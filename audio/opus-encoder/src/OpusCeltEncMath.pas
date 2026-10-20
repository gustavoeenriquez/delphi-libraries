unit OpusCeltEncMath;

{
  OpusCeltEncMath.pas - CELT encoder numeric kernels (float build)

  Port of libopus 1.5.2: celt/kiss_fft.c (forward FFT), celt/mdct.c
  (clt_mdct_forward), celt/mathops.h (FLOAT_APPROX celt_log2/celt_exp2,
  fast_atan2f), celt/cwrs.c (SMALL_FOOTPRINT encode_pulses), celt/vq.c
  (exp_rotation, op_pvq_search, alg_quant, renormalise_vector,
  stereo_itheta), celt/bands.c (haar1), celt/pitch.c, celt/celt_lpc.c and
  the comb filter of celt/celt.c.

  All arithmetic follows the C float semantics (EXCESSPRECISION OFF,
  float literals as typed Single constants, double literals where libopus
  uses them) so that the encoder decisions match libopus built with
  FLOAT_APPROX (its default configuration) on SSE2 hardware.

  Copyright (c) 2003-2004 Mark Borgerding, 2007-2011 Xiph.Org Foundation,
  Jean-Marc Valin, Timothy B. Terriberry.
  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$EXCESSPRECISION OFF}
{$Q-}{$R-}

interface

uses
  Math,
  OpusEntEnc,
  OpusCeltEncTables;

const
  COMBFILTER_MAXPERIOD = 1024;
  COMBFILTER_MINPERIOD = 15;
  CELT_SPREAD_NONE       = 0;
  CELT_SPREAD_LIGHT      = 1;
  CELT_SPREAD_NORMAL     = 2;
  CELT_SPREAD_AGGRESSIVE = 3;

  // float constants of libopus (typed so that they keep float semantics)
  F_EPSILON: Single = 1e-15;
  F_ONE    : Single = 1.0;
  F_HALF   : Single = 0.5;

type
  PKissCpx = ^TKissCpx;

function  CeltLog2(X: Single): Single;
function  CeltExp2(X: Single): Single;
function  FastAtan2F(Y, X: Single): Single;
// celt_sqrt(): (float)sqrt(x). Delphi's Sqrt returns Extended/Double, which
// would turn the surrounding expression into double arithmetic.
function  SqrtF(X: Single): Single; inline;
function  CeltInnerProd(X, Y: PSingle; N: Integer): Single; inline;
function  CeltMaxAbs(X: PSingle; Len: Integer): Single;

// Forward MDCT of the 48 kHz / 960 mode (N = 1920 >> Shift), libopus mdct.c
procedure CltMdctForward(Inp, Outp: PSingle; Window: PSingle; Overlap, Shift, Stride: Integer);

// PVQ / vq.c
procedure EncodePulses(Y: PInteger; N, K: Integer; var Enc: TEcEnc);
procedure ExpRotationF(X: PSingle; Len, Dir, Stride, K, Spread: Integer);
function  OpPvqSearch(X: PSingle; Iy: PInteger; K, N: Integer): Single;
function  AlgQuant(X: PSingle; N, K, Spread, B: Integer; var Enc: TEcEnc;
  Gain: Single; Resynth: Boolean): Cardinal;
procedure RenormaliseVectorF(X: PSingle; N: Integer; Gain: Single);
function  StereoItheta(X, Y: PSingle; Stereo: Boolean; N: Integer): Integer;
procedure Haar1F(X: PSingle; N0, Stride: Integer);

// pitch.c / celt_lpc.c
procedure PitchDownsample(const X: array of PSingle; XLp: PSingle; Len, C: Integer);
procedure PitchSearch(XLp, Y: PSingle; Len, MaxPitch: Integer; out Pitch: Integer);
function  RemoveDoubling(X: PSingle; MaxPeriod, MinPeriod, N: Integer;
  var T0_: Integer; PrevPeriod: Integer; PrevGain: Single): Single;
procedure CeltLpc(Lpc: PSingle; Ac: PSingle; P: Integer);
procedure CeltAutocorr(X: PSingle; Ac: PSingle; Lag, N: Integer);
procedure CeltPitchXcorr(X, Y: PSingle; Xcorr: PSingle; Len, MaxPitch: Integer);
// opus_fft_c for the 480-point state (analysis.c)
procedure OpusFft480(Fin, Fout: PKissCpx);

// celt.c comb filter (float semantics)
procedure CombFilterF(Y, X: PSingle; T0, T1, N: Integer; G0, G1: Single;
  Tapset0, Tapset1: Integer; Window: PSingle; Overlap: Integer);

implementation

// ---------------------------------------------------------------------------
// mathops.h (FLOAT_APPROX)
// ---------------------------------------------------------------------------

function CeltLog2(X: Single): Single;
const
  C0: Single = -0.41445418;
  C1: Single = 0.95909232;
  C2: Single = -0.33951290;
  C3: Single = 0.16541097;
  C15: Single = 1.5;
var
  U      : Cardinal;
  Integer_: Integer;
  F, Frac: Single;
begin
  Move(X, U, 4);
  Integer_ := Integer(U shr 23) - 127;
  U := U - (Cardinal(Integer_) shl 23);
  Move(U, F, 4);
  Frac := F - C15;
  Frac := C0 + Frac * (C1 + Frac * (C2 + Frac * C3));
  Result := 1 + Integer_ + Frac;
end;

function CeltExp2(X: Single): Single;
const
  K0: Single = 0.99992522;
  K1: Single = 0.69583354;
  K2: Single = 0.22606716;
  K3: Single = 0.078024523;
var
  Integer_: Integer;
  Frac, F : Single;
  U       : Cardinal;
begin
  Integer_ := Floor(X);
  if Integer_ < -50 then Exit(0);
  Frac := X - Integer_;
  F := K0 + Frac * (K1 + Frac * (K2 + K3 * Frac));
  Move(F, U, 4);
  U := (U + (Cardinal(Integer_) shl 23)) and $7FFFFFFF;
  Move(U, Result, 4);
