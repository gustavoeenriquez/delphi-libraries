unit uPDF.Document;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Lexer, uPDF.XRef, uPDF.Parser,
  uPDF.Encryption;

type
  TPDFPage = class;

  // -------------------------------------------------------------------------
  // PDF Document — root model class
  // -------------------------------------------------------------------------
  TPDFDocument = class
  private
    FParser:      TPDFParser;    // nil when creating from scratch
    FCatalog:     TPDFDictionary;
    FPages:       TObjectList<TPDFPage>;
    FVersion:     TPDFVersion;
    FIsOpen:      Boolean;
    FDecryptor:   IDecryptionContext; // nil for unencrypted PDFs
    FNextObjNum:  Integer;       // For write path: next available object number
    FInfoDict:    TPDFDictionary; // owned; nil until first metadata setter call

    procedure LoadPages;
    procedure LoadPageTree(ANode: TPDFDictionary; AInherit: TPDFDictionary);
    procedure DoFullRewriteFromParser(AStream: TStream);
    procedure DoFullRewriteFromScratch(AStream: TStream);

    function  GetPageCount: Integer;
    function  GetPage(AIndex: Integer): TPDFPage;
    function  GetIsEncrypted: Boolean;
    function  NewObjectNumber: Integer;
    function  EnsureInfoDict: TPDFDictionary;
    function  GetInfoString(const AKey: string): string;
    procedure SetInfoString(const AKey, AValue: string);

  public
    constructor Create;
    destructor  Destroy; override;

    // ---- Read path ----
    procedure LoadFromStream(AStream: TStream);
    procedure LoadFromFile(const APath: string);

    // ---- Write path ----
    procedure SaveToStream(AStream: TStream; AMode: TPDFSaveMode = TPDFSaveMode.FullRewrite);
    procedure SaveToFile(const APath: string; AMode: TPDFSaveMode = TPDFSaveMode.FullRewrite);

    // ---- Page access ----
    function  AddPage(AWidth: Single = PDF_A4_WIDTH;
                      AHeight: Single = PDF_A4_HEIGHT): TPDFPage;
    function  RemovePage(AIndex: Integer): Boolean;

    property  PageCount: Integer read GetPageCount;
    property  Pages[AIndex: Integer]: TPDFPage read GetPage; default;

    // ---- Metadata ----
    function  GetTitle: string;
    function  GetAuthor: string;
    function  GetSubject: string;
    function  GetCreator: string;
    function  GetProducer: string;
    procedure SetTitle(const AValue: string);
    procedure SetAuthor(const AValue: string);
    procedure SetSubject(const AValue: string);
    procedure SetCreator(const AValue: string);
    procedure SetProducer(const AValue: string);

    property  Title:    string read GetTitle    write SetTitle;
    property  Author:   string read GetAuthor   write SetAuthor;
    property  Subject:  string read GetSubject  write SetSubject;
    property  Creator:  string read GetCreator  write SetCreator;
    property  Producer: string read GetProducer write SetProducer;

    // ---- State ----
    property  Version:     TPDFVersion read FVersion;
    property  IsOpen:      Boolean read FIsOpen;
    property  IsEncrypted: Boolean read GetIsEncrypted;

    // Authenticate with user or owner password (call after LoadFromFile if
    // IsEncrypted is True and you need to read content).
    // Empty string tries the empty/user password.
    // Returns True if the password is correct.
    function  Authenticate(const APassword: string = ''): Boolean;

    // ---- Internal (used by renderer / extractor / Phase 9 units) ----
    function  Resolver: IObjectResolver;
    function  Catalog: TPDFDictionary;
    function  Trailer: TPDFDictionary;

    // ---- Incremental-update helpers ----
    // Highest object number present in the XRef (0 if not loaded from file).
    function  MaxObjectNumber: Integer;
    // Byte offset of the last startxref entry (−1 if not loaded from file).
    function  StartXRefOffset: Int64;
  end;

  // -------------------------------------------------------------------------
  // PDF Page
  // -------------------------------------------------------------------------
  TPDFPage = class
  private
    [Weak] FDocument: TPDFDocument;
    FDict:            TPDFDictionary;
    FPageIndex:       Integer;
    FMediaBox:        TPDFRect;
    FCropBox:         TPDFRect;
    FRotation:        Integer;
    FOrigObjNum:             Integer;  // obj# in source file (0 = created fresh via AddPage)
    FPendingContentOverride: TBytes;   // set by AppendContent; merged into /Contents on SaveToStream

    function  GetWidth: Single;
    function  GetHeight: Single;
    function  GetMediaBox: TPDFRect;
    function  GetCropBox: TPDFRect;

    // Build merged content stream (may be array of streams)
    function  BuildContentStream: TBytes;

  public
    constructor Create(ADocument: TPDFDocument; ADict: TPDFDictionary;
      AIndex: Integer; AOrigObjNum: Integer = 0);
    destructor  Destroy; override;

    // Page geometry (after applying rotation)
    property  MediaBox: TPDFRect read GetMediaBox;
    property  CropBox:  TPDFRect read GetCropBox;
    property  Rotation: Integer read FRotation;
    property  Width:    Single read GetWidth;
    property  Height:   Single read GetHeight;

    // Raw page dict (for advanced use)
    function  Dict: TPDFDictionary;

    // Decoded content stream bytes (all streams merged and decompressed)
    function  ContentStreamBytes: TBytes;

    // Resources dict (/Font, /XObject, /ColorSpace, etc.)
    function  Resources: TPDFDictionary;

    // Resolve a resource by type and name, e.g. ('Font', 'F1')
    function  GetResource(const AType, AName: string): TPDFObject;

    // Append PDF operators on top of existing page content.
    // AOperators: raw bytes from TPDFContentBuilder.Build.
    // Takes effect when the parent TPDFDocument.SaveToStream is called.
    // Can be called multiple times; each call appends to the previous result.
    procedure AppendContent(const AOperators: TBytes);

    property  PageIndex: Integer read FPageIndex;
    property  Document:  TPDFDocument read FDocument;
  end;

