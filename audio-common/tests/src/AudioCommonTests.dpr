program AudioCommonTests;

{
  AudioCommonTests.dpr - Console test runner for audio-common

  Tests:
    1. AudioBitReader — MSB-first and LSB-first extraction
    2. AudioSampleConv — round-trip conversions
    3. AudioCRC — CRC-8, CRC-16, CRC-32 known-good vectors

  Run as a console application. Prints PASS/FAIL per test.
  Exit code 0 = all passed, 1 = any failed.

  License: CC0 1.0 Universal (Public Domain)
}

{$APPTYPE CONSOLE}

uses
  SysUtils,
  AudioTypes     in '..\..\src\AudioTypes.pas',
  AudioBitReader in '..\..\src\AudioBitReader.pas',
  AudioSampleConv in '..\..\src\AudioSampleConv.pas',
  AudioCRC       in '..\..\src\AudioCRC.pas';

var
  GFailed: Boolean = False;

procedure Pass(const Name: string);
begin
  Writeln('  PASS  ', Name);
end;

procedure Fail(const Name, Detail: string);
begin
  Writeln('  FAIL  ', Name, '  — ', Detail);
  GFailed := True;
end;

procedure Check(Cond: Boolean; const Name, Detail: string);
begin
  if Cond then Pass(Name) else Fail(Name, Detail);
end;

// ---------------------------------------------------------------------------
// BitReader tests
// ---------------------------------------------------------------------------

procedure TestBitReaderMSB;
var
  Data: array[0..3] of Byte;
  Br: TAudioBitReader;
  V: Cardinal;
begin
  Writeln('--- AudioBitReader (MSB-first) ---');

  // Data: $A5 $C3 = 1010_0101  1100_0011
  Data[0] := $A5;
  Data[1] := $C3;
  Data[2] := $00;
  Data[3] := $00;

  BrInit(Br, @Data[0], 4, boMSBFirst);

  // First bit = 1
  V := BrRead(Br, 1);
  Check(V = 1, 'MSB bit0 = 1', Format('got %d', [V]));

  // Next 3 bits = 010
  V := BrRead(Br, 3);
  Check(V = 2, 'MSB bits 1-3 = 010', Format('got %d', [V]));

  // Next 4 bits = 0101
  V := BrRead(Br, 4);
  Check(V = 5, 'MSB bits 4-7 = 0101', Format('got %d', [V]));

  // Now in second byte $C3 = 1100_0011
  V := BrRead(Br, 8);
  Check(V = $C3, 'MSB byte1 = $C3', Format('got $%X', [V]));

  Check(BrBitsLeft(Br) = 16, 'bits left = 16', Format('got %d', [BrBitsLeft(Br)]));
end;

procedure TestBitReaderLSB;
var
  Data: array[0..1] of Byte;
  Br: TAudioBitReader;
  V: Cardinal;
begin
  Writeln('--- AudioBitReader (LSB-first) ---');

  // $6B = 0110_1011  → LSB-first: bits 0..7 = 1,1,0,1,0,1,1,0
  Data[0] := $6B;
  Data[1] := $00;

  BrInit(Br, @Data[0], 2, boLSBFirst);

  V := BrRead(Br, 4);  // bits 0-3: 1011 = 0xB = 11
  Check(V = $B, 'LSB nibble0 = $B', Format('got $%X', [V]));

  V := BrRead(Br, 4);  // bits 4-7: 0110 = 6
  Check(V = 6, 'LSB nibble1 = 6', Format('got %d', [V]));
end;

procedure TestBitReaderUnary;
var
  Data: array[0..1] of Byte;
  Br: TAudioBitReader;
  V: Cardinal;
