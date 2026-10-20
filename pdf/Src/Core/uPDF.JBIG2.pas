unit uPDF.JBIG2;

{ JBIG2 decoder (ITU-T T.88 | ISO/IEC 14492) for the PDF JBIG2Decode filter.
  Pure Pascal, no platform dependencies.  Written from the text of
  Recommendation T.88 (08/2018).

  Supported:
  - MQ arithmetic decoding (Annex E) and the integer decoding procedures
    IAx / IAID (Annex A);
  - generic regions (6.2): templates 0-3 with adaptive pixels, TPGD;
  - generic refinement regions (6.3): templates 0-1, TPGR;
  - symbol dictionaries (6.5) with refinement/aggregate coding and
    bitmap coding context reuse;
  - text regions (6.4): all reference corners, transposition, combination
    operators, symbol instance refinement;
  - intermediate / immediate regions, refinement of the page or of an
    intermediate region, page information with unknown height and stripes;
  - the embedded stream organisation used by PDF (with JBIG2Globals) and the
    sequential / random-access file organisations (Annex D).

  The page bitmap uses the JBIG2 convention (1 = black); the PDF filter
  output is its inverse (1 = white).

  License: CC0 1.0 Universal (public domain). }

interface

uses
  System.SysUtils;

type
  EJBIG2Error = class(Exception);

// PDF JBIG2Decode: the embedded stream (segments without a file header)
// and the optional JBIG2Globals stream.  Returns the first page as packed
// rows, most significant bit first, 1 = black.
function JBIG2DecodeEmbedded(const AData, AGlobals: TBytes;
  out AWidth, AHeight: Integer): TBytes;

// A JBIG2 file (Annex D, sequential or random-access organisation); APage
// is 1-based.  Packed rows, 1 = black.
function JBIG2DecodeFile(const AData: TBytes; APage: Integer;
  out AWidth, AHeight: Integer): TBytes;

implementation

uses
  System.Math, System.Generics.Collections, uPDF.CCITTFax;

{ ===========================================================================
  Bitmaps: one byte per pixel (0 or 1)
  =========================================================================== }

type
  TJBBitmap = record
    W, H: Integer;
    Px:   TBytes;
    function Get(X, Y: Integer): Integer; inline;
    class function Make(AW, AH: Integer; AFill: Byte = 0): TJBBitmap; static;
  end;

function TJBBitmap.Get(X, Y: Integer): Integer;
begin
  if (X < 0) or (Y < 0) or (X >= W) or (Y >= H) then Result := 0
  else Result := Px[Y * W + X];
end;

class function TJBBitmap.Make(AW, AH: Integer; AFill: Byte): TJBBitmap;
begin
  if (AW < 0) or (AH < 0) or (Int64(AW) * AH > 1 shl 30) then
    raise EJBIG2Error.CreateFmt('JBIG2: invalid bitmap size %dx%d', [AW, AH]);
  Result.W := AW;
  Result.H := AH;
  // Result may be the caller's variable: SetLength would keep its pixels
  Result.Px := nil;
  SetLength(Result.Px, AW * AH);
  if (AFill <> 0) and (AW * AH > 0) then
    FillChar(Result.Px[0], AW * AH, AFill);
end;

const
  OP_OR = 0; OP_AND = 1; OP_XOR = 2; OP_XNOR = 3; OP_REPLACE = 4;

// Combines ASrc into ADst with its top left corner at (AX, AY)
procedure Compose(var ADst: TJBBitmap; const ASrc: TJBBitmap;
  AX, AY, AOp: Integer);
var
  X, Y, X0, X1, Y0, Y1, D, S: Integer;
begin
  X0 := Max(0, -AX);  X1 := Min(ASrc.W, ADst.W - AX);
  Y0 := Max(0, -AY);  Y1 := Min(ASrc.H, ADst.H - AY);
  for Y := Y0 to Y1 - 1 do
  begin
    D := (Y + AY) * ADst.W + AX;
    S := Y * ASrc.W;
    for X := X0 to X1 - 1 do
      case AOp of
        OP_OR:   ADst.Px[D + X] := ADst.Px[D + X] or ASrc.Px[S + X];
        OP_AND:  ADst.Px[D + X] := ADst.Px[D + X] and ASrc.Px[S + X];
        OP_XOR:  ADst.Px[D + X] := ADst.Px[D + X] xor ASrc.Px[S + X];
        OP_XNOR: ADst.Px[D + X] := 1 - (ADst.Px[D + X] xor ASrc.Px[S + X]);
      else
        ADst.Px[D + X] := ASrc.Px[S + X];
      end;
  end;
end;

{ ===========================================================================
  MQ arithmetic decoder (Annex E, Figures E.15-E.20)
  =========================================================================== }

const
  // Table E.1: Qe values and probability estimation state machine
  QE_TABLE: array[0..46] of record Qe: Word; NMPS, NLPS, Switch: Byte; end = (
    (Qe: $5601; NMPS:  1; NLPS:  1; Switch: 1),
    (Qe: $3401; NMPS:  2; NLPS:  6; Switch: 0),
    (Qe: $1801; NMPS:  3; NLPS:  9; Switch: 0),
    (Qe: $0AC1; NMPS:  4; NLPS: 12; Switch: 0),
    (Qe: $0521; NMPS:  5; NLPS: 29; Switch: 0),
    (Qe: $0221; NMPS: 38; NLPS: 33; Switch: 0),
    (Qe: $5601; NMPS:  7; NLPS:  6; Switch: 1),
    (Qe: $5401; NMPS:  8; NLPS: 14; Switch: 0),
    (Qe: $4801; NMPS:  9; NLPS: 14; Switch: 0),
    (Qe: $3801; NMPS: 10; NLPS: 14; Switch: 0),
    (Qe: $3001; NMPS: 11; NLPS: 17; Switch: 0),
    (Qe: $2401; NMPS: 12; NLPS: 18; Switch: 0),
    (Qe: $1C01; NMPS: 13; NLPS: 20; Switch: 0),
    (Qe: $1601; NMPS: 29; NLPS: 21; Switch: 0),
    (Qe: $5601; NMPS: 15; NLPS: 14; Switch: 1),
    (Qe: $5401; NMPS: 16; NLPS: 14; Switch: 0),
    (Qe: $5101; NMPS: 17; NLPS: 15; Switch: 0),
    (Qe: $4801; NMPS: 18; NLPS: 16; Switch: 0),
    (Qe: $3801; NMPS: 19; NLPS: 17; Switch: 0),
    (Qe: $3401; NMPS: 20; NLPS: 18; Switch: 0),
    (Qe: $3001; NMPS: 21; NLPS: 19; Switch: 0),
    (Qe: $2801; NMPS: 22; NLPS: 19; Switch: 0),
    (Qe: $2401; NMPS: 23; NLPS: 20; Switch: 0),
    (Qe: $2201; NMPS: 24; NLPS: 21; Switch: 0),
    (Qe: $1C01; NMPS: 25; NLPS: 22; Switch: 0),
    (Qe: $1801; NMPS: 26; NLPS: 23; Switch: 0),
    (Qe: $1601; NMPS: 27; NLPS: 24; Switch: 0),
    (Qe: $1401; NMPS: 28; NLPS: 25; Switch: 0),
    (Qe: $1201; NMPS: 29; NLPS: 26; Switch: 0),
    (Qe: $1101; NMPS: 30; NLPS: 27; Switch: 0),
    (Qe: $0AC1; NMPS: 31; NLPS: 28; Switch: 0),
    (Qe: $09C1; NMPS: 32; NLPS: 29; Switch: 0),
    (Qe: $08A1; NMPS: 33; NLPS: 30; Switch: 0),
    (Qe: $0521; NMPS: 34; NLPS: 31; Switch: 0),
    (Qe: $0441; NMPS: 35; NLPS: 32; Switch: 0),
    (Qe: $02A1; NMPS: 36; NLPS: 33; Switch: 0),
    (Qe: $0221; NMPS: 37; NLPS: 34; Switch: 0),
    (Qe: $0141; NMPS: 38; NLPS: 35; Switch: 0),
    (Qe: $0111; NMPS: 39; NLPS: 36; Switch: 0),
    (Qe: $0085; NMPS: 40; NLPS: 37; Switch: 0),
    (Qe: $0049; NMPS: 41; NLPS: 38; Switch: 0),
    (Qe: $0025; NMPS: 42; NLPS: 39; Switch: 0),
    (Qe: $0015; NMPS: 43; NLPS: 40; Switch: 0),
    (Qe: $0009; NMPS: 44; NLPS: 41; Switch: 0),
    (Qe: $0005; NMPS: 45; NLPS: 42; Switch: 0),
    (Qe: $0001; NMPS: 45; NLPS: 43; Switch: 0),
    (Qe: $5601; NMPS: 46; NLPS: 46; Switch: 0));

type
  // A context: bits 0-6 = index I(CX) into Table E.1, bit 7 = MPS(CX)
  TMQDecoder = record
    Data:   TBytes;
    Pos:    Integer;   // last byte read (BP)
    EndPos: Integer;   // one past the last byte of the coded data
    C, A:   Cardinal;
    CT:     Integer;
    procedure Init(const AData: TBytes; AStart, AEnd: Integer);
    function ByteAt(I: Integer): Integer; inline;
    procedure ByteIn;
    function Decode(var Cx: Byte): Integer;
  end;

function TMQDecoder.ByteAt(I: Integer): Integer;
begin
  // past the end the data reads as a marker (0xFF 0xFF...)
  if I < EndPos then Result := Data[I] else Result := $FF;
end;

procedure TMQDecoder.Init(const AData: TBytes; AStart, AEnd: Integer);
begin
  Data   := AData;
  EndPos := Min(AEnd, Length(AData));
  Pos    := AStart;                       // INITDEC (Figure E.20)
  C      := Cardinal(ByteAt(Pos)) shl 16;
  ByteIn;
  C  := C shl 7;
  Dec(CT, 7);
  A  := $8000;
end;

procedure TMQDecoder.ByteIn;
begin
  // BYTEIN (Figure E.19)
  if ByteAt(Pos) = $FF then
  begin
    if ByteAt(Pos + 1) > $8F then
    begin
      C  := C + $FF00;     // marker: feed 1 bits
      CT := 8;
    end
    else
    begin
      Inc(Pos);
      C  := C + Cardinal(ByteAt(Pos)) shl 9;
      CT := 7;
    end;
  end
  else
  begin
    Inc(Pos);
    C  := C + Cardinal(ByteAt(Pos)) shl 8;
    CT := 8;
  end;
end;

function TMQDecoder.Decode(var Cx: Byte): Integer;
var
  I, MPS: Integer;
  Qe: Cardinal;
begin
  // DECODE (Figure E.15) with MPS_EXCHANGE / LPS_EXCHANGE (E.16, E.17)
  I   := Cx and $7F;
  MPS := Cx shr 7;
  Qe  := QE_TABLE[I].Qe;
  A   := A - Qe;
  if (C shr 16) < Qe then
  begin
    if A < Qe then
    begin
      Result := MPS;
      I := QE_TABLE[I].NMPS;
    end
    else
    begin
      Result := 1 - MPS;
      if QE_TABLE[I].Switch = 1 then MPS := 1 - MPS;
      I := QE_TABLE[I].NLPS;
    end;
    A := Qe;
  end
  else
  begin
    C := C - Qe shl 16;
    if (A and $8000) <> 0 then
      Exit(MPS);
    if A < Qe then
    begin
      Result := 1 - MPS;
      if QE_TABLE[I].Switch = 1 then MPS := 1 - MPS;
      I := QE_TABLE[I].NLPS;
    end
    else
    begin
      Result := MPS;
      I := QE_TABLE[I].NMPS;
    end;
  end;
  Cx := Byte(I or (MPS shl 7));
  // RENORMD (Figure E.18)
  repeat
    if CT = 0 then ByteIn;
    A := A shl 1;
    C := C shl 1;
    Dec(CT);
  until (A and $8000) <> 0;
end;

{ ===========================================================================
  Integer arithmetic decoding procedures (Annex A)
  =========================================================================== }

type
  TIACtx = array[0..511] of Byte;

// A.2: the value, or False for OOB
function DecodeInt(var D: TMQDecoder; var Ctx: TIACtx; out V: Integer): Boolean;
var
  Prev, S, N, I: Integer;
  Off, Val: Int64;

  function Bit: Integer;
  begin
    Result := D.Decode(Ctx[Prev]);
    if Prev < 256 then Prev := (Prev shl 1) or Result
    else Prev := (((Prev shl 1) or Result) and 511) or 256;
  end;

