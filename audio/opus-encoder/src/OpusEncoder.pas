unit OpusEncoder;

{
  OpusEncoder.pas - Opus encoder (RFC 6716), equivalent of opus_encoder_create /
  opus_encode / opus_encode_float / opus_encoder_ctl

  Port of libopus 1.5.2 src/opus_encoder.c (float build).

  Stage E1: CELT-only. The mode/bandwidth/channel decision logic is ported
  as in libopus, but until the SILK encoder is available (stage E2) every
  frame is coded in CELT-only mode, and the tonality analysis (analysis.c,
  stage E3) is not run, i.e. the encoder behaves like libopus with
  OPUS_SET_FORCE_MODE(MODE_CELT_ONLY) and without analysis. In-band FEC and
  SILK DTX need SILK and are accepted but have no effect yet.

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
  OpusEncTypes;

const
  OPUS_MAX_PACKET_BYTES = 1276;

type
  TOpusEncoder = class
  private
    FCelt               : TCeltEncoder;
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
      OutDataBytes, LsbDepth: Integer; FloatApi: Boolean): Integer;
    function  EncodeFrameNative(Pcm: PSingle; FrameSize: Integer; Data: PByte;
      MaxDataBytes: Integer; FloatApi, FirstFrame: Boolean; const AnalysisInfo: TAnalysisInfo;
      IsSilence: Boolean; Redundancy, CeltToSilk, Prefill: Boolean; EquivRate: Integer;
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
  OpusSilkMath;

const
  MAX_ENCODER_BUFFER = 480;
  VARIABLE_HP_MIN_CUTOFF_HZ = 60;
  NB_SPEECH_FRAMES_BEFORE_DTX = 10;
  MAX_CONSECUTIVE_DTX = 20;
  VAD_NO_DECISION = -1;
  VERY_SMALL: Single = 1e-30;
  INV32768: Single = 1.0 / 32768;
  INV16384: Single = 1.0 / 16384;
  INV2P28: Single = 1.0 / 268435456;

  // SILK encoder availability: CELT-only until stage E2
  SILK_ENCODER_AVAILABLE = False;

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

  FillChar(FSilkMode, SizeOf(FSilkMode), 0);
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
  ResetState;
end;

destructor TOpusEncoder.Destroy;
begin
  FCelt.Free;
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
end;

procedure TOpusEncoder.Reset;
begin
  ResetState;
  FCelt.Reset;
  // silk_InitEncoder(): the SILK outputs read by the Opus layer go back to 0
  FSilkMode.AllowBandwidthSwitch := 0;
  FSilkMode.InWBmodeWithoutVariableLP := 0;
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
  I: Integer;
begin
  FrameSize := OpusFrameSizeSelect(FrameSize, FVariableDuration, FFs);
  if FrameSize <= 0 then Exit(OPUS_BAD_ARG);
  if (Pcm = nil) or (Data = nil) then Exit(OPUS_BAD_ARG);
  SetLength(InBuf, FrameSize * FChannels);
  for I := 0 to FrameSize * FChannels - 1 do
    InBuf[I] := INV32768 * Pcm[I];
  Result := EncodeNative(@InBuf[0], FrameSize, Data, MaxDataBytes, 16, False);
end;

function TOpusEncoder.EncodeFloat(Pcm: PSingle; FrameSize: Integer; Data: PByte; MaxDataBytes: Integer): Integer;
begin
  FrameSize := OpusFrameSizeSelect(FrameSize, FVariableDuration, FFs);
  if FrameSize <= 0 then Exit(OPUS_BAD_ARG);
  if (Pcm = nil) or (Data = nil) then Exit(OPUS_BAD_ARG);
  Result := EncodeNative(Pcm, FrameSize, Data, MaxDataBytes, 24, True);
end;

function TOpusEncoder.EncodeNative(Pcm: PSingle; FrameSize: Integer; Data: PByte;
  OutDataBytes, LsbDepth: Integer; FloatApi: Boolean): Integer;
var
  I, Ret, VoiceEst, EquivRate, FrameRate, MaxRate, CurrBandwidth, MaxDataBytes, CbrBytes: Integer;
  FrameRate12, TocMode, Bw, PacketCode, NumMultiframes, StereoThreshold: Integer;
  ModeVoice, ModeMusic, Threshold, Hysteresis, BandwidthVal: Integer;
  BandwidthThresholds: array[0..7] of Integer;
  VoiceThr, MusicThr: PInteger;
  StereoWidth: Single;
  Redundancy, CeltToSilk, ToCelt, Prefill, IsSilence: Boolean;
  AnalysisInfo: TAnalysisInfo;
  EncFrameSize, NbFrames, MaxHeaderBytes, RepacketizeLen, MaxLenSum, TotSize, TmpLen,
  DtxCount, CurrMax: Integer;
  TmpData: array of Byte;
  CurrData: PByte;
  Rp: TOpusRepacketizer;
  BakToMono: Integer;
  FirstFrame, FrameToCelt, FrameRedundancy: Boolean;
begin
  MaxDataBytes := Min(OPUS_MAX_PACKET_BYTES, OutDataBytes);
  FRangeFinal := 0;
  CbrBytes := -1;
  Redundancy := False;
  CeltToSilk := False;
  ToCelt := False;
  Prefill := False;
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
    // run_analysis() (analysis.c) is part of stage E3
  end;

  if not IsSilence then
    FVoiceRatio := -1;
  FDetectedBandwidth := 0;

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
  // Stage E1: no SILK encoder yet, every frame is CELT-only
  if not SILK_ENCODER_AVAILABLE then
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
    Prefill := True;   // (silk_InitEncoder: stage E2)

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
  // (detected bandwidth from the analysis: stage E3)

  // decide_fec(): FEC is never used in CELT-only mode
  FSilkMode.LBRRCoded := 0;
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
      if (FSilkMode.Complexity >= 7) and (FFs >= 16000) then
        IsSilence := IsDigitalSilence(Pcm, FrameSize, FChannels, LsbDepth);
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
  IsSilence: Boolean; Redundancy, CeltToSilk, Prefill: Boolean; EquivRate: Integer;
  ToCelt: Boolean): Integer;