end;

function FastAtan2F(Y, X: Single): Single;
const
  cA: Single = 0.43157974;
  cB: Single = 0.67848403;
  cC: Single = 0.08595542;
  cE: Single = 3.141592653 / 2;
  Tiny: Single = 1e-18;
var
  X2, Y2, Den: Single;
  S1, S2: Single;
begin
  X2 := X * X;
  Y2 := Y * Y;
  if X2 + Y2 < Tiny then Exit(0);
  if X2 < Y2 then
  begin
    Den := (Y2 + cB * X2) * (Y2 + cC * X2);
    if Y < 0 then S1 := -cE else S1 := cE;
    Result := -X * Y * (Y2 + cA * X2) / Den + S1;
  end
  else
  begin
    Den := (X2 + cB * Y2) * (X2 + cC * Y2);
    if Y < 0 then S1 := -cE else S1 := cE;
    if X * Y < 0 then S2 := -cE else S2 := cE;
    Result := X * Y * (X2 + cA * Y2) / Den + S1 - S2;
  end;
end;

function SqrtF(X: Single): Single;
begin
  Result := Sqrt(X);
end;

function CeltInnerProd(X, Y: PSingle; N: Integer): Single;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to N - 1 do
    Result := Result + X[I] * Y[I];
end;

function CeltMaxAbs(X: PSingle; Len: Integer): Single;
var
  I: Integer;
  MaxV, MinV: Single;
begin
  MaxV := 0;
  MinV := 0;
  for I := 0 to Len - 1 do
  begin
    if X[I] > MaxV then MaxV := X[I];
    if X[I] < MinV then MinV := X[I];
  end;
  if MaxV > -MinV then Result := MaxV else Result := -MinV;
end;

// ---------------------------------------------------------------------------
// kiss_fft.c (forward, float)
// ---------------------------------------------------------------------------

const
  FFT_SCALE: array[0..3] of Single = (0.002083333, 0.004166667, 0.008333333, 0.016666667);
  KISS_TW: Single = 0.7071067812;
  F_HALF_OF: Single = 0.5;

procedure KfBfly2(Fout: PKissCpx; M, N: Integer);
var
  I: Integer;
  Fout2: PKissCpx;
  T: TKissCpx;
begin
  // m == 4 here (the radix-2 always follows a radix-4)
  for I := 0 to N - 1 do
  begin
    Fout2 := Fout + 4;
    T := Fout2[0];
    Fout2[0].R := Fout[0].R - T.R; Fout2[0].I := Fout[0].I - T.I;
    Fout[0].R := Fout[0].R + T.R;  Fout[0].I := Fout[0].I + T.I;

    T.R := (Fout2[1].R + Fout2[1].I) * KISS_TW;
    T.I := (Fout2[1].I - Fout2[1].R) * KISS_TW;
    Fout2[1].R := Fout[1].R - T.R; Fout2[1].I := Fout[1].I - T.I;
    Fout[1].R := Fout[1].R + T.R;  Fout[1].I := Fout[1].I + T.I;

    T.R := Fout2[2].I;
    T.I := -Fout2[2].R;
    Fout2[2].R := Fout[2].R - T.R; Fout2[2].I := Fout[2].I - T.I;
    Fout[2].R := Fout[2].R + T.R;  Fout[2].I := Fout[2].I + T.I;

    T.R := (Fout2[3].I - Fout2[3].R) * KISS_TW;
    T.I := -(Fout2[3].I + Fout2[3].R) * KISS_TW;
    Fout2[3].R := Fout[3].R - T.R; Fout2[3].I := Fout[3].I - T.I;
    Fout[3].R := Fout[3].R + T.R;  Fout[3].I := Fout[3].I + T.I;
    Inc(Fout, 8);
  end;
end;

procedure KfBfly4(Fout: PKissCpx; FStride, M, N, MM: Integer);
var
  I, J, M2, M3: Integer;
  S0, S1, S2, S3, S4, S5: TKissCpx;
  Tw1, Tw2, Tw3: PKissCpx;
  FoutBeg: PKissCpx;
  Tw: PKissCpx;
begin
  if M = 1 then
  begin
    for I := 0 to N - 1 do
    begin
      S0.R := Fout[0].R - Fout[2].R; S0.I := Fout[0].I - Fout[2].I;
      Fout[0].R := Fout[0].R + Fout[2].R; Fout[0].I := Fout[0].I + Fout[2].I;
      S1.R := Fout[1].R + Fout[3].R; S1.I := Fout[1].I + Fout[3].I;
      Fout[2].R := Fout[0].R - S1.R; Fout[2].I := Fout[0].I - S1.I;
      Fout[0].R := Fout[0].R + S1.R; Fout[0].I := Fout[0].I + S1.I;
      S1.R := Fout[1].R - Fout[3].R; S1.I := Fout[1].I - Fout[3].I;
      Fout[1].R := S0.R + S1.I;
      Fout[1].I := S0.I - S1.R;
      Fout[3].R := S0.R - S1.I;
      Fout[3].I := S0.I + S1.R;
      Inc(Fout, 4);
    end;
  end
  else
  begin
    Tw := @FFT_TWIDDLES480[0];
    M2 := 2 * M;
    M3 := 3 * M;
    FoutBeg := Fout;
    for I := 0 to N - 1 do
    begin
      Fout := FoutBeg + I * MM;
      Tw1 := Tw; Tw2 := Tw; Tw3 := Tw;
      for J := 0 to M - 1 do
      begin
        S0.R := Fout[M].R * Tw1.R - Fout[M].I * Tw1.I;
        S0.I := Fout[M].R * Tw1.I + Fout[M].I * Tw1.R;
        S1.R := Fout[M2].R * Tw2.R - Fout[M2].I * Tw2.I;
        S1.I := Fout[M2].R * Tw2.I + Fout[M2].I * Tw2.R;
        S2.R := Fout[M3].R * Tw3.R - Fout[M3].I * Tw3.I;
        S2.I := Fout[M3].R * Tw3.I + Fout[M3].I * Tw3.R;

        S5.R := Fout[0].R - S1.R; S5.I := Fout[0].I - S1.I;
        Fout[0].R := Fout[0].R + S1.R; Fout[0].I := Fout[0].I + S1.I;
        S3.R := S0.R + S2.R; S3.I := S0.I + S2.I;
        S4.R := S0.R - S2.R; S4.I := S0.I - S2.I;
        Fout[M2].R := Fout[0].R - S3.R; Fout[M2].I := Fout[0].I - S3.I;
        Inc(Tw1, FStride);
        Inc(Tw2, FStride * 2);
        Inc(Tw3, FStride * 3);
        Fout[0].R := Fout[0].R + S3.R; Fout[0].I := Fout[0].I + S3.I;

        Fout[M].R := S5.R + S4.I;
        Fout[M].I := S5.I - S4.R;
        Fout[M3].R := S5.R - S4.I;
        Fout[M3].I := S5.I + S4.R;
        Inc(Fout);
      end;
    end;
  end;