implementation

uses
  System.Math,
  uPDF.Writer;

// =========================================================================
// TPDFDocument
// =========================================================================

constructor TPDFDocument.Create;
begin
  inherited;
  FPages      := TObjectList<TPDFPage>.Create(True);
  FIsOpen     := False;
  FNextObjNum := 1;
  FVersion    := TPDFVersion.Make(1, 7);
end;

destructor TPDFDocument.Destroy;
begin
  FInfoDict.Free;
  FPages.Free;
  FParser.Free;   // owns pool → destroys all PDF objects
  inherited;
end;

function TPDFDocument.NewObjectNumber: Integer;
begin
  Result := FNextObjNum;
  Inc(FNextObjNum);
end;

function TPDFDocument.Resolver: IObjectResolver;
begin
  if FParser <> nil then
    Result := FParser as IObjectResolver
  else
    Result := nil;
end;

function TPDFDocument.Catalog: TPDFDictionary;
begin
  Result := FCatalog;
end;

function TPDFDocument.Trailer: TPDFDictionary;
begin
  if FParser <> nil then
    Result := FParser.Trailer
  else
    Result := nil;
end;

function TPDFDocument.MaxObjectNumber: Integer;
begin
  if FParser <> nil then
    Result := FParser.XRef.HighestObjectNumber
  else
    Result := FNextObjNum - 1;
end;

function TPDFDocument.StartXRefOffset: Int64;
begin
  if FParser <> nil then
    Result := FParser.StartXRefOffset
  else
    Result := -1;
end;

// =========================================================================
// LoadFromStream / LoadFromFile
// =========================================================================

procedure TPDFDocument.LoadFromStream(AStream: TStream);
begin
  FParser.Free;
  FParser  := nil;
  FPages.Clear;
  FCatalog := nil;
  FIsOpen  := False;

  FParser := TPDFParser.Create(AStream, False);
  FParser.Open;
  FVersion := FParser.Version;

  if FParser.IsEncrypted then
    Authenticate('');  // auto-try empty password; caller may call Authenticate() again

  // Locate catalog
  var RootObj := FParser.Trailer.Get('Root');
  if (RootObj = nil) or not RootObj.IsDictionary then
    raise EPDFDocumentError.Create('PDF trailer has no /Root entry');
  FCatalog := TPDFDictionary(RootObj);

  // Load page tree
  LoadPages;

  FIsOpen := True;
end;

