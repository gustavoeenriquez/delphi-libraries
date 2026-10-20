unit MP3EncQuantize;

{
  MP3EncQuantize.pas — MP3 Layer III spectral quantizer / dequantizer

  Implements:
    - Quantize 576 MDCT coefficients → integer indices ix[0..575]
    - Dequantize ix[] → reconstructed float coefficients (for distortion check)
    - Scale-factor band helpers (44.1/48/32 kHz, long blocks only)

  Quantization formula (ISO 11172-3 §2.4.3.4):
    step   = 2^( (global_gain - 210 + sfb_adj) / 4 )
    ix[i]  = floor( (|xr[i]| / step)^(3/4) + 0.4054 )

  Dequantization formula:
    xr'[i] = ix[i]^(4/3) * 2^( (global_gain - 210 + sfb_adj) / 4 )
    (sign is restored from the original xr[i])

  sfb_adj for long blocks:
    sfb_adj = -2*(1+scalefac_scale)*(scalefac_l[sfb] + preflag*pretab[sfb])

  Reference: toots/shine l3loop.c — translated to floating-point Delphi.
  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

const
  QUANT_GRANULE  = 576;
  QUANT_SFB_LMAX = 22;    // scalefactor bands for long blocks (MPEG1)
  QUANT_SR_COUNT = 3;     // 0=44100, 1=48000, 2=32000
  QUANT_POW43_MAX = 8192; // precomputed ix^(4/3) table size

type
  T576      = array[0..QUANT_GRANULE - 1]  of Double;
  T576Int   = array[0..QUANT_GRANULE - 1]  of Integer;
  TScalefacL = array[0..QUANT_SFB_LMAX - 1] of Integer;

  TQuantState = record
    Pow43 : array[0..QUANT_POW43_MAX - 1] of Double;  // ix^(4/3)
  end;

{ Build the ix^(4/3) lookup table. Call once per encoder session. }
procedure QuantInit(out AState: TQuantState);

{ Return the scalefactor band (0..21) that contains spectral line ALine.
  ASrIdx: 0=44100 Hz, 1=48000 Hz, 2=32000 Hz }
function QuantSfbForLine(ASrIdx, ALine: Integer): Integer;

{ Per-band gain adjustment (long blocks):
  = -2 * (1 + AScalefacScale) * (AScalefacL + APreflag * APretab) }
function QuantSfbAdj(AScalefacL, AScalefacScale, APreflag, APretab: Integer): Integer;

{ Quantize a single spectral line (returns non-negative ix).
  AXrAbs    : absolute value of the MDCT coefficient
  AGlobalGain : global_gain (0..255)
  ASfbAdj   : per-band gain adjustment (from QuantSfbAdj, usually <= 0) }
function QuantizeLine(AXrAbs: Double; AGlobalGain, ASfbAdj: Integer): Integer;

{ Dequantize a single ix (returns positive; caller restores sign).
  For ix >= QUANT_POW43_MAX, falls back to direct formula. }
function DequantizeLine(const AState: TQuantState;
  AIx, AGlobalGain, ASfbAdj: Integer): Double;

{ Quantize 576 coefficients for one granule.
  Returns the maximum ix value (0 = all zero). }
function QuantizeBlock(const AState: TQuantState;
  const AXr: T576; AGlobalGain: Integer;
  const AScalefacL: TScalefacL; AScalefacScale, APreflag, ASrIdx: Integer;
  out AIx: T576Int): Integer;

{ Dequantize 576 coefficients (signs from AXr; zero when AIx[i]=0; AIx may
  hold signed values, only the magnitude is used). }
procedure DequantizeBlock(const AState: TQuantState;
  const AIx: T576Int; const AXr: T576;
  AGlobalGain: Integer;
  const AScalefacL: TScalefacL; AScalefacScale, APreflag, ASrIdx: Integer;
  out AOut: T576);

{ ISO 11172-3 Table B.6 — pre-emphasis table pretab[22] }
function QuantPretab(ASfb: Integer): Integer;

{ Return the first spectral line of scalefactor band ASfb (0..22).
  ASfb = QUANT_SFB_LMAX returns 576. }
function QuantSfbBand(ASrIdx, ASfb: Integer): Integer;

const
  QUANT_SFB_SMAX = 13;   { scalefactor bands for short blocks (per window) }

{ First line (0..192) of short-block scalefactor band ASfb (0..13) inside one
  window; ASfb = 13 returns 192 (ISO 11172-3 Table B.8). }
function QuantSfbShort(ASrIdx, ASfb: Integer): Integer;

implementation

uses
  System.Math;

// ---------------------------------------------------------------------------
// Scalefactor band boundaries (ISO 11172-3 Table B.8)
// ---------------------------------------------------------------------------

const
  { 23 entries per sample rate: band starts at sfb_band[i], ends at sfb_band[i+1]-1 }
  SFB_BAND: array[0..QUANT_SR_COUNT - 1, 0..QUANT_SFB_LMAX] of Integer = (
    // 44100 Hz
    (0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 52, 62,
     74, 90, 110, 134, 162, 196, 238, 288, 342, 418, 576),
    // 48000 Hz
    (0, 4, 8, 12, 16, 20, 24, 30, 36, 42, 50, 60,
     72, 88, 106, 128, 156, 190, 230, 276, 330, 384, 576),
    // 32000 Hz
    (0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 54, 66,
     82, 102, 126, 156, 194, 240, 296, 364, 448, 550, 576)
  );

  { ISO 11172-3 Table B.6: preemphasis (pretab[22]) }
  PRETAB: array[0..QUANT_SFB_LMAX - 1] of Integer =
    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
     1, 1, 1, 1, 2, 2, 3, 3, 3, 2, 0);

  { 0.0946 constant from ISO 11172-3 (quantizer rounding bias) }
  QUANT_BIAS = 0.4054;  // = 0.5 - 0.0946

