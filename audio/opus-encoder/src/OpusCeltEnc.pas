unit OpusCeltEnc;

{
  OpusCeltEnc.pas - CELT encoder (RFC 6716 section 5.3), 48 kHz / 960 mode

  Port of libopus 1.5.2 celt/celt_encoder.c (float build, no RESYNTH, no
  custom modes): transient analysis, pitch pre-filter, MDCT, tf analysis,
  spreading decision, dynamic allocation, allocation trim, stereo analysis,
  coarse/fine energy, PVQ band quantisation and CBR/VBR/CVBR rate control.

  Input: interleaved float PCM in [-1, 1] at 48/24/16/12/8 kHz (lower rates
  are zero-stuffed internally, as in libopus).

  Copyright (c) 2007-2008 CSIRO, 2007-2010 Xiph.Org Foundation,
  2008 Gregory Maxwell. Written by Jean-Marc Valin and Gregory Maxwell.
  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$EXCESSPRECISION OFF}
{$Q-}{$R-}

interface

uses
  SysUtils, Math,
  OpusEntEnc,
  OpusCeltTables,
  OpusCeltMath,
  OpusCeltBands,
  OpusCeltEncMath,
  OpusCeltEncBands,
  OpusEncTypes;

const
  CELT_ENC_MAX_BYTES = 1275;

type
  TCeltEncoder = class
  private
    FChannels       : Integer;   // CC
    FStreamChannels : Integer;   // C
    FForceIntra     : Boolean;
    FClip           : Boolean;
    FDisablePf      : Boolean;
    FComplexity     : Integer;
    FUpsample       : Integer;
    FStart, FEnd    : Integer;
    FBitrate        : Integer;
    FVbr            : Boolean;
    FConstrainedVbr : Boolean;
    FLossRate       : Integer;
    FLsbDepth       : Integer;
    FLfe            : Boolean;
    FDisableInv     : Boolean;
    // reset state
    FRng            : Cardinal;
    FSpreadDecision : Integer;
    FDelayedIntra   : Single;
    FTonalAverage   : Integer;
    FLastCodedBands : Integer;
    FHfAverage      : Integer;
    FTapsetDecision : Integer;
    FPrefilterPeriod: Integer;
    FPrefilterGain  : Single;
    FPrefilterTapset: Integer;
    FConsecTransient: Integer;
    FAnalysis       : TAnalysisInfo;
    FSilkInfo       : TSilkInfo;
    FPreemphMemE    : array[0..1] of Single;
    FPreemphMemD    : array[0..1] of Single;
    FVbrReservoir   : Integer;
    FVbrDrift       : Integer;
    FVbrOffset      : Integer;
    FVbrCount       : Integer;
    FOverlapMax     : Single;
    FStereoSaving   : Single;
    FIntensity      : Integer;
    FSpecAvg        : Single;
    FInMem          : array[0..2 * CELT_OVERLAP_SIZE - 1] of Single;
    FPrefilterMem   : array[0..2 * COMBFILTER_MAXPERIOD - 1] of Single;
    FOldBandE       : array[0..2 * CELT_NB_EBANDS - 1] of Single;
    FOldLogE        : array[0..2 * CELT_NB_EBANDS - 1] of Single;
    FOldLogE2       : array[0..2 * CELT_NB_EBANDS - 1] of Single;
    FEnergyError    : array[0..2 * CELT_NB_EBANDS - 1] of Single;
    procedure ComputeMdcts(ShortBlocks: Integer; Inp, OutF: PSingle; C, CC, LM: Integer);
    function  RunPrefilter(Inp: PSingle; CC, N, PrefilterTapset: Integer;
      out Pitch: Integer; out Gain: Single; out QGain: Integer; Enabled: Boolean;
      NbAvailableBytes: Integer): Boolean;
    procedure SetBitrate(Value: Integer);
  public
    constructor Create(SampleRate, AChannels: Integer);
    procedure Reset;
    // celt_encode_with_ec. Pcm: interleaved float (FChannels channels),
    // FrameSize samples per channel at the API rate. When Enc is nil the
    // frame is written to Compressed (MaxBytes bytes max). Returns the number
    // of bytes or a negative OPUS_* error code.
    function EncodeWithEc(Pcm: PSingle; FrameSize: Integer; Compressed: PByte;
      NbCompressedBytes: Integer; Enc: PEcEnc): Integer;
    procedure SetAnalysis(const Info: TAnalysisInfo);
    procedure SetSilkInfo(const Info: TSilkInfo);
    procedure SetPrediction(Value: Integer);   // CELT_SET_PREDICTION (0..2)
    property Complexity    : Integer read FComplexity write FComplexity;
    property StartBand     : Integer read FStart write FStart;
    property EndBand       : Integer read FEnd write FEnd;
    property StreamChannels: Integer read FStreamChannels write FStreamChannels;
    property Bitrate       : Integer read FBitrate write SetBitrate;
    property Vbr           : Boolean read FVbr write FVbr;
    property VbrConstraint : Boolean read FConstrainedVbr write FConstrainedVbr;
    property PacketLossPerc: Integer read FLossRate write FLossRate;
    property LsbDepth      : Integer read FLsbDepth write FLsbDepth;
    property PhaseInversionDisabled: Boolean read FDisableInv write FDisableInv;
    property Lfe           : Boolean read FLfe write FLfe;
    property FinalRange    : Cardinal read FRng;
    property Channels      : Integer read FChannels;
    property Upsample      : Integer read FUpsample;
  end;

function CeltResamplingFactor(Rate: Integer): Integer;

implementation

const
  TF_SELECT_TABLE: array[0..3, 0..7] of ShortInt = (
    (0, -1, 0, -1,    0, -1, 0, -1),
    (0, -1, 0, -2,    1,  0, 1, -1),
    (0, -2, 0, -3,    2,  0, 1, -1),
    (0, -2, 0, -3,    3,  0, 1, -1));
  TRIM_ICDF  : array[0..10] of Byte = (126, 124, 119, 109, 87, 41, 19, 9, 4, 2, 0);
  SPREAD_ICDF: array[0..3] of Byte = (25, 23, 2, 0);
  TAPSET_ICDF: array[0..2] of Byte = (2, 1, 0);
  PREEMPH0: Single = 0.85000610;
  SIG_SCALE: Single = 32768.0;
  CLIP_MAX: Single = 65536.0;

  INTENSITY_THRESHOLDS: array[0..20] of Single =
    (1, 2, 3, 4, 5, 6, 7, 8, 16, 24, 36, 44, 50, 56, 62, 67, 72, 79, 88, 106, 134);
  INTENSITY_HISTERESIS: array[0..20] of Single =
    (1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 3, 3, 4, 5, 6, 8, 8);

function Sar(X, S: Integer): Integer; inline;
begin
  if X >= 0 then Result := X shr S
  else Result := not ((not X) shr S);
end;

function CeltResamplingFactor(Rate: Integer): Integer;
begin
  case Rate of
    48000: Result := 1;
    24000: Result := 2;
    16000: Result := 3;
    12000: Result := 4;
    8000 : Result := 6;
  else
    Result := 0;
  end;
end;

// ---------------------------------------------------------------------------
// Analysis helpers (static functions of celt_encoder.c)
// ---------------------------------------------------------------------------

function TransientAnalysis(Inp: PSingle; Len, C: Integer; out TfEstimate: Single;
  out TfChan: Integer; AllowWeakTransients: Boolean; out WeakTransient: Boolean): Boolean;
const
  INV_TABLE: array[0..127] of Byte = (
    255,255,156,110, 86, 70, 59, 51, 45, 40, 37, 33, 31, 28, 26, 25,
     23, 22, 21, 20, 19, 18, 17, 16, 16, 15, 15, 14, 13, 13, 12, 12,
     12, 12, 11, 11, 11, 10, 10, 10,  9,  9,  9,  9,  9,  9,  8,  8,
      8,  8,  8,  7,  7,  7,  7,  7,  7,  6,  6,  6,  6,  6,  6,  6,
      6,  6,  6,  6,  6,  6,  6,  6,  6,  5,  5,  5,  5,  5,  5,  5,
      5,  5,  5,  5,  5,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,
      4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  3,  3,
      3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  2);
  DECAY_NORMAL: Single = 0.0625;
  DECAY_WEAK  : Single = 0.03125;
  K875: Single = 0.875;
  K125: Single = 0.125;
  K0069: Single = 0.0069;
var
  I, Ch, Len2, Unmask, MaskMetric, Id: Integer;
  Tmp: array of Single;
  Mem0, Mem1, Mem00, X, Y, X2, Mean, Norm, MaxE, ForwardDecay, TfMax, T: Single;
  D: Double;
  IsTransient: Boolean;