begin
  Prev := 1;
  S := Bit;
  if Bit = 0 then begin N := 2; Off := 0; end
  else if Bit = 0 then begin N := 4; Off := 4; end
  else if Bit = 0 then begin N := 6; Off := 20; end
  else if Bit = 0 then begin N := 8; Off := 84; end
  else if Bit = 0 then begin N := 12; Off := 340; end
  else begin N := 32; Off := 4436; end;
  Val := 0;
  for I := 1 to N do
    Val := (Val shl 1) or Bit;
  Val := Val + Off;
  if S = 1 then
  begin
    if Val = 0 then Exit(False);   // -0 = OOB
    Val := -Val;
  end;
  V := Integer(EnsureRange(Val, Low(Integer), High(Integer)));
  Result := True;
end;

// A.2 for values that must not be OOB
function DecodeIntV(var D: TMQDecoder; var Ctx: TIACtx): Integer;
begin
  if not DecodeInt(D, Ctx, Result) then
    raise EJBIG2Error.Create('JBIG2: unexpected OOB');
end;

// A.3: IAID with SBSYMCODELEN = ALen bits; Ctx has 2^(ALen+1) entries
function DecodeIAID(var D: TMQDecoder; var Ctx: TBytes; ALen: Integer): Integer;
var
  Prev, I: Integer;
begin
  Prev := 1;
  for I := 1 to ALen do
    Prev := (Prev shl 1) or D.Decode(Ctx[Prev]);
  Result := Prev - (1 shl ALen);
end;

{ ===========================================================================
  Generic region decoding procedure (6.2), arithmetic variant
  =========================================================================== }

type
  TATPixels = array[0..11] of record X, Y: Integer; end;   // A1..A12

const
  // Contexts of the SLTP bit (Figures 8-11) in the gathering order below
  SLTP_CX: array[0..4] of Integer = ($9B25, $0795, $00E5, $0195, $9B25);

// Generic region decoding with a template and arithmetic coding (6.2.5).
// The CONTEXT gathering order (free per 6.2.5.7) is, from bit 0 up: the
// current row right to left, then the AT pixel(s), the row above right to
// left, and the row two above; template 0 interleaves A2, A3 and A4 as
// shown.  ATemplate 4 is template 0 with EXTTEMPLATE (Figure 3(b)): four
// fixed pixels and A1..A12; it covers the same 16 cells as template 0, so
// its SLTP context (Figure 8) has the same value.  ASkip: optional bitmap
// of pixels forced to 0 (USESKIP).
function DecodeGenericArith(var D: TMQDecoder; var Cx: TBytes;
  AW, AH, ATemplate: Integer; ATPGDON: Boolean; const AT: TATPixels;
  const ASkip: TJBBitmap; AUseSkip: Boolean): TJBBitmap;
const
  M = 4;   // margin columns on each side of the padded rows
var
  PW, X, Y, R0, R1, R2, Ctx, LTP: Integer;
  B: TBytes;

  function ATPix(N, AX, AY: Integer): Integer;
  var
    PX, PY: Integer;
  begin
    PX := AX + AT[N].X;
    PY := AY + AT[N].Y;
    if (PX < 0) or (PX >= AW) or (PY < 0) then Result := 0
    else Result := B[(PY + 2) * PW + PX + M];
  end;

begin
  Result := TJBBitmap.Make(AW, AH);
  if (AW = 0) or (AH = 0) then Exit;
  // padded working copy: 2 zero rows on top, M zero columns on each side
  PW := AW + 2 * M;
  SetLength(B, (AH + 2) * PW);
  LTP := 0;
  for Y := 0 to AH - 1 do
  begin
    R0 := (Y + 2) * PW + M;
    R1 := R0 - PW;
    R2 := R1 - PW;
    if ATPGDON then
    begin
      LTP := LTP xor D.Decode(Cx[SLTP_CX[ATemplate]]);
      if LTP = 1 then
      begin
        Move(B[R1], B[R0], AW);
        Continue;
      end;
    end;
    for X := 0 to AW - 1 do
    begin
      if AUseSkip and (ASkip.Px[Y * AW + X] <> 0) then
        Continue;
      case ATemplate of
        0: Ctx := B[R0 + X - 1] or (B[R0 + X - 2] shl 1) or (B[R0 + X - 3] shl 2) or
             (B[R0 + X - 4] shl 3) or (ATPix(0, X, Y) shl 4) or
             (B[R1 + X + 2] shl 5) or (B[R1 + X + 1] shl 6) or (B[R1 + X] shl 7) or
             (B[R1 + X - 1] shl 8) or (B[R1 + X - 2] shl 9) or
             (ATPix(1, X, Y) shl 10) or (ATPix(2, X, Y) shl 11) or
             (B[R2 + X + 1] shl 12) or (B[R2 + X] shl 13) or (B[R2 + X - 1] shl 14) or
             (ATPix(3, X, Y) shl 15);
        1: Ctx := B[R0 + X - 1] or (B[R0 + X - 2] shl 1) or (B[R0 + X - 3] shl 2) or
             (ATPix(0, X, Y) shl 3) or
             (B[R1 + X + 2] shl 4) or (B[R1 + X + 1] shl 5) or (B[R1 + X] shl 6) or
             (B[R1 + X - 1] shl 7) or (B[R1 + X - 2] shl 8) or
             (B[R2 + X + 2] shl 9) or (B[R2 + X + 1] shl 10) or (B[R2 + X] shl 11) or
             (B[R2 + X - 1] shl 12);
        2: Ctx := B[R0 + X - 1] or (B[R0 + X - 2] shl 1) or (ATPix(0, X, Y) shl 2) or
             (B[R1 + X + 1] shl 3) or (B[R1 + X] shl 4) or (B[R1 + X - 1] shl 5) or
             (B[R1 + X - 2] shl 6) or
             (B[R2 + X + 1] shl 7) or (B[R2 + X] shl 8) or (B[R2 + X - 1] shl 9);
        3: Ctx := B[R0 + X - 1] or (B[R0 + X - 2] shl 1) or (B[R0 + X - 3] shl 2) or
             (B[R0 + X - 4] shl 3) or (ATPix(0, X, Y) shl 4) or
             (B[R1 + X + 1] shl 5) or (B[R1 + X] shl 6) or (B[R1 + X - 1] shl 7) or
             (B[R1 + X - 2] shl 8) or (B[R1 + X - 3] shl 9);
      else
        Ctx := B[R0 + X - 1] or (ATPix(0, X, Y) shl 1) or (ATPix(6, X, Y) shl 2) or
             (ATPix(7, X, Y) shl 3) or (ATPix(9, X, Y) shl 4) or (ATPix(5, X, Y) shl 5) or
             (B[R1 + X + 1] shl 6) or (B[R1 + X] shl 7) or (B[R1 + X - 1] shl 8) or
             (ATPix(2, X, Y) shl 9) or (ATPix(11, X, Y) shl 10) or (ATPix(8, X, Y) shl 11) or
             (ATPix(4, X, Y) shl 12) or (ATPix(1, X, Y) shl 13) or (ATPix(3, X, Y) shl 14) or
             (ATPix(10, X, Y) shl 15);
      end;
      B[R0 + X] := D.Decode(Cx[Ctx]);
    end;
  end;
  for Y := 0 to AH - 1 do
    Move(B[(Y + 2) * PW + M], Result.Px[Y * AW], AW);
end;

{ ===========================================================================
  Generic refinement region decoding procedure (6.3)
  =========================================================================== }

type
  TRefATPixels = array[0..1] of record X, Y: Integer; end;

// CONTEXT gathering order, from bit 0 up.  Template 0 (Figure 12):
// (x-1,y) (x+1,y-1) (x,y-1) RA1, then the reference 3x3 from the bottom
// right to the top middle, and RA2.  Template 1 (Figure 13): (x-1,y)
// (x+1,y-1) (x,y-1) (x-1,y-1), reference (1,1) (0,1) (1,0) (0,0) (-1,0)
// (0,-1).  The SLTP contexts (Figures 14, 15) have only the reference
// pixel at the centre set: bit 8 and bit 7 respectively.
function DecodeRefinement(var D: TMQDecoder; var Cx: TBytes;
  AW, AH, ATemplate: Integer; const ARef: TJBBitmap; ADX, ADY: Integer;
  ATPGRON: Boolean; const AT: TRefATPixels): TJBBitmap;
var
  X, Y, RX, RY, Ctx, LTP, V: Integer;
  Result_: TJBBitmap;

  function Cur(PX, PY: Integer): Integer;
  begin
    if (PX < 0) or (PX >= AW) or (PY < 0) then Result := 0
    else Result := Result_.Px[PY * AW + PX];
  end;

  function Ref(PX, PY: Integer): Integer;
  begin
    Result := ARef.Get(PX, PY);
  end;

  function Context: Integer;
  begin
    if ATemplate = 0 then
      Result := Cur(X - 1, Y) or (Cur(X + 1, Y - 1) shl 1) or (Cur(X, Y - 1) shl 2) or
        (Cur(X + AT[0].X, Y + AT[0].Y) shl 3) or
        (Ref(RX + 1, RY + 1) shl 4) or (Ref(RX, RY + 1) shl 5) or (Ref(RX - 1, RY + 1) shl 6) or
        (Ref(RX + 1, RY) shl 7) or (Ref(RX, RY) shl 8) or (Ref(RX - 1, RY) shl 9) or
        (Ref(RX + 1, RY - 1) shl 10) or (Ref(RX, RY - 1) shl 11) or
        (Ref(RX + AT[1].X, RY + AT[1].Y) shl 12)
    else
      Result := Cur(X - 1, Y) or (Cur(X + 1, Y - 1) shl 1) or (Cur(X, Y - 1) shl 2) or
        (Cur(X - 1, Y - 1) shl 3) or
        (Ref(RX + 1, RY + 1) shl 4) or (Ref(RX, RY + 1) shl 5) or (Ref(RX + 1, RY) shl 6) or
        (Ref(RX, RY) shl 7) or (Ref(RX - 1, RY) shl 8) or (Ref(RX, RY - 1) shl 9);
  end;

  // TPGR (Figure 16): the 3x3 reference neighbourhood has a single value
  function Typical(out AValue: Integer): Boolean;
  var
    I, J: Integer;
  begin
    AValue := Ref(RX, RY);
    for J := -1 to 1 do
      for I := -1 to 1 do
        if Ref(RX + I, RY + J) <> AValue then Exit(False);
    Result := True;
  end;

begin
  Result_ := TJBBitmap.Make(AW, AH);
  LTP := 0;
  for Y := 0 to AH - 1 do
  begin
    if ATPGRON then
    begin
      if ATemplate = 0 then LTP := LTP xor D.Decode(Cx[$100])
      else LTP := LTP xor D.Decode(Cx[$80]);
    end;
    RY := Y - ADY;
    for X := 0 to AW - 1 do
    begin
      RX := X - ADX;
      if (LTP = 1) and Typical(V) then
        Result_.Px[Y * AW + X] := V
      else
      begin
        Ctx := Context;
        Result_.Px[Y * AW + X] := D.Decode(Cx[Ctx]);
      end;
    end;
  end;
  Result := Result_;
end;

{ ===========================================================================
  Bit reader and Huffman tables (Annex B)
  =========================================================================== }

type
  // Most significant bit first (5.4.1)
  TBitReader = record
    Data:   TBytes;
    Pos:    Integer;   // byte
    Bit:    Integer;   // bits already used in Data[Pos] (0..7)
    EndPos: Integer;
    procedure Init(const AData: TBytes; AStart, AEnd: Integer);
    function ReadBit: Integer;
    function ReadBits(N: Integer): Cardinal;
    procedure Align;   // skip the rest of the current byte
  end;

  THuffKind = (hlNormal, hlLower, hlUpper, hlOOB);
  THuffLine = record
    PrefLen, RangeLen: Integer;
    RangeLow: Integer;
    Kind: THuffKind;
  end;

  // A code table: its lines and, per prefix length, the line indexes in
  // code order (B.3 assigns consecutive codes to the lines of each length)
  THuffTable = record
    Lines:    TArray<THuffLine>;
    First:    TArray<Int64>;              // first code of each length
    ByLen:    TArray<TArray<Integer>>;    // line indexes of each length
    procedure Build;
    function Valid: Boolean;
  end;

procedure TBitReader.Init(const AData: TBytes; AStart, AEnd: Integer);
begin
  Data   := AData;
  Pos    := AStart;
  Bit    := 0;
  EndPos := Min(AEnd, Length(AData));
end;

