unit OpusSilkEncFLP;

{
  OpusSilkEncFLP.pas - SILK float encoder analysis

  Port of libopus 1.5.2 silk/float/noise_shape_analysis_FLP.c,
  find_LPC_FLP.c, find_LTP_FLP.c, LTP_analysis_filter_FLP.c,
  residual_energy_FLP.c, corrMatrix_FLP.c, find_pitch_lags_FLP.c,
  find_pred_coefs_FLP.c, process_gains_FLP.c, wrappers_FLP.c,
  LTP_scale_ctrl_FLP.c.
  Copyright (c) 2006-2011 Skype Limited; Xiph.Org Foundation.

  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$EXCESSPRECISION OFF}
{$Q-}{$R-}

interface

uses
  OpusSilkMath, OpusSilkEncTables, OpusSilkEncDefs, OpusSilkEncCore, OpusSilkEncNLSF, OpusSilkEncNSQ,
  OpusSilkEncDSP, OpusCeltEncMath;

procedure SilkNoiseShapeAnalysisFLP(var Enc: TSilkEncoderStateFLP; var Ctrl: TSilkEncoderControlFLP;
  PitchRes, X: PSingle);
procedure SilkFindPitchLagsFLP(var Enc: TSilkEncoderStateFLP; var Ctrl: TSilkEncoderControlFLP;
  Res, X: PSingle);
procedure SilkFindPredCoefsFLP(var Enc: TSilkEncoderStateFLP; var Ctrl: TSilkEncoderControlFLP;
  ResPitch, X: PSingle; CondCoding: Integer);
procedure SilkProcessGainsFLP(var Enc: TSilkEncoderStateFLP; var Ctrl: TSilkEncoderControlFLP; CondCoding: Integer);
procedure SilkNSQWrapperFLP(var Enc: TSilkEncoderStateFLP; var Ctrl: TSilkEncoderControlFLP;
  var Indices: TSideInfoIndices; var NSQ: TSilkNSQState; Pulses: PShortInt; X: PSingle);

implementation

const
  BG_SNR_DECR_dB: Single = 2.0;
  HARM_SNR_INCR_dB: Single = 2.0;
  ENERGY_VARIATION_THRESHOLD_QNT_OFFSET: Single = 0.6;
  FIND_PITCH_WHITE_NOISE_FRACTION: Single = 1e-3;
  FIND_PITCH_BANDWIDTH_EXPANSION: Single = 0.99;
  BANDWIDTH_EXPANSION: Single = 0.94;
  SHAPE_WHITE_NOISE_FRACTION: Single = 3e-5;
  LOW_FREQ_SHAPING: Single = 4.0;
  LOW_QUALITY_LOW_FREQ_SHAPING_DECR: Single = 0.5;
  HP_NOISE_COEF: Single = 0.25;
  HARM_HP_NOISE_COEF: Single = 0.35;
  HARMONIC_SHAPING: Single = 0.3;
  HIGH_RATE_OR_LOW_QUALITY_HARMONIC_SHAPING: Single = 0.2;
  SUBFR_SMTH_COEF: Single = 0.4;
  LAMBDA_OFFSET: Single = 1.2;
  LAMBDA_SPEECH_ACT: Single = -0.2;
  LAMBDA_DELAYED_DECISIONS: Single = -0.05;
  LAMBDA_INPUT_QUALITY: Single = -0.1;
  LAMBDA_CODING_QUALITY: Single = -0.2;
  LAMBDA_QUANT_OFFSET: Single = 0.8;
  LTP_CORR_INV_MAX: Single = 0.03;
  MAX_PREDICTION_POWER_GAIN: Single = 1e4;
  MAX_PREDICTION_POWER_GAIN_AFTER_RESET: Single = 1e2;
  F_ONE: Single = 1.0;
  F_HALF: Single = 0.5;
  F_INV128: Single = 1.0 / 128.0;
  F_INV256: Single = 1.0 / 256.0;
  F_INV1024: Single = 1.0 / 1024.0;
  F_INV4096: Single = 1.0 / 4096.0;
  F_INV16384: Single = 1.0 / 16384.0;
  F_INV32768: Single = 1.0 / 32768.0;
  F_65536: Single = 65536.0;
  F_16384: Single = 16384.0;
  F_8192: Single = 8192.0;
  F_4096: Single = 4096.0;
  F_1024: Single = 1024.0;
  F_131072: Single = 131072.0;
  F_32767: Single = 32767.0;
  SILK_FLOAT_MAX: Single = 3.40282347e+38;

// ---------------------------------------------------------------------------
// Noise shape analysis
// ---------------------------------------------------------------------------

function WarpedGain(Coefs: PSingle; Lambda: Single; Order: Integer): Single;
var
  I: Integer;
  Gain: Single;
begin
  Lambda := -Lambda;
  Gain := Coefs[Order - 1];
  for I := Order - 2 downto 0 do
    Gain := Lambda * Gain + Coefs[I];
  Result := F_ONE / (F_ONE - Lambda * Gain);
end;

procedure LimitWithBwe(Coefs: PSingle; Lambda, Limit: Single; Order: Integer; Warped: Boolean);
const
  F099: Single = 0.99;
  F08: Single = 0.8;
  F01: Single = 0.1;
var
  I, Iter, Ind: Integer;
  Tmp, MaxAbs, Chirp, Gain, T: Single;
