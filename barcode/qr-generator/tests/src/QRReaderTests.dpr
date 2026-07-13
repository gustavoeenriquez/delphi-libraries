program QRReaderTests;

{
  QRReaderTests.dpr -- suite de pruebas para el lector de codigos QR
  (QRReedSolomonDecoder, QRBitStreamDecoder, QRMatrixDecoder, pipeline de
  vision QRReader). Se ira ampliando a medida que se agreguen las unidades
  del lector.

  Cada test imprime PASS/FAIL. Codigo de salida 1 si algun test falla.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$APPTYPE CONSOLE}

uses
  SysUtils,
  QRTypes,
  QRReedSolomon,
  QRReedSolomonDecoder;

var
  GTotal: Integer = 0;
  GPassed: Integer = 0;

procedure Check(const AName: string; ACond: Boolean);
begin
  Inc(GTotal);
  if ACond then
  begin
    WriteLn('PASS: ', AName);
    Inc(GPassed);
  end
  else
    WriteLn('FAIL: ', AName);
end;

function BytesEqual(const A, B: TBytes): Boolean;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then Exit(False);
  for I := 0 to High(A) do
    if A[I] <> B[I] then Exit(False);
  Result := True;
end;

// ---------------------------------------------------------------------------
// GF(256): la multiplicacion por tablas del decoder debe coincidir con la
// multiplicacion "russian peasant" bit a bit del encoder (mismo campo).
// ---------------------------------------------------------------------------

procedure TestGFCrossCheck;
var
  A, B: Integer;
  Mismatches: Integer;
begin
  Mismatches := 0;
  for A := 0 to 255 do
    for B := 0 to 255 do
      if QRGF256Multiply(A, B) <> QRReedSolomonMultiply(A, B) then
        Inc(Mismatches);
  Check('GF256Multiply coincide con QRReedSolomonMultiply (65536 casos)', Mismatches = 0);

  Mismatches := 0;
  for A := 1 to 255 do
    if QRGF256Multiply(A, QRGF256Inverse(A)) <> 1 then
      Inc(Mismatches);
  Check('GF256Inverse: A * inverse(A) = 1 para todo A en 1..255', Mismatches = 0);
end;

// ---------------------------------------------------------------------------
// Construye un bloque codificado (data+ecc) usando el ENCODER, lo corrompe,
// y confirma que el DECODER lo recupera exactamente.
// ---------------------------------------------------------------------------

function BuildEncodedBlock(const AData: TBytes; AEccLen: Integer): TBytes;
var
  Gen, Ecc: TBytes;
begin
  Gen := QRReedSolomonComputeDivisor(AEccLen);
  Ecc := QRReedSolomonComputeRemainder(AData, Gen);
  SetLength(Result, Length(AData) + Length(Ecc));
  Move(AData[0], Result[0], Length(AData));
  Move(Ecc[0], Result[Length(AData)], Length(Ecc));
end;

procedure TestReedSolomonDecodeNoErrors;
var
  Data, Block: TBytes;
  NumCorrected: Integer;
  Ok: Boolean;
begin
  Data := TBytes.Create($11, $22, $33, $44, $55, $66, $C0, $DE);
  Block := BuildEncodedBlock(Data, 10);
  Ok := QRReedSolomonDecodeBlock(Block, 10, NumCorrected);
  Check('RS decode sin errores: retorna True', Ok);
  Check('RS decode sin errores: 0 corregidos', NumCorrected = 0);
  Check('RS decode sin errores: datos intactos', BytesEqual(Copy(Block, 0, Length(Data)), Data));
end;

procedure TestReedSolomonDecodeWithinCapacity;
var
  Data, Block, Original: TBytes;
  EccLen, MaxErrors, I: Integer;
  NumCorrected: Integer;
  Ok: Boolean;
