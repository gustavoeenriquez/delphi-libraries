unit MP3EncWAV;

(*
  MP3EncWAV.pas — WAV reader and WAV-to-MP3 stream encoder

  Supported PCM formats (AudioFormat = 1):
    8-bit unsigned, 16-bit signed, 24-bit signed, 32-bit signed
  Supported float format (AudioFormat = 3 = IEEE_FLOAT):
    32-bit IEEE 754 single-precision

  Channel counts: 1..8
    1 channel  -> mono MP3  (FRAME_CH_MONO)
    2+ channels -> stereo MP3 (FRAME_CH_DUAL); multichannel is downmixed using
                  a standard ITU-style L/R mix matrix (5.1 and 7.1 aware)

  Sample rates: 44100, 48000, 32000 Hz (MPEG1 Layer III).

  Multichannel downmix coefficients (channels 0-7 per WAVE standard order):
    Ch 0  Front Left          -> L: 1.000
    Ch 1  Front Right         -> R: 1.000
    Ch 2  Front Centre        -> L: 0.707, R: 0.707
    Ch 3  Low Frequency (LFE) -> L: 0.354, R: 0.354
    Ch 4  Back Left           -> L: 0.707
    Ch 5  Back Right          -> R: 0.707
    Ch 6  Side Left           -> L: 0.707
    Ch 7  Side Right          -> R: 0.707

  WAV sample scaling to encoder range (±32768):
    8-bit  unsigned: (b - 128) * 256
    16-bit signed:   s (unchanged)
    24-bit signed:   s / 256
    32-bit signed:   s / 65536
    32-bit float:    f * 32768

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
*)

interface

uses
  SysUtils,
  Classes,
  System.Math,
  MP3EncEncoder,
  MP3EncID3,
  MP3EncID3v2,
  MP3EncXing;

type
  TWAVHeader = record
    AudioFormat   : Word;      { 1 = PCM, 3 = IEEE float }
    Channels      : Word;      { 1..8 }
    SampleRate    : Cardinal;  { 44100 / 48000 / 32000 }
    BitsPerSample : Word;      { 8/16/24/32 for PCM; 32 for float }
    SampleCount   : Integer;   { total sample frames (data_bytes / block_align) }
    BlockAlign    : Word;      { Channels * BitsPerSample div 8 }
  end;

  TWAVReader = record
    Stream  : TStream;   { not owned }
    Header  : TWAVHeader;
    DataEnd : Int64;     { stream position just past the last data byte }
  end;

{ Parse the WAV header from the current stream position (must be at byte 0).
  Returns True for a valid PCM or IEEE-float WAV with a supported sample rate.
  On return the stream is positioned at the first PCM/float sample byte. }
function WAVReaderOpen(AStream: TStream; out AReader: TWAVReader): Boolean;

{ Map a WAV sample rate to an MPEG1 SrIdx (0=44100, 1=48000, 2=32000).
  Returns -1 if the rate is not one of the three MPEG1 rates. }
function WAVSrIdx(ASampleRate: Cardinal): Integer;

{ Read the next frame of up to ENC_PCM_PER_FRAME mono float samples.
  Multichannel input is downmixed to mono using the standard mix matrix.
  Samples are scaled to ±32768.  Remaining positions are set to 0.0.
  Returns True while samples remain; False when ACount = 0. }
function WAVReaderReadFrame(var AReader: TWAVReader; out APCM: T1152;
  out ACount: Integer): Boolean;

{ Read the next frame of up to ENC_PCM_PER_FRAME stereo float sample pairs.
  Mono input is duplicated to both channels.
  Multichannel input is downmixed using the standard mix matrix.
  Returns True while samples remain; False when ACount = 0. }
function WAVReaderReadFrameStereo(var AReader: TWAVReader;
  out APCM_L, APCM_R: T1152; out ACount: Integer): Boolean;

{ Encode a WAV stream to MP3.  Mono WAV -> mono MP3; 2+ channels -> stereo MP3.
  Returns frame count or -1 on error. }
function EncodeWAVStream(AWavIn, AMP3Out: TStream;
  ABrIdx, APadding: Byte): Integer;

