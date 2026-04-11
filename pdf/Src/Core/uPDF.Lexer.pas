unit uPDF.Lexer;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes,
  uPDF.Types, uPDF.Errors;

type
  // -------------------------------------------------------------------------
  // Token types produced by the lexer
  // -------------------------------------------------------------------------
  TPDFTokenKind = (
    EndOfFile,
    // Scalar values
    BooleanTrue,   // true
    BooleanFalse,  // false
    Null,          // null
    Integer,       // 123, -456
    Real,          // 3.14, -0.5
    LiteralString, // (...)
    HexString,     // <...>
    Name,          // /Name
    // Structural
    ArrayOpen,     // [
    ArrayClose,    // ]
    DictOpen,      // <<
    DictClose,     // >>
    // Indirect object markers
    ObjBegin,      // obj
    ObjEnd,        // endobj
    StreamBegin,   // stream
    StreamEnd,     // endstream
    // Cross-reference / trailer keywords
    XRef,          // xref
    Trailer,       // trailer
    StartXRef,     // startxref
    // Inline image markers
    InlineImageBegin, // BI
    InlineImageData,  // ID
    InlineImageEnd,   // EI
    // Generic keyword (operators in content streams, unknown keywords)
    Keyword
  );

  TPDFToken = record
    Kind:    TPDFTokenKind;
    Value:   string;         // Decoded string value (Name without '/', string decoded)
    RawData: RawByteString;  // Raw bytes (strings, hex strings)
    IntVal:  Int64;          // For Integer tokens
    RealVal: Double;         // For Real tokens
    Offset:  Int64;          // Byte offset in stream where token starts
  end;

  // -------------------------------------------------------------------------
  // Low-level PDF byte scanner / lexer
  //
  // Operates on any TStream (file, memory, decompressed content stream).
  // Does NOT own the stream. Caller manages lifetime.
  // -------------------------------------------------------------------------
  TPDFLexer = class
  private
    FStream:      TStream;
    FBuf:         TBytes;
    FBufSize:     Integer;
    FBufPos:      Integer;
    FStreamBase:  Int64;  // FStream.Position when lexer was created
    FPosition:    Int64;  // logical position in the stream (from FStreamBase)
    FOwnsStream:  Boolean;
    FPushedToken: TPDFToken;
    FHasPushedToken: Boolean;

    function  FillBuffer: Boolean;
    function  PeekByte: Integer;            // -1 = EOF
    function  ReadByte: Integer;            // -1 = EOF; advances position
    procedure UnreadByte;                   // rewind one byte
    function  SkipWhitespaceAndComments: Boolean; // returns False on EOF

    function  ReadLiteralString: TPDFToken;
    function  ReadHexString: TPDFToken;
    function  ReadName: TPDFToken;
    function  ReadNumberOrKeyword(AFirstByte: Byte): TPDFToken;
    function  IsWhitespace(AB: Byte): Boolean;
    function  IsDelimiter(AB: Byte): Boolean;
    function  IsDigit(AB: Byte): Boolean; inline;

    class function DecodeNameEscape(const ARaw: string): string; static;
    class function DecodeOctal(const S: string; var AIdx: Integer): Char; static;
  public
    constructor Create(AStream: TStream; AOwnsStream: Boolean = False);
    destructor  Destroy; override;

    // Read the next token; returns a token with Kind=EndOfFile at end
    function  NextToken: TPDFToken;
    // Peek at next token without consuming it
    function  PeekToken: TPDFToken;
    // Push a token back so it is returned by the next NextToken call
    procedure PushBack(const ATok: TPDFToken);

    // Skip raw bytes (used for stream body reading)
    procedure SkipBytes(ACount: Int64);
    // Read raw bytes directly (for stream body, after 'stream' keyword)
    function  ReadRawBytes(ACount: Int64): TBytes;

    // Seek to absolute offset in the underlying stream
    procedure SeekTo(AOffset: Int64);
    // Current byte position
    function  Position: Int64;
    // Total stream size
    function  StreamSize: Int64;

    // Utility: skip to end of current line (CR, LF, CRLF)
    procedure SkipToEOL;
    // Read rest of current line as string
    function  ReadLine: string;
    // Find the last occurrence of AMarker searching backwards from AStartPos
    function  FindLastMarker(const AMarker: string; AStartPos: Int64): Int64;
  end;

implementation

uses
  System.Math;