end;

procedure KfBfly3(Fout: PKissCpx; FStride, M, N, MM: Integer);
var
  I, K, M2: Integer;
  Tw1, Tw2: PKissCpx;
  S0, S1, S2, S3: TKissCpx;
  Epi3: TKissCpx;
  FoutBeg: PKissCpx;
begin
  M2 := 2 * M;
  FoutBeg := Fout;
  Epi3 := FFT_TWIDDLES480[FStride * M];
  for I := 0 to N - 1 do
  begin
    Fout := FoutBeg + I * MM;
    Tw1 := @FFT_TWIDDLES480[0];
    Tw2 := Tw1;
    K := M;
    repeat
      S1.R := Fout[M].R * Tw1.R - Fout[M].I * Tw1.I;
      S1.I := Fout[M].R * Tw1.I + Fout[M].I * Tw1.R;
      S2.R := Fout[M2].R * Tw2.R - Fout[M2].I * Tw2.I;
      S2.I := Fout[M2].R * Tw2.I + Fout[M2].I * Tw2.R;

      S3.R := S1.R + S2.R; S3.I := S1.I + S2.I;
      S0.R := S1.R - S2.R; S0.I := S1.I - S2.I;
      Inc(Tw1, FStride);
      Inc(Tw2, FStride * 2);

      Fout[M].R := Fout[0].R - S3.R * F_HALF_OF;
      Fout[M].I := Fout[0].I - S3.I * F_HALF_OF;

      S0.R := S0.R * Epi3.I;
      S0.I := S0.I * Epi3.I;

      Fout[0].R := Fout[0].R + S3.R; Fout[0].I := Fout[0].I + S3.I;

      Fout[M2].R := Fout[M].R + S0.I;
      Fout[M2].I := Fout[M].I - S0.R;

      Fout[M].R := Fout[M].R - S0.I;
      Fout[M].I := Fout[M].I + S0.R;
      Inc(Fout);
      Dec(K);
    until K = 0;
  end;
end;

procedure KfBfly5(Fout: PKissCpx; FStride, M, N, MM: Integer);
var
  Fout0, Fout1, Fout2, Fout3, Fout4: PKissCpx;
  I, U: Integer;
  S: array[0..12] of TKissCpx;
  Tw: PKissCpx;
  Ya, Yb: TKissCpx;
  FoutBeg: PKissCpx;
  A, B: TKissCpx;
begin
  FoutBeg := Fout;
  Ya := FFT_TWIDDLES480[FStride * M];
  Yb := FFT_TWIDDLES480[FStride * 2 * M];
  Tw := @FFT_TWIDDLES480[0];
  for I := 0 to N - 1 do
  begin
    Fout := FoutBeg + I * MM;
    Fout0 := Fout;
    Fout1 := Fout0 + M;
    Fout2 := Fout0 + 2 * M;
    Fout3 := Fout0 + 3 * M;
    Fout4 := Fout0 + 4 * M;
    for U := 0 to M - 1 do
    begin
      S[0] := Fout0^;
      A := Fout1^; B := Tw[U * FStride];
      S[1].R := A.R * B.R - A.I * B.I; S[1].I := A.R * B.I + A.I * B.R;
      A := Fout2^; B := Tw[2 * U * FStride];
      S[2].R := A.R * B.R - A.I * B.I; S[2].I := A.R * B.I + A.I * B.R;
      A := Fout3^; B := Tw[3 * U * FStride];
      S[3].R := A.R * B.R - A.I * B.I; S[3].I := A.R * B.I + A.I * B.R;
      A := Fout4^; B := Tw[4 * U * FStride];
      S[4].R := A.R * B.R - A.I * B.I; S[4].I := A.R * B.I + A.I * B.R;

      S[7].R := S[1].R + S[4].R;  S[7].I := S[1].I + S[4].I;
      S[10].R := S[1].R - S[4].R; S[10].I := S[1].I - S[4].I;
      S[8].R := S[2].R + S[3].R;  S[8].I := S[2].I + S[3].I;
      S[9].R := S[2].R - S[3].R;  S[9].I := S[2].I - S[3].I;

      Fout0.R := Fout0.R + (S[7].R + S[8].R);
      Fout0.I := Fout0.I + (S[7].I + S[8].I);

      S[5].R := S[0].R + (S[7].R * Ya.R + S[8].R * Yb.R);
      S[5].I := S[0].I + (S[7].I * Ya.R + S[8].I * Yb.R);

      S[6].R := S[10].I * Ya.I + S[9].I * Yb.I;
      S[6].I := -(S[10].R * Ya.I + S[9].R * Yb.I);

      Fout1.R := S[5].R - S[6].R; Fout1.I := S[5].I - S[6].I;
      Fout4.R := S[5].R + S[6].R; Fout4.I := S[5].I + S[6].I;

      S[11].R := S[0].R + (S[7].R * Yb.R + S[8].R * Ya.R);
      S[11].I := S[0].I + (S[7].I * Yb.R + S[8].I * Ya.R);
      S[12].R := S[9].I * Ya.I - S[10].I * Yb.I;
      S[12].I := S[10].R * Yb.I - S[9].R * Ya.I;

      Fout2.R := S[11].R + S[12].R; Fout2.I := S[11].I + S[12].I;
      Fout3.R := S[11].R - S[12].R; Fout3.I := S[11].I - S[12].I;

      Inc(Fout0); Inc(Fout1); Inc(Fout2); Inc(Fout3); Inc(Fout4);
    end;
  end;
