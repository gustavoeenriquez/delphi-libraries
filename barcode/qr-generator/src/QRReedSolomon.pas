unit QRReedSolomon;

{
  QRReedSolomon.pas -- Aritmetica GF(256) y codigo Reed-Solomon para QR Code
  (ISO/IEC 18004 Annex A). Campo GF(2^8) con polinomio primitivo 0x11D,
  generador r = 0x02.

  Portado del algoritmo de "QR Code generator library" de Project Nayuki
  (MIT License): https://www.nayuki.io/page/qr-code-generator-library
  Los vectores de prueba (QRGeneratorTests.dpr) provienen del mismo proyecto
  (qrcodegen-test.c), lo que permite verificar esta traduccion bit a bit.

  License de esta libreria: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils;

// Producto de dos elementos de GF(256) modulo 0x11D.
function QRReedSolomonMultiply(X, Y: Byte): Byte;

// Genera el polinomio generador de grado ADegree: (x - r^0)(x - r^1)...(x - r^{degree-1}),
// almacenado de mayor a menor potencia (se omite el termino lider, siempre 1).
function QRReedSolomonComputeDivisor(ADegree: Integer): TBytes;

// Calcula el resto de la division de ATheData(x) * x^deg(divisor) entre ADivisor(x),
// es decir, los codewords de correccion de errores para un bloque de datos.
function QRReedSolomonComputeRemainder(const AData, ADivisor: TBytes): TBytes;

implementation

function QRReedSolomonMultiply(X, Y: Byte): Byte;
var
  Z: Integer;
  I: Integer;
begin
  Z := 0;
  for I := 7 downto 0 do
  begin
    Z := (Z shl 1) xor ((Z shr 7) * $11D);
    Z := Z xor (((Y shr I) and 1) * X);
  end;
  Result := Byte(Z);
end;

function QRReedSolomonComputeDivisor(ADegree: Integer): TBytes;
var
  Root: Byte;
  I, J: Integer;
begin
  if (ADegree < 1) or (ADegree > 255) then
    raise Exception.Create('QRReedSolomonComputeDivisor: grado fuera de rango');
  SetLength(Result, ADegree);
  FillChar(Result[0], ADegree, 0);
  Result[ADegree - 1] := 1; // monomio x^0

  Root := 1;
  for I := 0 to ADegree - 1 do
  begin
    for J := 0 to ADegree - 1 do
    begin
      Result[J] := QRReedSolomonMultiply(Result[J], Root);
      if J + 1 < ADegree then
        Result[J] := Result[J] xor Result[J + 1];
    end;
    Root := QRReedSolomonMultiply(Root, 2);
  end;
end;

function QRReedSolomonComputeRemainder(const AData, ADivisor: TBytes): TBytes;
var
  N, I, K: Integer;
  Factor: Byte;
begin
  N := Length(ADivisor);
  SetLength(Result, N);
  if N = 0 then
    Exit;
  FillChar(Result[0], N, 0);
  for K := 0 to Length(AData) - 1 do
  begin
    Factor := AData[K] xor Result[0];
    for I := 0 to N - 2 do
      Result[I] := Result[I + 1];
    Result[N - 1] := 0;
    for I := 0 to N - 1 do
      Result[I] := Result[I] xor QRReedSolomonMultiply(ADivisor[I], Factor);
  end;
end;

end.
