unit OpusCeltMath;

{
  OpusCeltMath.pas - CELT numeric kernels: PVQ enumeration (cwrs), vector
  quantiser helpers (vq), Haar/Hadamard reordering, bit-exact trig helpers,
  low-overlap inverse MDCT and the pitch comb (post) filter.

  Ported from libopus 1.5.2 celt/cwrs.c (SMALL_FOOTPRINT variant), vq.c,
  bands.c (haar/hadamard), mathops.c, mdct.c and celt.c (float build).
  Copyright (c) 2007-2011 Xiph.Org Foundation, Timothy B. Terriberry,
  Jean-Marc Valin; BSD license.

  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  SysUtils, Math,
  OpusEntDec;

const
  SPREAD_NONE       = 0;
  SPREAD_LIGHT      = 1;
  SPREAD_NORMAL     = 2;
  SPREAD_AGGRESSIVE = 3;
  COMBFILTER_MINPERIOD = 15;
  CELT_EPSILON = 1e-15;

function  ISqrt32(V: Cardinal): Cardinal;
function  CeltLcgRand(Seed: Cardinal): Cardinal; inline;
function  FracMul16(A, B: Integer): Integer; inline;
function  BitexactCos(X: SmallInt): SmallInt;
function  BitexactLog2Tan(ISin, ICos: Integer): Integer;
function  CeltExp2(X: Single): Single; inline;
function  CeltLog2(X: Single): Single; inline;

// PVQ: decode a pulse vector of N dimensions with K pulses. Returns sum(y^2).
function  DecodePulses(Y: PInteger; N, K: Integer; var Dec: TEcDec): Single;
// Number of PVQ codewords V(N,K) and index -> pulse vector (exposed for tests)
function  CeltPvqV(N, K: Integer): Cardinal;
function  CeltCwrsi(N, K: Integer; I: Cardinal; Y: PInteger): Single;
procedure ExpRotation(X: PSingle; Len, Dir, Stride, K, Spread: Integer);
function  AlgUnquant(X: PSingle; N, K, Spread, B: Integer; var Dec: TEcDec; Gain: Single): Cardinal;
procedure RenormaliseVector(X: PSingle; N: Integer; Gain: Single);
procedure Haar1(X: PSingle; N0, Stride: Integer);
procedure DeinterleaveHadamard(X: PSingle; N0, Stride: Integer; Hadamard: Boolean);
procedure InterleaveHadamard(X: PSingle; N0, Stride: Integer; Hadamard: Boolean);

// Inverse MDCT of the 48 kHz / 960 mode (N = 1920 >> shift)
type
  TCeltMdct = record
    N        : Integer;
    MaxShift : Integer;
    Trig     : TArray<Single>;              // per level: N2 entries cos(2pi(i+1/8)/N)
    TrigOffs : array[0..3] of Integer;
    // FFT scratch
    FRe, FIm : TArray<Single>;
    TRe, TIm : TArray<Single>;
    TwRe, TwIm: TArray<TArray<Single>>;     // twiddles per level, size N4
    procedure Init(AN, AMaxShift: Integer);
    procedure Backward(Inp: PSingle; Outp: PSingle; Window: PSingle;
      Overlap, Shift, Stride: Integer);
  end;

procedure CombFilter(Y, X: PSingle; T0, T1, N: Integer; G0, G1: Single;
  Tapset0, Tapset1: Integer; Window: PSingle; Overlap: Integer);

implementation

// ---------------------------------------------------------------------------
// Integer helpers
// ---------------------------------------------------------------------------

function ISqrt32(V: Cardinal): Cardinal;
var
  B, G, T: Cardinal;
  BShift : Integer;
begin
  G := 0;
  BShift := (EcIlog(V) - 1) shr 1;
  B := Cardinal(1) shl BShift;
  repeat
    T := ((G shl 1) + B) shl BShift;
    if T <= V then
    begin
      G := G + B;
      V := V - T;
    end;
    B := B shr 1;
    Dec(BShift);
  until BShift < 0;
  Result := G;
end;

function CeltLcgRand(Seed: Cardinal): Cardinal;
begin
  Result := Cardinal(1664525) * Seed + Cardinal(1013904223);
end;

function FracMul16(A, B: Integer): Integer;
begin
  Result := (16384 + A * B) shr 15;   // arithmetic shift of a signed value
  if (16384 + A * B) < 0 then
    Result := -((-(16384 + A * B) + 32767) shr 15);
end;

function BitexactCos(X: SmallInt): SmallInt;
var
  Tmp: Integer;
  X2 : Integer;
begin
  Tmp := (4096 + Integer(X) * Integer(X)) shr 13;
  X2 := Tmp;
  X2 := (32767 - X2) + FracMul16(X2, (-7651 + FracMul16(X2, (8277 + FracMul16(-626, X2)))));
  Result := SmallInt(1 + X2);
end;

function BitexactLog2Tan(ISin, ICos: Integer): Integer;
var
  Lc, Ls: Integer;
begin
  Lc := EcIlog(Cardinal(ICos));
  Ls := EcIlog(Cardinal(ISin));
  ICos := ICos shl (15 - Lc);
  ISin := ISin shl (15 - Ls);
  Result := (Ls - Lc) * (1 shl 11)
          + FracMul16(ISin, FracMul16(ISin, -2597) + 7932)
          - FracMul16(ICos, FracMul16(ICos, -2597) + 7932);
end;

function CeltExp2(X: Single): Single;
begin
  Result := Exp(0.6931471805599453094 * X);
end;

function CeltLog2(X: Single): Single;
begin
  Result := 1.442695040888963387 * Ln(X);
end;

// ---------------------------------------------------------------------------
// cwrs (SMALL_FOOTPRINT variant: O(N*K) with O(K) memory)
// ---------------------------------------------------------------------------

procedure UNext(Ui: PCardinal; Len: Cardinal; Ui0: Cardinal);
var
  Ui1: Cardinal;
  J  : Cardinal;
begin
  J := 1;
  repeat
    Ui1 := Ui[J] + Ui[J - 1] + Ui0;
    Ui[J - 1] := Ui0;
    Ui0 := Ui1;
    Inc(J);
  until J >= Len;
  Ui[J - 1] := Ui0;
end;

procedure UPrev(Ui: PCardinal; N: Cardinal; Ui0: Cardinal);
var
  Ui1: Cardinal;
  J  : Cardinal;
begin
  J := 1;
  repeat
    Ui1 := Ui[J] - Ui[J - 1] - Ui0;
    Ui[J - 1] := Ui0;
    Ui0 := Ui1;
    Inc(J);
  until J >= N;
  Ui[J - 1] := Ui0;
end;

// Compute V(N,K) and fill U[0..K+1] with U(N,i)
function NcwrsURow(N, K: Cardinal; U: PCardinal): Cardinal;
var
  Len, K2: Cardinal;
begin
  Len := K + 2;
  U[0] := 0;
  U[1] := 1;
  K2 := 2;
  repeat
    U[K2] := (K2 shl 1) - 1;
    Inc(K2);
  until K2 >= Len;
  K2 := 2;
  while K2 < N do
  begin
    UNext(U + 1, K + 1, 1);
    Inc(K2);
  end;
  Result := U[K] + U[K + 1];
end;

function Cwrsi(N, K: Integer; I: Cardinal; Y: PInteger; U: PCardinal): Single;
var
  J   : Integer;
  P   : Cardinal;
  S   : Integer;
  Yj  : Integer;
  Val : Integer;
begin
  Result := 0;
  J := 0;
  repeat
    P := U[K + 1];
    if I >= P then begin S := -1; I := I - P; end else S := 0;
    Yj := K;
    P := U[K];
    while P > I do
    begin
      Dec(K);
      P := U[K];
    end;
    I := I - P;
    Yj := Yj - K;
    Val := (Yj + S) xor S;
    Y[J] := Val;
    Result := Result + Val * Val;
    UPrev(U, K + 2, 0);
    Inc(J);
  until J >= N;
end;

function CeltPvqV(N, K: Integer): Cardinal;
var
  U: TArray<Cardinal>;
begin
  SetLength(U, K + 2);
  Result := NcwrsURow(N, K, @U[0]);
end;

function CeltCwrsi(N, K: Integer; I: Cardinal; Y: PInteger): Single;
var
  U: TArray<Cardinal>;
begin
  SetLength(U, K + 2);
  NcwrsURow(N, K, @U[0]);
  Result := Cwrsi(N, K, I, Y, @U[0]);
end;

function DecodePulses(Y: PInteger; N, K: Integer; var Dec: TEcDec): Single;
var
  U : TArray<Cardinal>;
  Nc: Cardinal;
begin
  SetLength(U, K + 2);
  Nc := NcwrsURow(N, K, @U[0]);
  Result := Cwrsi(N, K, EcDecUInt(Dec, Nc), Y, @U[0]);
end;

// ---------------------------------------------------------------------------
// vq
// ---------------------------------------------------------------------------

procedure ExpRotation1(X: PSingle; Len, Stride: Integer; C, S: Single);
var
  I     : Integer;
  Ms    : Single;
  X1, X2: Single;
  P     : PSingle;
begin
  Ms := -S;
  P := X;
  for I := 0 to Len - Stride - 1 do
  begin
    X1 := P[0];
    X2 := P[Stride];
    P[Stride] := C * X2 + S * X1;
    P[0]      := C * X1 + Ms * X2;
    Inc(P);
  end;
  P := X + (Len - 2 * Stride - 1);
  for I := Len - 2 * Stride - 1 downto 0 do
  begin
    X1 := P[0];
    X2 := P[Stride];
    P[Stride] := C * X2 + S * X1;
    P[0]      := C * X1 + Ms * X2;
    Dec(P);
  end;
end;

procedure ExpRotation(X: PSingle; Len, Dir, Stride, K, Spread: Integer);
const
  SPREAD_FACTOR: array[0..2] of Integer = (15, 10, 5);
var
  I       : Integer;
  C, S    : Single;
  Gain    : Single;
  Theta   : Single;
  Stride2 : Integer;
  Factor  : Integer;
begin
  if (2 * K >= Len) or (Spread = SPREAD_NONE) then Exit;
  Factor := SPREAD_FACTOR[Spread - 1];
  Gain  := Len / (Len + Factor * K);
  Theta := 0.5 * Gain * Gain;
  C := Cos(0.5 * Pi * Theta);
  S := Cos(0.5 * Pi * (1.0 - Theta));
  Stride2 := 0;
  if Len >= 8 * Stride then
  begin
    Stride2 := 1;
    while (Stride2 * Stride2 + Stride2) * Stride + (Stride shr 2) < Len do
      Inc(Stride2);
  end;
  Len := Len div Stride;
  for I := 0 to Stride - 1 do
  begin
    if Dir < 0 then
    begin
      if Stride2 <> 0 then
        ExpRotation1(X + I * Len, Len, Stride2, S, C);
      ExpRotation1(X + I * Len, Len, 1, C, S);
    end
    else
    begin
      ExpRotation1(X + I * Len, Len, 1, C, -S);
      if Stride2 <> 0 then
        ExpRotation1(X + I * Len, Len, Stride2, S, -C);
    end;
  end;
end;

procedure NormaliseResidual(Iy: PInteger; X: PSingle; N: Integer; Ryy: Single; Gain: Single);
var
  I: Integer;
  G: Single;
begin
  G := Gain / Sqrt(Ryy);
  for I := 0 to N - 1 do
    X[I] := G * Iy[I];
end;

function ExtractCollapseMask(Iy: PInteger; N, B: Integer): Cardinal;
var
  N0, I, J: Integer;
  Tmp     : Integer;
begin
  if B <= 1 then Exit(1);
  N0 := N div B;
  Result := 0;
  for I := 0 to B - 1 do
  begin
    Tmp := 0;
    for J := 0 to N0 - 1 do
      Tmp := Tmp or Iy[I * N0 + J];
    if Tmp <> 0 then
      Result := Result or (Cardinal(1) shl I);
  end;
end;

function AlgUnquant(X: PSingle; N, K, Spread, B: Integer; var Dec: TEcDec; Gain: Single): Cardinal;
var
  Iy : TArray<Integer>;
  Ryy: Single;
begin
  SetLength(Iy, N);
  Ryy := DecodePulses(@Iy[0], N, K, Dec);
  NormaliseResidual(@Iy[0], X, N, Ryy, Gain);
  ExpRotation(X, N, -1, B, K, Spread);
  Result := ExtractCollapseMask(@Iy[0], N, B);
end;

procedure RenormaliseVector(X: PSingle; N: Integer; Gain: Single);
var
  I: Integer;
  E: Single;
  G: Single;
begin
  E := CELT_EPSILON;
  for I := 0 to N - 1 do
    E := E + X[I] * X[I];
  G := Gain / Sqrt(E);
  for I := 0 to N - 1 do
    X[I] := X[I] * G;
end;

// ---------------------------------------------------------------------------
// Haar / Hadamard
// ---------------------------------------------------------------------------

procedure Haar1(X: PSingle; N0, Stride: Integer);
var
  I, J      : Integer;
  Tmp1, Tmp2: Single;
begin
  N0 := N0 shr 1;
  for I := 0 to Stride - 1 do
    for J := 0 to N0 - 1 do
    begin
      Tmp1 := 0.70710678 * X[Stride * 2 * J + I];
      Tmp2 := 0.70710678 * X[Stride * (2 * J + 1) + I];
      X[Stride * 2 * J + I]       := Tmp1 + Tmp2;
      X[Stride * (2 * J + 1) + I] := Tmp1 - Tmp2;
    end;
end;

const
  ORDERY_TABLE: array[0..29] of Integer = (
     1,  0,
     3,  0,  2,  1,
     7,  0,  4,  3,  6,  1,  5,  2,
    15,  0,  8,  7, 12,  3, 11,  4, 14,  1,  9,  6, 13,  2, 10,  5);

procedure DeinterleaveHadamard(X: PSingle; N0, Stride: Integer; Hadamard: Boolean);
var
  I, J, N: Integer;
  Tmp    : TArray<Single>;
  Ordery : PInteger;
begin
  N := N0 * Stride;
  SetLength(Tmp, N);
  if Hadamard then
  begin
    Ordery := @ORDERY_TABLE[Stride - 2];
    for I := 0 to Stride - 1 do
      for J := 0 to N0 - 1 do
        Tmp[Ordery[I] * N0 + J] := X[J * Stride + I];
  end
  else
    for I := 0 to Stride - 1 do
      for J := 0 to N0 - 1 do
        Tmp[I * N0 + J] := X[J * Stride + I];
  Move(Tmp[0], X^, N * SizeOf(Single));
end;

procedure InterleaveHadamard(X: PSingle; N0, Stride: Integer; Hadamard: Boolean);
var
  I, J, N: Integer;
  Tmp    : TArray<Single>;
  Ordery : PInteger;
begin
  N := N0 * Stride;
  SetLength(Tmp, N);
  if Hadamard then
  begin
    Ordery := @ORDERY_TABLE[Stride - 2];
    for I := 0 to Stride - 1 do
      for J := 0 to N0 - 1 do
        Tmp[J * Stride + I] := X[Ordery[I] * N0 + J];
  end
  else
    for I := 0 to Stride - 1 do
      for J := 0 to N0 - 1 do
        Tmp[J * Stride + I] := X[I * N0 + J];
  Move(Tmp[0], X^, N * SizeOf(Single));
end;

// ---------------------------------------------------------------------------
// Mixed-radix FFT (forward, unscaled), sizes 60/120/240/480
// ---------------------------------------------------------------------------

// Recursive decimation-in-time: Out[k] = sum_r W^(r k) F_r[k mod (n/p)]
procedure FftRec(InRe, InIm: PSingle; InStride: Integer; OutRe, OutIm: PSingle;
  N: Integer; TwRe, TwIm: PSingle; TwStride: Integer);
var
  P, M, R, K, Q: Integer;
  SubRe, SubIm : TArray<Single>;
  Wr, Wi       : Single;
  Ar, Ai       : Single;
  Idx          : Integer;
begin
  if N = 1 then
  begin
    OutRe[0] := InRe[0];
    OutIm[0] := InIm[0];
    Exit;
  end;
  if (N mod 2) = 0 then P := 2
  else if (N mod 3) = 0 then P := 3
  else if (N mod 5) = 0 then P := 5
  else P := N;
  M := N div P;
  SetLength(SubRe, N);
  SetLength(SubIm, N);
  for R := 0 to P - 1 do
    FftRec(InRe + R * InStride, InIm + R * InStride, InStride * P,
      @SubRe[R * M], @SubIm[R * M], M, TwRe, TwIm, TwStride * P);
  for K := 0 to N - 1 do
  begin
    Q := K mod M;
    Ar := 0; Ai := 0;
    for R := 0 to P - 1 do
    begin
      Idx := ((R * K) mod N) * TwStride;
      Wr := TwRe[Idx];
      Wi := TwIm[Idx];
      Ar := Ar + SubRe[R * M + Q] * Wr - SubIm[R * M + Q] * Wi;
      Ai := Ai + SubRe[R * M + Q] * Wi + SubIm[R * M + Q] * Wr;
    end;
    OutRe[K] := Ar;
    OutIm[K] := Ai;
  end;
end;

procedure TCeltMdct.Init(AN, AMaxShift: Integer);
var
  Shift, I, N2, N4, NN: Integer;
  Offs: Integer;
begin
  N := AN;
  MaxShift := AMaxShift;
  Offs := 0;
  NN := N;
  N2 := N shr 1;
  SetLength(Trig, N - (N2 shr MaxShift));
  SetLength(TwRe, MaxShift + 1);
  SetLength(TwIm, MaxShift + 1);
  for Shift := 0 to MaxShift do
  begin
    TrigOffs[Shift] := Offs;
    for I := 0 to N2 - 1 do
      Trig[Offs + I] := Cos(2 * Pi * (I + 0.125) / NN);
    N4 := NN shr 2;
    SetLength(TwRe[Shift], N4);
    SetLength(TwIm[Shift], N4);
    for I := 0 to N4 - 1 do
    begin
      TwRe[Shift][I] :=  Cos(2 * Pi * I / N4);
      TwIm[Shift][I] := -Sin(2 * Pi * I / N4);
    end;
    Inc(Offs, N2);
    N2 := N2 shr 1;
    NN := NN shr 1;
  end;
  SetLength(FRe, N shr 2);
  SetLength(FIm, N shr 2);
  SetLength(TRe, N shr 2);
  SetLength(TIm, N shr 2);
end;

procedure TCeltMdct.Backward(Inp: PSingle; Outp: PSingle; Window: PSingle;
  Overlap, Shift, Stride: Integer);
var
  NN, N2, N4, I  : Integer;
  T              : PSingle;
  Xp1, Xp2       : PSingle;
  Y              : PSingle;
  Yr, Yi, Re, Im : Single;
  T0, T1         : Single;
  X1, X2         : Single;
  Wp1, Wp2       : Integer;
  J              : Integer;
begin
  NN := N shr Shift;
  T  := @Trig[TrigOffs[Shift]];
  N2 := NN shr 1;
  N4 := NN shr 2;

  // Pre-rotate into the FFT input (real/imag swapped: FFT instead of IFFT)
  Xp1 := Inp;
  Xp2 := Inp + Stride * (N2 - 1);
  for I := 0 to N4 - 1 do
  begin
    Yr := Xp2^ * T[I] + Xp1^ * T[N4 + I];
    Yi := Xp1^ * T[I] - Xp2^ * T[N4 + I];
    FRe[I] := Yi;
    FIm[I] := Yr;
    Inc(Xp1, 2 * Stride);
    Dec(Xp2, 2 * Stride);
  end;

  FftRec(@FRe[0], @FIm[0], 1, @TRe[0], @TIm[0], N4, @TwRe[Shift][0], @TwIm[Shift][0], 1);

  // Post-rotate and de-shuffle (from both ends)
  Y := Outp + (Overlap shr 1);
  for I := 0 to ((N4 + 1) shr 1) - 1 do
  begin
    Re := TIm[I];
    Im := TRe[I];
    T0 := T[I];
    T1 := T[N4 + I];
    Yr := Re * T0 + Im * T1;
    Yi := Re * T1 - Im * T0;
    J  := N4 - 1 - I;
    Y[2 * I]     := Yr;
    Y[2 * J + 1] := Yi;
    Re := TIm[J];
    Im := TRe[J];
    T0 := T[N4 - I - 1];
    T1 := T[N2 - I - 1];
    Yr := Re * T0 + Im * T1;
    Yi := Re * T1 - Im * T0;
    Y[2 * J]     := Yr;
    Y[2 * I + 1] := Yi;
  end;

  // Mirror on both sides for TDAC
  Wp1 := 0;
  Wp2 := Overlap - 1;
  for I := 0 to (Overlap div 2) - 1 do
  begin
    X1 := Outp[Overlap - 1 - I];
    X2 := Outp[I];
    Outp[I]               := Window[Wp2] * X2 - Window[Wp1] * X1;
    Outp[Overlap - 1 - I] := Window[Wp1] * X2 + Window[Wp2] * X1;
    Inc(Wp1);
    Dec(Wp2);
  end;
end;

// ---------------------------------------------------------------------------
// Comb filter (pitch post-filter), celt.c
// ---------------------------------------------------------------------------

procedure CombFilterConst(Y, X: PSingle; T, N: Integer; G10, G11, G12: Single);
var
  X0, X1, X2, X3, X4: Single;
  I: Integer;
begin
  X4 := X[-T - 2];
  X3 := X[-T - 1];
  X2 := X[-T];
  X1 := X[-T + 1];
  for I := 0 to N - 1 do
  begin
    X0 := X[I - T + 2];
    Y[I] := X[I] + G10 * X2 + G11 * (X1 + X3) + G12 * (X0 + X4);
    X4 := X3;
    X3 := X2;
    X2 := X1;
    X1 := X0;
  end;
end;

procedure CombFilter(Y, X: PSingle; T0, T1, N: Integer; G0, G1: Single;
  Tapset0, Tapset1: Integer; Window: PSingle; Overlap: Integer);
const
  Gains: array[0..2, 0..2] of Single = (
    (0.3066406250, 0.2170410156, 0.1296386719),
    (0.4638671875, 0.2680664062, 0.0),
    (0.7998046875, 0.1000976562, 0.0));
var
  I: Integer;
  G00, G01, G02, G10, G11, G12: Single;
  X0, X1, X2, X3, X4: Single;
  F: Single;
begin
  if (G0 = 0) and (G1 = 0) then
  begin
    if X <> Y then Move(X^, Y^, N * SizeOf(Single));
    Exit;
  end;
  T0 := Max(T0, COMBFILTER_MINPERIOD);
  T1 := Max(T1, COMBFILTER_MINPERIOD);
  G00 := G0 * Gains[Tapset0][0];
  G01 := G0 * Gains[Tapset0][1];
  G02 := G0 * Gains[Tapset0][2];
  G10 := G1 * Gains[Tapset1][0];
  G11 := G1 * Gains[Tapset1][1];
  G12 := G1 * Gains[Tapset1][2];
  X1 := X[-T1 + 1];
  X2 := X[-T1];
  X3 := X[-T1 - 1];
  X4 := X[-T1 - 2];
  if (G0 = G1) and (T0 = T1) and (Tapset0 = Tapset1) then
    Overlap := 0;
  for I := 0 to Overlap - 1 do
  begin
    X0 := X[I - T1 + 2];
    F := Window[I] * Window[I];
    Y[I] := X[I]
          + ((1 - F) * G00) * X[I - T0]
          + ((1 - F) * G01) * (X[I - T0 + 1] + X[I - T0 - 1])
          + ((1 - F) * G02) * (X[I - T0 + 2] + X[I - T0 - 2])
          + (F * G10) * X2
          + (F * G11) * (X1 + X3)
          + (F * G12) * (X0 + X4);
    X4 := X3;
    X3 := X2;
    X2 := X1;
    X1 := X0;
  end;
  if G1 = 0 then
  begin
    if X <> Y then Move((X + Overlap)^, (Y + Overlap)^, (N - Overlap) * SizeOf(Single));
    Exit;
  end;
  CombFilterConst(Y + Overlap, X + Overlap, T1, N - Overlap, G10, G11, G12);
end;

end.
