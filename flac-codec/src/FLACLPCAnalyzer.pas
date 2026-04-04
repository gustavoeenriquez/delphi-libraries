unit FLACLPCAnalyzer;

{
  FLACLPCAnalyzer.pas - LPC analysis for FLAC encoding

  Provides:
    FLACFixedResiduals    — compute forward-difference residuals for fixed predictors
    FLACEstimateBitsAbs   — estimate residual compressibility (sum of |r|)
    FLACSelectBestFixed   — choose the fixed predictor order that minimizes residuals
    FLACAutocorr          — windowed autocorrelation (Welch window for bias)
    FLACLevinsonDurbin    — solve Yule-Walker equations for LPC coefficients
    FLACQuantizeCoeffs    — quantize floating-point coefficients to integers + shift
    FLACLPCComputeResiduals — apply integer LPC and compute residuals

  Predictor selection strategy (implemented here):
    1. Try all fixed orders 0-4; pick minimum |residual| sum.
    2. (Optional) Run LPC if allowed by config; use if better.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  Math,
  AudioTypes,
  FLACTypes;

// ---------------------------------------------------------------------------
// Fixed predictor residuals
// ---------------------------------------------------------------------------

// Compute forward-difference residuals for fixed predictor of given order.
// Samples[0..BlockSize-1] → Residuals[Order..BlockSize-1]  (first Order = warmup).
// Residuals must have BlockSize elements; the first Order are left unchanged.
procedure FLACFixedResiduals(
  Order    : Integer;
  BlockSize: Integer;
  Samples  : PInteger;
  Residuals: PInteger   // output: [Order..BlockSize-1]
);

// Sum of absolute values of residuals (used for predictor selection).
// Lower = more compressible.
function FLACEstimateBitsAbs(Residuals: PInteger; Count: Integer): Int64;

// Try all fixed orders 0-4; fill BestResiduals (BlockSize-BestOrder elements)
// and return the best order. BestResiduals must be pre-allocated to BlockSize.
function FLACSelectBestFixed(
  BlockSize    : Integer;
  Samples      : PInteger;
  BestResiduals: PInteger   // output: best residuals, starting from BestOrder
): Integer;

// ---------------------------------------------------------------------------
// LPC analysis
// ---------------------------------------------------------------------------

// Compute windowed autocorrelation coefficients R[0..Order].
// Uses a Welch window (parabolic taper) to reduce spectral leakage.
procedure FLACAutocorr(
  Samples  : PInteger;
  NSamples : Integer;
  Order    : Integer;
  R        : PDouble    // output: Order+1 values
);

// Levinson-Durbin algorithm: solve the Toeplitz autocorrelation system.
// R[0..Order]: autocorrelation (R[0] must be > 0).
// On success: Coeffs[0..Order-1] = reflection coefficients as float.
// Error: prediction error at this order.
// Returns False if the signal is degenerate (R[0]=0 or system unstable).
function FLACLevinsonDurbin(
  R      : PDouble;
  Order  : Integer;
  Coeffs : PDouble;   // output: Order float coefficients
  out Error: Double
): Boolean;

// Quantize float LPC coefficients to integers.
// Precision: desired coefficient bit width (8..15 bits signed).
// IntCoeffs[0..Order-1]: quantized integer coefficients.
// Shift: right-shift applied to the LPC sum before adding residual.
//        Negative shift means left-shift (unusual but valid).
procedure FLACQuantizeCoeffs(
  FloatCoeffs: PDouble;
  Order      : Integer;
  Precision  : Integer;
  IntCoeffs  : PSmallInt;  // output
  out Shift  : Integer
);

// Apply integer LPC forward prediction and compute residuals.
// Samples[0..Order-1]: warm-up. Residuals[0..BlockSize-Order-1]: output.
procedure FLACLPCComputeResiduals(
  Order    : Integer;
  BlockSize: Integer;
  Shift    : Integer;
  Coeffs   : PSmallInt;
  Samples  : PInteger;
  Residuals: PInteger  // BlockSize-Order elements
);

implementation

// ---------------------------------------------------------------------------
// Fixed predictor residuals
// ---------------------------------------------------------------------------

procedure FLACFixedResiduals(
  Order    : Integer;
  BlockSize: Integer;
  Samples  : PInteger;
  Residuals: PInteger
);
var
  I: Integer;
  S: PInteger;
  R: PInteger;
begin
  S := Samples  + Order;
  R := Residuals;

  case Order of
    0:
      for I := 0 to BlockSize - 1 do
      begin
        R^ := S^;
        Inc(S); Inc(R);
      end;
    1:
      for I := Order to BlockSize - 1 do
      begin
        R^ := S^ - (S-1)^;
        Inc(S); Inc(R);
      end;
    2:
      for I := Order to BlockSize - 1 do
      begin
        R^ := S^ - 2*(S-1)^ + (S-2)^;
        Inc(S); Inc(R);
      end;
    3:
      for I := Order to BlockSize - 1 do
      begin
        R^ := S^ - 3*(S-1)^ + 3*(S-2)^ - (S-3)^;
        Inc(S); Inc(R);
      end;
    4:
      for I := Order to BlockSize - 1 do
      begin
        R^ := S^ - 4*(S-1)^ + 6*(S-2)^ - 4*(S-3)^ + (S-4)^;
        Inc(S); Inc(R);
      end;
  end;
end;

function FLACEstimateBitsAbs(Residuals: PInteger; Count: Integer): Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Count - 1 do
  begin
    var V := (Residuals + I)^;
    if V >= 0 then Result := Result + V
    else Result := Result - V;
  end;
end;

function FLACSelectBestFixed(
  BlockSize    : Integer;
  Samples      : PInteger;
  BestResiduals: PInteger
): Integer;
var
  Order     : Integer;
  BestOrder : Integer;
  BestScore : Int64;
  Score     : Int64;
  TmpRes    : TArray<Integer>;
begin
  SetLength(TmpRes, BlockSize);
  BestOrder := 0;
  BestScore := High(Int64);

  for Order := 0 to FLAC_SUBFRAME_FIXED_MAX_ORDER do
  begin
    FLACFixedResiduals(Order, BlockSize, Samples, @TmpRes[0]);
    Score := FLACEstimateBitsAbs(@TmpRes[0], BlockSize - Order);
    if Score < BestScore then
    begin
      BestScore := Score;
      BestOrder := Order;
      // Copy residuals to output
      Move(TmpRes[0], BestResiduals^, (BlockSize - Order) * SizeOf(Integer));
    end;
  end;

  Result := BestOrder;
end;

// ---------------------------------------------------------------------------
// LPC autocorrelation
// ---------------------------------------------------------------------------

procedure FLACAutocorr(
  Samples  : PInteger;
  NSamples : Integer;
  Order    : Integer;
  R        : PDouble
);
var
  K, I    : Integer;
  Acc     : Double;
  WinFact : Double;
  WData   : TArray<Double>;
begin
  // Apply Welch window and store as float
  SetLength(WData, NSamples);
  for I := 0 to NSamples - 1 do
  begin
    WinFact := 1.0 - Sqr((I - (NSamples - 1) * 0.5) / ((NSamples + 1) * 0.5));
    WData[I] := (Samples + I)^ * WinFact;
  end;

  // Compute R[k] = sum_i(WData[i] * WData[i+k])
  for K := 0 to Order do
  begin
    Acc := 0.0;
    for I := 0 to NSamples - K - 1 do
      Acc := Acc + WData[I] * WData[I + K];
    (R + K)^ := Acc;
  end;
end;

// ---------------------------------------------------------------------------
// Levinson-Durbin
// ---------------------------------------------------------------------------

function FLACLevinsonDurbin(
  R      : PDouble;
  Order  : Integer;
  Coeffs : PDouble;
  out Error: Double
): Boolean;
var
  I, J   : Integer;
  Lambda : Double;
  Tmp    : TArray<Double>;
  PrevA  : TArray<Double>;
begin
  Result := False;
  Error  := 0;

  if (R + 0)^ <= 0 then Exit;
  Error := (R + 0)^;

  SetLength(Tmp,  Order + 1);
  SetLength(PrevA, Order + 1);
  FillChar(Tmp[0], (Order + 1) * SizeOf(Double), 0);

  for I := 1 to Order do
  begin
    // Compute reflection coefficient
    Lambda := 0;
    for J := 1 to I - 1 do
      Lambda := Lambda + PrevA[J] * (R + (I - J))^;
    Lambda := -((R + I)^ + Lambda) / Error;

    // Update coefficients
    Tmp[I] := Lambda;
    for J := 1 to I - 1 do
      Tmp[J] := PrevA[J] + Lambda * PrevA[I - J];

    // Update error
    Error := Error * (1.0 - Lambda * Lambda);
    if Error <= 0 then Exit;  // unstable

    // Keep this order's result
    Move(Tmp[0], PrevA[0], (Order + 1) * SizeOf(Double));
  end;

  // Copy to output (1-indexed internal → 0-indexed output)
  for I := 0 to Order - 1 do
    (Coeffs + I)^ := PrevA[I + 1];

  Result := True;
end;

// ---------------------------------------------------------------------------
// Coefficient quantization
// ---------------------------------------------------------------------------

procedure FLACQuantizeCoeffs(
  FloatCoeffs: PDouble;
  Order      : Integer;
  Precision  : Integer;
  IntCoeffs  : PSmallInt;
  out Shift  : Integer
);
var
  MaxCoeff: Double;
  I       : Integer;
  Scale   : Double;
  MaxInt  : Integer;
begin
  // Find the largest absolute value among coefficients
  MaxCoeff := 0;
  for I := 0 to Order - 1 do
    MaxCoeff := Max(MaxCoeff, Abs((FloatCoeffs + I)^));

  if MaxCoeff = 0 then
  begin
    for I := 0 to Order - 1 do (IntCoeffs + I)^ := 0;
    Shift := 0;
    Exit;
  end;

  // Compute shift so that max coefficient * 2^shift fits in Precision-1 bits
  MaxInt := (1 shl (Precision - 1)) - 1;

  // shift = ceil(log2(MaxCoeff)) - (Precision - 1) ... roughly
  // We want: MaxCoeff * 2^(-shift) <= MaxInt
  // → shift = ceil(log2(MaxCoeff / MaxInt))
  Shift := 0;
  Scale := MaxInt / MaxCoeff;

  // Find the integer shift: scale = 2^(-shift)
  while Scale >= 2.0 do begin Scale := Scale * 0.5; Inc(Shift); end;
  while (Scale < 1.0) and (Shift > -8) do begin Scale := Scale * 2.0; Dec(Shift); end;

  // Negate shift: FLAC uses right-shift convention (positive = right-shift)
  Shift := -Shift;

  // Quantize
  var QScale: Double;
  if Shift >= 0 then QScale := 1.0 / (1 shl Shift)
  else QScale := (1 shl (-Shift));

  for I := 0 to Order - 1 do
  begin
    var V := Round((FloatCoeffs + I)^ / QScale);
    if V >  MaxInt then V :=  MaxInt;
    if V < -MaxInt - 1 then V := -MaxInt - 1;
    (IntCoeffs + I)^ := SmallInt(V);
  end;
end;

// ---------------------------------------------------------------------------
// LPC residual computation
// ---------------------------------------------------------------------------

procedure FLACLPCComputeResiduals(
  Order    : Integer;
  BlockSize: Integer;
  Shift    : Integer;
  Coeffs   : PSmallInt;
  Samples  : PInteger;
  Residuals: PInteger
);
var
  I, J  : Integer;
  Acc   : Int64;
  S     : PInteger;
  R     : PInteger;
begin
  S := Samples  + Order;
  R := Residuals;

  for I := Order to BlockSize - 1 do
  begin
    Acc := 0;
    for J := 0 to Order - 1 do
      Acc := Acc + Int64((Coeffs + J)^) * Int64((S - 1 - J)^);

    if Shift >= 0 then
      R^ := S^ - Integer(Acc shr Shift)
    else
      R^ := S^ - Integer(Acc shl (-Shift));

    Inc(S); Inc(R);
  end;
end;

end.
