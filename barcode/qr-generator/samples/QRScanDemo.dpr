program QRScanDemo;

{
  QRScanDemo.dpr -- lector de codigos QR por linea de comandos.

  Uso:
    QRScanDemo.exe <imagen.png|jpg|bmp>

  Ejemplo:
    QRScanDemo.exe foto_qr.jpg

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$APPTYPE CONSOLE}

uses
  SysUtils,
  QRTypes,
  QRGrayImage,
  QRBinarizer,
  QRFinderPatternFinder,
  QRAlignmentPatternFinder,
  QRPerspectiveTransform,
  QRReedSolomonDecoder,
  QRBitStreamDecoder,
  QRMatrixDecoder,
  QRReader,
  QRImageLoader;

var
  Img: TQRGrayImage;
  R: TQRReadResult;
begin
  try
    if ParamCount < 1 then
    begin
      WriteLn('Uso: QRScanDemo.exe <imagen.png|jpg|bmp>');
      Halt(1);
    end;

    Img := QRLoadGrayImage(ParamStr(1));
    R := QRReadImage(Img);

    if R.Success then
    begin
      WriteLn('Texto: ', R.Text);
      WriteLn(Format('Version: %d  ECC: %d  Mascara: %d  Errores corregidos: %d',
        [R.Version, Ord(R.ErrorLevel), R.Mask, R.NumErrorsCorrected]));
      if Length(R.EciValues) > 0 then
        WriteLn('ECI detectados: ', Length(R.EciValues));
      if Length(R.KanjiSjisBytes) > 0 then
        WriteLn(Format('Bytes Kanji (Shift-JIS): %d', [Length(R.KanjiSjisBytes)]));
    end
    else
    begin
      WriteLn('No se pudo decodificar: ', R.ErrorMessage);
      Halt(2);
    end;
  except
    on E: Exception do
    begin
      WriteLn('Error: ', E.Message);
      Halt(1);
    end;
  end;
end.
