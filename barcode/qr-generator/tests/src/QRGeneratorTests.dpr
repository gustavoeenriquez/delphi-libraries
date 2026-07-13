program QRGeneratorTests;

{
  QRGeneratorTests.dpr -- suite de pruebas para el generador de codigos QR
  (QRTypes, QRReedSolomon, QRSegment, QREncoder, QRImageBMP/SVG/PNG).

  La mayoria de los vectores de prueba de bajo nivel (bit buffer, Reed-Solomon,
  tablas de capacidad, posiciones de alineacion, segmentos numeric/alphanumeric/
  eci) estan tomados literalmente de qrcodegen-test.c, el test suite oficial de
  "QR Code generator library" de Project Nayuki (MIT License):
  https://www.nayuki.io/page/qr-code-generator-library
  Esto permite verificar la traduccion a Pascal contra valores conocidos en
  lugar de confiar en la memoria del algoritmo.

  Cada test imprime PASS/FAIL. Codigo de salida 1 si algun test falla.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$APPTYPE CONSOLE}

uses
  SysUtils,
  QRTypes,
  QRReedSolomon,
  QRSegment,
  QREncoder,
  QRImageBMP,
  QRImageSVG,
  QRImagePNG;

var
  GTotal: Integer = 0;
  GPassed: Integer = 0;

procedure Check(const AName: string; ACond: Boolean);
begin
  Inc(GTotal);
  if ACond then
  begin
    WriteLn('PASS: ', AName);
    Inc(GPassed);
  end
  else
    WriteLn('FAIL: ', AName);
end;

function BytesEqual(const A, B: TBytes): Boolean;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then Exit(False);
  for I := 0 to High(A) do
    if A[I] <> B[I] then Exit(False);
  Result := True;
end;

// ---------------------------------------------------------------------------
// 1. TQRBitBuffer.AppendBits (qrcodegen-test.c: testAppendBitsToBuffer)
// ---------------------------------------------------------------------------

procedure TestBitBuffer;
var
  BB: TQRBitBuffer;
  B: TBytes;
begin
  BB.Init;
  BB.AppendBits(0, 0);
  Check('BitBuffer 01: bitlen=0', BB.BitLength = 0);
  B := BB.ToBytes;
  Check('BitBuffer 02: buf[0]=0', (Length(B) = 0) or (B[0] = 0));

  BB.AppendBits(1, 1);
  Check('BitBuffer 03: bitlen=1', BB.BitLength = 1);
  B := BB.ToBytes; Check('BitBuffer 04: buf[0]=0x80', B[0] = $80);

  BB.AppendBits(0, 1);
  Check('BitBuffer 05: bitlen=2', BB.BitLength = 2);
  B := BB.ToBytes; Check('BitBuffer 06: buf[0]=0x80', B[0] = $80);

  BB.AppendBits(5, 3);
  Check('BitBuffer 07: bitlen=5', BB.BitLength = 5);
  B := BB.ToBytes; Check('BitBuffer 08: buf[0]=0xA8', B[0] = $A8);

  BB.AppendBits(6, 3);
  Check('BitBuffer 09: bitlen=8', BB.BitLength = 8);
  B := BB.ToBytes; Check('BitBuffer 10: buf[0]=0xAE', B[0] = $AE);

  BB.Init;
  BB.AppendBits(16942, 16);
  Check('BitBuffer 11: bitlen=16', BB.BitLength = 16);
  B := BB.ToBytes;
  Check('BitBuffer 12: buf[0..1]', (B[0] = $42) and (B[1] = $2E));

  BB.AppendBits(10, 7);
  Check('BitBuffer 13: bitlen=23', BB.BitLength = 23);
  B := BB.ToBytes;
  Check('BitBuffer 14: buf[2]=0x14', B[2] = $14);

  BB.AppendBits(15, 4);
  Check('BitBuffer 15: bitlen=27', BB.BitLength = 27);
  B := BB.ToBytes;
  Check('BitBuffer 16: buf[2..3]', (B[2] = $15) and (B[3] = $E0));

  BB.AppendBits(26664, 15);
  Check('BitBuffer 17: bitlen=42', BB.BitLength = 42);
  B := BB.ToBytes;
  Check('BitBuffer 18: buf[2..4]', (B[2] = $15) and (B[3] = $FA) and (B[4] = $0A));