end;

// opus_fft_impl for the sub-FFT selected by Shift (0: 480 ... 3: 60)
procedure OpusFftImpl(Shift: Integer; Fout: PKissCpx);
var
  M2, M, P, L, I: Integer;
  FStride: array[0..8] of Integer;
  Factors: PSmallInt;
  TwShift: Integer;
begin
  Factors := @FFT_FACTORS[Shift][0];
  TwShift := Shift;      // st->shift is -1 for the 480-point state (=> 0)
  FStride[0] := 1;
  L := 0;
  repeat
    P := Factors[2 * L];
    M := Factors[2 * L + 1];
    FStride[L + 1] := FStride[L] * P;
    Inc(L);
  until M = 1;
  M := Factors[2 * L - 1];
  for I := L - 1 downto 0 do
  begin
    if I <> 0 then M2 := Factors[2 * I - 1]
    else M2 := 1;
    case Factors[2 * I] of
      2: KfBfly2(Fout, M, FStride[I]);
      4: KfBfly4(Fout, FStride[I] shl TwShift, M, FStride[I], M2);
      3: KfBfly3(Fout, FStride[I] shl TwShift, M, FStride[I], M2);
      5: KfBfly5(Fout, FStride[I] shl TwShift, M, FStride[I], M2);
    end;
    M := M2;
  end;
end;

function FftBitrev(Shift: Integer): PSmallInt;
begin
  case Shift of
    0: Result := @FFT_BITREV480[0];
    1: Result := @FFT_BITREV240[0];
    2: Result := @FFT_BITREV120[0];
  else
    Result := @FFT_BITREV60[0];
  end;
end;

procedure OpusFft480(Fin, Fout: PKissCpx);
var
  I: Integer;
  Scale: Single;
  Bitrev: PSmallInt;
begin
  Scale := FFT_SCALE[0];
  Bitrev := FftBitrev(0);
  for I := 0 to 479 do
  begin
    Fout[Bitrev[I]].R := Scale * Fin[I].R;
    Fout[Bitrev[I]].I := Scale * Fin[I].I;
  end;
  OpusFftImpl(0, Fout);
end;

// ---------------------------------------------------------------------------
// mdct.c: clt_mdct_forward_c
// ---------------------------------------------------------------------------

procedure CltMdctForward(Inp, Outp: PSingle; Window: PSingle; Overlap, Shift, Stride: Integer);
var
  I, N, N2, N4: Integer;
  F : array[0..959] of Single;
  F2: array[0..479] of TKissCpx;
  Trig: PSingle;
  Scale: Single;
  Xp1, Xp2, Yp, Wp1, Wp2: PSingle;
  Re, Im, Yr, Yi, T0, T1: Single;
  Bitrev: PSmallInt;
  Fp: PKissCpx;
  Yp1, Yp2: PSingle;
begin
  Scale := FFT_SCALE[Shift];
  Bitrev := FftBitrev(Shift);
  N := 1920;
  Trig := @MDCT_TRIG960[0];
  for I := 0 to Shift - 1 do
  begin
    N := N shr 1;
    Inc(Trig, N);
  end;
  N2 := N shr 1;
  N4 := N shr 2;

  // Window, shuffle, fold
  Xp1 := Inp + (Overlap shr 1);
  Xp2 := Inp + N2 - 1 + (Overlap shr 1);
  Yp := @F[0];
  Wp1 := Window + (Overlap shr 1);
  Wp2 := Window + (Overlap shr 1) - 1;
  I := 0;
  while I < ((Overlap + 3) shr 2) do
  begin
    Yp^ := Wp2^ * Xp1[N2] + Wp1^ * Xp2^; Inc(Yp);
    Yp^ := Wp1^ * Xp1^ - Wp2^ * Xp2[-N2]; Inc(Yp);
    Inc(Xp1, 2); Dec(Xp2, 2);
    Inc(Wp1, 2); Dec(Wp2, 2);
    Inc(I);
  end;
  Wp1 := Window;
  Wp2 := Window + Overlap - 1;
  while I < N4 - ((Overlap + 3) shr 2) do
  begin
    Yp^ := Xp2^; Inc(Yp);
    Yp^ := Xp1^; Inc(Yp);
    Inc(Xp1, 2); Dec(Xp2, 2);
    Inc(I);
  end;
  while I < N4 do
  begin
    Yp^ := -(Wp1^ * Xp1[-N2]) + Wp2^ * Xp2^; Inc(Yp);
    Yp^ := Wp2^ * Xp1^ + Wp1^ * Xp2[N2]; Inc(Yp);
    Inc(Xp1, 2); Dec(Xp2, 2);
    Inc(Wp1, 2); Dec(Wp2, 2);
    Inc(I);
  end;

  // Pre-rotation
  Yp := @F[0];
  for I := 0 to N4 - 1 do
  begin
    T0 := Trig[I];
    T1 := Trig[N4 + I];
    Re := Yp^; Inc(Yp);
    Im := Yp^; Inc(Yp);
    Yr := Re * T0 - Im * T1;
    Yi := Im * T0 + Re * T1;
    F2[Bitrev[I]].R := Scale * Yr;
    F2[Bitrev[I]].I := Scale * Yi;
  end;

  OpusFftImpl(Shift, @F2[0]);

  // Post-rotate
  Fp := @F2[0];
  Yp1 := Outp;
  Yp2 := Outp + Stride * (N2 - 1);
  for I := 0 to N4 - 1 do
  begin
    Yr := Fp.I * Trig[N4 + I] - Fp.R * Trig[I];
    Yi := Fp.R * Trig[N4 + I] + Fp.I * Trig[I];
    Yp1^ := Yr;
    Yp2^ := Yi;
    Inc(Fp);
    Inc(Yp1, 2 * Stride);
    Dec(Yp2, 2 * Stride);
  end;
