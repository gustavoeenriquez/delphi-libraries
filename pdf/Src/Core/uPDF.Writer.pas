unit uPDF.Writer;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.StrUtils, System.Classes, System.Generics.Collections,
  System.Math,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Filters;

type
  // -------------------------------------------------------------------------
  // Serialization options
  // -------------------------------------------------------------------------
  TPDFWriteOptions = record
    UseObjectStreams:  Boolean;  // pack small objects into /ObjStm (PDF 1.5+)
    UseXRefStream:     Boolean;  // write XRef stream instead of classic table
    CompressStreams:   Boolean;  // apply FlateDecode to non-JPEG streams
    Version:           TPDFVersion;
    class function Default: TPDFWriteOptions; static;
  end;

  // -------------------------------------------------------------------------
  // Object writer: serialises any TPDFObject to bytes
  // -------------------------------------------------------------------------
  TPDFObjectSerializer = class
  public
    class procedure WriteObject(AObj: TPDFObject; AOut: TStream); static;
    class procedure WriteValue(AObj: TPDFObject; AOut: TStream); static;
  private
    class procedure WriteNull(AOut: TStream); static;
    class procedure WriteBoolean(AObj: TPDFBoolean; AOut: TStream); static;
    class procedure WriteInteger(AObj: TPDFInteger; AOut: TStream); static;
    class procedure WriteReal(AObj: TPDFReal; AOut: TStream); static;
    class procedure WriteString(AObj: TPDFString; AOut: TStream); static;
    class procedure WriteName(AObj: TPDFName; AOut: TStream); static;
    class procedure WriteArray(AObj: TPDFArray; AOut: TStream); static;
    class procedure WriteDict(AObj: TPDFDictionary; AOut: TStream); static;
    class procedure WriteStream(AObj: TPDFStream; AOut: TStream;
      ACompress: Boolean); static;
    class procedure WriteRef(AObj: TPDFReference; AOut: TStream); static;

    class procedure WriteBytes(const S: string; AOut: TStream); static; inline;
    class function  EscapeNameChar(C: Char): string; static;
    class function  EscapeStringChar(B: Byte): string; static;
  end;

  // -------------------------------------------------------------------------
  // PDF Writer
  // -------------------------------------------------------------------------
  TPDFWriter = class
  private
    FOut:         TStream;
    FOptions:     TPDFWriteOptions;
    // Map: object number → byte offset written so far
    FOffsets:     TDictionary<Integer, Int64>;
    FNextObjNum:  Integer;
    FXRefOffset:  Int64;

    procedure WriteHeader;
    procedure WriteBinaryComment;
    procedure WriteIndirectObject(AObjNum, AGeneration: Integer;
      AObj: TPDFObject);
    procedure WriteXRefTable;
    procedure WriteXRefStream(ATrailerDict: TPDFDictionary);
    procedure WriteTrailer(ATrailerDict: TPDFDictionary; AXRefOffset: Int64);
    procedure WriteEOF;

    function  AllocObjNum: Integer;
    function  CurrentOffset: Int64; inline;
    procedure WriteStr(const S: string); inline;
    procedure WriteBytes(const B: TBytes); inline;
    procedure WriteEOL; inline;

  public
    constructor Create(AOut: TStream; const AOptions: TPDFWriteOptions);
    destructor  Destroy; override;

    // --- Full rewrite ---
    // Write a complete PDF from an object pool.
    // ARoot      : catalog dict (object number assigned by writer)
    // AInfo      : info dict (optional, nil = omit)
    // AObjects   : map of pre-assigned obj# → TPDFObject pairs to serialize
    procedure WriteFull(ACatalog: TPDFDictionary; AInfo: TPDFDictionary;
      AObjects: TDictionary<Integer, TPDFObject>);

    // --- Incremental update ---
    // Append a new xref section + trailer to an existing PDF stream.
    // AExistingSize: byte size of the original file (the startxref base)
    // APrevXRef    : byte offset of the previous startxref
    // AChanged     : map of obj# → new/updated TPDFObject
    procedure WriteIncremental(AExistingSize: Int64; APrevXRef: Int64;
      AChanged: TDictionary<Integer, TPDFObject>;
      ATrailerBase: TPDFDictionary);

    // Allocate the next object number (for building object trees)
    property  NextObjNum: Integer read FNextObjNum;
  end;

  // -------------------------------------------------------------------------
  // High-level PDF document builder
  // Provides a fluent API for creating PDFs from scratch.
  // -------------------------------------------------------------------------
  TPDFBuilder = class
  private
    FVersion:    TPDFVersion;
    FPages:      TObjectList<TPDFDictionary>;  // page dicts (owns)
    FInfo:       TPDFDictionary;
    FPool:       TPDFObjectPool;

    // Object numbering
    FNextObjNum: Integer;
    function  AllocObjNum: Integer; inline;
    function  MakeRef(AObjNum: Integer): TPDFReference; inline;

  public
    constructor Create;
    destructor  Destroy; override;

    // ---- Metadata ----
    procedure SetTitle(const AValue: string);
    procedure SetAuthor(const AValue: string);
    procedure SetSubject(const AValue: string);
    procedure SetCreator(const AValue: string);
    procedure SetProducer(const AValue: string);
    procedure SetVersion(const AVersion: TPDFVersion);

    // ---- Pages ----
    // Add a blank page and return its dict for content building
    function  AddPage(AWidth: Single = PDF_A4_WIDTH;
                      AHeight: Single = PDF_A4_HEIGHT): TPDFDictionary;
    function  PageCount: Integer;

    // ---- Save ----
    procedure SaveToStream(AStream: TStream;
      const AOptions: TPDFWriteOptions); overload;
    procedure SaveToStream(AStream: TStream); overload;
    procedure SaveToFile(const APath: string); overload;
    procedure SaveToFile(const APath: string;
      const AOptions: TPDFWriteOptions); overload;
  end;

  // -------------------------------------------------------------------------
  // Content stream builder (for a single page)
  // Generates a PDF content stream (operators + operands).
  // -------------------------------------------------------------------------
  TPDFContentBuilder = class
  private
    FStream:  TStringBuilder;
    procedure Op(const S: string); inline;
    procedure Num(V: Single); overload; inline;
    procedure Num(V: Integer); overload; inline;
    procedure NumList(const V: array of Single);
  public
    constructor Create;
    destructor  Destroy; override;

    // ---- Graphics state ----
    procedure SaveState;          // q
    procedure RestoreState;       // Q
    procedure SetLineWidth(W: Single);
    procedure SetLineCap(Cap: Integer);
    procedure SetLineJoin(Join: Integer);
    procedure SetMiterLimit(ML: Single);
    procedure SetDash(const Lengths: array of Single; Phase: Single);
    procedure SetFlat(F: Single);

    // ---- Transform ----
    procedure ConcatMatrix(A, B, C, D, E, F_: Single);
    procedure Translate(TX, TY: Single);
    procedure Scale(SX, SY: Single);
    procedure Rotate(AngleDeg: Single);

    // ---- Color ----
    procedure SetStrokeGray(G: Single);
    procedure SetFillGray(G: Single);
    procedure SetStrokeRGB(R, G, B: Single);
    procedure SetFillRGB(R, G, B: Single);
    procedure SetStrokeCMYK(C, M, Y, K: Single);
    procedure SetFillCMYK(C, M, Y, K: Single);
    procedure SetStrokeColorSpace(const AName: string);
    procedure SetFillColorSpace(const AName: string);

    // ---- Path construction ----
    procedure MoveTo(X, Y: Single);
    procedure LineTo(X, Y: Single);
    procedure CurveTo(X1, Y1, X2, Y2, X3, Y3: Single);
    procedure ClosePath;
    procedure Rectangle(X, Y, W, H: Single);
    // Ellipse (approximated with 4 Bezier curves)
    procedure Ellipse(CX, CY, RX, RY: Single);

    // ---- Path painting ----
    procedure Stroke;
    procedure Fill;
    procedure FillEvenOdd;
    procedure FillAndStroke;
    procedure FillEvenOddAndStroke;
    procedure EndPath;
    procedure ClipNonZero;
    procedure ClipEvenOdd;

    // ---- Shapes (convenience) ----
    procedure DrawRect(X, Y, W, H: Single; AFill: Boolean = False);
    procedure DrawLine(X1, Y1, X2, Y2: Single);
    procedure DrawEllipse(CX, CY, RX, RY: Single; AFill: Boolean = False);

    // ---- Text ----
    procedure BeginText;
    procedure EndText;
    procedure SetFont(const AName: string; ASize: Single);
    procedure SetCharSpacing(V: Single);
    procedure SetWordSpacing(V: Single);
    procedure SetHorizScaling(V: Single);   // percent
    procedure SetLeading(V: Single);
    procedure SetTextRenderMode(Mode: Integer);
    procedure SetTextRise(V: Single);
    procedure MoveTextPos(TX, TY: Single);
    procedure SetTextMatrix(A, B, C, D, E, F_: Single);
    procedure NextLine;
    procedure ShowText(const AText: string);
    procedure ShowTextKerned(const AItems: array of const);  // mix strings + numbers
    // Convenience: draw text at absolute position
    procedure DrawText(X, Y: Single; const AText: string);
    procedure DrawTextCentered(X, Y, AWidth: Single; const AText: string);

    // ---- XObject ----
    procedure InvokeXObject(const AName: string);

    // ---- Produce bytes ----
    function  Build: TBytes;
    function  BuildAsString: string;
    procedure Clear;
  end;

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------
  function PDFEscapeString(const S: string): string;
  function PDFRealToStr(V: Single): string;

