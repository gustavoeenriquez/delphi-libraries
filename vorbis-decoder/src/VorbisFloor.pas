unit VorbisFloor;

{
  VorbisFloor.pas - Vorbis floor curve decode (types 0 and 1)

  Floor type 0: LSP-based spectral envelope (legacy, rare in practice).
  Floor type 1: piecewise linear curve (standard in all Vorbis files).

  Floor 1 decode follows spec sections 7.3.2 (packet decode) and
  7.3.4 (amplitude synthesis/fitting):
    1. Non-zero flag (1 bit) — if 0, silence for this channel
    2. Y[0] and Y[1] for endpoints (X=0 and X=n/2)
    3. Per partition: decode class via master book, then per-dimension via
       subclass books using (cval & csub) indexing
    4. Amplitude fitting: for each sorted interior point, compute the
       predicted value from its low/high neighbors, then decode the delta
    5. Curve rendering: Bresenham-style step function between points

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

// Decode a floor 1 curve.
// Returns True when non-zero (active floor), False for unused/silence.
// Output must be pre-allocated with at least BlockSize elements.
function VorbisDecodeFloor1(
  const F   : TVorbisFloor1;
  const CBs : TArray<TVorbisCodebook>;
  var Br    : TAudioBitReader;
  BlockSize : Integer;
  Output    : PSingle
): Boolean;

// Decode a floor 0 curve (LSP-based).
function VorbisDecodeFloor0(
  const F        : TVorbisFloor0;
  const CBs      : TArray<TVorbisCodebook>;
  var Br         : TAudioBitReader;
  BlockSize      : Integer;
  SampleRate     : Integer;
  Output         : PSingle
): Boolean;

implementation

// ---------------------------------------------------------------------------
// Floor 1 helpers
// ---------------------------------------------------------------------------

// render_point: spec section 7.3.3
// Bresenham-step value at x between (x0,y0) and (x1,y1)
function RenderPoint(X0, Y0, X1, Y1, X: Integer): Integer; inline;
var
  Dy, Adx, Ady, Err, Off: Integer;
begin
  Dy  := Y1 - Y0;
  Adx := X1 - X0;
  Ady := Abs(Dy);
  if Adx = 0 then Exit(Y0);
  Err := Ady * (X - X0);
  Off := Err div Adx;
  if Dy < 0 then Result := Y0 - Off
  else Result := Y0 + Off;
end;

// Convert Y value to linear amplitude (spec section 7.3.5)
function Floor1ToLin(Y: Integer): Single; inline;
begin
  // floor1_inverse_dB_table equivalent:
  // amplitude = 2^(val * 0.21875 - 34.375) ... but the table is only for val in [0..255]
  // For val=0: amplitude = 0 (silence)
  if Y <= 0 then Exit(0.0);
  Result := Power(2.0, Y * 0.21875 - 34.375);
end;

// render_line: spec section 7.3.5
// Fills Output[X0..X1-1] using Bresenham stepping, converting Y to linear.
procedure RenderLine(X0, Y0, X1, Y1, BlockSize: Integer; Output: PSingle);
var
  Dy, Adx, Ady, Err, Off, X, Base: Integer;
begin
  if X0 >= BlockSize then Exit;
  Output[X0] := Floor1ToLin(Y0);
  if X0 + 1 >= X1 then Exit;

  Dy  := Y1 - Y0;
  Adx := X1 - X0;
  Ady := Abs(Dy);
  Err := 0;
  Off := 0;
  Base := Y0;

  for X := X0 + 1 to X1 - 1 do
  begin
    if X >= BlockSize then Exit;
    Inc(Err, Ady);
    if Err >= Adx then
    begin
      Dec(Err, Adx);
      if Dy < 0 then Dec(Off) else Inc(Off);
    end;
    Output[X] := Floor1ToLin(Base + Off);
  end;
end;

// ---------------------------------------------------------------------------
// Decode floor type 1
// ---------------------------------------------------------------------------

function VorbisDecodeFloor1(
  const F   : TVorbisFloor1;
  const CBs : TArray<TVorbisCodebook>;
  var Br    : TAudioBitReader;
  BlockSize : Integer;
  Output    : PSingle
): Boolean;
var
  I, J        : Integer;
  NonZero     : Boolean;
  YRaw        : TArray<Integer>;   // decoded raw Y values indexed by XList position
  FinalY      : TArray<Integer>;   // after amplitude fitting
  Step2Flag   : TArray<Boolean>;
  ListIdx     : Integer;
  PartIdx     : Integer;
  ClassIdx    : Integer;
  CVal, CSub  : Integer;
  CBits       : Integer;
  BookIdx     : Integer;
  Sym         : Integer;
  MaxRange    : Integer;
  // For sorted sweep
  SortN       : Integer;
  CurX, CurY  : Integer;
  Predicted   : Integer;
  LoX, HiX    : Integer;
  LoY, HiY    : Integer;
  HiRoom, LoRoom, Room: Integer;
begin
  Result := False;

  // 1. Non-zero flag
  NonZero := BrRead(Br, 1) <> 0;
  if not NonZero then
  begin
    for I := 0 to BlockSize - 1 do Output[I] := 0.0;
    Exit(False); // silence
  end;

  SortN := F.XListCount;
  MaxRange := (F.Multiplier * 65) - 1;  // max Y value (range-1)

  SetLength(YRaw, SortN);
  SetLength(FinalY, SortN);
  SetLength(Step2Flag, SortN);

  // 2. Read Y[0] (X=0) and Y[1] (X=n/2) directly
  YRaw[0] := BrRead(Br, F.RangeBits);
  YRaw[1] := BrRead(Br, F.RangeBits);
  Step2Flag[0] := True;
  Step2Flag[1] := True;

  // 3. Decode partition Y values
  ListIdx := 2;
  for PartIdx := 0 to F.Partitions - 1 do
  begin
    ClassIdx := F.PartitionClassList[PartIdx];
    var Cls  := F.Classes[ClassIdx];
    CBits    := Cls.SubClasses;          // subclass exponent
    CSub     := (1 shl CBits) - 1;       // subclass mask
    CVal     := 0;

    // Read class codeword from master book if subclasses > 0
    if CBits > 0 then
    begin
      CVal := VorbisCodebookDecode(CBs[Cls.MasterBook], Br);
      if CVal < 0 then Exit;
    end;

    // Read each dimension's Y value
    for J := 0 to Cls.Dimensions - 1 do
    begin
      BookIdx := Cls.SubClassBooks[CVal and CSub];
      CVal    := CVal shr CBits;

      if BookIdx >= 0 then
      begin
        Sym := VorbisCodebookDecode(CBs[BookIdx], Br);
        if Sym < 0 then Exit;
        YRaw[ListIdx] := Sym;
        Step2Flag[ListIdx] := True;
      end
      else
      begin
        YRaw[ListIdx] := 0;
        Step2Flag[ListIdx] := True;  // still used, just Y=0
      end;
      Inc(ListIdx);
    end;
  end;

  // 4. Amplitude fitting (spec section 7.3.4)
  // Walk through points in sorted X order.
  // XSorted[I] is the original index into XList/YRaw for the I-th sorted point.

  // Points 0 and 1 in sorted order are X=0 and X=n/2 (always present)
  FinalY[F.XSorted[0]] := YRaw[F.XSorted[0]];
  FinalY[F.XSorted[1]] := YRaw[F.XSorted[1]];

  for I := 2 to SortN - 1 do
  begin
    var Orig := F.XSorted[I];
    CurX := F.XList[Orig];

    // Find low neighbor: largest sorted X < CurX among already-processed
    LoX := 0; LoY := FinalY[F.XSorted[0]];
    HiX := F.XList[F.XSorted[1]]; HiY := FinalY[F.XSorted[1]];
    for J := 0 to I - 1 do
    begin
      var Px := F.XList[F.XSorted[J]];
      if Px < CurX then
      begin
        if Px > LoX then begin LoX := Px; LoY := FinalY[F.XSorted[J]]; end;
      end
      else if Px > CurX then
      begin
        if Px < HiX then begin HiX := Px; HiY := FinalY[F.XSorted[J]]; end;
      end;
    end;

    Predicted := RenderPoint(LoX, LoY, HiX, HiY, CurX);

    HiRoom := MaxRange - Predicted;
    LoRoom := Predicted;
    if HiRoom < LoRoom then Room := HiRoom * 2
    else Room := LoRoom * 2;

    var RawVal := YRaw[Orig];
    if RawVal = 0 then
    begin
      Step2Flag[Orig] := False;
      FinalY[Orig] := Predicted;
    end
    else
    begin
      Step2Flag[Orig] := True;
      // Mark neighbors as used too
      if RawVal >= Room then
      begin
        if HiRoom > LoRoom then
          FinalY[Orig] := RawVal - LoRoom + Predicted
        else
          FinalY[Orig] := Predicted - RawVal + HiRoom - 1;
      end
      else
      begin
        if (RawVal and 1) <> 0 then
          FinalY[Orig] := Predicted - (RawVal + 1) div 2
        else
          FinalY[Orig] := Predicted + RawVal div 2;
      end;
    end;

    // Clamp to valid range
    if FinalY[Orig] < 0      then FinalY[Orig] := 0;
    if FinalY[Orig] > MaxRange then FinalY[Orig] := MaxRange;
  end;

  // 5. Render piecewise linear curve (spec section 7.3.5)
  for I := 0 to BlockSize - 1 do Output[I] := 0.0;

  // Walk sorted X list; render each active segment
  for I := 0 to SortN - 2 do
  begin
    var IdxA := F.XSorted[I];
    var IdxB := F.XSorted[I + 1];
    if Step2Flag[IdxA] and Step2Flag[IdxB] then
      RenderLine(F.XList[IdxA], FinalY[IdxA],
                 F.XList[IdxB], FinalY[IdxB], BlockSize, Output);
  end;

  // Last point: extend to end of spectrum
  var LastIdx := F.XSorted[SortN - 1];
  if Step2Flag[LastIdx] then
  begin
    var Lx := F.XList[LastIdx];
    var Ly := FinalY[LastIdx];
    for I := Lx to BlockSize - 1 do
      Output[I] := Floor1ToLin(Ly);
  end;

  Result := True;
end;

// ---------------------------------------------------------------------------
// Floor type 0 decode (LSP-based)
// ---------------------------------------------------------------------------

function VorbisDecodeFloor0(
  const F        : TVorbisFloor0;
  const CBs      : TArray<TVorbisCodebook>;
  var Br         : TAudioBitReader;
  BlockSize      : Integer;
  SampleRate     : Integer;
  Output         : PSingle
): Boolean;
var
  Amplitude  : Integer;
  BookIdx    : Integer;
  CBook      : Integer;
  Vec        : TArray<Single>;
  Coeff      : TArray<Single>;
  CoeffCount : Integer;
  I          : Integer;
begin
  Result := False;

  Amplitude := BrRead(Br, F.AmplitudeBits);
  if Amplitude = 0 then
  begin
    for I := 0 to BlockSize - 1 do Output[I] := 0.0;
    Exit(False);
  end;

  BookIdx := BrRead(Br, VorbisILog(F.NumberOfBooks));
  if (BookIdx >= F.NumberOfBooks) or (BookIdx < 0) then Exit;

  CBook := F.BookList[BookIdx];
  SetLength(Vec, CBs[CBook].Dimensions);
  SetLength(Coeff, F.Order + 1);
  CoeffCount := 0;

  while CoeffCount < F.Order do
  begin
    if not VorbisCodebookDecodeVQ(CBs[CBook], Br, @Vec[0]) then Exit;
    for I := 0 to CBs[CBook].Dimensions - 1 do
    begin
      if CoeffCount >= F.Order then Break;
      Coeff[CoeffCount] := Vec[I];
      Inc(CoeffCount);
    end;
  end;

  // Evaluate LSP->amplitude at each spectral line using bark mapping
  // Spec section 7.2.4: map spectral line i to bark frequency, then
  // compute LPC response from LSP coefficients
  var AmpScale: Single := Amplitude * (Power(2.0, F.AmplitudeBits) / (Power(2.0, F.AmplitudeBits) - 1));

  for I := 0 to BlockSize - 1 do
  begin
    // Bark-scale map: w = 2*pi * f_center / sample_rate
    var BarkFreq: Single := Pi / BlockSize * I;
    var Omega: Single := BarkFreq;

    // LSP to spectrum evaluation
    var P: Single := 1.0;
    var Q: Single := 1.0;
    var J: Integer := 0;
    while J + 1 < F.Order do
    begin
      P := P * (4.0 * Coeff[J]   * Coeff[J]   - 4.0 * Cos(Omega) * Coeff[J]   + 1.0);
      Q := Q * (4.0 * Coeff[J+1] * Coeff[J+1] - 4.0 * Cos(Omega) * Coeff[J+1] + 1.0);
      Inc(J, 2);
    end;
    if (F.Order and 1) <> 0 then
      P := P * (2.0 * Cos(Omega) - 2.0 * Coeff[F.Order - 1]);

    var LinAmp: Single := AmpScale / Sqrt(P * P + Q * Q);
    Output[I] := LinAmp;
  end;

  Result := True;
end;

end.
