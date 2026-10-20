unit G729Decoder;

{
  G729Decoder.pas - ITU-T G.729 Annex A decoder (also decodes full G.729)

  Written from the text of Recommendation ITU-T G.729 (06/2012), clause 4
  and clause A.4, in floating point:
    - parameter decoding (4.1), excitation and LP synthesis
    - Annex A post-processing (A.4.2): integer-delay long-term postfilter,
      tilt compensation, short-term postfilter, adaptive gain control,
      100 Hz high-pass filter and upscaling
    - frame erasure concealment (4.4 / A.4.4) and pitch parity check (4.1.2)

  One instance per channel/call; instances are independent.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  SysUtils, G729Common;

type
  TG729FrameType = (g729Speech, g729SID, g729NoData, g729Lost);

  TG729Decoder = class
  private
    FLsf: TG729LsfState;
    FGain: TG729GainPredictor;
    FPrevW: TLsf;                   // last decoded LSF (radians)
    FPrevQ: TLsf;                   // last decoded LSP (cosine domain)
    FExcBuf: array[0..G729_PIT_MAX + G729_INTERP + G729_FRAME] of Double;
    FSyn: array[0..G729_ORDER - 1] of Double;   // past s^(n), most recent first
    FOldT0: Integer;
    FBeta: Double;                  // pitch sharpening factor
    FPrevGp, FPrevGc: Double;
    FSeed: Word;
    // postfilter
    FRes: array[0..G729_PIT_MAX + 3 + G729_SUBFR - 1] of Double;  // residual history + current
    FPfSyn: array[0..G729_ORDER - 1] of Double;  // memory of 1/A(z/gd), most recent first
    FTiltMem: Double;
    FAgc: Double;
    FHpX1, FHpX2, FHpY1, FHpY2: Double;
    // Annex B (comfort noise generation)
    FPrevType: Integer;             // type of the previous frame: 0 untransmitted, 1 active, 2 SID
    FSidW: TLsf;                    // LSF of the last SID
    FSidGain: Double;               // G~sid
    FCngGain: Double;               // G~t (smoothed target gain)
    FCngSeed: Word;
    FActW: TLsf;                    // LSF of the last valid active frame
    FActEnergyDb: Double;           // excitation energy of the last valid active frame
    function NextRandom: Integer;
    function NextCngRandom: Integer;
    function CngGauss: Double;
    procedure DecodeParams(const P: TG729Params; Erased: Boolean; Output: PSmallInt);
    procedure DecodeCng(NewSid: Boolean; const Sid: array of Integer; Output: PSmallInt);
    procedure SynthAndPost(Sf: Integer; const A: TLpc; IntT: Integer; Exc: PDouble; Output: PSmallInt);
    function Synthesize(const A: TLpc; Exc: PDouble; out Syn: array of Double): Boolean;
    procedure PostFilter(const A: TLpc; IntT: Integer; const Prev, S: array of Double; Output: PSmallInt);
  public
    constructor Create;
    procedure Reset;
    // Decodes one frame: Len = 10 (speech), 2 (Annex B SID) or 0/nil (missing frame).
    // A missing frame after speech is concealed (4.4); after a SID or an untransmitted
    // frame it continues the comfort noise (B.4.5). Always writes 80 samples (8 kHz).
    // Returns how the frame was decoded.
    function Decode(Data: PByte; Len: Integer; Output: PSmallInt): TG729FrameType; overload;
    // Explicit frame type, for streams that distinguish an untransmitted (DTX) frame
    // (g729NoData) from an erased one (g729Lost). Data is used for g729Speech/g729SID.
    function DecodeFrame(FrameType: TG729FrameType; Data: PByte; Output: PSmallInt): TG729FrameType;
    function Decode(const Data: array of Byte; out Samples: TArray<SmallInt>): TG729FrameType; overload;
    // Decodes an RTP payload (RFC 3551): N frames of 10 octets, optionally followed
    // by one 2-octet SID frame. Returns the number of samples written (80 per frame).
    function DecodePayload(Data: PByte; Len: Integer; Output: PSmallInt): Integer;
  end;

implementation

uses
  Math;

const
  GAMMA_N = 0.55;
  GAMMA_D = 0.70;
  GAMMA_P = 0.50;
  GAMMA_T = 0.80;
  EXC_OFS = G729_PIT_MAX + G729_INTERP;   // index of u(0) of the frame in FExcBuf
  OVERFLOW_LIMIT = 32767;
  RES_OFS = G729_PIT_MAX + 3;             // index of r^(0) of the subframe in FRes
  // output high-pass filter (equation 91)
  HP_B0 = 0.93980581; HP_B1 = -1.8795834; HP_B2 = 0.93980581;
  HP_A1 = 1.9330735; HP_A2 = -0.93589199;
  CNG_SEED = 11111;
  CNG_ALPHA = 0.6;
  // Offset between the excitation energy of the last active frame and the SID
  // level used when the first SID of a pause is lost (B.4.5). The text does not
  // define the scale of that energy term; calibrated on the ITU vector tstseq6.
  SID_RECOVERY_DB = 7.0;

{ TG729Decoder }

constructor TG729Decoder.Create;
begin
  inherited Create;
  Reset;
end;

procedure TG729Decoder.Reset;
var
  I: Integer;
begin
  FLsf.Init;
  FGain.Init;
  for I := 0 to G729_ORDER - 1 do
    FPrevW[I] := (I + 1) * Pi / 11;
  LsfToLsp(FPrevW, FPrevQ);
  FillChar(FExcBuf, SizeOf(FExcBuf), 0);
  FillChar(FSyn, SizeOf(FSyn), 0);
  FOldT0 := 60;
  FBeta := 0.8;
  FPrevGp := 0; FPrevGc := 0;
  FSeed := 21845;
  FillChar(FRes, SizeOf(FRes), 0);
  FillChar(FPfSyn, SizeOf(FPfSyn), 0);
  FTiltMem := 0;
  FAgc := 1.0;
  FHpX1 := 0; FHpX2 := 0; FHpY1 := 0; FHpY2 := 0;
  FPrevType := 1;
  FSidW := FPrevW;
  FActW := FPrevW;
  FSidGain := 0;
  FCngGain := 0;
  FCngSeed := CNG_SEED;
  FActEnergyDb := -12;
end;

function TG729Decoder.NextCngRandom: Integer;
begin
  FCngSeed := Word(31821 * FCngSeed + 13849);
  Result := FCngSeed;
end;

// Zero-mean, unit-variance pseudo-Gaussian value (sum of 12 uniform values)
function TG729Decoder.CngGauss: Double;
var
  I: Integer;
begin
  Result := -6;
  for I := 1 to 12 do Result := Result + NextCngRandom / 65536;
end;

function TG729Decoder.NextRandom: Integer;
begin
  FSeed := Word(31821 * FSeed + 13849);
  Result := FSeed;
end;

procedure TG729Decoder.DecodeParams(const P: TG729Params; Erased: Boolean; Output: PSmallInt);
var
  W, Q, QI: TLsf;
  A: array[0..1] of TLpc;
  Sf, I, N, IntT, Frac, IntT1, K, T, C, S, GA, GB: Integer;
  Exc: PDouble;
  Code: array[0..G729_SUBFR - 1] of Double;
  Gp, Gc, Gamma, Energy: Double;
  BadPitch: Boolean;
begin
  Energy := 0;
  // LP filter parameters (4.1.1 / 4.4.1)
  if Erased then
  begin
    W := FPrevW;
    LsfConceal(FLsf, W);
  end
  else
    LsfDecode(FLsf, P.L0, P.L1, P.L2, P.L3, W);
  LsfToLsp(W, Q);
  for I := 0 to G729_ORDER - 1 do QI[I] := 0.5 * (FPrevQ[I] + Q[I]);
  LspToLp(QI, A[0]);
  LspToLp(Q, A[1]);
  FPrevW := W;
  FPrevQ := Q;

  BadPitch := (not Erased) and (PitchParity(P.P1) <> P.P0);
  IntT1 := FOldT0;
  for Sf := 0 to 1 do
  begin
    // adaptive-codebook delay (4.1.2, 4.1.3, 4.4.4)
    if Erased or ((Sf = 0) and BadPitch) then
    begin
      IntT := FOldT0;
      Frac := 0;
      Inc(FOldT0);
      if FOldT0 > G729_PIT_MAX then FOldT0 := G729_PIT_MAX;
    end
    else
    begin
      if Sf = 0 then DecodePitch1(P.P1, IntT, Frac)
      else DecodePitch2(P.P2, IntT1, IntT, Frac);
      FOldT0 := IntT;
    end;
    if Sf = 0 then IntT1 := IntT;

    Exc := @FExcBuf[EXC_OFS + Sf * G729_SUBFR];
    PitchToKT(IntT, Frac, K, T);
    AdaptiveVector(Exc, K, T);

    // fixed codebook (4.1.4) with pitch sharpening (equation 48)
    if Erased then
    begin
      C := NextRandom and $1FFF;
      S := NextRandom and $F;
    end
    else if Sf = 0 then begin C := P.C1; S := P.S1; end
    else begin C := P.C2; S := P.S2; end;
    DecodeFixedCodebook(C, S, Code);
    if IntT < G729_SUBFR then
      for N := IntT to G729_SUBFR - 1 do
        Code[N] := Code[N] + FBeta * Code[N - IntT];

    // gains (4.1.5 / 4.4.2, 4.4.3)
    if Erased then
    begin
      Gp := 0.9 * FPrevGp;
      if Gp > 0.9 then Gp := 0.9;
      Gc := 0.98 * FPrevGc;
      FGain.PushErased;
    end
    else
    begin
      if Sf = 0 then begin GA := P.GA1; GB := P.GB1; end
      else begin GA := P.GA2; GB := P.GB2; end;
      DecodeGains(GA, GB, Gp, Gamma);
      // the energy of c(n) is taken after the pitch sharpening
      Gc := Gamma * FGain.PredictedGain(Code);
      FGain.Push(20 * Log10(Max(Gamma, 1E-10)));
    end;
    FPrevGp := Gp;
    FPrevGc := Gc;
    FBeta := EnsureRange(Gp, 0.2, 0.8);

    // excitation (75), LP synthesis (77) and post-processing
    for N := 0 to G729_SUBFR - 1 do
    begin
      Exc[N] := Gp * Exc[N] + Gc * Code[N];
      Energy := Energy + Sqr(Exc[N]);
    end;
    SynthAndPost(Sf, A[Sf], IntT, Exc, Output + Sf * G729_SUBFR);
  end;

  // Annex B: remember the last valid active frame (SID recovery, B.4.5)
  if not Erased then
  begin
    FActW := W;
    FActEnergyDb := 10 * Log10(Max(Energy / G729_FRAME, 1E-10));
  end;
  // shift the excitation history
  Move(FExcBuf[G729_FRAME], FExcBuf[0], EXC_OFS * SizeOf(Double));
end;

procedure TG729Decoder.SynthAndPost(Sf: Integer; const A: TLpc; IntT: Integer; Exc: PDouble;
  Output: PSmallInt);
var
  Syn: array[0..G729_SUBFR - 1] of Double;
  PrevSyn: array[0..G729_ORDER - 1] of Double;
  N: Integer;
begin
  Move(FSyn, PrevSyn, SizeOf(PrevSyn));
  if not Synthesize(A, Exc, Syn) then
  begin
    // the synthesis left the 16-bit range: scale down the excitation
    // history (as the reference decoder does on overflow) and redo it
    Move(PrevSyn, FSyn, SizeOf(PrevSyn));
    for N := 0 to EXC_OFS + Sf * G729_SUBFR + G729_SUBFR - 1 do
      FExcBuf[N] := FExcBuf[N] * 0.25;
    Synthesize(A, Exc, Syn);
  end;
  PostFilter(A, IntT, PrevSyn, Syn, Output);
end;

// Comfort noise generation (B.4.4). NewSid: Sid = (L0, L1, L2, gain index) was received.
procedure TG729Decoder.DecodeCng(NewSid: Boolean; const Sid: array of Integer; Output: PSmallInt);
var
  Q, QI: TLsf;
  A: array[0..1] of TLpc;
  Sf, I, N, Lag, C, S: Integer;
  Exc: PDouble;
  Ea, Ef, Ex2: array[0..G729_SUBFR - 1] of Double;
  EnA, Cross, K, AA, GaMax, Ga, Gf, B, Cc, Disc, R1, R2, E1, E2, E3, Alpha, Beta: Double;
begin
  if NewSid then
  begin
    // the SID codeword also enters the MA memory of the LSF predictor
    SidLsfDecode(FLsf, Sid[0], Sid[1], Sid[2], FSidW);
    FSidGain := Power(10, SidGainDb(Sid[3]) / 20);
  end
  else if FPrevType = 1 then
  begin
    // the first SID of the inactive period was lost: rebuild it from the
    // last valid active frame (B.4.5)
    FSidW := FActW;
    FSidGain := Power(10, SidGainDb(SidGainIndex(FActEnergyDb + SID_RECOVERY_DB)) / 20);
  end;
  // target gain smoothing (B.19)
  if FPrevType = 1 then FCngGain := FSidGain
  else FCngGain := 7 / 8 * FCngGain + 1 / 8 * FSidGain;

  // LP filters: SID LSP as current LSP, interpolated with the previous frame
  LsfToLsp(FSidW, Q);
  for I := 0 to G729_ORDER - 1 do QI[I] := 0.5 * (FPrevQ[I] + Q[I]);
  LspToLp(QI, A[0]);
  LspToLp(Q, A[1]);
  FPrevQ := Q;
  FPrevW := FSidW;

  K := G729_SUBFR * Sqr(FCngGain);
  for Sf := 0 to 1 do
  begin
    Exc := @FExcBuf[EXC_OFS + Sf * G729_SUBFR];
    // adaptive excitation of unity gain at a random lag in [40, 103]
    Lag := 40 + NextCngRandom mod 64;
    AdaptiveVector(Exc, Lag, 0);
    for N := 0 to G729_SUBFR - 1 do Ea[N] := Exc[N];
    // random ACELP fixed excitation
    C := NextCngRandom and $1FFF;
    S := NextCngRandom and $F;
    DecodeFixedCodebook(C, S, Ef);
    EnA := 0; Cross := 0;
    for N := 0 to G729_SUBFR - 1 do
    begin
      EnA := EnA + Sqr(Ea[N]);
      Cross := Cross + Ea[N] * Ef[N];
    end;
    // random adaptive gain, limited so that (B.21) has a real solution and the
    // adaptive gain stays small (B.22; the bound is the smaller of the two values)
    AA := EnA - Sqr(Cross) / 4;
    GaMax := 0.5;
    if (AA > 0) and (Sqrt(K / AA) < GaMax) then GaMax := Sqrt(K / AA);
    Ga := GaMax * (NextCngRandom / 65536);
    B := Ga * Cross / 2;
    Cc := (EnA * Sqr(Ga) - K) / 4;
    Disc := Max(Sqr(B) - 4 * Cc, 0);
    R1 := (-B + Sqrt(Disc)) / 2;
    R2 := (-B - Sqrt(Disc)) / 2;
    if Abs(R1) <= Abs(R2) then Gf := R1 else Gf := R2;
    // mixture with a Gaussian excitation (B.23 - B.26)
    E1 := 0; E2 := 0; E3 := 0;
    for N := 0 to G729_SUBFR - 1 do
    begin
      Exc[N] := Ga * Ea[N] + Gf * Ef[N];
      Ex2[N] := CngGauss;
      E1 := E1 + Sqr(Exc[N]);
      E2 := E2 + Sqr(Ex2[N]);
      E3 := E3 + Exc[N] * Ex2[N];
    end;
    Alpha := CNG_ALPHA;
    Disc := Sqr(Alpha * E3) - E2 * (Sqr(Alpha) - 1) * E1;
    if (E2 > 0) and (Disc >= 0) then Beta := (-Alpha * E3 + Sqrt(Disc)) / E2 else Beta := -1;
    if Beta < 0 then begin Beta := 0; Alpha := 1; end;
    for N := 0 to G729_SUBFR - 1 do
      Exc[N] := Alpha * Exc[N] + Beta * Ex2[N];

    SynthAndPost(Sf, A[Sf], Lag, Exc, Output + Sf * G729_SUBFR);
  end;
  Move(FExcBuf[G729_FRAME], FExcBuf[0], EXC_OFS * SizeOf(Double));
end;

function TG729Decoder.Synthesize(const A: TLpc; Exc: PDouble; out Syn: array of Double): Boolean;
var
  N, I: Integer;
  X: Double;
begin
  Result := True;
  for N := 0 to G729_SUBFR - 1 do
  begin
    X := Exc[N];
    for I := 0 to G729_ORDER - 1 do
      X := X - A[I + 1] * FSyn[I];
    Move(FSyn[0], FSyn[1], (G729_ORDER - 1) * SizeOf(Double));
    FSyn[0] := X;
    Syn[N] := X;
    if Abs(X) > OVERFLOW_LIMIT then Result := False;
  end;
end;

procedure TG729Decoder.PostFilter(const A: TLpc; IntT: Integer; const Prev, S: array of Double;
  Output: PSmallInt);
var
  AN, AD: TLpc;
  Hf: array[0..21] of Double;
  Ltp: array[0..G729_SUBFR - 1] of Double;
  Sf: array[0..G729_SUBFR - 1] of Double;
  N, I, K, Tcl, BestT: Integer;
  G, Corr, BestCorr, E0, Ek, Gl, K1, Rh0, Rh1, Es, Ef, Gain, X, Y, Prev1: Double;
  R: PDouble;

  function SHat(Idx: Integer): Double;   // s^(Idx), Idx >= -10
  begin
    if Idx >= 0 then Result := S[Idx] else Result := Prev[-Idx - 1];
  end;

begin
  G := 1;
  for I := 0 to G729_ORDER do
  begin
    AN[I] := A[I] * G;
    G := G * GAMMA_N;
  end;
  G := 1;
  for I := 0 to G729_ORDER do
  begin
    AD[I] := A[I] * G;
    G := G * GAMMA_D;
  end;

  // residual r^(n) of s^(n) through A(z/gn) (equation 79)
  R := @FRes[RES_OFS];
  for N := 0 to G729_SUBFR - 1 do
  begin
    X := S[N];
    for I := 1 to G729_ORDER do X := X + AN[I] * SHat(N - I);
    R[N] := X;
  end;

  // long-term postfilter with integer delay (A.4.2.1)
  Tcl := IntT;
  if Tcl > 140 then Tcl := 140;
  BestT := Tcl;
  BestCorr := -MaxDouble;
  for K := Tcl - 3 to Tcl + 3 do
  begin
    Corr := 0;
    for N := 0 to G729_SUBFR - 1 do Corr := Corr + R[N] * R[N - K];
    if Corr > BestCorr then begin BestCorr := Corr; BestT := K; end;
  end;
  E0 := 0; Ek := 0;
  for N := 0 to G729_SUBFR - 1 do
  begin
    E0 := E0 + Sqr(R[N]);
    Ek := Ek + Sqr(R[N - BestT]);
  end;
  if (BestCorr <= 0) or (Ek <= 0) or (Sqr(BestCorr) < 0.5 * E0 * Ek) then Gl := 0
  else Gl := Min(BestCorr / Ek, 1.0);
  G := GAMMA_P * Gl;
  for N := 0 to G729_SUBFR - 1 do
    Ltp[N] := (R[N] + G * R[N - BestT]) / (1 + G);

  // tilt compensation (A.4.2.3) on the truncated impulse response of A(z/gn)/A(z/gd)
  for N := 0 to 21 do
  begin
    if N <= G729_ORDER then X := AN[N] else X := 0;
    for I := 1 to Min(N, G729_ORDER) do X := X - AD[I] * Hf[N - I];
    Hf[N] := X;
  end;
  Rh0 := 0; Rh1 := 0;
  for N := 0 to 21 do Rh0 := Rh0 + Sqr(Hf[N]);
  for N := 0 to 20 do Rh1 := Rh1 + Hf[N] * Hf[N + 1];
  if Rh0 > 0 then K1 := -Rh1 / Rh0 else K1 := 0;
  if K1 < 0 then G := GAMMA_T * K1 else G := 0;
  Prev1 := FTiltMem;
  for N := 0 to G729_SUBFR - 1 do
  begin
    X := Ltp[N];
    Ltp[N] := X + G * Prev1;
    Prev1 := X;
  end;
  FTiltMem := Prev1;

  // short-term postfilter 1/A(z/gd) (A.4.2.2)
  for N := 0 to G729_SUBFR - 1 do
  begin
    X := Ltp[N];
    for I := 0 to G729_ORDER - 1 do X := X - AD[I + 1] * FPfSyn[I];
    Move(FPfSyn[0], FPfSyn[1], (G729_ORDER - 1) * SizeOf(Double));
    FPfSyn[0] := X;
    Sf[N] := X;
  end;

  // adaptive gain control (A.4.2.4)
  Es := 0; Ef := 0;
  for N := 0 to G729_SUBFR - 1 do
  begin
    Es := Es + Sqr(S[N]);
    Ef := Ef + Sqr(Sf[N]);
  end;
  if (Es > 0) and (Ef > 0) then Gain := Sqrt(Es / Ef) else Gain := 0;

  for N := 0 to G729_SUBFR - 1 do
  begin
    FAgc := 0.9 * FAgc + 0.1 * Gain;
    X := FAgc * Sf[N];
    // high-pass filter (91) and upscaling by 2
    Y := HP_B0 * X + HP_B1 * FHpX1 + HP_B2 * FHpX2 + HP_A1 * FHpY1 + HP_A2 * FHpY2;
    FHpX2 := FHpX1; FHpX1 := X;
    FHpY2 := FHpY1; FHpY1 := Y;
    Output[N] := SmallInt(EnsureRange(Round(2 * Y), -32768, 32767));
  end;

  // shift the residual history
  Move(FRes[G729_SUBFR], FRes[0], RES_OFS * SizeOf(Double));
end;

function TG729Decoder.DecodeFrame(FrameType: TG729FrameType; Data: PByte;
  Output: PSmallInt): TG729FrameType;
var
  P: TG729Params;
  Sid: array[0..3] of Integer;
begin
  // an erased frame takes the type of the previous one (B.27)
  if FrameType = g729Lost then
    if FPrevType = 1 then Result := g729Lost else Result := g729NoData
  else
    Result := FrameType;
  FillChar(P, SizeOf(P), 0);
  FillChar(Sid, SizeOf(Sid), 0);
  case Result of
    g729Speech:
      begin
        UnpackFrame(Data, P);
        DecodeParams(P, False, Output);
        FCngSeed := CNG_SEED;     // the CNG generator restarts at each active frame
        FPrevType := 1;
      end;
    g729Lost:
      DecodeParams(P, True, Output);
    g729SID:
      begin
        UnpackSid(Data, Sid[0], Sid[1], Sid[2], Sid[3]);
        DecodeCng(True, Sid, Output);
        FPrevType := 2;
      end;
    g729NoData:
      begin
        DecodeCng(False, Sid, Output);
        FPrevType := 0;
      end;
  end;
end;

function TG729Decoder.Decode(Data: PByte; Len: Integer; Output: PSmallInt): TG729FrameType;
begin
  if (Data <> nil) and (Len >= G729_FRAME_BYTES) then
    Result := DecodeFrame(g729Speech, Data, Output)
  else if (Data <> nil) and (Len >= G729_SID_BYTES) then
    Result := DecodeFrame(g729SID, Data, Output)
  else
    Result := DecodeFrame(g729Lost, nil, Output);
end;

function TG729Decoder.Decode(const Data: array of Byte; out Samples: TArray<SmallInt>): TG729FrameType;
begin
  SetLength(Samples, G729_FRAME);
  if Length(Data) > 0 then
    Result := Decode(@Data[0], Length(Data), @Samples[0])
  else
    Result := Decode(nil, 0, @Samples[0]);
end;

function TG729Decoder.DecodePayload(Data: PByte; Len: Integer; Output: PSmallInt): Integer;
begin
  Result := 0;
  while Len >= G729_FRAME_BYTES do
  begin
    Decode(Data, G729_FRAME_BYTES, Output);
    Inc(Data, G729_FRAME_BYTES); Dec(Len, G729_FRAME_BYTES);
    Inc(Output, G729_FRAME); Inc(Result, G729_FRAME);
  end;
  if Len = G729_SID_BYTES then
  begin
    Decode(Data, G729_SID_BYTES, Output);
    Inc(Result, G729_FRAME);
  end;
end;

end.
