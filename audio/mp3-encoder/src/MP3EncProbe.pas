unit MP3EncProbe;

(*
  MP3EncProbe.pas — MP3 stream metadata extractor

  Given any TStream containing an MP3 file, extracts:
    - Audio properties: bitrate, sample rate, channels, channel mode
    - Duration: computed from frame count * 1152 / sample_rate
    - Frame count: from Xing/Info header when present, otherwise by scanning
    - Xing/Info header presence and VBR flag
    - ID3v1 and ID3v2 tags (read via MP3EncID3 and MP3EncID3v2)

  Stream layout handled:
    [ID3v2 header (optional)] [audio frames] [ID3v1 tag (optional)]

  Reference: ISO 11172-3; https://wiki.hydrogenaud.io/index.php?title=Xing
  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
*)

interface

uses
  SysUtils,
  Classes,
  MP3EncFrame,
  MP3EncEncoder,
  MP3DecFrame,
  MP3EncID3,
  MP3EncID3v2;

type
  TMP3ProbeResult = record
    IsValid      : Boolean;
    DurationMs   : Cardinal;   { FrameCount * 1152 / SampleRate * 1000 }
    FrameCount   : Integer;    { audio frames (Xing/Info frame not counted) }
    BitRateKbps  : Integer;    { 32..320 }
    SampleRate   : Integer;    { Hz: 44100, 48000 or 32000 }
    Channels     : Integer;    { 1 or 2 }
    ChannelMode  : Byte;       { FRAME_CH_MONO / FRAME_CH_DUAL / FRAME_CH_JOINT }
    HasXing      : Boolean;    { Xing or Info frame found }
    IsVBR        : Boolean;    { True = "Xing" marker (VBR), False = "Info" (CBR) }
    HasID3v1     : Boolean;
    HasID3v2     : Boolean;
    TagV1        : TID3v1Tag;
    TagV2        : TID3v2Tag;
  end;

{ Probe an MP3 stream. Saves and restores stream position.
  Returns True when at least one valid MPEG1 Layer III frame is found. }
function MP3ProbeStream(AStream: TStream; out AResult: TMP3ProbeResult): Boolean;

implementation

const
  PROBE_KBPS: array[0..14] of Integer =
    (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320);
  PROBE_SR: array[0..2] of Integer = (44100, 48000, 32000);
  PROBE_XING_FLAG_FRAMES = $01;

function XingOfsForCh(ACh: Integer): Integer;
begin
  if ACh > 1 then Result := 36 else Result := 21;  { 4+32 stereo, 4+17 mono }
end;

// ---------------------------------------------------------------------------

function MP3ProbeStream(AStream: TStream; out AResult: TMP3ProbeResult): Boolean;
var
  savedPos   : Int64;
  audioStart : Int64;
  audioEnd   : Int64;
  frameSize  : Integer;
  FCfg       : TFrameConfig;
  buf4       : TBytes;
  firstFrame : TBytes;
  xOfs       : Integer;
  xFlags     : Cardinal;
  xPos       : Integer;
  scanPos    : Int64;
begin
  Result  := False;
  AResult := Default(TMP3ProbeResult);
  savedPos := AStream.Position;
  try
    if AStream.Size < 4 then Exit;

    { ID3v2 at stream start }
    AResult.HasID3v2 := ID3v2HasTag(AStream);
    if AResult.HasID3v2 then begin
      ID3v2ReadTag(AStream, AResult.TagV2);
      audioStart := ID3v2TagSize(AStream);
    end else
      audioStart := 0;

    { ID3v1 at stream end }
    AResult.HasID3v1 := ID3HasTag(AStream);
    if AResult.HasID3v1 then
      ID3ReadTag(AStream, AResult.TagV1);

    audioEnd := AStream.Size;
    if AResult.HasID3v1 then
      Dec(audioEnd, ID3_TAG_SIZE);

    { Parse first audio frame header }
    if audioStart + 4 > audioEnd then Exit;
    SetLength(buf4, 4);
    AStream.Position := audioStart;
    AStream.ReadBuffer(buf4[0], 4);
    if not FrameParseHeader(buf4, 0, FCfg) then Exit;

    AResult.IsValid     := True;
    AResult.BitRateKbps := PROBE_KBPS[FCfg.BitrateIndex];
    AResult.SampleRate  := PROBE_SR[FCfg.SamplerateIndex];
    AResult.Channels    := FCfg.Channels;
    AResult.ChannelMode := FCfg.ChannelMode;

    frameSize := EncFrameBytes(FCfg.BitrateIndex, FCfg.SamplerateIndex, FCfg.Padding);

    { Check for Xing / Info in first audio frame }
    if audioStart + frameSize <= audioEnd then begin
      SetLength(firstFrame, frameSize);
      AStream.Position := audioStart;
      AStream.ReadBuffer(firstFrame[0], frameSize);
      xOfs := XingOfsForCh(FCfg.Channels);
      if xOfs + 12 <= frameSize then begin
        if (firstFrame[xOfs]   = Ord('X')) and (firstFrame[xOfs+1] = Ord('i')) and
           (firstFrame[xOfs+2] = Ord('n')) and (firstFrame[xOfs+3] = Ord('g')) then begin
          AResult.HasXing := True;
          AResult.IsVBR   := True;
        end else
        if (firstFrame[xOfs]   = Ord('I')) and (firstFrame[xOfs+1] = Ord('n')) and
           (firstFrame[xOfs+2] = Ord('f')) and (firstFrame[xOfs+3] = Ord('o')) then begin
          AResult.HasXing := True;
          AResult.IsVBR   := False;
        end;

        if AResult.HasXing then begin
          xPos   := xOfs + 4;
          xFlags := (Cardinal(firstFrame[xPos])   shl 24)
                  or (Cardinal(firstFrame[xPos+1]) shl 16)
                  or (Cardinal(firstFrame[xPos+2]) shl 8)
                  or  Cardinal(firstFrame[xPos+3]);
          Inc(xPos, 4);
          if (xFlags and PROBE_XING_FLAG_FRAMES) <> 0 then
            AResult.FrameCount := Integer(
               (Cardinal(firstFrame[xPos])   shl 24)
              or (Cardinal(firstFrame[xPos+1]) shl 16)
              or (Cardinal(firstFrame[xPos+2]) shl 8)
              or  Cardinal(firstFrame[xPos+3]));
        end;
      end;
    end;

    { Scan frames when Xing absent or has no frame count }
    if not AResult.HasXing or (AResult.FrameCount = 0) then begin
      AResult.FrameCount := 0;
      if AResult.HasXing then
        scanPos := audioStart + frameSize   { skip the Xing frame }
      else
        scanPos := audioStart;
      SetLength(buf4, 4);
      while scanPos + 4 <= audioEnd do begin
        AStream.Position := scanPos;
        AStream.ReadBuffer(buf4[0], 4);
        if FrameParseHeader(buf4, 0, FCfg) then begin
          Inc(AResult.FrameCount);
          Inc(scanPos,
            EncFrameBytes(FCfg.BitrateIndex, FCfg.SamplerateIndex, FCfg.Padding));
        end else
          Inc(scanPos);  { resync: skip one byte }
      end;
    end;

    { Duration }
    if (AResult.SampleRate > 0) and (AResult.FrameCount > 0) then
      AResult.DurationMs := Cardinal(
        Round(AResult.FrameCount * 1152.0 / AResult.SampleRate * 1000));

    Result := True;
  finally
    AStream.Position := savedPos;
  end;
end;

end.
