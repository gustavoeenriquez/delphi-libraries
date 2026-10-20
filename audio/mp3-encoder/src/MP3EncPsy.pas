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

  Short blocks (PsyAnalyseShort) use the same steps on the 13 short
  scalefactor bands of each of the three windows, treating the signal as
  noise-like (a transient).  With the 1/(N/4) MDCT scaling a stationary
  signal has 3x more energy per line in a 12-point MDCT than in a 36-point
  one, so the absolute threshold per line is 3x higher there.

  FFT model (PsyAnalyseFFT, long blocks): psychoacoustic model 2 of ISO
  11172-3 Annex D on a 1024-point FFT (Hann window) of the PCM centred on
  the granule.  The tonality of every partition of about 1/3 Bark comes
  from the unpredictability of its lines (polar prediction from the two
  previous granules) instead of one flatness value for the whole granule:
    c(w)  = |X(w) - Xpred(w)| / (|X(w)| + |Xpred(w)|)        lines < 206
    tb    = -0.299 - 0.43 ln(spread(e*c) / spread(e))         (0 .. 1)
    SNR   = max(minval, tb*29 + (1-tb)*6) dB
  The threshold of each partition is spread evenly over its lines and
  summed per scalefactor band; the band ratio threshold/energy is then
  applied to the MDCT energies (PsyApplyRatio), so the scales of the two
  transforms never meet.  The pre-echo control of model 2 (threshold
  limited by those of the previous granules) is left out: the window
  switching handles the transients, and limiting the threshold measured
  worse (PEAQ).

  Reference: ISO 11172-3 Annex D (model 2), LAME psymodel.c (structure only)
  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
*)

interface

uses
  MP3EncQuantize;

const
  PSY_BANDS        = QUANT_SFB_LMAX;  { 22 scalefactor bands (long blocks) }
  PSY_SBANDS       = QUANT_SFB_SMAX;  { 13 scalefactor bands per short window }
  PSY_FULLSCALE_DB = 96.0;            { SPL assumed for a full-scale sine }
  PSY_FFT_LONG     = 1024;            { FFT size of the long-block model }
  PSY_FFT_LINES    = PSY_FFT_LONG div 2;
  PSY_MAXPART      = 80;              { partitions of about 1/3 Bark }

type
  TPsyBandArr = array[0..PSY_BANDS - 1] of Double;
  TPsyFFTBuf  = array[0..PSY_FFT_LONG - 1] of Double;
  TPsyFFTSpec = array[0..PSY_FFT_LINES - 1] of Double;
  TPsyPartArr = array[0..PSY_MAXPART - 1] of Double;

  { State of the FFT model for one channel: the spectra of the two previous
    granules, for the unpredictability measure. }
  TPsyFFTState = record
    R1, R2, F1, F2 : TPsyFFTSpec;   { magnitude and phase, granules t-1, t-2 }
    Count          : Integer;       { granules analysed so far }
  end;

  TPsyModel = record
    SrIdx      : Integer;
    SampleRate : Integer;
    Width      : array[0..PSY_BANDS - 1] of Integer;
    Bark       : TPsyBandArr;   { Bark value of each band centre }
    AthLin     : TPsyBandArr;   { absolute threshold, energy per line }
    MinValDb   : TPsyBandArr;   { minimum masking offset per band (dB) }
    Spread     : array[0..PSY_BANDS - 1, 0..PSY_BANDS - 1] of Double; { [to][from] }
    { short blocks }
    WidthS     : array[0..PSY_SBANDS - 1] of Integer;
    BarkS, AthLinS, MinValDbS : array[0..PSY_SBANDS - 1] of Double;
    SpreadS    : array[0..PSY_SBANDS - 1, 0..PSY_SBANDS - 1] of Double;
    { FFT model (long blocks) }
    NPart      : Integer;
    PartLo, PartHi : array[0..PSY_MAXPART - 1] of Integer;  { FFT lines [lo, hi) }
    PartOf     : array[0..PSY_FFT_LINES - 1] of Integer;    { partition of a line }
    PartBval, PartMinVal, PartRnorm : TPsyPartArr;
    PartSpread : array[0..PSY_MAXPART - 1, 0..PSY_MAXPART - 1] of Double; { [to][from] }
    SfbFftLo, SfbFftHi : array[0..PSY_BANDS - 1] of Integer; { FFT lines of each sfb }
    Window     : TPsyFFTBuf;                                { Hann }
    CosTab, SinTab : array[0..PSY_FFT_LONG div 2 - 1] of Double;
  end;

  TPsyShortArr = array[0..PSY_SBANDS - 1, 0..2] of Double;   { [sfb][window] }
  TPsyShortSpec = array[0..2, 0..191] of Double;              { [window][line] }

  TPsyShortResult = record
    Energy  : TPsyShortArr;   { band energies }
    Xmin    : TPsyShortArr;   { allowed noise energy per line }
    EstBits : Double;
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