function TBitReader.ReadBit: Integer;
begin
  if Pos >= EndPos then raise EJBIG2Error.Create('JBIG2: unexpected end of Huffman data');
  Result := (Data[Pos] shr (7 - Bit)) and 1;
  Inc(Bit);
  if Bit = 8 then
  begin
    Bit := 0;
    Inc(Pos);
  end;
end;

function TBitReader.ReadBits(N: Integer): Cardinal;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to N do
    Result := (Result shl 1) or Cardinal(ReadBit);
end;

procedure TBitReader.Align;
begin
  if Bit <> 0 then
  begin
    Bit := 0;
    Inc(Pos);
  end;
end;

// B.3: prefix codes from the prefix lengths
procedure THuffTable.Build;
var
  Count: TArray<Integer>;
  I, MaxLen, L: Integer;
begin
  MaxLen := 0;
  for I := 0 to High(Lines) do
  begin
    if (Lines[I].PrefLen < 0) or (Lines[I].PrefLen > 32) then
      raise EJBIG2Error.Create('JBIG2: invalid Huffman prefix length');
    MaxLen := Max(MaxLen, Lines[I].PrefLen);
  end;
  SetLength(Count, MaxLen + 1);
  SetLength(First, MaxLen + 1);
  SetLength(ByLen, MaxLen + 1);
  for I := 0 to High(Lines) do
    if Lines[I].PrefLen > 0 then
    begin
      Inc(Count[Lines[I].PrefLen]);
      L := Lines[I].PrefLen;
      ByLen[L] := ByLen[L] + [I];
    end;
  First[0] := 0;
  for L := 1 to MaxLen do
    First[L] := (First[L - 1] + Count[L - 1]) * 2;
end;

function THuffTable.Valid: Boolean;
begin
  Result := Length(Lines) > 0;
end;

// B.4: decodes a value; False for OOB
function HuffDecode(var R: TBitReader; const T: THuffTable; out V: Integer): Boolean;
var
  Code, Val: Int64;
  L, Idx: Integer;
  Line: THuffLine;
begin
  if not T.Valid then raise EJBIG2Error.Create('JBIG2: missing Huffman table');
  Code := 0;
  for L := 1 to High(T.First) do
  begin
    Code := Code * 2 + R.ReadBit;
    Idx := Code - T.First[L];
    if (Idx >= 0) and (Idx < Length(T.ByLen[L])) then
    begin
      Line := T.Lines[T.ByLen[L][Idx]];
      if Line.Kind = hlOOB then Exit(False);
      Val := R.ReadBits(Line.RangeLen);
      if Line.Kind = hlLower then Val := Int64(Line.RangeLow) - Val
      else Val := Int64(Line.RangeLow) + Val;
      V := Integer(EnsureRange(Val, Low(Integer), High(Integer)));
      Exit(True);
    end;
  end;
  raise EJBIG2Error.Create('JBIG2: invalid Huffman code');
end;

function HuffDecodeV(var R: TBitReader; const T: THuffTable): Integer;
begin
  if not HuffDecode(R, T, Result) then
    raise EJBIG2Error.Create('JBIG2: unexpected OOB');
end;

const
  // Standard Huffman tables B.1-B.15 (generated by Tests/tools/gen_jbig2_huffman.py):
  // PREFLEN, RANGELEN, RANGELOW, kind; lines in the order of B.2
  STD_LINES: array[0..183] of THuffLine = (
    (PrefLen:  1; RangeLen:  4; RangeLow:       0; Kind: hlNormal),   // B.1
    (PrefLen:  2; RangeLen:  8; RangeLow:      16; Kind: hlNormal),
    (PrefLen:  3; RangeLen: 16; RangeLow:     272; Kind: hlNormal),
    (PrefLen:  3; RangeLen: 32; RangeLow:   65808; Kind: hlUpper),
    (PrefLen:  1; RangeLen:  0; RangeLow:       0; Kind: hlNormal),   // B.2
    (PrefLen:  2; RangeLen:  0; RangeLow:       1; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  0; RangeLow:       2; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  3; RangeLow:       3; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  6; RangeLow:      11; Kind: hlNormal),
    (PrefLen:  6; RangeLen: 32; RangeLow:      75; Kind: hlUpper),
    (PrefLen:  6; RangeLen:  0; RangeLow:       0; Kind: hlOOB),
    (PrefLen:  8; RangeLen:  8; RangeLow:    -256; Kind: hlNormal),   // B.3
    (PrefLen:  1; RangeLen:  0; RangeLow:       0; Kind: hlNormal),
    (PrefLen:  2; RangeLen:  0; RangeLow:       1; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  0; RangeLow:       2; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  3; RangeLow:       3; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  6; RangeLow:      11; Kind: hlNormal),
    (PrefLen:  8; RangeLen: 32; RangeLow:    -257; Kind: hlLower),
    (PrefLen:  7; RangeLen: 32; RangeLow:      75; Kind: hlUpper),
    (PrefLen:  6; RangeLen:  0; RangeLow:       0; Kind: hlOOB),
    (PrefLen:  1; RangeLen:  0; RangeLow:       1; Kind: hlNormal),   // B.4
    (PrefLen:  2; RangeLen:  0; RangeLow:       2; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  0; RangeLow:       3; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  3; RangeLow:       4; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  6; RangeLow:      12; Kind: hlNormal),
    (PrefLen:  5; RangeLen: 32; RangeLow:      76; Kind: hlUpper),
    (PrefLen:  7; RangeLen:  8; RangeLow:    -255; Kind: hlNormal),   // B.5
    (PrefLen:  1; RangeLen:  0; RangeLow:       1; Kind: hlNormal),
    (PrefLen:  2; RangeLen:  0; RangeLow:       2; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  0; RangeLow:       3; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  3; RangeLow:       4; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  6; RangeLow:      12; Kind: hlNormal),
    (PrefLen:  7; RangeLen: 32; RangeLow:    -256; Kind: hlLower),
    (PrefLen:  6; RangeLen: 32; RangeLow:      76; Kind: hlUpper),
    (PrefLen:  5; RangeLen: 10; RangeLow:   -2048; Kind: hlNormal),   // B.6
    (PrefLen:  4; RangeLen:  9; RangeLow:   -1024; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  8; RangeLow:    -512; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  7; RangeLow:    -256; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  6; RangeLow:    -128; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  5; RangeLow:     -64; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  5; RangeLow:     -32; Kind: hlNormal),
    (PrefLen:  2; RangeLen:  7; RangeLow:       0; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  7; RangeLow:     128; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  8; RangeLow:     256; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  9; RangeLow:     512; Kind: hlNormal),
    (PrefLen:  4; RangeLen: 10; RangeLow:    1024; Kind: hlNormal),
    (PrefLen:  6; RangeLen: 32; RangeLow:   -2049; Kind: hlLower),
    (PrefLen:  6; RangeLen: 32; RangeLow:    2048; Kind: hlUpper),
    (PrefLen:  4; RangeLen:  9; RangeLow:   -1024; Kind: hlNormal),   // B.7
    (PrefLen:  3; RangeLen:  8; RangeLow:    -512; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  7; RangeLow:    -256; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  6; RangeLow:    -128; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  5; RangeLow:     -64; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  5; RangeLow:     -32; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  5; RangeLow:       0; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  5; RangeLow:      32; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  6; RangeLow:      64; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  7; RangeLow:     128; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  8; RangeLow:     256; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  9; RangeLow:     512; Kind: hlNormal),
    (PrefLen:  3; RangeLen: 10; RangeLow:    1024; Kind: hlNormal),
    (PrefLen:  5; RangeLen: 32; RangeLow:   -1025; Kind: hlLower),
    (PrefLen:  5; RangeLen: 32; RangeLow:    2048; Kind: hlUpper),
    (PrefLen:  8; RangeLen:  3; RangeLow:     -15; Kind: hlNormal),   // B.8
    (PrefLen:  9; RangeLen:  1; RangeLow:      -7; Kind: hlNormal),
    (PrefLen:  8; RangeLen:  1; RangeLow:      -5; Kind: hlNormal),
    (PrefLen:  9; RangeLen:  0; RangeLow:      -3; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  0; RangeLow:      -2; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  0; RangeLow:      -1; Kind: hlNormal),
    (PrefLen:  2; RangeLen:  1; RangeLow:       0; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  0; RangeLow:       2; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  0; RangeLow:       3; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  4; RangeLow:       4; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  1; RangeLow:      20; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  4; RangeLow:      22; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  5; RangeLow:      38; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  6; RangeLow:      70; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  7; RangeLow:     134; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  7; RangeLow:     262; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  8; RangeLow:     390; Kind: hlNormal),
    (PrefLen:  6; RangeLen: 10; RangeLow:     646; Kind: hlNormal),
    (PrefLen:  9; RangeLen: 32; RangeLow:     -16; Kind: hlLower),
    (PrefLen:  9; RangeLen: 32; RangeLow:    1670; Kind: hlUpper),
    (PrefLen:  2; RangeLen:  0; RangeLow:       0; Kind: hlOOB),
    (PrefLen:  8; RangeLen:  4; RangeLow:     -31; Kind: hlNormal),   // B.9
    (PrefLen:  9; RangeLen:  2; RangeLow:     -15; Kind: hlNormal),
    (PrefLen:  8; RangeLen:  2; RangeLow:     -11; Kind: hlNormal),
    (PrefLen:  9; RangeLen:  1; RangeLow:      -7; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  1; RangeLow:      -5; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  1; RangeLow:      -3; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  1; RangeLow:      -1; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  1; RangeLow:       1; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  1; RangeLow:       3; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  1; RangeLow:       5; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  5; RangeLow:       7; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  2; RangeLow:      39; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  5; RangeLow:      43; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  6; RangeLow:      75; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  7; RangeLow:     139; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  8; RangeLow:     267; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  8; RangeLow:     523; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  9; RangeLow:     779; Kind: hlNormal),
    (PrefLen:  6; RangeLen: 11; RangeLow:    1291; Kind: hlNormal),
    (PrefLen:  9; RangeLen: 32; RangeLow:     -32; Kind: hlLower),
    (PrefLen:  9; RangeLen: 32; RangeLow:    3339; Kind: hlUpper),
    (PrefLen:  2; RangeLen:  0; RangeLow:       0; Kind: hlOOB),
    (PrefLen:  7; RangeLen:  4; RangeLow:     -21; Kind: hlNormal),   // B.10
    (PrefLen:  8; RangeLen:  0; RangeLow:      -5; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  0; RangeLow:      -4; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  0; RangeLow:      -3; Kind: hlNormal),
    (PrefLen:  2; RangeLen:  2; RangeLow:      -2; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  0; RangeLow:       2; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  0; RangeLow:       3; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  0; RangeLow:       4; Kind: hlNormal),
    (PrefLen:  8; RangeLen:  0; RangeLow:       5; Kind: hlNormal),
    (PrefLen:  2; RangeLen:  6; RangeLow:       6; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  5; RangeLow:      70; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  5; RangeLow:     102; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  6; RangeLow:     134; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  7; RangeLow:     198; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  8; RangeLow:     326; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  9; RangeLow:     582; Kind: hlNormal),
    (PrefLen:  6; RangeLen: 10; RangeLow:    1094; Kind: hlNormal),
    (PrefLen:  7; RangeLen: 11; RangeLow:    2118; Kind: hlNormal),
    (PrefLen:  8; RangeLen: 32; RangeLow:     -22; Kind: hlLower),
    (PrefLen:  8; RangeLen: 32; RangeLow:    4166; Kind: hlUpper),
    (PrefLen:  2; RangeLen:  0; RangeLow:       0; Kind: hlOOB),
    (PrefLen:  1; RangeLen:  0; RangeLow:       1; Kind: hlNormal),   // B.11
    (PrefLen:  2; RangeLen:  1; RangeLow:       2; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  0; RangeLow:       4; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  1; RangeLow:       5; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  1; RangeLow:       7; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  2; RangeLow:       9; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  2; RangeLow:      13; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  2; RangeLow:      17; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  3; RangeLow:      21; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  4; RangeLow:      29; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  5; RangeLow:      45; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  6; RangeLow:      77; Kind: hlNormal),
    (PrefLen:  7; RangeLen: 32; RangeLow:     141; Kind: hlUpper),
    (PrefLen:  1; RangeLen:  0; RangeLow:       1; Kind: hlNormal),   // B.12
    (PrefLen:  2; RangeLen:  0; RangeLow:       2; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  1; RangeLow:       3; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  0; RangeLow:       5; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  1; RangeLow:       6; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  1; RangeLow:       8; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  0; RangeLow:      10; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  1; RangeLow:      11; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  2; RangeLow:      13; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  3; RangeLow:      17; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  4; RangeLow:      25; Kind: hlNormal),
    (PrefLen:  8; RangeLen:  5; RangeLow:      41; Kind: hlNormal),
    (PrefLen:  8; RangeLen: 32; RangeLow:      73; Kind: hlUpper),
    (PrefLen:  1; RangeLen:  0; RangeLow:       1; Kind: hlNormal),   // B.13
    (PrefLen:  3; RangeLen:  0; RangeLow:       2; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  0; RangeLow:       3; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  0; RangeLow:       4; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  1; RangeLow:       5; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  3; RangeLow:       7; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  1; RangeLow:      15; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  2; RangeLow:      17; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  3; RangeLow:      21; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  4; RangeLow:      29; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  5; RangeLow:      45; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  6; RangeLow:      77; Kind: hlNormal),
    (PrefLen:  7; RangeLen: 32; RangeLow:     141; Kind: hlUpper),
    (PrefLen:  3; RangeLen:  0; RangeLow:      -2; Kind: hlNormal),   // B.14
    (PrefLen:  3; RangeLen:  0; RangeLow:      -1; Kind: hlNormal),
    (PrefLen:  1; RangeLen:  0; RangeLow:       0; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  0; RangeLow:       1; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  0; RangeLow:       2; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  4; RangeLow:     -24; Kind: hlNormal),   // B.15
    (PrefLen:  6; RangeLen:  2; RangeLow:      -8; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  1; RangeLow:      -4; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  0; RangeLow:      -2; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  0; RangeLow:      -1; Kind: hlNormal),
    (PrefLen:  1; RangeLen:  0; RangeLow:       0; Kind: hlNormal),
    (PrefLen:  3; RangeLen:  0; RangeLow:       1; Kind: hlNormal),
    (PrefLen:  4; RangeLen:  0; RangeLow:       2; Kind: hlNormal),
    (PrefLen:  5; RangeLen:  1; RangeLow:       3; Kind: hlNormal),
    (PrefLen:  6; RangeLen:  2; RangeLow:       5; Kind: hlNormal),
    (PrefLen:  7; RangeLen:  4; RangeLow:       9; Kind: hlNormal),
    (PrefLen:  7; RangeLen: 32; RangeLow:     -25; Kind: hlLower),
    (PrefLen:  7; RangeLen: 32; RangeLow:      25; Kind: hlUpper));
  STD_START: array[1..16] of Integer = (0, 4, 11, 20, 26, 34, 48, 63, 84, 106, 127, 140, 153, 166, 171, 184);