end;

// ---------------------------------------------------------------------------
// cwrs.c (SMALL_FOOTPRINT): encode_pulses
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

function Icwrs(N, K: Integer; out Nc: Cardinal; Y: PInteger; U: PCardinal): Cardinal;
var
  I: Cardinal;
  J, KK: Integer;
begin
  U[0] := 0;
  for KK := 1 to K + 1 do
    U[KK] := (Cardinal(KK) shl 1) - 1;
  // icwrs1
  KK := Abs(Y[N - 1]);
  I := Ord(Y[N - 1] < 0);
  J := N - 2;
  I := I + U[KK];
  KK := KK + Abs(Y[J]);
  if Y[J] < 0 then I := I + U[KK + 1];
  while J > 0 do
  begin
    Dec(J);
    UNext(U, K + 2, 0);
    I := I + U[KK];
    KK := KK + Abs(Y[J]);
    if Y[J] < 0 then I := I + U[KK + 1];
  end;
  Nc := U[KK] + U[KK + 1];
  Result := I;
end;

procedure EncodePulses(Y: PInteger; N, K: Integer; var Enc: TEcEnc);
var
  U : array of Cardinal;
  I, Nc: Cardinal;
begin
  SetLength(U, K + 2);
  I := Icwrs(N, K, Nc, Y, @U[0]);
  EcEncUInt(Enc, I, Nc);
end;

// ---------------------------------------------------------------------------
// vq.c
// ---------------------------------------------------------------------------

procedure ExpRotation1F(X: PSingle; Len, Stride: Integer; C, S: Single);
var
  I : Integer;
  Ms: Single;
  X1, X2: Single;
  P : PSingle;
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

procedure ExpRotationF(X: PSingle; Len, Dir, Stride, K, Spread: Integer);
const
  SPREAD_FACTOR: array[0..2] of Integer = (15, 10, 5);
  HALF_PI_F: Single = 0.5 * 3.141592653;   // (.5f*PI) folded in float
var
  I, Stride2, Factor: Integer;
  C, S, Gain, Theta, Arg: Single;
begin
  if (2 * K >= Len) or (Spread = CELT_SPREAD_NONE) then Exit;
  Factor := SPREAD_FACTOR[Spread - 1];
  Gain := (F_ONE * Len) / Single(Len + Factor * K);
  Theta := F_HALF * (Gain * Gain);
  Arg := HALF_PI_F * Theta;
  C := Cos(Double(Arg));
  Arg := HALF_PI_F * (F_ONE - Theta);
  S := Cos(Double(Arg));
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
        ExpRotation1F(X + I * Len, Len, Stride2, S, C);
      ExpRotation1F(X + I * Len, Len, 1, C, S);
    end
    else
    begin
      ExpRotation1F(X + I * Len, Len, 1, C, -S);
      if Stride2 <> 0 then
        ExpRotation1F(X + I * Len, Len, Stride2, S, -C);
    end;
  end;
end;

function OpPvqSearch(X: PSingle; Iy: PInteger; K, N: Integer): Single;
const
  K08: Single = 0.8;
  F64: Single = 64;
var
  Y   : array of Single;
  SignX: array of Integer;
  I, J, PulsesLeft, BestId: Integer;
  Sum, Xy, Yy, Rcp, Rxy, Ryy, BestNum, BestDen, Tmp: Single;
begin
  SetLength(Y, N);
  SetLength(SignX, N);
  Sum := 0;
  for J := 0 to N - 1 do
  begin
    SignX[J] := Ord(X[J] < 0);
    X[J] := Abs(X[J]);
    Iy[J] := 0;
    Y[J] := 0;
  end;
  Xy := 0;
  Yy := 0;
  PulsesLeft := K;
  if K > (N shr 1) then
  begin
    for J := 0 to N - 1 do
      Sum := Sum + X[J];
    if not ((Sum > F_EPSILON) and (Sum < F64)) then
    begin
      X[0] := 1.0;
      for J := 1 to N - 1 do
        X[J] := 0;
      Sum := 1.0;
    end;
    Rcp := (K + K08) * (F_ONE / Sum);
    for J := 0 to N - 1 do
    begin
      Iy[J] := Floor(Rcp * X[J]);
      Y[J] := Iy[J];
      Yy := Yy + Y[J] * Y[J];
      Xy := Xy + X[J] * Y[J];
      Y[J] := Y[J] * 2;
      Dec(PulsesLeft, Iy[J]);
    end;
  end;

  if PulsesLeft > N + 3 then
  begin
    Tmp := PulsesLeft;
    Yy := Yy + Tmp * Tmp;
    Yy := Yy + Tmp * Y[0];
    Inc(Iy[0], PulsesLeft);
    PulsesLeft := 0;
  end;

  for I := 0 to PulsesLeft - 1 do
  begin
    BestId := 0;
    Yy := Yy + 1;
    Rxy := Xy + X[0];
    Ryy := Yy + Y[0];
    Rxy := Rxy * Rxy;
    BestDen := Ryy;
    BestNum := Rxy;
    for J := 1 to N - 1 do
    begin
      Rxy := Xy + X[J];
      Ryy := Yy + Y[J];
      Rxy := Rxy * Rxy;
      if BestDen * Rxy > Ryy * BestNum then
      begin
        BestDen := Ryy;
        BestNum := Rxy;
        BestId := J;
      end;
    end;
    Xy := Xy + X[BestId];
    Yy := Yy + Y[BestId];
    Y[BestId] := Y[BestId] + 2;
    Inc(Iy[BestId]);
  end;

  for J := 0 to N - 1 do
    Iy[J] := (Iy[J] xor -SignX[J]) + SignX[J];
  Result := Yy;
end;

function ExtractCollapseMaskF(Iy: PInteger; N, B: Integer): Cardinal;
var
  N0, I, J: Integer;
  Tmp: Integer;
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