procedure TPDFDocument.LoadFromFile(const APath: string);
begin
  var FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  // Parser will NOT own the stream (we manage it externally here).
  // Instead we pass ownership to parser so it lives until parser is freed.
  FParser.Free;
  FParser := nil;
  FPages.Clear;
  FCatalog := nil;
  FIsOpen  := False;

  FParser := TPDFParser.Create(FS, True {owns stream});
  FParser.Open;
  FVersion := FParser.Version;

  if FParser.IsEncrypted then
    Authenticate('');  // auto-try empty password; caller may call Authenticate() again

  var RootObj := FParser.Trailer.Get('Root');
  if (RootObj = nil) or not RootObj.IsDictionary then
    raise EPDFDocumentError.Create('PDF trailer has no /Root entry');
  FCatalog := TPDFDictionary(RootObj);

  LoadPages;
  FIsOpen := True;
end;

// =========================================================================
// Page tree traversal
// =========================================================================

procedure TPDFDocument.LoadPages;
begin
  var PagesObj := FCatalog.Get('Pages');
  if (PagesObj = nil) or not PagesObj.IsDictionary then
    raise EPDFDocumentError.Create('Catalog has no /Pages entry');
  LoadPageTree(TPDFDictionary(PagesObj), nil);
end;

procedure TPDFDocument.LoadPageTree(ANode: TPDFDictionary; AInherit: TPDFDictionary);
var
  NodeType: string;
begin
  NodeType := ANode.GetAsName('Type');

  if NodeType = 'Pages' then
  begin
    // Intermediate node
    var KidsArr := ANode.GetAsArray('Kids');
    if KidsArr = nil then Exit;

    // Build inheritance dict: merge AInherit with current node's inheritable attrs
    var Inherit := TPDFDictionary.Create;
    try
      // Copy from parent first
      if AInherit <> nil then
        AInherit.ForEach(procedure(K: string; V: TPDFObject)
        begin
          Inherit.SetValue(K, V.Clone);
        end);
      // Override with this node's values (inheritable attributes)
      for var Key in ['MediaBox', 'CropBox', 'Rotate', 'Resources'] do
      begin
        var V := ANode.RawGet(Key);
        if V <> nil then
          Inherit.SetValue(Key, V.Clone);
      end;

      for var I := 0 to KidsArr.Count - 1 do
      begin
        var KidObj := KidsArr.Get(I);
        if (KidObj <> nil) and KidObj.IsDictionary then
          LoadPageTree(TPDFDictionary(KidObj), Inherit);
      end;
    finally
      Inherit.Free;
    end;
  end
  else if (NodeType = 'Page') or (NodeType = '') then
  begin
    // Leaf page — merge inherited attributes into the page dict if absent
    var MergedDict := TPDFDictionary(ANode.Clone);
    try
      if AInherit <> nil then
        AInherit.ForEach(procedure(K: string; V: TPDFObject)
        begin
          if not MergedDict.Contains(K) then
            MergedDict.SetValue(K, V.Clone);
        end);

      var Page := TPDFPage.Create(Self, MergedDict, FPages.Count, ANode.ID.Number);
      FPages.Add(Page);
    except
      MergedDict.Free;
      raise;
    end;
    // MergedDict ownership transferred to TPDFPage
  end;
end;

// =========================================================================
// Page accessors
// =========================================================================

function TPDFDocument.GetIsEncrypted: Boolean;
begin
  Result := (FParser <> nil) and FParser.IsEncrypted;
end;

function TPDFDocument.GetPageCount: Integer;
begin
  Result := FPages.Count;
end;

function TPDFDocument.GetPage(AIndex: Integer): TPDFPage;
begin
  if (AIndex < 0) or (AIndex >= FPages.Count) then
    raise EPDFPageNotFoundError.CreateFmt('Page index %d out of range (count=%d)',
      [AIndex, FPages.Count]);
  Result := FPages[AIndex];
end;

function TPDFDocument.AddPage(AWidth: Single; AHeight: Single): TPDFPage;
var
  PageDict: TPDFDictionary;
  MediaBox: TPDFArray;
begin
  PageDict := TPDFDictionary.Create;
  PageDict.SetValue('Type', TPDFName.Create('Page'));

  MediaBox := TPDFArray.Create;
  MediaBox.Add(TPDFReal.Create(0));
  MediaBox.Add(TPDFReal.Create(0));
  MediaBox.Add(TPDFReal.Create(AWidth));
  MediaBox.Add(TPDFReal.Create(AHeight));
  PageDict.SetValue('MediaBox', MediaBox);

  PageDict.SetValue('Resources', TPDFDictionary.Create);

  Result := TPDFPage.Create(Self, PageDict, FPages.Count);
  FPages.Add(Result);