{ Encode a WAV stream and append an ID3v1.1 tag. }
function EncodeWAVStreamTagged(AWavIn, AMP3Out: TStream;
  ABrIdx, APadding: Byte; const ATag: TID3v1Tag): Integer;

{ Encode a WAV stream and prepend an ID3v2.3 tag. }
function EncodeWAVStreamTaggedV2(AWavIn, AMP3Out: TStream;
  ABrIdx, APadding: Byte; const ATag: TID3v2Tag): Integer;

{ Encode a stereo (or multichannel) WAV using MS joint stereo.
  Mono WAV falls back to FRAME_CH_MONO.
  Returns frame count or -1 on error. }
function EncodeWAVStreamMS(AWavIn, AMP3Out: TStream;
  ABrIdx, APadding: Byte): Integer;

{ Encode a WAV stream and prepend a CBR Info (Xing) header frame. }
function EncodeWAVStreamInfo(AWavIn, AMP3Out: TStream;
  ABrIdx, APadding: Byte): Integer;

{ Encode a WAV stream and prepend a CBR Info (Xing) frame with LAME gapless
  extension (encoder delay = ENC_DELAY; padding = FrameCount*1152 - ENC_DELAY - TotalSamples). }
function EncodeWAVStreamLame(AWavIn, AMP3Out: TStream;
  ABrIdx, APadding: Byte): Integer;

{ Variable bitrate: AQuality 0 (best) .. 9 (smallest).  A Xing (VBR) header
  frame with a seek table and the LAME gapless extension is prepended.
  Returns the number of audio frames or -1 on error. }
function EncodeWAVStreamVBR(AWavIn, AMP3Out: TStream; AQuality: Integer): Integer;

implementation

// ---------------------------------------------------------------------------
// Little-endian I/O helpers
// ---------------------------------------------------------------------------

function ReadU16LE(AStream: TStream): Word;
var b: array[0..1] of Byte;
begin
  AStream.ReadBuffer(b, 2);
  Result := b[0] or (Word(b[1]) shl 8);
end;

function ReadU32LE(AStream: TStream): Cardinal;
var b: array[0..3] of Byte;
begin
  AStream.ReadBuffer(b, 4);
  Result := b[0] or (Cardinal(b[1]) shl 8)
          or (Cardinal(b[2]) shl 16) or (Cardinal(b[3]) shl 24);
end;

function ReadTag(AStream: TStream): AnsiString;
var b: array[0..3] of AnsiChar;
begin
  AStream.ReadBuffer(b, 4);
  SetString(Result, b, 4);
end;

// ---------------------------------------------------------------------------
// Downmix coefficients — ITU-style, channels 0..7 per WAVE standard order
// ---------------------------------------------------------------------------

const
  DOWNMIX_L: array[0..7] of Double =
    (1.000, 0.000, 0.707, 0.354, 0.707, 0.000, 0.707, 0.000);
  DOWNMIX_R: array[0..7] of Double =
    (0.000, 1.000, 0.707, 0.354, 0.000, 0.707, 0.000, 0.707);

// ---------------------------------------------------------------------------
// Sample reader
// ---------------------------------------------------------------------------

{ Read one sample value and return it scaled to ±32768. }
function ReadOneSample(AStream: TStream; ABits: Word;
  AIsFloat: Boolean): Double;
var
  b8  : Byte;
  s16 : SmallInt;
  b24 : array[0..2] of Byte;
  i24 : Integer;
  s32 : Integer;
  f32 : Single;
begin
  if AIsFloat then begin
    AStream.ReadBuffer(f32, SizeOf(f32));
    Result := f32 * 32768.0;
  end else
    case ABits of
      8: begin
           AStream.ReadBuffer(b8, 1);
           Result := (Integer(b8) - 128) * 256.0;
         end;
      16: begin
            AStream.ReadBuffer(s16, SizeOf(s16));
            Result := s16;
          end;
      24: begin
            AStream.ReadBuffer(b24, 3);
            i24 := Integer(b24[0]) or (Integer(b24[1]) shl 8)
                 or (Integer(b24[2]) shl 16);
            if (i24 and $800000) <> 0 then
              i24 := i24 or Integer($FF000000);  { sign-extend to 32 bits }
            Result := i24 / 256.0;
          end;
      32: begin
            AStream.ReadBuffer(s32, SizeOf(s32));
            Result := s32 / 65536.0;
          end;
    else
      Result := 0;
    end;
