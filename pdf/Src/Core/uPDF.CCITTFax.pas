unit uPDF.CCITTFax;

{ CCITT Group 3 and Group 4 facsimile decoder (ITU-T T.4 and T.6) for the
  PDF CCITTFaxDecode filter.  Pure Pascal, no platform dependencies.

  Supported: K < 0 (Group 4, two-dimensional), K = 0 (Group 3 one-dimensional,
  Modified Huffman), K > 0 (Group 3 mixed one/two-dimensional with a tag bit
  after every EOL), EOL codes with or without fill bits, EncodedByteAlign,
  EndOfBlock (EOFB of T.6 and RTC of T.4), BlackIs1.  Uncompressed mode
  (the T.4 extension code) is not supported; such rows are treated as damaged.

  Damaged rows: when the data has EOL codes (Group 3), decoding resynchronises
  on the next EOL and the damaged row is replaced by the previous one.  In
  Group 4 there is nothing to resynchronise on and decoding stops there.  If
  Rows is known, missing rows are filled with white.

  Output: Rows x ((Columns + 7) div 8) bytes, one bit per pixel, most
  significant bit first; 0 = black unless BlackIs1 (the PDF convention).

  License: CC0 1.0 Universal (public domain). }

interface

uses
  System.SysUtils;

type
  // The CCITTFaxDecode entries of /DecodeParms
  TCCITTFaxParams = record
    K:                      Integer;  // < 0 Group 4, 0 Group 3 1-D, > 0 Group 3 2-D
    Columns:                Integer;  // pixels per row (PDF default 1728)
    Rows:                   Integer;  // 0 = until the data or the EOFB ends
    EndOfLine:              Boolean;  // EOL codes are required (they are accepted anyway)
    EncodedByteAlign:       Boolean;  // every row starts on a byte boundary
    EndOfBlock:             Boolean;  // data ends with EOFB / RTC
    BlackIs1:               Boolean;  // 1 bits are black in the output
    DamagedRowsBeforeError: Integer;
    class function Default: TCCITTFaxParams; static;
  end;

  ECCITTFaxError = class(Exception);

// Decodes AData; raises ECCITTFaxError when not even one row can be decoded.
function CCITTFaxDecode(const AData: TBytes;
  const AParams: TCCITTFaxParams): TBytes; overload;
// Same; ARows receives the number of rows in the result.
function CCITTFaxDecode(const AData: TBytes;
  const AParams: TCCITTFaxParams; out ARows: Integer): TBytes; overload;
// Same; AConsumed receives the number of bytes used, including an EOFB
// right after the last of AParams.Rows rows (JBIG2 MMR data, T.88 6.2.6).
function CCITTFaxDecode(const AData: TBytes;
  const AParams: TCCITTFaxParams; out ARows, AConsumed: Integer): TBytes; overload;

implementation

uses
  System.Math;

{ ---------------------------------------------------------------------------
  Code tables (T.4 tables 2 and 3, T.4 table 4 / T.6 table 1)
  --------------------------------------------------------------------------- }

