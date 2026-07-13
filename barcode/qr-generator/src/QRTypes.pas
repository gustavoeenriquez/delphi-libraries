unit QRTypes;

{
  QRTypes.pas -- Tipos base, tablas ECC y utilidades de bajo nivel para QR Code
  (ISO/IEC 18004, QR Code Model 2, versiones 1-40).

  Las tablas ECC_CODEWORDS_PER_BLOCK / NUM_ERROR_CORRECTION_BLOCKS y las
  formulas GetNumRawDataModules / GetAlignmentPatternPositions estan portadas
  de "QR Code generator library" de Project Nayuki (MIT License):
  https://www.nayuki.io/page/qr-code-generator-library
  Ver LICENSE.md de esta libreria para el aviso de atribucion completo.

  License de esta libreria: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils;

type
  EQRError = class(Exception);

  // Nivel de correccion de errores. El orden del enum coincide con el indice
  // de fila usado en ECC_CODEWORDS_PER_BLOCK / NUM_ERROR_CORRECTION_BLOCKS.
  TQRErrorLevel = (qeLow, qeMedium, qeQuartile, qeHigh);

  // Modo de codificacion de un segmento de datos.
  TQRMode = (qmNumeric, qmAlphanumeric, qmByte, qmKanji, qmEci);

  // Grilla de modulos: True = oscuro (negro), False = claro (blanco).
  TQRBoolRow   = array of Boolean;
  TQRModuleGrid = array of TQRBoolRow;

  // Punto 2D de precision simple, usado por el pipeline de vision (deteccion
  // de patrones, transformacion de perspectiva).
  TQRPointF = record
    X, Y: Single;
  end;

  // Buffer de bits de longitud variable, empaquetado MSB-first (igual que
  // qrcodegen.c: appendBitsToBuffer). Usado para ensamblar segmentos y el
  // stream de datos final antes de aplicar Reed-Solomon.
  TQRBitBuffer = record
  private
    FBytes: TBytes;
    FBitLength: Integer;
    procedure EnsureCapacity(ARequiredBytes: Integer);
  public
    procedure Init;
    procedure AppendBits(AValue: Cardinal; ANumBits: Integer);
    procedure AppendBitBuffer(const AOther: TQRBitBuffer);
    function BitLength: Integer;
    function ToBytes: TBytes; // redondea a bytes completos (rellena con 0)
  end;

const
  QR_MIN_VERSION = 1;
  QR_MAX_VERSION = 40;

  // uint2 de nivel ECC empleado en la codificacion BCH de "format bits".
  // Orden: Low, Medium, Quartile, High (no es el mismo orden que el "ordinal").
  QR_FORMAT_BITS: array[TQRErrorLevel] of Byte = (1, 0, 3, 2);

  // Numero de codewords ECC por bloque. Indice de columna = version (1..40),
  // columna 0 sin usar (-1). Fuente: qrcodegen.py _ECC_CODEWORDS_PER_BLOCK.
  ECC_CODEWORDS_PER_BLOCK: array[TQRErrorLevel, 0..40] of ShortInt = (
    (-1,  7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),
    (-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28),
    (-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),
    (-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30)
  );

  // Numero de bloques de Reed-Solomon. Fuente: qrcodegen.py _NUM_ERROR_CORRECTION_BLOCKS.
  NUM_ERROR_CORRECTION_BLOCKS: array[TQRErrorLevel, 0..40] of ShortInt = (
    (-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4,  4,  4,  4,  4,  6,  6,  6,  6,  7,  8,  8,  9,  9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25),
    (-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5,  5,  8,  9,  9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49),
    (-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8,  8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68),
    (-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81)
  );

  // Penalizaciones para la seleccion automatica de mascara (ISO/IEC 18004 6.8.2)
  QR_PENALTY_N1 = 3;
  QR_PENALTY_N2 = 3;
  QR_PENALTY_N3 = 40;
  QR_PENALTY_N4 = 10;

// Ancho/alto en modulos de una version (21 para v1, +4 por version).
function QRSizeForVersion(AVersion: Integer): Integer; inline;

// Numero de bits crudos disponibles para datos+ECC (incluye remainder bits).
// Formula cerrada, ver qrcodegen.py _get_num_raw_data_modules.
function QRGetNumRawDataModules(AVersion: Integer): Integer;

// Numero de codewords de datos (8 bits) disponibles, descontando ECC.
function QRGetNumDataCodewords(AVersion: Integer; AEcl: TQRErrorLevel): Integer;

// Posiciones (ascendentes) de los centros de los patrones de alineacion.
// Se usan tanto en X como en Y; array vacio para version 1.
function QRGetAlignmentPatternPositions(AVersion: Integer): TArray<Integer>;

// Indicador de modo (4 bits) y ancho del campo "character count" segun version.
function QRModeBits(AMode: TQRMode): Byte;
function QRModeCharCountBits(AMode: TQRMode; AVersion: Integer): Integer;

// Las 8 funciones de mascara (ISO/IEC 18004 Table 10). Compartida entre
// QREncoder (ApplyMask) y QRMatrixDecoder (unmask, misma operacion XOR
// auto-inversa) para que ambos usen exactamente la misma definicion.
function QRMaskFunction(AMaskIdx, AX, AY: Integer): Integer;

implementation

function QRSizeForVersion(AVersion: Integer): Integer;
begin
  Result := AVersion * 4 + 17;
end;

function QRGetNumRawDataModules(AVersion: Integer): Integer;
var
  NumAlign: Integer;
begin
  if (AVersion < QR_MIN_VERSION) or (AVersion > QR_MAX_VERSION) then
    raise EQRError.CreateFmt('Version fuera de rango: %d', [AVersion]);
  Result := (16 * AVersion + 128) * AVersion + 64;
  if AVersion >= 2 then
  begin
    NumAlign := AVersion div 7 + 2;
    Result := Result - ((25 * NumAlign - 10) * NumAlign - 55);
    if AVersion >= 7 then
      Result := Result - 36;
  end;
end;

function QRGetNumDataCodewords(AVersion: Integer; AEcl: TQRErrorLevel): Integer;
begin
  Result := QRGetNumRawDataModules(AVersion) div 8
    - ECC_CODEWORDS_PER_BLOCK[AEcl, AVersion] * NUM_ERROR_CORRECTION_BLOCKS[AEcl, AVersion];
end;

function QRGetAlignmentPatternPositions(AVersion: Integer): TArray<Integer>;
var
  NumAlign, Step, Size, I: Integer;
  Tmp: TArray<Integer>;
begin
  if AVersion = 1 then
    Exit(nil);
  NumAlign := AVersion div 7 + 2;
  Step := (AVersion * 8 + NumAlign * 3 + 5) div (NumAlign * 4 - 4) * 2;
  Size := QRSizeForVersion(AVersion);
  SetLength(Tmp, NumAlign);
  // Genera de mayor a menor (como el borde derecho hacia adentro) y luego invierte.
  for I := 0 to NumAlign - 2 do
    Tmp[I] := Size - 7 - I * Step;
  Tmp[NumAlign - 1] := 6;
  SetLength(Result, NumAlign);
  for I := 0 to NumAlign - 1 do
    Result[I] := Tmp[NumAlign - 1 - I];
end;

function QRModeBits(AMode: TQRMode): Byte;
begin
  case AMode of
    qmNumeric:      Result := $1;
    qmAlphanumeric: Result := $2;
    qmByte:         Result := $4;
    qmKanji:        Result := $8;
    qmEci:          Result := $7;
  else
    Result := 0;
  end;
end;

function QRModeCharCountBits(AMode: TQRMode; AVersion: Integer): Integer;
const
  // [1-9, 10-26, 27-40]
  CC_NUMERIC:      array[0..2] of Integer = (10, 12, 14);
  CC_ALPHANUMERIC: array[0..2] of Integer = (9, 11, 13);
  CC_BYTE:         array[0..2] of Integer = (8, 16, 16);
  CC_KANJI:        array[0..2] of Integer = (8, 10, 12);
var
  Group: Integer;
begin
  Group := (AVersion + 7) div 17; // 1..9 -> 0 ; 10..26 -> 1 ; 27..40 -> 2
  case AMode of
    qmNumeric:      Result := CC_NUMERIC[Group];
    qmAlphanumeric: Result := CC_ALPHANUMERIC[Group];
    qmByte:         Result := CC_BYTE[Group];
    qmKanji:        Result := CC_KANJI[Group];
    qmEci:          Result := 0;
  else
    Result := 0;
  end;
end;

function QRMaskFunction(AMaskIdx, AX, AY: Integer): Integer;
begin
  case AMaskIdx of
    0: Result := (AX + AY) mod 2;
    1: Result := AY mod 2;
    2: Result := AX mod 3;
    3: Result := (AX + AY) mod 3;
    4: Result := (AX div 3 + AY div 2) mod 2;
    5: Result := (AX * AY) mod 2 + (AX * AY) mod 3;
    6: Result := ((AX * AY) mod 2 + (AX * AY) mod 3) mod 2;
    7: Result := ((AX + AY) mod 2 + (AX * AY) mod 3) mod 2;
  else
    raise EQRError.Create('Indice de mascara invalido');
  end;
end;

{ TQRBitBuffer }

procedure TQRBitBuffer.Init;
begin
  FBytes := nil;
  FBitLength := 0;
end;

procedure TQRBitBuffer.EnsureCapacity(ARequiredBytes: Integer);
var
  NewCap: Integer;
begin
  if Length(FBytes) >= ARequiredBytes then
    Exit;
  NewCap := Length(FBytes);
  if NewCap = 0 then
    NewCap := 16;
  while NewCap < ARequiredBytes do
    NewCap := NewCap * 2;
  SetLength(FBytes, NewCap);
end;

procedure TQRBitBuffer.AppendBits(AValue: Cardinal; ANumBits: Integer);
var
  I, Bit: Integer;
begin
  if (ANumBits < 0) or (ANumBits > 31) then
    raise EQRError.Create('ANumBits fuera de rango');
  if (ANumBits < 32) and (AValue shr ANumBits <> 0) then
    raise EQRError.Create('AValue no cabe en ANumBits bits');
  if ANumBits = 0 then
    Exit;
  EnsureCapacity((FBitLength + ANumBits + 7) shr 3);
  for I := ANumBits - 1 downto 0 do
  begin
    Bit := (AValue shr I) and 1;
    FBytes[FBitLength shr 3] := FBytes[FBitLength shr 3] or (Bit shl (7 - (FBitLength and 7)));
    Inc(FBitLength);
  end;
end;

procedure TQRBitBuffer.AppendBitBuffer(const AOther: TQRBitBuffer);
var
  I, Bit: Integer;
begin
  EnsureCapacity((FBitLength + AOther.FBitLength + 7) shr 3);
  for I := 0 to AOther.FBitLength - 1 do
  begin
    Bit := (AOther.FBytes[I shr 3] shr (7 - (I and 7))) and 1;
    FBytes[FBitLength shr 3] := FBytes[FBitLength shr 3] or (Bit shl (7 - (FBitLength and 7)));
    Inc(FBitLength);
  end;
end;

function TQRBitBuffer.BitLength: Integer;
begin
  Result := FBitLength;
end;

function TQRBitBuffer.ToBytes: TBytes;
begin
  SetLength(Result, (FBitLength + 7) shr 3);
  if Length(Result) > 0 then
    Move(FBytes[0], Result[0], Length(Result));
end;

end.
