unit MP3EncXing;

(*
  MP3EncXing.pas — Xing/Info CBR header frame and LAME gapless tag

  The Info (CBR) or Xing (VBR) header is embedded in the first MP3 frame.
  That frame carries silence audio (Part2_3_Length = 0 for both granules)
  and the metadata is written into the main-data area beginning at:
    MPEG1 mono   : byte 21  (4 header + 17 side-info)
    MPEG1 stereo : byte 36  (4 header + 32 side-info)

  Binary layout of the Xing/Info embedded data (all multi-byte fields big-endian):
    +0   4 bytes  "Info" (CBR) or "Xing" (VBR)
    +4   4 bytes  flags  (bit 0 = FrameCount, 1 = FileSize, 2 = TOC, 3 = Quality)
    +8   4 bytes  total audio frame count              (when bit 0 set)
   +12   4 bytes  total audio byte size                (when bit 1 set)
   +16 100 bytes  TOC[0..99]: seek table               (when bit 2 set)
  +116   4 bytes  quality, 0 (best) .. 100 (worst)     (when bit 3 set)

  When all four flags are set the Xing data area is exactly 120 bytes.
  The LAME extension is placed at xingDataOffset + 120.

  LAME extension (36 bytes; layout of LAME VbrTag.c, as read by ffmpeg):
    +0    9 bytes  Encoder string ("LAME3.100")
    +9    1 byte   Info tag revision (bits 7-4) + VBR method (bits 3-0)
    +10   1 byte   Lowpass filter value (100 Hz units; 0 = not set)
    +11   4 bytes  Replay Gain — peak signal amplitude (set to 0)
    +15   2 bytes  Radio Replay Gain (set to 0)
    +17   2 bytes  Audiophile Replay Gain (set to 0)
    +19   1 byte   Encoding flags (bits 7-4) + ATH type (bits 3-0)
    +20   1 byte   ABR / minimum bitrate (set to 0)
    +21   3 bytes  Encoder delay (12 bits, MSB) | encoder padding (12 bits, LSB)
    +24   1 byte   Misc info (set to 0)
    +25   1 byte   MP3 gain (set to 0)
    +26   2 bytes  Preset and surround info (set to 0)
    +28   4 bytes  Music length (total byte count of all audio frames)
    +32   2 bytes  Music CRC (set to 0)
    +34   2 bytes  Info tag CRC: CRC-16 of the frame bytes before it (190 stereo, 175 mono)

  Delay/padding encoding (3 bytes at LAME +21):
    byte[0] = (delay  >> 4) & 0xFF
    byte[1] = ((delay  & 0x0F) << 4) | ((padding >> 8) & 0x0F)
    byte[2] = padding & 0xFF

  References:
    https://wiki.hydrogenaud.io/index.php?title=Xing
    http://gabriel.mp3-tech.org/mp3infotag.html
  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
*)

interface

uses
  SysUtils,
  Classes,
  MP3EncBitWriter,
  MP3EncFrame,
  MP3EncEncoder;

const
  XING_FLAG_FRAMES  = $01;
  XING_FLAG_BYTES   = $02;
  XING_FLAG_TOC     = $04;
  XING_FLAG_QUALITY = $08;

  LAME_VBR_CBR       = 1;    { CBR encoding }
  LAME_VBR_VBR       = 4;    { VBR-new (LAME default) }
  LAME_ENCODER_DELAY = 576;  { standard MPEG1 Layer III MDCT overhead, in samples }

type
  TXingTag = record
    IsVBR      : Boolean;                { False = "Info" (CBR), True = "Xing" (VBR) }
    Flags      : Byte;                   { OR of XING_FLAG_* constants }
    FrameCount : Cardinal;
    FileSize   : Cardinal;               { total bytes of audio frames (not this frame) }
    TOC        : array[0..99] of Byte;   { TOC[i] = floor(seek_pos[i%] / total * 256) }
    Quality    : Cardinal;               { 0 = best .. 100 = worst }
  end;

  TLameTag = record
    EncoderDelay  : Word;    { 0..4095: silence samples the encoder prepends }
    EncoderPadding: Word;    { 0..4095: zero samples added to the last frame }
    VBRMethod     : Byte;    { LAME_VBR_CBR = 1, LAME_VBR_VBR = 4 }
    MusicLength   : Cardinal;  { total byte count of all audio frames }
  end;