begin
  Ind := 0;
  Gain := 0;
  if Warped then
  begin
    for I := Order - 1 downto 1 do
      Coefs[I - 1] := Coefs[I - 1] - Lambda * Coefs[I];
    Gain := (F_ONE - Lambda * Lambda) / (F_ONE + Lambda * Coefs[0]);
    for I := 0 to Order - 1 do
      Coefs[I] := Coefs[I] * Gain;
  end;
  for Iter := 0 to 9 do
  begin
    MaxAbs := -1.0;
    for I := 0 to Order - 1 do
    begin
      Tmp := Abs(Coefs[I]);
      if Tmp > MaxAbs then
      begin
        MaxAbs := Tmp;
        Ind := I;
      end;
    end;
    if MaxAbs <= Limit then Exit;
    if Warped then
    begin
      for I := 1 to Order - 1 do
        Coefs[I - 1] := Coefs[I - 1] + Lambda * Coefs[I];
      Gain := F_ONE / Gain;
      for I := 0 to Order - 1 do
        Coefs[I] := Coefs[I] * Gain;
    end;
    T := F08 + F01 * Iter;
    T := T * (MaxAbs - Limit);
    Chirp := F099 - T / (MaxAbs * (Ind + 1));
    SilkBwExpanderFLP(Coefs, Order, Chirp);
    if Warped then
    begin
      for I := Order - 1 downto 1 do
        Coefs[I - 1] := Coefs[I - 1] - Lambda * Coefs[I];
      Gain := (F_ONE - Lambda * Lambda) / (F_ONE + Lambda * Coefs[0]);
      for I := 0 to Order - 1 do
        Coefs[I] := Coefs[I] * Gain;
    end;
  end;
end;

procedure SilkNoiseShapeAnalysisFLP(var Enc: TSilkEncoderStateFLP; var Ctrl: TSilkEncoderControlFLP;
  PitchRes, X: PSingle);
const
  F025: Single = 0.25;
  F20: Single = 20.0;
  FM04: Single = -0.4;
  F6: Single = 6.0;
  F001: Single = 0.01;
  F016: Single = 0.16;
  FM016: Single = -0.16;
  F02: Single = 0.2;
  F3: Single = 3.0;
  F13: Single = 1.3;
  F06: Single = 0.6;
  F3999: Single = 3.999;
  F2: Single = 2.0;
var
  K, NSamples, NSegs, Shift, SlopePart, FlatPart: Integer;
  SNRAdjdB, HarmShapeGain, Tilt, Nrg, LogEnergy, LogEnergyPrev, EnergyVariation: Single;
  BWExp, GainMult, GainAdd, Strength, B, Warping, T: Single;
  XWindowed: array[0..SHAPE_LPC_WIN_MAX - 1] of Single;
  AutoCorr, Rc: array[0..MAX_SHAPE_LPC_ORDER] of Single;
  XPtr, PitchResPtr: PSingle;
  C: ^TSilkEncoderState;
  Sh: ^TSilkShapeStateFLP;