begin
  SetLength(Tmp, Len);
  WeakTransient := False;
  TfChan := 0;
  MaskMetric := 0;
  if AllowWeakTransients then ForwardDecay := DECAY_WEAK
  else ForwardDecay := DECAY_NORMAL;
  Len2 := Len div 2;
  for Ch := 0 to C - 1 do
  begin
    Mem0 := 0;
    Mem1 := 0;
    for I := 0 to Len - 1 do
    begin
      X := Inp[I + Ch * Len];
      Y := Mem0 + X;
      Mem00 := Mem0;
      Mem0 := Mem0 - X + F_HALF * Mem1;
      Mem1 := X - Mem00;
      Tmp[I] := Y;
    end;
    for I := 0 to 11 do
      Tmp[I] := 0;

    Mean := 0;
    Mem0 := 0;
    for I := 0 to Len2 - 1 do
    begin
      X2 := Tmp[2 * I] * Tmp[2 * I] + Tmp[2 * I + 1] * Tmp[2 * I + 1];
      Mean := Mean + X2;
      Mem0 := X2 + (F_ONE - ForwardDecay) * Mem0;
      Tmp[I] := ForwardDecay * Mem0;
    end;

    Mem0 := 0;
    MaxE := 0;
    for I := Len2 - 1 downto 0 do
    begin
      Mem0 := Tmp[I] + K875 * Mem0;
      Tmp[I] := K125 * Mem0;
      T := K125 * Mem0;
      if T > MaxE then MaxE := T;
    end;

    // mean = celt_sqrt(mean * maxE*.5*len2): double arithmetic in libopus
    Mean := Sqrt(Double(Mean * MaxE) * 0.5 * Len2);
    Norm := Len2 / (F_EPSILON + Mean);
    Unmask := 0;
    I := 12;
    while I < Len2 - 5 do
    begin
      // id = MAX32(0, MIN32(127, floor(64*norm*(tmp[i]+EPSILON))))
      T := 64 * Norm * (Tmp[I] + F_EPSILON);
      if T >= 128 then Id := 127
      else if T < 0 then Id := 0
      else Id := Floor(T);
      Unmask := Unmask + INV_TABLE[Id];
      Inc(I, 4);
    end;
    Unmask := 64 * Unmask * 4 div (6 * (Len2 - 17));
    if Unmask > MaskMetric then
    begin
      TfChan := Ch;
      MaskMetric := Unmask;
    end;
  end;
  IsTransient := MaskMetric > 200;
  if AllowWeakTransients and IsTransient and (MaskMetric < 600) then
  begin
    IsTransient := False;
    WeakTransient := True;
  end;
  TfMax := Single(Sqrt(Double(27 * MaskMetric))) - 42;
  if TfMax < 0 then TfMax := 0;
  if 163 < TfMax then T := 163 else T := TfMax;
  // QCONST32(0.139,28) is a double literal: the subtraction is done in double
  D := K0069 * T;
  D := D - 0.139;
  if D < 0 then D := 0;
  TfEstimate := Sqrt(D);
  Result := IsTransient;
end;

function PatchTransientDecision(NewE, OldE: PSingle; StartB, EndB, C: Integer): Boolean;
var
  I, Ch: Integer;
  MeanDiff, X1, X2, D: Single;
  SpreadOld: array[0..25] of Single;
begin
  MeanDiff := 0;
  if C = 1 then
  begin
    SpreadOld[StartB] := OldE[StartB];
    for I := StartB + 1 to EndB - 1 do
      SpreadOld[I] := Max(SpreadOld[I - 1] - F_ONE, OldE[I]);
  end
  else
  begin
    SpreadOld[StartB] := Max(OldE[StartB], OldE[StartB + CELT_NB_EBANDS]);
    for I := StartB + 1 to EndB - 1 do
      SpreadOld[I] := Max(SpreadOld[I - 1] - F_ONE, Max(OldE[I], OldE[I + CELT_NB_EBANDS]));
  end;
  for I := EndB - 2 downto StartB do
    SpreadOld[I] := Max(SpreadOld[I], SpreadOld[I + 1] - F_ONE);
  for Ch := 0 to C - 1 do
    for I := Max(2, StartB) to EndB - 2 do
    begin
      X1 := Max(Single(0), NewE[I + Ch * CELT_NB_EBANDS]);
      X2 := Max(Single(0), SpreadOld[I]);
      D := X1 - X2;
      if D < 0 then D := 0;
      MeanDiff := MeanDiff + D;
    end;
  MeanDiff := MeanDiff / (C * (EndB - 1 - Max(2, StartB)));
  Result := MeanDiff > F_ONE;
end;

procedure CeltPreemphasis(Pcm: PSingle; Inp: PSingle; N, CC, Upsample: Integer;
  var Mem: Single; Clip: Boolean);
var
  I, Nu: Integer;
  M, X: Single;
begin
  M := Mem;
  if (Upsample = 1) and not Clip then
  begin
    for I := 0 to N - 1 do
    begin
      X := Pcm[CC * I] * SIG_SCALE;
      Inp[I] := X - M;
      M := PREEMPH0 * X;
    end;
    Mem := M;
    Exit;
  end;
  Nu := N div Upsample;
  if Upsample <> 1 then
    FillChar(Inp^, N * SizeOf(Single), 0);
  for I := 0 to Nu - 1 do
    Inp[I * Upsample] := Pcm[CC * I] * SIG_SCALE;
  if Clip then
    for I := 0 to Nu - 1 do
    begin
      if Inp[I * Upsample] > CLIP_MAX then Inp[I * Upsample] := CLIP_MAX
      else if Inp[I * Upsample] < -CLIP_MAX then Inp[I * Upsample] := -CLIP_MAX;
    end;
  for I := 0 to N - 1 do
  begin
    X := Inp[I];
    Inp[I] := X - M;
    M := PREEMPH0 * X;
  end;
  Mem := M;
end;

function L1Metric(Tmp: PSingle; N, LM: Integer; Bias: Single): Single;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to N - 1 do
    Result := Result + Abs(Tmp[I]);
  Result := Result + (LM * Bias) * Result;
end;

function TfAnalysis(Len, IsTransient: Integer; TfRes: PInteger; Lambda: Integer;
  X: PSingle; N0, LM: Integer; TfEstimate: Single; TfChan: Integer;
  Importance: PInteger): Integer;
const
  K04: Single = 0.04;
  K025: Single = 0.25;
var
  I, K, N, Sel, BestLevel, Cost0, Cost1, Curr0, Curr1, From0, From1, B, TfSelect: Integer;
  Narrow: Boolean;
  Metric, Path0, Path1: array of Integer;
  Tmp, Tmp1: array of Single;
  L1, BestL1, Bias: Single;
  SelCost: array[0..1] of Integer;
begin
  Bias := F_HALF - TfEstimate;
  if -K025 > Bias then Bias := -K025;
  Bias := K04 * Bias;
  SetLength(Metric, Len);
  SetLength(Tmp, (CELT_EBANDS[Len] - CELT_EBANDS[Len - 1]) shl LM);
  SetLength(Tmp1, (CELT_EBANDS[Len] - CELT_EBANDS[Len - 1]) shl LM);
  SetLength(Path0, Len);
  SetLength(Path1, Len);
  for I := 0 to Len - 1 do
  begin
    BestLevel := 0;
    N := (CELT_EBANDS[I + 1] - CELT_EBANDS[I]) shl LM;
    Narrow := (CELT_EBANDS[I + 1] - CELT_EBANDS[I]) = 1;
    Move((X + TfChan * N0 + (CELT_EBANDS[I] shl LM))^, Tmp[0], N * SizeOf(Single));
    if IsTransient <> 0 then
      L1 := L1Metric(@Tmp[0], N, LM, Bias)
    else
      L1 := L1Metric(@Tmp[0], N, 0, Bias);
    BestL1 := L1;
    if (IsTransient <> 0) and not Narrow then
    begin
      Move(Tmp[0], Tmp1[0], N * SizeOf(Single));
      Haar1F(@Tmp1[0], N shr LM, 1 shl LM);
      L1 := L1Metric(@Tmp1[0], N, LM + 1, Bias);
      if L1 < BestL1 then
      begin
        BestL1 := L1;
        BestLevel := -1;
      end;
    end;
    for K := 0 to LM + Ord(not ((IsTransient <> 0) or Narrow)) - 1 do
    begin
      if IsTransient <> 0 then B := LM - K - 1
      else B := K + 1;
      Haar1F(@Tmp[0], N shr K, 1 shl K);
      L1 := L1Metric(@Tmp[0], N, B, Bias);
      if L1 < BestL1 then
      begin
        BestL1 := L1;
        BestLevel := K + 1;
      end;
    end;
    if IsTransient <> 0 then
      Metric[I] := 2 * BestLevel
    else
      Metric[I] := -2 * BestLevel;
    if Narrow and ((Metric[I] = 0) or (Metric[I] = -2 * LM)) then
      Dec(Metric[I]);
  end;

  TfSelect := 0;
  for Sel := 0 to 1 do
  begin
    Cost0 := Importance[0] * Abs(Metric[0] - 2 * TF_SELECT_TABLE[LM][4 * IsTransient + 2 * Sel + 0]);
    Cost1 := Importance[0] * Abs(Metric[0] - 2 * TF_SELECT_TABLE[LM][4 * IsTransient + 2 * Sel + 1]);
    if IsTransient = 0 then Cost1 := Cost1 + Lambda;
    for I := 1 to Len - 1 do
    begin
      Curr0 := Min(Cost0, Cost1 + Lambda);
      Curr1 := Min(Cost0 + Lambda, Cost1);
      Cost0 := Curr0 + Importance[I] * Abs(Metric[I] - 2 * TF_SELECT_TABLE[LM][4 * IsTransient + 2 * Sel + 0]);
      Cost1 := Curr1 + Importance[I] * Abs(Metric[I] - 2 * TF_SELECT_TABLE[LM][4 * IsTransient + 2 * Sel + 1]);
    end;
    Cost0 := Min(Cost0, Cost1);
    SelCost[Sel] := Cost0;
  end;
  if (SelCost[1] < SelCost[0]) and (IsTransient <> 0) then
    TfSelect := 1;
  Cost0 := Importance[0] * Abs(Metric[0] - 2 * TF_SELECT_TABLE[LM][4 * IsTransient + 2 * TfSelect + 0]);
  Cost1 := Importance[0] * Abs(Metric[0] - 2 * TF_SELECT_TABLE[LM][4 * IsTransient + 2 * TfSelect + 1]);
  if IsTransient = 0 then Cost1 := Cost1 + Lambda;
  for I := 1 to Len - 1 do
  begin
    From0 := Cost0;
    From1 := Cost1 + Lambda;
    if From0 < From1 then
    begin
      Curr0 := From0;
      Path0[I] := 0;
    end
    else
    begin
      Curr0 := From1;
      Path0[I] := 1;
    end;
    From0 := Cost0 + Lambda;
    From1 := Cost1;
    if From0 < From1 then
    begin
      Curr1 := From0;
      Path1[I] := 0;
    end
    else
    begin
      Curr1 := From1;
      Path1[I] := 1;
    end;
    Cost0 := Curr0 + Importance[I] * Abs(Metric[I] - 2 * TF_SELECT_TABLE[LM][4 * IsTransient + 2 * TfSelect + 0]);
    Cost1 := Curr1 + Importance[I] * Abs(Metric[I] - 2 * TF_SELECT_TABLE[LM][4 * IsTransient + 2 * TfSelect + 1]);
  end;
  if Cost0 < Cost1 then TfRes[Len - 1] := 0 else TfRes[Len - 1] := 1;
  for I := Len - 2 downto 0 do
  begin
    if TfRes[I + 1] = 1 then
      TfRes[I] := Path1[I + 1]
    else
      TfRes[I] := Path0[I + 1];
  end;
  Result := TfSelect;