// ---------------------------------------------------------------------------

procedure QuantInit(out AState: TQuantState);
var
  i: Integer;
begin
  FillChar(AState, SizeOf(AState), 0);
  for i := 1 to QUANT_POW43_MAX - 1 do
    AState.Pow43[i] := Power(i, 4.0 / 3.0);
  { AState.Pow43[0] = 0.0 already from FillChar }
end;

function QuantSfbForLine(ASrIdx, ALine: Integer): Integer;
var
  sfb: Integer;
begin
  for sfb := 0 to QUANT_SFB_LMAX - 1 do
    if ALine < SFB_BAND[ASrIdx][sfb + 1] then
      Exit(sfb);
  Result := QUANT_SFB_LMAX - 1;
end;

function QuantSfbAdj(AScalefacL, AScalefacScale, APreflag, APretab: Integer): Integer;
begin
  Result := -2 * (1 + AScalefacScale) * (AScalefacL + APreflag * APretab);
end;

function QuantizeLine(AXrAbs: Double; AGlobalGain, ASfbAdj: Integer): Integer;
var
  step: Double;
begin
  if AXrAbs = 0.0 then
    Exit(0);
  // ISO 11172-3: ix = nint( (|xr| / 2^((global_gain-210)/4))^(3/4) - 0.0946 )
  step := Power(2.0, (AGlobalGain - 210 + ASfbAdj) / 4.0);
  Result := Trunc(Power(AXrAbs / step, 0.75) + QUANT_BIAS);
end;

function DequantizeLine(const AState: TQuantState;
  AIx, AGlobalGain, ASfbAdj: Integer): Double;
var
  p43, gain: Double;
begin
  if AIx = 0 then
    Exit(0.0);
  if AIx < QUANT_POW43_MAX then
    p43 := AState.Pow43[AIx]
  else
    p43 := Power(AIx, 4.0 / 3.0);
  gain := Power(2.0, (AGlobalGain - 210 + ASfbAdj) / 4.0);
  Result := p43 * gain;