begin
  C := @Enc.sCmn;
  Sh := @Enc.sShape;
  XPtr := X - C.la_shape;

  SNRAdjdB := C.SNR_dB_Q7 * F_INV128;
  T := F_HALF * (C.input_quality_bands_Q15[0] + C.input_quality_bands_Q15[1]);
  Ctrl.input_quality := T * F_INV32768;
  Ctrl.coding_quality := SilkSigmoid(F025 * (SNRAdjdB - F20));
  if C.useCBR = 0 then
  begin
    B := F_ONE - C.speech_activity_Q8 * F_INV256;
    T := BG_SNR_DECR_dB * Ctrl.coding_quality;
    T := T * (F_HALF + F_HALF * Ctrl.input_quality);
    T := T * B;
    T := T * B;
    SNRAdjdB := SNRAdjdB - T;
  end;
  if C.indices.signalType = TYPE_VOICED then
    SNRAdjdB := SNRAdjdB + HARM_SNR_INCR_dB * Enc.LTPCorr
  else
  begin
    T := FM04 * C.SNR_dB_Q7;
    T := T * F_INV128 + F6;
    SNRAdjdB := SNRAdjdB + T * (F_ONE - Ctrl.input_quality);
  end;

  if C.indices.signalType = TYPE_VOICED then
    C.indices.quantOffsetType := 0
  else
  begin
    NSamples := 2 * C.fs_kHz;
    EnergyVariation := 0.0;
    LogEnergyPrev := 0.0;
    PitchResPtr := PitchRes;
    NSegs := SilkSMULBB(SUB_FRAME_LENGTH_MS, C.nb_subfr) div 2;
    for K := 0 to NSegs - 1 do
    begin
      T := SilkEnergyFLP(PitchResPtr, NSamples);
      Nrg := Single(NSamples) + T;
      LogEnergy := SilkLog2F(Nrg);
      if K > 0 then
        EnergyVariation := EnergyVariation + Abs(LogEnergy - LogEnergyPrev);
      LogEnergyPrev := LogEnergy;
      Inc(PitchResPtr, NSamples);
    end;
    if EnergyVariation > ENERGY_VARIATION_THRESHOLD_QNT_OFFSET * (NSegs - 1) then
      C.indices.quantOffsetType := 0
    else
      C.indices.quantOffsetType := 1;
  end;

  Strength := FIND_PITCH_WHITE_NOISE_FRACTION * Ctrl.predGain;
  BWExp := BANDWIDTH_EXPANSION / (F_ONE + Strength * Strength);
  T := C.warping_Q16 / F_65536;
  Warping := T + F001 * Ctrl.coding_quality;

  for K := 0 to C.nb_subfr - 1 do
  begin
    FlatPart := C.fs_kHz * 3;
    SlopePart := (C.shapeWinLength - FlatPart) div 2;
    SilkApplySineWindowFLP(@XWindowed[0], XPtr, 1, SlopePart);
    Shift := SlopePart;
    Move(XPtr[Shift], XWindowed[Shift], FlatPart * SizeOf(Single));
    Inc(Shift, FlatPart);
    SilkApplySineWindowFLP(@XWindowed[Shift], XPtr + Shift, 2, SlopePart);
    Inc(XPtr, C.subfr_length);
    if C.warping_Q16 > 0 then
      SilkWarpedAutocorrelationFLP(@AutoCorr[0], @XWindowed[0], Warping, C.shapeWinLength, C.shapingLPCOrder)
    else
      SilkAutocorrelationFLP(@AutoCorr[0], @XWindowed[0], C.shapeWinLength, C.shapingLPCOrder + 1);
    T := AutoCorr[0] * SHAPE_WHITE_NOISE_FRACTION + F_ONE;
    AutoCorr[0] := AutoCorr[0] + T;
    Nrg := SilkSchurFLP(@Rc[0], @AutoCorr[0], C.shapingLPCOrder);
    SilkK2aFLP(@Ctrl.AR[K * MAX_SHAPE_LPC_ORDER], @Rc[0], C.shapingLPCOrder);
    Ctrl.Gains[K] := SqrtF(Nrg);
    if C.warping_Q16 > 0 then
      Ctrl.Gains[K] := Ctrl.Gains[K] * WarpedGain(@Ctrl.AR[K * MAX_SHAPE_LPC_ORDER], Warping, C.shapingLPCOrder);
    SilkBwExpanderFLP(@Ctrl.AR[K * MAX_SHAPE_LPC_ORDER], C.shapingLPCOrder, BWExp);
    LimitWithBwe(@Ctrl.AR[K * MAX_SHAPE_LPC_ORDER], Warping, F3999, C.shapingLPCOrder, C.warping_Q16 > 0);
  end;

  T := FM016 * SNRAdjdB;
  GainMult := PowD(2.0, T);
  T := F016 * MIN_QGAIN_DB;
  GainAdd := PowD(2.0, T);
  for K := 0 to C.nb_subfr - 1 do
  begin
    Ctrl.Gains[K] := Ctrl.Gains[K] * GainMult;
    Ctrl.Gains[K] := Ctrl.Gains[K] + GainAdd;
  end;

  T := C.input_quality_bands_Q15[0] * F_INV32768 - F_ONE;
  Strength := LOW_FREQ_SHAPING * (F_ONE + LOW_QUALITY_LOW_FREQ_SHAPING_DECR * T);
  T := C.speech_activity_Q8 * F_INV256;
  Strength := Strength * T;
  if C.indices.signalType = TYPE_VOICED then
  begin
    for K := 0 to C.nb_subfr - 1 do
    begin
      T := F02 / C.fs_kHz;
      B := T + F3 / Ctrl.pitchL[K];
      Ctrl.LF_MA_shp[K] := -F_ONE + B;
      T := F_ONE - B;
      Ctrl.LF_AR_shp[K] := T - B * Strength;
    end;
    T := (1 - HP_NOISE_COEF) * HARM_HP_NOISE_COEF;
    T := T * C.speech_activity_Q8;
    T := T * F_INV256;
    Tilt := -HP_NOISE_COEF - T;
  end
  else
  begin
    B := F13 / C.fs_kHz;
    Ctrl.LF_MA_shp[0] := -F_ONE + B;
    T := B * Strength;
    T := T * F06;
    Ctrl.LF_AR_shp[0] := (F_ONE - B) - T;
    for K := 1 to C.nb_subfr - 1 do
    begin
      Ctrl.LF_MA_shp[K] := Ctrl.LF_MA_shp[0];
      Ctrl.LF_AR_shp[K] := Ctrl.LF_AR_shp[0];
    end;
    Tilt := -HP_NOISE_COEF;
  end;

  if C.indices.signalType = TYPE_VOICED then
  begin
    HarmShapeGain := HARMONIC_SHAPING;
    T := (F_ONE - Ctrl.coding_quality) * Ctrl.input_quality;
    HarmShapeGain := HarmShapeGain + HIGH_RATE_OR_LOW_QUALITY_HARMONIC_SHAPING * (F_ONE - T);
    HarmShapeGain := HarmShapeGain * SqrtF(Enc.LTPCorr);
  end
  else
    HarmShapeGain := 0.0;

  for K := 0 to C.nb_subfr - 1 do
  begin
    Sh.HarmShapeGain_smth := Sh.HarmShapeGain_smth + SUBFR_SMTH_COEF * (HarmShapeGain - Sh.HarmShapeGain_smth);
    Ctrl.HarmShapeGain[K] := Sh.HarmShapeGain_smth;
    Sh.Tilt_smth := Sh.Tilt_smth + SUBFR_SMTH_COEF * (Tilt - Sh.Tilt_smth);
    Ctrl.Tilt[K] := Sh.Tilt_smth;
  end;
end;

// ---------------------------------------------------------------------------
// Pitch lags
// ---------------------------------------------------------------------------

procedure SilkFindPitchLagsFLP(var Enc: TSilkEncoderStateFLP; var Ctrl: TSilkEncoderControlFLP;
  Res, X: PSingle);
const
  F06: Single = 0.6;
  F0004: Single = 0.004;
  F01: Single = 0.1;
  F015: Single = 0.15;