end;

// ---------------------------------------------------------------------------

function WAVSrIdx(ASampleRate: Cardinal): Integer;
begin
  case ASampleRate of
    44100: Result := 0;
    48000: Result := 1;
    32000: Result := 2;
  else
    Result := -1;
  end;
end;

// ---------------------------------------------------------------------------

function WAVReaderOpen(AStream: TStream; out AReader: TWAVReader): Boolean;
var
  tag       : AnsiString;
  chunkSize : Cardinal;
  audioFmt  : Word;
  byteRate  : Cardinal;
  dataBytes : Cardinal;
  fmtFound  : Boolean;
  dataFound : Boolean;
  fmtSize   : Cardinal;
begin
  Result  := False;
  FillChar(AReader, SizeOf(AReader), 0);
  AReader.Stream := AStream;
  try
    { RIFF header }
    tag := ReadTag(AStream);
    if tag <> 'RIFF' then Exit;
    ReadU32LE(AStream);       { file size - 8, ignored }
    tag := ReadTag(AStream);
    if tag <> 'WAVE' then Exit;

    fmtFound  := False;
    dataFound := False;

    while (AStream.Position < AStream.Size - 7) and not dataFound do begin
      tag       := ReadTag(AStream);
      chunkSize := ReadU32LE(AStream);

      if tag = 'fmt ' then begin
        fmtSize := chunkSize;
        if fmtSize < 16 then Exit;
        audioFmt := ReadU16LE(AStream);
        if (audioFmt <> 1) and (audioFmt <> 3) then Exit;  { PCM or IEEE float }
        AReader.Header.AudioFormat    := audioFmt;
        AReader.Header.Channels       := ReadU16LE(AStream);
        AReader.Header.SampleRate     := ReadU32LE(AStream);
        byteRate                      := ReadU32LE(AStream);
        AReader.Header.BlockAlign     := ReadU16LE(AStream);
        AReader.Header.BitsPerSample  := ReadU16LE(AStream);
        if fmtSize > 16 then
          AStream.Seek(fmtSize - 16, soCurrent);
        fmtFound := True;
        byteRate := byteRate;  { suppress hint }
      end else if tag = 'data' then begin
        if not fmtFound then Exit;
        dataBytes := chunkSize;
        AReader.Header.SampleCount := dataBytes div AReader.Header.BlockAlign;
        AReader.DataEnd := AStream.Position + dataBytes;
        dataFound := True;
      end else
        AStream.Seek((chunkSize + 1) and not Cardinal(1), soCurrent);
    end;

    if not (fmtFound and dataFound) then Exit;

    { Validate bit depth + format combination }
    if AReader.Header.AudioFormat = 3 then begin
      if AReader.Header.BitsPerSample <> 32 then Exit;   { float: 32-bit only }
    end else begin
      if not (AReader.Header.BitsPerSample in [8, 16, 24, 32]) then Exit;
    end;

    { Validate channel count }
    if (AReader.Header.Channels < 1) or (AReader.Header.Channels > 8) then Exit;

    if WAVSrIdx(AReader.Header.SampleRate) < 0 then Exit;

    Result := True;
  except
    Result := False;
    FillChar(AReader, SizeOf(AReader), 0);
  end;
end;

// ---------------------------------------------------------------------------

function WAVReaderReadFrame(var AReader: TWAVReader; out APCM: T1152;
  out ACount: Integer): Boolean;
var
  i, ch, bytesLeft, samplesLeft: Integer;
  nch    : Integer;
  isFloat: Boolean;
  bits   : Word;
  chBuf  : array[0..7] of Double;
  L, R   : Double;