end;

function TPDFDocument.RemovePage(AIndex: Integer): Boolean;
begin
  if (AIndex < 0) or (AIndex >= FPages.Count) then
    Exit(False);
  FPages.Delete(AIndex);
  // Re-number remaining pages
  for var I := AIndex to FPages.Count - 1 do
    FPages[I].FPageIndex := I;
  Result := True;
end;

// =========================================================================
// Metadata helpers
// =========================================================================

// Encode a Unicode string as PDF text string (UTF-16 BE with BOM $FE $FF).
function UnicodeStringToPDFBytes(const S: string): RawByteString;
var
  I: Integer;
  W: Word;
begin
  if S = '' then begin Result := ''; Exit; end;
  SetLength(Result, 2 + Length(S) * 2);
  PByte(@Result[1])^ := $FE;
  PByte(@Result[2])^ := $FF;
  for I := 1 to Length(S) do
  begin
    W := Ord(S[I]);
    PByte(@Result[2 + (I - 1) * 2 + 1])^ := W shr 8;
    PByte(@Result[2 + (I - 1) * 2 + 2])^ := W and $FF;
  end;
end;

// Return FInfoDict, creating and initialising it on first call.
// For loaded documents the parser's Info entries are cloned in so existing
// metadata is preserved when only some fields are updated.
function TPDFDocument.EnsureInfoDict: TPDFDictionary;
begin
  if FInfoDict = nil then
  begin
    if FParser <> nil then
    begin
      var InfoRef := FParser.Trailer.Get('Info');
      if (InfoRef <> nil) and InfoRef.IsDictionary then
        FInfoDict := TPDFDictionary(InfoRef.Clone)
      else
        FInfoDict := TPDFDictionary.Create;
    end
    else
      FInfoDict := TPDFDictionary.Create;
  end;
  Result := FInfoDict;
end;

// =========================================================================
// Metadata
// =========================================================================

function TPDFDocument.GetInfoString(const AKey: string): string;
begin
  if FInfoDict <> nil then
    Result := FInfoDict.GetAsUnicodeString(AKey)
  else if FParser <> nil then
  begin
    var InfoRef := FParser.Trailer.Get('Info');
    if (InfoRef <> nil) and InfoRef.IsDictionary then
      Result := TPDFDictionary(InfoRef).GetAsUnicodeString(AKey)
    else
      Result := '';
  end
  else
    Result := '';
end;

procedure TPDFDocument.SetInfoString(const AKey, AValue: string);
var
  Info: TPDFDictionary;
begin
  Info := EnsureInfoDict;
  if AValue = '' then
    Info.Remove(AKey)
  else
    Info.SetValue(AKey, TPDFString.Create(UnicodeStringToPDFBytes(AValue), False));
end;

function TPDFDocument.GetTitle:    string; begin Result := GetInfoString('Title');    end;
function TPDFDocument.GetAuthor:   string; begin Result := GetInfoString('Author');   end;
function TPDFDocument.GetSubject:  string; begin Result := GetInfoString('Subject');  end;
function TPDFDocument.GetCreator:  string; begin Result := GetInfoString('Creator');  end;
function TPDFDocument.GetProducer: string; begin Result := GetInfoString('Producer'); end;

procedure TPDFDocument.SetTitle(const AValue: string);    begin SetInfoString('Title',    AValue); end;
procedure TPDFDocument.SetAuthor(const AValue: string);   begin SetInfoString('Author',   AValue); end;
procedure TPDFDocument.SetSubject(const AValue: string);  begin SetInfoString('Subject',  AValue); end;
procedure TPDFDocument.SetCreator(const AValue: string);  begin SetInfoString('Creator',  AValue); end;
procedure TPDFDocument.SetProducer(const AValue: string); begin SetInfoString('Producer', AValue); end;

// =========================================================================
// Encryption / Authentication
// =========================================================================

function TPDFDocument.Authenticate(const APassword: string): Boolean;
var
  EncryptObj:  TPDFObject;
  EncryptDict: TPDFDictionary;
  FileIDBytes: TBytes;
  IDObj:       TPDFObject;
  IDArr:       TPDFArray;
  IDElem:      TPDFObject;
  RawID:       RawByteString;
  Info:        TPDFEncryptionInfo;
  Decryptor:   TPDFDecryptor;