begin
  Writeln('--- BrReadUnary ---');

  // $0E = 0000_1110 → MSB-first: 0 0 0 0 1 ...
  // Unary should return 4 (four leading zeros before the 1)
  Data[0] := $0E;
  Data[1] := $FF;
  BrInit(Br, @Data[0], 2, boMSBFirst);

  V := BrReadUnary(Br);
  Check(V = 4, 'Unary $0E = 4', Format('got %d', [V]));

  // After unary(4), Pos = 5. Next 3 bits of $0E = 110 = 6
  V := BrRead(Br, 3);
  Check(V = 6, 'Bits after unary = 110', Format('got %d', [V]));
end;

procedure TestBitReaderAlign;
var
  Data: array[0..1] of Byte;
  Br: TAudioBitReader;
begin
  Writeln('--- BrByteAlign ---');

  Data[0] := $FF;
  Data[1] := $FF;
  BrInit(Br, @Data[0], 2, boMSBFirst);

  BrSkip(Br, 3);
  BrByteAlign(Br);
  Check(BrBytePos(Br) = 1, 'Align after 3 bits → byte 1', Format('got %d', [BrBytePos(Br)]));

  BrByteAlign(Br);  // already aligned
  Check(BrBytePos(Br) = 1, 'Align on boundary is no-op', Format('got %d', [BrBytePos(Br)]));
end;

procedure TestBitReaderPeekSkip;
var
  Data: array[0..1] of Byte;
  Br: TAudioBitReader;
  V: Cardinal;
begin
  Writeln('--- BrPeek / BrSkip ---');

  // $B4 = 1011_0100
  Data[0] := $B4;
  Data[1] := $00;
  BrInit(Br, @Data[0], 2, boMSBFirst);

  // Peek 4 bits = 1011 = $B; position must not advance
  V := BrPeek(Br, 4);
  Check(V = $B, 'Peek 4 bits = $B', Format('got $%X', [V]));
  Check(BrBitsLeft(Br) = 16, 'Position unchanged after peek', Format('bits left = %d', [BrBitsLeft(Br)]));

  // Skip 4 bits, then read remaining nibble = 0100 = 4
  BrSkip(Br, 4);
  V := BrRead(Br, 4);
  Check(V = 4, 'After skip 4: next 4 bits = 4', Format('got %d', [V]));

  // BrEOF: consume remaining 8 bits, then check EOF
  BrSkip(Br, 8);
  Check(BrEOF(Br), 'EOF after consuming all bits', '');
end;

procedure TestBitReaderSigned;
var
  Data: array[0..0] of Byte;
  Br: TAudioBitReader;
  V: Integer;
begin
  Writeln('--- BrReadSignedMSB ---');

  // $F0 = 1111_0000
  Data[0] := $F0;
  BrInit(Br, @Data[0], 1, boMSBFirst);

  // Read 4 bits signed: 1111 = -1 (two's complement)
  V := BrReadSignedMSB(Br, 4);
  Check(V = -1, 'Signed 4-bit 1111 = -1', Format('got %d', [V]));

  // Read 4 bits signed: 0000 = 0
  V := BrReadSignedMSB(Br, 4);
  Check(V = 0, 'Signed 4-bit 0000 = 0', Format('got %d', [V]));
end;

procedure TestBitReaderLSBExtended;
var
  Data: array[0..1] of Byte;
  Br: TAudioBitReader;
  V: Cardinal;
begin
  Writeln('--- BrReadLSB cross-byte ---');

  // $B4 $0A = 1011_0100  0000_1010
  // LSB-first: bit stream = 0,0,1,0,1,1,0,1,  0,1,0,1,0,0,0,0
  Data[0] := $B4;  // = 0010 1101 in LSB order: bits 0-7 = 0,0,1,0,1,1,0,1
  Data[1] := $0A;  // bits 8-15 = 0,1,0,1,0,0,0,0
  BrInit(Br, @Data[0], 2, boLSBFirst);

  // Read 10 bits LSB: bits 0-9 = 00101101_01 = value?
  // $B4 low nibble LSB = 0100 = 4, high nibble LSB = 1011 → read 10 bits
  // bits 0..9 from $B4 $0A LSB-first: B4=1011_0100 → bit0=0,bit1=0,bit2=1,bit3=0,bit4=1,bit5=1,bit6=0,bit7=1
  // $0A=0000_1010 → bit8=0,bit9=1
  // 10-bit value LSB: bit0 + bit1*2 + ... = 0+0+4+0+16+32+0+128+0+512 = 692
  V := BrRead(Br, 10);
  Check(V = 692, 'LSB 10 bits cross-byte = 692', Format('got %d', [V]));