begin
  FillChar(APCM, SizeOf(APCM), 0);
  ACount := 0;

  bytesLeft := AReader.DataEnd - AReader.Stream.Position;
  if bytesLeft <= 0 then begin Result := False; Exit; end;

  samplesLeft := bytesLeft div AReader.Header.BlockAlign;
  if samplesLeft > ENC_PCM_PER_FRAME then
    samplesLeft := ENC_PCM_PER_FRAME;

  nch     := AReader.Header.Channels;
  bits    := AReader.Header.BitsPerSample;
  isFloat := AReader.Header.AudioFormat = 3;

  for i := 0 to samplesLeft - 1 do begin
    for ch := 0 to nch - 1 do
      chBuf[ch] := ReadOneSample(AReader.Stream, bits, isFloat);
    if nch = 1 then
      APCM[i] := chBuf[0]
    else begin
      L := 0; R := 0;
      for ch := 0 to nch - 1 do begin
        L := L + chBuf[ch] * DOWNMIX_L[ch];
        R := R + chBuf[ch] * DOWNMIX_R[ch];
      end;
      APCM[i] := (L + R) * 0.5;
    end;
  end;

  ACount := samplesLeft;
  Result := ACount > 0;
end;

// ---------------------------------------------------------------------------

function WAVReaderReadFrameStereo(var AReader: TWAVReader;
  out APCM_L, APCM_R: T1152; out ACount: Integer): Boolean;
var
  i, ch, bytesLeft, samplesLeft: Integer;
  nch    : Integer;
  isFloat: Boolean;
  bits   : Word;
  chBuf  : array[0..7] of Double;
  L, R   : Double;
begin
  FillChar(APCM_L, SizeOf(APCM_L), 0);
  FillChar(APCM_R, SizeOf(APCM_R), 0);
  ACount := 0;

  bytesLeft := AReader.DataEnd - AReader.Stream.Position;
  if bytesLeft <= 0 then begin Result := False; Exit; end;

  samplesLeft := bytesLeft div AReader.Header.BlockAlign;
  if samplesLeft > ENC_PCM_PER_FRAME then
    samplesLeft := ENC_PCM_PER_FRAME;

  nch     := AReader.Header.Channels;
  bits    := AReader.Header.BitsPerSample;
  isFloat := AReader.Header.AudioFormat = 3;

  for i := 0 to samplesLeft - 1 do begin
    for ch := 0 to nch - 1 do
      chBuf[ch] := ReadOneSample(AReader.Stream, bits, isFloat);
    if nch = 1 then begin
      APCM_L[i] := chBuf[0];
      APCM_R[i] := chBuf[0];
    end else begin
      L := 0; R := 0;
      for ch := 0 to nch - 1 do begin
        L := L + chBuf[ch] * DOWNMIX_L[ch];
        R := R + chBuf[ch] * DOWNMIX_R[ch];
      end;
      APCM_L[i] := L;
      APCM_R[i] := R;
    end;
  end;

  ACount := samplesLeft;
  Result := ACount > 0;
end;

// ---------------------------------------------------------------------------

function EncodeWAVStreamEx(AWavIn, AMP3Out: TStream;
  ABrIdx, APadding: Byte; AVbrQuality: Integer): Integer; forward;

function EncodeWAVStream(AWavIn, AMP3Out: TStream;
  ABrIdx, APadding: Byte): Integer;
begin
  Result := EncodeWAVStreamEx(AWavIn, AMP3Out, ABrIdx, APadding, -1);
end;

{ AVbrQuality < 0: CBR at ABrIdx; 0..9: VBR }
function EncodeWAVStreamEx(AWavIn, AMP3Out: TStream;
  ABrIdx, APadding: Byte; AVbrQuality: Integer): Integer;
var
  Reader : TWAVReader;
  Enc    : TMP3Encoder;
  Cfg    : TEncConfig;
  PCM    : T1152;
  PCM_L  : T1152;
  PCM_R  : T1152;
  Frame  : TBytes;
  cnt    : Integer;
  srIdx  : Integer;