{ Analyse one short-block granule: three windows of 192 lines each. }
procedure PsyAnalyseShort(const AModel: TPsyModel; const ASpec: TPsyShortSpec;
  out AResult: TPsyShortResult);

{ Bit demand estimate of a short-block granule. }
function PsyEstimateBitsShort(const AModel: TPsyModel;
  const AEnergy, AXmin: TPsyShortArr): Double;

{ Bit demand estimate for given band energies and allowed noise. }
function PsyEstimateBits(const AModel: TPsyModel;
  const AEnergy, AXmin: TPsyBandArr): Double;

{ Reset the FFT model state of a channel. }
procedure PsyFFTReset(out AState: TPsyFFTState);

{ FFT model on the 1024 PCM samples centred on the granule: allowed noise /
  signal energy of every scalefactor band (long blocks). }
procedure PsyAnalyseFFT(const AModel: TPsyModel; var AState: TPsyFFTState;
  const ASamples: TPsyFFTBuf; out ARatio: TPsyBandArr);

{ Allowed noise of a long-block granule from the band ratios of the FFT
  model and the MDCT band energies in AResult.Energy (as PsyAnalyse leaves
  them), with the absolute threshold as the floor.  Updates Xmin and
  EstBits. }
procedure PsyApplyRatio(const AModel: TPsyModel; const ARatio: TPsyBandArr;
  var AResult: TPsyResult);

implementation

uses
  System.Math;

