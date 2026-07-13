program QRDemo;

{
  QRDemo.dpr -- generador de codigos QR por linea de comandos.

  Uso:
    QRDemo.exe <texto> <salida.png|salida.svg|salida.bmp> [L|M|Q|H] [escala] [quietzone]

  Ejemplo:
    QRDemo.exe "https://github.com/gustavoeenriquez/delphi-libraries" qr.png M 8 4

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$APPTYPE CONSOLE}

uses
  SysUtils,
  QRTypes,
  QREncoder,
  QRImageBMP,
  QRImageSVG,
  QRImagePNG;

procedure PrintUsage;
begin
  WriteLn('Uso: QRDemo.exe <texto> <salida.png|svg|bmp> [L|M|Q|H] [escala] [quietzone]');
  WriteLn('  L = Low (~7%), M = Medium (~15%, por defecto), Q = Quartile (~25%), H = High (~30%)');
end;

function ParseEcl(const S: string): TQRErrorLevel;
begin
  if S = '' then Exit(qeMedium);
  case UpCase(S[1]) of
    'L': Result := qeLow;
    'M': Result := qeMedium;
    'Q': Result := qeQuartile;
    'H': Result := qeHigh;
  else
    raise Exception.CreateFmt('Nivel ECC invalido: %s (use L/M/Q/H)', [S]);
  end;
end;

var
  Text, OutFile, Ext: string;
  Ecl: TQRErrorLevel;
  Scale, QuietZone: Integer;
  QR: TQRCode;
begin
  try
    if ParamCount < 2 then
    begin
      PrintUsage;
      Halt(1);
    end;

    Text := ParamStr(1);
    OutFile := ParamStr(2);
    Ecl := qeMedium;
    if ParamCount >= 3 then Ecl := ParseEcl(ParamStr(3));
    Scale := 8;
    if ParamCount >= 4 then Scale := StrToInt(ParamStr(4));
    QuietZone := 4;
    if ParamCount >= 5 then QuietZone := StrToInt(ParamStr(5));

    QR := TQRCode.EncodeText(Text, Ecl);
    try
      WriteLn(Format('Version: %d  Tamano: %dx%d modulos  ECC: %d  Mascara: %d',
        [QR.Version, QR.Size, QR.Size, Ord(QR.ErrorLevel), QR.Mask]));

      Ext := LowerCase(ExtractFileExt(OutFile));
      if Ext = '.png' then
        QRSavePNG(QR, OutFile, Scale, QuietZone)
      else if Ext = '.svg' then
        QRSaveSVG(QR, OutFile, Scale, QuietZone)
      else if Ext = '.bmp' then
        QRSaveBMP(QR, OutFile, Scale, QuietZone)
      else
        raise Exception.Create('Extension no soportada: use .png, .svg o .bmp');

      WriteLn('Escrito: ', OutFile);
    finally
      QR.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn('Error: ', E.Message);
      Halt(1);
    end;
  end;
end.