begin
  Result := -1;
  if not WAVReaderOpen(AWavIn, Reader) then Exit;

  srIdx := WAVSrIdx(Reader.Header.SampleRate);
  if srIdx < 0 then Exit;

  Cfg.SrIdx   := srIdx;
  Cfg.BrIdx   := ABrIdx;
  Cfg.Padding := APadding;

  if Reader.Header.Channels >= 2 then begin
    EncInitStereo(Enc, Cfg);
    EncEnableReservoir(Enc, True);
    if AVbrQuality >= 0 then EncEnableVBR(Enc, AVbrQuality);
    Result := 0;
    while WAVReaderReadFrameStereo(Reader, PCM_L, PCM_R, cnt) do begin
      Frame := EncodeFrameAuto(Enc, PCM_L, PCM_R);
      if Length(Frame) > 0 then AMP3Out.WriteBuffer(Frame[0], Length(Frame));
      Inc(Result);
    end;
    { one frame of silence pushes out the ENC_DELAY samples still inside
      the analysis filterbank }
    FillChar(PCM_L, SizeOf(PCM_L), 0);
    FillChar(PCM_R, SizeOf(PCM_R), 0);
    Frame := EncodeFrameAuto(Enc, PCM_L, PCM_R);
    if Length(Frame) > 0 then AMP3Out.WriteBuffer(Frame[0], Length(Frame));
    Inc(Result);
  end else begin
    EncInit(Enc, Cfg);
    EncEnableReservoir(Enc, True);
    if AVbrQuality >= 0 then EncEnableVBR(Enc, AVbrQuality);
    Result := 0;
    while WAVReaderReadFrame(Reader, PCM, cnt) do begin
      Frame := EncodeFrame(Enc, PCM);
      if Length(Frame) > 0 then AMP3Out.WriteBuffer(Frame[0], Length(Frame));
      Inc(Result);
    end;
    FillChar(PCM, SizeOf(PCM), 0);
    Frame := EncodeFrame(Enc, PCM);
    if Length(Frame) > 0 then AMP3Out.WriteBuffer(Frame[0], Length(Frame));
    Inc(Result);
  end;
  Frame := EncFlush(Enc);
  if Length(Frame) > 0 then AMP3Out.WriteBuffer(Frame[0], Length(Frame));
end;

// ---------------------------------------------------------------------------

function EncodeWAVStreamTaggedV2(AWavIn, AMP3Out: TStream;
  ABrIdx, APadding: Byte; const ATag: TID3v2Tag): Integer;
var
  Temp: TMemoryStream;
begin
  Temp := TMemoryStream.Create;
  try
    Result := EncodeWAVStream(AWavIn, Temp, ABrIdx, APadding);
    if Result >= 0 then begin
      ID3v2WriteTag(AMP3Out, ATag);
      Temp.Position := 0;
      AMP3Out.CopyFrom(Temp, Temp.Size);
    end;
  finally
    Temp.Free;
  end;
end;

// ---------------------------------------------------------------------------

function EncodeWAVStreamMS(AWavIn, AMP3Out: TStream;
  ABrIdx, APadding: Byte): Integer;
var
  Reader : TWAVReader;
  Enc    : TMP3Encoder;
  Cfg    : TEncConfig;
  PCM    : T1152;
  PCM_L  : T1152;
  PCM_R  : T1152;
  Frame  : TBytes;
  cnt    : Integer;
  srIdx  : Integer;
begin
  Result := -1;
  if not WAVReaderOpen(AWavIn, Reader) then Exit;

  srIdx := WAVSrIdx(Reader.Header.SampleRate);
  if srIdx < 0 then Exit;

  Cfg.SrIdx   := srIdx;
  Cfg.BrIdx   := ABrIdx;
  Cfg.Padding := APadding;

  if Reader.Header.Channels >= 2 then begin
    EncInitJointStereo(Enc, Cfg);
    EncEnableReservoir(Enc, True);
    Result := 0;
    while WAVReaderReadFrameStereo(Reader, PCM_L, PCM_R, cnt) do begin
      Frame := EncodeFrameMS(Enc, PCM_L, PCM_R);
      if Length(Frame) > 0 then AMP3Out.WriteBuffer(Frame[0], Length(Frame));
      Inc(Result);
    end;
    FillChar(PCM_L, SizeOf(PCM_L), 0);
    FillChar(PCM_R, SizeOf(PCM_R), 0);
    Frame := EncodeFrameMS(Enc, PCM_L, PCM_R);
    if Length(Frame) > 0 then AMP3Out.WriteBuffer(Frame[0], Length(Frame));
    Inc(Result);
  end else begin
    EncInit(Enc, Cfg);
    EncEnableReservoir(Enc, True);
    Result := 0;
    while WAVReaderReadFrame(Reader, PCM, cnt) do begin
      Frame := EncodeFrame(Enc, PCM);
      if Length(Frame) > 0 then AMP3Out.WriteBuffer(Frame[0], Length(Frame));
      Inc(Result);
    end;
    FillChar(PCM, SizeOf(PCM), 0);
    Frame := EncodeFrame(Enc, PCM);
    if Length(Frame) > 0 then AMP3Out.WriteBuffer(Frame[0], Length(Frame));
    Inc(Result);
  end;
  Frame := EncFlush(Enc);
  if Length(Frame) > 0 then AMP3Out.WriteBuffer(Frame[0], Length(Frame));
