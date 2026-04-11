unit uPDF.XRef;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Lexer;

type
  // -------------------------------------------------------------------------
  // Cross-reference table
  // Handles classic 'xref' tables, PDF 1.5+ XRef streams, and incremental
  // updates (/Prev chains).  Thread-safety is NOT guaranteed (single-use).
  // -------------------------------------------------------------------------
  TPDFXRef = class
  private
    FEntries:          TDictionary<Integer, TPDFXRefEntry>;
    FTrailer:          TPDFDictionary;
    FHighestObjNum:    Integer;

    procedure ParseClassicXRef(ALexer: TPDFLexer);
    procedure ParseXRefStream(ARawData: TBytes; ADict: TPDFDictionary);
    procedure MergeTrailer(ADict: TPDFDictionary);

    // Mini object parser (avoids circular dep with uPDF.Parser)
    class function ParseValue(ALexer: TPDFLexer): TPDFObject; static;
    class function ParseArray(ALexer: TPDFLexer): TPDFArray; static;
    class function ParseDict(ALexer: TPDFLexer): TPDFDictionary; static;
  public
    constructor Create;
    destructor  Destroy; override;

    // Parse the XRef chain starting at AStartXRefOffset.
    // ALexer must be positioned at the beginning of the file (SeekTo(0) done internally).
    procedure Parse(ALexer: TPDFLexer; AStartXRefOffset: Int64);

    function  TryGetEntry(AObjNum: Integer; out AEntry: TPDFXRefEntry): Boolean;
    function  GetEntry(AObjNum: Integer): TPDFXRefEntry;

    function  Trailer: TPDFDictionary;
    function  HighestObjectNumber: Integer;
    function  Count: Integer;
    procedure ForEach(AProc: TProc<Integer, TPDFXRefEntry>);

    // For writer: build XRef from scratch
    procedure Clear;
    procedure SetEntry(AObjNum, AGeneration: Integer; AType: TPDFXRefEntryType;
      AOffset: Int64; AIndexInStream: Integer = 0);
    procedure SetTrailer(ADict: TPDFDictionary);
  end;

implementation

uses
  System.Math;

// =========================================================================
// Constructor / Destructor
// =========================================================================

constructor TPDFXRef.Create;
begin
  inherited;
  FEntries       := TDictionary<Integer, TPDFXRefEntry>.Create;
  FTrailer       := TPDFDictionary.Create;
  FHighestObjNum := 0;
end;

destructor TPDFXRef.Destroy;
begin
  FTrailer.Free;
  FEntries.Free;
  inherited;
end;

// =========================================================================
// Public API
// =========================================================================

procedure TPDFXRef.Clear;
begin
  FEntries.Clear;
  FTrailer.Free;
  FTrailer       := TPDFDictionary.Create;
  FHighestObjNum := 0;
end;

function TPDFXRef.Count: Integer;
begin
  Result := FEntries.Count;
end;

function TPDFXRef.HighestObjectNumber: Integer;
begin
  Result := FHighestObjNum;
end;

function TPDFXRef.Trailer: TPDFDictionary;
begin
  Result := FTrailer;
end;

function TPDFXRef.TryGetEntry(AObjNum: Integer; out AEntry: TPDFXRefEntry): Boolean;
begin
  Result := FEntries.TryGetValue(AObjNum, AEntry);
  if Result and (AEntry.EntryType = TPDFXRefEntryType.Free) then
    Result := False;
end;

function TPDFXRef.GetEntry(AObjNum: Integer): TPDFXRefEntry;
begin
  if not FEntries.TryGetValue(AObjNum, Result) then
    raise EPDFXRefError.CreateFmt('Object %d not found in XRef', [AObjNum]);
  if Result.EntryType = TPDFXRefEntryType.Free then
    raise EPDFXRefError.CreateFmt('Object %d is free', [AObjNum]);
end;

procedure TPDFXRef.SetEntry(AObjNum, AGeneration: Integer;
  AType: TPDFXRefEntryType; AOffset: Int64; AIndexInStream: Integer);
var
  E: TPDFXRefEntry;
begin
  E.EntryType     := AType;
  E.Offset        := AOffset;
  E.Generation    := AGeneration;
  E.IndexInStream := AIndexInStream;
  FEntries.AddOrSetValue(AObjNum, E);
  if AObjNum > FHighestObjNum then
    FHighestObjNum := AObjNum;
end;

procedure TPDFXRef.SetTrailer(ADict: TPDFDictionary);
begin
  FTrailer.Free;
  FTrailer := ADict;
end;

procedure TPDFXRef.ForEach(AProc: TProc<Integer, TPDFXRefEntry>);
begin
  for var Pair in FEntries do
    AProc(Pair.Key, Pair.Value);
end;

// =========================================================================
// Trailer merge: earlier updates do NOT override later ones
// =========================================================================