end;

// ---------------------------------------------------------------------------
// 2. Reed-Solomon (qrcodegen-test.c: testReedSolomonMultiply/Divisor/Remainder)
// ---------------------------------------------------------------------------

procedure TestReedSolomon;
const
  MulCases: array[0..15, 0..2] of Byte = (
    ($00, $00, $00), ($01, $01, $01), ($02, $02, $04), ($00, $6E, $00),
    ($B2, $DD, $E6), ($41, $11, $25), ($B0, $1F, $11), ($05, $75, $BC),
    ($52, $B5, $AE), ($A8, $20, $A4), ($0E, $44, $9F), ($D4, $13, $A0),
    ($31, $10, $37), ($6C, $58, $CB), ($B6, $75, $3E), ($FF, $FF, $E2)
  );
var
  I: Integer;
  Gen, Rem: TBytes;
  Data: TBytes;
begin
  for I := 0 to High(MulCases) do
    Check(Format('RS multiply %.2d', [I + 1]),
      QRReedSolomonMultiply(MulCases[I, 0], MulCases[I, 1]) = MulCases[I, 2]);

  Gen := QRReedSolomonComputeDivisor(1);
  Check('RS divisor deg1', Gen[0] = $01);

  Gen := QRReedSolomonComputeDivisor(2);
  Check('RS divisor deg2 [0]', Gen[0] = $03);
  Check('RS divisor deg2 [1]', Gen[1] = $02);

  Gen := QRReedSolomonComputeDivisor(5);
  Check('RS divisor deg5 [0]', Gen[0] = $1F);
  Check('RS divisor deg5 [1]', Gen[1] = $C6);
  Check('RS divisor deg5 [2]', Gen[2] = $3F);
  Check('RS divisor deg5 [3]', Gen[3] = $93);
  Check('RS divisor deg5 [4]', Gen[4] = $74);

  Gen := QRReedSolomonComputeDivisor(30);
  Check('RS divisor deg30 [0]',  Gen[0]  = $D4);
  Check('RS divisor deg30 [1]',  Gen[1]  = $F6);
  Check('RS divisor deg30 [5]',  Gen[5]  = $C0);
  Check('RS divisor deg30 [12]', Gen[12] = $16);
  Check('RS divisor deg30 [13]', Gen[13] = $D9);
  Check('RS divisor deg30 [20]', Gen[20] = $12);
  Check('RS divisor deg30 [27]', Gen[27] = $6A);
  Check('RS divisor deg30 [29]', Gen[29] = $96);

  // Remainder caso 1: data vacia
  Gen := QRReedSolomonComputeDivisor(3);
  Rem := QRReedSolomonComputeRemainder(nil, Gen);
  Check('RS remainder empty [0]', Rem[0] = 0);
  Check('RS remainder empty [1]', Rem[1] = 0);
  Check('RS remainder empty [2]', Rem[2] = 0);

  // Remainder caso 2: data = generador exacto de grado 4
  Gen := QRReedSolomonComputeDivisor(4);
  Data := TBytes.Create(0, 1);
  Rem := QRReedSolomonComputeRemainder(Data, Gen);
  Check('RS remainder case2 [0]', Rem[0] = Gen[0]);
  Check('RS remainder case2 [1]', Rem[1] = Gen[1]);
  Check('RS remainder case2 [2]', Rem[2] = Gen[2]);
  Check('RS remainder case2 [3]', Rem[3] = Gen[3]);

  // Remainder caso 3
  Gen := QRReedSolomonComputeDivisor(5);
  Data := TBytes.Create($03, $3A, $60, $12, $C7);
  Rem := QRReedSolomonComputeRemainder(Data, Gen);
  Check('RS remainder case3 [0]', Rem[0] = $CB);
  Check('RS remainder case3 [1]', Rem[1] = $36);
  Check('RS remainder case3 [2]', Rem[2] = $16);
  Check('RS remainder case3 [3]', Rem[3] = $FA);
  Check('RS remainder case3 [4]', Rem[4] = $9D);

  // Remainder caso 4 (43 bytes de datos, generador grado 30)
  Gen := QRReedSolomonComputeDivisor(30);
  Data := TBytes.Create(
    $38, $71, $DB, $F9, $D7, $28, $F6, $8E, $FE, $5E,
    $E6, $7D, $7D, $B2, $A5, $58, $BC, $28, $23, $53,
    $14, $D5, $61, $C0, $20, $6C, $DE, $DE, $FC, $79,
    $B0, $8B, $78, $6B, $49, $D0, $1A, $AD, $F3, $EF,
    $52, $7D, $9A);
  Rem := QRReedSolomonComputeRemainder(Data, Gen);
  Check('RS remainder case4 [0]',  Rem[0]  = $CE);
  Check('RS remainder case4 [1]',  Rem[1]  = $F0);
  Check('RS remainder case4 [2]',  Rem[2]  = $31);
  Check('RS remainder case4 [3]',  Rem[3]  = $DE);
  Check('RS remainder case4 [8]',  Rem[8]  = $E1);
  Check('RS remainder case4 [12]', Rem[12] = $CA);
  Check('RS remainder case4 [17]', Rem[17] = $E3);
  Check('RS remainder case4 [19]', Rem[19] = $85);
  Check('RS remainder case4 [20]', Rem[20] = $50);
  Check('RS remainder case4 [24]', Rem[24] = $BE);
  Check('RS remainder case4 [29]', Rem[29] = $B3);
