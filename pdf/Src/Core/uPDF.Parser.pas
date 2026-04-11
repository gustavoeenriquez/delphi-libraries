unit uPDF.Parser;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Lexer, uPDF.XRef;

type
  // -------------------------------------------------------------------------
  // Main PDF parser.
  // Implements IObjectResolver so that TPDFReference.Resolve() works.
  // Provides random-access loading of indirect objects via XRef.
  // -------------------------------------------------------------------------
  TPDFParser = class(TInterfacedObject, IObjectResolver)
  private
    FStream:    TStream;
    FOwns:      Boolean;
    FLexer:     TPDFLexer;
    FXRef:      TPDFXRef;
    FPool:      TPDFObjectPool;
    // Cache: object number → loaded object
    FCache:     TDictionary<Integer, TPDFObject>;
    // Object stream cache: container obj# → list of objects
    FObjectStreamCache: TDictionary<Integer, TObjectList<TPDFObject>>;

    FVersion:            TPDFVersion;
    FEncrypted:          Boolean;
    FDecryptionContext:  IDecryptionContext;

    procedure DetectVersion;
    function  FindStartXRef: Int64;
    procedure ParseXRef;
    function  ParseObject(ALexer: TPDFLexer): TPDFObject;
    function  ParseArray(ALexer: TPDFLexer): TPDFArray;
    function  ParseDict(ALexer: TPDFLexer): TPDFDictionary;
    function  ParseDictOrStream(ALexer: TPDFLexer): TPDFObject;
    function  LoadObjectStream(AContainerObjNum: Integer): TObjectList<TPDFObject>;
    procedure SetResolverOnObject(AObj: TPDFObject);
    // Recursively decrypt all TPDFString values inside AObj
    procedure DecryptObjectStrings(AObj: TPDFObject; AObjNum, AGenNum: Integer);

    // IObjectResolver
    function  Resolve(const AID: TPDFObjectID): TPDFObject;
    function  ResolveNumber(ANumber, AGeneration: Integer): TPDFObject;

    // Disable TInterfacedObject automatic ref-count-based destruction.
    // TPDFDocument owns FParser via a regular object reference; if we let
    // IObjectResolver interface references held by PDF objects free the parser
    // when their ref-count reaches zero (during FPages.Free), FParser.Free
    // in the document destructor would then double-free it.
    function _AddRef: Integer; stdcall;
    function _Release: Integer; stdcall;
  public
    constructor Create(AStream: TStream; AOwns: Boolean = False);
    destructor  Destroy; override;

    // Open and parse the PDF structure (XRef + trailer).
    // Does NOT parse all object bodies — those are lazy-loaded.
    procedure Open;

    // Load an indirect object by number.  Returns TPDFNull if not found.
    function  LoadObject(AObjNum: Integer; AGeneration: Integer = 0): TPDFObject;

    // Convenience: load and dereference
    function  LoadResolved(AObjNum: Integer): TPDFObject;

    // Attach decryption context (call after successful authentication)
    procedure SetDecryptionContext(ACtx: IDecryptionContext);

    // Access parsed structures
    function  XRef: TPDFXRef;
    function  Trailer: TPDFDictionary;
    function  Version: TPDFVersion;
    function  IsEncrypted: Boolean;

    // The object pool (owns all loaded objects)
    function  Pool: TPDFObjectPool;
  end;

implementation

uses
  System.Math;

function StrToBytes(const S: RawByteString): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

// =========================================================================
// Constructor / Destructor
// =========================================================================

constructor TPDFParser.Create(AStream: TStream; AOwns: Boolean);
begin
  inherited Create;
  FStream     := AStream;
  FOwns       := AOwns;
  FLexer      := TPDFLexer.Create(AStream, False);
  FXRef       := TPDFXRef.Create;
  FPool       := TPDFObjectPool.Create;
  FCache      := TDictionary<Integer, TPDFObject>.Create;
  FObjectStreamCache := TDictionary<Integer, TObjectList<TPDFObject>>.Create;
  FEncrypted  := False;
end;

destructor TPDFParser.Destroy;
begin
  for var List in FObjectStreamCache.Values do
    List.Free;
  FObjectStreamCache.Free;
  FCache.Free;          // Does NOT own objects (owned by FPool)
  FPool.Free;
  FXRef.Free;
  FLexer.Free;
  if FOwns then FStream.Free;
  inherited;