end;

procedure TestBitReaderReset;
var
  Data: array[0..0] of Byte;
  Br: TAudioBitReader;
  V: Cardinal;
begin
  Writeln('--- BrReset ---');

  Data[0] := $A5;
  BrInit(Br, @Data[0], 1, boMSBFirst);

  BrSkip(Br, 4);
  Check(BrBitsLeft(Br) = 4, 'After skip 4: 4 bits left', Format('got %d', [BrBitsLeft(Br)]));

  BrReset(Br, @Data[0], 1);
  Check(BrBitsLeft(Br) = 8, 'After Reset: 8 bits left', Format('got %d', [BrBitsLeft(Br)]));

  V := BrRead(Br, 8);
  Check(V = $A5, 'After Reset reads full byte', Format('got $%X', [V]));
end;

procedure TestRiceCoding;
var
  // Manually encoded Rice(2) values for known signed integers.
  // Rice(k=2): unsigned = zig-zag(signed). quotient in unary, then 2 bits remainder.
  // signed 0 → unsigned 0 → Q=0, R=00 → bits: 1 00
  // signed 1 → unsigned 2 → Q=0, R=10 → bits: 1 10
  // signed -1 → unsigned 1 → Q=0, R=01 → bits: 1 01
  // signed 2 → unsigned 4 → Q=1, R=00 → bits: 0 1 00
  // Packed into bytes (MSB-first):
  // [1][00][1][10][1][01][0 1][00] ...
  //  1 00 1 10 1 01 01 00  = 1001 1010 1010 0...
  //  = $9A $A0
  Data: array[0..1] of Byte;
  Br: TAudioBitReader;
  V: Integer;
begin
  Writeln('--- BrReadRiceSigned ---');

  Data[0] := $9A;  // 1001 1010
  Data[1] := $A0;  // 1010 0000

  BrInit(Br, @Data[0], 2, boMSBFirst);

  V := BrReadRiceSigned(Br, 2);
  Check(V = 0,  'Rice(2) → 0',  Format('got %d', [V]));

  V := BrReadRiceSigned(Br, 2);
  Check(V = 1,  'Rice(2) → 1',  Format('got %d', [V]));

  V := BrReadRiceSigned(Br, 2);
  Check(V = -1, 'Rice(2) → -1', Format('got %d', [V]));

  V := BrReadRiceSigned(Br, 2);
  Check(V = 2,  'Rice(2) → 2',  Format('got %d', [V]));
end;

// ---------------------------------------------------------------------------
// SampleConv tests
// ---------------------------------------------------------------------------

procedure TestSampleConv;
const
  Eps = 0.0001;

  function Near(A, B: Single): Boolean;
  begin
    Result := Abs(A - B) < Eps;
  end;

