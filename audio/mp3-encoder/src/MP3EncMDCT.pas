unit MP3EncMDCT;

{
  MP3EncMDCT.pas — Forward MDCT and aliasing reduction for MP3 Layer III

  Implements:
    - 36-point MDCT producing 18 frequency-domain coefficients (long blocks)
    - ISO 11172-3 Table B.9 aliasing reduction butterflies

  Reference: toots/shine l3mdct.c — translated to floating-point Delphi.
  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

const
  MDCT_SUBBANDS    = 32;
  MDCT_LONG_COEFS  = 18;  // spectral lines per band per granule
  MDCT_LONG_INPUT  = 36;  // time-domain samples per band (prev 18 + curr 18)

type
  { State block — initialise once per encoder session }
  TMDCTState = record
    { Combined window × MDCT kernel.
      cos_l[m][k] = sin(PI/36*(k+0.5)) * cos(PI/72*(2k+19)*(2m+1)) / 9 }
    CosL : array[0..MDCT_LONG_COEFS - 1,  0..MDCT_LONG_INPUT - 1]  of Double;
    CS   : array[0..7] of Double;   // aliasing-reduction scale coefficients
    CA   : array[0..7] of Double;   // aliasing-reduction cross coefficients
  end;

  { Input: 32 subbands × 36 time-domain samples (18 prev + 18 curr granule) }
  TMDCTInput  = array[0..MDCT_SUBBANDS - 1, 0..MDCT_LONG_INPUT - 1]  of Double;

  { Output: 32 subbands × 18 MDCT spectral coefficients }
  TMDCTOutput = array[0..MDCT_SUBBANDS - 1, 0..MDCT_LONG_COEFS - 1] of Double;

{ Compute CosL table and CS/CA aliasing-reduction coefficients. }
procedure MDCTInit(out AState: TMDCTState);

{ Forward MDCT + aliasing reduction for one granule.
  AIn[b][0..35]  : 36 subband samples per band b
  AOut[b][0..17] : 18 MDCT coefficients per band b (after antialias) }
procedure MDCTProcess(const AState: TMDCTState;
  const AIn: TMDCTInput; var AOut: TMDCTOutput);

implementation

uses
  System.Math;

const
  { Table B.9 aliasing reduction ci coefficients }
  CAlias: array[0..7] of Double = (
    -0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037
  );

procedure MDCTInit(out AState: TMDCTState);
var
  m, k, i: Integer;
  c: Double;
begin
  FillChar(AState, SizeOf(AState), 0);

  for m := 0 to MDCT_LONG_COEFS - 1 do
    for k := 0 to MDCT_LONG_INPUT - 1 do
      { The 1/9 (= 1/(N/4), N = 36) factor makes the forward transform the
        exact inverse of the unscaled ISO decoder IMDCT (dist10 mdct.c);
        without it every spectral line is 9x too large. }
      AState.CosL[m][k] :=
        Sin(Pi / 36.0 * (k + 0.5)) *
        Cos(Pi / 72.0 * (2 * k + 19) * (2 * m + 1)) / 9.0;

  for i := 0 to 7 do begin
    c := CAlias[i];
    AState.CS[i] := 1.0 / Sqrt(1.0 + c * c);
    AState.CA[i] := c  / Sqrt(1.0 + c * c);
  end;
end;

procedure MDCTProcess(const AState: TMDCTState;
  const AIn: TMDCTInput; var AOut: TMDCTOutput);
var
  b, m, k: Integer;
  v, hi, lo: Double;
begin
  { 36-point forward MDCT per band }
  for b := 0 to MDCT_SUBBANDS - 1 do
    for m := 0 to MDCT_LONG_COEFS - 1 do begin
      v := 0.0;
      for k := 0 to MDCT_LONG_INPUT - 1 do
        v := v + AIn[b][k] * AState.CosL[m][k];
      AOut[b][m] := v;
    end;

  { Aliasing-reduction butterflies (ISO 11172-3 §2.4.3.4)
    Butterfly between band b coefficient i and band b-1 coefficient 17-i }
  for b := 1 to MDCT_SUBBANDS - 1 do
    for k := 0 to 7 do begin
      hi := AOut[b][k];
      lo := AOut[b - 1][17 - k];
      AOut[b][k]          := hi * AState.CS[k] - lo * AState.CA[k];
      AOut[b - 1][17 - k] := lo * AState.CS[k] + hi * AState.CA[k];
    end;
end;

end.