end;

// ---------------------------------------------------------------------------

function EncodeWAVStreamTagged(AWavIn, AMP3Out: TStream;
  ABrIdx, APadding: Byte; const ATag: TID3v1Tag): Integer;
begin
  Result := EncodeWAVStream(AWavIn, AMP3Out, ABrIdx, APadding);
  if Result >= 0 then
    ID3WriteTag(AMP3Out, ATag);
end;

// ---------------------------------------------------------------------------

function EncodeWAVStreamInfo(AWavIn, AMP3Out: TStream;
  ABrIdx, APadding: Byte): Integer;
var
  Reader  : TWAVReader;
  Cfg     : TEncConfig;
  Tag     : TXingTag;
  Temp    : TMemoryStream;
  srIdx   : Integer;
  channels: Integer;
begin
  Result := -1;
  if not WAVReaderOpen(AWavIn, Reader) then Exit;
  srIdx    := WAVSrIdx(Reader.Header.SampleRate);
  channels := Reader.Header.Channels;
  if srIdx < 0 then Exit;

  Cfg.SrIdx   := srIdx;
  Cfg.BrIdx   := ABrIdx;
  Cfg.Padding := APadding;

  AWavIn.Position := 0;
  Temp := TMemoryStream.Create;
  try
    Result := EncodeWAVStream(AWavIn, Temp, ABrIdx, APadding);
    if Result < 0 then Exit;

    Tag            := Default(TXingTag);
    Tag.IsVBR      := False;
    Tag.Flags      := XING_FLAG_FRAMES or XING_FLAG_BYTES or XING_FLAG_TOC;
    Tag.FrameCount := Result;
    Tag.FileSize   := Temp.Size;
    XingBuildCBRTOC(Tag.TOC);

    { Xing channel count: cap at 2 for the Info frame }
    if channels > 2 then channels := 2;
    XingWriteFrame(AMP3Out, Cfg, channels, Tag);
    Temp.Position := 0;
    AMP3Out.CopyFrom(Temp, Temp.Size);
  finally
    Temp.Free;
  end;
end;

// ---------------------------------------------------------------------------

function EncodeWAVStreamLame(AWavIn, AMP3Out: TStream;
  ABrIdx, APadding: Byte): Integer;
var
  Reader      : TWAVReader;
  Cfg         : TEncConfig;
  XTag        : TXingTag;
  LTag        : TLameTag;
  Temp        : TMemoryStream;
  srIdx       : Integer;
  channels    : Integer;
  totalSamples: Integer;
  encPadding  : Integer;
begin
  Result := -1;
  if not WAVReaderOpen(AWavIn, Reader) then Exit;
  srIdx        := WAVSrIdx(Reader.Header.SampleRate);
  if srIdx < 0 then Exit;
  channels     := Reader.Header.Channels;
  totalSamples := Reader.Header.SampleCount;

  Cfg.SrIdx   := srIdx;
  Cfg.BrIdx   := ABrIdx;
  Cfg.Padding := APadding;

  AWavIn.Position := 0;
  Temp := TMemoryStream.Create;
  try
    Result := EncodeWAVStream(AWavIn, Temp, ABrIdx, APadding);
    if Result < 0 then Exit;

    { The analysis filterbank delays the audio by ENC_DELAY samples and a
      frame of silence is appended, so the padding after the real audio is
      frames*1152 - delay - samples (gapless decoders drop delay + padding). }
    encPadding := Result * 1152 - totalSamples - ENC_DELAY;
    if encPadding < 0 then encPadding := 0;

    XTag            := Default(TXingTag);
    XTag.IsVBR      := False;
    XTag.Flags      := XING_FLAG_FRAMES or XING_FLAG_BYTES
                     or XING_FLAG_TOC   or XING_FLAG_QUALITY;
    XTag.FrameCount := Result;
    XTag.FileSize   := Temp.Size;
    XingBuildCBRTOC(XTag.TOC);

    LTag                := Default(TLameTag);
    LTag.EncoderDelay   := ENC_DELAY;
    LTag.EncoderPadding := encPadding;
    LTag.VBRMethod      := LAME_VBR_CBR;
    LTag.MusicLength    := Temp.Size;

    if channels > 2 then channels := 2;
    LameWriteFrame(AMP3Out, Cfg, channels, XTag, LTag);
    Temp.Position := 0;
    AMP3Out.CopyFrom(Temp, Temp.Size);
  finally
    Temp.Free;
  end;