begin
  Writeln('--- AudioSampleConv ---');

  Check(Near(SampleInt16ToFloat(0),      0.0),   'Int16 0 → 0.0',  '');
  Check(Near(SampleInt16ToFloat(32767),  1.0),   'Int16 max → ~1', '');
  Check(Near(SampleInt16ToFloat(-32768), -1.0),  'Int16 min → -1', '');

  Check(Near(SampleInt8ToFloat(0),    0.0),  'Int8 0 → 0.0', '');
  Check(Near(SampleInt8ToFloat(127),  0.9922), 'Int8 127 → ~1', '');
  Check(Near(SampleInt8ToFloat(-128), -1.0), 'Int8 -128 → -1', '');

  Check(Near(SampleUInt8ToFloat(128), 0.0),  'UInt8 128 → 0.0', '');
  Check(Near(SampleUInt8ToFloat(0),  -1.0),  'UInt8 0 → -1.0', '');
  Check(Near(SampleUInt8ToFloat(255),  0.9922), 'UInt8 255 → ~1', '');

  Check(SampleFloatToInt16(1.0) = 32767,  'Float 1.0 → Int16 32767',  '');
  Check(SampleFloatToInt16(-1.0) = -32768, 'Float -1.0 → Int16 -32768', '');
  Check(SampleFloatToInt16(0.0) = 0,       'Float 0.0 → Int16 0',       '');

  Check(SampleFloatToUInt8(0.0) = 128, 'Float 0.0 → UInt8 128', '');
  Check(SampleFloatToUInt8(-1.0) = 0,  'Float -1.0 → UInt8 0',  '');

  // Int24 round-trip
  var P: array[0..2] of Byte;
  SampleFloatToInt24(0.5, @P[0]);
  var Back: Single := SampleInt24ToFloat(@P[0]);
  Check(Near(Back, 0.5), 'Int24 round-trip 0.5', Format('got %f', [Back]));

  SampleFloatToInt24(-0.5, @P[0]);
  Back := SampleInt24ToFloat(@P[0]);
  Check(Near(Back, -0.5), 'Int24 round-trip -0.5', Format('got %f', [Back]));

  SampleFloatToInt24(0.0, @P[0]);
  Back := SampleInt24ToFloat(@P[0]);
  Check(Near(Back, 0.0), 'Int24 round-trip 0.0', Format('got %f', [Back]));
end;

procedure TestSampleConvExtended;
const
  Eps = 0.0001;

  function Near(A, B: Single): Boolean;
  begin
    Result := Abs(A - B) < Eps;
  end;

begin
  Writeln('--- AudioSampleConv extended ---');

  // Int32
  Check(Near(SampleInt32ToFloat(0),           0.0),   'Int32 0 → 0.0',   '');
  Check(Near(SampleInt32ToFloat(2147483647),   1.0),   'Int32 max → ~1.0','');
  Check(Near(SampleInt32ToFloat(-2147483648), -1.0),   'Int32 min → -1.0','');

  // Float32 passthrough + clamping
  Check(Near(SampleFloat32ToFloat(0.5),   0.5),  'Float32 0.5 → 0.5',  '');
  Check(Near(SampleFloat32ToFloat(1.5),   1.0),  'Float32 1.5 clamped → 1.0', '');
  Check(Near(SampleFloat32ToFloat(-2.0), -1.0),  'Float32 -2.0 clamped → -1.0', '');

  // Float64 downcast + clamping
  Check(Near(SampleFloat64ToFloat(0.25),  0.25), 'Float64 0.25 → 0.25', '');
  Check(Near(SampleFloat64ToFloat(2.0),   1.0),  'Float64 2.0 clamped → 1.0', '');

  // SampleFloatToInt32 round-trip
  Check(SampleFloatToInt32(0.0) = 0,          'Float 0.0 → Int32 0',   '');
  Check(SampleFloatToInt32(1.0) = 2147483647, 'Float 1.0 → Int32 max', '');
  Check(SampleFloatToInt32(-1.0) = -2147483647, 'Float -1.0 → Int32 -2147483647 (symmetric range)', '');

  // SampleFloatToFloat32 clamping
  Check(Near(SampleFloatToFloat32(0.75),  0.75), 'FloatToFloat32 0.75 → 0.75', '');
  Check(Near(SampleFloatToFloat32(1.5),   1.0),  'FloatToFloat32 1.5 clamped', '');
  Check(Near(SampleFloatToFloat32(-1.5), -1.0),  'FloatToFloat32 -1.5 clamped','');
end;

procedure TestBlockHelpers;
const
  Eps = 0.0001;
  N = 4;

  function Near(A, B: Single): Boolean;
  begin
    Result := Abs(A - B) < Eps;
  end;