end;

// =========================================================================
// Disable TInterfacedObject ref-count-based destruction
// =========================================================================

function TPDFParser._AddRef: Integer;
begin
  Result := -1; // Ownership is via the TPDFDocument object reference, not ref-counting
end;

function TPDFParser._Release: Integer;
begin
  Result := -1; // Prevent automatic Free when IObjectResolver interface refs are released
end;

// =========================================================================
// IObjectResolver
// =========================================================================

function TPDFParser.Resolve(const AID: TPDFObjectID): TPDFObject;
begin
  Result := LoadObject(AID.Number, AID.Generation);
end;

function TPDFParser.ResolveNumber(ANumber, AGeneration: Integer): TPDFObject;
begin
  Result := LoadObject(ANumber, AGeneration);
end;

// =========================================================================
// Accessors
// =========================================================================

function TPDFParser.XRef: TPDFXRef;       begin Result := FXRef;            end;
function TPDFParser.Trailer: TPDFDictionary; begin Result := FXRef.Trailer; end;
function TPDFParser.Version: TPDFVersion; begin Result := FVersion;          end;
function TPDFParser.IsEncrypted: Boolean; begin Result := FEncrypted;        end;
function TPDFParser.Pool: TPDFObjectPool; begin Result := FPool;             end;

// =========================================================================
// Open
// =========================================================================

procedure TPDFParser.Open;
begin
  DetectVersion;
  var StartXRef := FindStartXRef;
  if StartXRef < 0 then
    raise EPDFParseError.Create('Cannot locate startxref offset');
  ParseXRef;
  // Check for encryption
  FEncrypted := FXRef.Trailer.Contains('Encrypt');
end;

// =========================================================================
// Version detection: read first line for %PDF-M.m
// =========================================================================

procedure TPDFParser.DetectVersion;
begin
  FLexer.SeekTo(0);
  var Line := FLexer.ReadLine;
  if not Line.StartsWith('%PDF-') then
  begin
    // Tolerance: some PDFs have a BOM before the header
    FVersion := TPDFVersion.Make(1, 4);
    Exit;
  end;
  FVersion := TPDFVersion.Parse(Line.Substring(5));
end;

// =========================================================================
// Find startxref value: search backwards from EOF
// =========================================================================

function TPDFParser.FindStartXRef: Int64;
const
  SEARCH_TAIL = 2048; // bytes from EOF to search
var
  SearchStart: Int64;
  Buf:         TBytes;
  BufLen:      Integer;
  I:           Integer;
  S:           string;