var
  StdTables: array[1..15] of THuffTable;

procedure BuildStdTables;
var
  N, I: Integer;
begin
  for N := 1 to 15 do
  begin
    SetLength(StdTables[N].Lines, STD_START[N + 1] - STD_START[N]);
    for I := STD_START[N] to STD_START[N + 1] - 1 do
      StdTables[N].Lines[I - STD_START[N]] := STD_LINES[I];
    StdTables[N].Build;
  end;
end;

// B.2: a table from a code table segment
function ReadCodeTable(const B: TBytes): THuffTable;
var
  R: TBitReader;
  Flags, HTPS, HTRS, Low_, High_, Cur: Integer;
  OOB: Boolean;
  L: THuffLine;
begin
  if Length(B) < 9 then raise EJBIG2Error.Create('JBIG2: truncated code table');
  Flags := B[0];
  OOB  := (Flags and 1) <> 0;
  HTPS := ((Flags shr 1) and 7) + 1;
  HTRS := ((Flags shr 4) and 7) + 1;
  Low_  := Integer((Cardinal(B[1]) shl 24) or (Cardinal(B[2]) shl 16) or (Cardinal(B[3]) shl 8) or B[4]);
  High_ := Integer((Cardinal(B[5]) shl 24) or (Cardinal(B[6]) shl 16) or (Cardinal(B[7]) shl 8) or B[8]);
  R.Init(B, 9, Length(B));
  Result.Lines := nil;
  Cur := Low_;
  repeat
    L.PrefLen  := R.ReadBits(HTPS);
    L.RangeLen := R.ReadBits(HTRS);
    L.RangeLow := Cur;
    L.Kind     := hlNormal;
    Result.Lines := Result.Lines + [L];
    Cur := Integer(Int64(Cur) + (Int64(1) shl Min(L.RangeLen, 32)));
  until Cur >= High_;
  L.PrefLen := R.ReadBits(HTPS); L.RangeLen := 32; L.RangeLow := Low_ - 1; L.Kind := hlLower;
  Result.Lines := Result.Lines + [L];
  L.PrefLen := R.ReadBits(HTPS); L.RangeLen := 32; L.RangeLow := High_; L.Kind := hlUpper;
  Result.Lines := Result.Lines + [L];
  if OOB then
  begin
    L.PrefLen := R.ReadBits(HTPS); L.RangeLen := 0; L.RangeLow := 0; L.Kind := hlOOB;
    Result.Lines := Result.Lines + [L];
  end;
  Result.Build;
end;

// Prefix code table with only lengths (symbol ID codes, run codes)
function CodeTableFromLengths(const ALens: TArray<Integer>): THuffTable;
var
  I: Integer;
begin
  SetLength(Result.Lines, Length(ALens));
  for I := 0 to High(ALens) do
  begin
    Result.Lines[I].PrefLen  := ALens[I];
    Result.Lines[I].RangeLen := 0;
    Result.Lines[I].RangeLow := I;
    Result.Lines[I].Kind     := hlNormal;
  end;
  Result.Build;
end;

{ ===========================================================================
  Generic region decoding procedure (6.2), MMR variant (6.2.6)
  =========================================================================== }

// MMR bitmap of AW x AH from AData[AStart..AEnd); AConsumed receives the
// bytes used (including an EOFB right after the last row)
function DecodeGenericMMR(const AData: TBytes; AStart, AEnd, AW, AH: Integer;
  out AConsumed: Integer): TJBBitmap;
var
  P: TCCITTFaxParams;
  Bits: TBytes;
  Rows, X, Y, RowBytes: Integer;
begin
  Result := TJBBitmap.Make(AW, AH);
  AConsumed := 0;
  if (AW = 0) or (AH = 0) then Exit;
  P := TCCITTFaxParams.Default;
  P.K := -1;
  P.Columns := AW;
  P.Rows := AH;
  P.BlackIs1 := True;          // black = 1, as in JBIG2
  try
    Bits := CCITTFaxDecode(Copy(AData, AStart, Max(0, AEnd - AStart)), P, Rows, AConsumed);
  except
    on E: ECCITTFaxError do
      raise EJBIG2Error.Create('JBIG2: ' + E.Message);
  end;
  RowBytes := (AW + 7) div 8;
  for Y := 0 to AH - 1 do
    for X := 0 to AW - 1 do
      Result.Px[Y * AW + X] := (Bits[Y * RowBytes + X shr 3] shr (7 - X and 7)) and 1;
end;

{ ===========================================================================
  Text region decoding procedure (6.4)
  =========================================================================== }

type
  // Arithmetic coding statistics of a text region (shared by all the
  // symbols of a symbol dictionary that uses refinement/aggregation)
  TTextContexts = record
    IADT, IAFS, IADS, IAIT, IARI, IARDW, IARDH, IARDX, IARDY: TIACtx;
    IAID: TBytes;
    procedure Reset(ASymCodeLen: Integer);
  end;

  TTextParams = record
    Huff:       Boolean;
    Refine:     Boolean;
    W, H:       Integer;
    NumInst:    Integer;
    Strips:     Integer;
    SymCodeLen: Integer;
    DefPixel:   Integer;
    CombOp:     Integer;
    Transposed: Boolean;
    RefCorner:  Integer;   // 0 BOTTOMLEFT, 1 TOPLEFT, 2 BOTTOMRIGHT, 3 TOPRIGHT
    DSOffset:   Integer;
    RTemplate:  Integer;
    RAT:        TRefATPixels;
    // Huffman variant
    HFS, HDS, HDT, HRDW, HRDH, HRDX, HRDY, HRSIZE: THuffTable;
    SymCodes:   THuffTable;   // SBSYMCODES, prefix codes
    FixedIDs:   Boolean;      // SBSYMCODES are SymCodeLen-bit values (6.5.8.2.3)
  end;

  // Where a text region (or a symbol dictionary) reads its data
  TTextSource = record
    D: TMQDecoder;     // arithmetic variant
    R: TBitReader;     // Huffman variant
  end;

const
  RC_BOTTOMLEFT = 0; RC_TOPLEFT = 1; RC_BOTTOMRIGHT = 2; RC_TOPRIGHT = 3;

procedure TTextContexts.Reset(ASymCodeLen: Integer);
begin
  FillChar(IADT, SizeOf(TIACtx), 0);
  FillChar(IAFS, SizeOf(TIACtx), 0);
  FillChar(IADS, SizeOf(TIACtx), 0);
  FillChar(IAIT, SizeOf(TIACtx), 0);
  FillChar(IARI, SizeOf(TIACtx), 0);
  FillChar(IARDW, SizeOf(TIACtx), 0);
  FillChar(IARDH, SizeOf(TIACtx), 0);
  FillChar(IARDX, SizeOf(TIACtx), 0);
  FillChar(IARDY, SizeOf(TIACtx), 0);
  IAID := nil;
  SetLength(IAID, 1 shl (ASymCodeLen + 1));
end;

// floor(A / 2)
function Half(A: Integer): Integer; inline;
begin
  Result := A div 2;
  if (A < 0) and Odd(A) then Dec(Result);
end;

// Refinement of a symbol instance in the Huffman variant: the bitmap data
// size, then arithmetic-coded data that starts and ends on byte boundaries
function RefineHuffman(var S: TTextSource; var GRCx: TBytes;
  const ASize: THuffTable; AW, AH, ATemplate: Integer; const ARef: TJBBitmap;
  ADX, ADY: Integer; const AT: TRefATPixels): TJBBitmap;
var
  Size, Start: Integer;
begin
  Size := HuffDecodeV(S.R, ASize);
  S.R.Align;
  Start := S.R.Pos;
  if (Size < 0) or (Start + Size > S.R.EndPos) then
    raise EJBIG2Error.Create('JBIG2: invalid refinement data size');
  S.D.Init(S.R.Data, Start, Start + Size);
  Result := DecodeRefinement(S.D, GRCx, AW, AH, ATemplate, ARef, ADX, ADY, False, AT);
  S.R.Pos := Start + Size;
  S.R.Bit := 0;
end;

function DecodeTextRegion(var S: TTextSource; var Ctx: TTextContexts;
  var GRCx: TBytes; const P: TTextParams;
  const ASyms: TArray<TJBBitmap>): TJBBitmap;
var
  StripT, FirstS, NInst, DT, DFS, IDS, CurS, CurT, TI, SI, ID: Integer;
  RI, RDW, RDH, RDX, RDY, X0, Y0, LogStrips: Integer;
  IB: TJBBitmap;
  More: Boolean;