const
  BUFFER_SIZE = 65536;

  // PDF whitespace characters (spec Table 1)
  PDF_WS: set of Byte = [0, 9, 10, 12, 13, 32];

  // PDF delimiter characters (spec Table 2)
  PDF_DELIM: set of Byte = [
    Ord('('), Ord(')'), Ord('<'), Ord('>'), Ord('['), Ord(']'),
    Ord('{'), Ord('}'), Ord('/'), Ord('%')
  ];

// =========================================================================
// TPDFLexer
// =========================================================================

constructor TPDFLexer.Create(AStream: TStream; AOwnsStream: Boolean);
begin
  inherited Create;
  FStream      := AStream;
  FOwnsStream  := AOwnsStream;
  FStreamBase  := AStream.Position;
  FPosition    := 0;
  FBufSize     := 0;
  FBufPos      := 0;
  SetLength(FBuf, BUFFER_SIZE);
end;

destructor TPDFLexer.Destroy;
begin
  if FOwnsStream then
    FStream.Free;
  inherited;
end;

function TPDFLexer.Position: Int64;
begin
  Result := FPosition;
end;

function TPDFLexer.StreamSize: Int64;
begin
  Result := FStream.Size - FStreamBase;
end;

procedure TPDFLexer.SeekTo(AOffset: Int64);
begin
  FStream.Position := FStreamBase + AOffset;
  FPosition        := AOffset;
  FBufSize         := 0;
  FBufPos          := 0;
end;

function TPDFLexer.FillBuffer: Boolean;
begin
  FStream.Position := FStreamBase + FPosition;
  FBufSize := FStream.Read(FBuf[0], BUFFER_SIZE);
  FBufPos  := 0;
  Result   := FBufSize > 0;
end;

function TPDFLexer.PeekByte: Integer;
begin
  if FBufPos >= FBufSize then
    if not FillBuffer then
      Exit(-1);
  Result := FBuf[FBufPos];
end;

function TPDFLexer.ReadByte: Integer;
begin
  if FBufPos >= FBufSize then
    if not FillBuffer then
      Exit(-1);
  Result := FBuf[FBufPos];
  Inc(FBufPos);
  Inc(FPosition);
end;

procedure TPDFLexer.UnreadByte;
begin
  if FBufPos > 0 then
  begin
    Dec(FBufPos);
    Dec(FPosition);
  end else
  begin
    // Need to step back in file — rare case
    Dec(FPosition);
    SeekTo(FPosition);
  end;
end;

function TPDFLexer.IsWhitespace(AB: Byte): Boolean;
begin
  Result := AB in PDF_WS;
end;

function TPDFLexer.IsDelimiter(AB: Byte): Boolean;
begin
  Result := AB in PDF_DELIM;
end;

function TPDFLexer.IsDigit(AB: Byte): Boolean;
begin
  Result := (AB >= Ord('0')) and (AB <= Ord('9'));
end;

function TPDFLexer.SkipWhitespaceAndComments: Boolean;
var
  B: Integer;
begin
  Result := False;
  repeat
    B := PeekByte;
    if B = -1 then Exit;

    if B in PDF_WS then
    begin
      ReadByte;
    end
    else if B = Ord('%') then
    begin
      // Comment: skip to EOL
      ReadByte;
      repeat
        B := ReadByte;
        if B = -1 then Exit;
      until B in [10, 13]; // LF or CR
      // Handle CR+LF
      if (B = 13) and (PeekByte = 10) then
        ReadByte;
    end
    else
    begin
      Result := True;
      Exit;
    end;
  until False;
end;

procedure TPDFLexer.SkipToEOL;
var
  B: Integer;
begin
  repeat
    B := ReadByte;
    if B = -1 then Break;
  until B in [10, 13];
  if (B = 13) and (PeekByte = 10) then
    ReadByte;
end;

function TPDFLexer.ReadLine: string;
var
  SB: TStringBuilder;
  B:  Integer;
begin
  SB := TStringBuilder.Create;
  try
    repeat
      B := ReadByte;
      if B = -1 then Break;
      if B in [10, 13] then
      begin
        if (B = 13) and (PeekByte = 10) then
          ReadByte;
        Break;
      end;
      SB.Append(Char(B));
    until False;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TPDFLexer.ReadLiteralString: TPDFToken;
var
  SB:     TStringBuilder;
  Bytes:  TStringBuilder;
  B:      Integer;
  Depth:  Integer;
  Octal:  string;