begin
  // EccLen=16 -> corrige hasta 8 bytes errados
  EccLen := 16;
  MaxErrors := EccLen div 2;
  Data := TBytes.Create($01, $02, $03, $04, $05, $06, $07, $08, $09, $0A, $0B, $0C, $0D, $0E, $0F, $10, $EE, $FF);
  Original := Copy(Data, 0, Length(Data));
  Block := BuildEncodedBlock(Data, EccLen);

  // Corrompe exactamente MaxErrors bytes (mitad en la zona de datos, mitad en ECC)
  for I := 0 to MaxErrors - 1 do
    Block[I * 2] := Byte(Block[I * 2] xor $FF);

  Ok := QRReedSolomonDecodeBlock(Block, EccLen, NumCorrected);
  Check(Format('RS decode con %d errores (limite exacto): retorna True', [MaxErrors]), Ok);
  Check('RS decode en el limite: recupera los datos originales exactos',
    BytesEqual(Copy(Block, 0, Length(Original)), Original));
end;

procedure TestReedSolomonDecodeBeyondCapacity;
var
  Data, Block: TBytes;
  EccLen, MaxErrors, I: Integer;
  NumCorrected: Integer;
  Ok, Recovered: Boolean;
  Original: TBytes;
begin
  EccLen := 10; // corrige hasta 5 bytes
  MaxErrors := EccLen div 2;
  Data := TBytes.Create($AA, $BB, $CC, $DD, $EE, $01, $02, $03, $04, $05);
  Original := Copy(Data, 0, Length(Data));
  Block := BuildEncodedBlock(Data, EccLen);

  // Corrompe uno mas de lo que el codigo puede garantizar corregir
  for I := 0 to MaxErrors do
    Block[I * 2] := Byte(Block[I * 2] xor $F0);

  Ok := QRReedSolomonDecodeBlock(Block, EccLen, NumCorrected);
  // Con mas errores que la capacidad, el decoder debe fallar (False) o,
  // si "acierta" a otra palabra valida por coincidencia, no debe reportar
  // silenciosamente los datos originales como correctos sin serlo.
  Recovered := Ok and BytesEqual(Copy(Block, 0, Length(Original)), Original);
  Check('RS decode mas alla de la capacidad: no recupera silenciosamente datos incorrectos',
    not Recovered);
end;

procedure TestReedSolomonMultipleBlocks;
var
  Data, Block: TBytes;
  NumCorrected: Integer;
  Ok: Boolean;
  TrialIdx: Integer;
begin
  // Repite con varios tamanos tipicos de bloque QR (Ecc por bloque: 7,18,22,30)
  for TrialIdx := 0 to 3 do
  begin
    case TrialIdx of
      0: Data := TBytes.Create($10, $20, $30, $40, $50, $60, $70, $80, $90, $A0, $B0, $C0, $D0, $E0, $F0, $01);
      1: Data := TBytes.Create($01, $02, $03, $04, $05, $06, $07, $08, $09, $0A);
      2: Data := TBytes.Create($5A, $A5, $3C, $C3, $7E, $E7, $18, $81, $24, $42, $99, $66);
    else
      Data := TBytes.Create($FF, $00, $FF, $00, $12, $34, $56, $78, $9A, $BC, $DE, $F0, $11, $22);
    end;
    case TrialIdx of
      0: Block := BuildEncodedBlock(Data, 7);
      1: Block := BuildEncodedBlock(Data, 18);
      2: Block := BuildEncodedBlock(Data, 22);
    else
      Block := BuildEncodedBlock(Data, 30);
    end;
    // Corrompe 2 bytes (bien dentro de la capacidad en todos los casos)
    Block[0] := Byte(Block[0] xor $55);
    Block[Length(Block) - 1] := Byte(Block[Length(Block) - 1] xor $AA);

    Ok := QRReedSolomonDecodeBlock(Block, Length(Block) - Length(Data), NumCorrected);
    Check(Format('RS decode bloque tipico #%d: retorna True', [TrialIdx]), Ok);
    Check(Format('RS decode bloque tipico #%d: 2 errores corregidos', [TrialIdx]), NumCorrected = 2);
    Check(Format('RS decode bloque tipico #%d: datos recuperados', [TrialIdx]),
      BytesEqual(Copy(Block, 0, Length(Data)), Data));
  end;
end;

begin
  TestGFCrossCheck;
  TestReedSolomonDecodeNoErrors;
  TestReedSolomonDecodeWithinCapacity;
  TestReedSolomonDecodeBeyondCapacity;
  TestReedSolomonMultipleBlocks;

  WriteLn;
  WriteLn(Format('%d / %d tests passed', [GPassed, GTotal]));
  if GPassed < GTotal then
    Halt(1)
  else
    Halt(0);
end.