begin
  Result := TJBBitmap.Make(P.W, P.H, P.DefPixel);
  LogStrips := 0;
  while (1 shl LogStrips) < P.Strips do Inc(LogStrips);
  // 6.4.5 step 2): initial STRIPT (6.4.6)
  if P.Huff then StripT := -HuffDecodeV(S.R, P.HDT) * P.Strips
  else StripT := -DecodeIntV(S.D, Ctx.IADT) * P.Strips;
  FirstS := 0;
  NInst  := 0;
  while NInst < P.NumInst do
  begin
    // 6.4.6: strip delta T
    if P.Huff then DT := HuffDecodeV(S.R, P.HDT) * P.Strips
    else DT := DecodeIntV(S.D, Ctx.IADT) * P.Strips;
    Inc(StripT, DT);
    // 6.4.7: first symbol instance S coordinate
    if P.Huff then DFS := HuffDecodeV(S.R, P.HFS)
    else DFS := DecodeIntV(S.D, Ctx.IAFS);
    Inc(FirstS, DFS);
    CurS := FirstS;
    repeat
      // 6.4.9: T coordinate
      if P.Strips = 1 then CurT := 0
      else if P.Huff then CurT := Integer(S.R.ReadBits(LogStrips))
      else CurT := DecodeIntV(S.D, Ctx.IAIT);
      TI := StripT + CurT;
      // 6.4.10: symbol ID
      if not P.Huff then
        ID := DecodeIAID(S.D, Ctx.IAID, P.SymCodeLen)
      else if P.FixedIDs then
        ID := Integer(S.R.ReadBits(P.SymCodeLen))
      else
        ID := HuffDecodeV(S.R, P.SymCodes);
      if (ID < 0) or (ID >= Length(ASyms)) then
        raise EJBIG2Error.Create('JBIG2: symbol ID out of range');
      // 6.4.11: symbol instance bitmap
      if not P.Refine then RI := 0
      else if P.Huff then RI := S.R.ReadBit
      else RI := DecodeIntV(S.D, Ctx.IARI);
      if RI = 0 then
        IB := ASyms[ID]
      else
      begin
        if P.Huff then
        begin
          RDW := HuffDecodeV(S.R, P.HRDW);
          RDH := HuffDecodeV(S.R, P.HRDH);
          RDX := HuffDecodeV(S.R, P.HRDX);
          RDY := HuffDecodeV(S.R, P.HRDY);
          IB := RefineHuffman(S, GRCx, P.HRSIZE, ASyms[ID].W + RDW, ASyms[ID].H + RDH,
            P.RTemplate, ASyms[ID], Half(RDW) + RDX, Half(RDH) + RDY, P.RAT);
        end
        else
        begin
          RDW := DecodeIntV(S.D, Ctx.IARDW);
          RDH := DecodeIntV(S.D, Ctx.IARDH);
          RDX := DecodeIntV(S.D, Ctx.IARDX);
          RDY := DecodeIntV(S.D, Ctx.IARDY);
          // Table 12
          IB := DecodeRefinement(S.D, GRCx, ASyms[ID].W + RDW, ASyms[ID].H + RDH,
            P.RTemplate, ASyms[ID], Half(RDW) + RDX, Half(RDH) + RDY, False, P.RAT);
        end;
      end;
      // vi) CURS before placing
      if not P.Transposed and (P.RefCorner in [RC_TOPRIGHT, RC_BOTTOMRIGHT]) then
        Inc(CurS, IB.W - 1)
      else if P.Transposed and (P.RefCorner in [RC_BOTTOMLEFT, RC_BOTTOMRIGHT]) then
        Inc(CurS, IB.H - 1);
      SI := CurS;
      // viii) location of the reference corner
      if not P.Transposed then
      begin
        X0 := SI; Y0 := TI;
      end
      else
      begin
        X0 := TI; Y0 := SI;
      end;
      if P.RefCorner in [RC_TOPRIGHT, RC_BOTTOMRIGHT] then Dec(X0, IB.W - 1);
      if P.RefCorner in [RC_BOTTOMLEFT, RC_BOTTOMRIGHT] then Dec(Y0, IB.H - 1);
      // x) draw
      Compose(Result, IB, X0, Y0, P.CombOp);
      // xi) CURS after placing
      if not P.Transposed and (P.RefCorner in [RC_TOPLEFT, RC_BOTTOMLEFT]) then
        Inc(CurS, IB.W - 1)
      else if P.Transposed and (P.RefCorner in [RC_TOPLEFT, RC_TOPRIGHT]) then
        Inc(CurS, IB.H - 1);
      Inc(NInst);
      // 6.4.8: next symbol instance S coordinate; OOB ends the strip (it
      // is coded after the last instance too)
      if P.Huff then More := HuffDecode(S.R, P.HDS, IDS)
      else More := DecodeInt(S.D, Ctx.IADS, IDS);
      if not More then Break;
      if NInst >= P.NumInst then
        raise EJBIG2Error.Create('JBIG2: too many symbol instances');
      Inc(CurS, IDS + P.DSOffset);
    until False;
  end;
end;

{ ===========================================================================
  Segments
  =========================================================================== }

type
  TSegment = record
    Number:  Cardinal;
    Typ:     Integer;
    Page:    Cardinal;
    Refs:    TArray<Cardinal>;
    Data:    TBytes;
  end;

  TRegionInfo = record
    W, H, X, Y: Integer;
    Op:         Integer;
  end;

  // What a decoded segment leaves for later segments
  TSegResult = class
    IsDict:      Boolean;             // symbol dictionary segment
    Symbols:     TArray<TJBBitmap>;   // symbol dictionary: exported symbols
    GBCx, GRCx:  TBytes;              // retained bitmap coding contexts
    Region:      TJBBitmap;           // intermediate region
    IsPatterns:  Boolean;             // pattern dictionary segment
    Patterns:    TArray<TJBBitmap>;
    IsTable:     Boolean;             // code table segment
    Table:       THuffTable;
    RegionInfo:  TRegionInfo;
    HasRegion:   Boolean;
  end;

function U32(const B: TBytes; P: Integer): Cardinal; inline;
begin
  if P + 4 > Length(B) then raise EJBIG2Error.Create('JBIG2: truncated data');
  Result := (Cardinal(B[P]) shl 24) or (Cardinal(B[P + 1]) shl 16) or
    (Cardinal(B[P + 2]) shl 8) or B[P + 3];
end;

function U16(const B: TBytes; P: Integer): Integer; inline;
begin
  if P + 2 > Length(B) then raise EJBIG2Error.Create('JBIG2: truncated data');
  Result := (B[P] shl 8) or B[P + 1];
end;

function S8(const B: TBytes; P: Integer): Integer; inline;
begin
  if P >= Length(B) then raise EJBIG2Error.Create('JBIG2: truncated data');
  Result := ShortInt(B[P]);
end;

// Segment header (7.2) at APos; returns False at the end of the data.
// ADataLen receives the data length field (0xFFFFFFFF = unknown).
function ReadSegmentHeader(const B: TBytes; var APos: Integer;
  out ASeg: TSegment; out ADataLen: Cardinal): Boolean;
var
  Flags, Count, I, RefSize: Integer;
begin
  Result := False;
  if APos + 11 > Length(B) then Exit;
  ASeg.Number := U32(B, APos);
  Flags := B[APos + 4];
  ASeg.Typ := Flags and 63;
  Inc(APos, 5);
  Count := B[APos] shr 5;
  if Count = 7 then
  begin
    Count := Integer(U32(B, APos) and $1FFFFFFF);
    Inc(APos, 4 + (Count + 8) div 8);
  end
  else
    Inc(APos);
  if ASeg.Number <= 256 then RefSize := 1
  else if ASeg.Number <= 65536 then RefSize := 2
  else RefSize := 4;
  SetLength(ASeg.Refs, Count);
  for I := 0 to Count - 1 do
  begin
    case RefSize of
      1: begin
           if APos >= Length(B) then raise EJBIG2Error.Create('JBIG2: truncated header');
           ASeg.Refs[I] := B[APos];
         end;
      2: ASeg.Refs[I] := U16(B, APos);
    else
      ASeg.Refs[I] := U32(B, APos);
    end;
    Inc(APos, RefSize);
  end;
  if Flags and 64 <> 0 then
  begin
    ASeg.Page := U32(B, APos);
    Inc(APos, 4);
  end
  else
  begin
    if APos >= Length(B) then raise EJBIG2Error.Create('JBIG2: truncated header');
    ASeg.Page := B[APos];
    Inc(APos);
  end;
  ADataLen := U32(B, APos);
  Inc(APos, 4);
  Result := True;
end;

// Data length of an immediate generic region whose length is unknown
// (7.2.7, 7.4.6.4): up to and including the row count after 0xFF 0xAC
// (arithmetic) or 0x00 0x00 (MMR)
function UnknownGenericLength(const B: TBytes; AStart: Integer): Integer;
var
  MMR: Boolean;
  P: Integer;
begin
  if AStart + 18 > Length(B) then raise EJBIG2Error.Create('JBIG2: truncated data');
  MMR := (B[AStart + 17] and 1) <> 0;
  P := AStart + 18;
  while P + 6 <= Length(B) do
  begin
    if (MMR and (B[P] = 0) and (B[P + 1] = 0)) or
       (not MMR and (B[P] = $FF) and (B[P + 1] = $AC)) then
      Exit(P + 6 - AStart);
    Inc(P);
  end;
  raise EJBIG2Error.Create('JBIG2: end of a generic region of unknown length not found');
end;

// Sequential / embedded organisation: header, data, header, data...
procedure ParseSequential(const B: TBytes; AStart: Integer;
  AList: TList<TSegment>);
var
  P: Integer;
  S: TSegment;
  Len: Cardinal;
begin
  P := AStart;
  while ReadSegmentHeader(B, P, S, Len) do
  begin
    if Len = $FFFFFFFF then
    begin
      if S.Typ <> 38 then raise EJBIG2Error.Create('JBIG2: unknown segment length');
      Len := UnknownGenericLength(B, P);
    end;
    if Int64(P) + Len > Length(B) then
      raise EJBIG2Error.Create('JBIG2: truncated segment');
    S.Data := Copy(B, P, Len);
    Inc(P, Len);
    AList.Add(S);
    if S.Typ = 51 then Break;   // end of file
  end;
end;

// Random-access organisation (D.2): all headers, then all data parts
procedure ParseRandomAccess(const B: TBytes; AStart: Integer;
  AList: TList<TSegment>);
var
  P, I: Integer;
  S: TSegment;
  Len: Cardinal;
  Lens: TList<Cardinal>;
begin
  Lens := TList<Cardinal>.Create;
  try
    P := AStart;
    while ReadSegmentHeader(B, P, S, Len) do
    begin
      if Len = $FFFFFFFF then raise EJBIG2Error.Create('JBIG2: unknown segment length');
      AList.Add(S);
      Lens.Add(Len);
      if S.Typ = 51 then Break;
    end;
    for I := 0 to AList.Count - 1 do
    begin
      if Int64(P) + Lens[I] > Length(B) then
        raise EJBIG2Error.Create('JBIG2: truncated segment');
      S := AList[I];
      S.Data := Copy(B, P, Lens[I]);
      AList[I] := S;
      Inc(P, Lens[I]);
    end;
  finally
    Lens.Free;
  end;
end;

{ ===========================================================================
  Page decoder (clause 8)
  =========================================================================== }

type
  TJBIG2Decoder = class
  private
    FResults:     TObjectDictionary<Cardinal, TSegResult>;
    FPage:        TJBBitmap;
    FHasPage:     Boolean;
    FPageDefPix:  Integer;
    FPageDefOp:   Integer;
    FUnknownH:    Boolean;   // page height 0xFFFFFFFF
    FStripeEnd:   Integer;   // last end-of-stripe row + 1
    FMaxY:        Integer;   // rows touched so far (unknown height)
    FAllSymbols:  TArray<TJBBitmap>;  // exported by every dictionary so far
    function ReadRegionInfo(const B: TBytes): TRegionInfo;
    procedure EnsurePageRows(ARows: Integer);
    procedure PlaceRegion(const ARegion: TJBBitmap; const AInfo: TRegionInfo);
    function ReferredSymbols(const S: TSegment): TArray<TJBBitmap>;
    function ReferredTables(const S: TSegment): TArray<THuffTable>;
    procedure DoPageInfo(const S: TSegment);
    procedure DoSymbolDictionary(const S: TSegment);
    procedure DoTextRegion(const S: TSegment);
    procedure DoPatternDictionary(const S: TSegment);
    procedure DoHalftoneRegion(const S: TSegment);
    procedure DoGenericRegion(const S: TSegment);
    procedure DoRefinementRegion(const S: TSegment);
    procedure DoCodeTable(const S: TSegment);
    procedure StoreRegion(const S: TSegment; const ARegion: TJBBitmap;
      const AInfo: TRegionInfo);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Process(const S: TSegment);
    function PageBits(out AWidth, AHeight: Integer): TBytes;
  end;

constructor TJBIG2Decoder.Create;
begin
  inherited;
  FResults := TObjectDictionary<Cardinal, TSegResult>.Create([doOwnsValues]);
end;

destructor TJBIG2Decoder.Destroy;
begin
  FResults.Free;
  inherited;
end;

function TJBIG2Decoder.ReadRegionInfo(const B: TBytes): TRegionInfo;
begin
  if Length(B) < 17 then raise EJBIG2Error.Create('JBIG2: truncated region header');
  Result.W  := Integer(U32(B, 0));
  Result.H  := Integer(U32(B, 4));
  Result.X  := Integer(U32(B, 8));
  Result.Y  := Integer(U32(B, 12));
  Result.Op := B[16] and 7;
  if (Result.W < 0) or (Result.H < 0) then
    raise EJBIG2Error.Create('JBIG2: invalid region size');
end;

procedure TJBIG2Decoder.EnsurePageRows(ARows: Integer);
var
  Old: TJBBitmap;
begin
  if not FUnknownH or (ARows <= FPage.H) then Exit;
  Old := FPage;
  FPage := TJBBitmap.Make(Old.W, Max(ARows, Old.H * 2), FPageDefPix);
  if Length(Old.Px) > 0 then
    Move(Old.Px[0], FPage.Px[0], Length(Old.Px));
