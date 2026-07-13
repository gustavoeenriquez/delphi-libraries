unit QREncoder;

{
  QREncoder.pas -- Construccion completa de un simbolo QR Code (ISO/IEC 18004,
  Model 2, versiones 1-40): eleccion de version/nivel ECC, patrones de funcion
  (buscador, temporizacion, alineacion, formato, version), intercalado de
  codewords Reed-Solomon, colocacion en zigzag, las 8 mascaras y el calculo de
  penalizacion para elegir automaticamente la mejor.

  Algoritmo portado de "QR Code generator library" de Project Nayuki
  (MIT License): https://www.nayuki.io/page/qr-code-generator-library
  Ver LICENSE.md de esta libreria para el aviso de atribucion completo.

  Uso tipico:
    QR := TQRCode.EncodeText('https://example.com', qeMedium);
    try
      for Y := 0 to QR.Size - 1 do
        for X := 0 to QR.Size - 1 do
          if QR.GetModule(X, Y) then ... // modulo oscuro
    finally
      QR.Free;
    end;

  License de esta libreria: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Math, QRTypes, QRSegment, QRReedSolomon, QRBCH;

type
  TQRRunHistory = array[0..6] of Integer;

  TQRCode = class
  private
    FVersion: Integer;
    FSize: Integer;
    FErrorLevel: TQRErrorLevel;
    FMask: Integer;
    FModules: TQRModuleGrid;
    FIsFunction: TQRModuleGrid;

    procedure SetFunctionModule(AX, AY: Integer; AIsDark: Boolean); inline;
    procedure DrawFinderPattern(AX, AY: Integer);
    procedure DrawAlignmentPattern(AX, AY: Integer);
    procedure DrawFormatBits(AMask: Integer);
    procedure DrawVersion;
    procedure DrawFunctionPatterns;
    function AddEccAndInterleave(const AData: TBytes): TBytes;
    procedure DrawCodewords(const AData: TBytes);
    procedure ApplyMask(AMaskIdx: Integer);
    function GetPenaltyScore: Integer;
    procedure FinderPenaltyAddHistory(ACurrentRunLength: Integer; var ARunHistory: TQRRunHistory);
    function FinderPenaltyCountPatterns(const ARunHistory: TQRRunHistory): Integer;
    function FinderPenaltyTerminateAndCount(ACurrentRunColor: Boolean; ACurrentRunLength: Integer;
      var ARunHistory: TQRRunHistory): Integer;
  public
    // Constructor de bajo nivel: ADataCodewords debe tener exactamente
    // QRGetNumDataCodewords(AVersion, AEcl) bytes (con terminador y relleno ya
    // aplicados). AMask entre 0 y 7 fuerza una mascara; -1 elige la optima.
    constructor Create(AVersion: Integer; AEcl: TQRErrorLevel; const ADataCodewords: TBytes; AMask: Integer = -1);

    // API de alto/medio nivel (equivalente a encode_text / encode_binary / encode_segments)
    class function EncodeText(const AText: string; AEcl: TQRErrorLevel): TQRCode;
    class function EncodeBytes(const AData: TBytes; AEcl: TQRErrorLevel): TQRCode;
    class function EncodeSegments(const ASegs: TQRSegmentArray; AEcl: TQRErrorLevel;
      AMinVersion: Integer = QR_MIN_VERSION; AMaxVersion: Integer = QR_MAX_VERSION;
      AMask: Integer = -1; ABoostEcl: Boolean = True): TQRCode;

    function GetModule(AX, AY: Integer): Boolean;

    property Version: Integer read FVersion;
    property Size: Integer read FSize;
    property ErrorLevel: TQRErrorLevel read FErrorLevel;
    property Mask: Integer read FMask;
  end;

implementation

function GetBit(AValue: Integer; AIndex: Integer): Boolean; inline;
begin
  Result := ((AValue shr AIndex) and 1) <> 0;
end;

function QRMaskFunction(AMaskIdx, AX, AY: Integer): Integer;
begin
  case AMaskIdx of
    0: Result := (AX + AY) mod 2;
    1: Result := AY mod 2;
    2: Result := AX mod 3;
    3: Result := (AX + AY) mod 3;
    4: Result := (AX div 3 + AY div 2) mod 2;
    5: Result := (AX * AY) mod 2 + (AX * AY) mod 3;
    6: Result := ((AX * AY) mod 2 + (AX * AY) mod 3) mod 2;
    7: Result := ((AX + AY) mod 2 + (AX * AY) mod 3) mod 2;
  else
    raise EQRError.Create('Indice de mascara invalido');
  end;
end;

{ TQRCode }

constructor TQRCode.Create(AVersion: Integer; AEcl: TQRErrorLevel; const ADataCodewords: TBytes; AMask: Integer);
var
  AllCodewords: TBytes;
  I, BestMask: Integer;
  Penalty, MinPenalty: Int64;
begin
  inherited Create;
  if (AVersion < QR_MIN_VERSION) or (AVersion > QR_MAX_VERSION) then
    raise EQRError.CreateFmt('Version fuera de rango: %d', [AVersion]);
  if (AMask < -1) or (AMask > 7) then
    raise EQRError.CreateFmt('Mascara fuera de rango: %d', [AMask]);

  FVersion := AVersion;
  FSize := QRSizeForVersion(AVersion);
  FErrorLevel := AEcl;

  SetLength(FModules, FSize, FSize);
  SetLength(FIsFunction, FSize, FSize);

  DrawFunctionPatterns;
  AllCodewords := AddEccAndInterleave(ADataCodewords);
  DrawCodewords(AllCodewords);

  if AMask = -1 then
  begin
    MinPenalty := High(Int64);
    BestMask := 0;
    for I := 0 to 7 do
    begin
      ApplyMask(I);
      DrawFormatBits(I);
      Penalty := GetPenaltyScore;
      if Penalty < MinPenalty then
      begin
        BestMask := I;
        MinPenalty := Penalty;
      end;
      ApplyMask(I); // deshace la mascara (XOR es su propia inversa)
    end;
    AMask := BestMask;
  end;

  FMask := AMask;
  ApplyMask(FMask);
  DrawFormatBits(FMask);

  FIsFunction := nil;
end;

class function TQRCode.EncodeText(const AText: string; AEcl: TQRErrorLevel): TQRCode;
begin
  Result := EncodeSegments(QRMakeSegments(AText), AEcl);
end;

class function TQRCode.EncodeBytes(const AData: TBytes; AEcl: TQRErrorLevel): TQRCode;
var
  Segs: TQRSegmentArray;
begin
  SetLength(Segs, 1);
  Segs[0] := QRMakeBytes(AData);
  Result := EncodeSegments(Segs, AEcl);
end;

class function TQRCode.EncodeSegments(const ASegs: TQRSegmentArray; AEcl: TQRErrorLevel;
  AMinVersion, AMaxVersion, AMask: Integer; ABoostEcl: Boolean): TQRCode;
var
  Version, DataCapacityBits, DataUsedBits: Integer;
  Ecl: TQRErrorLevel;
  BB: TQRBitBuffer;
  Seg: TQRSegment;
  PadToggle: Boolean;
  DataCodewords: TBytes;
begin
  if not ((QR_MIN_VERSION <= AMinVersion) and (AMinVersion <= AMaxVersion) and (AMaxVersion <= QR_MAX_VERSION)) then
    raise EQRError.Create('Rango de version invalido');
  if (AMask < -1) or (AMask > 7) then
    raise EQRError.Create('Mascara fuera de rango');

  Ecl := AEcl;
  Version := AMinVersion;
  while True do
  begin
    DataCapacityBits := QRGetNumDataCodewords(Version, Ecl) * 8;
    DataUsedBits := QRGetTotalBits(ASegs, Version);
    if (DataUsedBits >= 0) and (DataUsedBits <= DataCapacityBits) then
      Break;
    if Version >= AMaxVersion then
      raise EQRError.CreateFmt('Los datos no caben en ninguna version del rango pedido (bits=%d, capacidad max=%d)',
        [DataUsedBits, DataCapacityBits]);
    Inc(Version);
  end;

  if ABoostEcl then
  begin
    if (Ord(Ecl) < Ord(qeMedium)) and (DataUsedBits <= QRGetNumDataCodewords(Version, qeMedium) * 8) then
      Ecl := qeMedium;
    if (Ord(Ecl) < Ord(qeQuartile)) and (DataUsedBits <= QRGetNumDataCodewords(Version, qeQuartile) * 8) then
      Ecl := qeQuartile;
    if (Ord(Ecl) < Ord(qeHigh)) and (DataUsedBits <= QRGetNumDataCodewords(Version, qeHigh) * 8) then
      Ecl := qeHigh;
  end;

  BB.Init;
  for Seg in ASegs do
  begin
    BB.AppendBits(QRModeBits(Seg.Mode), 4);
    BB.AppendBits(Seg.NumChars, QRModeCharCountBits(Seg.Mode, Version));
    BB.AppendBitBuffer(Seg.Bits);
  end;

  DataCapacityBits := QRGetNumDataCodewords(Version, Ecl) * 8;

  // Terminador (hasta 4 bits en cero)
  BB.AppendBits(0, Min(4, DataCapacityBits - BB.BitLength));
  // Relleno hasta el siguiente byte completo
  BB.AppendBits(0, (8 - BB.BitLength mod 8) mod 8);
  // Bytes de relleno alternos 0xEC, 0x11 hasta llenar la capacidad
  PadToggle := True;
  while BB.BitLength < DataCapacityBits do
  begin
    if PadToggle then
      BB.AppendBits($EC, 8)
    else
      BB.AppendBits($11, 8);
    PadToggle := not PadToggle;
  end;

  DataCodewords := BB.ToBytes;
  Result := TQRCode.Create(Version, Ecl, DataCodewords, AMask);
end;

function TQRCode.GetModule(AX, AY: Integer): Boolean;
begin
  if (AX < 0) or (AX >= FSize) or (AY < 0) or (AY >= FSize) then
    Exit(False);
  Result := FModules[AY, AX];
end;

procedure TQRCode.SetFunctionModule(AX, AY: Integer; AIsDark: Boolean);
begin
  FModules[AY, AX] := AIsDark;
  FIsFunction[AY, AX] := True;
end;

procedure TQRCode.DrawFinderPattern(AX, AY: Integer);
var
  DX, DY, XX, YY: Integer;
begin
  for DY := -4 to 4 do
    for DX := -4 to 4 do
    begin
      XX := AX + DX;
      YY := AY + DY;
      if (XX >= 0) and (XX < FSize) and (YY >= 0) and (YY < FSize) then
        SetFunctionModule(XX, YY, not (Max(Abs(DX), Abs(DY)) in [2, 4]));
    end;
end;

procedure TQRCode.DrawAlignmentPattern(AX, AY: Integer);
var
  DX, DY: Integer;
begin
  for DY := -2 to 2 do
    for DX := -2 to 2 do
      SetFunctionModule(AX + DX, AY + DY, Max(Abs(DX), Abs(DY)) <> 1);
end;

procedure TQRCode.DrawFunctionPatterns;
var
  I, Ii, Jj, NumAlign: Integer;
  AlignPos: TArray<Integer>;
begin
  for I := 0 to FSize - 1 do
  begin
    SetFunctionModule(6, I, I mod 2 = 0);
    SetFunctionModule(I, 6, I mod 2 = 0);
  end;

  DrawFinderPattern(3, 3);
  DrawFinderPattern(FSize - 4, 3);
  DrawFinderPattern(3, FSize - 4);

  AlignPos := QRGetAlignmentPatternPositions(FVersion);
  NumAlign := Length(AlignPos);
  for Ii := 0 to NumAlign - 1 do
    for Jj := 0 to NumAlign - 1 do
    begin
      // No dibujar sobre las tres esquinas de los buscadores
      if (Ii = 0) and (Jj = 0) then Continue;
      if (Ii = 0) and (Jj = NumAlign - 1) then Continue;
      if (Ii = NumAlign - 1) and (Jj = 0) then Continue;
      DrawAlignmentPattern(AlignPos[Ii], AlignPos[Jj]);
    end;

  DrawFormatBits(0); // valor de mascara ficticio, se sobrescribe al final
  DrawVersion;
end;

procedure TQRCode.DrawFormatBits(AMask: Integer);
var
  Bits, I: Integer;
begin
  Bits := QRComputeFormatBits(FErrorLevel, AMask);

  // Primera copia
  for I := 0 to 5 do
    SetFunctionModule(8, I, GetBit(Bits, I));
  SetFunctionModule(8, 7, GetBit(Bits, 6));
  SetFunctionModule(8, 8, GetBit(Bits, 7));
  SetFunctionModule(7, 8, GetBit(Bits, 8));
  for I := 9 to 14 do
    SetFunctionModule(14 - I, 8, GetBit(Bits, I));

  // Segunda copia
  for I := 0 to 7 do
    SetFunctionModule(FSize - 1 - I, 8, GetBit(Bits, I));
  for I := 8 to 14 do
    SetFunctionModule(8, FSize - 15 + I, GetBit(Bits, I));
  SetFunctionModule(8, FSize - 8, True); // siempre oscuro
end;

procedure TQRCode.DrawVersion;
var
  Bits, I, A, B: Integer;
  Bit: Boolean;
begin
  if FVersion < 7 then
    Exit;
  Bits := QRComputeVersionBits(FVersion);

  for I := 0 to 17 do
  begin
    Bit := GetBit(Bits, I);
    A := FSize - 11 + (I mod 3);
    B := I div 3;
    SetFunctionModule(A, B, Bit);
    SetFunctionModule(B, A, Bit);
  end;
end;

function TQRCode.AddEccAndInterleave(const AData: TBytes): TBytes;
var
  NumBlocks, BlockEccLen, RawCodewords, NumShortBlocks, ShortBlockLen: Integer;
  RsDiv: TBytes;
  Blocks: array of TBytes;
  Dat, Ecc: TBytes;
  DatLen, I, J, K: Integer;
begin
  NumBlocks := NUM_ERROR_CORRECTION_BLOCKS[FErrorLevel, FVersion];
  BlockEccLen := ECC_CODEWORDS_PER_BLOCK[FErrorLevel, FVersion];
  RawCodewords := QRGetNumRawDataModules(FVersion) div 8;
  NumShortBlocks := NumBlocks - (RawCodewords mod NumBlocks);
  ShortBlockLen := RawCodewords div NumBlocks;

  SetLength(Blocks, NumBlocks);
  RsDiv := QRReedSolomonComputeDivisor(BlockEccLen);
  K := 0;
  for I := 0 to NumBlocks - 1 do
  begin
    if I < NumShortBlocks then
      DatLen := ShortBlockLen - BlockEccLen
    else
      DatLen := ShortBlockLen - BlockEccLen + 1;

    SetLength(Dat, DatLen);
    if DatLen > 0 then
      Move(AData[K], Dat[0], DatLen);
    Inc(K, DatLen);

    Ecc := QRReedSolomonComputeRemainder(Dat, RsDiv);

    if I < NumShortBlocks then
    begin
      SetLength(Dat, DatLen + 1);
      Dat[DatLen] := 0; // relleno: se omite al intercalar
    end;

    SetLength(Blocks[I], Length(Dat) + Length(Ecc));
    if Length(Dat) > 0 then
      Move(Dat[0], Blocks[I][0], Length(Dat));
    if Length(Ecc) > 0 then
      Move(Ecc[0], Blocks[I][Length(Dat)], Length(Ecc));
  end;

  SetLength(Result, RawCodewords);
  K := 0;
  for I := 0 to Length(Blocks[0]) - 1 do
    for J := 0 to NumBlocks - 1 do
      if (I <> ShortBlockLen - BlockEccLen) or (J >= NumShortBlocks) then
      begin
        Result[K] := Blocks[J][I];
        Inc(K);
      end;
end;

procedure TQRCode.DrawCodewords(const AData: TBytes);
var
  I, RightBase, Right, Vert, J, X, Y: Integer;
  Upward: Boolean;
begin
  I := 0;
  RightBase := FSize - 1;
  while RightBase > 0 do
  begin
    Right := RightBase;
    if Right <= 6 then
      Dec(Right);
    for Vert := 0 to FSize - 1 do
      for J := 0 to 1 do
      begin
        X := Right - J;
        Upward := (Right + 1) and 2 = 0;
        if Upward then
          Y := FSize - 1 - Vert
        else
          Y := Vert;
        if (not FIsFunction[Y, X]) and (I < Length(AData) * 8) then
        begin
          FModules[Y, X] := ((AData[I shr 3] shr (7 - (I and 7))) and 1) <> 0;
          Inc(I);
        end;
      end;
    Dec(RightBase, 2);
  end;
end;

procedure TQRCode.ApplyMask(AMaskIdx: Integer);
var
  X, Y: Integer;
begin
  for Y := 0 to FSize - 1 do
    for X := 0 to FSize - 1 do
      if (not FIsFunction[Y, X]) and (QRMaskFunction(AMaskIdx, X, Y) = 0) then
        FModules[Y, X] := not FModules[Y, X];
end;

procedure TQRCode.FinderPenaltyAddHistory(ACurrentRunLength: Integer; var ARunHistory: TQRRunHistory);
var
  I: Integer;
begin
  if ARunHistory[0] = 0 then
    Inc(ACurrentRunLength, FSize); // borde claro virtual antes de la primera racha
  for I := High(TQRRunHistory) downto 1 do
    ARunHistory[I] := ARunHistory[I - 1];
  ARunHistory[0] := ACurrentRunLength;
end;

function TQRCode.FinderPenaltyCountPatterns(const ARunHistory: TQRRunHistory): Integer;
var
  N: Integer;
  Core: Boolean;
begin
  N := ARunHistory[1];
  Core := (N > 0) and (ARunHistory[2] = N) and (ARunHistory[4] = N) and (ARunHistory[5] = N) and (ARunHistory[3] = N * 3);
  Result := 0;
  if Core and (ARunHistory[0] >= N * 4) and (ARunHistory[6] >= N) then
    Inc(Result);
  if Core and (ARunHistory[6] >= N * 4) and (ARunHistory[0] >= N) then
    Inc(Result);
end;

function TQRCode.FinderPenaltyTerminateAndCount(ACurrentRunColor: Boolean; ACurrentRunLength: Integer;
  var ARunHistory: TQRRunHistory): Integer;
begin
  if ACurrentRunColor then // termina una racha oscura
  begin
    FinderPenaltyAddHistory(ACurrentRunLength, ARunHistory);
    ACurrentRunLength := 0;
  end;
  Inc(ACurrentRunLength, FSize); // borde claro al final de la linea
  FinderPenaltyAddHistory(ACurrentRunLength, ARunHistory);
  Result := FinderPenaltyCountPatterns(ARunHistory);
end;

function TQRCode.GetPenaltyScore: Integer;
var
  Total: Integer;
  X, Y, Dark, K: Integer;
  RunColor: Boolean;
  RunLen: Integer;
  RunHistory: TQRRunHistory;
begin
  Result := 0;

  // Rachas horizontales + patrones tipo buscador
  for Y := 0 to FSize - 1 do
  begin
    RunColor := False;
    RunLen := 0;
    FillChar(RunHistory, SizeOf(RunHistory), 0);
    for X := 0 to FSize - 1 do
    begin
      if FModules[Y, X] = RunColor then
      begin
        Inc(RunLen);
        if RunLen = 5 then
          Inc(Result, QR_PENALTY_N1)
        else if RunLen > 5 then
          Inc(Result);
      end
      else
      begin
        FinderPenaltyAddHistory(RunLen, RunHistory);
        if not RunColor then
          Inc(Result, FinderPenaltyCountPatterns(RunHistory) * QR_PENALTY_N3);
        RunColor := FModules[Y, X];
        RunLen := 1;
      end;
    end;
    Inc(Result, FinderPenaltyTerminateAndCount(RunColor, RunLen, RunHistory) * QR_PENALTY_N3);
  end;

  // Rachas verticales + patrones tipo buscador
  for X := 0 to FSize - 1 do
  begin
    RunColor := False;
    RunLen := 0;
    FillChar(RunHistory, SizeOf(RunHistory), 0);
    for Y := 0 to FSize - 1 do
    begin
      if FModules[Y, X] = RunColor then
      begin
        Inc(RunLen);
        if RunLen = 5 then
          Inc(Result, QR_PENALTY_N1)
        else if RunLen > 5 then
          Inc(Result);
      end
      else
      begin
        FinderPenaltyAddHistory(RunLen, RunHistory);
        if not RunColor then
          Inc(Result, FinderPenaltyCountPatterns(RunHistory) * QR_PENALTY_N3);
        RunColor := FModules[Y, X];
        RunLen := 1;
      end;
    end;
    Inc(Result, FinderPenaltyTerminateAndCount(RunColor, RunLen, RunHistory) * QR_PENALTY_N3);
  end;

  // Bloques 2x2 del mismo color
  for Y := 0 to FSize - 2 do
    for X := 0 to FSize - 2 do
      if (FModules[Y, X] = FModules[Y, X + 1]) and (FModules[Y, X] = FModules[Y + 1, X])
        and (FModules[Y, X] = FModules[Y + 1, X + 1]) then
        Inc(Result, QR_PENALTY_N2);

  // Balance de modulos oscuros/claros
  Dark := 0;
  for Y := 0 to FSize - 1 do
    for X := 0 to FSize - 1 do
      if FModules[Y, X] then
        Inc(Dark);
  Total := FSize * FSize;
  K := (Abs(Dark * 20 - Total * 10) + Total - 1) div Total - 1;
  Inc(Result, K * QR_PENALTY_N4);
end;

end.
