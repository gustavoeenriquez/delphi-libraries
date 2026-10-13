program TestMP3EncPhase3;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Math,
  MP3EncQuantize;

var
  GTotal  : Integer = 0;
  GPassed : Integer = 0;

procedure Check(const AName: string; ACond: Boolean);
begin
  Inc(GTotal);
  if ACond then begin
    Inc(GPassed);
    WriteLn('  PASS  ', AName);
  end else
    WriteLn('  FAIL  ', AName);
end;

function Near(A, B, Eps: Double): Boolean;
begin
  Result := Abs(A - B) < Eps;
end;

var
  State  : TQuantState;
  Xr     : T576;
  Ix     : T576Int;
  XrOut  : T576;
  SfL    : TScalefacL;
  maxIx  : Integer;

begin
  QuantInit(State);
  WriteLn('=== MP3EncQuantize Phase 3 ===');

  { -------- QI: Pow43 table -------- }
  WriteLn;
  WriteLn('--- QuantInit / Pow43 ---');
  Check('QI01 Pow43[0] = 0',    Near(State.Pow43[0], 0.0, 1e-12));
  Check('QI02 Pow43[1] = 1',    Near(State.Pow43[1], 1.0, 1e-12));
  { 8^(4/3) = (2^3)^(4/3) = 2^4 = 16 }
  Check('QI03 Pow43[8] = 16',   Near(State.Pow43[8], 16.0, 1e-9));
  { 27^(4/3) = (3^3)^(4/3) = 3^4 = 81 }
  Check('QI04 Pow43[27] = 81',  Near(State.Pow43[27], 81.0, 1e-6));
  Check('QI05 Pow43 monotone',  State.Pow43[100] < State.Pow43[200]);
  Check('QI06 Pow43[1000]',     Near(State.Pow43[1000], Power(1000.0, 4.0/3.0), 1e-6));

  { -------- PT: QuantPretab -------- }
  WriteLn;
  WriteLn('--- QuantPretab ---');
  Check('PT01 pretab[0]  = 0', QuantPretab(0)  = 0);
  Check('PT02 pretab[10] = 0', QuantPretab(10) = 0);
  Check('PT03 pretab[11] = 1', QuantPretab(11) = 1);
  Check('PT04 pretab[15] = 2', QuantPretab(15) = 2);
  Check('PT05 pretab[17] = 3', QuantPretab(17) = 3);
  Check('PT06 pretab[20] = 2', QuantPretab(20) = 2);
  Check('PT07 pretab[21] = 0', QuantPretab(21) = 0);
  Check('PT08 pretab OOB= 0',  QuantPretab(99) = 0);

  { -------- SA: QuantSfbAdj -------- }
  WriteLn;
  WriteLn('--- QuantSfbAdj ---');
  { -2*(1+0)*(0+0*0) = 0 }
  Check('SA01 (0,0,0,0)=  0', QuantSfbAdj(0, 0, 0, 0) =   0);
  { -2*(1+0)*(2+0*0) = -4 }
  Check('SA02 (2,0,0,0)= -4', QuantSfbAdj(2, 0, 0, 0) =  -4);
  { -2*(1+1)*(1+0*0) = -4 }
  Check('SA03 (1,1,0,0)= -4', QuantSfbAdj(1, 1, 0, 0) =  -4);
  { -2*(1+0)*(0+1*1) = -2 }
  Check('SA04 (0,0,1,1)= -2', QuantSfbAdj(0, 0, 1, 1) =  -2);
  { -2*(1+1)*(3+1*2) = -2*2*5 = -20 }
  Check('SA05 (3,1,1,2)=-20', QuantSfbAdj(3, 1, 1, 2) = -20);

  { -------- SF: QuantSfbForLine -------- }
  WriteLn;
  WriteLn('--- QuantSfbForLine ---');
  { 44100 Hz: SFB_BAND[0]=(0,4,8,12,...,74,90,...) }
  Check('SF01 44100 line  0 →  0', QuantSfbForLine(0,   0) =  0);
  Check('SF02 44100 line  3 →  0', QuantSfbForLine(0,   3) =  0);
  Check('SF03 44100 line  4 →  1', QuantSfbForLine(0,   4) =  1);
  { [62,74) → sfb 11; [74,90) → sfb 12 }
  Check('SF04 44100 line 63 → 11', QuantSfbForLine(0,  63) = 11);
  Check('SF05 44100 line 89 → 12', QuantSfbForLine(0,  89) = 12);
  Check('SF06 44100 line575 → 21', QuantSfbForLine(0, 575) = 21);
  { 48000 Hz: same low-band boundaries }
  Check('SF07 48000 line  4 →  1', QuantSfbForLine(1,   4) =  1);
  { 32000 Hz: SFB_BAND[2][9]=44, SFB_BAND[2][10]=54 → line 50 → sfb 9 }
  Check('SF08 32000 line 50 →  9', QuantSfbForLine(2,  50) =  9);

  { -------- QL: QuantizeLine -------- }
  WriteLn;
  WriteLn('--- QuantizeLine ---');
  { zero input → always 0 }
  Check('QL01 0.0        → 0', QuantizeLine(0.0,  210, 0) = 0);
  { step=1: floor(1^0.75 + 0.4054) = floor(1.4054) = 1 }
  Check('QL02 1.0        → 1', QuantizeLine(1.0,  210, 0) = 1);
  { 2^0.75 ≈ 1.6818; +0.4054 = 2.0872 → 2 }
  Check('QL03 2.0        → 2', QuantizeLine(2.0,  210, 0) = 2);
  { global_gain=206 → step=2^(-1)=0.5; 1.0/0.5+0.4054=2.4054 → 2 }
  Check('QL04 1.0 g=206  → 2', QuantizeLine(1.0,  206, 0) = 2);
  { sfbAdj=-4 → step=0.5; (1.5/0.5)^0.75 = 3^0.75 ≈ 2.2795; +0.4054 ≈ 2.685 → 2 }
  Check('QL05 1.5 adj=-4 → 2', QuantizeLine(1.5,  210,-4) = 2);
  { sfbAdj= 0 → step=1.0; 1.5^0.75≈1.3552; +0.4054≈1.761 → 1 }
  Check('QL06 1.5 adj= 0 → 1', QuantizeLine(1.5,  210, 0) = 1);
  { 16^0.75 = (2^4)^0.75 = 2^3 = 8; floor(8+0.4054)=8 }
  Check('QL07 16.0       → 8', QuantizeLine(16.0, 210, 0) = 8);

  { -------- DQ: DequantizeLine -------- }
  WriteLn;
  WriteLn('--- DequantizeLine ---');
  { ix=0 → 0 regardless of gain }
  Check('DQ01 ix=0  → 0.0',
        Near(DequantizeLine(State, 0, 210, 0), 0.0, 1e-12));
  { 1^(4/3) * 2^0 = 1.0 }
  Check('DQ02 ix=1  → 1.0',
        Near(DequantizeLine(State, 1, 210, 0), 1.0, 1e-9));
  { 8^(4/3) * 1 = 16.0 }
  Check('DQ03 ix=8  → 16.0',
        Near(DequantizeLine(State, 8, 210, 0), 16.0, 1e-9));
  { gain=214 → factor=2^1=2; 1^(4/3)*2 = 2.0 }
  Check('DQ04 ix=1 g=214 → 2.0',
        Near(DequantizeLine(State, 1, 214, 0), 2.0, 1e-9));
  { 2^(4/3) — table value must match Power() }
  Check('DQ05 ix=2  → 2^(4/3)',
        Near(DequantizeLine(State, 2, 210, 0), Power(2.0, 4.0/3.0), 1e-9));

  { -------- QB: QuantizeBlock / DequantizeBlock -------- }
  WriteLn;
  WriteLn('--- QuantizeBlock / DequantizeBlock ---');

  { All-zero block → maxIx = 0, all ix = 0 }
  FillChar(Xr,  SizeOf(Xr),  0);
  FillChar(SfL, SizeOf(SfL), 0);
  maxIx := QuantizeBlock(State, Xr, 210, SfL, 0, 0, 0, Ix);
  Check('QB01 all-zero maxIx=0',   maxIx = 0);
  Check('QB02 all-zero Ix[0]=0',   Ix[0] = 0);
  Check('QB03 all-zero Ix[575]=0', Ix[575] = 0);

  { Single non-zero coefficient at line 100 }
  Xr[100] := 16.0;
  maxIx := QuantizeBlock(State, Xr, 210, SfL, 0, 0, 0, Ix);
  Check('QB04 Ix[100]=8',   Ix[100] = 8);
  Check('QB05 maxIx=8',     maxIx = 8);
  Check('QB06 Ix[50]=0',    Ix[50]  = 0);

  { Dequantize: roundtrip on ix=8 must recover 16.0 }
  DequantizeBlock(State, Ix, Xr, 210, SfL, 0, 0, 0, XrOut);
  Check('QB07 dequant[100]=16.0', Near(XrOut[100], 16.0, 1e-9));
  Check('QB08 dequant[50]=0.0',   Near(XrOut[50],   0.0, 1e-9));

  { Negative coefficient: sign must be restored by dequantizer }
  FillChar(Xr, SizeOf(Xr), 0);
  Xr[300] := -16.0;
  maxIx := QuantizeBlock(State, Xr, 210, SfL, 0, 0, 0, Ix);
  DequantizeBlock(State, Ix, Xr, 210, SfL, 0, 0, 0, XrOut);
  Check('QB09 negative sign',     XrOut[300] < 0.0);
  Check('QB10 negative mag=16.0', Near(Abs(XrOut[300]), 16.0, 1e-9));

  { scalefac_scale=1, scalefac_l[1]=2: adj = -2*(1+1)*(2+0) = -8
    → step = 2^(-2) = 0.25; (1.0/0.25)^0.75 + 0.4054 = 2.828 + 0.4054 → ix=3 }
  FillChar(Xr, SizeOf(Xr), 0);
  Xr[4] := 1.0;
  SfL[1] := 2;
  maxIx := QuantizeBlock(State, Xr, 210, SfL, 1, 0, 0, Ix);
  Check('QB11 scalefac_scale Ix[4]=3', Ix[4] = 3);

  WriteLn;
  WriteLn(Format('=== %d / %d passed ===', [GPassed, GTotal]));
  if GPassed < GTotal then
    ExitCode := 1;
end.
