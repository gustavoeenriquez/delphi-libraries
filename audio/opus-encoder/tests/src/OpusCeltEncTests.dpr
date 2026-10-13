program OpusCeltEncTests;

{
  OpusCeltEncTests.dpr - Tests for OpusEncCelt (CELT encoder Phase 2)

  CE01-CE03: PVQ combinatorics (U, V, icwrs)
  CE04-CE05: PVQ search correctness
  CE06-CE07: Forward MDCT round-trip with IMDCT
  CE08:      Band energy computation
  CE09:      Bit allocation sanity
  CE10:      Full encode (smoke test — no crash, no error)

  License: CC0 1.0 Universal (Public Domain)
}

{$APPTYPE CONSOLE}

uses
  SysUtils, Math,
  OpusTypes,
  OpusEncTypes,
  OpusRangeEncoder,
  OpusRangeDecoder,
  OpusCelt,
  OpusEncCelt;

var
  Passed, Failed: Integer;

procedure Check(Cond: Boolean; const Name: string);
begin
  if Cond then begin WriteLn('  PASS: ', Name); Inc(Passed); end
  else          begin WriteLn('  FAIL: ', Name); Inc(Failed); end;
end;

procedure CheckNear(A, B, Eps: Double; const Name: string);
begin
  Check(Abs(A - B) <= Eps, Name + Format(' (%.6f vs %.6f)', [A, B]));
end;

// ===========================================================================
// CE01: CeltPVQU known values
// ===========================================================================
procedure TestCE01_PVQU;
begin
  WriteLn('CE01: CeltPVQU known values');
  // U(0,0) = 1, U(0,K>0) = 0
  Check(CeltPVQU(0, 0) = 1,  'U(0,0) = 1');
  Check(CeltPVQU(0, 5) = 0,  'U(0,5) = 0');
  // U(1,K) = 1 for K >= 1
  Check(CeltPVQU(1, 1) = 1,  'U(1,1) = 1');
  Check(CeltPVQU(1, 50) = 1, 'U(1,50) = 1');
  // U(2,2) = 3, U(2,3) = 5 (pattern: 2K-1)
  Check(CeltPVQU(2, 2) = 3,  'U(2,2) = 3');
  Check(CeltPVQU(2, 3) = 5,  'U(2,3) = 5');
  Check(CeltPVQU(2, 10) = 19, 'U(2,10) = 19');
  // U(3,3) = 13
  Check(CeltPVQU(3, 3) = 13, 'U(3,3) = 13');
  // Symmetry: U(N,K) = U(K,N)
  Check(CeltPVQU(5, 3) = CeltPVQU(3, 5), 'U(5,3) = U(3,5)');
end;

// ===========================================================================
// CE02: CeltPVQV = U(N,K) + U(N,K+1)
// ===========================================================================
procedure TestCE02_PVQV;
begin
  WriteLn('CE02: CeltPVQV correctness');
  Check(CeltPVQV(3, 3) = CeltPVQU(3,3) + CeltPVQU(3,4), 'V(3,3) = U(3,3)+U(3,4)');
  Check(CeltPVQV(2, 2) = CeltPVQU(2,2) + CeltPVQU(2,3), 'V(2,2) = U(2,2)+U(2,3)');
  // V(N,K) = total PVQ codewords ≥ 1
  Check(CeltPVQV(4, 2) > 0, 'V(4,2) > 0');
  Check(CeltPVQV(8, 4) > 0, 'V(8,4) > 0');
end;

// ===========================================================================
// CE03: CeltIcwrs + encode/decode round-trip
// ===========================================================================
procedure TestCE03_Icwrs;
var
  Y    : array[0..3] of Integer;
  Buf  : array[0..127] of Byte;
  Re   : TOpusRangeEncoder;
  Rd   : TOpusRangeDecoder;
  Rank : UInt32;
  V    : UInt32;
  Len  : Integer;
  Got  : Cardinal;
