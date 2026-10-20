unit OpusCeltEncBands;

{
  OpusCeltEncBands.pas - CELT band analysis and quantisation (encoder side)

  Port of the encoder paths of libopus 1.5.2 celt/bands.c
  (compute_band_energies, normalise_bands, spreading_decision,
  hysteresis_decision, quant_all_bands and helpers), celt/quant_bands.c
  (amp2Log2, quant_coarse_energy, quant_fine_energy, quant_energy_finalise)
  and celt/rate.c (clt_compute_allocation with encode=1). Float build.

  Copyright (c) 2007-2011 Xiph.Org Foundation, Jean-Marc Valin,
  Timothy B. Terriberry, Gregory Maxwell.
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
  OpusCeltEncMath;

const
  MAX_FINE_BITS = 8;

function  HysteresisDecision(Val: Single; Thresholds, Hysteresis: PSingle; N, Prev: Integer): Integer;
procedure ComputeBandEnergies(Freq: PSingle; BandE: PSingle; EndB, C, LM: Integer);
procedure NormaliseBands(Freq: PSingle; X: PSingle; BandE: PSingle; EndB, C, M: Integer);
procedure Amp2Log2(EffEnd, EndB: Integer; BandE, BandLogE: PSingle; C: Integer);
function  SpreadingDecision(X: PSingle; var Average: Integer; LastDecision: Integer;
  var HfAverage, TapsetDecision: Integer; UpdateHf: Boolean; EndB, C, M: Integer;
  SpreadWeight: PInteger): Integer;

procedure QuantCoarseEnergy(StartB, EndB, EffEnd: Integer; EBands, OldEBands: PSingle;
  Budget: Cardinal; Error: PSingle; var Enc: TEcEnc; C, LM, NbAvailableBytes: Integer;
  ForceIntra: Boolean; var DelayedIntra: Single; TwoPass: Boolean; LossRate: Integer;
  Lfe: Boolean);
procedure QuantFineEnergy(StartB, EndB: Integer; OldEBands, Error: PSingle;
  const FineQuant: TIntArray; var Enc: TEcEnc; C: Integer);
procedure QuantEnergyFinalise(StartB, EndB: Integer; OldEBands, Error: PSingle;
  const FineQuant, FinePriority: TIntArray; BitsLeft: Integer; var Enc: TEcEnc; C: Integer);

function CltComputeAllocationEnc(StartB, EndB: Integer; const Offsets, Cap: TIntArray;
  AllocTrim: Integer; var Intensity, DualStereo: Integer; Total: Integer;
  out Balance: Integer; var Pulses, EBits, FinePriority: TIntArray;
  C, LM: Integer; var Enc: TEcEnc; Prev, SignalBandwidth: Integer): Integer;

procedure QuantAllBandsEnc(StartB, EndB: Integer; X_, Y_: PSingle;
  CollapseMasks: PByte; BandE: PSingle; const Pulses: TIntArray;
  ShortBlocks, Spread, DualStereo, Intensity: Integer; const TfRes: TIntArray;
  TotalBits, Balance: Integer; var Enc: TEcEnc; LM, CodedBands: Integer;
  var Seed: Cardinal; Complexity: Integer; DisableInv: Boolean);

implementation

const
  FINE_OFFSET            = 21;
  QTHETA_OFFSET          = 4;
  QTHETA_OFFSET_TWOPHASE = 16;
  ALLOC_STEPS            = 6;
  NORM_SCALING: Single   = 1.0;
  F_1E27: Single         = 1e-27;
  F_R2: Single           = 0.70710678;

  LOG2_FRAC_TABLE: array[0..23] of Byte = (
    0,
    8, 13,
    16, 19, 21, 23,
    24, 26, 27, 28, 29, 30, 31, 32,
    32, 33, 34, 34, 35, 36, 36, 37, 37);

  PRED_COEF: array[0..3] of Single = (29440/32768, 26112/32768, 21248/32768, 16384/32768);
  BETA_COEF: array[0..3] of Single = (30147/32768, 22282/32768, 12124/32768, 6554/32768);
  BETA_INTRA: Single = 4915/32768;
  SMALL_ENERGY_ICDF: array[0..2] of Byte = (2, 1, 0);

// Arithmetic shift right (C >> on a signed int)
function Sar(X, S: Integer): Integer; inline;
begin
  if X >= 0 then Result := X shr S
  else Result := not ((not X) shr S);
end;

function HysteresisDecision(Val: Single; Thresholds, Hysteresis: PSingle; N, Prev: Integer): Integer;
var
  I: Integer;
begin
  I := 0;
  while I < N do
  begin
    if Val < Thresholds[I] then Break;
    Inc(I);
  end;
  if (I > Prev) and (Val < Thresholds[Prev] + Hysteresis[Prev]) then
    I := Prev;
  if (I < Prev) and (Val > Thresholds[Prev - 1] - Hysteresis[Prev - 1]) then
    I := Prev;
  Result := I;
end;

procedure ComputeBandEnergies(Freq: PSingle; BandE: PSingle; EndB, C, LM: Integer);
var
  I, Ch, N: Integer;
  Sum: Single;
begin
  N := CELT_SHORT_MDCT shl LM;
  for Ch := 0 to C - 1 do
    for I := 0 to EndB - 1 do
    begin
      Sum := F_1E27 + CeltInnerProd(Freq + Ch * N + (CELT_EBANDS[I] shl LM),
        Freq + Ch * N + (CELT_EBANDS[I] shl LM), (CELT_EBANDS[I + 1] - CELT_EBANDS[I]) shl LM);
      BandE[I + Ch * CELT_NB_EBANDS] := SqrtF(Sum);
    end;
end;

procedure NormaliseBands(Freq: PSingle; X: PSingle; BandE: PSingle; EndB, C, M: Integer);
var
  I, J, Ch, N: Integer;
  G: Single;
begin
  N := M * CELT_SHORT_MDCT;
  for Ch := 0 to C - 1 do
    for I := 0 to EndB - 1 do
    begin
      G := F_ONE / (F_1E27 + BandE[I + Ch * CELT_NB_EBANDS]);
      for J := M * CELT_EBANDS[I] to M * CELT_EBANDS[I + 1] - 1 do
        X[J + Ch * N] := Freq[J + Ch * N] * G;
    end;
end;

procedure Amp2Log2(EffEnd, EndB: Integer; BandE, BandLogE: PSingle; C: Integer);
var
  I, Ch: Integer;
begin
  for Ch := 0 to C - 1 do
  begin
    for I := 0 to EffEnd - 1 do
      BandLogE[I + Ch * CELT_NB_EBANDS] := CeltLog2(BandE[I + Ch * CELT_NB_EBANDS]) - CELT_EMEANS[I];
    for I := EffEnd to EndB - 1 do
      BandLogE[Ch * CELT_NB_EBANDS + I] := -14.0;
  end;
end;

function SpreadingDecision(X: PSingle; var Average: Integer; LastDecision: Integer;
  var HfAverage, TapsetDecision: Integer; UpdateHf: Boolean; EndB, C, M: Integer;
  SpreadWeight: PInteger): Integer;
const
  T0: Single = 0.25;
  T1: Single = 0.0625;
  T2: Single = 0.015625;
var
  I, J, Ch, N0, N, Tmp, Sum, NbBands, HfSum: Integer;
  TCount: array[0..2] of Integer;
  Xp: PSingle;
  X2N: Single;
begin
  Sum := 0;
  NbBands := 0;
  HfSum := 0;
  N0 := M * CELT_SHORT_MDCT;
  if M * (CELT_EBANDS[EndB] - CELT_EBANDS[EndB - 1]) <= 8 then
    Exit(CELT_SPREAD_NONE);
  for Ch := 0 to C - 1 do
    for I := 0 to EndB - 1 do
    begin
      TCount[0] := 0; TCount[1] := 0; TCount[2] := 0;
      Xp := X + M * CELT_EBANDS[I] + Ch * N0;
      N := M * (CELT_EBANDS[I + 1] - CELT_EBANDS[I]);
      if N <= 8 then Continue;
      for J := 0 to N - 1 do
      begin
        X2N := (Xp[J] * Xp[J]) * N;
        if X2N < T0 then Inc(TCount[0]);
        if X2N < T1 then Inc(TCount[1]);
        if X2N < T2 then Inc(TCount[2]);
      end;
      if I > CELT_NB_EBANDS - 4 then
        HfSum := HfSum + Integer(Cardinal(32 * (TCount[1] + TCount[0])) div Cardinal(N));
      Tmp := Ord(2 * TCount[2] >= N) + Ord(2 * TCount[1] >= N) + Ord(2 * TCount[0] >= N);
      Sum := Sum + Tmp * SpreadWeight[I];
      NbBands := NbBands + SpreadWeight[I];
    end;
  if UpdateHf then
  begin
    if HfSum <> 0 then
      HfSum := Integer(Cardinal(HfSum) div Cardinal(C * (4 - CELT_NB_EBANDS + EndB)));
    HfAverage := (HfAverage + HfSum) shr 1;
    HfSum := HfAverage;
    if TapsetDecision = 2 then Inc(HfSum, 4)
    else if TapsetDecision = 0 then Dec(HfSum, 4);
    if HfSum > 22 then TapsetDecision := 2
    else if HfSum > 18 then TapsetDecision := 1
    else TapsetDecision := 0;
  end;
  Sum := Integer(Cardinal(Sum shl 8) div Cardinal(NbBands));
  Sum := (Sum + Average) shr 1;
  Average := Sum;
  Sum := (3 * Sum + (((3 - LastDecision) shl 7) + 64) + 2) shr 2;
  if Sum < 80 then Result := CELT_SPREAD_AGGRESSIVE
  else if Sum < 256 then Result := CELT_SPREAD_NORMAL
  else if Sum < 384 then Result := CELT_SPREAD_LIGHT
  else Result := CELT_SPREAD_NONE;
end;

// ---------------------------------------------------------------------------
// quant_bands.c (encoder)
// ---------------------------------------------------------------------------

function LossDistortion(EBands, OldEBands: PSingle; StartB, EndB, Len, C: Integer): Single;
var
  Ch, I: Integer;
  D: Single;
begin
  Result := 0;
  for Ch := 0 to C - 1 do
    for I := StartB to EndB - 1 do
    begin
      D := EBands[I + Ch * Len] - OldEBands[I + Ch * Len];
      Result := Result + D * D;
    end;
  if 200 < Result then Result := 200;
end;

function QuantCoarseEnergyImpl(StartB, EndB: Integer; EBands, OldEBands: PSingle;
  Budget, Tell: Integer; ProbModel: PByte; Error: PSingle; var Enc: TEcEnc;
  C, LM, Intra: Integer; MaxDecay: Single; Lfe: Boolean): Integer;
const
  M9 : Single = -9.0;
  M28: Single = -28.0;
var
  I, Ch, BitsLeft, Qi, Qi0, Pi, Badness: Integer;
  Prev: array[0..1] of Single;
  Coef, Beta, X, F, Tmp, OldE, DecayBound, Q: Single;
begin
  Badness := 0;
  Prev[0] := 0; Prev[1] := 0;
  if Tell + 3 <= Budget then
    EcEncBitLogp(Enc, Intra, 3);
  if Intra <> 0 then
  begin
    Coef := 0;
    Beta := BETA_INTRA;
  end
  else
  begin
    Beta := BETA_COEF[LM];
    Coef := PRED_COEF[LM];
  end;
  for I := StartB to EndB - 1 do
    for Ch := 0 to C - 1 do
    begin
      X := EBands[I + Ch * CELT_NB_EBANDS];
      OldE := OldEBands[I + Ch * CELT_NB_EBANDS];
      if M9 > OldE then OldE := M9;
      F := X - Coef * OldE - Prev[Ch];
      Qi := Floor(F_HALF + F);
      DecayBound := OldEBands[I + Ch * CELT_NB_EBANDS];
      if M28 > DecayBound then DecayBound := M28;
      DecayBound := DecayBound - MaxDecay;
      if (Qi < 0) and (X < DecayBound) then
      begin
        Qi := Qi + Trunc(DecayBound - X);
        if Qi > 0 then Qi := 0;
      end;
      Qi0 := Qi;
      Tell := EcTell(Enc);
      BitsLeft := Budget - Tell - 3 * C * (EndB - I);
      if (I <> StartB) and (BitsLeft < 30) then
      begin
        if BitsLeft < 24 then Qi := Min(1, Qi);
        if BitsLeft < 16 then Qi := Max(-1, Qi);
      end;
      if Lfe and (I >= 2) then
        Qi := Min(Qi, 0);
      if Budget - Tell >= 15 then
      begin
        Pi := 2 * Min(I, 20);
        EcLaplaceEncode(Enc, Qi, Cardinal(ProbModel[Pi]) shl 7, Integer(ProbModel[Pi + 1]) shl 6);
      end
      else if Budget - Tell >= 2 then
      begin
        Qi := Max(-1, Min(Qi, 1));
        EcEncIcdf(Enc, (2 * Qi) xor -Ord(Qi < 0), @SMALL_ENERGY_ICDF[0], 2);
      end
      else if Budget - Tell >= 1 then
      begin
        Qi := Min(0, Qi);
        EcEncBitLogp(Enc, -Qi, 1);
      end
      else
        Qi := -1;
      Error[I + Ch * CELT_NB_EBANDS] := F - Qi;
      Badness := Badness + Abs(Qi0 - Qi);
      Q := Qi;
      Tmp := Coef * OldE + Prev[Ch] + Q;
      OldEBands[I + Ch * CELT_NB_EBANDS] := Tmp;
      Prev[Ch] := Prev[Ch] + Q - Beta * Q;
    end;
  if Lfe then Result := 0 else Result := Badness;
end;

procedure QuantCoarseEnergy(StartB, EndB, EffEnd: Integer; EBands, OldEBands: PSingle;
  Budget: Cardinal; Error: PSingle; var Enc: TEcEnc; C, LM, NbAvailableBytes: Integer;
  ForceIntra: Boolean; var DelayedIntra: Single; TwoPass: Boolean; LossRate: Integer;
  Lfe: Boolean);
const
  F16 : Single = 16.0;
  F3  : Single = 3.0;
  F125: Single = 0.125;
var
  Intra, Badness1, Badness2: Integer;
  MaxDecay, NewDistortion, Tmp: Single;
  OldEBandsIntra, ErrorIntra: array[0..2 * CELT_NB_EBANDS - 1] of Single;
  EncStartState, EncIntraState: TEcEnc;
  Tell, TellIntra: Integer;
  IntraBias: Integer;
  NStartBytes, NIntraBytes, SaveBytes: Cardinal;
  IntraBuf: PByte;
  IntraBits: TBytes;
begin
  Badness1 := 0;
  Intra := Ord(ForceIntra or ((not TwoPass) and (DelayedIntra > 2 * C * (EndB - StartB)) and
    (NbAvailableBytes > (EndB - StartB) * C)));
  Tmp := Budget * DelayedIntra;
  Tmp := Tmp * LossRate;
  Tmp := Tmp / (C * 512);
  IntraBias := Trunc(Tmp);
  NewDistortion := LossDistortion(EBands, OldEBands, StartB, EffEnd, CELT_NB_EBANDS, C);

  Tell := EcTell(Enc);
  if Cardinal(Tell + 3) > Budget then
  begin
    TwoPass := False;
    Intra := 0;
  end;

  MaxDecay := F16;
  if EndB - StartB > 10 then
  begin
    Tmp := F125 * NbAvailableBytes;
    if Tmp < MaxDecay then MaxDecay := Tmp;
  end;
  if Lfe then
    MaxDecay := F3;
  EncStartState := Enc;

  Move(OldEBands^, OldEBandsIntra[0], C * CELT_NB_EBANDS * SizeOf(Single));

  if TwoPass or (Intra <> 0) then
    Badness1 := QuantCoarseEnergyImpl(StartB, EndB, EBands, @OldEBandsIntra[0], Budget,
      Tell, @CELT_E_PROB_MODEL[(LM * 2 + 1) * 42], @ErrorIntra[0], Enc, C, LM, 1, MaxDecay, Lfe);

  if Intra = 0 then
  begin
    TellIntra := EcTellFrac(Enc);
    EncIntraState := Enc;
    NStartBytes := EcRangeBytes(EncStartState);
    NIntraBytes := EcRangeBytes(EncIntraState);
    IntraBuf := EncIntraState.Buf + NStartBytes;
    SaveBytes := NIntraBytes - NStartBytes;
    SetLength(IntraBits, SaveBytes);
    if SaveBytes > 0 then
      Move(IntraBuf^, IntraBits[0], SaveBytes);

    Enc := EncStartState;
    Badness2 := QuantCoarseEnergyImpl(StartB, EndB, EBands, OldEBands, Budget,
      Tell, @CELT_E_PROB_MODEL[(LM * 2 + Intra) * 42], Error, Enc, C, LM, 0, MaxDecay, Lfe);

    if TwoPass and ((Badness1 < Badness2) or
       ((Badness1 = Badness2) and (Integer(EcTellFrac(Enc)) + IntraBias > TellIntra))) then
    begin
      Enc := EncIntraState;
      if SaveBytes > 0 then
        Move(IntraBits[0], IntraBuf^, SaveBytes);
      Move(OldEBandsIntra[0], OldEBands^, C * CELT_NB_EBANDS * SizeOf(Single));
      Move(ErrorIntra[0], Error^, C * CELT_NB_EBANDS * SizeOf(Single));
      Intra := 1;
    end;
  end
  else
  begin
    Move(OldEBandsIntra[0], OldEBands^, C * CELT_NB_EBANDS * SizeOf(Single));
    Move(ErrorIntra[0], Error^, C * CELT_NB_EBANDS * SizeOf(Single));
  end;

  if Intra <> 0 then
    DelayedIntra := NewDistortion
  else
    DelayedIntra := (PRED_COEF[LM] * PRED_COEF[LM]) * DelayedIntra + NewDistortion;
end;

procedure QuantFineEnergy(StartB, EndB: Integer; OldEBands, Error: PSingle;
  const FineQuant: TIntArray; var Enc: TEcEnc; C: Integer);
const
  INV16384: Single = 1.0 / 16384;
var
  I, Ch, Q2, Frac: Integer;
  Offset: Single;
begin
  for I := StartB to EndB - 1 do
  begin
    Frac := 1 shl FineQuant[I];
    if FineQuant[I] <= 0 then Continue;
    for Ch := 0 to C - 1 do
    begin
      Q2 := Floor((Error[I + Ch * CELT_NB_EBANDS] + F_HALF) * Frac);
      if Q2 > Frac - 1 then Q2 := Frac - 1;
      if Q2 < 0 then Q2 := 0;
      EcEncBits(Enc, Q2, FineQuant[I]);
      Offset := (Q2 + F_HALF) * (1 shl (14 - FineQuant[I])) * INV16384 - F_HALF;
      OldEBands[I + Ch * CELT_NB_EBANDS] := OldEBands[I + Ch * CELT_NB_EBANDS] + Offset;
      Error[I + Ch * CELT_NB_EBANDS] := Error[I + Ch * CELT_NB_EBANDS] - Offset;
    end;
  end;
end;

procedure QuantEnergyFinalise(StartB, EndB: Integer; OldEBands, Error: PSingle;
  const FineQuant, FinePriority: TIntArray; BitsLeft: Integer; var Enc: TEcEnc; C: Integer);
const
  INV16384: Single = 1.0 / 16384;
var
  I, Prio, Ch, Q2: Integer;
  Offset: Single;
begin
  for Prio := 0 to 1 do
  begin
    I := StartB;
    while (I < EndB) and (BitsLeft >= C) do
    begin
      if (FineQuant[I] >= MAX_FINE_BITS) or (FinePriority[I] <> Prio) then
      begin
        Inc(I);
        Continue;
      end;
      for Ch := 0 to C - 1 do
      begin
        if Error[I + Ch * CELT_NB_EBANDS] < 0 then Q2 := 0 else Q2 := 1;
        EcEncBits(Enc, Q2, 1);
        Offset := (Q2 - F_HALF) * (1 shl (14 - FineQuant[I] - 1)) * INV16384;
        OldEBands[I + Ch * CELT_NB_EBANDS] := OldEBands[I + Ch * CELT_NB_EBANDS] + Offset;
        Error[I + Ch * CELT_NB_EBANDS] := Error[I + Ch * CELT_NB_EBANDS] - Offset;
        Dec(BitsLeft);
      end;
      Inc(I);
    end;
  end;
end;

// ---------------------------------------------------------------------------
// rate.c (encoder)
// ---------------------------------------------------------------------------

function InterpBits2PulsesEnc(StartB, EndB, SkipStart: Integer;
  const Bits1, Bits2, Thresh, Cap: TIntArray; Total: Integer; out Balance: Integer;
  SkipRsv: Integer; var Intensity: Integer; IntensityRsv: Integer;
  var DualStereo: Integer; DualStereoRsv: Integer; var Bits, EBits, FinePriority: TIntArray;
  C, LM: Integer; var Enc: TEcEnc; Prev, SignalBandwidth: Integer): Integer;
var
  Psum, Lo, Hi, I, J, Mid, Tmp: Integer;
  LogM, Stereo, CodedBands, AllocFloor: Integer;
  Left, PerCoeff, Done, Bal: Integer;
  BandWidth, BandBits, Rem, DepthThreshold: Integer;
  N0, N, Den, Offset, NClogN, Excess, Bit: Integer;
  ExtraFine, ExtraBits: Integer;
begin
  AllocFloor := C shl BITRES;
  Stereo := Ord(C > 1);
  LogM := LM shl BITRES;
  Lo := 0;
  Hi := 1 shl ALLOC_STEPS;
  for I := 0 to ALLOC_STEPS - 1 do
  begin
    Mid := (Lo + Hi) shr 1;
    Psum := 0;
    Done := 0;
    for J := EndB - 1 downto StartB do
    begin
      Tmp := Bits1[J] + (Mid * Bits2[J] shr ALLOC_STEPS);
      if (Tmp >= Thresh[J]) or (Done <> 0) then
      begin
        Done := 1;
        Psum := Psum + Min(Tmp, Cap[J]);
      end
      else if Tmp >= AllocFloor then
        Psum := Psum + AllocFloor;
    end;
    if Psum > Total then Hi := Mid
    else Lo := Mid;
  end;
  Psum := 0;
  Done := 0;
  for J := EndB - 1 downto StartB do
  begin
    Tmp := Bits1[J] + (Lo * Bits2[J] shr ALLOC_STEPS);
    if (Tmp < Thresh[J]) and (Done = 0) then
    begin
      if Tmp >= AllocFloor then Tmp := AllocFloor
      else Tmp := 0;
    end
    else
      Done := 1;
    Tmp := Min(Tmp, Cap[J]);
    Bits[J] := Tmp;
    Psum := Psum + Tmp;
  end;

  CodedBands := EndB;
  while True do
  begin
    J := CodedBands - 1;
    if J <= SkipStart then
    begin
      Total := Total + SkipRsv;
      Break;
    end;
    Left := Total - Psum;
    PerCoeff := Integer(Cardinal(Left) div Cardinal(CELT_EBANDS[CodedBands] - CELT_EBANDS[StartB]));
    Left := Left - (CELT_EBANDS[CodedBands] - CELT_EBANDS[StartB]) * PerCoeff;
    Rem := Max(Left - (CELT_EBANDS[J] - CELT_EBANDS[StartB]), 0);
    BandWidth := CELT_EBANDS[CodedBands] - CELT_EBANDS[J];
    BandBits := Bits[J] + PerCoeff * BandWidth + Rem;
    if BandBits >= Max(Thresh[J], AllocFloor + (1 shl BITRES)) then
    begin
      if CodedBands > 17 then
      begin
        if J < Prev then DepthThreshold := 7 else DepthThreshold := 9;
      end
      else
        DepthThreshold := 0;
      if (CodedBands <= StartB + 2) or
         ((BandBits > ((DepthThreshold * BandWidth) shl LM shl BITRES) shr 4) and (J <= SignalBandwidth)) then
      begin
        EcEncBitLogp(Enc, 1, 1);
        Break;
      end;
      EcEncBitLogp(Enc, 0, 1);
      Psum := Psum + (1 shl BITRES);
      BandBits := BandBits - (1 shl BITRES);
    end;
    Psum := Psum - (Bits[J] + IntensityRsv);
    if IntensityRsv > 0 then
      IntensityRsv := LOG2_FRAC_TABLE[J - StartB];
    Psum := Psum + IntensityRsv;
    if BandBits >= AllocFloor then
    begin
      Psum := Psum + AllocFloor;
      Bits[J] := AllocFloor;
    end
    else
      Bits[J] := 0;
    Dec(CodedBands);
  end;

  if IntensityRsv > 0 then
  begin
    Intensity := Min(Intensity, CodedBands);
    EcEncUInt(Enc, Intensity - StartB, CodedBands + 1 - StartB);
  end
  else
    Intensity := 0;
  if Intensity <= StartB then
  begin
    Total := Total + DualStereoRsv;
    DualStereoRsv := 0;
  end;
  if DualStereoRsv > 0 then
    EcEncBitLogp(Enc, DualStereo, 1)
  else
    DualStereo := 0;

  Left := Total - Psum;
  PerCoeff := Integer(Cardinal(Left) div Cardinal(CELT_EBANDS[CodedBands] - CELT_EBANDS[StartB]));
  Left := Left - (CELT_EBANDS[CodedBands] - CELT_EBANDS[StartB]) * PerCoeff;
  for J := StartB to CodedBands - 1 do
    Bits[J] := Bits[J] + PerCoeff * (CELT_EBANDS[J + 1] - CELT_EBANDS[J]);
  for J := StartB to CodedBands - 1 do
  begin
    Tmp := Min(Left, CELT_EBANDS[J + 1] - CELT_EBANDS[J]);
    Bits[J] := Bits[J] + Tmp;
    Left := Left - Tmp;
  end;

  Bal := 0;
  for J := StartB to CodedBands - 1 do
  begin
    N0 := CELT_EBANDS[J + 1] - CELT_EBANDS[J];
    N := N0 shl LM;
    Bit := Bits[J] + Bal;
    if N > 1 then
    begin
      Excess := Max(Bit - Cap[J], 0);
      Bits[J] := Bit - Excess;
      Den := C * N;
      if (C = 2) and (N > 2) and (DualStereo = 0) and (J < Intensity) then Inc(Den);
      NClogN := Den * (CELT_LOGN400[J] + LogM);
      Offset := (NClogN shr 1) - Den * FINE_OFFSET;
      if N = 2 then
        Offset := Offset + (Den shl BITRES shr 2);
      if Bits[J] + Offset < Den * 2 shl BITRES then
        Offset := Offset + (NClogN shr 2)
      else if Bits[J] + Offset < Den * 3 shl BITRES then
        Offset := Offset + (NClogN shr 3);
      EBits[J] := Max(0, Bits[J] + Offset + (Den shl (BITRES - 1)));
      EBits[J] := Integer(Cardinal(EBits[J]) div Cardinal(Den)) shr BITRES;
      if C * EBits[J] > (Bits[J] shr BITRES) then
        EBits[J] := Bits[J] shr Stereo shr BITRES;
      EBits[J] := Min(EBits[J], MAX_FINE_BITS);
      FinePriority[J] := Ord(EBits[J] * (Den shl BITRES) >= Bits[J] + Offset);
      Bits[J] := Bits[J] - (C * EBits[J] shl BITRES);
    end
    else
    begin
      Excess := Max(0, Bit - (C shl BITRES));
      Bits[J] := Bit - Excess;
      EBits[J] := 0;
      FinePriority[J] := 1;
    end;
    if Excess > 0 then
    begin
      ExtraFine := Min(Excess shr (Stereo + BITRES), MAX_FINE_BITS - EBits[J]);
      EBits[J] := EBits[J] + ExtraFine;
      ExtraBits := ExtraFine * C shl BITRES;
      FinePriority[J] := Ord(ExtraBits >= Excess - Bal);
      Excess := Excess - ExtraBits;
    end;
    Bal := Excess;
  end;
  Balance := Bal;

  for J := CodedBands to EndB - 1 do
  begin
    EBits[J] := Bits[J] shr Stereo shr BITRES;
    Bits[J] := 0;
    FinePriority[J] := Ord(EBits[J] < 1);
  end;
  Result := CodedBands;
end;

function CltComputeAllocationEnc(StartB, EndB: Integer; const Offsets, Cap: TIntArray;
  AllocTrim: Integer; var Intensity, DualStereo: Integer; Total: Integer;
  out Balance: Integer; var Pulses, EBits, FinePriority: TIntArray;
  C, LM: Integer; var Enc: TEcEnc; Prev, SignalBandwidth: Integer): Integer;
var
  Lo, Hi, Len, J: Integer;
  SkipStart, SkipRsv, IntensityRsv, DualStereoRsv: Integer;
  Bits1, Bits2, Thresh, TrimOffset: TIntArray;
  Done, Psum, Mid, BitsJ, N: Integer;
  Bits1J, Bits2J: Integer;
begin
  Total := Max(Total, 0);
  Len := CELT_NB_EBANDS;
  SkipStart := StartB;
  if Total >= 1 shl BITRES then SkipRsv := 1 shl BITRES else SkipRsv := 0;
  Total := Total - SkipRsv;
  IntensityRsv := 0;
  DualStereoRsv := 0;
  if C = 2 then
  begin
    IntensityRsv := LOG2_FRAC_TABLE[EndB - StartB];
    if IntensityRsv > Total then
      IntensityRsv := 0
    else
    begin
      Total := Total - IntensityRsv;
      if Total >= 1 shl BITRES then DualStereoRsv := 1 shl BITRES else DualStereoRsv := 0;
      Total := Total - DualStereoRsv;
    end;
  end;
  SetLength(Bits1, Len); SetLength(Bits2, Len);
  SetLength(Thresh, Len); SetLength(TrimOffset, Len);
  SetLength(Pulses, Len); SetLength(EBits, Len); SetLength(FinePriority, Len);
  for J := StartB to EndB - 1 do
  begin
    Thresh[J] := Max(C shl BITRES, (3 * (CELT_EBANDS[J + 1] - CELT_EBANDS[J]) shl LM shl BITRES) shr 4);
    TrimOffset[J] := Sar(C * (CELT_EBANDS[J + 1] - CELT_EBANDS[J]) * (AllocTrim - 5 - LM) * (EndB - J - 1)
                     * (1 shl (LM + BITRES)), 6);
    if (CELT_EBANDS[J + 1] - CELT_EBANDS[J]) shl LM = 1 then
      TrimOffset[J] := TrimOffset[J] - (C shl BITRES);
  end;
  Lo := 1;
  Hi := CELT_NB_ALLOC_VECS - 1;
  repeat
    Done := 0;
    Psum := 0;
    Mid := (Lo + Hi) shr 1;
    for J := EndB - 1 downto StartB do
    begin
      N := CELT_EBANDS[J + 1] - CELT_EBANDS[J];
      BitsJ := C * N * CELT_BAND_ALLOCATION[Mid * Len + J] shl LM shr 2;
      if BitsJ > 0 then
        BitsJ := Max(0, BitsJ + TrimOffset[J]);
      BitsJ := BitsJ + Offsets[J];
      if (BitsJ >= Thresh[J]) or (Done <> 0) then
      begin
        Done := 1;
        Psum := Psum + Min(BitsJ, Cap[J]);
      end
      else if BitsJ >= C shl BITRES then
        Psum := Psum + (C shl BITRES);
    end;
    if Psum > Total then Hi := Mid - 1
    else Lo := Mid + 1;
  until Lo > Hi;
  Hi := Lo;
  Dec(Lo);
  for J := StartB to EndB - 1 do
  begin
    N := CELT_EBANDS[J + 1] - CELT_EBANDS[J];
    Bits1J := C * N * CELT_BAND_ALLOCATION[Lo * Len + J] shl LM shr 2;
    if Hi >= CELT_NB_ALLOC_VECS then Bits2J := Cap[J]
    else Bits2J := C * N * CELT_BAND_ALLOCATION[Hi * Len + J] shl LM shr 2;
    if Bits1J > 0 then Bits1J := Max(0, Bits1J + TrimOffset[J]);
    if Bits2J > 0 then Bits2J := Max(0, Bits2J + TrimOffset[J]);
    if Lo > 0 then Bits1J := Bits1J + Offsets[J];
    Bits2J := Bits2J + Offsets[J];
    if Offsets[J] > 0 then SkipStart := J;
    Bits2J := Max(0, Bits2J - Bits1J);
    Bits1[J] := Bits1J;
    Bits2[J] := Bits2J;
  end;
  Result := InterpBits2PulsesEnc(StartB, EndB, SkipStart, Bits1, Bits2, Thresh, Cap,
    Total, Balance, SkipRsv, Intensity, IntensityRsv, DualStereo, DualStereoRsv,
    Pulses, EBits, FinePriority, C, LM, Enc, Prev, SignalBandwidth);
end;

// ---------------------------------------------------------------------------
// bands.c: quant_all_bands (encode = 1)
// ---------------------------------------------------------------------------

type
  TBandCtxE = record
    Resynth      : Boolean;
    I            : Integer;
    Intensity    : Integer;
    Spread       : Integer;
    TfChange     : Integer;
    Ec           : PEcEnc;
    RemainingBits: Integer;
    BandE        : PSingle;
    Seed         : Cardinal;
    ThetaRound   : Integer;
    DisableInv   : Boolean;
    AvoidSplitNoise: Boolean;
  end;

  TSplitCtxE = record
    Inv, IMid, ISide, Delta, ITheta, QAlloc: Integer;
  end;

function ComputeQn(N, B, Offset, PulseCap: Integer; Stereo: Boolean): Integer;
const
  EXP2_TABLE8: array[0..7] of Integer = (16384, 17866, 19483, 21247, 23170, 25267, 27554, 30048);
var
  Qn, Qb, N2: Integer;
begin
  N2 := 2 * N - 1;
  if Stereo and (N = 2) then Dec(N2);
  Qb := (B + N2 * Offset) div N2;
  Qb := Min(B - PulseCap - (4 shl BITRES), Qb);
  Qb := Min(8 shl BITRES, Qb);
  if Qb < (1 shl BITRES shr 1) then
    Qn := 1
  else
  begin
    Qn := EXP2_TABLE8[Qb and 7] shr (14 - (Qb shr BITRES));
    Qn := ((Qn + 1) shr 1) shl 1;
  end;
  Result := Qn;
end;

procedure IntensityStereo(X, Y: PSingle; BandE: PSingle; BandID, N: Integer);
var
  J: Integer;
  A1, A2, Left, Right, Norm: Single;
begin
  Left := BandE[BandID];
  Right := BandE[BandID + CELT_NB_EBANDS];
  Norm := F_EPSILON + SqrtF(F_EPSILON + Left * Left + Right * Right);
  A1 := Left / Norm;
  A2 := Right / Norm;
  for J := 0 to N - 1 do
    X[J] := A1 * X[J] + A2 * Y[J];
end;

procedure StereoSplit(X, Y: PSingle; N: Integer);
var
  J: Integer;
  L, R: Single;
begin
  for J := 0 to N - 1 do
  begin
    L := F_R2 * X[J];
    R := F_R2 * Y[J];
    X[J] := L + R;
    Y[J] := R - L;
  end;
end;

procedure StereoMergeF(X, Y: PSingle; Mid: Single; N: Integer);
const
  T6E4: Single = 6e-4;
var
  J: Integer;
  Xp, Side, El, Er, Mid2, LGain, RGain, L, R: Single;
begin
  Xp := 0; Side := 0;
  for J := 0 to N - 1 do
  begin
    Xp := Xp + Y[J] * X[J];
    Side := Side + Y[J] * Y[J];
  end;
  Xp := Mid * Xp;
  Mid2 := Mid;
  El := Mid2 * Mid2 + Side - 2 * Xp;
  Er := Mid2 * Mid2 + Side + 2 * Xp;
  if (Er < T6E4) or (El < T6E4) then
  begin
    Move(X^, Y^, N * SizeOf(Single));
    Exit;
  end;
  LGain := F_ONE / SqrtF(El);
  RGain := F_ONE / SqrtF(Er);
  for J := 0 to N - 1 do
  begin
    L := Mid * X[J];
    R := Y[J];
    X[J] := LGain * (L - R);
    Y[J] := RGain * (L + R);
  end;
end;

procedure ComputeThetaE(var Ctx: TBandCtxE; out SCtx: TSplitCtxE; X, Y: PSingle;
  N: Integer; var B: Integer; BB, B0, LM: Integer; Stereo: Boolean; var Fill: Integer);
var
  Qn, ITheta, Delta, IMid, ISide, QAlloc, PulseCap, Offset: Integer;
  Tell, Inv, Unquantized, Bias, Down, J: Integer;
  P0, Xv, X0, Ft, Fs, Fl: Integer;
begin
  Inv := 0;
  PulseCap := CELT_LOGN400[Ctx.I] + LM * (1 shl BITRES);
  if Stereo and (N = 2) then Offset := (PulseCap shr 1) - QTHETA_OFFSET_TWOPHASE
  else Offset := (PulseCap shr 1) - QTHETA_OFFSET;
  Qn := ComputeQn(N, B, Offset, PulseCap, Stereo);
  if Stereo and (Ctx.I >= Ctx.Intensity) then Qn := 1;
  ITheta := StereoItheta(X, Y, Stereo, N);
  Tell := EcTellFrac(Ctx.Ec^);
  if Qn <> 1 then
  begin
    if (not Stereo) or (Ctx.ThetaRound = 0) then
    begin
      ITheta := (ITheta * Qn + 8192) shr 14;
      if (not Stereo) and Ctx.AvoidSplitNoise and (ITheta > 0) and (ITheta < Qn) then
      begin
        Unquantized := Integer(Cardinal(ITheta * 16384) div Cardinal(Qn));
        IMid := BitexactCos(SmallInt(Unquantized));
        ISide := BitexactCos(SmallInt(16384 - Unquantized));
        Delta := FracMul16((N - 1) shl 7, BitexactLog2Tan(ISide, IMid));
        if Delta > B then ITheta := Qn
        else if Delta < -B then ITheta := 0;
      end;
    end
    else
    begin
      if ITheta > 8192 then Bias := 32767 div Qn else Bias := -(32767 div Qn);
      Down := Min(Qn - 1, Max(0, Sar(ITheta * Qn + Bias, 14)));
      if Ctx.ThetaRound < 0 then ITheta := Down
      else ITheta := Down + 1;
    end;
    if Stereo and (N > 2) then
    begin
      P0 := 3;
      Xv := ITheta;
      X0 := Qn div 2;
      Ft := P0 * (X0 + 1) + X0;
      if Xv <= X0 then
        EcEncode(Ctx.Ec^, P0 * Xv, P0 * (Xv + 1), Ft)
      else
        EcEncode(Ctx.Ec^, (Xv - 1 - X0) + (X0 + 1) * P0, (Xv - X0) + (X0 + 1) * P0, Ft);
    end
    else if (B0 > 1) or Stereo then
      EcEncUInt(Ctx.Ec^, ITheta, Qn + 1)
    else
    begin
      Ft := ((Qn shr 1) + 1) * ((Qn shr 1) + 1);
      if ITheta <= (Qn shr 1) then
      begin
        Fs := ITheta + 1;
        Fl := ITheta * (ITheta + 1) shr 1;
      end
      else
      begin
        Fs := Qn + 1 - ITheta;
        Fl := Ft - ((Qn + 1 - ITheta) * (Qn + 2 - ITheta) shr 1);
      end;
      EcEncode(Ctx.Ec^, Fl, Fl + Fs, Ft);
    end;
    ITheta := Integer(Cardinal(ITheta * 16384) div Cardinal(Qn));
    if Stereo then
    begin
      if ITheta = 0 then
        IntensityStereo(X, Y, Ctx.BandE, Ctx.I, N)
      else
        StereoSplit(X, Y, N);
    end;
  end
  else if Stereo then
  begin
    Inv := Ord((ITheta > 8192) and not Ctx.DisableInv);
    if Inv <> 0 then
      for J := 0 to N - 1 do
        Y[J] := -Y[J];
    IntensityStereo(X, Y, Ctx.BandE, Ctx.I, N);
    if (B > 2 shl BITRES) and (Ctx.RemainingBits > 2 shl BITRES) then
      EcEncBitLogp(Ctx.Ec^, Inv, 2)
    else
      Inv := 0;
    if Ctx.DisableInv then Inv := 0;
    ITheta := 0;
  end;
  QAlloc := Integer(EcTellFrac(Ctx.Ec^)) - Tell;
  B := B - QAlloc;

  if ITheta = 0 then
  begin
    IMid := 32767;
    ISide := 0;
    Fill := Fill and ((1 shl BB) - 1);
    Delta := -16384;
  end
  else if ITheta = 16384 then
  begin
    IMid := 0;
    ISide := 32767;
    Fill := Fill and (((1 shl BB) - 1) shl BB);
    Delta := 16384;
  end
  else
  begin
    IMid := BitexactCos(SmallInt(ITheta));
    ISide := BitexactCos(SmallInt(16384 - ITheta));
    Delta := FracMul16((N - 1) shl 7, BitexactLog2Tan(ISide, IMid));
  end;
  SCtx.Inv := Inv;
  SCtx.IMid := IMid;
  SCtx.ISide := ISide;
  SCtx.Delta := Delta;
  SCtx.ITheta := ITheta;
  SCtx.QAlloc := QAlloc;
end;

function QuantBandN1E(var Ctx: TBandCtxE; X, Y: PSingle; LowbandOut: PSingle): Cardinal;
var
  C, Sign: Integer;
  Xp: PSingle;
begin
  Xp := X;
  for C := 0 to Ord(Y <> nil) do
  begin
    Sign := 0;
    if Ctx.RemainingBits >= 1 shl BITRES then
    begin
      Sign := Ord(Xp[0] < 0);
      EcEncBits(Ctx.Ec^, Sign, 1);
      Ctx.RemainingBits := Ctx.RemainingBits - (1 shl BITRES);
    end;
    if Ctx.Resynth then
    begin
      if Sign <> 0 then Xp[0] := -NORM_SCALING else Xp[0] := NORM_SCALING;
    end;
    Xp := Y;
  end;
  if LowbandOut <> nil then
    LowbandOut[0] := X[0];
  Result := 1;
end;

function QuantPartitionE(var Ctx: TBandCtxE; X: PSingle; N, B, BB: Integer;
  Lowband: PSingle; LM: Integer; Gain: Single; Fill: Integer): Cardinal;
const
  FOLD_NOISE: Single = 1.0 / 256;
var
  Cache: PByte;
  Q, CurrBits, IMid, ISide, B0, MBits, SBits, Delta, ITheta, QAlloc, Rebalance, K, J: Integer;
  Mid, Side, Tmp: Single;
  Cm, CmMask: Cardinal;
  Y, NextLowband2: PSingle;
  SCtx: TSplitCtxE;
begin
  Cm := 0;
  B0 := BB;
  Cache := @CELT_CACHE_BITS50[CELT_CACHE_INDEX50[(LM + 1) * CELT_NB_EBANDS + Ctx.I]];
  if (LM <> -1) and (B > Cache[Cache[0]] + 12) and (N > 2) then
  begin
    NextLowband2 := nil;
    N := N shr 1;
    Y := X + N;
    LM := LM - 1;
    if BB = 1 then
      Fill := (Fill and 1) or (Fill shl 1);
    BB := (BB + 1) shr 1;
    ComputeThetaE(Ctx, SCtx, X, Y, N, B, BB, B0, LM, False, Fill);
    IMid := SCtx.IMid;
    ISide := SCtx.ISide;
    Delta := SCtx.Delta;
    ITheta := SCtx.ITheta;
    QAlloc := SCtx.QAlloc;
    Mid := (F_ONE / 32768) * IMid;
    Side := (F_ONE / 32768) * ISide;
    if (B0 > 1) and ((ITheta and $3FFF) <> 0) then
    begin
      if ITheta > 8192 then
        Delta := Delta - Sar(Delta, 4 - LM)
      else
        Delta := Min(0, Delta + (N shl BITRES shr (5 - LM)));
    end;
    MBits := Max(0, Min(B, (B - Delta) div 2));
    SBits := B - MBits;
    Ctx.RemainingBits := Ctx.RemainingBits - QAlloc;
    if Lowband <> nil then
      NextLowband2 := Lowband + N;
    Rebalance := Ctx.RemainingBits;
    if MBits >= SBits then
    begin
      Cm := QuantPartitionE(Ctx, X, N, MBits, BB, Lowband, LM, Gain * Mid, Fill);
      Rebalance := MBits - (Rebalance - Ctx.RemainingBits);
      if (Rebalance > 3 shl BITRES) and (ITheta <> 0) then
        SBits := SBits + (Rebalance - (3 shl BITRES));
      Cm := Cm or (QuantPartitionE(Ctx, Y, N, SBits, BB, NextLowband2, LM, Gain * Side, Fill shr BB) shl (B0 shr 1));
    end
    else
    begin
      Cm := QuantPartitionE(Ctx, Y, N, SBits, BB, NextLowband2, LM, Gain * Side, Fill shr BB) shl (B0 shr 1);
      Rebalance := SBits - (Rebalance - Ctx.RemainingBits);
      if (Rebalance > 3 shl BITRES) and (ITheta <> 16384) then
        MBits := MBits + (Rebalance - (3 shl BITRES));
      Cm := Cm or QuantPartitionE(Ctx, X, N, MBits, BB, Lowband, LM, Gain * Mid, Fill);
    end;
  end
  else
  begin
    Q := Bits2Pulses(Ctx.I, LM, B);
    CurrBits := Pulses2Bits(Ctx.I, LM, Q);
    Ctx.RemainingBits := Ctx.RemainingBits - CurrBits;
    while (Ctx.RemainingBits < 0) and (Q > 0) do
    begin
      Ctx.RemainingBits := Ctx.RemainingBits + CurrBits;
      Dec(Q);
      CurrBits := Pulses2Bits(Ctx.I, LM, Q);
      Ctx.RemainingBits := Ctx.RemainingBits - CurrBits;
    end;
    if Q <> 0 then
    begin
      K := GetPulses(Q);
      Cm := AlgQuant(X, N, K, Ctx.Spread, BB, Ctx.Ec^, Gain, Ctx.Resynth);
    end
    else if Ctx.Resynth then
    begin
      CmMask := (Cardinal(1) shl BB) - 1;
      Fill := Fill and Integer(CmMask);
      if Fill = 0 then
        FillChar(X^, N * SizeOf(Single), 0)
      else
      begin
        if Lowband = nil then
        begin
          for J := 0 to N - 1 do
          begin
            Ctx.Seed := CeltLcgRand(Ctx.Seed);
            X[J] := Sar(Integer(Ctx.Seed), 20);
          end;
          Cm := CmMask;
        end
        else
        begin
          for J := 0 to N - 1 do
          begin
            Ctx.Seed := CeltLcgRand(Ctx.Seed);
            if (Ctx.Seed and $8000) <> 0 then Tmp := FOLD_NOISE else Tmp := -FOLD_NOISE;
            X[J] := Lowband[J] + Tmp;
          end;
          Cm := Cardinal(Fill);
        end;
        RenormaliseVectorF(X, N, Gain);
      end;
    end;
  end;
  Result := Cm;
end;

function QuantBandE(var Ctx: TBandCtxE; X: PSingle; N, B, BB: Integer;
  Lowband: PSingle; LM: Integer; LowbandOut: PSingle; Gain: Single;
  LowbandScratch: PSingle; Fill: Integer): Cardinal;
const
  BIT_INTERLEAVE_TABLE: array[0..15] of Byte = (0,1,1,1,2,3,3,3,2,3,3,3,2,3,3,3);
  BIT_DEINTERLEAVE_TABLE: array[0..15] of Byte = (
    $00,$03,$0C,$0F,$30,$33,$3C,$3F,$C0,$C3,$CC,$CF,$F0,$F3,$FC,$FF);
var
  N0, N_B, N_B0, B0, TimeDivide, Recombine, K, J, TfChange: Integer;
  LongBlocks: Boolean;
  Cm: Cardinal;
  Nrm: Single;
begin
  N0 := N;
  N_B := N;
  B0 := BB;
  TimeDivide := 0;
  Recombine := 0;
  TfChange := Ctx.TfChange;
  LongBlocks := B0 = 1;
  N_B := N_B div BB;

  if N = 1 then
    Exit(QuantBandN1E(Ctx, X, nil, LowbandOut));

  if TfChange > 0 then Recombine := TfChange;

  if (LowbandScratch <> nil) and (Lowband <> nil) and
     ((Recombine <> 0) or (((N_B and 1) = 0) and (TfChange < 0)) or (B0 > 1)) then
  begin
    Move(Lowband^, LowbandScratch^, N * SizeOf(Single));
    Lowband := LowbandScratch;
  end;

  for K := 0 to Recombine - 1 do
  begin
    Haar1F(X, N shr K, 1 shl K);
    if Lowband <> nil then
      Haar1F(Lowband, N shr K, 1 shl K);
    Fill := BIT_INTERLEAVE_TABLE[Fill and $F] or (BIT_INTERLEAVE_TABLE[Fill shr 4] shl 2);
  end;
  BB := BB shr Recombine;
  N_B := N_B shl Recombine;

  while ((N_B and 1) = 0) and (TfChange < 0) do
  begin
    Haar1F(X, N_B, BB);
    if Lowband <> nil then
      Haar1F(Lowband, N_B, BB);
    Fill := Fill or (Fill shl BB);
    BB := BB shl 1;
    N_B := N_B shr 1;
    Inc(TimeDivide);
    Inc(TfChange);
  end;
  B0 := BB;
  N_B0 := N_B;

  if B0 > 1 then
  begin
    DeinterleaveHadamard(X, N_B shr Recombine, B0 shl Recombine, LongBlocks);
    if Lowband <> nil then
      DeinterleaveHadamard(Lowband, N_B shr Recombine, B0 shl Recombine, LongBlocks);
  end;

  Cm := QuantPartitionE(Ctx, X, N, B, BB, Lowband, LM, Gain, Fill);

  if Ctx.Resynth then
  begin
    if B0 > 1 then
      InterleaveHadamard(X, N_B shr Recombine, B0 shl Recombine, LongBlocks);
    N_B := N_B0;
    BB := B0;
    for K := 0 to TimeDivide - 1 do
    begin
      BB := BB shr 1;
      N_B := N_B shl 1;
      Cm := Cm or (Cm shr BB);
      Haar1F(X, N_B, BB);
    end;
    for K := 0 to Recombine - 1 do
    begin
      Cm := BIT_DEINTERLEAVE_TABLE[Cm];
      Haar1F(X, N0 shr K, 1 shl K);
    end;
    BB := BB shl Recombine;
    if LowbandOut <> nil then
    begin
      Nrm := Sqrt(Double(N0));
      for J := 0 to N0 - 1 do
        LowbandOut[J] := Nrm * X[J];
    end;
    Cm := Cm and ((Cardinal(1) shl BB) - 1);
  end;
  Result := Cm;
end;

function QuantBandStereoE(var Ctx: TBandCtxE; X, Y: PSingle; N, B, BB: Integer;
  Lowband: PSingle; LM: Integer; LowbandOut: PSingle; LowbandScratch: PSingle;
  Fill: Integer): Cardinal;
var
  IMid, ISide, Inv, MBits, SBits, Delta, ITheta, QAlloc, OrigFill, C, Sign, J, Rebalance: Integer;
  Mid, Side, Tmp: Single;
  Cm: Cardinal;
  SCtx: TSplitCtxE;
  X2, Y2: PSingle;
begin
  if N = 1 then
    Exit(QuantBandN1E(Ctx, X, Y, LowbandOut));
  OrigFill := Fill;
  ComputeThetaE(Ctx, SCtx, X, Y, N, B, BB, BB, LM, True, Fill);
  Inv := SCtx.Inv;
  IMid := SCtx.IMid;
  ISide := SCtx.ISide;
  Delta := SCtx.Delta;
  ITheta := SCtx.ITheta;
  QAlloc := SCtx.QAlloc;
  Mid := (F_ONE / 32768) * IMid;
  Side := (F_ONE / 32768) * ISide;

  if N = 2 then
  begin
    MBits := B;
    SBits := 0;
    if (ITheta <> 0) and (ITheta <> 16384) then
      SBits := 1 shl BITRES;
    MBits := MBits - SBits;
    C := Ord(ITheta > 8192);
    Ctx.RemainingBits := Ctx.RemainingBits - (QAlloc + SBits);
    if C <> 0 then begin X2 := Y; Y2 := X; end
    else begin X2 := X; Y2 := Y; end;
    Sign := 0;
    if SBits <> 0 then
    begin
      Sign := Ord(X2[0] * Y2[1] - X2[1] * Y2[0] < 0);
      EcEncBits(Ctx.Ec^, Sign, 1);
    end;
    Sign := 1 - 2 * Sign;
    Cm := QuantBandE(Ctx, X2, N, MBits, BB, Lowband, LM, LowbandOut, F_ONE, LowbandScratch, OrigFill);
    Y2[0] := -Sign * X2[1];
    Y2[1] := Sign * X2[0];
    if Ctx.Resynth then
    begin
      X[0] := Mid * X[0];
      X[1] := Mid * X[1];
      Y[0] := Side * Y[0];
      Y[1] := Side * Y[1];
      Tmp := X[0];
      X[0] := Tmp - Y[0];
      Y[0] := Tmp + Y[0];
      Tmp := X[1];
      X[1] := Tmp - Y[1];
      Y[1] := Tmp + Y[1];
    end;
  end
  else
  begin
    MBits := Max(0, Min(B, (B - Delta) div 2));
    SBits := B - MBits;
    Ctx.RemainingBits := Ctx.RemainingBits - QAlloc;
    Rebalance := Ctx.RemainingBits;
    if MBits >= SBits then
    begin
      Cm := QuantBandE(Ctx, X, N, MBits, BB, Lowband, LM, LowbandOut, F_ONE, LowbandScratch, Fill);
      Rebalance := MBits - (Rebalance - Ctx.RemainingBits);
      if (Rebalance > 3 shl BITRES) and (ITheta <> 0) then
        SBits := SBits + (Rebalance - (3 shl BITRES));
      Cm := Cm or QuantBandE(Ctx, Y, N, SBits, BB, nil, LM, nil, Side, nil, Fill shr BB);
    end
    else
    begin
      Cm := QuantBandE(Ctx, Y, N, SBits, BB, nil, LM, nil, Side, nil, Fill shr BB);
      Rebalance := SBits - (Rebalance - Ctx.RemainingBits);
      if (Rebalance > 3 shl BITRES) and (ITheta <> 16384) then
        MBits := MBits + (Rebalance - (3 shl BITRES));
      Cm := Cm or QuantBandE(Ctx, X, N, MBits, BB, Lowband, LM, LowbandOut, F_ONE, LowbandScratch, Fill);
    end;
  end;

  if Ctx.Resynth then
  begin
    if N <> 2 then
      StereoMergeF(X, Y, Mid, N);
    if Inv <> 0 then
      for J := 0 to N - 1 do
        Y[J] := -Y[J];
  end;
  Result := Cm;
end;

procedure SpecialHybridFolding(Norm, Norm2: PSingle; StartB, M: Integer; DualStereo: Integer);
var
  N1, N2: Integer;
begin
  N1 := M * (CELT_EBANDS[StartB + 1] - CELT_EBANDS[StartB]);
  N2 := M * (CELT_EBANDS[StartB + 2] - CELT_EBANDS[StartB + 1]);
  if N2 - N1 > 0 then
  begin
    Move((Norm + (2 * N1 - N2))^, (Norm + N1)^, (N2 - N1) * SizeOf(Single));
    if DualStereo <> 0 then
      Move((Norm2 + (2 * N1 - N2))^, (Norm2 + N1)^, (N2 - N1) * SizeOf(Single));
  end;
end;

procedure QuantAllBandsEnc(StartB, EndB: Integer; X_, Y_: PSingle;
  CollapseMasks: PByte; BandE: PSingle; const Pulses: TIntArray;
  ShortBlocks, Spread, DualStereo, Intensity: Integer; const TfRes: TIntArray;
  TotalBits, Balance: Integer; var Enc: TEcEnc; LM, CodedBands: Integer;
  var Seed: Cardinal; Complexity: Integer; DisableInv: Boolean);
var
  I, J, M, BB, C, NormOffset, LowbandOffset, ResynthAlloc: Integer;
  RemainingBits, Tell, B, N, CurrBalance, EffectiveLowband, TfChange: Integer;
  FoldStart, FoldEnd, FoldI: Integer;
  NormBuf, LowbandScratchBuf, XSave, YSave, XSave2, YSave2, NormSave2: array of Single;
  Norm, Norm2, LowbandScratch, X, Y, LowbandPtr, LowbandOutPtr: PSingle;
  UpdateLowband, Last, ThetaRdo, Resynth: Boolean;
  XCm, YCm, Cm, Cm2: Cardinal;
  Ctx, CtxSave, CtxSave2: TBandCtxE;
  EcSave, EcSave2: TEcEnc;
  W: array[0..1] of Single;
  MinE, Ex, Ey, Dist0, Dist1: Single;
  NStartBytes, NEndBytes, SaveBytes: Integer;
  BytesBuf: PByte;
  BytesSave: array[0..1274] of Byte;
begin
  M := 1 shl LM;
  if ShortBlocks <> 0 then BB := M else BB := 1;
  NormOffset := M * CELT_EBANDS[StartB];
  if Y_ <> nil then C := 2 else C := 1;
  ThetaRdo := (Y_ <> nil) and (DualStereo = 0) and (Complexity >= 8);
  Resynth := ThetaRdo;
  UpdateLowband := True;

  SetLength(NormBuf, C * (M * CELT_EBANDS[CELT_NB_EBANDS - 1] - NormOffset) + 1);
  Norm := @NormBuf[0];
  Norm2 := Norm + M * CELT_EBANDS[CELT_NB_EBANDS - 1] - NormOffset;

  if Resynth then
    ResynthAlloc := M * (CELT_EBANDS[CELT_NB_EBANDS] - CELT_EBANDS[CELT_NB_EBANDS - 1])
  else
    ResynthAlloc := 1;
  SetLength(LowbandScratchBuf, ResynthAlloc);
  SetLength(XSave, ResynthAlloc);
  SetLength(YSave, ResynthAlloc);
  SetLength(XSave2, ResynthAlloc);
  SetLength(YSave2, ResynthAlloc);
  SetLength(NormSave2, ResynthAlloc);
  if Resynth then
    LowbandScratch := @LowbandScratchBuf[0]
  else
    LowbandScratch := X_ + M * CELT_EBANDS[CELT_NB_EBANDS - 1];

  LowbandOffset := 0;
  Ctx.BandE := BandE;
  Ctx.Ec := @Enc;
  Ctx.Intensity := Intensity;
  Ctx.Seed := Seed;
  Ctx.Spread := Spread;
  Ctx.DisableInv := DisableInv;
  Ctx.Resynth := Resynth;
  Ctx.ThetaRound := 0;
  Ctx.AvoidSplitNoise := BB > 1;
  for I := StartB to EndB - 1 do
  begin
    EffectiveLowband := -1;
    Ctx.I := I;
    Last := I = EndB - 1;
    X := X_ + M * CELT_EBANDS[I];
    if Y_ <> nil then Y := Y_ + M * CELT_EBANDS[I] else Y := nil;
    N := M * CELT_EBANDS[I + 1] - M * CELT_EBANDS[I];
    Tell := EcTellFrac(Enc);
    if I <> StartB then
      Balance := Balance - Tell;
    RemainingBits := TotalBits - Tell - 1;
    Ctx.RemainingBits := RemainingBits;
    if I <= CodedBands - 1 then
    begin
      CurrBalance := Balance div Min(3, CodedBands - I);
      B := Max(0, Min(16383, Min(RemainingBits + 1, Pulses[I] + CurrBalance)));
    end
    else
      B := 0;

    if Resynth and ((M * CELT_EBANDS[I] - N >= M * CELT_EBANDS[StartB]) or (I = StartB + 1)) and
       (UpdateLowband or (LowbandOffset = 0)) then
      LowbandOffset := I;
    if I = StartB + 1 then
      SpecialHybridFolding(Norm, Norm2, StartB, M, DualStereo);

    TfChange := TfRes[I];
    Ctx.TfChange := TfChange;
    if I >= CELT_NB_EBANDS then
    begin
      X := Norm;
      if Y_ <> nil then Y := Norm;
      LowbandScratch := nil;
    end;
    if Last and not ThetaRdo then
      LowbandScratch := nil;

    if (LowbandOffset <> 0) and ((Spread <> CELT_SPREAD_AGGRESSIVE) or (BB > 1) or (TfChange < 0)) then
    begin
      EffectiveLowband := Max(0, M * CELT_EBANDS[LowbandOffset] - NormOffset - N);
      FoldStart := LowbandOffset;
      repeat
        Dec(FoldStart);
      until not (M * CELT_EBANDS[FoldStart] > EffectiveLowband + NormOffset);
      FoldEnd := LowbandOffset - 1;
      repeat
        Inc(FoldEnd);
      until not ((FoldEnd < I) and (M * CELT_EBANDS[FoldEnd] < EffectiveLowband + NormOffset + N));
      XCm := 0; YCm := 0;
      FoldI := FoldStart;
      repeat
        XCm := XCm or CollapseMasks[FoldI * C + 0];
        YCm := YCm or CollapseMasks[FoldI * C + C - 1];
        Inc(FoldI);
      until FoldI >= FoldEnd;
    end
    else
    begin
      XCm := (Cardinal(1) shl BB) - 1;
      YCm := XCm;
    end;

    if (DualStereo <> 0) and (I = Intensity) then
    begin
      DualStereo := 0;
      if Resynth then
        for J := 0 to M * CELT_EBANDS[I] - NormOffset - 1 do
          Norm[J] := F_HALF * (Norm[J] + Norm2[J]);
    end;

    if EffectiveLowband <> -1 then LowbandPtr := Norm + EffectiveLowband else LowbandPtr := nil;
    if Last then LowbandOutPtr := nil else LowbandOutPtr := Norm + M * CELT_EBANDS[I] - NormOffset;

    if DualStereo <> 0 then
    begin
      XCm := QuantBandE(Ctx, X, N, B div 2, BB, LowbandPtr, LM, LowbandOutPtr, F_ONE, LowbandScratch, Integer(XCm));
      if EffectiveLowband <> -1 then LowbandPtr := Norm2 + EffectiveLowband else LowbandPtr := nil;
      if Last then LowbandOutPtr := nil else LowbandOutPtr := Norm2 + M * CELT_EBANDS[I] - NormOffset;
      YCm := QuantBandE(Ctx, Y, N, B div 2, BB, LowbandPtr, LM, LowbandOutPtr, F_ONE, LowbandScratch, Integer(YCm));
    end
    else
    begin
      if Y <> nil then
      begin
        if ThetaRdo and (I < Intensity) then
        begin
          // compute_channel_weights
          Ex := BandE[I];
          Ey := BandE[I + CELT_NB_EBANDS];
          if Ex < Ey then MinE := Ex else MinE := Ey;
          Ex := Ex + MinE / 3;
          Ey := Ey + MinE / 3;
          W[0] := Ex;
          W[1] := Ey;
          Cm := XCm or YCm;
          EcSave := Enc;
          CtxSave := Ctx;
          Move(X^, XSave[0], N * SizeOf(Single));
          Move(Y^, YSave[0], N * SizeOf(Single));
          // Encode and round down
          Ctx.ThetaRound := -1;
          XCm := QuantBandStereoE(Ctx, X, Y, N, B, BB, LowbandPtr, LM, LowbandOutPtr, LowbandScratch, Integer(Cm));
          Dist0 := W[0] * CeltInnerProd(@XSave[0], X, N) + W[1] * CeltInnerProd(@YSave[0], Y, N);
          Cm2 := XCm;
          EcSave2 := Enc;
          CtxSave2 := Ctx;
          Move(X^, XSave2[0], N * SizeOf(Single));
          Move(Y^, YSave2[0], N * SizeOf(Single));
          if not Last then
            Move((Norm + M * CELT_EBANDS[I] - NormOffset)^, NormSave2[0], N * SizeOf(Single));
          NStartBytes := EcSave.Offs;
          NEndBytes := EcSave.Storage;
          BytesBuf := EcSave.Buf + NStartBytes;
          SaveBytes := NEndBytes - NStartBytes;
          if SaveBytes > 0 then
            Move(BytesBuf^, BytesSave[0], SaveBytes);

          // Restore
          Enc := EcSave;
          Ctx := CtxSave;
          Ctx.Ec := @Enc;
          Move(XSave[0], X^, N * SizeOf(Single));
          Move(YSave[0], Y^, N * SizeOf(Single));
          if I = StartB + 1 then
            SpecialHybridFolding(Norm, Norm2, StartB, M, DualStereo);
          // Encode and round up
          Ctx.ThetaRound := 1;
          XCm := QuantBandStereoE(Ctx, X, Y, N, B, BB, LowbandPtr, LM, LowbandOutPtr, LowbandScratch, Integer(Cm));
          Dist1 := W[0] * CeltInnerProd(@XSave[0], X, N) + W[1] * CeltInnerProd(@YSave[0], Y, N);
          if Dist0 >= Dist1 then
          begin
            XCm := Cm2;
            Enc := EcSave2;
            Ctx := CtxSave2;
            Ctx.Ec := @Enc;
            Move(XSave2[0], X^, N * SizeOf(Single));
            Move(YSave2[0], Y^, N * SizeOf(Single));
            if not Last then
              Move(NormSave2[0], (Norm + M * CELT_EBANDS[I] - NormOffset)^, N * SizeOf(Single));
            if SaveBytes > 0 then
              Move(BytesSave[0], BytesBuf^, SaveBytes);
          end;
        end
        else
        begin
          Ctx.ThetaRound := 0;
          XCm := QuantBandStereoE(Ctx, X, Y, N, B, BB, LowbandPtr, LM, LowbandOutPtr, LowbandScratch, Integer(XCm or YCm));
        end;
      end
      else
        XCm := QuantBandE(Ctx, X, N, B, BB, LowbandPtr, LM, LowbandOutPtr, F_ONE, LowbandScratch, Integer(XCm or YCm));
      YCm := XCm;
    end;
    CollapseMasks[I * C + 0] := Byte(XCm);
    CollapseMasks[I * C + C - 1] := Byte(YCm);
    Balance := Balance + Pulses[I] + Tell;
    UpdateLowband := B > (N shl BITRES);
    Ctx.AvoidSplitNoise := False;
  end;
  Seed := Ctx.Seed;
end;

end.