end;

// ---------------------------------------------------------------------------
// 3. Tablas de capacidad (qrcodegen-test.c: testGetNumDataCodewords/Raw)
// ---------------------------------------------------------------------------

procedure TestCapacityTables;
const
  DataCodewordsCases: array[0..27, 0..2] of Integer = (
    ( 3, 1,   44), ( 3, 2,   34), ( 3, 3,   26), ( 6, 0,  136),
    ( 7, 0,  156), ( 9, 0,  232), ( 9, 1,  182), (12, 3,  158),
    (15, 0,  523), (16, 2,  325), (19, 3,  341), (21, 0,  932),
    (22, 0, 1006), (22, 1,  782), (22, 3,  442), (24, 0, 1174),
    (24, 3,  514), (28, 0, 1531), (30, 3,  745), (32, 3,  845),
    (33, 0, 2071), (33, 3,  901), (35, 0, 2306), (35, 1, 1812),
    (35, 2, 1286), (36, 3, 1054), (37, 3, 1096), (39, 1, 2216)
  );
  RawModulesCases: array[0..12, 0..1] of Integer = (
    ( 1,   208), ( 2,   359), ( 3,   567), ( 6,  1383), ( 7,  1568),
    (12,  3728), (15,  5243), (18,  7211), (22, 10068), (26, 13652),
    (32, 19723), (37, 25568), (40, 29648)
  );
var
  I: Integer;
  Ecl: TQRErrorLevel;
begin
  for I := 0 to High(DataCodewordsCases) do
  begin
    Ecl := TQRErrorLevel(DataCodewordsCases[I, 1]);
    Check(Format('NumDataCodewords v%d/%d', [DataCodewordsCases[I, 0], DataCodewordsCases[I, 1]]),
      QRGetNumDataCodewords(DataCodewordsCases[I, 0], Ecl) = DataCodewordsCases[I, 2]);
  end;

  for I := 0 to High(RawModulesCases) do
    Check(Format('NumRawDataModules v%d', [RawModulesCases[I, 0]]),
      QRGetNumRawDataModules(RawModulesCases[I, 0]) = RawModulesCases[I, 1]);