const
  PSY_SAMPLERATES: array[0..2] of Integer = (44100, 48000, 32000);
  PSY_TMN      = 29.0;   { tone masking noise (dB) }
  PSY_NMT      = 6.0;    { noise masking tone (dB) }
  PSY_CW_LINES = 206;    { unpredictability measured below this FFT line
                           (~8.9 kHz at 44.1 kHz); the lines above count 0.4 }

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

  { short blocks: line i of a window is centred at (i + 0.5) * fs / 384 Hz }
  for b := 0 to PSY_SBANDS - 1 do begin
    lo := QuantSfbShort(ASrIdx, b);
    hi := QuantSfbShort(ASrIdx, b + 1);
    AModel.WidthS[b] := hi - lo;
    fLo := (lo + 0.5) * fs / 384.0;
    fHi := (hi - 0.5) * fs / 384.0;
    fC  := 0.5 * (fLo + fHi);
    AModel.BarkS[b] := PsyBarkOf(fC);
    ath := Min(PsyAthDb(fLo), Min(PsyAthDb(fC), PsyAthDb(fHi)));
    AModel.AthLinS[b] := 3.0 * Power(10.0, (ath - PSY_FULLSCALE_DB + AAthAdjustDb) / 10.0);
    AModel.MinValDbS[b] := EnsureRange(24.5 - AModel.BarkS[b], 3.5, 24.5);
  end;
  for b := 0 to PSY_SBANDS - 1 do begin
    norm := 0.0;
    for k := 0 to PSY_SBANDS - 1 do begin
      w := Power(10.0, SpreadDb(AModel.BarkS[b] - AModel.BarkS[k]) / 10.0);
      AModel.SpreadS[b][k] := w;
      norm := norm + w;
    end;
    for k := 0 to PSY_SBANDS - 1 do
      AModel.SpreadS[b][k] := AModel.SpreadS[b][k] / norm;
  end;

  { FFT model: partitions of about 1/3 Bark over the 512 lines of the
    1024-point FFT (line k at k * fs / 1024 Hz) }
  b := 0;
  AModel.PartLo[0] := 0;
  for k := 1 to PSY_FFT_LINES - 1 do
    if (b < PSY_MAXPART - 1) and
       (PsyBarkOf(k * fs / PSY_FFT_LONG) - PsyBarkOf(AModel.PartLo[b] * fs / PSY_FFT_LONG) >= 1.0 / 3.0) then begin
      AModel.PartHi[b] := k;
      Inc(b);
      AModel.PartLo[b] := k;
    end;
  AModel.PartHi[b] := PSY_FFT_LINES;
  AModel.NPart := b + 1;
  for b := 0 to AModel.NPart - 1 do begin
    for k := AModel.PartLo[b] to AModel.PartHi[b] - 1 do AModel.PartOf[k] := b;
    AModel.PartBval[b] := PsyBarkOf(0.5 * (AModel.PartLo[b] + AModel.PartHi[b] - 1) * fs / PSY_FFT_LONG);
    AModel.PartMinVal[b] := EnsureRange(24.5 - AModel.PartBval[b], 3.5, 24.5);
  end;
  for b := 0 to AModel.NPart - 1 do begin
    norm := 0.0;
    for k := 0 to AModel.NPart - 1 do begin
      w := Power(10.0, SpreadDb(AModel.PartBval[b] - AModel.PartBval[k]) / 10.0);
      AModel.PartSpread[b][k] := w;
      norm := norm + w;
    end;
    AModel.PartRnorm[b] := 1.0 / norm;
  end;
  { scalefactor band b covers MDCT lines [lo, hi), i.e. frequencies
    [lo, hi) * fs / 1152, which are FFT lines [lo, hi) * 1024 / 1152 }
  for b := 0 to PSY_BANDS - 1 do begin
    lo := Round(QuantSfbBand(ASrIdx, b) * PSY_FFT_LONG / 1152.0);
    hi := Round(QuantSfbBand(ASrIdx, b + 1) * PSY_FFT_LONG / 1152.0);
    if lo > PSY_FFT_LINES - 1 then lo := PSY_FFT_LINES - 1;
    if hi > PSY_FFT_LINES then hi := PSY_FFT_LINES;
    if hi <= lo then hi := lo + 1;
    AModel.SfbFftLo[b] := lo;
    AModel.SfbFftHi[b] := hi;
  end;
  for k := 0 to PSY_FFT_LONG - 1 do
    AModel.Window[k] := 0.5 - 0.5 * Cos(2.0 * Pi * (k + 0.5) / PSY_FFT_LONG);
  for k := 0 to PSY_FFT_LONG div 2 - 1 do begin
    AModel.CosTab[k] := Cos(2.0 * Pi * k / PSY_FFT_LONG);
    AModel.SinTab[k] := -Sin(2.0 * Pi * k / PSY_FFT_LONG);
  end;
end;

procedure PsyFFTReset(out AState: TPsyFFTState);
begin
  AState := Default(TPsyFFTState);
end;

{ In-place radix-2 FFT of PSY_FFT_LONG points. }
procedure FFTLong(const AModel: TPsyModel; var ARe, AIm: TPsyFFTBuf);
var
  i, j, k, m, len, half, step: Integer;
  tr, ti, wr, wi: Double;
