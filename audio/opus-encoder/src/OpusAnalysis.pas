unit OpusAnalysis;

{
  OpusAnalysis.pas - tonality / speech-music analysis of the Opus encoder

  Port of libopus 1.5.2 src/analysis.c and src/mlp.c (float build): 480-point
  FFT analysis at 24 kHz, tonality, noisiness, band energies, bandwidth
  detection, leakage boost, and the dense+GRU MLP that gives the music and
  activity probabilities.
  Copyright (c) 2011-2018 Xiph.Org Foundation, Jean-Marc Valin.

  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$EXCESSPRECISION OFF}
{$Q-}{$R-}

interface

uses
  Math, OpusEncTypes, OpusCeltEncTables, OpusCeltEncMath, OpusAnalysisTables;

const
  AN_NB_FRAMES = 8;
  AN_NB_TBANDS = 18;
  ANALYSIS_BUF_SIZE = 720;
  ANALYSIS_COUNT_MAX = 10000;
  DETECT_SIZE = 100;
  MAX_NEURONS = 32;

type
  TTonalityAnalysisState = record
    Application    : Integer;
    Fs             : Integer;
    // reset start (TONALITY_ANALYSIS_RESET_START)
    Angle          : array[0..239] of Single;
    DAngle         : array[0..239] of Single;
    D2Angle        : array[0..239] of Single;
    InMem          : array[0..ANALYSIS_BUF_SIZE - 1] of Single;
    MemFill        : Integer;
    PrevBandTonality: array[0..AN_NB_TBANDS - 1] of Single;
    PrevTonality   : Single;
    PrevBandwidth  : Integer;
    E              : array[0..AN_NB_FRAMES - 1, 0..AN_NB_TBANDS - 1] of Single;
    LogE           : array[0..AN_NB_FRAMES - 1, 0..AN_NB_TBANDS - 1] of Single;
    LowE           : array[0..AN_NB_TBANDS - 1] of Single;
    HighE          : array[0..AN_NB_TBANDS - 1] of Single;
    MeanE          : array[0..AN_NB_TBANDS] of Single;
    Mem            : array[0..31] of Single;
    CMean          : array[0..7] of Single;
    Std            : array[0..8] of Single;
    ETracker       : Single;
    LowECount      : Single;
    ECount         : Integer;
    Count          : Integer;
    AnalysisOffset : Integer;
    WritePos       : Integer;
    ReadPos        : Integer;
    ReadSubframe   : Integer;
    HpEnerAccum    : Single;
    Initialized    : Boolean;
    RnnState       : array[0..MAX_NEURONS - 1] of Single;
    DownmixState   : array[0..2] of Single;
    Info           : array[0..DETECT_SIZE - 1] of TAnalysisInfo;
  end;

procedure TonalityAnalysisInit(var Tonal: TTonalityAnalysisState; Fs: Integer);
procedure TonalityAnalysisReset(var Tonal: TTonalityAnalysisState);
procedure TonalityGetInfo(var Tonal: TTonalityAnalysisState; var InfoOut: TAnalysisInfo; Len: Integer);
// run_analysis with downmix_float semantics: Pcm is interleaved float in
// [-1, 1] with C channels (c1 = 0, c2 = -2 as in opus_encode/opus_encode_float)
procedure RunAnalysis(var Tonal: TTonalityAnalysisState; Pcm: PSingle; AnalysisFrameSize, FrameSize,
  C, Fs, LsbDepth: Integer; var Info: TAnalysisInfo);

implementation

const
  F_ONE: Single = 1.0;
  F_HALF: Single = 0.5;
  WEIGHTS_SCALE: Single = 1.0 / 128;
  TRANSITION_PENALTY = 10;
  NB_TONAL_SKIP_BANDS = 9;
  LEAKAGE_OFFSET: Single = 2.5;
  LEAKAGE_SLOPE: Single = 2.0;

// ---------------------------------------------------------------------------
// mlp.c
// ---------------------------------------------------------------------------

function TansigApprox(X: Single): Single;
const
  N0: Single = 952.52801514;
  N1: Single = 96.39235687;
  N2: Single = 0.60863042;
  D0: Single = 952.72399902;
  D1: Single = 413.36801147;
  D2: Single = 11.88600922;
var
  X2, Num, Den: Single;
begin
  X2 := X * X;
  Num := N2 * X2 + N1;
  Num := Num * X2 + N0;
  Den := D2 * X2 + D1;
  Den := Den * X2 + D0;
  Num := Num * X / Den;
  if Num > F_ONE then Num := F_ONE;
  if Num < -F_ONE then Num := -F_ONE;
  Result := Num;
end;

function SigmoidApprox(X: Single): Single;
begin
  Result := F_HALF + F_HALF * TansigApprox(F_HALF * X);
end;

procedure GemmAccum(OutP: PSingle; Weights: PShortInt; Rows, Cols, ColStride: Integer; X: PSingle);
var
  I, J: Integer;
begin
  for I := 0 to Rows - 1 do
    for J := 0 to Cols - 1 do
      OutP[I] := OutP[I] + Weights[J * ColStride + I] * X[J];
end;

procedure ComputeDense(Bias, Weights: PShortInt; NbInputs, NbNeurons: Integer; Sigmoid: Boolean;
  OutP, InP: PSingle);
