unit G729Encoder;

{
  G729Encoder.pas - ITU-T G.729 Annex A encoder

  Written from the text of Recommendation ITU-T G.729 (06/2012), clause 3
  and clause A.3, in floating point. The bit stream is the standard G.729
  one (10 octets per 10 ms frame) and can be decoded by any G.729 or
  G.729A decoder.

  Where the Recommendation leaves the search strategy to the implementer,
  this encoder uses exact searches instead of the reduced-complexity ones:
    - LSP roots: grid search followed by bisection to full precision
    - open-loop pitch: full-rate correlations (clause 3.4 selection rule)
    - fixed codebook: exhaustive search of the 8192 pulse combinations
    - gains: exhaustive search of the 8 x 16 conjugate codebook
  The perceptual weighting is the Annex A one: W(z) = A(z)/A(z/0.75) with
  quantized coefficients.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  SysUtils, G729Common;

type
  TG729Encoder = class
  private
    FLsf: TG729LsfState;
    FGain: TG729GainPredictor;
    FWindow: array[0..239] of Double;     // w_lp(n), equation (3)
    FLagWin: array[1..G729_ORDER] of Double;
    FSpeech: array[0..239] of Double;     // 120 past + 80 current + 40 look-ahead
    FHpX1, FHpX2, FHpY1, FHpY2: Double;   // pre-processing filter
    FPrevW: TLsf;                         // previous unquantized LSF (fallback)
    FPrevQ: TLsf;                         // previous quantized LSP
    FPrevA: TLpc;                         // previous unquantized LP filter (fallback)
    FExcBuf: array[0..G729_PIT_MAX + G729_INTERP + G729_FRAME] of Double;
    FSw: array[0..G729_PIT_MAX + G729_FRAME - 1] of Double;   // weighted speech history + frame
    FSwMem: array[0..G729_ORDER] of Double;     // memory of 1/A'(z), most recent first
    FWMem: array[0..G729_ORDER - 1] of Double;  // memory of 1/A(z/g) (weighted error)
    FBeta: Double;
    FPending: array[0..G729_FRAME - 1] of SmallInt;
    FPendingCount: Integer;
    procedure Preprocess(PCM: PSmallInt);
    procedure AnalyzeLp(out A: TLpc);
    procedure LpToLsf(const A: TLpc; out W: TLsf);
    procedure QuantizeLsf(const W: TLsf; out P: TG729Params; out WQ: TLsf);
    function OpenLoopPitch: Integer;
    procedure EncodeFrame(PCM: PSmallInt; Output: PByte);
  public
    constructor Create;
    procedure Reset;
    // Encodes exactly 80 samples (10 ms at 8 kHz) into 10 octets.
    procedure EncodeFrame10ms(PCM: PSmallInt; Output: PByte);
    // Encodes N samples (any count); writes 10 octets per complete frame and keeps
    // the remainder for the next call. Returns the number of octets written.
    function Encode(PCM: PSmallInt; N: Integer; Output: PByte): Integer; overload;
    function Encode(const PCM: array of SmallInt): TBytes; overload;
  end;

implementation

uses
  Math, G729Tables;

const
  GAMMA_W = 0.75;
  EXC_OFS = G729_PIT_MAX + G729_INTERP;
  SW_OFS = G729_PIT_MAX;
  // pre-processing high-pass filter with 1/2 scaling (equation 1)
  PP_B0 = 0.46363718; PP_B1 = -0.92724705; PP_B2 = 0.46363718;
  PP_A1 = 1.9059465; PP_A2 = -0.9114024;

{ helpers }

// y = x filtered by 1/A(z), Mem holds past outputs (most recent first) and is updated
procedure SynthFilter(const A: TLpc; X: PDouble; Y: PDouble; N: Integer; var Mem: array of Double);
var
  I, K: Integer;
  S: Double;
begin
  for I := 0 to N - 1 do
  begin
    S := X[I];
    for K := 1 to G729_ORDER do S := S - A[K] * Mem[K - 1];
    for K := G729_ORDER - 1 downto 1 do Mem[K] := Mem[K - 1];
    Mem[0] := S;
    Y[I] := S;
  end;
end;

procedure Bandwidth(const A: TLpc; G: Double; out B: TLpc);
var
  I: Integer;
  F: Double;
begin
  F := 1;
  for I := 0 to G729_ORDER do
  begin
    B[I] := A[I] * F;
    F := F * G;
  end;
end;

{ TG729Encoder }

constructor TG729Encoder.Create;
var
  N, K: Integer;
begin
  inherited Create;
  for N := 0 to 199 do FWindow[N] := 0.54 - 0.46 * Cos(2 * Pi * N / 399);
  for N := 200 to 239 do FWindow[N] := Cos(2 * Pi * (N - 200) / 159);
  for K := 1 to G729_ORDER do
    FLagWin[K] := Exp(-0.5 * Sqr(2 * Pi * 60 * K / 8000));
  Reset;
end;

procedure TG729Encoder.Reset;
var
  I: Integer;
begin
  FLsf.Init;
  FGain.Init;
  FillChar(FSpeech, SizeOf(FSpeech), 0);
  FHpX1 := 0; FHpX2 := 0; FHpY1 := 0; FHpY2 := 0;
  for I := 0 to G729_ORDER - 1 do FPrevW[I] := (I + 1) * Pi / 11;
  LsfToLsp(FPrevW, FPrevQ);
  LspToLp(FPrevQ, FPrevA);
  FillChar(FExcBuf, SizeOf(FExcBuf), 0);
  FillChar(FSw, SizeOf(FSw), 0);
  FillChar(FSwMem, SizeOf(FSwMem), 0);
  FillChar(FWMem, SizeOf(FWMem), 0);
  FBeta := 0.8;
  FPendingCount := 0;
end;

procedure TG729Encoder.Preprocess(PCM: PSmallInt);
var
  N: Integer;
  X, Y: Double;
begin
  Move(FSpeech[G729_FRAME], FSpeech[0], (240 - G729_FRAME) * SizeOf(Double));
  for N := 0 to G729_FRAME - 1 do
  begin
    X := PCM[N];
    Y := PP_B0 * X + PP_B1 * FHpX1 + PP_B2 * FHpX2 + PP_A1 * FHpY1 + PP_A2 * FHpY2;
    FHpX2 := FHpX1; FHpX1 := X;
    FHpY2 := FHpY1; FHpY1 := Y;
    FSpeech[240 - G729_FRAME + N] := Y;
  end;
end;

// Windowing, autocorrelation, lag window and Levinson-Durbin (3.2.1, 3.2.2)
procedure TG729Encoder.AnalyzeLp(out A: TLpc);
var
  S: array[0..239] of Double;
  R: array[0..G729_ORDER] of Double;
  Tmp: TLpc;
  N, K, I, J: Integer;
  E, Ki, Acc: Double;
begin
  for N := 0 to 239 do S[N] := FWindow[N] * FSpeech[N];
  for K := 0 to G729_ORDER do
  begin
    Acc := 0;
    for N := K to 239 do Acc := Acc + S[N] * S[N - K];
    R[K] := Acc;
  end;
  if R[0] < 1.0 then R[0] := 1.0;
  R[0] := R[0] * 1.0001;
  for K := 1 to G729_ORDER do R[K] := R[K] * FLagWin[K];

  A[0] := 1;
  for I := 1 to G729_ORDER do A[I] := 0;
  E := R[0];
  for I := 1 to G729_ORDER do
  begin
    Acc := 0;
    for J := 0 to I - 1 do Acc := Acc + A[J] * R[I - J];
    Ki := -Acc / E;
    if Abs(Ki) >= 1 then
    begin
      A := FPrevA;          // unstable: keep the previous filter
      Exit;
    end;
    Tmp := A;
    A[I] := Ki;
    for J := 1 to I - 1 do A[J] := Tmp[J] + Ki * Tmp[I - J];
    E := E * (1 - Ki * Ki);
  end;
  FPrevA := A;
end;

// LP -> LSP conversion (3.2.3); falls back to the previous LSF if roots are missing
procedure TG729Encoder.LpToLsf(const A: TLpc; out W: TLsf);
begin
  if G729Common.LpToLsf(A, W) then FPrevW := W
  else W := FPrevW;
end;

// LSF quantization (3.2.4): both MA predictors, L1 then L2 then L3
procedure TG729Encoder.QuantizeLsf(const W: TLsf; out P: TG729Params; out WQ: TLsf);
var
  Wt: TLsf;
  Mode, I, K, C, Best1, Best2, Best3, BestMode: Integer;
  BestL1, BestL2, BestL3: array[0..1] of Integer;
  BestErr: array[0..1] of Double;
  Target, L, Wsc: TLsf;
  Err, E, D, SumP: Double;
begin
  // weights (equation 22), with w5 and w6 multiplied by 1.2
  D := W[1] - 0.04 * Pi - 1;
  if D > 0 then Wt[0] := 1 else Wt[0] := 10 * D * D + 1;
  for I := 1 to 8 do
  begin
    D := W[I + 1] - W[I - 1] - 1;
    if D > 0 then Wt[I] := 1 else Wt[I] := 10 * D * D + 1;
  end;
  D := -W[8] + 0.92 * Pi - 1;
  if D > 0 then Wt[9] := 1 else Wt[9] := 10 * D * D + 1;
  Wt[4] := Wt[4] * 1.2;
  Wt[5] := Wt[5] * 1.2;

  for Mode := 0 to 1 do
  begin
    // target codeword (equation 23) and error weights in the codeword domain
    for I := 0 to G729_ORDER - 1 do
    begin
      SumP := MA_PRED_SUM[Mode][I] / 32768;
      E := W[I];
      for K := 0 to 3 do E := E - MA_PRED[Mode][K][I] / 32768 * FLsf.PrevL[K][I];
      Target[I] := E / SumP;
      Wsc[I] := Wt[I] * SumP * SumP;
    end;
    // first stage: unweighted MSE
    Best1 := 0; BestErr[Mode] := MaxDouble;
    for C := 0 to 127 do
    begin
      Err := 0;
      for I := 0 to G729_ORDER - 1 do Err := Err + Sqr(Target[I] - LSPCB1[C][I] / 8192);
      if Err < BestErr[Mode] then begin BestErr[Mode] := Err; Best1 := C; end;
    end;
    // second stage, lower part
    Best2 := 0; BestErr[Mode] := MaxDouble;
    for C := 0 to 31 do
    begin
      for I := 0 to 4 do L[I] := (LSPCB1[Best1][I] + LSPCB2[C][I]) / 8192;
      for I := 5 to 9 do L[I] := LSPCB1[Best1][I] / 8192;
      LsfRearrange(L, 0.0012);
      Err := 0;
      for I := 0 to 4 do Err := Err + Wsc[I] * Sqr(Target[I] - L[I]);
      if Err < BestErr[Mode] then begin BestErr[Mode] := Err; Best2 := C; end;
    end;
    // second stage, higher part
    Best3 := 0; BestErr[Mode] := MaxDouble;
    for C := 0 to 31 do
    begin
      for I := 0 to 4 do L[I] := (LSPCB1[Best1][I] + LSPCB2[Best2][I]) / 8192;
      for I := 5 to 9 do L[I] := (LSPCB1[Best1][I] + LSPCB2[C][I]) / 8192;
      LsfRearrange(L, 0.0012);
      Err := 0;
      for I := 5 to 9 do Err := Err + Wsc[I] * Sqr(Target[I] - L[I]);
      if Err < BestErr[Mode] then begin BestErr[Mode] := Err; Best3 := C; end;
    end;
    // full weighted error of the selected vector
    for I := 0 to 4 do L[I] := (LSPCB1[Best1][I] + LSPCB2[Best2][I]) / 8192;
    for I := 5 to 9 do L[I] := (LSPCB1[Best1][I] + LSPCB2[Best3][I]) / 8192;
    LsfRearrange(L, 0.0012);
    LsfRearrange(L, 0.0006);
    Err := 0;
    for I := 0 to G729_ORDER - 1 do Err := Err + Wsc[I] * Sqr(Target[I] - L[I]);
    BestErr[Mode] := Err;
    BestL1[Mode] := Best1; BestL2[Mode] := Best2; BestL3[Mode] := Best3;
  end;
  if BestErr[1] < BestErr[0] then BestMode := 1 else BestMode := 0;
  P.L0 := BestMode;
  P.L1 := BestL1[BestMode];
  P.L2 := BestL2[BestMode];
  P.L3 := BestL3[BestMode];
  // decode exactly as the decoder does, which also updates the MA memory
  LsfDecode(FLsf, P.L0, P.L1, P.L2, P.L3, WQ);
end;

// Open-loop pitch on the weighted speech of the current frame (3.4)
function TG729Encoder.OpenLoopPitch: Integer;

  procedure BestIn(TLo, THi: Integer; out T: Integer; out RN: Double);
  var
    K, N: Integer;
    R, Best, E: Double;
    Sw: PDouble;
  begin
    Sw := @FSw[SW_OFS];
    Best := -MaxDouble; T := TLo;
    for K := TLo to THi do
    begin
      R := 0;
      for N := 0 to G729_FRAME - 1 do R := R + Sw[N] * Sw[N - K];
      if R > Best then begin Best := R; T := K; end;
    end;
    E := 0;
    for N := 0 to G729_FRAME - 1 do E := E + Sqr(Sw[N - T]);
    if E > 0 then RN := Best / Sqrt(E) else RN := 0;
  end;

var
  T1, T2, T3: Integer;
  R1, R2, R3, RBest: Double;
begin
  BestIn(80, 143, T1, R1);
  BestIn(40, 79, T2, R2);
  BestIn(20, 39, T3, R3);
  Result := T1; RBest := R1;
  if R2 >= 0.85 * RBest then begin Result := T2; RBest := R2; end;
  if R3 >= 0.85 * RBest then Result := T3;
end;

procedure TG729Encoder.EncodeFrame(PCM: PSmallInt; Output: PByte);
var
  P: TG729Params;
  A, AW, AP: TLpc;
  Aq: array[0..1] of TLpc;
  W, WQ, Q, QI: TLsf;
  Sf, N, I, J, K, T, Top, TMin, TMax, IntT, Frac, D, BestD, DLo, DHi: Integer;
  Res, H, X, Xb, Y, Z, Code, Hs, Dn, Xp: array[0..G729_SUBFR - 1] of Double;
  Phi: array[0..G729_SUBFR - 1, 0..G729_SUBFR - 1] of Double;
  Exc, Spe: PDouble;
  Corr, BestCorr, Gp, Gc, Gpred, E, BestE, Xy, Yy, Xz, Zz, Yz, G1, G2: Double;
  IntT1, M0, M1, M2, M3, I0, I1, I2, I3, BestPos0, BestPos1, BestPos2, BestPos3: Integer;
  C0, C1, C2, C3, E0, E1, E2, E3, Num, BestNum, BestDen: Double;
  Sg: array[0..G729_SUBFR - 1] of Double;
  GA, GB, BestGA, BestGB, Ci, Si: Integer;
  Mem: array[0..G729_ORDER - 1] of Double;
begin
  Preprocess(PCM);
  // current frame: FSpeech[120..199]; look-ahead 200..239
  AnalyzeLp(A);
  LpToLsf(A, W);
  QuantizeLsf(W, P, WQ);
  LsfToLsp(WQ, Q);
  for I := 0 to G729_ORDER - 1 do QI[I] := 0.5 * (FPrevQ[I] + Q[I]);
  LspToLp(QI, Aq[0]);
  LspToLp(Q, Aq[1]);
  FPrevQ := Q;

  // weighted speech of the frame for the open-loop pitch (A.3.3):
  // residual through A(z), then 1/A'(z) with A'(z) = A(z/g)(1 - 0.7 z^-1)
  Spe := @FSpeech[120];
  for Sf := 0 to 1 do
  begin
    Bandwidth(Aq[Sf], GAMMA_W, AW);
    AP[0] := 1;
    for I := 1 to G729_ORDER do AP[I] := AW[I] - 0.7 * AW[I - 1];
    for N := 0 to G729_SUBFR - 1 do
    begin
      E := Spe[Sf * G729_SUBFR + N];
      for I := 1 to G729_ORDER do E := E + Aq[Sf][I] * Spe[Sf * G729_SUBFR + N - I];
      // 1/A'(z): A'(z) has 11 coefficients, the last one is -0.7 * AW(10)
      for I := 1 to G729_ORDER do E := E - AP[I] * FSwMem[I - 1];
      E := E + 0.7 * AW[G729_ORDER] * FSwMem[G729_ORDER];
      for I := G729_ORDER downto 1 do FSwMem[I] := FSwMem[I - 1];
      FSwMem[0] := E;
      FSw[SW_OFS + Sf * G729_SUBFR + N] := E;
    end;
  end;
  Top := OpenLoopPitch;

  IntT1 := Top;
  for Sf := 0 to 1 do
  begin
    Exc := @FExcBuf[EXC_OFS + Sf * G729_SUBFR];
    Bandwidth(Aq[Sf], GAMMA_W, AW);

    // impulse response of 1/A(z/g) (A.3.5)
    for N := 0 to G729_SUBFR - 1 do
    begin
      if N = 0 then E := 1 else E := 0;
      for I := 1 to Min(N, G729_ORDER) do E := E - AW[I] * H[N - I];
      H[N] := E;
    end;

    // residual (A.3) and target x(n) through 1/A(z/g) (A.3.6)
    for N := 0 to G729_SUBFR - 1 do
    begin
      E := Spe[Sf * G729_SUBFR + N];
      for I := 1 to G729_ORDER do E := E + Aq[Sf][I] * Spe[Sf * G729_SUBFR + N - I];
      Res[N] := E;
      Exc[N] := E;      // extends the past excitation for the search
    end;
    Move(FWMem, Mem, SizeOf(Mem));
    SynthFilter(AW, @Res[0], @X[0], G729_SUBFR, Mem);

    // backward filtered target xb(n) = sum x(i) h(i - n)
    for N := 0 to G729_SUBFR - 1 do
    begin
      E := 0;
      for I := N to G729_SUBFR - 1 do E := E + X[I] * H[I - N];
      Xb[N] := E;
    end;

    // adaptive-codebook search (A.3.7), delays in thirds of a sample
    if Sf = 0 then
    begin
      TMin := Top - 3;
      if TMin < G729_PIT_MIN then TMin := G729_PIT_MIN;
      TMax := TMin + 6;
      if TMax > G729_PIT_MAX then begin TMax := G729_PIT_MAX; TMin := TMax - 6; end;
    end
    else
      PitchRange2(IntT1, TMin, TMax);
    BestCorr := -MaxDouble; IntT := TMin;
    for K := TMin to TMax do
    begin
      Corr := 0;
      for N := 0 to G729_SUBFR - 1 do Corr := Corr + Xb[N] * Exc[N - K];
      if Corr > BestCorr then begin BestCorr := Corr; IntT := K; end;
    end;
    BestD := 3 * IntT;
    if (Sf = 1) or (IntT < 85) then
    begin
      if Sf = 0 then begin DLo := 3 * IntT - 1; DHi := 3 * IntT + 1; if DLo < 3 * 19 + 1 then DLo := 3 * 19 + 1; end
      else begin DLo := Max(3 * IntT - 1, 3 * TMin - 2); DHi := Min(3 * IntT + 1, 3 * TMax + 2); end;
      BestCorr := -MaxDouble;
      for D := DLo to DHi do
      begin
        J := (D + 1) div 3; Frac := D - 3 * J;
        PitchToKT(J, Frac, K, T);
        // interpolated past excitation u_kt(n) (equation A.8) without writing Exc
        Corr := 0;
        for N := 0 to G729_SUBFR - 1 do
        begin
          E := 0;
          for I := 0 to 9 do
          begin
            E := E + Exc[N - K - I] * B30[T + 3 * I];
            E := E + Exc[N - K + 1 + I] * B30[3 - T + 3 * I];
          end;
          Corr := Corr + Xb[N] * E;
        end;
        if Corr > BestCorr then begin BestCorr := Corr; BestD := D; end;
      end;
    end;
    IntT := (BestD + 1) div 3;
    Frac := BestD - 3 * IntT;
    if Sf = 0 then
    begin
      if (IntT < 85) or ((IntT = 85) and (Frac <= 0)) then P.P1 := 3 * (IntT - 19) + Frac - 1
      else P.P1 := IntT - 85 + 197;
      P.P0 := PitchParity(P.P1);
      IntT1 := IntT;
    end
    else
      P.P2 := 3 * (IntT - TMin) + Frac + 2;

    // adaptive-codebook vector v(n) and its filtered version y(n)
    PitchToKT(IntT, Frac, K, T);
    AdaptiveVector(Exc, K, T);
    for N := 0 to G729_SUBFR - 1 do
    begin
      E := 0;
      for I := 0 to N do E := E + Exc[I] * H[N - I];
      Y[N] := E;
    end;
    Xy := 0; Yy := 0;
    for N := 0 to G729_SUBFR - 1 do
    begin
      Xy := Xy + X[N] * Y[N];
      Yy := Yy + Y[N] * Y[N];
    end;
    if Yy > 0 then Gp := EnsureRange(Xy / Yy, 0, 1.2) else Gp := 0;

    // fixed-codebook search (3.8) on x'(n) with the pitch-sharpened h(n)
    for N := 0 to G729_SUBFR - 1 do Xp[N] := X[N] - Gp * Y[N];
    Hs := H;
    if IntT < G729_SUBFR then
      for N := IntT to G729_SUBFR - 1 do Hs[N] := Hs[N] + FBeta * Hs[N - IntT];
    for N := 0 to G729_SUBFR - 1 do
    begin
      E := 0;
      for I := N to G729_SUBFR - 1 do E := E + Xp[I] * Hs[I - N];
      Dn[N] := E;
      if E >= 0 then Sg[N] := 1 else Sg[N] := -1;
    end;
    for I := 0 to G729_SUBFR - 1 do
      for J := I to G729_SUBFR - 1 do
      begin
        E := 0;
        for N := J to G729_SUBFR - 1 do E := E + Hs[N - I] * Hs[N - J];
        E := E * Sg[I] * Sg[J];
        Phi[I][J] := E;
        Phi[J][I] := E;
      end;
    BestNum := -1; BestDen := 1;
    BestPos0 := 0; BestPos1 := 1; BestPos2 := 2; BestPos3 := 3;
    for I0 := 0 to 7 do
    begin
      M0 := 5 * I0;
      C0 := Abs(Dn[M0]); E0 := Phi[M0][M0];
      for I1 := 0 to 7 do
      begin
        M1 := 5 * I1 + 1;
        C1 := C0 + Abs(Dn[M1]); E1 := E0 + Phi[M1][M1] + 2 * Phi[M0][M1];
        for I2 := 0 to 7 do
        begin
          M2 := 5 * I2 + 2;
          C2 := C1 + Abs(Dn[M2]);
          E2 := E1 + Phi[M2][M2] + 2 * (Phi[M0][M2] + Phi[M1][M2]);
          for I3 := 0 to 15 do
          begin
            M3 := 5 * (I3 shr 1) + 3 + (I3 and 1);
            C3 := C2 + Abs(Dn[M3]);
            E3 := E2 + Phi[M3][M3] + 2 * (Phi[M0][M3] + Phi[M1][M3] + Phi[M2][M3]);
            Num := C3 * C3;
            if (E3 > 0) and (Num * BestDen > BestNum * E3) then
            begin
              BestNum := Num; BestDen := E3;
              BestPos0 := M0; BestPos1 := M1; BestPos2 := M2; BestPos3 := M3;
            end;
          end;
        end;
      end;
    end;
    Ci := BestPos0 div 5 + 8 * (BestPos1 div 5) + 64 * (BestPos2 div 5) +
          512 * (2 * (BestPos3 div 5) + Ord(BestPos3 mod 5 = 4));
    Si := 0;
    if Sg[BestPos0] > 0 then Si := Si or 1;
    if Sg[BestPos1] > 0 then Si := Si or 2;
    if Sg[BestPos2] > 0 then Si := Si or 4;
    if Sg[BestPos3] > 0 then Si := Si or 8;
    if Sf = 0 then begin P.C1 := Ci; P.S1 := Si; end
    else begin P.C2 := Ci; P.S2 := Si; end;

    // code vector as the decoder builds it (with the pitch sharpening)
    DecodeFixedCodebook(Ci, Si, Code);
    if IntT < G729_SUBFR then
      for N := IntT to G729_SUBFR - 1 do Code[N] := Code[N] + FBeta * Code[N - IntT];
    for N := 0 to G729_SUBFR - 1 do
    begin
      E := 0;
      for I := 0 to N do E := E + Code[I] * H[N - I];
      Z[N] := E;
    end;

    // gain quantization (3.9): exhaustive search of equation (63)
    Xz := 0; Zz := 0; Yz := 0;
    for N := 0 to G729_SUBFR - 1 do
    begin
      Xz := Xz + X[N] * Z[N];
      Zz := Zz + Z[N] * Z[N];
      Yz := Yz + Y[N] * Z[N];
    end;
    Gpred := FGain.PredictedGain(Code);
    BestE := MaxDouble; BestGA := 0; BestGB := 0;
    for GA := 0 to 7 do
      for GB := 0 to 15 do
      begin
        G1 := (GAIN_GA[GA][0] + GAIN_GB[GB][0]) / 16384;
        G2 := Gpred * (GAIN_GA[GA][1] + GAIN_GB[GB][1]) / 8192;
        E := G1 * G1 * Yy + G2 * G2 * Zz - 2 * G1 * Xy - 2 * G2 * Xz + 2 * G1 * G2 * Yz;
        if E < BestE then begin BestE := E; BestGA := GA; BestGB := GB; end;
      end;
    if Sf = 0 then begin P.GA1 := GA_MAP[BestGA]; P.GB1 := GB_MAP[BestGB]; end
    else begin P.GA2 := GA_MAP[BestGA]; P.GB2 := GB_MAP[BestGB]; end;
    Gp := (GAIN_GA[BestGA][0] + GAIN_GB[BestGB][0]) / 16384;
    G1 := (GAIN_GA[BestGA][1] + GAIN_GB[BestGB][1]) / 8192;
    Gc := Gpred * G1;
    FGain.Push(20 * Log10(Max(G1, 1E-10)));
    FBeta := EnsureRange(Gp, 0.2, 0.8);

    // excitation (A.9) and memory update of 1/A(z/g) (A.10)
    for N := 0 to G729_SUBFR - 1 do
      Exc[N] := Gp * Exc[N] + Gc * Code[N];
    for I := 0 to G729_ORDER - 1 do
      FWMem[I] := X[G729_SUBFR - 1 - I] - Gp * Y[G729_SUBFR - 1 - I] - Gc * Z[G729_SUBFR - 1 - I];
  end;

  // shift histories
  Move(FExcBuf[G729_FRAME], FExcBuf[0], EXC_OFS * SizeOf(Double));
  Move(FSw[G729_FRAME], FSw[0], SW_OFS * SizeOf(Double));
  PackFrame(P, Output);
end;

procedure TG729Encoder.EncodeFrame10ms(PCM: PSmallInt; Output: PByte);
begin
  EncodeFrame(PCM, Output);
end;

function TG729Encoder.Encode(PCM: PSmallInt; N: Integer; Output: PByte): Integer;
var
  Take: Integer;
begin
  Result := 0;
  while N > 0 do
  begin
    if (FPendingCount = 0) and (N >= G729_FRAME) then
    begin
      EncodeFrame(PCM, Output);
      Inc(PCM, G729_FRAME); Dec(N, G729_FRAME);
    end
    else
    begin
      Take := Min(N, G729_FRAME - FPendingCount);
      Move(PCM^, FPending[FPendingCount], Take * SizeOf(SmallInt));
      Inc(FPendingCount, Take); Inc(PCM, Take); Dec(N, Take);
      if FPendingCount < G729_FRAME then Break;
      EncodeFrame(@FPending[0], Output);
      FPendingCount := 0;
    end;
    Inc(Output, G729_FRAME_BYTES);
    Inc(Result, G729_FRAME_BYTES);
  end;
end;

function TG729Encoder.Encode(const PCM: array of SmallInt): TBytes;
var
  N: Integer;
begin
  SetLength(Result, ((Length(PCM) + FPendingCount) div G729_FRAME) * G729_FRAME_BYTES);
  if Length(PCM) = 0 then Exit;
  N := Encode(@PCM[0], Length(PCM), PByte(Result));
  SetLength(Result, N);
end;

end.
