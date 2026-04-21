unit uPDF.IncrementalUpdate;

{$SCOPEDENUMS ON}

// ============================================================================
// TPDFIncrementalUpdater
//
// Appends changes to an existing PDF without rewriting the original bytes.
// The update conforms to ISO 32000 §7.5.6 (Incremental Updates):
//   original file bytes  |  new/modified objects  |  new xref section  |  new trailer
//
// Typical usage:
//   var Upd := TPDFIncrementalUpdater.Create('input.pdf');
//   try
//     var Page := Upd.AddPage;
//     Upd.AddStandardFont(Page, 'F1', 'Helvetica');
//     var CB := TPDFContentBuilder.Create;
//     try
//       CB.BeginText;
//       CB.SetFont('F1', 12);
//       CB.SetTextMatrix(1, 0, 0, 1, 50, 750);
//       CB.ShowText('Appended page');
//       CB.EndText;
//       Upd.SetPageContent(Page, CB.Build);
//     finally CB.Free end;
//     Upd.SaveToFile('output.pdf');
//   finally Upd.Free end;
// ============================================================================

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.IOUtils, System.Math,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Document, uPDF.Writer;

type
  TPDFIncrementalUpdater = class
  private
    FDocument:    TPDFDocument;
    FSourceBytes: TBytes;
    FSourceStm:   TBytesStream;   // keeps original bytes alive for lazy parser reads
    FChanged:     TObjectDictionary<Integer, TPDFObject>;
    FNextObjNum:  Integer;
    FPagesRootNum: Integer;
    FStartXRef:   Int64;

    function  AllocObjNum: Integer; inline;
    function  GetCurrentPagesDict: TPDFDictionary;
    function  EnsureResources(APageDict: TPDFDictionary): TPDFDictionary;
    function  EnsureFontDict(APageDict: TPDFDictionary): TPDFDictionary;

  public
    // Load source from a file or from raw bytes already in memory.
    constructor Create(const ASourceFile: string); overload;
    constructor Create(const ASourceBytes: TBytes); overload;
    destructor  Destroy; override;

    // Read-only access to the original document structure.
    property Document: TPDFDocument read FDocument;

    // ---- Modifications ----

    // Append a blank page at the end of the document.
    // Returns the new page's dict — use it with AddStandardFont / SetPageContent.
    function  AddPage(AWidth: Single = PDF_A4_WIDTH;
                      AHeight: Single = PDF_A4_HEIGHT): TPDFDictionary;

    // Register a standard PDF Type1 font on a page dict returned by AddPage.
    // AResName:      name used in SetFont calls (e.g. 'F1').
    // ABaseFontName: one of the 14 standard Type1 names (Helvetica, Courier, etc.).
    procedure AddStandardFont(APageDict: TPDFDictionary;
                const AResName, ABaseFontName: string);

    // Attach a content stream to a page returned by AddPage.
    // Call with the bytes from TPDFContentBuilder.Build.
    procedure SetPageContent(APageDict: TPDFDictionary;
                const AContentBytes: TBytes);

    // ---- Save ----

    // Write the original bytes followed by the incremental update section.
    // AOut must be a freshly-created stream (not the original file stream).
    procedure SaveToStream(AOut: TStream);
    procedure SaveToFile(const APath: string);
  end;

implementation

// ============================================================================
// Helpers
// ============================================================================

function TPDFIncrementalUpdater.AllocObjNum: Integer;
begin
  Result := FNextObjNum;
  Inc(FNextObjNum);
end;

function TPDFIncrementalUpdater.GetCurrentPagesDict: TPDFDictionary;
var
  Obj: TPDFObject;
begin
  // If a previous AddPage call already placed a modified Pages dict in FChanged,
  // return that updated version; otherwise fall back to the parser-owned original.
  if FChanged.TryGetValue(FPagesRootNum, Obj) and (Obj <> nil) and
     Obj.IsDictionary then
    Result := TPDFDictionary(Obj)
  else
    Result := TPDFDictionary(FDocument.Catalog.Get('Pages'));
end;

function TPDFIncrementalUpdater.EnsureResources(
  APageDict: TPDFDictionary): TPDFDictionary;
begin
  Result := APageDict.GetAsDictionary('Resources');
  if Result = nil then
  begin
    Result := TPDFDictionary.Create;
    APageDict.SetValue('Resources', Result);
  end;
end;

function TPDFIncrementalUpdater.EnsureFontDict(
  APageDict: TPDFDictionary): TPDFDictionary;
var
  ResDict: TPDFDictionary;
begin
  ResDict := EnsureResources(APageDict);
  Result  := ResDict.GetAsDictionary('Font');
  if Result = nil then
  begin
    Result := TPDFDictionary.Create;
    ResDict.SetValue('Font', Result);
  end;
end;

// ============================================================================
// Constructor / Destructor
// ============================================================================

constructor TPDFIncrementalUpdater.Create(const ASourceBytes: TBytes);
var
  PagesObj: TPDFObject;
begin
  inherited Create;
  FSourceBytes  := ASourceBytes;
  FChanged      := TObjectDictionary<Integer, TPDFObject>.Create([doOwnsValues]);
  FSourceStm    := TBytesStream.Create(ASourceBytes);
  FDocument     := TPDFDocument.Create;
  FDocument.LoadFromStream(FSourceStm);  // parser holds non-owning ref to FSourceStm

  // Cache the Pages root object number and the next available object number.
  PagesObj       := FDocument.Catalog.Get('Pages');
  FPagesRootNum  := IfThen(PagesObj <> nil, PagesObj.ID.Number, 0);
  FNextObjNum    := FDocument.MaxObjectNumber + 1;
  FStartXRef     := FDocument.StartXRefOffset;