var
  I: Integer;
begin
  for I := 0 to NbNeurons - 1 do
    OutP[I] := Bias[I];
  GemmAccum(OutP, Weights, NbNeurons, NbInputs, NbNeurons, InP);
  for I := 0 to NbNeurons - 1 do
    OutP[I] := OutP[I] * WEIGHTS_SCALE;
  if Sigmoid then
    for I := 0 to NbNeurons - 1 do
      OutP[I] := SigmoidApprox(OutP[I])
  else
    for I := 0 to NbNeurons - 1 do
      OutP[I] := TansigApprox(OutP[I]);
end;

procedure ComputeGru(Bias, InW, RecW: PShortInt; M, N: Integer; State, InP: PSingle);
var
  I, Stride: Integer;
  Tmp, Z, R, H: array[0..MAX_NEURONS - 1] of Single;
begin
  Stride := 3 * N;
  for I := 0 to N - 1 do Z[I] := Bias[I];
  GemmAccum(@Z[0], InW, N, M, Stride, InP);
  GemmAccum(@Z[0], RecW, N, N, Stride, State);
  for I := 0 to N - 1 do Z[I] := SigmoidApprox(WEIGHTS_SCALE * Z[I]);
  for I := 0 to N - 1 do R[I] := Bias[N + I];
  GemmAccum(@R[0], InW + N, N, M, Stride, InP);
  GemmAccum(@R[0], RecW + N, N, N, Stride, State);
  for I := 0 to N - 1 do R[I] := SigmoidApprox(WEIGHTS_SCALE * R[I]);
  for I := 0 to N - 1 do H[I] := Bias[2 * N + I];
  for I := 0 to N - 1 do Tmp[I] := State[I] * R[I];
  GemmAccum(@H[0], InW + 2 * N, N, M, Stride, InP);
  GemmAccum(@H[0], RecW + 2 * N, N, N, Stride, @Tmp[0]);
  for I := 0 to N - 1 do
    H[I] := Z[I] * State[I] + (1 - Z[I]) * TansigApprox(WEIGHTS_SCALE * H[I]);
  for I := 0 to N - 1 do State[I] := H[I];
end;

// ---------------------------------------------------------------------------
// analysis.c
// ---------------------------------------------------------------------------

function ResamplerDown2Hp(S: PSingle; OutP, InP: PSingle; InLen: Integer): Single;
const
  K0: Single = 0.6074371;
  K1: Single = 0.15063;
var
  K, Len2: Integer;
  In32, Out32, Out32Hp, Y, X, HpEner: Single;
begin
  Len2 := InLen div 2;
  HpEner := 0;
  for K := 0 to Len2 - 1 do
  begin
    In32 := InP[2 * K];
    Y := In32 - S[0];
    X := K0 * Y;
    Out32 := S[0] + X;
    S[0] := In32 + X;
    Out32Hp := Out32;
    In32 := InP[2 * K + 1];
    Y := In32 - S[1];
    X := K1 * Y;
    Out32 := Out32 + S[1];
    Out32 := Out32 + X;
    S[1] := In32 + X;
    Y := -In32 - S[2];
    X := K1 * Y;
    Out32Hp := Out32Hp + S[2];
    Out32Hp := Out32Hp + X;
    S[2] := -In32 + X;
    HpEner := HpEner + Out32Hp * Out32Hp;
    OutP[K] := F_HALF * Out32;
  end;
  Result := HpEner;
end;

// downmix_float (c1 = 0, c2 = -2) + resampling to 24 kHz
function DownmixAndResample(Pcm: PSingle; Y: PSingle; S: PSingle; Subframe, Offset, C, Fs: Integer): Single;
const
  SIG_SCALE: Single = 32768.0;
  INV32768: Single = 1.0 / 32768;
var
  Tmp, Tmp3x: array of Single;
  J, Ch: Integer;
  Scale: Single;
begin
  Result := 0;
  if Subframe = 0 then Exit;
  if Fs = 48000 then
  begin
    Subframe := Subframe * 2;
    Offset := Offset * 2;
  end
  else if Fs = 16000 then
  begin
    Subframe := Subframe * 2 div 3;
    Offset := Offset * 2 div 3;
  end;
  SetLength(Tmp, Subframe);
  for J := 0 to Subframe - 1 do
    Tmp[J] := Pcm[(J + Offset) * C] * SIG_SCALE;
  for Ch := 1 to C - 1 do
    for J := 0 to Subframe - 1 do
      Tmp[J] := Tmp[J] + Pcm[(J + Offset) * C + Ch] * SIG_SCALE;
  Scale := INV32768;
  Scale := Scale / C;
  for J := 0 to Subframe - 1 do
    Tmp[J] := Tmp[J] * Scale;
  if Fs = 48000 then
    Result := ResamplerDown2Hp(S, Y, @Tmp[0], Subframe)
  else if Fs = 24000 then
    Move(Tmp[0], Y^, Subframe * SizeOf(Single))
  else if Fs = 16000 then
  begin
    SetLength(Tmp3x, 3 * Subframe);
    for J := 0 to Subframe - 1 do
    begin
      Tmp3x[3 * J] := Tmp[J];
      Tmp3x[3 * J + 1] := Tmp[J];
      Tmp3x[3 * J + 2] := Tmp[J];
    end;
    ResamplerDown2Hp(S, Y, @Tmp3x[0], 3 * Subframe);
  end;