begin
  j := 0;
  for i := 0 to PSY_FFT_LONG - 2 do begin
    if i < j then begin
      tr := ARe[i]; ARe[i] := ARe[j]; ARe[j] := tr;
      ti := AIm[i]; AIm[i] := AIm[j]; AIm[j] := ti;
    end;
    m := PSY_FFT_LONG shr 1;
    while (m >= 1) and (j >= m) do begin
      Dec(j, m);
      m := m shr 1;
    end;
    Inc(j, m);
  end;
  len := 2;
  while len <= PSY_FFT_LONG do begin
    half := len shr 1;
    step := PSY_FFT_LONG div len;
    i := 0;
    while i < PSY_FFT_LONG do begin
      for k := 0 to half - 1 do begin
        wr := AModel.CosTab[k * step];
        wi := AModel.SinTab[k * step];
        tr := wr * ARe[i + k + half] - wi * AIm[i + k + half];
        ti := wr * AIm[i + k + half] + wi * ARe[i + k + half];
        ARe[i + k + half] := ARe[i + k] - tr;
        AIm[i + k + half] := AIm[i + k] - ti;
        ARe[i + k] := ARe[i + k] + tr;
        AIm[i + k] := AIm[i + k] + ti;
      end;
      Inc(i, len);
    end;
    len := len shl 1;
  end;
end;

procedure PsyAnalyseFFT(const AModel: TPsyModel; var AState: TPsyFFTState;
  const ASamples: TPsyFFTBuf; out ARatio: TPsyBandArr);
var
  re, im: TPsyFFTBuf;
  r, f, cw: TPsyFFTSpec;
  eb, cb, nb: TPsyPartArr;
  k, b, j, np: Integer;
  rp, fp, den, ecb, ct, c, tb, snr, en, thr: Double;
begin
  np := AModel.NPart;
  for k := 0 to PSY_FFT_LONG - 1 do begin
    re[k] := ASamples[k] * AModel.Window[k];
    im[k] := 0.0;
  end;
  FFTLong(AModel, re, im);

  { magnitude, phase and unpredictability (polar prediction from the two
    previous granules; 1 = unpredictable / noise, 0 = perfectly predicted) }
  for k := 0 to PSY_FFT_LINES - 1 do begin
    r[k] := Sqrt(Sqr(re[k]) + Sqr(im[k]));
    if r[k] > 0.0 then f[k] := ArcTan2(im[k], re[k]) else f[k] := 0.0;
    if k >= PSY_CW_LINES then
      cw[k] := 0.4
    else if AState.Count < 2 then
      cw[k] := 1.0
    else begin
      rp := 2.0 * AState.R1[k] - AState.R2[k];
      fp := 2.0 * AState.F1[k] - AState.F2[k];
      den := r[k] + Abs(rp);
      if den > 0.0 then
        cw[k] := Sqrt(Sqr(r[k] * Cos(f[k]) - rp * Cos(fp)) +
                      Sqr(r[k] * Sin(f[k]) - rp * Sin(fp))) / den
      else
        cw[k] := 1.0;
    end;
  end;
  AState.R2 := AState.R1; AState.F2 := AState.F1;
  AState.R1 := r;         AState.F1 := f;
  Inc(AState.Count);

  { energy and unpredictability-weighted energy per partition }
  for b := 0 to np - 1 do begin
    eb[b] := 0.0; cb[b] := 0.0;
    for k := AModel.PartLo[b] to AModel.PartHi[b] - 1 do begin
      eb[b] := eb[b] + Sqr(r[k]);
      cb[b] := cb[b] + Sqr(r[k]) * cw[k];
    end;
  end;

  { spreading, tonality index, SNR, threshold }
  for b := 0 to np - 1 do begin
    ecb := 0.0; ct := 0.0;
    for j := 0 to np - 1 do begin
      ecb := ecb + AModel.PartSpread[b][j] * eb[j];
      ct  := ct  + AModel.PartSpread[b][j] * cb[j];
    end;
    if ecb > 0.0 then c := ct / ecb else c := 1.0;
    if c < 1.0e-10 then c := 1.0e-10;
    tb := EnsureRange(-0.299 - 0.43 * Ln(c), 0.0, 1.0);
    snr := tb * PSY_TMN + (1.0 - tb) * PSY_NMT;
    if snr < AModel.PartMinVal[b] then snr := AModel.PartMinVal[b];
    nb[b] := ecb * AModel.PartRnorm[b] * Power(10.0, -snr / 10.0);
  end;

  { allowed noise / energy per scalefactor band (threshold spread evenly
    over the lines of a partition) }
  for b := 0 to PSY_BANDS - 1 do begin
    en := 0.0; thr := 0.0;
    for k := AModel.SfbFftLo[b] to AModel.SfbFftHi[b] - 1 do begin
      j := AModel.PartOf[k];
      en := en + Sqr(r[k]);
      thr := thr + nb[j] / (AModel.PartHi[j] - AModel.PartLo[j]);
    end;
    if en > 0.0 then ARatio[b] := thr / en else ARatio[b] := 0.0;
  end;