end;

// ---------------------------------------------------------------------------

{$POINTERMATH ON}
{ Byte offset of every MPEG1 Layer III frame in AData (header walk). }
function FrameOffsets(const AData: TMemoryStream): TArray<Integer>;
const
  KBPS_TAB: array[0..15] of Integer = (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0);
  SRT: array[0..3] of Integer = (44100, 48000, 32000, 0);
var
  p, len, br, sr: Integer;
  b: PByte;
begin
  Result := nil;
  b := AData.Memory;
  p := 0;
  while p + 4 <= AData.Size do begin
    if (b[p] <> $FF) or ((b[p + 1] and $E0) <> $E0) then Break;
    br := KBPS_TAB[b[p + 2] shr 4];
    sr := SRT[(b[p + 2] shr 2) and 3];
    if (br = 0) or (sr = 0) then Break;
    len := 144000 * br div sr + ((b[p + 2] shr 1) and 1);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := p;
    Inc(p, len);
  end;
end;

function EncodeWAVStreamVBR(AWavIn, AMP3Out: TStream; AQuality: Integer): Integer;
var
  Reader      : TWAVReader;
  Cfg         : TEncConfig;
  XTag        : TXingTag;
  LTag        : TLameTag;
  Temp        : TMemoryStream;
  ofs         : TArray<Integer>;
  srIdx, channels, totalSamples, encPadding, i, f: Integer;
begin
  Result := -1;
  if not WAVReaderOpen(AWavIn, Reader) then Exit;
  srIdx := WAVSrIdx(Reader.Header.SampleRate);
  if srIdx < 0 then Exit;
  channels     := Reader.Header.Channels;
  totalSamples := Reader.Header.SampleCount;
  { the header frame itself: 128 kbps holds the Xing and LAME data in mono and stereo }
  Cfg.SrIdx   := srIdx;
  Cfg.BrIdx   := 9;
  Cfg.Padding := 0;

  AWavIn.Position := 0;
  Temp := TMemoryStream.Create;
  try
    Result := EncodeWAVStreamEx(AWavIn, Temp, 9, 0, AQuality);
    if Result < 0 then Exit;
    encPadding := Result * 1152 - totalSamples - ENC_DELAY;
    if encPadding < 0 then encPadding := 0;

    { seek table: byte position (x 256 / size) of the frame at each percent }
    ofs := FrameOffsets(Temp);
    XTag            := Default(TXingTag);
    XTag.IsVBR      := True;
    XTag.Flags      := XING_FLAG_FRAMES or XING_FLAG_BYTES
                     or XING_FLAG_TOC   or XING_FLAG_QUALITY;
    XTag.FrameCount := Length(ofs);
    XTag.FileSize   := Temp.Size;
    XTag.Quality    := AQuality * 10;
    for i := 0 to 99 do
      if Length(ofs) > 0 then begin
        f := (i * Length(ofs)) div 100;
        XTag.TOC[i] := Min(255, Int64(ofs[f]) * 256 div Max(Temp.Size, 1));
      end;

    LTag                := Default(TLameTag);
    LTag.EncoderDelay   := ENC_DELAY;
    LTag.EncoderPadding := encPadding;
    LTag.VBRMethod      := LAME_VBR_VBR;
    LTag.MusicLength    := Temp.Size;

    if channels > 2 then channels := 2;
    LameWriteFrame(AMP3Out, Cfg, channels, XTag, LTag);
    Temp.Position := 0;
    AMP3Out.CopyFrom(Temp, Temp.Size);
  finally
    Temp.Free;
  end;
end;

end.