var
  BufLen, WinMid: Integer;
  Thrhld, ResNrg, T: Single;
  XBufPtr, XBuf: PSingle;
  AutoCorr: array[0..MAX_FIND_PITCH_LPC_ORDER] of Single;
  A, ReflCoef: array[0..MAX_FIND_PITCH_LPC_ORDER - 1] of Single;
  Wsig: array[0..FIND_PITCH_LPC_WIN_MAX - 1] of Single;
  WsigPtr: PSingle;
  C: ^TSilkEncoderState;
begin
  C := @Enc.sCmn;
  BufLen := C.la_pitch + C.frame_length + C.ltp_mem_length;
  XBuf := X - C.ltp_mem_length;
  XBufPtr := XBuf + BufLen - C.pitch_LPC_win_length;
  WsigPtr := @Wsig[0];
  SilkApplySineWindowFLP(WsigPtr, XBufPtr, 1, C.la_pitch);
  Inc(WsigPtr, C.la_pitch);
  Inc(XBufPtr, C.la_pitch);
  WinMid := C.pitch_LPC_win_length - (C.la_pitch shl 1);
  Move(XBufPtr^, WsigPtr^, WinMid * SizeOf(Single));
  Inc(WsigPtr, WinMid);
  Inc(XBufPtr, WinMid);
  SilkApplySineWindowFLP(WsigPtr, XBufPtr, 2, C.la_pitch);
  SilkAutocorrelationFLP(@AutoCorr[0], @Wsig[0], C.pitch_LPC_win_length, C.pitchEstimationLPCOrder + 1);
  T := AutoCorr[0] * FIND_PITCH_WHITE_NOISE_FRACTION + 1;
  AutoCorr[0] := AutoCorr[0] + T;
  ResNrg := SilkSchurFLP(@ReflCoef[0], @AutoCorr[0], C.pitchEstimationLPCOrder);
  if ResNrg > F_ONE then T := ResNrg else T := F_ONE;
  Ctrl.predGain := AutoCorr[0] / T;
  SilkK2aFLP(@A[0], @ReflCoef[0], C.pitchEstimationLPCOrder);
  SilkBwExpanderFLP(@A[0], C.pitchEstimationLPCOrder, FIND_PITCH_BANDWIDTH_EXPANSION);
  SilkLPCAnalysisFilterFLP(Res, @A[0], XBuf, BufLen, C.pitchEstimationLPCOrder);
  if (C.indices.signalType <> TYPE_NO_VOICE_ACTIVITY) and (C.first_frame_after_reset = 0) then
  begin
    Thrhld := F06;
    Thrhld := Thrhld - F0004 * C.pitchEstimationLPCOrder;
    T := F01 * C.speech_activity_Q8;
    Thrhld := Thrhld - T * F_INV256;
    Thrhld := Thrhld - F015 * (C.prevSignalType shr 1);
    T := F01 * C.input_tilt_Q15;
    Thrhld := Thrhld - T * F_INV32768;
    T := C.pitchEstimationThreshold_Q16 / F_65536;
    if SilkPitchAnalysisCoreFLP(Res, @Ctrl.pitchL[0], C.indices.lagIndex, C.indices.contourIndex, Enc.LTPCorr,
      C.prevLag, T, Thrhld, C.fs_kHz, C.pitchEstimationComplexity, C.nb_subfr) = 0 then
      C.indices.signalType := TYPE_VOICED
    else
      C.indices.signalType := TYPE_UNVOICED;
  end
  else
  begin
    FillChar(Ctrl.pitchL, SizeOf(Ctrl.pitchL), 0);
    C.indices.lagIndex := 0;
    C.indices.contourIndex := 0;
    Enc.LTPCorr := 0;
  end;
end;

// ---------------------------------------------------------------------------
// LTP analysis
// ---------------------------------------------------------------------------

procedure CorrVectorFLP(X, T: PSingle; L, Order: Integer; Xt: PSingle);
var
  Lag: Integer;
  Ptr1: PSingle;
begin
  Ptr1 := X + (Order - 1);
  for Lag := 0 to Order - 1 do
  begin
    Xt[Lag] := SilkInnerProductFLP(Ptr1, T, L);
    Dec(Ptr1);
  end;
end;

procedure CorrMatrixFLP(X: PSingle; L, Order: Integer; XX: PSingle);
var
  J, Lag: Integer;
  Energy: Double;
  Ptr1, Ptr2: PSingle;
  T: Single;
begin
  Ptr1 := X + (Order - 1);
  Energy := SilkEnergyFLP(Ptr1, L);
  XX[0] := Energy;
  for J := 1 to Order - 1 do
  begin
    T := Ptr1[-J] * Ptr1[-J] - Ptr1[L - J] * Ptr1[L - J];
    Energy := Energy + T;
    XX[J * Order + J] := Energy;
  end;
  Ptr2 := X + (Order - 2);
  for Lag := 1 to Order - 1 do
  begin
    Energy := SilkInnerProductFLP(Ptr1, Ptr2, L);
    XX[Lag * Order + 0] := Energy;
    XX[0 * Order + Lag] := Energy;
    for J := 1 to Order - Lag - 1 do
    begin
      T := Ptr1[-J] * Ptr2[-J] - Ptr1[L - J] * Ptr2[L - J];
      Energy := Energy + T;
      XX[(Lag + J) * Order + J] := Energy;
      XX[J * Order + Lag + J] := Energy;
    end;
    Dec(Ptr2);
  end;
end;

procedure FindLTPFLP(XX, CorrVec: PSingle; RPtr: PSingle; Lag: PInteger; SubfrLength, NbSubfr: Integer);
var
  K: Integer;
  CorrVecPtr, XXPtr, LagPtr: PSingle;
  RNrg, Temp, T: Single;