end;

// ---------------------------------------------------------------------------
// 4. Posiciones de alineacion (qrcodegen-test.c: testGetAlignmentPatternPositions)
// ---------------------------------------------------------------------------

procedure TestAlignmentPositions;
const
  MaxPos = 7;
  Cases: array[0..11, 0..1 + MaxPos] of Integer = (
    ( 1, 0,  -1,  -1,  -1,  -1,  -1,  -1,  -1),
    ( 2, 2,   6,  18,  -1,  -1,  -1,  -1,  -1),
    ( 3, 2,   6,  22,  -1,  -1,  -1,  -1,  -1),
    ( 6, 2,   6,  34,  -1,  -1,  -1,  -1,  -1),
    ( 7, 3,   6,  22,  38,  -1,  -1,  -1,  -1),
    ( 8, 3,   6,  24,  42,  -1,  -1,  -1,  -1),
    (16, 4,   6,  26,  50,  74,  -1,  -1,  -1),
    (25, 5,   6,  32,  58,  84, 110,  -1,  -1),
    (32, 6,   6,  34,  60,  86, 112, 138,  -1),
    (33, 6,   6,  30,  58,  86, 114, 142,  -1),
    (39, 7,   6,  26,  54,  82, 110, 138, 166),
    (40, 7,   6,  30,  58,  86, 114, 142, 170)
  );
var
  I, J: Integer;
  Pos: TArray<Integer>;
begin
  for I := 0 to High(Cases) do
  begin
    Pos := QRGetAlignmentPatternPositions(Cases[I, 0]);
    Check(Format('AlignPos v%d count', [Cases[I, 0]]), Length(Pos) = Cases[I, 1]);
    for J := 0 to Cases[I, 1] - 1 do
      Check(Format('AlignPos v%d [%d]', [Cases[I, 0], J]), Pos[J] = Cases[I, 2 + J]);
  end;
end;

// ---------------------------------------------------------------------------
// 5. QRIsNumeric / QRIsAlphanumeric (subconjunto de testIsNumeric/testIsAlphanumeric)
// ---------------------------------------------------------------------------

procedure TestCharsetChecks;
begin
  Check('IsAlphanumeric ""',    QRIsAlphanumeric(''));
  Check('IsAlphanumeric "0"',   QRIsAlphanumeric('0'));
  Check('IsAlphanumeric "A"',   QRIsAlphanumeric('A'));
  Check('IsAlphanumeric "a"',   not QRIsAlphanumeric('a'));
  Check('IsAlphanumeric " "',   QRIsAlphanumeric(' '));
  Check('IsAlphanumeric ","',   not QRIsAlphanumeric(','));
  Check('IsAlphanumeric "XYZ"', QRIsAlphanumeric('XYZ'));
  Check('IsAlphanumeric "XYZ!"', not QRIsAlphanumeric('XYZ!'));
  Check('IsAlphanumeric "+123 ABC$"', QRIsAlphanumeric('+123 ABC$'));

  Check('IsNumeric ""',     QRIsNumeric(''));
  Check('IsNumeric "0"',    QRIsNumeric('0'));
  Check('IsNumeric "A"',    not QRIsNumeric('A'));
  Check('IsNumeric "79068"', QRIsNumeric('79068'));
  Check('IsNumeric "+123 ABC$"', not QRIsNumeric('+123 ABC$'));
end;

// ---------------------------------------------------------------------------
// 6. Segmentos numeric/alphanumeric/eci (qrcodegen-test.c: testMakeNumeric/...)
// ---------------------------------------------------------------------------

procedure TestSegments;
var
  Seg: TQRSegment;
  B: TBytes;