procedure TPDFXRef.MergeTrailer(ADict: TPDFDictionary);
begin
  ADict.ForEach(
    procedure(AKey: string; AValue: TPDFObject)
    begin
      if not FTrailer.Contains(AKey) then
        FTrailer.SetValue(AKey, AValue.Clone);
    end);
end;

// =========================================================================
// Mini object parser (avoids circular dependency with uPDF.Parser)
// Only parses values needed in trailer dicts: booleans, integers, reals,
// strings, names, arrays, dictionaries, and indirect references.
// =========================================================================

class function TPDFXRef.ParseValue(ALexer: TPDFLexer): TPDFObject;
var
  Tok:  TPDFToken;
  Tok2: TPDFToken;
  Tok3: TPDFToken;
begin
  Tok := ALexer.NextToken;
  case Tok.Kind of
    TPDFTokenKind.BooleanTrue:  Result := TPDFBoolean.Create(True);
    TPDFTokenKind.BooleanFalse: Result := TPDFBoolean.Create(False);
    TPDFTokenKind.Null:         Result := TPDFNull.Create;
    TPDFTokenKind.LiteralString:Result := TPDFString.Create(Tok.RawData, False);
    TPDFTokenKind.HexString:    Result := TPDFString.Create(Tok.RawData, True);
    TPDFTokenKind.Name:         Result := TPDFName.Create(Tok.Value);
    TPDFTokenKind.ArrayOpen:    Result := ParseArray(ALexer);
    TPDFTokenKind.DictOpen:     Result := ParseDict(ALexer);
    TPDFTokenKind.Real:         Result := TPDFReal.Create(Tok.RealVal);
    TPDFTokenKind.Integer:
    begin
      // Could be start of indirect reference: "N G R"
      Tok2 := ALexer.PeekToken;
      if Tok2.Kind = TPDFTokenKind.Integer then
      begin
        // Might be a reference — look one more ahead
        ALexer.NextToken; // consume second integer
        Tok3 := ALexer.PeekToken;
        if (Tok3.Kind = TPDFTokenKind.Keyword) and (Tok3.Value = 'R') then
        begin
          ALexer.NextToken; // consume 'R'
          Result := TPDFReference.CreateNum(Tok.IntVal, Tok2.IntVal);
        end else
        begin
          // Not a reference — push Tok2 back so it is not lost
          ALexer.PushBack(Tok2);
          Result := TPDFInteger.Create(Tok.IntVal);
        end;
      end else
        Result := TPDFInteger.Create(Tok.IntVal);
    end;
  else
    Result := TPDFNull.Create;
  end;
end;

class function TPDFXRef.ParseArray(ALexer: TPDFLexer): TPDFArray;
begin
  Result := TPDFArray.Create;
  try
    while True do
    begin
      var Tok := ALexer.PeekToken;
      if Tok.Kind in [TPDFTokenKind.ArrayClose, TPDFTokenKind.EndOfFile] then
      begin
        ALexer.NextToken;
        Break;
      end;
      Result.Add(ParseValue(ALexer));
    end;
  except
    Result.Free;
    raise;
  end;
end;

class function TPDFXRef.ParseDict(ALexer: TPDFLexer): TPDFDictionary;
begin
  // '<<' already consumed by caller
  Result := TPDFDictionary.Create;
  try
    while True do
    begin
      var Tok := ALexer.PeekToken;
      if Tok.Kind in [TPDFTokenKind.DictClose, TPDFTokenKind.EndOfFile] then
      begin
        ALexer.NextToken;
        Break;
      end;
      var KeyTok := ALexer.NextToken;
      if KeyTok.Kind <> TPDFTokenKind.Name then
        raise EPDFXRefError.CreateFmt(
          'Expected /Name key in dict, got "%s"', [KeyTok.Value]);
      Result.SetValue(KeyTok.Value, ParseValue(ALexer));
    end;
  except
    Result.Free;
    raise;
  end;
end;

// =========================================================================
// Parse classic xref table
// =========================================================================

procedure TPDFXRef.ParseClassicXRef(ALexer: TPDFLexer);
// 'xref' keyword was already consumed before calling this.
var
  First, Count: Integer;
  ObjNum:       Integer;
  Line:         string;
  Entry:        TPDFXRefEntry;