end;

procedure TfEncode(StartB, EndB, IsTransient: Integer; TfRes: PInteger; LM, TfSelect: Integer;
  var Enc: TEcEnc);
var
  Curr, I, TfSelectRsv, TfChanged, Logp: Integer;
  Budget, Tell: Cardinal;
begin
  Budget := Enc.Storage * 8;
  Tell := EcTell(Enc);
  if IsTransient <> 0 then Logp := 2 else Logp := 4;
  TfSelectRsv := Ord((LM > 0) and (Tell + Cardinal(Logp) + 1 <= Budget));
  Budget := Budget - Cardinal(TfSelectRsv);
  Curr := 0;
  TfChanged := 0;
  for I := StartB to EndB - 1 do
  begin
    if Tell + Cardinal(Logp) <= Budget then
    begin
      EcEncBitLogp(Enc, TfRes[I] xor Curr, Logp);
      Tell := EcTell(Enc);
      Curr := TfRes[I];
      TfChanged := TfChanged or Curr;
    end
    else
      TfRes[I] := Curr;
    if IsTransient <> 0 then Logp := 4 else Logp := 5;
  end;
  if (TfSelectRsv <> 0) and
     (TF_SELECT_TABLE[LM][4 * IsTransient + 0 + TfChanged] <> TF_SELECT_TABLE[LM][4 * IsTransient + 2 + TfChanged]) then
    EcEncBitLogp(Enc, TfSelect, 1)
  else
    TfSelect := 0;
  for I := StartB to EndB - 1 do
    TfRes[I] := TF_SELECT_TABLE[LM][4 * IsTransient + 2 * TfSelect + TfRes[I]];
end;

function AllocTrimAnalysis(X: PSingle; BandLogE: PSingle; EndB, LM, C, N0: Integer;
  const Analysis: TAnalysisInfo; var StereoSaving: Single; TfEstimate: Single;
  Intensity: Integer; SurroundTrim: Single; EquivRate: Integer): Integer;
const
  K1_16: Single = 1.0 / 16;
  K1_8 : Single = 1.0 / 8;
  K1001: Single = 1.001;
  K075 : Single = 0.75;
  K025 : Single = 0.25;
  K05  : Single = 0.05;
  F2   : Single = 2.0;
  F4   : Single = 4.0;
var
  I, Ch, Frac, TrimIndex: Integer;
  Diff, Trim, Sum, MinXC, Partial, LogXC, LogXC2, T: Single;
begin
  Diff := 0;
  Trim := 5.0;
  if EquivRate < 64000 then
    Trim := 4.0
  else if EquivRate < 80000 then
  begin
    Frac := (EquivRate - 64000) shr 10;
    Trim := F4 + K1_16 * Frac;
  end;
  if C = 2 then
  begin
    Sum := 0;
    for I := 0 to 7 do
    begin
      Partial := CeltInnerProd(X + (CELT_EBANDS[I] shl LM), X + N0 + (CELT_EBANDS[I] shl LM),
        (CELT_EBANDS[I + 1] - CELT_EBANDS[I]) shl LM);
      Sum := Sum + Partial;
    end;
    Sum := K1_8 * Sum;
    Sum := Min(F_ONE, Abs(Sum));
    MinXC := Sum;
    for I := 8 to Intensity - 1 do
    begin
      Partial := CeltInnerProd(X + (CELT_EBANDS[I] shl LM), X + N0 + (CELT_EBANDS[I] shl LM),
        (CELT_EBANDS[I + 1] - CELT_EBANDS[I]) shl LM);
      MinXC := Min(MinXC, Abs(Partial));
    end;
    MinXC := Min(F_ONE, Abs(MinXC));
    LogXC := CeltLog2(K1001 - Sum * Sum);
    LogXC2 := Max(F_HALF * LogXC, CeltLog2(K1001 - MinXC * MinXC));
    Trim := Trim + Max(-F4, K075 * LogXC);
    StereoSaving := Min(StereoSaving + K025, -(F_HALF * LogXC2));
  end;

  for Ch := 0 to C - 1 do
    for I := 0 to EndB - 2 do
      Diff := Diff + BandLogE[I + Ch * CELT_NB_EBANDS] * (2 + 2 * I - EndB);
  Diff := Diff / (C * (EndB - 1));
  T := (Diff + F_ONE) / 6;
  if T > F2 then T := F2;
  if T < -F2 then T := -F2;
  Trim := Trim - T;
  Trim := Trim - SurroundTrim;
  Trim := Trim - 2 * TfEstimate;
  if Analysis.Valid then
  begin
    T := F2 * (Analysis.TonalitySlope + K05);
    if T > F2 then T := F2;
    if T < -F2 then T := -F2;
    Trim := Trim - T;
  end;
  TrimIndex := Floor(F_HALF + Trim);
  Result := Max(0, Min(10, TrimIndex));
end;

function StereoAnalysis(X: PSingle; LM, N0: Integer): Boolean;
const
  K707: Single = 0.707107;
var
  I, J, Thetas: Integer;
  SumLR, SumMS, L, R, M, S: Single;
begin
  SumLR := F_EPSILON;
  SumMS := F_EPSILON;
  for I := 0 to 12 do
    for J := CELT_EBANDS[I] shl LM to (CELT_EBANDS[I + 1] shl LM) - 1 do
    begin
      L := X[J];
      R := X[N0 + J];
      M := L + R;
      S := L - R;
      SumLR := SumLR + (Abs(L) + Abs(R));
      SumMS := SumMS + (Abs(M) + Abs(S));
    end;
  SumMS := K707 * SumMS;
  Thetas := 13;
  if LM <= 1 then
    Thetas := Thetas - 8;
  Result := ((CELT_EBANDS[13] shl (LM + 1)) + Thetas) * SumMS >
            (CELT_EBANDS[13] shl (LM + 1)) * SumLR;
end;

function MedianOf5(X: PSingle): Single;
var
  T0, T1, T2, T3, T4, Tmp: Single;
begin
  T2 := X[2];
  if X[0] > X[1] then begin T0 := X[1]; T1 := X[0]; end
  else begin T0 := X[0]; T1 := X[1]; end;
  if X[3] > X[4] then begin T3 := X[4]; T4 := X[3]; end
  else begin T3 := X[3]; T4 := X[4]; end;
  if T0 > T3 then
  begin
    Tmp := T0; T0 := T3; T3 := Tmp;
    Tmp := T1; T1 := T4; T4 := Tmp;
  end;
  if T2 > T1 then
  begin
    if T1 < T3 then Result := Min(T2, T3)
    else Result := Min(T4, T1);
  end
  else
  begin
    if T2 < T3 then Result := Min(T1, T3)
    else Result := Min(T2, T4);
  end;
end;

function MedianOf3(X: PSingle): Single;
var
  T0, T1, T2: Single;
begin
  if X[0] > X[1] then begin T0 := X[1]; T1 := X[0]; end
  else begin T0 := X[0]; T1 := X[1]; end;
  T2 := X[2];
  if T1 < T2 then Result := T1
  else if T0 < T2 then Result := T2
  else Result := T0;
end;

function DynallocAnalysis(BandLogE, BandLogE2, OldBandE: PSingle; StartB, EndB, C: Integer;
  Offsets: PInteger; LsbDepth: Integer; IsTransient, Vbr, ConstrainedVbr: Boolean;
  LM, EffectiveBytes: Integer; out TotBoost_: Integer; Lfe: Boolean;
  SurroundDynalloc: PSingle; const Analysis: TAnalysisInfo; Importance, SpreadWeight: PInteger): Single;
const
  K319 : Single = 31.9;
  K0625: Single = 0.0625;
  K0062: Single = 0.0062;
  F2   : Single = 2.0;
  F3   : Single = 3.0;
  F12  : Single = 12.0;
  F05  : Single = 0.5;
  F15  : Single = 1.5;
  F4   : Single = 4.0;
  K1_64: Single = 1.0 / 64;
var
  I, Ch, Last, Shift, Width, Boost, BoostBits, Cap, TotBoost: Integer;
  MaxDepth, Smr, Tmp, Offset: Single;
  Follower, NoiseFloor: array[0..2 * CELT_NB_EBANDS - 1] of Single;
  BandLogE3, Mask, Sig: array[0..CELT_NB_EBANDS - 1] of Single;
  F: PSingle;
