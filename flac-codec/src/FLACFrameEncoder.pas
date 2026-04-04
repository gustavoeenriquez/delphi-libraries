unit FLACFrameEncoder;

{
  FLACFrameEncoder.pas - FLAC audio frame encoder

  Encodes a single block of integer samples into a complete FLAC frame
  (header + subframes + byte-alignment + CRC-16 footer).

  Predictor strategy per channel:
    1. Try all fixed orders 0-4; pick the one with minimum |residual| sum.
    2. If Config.MaxLPCOrder > 0: run LPC and use it if it beats fixed.
    3. If all predictors result in more bits than verbatim: use VERBATIM.
    4. Constant subframe: if all samples are identical.

  Stereo inter-channel decorrelation:
    The encoder tries left/right, left+side, right+side, and mid+side,
    then picks whichever two-channel encoding gives the fewest bits.
    For non-stereo, channels are encoded independently.

  Entry point: FLACEncodeFrame

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  SysUtils, Math,
  AudioTypes,
  AudioCRC,
  FLACTypes,
  FLACBitWriter,
  FLACRiceEncoder,
  FLACLPCAnalyzer;

// ---------------------------------------------------------------------------
// Encoder configuration
// ---------------------------------------------------------------------------

type
  TFLACEncConfig = record
    MaxLPCOrder  : Integer;  // 0 = fixed only; 1..12 = LPC up to this order
    QLPPrecision : Integer;  // LPC coefficient precision (8..15); 0 = auto (10)
    TryStereoModes: Boolean; // Try L/S, R/S, M/S for stereo (default True)
  end;

// Default configuration (fast, good compression)
function FLACDefaultConfig: TFLACEncConfig;

// ---------------------------------------------------------------------------
// Encode one frame
// ---------------------------------------------------------------------------

// Encode BlockSize integer samples per channel into a FLAC frame.
// Samples[Ch][0..BlockSize-1]: integer PCM in [-2^(BPS-1) .. 2^(BPS-1)-1].
// FrameNum: 0-based frame index (fixed blocking strategy).
// SampleRate: passed through to the frame header.
// BPS: bits per sample (8..24).
// Returns False only if parameters are invalid.
function FLACEncodeFrame(
  const Config   : TFLACEncConfig;
  const SI       : TFLACStreamInfo;
  FrameNum       : Integer;
  Samples        : array of TArray<Integer>;   // [channel][sample_index]
  BlockSize      : Integer;
  out FrameData  : TBytes
): Boolean;

implementation

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Write a UTF-8 encoded integer (frame number, up to 31 bits → 6 bytes).
procedure WriteUTF8Int(var BW: TFLACBitWriter; V: Cardinal);
begin
  if V < $80 then
    BW.PushBits(V, 8)
  else if V < $800 then
  begin
    BW.PushBits($C0 or (V shr 6), 8);
    BW.PushBits($80 or (V and $3F), 8);
  end
  else if V < $10000 then
  begin
    BW.PushBits($E0 or (V shr 12), 8);
    BW.PushBits($80 or ((V shr 6) and $3F), 8);
    BW.PushBits($80 or (V and $3F), 8);
  end
  else if V < $200000 then
  begin
    BW.PushBits($F0 or (V shr 18), 8);
    BW.PushBits($80 or ((V shr 12) and $3F), 8);
    BW.PushBits($80 or ((V shr 6) and $3F), 8);
    BW.PushBits($80 or (V and $3F), 8);
  end
  else if V < $4000000 then
  begin
    BW.PushBits($F8 or (V shr 24), 8);
    BW.PushBits($80 or ((V shr 18) and $3F), 8);
    BW.PushBits($80 or ((V shr 12) and $3F), 8);
    BW.PushBits($80 or ((V shr 6) and $3F), 8);
    BW.PushBits($80 or (V and $3F), 8);
  end
  else
  begin
    BW.PushBits($FC or (V shr 30), 8);
    BW.PushBits($80 or ((V shr 24) and $3F), 8);
    BW.PushBits($80 or ((V shr 18) and $3F), 8);
    BW.PushBits($80 or ((V shr 12) and $3F), 8);
    BW.PushBits($80 or ((V shr 6) and $3F), 8);
    BW.PushBits($80 or (V and $3F), 8);
  end;
end;

// ---------------------------------------------------------------------------
// Subframe encoding
// ---------------------------------------------------------------------------

// Returns estimated bit count for a VERBATIM subframe
function VerbatimBits(BlockSize, BPS: Integer): Int64;
begin
  // 8-bit subframe header + BlockSize * BPS
  Result := 8 + Int64(BlockSize) * BPS;
end;

// Encode a CONSTANT subframe (all samples = ConstVal)
procedure EncodeConstantSubframe(var BW: TFLACBitWriter; ConstVal, BPS: Integer);
begin
  BW.PushBit(0);          // padding bit
  BW.PushBits(FLAC_SUBFRAME_CONSTANT, 6);
  BW.PushBit(0);          // no wasted bits
  BW.PushSigned(ConstVal, BPS);
end;

// Encode a VERBATIM subframe
procedure EncodeVerbatimSubframe(var BW: TFLACBitWriter; Samples: PInteger;
  BlockSize, BPS: Integer);
var
  I: Integer;
begin
  BW.PushBit(0);
  BW.PushBits(FLAC_SUBFRAME_VERBATIM, 6);
  BW.PushBit(0);
  for I := 0 to BlockSize - 1 do
    BW.PushSigned((Samples + I)^, BPS);
end;

// Encode a FIXED subframe with given order
procedure EncodeFixedSubframe(var BW: TFLACBitWriter; Order, BlockSize, BPS: Integer;
  Samples, Residuals: PInteger);
var
  I: Integer;
begin
  BW.PushBit(0);
  BW.PushBits(FLAC_SUBFRAME_FIXED_BASE + Cardinal(Order), 6);
  BW.PushBit(0);
  // Warm-up samples
  for I := 0 to Order - 1 do
    BW.PushSigned((Samples + I)^, BPS);
  // Residuals
  FLACWriteResiduals(BW, Order, BlockSize, BPS, Residuals);
end;

// Encode an LPC subframe
procedure EncodeLPCSubframe(var BW: TFLACBitWriter; Order, BlockSize, BPS: Integer;
  QLPPrec, QLPShift: Integer; Coeffs: PSmallInt;
  Samples, Residuals: PInteger);
var
  I: Integer;
begin
  BW.PushBit(0);
  BW.PushBits(FLAC_SUBFRAME_LPC_BASE + Cardinal(Order) - 1, 6);
  BW.PushBit(0);
  // Warm-up samples
  for I := 0 to Order - 1 do
    BW.PushSigned((Samples + I)^, BPS);
  // LPC precision (4 bits: value = precision - 1)
  BW.PushBits(QLPPrec - 1, 4);
  // Quantization shift (5-bit signed)
  BW.PushSigned(QLPShift, 5);
  // Coefficients
  for I := 0 to Order - 1 do
    BW.PushSigned((Coeffs + I)^, QLPPrec);
  // Residuals
  FLACWriteResiduals(BW, Order, BlockSize, BPS, Residuals);
end;

// Encode one channel subframe, choosing the best predictor.
// BW must be the target bit writer. Returns estimated bits written.
procedure EncodeBestSubframe(
  var BW          : TFLACBitWriter;
  const Config    : TFLACEncConfig;
  Samples         : PInteger;
  BlockSize, BPS  : Integer
);
var
  AllSame  : Boolean;
  ConstVal : Integer;
  I        : Integer;
  FixRes   : TArray<Integer>;
  FixOrder : Integer;
  FixBits  : Int64;
  VerbBits : Int64;
  LPCOrder : Integer;
  LPCBest  : Integer;
  LPCBits  : Int64;
  R        : TArray<Double>;
  FCoeffs  : TArray<Double>;
  ICoeffs  : array[0..31] of SmallInt;
  Shift    : Integer;
  LPCRes   : TArray<Integer>;
  LPCErr   : Double;
  UseLPC   : Boolean;
  LPCPrec  : Integer;
  BWTmp    : TFLACBitWriter;
begin
  // ---- Check for CONSTANT ----
  AllSame  := True;
  ConstVal := Samples^;
  for I := 1 to BlockSize - 1 do
    if (Samples + I)^ <> ConstVal then begin AllSame := False; Break; end;

  if AllSame then
  begin
    EncodeConstantSubframe(BW, ConstVal, BPS);
    Exit;
  end;

  // ---- Best fixed predictor ----
  SetLength(FixRes, BlockSize);
  FixOrder := FLACSelectBestFixed(BlockSize, Samples, @FixRes[0]);
  BWTmp.Init;
  EncodeFixedSubframe(BWTmp, FixOrder, BlockSize, BPS, Samples, @FixRes[0]);
  FixBits  := BWTmp.BitCount;
  VerbBits := VerbatimBits(BlockSize, BPS);

  // ---- Optional LPC ----
  UseLPC := False;
  LPCBits := High(Int64);
  LPCBest := 0;
  LPCPrec := Config.QLPPrecision;
  if LPCPrec <= 0 then LPCPrec := 10;
  SetLength(LPCRes, BlockSize);
  SetLength(R, Config.MaxLPCOrder + 2);
  SetLength(FCoeffs, Config.MaxLPCOrder + 2);

  if Config.MaxLPCOrder > 0 then
  begin
    FLACAutocorr(Samples, BlockSize, Config.MaxLPCOrder, @R[0]);
    if R[0] > 0 then
    begin
      for LPCOrder := 1 to Config.MaxLPCOrder do
      begin
        if not FLACLevinsonDurbin(@R[0], LPCOrder, @FCoeffs[0], LPCErr) then Continue;
        FLACQuantizeCoeffs(@FCoeffs[0], LPCOrder, LPCPrec, @ICoeffs[0], Shift);
        FLACLPCComputeResiduals(LPCOrder, BlockSize, Shift, @ICoeffs[0], Samples, @LPCRes[0]);
        BWTmp.Init;
        EncodeLPCSubframe(BWTmp, LPCOrder, BlockSize, BPS, LPCPrec, Shift,
                          @ICoeffs[0], Samples, @LPCRes[0]);
        var Bits := BWTmp.BitCount;
        if Bits < LPCBits then
        begin
          LPCBits := Bits;
          LPCBest := LPCOrder;
        end;
      end;
      UseLPC := (LPCBits < FixBits) and (LPCBits < VerbBits);
    end;
  end;

  // ---- Choose and write the best subframe ----
  if UseLPC then
  begin
    // Re-compute for the best LPC order
    FLACLevinsonDurbin(@R[0], LPCBest, @FCoeffs[0], LPCErr);
    FLACQuantizeCoeffs(@FCoeffs[0], LPCBest, LPCPrec, @ICoeffs[0], Shift);
    FLACLPCComputeResiduals(LPCBest, BlockSize, Shift, @ICoeffs[0], Samples, @LPCRes[0]);
    EncodeLPCSubframe(BW, LPCBest, BlockSize, BPS, LPCPrec, Shift,
                      @ICoeffs[0], Samples, @LPCRes[0]);
  end
  else if FixBits <= VerbBits then
    EncodeFixedSubframe(BW, FixOrder, BlockSize, BPS, Samples, @FixRes[0])
  else
    EncodeVerbatimSubframe(BW, Samples, BlockSize, BPS);
end;

// ---------------------------------------------------------------------------
// Stereo inter-channel encoding
// ---------------------------------------------------------------------------

// Compute side = left - right channel.
procedure ComputeSide(Left, Right, Side: PInteger; N: Integer);
var I: Integer;
begin
  for I := 0 to N - 1 do
    (Side + I)^ := (Left + I)^ - (Right + I)^;
end;

// Compute mid = floor((left + right) / 2)  — arithmetic right shift by 1.
// Delphi's 'shr' is a logical (unsigned) shift; for negative sums it fills the
// sign bit with 0, producing large positive garbage.  We propagate the MSB
// explicitly: result = (unsigned_sum >> 1) | sign_bit.
procedure ComputeMid(Left, Right, Mid: PInteger; N: Integer);
var
  I  : Integer;
  SC : Cardinal;
begin
  for I := 0 to N - 1 do
  begin
    SC := Cardinal((Left + I)^ + (Right + I)^);
    (Mid + I)^ := Integer((SC shr 1) or (SC and $80000000));
  end;
end;

// Estimate total bits for a two-channel encoding by running EncodeBestSubframe
// on both channels and summing.
function EstimateStereoBytes(
  const Config: TFLACEncConfig;
  Ch0, Ch1: PInteger; BlockSize, BPS: Integer): Int64;
var
  BW0, BW1: TFLACBitWriter;
  Cap: Integer;
begin
  // Pre-allocate generously so BW0/BW1 never reallocate during estimation.
  // This prevents heap-reallocation pressure from interfering with caller's
  // dynamic arrays (MidData, SideData) between stereo-mode estimation calls.
  Cap := BlockSize * ((BPS + 7) div 8) * 4;
  if Cap < 4096 then Cap := 4096;
  BW0.Init(Cap);
  BW1.Init(Cap);
  EncodeBestSubframe(BW0, Config, Ch0, BlockSize, BPS);
  EncodeBestSubframe(BW1, Config, Ch1, BlockSize, BPS);
  Result := BW0.BitCount + BW1.BitCount;
end;

// ---------------------------------------------------------------------------
// Frame encoder
// ---------------------------------------------------------------------------

function FLACDefaultConfig: TFLACEncConfig;
begin
  Result.MaxLPCOrder   := 8;
  Result.QLPPrecision  := 10;
  Result.TryStereoModes := True;
end;

function FLACEncodeFrame(
  const Config   : TFLACEncConfig;
  const SI       : TFLACStreamInfo;
  FrameNum       : Integer;
  Samples        : array of TArray<Integer>;
  BlockSize      : Integer;
  out FrameData  : TBytes
): Boolean;
var
  Channels     : Integer;
  BPS          : Integer;
  BWHdr        : TFLACBitWriter;   // frame header
  BWSubframes  : TFLACBitWriter;   // subframes
  BWFull       : TFLACBitWriter;   // combined
  BsCode       : Integer;
  SrCode       : Integer;
  ChannelAssign: Integer;
  BpsCode      : Integer;
  I            : Integer;
  HdrBytes     : TBytes;
  HdrCRC8      : Byte;

  // Stereo mode selection
  SideData     : TArray<Integer>;
  MidData      : TArray<Integer>;
  BitsLL, BitsLS, BitsRS, BitsMS: Int64;

  // Per-channel data pointers for encoding
  ChData       : array[0..7] of PInteger;

  procedure FinalizeFrame;
  var
    AllBytes    : TBytes;
    AllLen      : Integer;
    FrameCRC16  : Word;
  begin
    // Combine header + subframes
    BWFull.Init(BWHdr.ByteCount + BWSubframes.ByteCount + 4);
    HdrBytes := BWHdr.GetBytes;
    BWFull.PushBits(0, 0);  // just init

    AllLen := 0;
    SetLength(AllBytes, BWHdr.ByteCount + BWSubframes.ByteCount + 4);

    var HdrB := BWHdr.GetBytes;
    Move(HdrB[0], AllBytes[AllLen], Length(HdrB));
    Inc(AllLen, Length(HdrB));
    var SfB := BWSubframes.GetBytes;
    Move(SfB[0], AllBytes[AllLen], Length(SfB));
    Inc(AllLen, Length(SfB));

    // CRC-16 over everything so far
    FrameCRC16 := CRC16_Calc(@AllBytes[0], AllLen);
    AllBytes[AllLen]     := Byte(FrameCRC16 shr 8);
    AllBytes[AllLen + 1] := Byte(FrameCRC16 and $FF);
    Inc(AllLen, 2);

    SetLength(FrameData, AllLen);
    Move(AllBytes[0], FrameData[0], AllLen);
  end;

begin
  Result := False;
  if Length(Samples) = 0 then Exit;
  if BlockSize <= 0 then Exit;

  Channels := Length(Samples);
  BPS      := SI.BitsPerSample;

  // Validate
  if (Channels < 1) or (Channels > 8) then Exit;
  if (BPS < 4) or (BPS > 32) then Exit;

  // ---- Stereo mode selection ----
  ChannelAssign := Channels - 1;  // default: independent

  if Config.TryStereoModes and (Channels = 2) then
  begin
    SetLength(SideData, BlockSize);
    SetLength(MidData,  BlockSize);

    ComputeSide(@Samples[0][0], @Samples[1][0], @SideData[0], BlockSize);
    ComputeMid (@Samples[0][0], @Samples[1][0], @MidData[0],  BlockSize);

    // Estimate bits for each stereo mode (side channel gets BPS+1)
    BitsLL := EstimateStereoBytes(Config, @Samples[0][0], @Samples[1][0], BlockSize, BPS);
    BitsLS := EstimateStereoBytes(Config, @Samples[0][0], @SideData[0],   BlockSize, BPS + 1);
    BitsRS := EstimateStereoBytes(Config, @SideData[0],   @Samples[1][0], BlockSize, BPS + 1);
    BitsMS := EstimateStereoBytes(Config, @MidData[0],    @SideData[0],   BlockSize, BPS + 1);

    var BestBits := BitsLL;
    ChannelAssign := 1;  // independent stereo

    if BitsLS < BestBits then begin BestBits := BitsLS; ChannelAssign := FLAC_CHANASSIGN_LEFT_SIDE; end;
    if BitsRS < BestBits then begin BestBits := BitsRS; ChannelAssign := FLAC_CHANASSIGN_RIGHT_SIDE; end;
    if BitsMS < BestBits then begin ChannelAssign := FLAC_CHANASSIGN_MID_SIDE; end;
  end;

  // Set up channel data pointers based on assignment
  for I := 0 to Channels - 1 do
    ChData[I] := @Samples[I][0];

  if ChannelAssign = FLAC_CHANASSIGN_LEFT_SIDE then
    ChData[1] := @SideData[0]
  else if ChannelAssign = FLAC_CHANASSIGN_RIGHT_SIDE then
    ChData[0] := @SideData[0]
  else if ChannelAssign = FLAC_CHANASSIGN_MID_SIDE then
  begin
    ChData[0] := @MidData[0];
    ChData[1] := @SideData[0];
  end;

  // ---- Build frame header ----
  BWHdr.Init(32);

  // Sync code + blocking strategy (fixed = 0)
  BWHdr.PushBits($FF, 8);
  BWHdr.PushBits($F8, 8);

  // Block size code
  BsCode := 0;
  if      BlockSize = 192  then BsCode := 1
  else if BlockSize = 576  then BsCode := 2
  else if BlockSize = 1152 then BsCode := 3
  else if BlockSize = 2304 then BsCode := 4
  else if BlockSize = 4608 then BsCode := 5
  else if BlockSize <= 256 then BsCode := 6
  else BsCode := 7;

  // Sample rate code
  SrCode := 0;
  case SI.SampleRate of
    88200: SrCode := 1;  176400: SrCode := 2;  192000: SrCode := 3;
    8000:  SrCode := 4;  16000:  SrCode := 5;  22050:  SrCode := 6;
    24000: SrCode := 7;  32000:  SrCode := 8;  44100:  SrCode := 9;
    48000: SrCode := 10; 96000:  SrCode := 11;
  else SrCode := 0;
  end;

  BWHdr.PushBits(BsCode, 4);
  BWHdr.PushBits(SrCode, 4);

  // Channel assignment code | BPS code | reserved 0
  case BPS of
    8:  BpsCode := 1; 12: BpsCode := 2;
    16: BpsCode := 4; 20: BpsCode := 5;
    24: BpsCode := 6; 32: BpsCode := 7;
  else BpsCode := 0;
  end;
  BWHdr.PushBits(ChannelAssign, 4);
  BWHdr.PushBits(BpsCode, 3);
  BWHdr.PushBit(0);  // reserved

  // Frame number (UTF-8)
  WriteUTF8Int(BWHdr, FrameNum);

  // Optional block size bytes
  if BsCode = 6 then BWHdr.PushBits(BlockSize - 1, 8)
  else if BsCode = 7 then BWHdr.PushBits(BlockSize - 1, 16);

  // CRC-8 of header so far
  var HdrSoFar := BWHdr.GetBytes;
  HdrCRC8 := CRC8_Calc(@HdrSoFar[0], Length(HdrSoFar));
  BWHdr.PushBits(HdrCRC8, 8);

  // ---- Encode subframes ----
  BWSubframes.Init(BlockSize * Channels * (BPS div 8) + 64);

  for I := 0 to Channels - 1 do
  begin
    var ChBPS := BPS;
    if ChannelAssign = FLAC_CHANASSIGN_LEFT_SIDE  then begin if I = 1 then Inc(ChBPS); end
    else if ChannelAssign = FLAC_CHANASSIGN_RIGHT_SIDE then begin if I = 0 then Inc(ChBPS); end
    else if ChannelAssign = FLAC_CHANASSIGN_MID_SIDE   then begin if I = 1 then Inc(ChBPS); end;

    EncodeBestSubframe(BWSubframes, Config, ChData[I], BlockSize, ChBPS);
  end;

  // Byte-align subframes
  BWSubframes.ByteAlign;

  // ---- Assemble and add CRC-16 ----
  FinalizeFrame;
  Result := True;
end;

end.
