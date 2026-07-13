unit QRFinderPatternFinder;

{
  QRFinderPatternFinder.pas -- Localiza los 3 patrones buscadores (los
  cuadrados anidados en las esquinas de un QR) dentro de una imagen binaria,
  buscando la proporcion 1:1:3:1:1 de modulos claro/oscuro por filas,
  confirmando cada candidato con verificaciones cruzadas vertical, horizontal
  y diagonal, y finalmente eligiendo el trio de candidatos cuya geometria mas
  se aproxima a un triangulo rectangulo isosceles.

  Portado de ZXing (Apache License 2.0): FinderPatternFinder.java,
  FinderPattern.java, FinderPatternInfo.java, ResultPoint.java
  https://github.com/zxing/zxing
  Ver README.md de esta libreria para el aviso de atribucion completo.

  License de esta libreria: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Math, Generics.Collections, QRTypes;

type
  EQRFinderNotFound = class(Exception);

  TQRFinderPattern = record
    X, Y: Single;
    ModuleSize: Single;
    Count: Integer;
  end;

  TQRFinderPatternInfo = record
    BottomLeft, TopLeft, TopRight: TQRFinderPattern;
  end;

// Busca los 3 patrones buscadores en AImage (True = modulo oscuro).
// Lanza EQRFinderNotFound si no encuentra suficientes candidatos o ninguna
// combinacion de 3 se aproxima a un triangulo rectangulo isosceles valido.
function QRFindFinderPatterns(const AImage: TQRModuleGrid; AWidth, AHeight: Integer): TQRFinderPatternInfo;

function QRPointDistance(const A, B: TQRPointF): Single;

implementation

const
  CENTER_QUORUM = 2;
  MAX_FINDER_PATTERN_CANDIDATES = 25;
  MIN_SKIP = 3;
  MAX_MODULES = 97;

function QRPointDistance(const A, B: TQRPointF): Single;
begin
  Result := Sqrt(Sqr(A.X - B.X) + Sqr(A.Y - B.Y));
end;

function SquaredDistance(const A, B: TQRFinderPattern): Double;
var
  DX, DY: Double;
begin
  DX := A.X - B.X;
  DY := A.Y - B.Y;
  Result := DX * DX + DY * DY;
end;

function AboutEquals(const APattern: TQRFinderPattern; AModuleSize, AI, AJ: Single): Boolean;
var
  ModuleSizeDiff: Single;
begin
  if (Abs(AI - APattern.Y) <= AModuleSize) and (Abs(AJ - APattern.X) <= AModuleSize) then
  begin
    ModuleSizeDiff := Abs(AModuleSize - APattern.ModuleSize);
    Exit((ModuleSizeDiff <= 1.0) or (ModuleSizeDiff <= APattern.ModuleSize));
  end;
  Result := False;
end;

function CombineEstimate(const APattern: TQRFinderPattern; AI, AJ, ANewModuleSize: Single): TQRFinderPattern;
var
  CombinedCount: Integer;
begin
  CombinedCount := APattern.Count + 1;
  Result.X := (APattern.Count * APattern.X + AJ) / CombinedCount;
  Result.Y := (APattern.Count * APattern.Y + AI) / CombinedCount;
  Result.ModuleSize := (APattern.Count * APattern.ModuleSize + ANewModuleSize) / CombinedCount;
  Result.Count := CombinedCount;
end;

// ---------------------------------------------------------------------------
// Finder cuya implementacion mantiene estado mutable durante la busqueda
// (equivalente a la clase FinderPatternFinder de ZXing).
// ---------------------------------------------------------------------------

type
  TFinder = class
  private
    FImage: TQRModuleGrid;
    FWidth, FHeight: Integer;
    FPossibleCenters: TList<TQRFinderPattern>;
    FHasSkipped: Boolean;

    function GetPixel(AX, AY: Integer): Boolean; inline;
    function CrossCheckVertical(AStartI, ACenterJ, AMaxCount, AOriginalTotal: Integer): Single;
    function CrossCheckHorizontal(AStartJ, ACenterI, AMaxCount, AOriginalTotal: Integer): Single;
    function CrossCheckDiagonal(ACenterI, ACenterJ: Integer): Boolean;
    function HandlePossibleCenter(const AStateCount: array of Integer; AI, AJ: Integer): Boolean;
    function FindRowSkip: Integer;
    function HaveMultiplyConfirmedCenters: Boolean;
    function SelectBestPatterns: TArray<TQRFinderPattern>;
  public
    constructor Create(const AImage: TQRModuleGrid; AWidth, AHeight: Integer);
    destructor Destroy; override;
    function Find: TQRFinderPatternInfo;
  end;

function CenterFromEnd(const AStateCount: array of Integer; AEnd: Integer): Single;
begin
  Result := (AEnd - AStateCount[4] - AStateCount[3]) - AStateCount[2] / 2.0;
end;

function FoundPatternCross(const AStateCount: array of Integer): Boolean;
var
  TotalModuleSize, I: Integer;
  ModuleSize, MaxVariance: Single;
begin
  TotalModuleSize := 0;
  for I := 0 to 4 do
  begin
    if AStateCount[I] = 0 then
      Exit(False);
    Inc(TotalModuleSize, AStateCount[I]);
  end;
  if TotalModuleSize < 7 then
    Exit(False);
  ModuleSize := TotalModuleSize / 7.0;
  MaxVariance := ModuleSize / 2.0;
  Result :=
    (Abs(ModuleSize - AStateCount[0]) < MaxVariance) and
    (Abs(ModuleSize - AStateCount[1]) < MaxVariance) and
    (Abs(3.0 * ModuleSize - AStateCount[2]) < 3 * MaxVariance) and
    (Abs(ModuleSize - AStateCount[3]) < MaxVariance) and
    (Abs(ModuleSize - AStateCount[4]) < MaxVariance);
end;

function FoundPatternDiagonal(const AStateCount: array of Integer): Boolean;
var
  TotalModuleSize, I: Integer;
  ModuleSize, MaxVariance: Single;
begin
  TotalModuleSize := 0;
  for I := 0 to 4 do
  begin
    if AStateCount[I] = 0 then
      Exit(False);
    Inc(TotalModuleSize, AStateCount[I]);
  end;
  if TotalModuleSize < 7 then
    Exit(False);
  ModuleSize := TotalModuleSize / 7.0;
  MaxVariance := ModuleSize / 1.333;
  Result :=
    (Abs(ModuleSize - AStateCount[0]) < MaxVariance) and
    (Abs(ModuleSize - AStateCount[1]) < MaxVariance) and
    (Abs(3.0 * ModuleSize - AStateCount[2]) < 3 * MaxVariance) and
    (Abs(ModuleSize - AStateCount[3]) < MaxVariance) and
    (Abs(ModuleSize - AStateCount[4]) < MaxVariance);
end;

procedure ShiftCounts2(var AStateCount: array of Integer);
begin
  AStateCount[0] := AStateCount[2];
  AStateCount[1] := AStateCount[3];
  AStateCount[2] := AStateCount[4];
  AStateCount[3] := 1;
  AStateCount[4] := 0;
end;

constructor TFinder.Create(const AImage: TQRModuleGrid; AWidth, AHeight: Integer);
begin
  inherited Create;
  FImage := AImage;
  FWidth := AWidth;
  FHeight := AHeight;
  FPossibleCenters := TList<TQRFinderPattern>.Create;
  FHasSkipped := False;
end;

destructor TFinder.Destroy;
begin
  FPossibleCenters.Free;
  inherited;
end;

function TFinder.GetPixel(AX, AY: Integer): Boolean;
begin
  Result := FImage[AY, AX];
end;

function TFinder.CrossCheckVertical(AStartI, ACenterJ, AMaxCount, AOriginalTotal: Integer): Single;
var
  StateCount: array[0..4] of Integer;
  I, StateCountTotal: Integer;
begin
  FillChar(StateCount, SizeOf(StateCount), 0);

  I := AStartI;
  while (I >= 0) and GetPixel(ACenterJ, I) do begin Inc(StateCount[2]); Dec(I); end;
  if I < 0 then Exit(NaN);
  while (I >= 0) and (not GetPixel(ACenterJ, I)) and (StateCount[1] <= AMaxCount) do begin Inc(StateCount[1]); Dec(I); end;
  if (I < 0) or (StateCount[1] > AMaxCount) then Exit(NaN);
  while (I >= 0) and GetPixel(ACenterJ, I) and (StateCount[0] <= AMaxCount) do begin Inc(StateCount[0]); Dec(I); end;
  if StateCount[0] > AMaxCount then Exit(NaN);

  I := AStartI + 1;
  while (I < FHeight) and GetPixel(ACenterJ, I) do begin Inc(StateCount[2]); Inc(I); end;
  if I = FHeight then Exit(NaN);
  while (I < FHeight) and (not GetPixel(ACenterJ, I)) and (StateCount[3] < AMaxCount) do begin Inc(StateCount[3]); Inc(I); end;
  if (I = FHeight) or (StateCount[3] >= AMaxCount) then Exit(NaN);
  while (I < FHeight) and GetPixel(ACenterJ, I) and (StateCount[4] < AMaxCount) do begin Inc(StateCount[4]); Inc(I); end;
  if StateCount[4] >= AMaxCount then Exit(NaN);

  StateCountTotal := StateCount[0] + StateCount[1] + StateCount[2] + StateCount[3] + StateCount[4];
  if 5 * Abs(StateCountTotal - AOriginalTotal) >= 2 * AOriginalTotal then
    Exit(NaN);

  if FoundPatternCross(StateCount) then
    Result := CenterFromEnd(StateCount, I)
  else
    Result := NaN;
end;

function TFinder.CrossCheckHorizontal(AStartJ, ACenterI, AMaxCount, AOriginalTotal: Integer): Single;
var
  StateCount: array[0..4] of Integer;
  J, StateCountTotal: Integer;
begin
  FillChar(StateCount, SizeOf(StateCount), 0);

  J := AStartJ;
  while (J >= 0) and GetPixel(J, ACenterI) do begin Inc(StateCount[2]); Dec(J); end;
  if J < 0 then Exit(NaN);
  while (J >= 0) and (not GetPixel(J, ACenterI)) and (StateCount[1] <= AMaxCount) do begin Inc(StateCount[1]); Dec(J); end;
  if (J < 0) or (StateCount[1] > AMaxCount) then Exit(NaN);
  while (J >= 0) and GetPixel(J, ACenterI) and (StateCount[0] <= AMaxCount) do begin Inc(StateCount[0]); Dec(J); end;
  if StateCount[0] > AMaxCount then Exit(NaN);

  J := AStartJ + 1;
  while (J < FWidth) and GetPixel(J, ACenterI) do begin Inc(StateCount[2]); Inc(J); end;
  if J = FWidth then Exit(NaN);
  while (J < FWidth) and (not GetPixel(J, ACenterI)) and (StateCount[3] < AMaxCount) do begin Inc(StateCount[3]); Inc(J); end;
  if (J = FWidth) or (StateCount[3] >= AMaxCount) then Exit(NaN);
  while (J < FWidth) and GetPixel(J, ACenterI) and (StateCount[4] < AMaxCount) do begin Inc(StateCount[4]); Inc(J); end;
  if StateCount[4] >= AMaxCount then Exit(NaN);

  StateCountTotal := StateCount[0] + StateCount[1] + StateCount[2] + StateCount[3] + StateCount[4];
  if 5 * Abs(StateCountTotal - AOriginalTotal) >= AOriginalTotal then
    Exit(NaN);

  if FoundPatternCross(StateCount) then
    Result := CenterFromEnd(StateCount, J)
  else
    Result := NaN;
end;

function TFinder.CrossCheckDiagonal(ACenterI, ACenterJ: Integer): Boolean;
var
  StateCount: array[0..4] of Integer;
  I: Integer;
begin
  FillChar(StateCount, SizeOf(StateCount), 0);

  I := 0;
  while (ACenterI >= I) and (ACenterJ >= I) and GetPixel(ACenterJ - I, ACenterI - I) do begin Inc(StateCount[2]); Inc(I); end;
  if StateCount[2] = 0 then Exit(False);
  while (ACenterI >= I) and (ACenterJ >= I) and (not GetPixel(ACenterJ - I, ACenterI - I)) do begin Inc(StateCount[1]); Inc(I); end;
  if StateCount[1] = 0 then Exit(False);
  while (ACenterI >= I) and (ACenterJ >= I) and GetPixel(ACenterJ - I, ACenterI - I) do begin Inc(StateCount[0]); Inc(I); end;
  if StateCount[0] = 0 then Exit(False);

  I := 1;
  while (ACenterI + I < FHeight) and (ACenterJ + I < FWidth) and GetPixel(ACenterJ + I, ACenterI + I) do begin Inc(StateCount[2]); Inc(I); end;
  while (ACenterI + I < FHeight) and (ACenterJ + I < FWidth) and (not GetPixel(ACenterJ + I, ACenterI + I)) do begin Inc(StateCount[3]); Inc(I); end;
  if StateCount[3] = 0 then Exit(False);
  while (ACenterI + I < FHeight) and (ACenterJ + I < FWidth) and GetPixel(ACenterJ + I, ACenterI + I) do begin Inc(StateCount[4]); Inc(I); end;
  if StateCount[4] = 0 then Exit(False);

  Result := FoundPatternDiagonal(StateCount);
end;

function TFinder.HandlePossibleCenter(const AStateCount: array of Integer; AI, AJ: Integer): Boolean;
var
  StateCountTotal: Integer;
  CenterJ, CenterI: Single;
  EstimatedModuleSize: Single;
  Index: Integer;
  Found: Boolean;
  Center: TQRFinderPattern;
begin
  StateCountTotal := AStateCount[0] + AStateCount[1] + AStateCount[2] + AStateCount[3] + AStateCount[4];
  CenterJ := CenterFromEnd(AStateCount, AJ);
  CenterI := CrossCheckVertical(AI, Trunc(CenterJ), AStateCount[2], StateCountTotal);
  if not IsNan(CenterI) then
  begin
    CenterJ := CrossCheckHorizontal(Trunc(CenterJ), Trunc(CenterI), AStateCount[2], StateCountTotal);
    if (not IsNan(CenterJ)) and CrossCheckDiagonal(Trunc(CenterI), Trunc(CenterJ)) then
    begin
      EstimatedModuleSize := StateCountTotal / 7.0;
      Found := False;
      for Index := 0 to FPossibleCenters.Count - 1 do
      begin
        Center := FPossibleCenters[Index];
        if AboutEquals(Center, EstimatedModuleSize, CenterI, CenterJ) then
        begin
          FPossibleCenters[Index] := CombineEstimate(Center, CenterI, CenterJ, EstimatedModuleSize);
          Found := True;
          Break;
        end;
      end;
      if not Found then
      begin
        Center.X := CenterJ;
        Center.Y := CenterI;
        Center.ModuleSize := EstimatedModuleSize;
        Center.Count := 1;
        FPossibleCenters.Add(Center);
      end;
      Exit(True);
    end;
  end;
  Result := False;
end;

function TFinder.FindRowSkip: Integer;
var
  FirstConfirmed: TQRFinderPattern;
  HasFirst: Boolean;
  Center: TQRFinderPattern;
begin
  if FPossibleCenters.Count <= 1 then
    Exit(0);
  HasFirst := False;
  FirstConfirmed := Default(TQRFinderPattern);
  for Center in FPossibleCenters do
    if Center.Count >= CENTER_QUORUM then
    begin
      if not HasFirst then
      begin
        FirstConfirmed := Center;
        HasFirst := True;
      end
      else
      begin
        FHasSkipped := True;
        Exit(Trunc((Abs(FirstConfirmed.X - Center.X) - Abs(FirstConfirmed.Y - Center.Y)) / 2));
      end;
    end;
  Result := 0;
end;

function TFinder.HaveMultiplyConfirmedCenters: Boolean;
var
  ConfirmedCount: Integer;
  TotalModuleSize, Average, TotalDeviation: Single;
  Pattern: TQRFinderPattern;
begin
  ConfirmedCount := 0;
  TotalModuleSize := 0.0;
  for Pattern in FPossibleCenters do
    if Pattern.Count >= CENTER_QUORUM then
    begin
      Inc(ConfirmedCount);
      TotalModuleSize := TotalModuleSize + Pattern.ModuleSize;
    end;
  if ConfirmedCount < 3 then
    Exit(False);
  Average := TotalModuleSize / FPossibleCenters.Count;
  TotalDeviation := 0.0;
  for Pattern in FPossibleCenters do
    TotalDeviation := TotalDeviation + Abs(Pattern.ModuleSize - Average);
  Result := TotalDeviation <= 0.05 * TotalModuleSize;
end;

function TFinder.SelectBestPatterns: TArray<TQRFinderPattern>;
var
  Candidates: TArray<TQRFinderPattern>;
  ConfirmedCount, I, J, K, N: Integer;
  MinModuleSize, MaxModuleSize: Single;
  A, B, C, Temp, D, Distortion: Double;
  Best: array[0..2] of TQRFinderPattern;
  HaveBest: Boolean;
begin
  if FPossibleCenters.Count < 3 then
    raise EQRFinderNotFound.Create('Menos de 3 patrones buscadores candidatos');

  ConfirmedCount := 0;
  for I := 0 to FPossibleCenters.Count - 1 do
    if FPossibleCenters[I].Count >= CENTER_QUORUM then
      Inc(ConfirmedCount);

  if (ConfirmedCount >= 3) or (FPossibleCenters.Count > MAX_FINDER_PATTERN_CANDIDATES) then
    for I := FPossibleCenters.Count - 1 downto 0 do
      if FPossibleCenters[I].Count < CENTER_QUORUM then
        FPossibleCenters.Delete(I);

  Candidates := FPossibleCenters.ToArray;
  // Ordena ascendente por ModuleSize (seleccion simple; hay a lo sumo ~25 candidatos)
  N := Length(Candidates);
  for I := 0 to N - 2 do
    for J := 0 to N - 2 - I do
      if Candidates[J].ModuleSize > Candidates[J + 1].ModuleSize then
      begin
        var Tmp := Candidates[J];
        Candidates[J] := Candidates[J + 1];
        Candidates[J + 1] := Tmp;
      end;

  Distortion := MaxDouble;
  HaveBest := False;
  for I := 0 to N - 3 do
  begin
    MinModuleSize := Candidates[I].ModuleSize;
    for J := I + 1 to N - 2 do
    begin
      A := SquaredDistance(Candidates[I], Candidates[J]);
      for K := J + 1 to N - 1 do
      begin
        MaxModuleSize := Candidates[K].ModuleSize;
        if MaxModuleSize > MinModuleSize * 1.4 then
          Continue;

        B := SquaredDistance(Candidates[J], Candidates[K]);
        C := SquaredDistance(Candidates[I], Candidates[K]);

        // ordena A<=B<=C (variables locales, no afecta los candidatos)
        var A2 := A; var B2 := B; var C2 := C;
        if A2 < B2 then
        begin
          if B2 > C2 then
          begin
            if A2 < C2 then begin Temp := B2; B2 := C2; C2 := Temp; end
            else begin Temp := A2; A2 := C2; C2 := B2; B2 := Temp; end;
          end;
        end
        else
        begin
          if B2 < C2 then
          begin
            if A2 < C2 then begin Temp := A2; A2 := B2; B2 := Temp; end
            else begin Temp := A2; A2 := B2; B2 := C2; C2 := Temp; end;
          end
          else
          begin
            Temp := A2; A2 := C2; C2 := Temp;
          end;
        end;

        D := Abs(C2 - 2 * B2) + Abs(C2 - 2 * A2);
        if D < Distortion then
        begin
          Distortion := D;
          Best[0] := Candidates[I];
          Best[1] := Candidates[J];
          Best[2] := Candidates[K];
          HaveBest := True;
        end;
      end;
    end;
  end;

  if not HaveBest then
    raise EQRFinderNotFound.Create('Ninguna combinacion de 3 candidatos forma un triangulo valido');

  SetLength(Result, 3);
  Result[0] := Best[0];
  Result[1] := Best[1];
  Result[2] := Best[2];
end;

function CrossProductZ(const APointA, APointB, APointC: TQRFinderPattern): Single;
begin
  Result := ((APointC.X - APointB.X) * (APointA.Y - APointB.Y)) - ((APointC.Y - APointB.Y) * (APointA.X - APointB.X));
end;

procedure OrderBestPatterns(var APatterns: TArray<TQRFinderPattern>);
var
  D01, D12, D02: Single;
  PA, PB, PC, Temp: TQRFinderPattern;
  PtA, PtB, PtC: TQRPointF;
begin
  PtA.X := APatterns[0].X; PtA.Y := APatterns[0].Y;
  PtB.X := APatterns[1].X; PtB.Y := APatterns[1].Y;
  PtC.X := APatterns[2].X; PtC.Y := APatterns[2].Y;
  D01 := QRPointDistance(PtA, PtB);
  D12 := QRPointDistance(PtB, PtC);
  D02 := QRPointDistance(PtA, PtC);

  if (D12 >= D01) and (D12 >= D02) then
  begin
    PB := APatterns[0]; PA := APatterns[1]; PC := APatterns[2];
  end
  else if (D02 >= D12) and (D02 >= D01) then
  begin
    PB := APatterns[1]; PA := APatterns[0]; PC := APatterns[2];
  end
  else
  begin
    PB := APatterns[2]; PA := APatterns[0]; PC := APatterns[1];
  end;

  if CrossProductZ(PA, PB, PC) < 0.0 then
  begin
    Temp := PA; PA := PC; PC := Temp;
  end;

  APatterns[0] := PA;
  APatterns[1] := PB;
  APatterns[2] := PC;
end;

function TFinder.Find: TQRFinderPatternInfo;
var
  MaxI, MaxJ, ISkip, RowSkip: Integer;
  StateCount: array[0..4] of Integer;
  CurrentState: Integer;
  I, J: Integer;
  Done, Confirmed: Boolean;
  Best: TArray<TQRFinderPattern>;
begin
  MaxI := FHeight;
  MaxJ := FWidth;

  ISkip := (3 * MaxI) div (4 * MAX_MODULES);
  if ISkip < MIN_SKIP then
    ISkip := MIN_SKIP;

  Done := False;
  I := ISkip - 1;
  while (I < MaxI) and (not Done) do
  begin
    FillChar(StateCount, SizeOf(StateCount), 0);
    CurrentState := 0;
    J := 0;
    while J < MaxJ do
    begin
      if GetPixel(J, I) then
      begin
        // Pixel oscuro
        if (CurrentState and 1) = 1 then // contando blancos
          Inc(CurrentState);
        Inc(StateCount[CurrentState]);
      end
      else
      begin
        // Pixel claro
        if (CurrentState and 1) = 0 then // contando oscuros
        begin
          if CurrentState = 4 then // patron completo, posible ganador
          begin
            if FoundPatternCross(StateCount) then
            begin
              Confirmed := HandlePossibleCenter(StateCount, I, J);
              if Confirmed then
              begin
                ISkip := 2;
                if FHasSkipped then
                  Done := HaveMultiplyConfirmedCenters
                else
                begin
                  RowSkip := FindRowSkip;
                  if RowSkip > StateCount[2] then
                  begin
                    Inc(I, RowSkip - StateCount[2] - ISkip);
                    J := MaxJ - 1;
                  end;
                end;
                CurrentState := 0;
                FillChar(StateCount, SizeOf(StateCount), 0);
              end
              else
              begin
                ShiftCounts2(StateCount);
                CurrentState := 3;
                Inc(J);
                Continue; // equivalente al "continue" del for de Java (ya incremento J)
              end;
            end
            else
            begin
              ShiftCounts2(StateCount);
              CurrentState := 3;
            end;
          end
          else
          begin
            Inc(CurrentState);
            Inc(StateCount[CurrentState]);
          end;
        end
        else
          Inc(StateCount[CurrentState]); // contando blancos
      end;
      Inc(J);
    end;
    if FoundPatternCross(StateCount) then
    begin
      Confirmed := HandlePossibleCenter(StateCount, I, MaxJ);
      if Confirmed then
      begin
        ISkip := StateCount[0];
        if FHasSkipped then
          Done := HaveMultiplyConfirmedCenters;
      end;
    end;
    Inc(I, ISkip);
  end;

  Best := SelectBestPatterns;
  OrderBestPatterns(Best);

  Result.BottomLeft := Best[0];
  Result.TopLeft := Best[1];
  Result.TopRight := Best[2];
end;

function QRFindFinderPatterns(const AImage: TQRModuleGrid; AWidth, AHeight: Integer): TQRFinderPatternInfo;
var
  Finder: TFinder;
begin
  Finder := TFinder.Create(AImage, AWidth, AHeight);
  try
    Result := Finder.Find;
  finally
    Finder.Free;
  end;
end;

end.