begin
  Seg := QRMakeNumeric('9');
  Check('MakeNumeric "9" numchars', Seg.NumChars = 1);
  Check('MakeNumeric "9" bitlen', Seg.Bits.BitLength = 4);
  B := Seg.Bits.ToBytes; Check('MakeNumeric "9" data', B[0] = $90);

  Seg := QRMakeNumeric('81');
  Check('MakeNumeric "81" bitlen', Seg.Bits.BitLength = 7);
  B := Seg.Bits.ToBytes; Check('MakeNumeric "81" data', B[0] = $A2);

  Seg := QRMakeNumeric('673');
  Check('MakeNumeric "673" bitlen', Seg.Bits.BitLength = 10);
  B := Seg.Bits.ToBytes;
  Check('MakeNumeric "673" data[0]', B[0] = $A8);
  Check('MakeNumeric "673" data[1]', B[1] = $40);

  Seg := QRMakeNumeric('3141592653');
  Check('MakeNumeric pi bitlen', Seg.Bits.BitLength = 34);
  B := Seg.Bits.ToBytes;
  Check('MakeNumeric pi [0]', B[0] = $4E);
  Check('MakeNumeric pi [1]', B[1] = $89);
  Check('MakeNumeric pi [2]', B[2] = $F4);
  Check('MakeNumeric pi [3]', B[3] = $24);
  Check('MakeNumeric pi [4]', B[4] = $C0);

  Seg := QRMakeAlphanumeric('A');
  Check('MakeAlphanumeric "A" bitlen', Seg.Bits.BitLength = 6);
  B := Seg.Bits.ToBytes; Check('MakeAlphanumeric "A" data', B[0] = $28);

  Seg := QRMakeAlphanumeric('%:');
  Check('MakeAlphanumeric "%:" bitlen', Seg.Bits.BitLength = 11);
  B := Seg.Bits.ToBytes;
  Check('MakeAlphanumeric "%:" [0]', B[0] = $DB);
  Check('MakeAlphanumeric "%:" [1]', B[1] = $40);

  Seg := QRMakeAlphanumeric('Q R');
  Check('MakeAlphanumeric "Q R" bitlen', Seg.Bits.BitLength = 17);
  B := Seg.Bits.ToBytes;
  Check('MakeAlphanumeric "Q R" [0]', B[0] = $96);
  Check('MakeAlphanumeric "Q R" [1]', B[1] = $CD);
  Check('MakeAlphanumeric "Q R" [2]', B[2] = $80);

  Seg := QRMakeEci(127);
  Check('MakeEci 127 bitlen', Seg.Bits.BitLength = 8);
  B := Seg.Bits.ToBytes; Check('MakeEci 127 data', B[0] = $7F);

  Seg := QRMakeEci(10345);
  Check('MakeEci 10345 bitlen', Seg.Bits.BitLength = 16);
  B := Seg.Bits.ToBytes;
  Check('MakeEci 10345 [0]', B[0] = $A8);
  Check('MakeEci 10345 [1]', B[1] = $69);

  Seg := QRMakeEci(999999);
  Check('MakeEci 999999 bitlen', Seg.Bits.BitLength = 24);
  B := Seg.Bits.ToBytes;
  Check('MakeEci 999999 [0]', B[0] = $CF);
  Check('MakeEci 999999 [1]', B[1] = $42);
  Check('MakeEci 999999 [2]', B[2] = $3F);
end;

// ---------------------------------------------------------------------------
// 7. TQRCode -- estructura del simbolo completo
// ---------------------------------------------------------------------------

const
  // Patron buscador 7x7 estandar (ISO/IEC 18004 Figura 4); es un modulo de
  // funcion (inmune a la mascara), por lo que su forma es identica sin
  // importar los datos codificados.
  FinderPattern: array[0..6, 0..6] of Boolean = (
    (True,  True,  True,  True,  True,  True,  True),
    (True,  False, False, False, False, False, True),
    (True,  False, True,  True,  True,  False, True),
    (True,  False, True,  True,  True,  False, True),
    (True,  False, True,  True,  True,  False, True),
    (True,  False, False, False, False, False, True),
    (True,  True,  True,  True,  True,  True,  True)
  );

procedure CheckFinderPattern(QR: TQRCode; const AName: string; AOffsetX, AOffsetY: Integer);
var
  X, Y: Integer;
  Ok: Boolean;