begin
  Result := -1;
  var FileSize := FStream.Size;
  SearchStart  := Max(0, FileSize - SEARCH_TAIL);
  BufLen       := FileSize - SearchStart;
  SetLength(Buf, BufLen);
  FStream.Position := SearchStart;
  FStream.Read(Buf[0], BufLen);

  // Build string and search backwards for 'startxref'
  SetLength(S, BufLen);
  for I := 0 to BufLen - 1 do
    S[I + 1] := Char(Buf[I]);

  // Find last occurrence of 'startxref'
  var Marker := 'startxref';
  var Pos    := S.LastIndexOf(Marker);
  if Pos < 0 then Exit;

  // After 'startxref', skip whitespace then read the integer offset
  var TextAfter := S.Substring(Pos + System.Length(Marker)).TrimLeft;
  var EOL := TextAfter.IndexOfAny([#10, #13, ' ', #9]);
  if EOL < 0 then EOL := TextAfter.Length;
  if not TryStrToInt64(TextAfter.Substring(0, EOL).Trim, Result) then
    Result := -1;
end;

// =========================================================================
// Parse XRef
// =========================================================================

procedure TPDFParser.ParseXRef;
begin
  var StartXRef := FindStartXRef;
  FXRef.Parse(FLexer, StartXRef);
  // Trailer references were created by XRef's mini-parser without resolvers;
  // propagate the resolver now so Trailer.Get('Root') etc. can dereference.
  SetResolverOnObject(FXRef.Trailer);
end;

// =========================================================================
// Object parser
// =========================================================================

function TPDFParser.ParseObject(ALexer: TPDFLexer): TPDFObject;
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
    TPDFTokenKind.Real:         Result := TPDFReal.Create(Tok.RealVal);
    TPDFTokenKind.ArrayOpen:    Result := ParseArray(ALexer);
    TPDFTokenKind.DictOpen:     Result := ParseDictOrStream(ALexer);

    TPDFTokenKind.Integer:
    begin
      // Could be: plain integer, or "N G R" (reference), or "N G obj" (indirect obj start)
      Tok2 := ALexer.PeekToken;
      if Tok2.Kind <> TPDFTokenKind.Integer then
        Exit(TPDFInteger.Create(Tok.IntVal));

      ALexer.NextToken; // consume second integer
      Tok3 := ALexer.PeekToken;

      if (Tok3.Kind = TPDFTokenKind.Keyword) and (Tok3.Value = 'R') then
      begin
        ALexer.NextToken; // consume 'R'
        var Ref := TPDFReference.CreateNum(Tok.IntVal, Tok2.IntVal);
        Ref.Resolver := Self;
        Result := Ref;
      end else
      begin
        // Not a reference — push Tok2 back so the next ParseObject call sees it
        ALexer.PushBack(Tok2);
        Result := TPDFInteger.Create(Tok.IntVal);
      end;
    end;

    TPDFTokenKind.Keyword:
    begin
      // 'R' as standalone shouldn't occur here; return null
      Result := TPDFNull.Create;
    end;

  else
    Result := TPDFNull.Create;
  end;

  // Give the object a resolver reference so TPDFReference can resolve itself
  if Result <> nil then
    SetResolverOnObject(Result);
end;

function TPDFParser.ParseArray(ALexer: TPDFLexer): TPDFArray;
begin
  Result := TPDFArray.Create;
  while True do
  begin
    var Tok := ALexer.PeekToken;
    if Tok.Kind in [TPDFTokenKind.ArrayClose, TPDFTokenKind.EndOfFile] then
    begin
      ALexer.NextToken;
      Break;
    end;
    if Tok.Kind = TPDFTokenKind.ObjEnd then Break; // malformed but tolerate
    Result.Add(ParseObject(ALexer));
  end;
end;

function TPDFParser.ParseDict(ALexer: TPDFLexer): TPDFDictionary;
// '<<' already consumed
begin
  Result := TPDFDictionary.Create;
  while True do
  begin
    var Tok := ALexer.PeekToken;
    if Tok.Kind in [TPDFTokenKind.DictClose, TPDFTokenKind.EndOfFile] then
    begin
      ALexer.NextToken;
      Break;
    end;
    if Tok.Kind = TPDFTokenKind.ObjEnd then Break;

    var KeyTok := ALexer.NextToken;
    if KeyTok.Kind <> TPDFTokenKind.Name then
    begin
      // Tolerate malformed dicts by skipping unexpected tokens
      Continue;
    end;

    var Val := ParseObject(ALexer);
    Result.SetValue(KeyTok.Value, Val);
  end;
end;

function TPDFParser.ParseDictOrStream(ALexer: TPDFLexer): TPDFObject;
// '<<' already consumed; peek for 'stream' after '>>'
var
  Dict: TPDFDictionary;
begin
  Dict := ParseDict(ALexer);

  var NextTok := ALexer.PeekToken;
  if NextTok.Kind <> TPDFTokenKind.StreamBegin then
    Exit(Dict);

  // It's a stream — consume 'stream' keyword and following EOL
  ALexer.NextToken;
  ALexer.SkipToEOL;
  var StreamDataOffset := ALexer.Position;  // save BEFORE GetAsInteger may call LoadObject/SeekTo

  var StreamObj := TPDFStream.Create;
  // Copy dict entries to stream's dict
  Dict.ForEach(procedure(AKey: string; AValue: TPDFObject)
  begin
    StreamObj.Dict.SetValue(AKey, AValue.Clone);
  end);
  Dict.Free;  // Dict no longer needed; StreamObj.Dict owns the clones

  var Len := StreamObj.Dict.GetAsInteger('Length');
  if Len > 0 then
    StreamObj.SetFileSource(FStream, StreamDataOffset, Len)
  else
  begin
    // Length missing or zero: read until 'endstream'
    // Fallback: try to read up to 'endstream' marker
    var Data := ALexer.ReadRawBytes(0); // zero = use marker scan
    StreamObj.SetRawData(Data);
  end;

  // Skip past the stream body and 'endstream' keyword
  if Len > 0 then
    ALexer.SkipBytes(Len);

  // Skip optional whitespace + 'endstream'
  var EndTok := ALexer.NextToken;
  if EndTok.Kind <> TPDFTokenKind.StreamEnd then
  begin
    // Tolerate: search for endstream
    // (Some generators add extra bytes after the stream data)
  end;

  Result := StreamObj;
end;

// =========================================================================
// Load an indirect object by number
// =========================================================================

function TPDFParser.LoadObject(AObjNum: Integer; AGeneration: Integer): TPDFObject;
var
  Entry: TPDFXRefEntry;
begin
  // Check cache first
  if FCache.TryGetValue(AObjNum, Result) then
    Exit;

  if not FXRef.TryGetEntry(AObjNum, Entry) then
  begin
    Result := TPDFNull.Instance;
    Exit;
  end;

  case Entry.EntryType of
    TPDFXRefEntryType.InUse:
    begin
      // Seek to offset and parse the indirect object
      FLexer.SeekTo(Entry.Offset);

      var ObjNumTok := FLexer.NextToken;
      var GenTok    := FLexer.NextToken;
      var ObjTok    := FLexer.NextToken;

      if ObjTok.Kind <> TPDFTokenKind.ObjBegin then
        raise EPDFParseError.CreateFmt(
          'Expected "obj" at offset %d for object %d, got "%s"',
          [Entry.Offset, AObjNum, ObjTok.Value]);

      Result := ParseObject(FLexer);
      FPool.Add(Result);  // Only top-level indirect objects go in the pool

      // Consume 'endobj'
      var EndTok := FLexer.PeekToken;
      if EndTok.Kind = TPDFTokenKind.ObjEnd then
        FLexer.NextToken;
    end;

    TPDFXRefEntryType.Compressed:
    begin
      // Object inside an object stream
      var ContainerNum := Entry.Offset;
      var Index        := Entry.IndexInStream;
      var ObjList      := LoadObjectStream(ContainerNum);
      if (ObjList <> nil) and (Index < ObjList.Count) then
        Result := ObjList[Index]
      else
        Result := TPDFNull.Instance;
    end;

  else
    Result := TPDFNull.Instance;
  end;

  // Tag with ID and resolver
  if Result <> nil then
  begin
    Result.ID       := TPDFObjectID.Make(AObjNum, AGeneration);
    Result.Resolver := Self;
    FCache.AddOrSetValue(AObjNum, Result);

    // Apply decryption to strings and prepare streams for lazy decryption
    if FDecryptionContext <> nil then
      DecryptObjectStrings(Result, AObjNum, AGeneration);
  end;
end;

function TPDFParser.LoadResolved(AObjNum: Integer): TPDFObject;
begin
  Result := LoadObject(AObjNum);
  if Result <> nil then
    Result := Result.Dereference;
end;

procedure TPDFParser.SetDecryptionContext(ACtx: IDecryptionContext);
begin
  FDecryptionContext := ACtx;
  // Clear cache so objects reload with decryption applied
  FCache.Clear;
end;

procedure TPDFParser.DecryptObjectStrings(AObj: TPDFObject;
  AObjNum, AGenNum: Integer);
var
  Str:  TPDFString;
  Dict: TPDFDictionary;
  Arr:  TPDFArray;
  I:    Integer;
begin
  if (AObj = nil) or (FDecryptionContext = nil) then Exit;

  case AObj.Kind of
    TPDFObjectKind.String_:
    begin
      Str := TPDFString(AObj);
      var Raw := StrToBytes(Str.Bytes);
      if Length(Raw) > 0 then
      begin
        var Decrypted := FDecryptionContext.DecryptBytes(Raw, AObjNum, AGenNum, False);
        if Length(Decrypted) > 0 then
          Str.SetDecryptedBytes(Decrypted);
      end;
    end;

    TPDFObjectKind.Dictionary:
    begin
      Dict := TPDFDictionary(AObj);
      Dict.ForEach(procedure(AKey: string; AValue: TPDFObject)
      begin
        DecryptObjectStrings(AValue, AObjNum, AGenNum);
      end);
    end;

    TPDFObjectKind.Array_:
    begin
      Arr := TPDFArray(AObj);
      for I := 0 to Arr.Count - 1 do
        DecryptObjectStrings(Arr.Items(I), AObjNum, AGenNum);
    end;

    TPDFObjectKind.Stream:
    begin
      // Decrypt string values in the stream's dict (not the stream body —
      // that's handled lazily in EnsureDecoded via SetDecryptionContext)
      DecryptObjectStrings(TPDFStream(AObj).Dict, AObjNum, AGenNum);
      TPDFStream(AObj).SetDecryptionContext(FDecryptionContext, AObjNum, AGenNum);
    end;
  end;
end;

// =========================================================================
// Load object stream (PDF 1.5+ /ObjStm)
// =========================================================================

function TPDFParser.LoadObjectStream(AContainerObjNum: Integer): TObjectList<TPDFObject>;
var
  Container: TPDFObject;
  Stm:       TPDFStream;
  N, First:  Integer;
  Offsets:   TArray<Integer>;
  ObjNums:   TArray<Integer>;
begin
  // Check cache
  if FObjectStreamCache.TryGetValue(AContainerObjNum, Result) then
    Exit;

  Container := LoadObject(AContainerObjNum);
  if (Container = nil) or not Container.IsStream then
  begin
    Result := nil;
    Exit;
  end;

  Stm   := Container.AsStream;
  N     := Stm.Dict.GetAsInteger('N');
  First := Stm.Dict.GetAsInteger('First');

  if N <= 0 then
  begin
    Result := nil;
    Exit;
  end;

  // Decode the stream
  var DecodedBytes := Stm.DecodedBytes;
  var StmStream    := TBytesStream.Create(DecodedBytes);
  try
    var ObjLexer := TPDFLexer.Create(StmStream, False);
    try
      // Read N pairs: objnum offset
      SetLength(ObjNums, N);
      SetLength(Offsets, N);
      for var I := 0 to N - 1 do
      begin
        var NumTok := ObjLexer.NextToken;
        var OffTok := ObjLexer.NextToken;
        if (NumTok.Kind = TPDFTokenKind.Integer) and (OffTok.Kind = TPDFTokenKind.Integer) then
        begin
          ObjNums[I] := NumTok.IntVal;
          Offsets[I] := OffTok.IntVal;
        end else
        begin
          N := I; // truncate on error
          Break;
        end;
      end;

      Result := TObjectList<TPDFObject>.Create(False); // does NOT own objects (pool does)
      FObjectStreamCache.Add(AContainerObjNum, Result);

      // Parse each object at its offset (relative to 'First')
      for var I := 0 to N - 1 do
      begin
        ObjLexer.SeekTo(First + Offsets[I]);
        var Obj := ParseObject(ObjLexer);
        Obj.ID       := TPDFObjectID.Make(ObjNums[I], 0);
        Obj.Resolver := Self;
        FPool.Add(Obj);
        FCache.AddOrSetValue(ObjNums[I], Obj);
        Result.Add(Obj);
      end;
    finally
      ObjLexer.Free;
    end;
  finally
    StmStream.Free;
  end;
end;

// =========================================================================
// Recursively attach the resolver to all references in an object
// =========================================================================

procedure TPDFParser.SetResolverOnObject(AObj: TPDFObject);
begin
  if AObj = nil then Exit;
  AObj.Resolver := Self;

  case AObj.Kind of
    TPDFObjectKind.Array_:
    begin
      var A := TPDFArray(AObj);
      for var I := 0 to A.Count - 1 do
        SetResolverOnObject(A.Items(I));
    end;
    TPDFObjectKind.Dictionary:
    begin
      var D := TPDFDictionary(AObj);
      D.ForEach(procedure(AKey: string; AValue: TPDFObject)
      begin
        SetResolverOnObject(AValue);
      end);
    end;
    TPDFObjectKind.Stream:
    begin
      var S := TPDFStream(AObj);
      S.Dict.ForEach(procedure(AKey: string; AValue: TPDFObject)
      begin
        SetResolverOnObject(AValue);
      end);
    end;
  end;
end;

end.