begin
  Result := False;
  if FParser = nil then Exit;
  if not FParser.IsEncrypted then Exit(True);

  // Locate /Encrypt dict (may be an indirect reference)
  EncryptObj := FParser.Trailer.Get('Encrypt');
  if EncryptObj = nil then Exit;
  EncryptObj := EncryptObj.Dereference;
  if not EncryptObj.IsDictionary then Exit;
  EncryptDict := TPDFDictionary(EncryptObj);

  // Extract first element of /ID array as raw bytes
  SetLength(FileIDBytes, 0);
  IDObj := FParser.Trailer.Get('ID');
  if (IDObj <> nil) and IDObj.IsArray then
  begin
    IDArr := TPDFArray(IDObj);
    if IDArr.Count > 0 then
    begin
      IDElem := IDArr.Get(0);
      if (IDElem <> nil) and IDElem.IsString then
      begin
        RawID := TPDFString(IDElem).Bytes;
        SetLength(FileIDBytes, Length(RawID));
        if Length(RawID) > 0 then
          Move(RawID[1], FileIDBytes[0], Length(RawID));
      end;
    end;
  end;

  Info := TPDFEncryptionInfo.FromEncryptDict(EncryptDict, FileIDBytes);
  if not Info.IsValid then Exit;

  Decryptor := TPDFDecryptor.Create(Info);
  if not Decryptor.Authenticate(APassword) then
  begin
    Decryptor.Free;
    Exit;
  end;

  FDecryptor := Decryptor;   // interface assignment releases old value, AddRefs new
  FParser.SetDecryptionContext(FDecryptor);
  Result := True;
end;

// =========================================================================
// SaveToStream / SaveToFile  (Phase 5)
// =========================================================================

procedure TPDFDocument.SaveToStream(AStream: TStream; AMode: TPDFSaveMode);
begin
  if AMode = TPDFSaveMode.Incremental then
    raise EPDFNotSupportedError.Create(
      'Incremental save is not available on TPDFDocument; use TPDFIncrementalUpdater');

  if FParser <> nil then
    DoFullRewriteFromParser(AStream)
  else
    DoFullRewriteFromScratch(AStream);
end;

procedure TPDFDocument.SaveToFile(const APath: string; AMode: TPDFSaveMode);
begin
  var FS := TFileStream.Create(APath, fmCreate);
  try
    SaveToStream(FS, AMode);
  finally
    FS.Free;
  end;
end;

// -------------------------------------------------------------------------
// DoFullRewriteFromParser
// Walk the parser's XRef, clone every object, replace the /Pages tree with
// the current FPages list (pages may have been modified/added/removed), and
// write a fresh PDF using TPDFWriter.WriteFull.
// -------------------------------------------------------------------------
procedure TPDFDocument.DoFullRewriteFromParser(AStream: TStream);
var
  Objects:      TObjectDictionary<Integer, TPDFObject>;
  PagesObjNum:  Integer;
  CatalogObjNum: Integer;
  PageObjNums:  TArray<Integer>;
  NextNew:      Integer;
  I:            Integer;
