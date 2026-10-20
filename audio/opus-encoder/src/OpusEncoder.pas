unit OpusEncoder;

{
  OpusEncoder.pas - Opus encoder (RFC 6716), equivalent of opus_encoder_create /
  opus_encode / opus_encode_float / opus_encoder_ctl

  Port of libopus 1.5.2 src/opus_encoder.c (float build).

  SILK, hybrid and CELT modes, mode/bandwidth/channel decisions driven by the
  tonality analysis (analysis.c: speech/music probability, detected
  bandwidth, activity for DTX), in-band FEC (LBRR), DTX and the redundant
  CELT frames of mode transitions follow libopus.

  Copyright (c) 2010-2011 Xiph.Org Foundation, Skype Limited.
  Written by Jean-Marc Valin and Koen Vos.
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
  OpusCeltEncMath,
  OpusCeltEnc,
  OpusRepacketizer,
  OpusEncTypes,
  OpusSilkEncDefs,
  OpusAnalysis;

const
  OPUS_MAX_PACKET_BYTES = 1276;

type
  TOpusEncoder = class
  private
    FCelt               : TCeltEncoder;
    FSilk               : PSilkEncoder;
    FAnalysis           : TTonalityAnalysisState;
    FSilkMode           : TSilkEncControl;
    FApplication        : Integer;
    FChannels           : Integer;
    FDelayCompensation  : Integer;
    FForceChannels      : Integer;
    FSignalType         : Integer;
    FUserBandwidth      : Integer;
    FMaxBandwidth       : Integer;
    FUserForcedMode     : Integer;
    FVoiceRatio         : Integer;
    FFs                 : Integer;
    FUseVbr             : Boolean;
    FVbrConstraint      : Boolean;
    FVariableDuration   : Integer;
    FBitrateBps         : Integer;
    FUserBitrateBps     : Integer;
    FLsbDepth           : Integer;
    FEncoderBuffer      : Integer;
    FLfe                : Boolean;
    FUseDtx             : Boolean;
    FFecConfig          : Integer;
    // reset state (OPUS_ENCODER_RESET_START)
    FStreamChannels     : Integer;
    FHybridStereoWidthQ14: Integer;
    FVariableHPSmth2Q15 : Integer;
    FPrevHBGain         : Single;
    FHpMem              : array[0..3] of Single;
    FMode               : Integer;
    FPrevMode           : Integer;
    FPrevChannels       : Integer;
    FPrevFramesize      : Integer;
    FBandwidth          : Integer;
    FAutoBandwidth      : Integer;
    FSilkBwSwitch       : Integer;
    FFirst              : Boolean;
    FWidthXX, FWidthXY, FWidthYY: Single;
    FSmoothedWidth      : Single;
    FMaxFollower        : Single;
    FDelayBuffer        : array[0..2 * 480 - 1] of Single;
    FDetectedBandwidth  : Integer;
    FNbNoActivityMsQ1   : Integer;
    FPeakSignalEnergy   : Single;
    FNonfinalFrame      : Boolean;
    FRangeFinal         : Cardinal;
    procedure ResetState;
    function  UserBitrateToBitrate(FrameSize, MaxDataBytes: Integer): Integer;
    function  ComputeStereoWidth(Pcm: PSingle; FrameSize: Integer): Single;
    function  EncodeNative(Pcm: PSingle; FrameSize: Integer; Data: PByte;
      OutDataBytes, LsbDepth: Integer; FloatApi: Boolean; AnalysisPcm: PSingle;
      AnalysisSize: Integer): Integer;
    function  EncodeFrameNative(Pcm: PSingle; FrameSize: Integer; Data: PByte;
      MaxDataBytes: Integer; FloatApi, FirstFrame: Boolean; const AnalysisInfo: TAnalysisInfo;
      IsSilence: Boolean; Redundancy, CeltToSilk: Boolean; Prefill: Integer; EquivRate: Integer;
      ToCelt: Boolean): Integer;
    procedure SetBitrate(Value: Integer);
    function  GetBitrate: Integer;
    procedure SetComplexity(Value: Integer);
    function  GetComplexity: Integer;
    procedure SetVbr(Value: Boolean);
    procedure SetInbandFec(Value: Integer);
    procedure SetPacketLossPerc(Value: Integer);
    function  GetPacketLossPerc: Integer;
    procedure SetSignal(Value: Integer);
    procedure SetBandwidth(Value: Integer);
    procedure SetMaxBandwidth(Value: Integer);
    procedure SetForceChannels(Value: Integer);
    procedure SetLsbDepth(Value: Integer);
    procedure SetExpertFrameDuration(Value: Integer);
    procedure SetPredictionDisabled(Value: Boolean);
    function  GetPredictionDisabled: Boolean;
    procedure SetPhaseInversionDisabled(Value: Boolean);
    function  GetPhaseInversionDisabled: Boolean;
    procedure SetForceMode(Value: Integer);
    procedure SetVoiceRatio(Value: Integer);
    procedure SetApplication(Value: Integer);
    procedure SetLfe(Value: Boolean);
    function  GetLookahead: Integer;
    function  GetInDTX: Boolean;
  public
    // SampleRate: 8000, 12000, 16000, 24000 or 48000. Channels: 1 or 2.
    constructor Create(SampleRate, Channels: Integer; Application: TOpusApplication); overload;
    constructor Create(SampleRate, Channels, Application: Integer); overload;
    destructor Destroy; override;
    procedure Reset;   // OPUS_RESET_STATE
    // opus_encode: interleaved 16-bit PCM, FrameSize samples per channel
    // (2.5, 5, 10, 20, 40 or 60 ms). Returns the packet length or an OPUS_*
    // error code (negative).
    function Encode(Pcm: PSmallInt; FrameSize: Integer; Data: PByte; MaxDataBytes: Integer): Integer;
    // opus_encode_float: interleaved float PCM in [-1, 1]
    function EncodeFloat(Pcm: PSingle; FrameSize: Integer; Data: PByte; MaxDataBytes: Integer): Integer;

    // CTLs
    property Application: Integer read FApplication write SetApplication;
    // bits/s, OPUS_AUTO or OPUS_BITRATE_MAX
    property Bitrate: Integer read GetBitrate write SetBitrate;
    property Complexity: Integer read GetComplexity write SetComplexity;
    property Vbr: Boolean read FUseVbr write SetVbr;
    property VbrConstraint: Boolean read FVbrConstraint write FVbrConstraint;
    property InbandFec: Integer read FFecConfig write SetInbandFec;   // 0, 1, 2
    property PacketLossPerc: Integer read GetPacketLossPerc write SetPacketLossPerc;
    property Dtx: Boolean read FUseDtx write FUseDtx;
    property Signal: Integer read FSignalType write SetSignal;           // OPUS_AUTO / OPUS_SIGNAL_*
    property Bandwidth: Integer read FBandwidth write SetBandwidth;     // get: last coded bandwidth
    property UserBandwidth: Integer read FUserBandwidth;
    property MaxBandwidth: Integer read FMaxBandwidth write SetMaxBandwidth;
    property ForceChannels: Integer read FForceChannels write SetForceChannels;
    property LsbDepth: Integer read FLsbDepth write SetLsbDepth;
    property ExpertFrameDuration: Integer read FVariableDuration write SetExpertFrameDuration;
    property PredictionDisabled: Boolean read GetPredictionDisabled write SetPredictionDisabled;
    property PhaseInversionDisabled: Boolean read GetPhaseInversionDisabled write SetPhaseInversionDisabled;
    property ForceMode: Integer read FUserForcedMode write SetForceMode;  // OPUS_AUTO or MODE_*
    property VoiceRatio: Integer read FVoiceRatio write SetVoiceRatio;
    property Lfe: Boolean read FLfe write SetLfe;
    property Lookahead: Integer read GetLookahead;
    property SampleRate: Integer read FFs;
    property Channels: Integer read FChannels;
    property FinalRange: Cardinal read FRangeFinal;
    property InDTX: Boolean read GetInDTX;
    property Mode: Integer read FMode;   // mode of the last frame (MODE_*)
  end;

function OpusFrameSizeSelect(FrameSize, VariableDuration, Fs: Integer): Integer;

implementation

uses
  OpusSilkMath, OpusSilkEnc;

const
  MAX_ENCODER_BUFFER = 480;
  VARIABLE_HP_MIN_CUTOFF_HZ = 60;
  NB_SPEECH_FRAMES_BEFORE_DTX = 10;
  MAX_CONSECUTIVE_DTX = 20;
  VAD_NO_DECISION = -1;
  DTX_ACTIVITY_THRESHOLD: Single = 0.1;
  PSEUDO_SNR_THRESHOLD: Single = 316.23;
  VERY_SMALL: Single = 1e-30;
  INV32768: Single = 1.0 / 32768;
  INV16384: Single = 1.0 / 16384;
  INV2P28: Single = 1.0 / 268435456;

  FEC_THRESHOLDS: array[0..9] of Integer = (
    12000, 1000, 14000, 1000, 16000, 1000, 20000, 1000, 22000, 1000);
  HYBRID_RATE_TABLE: array[0..6, 0..4] of Integer = (
    (0, 0, 0, 0, 0),
    (12000, 10000, 10000, 11000, 11000),
    (16000, 13500, 13500, 15000, 15000),
    (20000, 16000, 16000, 18000, 18000),
    (24000, 18000, 18000, 21000, 21000),
    (32000, 22000, 22000, 28000, 28000),
    (64000, 38000, 38000, 50000, 50000));

  MONO_VOICE_BANDWIDTH_THRESHOLDS: array[0..7] of Integer = (
    9000, 700, 9000, 700, 13500, 1000, 14000, 2000);
  MONO_MUSIC_BANDWIDTH_THRESHOLDS: array[0..7] of Integer = (
    9000, 700, 9000, 700, 11000, 1000, 12000, 2000);
  STEREO_VOICE_BANDWIDTH_THRESHOLDS: array[0..7] of Integer = (
    9000, 700, 9000, 700, 13500, 1000, 14000, 2000);
  STEREO_MUSIC_BANDWIDTH_THRESHOLDS: array[0..7] of Integer = (
    9000, 700, 9000, 700, 11000, 1000, 12000, 2000);
  STEREO_VOICE_THRESHOLD = 19000;
  STEREO_MUSIC_THRESHOLD = 17000;
  MODE_THRESHOLDS: array[0..1, 0..1] of Integer = ((64000, 10000), (44000, 10000));

function GenToc(Mode, Framerate, Bandwidth, Channels: Integer): Byte;
var
  Period, Tmp: Integer;
  Toc: Integer;
begin
  Period := 0;
  while Framerate < 400 do
  begin
    Framerate := Framerate shl 1;
    Inc(Period);
  end;
  if Mode = MODE_SILK_ONLY then
  begin
    Toc := (Bandwidth - OPUS_BANDWIDTH_NARROWBAND) shl 5;
    Toc := Toc or ((Period - 2) shl 3);
  end
  else if Mode = MODE_CELT_ONLY then
  begin
    Tmp := Bandwidth - OPUS_BANDWIDTH_MEDIUMBAND;
    if Tmp < 0 then Tmp := 0;
    Toc := $80;
    Toc := Toc or (Tmp shl 5);
    Toc := Toc or (Period shl 3);
  end
  else
  begin
    Toc := $60;
    Toc := Toc or ((Bandwidth - OPUS_BANDWIDTH_SUPERWIDEBAND) shl 4);
    Toc := Toc or ((Period - 2) shl 3);
  end;
  Toc := Toc or (Ord(Channels = 2) shl 2);
  Result := Byte(Toc);
end;

procedure SilkBiquadFloat(InP: PSingle; const BQ28: array of Integer; const AQ28: array of Integer;
  S: PSingle; OutP: PSingle; Len, Stride: Integer);
var
  K: Integer;
  VOut, InVal: Single;
  A: array[0..1] of Single;
  B: array[0..2] of Single;
begin
  A[0] := AQ28[0] * INV2P28;
  A[1] := AQ28[1] * INV2P28;
  B[0] := BQ28[0] * INV2P28;
  B[1] := BQ28[1] * INV2P28;
  B[2] := BQ28[2] * INV2P28;
  for K := 0 to Len - 1 do
  begin
    InVal := InP[K * Stride];
    VOut := S[0] + B[0] * InVal;
    S[0] := S[1] - VOut * A[0] + B[1] * InVal;
    S[1] := -VOut * A[1] + B[2] * InVal + VERY_SMALL;
    OutP[K * Stride] := VOut;
  end;
end;

procedure HpCutoff(InP: PSingle; CutoffHz: Integer; OutP: PSingle; HpMem: PSingle;
  Len, Channels, Fs: Integer);
const
  FC_CONST = 2471;     // SILK_FIX_CONST(1.5 * 3.14159 / 1000, 19)
  R092_Q9 = 471;       // SILK_FIX_CONST(0.92, 9)
var
  BQ28: array[0..2] of Integer;
  AQ28: array[0..1] of Integer;
  FcQ19, RQ28, RQ22: Integer;
begin
  FcQ19 := SilkSMULBB(FC_CONST, CutoffHz) div (Fs div 1000);
  RQ28 := (1 shl 28) - R092_Q9 * FcQ19;
  BQ28[0] := RQ28;
  BQ28[1] := (-RQ28) shl 1;
  BQ28[2] := RQ28;
  RQ22 := Sar32(RQ28, 6);
  AQ28[0] := SilkSMULWW(RQ22, SilkSMULWW(FcQ19, FcQ19) - (2 shl 22));
  AQ28[1] := SilkSMULWW(RQ22, RQ22);
  SilkBiquadFloat(InP, BQ28, AQ28, HpMem, OutP, Len, Channels);
  if Channels = 2 then
    SilkBiquadFloat(InP + 1, BQ28, AQ28, HpMem + 2, OutP + 1, Len, Channels);
end;

procedure DcReject(InP: PSingle; CutoffHz: Integer; OutP: PSingle; HpMem: PSingle;
  Len, Channels, Fs: Integer);
const
  K63: Single = 6.3;
var
  I: Integer;
  Coef, Coef2, M0, M2, X0, X1, Out0, Out1, X, Y: Single;
begin
  Coef := K63 * CutoffHz / Fs;
  Coef2 := 1 - Coef;
  if Channels = 2 then
  begin
    M0 := HpMem[0];
    M2 := HpMem[2];
    for I := 0 to Len - 1 do
    begin
      X0 := InP[2 * I + 0];
      X1 := InP[2 * I + 1];
      Out0 := X0 - M0;
      Out1 := X1 - M2;
      M0 := Coef * X0 + VERY_SMALL + Coef2 * M0;
      M2 := Coef * X1 + VERY_SMALL + Coef2 * M2;
      OutP[2 * I + 0] := Out0;
      OutP[2 * I + 1] := Out1;
    end;
    HpMem[0] := M0;
    HpMem[2] := M2;
  end
  else
  begin
    M0 := HpMem[0];
    for I := 0 to Len - 1 do
    begin
      X := InP[I];
      Y := X - M0;
      M0 := Coef * X + VERY_SMALL + Coef2 * M0;
      OutP[I] := Y;
    end;
    HpMem[0] := M0;
  end;
end;

procedure StereoFade(InP, OutP: PSingle; G1, G2: Single; Overlap48, FrameSize, Channels: Integer;
  Window: PSingle; Fs: Integer);
var
  I, Overlap, Inc_: Integer;
  Diff, G, W: Single;
begin
  Inc_ := 48000 div Fs;
  Overlap := Overlap48 div Inc_;
  G1 := F_ONE - G1;
  G2 := F_ONE - G2;
  for I := 0 to Overlap - 1 do
  begin
    W := Window[I * Inc_] * Window[I * Inc_];
    G := W * G2 + (F_ONE - W) * G1;
    Diff := F_HALF * (InP[I * Channels] - InP[I * Channels + 1]);
    Diff := G * Diff;
    OutP[I * Channels] := OutP[I * Channels] - Diff;
    OutP[I * Channels + 1] := OutP[I * Channels + 1] + Diff;
  end;
  for I := Overlap to FrameSize - 1 do
  begin
    Diff := F_HALF * (InP[I * Channels] - InP[I * Channels + 1]);
    Diff := G2 * Diff;
    OutP[I * Channels] := OutP[I * Channels] - Diff;
    OutP[I * Channels + 1] := OutP[I * Channels + 1] + Diff;
  end;
end;

procedure GainFade(InP, OutP: PSingle; G1, G2: Single; Overlap48, FrameSize, Channels: Integer;
  Window: PSingle; Fs: Integer);
var
  I, C, Inc_, Overlap: Integer;
  G, W: Single;
begin
  Inc_ := 48000 div Fs;
  Overlap := Overlap48 div Inc_;
  if Channels = 1 then
    for I := 0 to Overlap - 1 do
    begin
      W := Window[I * Inc_] * Window[I * Inc_];
      G := W * G2 + (F_ONE - W) * G1;
      OutP[I] := G * InP[I];
    end
  else
    for I := 0 to Overlap - 1 do
    begin
      W := Window[I * Inc_] * Window[I * Inc_];
      G := W * G2 + (F_ONE - W) * G1;
      OutP[I * 2] := G * InP[I * 2];
      OutP[I * 2 + 1] := G * InP[I * 2 + 1];
    end;
  for C := 0 to Channels - 1 do
    for I := Overlap to FrameSize - 1 do
      OutP[I * Channels + C] := G2 * InP[I * Channels + C];
end;

function ComputeEquivRate(Bitrate, Channels, FrameRate: Integer; Vbr: Boolean;
  Mode, Complexity, Loss: Integer): Integer;
var
  Equiv: Integer;
begin
  Equiv := Bitrate;
  if FrameRate > 50 then
    Equiv := Equiv - (40 * Channels + 20) * (FrameRate - 50);
  if not Vbr then
    Equiv := Equiv - Equiv div 12;
  Equiv := Equiv * (90 + Complexity) div 100;
  if (Mode = MODE_SILK_ONLY) or (Mode = MODE_HYBRID) then
  begin
    if Complexity < 2 then
      Equiv := Equiv * 4 div 5;
    Equiv := Equiv - Equiv * Loss div (6 * Loss + 10);
  end
  else if Mode = MODE_CELT_ONLY then
  begin
    if Complexity < 5 then
      Equiv := Equiv * 9 div 10;
  end
  else
    Equiv := Equiv - Equiv * Loss div (12 * Loss + 20);
  Result := Equiv;
end;

function IsDigitalSilence(Pcm: PSingle; FrameSize, Channels, LsbDepth: Integer): Boolean;
var
  SampleMax, Thresh: Single;
begin
  SampleMax := CeltMaxAbs(Pcm, FrameSize * Channels);
  Thresh := F_ONE / (1 shl LsbDepth);
  Result := SampleMax <= Thresh;
end;

function DecideDtxMode(Activity: Integer; var NbNoActivityMsQ1: Integer; FrameSizeMsQ1: Integer): Boolean;
begin
  if Activity = 0 then
  begin
    Inc(NbNoActivityMsQ1, FrameSizeMsQ1);
    if NbNoActivityMsQ1 > NB_SPEECH_FRAMES_BEFORE_DTX * 20 * 2 then
    begin
      if NbNoActivityMsQ1 <= (NB_SPEECH_FRAMES_BEFORE_DTX + MAX_CONSECUTIVE_DTX) * 20 * 2 then
        Exit(True)
      else
        NbNoActivityMsQ1 := NB_SPEECH_FRAMES_BEFORE_DTX * 20 * 2;
    end;
  end
  else
    NbNoActivityMsQ1 := 0;
  Result := False;
end;

function ComputeFrameEnergy(Pcm: PSingle; FrameSize, Channels: Integer): Single;
var
  Len: Integer;
begin
  Len := FrameSize * Channels;
  Result := CeltInnerProd(Pcm, Pcm, Len) / Len;
end;

function DecideFec(UseInBandFEC, PacketLossPerc, LastFec, Mode: Integer; var Bandwidth: Integer;
  Rate: Integer): Integer;
var
  OrigBandwidth, Hysteresis, LBRRRateThresBps: Integer;
begin
  if (UseInBandFEC = 0) or (PacketLossPerc = 0) or (Mode = MODE_CELT_ONLY) then
    Exit(0);
  OrigBandwidth := Bandwidth;
  while True do
  begin
    LBRRRateThresBps := FEC_THRESHOLDS[2 * (Bandwidth - OPUS_BANDWIDTH_NARROWBAND)];
    Hysteresis := FEC_THRESHOLDS[2 * (Bandwidth - OPUS_BANDWIDTH_NARROWBAND) + 1];
    if LastFec = 1 then LBRRRateThresBps := LBRRRateThresBps - Hysteresis;
    if LastFec = 0 then LBRRRateThresBps := LBRRRateThresBps + Hysteresis;
    LBRRRateThresBps := SilkSMULWB(LBRRRateThresBps * (125 - Min(PacketLossPerc, 25)), 655);
    if Rate > LBRRRateThresBps then
      Exit(1)
    else if PacketLossPerc <= 5 then
      Exit(0)
    else if Bandwidth > OPUS_BANDWIDTH_NARROWBAND then
      Dec(Bandwidth)
    else
      Break;
  end;
  Bandwidth := OrigBandwidth;
  Result := 0;
end;

function ComputeSilkRateForHybrid(Rate, Bandwidth: Integer; Frame20ms, Vbr: Boolean;
  Fec, Channels: Integer): Integer;
var
  Entry, I, N, Lo, Hi, X0, X1: Integer;
begin
  Rate := Rate div Channels;
  Entry := 1 + Ord(Frame20ms) + 2 * Fec;
  N := Length(HYBRID_RATE_TABLE);
  I := 1;
  while I < N do
  begin
    if HYBRID_RATE_TABLE[I, 0] > Rate then Break;
    Inc(I);
  end;
  if I = N then
  begin
    Result := HYBRID_RATE_TABLE[I - 1, Entry];
    Result := Result + (Rate - HYBRID_RATE_TABLE[I - 1, 0]) div 2;
  end
  else
  begin
    Lo := HYBRID_RATE_TABLE[I - 1, Entry];
    Hi := HYBRID_RATE_TABLE[I, Entry];
    X0 := HYBRID_RATE_TABLE[I - 1, 0];
    X1 := HYBRID_RATE_TABLE[I, 0];
    Result := (Lo * (X1 - Rate) + Hi * (Rate - X0)) div (X1 - X0);
  end;
  if not Vbr then
    Result := Result + 100;
  if Bandwidth = OPUS_BANDWIDTH_SUPERWIDEBAND then
    Result := Result + 300;
  Result := Result * Channels;
  if (Channels = 2) and (Rate >= 12000) then
    Result := Result - 1000;
end;

function ComputeRedundancyBytes(MaxDataBytes, BitrateBps, FrameRate, Channels: Integer): Integer;
var
  RedundancyBytesCap, RedundancyRate, BaseBits, AvailableBits: Integer;
begin
  BaseBits := 40 * Channels + 20;
  RedundancyRate := BitrateBps + BaseBits * (200 - FrameRate);
  RedundancyRate := 3 * RedundancyRate div 2;
  Result := RedundancyRate div 1600;
  AvailableBits := MaxDataBytes * 8 - 2 * BaseBits;
  RedundancyBytesCap := (AvailableBits * 240 div (240 + 48000 div FrameRate) + BaseBits) div 8;
  Result := Min(Result, RedundancyBytesCap);
  if Result > 4 + 8 * Channels then
    Result := Min(257, Result)
  else
    Result := 0;
end;

function Float2Int16(X: Single): SmallInt;
const
  SCALE: Single = 32768.0;
  LO: Single = -32768.0;
  HI: Single = 32767.0;
begin
  X := X * SCALE;
  if X < LO then X := LO;
  if X > HI then X := HI;
  Result := SmallInt(Round(X));
end;

function OpusFrameSizeSelect(FrameSize, VariableDuration, Fs: Integer): Integer;
var
  NewSize: Integer;
begin
  if FrameSize < Fs div 400 then Exit(-1);
  if VariableDuration = OPUS_FRAMESIZE_ARG then
    NewSize := FrameSize
  else if (VariableDuration >= OPUS_FRAMESIZE_2_5_MS) and (VariableDuration <= OPUS_FRAMESIZE_120_MS) then
  begin
    if VariableDuration <= OPUS_FRAMESIZE_40_MS then
      NewSize := (Fs div 400) shl (VariableDuration - OPUS_FRAMESIZE_2_5_MS)
    else
      NewSize := (VariableDuration - OPUS_FRAMESIZE_2_5_MS - 2) * Fs div 50;
  end
  else
    Exit(-1);
  if NewSize > FrameSize then Exit(-1);
  if (400 * NewSize <> Fs) and (200 * NewSize <> Fs) and (100 * NewSize <> Fs) and
     (50 * NewSize <> Fs) and (25 * NewSize <> Fs) and (50 * NewSize <> 3 * Fs) and
     (50 * NewSize <> 4 * Fs) and (50 * NewSize <> 5 * Fs) and (50 * NewSize <> 6 * Fs) then
    Exit(-1);
  Result := NewSize;
end;

// ---------------------------------------------------------------------------
// TOpusEncoder
// ---------------------------------------------------------------------------

constructor TOpusEncoder.Create(SampleRate, Channels: Integer; Application: TOpusApplication);
begin
  Create(SampleRate, Channels, OpusApplicationValue(Application));
end;

constructor TOpusEncoder.Create(SampleRate, Channels, Application: Integer);
begin
  inherited Create;
  if ((SampleRate <> 48000) and (SampleRate <> 24000) and (SampleRate <> 16000) and
      (SampleRate <> 12000) and (SampleRate <> 8000)) or ((Channels <> 1) and (Channels <> 2)) or
     ((Application <> OPUS_APPLICATION_VOIP) and (Application <> OPUS_APPLICATION_AUDIO) and
      (Application <> OPUS_APPLICATION_RESTRICTED_LOWDELAY)) then
    raise EArgumentException.Create('TOpusEncoder: invalid sample rate, channels or application');
  FChannels := Channels;
  FStreamChannels := Channels;
  FFs := SampleRate;

  New(FSilk);
  if SilkInitEncoder(FSilk^, FSilkMode) <> 0 then
    raise EArgumentException.Create('TOpusEncoder: SILK init failed');
  FSilkMode.NChannelsAPI := Channels;
  FSilkMode.NChannelsInternal := Channels;
  FSilkMode.APISampleRate := FFs;
  FSilkMode.MaxInternalSampleRate := 16000;
  FSilkMode.MinInternalSampleRate := 8000;
  FSilkMode.DesiredInternalSampleRate := 16000;
  FSilkMode.PayloadSizeMs := 20;
  FSilkMode.BitRate := 25000;
  FSilkMode.PacketLossPercentage := 0;
  FSilkMode.Complexity := 9;
  FSilkMode.UseInBandFEC := 0;
  FSilkMode.UseDRED := 0;
  FSilkMode.UseDTX := 0;
  FSilkMode.UseCBR := 0;
  FSilkMode.ReducedDependency := 0;

  FCelt := TCeltEncoder.Create(FFs, Channels);
  FCelt.Complexity := FSilkMode.Complexity;

  FUseVbr := True;
  FVbrConstraint := True;
  FUserBitrateBps := OPUS_AUTO;
  FBitrateBps := 3000 + FFs * Channels;
  FApplication := Application;
  FSignalType := OPUS_AUTO;
  FUserBandwidth := OPUS_AUTO;
  FMaxBandwidth := OPUS_BANDWIDTH_FULLBAND;
  FForceChannels := OPUS_AUTO;
  FUserForcedMode := OPUS_AUTO;
  FVoiceRatio := -1;
  FEncoderBuffer := FFs div 100;
  FLsbDepth := 24;
  FVariableDuration := OPUS_FRAMESIZE_ARG;
  FDelayCompensation := FFs div 250;
  TonalityAnalysisInit(FAnalysis, FFs);
  FAnalysis.Application := FApplication;
  ResetState;
end;

destructor TOpusEncoder.Destroy;
begin
  FCelt.Free;
  Dispose(FSilk);
  inherited;
end;

procedure TOpusEncoder.ResetState;
begin
  FStreamChannels := FChannels;
  FHybridStereoWidthQ14 := 1 shl 14;
  FVariableHPSmth2Q15 := SilkLin2Log(VARIABLE_HP_MIN_CUTOFF_HZ) shl 8;
  FPrevHBGain := 1.0;
  FillChar(FHpMem, SizeOf(FHpMem), 0);
  FMode := MODE_HYBRID;
  FPrevMode := 0;
  FPrevChannels := 0;
  FPrevFramesize := 0;
  FBandwidth := OPUS_BANDWIDTH_FULLBAND;
  FAutoBandwidth := 0;
  FSilkBwSwitch := 0;
  FFirst := True;
  FWidthXX := 0; FWidthXY := 0; FWidthYY := 0;
  FSmoothedWidth := 0;
  FMaxFollower := 0;
  FillChar(FDelayBuffer, SizeOf(FDelayBuffer), 0);
  FDetectedBandwidth := 0;
  FNbNoActivityMsQ1 := 0;
  FPeakSignalEnergy := 0;
  FNonfinalFrame := False;
  FRangeFinal := 0;
  TonalityAnalysisReset(FAnalysis);
end;

procedure TOpusEncoder.Reset;
var
  Dummy: TSilkEncControl;
begin
  ResetState;
  FCelt.Reset;
  SilkInitEncoder(FSilk^, Dummy);
end;

function TOpusEncoder.UserBitrateToBitrate(FrameSize, MaxDataBytes: Integer): Integer;
begin
  if FrameSize = 0 then FrameSize := FFs div 400;
  if FUserBitrateBps = OPUS_AUTO then
    Result := 60 * FFs div FrameSize + FFs * FChannels
  else if FUserBitrateBps = OPUS_BITRATE_MAX then
    Result := MaxDataBytes * 8 * FFs div FrameSize
  else
    Result := FUserBitrateBps;
end;

function TOpusEncoder.ComputeStereoWidth(Pcm: PSingle; FrameSize: Integer): Single;
const
  K1E9: Single = 1e9;
  K8E4: Single = 8e-4;
  K002: Single = 0.02;
var
  I, FrameRate: Integer;
  Xx, Xy, Yy, Pxx, Pxy, Pyy, X, Y, ShortAlpha: Single;
  SqrtXX, SqrtYY, QrrtXX, QrrtYY, Corr, LDiff, Width: Single;
begin
  FrameRate := FFs div FrameSize;
  ShortAlpha := F_ONE - Single(25) / Max(50, FrameRate);
  Xx := 0; Xy := 0; Yy := 0;
  I := 0;
  while I < FrameSize - 3 do
  begin
    X := Pcm[2 * I];     Y := Pcm[2 * I + 1];
    Pxx := X * X; Pxy := X * Y; Pyy := Y * Y;
    X := Pcm[2 * I + 2]; Y := Pcm[2 * I + 3];
    Pxx := Pxx + X * X; Pxy := Pxy + X * Y; Pyy := Pyy + Y * Y;
    X := Pcm[2 * I + 4]; Y := Pcm[2 * I + 5];
    Pxx := Pxx + X * X; Pxy := Pxy + X * Y; Pyy := Pyy + Y * Y;
    X := Pcm[2 * I + 6]; Y := Pcm[2 * I + 7];
    Pxx := Pxx + X * X; Pxy := Pxy + X * Y; Pyy := Pyy + Y * Y;
    Xx := Xx + Pxx;
    Xy := Xy + Pxy;
    Yy := Yy + Pyy;
    Inc(I, 4);
  end;
  if (not (Xx < K1E9)) or IsNan(Xx) or (not (Yy < K1E9)) or IsNan(Yy) then
  begin
    Xx := 0; Xy := 0; Yy := 0;
  end;
  FWidthXX := FWidthXX + ShortAlpha * (Xx - FWidthXX);
  FWidthXY := FWidthXY + ShortAlpha * (Xy - FWidthXY);
  FWidthYY := FWidthYY + ShortAlpha * (Yy - FWidthYY);
  if 0 > FWidthXX then FWidthXX := 0;
  if 0 > FWidthXY then FWidthXY := 0;
  if 0 > FWidthYY then FWidthYY := 0;
  if Max(FWidthXX, FWidthYY) > K8E4 then
  begin
    SqrtXX := SqrtF(FWidthXX);
    SqrtYY := SqrtF(FWidthYY);
    QrrtXX := SqrtF(SqrtXX);
    QrrtYY := SqrtF(SqrtYY);
    FWidthXY := Min(FWidthXY, SqrtXX * SqrtYY);
    Corr := FWidthXY / (F_EPSILON + SqrtXX * SqrtYY);
    LDiff := (F_ONE * Abs(QrrtXX - QrrtYY)) / (F_EPSILON + QrrtXX + QrrtYY);
    Width := SqrtF(F_ONE - Corr * Corr) * LDiff;
    FSmoothedWidth := FSmoothedWidth + (Width - FSmoothedWidth) / FrameRate;
    FMaxFollower := Max(FMaxFollower - K002 / FrameRate, FSmoothedWidth);
  end;
  Result := Min(F_ONE, 20 * FMaxFollower);
end;

function TOpusEncoder.Encode(Pcm: System.PSmallInt; FrameSize: Integer; Data: PByte; MaxDataBytes: Integer): Integer;
var
  InBuf: array of Single;
  I, AnalysisFrameSize: Integer;
begin
  AnalysisFrameSize := FrameSize;
  FrameSize := OpusFrameSizeSelect(FrameSize, FVariableDuration, FFs);
  if FrameSize <= 0 then Exit(OPUS_BAD_ARG);
  if (Pcm = nil) or (Data = nil) then Exit(OPUS_BAD_ARG);
  // the analysis reads the whole analysis_frame_size (downmix_int); x/32768
  // is exact, so the same buffer serves both paths
  SetLength(InBuf, AnalysisFrameSize * FChannels);
  for I := 0 to AnalysisFrameSize * FChannels - 1 do
    InBuf[I] := INV32768 * Pcm[I];
  Result := EncodeNative(@InBuf[0], FrameSize, Data, MaxDataBytes, 16, False, @InBuf[0], AnalysisFrameSize);
end;

function TOpusEncoder.EncodeFloat(Pcm: PSingle; FrameSize: Integer; Data: PByte; MaxDataBytes: Integer): Integer;
var
  AnalysisFrameSize: Integer;
begin
  AnalysisFrameSize := FrameSize;
  FrameSize := OpusFrameSizeSelect(FrameSize, FVariableDuration, FFs);
  if FrameSize <= 0 then Exit(OPUS_BAD_ARG);
  if (Pcm = nil) or (Data = nil) then Exit(OPUS_BAD_ARG);
  Result := EncodeNative(Pcm, FrameSize, Data, MaxDataBytes, 24, True, Pcm, AnalysisFrameSize);
end;

function TOpusEncoder.EncodeNative(Pcm: PSingle; FrameSize: Integer; Data: PByte;
  OutDataBytes, LsbDepth: Integer; FloatApi: Boolean; AnalysisPcm: PSingle;
  AnalysisSize: Integer): Integer;
const
  K0999: Single = 0.999;
var
  I, Ret, VoiceEst, EquivRate, FrameRate, MaxRate, CurrBandwidth, MaxDataBytes, CbrBytes: Integer;
  FrameRate12, TocMode, Bw, PacketCode, NumMultiframes, StereoThreshold: Integer;
  ModeVoice, ModeMusic, Threshold, Hysteresis, BandwidthVal: Integer;
  BandwidthThresholds: array[0..7] of Integer;
  VoiceThr, MusicThr: PInteger;
  StereoWidth: Single;
  Redundancy, CeltToSilk, ToCelt, IsSilence: Boolean;
  Prefill: Integer;
  AnalysisInfo: TAnalysisInfo;
  EncFrameSize, NbFrames, MaxHeaderBytes, RepacketizeLen, MaxLenSum, TotSize, TmpLen,
  DtxCount, CurrMax: Integer;
  TmpData: array of Byte;
  CurrData: PByte;
  Rp: TOpusRepacketizer;
  BakToMono: Integer;
  FirstFrame, FrameToCelt, FrameRedundancy: Boolean;
  DummySilk: TSilkEncControl;
  AnalysisReadPosBak, AnalysisReadSubframeBak, AnalysisBandwidth, MinDetectedBandwidth: Integer;
  Prob, E: Single;
begin
  AnalysisReadPosBak := -1;
  AnalysisReadSubframeBak := -1;
  MaxDataBytes := Min(OPUS_MAX_PACKET_BYTES, OutDataBytes);
  FRangeFinal := 0;
  CbrBytes := -1;
  Redundancy := False;
  CeltToSilk := False;
  ToCelt := False;
  Prefill := 0;
  if (FrameSize <= 0) or (MaxDataBytes <= 0) then
    Exit(OPUS_BAD_ARG);
  if (MaxDataBytes = 1) and (FFs = FrameSize * 10) then
    Exit(OPUS_BUFFER_TOO_SMALL);

  LsbDepth := Min(LsbDepth, FLsbDepth);

  FillChar(AnalysisInfo, SizeOf(AnalysisInfo), 0);
  AnalysisInfo.Valid := False;
  IsSilence := False;
  if (FSilkMode.Complexity >= 7) and (FFs >= 16000) then
  begin
    IsSilence := IsDigitalSilence(Pcm, FrameSize, FChannels, LsbDepth);
    AnalysisReadPosBak := FAnalysis.ReadPos;
    AnalysisReadSubframeBak := FAnalysis.ReadSubframe;
    RunAnalysis(FAnalysis, AnalysisPcm, AnalysisSize, FrameSize, FChannels, FFs, LsbDepth, AnalysisInfo);
    // track the peak signal energy
    if (not IsSilence) and (AnalysisInfo.ActivityProbability > DTX_ACTIVITY_THRESHOLD) then
    begin
      E := ComputeFrameEnergy(Pcm, FrameSize, FChannels);
      FPeakSignalEnergy := Max(K0999 * FPeakSignalEnergy, E);
    end;
  end
  else if FAnalysis.Initialized then
    TonalityAnalysisReset(FAnalysis);

  if not IsSilence then
    FVoiceRatio := -1;
  FDetectedBandwidth := 0;
  if AnalysisInfo.Valid then
  begin
    if FSignalType = OPUS_AUTO then
    begin
      if FPrevMode = 0 then
        Prob := AnalysisInfo.MusicProb
      else if FPrevMode = MODE_CELT_ONLY then
        Prob := AnalysisInfo.MusicProbMax
      else
        Prob := AnalysisInfo.MusicProbMin;
      FVoiceRatio := Floor(0.5 + 100 * (1 - Prob));
    end;
    AnalysisBandwidth := AnalysisInfo.Bandwidth;
    if AnalysisBandwidth <= 12 then
      FDetectedBandwidth := OPUS_BANDWIDTH_NARROWBAND
    else if AnalysisBandwidth <= 14 then
      FDetectedBandwidth := OPUS_BANDWIDTH_MEDIUMBAND
    else if AnalysisBandwidth <= 16 then
      FDetectedBandwidth := OPUS_BANDWIDTH_WIDEBAND
    else if AnalysisBandwidth <= 18 then
      FDetectedBandwidth := OPUS_BANDWIDTH_SUPERWIDEBAND
    else
      FDetectedBandwidth := OPUS_BANDWIDTH_FULLBAND;
  end;

  if (FChannels = 2) and (FForceChannels <> 1) then
    StereoWidth := ComputeStereoWidth(Pcm, FrameSize)
  else
    StereoWidth := 0;
  FBitrateBps := UserBitrateToBitrate(FrameSize, MaxDataBytes);

  FrameRate := FFs div FrameSize;
  if not FUseVbr then
  begin
    FrameRate12 := 12 * FFs div FrameSize;
    CbrBytes := Min((12 * FBitrateBps div 8 + FrameRate12 div 2) div FrameRate12, MaxDataBytes);
    FBitrateBps := CbrBytes * FrameRate12 * 8 div 12;
    MaxDataBytes := Max(1, CbrBytes);
  end;
  if (MaxDataBytes < 3) or (FBitrateBps < 3 * FrameRate * 8) or
     ((FrameRate < 50) and ((MaxDataBytes * FrameRate < 300) or (FBitrateBps < 2400))) then
  begin
    // If the space is too low to do something useful, emit 'PLC' frames.
    TocMode := FMode;
    if FBandwidth = 0 then Bw := OPUS_BANDWIDTH_NARROWBAND else Bw := FBandwidth;
    PacketCode := 0;
    NumMultiframes := 0;
    if TocMode = 0 then
      TocMode := MODE_SILK_ONLY;
    if FrameRate > 100 then
      TocMode := MODE_CELT_ONLY;
    if (FrameRate = 25) and (TocMode <> MODE_SILK_ONLY) then
    begin
      FrameRate := 50;
      PacketCode := 1;
    end;
    if FrameRate <= 16 then
    begin
      if (OutDataBytes = 1) or ((TocMode = MODE_SILK_ONLY) and (FrameRate <> 10)) then
      begin
        TocMode := MODE_SILK_ONLY;
        PacketCode := Ord(FrameRate <= 12);
        if FrameRate = 12 then FrameRate := 25 else FrameRate := 16;
      end
      else
      begin
        NumMultiframes := 50 div FrameRate;
        FrameRate := 50;
        PacketCode := 3;
      end;
    end;
    if (TocMode = MODE_SILK_ONLY) and (Bw > OPUS_BANDWIDTH_WIDEBAND) then
      Bw := OPUS_BANDWIDTH_WIDEBAND
    else if (TocMode = MODE_CELT_ONLY) and (Bw = OPUS_BANDWIDTH_MEDIUMBAND) then
      Bw := OPUS_BANDWIDTH_NARROWBAND
    else if (TocMode = MODE_HYBRID) and (Bw <= OPUS_BANDWIDTH_SUPERWIDEBAND) then
      Bw := OPUS_BANDWIDTH_SUPERWIDEBAND;
    Data[0] := GenToc(TocMode, FrameRate, Bw, FStreamChannels);
    Data[0] := Data[0] or PacketCode;
    if PacketCode <= 1 then Ret := 1 else Ret := 2;
    MaxDataBytes := Max(MaxDataBytes, Ret);
    if PacketCode = 3 then
      Data[1] := NumMultiframes;
    if not FUseVbr then
    begin
      Ret := OpusPacketPad(Data, Ret, MaxDataBytes);
      if Ret = OPUS_OK then Ret := MaxDataBytes
      else Ret := OPUS_INTERNAL_ERROR;
    end;
    Exit(Ret);
  end;
  MaxRate := FrameRate * MaxDataBytes * 8;

  // Equivalent 20-ms rate for mode/channel/bandwidth decisions
  EquivRate := ComputeEquivRate(FBitrateBps, FChannels, FFs div FrameSize, FUseVbr, 0,
    FSilkMode.Complexity, FSilkMode.PacketLossPercentage);

  if FSignalType = OPUS_SIGNAL_VOICE then
    VoiceEst := 127
  else if FSignalType = OPUS_SIGNAL_MUSIC then
    VoiceEst := 0
  else if FVoiceRatio >= 0 then
  begin
    VoiceEst := FVoiceRatio * 327 shr 8;
    if FApplication = OPUS_APPLICATION_AUDIO then
      VoiceEst := Min(VoiceEst, 115);
  end
  else if FApplication = OPUS_APPLICATION_VOIP then
    VoiceEst := 115
  else
    VoiceEst := 48;

  if (FForceChannels <> OPUS_AUTO) and (FChannels = 2) then
    FStreamChannels := FForceChannels
  else
  begin
    if FChannels = 2 then
    begin
      StereoThreshold := STEREO_MUSIC_THRESHOLD +
        ((VoiceEst * VoiceEst * (STEREO_VOICE_THRESHOLD - STEREO_MUSIC_THRESHOLD)) shr 14);
      if FStreamChannels = 2 then
        StereoThreshold := StereoThreshold - 1000
      else
        StereoThreshold := StereoThreshold + 1000;
      if EquivRate > StereoThreshold then FStreamChannels := 2 else FStreamChannels := 1;
    end
    else
      FStreamChannels := FChannels;
  end;
  EquivRate := ComputeEquivRate(FBitrateBps, FStreamChannels, FFs div FrameSize, FUseVbr, 0,
    FSilkMode.Complexity, FSilkMode.PacketLossPercentage);

  FSilkMode.UseDTX := Ord(FUseDtx and not (AnalysisInfo.Valid or IsSilence));

  // Mode selection depending on application and signal type
  if FApplication = OPUS_APPLICATION_RESTRICTED_LOWDELAY then
    FMode := MODE_CELT_ONLY
  else if FUserForcedMode = OPUS_AUTO then
  begin
    ModeVoice := Trunc((F_ONE - StereoWidth) * MODE_THRESHOLDS[0][0] + StereoWidth * MODE_THRESHOLDS[1][0]);
    ModeMusic := Trunc((F_ONE - StereoWidth) * MODE_THRESHOLDS[1][1] + StereoWidth * MODE_THRESHOLDS[1][1]);
    Threshold := ModeMusic + ((VoiceEst * VoiceEst * (ModeVoice - ModeMusic)) shr 14);
    if FApplication = OPUS_APPLICATION_VOIP then
      Threshold := Threshold + 8000;
    if FPrevMode = MODE_CELT_ONLY then
      Threshold := Threshold - 4000
    else if FPrevMode > 0 then
      Threshold := Threshold + 4000;
    if EquivRate >= Threshold then FMode := MODE_CELT_ONLY else FMode := MODE_SILK_ONLY;
    if (FSilkMode.UseInBandFEC <> 0) and (FSilkMode.PacketLossPercentage > (128 - VoiceEst) shr 4) and
       ((FFecConfig <> 2) or (VoiceEst > 25)) then
      FMode := MODE_SILK_ONLY;
    if (FSilkMode.UseDTX <> 0) and (VoiceEst > 100) then
      FMode := MODE_SILK_ONLY;
    if FrameRate > 50 then I := 9000 else I := 6000;
    if MaxDataBytes < I * FrameSize div (FFs * 8) then
      FMode := MODE_CELT_ONLY;
  end
  else
    FMode := FUserForcedMode;

  if (FMode <> MODE_CELT_ONLY) and (FrameSize < FFs div 100) then
    FMode := MODE_CELT_ONLY;
  if FLfe then
    FMode := MODE_CELT_ONLY;

  if (FPrevMode > 0) and
     (((FMode <> MODE_CELT_ONLY) and (FPrevMode = MODE_CELT_ONLY)) or
      ((FMode = MODE_CELT_ONLY) and (FPrevMode <> MODE_CELT_ONLY))) then
  begin
    Redundancy := True;
    CeltToSilk := FMode <> MODE_CELT_ONLY;
    if not CeltToSilk then
    begin
      if FrameSize >= FFs div 100 then
      begin
        FMode := FPrevMode;
        ToCelt := True;
      end
      else
        Redundancy := False;
    end;
  end;

  if (FStreamChannels = 1) and (FPrevChannels = 2) and (FSilkMode.ToMono = 0) and
     (FMode <> MODE_CELT_ONLY) and (FPrevMode <> MODE_CELT_ONLY) then
  begin
    FSilkMode.ToMono := 1;
    FStreamChannels := 2;
  end
  else
    FSilkMode.ToMono := 0;

  EquivRate := ComputeEquivRate(FBitrateBps, FStreamChannels, FFs div FrameSize, FUseVbr, FMode,
    FSilkMode.Complexity, FSilkMode.PacketLossPercentage);

  if (FMode <> MODE_CELT_ONLY) and (FPrevMode = MODE_CELT_ONLY) then
  begin
    SilkInitEncoder(FSilk^, DummySilk);
    Prefill := 1;
  end;

  // Automatic (rate-dependent) bandwidth selection
  if (FMode = MODE_CELT_ONLY) or FFirst or (FSilkMode.AllowBandwidthSwitch <> 0) then
  begin
    BandwidthVal := OPUS_BANDWIDTH_FULLBAND;
    if (FChannels = 2) and (FForceChannels <> 1) then
    begin
      VoiceThr := @STEREO_VOICE_BANDWIDTH_THRESHOLDS[0];
      MusicThr := @STEREO_MUSIC_BANDWIDTH_THRESHOLDS[0];
    end
    else
    begin
      VoiceThr := @MONO_VOICE_BANDWIDTH_THRESHOLDS[0];
      MusicThr := @MONO_MUSIC_BANDWIDTH_THRESHOLDS[0];
    end;
    for I := 0 to 7 do
      BandwidthThresholds[I] := MusicThr[I] +
        ((VoiceEst * VoiceEst * (VoiceThr[I] - MusicThr[I])) shr 14);
    repeat
      Threshold := BandwidthThresholds[2 * (BandwidthVal - OPUS_BANDWIDTH_MEDIUMBAND)];
      Hysteresis := BandwidthThresholds[2 * (BandwidthVal - OPUS_BANDWIDTH_MEDIUMBAND) + 1];
      if not FFirst then
      begin
        if FAutoBandwidth >= BandwidthVal then
          Threshold := Threshold - Hysteresis
        else
          Threshold := Threshold + Hysteresis;
      end;
      if EquivRate >= Threshold then
        Break;
      Dec(BandwidthVal);
    until BandwidthVal <= OPUS_BANDWIDTH_NARROWBAND;
    if BandwidthVal = OPUS_BANDWIDTH_MEDIUMBAND then
      BandwidthVal := OPUS_BANDWIDTH_WIDEBAND;
    FBandwidth := BandwidthVal;
    FAutoBandwidth := BandwidthVal;
    if (not FFirst) and (FMode <> MODE_CELT_ONLY) and (FSilkMode.InWBmodeWithoutVariableLP = 0) and
       (FBandwidth > OPUS_BANDWIDTH_WIDEBAND) then
      FBandwidth := OPUS_BANDWIDTH_WIDEBAND;
  end;

  if FBandwidth > FMaxBandwidth then
    FBandwidth := FMaxBandwidth;
  if FUserBandwidth <> OPUS_AUTO then
    FBandwidth := FUserBandwidth;
  if (FMode <> MODE_CELT_ONLY) and (MaxRate < 15000) then
    FBandwidth := Min(FBandwidth, OPUS_BANDWIDTH_WIDEBAND);

  if (FFs <= 24000) and (FBandwidth > OPUS_BANDWIDTH_SUPERWIDEBAND) then
    FBandwidth := OPUS_BANDWIDTH_SUPERWIDEBAND;
  if (FFs <= 16000) and (FBandwidth > OPUS_BANDWIDTH_WIDEBAND) then
    FBandwidth := OPUS_BANDWIDTH_WIDEBAND;
  if (FFs <= 12000) and (FBandwidth > OPUS_BANDWIDTH_MEDIUMBAND) then
    FBandwidth := OPUS_BANDWIDTH_MEDIUMBAND;
  if (FFs <= 8000) and (FBandwidth > OPUS_BANDWIDTH_NARROWBAND) then
    FBandwidth := OPUS_BANDWIDTH_NARROWBAND;
  // use detected bandwidth to reduce the encoded bandwidth
  if (FDetectedBandwidth <> 0) and (FUserBandwidth = OPUS_AUTO) then
  begin
    if (EquivRate <= 18000 * FStreamChannels) and (FMode = MODE_CELT_ONLY) then
      MinDetectedBandwidth := OPUS_BANDWIDTH_NARROWBAND
    else if (EquivRate <= 24000 * FStreamChannels) and (FMode = MODE_CELT_ONLY) then
      MinDetectedBandwidth := OPUS_BANDWIDTH_MEDIUMBAND
    else if EquivRate <= 30000 * FStreamChannels then
      MinDetectedBandwidth := OPUS_BANDWIDTH_WIDEBAND
    else if EquivRate <= 44000 * FStreamChannels then
      MinDetectedBandwidth := OPUS_BANDWIDTH_SUPERWIDEBAND
    else
      MinDetectedBandwidth := OPUS_BANDWIDTH_FULLBAND;
    FDetectedBandwidth := Max(FDetectedBandwidth, MinDetectedBandwidth);
    FBandwidth := Min(FBandwidth, FDetectedBandwidth);
  end;

  FSilkMode.LBRRCoded := DecideFec(FSilkMode.UseInBandFEC, FSilkMode.PacketLossPercentage,
    FSilkMode.LBRRCoded, FMode, FBandwidth, EquivRate);
  FCelt.LsbDepth := LsbDepth;

  if (FMode = MODE_CELT_ONLY) and (FBandwidth = OPUS_BANDWIDTH_MEDIUMBAND) then
    FBandwidth := OPUS_BANDWIDTH_WIDEBAND;
  if FLfe then
    FBandwidth := OPUS_BANDWIDTH_NARROWBAND;

  CurrBandwidth := FBandwidth;

  if (FMode = MODE_SILK_ONLY) and (CurrBandwidth > OPUS_BANDWIDTH_WIDEBAND) then
    FMode := MODE_HYBRID;
  if (FMode = MODE_HYBRID) and (CurrBandwidth <= OPUS_BANDWIDTH_WIDEBAND) then
    FMode := MODE_SILK_ONLY;

  // Can't support higher than >60 ms frames, and >20 ms when in Hybrid or CELT-only modes
  if ((FrameSize > FFs div 50) and (FMode <> MODE_SILK_ONLY)) or (FrameSize > 3 * FFs div 50) then
  begin
    if FMode = MODE_SILK_ONLY then
    begin
      if FrameSize = 2 * FFs div 25 then EncFrameSize := FFs div 25
      else if FrameSize = 3 * FFs div 25 then EncFrameSize := 3 * FFs div 50
      else EncFrameSize := FFs div 50;
    end
    else
      EncFrameSize := FFs div 50;
    NbFrames := FrameSize div EncFrameSize;
    if AnalysisReadPosBak <> -1 then
    begin
      // reset the analysis position to the beginning of the first frame
      FAnalysis.ReadPos := AnalysisReadPosBak;
      FAnalysis.ReadSubframe := AnalysisReadSubframeBak;
    end;
    if NbFrames = 2 then MaxHeaderBytes := 3 else MaxHeaderBytes := 2 + (NbFrames - 1) * 2;
    if FUseVbr or (FUserBitrateBps = OPUS_BITRATE_MAX) then
      RepacketizeLen := OutDataBytes
    else
      RepacketizeLen := Min(CbrBytes, OutDataBytes);
    MaxLenSum := NbFrames + RepacketizeLen - MaxHeaderBytes;
    SetLength(TmpData, Max(1, MaxLenSum));
    CurrData := @TmpData[0];
    Rp.Init;
    TotSize := 0;
    DtxCount := 0;

    BakToMono := FSilkMode.ToMono;
    if BakToMono <> 0 then
      FForceChannels := 1
    else
      FPrevChannels := FStreamChannels;

    for I := 0 to NbFrames - 1 do
    begin
      FirstFrame := (I = 0) or (I = DtxCount);
      FSilkMode.ToMono := 0;
      FNonfinalFrame := I < NbFrames - 1;
      FrameToCelt := ToCelt and (I = NbFrames - 1);
      FrameRedundancy := Redundancy and (FrameToCelt or ((not ToCelt) and (I = 0)));
      CurrMax := Min(3 * FBitrateBps div (3 * 8 * FFs div EncFrameSize), MaxLenSum div NbFrames);
      CurrMax := Min(MaxLenSum - TotSize, CurrMax);
      if AnalysisReadPosBak <> -1 then
      begin
        IsSilence := IsDigitalSilence(Pcm, FrameSize, FChannels, LsbDepth);
        TonalityGetInfo(FAnalysis, AnalysisInfo, EncFrameSize);
      end;
      TmpLen := EncodeFrameNative(Pcm + I * (FChannels * EncFrameSize), EncFrameSize, CurrData,
        CurrMax, FloatApi, FirstFrame, AnalysisInfo, IsSilence, FrameRedundancy, CeltToSilk,
        Prefill, EquivRate, FrameToCelt);
      if TmpLen < 0 then
        Exit(OPUS_INTERNAL_ERROR)
      else if TmpLen = 1 then
        Inc(DtxCount);
      Ret := Rp.Cat(CurrData, TmpLen);
      if Ret < 0 then
        Exit(OPUS_INTERNAL_ERROR);
      TotSize := TotSize + TmpLen;
      Inc(CurrData, TmpLen);
    end;
    Ret := Rp.OutRange(0, NbFrames, Data, RepacketizeLen, (not FUseVbr) and (DtxCount <> NbFrames));
    if Ret < 0 then
      Ret := OPUS_INTERNAL_ERROR;
    FSilkMode.ToMono := BakToMono;
    Result := Ret;
  end
  else
    Result := EncodeFrameNative(Pcm, FrameSize, Data, MaxDataBytes, FloatApi, True, AnalysisInfo,
      IsSilence, Redundancy, CeltToSilk, Prefill, EquivRate, ToCelt);
end;

function TOpusEncoder.EncodeFrameNative(Pcm: PSingle; FrameSize: Integer; Data: PByte;
  MaxDataBytes: Integer; FloatApi, FirstFrame: Boolean; const AnalysisInfo: TAnalysisInfo;
  IsSilence: Boolean; Redundancy, CeltToSilk: Boolean; Prefill: Integer; EquivRate: Integer;
  ToCelt: Boolean): Integer;
const
  K1E9: Single = 1e9;
  INV1024: Single = 1.0 / 1024;
var
  I, Ret, NBytes, BytesTarget, NbComprBytes, RedundancyBytes, CutoffHz, HpFreqSmth1, FrameRate,
  CurrBandwidth, DelayCompensation, TotalBuffer, Activity, EndBand, StartBand, MaxRedundancy: Integer;
  TotalBitRate, CeltRate, EffectiveMaxRate, OtherBits, MaxBitRate, PrefillOffset, Zero, Err, N2, N4: Integer;
  RedundantRng: Cardinal;
  HBGain, G1, G2, Sum: Single;
  Enc: TEcEnc;
  PcmBuf, TmpPrefill: array of Single;
  PcmSilk: array of SmallInt;
  ApplyPadding: Boolean;
  Payload: PByte;
  Dummy: array[0..1] of Byte;
  Info: TSilkInfo;
  DummyEnc: TEcEnc;
  NoiseEnergy: Single;
begin
  FRangeFinal := 0;
  Ret := 0;
  RedundancyBytes := 0;
  RedundantRng := 0;
  StartBand := 0;
  NBytes := 0;
  CurrBandwidth := FBandwidth;
  if FApplication = OPUS_APPLICATION_RESTRICTED_LOWDELAY then
    DelayCompensation := 0
  else
    DelayCompensation := FDelayCompensation;
  TotalBuffer := DelayCompensation;
  FrameRate := FFs div FrameSize;

  Activity := VAD_NO_DECISION;
  if IsSilence then
    Activity := 0
  else if AnalysisInfo.Valid then
  begin
    Activity := Ord(AnalysisInfo.ActivityProbability >= DTX_ACTIVITY_THRESHOLD);
    if Activity = 0 then
    begin
      // mark as active if this noise frame is sufficiently loud
      NoiseEnergy := ComputeFrameEnergy(Pcm, FrameSize, FChannels);
      Activity := Ord(FPeakSignalEnergy < PSEUDO_SNR_THRESHOLD * NoiseEnergy);
    end;
  end;

  // For the first frame at a new SILK bandwidth
  if FSilkBwSwitch <> 0 then
  begin
    Redundancy := True;
    CeltToSilk := True;
    FSilkBwSwitch := 0;
    Prefill := 2;
  end;
  if FMode = MODE_CELT_ONLY then
    Redundancy := False;
  if Redundancy then
  begin
    RedundancyBytes := ComputeRedundancyBytes(MaxDataBytes, FBitrateBps, FrameRate, FStreamChannels);
    if RedundancyBytes = 0 then
      Redundancy := False;
  end;
  BytesTarget := Min(MaxDataBytes - RedundancyBytes, FBitrateBps * FrameSize div (FFs * 8)) - 1;

  Payload := Data + 1;
  EcEncInit(Enc, Payload, MaxDataBytes - 1);

  SetLength(PcmBuf, (TotalBuffer + FrameSize) * FChannels);
  if TotalBuffer > 0 then
    Move(FDelayBuffer[(FEncoderBuffer - TotalBuffer) * FChannels], PcmBuf[0],
      TotalBuffer * FChannels * SizeOf(Single));

  if FMode = MODE_CELT_ONLY then
    HpFreqSmth1 := SilkLin2Log(VARIABLE_HP_MIN_CUTOFF_HZ) shl 8
  else
    HpFreqSmth1 := FSilk.state_Fxx[0].sCmn.variable_HP_smth1_Q15;
  FVariableHPSmth2Q15 := SilkSMLAWB(FVariableHPSmth2Q15, HpFreqSmth1 - FVariableHPSmth2Q15, 983);
  CutoffHz := SilkLog2Lin(Sar32(FVariableHPSmth2Q15, 8));

  if FApplication = OPUS_APPLICATION_VOIP then
    HpCutoff(Pcm, CutoffHz, @PcmBuf[TotalBuffer * FChannels], @FHpMem[0], FrameSize, FChannels, FFs)
  else
    DcReject(Pcm, 3, @PcmBuf[TotalBuffer * FChannels], @FHpMem[0], FrameSize, FChannels, FFs);

  if FloatApi then
  begin
    Sum := CeltInnerProd(@PcmBuf[TotalBuffer * FChannels], @PcmBuf[TotalBuffer * FChannels],
      FrameSize * FChannels);
    if (not (Sum < K1E9)) or IsNan(Sum) then
    begin
      FillChar(PcmBuf[TotalBuffer * FChannels], FrameSize * FChannels * SizeOf(Single), 0);
      FillChar(FHpMem, SizeOf(FHpMem), 0);
    end;
  end;

  // SILK processing
  HBGain := 1.0;
  if FMode <> MODE_CELT_ONLY then
  begin
    SetLength(PcmSilk, FChannels * Max(FrameSize, FEncoderBuffer));
    TotalBitRate := 8 * BytesTarget * FrameRate;
    if FMode = MODE_HYBRID then
    begin
      FSilkMode.BitRate := ComputeSilkRateForHybrid(TotalBitRate, CurrBandwidth, FFs = 50 * FrameSize,
        FUseVbr, FSilkMode.LBRRCoded, FStreamChannels);
      CeltRate := TotalBitRate - FSilkMode.BitRate;
      G1 := -CeltRate * INV1024;
      HBGain := F_ONE - CeltExp2(G1);
    end
    else
      FSilkMode.BitRate := TotalBitRate;
    FSilkMode.PayloadSizeMs := 1000 * FrameSize div FFs;
    FSilkMode.NChannelsAPI := FChannels;
    FSilkMode.NChannelsInternal := FStreamChannels;
    if CurrBandwidth = OPUS_BANDWIDTH_NARROWBAND then
      FSilkMode.DesiredInternalSampleRate := 8000
    else if CurrBandwidth = OPUS_BANDWIDTH_MEDIUMBAND then
      FSilkMode.DesiredInternalSampleRate := 12000
    else
      FSilkMode.DesiredInternalSampleRate := 16000;
    if FMode = MODE_HYBRID then
      FSilkMode.MinInternalSampleRate := 16000
    else
      FSilkMode.MinInternalSampleRate := 8000;
    FSilkMode.MaxInternalSampleRate := 16000;
    if FMode = MODE_SILK_ONLY then
    begin
      EffectiveMaxRate := FrameRate * MaxDataBytes * 8;
      if FrameRate > 50 then
        EffectiveMaxRate := EffectiveMaxRate * 2 div 3;
      if EffectiveMaxRate < 8000 then
      begin
        FSilkMode.MaxInternalSampleRate := 12000;
        FSilkMode.DesiredInternalSampleRate := Min(12000, FSilkMode.DesiredInternalSampleRate);
      end;
      if EffectiveMaxRate < 7000 then
      begin
        FSilkMode.MaxInternalSampleRate := 8000;
        FSilkMode.DesiredInternalSampleRate := Min(8000, FSilkMode.DesiredInternalSampleRate);
      end;
    end;
    FSilkMode.UseCBR := Ord(not FUseVbr);
    FSilkMode.MaxBits := (MaxDataBytes - 1) * 8;
    if Redundancy and (RedundancyBytes >= 2) then
    begin
      FSilkMode.MaxBits := FSilkMode.MaxBits - (RedundancyBytes * 8 + 1);
      if FMode = MODE_HYBRID then
        FSilkMode.MaxBits := FSilkMode.MaxBits - 20;
    end;
    if FSilkMode.UseCBR <> 0 then
    begin
      if FMode = MODE_HYBRID then
      begin
        OtherBits := SmallInt(Max(0, FSilkMode.MaxBits - FSilkMode.BitRate * FrameSize div FFs));
        FSilkMode.MaxBits := Max(0, FSilkMode.MaxBits - OtherBits * 3 div 4);
        FSilkMode.UseCBR := 0;
      end;
    end
    else
    begin
      if FMode = MODE_HYBRID then
      begin
        MaxBitRate := ComputeSilkRateForHybrid(FSilkMode.MaxBits * FFs div FrameSize, CurrBandwidth,
          FFs = 50 * FrameSize, FUseVbr, FSilkMode.LBRRCoded, FStreamChannels);
        FSilkMode.MaxBits := MaxBitRate * FrameSize div FFs;
      end;
    end;
    if Prefill <> 0 then
    begin
      Zero := 0;
      PrefillOffset := FChannels * (FEncoderBuffer - FDelayCompensation - FFs div 400);
      GainFade(@FDelayBuffer[PrefillOffset], @FDelayBuffer[PrefillOffset], 0, F_ONE, CELT_OVERLAP_SIZE,
        FFs div 400, FChannels, @CELT_WINDOW120[0], FFs);
      FillChar(FDelayBuffer[0], PrefillOffset * SizeOf(Single), 0);
      for I := 0 to FEncoderBuffer * FChannels - 1 do
        PcmSilk[I] := Float2Int16(FDelayBuffer[I]);
      FillChar(DummyEnc, SizeOf(DummyEnc), 0);
      SilkEncode(FSilk^, FSilkMode, @PcmSilk[0], FEncoderBuffer, DummyEnc, Zero, Prefill, Activity);
      FSilkMode.OpusCanSwitch := 0;
    end;
    for I := 0 to FrameSize * FChannels - 1 do
      PcmSilk[I] := Float2Int16(PcmBuf[TotalBuffer * FChannels + I]);
    Ret := SilkEncode(FSilk^, FSilkMode, @PcmSilk[0], FrameSize, Enc, NBytes, 0, Activity);
    if Ret <> 0 then
      Exit(OPUS_INTERNAL_ERROR);
    if FMode = MODE_SILK_ONLY then
    begin
      if FSilkMode.InternalSampleRate = 8000 then
        CurrBandwidth := OPUS_BANDWIDTH_NARROWBAND
      else if FSilkMode.InternalSampleRate = 12000 then
        CurrBandwidth := OPUS_BANDWIDTH_MEDIUMBAND
      else if FSilkMode.InternalSampleRate = 16000 then
        CurrBandwidth := OPUS_BANDWIDTH_WIDEBAND;
    end;
    FSilkMode.OpusCanSwitch := Ord((FSilkMode.SwitchReady <> 0) and not FNonfinalFrame);
    if NBytes = 0 then
    begin
      FRangeFinal := 0;
      Data[0] := GenToc(FMode, FFs div FrameSize, CurrBandwidth, FStreamChannels);
      Exit(1);
    end;
    if FSilkMode.OpusCanSwitch <> 0 then
    begin
      RedundancyBytes := ComputeRedundancyBytes(MaxDataBytes, FBitrateBps, FrameRate, FStreamChannels);
      Redundancy := RedundancyBytes <> 0;
      CeltToSilk := False;
      FSilkBwSwitch := 1;
    end;
  end;

  // CELT processing
  EndBand := 21;
  case CurrBandwidth of
    OPUS_BANDWIDTH_NARROWBAND: EndBand := 13;
    OPUS_BANDWIDTH_MEDIUMBAND, OPUS_BANDWIDTH_WIDEBAND: EndBand := 17;
    OPUS_BANDWIDTH_SUPERWIDEBAND: EndBand := 19;
    OPUS_BANDWIDTH_FULLBAND: EndBand := 21;
  end;
  FCelt.EndBand := EndBand;
  FCelt.StreamChannels := FStreamChannels;
  FCelt.Bitrate := OPUS_BITRATE_MAX;
  if FMode <> MODE_SILK_ONLY then
  begin
    if FSilkMode.ReducedDependency <> 0 then
      FCelt.SetPrediction(0)
    else
      FCelt.SetPrediction(2);
  end;

  SetLength(TmpPrefill, FChannels * FFs div 400);
  if (FMode <> MODE_SILK_ONLY) and (FMode <> FPrevMode) and (FPrevMode > 0) then
    Move(FDelayBuffer[(FEncoderBuffer - TotalBuffer - FFs div 400) * FChannels], TmpPrefill[0],
      FChannels * (FFs div 400) * SizeOf(Single));

  if FChannels * (FEncoderBuffer - (FrameSize + TotalBuffer)) > 0 then
  begin
    Move(FDelayBuffer[FChannels * FrameSize], FDelayBuffer[0],
      FChannels * (FEncoderBuffer - FrameSize - TotalBuffer) * SizeOf(Single));
    Move(PcmBuf[0], FDelayBuffer[FChannels * (FEncoderBuffer - FrameSize - TotalBuffer)],
      (FrameSize + TotalBuffer) * FChannels * SizeOf(Single));
  end
  else
    Move(PcmBuf[(FrameSize + TotalBuffer - FEncoderBuffer) * FChannels], FDelayBuffer[0],
      FEncoderBuffer * FChannels * SizeOf(Single));

  if (FPrevHBGain < 1.0) or (HBGain < 1.0) then
    GainFade(@PcmBuf[0], @PcmBuf[0], FPrevHBGain, HBGain, CELT_OVERLAP_SIZE, FrameSize,
      FChannels, @CELT_WINDOW120[0], FFs);
  FPrevHBGain := HBGain;
  if (FMode <> MODE_HYBRID) or (FStreamChannels = 1) then
  begin
    if EquivRate > 32000 then
      FSilkMode.StereoWidthQ14 := 16384
    else if EquivRate < 16000 then
      FSilkMode.StereoWidthQ14 := 0
    else
      FSilkMode.StereoWidthQ14 := 16384 - 2048 * (32000 - EquivRate) div (EquivRate - 14000);
  end;
  if FChannels = 2 then
  begin
    if (FHybridStereoWidthQ14 < (1 shl 14)) or (FSilkMode.StereoWidthQ14 < (1 shl 14)) then
    begin
      G1 := FHybridStereoWidthQ14;
      G2 := FSilkMode.StereoWidthQ14;
      G1 := G1 * INV16384;
      G2 := G2 * INV16384;
      StereoFade(@PcmBuf[0], @PcmBuf[0], G1, G2, CELT_OVERLAP_SIZE, FrameSize, FChannels,
        @CELT_WINDOW120[0], FFs);
      FHybridStereoWidthQ14 := FSilkMode.StereoWidthQ14;
    end;
  end;

  if (FMode <> MODE_CELT_ONLY) and
     (EcTell(Enc) + 17 + 20 * Ord(FMode = MODE_HYBRID) <= 8 * (MaxDataBytes - 1)) then
  begin
    if FMode = MODE_HYBRID then
      EcEncBitLogp(Enc, Ord(Redundancy), 12);
    if Redundancy then
    begin
      EcEncBitLogp(Enc, Ord(CeltToSilk), 1);
      if FMode = MODE_HYBRID then
        MaxRedundancy := (MaxDataBytes - 1) - Sar32(EcTell(Enc) + 8 + 3 + 7, 3)
      else
        MaxRedundancy := (MaxDataBytes - 1) - Sar32(EcTell(Enc) + 7, 3);
      RedundancyBytes := Min(MaxRedundancy, RedundancyBytes);
      RedundancyBytes := Min(257, Max(2, RedundancyBytes));
      if FMode = MODE_HYBRID then
        EcEncUInt(Enc, RedundancyBytes - 2, 256);
    end;
  end
  else
    Redundancy := False;

  if not Redundancy then
  begin
    FSilkBwSwitch := 0;
    RedundancyBytes := 0;
  end;
  if FMode <> MODE_CELT_ONLY then
    StartBand := 17;

  if FMode = MODE_SILK_ONLY then
  begin
    Ret := Sar32(EcTell(Enc) + 7, 3);
    EcEncDone(Enc);
    NbComprBytes := Ret;
  end
  else
  begin
    NbComprBytes := (MaxDataBytes - 1) - RedundancyBytes;
    EcEncShrink(Enc, NbComprBytes);
  end;

  if Redundancy or (FMode <> MODE_SILK_ONLY) then
    FCelt.SetAnalysis(AnalysisInfo);
  if FMode = MODE_HYBRID then
  begin
    Info.SignalType := FSilkMode.SignalType;
    Info.Offset := FSilkMode.Offset;
    FCelt.SetSilkInfo(Info);
  end;

  // 5 ms redundant frame for CELT->SILK
  if Redundancy and CeltToSilk then
  begin
    FCelt.StartBand := 0;
    FCelt.Vbr := False;
    FCelt.Bitrate := OPUS_BITRATE_MAX;
    Err := FCelt.EncodeWithEc(@PcmBuf[0], FFs div 200, Payload + NbComprBytes, RedundancyBytes, nil);
    if Err < 0 then
      Exit(OPUS_INTERNAL_ERROR);
    RedundantRng := FCelt.FinalRange;
    FCelt.Reset;
  end;

  FCelt.StartBand := StartBand;

  if FMode <> MODE_SILK_ONLY then
  begin
    FCelt.Vbr := FUseVbr;
    if FMode = MODE_HYBRID then
    begin
      if FUseVbr then
      begin
        FCelt.Bitrate := FBitrateBps - FSilkMode.BitRate;
        FCelt.VbrConstraint := False;
      end;
    end
    else
    begin
      if FUseVbr then
      begin
        FCelt.Vbr := True;
        FCelt.VbrConstraint := FVbrConstraint;
        FCelt.Bitrate := FBitrateBps;
      end;
    end;
    if (FMode <> FPrevMode) and (FPrevMode > 0) then
    begin
      FCelt.Reset;
      FCelt.EncodeWithEc(@TmpPrefill[0], FFs div 400, @Dummy[0], 2, nil);
      FCelt.SetPrediction(0);
    end;
    if EcTell(Enc) <= 8 * NbComprBytes then
    begin
      Ret := FCelt.EncodeWithEc(@PcmBuf[0], FrameSize, nil, NbComprBytes, @Enc);
      if Ret < 0 then
        Exit(OPUS_INTERNAL_ERROR);
      if Redundancy and CeltToSilk and (FMode = MODE_HYBRID) and (NbComprBytes <> Ret) then
      begin
        Move(Payload[NbComprBytes], Payload[Ret], RedundancyBytes);
        NbComprBytes := Ret + RedundancyBytes;
      end;
    end;
  end;

  // 5 ms redundant frame for SILK->CELT
  if Redundancy and not CeltToSilk then
  begin
    N2 := FFs div 200;
    N4 := FFs div 400;
    FCelt.Reset;
    FCelt.StartBand := 0;
    FCelt.SetPrediction(0);
    FCelt.Vbr := False;
    FCelt.Bitrate := OPUS_BITRATE_MAX;
    if FMode = MODE_HYBRID then
    begin
      NbComprBytes := Ret;
      EcEncShrink(Enc, NbComprBytes);
    end;
    FCelt.EncodeWithEc(@PcmBuf[FChannels * (FrameSize - N2 - N4)], N4, @Dummy[0], 2, nil);
    Err := FCelt.EncodeWithEc(@PcmBuf[FChannels * (FrameSize - N2)], N2, Payload + NbComprBytes,
      RedundancyBytes, nil);
    if Err < 0 then
      Exit(OPUS_INTERNAL_ERROR);
    RedundantRng := FCelt.FinalRange;
  end;

  Data[0] := GenToc(FMode, FFs div FrameSize, CurrBandwidth, FStreamChannels);
  FRangeFinal := Enc.Rng xor RedundantRng;

  if ToCelt then
    FPrevMode := MODE_CELT_ONLY
  else
    FPrevMode := FMode;
  FPrevChannels := FStreamChannels;
  FPrevFramesize := FrameSize;
  FFirst := False;

  // DTX decision
  if FUseDtx and (AnalysisInfo.Valid or IsSilence) then
  begin
    if DecideDtxMode(Activity, FNbNoActivityMsQ1, 2 * 1000 * FrameSize div FFs) then
    begin
      FRangeFinal := 0;
      Data[0] := GenToc(FMode, FFs div FrameSize, CurrBandwidth, FStreamChannels);
      Exit(1);
    end;
  end
  else
    FNbNoActivityMsQ1 := 0;

  if EcTell(Enc) > (MaxDataBytes - 1) * 8 then
  begin
    if MaxDataBytes < 2 then
      Exit(OPUS_BUFFER_TOO_SMALL);
    Data[1] := 0;
    Ret := 1;
    FRangeFinal := 0;
  end
  else if (FMode = MODE_SILK_ONLY) and not Redundancy then
  begin
    while (Ret > 2) and (Data[Ret] = 0) do
      Dec(Ret);
  end;
  Ret := Ret + 1 + RedundancyBytes;
  ApplyPadding := not FUseVbr;
  if ApplyPadding then
  begin
    if OpusPacketPad(Data, Ret, MaxDataBytes) <> OPUS_OK then
      Exit(OPUS_INTERNAL_ERROR);
    Ret := MaxDataBytes;
  end;
  Result := Ret;
end;

// ---------------------------------------------------------------------------
// CTLs
// ---------------------------------------------------------------------------

procedure TOpusEncoder.SetApplication(Value: Integer);
begin
  if ((Value <> OPUS_APPLICATION_VOIP) and (Value <> OPUS_APPLICATION_AUDIO) and
      (Value <> OPUS_APPLICATION_RESTRICTED_LOWDELAY)) or ((not FFirst) and (FApplication <> Value)) then
    raise EArgumentException.Create('TOpusEncoder: invalid application');
  FApplication := Value;
  FAnalysis.Application := Value;
end;

procedure TOpusEncoder.SetBitrate(Value: Integer);
begin
  if (Value <> OPUS_AUTO) and (Value <> OPUS_BITRATE_MAX) then
  begin
    if Value <= 0 then
      raise EArgumentException.Create('TOpusEncoder: invalid bitrate')
    else if Value <= 500 then
      Value := 500
    else if Value > 300000 * FChannels then
      Value := 300000 * FChannels;
  end;
  FUserBitrateBps := Value;
end;

function TOpusEncoder.GetBitrate: Integer;
begin
  Result := UserBitrateToBitrate(FPrevFramesize, 1276);
end;

procedure TOpusEncoder.SetComplexity(Value: Integer);
begin
  if (Value < 0) or (Value > 10) then
    raise EArgumentException.Create('TOpusEncoder: complexity must be 0..10');
  FSilkMode.Complexity := Value;
  FCelt.Complexity := Value;
end;

function TOpusEncoder.GetComplexity: Integer;
begin
  Result := FSilkMode.Complexity;
end;

procedure TOpusEncoder.SetVbr(Value: Boolean);
begin
  FUseVbr := Value;
  FSilkMode.UseCBR := Ord(not Value);
end;

procedure TOpusEncoder.SetInbandFec(Value: Integer);
begin
  if (Value < 0) or (Value > 2) then
    raise EArgumentException.Create('TOpusEncoder: inband FEC must be 0..2');
  FFecConfig := Value;
  FSilkMode.UseInBandFEC := Ord(Value <> 0);
end;

procedure TOpusEncoder.SetPacketLossPerc(Value: Integer);
begin
  if (Value < 0) or (Value > 100) then
    raise EArgumentException.Create('TOpusEncoder: packet loss must be 0..100');
  FSilkMode.PacketLossPercentage := Value;
  FCelt.PacketLossPerc := Value;
end;

function TOpusEncoder.GetPacketLossPerc: Integer;
begin
  Result := FSilkMode.PacketLossPercentage;
end;

procedure TOpusEncoder.SetSignal(Value: Integer);
begin
  if (Value <> OPUS_AUTO) and (Value <> OPUS_SIGNAL_VOICE) and (Value <> OPUS_SIGNAL_MUSIC) then
    raise EArgumentException.Create('TOpusEncoder: invalid signal type');
  FSignalType := Value;
end;

procedure TOpusEncoder.SetBandwidth(Value: Integer);
begin
  if ((Value < OPUS_BANDWIDTH_NARROWBAND) or (Value > OPUS_BANDWIDTH_FULLBAND)) and (Value <> OPUS_AUTO) then
    raise EArgumentException.Create('TOpusEncoder: invalid bandwidth');
  FUserBandwidth := Value;
  if FUserBandwidth = OPUS_BANDWIDTH_NARROWBAND then
    FSilkMode.MaxInternalSampleRate := 8000
  else if FUserBandwidth = OPUS_BANDWIDTH_MEDIUMBAND then
    FSilkMode.MaxInternalSampleRate := 12000
  else
    FSilkMode.MaxInternalSampleRate := 16000;
end;

procedure TOpusEncoder.SetMaxBandwidth(Value: Integer);
begin
  if (Value < OPUS_BANDWIDTH_NARROWBAND) or (Value > OPUS_BANDWIDTH_FULLBAND) then
    raise EArgumentException.Create('TOpusEncoder: invalid max bandwidth');
  FMaxBandwidth := Value;
  if FMaxBandwidth = OPUS_BANDWIDTH_NARROWBAND then
    FSilkMode.MaxInternalSampleRate := 8000
  else if FMaxBandwidth = OPUS_BANDWIDTH_MEDIUMBAND then
    FSilkMode.MaxInternalSampleRate := 12000
  else
    FSilkMode.MaxInternalSampleRate := 16000;
end;

procedure TOpusEncoder.SetForceChannels(Value: Integer);
begin
  if ((Value < 1) or (Value > FChannels)) and (Value <> OPUS_AUTO) then
    raise EArgumentException.Create('TOpusEncoder: invalid force channels');
  FForceChannels := Value;
end;

procedure TOpusEncoder.SetLsbDepth(Value: Integer);
begin
  if (Value < 8) or (Value > 24) then
    raise EArgumentException.Create('TOpusEncoder: LSB depth must be 8..24');
  FLsbDepth := Value;
end;

procedure TOpusEncoder.SetExpertFrameDuration(Value: Integer);
begin
  if (Value <> OPUS_FRAMESIZE_ARG) and ((Value < OPUS_FRAMESIZE_2_5_MS) or (Value > OPUS_FRAMESIZE_120_MS)) then
    raise EArgumentException.Create('TOpusEncoder: invalid frame duration');
  FVariableDuration := Value;
end;

procedure TOpusEncoder.SetPredictionDisabled(Value: Boolean);
begin
  FSilkMode.ReducedDependency := Ord(Value);
end;

function TOpusEncoder.GetPredictionDisabled: Boolean;
begin
  Result := FSilkMode.ReducedDependency <> 0;
end;

procedure TOpusEncoder.SetPhaseInversionDisabled(Value: Boolean);
begin
  FCelt.PhaseInversionDisabled := Value;
end;

function TOpusEncoder.GetPhaseInversionDisabled: Boolean;
begin
  Result := FCelt.PhaseInversionDisabled;
end;

procedure TOpusEncoder.SetForceMode(Value: Integer);
begin
  if ((Value < MODE_SILK_ONLY) or (Value > MODE_CELT_ONLY)) and (Value <> OPUS_AUTO) then
    raise EArgumentException.Create('TOpusEncoder: invalid forced mode');
  FUserForcedMode := Value;
end;

procedure TOpusEncoder.SetVoiceRatio(Value: Integer);
begin
  if (Value < -1) or (Value > 100) then
    raise EArgumentException.Create('TOpusEncoder: voice ratio must be -1..100');
  FVoiceRatio := Value;
end;

procedure TOpusEncoder.SetLfe(Value: Boolean);
begin
  FLfe := Value;
  FCelt.Lfe := Value;
end;

function TOpusEncoder.GetLookahead: Integer;
begin
  Result := FFs div 400;
  if FApplication <> OPUS_APPLICATION_RESTRICTED_LOWDELAY then
    Result := Result + FDelayCompensation;
end;

function TOpusEncoder.GetInDTX: Boolean;
begin
  if (FSilkMode.UseDTX <> 0) and ((FPrevMode = MODE_SILK_ONLY) or (FPrevMode = MODE_HYBRID)) then
  begin
    Result := FSilk.state_Fxx[0].sCmn.noSpeechCounter >= NB_SPEECH_FRAMES_BEFORE_DTX;
    if Result and (FSilkMode.NChannelsInternal = 2) and (FSilk.prev_decode_only_middle = 0) then
      Result := FSilk.state_Fxx[1].sCmn.noSpeechCounter >= NB_SPEECH_FRAMES_BEFORE_DTX;
  end
  else if FUseDtx then
    Result := FNbNoActivityMsQ1 >= NB_SPEECH_FRAMES_BEFORE_DTX * 20 * 2
  else
    Result := False;
end;

end.
