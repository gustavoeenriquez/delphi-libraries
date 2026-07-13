unit QRBitStreamDecoder;

{
  QRBitStreamDecoder.pas -- Inverso de QRSegment: parsea el stream de bytes de
  datos ya corregido (post Reed-Solomon) de vuelta a texto, siguiendo
  ISO/IEC 18004 §7.4 (indicador de modo, character count, payload) hasta el
  terminador o el fin de los datos.

  Alcance (igual que el encoder, ver README.md):
    - Numeric, Alphanumeric, Byte (UTF-8), Kanji (Shift-JIS crudo), ECI: soportados.
    - Structured Append, FNC1 (primera/segunda posicion), Hanzi (GB2312):
      NO soportados -- se reporta EQRBitStreamError en vez de interpretar mal los bits.

  Algoritmo de referencia: ZXing (Apache License 2.0), DecodedBitStreamParser.java
  https://github.com/zxing/zxing
  Ver README.md de esta libreria para el aviso de atribucion completo.

  License de esta libreria: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Classes, Generics.Collections, QRTypes;

type
  EQRBitStreamError = class(Exception);

  TQRDecodedResult = record
    Text: string;             // numeric + alphanumeric + byte(UTF-8) concatenados, en orden
    KanjiSjisBytes: TBytes;   // bytes Shift-JIS crudos de segmentos kanji (concatenados)
    EciValues: TArray<Integer>; // designadores ECI encontrados, en orden de aparicion
  end;

  TQRBitReader = record
  private
    FData: TBytes;
    FBitPos: Integer;
  public
    procedure Init(const AData: TBytes);
    function Available: Integer;
    function ReadBits(ANumBits: Integer): Integer;
  end;

// AVersion se usa solo para determinar el ancho del character count indicator.
function QRDecodeBitStream(const AData: TBytes; AVersion: Integer): TQRDecodedResult;

implementation

const
  ALPHANUMERIC_CHARS = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';

{ TQRBitReader }

procedure TQRBitReader.Init(const AData: TBytes);
begin
  FData := AData;
  FBitPos := 0;
end;

function TQRBitReader.Available: Integer;
begin
  Result := Length(FData) * 8 - FBitPos;
end;

function TQRBitReader.ReadBits(ANumBits: Integer): Integer;
var
  I, Bit: Integer;
begin
  if (ANumBits < 0) or (ANumBits > 24) then
    raise EQRBitStreamError.Create('ReadBits: ANumBits fuera de rango');
  if ANumBits > Available then
    raise EQRBitStreamError.Create('ReadBits: no quedan suficientes bits');
  Result := 0;
  for I := 0 to ANumBits - 1 do
  begin
    Bit := (FData[FBitPos shr 3] shr (7 - (FBitPos and 7))) and 1;
    Result := (Result shl 1) or Bit;
    Inc(FBitPos);
  end;
end;

function ToAlphanumericChar(AValue: Integer): Char;
begin
  if (AValue < 0) or (AValue >= Length(ALPHANUMERIC_CHARS)) then
    raise EQRBitStreamError.CreateFmt('Valor alfanumerico invalido: %d', [AValue]);
  Result := ALPHANUMERIC_CHARS[AValue + 1];
end;

procedure DecodeNumericSegment(var ABits: TQRBitReader; ASB: TStringBuilder; ACount: Integer);
var
  V: Integer;
begin
  while ACount >= 3 do
  begin
    V := ABits.ReadBits(10);
    if V >= 1000 then
      raise EQRBitStreamError.Create('Numeric: grupo de 3 digitos invalido (>=1000)');
    ASB.Append(ToAlphanumericChar(V div 100));
    ASB.Append(ToAlphanumericChar((V div 10) mod 10));
    ASB.Append(ToAlphanumericChar(V mod 10));
    Dec(ACount, 3);
  end;
  if ACount = 2 then
  begin
    V := ABits.ReadBits(7);
    if V >= 100 then
      raise EQRBitStreamError.Create('Numeric: grupo de 2 digitos invalido (>=100)');
    ASB.Append(ToAlphanumericChar(V div 10));
    ASB.Append(ToAlphanumericChar(V mod 10));
  end
  else if ACount = 1 then
  begin
    V := ABits.ReadBits(4);
    if V >= 10 then
      raise EQRBitStreamError.Create('Numeric: digito final invalido (>=10)');
    ASB.Append(ToAlphanumericChar(V));
  end;
end;

procedure DecodeAlphanumericSegment(var ABits: TQRBitReader; ASB: TStringBuilder; ACount: Integer);
var
  V: Integer;
begin
  while ACount > 1 do
  begin
    V := ABits.ReadBits(11);
    ASB.Append(ToAlphanumericChar(V div 45));
    ASB.Append(ToAlphanumericChar(V mod 45));
    Dec(ACount, 2);
  end;
  if ACount = 1 then
    ASB.Append(ToAlphanumericChar(ABits.ReadBits(6)));
end;

procedure DecodeByteSegment(var ABits: TQRBitReader; ASB: TStringBuilder; ACount: Integer);
var
  Buf: TBytes;
  I: Integer;
begin
  SetLength(Buf, ACount);
  for I := 0 to ACount - 1 do
    Buf[I] := Byte(ABits.ReadBits(8));
  ASB.Append(TEncoding.UTF8.GetString(Buf));
end;

procedure DecodeKanjiSegment(var ABits: TQRBitReader; AKanjiBytes: TList<Byte>; ACount: Integer);
var
  I, TwoBytes, Assembled: Integer;
begin
  for I := 0 to ACount - 1 do
  begin
    TwoBytes := ABits.ReadBits(13);
    Assembled := ((TwoBytes div $C0) shl 8) or (TwoBytes mod $C0);
    if Assembled < $1F00 then
      Inc(Assembled, $8140)
    else
      Inc(Assembled, $C140);
    AKanjiBytes.Add(Byte(Assembled shr 8));
    AKanjiBytes.Add(Byte(Assembled and $FF));
  end;
end;

function ParseEciValue(var ABits: TQRBitReader): Integer;
var
  FirstByte, SecondByte, ThirdFourth: Integer;
begin
  FirstByte := ABits.ReadBits(8);
  if (FirstByte and $80) = 0 then
    Exit(FirstByte and $7F);
  if (FirstByte and $C0) = $80 then
  begin
    SecondByte := ABits.ReadBits(8);
    Exit(((FirstByte and $3F) shl 8) or SecondByte);
  end;
  if (FirstByte and $E0) = $C0 then
  begin
    ThirdFourth := ABits.ReadBits(16);
    Exit(((FirstByte and $1F) shl 16) or ThirdFourth);
  end;
  raise EQRBitStreamError.Create('ECI: prefijo de designador invalido');
end;

function QRDecodeBitStream(const AData: TBytes; AVersion: Integer): TQRDecodedResult;
var
  Bits: TQRBitReader;
  SB: TStringBuilder;
  KanjiBytes: TList<Byte>;
  EciList: TList<Integer>;
  ModeBits, Count: Integer;
  Mode: TQRMode;
  Done: Boolean;
  I: Integer;
begin
  Bits.Init(AData);
  SB := TStringBuilder.Create;
  KanjiBytes := TList<Byte>.Create;
  EciList := TList<Integer>.Create;
  try
    Done := False;
    while not Done do
    begin
      if Bits.Available < 4 then
        Break; // se asume terminador implicito (datos agotados)

      ModeBits := Bits.ReadBits(4);
      case ModeBits of
        $0: Done := True; // terminador
        $7: EciList.Add(ParseEciValue(Bits));
        $1, $2, $4, $8:
        begin
          case ModeBits of
            $1: Mode := qmNumeric;
            $2: Mode := qmAlphanumeric;
            $4: Mode := qmByte;
          else
            Mode := qmKanji;
          end;
          Count := Bits.ReadBits(QRModeCharCountBits(Mode, AVersion));
          case Mode of
            qmNumeric:      DecodeNumericSegment(Bits, SB, Count);
            qmAlphanumeric: DecodeAlphanumericSegment(Bits, SB, Count);
            qmByte:         DecodeByteSegment(Bits, SB, Count);
            qmKanji:        DecodeKanjiSegment(Bits, KanjiBytes, Count);
          end;
        end;
        $3: raise EQRBitStreamError.Create('Modo "Structured Append" no soportado');
        $5, $9: raise EQRBitStreamError.Create('Modo FNC1 no soportado');
        $D: raise EQRBitStreamError.Create('Modo Hanzi (GB2312) no soportado');
      else
        raise EQRBitStreamError.CreateFmt('Indicador de modo desconocido: 0x%X', [ModeBits]);
      end;
    end;

    Result.Text := SB.ToString;
    SetLength(Result.KanjiSjisBytes, KanjiBytes.Count);
    for I := 0 to KanjiBytes.Count - 1 do
      Result.KanjiSjisBytes[I] := KanjiBytes[I];
    SetLength(Result.EciValues, EciList.Count);
    for I := 0 to EciList.Count - 1 do
      Result.EciValues[I] := EciList[I];
  finally
    SB.Free;
    KanjiBytes.Free;
    EciList.Free;
  end;
end;

end.
