unit OpusSilkEncDSP;

{
  OpusSilkEncDSP.pas - SILK float signal processing primitives and pitch analysis

  Port of libopus 1.5.2 silk/float/SigProc_FLP.h, energy_FLP.c,
  inner_product_FLP.c, autocorrelation_FLP.c, apply_sine_window_FLP.c,
  burg_modified_FLP.c, bwexpander_FLP.c, k2a_FLP.c, LPC_inv_pred_gain_FLP.c,
  schur_FLP.c, scale_vector_FLP.c, scale_copy_vector_FLP.c, sort_FLP.c,
  LPC_analysis_filter_FLP.c, warped_autocorrelation_FLP.c,
  pitch_analysis_core_FLP.c.
  Copyright (c) 2006-2011 Skype Limited; Xiph.Org Foundation.

  Float semantics follow the C reference compiled for SSE2 (silk_float is
  float, explicit double accumulators stay double).

  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$EXCESSPRECISION OFF}
{$Q-}{$R-}

interface

uses
  Math, OpusSilkMath, OpusSilkEncTables, OpusSilkEncDefs, OpusSilkEncCore, OpusCeltEncMath;

const
  SILK_PI: Single = 3.1415926536;

function  SilkFloat2Int(X: Single): Integer; inline;
procedure SilkFloat2ShortArray(OutP: PSmallInt; InP: PSingle; Length: Integer);
procedure SilkShort2FloatArray(OutP: PSingle; InP: PSmallInt; Length: Integer);
function  SilkSigmoid(X: Single): Single;
function  SilkLog2F(X: Double): Single;
function  SqrtD(X: Double): Double; inline;
function  PowD(X, Y: Double): Double;

function  SilkEnergyFLP(Data: PSingle; DataSize: Integer): Double;
function  SilkInnerProductFLP(Data1, Data2: PSingle; DataSize: Integer): Double;
procedure SilkAutocorrelationFLP(Results, InputData: PSingle; InputDataSize, CorrelationCount: Integer);
procedure SilkApplySineWindowFLP(PxWin, Px: PSingle; WinType, Length: Integer);
function  SilkBurgModifiedFLP(A, X: PSingle; MinInvGain: Single; SubfrLength, NbSubfr, D: Integer): Single;
procedure SilkBwExpanderFLP(Ar: PSingle; D: Integer; Chirp: Single);
procedure SilkK2aFLP(A, Rc: PSingle; Order: Integer);
function  SilkLPCInversePredGainFLP(A: PSingle; Order: Integer): Single;
function  SilkSchurFLP(ReflCoef, AutoCorr: PSingle; Order: Integer): Single;
procedure SilkScaleVectorFLP(Data1: PSingle; Gain: Single; DataSize: Integer);
procedure SilkScaleCopyVectorFLP(DataOut, DataIn: PSingle; Gain: Single; DataSize: Integer);
procedure SilkInsertionSortDecreasingFLP(A: PSingle; Idx: PInteger; L, K: Integer);
procedure SilkLPCAnalysisFilterFLP(RLPC, PredCoef, S: PSingle; Length, Order: Integer);
procedure SilkWarpedAutocorrelationFLP(Corr, Input: PSingle; Warping: Single; Length, Order: Integer);

function  SilkPitchAnalysisCoreFLP(Frame: PSingle; PitchOut: PInteger; var LagIndex: SmallInt;
  var ContourIndex: ShortInt; var LTPCorr: Single; PrevLag: Integer; SearchThres1, SearchThres2: Single;
  FsKHz, Complexity, NbSubfr: Integer): Integer;

implementation

function SilkFloat2Int(X: Single): Integer;
begin
  // lrintf / cvtss2si: round to nearest, ties to even
  Result := Round(X);
end;

procedure SilkFloat2ShortArray(OutP: PSmallInt; InP: PSingle; Length: Integer);
var
  K: Integer;
begin
  for K := Length - 1 downto 0 do
    OutP[K] := SmallInt(SilkSat16(Round(InP[K])));
end;

procedure SilkShort2FloatArray(OutP: PSingle; InP: PSmallInt; Length: Integer);
var
  K: Integer;
begin
  for K := Length - 1 downto 0 do
    OutP[K] := InP[K];
end;

function SilkSigmoid(X: Single): Single;
var
  D: Double;
begin
  D := 1.0 / (1.0 + Exp(-Double(X)));
  Result := D;
end;

function SilkLog2F(X: Double): Single;
var
  D: Double;
begin
  D := 3.32192809488736 * Log10(X);
  Result := D;
end;

function SqrtD(X: Double): Double;
begin
  Result := Sqrt(X);
end;

function PowD(X, Y: Double): Double;
begin
  Result := Power(X, Y);
end;

// ---------------------------------------------------------------------------

function SilkEnergyFLP(Data: PSingle; DataSize: Integer): Double;
var
  I: Integer;
  T: Double;
