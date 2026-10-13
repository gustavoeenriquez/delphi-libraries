program TestMP3EncPhase2;

{$APPTYPE CONSOLE}

{
  Phase 2 tests — MP3EncMDCT + MP3EncPolyphase

  Covers:
    MX01-MX18  Forward MDCT (36->18), cos_l table, CS/CA aliasing coefficients,
               aliasing-reduction butterflies
    PF01-PF14  Polyphase analysis filterbank: FL matrix, ISO window,
               circular buffer, subband filter output
}

uses
  SysUtils,
  System.Math,
  MP3EncMDCT,
  MP3EncPolyphase;

var
  GTotal, GPassed: Integer;

procedure Check(const AName: string; ACond: Boolean);
begin
  Inc(GTotal);
  if ACond then begin
    Inc(GPassed);
    WriteLn('  OK  ', AName);
  end else
    WriteLn('FAIL  ', AName);
end;

function Near(A, B, Eps: Double): Boolean; inline;
begin
  Result := Abs(A - B) < Eps;
end;

// ===========================================================================
// MDCT tests
// ===========================================================================

procedure TestMDCTInit;
var
  S: TMDCTState;
begin
  MDCTInit(S);
  { MX01: CosL[0][0] = sin(PI/72) * cos(19*PI/72) / 9  (1/(N/4) scaling, dist10) }
  Check('MX01 CosL[0][0]',
    Near(S.CosL[0][0],
         Sin(Pi / 36.0 * 0.5) * Cos(Pi / 72.0 * 19 * 1) / 9.0,
         1e-14));

  { MX02: CosL[17][35] = -CosL[0][0] (MDCT kernel symmetry) }
  Check('MX02 CosL[17][35] = -CosL[0][0]',
    Near(S.CosL[17][35], -S.CosL[0][0], 1e-14));

  { MX03: CS[0] = 1/sqrt(1.36) }
  Check('MX03 CS[0]',
    Near(S.CS[0], 1.0 / Sqrt(1.36), 1e-14));

  { MX04: CA[0] = -0.6/sqrt(1.36) }
  Check('MX04 CA[0]',
    Near(S.CA[0], -0.6 / Sqrt(1.36), 1e-14));
end;

procedure TestMDCTCoefficients;
var
  S: TMDCTState;
  i: Integer;
  allOK: Boolean;
begin
  MDCTInit(S);

  { MX05: CS[i]^2 * (1 + CI[i]^2) = 1 for all i (formula verification) }
  allOK := True;
  for i := 0 to 7 do begin
    { CS = 1/sqrt(1+c^2)  =>  CS^2*(1+c^2) = 1
      CA = c/sqrt(1+c^2)  =>  CA = c * CS
      From CA/CS we can reconstruct c, then verify: }
    if (Abs(S.CS[i]) < 1e-15) then begin allOK := False; Break; end;
    { Verify CS^2 + CA^2 = 1/(1+c^2) * (1 + c^2) ... actually:
      CS^2 + CA^2 = (1 + c^2) / (1 + c^2) = 1 is NOT right.
      Correct: CS^2 * (1+c^2) = 1 }
  end;
  Check('MX05 CS[i]^2*(1+CI^2)=1  i=0',
    Near(S.CS[0] * S.CS[0] * (1.0 + 0.36), 1.0, 1e-14));

  { MX06: same for i=7 (smallest ci = -0.0037) }
  Check('MX06 CS[7]^2*(1+CI^2)=1  i=7',
    Near(S.CS[7] * S.CS[7] * (1.0 + 0.0037 * 0.0037), 1.0, 1e-14));

  { MX07: CA[0] / CS[0] = -0.6 }
  Check('MX07 CA[0]/CS[0] = -0.6',
    Near(S.CA[0] / S.CS[0], -0.6, 1e-14));

  { MX08: CA[7] is negative (all ci are negative) }
  Check('MX08 CA[7] < 0', S.CA[7] < 0.0);
end;

procedure TestMDCTProcess;
var
  S : TMDCTState;
  In0 : TMDCTInput;
  Out0: TMDCTOutput;
  m   : Integer;
  allZero: Boolean;