end;

procedure TJBIG2Decoder.PlaceRegion(const ARegion: TJBBitmap;
  const AInfo: TRegionInfo);
begin
  if not FHasPage then raise EJBIG2Error.Create('JBIG2: region before page information');
  EnsurePageRows(AInfo.Y + ARegion.H);
  FMaxY := Max(FMaxY, AInfo.Y + ARegion.H);
  Compose(FPage, ARegion, AInfo.X, AInfo.Y, AInfo.Op);
end;

procedure TJBIG2Decoder.StoreRegion(const S: TSegment; const ARegion: TJBBitmap;
  const AInfo: TRegionInfo);
var
  R: TSegResult;
begin
  // intermediate region segments (types 4, 20, 36, 40) keep their bitmap
  if S.Typ in [4, 20, 36, 40] then
  begin
    R := TSegResult.Create;
    R.Region := ARegion;
    R.RegionInfo := AInfo;
    R.HasRegion := True;
    FResults.AddOrSetValue(S.Number, R);
  end
  else
    PlaceRegion(ARegion, AInfo);
end;

function TJBIG2Decoder.ReferredSymbols(const S: TSegment): TArray<TJBBitmap>;
var
  R: TSegResult;
  Ref: Cardinal;
begin
  Result := nil;
  for Ref in S.Refs do
    if FResults.TryGetValue(Ref, R) and R.IsDict then
      Result := Result + R.Symbols;
end;

// User-supplied Huffman tables: the referred code table segments, in order
function TJBIG2Decoder.ReferredTables(const S: TSegment): TArray<THuffTable>;
var
  R: TSegResult;
  Ref: Cardinal;
begin
  Result := nil;
  for Ref in S.Refs do
    if FResults.TryGetValue(Ref, R) and R.IsTable then
      Result := Result + [R.Table];
end;

procedure TJBIG2Decoder.DoPageInfo(const S: TSegment);
var
  W, H: Cardinal;
  Flags: Integer;
begin
  if Length(S.Data) < 19 then raise EJBIG2Error.Create('JBIG2: truncated page information');
  W := U32(S.Data, 0);
  H := U32(S.Data, 4);
  Flags := S.Data[16];
  FPageDefPix := (Flags shr 2) and 1;
  FPageDefOp  := (Flags shr 3) and 3;
  FUnknownH   := H = $FFFFFFFF;
  if FUnknownH then H := 0;
  FPage := TJBBitmap.Make(Integer(W), Integer(H), FPageDefPix);
  FHasPage := True;
  FStripeEnd := 0;
  FMaxY := 0;
end;

function ReadAT(const B: TBytes; P, N: Integer): TATPixels;
var
  I: Integer;
begin
  for I := 0 to 11 do
    if I < N then
    begin
      Result[I].X := S8(B, P + 2 * I);
      Result[I].Y := S8(B, P + 2 * I + 1);
    end
    else
    begin
      Result[I].X := 0;
      Result[I].Y := 0;
    end;
end;

function CeilLog2(N: Integer): Integer;
begin
  Result := 0;
  while (1 shl Result) < N do Inc(Result);
end;

// Selects a table: AStd[ASel] is a standard table number, 0 = not allowed,
// -1 = the next user-supplied table
function SelectTable(ASel: Integer; const AStd: array of Integer;
  const AUser: TArray<THuffTable>; var AUserIdx: Integer): THuffTable;
begin
  if (ASel < 0) or (ASel > High(AStd)) or (AStd[ASel] = 0) then
    raise EJBIG2Error.Create('JBIG2: invalid Huffman table selection');
  if AStd[ASel] > 0 then
    Exit(StdTables[AStd[ASel]]);
  if AUserIdx > High(AUser) then
    raise EJBIG2Error.Create('JBIG2: missing user-supplied Huffman table');
  Result := AUser[AUserIdx];
  Inc(AUserIdx);
end;

procedure TJBIG2Decoder.DoSymbolDictionary(const S: TSegment);
var
  B: TBytes;
  Flags, P, SDTemplate, SDRTemplate, NumEx, NumNew, NumIn, HCHeight,
  SymWidth, TotWidth, NDecoded, DW, I, J, ExIndex, Run, CurFlag, NAgg, NRuns,
  HCFirst, BMSize, Consumed, X, Y, CodeLen, UserIdx: Integer;
  HuffMode, RefAgg, CtxUsed, CtxRetained: Boolean;
  AT: TATPixels;
  RAT: TRefATPixels;
  InSyms, NewSyms, AllSyms: TArray<TJBBitmap>;
  Widths: TArray<Integer>;
  ExFlags: TArray<Boolean>;
  Src: TTextSource;
  GBCx, GRCx: TBytes;
  IADH, IADW, IAEX, IAAI: TIACtx;
  TCtx: TTextContexts;
  TP: TTextParams;
  R, Last: TSegResult;
  Ref: Cardinal;
  BS, BHC: TJBBitmap;
  NoSkip: TJBBitmap;
  User: TArray<THuffTable>;
  HDH, HDW, HBMSIZE, HAGG: THuffTable;

  function GetInt(var Ctx: TIACtx; const T: THuffTable; out V: Integer): Boolean;
  begin
    if HuffMode then Result := HuffDecode(Src.R, T, V)
    else Result := DecodeInt(Src.D, Ctx, V);
  end;

  function GetIntV(var Ctx: TIACtx; const T: THuffTable): Integer;
  begin
    if not GetInt(Ctx, T, Result) then
      raise EJBIG2Error.Create('JBIG2: unexpected OOB');
  end;

begin
  B := S.Data;
  Flags := U16(B, 0);
  HuffMode    := (Flags and 1) <> 0;
  RefAgg      := (Flags and 2) <> 0;
  CtxUsed     := (Flags and $100) <> 0;
  CtxRetained := (Flags and $200) <> 0;
  SDTemplate  := (Flags shr 10) and 3;
  SDRTemplate := (Flags shr 12) and 1;
  P := 2;
  AT := ReadAT(B, P, 0);
  if not HuffMode then
  begin
    if SDTemplate = 0 then begin AT := ReadAT(B, P, 4); Inc(P, 8); end
    else begin AT := ReadAT(B, P, 1); Inc(P, 2); end;
  end;
  RAT[0].X := 0; RAT[0].Y := 0; RAT[1].X := 0; RAT[1].Y := 0;
  if RefAgg and (SDRTemplate = 0) then
  begin
    RAT[0].X := S8(B, P);     RAT[0].Y := S8(B, P + 1);
    RAT[1].X := S8(B, P + 2); RAT[1].Y := S8(B, P + 3);
    Inc(P, 4);
  end;
  NumEx  := Integer(U32(B, P));
  NumNew := Integer(U32(B, P + 4));
  Inc(P, 8);
  if (NumEx < 0) or (NumNew < 0) then raise EJBIG2Error.Create('JBIG2: invalid symbol count');

  InSyms := ReferredSymbols(S);
  NumIn  := Length(InSyms);

  // 7.4.2.1.6: Huffman tables
  if HuffMode then
  begin
    User := ReferredTables(S);
    UserIdx := 0;
    HDH     := SelectTable((Flags shr 2) and 3, [4, 5, 0, -1], User, UserIdx);
    HDW     := SelectTable((Flags shr 4) and 3, [2, 3, 0, -1], User, UserIdx);
    HBMSIZE := SelectTable((Flags shr 6) and 1, [1, -1], User, UserIdx);
    HAGG    := SelectTable((Flags shr 7) and 1, [1, -1], User, UserIdx);
  end;

  // 7.4.2.2 steps 3-5: bitmap coding contexts (possibly reused), integer
  // coding contexts always reset
  SetLength(GBCx, 65536);
  SetLength(GRCx, 8192);
  if CtxUsed then
  begin
    Last := nil;
    for Ref in S.Refs do
      if FResults.TryGetValue(Ref, R) and R.IsDict then Last := R;
    if (Last <> nil) and (Length(Last.GBCx) = 65536) then
    begin
      GBCx := Copy(Last.GBCx);
      GRCx := Copy(Last.GRCx);
    end;
  end;
  FillChar(IADH, SizeOf(IADH), 0);
  FillChar(IADW, SizeOf(IADW), 0);
  FillChar(IAEX, SizeOf(IAEX), 0);
  FillChar(IAAI, SizeOf(IAAI), 0);
  // 6.5.8.2.3: symbol ID codes for refinement/aggregation
  if HuffMode then CodeLen := Max(CeilLog2(NumIn + NumNew), 1)
  else CodeLen := CeilLog2(NumIn + NumNew);
  TCtx.Reset(CodeLen);

  if HuffMode then Src.R.Init(B, P, Length(B))
  else Src.D.Init(B, P, Length(B));
  SetLength(NewSyms, NumNew);
  SetLength(Widths, NumNew);
  HCHeight := 0;
  NDecoded := 0;
  NoSkip := Default(TJBBitmap);
  while NDecoded < NumNew do
  begin
    Inc(HCHeight, GetIntV(IADH, HDH));                  // 6.5.6
    SymWidth := 0;
    TotWidth := 0;
    HCFirst  := NDecoded;
    while GetInt(IADW, HDW, DW) do                      // 6.5.7, OOB ends the class
    begin
      if NDecoded >= NumNew then
        raise EJBIG2Error.Create('JBIG2: too many symbols in dictionary');
      Inc(SymWidth, DW);
      Inc(TotWidth, SymWidth);
      if (SymWidth < 0) or (HCHeight < 0) then
        raise EJBIG2Error.Create('JBIG2: invalid symbol size');
      if HuffMode and not RefAgg then
      begin
        // the bitmaps come in the height class collective bitmap
        Widths[NDecoded] := SymWidth;
        Inc(NDecoded);
        Continue;
      end;
      if not RefAgg then
        // 6.5.8.1, Table 16
        BS := DecodeGenericArith(Src.D, GBCx, SymWidth, HCHeight, SDTemplate, False,
          AT, NoSkip, False)
      else
      begin
        // 6.5.8.2
        NAgg := GetIntV(IAAI, HAGG);
        AllSyms := InSyms + Copy(NewSyms, 0, NDecoded);
        if NAgg > 1 then
        begin
          // Table 17
          TP := Default(TTextParams);
          TP.Huff := HuffMode;
          TP.Refine := True;
          TP.W := SymWidth;
          TP.H := HCHeight;
          TP.NumInst := NAgg;
          TP.Strips := 1;
          TP.SymCodeLen := CodeLen;
          TP.FixedIDs := True;
          TP.DefPixel := 0;
          TP.CombOp := OP_OR;
          TP.Transposed := False;
          TP.RefCorner := RC_TOPLEFT;
          TP.DSOffset := 0;
          TP.RTemplate := SDRTemplate;
          TP.RAT := RAT;
          if HuffMode then
          begin
            TP.HFS := StdTables[6];
            TP.HDS := StdTables[8];
            TP.HDT := StdTables[11];
            TP.HRDW := StdTables[15];
            TP.HRDH := StdTables[15];
            TP.HRDX := StdTables[15];
            TP.HRDY := StdTables[15];
            TP.HRSIZE := StdTables[1];
          end;
          BS := DecodeTextRegion(Src, TCtx, GRCx, TP, AllSyms);
        end
        else
        begin
          // 6.5.8.2.2, Table 18
          if HuffMode then I := Integer(Src.R.ReadBits(CodeLen))
          else I := DecodeIAID(Src.D, TCtx.IAID, CodeLen);
          if (I < 0) or (I >= Length(AllSyms)) then
            raise EJBIG2Error.Create('JBIG2: symbol ID out of range');
          if HuffMode then
          begin
            J  := HuffDecodeV(Src.R, StdTables[15]);
            DW := HuffDecodeV(Src.R, StdTables[15]);
            BS := RefineHuffman(Src, GRCx, StdTables[1], SymWidth, HCHeight,
              SDRTemplate, AllSyms[I], J, DW, RAT);
          end
          else
          begin
            J  := DecodeIntV(Src.D, TCtx.IARDX);
            DW := DecodeIntV(Src.D, TCtx.IARDY);
            BS := DecodeRefinement(Src.D, GRCx, SymWidth, HCHeight, SDRTemplate,
              AllSyms[I], J, DW, False, RAT);
          end;
        end;
      end;
      NewSyms[NDecoded] := BS;
      Inc(NDecoded);
    end;
    if HuffMode and not RefAgg then
    begin
      // 6.5.9: height class collective bitmap
      BMSize := HuffDecodeV(Src.R, HBMSIZE);
      Src.R.Align;
      if BMSize = 0 then
      begin
        // uncompressed, rows padded to bytes
        BHC := TJBBitmap.Make(TotWidth, HCHeight);
        for Y := 0 to HCHeight - 1 do
        begin
          for X := 0 to TotWidth - 1 do
          begin
            if Src.R.Pos + X shr 3 >= Src.R.EndPos then
              raise EJBIG2Error.Create('JBIG2: truncated collective bitmap');
            BHC.Px[Y * TotWidth + X] := (B[Src.R.Pos + X shr 3] shr (7 - X and 7)) and 1;
          end;
          Inc(Src.R.Pos, (TotWidth + 7) div 8);
        end;
      end
      else
      begin
        if Src.R.Pos + BMSize > Src.R.EndPos then
          raise EJBIG2Error.Create('JBIG2: truncated collective bitmap');
        BHC := DecodeGenericMMR(B, Src.R.Pos, Src.R.Pos + BMSize, TotWidth, HCHeight,
          Consumed);
        Inc(Src.R.Pos, BMSize);
      end;
      // break it up into the symbols of the height class
      X := 0;
      for I := HCFirst to NDecoded - 1 do
      begin
        BS := TJBBitmap.Make(Widths[I], HCHeight);
        for Y := 0 to HCHeight - 1 do
          if Widths[I] > 0 then
            Move(BHC.Px[Y * TotWidth + X], BS.Px[Y * Widths[I]], Widths[I]);
        NewSyms[I] := BS;
        Inc(X, Widths[I]);
      end;
    end;
  end;

  // 6.5.10: exported symbols
  SetLength(ExFlags, NumIn + NumNew);
  ExIndex := 0;
  CurFlag := 0;
  NRuns := 0;
  while ExIndex < NumIn + NumNew do
  begin
    if HuffMode then Run := HuffDecodeV(Src.R, StdTables[1])
    else Run := DecodeIntV(Src.D, IAEX);
    Inc(NRuns);
    // Compatibility: the T.88 sample encoder (conformance data of Annex K)
    // codes the export runs as 0, 0 and its decoder exports the new
    // symbols.  A conforming stream never starts with 0, 0 when it
    // exports exactly its NumNew > 0 new symbols.
    if (NRuns = 2) and (Run = 0) and (ExIndex = 0) and (NumNew > 0) and
       (NumEx = NumNew) then
    begin
      for I := 0 to NumIn + NumNew - 1 do
        ExFlags[I] := I >= NumIn;
      Break;
    end;
    if (Run < 0) or (ExIndex + Run > NumIn + NumNew) then
      raise EJBIG2Error.Create('JBIG2: invalid export run');
    for I := ExIndex to ExIndex + Run - 1 do
      ExFlags[I] := CurFlag = 1;
    Inc(ExIndex, Run);
    CurFlag := 1 - CurFlag;
  end;
  R := TSegResult.Create;
  try
    J := 0;
    for I := 0 to NumIn + NumNew - 1 do
      if ExFlags[I] then
      begin
        SetLength(R.Symbols, J + 1);
        if I < NumIn then R.Symbols[J] := InSyms[I]
        else R.Symbols[J] := NewSyms[I - NumIn];
        Inc(J);
      end;
    if J <> NumEx then
      raise EJBIG2Error.Create('JBIG2: exported symbol count mismatch');
    if CtxRetained then
    begin
      R.GBCx := GBCx;
      R.GRCx := GRCx;
    end;
    R.IsDict := True;
    FAllSymbols := FAllSymbols + R.Symbols;
    FResults.AddOrSetValue(S.Number, R);
  except
    R.Free;
    raise;
  end;
