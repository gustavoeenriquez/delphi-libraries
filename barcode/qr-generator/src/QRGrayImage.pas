unit QRGrayImage;

{
  QRGrayImage.pas -- Imagen en escala de grises simple (buffer de bytes,
  row-major), desacoplada de cualquier formato de archivo. Es el punto de
  entrada del pipeline de lectura: cualquier fuente de pixeles (PNG, JPEG,
  BMP, un frame de camara, etc.) solo necesita producir esta estructura.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils;

type
  EQRImageError = class(Exception);

  TQRGrayImage = record
    Width: Integer;
    Height: Integer;
    Pixels: TBytes; // Width*Height bytes, fila por fila, 0=negro..255=blanco
    function GetPixel(AX, AY: Integer): Byte; inline;
  end;

function QRGrayImageCreate(AWidth, AHeight: Integer): TQRGrayImage;

implementation

function QRGrayImageCreate(AWidth, AHeight: Integer): TQRGrayImage;
begin
  if (AWidth <= 0) or (AHeight <= 0) then
    raise EQRImageError.Create('QRGrayImageCreate: dimensiones invalidas');
  Result.Width := AWidth;
  Result.Height := AHeight;
  SetLength(Result.Pixels, AWidth * AHeight);
end;

{ TQRGrayImage }

function TQRGrayImage.GetPixel(AX, AY: Integer): Byte;
begin
  Result := Pixels[AY * Width + AX];
end;

end.