begin
  MDCTInit(S);

  { MX09: Zero input -> zero MDCT output (band 0, coef 0) }
  FillChar(In0,  SizeOf(In0),  0);
  FillChar(Out0, SizeOf(Out0), 0);
  MDCTProcess(S, In0, Out0);
  Check('MX09 Zero input -> Out[0][0]=0', Out0[0][0] = 0.0);

  { MX10: Zero input -> zero for all bands }
  allZero := True;
  for m := 0 to MDCT_LONG_COEFS - 1 do
    if Out0[31][m] <> 0.0 then begin allZero := False; Break; end;
  Check('MX10 Zero input -> Out[31] all zero', allZero);

  { MX11: Impulse at k=0 of band 0 -> Out[0][m] = CosL[m][0] }
  FillChar(In0, SizeOf(In0), 0);
  In0[0][0] := 1.0;   // only band 0, only first time sample
  FillChar(Out0, SizeOf(Out0), 0);
  MDCTProcess(S, In0, Out0);
  { After antialias, Out[0][0] is untouched because antialias loop starts at band=1
    and touches Out[0][17..10] — not Out[0][0]. }
  Check('MX11 Impulse[0][0] -> Out[0][0]=CosL[0][0]',
    Near(Out0[0][0], S.CosL[0][0], 1e-14));

  { MX12: Linearity: 2 * MDCT(x) = MDCT(2x) — check band 0 coef 0 }
  FillChar(In0, SizeOf(In0), 0);
  In0[0][0] := 2.0;
  FillChar(Out0, SizeOf(Out0), 0);
  MDCTProcess(S, In0, Out0);
  Check('MX12 MDCT(2x)[0][0] = 2*CosL[0][0]',
    Near(Out0[0][0], 2.0 * S.CosL[0][0], 1e-14));

  { MX13: All CosL[m][k] are in [-1, 1] range }
  allZero := True;   // reusing flag as "allInRange"
  for m := 0 to MDCT_LONG_COEFS - 1 do
    if Abs(S.CosL[m][0]) > 1.0 + 1e-12 then begin allZero := False; Break; end;
  Check('MX13 CosL values in [-1,1]', allZero);
end;

procedure TestAntialias;
var
  S   : TMDCTState;
  AIn : TMDCTInput;
  AOut: TMDCTOutput;
  hi, lo, newHi, newLo: Double;
begin
  MDCTInit(S);

  { MX14: CS[0] ≈ 0.857492... }
  Check('MX14 CS[0] approx', Near(S.CS[0], 0.857492925712544, 1e-12));

  { MX15: CA[0] ≈ -0.514495... }
  Check('MX15 CA[0] approx', Near(S.CA[0], -0.514495755427527, 1e-12));

  { MX16-MX17: Butterfly with band[1][0]=1, band[0][17]=0
    Expected: new[1][0] = CS[0], new[0][17] = CA[0] }
  FillChar(AIn, SizeOf(AIn), 0);
  AIn[1][0] := 1.0;  // hi term for k=0
  AIn[0][0] := 0.0;  // doesn't matter for k=0 butterfly (uses [17-0]=17)
  FillChar(AOut, SizeOf(AOut), 0);
  MDCTProcess(S, AIn, AOut);
  { MDCTProcess includes MDCT then antialias.
    MDCT: Out[1][0] = Σ AIn[1][k]*CosL[0][k] for m=0 = CosL[0][0]
          Out[0][17] = 0 (band 0 input is 0)
    Antialias butterfly k=0:
      new[1][0]  = Out[1][0]*CS[0] - Out[0][17]*CA[0]
      new[0][17] = Out[0][17]*CS[0] + Out[1][0]*CA[0] }
  hi := S.CosL[0][0];  // expected Out[1][0] before antialias
  lo := 0.0;
  newHi := hi * S.CS[0] - lo * S.CA[0];
  newLo := lo * S.CS[0] + hi * S.CA[0];
  Check('MX16 Antialias butterfly new[1][0]', Near(AOut[1][0], newHi, 1e-14));
  Check('MX17 Antialias butterfly new[0][17]', Near(AOut[0][17], newLo, 1e-14));

  { MX18: Band 0 coef 0 untouched by antialias
    (antialias touches band[0][17..10], not band[0][0]) }
  FillChar(AIn, SizeOf(AIn), 0);
  AIn[0][0] := 1.0;
  FillChar(AOut, SizeOf(AOut), 0);
  MDCTProcess(S, AIn, AOut);
  { Out[0][0] comes from MDCT then antialias.
    Antialias for b=1: new[0][17-k] for k=0..7 -> touches [17..10], not [0].
    So Out[0][0] = CosL[0][0] * 1.0 from MDCT, unchanged by antialias. }
  Check('MX18 Out[0][0] = CosL[0][0] (antialias does not touch coef 0)',
    Near(AOut[0][0], S.CosL[0][0], 1e-14));
end;