begin
  CorrVecPtr := CorrVec;
  XXPtr := XX;
  for K := 0 to NbSubfr - 1 do
  begin
    LagPtr := RPtr - (Lag[K] + LTP_ORDER div 2);
    CorrMatrixFLP(LagPtr, SubfrLength, LTP_ORDER, XXPtr);
    CorrVectorFLP(LagPtr, RPtr, SubfrLength, LTP_ORDER, CorrVecPtr);
    RNrg := SilkEnergyFLP(RPtr, SubfrLength + LTP_ORDER);
    T := LTP_CORR_INV_MAX * F_HALF;
    T := T * (XXPtr[0] + XXPtr[24]) + F_ONE;
    if RNrg > T then T := RNrg;
    Temp := F_ONE / T;
    SilkScaleVectorFLP(XXPtr, Temp, LTP_ORDER * LTP_ORDER);
    SilkScaleVectorFLP(CorrVecPtr, Temp, LTP_ORDER);
    Inc(RPtr, SubfrLength);
    Inc(XXPtr, LTP_ORDER * LTP_ORDER);
    Inc(CorrVecPtr, LTP_ORDER);
  end;
end;

procedure LTPAnalysisFilterFLP(LTPRes, X, B: PSingle; PitchL: PInteger; InvGains: PSingle;
  SubfrLength, NbSubfr, PreLength: Integer);
var
  XPtr, XLagPtr, ResPtr: PSingle;
  Btmp: array[0..LTP_ORDER - 1] of Single;
  InvGain: Single;
  K, I, J: Integer;
begin
  XPtr := X;
  ResPtr := LTPRes;
  for K := 0 to NbSubfr - 1 do
  begin
    XLagPtr := XPtr - PitchL[K];
    InvGain := InvGains[K];
    for I := 0 to LTP_ORDER - 1 do
      Btmp[I] := B[K * LTP_ORDER + I];
    for I := 0 to SubfrLength + PreLength - 1 do
    begin
      ResPtr[I] := XPtr[I];
      for J := 0 to LTP_ORDER - 1 do
        ResPtr[I] := ResPtr[I] - Btmp[J] * XLagPtr[LTP_ORDER div 2 - J];
      ResPtr[I] := ResPtr[I] * InvGain;
      Inc(XLagPtr);
    end;
    Inc(ResPtr, SubfrLength + PreLength);
    Inc(XPtr, SubfrLength);
  end;
end;

procedure ResidualEnergyFLP(Nrgs: PSingle; X: PSingle; A: PSingle; Gains: PSingle;
  SubfrLength, NbSubfr, LPCOrder: Integer);
var
  Shift: Integer;
  LPCRes: array[0..(MAX_FRAME_LENGTH + MAX_NB_SUBFR * MAX_LPC_ORDER) div 2 - 1] of Single;
  LPCResPtr: PSingle;
  G: Single;
begin
  LPCResPtr := @LPCRes[LPCOrder];
  Shift := LPCOrder + SubfrLength;
  SilkLPCAnalysisFilterFLP(@LPCRes[0], A, X, 2 * Shift, LPCOrder);
  G := Gains[0] * Gains[0];
  Nrgs[0] := G * SilkEnergyFLP(LPCResPtr, SubfrLength);
  G := Gains[1] * Gains[1];
  Nrgs[1] := G * SilkEnergyFLP(LPCResPtr + Shift, SubfrLength);
  if NbSubfr = MAX_NB_SUBFR then
  begin
    SilkLPCAnalysisFilterFLP(@LPCRes[0], A + MAX_LPC_ORDER, X + 2 * Shift, 2 * Shift, LPCOrder);
    G := Gains[2] * Gains[2];
    Nrgs[2] := G * SilkEnergyFLP(LPCResPtr, SubfrLength);
    G := Gains[3] * Gains[3];
    Nrgs[3] := G * SilkEnergyFLP(LPCResPtr + Shift, SubfrLength);
  end;
end;

// ---------------------------------------------------------------------------
// Wrappers
// ---------------------------------------------------------------------------

procedure SilkA2NLSFFLP(NLSFQ15: PSmallInt; PAR: PSingle; LPCOrder: Integer);
var
  I: Integer;
  AFixQ16: array[0..MAX_LPC_ORDER - 1] of Integer;
begin
  for I := 0 to LPCOrder - 1 do
    AFixQ16[I] := SilkFloat2Int(PAR[I] * F_65536);
  SilkA2NLSF(NLSFQ15, @AFixQ16[0], LPCOrder);
end;

procedure SilkNLSF2AFLP(PAR: PSingle; NLSFQ15: PSmallInt; LPCOrder: Integer);
var
  I: Integer;
  AFixQ12: array[0..MAX_LPC_ORDER - 1] of SmallInt;
begin
  SilkNLSF2AEnc(@AFixQ12[0], NLSFQ15, LPCOrder);
  for I := 0 to LPCOrder - 1 do
    PAR[I] := AFixQ12[I] * F_INV4096;
end;

procedure SilkQuantLTPGainsFLP(B: PSingle; CbkIndex: PShortInt; var PeriodicityIndex: ShortInt;
  var SumLogGainQ7: Integer; var PredGaindB: Single; XX, CorrVec: PSingle; SubfrLen, NbSubfr: Integer);
var
  I, PredGaindBQ7: Integer;
  BQ14: array[0..MAX_NB_SUBFR * LTP_ORDER - 1] of SmallInt;
  XXQ17: array[0..MAX_NB_SUBFR * LTP_ORDER * LTP_ORDER - 1] of Integer;
  CorrVecQ17: array[0..MAX_NB_SUBFR * LTP_ORDER - 1] of Integer;
