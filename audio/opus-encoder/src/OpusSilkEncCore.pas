unit OpusSilkEncCore;

{
  OpusSilkEncCore.pas - SILK encoder fixed-point helpers

  Port of libopus 1.5.2 silk/resampler.c, resampler_private_down_FIR.c,
  resampler_private_AR2.c, resampler_private_IIR_FIR.c,
  resampler_private_up2_HQ.c, resampler_down2.c, resampler_down2_3.c, VAD.c,
  ana_filt_bank_1.c, sigm_Q15.c, biquad_alt.c, LP_variable_cutoff.c,
  gain_quant.c, interpolate.c, sort.c, inner_prod_aligned.c.
  Copyright (c) 2006-2011 Skype Limited; Xiph.Org Foundation.

  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  OpusSilkMath, OpusSilkEncTables, OpusSilkEncDefs;

function  SilkSMLAWT(A, B, C: Integer): Integer; inline;
function  SilkAddPosSat32(A, B: Integer): Integer; inline;
function  SilkSat16S(A: Integer): SmallInt; inline;
function  SilkInnerProdAlignedScale(V1, V2: PSmallInt; Scale, Len: Integer): Integer;
procedure SilkInsertionSortIncreasing(A: PInteger; Idx: PInteger; L, K: Integer);

function  SilkResamplerInit(var S: TSilkResamplerState; FsHzIn, FsHzOut: Integer; ForEnc: Boolean): Integer;
function  SilkResampler(var S: TSilkResamplerState; OutP, InP: PSmallInt; InLen: Integer): Integer;
procedure SilkResamplerDown2(S: PInteger; OutP, InP: PSmallInt; InLen: Integer);
procedure SilkResamplerDown2_3(S: PInteger; OutP, InP: PSmallInt; InLen: Integer);

function  SilkSigmQ15(InQ5: Integer): Integer;
procedure SilkAnaFiltBank1(InP: PSmallInt; S: PInteger; OutL, OutH: PSmallInt; N: Integer);
function  SilkVADInit(var V: TSilkVADState): Integer;
function  SilkVADGetSAQ8(var E: TSilkEncoderState; PIn: PSmallInt): Integer;

procedure SilkBiquadAltStride1(InP: PSmallInt; B, A: PInteger; S: PInteger; OutP: PSmallInt; Len: Integer);
procedure SilkLPVariableCutoff(var LP: TSilkLPState; Frame: PSmallInt; FrameLength: Integer);

procedure SilkGainsQuant(Ind: PShortInt; GainQ16: PInteger; var PrevInd: ShortInt; Conditional, NbSubfr: Integer);
procedure SilkGainsDequant(GainQ16: PInteger; Ind: PShortInt; var PrevInd: ShortInt; Conditional, NbSubfr: Integer);
function  SilkGainsID(Ind: PShortInt; NbSubfr: Integer): Integer;
procedure SilkInterpolate(Xi, X0, X1: PSmallInt; IfactQ2, D: Integer);

implementation

function SilkSMLAWT(A, B, C: Integer): Integer;
begin
  Result := A + Integer(Sar64(Int64(B) * Int64(Sar32(C, 16)), 16));
end;

function SilkAddPosSat32(A, B: Integer): Integer;
var
  S: Cardinal;
begin
  S := Cardinal(A) + Cardinal(B);
  if (S and $80000000) <> 0 then Result := SILK_INT32_MAX else Result := Integer(S);
end;

function SilkSat16S(A: Integer): SmallInt;
begin
  Result := SmallInt(SilkSat16(A));
end;

function SilkInnerProdAlignedScale(V1, V2: PSmallInt; Scale, Len: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Len - 1 do
    Result := Result + Sar32(SilkSMULBB(V1[I], V2[I]), Scale);
end;

procedure SilkInsertionSortIncreasing(A: PInteger; Idx: PInteger; L, K: Integer);
var
  Value, I, J: Integer;
begin
  for I := 0 to K - 1 do Idx[I] := I;
  for I := 1 to K - 1 do
  begin
    Value := A[I];
    J := I - 1;
    while (J >= 0) and (Value < A[J]) do
    begin
      A[J + 1] := A[J];
      Idx[J + 1] := Idx[J];
      Dec(J);
    end;
    A[J + 1] := Value;
    Idx[J + 1] := I;
  end;
  for I := K to L - 1 do
  begin
    Value := A[I];
    if Value < A[K - 1] then
    begin
      J := K - 2;
      while (J >= 0) and (Value < A[J]) do
      begin
        A[J + 1] := A[J];
        Idx[J + 1] := Idx[J];
        Dec(J);
      end;
      A[J + 1] := Value;
      Idx[J + 1] := I;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Resampler
// ---------------------------------------------------------------------------

const
  RS_COPY = 0;
  RS_UP2_HQ = 1;
  RS_IIR_FIR = 2;
  RS_DOWN_FIR = 3;
  DELAY_MATRIX_ENC: array[0..4, 0..2] of Byte = (
    (6, 0, 3), (0, 7, 3), (0, 1, 10), (0, 2, 6), (18, 10, 12));
  DELAY_MATRIX_DEC: array[0..2, 0..4] of Byte = (
    (4, 0, 2, 0, 0), (0, 9, 4, 7, 4), (0, 3, 12, 7, 7));
  UP2_HQ_0: array[0..2] of SmallInt = (1746, 14986, 39083 - 65536);
  UP2_HQ_1: array[0..2] of SmallInt = (6854, 25769, 55542 - 65536);

function RateID(R: Integer): Integer;
var
  G16, G24: Integer;
begin
  if R > 16000 then G16 := 1 else G16 := 0;
  if R > 24000 then G24 := 1 else G24 := 0;
  Result := Sar32(Sar32(R, 12) - G16, G24) - 1;
end;

function SilkResamplerInit(var S: TSilkResamplerState; FsHzIn, FsHzOut: Integer; ForEnc: Boolean): Integer;
var
  Up2x: Integer;
begin
  FillChar(S, SizeOf(S), 0);
  if ForEnc then
  begin
    if ((FsHzIn <> 8000) and (FsHzIn <> 12000) and (FsHzIn <> 16000) and (FsHzIn <> 24000) and (FsHzIn <> 48000)) or
       ((FsHzOut <> 8000) and (FsHzOut <> 12000) and (FsHzOut <> 16000)) then
      Exit(-1);
    S.inputDelay := DELAY_MATRIX_ENC[RateID(FsHzIn), RateID(FsHzOut)];
  end
  else
  begin
    if ((FsHzIn <> 8000) and (FsHzIn <> 12000) and (FsHzIn <> 16000)) or
       ((FsHzOut <> 8000) and (FsHzOut <> 12000) and (FsHzOut <> 16000) and (FsHzOut <> 24000) and (FsHzOut <> 48000)) then
      Exit(-1);
    S.inputDelay := DELAY_MATRIX_DEC[RateID(FsHzIn), RateID(FsHzOut)];
  end;
  S.Fs_in_kHz := FsHzIn div 1000;
  S.Fs_out_kHz := FsHzOut div 1000;
  S.batchSize := S.Fs_in_kHz * RESAMPLER_MAX_BATCH_SIZE_MS;
  Up2x := 0;
  if FsHzOut > FsHzIn then
  begin
    if FsHzOut = FsHzIn * 2 then
      S.resampler_function := RS_UP2_HQ
    else
    begin
      S.resampler_function := RS_IIR_FIR;
      Up2x := 1;
    end;
  end
  else if FsHzOut < FsHzIn then
  begin
    S.resampler_function := RS_DOWN_FIR;
    if FsHzOut * 4 = FsHzIn * 3 then
    begin
      S.FIR_Fracs := 3; S.FIR_Order := RESAMPLER_DOWN_ORDER_FIR0; S.Coefs := @SE_RESAMPLER_3_4_COEFS[0];
    end
    else if FsHzOut * 3 = FsHzIn * 2 then
    begin
      S.FIR_Fracs := 2; S.FIR_Order := RESAMPLER_DOWN_ORDER_FIR0; S.Coefs := @SE_RESAMPLER_2_3_COEFS[0];
    end
    else if FsHzOut * 2 = FsHzIn then
    begin
      S.FIR_Fracs := 1; S.FIR_Order := RESAMPLER_DOWN_ORDER_FIR1; S.Coefs := @SE_RESAMPLER_1_2_COEFS[0];
    end
    else if FsHzOut * 3 = FsHzIn then
    begin
      S.FIR_Fracs := 1; S.FIR_Order := RESAMPLER_DOWN_ORDER_FIR2; S.Coefs := @SE_RESAMPLER_1_3_COEFS[0];
    end
    else if FsHzOut * 4 = FsHzIn then
    begin
      S.FIR_Fracs := 1; S.FIR_Order := RESAMPLER_DOWN_ORDER_FIR2; S.Coefs := @SE_RESAMPLER_1_4_COEFS[0];
    end
    else if FsHzOut * 6 = FsHzIn then
    begin
      S.FIR_Fracs := 1; S.FIR_Order := RESAMPLER_DOWN_ORDER_FIR2; S.Coefs := @SE_RESAMPLER_1_6_COEFS[0];
    end
    else
      Exit(-1);
  end
  else
    S.resampler_function := RS_COPY;
  S.invRatio_Q16 := ((FsHzIn shl (14 + Up2x)) div FsHzOut) shl 2;
  while SilkSMULWW(S.invRatio_Q16, FsHzOut) < (FsHzIn shl Up2x) do
    Inc(S.invRatio_Q16);
  Result := 0;
end;

procedure ResamplerAR2(S: PInteger; OutQ8: PInteger; InP: PSmallInt; A: PSmallInt; Len: Integer);
var
  K, Out32: Integer;
begin
  for K := 0 to Len - 1 do
  begin
    Out32 := S[0] + (Integer(InP[K]) shl 8);
    OutQ8[K] := Out32;
    Out32 := Out32 shl 2;
    S[0] := SilkSMLAWB(S[1], Out32, A[0]);
    S[1] := SilkSMULWB(Out32, A[1]);
  end;
end;

function DownFIRInterpol(OutP: PSmallInt; Buf: PInteger; Coefs: PSmallInt; Order, Fracs,
  MaxIndexQ16, IncQ16: Integer): PSmallInt;
var
  IndexQ16, ResQ6, InterpolInd: Integer;
  B: PInteger;
  IP: PSmallInt;
begin
  IndexQ16 := 0;
  case Order of
    RESAMPLER_DOWN_ORDER_FIR0:
      while IndexQ16 < MaxIndexQ16 do
      begin
        B := Buf + Sar32(IndexQ16, 16);
        InterpolInd := SilkSMULWB(IndexQ16 and $FFFF, Fracs);
        IP := Coefs + (RESAMPLER_DOWN_ORDER_FIR0 div 2) * InterpolInd;
        ResQ6 := SilkSMULWB(B[0], IP[0]);
        ResQ6 := SilkSMLAWB(ResQ6, B[1], IP[1]);
        ResQ6 := SilkSMLAWB(ResQ6, B[2], IP[2]);
        ResQ6 := SilkSMLAWB(ResQ6, B[3], IP[3]);
        ResQ6 := SilkSMLAWB(ResQ6, B[4], IP[4]);
        ResQ6 := SilkSMLAWB(ResQ6, B[5], IP[5]);
        ResQ6 := SilkSMLAWB(ResQ6, B[6], IP[6]);
        ResQ6 := SilkSMLAWB(ResQ6, B[7], IP[7]);
        ResQ6 := SilkSMLAWB(ResQ6, B[8], IP[8]);
        IP := Coefs + (RESAMPLER_DOWN_ORDER_FIR0 div 2) * (Fracs - 1 - InterpolInd);
        ResQ6 := SilkSMLAWB(ResQ6, B[17], IP[0]);
        ResQ6 := SilkSMLAWB(ResQ6, B[16], IP[1]);
        ResQ6 := SilkSMLAWB(ResQ6, B[15], IP[2]);
        ResQ6 := SilkSMLAWB(ResQ6, B[14], IP[3]);
        ResQ6 := SilkSMLAWB(ResQ6, B[13], IP[4]);
        ResQ6 := SilkSMLAWB(ResQ6, B[12], IP[5]);
        ResQ6 := SilkSMLAWB(ResQ6, B[11], IP[6]);
        ResQ6 := SilkSMLAWB(ResQ6, B[10], IP[7]);
        ResQ6 := SilkSMLAWB(ResQ6, B[9], IP[8]);
        OutP^ := SilkSat16S(SilkRShiftRound(ResQ6, 6));
        Inc(OutP);
        Inc(IndexQ16, IncQ16);
      end;
    RESAMPLER_DOWN_ORDER_FIR1:
      while IndexQ16 < MaxIndexQ16 do
      begin
        B := Buf + Sar32(IndexQ16, 16);
        ResQ6 := SilkSMULWB(B[0] + B[23], Coefs[0]);
        ResQ6 := SilkSMLAWB(ResQ6, B[1] + B[22], Coefs[1]);
        ResQ6 := SilkSMLAWB(ResQ6, B[2] + B[21], Coefs[2]);
        ResQ6 := SilkSMLAWB(ResQ6, B[3] + B[20], Coefs[3]);
        ResQ6 := SilkSMLAWB(ResQ6, B[4] + B[19], Coefs[4]);
        ResQ6 := SilkSMLAWB(ResQ6, B[5] + B[18], Coefs[5]);
        ResQ6 := SilkSMLAWB(ResQ6, B[6] + B[17], Coefs[6]);
        ResQ6 := SilkSMLAWB(ResQ6, B[7] + B[16], Coefs[7]);
        ResQ6 := SilkSMLAWB(ResQ6, B[8] + B[15], Coefs[8]);
        ResQ6 := SilkSMLAWB(ResQ6, B[9] + B[14], Coefs[9]);
        ResQ6 := SilkSMLAWB(ResQ6, B[10] + B[13], Coefs[10]);
        ResQ6 := SilkSMLAWB(ResQ6, B[11] + B[12], Coefs[11]);
        OutP^ := SilkSat16S(SilkRShiftRound(ResQ6, 6));
        Inc(OutP);
        Inc(IndexQ16, IncQ16);
      end;
    RESAMPLER_DOWN_ORDER_FIR2:
      while IndexQ16 < MaxIndexQ16 do
      begin
        B := Buf + Sar32(IndexQ16, 16);
        ResQ6 := SilkSMULWB(B[0] + B[35], Coefs[0]);
        ResQ6 := SilkSMLAWB(ResQ6, B[1] + B[34], Coefs[1]);
        ResQ6 := SilkSMLAWB(ResQ6, B[2] + B[33], Coefs[2]);
        ResQ6 := SilkSMLAWB(ResQ6, B[3] + B[32], Coefs[3]);
        ResQ6 := SilkSMLAWB(ResQ6, B[4] + B[31], Coefs[4]);
        ResQ6 := SilkSMLAWB(ResQ6, B[5] + B[30], Coefs[5]);
        ResQ6 := SilkSMLAWB(ResQ6, B[6] + B[29], Coefs[6]);
        ResQ6 := SilkSMLAWB(ResQ6, B[7] + B[28], Coefs[7]);
        ResQ6 := SilkSMLAWB(ResQ6, B[8] + B[27], Coefs[8]);
        ResQ6 := SilkSMLAWB(ResQ6, B[9] + B[26], Coefs[9]);
        ResQ6 := SilkSMLAWB(ResQ6, B[10] + B[25], Coefs[10]);
        ResQ6 := SilkSMLAWB(ResQ6, B[11] + B[24], Coefs[11]);
        ResQ6 := SilkSMLAWB(ResQ6, B[12] + B[23], Coefs[12]);
        ResQ6 := SilkSMLAWB(ResQ6, B[13] + B[22], Coefs[13]);
        ResQ6 := SilkSMLAWB(ResQ6, B[14] + B[21], Coefs[14]);
        ResQ6 := SilkSMLAWB(ResQ6, B[15] + B[20], Coefs[15]);
        ResQ6 := SilkSMLAWB(ResQ6, B[16] + B[19], Coefs[16]);
        ResQ6 := SilkSMLAWB(ResQ6, B[17] + B[18], Coefs[17]);
        OutP^ := SilkSat16S(SilkRShiftRound(ResQ6, 6));
        Inc(OutP);
        Inc(IndexQ16, IncQ16);
      end;
  end;
  Result := OutP;
end;

procedure ResamplerDownFIR(var S: TSilkResamplerState; OutP, InP: PSmallInt; InLen: Integer);
var
  NSamplesIn, MaxIndexQ16, IncQ16: Integer;
  Buf: array[0..RESAMPLER_MAX_BATCH_SIZE_IN + SILK_RESAMPLER_MAX_FIR_ORDER - 1] of Integer;
  FIRCoefs: PSmallInt;
begin
  Move(S.sFIR[0], Buf[0], S.FIR_Order * SizeOf(Integer));
  FIRCoefs := S.Coefs + 2;
  IncQ16 := S.invRatio_Q16;
  while True do
  begin
    if InLen < S.batchSize then NSamplesIn := InLen else NSamplesIn := S.batchSize;
    ResamplerAR2(@S.sIIR[0], @Buf[S.FIR_Order], InP, S.Coefs, NSamplesIn);
    MaxIndexQ16 := NSamplesIn shl 16;
    OutP := DownFIRInterpol(OutP, @Buf[0], FIRCoefs, S.FIR_Order, S.FIR_Fracs, MaxIndexQ16, IncQ16);
    Inc(InP, NSamplesIn);
    Dec(InLen, NSamplesIn);
    if InLen > 1 then
      Move(Buf[NSamplesIn], Buf[0], S.FIR_Order * SizeOf(Integer))
    else
      Break;
  end;
  Move(Buf[NSamplesIn], S.sFIR[0], S.FIR_Order * SizeOf(Integer));
end;

procedure ResamplerUp2HQ(S: PInteger; OutP, InP: PSmallInt; Len: Integer);
var
  K, In32, Out1, Out2, Y, X: Integer;
begin
  for K := 0 to Len - 1 do
  begin
    In32 := Integer(InP[K]) shl 10;
    Y := In32 - S[0];
    X := SilkSMULWB(Y, UP2_HQ_0[0]);
    Out1 := S[0] + X;
    S[0] := In32 + X;
    Y := Out1 - S[1];
    X := SilkSMULWB(Y, UP2_HQ_0[1]);
    Out2 := S[1] + X;
    S[1] := Out1 + X;
    Y := Out2 - S[2];
    X := SilkSMLAWB(Y, Y, UP2_HQ_0[2]);
    Out1 := S[2] + X;
    S[2] := Out2 + X;
    OutP[2 * K] := SilkSat16S(SilkRShiftRound(Out1, 10));
    Y := In32 - S[3];
    X := SilkSMULWB(Y, UP2_HQ_1[0]);
    Out1 := S[3] + X;
    S[3] := In32 + X;
    Y := Out1 - S[4];
    X := SilkSMULWB(Y, UP2_HQ_1[1]);
    Out2 := S[4] + X;
    S[4] := Out1 + X;
    Y := Out2 - S[5];
    X := SilkSMLAWB(Y, Y, UP2_HQ_1[2]);
    Out1 := S[5] + X;
    S[5] := Out2 + X;
    OutP[2 * K + 1] := SilkSat16S(SilkRShiftRound(Out1, 10));
  end;
end;

procedure ResamplerIIRFIR(var S: TSilkResamplerState; OutP, InP: PSmallInt; InLen: Integer);
var
  NSamplesIn, MaxIndexQ16, IncQ16, IndexQ16, ResQ15, TI: Integer;
  Buf: array[0..2 * RESAMPLER_MAX_BATCH_SIZE_IN + RESAMPLER_ORDER_FIR_12 - 1] of SmallInt;
  B: PSmallInt;
begin
  Move(S.sFIR[0], Buf[0], RESAMPLER_ORDER_FIR_12 * SizeOf(SmallInt));
  IncQ16 := S.invRatio_Q16;
  while True do
  begin
    if InLen < S.batchSize then NSamplesIn := InLen else NSamplesIn := S.batchSize;
    ResamplerUp2HQ(@S.sIIR[0], @Buf[RESAMPLER_ORDER_FIR_12], InP, NSamplesIn);
    MaxIndexQ16 := NSamplesIn shl 17;
    IndexQ16 := 0;
    while IndexQ16 < MaxIndexQ16 do
    begin
      TI := SilkSMULWB(IndexQ16 and $FFFF, 12);
      B := @Buf[IndexQ16 shr 16];
      ResQ15 := SilkSMULBB(B[0], SE_RESAMPLER_FRAC_FIR_12[TI, 0]);
      ResQ15 := SilkSMLABB(ResQ15, B[1], SE_RESAMPLER_FRAC_FIR_12[TI, 1]);
      ResQ15 := SilkSMLABB(ResQ15, B[2], SE_RESAMPLER_FRAC_FIR_12[TI, 2]);
      ResQ15 := SilkSMLABB(ResQ15, B[3], SE_RESAMPLER_FRAC_FIR_12[TI, 3]);
      ResQ15 := SilkSMLABB(ResQ15, B[4], SE_RESAMPLER_FRAC_FIR_12[11 - TI, 3]);
      ResQ15 := SilkSMLABB(ResQ15, B[5], SE_RESAMPLER_FRAC_FIR_12[11 - TI, 2]);
      ResQ15 := SilkSMLABB(ResQ15, B[6], SE_RESAMPLER_FRAC_FIR_12[11 - TI, 1]);
      ResQ15 := SilkSMLABB(ResQ15, B[7], SE_RESAMPLER_FRAC_FIR_12[11 - TI, 0]);
      OutP^ := SilkSat16S(SilkRShiftRound(ResQ15, 15));
      Inc(OutP);
      Inc(IndexQ16, IncQ16);
    end;
    Inc(InP, NSamplesIn);
    Dec(InLen, NSamplesIn);
    if InLen > 0 then
      Move(Buf[NSamplesIn shl 1], Buf[0], RESAMPLER_ORDER_FIR_12 * SizeOf(SmallInt))
    else
      Break;
  end;
  Move(Buf[NSamplesIn shl 1], S.sFIR[0], RESAMPLER_ORDER_FIR_12 * SizeOf(SmallInt));
end;

procedure ResamplerDispatch(var S: TSilkResamplerState; OutP, InP: PSmallInt; Len: Integer);
begin
  case S.resampler_function of
    RS_UP2_HQ  : ResamplerUp2HQ(@S.sIIR[0], OutP, InP, Len);
    RS_IIR_FIR : ResamplerIIRFIR(S, OutP, InP, Len);
    RS_DOWN_FIR: ResamplerDownFIR(S, OutP, InP, Len);
  else
    Move(InP^, OutP^, Len * SizeOf(SmallInt));
  end;
end;

function SilkResampler(var S: TSilkResamplerState; OutP, InP: PSmallInt; InLen: Integer): Integer;
var
  NSamples: Integer;
begin
  NSamples := S.Fs_in_kHz - S.inputDelay;
  Move(InP^, S.delayBuf[S.inputDelay], NSamples * SizeOf(SmallInt));
  ResamplerDispatch(S, OutP, @S.delayBuf[0], S.Fs_in_kHz);
  ResamplerDispatch(S, OutP + S.Fs_out_kHz, InP + NSamples, InLen - S.Fs_in_kHz);
  Move(InP[InLen - S.inputDelay], S.delayBuf[0], S.inputDelay * SizeOf(SmallInt));
  Result := 0;
end;

procedure SilkResamplerDown2(S: PInteger; OutP, InP: PSmallInt; InLen: Integer);
var
  K, Len2, In32, Out32, Y, X: Integer;
begin
  Len2 := Sar32(InLen, 1);
  for K := 0 to Len2 - 1 do
  begin
    In32 := Integer(InP[2 * K]) shl 10;
    Y := In32 - S[0];
    X := SilkSMLAWB(Y, Y, SILK_RESAMPLER_DOWN2_1);
    Out32 := S[0] + X;
    S[0] := In32 + X;
    In32 := Integer(InP[2 * K + 1]) shl 10;
    Y := In32 - S[1];
    X := SilkSMULWB(Y, SILK_RESAMPLER_DOWN2_0);
    Out32 := Out32 + S[1];
    Out32 := Out32 + X;
    S[1] := In32 + X;
    OutP[K] := SilkSat16S(SilkRShiftRound(Out32, 11));
  end;
end;

procedure SilkResamplerDown2_3(S: PInteger; OutP, InP: PSmallInt; InLen: Integer);
const
  ORDER_FIR = 4;
var
  NSamplesIn, Counter, ResQ6: Integer;
  Buf: array[0..RESAMPLER_MAX_BATCH_SIZE_IN + ORDER_FIR - 1] of Integer;
  B: PInteger;
  C: PSmallInt;
begin
  C := @SE_RESAMPLER_2_3_COEFS_LQ[0];
  Move(S^, Buf[0], ORDER_FIR * SizeOf(Integer));
  while True do
  begin
    if InLen < RESAMPLER_MAX_BATCH_SIZE_IN then NSamplesIn := InLen else NSamplesIn := RESAMPLER_MAX_BATCH_SIZE_IN;
    ResamplerAR2(S + ORDER_FIR, @Buf[ORDER_FIR], InP, C, NSamplesIn);
    B := @Buf[0];
    Counter := NSamplesIn;
    while Counter > 2 do
    begin
      ResQ6 := SilkSMULWB(B[0], C[2]);
      ResQ6 := SilkSMLAWB(ResQ6, B[1], C[3]);
      ResQ6 := SilkSMLAWB(ResQ6, B[2], C[5]);
      ResQ6 := SilkSMLAWB(ResQ6, B[3], C[4]);
      OutP^ := SilkSat16S(SilkRShiftRound(ResQ6, 6));
      Inc(OutP);
      ResQ6 := SilkSMULWB(B[1], C[4]);
      ResQ6 := SilkSMLAWB(ResQ6, B[2], C[5]);
      ResQ6 := SilkSMLAWB(ResQ6, B[3], C[3]);
      ResQ6 := SilkSMLAWB(ResQ6, B[4], C[2]);
      OutP^ := SilkSat16S(SilkRShiftRound(ResQ6, 6));
      Inc(OutP);
      Inc(B, 3);
      Dec(Counter, 3);
    end;
    Inc(InP, NSamplesIn);
    Dec(InLen, NSamplesIn);
    if InLen > 0 then
      Move(Buf[NSamplesIn], Buf[0], ORDER_FIR * SizeOf(Integer))
    else
      Break;
  end;
  Move(Buf[NSamplesIn], S^, ORDER_FIR * SizeOf(Integer));
end;

// ---------------------------------------------------------------------------
// VAD
// ---------------------------------------------------------------------------

const
  SIGM_LUT_SLOPE_Q10: array[0..5] of Integer = (237, 153, 73, 30, 12, 7);
  SIGM_LUT_POS_Q15: array[0..5] of Integer = (16384, 23955, 28861, 31213, 32178, 32548);
  SIGM_LUT_NEG_Q15: array[0..5] of Integer = (16384, 8812, 3906, 1554, 589, 219);
  TILT_WEIGHTS: array[0..VAD_N_BANDS - 1] of Integer = (30000, 6000, -12000, -12000);
  A_FB1_20 = 5394 shl 1;
  A_FB1_21 = -24290;

function SilkSigmQ15(InQ5: Integer): Integer;
var
  Ind: Integer;
begin
  if InQ5 < 0 then
  begin
    InQ5 := -InQ5;
    if InQ5 >= 6 * 32 then Exit(0);
    Ind := Sar32(InQ5, 5);
    Result := SIGM_LUT_NEG_Q15[Ind] - SilkSMULBB(SIGM_LUT_SLOPE_Q10[Ind], InQ5 and $1F);
  end
  else
  begin
    if InQ5 >= 6 * 32 then Exit(32767);
    Ind := Sar32(InQ5, 5);
    Result := SIGM_LUT_POS_Q15[Ind] + SilkSMULBB(SIGM_LUT_SLOPE_Q10[Ind], InQ5 and $1F);
  end;
end;

procedure SilkAnaFiltBank1(InP: PSmallInt; S: PInteger; OutL, OutH: PSmallInt; N: Integer);
var
  K, N2, In32, X, Y, Out1, Out2: Integer;
begin
  N2 := Sar32(N, 1);
  for K := 0 to N2 - 1 do
  begin
    In32 := Integer(InP[2 * K]) shl 10;
    Y := In32 - S[0];
    X := SilkSMLAWB(Y, Y, A_FB1_21);
    Out1 := S[0] + X;
    S[0] := In32 + X;
    In32 := Integer(InP[2 * K + 1]) shl 10;
    Y := In32 - S[1];
    X := SilkSMULWB(Y, A_FB1_20);
    Out2 := S[1] + X;
    S[1] := In32 + X;
    OutL[K] := SilkSat16S(SilkRShiftRound(Out2 + Out1, 11));
    OutH[K] := SilkSat16S(SilkRShiftRound(Out2 - Out1, 11));
  end;
end;

function SilkVADInit(var V: TSilkVADState): Integer;
var
  B, T: Integer;
begin
  FillChar(V, SizeOf(V), 0);
  for B := 0 to VAD_N_BANDS - 1 do
  begin
    T := VAD_NOISE_LEVELS_BIAS div (B + 1);
    if T < 1 then T := 1;
    V.NoiseLevelBias[B] := T;
  end;
  for B := 0 to VAD_N_BANDS - 1 do
  begin
    V.NL[B] := 100 * V.NoiseLevelBias[B];
    V.inv_NL[B] := SILK_INT32_MAX div V.NL[B];
  end;
  V.counter := 15;
  for B := 0 to VAD_N_BANDS - 1 do
    V.NrgRatioSmth_Q8[B] := 100 * 256;
  Result := 0;
end;

procedure VADGetNoiseLevels(PX: PInteger; var V: TSilkVADState);
var
  K, Nl, Nrg, InvNrg, Coef, MinCoef: Integer;
begin
  if V.counter < 1000 then
  begin
    MinCoef := SILK_INT16_MAX div (Sar32(V.counter, 4) + 1);
    Inc(V.counter);
  end
  else
    MinCoef := 0;
  for K := 0 to VAD_N_BANDS - 1 do
  begin
    Nl := V.NL[K];
    Nrg := SilkAddPosSat32(PX[K], V.NoiseLevelBias[K]);
    InvNrg := SILK_INT32_MAX div Nrg;
    if Nrg > (Nl shl 3) then
      Coef := VAD_NOISE_LEVEL_SMOOTH_COEF_Q16 shr 3
    else if Nrg < Nl then
      Coef := VAD_NOISE_LEVEL_SMOOTH_COEF_Q16
    else
      Coef := SilkSMULWB(SilkSMULWW(InvNrg, Nl), VAD_NOISE_LEVEL_SMOOTH_COEF_Q16 shl 1);
    if Coef < MinCoef then Coef := MinCoef;
    V.inv_NL[K] := SilkSMLAWB(V.inv_NL[K], InvNrg - V.inv_NL[K], Coef);
    Nl := SILK_INT32_MAX div V.inv_NL[K];
    if Nl > $00FFFFFF then Nl := $00FFFFFF;
    V.NL[K] := Nl;
  end;
end;

function SilkVADGetSAQ8(var E: TSilkEncoderState; PIn: PSmallInt): Integer;
var
  SAQ15, PSNRdBQ7, InputTilt: Integer;
  DecFL1, DecFL2, DecFL: Integer;
  DecSubfrLen, DecSubfrOff, SNRQ7, I, B, S: Integer;
  SumSquared, SmoothCoefQ16: Integer;
  HPstateTmp: SmallInt;
  X: array[0..MAX_FRAME_LENGTH + MAX_FRAME_LENGTH div 2] of SmallInt;
  Xnrg, NrgToNoiseRatioQ8: array[0..VAD_N_BANDS - 1] of Integer;
  SpeechNrg, XTmp: Integer;
  XOffset: array[0..VAD_N_BANDS - 1] of Integer;
  V: ^TSilkVADState;
begin
  V := @E.sVAD;
  DecFL1 := Sar32(E.frame_length, 1);
  DecFL2 := Sar32(E.frame_length, 2);
  DecFL := Sar32(E.frame_length, 3);
  XOffset[0] := 0;
  XOffset[1] := DecFL + DecFL2;
  XOffset[2] := XOffset[1] + DecFL;
  XOffset[3] := XOffset[2] + DecFL2;
  SilkAnaFiltBank1(PIn, @V.AnaState[0], @X[0], @X[XOffset[3]], E.frame_length);
  SilkAnaFiltBank1(@X[0], @V.AnaState1[0], @X[0], @X[XOffset[2]], DecFL1);
  SilkAnaFiltBank1(@X[0], @V.AnaState2[0], @X[0], @X[XOffset[1]], DecFL2);
  X[DecFL - 1] := SmallInt(Sar32(X[DecFL - 1], 1));
  HPstateTmp := X[DecFL - 1];
  for I := DecFL - 1 downto 1 do
  begin
    X[I - 1] := SmallInt(Sar32(X[I - 1], 1));
    X[I] := SmallInt(X[I] - X[I - 1]);
  end;
  X[0] := SmallInt(X[0] - V.HPstate);
  V.HPstate := HPstateTmp;
  for B := 0 to VAD_N_BANDS - 1 do
  begin
    if VAD_N_BANDS - B < VAD_N_BANDS - 1 then
      DecFL := Sar32(E.frame_length, VAD_N_BANDS - B)
    else
      DecFL := Sar32(E.frame_length, VAD_N_BANDS - 1);
    DecSubfrLen := Sar32(DecFL, VAD_INTERNAL_SUBFRAMES_LOG2);
    DecSubfrOff := 0;
    Xnrg[B] := V.XnrgSubfr[B];
    for S := 0 to VAD_INTERNAL_SUBFRAMES - 1 do
    begin
      SumSquared := 0;
      for I := 0 to DecSubfrLen - 1 do
      begin
        XTmp := Sar32(X[XOffset[B] + I + DecSubfrOff], 3);
        SumSquared := SilkSMLABB(SumSquared, XTmp, XTmp);
      end;
      if S < VAD_INTERNAL_SUBFRAMES - 1 then
        Xnrg[B] := SilkAddPosSat32(Xnrg[B], SumSquared)
      else
        Xnrg[B] := SilkAddPosSat32(Xnrg[B], Sar32(SumSquared, 1));
      Inc(DecSubfrOff, DecSubfrLen);
    end;
    V.XnrgSubfr[B] := SumSquared;
  end;
  VADGetNoiseLevels(@Xnrg[0], V^);
  SumSquared := 0;
  InputTilt := 0;
  for B := 0 to VAD_N_BANDS - 1 do
  begin
    SpeechNrg := Xnrg[B] - V.NL[B];
    if SpeechNrg > 0 then
    begin
      if (Cardinal(Xnrg[B]) and $FF800000) = 0 then
        NrgToNoiseRatioQ8[B] := (Xnrg[B] shl 8) div (V.NL[B] + 1)
      else
        NrgToNoiseRatioQ8[B] := Xnrg[B] div (Sar32(V.NL[B], 8) + 1);
      SNRQ7 := SilkLin2Log(NrgToNoiseRatioQ8[B]) - 8 * 128;
      SumSquared := SilkSMLABB(SumSquared, SNRQ7, SNRQ7);
      if SpeechNrg < (1 shl 20) then
        SNRQ7 := SilkSMULWB(SilkSqrtApprox(SpeechNrg) shl 6, SNRQ7);
      InputTilt := SilkSMLAWB(InputTilt, TILT_WEIGHTS[B], SNRQ7);
    end
    else
      NrgToNoiseRatioQ8[B] := 256;
  end;
  SumSquared := SumSquared div VAD_N_BANDS;
  PSNRdBQ7 := SmallInt(3 * SilkSqrtApprox(SumSquared));
  SAQ15 := SilkSigmQ15(SilkSMULWB(VAD_SNR_FACTOR_Q16, PSNRdBQ7) - VAD_NEGATIVE_OFFSET_Q5);
  E.input_tilt_Q15 := (SilkSigmQ15(InputTilt) - 16384) shl 1;
  SpeechNrg := 0;
  for B := 0 to VAD_N_BANDS - 1 do
    SpeechNrg := SpeechNrg + (B + 1) * Sar32(Xnrg[B] - V.NL[B], 4);
  if E.frame_length = 20 * E.fs_kHz then
    SpeechNrg := Sar32(SpeechNrg, 1);
  if SpeechNrg <= 0 then
    SAQ15 := Sar32(SAQ15, 1)
  else if SpeechNrg < 16384 then
  begin
    SpeechNrg := SpeechNrg shl 16;
    SpeechNrg := SilkSqrtApprox(SpeechNrg);
    SAQ15 := SilkSMULWB(32768 + SpeechNrg, SAQ15);
  end;
  E.speech_activity_Q8 := Sar32(SAQ15, 7);
  if E.speech_activity_Q8 > 255 then E.speech_activity_Q8 := 255;
  SmoothCoefQ16 := SilkSMULWB(VAD_SNR_SMOOTH_COEF_Q18, SilkSMULWB(SAQ15, SAQ15));
  if E.frame_length = 10 * E.fs_kHz then
    SmoothCoefQ16 := Sar32(SmoothCoefQ16, 1);
  for B := 0 to VAD_N_BANDS - 1 do
  begin
    V.NrgRatioSmth_Q8[B] := SilkSMLAWB(V.NrgRatioSmth_Q8[B], NrgToNoiseRatioQ8[B] - V.NrgRatioSmth_Q8[B], SmoothCoefQ16);
    SNRQ7 := 3 * (SilkLin2Log(V.NrgRatioSmth_Q8[B]) - 8 * 128);
    E.input_quality_bands_Q15[B] := SilkSigmQ15(Sar32(SNRQ7 - 16 * 128, 4));
  end;
  Result := 0;
end;

// ---------------------------------------------------------------------------
// Biquad / LP variable cutoff
// ---------------------------------------------------------------------------

procedure SilkBiquadAltStride1(InP: PSmallInt; B, A: PInteger; S: PInteger; OutP: PSmallInt; Len: Integer);
var
  K, InVal, A0U, A0L, A1U, A1L, Out32Q14: Integer;
begin
  A0L := (-A[0]) and $00003FFF;
  A0U := Sar32(-A[0], 14);
  A1L := (-A[1]) and $00003FFF;
  A1U := Sar32(-A[1], 14);
  for K := 0 to Len - 1 do
  begin
    InVal := InP[K];
    Out32Q14 := SilkSMLAWB(S[0], B[0], InVal) shl 2;
    S[0] := S[1] + SilkRShiftRound(SilkSMULWB(Out32Q14, A0L), 14);
    S[0] := SilkSMLAWB(S[0], Out32Q14, A0U);
    S[0] := SilkSMLAWB(S[0], B[1], InVal);
    S[1] := SilkRShiftRound(SilkSMULWB(Out32Q14, A1L), 14);
    S[1] := SilkSMLAWB(S[1], Out32Q14, A1U);
    S[1] := SilkSMLAWB(S[1], B[2], InVal);
    OutP[K] := SilkSat16S(Sar32(Out32Q14 + (1 shl 14) - 1, 14));
  end;
end;

procedure LPInterpolateFilterTaps(B, A: PInteger; Ind, FacQ16: Integer);
var
  NB, NA: Integer;
begin
  if Ind < TRANSITION_INT_NUM - 1 then
  begin
    if FacQ16 > 0 then
    begin
      if FacQ16 < 32768 then
      begin
        for NB := 0 to TRANSITION_NB - 1 do
          B[NB] := SilkSMLAWB(SE_TRANSITION_LP_B_Q28[Ind, NB],
            SE_TRANSITION_LP_B_Q28[Ind + 1, NB] - SE_TRANSITION_LP_B_Q28[Ind, NB], FacQ16);
        for NA := 0 to TRANSITION_NA - 1 do
          A[NA] := SilkSMLAWB(SE_TRANSITION_LP_A_Q28[Ind, NA],
            SE_TRANSITION_LP_A_Q28[Ind + 1, NA] - SE_TRANSITION_LP_A_Q28[Ind, NA], FacQ16);
      end
      else
      begin
        for NB := 0 to TRANSITION_NB - 1 do
          B[NB] := SilkSMLAWB(SE_TRANSITION_LP_B_Q28[Ind + 1, NB],
            SE_TRANSITION_LP_B_Q28[Ind + 1, NB] - SE_TRANSITION_LP_B_Q28[Ind, NB], FacQ16 - (1 shl 16));
        for NA := 0 to TRANSITION_NA - 1 do
          A[NA] := SilkSMLAWB(SE_TRANSITION_LP_A_Q28[Ind + 1, NA],
            SE_TRANSITION_LP_A_Q28[Ind + 1, NA] - SE_TRANSITION_LP_A_Q28[Ind, NA], FacQ16 - (1 shl 16));
      end;
    end
    else
    begin
      for NB := 0 to TRANSITION_NB - 1 do B[NB] := SE_TRANSITION_LP_B_Q28[Ind, NB];
      for NA := 0 to TRANSITION_NA - 1 do A[NA] := SE_TRANSITION_LP_A_Q28[Ind, NA];
    end;
  end
  else
  begin
    for NB := 0 to TRANSITION_NB - 1 do B[NB] := SE_TRANSITION_LP_B_Q28[TRANSITION_INT_NUM - 1, NB];
    for NA := 0 to TRANSITION_NA - 1 do A[NA] := SE_TRANSITION_LP_A_Q28[TRANSITION_INT_NUM - 1, NA];
  end;
end;

procedure SilkLPVariableCutoff(var LP: TSilkLPState; Frame: PSmallInt; FrameLength: Integer);
var
  B: array[0..TRANSITION_NB - 1] of Integer;
  A: array[0..TRANSITION_NA - 1] of Integer;
  FacQ16, Ind: Integer;
begin
  if LP.mode <> 0 then
  begin
    // TRANSITION_INT_STEPS = 64
    FacQ16 := (TRANSITION_FRAMES - LP.transition_frame_no) shl (16 - 6);
    Ind := Sar32(FacQ16, 16);
    FacQ16 := FacQ16 - (Ind shl 16);
    LPInterpolateFilterTaps(@B[0], @A[0], Ind, FacQ16);
    LP.transition_frame_no := SilkLimit(LP.transition_frame_no + LP.mode, 0, TRANSITION_FRAMES);
    SilkBiquadAltStride1(Frame, @B[0], @A[0], @LP.In_LP_State[0], Frame, FrameLength);
  end;
end;

// ---------------------------------------------------------------------------
// Gains
// ---------------------------------------------------------------------------

const
  GQ_OFFSET = (MIN_QGAIN_DB * 128) div 6 + 16 * 128;
  GQ_SCALE_Q16 = (65536 * (N_LEVELS_QGAIN - 1)) div (((MAX_QGAIN_DB - MIN_QGAIN_DB) * 128) div 6);
  GQ_INV_SCALE_Q16 = (65536 * (((MAX_QGAIN_DB - MIN_QGAIN_DB) * 128) div 6)) div (N_LEVELS_QGAIN - 1);

procedure SilkGainsQuant(Ind: PShortInt; GainQ16: PInteger; var PrevInd: ShortInt; Conditional, NbSubfr: Integer);
var
  K, Thr, T: Integer;
begin
  for K := 0 to NbSubfr - 1 do
  begin
    Ind[K] := ShortInt(SilkSMULWB(GQ_SCALE_Q16, SilkLin2Log(GainQ16[K]) - GQ_OFFSET));
    if Ind[K] < PrevInd then
      Ind[K] := ShortInt(Ind[K] + 1);
    Ind[K] := ShortInt(SilkLimit(Ind[K], 0, N_LEVELS_QGAIN - 1));
    if (K = 0) and (Conditional = 0) then
    begin
      Ind[K] := ShortInt(SilkLimit(Ind[K], PrevInd + MIN_DELTA_GAIN_QUANT, N_LEVELS_QGAIN - 1));
      PrevInd := Ind[K];
    end
    else
    begin
      Ind[K] := ShortInt(Ind[K] - PrevInd);
      Thr := 2 * MAX_DELTA_GAIN_QUANT - N_LEVELS_QGAIN + PrevInd;
      if Ind[K] > Thr then
        Ind[K] := ShortInt(Thr + Sar32(Ind[K] - Thr + 1, 1));
      Ind[K] := ShortInt(SilkLimit(Ind[K], MIN_DELTA_GAIN_QUANT, MAX_DELTA_GAIN_QUANT));
      if Ind[K] > Thr then
      begin
        T := PrevInd + (Ind[K] shl 1) - Thr;
        if T > N_LEVELS_QGAIN - 1 then T := N_LEVELS_QGAIN - 1;
        PrevInd := ShortInt(T);
      end
      else
        PrevInd := ShortInt(PrevInd + Ind[K]);
      Ind[K] := ShortInt(Ind[K] - MIN_DELTA_GAIN_QUANT);
    end;
    T := SilkSMULWB(GQ_INV_SCALE_Q16, PrevInd) + GQ_OFFSET;
    if T > 3967 then T := 3967;
    GainQ16[K] := SilkLog2Lin(T);
  end;
end;

procedure SilkGainsDequant(GainQ16: PInteger; Ind: PShortInt; var PrevInd: ShortInt; Conditional, NbSubfr: Integer);
var
  K, IndTmp, Thr, P, T: Integer;
begin
  for K := 0 to NbSubfr - 1 do
  begin
    P := PrevInd;
    if (K = 0) and (Conditional = 0) then
    begin
      if Ind[K] > P - 16 then P := Ind[K] else P := P - 16;
    end
    else
    begin
      IndTmp := Ind[K] + MIN_DELTA_GAIN_QUANT;
      Thr := 2 * MAX_DELTA_GAIN_QUANT - N_LEVELS_QGAIN + P;
      if IndTmp > Thr then
        P := P + (IndTmp shl 1) - Thr
      else
        P := P + IndTmp;
    end;
    // prev_ind is an opus_int8: the accumulation wraps before the limit
    P := ShortInt(P);
    P := SilkLimit(P, 0, N_LEVELS_QGAIN - 1);
    PrevInd := ShortInt(P);
    T := SilkSMULWB(GQ_INV_SCALE_Q16, P) + GQ_OFFSET;
    if T > 3967 then T := 3967;
    GainQ16[K] := SilkLog2Lin(T);
  end;
end;

function SilkGainsID(Ind: PShortInt; NbSubfr: Integer): Integer;
var
  K: Integer;
begin
  Result := 0;
  for K := 0 to NbSubfr - 1 do
    Result := Ind[K] + (Result shl 8);
end;

procedure SilkInterpolate(Xi, X0, X1: PSmallInt; IfactQ2, D: Integer);
var
  I: Integer;
begin
  for I := 0 to D - 1 do
    Xi[I] := SmallInt(X0[I] + Sar32(SilkSMULBB(X1[I] - X0[I], IfactQ2), 2));
end;

end.
