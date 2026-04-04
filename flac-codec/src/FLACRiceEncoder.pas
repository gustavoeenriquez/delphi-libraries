unit FLACRiceEncoder;

{
  FLACRiceEncoder.pas - Rice residual encoding for FLAC

  Provides:
    FLACSelectRiceParam  — find optimal Rice parameter k for a residual partition
    FLACWriteRicePartition — write one partition (Rice param header + samples)
    FLACWriteResiduals   — write the complete residual section of a subframe
                           (coding method + partition order + all partitions)

  Partition order selection: always uses order 0 (single partition) for
  BlockSize <= 64, otherwise tries orders 0..4 and picks the best.

  Coding method: always FLAC_RESIDUAL_RICE (4-bit parameter).
  Rice2 would only help for very high BPS signals (>20-bit), which is rare.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  AudioTypes,
  FLACTypes,
  FLACBitWriter;

// Select the optimal Rice parameter k for a residual block.
// Returns k in [0..14]; returns 0 if Count = 0.
function FLACSelectRiceParam(Residuals: PInteger; Count: Integer): Integer;

// Estimate the total encoded bits for Rice(k) over Count residuals.
// Used for partition order selection.
function FLACEstimateRiceBits(Residuals: PInteger; Count, K: Integer): Int64;

// Write one Rice-coded partition into BW.
// RiceParamBits: 4 for method 0 (Rice), 5 for method 1 (Rice2)
// K: Rice parameter (or escape param value for escape coding)
// If K = EscapeParam: writes an escape partition (raw BPS-wide samples).
procedure FLACWriteRicePartition(
  var BW          : TFLACBitWriter;
  RiceParamBits   : Integer;
  K               : Integer;
  EscapeParam     : Integer;
  BPS             : Integer;    // bits per sample (for escape raw width)
  Residuals       : PInteger;
  Count           : Integer
);

// Write the complete residual section of a subframe:
//   [2-bit coding method][4-bit partition order]
//   [partitions × (param + samples)]
// Selects partition order and Rice parameters automatically.
procedure FLACWriteResiduals(
  var BW       : TFLACBitWriter;
  WarmupCount  : Integer;  // predictor order = first partition adjustment
  BlockSize    : Integer;
  BPS          : Integer;
  Residuals    : PInteger  // BlockSize - WarmupCount values
);

implementation

uses
  Math;

// ---------------------------------------------------------------------------
// Rice parameter selection
// ---------------------------------------------------------------------------

function FLACSelectRiceParam(Residuals: PInteger; Count: Integer): Integer;
var
  SumAbs : Int64;
  I      : Integer;
  BestK  : Integer;
  BestBits: Int64;
  Bits   : Int64;
  K      : Integer;
begin
  if Count = 0 then Exit(0);

  SumAbs := 0;
  for I := 0 to Count - 1 do
  begin
    var V := (Residuals + I)^;
    if V >= 0 then SumAbs := SumAbs + V
    else SumAbs := SumAbs - V;
  end;

  // Quick estimate: k ≈ log2(mean_abs) - 1, clamped to 0..14
  var MeanAbs := SumAbs div Count;
  if MeanAbs = 0 then Exit(0);

  BestK    := 0;
  BestBits := High(Int64);

  // Try a range of k values around the estimate
  var KStart := 0;
  var KMid   := 0;
  if MeanAbs > 1 then
  begin
    var Tmp := MeanAbs;
    while Tmp > 1 do begin Tmp := Tmp shr 1; Inc(KMid); end;
    KStart := Max(0, KMid - 2);
  end;

  for K := KStart to Min(14, KStart + 5) do
  begin
    Bits := FLACEstimateRiceBits(Residuals, Count, K);
    if Bits < BestBits then
    begin
      BestBits := Bits;
      BestK    := K;
    end;
  end;

  Result := BestK;
end;

function FLACEstimateRiceBits(Residuals: PInteger; Count, K: Integer): Int64;
var
  I    : Integer;
  V, U : Integer;
  Q    : Integer;
begin
  Result := 0;
  for I := 0 to Count - 1 do
  begin
    V := (Residuals + I)^;
    // Zig-zag to unsigned
    if V >= 0 then U := V shl 1
    else U := ((-V) shl 1) - 1;
    Q := U shr K;
    // Bits = (Q + 1) unary + K remainder
    Result := Result + Int64(Q + 1) + K;
  end;
end;

// ---------------------------------------------------------------------------
// Write one partition
// ---------------------------------------------------------------------------

procedure FLACWriteRicePartition(
  var BW          : TFLACBitWriter;
  RiceParamBits   : Integer;
  K               : Integer;
  EscapeParam     : Integer;
  BPS             : Integer;
  Residuals       : PInteger;
  Count           : Integer
);
var
  I       : Integer;
  RawBits : Integer;
begin
  if K = EscapeParam then
  begin
    // Escape coding: write param + 5-bit raw width + raw samples.
    // Compute the actual signed bit width needed from the residuals, because
    // FIXED/LPC residuals can exceed the channel BPS (e.g. order-2 FIXED on a
    // square wave produces residuals up to 4*MaxVal which needs BPS+2 bits).
    BW.PushBits(EscapeParam, RiceParamBits);
    var MaxAbsV: Integer := 0;
    for I := 0 to Count - 1 do
    begin
      var V := (Residuals + I)^;
      if V < 0 then V := -V - 1;  // two's complement: -n needs same bits as n-1
      if V > MaxAbsV then MaxAbsV := V;
    end;
    RawBits := 1;  // at minimum 1 bit (sign)
    var TmpV := MaxAbsV;
    while TmpV > 0 do begin TmpV := TmpV shr 1; Inc(RawBits); end;
    if RawBits > 32 then RawBits := 32;
    BW.PushBits(RawBits, 5);
    for I := 0 to Count - 1 do
      BW.PushSigned((Residuals + I)^, RawBits);
  end
  else
  begin
    BW.PushBits(K, RiceParamBits);
    for I := 0 to Count - 1 do
      BW.PushRice((Residuals + I)^, K);
  end;
end;

// ---------------------------------------------------------------------------
// Write all residuals with automatic partition order selection
// ---------------------------------------------------------------------------

procedure FLACWriteResiduals(
  var BW       : TFLACBitWriter;
  WarmupCount  : Integer;
  BlockSize    : Integer;
  BPS          : Integer;
  Residuals    : PInteger
);
var
  ResCount     : Integer;
  BestOrder    : Integer;
  BestBits     : Int64;
  Order        : Integer;
  PartCount    : Integer;
  SampPerPart  : Integer;
  TotalBits    : Int64;
  P            : Integer;
  PartStart    : Integer;
  PartSamples  : Integer;
  K            : Integer;
begin
  ResCount := BlockSize - WarmupCount;

  // Select partition order (0..4) by minimum estimated bits
  BestOrder := 0;
  BestBits  := High(Int64);

  var MaxOrder := 0;
  if BlockSize >= 16 then MaxOrder := 1;
  if BlockSize >= 32 then MaxOrder := 2;
  if BlockSize >= 64 then MaxOrder := 3;
  if BlockSize >= 128 then MaxOrder := 4;

  for Order := 0 to MaxOrder do
  begin
    PartCount   := 1 shl Order;
    SampPerPart := BlockSize shr Order;
    if SampPerPart < WarmupCount then Continue;

    TotalBits := 0;
    for P := 0 to PartCount - 1 do
    begin
      if P = 0 then PartSamples := SampPerPart - WarmupCount
      else PartSamples := SampPerPart;
      if PartSamples <= 0 then Continue;

      PartStart := 0;
      if P > 0 then
        PartStart := P * SampPerPart - WarmupCount;

      K := FLACSelectRiceParam(Residuals + PartStart, PartSamples);
      TotalBits := TotalBits + FLACEstimateRiceBits(Residuals + PartStart, PartSamples, K)
                 + 4; // rice param field
    end;
    TotalBits := TotalBits + 4; // partition order field overhead

    if TotalBits < BestBits then
    begin
      BestBits  := TotalBits;
      BestOrder := Order;
    end;
  end;

  // Write: coding method (2 bits) + partition order (4 bits)
  BW.PushBits(FLAC_RESIDUAL_RICE, 2);    // method 0 = Rice
  BW.PushBits(BestOrder, 4);

  // Write each partition
  PartCount   := 1 shl BestOrder;
  SampPerPart := BlockSize shr BestOrder;

  for P := 0 to PartCount - 1 do
  begin
    if P = 0 then PartSamples := SampPerPart - WarmupCount
    else PartSamples := SampPerPart;
    if PartSamples <= 0 then Continue;

    PartStart := 0;
    if P > 0 then
      PartStart := P * SampPerPart - WarmupCount;

    K := FLACSelectRiceParam(Residuals + PartStart, PartSamples);

    // If Rice would be bigger than raw: use escape
    var RiceBits := FLACEstimateRiceBits(Residuals + PartStart, PartSamples, K);
    var RawBits  := Int64(PartSamples) * BPS;
    if RiceBits > RawBits then K := FLAC_RICE_ESCAPE_PARAM;

    FLACWriteRicePartition(BW, 4, K, FLAC_RICE_ESCAPE_PARAM, BPS,
                           Residuals + PartStart, PartSamples);
  end;
end;

end.