implementation

uses
  System.Character;

// =========================================================================
// TPDFWriteOptions
// =========================================================================

class function TPDFWriteOptions.Default: TPDFWriteOptions;
begin
  Result.UseObjectStreams := False;
  Result.UseXRefStream    := False;
  Result.CompressStreams  := True;
  Result.Version          := TPDFVersion.Make(1, 7);
end;

// =========================================================================
// Helpers
// =========================================================================

function PDFRealToStr(V: Single): string;
begin
  if Frac(V) = 0 then
    Result := IntToStr(Trunc(V))
  else
  begin
    Result := Format('%.6g', [V]);
    // Always use '.' as decimal separator regardless of locale
    Result := Result.Replace(',', '.');
    // Remove trailing zeros after decimal point
    if Result.Contains('.') then
    begin
      while Result.EndsWith('0') do
        Delete(Result, Length(Result), 1);
      if Result.EndsWith('.') then
        Delete(Result, Length(Result), 1);
    end;
  end;
end;

// Return a zero-padded 3-digit octal string for a byte value (0..255)
function ByteToOct3(B: Byte): string;
begin
  Result := Chr(Ord('0') + (B shr 6) and 7) +
            Chr(Ord('0') + (B shr 3) and 7) +
            Chr(Ord('0') +  B        and 7);
end;

function PDFEscapeString(const S: string): string;
// Converts a Unicode string to a PDF literal string using Windows-1252 encoding.
// Characters outside CP1252 are replaced by '?'.
// Bytes > 127 are emitted as \nnn octal so the output stays all-ASCII,
// compatible with TEncoding.ASCII used in TPDFContentBuilder.Build.
var
  SB:    TStringBuilder;
  Bytes: TBytes;
  B:     Byte;