end;

procedure TonalityAnalysisInit(var Tonal: TTonalityAnalysisState; Fs: Integer);
begin
  Tonal.Fs := Fs;
  TonalityAnalysisReset(Tonal);
end;

procedure TonalityAnalysisReset(var Tonal: TTonalityAnalysisState);
var
  P: PByte;
begin
  P := @Tonal.Angle[0];
  FillChar(P^, SizeOf(Tonal) - (P - PByte(@Tonal)), 0);
end;

procedure TonalityGetInfo(var Tonal: TTonalityAnalysisState; var InfoOut: TAnalysisInfo; Len: Integer);
const
  F01: Single = 0.1;
  F02: Single = 0.2;
var
  Pos, CurrLookahead, TonalityCount, I, Pos0, MPos, VPos, BandwidthSpan: Integer;
  TonalityMax, TonalityAvg, ProbAvg, ProbCount, ProbMin, ProbMax, VadProb, PosVad, PMin, PMax, T: Single;
begin
  Pos := Tonal.ReadPos;
  CurrLookahead := Tonal.WritePos - Tonal.ReadPos;
  if CurrLookahead < 0 then Inc(CurrLookahead, DETECT_SIZE);
  Inc(Tonal.ReadSubframe, Len div (Tonal.Fs div 400));
  while Tonal.ReadSubframe >= 8 do
  begin
    Dec(Tonal.ReadSubframe, 8);
    Inc(Tonal.ReadPos);
  end;
  if Tonal.ReadPos >= DETECT_SIZE then Dec(Tonal.ReadPos, DETECT_SIZE);
  if (Len > Tonal.Fs div 50) and (Pos <> Tonal.WritePos) then
  begin
    Inc(Pos);
    if Pos = DETECT_SIZE then Pos := 0;
  end;
  if Pos = Tonal.WritePos then Dec(Pos);
  if Pos < 0 then Pos := DETECT_SIZE - 1;
  Pos0 := Pos;
  InfoOut := Tonal.Info[Pos];
  if not InfoOut.Valid then Exit;
  TonalityMax := InfoOut.Tonality;
  TonalityAvg := InfoOut.Tonality;
  TonalityCount := 1;
  BandwidthSpan := 6;
  for I := 0 to 2 do
  begin
    Inc(Pos);
    if Pos = DETECT_SIZE then Pos := 0;
    if Pos = Tonal.WritePos then Break;
    if Tonal.Info[Pos].Tonality > TonalityMax then TonalityMax := Tonal.Info[Pos].Tonality;
    TonalityAvg := TonalityAvg + Tonal.Info[Pos].Tonality;
    Inc(TonalityCount);
    if Tonal.Info[Pos].Bandwidth > InfoOut.Bandwidth then InfoOut.Bandwidth := Tonal.Info[Pos].Bandwidth;
    Dec(BandwidthSpan);
  end;
  Pos := Pos0;
  for I := 0 to BandwidthSpan - 1 do
  begin
    Dec(Pos);
    if Pos < 0 then Pos := DETECT_SIZE - 1;
    if Pos = Tonal.WritePos then Break;
    if Tonal.Info[Pos].Bandwidth > InfoOut.Bandwidth then InfoOut.Bandwidth := Tonal.Info[Pos].Bandwidth;
  end;
  T := TonalityAvg / TonalityCount;
  if T > TonalityMax - F02 then InfoOut.Tonality := T else InfoOut.Tonality := TonalityMax - F02;
  MPos := Pos0;
  VPos := Pos0;
  if CurrLookahead > 15 then
  begin
    Inc(MPos, 5);
    if MPos >= DETECT_SIZE then Dec(MPos, DETECT_SIZE);
    Inc(VPos);
    if VPos >= DETECT_SIZE then Dec(VPos, DETECT_SIZE);
  end;
  ProbMin := 1;
  ProbMax := 0;
  VadProb := Tonal.Info[VPos].ActivityProbability;
  if VadProb > F01 then ProbCount := VadProb else ProbCount := F01;
  ProbAvg := ProbCount * Tonal.Info[MPos].MusicProb;
  while True do
  begin
    Inc(MPos);
    if MPos = DETECT_SIZE then MPos := 0;
    if MPos = Tonal.WritePos then Break;
    Inc(VPos);
    if VPos = DETECT_SIZE then VPos := 0;
    if VPos = Tonal.WritePos then Break;
    PosVad := Tonal.Info[VPos].ActivityProbability;
    T := (ProbAvg - TRANSITION_PENALTY * (VadProb - PosVad)) / ProbCount;
    if T < ProbMin then ProbMin := T;
    T := (ProbAvg + TRANSITION_PENALTY * (VadProb - PosVad)) / ProbCount;
    if T > ProbMax then ProbMax := T;
    if PosVad > F01 then T := PosVad else T := F01;
    ProbCount := ProbCount + T;
    ProbAvg := ProbAvg + T * Tonal.Info[MPos].MusicProb;
  end;
  InfoOut.MusicProb := ProbAvg / ProbCount;
  T := ProbAvg / ProbCount;
  if T < ProbMin then ProbMin := T;
  if T > ProbMax then ProbMax := T;
  if ProbMin < 0 then ProbMin := 0;
  if ProbMax > 1 then ProbMax := 1;
  if CurrLookahead < 10 then
  begin
    PMin := ProbMin;
    PMax := ProbMax;
    Pos := Pos0;
    for I := 0 to Min(Tonal.Count - 1, 15) - 1 do
    begin
      Dec(Pos);
      if Pos < 0 then Pos := DETECT_SIZE - 1;
      if Tonal.Info[Pos].MusicProb < PMin then PMin := Tonal.Info[Pos].MusicProb;
      if Tonal.Info[Pos].MusicProb > PMax then PMax := Tonal.Info[Pos].MusicProb;
    end;
    T := PMin - F01 * VadProb;
    if T > 0 then PMin := T else PMin := 0;
    T := PMax + F01 * VadProb;
    if T < 1 then PMax := T else PMax := 1;
    T := F_ONE - F01 * CurrLookahead;
    ProbMin := ProbMin + T * (PMin - ProbMin);
    ProbMax := ProbMax + T * (PMax - ProbMax);
  end;
  InfoOut.MusicProbMin := ProbMin;
  InfoOut.MusicProbMax := ProbMax;
