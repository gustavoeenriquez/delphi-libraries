unit FLACPredictor;

{
  FLACPredictor.pas - FLAC fixed and LPC predictor restoration

  Converts residuals + warm-up samples back into the original PCM signal.

  Two predictor types:
    Fixed (order 0-4): closed-form finite-difference predictors
    LPC   (order 1-32): quantized linear predictive coding coefficients

  All arithmetic is on Int32/Int64 (samples are up to 24-bit, coefficients
  up to 16-bit signed; LPC accumulator must be 64-bit to avoid overflow).

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

// ---------------------------------------------------------------------------
// Fixed predictor restoration
// ---------------------------------------------------------------------------
//
// Fills Samples[Order..BlockSize-1] using the fixed predictor of given order.
// Samples[0..Order-1] must already contain the warm-up samples.
// Residuals[0..BlockSize-Order-1] are added to the predicted values.
//
// Fixed predictor equations (FLAC spec §11.3.1):
//   order 0: predicted = 0
//   order 1: predicted = s[i-1]
//   order 2: predicted = 2*s[i-1] - s[i-2]
//   order 3: predicted = 3*s[i-1] - 3*s[i-2] + s[i-3]
//   order 4: predicted = 4*s[i-1] - 6*s[i-2] + 4*s[i-3] - s[i-4]
//
procedure FLACFixedRestore(
  Order     : Integer;        // 0..4
  BlockSize : Integer;
  Samples   : PInteger;       // in-out: warm-up in [0..Order-1], filled for [Order..]
  Residuals : PInteger        // input: BlockSize - Order values
);

// ---------------------------------------------------------------------------
// LPC predictor restoration
// ---------------------------------------------------------------------------
//
// Fills Samples[Order..BlockSize-1].
// Samples[0..Order-1] must already contain the warm-up samples.
//
// Prediction:
//   predicted = sum(i=0..Order-1: Coeffs[i] * Samples[n-1-i]) >> QLPShift
//   Samples[n] = Residuals[n-Order] + predicted
//
// QLPShift can be negative (left shift), per FLAC spec §11.3.2.
//
procedure FLACLPCRestore(
  Order     : Integer;        // 1..32
  BlockSize : Integer;
  QLPShift  : Integer;        // quantization level (signed; right-shift amount)
  Coeffs    : PSmallInt;      // LPC coefficients [0..Order-1], signed 16-bit
  Samples   : PInteger;
  Residuals : PInteger
);

implementation

// ---------------------------------------------------------------------------
// Fixed predictor
// ---------------------------------------------------------------------------

procedure FLACFixedRestore(
  Order     : Integer;
  BlockSize : Integer;
  Samples   : PInteger;
  Residuals : PInteger
);
var
  I    : Integer;
  Pred : Integer;
  S    : PInteger;
  R    : PInteger;
begin
  S := Samples  + Order;
  R := Residuals;

  case Order of
    0:
      for I := 0 to BlockSize - 1 do
      begin
        S^ := R^;
        Inc(S); Inc(R);
      end;

    1:
      for I := Order to BlockSize - 1 do
      begin
        Pred := (S - 1)^;
        S^   := R^ + Pred;
        Inc(S); Inc(R);
      end;

    2:
      for I := Order to BlockSize - 1 do
      begin
        Pred := 2 * (S-1)^ - (S-2)^;
        S^   := R^ + Pred;
        Inc(S); Inc(R);
      end;

    3:
      for I := Order to BlockSize - 1 do
      begin
        Pred := 3 * (S-1)^ - 3 * (S-2)^ + (S-3)^;
        S^   := R^ + Pred;
        Inc(S); Inc(R);
      end;

    4:
      for I := Order to BlockSize - 1 do
      begin
        Pred := 4 * (S-1)^ - 6 * (S-2)^ + 4 * (S-3)^ - (S-4)^;
        S^   := R^ + Pred;
        Inc(S); Inc(R);
      end;
  end;
end;

// ---------------------------------------------------------------------------
// LPC predictor
// ---------------------------------------------------------------------------

procedure FLACLPCRestore(
  Order     : Integer;
  BlockSize : Integer;
  QLPShift  : Integer;
  Coeffs    : PSmallInt;
  Samples   : PInteger;
  Residuals : PInteger
);
var
  I, J    : Integer;
  Acc     : Int64;
  S       : PInteger;
  R       : PInteger;
  CPtr    : PSmallInt;
begin
  S := Samples  + Order;
  R := Residuals;

  for I := Order to BlockSize - 1 do
  begin
    Acc  := 0;
    CPtr := Coeffs;
    for J := 0 to Order - 1 do
    begin
      Acc  := Acc + Int64(CPtr^) * Int64((S - 1 - J)^);
      Inc(CPtr);
    end;

    if QLPShift >= 0 then
      S^ := R^ + Integer(Acc shr QLPShift)
    else
      S^ := R^ + Integer(Acc shl (-QLPShift));

    Inc(S); Inc(R);
  end;
end;

end.
