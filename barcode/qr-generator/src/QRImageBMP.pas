unit QRImageBMP;

{
  QRImageBMP.pas -- Renderiza un TQRCode como bitmap Windows (BMP) 24 bits,
  sin compresion, sin dependencias externas (no usa Vcl.Graphics ni GDI+).

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Classes, QREncoder;

// Renderiza a un buffer BMP en memoria.
//   AScale     -- pixeles por modulo (>=1)
//   AQuietZone -- modulos de margen blanco alrededor del simbolo (recomendado >=4 por spec)
function QRRenderBMP(AQr: TQRCode; AScale: Integer = 8; AQuietZone: Integer = 4;
  ADarkColor: Cardinal = $000000; ALightColor: Cardinal = $FFFFFF): TBytes;

procedure QRSaveBMP(AQr: TQRCode; const AFileName: string; AScale: Integer = 8;
  AQuietZone: Integer = 4; ADarkColor: Cardinal = $000000; ALightColor: Cardinal = $FFFFFF);

implementation

type
  // Estructuras BMP empaquetadas manualmente en el stream (evita depender de
  // Windows.pas / TBitmapFileHeader, portable a otras plataformas).
  TBmpFileHeader = packed record
    bfType: Word;
    bfSize: Cardinal;
    bfReserved1: Word;
    bfReserved2: Word;
    bfOffBits: Cardinal;
  end;

  TBmpInfoHeader = packed record
    biSize: Cardinal;
    biWidth: Integer;
    biHeight: Integer;
    biPlanes: Word;
    biBitCount: Word;
    biCompression: Cardinal;
    biSizeImage: Cardinal;
    biXPelsPerMeter: Integer;
    biYPelsPerMeter: Integer;
    biClrUsed: Cardinal;
    biClrImportant: Cardinal;
  end;

function QRRenderBMP(AQr: TQRCode; AScale, AQuietZone: Integer; ADarkColor, ALightColor: Cardinal): TBytes;
var
  ImgSize, RowBytes, PixelDataSize: Integer;
  FileHdr: TBmpFileHeader;
  InfoHdr: TBmpInfoHeader;
  Stream: TMemoryStream;
  FileRow, X, ImgY, ModX, ModY, Pad: Integer;
  Color: Cardinal;
  B, G, R: Byte;
  ZeroBuf: array[0..3] of Byte;
begin
  if AScale < 1 then
    raise Exception.Create('QRRenderBMP: AScale debe ser >= 1');
  if AQuietZone < 0 then
    raise Exception.Create('QRRenderBMP: AQuietZone debe ser >= 0');

  ImgSize := (AQr.Size + AQuietZone * 2) * AScale;
  RowBytes := ((ImgSize * 3 + 3) div 4) * 4;
  PixelDataSize := RowBytes * ImgSize;

  FillChar(FileHdr, SizeOf(FileHdr), 0);
  FileHdr.bfType := $4D42; // 'BM'
  FileHdr.bfSize := SizeOf(TBmpFileHeader) + SizeOf(TBmpInfoHeader) + Cardinal(PixelDataSize);
  FileHdr.bfOffBits := SizeOf(TBmpFileHeader) + SizeOf(TBmpInfoHeader);

  FillChar(InfoHdr, SizeOf(InfoHdr), 0);
  InfoHdr.biSize := SizeOf(TBmpInfoHeader);
  InfoHdr.biWidth := ImgSize;
  InfoHdr.biHeight := ImgSize; // positivo = bottom-up
  InfoHdr.biPlanes := 1;
  InfoHdr.biBitCount := 24;
  InfoHdr.biCompression := 0; // BI_RGB
  InfoHdr.biSizeImage := PixelDataSize;
  InfoHdr.biXPelsPerMeter := 2835; // ~72 DPI
  InfoHdr.biYPelsPerMeter := 2835;

  Stream := TMemoryStream.Create;
  try
    Stream.WriteBuffer(FileHdr, SizeOf(FileHdr));
    Stream.WriteBuffer(InfoHdr, SizeOf(InfoHdr));

    Pad := RowBytes - ImgSize * 3;
    FillChar(ZeroBuf, SizeOf(ZeroBuf), 0);

    // BMP almacena filas de abajo hacia arriba.
    for FileRow := 0 to ImgSize - 1 do
    begin
      ImgY := ImgSize - 1 - FileRow;
      ModY := (ImgY div AScale) - AQuietZone;
      for X := 0 to ImgSize - 1 do
      begin
        ModX := (X div AScale) - AQuietZone;
        if (ModX >= 0) and (ModX < AQr.Size) and (ModY >= 0) and (ModY < AQr.Size) and AQr.GetModule(ModX, ModY) then
          Color := ADarkColor
        else
          Color := ALightColor;
        B := Color and $FF;
        G := (Color shr 8) and $FF;
        R := (Color shr 16) and $FF;
        Stream.WriteBuffer(B, 1);
        Stream.WriteBuffer(G, 1);
        Stream.WriteBuffer(R, 1);
      end;
      if Pad > 0 then
        Stream.WriteBuffer(ZeroBuf, Pad);
    end;

    SetLength(Result, Stream.Size);
    Stream.Position := 0;
    Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

procedure QRSaveBMP(AQr: TQRCode; const AFileName: string; AScale, AQuietZone: Integer;
  ADarkColor, ALightColor: Cardinal);
var
  Bytes: TBytes;
begin
  Bytes := QRRenderBMP(AQr, AScale, AQuietZone, ADarkColor, ALightColor);
  with TFileStream.Create(AFileName, fmCreate) do
    try
      WriteBuffer(Bytes[0], Length(Bytes));
    finally
      Free;
    end;
end;

end.