end;

function IsDigitalSilenceF(Pcm: PSingle; Len, LsbDepth: Integer): Boolean;
begin
  Result := CeltMaxAbs(Pcm, Len) <= F_ONE / (1 shl LsbDepth);
end;

function MaxF(A, B: Single): Single; inline;
begin
  if A > B then Result := A else Result := B;
end;

function MinF(A, B: Single): Single; inline;
begin
  if A < B then Result := A else Result := B;
end;

// MLP input features (end of tonality_analysis)
procedure FeaturesStep(var Tonal: TTonalityAnalysisState; const BFCC, MidE: array of Single;
  var Features: array of Single; Alpha: Single; const Info: TAnalysisInfo;
  SpecVariability, FrameStationarity: Single);
const
  C0: Single = -0.12299;
  C1: Single = 0.49195;
  C2: Single = 0.69693;
  C3: Single = 1.4349;
  C4: Single = 0.63246;
  C5: Single = 0.31623;
  C6: Single = 0.53452;
  C7: Single = 0.26726;
  B18: Single = 0.78;
  B20: Single = 0.154723;
  B21: Single = 0.724643;
  B22: Single = 0.743717;
  B23: Single = 0.069216;
  B24: Single = 0.067930;
var
  I: Integer;
  T: Single;
begin
  for I := 0 to 3 do
    Features[I] := C0 * (BFCC[I] + Tonal.Mem[I + 24]) + C1 * (Tonal.Mem[I] + Tonal.Mem[I + 16]) +
      C2 * Tonal.Mem[I + 8] - C3 * Tonal.CMean[I];
  for I := 0 to 3 do
    Tonal.CMean[I] := (1 - Alpha) * Tonal.CMean[I] + Alpha * BFCC[I];
  for I := 0 to 3 do
    Features[4 + I] := C4 * (BFCC[I] - Tonal.Mem[I + 24]) + C5 * (Tonal.Mem[I] - Tonal.Mem[I + 16]);
  for I := 0 to 2 do
    Features[8 + I] := C6 * (BFCC[I] + Tonal.Mem[I + 24]) - C7 * (Tonal.Mem[I] + Tonal.Mem[I + 16]) -
      C6 * Tonal.Mem[I + 8];
  if Tonal.Count > 5 then
    for I := 0 to 8 do
    begin
      T := Alpha * Features[I];
      Tonal.Std[I] := (1 - Alpha) * Tonal.Std[I] + T * Features[I];
    end;
  for I := 0 to 3 do
    Features[I] := BFCC[I] - MidE[I];
  for I := 0 to 7 do
  begin
    Tonal.Mem[I + 24] := Tonal.Mem[I + 16];
    Tonal.Mem[I + 16] := Tonal.Mem[I + 8];
    Tonal.Mem[I + 8] := Tonal.Mem[I];
    Tonal.Mem[I] := BFCC[I];
  end;
  for I := 0 to 8 do
    Features[11 + I] := SqrtF(Tonal.Std[I]) - AN_STD_FEATURE_BIAS[I];
  Features[18] := SpecVariability - B18;
  Features[20] := Info.Tonality - B20;
  Features[21] := Info.Activity - B21;
  Features[22] := FrameStationarity - B22;
  Features[23] := Info.TonalitySlope + B23;
  Features[24] := Tonal.LowECount - B24;
end;

procedure TonalityAnalysis(var Tonal: TTonalityAnalysisState; Pcm: PSingle; Len, Offset, C, LsbDepth: Integer);
const
  N = 480;
  N2 = 240;
  HALF_INV_PI: Single = 0.159154937;     // (float)(.5f/M_PI)
  K640PI4: Single = 62341.8164;          // 40.f*16.f*pi4
  K015: Single = 0.015;
  K09: Single = 0.9;
  K01: Single = 0.1;
  K025: Single = 0.25;
  LOG2E_HALF: Single = 0.721347511;      // .5f*1.442695f
  EPS10: Single = 1e-10;
  EPS15: Single = 1e-15;
  EPS5: Single = 1e-5;
  K001: Single = 0.01;
  K099: Single = 0.99;
  K003: Single = 0.03;
  K005: Single = 0.05;
  K1E9: Single = 1e9;
  K1E15: Single = 1e15;
  K57E4: Single = 5.7e-4;
  INV3600: Single = 0.000277777785;      // 1.f/(60*60)
  K0003: Single = 0.003;
  K08: Single = 0.8;
  K64: Single = 64.0;
  F10: Single = 10.0;
  F30: Single = 30.0;