begin
  TotBoost := 0;
  for I := 0 to CELT_NB_EBANDS - 1 do
    Offsets[I] := 0;
  MaxDepth := -K319;
  for I := 0 to EndB - 1 do
    NoiseFloor[I] := K0625 * CELT_LOGN400[I] + F05 + (9 - LsbDepth) - CELT_EMEANS[I]
                   + K0062 * ((I + 5) * (I + 5));
  for Ch := 0 to C - 1 do
    for I := 0 to EndB - 1 do
      MaxDepth := Max(MaxDepth, BandLogE[Ch * CELT_NB_EBANDS + I] - NoiseFloor[I]);

  for I := 0 to EndB - 1 do
    Mask[I] := BandLogE[I] - NoiseFloor[I];
  if C = 2 then
    for I := 0 to EndB - 1 do
      Mask[I] := Max(Mask[I], BandLogE[CELT_NB_EBANDS + I] - NoiseFloor[I]);
  Move(Mask[0], Sig[0], EndB * SizeOf(Single));
  for I := 1 to EndB - 1 do
    Mask[I] := Max(Mask[I], Mask[I - 1] - F2);
  for I := EndB - 2 downto 0 do
    Mask[I] := Max(Mask[I], Mask[I + 1] - F3);
  for I := 0 to EndB - 1 do
  begin
    Smr := Sig[I] - Max(Max(Single(0), MaxDepth - F12), Mask[I]);
    Shift := Min(5, Max(0, -Floor(F_HALF + Smr)));
    SpreadWeight[I] := 32 shr Shift;
  end;

  if (EffectiveBytes >= 30 + 5 * LM) and not Lfe then
  begin
    Last := 0;
    for Ch := 0 to C - 1 do
    begin
      Move(BandLogE2[Ch * CELT_NB_EBANDS], BandLogE3[0], EndB * SizeOf(Single));
      if LM = 0 then
        for I := 0 to Min(8, EndB) - 1 do
          BandLogE3[I] := Max(BandLogE2[Ch * CELT_NB_EBANDS + I], OldBandE[Ch * CELT_NB_EBANDS + I]);
      F := @Follower[Ch * CELT_NB_EBANDS];
      F[0] := BandLogE3[0];
      for I := 1 to EndB - 1 do
      begin
        if BandLogE3[I] > BandLogE3[I - 1] + F05 then
          Last := I;
        F[I] := Min(F[I - 1] + F15, BandLogE3[I]);
      end;
      for I := Last - 1 downto 0 do
        F[I] := Min(F[I], Min(F[I + 1] + F2, BandLogE3[I]));
      Offset := F_ONE;
      for I := 2 to EndB - 3 do
        F[I] := Max(F[I], MedianOf5(@BandLogE3[I - 2]) - Offset);
      Tmp := MedianOf3(@BandLogE3[0]) - Offset;
      F[0] := Max(F[0], Tmp);
      F[1] := Max(F[1], Tmp);
      Tmp := MedianOf3(@BandLogE3[EndB - 3]) - Offset;
      F[EndB - 2] := Max(F[EndB - 2], Tmp);
      F[EndB - 1] := Max(F[EndB - 1], Tmp);
      for I := 0 to EndB - 1 do
        F[I] := Max(F[I], NoiseFloor[I]);
    end;
    if C = 2 then
    begin
      for I := StartB to EndB - 1 do
      begin
        Follower[CELT_NB_EBANDS + I] := Max(Follower[CELT_NB_EBANDS + I], Follower[I] - F4);
        Follower[I] := Max(Follower[I], Follower[CELT_NB_EBANDS + I] - F4);
        Follower[I] := F_HALF * (Max(Single(0), BandLogE[I] - Follower[I]) +
          Max(Single(0), BandLogE[CELT_NB_EBANDS + I] - Follower[CELT_NB_EBANDS + I]));
      end;
    end
    else
      for I := StartB to EndB - 1 do
        Follower[I] := Max(Single(0), BandLogE[I] - Follower[I]);
    for I := StartB to EndB - 1 do
      Follower[I] := Max(Follower[I], SurroundDynalloc[I]);
    for I := StartB to EndB - 1 do
      Importance[I] := Floor(F_HALF + 13 * CeltExp2(Min(Follower[I], F4)));
    if ((not Vbr) or ConstrainedVbr) and not IsTransient then
      for I := StartB to EndB - 1 do
        Follower[I] := F_HALF * Follower[I];
    for I := StartB to EndB - 1 do
    begin
      if I < 8 then
        Follower[I] := Follower[I] * 2;
      if I >= 12 then
        Follower[I] := F_HALF * Follower[I];
    end;
    if Analysis.Valid then
      for I := StartB to Min(LEAK_BANDS, EndB) - 1 do
        Follower[I] := Follower[I] + K1_64 * Analysis.LeakBoost[I];
    for I := StartB to EndB - 1 do
    begin
      Follower[I] := Min(Follower[I], F4);
      Width := C * (CELT_EBANDS[I + 1] - CELT_EBANDS[I]) shl LM;
      if Width < 6 then
      begin
        Boost := Trunc(Follower[I]);
        BoostBits := Boost * Width shl BITRES;
      end
      else if Width > 48 then
      begin
        Boost := Trunc(Follower[I] * 8);
        BoostBits := (Boost * Width shl BITRES) div 8;
      end
      else
      begin
        Boost := Trunc(Follower[I] * Width / 6);
        BoostBits := Boost * 6 shl BITRES;
      end;
      if ((not Vbr) or (ConstrainedVbr and not IsTransient)) and
         ((TotBoost + BoostBits) shr BITRES shr 3 > 2 * EffectiveBytes div 3) then
      begin
        Cap := (2 * EffectiveBytes div 3) shl BITRES shl 3;
        Offsets[I] := Cap - TotBoost;
        TotBoost := Cap;
        Break;
      end
      else
      begin
        Offsets[I] := Boost;
        TotBoost := TotBoost + BoostBits;
      end;
    end;
  end
  else
    for I := StartB to EndB - 1 do
      Importance[I] := 13;
  TotBoost_ := TotBoost;
  Result := MaxDepth;
end;

function ComputeVbr(const Analysis: TAnalysisInfo; BaseTarget, LM, Bitrate, LastCodedBands,
  C, Intensity: Integer; ConstrainedVbr: Boolean; StereoSaving: Single; TotBoost: Integer;
  TfEstimate: Single; PitchChange: Boolean; MaxDepth: Single; Lfe: Boolean;
  TemporalVbr: Single): Integer;
const
  K04  : Single = 0.4;
  K08  : Single = 0.8;
  K01  : Single = 0.1;
  K044 : Single = 0.044;
  K015 : Single = 0.15;
  K012 : Single = 0.12;
  K12  : Single = 1.2;
  K067 : Single = 0.67;
  K02  : Single = 0.2;
  K31  : Single = 0.0000031;
var
  Target, CodedBins, CodedBands, CodedStereoBands, CodedStereoDof, TonalTarget,
  FloorDepth, Bins: Integer;
  MaxFrac, A, B, Tonal, Amount, TvbrFactor: Single;
begin
  if LastCodedBands <> 0 then CodedBands := LastCodedBands else CodedBands := CELT_NB_EBANDS;
  CodedBins := CELT_EBANDS[CodedBands] shl LM;
  if C = 2 then
    CodedBins := CodedBins + (CELT_EBANDS[Min(Intensity, CodedBands)] shl LM);
  Target := BaseTarget;
  if Analysis.Valid and (Analysis.Activity < 0.4) then
    Target := Target - Trunc((CodedBins shl BITRES) * (K04 - Analysis.Activity));
  if C = 2 then
  begin
    CodedStereoBands := Min(Intensity, CodedBands);
    CodedStereoDof := (CELT_EBANDS[CodedStereoBands] shl LM) - CodedStereoBands;
    MaxFrac := (K08 * CodedStereoDof) / CodedBins;
    StereoSaving := Min(StereoSaving, F_ONE);
    A := MaxFrac * Target;
    B := (StereoSaving - K01) * (CodedStereoDof shl BITRES);
    if A < B then Target := Target - Trunc(A)
    else Target := Target - Trunc(B);
  end;
  Target := Target + TotBoost - (19 shl LM);
  Target := Target + Trunc((TfEstimate - K044) * Target);
  if Analysis.Valid and not Lfe then
  begin
    Tonal := Max(Single(0), Analysis.Tonality - K015) - K012;
    TonalTarget := Target + Trunc((CodedBins shl BITRES) * K12 * Tonal);
    if PitchChange then
      TonalTarget := TonalTarget + Trunc((CodedBins shl BITRES) * K08);
    Target := TonalTarget;
  end;
  Bins := CELT_EBANDS[CELT_NB_EBANDS - 2] shl LM;
  FloorDepth := Trunc((C * Bins shl BITRES) * MaxDepth);
  FloorDepth := Max(FloorDepth, Sar(Target, 2));
  Target := Min(Target, FloorDepth);
  if ConstrainedVbr then
    Target := BaseTarget + Trunc(K067 * (Target - BaseTarget));
  if TfEstimate < K02 then
  begin
    Amount := K31 * Max(0, Min(32000, 96000 - Bitrate));
    TvbrFactor := TemporalVbr * Amount;
    Target := Target + Trunc(TvbrFactor * Target);
  end;
  Target := Min(2 * BaseTarget, Target);
  Result := Target;
end;

// ---------------------------------------------------------------------------
// TCeltEncoder
// ---------------------------------------------------------------------------