begin
  for I := 0 to NbSubfr * LTP_ORDER * LTP_ORDER - 1 do
    XXQ17[I] := SilkFloat2Int(XX[I] * F_131072);
  for I := 0 to NbSubfr * LTP_ORDER - 1 do
    CorrVecQ17[I] := SilkFloat2Int(CorrVec[I] * F_131072);
  SilkQuantLTPGains(@BQ14[0], CbkIndex, PeriodicityIndex, SumLogGainQ7, PredGaindBQ7, @XXQ17[0], @CorrVecQ17[0],
    SubfrLen, NbSubfr);
  for I := 0 to NbSubfr * LTP_ORDER - 1 do
    B[I] := BQ14[I] * F_INV16384;
  PredGaindB := PredGaindBQ7 * F_INV128;
end;

procedure SilkLTPScaleCtrlFLP(var Enc: TSilkEncoderStateFLP; var Ctrl: TSilkEncoderControlFLP; CondCoding: Integer);
var
  RoundLoss, G, Idx: Integer;
  C: ^TSilkEncoderState;
begin
  C := @Enc.sCmn;
  if CondCoding = CODE_INDEPENDENTLY then
  begin
    RoundLoss := C.PacketLoss_perc * C.nFramesPerPacket;
    if C.LBRR_flag <> 0 then
      RoundLoss := 2 + SilkSMULBB(RoundLoss, RoundLoss) div 100;
    G := SmallInt(Trunc(Ctrl.LTPredCodGain));
    Idx := 0;
    if SilkSMULBB(G, RoundLoss) > SilkLog2Lin(2900 - C.SNR_dB_Q7) then Inc(Idx);
    if SilkSMULBB(G, RoundLoss) > SilkLog2Lin(3900 - C.SNR_dB_Q7) then Inc(Idx);
    C.indices.LTP_scaleIndex := ShortInt(Idx);
  end
  else
    C.indices.LTP_scaleIndex := 0;
  Ctrl.LTP_scale := SE_LTPSCALES_TABLE_Q14[C.indices.LTP_scaleIndex] / F_16384;
end;

procedure SilkFindLPCFLP(var E: TSilkEncoderState; NLSFQ15: PSmallInt; X: PSingle; MinInvGain: Single);
var
  K, SubfrLength: Integer;
  A, ATmp: array[0..MAX_LPC_ORDER - 1] of Single;
  ResNrg, ResNrg2nd, ResNrgInterp: Single;
  NLSF0Q15: array[0..MAX_LPC_ORDER - 1] of SmallInt;
  LPCRes: array[0..MAX_FRAME_LENGTH + MAX_NB_SUBFR * MAX_LPC_ORDER - 1] of Single;
  D: Double;
begin
  SubfrLength := E.subfr_length + E.predictLPCOrder;
  E.indices.NLSFInterpCoef_Q2 := 4;
  ResNrg := SilkBurgModifiedFLP(@A[0], X, MinInvGain, SubfrLength, E.nb_subfr, E.predictLPCOrder);
  if (E.useInterpolatedNLSFs <> 0) and (E.first_frame_after_reset = 0) and (E.nb_subfr = MAX_NB_SUBFR) then
  begin
    ResNrg := ResNrg - SilkBurgModifiedFLP(@ATmp[0], X + (MAX_NB_SUBFR div 2) * SubfrLength, MinInvGain,
      SubfrLength, MAX_NB_SUBFR div 2, E.predictLPCOrder);
    SilkA2NLSFFLP(NLSFQ15, @ATmp[0], E.predictLPCOrder);
    ResNrg2nd := SILK_FLOAT_MAX;
    for K := 3 downto 0 do
    begin
      SilkInterpolate(@NLSF0Q15[0], @E.prev_NLSFq_Q15[0], NLSFQ15, K, E.predictLPCOrder);
      SilkNLSF2AFLP(@ATmp[0], @NLSF0Q15[0], E.predictLPCOrder);
      SilkLPCAnalysisFilterFLP(@LPCRes[0], @ATmp[0], X, 2 * SubfrLength, E.predictLPCOrder);
      D := SilkEnergyFLP(@LPCRes[E.predictLPCOrder], SubfrLength - E.predictLPCOrder) +
           SilkEnergyFLP(@LPCRes[E.predictLPCOrder + SubfrLength], SubfrLength - E.predictLPCOrder);
      ResNrgInterp := D;
      if ResNrgInterp < ResNrg then
      begin
        ResNrg := ResNrgInterp;
        E.indices.NLSFInterpCoef_Q2 := ShortInt(K);
      end
      else if ResNrgInterp > ResNrg2nd then
        Break;
      ResNrg2nd := ResNrgInterp;
    end;
  end;
  if E.indices.NLSFInterpCoef_Q2 = 4 then
    SilkA2NLSFFLP(NLSFQ15, @A[0], E.predictLPCOrder);
end;

procedure SilkFindPredCoefsFLP(var Enc: TSilkEncoderStateFLP; var Ctrl: TSilkEncoderControlFLP;
  ResPitch, X: PSingle; CondCoding: Integer);
const
  F025: Single = 0.25;
  F075: Single = 0.75;
