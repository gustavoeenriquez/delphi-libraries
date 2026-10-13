unit OpusSilkMath;

{
  OpusSilkMath.pas - SILK fixed-point arithmetic and signal-processing helpers

  Ported from libopus 1.5.2 silk/macros.h, SigProc_FIX.h, Inlines.h, log2lin.c,
  lin2log.c, bwexpander.c, bwexpander_32.c, LPC_fit.c, LPC_inv_pred_gain.c,
  LPC_analysis_filter.c, sum_sqr_shift.c, NLSF2A.c, NLSF_stabilize.c, sort.c.
  Copyright (c) 2006-2011 Skype Limited, Xiph.Org Foundation; BSD license.

  All operations replicate the 32-bit two's complement semantics of the
  reference (arithmetic shifts, wrap-around where the reference wraps).

  License of this unit: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  SysUtils, Math,
  OpusEntDec,
  OpusSilkTables;

const
  SILK_MAX_LPC_ORDER   = 16;
  SILK_MIN_LPC_ORDER   = 10;
  SILK_MAX_NB_SUBFR    = 4;
  SILK_LTP_ORDER       = 5;
  SILK_MAX_FS_KHZ      = 16;
  SILK_SUB_FRAME_LENGTH_MS = 5;
  SILK_MAX_SUB_FRAME_LENGTH = SILK_SUB_FRAME_LENGTH_MS * SILK_MAX_FS_KHZ;   // 80
  SILK_MAX_FRAME_LENGTH_MS = SILK_SUB_FRAME_LENGTH_MS * SILK_MAX_NB_SUBFR;  // 20
  SILK_MAX_FRAME_LENGTH = SILK_MAX_FRAME_LENGTH_MS * SILK_MAX_FS_KHZ;       // 320
  SILK_LTP_MEM_LENGTH_MS = 20;
  SILK_MAX_FRAMES_PER_PACKET = 3;
  SILK_SHELL_CODEC_FRAME_LENGTH = 16;
  SILK_LOG2_SHELL_CODEC_FRAME_LENGTH = 4;
  SILK_MAX_NB_SHELL_BLOCKS = SILK_MAX_FRAME_LENGTH div SILK_SHELL_CODEC_FRAME_LENGTH;
  SILK_N_RATE_LEVELS = 10;
  SILK_MAX_PULSES = 16;
  SILK_NLSF_QUANT_MAX_AMPLITUDE = 4;
  SILK_MAX_LPC_STABILIZE_ITERATIONS = 16;
  SILK_LSF_COS_TAB_SZ_FIX = 128;
  SILK_TYPE_NO_VOICE_ACTIVITY = 0;
  SILK_TYPE_UNVOICED = 1;
  SILK_TYPE_VOICED = 2;
  SILK_CODE_INDEPENDENTLY = 0;
  SILK_CODE_INDEPENDENTLY_NO_LTP_SCALING = 1;
  SILK_CODE_CONDITIONALLY = 2;
  SILK_MIN_QGAIN_DB = 2;
  SILK_MAX_QGAIN_DB = 88;
  SILK_N_LEVELS_QGAIN = 64;
  SILK_MAX_DELTA_GAIN_QUANT = 36;
  SILK_MIN_DELTA_GAIN_QUANT = -4;
  SILK_QUANT_LEVEL_ADJUST_Q10 = 80;
  SILK_BWE_AFTER_LOSS_Q16 = 63570;
  SILK_MAX_PREDICTION_POWER_GAIN = 1e4;
  SILK_STEREO_QUANT_SUB_STEPS = 5;
  SILK_STEREO_INTERP_LEN_MS = 8;
  SILK_PE_MAX_NB_SUBFR = 4;
  SILK_PE_NB_CBKS_STAGE2_EXT = 11;
  SILK_PE_NB_CBKS_STAGE3_MAX = 34;
  SILK_PE_NB_CBKS_STAGE2_10MS = 3;
  SILK_PE_NB_CBKS_STAGE3_10MS = 12;
  SILK_PE_MIN_LAG_MS = 2;
  SILK_PE_MAX_LAG_MS = 18;
  SILK_CNG_BUF_MASK_MAX = 255;
  SILK_CNG_GAIN_SMTH_Q16 = 4634;
  SILK_CNG_GAIN_SMTH_THRESHOLD_Q16 = 46396;
  SILK_CNG_NLSF_SMTH_Q16 = 16348;
  SILK_INT32_MAX = 2147483647;
  SILK_INT32_MIN = Integer($80000000);
  SILK_INT16_MAX = 32767;
  SILK_INT16_MIN = -32768;

type
  PSmallInt = ^SmallInt;
  PShortInt = ^ShortInt;

function  Sar32(A: Integer; N: Integer): Integer; inline;
function  Sar64(A: Int64; N: Integer): Int64; inline;
function  SilkSMULWB(A, B: Integer): Integer; inline;
function  SilkSMLAWB(A, B, C: Integer): Integer; inline;
function  SilkSMULWT(A, B: Integer): Integer; inline;
function  SilkSMULBB(A, B: Integer): Integer; inline;
function  SilkSMLABB(A, B, C: Integer): Integer; inline;
function  SilkSMULWW(A, B: Integer): Integer; inline;
function  SilkSMLAWW(A, B, C: Integer): Integer; inline;
function  SilkSMULTT(A, B: Integer): Integer; inline;
function  SilkSMMUL(A, B: Integer): Integer; inline;
function  SilkSMULL(A, B: Integer): Int64; inline;
function  SilkAddSat32(A, B: Integer): Integer; inline;
function  SilkSubSat32(A, B: Integer): Integer; inline;
function  SilkSat16(A: Integer): Integer; inline;
function  SilkRShiftRound(A: Integer; Shift: Integer): Integer; inline;
function  SilkRShiftRound64(A: Int64; Shift: Integer): Int64; inline;
function  SilkLShiftSat32(A: Integer; Shift: Integer): Integer; inline;
function  SilkLimit(A, L1, L2: Integer): Integer; inline;
function  SilkAbs(A: Integer): Integer; inline;
function  SilkCLZ32(V: Integer): Integer; inline;
procedure SilkCLZFrac(V: Integer; out Lz, FracQ7: Integer);
function  SilkROR32(A: Integer; Rot: Integer): Integer;
function  SilkSqrtApprox(X: Integer): Integer;
function  SilkDIV32VarQ(A32, B32: Integer; Qres: Integer): Integer;
function  SilkINVERSE32VarQ(B32: Integer; Qres: Integer): Integer;
function  SilkLog2Lin(InLogQ7: Integer): Integer;
function  SilkLin2Log(InLin: Integer): Integer;
function  SilkRand(Seed: Integer): Integer; inline;

procedure SilkBwExpander(Ar: PSmallInt; D: Integer; ChirpQ16: Integer);
procedure SilkBwExpander32(Ar: PInteger; D: Integer; ChirpQ16: Integer);
procedure SilkLPCFit(AQOut: PSmallInt; AQIn: PInteger; QOUT, QIN, D: Integer);
function  SilkLPCInversePredGain(AQ12: PSmallInt; Order: Integer): Integer;
procedure SilkLPCAnalysisFilter(OutP: PSmallInt; InP: PSmallInt; B: PSmallInt; Len, D: Integer);
procedure SilkSumSqrShift(out Energy: Integer; out Shift: Integer; X: PSmallInt; Len: Integer);
procedure SilkNLSF2A(AQ12: PSmallInt; NLSF: PSmallInt; D: Integer);
procedure SilkNLSFStabilize(NLSFQ15: PSmallInt; NDeltaMinQ15: PSmallInt; L: Integer);
procedure SilkInsertionSortIncreasingAllValuesInt16(A: PSmallInt; L: Integer);

implementation

function Sar32(A: Integer; N: Integer): Integer;
begin
  if N <= 0 then Exit(A);
  if N >= 32 then
  begin
    if A < 0 then Exit(-1) else Exit(0);
  end;
  Result := Integer(Cardinal(A) shr N);
  if A < 0 then
    Result := Result or Integer(Cardinal($FFFFFFFF) shl (32 - N));
end;

function Sar64(A: Int64; N: Integer): Int64;
begin
  if N <= 0 then Exit(A);
  if N >= 64 then
  begin
    if A < 0 then Exit(-1) else Exit(0);
  end;
  Result := Int64(UInt64(A) shr N);
  if A < 0 then
    Result := Result or Int64(UInt64($FFFFFFFFFFFFFFFF) shl (64 - N));
end;

function SilkSMULWB(A, B: Integer): Integer;
begin
  Result := Integer(Sar64(Int64(A) * Int64(SmallInt(B)), 16));
end;

function SilkSMLAWB(A, B, C: Integer): Integer;
begin
  Result := A + Integer(Sar64(Int64(B) * Int64(SmallInt(C)), 16));
end;

function SilkSMULWT(A, B: Integer): Integer;
begin
  Result := Integer(Sar64(Int64(A) * Int64(Sar32(B, 16)), 16));
end;

function SilkSMULBB(A, B: Integer): Integer;
begin
  Result := Integer(SmallInt(A)) * Integer(SmallInt(B));
end;

function SilkSMLABB(A, B, C: Integer): Integer;
begin
  Result := A + Integer(SmallInt(B)) * Integer(SmallInt(C));
end;

function SilkSMULWW(A, B: Integer): Integer;
begin
  Result := Integer(Sar64(Int64(A) * Int64(B), 16));
end;

function SilkSMLAWW(A, B, C: Integer): Integer;
begin
  Result := A + Integer(Sar64(Int64(B) * Int64(C), 16));
end;

function SilkSMULTT(A, B: Integer): Integer;
begin
  Result := Sar32(A, 16) * Sar32(B, 16);
end;

function SilkSMMUL(A, B: Integer): Integer;
begin
  Result := Integer(Sar64(Int64(A) * Int64(B), 32));
end;

function SilkSMULL(A, B: Integer): Int64;
begin
  Result := Int64(A) * Int64(B);
end;

function SilkAddSat32(A, B: Integer): Integer;
var
  S: Int64;
begin
  S := Int64(A) + Int64(B);
  if S > SILK_INT32_MAX then Result := SILK_INT32_MAX
  else if S < SILK_INT32_MIN then Result := SILK_INT32_MIN
  else Result := Integer(S);
end;

function SilkSubSat32(A, B: Integer): Integer;
var
  S: Int64;
begin
  S := Int64(A) - Int64(B);
  if S > SILK_INT32_MAX then Result := SILK_INT32_MAX
  else if S < SILK_INT32_MIN then Result := SILK_INT32_MIN
  else Result := Integer(S);
end;

function SilkSat16(A: Integer): Integer;
begin
  if A > SILK_INT16_MAX then Result := SILK_INT16_MAX
  else if A < SILK_INT16_MIN then Result := SILK_INT16_MIN
  else Result := A;
end;

function SilkRShiftRound(A: Integer; Shift: Integer): Integer;
begin
  if Shift = 1 then Result := Sar32(A, 1) + (A and 1)
  else Result := Sar32(Sar32(A, Shift - 1) + 1, 1);
end;

function SilkRShiftRound64(A: Int64; Shift: Integer): Int64;
begin
  if Shift = 1 then Result := Sar64(A, 1) + (A and 1)
  else Result := Sar64(Sar64(A, Shift - 1) + 1, 1);
end;

function SilkLShiftSat32(A: Integer; Shift: Integer): Integer;
begin
  Result := SilkLimit(A, Sar32(SILK_INT32_MIN, Shift), Sar32(SILK_INT32_MAX, Shift)) shl Shift;
end;

function SilkLimit(A, L1, L2: Integer): Integer;
begin
  if L1 > L2 then
  begin
    if A > L1 then Result := L1
    else if A < L2 then Result := L2
    else Result := A;
  end
  else
  begin
    if A > L2 then Result := L2
    else if A < L1 then Result := L1
    else Result := A;
  end;
end;

function SilkAbs(A: Integer): Integer;
begin
  if A > 0 then Result := A else Result := -A;
end;

function SilkCLZ32(V: Integer): Integer;
begin
  if V = 0 then Result := 32
  else Result := 32 - EcIlog(Cardinal(V));
end;

procedure SilkCLZFrac(V: Integer; out Lz, FracQ7: Integer);
begin
  Lz := SilkCLZ32(V);
  FracQ7 := SilkROR32(V, 24 - Lz) and $7F;
end;

function SilkROR32(A: Integer; Rot: Integer): Integer;
var
  X, R, M: Cardinal;
begin
  X := Cardinal(A);
  if Rot = 0 then Exit(A);
  if Rot < 0 then
  begin
    M := Cardinal(-Rot);
    Result := Integer((X shl M) or (X shr (32 - M)));
  end
  else
  begin
    R := Cardinal(Rot);
    Result := Integer((X shl (32 - R)) or (X shr R));
  end;
end;

function SilkSqrtApprox(X: Integer): Integer;
var
  Y, Lz, FracQ7: Integer;
begin
  if X <= 0 then Exit(0);
  SilkCLZFrac(X, Lz, FracQ7);
  if (Lz and 1) <> 0 then Y := 32768
  else Y := 46214;
  Y := Sar32(Y, Sar32(Lz, 1));
  Y := SilkSMLAWB(Y, Y, SilkSMULBB(213, FracQ7));
  Result := Y;
end;

function SilkDIV32VarQ(A32, B32: Integer; Qres: Integer): Integer;
var
  AHeadrm, BHeadrm, LShift: Integer;
  B32Inv, A32Nrm, B32Nrm, Res: Integer;
begin
  AHeadrm := SilkCLZ32(SilkAbs(A32)) - 1;
  A32Nrm := A32 shl AHeadrm;
  BHeadrm := SilkCLZ32(SilkAbs(B32)) - 1;
  B32Nrm := B32 shl BHeadrm;
  B32Inv := (SILK_INT32_MAX shr 2) div Sar32(B32Nrm, 16);
  Res := SilkSMULWB(A32Nrm, B32Inv);
  A32Nrm := Integer(Cardinal(A32Nrm) - Cardinal(SilkSMMUL(B32Nrm, Res) shl 3));
  Res := SilkSMLAWB(Res, A32Nrm, B32Inv);
  LShift := 29 + AHeadrm - BHeadrm - Qres;
  if LShift < 0 then
    Result := SilkLShiftSat32(Res, -LShift)
  else if LShift < 32 then
    Result := Sar32(Res, LShift)
  else
    Result := 0;
end;

function SilkINVERSE32VarQ(B32: Integer; Qres: Integer): Integer;
var
  BHeadrm, LShift: Integer;
  B32Inv, B32Nrm, ErrQ32, Res: Integer;
begin
  BHeadrm := SilkCLZ32(SilkAbs(B32)) - 1;
  B32Nrm := B32 shl BHeadrm;
  B32Inv := (SILK_INT32_MAX shr 2) div Sar32(B32Nrm, 16);
  Res := B32Inv shl 16;
  ErrQ32 := ((1 shl 29) - SilkSMULWB(B32Nrm, B32Inv)) shl 3;
  Res := SilkSMLAWW(Res, ErrQ32, B32Inv);
  LShift := 61 - BHeadrm - Qres;
  if LShift <= 0 then
    Result := SilkLShiftSat32(Res, -LShift)
  else if LShift < 32 then
    Result := Sar32(Res, LShift)
  else
    Result := 0;
end;

function SilkLog2Lin(InLogQ7: Integer): Integer;
var
  OutV, FracQ7: Integer;
begin
  if InLogQ7 < 0 then Exit(0)
  else if InLogQ7 >= 3967 then Exit(SILK_INT32_MAX);
  OutV := 1 shl Sar32(InLogQ7, 7);
  FracQ7 := InLogQ7 and $7F;
  if InLogQ7 < 2048 then
    OutV := OutV + Sar32(OutV * SilkSMLAWB(FracQ7, SilkSMULBB(FracQ7, 128 - FracQ7), -174), 7)
  else
    OutV := OutV + Sar32(OutV, 7) * SilkSMLAWB(FracQ7, SilkSMULBB(FracQ7, 128 - FracQ7), -174);
  Result := OutV;
end;

function SilkLin2Log(InLin: Integer): Integer;
var
  Lz, FracQ7: Integer;
begin
  SilkCLZFrac(InLin, Lz, FracQ7);
  Result := SilkSMLAWB(FracQ7, FracQ7 * (128 - FracQ7), 179) + ((31 - Lz) shl 7);
end;

function SilkRand(Seed: Integer): Integer;
begin
  Result := Integer(Cardinal(907633515) + Cardinal(Seed) * Cardinal(196314165));
end;

// ---------------------------------------------------------------------------

procedure SilkBwExpander(Ar: PSmallInt; D: Integer; ChirpQ16: Integer);
var
  I: Integer;
  ChirpMinusOneQ16: Integer;
begin
  ChirpMinusOneQ16 := ChirpQ16 - 65536;
  for I := 0 to D - 2 do
  begin
    Ar[I] := SmallInt(SilkRShiftRound(ChirpQ16 * Ar[I], 16));
    ChirpQ16 := ChirpQ16 + SilkRShiftRound(ChirpQ16 * ChirpMinusOneQ16, 16);
  end;
  Ar[D - 1] := SmallInt(SilkRShiftRound(ChirpQ16 * Ar[D - 1], 16));
end;

procedure SilkBwExpander32(Ar: PInteger; D: Integer; ChirpQ16: Integer);
var
  I: Integer;
  ChirpMinusOneQ16: Integer;
begin
  ChirpMinusOneQ16 := ChirpQ16 - 65536;
  for I := 0 to D - 2 do
  begin
    Ar[I] := SilkSMULWW(ChirpQ16, Ar[I]);
    ChirpQ16 := ChirpQ16 + SilkRShiftRound(ChirpQ16 * ChirpMinusOneQ16, 16);
  end;
  Ar[D - 1] := SilkSMULWW(ChirpQ16, Ar[D - 1]);
end;

procedure SilkLPCFit(AQOut: PSmallInt; AQIn: PInteger; QOUT, QIN, D: Integer);
var
  I, K, Idx: Integer;
  MaxAbs, AbsVal, ChirpQ16: Integer;
begin
  Idx := 0;
  I := 0;
  while I < 10 do
  begin
    MaxAbs := 0;
    for K := 0 to D - 1 do
    begin
      AbsVal := SilkAbs(AQIn[K]);
      if AbsVal > MaxAbs then
      begin
        MaxAbs := AbsVal;
        Idx := K;
      end;
    end;
    MaxAbs := SilkRShiftRound(MaxAbs, QIN - QOUT);
    if MaxAbs > SILK_INT16_MAX then
    begin
      MaxAbs := Min(MaxAbs, 163838);
      ChirpQ16 := 65470 - (((MaxAbs - SILK_INT16_MAX) shl 14) div Sar32(MaxAbs * (Idx + 1), 2));
      SilkBwExpander32(AQIn, D, ChirpQ16);
    end
    else
      Break;
    Inc(I);
  end;
  if I = 10 then
  begin
    for K := 0 to D - 1 do
    begin
      AQOut[K] := SmallInt(SilkSat16(SilkRShiftRound(AQIn[K], QIN - QOUT)));
      AQIn[K] := Integer(AQOut[K]) shl (QIN - QOUT);
    end;
  end
  else
    for K := 0 to D - 1 do
      AQOut[K] := SmallInt(SilkRShiftRound(AQIn[K], QIN - QOUT));
end;

const
  LPC_QA = 24;
  LPC_A_LIMIT = 16773022;   // SILK_FIX_CONST(0.99975, 24)

function Mul32FracQ(A32, B32: Integer; Q: Integer): Integer; inline;
begin
  Result := Integer(SilkRShiftRound64(SilkSMULL(A32, B32), Q));
end;

function LPCInversePredGainQA(AQA: PInteger; Order: Integer): Integer;
var
  K, N, Mult2Q: Integer;
  InvGainQ30, RcQ31, RcMult1Q30, RcMult2, Tmp1, Tmp2: Integer;
  Tmp64: Int64;
  MinInv: Integer;
begin
  MinInv := Round((1.0 / SILK_MAX_PREDICTION_POWER_GAIN) * (Int64(1) shl 30) + 0.5);
  InvGainQ30 := 1 shl 30;
  K := Order - 1;
  while K > 0 do
  begin
    if (AQA[K] > LPC_A_LIMIT) or (AQA[K] < -LPC_A_LIMIT) then Exit(0);
    RcQ31 := -(AQA[K] shl (31 - LPC_QA));
    RcMult1Q30 := (1 shl 30) - SilkSMMUL(RcQ31, RcQ31);
    InvGainQ30 := SilkSMMUL(InvGainQ30, RcMult1Q30) shl 2;
    if InvGainQ30 < MinInv then Exit(0);
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
    Dec(K);
  end;
  if (AQA[0] > LPC_A_LIMIT) or (AQA[0] < -LPC_A_LIMIT) then Exit(0);
  RcQ31 := -(AQA[0] shl (31 - LPC_QA));
  RcMult1Q30 := (1 shl 30) - SilkSMMUL(RcQ31, RcQ31);
  InvGainQ30 := SilkSMMUL(InvGainQ30, RcMult1Q30) shl 2;
  if InvGainQ30 < MinInv then Exit(0);
  Result := InvGainQ30;
end;

function SilkLPCInversePredGain(AQ12: PSmallInt; Order: Integer): Integer;
var
  K: Integer;
  AtmpQA: array[0..SILK_MAX_LPC_ORDER - 1] of Integer;
  DCResp: Integer;
begin
  DCResp := 0;
  for K := 0 to Order - 1 do
  begin
    DCResp := DCResp + AQ12[K];
    AtmpQA[K] := Integer(AQ12[K]) shl (LPC_QA - 12);
  end;
  if DCResp >= 4096 then Exit(0);
  Result := LPCInversePredGainQA(@AtmpQA[0], Order);
end;

procedure SilkLPCAnalysisFilter(OutP: PSmallInt; InP: PSmallInt; B: PSmallInt; Len, D: Integer);
var
  Ix, J: Integer;
  Out32Q12, Out32: Integer;
  InPtr: PSmallInt;
begin
  for Ix := D to Len - 1 do
  begin
    InPtr := InP + (Ix - 1);
    Out32Q12 := SilkSMULBB(InPtr[0], B[0]);
    Out32Q12 := Integer(Cardinal(Out32Q12) + Cardinal(SilkSMULBB(InPtr[-1], B[1])));
    Out32Q12 := Integer(Cardinal(Out32Q12) + Cardinal(SilkSMULBB(InPtr[-2], B[2])));
    Out32Q12 := Integer(Cardinal(Out32Q12) + Cardinal(SilkSMULBB(InPtr[-3], B[3])));
    Out32Q12 := Integer(Cardinal(Out32Q12) + Cardinal(SilkSMULBB(InPtr[-4], B[4])));
    Out32Q12 := Integer(Cardinal(Out32Q12) + Cardinal(SilkSMULBB(InPtr[-5], B[5])));
    J := 6;
    while J < D do
    begin
      Out32Q12 := Integer(Cardinal(Out32Q12) + Cardinal(SilkSMULBB(InPtr[-J], B[J])));
      Out32Q12 := Integer(Cardinal(Out32Q12) + Cardinal(SilkSMULBB(InPtr[-J - 1], B[J + 1])));
      Inc(J, 2);
    end;
    Out32Q12 := Integer(Cardinal(Integer(InPtr[1]) shl 12) - Cardinal(Out32Q12));
    Out32 := SilkRShiftRound(Out32Q12, 12);
    OutP[Ix] := SmallInt(SilkSat16(Out32));
  end;
  for Ix := 0 to D - 1 do
    OutP[Ix] := 0;
end;

procedure SilkSumSqrShift(out Energy: Integer; out Shift: Integer; X: PSmallInt; Len: Integer);
var
  I, Shft: Integer;
  NrgTmp: Cardinal;
  Nrg: Integer;
begin
  Shft := 31 - SilkCLZ32(Len);
  Nrg := Len;
  I := 0;
  while I < Len - 1 do
  begin
    NrgTmp := Cardinal(SilkSMULBB(X[I], X[I]));
    NrgTmp := NrgTmp + Cardinal(SilkSMULBB(X[I + 1], X[I + 1]));
    Nrg := Integer(Cardinal(Nrg) + (NrgTmp shr Shft));
    Inc(I, 2);
  end;
  if I < Len then
  begin
    NrgTmp := Cardinal(SilkSMULBB(X[I], X[I]));
    Nrg := Integer(Cardinal(Nrg) + (NrgTmp shr Shft));
  end;
  Shft := Max(0, Shft + 3 - SilkCLZ32(Nrg));
  Nrg := 0;
  I := 0;
  while I < Len - 1 do
  begin
    NrgTmp := Cardinal(SilkSMULBB(X[I], X[I]));
    NrgTmp := NrgTmp + Cardinal(SilkSMULBB(X[I + 1], X[I + 1]));
    Nrg := Integer(Cardinal(Nrg) + (NrgTmp shr Shft));
    Inc(I, 2);
  end;
  if I < Len then
  begin
    NrgTmp := Cardinal(SilkSMULBB(X[I], X[I]));
    Nrg := Integer(Cardinal(Nrg) + (NrgTmp shr Shft));
  end;
  Shift := Shft;
  Energy := Nrg;
end;

// ---------------------------------------------------------------------------
// NLSF2A
// ---------------------------------------------------------------------------

const
  NLSF_QA = 16;

procedure NLSF2AFindPoly(OutP: PInteger; CLSF: PInteger; Dd: Integer);
var
  K, N: Integer;
  Ftmp: Integer;
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

procedure SilkNLSF2A(AQ12: PSmallInt; NLSF: PSmallInt; D: Integer);
const
  Ordering16: array[0..15] of Byte = (0, 15, 8, 7, 4, 11, 12, 3, 2, 13, 10, 5, 6, 9, 14, 1);
  Ordering10: array[0..9] of Byte = (0, 9, 6, 3, 4, 5, 8, 1, 2, 7);
var
  Ordering: PByte;
  K, I, Dd: Integer;
  CosLSFQA: array[0..SILK_MAX_LPC_ORDER - 1] of Integer;
  P, Q: array[0..SILK_MAX_LPC_ORDER div 2] of Integer;
  Ptmp, Qtmp, FInt, FFrac, CosVal, Delta: Integer;
  A32QA1: array[0..SILK_MAX_LPC_ORDER - 1] of Integer;
begin
  if D = 16 then Ordering := @Ordering16[0] else Ordering := @Ordering10[0];
  for K := 0 to D - 1 do
  begin
    FInt := Sar32(NLSF[K], 15 - 7);
    FFrac := NLSF[K] - (FInt shl (15 - 7));
    CosVal := SILK_LSFCOSTAB_FIX_Q12[FInt];
    Delta := SILK_LSFCOSTAB_FIX_Q12[FInt + 1] - CosVal;
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
  while (SilkLPCInversePredGain(AQ12, D) = 0) and (I < SILK_MAX_LPC_STABILIZE_ITERATIONS) do
  begin
    SilkBwExpander32(@A32QA1[0], D, 65536 - (2 shl I));
    for K := 0 to D - 1 do
      AQ12[K] := SmallInt(SilkRShiftRound(A32QA1[K], NLSF_QA + 1 - 12));
    Inc(I);
  end;
end;

// ---------------------------------------------------------------------------
// NLSF stabilize
// ---------------------------------------------------------------------------

procedure SilkInsertionSortIncreasingAllValuesInt16(A: PSmallInt; L: Integer);
var
  Value, I, J: Integer;
begin
  for I := 1 to L - 1 do
  begin
    Value := A[I];
    J := I - 1;
    while (J >= 0) and (Value < A[J]) do
    begin
      A[J + 1] := A[J];
      Dec(J);
    end;
    A[J + 1] := SmallInt(Value);
  end;
end;

procedure SilkNLSFStabilize(NLSFQ15: PSmallInt; NDeltaMinQ15: PSmallInt; L: Integer);
const
  MAX_LOOPS = 20;
var
  I, II, K, Loops: Integer;
  CenterFreqQ15: SmallInt;
  DiffQ15, MinDiffQ15, MinCenterQ15, MaxCenterQ15: Integer;
begin
  II := 0;
  Loops := 0;
  while Loops < MAX_LOOPS do
  begin
    MinDiffQ15 := NLSFQ15[0] - NDeltaMinQ15[0];
    II := 0;
    for I := 1 to L - 1 do
    begin
      DiffQ15 := NLSFQ15[I] - (NLSFQ15[I - 1] + NDeltaMinQ15[I]);
      if DiffQ15 < MinDiffQ15 then
      begin
        MinDiffQ15 := DiffQ15;
        II := I;
      end;
    end;
    DiffQ15 := (1 shl 15) - (NLSFQ15[L - 1] + NDeltaMinQ15[L]);
    if DiffQ15 < MinDiffQ15 then
    begin
      MinDiffQ15 := DiffQ15;
      II := L;
    end;
    if MinDiffQ15 >= 0 then Exit;
    if II = 0 then
      NLSFQ15[0] := NDeltaMinQ15[0]
    else if II = L then
      NLSFQ15[L - 1] := (1 shl 15) - NDeltaMinQ15[L]
    else
    begin
      MinCenterQ15 := 0;
      for K := 0 to II - 1 do
        MinCenterQ15 := MinCenterQ15 + NDeltaMinQ15[K];
      MinCenterQ15 := MinCenterQ15 + Sar32(NDeltaMinQ15[II], 1);
      MaxCenterQ15 := 1 shl 15;
      for K := L downto II + 1 do
        MaxCenterQ15 := MaxCenterQ15 - NDeltaMinQ15[K];
      MaxCenterQ15 := MaxCenterQ15 - Sar32(NDeltaMinQ15[II], 1);
      CenterFreqQ15 := SmallInt(SilkLimit(SilkRShiftRound(Integer(NLSFQ15[II - 1]) + Integer(NLSFQ15[II]), 1),
        MinCenterQ15, MaxCenterQ15));
      NLSFQ15[II - 1] := CenterFreqQ15 - Sar32(NDeltaMinQ15[II], 1);
      NLSFQ15[II] := NLSFQ15[II - 1] + NDeltaMinQ15[II];
    end;
    Inc(Loops);
  end;
  if Loops = MAX_LOOPS then
  begin
    SilkInsertionSortIncreasingAllValuesInt16(NLSFQ15, L);
    NLSFQ15[0] := SmallInt(Max(NLSFQ15[0], NDeltaMinQ15[0]));
    for I := 1 to L - 1 do
      NLSFQ15[I] := SmallInt(Max(NLSFQ15[I], SilkSat16(Integer(NLSFQ15[I - 1]) + NDeltaMinQ15[I])));
    NLSFQ15[L - 1] := SmallInt(Min(NLSFQ15[L - 1], (1 shl 15) - NDeltaMinQ15[L]));
    for I := L - 2 downto 0 do
      NLSFQ15[I] := SmallInt(Min(NLSFQ15[I], NLSFQ15[I + 1] - NDeltaMinQ15[I + 1]));
  end;
end;

end.