{ Byte offset within a frame where the Xing data begins.
  MPEG1 mono: 21 (4+17).  MPEG1 stereo: 36 (4+32). }
function XingDataOffset(AChannels: Integer): Integer;

{ Fill ATOC with a linear CBR seek table: TOC[i] = Round(i * 256 / 100). }
procedure XingBuildCBRTOC(var ATOC: array of Byte);

{ Write a complete silence MP3 frame with the Xing/Info data embedded
  in the main-data area.  AChannels: 1 (mono) or 2 (stereo). }
procedure XingWriteFrame(AStream: TStream; const ACfg: TEncConfig;
  AChannels: Integer; const ATag: TXingTag);

{ Parse a Xing/Info header from the first frame of AStream.
  Stream position is saved and restored.
  Returns True when "Xing" or "Info" magic is found. }
function XingReadFrame(AStream: TStream; const ACfg: TEncConfig;
  AChannels: Integer; out ATag: TXingTag): Boolean;

{ Write a Xing/Info frame with LAME gapless extension at xingDataOffset + 120.
  All four Xing flags are forced on to guarantee the 120-byte Xing area.
  Falls back to a plain Xing frame when the frame is too small for LAME data. }
procedure LameWriteFrame(AStream: TStream; const ACfg: TEncConfig;
  AChannels: Integer; const AXing: TXingTag; const ALame: TLameTag);

{ Parse a Xing/Info frame and its LAME extension.
  Stream position is saved and restored.
  Returns True only when both Xing/Info magic and LAME magic are found. }
function LameReadFrame(AStream: TStream; const ACfg: TEncConfig;
  AChannels: Integer; out AXing: TXingTag; out ALame: TLameTag): Boolean;

implementation

// ---------------------------------------------------------------------------

function XingDataOffset(AChannels: Integer): Integer;
begin
  if AChannels > 1 then
    Result := 4 + (FRAME_SIDEINFO_STEREO div 8)   { 36 }
  else
    Result := 4 + (FRAME_SIDEINFO_MONO div 8);     { 21 }
end;

// ---------------------------------------------------------------------------

procedure XingBuildCBRTOC(var ATOC: array of Byte);
var
  i: Integer;
begin
  for i := 0 to High(ATOC) do
    ATOC[i] := Byte(Round(i * 256 / 100));
end;

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

procedure WriteU32BE(AFrame: TBytes; APos: Integer; V: Cardinal);
begin
  AFrame[APos]     := (V shr 24) and $FF;
  AFrame[APos + 1] := (V shr 16) and $FF;
  AFrame[APos + 2] := (V shr 8)  and $FF;
  AFrame[APos + 3] :=  V         and $FF;
end;

function ReadU32BE(const AFrame: TBytes; APos: Integer): Cardinal;
begin
  Result := (Cardinal(AFrame[APos])     shl 24)
          or (Cardinal(AFrame[APos + 1]) shl 16)
          or (Cardinal(AFrame[APos + 2]) shl 8)
          or  Cardinal(AFrame[APos + 3]);
end;

{ CRC-16 with polynomial $8005, init 0, no reflection — same as LAME VBRTag.c }
function CRC16Frame(const AFrame: TBytes; ALen: Integer): Word;
var
  crc: Word;
  i, bit: Integer;
begin
  crc := 0;
  for i := 0 to ALen - 1 do begin
    crc := crc xor (Word(AFrame[i]) shl 8);
    for bit := 0 to 7 do begin
      if (crc and $8000) <> 0 then
        crc := (crc shl 1) xor $8005
      else
        crc := crc shl 1;
    end;
  end;
  Result := crc;
end;

{ Build a silence MP3 frame with Xing/Info data embedded.
  Returns the complete frame bytes zero-padded to EncFrameBytes. }
function BuildXingFrame(const ACfg: TEncConfig; AChannels: Integer;
  const ATag: TXingTag): TBytes;
var
  FCfg      : TFrameConfig;
  SI        : TFrameSideInfo;
  BW        : TMP3BitWriter;
  frameBytes, xingOfs, pos: Integer;
