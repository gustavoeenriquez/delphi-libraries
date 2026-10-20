unit OpusCelt;

{
  OpusCelt.pas - CELT decoder (RFC 6716 section 4.3), 48 kHz / 960 mode

  Port of libopus 1.5.2 celt/celt_decoder.c (float build) without the
  pitch-based packet loss concealment: lost frames use the noise-based
  concealment path only. Copyright (c) 2007-2011 Xiph.Org Foundation,
  Jean-Marc Valin, Timothy B. Terriberry; BSD license.

  Output: planar float at 48 kHz, nominal range [-1, 1].

  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  SysUtils, Math,
  OpusEntDec,
  OpusCeltTables,
  OpusCeltMath,
  OpusCeltBands;

const
  CELT_DECODE_BUFFER_SIZE = 2048;
  CELT_SIG_SCALE          = 32768.0;
  CELT_FRAME_120          = 120;

type
  PEcDec = ^TEcDec;

  TCeltDecoder = class
  private
    FChannels       : Integer;   // output channels (CC)
    FStreamChannels : Integer;   // coded channels (C)
    FStart, FEnd    : Integer;
    FDisableInv     : Boolean;
    FRng            : Cardinal;
    FError          : Integer;
    FLossDuration   : Integer;
    FSkipPlc        : Boolean;
    FPostfilterPeriod, FPostfilterPeriodOld: Integer;
    FPostfilterGain, FPostfilterGainOld: Single;
    FPostfilterTapset, FPostfilterTapsetOld: Integer;
    FPrefilterAndFold: Boolean;
    FPreemphMemD    : array[0..1] of Single;
    FDecodeMem      : array[0..1] of TArray<Single>;   // DECODE_BUFFER_SIZE + overlap
    FOldEBands      : TArray<Single>;   // 2 * nbEBands
    FOldLogE        : TArray<Single>;
    FOldLogE2       : TArray<Single>;
    FBackgroundLogE : TArray<Single>;
    FMdct           : TCeltMdct;
    FFreq           : TArray<Single>;
    FX              : TArray<Single>;
    procedure Synthesis(X: PSingle; OutSyn: array of PSingle; OldBandE: PSingle;
      StartB, EffEnd, C, CC: Integer; IsTransient: Boolean; LM: Integer; Silence: Boolean);
    procedure Deemphasis(InSyn: array of PSingle; const Pcm: array of PSingle; N, C: Integer);
    procedure PrefilterAndFold(N: Integer);
    procedure DecodeLost(N, LM: Integer);
  public
    constructor Create(AChannels: Integer);
    procedure Reset;
    // Decode one CELT frame of FrameSize samples (120/240/480/960) into
    // Pcm[ch][0..FrameSize-1]. Data = nil or Len <= 1 runs concealment.
    // ExtDec: range decoder already positioned (hybrid mode), or nil.
    // Returns the number of samples per channel, or a negative error code.
    function Decode(Data: PByte; Len: Integer; const Pcm: array of PSingle;
      FrameSize: Integer; ExtDec: PEcDec): Integer;
    property StartBand     : Integer read FStart write FStart;
    property EndBand       : Integer read FEnd write FEnd;
    property StreamChannels: Integer read FStreamChannels write FStreamChannels;
    property DisableInv    : Boolean read FDisableInv write FDisableInv;
    property FinalRange    : Cardinal read FRng;
    property Channels      : Integer read FChannels;
  end;

implementation

const
  TF_SELECT_TABLE: array[0..3, 0..7] of ShortInt = (
    (0, -1, 0, -1,    0, -1, 0, -1),
    (0, -1, 0, -2,    1,  0, 1, -1),
    (0, -2, 0, -3,    2,  0, 1, -1),
    (0, -2, 0, -3,    3,  0, 1, -1));
  TRIM_ICDF  : array[0..10] of Byte = (126, 124, 119, 109, 87, 41, 19, 9, 4, 2, 0);
  SPREAD_ICDF: array[0..3] of Byte = (25, 23, 2, 0);
  TAPSET_ICDF: array[0..2] of Byte = (2, 1, 0);

constructor TCeltDecoder.Create(AChannels: Integer);
var
  C: Integer;
begin
  inherited Create;
  FChannels := AChannels;
  FStreamChannels := AChannels;
  FStart := 0;
  FEnd := CELT_NB_EBANDS;
  FDisableInv := AChannels = 1;
  for C := 0 to 1 do
    SetLength(FDecodeMem[C], CELT_DECODE_BUFFER_SIZE + CELT_OVERLAP_SIZE);
  SetLength(FOldEBands, 2 * CELT_NB_EBANDS);
  SetLength(FOldLogE, 2 * CELT_NB_EBANDS);
  SetLength(FOldLogE2, 2 * CELT_NB_EBANDS);
  SetLength(FBackgroundLogE, 2 * CELT_NB_EBANDS);
  SetLength(FFreq, CELT_SHORT_MDCT shl CELT_MAX_LM);
  SetLength(FX, 2 * (CELT_SHORT_MDCT shl CELT_MAX_LM));
  FMdct.Init(2 * (CELT_SHORT_MDCT shl CELT_MAX_LM), CELT_MAX_LM);
  Reset;
end;

procedure TCeltDecoder.Reset;
var
  I, C: Integer;
begin
  FRng := 0;
  FError := 0;
  FLossDuration := 0;
  FSkipPlc := True;
  FPostfilterPeriod := 0;
  FPostfilterPeriodOld := 0;
  FPostfilterGain := 0;
  FPostfilterGainOld := 0;
  FPostfilterTapset := 0;
  FPostfilterTapsetOld := 0;
  FPrefilterAndFold := False;
  FPreemphMemD[0] := 0;
  FPreemphMemD[1] := 0;
  for C := 0 to 1 do
    FillChar(FDecodeMem[C][0], Length(FDecodeMem[C]) * SizeOf(Single), 0);
  for I := 0 to 2 * CELT_NB_EBANDS - 1 do
  begin
    FOldEBands[I] := 0;
    FOldLogE[I] := -28.0;
    FOldLogE2[I] := -28.0;
    FBackgroundLogE[I] := 0;
  end;
end;

// ---------------------------------------------------------------------------

procedure TCeltDecoder.Deemphasis(InSyn: array of PSingle; const Pcm: array of PSingle; N, C: Integer);
var
  Ch, J: Integer;
  M, Tmp: Single;
  X, Y: PSingle;
begin
  for Ch := 0 to C - 1 do
  begin
    M := FPreemphMemD[Ch];
    X := InSyn[Ch];
    Y := Pcm[Ch];
    for J := 0 to N - 1 do
    begin
      Tmp := X[J] + 1e-30 + M;
      M := CELT_PREEMPH * Tmp;
      Y[J] := Tmp * (1.0 / CELT_SIG_SCALE);
    end;
    FPreemphMemD[Ch] := M;
  end;
end;

procedure TCeltDecoder.Synthesis(X: PSingle; OutSyn: array of PSingle; OldBandE: PSingle;
  StartB, EffEnd, C, CC: Integer; IsTransient: Boolean; LM: Integer; Silence: Boolean);
var
  Ch, I, B, BB, NB, N, Shift, M: Integer;
  Freq, Freq2: PSingle;
  Tmp2: TArray<Single>;
begin
  N := CELT_SHORT_MDCT shl LM;
  M := 1 shl LM;
  Freq := @FFreq[0];
  if IsTransient then
  begin
    BB := M;
    NB := CELT_SHORT_MDCT;
    Shift := CELT_MAX_LM;
  end
  else
  begin
    BB := 1;
    NB := CELT_SHORT_MDCT shl LM;
    Shift := CELT_MAX_LM - LM;
  end;
  if (CC = 2) and (C = 1) then
  begin
    DenormaliseBands(X, Freq, OldBandE, StartB, EffEnd, M, 1, Silence);
    SetLength(Tmp2, N);
    Freq2 := @Tmp2[0];
    Move(Freq^, Freq2^, N * SizeOf(Single));
    for B := 0 to BB - 1 do
      FMdct.Backward(Freq2 + B, OutSyn[0] + NB * B, @CELT_WINDOW120[0], CELT_OVERLAP_SIZE, Shift, BB);
    for B := 0 to BB - 1 do
      FMdct.Backward(Freq + B, OutSyn[1] + NB * B, @CELT_WINDOW120[0], CELT_OVERLAP_SIZE, Shift, BB);
  end
  else if (CC = 1) and (C = 2) then
  begin
    SetLength(Tmp2, N);
    Freq2 := @Tmp2[0];
    DenormaliseBands(X, Freq, OldBandE, StartB, EffEnd, M, 1, Silence);
    DenormaliseBands(X + N, Freq2, OldBandE + CELT_NB_EBANDS, StartB, EffEnd, M, 1, Silence);
    for I := 0 to N - 1 do
      Freq[I] := 0.5 * Freq[I] + 0.5 * Freq2[I];
    for B := 0 to BB - 1 do
      FMdct.Backward(Freq + B, OutSyn[0] + NB * B, @CELT_WINDOW120[0], CELT_OVERLAP_SIZE, Shift, BB);
  end
  else
  begin
    for Ch := 0 to CC - 1 do
    begin
      DenormaliseBands(X + Ch * N, Freq, OldBandE + Ch * CELT_NB_EBANDS, StartB, EffEnd, M, 1, Silence);
      for B := 0 to BB - 1 do
        FMdct.Backward(Freq + B, OutSyn[Ch] + NB * B, @CELT_WINDOW120[0], CELT_OVERLAP_SIZE, Shift, BB);
    end;
  end;
  for Ch := 0 to CC - 1 do
    for I := 0 to N - 1 do
    begin
      if OutSyn[Ch][I] > 300000000.0 then OutSyn[Ch][I] := 300000000.0
      else if OutSyn[Ch][I] < -300000000.0 then OutSyn[Ch][I] := -300000000.0;
    end;
end;

procedure TfDecode(StartB, EndB: Integer; IsTransient: Boolean; var TfRes: TIntArray;
  LM: Integer; var Rd: TEcDec);
var
  I, Curr, TfSelect, TfSelectRsv, TfChanged, Logp: Integer;
  Budget, Tell: Cardinal;
  IsT: Integer;
begin
  IsT := Ord(IsTransient);
  Budget := Rd.Storage * 8;
  Tell := EcTell(Rd);
  if IsTransient then Logp := 2 else Logp := 4;
  TfSelectRsv := Ord((LM > 0) and (Tell + Cardinal(Logp) + 1 <= Budget));
  Budget := Budget - Cardinal(TfSelectRsv);
  TfChanged := 0;
  Curr := 0;
  for I := StartB to EndB - 1 do
  begin
    if Tell + Cardinal(Logp) <= Budget then
    begin
      Curr := Curr xor EcDecBitLogp(Rd, Logp);
      Tell := EcTell(Rd);
      TfChanged := TfChanged or Curr;
    end;
    TfRes[I] := Curr;
    if IsTransient then Logp := 4 else Logp := 5;
  end;
  TfSelect := 0;
  if (TfSelectRsv <> 0) and
     (TF_SELECT_TABLE[LM][4 * IsT + 0 + TfChanged] <> TF_SELECT_TABLE[LM][4 * IsT + 2 + TfChanged]) then
    TfSelect := EcDecBitLogp(Rd, 1);
  for I := StartB to EndB - 1 do
    TfRes[I] := TF_SELECT_TABLE[LM][4 * IsT + 2 * TfSelect + TfRes[I]];
end;

procedure TCeltDecoder.PrefilterAndFold(N: Integer);
var
  C, I: Integer;
  Etmp: array[0..CELT_OVERLAP_SIZE - 1] of Single;
  Mem: PSingle;
begin
  for C := 0 to FChannels - 1 do
  begin
    Mem := @FDecodeMem[C][0];
    CombFilter(@Etmp[0], Mem + (CELT_DECODE_BUFFER_SIZE - N),
      FPostfilterPeriodOld, FPostfilterPeriod, CELT_OVERLAP_SIZE,
      -FPostfilterGainOld, -FPostfilterGain,
      FPostfilterTapsetOld, FPostfilterTapset, nil, 0);
    for I := 0 to (CELT_OVERLAP_SIZE div 2) - 1 do
      Mem[CELT_DECODE_BUFFER_SIZE - N + I] :=
        CELT_WINDOW120[I] * Etmp[CELT_OVERLAP_SIZE - 1 - I] +
        CELT_WINDOW120[CELT_OVERLAP_SIZE - I - 1] * Etmp[I];
  end;
end;

procedure TCeltDecoder.DecodeLost(N, LM: Integer);
var
  C, I, J, BOffs, BLen: Integer;
  OutSyn: array[0..1] of PSingle;
  EffEnd: Integer;
  Decay : Single;
  Seed  : Cardinal;
  X     : PSingle;
begin
  // Noise-based concealment (libopus uses pitch-based PLC for short losses;
  // this port always uses the noise path).
  EffEnd := Max(FStart, Min(FEnd, CELT_NB_EBANDS));
  for C := 0 to FChannels - 1 do
  begin
    Move(FDecodeMem[C][N], FDecodeMem[C][0], (CELT_DECODE_BUFFER_SIZE - N + CELT_OVERLAP_SIZE) * SizeOf(Single));
    OutSyn[C] := @FDecodeMem[C][CELT_DECODE_BUFFER_SIZE - N];
  end;
  if FPrefilterAndFold then
    PrefilterAndFold(N);
  if FLossDuration = 0 then Decay := 1.5 else Decay := 0.5;
  for C := 0 to FChannels - 1 do
    for I := FStart to FEnd - 1 do
      FOldEBands[C * CELT_NB_EBANDS + I] :=
        Max(FBackgroundLogE[C * CELT_NB_EBANDS + I], FOldEBands[C * CELT_NB_EBANDS + I] - Decay);
  Seed := FRng;
  X := @FX[0];
  for C := 0 to FChannels - 1 do
    for I := FStart to EffEnd - 1 do
    begin
      BOffs := N * C + (CELT_EBANDS[I] shl LM);
      BLen := (CELT_EBANDS[I + 1] - CELT_EBANDS[I]) shl LM;
      for J := 0 to BLen - 1 do
      begin
        Seed := CeltLcgRand(Seed);
        X[BOffs + J] := Integer(Seed) div (1 shl 20);
        if Integer(Seed) < 0 then
          X[BOffs + J] := -((-Integer(Seed) + (1 shl 20) - 1) shr 20);
      end;
      RenormaliseVector(X + BOffs, BLen, 1.0);
    end;
  FRng := Seed;
  Synthesis(X, OutSyn, @FOldEBands[0], FStart, EffEnd, FChannels, FChannels, False, LM, False);
  FPrefilterAndFold := False;
  FSkipPlc := True;
  FLossDuration := Min(10000, FLossDuration + (1 shl LM));
end;

function TCeltDecoder.Decode(Data: PByte; Len: Integer; const Pcm: array of PSingle;
  FrameSize: Integer; ExtDec: PEcDec): Integer;
var
  LocalDec     : TEcDec;
  Rd          : PEcDec;
  C, I, N, M, LM: Integer;
  CC, SC       : Integer;
  OutSyn       : array[0..1] of PSingle;
  EffEnd       : Integer;
  TotalBits, Tell: Integer;
  Silence      : Boolean;
  PostfilterGain: Single;
  PostfilterPitch, PostfilterTapset: Integer;
  Qg, Octave   : Integer;
  IsTransient  : Boolean;
  ShortBlocks  : Integer;
  IntraEner    : Integer;
  Safety       : Single;
  Missing      : Integer;
  Slope, E0, E1, E2: Single;
  TfRes        : TIntArray;
  SpreadDecision: Integer;
  Cap, Offsets : TIntArray;
  DynallocLogp, DynallocLoopLogp: Integer;
  Width, Quanta, Boost, Flag: Integer;
  TellFrac     : Integer;
  FineQuant, Pulses, FinePriority: TIntArray;
  AllocTrim    : Integer;
  Bits, Balance: Integer;
  AntiCollapseRsv, AntiCollapseOn: Integer;
  Intensity, DualStereo, CodedBands: Integer;
  CollapseMasks: TArray<Byte>;
  X            : PSingle;
  Y            : PSingle;
  MaxBackgroundIncrease: Single;
begin
  Result := -1;
  CC := FChannels;
  SC := FStreamChannels;
  LM := 0;
  while LM <= CELT_MAX_LM do
  begin
    if (CELT_SHORT_MDCT shl LM) = FrameSize then Break;
    Inc(LM);
  end;
  if LM > CELT_MAX_LM then Exit(-1);
  M := 1 shl LM;
  if (Len < 0) or (Len > 1275) then Exit(-1);
  N := M * CELT_SHORT_MDCT;
  for C := 0 to CC - 1 do
    OutSyn[C] := @FDecodeMem[C][CELT_DECODE_BUFFER_SIZE - N];
  EffEnd := Min(FEnd, CELT_NB_EBANDS);

  if (Data = nil) or (Len <= 1) then
  begin
    DecodeLost(N, LM);
    Deemphasis(OutSyn, Pcm, N, CC);
    Exit(FrameSize);
  end;

  if FLossDuration = 0 then FSkipPlc := False;

  if ExtDec = nil then
  begin
    EcDecInit(LocalDec, Data, Len);
    Rd := @LocalDec;
  end
  else
    Rd := ExtDec;

  if SC = 1 then
    for I := 0 to CELT_NB_EBANDS - 1 do
      FOldEBands[I] := Max(FOldEBands[I], FOldEBands[CELT_NB_EBANDS + I]);

  TotalBits := Len * 8;
  Tell := EcTell(Rd^);
  if Tell >= TotalBits then Silence := True
  else if Tell = 1 then Silence := EcDecBitLogp(Rd^, 15) <> 0
  else Silence := False;
  if Silence then
  begin
    Tell := Len * 8;
    Rd^.NBitsTotal := Rd^.NBitsTotal + Tell - EcTell(Rd^);
  end;

  PostfilterGain := 0;
  PostfilterPitch := 0;
  PostfilterTapset := 0;
  if (FStart = 0) and (Tell + 16 <= TotalBits) then
  begin
    if EcDecBitLogp(Rd^, 1) <> 0 then
    begin
      Octave := EcDecUInt(Rd^, 6);
      PostfilterPitch := (16 shl Octave) + Integer(EcDecBits(Rd^, 4 + Octave)) - 1;
      Qg := EcDecBits(Rd^, 3);
      if EcTell(Rd^) + 2 <= TotalBits then
        PostfilterTapset := EcDecIcdf(Rd^, @TAPSET_ICDF[0], 2);
      PostfilterGain := 0.09375 * (Qg + 1);
    end;
    Tell := EcTell(Rd^);
  end;

  if (LM > 0) and (Tell + 3 <= TotalBits) then
  begin
    IsTransient := EcDecBitLogp(Rd^, 3) <> 0;
    Tell := EcTell(Rd^);
  end
  else
    IsTransient := False;
  if IsTransient then ShortBlocks := M else ShortBlocks := 0;

  if Tell + 3 <= TotalBits then IntraEner := EcDecBitLogp(Rd^, 3) else IntraEner := 0;

  if (IntraEner = 0) and (FLossDuration <> 0) then
  begin
    for C := 0 to 1 do
    begin
      Safety := 0;
      Missing := Min(10, FLossDuration shr LM);
      if LM = 0 then Safety := 1.5
      else if LM = 1 then Safety := 0.5;
      for I := FStart to FEnd - 1 do
      begin
        if FOldEBands[C * CELT_NB_EBANDS + I] < Max(FOldLogE[C * CELT_NB_EBANDS + I], FOldLogE2[C * CELT_NB_EBANDS + I]) then
        begin
          E0 := FOldEBands[C * CELT_NB_EBANDS + I];
          E1 := FOldLogE[C * CELT_NB_EBANDS + I];
          E2 := FOldLogE2[C * CELT_NB_EBANDS + I];
          Slope := Max(E1 - E0, 0.5 * (E2 - E0));
          E0 := E0 - Max(0, (1 + Missing) * Slope);
          FOldEBands[C * CELT_NB_EBANDS + I] := Max(-20.0, E0);
        end
        else
          FOldEBands[C * CELT_NB_EBANDS + I] := Min(Min(FOldEBands[C * CELT_NB_EBANDS + I],
            FOldLogE[C * CELT_NB_EBANDS + I]), FOldLogE2[C * CELT_NB_EBANDS + I]);
        FOldEBands[C * CELT_NB_EBANDS + I] := FOldEBands[C * CELT_NB_EBANDS + I] - Safety;
      end;
    end;
  end;

  UnquantCoarseEnergy(FStart, FEnd, @FOldEBands[0], IntraEner, Rd^, SC, LM);

  SetLength(TfRes, CELT_NB_EBANDS);
  TfDecode(FStart, FEnd, IsTransient, TfRes, LM, Rd^);

  Tell := EcTell(Rd^);
  SpreadDecision := SPREAD_NORMAL;
  if Tell + 4 <= TotalBits then
    SpreadDecision := EcDecIcdf(Rd^, @SPREAD_ICDF[0], 5);

  InitCaps(Cap, LM, SC);
  SetLength(Offsets, CELT_NB_EBANDS);
  DynallocLogp := 6;
  TotalBits := TotalBits shl BITRES;
  TellFrac := EcTellFrac(Rd^);
  for I := FStart to FEnd - 1 do
  begin
    Width := SC * (CELT_EBANDS[I + 1] - CELT_EBANDS[I]) shl LM;
    Quanta := Min(Width shl BITRES, Max(6 shl BITRES, Width));
    DynallocLoopLogp := DynallocLogp;
    Boost := 0;
    while (TellFrac + (DynallocLoopLogp shl BITRES) < TotalBits) and (Boost < Cap[I]) do
    begin
      Flag := EcDecBitLogp(Rd^, DynallocLoopLogp);
      TellFrac := EcTellFrac(Rd^);
      if Flag = 0 then Break;
      Boost := Boost + Quanta;
      TotalBits := TotalBits - Quanta;
      DynallocLoopLogp := 1;
    end;
    Offsets[I] := Boost;
    if Boost > 0 then
      DynallocLogp := Max(2, DynallocLogp - 1);
  end;

  if TellFrac + (6 shl BITRES) <= TotalBits then
    AllocTrim := EcDecIcdf(Rd^, @TRIM_ICDF[0], 7)
  else
    AllocTrim := 5;

  Bits := ((Len * 8) shl BITRES) - Integer(EcTellFrac(Rd^)) - 1;
  if IsTransient and (LM >= 2) and (Bits >= ((LM + 2) shl BITRES)) then
    AntiCollapseRsv := 1 shl BITRES
  else
    AntiCollapseRsv := 0;
  Bits := Bits - AntiCollapseRsv;

  Intensity := 0;
  DualStereo := 0;
  CodedBands := CltComputeAllocation(FStart, FEnd, Offsets, Cap, AllocTrim,
    Intensity, DualStereo, Bits, Balance, Pulses, FineQuant, FinePriority, SC, LM, Rd^);

  UnquantFineEnergy(FStart, FEnd, @FOldEBands[0], FineQuant, Rd^, SC);

  for C := 0 to CC - 1 do
    Move(FDecodeMem[C][N], FDecodeMem[C][0], (CELT_DECODE_BUFFER_SIZE - N + CELT_OVERLAP_SIZE) * SizeOf(Single));

  SetLength(CollapseMasks, SC * CELT_NB_EBANDS);
  FillChar(CollapseMasks[0], Length(CollapseMasks), 0);
  X := @FX[0];
  FillChar(X^, SC * N * SizeOf(Single), 0);
  if SC = 2 then Y := X + N else Y := nil;

  QuantAllBands(FStart, FEnd, X, Y, @CollapseMasks[0], Pulses, ShortBlocks,
    SpreadDecision, DualStereo, Intensity, TfRes,
    Len * (8 shl BITRES) - AntiCollapseRsv, Balance, Rd^, LM, CodedBands,
    FRng, FDisableInv);

  AntiCollapseOn := 0;
  if AntiCollapseRsv > 0 then
    AntiCollapseOn := EcDecBits(Rd^, 1);

  UnquantEnergyFinalise(FStart, FEnd, @FOldEBands[0], FineQuant, FinePriority,
    Len * 8 - EcTell(Rd^), Rd^, SC);

  if AntiCollapseOn <> 0 then
    AntiCollapse(X, @CollapseMasks[0], LM, SC, N, FStart, FEnd, @FOldEBands[0],
      @FOldLogE[0], @FOldLogE2[0], Pulses, FRng);

  if Silence then
    for I := 0 to SC * CELT_NB_EBANDS - 1 do
      FOldEBands[I] := -28.0;

  if FPrefilterAndFold then
    PrefilterAndFold(N);

  Synthesis(X, OutSyn, @FOldEBands[0], FStart, EffEnd, SC, CC, IsTransient, LM, Silence);

  for C := 0 to CC - 1 do
  begin
    FPostfilterPeriod := Max(FPostfilterPeriod, COMBFILTER_MINPERIOD);
    FPostfilterPeriodOld := Max(FPostfilterPeriodOld, COMBFILTER_MINPERIOD);
    CombFilter(OutSyn[C], OutSyn[C], FPostfilterPeriodOld, FPostfilterPeriod, CELT_SHORT_MDCT,
      FPostfilterGainOld, FPostfilterGain, FPostfilterTapsetOld, FPostfilterTapset,
      @CELT_WINDOW120[0], CELT_OVERLAP_SIZE);
    if LM <> 0 then
      CombFilter(OutSyn[C] + CELT_SHORT_MDCT, OutSyn[C] + CELT_SHORT_MDCT,
        FPostfilterPeriod, PostfilterPitch, N - CELT_SHORT_MDCT,
        FPostfilterGain, PostfilterGain, FPostfilterTapset, PostfilterTapset,
        @CELT_WINDOW120[0], CELT_OVERLAP_SIZE);
  end;
  FPostfilterPeriodOld := FPostfilterPeriod;
  FPostfilterGainOld := FPostfilterGain;
  FPostfilterTapsetOld := FPostfilterTapset;
  FPostfilterPeriod := PostfilterPitch;
  FPostfilterGain := PostfilterGain;
  FPostfilterTapset := PostfilterTapset;
  if LM <> 0 then
  begin
    FPostfilterPeriodOld := FPostfilterPeriod;
    FPostfilterGainOld := FPostfilterGain;
    FPostfilterTapsetOld := FPostfilterTapset;
  end;

  if SC = 1 then
    Move(FOldEBands[0], FOldEBands[CELT_NB_EBANDS], CELT_NB_EBANDS * SizeOf(Single));

  if not IsTransient then
  begin
    Move(FOldLogE[0], FOldLogE2[0], 2 * CELT_NB_EBANDS * SizeOf(Single));
    Move(FOldEBands[0], FOldLogE[0], 2 * CELT_NB_EBANDS * SizeOf(Single));
  end
  else
    for I := 0 to 2 * CELT_NB_EBANDS - 1 do
      FOldLogE[I] := Min(FOldLogE[I], FOldEBands[I]);

  MaxBackgroundIncrease := Min(160, FLossDuration + M) * 0.001;
  for I := 0 to 2 * CELT_NB_EBANDS - 1 do
    FBackgroundLogE[I] := Min(FBackgroundLogE[I] + MaxBackgroundIncrease, FOldEBands[I]);

  for C := 0 to 1 do
  begin
    for I := 0 to FStart - 1 do
    begin
      FOldEBands[C * CELT_NB_EBANDS + I] := 0;
      FOldLogE[C * CELT_NB_EBANDS + I] := -28.0;
      FOldLogE2[C * CELT_NB_EBANDS + I] := -28.0;
    end;
    for I := FEnd to CELT_NB_EBANDS - 1 do
    begin
      FOldEBands[C * CELT_NB_EBANDS + I] := 0;
      FOldLogE[C * CELT_NB_EBANDS + I] := -28.0;
      FOldLogE2[C * CELT_NB_EBANDS + I] := -28.0;
    end;
  end;
  FRng := Rd^.Rng;

  Deemphasis(OutSyn, Pcm, N, CC);
  FLossDuration := 0;
  FPrefilterAndFold := False;
  if EcTell(Rd^) > 8 * Len then Exit(-3);
  if Rd^.Error <> 0 then FError := 1;
  Result := FrameSize;
end;

end.