end;

constructor TPDFIncrementalUpdater.Create(const ASourceFile: string);
begin
  Create(TFile.ReadAllBytes(ASourceFile));
end;

destructor TPDFIncrementalUpdater.Destroy;
begin
  FChanged.Free;
  FDocument.Free;   // must be freed before FSourceStm (parser holds stream ref)
  FSourceStm.Free;
  inherited;
end;

// ============================================================================
// AddPage
// ============================================================================

function TPDFIncrementalUpdater.AddPage(AWidth, AHeight: Single): TPDFDictionary;
var
  PagesDict:    TPDFDictionary;
  NewPagesDict: TPDFDictionary;
  KidsArr:      TPDFArray;
  NewPageNum:   Integer;
  NewPageDict:  TPDFDictionary;
  MB:           TPDFArray;
begin
  PagesDict := GetCurrentPagesDict;

  // Build the new page dict
  NewPageNum  := AllocObjNum;
  NewPageDict := TPDFDictionary.Create;
  NewPageDict.SetValue('Type', TPDFName.Create('Page'));
  MB := TPDFArray.Create;
  MB.Add(TPDFReal.Create(0));
  MB.Add(TPDFReal.Create(0));
  MB.Add(TPDFReal.Create(AWidth));
  MB.Add(TPDFReal.Create(AHeight));
  NewPageDict.SetValue('MediaBox', MB);
  NewPageDict.SetValue('Resources', TPDFDictionary.Create);
  NewPageDict.SetValue('Parent', TPDFReference.CreateNum(FPagesRootNum, 0));
  FChanged.AddOrSetValue(NewPageNum, NewPageDict);

  // Clone the Pages root, add the new page reference, and increment /Count.
  // Clone preserves existing Kids entries as TPDFReference objects (raw storage),
  // which is correct for the incremental XRef section.
  NewPagesDict := TPDFDictionary(PagesDict.Clone);
  NewPagesDict.SetValue('Count',
    TPDFInteger.Create(PagesDict.GetAsInteger('Count') + 1));
  KidsArr := NewPagesDict.GetAsArray('Kids');
  if KidsArr <> nil then
    KidsArr.Add(TPDFReference.CreateNum(NewPageNum, 0))
  else
  begin
    KidsArr := TPDFArray.Create;
    KidsArr.Add(TPDFReference.CreateNum(NewPageNum, 0));
    NewPagesDict.SetValue('Kids', KidsArr);
  end;
  FChanged.AddOrSetValue(FPagesRootNum, NewPagesDict);

  Result := NewPageDict;
end;

// ============================================================================
// AddStandardFont
// ============================================================================

procedure TPDFIncrementalUpdater.AddStandardFont(APageDict: TPDFDictionary;
  const AResName, ABaseFontName: string);
var
  FontDict: TPDFDictionary;
  FD:       TPDFDictionary;
begin
  FontDict := EnsureFontDict(APageDict);
  FD := TPDFDictionary.Create;
  FD.SetValue('Type',     TPDFName.Create('Font'));
  FD.SetValue('Subtype',  TPDFName.Create('Type1'));
  FD.SetValue('BaseFont', TPDFName.Create(ABaseFontName));
  FD.SetValue('Encoding', TPDFName.Create('WinAnsiEncoding'));
  FontDict.SetValue(AResName, FD);
end;

// ============================================================================
// SetPageContent
// ============================================================================

procedure TPDFIncrementalUpdater.SetPageContent(APageDict: TPDFDictionary;
  const AContentBytes: TBytes);
var
  ContentNum: Integer;
  ContentStm: TPDFStream;
begin
  ContentNum := AllocObjNum;
  ContentStm := TPDFStream.Create;
  ContentStm.SetRawData(AContentBytes);
  ContentStm.Dict.SetValue('Length', TPDFInteger.Create(Length(AContentBytes)));
  FChanged.AddOrSetValue(ContentNum, ContentStm);
  APageDict.SetValue('Contents', TPDFReference.CreateNum(ContentNum, 0));
end;

// ============================================================================
// SaveToStream / SaveToFile
// ============================================================================

procedure TPDFIncrementalUpdater.SaveToStream(AOut: TStream);
var
  Opts:    TPDFWriteOptions;
  Writer:  TPDFWriter;
  Trailer: TPDFDictionary;
begin
  // Write original bytes unchanged
  if Length(FSourceBytes) > 0 then
    AOut.Write(FSourceBytes[0], Length(FSourceBytes));

  // Append the incremental XRef section + trailer
  Trailer := FDocument.Trailer;
  if Trailer = nil then
    raise EPDFError.Create('Cannot save incrementally: document has no trailer');
  if FStartXRef < 0 then
    raise EPDFError.Create('Cannot save incrementally: startxref offset unknown');

  Opts   := TPDFWriteOptions.Default;
  Writer := TPDFWriter.Create(AOut, Opts);
  try
    Writer.WriteIncremental(
      Length(FSourceBytes),
      FStartXRef,
      FChanged,
      Trailer);
  finally
    Writer.Free;
  end;
end;

procedure TPDFIncrementalUpdater.SaveToFile(const APath: string);
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(APath, fmCreate);
  try
    SaveToStream(FS);
  finally
    FS.Free;
  end;
end;

end.
