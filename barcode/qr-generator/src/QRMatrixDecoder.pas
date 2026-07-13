unit QRMatrixDecoder;

{
  QRMatrixDecoder.pas -- Decodifica una grilla de modulos (TQRModuleGrid) YA
  binarizada y alineada a la cuadricula del simbolo (sin correccion de
  perspectiva pendiente: eso lo hace QRReader antes de llamar aqui).

  Cada funcion de lectura (formato, version, codewords en zigzag, mascara de
  modulos de funcion) es el espejo exacto de la funcion de escritura homonima
  en QREncoder.pas -- lee las mismas coordenadas, en el mismo orden de bits,
  que se usaron para escribirlas. Esto garantiza consistencia con el encoder
  de esta misma libreria (ya verificado de punta a punta con un decodificador
  externo independiente, ver README.md).

  Pipeline: format info (BCH, 2 copias) -> version info si aplica (BCH, 2
  copias) -> desenmascarar -> leer codewords en zigzag inverso -> desentrelazar
  bloques -> corregir errores (Reed-Solomon) -> parsear bitstream a texto.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, QRTypes, QRBCH, QRReedSolomonDecoder, QRBitStreamDecoder;

type
  TQRMatrixDecodeResult = record
    Success: Boolean;
    ErrorMessage: string;
    Version: Integer;
    ErrorLevel: TQRErrorLevel;
    Mask: Integer;
    NumErrorsCorrected: Integer;
    Text: string;
    KanjiSjisBytes: TBytes;
    EciValues: TArray<Integer>;
  end;

// Calcula que coordenadas son "modulos de funcion" (buscador, separador,
// timing, alineacion, formato, version, modulo oscuro fijo) para una version
// dada -- necesario para saber cuales modulos NO llevan datos.
function QRComputeFunctionModuleMask(AVersion: Integer): TQRModuleGrid;

// Decodifica una grilla ya alineada (AModules[Y,X], tamano ASize x ASize).
function QRDecodeMatrix(const AModules: TQRModuleGrid; ASize: Integer): TQRMatrixDecodeResult;

implementation

// ---------------------------------------------------------------------------
// Modulos de funcion (espejo de QREncoder.DrawFunctionPatterns)
// ---------------------------------------------------------------------------

procedure MarkFinderPattern(var AGrid: TQRModuleGrid; ASize, ACx, ACy: Integer);
var
  DX, DY, XX, YY: Integer;
begin
  for DY := -4 to 4 do
    for DX := -4 to 4 do
    begin
      XX := ACx + DX;
      YY := ACy + DY;
      if (XX >= 0) and (XX < ASize) and (YY >= 0) and (YY < ASize) then
        AGrid[YY, XX] := True;
    end;
end;

procedure MarkAlignmentPattern(var AGrid: TQRModuleGrid; ACx, ACy: Integer);
var
  DX, DY: Integer;
begin
  for DY := -2 to 2 do
    for DX := -2 to 2 do
      AGrid[ACy + DY, ACx + DX] := True;
end;

function QRComputeFunctionModuleMask(AVersion: Integer): TQRModuleGrid;
var
  Size, I, Ii, Jj, NumAlign: Integer;
  AlignPos: TArray<Integer>;
begin
  Size := QRSizeForVersion(AVersion);
  SetLength(Result, Size, Size);

  for I := 0 to Size - 1 do
  begin
    Result[I, 6] := True;
    Result[6, I] := True;
  end;

  MarkFinderPattern(Result, Size, 3, 3);
  MarkFinderPattern(Result, Size, Size - 4, 3);
  MarkFinderPattern(Result, Size, 3, Size - 4);

  AlignPos := QRGetAlignmentPatternPositions(AVersion);
  NumAlign := Length(AlignPos);
  for Ii := 0 to NumAlign - 1 do
    for Jj := 0 to NumAlign - 1 do
    begin
      if (Ii = 0) and (Jj = 0) then Continue;
      if (Ii = 0) and (Jj = NumAlign - 1) then Continue;
      if (Ii = NumAlign - 1) and (Jj = 0) then Continue;
      MarkAlignmentPattern(Result, AlignPos[Ii], AlignPos[Jj]);
    end;

  // Format info (2 copias) -- espejo de QREncoder.DrawFormatBits
  for I := 0 to 5 do Result[I, 8] := True;
  Result[7, 8] := True;
  Result[8, 8] := True;
  Result[8, 7] := True;
  for I := 9 to 14 do Result[8, 14 - I] := True;
  for I := 0 to 7 do Result[8, Size - 1 - I] := True;
  for I := 8 to 14 do Result[Size - 15 + I, 8] := True;
  Result[Size - 8, 8] := True; // modulo oscuro fijo

  // Version info (2 copias, solo v>=7) -- espejo de QREncoder.DrawVersion
  if AVersion >= 7 then
    for I := 0 to 17 do
    begin
      Result[I div 3, Size - 11 + (I mod 3)] := True;
      Result[Size - 11 + (I mod 3), I div 3] := True;
    end;
end;

// ---------------------------------------------------------------------------
// Lectura de format info / version info (espejo de QREncoder.DrawFormatBits/DrawVersion)
// ---------------------------------------------------------------------------

function GetBitAt(const AModules: TQRModuleGrid; AX, AY: Integer): Integer; inline;
begin
  if AModules[AY, AX] then Result := 1 else Result := 0;
end;

function ReadFormatCopy1(const AModules: TQRModuleGrid): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to 5 do Result := Result or (GetBitAt(AModules, 8, I) shl I);
  Result := Result or (GetBitAt(AModules, 8, 7) shl 6);
  Result := Result or (GetBitAt(AModules, 8, 8) shl 7);
  Result := Result or (GetBitAt(AModules, 7, 8) shl 8);
  for I := 9 to 14 do Result := Result or (GetBitAt(AModules, 14 - I, 8) shl I);
end;

function ReadFormatCopy2(const AModules: TQRModuleGrid; ASize: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to 7 do Result := Result or (GetBitAt(AModules, ASize - 1 - I, 8) shl I);
  for I := 8 to 14 do Result := Result or (GetBitAt(AModules, 8, ASize - 15 + I) shl I);
end;

function ReadVersionCopy1(const AModules: TQRModuleGrid; ASize: Integer): Integer;
var
  I, A, B: Integer;
begin
  Result := 0;
  for I := 0 to 17 do
  begin
    A := ASize - 11 + (I mod 3);
    B := I div 3;
    Result := Result or (GetBitAt(AModules, A, B) shl I);
  end;
end;

function ReadVersionCopy2(const AModules: TQRModuleGrid; ASize: Integer): Integer;
var
  I, A, B: Integer;
begin
  Result := 0;
  for I := 0 to 17 do
  begin
    A := ASize - 11 + (I mod 3);
    B := I div 3;
    Result := Result or (GetBitAt(AModules, B, A) shl I);
  end;
end;

// ---------------------------------------------------------------------------
// Codewords en zigzag (espejo de QREncoder.DrawCodewords)
// ---------------------------------------------------------------------------

function ReadCodewords(const AModules, AIsFunction: TQRModuleGrid; ASize, ANumRawBytes: Integer): TBytes;
var
  I, RightBase, Right, Vert, J, X, Y: Integer;
  Upward: Boolean;
begin
  SetLength(Result, ANumRawBytes);
  FillChar(Result[0], ANumRawBytes, 0);
  I := 0;
  RightBase := ASize - 1;
  while RightBase > 0 do
  begin
    Right := RightBase;
    if Right <= 6 then Dec(Right);
    for Vert := 0 to ASize - 1 do
      for J := 0 to 1 do
      begin
        X := Right - J;
        Upward := (Right + 1) and 2 = 0;
        if Upward then Y := ASize - 1 - Vert else Y := Vert;
        if (not AIsFunction[Y, X]) and (I < ANumRawBytes * 8) then
        begin
          if AModules[Y, X] then
            Result[I shr 3] := Result[I shr 3] or ($80 shr (I and 7));
          Inc(I);
        end;
      end;
    Dec(RightBase, 2);
  end;
end;

// ---------------------------------------------------------------------------
// Desentrelazado de bloques (inverso exacto de QREncoder.AddEccAndInterleave)
// ---------------------------------------------------------------------------

procedure DeinterleaveBlocks(const ARawCodewords: TBytes; AVersion: Integer; AEcl: TQRErrorLevel;
  out ABlocks: TArray<TBytes>; out ABlockDataLens: TArray<Integer>; out ABlockEccLen: Integer);
var
  NumBlocks, RawCodewords, NumShortBlocks, ShortBlockLen: Integer;
  Padded: TArray<TBytes>;
  I, J, K, PaddedLen: Integer;
begin
  NumBlocks := NUM_ERROR_CORRECTION_BLOCKS[AEcl, AVersion];
  ABlockEccLen := ECC_CODEWORDS_PER_BLOCK[AEcl, AVersion];
  RawCodewords := QRGetNumRawDataModules(AVersion) div 8;
  NumShortBlocks := NumBlocks - (RawCodewords mod NumBlocks);
  ShortBlockLen := RawCodewords div NumBlocks;
  PaddedLen := ShortBlockLen + 1;

  // 1) Reconstruye la forma "acolchada" identica a QREncoder.AddEccAndInterleave
  //    (los bloques cortos llevan un byte de relleno en la posicion
  //    ShortBlockLen-ABlockEccLen que NUNCA se transmite -- se salta abajo).
  SetLength(Padded, NumBlocks);
  SetLength(ABlockDataLens, NumBlocks);
  for I := 0 to NumBlocks - 1 do
  begin
    if I < NumShortBlocks then
      ABlockDataLens[I] := ShortBlockLen - ABlockEccLen
    else
      ABlockDataLens[I] := ShortBlockLen - ABlockEccLen + 1;
    SetLength(Padded[I], PaddedLen);
  end;

  K := 0;
  for I := 0 to ShortBlockLen do // shortblocklen+1 iteraciones (0..shortblocklen)
    for J := 0 to NumBlocks - 1 do
      if (I <> ShortBlockLen - ABlockEccLen) or (J >= NumShortBlocks) then
      begin
        Padded[J][I] := ARawCodewords[K];
        Inc(K);
      end;

  // 2) Compacta cada bloque a su codeword real [data][ecc] SIN el relleno,
  //    que es lo que espera QRReedSolomonDecodeBlock (arreglo contiguo).
  SetLength(ABlocks, NumBlocks);
  for J := 0 to NumBlocks - 1 do
  begin
    SetLength(ABlocks[J], ABlockDataLens[J] + ABlockEccLen);
    Move(Padded[J][0], ABlocks[J][0], ABlockDataLens[J]);
    Move(Padded[J][PaddedLen - ABlockEccLen], ABlocks[J][ABlockDataLens[J]], ABlockEccLen);
  end;
end;

function QRDecodeMatrix(const AModules: TQRModuleGrid; ASize: Integer): TQRMatrixDecodeResult;
var
  ProvisionalVersion, Version: Integer;
  Ecl: TQRErrorLevel;
  Mask: Integer;
  IsFunction: TQRModuleGrid;
  UnmaskedModules: TQRModuleGrid;
  X, Y: Integer;
  RawCodewords: TBytes;
  NumRawBytes, NumDataCodewords: Integer;
  Blocks: TArray<TBytes>;
  BlockDataLens: TArray<Integer>;
  BlockEccLen: Integer;
  I: Integer;
  NumCorrectedThisBlock, TotalCorrected: Integer;
  DataStream: TBytes;
  Offset: Integer;
  BitResult: TQRDecodedResult;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Success := False;

  ProvisionalVersion := (ASize - 17) div 4;
  if (ASize < 21) or (ASize > 177) or ((ASize - 17) mod 4 <> 0) then
  begin
    Result.ErrorMessage := 'Tamano de grilla invalido (no corresponde a ninguna version QR)';
    Exit;
  end;

  if ProvisionalVersion >= 7 then
  begin
    if not QRDecodeVersionBitsBest(ReadVersionCopy1(AModules, ASize), ReadVersionCopy2(AModules, ASize), Version) then
    begin
      Result.ErrorMessage := 'No se pudo leer version info (demasiados errores)';
      Exit;
    end;
    if Version <> ProvisionalVersion then
    begin
      Result.ErrorMessage := Format('Version info (%d) no coincide con el tamano de la grilla (v%d)', [Version, ProvisionalVersion]);
      Exit;
    end;
  end
  else
    Version := ProvisionalVersion;

  if not QRDecodeFormatBitsBest(ReadFormatCopy1(AModules), ReadFormatCopy2(AModules, ASize), Ecl, Mask) then
  begin
    Result.ErrorMessage := 'No se pudo leer format info (demasiados errores)';
    Exit;
  end;

  IsFunction := QRComputeFunctionModuleMask(Version);

  // Desenmascarar (XOR es su propia inversa) en una copia editable
  SetLength(UnmaskedModules, ASize, ASize);
  for Y := 0 to ASize - 1 do
    for X := 0 to ASize - 1 do
    begin
      UnmaskedModules[Y, X] := AModules[Y, X];
      if (not IsFunction[Y, X]) and (QRMaskFunction(Mask, X, Y) = 0) then
        UnmaskedModules[Y, X] := not UnmaskedModules[Y, X];
    end;

  NumRawBytes := QRGetNumRawDataModules(Version) div 8;
  RawCodewords := ReadCodewords(UnmaskedModules, IsFunction, ASize, NumRawBytes);

  DeinterleaveBlocks(RawCodewords, Version, Ecl, Blocks, BlockDataLens, BlockEccLen);

  TotalCorrected := 0;
  for I := 0 to High(Blocks) do
  begin
    if not QRReedSolomonDecodeBlock(Blocks[I], BlockEccLen, NumCorrectedThisBlock) then
    begin
      Result.ErrorMessage := Format('Bloque %d: demasiados errores para corregir con Reed-Solomon', [I]);
      Exit;
    end;
    Inc(TotalCorrected, NumCorrectedThisBlock);
  end;

  NumDataCodewords := QRGetNumDataCodewords(Version, Ecl);
  SetLength(DataStream, NumDataCodewords);
  Offset := 0;
  for I := 0 to High(Blocks) do
  begin
    Move(Blocks[I][0], DataStream[Offset], BlockDataLens[I]);
    Inc(Offset, BlockDataLens[I]);
  end;

  try
    BitResult := QRDecodeBitStream(DataStream, Version);
  except
    on E: Exception do
    begin
      Result.ErrorMessage := 'Error al parsear el stream de datos: ' + E.Message;
      Exit;
    end;
  end;

  Result.Success := True;
  Result.Version := Version;
  Result.ErrorLevel := Ecl;
  Result.Mask := Mask;
  Result.NumErrorsCorrected := TotalCorrected;
  Result.Text := BitResult.Text;
  Result.KanjiSjisBytes := BitResult.KanjiSjisBytes;
  Result.EciValues := BitResult.EciValues;
end;

end.