constructor TCeltEncoder.Create(SampleRate, AChannels: Integer);
begin
  inherited Create;
  if (AChannels < 1) or (AChannels > 2) then
    raise EArgumentException.Create('TCeltEncoder: channels must be 1 or 2');
  FUpsample := CeltResamplingFactor(SampleRate);
  if FUpsample = 0 then
    raise EArgumentException.Create('TCeltEncoder: unsupported sample rate');
  FChannels := AChannels;
  FStreamChannels := AChannels;
  FStart := 0;
  FEnd := CELT_NB_EBANDS;
  FConstrainedVbr := True;
  FClip := True;
  FBitrate := OPUS_BITRATE_MAX;
  FVbr := False;
  FForceIntra := False;
  FComplexity := 5;
  FLsbDepth := 24;
  Reset;
end;

procedure TCeltEncoder.Reset;
var
  I: Integer;
begin
  FRng := 0;
  FSpreadDecision := CELT_SPREAD_NORMAL;
  FDelayedIntra := 1;
  FTonalAverage := 256;
  FLastCodedBands := 0;
  FHfAverage := 0;
  FTapsetDecision := 0;
  FPrefilterPeriod := 0;
  FPrefilterGain := 0;
  FPrefilterTapset := 0;
  FConsecTransient := 0;
  FillChar(FAnalysis, SizeOf(FAnalysis), 0);
  FillChar(FSilkInfo, SizeOf(FSilkInfo), 0);
  FPreemphMemE[0] := 0; FPreemphMemE[1] := 0;
  FPreemphMemD[0] := 0; FPreemphMemD[1] := 0;
  FVbrReservoir := 0;
  FVbrDrift := 0;
  FVbrOffset := 0;
  FVbrCount := 0;
  FOverlapMax := 0;
  FStereoSaving := 0;
  FIntensity := 0;
  FSpecAvg := 0;
  FillChar(FInMem, SizeOf(FInMem), 0);
  FillChar(FPrefilterMem, SizeOf(FPrefilterMem), 0);
  FillChar(FOldBandE, SizeOf(FOldBandE), 0);
  FillChar(FEnergyError, SizeOf(FEnergyError), 0);
  for I := 0 to 2 * CELT_NB_EBANDS - 1 do
  begin
    FOldLogE[I] := -28.0;
    FOldLogE2[I] := -28.0;
  end;
end;

procedure TCeltEncoder.SetBitrate(Value: Integer);
begin
  // OPUS_SET_BITRATE on the CELT encoder: invalid values are ignored (the
  // libopus ctl returns OPUS_BAD_ARG and the Opus layer does not check it)
  if (Value <= 500) and (Value <> OPUS_BITRATE_MAX) then
    Exit;
  FBitrate := Min(Value, 260000 * FChannels);
end;

procedure TCeltEncoder.SetAnalysis(const Info: TAnalysisInfo);
begin
  FAnalysis := Info;
end;

procedure TCeltEncoder.SetSilkInfo(const Info: TSilkInfo);
begin
  FSilkInfo := Info;
end;

procedure TCeltEncoder.SetPrediction(Value: Integer);
begin
  FDisablePf := Value <= 1;
  FForceIntra := Value = 0;
end;

procedure TCeltEncoder.ComputeMdcts(ShortBlocks: Integer; Inp, OutF: PSingle; C, CC, LM: Integer);
var
  N, B, Shift, I, BlockIdx, Ch, Bound: Integer;
begin
  if ShortBlocks <> 0 then
  begin
    B := ShortBlocks;
    N := CELT_SHORT_MDCT;
    Shift := CELT_MAX_LM;
  end
  else
  begin
    B := 1;
    N := CELT_SHORT_MDCT shl LM;
    Shift := CELT_MAX_LM - LM;
  end;
  for Ch := 0 to CC - 1 do
    for BlockIdx := 0 to B - 1 do
      CltMdctForward(Inp + Ch * (B * N + CELT_OVERLAP_SIZE) + BlockIdx * N,
        OutF + BlockIdx + Ch * N * B, @CELT_WINDOW120[0], CELT_OVERLAP_SIZE, Shift, B);
  if (CC = 2) and (C = 1) then
    for I := 0 to B * N - 1 do
      OutF[I] := F_HALF * OutF[I] + F_HALF * OutF[B * N + I];
  if FUpsample <> 1 then
    for Ch := 0 to C - 1 do
    begin
      Bound := B * N div FUpsample;
      for I := 0 to Bound - 1 do
        OutF[Ch * B * N + I] := OutF[Ch * B * N + I] * FUpsample;
      FillChar(OutF[Ch * B * N + Bound], (B * N - Bound) * SizeOf(Single), 0);
    end;
end;

function TCeltEncoder.RunPrefilter(Inp: PSingle; CC, N, PrefilterTapset: Integer;
  out Pitch: Integer; out Gain: Single; out QGain: Integer; Enabled: Boolean;
  NbAvailableBytes: Integer): Boolean;
const
  K07 : Single = 0.7;
  K02 : Single = 0.2;
  K01 : Single = 0.1;
  K04 : Single = 0.4;
  K055: Single = 0.55;
  K09375: Single = 0.09375;
var
  Ch, PitchIndex, Qg, Offset: Integer;
  PreBuf: array of Single;
  Pre: array[0..1] of PSingle;
  PitchBuf: array of Single;
  Gain1, PfThreshold: Single;
  PfOn: Boolean;
  Overlap: Integer;
begin
  Overlap := CELT_OVERLAP_SIZE;
  SetLength(PreBuf, CC * (N + COMBFILTER_MAXPERIOD));
  Pre[0] := PSingle(@PreBuf[0]);
  Pre[1] := PSingle(@PreBuf[0]) + (N + COMBFILTER_MAXPERIOD);
  for Ch := 0 to CC - 1 do
  begin
    Move(FPrefilterMem[Ch * COMBFILTER_MAXPERIOD], Pre[Ch]^, COMBFILTER_MAXPERIOD * SizeOf(Single));
    Move(Inp[Ch * (N + Overlap) + Overlap], Pre[Ch][COMBFILTER_MAXPERIOD], N * SizeOf(Single));
  end;

  if Enabled then
  begin
    SetLength(PitchBuf, (COMBFILTER_MAXPERIOD + N) shr 1);
    PitchDownsample(Pre, @PitchBuf[0], COMBFILTER_MAXPERIOD + N, CC);
    PitchSearch(@PitchBuf[COMBFILTER_MAXPERIOD shr 1], @PitchBuf[0], N,
      COMBFILTER_MAXPERIOD - 3 * COMBFILTER_MINPERIOD, PitchIndex);
    PitchIndex := COMBFILTER_MAXPERIOD - PitchIndex;
    Gain1 := RemoveDoubling(@PitchBuf[0], COMBFILTER_MAXPERIOD, COMBFILTER_MINPERIOD,
      N, PitchIndex, FPrefilterPeriod, FPrefilterGain);
    if PitchIndex > COMBFILTER_MAXPERIOD - 2 then
      PitchIndex := COMBFILTER_MAXPERIOD - 2;
    Gain1 := K07 * Gain1;
    if FLossRate > 2 then Gain1 := F_HALF * Gain1;
    if FLossRate > 4 then Gain1 := F_HALF * Gain1;
    if FLossRate > 8 then Gain1 := 0;
  end
  else
  begin
    Gain1 := 0;
    PitchIndex := COMBFILTER_MINPERIOD;
  end;
  if FAnalysis.Valid then
    Gain1 := Gain1 * FAnalysis.MaxPitchRatio;

  PfThreshold := K02;
  if Abs(PitchIndex - FPrefilterPeriod) * 10 > PitchIndex then
    PfThreshold := PfThreshold + K02;
  if NbAvailableBytes < 25 then
    PfThreshold := PfThreshold + K01;
  if NbAvailableBytes < 35 then
    PfThreshold := PfThreshold + K01;
  if FPrefilterGain > K04 then
    PfThreshold := PfThreshold - K01;
  if FPrefilterGain > K055 then
    PfThreshold := PfThreshold - K01;
  PfThreshold := Max(PfThreshold, K02);
  if Gain1 < PfThreshold then
  begin
    Gain1 := 0;
    PfOn := False;
    Qg := 0;
  end
  else
  begin
    if Abs(Gain1 - FPrefilterGain) < K01 then
      Gain1 := FPrefilterGain;
    Qg := Floor(F_HALF + Gain1 * 32 / 3) - 1;
    Qg := Max(0, Min(7, Qg));
    Gain1 := K09375 * (Qg + 1);
    PfOn := True;
  end;

  for Ch := 0 to CC - 1 do
  begin
    Offset := CELT_SHORT_MDCT - Overlap;
    FPrefilterPeriod := Max(FPrefilterPeriod, COMBFILTER_MINPERIOD);
    Move(FInMem[Ch * Overlap], Inp[Ch * (N + Overlap)], Overlap * SizeOf(Single));
    if Offset <> 0 then
      CombFilterF(Inp + Ch * (N + Overlap) + Overlap, Pre[Ch] + COMBFILTER_MAXPERIOD,
        FPrefilterPeriod, FPrefilterPeriod, Offset, -FPrefilterGain, -FPrefilterGain,
        FPrefilterTapset, FPrefilterTapset, nil, 0);
    CombFilterF(Inp + Ch * (N + Overlap) + Overlap + Offset, Pre[Ch] + COMBFILTER_MAXPERIOD + Offset,
      FPrefilterPeriod, PitchIndex, N - Offset, -FPrefilterGain, -Gain1,
      FPrefilterTapset, PrefilterTapset, @CELT_WINDOW120[0], Overlap);
    Move(Inp[Ch * (N + Overlap) + N], FInMem[Ch * Overlap], Overlap * SizeOf(Single));
    if N > COMBFILTER_MAXPERIOD then
      Move(Pre[Ch][N], FPrefilterMem[Ch * COMBFILTER_MAXPERIOD], COMBFILTER_MAXPERIOD * SizeOf(Single))
    else
    begin
      Move(FPrefilterMem[Ch * COMBFILTER_MAXPERIOD + N], FPrefilterMem[Ch * COMBFILTER_MAXPERIOD],
        (COMBFILTER_MAXPERIOD - N) * SizeOf(Single));
      Move(Pre[Ch][COMBFILTER_MAXPERIOD], FPrefilterMem[Ch * COMBFILTER_MAXPERIOD + COMBFILTER_MAXPERIOD - N],
        N * SizeOf(Single));
    end;
  end;

  Gain := Gain1;
  Pitch := PitchIndex;
  QGain := Qg;
  Result := PfOn;