end;

procedure PsyApplyRatio(const AModel: TPsyModel; const ARatio: TPsyBandArr;
  var AResult: TPsyResult);
var
  b: Integer;
  t: Double;
begin
  for b := 0 to PSY_BANDS - 1 do begin
    if AModel.Width[b] > 0 then
      t := ARatio[b] * AResult.Energy[b] / AModel.Width[b]
    else
      t := 0.0;
    if t < AModel.AthLin[b] then t := AModel.AthLin[b];
    AResult.Xmin[b] := t;
  end;
  AResult.EstBits := PsyEstimateBits(AModel, AResult.Energy, AResult.Xmin);
end;

function PsyEstimateBitsShort(const AModel: TPsyModel;
  const AEnergy, AXmin: TPsyShortArr): Double;
var
  b, w: Integer;
  avg, r: Double;
begin
  Result := 0.0;
  for w := 0 to 2 do
    for b := 0 to PSY_SBANDS - 1 do begin
      if AModel.WidthS[b] <= 0 then Continue;
      avg := AEnergy[b][w] / AModel.WidthS[b];
      if (avg <= 0.0) or (AXmin[b][w] <= 0.0) then Continue;
      r := avg / AXmin[b][w];
      if r > 1.0 then
        Result := Result + AModel.WidthS[b] * 0.5 * Log2(r);
    end;
end;

procedure PsyAnalyseShort(const AModel: TPsyModel; const ASpec: TPsyShortSpec;
  out AResult: TPsyShortResult);
var
  b, k, w, i, lo: Integer;
  e, c, o, t: Double;
begin
  AResult := Default(TPsyShortResult);
  for w := 0 to 2 do begin
    lo := 0;
    for b := 0 to PSY_SBANDS - 1 do begin
      e := 0.0;
      for i := lo to lo + AModel.WidthS[b] - 1 do e := e + Sqr(ASpec[w][i]);
      AResult.Energy[b][w] := e;
      Inc(lo, AModel.WidthS[b]);
    end;
  end;
  for w := 0 to 2 do
    for b := 0 to PSY_SBANDS - 1 do begin
      c := 0.0;
      for k := 0 to PSY_SBANDS - 1 do
        c := c + AModel.SpreadS[b][k] * AResult.Energy[k][w];
      o := 5.5;                                 { noise-like masker }
      if o < AModel.MinValDbS[b] then o := AModel.MinValDbS[b];
      t := c * Power(10.0, -o / 10.0);
      if AModel.WidthS[b] > 0 then t := t / AModel.WidthS[b] else t := 0.0;
      if t < AModel.AthLinS[b] then t := AModel.AthLinS[b];
      AResult.Xmin[b][w] := t;
    end;
  AResult.EstBits := PsyEstimateBitsShort(AModel, AResult.Energy, AResult.Xmin);
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