var
  I, J: Integer;
  XXLTP: array[0..MAX_NB_SUBFR * LTP_ORDER * LTP_ORDER - 1] of Single;
  CorrVecLTP: array[0..MAX_NB_SUBFR * LTP_ORDER - 1] of Single;
  InvGains: array[0..MAX_NB_SUBFR - 1] of Single;
  NLSFQ15: array[0..MAX_LPC_ORDER - 1] of SmallInt;
  XPtr, XPrePtr: PSingle;
  LPCInPre: array[0..MAX_NB_SUBFR * MAX_LPC_ORDER + MAX_FRAME_LENGTH - 1] of Single;
  MinInvGain, T: Single;
  PredCoefQ12: array[0..1, 0..MAX_LPC_ORDER - 1] of SmallInt;
  C: ^TSilkEncoderState;
begin
  C := @Enc.sCmn;
  FillChar(NLSFQ15, SizeOf(NLSFQ15), 0);
  for I := 0 to C.nb_subfr - 1 do
    InvGains[I] := F_ONE / Ctrl.Gains[I];
  if C.indices.signalType = TYPE_VOICED then
  begin
    FindLTPFLP(@XXLTP[0], @CorrVecLTP[0], ResPitch, @Ctrl.pitchL[0], C.subfr_length, C.nb_subfr);
    SilkQuantLTPGainsFLP(@Ctrl.LTPCoef[0], @C.indices.LTPIndex[0], C.indices.PERIndex, C.sum_log_gain_Q7,
      Ctrl.LTPredCodGain, @XXLTP[0], @CorrVecLTP[0], C.subfr_length, C.nb_subfr);
    SilkLTPScaleCtrlFLP(Enc, Ctrl, CondCoding);
    LTPAnalysisFilterFLP(@LPCInPre[0], X - C.predictLPCOrder, @Ctrl.LTPCoef[0], @Ctrl.pitchL[0], @InvGains[0],
      C.subfr_length, C.nb_subfr, C.predictLPCOrder);
  end
  else
  begin
    XPtr := X - C.predictLPCOrder;
    XPrePtr := @LPCInPre[0];
    for I := 0 to C.nb_subfr - 1 do
    begin
      SilkScaleCopyVectorFLP(XPrePtr, XPtr, InvGains[I], C.subfr_length + C.predictLPCOrder);
      Inc(XPrePtr, C.subfr_length + C.predictLPCOrder);
      Inc(XPtr, C.subfr_length);
    end;
    FillChar(Ctrl.LTPCoef, C.nb_subfr * LTP_ORDER * SizeOf(Single), 0);
    Ctrl.LTPredCodGain := 0.0;
    C.sum_log_gain_Q7 := 0;
  end;
  if C.first_frame_after_reset <> 0 then
    MinInvGain := F_ONE / MAX_PREDICTION_POWER_GAIN_AFTER_RESET
  else
  begin
    T := Ctrl.LTPredCodGain / 3;
    MinInvGain := PowD(2, T);
    MinInvGain := MinInvGain / MAX_PREDICTION_POWER_GAIN;
    T := F025 + F075 * Ctrl.coding_quality;
    MinInvGain := MinInvGain / T;
  end;
  SilkFindLPCFLP(C^, @NLSFQ15[0], @LPCInPre[0], MinInvGain);
  SilkProcessNLSFs(C^, @PredCoefQ12[0, 0], @NLSFQ15[0], @C.prev_NLSFq_Q15[0]);
  for J := 0 to 1 do
    for I := 0 to C.predictLPCOrder - 1 do
      Ctrl.PredCoef[J, I] := PredCoefQ12[J, I] * F_INV4096;
  ResidualEnergyFLP(@Ctrl.ResNrg[0], @LPCInPre[0], @Ctrl.PredCoef[0, 0], @Ctrl.Gains[0], C.subfr_length,
    C.nb_subfr, C.predictLPCOrder);
  Move(NLSFQ15[0], C.prev_NLSFq_Q15[0], SizeOf(C.prev_NLSFq_Q15));
end;

// ---------------------------------------------------------------------------
// Gains
// ---------------------------------------------------------------------------

procedure SilkProcessGainsFLP(var Enc: TSilkEncoderStateFLP; var Ctrl: TSilkEncoderControlFLP; CondCoding: Integer);
const
  F025: Single = 0.25;
  F12: Single = 12.0;
  F033: Single = 0.33;
  F21: Single = 21.0;
var
  K: Integer;
  PGainsQ16: array[0..MAX_NB_SUBFR - 1] of Integer;
  S, InvMaxSqrVal, Gain, QuantOffset, T: Single;
  D: Double;
  Sh: ^TSilkShapeStateFLP;
  C: ^TSilkEncoderState;
  Cond: Integer;