begin
  Result := 0.0;
  I := 0;
  while I < DataSize - 3 do
  begin
    T := Data[I] * Double(Data[I]) + Data[I + 1] * Double(Data[I + 1]) +
         Data[I + 2] * Double(Data[I + 2]) + Data[I + 3] * Double(Data[I + 3]);
    Result := Result + T;
    Inc(I, 4);
  end;
  while I < DataSize do
  begin
    Result := Result + Data[I] * Double(Data[I]);
    Inc(I);
  end;
end;

function SilkInnerProductFLP(Data1, Data2: PSingle; DataSize: Integer): Double;
var
  I: Integer;
  T: Double;
begin
  Result := 0.0;
  I := 0;
  while I < DataSize - 3 do
  begin
    T := Data1[I] * Double(Data2[I]) + Data1[I + 1] * Double(Data2[I + 1]) +
         Data1[I + 2] * Double(Data2[I + 2]) + Data1[I + 3] * Double(Data2[I + 3]);
    Result := Result + T;
    Inc(I, 4);
  end;
  while I < DataSize do
  begin
    Result := Result + Data1[I] * Double(Data2[I]);
    Inc(I);
  end;
end;

procedure SilkAutocorrelationFLP(Results, InputData: PSingle; InputDataSize, CorrelationCount: Integer);
var
  I: Integer;
begin
  if CorrelationCount > InputDataSize then CorrelationCount := InputDataSize;
  for I := 0 to CorrelationCount - 1 do
    Results[I] := SilkInnerProductFLP(InputData, InputData + I, InputDataSize - I);
end;

procedure SilkApplySineWindowFLP(PxWin, Px: PSingle; WinType, Length: Integer);
const
  HALF: Single = 0.5;
  TWO: Single = 2.0;
var
  K: Integer;
  Freq, C, S0, S1: Single;
begin
  Freq := SILK_PI / (Length + 1);
  C := TWO - Freq * Freq;
  if WinType < 2 then
  begin
    S0 := 0.0;
    S1 := Freq;
  end
  else
  begin
    S0 := 1.0;
    S1 := HALF * C;
  end;
  K := 0;
  while K < Length do
  begin
    PxWin[K] := Px[K] * HALF * (S0 + S1);
    PxWin[K + 1] := Px[K + 1] * S1;
    S0 := C * S1 - S0;
    PxWin[K + 2] := Px[K + 2] * HALF * (S1 + S0);
    PxWin[K + 3] := Px[K + 3] * S0;
    S1 := C * S0 - S1;
    Inc(K, 4);
  end;
end;

function SilkBurgModifiedFLP(A, X: PSingle; MinInvGain: Single; SubfrLength, NbSubfr, D: Integer): Single;
const
  FIND_LPC_COND_FAC: Single = 1e-5;
  EPS9: Single = 1e-9;
  ONE_F: Single = 1.0;
var
  K, N, S, ReachedMaxGain: Integer;
  C0, InvGain, Num, NrgF, NrgB, Rc, Atmp, Tmp1, Tmp2: Double;
  XPtr: PSingle;
  CFirstRow, CLastRow: array[0..MAX_LPC_ORDER - 1] of Double;
  CAf, CAb: array[0..MAX_LPC_ORDER] of Double;
  Af: array[0..MAX_LPC_ORDER - 1] of Double;
  P: Single;