begin
  Objects := TObjectDictionary<Integer, TPDFObject>.Create([doOwnsValues]);
  try
    // ---- Step 1: clone every in-use object from the XRef ----
    NextNew := FParser.XRef.HighestObjectNumber + 1;

    FParser.XRef.ForEach(
      procedure(ObjNum: Integer; Entry: TPDFXRefEntry)
      var
        Obj: TPDFObject;
        ObjType: string;
      begin
        if Entry.EntryType = TPDFXRefEntryType.Free then Exit;

        Obj := FParser.LoadObject(ObjNum, Entry.Generation);
        if (Obj = nil) or Obj.IsNull then Exit;

        // Skip PDF 1.5 infrastructure streams (ObjStm, XRef streams) —
        // constituent objects are written as plain indirect objects.
        if Obj.IsStream then
        begin
          ObjType := TPDFStream(Obj).Dict.GetAsName('Type');
          if (ObjType = 'ObjStm') or (ObjType = 'XRef') then Exit;
          if FParser.IsEncrypted then
            TPDFStream(Obj).StripEncryption  // decrypt in-place; preserves filters
          else
            TPDFStream(Obj).RawBytes;   // force lazy load before clone
        end
        else if Obj.IsDictionary then
        begin
          ObjType := TPDFDictionary(Obj).GetAsName('Type');
          if ObjType = 'XRef' then Exit;
        end;

        Objects.AddOrSetValue(ObjNum, Obj.Clone);
      end);

    // ---- Step 2: find /Pages root obj# ----
    PagesObjNum := 0;
    var PagesRaw := FCatalog.RawGet('Pages');
    if (PagesRaw <> nil) and PagesRaw.IsReference then
      PagesObjNum := TPDFReference(PagesRaw).RefID.Number
    else
    begin
      var PagesObj := FCatalog.Get('Pages');
      if (PagesObj <> nil) and (PagesObj.ID.Number > 0) then
        PagesObjNum := PagesObj.ID.Number;
    end;
    if PagesObjNum = 0 then
    begin
      PagesObjNum := NextNew;
      Inc(NextNew);
    end;

    // ---- Step 3: assign obj#s to current pages ----
    SetLength(PageObjNums, FPages.Count);
    for I := 0 to FPages.Count - 1 do
    begin
      if FPages[I].FOrigObjNum > 0 then
        PageObjNums[I] := FPages[I].FOrigObjNum
      else
      begin
        PageObjNums[I] := NextNew;
        Inc(NextNew);
      end;
    end;

    // ---- Step 4: rebuild flat /Pages tree ----
    var NewPagesDict := TPDFDictionary.Create;
    NewPagesDict.SetValue('Type',  TPDFName.Create('Pages'));
    NewPagesDict.SetValue('Count', TPDFInteger.Create(FPages.Count));
    var KidsArr := TPDFArray.Create;
    for I := 0 to FPages.Count - 1 do
      KidsArr.Add(TPDFReference.CreateNum(PageObjNums[I], 0));
    NewPagesDict.SetValue('Kids', KidsArr);
    Objects.AddOrSetValue(PagesObjNum, NewPagesDict);

    // ---- Step 5: write page dicts from FPages (with any modifications) ----
    for I := 0 to FPages.Count - 1 do
    begin
      var PageDict := TPDFDictionary(FPages[I].FDict.Clone);
      PageDict.SetValue('Type',   TPDFName.Create('Page'));
      PageDict.SetValue('Parent', TPDFReference.CreateNum(PagesObjNum, 0));
      PageDict.Remove('Kids');   // not a valid key on leaf pages

      // AppendContent override: register a new content stream and point /Contents to it
      if Length(FPages[I].FPendingContentOverride) > 0 then
      begin
        var ContentObjNum := NextNew;
        Inc(NextNew);
        var ContentStm := TPDFStream.Create;
        ContentStm.SetRawData(FPages[I].FPendingContentOverride);
        ContentStm.Dict.SetValue('Length',
          TPDFInteger.Create(Length(FPages[I].FPendingContentOverride)));
        Objects.AddOrSetValue(ContentObjNum, ContentStm);
        PageDict.SetValue('Contents', TPDFReference.CreateNum(ContentObjNum, 0));
      end;

      Objects.AddOrSetValue(PageObjNums[I], PageDict);
    end;

    // ---- Step 6: find catalog obj# and ensure /Pages ref is correct ----
    CatalogObjNum := 0;
    var RootRaw := FParser.Trailer.RawGet('Root');
    if (RootRaw <> nil) and RootRaw.IsReference then
      CatalogObjNum := TPDFReference(RootRaw).RefID.Number
    else if (FCatalog <> nil) and (FCatalog.ID.Number > 0) then
      CatalogObjNum := FCatalog.ID.Number;

    var CatObj: TPDFObject;
    if (CatalogObjNum > 0) and Objects.TryGetValue(CatalogObjNum, CatObj) and
       CatObj.IsDictionary then
      TPDFDictionary(CatObj).SetValue('Pages',
        TPDFReference.CreateNum(PagesObjNum, 0));

    // ---- Step 7: locate catalog and info dicts for WriteFull ----
    var CatalogDict: TPDFDictionary := nil;
    var InfoDict:    TPDFDictionary := nil;

    if (CatalogObjNum > 0) and Objects.TryGetValue(CatalogObjNum, CatObj) and
       CatObj.IsDictionary then
      CatalogDict := TPDFDictionary(CatObj);

    if FInfoDict <> nil then
    begin
      // Metadata was set — inject FInfoDict into Objects (reuse original obj# if present)
      var InfoObjNum: Integer := 0;
      var InfoRawRef := FParser.Trailer.RawGet('Info');
      if (InfoRawRef <> nil) and InfoRawRef.IsReference then
        InfoObjNum := TPDFReference(InfoRawRef).RefID.Number;
      if InfoObjNum = 0 then
      begin
        InfoObjNum := NextNew;
        Inc(NextNew);
      end;
      Objects.AddOrSetValue(InfoObjNum, FInfoDict.Clone);
      InfoDict := TPDFDictionary(Objects[InfoObjNum]);
    end
    else
    begin
      var InfoRawRef := FParser.Trailer.RawGet('Info');
      if (InfoRawRef <> nil) and InfoRawRef.IsReference then
      begin
        var InfoNum := TPDFReference(InfoRawRef).RefID.Number;
        var InfoObj: TPDFObject;
        if Objects.TryGetValue(InfoNum, InfoObj) and InfoObj.IsDictionary then
          InfoDict := TPDFDictionary(InfoObj);
      end;
    end;

    // ---- Step 8: write ----
    var Opts := TPDFWriteOptions.Default;
    Opts.Version := FVersion;
    var Writer := TPDFWriter.Create(AStream, Opts);
    try
      Writer.WriteFull(CatalogDict, InfoDict, Objects);
    finally
      Writer.Free;
    end;
  finally
    Objects.Free;
  end;