begin
  Bytes := TEncoding.GetEncoding(1252).GetBytes(S);
  SB := TStringBuilder.Create;
  try
    for B in Bytes do
    begin
      case B of
        10: SB.Append('\n');
        13: SB.Append('\r');
        9:  SB.Append('\t');
        8:  SB.Append('\b');
        12: SB.Append('\f');
        Ord('('): SB.Append('\(');
        Ord(')'): SB.Append('\)');
        Ord('\'): SB.Append('\\');
      else
        if (B < 32) or (B > 126) then
          SB.Append('\' + ByteToOct3(B))
        else
          SB.Append(Chr(B));
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

// =========================================================================
// TPDFObjectSerializer
// =========================================================================

class procedure TPDFObjectSerializer.WriteBytes(const S: string; AOut: TStream);
begin
  if S = '' then Exit;
  var B := TEncoding.ASCII.GetBytes(S);
  AOut.Write(B[0], Length(B));
end;

class function TPDFObjectSerializer.EscapeNameChar(C: Char): string;
begin
  // Chars that need #XX escaping in names
  if (Ord(C) < 33) or (Ord(C) > 126) or
     (C in ['(', ')', '<', '>', '[', ']', '{', '}', '/', '%', '#']) then
    Result := '#' + IntToHex(Ord(C), 2)
  else
    Result := C;
end;

class function TPDFObjectSerializer.EscapeStringChar(B: Byte): string;
begin
  case B of
    10: Result := '\n';
    13: Result := '\r';
    9:  Result := '\t';
    8:  Result := '\b';
    12: Result := '\f';
    Ord('('): Result := '\(';
    Ord(')'): Result := '\)';
    Ord('\'): Result := '\\';
  else
    if (B < 32) or (B > 126) then
      Result := '\' + ByteToOct3(B)
    else
      Result := Char(B);
  end;
end;

class procedure TPDFObjectSerializer.WriteNull(AOut: TStream);
begin
  WriteBytes('null', AOut);
end;

class procedure TPDFObjectSerializer.WriteBoolean(AObj: TPDFBoolean; AOut: TStream);
begin
  WriteBytes(IfThen(AObj.Value, 'true', 'false'), AOut);
end;

class procedure TPDFObjectSerializer.WriteInteger(AObj: TPDFInteger; AOut: TStream);
begin
  WriteBytes(IntToStr(AObj.Value), AOut);
end;

class procedure TPDFObjectSerializer.WriteReal(AObj: TPDFReal; AOut: TStream);
begin
  WriteBytes(PDFRealToStr(AObj.Value), AOut);
end;

class procedure TPDFObjectSerializer.WriteString(AObj: TPDFString; AOut: TStream);
begin
  var Bytes := AObj.Bytes;
  if AObj.IsHex then
  begin
    WriteBytes('<', AOut);
    for var B in Bytes do
      WriteBytes(IntToHex(Ord(B), 2), AOut);
    WriteBytes('>', AOut);
  end else
  begin
    WriteBytes('(', AOut);
    for var I := 1 to Length(Bytes) do
      WriteBytes(EscapeStringChar(Ord(Bytes[I])), AOut);
    WriteBytes(')', AOut);
  end;
end;

class procedure TPDFObjectSerializer.WriteName(AObj: TPDFName; AOut: TStream);
begin
  WriteBytes('/', AOut);
  for var C in AObj.Value do
    WriteBytes(EscapeNameChar(C), AOut);
end;

class procedure TPDFObjectSerializer.WriteArray(AObj: TPDFArray; AOut: TStream);
begin
  WriteBytes('[', AOut);
  for var I := 0 to AObj.Count - 1 do
  begin
    if I > 0 then WriteBytes(' ', AOut);
    WriteValue(AObj.Items(I), AOut);
  end;
  WriteBytes(']', AOut);
end;

class procedure TPDFObjectSerializer.WriteDict(AObj: TPDFDictionary; AOut: TStream);
begin
  WriteBytes('<<', AOut);
  AObj.ForEach(procedure(AKey: string; AValue: TPDFObject)
  begin
    WriteBytes(#10'/', AOut);
    WriteBytes(AKey, AOut);
    WriteBytes(' ', AOut);
    WriteValue(AValue, AOut);
  end);
  WriteBytes(#10'>>', AOut);
end;

class procedure TPDFObjectSerializer.WriteStream(AObj: TPDFStream;
  AOut: TStream; ACompress: Boolean);
var
  Data: TBytes;
begin
  // Decide what bytes to write
  // If CompressStreams and no filter yet, apply FlateDecode
  var AlreadyFiltered := AObj.Dict.Contains('Filter');

  if ACompress and not AlreadyFiltered then
  begin
    var Raw := AObj.DecodedBytes;
    if Length(Raw) = 0 then
      Data := nil
    else
    begin
      var InStm  := TBytesStream.Create(Raw);
      var OutStm := TBytesStream.Create;
      try
        var F := TPDFFlateFilter.Create;
        try
          F.Encode(InStm, OutStm, nil);
        finally
          F.Free;
        end;
        Data := Copy(OutStm.Bytes, 0, OutStm.Size);
      finally
        InStm.Free;
        OutStm.Free;
      end;
      // Update dict
      AObj.Dict.SetValue('Filter', TPDFName.Create('FlateDecode'));
    end;
  end else
    Data := AObj.RawBytes;

  // Update /Length
  AObj.Dict.SetValue('Length', TPDFInteger.Create(Length(Data)));

  // Write dict
  WriteDict(AObj.Dict, AOut);
  WriteBytes(#10'stream'#10, AOut);
  if Length(Data) > 0 then
    AOut.Write(Data[0], Length(Data));
  WriteBytes(#10'endstream', AOut);
end;

class procedure TPDFObjectSerializer.WriteRef(AObj: TPDFReference; AOut: TStream);
begin
  WriteBytes(Format('%d %d R', [AObj.RefID.Number, AObj.RefID.Generation]), AOut);
end;

class procedure TPDFObjectSerializer.WriteValue(AObj: TPDFObject; AOut: TStream);
begin
  if AObj = nil then
  begin
    WriteNull(AOut);
    Exit;
  end;
  case AObj.Kind of
    TPDFObjectKind.Null:       WriteNull(AOut);
    TPDFObjectKind.Boolean:    WriteBoolean(TPDFBoolean(AObj), AOut);
    TPDFObjectKind.Integer:    WriteInteger(TPDFInteger(AObj), AOut);
    TPDFObjectKind.Real:       WriteReal(TPDFReal(AObj), AOut);
    TPDFObjectKind.String_:    WriteString(TPDFString(AObj), AOut);
    TPDFObjectKind.Name:       WriteName(TPDFName(AObj), AOut);
    TPDFObjectKind.Array_:     WriteArray(TPDFArray(AObj), AOut);
    TPDFObjectKind.Dictionary: WriteDict(TPDFDictionary(AObj), AOut);
    TPDFObjectKind.Stream:     WriteStream(TPDFStream(AObj), AOut, False);
    TPDFObjectKind.Reference:  WriteRef(TPDFReference(AObj), AOut);
  end;
end;

class procedure TPDFObjectSerializer.WriteObject(AObj: TPDFObject; AOut: TStream);
begin
  WriteValue(AObj, AOut);
end;

// =========================================================================
// TPDFWriter
// =========================================================================

constructor TPDFWriter.Create(AOut: TStream; const AOptions: TPDFWriteOptions);
begin
  inherited Create;
  FOut        := AOut;
  FOptions    := AOptions;
  FOffsets    := TDictionary<Integer, Int64>.Create;
  FNextObjNum := 1;
end;

destructor TPDFWriter.Destroy;
begin
  FOffsets.Free;
  inherited;
end;

function TPDFWriter.CurrentOffset: Int64;
begin
  Result := FOut.Position;
end;

procedure TPDFWriter.WriteStr(const S: string);
begin
  if S = '' then Exit;
  var B := TEncoding.ASCII.GetBytes(S);
  FOut.Write(B[0], Length(B));
end;

procedure TPDFWriter.WriteBytes(const B: TBytes);
begin
  if Length(B) > 0 then FOut.Write(B[0], Length(B));
end;

procedure TPDFWriter.WriteEOL;
begin
  WriteStr(#10);
end;

function TPDFWriter.AllocObjNum: Integer;
begin
  Result := FNextObjNum;
  Inc(FNextObjNum);
end;

procedure TPDFWriter.WriteHeader;
begin
  WriteStr(Format('%%PDF-%s', [FOptions.Version.ToString]));
  WriteEOL;
end;

procedure TPDFWriter.WriteBinaryComment;
begin
  // Comment with high bytes to signal binary content to FTP clients
  WriteStr('%');
  var B: TBytes := [$E2, $E3, $CF, $D3];
  FOut.Write(B[0], 4);
  WriteEOL;
end;

procedure TPDFWriter.WriteIndirectObject(AObjNum, AGeneration: Integer;
  AObj: TPDFObject);
begin
  FOffsets.AddOrSetValue(AObjNum, CurrentOffset);
  WriteStr(Format('%d %d obj', [AObjNum, AGeneration]));
  WriteEOL;
  if AObj.IsStream then
    TPDFObjectSerializer.WriteStream(TPDFStream(AObj), FOut, FOptions.CompressStreams)
  else
    TPDFObjectSerializer.WriteValue(AObj, FOut);
  WriteEOL;
  WriteStr('endobj');
  WriteEOL;
  WriteEOL;
end;

procedure TPDFWriter.WriteXRefTable;
// Write classic cross-reference table
var
  MaxObj:   Integer;
  ObjNums:  TArray<Integer>;
  Offsets:  TArray<Int64>;
begin
  FXRefOffset := CurrentOffset;

  // Collect and sort object numbers
  ObjNums := FOffsets.Keys.ToArray;
  TArray.Sort<Integer>(ObjNums);
  MaxObj := 0;
  for var N in ObjNums do
    if N > MaxObj then MaxObj := N;

  WriteStr('xref');
  WriteEOL;
  // Single subsection: 0 to MaxObj+1
  WriteStr(Format('0 %d', [MaxObj + 1]));
  WriteEOL;
  // Free object 0
  WriteStr('0000000000 65535 f ');
  WriteEOL;
  for var N := 1 to MaxObj do
  begin
    var Offset: Int64 := 0;
    FOffsets.TryGetValue(N, Offset);
    if FOffsets.ContainsKey(N) then
      WriteStr(Format('%10.10d 00000 n ', [Offset]))
    else
      WriteStr('0000000000 65535 f ');  // free entry for gaps
    WriteEOL;
  end;
end;

procedure TPDFWriter.WriteTrailer(ATrailerDict: TPDFDictionary;
  AXRefOffset: Int64);
begin
  WriteStr('trailer');
  WriteEOL;
  TPDFObjectSerializer.WriteDict(ATrailerDict, FOut);
  WriteEOL;
  WriteStr('startxref');
  WriteEOL;
  WriteStr(IntToStr(AXRefOffset));
  WriteEOL;
end;

procedure TPDFWriter.WriteEOF;
begin
  WriteStr('%%EOF');
  WriteEOL;
end;

procedure TPDFWriter.WriteXRefStream(ATrailerDict: TPDFDictionary);
// PDF 1.5+ XRef stream (combines xref + trailer into one compressed stream)
var
  Entries:    TArray<Integer>;
  MaxObj:     Integer;
  Data:       TBytes;
  Pos:        Integer;
  EntryCount: Integer;
  W0, W1, W2: Integer;

  procedure WriteField(V: Int64; Width: Integer);
  var I: Integer;
  begin
    for I := Width - 1 downto 0 do
    begin
      Data[Pos + I] := V and $FF;
      V := V shr 8;
    end;
    Inc(Pos, Width);
  end;

begin
  FXRefOffset := CurrentOffset;

  Entries := FOffsets.Keys.ToArray;
  TArray.Sort<Integer>(Entries);
  MaxObj := 0;
  for var N in Entries do
    if N > MaxObj then MaxObj := N;

  EntryCount := MaxObj + 1;

  // Build raw XRef stream data: each entry is 1+8+2 = 11 bytes
  // Field widths W = [1, 8, 2]: type(1), offset(8), gen(2)
  W0 := 1; W1 := 8; W2 := 2;
  SetLength(Data, EntryCount * (W0 + W1 + W2));
  Pos := 0;

  // Entry 0: free (type=0)
  WriteField(0, W0);
  WriteField(0, W1);
  WriteField($FFFF, W2);

  for var N := 1 to MaxObj do
  begin
    if FOffsets.ContainsKey(N) then
    begin
      var Off: Int64;
      FOffsets.TryGetValue(N, Off);
      WriteField(1, W0);
      WriteField(Off, W1);
      WriteField(0, W2);
    end else
    begin
      WriteField(0, W0);
      WriteField(0, W1);
      WriteField($FFFF, W2);
    end;
  end;

  // Compress the data
  var InStm  := TBytesStream.Create(Data);
  var OutStm := TBytesStream.Create;
  try
    var F := TPDFFlateFilter.Create;
    try
      F.Encode(InStm, OutStm, nil);
    finally
      F.Free;
    end;
    Data := Copy(OutStm.Bytes, 0, OutStm.Size);
  finally
    InStm.Free;
    OutStm.Free;
  end;

  // Build XRef stream object number
  var XRefObjNum := AllocObjNum;
  FOffsets.AddOrSetValue(XRefObjNum, FXRefOffset);

  // Build stream dict (merged with trailer dict)
  var XRefDict := TPDFDictionary(ATrailerDict.Clone);
  XRefDict.SetValue('Type',   TPDFName.Create('XRef'));
  XRefDict.SetValue('Size',   TPDFInteger.Create(EntryCount + 1));
  XRefDict.SetValue('W',      TPDFArray.Create);
  var WArr := TPDFArray(XRefDict.GetAsArray('W'));
  WArr.Add(TPDFInteger.Create(W0));
  WArr.Add(TPDFInteger.Create(W1));
  WArr.Add(TPDFInteger.Create(W2));
  XRefDict.SetValue('Index',  TPDFArray.Create);
  var IdxArr := TPDFArray(XRefDict.GetAsArray('Index'));
  IdxArr.Add(TPDFInteger.Create(0));
  IdxArr.Add(TPDFInteger.Create(EntryCount));
  XRefDict.SetValue('Filter', TPDFName.Create('FlateDecode'));
  XRefDict.SetValue('Length', TPDFInteger.Create(Length(Data)));

  // Write as indirect object
  WriteStr(Format('%d 0 obj', [XRefObjNum]));
  WriteEOL;
  TPDFObjectSerializer.WriteDict(XRefDict, FOut);
  WriteEOL;
  WriteStr('stream');
  WriteEOL;
  FOut.Write(Data[0], Length(Data));
  WriteEOL;
  WriteStr('endstream');
  WriteEOL;
  WriteStr('endobj');
  WriteEOL;
  XRefDict.Free;

  WriteStr('startxref');
  WriteEOL;
  WriteStr(IntToStr(FXRefOffset));
  WriteEOL;
end;

procedure TPDFWriter.WriteFull(ACatalog: TPDFDictionary;
  AInfo: TPDFDictionary; AObjects: TDictionary<Integer, TPDFObject>);
var
  SortedNums: TArray<Integer>;
begin
  FOffsets.Clear;
  FOut.Position := 0;
  FOut.Size     := 0;
  if FNextObjNum = 1 then
    FNextObjNum := (AObjects.Count + 2); // leave room

  WriteHeader;
  WriteBinaryComment;

  // Write all objects in ascending number order
  SortedNums := AObjects.Keys.ToArray;
  TArray.Sort<Integer>(SortedNums);

  for var N in SortedNums do
  begin
    var Obj := AObjects[N];
    WriteIndirectObject(N, 0, Obj);
  end;

  // Trailer dict
  var TrailerDict := TPDFDictionary.Create;
  try
    var MaxObjNum := 0;
    for var N in FOffsets.Keys do
      if N > MaxObjNum then MaxObjNum := N;

    TrailerDict.SetValue('Size', TPDFInteger.Create(MaxObjNum + 1));

    // Root reference: find catalog object number
    var CatalogNum := -1;
    for var Pair in AObjects do
      if Pair.Value = ACatalog then
      begin
        CatalogNum := Pair.Key;
        Break;
      end;
    if CatalogNum > 0 then
      TrailerDict.SetValue('Root', TPDFReference.CreateNum(CatalogNum, 0));

    // Info reference
    if AInfo <> nil then
    begin
      var InfoNum := -1;
      for var Pair in AObjects do
        if Pair.Value = AInfo then
        begin
          InfoNum := Pair.Key;
          Break;
        end;
      if InfoNum > 0 then
        TrailerDict.SetValue('Info', TPDFReference.CreateNum(InfoNum, 0));
    end;

    if FOptions.UseXRefStream then
      WriteXRefStream(TrailerDict)
    else
    begin
      WriteXRefTable;
      WriteTrailer(TrailerDict, FXRefOffset);
    end;
  finally
    TrailerDict.Free;
  end;

  WriteEOF;
end;

procedure TPDFWriter.WriteIncremental(AExistingSize: Int64;
  APrevXRef: Int64; AChanged: TDictionary<Integer, TPDFObject>;
  ATrailerBase: TPDFDictionary);
var
  SortedNums: TArray<Integer>;
begin
  FOffsets.Clear;
  FOut.Position := AExistingSize;

  WriteEOL; // blank line separator

  SortedNums := AChanged.Keys.ToArray;
  TArray.Sort<Integer>(SortedNums);

  for var N in SortedNums do
    WriteIndirectObject(N, 0, AChanged[N]);

  // New XRef section covering only changed objects
  FXRefOffset := CurrentOffset;
  WriteStr('xref');
  WriteEOL;

  // Write individual subsections (one per changed object for simplicity)
  for var N in SortedNums do
  begin
    WriteStr(Format('%d 1', [N]));
    WriteEOL;
    var Off: Int64;
    FOffsets.TryGetValue(N, Off);
    WriteStr(Format('%10.10d 00000 n ', [Off]));
    WriteEOL;
  end;

  // Incremental trailer
  var UpdateTrailer := TPDFDictionary.Create;
  try
    var MaxSize := ATrailerBase.GetAsInteger('Size');
    for var N in SortedNums do
      if N >= MaxSize then MaxSize := N + 1;
    UpdateTrailer.SetValue('Size', TPDFInteger.Create(MaxSize));
    UpdateTrailer.SetValue('Prev', TPDFInteger.Create(APrevXRef));
    // Keep Root and Info from base trailer
    var RootObj := ATrailerBase.RawGet('Root');
    if RootObj <> nil then
      UpdateTrailer.SetValue('Root', RootObj.Clone);
    var InfoObj := ATrailerBase.RawGet('Info');
    if InfoObj <> nil then
      UpdateTrailer.SetValue('Info', InfoObj.Clone);

    WriteTrailer(UpdateTrailer, FXRefOffset);
  finally
    UpdateTrailer.Free;
  end;

  WriteEOF;
end;

// =========================================================================
// TPDFBuilder
// =========================================================================

constructor TPDFBuilder.Create;
begin
  inherited;
  FPages      := TObjectList<TPDFDictionary>.Create(True);
  FPool       := TPDFObjectPool.Create;
  FInfo       := TPDFDictionary.Create;
  FNextObjNum := 1;
  FVersion    := TPDFVersion.Make(1, 7);
  FInfo.SetValue('Producer', TPDFString.Create('PDFLib Delphi'));
end;

destructor TPDFBuilder.Destroy;
begin
  FInfo.Free;
  FPool.Free;
  FPages.Free;
  inherited;
end;

function TPDFBuilder.AllocObjNum: Integer;
begin
  Result := FNextObjNum;
  Inc(FNextObjNum);
end;

function TPDFBuilder.MakeRef(AObjNum: Integer): TPDFReference;
begin
  Result := TPDFReference.CreateNum(AObjNum, 0);
end;

// Encode a Unicode string as a PDF info string.
// Uses UTF-16BE with BOM (FE FF prefix) so the PDF reader can display any
// Unicode character, including accented letters, ñ, CJK, emojis, etc.
function MakePDFInfoString(const S: string): TPDFString;
var
  UTF16BE: TBytes;
  Raw:     RawByteString;
begin
  UTF16BE := TEncoding.BigEndianUnicode.GetBytes(S);
  SetLength(Raw, 2 + Length(UTF16BE));
  Raw[1] := #$FE;
  Raw[2] := #$FF;
  if Length(UTF16BE) > 0 then
    Move(UTF16BE[0], Raw[3], Length(UTF16BE));
  Result := TPDFString.Create(Raw);
end;

procedure TPDFBuilder.SetTitle(const AValue: string);
begin
  FInfo.SetValue('Title', MakePDFInfoString(AValue));
end;

procedure TPDFBuilder.SetAuthor(const AValue: string);
begin
  FInfo.SetValue('Author', MakePDFInfoString(AValue));
end;

procedure TPDFBuilder.SetSubject(const AValue: string);
begin
  FInfo.SetValue('Subject', MakePDFInfoString(AValue));
end;

procedure TPDFBuilder.SetCreator(const AValue: string);
begin
  FInfo.SetValue('Creator', MakePDFInfoString(AValue));
end;

procedure TPDFBuilder.SetProducer(const AValue: string);
begin
  FInfo.SetValue('Producer', MakePDFInfoString(AValue));
end;

procedure TPDFBuilder.SetVersion(const AVersion: TPDFVersion);
begin
  FVersion := AVersion;
end;

function TPDFBuilder.AddPage(AWidth, AHeight: Single): TPDFDictionary;
begin
  var PageDict := TPDFDictionary.Create;
  PageDict.SetValue('Type', TPDFName.Create('Page'));
  var MB := TPDFArray.Create;
  MB.Add(TPDFReal.Create(0));
  MB.Add(TPDFReal.Create(0));
  MB.Add(TPDFReal.Create(AWidth));
  MB.Add(TPDFReal.Create(AHeight));
  PageDict.SetValue('MediaBox', MB);
  PageDict.SetValue('Resources', TPDFDictionary.Create);
  FPages.Add(PageDict);
  Result := PageDict;
end;

function TPDFBuilder.PageCount: Integer;
begin
  Result := FPages.Count;
end;

procedure TPDFBuilder.SaveToStream(AStream: TStream;
  const AOptions: TPDFWriteOptions);
var
  Objects:   TDictionary<Integer, TPDFObject>;
  PageRefs:  TArray<TPDFReference>;
begin
  Objects := TDictionary<Integer, TPDFObject>.Create;
  try
    FNextObjNum := 1;

    // Allocate Info
    var InfoNum  := AllocObjNum;  // 1
    // Allocate Catalog
    var CatNum   := AllocObjNum;  // 2
    // Allocate Pages root
    var PagesNum := AllocObjNum;  // 3

    // Page objects
    SetLength(PageRefs, FPages.Count);
    var PageNums: TArray<Integer>;
    SetLength(PageNums, FPages.Count);
    for var I := 0 to FPages.Count - 1 do
    begin
      PageNums[I] := AllocObjNum;
      PageRefs[I] := MakeRef(PageNums[I]);
    end;

    // Content streams (one per page)
    var ContentNums: TArray<Integer>;
    SetLength(ContentNums, FPages.Count);
    for var I := 0 to FPages.Count - 1 do
      ContentNums[I] := AllocObjNum;

    // Font objects (collect unique fonts from pages)
    // Simple approach: scan pages for /Resources/Font entries

    // --- Build Pages tree ---
    var PagesDict := TPDFDictionary.Create;
    PagesDict.SetValue('Type',  TPDFName.Create('Pages'));
    PagesDict.SetValue('Count', TPDFInteger.Create(FPages.Count));
    var KidsArr := TPDFArray.Create;
    for var Ref in PageRefs do
      KidsArr.Add(Ref.Clone);
    PagesDict.SetValue('Kids', KidsArr);
    Objects.Add(PagesNum, PagesDict);

    // --- Build each page + content stream ---
    for var I := 0 to FPages.Count - 1 do
    begin
      var PageDict := TPDFDictionary(FPages[I].Clone);

      // Link to parent
      PageDict.SetValue('Parent', MakeRef(PagesNum));

      // Content stream: check if page has a /Contents entry already
      var ContentsRaw := FPages[I].RawGet('Contents');
      var ContentStm  := TPDFStream.Create;
      if ContentsRaw <> nil then
      begin
        // The page dict had content data added by caller (via TPDFContentBuilder)
        var CB := ContentsRaw;
        if CB.IsStream then
        begin
          ContentStm.Free;
          ContentStm := TPDFStream(CB.Clone);
        end else if CB.IsString then
        begin
          var Bytes_ := CB.AsString;
          var RawData: TBytes;
          SetLength(RawData, Length(Bytes_));
          if Length(Bytes_) > 0 then
            Move(Bytes_[1], RawData[0], Length(Bytes_));
          ContentStm.SetRawData(RawData);
        end;
      end;
      // Else content is empty (blank page)
      ContentStm.Dict.SetValue('Length', TPDFInteger.Create(Length(ContentStm.RawBytes)));
      Objects.Add(ContentNums[I], ContentStm);

      // Update page Contents reference
      PageDict.SetValue('Contents', MakeRef(ContentNums[I]));
      PageDict.Remove('Contents_raw'); // remove raw placeholder if any
      Objects.Add(PageNums[I], PageDict);
    end;

    // --- Catalog ---
    var CatalogDict := TPDFDictionary.Create;
    CatalogDict.SetValue('Type',  TPDFName.Create('Catalog'));
    CatalogDict.SetValue('Pages', MakeRef(PagesNum));
    Objects.Add(CatNum, CatalogDict);

    // --- Info ---
    Objects.Add(InfoNum, TPDFDictionary(FInfo.Clone));

    // --- Write ---
    var Opts := AOptions;
    Opts.Version := FVersion;
    var Writer := TPDFWriter.Create(AStream, Opts);
    try
      Writer.FNextObjNum := FNextObjNum;
      Writer.WriteFull(CatalogDict, TPDFDictionary(Objects[InfoNum]), Objects);
    finally
      Writer.Free;
    end;
  finally
    // Free objects we own (not FPages items — those stay in FPages)
    for var Pair in Objects do
      Pair.Value.Free;
    Objects.Free;
  end;
end;

procedure TPDFBuilder.SaveToStream(AStream: TStream);
begin
  SaveToStream(AStream, TPDFWriteOptions.Default);
end;

procedure TPDFBuilder.SaveToFile(const APath: string;
  const AOptions: TPDFWriteOptions);
begin
  var FS := TFileStream.Create(APath, fmCreate);
  try
    SaveToStream(FS, AOptions);
  finally
    FS.Free;
  end;
end;

procedure TPDFBuilder.SaveToFile(const APath: string);
begin
  SaveToFile(APath, TPDFWriteOptions.Default);
end;

// =========================================================================
// TPDFContentBuilder
// =========================================================================

constructor TPDFContentBuilder.Create;
begin
  inherited;
  FStream := TStringBuilder.Create;
end;

destructor TPDFContentBuilder.Destroy;
begin
  FStream.Free;
  inherited;
end;

procedure TPDFContentBuilder.Op(const S: string);
begin
  FStream.Append(S);
  FStream.Append(#10);
end;

procedure TPDFContentBuilder.Num(V: Single);
begin
  FStream.Append(PDFRealToStr(V));
  FStream.Append(' ');
end;

procedure TPDFContentBuilder.Num(V: Integer);
begin
  FStream.Append(IntToStr(V));
  FStream.Append(' ');
end;

procedure TPDFContentBuilder.NumList(const V: array of Single);
begin
  for var N in V do
    Num(N);
end;

procedure TPDFContentBuilder.Clear;
begin
  FStream.Clear;
end;

function TPDFContentBuilder.BuildAsString: string;
begin
  Result := FStream.ToString;
end;

function TPDFContentBuilder.Build: TBytes;
begin
  Result := TEncoding.ASCII.GetBytes(FStream.ToString);
end;

// ---- Graphics state ----

procedure TPDFContentBuilder.SaveState;    begin Op('q');  end;
procedure TPDFContentBuilder.RestoreState; begin Op('Q');  end;

procedure TPDFContentBuilder.SetLineWidth(W: Single);
begin Num(W); Op('w'); end;

procedure TPDFContentBuilder.SetLineCap(Cap: Integer);
begin Num(Cap); Op('J'); end;

procedure TPDFContentBuilder.SetLineJoin(Join: Integer);
begin Num(Join); Op('j'); end;

procedure TPDFContentBuilder.SetMiterLimit(ML: Single);
begin Num(ML); Op('M'); end;

procedure TPDFContentBuilder.SetDash(const Lengths: array of Single; Phase: Single);
begin
  FStream.Append('[');
  for var L in Lengths do
  begin
    FStream.Append(PDFRealToStr(L));
    FStream.Append(' ');
  end;
  FStream.Append('] ');
  Num(Phase);
  Op('d');
end;

procedure TPDFContentBuilder.SetFlat(F: Single);
begin Num(F); Op('i'); end;

// ---- Transform ----

procedure TPDFContentBuilder.ConcatMatrix(A, B, C, D, E, F_: Single);
begin NumList([A, B, C, D, E, F_]); Op('cm'); end;

procedure TPDFContentBuilder.Translate(TX, TY: Single);
begin ConcatMatrix(1, 0, 0, 1, TX, TY); end;

procedure TPDFContentBuilder.Scale(SX, SY: Single);
begin ConcatMatrix(SX, 0, 0, SY, 0, 0); end;

procedure TPDFContentBuilder.Rotate(AngleDeg: Single);
var
  S, Co: Single;
begin
  S  := Sin(AngleDeg * Pi / 180);
  Co := Cos(AngleDeg * Pi / 180);
  ConcatMatrix(Co, S, -S, Co, 0, 0);
end;

// ---- Color ----

procedure TPDFContentBuilder.SetStrokeGray(G: Single);
begin Num(G); Op('G'); end;

procedure TPDFContentBuilder.SetFillGray(G: Single);
begin Num(G); Op('g'); end;

procedure TPDFContentBuilder.SetStrokeRGB(R, G, B: Single);
begin NumList([R, G, B]); Op('RG'); end;

procedure TPDFContentBuilder.SetFillRGB(R, G, B: Single);
begin NumList([R, G, B]); Op('rg'); end;

procedure TPDFContentBuilder.SetStrokeCMYK(C, M, Y, K: Single);
begin NumList([C, M, Y, K]); Op('K'); end;

procedure TPDFContentBuilder.SetFillCMYK(C, M, Y, K: Single);
begin NumList([C, M, Y, K]); Op('k'); end;

procedure TPDFContentBuilder.SetStrokeColorSpace(const AName: string);
begin FStream.Append('/'); FStream.Append(AName); FStream.Append(' '); Op('CS'); end;

procedure TPDFContentBuilder.SetFillColorSpace(const AName: string);
begin FStream.Append('/'); FStream.Append(AName); FStream.Append(' '); Op('cs'); end;

// ---- Path construction ----

procedure TPDFContentBuilder.MoveTo(X, Y: Single);
begin NumList([X, Y]); Op('m'); end;

procedure TPDFContentBuilder.LineTo(X, Y: Single);
begin NumList([X, Y]); Op('l'); end;

procedure TPDFContentBuilder.CurveTo(X1, Y1, X2, Y2, X3, Y3: Single);
begin NumList([X1, Y1, X2, Y2, X3, Y3]); Op('c'); end;

procedure TPDFContentBuilder.ClosePath;
begin Op('h'); end;

procedure TPDFContentBuilder.Rectangle(X, Y, W, H: Single);
begin NumList([X, Y, W, H]); Op('re'); end;

procedure TPDFContentBuilder.Ellipse(CX, CY, RX, RY: Single);
// 4-arc Bezier approximation (κ ≈ 0.5523)
const
  K = 0.5523;
begin
  MoveTo(CX + RX, CY);
  CurveTo(CX + RX,    CY + K*RY, CX + K*RX, CY + RY, CX,       CY + RY);
  CurveTo(CX - K*RX,  CY + RY,   CX - RX,   CY + K*RY, CX - RX, CY);
  CurveTo(CX - RX,    CY - K*RY, CX - K*RX, CY - RY, CX,       CY - RY);
  CurveTo(CX + K*RX,  CY - RY,   CX + RX,   CY - K*RY, CX + RX, CY);
  ClosePath;
end;

// ---- Path painting ----

procedure TPDFContentBuilder.Stroke;             begin Op('S');  end;
procedure TPDFContentBuilder.Fill;               begin Op('f');  end;
procedure TPDFContentBuilder.FillEvenOdd;        begin Op('f*'); end;
procedure TPDFContentBuilder.FillAndStroke;      begin Op('B');  end;
procedure TPDFContentBuilder.FillEvenOddAndStroke;begin Op('B*'); end;
procedure TPDFContentBuilder.EndPath;            begin Op('n');  end;
procedure TPDFContentBuilder.ClipNonZero;        begin Op('W');  end;
procedure TPDFContentBuilder.ClipEvenOdd;        begin Op('W*'); end;

// ---- Shapes convenience ----

procedure TPDFContentBuilder.DrawRect(X, Y, W, H: Single; AFill: Boolean);
begin
  Rectangle(X, Y, W, H);
  if AFill then FillAndStroke else Stroke;
end;

procedure TPDFContentBuilder.DrawLine(X1, Y1, X2, Y2: Single);
begin
  MoveTo(X1, Y1);
  LineTo(X2, Y2);
  Stroke;
end;

procedure TPDFContentBuilder.DrawEllipse(CX, CY, RX, RY: Single; AFill: Boolean);
begin
  Ellipse(CX, CY, RX, RY);
  if AFill then FillAndStroke else Stroke;
end;

// ---- Text ----

procedure TPDFContentBuilder.BeginText; begin Op('BT'); end;
procedure TPDFContentBuilder.EndText;   begin Op('ET'); end;

procedure TPDFContentBuilder.SetFont(const AName: string; ASize: Single);
begin
  FStream.Append('/');
  FStream.Append(AName);
  FStream.Append(' ');
  Num(ASize);
  Op('Tf');
end;

procedure TPDFContentBuilder.SetCharSpacing(V: Single);  begin Num(V); Op('Tc'); end;
procedure TPDFContentBuilder.SetWordSpacing(V: Single);  begin Num(V); Op('Tw'); end;
procedure TPDFContentBuilder.SetHorizScaling(V: Single); begin Num(V); Op('Tz'); end;
procedure TPDFContentBuilder.SetLeading(V: Single);      begin Num(V); Op('TL'); end;
procedure TPDFContentBuilder.SetTextRenderMode(Mode: Integer); begin Num(Mode); Op('Tr'); end;
procedure TPDFContentBuilder.SetTextRise(V: Single);     begin Num(V); Op('Ts'); end;

procedure TPDFContentBuilder.MoveTextPos(TX, TY: Single);
begin NumList([TX, TY]); Op('Td'); end;

procedure TPDFContentBuilder.SetTextMatrix(A, B, C, D, E, F_: Single);
begin NumList([A, B, C, D, E, F_]); Op('Tm'); end;

procedure TPDFContentBuilder.NextLine;
begin Op('T*'); end;

procedure TPDFContentBuilder.ShowText(const AText: string);
begin
  FStream.Append('(');
  FStream.Append(PDFEscapeString(AText));
  FStream.Append(') ');
  Op('Tj');
end;

procedure TPDFContentBuilder.ShowTextKerned(const AItems: array of const);
// Items can be strings or integers/reals (kerning adjust)
begin
  FStream.Append('[');
  for var Item in AItems do
  begin
    case Item.VType of
      vtAnsiString:
      begin
        FStream.Append('(');
        FStream.Append(PDFEscapeString(string(AnsiString(Item.VAnsiString^))));
        FStream.Append(') ');
      end;
      vtWideString:
      begin
        FStream.Append('(');
        FStream.Append(PDFEscapeString(WideString(Item.VWideString^)));
        FStream.Append(') ');
      end;
      vtUnicodeString:
      begin
        FStream.Append('(');
        FStream.Append(PDFEscapeString(string(Item.VUnicodeString^)));
        FStream.Append(') ');
      end;
      vtInteger:   FStream.AppendFormat('%d ', [Item.VInteger]);
      vtExtended:  FStream.Append(PDFRealToStr(Item.VExtended^) + ' ');
    end;
  end;
  FStream.Append('] ');
  Op('TJ');
end;

procedure TPDFContentBuilder.DrawText(X, Y: Single; const AText: string);
begin
  BeginText;
  SetTextMatrix(1, 0, 0, 1, X, Y);
  ShowText(AText);
  EndText;
end;

procedure TPDFContentBuilder.DrawTextCentered(X, Y, AWidth: Single;
  const AText: string);
begin
  // Approximate centering — caller should set font first
  BeginText;
  SetTextMatrix(1, 0, 0, 1, X + AWidth / 2, Y);
  ShowText(AText);
  EndText;
end;

// ---- XObject ----

procedure TPDFContentBuilder.InvokeXObject(const AName: string);
begin
  FStream.Append('/');
  FStream.Append(AName);
  FStream.Append(' ');
  Op('Do');
end;

end.