begin
  frameBytes := EncFrameBytes(ACfg.BrIdx, ACfg.SrIdx, ACfg.Padding);

  FillChar(FCfg, SizeOf(FCfg), 0);
  FCfg.VersionBits     := FRAME_VER_MPEG1;
  FCfg.LayerBits       := FRAME_LAY_III;
  FCfg.ProtectionBit   := FRAME_NO_CRC;
  FCfg.BitrateIndex    := ACfg.BrIdx;
  FCfg.SamplerateIndex := ACfg.SrIdx;
  FCfg.Padding         := ACfg.Padding;
  FCfg.Original        := 1;
  FCfg.Granules        := ENC_GRANULES;
  if AChannels > 1 then begin
    FCfg.ChannelMode := FRAME_CH_JOINT;   { as the audio frames of the writers }
    FCfg.Channels    := 2;
  end else begin
    FCfg.ChannelMode := FRAME_CH_MONO;
    FCfg.Channels    := 1;
  end;
  FillChar(SI, SizeOf(SI), 0);

  BW := TMP3BitWriter.Create;
  try
    FrameWriteHeader(BW, FCfg);
    FrameWriteSideInfo(BW, FCfg, SI);
    FrameWriteMainData(BW, FCfg, SI);
    Result := BW.GetBytes;
  finally
    BW.Free;
  end;
  SetLength(Result, frameBytes);  { zero-pad the main-data area }

  xingOfs := XingDataOffset(AChannels);
  pos     := xingOfs;

  if ATag.IsVBR then begin
    Result[pos] := Ord('X'); Result[pos+1] := Ord('i');
    Result[pos+2] := Ord('n'); Result[pos+3] := Ord('g');
  end else begin
    Result[pos] := Ord('I'); Result[pos+1] := Ord('n');
    Result[pos+2] := Ord('f'); Result[pos+3] := Ord('o');
  end;
  Inc(pos, 4);

  WriteU32BE(Result, pos, Cardinal(ATag.Flags));
  Inc(pos, 4);

  if (ATag.Flags and XING_FLAG_FRAMES) <> 0 then begin
    WriteU32BE(Result, pos, ATag.FrameCount);
    Inc(pos, 4);
  end;
  if (ATag.Flags and XING_FLAG_BYTES) <> 0 then begin
    WriteU32BE(Result, pos, ATag.FileSize);
    Inc(pos, 4);
  end;
  if (ATag.Flags and XING_FLAG_TOC) <> 0 then begin
    Move(ATag.TOC[0], Result[pos], 100);
    Inc(pos, 100);
  end;
  if (ATag.Flags and XING_FLAG_QUALITY) <> 0 then
    WriteU32BE(Result, pos, ATag.Quality);
end;

// ---------------------------------------------------------------------------

procedure XingWriteFrame(AStream: TStream; const ACfg: TEncConfig;
  AChannels: Integer; const ATag: TXingTag);
var
  Frame     : TBytes;
  frameBytes: Integer;
begin
  Frame      := BuildXingFrame(ACfg, AChannels, ATag);
  frameBytes := EncFrameBytes(ACfg.BrIdx, ACfg.SrIdx, ACfg.Padding);
  AStream.WriteBuffer(Frame[0], frameBytes);
end;

// ---------------------------------------------------------------------------

function XingReadFrame(AStream: TStream; const ACfg: TEncConfig;
  AChannels: Integer; out ATag: TXingTag): Boolean;
var
  savedPos  : Int64;
  frameBytes, xingOfs, pos: Integer;
  Frame     : TBytes;
