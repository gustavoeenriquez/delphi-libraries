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
    FDecryptor:   TPDFDecryptor; // nil for unencrypted PDFs
    FNextObjNum:  Integer;       // For write path: next available object number

    procedure LoadPages;
    procedure LoadPageTree(ANode: TPDFDictionary; AInherit: TPDFDictionary);

    function  GetPageCount: Integer;
    function  GetPage(AIndex: Integer): TPDFPage;
    function  GetIsEncrypted: Boolean;
    function  NewObjectNumber: Integer;

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

    property  Title:    string read GetTitle    write SetTitle;
    property  Author:   string read GetAuthor   write SetAuthor;

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

    function  GetWidth: Single;
    function  GetHeight: Single;
    function  GetMediaBox: TPDFRect;
    function  GetCropBox: TPDFRect;

    // Build merged content stream (may be array of streams)
    function  BuildContentStream: TBytes;

  public
    constructor Create(ADocument: TPDFDocument; ADict: TPDFDictionary;
      AIndex: Integer);
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

    property  PageIndex: Integer read FPageIndex;
    property  Document:  TPDFDocument read FDocument;
  end;

implementation

uses
  System.Math;

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
  FDecryptor.Free;
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

      var Page := TPDFPage.Create(Self, MergedDict, FPages.Count);
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
// Metadata
// =========================================================================

function TPDFDocument.GetTitle: string;
begin
  var InfoRef := FParser.Trailer.Get('Info');
  if (InfoRef <> nil) and InfoRef.IsDictionary then
    Result := TPDFDictionary(InfoRef).GetAsUnicodeString('Title')
  else
    Result := '';
end;

function TPDFDocument.GetAuthor: string;
begin
  var InfoRef := FParser.Trailer.Get('Info');
  if (InfoRef <> nil) and InfoRef.IsDictionary then
    Result := TPDFDictionary(InfoRef).GetAsUnicodeString('Author')
  else
    Result := '';
end;

function TPDFDocument.GetSubject: string;
begin
  var InfoRef := FParser.Trailer.Get('Info');
  if (InfoRef <> nil) and InfoRef.IsDictionary then
    Result := TPDFDictionary(InfoRef).GetAsUnicodeString('Subject')
  else
    Result := '';
end;

function TPDFDocument.GetCreator: string;
begin
  var InfoRef := FParser.Trailer.Get('Info');
  if (InfoRef <> nil) and InfoRef.IsDictionary then
    Result := TPDFDictionary(InfoRef).GetAsUnicodeString('Creator')
  else
    Result := '';
end;

function TPDFDocument.GetProducer: string;
begin
  var InfoRef := FParser.Trailer.Get('Info');
  if (InfoRef <> nil) and InfoRef.IsDictionary then
    Result := TPDFDictionary(InfoRef).GetAsUnicodeString('Producer')
  else
    Result := '';
end;

procedure TPDFDocument.SetTitle(const AValue: string);
begin
  // TODO: create/update Info dict
end;

procedure TPDFDocument.SetAuthor(const AValue: string);
begin
  // TODO: create/update Info dict
end;

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

  FDecryptor.Free;
  FDecryptor := Decryptor;
  FParser.SetDecryptionContext(FDecryptor);
  Result := True;
end;

// =========================================================================
// SaveToStream / SaveToFile  (Phase 5)
// =========================================================================

procedure TPDFDocument.SaveToStream(AStream: TStream; AMode: TPDFSaveMode);
begin
  raise EPDFNotSupportedError.Create('PDF writing not yet implemented (Phase 5)');
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

// =========================================================================
// TPDFPage
// =========================================================================

constructor TPDFPage.Create(ADocument: TPDFDocument; ADict: TPDFDictionary;
  AIndex: Integer);
begin
  inherited Create;
  FDocument   := ADocument;
  FDict       := ADict;
  FPageIndex  := AIndex;
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

end.