begin
  Result.Kind   := TPDFTokenKind.LiteralString;
  Result.Offset := FPosition - 1; // '(' already consumed

  SB    := TStringBuilder.Create;
  Bytes := TStringBuilder.Create;
  Depth := 1;
  try
    while Depth > 0 do
    begin
      B := ReadByte;
      if B = -1 then
        raise EPDFLexError.Create('Unexpected EOF in literal string');

      case B of
        Ord('('):
        begin
          Inc(Depth);
          Bytes.Append(Char(B));
        end;
        Ord(')'):
        begin
          Dec(Depth);
          if Depth > 0 then
            Bytes.Append(Char(B));
        end;
        Ord('\'):
        begin
          B := ReadByte;
          if B = -1 then
            raise EPDFLexError.Create('Unexpected EOF in string escape');
          case B of
            Ord('n'):  Bytes.Append(#10);
            Ord('r'):  Bytes.Append(#13);
            Ord('t'):  Bytes.Append(#9);
            Ord('b'):  Bytes.Append(#8);
            Ord('f'):  Bytes.Append(#12);
            Ord('('):  Bytes.Append('(');
            Ord(')'):  Bytes.Append(')');
            Ord('\'):  Bytes.Append('\');
            10: {LF - escaped newline, ignore};
            13:
            begin  // CR or CRLF — escaped newline
              if PeekByte = 10 then ReadByte;
            end;
            Ord('0')..Ord('7'):
            begin
              // Octal escape: 1-3 digits
              Octal := Char(B);
              if IsDigit(PeekByte) and (PeekByte <= Ord('7')) then
              begin
                Octal := Octal + Char(ReadByte);
                if IsDigit(PeekByte) and (PeekByte <= Ord('7')) then
                  Octal := Octal + Char(ReadByte);
              end;
              Bytes.Append(Char(StrToInt('$' + IntToHex(StrToInt(Octal), 2))));
              // Actually parse as octal:
              var OctalVal := 0;
              for var C in Octal do
                OctalVal := OctalVal * 8 + (Ord(C) - Ord('0'));
              // Replace what we just appended with correct value
              Bytes.Remove(Bytes.Length - 1, 1);
              Bytes.Append(Char(OctalVal));
            end;
          else
            Bytes.Append(Char(B));
          end;
        end;
        13:
        begin
          // Normalize CR and CRLF to LF
          if PeekByte = 10 then ReadByte;
          Bytes.Append(#10);
        end;
      else
        Bytes.Append(Char(B));
      end;
    end;

    var S := Bytes.ToString;
    SetLength(Result.RawData, S.Length);
    for var I := 1 to S.Length do
      Result.RawData[I] := AnsiChar(Ord(S[I]) and $FF);
    Result.Value := S;
  finally
    SB.Free;
    Bytes.Free;
  end;
end;

function TPDFLexer.ReadHexString: TPDFToken;
var
  SB:  TStringBuilder;
  B:   Integer;
  Hi:  Integer;
  Lo:  Integer;
begin
  Result.Kind   := TPDFTokenKind.HexString;
  Result.Offset := FPosition - 1;

  SB := TStringBuilder.Create;
  try
    Hi := -1;
    repeat
      B := ReadByte;
      if B = -1 then
        raise EPDFLexError.Create('Unexpected EOF in hex string');
      if B = Ord('>') then
      begin
        if Hi >= 0 then
          SB.Append(Char(Hi shl 4)); // odd nibble: pad with 0
        Break;
      end;
      if B in PDF_WS then Continue;
      var Nibble: Integer;
      if (B >= Ord('0')) and (B <= Ord('9')) then Nibble := B - Ord('0')
      else if (B >= Ord('a')) and (B <= Ord('f')) then Nibble := B - Ord('a') + 10
      else if (B >= Ord('A')) and (B <= Ord('F')) then Nibble := B - Ord('A') + 10
      else raise EPDFLexError.CreateFmt('Invalid hex digit: %s', [Char(B)]);

      if Hi < 0 then
        Hi := Nibble
      else
      begin
        Lo := Nibble;
        SB.Append(Char((Hi shl 4) or Lo));
        Hi := -1;
      end;
    until False;

    var S := SB.ToString;
    SetLength(Result.RawData, S.Length);
    for var I := 1 to S.Length do
      Result.RawData[I] := AnsiChar(Ord(S[I]) and $FF);
    Result.Value := S;
  finally
    SB.Free;
  end;
end;

function TPDFLexer.ReadName: TPDFToken;
var
  SB: TStringBuilder;
  B:  Integer;
begin
  Result.Kind   := TPDFTokenKind.Name;
  Result.Offset := FPosition - 1;

  SB := TStringBuilder.Create;
  try
    repeat
      B := PeekByte;
      if (B = -1) or (B in PDF_WS) or (B in PDF_DELIM) then Break;
      ReadByte;
      if B = Ord('#') then
      begin
        // Hex escape in name: #XX
        var H1 := ReadByte;
        var H2 := ReadByte;
        if (H1 = -1) or (H2 = -1) then
          raise EPDFLexError.Create('Unexpected EOF in name escape');
        var HexStr := Char(H1) + Char(H2);
        try
          SB.Append(Char(StrToInt('$' + HexStr)));
        except
          raise EPDFLexError.CreateFmt('Invalid name escape: #%s', [HexStr]);
        end;
      end else
        SB.Append(Char(B));
    until False;

    Result.Value := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TPDFLexer.ReadNumberOrKeyword(AFirstByte: Byte): TPDFToken;
var
  SB:       TStringBuilder;
  B:        Integer;
  HasDot:   Boolean;
  HasSign:  Boolean;
begin
  Result.Offset := FPosition - 1;
  SB := TStringBuilder.Create;
  try
    SB.Append(Char(AFirstByte));
    HasDot  := (AFirstByte = Ord('.'));
    HasSign := (AFirstByte in [Ord('+'), Ord('-')]);

    repeat
      B := PeekByte;
      if (B = -1) or (B in PDF_WS) or (B in PDF_DELIM) then Break;
      ReadByte;
      if B = Ord('.') then
        HasDot := True;
      SB.Append(Char(B));
    until False;

    var S := SB.ToString;

    // Is it a number?
    if IsDigit(AFirstByte)
       or (HasSign and (SB.Length > 1))
       or (HasDot and (SB.Length > 1)) then
    begin
      if HasDot then
      begin
        var V: Double;
        if TryStrToFloat(S.Replace('.', FormatSettings.DecimalSeparator), V) then
        begin
          Result.Kind    := TPDFTokenKind.Real;
          Result.RealVal := V;
          Result.Value   := S;
          Exit;
        end;
      end else if not HasDot then
      begin
        var V: Int64;
        if TryStrToInt64(S, V) then
        begin
          Result.Kind   := TPDFTokenKind.Integer;
          Result.IntVal := V;
          Result.Value  := S;
          Exit;
        end;
      end;
    end;

    // Keyword
    Result.Kind  := TPDFTokenKind.Keyword;
    Result.Value := S;

    // Map known keywords
    if S = 'true'        then Result.Kind := TPDFTokenKind.BooleanTrue
    else if S = 'false'  then Result.Kind := TPDFTokenKind.BooleanFalse
    else if S = 'null'   then Result.Kind := TPDFTokenKind.Null
    else if S = 'obj'    then Result.Kind := TPDFTokenKind.ObjBegin
    else if S = 'endobj' then Result.Kind := TPDFTokenKind.ObjEnd
    else if S = 'stream' then Result.Kind := TPDFTokenKind.StreamBegin
    else if S = 'endstream' then Result.Kind := TPDFTokenKind.StreamEnd
    else if S = 'xref'   then Result.Kind := TPDFTokenKind.XRef
    else if S = 'trailer' then Result.Kind := TPDFTokenKind.Trailer
    else if S = 'startxref' then Result.Kind := TPDFTokenKind.StartXRef
    else if S = 'BI'     then Result.Kind := TPDFTokenKind.InlineImageBegin
    else if S = 'ID'     then Result.Kind := TPDFTokenKind.InlineImageData
    else if S = 'EI'     then Result.Kind := TPDFTokenKind.InlineImageEnd;
  finally
    SB.Free;
  end;
end;

function TPDFLexer.NextToken: TPDFToken;
var
  B: Integer;
begin
  if FHasPushedToken then
  begin
    Result := FPushedToken;
    FHasPushedToken := False;
    Exit;
  end;

  if not SkipWhitespaceAndComments then
  begin
    Result.Kind   := TPDFTokenKind.EndOfFile;
    Result.Offset := FPosition;
    Exit;
  end;

  Result.Offset := FPosition;
  B := ReadByte;

  case B of
    Ord('('):
      Result := ReadLiteralString;

    Ord('<'):
    begin
      if PeekByte = Ord('<') then
      begin
        ReadByte;
        Result.Kind   := TPDFTokenKind.DictOpen;
        Result.Value  := '<<';
        Result.Offset := FPosition - 2;
      end else
        Result := ReadHexString;
    end;

    Ord('>'):
    begin
      if PeekByte = Ord('>') then
      begin
        ReadByte;
        Result.Kind   := TPDFTokenKind.DictClose;
        Result.Value  := '>>';
        Result.Offset := FPosition - 2;
      end else
        raise EPDFLexError.CreateFmt('Unexpected ">" at offset %d', [FPosition]);
    end;

    Ord('['):
    begin
      Result.Kind  := TPDFTokenKind.ArrayOpen;
      Result.Value := '[';
    end;

    Ord(']'):
    begin
      Result.Kind  := TPDFTokenKind.ArrayClose;
      Result.Value := ']';
    end;

    Ord('/'):
      Result := ReadName;

  else
    Result := ReadNumberOrKeyword(B);
  end;
end;

function TPDFLexer.PeekToken: TPDFToken;
var
  SavePos: Int64;
begin
  SavePos := FPosition;
  var SaveBufPos := FBufPos;
  var SaveBufSize := FBufSize;
  var SaveHasPushedToken := FHasPushedToken;
  var SavePushedToken    := FPushedToken;
  Result := NextToken;
  // Restore state (including any pushed token that NextToken may have consumed)
  FPosition       := SavePos;
  FBufPos         := SaveBufPos;
  FBufSize        := SaveBufSize;
  FStream.Position := FStreamBase + FPosition;
  FHasPushedToken := SaveHasPushedToken;
  FPushedToken    := SavePushedToken;
end;

procedure TPDFLexer.PushBack(const ATok: TPDFToken);
begin
  FPushedToken := ATok;
  FHasPushedToken := True;
end;

procedure TPDFLexer.SkipBytes(ACount: Int64);
begin
  SeekTo(FPosition + ACount);
end;

function TPDFLexer.ReadRawBytes(ACount: Int64): TBytes;
begin
  SetLength(Result, ACount);
  if ACount = 0 then Exit;

  // Flush buffer and read directly
  var Remaining := ACount;
  var OutPos    := 0;

  // First drain what's in the buffer
  var InBuf := FBufSize - FBufPos;
  if InBuf > 0 then
  begin
    var Take := Min(InBuf, Remaining);
    Move(FBuf[FBufPos], Result[OutPos], Take);
    Inc(FBufPos, Take);
    Inc(FPosition, Take);
    Inc(OutPos, Take);
    Dec(Remaining, Take);
  end;

  // Then read directly from stream
  if Remaining > 0 then
  begin
    FStream.Position := FStreamBase + FPosition;
    var Read := FStream.Read(Result[OutPos], Remaining);
    Inc(FPosition, Read);
    FBufSize := 0;
    FBufPos  := 0;
    if Read < Remaining then
      raise EPDFStreamError.CreateFmt(
        'Unexpected EOF reading %d bytes (got %d)', [ACount, OutPos + Read]);
  end;
end;

function TPDFLexer.FindLastMarker(const AMarker: string; AStartPos: Int64): Int64;
const
  SEARCH_BUF = 1024;
var
  Buf:     TBytes;
  SearchFrom: Int64;
  BufLen:  Integer;
begin
  Result := -1;
  SetLength(Buf, SEARCH_BUF + System.Length(AMarker));

  var MarkerBytes: TBytes;
  SetLength(MarkerBytes, System.Length(AMarker));
  for var I := 0 to High(MarkerBytes) do
    MarkerBytes[I] := Ord(AMarker[I+1]);

  SearchFrom := AStartPos;

  while SearchFrom >= 0 do
  begin
    var ReadStart := Max(0, SearchFrom - SEARCH_BUF);
    BufLen := SearchFrom - ReadStart;
    if BufLen = 0 then Break;

    FStream.Position := FStreamBase + ReadStart;
    FStream.Read(Buf[0], BufLen);

    // Search backwards in buf for marker
    for var I := BufLen - System.Length(AMarker) downto 0 do
    begin
      var Found := True;
      for var J := 0 to High(MarkerBytes) do
        if Buf[I + J] <> MarkerBytes[J] then
        begin
          Found := False;
          Break;
        end;
      if Found then
      begin
        Result := ReadStart + I;
        Exit;
      end;
    end;

    SearchFrom := ReadStart;
  end;
end;

class function TPDFLexer.DecodeNameEscape(const ARaw: string): string;
begin
  // Already handled inline in ReadName
  Result := ARaw;
end;

class function TPDFLexer.DecodeOctal(const S: string; var AIdx: Integer): Char;
var
  V: Integer;
begin
  V := 0;
  var Count := 0;
  while (AIdx <= S.Length) and (Count < 3) do
  begin
    var C := S[AIdx];
    if (C >= '0') and (C <= '7') then
    begin
      V := V * 8 + (Ord(C) - Ord('0'));
      Inc(AIdx);
      Inc(Count);
    end else
      Break;
  end;
  Result := Char(V);
end;

end.