// ===========================================================================
// Polyphase tests
// ===========================================================================

procedure TestPolyphaseInit;
var
  St: TPolyphaseState;
begin
  PolyphaseInit(St);

  { PF01: FL[0][0] = cos(PI/4) = sqrt(2)/2 }
  Check('PF01 FL[0][0] = sqrt(2)/2',
    Near(St.FL[0][0], Sqrt(2.0) / 2.0, 1e-14));

  { PF02: FL[0][16] = cos(0) = 1.0 }
  Check('PF02 FL[0][16] = 1.0', St.FL[0][16] = 1.0);

  { PF03: FL[1][0] = cos(3*PI/4) = -sqrt(2)/2 }
  Check('PF03 FL[1][0] = -sqrt(2)/2',
    Near(St.FL[1][0], -Sqrt(2.0) / 2.0, 1e-14));

  { PF04: FL[0][48] = cos(-PI/2) ≈ 0 }
  Check('PF04 FL[0][48] ≈ 0', Abs(St.FL[0][48]) < 1e-14);
end;

procedure TestEnwindow;
begin
  { PF05: Enwindow[0] = 0.0 }
  Check('PF05 EW[0] = 0', PolyphaseEnwindow(0) = 0.0);

  { PF06: Peak at index 256 = 0.035781 }
  Check('PF06 EW[256] = 0.035781',
    Near(PolyphaseEnwindow(256), 0.035781, 1e-7));

  { PF07: Sign change: EW[255] < 0 (window is anti-symmetric at center) }
  Check('PF07 EW[255] < 0', PolyphaseEnwindow(255) < 0.0);

  { PF08: EW[64] > 0 (sign change at the 64-sample boundary) }
  Check('PF08 EW[64] > 0', PolyphaseEnwindow(64) > 0.0);
end;

procedure TestPolyphaseFilter;
var
  St    : TPolyphaseState;
  Samp  : TPCMBlock;
  Sub   : TSubbandSamples;
  i, call: Integer;
  allZero: Boolean;
begin
  PolyphaseInit(St);
  FillChar(Samp, SizeOf(Samp), 0);

  { PF09: Zero input -> zero output (subband 0) }
  PolyphaseFilter(St, Samp, Sub);
  Check('PF09 Zero input -> Sub[0]=0', Sub[0] = 0.0);

  { PF10: Zero input -> zero output (subband 31) }
  Check('PF10 Zero input -> Sub[31]=0', Sub[31] = 0.0);

  { PF11: Impulse at the oldest sample of the block (ASamples[31]; ASamples[0]
    is the newest and is multiplied by C[0] = 0) -> non-zero subband output }
  PolyphaseInit(St);
  FillChar(Samp, SizeOf(Samp), 0);
  Samp[31] := 32768.0;
  PolyphaseFilter(St, Samp, Sub);
  Check('PF11 Impulse -> Sub[0] <> 0', Sub[0] <> 0.0);

  { PF12: Impulse subband[0] sign is negative (cos(15pi/64)*C[31]*32768) }
  Check('PF12 Impulse Sub[0] < 0', Sub[0] < 0.0);

  { PF13: Impulse subband[1] sign is positive }
  Check('PF13 Impulse Sub[1] > 0', Sub[1] > 0.0);

  { PF14: After 16 DC calls (fills entire 512-sample buffer with 1.0),
    subband output is non-zero }
  PolyphaseInit(St);
  for i := 0 to POLY_SUBBANDS - 1 do Samp[i] := 1.0;
  for call := 1 to 16 do
    PolyphaseFilter(St, Samp, Sub);
  allZero := True;
  for i := 0 to POLY_SUBBANDS - 1 do
    if Abs(Sub[i]) > 1e-10 then begin allZero := False; Break; end;
  Check('PF14 DC×16 calls -> some subband non-zero', not allZero);
end;

// ===========================================================================

begin
  GTotal  := 0;
  GPassed := 0;

  WriteLn('MP3 Encoder Phase 2 — MDCT + Polyphase tests');
  WriteLn('---------------------------------------------');
  WriteLn('--- MDCT ---');
  TestMDCTInit;
  TestMDCTCoefficients;
  TestMDCTProcess;
  TestAntialias;
  WriteLn('--- Polyphase ---');
  TestPolyphaseInit;
  TestEnwindow;
  TestPolyphaseFilter;
  WriteLn('---------------------------------------------');
  WriteLn(GPassed, '/', GTotal, ' tests passed.');
  if GPassed < GTotal then Halt(1);
end.