end;

function TCeltEncoder.EncodeWithEc(Pcm: PSingle; FrameSize: Integer; Compressed: PByte;
  NbCompressedBytes: Integer; Enc: PEcEnc): Integer;
const
  K04  : Single = 0.4;
  K03  : Single = 0.3;
  K02  : Single = 0.2;
  K07  : Single = 0.7;
  K025 : Single = 0.25;
  K05  : Single = 0.5;
  K002 : Single = 0.02;
  F2   : Single = 2.0;
  F3   : Single = 3.0;
  F15  : Single = 1.5;
  F10  : Single = 10.0;
  M28  : Single = -28.0;
  F001 : Single = 0.001;
var
  I, Ch, N, LM, M, CC, C: Integer;
  Bits, VbrRate, TotalBits, TotalBoost, Balance, Tell, Tell0Frac: Integer;
  LocalEnc: TEcEnc;
  InBuf, Freq, X, BandE, BandLogE, BandLogE2, Error, SurroundDynalloc: array of Single;
  FineQuant, Pulses, Cap, Offsets, Importance, SpreadWeight, FinePriority, TfRes: TIntArray;
  CollapseMasks: array of Byte;
  ShortBlocks, TfSelect, NbFilledBytes, NbAvailableBytes, StartB, EndB, EffEnd: Integer;
  CodedBands, AllocTrim, PitchIndex, DualStereo, EffectiveBytes, DynallocLogp: Integer;
  PrefilterTapset, AntiCollapseRsv, AntiCollapseOn, TfChan, TotBoost: Integer;
  SignalBandwidth, EquivRate, Qg, Width, Quanta, DynallocLoopLogp, Boost, J, Flag: Integer;
  Den, Tmp, VbrBound, MaxAllowed, LmDiff, BaseTarget, Target, MinAllowed, Delta,
  Adjust, MinBandwidth, Lambda: Integer;
  IsTransient, Silence, PfOn, PitchChange, SecondMdct, TransientGotDisabled,
  Hybrid, WeakTransient, EnableTfAnalysis, Enabled, NeedClip, AllowWeak, IsT: Boolean;
  Gain1, TfEstimate, SampleMax, MaxDepth, SurroundMasking, TemporalVbr, SurroundTrim,
  Follow, FrameAvg, Offset, Alpha, LsbThresh: Single;
  Octave: Integer;