end;

// -------------------------------------------------------------------------
// DoFullRewriteFromScratch
// Document was created with AddPage (no parser).  Serialise FPages as a
// minimal PDF with a flat /Pages tree and no content streams.
// -------------------------------------------------------------------------
procedure TPDFDocument.DoFullRewriteFromScratch(AStream: TStream);
var
  Objects:  TObjectDictionary<Integer, TPDFObject>;
  PageNums: TArray<Integer>;
  PagesNum: Integer;
  CatNum:   Integer;
  I:        Integer;
begin
  Objects := TObjectDictionary<Integer, TPDFObject>.Create([doOwnsValues]);
  try
    FNextObjNum := 1;
    CatNum   := FNextObjNum; Inc(FNextObjNum);
    PagesNum := FNextObjNum; Inc(FNextObjNum);

    SetLength(PageNums, FPages.Count);
    for I := 0 to FPages.Count - 1 do
    begin
      PageNums[I] := FNextObjNum;
      Inc(FNextObjNum);
    end;

    // /Pages tree
    var PagesDict := TPDFDictionary.Create;
    PagesDict.SetValue('Type',  TPDFName.Create('Pages'));
    PagesDict.SetValue('Count', TPDFInteger.Create(FPages.Count));
    var Kids := TPDFArray.Create;
    for I := 0 to FPages.Count - 1 do
      Kids.Add(TPDFReference.CreateNum(PageNums[I], 0));
    PagesDict.SetValue('Kids', Kids);
    Objects.Add(PagesNum, PagesDict);

    // Page objects
    for I := 0 to FPages.Count - 1 do
    begin
      var PageDict := TPDFDictionary(FPages[I].FDict.Clone);
      PageDict.SetValue('Type',   TPDFName.Create('Page'));
      PageDict.SetValue('Parent', TPDFReference.CreateNum(PagesNum, 0));
      Objects.Add(PageNums[I], PageDict);
    end;

    // Catalog
    var CatalogDict := TPDFDictionary.Create;
    CatalogDict.SetValue('Type',  TPDFName.Create('Catalog'));
    CatalogDict.SetValue('Pages', TPDFReference.CreateNum(PagesNum, 0));
    Objects.Add(CatNum, CatalogDict);

    // Inject Info dict if metadata was set
    var InfoDictForWrite: TPDFDictionary := nil;
    if FInfoDict <> nil then
    begin
      var InfoNum := FNextObjNum; Inc(FNextObjNum);
      Objects.Add(InfoNum, FInfoDict.Clone);
      InfoDictForWrite := TPDFDictionary(Objects[InfoNum]);
    end;

    var Opts := TPDFWriteOptions.Default;
    Opts.Version := FVersion;
    var Writer := TPDFWriter.Create(AStream, Opts);
    try
      Writer.WriteFull(CatalogDict, InfoDictForWrite, Objects);
    finally
      Writer.Free;
    end;
  finally
    Objects.Free;
  end;
end;

// =========================================================================
// TPDFPage
// =========================================================================