end;

function QuantizeBlock(const AState: TQuantState;
  const AXr: T576; AGlobalGain: Integer;
  const AScalefacL: TScalefacL; AScalefacScale, APreflag, ASrIdx: Integer;
  out AIx: T576Int): Integer;
var
  i, sfb, sfbAdj, ix, maxIx: Integer;
begin
  maxIx := 0;
  sfb   := 0;
  sfbAdj := QuantSfbAdj(AScalefacL[0], AScalefacScale, APreflag, PRETAB[0]);

  for i := 0 to QUANT_GRANULE - 1 do begin
    { Update sfb and its gain adjustment when we cross a band boundary }
    if (sfb < QUANT_SFB_LMAX - 1) and (i >= SFB_BAND[ASrIdx][sfb + 1]) then begin
      Inc(sfb);
      sfbAdj := QuantSfbAdj(AScalefacL[sfb], AScalefacScale, APreflag, PRETAB[sfb]);
    end;

    ix := QuantizeLine(Abs(AXr[i]), AGlobalGain, sfbAdj);
    AIx[i] := ix;
    if ix > maxIx then maxIx := ix;
  end;
  Result := maxIx;
end;

procedure DequantizeBlock(const AState: TQuantState;
  const AIx: T576Int; const AXr: T576;
  AGlobalGain: Integer;
  const AScalefacL: TScalefacL; AScalefacScale, APreflag, ASrIdx: Integer;
  out AOut: T576);
var
  i, sfb, sfbAdj: Integer;
  mag: Double;
begin
  sfb    := 0;
  sfbAdj := QuantSfbAdj(AScalefacL[0], AScalefacScale, APreflag, PRETAB[0]);

  for i := 0 to QUANT_GRANULE - 1 do begin
    if (sfb < QUANT_SFB_LMAX - 1) and (i >= SFB_BAND[ASrIdx][sfb + 1]) then begin
      Inc(sfb);
      sfbAdj := QuantSfbAdj(AScalefacL[sfb], AScalefacScale, APreflag, PRETAB[sfb]);
    end;

    mag := DequantizeLine(AState, Abs(AIx[i]), AGlobalGain, sfbAdj);  { AIx may be signed }
    { Restore sign from original xr }
    if AXr[i] < 0.0 then
      AOut[i] := -mag
    else
      AOut[i] := mag;
  end;
end;

function QuantPretab(ASfb: Integer): Integer;
begin
  if (ASfb >= 0) and (ASfb < QUANT_SFB_LMAX) then
    Result := PRETAB[ASfb]
  else
    Result := 0;
end;

const
  SFB_SHORT: array[0..QUANT_SR_COUNT - 1, 0..QUANT_SFB_SMAX] of Integer = (
    (0, 4, 8, 12, 16, 22, 30, 40, 52, 66, 84, 106, 136, 192),   { 44100 }
    (0, 4, 8, 12, 16, 22, 28, 38, 50, 64, 80, 100, 126, 192),   { 48000 }
    (0, 4, 8, 12, 16, 22, 30, 42, 58, 78, 104, 138, 180, 192)); { 32000 }

function QuantSfbShort(ASrIdx, ASfb: Integer): Integer;
begin
  if (ASrIdx < 0) or (ASrIdx >= QUANT_SR_COUNT) then ASrIdx := 0;
  if ASfb < 0 then ASfb := 0
  else if ASfb > QUANT_SFB_SMAX then ASfb := QUANT_SFB_SMAX;
  Result := SFB_SHORT[ASrIdx][ASfb];
end;

function QuantSfbBand(ASrIdx, ASfb: Integer): Integer;
begin
  if ASfb < 0 then ASfb := 0
  else if ASfb > QUANT_SFB_LMAX then ASfb := QUANT_SFB_LMAX;
  Result := SFB_BAND[ASrIdx][ASfb];
end;

end.