begin
  while True do
  begin
    var Tok := ALexer.PeekToken;
    if Tok.Kind in [TPDFTokenKind.Trailer, TPDFTokenKind.EndOfFile] then
      Break;
    if Tok.Kind <> TPDFTokenKind.Integer then
      raise EPDFXRefError.CreateFmt('Expected xref subsection first, got "%s"', [Tok.Value]);

    First := ALexer.NextToken.IntVal;
    var CntTok := ALexer.NextToken;
    if CntTok.Kind <> TPDFTokenKind.Integer then
      raise EPDFXRefError.Create('Expected xref subsection count');
    Count := CntTok.IntVal;

    // Skip EOL after "first count"
    ALexer.SkipToEOL;

    ObjNum := First;
    for var I := 0 to Count - 1 do
    begin
      Line := ALexer.ReadLine;
      // Lines are exactly 20 bytes in strict PDF but we tolerate less
      Line := Line.Trim;
      if Line = '' then
      begin
        Line := ALexer.ReadLine.Trim;
        if Line = '' then
          raise EPDFXRefError.CreateFmt('Empty xref line for object %d', [ObjNum]);
      end;

      if System.Length(Line) < 18 then
        raise EPDFXRefError.CreateFmt('Short xref line "%s" for object %d', [Line, ObjNum]);

      try
        Entry.Offset     := StrToInt64(Line.Substring(0, 10).Trim);
        Entry.Generation := StrToInt(Line.Substring(11, 5).Trim);
        var TypeChar := Line.Chars[17];
        if TypeChar = 'n' then
          Entry.EntryType := TPDFXRefEntryType.InUse
        else
          Entry.EntryType := TPDFXRefEntryType.Free;
        Entry.IndexInStream := 0;
      except
        on E: Exception do
          raise EPDFXRefError.CreateFmt(
            'Malformed xref line "%s" for object %d: %s', [Line, ObjNum, E.Message]);
      end;

      // Later sections (smaller Prev offset) do NOT override earlier (current file)
      if not FEntries.ContainsKey(ObjNum) then
      begin
        FEntries.Add(ObjNum, Entry);
        if ObjNum > FHighestObjNum then
          FHighestObjNum := ObjNum;
      end;
      Inc(ObjNum);
    end;
  end;
end;

// =========================================================================
// Parse XRef stream (PDF 1.5+)
// =========================================================================

procedure TPDFXRef.ParseXRefStream(ARawData: TBytes; ADict: TPDFDictionary);
var
  W:     array[0..2] of Integer;
  Data:  TBytes;
  Pos:   Integer;

  function ReadField(AWidth: Integer): Int64;
  begin
    Result := 0;
    for var I := 0 to AWidth - 1 do
    begin
      if Pos >= Length(Data) then
        raise EPDFXRefError.Create('Premature EOF in XRef stream data');
      Result := (Result shl 8) or Data[Pos];
      Inc(Pos);
    end;
  end;

begin
  // /W array
  var WArr := ADict.GetAsArray('W');
  if (WArr = nil) or (WArr.Count < 3) then
    raise EPDFXRefError.Create('XRef stream missing /W array');
  W[0] := WArr.GetAsInteger(0);
  W[1] := WArr.GetAsInteger(1);
  W[2] := WArr.GetAsInteger(2);

  if W[1] = 0 then
    raise EPDFXRefError.Create('XRef stream /W field 2 (offset) width is 0');

  // Decode stream data (apply filters)
  // Build a temporary stream object to leverage TPDFStream.DecodedBytes
  var TmpStream := TPDFStream.Create;
  try
    // Copy filter info from dict
    var FilterObj := ADict.RawGet('Filter');
    if FilterObj <> nil then
      TmpStream.Dict.SetValue('Filter', FilterObj.Clone);
    var ParmsObj := ADict.RawGet('DecodeParms');
    if ParmsObj <> nil then
      TmpStream.Dict.SetValue('DecodeParms', ParmsObj.Clone);
    TmpStream.Dict.SetValue('Length', TPDFInteger.Create(Length(ARawData)));
    TmpStream.SetRawData(ARawData);
    Data := TmpStream.DecodedBytes;
  finally
    TmpStream.Free;
  end;

  Pos := 0;

  // /Index subsections
  var IndexArr := ADict.GetAsArray('Index');
  var Sections: TArray<Integer>;
  if (IndexArr <> nil) and (IndexArr.Count >= 2) then
  begin
    SetLength(Sections, IndexArr.Count);
    for var I := 0 to IndexArr.Count - 1 do
      Sections[I] := IndexArr.GetAsInteger(I);
  end else
  begin
    SetLength(Sections, 2);
    Sections[0] := 0;
    Sections[1] := ADict.GetAsInteger('Size');
  end;

  var SI := 0;
  while SI < Length(Sections) - 1 do
  begin
    var First := Sections[SI];
    var Count := Sections[SI + 1];
    Inc(SI, 2);

    for var I := 0 to Count - 1 do
    begin
      var ObjNum := First + I;
      var T1 := ReadField(W[0]);
      var T2 := ReadField(W[1]);
      var T3 := ReadField(W[2]);

      if FEntries.ContainsKey(ObjNum) then Continue;

      var Entry: TPDFXRefEntry;
      case T1 of
        0: begin
             Entry.EntryType     := TPDFXRefEntryType.Free;
             Entry.Offset        := T2;
             Entry.Generation    := T3;
             Entry.IndexInStream := 0;
           end;
        1: begin
             Entry.EntryType     := TPDFXRefEntryType.InUse;
             Entry.Offset        := T2;
             Entry.Generation    := T3;
             Entry.IndexInStream := 0;
           end;
        2: begin
             Entry.EntryType     := TPDFXRefEntryType.Compressed;
             Entry.Offset        := T2; // container object number
             Entry.Generation    := 0;
             Entry.IndexInStream := T3;
           end;
      else
        Entry.EntryType     := TPDFXRefEntryType.Free;
        Entry.Offset        := 0;
        Entry.Generation    := 0;
        Entry.IndexInStream := 0;
      end;

      FEntries.Add(ObjNum, Entry);
      if ObjNum > FHighestObjNum then
        FHighestObjNum := ObjNum;
    end;
  end;