var
  Src16  : array[0..N-1] of SmallInt;
  Src32  : array[0..N-1] of Integer;
  SrcF32 : array[0..N-1] of Single;
  SrcI24 : array[0..N*3-1] of Byte;
  Dst    : array[0..N-1] of Single;
  I      : Integer;
begin
  Writeln('--- Block conversion helpers ---');

  // BlockInt16ToFloat (stride = 1)
  for I := 0 to N - 1 do
    Src16[I] := SmallInt((I - 2) * 8192);  // -16384, -8192, 0, 8192
  BlockInt16ToFloat(@Src16[0], 1, N, @Dst[0]);
  Check(Near(Dst[0], -16384.0 / 32768.0), 'Block16[0] = -0.5', Format('got %f', [Dst[0]]));
  Check(Near(Dst[2], 0.0),                'Block16[2] = 0.0',  Format('got %f', [Dst[2]]));
  Check(Near(Dst[3],  8192.0 / 32768.0),  'Block16[3] = 0.25', Format('got %f', [Dst[3]]));

  // BlockInt32ToFloat (stride = 1)
  Src32[0] := -2147483648;
  Src32[1] := 0;
  Src32[2] := 1073741824;  // 2^30 → 0.5
  Src32[3] := 2147483647;
  BlockInt32ToFloat(@Src32[0], 1, N, @Dst[0]);
  Check(Near(Dst[0], -1.0), 'Block32[0] = -1.0', Format('got %f', [Dst[0]]));
  Check(Near(Dst[1],  0.0), 'Block32[1] = 0.0',  Format('got %f', [Dst[1]]));
  Check(Near(Dst[2],  0.5), 'Block32[2] = 0.5',  Format('got %f', [Dst[2]]));

  // BlockFloat32ToFloat — clamping
  SrcF32[0] := -2.0;
  SrcF32[1] :=  0.3;
  SrcF32[2] :=  1.8;
  SrcF32[3] :=  0.0;
  BlockFloat32ToFloat(@SrcF32[0], 1, N, @Dst[0]);
  Check(Near(Dst[0], -1.0), 'BlockF32[0] clamped -1.0', Format('got %f', [Dst[0]]));
  Check(Near(Dst[1],  0.3), 'BlockF32[1] = 0.3',         Format('got %f', [Dst[1]]));
  Check(Near(Dst[2],  1.0), 'BlockF32[2] clamped 1.0',   Format('got %f', [Dst[2]]));

  // BlockInt24ToFloat — use SampleFloatToInt24 to build test data
  SampleFloatToInt24(-0.5, @SrcI24[0]);
  SampleFloatToInt24( 0.0, @SrcI24[3]);
  SampleFloatToInt24( 0.5, @SrcI24[6]);
  SampleFloatToInt24( 1.0, @SrcI24[9]);
  BlockInt24ToFloat(@SrcI24[0], 3, N, @Dst[0]);
  Check(Near(Dst[0], -0.5), 'Block24[0] = -0.5', Format('got %f', [Dst[0]]));
  Check(Near(Dst[1],  0.0), 'Block24[1] = 0.0',  Format('got %f', [Dst[1]]));
  Check(Near(Dst[2],  0.5), 'Block24[2] = 0.5',  Format('got %f', [Dst[2]]));
end;

// ---------------------------------------------------------------------------
// CRC tests — known good vectors
// ---------------------------------------------------------------------------

procedure TestCRC;
var
  Data: TBytes;
  C8: Byte;
  C16: Word;
  C32: Cardinal;
