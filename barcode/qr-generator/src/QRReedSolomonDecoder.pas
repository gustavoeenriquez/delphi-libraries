unit QRReedSolomonDecoder;

{
  QRReedSolomonDecoder.pas -- Correccion de errores Reed-Solomon sobre GF(256)
  (mismo campo que QRReedSolomon.pas: polinomio primitivo 0x11D, generador
  alpha=2, generatorBase=0). Dado un bloque "recibido" (datos+ECC, posiblemente
  con bytes alterados), calcula sindromes, resuelve el polinomio localizador
  de errores y el evaluador de errores con el algoritmo de Euclides, ubica las
  posiciones de error (busqueda de Chien) y corrige las magnitudes (formula
  de Forney).

  Portado de ZXing (Apache License 2.0): GenericGF.java, GenericGFPoly.java,
  ReedSolomonDecoder.java
  https://github.com/zxing/zxing
  Ver README.md de esta libreria para el aviso de atribucion completo.

  License de esta libreria: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils;

type
  EQRRSDecodeError = class(Exception);

// Multiplicacion/inverso en GF(256) via tablas exp/log (mismo campo que
// QRReedSolomonMultiply de QRReedSolomon.pas; verificado por test cruzado).
function QRGF256Multiply(A, B: Integer): Integer;
function QRGF256Inverse(A: Integer): Integer;

// Corrige errores en AReceived (datos+ECC de UN bloque, en el orden en que
// se transmiten: datos primero, ECC al final). ANumEccCodewords es el numero
// de codewords ECC del bloque (== "2t", corrige hasta t bytes errados).
// Devuelve False si el bloque tiene mas errores de los que el codigo puede
// corregir (AReceived queda sin modificar en ese caso).
function QRReedSolomonDecodeBlock(var AReceived: TBytes; ANumEccCodewords: Integer;
  out ANumErrorsCorrected: Integer): Boolean;

implementation

const
  GF_SIZE = 256;
  GF_PRIMITIVE = $11D;

var
  GF_EXP: array[0..255] of Integer;
  GF_LOG: array[0..255] of Integer;

procedure GFInitTables;
var
  X, I: Integer;
begin
  X := 1;
  for I := 0 to 255 do
  begin
    GF_EXP[I] := X;
    X := X * 2;
    if X >= GF_SIZE then
    begin
      X := X xor GF_PRIMITIVE;
      X := X and (GF_SIZE - 1);
    end;
  end;
  for I := 0 to 254 do
    GF_LOG[GF_EXP[I]] := I;
end;

function QRGF256Multiply(A, B: Integer): Integer;
begin
  if (A = 0) or (B = 0) then
    Exit(0);
  Result := GF_EXP[(GF_LOG[A] + GF_LOG[B]) mod 255];
end;

function QRGF256Inverse(A: Integer): Integer;
begin
  if A = 0 then
    raise EQRRSDecodeError.Create('QRGF256Inverse: no existe inverso de 0');
  Result := GF_EXP[255 - GF_LOG[A]];
end;

// ---------------------------------------------------------------------------
// Polinomios sobre GF(256), representados como TArray<Integer> de mayor a
// menor grado (coeficiente[0] = termino de mayor grado), siempre normalizados
// (sin ceros a la izquierda, salvo el polinomio "0" representado como [0]).
// ---------------------------------------------------------------------------

function PolyNormalize(const ACoeffs: TArray<Integer>): TArray<Integer>;
var
  FirstNonZero, I: Integer;
begin
  if (Length(ACoeffs) > 1) and (ACoeffs[0] = 0) then
  begin
    FirstNonZero := 1;
    while (FirstNonZero < Length(ACoeffs)) and (ACoeffs[FirstNonZero] = 0) do
      Inc(FirstNonZero);
    if FirstNonZero = Length(ACoeffs) then
      Exit(TArray<Integer>.Create(0));
    SetLength(Result, Length(ACoeffs) - FirstNonZero);
    for I := 0 to High(Result) do
      Result[I] := ACoeffs[FirstNonZero + I];
    Exit;
  end;
  Result := ACoeffs;
end;

function PolyDegree(const P: TArray<Integer>): Integer; inline;
begin
  Result := Length(P) - 1;
end;

function PolyIsZero(const P: TArray<Integer>): Boolean; inline;
begin
  Result := P[0] = 0;
end;

function PolyCoefficient(const P: TArray<Integer>; ADegree: Integer): Integer; inline;
begin
  Result := P[Length(P) - 1 - ADegree];
end;

function PolyBuildMonomial(ADegree, ACoefficient: Integer): TArray<Integer>;
begin
  if ACoefficient = 0 then
    Exit(TArray<Integer>.Create(0));
  SetLength(Result, ADegree + 1);
  FillChar(Result[0], Length(Result) * SizeOf(Integer), 0);
  Result[0] := ACoefficient;
end;

function PolyEvaluateAt(const P: TArray<Integer>; A: Integer): Integer;
var
  I: Integer;
begin
  if A = 0 then
    Exit(PolyCoefficient(P, 0));
  if A = 1 then
  begin
    Result := 0;
    for I := 0 to High(P) do
      Result := Result xor P[I];
    Exit;
  end;
  Result := P[0];
  for I := 1 to High(P) do
    Result := QRGF256Multiply(A, Result) xor P[I];
end;

function PolyAddOrSubtract(const A, B: TArray<Integer>): TArray<Integer>;
var
  Small, Large: TArray<Integer>;
  LenDiff, I: Integer;
begin
  if PolyIsZero(A) then Exit(B);
  if PolyIsZero(B) then Exit(A);
  if Length(A) > Length(B) then
  begin
    Large := A; Small := B;
  end
  else
  begin
    Large := B; Small := A;
  end;
  SetLength(Result, Length(Large));
  LenDiff := Length(Large) - Length(Small);
  for I := 0 to LenDiff - 1 do
    Result[I] := Large[I];
  for I := LenDiff to High(Large) do
    Result[I] := Small[I - LenDiff] xor Large[I];
  Result := PolyNormalize(Result);
end;

function PolyMultiply(const A, B: TArray<Integer>): TArray<Integer>;
var
  I, J: Integer;
begin
  if PolyIsZero(A) or PolyIsZero(B) then
    Exit(TArray<Integer>.Create(0));
  SetLength(Result, Length(A) + Length(B) - 1);
  FillChar(Result[0], Length(Result) * SizeOf(Integer), 0);
  for I := 0 to High(A) do
    for J := 0 to High(B) do
      Result[I + J] := Result[I + J] xor QRGF256Multiply(A[I], B[J]);
end;

function PolyMultiplyByMonomial(const P: TArray<Integer>; ADegree, ACoefficient: Integer): TArray<Integer>;
var
  I: Integer;
begin
  if ACoefficient = 0 then
    Exit(TArray<Integer>.Create(0));
  SetLength(Result, Length(P) + ADegree);
  FillChar(Result[0], Length(Result) * SizeOf(Integer), 0);
  for I := 0 to High(P) do
    Result[I] := QRGF256Multiply(P[I], ACoefficient);
end;

// Algoritmo de Euclides extendido: dado A (=x^twoS) y B (=sindromes), calcula
// [sigma, omega] tal que sigma es el localizador de errores y omega el
// evaluador, deteniendose cuando deg(r) < twoS/2.
function RunEuclideanAlgorithm(A, B: TArray<Integer>; R: Integer; out ASigma, AOmega: TArray<Integer>): Boolean;
var
  RLast, RCur, RLastLast: TArray<Integer>;
  TLast, TCur, TLastLast: TArray<Integer>;
  Q, Term: TArray<Integer>;
  DenomInv, Scale, DegreeDiff: Integer;
  SigmaTildeAtZero, Inv: Integer;
begin
  if PolyDegree(A) < PolyDegree(B) then
  begin
    Term := A; A := B; B := Term;
  end;

  RLast := A;
  RCur := B;
  TLast := TArray<Integer>.Create(0);
  TCur := TArray<Integer>.Create(1);

  while 2 * PolyDegree(RCur) >= R do
  begin
    RLastLast := RLast;
    TLastLast := TLast;
    RLast := RCur;
    TLast := TCur;

    if PolyIsZero(RLast) then
    begin
      ASigma := nil; AOmega := nil;
      Exit(False); // r_{i-1} era cero: algoritmo ya termino, entrada invalida
    end;

    RCur := RLastLast;
    Q := TArray<Integer>.Create(0);
    DenomInv := QRGF256Inverse(PolyCoefficient(RLast, PolyDegree(RLast)));
    while (PolyDegree(RCur) >= PolyDegree(RLast)) and (not PolyIsZero(RCur)) do
    begin
      DegreeDiff := PolyDegree(RCur) - PolyDegree(RLast);
      Scale := QRGF256Multiply(PolyCoefficient(RCur, PolyDegree(RCur)), DenomInv);
      Q := PolyAddOrSubtract(Q, PolyBuildMonomial(DegreeDiff, Scale));
      RCur := PolyAddOrSubtract(RCur, PolyMultiplyByMonomial(RLast, DegreeDiff, Scale));
    end;

    TCur := PolyAddOrSubtract(PolyMultiply(Q, TLast), TLastLast);

    if PolyDegree(RCur) >= PolyDegree(RLast) then
    begin
      ASigma := nil; AOmega := nil;
      Exit(False); // la division no redujo el grado: entrada corrupta
    end;
  end;

  SigmaTildeAtZero := PolyCoefficient(TCur, 0);
  if SigmaTildeAtZero = 0 then
  begin
    ASigma := nil; AOmega := nil;
    Exit(False);
  end;

  Inv := QRGF256Inverse(SigmaTildeAtZero);
  ASigma := PolyMultiplyByMonomial(TCur, 0, Inv); // TCur * inv (grado 0 => solo escala)
  AOmega := PolyMultiplyByMonomial(RCur, 0, Inv);
  Result := True;
end;

function FindErrorLocations(const AErrorLocator: TArray<Integer>; out ALocations: TArray<Integer>): Boolean;
var
  NumErrors, E, I: Integer;
begin
  NumErrors := PolyDegree(AErrorLocator);
  if NumErrors = 1 then
  begin
    ALocations := TArray<Integer>.Create(PolyCoefficient(AErrorLocator, 1));
    Exit(True);
  end;
  SetLength(ALocations, NumErrors);
  E := 0;
  I := 1;
  while (I < GF_SIZE) and (E < NumErrors) do
  begin
    if PolyEvaluateAt(AErrorLocator, I) = 0 then
    begin
      ALocations[E] := QRGF256Inverse(I);
      Inc(E);
    end;
    Inc(I);
  end;
  Result := E = NumErrors;
  if not Result then
    ALocations := nil;
end;

function FindErrorMagnitudes(const AErrorEvaluator: TArray<Integer>; const ALocations: TArray<Integer>): TArray<Integer>;
var
  S, I, J: Integer;
  XiInverse, Denominator, Term, TermPlus1: Integer;
begin
  S := Length(ALocations);
  SetLength(Result, S);
  for I := 0 to S - 1 do
  begin
    XiInverse := QRGF256Inverse(ALocations[I]);
    Denominator := 1;
    for J := 0 to S - 1 do
      if I <> J then
      begin
        Term := QRGF256Multiply(ALocations[J], XiInverse);
        if (Term and 1) = 0 then
          TermPlus1 := Term or 1
        else
          TermPlus1 := Term and not 1;
        Denominator := QRGF256Multiply(Denominator, TermPlus1);
      end;
    Result[I] := QRGF256Multiply(PolyEvaluateAt(AErrorEvaluator, XiInverse), QRGF256Inverse(Denominator));
    // generatorBase = 0 para QR: no se aplica el factor xiInverse adicional
  end;
end;

function QRReedSolomonDecodeBlock(var AReceived: TBytes; ANumEccCodewords: Integer;
  out ANumErrorsCorrected: Integer): Boolean;
var
  Poly: TArray<Integer>;
  Syndrome: TArray<Integer>;
  NoError: Boolean;
  I, Eval, Position: Integer;
  Sigma, Omega: TArray<Integer>;
  ErrorLocations, ErrorMagnitudes: TArray<Integer>;
begin
  ANumErrorsCorrected := 0;
  SetLength(Poly, Length(AReceived));
  for I := 0 to High(AReceived) do
    Poly[I] := AReceived[I];
  Poly := PolyNormalize(Poly);

  SetLength(Syndrome, ANumEccCodewords);
  NoError := True;
  for I := 0 to ANumEccCodewords - 1 do
  begin
    Eval := PolyEvaluateAt(Poly, GF_EXP[I]); // generatorBase = 0
    Syndrome[ANumEccCodewords - 1 - I] := Eval;
    if Eval <> 0 then
      NoError := False;
  end;
  if NoError then
    Exit(True);

  if not RunEuclideanAlgorithm(PolyBuildMonomial(ANumEccCodewords, 1), Syndrome, ANumEccCodewords, Sigma, Omega) then
    Exit(False);

  if not FindErrorLocations(Sigma, ErrorLocations) then
    Exit(False);
  ErrorMagnitudes := FindErrorMagnitudes(Omega, ErrorLocations);

  for I := 0 to High(ErrorLocations) do
  begin
    Position := Length(AReceived) - 1 - GF_LOG[ErrorLocations[I]];
    if Position < 0 then
      Exit(False);
    AReceived[Position] := Byte(AReceived[Position] xor ErrorMagnitudes[I]);
  end;

  ANumErrorsCorrected := Length(ErrorLocations);
  Result := True;
end;

initialization
  GFInitTables;

end.