begin
  C0 := SilkEnergyFLP(X, NbSubfr * SubfrLength);
  FillChar(CFirstRow, SizeOf(CFirstRow), 0);
  for S := 0 to NbSubfr - 1 do
  begin
    XPtr := X + S * SubfrLength;
    for N := 1 to D do
      CFirstRow[N - 1] := CFirstRow[N - 1] + SilkInnerProductFLP(XPtr, XPtr + N, SubfrLength - N);
  end;
  CLastRow := CFirstRow;
  CAf[0] := C0 + FIND_LPC_COND_FAC * C0 + EPS9;
  CAb[0] := CAf[0];
  InvGain := ONE_F;
  ReachedMaxGain := 0;
  for N := 0 to D - 1 do
  begin
    for S := 0 to NbSubfr - 1 do
    begin
      XPtr := X + S * SubfrLength;
      Tmp1 := XPtr[N];
      Tmp2 := XPtr[SubfrLength - N - 1];
      for K := 0 to N - 1 do
      begin
        P := XPtr[N] * XPtr[N - K - 1];
        CFirstRow[K] := CFirstRow[K] - P;
        P := XPtr[SubfrLength - N - 1] * XPtr[SubfrLength - N + K];
        CLastRow[K] := CLastRow[K] - P;
        Atmp := Af[K];
        Tmp1 := Tmp1 + XPtr[N - K - 1] * Atmp;
        Tmp2 := Tmp2 + XPtr[SubfrLength - N + K] * Atmp;
      end;
      for K := 0 to N do
      begin
        CAf[K] := CAf[K] - Tmp1 * XPtr[N - K];
        CAb[K] := CAb[K] - Tmp2 * XPtr[SubfrLength - N + K - 1];
      end;
    end;
    Tmp1 := CFirstRow[N];
    Tmp2 := CLastRow[N];
    for K := 0 to N - 1 do
    begin
      Atmp := Af[K];
      Tmp1 := Tmp1 + CLastRow[N - K - 1] * Atmp;
      Tmp2 := Tmp2 + CFirstRow[N - K - 1] * Atmp;
    end;
    CAf[N + 1] := Tmp1;
    CAb[N + 1] := Tmp2;
    Num := CAb[N + 1];
    NrgB := CAb[0];
    NrgF := CAf[0];
    for K := 0 to N - 1 do
    begin
      Atmp := Af[K];
      Num := Num + CAb[N - K] * Atmp;
      NrgB := NrgB + CAb[K + 1] * Atmp;
      NrgF := NrgF + CAf[K + 1] * Atmp;
    end;
    Rc := -2.0 * Num / (NrgF + NrgB);
    Tmp1 := InvGain * (1.0 - Rc * Rc);
    if Tmp1 <= MinInvGain then
    begin
      Rc := SqrtD(1.0 - MinInvGain / InvGain);
      if Num > 0 then Rc := -Rc;
      InvGain := MinInvGain;
      ReachedMaxGain := 1;
    end
    else
      InvGain := Tmp1;
    for K := 0 to ((N + 1) shr 1) - 1 do
    begin
      Tmp1 := Af[K];
      Tmp2 := Af[N - K - 1];
      Af[K] := Tmp1 + Rc * Tmp2;
      Af[N - K - 1] := Tmp2 + Rc * Tmp1;
    end;
    Af[N] := Rc;
    if ReachedMaxGain <> 0 then
    begin
      for K := N + 1 to D - 1 do Af[K] := 0.0;
      Break;
    end;
    for K := 0 to N + 1 do
    begin
      Tmp1 := CAf[K];
      CAf[K] := CAf[K] + Rc * CAb[N - K + 1];
      CAb[N - K + 1] := CAb[N - K + 1] + Rc * Tmp1;
    end;
  end;
  if ReachedMaxGain <> 0 then
  begin
    for K := 0 to D - 1 do
      A[K] := -Af[K];
    for S := 0 to NbSubfr - 1 do
      C0 := C0 - SilkEnergyFLP(X + S * SubfrLength, D);
    NrgF := C0 * InvGain;
  end
  else
  begin
    NrgF := CAf[0];
    Tmp1 := 1.0;
    for K := 0 to D - 1 do
    begin
      Atmp := Af[K];
      NrgF := NrgF + CAf[K + 1] * Atmp;
      Tmp1 := Tmp1 + Atmp * Atmp;
      A[K] := -Atmp;
    end;
    NrgF := NrgF - FIND_LPC_COND_FAC * C0 * Tmp1;
  end;
  Result := NrgF;
end;

procedure SilkBwExpanderFLP(Ar: PSingle; D: Integer; Chirp: Single);
var
  I: Integer;
  Cfac: Single;
begin
  Cfac := Chirp;
  for I := 0 to D - 2 do
  begin
    Ar[I] := Ar[I] * Cfac;
    Cfac := Cfac * Chirp;
  end;
  Ar[D - 1] := Ar[D - 1] * Cfac;
end;

procedure SilkK2aFLP(A, Rc: PSingle; Order: Integer);
var
  K, N: Integer;
  Rck, Tmp1, Tmp2: Single;
begin
  for K := 0 to Order - 1 do
  begin
    Rck := Rc[K];
    for N := 0 to ((K + 1) shr 1) - 1 do
    begin
      Tmp1 := A[N];
      Tmp2 := A[K - N - 1];
      A[N] := Tmp1 + Tmp2 * Rck;
      A[K - N - 1] := Tmp2 + Tmp1 * Rck;
    end;
    A[K] := -Rck;
  end;
end;

function SilkLPCInversePredGainFLP(A: PSingle; Order: Integer): Single;
const
  ONE_F: Single = 1.0;
  MAX_PRED_GAIN: Single = 1e4;
var
  K, N: Integer;
  InvGain, Rc, RcMult1, RcMult2, Tmp1, Tmp2: Double;
  Atmp: array[0..MAX_LPC_ORDER - 1] of Single;
begin
  Move(A^, Atmp[0], Order * SizeOf(Single));
  InvGain := 1.0;
  for K := Order - 1 downto 1 do
  begin
    Rc := -Atmp[K];
    RcMult1 := ONE_F - Rc * Rc;
    InvGain := InvGain * RcMult1;
    if InvGain * MAX_PRED_GAIN < ONE_F then Exit(0.0);
    RcMult2 := ONE_F / RcMult1;
    for N := 0 to ((K + 1) shr 1) - 1 do
    begin
      Tmp1 := Atmp[N];
      Tmp2 := Atmp[K - N - 1];
      Atmp[N] := (Tmp1 - Tmp2 * Rc) * RcMult2;
      Atmp[K - N - 1] := (Tmp2 - Tmp1 * Rc) * RcMult2;
    end;
  end;
  Rc := -Atmp[0];
  RcMult1 := ONE_F - Rc * Rc;
  InvGain := InvGain * RcMult1;
  if InvGain * MAX_PRED_GAIN < ONE_F then Exit(0.0);
  Result := InvGain;
end;

function SilkSchurFLP(ReflCoef, AutoCorr: PSingle; Order: Integer): Single;
const
  EPS9: Single = 1e-9;
