unit OpusSilkEncNLSF;

{
  OpusSilkEncNLSF.pas - SILK encoder NLSF analysis and quantization

  Port of libopus 1.5.2 silk/A2NLSF.c, NLSF2A.c, LPC_inv_pred_gain.c,
  NLSF_encode.c, NLSF_VQ.c, NLSF_del_dec_quant.c, NLSF_VQ_weights_laroia.c,
  NLSF_unpack.c, NLSF_decode.c, process_NLSFs.c.
  Copyright (c) 2006-2011 Skype Limited; Xiph.Org Foundation.

  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  OpusEntDec, OpusSilkMath, OpusSilkEncTables, OpusSilkEncDefs, OpusSilkEncCore;

function  SilkLPCInversePredGainEnc(AQ12: PSmallInt; Order: Integer): Integer;
procedure SilkNLSF2AEnc(AQ12: PSmallInt; NLSF: PSmallInt; D: Integer);
procedure SilkA2NLSF(NLSF: PSmallInt; AQ16: PInteger; D: Integer);
procedure SilkNLSFUnpackEnc(EcIx: PSmallInt; PredQ8: PByte; const CB: TSilkNLSFCB; CB1Index: Integer);
procedure SilkNLSFDecodeEnc(PNLSFQ15: PSmallInt; NLSFIndices: PShortInt; const CB: TSilkNLSFCB);
function  SilkNLSFEncode(NLSFIndices: PShortInt; PNLSFQ15: PSmallInt; const CB: TSilkNLSFCB;
  PWQ2: PSmallInt; NLSFMuQ20, NSurvivors, SignalType: Integer): Integer;
procedure SilkProcessNLSFs(var E: TSilkEncoderState; PredCoefQ12: PSmallInt; PNLSFQ15: PSmallInt;
  PrevNLSFqQ15: PSmallInt);

implementation

const
  QA = 24;
  A_LIMIT = 16773022;            // SILK_FIX_CONST(0.99975, QA)
  MIN_INV_GAIN_Q30 = 107374;     // SILK_FIX_CONST(1.0f / MAX_PREDICTION_POWER_GAIN, 30)
  NLSF_QUANT_LEVEL_ADJ_Q10 = 102;

function Mul32FracQ(A32, B32: Integer; Q: Integer): Integer; inline;
begin
  Result := Integer(SilkRShiftRound64(SilkSMULL(A32, B32), Q));
end;

function LPCInversePredGainQA(AQA: PInteger; Order: Integer): Integer;
var
  K, N, Mult2Q: Integer;
  InvGainQ30, RcQ31, RcMult1Q30, RcMult2, Tmp1, Tmp2: Integer;
  Tmp64: Int64;
begin
  InvGainQ30 := 1 shl 30;
  for K := Order - 1 downto 1 do
  begin
    if (AQA[K] > A_LIMIT) or (AQA[K] < -A_LIMIT) then Exit(0);
    RcQ31 := -(AQA[K] shl (31 - QA));
    RcMult1Q30 := (1 shl 30) - SilkSMMUL(RcQ31, RcQ31);
    InvGainQ30 := SilkSMMUL(InvGainQ30, RcMult1Q30) shl 2;
    if InvGainQ30 < MIN_INV_GAIN_Q30 then Exit(0);
    Mult2Q := 32 - SilkCLZ32(SilkAbs(RcMult1Q30));
    RcMult2 := SilkINVERSE32VarQ(RcMult1Q30, Mult2Q + 30);
    for N := 0 to ((K + 1) shr 1) - 1 do
    begin
      Tmp1 := AQA[N];
      Tmp2 := AQA[K - N - 1];
      Tmp64 := SilkRShiftRound64(SilkSMULL(SilkSubSat32(Tmp1, Mul32FracQ(Tmp2, RcQ31, 31)), RcMult2), Mult2Q);
      if (Tmp64 > SILK_INT32_MAX) or (Tmp64 < SILK_INT32_MIN) then Exit(0);
      AQA[N] := Integer(Tmp64);
      Tmp64 := SilkRShiftRound64(SilkSMULL(SilkSubSat32(Tmp2, Mul32FracQ(Tmp1, RcQ31, 31)), RcMult2), Mult2Q);
      if (Tmp64 > SILK_INT32_MAX) or (Tmp64 < SILK_INT32_MIN) then Exit(0);
      AQA[K - N - 1] := Integer(Tmp64);
    end;
  end;
  if (AQA[0] > A_LIMIT) or (AQA[0] < -A_LIMIT) then Exit(0);
  RcQ31 := -(AQA[0] shl (31 - QA));
  RcMult1Q30 := (1 shl 30) - SilkSMMUL(RcQ31, RcQ31);
  InvGainQ30 := SilkSMMUL(InvGainQ30, RcMult1Q30) shl 2;
  if InvGainQ30 < MIN_INV_GAIN_Q30 then Exit(0);
  Result := InvGainQ30;
end;

function SilkLPCInversePredGainEnc(AQ12: PSmallInt; Order: Integer): Integer;
var
  K, DCResp: Integer;
  AtmpQA: array[0..MAX_LPC_ORDER - 1] of Integer;
begin
  DCResp := 0;
  for K := 0 to Order - 1 do
  begin
    DCResp := DCResp + AQ12[K];
    AtmpQA[K] := Integer(AQ12[K]) shl (QA - 12);
  end;
  if DCResp >= 4096 then Exit(0);
  Result := LPCInversePredGainQA(@AtmpQA[0], Order);
end;

// ---------------------------------------------------------------------------
// NLSF2A
// ---------------------------------------------------------------------------

const
  NLSF_QA = 16;

procedure NLSF2AFindPoly(OutP: PInteger; CLSF: PInteger; Dd: Integer);
var
  K, N, Ftmp: Integer;
begin
  OutP[0] := 1 shl NLSF_QA;
  OutP[1] := -CLSF[0];
  for K := 1 to Dd - 1 do
  begin
    Ftmp := CLSF[2 * K];
    OutP[K + 1] := (OutP[K - 1] shl 1) - Integer(SilkRShiftRound64(SilkSMULL(Ftmp, OutP[K]), NLSF_QA));
    for N := K downto 2 do
      OutP[N] := OutP[N] + OutP[N - 2] - Integer(SilkRShiftRound64(SilkSMULL(Ftmp, OutP[N - 1]), NLSF_QA));
    OutP[1] := OutP[1] - Ftmp;
  end;
end;

procedure SilkNLSF2AEnc(AQ12: PSmallInt; NLSF: PSmallInt; D: Integer);
const
  Ordering16: array[0..15] of Byte = (0, 15, 8, 7, 4, 11, 12, 3, 2, 13, 10, 5, 6, 9, 14, 1);
  Ordering10: array[0..9] of Byte = (0, 9, 6, 3, 4, 5, 8, 1, 2, 7);
var
  Ordering: PByte;
  K, I, Dd: Integer;
  CosLSFQA: array[0..MAX_LPC_ORDER - 1] of Integer;
  P, Q: array[0..MAX_LPC_ORDER div 2] of Integer;
  Ptmp, Qtmp, FInt, FFrac, CosVal, Delta: Integer;
  A32QA1: array[0..MAX_LPC_ORDER - 1] of Integer;
begin
  if D = 16 then Ordering := @Ordering16[0] else Ordering := @Ordering10[0];
  for K := 0 to D - 1 do
  begin
    FInt := Sar32(NLSF[K], 15 - 7);
    FFrac := NLSF[K] - (FInt shl (15 - 7));
    CosVal := SE_LSFCOSTAB_FIX_Q12[FInt];
    Delta := SE_LSFCOSTAB_FIX_Q12[FInt + 1] - CosVal;
    CosLSFQA[Ordering[K]] := SilkRShiftRound((CosVal shl 8) + Delta * FFrac, 20 - NLSF_QA);
  end;
  Dd := Sar32(D, 1);
  NLSF2AFindPoly(@P[0], @CosLSFQA[0], Dd);
  NLSF2AFindPoly(@Q[0], @CosLSFQA[1], Dd);
  for K := 0 to Dd - 1 do
  begin
    Ptmp := P[K + 1] + P[K];
    Qtmp := Q[K + 1] - Q[K];
    A32QA1[K] := -Qtmp - Ptmp;
    A32QA1[D - K - 1] := Qtmp - Ptmp;
  end;
  SilkLPCFit(AQ12, @A32QA1[0], 12, NLSF_QA + 1, D);
  I := 0;
  while (SilkLPCInversePredGainEnc(AQ12, D) = 0) and (I < MAX_LPC_STABILIZE_ITERATIONS) do
  begin
    SilkBwExpander32(@A32QA1[0], D, 65536 - (2 shl I));
    for K := 0 to D - 1 do
      AQ12[K] := SmallInt(SilkRShiftRound(A32QA1[K], NLSF_QA + 1 - 12));
    Inc(I);
  end;
end;

// ---------------------------------------------------------------------------
// A2NLSF
// ---------------------------------------------------------------------------

const
  BIN_DIV_STEPS_A2NLSF_FIX = 3;
  MAX_ITERATIONS_A2NLSF_FIX = 16;

procedure A2NLSFTransPoly(P: PInteger; Dd: Integer);
var
  K, N: Integer;
begin
  for K := 2 to Dd do
  begin
    for N := Dd downto K + 1 do
      P[N - 2] := P[N - 2] - P[N];
    P[K - 2] := P[K - 2] - (P[K] shl 1);
  end;
end;

function A2NLSFEvalPoly(P: PInteger; X, Dd: Integer): Integer;
var
  N, XQ16: Integer;
begin
  Result := P[Dd];
  XQ16 := X shl 4;
  for N := Dd - 1 downto 0 do
    Result := SilkSMLAWW(P[N], Result, XQ16);
end;

procedure A2NLSFInit(AQ16: PInteger; P, Q: PInteger; Dd: Integer);
var
  K: Integer;
begin
  P[Dd] := 1 shl 16;
  Q[Dd] := 1 shl 16;
  for K := 0 to Dd - 1 do
  begin
    P[K] := -AQ16[Dd - K - 1] - AQ16[Dd + K];
    Q[K] := -AQ16[Dd - K - 1] + AQ16[Dd + K];
  end;
  for K := Dd downto 1 do
  begin
    P[K - 1] := P[K - 1] - P[K];
    Q[K - 1] := Q[K - 1] + Q[K];
  end;
  A2NLSFTransPoly(P, Dd);
  A2NLSFTransPoly(Q, Dd);
end;

procedure SilkA2NLSF(NLSF: PSmallInt; AQ16: PInteger; D: Integer);
var
  I, K, M, Dd, RootIx, FFrac: Integer;
  XLo, XHi, XMid, YLo, YHi, YMid, Thr, Nom, Den: Integer;
  P, Q: array[0..MAX_LPC_ORDER div 2] of Integer;
  PQ: array[0..1] of PInteger;
  PP: PInteger;
begin
  PQ[0] := @P[0];
  PQ[1] := @Q[0];
  Dd := Sar32(D, 1);
  A2NLSFInit(AQ16, @P[0], @Q[0], Dd);
  PP := @P[0];
  XLo := SE_LSFCOSTAB_FIX_Q12[0];
  YLo := A2NLSFEvalPoly(PP, XLo, Dd);
  if YLo < 0 then
  begin
    NLSF[0] := 0;
    PP := @Q[0];
    YLo := A2NLSFEvalPoly(PP, XLo, Dd);
    RootIx := 1;
  end
  else
    RootIx := 0;
  K := 1;
  I := 0;
  Thr := 0;
  while True do
  begin
    XHi := SE_LSFCOSTAB_FIX_Q12[K];
    YHi := A2NLSFEvalPoly(PP, XHi, Dd);
    if ((YLo <= 0) and (YHi >= Thr)) or ((YLo >= 0) and (YHi <= -Thr)) then
    begin
      if YHi = 0 then Thr := 1 else Thr := 0;
      FFrac := -256;
      for M := 0 to BIN_DIV_STEPS_A2NLSF_FIX - 1 do
      begin
        XMid := SilkRShiftRound(XLo + XHi, 1);
        YMid := A2NLSFEvalPoly(PP, XMid, Dd);
        if ((YLo <= 0) and (YMid >= 0)) or ((YLo >= 0) and (YMid <= 0)) then
        begin
          XHi := XMid;
          YHi := YMid;
        end
        else
        begin
          XLo := XMid;
          YLo := YMid;
          FFrac := FFrac + Sar32(128, M);
        end;
      end;
      if SilkAbs(YLo) < 65536 then
      begin
        Den := YLo - YHi;
        Nom := (YLo shl (8 - BIN_DIV_STEPS_A2NLSF_FIX)) + Sar32(Den, 1);
        if Den <> 0 then
          FFrac := FFrac + Nom div Den;
      end
      else
        FFrac := FFrac + YLo div Sar32(YLo - YHi, 8 - BIN_DIV_STEPS_A2NLSF_FIX);
      M := (K shl 8) + FFrac;
      if M > SILK_INT16_MAX then M := SILK_INT16_MAX;
      NLSF[RootIx] := SmallInt(M);
      Inc(RootIx);
      if RootIx >= D then Break;
      PP := PQ[RootIx and 1];
      XLo := SE_LSFCOSTAB_FIX_Q12[K - 1];
      YLo := (1 - (RootIx and 2)) shl 12;
    end
    else
    begin
      Inc(K);
      XLo := XHi;
      YLo := YHi;
      Thr := 0;
      if K > LSF_COS_TAB_SZ_FIX then
      begin
        Inc(I);
        if I > MAX_ITERATIONS_A2NLSF_FIX then
        begin
          NLSF[0] := SmallInt((1 shl 15) div (D + 1));
          for K := 1 to D - 1 do
            NLSF[K] := SmallInt(NLSF[K - 1] + NLSF[0]);
          Exit;
        end;
        SilkBwExpander32(AQ16, D, 65536 - (1 shl I));
        A2NLSFInit(AQ16, @P[0], @Q[0], Dd);
        PP := @P[0];
        XLo := SE_LSFCOSTAB_FIX_Q12[0];
        YLo := A2NLSFEvalPoly(PP, XLo, Dd);
        if YLo < 0 then
        begin
          NLSF[0] := 0;
          PP := @Q[0];
          YLo := A2NLSFEvalPoly(PP, XLo, Dd);
          RootIx := 1;
        end
        else
          RootIx := 0;
        K := 1;
      end;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// NLSF quantization
// ---------------------------------------------------------------------------

procedure NLSFVQWeightsLaroia(PNLSFW: PSmallInt; PNLSF: PSmallInt; D: Integer);
var
  K, Tmp1, Tmp2, T: Integer;
begin
  Tmp1 := PNLSF[0];
  if Tmp1 < 1 then Tmp1 := 1;
  Tmp1 := (1 shl (15 + NLSF_W_Q)) div Tmp1;
  Tmp2 := PNLSF[1] - PNLSF[0];
  if Tmp2 < 1 then Tmp2 := 1;
  Tmp2 := (1 shl (15 + NLSF_W_Q)) div Tmp2;
  T := Tmp1 + Tmp2;
  if T > SILK_INT16_MAX then T := SILK_INT16_MAX;
  PNLSFW[0] := SmallInt(T);
  K := 1;
  while K < D - 1 do
  begin
    Tmp1 := PNLSF[K + 1] - PNLSF[K];
    if Tmp1 < 1 then Tmp1 := 1;
    Tmp1 := (1 shl (15 + NLSF_W_Q)) div Tmp1;
    T := Tmp1 + Tmp2;
    if T > SILK_INT16_MAX then T := SILK_INT16_MAX;
    PNLSFW[K] := SmallInt(T);
    Tmp2 := PNLSF[K + 2] - PNLSF[K + 1];
    if Tmp2 < 1 then Tmp2 := 1;
    Tmp2 := (1 shl (15 + NLSF_W_Q)) div Tmp2;
    T := Tmp1 + Tmp2;
    if T > SILK_INT16_MAX then T := SILK_INT16_MAX;
    PNLSFW[K + 1] := SmallInt(T);
    Inc(K, 2);
  end;
  Tmp1 := (1 shl 15) - PNLSF[D - 1];
  if Tmp1 < 1 then Tmp1 := 1;
  Tmp1 := (1 shl (15 + NLSF_W_Q)) div Tmp1;
  T := Tmp1 + Tmp2;
  if T > SILK_INT16_MAX then T := SILK_INT16_MAX;
  PNLSFW[D - 1] := SmallInt(T);
end;

procedure NLSFVQ(ErrQ24: PInteger; InQ15: PSmallInt; PCBQ8: PByte; PWghtQ9: PSmallInt; K, LPCOrder: Integer);
var
  I, M, DiffQ15, DiffwQ24, SumErrorQ24, PredQ24: Integer;
  CB: PByte;
  W: PSmallInt;
begin
  CB := PCBQ8;
  W := PWghtQ9;
  for I := 0 to K - 1 do
  begin
    SumErrorQ24 := 0;
    PredQ24 := 0;
    M := LPCOrder - 2;
    while M >= 0 do
    begin
      DiffQ15 := InQ15[M + 1] - (Integer(CB[M + 1]) shl 7);
      DiffwQ24 := SilkSMULBB(DiffQ15, W[M + 1]);
      SumErrorQ24 := SumErrorQ24 + SilkAbs(DiffwQ24 - Sar32(PredQ24, 1));
      PredQ24 := DiffwQ24;
      DiffQ15 := InQ15[M] - (Integer(CB[M]) shl 7);
      DiffwQ24 := SilkSMULBB(DiffQ15, W[M]);
      SumErrorQ24 := SumErrorQ24 + SilkAbs(DiffwQ24 - Sar32(PredQ24, 1));
      PredQ24 := DiffwQ24;
      Dec(M, 2);
    end;
    ErrQ24[I] := SumErrorQ24;
    Inc(CB, LPCOrder);
    Inc(W, LPCOrder);
  end;
end;

procedure SilkNLSFUnpackEnc(EcIx: PSmallInt; PredQ8: PByte; const CB: TSilkNLSFCB; CB1Index: Integer);
var
  I: Integer;
  Entry: Byte;
  EcSel: PByte;
begin
  EcSel := CB.ec_sel + CB1Index * CB.order div 2;
  I := 0;
  while I < CB.order do
  begin
    Entry := EcSel^;
    Inc(EcSel);
    EcIx[I] := SmallInt(SilkSMULBB((Entry shr 1) and 7, 2 * NLSF_QUANT_MAX_AMPLITUDE + 1));
    PredQ8[I] := CB.pred_Q8[I + (Entry and 1) * (CB.order - 1)];
    EcIx[I + 1] := SmallInt(SilkSMULBB((Entry shr 5) and 7, 2 * NLSF_QUANT_MAX_AMPLITUDE + 1));
    PredQ8[I + 1] := CB.pred_Q8[I + ((Entry shr 4) and 1) * (CB.order - 1) + 1];
    Inc(I, 2);
  end;
end;

procedure NLSFResidualDequant(XQ10: PSmallInt; Indices: PShortInt; PredCoefQ8: PByte; QuantStepSizeQ16, Order: Integer);
var
  I, OutQ10, PredQ10: Integer;
begin
  OutQ10 := 0;
  for I := Order - 1 downto 0 do
  begin
    PredQ10 := Sar32(SilkSMULBB(OutQ10, PredCoefQ8[I]), 8);
    OutQ10 := Integer(Indices[I]) shl 10;
    if OutQ10 > 0 then
      OutQ10 := SmallInt(OutQ10 - NLSF_QUANT_LEVEL_ADJ_Q10)
    else if OutQ10 < 0 then
      OutQ10 := SmallInt(OutQ10 + NLSF_QUANT_LEVEL_ADJ_Q10);
    OutQ10 := SilkSMLAWB(PredQ10, OutQ10, QuantStepSizeQ16);
    XQ10[I] := SmallInt(OutQ10);
  end;
end;

procedure SilkNLSFDecodeEnc(PNLSFQ15: PSmallInt; NLSFIndices: PShortInt; const CB: TSilkNLSFCB);
var
  I, Tmp: Integer;
  PredQ8: array[0..MAX_LPC_ORDER - 1] of Byte;
  EcIx, ResQ10: array[0..MAX_LPC_ORDER - 1] of SmallInt;
  PCB: PByte;
  PW: PSmallInt;
begin
  SilkNLSFUnpackEnc(@EcIx[0], @PredQ8[0], CB, NLSFIndices[0]);
  NLSFResidualDequant(@ResQ10[0], NLSFIndices + 1, @PredQ8[0], CB.quantStepSize_Q16, CB.order);
  PCB := CB.CB1_NLSF_Q8 + NLSFIndices[0] * CB.order;
  PW := CB.CB1_Wght_Q9 + NLSFIndices[0] * CB.order;
  for I := 0 to CB.order - 1 do
  begin
    Tmp := ((Integer(ResQ10[I]) shl 14) div PW[I]) + (Integer(PCB[I]) shl 7);
    PNLSFQ15[I] := SmallInt(SilkLimit(Tmp, 0, 32767));
  end;
  SilkNLSFStabilize(PNLSFQ15, CB.deltaMin_Q15, CB.order);
end;

function NLSFDelDecQuant(Indices: PShortInt; XQ10, WQ5: PSmallInt; PredCoefQ8: PByte; EcIx: PSmallInt;
  EcRatesQ5: PByte; QuantStepSizeQ16, InvQuantStepSizeQ6, MuQ20, Order: Integer): Integer;
const
  NS = NLSF_QUANT_DEL_DEC_STATES;
  AMPX = NLSF_QUANT_MAX_AMPLITUDE_EXT;
  AMP = NLSF_QUANT_MAX_AMPLITUDE;
var
  I, J, NStates, IndTmp, IndMinMax, IndMaxMin, InQ10, ResQ10: Integer;
  PredQ10, DiffQ10, Rate0Q5, Rate1Q5: Integer;
  Out0Q10, Out1Q10: SmallInt;
  RDTmpQ25, MinQ25, MinMaxQ25, MaxMinQ25: Integer;
  IndSort: array[0..NS - 1] of Integer;
  Ind: array[0..NS - 1, 0..MAX_LPC_ORDER - 1] of ShortInt;
  PrevOutQ10: array[0..2 * NS - 1] of SmallInt;
  RDQ25: array[0..2 * NS - 1] of Integer;
  RDMinQ25, RDMaxQ25: array[0..NS - 1] of Integer;
  RatesQ5: PByte;
  Out0Tab, Out1Tab: array[0..2 * AMPX - 1] of Integer;
begin
  for I := -AMPX to AMPX - 1 do
  begin
    Out0Q10 := SmallInt(I shl 10);
    Out1Q10 := SmallInt(Out0Q10 + 1024);
    if I > 0 then
    begin
      Out0Q10 := SmallInt(Out0Q10 - NLSF_QUANT_LEVEL_ADJ_Q10);
      Out1Q10 := SmallInt(Out1Q10 - NLSF_QUANT_LEVEL_ADJ_Q10);
    end
    else if I = 0 then
      Out1Q10 := SmallInt(Out1Q10 - NLSF_QUANT_LEVEL_ADJ_Q10)
    else if I = -1 then
      Out0Q10 := SmallInt(Out0Q10 + NLSF_QUANT_LEVEL_ADJ_Q10)
    else
    begin
      Out0Q10 := SmallInt(Out0Q10 + NLSF_QUANT_LEVEL_ADJ_Q10);
      Out1Q10 := SmallInt(Out1Q10 + NLSF_QUANT_LEVEL_ADJ_Q10);
    end;
    Out0Tab[I + AMPX] := Sar32(SilkSMULBB(Out0Q10, QuantStepSizeQ16), 16);
    Out1Tab[I + AMPX] := Sar32(SilkSMULBB(Out1Q10, QuantStepSizeQ16), 16);
  end;
  NStates := 1;
  RDQ25[0] := 0;
  PrevOutQ10[0] := 0;
  for I := Order - 1 downto 0 do
  begin
    RatesQ5 := EcRatesQ5 + EcIx[I];
    InQ10 := XQ10[I];
    for J := 0 to NStates - 1 do
    begin
      PredQ10 := Sar32(SilkSMULBB(PredCoefQ8[I], PrevOutQ10[J]), 8);
      ResQ10 := SmallInt(InQ10 - PredQ10);
      IndTmp := Sar32(SilkSMULBB(InvQuantStepSizeQ6, ResQ10), 16);
      IndTmp := SilkLimit(IndTmp, -AMPX, AMPX - 1);
      Ind[J, I] := ShortInt(IndTmp);
      Out0Q10 := SmallInt(Out0Tab[IndTmp + AMPX]);
      Out1Q10 := SmallInt(Out1Tab[IndTmp + AMPX]);
      Out0Q10 := SmallInt(Out0Q10 + PredQ10);
      Out1Q10 := SmallInt(Out1Q10 + PredQ10);
      PrevOutQ10[J] := Out0Q10;
      PrevOutQ10[J + NStates] := Out1Q10;
      if IndTmp + 1 >= AMP then
      begin
        if IndTmp + 1 = AMP then
        begin
          Rate0Q5 := RatesQ5[IndTmp + AMP];
          Rate1Q5 := 280;
        end
        else
        begin
          Rate0Q5 := SilkSMLABB(280 - 43 * AMP, 43, IndTmp);
          Rate1Q5 := SmallInt(Rate0Q5 + 43);
        end;
      end
      else if IndTmp <= -AMP then
      begin
        if IndTmp = -AMP then
        begin
          Rate0Q5 := 280;
          Rate1Q5 := RatesQ5[IndTmp + 1 + AMP];
        end
        else
        begin
          Rate0Q5 := SilkSMLABB(280 - 43 * AMP, -43, IndTmp);
          Rate1Q5 := SmallInt(Rate0Q5 - 43);
        end;
      end
      else
      begin
        Rate0Q5 := RatesQ5[IndTmp + AMP];
        Rate1Q5 := RatesQ5[IndTmp + 1 + AMP];
      end;
      RDTmpQ25 := RDQ25[J];
      DiffQ10 := SmallInt(InQ10 - Out0Q10);
      RDQ25[J] := SilkSMLABB(RDTmpQ25 + SilkSMULBB(DiffQ10, DiffQ10) * WQ5[I], MuQ20, Rate0Q5);
      DiffQ10 := SmallInt(InQ10 - Out1Q10);
      RDQ25[J + NStates] := SilkSMLABB(RDTmpQ25 + SilkSMULBB(DiffQ10, DiffQ10) * WQ5[I], MuQ20, Rate1Q5);
    end;
    if NStates <= NS div 2 then
    begin
      for J := 0 to NStates - 1 do
        Ind[J + NStates, I] := ShortInt(Ind[J, I] + 1);
      NStates := NStates shl 1;
      for J := NStates to NS - 1 do
        Ind[J, I] := Ind[J - NStates, I];
    end
    else
    begin
      for J := 0 to NS - 1 do
      begin
        if RDQ25[J] > RDQ25[J + NS] then
        begin
          RDMaxQ25[J] := RDQ25[J];
          RDMinQ25[J] := RDQ25[J + NS];
          RDQ25[J] := RDMinQ25[J];
          RDQ25[J + NS] := RDMaxQ25[J];
          Out0Q10 := PrevOutQ10[J];
          PrevOutQ10[J] := PrevOutQ10[J + NS];
          PrevOutQ10[J + NS] := Out0Q10;
          IndSort[J] := J + NS;
        end
        else
        begin
          RDMinQ25[J] := RDQ25[J];
          RDMaxQ25[J] := RDQ25[J + NS];
          IndSort[J] := J;
        end;
      end;
      while True do
      begin
        MinMaxQ25 := SILK_INT32_MAX;
        MaxMinQ25 := 0;
        IndMinMax := 0;
        IndMaxMin := 0;
        for J := 0 to NS - 1 do
        begin
          if MinMaxQ25 > RDMaxQ25[J] then
          begin
            MinMaxQ25 := RDMaxQ25[J];
            IndMinMax := J;
          end;
          if MaxMinQ25 < RDMinQ25[J] then
          begin
            MaxMinQ25 := RDMinQ25[J];
            IndMaxMin := J;
          end;
        end;
        if MinMaxQ25 >= MaxMinQ25 then Break;
        IndSort[IndMaxMin] := IndSort[IndMinMax] xor NS;
        RDQ25[IndMaxMin] := RDQ25[IndMinMax + NS];
        PrevOutQ10[IndMaxMin] := PrevOutQ10[IndMinMax + NS];
        RDMinQ25[IndMaxMin] := 0;
        RDMaxQ25[IndMinMax] := SILK_INT32_MAX;
        Move(Ind[IndMinMax, 0], Ind[IndMaxMin, 0], MAX_LPC_ORDER);
      end;
      for J := 0 to NS - 1 do
        Ind[J, I] := ShortInt(Ind[J, I] + Sar32(IndSort[J], NLSF_QUANT_DEL_DEC_STATES_LOG2));
    end;
  end;
  IndTmp := 0;
  MinQ25 := SILK_INT32_MAX;
  for J := 0 to 2 * NS - 1 do
    if MinQ25 > RDQ25[J] then
    begin
      MinQ25 := RDQ25[J];
      IndTmp := J;
    end;
  for J := 0 to Order - 1 do
    Indices[J] := Ind[IndTmp and (NS - 1), J];
  Indices[0] := ShortInt(Indices[0] + Sar32(IndTmp, NLSF_QUANT_DEL_DEC_STATES_LOG2));
  Result := MinQ25;
end;

function SilkNLSFEncode(NLSFIndices: PShortInt; PNLSFQ15: PSmallInt; const CB: TSilkNLSFCB;
  PWQ2: PSmallInt; NLSFMuQ20, NSurvivors, SignalType: Integer): Integer;
var
  I, S, Ind1, BestIndex, ProbQ8, BitsQ7, WTmpQ9: Integer;
  ErrQ24: array[0..NLSF_VQ_MAX_VECTORS - 1] of Integer;
  RDQ25: array[0..NLSF_VQ_MAX_VECTORS - 1] of Integer;
  TempIndices1: array[0..NLSF_VQ_MAX_VECTORS - 1] of Integer;
  TempIndices2: array[0..NLSF_VQ_MAX_VECTORS * MAX_LPC_ORDER - 1] of ShortInt;
  ResQ10, NLSFTmpQ15, WAdjQ5, EcIx: array[0..MAX_LPC_ORDER - 1] of SmallInt;
  PredQ8: array[0..MAX_LPC_ORDER - 1] of Byte;
  PCB: PByte;
  PW: PSmallInt;
  ICDF: PByte;
begin
  SilkNLSFStabilize(PNLSFQ15, CB.deltaMin_Q15, CB.order);
  NLSFVQ(@ErrQ24[0], PNLSFQ15, CB.CB1_NLSF_Q8, CB.CB1_Wght_Q9, CB.nVectors, CB.order);
  SilkInsertionSortIncreasing(@ErrQ24[0], @TempIndices1[0], CB.nVectors, NSurvivors);
  for S := 0 to NSurvivors - 1 do
  begin
    Ind1 := TempIndices1[S];
    PCB := CB.CB1_NLSF_Q8 + Ind1 * CB.order;
    PW := CB.CB1_Wght_Q9 + Ind1 * CB.order;
    for I := 0 to CB.order - 1 do
    begin
      NLSFTmpQ15[I] := SmallInt(Integer(PCB[I]) shl 7);
      WTmpQ9 := PW[I];
      ResQ10[I] := SmallInt(Sar32(SilkSMULBB(PNLSFQ15[I] - NLSFTmpQ15[I], WTmpQ9), 14));
      WAdjQ5[I] := SmallInt(SilkDIV32VarQ(PWQ2[I], SilkSMULBB(WTmpQ9, WTmpQ9), 21));
    end;
    SilkNLSFUnpackEnc(@EcIx[0], @PredQ8[0], CB, Ind1);
    RDQ25[S] := NLSFDelDecQuant(@TempIndices2[S * MAX_LPC_ORDER], @ResQ10[0], @WAdjQ5[0], @PredQ8[0], @EcIx[0],
      CB.ec_Rates_Q5, CB.quantStepSize_Q16, CB.invQuantStepSize_Q6, NLSFMuQ20, CB.order);
    ICDF := CB.CB1_iCDF + (SignalType shr 1) * CB.nVectors;
    if Ind1 = 0 then
      ProbQ8 := 256 - ICDF[Ind1]
    else
      ProbQ8 := ICDF[Ind1 - 1] - ICDF[Ind1];
    BitsQ7 := (8 shl 7) - SilkLin2Log(ProbQ8);
    RDQ25[S] := SilkSMLABB(RDQ25[S], BitsQ7, Sar32(NLSFMuQ20, 2));
  end;
  SilkInsertionSortIncreasing(@RDQ25[0], @BestIndex, NSurvivors, 1);
  NLSFIndices[0] := ShortInt(TempIndices1[BestIndex]);
  Move(TempIndices2[BestIndex * MAX_LPC_ORDER], NLSFIndices[1], CB.order);
  SilkNLSFDecodeEnc(PNLSFQ15, NLSFIndices, CB);
  Result := RDQ25[0];
end;

procedure SilkProcessNLSFs(var E: TSilkEncoderState; PredCoefQ12: PSmallInt; PNLSFQ15: PSmallInt;
  PrevNLSFqQ15: PSmallInt);
var
  I, DoInterpolate, NLSFMuQ20: Integer;
  ISqrQ15: SmallInt;
  PNLSF0TempQ15, PNLSFWQW, PNLSFW0TempQW: array[0..MAX_LPC_ORDER - 1] of SmallInt;
begin
  NLSFMuQ20 := SilkSMLAWB(3146, -268434, E.speech_activity_Q8);
  if E.nb_subfr = 2 then
    NLSFMuQ20 := NLSFMuQ20 + Sar32(NLSFMuQ20, 1);
  NLSFVQWeightsLaroia(@PNLSFWQW[0], PNLSFQ15, E.predictLPCOrder);
  if (E.useInterpolatedNLSFs = 1) and (E.indices.NLSFInterpCoef_Q2 < 4) then DoInterpolate := 1 else DoInterpolate := 0;
  if DoInterpolate <> 0 then
  begin
    SilkInterpolate(@PNLSF0TempQ15[0], PrevNLSFqQ15, PNLSFQ15, E.indices.NLSFInterpCoef_Q2, E.predictLPCOrder);
    NLSFVQWeightsLaroia(@PNLSFW0TempQW[0], @PNLSF0TempQ15[0], E.predictLPCOrder);
    ISqrQ15 := SmallInt(SilkSMULBB(E.indices.NLSFInterpCoef_Q2, E.indices.NLSFInterpCoef_Q2) shl 11);
    for I := 0 to E.predictLPCOrder - 1 do
      PNLSFWQW[I] := SmallInt(Sar32(PNLSFWQW[I], 1) + Sar32(SilkSMULBB(PNLSFW0TempQW[I], ISqrQ15), 16));
  end;
  SilkNLSFEncode(@E.indices.NLSFIndices[0], PNLSFQ15, E.psNLSF_CB^, @PNLSFWQW[0], NLSFMuQ20,
    E.NLSF_MSVQ_Survivors, E.indices.signalType);
  SilkNLSF2AEnc(PredCoefQ12 + MAX_LPC_ORDER, PNLSFQ15, E.predictLPCOrder);
  if DoInterpolate <> 0 then
  begin
    SilkInterpolate(@PNLSF0TempQ15[0], PrevNLSFqQ15, PNLSFQ15, E.indices.NLSFInterpCoef_Q2, E.predictLPCOrder);
    SilkNLSF2AEnc(PredCoefQ12, @PNLSF0TempQ15[0], E.predictLPCOrder);
  end
  else
    Move(PredCoefQ12[MAX_LPC_ORDER], PredCoefQ12^, E.predictLPCOrder * SizeOf(SmallInt));
end;

end.
