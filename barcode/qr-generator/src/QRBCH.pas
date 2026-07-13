unit QRBCH;

{
  QRBCH.pas -- Codificacion y decodificacion BCH de "format info" (15 bits,
  ISO/IEC 18004 Annex C) y "version info" (18 bits, Annex D).

  Format info: 5 bits de datos (2 de nivel ECC + 3 de mascara) protegidos por
  un codigo BCH(15,5) que corrige hasta 3 bits errados, mas XOR con la
  mascara fija 0x5412 (para que el patron nunca sea todo-ceros).

  Version info: 6 bits de version (7-40) protegidos por un codigo BCH(18,6)
  que corrige hasta 3 bits errados. Solo se usa desde la version 7.

  La decodificacion usa distancia de Hamming minima contra las 32 (formato)
  o 34 (version) palabras validas -- exhaustivo y exacto, sin necesidad de
  un decodificador BCH sindromico. Este enfoque replica el usado por
  ZXing (Apache 2.0) en FormatInformation.java / Version.java.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, QRTypes;

// Codifica: 15 bits listos para colocar en el simbolo (ya incluye el XOR con 0x5412).
function QRComputeFormatBits(AEcl: TQRErrorLevel; AMask: Integer): Integer;

// Codifica: 18 bits listos para colocar (solo tiene sentido para AVersion >= 7).
function QRComputeVersionBits(AVersion: Integer): Integer;

// Decodifica 15 bits leidos del simbolo (posiblemente con hasta 3 bits errados).
// Devuelve False si la distancia de Hamming al mejor candidato supera 3 (dato ilegible).
function QRDecodeFormatBits(ABits: Integer; out AEcl: TQRErrorLevel; out AMask: Integer): Boolean;

// Decodifica 18 bits de version info. Devuelve False si no hay candidato a distancia <= 3.
function QRDecodeVersionBits(ABits: Integer; out AVersion: Integer): Boolean;

// Distancia de Hamming entre dos enteros interpretados como bitstrings de ANumBits.
function QRHammingDistance(A, B: Integer; ANumBits: Integer): Integer;

implementation

function QRHammingDistance(A, B: Integer; ANumBits: Integer): Integer;
var
  X: Integer;
  I: Integer;
begin
  X := A xor B;
  Result := 0;
  for I := 0 to ANumBits - 1 do
    if ((X shr I) and 1) <> 0 then
      Inc(Result);
end;

function QRComputeFormatBits(AEcl: TQRErrorLevel; AMask: Integer): Integer;
var
  Data, Rem, I: Integer;
begin
  Data := (QR_FORMAT_BITS[AEcl] shl 3) or AMask;
  Rem := Data;
  for I := 1 to 10 do
    Rem := (Rem shl 1) xor ((Rem shr 9) * $537);
  Result := (Data shl 10 or Rem) xor $5412;
end;

function QRComputeVersionBits(AVersion: Integer): Integer;
var
  Rem, I: Integer;
begin
  Rem := AVersion;
  for I := 1 to 12 do
    Rem := (Rem shl 1) xor ((Rem shr 11) * $1F25);
  Result := (AVersion shl 12) or Rem;
end;

function QRDecodeFormatBits(ABits: Integer; out AEcl: TQRErrorLevel; out AMask: Integer): Boolean;
var
  Ecl: TQRErrorLevel;
  Mask, Candidate, Dist, BestDist: Integer;
  BestEcl: TQRErrorLevel;
  BestMask: Integer;
begin
  BestDist := 16; // > maximo posible (15), asegura que el primer candidato lo reemplace
  BestEcl := qeMedium;
  BestMask := 0;
  for Ecl := Low(TQRErrorLevel) to High(TQRErrorLevel) do
    for Mask := 0 to 7 do
    begin
      Candidate := QRComputeFormatBits(Ecl, Mask);
      Dist := QRHammingDistance(ABits, Candidate, 15);
      if Dist < BestDist then
      begin
        BestDist := Dist;
        BestEcl := Ecl;
        BestMask := Mask;
      end;
    end;
  Result := BestDist <= 3;
  AEcl := BestEcl;
  AMask := BestMask;
end;

function QRDecodeVersionBits(ABits: Integer; out AVersion: Integer): Boolean;
var
  V, Candidate, Dist, BestDist, BestVersion: Integer;
begin
  BestDist := 19; // > maximo posible (18)
  BestVersion := 7;
  for V := 7 to 40 do
  begin
    Candidate := QRComputeVersionBits(V);
    Dist := QRHammingDistance(ABits, Candidate, 18);
    if Dist < BestDist then
    begin
      BestDist := Dist;
      BestVersion := V;
    end;
  end;
  Result := BestDist <= 3;
  AVersion := BestVersion;
end;

end.