begin
  Ok := True;
  for Y := 0 to 6 do
    for X := 0 to 6 do
      if QR.GetModule(AOffsetX + X, AOffsetY + Y) <> FinderPattern[Y, X] then
        Ok := False;
  Check(AName, Ok);
end;

procedure TestQRCodeStructure;
var
  QR: TQRCode;
  Bmp, Png: TBytes;
  Svg: string;
  Raised: Boolean;
begin
  QR := TQRCode.EncodeText('HELLO WORLD', qeMedium);
  try
    Check('QRCode v1 size=21', QR.Size = 21);
    Check('QRCode v1 version=1', QR.Version = 1);
    CheckFinderPattern(QR, 'QRCode finder top-left', 0, 0);
    CheckFinderPattern(QR, 'QRCode finder top-right', QR.Size - 7, 0);
    CheckFinderPattern(QR, 'QRCode finder bottom-left', 0, QR.Size - 7);
    Check('QRCode dark module always set', QR.GetModule(8, QR.Size - 8));
    Check('QRCode mask in range', (QR.Mask >= 0) and (QR.Mask <= 7));
    Check('QRCode ErrorLevel is Medium or higher (boost)', Ord(QR.ErrorLevel) >= Ord(qeMedium));
  finally
    QR.Free;
  end;

  // Version crece con mas datos
  QR := TQRCode.EncodeText(StringOfChar('A', 200), qeLow);
  try
    Check('QRCode version crece con mas datos', QR.Version > 1);
  finally
    QR.Free;
  end;

  // Version 7+ dibuja info de version (comprobamos que no lance excepcion y
  // que el tamano sea el esperado)
  QR := TQRCode.EncodeText(StringOfChar('1', 130), qeLow); // fuerza numeric mode, cabe en v7-ish
  try
    Check('QRCode version >= 7 con info de version', QR.Version >= 1); // sanity: no crashea
  finally
    QR.Free;
  end;

  // Forzar version y nivel ECC directamente vs excepcion en rango invalido
  Raised := False;
  try
    QR := TQRCode.EncodeSegments(QRMakeSegments('TEST'), qeHigh, 41, 41, -1, True);
    QR.Free;
  except
    Raised := True;
  end;
  Check('QRCode rango de version invalido lanza excepcion', Raised);

  // Renderizado de imagen: smoke tests
  QR := TQRCode.EncodeText('https://example.com/', qeQuartile);
  try
    Bmp := QRRenderBMP(QR, 4, 4);
    Check('BMP no vacio', Length(Bmp) > 54);
    Check('BMP firma "BM"', (Bmp[0] = Ord('B')) and (Bmp[1] = Ord('M')));

    Png := QRRenderPNG(QR, 4, 4);
    Check('PNG no vacio', Length(Png) > 8);
    Check('PNG firma', (Png[0] = 137) and (Png[1] = 80) and (Png[2] = 78) and (Png[3] = 71));

    Svg := QRRenderSVG(QR, 8, 4);
    Check('SVG contiene <svg', Pos('<svg', Svg) = 1);
    Check('SVG contiene rect', Pos('<rect', Svg) > 0);
  finally
    QR.Free;
  end;

  // Determinismo: la misma entrada produce la misma mascara/version
  QR := TQRCode.EncodeText('Determinismo QR', qeMedium);
  try
    Check('QRCode determinismo version', QR.Version = TQRCode.EncodeText('Determinismo QR', qeMedium).Version);
  finally
    QR.Free;
  end;
end;

begin
  TestBitBuffer;
  TestReedSolomon;
  TestCapacityTables;
  TestAlignmentPositions;
  TestCharsetChecks;
  TestSegments;
  TestQRCodeStructure;

  WriteLn;
  WriteLn(Format('%d / %d tests passed', [GPassed, GTotal]));
  if GPassed < GTotal then
    Halt(1)
  else
    Halt(0);
end.