var
  I, B, J, K, Remaining, PrevPos, Bandwidth, BandStart, BandEnd: Integer;
  FftIn, FftOut: array[0..479] of TKissCpx;
  Tonality, Noisiness, Tonality2: array[0..239] of Single;
  BandTonality, LogE: array[0..AN_NB_TBANDS - 1] of Single;
  BFCC, MidE: array[0..7] of Single;
  Features: array[0..24] of Single;
  FrameTonality, MaxFrameTonality, FrameNoisiness, Slope, FrameStationarity, RelativeE: Single;
  FrameProbs: array[0..1] of Single;
  Alpha, AlphaE, AlphaE2, FrameLoudness, BandwidthMask, MaxE, NoiseFloor, HpEner: Single;
  IsMasked: array[0..AN_NB_TBANDS] of Boolean;
  SpecVariability, BelowMaxPitch, AboveMaxPitch: Single;
  BandLog2, LeakageFrom, LeakageTo: array[0..AN_NB_TBANDS] of Single;
  LayerOut: array[0..MAX_NEURONS - 1] of Single;
  IsSilence: Boolean;
  W, X1r, X1i, X2r, X2i, Angle, DAngle_, D2Angle_, Angle2, DAngle2, D2Angle2, Mod1, Mod2, AvgMod: Single;
  Tt, E, TE, NE, L1, L2, Stationarity, BinE, LeakSlope, Boost, MinDist, Dist, Tmp, Em, NoiseRatio, Sum: Single;
  Info: ^TAnalysisInfo;
  D: Double;
