unit OpusSilkEncNSQ;

{
  OpusSilkEncNSQ.pas - SILK noise shaping quantizers and LTP gain quantizer

  Port of libopus 1.5.2 silk/NSQ.c, NSQ.h, NSQ_del_dec.c, quant_LTP_gains.c,
  VQ_WMat_EC.c (C reference paths, no SIMD).
  Copyright (c) 2006-2011 Skype Limited; Xiph.Org Foundation.

  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  OpusEntDec, OpusSilkMath, OpusSilkEncTables, OpusSilkEncDefs, OpusSilkEncCore;

procedure SilkQuantLTPGains(BQ14: PSmallInt; CbkIndex: PShortInt; var PeriodicityIndex: ShortInt;
  var SumLogGainQ7: Integer; var PredGaindBQ7: Integer; CorrMatQ17, CorrVecQ17: PInteger; SubfrLen, NbSubfr: Integer);

procedure SilkNSQ(const E: TSilkEncoderState; var NSQ: TSilkNSQState; var Indices: TSideInfoIndices;
  X16: PSmallInt; Pulses: PShortInt; PredCoefQ12: PSmallInt; LTPCoefQ14: PSmallInt; ARQ13: PSmallInt;
  HarmShapeGainQ14, TiltQ14: PInteger; LFShpQ14, GainsQ16: PInteger; PitchL: PInteger;
  LambdaQ10, LTPScaleQ14: Integer);

procedure SilkNSQDelDec(const E: TSilkEncoderState; var NSQ: TSilkNSQState; var Indices: TSideInfoIndices;
  X16: PSmallInt; Pulses: PShortInt; PredCoefQ12: PSmallInt; LTPCoefQ14: PSmallInt; ARQ13: PSmallInt;
  HarmShapeGainQ14, TiltQ14: PInteger; LFShpQ14, GainsQ16: PInteger; PitchL: PInteger;
  LambdaQ10, LTPScaleQ14: Integer);

implementation

// ---------------------------------------------------------------------------
// LTP gain quantization
// ---------------------------------------------------------------------------

procedure VQWMatEC(var Ind: ShortInt; var ResNrgQ15, RateDistQ8, GainQ7: Integer; CorrMatQ17, CorrVecQ17: PInteger;
  CbQ7: PShortInt; CbGainQ7, ClQ5: PByte; SubfrLen, MaxGainQ7, L: Integer);
var
  K, GainTmpQ7, Penalty, Sum1Q15, Sum2Q24, BitsResQ8, BitsTotQ8, T: Integer;
  Row: PShortInt;
  NegxXQ24: array[0..4] of Integer;
begin
  for K := 0 to 4 do
    NegxXQ24[K] := -(CorrVecQ17[K] shl 7);
  RateDistQ8 := SILK_INT32_MAX;
  ResNrgQ15 := SILK_INT32_MAX;
  Row := CbQ7;
  Ind := 0;
  for K := 0 to L - 1 do
  begin
    GainTmpQ7 := CbGainQ7[K];
    Sum1Q15 := 32801;   // SILK_FIX_CONST(1.001, 15)
    T := GainTmpQ7 - MaxGainQ7;
    if T < 0 then T := 0;
    Penalty := T shl 11;
    Sum2Q24 := NegxXQ24[0] + CorrMatQ17[1] * Row[1];
    Sum2Q24 := Sum2Q24 + CorrMatQ17[2] * Row[2];
    Sum2Q24 := Sum2Q24 + CorrMatQ17[3] * Row[3];
    Sum2Q24 := Sum2Q24 + CorrMatQ17[4] * Row[4];
    Sum2Q24 := Sum2Q24 shl 1;
    Sum2Q24 := Sum2Q24 + CorrMatQ17[0] * Row[0];
    Sum1Q15 := SilkSMLAWB(Sum1Q15, Sum2Q24, Row[0]);
    Sum2Q24 := NegxXQ24[1] + CorrMatQ17[7] * Row[2];
    Sum2Q24 := Sum2Q24 + CorrMatQ17[8] * Row[3];
    Sum2Q24 := Sum2Q24 + CorrMatQ17[9] * Row[4];
    Sum2Q24 := Sum2Q24 shl 1;
    Sum2Q24 := Sum2Q24 + CorrMatQ17[6] * Row[1];
    Sum1Q15 := SilkSMLAWB(Sum1Q15, Sum2Q24, Row[1]);
    Sum2Q24 := NegxXQ24[2] + CorrMatQ17[13] * Row[3];
    Sum2Q24 := Sum2Q24 + CorrMatQ17[14] * Row[4];
    Sum2Q24 := Sum2Q24 shl 1;
    Sum2Q24 := Sum2Q24 + CorrMatQ17[12] * Row[2];
    Sum1Q15 := SilkSMLAWB(Sum1Q15, Sum2Q24, Row[2]);
    Sum2Q24 := NegxXQ24[3] + CorrMatQ17[19] * Row[4];
    Sum2Q24 := Sum2Q24 shl 1;
    Sum2Q24 := Sum2Q24 + CorrMatQ17[18] * Row[3];
    Sum1Q15 := SilkSMLAWB(Sum1Q15, Sum2Q24, Row[3]);
    Sum2Q24 := NegxXQ24[4] shl 1;
    Sum2Q24 := Sum2Q24 + CorrMatQ17[24] * Row[4];
    Sum1Q15 := SilkSMLAWB(Sum1Q15, Sum2Q24, Row[4]);
    if Sum1Q15 >= 0 then
    begin
      BitsResQ8 := SilkSMULBB(SubfrLen, SilkLin2Log(Sum1Q15 + Penalty) - (15 shl 7));
      BitsTotQ8 := BitsResQ8 + (Integer(ClQ5[K]) shl (3 - 1));
      if BitsTotQ8 <= RateDistQ8 then
      begin
        RateDistQ8 := BitsTotQ8;
        ResNrgQ15 := Sum1Q15 + Penalty;
        Ind := ShortInt(K);
        GainQ7 := GainTmpQ7;
      end;
    end;
    Inc(Row, LTP_ORDER);
  end;
end;

procedure SilkQuantLTPGains(BQ14: PSmallInt; CbkIndex: PShortInt; var PeriodicityIndex: ShortInt;
  var SumLogGainQ7: Integer; var PredGaindBQ7: Integer; CorrMatQ17, CorrVecQ17: PInteger; SubfrLen, NbSubfr: Integer);
const
  GAIN_SAFETY = 51;     // SILK_FIX_CONST(0.4, 7)
var
  J, K, CbkSize: Integer;
  TempIdx: array[0..MAX_NB_SUBFR - 1] of ShortInt;
  ClPtr, CbkGainPtr: PByte;
  CbkPtr: PShortInt;
  MatPtr, VecPtr: PInteger;
  ResNrgQ15Subfr, ResNrgQ15, RateDistQ7Subfr, RateDistQ7, MinRateDistQ7: Integer;
  SumLogGainTmpQ7, BestSumLogGainQ7, MaxGainQ7, GainQ7: Integer;
begin
  MinRateDistQ7 := SILK_INT32_MAX;
  BestSumLogGainQ7 := 0;
  GainQ7 := 0;
  for K := 0 to 2 do
  begin
    ClPtr := SILK_LTP_GAIN_BITS_Q5_PTRS[K];
    CbkPtr := SILK_LTP_VQ_PTRS_Q7[K];
    CbkGainPtr := SILK_LTP_VQ_GAIN_PTRS_Q7[K];
    CbkSize := SE_LTP_VQ_SIZES[K];
    MatPtr := CorrMatQ17;
    VecPtr := CorrVecQ17;
    ResNrgQ15 := 0;
    RateDistQ7 := 0;
    SumLogGainTmpQ7 := SumLogGainQ7;
    for J := 0 to NbSubfr - 1 do
    begin
      MaxGainQ7 := SilkLog2Lin((5333 - SumLogGainTmpQ7) + 896) - GAIN_SAFETY;
      VQWMatEC(TempIdx[J], ResNrgQ15Subfr, RateDistQ7Subfr, GainQ7, MatPtr, VecPtr, CbkPtr, CbkGainPtr, ClPtr,
        SubfrLen, MaxGainQ7, CbkSize);
      ResNrgQ15 := SilkAddPosSat32(ResNrgQ15, ResNrgQ15Subfr);
      RateDistQ7 := SilkAddPosSat32(RateDistQ7, RateDistQ7Subfr);
      SumLogGainTmpQ7 := SumLogGainTmpQ7 + SilkLin2Log(GAIN_SAFETY + GainQ7) - 896;
      if SumLogGainTmpQ7 < 0 then SumLogGainTmpQ7 := 0;
      Inc(MatPtr, LTP_ORDER * LTP_ORDER);
      Inc(VecPtr, LTP_ORDER);
    end;
    if RateDistQ7 <= MinRateDistQ7 then
    begin
      MinRateDistQ7 := RateDistQ7;
      PeriodicityIndex := ShortInt(K);
      Move(TempIdx[0], CbkIndex^, NbSubfr);
      BestSumLogGainQ7 := SumLogGainTmpQ7;
    end;
  end;
  CbkPtr := SILK_LTP_VQ_PTRS_Q7[PeriodicityIndex];
  for J := 0 to NbSubfr - 1 do
    for K := 0 to LTP_ORDER - 1 do
      BQ14[J * LTP_ORDER + K] := SmallInt(Integer(CbkPtr[CbkIndex[J] * LTP_ORDER + K]) shl 7);
  if NbSubfr = 2 then
    ResNrgQ15 := Sar32(ResNrgQ15, 1)
  else
    ResNrgQ15 := Sar32(ResNrgQ15, 2);
  SumLogGainQ7 := BestSumLogGainQ7;
  PredGaindBQ7 := SilkSMULBB(-3, SilkLin2Log(ResNrgQ15) - (15 shl 7));
end;

// ---------------------------------------------------------------------------
// NSQ helpers
// ---------------------------------------------------------------------------

function ShortPrediction(Buf32: PInteger; Coef16: PSmallInt; Order: Integer): Integer; inline;
begin
  Result := Sar32(Order, 1);
  Result := SilkSMLAWB(Result, Buf32[0], Coef16[0]);
  Result := SilkSMLAWB(Result, Buf32[-1], Coef16[1]);
  Result := SilkSMLAWB(Result, Buf32[-2], Coef16[2]);
  Result := SilkSMLAWB(Result, Buf32[-3], Coef16[3]);
  Result := SilkSMLAWB(Result, Buf32[-4], Coef16[4]);
  Result := SilkSMLAWB(Result, Buf32[-5], Coef16[5]);
  Result := SilkSMLAWB(Result, Buf32[-6], Coef16[6]);
  Result := SilkSMLAWB(Result, Buf32[-7], Coef16[7]);
  Result := SilkSMLAWB(Result, Buf32[-8], Coef16[8]);
  Result := SilkSMLAWB(Result, Buf32[-9], Coef16[9]);
  if Order = 16 then
  begin
    Result := SilkSMLAWB(Result, Buf32[-10], Coef16[10]);
    Result := SilkSMLAWB(Result, Buf32[-11], Coef16[11]);
    Result := SilkSMLAWB(Result, Buf32[-12], Coef16[12]);
    Result := SilkSMLAWB(Result, Buf32[-13], Coef16[13]);
    Result := SilkSMLAWB(Result, Buf32[-14], Coef16[14]);
    Result := SilkSMLAWB(Result, Buf32[-15], Coef16[15]);
  end;
end;

function NoiseShapeFeedbackLoop(Data0: PInteger; Data1: PInteger; Coef: PSmallInt; Order: Integer): Integer;
var
  Tmp1, Tmp2, J: Integer;
begin
  Tmp2 := Data0[0];
  Tmp1 := Data1[0];
  Data1[0] := Tmp2;
  Result := Sar32(Order, 1);
  Result := SilkSMLAWB(Result, Tmp2, Coef[0]);
  J := 2;
  while J < Order do
  begin
    Tmp2 := Data1[J - 1];
    Data1[J - 1] := Tmp1;
    Result := SilkSMLAWB(Result, Tmp1, Coef[J - 1]);
    Tmp1 := Data1[J];
    Data1[J] := Tmp2;
    Result := SilkSMLAWB(Result, Tmp2, Coef[J]);
    Inc(J, 2);
  end;
  Data1[Order - 1] := Tmp1;
  Result := SilkSMLAWB(Result, Tmp1, Coef[Order - 1]);
  Result := Result shl 1;
end;

// Quantization level candidates shared by both quantizers (rd in Q20 for NSQ,
// shifted down by the caller for the delayed-decision version).
procedure QuantCandidates(RQ10, OffsetQ10, LambdaQ10: Integer; out Q1Q10, Q2Q10, Rd1, Rd2: Integer);
var
  Q1Q0, RdoOffset: Integer;
begin
  Q1Q10 := RQ10 - OffsetQ10;
  Q1Q0 := Sar32(Q1Q10, 10);
  if LambdaQ10 > 2048 then
  begin
    RdoOffset := LambdaQ10 div 2 - 512;
    if Q1Q10 > RdoOffset then
      Q1Q0 := Sar32(Q1Q10 - RdoOffset, 10)
    else if Q1Q10 < -RdoOffset then
      Q1Q0 := Sar32(Q1Q10 + RdoOffset, 10)
    else if Q1Q10 < 0 then
      Q1Q0 := -1
    else
      Q1Q0 := 0;
  end;
  if Q1Q0 > 0 then
  begin
    Q1Q10 := (Q1Q0 shl 10) - QUANT_LEVEL_ADJUST_Q10;
    Q1Q10 := Q1Q10 + OffsetQ10;
    Q2Q10 := Q1Q10 + 1024;
    Rd1 := SilkSMULBB(Q1Q10, LambdaQ10);
    Rd2 := SilkSMULBB(Q2Q10, LambdaQ10);
  end
  else if Q1Q0 = 0 then
  begin
    Q1Q10 := OffsetQ10;
    Q2Q10 := Q1Q10 + 1024 - QUANT_LEVEL_ADJUST_Q10;
    Rd1 := SilkSMULBB(Q1Q10, LambdaQ10);
    Rd2 := SilkSMULBB(Q2Q10, LambdaQ10);
  end
  else if Q1Q0 = -1 then
  begin
    Q2Q10 := OffsetQ10;
    Q1Q10 := Q2Q10 - (1024 - QUANT_LEVEL_ADJUST_Q10);
    Rd1 := SilkSMULBB(-Q1Q10, LambdaQ10);
    Rd2 := SilkSMULBB(Q2Q10, LambdaQ10);
  end
  else
  begin
    Q1Q10 := (Q1Q0 shl 10) + QUANT_LEVEL_ADJUST_Q10;
    Q1Q10 := Q1Q10 + OffsetQ10;
    Q2Q10 := Q1Q10 + 1024;
    Rd1 := SilkSMULBB(-Q1Q10, LambdaQ10);
    Rd2 := SilkSMULBB(-Q2Q10, LambdaQ10);
  end;
end;

// ---------------------------------------------------------------------------
// NSQ
// ---------------------------------------------------------------------------

procedure NSQScaleStates(const E: TSilkEncoderState; var NSQ: TSilkNSQState; X16: PSmallInt; XScQ10: PInteger;
  SLTP: PSmallInt; SLTPQ15: PInteger; Subfr, LTPScaleQ14: Integer; GainsQ16, PitchL: PInteger; SignalType: Integer);
var
  I, Lag, GainAdjQ16, InvGainQ31, InvGainQ26, G: Integer;
begin
  Lag := PitchL[Subfr];
  G := GainsQ16[Subfr];
  if G < 1 then G := 1;
  InvGainQ31 := SilkINVERSE32VarQ(G, 47);
  InvGainQ26 := SilkRShiftRound(InvGainQ31, 5);
  for I := 0 to E.subfr_length - 1 do
    XScQ10[I] := SilkSMULWW(X16[I], InvGainQ26);
  if NSQ.rewhite_flag <> 0 then
  begin
    if Subfr = 0 then
      InvGainQ31 := SilkSMULWB(InvGainQ31, LTPScaleQ14) shl 2;
    for I := NSQ.sLTP_buf_idx - Lag - LTP_ORDER div 2 to NSQ.sLTP_buf_idx - 1 do
      SLTPQ15[I] := SilkSMULWB(InvGainQ31, SLTP[I]);
  end;
  if GainsQ16[Subfr] <> NSQ.prev_gain_Q16 then
  begin
    GainAdjQ16 := SilkDIV32VarQ(NSQ.prev_gain_Q16, GainsQ16[Subfr], 16);
    for I := NSQ.sLTP_shp_buf_idx - E.ltp_mem_length to NSQ.sLTP_shp_buf_idx - 1 do
      NSQ.sLTP_shp_Q14[I] := SilkSMULWW(GainAdjQ16, NSQ.sLTP_shp_Q14[I]);
    if (SignalType = TYPE_VOICED) and (NSQ.rewhite_flag = 0) then
      for I := NSQ.sLTP_buf_idx - Lag - LTP_ORDER div 2 to NSQ.sLTP_buf_idx - 1 do
        SLTPQ15[I] := SilkSMULWW(GainAdjQ16, SLTPQ15[I]);
    NSQ.sLF_AR_shp_Q14 := SilkSMULWW(GainAdjQ16, NSQ.sLF_AR_shp_Q14);
    NSQ.sDiff_shp_Q14 := SilkSMULWW(GainAdjQ16, NSQ.sDiff_shp_Q14);
    for I := 0 to NSQ_LPC_BUF_LENGTH - 1 do
      NSQ.sLPC_Q14[I] := SilkSMULWW(GainAdjQ16, NSQ.sLPC_Q14[I]);
    for I := 0 to MAX_SHAPE_LPC_ORDER - 1 do
      NSQ.sAR2_Q14[I] := SilkSMULWW(GainAdjQ16, NSQ.sAR2_Q14[I]);
    NSQ.prev_gain_Q16 := GainsQ16[Subfr];
  end;
end;

procedure NoiseShapeQuantizer(var NSQ: TSilkNSQState; SignalType: Integer; XScQ10: PInteger; Pulses: PShortInt;
  XQ: PSmallInt; SLTPQ15: PInteger; AQ12, BQ14, ARShpQ13: PSmallInt; Lag, HarmShapeFIRPackedQ14, TiltQ14,
  LFShpQ14, GainQ16, LambdaQ10, OffsetQ10, Length, ShapingLPCOrder, PredictLPCOrder: Integer);
var
  I: Integer;
  LTPPredQ13, LPCPredQ10, NARQ12, NLTPQ13, NLFQ12, RQ10, RrQ10, Q1Q10, Q2Q10, Rd1Q20, Rd2Q20: Integer;
  ExcQ14, LPCExcQ14, XqQ14, GainQ10, Tmp1, Tmp2, SLFARShpQ14: Integer;
  PsLPCQ14, ShpLagPtr, PredLagPtr: PInteger;
begin
  ShpLagPtr := @NSQ.sLTP_shp_Q14[NSQ.sLTP_shp_buf_idx - Lag + HARM_SHAPE_FIR_TAPS div 2];
  PredLagPtr := SLTPQ15 + (NSQ.sLTP_buf_idx - Lag + LTP_ORDER div 2);
  GainQ10 := Sar32(GainQ16, 6);
  PsLPCQ14 := @NSQ.sLPC_Q14[NSQ_LPC_BUF_LENGTH - 1];
  for I := 0 to Length - 1 do
  begin
    NSQ.rand_seed := SilkRand(NSQ.rand_seed);
    LPCPredQ10 := ShortPrediction(PsLPCQ14, AQ12, PredictLPCOrder);
    if SignalType = TYPE_VOICED then
    begin
      LTPPredQ13 := 2;
      LTPPredQ13 := SilkSMLAWB(LTPPredQ13, PredLagPtr[0], BQ14[0]);
      LTPPredQ13 := SilkSMLAWB(LTPPredQ13, PredLagPtr[-1], BQ14[1]);
      LTPPredQ13 := SilkSMLAWB(LTPPredQ13, PredLagPtr[-2], BQ14[2]);
      LTPPredQ13 := SilkSMLAWB(LTPPredQ13, PredLagPtr[-3], BQ14[3]);
      LTPPredQ13 := SilkSMLAWB(LTPPredQ13, PredLagPtr[-4], BQ14[4]);
      Inc(PredLagPtr);
    end
    else
      LTPPredQ13 := 0;
    NARQ12 := NoiseShapeFeedbackLoop(@NSQ.sDiff_shp_Q14, @NSQ.sAR2_Q14[0], ARShpQ13, ShapingLPCOrder);
    NARQ12 := SilkSMLAWB(NARQ12, NSQ.sLF_AR_shp_Q14, TiltQ14);
    NLFQ12 := SilkSMULWB(NSQ.sLTP_shp_Q14[NSQ.sLTP_shp_buf_idx - 1], LFShpQ14);
    NLFQ12 := SilkSMLAWT(NLFQ12, NSQ.sLF_AR_shp_Q14, LFShpQ14);
    Tmp1 := (LPCPredQ10 shl 2) - NARQ12;
    Tmp1 := Tmp1 - NLFQ12;
    if Lag > 0 then
    begin
      NLTPQ13 := SilkSMULWB(SilkAddSat32(ShpLagPtr[0], ShpLagPtr[-2]), HarmShapeFIRPackedQ14);
      NLTPQ13 := SilkSMLAWT(NLTPQ13, ShpLagPtr[-1], HarmShapeFIRPackedQ14);
      NLTPQ13 := NLTPQ13 shl 1;
      Inc(ShpLagPtr);
      Tmp2 := LTPPredQ13 - NLTPQ13;
      Tmp1 := Tmp2 + (Tmp1 shl 1);
      Tmp1 := SilkRShiftRound(Tmp1, 3);
    end
    else
      Tmp1 := SilkRShiftRound(Tmp1, 2);
    RQ10 := XScQ10[I] - Tmp1;
    if NSQ.rand_seed < 0 then RQ10 := -RQ10;
    RQ10 := SilkLimit(RQ10, -(31 shl 10), 30 shl 10);
    QuantCandidates(RQ10, OffsetQ10, LambdaQ10, Q1Q10, Q2Q10, Rd1Q20, Rd2Q20);
    RrQ10 := RQ10 - Q1Q10;
    Rd1Q20 := SilkSMLABB(Rd1Q20, RrQ10, RrQ10);
    RrQ10 := RQ10 - Q2Q10;
    Rd2Q20 := SilkSMLABB(Rd2Q20, RrQ10, RrQ10);
    if Rd2Q20 < Rd1Q20 then Q1Q10 := Q2Q10;
    Pulses[I] := ShortInt(SilkRShiftRound(Q1Q10, 10));
    ExcQ14 := Q1Q10 shl 4;
    if NSQ.rand_seed < 0 then ExcQ14 := -ExcQ14;
    LPCExcQ14 := ExcQ14 + (LTPPredQ13 shl 1);
    XqQ14 := LPCExcQ14 + (LPCPredQ10 shl 4);
    XQ[I] := SilkSat16S(SilkRShiftRound(SilkSMULWW(XqQ14, GainQ10), 8));
    Inc(PsLPCQ14);
    PsLPCQ14^ := XqQ14;
    NSQ.sDiff_shp_Q14 := XqQ14 - (XScQ10[I] shl 4);
    SLFARShpQ14 := NSQ.sDiff_shp_Q14 - (NARQ12 shl 2);
    NSQ.sLF_AR_shp_Q14 := SLFARShpQ14;
    NSQ.sLTP_shp_Q14[NSQ.sLTP_shp_buf_idx] := SLFARShpQ14 - (NLFQ12 shl 2);
    SLTPQ15[NSQ.sLTP_buf_idx] := LPCExcQ14 shl 1;
    Inc(NSQ.sLTP_shp_buf_idx);
    Inc(NSQ.sLTP_buf_idx);
    NSQ.rand_seed := NSQ.rand_seed + Pulses[I];
  end;
  Move(NSQ.sLPC_Q14[Length], NSQ.sLPC_Q14[0], NSQ_LPC_BUF_LENGTH * SizeOf(Integer));
end;

procedure SilkNSQ(const E: TSilkEncoderState; var NSQ: TSilkNSQState; var Indices: TSideInfoIndices;
  X16: PSmallInt; Pulses: PShortInt; PredCoefQ12: PSmallInt; LTPCoefQ14: PSmallInt; ARQ13: PSmallInt;
  HarmShapeGainQ14, TiltQ14: PInteger; LFShpQ14, GainsQ16: PInteger; PitchL: PInteger;
  LambdaQ10, LTPScaleQ14: Integer);
var
  K, Lag, StartIdx, LSFInterpolationFlag, HarmShapeFIRPackedQ14, OffsetQ10: Integer;
  AQ12, BQ14, ARShpQ13: PSmallInt;
  PXQ: PSmallInt;
  SLTPQ15: array[0..2 * MAX_FRAME_LENGTH - 1] of Integer;
  SLTP: array[0..2 * MAX_FRAME_LENGTH - 1] of SmallInt;
  XScQ10: array[0..MAX_SUB_FRAME_LENGTH - 1] of Integer;
begin
  NSQ.rand_seed := Indices.Seed;
  Lag := NSQ.lagPrev;
  OffsetQ10 := SE_QUANTIZATION_OFFSETS_Q10[Indices.signalType shr 1, Indices.quantOffsetType];
  if Indices.NLSFInterpCoef_Q2 = 4 then LSFInterpolationFlag := 0 else LSFInterpolationFlag := 1;
  NSQ.sLTP_shp_buf_idx := E.ltp_mem_length;
  NSQ.sLTP_buf_idx := E.ltp_mem_length;
  PXQ := @NSQ.xq[E.ltp_mem_length];
  for K := 0 to E.nb_subfr - 1 do
  begin
    AQ12 := PredCoefQ12 + ((K shr 1) or (1 - LSFInterpolationFlag)) * MAX_LPC_ORDER;
    BQ14 := LTPCoefQ14 + K * LTP_ORDER;
    ARShpQ13 := ARQ13 + K * MAX_SHAPE_LPC_ORDER;
    HarmShapeFIRPackedQ14 := Sar32(HarmShapeGainQ14[K], 2);
    HarmShapeFIRPackedQ14 := HarmShapeFIRPackedQ14 or (Sar32(HarmShapeGainQ14[K], 1) shl 16);
    NSQ.rewhite_flag := 0;
    if Indices.signalType = TYPE_VOICED then
    begin
      Lag := PitchL[K];
      if (K and (3 - (LSFInterpolationFlag shl 1))) = 0 then
      begin
        StartIdx := E.ltp_mem_length - Lag - E.predictLPCOrder - LTP_ORDER div 2;
        SilkLPCAnalysisFilter(@SLTP[StartIdx], @NSQ.xq[StartIdx + K * E.subfr_length], AQ12,
          E.ltp_mem_length - StartIdx, E.predictLPCOrder);
        NSQ.rewhite_flag := 1;
        NSQ.sLTP_buf_idx := E.ltp_mem_length;
      end;
    end;
    NSQScaleStates(E, NSQ, X16, @XScQ10[0], @SLTP[0], @SLTPQ15[0], K, LTPScaleQ14, GainsQ16, PitchL,
      Indices.signalType);
    NoiseShapeQuantizer(NSQ, Indices.signalType, @XScQ10[0], Pulses, PXQ, @SLTPQ15[0], AQ12, BQ14, ARShpQ13,
      Lag, HarmShapeFIRPackedQ14, TiltQ14[K], LFShpQ14[K], GainsQ16[K], LambdaQ10, OffsetQ10,
      E.subfr_length, E.shapingLPCOrder, E.predictLPCOrder);
    Inc(X16, E.subfr_length);
    Inc(Pulses, E.subfr_length);
    Inc(PXQ, E.subfr_length);
  end;
  NSQ.lagPrev := PitchL[E.nb_subfr - 1];
  Move(NSQ.xq[E.frame_length], NSQ.xq[0], E.ltp_mem_length * SizeOf(SmallInt));
  Move(NSQ.sLTP_shp_Q14[E.frame_length], NSQ.sLTP_shp_Q14[0], E.ltp_mem_length * SizeOf(Integer));
end;

// ---------------------------------------------------------------------------
// NSQ with delayed decision
// ---------------------------------------------------------------------------

type
  TNSQDelDec = record
    sLPC_Q14 : array[0..MAX_SUB_FRAME_LENGTH + NSQ_LPC_BUF_LENGTH - 1] of Integer;
    RandState: array[0..DECISION_DELAY - 1] of Integer;
    Q_Q10    : array[0..DECISION_DELAY - 1] of Integer;
    Xq_Q14   : array[0..DECISION_DELAY - 1] of Integer;
    Pred_Q15 : array[0..DECISION_DELAY - 1] of Integer;
    Shape_Q14: array[0..DECISION_DELAY - 1] of Integer;
    sAR2_Q14 : array[0..MAX_SHAPE_LPC_ORDER - 1] of Integer;
    LF_AR_Q14: Integer;
    Diff_Q14 : Integer;
    Seed     : Integer;
    SeedInit : Integer;
    RD_Q10   : Integer;
  end;
  PNSQDelDec = ^TNSQDelDec;

  TNSQSample = record
    Q_Q10       : Integer;
    RD_Q10      : Integer;
    xq_Q14      : Integer;
    LF_AR_Q14   : Integer;
    Diff_Q14    : Integer;
    sLTP_shp_Q14: Integer;
    LPC_exc_Q14 : Integer;
  end;
  TNSQSamplePair = array[0..1] of TNSQSample;

  TDelDecArray = array[0..MAX_DEL_DEC_STATES - 1] of TNSQDelDec;

procedure NSQDelDecScaleStates(const E: TSilkEncoderState; var NSQ: TSilkNSQState; var DD: TDelDecArray;
  X16: PSmallInt; XScQ10: PInteger; SLTP: PSmallInt; SLTPQ15: PInteger; Subfr, NStates, LTPScaleQ14: Integer;
  GainsQ16, PitchL: PInteger; SignalType, DecisionDelay: Integer);
var
  I, K, Lag, GainAdjQ16, InvGainQ31, InvGainQ26, G: Integer;
begin
  Lag := PitchL[Subfr];
  G := GainsQ16[Subfr];
  if G < 1 then G := 1;
  InvGainQ31 := SilkINVERSE32VarQ(G, 47);
  InvGainQ26 := SilkRShiftRound(InvGainQ31, 5);
  for I := 0 to E.subfr_length - 1 do
    XScQ10[I] := SilkSMULWW(X16[I], InvGainQ26);
  if NSQ.rewhite_flag <> 0 then
  begin
    if Subfr = 0 then
      InvGainQ31 := SilkSMULWB(InvGainQ31, LTPScaleQ14) shl 2;
    for I := NSQ.sLTP_buf_idx - Lag - LTP_ORDER div 2 to NSQ.sLTP_buf_idx - 1 do
      SLTPQ15[I] := SilkSMULWB(InvGainQ31, SLTP[I]);
  end;
  if GainsQ16[Subfr] <> NSQ.prev_gain_Q16 then
  begin
    GainAdjQ16 := SilkDIV32VarQ(NSQ.prev_gain_Q16, GainsQ16[Subfr], 16);
    for I := NSQ.sLTP_shp_buf_idx - E.ltp_mem_length to NSQ.sLTP_shp_buf_idx - 1 do
      NSQ.sLTP_shp_Q14[I] := SilkSMULWW(GainAdjQ16, NSQ.sLTP_shp_Q14[I]);
    if (SignalType = TYPE_VOICED) and (NSQ.rewhite_flag = 0) then
      for I := NSQ.sLTP_buf_idx - Lag - LTP_ORDER div 2 to NSQ.sLTP_buf_idx - DecisionDelay - 1 do
        SLTPQ15[I] := SilkSMULWW(GainAdjQ16, SLTPQ15[I]);
    for K := 0 to NStates - 1 do
      with DD[K] do
      begin
        LF_AR_Q14 := SilkSMULWW(GainAdjQ16, LF_AR_Q14);
        Diff_Q14 := SilkSMULWW(GainAdjQ16, Diff_Q14);
        for I := 0 to NSQ_LPC_BUF_LENGTH - 1 do
          sLPC_Q14[I] := SilkSMULWW(GainAdjQ16, sLPC_Q14[I]);
        for I := 0 to MAX_SHAPE_LPC_ORDER - 1 do
          sAR2_Q14[I] := SilkSMULWW(GainAdjQ16, sAR2_Q14[I]);
        for I := 0 to DECISION_DELAY - 1 do
        begin
          Pred_Q15[I] := SilkSMULWW(GainAdjQ16, Pred_Q15[I]);
          Shape_Q14[I] := SilkSMULWW(GainAdjQ16, Shape_Q14[I]);
        end;
      end;
    NSQ.prev_gain_Q16 := GainsQ16[Subfr];
  end;
end;

procedure NoiseShapeQuantizerDelDec(var NSQ: TSilkNSQState; var DD: TDelDecArray; SignalType: Integer;
  XQ10: PInteger; Pulses: PShortInt; XQ: PSmallInt; SLTPQ15: PInteger; DelayedGainQ10: PInteger;
  AQ12, BQ14, ARShpQ13: PSmallInt; Lag, HarmShapeFIRPackedQ14, TiltQ14, LFShpQ14, GainQ16, LambdaQ10,
  OffsetQ10, Length, Subfr, ShapingLPCOrder, PredictLPCOrder, WarpingQ16, NStates: Integer;
  var SmplBufIdx: Integer; DecisionDelay: Integer);
var
  I, J, K, WinnerInd, RDminInd, RDmaxInd, LastSmpleIdx: Integer;
  WinnerRandState: Integer;
  LTPPredQ14, LPCPredQ14, NARQ14, NLTPQ14, NLFQ14, RQ10, RrQ10, Rd1Q10, Rd2Q10, RDminQ10, RDmaxQ10: Integer;
  Q1Q10, Q2Q10, ExcQ14, LPCExcQ14, XqQ14, GainQ10, Tmp1, Tmp2, SLFARShpQ14: Integer;
  PredLagPtr, ShpLagPtr, PsLPCQ14: PInteger;
  SS: array[0..MAX_DEL_DEC_STATES - 1] of TNSQSamplePair;
  PDD: PNSQDelDec;
begin
  ShpLagPtr := @NSQ.sLTP_shp_Q14[NSQ.sLTP_shp_buf_idx - Lag + HARM_SHAPE_FIR_TAPS div 2];
  PredLagPtr := SLTPQ15 + (NSQ.sLTP_buf_idx - Lag + LTP_ORDER div 2);
  GainQ10 := Sar32(GainQ16, 6);
  for I := 0 to Length - 1 do
  begin
    if SignalType = TYPE_VOICED then
    begin
      LTPPredQ14 := 2;
      LTPPredQ14 := SilkSMLAWB(LTPPredQ14, PredLagPtr[0], BQ14[0]);
      LTPPredQ14 := SilkSMLAWB(LTPPredQ14, PredLagPtr[-1], BQ14[1]);
      LTPPredQ14 := SilkSMLAWB(LTPPredQ14, PredLagPtr[-2], BQ14[2]);
      LTPPredQ14 := SilkSMLAWB(LTPPredQ14, PredLagPtr[-3], BQ14[3]);
      LTPPredQ14 := SilkSMLAWB(LTPPredQ14, PredLagPtr[-4], BQ14[4]);
      LTPPredQ14 := LTPPredQ14 shl 1;
      Inc(PredLagPtr);
    end
    else
      LTPPredQ14 := 0;
    if Lag > 0 then
    begin
      NLTPQ14 := SilkSMULWB(SilkAddSat32(ShpLagPtr[0], ShpLagPtr[-2]), HarmShapeFIRPackedQ14);
      NLTPQ14 := SilkSMLAWT(NLTPQ14, ShpLagPtr[-1], HarmShapeFIRPackedQ14);
      NLTPQ14 := LTPPredQ14 - (NLTPQ14 shl 2);
      Inc(ShpLagPtr);
    end
    else
      NLTPQ14 := 0;
    for K := 0 to NStates - 1 do
    begin
      PDD := @DD[K];
      PDD.Seed := SilkRand(PDD.Seed);
      PsLPCQ14 := @PDD.sLPC_Q14[NSQ_LPC_BUF_LENGTH - 1 + I];
      LPCPredQ14 := ShortPrediction(PsLPCQ14, AQ12, PredictLPCOrder);
      LPCPredQ14 := LPCPredQ14 shl 4;
      Tmp2 := SilkSMLAWB(PDD.Diff_Q14, PDD.sAR2_Q14[0], WarpingQ16);
      Tmp1 := SilkSMLAWB(PDD.sAR2_Q14[0], PDD.sAR2_Q14[1] - Tmp2, WarpingQ16);
      PDD.sAR2_Q14[0] := Tmp2;
      NARQ14 := Sar32(ShapingLPCOrder, 1);
      NARQ14 := SilkSMLAWB(NARQ14, Tmp2, ARShpQ13[0]);
      J := 2;
      while J < ShapingLPCOrder do
      begin
        Tmp2 := SilkSMLAWB(PDD.sAR2_Q14[J - 1], PDD.sAR2_Q14[J] - Tmp1, WarpingQ16);
        PDD.sAR2_Q14[J - 1] := Tmp1;
        NARQ14 := SilkSMLAWB(NARQ14, Tmp1, ARShpQ13[J - 1]);
        Tmp1 := SilkSMLAWB(PDD.sAR2_Q14[J], PDD.sAR2_Q14[J + 1] - Tmp2, WarpingQ16);
        PDD.sAR2_Q14[J] := Tmp2;
        NARQ14 := SilkSMLAWB(NARQ14, Tmp2, ARShpQ13[J]);
        Inc(J, 2);
      end;
      PDD.sAR2_Q14[ShapingLPCOrder - 1] := Tmp1;
      NARQ14 := SilkSMLAWB(NARQ14, Tmp1, ARShpQ13[ShapingLPCOrder - 1]);
      NARQ14 := NARQ14 shl 1;
      NARQ14 := SilkSMLAWB(NARQ14, PDD.LF_AR_Q14, TiltQ14);
      NARQ14 := NARQ14 shl 2;
      NLFQ14 := SilkSMULWB(PDD.Shape_Q14[SmplBufIdx], LFShpQ14);
      NLFQ14 := SilkSMLAWT(NLFQ14, PDD.LF_AR_Q14, LFShpQ14);
      NLFQ14 := NLFQ14 shl 2;
      Tmp1 := SilkAddSat32(NARQ14, NLFQ14);
      Tmp2 := NLTPQ14 + LPCPredQ14;
      Tmp1 := SilkSubSat32(Tmp2, Tmp1);
      Tmp1 := SilkRShiftRound(Tmp1, 4);
      RQ10 := XQ10[I] - Tmp1;
      if PDD.Seed < 0 then RQ10 := -RQ10;
      RQ10 := SilkLimit(RQ10, -(31 shl 10), 30 shl 10);
      QuantCandidates(RQ10, OffsetQ10, LambdaQ10, Q1Q10, Q2Q10, Rd1Q10, Rd2Q10);
      RrQ10 := RQ10 - Q1Q10;
      Rd1Q10 := Sar32(SilkSMLABB(Rd1Q10, RrQ10, RrQ10), 10);
      RrQ10 := RQ10 - Q2Q10;
      Rd2Q10 := Sar32(SilkSMLABB(Rd2Q10, RrQ10, RrQ10), 10);
      if Rd1Q10 < Rd2Q10 then
      begin
        SS[K][0].RD_Q10 := PDD.RD_Q10 + Rd1Q10;
        SS[K][1].RD_Q10 := PDD.RD_Q10 + Rd2Q10;
        SS[K][0].Q_Q10 := Q1Q10;
        SS[K][1].Q_Q10 := Q2Q10;
      end
      else
      begin
        SS[K][0].RD_Q10 := PDD.RD_Q10 + Rd2Q10;
        SS[K][1].RD_Q10 := PDD.RD_Q10 + Rd1Q10;
        SS[K][0].Q_Q10 := Q2Q10;
        SS[K][1].Q_Q10 := Q1Q10;
      end;
      for J := 0 to 1 do
      begin
        ExcQ14 := SS[K][J].Q_Q10 shl 4;
        if PDD.Seed < 0 then ExcQ14 := -ExcQ14;
        LPCExcQ14 := ExcQ14 + LTPPredQ14;
        XqQ14 := LPCExcQ14 + LPCPredQ14;
        SS[K][J].Diff_Q14 := XqQ14 - (XQ10[I] shl 4);
        SLFARShpQ14 := SS[K][J].Diff_Q14 - NARQ14;
        SS[K][J].sLTP_shp_Q14 := SilkSubSat32(SLFARShpQ14, NLFQ14);
        SS[K][J].LF_AR_Q14 := SLFARShpQ14;
        SS[K][J].LPC_exc_Q14 := LPCExcQ14;
        SS[K][J].xq_Q14 := XqQ14;
      end;
    end;
    SmplBufIdx := (SmplBufIdx - 1) mod DECISION_DELAY;
    if SmplBufIdx < 0 then Inc(SmplBufIdx, DECISION_DELAY);
    LastSmpleIdx := (SmplBufIdx + DecisionDelay) mod DECISION_DELAY;
    RDminQ10 := SS[0][0].RD_Q10;
    WinnerInd := 0;
    for K := 1 to NStates - 1 do
      if SS[K][0].RD_Q10 < RDminQ10 then
      begin
        RDminQ10 := SS[K][0].RD_Q10;
        WinnerInd := K;
      end;
    WinnerRandState := DD[WinnerInd].RandState[LastSmpleIdx];
    for K := 0 to NStates - 1 do
      if DD[K].RandState[LastSmpleIdx] <> WinnerRandState then
      begin
        SS[K][0].RD_Q10 := SS[K][0].RD_Q10 + (SILK_INT32_MAX shr 4);
        SS[K][1].RD_Q10 := SS[K][1].RD_Q10 + (SILK_INT32_MAX shr 4);
      end;
    RDmaxQ10 := SS[0][0].RD_Q10;
    RDminQ10 := SS[0][1].RD_Q10;
    RDmaxInd := 0;
    RDminInd := 0;
    for K := 1 to NStates - 1 do
    begin
      if SS[K][0].RD_Q10 > RDmaxQ10 then
      begin
        RDmaxQ10 := SS[K][0].RD_Q10;
        RDmaxInd := K;
      end;
      if SS[K][1].RD_Q10 < RDminQ10 then
      begin
        RDminQ10 := SS[K][1].RD_Q10;
        RDminInd := K;
      end;
    end;
    if RDminQ10 < RDmaxQ10 then
    begin
      Move(PInteger(@DD[RDminInd])[I], PInteger(@DD[RDmaxInd])[I], SizeOf(TNSQDelDec) - I * SizeOf(Integer));
      SS[RDmaxInd][0] := SS[RDminInd][1];
    end;
    PDD := @DD[WinnerInd];
    if (Subfr > 0) or (I >= DecisionDelay) then
    begin
      Pulses[I - DecisionDelay] := ShortInt(SilkRShiftRound(PDD.Q_Q10[LastSmpleIdx], 10));
      XQ[I - DecisionDelay] := SilkSat16S(SilkRShiftRound(
        SilkSMULWW(PDD.Xq_Q14[LastSmpleIdx], DelayedGainQ10[LastSmpleIdx]), 8));
      NSQ.sLTP_shp_Q14[NSQ.sLTP_shp_buf_idx - DecisionDelay] := PDD.Shape_Q14[LastSmpleIdx];
      SLTPQ15[NSQ.sLTP_buf_idx - DecisionDelay] := PDD.Pred_Q15[LastSmpleIdx];
    end;
    Inc(NSQ.sLTP_shp_buf_idx);
    Inc(NSQ.sLTP_buf_idx);
    for K := 0 to NStates - 1 do
    begin
      PDD := @DD[K];
      PDD.LF_AR_Q14 := SS[K][0].LF_AR_Q14;
      PDD.Diff_Q14 := SS[K][0].Diff_Q14;
      PDD.sLPC_Q14[NSQ_LPC_BUF_LENGTH + I] := SS[K][0].xq_Q14;
      PDD.Xq_Q14[SmplBufIdx] := SS[K][0].xq_Q14;
      PDD.Q_Q10[SmplBufIdx] := SS[K][0].Q_Q10;
      PDD.Pred_Q15[SmplBufIdx] := SS[K][0].LPC_exc_Q14 shl 1;
      PDD.Shape_Q14[SmplBufIdx] := SS[K][0].sLTP_shp_Q14;
      PDD.Seed := PDD.Seed + SilkRShiftRound(SS[K][0].Q_Q10, 10);
      PDD.RandState[SmplBufIdx] := PDD.Seed;
      PDD.RD_Q10 := SS[K][0].RD_Q10;
    end;
    DelayedGainQ10[SmplBufIdx] := GainQ10;
  end;
  for K := 0 to NStates - 1 do
    Move(DD[K].sLPC_Q14[Length], DD[K].sLPC_Q14[0], NSQ_LPC_BUF_LENGTH * SizeOf(Integer));
end;

procedure SilkNSQDelDec(const E: TSilkEncoderState; var NSQ: TSilkNSQState; var Indices: TSideInfoIndices;
  X16: PSmallInt; Pulses: PShortInt; PredCoefQ12: PSmallInt; LTPCoefQ14: PSmallInt; ARQ13: PSmallInt;
  HarmShapeGainQ14, TiltQ14: PInteger; LFShpQ14, GainsQ16: PInteger; PitchL: PInteger;
  LambdaQ10, LTPScaleQ14: Integer);
var
  I, K, Lag, StartIdx, LSFInterpolationFlag, WinnerInd, Subfr: Integer;
  LastSmpleIdx, SmplBufIdx, DecisionDelay: Integer;
  AQ12, BQ14, ARShpQ13: PSmallInt;
  PXQ: PSmallInt;
  SLTPQ15: array[0..2 * MAX_FRAME_LENGTH - 1] of Integer;
  SLTP: array[0..2 * MAX_FRAME_LENGTH - 1] of SmallInt;
  HarmShapeFIRPackedQ14, OffsetQ10, RDminQ10, GainQ10: Integer;
  XScQ10: array[0..MAX_SUB_FRAME_LENGTH - 1] of Integer;
  DelayedGainQ10: array[0..DECISION_DELAY - 1] of Integer;
  DD: TDelDecArray;
  PDD: PNSQDelDec;
begin
  Lag := NSQ.lagPrev;
  FillChar(DD, SizeOf(TNSQDelDec) * E.nStatesDelayedDecision, 0);
  for K := 0 to E.nStatesDelayedDecision - 1 do
  begin
    PDD := @DD[K];
    PDD.Seed := (K + Indices.Seed) and 3;
    PDD.SeedInit := PDD.Seed;
    PDD.RD_Q10 := 0;
    PDD.LF_AR_Q14 := NSQ.sLF_AR_shp_Q14;
    PDD.Diff_Q14 := NSQ.sDiff_shp_Q14;
    PDD.Shape_Q14[0] := NSQ.sLTP_shp_Q14[E.ltp_mem_length - 1];
    Move(NSQ.sLPC_Q14[0], PDD.sLPC_Q14[0], NSQ_LPC_BUF_LENGTH * SizeOf(Integer));
    Move(NSQ.sAR2_Q14[0], PDD.sAR2_Q14[0], SizeOf(NSQ.sAR2_Q14));
  end;
  OffsetQ10 := SE_QUANTIZATION_OFFSETS_Q10[Indices.signalType shr 1, Indices.quantOffsetType];
  SmplBufIdx := 0;
  if DECISION_DELAY < E.subfr_length then DecisionDelay := DECISION_DELAY else DecisionDelay := E.subfr_length;
  if Indices.signalType = TYPE_VOICED then
  begin
    for K := 0 to E.nb_subfr - 1 do
      if PitchL[K] - LTP_ORDER div 2 - 1 < DecisionDelay then
        DecisionDelay := PitchL[K] - LTP_ORDER div 2 - 1;
  end
  else if Lag > 0 then
  begin
    if Lag - LTP_ORDER div 2 - 1 < DecisionDelay then
      DecisionDelay := Lag - LTP_ORDER div 2 - 1;
  end;
  if Indices.NLSFInterpCoef_Q2 = 4 then LSFInterpolationFlag := 0 else LSFInterpolationFlag := 1;
  FillChar(DelayedGainQ10, SizeOf(DelayedGainQ10), 0);
  PXQ := @NSQ.xq[E.ltp_mem_length];
  NSQ.sLTP_shp_buf_idx := E.ltp_mem_length;
  NSQ.sLTP_buf_idx := E.ltp_mem_length;
  Subfr := 0;
  for K := 0 to E.nb_subfr - 1 do
  begin
    AQ12 := PredCoefQ12 + ((K shr 1) or (1 - LSFInterpolationFlag)) * MAX_LPC_ORDER;
    BQ14 := LTPCoefQ14 + K * LTP_ORDER;
    ARShpQ13 := ARQ13 + K * MAX_SHAPE_LPC_ORDER;
    HarmShapeFIRPackedQ14 := Sar32(HarmShapeGainQ14[K], 2);
    HarmShapeFIRPackedQ14 := HarmShapeFIRPackedQ14 or (Sar32(HarmShapeGainQ14[K], 1) shl 16);
    NSQ.rewhite_flag := 0;
    if Indices.signalType = TYPE_VOICED then
    begin
      Lag := PitchL[K];
      if (K and (3 - (LSFInterpolationFlag shl 1))) = 0 then
      begin
        if K = 2 then
        begin
          RDminQ10 := DD[0].RD_Q10;
          WinnerInd := 0;
          for I := 1 to E.nStatesDelayedDecision - 1 do
            if DD[I].RD_Q10 < RDminQ10 then
            begin
              RDminQ10 := DD[I].RD_Q10;
              WinnerInd := I;
            end;
          for I := 0 to E.nStatesDelayedDecision - 1 do
            if I <> WinnerInd then
              DD[I].RD_Q10 := DD[I].RD_Q10 + (SILK_INT32_MAX shr 4);
          PDD := @DD[WinnerInd];
          LastSmpleIdx := SmplBufIdx + DecisionDelay;
          for I := 0 to DecisionDelay - 1 do
          begin
            LastSmpleIdx := (LastSmpleIdx - 1) mod DECISION_DELAY;
            if LastSmpleIdx < 0 then Inc(LastSmpleIdx, DECISION_DELAY);
            Pulses[I - DecisionDelay] := ShortInt(SilkRShiftRound(PDD.Q_Q10[LastSmpleIdx], 10));
            PXQ[I - DecisionDelay] := SilkSat16S(SilkRShiftRound(
              SilkSMULWW(PDD.Xq_Q14[LastSmpleIdx], GainsQ16[1]), 14));
            NSQ.sLTP_shp_Q14[NSQ.sLTP_shp_buf_idx - DecisionDelay + I] := PDD.Shape_Q14[LastSmpleIdx];
          end;
          Subfr := 0;
        end;
        StartIdx := E.ltp_mem_length - Lag - E.predictLPCOrder - LTP_ORDER div 2;
        SilkLPCAnalysisFilter(@SLTP[StartIdx], @NSQ.xq[StartIdx + K * E.subfr_length], AQ12,
          E.ltp_mem_length - StartIdx, E.predictLPCOrder);
        NSQ.sLTP_buf_idx := E.ltp_mem_length;
        NSQ.rewhite_flag := 1;
      end;
    end;
    NSQDelDecScaleStates(E, NSQ, DD, X16, @XScQ10[0], @SLTP[0], @SLTPQ15[0], K, E.nStatesDelayedDecision,
      LTPScaleQ14, GainsQ16, PitchL, Indices.signalType, DecisionDelay);
    NoiseShapeQuantizerDelDec(NSQ, DD, Indices.signalType, @XScQ10[0], Pulses, PXQ, @SLTPQ15[0],
      @DelayedGainQ10[0], AQ12, BQ14, ARShpQ13, Lag, HarmShapeFIRPackedQ14, TiltQ14[K], LFShpQ14[K],
      GainsQ16[K], LambdaQ10, OffsetQ10, E.subfr_length, Subfr, E.shapingLPCOrder, E.predictLPCOrder,
      E.warping_Q16, E.nStatesDelayedDecision, SmplBufIdx, DecisionDelay);
    Inc(Subfr);
    Inc(X16, E.subfr_length);
    Inc(Pulses, E.subfr_length);
    Inc(PXQ, E.subfr_length);
  end;
  RDminQ10 := DD[0].RD_Q10;
  WinnerInd := 0;
  for K := 1 to E.nStatesDelayedDecision - 1 do
    if DD[K].RD_Q10 < RDminQ10 then
    begin
      RDminQ10 := DD[K].RD_Q10;
      WinnerInd := K;
    end;
  PDD := @DD[WinnerInd];
  Indices.Seed := ShortInt(PDD.SeedInit);
  LastSmpleIdx := SmplBufIdx + DecisionDelay;
  GainQ10 := Sar32(GainsQ16[E.nb_subfr - 1], 6);
  for I := 0 to DecisionDelay - 1 do
  begin
    LastSmpleIdx := (LastSmpleIdx - 1) mod DECISION_DELAY;
    if LastSmpleIdx < 0 then Inc(LastSmpleIdx, DECISION_DELAY);
    Pulses[I - DecisionDelay] := ShortInt(SilkRShiftRound(PDD.Q_Q10[LastSmpleIdx], 10));
    PXQ[I - DecisionDelay] := SilkSat16S(SilkRShiftRound(SilkSMULWW(PDD.Xq_Q14[LastSmpleIdx], GainQ10), 8));
    NSQ.sLTP_shp_Q14[NSQ.sLTP_shp_buf_idx - DecisionDelay + I] := PDD.Shape_Q14[LastSmpleIdx];
  end;
  Move(PDD.sLPC_Q14[E.subfr_length], NSQ.sLPC_Q14[0], NSQ_LPC_BUF_LENGTH * SizeOf(Integer));
  Move(PDD.sAR2_Q14[0], NSQ.sAR2_Q14[0], SizeOf(PDD.sAR2_Q14));
  NSQ.sLF_AR_shp_Q14 := PDD.LF_AR_Q14;
  NSQ.sDiff_shp_Q14 := PDD.Diff_Q14;
  NSQ.lagPrev := PitchL[E.nb_subfr - 1];
  Move(NSQ.xq[E.frame_length], NSQ.xq[0], E.ltp_mem_length * SizeOf(SmallInt));
  Move(NSQ.sLTP_shp_Q14[E.frame_length], NSQ.sLTP_shp_Q14[0], E.ltp_mem_length * SizeOf(Integer));
end;

end.