constructor TPDFPage.Create(ADocument: TPDFDocument; ADict: TPDFDictionary;
  AIndex: Integer; AOrigObjNum: Integer);
begin
  inherited Create;
  FDocument   := ADocument;
  FDict       := ADict;
  FPageIndex  := AIndex;
  FOrigObjNum := AOrigObjNum;
  FRotation   := FDict.GetAsInteger('Rotate', 0);

  // Normalize rotation to 0..270
  FRotation := ((FRotation mod 360) + 360) mod 360;
  if FRotation mod 90 <> 0 then FRotation := 0;

  FMediaBox := FDict.GetRect('MediaBox').Normalize;
  FCropBox  := FDict.GetRect('CropBox').Normalize;
  if FCropBox.IsEmpty then
    FCropBox := FMediaBox;
end;

destructor TPDFPage.Destroy;
begin
  FDict.Free;
  inherited;
end;

function TPDFPage.Dict: TPDFDictionary;
begin
  Result := FDict;
end;

function TPDFPage.GetMediaBox: TPDFRect; begin Result := FMediaBox; end;
function TPDFPage.GetCropBox: TPDFRect;  begin Result := FCropBox;  end;

function TPDFPage.GetWidth: Single;
begin
  if (FRotation = 90) or (FRotation = 270) then
    Result := FCropBox.Height
  else
    Result := FCropBox.Width;
end;

function TPDFPage.GetHeight: Single;
begin
  if (FRotation = 90) or (FRotation = 270) then
    Result := FCropBox.Width
  else
    Result := FCropBox.Height;
end;

function TPDFPage.Resources: TPDFDictionary;
begin
  var R := FDict.Get('Resources');
  if (R <> nil) and R.IsDictionary then
    Result := TPDFDictionary(R)
  else
    Result := nil;
end;

function TPDFPage.GetResource(const AType, AName: string): TPDFObject;
begin
  var Res := Resources;
  if Res = nil then Exit(nil);
  var TypeDict := Res.GetAsDictionary(AType);
  if TypeDict = nil then Exit(nil);
  Result := TypeDict.Get(AName);
end;

function TPDFPage.BuildContentStream: TBytes;
var
  Merged: TBytesStream;
begin
  Merged := TBytesStream.Create;
  try
    var ContentObj := FDict.RawGet('Contents');
    if ContentObj = nil then
      Exit(nil);

    ContentObj := ContentObj.Dereference;

    if ContentObj.IsStream then
    begin
      var S := TPDFStream(ContentObj);
      var D := S.DecodedBytes;
      if Length(D) > 0 then
        Merged.Write(D[0], Length(D));
      // Add a space separator between streams
      var Sep: Byte := 32;
      Merged.Write(Sep, 1);
    end
    else if ContentObj.IsArray then
    begin
      var A := TPDFArray(ContentObj);
      for var I := 0 to A.Count - 1 do
      begin
        var Item := A.Get(I);
        if Item.IsStream then
        begin
          var S := TPDFStream(Item);
          var D := S.DecodedBytes;
          if Length(D) > 0 then
            Merged.Write(D[0], Length(D));
          var Sep: Byte := 32;
          Merged.Write(Sep, 1);
        end;
      end;
    end;

    Result := Copy(Merged.Bytes, 0, Merged.Size);
  finally
    Merged.Free;
  end;
end;

function TPDFPage.ContentStreamBytes: TBytes;
begin
  Result := BuildContentStream;
end;

procedure TPDFPage.AppendContent(const AOperators: TBytes);
var
  Current:   TBytes;
  MergedLen: Integer;
begin
  if Length(AOperators) = 0 then Exit;

  // Build on top of any previously-appended override, not the on-disk bytes,
  // so successive AppendContent calls accumulate correctly.
  if Length(FPendingContentOverride) > 0 then
    Current := FPendingContentOverride
  else
    Current := BuildContentStream;

  if Length(Current) = 0 then
  begin
    FPendingContentOverride := Copy(AOperators);
    Exit;
  end;

  MergedLen := Length(Current) + 1 + Length(AOperators);
  SetLength(FPendingContentOverride, MergedLen);
  Move(Current[0],    FPendingContentOverride[0],               Length(Current));
  FPendingContentOverride[Length(Current)] := Ord(' ');         // operator separator
  Move(AOperators[0], FPendingContentOverride[Length(Current) + 1], Length(AOperators));
end;

end.