function AlgQuant(X: PSingle; N, K, Spread, B: Integer; var Enc: TEcEnc;
  Gain: Single; Resynth: Boolean): Cardinal;
var
  Iy: array of Integer;
  Yy, G: Single;
  I: Integer;
begin
  SetLength(Iy, N + 3);
  ExpRotationF(X, N, 1, B, K, Spread);
  Yy := OpPvqSearch(X, @Iy[0], K, N);
  EncodePulses(@Iy[0], N, K, Enc);
  if Resynth then
  begin
    // normalise_residual
    G := (F_ONE / SqrtF(Yy)) * Gain;
    for I := 0 to N - 1 do
      X[I] := G * Iy[I];
    ExpRotationF(X, N, -1, B, K, Spread);
  end;
  Result := ExtractCollapseMaskF(@Iy[0], N, B);
end;

procedure RenormaliseVectorF(X: PSingle; N: Integer; Gain: Single);
var
  I: Integer;
  E, G: Single;
begin
  E := F_EPSILON + CeltInnerProd(X, X, N);
  G := (F_ONE / SqrtF(E)) * Gain;
  for I := 0 to N - 1 do
    X[I] := G * X[I];
end;

function StereoItheta(X, Y: PSingle; Stereo: Boolean; N: Integer): Integer;
const
  ITHETA_SCALE: Single = 16384 * 0.63662;   // 16384*0.63662f folded in float
var
  I: Integer;
  Emid, Eside, M, S, Mid, Side: Single;
begin
  Emid := F_EPSILON;
  Eside := F_EPSILON;
  if Stereo then
  begin
    for I := 0 to N - 1 do
    begin
      M := X[I] + Y[I];
      S := X[I] - Y[I];
      Emid := Emid + M * M;
      Eside := Eside + S * S;
    end;
  end
  else
  begin
    Emid := Emid + CeltInnerProd(X, X, N);
    Eside := Eside + CeltInnerProd(Y, Y, N);
  end;
  Mid := SqrtF(Emid);
  Side := SqrtF(Eside);
  Result := Floor(F_HALF + ITHETA_SCALE * FastAtan2F(Side, Mid));
end;

procedure Haar1F(X: PSingle; N0, Stride: Integer);
const
  R2: Single = 0.70710678;
var
  I, J: Integer;
  Tmp1, Tmp2: Single;
begin
  N0 := N0 shr 1;
  for I := 0 to Stride - 1 do
    for J := 0 to N0 - 1 do
    begin
      Tmp1 := R2 * X[Stride * 2 * J + I];
      Tmp2 := R2 * X[Stride * (2 * J + 1) + I];
      X[Stride * 2 * J + I] := Tmp1 + Tmp2;
      X[Stride * (2 * J + 1) + I] := Tmp1 - Tmp2;
    end;
end;

// ---------------------------------------------------------------------------
// celt_lpc.c
// ---------------------------------------------------------------------------

procedure CeltLpc(Lpc: PSingle; Ac: PSingle; P: Integer);
const
  TINY: Single = 1e-10;
  K001: Single = 0.001;
var
  I, J: Integer;
  R, Error, Rr, Tmp1, Tmp2: Single;
begin
  Error := Ac[0];
  for I := 0 to P - 1 do
    Lpc[I] := 0;
  if Ac[0] > TINY then
  begin
    for I := 0 to P - 1 do
    begin
      Rr := 0;
      for J := 0 to I - 1 do
        Rr := Rr + Lpc[J] * Ac[I - J];
      Rr := Rr + Ac[I + 1];
      R := -(Rr / Error);
      Lpc[I] := R;
      for J := 0 to ((I + 1) shr 1) - 1 do
      begin
        Tmp1 := Lpc[J];
        Tmp2 := Lpc[I - 1 - J];
        Lpc[J] := Tmp1 + R * Tmp2;
        Lpc[I - 1 - J] := Tmp2 + R * Tmp1;
      end;
      Error := Error - (R * R) * Error;
      if Error <= K001 * Ac[0] then
        Break;
    end;
  end;
end;

procedure CeltPitchXcorr(X, Y: PSingle; Xcorr: PSingle; Len, MaxPitch: Integer);
var
  I: Integer;
begin
  for I := 0 to MaxPitch - 1 do
    Xcorr[I] := CeltInnerProd(X, Y + I, Len);
end;

procedure CeltAutocorr(X: PSingle; Ac: PSingle; Lag, N: Integer);
var
  I, K, FastN: Integer;
  D: Single;
begin
  FastN := N - Lag;
  CeltPitchXcorr(X, X, Ac, FastN, Lag + 1);
  for K := 0 to Lag do
  begin
    D := 0;
    for I := K + FastN to N - 1 do
      D := D + X[I] * X[I - K];
    Ac[K] := Ac[K] + D;
  end;
end;

// ---------------------------------------------------------------------------
// pitch.c
// ---------------------------------------------------------------------------

procedure CeltFir5(X: PSingle; Num: PSingle; N: Integer);
var
  I: Integer;
  Num0, Num1, Num2, Num3, Num4: Single;
  Mem0, Mem1, Mem2, Mem3, Mem4, Sum: Single;
begin
  Num0 := Num[0]; Num1 := Num[1]; Num2 := Num[2]; Num3 := Num[3]; Num4 := Num[4];
  Mem0 := 0; Mem1 := 0; Mem2 := 0; Mem3 := 0; Mem4 := 0;
  for I := 0 to N - 1 do
  begin
    Sum := X[I];
    Sum := Sum + Num0 * Mem0;
    Sum := Sum + Num1 * Mem1;
    Sum := Sum + Num2 * Mem2;
    Sum := Sum + Num3 * Mem3;
    Sum := Sum + Num4 * Mem4;
    Mem4 := Mem3;
    Mem3 := Mem2;
    Mem2 := Mem1;
    Mem1 := Mem0;
    Mem0 := X[I];
    X[I] := Sum;
  end;
end;

