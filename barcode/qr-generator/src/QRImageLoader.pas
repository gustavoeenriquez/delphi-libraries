unit QRImageLoader;

{
  QRImageLoader.pas -- Carga BMP/PNG/JPEG (y cualquier otro formato que la
  VCL sepa abrir) y los convierte a TQRGrayImage (escala de grises) para
  alimentar QRReader.QRReadImage.

  A diferencia del resto de esta libreria (deliberadamente sin Vcl.Graphics,
  ver README.md), esta es la UNICA unidad con esa dependencia: escribir un
  decodificador JPEG propio esta fuera de alcance de un lector de codigos QR,
  y Vcl.Graphics/Vcl.Imaging ya resuelven bien "abrir un archivo de imagen".
  Es deliberadamente opcional y aislada -- si no la necesitas (por ejemplo,
  ya tienes los pixeles de otra fuente como una camara o Skia4Delphi), no la
  incluyas en tu uses y usa QRGrayImageCreate directamente.

  Solo Windows (VCL). Para FMX/Linux, construye tu propio TQRGrayImage desde
  la fuente de pixeles que tengas disponible.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Vcl.Graphics, Vcl.Imaging.pngimage, Vcl.Imaging.jpeg, QRGrayImage;

// Carga cualquier archivo de imagen soportado por la VCL (BMP, PNG, JPEG, ...)
// y lo convierte a escala de grises (luminancia perceptual ITU-R BT.601).
function QRLoadGrayImage(const AFileName: string): TQRGrayImage;

implementation

function QRLoadGrayImage(const AFileName: string): TQRGrayImage;
var
  Pic: TPicture;
  Bmp: TBitmap;
  X, Y: Integer;
  Row: PByteArray;
  R, G, B: Byte;
begin
  Pic := TPicture.Create;
  try
    Pic.LoadFromFile(AFileName);
    Bmp := TBitmap.Create;
    try
      Bmp.PixelFormat := pf24bit;
      Bmp.SetSize(Pic.Width, Pic.Height);
      Bmp.Canvas.Draw(0, 0, Pic.Graphic);

      Result := QRGrayImageCreate(Bmp.Width, Bmp.Height);
      for Y := 0 to Bmp.Height - 1 do
      begin
        Row := Bmp.ScanLine[Y];
        for X := 0 to Bmp.Width - 1 do
        begin
          B := Row[X * 3];
          G := Row[X * 3 + 1];
          R := Row[X * 3 + 2];
          Result.Pixels[Y * Bmp.Width + X] := (R * 299 + G * 587 + B * 114) div 1000;
        end;
      end;
    finally
      Bmp.Free;
    end;
  finally
    Pic.Free;
  end;
end;

end.