const
  WHITE_TERM: array[0..63] of string = (
    '00110101', '000111', '0111', '1000', '1011', '1100', '1110', '1111',
    '10011', '10100', '00111', '01000', '001000', '000011', '110100', '110101',
    '101010', '101011', '0100111', '0001100', '0001000', '0010111', '0000011', '0000100',
    '0101000', '0101011', '0010011', '0100100', '0011000', '00000010', '00000011', '00011010',
    '00011011', '00010010', '00010011', '00010100', '00010101', '00010110', '00010111', '00101000',
    '00101001', '00101010', '00101011', '00101100', '00101101', '00000100', '00000101', '00001010',
    '00001011', '01010010', '01010011', '01010100', '01010101', '00100100', '00100101', '01011000',
    '01011001', '01011010', '01011011', '01001010', '01001011', '00110010', '00110011', '00110100');

  // 64, 128, ... 1728
  WHITE_MAKEUP: array[0..26] of string = (
    '11011', '10010', '010111', '0110111', '00110110', '00110111', '01100100', '01100101',
    '01101000', '01100111', '011001100', '011001101', '011010010', '011010011', '011010100', '011010101',
    '011010110', '011010111', '011011000', '011011001', '011011010', '011011011', '010011000', '010011001',
    '010011010', '011000', '010011011');

  BLACK_TERM: array[0..63] of string = (
    '0000110111', '010', '11', '10', '011', '0011', '0010', '00011',
    '000101', '000100', '0000100', '0000101', '0000111', '00000100', '00000111', '000011000',
    '0000010111', '0000011000', '0000001000', '00001100111', '00001101000', '00001101100', '00000110111', '00000101000',
    '00000010111', '00000011000', '000011001010', '000011001011', '000011001100', '000011001101', '000001101000', '000001101001',
    '000001101010', '000001101011', '000011010010', '000011010011', '000011010100', '000011010101', '000011010110', '000011010111',
    '000001101100', '000001101101', '000011011010', '000011011011', '000001010100', '000001010101', '000001010110', '000001010111',
    '000001100100', '000001100101', '000001010010', '000001010011', '000000100100', '000000110111', '000000111000', '000000100111',
    '000000101000', '000001011000', '000001011001', '000000101011', '000000101100', '000001011010', '000001100110', '000001100111');

  BLACK_MAKEUP: array[0..26] of string = (
    '0000001111', '000011001000', '000011001001', '000001011011', '000000110011', '000000110100', '000000110101', '0000001101100',
    '0000001101101', '0000001001010', '0000001001011', '0000001001100', '0000001001101', '0000001110010', '0000001110011', '0000001110100',
    '0000001110101', '0000001110110', '0000001110111', '0000001010010', '0000001010011', '0000001010100', '0000001010101', '0000001011010',
    '0000001011011', '0000001100100', '0000001100101');

  // 1792, 1856, ... 2560, shared by both colours
  EXT_MAKEUP: array[0..12] of string = (
    '00000001000', '00000001100', '00000001101', '000000010010', '000000010011', '000000010100', '000000010101',
    '000000010110', '000000010111', '000000011100', '000000011101', '000000011110', '000000011111');

  RUN_BITS  = 13;   // longest run code
  MODE_BITS = 7;    // longest mode code

  // Mode codes; vertical modes are stored as their offset -3..3
  MODE_PASS = 100;
  MODE_HORZ = 101;
  MODE_EXT  = 102;

type
  TCodeEntry = record
    Value: SmallInt;  // run length, or mode
    Len:   Byte;      // 0 = no code with this prefix
  end;

var
  WhiteTab, BlackTab: array[0..(1 shl RUN_BITS) - 1] of TCodeEntry;
  ModeTab: array[0..(1 shl MODE_BITS) - 1] of TCodeEntry;

procedure AddCode(var ATab: array of TCodeEntry; ABits: Integer;
  const ACode: string; AValue: Integer);
var
  C, I, Span: Integer;
begin
  C := 0;
  for I := 1 to Length(ACode) do
    C := C * 2 + Ord(ACode[I] = '1');
  Span := 1 shl (ABits - Length(ACode));
  for I := C * Span to (C + 1) * Span - 1 do
  begin
    ATab[I].Value := AValue;
    ATab[I].Len   := Length(ACode);
  end;
end;

procedure BuildTables;
var
  I: Integer;
begin
  for I := 0 to 63 do
  begin
    AddCode(WhiteTab, RUN_BITS, WHITE_TERM[I], I);
    AddCode(BlackTab, RUN_BITS, BLACK_TERM[I], I);
  end;
  for I := 0 to 26 do
  begin
    AddCode(WhiteTab, RUN_BITS, WHITE_MAKEUP[I], 64 * (I + 1));
    AddCode(BlackTab, RUN_BITS, BLACK_MAKEUP[I], 64 * (I + 1));
  end;
  for I := 0 to 12 do
  begin
    AddCode(WhiteTab, RUN_BITS, EXT_MAKEUP[I], 1792 + 64 * I);
    AddCode(BlackTab, RUN_BITS, EXT_MAKEUP[I], 1792 + 64 * I);
  end;
  AddCode(ModeTab, MODE_BITS, '1',       0);
  AddCode(ModeTab, MODE_BITS, '011',     1);
  AddCode(ModeTab, MODE_BITS, '010',     -1);
  AddCode(ModeTab, MODE_BITS, '000011',  2);
  AddCode(ModeTab, MODE_BITS, '000010',  -2);
  AddCode(ModeTab, MODE_BITS, '0000011', 3);
  AddCode(ModeTab, MODE_BITS, '0000010', -3);
  AddCode(ModeTab, MODE_BITS, '001',     MODE_HORZ);
  AddCode(ModeTab, MODE_BITS, '0001',    MODE_PASS);
  AddCode(ModeTab, MODE_BITS, '0000001', MODE_EXT);