end;

// =========================================================================
// Main parse entry point
// =========================================================================

procedure TPDFXRef.Parse(ALexer: TPDFLexer; AStartXRefOffset: Int64);
var
  Visited: TList<Int64>;
  Offset:  Int64;
begin
  Visited := TList<Int64>.Create;
  try
    Offset := AStartXRefOffset;

    while Offset >= 0 do
    begin
      if Visited.Contains(Offset) then
        raise EPDFXRefError.CreateFmt('Circular /Prev chain at offset %d', [Offset]);
      Visited.Add(Offset);

      ALexer.SeekTo(Offset);
      var Tok := ALexer.NextToken;

      if Tok.Kind = TPDFTokenKind.XRef then
      begin
        // ---- Classic xref table ----
        ParseClassicXRef(ALexer);

        // Consume 'trailer' keyword
        var TrTok := ALexer.NextToken;
        if TrTok.Kind <> TPDFTokenKind.Trailer then
          raise EPDFXRefError.CreateFmt(
            'Expected "trailer" after xref table, got "%s"', [TrTok.Value]);

        // Parse trailer dict
        var OpenTok := ALexer.NextToken;
        if OpenTok.Kind <> TPDFTokenKind.DictOpen then
          raise EPDFXRefError.Create('Expected << after "trailer"');

        var TrailerDict := ParseDict(ALexer);
        MergeTrailer(TrailerDict);

        Offset := TrailerDict.GetAsInteger('Prev', -1);
        TrailerDict.Free;
      end
      else if Tok.Kind = TPDFTokenKind.Integer then
      begin
        // ---- XRef stream: "N G obj" ----
        var ObjNum := Tok.IntVal;
        var GenTok := ALexer.NextToken;
        if GenTok.Kind <> TPDFTokenKind.Integer then
          raise EPDFXRefError.Create('Expected generation number for XRef stream object');
        var ObjTok := ALexer.NextToken;
        if ObjTok.Kind <> TPDFTokenKind.ObjBegin then
          raise EPDFXRefError.Create('Expected "obj" for XRef stream object');

        // Parse stream dict
        var OpenTok := ALexer.NextToken;
        if OpenTok.Kind <> TPDFTokenKind.DictOpen then
          raise EPDFXRefError.Create('Expected << for XRef stream dict');

        var StreamDict := ParseDict(ALexer);

        // Verify /Type /XRef
        if StreamDict.GetAsName('Type') <> 'XRef' then
        begin
          StreamDict.Free;
          raise EPDFXRefError.Create('Stream at startxref offset has no /Type /XRef');
        end;

        // Consume 'stream' keyword and following EOL
        var StrmTok := ALexer.NextToken;
        if StrmTok.Kind <> TPDFTokenKind.StreamBegin then
        begin
          StreamDict.Free;
          raise EPDFXRefError.Create('Expected "stream" keyword');
        end;

        // The spec says exactly one EOL (CR, LF, or CRLF) follows 'stream'
        // Our lexer's SkipToEOL handles all variants
        ALexer.SkipToEOL;

        // Read raw encoded stream bytes
        var StreamLen := StreamDict.GetAsInteger('Length');
        if StreamLen <= 0 then
        begin
          StreamDict.Free;
          raise EPDFXRefError.Create('XRef stream has invalid /Length');
        end;

        var RawData := ALexer.ReadRawBytes(StreamLen);

        // Merge dict as trailer BEFORE parsing so /Prev is available
        MergeTrailer(StreamDict);

        // Parse XRef stream entries
        ParseXRefStream(RawData, StreamDict);

        Offset := StreamDict.GetAsInteger('Prev', -1);
        StreamDict.Free;
      end
      else
        raise EPDFXRefError.CreateFmt(
          'Expected "xref" or indirect obj at offset %d, got "%s"',
          [Offset, Tok.Value]);
    end;
  finally
    Visited.Free;
  end;
end;

end.
