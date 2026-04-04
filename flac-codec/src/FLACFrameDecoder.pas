unit FLACFrameDecoder;

{
  FLACFrameDecoder.pas - FLAC frame and subframe decoder

  Decodes one FLAC audio frame from a byte buffer into a TAudioBuffer.

  A FLAC frame is self-contained:
    Frame header  (variable size, ends with CRC-8)
    Per-channel subframes (CONSTANT / VERBATIM / FIXED / LPC)
    Bit alignment padding
    Frame footer  CRC-16 (covers entire frame including header)

  Entry point:
    FLACDecodeFrame(Buf, BufLen, StreamInfo, out Header, out Buffer, out FrameBytes)

  The caller is responsible for:
    - Locating the frame sync bytes (0xFF 0xF8 or 0xFF 0xF9)
    - Passing the buffer starting at the sync byte
    - Advancing the stream/buffer by FrameBytes after a successful decode

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  SysUtils,
  AudioTypes,
  AudioBitReader,
  AudioCRC,
  AudioSampleConv,
  FLACTypes,
  FLACBitReader,
  FLACRiceCoder,
  FLACPredictor;

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

// Decode one frame starting at Buf[0].
// On success:
//   Header     receives the parsed frame header
//   Buffer     receives the decoded samples (planar Single [-1..1])
//   FrameBytes receives the exact number of bytes consumed
// Returns True on success; False on sync error, CRC mismatch, or bad data.
//
// StreamInfo is used to supply defaults when header codes defer to STREAMINFO
// (sample rate code 0, BPS code 0).
function FLACDecodeFrame(
  Buf       : PByte;
  BufLen    : Integer;
  const StreamInfo: TFLACStreamInfo;
  out Header    : TFLACFrameHeader;
  out Buffer    : TAudioBuffer;
  out FrameBytes: Integer
): Boolean;

implementation

// ---------------------------------------------------------------------------
// Block size table (codes 2..5 and 8..15 from FLAC spec)
// ---------------------------------------------------------------------------

function DecodeBlockSizeCode(Code: Integer): Integer;
begin
  case Code of
    1:     Result := 192;
    2..5:  Result := 576 shl (Code - 2);
    8..15: Result := 256 shl (Code - 8);
  else
    Result := -1;  // caller must handle codes 0, 6, 7 specially
  end;
end;

// ---------------------------------------------------------------------------
// Sample rate table (codes 1..11 from FLAC spec)
// ---------------------------------------------------------------------------

function DecodeSampleRateCode(Code: Integer): Integer;
begin
  case Code of
     1: Result := 88200;
     2: Result := 176400;
     3: Result := 192000;
     4: Result := 8000;
     5: Result := 16000;
     6: Result := 22050;
     7: Result := 24000;
     8: Result := 32000;
     9: Result := 44100;
    10: Result := 48000;
    11: Result := 96000;
  else
    Result := -1;  // 0 = from STREAMINFO, 12/13/14 = read from stream, 15 = invalid
  end;
end;

// ---------------------------------------------------------------------------
// Parse frame header. BytePos advances byte-by-byte; CRC-8 covers everything
// up to (but not including) the CRC-8 byte itself.
// ---------------------------------------------------------------------------

function ParseFrameHeader(
  Buf       : PByte;
  BufLen    : Integer;
  const SI  : TFLACStreamInfo;
  out Hdr   : TFLACFrameHeader;
  out HdrBytes: Integer
): Boolean;
var
  Crc8     : Byte;
  BytePos  : Integer;
  B0, B1   : Byte;
  B2, B3   : Byte;
  BsCode   : Integer;
  SrCode   : Integer;
  BpsCode  : Integer;
  BlockSize: Integer;
  SampleRate: Integer;
  BPS      : Integer;
  SnOK     : Boolean;
  Sn       : Int64;
  HdrCrc   : Byte;
begin
  Result   := False;
  HdrBytes := 0;
  FillChar(Hdr, SizeOf(Hdr), 0);

  if BufLen < 6 then Exit;

  // ---- Sync: bytes 0-1 ----
  B0 := Buf^;
  B1 := (Buf+1)^;
  if B0 <> FLAC_SYNC_BYTE0 then Exit;
  if (B1 <> FLAC_SYNC_BYTE1_FIXED) and (B1 <> FLAC_SYNC_BYTE1_VARIABLE) then Exit;

  Hdr.BlockingStrategy := B1 and $01;

  // ---- Byte 2: block size (4 bits) | sample rate (4 bits) ----
  B2     := (Buf+2)^;
  BsCode := (B2 shr 4) and $0F;
  SrCode :=  B2         and $0F;

  // ---- Byte 3: channel assignment (4 bits) | BPS (3 bits) | reserved(1) ----
  B3 := (Buf+3)^;
  Hdr.ChannelAssignment := (B3 shr 4) and $0F;
  BpsCode               := (B3 shr 1) and $07;
  if (B3 and $01) <> 0 then Exit;  // reserved bit must be 0

  // Channel count from assignment code
  if Hdr.ChannelAssignment <= FLAC_CHANASSIGN_INDEPENDENT_MAX then
    Hdr.Channels := Hdr.ChannelAssignment + 1
  else if Hdr.ChannelAssignment in [FLAC_CHANASSIGN_LEFT_SIDE,
                                     FLAC_CHANASSIGN_RIGHT_SIDE,
                                     FLAC_CHANASSIGN_MID_SIDE] then
    Hdr.Channels := 2
  else
    Exit;  // reserved assignment

  // ---- BPS from code ----
  BPS := 0;
  if BpsCode = FLAC_BPS_STREAMINFO then
    BPS := SI.BitsPerSample
  else if BpsCode in [1..7] then
  begin
    BPS := FLAC_BPS_TABLE[BpsCode];
    if BPS = 0 then Exit;  // reserved (code 3)
  end
  else
    Exit;
  Hdr.BitsPerSample := BPS;

  // ---- CRC-8 start: covers bytes 0..N-1 where byte N is the CRC ----
  // We accumulate as we go. Bytes 0-3 first.
  Crc8    := CRC8_Init;
  BytePos := 0;
  Crc8    := CRC8_Update(Crc8, Buf + BytePos, 4);
  BytePos := 4;

  // ---- UTF-8 sample/frame number (variable, 1-7 bytes) ----
  SnOK := FLACReadUTF8Int(Buf, BytePos, BufLen - 2, Sn);  // -2: leave room for CRC+trailer
  if not SnOK then Exit;
  // Update CRC for the UTF-8 bytes consumed
  Crc8 := CRC8_Update(Crc8, Buf + 4, BytePos - 4);
  Hdr.SampleOrFrameNumber := Sn;

  // ---- Optional: extra block size (if BsCode = 6 or 7) ----
  BlockSize := DecodeBlockSizeCode(BsCode);
  if BsCode = 6 then
  begin
    if BytePos >= BufLen - 1 then Exit;
    BlockSize := (Buf + BytePos)^ + 1;
    Crc8 := CRC8_Update(Crc8, Buf + BytePos, 1);
    Inc(BytePos);
  end
  else if BsCode = 7 then
  begin
    if BytePos + 1 >= BufLen - 1 then Exit;
    var Hi := (Buf + BytePos)^;
    var Lo := (Buf + BytePos + 1)^;
    BlockSize := Integer(Hi shl 8 or Lo) + 1;
    Crc8 := CRC8_Update(Crc8, Buf + BytePos, 2);
    Inc(BytePos, 2);
  end
  else if BlockSize < 0 then
    Exit;  // code 0 = reserved

  Hdr.BlockSize := BlockSize;

  // ---- Optional: extra sample rate (if SrCode = 12/13/14) ----
  SampleRate := DecodeSampleRateCode(SrCode);
  if SrCode = 0 then
    SampleRate := SI.SampleRate
  else if SrCode = FLAC_SAMPLERATE_8BIT_KHZ then
  begin
    if BytePos >= BufLen - 1 then Exit;
    SampleRate := (Buf + BytePos)^ * 1000;
    Crc8 := CRC8_Update(Crc8, Buf + BytePos, 1);
    Inc(BytePos);
  end
  else if SrCode = FLAC_SAMPLERATE_16BIT_HZ then
  begin
    if BytePos + 1 >= BufLen - 1 then Exit;
    var Hi := (Buf + BytePos)^;
    var Lo := (Buf + BytePos + 1)^;
    SampleRate := Integer(Hi shl 8 or Lo);
    Crc8 := CRC8_Update(Crc8, Buf + BytePos, 2);
    Inc(BytePos, 2);
  end
  else if SrCode = FLAC_SAMPLERATE_16BIT_TENHZ then
  begin
    if BytePos + 1 >= BufLen - 1 then Exit;
    var Hi := (Buf + BytePos)^;
    var Lo := (Buf + BytePos + 1)^;
    SampleRate := Integer(Hi shl 8 or Lo) * 10;
    Crc8 := CRC8_Update(Crc8, Buf + BytePos, 2);
    Inc(BytePos, 2);
  end
  else if SrCode = 15 then
    Exit  // invalid
  else if SampleRate < 0 then
    Exit;

  Hdr.SampleRate := SampleRate;

  // ---- CRC-8 byte ----
  if BytePos >= BufLen then Exit;
  HdrCrc := (Buf + BytePos)^;
  Inc(BytePos);

  if Crc8 <> HdrCrc then Exit;
  Hdr.CRC8 := HdrCrc;

  HdrBytes := BytePos;
  Result   := True;
end;

// ---------------------------------------------------------------------------
// Decode one subframe into Samples[] (Int32 array, BlockSize elements)
// ---------------------------------------------------------------------------

function DecodeSubframe(
  var Br       : TAudioBitReader;
  BlockSize    : Integer;
  BPS          : Integer;
  Samples      : PInteger
): Boolean;
var
  HeaderBit    : Cardinal;
  TypeCode     : Cardinal;
  WastedFlag   : Cardinal;
  WastedBits   : Integer;
  SubType      : TFLACSubframeType;
  Order        : Integer;
  I            : Integer;
  CodingMethod : Integer;
  PartOrder    : Integer;
  LPCPrec      : Integer;
  LPCShift     : Integer;
  Coeffs       : array[0..31] of SmallInt;
  Residuals    : TArray<Integer>;
  EffBPS       : Integer;
begin
  Result := False;

  // ---- Subframe header: 1 zero bit + 6-bit type + 1-bit wasted-bits flag ----
  HeaderBit := FBrRead(Br, 1);
  if HeaderBit <> 0 then Exit;  // padding bit must be 0

  TypeCode  := FBrRead(Br, 6);
  WastedFlag:= FBrRead(Br, 1);

  WastedBits := 0;
  if WastedFlag = 1 then
  begin
    // Unary-encoded wasted bits: count leading 0s, the terminating 1 is already consumed
    // Actually per spec: read unary value k; wasted bits = k + 1
    WastedBits := Integer(BrReadUnary(Br)) + 1;
  end;

  EffBPS := BPS - WastedBits;
  if EffBPS <= 0 then Exit;

  // ---- Determine subframe type ----
  if TypeCode = FLAC_SUBFRAME_CONSTANT then
    SubType := sfConstant
  else if TypeCode = FLAC_SUBFRAME_VERBATIM then
    SubType := sfVerbatim
  else if (TypeCode >= FLAC_SUBFRAME_FIXED_BASE) and
          (TypeCode <= FLAC_SUBFRAME_FIXED_BASE + FLAC_SUBFRAME_FIXED_MAX_ORDER) then
  begin
    SubType := sfFixed;
    Order   := TypeCode - FLAC_SUBFRAME_FIXED_BASE;
  end
  else if TypeCode >= FLAC_SUBFRAME_LPC_BASE then
  begin
    SubType := sfLPC;
    Order   := TypeCode - FLAC_SUBFRAME_LPC_BASE + 1;
  end
  else
    Exit;  // reserved type code

  // ---- Decode based on type ----
  case SubType of

    sfConstant:
    begin
      var ConstVal := FBrReadSigned(Br, EffBPS);
      for I := 0 to BlockSize - 1 do
        (Samples + I)^ := ConstVal;
    end;

    sfVerbatim:
    begin
      for I := 0 to BlockSize - 1 do
        (Samples + I)^ := FBrReadSigned(Br, EffBPS);
    end;

    sfFixed:
    begin
      if Order > BlockSize then Exit;
      // Read warm-up samples
      for I := 0 to Order - 1 do
        (Samples + I)^ := FBrReadSigned(Br, EffBPS);

      // Residual coding method and partition order
      CodingMethod := Integer(FBrRead(Br, 2));
      PartOrder    := Integer(FBrRead(Br, 4));

      SetLength(Residuals, BlockSize - Order);
      if not FLACDecodeResiduals(Br, CodingMethod, PartOrder,
          Order, BlockSize, @Residuals[0], Length(Residuals)) then
        Exit;

      FLACFixedRestore(Order, BlockSize, Samples, @Residuals[0]);
    end;

    sfLPC:
    begin
      if Order > BlockSize then Exit;
      // Read warm-up samples
      for I := 0 to Order - 1 do
        (Samples + I)^ := FBrReadSigned(Br, EffBPS);

      // LPC coefficient precision (4 bits + 1 = 1..16; 0b1111 = invalid)
      LPCPrec := Integer(FBrRead(Br, 4)) + 1;
      if LPCPrec = 16 then Exit;  // 0b1111 + 1 = 16 reserved (spec says 0b0000 invalid, but +1 → 1..16 where 0b1111=15+1=16 is invalid)
      // Actually: 4-bit value = qlp_coeff_precision - 1, 0b0000=invalid
      // Re-read: the raw 4-bit value; if = 0b1111 invalid
      // Let me re-check: LPCPrec was already computed as raw+1; raw 0b1111 = 15 → +1 = 16 invalid
      // This is correct.

      // Quantization level (5-bit signed)
      LPCShift := FBrReadSigned(Br, 5);

      // LPC coefficients
      for I := 0 to Order - 1 do
        Coeffs[I] := SmallInt(FBrReadSigned(Br, LPCPrec));

      // Residual coding
      CodingMethod := Integer(FBrRead(Br, 2));
      PartOrder    := Integer(FBrRead(Br, 4));

      SetLength(Residuals, BlockSize - Order);
      if not FLACDecodeResiduals(Br, CodingMethod, PartOrder,
          Order, BlockSize, @Residuals[0], Length(Residuals)) then
        Exit;

      FLACLPCRestore(Order, BlockSize, LPCShift, @Coeffs[0], Samples, @Residuals[0]);
    end;
  end;

  // Apply wasted bits left-shift
  if WastedBits > 0 then
    for I := 0 to BlockSize - 1 do
      (Samples + I)^ := (Samples + I)^ shl WastedBits;

  Result := True;
end;

// ---------------------------------------------------------------------------
// Channel decorrelation for stereo difference modes
// ---------------------------------------------------------------------------

procedure DecorrelateChannels(
  Assignment : Integer;
  BlockSize  : Integer;
  Ch0        : PInteger;   // in-out
  Ch1        : PInteger    // in-out
);
var
  I    : Integer;
  Mid  : Integer;
  Side : Integer;
  Mid2 : Integer;
begin
  case Assignment of
    FLAC_CHANASSIGN_LEFT_SIDE:
      // ch0 = left, ch1 = side = left - right  →  right = left - side
      for I := 0 to BlockSize - 1 do
        (Ch1 + I)^ := (Ch0 + I)^ - (Ch1 + I)^;

    FLAC_CHANASSIGN_RIGHT_SIDE:
      // ch0 = side = left - right, ch1 = right  →  left = side + right
      for I := 0 to BlockSize - 1 do
        (Ch0 + I)^ := (Ch0 + I)^ + (Ch1 + I)^;

    FLAC_CHANASSIGN_MID_SIDE:
      // ch0 = mid = (left+right) >> 1, ch1 = side = left - right
      // Decode: mid2 = (mid << 1) | (side & 1)
      //         left = (mid2 + side) >> 1
      //         right = (mid2 - side) >> 1
      for I := 0 to BlockSize - 1 do
      begin
        Mid  := (Ch0 + I)^;
        Side := (Ch1 + I)^;
        Mid2 := (Mid shl 1) or (Side and 1);
        var SumL := Mid2 + Side;
        var SumR := Mid2 - Side;
        // Arithmetic right shift via sign-bit propagation (Delphi shr is logical)
        (Ch0 + I)^ := Integer((Cardinal(SumL) shr 1) or (Cardinal(SumL) and $80000000));
        (Ch1 + I)^ := Integer((Cardinal(SumR) shr 1) or (Cardinal(SumR) and $80000000));
      end;
  end;
end;

// ---------------------------------------------------------------------------
// FLACDecodeFrame — public entry point
// ---------------------------------------------------------------------------

function FLACDecodeFrame(
  Buf       : PByte;
  BufLen    : Integer;
  const StreamInfo: TFLACStreamInfo;
  out Header    : TFLACFrameHeader;
  out Buffer    : TAudioBuffer;
  out FrameBytes: Integer
): Boolean;
var
  HdrBytes   : Integer;
  Br         : TAudioBitReader;
  ChSamples  : array[0..7] of TArray<Integer>;
  Ch         : Integer;
  EffBPS     : Integer;
  FrameCRC16 : Word;
  FileCRC16  : Word;
  BytesUsed  : Integer;
  Scale      : Single;
  Frame, I   : Integer;
begin
  Result     := False;
  FrameBytes := 0;
  FillChar(Header, SizeOf(Header), 0);
  Buffer := nil;

  // Parse frame header
  if not ParseFrameHeader(Buf, BufLen, StreamInfo, Header, HdrBytes) then
    Exit;

  // Initialize bit reader starting right after the frame header
  BrInit(Br, Buf + HdrBytes, BufLen - HdrBytes, boMSBFirst);

  // Allocate per-channel integer sample buffers
  for Ch := 0 to Header.Channels - 1 do
    SetLength(ChSamples[Ch], Header.BlockSize);

  // Decode each subframe
  for Ch := 0 to Header.Channels - 1 do
  begin
    // Effective BPS for this channel: side channel gets +1 bit in difference modes
    EffBPS := Header.BitsPerSample;
    if Header.ChannelAssignment = FLAC_CHANASSIGN_LEFT_SIDE  then
    begin
      if Ch = 1 then Inc(EffBPS);
    end
    else if Header.ChannelAssignment = FLAC_CHANASSIGN_RIGHT_SIDE then
    begin
      if Ch = 0 then Inc(EffBPS);
    end
    else if Header.ChannelAssignment = FLAC_CHANASSIGN_MID_SIDE then
    begin
      if Ch = 1 then Inc(EffBPS);
    end;

    if not DecodeSubframe(Br, Header.BlockSize, EffBPS, @ChSamples[Ch][0]) then
      Exit;
  end;

  // Zero-bit padding to byte boundary
  BrByteAlign(Br);

  // Channel decorrelation
  if Header.Channels = 2 then
    DecorrelateChannels(
      Header.ChannelAssignment,
      Header.BlockSize,
      @ChSamples[0][0],
      @ChSamples[1][0]
    );

  // ---- CRC-16 check ----
  // The CRC covers everything from the first sync byte to just before the CRC-16
  BytesUsed := HdrBytes + (Br.Pos shr 3);  // header + subframe bytes
  if BytesUsed + 2 > BufLen then Exit;

  FrameCRC16 := CRC16_Calc(Buf, BytesUsed);
  FileCRC16  := Word((Buf + BytesUsed)^) shl 8 or (Buf + BytesUsed + 1)^;
  if FrameCRC16 <> FileCRC16 then Exit;

  FrameBytes := BytesUsed + 2;

  // ---- Convert to TAudioBuffer (planar Single [-1..1]) ----
  SetLength(Buffer, Header.Channels);
  Scale := 1.0 / Single(Int64(1) shl (Header.BitsPerSample - 1));

  for Ch := 0 to Header.Channels - 1 do
  begin
    SetLength(Buffer[Ch], Header.BlockSize);
    for Frame := 0 to Header.BlockSize - 1 do
      Buffer[Ch][Frame] := ChSamples[Ch][Frame] * Scale;
  end;

  Result := True;
end;

end.
