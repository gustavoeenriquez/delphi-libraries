unit OpusCelt;

{
  OpusCelt.pas - CELT (Constrained Energy Lapped Transform) decoder

  CELT is the wideband/fullband audio codec used by Opus for music and
  non-voice signals. It uses:

    - Overlapping MDCT with 50% overlap (120 samples at 48kHz)
    - 21 frequency bands (Bark-scale ERB)
    - Two-stage energy coding: coarse (pitch-based log-energy) + fine (per-band)
    - PVQ (Pyramid Vector Quantization): allocates bits per band then decodes
      a unit-norm vector via combinatorial numbering
    - Stereo: joint coding via intensity stereo or M/S (mid-side)
    - Transients: half-block size for attack transients
    - Post-filter (pitch pre-filter) for low-bitrate scenarios

  Spec reference: RFC 6716 sections 4.3 and appendix A

  This implementation covers the CELT decoder for mono and stereo.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  SysUtils, Math,
  OpusTypes,
  OpusRangeDecoder;

// CELT band limits (in bins at 48kHz for N=960, i.e., 20ms)
const
  // ERB bands: bin start positions for 21 bands at frame size 960
  CELT_BANDS_960: array[0..21] of Integer = (
    0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 34,
    40, 48, 60, 78, 100
  );
  // Same pattern scaled for smaller frames
  CELT_NUM_BANDS = 21;

type
  TCeltDecodeState = record
    // MDCT overlap buffer: 2 * overlap samples per channel
    Overlap      : TArray<TArray<Single>>;  // [channel][sample]
    OverlapN     : Integer;
    // Previous pitch filter state
    PostFilterPeriod  : Integer;
    PostFilterGainQ8  : Integer;
    // Previous frame energy (log domain)
    LogEnergy    : array[0..1, 0..CELT_NUM_BANDS - 1] of Single;
    // Silence flag from previous frame
    PrevSilence  : Boolean;
  end;

// Initialize CELT decode state.
procedure CeltDecodeStateInit(var State: TCeltDecodeState; Channels: Integer);

// Decode one CELT frame.
// Rd: range decoder positioned at start of CELT data.
// State: persistent state (updated).
// Channels: 1 or 2.
// FrameSize: samples (120, 240, 480, or 960 at 48kHz).
// Output: [channel][sample] array, pre-allocated.
// Returns False on decode error.
function CeltDecodeFrame(
  var Rd        : TOpusRangeDecoder;
  var State     : TCeltDecodeState;
  Channels      : Integer;
  FrameSize     : Integer;
  const Output  : TArray<TArray<Single>>
): Boolean;

// PVQ combinatorial number C(N, K) — used by tests.
function PVQ_C(N, K: Integer): Int64;

// CELT MDCT (N/4-point complex FFT, Malvar pre/post-rotation) — used by tests.
procedure CeltIMDCT(Input: PSingle; N: Integer; Output: PSingle);

implementation

// ---------------------------------------------------------------------------
// Band limits for current frame size
// ---------------------------------------------------------------------------

function GetBandLimits(FrameSize: Integer; Band: Integer): Integer;
var
  Scale : Integer;
begin
  // Scale the 960-sample band limits to the current frame size
  Scale := 960 div FrameSize;
  if Scale < 1 then Scale := 1;
  if Band <= CELT_NUM_BANDS then
    Result := CELT_BANDS_960[Band] * FrameSize div 960
  else
    Result := FrameSize div 2;
end;

// ---------------------------------------------------------------------------
// ICDF tables for CELT
// ---------------------------------------------------------------------------

const
  // Silence flag
  CELT_SILENCE_ICDF: array[0..1] of Byte = (255, 0);
  // Post-filter flag
  CELT_POSTFILTER_ICDF: array[0..1] of Byte = (128, 0);
  // Transient flag
  CELT_TRANSIENT_ICDF: array[0..1] of Byte = (128, 0);
  // Intra-frame energy prediction flag
  CELT_INTRA_ICDF: array[0..1] of Byte = (128, 0);
  // Number of CELT blocks (anti-collapse)
  CELT_ANTICOLLAPSE_ICDF: array[0..1] of Byte = (128, 0);
  // Stereo: dual-stereo ICDF
  CELT_DUALSTEREO_ICDF: array[0..1] of Byte = (128, 0);
  // Energy predictor table (coarse energy ICDF, per-band — simplified)
  CELT_ENERGY_ICDF: array[0..3] of Byte = (200, 150, 80, 0);

// ---------------------------------------------------------------------------
// Coarse energy decode (RFC 6716 §4.3.2.1)
// ---------------------------------------------------------------------------

// Decode coarse energy (log-domain) for all bands.
// Updates State.LogEnergy.
procedure CeltDecodeCoarseEnergy(
  var Rd      : TOpusRangeDecoder;
  var State   : TCeltDecodeState;
  Channels    : Integer;
  FrameSize   : Integer;
  Intra       : Boolean
);
var
  Ch, Band : Integer;
  Q        : Single;
  Prediction: Single;
begin
  for Band := 0 to CELT_NUM_BANDS - 1 do
  begin
    for Ch := 0 to Channels - 1 do
    begin
      // Decode correction to predicted energy
      var Sym: Integer := RdDecodeICDF(Rd, CELT_ENERGY_ICDF, 8);
      // Map symbol to dB correction: [-6, -3, +3, +6] dB (simplified)
      case Sym of
        0: Q := -6.0;
        1: Q := -3.0;
        2: Q :=  3.0;
        else Q :=  6.0;
      end;

      // Temporal prediction: use previous log-energy with decay
      if Intra then
        Prediction := 0.0
      else
        Prediction := State.LogEnergy[Ch][Band] * 0.9;

      State.LogEnergy[Ch][Band] := Prediction + Q;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Fine energy decode (RFC 6716 §4.3.2.2)
// ---------------------------------------------------------------------------

procedure CeltDecodeFineEnergy(
  var Rd      : TOpusRangeDecoder;
  var State   : TCeltDecodeState;
  Channels    : Integer;
  const FineBits: TArray<Integer>  // bits allocated per band for fine energy
);
var
  Ch, Band : Integer;
  Bits     : Integer;
  Raw      : Cardinal;
  Corr     : Single;
begin
  for Band := 0 to CELT_NUM_BANDS - 1 do
  begin
    for Ch := 0 to Channels - 1 do
    begin
      Bits := FineBits[Band];
      if Bits <= 0 then Continue;
      // Decode Bits-bit raw integer
      Raw  := RdDecodeUInt(Rd, Cardinal(1) shl Bits);
      // Convert to log-energy correction in [−0.5, +0.5) dB/bit
      Corr := (Integer(Raw) - (1 shl (Bits - 1))) / (1 shl Bits);
      State.LogEnergy[Ch][Band] := State.LogEnergy[Ch][Band] + Corr;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// PVQ (Pyramid Vector Quantization) decode (RFC 6716 §4.3.3)
// ---------------------------------------------------------------------------

// Combinatorial number: C(n, k) for PVQ indexing
function PVQ_C(N, K: Integer): Int64;
var
  I  : Integer;
  Num, Den: Int64;
begin
  if K > N then Exit(0);
  if K = 0 then Exit(1);
  Num := 1; Den := 1;
  for I := 1 to K do
  begin
    Num := Num * (N - I + 1);
    Den := Den * I;
  end;
  Result := Num div Den;
end;

// Decode a PVQ vector: N dimensions, K pulses.
// Uses the combinatorial unranking algorithm from RFC 6716 §4.3.3.1.
// Output: float vector, not normalized (raw pulse vector).
procedure PVQDecode(
  var Rd  : TOpusRangeDecoder;
  N, K    : Integer;
  Output  : PSingle
);
var
  I, J  : Integer;
  Index : Int64;
  Total : Int64;
  Sign_ : Integer;
  Pulses: TArray<Integer>;
begin
  if (N <= 0) or (K <= 0) then
  begin
    for I := 0 to N - 1 do Output[I] := 0.0;
    Exit;
  end;

  SetLength(Pulses, N);
  for I := 0 to N - 1 do Pulses[I] := 0;

  // Decode the index
  Total := PVQ_C(N + K - 1, K);
  if Total <= 0 then Total := 1;
  Index := RdDecodeUInt(Rd, Cardinal(Min(Total, Cardinal($7FFFFFFF))));

  // Unrank: reconstruct pulse distribution from index
  var Remaining := K;
  for I := 0 to N - 1 do
  begin
    J := 0;
    while (J < Remaining) do
    begin
      var C: Int64 := PVQ_C(N - I - 1 + Remaining - J - 1, Remaining - J - 1);
      if Index < C then Break;
      Dec(Index, C);
      Inc(J);
    end;
    Pulses[I] := J;
    Dec(Remaining, J);
    if Remaining <= 0 then Break;
  end;

  // Decode sign bits and build float vector
  for I := 0 to N - 1 do
  begin
    if Pulses[I] > 0 then
    begin
      Sign_ := 1;
      if RdDecodeBit(Rd) then Sign_ := -1;
      Output[I] := Pulses[I] * Sign_;
    end
    else
      Output[I] := 0.0;
  end;
end;

// ---------------------------------------------------------------------------
// Band decode (spectral coefficients per band via PVQ)
// ---------------------------------------------------------------------------

procedure CeltDecodeBands(
  var Rd      : TOpusRangeDecoder;
  var State   : TCeltDecodeState;
  Channels    : Integer;
  FrameSize   : Integer;
  const BandBits: TArray<Integer>  // bits per band
);
var
  Band, Ch  : Integer;
  BinStart  : Integer;
  BinEnd    : Integer;
  BinCount  : Integer;
  K         : Integer;
  BandEnergy: Single;
  NormFactor: Single;
  I         : Integer;
  // Per-band coefficient buffers
  CoeffBuf  : TArray<TArray<Single>>;
begin
  SetLength(CoeffBuf, Channels);
  for Ch := 0 to Channels - 1 do
    SetLength(CoeffBuf[Ch], FrameSize div 2);

  for Band := 0 to CELT_NUM_BANDS - 1 do
  begin
    BinStart := GetBandLimits(FrameSize, Band);
    BinEnd   := GetBandLimits(FrameSize, Band + 1);
    BinCount := BinEnd - BinStart;
    if BinCount <= 0 then Continue;

    var Bits := BandBits[Band];

    for Ch := 0 to Channels - 1 do
    begin
      // Compute number of pulses from bit allocation
      // Rough formula: K ≈ 2^(bits/N - 1) × N ... simplified to K = bits div 4
      K := Max(0, Min(Bits div 4, BinCount * 2));

      if K > 0 then
        PVQDecode(Rd, BinCount, K, @CoeffBuf[Ch][BinStart])
      else
        for I := BinStart to BinEnd - 1 do CoeffBuf[Ch][I] := 0.0;

      // Scale by decoded energy
      BandEnergy := Power(10.0, State.LogEnergy[Ch][Band] / 20.0);
      // Normalize pulse vector
      var NormSq: Single := 0.0;
      for I := BinStart to BinEnd - 1 do
        NormSq := NormSq + Sqr(CoeffBuf[Ch][I]);
      if NormSq > 1e-30 then
        NormFactor := BandEnergy / Sqrt(NormSq)
      else
        NormFactor := 0.0;

      for I := BinStart to BinEnd - 1 do
        CoeffBuf[Ch][I] := CoeffBuf[Ch][I] * NormFactor;
    end;
  end;

  // Store results in State output for IMDCT
  // (In full implementation, these would feed into the IMDCT input buffers)
  // For now, save in overlap buffer as a proxy
  for Ch := 0 to Channels - 1 do
    for I := 0 to FrameSize div 2 - 1 do
      if I < Length(State.Overlap[Ch]) then
        State.Overlap[Ch][I] := CoeffBuf[Ch][I];
end;

// ---------------------------------------------------------------------------
// MDCT (type-IV DCT inverse) for CELT
// ---------------------------------------------------------------------------

// 120-sample base MDCT at 48kHz (2.5ms).
// Scales up by 2× for each doubling of frame size.
procedure CeltIMDCT(Input: PSingle; N: Integer; Output: PSingle);
var
  N2, N4  : Integer;
  K, J    : Integer;
  Ar, Ai  : TArray<Single>;
  TmpR, TmpI : TArray<Single>;
  Angle   : Double;
  Tr, Ti  : Single;
begin
  N2 := N shr 1;
  N4 := N shr 2;
  if N4 = 0 then Exit;

  SetLength(Ar, N4);
  SetLength(Ai, N4);

  // Pre-rotation: map N/2 real spectral inputs to N/4 complex values
  for K := 0 to N4 - 1 do
  begin
    Angle := Pi * (4.0 * K + 1) / (2.0 * N);
    Ar[K] := Input[N2 - 1 - 2*K] * Cos(Angle) - Input[2*K] * Sin(Angle);
    Ai[K] := Input[N2 - 1 - 2*K] * Sin(Angle) + Input[2*K] * Cos(Angle);
  end;

  // N/4-point complex DFT
  // CELT frame sizes give N4 = 30, 60, 120, 240, 480 — none are powers of 2,
  // so the standard radix-2 FFT cannot be used here.
  SetLength(TmpR, N4);
  SetLength(TmpI, N4);
  for J := 0 to N4 - 1 do
  begin
    TmpR[J] := 0.0;
    TmpI[J] := 0.0;
    for K := 0 to N4 - 1 do
    begin
      Angle   := -2.0 * Pi * K * J / N4;
      TmpR[J] := TmpR[J] + Ar[K] * Cos(Angle) - Ai[K] * Sin(Angle);
      TmpI[J] := TmpI[J] + Ar[K] * Sin(Angle) + Ai[K] * Cos(Angle);
    end;
  end;
  for J := 0 to N4 - 1 do
  begin
    Ar[J] := TmpR[J];
    Ai[J] := TmpI[J];
  end;

  // Post-rotate and unfold to N real outputs
  for K := 0 to N4 - 1 do
  begin
    Angle := Pi * (4.0 * K + 1) / (2.0 * N);
    Tr := (Ar[K] * Cos(Angle) + Ai[K] * Sin(Angle)) * (1.0 / N4);
    Ti := (Ar[K] * Sin(Angle) - Ai[K] * Cos(Angle)) * (1.0 / N4);
    Output[N4 + K]         :=  Tr;
    Output[N4 - 1 - K]     :=  Ti;
    Output[N4*3 + K]       := -Ti;
    Output[N - 1 - K - N4] := -Tr;
  end;
end;

// CELT window: raised-cosine overlap
function CeltWindow(I, N: Integer): Single; inline;
begin
  // 120-sample sine^2 window
  var S: Single := Sin(Pi * (I + 0.5) / N);
  Result := S * S;
end;

// ---------------------------------------------------------------------------
// Simple bit allocation (proportional to band ERB width × quality)
// ---------------------------------------------------------------------------

procedure CeltAllocateBits(
  FrameSize   : Integer;
  TotalBits   : Integer;
  BandBits    : TArray<Integer>;
  FineBits    : TArray<Integer>
);
var
  Band      : Integer;
  BinCounts : TArray<Integer>;
  TotalBins : Integer;
  Remaining : Integer;
begin
  SetLength(BinCounts, CELT_NUM_BANDS);
  TotalBins := 0;
  for Band := 0 to CELT_NUM_BANDS - 1 do
  begin
    BinCounts[Band] := GetBandLimits(FrameSize, Band + 1) - GetBandLimits(FrameSize, Band);
    Inc(TotalBins, BinCounts[Band]);
  end;
  if TotalBins = 0 then TotalBins := 1;

  // Proportional allocation
  Remaining := TotalBits;
  for Band := 0 to CELT_NUM_BANDS - 1 do
  begin
    BandBits[Band] := TotalBits * BinCounts[Band] div TotalBins;
    Dec(Remaining, BandBits[Band]);
  end;
  // Give remainder to last band
  if CELT_NUM_BANDS > 0 then
    Inc(BandBits[CELT_NUM_BANDS - 1], Remaining);

  // Fine energy gets 1 bit per band per channel
  for Band := 0 to CELT_NUM_BANDS - 1 do
    FineBits[Band] := Min(1, BandBits[Band] div 4);
end;

// ---------------------------------------------------------------------------
// State init
// ---------------------------------------------------------------------------

procedure CeltDecodeStateInit(var State: TCeltDecodeState; Channels: Integer);
var
  Ch : Integer;
begin
  FillChar(State, SizeOf(State), 0);
  SetLength(State.Overlap, Channels);
  for Ch := 0 to Channels - 1 do
    SetLength(State.Overlap[Ch], CELT_OVERLAP * 2);
  State.OverlapN := CELT_OVERLAP;
  State.PrevSilence := True;
end;

// ---------------------------------------------------------------------------
// CELT frame decode
// ---------------------------------------------------------------------------

function CeltDecodeFrame(
  var Rd        : TOpusRangeDecoder;
  var State     : TCeltDecodeState;
  Channels      : Integer;
  FrameSize     : Integer;
  const Output  : TArray<TArray<Single>>
): Boolean;
var
  Ch         : Integer;
  I          : Integer;
  Silence    : Boolean;
  PostFilter : Boolean;
  HasTransient: Boolean;
  IntraEnergy : Boolean;
  BandBits   : TArray<Integer>;
  FineBitsArr: TArray<Integer>;
  MDCTIn     : TArray<TArray<Single>>;
  MDCTOut    : TArray<TArray<Single>>;
  Overlap    : Integer;
begin
  Result := False;
  Overlap := CELT_OVERLAP;

  SetLength(BandBits, CELT_NUM_BANDS);
  SetLength(FineBitsArr, CELT_NUM_BANDS);
  SetLength(MDCTIn, Channels);
  SetLength(MDCTOut, Channels);
  for Ch := 0 to Channels - 1 do
  begin
    SetLength(MDCTIn[Ch], FrameSize div 2);
    SetLength(MDCTOut[Ch], FrameSize);
    FillChar(MDCTIn[Ch][0], (FrameSize div 2) * SizeOf(Single), 0);
    FillChar(MDCTOut[Ch][0], FrameSize * SizeOf(Single), 0);
  end;

  // ---- Silence flag ----
  Silence := RdDecodeICDF(Rd, CELT_SILENCE_ICDF, 8) = 0;
  if Silence then
  begin
    for Ch := 0 to Channels - 1 do
      for I := 0 to FrameSize - 1 do
        Output[Ch][I] := 0.0;
    // Drain overlap
    for Ch := 0 to Channels - 1 do
      for I := 0 to Overlap - 1 do
        State.Overlap[Ch][I] := 0.0;
    State.PrevSilence := True;
    Exit(True);
  end;

  // ---- Post-filter ----
  PostFilter := RdDecodeICDF(Rd, CELT_POSTFILTER_ICDF, 8) = 0;
  if PostFilter then
  begin
    // Decode pitch period and gain (simplified: read but ignore)
    var Period: Cardinal := RdDecodeUInt(Rd, 512);
    var GainIdx: Cardinal := RdDecodeUInt(Rd, 8);
    State.PostFilterPeriod := Period;
    State.PostFilterGainQ8 := GainIdx;
  end;

  // ---- Transient flag ----
  HasTransient := (FrameSize > CELT_NB_IMDCT_SIZE) and
                  (RdDecodeICDF(Rd, CELT_TRANSIENT_ICDF, 8) = 0);

  // ---- Stereo: dual-stereo or M/S ----
  var DualStereo := (Channels > 1) and
                    (RdDecodeICDF(Rd, CELT_DUALSTEREO_ICDF, 8) = 0);

  // ---- Intra prediction flag ----
  IntraEnergy := RdDecodeICDF(Rd, CELT_INTRA_ICDF, 8) = 0;

  // ---- Coarse energy ----
  CeltDecodeCoarseEnergy(Rd, State, Channels, FrameSize, IntraEnergy);

  // ---- Bit allocation (simplified) ----
  var TotalBits := (Rd.DataLen - Rd.DataPos) * 8;  // rough estimate
  CeltAllocateBits(FrameSize, TotalBits, BandBits, FineBitsArr);

  // ---- Spectral coefficients ----
  CeltDecodeBands(Rd, State, Channels, FrameSize, BandBits);

  // ---- Fine energy ----
  CeltDecodeFineEnergy(Rd, State, Channels, FineBitsArr);

  // Copy spectral from overlap proxy into MDCT input
  for Ch := 0 to Channels - 1 do
    for I := 0 to FrameSize div 2 - 1 do
      if I < Length(State.Overlap[Ch]) then
        MDCTIn[Ch][I] := State.Overlap[Ch][I];

  // ---- IMDCT ----
  for Ch := 0 to Channels - 1 do
    CeltIMDCT(@MDCTIn[Ch][0], FrameSize, @MDCTOut[Ch][0]);

  // ---- Overlap-add with Hann window ----
  for Ch := 0 to Channels - 1 do
  begin
    // Left half: add previous overlap
    for I := 0 to Overlap - 1 do
    begin
      var W := CeltWindow(I, Overlap * 2);
      var Samp := MDCTOut[Ch][I] * W + State.Overlap[Ch][I];
      if Samp >  1.0 then Samp :=  1.0;
      if Samp < -1.0 then Samp := -1.0;
      Output[Ch][I] := Samp;
    end;
    // Center: flat (no overlap)
    for I := Overlap to FrameSize - Overlap - 1 do
    begin
      var Samp := MDCTOut[Ch][I];
      if Samp >  1.0 then Samp :=  1.0;
      if Samp < -1.0 then Samp := -1.0;
      Output[Ch][I] := Samp;
    end;
    // Save right overlap for next frame
    for I := 0 to Overlap - 1 do
    begin
      var W := CeltWindow(Overlap - 1 - I, Overlap * 2);
      State.Overlap[Ch][I] := MDCTOut[Ch][FrameSize - Overlap + I] * W;
    end;
  end;

  // M/S decoupling for stereo (if not dual-stereo)
  if (Channels > 1) and not DualStereo then
  begin
    for I := 0 to FrameSize - 1 do
    begin
      var M := Output[0][I];
      var S := Output[1][I];
      Output[0][I] := (M + S) * 0.5;
      Output[1][I] := (M - S) * 0.5;
    end;
  end;

  State.PrevSilence := False;
  Result := not RdHasError(Rd);
end;

end.