var
  K, N: Integer;
  C: array[0..MAX_SHAPE_LPC_ORDER, 0..1] of Double;
  Ctmp1, Ctmp2, RcTmp, Den: Double;
begin
  for K := 0 to Order do
  begin
    C[K, 0] := AutoCorr[K];
    C[K, 1] := AutoCorr[K];
  end;
  for K := 0 to Order - 1 do
  begin
    if C[0, 1] > EPS9 then Den := C[0, 1] else Den := EPS9;
    RcTmp := -C[K + 1, 0] / Den;
    ReflCoef[K] := RcTmp;
    for N := 0 to Order - K - 1 do
    begin
      Ctmp1 := C[N + K + 1, 0];
      Ctmp2 := C[N, 1];
      C[N + K + 1, 0] := Ctmp1 + Ctmp2 * RcTmp;
      C[N, 1] := Ctmp2 + Ctmp1 * RcTmp;
    end;
  end;
  Result := C[0, 1];
end;

procedure SilkScaleVectorFLP(Data1: PSingle; Gain: Single; DataSize: Integer);
var
  I: Integer;
begin
  for I := 0 to DataSize - 1 do
    Data1[I] := Data1[I] * Gain;
end;

procedure SilkScaleCopyVectorFLP(DataOut, DataIn: PSingle; Gain: Single; DataSize: Integer);
var
  I: Integer;
begin
  for I := 0 to DataSize - 1 do
    DataOut[I] := Gain * DataIn[I];
end;

procedure SilkInsertionSortDecreasingFLP(A: PSingle; Idx: PInteger; L, K: Integer);
var
  Value: Single;
  I, J: Integer;
begin
  for I := 0 to K - 1 do Idx[I] := I;
  for I := 1 to K - 1 do
  begin
    Value := A[I];
    J := I - 1;
    while (J >= 0) and (Value > A[J]) do
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
    if Value > A[K - 1] then
    begin
      J := K - 2;
      while (J >= 0) and (Value > A[J]) do
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

procedure SilkLPCAnalysisFilterFLP(RLPC, PredCoef, S: PSingle; Length, Order: Integer);
var
  Ix, J: Integer;
  Pred: Single;
  SP: PSingle;
begin
  for Ix := Order to Length - 1 do
  begin
    SP := S + (Ix - 1);
    Pred := SP[0] * PredCoef[0];
    for J := 1 to Order - 1 do
      Pred := Pred + SP[-J] * PredCoef[J];
    RLPC[Ix] := SP[1] - Pred;
  end;
  FillChar(RLPC^, Order * SizeOf(Single), 0);
end;

procedure SilkWarpedAutocorrelationFLP(Corr, Input: PSingle; Warping: Single; Length, Order: Integer);
var
  N, I: Integer;
  Tmp1, Tmp2: Double;
  State, C: array[0..MAX_SHAPE_LPC_ORDER] of Double;
begin
  FillChar(State, SizeOf(State), 0);
  FillChar(C, SizeOf(C), 0);
  for N := 0 to Length - 1 do
  begin
    Tmp1 := Input[N];
    I := 0;
    while I < Order do
    begin
      Tmp2 := State[I] + Warping * State[I + 1] - Warping * Tmp1;
      State[I] := Tmp1;
      C[I] := C[I] + State[0] * Tmp1;
      Tmp1 := State[I + 1] + Warping * State[I + 2] - Warping * Tmp2;
      State[I + 1] := Tmp2;
      C[I + 1] := C[I + 1] + State[0] * Tmp2;
      Inc(I, 2);
    end;
    State[Order] := Tmp1;
    C[Order] := C[Order] + State[0] * Tmp1;
  end;
  for I := 0 to Order do
    Corr[I] := C[I];
end;

// ---------------------------------------------------------------------------
// Pitch analysis
// ---------------------------------------------------------------------------

const
  SCRATCH_SIZE = 22;
  PE_SHORTLAG_BIAS: Single = 0.2;
  PE_PREVLAG_BIAS: Single = 0.2;
  PE_FLATCONTOUR_BIAS: Single = 0.05;

type
  TSt3Array = array[0..PE_MAX_NB_SUBFR - 1, 0..PE_NB_CBKS_STAGE3_MAX - 1, 0..PE_NB_STAGE3_LAGS - 1] of Single;

procedure GetSt3Tables(NbSubfr, Complexity: Integer; out LagRange, LagCB: PShortInt; out NbCbkSearch, CbkSize: Integer);
begin
  if NbSubfr = PE_MAX_NB_SUBFR then
  begin
    LagRange := @SE_LAG_RANGE_STAGE3[Complexity, 0, 0];
    LagCB := @SE_CB_LAGS_STAGE3[0, 0];
    NbCbkSearch := SE_NB_CBK_SEARCHS_STAGE3[Complexity];
    CbkSize := PE_NB_CBKS_STAGE3_MAX;
  end
  else
  begin
    LagRange := @SE_LAG_RANGE_STAGE3_10_MS[0, 0];
    LagCB := @SE_CB_LAGS_STAGE3_10_MS[0, 0];
    NbCbkSearch := PE_NB_CBKS_STAGE3_10MS;
    CbkSize := PE_NB_CBKS_STAGE3_10MS;
  end;