begin
  Result   := False;
  ATag     := Default(TXingTag);
  savedPos := AStream.Position;
  try
    frameBytes := EncFrameBytes(ACfg.BrIdx, ACfg.SrIdx, ACfg.Padding);
    if AStream.Size < frameBytes then Exit;

    AStream.Position := 0;
    SetLength(Frame, frameBytes);
    AStream.ReadBuffer(Frame[0], frameBytes);

    xingOfs := XingDataOffset(AChannels);

    if (Frame[xingOfs]   = Ord('X')) and (Frame[xingOfs+1] = Ord('i')) and
       (Frame[xingOfs+2] = Ord('n')) and (Frame[xingOfs+3] = Ord('g')) then
      ATag.IsVBR := True
    else if (Frame[xingOfs]   = Ord('I')) and (Frame[xingOfs+1] = Ord('n')) and
            (Frame[xingOfs+2] = Ord('f')) and (Frame[xingOfs+3] = Ord('o')) then
      ATag.IsVBR := False
    else
      Exit;

    pos        := xingOfs + 4;
    ATag.Flags := Frame[pos + 3];  { low byte of big-endian uint32 flags }
    Inc(pos, 4);

    if (ATag.Flags and XING_FLAG_FRAMES) <> 0 then begin
      ATag.FrameCount := ReadU32BE(Frame, pos);
      Inc(pos, 4);
    end;
    if (ATag.Flags and XING_FLAG_BYTES) <> 0 then begin
      ATag.FileSize := ReadU32BE(Frame, pos);
      Inc(pos, 4);
    end;
    if (ATag.Flags and XING_FLAG_TOC) <> 0 then begin
      Move(Frame[pos], ATag.TOC[0], 100);
      Inc(pos, 100);
    end;
    if (ATag.Flags and XING_FLAG_QUALITY) <> 0 then
      ATag.Quality := ReadU32BE(Frame, pos);

    Result := True;
  finally
    AStream.Position := savedPos;
  end;
end;

// ---------------------------------------------------------------------------
// LAME extension
// ---------------------------------------------------------------------------

const
  LAME_XING_AREA = 120;  { Xing data area size when all four flags are set }
  LAME_EXT_SIZE  = 36;   { LAME extension byte count (offsets 0..35) }

procedure LameWriteFrame(AStream: TStream; const ACfg: TEncConfig;
  AChannels: Integer; const AXing: TXingTag; const ALame: TLameTag);
var
  Frame      : TBytes;
  frameBytes : Integer;
  xingOfs    : Integer;
  lameOfs    : Integer;
  ForcedXing : TXingTag;
  crcLen     : Integer;
  tagCRC     : Word;
begin
  frameBytes := EncFrameBytes(ACfg.BrIdx, ACfg.SrIdx, ACfg.Padding);
  xingOfs    := XingDataOffset(AChannels);
  lameOfs    := xingOfs + LAME_XING_AREA;

  { Force all Xing flags so the Xing area is exactly LAME_XING_AREA bytes,
    placing the LAME extension at a fixed, predictable offset. }
  ForcedXing       := AXing;
  ForcedXing.Flags := AXing.Flags or XING_FLAG_FRAMES or XING_FLAG_BYTES
                    or XING_FLAG_TOC or XING_FLAG_QUALITY;

  Frame := BuildXingFrame(ACfg, AChannels, ForcedXing);

  { Write LAME extension only when there is enough room in the frame }
  if lameOfs + LAME_EXT_SIZE <= frameBytes then begin
    { Encoder string: "LAME3.100" (9 bytes) }
    Frame[lameOfs+ 0] := Ord('L'); Frame[lameOfs+ 1] := Ord('A');
    Frame[lameOfs+ 2] := Ord('M'); Frame[lameOfs+ 3] := Ord('E');
    Frame[lameOfs+ 4] := Ord('3'); Frame[lameOfs+ 5] := Ord('.');
    Frame[lameOfs+ 6] := Ord('1'); Frame[lameOfs+ 7] := Ord('0');
    Frame[lameOfs+ 8] := Ord('0');

    { Info tag revision 0 (high 4 bits) + VBR method (low 4 bits) }
    Frame[lameOfs+ 9] := ALame.VBRMethod and $0F;

    { Bytes 10..19 — lowpass, replay gain fields: already zero from BuildXingFrame }

    { Encoder delay (12 bits) and padding (12 bits) packed into 3 bytes }
    Frame[lameOfs+21] :=  (ALame.EncoderDelay  shr 4) and $FF;
    Frame[lameOfs+22] := ((ALame.EncoderDelay  and $0F) shl 4)
                      or  ((ALame.EncoderPadding shr 8) and $0F);
    Frame[lameOfs+23] :=   ALame.EncoderPadding and $FF;

    { Bytes 23..26 — misc, MP3 gain, preset: already zero }

    { Music length (big-endian 32-bit) }
    WriteU32BE(Frame, lameOfs + 28, ALame.MusicLength);

    { Bytes 31..32 — music CRC: zero }

    { Info tag CRC: CRC-16 of the first min(frameBytes, 190) bytes,
      with the CRC field (lameOfs+33..34) still = 0 }
    { CRC of every byte before the CRC field: 190 for stereo, 175 for mono }
    crcLen := lameOfs + 34;
    if crcLen > frameBytes then crcLen := frameBytes;
    tagCRC := CRC16Frame(Frame, crcLen);
    Frame[lameOfs+34] := tagCRC shr 8;
    Frame[lameOfs+35] := tagCRC and $FF;
  end;

  AStream.WriteBuffer(Frame[0], frameBytes);
