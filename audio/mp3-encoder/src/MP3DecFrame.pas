unit MP3DecFrame;

(*
  MP3DecFrame.pas — MPEG1 Layer III frame header and side-info parser

  Parses the 32-bit frame header and the 136-bit (mono) / 256-bit (stereo)
  side-information block from a raw byte buffer, mirroring exactly what
  FrameWriteHeader and FrameWriteSideInfo in MP3EncFrame write.

  Only long-block (window_switching_flag = 0) granules are fully decoded;
  short-block granules skip 22 bits so the bit position stays correct and
  subsequent fields parse cleanly.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
*)

interface

uses
  SysUtils,
  MP3EncBitReader,
  MP3EncFrame;

{ Parse the 32-bit MPEG1 Layer III header at AFrame[AByteOffset].
  Returns False when:
    - buffer too short (< AByteOffset + 4)
    - sync word ≠ $7FF (11 bits)
    - version ≠ MPEG1 or layer ≠ Layer III
  On success ACfg.Channels (1/2) and ACfg.Granules (always 2) are derived. }
function FrameParseHeader(const AFrame: TBytes; AByteOffset: Integer;
  out ACfg: TFrameConfig): Boolean;

{ Parse side information from AFrame[AByteOffset] using ACfg obtained from
  FrameParseHeader.  The standard byte offset after the 4-byte header is 4. }
procedure FrameParseSideInfo(const AFrame: TBytes; AByteOffset: Integer;
  const ACfg: TFrameConfig; out ASI: TFrameSideInfo);

implementation

// ---------------------------------------------------------------------------

function FrameParseHeader(const AFrame: TBytes; AByteOffset: Integer;
  out ACfg: TFrameConfig): Boolean;
var
  BR: TMP3BitReader;
begin
  Result := False;
  FillChar(ACfg, SizeOf(ACfg), 0);
  if Length(AFrame) < AByteOffset + 4 then Exit;

  BitReaderInitAt(BR, AFrame, AByteOffset);

  if BitReaderRead(BR, 11) <> $7FF then Exit;  { sync word }

  ACfg.VersionBits     := Byte(BitReaderRead(BR, 2));
  ACfg.LayerBits       := Byte(BitReaderRead(BR, 2));
  ACfg.ProtectionBit   := Byte(BitReaderRead(BR, 1));

  if ACfg.VersionBits <> FRAME_VER_MPEG1 then Exit;
  if ACfg.LayerBits   <> FRAME_LAY_III   then Exit;

  ACfg.BitrateIndex    := Byte(BitReaderRead(BR, 4));
  ACfg.SamplerateIndex := Byte(BitReaderRead(BR, 2));
  ACfg.Padding         := Byte(BitReaderRead(BR, 1));
  ACfg.PrivateBit      := Byte(BitReaderRead(BR, 1));
  ACfg.ChannelMode     := Byte(BitReaderRead(BR, 2));
  ACfg.ModeExt         := Byte(BitReaderRead(BR, 2));
  ACfg.Copyright       := Byte(BitReaderRead(BR, 1));
  ACfg.Original        := Byte(BitReaderRead(BR, 1));
  ACfg.Emphasis        := Byte(BitReaderRead(BR, 2));

  if ACfg.ChannelMode = FRAME_CH_MONO then
    ACfg.Channels := 1
  else
    ACfg.Channels := 2;
  ACfg.Granules := 2;  { MPEG1: always 2 granules }

  Result := True;
end;

// ---------------------------------------------------------------------------

procedure ReadGrSideInfo(var ABR: TMP3BitReader; out AGr: TGrInfo);
begin
  FillChar(AGr, SizeOf(AGr), 0);
  AGr.Part2_3_Length   := Integer(BitReaderRead(ABR, 12));
  AGr.BigValues        := Integer(BitReaderRead(ABR, 9));
  AGr.GlobalGain       := Integer(BitReaderRead(ABR, 8));
  AGr.ScalefacCompress := Integer(BitReaderRead(ABR, 4));
  if BitReaderRead(ABR, 1) = 0 then begin  { window_switching_flag = 0: long block }
    AGr.TableSelect[0] := Byte(BitReaderRead(ABR, 5));
    AGr.TableSelect[1] := Byte(BitReaderRead(ABR, 5));
    AGr.TableSelect[2] := Byte(BitReaderRead(ABR, 5));
    AGr.Region0Count   := Byte(BitReaderRead(ABR, 4));
    AGr.Region1Count   := Byte(BitReaderRead(ABR, 3));
  end else begin
    { short blocks: block_type(2)+mixed(1)+table_select[0..1](10)+subblock_gain[3](9) = 22 bits }
    BitReaderSkip(ABR, 22);
  end;
  AGr.Preflag           := Byte(BitReaderRead(ABR, 1));
  AGr.ScalefacScale     := Byte(BitReaderRead(ABR, 1));
  AGr.Count1TableSelect := Byte(BitReaderRead(ABR, 1));
end;

procedure FrameParseSideInfo(const AFrame: TBytes; AByteOffset: Integer;
  const ACfg: TFrameConfig; out ASI: TFrameSideInfo);
var
  BR     : TMP3BitReader;
  ch, gr : Integer;
begin
  FillChar(ASI, SizeOf(ASI), 0);
  if Length(AFrame) <= AByteOffset then Exit;

  BitReaderInitAt(BR, AFrame, AByteOffset);

  ASI.MainDataBegin := Integer(BitReaderRead(BR, 9));
  if ACfg.Channels = 1 then
    ASI.PrivateBits := Byte(BitReaderRead(BR, 5))
  else
    ASI.PrivateBits := Byte(BitReaderRead(BR, 3));

  for ch := 0 to ACfg.Channels - 1 do
    for gr := 0 to 3 do
      ASI.Scfsi[ch][gr] := Byte(BitReaderRead(BR, 1));

  for gr := 0 to ACfg.Granules - 1 do
    for ch := 0 to ACfg.Channels - 1 do
      ReadGrSideInfo(BR, ASI.Gr[gr][ch]);
end;

end.
