unit QRReader;

{
  QRReader.pas -- Orquestador de alto nivel del lector de codigos QR: recibe
  una imagen en escala de grises (TQRGrayImage) y devuelve el texto
  decodificado, sin asumir que el simbolo este derecho, centrado ni sin
  perspectiva -- soporta fotos con rotacion arbitraria, inclinacion (skew)
  moderada e iluminacion despareja.

  Pipeline: binarizar (QRBinarizer) -> localizar los 3 patrones buscadores
  (QRFinderPatternFinder) -> estimar tamano de modulo y dimension del simbolo
  -> localizar el patron de alineacion si aplica (QRAlignmentPatternFinder)
  -> construir la transformacion de perspectiva y muestrear la grilla
  (QRPerspectiveTransform) -> decodificar la grilla (QRMatrixDecoder).

  La estimacion de tamano de modulo (metodo de Bresenham) y la construccion
  de la transformacion estan portadas de ZXing (Apache License 2.0):
  Detector.java
  https://github.com/zxing/zxing
  Ver README.md de esta libreria para el aviso de atribucion completo.

  License de esta libreria: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Math, QRTypes, QRGrayImage, QRBinarizer, QRFinderPatternFinder,
  QRAlignmentPatternFinder, QRPerspectiveTransform, QRMatrixDecoder;

type
  TQRReadResult = record
    Success: Boolean;
    ErrorMessage: string;
    Text: string;
    Version: Integer;
    ErrorLevel: TQRErrorLevel;
    Mask: Integer;
    NumErrorsCorrected: Integer;
    KanjiSjisBytes: TBytes;
    EciValues: TArray<Integer>;
    // Diagnostico: centros de los patrones buscadores detectados (espacio pixel).
    TopLeft, TopRight, BottomLeft: TQRPointF;
    ModuleSize: Single;
  end;

function QRReadImage(const AImage: TQRGrayImage): TQRReadResult;

implementation

function ToPointF(const AFinder: TQRFinderPattern): TQRPointF; inline;
begin
  Result.X := AFinder.X;
  Result.Y := AFinder.Y;
end;

function FailResult(const AMsg: string): TQRReadResult;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Success := False;
  Result.ErrorMessage := AMsg;
end;

// ---------------------------------------------------------------------------
// Estimacion del tamano de modulo: traza una linea (variante de Bresenham)
// entre los centros de dos patrones buscadores y mide el ancho negro-blanco-
// negro central, en ambas direcciones, para promediar.
// ---------------------------------------------------------------------------

function SizeOfBlackWhiteBlackRun(const AImage: TQRModuleGrid; AImgWidth, AImgHeight: Integer;
  AFromX, AFromY, AToX, AToY: Integer): Single;
var
  Steep: Boolean;
  Temp, DX, DY, ErrorAcc, XStep, YStep, X, Y, XLimit, RealX, RealY: Integer;
  State: Integer;
begin
  Steep := Abs(AToY - AFromY) > Abs(AToX - AFromX);
  if Steep then
  begin
    Temp := AFromX; AFromX := AFromY; AFromY := Temp;
    Temp := AToX; AToX := AToY; AToY := Temp;
  end;

  DX := Abs(AToX - AFromX);
  DY := Abs(AToY - AFromY);
  ErrorAcc := -DX div 2;
  if AFromX < AToX then XStep := 1 else XStep := -1;
  if AFromY < AToY then YStep := 1 else YStep := -1;

  State := 0;
  XLimit := AToX + XStep;
  X := AFromX; Y := AFromY;
  while X <> XLimit do
  begin
    if Steep then begin RealX := Y; RealY := X; end
    else begin RealX := X; RealY := Y; end;

    if (RealX < 0) or (RealX >= AImgWidth) or (RealY < 0) or (RealY >= AImgHeight) then
      Break;

    if (State = 1) = AImage[RealY, RealX] then
    begin
      if State = 2 then
        Exit(Sqrt(Sqr(Single(X - AFromX)) + Sqr(Single(Y - AFromY))));
      Inc(State);
    end;

    Inc(ErrorAcc, DY);
    if ErrorAcc > 0 then
    begin
      if Y = AToY then Break;
      Inc(Y, YStep);
      Dec(ErrorAcc, DX);
    end;
    Inc(X, XStep);
  end;

  if State = 2 then
    Exit(Sqrt(Sqr(Single(AToX + XStep - AFromX)) + Sqr(Single(AToY - AFromY))));
  Result := NaN;
end;

function SizeOfBlackWhiteBlackRunBothWays(const AImage: TQRModuleGrid; AImgWidth, AImgHeight: Integer;
  AFromX, AFromY, AToX, AToY: Integer): Single;
var
  ResultVal, Scale: Single;
  OtherToX, OtherToY: Integer;
begin
  ResultVal := SizeOfBlackWhiteBlackRun(AImage, AImgWidth, AImgHeight, AFromX, AFromY, AToX, AToY);

  Scale := 1.0;
  OtherToX := AFromX - (AToX - AFromX);
  if OtherToX < 0 then
  begin
    Scale := AFromX / Single(AFromX - OtherToX);
    OtherToX := 0;
  end
  else if OtherToX >= AImgWidth then
  begin
    Scale := (AImgWidth - 1 - AFromX) / Single(OtherToX - AFromX);
    OtherToX := AImgWidth - 1;
  end;
  OtherToY := Trunc(AFromY - (AToY - AFromY) * Scale);

  Scale := 1.0;
  if OtherToY < 0 then
  begin
    Scale := AFromY / Single(AFromY - OtherToY);
    OtherToY := 0;
  end
  else if OtherToY >= AImgHeight then
  begin
    Scale := (AImgHeight - 1 - AFromY) / Single(OtherToY - AFromY);
    OtherToY := AImgHeight - 1;
  end;
  OtherToX := Trunc(AFromX + (OtherToX - AFromX) * Scale);

  ResultVal := ResultVal + SizeOfBlackWhiteBlackRun(AImage, AImgWidth, AImgHeight, AFromX, AFromY, OtherToX, OtherToY);
  Result := ResultVal - 1.0;
end;

function CalculateModuleSizeOneWay(const AImage: TQRModuleGrid; AImgWidth, AImgHeight: Integer;
  const APattern, AOtherPattern: TQRPointF): Single;
var
  Est1, Est2: Single;
begin
  Est1 := SizeOfBlackWhiteBlackRunBothWays(AImage, AImgWidth, AImgHeight,
    Trunc(APattern.X), Trunc(APattern.Y), Trunc(AOtherPattern.X), Trunc(AOtherPattern.Y));
  Est2 := SizeOfBlackWhiteBlackRunBothWays(AImage, AImgWidth, AImgHeight,
    Trunc(AOtherPattern.X), Trunc(AOtherPattern.Y), Trunc(APattern.X), Trunc(APattern.Y));
  if IsNan(Est1) then Exit(Est2 / 7.0);
  if IsNan(Est2) then Exit(Est1 / 7.0);
  Result := (Est1 + Est2) / 14.0;
end;

function CalculateModuleSize(const AImage: TQRModuleGrid; AImgWidth, AImgHeight: Integer;
  const ATopLeft, ATopRight, ABottomLeft: TQRPointF): Single;
begin
  Result := (CalculateModuleSizeOneWay(AImage, AImgWidth, AImgHeight, ATopLeft, ATopRight) +
             CalculateModuleSizeOneWay(AImage, AImgWidth, AImgHeight, ATopLeft, ABottomLeft)) / 2.0;
end;

function ComputeDimension(const ATopLeft, ATopRight, ABottomLeft: TQRPointF; AModuleSize: Single): Integer;
var
  TlTr, TlBl, Dimension: Integer;
begin
  TlTr := Round(QRPointDistance(ATopLeft, ATopRight) / AModuleSize);
  TlBl := Round(QRPointDistance(ATopLeft, ABottomLeft) / AModuleSize);
  Dimension := ((TlTr + TlBl) div 2) + 7;
  case Dimension and 3 of
    0: Inc(Dimension);
    2: Dec(Dimension);
    3: Dec(Dimension, 2);
  end;
  Result := Dimension;
end;

function QRReadImage(const AImage: TQRGrayImage): TQRReadResult;
var
  Binary: TQRModuleGrid;
  FinderInfo: TQRFinderPatternInfo;
  ModuleSize: Single;
  Dimension, ProvisionalVersion: Integer;
  AlignPositions: TArray<Integer>;
  HasAlignment, FoundAlign: Boolean;
  BottomRightX, BottomRightY, SourceBRX, SourceBRY, DimMinusThree: Single;
  EstAlignX, EstAlignY: Integer;
  ModulesBetweenFPCenters: Integer;
  AlignPt: TQRPointF;
  Transform: TQRPerspectiveTransform;
  Grid: TQRModuleGrid;
  DecodeResult: TQRMatrixDecodeResult;
  I, Allowance: Integer;
begin
  if not QRHybridBinarize(AImage, Binary) then
    Exit(FailResult('No se pudo binarizar la imagen (contraste insuficiente)'));

  try
    FinderInfo := QRFindFinderPatterns(Binary, AImage.Width, AImage.Height);
  except
    on E: EQRFinderNotFound do
      Exit(FailResult('No se localizaron los 3 patrones buscadores: ' + E.Message));
  end;

  ModuleSize := CalculateModuleSize(Binary, AImage.Width, AImage.Height,
    ToPointF(FinderInfo.TopLeft), ToPointF(FinderInfo.TopRight), ToPointF(FinderInfo.BottomLeft));
  if ModuleSize < 1.0 then
    Exit(FailResult('Tamano de modulo estimado invalido (< 1 pixel)'));

  Dimension := ComputeDimension(ToPointF(FinderInfo.TopLeft), ToPointF(FinderInfo.TopRight),
    ToPointF(FinderInfo.BottomLeft), ModuleSize);
  ProvisionalVersion := (Dimension - 17) div 4;
  if (ProvisionalVersion < QR_MIN_VERSION) or (ProvisionalVersion > QR_MAX_VERSION) then
    Exit(FailResult(Format('Dimension estimada invalida: %d modulos', [Dimension])));

  AlignPositions := QRGetAlignmentPatternPositions(ProvisionalVersion);
  HasAlignment := Length(AlignPositions) > 0;
  FoundAlign := False;
  DimMinusThree := Dimension - 3.5;

  if HasAlignment then
  begin
    ModulesBetweenFPCenters := QRSizeForVersion(ProvisionalVersion) - 7;
    BottomRightX := FinderInfo.TopRight.X - FinderInfo.TopLeft.X + FinderInfo.BottomLeft.X;
    BottomRightY := FinderInfo.TopRight.Y - FinderInfo.TopLeft.Y + FinderInfo.BottomLeft.Y;
    EstAlignX := Trunc(FinderInfo.TopLeft.X + (1.0 - 3.0 / ModulesBetweenFPCenters) * (BottomRightX - FinderInfo.TopLeft.X));
    EstAlignY := Trunc(FinderInfo.TopLeft.Y + (1.0 - 3.0 / ModulesBetweenFPCenters) * (BottomRightY - FinderInfo.TopLeft.Y));

    I := 4;
    while (I <= 16) and (not FoundAlign) do
    begin
      Allowance := Trunc(I * ModuleSize);
      FoundAlign := QRFindAlignmentPattern(Binary, AImage.Width, AImage.Height,
        EstAlignX - Allowance, EstAlignY - Allowance, 2 * Allowance, 2 * Allowance, ModuleSize, AlignPt);
      I := I * 4;
    end;
  end;

  if FoundAlign then
  begin
    BottomRightX := AlignPt.X;
    BottomRightY := AlignPt.Y;
    SourceBRX := DimMinusThree - 3.0;
    SourceBRY := SourceBRX;
  end
  else
  begin
    BottomRightX := FinderInfo.TopRight.X - FinderInfo.TopLeft.X + FinderInfo.BottomLeft.X;
    BottomRightY := FinderInfo.TopRight.Y - FinderInfo.TopLeft.Y + FinderInfo.BottomLeft.Y;
    SourceBRX := DimMinusThree;
    SourceBRY := DimMinusThree;
  end;

  Transform := TQRPerspectiveTransform.QuadrilateralToQuadrilateral(
    3.5, 3.5,
    DimMinusThree, 3.5,
    SourceBRX, SourceBRY,
    3.5, DimMinusThree,
    FinderInfo.TopLeft.X, FinderInfo.TopLeft.Y,
    FinderInfo.TopRight.X, FinderInfo.TopRight.Y,
    BottomRightX, BottomRightY,
    FinderInfo.BottomLeft.X, FinderInfo.BottomLeft.Y);

  Grid := QRSampleGrid(Binary, AImage.Width, AImage.Height, Transform, Dimension);

  DecodeResult := QRDecodeMatrix(Grid, Dimension);

  FillChar(Result, SizeOf(Result), 0);
  Result.Success := DecodeResult.Success;
  Result.ErrorMessage := DecodeResult.ErrorMessage;
  Result.Text := DecodeResult.Text;
  Result.Version := DecodeResult.Version;
  Result.ErrorLevel := DecodeResult.ErrorLevel;
  Result.Mask := DecodeResult.Mask;
  Result.NumErrorsCorrected := DecodeResult.NumErrorsCorrected;
  Result.KanjiSjisBytes := DecodeResult.KanjiSjisBytes;
  Result.EciValues := DecodeResult.EciValues;
  Result.TopLeft := ToPointF(FinderInfo.TopLeft);
  Result.TopRight := ToPointF(FinderInfo.TopRight);
  Result.BottomLeft := ToPointF(FinderInfo.BottomLeft);
  Result.ModuleSize := ModuleSize;
end;

end.