begin
  if not Tonal.Initialized then
  begin
    Tonal.MemFill := 240;
    Tonal.Initialized := True;
  end;
  Alpha := F_ONE / Min(10, 1 + Tonal.Count);
  AlphaE := F_ONE / Min(25, 1 + Tonal.Count);
  AlphaE2 := F_ONE / Min(100, 1 + Tonal.Count);
  if Tonal.Count <= 1 then AlphaE2 := 1;
  if Tonal.Fs = 48000 then
  begin
    Len := Len div 2;
    Offset := Offset div 2;
  end
  else if Tonal.Fs = 16000 then
  begin
    Len := 3 * Len div 2;
    Offset := 3 * Offset div 2;
  end;
  Tonal.HpEnerAccum := Tonal.HpEnerAccum + DownmixAndResample(Pcm, @Tonal.InMem[Tonal.MemFill],
    @Tonal.DownmixState[0], Min(Len, ANALYSIS_BUF_SIZE - Tonal.MemFill), Offset, C, Tonal.Fs);
  if Tonal.MemFill + Len < ANALYSIS_BUF_SIZE then
  begin
    Inc(Tonal.MemFill, Len);
    Exit;
  end;
  HpEner := Tonal.HpEnerAccum;
  Info := @Tonal.Info[Tonal.WritePos];
  Inc(Tonal.WritePos);
  if Tonal.WritePos >= DETECT_SIZE then Dec(Tonal.WritePos, DETECT_SIZE);
  IsSilence := IsDigitalSilenceF(@Tonal.InMem[0], ANALYSIS_BUF_SIZE, LsbDepth);
  FillChar(IsMasked, SizeOf(IsMasked), 0);
  for I := 0 to N2 - 1 do
  begin
    W := AN_ANALYSIS_WINDOW[I];
    FftIn[I].R := W * Tonal.InMem[I];
    FftIn[I].I := W * Tonal.InMem[N2 + I];
    FftIn[N - I - 1].R := W * Tonal.InMem[N - I - 1];
    FftIn[N - I - 1].I := W * Tonal.InMem[N + N2 - I - 1];
  end;
  Move(Tonal.InMem[ANALYSIS_BUF_SIZE - 240], Tonal.InMem[0], 240 * SizeOf(Single));
  Remaining := Len - (ANALYSIS_BUF_SIZE - Tonal.MemFill);
  Tonal.HpEnerAccum := DownmixAndResample(Pcm, @Tonal.InMem[240], @Tonal.DownmixState[0], Remaining,
    Offset + ANALYSIS_BUF_SIZE - Tonal.MemFill, C, Tonal.Fs);
  Tonal.MemFill := 240 + Remaining;
  if IsSilence then
  begin
    PrevPos := Tonal.WritePos - 2;
    if PrevPos < 0 then Inc(PrevPos, DETECT_SIZE);
    Info^ := Tonal.Info[PrevPos];
    Exit;
  end;
  OpusFft480(@FftIn[0], @FftOut[0]);
  if IsNan(FftOut[0].R) then
  begin
    Info.Valid := False;
    Exit;
  end;

  for I := 1 to N2 - 1 do
  begin
    X1r := FftOut[I].R + FftOut[N - I].R;
    X1i := FftOut[I].I - FftOut[N - I].I;
    X2r := FftOut[I].I + FftOut[N - I].I;
    X2i := FftOut[N - I].R - FftOut[I].R;
    Angle := HALF_INV_PI * FastAtan2F(X1i, X1r);
    DAngle_ := Angle - Tonal.Angle[I];
    D2Angle_ := DAngle_ - Tonal.DAngle[I];
    Angle2 := HALF_INV_PI * FastAtan2F(X2i, X2r);
    DAngle2 := Angle2 - Angle;
    D2Angle2 := DAngle2 - DAngle_;
    Mod1 := D2Angle_ - Round(D2Angle_);
    Noisiness[I] := Abs(Mod1);
    Mod1 := Mod1 * Mod1;
    Mod1 := Mod1 * Mod1;
    Mod2 := D2Angle2 - Round(D2Angle2);
    Noisiness[I] := Noisiness[I] + Abs(Mod2);
    Mod2 := Mod2 * Mod2;
    Mod2 := Mod2 * Mod2;
    AvgMod := K025 * (Tonal.D2Angle[I] + Mod1 + 2 * Mod2);
    Tonality[I] := F_ONE / (F_ONE + K640PI4 * AvgMod) - K015;
    Tonality2[I] := F_ONE / (F_ONE + K640PI4 * Mod2) - K015;
    Tonal.Angle[I] := Angle2;
    Tonal.DAngle[I] := DAngle2;
    Tonal.D2Angle[I] := Mod2;
  end;
  for I := 2 to N2 - 2 do
  begin
    Tt := MinF(Tonality2[I], MaxF(Tonality2[I - 1], Tonality2[I + 1]));
    Tonality[I] := K09 * MaxF(Tonality[I], Tt - K01);
  end;
  FrameTonality := 0;
  MaxFrameTonality := 0;
  Info.Activity := 0;
  FrameNoisiness := 0;
  FrameStationarity := 0;
  if Tonal.Count = 0 then
    for B := 0 to AN_NB_TBANDS - 1 do
    begin
      Tonal.LowE[B] := 1e10;
      Tonal.HighE[B] := -1e10;
    end;
  RelativeE := 0;
  FrameLoudness := 0;
  Slope := 0;
  begin
    X1r := 2 * FftOut[0].R;
    X2r := 2 * FftOut[0].I;
    E := X1r * X1r + X2r * X2r;
    for I := 1 to 3 do
    begin
      BinE := FftOut[I].R * FftOut[I].R + FftOut[N - I].R * FftOut[N - I].R
            + FftOut[I].I * FftOut[I].I + FftOut[N - I].I * FftOut[N - I].I;
      E := E + BinE;
    end;
    BandLog2[0] := LOG2E_HALF * Single(Ln(E + EPS10));
  end;
  for B := 0 to AN_NB_TBANDS - 1 do
  begin
    E := 0; TE := 0; NE := 0;
    for I := AN_TBANDS[B] to AN_TBANDS[B + 1] - 1 do
    begin
      BinE := FftOut[I].R * FftOut[I].R + FftOut[N - I].R * FftOut[N - I].R
            + FftOut[I].I * FftOut[I].I + FftOut[N - I].I * FftOut[N - I].I;
      E := E + BinE;
      TE := TE + BinE * MaxF(0, Tonality[I]);
      NE := NE + BinE * 2 * (F_HALF - Noisiness[I]);
    end;
    if (not (E < K1E9)) or IsNan(E) then
    begin
      Info.Valid := False;
      Exit;
    end;
    Tonal.E[Tonal.ECount, B] := E;
    FrameNoisiness := FrameNoisiness + NE / (EPS15 + E);
    FrameLoudness := FrameLoudness + SqrtF(E + EPS10);
    LogE[B] := Single(Ln(E + EPS10));
    BandLog2[B + 1] := LOG2E_HALF * Single(Ln(E + EPS10));
    Tonal.LogE[Tonal.ECount, B] := LogE[B];
    if Tonal.Count = 0 then
    begin
      Tonal.HighE[B] := LogE[B];
      Tonal.LowE[B] := LogE[B];
    end;
    if Double(Tonal.HighE[B]) > Double(Tonal.LowE[B]) + 7.5 then
    begin
      if Tonal.HighE[B] - LogE[B] > LogE[B] - Tonal.LowE[B] then
        Tonal.HighE[B] := Tonal.HighE[B] - K001
      else
        Tonal.LowE[B] := Tonal.LowE[B] + K001;
    end;
    if LogE[B] > Tonal.HighE[B] then
    begin
      Tonal.HighE[B] := LogE[B];
      Tonal.LowE[B] := MaxF(Tonal.HighE[B] - 15, Tonal.LowE[B]);
    end
    else if LogE[B] < Tonal.LowE[B] then
    begin
      Tonal.LowE[B] := LogE[B];
      Tonal.HighE[B] := MinF(Tonal.LowE[B] + 15, Tonal.HighE[B]);
    end;
    RelativeE := RelativeE + (LogE[B] - Tonal.LowE[B]) / (EPS5 + (Tonal.HighE[B] - Tonal.LowE[B]));
    L1 := 0; L2 := 0;
    for I := 0 to AN_NB_FRAMES - 1 do
    begin
      L1 := L1 + SqrtF(Tonal.E[I, B]);
      L2 := L2 + Tonal.E[I, B];
    end;
    Tmp := AN_NB_FRAMES * L2;
    D := 1e-15 + Tmp;
    Tmp := Single(Sqrt(D));
    Stationarity := MinF(K099, L1 / Tmp);
    Stationarity := Stationarity * Stationarity;
    Stationarity := Stationarity * Stationarity;
    FrameStationarity := FrameStationarity + Stationarity;
    BandTonality[B] := MaxF(TE / (EPS15 + E), Stationarity * Tonal.PrevBandTonality[B]);
    FrameTonality := FrameTonality + BandTonality[B];
    if B >= AN_NB_TBANDS - NB_TONAL_SKIP_BANDS then
      FrameTonality := FrameTonality - BandTonality[B - AN_NB_TBANDS + NB_TONAL_SKIP_BANDS];
    Tmp := F_ONE + K003 * (B - AN_NB_TBANDS);
    MaxFrameTonality := MaxF(MaxFrameTonality, Tmp * FrameTonality);
    Slope := Slope + BandTonality[B] * (B - 8);
    Tonal.PrevBandTonality[B] := BandTonality[B];
  end;

  LeakageFrom[0] := BandLog2[0];
  LeakageTo[0] := BandLog2[0] - LEAKAGE_OFFSET;
  for B := 1 to AN_NB_TBANDS do
  begin
    LeakSlope := LEAKAGE_SLOPE * (AN_TBANDS[B] - AN_TBANDS[B - 1]) / 4;
    LeakageFrom[B] := MinF(LeakageFrom[B - 1] + LeakSlope, BandLog2[B]);
    LeakageTo[B] := MaxF(LeakageTo[B - 1] - LeakSlope, BandLog2[B] - LEAKAGE_OFFSET);
  end;
  for B := AN_NB_TBANDS - 2 downto 0 do
  begin
    LeakSlope := LEAKAGE_SLOPE * (AN_TBANDS[B + 1] - AN_TBANDS[B]) / 4;
    LeakageFrom[B] := MinF(LeakageFrom[B + 1] + LeakSlope, LeakageFrom[B]);
    LeakageTo[B] := MaxF(LeakageTo[B + 1] - LeakSlope, LeakageTo[B]);
  end;
  for B := 0 to AN_NB_TBANDS do
  begin
    Boost := MaxF(0, LeakageTo[B] - BandLog2[B]) + MaxF(0, BandLog2[B] - (LeakageFrom[B] + LEAKAGE_OFFSET));
    Tmp := K64 * Boost;
    I := Floor(0.5 + Double(Tmp));
    if I > 255 then I := 255;
    Info.LeakBoost[B] := Byte(I);
  end;

  SpecVariability := 0;
  for I := 0 to AN_NB_FRAMES - 1 do
  begin
    MinDist := K1E15;
    for J := 0 to AN_NB_FRAMES - 1 do
    begin
      Dist := 0;
      for K := 0 to AN_NB_TBANDS - 1 do
      begin
        Tmp := Tonal.LogE[I, K] - Tonal.LogE[J, K];
        Dist := Dist + Tmp * Tmp;
      end;
      if J <> I then
        MinDist := MinF(MinDist, Dist);
    end;
    SpecVariability := SpecVariability + MinDist;
  end;
  Tmp := SpecVariability / AN_NB_FRAMES;
  Tmp := Tmp / AN_NB_TBANDS;
  SpecVariability := SqrtF(Tmp);

  BandwidthMask := 0;
  Bandwidth := 0;
  MaxE := 0;
  NoiseFloor := K57E4 / (1 shl Max(0, LsbDepth - 8));
  NoiseFloor := NoiseFloor * NoiseFloor;
  BelowMaxPitch := 0;
  AboveMaxPitch := 0;
  for B := 0 to AN_NB_TBANDS - 1 do
  begin
    E := 0;
    BandStart := AN_TBANDS[B];
    BandEnd := AN_TBANDS[B + 1];
    for I := BandStart to BandEnd - 1 do
    begin
      BinE := FftOut[I].R * FftOut[I].R + FftOut[N - I].R * FftOut[N - I].R
            + FftOut[I].I * FftOut[I].I + FftOut[N - I].I * FftOut[N - I].I;
      E := E + BinE;
    end;
    MaxE := MaxF(MaxE, E);
    if BandStart < 64 then
      BelowMaxPitch := BelowMaxPitch + E
    else
      AboveMaxPitch := AboveMaxPitch + E;
    Tonal.MeanE[B] := MaxF((1 - AlphaE2) * Tonal.MeanE[B], E);
    Em := MaxF(E, Tonal.MeanE[B]);
    if (E * K1E9 > MaxE) and ((Em > 3 * NoiseFloor * (BandEnd - BandStart)) or
       (E > NoiseFloor * (BandEnd - BandStart))) then
      Bandwidth := B + 1;
    if Tonal.PrevBandwidth >= B + 1 then Tmp := K001 else Tmp := K005;
    IsMasked[B] := E < Tmp * BandwidthMask;
    BandwidthMask := MaxF(K005 * BandwidthMask, E);
  end;
  if Tonal.Fs = 48000 then
  begin
    E := HpEner * INV3600;
    if Tonal.PrevBandwidth = 20 then NoiseRatio := F10 else NoiseRatio := F30;
    AboveMaxPitch := AboveMaxPitch + E;
    Tonal.MeanE[AN_NB_TBANDS] := MaxF((1 - AlphaE2) * Tonal.MeanE[AN_NB_TBANDS], E);
    Em := MaxF(E, Tonal.MeanE[AN_NB_TBANDS]);
    if (Em > 3 * NoiseRatio * NoiseFloor * 160) or (E > NoiseRatio * NoiseFloor * 160) then
      Bandwidth := 20;
    if Tonal.PrevBandwidth = 20 then Tmp := K001 else Tmp := K005;
    IsMasked[AN_NB_TBANDS] := E < Tmp * BandwidthMask;
  end;
  if AboveMaxPitch > BelowMaxPitch then
    Info.MaxPitchRatio := BelowMaxPitch / AboveMaxPitch
  else
    Info.MaxPitchRatio := 1;
  if (Bandwidth = 20) and IsMasked[AN_NB_TBANDS] then
    Dec(Bandwidth, 2)
  else if (Bandwidth > 0) and (Bandwidth <= AN_NB_TBANDS) and IsMasked[Bandwidth - 1] then
    Dec(Bandwidth);
  if Tonal.Count <= 2 then
    Bandwidth := 20;
  FrameLoudness := 20 * Single(Log10(FrameLoudness));
  Tonal.ETracker := MaxF(Tonal.ETracker - K0003, FrameLoudness);
  Tonal.LowECount := Tonal.LowECount * (1 - AlphaE);
  if FrameLoudness < Tonal.ETracker - 30 then
    Tonal.LowECount := Tonal.LowECount + AlphaE;
  for I := 0 to 7 do
  begin
    Sum := 0;
    for B := 0 to 15 do
      Sum := Sum + AN_DCT_TABLE[I * 16 + B] * LogE[B];
    BFCC[I] := Sum;
  end;
  for I := 0 to 7 do
  begin
    Sum := 0;
    for B := 0 to 15 do
    begin
      Tmp := AN_DCT_TABLE[I * 16 + B] * F_HALF;
      Sum := Sum + Tmp * (Tonal.HighE[B] + Tonal.LowE[B]);
    end;
    MidE[I] := Sum;
  end;
  FrameStationarity := FrameStationarity / AN_NB_TBANDS;
  RelativeE := RelativeE / AN_NB_TBANDS;
  if Tonal.Count < 10 then
    RelativeE := F_HALF;
  FrameNoisiness := FrameNoisiness / AN_NB_TBANDS;
  Info.Activity := FrameNoisiness + (1 - FrameNoisiness) * RelativeE;
  FrameTonality := MaxFrameTonality / (AN_NB_TBANDS - NB_TONAL_SKIP_BANDS);
  FrameTonality := MaxF(FrameTonality, Tonal.PrevTonality * K08);
  Tonal.PrevTonality := FrameTonality;
  Slope := Slope / (8 * 8);
  Info.TonalitySlope := Slope;
  Tonal.ECount := (Tonal.ECount + 1) mod AN_NB_FRAMES;
  Tonal.Count := Min(Tonal.Count + 1, ANALYSIS_COUNT_MAX);
  Info.Tonality := FrameTonality;
  FeaturesStep(Tonal, BFCC, MidE, Features, Alpha, Info^, SpecVariability, FrameStationarity);
  ComputeDense(@MLP_LAYER0_BIAS[0], @MLP_LAYER0_WEIGHTS[0], 25, 32, False, @LayerOut[0], @Features[0]);
  ComputeGru(@MLP_LAYER1_BIAS[0], @MLP_LAYER1_WEIGHTS[0], @MLP_LAYER1_RECUR_WEIGHTS[0], 32, 24,
    @Tonal.RnnState[0], @LayerOut[0]);
  ComputeDense(@MLP_LAYER2_BIAS[0], @MLP_LAYER2_WEIGHTS[0], 24, 2, True, @FrameProbs[0], @Tonal.RnnState[0]);
  Info.ActivityProbability := FrameProbs[1];
  Info.MusicProb := FrameProbs[0];
  Info.Bandwidth := Bandwidth;
  Tonal.PrevBandwidth := Bandwidth;
  Info.Noisiness := FrameNoisiness;
  Info.Valid := True;
end;

procedure RunAnalysis(var Tonal: TTonalityAnalysisState; Pcm: PSingle; AnalysisFrameSize, FrameSize,
  C, Fs, LsbDepth: Integer; var Info: TAnalysisInfo);
var
  Offset, PcmLen: Integer;
begin
  AnalysisFrameSize := AnalysisFrameSize - (AnalysisFrameSize and 1);
  if Pcm <> nil then
  begin
    AnalysisFrameSize := Min((DETECT_SIZE - 5) * Fs div 50, AnalysisFrameSize);
    PcmLen := AnalysisFrameSize - Tonal.AnalysisOffset;
    Offset := Tonal.AnalysisOffset;
    while PcmLen > 0 do
    begin
      TonalityAnalysis(Tonal, Pcm, Min(Fs div 50, PcmLen), Offset, C, LsbDepth);
      Inc(Offset, Fs div 50);
      Dec(PcmLen, Fs div 50);
    end;
    Tonal.AnalysisOffset := AnalysisFrameSize;
    Tonal.AnalysisOffset := Tonal.AnalysisOffset - FrameSize;
  end;
  TonalityGetInfo(Tonal, Info, FrameSize);
end;

end.