begin
  CC := FChannels;
  C := FStreamChannels;
  StartB := FStart;
  EndB := FEnd;
  Hybrid := StartB <> 0;
  TfEstimate := 0;
  PitchIndex := COMBFILTER_MINPERIOD;
  Gain1 := 0;
  DualStereo := 0;
  PrefilterTapset := 0;
  AntiCollapseOn := 0;
  TfChan := 0;
  PitchChange := False;
  TransientGotDisabled := False;
  SurroundMasking := 0;
  TemporalVbr := 0;
  SurroundTrim := 0;
  WeakTransient := False;
  ShortBlocks := 0;
  if (NbCompressedBytes < 2) or (Pcm = nil) then
    Exit(OPUS_BAD_ARG);

  FrameSize := FrameSize * FUpsample;
  LM := 0;
  while LM <= CELT_MAX_LM do
  begin
    if (CELT_SHORT_MDCT shl LM) = FrameSize then Break;
    Inc(LM);
  end;
  if LM > CELT_MAX_LM then
    Exit(OPUS_BAD_ARG);
  M := 1 shl LM;
  N := M * CELT_SHORT_MDCT;

  if Enc = nil then
  begin
    Tell := 1;
    Tell0Frac := 1;
    NbFilledBytes := 0;
  end
  else
  begin
    Tell0Frac := EcTellFrac(Enc^);
    Tell := EcTell(Enc^);
    NbFilledBytes := (Tell + 4) shr 3;
  end;

  NbCompressedBytes := Min(NbCompressedBytes, CELT_ENC_MAX_BYTES);
  NbAvailableBytes := NbCompressedBytes - NbFilledBytes;

  if FVbr and (FBitrate <> OPUS_BITRATE_MAX) then
  begin
    Den := 48000 shr BITRES;
    VbrRate := (FBitrate * FrameSize + (Den shr 1)) div Den;
    EffectiveBytes := VbrRate shr (3 + BITRES);
  end
  else
  begin
    VbrRate := 0;
    Tmp := FBitrate * FrameSize;
    if Tell > 1 then
      Tmp := Tmp + Tell * 48000;
    if FBitrate <> OPUS_BITRATE_MAX then
    begin
      NbCompressedBytes := Max(2, Min(NbCompressedBytes, (Tmp + 4 * 48000) div (8 * 48000)));
      if Enc <> nil then
        EcEncShrink(Enc^, NbCompressedBytes);
    end;
    EffectiveBytes := NbCompressedBytes - NbFilledBytes;
  end;
  EquivRate := ((NbCompressedBytes * 8 * 50) shl (3 - LM)) - (40 * C + 20) * ((400 shr LM) - 50);
  if FBitrate <> OPUS_BITRATE_MAX then
    EquivRate := Min(EquivRate, FBitrate - (40 * C + 20) * ((400 shr LM) - 50));

  if Enc = nil then
  begin
    EcEncInit(LocalEnc, Compressed, NbCompressedBytes);
    Enc := @LocalEnc;
  end;

  if VbrRate > 0 then
  begin
    if FConstrainedVbr then
    begin
      VbrBound := VbrRate;
      if Tell = 1 then I := 2 else I := 0;
      MaxAllowed := Min(Max(I, Sar(VbrRate + VbrBound - FVbrReservoir, BITRES + 3)), NbAvailableBytes);
      if MaxAllowed < NbAvailableBytes then
      begin
        NbCompressedBytes := NbFilledBytes + MaxAllowed;
        NbAvailableBytes := MaxAllowed;
        EcEncShrink(Enc^, NbCompressedBytes);
      end;
    end;
  end;
  TotalBits := NbCompressedBytes * 8;

  EffEnd := EndB;
  if EffEnd > CELT_NB_EBANDS then
    EffEnd := CELT_NB_EBANDS;

  SetLength(InBuf, CC * (N + CELT_OVERLAP_SIZE));

  SampleMax := Max(FOverlapMax, CeltMaxAbs(Pcm, C * (N - CELT_OVERLAP_SIZE) div FUpsample));
  FOverlapMax := CeltMaxAbs(Pcm + C * (N - CELT_OVERLAP_SIZE) div FUpsample, C * CELT_OVERLAP_SIZE div FUpsample);
  SampleMax := Max(SampleMax, FOverlapMax);
  LsbThresh := F_ONE / (1 shl FLsbDepth);
  Silence := SampleMax <= LsbThresh;
  if Tell = 1 then
    EcEncBitLogp(Enc^, Ord(Silence), 15)
  else
    Silence := False;
  if Silence then
  begin
    if VbrRate > 0 then
    begin
      NbCompressedBytes := Min(NbCompressedBytes, NbFilledBytes + 2);
      EffectiveBytes := NbCompressedBytes;
      TotalBits := NbCompressedBytes * 8;
      NbAvailableBytes := 2;
      EcEncShrink(Enc^, NbCompressedBytes);
    end;
    Tell := NbCompressedBytes * 8;
    Enc^.NBitsTotal := Enc^.NBitsTotal + Tell - EcTell(Enc^);
  end;
  for Ch := 0 to CC - 1 do
  begin
    NeedClip := FClip and (SampleMax > CLIP_MAX);
    CeltPreemphasis(Pcm + Ch, @InBuf[Ch * (N + CELT_OVERLAP_SIZE) + CELT_OVERLAP_SIZE], N, CC,
      FUpsample, FPreemphMemE[Ch], NeedClip);
  end;

  // Find pitch period and gain
  Enabled := ((FLfe and (NbAvailableBytes > 3)) or (NbAvailableBytes > 12 * C)) and
    not Hybrid and not Silence and not FDisablePf and (FComplexity >= 5);
  PrefilterTapset := FTapsetDecision;
  PfOn := RunPrefilter(@InBuf[0], CC, N, PrefilterTapset, PitchIndex, Gain1, Qg, Enabled, NbAvailableBytes);
  if ((Gain1 > K04) or (FPrefilterGain > K04)) and ((not FAnalysis.Valid) or (FAnalysis.Tonality > 0.3)) and
     ((PitchIndex > 1.26 * FPrefilterPeriod) or (PitchIndex < 0.79 * FPrefilterPeriod)) then
    PitchChange := True;
  if not PfOn then
  begin
    if (not Hybrid) and (Tell + 16 <= TotalBits) then
      EcEncBitLogp(Enc^, 0, 1);
  end
  else
  begin
    EcEncBitLogp(Enc^, 1, 1);
    Inc(PitchIndex);
    Octave := EcIlog(PitchIndex) - 5;
    EcEncUInt(Enc^, Octave, 6);
    EcEncBits(Enc^, PitchIndex - (16 shl Octave), 4 + Octave);
    Dec(PitchIndex);
    EcEncBits(Enc^, Qg, 3);
    EcEncIcdf(Enc^, PrefilterTapset, @TAPSET_ICDF[0], 2);
  end;

  IsTransient := False;
  ShortBlocks := 0;
  if (FComplexity >= 1) and not FLfe then
  begin
    AllowWeak := Hybrid and (EffectiveBytes < 15) and (FSilkInfo.SignalType <> 2);
    IsTransient := TransientAnalysis(@InBuf[0], N + CELT_OVERLAP_SIZE, CC, TfEstimate, TfChan,
      AllowWeak, WeakTransient);
  end;
  if (LM > 0) and (EcTell(Enc^) + 3 <= TotalBits) then
  begin
    if IsTransient then
      ShortBlocks := M;
  end
  else
  begin
    IsTransient := False;
    TransientGotDisabled := True;
  end;

  SetLength(Freq, CC * N);
  SetLength(BandE, CELT_NB_EBANDS * CC);
  SetLength(BandLogE, CELT_NB_EBANDS * CC);
  SecondMdct := (ShortBlocks <> 0) and (FComplexity >= 8);
  SetLength(BandLogE2, C * CELT_NB_EBANDS);
  if SecondMdct then
  begin
    ComputeMdcts(0, @InBuf[0], @Freq[0], C, CC, LM);
    ComputeBandEnergies(@Freq[0], @BandE[0], EffEnd, C, LM);
    Amp2Log2(EffEnd, EndB, @BandE[0], @BandLogE2[0], C);
    for Ch := 0 to C - 1 do
      for I := 0 to EndB - 1 do
        BandLogE2[CELT_NB_EBANDS * Ch + I] := BandLogE2[CELT_NB_EBANDS * Ch + I] + F_HALF * LM;
  end;

  ComputeMdcts(ShortBlocks, @InBuf[0], @Freq[0], C, CC, LM);
  if (CC = 2) and (C = 1) then
    TfChan := 0;
  ComputeBandEnergies(@Freq[0], @BandE[0], EffEnd, C, LM);
  if FLfe then
    for I := 2 to EndB - 1 do
    begin
      BandE[I] := Min(BandE[I], Single(1e-4) * BandE[0]);
      BandE[I] := Max(BandE[I], F_EPSILON);
    end;
  Amp2Log2(EffEnd, EndB, @BandE[0], @BandLogE[0], C);

  SetLength(SurroundDynalloc, C * CELT_NB_EBANDS);
  // (surround masking needs an energy mask: multistream only, not ported)

  // Temporal VBR (but not for LFE)
  if not FLfe then
  begin
    Follow := -F10;
    FrameAvg := 0;
    if ShortBlocks <> 0 then Offset := F_HALF * LM else Offset := 0;
    for I := StartB to EndB - 1 do
    begin
      Follow := Max(Follow - F_ONE, BandLogE[I] - Offset);
      if C = 2 then
        Follow := Max(Follow, BandLogE[I + CELT_NB_EBANDS] - Offset);
      FrameAvg := FrameAvg + Follow;
    end;
    FrameAvg := FrameAvg / (EndB - StartB);
    TemporalVbr := FrameAvg - FSpecAvg;
    TemporalVbr := Min(F3, Max(-F15, TemporalVbr));
    FSpecAvg := FSpecAvg + K002 * TemporalVbr;
  end;

  if not SecondMdct then
    Move(BandLogE[0], BandLogE2[0], C * CELT_NB_EBANDS * SizeOf(Single));

  // Last chance to catch any transient we might have missed in the
  // time-domain analysis
  if (LM > 0) and (EcTell(Enc^) + 3 <= TotalBits) and not IsTransient and (FComplexity >= 5) and
     not FLfe and not Hybrid then
  begin
    if PatchTransientDecision(@BandLogE[0], @FOldBandE[0], StartB, EndB, C) then
    begin
      IsTransient := True;
      ShortBlocks := M;
      ComputeMdcts(ShortBlocks, @InBuf[0], @Freq[0], C, CC, LM);
      ComputeBandEnergies(@Freq[0], @BandE[0], EffEnd, C, LM);
      Amp2Log2(EffEnd, EndB, @BandE[0], @BandLogE[0], C);
      for Ch := 0 to C - 1 do
        for I := 0 to EndB - 1 do
          BandLogE2[CELT_NB_EBANDS * Ch + I] := BandLogE2[CELT_NB_EBANDS * Ch + I] + F_HALF * LM;
      TfEstimate := K02;
    end;
  end;

  if (LM > 0) and (EcTell(Enc^) + 3 <= TotalBits) then
    EcEncBitLogp(Enc^, Ord(IsTransient), 3);

  SetLength(X, C * N);
  NormaliseBands(@Freq[0], @X[0], @BandE[0], EffEnd, C, M);

  EnableTfAnalysis := (EffectiveBytes >= 15 * C) and not Hybrid and (FComplexity >= 2) and not FLfe;

  SetLength(Offsets, CELT_NB_EBANDS);
  SetLength(Importance, CELT_NB_EBANDS);
  SetLength(SpreadWeight, CELT_NB_EBANDS);

  MaxDepth := DynallocAnalysis(@BandLogE[0], @BandLogE2[0], @FOldBandE[0], StartB, EndB, C,
    @Offsets[0], FLsbDepth, IsTransient, FVbr, FConstrainedVbr, LM, EffectiveBytes, TotBoost,
    FLfe, @SurroundDynalloc[0], FAnalysis, @Importance[0], @SpreadWeight[0]);

  SetLength(TfRes, CELT_NB_EBANDS);
  IsT := IsTransient;
  if EnableTfAnalysis then
  begin
    Lambda := Max(80, 20480 div EffectiveBytes + 2);
    TfSelect := TfAnalysis(EffEnd, Ord(IsT), @TfRes[0], Lambda, @X[0], N, LM, TfEstimate, TfChan,
      @Importance[0]);
    for I := EffEnd to EndB - 1 do
      TfRes[I] := TfRes[EffEnd - 1];
  end
  else if Hybrid and WeakTransient then
  begin
    for I := 0 to EndB - 1 do
      TfRes[I] := 1;
    TfSelect := 0;
  end
  else if Hybrid and (EffectiveBytes < 15) and (FSilkInfo.SignalType <> 2) then
  begin
    for I := 0 to EndB - 1 do
      TfRes[I] := 0;
    TfSelect := Ord(IsT);
  end
  else
  begin
    for I := 0 to EndB - 1 do
      TfRes[I] := Ord(IsT);
    TfSelect := 0;
  end;

  SetLength(Error, C * CELT_NB_EBANDS);
  for Ch := 0 to C - 1 do
    for I := StartB to EndB - 1 do
      if Abs(BandLogE[I + Ch * CELT_NB_EBANDS] - FOldBandE[I + Ch * CELT_NB_EBANDS]) < F2 then
        BandLogE[I + Ch * CELT_NB_EBANDS] := BandLogE[I + Ch * CELT_NB_EBANDS] -
          FEnergyError[I + Ch * CELT_NB_EBANDS] * K025;
  QuantCoarseEnergy(StartB, EndB, EffEnd, @BandLogE[0], @FOldBandE[0], TotalBits, @Error[0],
    Enc^, C, LM, NbAvailableBytes, FForceIntra, FDelayedIntra, FComplexity >= 4, FLossRate, FLfe);

  TfEncode(StartB, EndB, Ord(IsT), @TfRes[0], LM, TfSelect, Enc^);

  if EcTell(Enc^) + 4 <= TotalBits then
  begin
    if FLfe then
    begin
      FTapsetDecision := 0;
      FSpreadDecision := CELT_SPREAD_NORMAL;
    end
    else if Hybrid then
    begin
      if FComplexity = 0 then FSpreadDecision := CELT_SPREAD_NONE
      else if IsTransient then FSpreadDecision := CELT_SPREAD_NORMAL
      else FSpreadDecision := CELT_SPREAD_AGGRESSIVE;
    end
    else if (ShortBlocks <> 0) or (FComplexity < 3) or (NbAvailableBytes < 10 * C) then
    begin
      if FComplexity = 0 then FSpreadDecision := CELT_SPREAD_NONE
      else FSpreadDecision := CELT_SPREAD_NORMAL;
    end
    else
      FSpreadDecision := SpreadingDecision(@X[0], FTonalAverage, FSpreadDecision, FHfAverage,
        FTapsetDecision, PfOn and (ShortBlocks = 0), EffEnd, C, M, @SpreadWeight[0]);
    EcEncIcdf(Enc^, FSpreadDecision, @SPREAD_ICDF[0], 5);
  end;

  if FLfe then
    Offsets[0] := Min(8, EffectiveBytes div 3);
  InitCaps(Cap, LM, C);

  DynallocLogp := 6;
  TotalBits := TotalBits shl BITRES;
  TotalBoost := 0;
  Tell := EcTellFrac(Enc^);
  for I := StartB to EndB - 1 do
  begin
    Width := C * (CELT_EBANDS[I + 1] - CELT_EBANDS[I]) shl LM;
    Quanta := Min(Width shl BITRES, Max(6 shl BITRES, Width));
    DynallocLoopLogp := DynallocLogp;
    Boost := 0;
    J := 0;
    while (Tell + (DynallocLoopLogp shl BITRES) < TotalBits - TotalBoost) and (Boost < Cap[I]) do
    begin
      Flag := Ord(J < Offsets[I]);
      EcEncBitLogp(Enc^, Flag, DynallocLoopLogp);
      Tell := EcTellFrac(Enc^);
      if Flag = 0 then
        Break;
      Boost := Boost + Quanta;
      TotalBoost := TotalBoost + Quanta;
      DynallocLoopLogp := 1;
      Inc(J);
    end;
    if J <> 0 then
      DynallocLogp := Max(2, DynallocLogp - 1);
    Offsets[I] := Boost;
  end;

  if C = 2 then
  begin
    if LM <> 0 then
      DualStereo := Ord(StereoAnalysis(@X[0], LM, N));
    FIntensity := HysteresisDecision(EquivRate div 1000, @INTENSITY_THRESHOLDS[0],
      @INTENSITY_HISTERESIS[0], 21, FIntensity);
    FIntensity := Min(EndB, Max(StartB, FIntensity));
  end;

  AllocTrim := 5;
  if Tell + (6 shl BITRES) <= TotalBits - TotalBoost then
  begin
    if (StartB > 0) or FLfe then
    begin
      FStereoSaving := 0;
      AllocTrim := 5;
    end
    else
      AllocTrim := AllocTrimAnalysis(@X[0], @BandLogE[0], EndB, LM, C, N, FAnalysis,
        FStereoSaving, TfEstimate, FIntensity, SurroundTrim, EquivRate);
    EcEncIcdf(Enc^, AllocTrim, @TRIM_ICDF[0], 7);
    Tell := EcTellFrac(Enc^);
  end;

  // Variable bitrate
  if VbrRate > 0 then
  begin
    LmDiff := CELT_MAX_LM - LM;
    NbCompressedBytes := Min(NbCompressedBytes, CELT_ENC_MAX_BYTES shr (3 - LM));
    if not Hybrid then
      BaseTarget := VbrRate - ((40 * C + 20) shl BITRES)
    else
      BaseTarget := Max(0, VbrRate - ((9 * C + 4) shl BITRES));
    if FConstrainedVbr then
      BaseTarget := BaseTarget + Sar(FVbrOffset, LmDiff);
    if not Hybrid then
      Target := ComputeVbr(FAnalysis, BaseTarget, LM, EquivRate, FLastCodedBands, C,
        FIntensity, FConstrainedVbr, FStereoSaving, TotBoost, TfEstimate, PitchChange,
        MaxDepth, FLfe, TemporalVbr)
    else
    begin
      Target := BaseTarget;
      if FSilkInfo.Offset < 100 then Target := Target + (12 shl BITRES shr (3 - LM));
      if FSilkInfo.Offset > 100 then Target := Target - (18 shl BITRES shr (3 - LM));
      Target := Target + Trunc((TfEstimate - K025) * (50 shl BITRES));
      if TfEstimate > K07 then
        Target := Max(Target, 50 shl BITRES);
    end;
    Target := Target + Tell;
    MinAllowed := ((Tell + TotalBoost + (1 shl (BITRES + 3)) - 1) shr (BITRES + 3)) + 2;
    if Hybrid then
      MinAllowed := Max(MinAllowed, (Tell0Frac + (37 shl BITRES) + TotalBoost + (1 shl (BITRES + 3)) - 1)
        shr (BITRES + 3));
    NbAvailableBytes := Sar(Target + (1 shl (BITRES + 2)), BITRES + 3);
    NbAvailableBytes := Max(MinAllowed, NbAvailableBytes);
    NbAvailableBytes := Min(NbCompressedBytes, NbAvailableBytes);
    Delta := Target - VbrRate;
    Target := NbAvailableBytes shl (BITRES + 3);
    if Silence then
    begin
      NbAvailableBytes := 2;
      Target := 2 * 8 shl BITRES;
      Delta := 0;
    end;
    if FVbrCount < 970 then
    begin
      Inc(FVbrCount);
      Alpha := F_ONE / (FVbrCount + 20);
    end
    else
      Alpha := F001;
    if FConstrainedVbr then
      FVbrReservoir := FVbrReservoir + Target - VbrRate;
    if FConstrainedVbr then
    begin
      FVbrDrift := FVbrDrift + Trunc(Alpha * ((Delta * (1 shl LmDiff)) - FVbrOffset - FVbrDrift));
      FVbrOffset := -FVbrDrift;
    end;
    if FConstrainedVbr and (FVbrReservoir < 0) then
    begin
      Adjust := (-FVbrReservoir) div (8 shl BITRES);
      if not Silence then
        NbAvailableBytes := NbAvailableBytes + Adjust;
      FVbrReservoir := 0;
    end;
    NbCompressedBytes := Min(NbCompressedBytes, NbAvailableBytes);
    EcEncShrink(Enc^, NbCompressedBytes);
  end;

  // Bit allocation
  SetLength(FineQuant, CELT_NB_EBANDS);
  SetLength(Pulses, CELT_NB_EBANDS);
  SetLength(FinePriority, CELT_NB_EBANDS);

  Bits := ((NbCompressedBytes * 8) shl BITRES) - Integer(EcTellFrac(Enc^)) - 1;
  if IsTransient and (LM >= 2) and (Bits >= ((LM + 2) shl BITRES)) then
    AntiCollapseRsv := 1 shl BITRES
  else
    AntiCollapseRsv := 0;
  Bits := Bits - AntiCollapseRsv;
  SignalBandwidth := EndB - 1;
  if FAnalysis.Valid then
  begin
    if EquivRate < 32000 * C then MinBandwidth := 13
    else if EquivRate < 48000 * C then MinBandwidth := 16
    else if EquivRate < 60000 * C then MinBandwidth := 18
    else if EquivRate < 80000 * C then MinBandwidth := 19
    else MinBandwidth := 20;
    SignalBandwidth := Max(FAnalysis.Bandwidth, MinBandwidth);
  end;
  if FLfe then
    SignalBandwidth := 1;
  CodedBands := CltComputeAllocationEnc(StartB, EndB, Offsets, Cap, AllocTrim, FIntensity,
    DualStereo, Bits, Balance, Pulses, FineQuant, FinePriority, C, LM, Enc^, FLastCodedBands,
    SignalBandwidth);
  if FLastCodedBands <> 0 then
    FLastCodedBands := Min(FLastCodedBands + 1, Max(FLastCodedBands - 1, CodedBands))
  else
    FLastCodedBands := CodedBands;

  QuantFineEnergy(StartB, EndB, @FOldBandE[0], @Error[0], FineQuant, Enc^, C);

  // Residual quantisation
  SetLength(CollapseMasks, C * CELT_NB_EBANDS);
  if C = 2 then
    QuantAllBandsEnc(StartB, EndB, @X[0], @X[N], @CollapseMasks[0], @BandE[0], Pulses,
      ShortBlocks, FSpreadDecision, DualStereo, FIntensity, TfRes,
      NbCompressedBytes * (8 shl BITRES) - AntiCollapseRsv, Balance, Enc^, LM, CodedBands,
      FRng, FComplexity, FDisableInv)
  else
    QuantAllBandsEnc(StartB, EndB, @X[0], nil, @CollapseMasks[0], @BandE[0], Pulses,
      ShortBlocks, FSpreadDecision, DualStereo, FIntensity, TfRes,
      NbCompressedBytes * (8 shl BITRES) - AntiCollapseRsv, Balance, Enc^, LM, CodedBands,
      FRng, FComplexity, FDisableInv);

  if AntiCollapseRsv > 0 then
  begin
    AntiCollapseOn := Ord(FConsecTransient < 2);
    EcEncBits(Enc^, AntiCollapseOn, 1);
  end;
  QuantEnergyFinalise(StartB, EndB, @FOldBandE[0], @Error[0], FineQuant, FinePriority,
    NbCompressedBytes * 8 - EcTell(Enc^), Enc^, C);
  FillChar(FEnergyError, SizeOf(FEnergyError), 0);
  for Ch := 0 to C - 1 do
    for I := StartB to EndB - 1 do
      FEnergyError[I + Ch * CELT_NB_EBANDS] := Max(-K05, Min(K05, Error[I + Ch * CELT_NB_EBANDS]));

  if Silence then
    for I := 0 to C * CELT_NB_EBANDS - 1 do
      FOldBandE[I] := M28;

  FPrefilterPeriod := PitchIndex;
  FPrefilterGain := Gain1;
  FPrefilterTapset := PrefilterTapset;

  if (CC = 2) and (C = 1) then
    Move(FOldBandE[0], FOldBandE[CELT_NB_EBANDS], CELT_NB_EBANDS * SizeOf(Single));

  if not IsTransient then
  begin
    Move(FOldLogE[0], FOldLogE2[0], CC * CELT_NB_EBANDS * SizeOf(Single));
    Move(FOldBandE[0], FOldLogE[0], CC * CELT_NB_EBANDS * SizeOf(Single));
  end
  else
    for I := 0 to CC * CELT_NB_EBANDS - 1 do
      FOldLogE[I] := Min(FOldLogE[I], FOldBandE[I]);
  for Ch := 0 to CC - 1 do
  begin
    for I := 0 to StartB - 1 do
    begin
      FOldBandE[Ch * CELT_NB_EBANDS + I] := 0;
      FOldLogE[Ch * CELT_NB_EBANDS + I] := M28;
      FOldLogE2[Ch * CELT_NB_EBANDS + I] := M28;
    end;
    for I := EndB to CELT_NB_EBANDS - 1 do
    begin
      FOldBandE[Ch * CELT_NB_EBANDS + I] := 0;
      FOldLogE[Ch * CELT_NB_EBANDS + I] := M28;
      FOldLogE2[Ch * CELT_NB_EBANDS + I] := M28;
    end;
  end;

  if IsTransient or TransientGotDisabled then
    Inc(FConsecTransient)
  else
    FConsecTransient := 0;
  FRng := Enc^.Rng;

  EcEncDone(Enc^);

  if Enc^.Error <> 0 then
    Result := OPUS_INTERNAL_ERROR
  else
    Result := NbCompressedBytes;
end;

end.
