unit OpusSilkEncCode;

{
  OpusSilkEncCode.pas - SILK encoder entropy coding and stereo processing

  Port of libopus 1.5.2 silk/encode_indices.c, encode_pulses.c,
  shell_coder.c, code_signs.c, stereo_LR_to_MS.c, stereo_find_predictor.c,
  stereo_quant_pred.c, stereo_encode_pred.c.
  Copyright (c) 2006-2011 Skype Limited; Xiph.Org Foundation.

  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  OpusEntEnc, OpusSilkMath, OpusSilkEncTables, OpusSilkEncDefs, OpusSilkEncCore, OpusSilkEncNLSF;

type
  TStereoIx = array[0..1, 0..2] of ShortInt;
  PStereoIx = ^TStereoIx;

procedure SilkEncodeIndices(var E: TSilkEncoderState; var Enc: TEcEnc; FrameIndex: Integer;
  EncodeLBRR: Boolean; CondCoding: Integer);
procedure SilkEncodePulses(var Enc: TEcEnc; SignalType, QuantOffsetType: Integer; Pulses: PShortInt;
  FrameLength: Integer);
procedure SilkStereoLRtoMS(var State: TStereoEncState; X1, X2: PSmallInt; var Ix: TStereoIx;
  var MidOnlyFlag: ShortInt; MidSideRatesBps: PInteger; TotalRateBps, PrevSpeechActQ8, ToMono,
  FsKHz, FrameLength: Integer);
procedure SilkStereoEncodePred(var Enc: TEcEnc; const Ix: TStereoIx);
procedure SilkStereoEncodeMidOnly(var Enc: TEcEnc; MidOnlyFlag: Integer);

implementation

procedure SilkEncodeIndices(var E: TSilkEncoderState; var Enc: TEcEnc; FrameIndex: Integer;
  EncodeLBRR: Boolean; CondCoding: Integer);
var
  I, K, TypeOffset, EncodeAbsoluteLagIndex, DeltaLagIndex, PitchHighBits, PitchLowBits: Integer;
  EcIx: array[0..MAX_LPC_ORDER - 1] of SmallInt;
  PredQ8: array[0..MAX_LPC_ORDER - 1] of Byte;
  Ind: ^TSideInfoIndices;
  CB: PSilkNLSFCB;
begin
  if EncodeLBRR then Ind := @E.indices_LBRR[FrameIndex] else Ind := @E.indices;
  TypeOffset := 2 * Ind.signalType + Ind.quantOffsetType;
  if EncodeLBRR or (TypeOffset >= 2) then
    EcEncIcdf(Enc, TypeOffset - 2, @SE_TYPE_OFFSET_VAD_ICDF[0], 8)
  else
    EcEncIcdf(Enc, TypeOffset, @SE_TYPE_OFFSET_NO_VAD_ICDF[0], 8);
  if CondCoding = CODE_CONDITIONALLY then
    EcEncIcdf(Enc, Ind.GainsIndices[0], @SE_DELTA_GAIN_ICDF[0], 8)
  else
  begin
    EcEncIcdf(Enc, Sar32(Ind.GainsIndices[0], 3), @SE_GAIN_ICDF[Ind.signalType, 0], 8);
    EcEncIcdf(Enc, Ind.GainsIndices[0] and 7, @SE_UNIFORM8_ICDF[0], 8);
  end;
  for I := 1 to E.nb_subfr - 1 do
    EcEncIcdf(Enc, Ind.GainsIndices[I], @SE_DELTA_GAIN_ICDF[0], 8);
  CB := E.psNLSF_CB;
  EcEncIcdf(Enc, Ind.NLSFIndices[0], CB.CB1_iCDF + (Ind.signalType shr 1) * CB.nVectors, 8);
  SilkNLSFUnpackEnc(@EcIx[0], @PredQ8[0], CB^, Ind.NLSFIndices[0]);
  for I := 0 to CB.order - 1 do
  begin
    if Ind.NLSFIndices[I + 1] >= NLSF_QUANT_MAX_AMPLITUDE then
    begin
      EcEncIcdf(Enc, 2 * NLSF_QUANT_MAX_AMPLITUDE, CB.ec_iCDF + EcIx[I], 8);
      EcEncIcdf(Enc, Ind.NLSFIndices[I + 1] - NLSF_QUANT_MAX_AMPLITUDE, @SE_NLSF_EXT_ICDF[0], 8);
    end
    else if Ind.NLSFIndices[I + 1] <= -NLSF_QUANT_MAX_AMPLITUDE then
    begin
      EcEncIcdf(Enc, 0, CB.ec_iCDF + EcIx[I], 8);
      EcEncIcdf(Enc, -Ind.NLSFIndices[I + 1] - NLSF_QUANT_MAX_AMPLITUDE, @SE_NLSF_EXT_ICDF[0], 8);
    end
    else
      EcEncIcdf(Enc, Ind.NLSFIndices[I + 1] + NLSF_QUANT_MAX_AMPLITUDE, CB.ec_iCDF + EcIx[I], 8);
  end;
  if E.nb_subfr = MAX_NB_SUBFR then
    EcEncIcdf(Enc, Ind.NLSFInterpCoef_Q2, @SE_NLSF_INTERPOLATION_FACTOR_ICDF[0], 8);
  if Ind.signalType = TYPE_VOICED then
  begin
    EncodeAbsoluteLagIndex := 1;
    if (CondCoding = CODE_CONDITIONALLY) and (E.ec_prevSignalType = TYPE_VOICED) then
    begin
      DeltaLagIndex := Ind.lagIndex - E.ec_prevLagIndex;
      if (DeltaLagIndex < -8) or (DeltaLagIndex > 11) then
        DeltaLagIndex := 0
      else
      begin
        DeltaLagIndex := DeltaLagIndex + 9;
        EncodeAbsoluteLagIndex := 0;
      end;
      EcEncIcdf(Enc, DeltaLagIndex, @SE_PITCH_DELTA_ICDF[0], 8);
    end;
    if EncodeAbsoluteLagIndex <> 0 then
    begin
      PitchHighBits := Ind.lagIndex div Sar32(E.fs_kHz, 1);
      PitchLowBits := Ind.lagIndex - SilkSMULBB(PitchHighBits, Sar32(E.fs_kHz, 1));
      EcEncIcdf(Enc, PitchHighBits, @SE_PITCH_LAG_ICDF[0], 8);
      EcEncIcdf(Enc, PitchLowBits, E.pitch_lag_low_bits_iCDF, 8);
    end;
    E.ec_prevLagIndex := Ind.lagIndex;
    EcEncIcdf(Enc, Ind.contourIndex, E.pitch_contour_iCDF, 8);
    EcEncIcdf(Enc, Ind.PERIndex, @SE_LTP_PER_INDEX_ICDF[0], 8);
    for K := 0 to E.nb_subfr - 1 do
      EcEncIcdf(Enc, Ind.LTPIndex[K], SILK_LTP_GAIN_ICDF_PTRS[Ind.PERIndex], 8);
    if CondCoding = CODE_INDEPENDENTLY then
      EcEncIcdf(Enc, Ind.LTP_scaleIndex, @SE_LTPSCALE_ICDF[0], 8);
  end;
  E.ec_prevSignalType := Ind.signalType;
  EcEncIcdf(Enc, Ind.Seed, @SE_UNIFORM4_ICDF[0], 8);
end;

// ---------------------------------------------------------------------------
// Pulses
// ---------------------------------------------------------------------------

function CombineAndCheck(PulsesComb: PInteger; PulsesIn: PInteger; MaxPulses, Len: Integer): Integer;
var
  K, Sum: Integer;
begin
  for K := 0 to Len - 1 do
  begin
    Sum := PulsesIn[2 * K] + PulsesIn[2 * K + 1];
    if Sum > MaxPulses then Exit(1);
    PulsesComb[K] := Sum;
  end;
  Result := 0;
end;

procedure CombinePulses(OutP, InP: PInteger; Len: Integer);
var
  K: Integer;
begin
  for K := 0 to Len - 1 do
    OutP[K] := InP[2 * K] + InP[2 * K + 1];
end;

procedure EncodeSplit(var Enc: TEcEnc; PChild1, P: Integer; ShellTable: PByte);
begin
  if P > 0 then
    EcEncIcdf(Enc, PChild1, ShellTable + SE_SHELL_CODE_TABLE_OFFSETS[P], 8);
end;

procedure SilkShellEncoder(var Enc: TEcEnc; Pulses0: PInteger);
var
  Pulses1: array[0..7] of Integer;
  Pulses2: array[0..3] of Integer;
  Pulses3: array[0..1] of Integer;
  Pulses4: array[0..0] of Integer;
  T0, T1, T2, T3: PByte;
begin
  T0 := @SE_SHELL_CODE_TABLE0[0];
  T1 := @SE_SHELL_CODE_TABLE1[0];
  T2 := @SE_SHELL_CODE_TABLE2[0];
  T3 := @SE_SHELL_CODE_TABLE3[0];
  CombinePulses(@Pulses1[0], Pulses0, 8);
  CombinePulses(@Pulses2[0], @Pulses1[0], 4);
  CombinePulses(@Pulses3[0], @Pulses2[0], 2);
  CombinePulses(@Pulses4[0], @Pulses3[0], 1);
  EncodeSplit(Enc, Pulses3[0], Pulses4[0], T3);
  EncodeSplit(Enc, Pulses2[0], Pulses3[0], T2);
  EncodeSplit(Enc, Pulses1[0], Pulses2[0], T1);
  EncodeSplit(Enc, Pulses0[0], Pulses1[0], T0);
  EncodeSplit(Enc, Pulses0[2], Pulses1[1], T0);
  EncodeSplit(Enc, Pulses1[2], Pulses2[1], T1);
  EncodeSplit(Enc, Pulses0[4], Pulses1[2], T0);
  EncodeSplit(Enc, Pulses0[6], Pulses1[3], T0);
  EncodeSplit(Enc, Pulses2[2], Pulses3[1], T2);
  EncodeSplit(Enc, Pulses1[4], Pulses2[2], T1);
  EncodeSplit(Enc, Pulses0[8], Pulses1[4], T0);
  EncodeSplit(Enc, Pulses0[10], Pulses1[5], T0);
  EncodeSplit(Enc, Pulses1[6], Pulses2[3], T1);
  EncodeSplit(Enc, Pulses0[12], Pulses1[6], T0);
  EncodeSplit(Enc, Pulses0[14], Pulses1[7], T0);
end;

procedure SilkEncodeSigns(var Enc: TEcEnc; Pulses: PShortInt; Length, SignalType, QuantOffsetType: Integer;
  SumPulses: PInteger);
var
  I, J, P: Integer;
  Icdf: array[0..1] of Byte;
  Q: PShortInt;
  IcdfPtr: PByte;
begin
  Icdf[1] := 0;
  Q := Pulses;
  I := SilkSMULBB(7, QuantOffsetType + (SignalType shl 1));
  IcdfPtr := @SE_SIGN_ICDF[I];
  Length := Sar32(Length + SHELL_CODEC_FRAME_LENGTH div 2, LOG2_SHELL_CODEC_FRAME_LENGTH);
  for I := 0 to Length - 1 do
  begin
    P := SumPulses[I];
    if P > 0 then
    begin
      if (P and $1F) < 6 then Icdf[0] := IcdfPtr[P and $1F] else Icdf[0] := IcdfPtr[6];
      for J := 0 to SHELL_CODEC_FRAME_LENGTH - 1 do
        if Q[J] <> 0 then
          EcEncIcdf(Enc, Sar32(Q[J], 15) + 1, @Icdf[0], 8);
    end;
    Inc(Q, SHELL_CODEC_FRAME_LENGTH);
  end;
end;

procedure SilkEncodePulses(var Enc: TEcEnc; SignalType, QuantOffsetType: Integer; Pulses: PShortInt;
  FrameLength: Integer);
var
  I, K, J, Iter, Bit, NLS, ScaleDown, RateLevelIndex: Integer;
  AbsQ, MinSumBitsQ5, SumBitsQ5: Integer;
  AbsPulses: array[0..MAX_FRAME_LENGTH + SHELL_CODEC_FRAME_LENGTH - 1] of Integer;
  SumPulses, NRshifts: array[0..MAX_NB_SHELL_BLOCKS] of Integer;
  PulsesComb: array[0..7] of Integer;
  AbsPtr: PInteger;
  PPtr: PShortInt;
  CdfPtr, NBitsPtr: PByte;
begin
  RateLevelIndex := 0;
  FillChar(PulsesComb, SizeOf(PulsesComb), 0);
  Iter := Sar32(FrameLength, LOG2_SHELL_CODEC_FRAME_LENGTH);
  if Iter * SHELL_CODEC_FRAME_LENGTH < FrameLength then
  begin
    Inc(Iter);
    FillChar(Pulses[FrameLength], SHELL_CODEC_FRAME_LENGTH, 0);
  end;
  for I := 0 to Iter * SHELL_CODEC_FRAME_LENGTH - 1 do
    AbsPulses[I] := SilkAbs(Pulses[I]);
  AbsPtr := @AbsPulses[0];
  for I := 0 to Iter - 1 do
  begin
    NRshifts[I] := 0;
    while True do
    begin
      ScaleDown := CombineAndCheck(@PulsesComb[0], AbsPtr, SE_MAX_PULSES_TABLE[0], 8);
      ScaleDown := ScaleDown + CombineAndCheck(@PulsesComb[0], @PulsesComb[0], SE_MAX_PULSES_TABLE[1], 4);
      ScaleDown := ScaleDown + CombineAndCheck(@PulsesComb[0], @PulsesComb[0], SE_MAX_PULSES_TABLE[2], 2);
      ScaleDown := ScaleDown + CombineAndCheck(@SumPulses[I], @PulsesComb[0], SE_MAX_PULSES_TABLE[3], 1);
      if ScaleDown <> 0 then
      begin
        Inc(NRshifts[I]);
        for K := 0 to SHELL_CODEC_FRAME_LENGTH - 1 do
          AbsPtr[K] := Sar32(AbsPtr[K], 1);
      end
      else
        Break;
    end;
    Inc(AbsPtr, SHELL_CODEC_FRAME_LENGTH);
  end;
  MinSumBitsQ5 := SILK_INT32_MAX;
  for K := 0 to N_RATE_LEVELS - 2 do
  begin
    NBitsPtr := @SE_PULSES_PER_BLOCK_BITS_Q5[K, 0];
    SumBitsQ5 := SE_RATE_LEVELS_BITS_Q5[SignalType shr 1, K];
    for I := 0 to Iter - 1 do
      if NRshifts[I] > 0 then
        SumBitsQ5 := SumBitsQ5 + NBitsPtr[SILK_MAX_PULSES + 1]
      else
        SumBitsQ5 := SumBitsQ5 + NBitsPtr[SumPulses[I]];
    if SumBitsQ5 < MinSumBitsQ5 then
    begin
      MinSumBitsQ5 := SumBitsQ5;
      RateLevelIndex := K;
    end;
  end;
  EcEncIcdf(Enc, RateLevelIndex, @SE_RATE_LEVELS_ICDF[SignalType shr 1, 0], 8);
  CdfPtr := @SE_PULSES_PER_BLOCK_ICDF[RateLevelIndex, 0];
  for I := 0 to Iter - 1 do
  begin
    if NRshifts[I] = 0 then
      EcEncIcdf(Enc, SumPulses[I], CdfPtr, 8)
    else
    begin
      EcEncIcdf(Enc, SILK_MAX_PULSES + 1, CdfPtr, 8);
      for K := 0 to NRshifts[I] - 2 do
        EcEncIcdf(Enc, SILK_MAX_PULSES + 1, @SE_PULSES_PER_BLOCK_ICDF[N_RATE_LEVELS - 1, 0], 8);
      EcEncIcdf(Enc, SumPulses[I], @SE_PULSES_PER_BLOCK_ICDF[N_RATE_LEVELS - 1, 0], 8);
    end;
  end;
  for I := 0 to Iter - 1 do
    if SumPulses[I] > 0 then
      SilkShellEncoder(Enc, @AbsPulses[I * SHELL_CODEC_FRAME_LENGTH]);
  for I := 0 to Iter - 1 do
    if NRshifts[I] > 0 then
    begin
      PPtr := Pulses + I * SHELL_CODEC_FRAME_LENGTH;
      NLS := NRshifts[I] - 1;
      for K := 0 to SHELL_CODEC_FRAME_LENGTH - 1 do
      begin
        AbsQ := ShortInt(SilkAbs(PPtr[K]));
        for J := NLS downto 1 do
        begin
          Bit := Sar32(AbsQ, J) and 1;
          EcEncIcdf(Enc, Bit, @SE_LSB_ICDF[0], 8);
        end;
        Bit := AbsQ and 1;
        EcEncIcdf(Enc, Bit, @SE_LSB_ICDF[0], 8);
      end;
    end;
  SilkEncodeSigns(Enc, Pulses, FrameLength, SignalType, QuantOffsetType, @SumPulses[0]);
end;

// ---------------------------------------------------------------------------
// Stereo
// ---------------------------------------------------------------------------

function StereoFindPredictor(out RatioQ14: Integer; X, Y: PSmallInt; MidResAmpQ0: PInteger;
  Length, SmoothCoefQ16: Integer): Integer;
var
  Scale, Scale1, Scale2, Nrgx, Nrgy, Corr, PredQ13, Pred2Q10: Integer;
begin
  SilkSumSqrShift(Nrgx, Scale1, X, Length);
  SilkSumSqrShift(Nrgy, Scale2, Y, Length);
  if Scale1 > Scale2 then Scale := Scale1 else Scale := Scale2;
  Scale := Scale + (Scale and 1);
  Nrgy := Sar32(Nrgy, Scale - Scale2);
  Nrgx := Sar32(Nrgx, Scale - Scale1);
  if Nrgx < 1 then Nrgx := 1;
  Corr := SilkInnerProdAlignedScale(X, Y, Scale, Length);
  PredQ13 := SilkDIV32VarQ(Corr, Nrgx, 13);
  PredQ13 := SilkLimit(PredQ13, -(1 shl 14), 1 shl 14);
  Pred2Q10 := SilkSMULWB(PredQ13, PredQ13);
  if SilkAbs(Pred2Q10) > SmoothCoefQ16 then SmoothCoefQ16 := SilkAbs(Pred2Q10);
  Scale := Sar32(Scale, 1);
  MidResAmpQ0[0] := SilkSMLAWB(MidResAmpQ0[0], (SilkSqrtApprox(Nrgx) shl Scale) - MidResAmpQ0[0], SmoothCoefQ16);
  Nrgy := Nrgy - (SilkSMULWB(Corr, PredQ13) shl (3 + 1));
  Nrgy := Nrgy + (SilkSMULWB(Nrgx, Pred2Q10) shl 6);
  MidResAmpQ0[1] := SilkSMLAWB(MidResAmpQ0[1], (SilkSqrtApprox(Nrgy) shl Scale) - MidResAmpQ0[1], SmoothCoefQ16);
  if MidResAmpQ0[0] > 1 then
    RatioQ14 := SilkDIV32VarQ(MidResAmpQ0[1], MidResAmpQ0[0], 14)
  else
    RatioQ14 := SilkDIV32VarQ(MidResAmpQ0[1], 1, 14);
  RatioQ14 := SilkLimit(RatioQ14, 0, 32767);
  Result := PredQ13;
end;

procedure StereoQuantPred(PredQ13: PInteger; var Ix: TStereoIx);
var
  I, J, N: Integer;
  LowQ13, StepQ13, LvlQ13, ErrMinQ13, ErrQ13, QuantPredQ13: Integer;
  Done: Boolean;
begin
  QuantPredQ13 := 0;
  for N := 0 to 1 do
  begin
    ErrMinQ13 := SILK_INT32_MAX;
    Done := False;
    for I := 0 to STEREO_QUANT_TAB_SIZE - 2 do
    begin
      LowQ13 := SE_STEREO_PRED_QUANT_Q13[I];
      StepQ13 := SilkSMULWB(SE_STEREO_PRED_QUANT_Q13[I + 1] - LowQ13, 6554);
      for J := 0 to STEREO_QUANT_SUB_STEPS - 1 do
      begin
        LvlQ13 := SilkSMLABB(LowQ13, StepQ13, 2 * J + 1);
        ErrQ13 := SilkAbs(PredQ13[N] - LvlQ13);
        if ErrQ13 < ErrMinQ13 then
        begin
          ErrMinQ13 := ErrQ13;
          QuantPredQ13 := LvlQ13;
          Ix[N, 0] := ShortInt(I);
          Ix[N, 1] := ShortInt(J);
        end
        else
        begin
          Done := True;
          Break;
        end;
      end;
      if Done then Break;
    end;
    Ix[N, 2] := ShortInt(Ix[N, 0] div 3);
    Ix[N, 0] := ShortInt(Ix[N, 0] - Ix[N, 2] * 3);
    PredQ13[N] := QuantPredQ13;
  end;
  PredQ13[0] := PredQ13[0] - PredQ13[1];
end;

procedure SilkStereoLRtoMS(var State: TStereoEncState; X1, X2: PSmallInt; var Ix: TStereoIx;
  var MidOnlyFlag: ShortInt; MidSideRatesBps: PInteger; TotalRateBps, PrevSpeechActQ8, ToMono,
  FsKHz, FrameLength: Integer);
var
  N, Is10msFrame, DenomQ16, Delta0Q13, Delta1Q13: Integer;
  Sum, Diff, SmoothCoefQ16, Pred0Q13, Pred1Q13: Integer;
  PredQ13: array[0..1] of Integer;
  LPRatioQ14, HPRatioQ14, FracQ16, Frac3Q16, MinMidRateBps, WidthQ14, WQ24, DeltawQ24: Integer;
  Side: array[0..MAX_FRAME_LENGTH + 1] of SmallInt;
  LPMid, HPMid, LPSide, HPSide: array[0..MAX_FRAME_LENGTH - 1] of SmallInt;
  Mid: PSmallInt;
begin
  Mid := X1 - 2;
  for N := 0 to FrameLength + 1 do
  begin
    Sum := X1[N - 2] + Integer(X2[N - 2]);
    Diff := X1[N - 2] - Integer(X2[N - 2]);
    Mid[N] := SmallInt(SilkRShiftRound(Sum, 1));
    Side[N] := SilkSat16S(SilkRShiftRound(Diff, 1));
  end;
  Move(State.sMid[0], Mid^, 2 * SizeOf(SmallInt));
  Move(State.sSide[0], Side[0], 2 * SizeOf(SmallInt));
  Move(Mid[FrameLength], State.sMid[0], 2 * SizeOf(SmallInt));
  Move(Side[FrameLength], State.sSide[0], 2 * SizeOf(SmallInt));
  for N := 0 to FrameLength - 1 do
  begin
    Sum := SilkRShiftRound(Mid[N] + Integer(Mid[N + 2]) + (Integer(Mid[N + 1]) shl 1), 2);
    LPMid[N] := SmallInt(Sum);
    HPMid[N] := SmallInt(Mid[N + 1] - Sum);
  end;
  for N := 0 to FrameLength - 1 do
  begin
    Sum := SilkRShiftRound(Side[N] + Integer(Side[N + 2]) + (Integer(Side[N + 1]) shl 1), 2);
    LPSide[N] := SmallInt(Sum);
    HPSide[N] := SmallInt(Side[N + 1] - Sum);
  end;
  if FrameLength = 10 * FsKHz then Is10msFrame := 1 else Is10msFrame := 0;
  if Is10msFrame <> 0 then SmoothCoefQ16 := 328 else SmoothCoefQ16 := 655;
  SmoothCoefQ16 := SilkSMULWB(SilkSMULBB(PrevSpeechActQ8, PrevSpeechActQ8), SmoothCoefQ16);
  PredQ13[0] := StereoFindPredictor(LPRatioQ14, @LPMid[0], @LPSide[0], @State.mid_side_amp_Q0[0], FrameLength, SmoothCoefQ16);
  PredQ13[1] := StereoFindPredictor(HPRatioQ14, @HPMid[0], @HPSide[0], @State.mid_side_amp_Q0[2], FrameLength, SmoothCoefQ16);
  FracQ16 := SilkSMLABB(HPRatioQ14, LPRatioQ14, 3);
  if FracQ16 > (1 shl 16) then FracQ16 := 1 shl 16;
  if Is10msFrame <> 0 then Dec(TotalRateBps, 1200) else Dec(TotalRateBps, 600);
  if TotalRateBps < 1 then TotalRateBps := 1;
  MinMidRateBps := SilkSMLABB(2000, FsKHz, 600);
  Frac3Q16 := 3 * FracQ16;
  MidSideRatesBps[0] := SilkDIV32VarQ(TotalRateBps, (13 shl 16) + Frac3Q16, 16 + 3);
  if MidSideRatesBps[0] < MinMidRateBps then
  begin
    MidSideRatesBps[0] := MinMidRateBps;
    MidSideRatesBps[1] := TotalRateBps - MidSideRatesBps[0];
    WidthQ14 := SilkDIV32VarQ((MidSideRatesBps[1] shl 1) - MinMidRateBps,
      SilkSMULWB((1 shl 16) + Frac3Q16, MinMidRateBps), 14 + 2);
    WidthQ14 := SilkLimit(WidthQ14, 0, 1 shl 14);
  end
  else
  begin
    MidSideRatesBps[1] := TotalRateBps - MidSideRatesBps[0];
    WidthQ14 := 1 shl 14;
  end;
  State.smth_width_Q14 := SmallInt(SilkSMLAWB(State.smth_width_Q14, WidthQ14 - State.smth_width_Q14, SmoothCoefQ16));
  MidOnlyFlag := 0;
  if ToMono <> 0 then
  begin
    WidthQ14 := 0;
    PredQ13[0] := 0;
    PredQ13[1] := 0;
    StereoQuantPred(@PredQ13[0], Ix);
  end
  else if (State.width_prev_Q14 = 0) and
    ((8 * TotalRateBps < 13 * MinMidRateBps) or (SilkSMULWB(FracQ16, State.smth_width_Q14) < 819)) then
  begin
    PredQ13[0] := Sar32(SilkSMULBB(State.smth_width_Q14, PredQ13[0]), 14);
    PredQ13[1] := Sar32(SilkSMULBB(State.smth_width_Q14, PredQ13[1]), 14);
    StereoQuantPred(@PredQ13[0], Ix);
    WidthQ14 := 0;
    PredQ13[0] := 0;
    PredQ13[1] := 0;
    MidSideRatesBps[0] := TotalRateBps;
    MidSideRatesBps[1] := 0;
    MidOnlyFlag := 1;
  end
  else if (State.width_prev_Q14 <> 0) and
    ((8 * TotalRateBps < 11 * MinMidRateBps) or (SilkSMULWB(FracQ16, State.smth_width_Q14) < 328)) then
  begin
    PredQ13[0] := Sar32(SilkSMULBB(State.smth_width_Q14, PredQ13[0]), 14);
    PredQ13[1] := Sar32(SilkSMULBB(State.smth_width_Q14, PredQ13[1]), 14);
    StereoQuantPred(@PredQ13[0], Ix);
    WidthQ14 := 0;
    PredQ13[0] := 0;
    PredQ13[1] := 0;
  end
  else if State.smth_width_Q14 > 15565 then
  begin
    StereoQuantPred(@PredQ13[0], Ix);
    WidthQ14 := 1 shl 14;
  end
  else
  begin
    PredQ13[0] := Sar32(SilkSMULBB(State.smth_width_Q14, PredQ13[0]), 14);
    PredQ13[1] := Sar32(SilkSMULBB(State.smth_width_Q14, PredQ13[1]), 14);
    StereoQuantPred(@PredQ13[0], Ix);
    WidthQ14 := State.smth_width_Q14;
  end;
  if MidOnlyFlag = 1 then
  begin
    State.silent_side_len := SmallInt(State.silent_side_len + FrameLength - STEREO_INTERP_LEN_MS * FsKHz);
    if State.silent_side_len < LA_SHAPE_MS * FsKHz then
      MidOnlyFlag := 0
    else
      State.silent_side_len := 10000;
  end
  else
    State.silent_side_len := 0;
  if (MidOnlyFlag = 0) and (MidSideRatesBps[1] < 1) then
  begin
    MidSideRatesBps[1] := 1;
    MidSideRatesBps[0] := TotalRateBps - MidSideRatesBps[1];
    if MidSideRatesBps[0] < 1 then MidSideRatesBps[0] := 1;
  end;
  Pred0Q13 := -State.pred_prev_Q13[0];
  Pred1Q13 := -State.pred_prev_Q13[1];
  WQ24 := Integer(State.width_prev_Q14) shl 10;
  DenomQ16 := (1 shl 16) div (STEREO_INTERP_LEN_MS * FsKHz);
  Delta0Q13 := -SilkRShiftRound(SilkSMULBB(PredQ13[0] - State.pred_prev_Q13[0], DenomQ16), 16);
  Delta1Q13 := -SilkRShiftRound(SilkSMULBB(PredQ13[1] - State.pred_prev_Q13[1], DenomQ16), 16);
  DeltawQ24 := SilkSMULWB(WidthQ14 - State.width_prev_Q14, DenomQ16) shl 10;
  for N := 0 to STEREO_INTERP_LEN_MS * FsKHz - 1 do
  begin
    Pred0Q13 := Pred0Q13 + Delta0Q13;
    Pred1Q13 := Pred1Q13 + Delta1Q13;
    WQ24 := WQ24 + DeltawQ24;
    Sum := (Mid[N] + Integer(Mid[N + 2]) + (Integer(Mid[N + 1]) shl 1)) shl 9;
    Sum := SilkSMLAWB(SilkSMULWB(WQ24, Side[N + 1]), Sum, Pred0Q13);
    Sum := SilkSMLAWB(Sum, Integer(Mid[N + 1]) shl 11, Pred1Q13);
    X2[N - 1] := SilkSat16S(SilkRShiftRound(Sum, 8));
  end;
  Pred0Q13 := -PredQ13[0];
  Pred1Q13 := -PredQ13[1];
  WQ24 := WidthQ14 shl 10;
  for N := STEREO_INTERP_LEN_MS * FsKHz to FrameLength - 1 do
  begin
    Sum := (Mid[N] + Integer(Mid[N + 2]) + (Integer(Mid[N + 1]) shl 1)) shl 9;
    Sum := SilkSMLAWB(SilkSMULWB(WQ24, Side[N + 1]), Sum, Pred0Q13);
    Sum := SilkSMLAWB(Sum, Integer(Mid[N + 1]) shl 11, Pred1Q13);
    X2[N - 1] := SilkSat16S(SilkRShiftRound(Sum, 8));
  end;
  State.pred_prev_Q13[0] := SmallInt(PredQ13[0]);
  State.pred_prev_Q13[1] := SmallInt(PredQ13[1]);
  State.width_prev_Q14 := SmallInt(WidthQ14);
end;

procedure SilkStereoEncodePred(var Enc: TEcEnc; const Ix: TStereoIx);
var
  N: Integer;
begin
  N := 5 * Ix[0, 2] + Ix[1, 2];
  EcEncIcdf(Enc, N, @SE_STEREO_PRED_JOINT_ICDF[0], 8);
  for N := 0 to 1 do
  begin
    EcEncIcdf(Enc, Ix[N, 0], @SE_UNIFORM3_ICDF[0], 8);
    EcEncIcdf(Enc, Ix[N, 1], @SE_UNIFORM5_ICDF[0], 8);
  end;
end;

procedure SilkStereoEncodeMidOnly(var Enc: TEcEnc; MidOnlyFlag: Integer);
begin
  EcEncIcdf(Enc, MidOnlyFlag, @SE_STEREO_ONLY_CODE_MID_ICDF[0], 8);
end;

end.
