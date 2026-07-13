unit QRSegment;

{
  QRSegment.pas -- Segmentos de datos QR: numerico, alfanumerico, byte, kanji y ECI.

  Cada TQRSegment guarda su modo, el numero de caracteres originales (para el
  campo "character count indicator") y los bits ya codificados listos para
  concatenar en el stream final (sin el indicador de modo ni el character count,
  que dependen de la version elegida y se anteponen en QREncoder).

  Portado / verificado contra "QR Code generator library" de Project Nayuki
  (MIT License): https://www.nayuki.io/page/qr-code-generator-library

  License de esta libreria: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Math, QRTypes;

type
  TQRSegment = record
    Mode: TQRMode;
    NumChars: Integer;
    Bits: TQRBitBuffer;
  end;
  TQRSegmentArray = TArray<TQRSegment>;

function QRIsNumeric(const AText: string): Boolean;
function QRIsAlphanumeric(const AText: string): Boolean;

function QRMakeNumeric(const ADigits: string): TQRSegment;
function QRMakeAlphanumeric(const AText: string): TQRSegment;
function QRMakeBytes(const AData: TBytes): TQRSegment;
function QRMakeEci(AAssignVal: Integer): TQRSegment;

// Modo Kanji (ISO/IEC 18004 8.4.5): recibe pares de bytes ya codificados en
// Shift_JIS (rangos 0x8140-0x9FFC o 0xE040-0xEBBF). No se detecta ni convierte
// texto Unicode automaticamente -- el llamador debe suministrar los bytes SJIS.
function QRMakeKanji(const ASjisBytes: TBytes): TQRSegment;

// Selecciona automaticamente el modo mas compacto para todo el string:
// numerico > alfanumerico > byte (UTF-8). No mezcla modos dentro del mismo
// texto (igual que QrSegment.make_segments en la libreria de referencia).
function QRMakeSegments(const AText: string): TQRSegmentArray;

// Bits totales (indicador de modo + character count + payload) para la
// version dada. Devuelve -1 si algun segmento no cabe en su campo de conteo.
function QRGetTotalBits(const ASegs: TQRSegmentArray; AVersion: Integer): Integer;

implementation

const
  ALPHANUMERIC_CHARS = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';

function AlphanumericIndex(Ch: Char; out AIndex: Integer): Boolean;
var
  P: Integer;
begin
  P := Pos(Ch, ALPHANUMERIC_CHARS);
  Result := P > 0;
  if Result then
    AIndex := P - 1;
end;

function QRIsNumeric(const AText: string): Boolean;
var
  Ch: Char;
begin
  for Ch in AText do
    if not CharInSet(Ch, ['0'..'9']) then
      Exit(False);
  Result := True;
end;

function QRIsAlphanumeric(const AText: string): Boolean;
var
  Ch: Char;
  Idx: Integer;
begin
  for Ch in AText do
    if not AlphanumericIndex(Ch, Idx) then
      Exit(False);
  Result := True;
end;

function QRMakeNumeric(const ADigits: string): TQRSegment;
var
  I, N, ChunkVal, J: Integer;
begin
  if not QRIsNumeric(ADigits) then
    raise EQRError.Create('QRMakeNumeric: el texto contiene caracteres no numericos');
  Result.Mode := qmNumeric;
  Result.NumChars := Length(ADigits);
  Result.Bits.Init;
  I := 1;
  while I <= Length(ADigits) do
  begin
    N := Min(3, Length(ADigits) - I + 1);
    ChunkVal := 0;
    for J := 0 to N - 1 do
      ChunkVal := ChunkVal * 10 + (Ord(ADigits[I + J]) - Ord('0'));
    Result.Bits.AppendBits(ChunkVal, N * 3 + 1);
    Inc(I, N);
  end;
end;

function QRMakeAlphanumeric(const AText: string): TQRSegment;
var
  I, Idx1, Idx2, Temp: Integer;
begin
  if not QRIsAlphanumeric(AText) then
    raise EQRError.Create('QRMakeAlphanumeric: el texto contiene caracteres no soportados');
  Result.Mode := qmAlphanumeric;
  Result.NumChars := Length(AText);
  Result.Bits.Init;
  I := 1;
  while I + 1 <= Length(AText) do
  begin
    AlphanumericIndex(AText[I], Idx1);
    AlphanumericIndex(AText[I + 1], Idx2);
    Temp := Idx1 * 45 + Idx2;
    Result.Bits.AppendBits(Temp, 11);
    Inc(I, 2);
  end;
  if I = Length(AText) then // 1 caracter restante
  begin
    AlphanumericIndex(AText[I], Idx1);
    Result.Bits.AppendBits(Idx1, 6);
  end;
end;

function QRMakeBytes(const AData: TBytes): TQRSegment;
var
  B: Byte;
begin
  Result.Mode := qmByte;
  Result.NumChars := Length(AData);
  Result.Bits.Init;
  for B in AData do
    Result.Bits.AppendBits(B, 8);
end;

function QRMakeEci(AAssignVal: Integer): TQRSegment;
begin
  Result.Mode := qmEci;
  Result.NumChars := 0;
  Result.Bits.Init;
  if AAssignVal < 0 then
    raise EQRError.Create('QRMakeEci: valor negativo')
  else if AAssignVal < (1 shl 7) then
    Result.Bits.AppendBits(AAssignVal, 8)
  else if AAssignVal < (1 shl 14) then
  begin
    Result.Bits.AppendBits($2, 2);
    Result.Bits.AppendBits(AAssignVal, 14);
  end
  else if AAssignVal < 1000000 then
  begin
    Result.Bits.AppendBits($6, 3);
    Result.Bits.AppendBits(AAssignVal, 21);
  end
  else
    raise EQRError.Create('QRMakeEci: valor fuera de rango');
end;

function QRMakeKanji(const ASjisBytes: TBytes): TQRSegment;
var
  I: Integer;
  Hi, Lo: Byte;
  Val: Integer;
begin
  if Length(ASjisBytes) mod 2 <> 0 then
    raise EQRError.Create('QRMakeKanji: numero impar de bytes Shift-JIS');
  Result.Mode := qmKanji;
  Result.NumChars := Length(ASjisBytes) div 2;
  Result.Bits.Init;
  I := 0;
  while I < Length(ASjisBytes) do
  begin
    Hi := ASjisBytes[I];
    Lo := ASjisBytes[I + 1];
    Val := (Hi shl 8) or Lo;
    if (Val >= $8140) and (Val <= $9FFC) then
      Val := Val - $8140
    else if (Val >= $E040) and (Val <= $EBBF) then
      Val := Val - $C140
    else
      raise EQRError.CreateFmt('QRMakeKanji: par de bytes 0x%.4x fuera de rango Shift-JIS', [Val]);
    Val := (Val shr 8) * $C0 + (Val and $FF);
    Result.Bits.AppendBits(Val, 13);
    Inc(I, 2);
  end;
end;

function QRMakeSegments(const AText: string): TQRSegmentArray;
begin
  if AText = '' then
    Exit(nil);
  SetLength(Result, 1);
  if QRIsNumeric(AText) then
    Result[0] := QRMakeNumeric(AText)
  else if QRIsAlphanumeric(AText) then
    Result[0] := QRMakeAlphanumeric(AText)
  else
    Result[0] := QRMakeBytes(TEncoding.UTF8.GetBytes(AText));
end;

function QRGetTotalBits(const ASegs: TQRSegmentArray; AVersion: Integer): Integer;
var
  Seg: TQRSegment;
  CcBits: Integer;
begin
  Result := 0;
  for Seg in ASegs do
  begin
    CcBits := QRModeCharCountBits(Seg.Mode, AVersion);
    if Seg.NumChars >= (1 shl CcBits) then
      Exit(-1);
    Result := Result + 4 + CcBits + Seg.Bits.BitLength;
  end;
end;

end.
