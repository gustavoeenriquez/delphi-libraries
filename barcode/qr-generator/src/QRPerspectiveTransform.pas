unit QRPerspectiveTransform;

{
  QRPerspectiveTransform.pas -- Transformacion de perspectiva 2D (homografia)
  entre dos cuadrilateros, y muestreo de una grilla de modulos a partir de
  una imagen binarizada usando esa transformacion. Basado en la seccion 3.4.2
  de "Digital Image Warping" (George Wolberg).

  Portado de ZXing (Apache License 2.0): PerspectiveTransform.java,
  GridSampler.java, DefaultGridSampler.java
  https://github.com/zxing/zxing
  Ver README.md de esta libreria para el aviso de atribucion completo.

  License de esta libreria: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, QRTypes;

type
  EQRTransformError = class(Exception);

  TQRPerspectiveTransform = record
    A11, A12, A13, A21, A22, A23, A31, A32, A33: Single;

    // Transforma (AX,AY) en el espacio "cuadrado unitario de origen" al
    // espacio destino de esta transformacion.
    function Transform(AX, AY: Single): TQRPointF;

    class function SquareToQuadrilateral(X0, Y0, X1, Y1, X2, Y2, X3, Y3: Single): TQRPerspectiveTransform; static;
    class function QuadrilateralToSquare(X0, Y0, X1, Y1, X2, Y2, X3, Y3: Single): TQRPerspectiveTransform; static;
    class function QuadrilateralToQuadrilateral(
      X0, Y0, X1, Y1, X2, Y2, X3, Y3: Single;
      X0P, Y0P, X1P, Y1P, X2P, Y2P, X3P, Y3P: Single): TQRPerspectiveTransform; static;

    function BuildAdjoint: TQRPerspectiveTransform;
    function Times(const AOther: TQRPerspectiveTransform): TQRPerspectiveTransform;
  end;

// Muestrea una grilla ADimension x ADimension desde AImage (espacio pixel)
// usando ATransform (que mapea coordenadas de modulo [0.5, dimension-0.5] a
// coordenadas de pixel). Corrige (nudge) puntos que caen justo 1px afuera.
function QRSampleGrid(const AImage: TQRModuleGrid; AImgWidth, AImgHeight: Integer;
  const ATransform: TQRPerspectiveTransform; ADimension: Integer): TQRModuleGrid;

implementation

{ TQRPerspectiveTransform }

function TQRPerspectiveTransform.Transform(AX, AY: Single): TQRPointF;
var
  Denominator: Single;
begin
  Denominator := A13 * AX + A23 * AY + A33;
  Result.X := (A11 * AX + A21 * AY + A31) / Denominator;
  Result.Y := (A12 * AX + A22 * AY + A32) / Denominator;
end;

class function TQRPerspectiveTransform.SquareToQuadrilateral(X0, Y0, X1, Y1, X2, Y2, X3, Y3: Single): TQRPerspectiveTransform;
var
  DX3, DY3, DX1, DX2, DY1, DY2, Denominator, A13, A23: Single;
begin
  DX3 := X0 - X1 + X2 - X3;
  DY3 := Y0 - Y1 + Y2 - Y3;
  if (DX3 = 0.0) and (DY3 = 0.0) then
  begin
    Result.A11 := X1 - X0; Result.A21 := X2 - X1; Result.A31 := X0;
    Result.A12 := Y1 - Y0; Result.A22 := Y2 - Y1; Result.A32 := Y0;
    Result.A13 := 0.0;     Result.A23 := 0.0;     Result.A33 := 1.0;
  end
  else
  begin
    DX1 := X1 - X2;
    DX2 := X3 - X2;
    DY1 := Y1 - Y2;
    DY2 := Y3 - Y2;
    Denominator := DX1 * DY2 - DX2 * DY1;
    A13 := (DX3 * DY2 - DX2 * DY3) / Denominator;
    A23 := (DX1 * DY3 - DX3 * DY1) / Denominator;
    Result.A11 := X1 - X0 + A13 * X1; Result.A21 := X3 - X0 + A23 * X3; Result.A31 := X0;
    Result.A12 := Y1 - Y0 + A13 * Y1; Result.A22 := Y3 - Y0 + A23 * Y3; Result.A32 := Y0;
    Result.A13 := A13; Result.A23 := A23; Result.A33 := 1.0;
  end;
end;

function TQRPerspectiveTransform.BuildAdjoint: TQRPerspectiveTransform;
begin
  Result.A11 := A22 * A33 - A23 * A32;
  Result.A21 := A23 * A31 - A21 * A33;
  Result.A31 := A21 * A32 - A22 * A31;
  Result.A12 := A13 * A32 - A12 * A33;
  Result.A22 := A11 * A33 - A13 * A31;
  Result.A32 := A12 * A31 - A11 * A32;
  Result.A13 := A12 * A23 - A13 * A22;
  Result.A23 := A13 * A21 - A11 * A23;
  Result.A33 := A11 * A22 - A12 * A21;
end;

class function TQRPerspectiveTransform.QuadrilateralToSquare(X0, Y0, X1, Y1, X2, Y2, X3, Y3: Single): TQRPerspectiveTransform;
begin
  Result := SquareToQuadrilateral(X0, Y0, X1, Y1, X2, Y2, X3, Y3).BuildAdjoint;
end;

function TQRPerspectiveTransform.Times(const AOther: TQRPerspectiveTransform): TQRPerspectiveTransform;
begin
  Result.A11 := A11 * AOther.A11 + A21 * AOther.A12 + A31 * AOther.A13;
  Result.A21 := A11 * AOther.A21 + A21 * AOther.A22 + A31 * AOther.A23;
  Result.A31 := A11 * AOther.A31 + A21 * AOther.A32 + A31 * AOther.A33;
  Result.A12 := A12 * AOther.A11 + A22 * AOther.A12 + A32 * AOther.A13;
  Result.A22 := A12 * AOther.A21 + A22 * AOther.A22 + A32 * AOther.A23;
  Result.A32 := A12 * AOther.A31 + A22 * AOther.A32 + A32 * AOther.A33;
  Result.A13 := A13 * AOther.A11 + A23 * AOther.A12 + A33 * AOther.A13;
  Result.A23 := A13 * AOther.A21 + A23 * AOther.A22 + A33 * AOther.A23;
  Result.A33 := A13 * AOther.A31 + A23 * AOther.A32 + A33 * AOther.A33;
end;

class function TQRPerspectiveTransform.QuadrilateralToQuadrilateral(
  X0, Y0, X1, Y1, X2, Y2, X3, Y3: Single;
  X0P, Y0P, X1P, Y1P, X2P, Y2P, X3P, Y3P: Single): TQRPerspectiveTransform;
var
  QToS, SToQ: TQRPerspectiveTransform;
begin
  QToS := QuadrilateralToSquare(X0, Y0, X1, Y1, X2, Y2, X3, Y3);
  SToQ := SquareToQuadrilateral(X0P, Y0P, X1P, Y1P, X2P, Y2P, X3P, Y3P);
  Result := SToQ.Times(QToS);
end;

// ---------------------------------------------------------------------------

function QRSampleGrid(const AImage: TQRModuleGrid; AImgWidth, AImgHeight: Integer;
  const ATransform: TQRPerspectiveTransform; ADimension: Integer): TQRModuleGrid;
var
  X, Y: Integer;
  PX, PY: Single;
  Pt: TQRPointF;
begin
  if ADimension <= 0 then
    raise EQRTransformError.Create('QRSampleGrid: dimension invalida');

  SetLength(Result, ADimension, ADimension);
  for Y := 0 to ADimension - 1 do
  begin
    PY := Y + 0.5;
    for X := 0 to ADimension - 1 do
    begin
      PX := X + 0.5;
      Pt := ATransform.Transform(PX, PY);

      // "Nudge" de 1px si cae justo en el borde (redondeo de la transformacion)
      if Pt.X < -1 then Continue; // fuera de rango: se deja el modulo en False
      if Pt.X >= AImgWidth + 1 then Continue;
      if Pt.Y < -1 then Continue;
      if Pt.Y >= AImgHeight + 1 then Continue;
      if Pt.X < 0 then Pt.X := 0;
      if Pt.X >= AImgWidth then Pt.X := AImgWidth - 1;
      if Pt.Y < 0 then Pt.Y := 0;
      if Pt.Y >= AImgHeight then Pt.Y := AImgHeight - 1;

      Result[Y, X] := AImage[Trunc(Pt.Y), Trunc(Pt.X)];
    end;
  end;
end;

end.