procedure PitchDownsample(const X: array of PSingle; XLp: PSingle; Len, C: Integer);
const
  Q25: Single = 0.25;
  Q5 : Single = 0.5;
  Q9 : Single = 0.9;
  Q8 : Single = 0.8;
  NF : Single = 1.0001;
  LW : Single = 0.008;
var
  I: Integer;
  Ac: array[0..4] of Single;
  Tmp: Single;
  Lpc: array[0..3] of Single;
  Lpc2: array[0..4] of Single;
  X0, X1: PSingle;
begin
  X0 := X[0];
  for I := 1 to (Len shr 1) - 1 do
    XLp[I] := Q25 * X0[2 * I - 1] + Q25 * X0[2 * I + 1] + Q5 * X0[2 * I];
  XLp[0] := Q25 * X0[1] + Q5 * X0[0];
  if C = 2 then
  begin
    X1 := X[1];
    for I := 1 to (Len shr 1) - 1 do
      XLp[I] := XLp[I] + (Q25 * X1[2 * I - 1] + Q25 * X1[2 * I + 1] + Q5 * X1[2 * I]);
    XLp[0] := XLp[0] + (Q25 * X1[1] + Q5 * X1[0]);
  end;
  CeltAutocorr(XLp, @Ac[0], 4, Len shr 1);
  Ac[0] := Ac[0] * NF;
  for I := 1 to 4 do
    Ac[I] := Ac[I] - Ac[I] * (LW * I) * (LW * I);
  CeltLpc(@Lpc[0], @Ac[0], 4);
  Tmp := 1.0;
  for I := 0 to 3 do
  begin
    Tmp := Q9 * Tmp;
    Lpc[I] := Lpc[I] * Tmp;
  end;
  Lpc2[0] := Lpc[0] + Q8;
  Lpc2[1] := Lpc[1] + Q8 * Lpc[0];
  Lpc2[2] := Lpc[2] + Q8 * Lpc[1];
  Lpc2[3] := Lpc[3] + Q8 * Lpc[2];
  Lpc2[4] := Q8 * Lpc[3];
  CeltFir5(XLp, @Lpc2[0], Len shr 1);
end;

procedure FindBestPitch(Xcorr, Y: PSingle; Len, MaxPitch: Integer; BestPitch: PInteger);
const
  SCALE12: Single = 1e-12;
var
  I, J: Integer;
  Syy, Num, Xcorr16: Single;
  BestNum, BestDen: array[0..1] of Single;
begin
  Syy := 1;
  BestNum[0] := -1; BestNum[1] := -1;
  BestDen[0] := 0;  BestDen[1] := 0;
  BestPitch[0] := 0;
  BestPitch[1] := 1;
  for J := 0 to Len - 1 do
    Syy := Syy + Y[J] * Y[J];
  for I := 0 to MaxPitch - 1 do
  begin
    if Xcorr[I] > 0 then
    begin
      Xcorr16 := Xcorr[I];
      Xcorr16 := Xcorr16 * SCALE12;
      Num := Xcorr16 * Xcorr16;
      if Num * BestDen[1] > BestNum[1] * Syy then
      begin
        if Num * BestDen[0] > BestNum[0] * Syy then
        begin
          BestNum[1] := BestNum[0];
          BestDen[1] := BestDen[0];
          BestPitch[1] := BestPitch[0];
          BestNum[0] := Num;
          BestDen[0] := Syy;
          BestPitch[0] := I;
        end
        else
        begin
          BestNum[1] := Num;
          BestDen[1] := Syy;
          BestPitch[1] := I;
        end;
      end;
    end;
    Syy := Syy + (Y[I + Len] * Y[I + Len] - Y[I] * Y[I]);
    if Syy < 1 then Syy := 1;
  end;
end;

procedure PitchSearch(XLp, Y: PSingle; Len, MaxPitch: Integer; out Pitch: Integer);
const
  Q7: Single = 0.7;
var
  I, J, Lag, Offset: Integer;
  BestPitch: array[0..1] of Integer;
  XLp4, YLp4, Xcorr: array of Single;
  Sum, A, B, C: Single;
begin
  Lag := Len + MaxPitch;
  SetLength(XLp4, Len shr 2);
  SetLength(YLp4, Lag shr 2);
  SetLength(Xcorr, MaxPitch shr 1);
  BestPitch[0] := 0; BestPitch[1] := 0;
  for J := 0 to (Len shr 2) - 1 do
    XLp4[J] := XLp[2 * J];
  for J := 0 to (Lag shr 2) - 1 do
    YLp4[J] := Y[2 * J];

  CeltPitchXcorr(@XLp4[0], @YLp4[0], @Xcorr[0], Len shr 2, MaxPitch shr 2);
  FindBestPitch(@Xcorr[0], @YLp4[0], Len shr 2, MaxPitch shr 2, @BestPitch[0]);

  for I := 0 to (MaxPitch shr 1) - 1 do
  begin
    Xcorr[I] := 0;
    if (Abs(I - 2 * BestPitch[0]) > 2) and (Abs(I - 2 * BestPitch[1]) > 2) then
      Continue;
    Sum := CeltInnerProd(XLp, Y + I, Len shr 1);
    if Sum < -1 then Xcorr[I] := -1 else Xcorr[I] := Sum;
  end;
  FindBestPitch(@Xcorr[0], Y, Len shr 1, MaxPitch shr 1, @BestPitch[0]);

  if (BestPitch[0] > 0) and (BestPitch[0] < (MaxPitch shr 1) - 1) then
  begin
    A := Xcorr[BestPitch[0] - 1];
    B := Xcorr[BestPitch[0]];
    C := Xcorr[BestPitch[0] + 1];
    if (C - A) > Q7 * (B - A) then Offset := 1
    else if (A - C) > Q7 * (B - C) then Offset := -1
    else Offset := 0;
  end
  else
    Offset := 0;
  Pitch := 2 * BestPitch[0] - Offset;
end;

function ComputePitchGain(Xy, Xx, Yy: Single): Single; inline;
begin
  Result := Xy / SqrtF(1 + Xx * Yy);
end;