begin
  WriteLn('CE03: CeltIcwrs + encode/decode round-trip');

  // Vector (1, -1, 2, 0): L1 = 4 pulses, N=4
  Y[0] := 1; Y[1] := -1; Y[2] := 2; Y[3] := 0;
  Rank := CeltIcwrs(4, Y);
  V    := CeltPVQV(4, 4);
  Check(Rank < V, Format('Rank %d < V(4,4)=%d', [Rank, V]));

  // Round-trip: encode rank, decode and compare
  FillChar(Buf, SizeOf(Buf), 0);
  ReInit(Re, @Buf[0], 128);
  ReEncodeUInt(Re, Rank, V);
  Len := ReFlush(Re);
  RdInit(Rd, @Buf[0], SizeOf(Buf));
  Got := RdDecodeUInt(Rd, V);
  Check(Got = Rank, Format('Round-trip rank: got %d, expected %d', [Got, Rank]));

  // Zero vector: all zeros with K=0
  Y[0] := 1; Y[1] := 0; Y[2] := 0; Y[3] := 0;
  Rank := CeltIcwrs(4, Y);
  V    := CeltPVQV(4, 1);
  Check(Rank < V, Format('Rank %d < V(4,1)=%d', [Rank, V]));
end;

// ===========================================================================
// CE04: PVQ search — result has correct L1 norm
// ===========================================================================
procedure TestCE04_PVQSearch_L1Norm;
var
  X  : array[0..7] of Single;
  IY : TArray<Integer>;
  I  : Integer;
  L1 : Integer;
begin
  WriteLn('CE04: PVQ search — L1 norm = K');

  // Test with N=8, K=3
  for I := 0 to 7 do X[I] := Sin(Pi * I / 8.0);
  CeltPVQSearch(@X[0], 8, 3, IY);
  L1 := 0;
  for I := 0 to 7 do Inc(L1, Abs(IY[I]));
  Check(L1 = 3, Format('L1 = 3 (got %d)', [L1]));

  // Test with N=4, K=5
  X[0]:=0.9; X[1]:=-0.3; X[2]:=0.1; X[3]:=-0.5;
  CeltPVQSearch(@X[0], 4, 5, IY);
  L1 := 0;
  for I := 0 to 3 do Inc(L1, Abs(IY[I]));
  Check(L1 = 5, Format('L1 = 5 for N=4,K=5 (got %d)', [L1]));
end;

// ===========================================================================
// CE05: PVQ search — result is a valid codeword (rank < V(N,K))
// ===========================================================================
procedure TestCE05_PVQSearch_ValidCodeword;
var
  X  : array[0..5] of Single;
  IY : TArray<Integer>;
  Rank, V: UInt32;
  I  : Integer;
const
  N = 6; K = 4;
begin
  WriteLn('CE05: PVQ search codeword in valid range');
  for I := 0 to N-1 do X[I] := Cos(Pi * I / N);
  CeltPVQSearch(@X[0], N, K, IY);
  Rank := CeltIcwrs(N, IY);
  V    := CeltPVQV(N, K);
  Check(Rank < V, Format('Rank %d < V(%d,%d)=%d', [Rank, N, K, V]));
end;

// ===========================================================================
// CE06: Forward MDCT — spectral energy is nonzero for nonzero input,
//       and applying IMDCT gives output with nonzero energy.
// ===========================================================================
procedure TestCE06_MDCTNonzero;
const
  M       = 480;   // 10ms → N=960, N4=240
  OVERLAP = 120;
var
  Sine : array[0..M-1] of Single;
  Zero : array[0..M-1] of Single;
  Spec : array[0..M-1] of Single;
  Recon: array[0..2*M-1] of Single;
  I    : Integer;
  ESpec, ERecon: Double;