end;

// ---------------------------------------------------------------------------

function LameReadFrame(AStream: TStream; const ACfg: TEncConfig;
  AChannels: Integer; out AXing: TXingTag; out ALame: TLameTag): Boolean;
var
  savedPos   : Int64;
  frameBytes : Integer;
  xingOfs    : Integer;
  lameOfs    : Integer;
  pos        : Integer;
  Frame      : TBytes;
begin
  Result   := False;
  AXing    := Default(TXingTag);
  ALame    := Default(TLameTag);
  savedPos := AStream.Position;
  try
    frameBytes := EncFrameBytes(ACfg.BrIdx, ACfg.SrIdx, ACfg.Padding);
    xingOfs    := XingDataOffset(AChannels);
    lameOfs    := xingOfs + LAME_XING_AREA;

    if AStream.Size < frameBytes then Exit;

    AStream.Position := 0;
    SetLength(Frame, frameBytes);
    AStream.ReadBuffer(Frame[0], frameBytes);

    { Parse Xing/Info magic }
    if (Frame[xingOfs]   = Ord('X')) and (Frame[xingOfs+1] = Ord('i')) and
       (Frame[xingOfs+2] = Ord('n')) and (Frame[xingOfs+3] = Ord('g')) then
      AXing.IsVBR := True
    else if (Frame[xingOfs]   = Ord('I')) and (Frame[xingOfs+1] = Ord('n')) and
            (Frame[xingOfs+2] = Ord('f')) and (Frame[xingOfs+3] = Ord('o')) then
      AXing.IsVBR := False
    else
      Exit;

    { Parse Xing fields }
    pos        := xingOfs + 4;
    AXing.Flags := Frame[pos + 3];
    Inc(pos, 4);
    if (AXing.Flags and XING_FLAG_FRAMES) <> 0 then begin
      AXing.FrameCount := ReadU32BE(Frame, pos); Inc(pos, 4);
    end;
    if (AXing.Flags and XING_FLAG_BYTES) <> 0 then begin
      AXing.FileSize := ReadU32BE(Frame, pos); Inc(pos, 4);
    end;
    if (AXing.Flags and XING_FLAG_TOC) <> 0 then begin
      Move(Frame[pos], AXing.TOC[0], 100); Inc(pos, 100);
    end;
    if (AXing.Flags and XING_FLAG_QUALITY) <> 0 then
      AXing.Quality := ReadU32BE(Frame, pos);

    { LAME extension requires enough space and the LAME magic }
    if lameOfs + LAME_EXT_SIZE > frameBytes then Exit;
    if (Frame[lameOfs]   <> Ord('L')) or (Frame[lameOfs+1] <> Ord('A')) or
       (Frame[lameOfs+2] <> Ord('M')) or (Frame[lameOfs+3] <> Ord('E')) then
      Exit;

    { Parse LAME fields }
    ALame.VBRMethod      := Frame[lameOfs+9] and $0F;
    ALame.EncoderDelay   := (Word(Frame[lameOfs+21]) shl 4)
                         or  (Frame[lameOfs+22] shr 4);
    ALame.EncoderPadding := (Word(Frame[lameOfs+22] and $0F) shl 8)
                         or  Frame[lameOfs+23];
    ALame.MusicLength    := ReadU32BE(Frame, lameOfs + 28);

    Result := True;
  finally
    AStream.Position := savedPos;
  end;
end;

end.