end;

procedure PAnaCalcCorrSt3(var CrossCorrSt3: TSt3Array; Frame: PSingle; StartLag, SfLength, NbSubfr, Complexity: Integer);
var
  TargetPtr: PSingle;
  I, J, K, LagCounter, LagLow, LagHigh, NbCbkSearch, Delta, Idx, CbkSize: Integer;
  ScratchMem, Xcorr: array[0..SCRATCH_SIZE - 1] of Single;
  LagRange, LagCB: PShortInt;
begin
  GetSt3Tables(NbSubfr, Complexity, LagRange, LagCB, NbCbkSearch, CbkSize);
  TargetPtr := Frame + (SfLength shl 2);
  for K := 0 to NbSubfr - 1 do
  begin
    LagCounter := 0;
    LagLow := LagRange[K * 2 + 0];
    LagHigh := LagRange[K * 2 + 1];
    CeltPitchXcorr(TargetPtr, TargetPtr - StartLag - LagHigh, @Xcorr[0], SfLength, LagHigh - LagLow + 1);
    for J := LagLow to LagHigh do
    begin
      ScratchMem[LagCounter] := Xcorr[LagHigh - J];
      Inc(LagCounter);
    end;
    Delta := LagRange[K * 2 + 0];
    for I := 0 to NbCbkSearch - 1 do
    begin
      Idx := LagCB[K * CbkSize + I] - Delta;
      for J := 0 to PE_NB_STAGE3_LAGS - 1 do
        CrossCorrSt3[K, I, J] := ScratchMem[Idx + J];
    end;
    Inc(TargetPtr, SfLength);
  end;
end;

procedure PAnaCalcEnergySt3(var EnergiesSt3: TSt3Array; Frame: PSingle; StartLag, SfLength, NbSubfr, Complexity: Integer);
var
  TargetPtr, BasisPtr: PSingle;
  Energy: Double;
  K, I, J, LagCounter, NbCbkSearch, Delta, Idx, CbkSize, LagDiff: Integer;
  ScratchMem: array[0..SCRATCH_SIZE - 1] of Single;
  LagRange, LagCB: PShortInt;
begin
  GetSt3Tables(NbSubfr, Complexity, LagRange, LagCB, NbCbkSearch, CbkSize);
  TargetPtr := Frame + (SfLength shl 2);
  for K := 0 to NbSubfr - 1 do
  begin
    LagCounter := 0;
    BasisPtr := TargetPtr - (StartLag + LagRange[K * 2 + 0]);
    Energy := SilkEnergyFLP(BasisPtr, SfLength) + 1e-3;
    ScratchMem[LagCounter] := Energy;
    Inc(LagCounter);
    LagDiff := LagRange[K * 2 + 1] - LagRange[K * 2 + 0] + 1;
    for I := 1 to LagDiff - 1 do
    begin
      Energy := Energy - BasisPtr[SfLength - I] * Double(BasisPtr[SfLength - I]);
      Energy := Energy + BasisPtr[-I] * Double(BasisPtr[-I]);
      ScratchMem[LagCounter] := Energy;
      Inc(LagCounter);
    end;
    Delta := LagRange[K * 2 + 0];
    for I := 0 to NbCbkSearch - 1 do
    begin
      Idx := LagCB[K * CbkSize + I] - Delta;
      for J := 0 to PE_NB_STAGE3_LAGS - 1 do
        EnergiesSt3[K, I, J] := ScratchMem[Idx + J];
    end;
    Inc(TargetPtr, SfLength);
  end;
end;

function SilkPitchAnalysisCoreFLP(Frame: PSingle; PitchOut: PInteger; var LagIndex: SmallInt;
  var ContourIndex: ShortInt; var LTPCorr: Single; PrevLag: Integer; SearchThres1, SearchThres2: Single;
  FsKHz, Complexity, NbSubfr: Integer): Integer;
const
  F4000: Single = 4000.0;
  F4096: Single = 4096.0;
  F02: Single = 0.2;
  F05: Single = 0.5;
  ONE_F: Single = 1.0;
