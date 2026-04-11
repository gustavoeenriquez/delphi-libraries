unit uPDF.TextExtractor;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.Generics.Defaults, System.Math,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Document,
  uPDF.GraphicsState, uPDF.ColorSpace, uPDF.Font,
  uPDF.ContentStream;

type
  // -------------------------------------------------------------------------
  // A positioned text fragment (word/glyph cluster)
  // -------------------------------------------------------------------------
  TPDFTextFragment = record
    Text:       string;
    X, Y:       Single;     // baseline position (user space, PDF coords)
    Width:      Single;     // approximate width
    FontSize:   Single;
    FontName:   string;
    PageIndex:  Integer;
  end;

  // -------------------------------------------------------------------------
  // A line of text (sorted fragments grouped by Y proximity)
  // -------------------------------------------------------------------------
  TPDFTextLine = record
    Fragments:  TArray<TPDFTextFragment>;
    Y:          Single;
    function    Text: string;
  end;

  // -------------------------------------------------------------------------
  // Extraction result for one page
  // -------------------------------------------------------------------------
  TPDFPageText = record
    PageIndex:  Integer;
    Fragments:  TArray<TPDFTextFragment>;
    Lines:      TArray<TPDFTextLine>;
    function    PlainText: string;
  end;

  // -------------------------------------------------------------------------
  // Resources adapter for a PDF page
  // Wraps TPDFPage resources to implement IPDFResources
  // -------------------------------------------------------------------------
  TPDFPageResources = class(TInterfacedObject, IPDFResources)
  private
    FPage:       TPDFPage;
    FFontCache:  TObjectDictionary<string, TPDFFont>;
    FCSCache:    TObjectDictionary<string, TPDFColorSpace>;
  public
    constructor Create(APage: TPDFPage);
    destructor  Destroy; override;
    // IPDFResources
    function GetFont(const AName: string): TPDFFont;
    function GetXObject(const AName: string): TPDFStream;
    function GetColorSpace(const AName: string): TPDFColorSpace;
    function GetExtGState(const AName: string): TPDFDictionary;
    function GetPattern(const AName: string): TPDFObject;
  end;

  // -------------------------------------------------------------------------
  // Text extractor
  // -------------------------------------------------------------------------
  TPDFTextExtractor = class
  private
    FDocument:   TPDFDocument;
    FFragments:  TList<TPDFTextFragment>;

    procedure OnGlyph(const AGlyph: TPDFGlyphInfo;
      const AState: TPDFGraphicsState);
    function  BuildLines(const AFragments: TArray<TPDFTextFragment>): TArray<TPDFTextLine>;
    procedure ProcessPage(APage: TPDFPage; APageIndex: Integer);
  public
    constructor Create(ADocument: TPDFDocument);
    destructor  Destroy; override;

    // Extract text from a specific page (0-based)
    function  ExtractPage(APageIndex: Integer): TPDFPageText;
    // Extract text from all pages
    function  ExtractAll: TArray<TPDFPageText>;
    // Simple flat text for the whole document
    function  ExtractAllText: string;
  end;

implementation

// =========================================================================
// TPDFTextLine
// =========================================================================

function TPDFTextLine.Text: string;
var
  PrevEndX: Single;
  Threshold: Single;
begin
  Result   := '';
  PrevEndX := 0;
  for var F in Fragments do
  begin
    if Result <> '' then
    begin
      // Add a word-space only when the gap between the previous glyph's right
      // edge and this glyph's left edge exceeds 25% of the current font size.
      Threshold := F.FontSize * 0.25;
      if (F.X - PrevEndX) > Threshold then
        Result := Result + ' ';
    end;
    Result   := Result + F.Text;
    PrevEndX := F.X + F.Width;
  end;
end;

// =========================================================================
// TPDFPageText
// =========================================================================

function TPDFPageText.PlainText: string;
var
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for var Line in Lines do
    begin
      SB.AppendLine(Line.Text);
    end;
    Result := SB.ToString.TrimRight;
  finally
    SB.Free;
  end;
