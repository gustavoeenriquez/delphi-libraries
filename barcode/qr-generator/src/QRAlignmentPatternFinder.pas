unit QRAlignmentPatternFinder;

{
  QRAlignmentPatternFinder.pas -- Busca el patron de alineacion (el cuadrado
  anidado mas pequeno cerca de la esquina inferior derecha) dentro de una
  subregion de la imagen, alrededor de la posicion estimada a partir de los
  3 patrones buscadores. Se usa como 4to punto de referencia para ajustar
  perspectiva en versiones >= 2.

  Portado de ZXing (Apache License 2.0): AlignmentPatternFinder.java,
  AlignmentPattern.java
  https://github.com/zxing/zxing
  Ver README.md de esta libreria para el aviso de atribucion completo.

  License de esta libreria: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Math, QRTypes, QRFinderPatternFinder;

// Busca dentro del rectangulo [AStartX,AStartY,AWidth,AHeight] (recortado a
// los limites de la imagen). AModuleSize es la estimacion previa (de los
// patrones buscadores). Devuelve True y el centro hallado en AFound, o False
// si no se encontro ningun candidato razonable.
function QRFindAlignmentPattern(const AImage: TQRModuleGrid; AImgWidth, AImgHeight: Integer;
  AStartX, AStartY, AWidth, AHeight: Integer; AModuleSize: Single; out AFound: TQRPointF): Boolean;

implementation

type
  TAlignCandidate = record
    X, Y, ModuleSize: Single;
    Count: Integer;
  end;

function AboutEquals(const APattern: TAlignCandidate; AModuleSize, AI, AJ: Single): Boolean;
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

function CombineEstimate(const APattern: TAlignCandidate; AI, AJ, ANewModuleSize: Single): TAlignCandidate;
var
  CombinedCount: Integer;
begin
  CombinedCount := APattern.Count + 1;
  Result.X := (APattern.Count * APattern.X + AJ) / CombinedCount;
  Result.Y := (APattern.Count * APattern.Y + AI) / CombinedCount;
  Result.ModuleSize := (APattern.Count * APattern.ModuleSize + ANewModuleSize) / CombinedCount;
  Result.Count := CombinedCount;
end;

function QRFindAlignmentPattern(const AImage: TQRModuleGrid; AImgWidth, AImgHeight: Integer;
  AStartX, AStartY, AWidth, AHeight: Integer; AModuleSize: Single; out AFound: TQRPointF): Boolean;
var
  MaxJ, MiddleI: Integer;
  StateCount: array[0..2] of Integer;
  CrossCheckState: array[0..2] of Integer;
  Candidates: TArray<TAlignCandidate>;
  NumCandidates: Integer;

  function FoundPatternCross(const ASC: array of Integer): Boolean;
  var
    MaxVariance: Single;
    K: Integer;
  begin
    MaxVariance := AModuleSize / 2.0;
    for K := 0 to 2 do
      if Abs(AModuleSize - ASC[K]) >= MaxVariance then
        Exit(False);
    Result := True;
  end;

  function CenterFromEnd(const ASC: array of Integer; AEnd: Integer): Single;
  begin
    Result := (AEnd - ASC[2]) - ASC[1] / 2.0;
  end;

  function CrossCheckVertical(AStartI, ACenterJ, AMaxCount, AOriginalTotal: Integer): Single;
  var
    I, StateCountTotal: Integer;
  begin
    CrossCheckState[0] := 0; CrossCheckState[1] := 0; CrossCheckState[2] := 0;

    I := AStartI;
    while (I >= 0) and AImage[I, ACenterJ] and (CrossCheckState[1] <= AMaxCount) do
    begin
      Inc(CrossCheckState[1]); Dec(I);
    end;
    if (I < 0) or (CrossCheckState[1] > AMaxCount) then Exit(NaN);
    while (I >= 0) and (not AImage[I, ACenterJ]) and (CrossCheckState[0] <= AMaxCount) do
    begin
      Inc(CrossCheckState[0]); Dec(I);
    end;
    if CrossCheckState[0] > AMaxCount then Exit(NaN);

    I := AStartI + 1;
    while (I < AImgHeight) and AImage[I, ACenterJ] and (CrossCheckState[1] <= AMaxCount) do
    begin
      Inc(CrossCheckState[1]); Inc(I);
    end;
    if (I = AImgHeight) or (CrossCheckState[1] > AMaxCount) then Exit(NaN);
    while (I < AImgHeight) and (not AImage[I, ACenterJ]) and (CrossCheckState[2] <= AMaxCount) do
    begin
      Inc(CrossCheckState[2]); Inc(I);
    end;
    if CrossCheckState[2] > AMaxCount then Exit(NaN);

    StateCountTotal := CrossCheckState[0] + CrossCheckState[1] + CrossCheckState[2];
    if 5 * Abs(StateCountTotal - AOriginalTotal) >= 2 * AOriginalTotal then
      Exit(NaN);

    if FoundPatternCross(CrossCheckState) then
      Result := CenterFromEnd(CrossCheckState, I)
    else
      Result := NaN;
  end;

  // Devuelve True si esta confirmado (segunda vez que se ve el mismo centro).
  function HandlePossibleCenter(const ASC: array of Integer; AI, AJ: Integer; out AConfirmed: TQRPointF): Boolean;
  var
    StateCountTotal: Integer;
    CenterJ, CenterI, EstimatedModuleSize: Single;
    K: Integer;
    Combined: TAlignCandidate;
    NewCand: TAlignCandidate;
  begin
    StateCountTotal := ASC[0] + ASC[1] + ASC[2];
    CenterJ := CenterFromEnd(ASC, AJ);
    CenterI := CrossCheckVertical(AI, Trunc(CenterJ), 2 * ASC[1], StateCountTotal);
    if IsNan(CenterI) then
      Exit(False);

    EstimatedModuleSize := StateCountTotal / 3.0;
    for K := 0 to NumCandidates - 1 do
      if AboutEquals(Candidates[K], EstimatedModuleSize, CenterI, CenterJ) then
      begin
        Combined := CombineEstimate(Candidates[K], CenterI, CenterJ, EstimatedModuleSize);
        AConfirmed.X := Combined.X;
        AConfirmed.Y := Combined.Y;
        Exit(True);
      end;

    NewCand.X := CenterJ;
    NewCand.Y := CenterI;
    NewCand.ModuleSize := EstimatedModuleSize;
    NewCand.Count := 1;
    if NumCandidates >= Length(Candidates) then
      SetLength(Candidates, Length(Candidates) + 8);
    Candidates[NumCandidates] := NewCand;
    Inc(NumCandidates);
    Result := False;
  end;

var
  IGen, I, J, CurrentState: Integer;
  ConfirmedPt: TQRPointF;
begin
  MaxJ := AStartX + AWidth;
  if MaxJ > AImgWidth then MaxJ := AImgWidth;
  if AStartX < 0 then AStartX := 0;
  if AStartY < 0 then AStartY := 0;
  MiddleI := AStartY + (AHeight div 2);

  SetLength(Candidates, 8);
  NumCandidates := 0;

  for IGen := 0 to AHeight - 1 do
  begin
    if (IGen and 1) = 0 then
      I := MiddleI + (IGen + 1) div 2
    else
      I := MiddleI - (IGen + 1) div 2;
    if (I < 0) or (I >= AImgHeight) then
      Continue;

    StateCount[0] := 0; StateCount[1] := 0; StateCount[2] := 0;
    J := AStartX;
    while (J < MaxJ) and (not AImage[I, J]) do
      Inc(J);
    CurrentState := 0;
    while J < MaxJ do
    begin
      if AImage[I, J] then
      begin
        if CurrentState = 1 then
          Inc(StateCount[1])
        else
        begin
          if CurrentState = 2 then
          begin
            if FoundPatternCross(StateCount) then
              if HandlePossibleCenter(StateCount, I, J, ConfirmedPt) then
              begin
                AFound := ConfirmedPt;
                Exit(True);
              end;
            StateCount[0] := StateCount[2];
            StateCount[1] := 1;
            StateCount[2] := 0;
            CurrentState := 1;
          end
          else
          begin
            Inc(CurrentState);
            Inc(StateCount[CurrentState]);
          end;
        end;
      end
      else
      begin
        if CurrentState = 1 then
          Inc(CurrentState);
        Inc(StateCount[CurrentState]);
      end;
      Inc(J);
    end;
    if FoundPatternCross(StateCount) then
      if HandlePossibleCenter(StateCount, I, MaxJ, ConfirmedPt) then
      begin
        AFound := ConfirmedPt;
        Exit(True);
      end;
  end;

  if NumCandidates > 0 then
  begin
    AFound.X := Candidates[0].X;
    AFound.Y := Candidates[0].Y;
    Exit(True);
  end;

  Result := False;
end;

end.
