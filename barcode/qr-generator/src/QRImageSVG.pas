unit QRImageSVG;

{
  QRImageSVG.pas -- Renderiza un TQRCode como SVG vectorial (texto plano).
  Fusiona modulos oscuros consecutivos de cada fila en un solo <rect> para
  mantener el archivo compacto incluso en versiones grandes (v40 = 177x177).

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Classes, IOUtils, QREncoder;

// AModuleSize -- tamano en unidades SVG (px logicos) de cada modulo.
// AQuietZone  -- modulos de margen blanco alrededor del simbolo.
function QRRenderSVG(AQr: TQRCode; AModuleSize: Integer = 10; AQuietZone: Integer = 4;
  const ADarkColor: string = '#000000'; const ALightColor: string = '#ffffff'): string;

procedure QRSaveSVG(AQr: TQRCode; const AFileName: string; AModuleSize: Integer = 10;
  AQuietZone: Integer = 4; const ADarkColor: string = '#000000'; const ALightColor: string = '#ffffff');

implementation

function QRRenderSVG(AQr: TQRCode; AModuleSize, AQuietZone: Integer;
  const ADarkColor, ALightColor: string): string;
var
  SB: TStringBuilder;
  TotalModules: Integer;
  ViewSize: Integer;
  Y, X, RunStart: Integer;
  InRun: Boolean;
begin
  if AModuleSize < 1 then
    raise Exception.Create('QRRenderSVG: AModuleSize debe ser >= 1');
  if AQuietZone < 0 then
    raise Exception.Create('QRRenderSVG: AQuietZone debe ser >= 0');

  TotalModules := AQr.Size + AQuietZone * 2;
  ViewSize := TotalModules * AModuleSize;

  SB := TStringBuilder.Create;
  try
    SB.Append(Format('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" shape-rendering="crispEdges">',
      [ViewSize, ViewSize, ViewSize, ViewSize]));
    SB.Append(Format('<rect x="0" y="0" width="%d" height="%d" fill="%s"/>', [ViewSize, ViewSize, ALightColor]));
    SB.Append(Format('<g fill="%s">', [ADarkColor]));

    for Y := 0 to AQr.Size - 1 do
    begin
      InRun := False;
      RunStart := 0;
      for X := 0 to AQr.Size - 1 do
      begin
        if AQr.GetModule(X, Y) then
        begin
          if not InRun then
          begin
            InRun := True;
            RunStart := X;
          end;
        end
        else if InRun then
        begin
          SB.Append(Format('<rect x="%d" y="%d" width="%d" height="%d"/>',
            [(RunStart + AQuietZone) * AModuleSize, (Y + AQuietZone) * AModuleSize,
             (X - RunStart) * AModuleSize, AModuleSize]));
          InRun := False;
        end;
      end;
      if InRun then
        SB.Append(Format('<rect x="%d" y="%d" width="%d" height="%d"/>',
          [(RunStart + AQuietZone) * AModuleSize, (Y + AQuietZone) * AModuleSize,
           (AQr.Size - RunStart) * AModuleSize, AModuleSize]));
    end;

    SB.Append('</g></svg>');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure QRSaveSVG(AQr: TQRCode; const AFileName: string; AModuleSize, AQuietZone: Integer;
  const ADarkColor, ALightColor: string);
begin
  TFile.WriteAllText(AFileName, QRRenderSVG(AQr, AModuleSize, AQuietZone, ADarkColor, ALightColor), TEncoding.UTF8);
end;

end.