end;

// =========================================================================
// TPDFPageResources
// =========================================================================

constructor TPDFPageResources.Create(APage: TPDFPage);
begin
  inherited Create;
  FPage     := APage;
  FFontCache := TObjectDictionary<string, TPDFFont>.Create([doOwnsValues]);
  FCSCache   := TObjectDictionary<string, TPDFColorSpace>.Create([doOwnsValues]);
end;

destructor TPDFPageResources.Destroy;
begin
  FCSCache.Free;
  FFontCache.Free;
  inherited;
end;

function TPDFPageResources.GetFont(const AName: string): TPDFFont;
begin
  if FFontCache.TryGetValue(AName, Result) then Exit;
  var FontObj := FPage.GetResource('Font', AName);
  if (FontObj <> nil) and FontObj.IsDictionary then
  begin
    Result := TPDFFontFactory.Build(TPDFDictionary(FontObj),
      FPage.Document.Resolver);
    if Result <> nil then
      FFontCache.Add(AName, Result);
  end else
    Result := nil;
end;

function TPDFPageResources.GetXObject(const AName: string): TPDFStream;
begin
  var Obj := FPage.GetResource('XObject', AName);
  if (Obj <> nil) and Obj.IsStream then
    Result := TPDFStream(Obj)
  else
    Result := nil;
end;

function TPDFPageResources.GetColorSpace(const AName: string): TPDFColorSpace;
begin
  if FCSCache.TryGetValue(AName, Result) then Exit;

  // First try device color spaces by name
  if AName = 'DeviceGray' then Exit(TPDFDeviceGray.Create);
  if AName = 'DeviceRGB'  then Exit(TPDFDeviceRGB.Create);
  if AName = 'DeviceCMYK' then Exit(TPDFDeviceCMYK.Create);

  var CSObj := FPage.GetResource('ColorSpace', AName);
  if CSObj <> nil then
  begin
    Result := TPDFColorSpaceFactory.Build(CSObj, FPage.Document.Resolver);
    if Result <> nil then
      FCSCache.Add(AName, Result);
  end else
    Result := nil;
end;

function TPDFPageResources.GetExtGState(const AName: string): TPDFDictionary;
begin
  var Obj := FPage.GetResource('ExtGState', AName);
  if (Obj <> nil) and Obj.IsDictionary then
    Result := TPDFDictionary(Obj)
  else
    Result := nil;
end;

function TPDFPageResources.GetPattern(const AName: string): TPDFObject;
begin
  Result := FPage.GetResource('Pattern', AName);
end;

// =========================================================================
// TPDFTextExtractor
// =========================================================================

constructor TPDFTextExtractor.Create(ADocument: TPDFDocument);
begin
  inherited Create;
  FDocument  := ADocument;
  FFragments := TList<TPDFTextFragment>.Create;
end;

destructor TPDFTextExtractor.Destroy;
begin
  FFragments.Free;
  inherited;
end;

procedure TPDFTextExtractor.OnGlyph(const AGlyph: TPDFGlyphInfo;
  const AState: TPDFGraphicsState);
var
  Frag: TPDFTextFragment;
begin
  if AGlyph.Unicode = '' then Exit;

  Frag.Text     := AGlyph.Unicode;
  Frag.X        := AGlyph.X;
  Frag.Y        := AGlyph.Y;
  Frag.Width    := AGlyph.Width / 1000.0 * AState.Text.FontSize;
  Frag.FontSize := AState.Text.FontSize;
  Frag.FontName := '';
  if AState.Text.Font <> nil then
    Frag.FontName := AState.Text.Font.Name;
  Frag.PageIndex := -1; // set by caller

  FFragments.Add(Frag);
end;

procedure TPDFTextExtractor.ProcessPage(APage: TPDFPage; APageIndex: Integer);
var
  Proc: TPDFContentStreamProcessor;
  Res:  IPDFResources;
  Data: TBytes;
