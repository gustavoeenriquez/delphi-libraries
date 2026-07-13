program QRReaderTests;

{
  QRReaderTests.dpr -- suite de pruebas para el lector de codigos QR
  (QRReedSolomonDecoder, QRBitStreamDecoder, QRMatrixDecoder, pipeline de
  vision QRReader). Se ira ampliando a medida que se agreguen las unidades
  del lector.

  Cada test imprime PASS/FAIL. Codigo de salida 1 si algun test falla.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Math,
  QRTypes,
  QRSegment,
  QRReedSolomon,
  QRReedSolomonDecoder,
  QRBitStreamDecoder,
  QRMatrixDecoder,
  QRGrayImage,
  QRBinarizer,
  QRFinderPatternFinder,
  QRAlignmentPatternFinder,
  QRPerspectiveTransform,
  QRReader,
  QRImageLoader,
  QRImageBMP,
  QRImagePNG,
  QREncoder;

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

function RepeatStr(const S: string; ACount: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to ACount do
    Result := Result + S;
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
// GF(256): la multiplicacion por tablas del decoder debe coincidir con la
// multiplicacion "russian peasant" bit a bit del encoder (mismo campo).
// ---------------------------------------------------------------------------

procedure TestGFCrossCheck;
var
  A, B: Integer;
  Mismatches: Integer;
begin
  Mismatches := 0;
  for A := 0 to 255 do
    for B := 0 to 255 do
      if QRGF256Multiply(A, B) <> QRReedSolomonMultiply(A, B) then
        Inc(Mismatches);
  Check('GF256Multiply coincide con QRReedSolomonMultiply (65536 casos)', Mismatches = 0);

  Mismatches := 0;
  for A := 1 to 255 do
    if QRGF256Multiply(A, QRGF256Inverse(A)) <> 1 then
      Inc(Mismatches);
  Check('GF256Inverse: A * inverse(A) = 1 para todo A en 1..255', Mismatches = 0);
end;

// ---------------------------------------------------------------------------
// Construye un bloque codificado (data+ecc) usando el ENCODER, lo corrompe,
// y confirma que el DECODER lo recupera exactamente.
// ---------------------------------------------------------------------------

function BuildEncodedBlock(const AData: TBytes; AEccLen: Integer): TBytes;
var
  Gen, Ecc: TBytes;
begin
  Gen := QRReedSolomonComputeDivisor(AEccLen);
  Ecc := QRReedSolomonComputeRemainder(AData, Gen);
  SetLength(Result, Length(AData) + Length(Ecc));
  Move(AData[0], Result[0], Length(AData));
  Move(Ecc[0], Result[Length(AData)], Length(Ecc));
end;

procedure TestReedSolomonDecodeNoErrors;
var
  Data, Block: TBytes;
  NumCorrected: Integer;
  Ok: Boolean;
begin
  Data := TBytes.Create($11, $22, $33, $44, $55, $66, $C0, $DE);
  Block := BuildEncodedBlock(Data, 10);
  Ok := QRReedSolomonDecodeBlock(Block, 10, NumCorrected);
  Check('RS decode sin errores: retorna True', Ok);
  Check('RS decode sin errores: 0 corregidos', NumCorrected = 0);
  Check('RS decode sin errores: datos intactos', BytesEqual(Copy(Block, 0, Length(Data)), Data));
end;

procedure TestReedSolomonDecodeWithinCapacity;
var
  Data, Block, Original: TBytes;
  EccLen, MaxErrors, I: Integer;
  NumCorrected: Integer;
  Ok: Boolean;
begin
  // EccLen=16 -> corrige hasta 8 bytes errados
  EccLen := 16;
  MaxErrors := EccLen div 2;
  Data := TBytes.Create($01, $02, $03, $04, $05, $06, $07, $08, $09, $0A, $0B, $0C, $0D, $0E, $0F, $10, $EE, $FF);
  Original := Copy(Data, 0, Length(Data));
  Block := BuildEncodedBlock(Data, EccLen);

  // Corrompe exactamente MaxErrors bytes (mitad en la zona de datos, mitad en ECC)
  for I := 0 to MaxErrors - 1 do
    Block[I * 2] := Byte(Block[I * 2] xor $FF);

  Ok := QRReedSolomonDecodeBlock(Block, EccLen, NumCorrected);
  Check(Format('RS decode con %d errores (limite exacto): retorna True', [MaxErrors]), Ok);
  Check('RS decode en el limite: recupera los datos originales exactos',
    BytesEqual(Copy(Block, 0, Length(Original)), Original));
end;

procedure TestReedSolomonDecodeBeyondCapacity;
var
  Data, Block: TBytes;
  EccLen, MaxErrors, I: Integer;
  NumCorrected: Integer;
  Ok, Recovered: Boolean;
  Original: TBytes;
begin
  EccLen := 10; // corrige hasta 5 bytes
  MaxErrors := EccLen div 2;
  Data := TBytes.Create($AA, $BB, $CC, $DD, $EE, $01, $02, $03, $04, $05);
  Original := Copy(Data, 0, Length(Data));
  Block := BuildEncodedBlock(Data, EccLen);

  // Corrompe uno mas de lo que el codigo puede garantizar corregir
  for I := 0 to MaxErrors do
    Block[I * 2] := Byte(Block[I * 2] xor $F0);

  Ok := QRReedSolomonDecodeBlock(Block, EccLen, NumCorrected);
  // Con mas errores que la capacidad, el decoder debe fallar (False) o,
  // si "acierta" a otra palabra valida por coincidencia, no debe reportar
  // silenciosamente los datos originales como correctos sin serlo.
  Recovered := Ok and BytesEqual(Copy(Block, 0, Length(Original)), Original);
  Check('RS decode mas alla de la capacidad: no recupera silenciosamente datos incorrectos',
    not Recovered);
end;

procedure TestReedSolomonMultipleBlocks;
var
  Data, Block: TBytes;
  NumCorrected: Integer;
  Ok: Boolean;
  TrialIdx: Integer;
begin
  // Repite con varios tamanos tipicos de bloque QR (Ecc por bloque: 7,18,22,30)
  for TrialIdx := 0 to 3 do
  begin
    case TrialIdx of
      0: Data := TBytes.Create($10, $20, $30, $40, $50, $60, $70, $80, $90, $A0, $B0, $C0, $D0, $E0, $F0, $01);
      1: Data := TBytes.Create($01, $02, $03, $04, $05, $06, $07, $08, $09, $0A);
      2: Data := TBytes.Create($5A, $A5, $3C, $C3, $7E, $E7, $18, $81, $24, $42, $99, $66);
    else
      Data := TBytes.Create($FF, $00, $FF, $00, $12, $34, $56, $78, $9A, $BC, $DE, $F0, $11, $22);
    end;
    case TrialIdx of
      0: Block := BuildEncodedBlock(Data, 7);
      1: Block := BuildEncodedBlock(Data, 18);
      2: Block := BuildEncodedBlock(Data, 22);
    else
      Block := BuildEncodedBlock(Data, 30);
    end;
    // Corrompe 2 bytes (bien dentro de la capacidad en todos los casos)
    Block[0] := Byte(Block[0] xor $55);
    Block[Length(Block) - 1] := Byte(Block[Length(Block) - 1] xor $AA);

    Ok := QRReedSolomonDecodeBlock(Block, Length(Block) - Length(Data), NumCorrected);
    Check(Format('RS decode bloque tipico #%d: retorna True', [TrialIdx]), Ok);
    Check(Format('RS decode bloque tipico #%d: 2 errores corregidos', [TrialIdx]), NumCorrected = 2);
    Check(Format('RS decode bloque tipico #%d: datos recuperados', [TrialIdx]),
      BytesEqual(Copy(Block, 0, Length(Data)), Data));
  end;
end;

// ---------------------------------------------------------------------------
// QRBitStreamDecoder: arma un stream de datos igual que lo haria el encoder
// (indicador de modo + character count + payload, terminador, relleno a
// byte) y confirma que QRDecodeBitStream recupera exactamente el texto.
// ---------------------------------------------------------------------------

function BuildDataStream(const ASegs: TQRSegmentArray; AVersion: Integer): TBytes;
var
  BB: TQRBitBuffer;
  Seg: TQRSegment;
begin
  BB.Init;
  for Seg in ASegs do
  begin
    BB.AppendBits(QRModeBits(Seg.Mode), 4);
    BB.AppendBits(Seg.NumChars, QRModeCharCountBits(Seg.Mode, AVersion));
    BB.AppendBitBuffer(Seg.Bits);
  end;
  BB.AppendBits(0, 4); // terminador
  BB.AppendBits(0, (8 - BB.BitLength mod 8) mod 8); // relleno a byte completo
  Result := BB.ToBytes;
end;

procedure TestBitStreamDecoder;
var
  Segs: TQRSegmentArray;
  Data: TBytes;
  R: TQRDecodedResult;
  Raised: Boolean;
begin
  // Numeric puro
  SetLength(Segs, 1);
  Segs[0] := QRMakeNumeric('0123456789');
  Data := BuildDataStream(Segs, 1);
  R := QRDecodeBitStream(Data, 1);
  Check('BitStream: numeric puro', R.Text = '0123456789');

  // Alphanumeric puro
  SetLength(Segs, 1);
  Segs[0] := QRMakeAlphanumeric('HELLO WORLD 123');
  Data := BuildDataStream(Segs, 1);
  R := QRDecodeBitStream(Data, 1);
  Check('BitStream: alphanumeric puro', R.Text = 'HELLO WORLD 123');

  // Byte (UTF-8) puro, con acentos/enie
  SetLength(Segs, 1);
  Segs[0] := QRMakeBytes(TEncoding.UTF8.GetBytes('Hola, ñ! 100%'));
  Data := BuildDataStream(Segs, 1);
  R := QRDecodeBitStream(Data, 1);
  Check('BitStream: byte UTF-8 con acentos', R.Text = 'Hola, ñ! 100%');

  // Segmentos mixtos: numeric + alphanumeric + byte concatenados
  SetLength(Segs, 3);
  Segs[0] := QRMakeNumeric('42');
  Segs[1] := QRMakeAlphanumeric('AB');
  Segs[2] := QRMakeBytes(TEncoding.UTF8.GetBytes('xy'));
  Data := BuildDataStream(Segs, 1);
  R := QRDecodeBitStream(Data, 1);
  Check('BitStream: segmentos mixtos concatenados', R.Text = '42ABxy');

  // ECI + byte
  SetLength(Segs, 2);
  Segs[0] := QRMakeEci(26);
  Segs[1] := QRMakeBytes(TEncoding.UTF8.GetBytes('utf8 text'));
  Data := BuildDataStream(Segs, 1);
  R := QRDecodeBitStream(Data, 1);
  Check('BitStream: ECI detectado', (Length(R.EciValues) = 1) and (R.EciValues[0] = 26));
  Check('BitStream: texto tras ECI', R.Text = 'utf8 text');

  // Kanji: bytes SJIS crudos preservados
  SetLength(Segs, 1);
  Segs[0] := QRMakeKanji(TBytes.Create($93, $5F, $E4, $AA)); // dos pares SJIS validos (rangos 8140-9FFC y E040-EBBF)
  Data := BuildDataStream(Segs, 1);
  R := QRDecodeBitStream(Data, 1);
  Check('BitStream: kanji preserva bytes SJIS',
    BytesEqual(R.KanjiSjisBytes, TBytes.Create($93, $5F, $E4, $AA)));

  // Modo no soportado (Structured Append = 0x3) debe lanzar excepcion, no interpretar mal
  begin
    var BB: TQRBitBuffer;
    BB.Init;
    BB.AppendBits($3, 4);
    BB.AppendBits(0, 4);
    Raised := False;
    try
      QRDecodeBitStream(BB.ToBytes, 1);
    except
      Raised := True;
    end;
    Check('BitStream: Structured Append lanza excepcion (no soportado)', Raised);
  end;
end;

// ---------------------------------------------------------------------------
// QRMatrixDecoder: round-trip completo encoder -> grilla -> decoder, usando
// TQRCode (QREncoder.pas) para producir simbolos reales y validos.
// ---------------------------------------------------------------------------

function GridFromQRCode(AQR: TQRCode): TQRModuleGrid;
var
  X, Y: Integer;
begin
  SetLength(Result, AQR.Size, AQR.Size);
  for Y := 0 to AQR.Size - 1 do
    for X := 0 to AQR.Size - 1 do
      Result[Y, X] := AQR.GetModule(X, Y);
end;

procedure TestMatrixDecodeRoundTrip;
var
  QR: TQRCode;
  Grid: TQRModuleGrid;
  R: TQRMatrixDecodeResult;
  Texts: array[0..4] of string;
  Ecls: array[0..4] of TQRErrorLevel;
  I: Integer;
begin
  Texts[0] := 'HELLO WORLD 123';
  Texts[1] := '9876543210';
  Texts[2] := 'Texto con acentos: ñ, á, é, í, ó, ú, ¿?, 100%';
  Texts[3] := StringOfChar('A', 300); // fuerza version alta, ejercita version info (>=7)
  Texts[4] := 'https://github.com/gustavoeenriquez/delphi-libraries';

  Ecls[0] := qeLow;
  Ecls[1] := qeMedium;
  Ecls[2] := qeQuartile;
  Ecls[3] := qeHigh;
  Ecls[4] := qeMedium;

  for I := 0 to 4 do
  begin
    QR := TQRCode.EncodeText(Texts[I], Ecls[I]);
    try
      Grid := GridFromQRCode(QR);
      R := QRDecodeMatrix(Grid, QR.Size);
      Check(Format('MatrixDecode caso %d: exito', [I]), R.Success);
      if R.Success then
      begin
        Check(Format('MatrixDecode caso %d: texto identico', [I]), R.Text = Texts[I]);
        Check(Format('MatrixDecode caso %d: version identica', [I]), R.Version = QR.Version);
        Check(Format('MatrixDecode caso %d: mascara identica', [I]), R.Mask = QR.Mask);
        Check(Format('MatrixDecode caso %d: 0 errores corregidos (sin ruido)', [I]), R.NumErrorsCorrected = 0);
      end
      else
        WriteLn('  (detalle del fallo: ', R.ErrorMessage, ')');
    finally
      QR.Free;
    end;
  end;
end;

procedure TestMatrixDecodeWithNoise;
var
  QR: TQRCode;
  Grid: TQRModuleGrid;
  R: TQRMatrixDecodeResult;
  Flipped: Integer;
begin
  // Nivel de correccion H (~30%) sobre un texto corto: la version resultante
  // deberia tolerar sin problema unos pocos modulos de datos invertidos.
  QR := TQRCode.EncodeText('Prueba de tolerancia a ruido en QRMatrixDecoder', qeHigh);
  try
    Grid := GridFromQRCode(QR);

    // Invierte 3 modulos de datos (evita la zona de los primeros patrones de
    // funcion para no destruir el propio format/version info).
    Flipped := 0;
    var X, Y: Integer;
    for Y := QR.Size - 6 to QR.Size - 1 do
      for X := QR.Size - 6 to QR.Size - 1 do
        if Flipped < 3 then
        begin
          Grid[Y, X] := not Grid[Y, X];
          Inc(Flipped);
        end;

    R := QRDecodeMatrix(Grid, QR.Size);
    Check('MatrixDecode con ruido: exito', R.Success);
    if R.Success then
    begin
      Check('MatrixDecode con ruido: texto recuperado exacto', R.Text = 'Prueba de tolerancia a ruido en QRMatrixDecoder');
      Check('MatrixDecode con ruido: reporta errores corregidos > 0', R.NumErrorsCorrected > 0);
    end
    else
      WriteLn('  (detalle del fallo: ', R.ErrorMessage, ')');
  finally
    QR.Free;
  end;
end;

procedure TestMatrixDecodeInvalidSize;
var
  Grid: TQRModuleGrid;
  R: TQRMatrixDecodeResult;
begin
  SetLength(Grid, 20, 20); // 20 no es un tamano valido (21 + 4*n)
  R := QRDecodeMatrix(Grid, 20);
  Check('MatrixDecode tamano invalido: falla de forma controlada (no excepcion)', not R.Success);
end;

function BuildGrayImageFromQR(AQR: TQRCode; AScale, AQuietZone: Integer): TQRGrayImage;
var
  ImgSize, X, Y, ModX, ModY: Integer;
begin
  ImgSize := (AQR.Size + 2 * AQuietZone) * AScale;
  Result := QRGrayImageCreate(ImgSize, ImgSize);
  for Y := 0 to ImgSize - 1 do
  begin
    ModY := (Y div AScale) - AQuietZone;
    for X := 0 to ImgSize - 1 do
    begin
      ModX := (X div AScale) - AQuietZone;
      if (ModX >= 0) and (ModX < AQR.Size) and (ModY >= 0) and (ModY < AQR.Size) and AQR.GetModule(ModX, ModY) then
        Result.Pixels[Y * ImgSize + X] := 0
      else
        Result.Pixels[Y * ImgSize + X] := 255;
    end;
  end;
end;

procedure TestReaderSmoke;
var
  QR: TQRCode;
  Img: TQRGrayImage;
  R: TQRReadResult;
begin
  QR := TQRCode.EncodeText('HELLO WORLD 123', qeMedium);
  try
    Img := BuildGrayImageFromQR(QR, 6, 4);
    R := QRReadImage(Img);
    Check('Reader smoke: exito', R.Success);
    if R.Success then
      Check('Reader smoke: texto correcto', R.Text = 'HELLO WORLD 123')
    else
      WriteLn('  (detalle del fallo: ', R.ErrorMessage, ')');
  finally
    QR.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Verificacion cruzada con imagenes generadas por una libreria INDEPENDIENTE
// (python "qrcode"), no por nuestro propio encoder. Descarta bugs simetricos
// entre nuestro encoder y nuestro lector.
// ---------------------------------------------------------------------------

procedure TestExternalImages;
const
  Dir = 'C:\Users\genri\AppData\Local\Temp\claude\E--Copilot-delphi-libraries\a9024ae2-9891-4cdc-a9d1-f91d9f0936d2\scratchpad\ext_qr\';
var
  Files: array[0..4] of string;
  Expected: array[0..4] of string;
  I: Integer;
  Img: TQRGrayImage;
  R: TQRReadResult;
begin
  Files[0] := 'ext_case0.png'; Expected[0] := 'https://example.com/independent-generator-test';
  Files[1] := 'ext_case1.png'; Expected[1] := 'HELLO EXTERNAL WORLD 123';
  Files[2] := 'ext_case2.png'; Expected[2] := 'Texto con acentos: nino, cafe, 100%';
  Files[3] := 'ext_case3.png'; Expected[3] := RepeatStr('1234567890', 8);
  Files[4] := 'ext_case4.png'; Expected[4] := 'Small';

  for I := 0 to 4 do
  begin
    if not FileExists(Dir + Files[I]) then
    begin
      Check('Externo ' + Files[I] + ': archivo presente', False);
      Continue;
    end;
    Img := QRLoadGrayImage(Dir + Files[I]);
    R := QRReadImage(Img);
    Check('Externo ' + Files[I] + ': exito', R.Success);
    if R.Success then
      Check('Externo ' + Files[I] + ': texto correcto', R.Text = Expected[I])
    else
      WriteLn('  (detalle del fallo: ', R.ErrorMessage, ')');
  end;

  // JPEG con compresion agresiva (calidad 60) generado por PIL -- el caso mas
  // representativo de "foto real" (bloques DCT + submuestreo de croma), muy
  // distinto de ruido sal-y-pimienta sintetico.
  if FileExists(Dir + 'ext_jpeg_q60.jpg') then
  begin
    Img := QRLoadGrayImage(Dir + 'ext_jpeg_q60.jpg');
    R := QRReadImage(Img);
    Check('Externo JPEG q60: exito', R.Success);
    if R.Success then
      Check('Externo JPEG q60: texto correcto', R.Text = 'Prueba de compresion JPEG realista, calidad baja')
    else
      WriteLn('  (detalle del fallo: ', R.ErrorMessage, ')');
  end
  else
    Check('Externo JPEG q60: archivo presente', False);
end;

// ---------------------------------------------------------------------------
// Round-trip completo por archivo: nuestro encoder -> PNG/BMP en disco ->
// QRImageLoader -> QRReadImage.
// ---------------------------------------------------------------------------

procedure TestFileRoundTrip;
const
  ScratchDir = 'C:\Users\genri\AppData\Local\Temp\claude\E--Copilot-delphi-libraries\a9024ae2-9891-4cdc-a9d1-f91d9f0936d2\scratchpad\';
var
  QR: TQRCode;
  Img: TQRGrayImage;
  R: TQRReadResult;
  PngPath, BmpPath: string;
begin
  QR := TQRCode.EncodeText('Round-trip PNG/BMP -> QRImageLoader -> QRReadImage', qeQuartile);
  try
    PngPath := ScratchDir + 'roundtrip_test.png';
    BmpPath := ScratchDir + 'roundtrip_test.bmp';
    QRSavePNG(QR, PngPath, 6, 4);
    QRSaveBMP(QR, BmpPath, 6, 4);

    Img := QRLoadGrayImage(PngPath);
    R := QRReadImage(Img);
    Check('Round-trip PNG: exito', R.Success);
    if R.Success then
      Check('Round-trip PNG: texto correcto', R.Text = 'Round-trip PNG/BMP -> QRImageLoader -> QRReadImage')
    else
      WriteLn('  (detalle del fallo PNG: ', R.ErrorMessage, ')');

    Img := QRLoadGrayImage(BmpPath);
    R := QRReadImage(Img);
    Check('Round-trip BMP: exito', R.Success);
    if R.Success then
      Check('Round-trip BMP: texto correcto', R.Text = 'Round-trip PNG/BMP -> QRImageLoader -> QRReadImage')
    else
      WriteLn('  (detalle del fallo BMP: ', R.ErrorMessage, ')');
  finally
    QR.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Robustez: multiples versiones/ECC/modos, rotaciones de 90/180/270 grados,
// rotacion leve arbitraria, y ruido tipo sal-y-pimienta.
// ---------------------------------------------------------------------------

function RotateImage90(const AImg: TQRGrayImage): TQRGrayImage;
var
  X, Y: Integer;
begin
  Result := QRGrayImageCreate(AImg.Height, AImg.Width);
  for Y := 0 to AImg.Height - 1 do
    for X := 0 to AImg.Width - 1 do
      // (x,y) -> (h-1-y, x) en la imagen rotada
      Result.Pixels[X * Result.Width + (AImg.Height - 1 - Y)] := AImg.GetPixel(X, Y);
end;

function RotateImageArbitrary(const AImg: TQRGrayImage; ADegrees: Double): TQRGrayImage;
var
  X, Y, SrcX, SrcY: Integer;
  CX, CY, Rad, CosA, SinA, DX, DY: Double;
begin
  Result := QRGrayImageCreate(AImg.Width, AImg.Height);
  CX := AImg.Width / 2.0;
  CY := AImg.Height / 2.0;
  Rad := ADegrees * Pi / 180.0;
  CosA := Cos(Rad);
  SinA := Sin(Rad);
  for Y := 0 to Result.Height - 1 do
    for X := 0 to Result.Width - 1 do
    begin
      DX := X - CX;
      DY := Y - CY;
      SrcX := Trunc(CX + DX * CosA + DY * SinA);
      SrcY := Trunc(CY - DX * SinA + DY * CosA);
      if (SrcX >= 0) and (SrcX < AImg.Width) and (SrcY >= 0) and (SrcY < AImg.Height) then
        Result.Pixels[Y * Result.Width + X] := AImg.GetPixel(SrcX, SrcY)
      else
        Result.Pixels[Y * Result.Width + X] := 255; // fondo blanco
    end;
end;

procedure AddSaltPepperNoise(var AImg: TQRGrayImage; APercent: Double; ASeed: Cardinal);
var
  I, N: Integer;
  Rnd: Cardinal;
begin
  Rnd := ASeed;
  N := Round(Length(AImg.Pixels) * APercent / 100.0);
  for I := 0 to N - 1 do
  begin
    Rnd := Rnd * 1664525 + 1013904223;
    AImg.Pixels[Rnd mod Cardinal(Length(AImg.Pixels))] := (Rnd shr 16) and $FF;
  end;
end;

procedure TestRobustness;
var
  QR: TQRCode;
  Img, Rotated: TQRGrayImage;
  R: TQRReadResult;
begin
  // Version alta (>=7, ejercita version info) + varios ECC + rotaciones 90/180/270
  QR := TQRCode.EncodeText(RepeatStr('ROBUSTEZ-', 40), qeQuartile);
  try
    Img := BuildGrayImageFromQR(QR, 5, 4);

    R := QRReadImage(Img);
    Check('Robustez v>=7 sin rotar: exito', R.Success);
    if R.Success then Check('Robustez v>=7 sin rotar: texto', R.Text = RepeatStr('ROBUSTEZ-', 40));

    Rotated := RotateImage90(Img);
    R := QRReadImage(Rotated);
    Check('Robustez rotacion 90: exito', R.Success);
    if R.Success then Check('Robustez rotacion 90: texto', R.Text = RepeatStr('ROBUSTEZ-', 40));

    Rotated := RotateImage90(RotateImage90(Img));
    R := QRReadImage(Rotated);
    Check('Robustez rotacion 180: exito', R.Success);
    if R.Success then Check('Robustez rotacion 180: texto', R.Text = RepeatStr('ROBUSTEZ-', 40));

    Rotated := RotateImage90(RotateImage90(RotateImage90(Img)));
    R := QRReadImage(Rotated);
    Check('Robustez rotacion 270: exito', R.Success);
    if R.Success then Check('Robustez rotacion 270: texto', R.Text = RepeatStr('ROBUSTEZ-', 40));
  finally
    QR.Free;
  end;

  // Rotacion arbitraria leve (12 grados) -- escala grande para tolerar aliasing
  QR := TQRCode.EncodeText('Rotacion arbitraria de 12 grados', qeHigh);
  try
    Img := BuildGrayImageFromQR(QR, 12, 6);
    Rotated := RotateImageArbitrary(Img, 12.0);
    R := QRReadImage(Rotated);
    Check('Robustez rotacion arbitraria 12 grados: exito', R.Success);
    if R.Success then
      Check('Robustez rotacion arbitraria 12 grados: texto', R.Text = 'Rotacion arbitraria de 12 grados')
    else
      WriteLn('  (detalle del fallo: ', R.ErrorMessage, ')');
  finally
    QR.Free;
  end;

  // Ruido sal-y-pimienta con ECC alto
  QR := TQRCode.EncodeText('Prueba de ruido sal y pimienta', qeHigh);
  try
    Img := BuildGrayImageFromQR(QR, 8, 4);
    AddSaltPepperNoise(Img, 0.5, 12345);
    R := QRReadImage(Img);
    Check('Robustez ruido 0.5%: exito', R.Success);
    if R.Success then
      Check('Robustez ruido 0.5%: texto', R.Text = 'Prueba de ruido sal y pimienta')
    else
      WriteLn('  (detalle del fallo: ', R.ErrorMessage, ')');
  finally
    QR.Free;
  end;
end;

begin
  TestReaderSmoke;
  TestExternalImages;
  TestFileRoundTrip;
  TestRobustness;
  TestGFCrossCheck;
  TestReedSolomonDecodeNoErrors;
  TestReedSolomonDecodeWithinCapacity;
  TestReedSolomonDecodeBeyondCapacity;
  TestReedSolomonMultipleBlocks;
  TestBitStreamDecoder;
  TestMatrixDecodeRoundTrip;
  TestMatrixDecodeWithNoise;
  TestMatrixDecodeInvalidSize;

  WriteLn;
  WriteLn(Format('%d / %d tests passed', [GPassed, GTotal]));
  if GPassed < GTotal then
    Halt(1)
  else
    Halt(0);
end.