const
  K1E9: Single = 1e9;
var
  Ret, NbComprBytes, RedundancyBytes, CutoffHz, HpFreqSmth1, FrameRate, CurrBandwidth,
  DelayCompensation, TotalBuffer, Activity, EndBand, StartBand: Integer;
  RedundantRng: Cardinal;
  HBGain, G1, G2, Sum: Single;
  Enc: TEcEnc;
  PcmBuf: array of Single;
  ApplyPadding: Boolean;
  Payload: PByte;
begin
  FRangeFinal := 0;
  Ret := 0;
  RedundancyBytes := 0;   // (stage E3)
  RedundantRng := 0;
  StartBand := 0;
  CurrBandwidth := FBandwidth;
  if FApplication = OPUS_APPLICATION_RESTRICTED_LOWDELAY then
    DelayCompensation := 0
  else
    DelayCompensation := FDelayCompensation;
  TotalBuffer := DelayCompensation;
  FrameRate := FFs div FrameSize;

  Activity := VAD_NO_DECISION;
  if IsSilence then
    Activity := 0;
  // (activity from the tonality analysis: stage E3)

  // Stage E1 (CELT-only): no SILK bandwidth switch and no redundant CELT
  // frame (Redundancy/CeltToSilk/Prefill are used from stage E3 on).
  FSilkBwSwitch := 0;

  Payload := Data + 1;
  EcEncInit(Enc, Payload, MaxDataBytes - 1);

  SetLength(PcmBuf, (TotalBuffer + FrameSize) * FChannels);
  if TotalBuffer > 0 then
    Move(FDelayBuffer[(FEncoderBuffer - TotalBuffer) * FChannels], PcmBuf[0],
      TotalBuffer * FChannels * SizeOf(Single));

  // Only the CELT-only path exists in stage E1: hp_freq_smth1 is constant
  HpFreqSmth1 := SilkLin2Log(VARIABLE_HP_MIN_CUTOFF_HZ) shl 8;
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

  HBGain := 1.0;
  // (SILK processing: stage E2)

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

  // (SILK/hybrid redundancy signalling: stages E2/E3)
  if FMode <> MODE_CELT_ONLY then
    StartBand := 17;

  NbComprBytes := (MaxDataBytes - 1) - RedundancyBytes;
  EcEncShrink(Enc, NbComprBytes);

  FCelt.SetAnalysis(AnalysisInfo);
  FCelt.StartBand := StartBand;

  if FMode <> MODE_SILK_ONLY then
  begin
    FCelt.Vbr := FUseVbr;
    if FUseVbr then
    begin
      FCelt.Vbr := True;
      FCelt.VbrConstraint := FVbrConstraint;
      FCelt.Bitrate := FBitrateBps;
    end;
    if EcTell(Enc) <= 8 * NbComprBytes then
    begin
      Ret := FCelt.EncodeWithEc(@PcmBuf[0], FrameSize, nil, NbComprBytes, @Enc);
      if Ret < 0 then
        Exit(OPUS_INTERNAL_ERROR);
    end;
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
  // (SILK DTX: stage E2)
  if FUseDtx then
    Result := FNbNoActivityMsQ1 >= NB_SPEECH_FRAMES_BEFORE_DTX * 20 * 2
  else
    Result := False;
end;

end.