var
  I, K, D, J: Integer;
  Frame8kHz: array[0..PE_MAX_FRAME_LENGTH_MS * 8 - 1] of Single;
  Frame4kHz: array[0..PE_MAX_FRAME_LENGTH_MS * 4 - 1] of Single;
  Frame8FIX: array[0..PE_MAX_FRAME_LENGTH_MS * 8 - 1] of SmallInt;
  Frame4FIX: array[0..PE_MAX_FRAME_LENGTH_MS * 4 - 1] of SmallInt;
  FrameFIX: array[0..16 * PE_MAX_FRAME_LENGTH_MS - 1] of SmallInt;
  FiltState: array[0..5] of Integer;
  Threshold, ContourBias: Single;
  C: array[0..PE_MAX_NB_SUBFR - 1, 0..(PE_MAX_LAG shr 1) + 4] of Single;
  Xcorr: array[0..PE_MAX_LAG_MS * 4 - PE_MIN_LAG_MS * 4] of Single;
  CC: array[0..PE_NB_CBKS_STAGE2_EXT - 1] of Single;
  TargetPtr, BasisPtr: PSingle;
  CrossCorr, Normalizer, Energy, EnergyTmp: Double;
  DSrch: array[0..PE_D_SRCH_LENGTH - 1] of Integer;
  DComp: array[0..(PE_MAX_LAG shr 1) + 4] of SmallInt;
  LengthDSrch, LengthDComp: Integer;
  Cmax, CCmax, CCmaxB, CCmaxNewB, CCmaxNew, T: Single;
  CBimax, CBimaxNew, Lag, StartLag, EndLag, LagNew, CbkSize: Integer;
  LagLog2, PrevLagLog2, DeltaLagLog2Sqr: Single;
  EnergiesSt3, CrossCorrSt3: TSt3Array;
  LagCounter: Integer;
  FrameLength, FrameLength8kHz, FrameLength4kHz: Integer;
  SfLength, SfLength8kHz, SfLength4kHz: Integer;
  MinLag, MinLag8kHz, MinLag4kHz, MaxLag, MaxLag8kHz, MaxLag4kHz: Integer;
  NbCbkSearch: Integer;
  LagCBPtr: PShortInt;