begin
  Writeln('--- AudioCRC ---');

  // CRC-8 (poly 0x07): FLAC uses this for frame header.
  // Known vector: CRC-8 of $FF = 0xF3 (poly 0x07, init 0, MSB-first)
  Data := TBytes.Create($FF);
  C8 := CRC8_Calc(@Data[0], 1);
  Check(C8 = $F3, 'CRC-8 of $FF = $F3', Format('got $%X', [C8]));

  // CRC-8 of empty = 0
  C8 := CRC8_Calc(nil, 0);
  Check(C8 = $00, 'CRC-8 empty = $00', Format('got $%X', [C8]));

  // CRC-16 (FLAC, poly 0x8005): known vector $1D0F for empty = 0
  C16 := CRC16_Calc(nil, 0);
  Check(C16 = $0000, 'CRC-16 empty = $0000', Format('got $%X', [C16]));

  // CRC-16 of $FF
  Data := TBytes.Create($FF);
  C16 := CRC16_Calc(@Data[0], 1);
  Check(C16 = $0202, 'CRC-16 of $FF = $0202', Format('got $%X', [C16]));

  // Ogg CRC-32: known vector — CRC of empty = 0
  C32 := CRC32Ogg_Calc(nil, 0);
  Check(C32 = $00000000, 'CRC32Ogg empty = 0', Format('got $%X', [C32]));

  // Ogg CRC-32 of "OggS" magic
  Data := TBytes.Create(Ord('O'), Ord('g'), Ord('g'), Ord('S'));
  C32 := CRC32Ogg_Calc(@Data[0], 4);
  Check(C32 = $5FB0A94F, 'CRC32Ogg("OggS") = $5FB0A94F', Format('got $%X', [C32]));
end;

procedure TestCRCIncremental;
var
  Data: TBytes;
  C8 : Byte;
  C16: Word;
  C32: Cardinal;
begin
  Writeln('--- CRC incremental update ---');

  // CRC-8 incremental: byte-by-byte must equal one-shot
  Data := TBytes.Create($FF, $A5, $3C);
  C8 := CRC8_Calc(@Data[0], 3);
  var C8Inc := CRC8_Init;
  C8Inc := CRC8_Update(C8Inc, @Data[0], 1);
  C8Inc := CRC8_Update(C8Inc, @Data[1], 1);
  C8Inc := CRC8_Update(C8Inc, @Data[2], 1);
  Check(C8Inc = C8, 'CRC-8 incremental = one-shot',
    Format('inc=$%X one=$%X', [C8Inc, C8]));

  // CRC-16 incremental
  C16 := CRC16_Calc(@Data[0], 3);
  var C16Inc := CRC16_Init;
  C16Inc := CRC16_Update(C16Inc, @Data[0], 1);
  C16Inc := CRC16_Update(C16Inc, @Data[1], 2);
  Check(C16Inc = C16, 'CRC-16 incremental = one-shot',
    Format('inc=$%X one=$%X', [C16Inc, C16]));

  // CRC-32 Ogg incremental
  Data := TBytes.Create(Ord('O'), Ord('g'), Ord('g'), Ord('S'), $00);
  C32 := CRC32Ogg_Calc(@Data[0], 5);
  var C32Inc := CRC32Ogg_Init;
  C32Inc := CRC32Ogg_Update(C32Inc, @Data[0], 3);
  C32Inc := CRC32Ogg_Update(C32Inc, @Data[3], 2);
  Check(C32Inc = C32, 'CRC32Ogg incremental = one-shot',
    Format('inc=$%X one=$%X', [C32Inc, C32]));
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

begin
  Writeln('=== audio-common unit tests ===');
  Writeln;

  TestBitReaderMSB;
  TestBitReaderLSB;
  TestBitReaderUnary;
  TestBitReaderAlign;
  TestBitReaderPeekSkip;
  TestBitReaderSigned;
  TestBitReaderLSBExtended;
  TestBitReaderReset;
  TestRiceCoding;
  TestSampleConv;
  TestSampleConvExtended;
  TestBlockHelpers;
  TestCRC;
  TestCRCIncremental;

  Writeln;
  if GFailed then
  begin
    Writeln('*** SOME TESTS FAILED ***');
    Halt(1);
  end
  else
    Writeln('All tests passed.');
end.