end;

// 7.4.3.1.7: symbol ID Huffman table
function ReadSymbolIDTable(var R: TBitReader; ANumSyms: Integer): THuffTable;
var
  RunLens, Lens: TArray<Integer>;
  RunTable: THuffTable;
  I, Code, N, Count: Integer;
begin
  SetLength(RunLens, 35);
  for I := 0 to 34 do
    RunLens[I] := Integer(R.ReadBits(4));
  RunTable := CodeTableFromLengths(RunLens);
  SetLength(Lens, ANumSyms);
  N := 0;
  while N < ANumSyms do
  begin
    Code := HuffDecodeV(R, RunTable);
    if Code < 32 then
    begin
      Lens[N] := Code;
      Inc(N);
      Continue;
    end;
    case Code of
      32: Count := Integer(R.ReadBits(2)) + 3;
      33: Count := Integer(R.ReadBits(3)) + 3;
    else
      Count := Integer(R.ReadBits(7)) + 11;
    end;
    for I := 1 to Count do
    begin
      if N >= ANumSyms then raise EJBIG2Error.Create('JBIG2: invalid symbol ID table');
      if Code = 32 then
      begin
        if N = 0 then raise EJBIG2Error.Create('JBIG2: invalid symbol ID table');
        Lens[N] := Lens[N - 1];
      end
      else
        Lens[N] := 0;
      Inc(N);
    end;
  end;
  R.Align;
  Result := CodeTableFromLengths(Lens);
end;

procedure TJBIG2Decoder.DoTextRegion(const S: TSegment);
var
  B: TBytes;
  Info: TRegionInfo;
  Flags, HFlags, P, UserIdx: Integer;
  TP: TTextParams;
  Syms: TArray<TJBBitmap>;
  Src: TTextSource;
  TCtx: TTextContexts;
  GRCx: TBytes;
  User: TArray<THuffTable>;
begin
  B := S.Data;
  Info := ReadRegionInfo(B);
  P := 17;
  Flags := U16(B, P);
  Inc(P, 2);
  TP := Default(TTextParams);
  TP.Huff       := (Flags and 1) <> 0;
  TP.Refine     := (Flags and 2) <> 0;
  TP.Strips     := 1 shl ((Flags shr 2) and 3);
  TP.RefCorner  := (Flags shr 4) and 3;
  TP.Transposed := (Flags and $40) <> 0;
  TP.CombOp     := (Flags shr 7) and 3;
  TP.DefPixel   := (Flags shr 9) and 1;
  TP.DSOffset   := (Flags shr 10) and $1F;
  if TP.DSOffset > 15 then Dec(TP.DSOffset, 32);
  TP.RTemplate  := (Flags shr 15) and 1;
  HFlags := 0;
  if TP.Huff then
  begin
    HFlags := U16(B, P);
    Inc(P, 2);
  end;
  if TP.Refine and (TP.RTemplate = 0) then
  begin
    TP.RAT[0].X := S8(B, P);     TP.RAT[0].Y := S8(B, P + 1);
    TP.RAT[1].X := S8(B, P + 2); TP.RAT[1].Y := S8(B, P + 3);
    Inc(P, 4);
  end;
  TP.NumInst := Integer(U32(B, P));
  Inc(P, 4);
  TP.W := Info.W;
  TP.H := Info.H;
  Syms := ReferredSymbols(S);
  // Compatibility: the T.88 sample encoder writes text regions that refer
  // to no symbol dictionary and use every dictionary decoded so far.  A
  // conforming region without dictionaries has no symbols to place.
  if (Length(S.Refs) = 0) and (TP.NumInst > 0) then
    Syms := FAllSymbols;
  TP.SymCodeLen := CeilLog2(Length(Syms));
  // 7.4.3.2: all statistics reset
  TCtx.Reset(TP.SymCodeLen);
  SetLength(GRCx, 8192);
  if TP.Huff then
  begin
    // 7.4.3.1.6: Huffman tables, then the symbol ID table (7.4.3.1.7)
    User := ReferredTables(S);
    UserIdx := 0;
    TP.HFS    := SelectTable(HFlags and 3, [6, 7, 0, -1], User, UserIdx);
    TP.HDS    := SelectTable((HFlags shr 2) and 3, [8, 9, 10, -1], User, UserIdx);
    TP.HDT    := SelectTable((HFlags shr 4) and 3, [11, 12, 13, -1], User, UserIdx);
    TP.HRDW   := SelectTable((HFlags shr 6) and 3, [14, 15, 0, -1], User, UserIdx);
    TP.HRDH   := SelectTable((HFlags shr 8) and 3, [14, 15, 0, -1], User, UserIdx);
    TP.HRDX   := SelectTable((HFlags shr 10) and 3, [14, 15, 0, -1], User, UserIdx);
    TP.HRDY   := SelectTable((HFlags shr 12) and 3, [14, 15, 0, -1], User, UserIdx);
    TP.HRSIZE := SelectTable((HFlags shr 14) and 1, [1, -1], User, UserIdx);
    Src.R.Init(B, P, Length(B));
    TP.SymCodes := ReadSymbolIDTable(Src.R, Length(Syms));
  end
  else
    Src.D.Init(B, P, Length(B));
  StoreRegion(S, DecodeTextRegion(Src, TCtx, GRCx, TP, Syms), Info);
end;

procedure TJBIG2Decoder.DoPatternDictionary(const S: TSegment);
var
  B: TBytes;
  Flags, PW, PH, GrayMax, Template, I, Y, Consumed: Integer;
  AT: TATPixels;
  D: TMQDecoder;
  Cx: TBytes;
  BHDC, NoSkip: TJBBitmap;
  R: TSegResult;
begin
  B := S.Data;
  if Length(B) < 7 then raise EJBIG2Error.Create('JBIG2: truncated pattern dictionary');
  Flags   := B[0];
  PW      := B[1];
  PH      := B[2];
  GrayMax := Integer(U32(B, 3));
  if (PW = 0) or (PH = 0) or (GrayMax < 0) or (Int64(GrayMax + 1) * PW > 1 shl 24) then
    raise EJBIG2Error.Create('JBIG2: invalid pattern dictionary');
  // 6.7.5, Table 27
  if (Flags and 1) <> 0 then
    BHDC := DecodeGenericMMR(B, 7, Length(B), (GrayMax + 1) * PW, PH, Consumed)
  else
  begin
    Template := (Flags shr 1) and 3;
    AT := ReadAT(B, 0, 0);
    AT[0].X := -PW; AT[0].Y := 0;
    AT[1].X := -3;  AT[1].Y := -1;
    AT[2].X := 2;   AT[2].Y := -2;
    AT[3].X := -2;  AT[3].Y := -2;
    SetLength(Cx, 65536);
    D.Init(B, 7, Length(B));
    NoSkip := Default(TJBBitmap);
    BHDC := DecodeGenericArith(D, Cx, (GrayMax + 1) * PW, PH, Template, False, AT,
      NoSkip, False);
  end;
  R := TSegResult.Create;
  SetLength(R.Patterns, GrayMax + 1);
  for I := 0 to GrayMax do
  begin
    R.Patterns[I] := TJBBitmap.Make(PW, PH);
    for Y := 0 to PH - 1 do
      Move(BHDC.Px[Y * BHDC.W + I * PW], R.Patterns[I].Px[Y * PW], PW);
  end;
  R.IsPatterns := True;
  FResults.AddOrSetValue(S.Number, R);
end;

// Annex C: gray-scale image of AW x AH with ABPP bits per value
function DecodeGrayScale(const AData: TBytes; AStart: Integer; AMMR: Boolean;
  AW, AH, ABPP, ATemplate: Integer; const ASkip: TJBBitmap;
  AUseSkip: Boolean): TArray<Integer>;
var
  D: TMQDecoder;
  Cx: TBytes;
  AT: TATPixels;
  Planes: TArray<TJBBitmap>;
  J, I, Pos, Consumed: Integer;
begin
  SetLength(Planes, ABPP);
  // Table C.4
  AT := ReadAT(AData, 0, 0);
  if ATemplate <= 1 then AT[0].X := 3 else AT[0].X := 2;
  AT[0].Y := -1;
  AT[1].X := -3; AT[1].Y := -1;
  AT[2].X := 2;  AT[2].Y := -2;
  AT[3].X := -2; AT[3].Y := -2;
  Pos := AStart;
  if not AMMR then
  begin
    SetLength(Cx, 65536);
    D.Init(AData, AStart, Length(AData));
  end;
  // C.5: from the most significant plane down, Gray-coded
  for J := ABPP - 1 downto 0 do
  begin
    if AMMR then
    begin
      Planes[J] := DecodeGenericMMR(AData, Pos, Length(AData), AW, AH, Consumed);
      Inc(Pos, Consumed);
    end
    else
      Planes[J] := DecodeGenericArith(D, Cx, AW, AH, ATemplate, False, AT, ASkip, AUseSkip);
    if J < ABPP - 1 then
      for I := 0 to AW * AH - 1 do
        Planes[J].Px[I] := Planes[J].Px[I] xor Planes[J + 1].Px[I];
  end;
  SetLength(Result, AW * AH);
  for I := 0 to AW * AH - 1 do
  begin
    Result[I] := 0;
    for J := ABPP - 1 downto 0 do
      Result[I] := (Result[I] shl 1) or Planes[J].Px[I];
  end;
