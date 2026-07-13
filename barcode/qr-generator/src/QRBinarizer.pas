unit QRBinarizer;

{
  QRBinarizer.pas -- Binarizacion (escala de grises -> blanco/negro) tolerante
  a iluminacion despareja, sombras y gradientes tipicos de fotos tomadas con
  camara. Implementa un umbral LOCAL por bloques de 8x8 pixeles, promediado
  sobre una vecindad de 5x5 bloques (HybridBinarizer), con una estimacion de
  punto negro por histograma bimodal como respaldo para imagenes pequenas.

  Portado de ZXing (Apache License 2.0): HybridBinarizer.java,
  GlobalHistogramBinarizer.java
  https://github.com/zxing/zxing
  Ver README.md de esta libreria para el aviso de atribucion completo.

  License de esta libreria: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Math, QRTypes, QRGrayImage;

// Umbral global por histograma (32 buckets, dos picos + valle entre ellos).
// Devuelve False si el contraste es demasiado bajo para decidir con confianza.
function QREstimateBlackPoint(const AHistogram: array of Integer; out AThreshold: Integer): Boolean;

// Binarizacion global (umbral unico para toda la imagen). Rapida, pero
// vulnerable a sombras/gradientes. Se usa como respaldo para imagenes chicas.
function QRGlobalBinarize(const AImage: TQRGrayImage; out AGrid: TQRModuleGrid): Boolean;

// Binarizacion local por bloques (HybridBinarizer). Recomendada para fotos.
// Cae a QRGlobalBinarize si la imagen es menor que el bloque minimo (40x40)
// o si el histograma global tampoco tiene contraste suficiente.
function QRHybridBinarize(const AImage: TQRGrayImage; out AGrid: TQRModuleGrid): Boolean;

implementation

const
  BLOCK_SIZE = 8;
  MINIMUM_DIMENSION = BLOCK_SIZE * 5; // 40
  MIN_DYNAMIC_RANGE = 24;
  LUMINANCE_BUCKETS = 32;
  LUMINANCE_SHIFT = 3; // 8 - log2(32)

function QREstimateBlackPoint(const AHistogram: array of Integer; out AThreshold: Integer): Boolean;
var
  NumBuckets, X: Integer;
  MaxBucketCount, FirstPeak, FirstPeakSize: Integer;
  SecondPeak, SecondPeakScore, DistanceToBiggest, Score: Integer;
  Temp, BestValley, BestValleyScore, FromFirst: Integer;
begin
  NumBuckets := Length(AHistogram);
  MaxBucketCount := 0;
  FirstPeak := 0;
  FirstPeakSize := 0;
  for X := 0 to NumBuckets - 1 do
  begin
    if AHistogram[X] > FirstPeakSize then
    begin
      FirstPeak := X;
      FirstPeakSize := AHistogram[X];
    end;
    if AHistogram[X] > MaxBucketCount then
      MaxBucketCount := AHistogram[X];
  end;

  SecondPeak := 0;
  SecondPeakScore := 0;
  for X := 0 to NumBuckets - 1 do
  begin
    DistanceToBiggest := X - FirstPeak;
    Score := AHistogram[X] * DistanceToBiggest * DistanceToBiggest;
    if Score > SecondPeakScore then
    begin
      SecondPeak := X;
      SecondPeakScore := Score;
    end;
  end;

  if FirstPeak > SecondPeak then
  begin
    Temp := FirstPeak;
    FirstPeak := SecondPeak;
    SecondPeak := Temp;
  end;

  if SecondPeak - FirstPeak <= NumBuckets div 16 then
  begin
    AThreshold := 128;
    Exit(False); // contraste insuficiente
  end;

  BestValley := SecondPeak - 1;
  BestValleyScore := -1;
  for X := SecondPeak - 1 downto FirstPeak + 1 do
  begin
    FromFirst := X - FirstPeak;
    Score := FromFirst * FromFirst * (SecondPeak - X) * (MaxBucketCount - AHistogram[X]);
    if Score > BestValleyScore then
    begin
      BestValley := X;
      BestValleyScore := Score;
    end;
  end;

  AThreshold := BestValley shl LUMINANCE_SHIFT;
  Result := True;
end;

function QRGlobalBinarize(const AImage: TQRGrayImage; out AGrid: TQRModuleGrid): Boolean;
var
  Histogram: array[0..LUMINANCE_BUCKETS - 1] of Integer;
  X, Y, Threshold: Integer;
begin
  FillChar(Histogram, SizeOf(Histogram), 0);
  for Y := 0 to AImage.Height - 1 do
    for X := 0 to AImage.Width - 1 do
      Inc(Histogram[AImage.GetPixel(X, Y) shr LUMINANCE_SHIFT]);

  if not QREstimateBlackPoint(Histogram, Threshold) then
  begin
    AGrid := nil;
    Exit(False);
  end;

  SetLength(AGrid, AImage.Height, AImage.Width);
  for Y := 0 to AImage.Height - 1 do
    for X := 0 to AImage.Width - 1 do
      AGrid[Y, X] := AImage.GetPixel(X, Y) < Threshold;
  Result := True;
end;

function Cap(AValue, AMax: Integer): Integer; inline;
begin
  if AValue < 2 then Result := 2
  else Result := Min(AValue, AMax);
end;

// Calcula un punto negro por bloque de BLOCK_SIZE x BLOCK_SIZE pixeles.
procedure CalculateBlackPoints(const AImage: TQRGrayImage; ASubWidth, ASubHeight: Integer;
  out ABlackPoints: TArray<TArray<Integer>>);
var
  MaxYOffset, MaxXOffset: Integer;
  X, Y, XOffset, YOffset, XX, YY, Pixel: Integer;
  Sum, MinV, MaxV, Average, AverageNeighbor: Integer;
begin
  MaxYOffset := AImage.Height - BLOCK_SIZE;
  MaxXOffset := AImage.Width - BLOCK_SIZE;
  SetLength(ABlackPoints, ASubHeight, ASubWidth);

  for Y := 0 to ASubHeight - 1 do
  begin
    YOffset := Y * BLOCK_SIZE;
    if YOffset > MaxYOffset then YOffset := MaxYOffset;
    for X := 0 to ASubWidth - 1 do
    begin
      XOffset := X * BLOCK_SIZE;
      if XOffset > MaxXOffset then XOffset := MaxXOffset;

      Sum := 0; MinV := 255; MaxV := 0;
      for YY := 0 to BLOCK_SIZE - 1 do
        for XX := 0 to BLOCK_SIZE - 1 do
        begin
          Pixel := AImage.GetPixel(XOffset + XX, YOffset + YY);
          Inc(Sum, Pixel);
          if Pixel < MinV then MinV := Pixel;
          if Pixel > MaxV then MaxV := Pixel;
        end;

      Average := Sum div (BLOCK_SIZE * BLOCK_SIZE);
      if MaxV - MinV <= MIN_DYNAMIC_RANGE then
      begin
        // Bloque de bajo contraste: asume fondo claro, usa la mitad del minimo.
        Average := MinV div 2;
        if (Y > 0) and (X > 0) then
        begin
          AverageNeighbor := (ABlackPoints[Y - 1, X] + 2 * ABlackPoints[Y, X - 1] + ABlackPoints[Y - 1, X - 1]) div 4;
          if MinV < AverageNeighbor then
            Average := AverageNeighbor;
        end;
      end;
      ABlackPoints[Y, X] := Average;
    end;
  end;
end;

function QRHybridBinarize(const AImage: TQRGrayImage; out AGrid: TQRModuleGrid): Boolean;
var
  SubWidth, SubHeight: Integer;
  BlackPoints: TArray<TArray<Integer>>;
  MaxYOffset, MaxXOffset: Integer;
  X, Y, XOffset, YOffset, Top, Left, Z, Sum, Average: Integer;
  BX, BY: Integer;
begin
  if (AImage.Width < MINIMUM_DIMENSION) or (AImage.Height < MINIMUM_DIMENSION) then
    Exit(QRGlobalBinarize(AImage, AGrid));

  SubWidth := AImage.Width div BLOCK_SIZE;
  if AImage.Width mod BLOCK_SIZE <> 0 then Inc(SubWidth);
  SubHeight := AImage.Height div BLOCK_SIZE;
  if AImage.Height mod BLOCK_SIZE <> 0 then Inc(SubHeight);

  CalculateBlackPoints(AImage, SubWidth, SubHeight, BlackPoints);

  SetLength(AGrid, AImage.Height, AImage.Width);
  MaxYOffset := AImage.Height - BLOCK_SIZE;
  MaxXOffset := AImage.Width - BLOCK_SIZE;

  for Y := 0 to SubHeight - 1 do
  begin
    YOffset := Y * BLOCK_SIZE;
    if YOffset > MaxYOffset then YOffset := MaxYOffset;
    Top := Cap(Y, SubHeight - 3);
    for X := 0 to SubWidth - 1 do
    begin
      XOffset := X * BLOCK_SIZE;
      if XOffset > MaxXOffset then XOffset := MaxXOffset;
      Left := Cap(X, SubWidth - 3);

      Sum := 0;
      for Z := -2 to 2 do
        Inc(Sum, BlackPoints[Top + Z, Left - 2] + BlackPoints[Top + Z, Left - 1] + BlackPoints[Top + Z, Left]
          + BlackPoints[Top + Z, Left + 1] + BlackPoints[Top + Z, Left + 2]);
      Average := Sum div 25;

      for BY := 0 to BLOCK_SIZE - 1 do
        for BX := 0 to BLOCK_SIZE - 1 do
          // "<=" para que los pixeles 0 (negro puro) sean negros aun con umbral 0
          AGrid[YOffset + BY, XOffset + BX] := AImage.GetPixel(XOffset + BX, YOffset + BY) <= Average;
    end;
  end;
  Result := True;
end;

end.