begin
  C := @Enc.sCmn;
  Sh := @Enc.sShape;
  if C.indices.signalType = TYPE_VOICED then
  begin
    S := F_ONE - F_HALF * SilkSigmoid(F025 * (Ctrl.LTPredCodGain - F12));
    for K := 0 to C.nb_subfr - 1 do
      Ctrl.Gains[K] := Ctrl.Gains[K] * S;
  end;
  T := C.SNR_dB_Q7 * F_INV128;
  T := F033 * (F21 - T);
  D := PowD(2.0, T) / C.subfr_length;
  InvMaxSqrVal := D;
  for K := 0 to C.nb_subfr - 1 do
  begin
    Gain := Ctrl.Gains[K];
    T := Ctrl.ResNrg[K] * InvMaxSqrVal;
    Gain := SqrtF(Gain * Gain + T);
    if Gain < F_32767 then Ctrl.Gains[K] := Gain else Ctrl.Gains[K] := F_32767;
  end;
  for K := 0 to C.nb_subfr - 1 do
    PGainsQ16[K] := Trunc(Ctrl.Gains[K] * F_65536);
  Move(PGainsQ16[0], Ctrl.GainsUnq_Q16[0], C.nb_subfr * SizeOf(Integer));
  Ctrl.lastGainIndexPrev := Sh.LastGainIndex;
  if CondCoding = CODE_CONDITIONALLY then Cond := 1 else Cond := 0;
  SilkGainsQuant(@C.indices.GainsIndices[0], @PGainsQ16[0], Sh.LastGainIndex, Cond, C.nb_subfr);
  for K := 0 to C.nb_subfr - 1 do
    Ctrl.Gains[K] := PGainsQ16[K] / F_65536;
  if C.indices.signalType = TYPE_VOICED then
  begin
    T := C.input_tilt_Q15 * F_INV32768;
    if Ctrl.LTPredCodGain + T > F_ONE then
      C.indices.quantOffsetType := 0
    else
      C.indices.quantOffsetType := 1;
  end;
  QuantOffset := SE_QUANTIZATION_OFFSETS_Q10[C.indices.signalType shr 1, C.indices.quantOffsetType] / F_1024;
  S := LAMBDA_OFFSET + LAMBDA_DELAYED_DECISIONS * C.nStatesDelayedDecision;
  T := LAMBDA_SPEECH_ACT * C.speech_activity_Q8;
  S := S + T * F_INV256;
  S := S + LAMBDA_INPUT_QUALITY * Ctrl.input_quality;
  S := S + LAMBDA_CODING_QUALITY * Ctrl.coding_quality;
  S := S + LAMBDA_QUANT_OFFSET * QuantOffset;
  Ctrl.Lambda := S;
end;

// ---------------------------------------------------------------------------
// NSQ wrapper
// ---------------------------------------------------------------------------

procedure SilkNSQWrapperFLP(var Enc: TSilkEncoderStateFLP; var Ctrl: TSilkEncoderControlFLP;
  var Indices: TSideInfoIndices; var NSQ: TSilkNSQState; Pulses: PShortInt; X: PSingle);
var
  I, J, LTPScaleQ14, LambdaQ10: Integer;
  X16: array[0..MAX_FRAME_LENGTH - 1] of SmallInt;
  GainsQ16: array[0..MAX_NB_SUBFR - 1] of Integer;
  PredCoefQ12: array[0..1, 0..MAX_LPC_ORDER - 1] of SmallInt;
  LTPCoefQ14: array[0..LTP_ORDER * MAX_NB_SUBFR - 1] of SmallInt;
  ARQ13: array[0..MAX_NB_SUBFR * MAX_SHAPE_LPC_ORDER - 1] of SmallInt;
  LFShpQ14: array[0..MAX_NB_SUBFR - 1] of Integer;
  TiltQ14, HarmShapeGainQ14: array[0..MAX_NB_SUBFR - 1] of Integer;
  C: ^TSilkEncoderState;
begin
  C := @Enc.sCmn;
  for I := 0 to C.nb_subfr - 1 do
    for J := 0 to C.shapingLPCOrder - 1 do
      ARQ13[I * MAX_SHAPE_LPC_ORDER + J] := SmallInt(SilkFloat2Int(Ctrl.AR[I * MAX_SHAPE_LPC_ORDER + J] * F_8192));
  for I := 0 to C.nb_subfr - 1 do
  begin
    LFShpQ14[I] := (SilkFloat2Int(Ctrl.LF_AR_shp[I] * F_16384) shl 16) or
      Integer(Word(SilkFloat2Int(Ctrl.LF_MA_shp[I] * F_16384)));
    TiltQ14[I] := SilkFloat2Int(Ctrl.Tilt[I] * F_16384);
    HarmShapeGainQ14[I] := SilkFloat2Int(Ctrl.HarmShapeGain[I] * F_16384);
  end;
  LambdaQ10 := SilkFloat2Int(Ctrl.Lambda * F_1024);
  for I := 0 to C.nb_subfr * LTP_ORDER - 1 do
    LTPCoefQ14[I] := SmallInt(SilkFloat2Int(Ctrl.LTPCoef[I] * F_16384));
  for J := 0 to 1 do
    for I := 0 to C.predictLPCOrder - 1 do
      PredCoefQ12[J, I] := SmallInt(SilkFloat2Int(Ctrl.PredCoef[J, I] * F_4096));
  for I := 0 to C.nb_subfr - 1 do
    GainsQ16[I] := SilkFloat2Int(Ctrl.Gains[I] * F_65536);
  if Indices.signalType = TYPE_VOICED then
    LTPScaleQ14 := SE_LTPSCALES_TABLE_Q14[Indices.LTP_scaleIndex]
  else
    LTPScaleQ14 := 0;
  for I := 0 to C.frame_length - 1 do
    X16[I] := SmallInt(SilkFloat2Int(X[I]));
  if (C.nStatesDelayedDecision > 1) or (C.warping_Q16 > 0) then
    SilkNSQDelDec(C^, NSQ, Indices, @X16[0], Pulses, @PredCoefQ12[0, 0], @LTPCoefQ14[0], @ARQ13[0],
      @HarmShapeGainQ14[0], @TiltQ14[0], @LFShpQ14[0], @GainsQ16[0], @Ctrl.pitchL[0], LambdaQ10, LTPScaleQ14)
  else
    SilkNSQ(C^, NSQ, Indices, @X16[0], Pulses, @PredCoefQ12[0, 0], @LTPCoefQ14[0], @ARQ13[0],
      @HarmShapeGainQ14[0], @TiltQ14[0], @LFShpQ14[0], @GainsQ16[0], @Ctrl.pitchL[0], LambdaQ10, LTPScaleQ14);
end;

end.