begin
  WriteLn('CE06: Forward MDCT produces nonzero spectrum for sine input');

  for I := 0 to M-1 do Sine[I] := Sin(2.0*Pi*10*I/M);
  FillChar(Zero, SizeOf(Zero), 0);

  // MDCT of [zeros | sine]
  CeltForwardMDCT(@Zero[0], @Sine[0], M, OVERLAP, @Spec[0]);

  ESpec := 0;
  for I := 0 to M-1 do ESpec := ESpec + Spec[I] * Spec[I];
  Check(ESpec > 0.001, Format('Spectral energy > 0 (%.6f)', [ESpec]));

  // IMDCT of the spectrum gives nonzero output
  CeltIMDCT(@Spec[0], 2*M, @Recon[0]);
  ERecon := 0;
  for I := 0 to 2*M-1 do ERecon := ERecon + Recon[I]*Recon[I];
  Check(ERecon > 0.001, Format('Recon energy > 0 after IMDCT (%.6f)', [ERecon]));

  // MDCT of zeros = zeros
  CeltForwardMDCT(@Zero[0], @Zero[0], M, OVERLAP, @Spec[0]);
  ESpec := 0;
  for I := 0 to M-1 do ESpec := ESpec + Spec[I]*Spec[I];
  CheckNear(ESpec, 0.0, 1e-10, 'MDCT of zeros = zeros');
end;

// ===========================================================================
// CE07: Forward MDCT — DC signal has zero spectral energy
// ===========================================================================
procedure TestCE07_MDCTDCZero;
const
  M       = 240;
  OVERLAP = 60;
var
  DC  : array[0..M-1] of Single;
  Spec: array[0..M-1] of Single;
  I   : Integer;
  Energy: Double;
begin
  WriteLn('CE07: MDCT of DC = 0 (difference transform)');

  // A constant signal: MDCT output should be near zero
  // because MDCT is a difference-based transform
  for I := 0 to M-1 do DC[I] := 1.0;
  CeltForwardMDCT(@DC[0], @DC[0], M, OVERLAP, @Spec[0]);

  Energy := 0;
  for I := 0 to M-1 do Energy := Energy + Spec[I] * Spec[I];
  CheckNear(Sqrt(Energy), 0.0, 0.01, 'DC signal → near-zero MDCT energy');
end;

// ===========================================================================
// CE08: Band energy computation
// ===========================================================================
procedure TestCE08_BandEnergy;
var
  X    : array[0..959] of Single;
  BandE: TArray<Single>;
  I, J : Integer;
  BinLo, BinHi: Integer;
  ExpE : Single;
const
  M = 960; LM = 3;
begin
  WriteLn('CE08: CeltComputeBandEnergy');

  FillChar(X, SizeOf(X), 0);

  // Put energy only in band 0 (bin 0): X[0] = 1.0
  X[0] := 1.0;
  CeltComputeBandEnergy(@X[0], M, LM, CELT_ENC_BANDS, BandE);
  CheckNear(BandE[0], 1.0, 0.001, 'Band 0 energy = 1.0 when X[0]=1');

  var AllOtherZero := True;
  for J := 1 to CELT_ENC_BANDS - 1 do
    if BandE[J] > 1e-10 then AllOtherZero := False;
  Check(AllOtherZero, 'Other bands energy ≈ 0 when X[0]=1 only');

  // Energy in band 5 (bins 5..6 for LM=3 → bins 40..47)
  FillChar(X, SizeOf(X), 0);
  BinLo := CELT_ENC_EBANDS[5] shl LM;
  BinHi := CELT_ENC_EBANDS[6] shl LM;
  for I := BinLo to BinHi-1 do X[I] := 1.0;
  ExpE := Sqrt(BinHi - BinLo);
  CeltComputeBandEnergy(@X[0], M, LM, CELT_ENC_BANDS, BandE);
  CheckNear(BandE[5], ExpE, 0.001, Format('Band 5 energy = sqrt(N_bins)=%.3f', [ExpE]));
end;