end;

{ TCCITTFaxParams }

class function TCCITTFaxParams.Default: TCCITTFaxParams;
begin
  Result.K                      := 0;
  Result.Columns                := 1728;
  Result.Rows                   := 0;
  Result.EndOfLine              := False;
  Result.EncodedByteAlign       := False;
  Result.EndOfBlock             := True;
  Result.BlackIs1               := False;
  Result.DamagedRowsBeforeError := 0;
end;

{ ---------------------------------------------------------------------------
  Decoder
  --------------------------------------------------------------------------- }

type
  TFaxDecoder = record
    Data:    TBytes;
    NBits:   Int64;
    Pos:     Int64;      // bit position, most significant bit of each byte first
    Columns: Integer;
    Ref, Cur: TArray<Integer>;   // changing elements of the reference and coding lines
    NCur:    Integer;
    function Peek(N: Integer): Cardinal;
    procedure Eat(N: Integer); inline;
    function AtEnd: Boolean; inline;
    procedure Align;
    function ReadRun(AWhite: Boolean): Integer;
    function AddChange(A: Integer): Boolean;
    function Decode1D: Boolean;
    function Decode2D: Boolean;
    procedure CloseLine;
  end;

// Next N bits (N <= 24) without consuming them; zeros past the end
function TFaxDecoder.Peek(N: Integer): Cardinal;
var
  B: Int64;
  I: Integer;
  Acc: Cardinal;
begin
  B := Pos shr 3;
  Acc := 0;
  for I := 0 to 3 do
  begin
    Acc := Acc shl 8;
    if B + I < Length(Data) then
      Acc := Acc or Data[B + I];
  end;
  Result := (Acc shl (Pos and 7)) shr (32 - N);
end;

procedure TFaxDecoder.Eat(N: Integer);
begin
  Inc(Pos, N);
end;

function TFaxDecoder.AtEnd: Boolean;
begin
  Result := Pos >= NBits;
end;

procedure TFaxDecoder.Align;
begin
  Pos := (Pos + 7) and not Int64(7);
end;

// One run: any make-up codes followed by a terminating code. -1 on error.
function TFaxDecoder.ReadRun(AWhite: Boolean): Integer;
var
  E: TCodeEntry;
begin
  Result := 0;
  repeat
    if AtEnd then Exit(-1);
    if AWhite then E := WhiteTab[Peek(RUN_BITS)]
    else E := BlackTab[Peek(RUN_BITS)];
    if E.Len = 0 then Exit(-1);
    Eat(E.Len);
    Inc(Result, E.Value);
  until E.Value < 64;
end;

function TFaxDecoder.AddChange(A: Integer): Boolean;
begin
  // a valid line has at most Columns + 1 changing elements
  Result := NCur <= Columns + 1;
  if Result then
  begin
    Cur[NCur] := A;
    Inc(NCur);
  end;
end;

// Sentinels after the last changing element, so b1/b2 lookups stop at Columns
procedure TFaxDecoder.CloseLine;
var
  I: Integer;
begin
  for I := 0 to 3 do
    Cur[NCur + I] := Columns;
end;

// One-dimensional row (T.4 4.1): alternating white / black runs
function TFaxDecoder.Decode1D: Boolean;
var
  A0, Run: Integer;
  White: Boolean;
begin
  Result := False;
  NCur := 0;
  A0 := 0;
  White := True;
  while A0 < Columns do
  begin
    Run := ReadRun(White);
    if Run < 0 then Exit;
    A0 := Min(A0 + Run, Columns);
    if not AddChange(A0) then Exit;
    White := not White;
  end;
  CloseLine;
  Result := True;
end;

// Two-dimensional row (T.4 4.2, T.6 2.2) coded against the reference line Ref
function TFaxDecoder.Decode2D: Boolean;
var
  A0, A1, A2, B1, B2, J, R1, R2, Color: Integer;
  E: TCodeEntry;
