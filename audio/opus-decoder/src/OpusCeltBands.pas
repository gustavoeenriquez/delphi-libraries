unit OpusCeltBands;

{
  OpusCeltBands.pas - CELT band decoding: energy unquantisation, bit
  allocation and PVQ band decoding (decoder paths only).

  Ported from libopus 1.5.2 celt/quant_bands.c, celt/rate.c and celt/bands.c
  (float build). Copyright (c) 2007-2011 Xiph.Org Foundation, Jean-Marc Valin,
  Timothy B. Terriberry; BSD license.

  License of this unit: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  SysUtils, Math,
  OpusEntDec,
  OpusCeltTables,
  OpusCeltMath;

const
  MAX_FINE_BITS           = 8;
  FINE_OFFSET             = 21;
  QTHETA_OFFSET           = 4;
  QTHETA_OFFSET_TWOPHASE  = 16;
  ALLOC_STEPS             = 6;
  LOG_MAX_PSEUDO          = 6;
  CELT_DB_MINUS28         = -28.0;

type
  TIntArray  = TArray<Integer>;
  TByteArray = TArray<Byte>;

function  GetPulses(I: Integer): Integer; inline;
function  Bits2Pulses(Band, LM, Bits: Integer): Integer;
function  Pulses2Bits(Band, LM, Pulses: Integer): Integer;
procedure InitCaps(var Cap: TIntArray; LM, C: Integer);

// Energy
procedure UnquantCoarseEnergy(StartB, EndB: Integer; OldEBands: PSingle;
  Intra: Integer; var Rd: TEcDec; C, LM: Integer);
procedure UnquantFineEnergy(StartB, EndB: Integer; OldEBands: PSingle;
  const FineQuant: TIntArray; var Rd: TEcDec; C: Integer);
procedure UnquantEnergyFinalise(StartB, EndB: Integer; OldEBands: PSingle;
  const FineQuant, FinePriority: TIntArray; BitsLeft: Integer; var Rd: TEcDec; C: Integer);

// Allocation (decode side)
function CltComputeAllocation(StartB, EndB: Integer; const Offsets, Cap: TIntArray;
  AllocTrim: Integer; var Intensity, DualStereo: Integer; Total: Integer;
  out Balance: Integer; var Pulses, EBits, FinePriority: TIntArray;
  C, LM: Integer; var Rd: TEcDec): Integer;

// Bands
procedure QuantAllBands(StartB, EndB: Integer; X_, Y_: PSingle;
  CollapseMasks: PByte; const Pulses: TIntArray; ShortBlocks, Spread,
  DualStereo, Intensity: Integer; const TfRes: TIntArray; TotalBits,
  Balance: Integer; var Rd: TEcDec; LM, CodedBands: Integer;
  var Seed: Cardinal; DisableInv: Boolean);

procedure AntiCollapse(X_: PSingle; CollapseMasks: PByte; LM, C, Size,
  StartB, EndB: Integer; LogE, Prev1LogE, Prev2LogE: PSingle;
  const Pulses: TIntArray; Seed: Cardinal);

procedure DenormaliseBands(X: PSingle; Freq: PSingle; BandLogE: PSingle;
  StartB, EndB, M, Downsample: Integer; Silence: Boolean);

implementation

// ---------------------------------------------------------------------------
// rate.h helpers
// ---------------------------------------------------------------------------

function GetPulses(I: Integer): Integer;
begin
  if I < 8 then Result := I
  else Result := (8 + (I and 7)) shl ((I shr 3) - 1);
end;

function Bits2Pulses(Band, LM, Bits: Integer): Integer;
var
  I, Lo, Hi, Mid: Integer;
  Cache: PByte;
begin
  Inc(LM);
  Cache := @CELT_CACHE_BITS50[CELT_CACHE_INDEX50[LM * CELT_NB_EBANDS + Band]];
  Lo := 0;
  Hi := Cache[0];
  Dec(Bits);
  for I := 0 to LOG_MAX_PSEUDO - 1 do
  begin
    Mid := (Lo + Hi + 1) shr 1;
    if Integer(Cache[Mid]) >= Bits then Hi := Mid
    else Lo := Mid;
  end;
  if Lo = 0 then I := -1 else I := Cache[Lo];
  if Bits - I <= Integer(Cache[Hi]) - Bits then Result := Lo
  else Result := Hi;
end;

function Pulses2Bits(Band, LM, Pulses: Integer): Integer;
var
  Cache: PByte;
begin
  Inc(LM);
  Cache := @CELT_CACHE_BITS50[CELT_CACHE_INDEX50[LM * CELT_NB_EBANDS + Band]];
  if Pulses = 0 then Result := 0
  else Result := Cache[Pulses] + 1;
end;

procedure InitCaps(var Cap: TIntArray; LM, C: Integer);
var
  I, N: Integer;
begin
  SetLength(Cap, CELT_NB_EBANDS);
  for I := 0 to CELT_NB_EBANDS - 1 do
  begin
    N := (CELT_EBANDS[I + 1] - CELT_EBANDS[I]) shl LM;
    Cap[I] := (CELT_CACHE_CAPS50[CELT_NB_EBANDS * (2 * LM + C - 1) + I] + 64) * C * N shr 2;
  end;
end;

// ---------------------------------------------------------------------------
// quant_bands.c (decoder)
// ---------------------------------------------------------------------------

const
  PRED_COEF: array[0..3] of Single = (29440/32768, 26112/32768, 21248/32768, 16384/32768);
  BETA_COEF: array[0..3] of Single = (30147/32768, 22282/32768, 12124/32768, 6554/32768);
  BETA_INTRA: Single = 4915/32768;
  SMALL_ENERGY_ICDF: array[0..2] of Byte = (2, 1, 0);

procedure UnquantCoarseEnergy(StartB, EndB: Integer; OldEBands: PSingle;
  Intra: Integer; var Rd: TEcDec; C, LM: Integer);
var
  ProbModel: PByte;
  I, Ch    : Integer;
  Prev     : array[0..1] of Single;
  Coef, Beta: Single;
  Budget, Tell: Integer;
  Qi, Pi   : Integer;
  Q, Tmp   : Single;
begin
  ProbModel := @CELT_E_PROB_MODEL[(LM * 2 + Intra) * 42];
  Prev[0] := 0; Prev[1] := 0;
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
  Budget := Rd.Storage * 8;
  for I := StartB to EndB - 1 do
  begin
    for Ch := 0 to C - 1 do
    begin
      Tell := EcTell(Rd);
      if Budget - Tell >= 15 then
      begin
        Pi := 2 * Min(I, 20);
        Qi := EcLaplaceDecode(Rd, Cardinal(ProbModel[Pi]) shl 7, Integer(ProbModel[Pi + 1]) shl 6);
      end
      else if Budget - Tell >= 2 then
      begin
        Qi := EcDecIcdf(Rd, @SMALL_ENERGY_ICDF[0], 2);
        Qi := (Qi shr 1) xor (-(Qi and 1));
      end
      else if Budget - Tell >= 1 then
        Qi := -EcDecBitLogp(Rd, 1)
      else
        Qi := -1;
      Q := Qi;
      OldEBands[I + Ch * CELT_NB_EBANDS] := Max(-9.0, OldEBands[I + Ch * CELT_NB_EBANDS]);
      Tmp := Coef * OldEBands[I + Ch * CELT_NB_EBANDS] + Prev[Ch] + Q;
      OldEBands[I + Ch * CELT_NB_EBANDS] := Tmp;
      Prev[Ch] := Prev[Ch] + Q - Beta * Q;
    end;
  end;
end;

procedure UnquantFineEnergy(StartB, EndB: Integer; OldEBands: PSingle;
  const FineQuant: TIntArray; var Rd: TEcDec; C: Integer);
var
  I, Ch, Q2: Integer;
  Offset   : Single;
begin
  for I := StartB to EndB - 1 do
  begin
    if FineQuant[I] <= 0 then Continue;
    for Ch := 0 to C - 1 do
    begin
      Q2 := EcDecBits(Rd, FineQuant[I]);
      Offset := (Q2 + 0.5) * (1 shl (14 - FineQuant[I])) * (1.0 / 16384) - 0.5;
      OldEBands[I + Ch * CELT_NB_EBANDS] := OldEBands[I + Ch * CELT_NB_EBANDS] + Offset;
    end;
  end;
end;

procedure UnquantEnergyFinalise(StartB, EndB: Integer; OldEBands: PSingle;
  const FineQuant, FinePriority: TIntArray; BitsLeft: Integer; var Rd: TEcDec; C: Integer);
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
        Q2 := EcDecBits(Rd, 1);
        Offset := (Q2 - 0.5) * (1 shl (14 - FineQuant[I] - 1)) * (1.0 / 16384);
        OldEBands[I + Ch * CELT_NB_EBANDS] := OldEBands[I + Ch * CELT_NB_EBANDS] + Offset;
        Dec(BitsLeft);
      end;
      Inc(I);
    end;
  end;
end;

// ---------------------------------------------------------------------------
// rate.c (decoder)
// ---------------------------------------------------------------------------

const
  LOG2_FRAC_TABLE: array[0..23] of Byte = (
    0,
    8, 13,
    16, 19, 21, 23,
    24, 26, 27, 28, 29, 30, 31, 32,
    32, 33, 34, 34, 35, 36, 36, 37, 37);

function InterpBits2Pulses(StartB, EndB, SkipStart: Integer;
  const Bits1, Bits2, Thresh, Cap: TIntArray; Total: Integer; out Balance: Integer;
  SkipRsv: Integer; var Intensity: Integer; IntensityRsv: Integer;
  var DualStereo: Integer; DualStereoRsv: Integer; var Bits, EBits, FinePriority: TIntArray;
  C, LM: Integer; var Rd: TEcDec): Integer;
var
  Psum, Lo, Hi, I, J, Mid, Tmp: Integer;
  LogM, Stereo, CodedBands, AllocFloor: Integer;
  Left, PerCoeff, Done, Bal: Integer;
  BandWidth, BandBits, Rem: Integer;
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

  // Decide which bands to skip, working backwards from the end
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
    PerCoeff := Left div (CELT_EBANDS[CodedBands] - CELT_EBANDS[StartB]);
    Left := Left - (CELT_EBANDS[CodedBands] - CELT_EBANDS[StartB]) * PerCoeff;
    Rem := Max(Left - (CELT_EBANDS[J] - CELT_EBANDS[StartB]), 0);
    BandWidth := CELT_EBANDS[CodedBands] - CELT_EBANDS[J];
    BandBits := Bits[J] + PerCoeff * BandWidth + Rem;
    if BandBits >= Max(Thresh[J], AllocFloor + (1 shl BITRES)) then
    begin
      if EcDecBitLogp(Rd, 1) <> 0 then
        Break;
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
    Intensity := StartB + Integer(EcDecUInt(Rd, CodedBands + 1 - StartB))
  else
    Intensity := 0;
  if Intensity <= StartB then
  begin
    Total := Total + DualStereoRsv;
    DualStereoRsv := 0;
  end;
  if DualStereoRsv > 0 then
    DualStereo := EcDecBitLogp(Rd, 1)
  else
    DualStereo := 0;

  // Allocate the remaining bits
  Left := Total - Psum;
  PerCoeff := Left div (CELT_EBANDS[CodedBands] - CELT_EBANDS[StartB]);
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
      EBits[J] := (EBits[J] div Den) shr BITRES;
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

function CltComputeAllocation(StartB, EndB: Integer; const Offsets, Cap: TIntArray;
  AllocTrim: Integer; var Intensity, DualStereo: Integer; Total: Integer;
  out Balance: Integer; var Pulses, EBits, FinePriority: TIntArray;
  C, LM: Integer; var Rd: TEcDec): Integer;
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
    TrimOffset[J] := C * (CELT_EBANDS[J + 1] - CELT_EBANDS[J]) * (AllocTrim - 5 - LM) * (EndB - J - 1)
                     * (1 shl (LM + BITRES)) shr 6;
    // (arithmetic shift of a possibly negative value)
    if C * (CELT_EBANDS[J + 1] - CELT_EBANDS[J]) * (AllocTrim - 5 - LM) * (EndB - J - 1) * (1 shl (LM + BITRES)) < 0 then
      TrimOffset[J] := -((-(C * (CELT_EBANDS[J + 1] - CELT_EBANDS[J]) * (AllocTrim - 5 - LM) * (EndB - J - 1) * (1 shl (LM + BITRES))) + 63) shr 6);
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
  Result := InterpBits2Pulses(StartB, EndB, SkipStart, Bits1, Bits2, Thresh, Cap,
    Total, Balance, SkipRsv, Intensity, IntensityRsv, DualStereo, DualStereoRsv,
    Pulses, EBits, FinePriority, C, LM, Rd);
end;

// ---------------------------------------------------------------------------
// bands.c (decoder)
// ---------------------------------------------------------------------------

procedure DenormaliseBands(X: PSingle; Freq: PSingle; BandLogE: PSingle;
  StartB, EndB, M, Downsample: Integer; Silence: Boolean);
var
  I, J, N, Bound, BandEnd: Integer;
  G, Lg: Single;
  F: PSingle;
  Xp: PSingle;
begin
  N := M * CELT_SHORT_MDCT;
  Bound := M * CELT_EBANDS[EndB];
  if Downsample <> 1 then
    Bound := Min(Bound, N div Downsample);
  if Silence then
  begin
    Bound := 0;
    StartB := 0;
    EndB := 0;
  end;
  F := Freq;
  Xp := X + M * CELT_EBANDS[StartB];
  for I := 0 to M * CELT_EBANDS[StartB] - 1 do
  begin
    F^ := 0;
    Inc(F);
  end;
  for I := StartB to EndB - 1 do
  begin
    J := M * CELT_EBANDS[I];
    BandEnd := M * CELT_EBANDS[I + 1];
    Lg := BandLogE[I] + CELT_EMEANS[I];
    G := CeltExp2(Min(32.0, Lg));
    while J < BandEnd do
    begin
      F^ := Xp^ * G;
      Inc(F); Inc(Xp);
      Inc(J);
    end;
  end;
  for I := Bound to N - 1 do
    Freq[I] := 0;
end;

procedure AntiCollapse(X_: PSingle; CollapseMasks: PByte; LM, C, Size,
  StartB, EndB: Integer; LogE, Prev1LogE, Prev2LogE: PSingle;
  const Pulses: TIntArray; Seed: Cardinal);
var
  I, J, K, Ch, N0, Depth: Integer;
  Thresh, Sqrt1: Single;
  Prev1, Prev2, Ediff, R: Single;
  X: PSingle;
  Renormalize: Boolean;
begin
  for I := StartB to EndB - 1 do
  begin
    N0 := CELT_EBANDS[I + 1] - CELT_EBANDS[I];
    Depth := ((1 + Pulses[I]) div (CELT_EBANDS[I + 1] - CELT_EBANDS[I])) shr LM;
    Thresh := 0.5 * CeltExp2(-0.125 * Depth);
    Sqrt1 := 1.0 / Sqrt(N0 shl LM);
    for Ch := 0 to C - 1 do
    begin
      Prev1 := Prev1LogE[Ch * CELT_NB_EBANDS + I];
      Prev2 := Prev2LogE[Ch * CELT_NB_EBANDS + I];
      if C = 1 then
      begin
        Prev1 := Max(Prev1, Prev1LogE[CELT_NB_EBANDS + I]);
        Prev2 := Max(Prev2, Prev2LogE[CELT_NB_EBANDS + I]);
      end;
      Ediff := LogE[Ch * CELT_NB_EBANDS + I] - Min(Prev1, Prev2);
      Ediff := Max(0, Ediff);
      R := 2.0 * CeltExp2(-Ediff);
      if LM = 3 then R := R * 1.41421356;
      R := Min(Thresh, R);
      R := R * Sqrt1;
      X := X_ + Ch * Size + (CELT_EBANDS[I] shl LM);
      Renormalize := False;
      for K := 0 to (1 shl LM) - 1 do
      begin
        if (CollapseMasks[I * C + Ch] and (1 shl K)) = 0 then
        begin
          for J := 0 to N0 - 1 do
          begin
            Seed := CeltLcgRand(Seed);
            if (Seed and $8000) <> 0 then X[(J shl LM) + K] := R
            else X[(J shl LM) + K] := -R;
          end;
          Renormalize := True;
        end;
      end;
      if Renormalize then
        RenormaliseVector(X, N0 shl LM, 1.0);
    end;
  end;
end;

procedure StereoMerge(X, Y: PSingle; Mid: Single; N: Integer);
var
  J: Integer;
  Xp, Side, El, Er: Single;
  Mid2, LGain, RGain, L, R: Single;
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
  if (Er < 6e-4) or (El < 6e-4) then
  begin
    Move(X^, Y^, N * SizeOf(Single));
    Exit;
  end;
  LGain := 1.0 / Sqrt(El);
  RGain := 1.0 / Sqrt(Er);
  for J := 0 to N - 1 do
  begin
    L := Mid * X[J];
    R := Y[J];
    X[J] := LGain * (L - R);
    Y[J] := RGain * (L + R);
  end;
end;

function ComputeQn(N, B, Offset, PulseCap: Integer; Stereo: Boolean): Integer;
const
  EXP2_TABLE8: array[0..7] of Integer = (16384, 17866, 19483, 21247, 23170, 25267, 27554, 30048);
var
  Qn, Qb, N2: Integer;
begin
  N2 := 2 * N - 1;
  if Stereo and (N = 2) then Dec(N2);
  Qb := (B + N2 * Offset) div N2;   // celt_sudiv: truncates toward zero
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

type
  TBandCtx = record
    I            : Integer;
    Intensity    : Integer;
    Spread       : Integer;
    TfChange     : Integer;
    Rd          : ^TEcDec;
    RemainingBits: Integer;
    Seed         : Cardinal;
    DisableInv   : Boolean;
    AvoidSplitNoise: Boolean;
  end;

  TSplitCtx = record
    Inv    : Integer;
    IMid   : Integer;
    ISide  : Integer;
    Delta  : Integer;
    ITheta : Integer;
    QAlloc : Integer;
  end;

procedure ComputeTheta(var Ctx: TBandCtx; out SCtx: TSplitCtx; X, Y: PSingle;
  N: Integer; var B: Integer; BB, B0, LM: Integer; Stereo: Boolean; var Fill: Integer);
var
  Qn, ITheta, Delta, IMid, ISide, QAlloc, PulseCap, Offset: Integer;
  Tell: Integer;
  Inv: Integer;
  P0, X0, Ft, Fs, Fl, Fm, XX: Integer;
begin
  Inv := 0;
  ITheta := 0;
  PulseCap := CELT_LOGN400[Ctx.I] + LM * (1 shl BITRES);
  if Stereo and (N = 2) then Offset := (PulseCap shr 1) - QTHETA_OFFSET_TWOPHASE
  else Offset := (PulseCap shr 1) - QTHETA_OFFSET;
  Qn := ComputeQn(N, B, Offset, PulseCap, Stereo);
  if Stereo and (Ctx.I >= Ctx.Intensity) then Qn := 1;
  Tell := EcTellFrac(Ctx.Rd^);
  if Qn <> 1 then
  begin
    if Stereo and (N > 2) then
    begin
      P0 := 3;
      X0 := Qn div 2;
      Ft := P0 * (X0 + 1) + X0;
      Fs := EcDecode(Ctx.Rd^, Ft);
      if Fs < (X0 + 1) * P0 then XX := Fs div P0
      else XX := X0 + 1 + (Fs - (X0 + 1) * P0);
      if XX <= X0 then
        EcDecUpdate(Ctx.Rd^, P0 * XX, P0 * (XX + 1), Ft)
      else
        EcDecUpdate(Ctx.Rd^, (XX - 1 - X0) + (X0 + 1) * P0, (XX - X0) + (X0 + 1) * P0, Ft);
      ITheta := XX;
    end
    else if (B0 > 1) or Stereo then
      ITheta := EcDecUInt(Ctx.Rd^, Qn + 1)
    else
    begin
      // Triangular pdf
      Ft := ((Qn shr 1) + 1) * ((Qn shr 1) + 1);
      Fm := EcDecode(Ctx.Rd^, Ft);
      if Fm < ((Qn shr 1) * ((Qn shr 1) + 1) shr 1) then
      begin
        ITheta := (Integer(ISqrt32(8 * Cardinal(Fm) + 1)) - 1) shr 1;
        Fs := ITheta + 1;
        Fl := ITheta * (ITheta + 1) shr 1;
      end
      else
      begin
        ITheta := (2 * (Qn + 1) - Integer(ISqrt32(8 * Cardinal(Ft - Fm - 1) + 1))) shr 1;
        Fs := Qn + 1 - ITheta;
        Fl := Ft - ((Qn + 1 - ITheta) * (Qn + 2 - ITheta) shr 1);
      end;
      EcDecUpdate(Ctx.Rd^, Fl, Fl + Fs, Ft);
    end;
    ITheta := (ITheta * 16384) div Qn;
  end
  else if Stereo then
  begin
    if (B > 2 shl BITRES) and (Ctx.RemainingBits > 2 shl BITRES) then
      Inv := EcDecBitLogp(Ctx.Rd^, 2)
    else
      Inv := 0;
    if Ctx.DisableInv then Inv := 0;
    ITheta := 0;
  end;
  QAlloc := Integer(EcTellFrac(Ctx.Rd^)) - Tell;
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

function QuantBandN1(var Ctx: TBandCtx; X, Y: PSingle; LowbandOut: PSingle): Cardinal;
var
  C, Sign: Integer;
  Xp: PSingle;
  Stereo: Integer;
begin
  Stereo := Ord(Y <> nil);
  Xp := X;
  for C := 0 to Stereo do
  begin
    Sign := 0;
    if Ctx.RemainingBits >= 1 shl BITRES then
    begin
      Sign := EcDecBits(Ctx.Rd^, 1);
      Ctx.RemainingBits := Ctx.RemainingBits - (1 shl BITRES);
    end;
    if Sign <> 0 then Xp[0] := -1.0 else Xp[0] := 1.0;
    Xp := Y;
  end;
  if LowbandOut <> nil then
    LowbandOut[0] := X[0];
  Result := 1;
end;

function QuantPartition(var Ctx: TBandCtx; X: PSingle; N, B, BB: Integer;
  Lowband: PSingle; LM: Integer; Gain: Single; Fill: Integer): Cardinal; forward;

function QuantPartition(var Ctx: TBandCtx; X: PSingle; N, B, BB: Integer;
  Lowband: PSingle; LM: Integer; Gain: Single; Fill: Integer): Cardinal;
var
  Cache: PByte;
  Q, CurrBits, IMid, ISide, B0: Integer;
  Mid, Side: Single;
  Cm: Cardinal;
  Y: PSingle;
  MBits, SBits, Delta, ITheta, QAlloc: Integer;
  SCtx: TSplitCtx;
  NextLowband2: PSingle;
  Rebalance: Integer;
  K, J: Integer;
  CmMask: Cardinal;
  Tmp: Single;
begin
  Cm := 0;
  B0 := BB;
  Cache := @CELT_CACHE_BITS50[CELT_CACHE_INDEX50[(LM + 1) * CELT_NB_EBANDS + Ctx.I]];
  if (LM <> -1) and (B > Cache[Cache[0]] + 12) and (N > 2) then
  begin
    N := N shr 1;
    Y := X + N;
    LM := LM - 1;
    if BB = 1 then
      Fill := (Fill and 1) or (Fill shl 1);
    BB := (BB + 1) shr 1;
    ComputeTheta(Ctx, SCtx, X, Y, N, B, BB, B0, LM, False, Fill);
    IMid := SCtx.IMid;
    ISide := SCtx.ISide;
    Delta := SCtx.Delta;
    ITheta := SCtx.ITheta;
    QAlloc := SCtx.QAlloc;
    Mid := (1.0 / 32768) * IMid;
    Side := (1.0 / 32768) * ISide;
    if (B0 > 1) and ((ITheta and $3FFF) <> 0) then
    begin
      if ITheta > 8192 then
        Delta := Delta - (Delta div (1 shl (4 - LM)))   // delta>>(4-LM) with arithmetic shift
      else
        Delta := Min(0, Delta + (N shl BITRES shr (5 - LM)));
    end;
    if (B0 > 1) and ((ITheta and $3FFF) <> 0) and (ITheta > 8192) then
    begin
      // redo with exact arithmetic shift semantics (floor division)
      Delta := SCtx.Delta;
      if Delta >= 0 then Delta := Delta - (Delta shr (4 - LM))
      else Delta := Delta + (((-Delta) + (1 shl (4 - LM)) - 1) shr (4 - LM));
    end;
    MBits := Max(0, Min(B, (B - Delta) div 2));
    SBits := B - MBits;
    Ctx.RemainingBits := Ctx.RemainingBits - QAlloc;
    if Lowband <> nil then NextLowband2 := Lowband + N
    else NextLowband2 := nil;
    Rebalance := Ctx.RemainingBits;
    if MBits >= SBits then
    begin
      Cm := QuantPartition(Ctx, X, N, MBits, BB, Lowband, LM, Gain * Mid, Fill);
      Rebalance := MBits - (Rebalance - Ctx.RemainingBits);
      if (Rebalance > 3 shl BITRES) and (ITheta <> 0) then
        SBits := SBits + (Rebalance - (3 shl BITRES));
      Cm := Cm or (QuantPartition(Ctx, Y, N, SBits, BB, NextLowband2, LM, Gain * Side, Fill shr BB) shl (B0 shr 1));
    end
    else
    begin
      Cm := QuantPartition(Ctx, Y, N, SBits, BB, NextLowband2, LM, Gain * Side, Fill shr BB) shl (B0 shr 1);
      Rebalance := SBits - (Rebalance - Ctx.RemainingBits);
      if (Rebalance > 3 shl BITRES) and (ITheta <> 16384) then
        MBits := MBits + (Rebalance - (3 shl BITRES));
      Cm := Cm or QuantPartition(Ctx, X, N, MBits, BB, Lowband, LM, Gain * Mid, Fill);
    end;
  end
  else
  begin
    // Basic no-split case
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
      Cm := AlgUnquant(X, N, K, Ctx.Spread, BB, Ctx.Rd^, Gain);
    end
    else
    begin
      CmMask := (Cardinal(1) shl BB) - 1;
      Fill := Fill and Integer(CmMask);
      if Fill = 0 then
      begin
        for J := 0 to N - 1 do X[J] := 0;
      end
      else
      begin
        if Lowband = nil then
        begin
          for J := 0 to N - 1 do
          begin
            Ctx.Seed := CeltLcgRand(Ctx.Seed);
            X[J] := Integer(Ctx.Seed) div (1 shl 20);   // (opus_int32)seed>>20
            if Integer(Ctx.Seed) < 0 then
              X[J] := -((-Integer(Ctx.Seed) + (1 shl 20) - 1) shr 20);
          end;
          Cm := CmMask;
        end
        else
        begin
          for J := 0 to N - 1 do
          begin
            Ctx.Seed := CeltLcgRand(Ctx.Seed);
            Tmp := 1.0 / 256;
            if (Ctx.Seed and $8000) = 0 then Tmp := -Tmp;
            X[J] := Lowband[J] + Tmp;
          end;
          Cm := Cardinal(Fill);
        end;
        RenormaliseVector(X, N, Gain);
      end;
    end;
  end;
  Result := Cm;
end;

function QuantBand(var Ctx: TBandCtx; X: PSingle; N, B, BB: Integer;
  Lowband: PSingle; LM: Integer; LowbandOut: PSingle; Gain: Single;
  LowbandScratch: PSingle; Fill: Integer): Cardinal;
const
  BIT_INTERLEAVE_TABLE: array[0..15] of Byte = (0,1,1,1,2,3,3,3,2,3,3,3,2,3,3,3);
  BIT_DEINTERLEAVE_TABLE: array[0..15] of Byte = (
    $00,$03,$0C,$0F,$30,$33,$3C,$3F,$C0,$C3,$CC,$CF,$F0,$F3,$FC,$FF);
var
  N0, N_B, N_B0, B0, TimeDivide, Recombine, K, J: Integer;
  LongBlocks: Boolean;
  Cm: Cardinal;
  TfChange: Integer;
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
    Exit(QuantBandN1(Ctx, X, nil, LowbandOut));

  if TfChange > 0 then Recombine := TfChange;

  if (LowbandScratch <> nil) and (Lowband <> nil) and
     ((Recombine <> 0) or (((N_B and 1) = 0) and (TfChange < 0)) or (B0 > 1)) then
  begin
    Move(Lowband^, LowbandScratch^, N * SizeOf(Single));
    Lowband := LowbandScratch;
  end;

  for K := 0 to Recombine - 1 do
  begin
    if Lowband <> nil then
      Haar1(Lowband, N shr K, 1 shl K);
    Fill := BIT_INTERLEAVE_TABLE[Fill and $F] or (BIT_INTERLEAVE_TABLE[Fill shr 4] shl 2);
  end;
  BB := BB shr Recombine;
  N_B := N_B shl Recombine;

  while ((N_B and 1) = 0) and (TfChange < 0) do
  begin
    if Lowband <> nil then
      Haar1(Lowband, N_B, BB);
    Fill := Fill or (Fill shl BB);
    BB := BB shl 1;
    N_B := N_B shr 1;
    Inc(TimeDivide);
    Inc(TfChange);
  end;
  B0 := BB;
  N_B0 := N_B;

  if B0 > 1 then
    if Lowband <> nil then
      DeinterleaveHadamard(Lowband, N_B shr Recombine, B0 shl Recombine, LongBlocks);

  Cm := QuantPartition(Ctx, X, N, B, BB, Lowband, LM, Gain, Fill);

  // Resynthesis
  if B0 > 1 then
    InterleaveHadamard(X, N_B shr Recombine, B0 shl Recombine, LongBlocks);

  N_B := N_B0;
  BB := B0;
  for K := 0 to TimeDivide - 1 do
  begin
    BB := BB shr 1;
    N_B := N_B shl 1;
    Cm := Cm or (Cm shr BB);
    Haar1(X, N_B, BB);
  end;

  for K := 0 to Recombine - 1 do
  begin
    Cm := BIT_DEINTERLEAVE_TABLE[Cm];
    Haar1(X, N0 shr K, 1 shl K);
  end;
  BB := BB shl Recombine;

  if LowbandOut <> nil then
  begin
    Nrm := Sqrt(N0);
    for J := 0 to N0 - 1 do
      LowbandOut[J] := Nrm * X[J];
  end;
  Cm := Cm and ((Cardinal(1) shl BB) - 1);
  Result := Cm;
end;

function QuantBandStereo(var Ctx: TBandCtx; X, Y: PSingle; N, B, BB: Integer;
  Lowband: PSingle; LM: Integer; LowbandOut: PSingle; LowbandScratch: PSingle;
  Fill: Integer): Cardinal;
var
  IMid, ISide, Inv: Integer;
  Mid, Side: Single;
  Cm: Cardinal;
  MBits, SBits, Delta, ITheta, QAlloc: Integer;
  SCtx: TSplitCtx;
  OrigFill: Integer;
  C, Sign, J: Integer;
  X2, Y2: PSingle;
  Tmp: Single;
  Rebalance: Integer;
begin
  Cm := 0;
  if N = 1 then
    Exit(QuantBandN1(Ctx, X, Y, LowbandOut));
  OrigFill := Fill;
  ComputeTheta(Ctx, SCtx, X, Y, N, B, BB, BB, LM, True, Fill);
  Inv := SCtx.Inv;
  IMid := SCtx.IMid;
  ISide := SCtx.ISide;
  Delta := SCtx.Delta;
  ITheta := SCtx.ITheta;
  QAlloc := SCtx.QAlloc;
  Mid := (1.0 / 32768) * IMid;
  Side := (1.0 / 32768) * ISide;

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
      Sign := EcDecBits(Ctx.Rd^, 1);
    Sign := 1 - 2 * Sign;
    Cm := QuantBand(Ctx, X2, N, MBits, BB, Lowband, LM, LowbandOut, 1.0, LowbandScratch, OrigFill);
    Y2[0] := -Sign * X2[1];
    Y2[1] := Sign * X2[0];
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
  end
  else
  begin
    MBits := Max(0, Min(B, (B - Delta) div 2));
    SBits := B - MBits;
    Ctx.RemainingBits := Ctx.RemainingBits - QAlloc;
    Rebalance := Ctx.RemainingBits;
    if MBits >= SBits then
    begin
      Cm := QuantBand(Ctx, X, N, MBits, BB, Lowband, LM, LowbandOut, 1.0, LowbandScratch, Fill);
      Rebalance := MBits - (Rebalance - Ctx.RemainingBits);
      if (Rebalance > 3 shl BITRES) and (ITheta <> 0) then
        SBits := SBits + (Rebalance - (3 shl BITRES));
      Cm := Cm or QuantBand(Ctx, Y, N, SBits, BB, nil, LM, nil, Side, nil, Fill shr BB);
    end
    else
    begin
      Cm := QuantBand(Ctx, Y, N, SBits, BB, nil, LM, nil, Side, nil, Fill shr BB);
      Rebalance := SBits - (Rebalance - Ctx.RemainingBits);
      if (Rebalance > 3 shl BITRES) and (ITheta <> 16384) then
        MBits := MBits + (Rebalance - (3 shl BITRES));
      Cm := Cm or QuantBand(Ctx, X, N, MBits, BB, Lowband, LM, LowbandOut, 1.0, LowbandScratch, Fill);
    end;
  end;

  // Resynthesis
  if N <> 2 then
    StereoMerge(X, Y, Mid, N);
  if Inv <> 0 then
    for J := 0 to N - 1 do
      Y[J] := -Y[J];
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

procedure QuantAllBands(StartB, EndB: Integer; X_, Y_: PSingle;
  CollapseMasks: PByte; const Pulses: TIntArray; ShortBlocks, Spread,
  DualStereo, Intensity: Integer; const TfRes: TIntArray; TotalBits,
  Balance: Integer; var Rd: TEcDec; LM, CodedBands: Integer;
  var Seed: Cardinal; DisableInv: Boolean);
var
  I, J: Integer;
  RemainingBits: Integer;
  NormBuf: TArray<Single>;
  Norm, Norm2: PSingle;
  LowbandScratch: PSingle;
  BB, M, LowbandOffset, NormOffset: Integer;
  UpdateLowband: Boolean;
  C: Integer;
  Ctx: TBandCtx;
  Tell, B, N, CurrBalance, EffectiveLowband: Integer;
  X, Y: PSingle;
  TfChange: Integer;
  XCm, YCm: Cardinal;
  Last: Boolean;
  FoldStart, FoldEnd, FoldI: Integer;
  LowbandPtr, LowbandOutPtr: PSingle;
begin
  M := 1 shl LM;
  if ShortBlocks <> 0 then BB := M else BB := 1;
  NormOffset := M * CELT_EBANDS[StartB];
  if Y_ <> nil then C := 2 else C := 1;
  SetLength(NormBuf, C * (M * CELT_EBANDS[CELT_NB_EBANDS - 1] - NormOffset) + 1);
  Norm := @NormBuf[0];
  Norm2 := Norm + (M * CELT_EBANDS[CELT_NB_EBANDS - 1] - NormOffset);
  LowbandScratch := X_ + M * CELT_EBANDS[CELT_NB_EBANDS - 1];
  LowbandOffset := 0;
  UpdateLowband := True;
  Ctx.Rd := @Rd;
  Ctx.Intensity := Intensity;
  Ctx.Seed := Seed;
  Ctx.Spread := Spread;
  Ctx.DisableInv := DisableInv;
  Ctx.AvoidSplitNoise := BB > 1;
  for I := StartB to EndB - 1 do
  begin
    Ctx.I := I;
    Last := I = EndB - 1;
    X := X_ + M * CELT_EBANDS[I];
    if Y_ <> nil then Y := Y_ + M * CELT_EBANDS[I] else Y := nil;
    N := M * CELT_EBANDS[I + 1] - M * CELT_EBANDS[I];
    Tell := EcTellFrac(Rd);
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

    if ((M * CELT_EBANDS[I] - N >= M * CELT_EBANDS[StartB]) or (I = StartB + 1)) and
       (UpdateLowband or (LowbandOffset = 0)) then
      LowbandOffset := I;
    if I = StartB + 1 then
      SpecialHybridFolding(Norm, Norm2, StartB, M, DualStereo);

    TfChange := TfRes[I];
    Ctx.TfChange := TfChange;
    if I >= CELT_NB_EBANDS then  // effEBands = nbEBands for this mode
    begin
      X := Norm;
      if Y_ <> nil then Y := Norm;
      LowbandScratch := nil;
    end;
    if Last then
      LowbandScratch := nil;

    EffectiveLowband := -1;
    if (LowbandOffset <> 0) and ((Spread <> SPREAD_AGGRESSIVE) or (BB > 1) or (TfChange < 0)) then
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
      for J := 0 to M * CELT_EBANDS[I] - NormOffset - 1 do
        Norm[J] := 0.5 * (Norm[J] + Norm2[J]);
    end;

    if EffectiveLowband <> -1 then LowbandPtr := Norm + EffectiveLowband else LowbandPtr := nil;
    if Last then LowbandOutPtr := nil else LowbandOutPtr := Norm + M * CELT_EBANDS[I] - NormOffset;

    if DualStereo <> 0 then
    begin
      XCm := QuantBand(Ctx, X, N, B div 2, BB, LowbandPtr, LM, LowbandOutPtr, 1.0, LowbandScratch, Integer(XCm));
      if EffectiveLowband <> -1 then LowbandPtr := Norm2 + EffectiveLowband else LowbandPtr := nil;
      if Last then LowbandOutPtr := nil else LowbandOutPtr := Norm2 + M * CELT_EBANDS[I] - NormOffset;
      YCm := QuantBand(Ctx, Y, N, B div 2, BB, LowbandPtr, LM, LowbandOutPtr, 1.0, LowbandScratch, Integer(YCm));
    end
    else
    begin
      if Y <> nil then
        XCm := QuantBandStereo(Ctx, X, Y, N, B, BB, LowbandPtr, LM, LowbandOutPtr, LowbandScratch, Integer(XCm or YCm))
      else
        XCm := QuantBand(Ctx, X, N, B, BB, LowbandPtr, LM, LowbandOutPtr, 1.0, LowbandScratch, Integer(XCm or YCm));
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
