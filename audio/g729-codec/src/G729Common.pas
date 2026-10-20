unit G729Common;

{
  G729Common.pas - Shared parts of the G.729 / G.729A codec

  Written from the text of Recommendation ITU-T G.729 (06/2012), main body
  clauses 3 and 4 and Annex A, in floating point (as allowed by Annex C):
    - bit-stream layout (Table 8) and pitch parity (3.7.2, 4.1.2)
    - LSF decoding: two-stage codebook, rearrangement, switched MA
      prediction, stability check (3.2.4) and LSP -> LP conversion (3.2.6)
    - adaptive-codebook interpolation with b30 (equation 40)
    - fixed-codebook index/sign coding (3.8.2) and MA gain prediction (3.9)
  Numeric codebooks come from G729Tables (see that unit for their origin).

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

const
  G729_FRAME = 80;            // samples per 10 ms frame (8 kHz)
  G729_SUBFR = 40;            // samples per subframe
  G729_ORDER = 10;            // LP order
  G729_PIT_MIN = 20;
  G729_PIT_MAX = 143;
  G729_INTERP = 10;           // half length of the b30 interpolation
  G729_FRAME_BYTES = 10;      // 80 bits
  G729_SID_BYTES = 2;         // Annex B SID frame (15 bits)
  G729_SAMPLE_RATE = 8000;

type
  TLpc = array[0..G729_ORDER] of Double;      // a(0) = 1
  TLsf = array[0..G729_ORDER - 1] of Double;  // radians, also used for LSP (cosine domain)

  // Transmitted parameters of one speech frame (Table 8)
  TG729Params = record
    L0, L1, L2, L3: Integer;
    P1, P0: Integer;
    C1, S1, GA1, GB1: Integer;
    P2: Integer;
    C2, S2, GA2, GB2: Integer;
  end;

  // Switched-MA predictive LSF quantizer state (shared by encoder and decoder)
  TG729LsfState = record
    PrevL: array[0..3] of TLsf;   // l^(m-1) .. l^(m-4)
    LastMode: Integer;            // L0 of the last good frame
    procedure Init;
    procedure Push(const L: TLsf);
  end;

  // MA prediction of the fixed-codebook gain (3.9.1)
  TG729GainPredictor = record
    PastU: array[0..3] of Double; // U^(m-1) .. U^(m-4), dB
    procedure Init;
    function PredictedGain(const Code: array of Double): Double;  // g'c, equation (71)
    procedure Push(U: Double);
    procedure PushErased;                                           // equation (95)
  end;

procedure UnpackFrame(Data: PByte; out P: TG729Params);
procedure PackFrame(const P: TG729Params; Data: PByte);
function PitchParity(P1: Integer): Integer;

procedure LsfRearrange(var L: TLsf; J: Double);
procedure LsfStabilize(var W: TLsf);
// LSF reconstruction from the codebook indices; updates the MA memory
procedure LsfDecode(var St: TG729LsfState; L0, L1, L2, L3: Integer; out W: TLsf);
// Erased frame: keep W, recompute the codeword for the MA memory (equation 92)
procedure LsfConceal(var St: TG729LsfState; const W: TLsf);
procedure LsfToLsp(const W: TLsf; out Q: TLsf);
procedure LspToLp(const Q: TLsf; out A: TLpc);
// LP -> LSF (3.2.3): roots of F1/F2 by grid search and bisection; False if not all found
function LpToLsf(const A: TLpc; out W: TLsf): Boolean;

// v(n) = u(n - k + t/3) interpolated with b30 (equation 40). Exc points at u(0);
// samples are generated in place so that delays below 40 reuse new samples.
procedure AdaptiveVector(Exc: PDouble; K, T: Integer);
// Integer and fractional pitch parts -> (k, t) used by AdaptiveVector
procedure PitchToKT(IntT, Frac: Integer; out K, T: Integer);

procedure DecodeFixedCodebook(C, S: Integer; out Code: array of Double);
procedure DecodePitch1(P1: Integer; out IntT, Frac: Integer);
procedure DecodePitch2(P2, IntT1: Integer; out IntT, Frac: Integer);
procedure PitchRange2(IntT1: Integer; out TMin, TMax: Integer);
procedure DecodeGains(GA, GB: Integer; out Gp, Gamma: Double);

// Fixed-point friendly constant tables converted once to floating point
var
  B30: array[0..30] of Double;

implementation

uses
  Math, G729Tables;

{ Bit stream }

type
  TBitWriter = record
    Data: PByte;
    Pos: Integer;
    procedure Put(Value, Bits: Integer);
  end;

  TBitReader = record
    Data: PByte;
    Pos: Integer;
    function Get(Bits: Integer): Integer;
  end;

procedure TBitWriter.Put(Value, Bits: Integer);
var
  I: Integer;
  P: PByte;
begin
  for I := Bits - 1 downto 0 do
  begin
    P := Data + Pos shr 3;
    if (Value shr I) and 1 <> 0 then
      P^ := P^ or (128 shr (Pos and 7));
    Inc(Pos);
  end;
end;

function TBitReader.Get(Bits: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Bits do
  begin
    Result := (Result shl 1) or (((Data + Pos shr 3)^ shr (7 - Pos and 7)) and 1);
    Inc(Pos);
  end;
end;

procedure UnpackFrame(Data: PByte; out P: TG729Params);
var
  R: TBitReader;
begin
  R.Data := Data; R.Pos := 0;
  P.L0 := R.Get(1); P.L1 := R.Get(7); P.L2 := R.Get(5); P.L3 := R.Get(5);
  P.P1 := R.Get(8); P.P0 := R.Get(1);
  P.C1 := R.Get(13); P.S1 := R.Get(4); P.GA1 := R.Get(3); P.GB1 := R.Get(4);
  P.P2 := R.Get(5);
  P.C2 := R.Get(13); P.S2 := R.Get(4); P.GA2 := R.Get(3); P.GB2 := R.Get(4);
end;

procedure PackFrame(const P: TG729Params; Data: PByte);
var
  W: TBitWriter;
begin
  FillChar(Data^, G729_FRAME_BYTES, 0);
  W.Data := Data; W.Pos := 0;
  W.Put(P.L0, 1); W.Put(P.L1, 7); W.Put(P.L2, 5); W.Put(P.L3, 5);
  W.Put(P.P1, 8); W.Put(P.P0, 1);
  W.Put(P.C1, 13); W.Put(P.S1, 4); W.Put(P.GA1, 3); W.Put(P.GB1, 4);
  W.Put(P.P2, 5);
  W.Put(P.C2, 13); W.Put(P.S2, 4); W.Put(P.GA2, 3); W.Put(P.GB2, 4);
end;

// Parity of the six most significant bits of the 8-bit index P1
function PitchParity(P1: Integer): Integer;
var
  I: Integer;
begin
  Result := 1;
  for I := 2 to 7 do
    Result := Result xor ((P1 shr I) and 1);
end;

{ LSF quantizer }

procedure TG729LsfState.Init;
var
  K, I: Integer;
begin
  for K := 0 to 3 do
    for I := 0 to G729_ORDER - 1 do
      PrevL[K][I] := (I + 1) * Pi / 11;
  LastMode := 0;
end;

procedure TG729LsfState.Push(const L: TLsf);
begin
  PrevL[3] := PrevL[2];
  PrevL[2] := PrevL[1];
  PrevL[1] := PrevL[0];
  PrevL[0] := L;
end;

procedure LsfRearrange(var L: TLsf; J: Double);
var
  I: Integer;
  A, B: Double;
begin
  for I := 1 to G729_ORDER - 1 do
    if L[I - 1] > L[I] - J then
    begin
      A := L[I - 1]; B := L[I];
      L[I - 1] := (B + A - J) / 2;
      L[I] := (B + A + J) / 2;
    end;
end;

procedure LsfStabilize(var W: TLsf);
var
  I, J: Integer;
  T: Double;
begin
  // 1) increasing order
  for I := 1 to G729_ORDER - 1 do
  begin
    T := W[I];
    J := I - 1;
    while (J >= 0) and (W[J] > T) do
    begin
      W[J + 1] := W[J];
      Dec(J);
    end;
    W[J + 1] := T;
  end;
  // 2..4) bounds and minimum distance
  if W[0] < 0.005 then W[0] := 0.005;
  for I := 0 to G729_ORDER - 2 do
    if W[I + 1] - W[I] < 0.0391 then W[I + 1] := W[I] + 0.0391;
  if W[G729_ORDER - 1] > 3.135 then W[G729_ORDER - 1] := 3.135;
end;

// Weighted sum of the current codeword and the MA memory (equation 20)
procedure LsfPredict(const St: TG729LsfState; Mode: Integer; const L: TLsf; out W: TLsf);
var
  I, K: Integer;
begin
  for I := 0 to G729_ORDER - 1 do
  begin
    W[I] := MA_PRED_SUM[Mode][I] / 32768 * L[I];
    for K := 0 to 3 do
      W[I] := W[I] + MA_PRED[Mode][K][I] / 32768 * St.PrevL[K][I];
  end;
end;

procedure LsfDecode(var St: TG729LsfState; L0, L1, L2, L3: Integer; out W: TLsf);
var
  L: TLsf;
  I: Integer;
begin
  for I := 0 to 4 do
    L[I] := (LSPCB1[L1][I] + LSPCB2[L2][I]) / 8192;
  for I := 5 to 9 do
    L[I] := (LSPCB1[L1][I] + LSPCB2[L3][I]) / 8192;
  LsfRearrange(L, 0.0012);
  LsfRearrange(L, 0.0006);
  LsfPredict(St, L0, L, W);
  St.Push(L);
  St.LastMode := L0;
  LsfStabilize(W);
end;

procedure LsfConceal(var St: TG729LsfState; const W: TLsf);
var
  L: TLsf;
  I, K: Integer;
  S: Double;
begin
  for I := 0 to G729_ORDER - 1 do
  begin
    S := W[I];
    for K := 0 to 3 do
      S := S - MA_PRED[St.LastMode][K][I] / 32768 * St.PrevL[K][I];
    L[I] := S / (MA_PRED_SUM[St.LastMode][I] / 32768);
  end;
  St.Push(L);
end;

procedure LsfToLsp(const W: TLsf; out Q: TLsf);
var
  I: Integer;
begin
  for I := 0 to G729_ORDER - 1 do
    Q[I] := Cos(W[I]);
end;

// Coefficients f(0..5) of F1 (Odd = 0: q1,q3,..) or F2 (Odd = 1: q2,q4,..)
procedure LspPoly(const Q: TLsf; Odd: Integer; out F: array of Double);
var
  I, J: Integer;
  B: Double;
begin
  F[0] := 1;
  F[1] := -2 * Q[Odd];
  for I := 2 to 5 do
  begin
    B := -2 * Q[2 * (I - 1) + Odd];
    F[I] := B * F[I - 1] + 2 * F[I - 2];
    for J := I - 1 downto 2 do
      F[J] := F[J] + B * F[J - 1] + F[J - 2];
    F[1] := F[1] + B;
  end;
end;

procedure LspToLp(const Q: TLsf; out A: TLpc);
var
  F1, F2: array[0..5] of Double;
  I: Integer;
  P1, P2: Double;
begin
  LspPoly(Q, 0, F1);
  LspPoly(Q, 1, F2);
  A[0] := 1;
  for I := 1 to 5 do
  begin
    P1 := F1[I] + F1[I - 1];   // F1(z)(1 + z^-1)
    P2 := F2[I] - F2[I - 1];   // F2(z)(1 - z^-1)
    A[I] := 0.5 * (P1 + P2);
    A[11 - I] := 0.5 * (P1 - P2);
  end;
end;

// Chebyshev evaluation of F1 or F2 at x = cos(w) (equations 16, 17)
function ChebEval(const F: array of Double; X: Double): Double;
var
  B0, B1, B2: Double;
  K: Integer;
begin
  B2 := 0;      // b6
  B1 := 1;      // b5
  for K := 4 downto 1 do
  begin
    B0 := 2 * X * B1 - B2 + F[5 - K];
    B2 := B1;
    B1 := B0;
  end;
  Result := X * B1 - B2 + F[5] / 2;
end;

function LpToLsf(const A: TLpc; out W: TLsf): Boolean;
const
  GRID = 100;
var
  F1, F2: array[0..5] of Double;
  I, J, Found, Iter: Integer;
  X0, X1, Y0, Y1, XM, YM: Double;
  Poly: Integer;
begin
  F1[0] := 1; F2[0] := 1;
  for I := 0 to 4 do
  begin
    F1[I + 1] := A[I + 1] + A[G729_ORDER - I] - F1[I];
    F2[I + 1] := A[I + 1] - A[G729_ORDER - I] + F2[I];
  end;
  Found := 0;
  Poly := 0;
  X0 := 1;
  Y0 := ChebEval(F1, X0);
  J := 1;
  while (J <= GRID) and (Found < G729_ORDER) do
  begin
    X1 := Cos(Pi * J / GRID);
    if Poly = 0 then Y1 := ChebEval(F1, X1) else Y1 := ChebEval(F2, X1);
    if (Y0 * Y1 <= 0) and not ((Y0 = 0) and (Y1 = 0)) then
    begin
      for Iter := 1 to 40 do
      begin
        XM := 0.5 * (X0 + X1);
        if Poly = 0 then YM := ChebEval(F1, XM) else YM := ChebEval(F2, XM);
        if Y0 * YM <= 0 then X1 := XM
        else begin X0 := XM; Y0 := YM; end;
      end;
      XM := 0.5 * (X0 + X1);
      W[Found] := ArcCos(EnsureRange(XM, -1, 1));
      Inc(Found);
      Poly := 1 - Poly;
      // restart the scan of the other polynomial from the root
      X0 := XM;
      if Poly = 0 then Y0 := ChebEval(F1, X0) else Y0 := ChebEval(F2, X0);
      Continue;     // re-test the same grid interval for the other polynomial
    end;
    X0 := X1; Y0 := Y1;
    Inc(J);
  end;
  Result := Found = G729_ORDER;
end;

{ Adaptive codebook }

procedure PitchToKT(IntT, Frac: Integer; out K, T: Integer);
begin
  // delay IntT + Frac/3 = K - T/3 with T in 0..2
  if Frac > 0 then begin K := IntT + 1; T := 3 - Frac; end
  else begin K := IntT; T := -Frac; end;
end;

procedure AdaptiveVector(Exc: PDouble; K, T: Integer);
var
  N, I: Integer;
  S: Double;
begin
  for N := 0 to G729_SUBFR - 1 do
  begin
    S := 0;
    for I := 0 to 9 do
    begin
      S := S + Exc[N - K - I] * B30[T + 3 * I];
      S := S + Exc[N - K + 1 + I] * B30[3 - T + 3 * I];
    end;
    Exc[N] := S;
  end;
end;

procedure DecodePitch1(P1: Integer; out IntT, Frac: Integer);
begin
  if P1 < 197 then
  begin
    IntT := (P1 + 2) div 3 + 19;
    Frac := P1 - 3 * IntT + 58;
  end
  else
  begin
    IntT := P1 - 112;
    Frac := 0;
  end;
end;

procedure PitchRange2(IntT1: Integer; out TMin, TMax: Integer);
begin
  TMin := IntT1 - 5;
  if TMin < G729_PIT_MIN then TMin := G729_PIT_MIN;
  TMax := TMin + 9;
  if TMax > G729_PIT_MAX then
  begin
    TMax := G729_PIT_MAX;
    TMin := TMax - 9;
  end;
end;

procedure DecodePitch2(P2, IntT1: Integer; out IntT, Frac: Integer);
var
  TMin, TMax, Q: Integer;
begin
  PitchRange2(IntT1, TMin, TMax);
  Q := (P2 + 2) div 3 - 1;
  IntT := Q + TMin;
  Frac := P2 - 2 - 3 * Q;
end;

{ Fixed codebook }

procedure DecodeFixedCodebook(C, S: Integer; out Code: array of Double);
var
  Pos: array[0..3] of Integer;
  I: Integer;
begin
  for I := 0 to G729_SUBFR - 1 do Code[I] := 0;
  Pos[0] := 5 * (C and 7);
  Pos[1] := 5 * ((C shr 3) and 7) + 1;
  Pos[2] := 5 * ((C shr 6) and 7) + 2;
  Pos[3] := 5 * ((C shr 10) and 7) + 3 + ((C shr 9) and 1);
  for I := 0 to 3 do
    if (S shr I) and 1 <> 0 then Code[Pos[I]] := 1
    else Code[Pos[I]] := -1;
end;

{ Gains }

procedure DecodeGains(GA, GB: Integer; out Gp, Gamma: Double);
var
  I, J: Integer;
begin
  I := GA_IMAP[GA];
  J := GB_IMAP[GB];
  Gp := (GAIN_GA[I][0] + GAIN_GB[J][0]) / 16384;
  Gamma := (GAIN_GA[I][1] + GAIN_GB[J][1]) / 8192;
end;

const
  MA_GAIN: array[0..3] of Double = (0.68, 0.58, 0.34, 0.19);
  MEAN_ENERGY = 30.0;   // dB

procedure TG729GainPredictor.Init;
var
  I: Integer;
begin
  for I := 0 to 3 do PastU[I] := -14;
end;

function TG729GainPredictor.PredictedGain(const Code: array of Double): Double;
var
  I: Integer;
  E, Pred: Double;
begin
  E := 0;
  for I := 0 to G729_SUBFR - 1 do E := E + Sqr(Code[I]);
  E := 10 * Log10(Max(E / G729_SUBFR, 1E-30));
  Pred := 0;
  for I := 0 to 3 do Pred := Pred + MA_GAIN[I] * PastU[I];
  Result := Power(10, (Pred + MEAN_ENERGY - E) / 20);
end;

procedure TG729GainPredictor.Push(U: Double);
begin
  PastU[3] := PastU[2];
  PastU[2] := PastU[1];
  PastU[1] := PastU[0];
  PastU[0] := U;
end;

procedure TG729GainPredictor.PushErased;
var
  U: Double;
begin
  U := 0.25 * (PastU[0] + PastU[1] + PastU[2] + PastU[3]) - 4;
  if U < -14 then U := -14;
  Push(U);
end;

procedure InitTables;
var
  I: Integer;
begin
  for I := 0 to 30 do B30[I] := INTERP_B30[I] / 32768;
end;

initialization
  InitTables;
end.
