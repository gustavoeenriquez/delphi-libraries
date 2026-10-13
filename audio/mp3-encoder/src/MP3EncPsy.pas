unit MP3EncPsy;

(*
  MP3EncPsy.pas — Psychoacoustic model for the MP3 Layer III encoder

  Simplified ISO 11172-3 psychoacoustic model 2 that works directly on the
  576 MDCT lines of a granule, using the 22 scalefactor bands as partitions:

    1. Energy per scalefactor band            E[b] = sum xr^2
    2. Spreading of the energies across bands with the Schroeder spreading
       function in the Bark domain (weights normalised per band)
    3. Tonality from the spectral flatness measure of the granule
         O[b] = a*(14.5 + bark[b]) + (1-a)*5.5 dB   (a = 1 tonal, 0 noise)
       with a minimum offset (minval) that decreases with frequency
    4. Masking threshold                       T[b] = spread[b] * 10^(-O[b]/10)
    5. Absolute threshold of hearing (Terhardt); a full-scale sine (MDCT line
       amplitude 1.0) is taken as 96 dB SPL
    6. Allowed noise energy per line        xmin[b] = max(T[b]/width[b], ATH[b])

  It also returns a rough estimate of the bits needed to code the granule at
  that threshold (sum width * 0.5*log2(energy/threshold)), used by the bit
  reservoir to distribute bits between granules and channels.

  Reference: ISO 11172-3 Annex D (model 2), LAME psymodel.c (structure only)
  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
*)

interface

uses
  MP3EncQuantize;

const
  PSY_BANDS        = QUANT_SFB_LMAX;  { 22 scalefactor bands (long blocks) }
  PSY_FULLSCALE_DB = 96.0;            { SPL assumed for a full-scale sine }

type
  TPsyBandArr = array[0..PSY_BANDS - 1] of Double;

  TPsyModel = record
    SrIdx      : Integer;
    SampleRate : Integer;
    Width      : array[0..PSY_BANDS - 1] of Integer;
    Bark       : TPsyBandArr;   { Bark value of each band centre }
    AthLin     : TPsyBandArr;   { absolute threshold, energy per line }
    MinValDb   : TPsyBandArr;   { minimum masking offset per band (dB) }
    Spread     : array[0..PSY_BANDS - 1, 0..PSY_BANDS - 1] of Double; { [to][from] }
  end;

  TPsyResult = record
    Energy   : TPsyBandArr;  { band energies (sum of xr^2) }
    Xmin     : TPsyBandArr;  { allowed noise energy per line }
    Tonality : Double;       { 0 = noise-like .. 1 = tonal }
    EstBits  : Double;       { rough bit demand to reach Xmin }
  end;

{ Absolute threshold of hearing in dB SPL (Terhardt approximation). }
function PsyAthDb(AFreqHz: Double): Double;

{ Frequency (Hz) to Bark (Zwicker). }
function PsyBarkOf(AFreqHz: Double): Double;

{ Initialise the model for a sample rate index (0=44100, 1=48000, 2=32000).
  AAthAdjustDb shifts the absolute threshold (negative = more demanding). }
procedure PsyInit(out AModel: TPsyModel; ASrIdx: Integer;
  AAthAdjustDb: Double = 0.0);

{ Analyse one granule (576 MDCT lines) and compute the allowed noise. }
procedure PsyAnalyse(const AModel: TPsyModel; const AXr: T576;
  out AResult: TPsyResult);

{ Bit demand estimate for given band energies and allowed noise. }
function PsyEstimateBits(const AModel: TPsyModel;
  const AEnergy, AXmin: TPsyBandArr): Double;

implementation

uses
  System.Math;

const
  PSY_SAMPLERATES: array[0..2] of Integer = (44100, 48000, 32000);

function PsyAthDb(AFreqHz: Double): Double;
var
  f: Double;
begin
  f := AFreqHz / 1000.0;
  if f < 0.02 then f := 0.02;   { the formula diverges below ~20 Hz }
  Result := 3.64 * Power(f, -0.8)
          - 6.5 * Exp(-0.6 * Sqr(f - 3.3))
          + 1e-3 * Power(f, 4.0);
end;

function PsyBarkOf(AFreqHz: Double): Double;
begin
  Result := 13.0 * ArcTan(0.00076 * AFreqHz)
          + 3.5 * ArcTan(Sqr(AFreqHz / 7500.0));
end;

{ Schroeder spreading function (dB) for a Bark distance ADz = z(masked) - z(masker) }
function SpreadDb(ADz: Double): Double;
begin
  Result := 15.81 + 7.5 * (ADz + 0.474) - 17.5 * Sqrt(1.0 + Sqr(ADz + 0.474));
end;

procedure PsyInit(out AModel: TPsyModel; ASrIdx: Integer; AAthAdjustDb: Double);
var
  b, k, lo, hi: Integer;
  fs, fLo, fHi, fC, ath, w, norm: Double;