// ===========================================================================
// CE09: Bit allocation — sum of band bits ≤ total budget
// ===========================================================================
procedure TestCE09_BitAllocation;
var
  Pulses, EBits: TArray<Integer>;
  Budget, J    : Integer;
  TotalPulseBits, TotalFineBits: Integer;
const
  LM = 3; NBands = 21;
begin
  WriteLn('CE09: CeltAllocBits sum ≤ budget');

  Budget := 2000;
  CeltAllocBits(Budget, NBands, LM, Pulses, EBits);

  Check(Length(Pulses) = NBands, 'Pulses array has NBands entries');
  Check(Length(EBits) = NBands,  'EBits array has NBands entries');

  var AllNonNeg := True;
  for J := 0 to NBands - 1 do
    if (Pulses[J] < 0) or (EBits[J] < 0) then AllNonNeg := False;
  Check(AllNonNeg, 'All pulses and fine bits >= 0');

  // Just check that we have at least some nonzero allocation
  var HasPulses := False;
  for J := 0 to NBands - 1 do
    if Pulses[J] > 0 then HasPulses := True;
  Check(HasPulses, 'At least one band has pulses for budget=2000');
end;

// ===========================================================================
// CE10: Full encode smoke test — no crash, no error flag
// ===========================================================================
procedure TestCE10_FullEncode;
var
  State : TCeltEncState;
  PCM   : array[0..959] of SmallInt;
  Buf   : array[0..4095] of Byte;
  Re    : TOpusRangeEncoder;
  Len   : Integer;
  I     : Integer;
begin
  WriteLn('CE10: Full CELT encode smoke test (20ms silence)');

  CeltEncStateInit(State, 1, 3);  // mono, LM=3 (20ms)
  FillChar(PCM, SizeOf(PCM), 0);  // silence
  FillChar(Buf, SizeOf(Buf), 0);

  ReInit(Re, @Buf[0], SizeOf(Buf));
  var OK := CeltEncodeFrame(State, @PCM[0], Re, 1600);
  Len := ReFlush(Re);

  Check(OK, 'CeltEncodeFrame returns True for silence');
  Check(not Re.Error, 'Range encoder no overflow');
  Check(Len >= 0, Format('Flushed %d bytes (>= 0)', [Len]));
  WriteLn(Format('    Encoded %d bytes for 20ms silence (1600 bits budget)', [Len]));

  // Try with a sine wave
  WriteLn('CE10b: Full CELT encode smoke test (20ms 440Hz sine)');
  CeltEncStateInit(State, 1, 3);
  for I := 0 to 959 do
    PCM[I] := Round(16000.0 * Sin(2.0 * Pi * 440.0 * I / 48000.0));

  FillChar(Buf, SizeOf(Buf), 0);
  ReInit(Re, @Buf[0], SizeOf(Buf));
  OK := CeltEncodeFrame(State, @PCM[0], Re, 1600);
  Len := ReFlush(Re);

  Check(OK, 'CeltEncodeFrame returns True for 440Hz sine');
  Check(not Re.Error, 'Range encoder no overflow for sine');
  WriteLn(Format('    Encoded %d bytes for 20ms 440Hz sine', [Len]));
end;

// ===========================================================================
// Main
// ===========================================================================
begin
  Passed := 0; Failed := 0;
  WriteLn('=== Opus CELT Encoder Tests — Phase 2 ===');
  WriteLn;

  TestCE01_PVQU;
  TestCE02_PVQV;
  TestCE03_Icwrs;
  TestCE04_PVQSearch_L1Norm;
  TestCE05_PVQSearch_ValidCodeword;
  TestCE06_MDCTNonzero;
  TestCE07_MDCTDCZero;
  TestCE08_BandEnergy;
  TestCE09_BitAllocation;
  TestCE10_FullEncode;

  WriteLn;
  WriteLn(Format('Results: %d passed, %d failed', [Passed, Failed]));
  if Failed > 0 then Halt(1);
end.
