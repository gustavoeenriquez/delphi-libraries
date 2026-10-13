unit VorbisFloor;

{
  VorbisFloor.pas - Vorbis floor type 1 decode (spec section 7.2)

  Two stages, mirroring the specification:
    1. VorbisFloor1Decode   - packet decode (7.2.3) + amplitude value synthesis (7.2.4).
                              Produces FinalY[] and Step2Flag[] in X-list order.
    2. VorbisFloor1Render   - curve synthesis (7.2.4, second half): walks the
                              points in sorted X order, draws Bresenham lines and
                              multiplies the target spectrum by the inverse-dB
                              amplitude (floor1_inverse_dB_table).

  Floor type 0 (LSP) is obsolete; no encoder in practical use emits it and it is
  not supported here (same policy as stb_vorbis). A stream using it is rejected.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  SysUtils, Math,
  AudioTypes,
  AudioBitReader,
  VorbisTypes,
  VorbisCodebook;

const
  {$I VorbisInverseDb.inc}

// Decode the floor 1 data of one channel from the packet.
// Returns False when the floor is "unused" (channel is silent this frame)
// or when the packet ends prematurely (spec: treat as unused).
function VorbisFloor1Decode(
  const F       : TVorbisFloor1;
  var CBs       : TArray<TVorbisCodebook>;
  var Br        : TAudioBitReader;
  var FinalY    : TArray<Integer>;
  var Step2Flag : TArray<Boolean>
): Boolean;

// Multiply Target[0..N2-1] by the rendered floor curve.
procedure VorbisFloor1Render(
  const F       : TVorbisFloor1;
  const FinalY  : TArray<Integer>;
  const Step2Flag: TArray<Boolean>;
  N2            : Integer;
  Target        : PSingle
);

// render_point (spec 9.2.6)
function VorbisRenderPoint(X0, Y0, X1, Y1, X: Integer): Integer;

implementation

function VorbisRenderPoint(X0, Y0, X1, Y1, X: Integer): Integer;
var
  Dy, Adx, Ady, Err, Off: Integer;
begin
  Dy  := Y1 - Y0;
  Adx := X1 - X0;
  Ady := Abs(Dy);
  Err := Ady * (X - X0);
  Off := Err div Adx;
  if Dy < 0 then Result := Y0 - Off
  else           Result := Y0 + Off;
end;

// render_line (spec 9.2.7). Multiplies Target[x] for x in [X0, X1).
procedure RenderLine(X0, Y0, X1, Y1, N: Integer; Target: PSingle);
var
  Dy, Adx, Ady, Base, X, Y, Err, Sy: Integer;
begin
  Dy  := Y1 - Y0;
  Adx := X1 - X0;
  Ady := Abs(Dy);
  Base := Dy div Adx;          // truncates toward zero, as in the spec
  if Dy < 0 then Sy := Base - 1
  else           Sy := Base + 1;
  Ady := Ady - Abs(Base) * Adx;
  if X1 > N then X1 := N;
  X := X0;
  Y := Y0;
  Err := 0;
  if X < X1 then
  begin
    Target[X] := Target[X] * VORBIS_INVERSE_DB_TABLE[Y and 255];
    Inc(X);
    while X < X1 do
    begin
      Inc(Err, Ady);
      if Err >= Adx then
      begin
        Dec(Err, Adx);
        Inc(Y, Sy);
      end
      else
        Inc(Y, Base);
      Target[X] := Target[X] * VORBIS_INVERSE_DB_TABLE[Y and 255];
      Inc(X);
    end;
  end;
end;

function VorbisFloor1Decode(
  const F       : TVorbisFloor1;
  var CBs       : TArray<TVorbisCodebook>;
  var Br        : TAudioBitReader;
  var FinalY    : TArray<Integer>;
  var Step2Flag : TArray<Boolean>
): Boolean;
const
  RangeList: array[0..3] of Integer = (256, 128, 86, 64);
var
  Range, YBits  : Integer;
  Values        : Integer;
  Offset        : Integer;
  J, K          : Integer;
  PClass, CDim  : Integer;
  CBits, CSub   : Integer;
  CVal, Book    : Integer;
  Temp          : Integer;
  Low, High     : Integer;
  Pred, Val     : Integer;
  HighRoom, LowRoom, Room: Integer;
begin
  Result := False;
  Values := F.XListCount;
  if Length(FinalY) < Values then SetLength(FinalY, Values);
  if Length(Step2Flag) < Values then SetLength(Step2Flag, Values);

  if Br.Pos >= Br.Limit then Exit;
  if BrRead(Br, 1) = 0 then Exit;   // floor unused

  Range := RangeList[F.Multiplier - 1];
  YBits := VorbisILog(Range) - 1;
  FinalY[0] := BrRead(Br, YBits);
  FinalY[1] := BrRead(Br, YBits);
  Offset := 2;

  // ---- 7.2.3 packet decode ----
  for J := 0 to F.Partitions - 1 do
  begin
    PClass := F.PartitionClassList[J];
    CDim   := F.Classes[PClass].Dimensions;
    CBits  := F.Classes[PClass].SubClasses;
    CSub   := (1 shl CBits) - 1;
    CVal   := 0;
    if CBits > 0 then
    begin
      CVal := VorbisCodebookDecode(CBs[F.Classes[PClass].MasterBook], Br);
      if CVal < 0 then Exit;
    end;
    for K := 0 to CDim - 1 do
    begin
      Book := F.Classes[PClass].SubClassBooks[CVal and CSub];
      CVal := CVal shr CBits;
      if Book >= 0 then
      begin
        Temp := VorbisCodebookDecode(CBs[Book], Br);
        if Temp < 0 then Exit;
        FinalY[Offset] := Temp;
      end
      else
        FinalY[Offset] := 0;
      Inc(Offset);
    end;
  end;

  // ---- 7.2.4 amplitude value synthesis ----
  Step2Flag[0] := True;
  Step2Flag[1] := True;
  for J := 2 to Values - 1 do
  begin
    Low  := F.LowNeighbor[J];
    High := F.HighNeighbor[J];
    Pred := VorbisRenderPoint(F.XList[Low], FinalY[Low], F.XList[High], FinalY[High], F.XList[J]);
    Val  := FinalY[J];
    HighRoom := Range - Pred;
    LowRoom  := Pred;
    if HighRoom < LowRoom then Room := HighRoom * 2
    else                       Room := LowRoom * 2;
    if Val <> 0 then
    begin
      Step2Flag[Low]  := True;
      Step2Flag[High] := True;
      Step2Flag[J]    := True;
      if Val >= Room then
      begin
        if HighRoom > LowRoom then
          FinalY[J] := Val - LowRoom + Pred
        else
          FinalY[J] := Pred - Val + HighRoom - 1;
      end
      else
      begin
        if (Val and 1) <> 0 then
          FinalY[J] := Pred - ((Val + 1) shr 1)
        else
          FinalY[J] := Pred + (Val shr 1);
      end;
    end
    else
    begin
      Step2Flag[J] := False;
      FinalY[J]    := Pred;
    end;
  end;

  Result := True;
end;

procedure VorbisFloor1Render(
  const F       : TVorbisFloor1;
  const FinalY  : TArray<Integer>;
  const Step2Flag: TArray<Boolean>;
  N2            : Integer;
  Target        : PSingle
);
var
  Q, J      : Integer;
  Lx, Ly    : Integer;
  Hx, Hy    : Integer;
  Amp       : Single;
begin
  Lx := 0;
  Ly := FinalY[0] * F.Multiplier;
  for Q := 1 to F.XListCount - 1 do
  begin
    J := F.XSorted[Q];
    if Step2Flag[J] then
    begin
      Hy := FinalY[J] * F.Multiplier;
      Hx := F.XList[J];
      if Lx <> Hx then
        RenderLine(Lx, Ly, Hx, Hy, N2, Target);
      Lx := Hx;
      Ly := Hy;
    end;
  end;
  if Lx < N2 then
  begin
    Amp := VORBIS_INVERSE_DB_TABLE[Ly and 255];
    for J := Lx to N2 - 1 do
      Target[J] := Target[J] * Amp;
  end;
end;

end.