begin
  AModel := Default(TPsyModel);
  if (ASrIdx < 0) or (ASrIdx > 2) then ASrIdx := 1;
  AModel.SrIdx      := ASrIdx;
  AModel.SampleRate := PSY_SAMPLERATES[ASrIdx];
  fs := AModel.SampleRate;

  for b := 0 to PSY_BANDS - 1 do begin
    lo := QuantSfbBand(ASrIdx, b);
    hi := QuantSfbBand(ASrIdx, b + 1);
    AModel.Width[b] := hi - lo;
    { line i is centred at (i + 0.5) * fs / 1152 Hz }
    fLo := (lo + 0.5) * fs / 1152.0;
    fHi := (hi - 0.5) * fs / 1152.0;
    fC  := 0.5 * (fLo + fHi);
    AModel.Bark[b] := PsyBarkOf(fC);
    { most sensitive point of the band }
    ath := Min(PsyAthDb(fLo), Min(PsyAthDb(fC), PsyAthDb(fHi)));
    AModel.AthLin[b]   := Power(10.0, (ath - PSY_FULLSCALE_DB + AAthAdjustDb) / 10.0);
    { minimum SNR demanded from the masker: ~24 dB at low frequencies,
      ~3.5 dB at the top (shape of the ISO model 2 minval table) }
    AModel.MinValDb[b] := EnsureRange(24.5 - AModel.Bark[b], 3.5, 24.5);
  end;

  for b := 0 to PSY_BANDS - 1 do begin
    norm := 0.0;
    for k := 0 to PSY_BANDS - 1 do begin
      w := Power(10.0, SpreadDb(AModel.Bark[b] - AModel.Bark[k]) / 10.0);
      AModel.Spread[b][k] := w;
      norm := norm + w;
    end;
    for k := 0 to PSY_BANDS - 1 do
      AModel.Spread[b][k] := AModel.Spread[b][k] / norm;
  end;
end;

function PsyEstimateBits(const AModel: TPsyModel;
  const AEnergy, AXmin: TPsyBandArr): Double;
var
  b: Integer;
  avg, r: Double;
begin
  Result := 0.0;
  for b := 0 to PSY_BANDS - 1 do begin
    if AModel.Width[b] <= 0 then Continue;
    avg := AEnergy[b] / AModel.Width[b];
    if (avg <= 0.0) or (AXmin[b] <= 0.0) then Continue;
    r := avg / AXmin[b];
    if r > 1.0 then
      Result := Result + AModel.Width[b] * 0.5 * Log2(r);
  end;
end;

procedure PsyAnalyse(const AModel: TPsyModel; const AXr: T576;
  out AResult: TPsyResult);
var
  b, k, i, lo, cnt: Integer;
  e, avg, sumLog, sumLin, sfm, a, c, o, t: Double;
begin
  AResult := Default(TPsyResult);

  { 1. band energies }
  lo := 0;
  for b := 0 to PSY_BANDS - 1 do begin
    e := 0.0;
    for i := lo to lo + AModel.Width[b] - 1 do
      e := e + Sqr(AXr[i]);
    AResult.Energy[b] := e;
    Inc(lo, AModel.Width[b]);
  end;

  { 3. tonality from the spectral flatness of the per-line average energies
       (bands 0..20; band 21 is above 16 kHz and usually empty) }
  cnt := 0; sumLog := 0.0; sumLin := 0.0;
  for b := 0 to PSY_BANDS - 2 do begin
    if AModel.Width[b] <= 0 then Continue;
    { silent bands count at the absolute threshold, so a sparse spectrum
      (few lines) is flat-ness-wise very peaky -> tonal }
    avg := AResult.Energy[b] / AModel.Width[b];
    if avg < AModel.AthLin[b] then avg := AModel.AthLin[b];
    sumLog := sumLog + Ln(avg);
    sumLin := sumLin + avg;
    Inc(cnt);
  end;
  if cnt > 1 then begin
    sfm := 10.0 * Log10(Exp(sumLog / cnt) / (sumLin / cnt));  { <= 0 dB }
    a := EnsureRange(sfm / -60.0, 0.0, 1.0);
  end else
    a := 0.0;
  AResult.Tonality := a;

  { 2, 4, 5, 6. spreading, offset, absolute threshold }
  for b := 0 to PSY_BANDS - 1 do begin
    c := 0.0;
    for k := 0 to PSY_BANDS - 1 do
      c := c + AModel.Spread[b][k] * AResult.Energy[k];
    o := a * (14.5 + AModel.Bark[b]) + (1.0 - a) * 5.5;
    if o < AModel.MinValDb[b] then o := AModel.MinValDb[b];
    t := c * Power(10.0, -o / 10.0);
    if AModel.Width[b] > 0 then t := t / AModel.Width[b] else t := 0.0;
    if t < AModel.AthLin[b] then t := AModel.AthLin[b];
    AResult.Xmin[b] := t;
  end;

  AResult.EstBits := PsyEstimateBits(AModel, AResult.Energy, AResult.Xmin);
end;

end.