begin
  Data := APage.ContentStreamBytes;
  if Length(Data) = 0 then Exit;

  Res  := TPDFPageResources.Create(APage);
  Proc := TPDFContentStreamProcessor.Create;
  try
    Proc.OnPaintGlyph :=
      procedure(const AGlyph: TPDFGlyphInfo; const AState: TPDFGraphicsState)
      begin
        OnGlyph(AGlyph, AState);
      end;

    Proc.Process(Data, Res, APage.Document.Resolver);

    // Tag fragments with page index
    for var I := 0 to FFragments.Count - 1 do
    begin
      var F := FFragments[I];
      if F.PageIndex = -1 then
      begin
        F.PageIndex := APageIndex;
        FFragments[I] := F;
      end;
    end;
  finally
    Proc.Free;
    // Res is IPDFResources — lifetime managed by interface reference counting
  end;
end;

function TPDFTextExtractor.BuildLines(
  const AFragments: TArray<TPDFTextFragment>): TArray<TPDFTextLine>;
const
  LINE_TOLERANCE = 2.0; // pts — fragments within this Y distance → same line
var
  Lines:    TList<TPDFTextLine>;
  SortedY:  TArray<Single>;
begin
  if Length(AFragments) = 0 then
    Exit(nil);

  // Sort fragments by Y descending (PDF coords: top = large Y), then X ascending
  var Sorted := Copy(AFragments);
  TArray.Sort<TPDFTextFragment>(Sorted,
    TComparer<TPDFTextFragment>.Construct(
      function(const A, B: TPDFTextFragment): Integer
      begin
        if Abs(A.Y - B.Y) <= LINE_TOLERANCE then
          Result := Sign(A.X - B.X)
        else
          Result := Sign(B.Y - A.Y); // descending Y
      end));

  Lines := TList<TPDFTextLine>.Create;
  try
    var CurrentLine: TPDFTextLine;
    var LineFrags := TList<TPDFTextFragment>.Create;
    try
      var CurrentY := Sorted[0].Y;

      for var Frag in Sorted do
      begin
        if Abs(Frag.Y - CurrentY) > LINE_TOLERANCE then
        begin
          // Flush current line
          CurrentLine.Y         := CurrentY;
          CurrentLine.Fragments := LineFrags.ToArray;
          Lines.Add(CurrentLine);
          LineFrags.Clear;
          CurrentY := Frag.Y;
        end;
        LineFrags.Add(Frag);
      end;

      // Flush last line
      if LineFrags.Count > 0 then
      begin
        CurrentLine.Y         := CurrentY;
        CurrentLine.Fragments := LineFrags.ToArray;
        Lines.Add(CurrentLine);
      end;
    finally
      LineFrags.Free;
    end;

    Result := Lines.ToArray;
  finally
    Lines.Free;
  end;
end;

function TPDFTextExtractor.ExtractPage(APageIndex: Integer): TPDFPageText;
begin
  FFragments.Clear;

  if (APageIndex < 0) or (APageIndex >= FDocument.PageCount) then
    raise EPDFPageNotFoundError.CreateFmt('Page index %d out of range', [APageIndex]);

  var Page := FDocument.Pages[APageIndex];
  ProcessPage(Page, APageIndex);

  Result.PageIndex := APageIndex;
  Result.Fragments := FFragments.ToArray;
  Result.Lines     := BuildLines(Result.Fragments);
end;

function TPDFTextExtractor.ExtractAll: TArray<TPDFPageText>;
begin
  SetLength(Result, FDocument.PageCount);
  for var I := 0 to FDocument.PageCount - 1 do
    Result[I] := ExtractPage(I);
end;

function TPDFTextExtractor.ExtractAllText: string;
var
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for var I := 0 to FDocument.PageCount - 1 do
    begin
      var PageText := ExtractPage(I);
      if I > 0 then SB.AppendLine;
      SB.AppendLine(Format('--- Page %d ---', [I + 1]));
      SB.AppendLine(PageText.PlainText);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

end.