begin
  Result := False;
  NCur := 0;
  A0 := -1;          // imaginary white element before the first pixel
  Color := 0;        // 0 = white, 1 = black: colour of a0
  J := 0;
  while A0 < Columns do
  begin
    if AtEnd then Exit;
    E := ModeTab[Peek(MODE_BITS)];
    if E.Len = 0 then Exit;   // EOL or bad data inside the row
    Eat(E.Len);

    // b1: first changing element of the reference line to the right of a0
    // with the colour opposite to a0's (even indexes change to black);
    // b2: the next one
    while Ref[J] <= A0 do Inc(J);
    B1 := J;
    if (B1 and 1) <> Color then Inc(B1);
    B2 := Ref[B1 + 1];
    B1 := Ref[B1];

    case E.Value of
      MODE_PASS:
        A0 := B2;
      MODE_HORZ:
        begin
          if A0 < 0 then A0 := 0;
          R1 := ReadRun(Color = 0);
          if R1 < 0 then Exit;
          R2 := ReadRun(Color <> 0);
          if R2 < 0 then Exit;
          A1 := Min(A0 + R1, Columns);
          A2 := Min(A1 + R2, Columns);
          if not (AddChange(A1) and AddChange(A2)) then Exit;
          A0 := A2;
        end;
      MODE_EXT:
        Exit;      // uncompressed mode: not supported
    else
      begin        // vertical mode, offset E.Value
        A1 := B1 + E.Value;
        if A1 > Columns then A1 := Columns;
        if A1 < Max(A0, 0) then Exit;
        if not AddChange(A1) then Exit;
        A0 := A1;
        Color := 1 - Color;
      end;
    end;
  end;
  CloseLine;
  Result := True;
end;

// Writes one row from the changing elements in AChanges
procedure EmitRow(var AOut: TBytes; AOffset: Integer;
  const AChanges: TArray<Integer>; ACount, AColumns, ARowBytes: Integer;
  ABlackIs1: Boolean);
var
  I, X, X0, X1: Integer;
  Mask: Byte;
begin
  if ABlackIs1 then FillChar(AOut[AOffset], ARowBytes, 0)
  else FillChar(AOut[AOffset], ARowBytes, $FF);
  I := 0;
  while I < ACount do
  begin
    X0 := AChanges[I];
    if I + 1 < ACount then X1 := AChanges[I + 1] else X1 := AColumns;
    X1 := Min(X1, AColumns);
    Inc(I, 2);
    X := X0;
    while X < X1 do
    begin
      if ((X and 7) = 0) and (X + 8 <= X1) then
      begin
        if ABlackIs1 then AOut[AOffset + X shr 3] := $FF
        else AOut[AOffset + X shr 3] := 0;
        Inc(X, 8);
      end
      else
      begin
        Mask := $80 shr (X and 7);
        if ABlackIs1 then
          AOut[AOffset + X shr 3] := AOut[AOffset + X shr 3] or Mask
        else
          AOut[AOffset + X shr 3] := AOut[AOffset + X shr 3] and not Mask;
        Inc(X);
      end;
    end;
  end;
end;

function CCITTFaxDecode(const AData: TBytes;
  const AParams: TCCITTFaxParams): TBytes;
var
  Rows: Integer;
begin
  Result := CCITTFaxDecode(AData, AParams, Rows);
end;

function CCITTFaxDecode(const AData: TBytes;
  const AParams: TCCITTFaxParams; out ARows: Integer): TBytes;
var
  Consumed: Integer;
begin
  Result := CCITTFaxDecode(AData, AParams, ARows, Consumed);
end;

function CCITTFaxDecode(const AData: TBytes;
  const AParams: TCCITTFaxParams; out ARows, AConsumed: Integer): TBytes;
var
  D: TFaxDecoder;
  RowBytes, Row, NRef, Cap: Integer;
  P0: Int64;
  GotEOL, Use2D, OK: Boolean;
  Tmp: TArray<Integer>;