function RemoveDoubling(X: PSingle; MaxPeriod, MinPeriod, N: Integer;
  var T0_: Integer; PrevPeriod: Integer; PrevGain: Single): Single;
const
  SECOND_CHECK: array[0..15] of Integer = (0, 0, 3, 2, 3, 2, 5, 2, 3, 2, 3, 2, 5, 2, 3, 2);
  Q3 : Single = 0.3;
  Q4 : Single = 0.4;
  Q5 : Single = 0.5;
  Q7 : Single = 0.7;
  Q85: Single = 0.85;
  Q9 : Single = 0.9;
var
  K, I, T, T0, T1, T1b, Offset, MinPeriod0: Integer;
  G, G0, Pg, Xy, Xx, Yy, Xy2, BestXy, BestYy, G1, Cont, Thresh: Single;
  Xcorr: array[0..2] of Single;
  YyLookup: array of Single;
begin
  MinPeriod0 := MinPeriod;
  MaxPeriod := MaxPeriod div 2;
  MinPeriod := MinPeriod div 2;
  T0_ := T0_ div 2;
  PrevPeriod := PrevPeriod div 2;
  N := N div 2;
  X := X + MaxPeriod;
  if T0_ >= MaxPeriod then
    T0_ := MaxPeriod - 1;
  T0 := T0_;
  T := T0;
  SetLength(YyLookup, MaxPeriod + 1);
  // dual_inner_prod(x, x, x-T0, N, &xx, &xy)
  Xx := 0; Xy := 0;
  for I := 0 to N - 1 do
  begin
    Xx := Xx + X[I] * X[I];
    Xy := Xy + X[I] * X[I - T0];
  end;
  YyLookup[0] := Xx;
  Yy := Xx;
  for I := 1 to MaxPeriod do
  begin
    Yy := Yy + X[-I] * X[-I] - X[N - I] * X[N - I];
    if Yy > 0 then YyLookup[I] := Yy else YyLookup[I] := 0;
  end;
  Yy := YyLookup[T0];
  BestXy := Xy;
  BestYy := Yy;
  G0 := ComputePitchGain(Xy, Xx, Yy);
  G := G0;
  for K := 2 to 15 do
  begin
    T1 := (2 * T0 + K) div (2 * K);
    if T1 < MinPeriod then
      Break;
    if K = 2 then
    begin
      if T1 + T0 > MaxPeriod then T1b := T0
      else T1b := T0 + T1;
    end
    else
      T1b := (2 * SECOND_CHECK[K] * T0 + K) div (2 * K);
    Xy := 0; Xy2 := 0;
    for I := 0 to N - 1 do
    begin
      Xy := Xy + X[I] * X[I - T1];
      Xy2 := Xy2 + X[I] * X[I - T1b];
    end;
    Xy := F_HALF * (Xy + Xy2);
    Yy := F_HALF * (YyLookup[T1] + YyLookup[T1b]);
    G1 := ComputePitchGain(Xy, Xx, Yy);
    if Abs(T1 - PrevPeriod) <= 1 then
      Cont := PrevGain
    else if (Abs(T1 - PrevPeriod) <= 2) and (5 * K * K < T0) then
      Cont := F_HALF * PrevGain
    else
      Cont := 0;
    Thresh := Max(Q3, Q7 * G0 - Cont);
    if T1 < 3 * MinPeriod then
      Thresh := Max(Q4, Q85 * G0 - Cont)
    else if T1 < 2 * MinPeriod then
      Thresh := Max(Q5, Q9 * G0 - Cont);
    if G1 > Thresh then
    begin
      BestXy := Xy;
      BestYy := Yy;
      T := T1;
      G := G1;
    end;
  end;
  if BestXy < 0 then BestXy := 0;
  if BestYy <= BestXy then
    Pg := 1.0
  else
    Pg := BestXy / (BestYy + 1);

  for K := 0 to 2 do
    Xcorr[K] := CeltInnerProd(X, X - (T + K - 1), N);
  if (Xcorr[2] - Xcorr[0]) > Q7 * (Xcorr[1] - Xcorr[0]) then
    Offset := 1
  else if (Xcorr[0] - Xcorr[2]) > Q7 * (Xcorr[1] - Xcorr[2]) then
    Offset := -1
  else
    Offset := 0;
  if Pg > G then
    Pg := G;
  T0_ := 2 * T + Offset;
  if T0_ < MinPeriod0 then
    T0_ := MinPeriod0;
  Result := Pg;
end;

// ---------------------------------------------------------------------------
// celt.c: comb_filter / comb_filter_const_c (float)
// ---------------------------------------------------------------------------

procedure CombFilterConstF(Y, X: PSingle; T, N: Integer; G10, G11, G12: Single);
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

procedure CombFilterF(Y, X: PSingle; T0, T1, N: Integer; G0, G1: Single;
  Tapset0, Tapset1: Integer; Window: PSingle; Overlap: Integer);
const
  Gains: array[0..2, 0..2] of Single = (
    (0.3066406250, 0.2170410156, 0.1296386719),
    (0.4638671875, 0.2680664062, 0.0),
    (0.7998046875, 0.1000976562, 0.0));
var
  I: Integer;
  G00, G01, G02, G10, G11, G12: Single;
  X0, X1, X2, X3, X4, F, OmF: Single;
begin
  if (G0 = 0) and (G1 = 0) then
  begin
    if X <> Y then Move(X^, Y^, N * SizeOf(Single));
    Exit;
  end;
  if T0 < COMBFILTER_MINPERIOD then T0 := COMBFILTER_MINPERIOD;
  if T1 < COMBFILTER_MINPERIOD then T1 := COMBFILTER_MINPERIOD;
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
    OmF := F_ONE - F;
    Y[I] := X[I]
          + (OmF * G00) * X[I - T0]
          + (OmF * G01) * (X[I - T0 + 1] + X[I - T0 - 1])
          + (OmF * G02) * (X[I - T0 + 2] + X[I - T0 - 2])
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
  CombFilterConstF(Y + Overlap, X + Overlap, T1, N - Overlap, G10, G11, G12);
end;

end.