end;

// 6.6.5: location of the pattern of grid cell (NG, MG); >> 8 is arithmetic
function GridX(GX, MG, NG, RX, RY: Integer): Integer;
var
  V: Int64;
begin
  V := Int64(GX) + Int64(MG) * RY + Int64(NG) * RX;
  Result := Integer(V div 256);
  if (V < 0) and (V mod 256 <> 0) then Dec(Result);
end;

function GridY(GY, MG, NG, RX, RY: Integer): Integer;
var
  V: Int64;
begin
  V := Int64(GY) + Int64(MG) * RX - Int64(NG) * RY;
  Result := Integer(V div 256);
  if (V < 0) and (V mod 256 <> 0) then Dec(Result);
end;

procedure TJBIG2Decoder.DoHalftoneRegion(const S: TSegment);
var
  B: TBytes;
  Info: TRegionInfo;
  Flags, Template, CombOp, DefPix, GW, GH, GX, GY, RX, RY, PW, PH, BPP,
  MG, NG, X, Y: Integer;
  MMR, EnableSkip: Boolean;
  Pats: TArray<TJBBitmap>;
  R: TSegResult;
  Ref: Cardinal;
  HReg, Skip: TJBBitmap;
  GI: TArray<Integer>;
begin
  B := S.Data;
  Info := ReadRegionInfo(B);
  if Length(B) < 17 + 1 + 20 then raise EJBIG2Error.Create('JBIG2: truncated halftone region');
  Flags      := B[17];
  MMR        := (Flags and 1) <> 0;
  Template   := (Flags shr 1) and 3;
  EnableSkip := (Flags and 8) <> 0;
  CombOp     := (Flags shr 4) and 7;
  DefPix     := (Flags shr 7) and 1;
  GW := Integer(U32(B, 18));
  GH := Integer(U32(B, 22));
  GX := Integer(U32(B, 26));
  GY := Integer(U32(B, 30));
  RX := U16(B, 34);
  RY := U16(B, 36);
  if (GW < 0) or (GH < 0) or (Int64(GW) * GH > 1 shl 26) then
    raise EJBIG2Error.Create('JBIG2: invalid halftone grid');
  // the referred pattern dictionary
  Pats := nil;
  for Ref in S.Refs do
    if FResults.TryGetValue(Ref, R) and R.IsPatterns then
    begin
      Pats := R.Patterns;
      Break;
    end;
  if Length(Pats) = 0 then raise EJBIG2Error.Create('JBIG2: halftone without patterns');
  PW := Pats[0].W;
  PH := Pats[0].H;
  // 6.6.5
  HReg := TJBBitmap.Make(Info.W, Info.H, DefPix);
  Skip := Default(TJBBitmap);
  if EnableSkip then
  begin
    Skip := TJBBitmap.Make(GW, GH);
    for MG := 0 to GH - 1 do
      for NG := 0 to GW - 1 do
      begin
        X := GridX(GX, MG, NG, RX, RY);
        Y := GridY(GY, MG, NG, RX, RY);
        if (X + PW <= 0) or (X >= Info.W) or (Y + PH <= 0) or (Y >= Info.H) then
          Skip.Px[MG * GW + NG] := 1;
      end;
  end;
  BPP := CeilLog2(Length(Pats));
  GI := DecodeGrayScale(B, 38, MMR, GW, GH, BPP, Template, Skip, EnableSkip);
  // 6.6.5.2: draw the patterns
  for MG := 0 to GH - 1 do
    for NG := 0 to GW - 1 do
    begin
      X := GridX(GX, MG, NG, RX, RY);
      Y := GridY(GY, MG, NG, RX, RY);
      if GI[MG * GW + NG] < Length(Pats) then
        Compose(HReg, Pats[GI[MG * GW + NG]], X, Y, CombOp);
    end;
  StoreRegion(S, HReg, Info);
end;

procedure TJBIG2Decoder.DoGenericRegion(const S: TSegment);
var
  B: TBytes;
  Info: TRegionInfo;
  Flags, P, Template, H, Consumed: Integer;
  AT: TATPixels;
  D: TMQDecoder;
  Cx: TBytes;
  Region, NoSkip: TJBBitmap;
begin
  B := S.Data;
  Info := ReadRegionInfo(B);
  if Length(B) < 18 then raise EJBIG2Error.Create('JBIG2: truncated generic region');
  Flags := B[17];
  P := 18;
  H := Info.H;
  // a region of unknown length ends with its actual row count (7.4.6.4)
  if (S.Typ = 38) and (Length(B) >= P + 6) and
     (((B[Length(B) - 6] = $FF) and (B[Length(B) - 5] = $AC)) or
      ((Flags and 1 <> 0) and (B[Length(B) - 6] = 0) and (B[Length(B) - 5] = 0))) then
    H := Min(H, Integer(U32(B, Length(B) - 4)));
  if (Flags and 1) <> 0 then
  begin
    Region := DecodeGenericMMR(B, P, Length(B), Info.W, H, Consumed);
    StoreRegion(S, Region, Info);
    Exit;
  end;
  Template := (Flags shr 1) and 3;
  if (Template = 0) and ((Flags and $10) <> 0) then
  begin
    // EXTTEMPLATE: A1..A12 (Figure 50; 24 bytes, the "32-byte" of 7.4.6.3
    // does not match the figure nor the conformance data)
    Template := 4;
    AT := ReadAT(B, P, 12);
    Inc(P, 24);
  end
  else if Template = 0 then begin AT := ReadAT(B, P, 4); Inc(P, 8); end
  else begin AT := ReadAT(B, P, 1); Inc(P, 2); end;
  SetLength(Cx, 65536);
  D.Init(B, P, Length(B));
  NoSkip := Default(TJBBitmap);
  Region := DecodeGenericArith(D, Cx, Info.W, H, Template, (Flags and 8) <> 0, AT,
    NoSkip, False);
  StoreRegion(S, Region, Info);
end;

procedure TJBIG2Decoder.DoRefinementRegion(const S: TSegment);
var
  B: TBytes;
  Info: TRegionInfo;
  Flags, P, X, Y: Integer;
  RAT: TRefATPixels;
  Ref, Region: TJBBitmap;
  R: TSegResult;
  D: TMQDecoder;
  Cx: TBytes;
  Found: Boolean;
begin
  B := S.Data;
  Info := ReadRegionInfo(B);
  if Length(B) < 18 then raise EJBIG2Error.Create('JBIG2: truncated refinement region');
  Flags := B[17];
  P := 18;
  RAT[0].X := 0; RAT[0].Y := 0; RAT[1].X := 0; RAT[1].Y := 0;
  if (Flags and 1) = 0 then
  begin
    RAT[0].X := S8(B, P);     RAT[0].Y := S8(B, P + 1);
    RAT[1].X := S8(B, P + 2); RAT[1].Y := S8(B, P + 3);
    Inc(P, 4);
  end;
  // 7.4.7.4: the referred intermediate region, or the page area
  Found := False;
  for var RefNo in S.Refs do
    if FResults.TryGetValue(RefNo, R) and R.HasRegion then
    begin
      Ref := R.Region;
      Found := True;
      FResults.Remove(RefNo);     // it is replaced by this segment's result
      Break;
    end;
  if not Found then
  begin
    if not FHasPage then raise EJBIG2Error.Create('JBIG2: refinement without page');
    EnsurePageRows(Info.Y + Info.H);
    Ref := TJBBitmap.Make(Info.W, Info.H);
    for Y := 0 to Info.H - 1 do
      for X := 0 to Info.W - 1 do
        Ref.Px[Y * Info.W + X] := FPage.Get(Info.X + X, Info.Y + Y);
  end;
  SetLength(Cx, 8192);
  D.Init(B, P, Length(B));
  Region := DecodeRefinement(D, Cx, Info.W, Info.H, Flags and 1, Ref, 0, 0,
    (Flags and 2) <> 0, RAT);
  StoreRegion(S, Region, Info);
end;

procedure TJBIG2Decoder.DoCodeTable(const S: TSegment);
var
  R: TSegResult;
begin
  R := TSegResult.Create;
  try
    R.Table := ReadCodeTable(S.Data);
    R.IsTable := True;
  except
    R.Free;
    raise;
  end;
  FResults.AddOrSetValue(S.Number, R);
end;

procedure TJBIG2Decoder.Process(const S: TSegment);
begin
  case S.Typ of
    0:            DoSymbolDictionary(S);
    4, 6, 7:      DoTextRegion(S);
    16:           DoPatternDictionary(S);
    20, 22, 23:   DoHalftoneRegion(S);
    36, 38, 39:   DoGenericRegion(S);
    40, 42, 43:   DoRefinementRegion(S);
    48:           DoPageInfo(S);
    49:           ;   // end of page
    50:           if Length(S.Data) >= 4 then
                    FStripeEnd := Max(FStripeEnd, Integer(U32(S.Data, 0)) + 1);
    53:           DoCodeTable(S);
  else
    ;   // end of file, profiles, colour palettes, extensions
  end;
end;

function TJBIG2Decoder.PageBits(out AWidth, AHeight: Integer): TBytes;
var
  H, RowBytes, X, Y: Integer;
  Row: Integer;
begin
  if not FHasPage then raise EJBIG2Error.Create('JBIG2: no page information segment');
  H := FPage.H;
  if FUnknownH then
  begin
    if FStripeEnd > 0 then H := FStripeEnd else H := FMaxY;
    EnsurePageRows(H);
  end;
  AWidth  := FPage.W;
  AHeight := H;
  RowBytes := (AWidth + 7) div 8;
  SetLength(Result, RowBytes * H);
  if Length(Result) > 0 then FillChar(Result[0], Length(Result), 0);
  for Y := 0 to H - 1 do
  begin
    Row := Y * RowBytes;
    for X := 0 to AWidth - 1 do
      if FPage.Px[Y * AWidth + X] <> 0 then
        Result[Row + X shr 3] := Result[Row + X shr 3] or ($80 shr (X and 7));
  end;
end;

{ ===========================================================================
  Entry points
  =========================================================================== }

function DecodeSegments(AList: TList<TSegment>; APage: Cardinal;
  out AWidth, AHeight: Integer): TBytes;
var
  Dec: TJBIG2Decoder;
  S: TSegment;
begin
  Dec := TJBIG2Decoder.Create;
  try
    for S in AList do
      // segments of the page, and those not associated with any page
      if (S.Page = 0) or (S.Page = APage) then
        try
          Dec.Process(S);
        except
          on E: EJBIG2Error do
            raise EJBIG2Error.CreateFmt('%s (segment %d, type %d)', [E.Message, S.Number, S.Typ]);
        end;
    Result := Dec.PageBits(AWidth, AHeight);
  finally
    Dec.Free;
  end;
end;

function JBIG2DecodeEmbedded(const AData, AGlobals: TBytes;
  out AWidth, AHeight: Integer): TBytes;
var
  List: TList<TSegment>;
  Page: Cardinal;
  S: TSegment;
begin
  List := TList<TSegment>.Create;
  try
    if Length(AGlobals) > 0 then
      ParseSequential(AGlobals, 0, List);
    ParseSequential(AData, 0, List);
    // the page of the first page information segment
    Page := 1;
    for S in List do
      if S.Typ = 48 then
      begin
        Page := S.Page;
        Break;
      end;
    Result := DecodeSegments(List, Page, AWidth, AHeight);
  finally
    List.Free;
  end;
end;

function JBIG2DecodeFile(const AData: TBytes; APage: Integer;
  out AWidth, AHeight: Integer): TBytes;
const
  ID: array[0..7] of Byte = ($97, $4A, $42, $32, $0D, $0A, $1A, $0A);
var
  List: TList<TSegment>;
  Flags, P, I: Integer;
begin
  // D.4: file header
  if Length(AData) < 9 then raise EJBIG2Error.Create('JBIG2: not a JBIG2 file');
  for I := 0 to 7 do
    if AData[I] <> ID[I] then raise EJBIG2Error.Create('JBIG2: not a JBIG2 file');
  Flags := AData[8];
  P := 9;
  if (Flags and 2) = 0 then Inc(P, 4);   // number of pages
  List := TList<TSegment>.Create;
  try
    if (Flags and 1) <> 0 then ParseSequential(AData, P, List)
    else ParseRandomAccess(AData, P, List);
    Result := DecodeSegments(List, Cardinal(APage), AWidth, AHeight);
  finally
    List.Free;
  end;
end;

initialization
  BuildStdTables;

end.