begin
  if AParams.Columns <= 0 then
    raise ECCITTFaxError.Create('CCITTFax: invalid Columns');
  D.Data    := AData;
  D.NBits   := Int64(Length(AData)) * 8;
  D.Pos     := 0;
  D.Columns := AParams.Columns;
  SetLength(D.Ref, D.Columns + 8);
  SetLength(D.Cur, D.Columns + 8);
  // the line before the first one is all white
  NRef := 0;
  D.NCur := 0;
  D.CloseLine;
  Tmp := D.Ref; D.Ref := D.Cur; D.Cur := Tmp;

  RowBytes := (D.Columns + 7) div 8;
  if AParams.Rows > 0 then Cap := AParams.Rows
  else Cap := Max(16, Length(AData) div Max(1, RowBytes div 8));
  SetLength(Result, Int64(Cap) * RowBytes);
  Row := 0;

  while (AParams.Rows <= 0) or (Row < AParams.Rows) do
  begin
    // Row start: fill bits and EOL, or byte alignment; end of block; tag bit.
    // Fill bits are zeros and no code starts with 12 zeros, so skipping
    // them never eats into row data.  EncodedByteAlign: without EOLs
    // (Group 4, or EndOfLine false) every row starts on a byte boundary, and
    // aligning first matters because the padding plus the leading zeros of
    // a code can look like an EOL; with EOLs, the fill bits make the EOL end
    // on a byte boundary (its zeros may start before one), so rows are
    // aligned only when no EOL is found.
    if AParams.EncodedByteAlign and ((AParams.K < 0) or not AParams.EndOfLine) then
      D.Align;
    P0 := D.Pos;
    while (not D.AtEnd) and (D.Peek(12) = 0) do D.Eat(1);
    GotEOL := (not D.AtEnd) and (D.Peek(12) = 1);
    if (not GotEOL) and AParams.EncodedByteAlign then
    begin
      D.Pos := P0;
      D.Align;
      while (not D.AtEnd) and (D.Peek(12) = 0) do D.Eat(1);
    end;
    if D.AtEnd then Break;
    if GotEOL then
    begin
      D.Eat(12);
      // EOFB (T.6) = EOL EOL; RTC (T.4) = 6 x EOL, each with a tag bit 1 in 2-D
      if AParams.K > 0 then
      begin
        if D.Peek(13) = $1001 then Break;
      end
      else if D.Peek(12) = 1 then Break;
      if D.AtEnd then Break;
    end;
    Use2D := AParams.K < 0;
    if AParams.K > 0 then
    begin
      Use2D := D.Peek(1) = 0;
      D.Eat(1);
    end;

    if Use2D then OK := D.Decode2D else OK := D.Decode1D;

    if Row >= Cap then
    begin
      Cap := Cap * 2;
      SetLength(Result, Int64(Cap) * RowBytes);
    end;

    if OK then
    begin
      EmitRow(Result, Row * RowBytes, D.Cur, D.NCur, D.Columns, RowBytes,
        AParams.BlackIs1);
      NRef := D.NCur;
      Tmp := D.Ref; D.Ref := D.Cur; D.Cur := Tmp;
      Inc(Row);
    end
    else
    begin
      // Damaged row: Group 3 resynchronises on the next EOL and repeats
      // the previous row; Group 4 cannot, so decoding ends here.
      if AParams.K < 0 then Break;
      while (not D.AtEnd) and (D.Peek(12) <> 1) do D.Eat(1);
      if D.AtEnd then Break;
      EmitRow(Result, Row * RowBytes, D.Ref, NRef, D.Columns, RowBytes,
        AParams.BlackIs1);
      Inc(Row);
    end;
  end;

  if Row = 0 then
    raise ECCITTFaxError.Create('CCITTFax: no row could be decoded');
  // an EOFB right after the last row belongs to the data
  if (AParams.Rows > 0) and (Row = AParams.Rows) and (D.Peek(24) = $001001) then
    D.Eat(24);
  AConsumed := Integer(Min(Int64(Length(AData)), (D.Pos + 7) div 8));
  if AParams.Rows > 0 then
  begin
    // missing rows are white
    if Cap < AParams.Rows then SetLength(Result, Int64(AParams.Rows) * RowBytes);
    while Row < AParams.Rows do
    begin
      EmitRow(Result, Row * RowBytes, nil, 0, D.Columns, RowBytes,
        AParams.BlackIs1);
      Inc(Row);
    end;
  end;
  SetLength(Result, Int64(Row) * RowBytes);
  ARows := Row;
end;

initialization
  BuildTables;

end.