begin
  FrameLength := (PE_LTP_MEM_LENGTH_MS + NbSubfr * PE_SUBFR_LENGTH_MS) * FsKHz;
  FrameLength4kHz := (PE_LTP_MEM_LENGTH_MS + NbSubfr * PE_SUBFR_LENGTH_MS) * 4;
  FrameLength8kHz := (PE_LTP_MEM_LENGTH_MS + NbSubfr * PE_SUBFR_LENGTH_MS) * 8;
  SfLength := PE_SUBFR_LENGTH_MS * FsKHz;
  SfLength4kHz := PE_SUBFR_LENGTH_MS * 4;
  SfLength8kHz := PE_SUBFR_LENGTH_MS * 8;
  MinLag := PE_MIN_LAG_MS * FsKHz;
  MinLag4kHz := PE_MIN_LAG_MS * 4;
  MinLag8kHz := PE_MIN_LAG_MS * 8;
  MaxLag := PE_MAX_LAG_MS * FsKHz - 1;
  MaxLag4kHz := PE_MAX_LAG_MS * 4;
  MaxLag8kHz := PE_MAX_LAG_MS * 8 - 1;

  if FsKHz = 16 then
  begin
    SilkFloat2ShortArray(@FrameFIX[0], Frame, FrameLength);
    FillChar(FiltState, 2 * SizeOf(Integer), 0);
    SilkResamplerDown2(@FiltState[0], @Frame8FIX[0], @FrameFIX[0], FrameLength);
    SilkShort2FloatArray(@Frame8kHz[0], @Frame8FIX[0], FrameLength8kHz);
  end
  else if FsKHz = 12 then
  begin
    SilkFloat2ShortArray(@FrameFIX[0], Frame, FrameLength);
    FillChar(FiltState, 6 * SizeOf(Integer), 0);
    SilkResamplerDown2_3(@FiltState[0], @Frame8FIX[0], @FrameFIX[0], FrameLength);
    SilkShort2FloatArray(@Frame8kHz[0], @Frame8FIX[0], FrameLength8kHz);
  end
  else
    SilkFloat2ShortArray(@Frame8FIX[0], Frame, FrameLength8kHz);

  FillChar(FiltState, 2 * SizeOf(Integer), 0);
  SilkResamplerDown2(@FiltState[0], @Frame4FIX[0], @Frame8FIX[0], FrameLength8kHz);
  SilkShort2FloatArray(@Frame4kHz[0], @Frame4FIX[0], FrameLength4kHz);

  for I := FrameLength4kHz - 1 downto 1 do
    Frame4kHz[I] := SilkSat16(Trunc(Frame4kHz[I]) + Trunc(Frame4kHz[I - 1]));

  // First stage, 4 kHz
  FillChar(C, SizeOf(Single) * NbSubfr * ((PE_MAX_LAG shr 1) + 5), 0);
  TargetPtr := @Frame4kHz[SfLength4kHz shl 2];
  for K := 0 to (NbSubfr shr 1) - 1 do
  begin
    BasisPtr := TargetPtr - MinLag4kHz;
    CeltPitchXcorr(TargetPtr, TargetPtr - MaxLag4kHz, @Xcorr[0], SfLength8kHz, MaxLag4kHz - MinLag4kHz + 1);
    CrossCorr := Xcorr[MaxLag4kHz - MinLag4kHz];
    T := SfLength8kHz * F4000;
    Normalizer := SilkEnergyFLP(TargetPtr, SfLength8kHz) + SilkEnergyFLP(BasisPtr, SfLength8kHz) + T;
    C[0, MinLag4kHz] := C[0, MinLag4kHz] + Single(2 * CrossCorr / Normalizer);
    for D := MinLag4kHz + 1 to MaxLag4kHz do
    begin
      Dec(BasisPtr);
      CrossCorr := Xcorr[MaxLag4kHz - D];
      Normalizer := Normalizer + (BasisPtr[0] * Double(BasisPtr[0]) -
        BasisPtr[SfLength8kHz] * Double(BasisPtr[SfLength8kHz]));
      C[0, D] := C[0, D] + Single(2 * CrossCorr / Normalizer);
    end;
    Inc(TargetPtr, SfLength8kHz);
  end;

  for I := MaxLag4kHz downto MinLag4kHz do
  begin
    T := C[0, I] * I / F4096;
    C[0, I] := C[0, I] - T;
  end;

  LengthDSrch := 4 + 2 * Complexity;
  SilkInsertionSortDecreasingFLP(@C[0, MinLag4kHz], @DSrch[0], MaxLag4kHz - MinLag4kHz + 1, LengthDSrch);

  Cmax := C[0, MinLag4kHz];
  if Cmax < F02 then
  begin
    FillChar(PitchOut^, NbSubfr * SizeOf(Integer), 0);
    LTPCorr := 0.0;
    LagIndex := 0;
    ContourIndex := 0;
    Exit(1);
  end;

  Threshold := SearchThres1 * Cmax;
  for I := 0 to LengthDSrch - 1 do
  begin
    if C[0, MinLag4kHz + I] > Threshold then
      DSrch[I] := (DSrch[I] + MinLag4kHz) shl 1
    else
    begin
      LengthDSrch := I;
      Break;
    end;
  end;

  for I := MinLag8kHz - 5 to MaxLag8kHz + 4 do
    DComp[I] := 0;
  for I := 0 to LengthDSrch - 1 do
    DComp[DSrch[I]] := 1;
  for I := MaxLag8kHz + 3 downto MinLag8kHz do
    DComp[I] := SmallInt(DComp[I] + DComp[I - 1] + DComp[I - 2]);
  LengthDSrch := 0;
  for I := MinLag8kHz to MaxLag8kHz do
    if DComp[I + 1] > 0 then
    begin
      DSrch[LengthDSrch] := I;
      Inc(LengthDSrch);
    end;
  for I := MaxLag8kHz + 3 downto MinLag8kHz do
    DComp[I] := SmallInt(DComp[I] + DComp[I - 1] + DComp[I - 2] + DComp[I - 3]);
  LengthDComp := 0;
  for I := MinLag8kHz to MaxLag8kHz + 3 do
    if DComp[I] > 0 then
    begin
      DComp[LengthDComp] := SmallInt(I - 2);
      Inc(LengthDComp);
    end;

  // Second stage, 8 kHz
  FillChar(C, SizeOf(C), 0);
  if FsKHz = 8 then
    TargetPtr := Frame + PE_LTP_MEM_LENGTH_MS * 8
  else
    TargetPtr := @Frame8kHz[PE_LTP_MEM_LENGTH_MS * 8];
  for K := 0 to NbSubfr - 1 do
  begin
    EnergyTmp := SilkEnergyFLP(TargetPtr, SfLength8kHz) + 1.0;
    for J := 0 to LengthDComp - 1 do
    begin
      D := DComp[J];
      BasisPtr := TargetPtr - D;
      CrossCorr := SilkInnerProductFLP(BasisPtr, TargetPtr, SfLength8kHz);
      if CrossCorr > 0.0 then
      begin
        Energy := SilkEnergyFLP(BasisPtr, SfLength8kHz);
        C[K, D] := 2 * CrossCorr / (Energy + EnergyTmp);
      end
      else
        C[K, D] := 0.0;
    end;
    Inc(TargetPtr, SfLength8kHz);
  end;

  CCmax := 0.0;
  CCmaxB := -1000.0;
  CBimax := 0;
  Lag := -1;
  if PrevLag > 0 then
  begin
    if FsKHz = 12 then
      PrevLag := (PrevLag shl 1) div 3
    else if FsKHz = 16 then
      PrevLag := PrevLag shr 1;
    PrevLagLog2 := SilkLog2F(Single(PrevLag));
  end
  else
    PrevLagLog2 := 0;

  if NbSubfr = PE_MAX_NB_SUBFR then
  begin
    CbkSize := PE_NB_CBKS_STAGE2_EXT;
    LagCBPtr := @SE_CB_LAGS_STAGE2[0, 0];
    if (FsKHz = 8) and (Complexity > SILK_PE_MIN_COMPLEX) then
      NbCbkSearch := PE_NB_CBKS_STAGE2_EXT
    else
      NbCbkSearch := PE_NB_CBKS_STAGE2;
  end
  else
  begin
    CbkSize := PE_NB_CBKS_STAGE2_10MS;
    LagCBPtr := @SE_CB_LAGS_STAGE2_10_MS[0, 0];
    NbCbkSearch := PE_NB_CBKS_STAGE2_10MS;
  end;

  for K := 0 to LengthDSrch - 1 do
  begin
    D := DSrch[K];
    for J := 0 to NbCbkSearch - 1 do
    begin
      CC[J] := 0.0;
      for I := 0 to NbSubfr - 1 do
        CC[J] := CC[J] + C[I, D + LagCBPtr[I * CbkSize + J]];
    end;
    CCmaxNew := -1000.0;
    CBimaxNew := 0;
    for I := 0 to NbCbkSearch - 1 do
      if CC[I] > CCmaxNew then
      begin
        CCmaxNew := CC[I];
        CBimaxNew := I;
      end;
    LagLog2 := SilkLog2F(Single(D));
    T := PE_SHORTLAG_BIAS * NbSubfr;
    CCmaxNewB := CCmaxNew - T * LagLog2;
    if PrevLag > 0 then
    begin
      DeltaLagLog2Sqr := LagLog2 - PrevLagLog2;
      DeltaLagLog2Sqr := DeltaLagLog2Sqr * DeltaLagLog2Sqr;
      T := PE_PREVLAG_BIAS * NbSubfr;
      T := T * LTPCorr;
      T := T * DeltaLagLog2Sqr;
      T := T / (DeltaLagLog2Sqr + F05);
      CCmaxNewB := CCmaxNewB - T;
    end;
    T := NbSubfr * SearchThres2;
    if (CCmaxNewB > CCmaxB) and (CCmaxNew > T) then
    begin
      CCmaxB := CCmaxNewB;
      CCmax := CCmaxNew;
      Lag := D;
      CBimax := CBimaxNew;
    end;
  end;

  if Lag = -1 then
  begin
    FillChar(PitchOut^, PE_MAX_NB_SUBFR * SizeOf(Integer), 0);
    LTPCorr := 0.0;
    LagIndex := 0;
    ContourIndex := 0;
    Exit(1);
  end;

  LTPCorr := CCmax / NbSubfr;

  if FsKHz > 8 then
  begin
    if FsKHz = 12 then
      Lag := SilkRShiftRound(SilkSMULBB(Lag, 3), 1)
    else
      Lag := Lag shl 1;
    Lag := SilkLimit(Lag, MinLag, MaxLag);
    if Lag - 2 > MinLag then StartLag := Lag - 2 else StartLag := MinLag;
    if Lag + 2 < MaxLag then EndLag := Lag + 2 else EndLag := MaxLag;
    LagNew := Lag;
    CBimax := 0;
    CCmax := -1000.0;
    PAnaCalcCorrSt3(CrossCorrSt3, Frame, StartLag, SfLength, NbSubfr, Complexity);
    PAnaCalcEnergySt3(EnergiesSt3, Frame, StartLag, SfLength, NbSubfr, Complexity);
    LagCounter := 0;
    ContourBias := PE_FLATCONTOUR_BIAS / Lag;
    if NbSubfr = PE_MAX_NB_SUBFR then
    begin
      NbCbkSearch := SE_NB_CBK_SEARCHS_STAGE3[Complexity];
      CbkSize := PE_NB_CBKS_STAGE3_MAX;
      LagCBPtr := @SE_CB_LAGS_STAGE3[0, 0];
    end
    else
    begin
      NbCbkSearch := PE_NB_CBKS_STAGE3_10MS;
      CbkSize := PE_NB_CBKS_STAGE3_10MS;
      LagCBPtr := @SE_CB_LAGS_STAGE3_10_MS[0, 0];
    end;
    TargetPtr := Frame + PE_LTP_MEM_LENGTH_MS * FsKHz;
    EnergyTmp := SilkEnergyFLP(TargetPtr, NbSubfr * SfLength) + 1.0;
    for D := StartLag to EndLag do
    begin
      for J := 0 to NbCbkSearch - 1 do
      begin
        CrossCorr := 0.0;
        Energy := EnergyTmp;
        for K := 0 to NbSubfr - 1 do
        begin
          CrossCorr := CrossCorr + CrossCorrSt3[K, J, LagCounter];
          Energy := Energy + EnergiesSt3[K, J, LagCounter];
        end;
        if CrossCorr > 0.0 then
        begin
          CCmaxNew := 2 * CrossCorr / Energy;
          T := ContourBias * J;
          CCmaxNew := CCmaxNew * (ONE_F - T);
        end
        else
          CCmaxNew := 0.0;
        if (CCmaxNew > CCmax) and (D + SE_CB_LAGS_STAGE3[0, J] <= MaxLag) then
        begin
          CCmax := CCmaxNew;
          LagNew := D;
          CBimax := J;
        end;
      end;
      Inc(LagCounter);
    end;
    for K := 0 to NbSubfr - 1 do
    begin
      PitchOut[K] := LagNew + LagCBPtr[K * CbkSize + CBimax];
      PitchOut[K] := SilkLimit(PitchOut[K], MinLag, PE_MAX_LAG_MS * FsKHz);
    end;
    LagIndex := SmallInt(LagNew - MinLag);
    ContourIndex := ShortInt(CBimax);
  end
  else
  begin
    for K := 0 to NbSubfr - 1 do
    begin
      PitchOut[K] := Lag + LagCBPtr[K * CbkSize + CBimax];
      PitchOut[K] := SilkLimit(PitchOut[K], MinLag8kHz, PE_MAX_LAG_MS * 8);
    end;
    LagIndex := SmallInt(Lag - MinLag8kHz);
    ContourIndex := ShortInt(CBimax);
  end;
  Result := 0;
end;

end.
