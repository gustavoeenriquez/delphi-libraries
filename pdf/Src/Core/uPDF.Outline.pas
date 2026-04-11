unit uPDF.Outline;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Generics.Collections,
  uPDF.Types, uPDF.Errors, uPDF.Objects;

type
  // -------------------------------------------------------------------------
  // PDF destination type (§12.3.2)
  // -------------------------------------------------------------------------
  TPDFDestKind = (
    XYZ,    // [page /XYZ left top zoom]
    Fit,    // [page /Fit]
    FitH,   // [page /FitH top]
    FitV,   // [page /FitV left]
    FitR,   // [page /FitR left bottom right top]
    FitB,   // [page /FitB]
    FitBH,  // [page /FitBH top]
    FitBV   // [page /FitBV left]
  );

  TPDFDestination = record
    IsValid:   Boolean;
    PageIndex: Integer;      // 0-based; -1 if unresolved
    Kind:      TPDFDestKind;
    Left, Top: Single;       // used by XYZ, FitH, FitV, FitR, FitB*
    Right, Bottom: Single;   // used by FitR
    Zoom:      Single;       // used by XYZ (0 = keep current)
  end;

  // -------------------------------------------------------------------------
  // One entry in the bookmarks tree
  // -------------------------------------------------------------------------
  TPDFOutlineItem = class
  private
    FChildren: TObjectList<TPDFOutlineItem>;
  public
    Title:      string;
    Dest:       TPDFDestination;
    ActionURI:  string;         // non-empty when action is /URI
    ActionPage: Integer;        // page for /GoTo/-/GoToR quick access
    IsOpen:     Boolean;        // /Count > 0
    Color:      TPDFColor;      // /C array (RGB 0..1)
    Bold:       Boolean;        // /F bit 1
    Italic:     Boolean;        // /F bit 0
    [Weak] Parent: TPDFOutlineItem;

    constructor Create;
    destructor  Destroy; override;

    function  AddChild: TPDFOutlineItem;
    property  Children: TObjectList<TPDFOutlineItem> read FChildren;
    function  ChildCount: Integer; inline;
  end;

  // -------------------------------------------------------------------------
  // Complete bookmarks tree for a document
  // -------------------------------------------------------------------------
  TPDFOutline = class
  private
    FItems: TObjectList<TPDFOutlineItem>;

    procedure ParseNode(ADict: TPDFDictionary; AParent: TPDFOutlineItem;
                        AResolver: IObjectResolver; APageTable: TDictionary<Integer, Integer>);
    procedure ResolveDestination(ADestArr: TPDFArray;
                                 out ADest: TPDFDestination;
                                 APageTable: TDictionary<Integer, Integer>);
    procedure ResolveDestFromName(const AName: string;
                                  AResolver: IObjectResolver;
                                  ACatalog: TPDFDictionary;
                                  out ADest: TPDFDestination;
                                  APageTable: TDictionary<Integer, Integer>);
    procedure BuildPageTable(ANode: TPDFDictionary; AResolver: IObjectResolver;
                             ATable: TDictionary<Integer, Integer>;
                             var AIndex: Integer);
  public
    constructor Create;
    destructor  Destroy; override;

    // Parse the /Outlines entry from the document catalog.
    // AResolver is the parser (IObjectResolver).
    // ACatalog is FParser.Trailer.Get('Root') cast to dict.
    procedure LoadFromCatalog(ACatalog: TPDFDictionary;
                              AResolver: IObjectResolver);

    function  IsEmpty: Boolean; inline;
    function  Count: Integer;   inline;

    property  Items: TObjectList<TPDFOutlineItem> read FItems;
  end;

// -------------------------------------------------------------------------
// Standalone helper: resolve a PDF destination array into TPDFDestination.
// APageTable maps object-number of a page dict → 0-based page index.
// -------------------------------------------------------------------------
function ResolvePDFDestination(ADestArr: TPDFArray;
  APageTable: TDictionary<Integer, Integer>): TPDFDestination;

implementation

// =========================================================================
// TPDFOutlineItem
// =========================================================================

constructor TPDFOutlineItem.Create;
begin
  inherited;
  FChildren := TObjectList<TPDFOutlineItem>.Create(True);
  Color     := TPDFColor.MakeGray(0);
end;

destructor TPDFOutlineItem.Destroy;
begin
  FChildren.Free;
  inherited;
end;

function TPDFOutlineItem.AddChild: TPDFOutlineItem;
begin
  Result        := TPDFOutlineItem.Create;
  Result.Parent := Self;
  FChildren.Add(Result);
end;

function TPDFOutlineItem.ChildCount: Integer;
begin
  Result := FChildren.Count;
end;

// =========================================================================
// TPDFOutline
// =========================================================================

constructor TPDFOutline.Create;
begin
  inherited;
  FItems := TObjectList<TPDFOutlineItem>.Create(True);
end;

destructor TPDFOutline.Destroy;
begin
  FItems.Free;
  inherited;
end;

function TPDFOutline.IsEmpty: Boolean; begin Result := FItems.Count = 0; end;
function TPDFOutline.Count: Integer;   begin Result := FItems.Count;    end;

// =========================================================================
// Page object-number → page-index table
// =========================================================================

procedure TPDFOutline.BuildPageTable(ANode: TPDFDictionary;
  AResolver: IObjectResolver; ATable: TDictionary<Integer, Integer>;
  var AIndex: Integer);
var
  NodeType: string;
  KidsArr:  TPDFArray;
  I:        Integer;
  KidObj:   TPDFObject;
  ObjID:    TPDFObjectID;
begin
  if ANode = nil then Exit;
  NodeType := ANode.GetAsName('Type');
  if NodeType = 'Pages' then
  begin
    KidsArr := ANode.GetAsArray('Kids');
    if KidsArr = nil then Exit;
    for I := 0 to KidsArr.Count - 1 do
    begin
      KidObj := KidsArr.Get(I);
      if KidObj = nil then Continue;
      // Capture the object number before dereferencing
      if KidObj is TPDFReference then
      begin
        ObjID := TPDFReference(KidObj).RefID;
        KidObj := KidObj.Dereference;
        if KidObj.IsDictionary then
        begin
          var KidDict := TPDFDictionary(KidObj);
          var KidType := KidDict.GetAsName('Type');
          if KidType = 'Page' then
            ATable.AddOrSetValue(ObjID.Number, AIndex)
          else
            ATable.AddOrSetValue(ObjID.Number, -1);  // intermediate
          BuildPageTable(KidDict, AResolver, ATable, AIndex);
        end;
      end
      else if KidObj.IsDictionary then
        BuildPageTable(TPDFDictionary(KidObj), AResolver, ATable, AIndex);
    end;
  end
  else if (NodeType = 'Page') or (NodeType = '') then
    Inc(AIndex);
end;

// =========================================================================
// Destination resolution
// =========================================================================

function ResolvePDFDestination(ADestArr: TPDFArray;
  APageTable: TDictionary<Integer, Integer>): TPDFDestination;
var
  PageObj: TPDFObject;
  Kind:    string;
  PageNum: Integer;
begin
  Result.IsValid    := False;
  Result.PageIndex  := -1;
  Result.Left       := 0; Result.Top  := 0;
  Result.Right      := 0; Result.Bottom := 0;
  Result.Zoom       := 0;
  Result.Kind       := TPDFDestKind.XYZ;

  if (ADestArr = nil) or (ADestArr.Count < 2) then Exit;

  // First element = page reference
  PageObj := ADestArr.Get(0);
  if PageObj is TPDFReference then
  begin
    var ObjNum := TPDFReference(PageObj).RefID.Number;
    if not APageTable.TryGetValue(ObjNum, PageNum) then
      PageNum := -1;
  end
  else if PageObj is TPDFInteger then
    PageNum := TPDFInteger(PageObj).AsInteger
  else
    PageNum := -1;

  Result.PageIndex := PageNum;
  Kind := ADestArr.GetAsName(1);

  if Kind = 'XYZ' then
  begin
    Result.Kind := TPDFDestKind.XYZ;
    Result.Left := ADestArr.GetAsNumber(2, 0);
    Result.Top  := ADestArr.GetAsNumber(3, 0);
    Result.Zoom := ADestArr.GetAsNumber(4, 0);
  end
  else if Kind = 'Fit' then
    Result.Kind := TPDFDestKind.Fit
  else if Kind = 'FitH' then
  begin
    Result.Kind := TPDFDestKind.FitH;
    Result.Top  := ADestArr.GetAsNumber(2, 0);
  end
  else if Kind = 'FitV' then
  begin
    Result.Kind := TPDFDestKind.FitV;
    Result.Left := ADestArr.GetAsNumber(2, 0);
  end
  else if Kind = 'FitR' then
  begin
    Result.Kind   := TPDFDestKind.FitR;
    Result.Left   := ADestArr.GetAsNumber(2, 0);
    Result.Bottom := ADestArr.GetAsNumber(3, 0);
    Result.Right  := ADestArr.GetAsNumber(4, 0);
    Result.Top    := ADestArr.GetAsNumber(5, 0);
  end
  else if Kind = 'FitB'  then Result.Kind := TPDFDestKind.FitB
  else if Kind = 'FitBH' then
  begin
    Result.Kind := TPDFDestKind.FitBH;
    Result.Top  := ADestArr.GetAsNumber(2, 0);
  end
  else if Kind = 'FitBV' then
  begin
    Result.Kind := TPDFDestKind.FitBV;
    Result.Left := ADestArr.GetAsNumber(2, 0);
  end;

  Result.IsValid := (PageNum >= 0);
end;

procedure TPDFOutline.ResolveDestination(ADestArr: TPDFArray;
  out ADest: TPDFDestination; APageTable: TDictionary<Integer, Integer>);
begin
  ADest := ResolvePDFDestination(ADestArr, APageTable);
end;

procedure TPDFOutline.ResolveDestFromName(const AName: string;
  AResolver: IObjectResolver; ACatalog: TPDFDictionary;
  out ADest: TPDFDestination; APageTable: TDictionary<Integer, Integer>);
var
  NamesObj: TPDFObject;
  DestsDict: TPDFDictionary;
  DestObj:   TPDFObject;
  DestArr:   TPDFArray;
begin
  ADest.IsValid := False;
  // Look in /Names/Dests name tree
  NamesObj := ACatalog.Get('Names');
  if (NamesObj <> nil) and NamesObj.IsDictionary then
  begin
    DestsDict := TPDFDictionary(NamesObj).GetAsDictionary('Dests');
    if DestsDict <> nil then
    begin
      // Simplified: only handles flat /Names array, not the full B-tree
      var NamesArr := DestsDict.GetAsArray('Names');
      if NamesArr <> nil then
      begin
        var I := 0;
        while I + 1 < NamesArr.Count do
        begin
          if NamesArr.Get(I).AsUnicodeString = AName then
          begin
            DestObj := NamesArr.Get(I + 1);
            if DestObj.IsDictionary then
            begin
              DestArr := TPDFDictionary(DestObj).GetAsArray('D');
              if DestArr <> nil then
                ResolveDestination(DestArr, ADest, APageTable);
            end
            else if DestObj.IsArray then
              ResolveDestination(TPDFArray(DestObj), ADest, APageTable);
            Exit;
          end;
          Inc(I, 2);
        end;
      end;
    end;
  end;
  // Fall back to /Dests dict in catalog (old-style named destinations)
  var OldDests := ACatalog.GetAsDictionary('Dests');
  if OldDests <> nil then
  begin
    DestObj := OldDests.Get(AName);
    if DestObj <> nil then
    begin
      if DestObj.IsArray then
        ResolveDestination(TPDFArray(DestObj), ADest, APageTable)
      else if DestObj.IsDictionary then
      begin
        DestArr := TPDFDictionary(DestObj).GetAsArray('D');
        if DestArr <> nil then
          ResolveDestination(DestArr, ADest, APageTable);
      end;
    end;
  end;
end;

// =========================================================================
// Main parse loop
// =========================================================================

procedure TPDFOutline.ParseNode(ADict: TPDFDictionary;
  AParent: TPDFOutlineItem; AResolver: IObjectResolver;
  APageTable: TDictionary<Integer, Integer>);
var
  Item:     TPDFOutlineItem;
  DestObj:  TPDFObject;
  ActObj:   TPDFObject;
  ColorArr: TPDFArray;
  Count:    Integer;
begin
  if ADict = nil then Exit;

  // Create item (either a root placeholder or a child)
  if AParent = nil then
    Item := nil   // "root" node — only iterate its children
  else
  begin
    if AParent.Parent = nil then
      // top-level
      Item := TPDFOutlineItem.Create
    else
      Item := AParent.AddChild;

    if Item <> AParent then  // adding to parent container when at top level
    begin
      // Title
      Item.Title := ADict.GetAsUnicodeString('Title');

      // Destination
      DestObj := ADict.Get('Dest');
      if DestObj <> nil then
      begin
        DestObj := DestObj.Dereference;
        if DestObj.IsArray then
          ResolveDestination(TPDFArray(DestObj), Item.Dest, APageTable)
        else if DestObj.IsString then
          ResolveDestFromName(TPDFString(DestObj).ToUnicode,
            AResolver, nil {caller should pass catalog}, Item.Dest, APageTable);
      end;

      // Action
      ActObj := ADict.Get('A');
      if ActObj <> nil then
      begin
        ActObj := ActObj.Dereference;
        if ActObj.IsDictionary then
        begin
          var ActDict := TPDFDictionary(ActObj);
          var ActType := ActDict.GetAsName('S');
          if (ActType = 'GoTo') or (ActType = '') then
          begin
            var DArr := ActDict.GetAsArray('D');
            if DArr <> nil then
              ResolveDestination(DArr, Item.Dest, APageTable)
            else
            begin
              var DStr := ActDict.Get('D');
              if (DStr <> nil) and DStr.IsString then
                ResolveDestFromName(TPDFString(DStr).ToUnicode,
                  AResolver, nil, Item.Dest, APageTable);
            end;
          end
          else if ActType = 'URI' then
            Item.ActionURI := ActDict.GetAsUnicodeString('URI');
        end;
      end;

      // Style flags (/F: bit 0 = italic, bit 1 = bold)
      var F := ADict.GetAsInteger('F', 0);
      Item.Italic := (F and 1) <> 0;
      Item.Bold   := (F and 2) <> 0;

      // Color
      ColorArr := ADict.GetAsArray('C');
      if (ColorArr <> nil) and (ColorArr.Count >= 3) then
        Item.Color := TPDFColor.MakeRGB(
          ColorArr.GetAsNumber(0, 0),
          ColorArr.GetAsNumber(1, 0),
          ColorArr.GetAsNumber(2, 0));

      // Open/closed state
      Count      := ADict.GetAsInteger('Count', 0);
      Item.IsOpen := Count > 0;
    end;
  end;

  // Recurse into /First child
  var FirstObj := ADict.Get('First');
  if (FirstObj <> nil) then
  begin
    FirstObj := FirstObj.Dereference;
    if FirstObj.IsDictionary then
    begin
      var ChildDict := TPDFDictionary(FirstObj);
      var Container := Item;
      if Container = nil then Container := AParent;

      // Iterate siblings via /Next
      var CurDict := ChildDict;
      while CurDict <> nil do
      begin
        ParseNode(CurDict, Container, AResolver, APageTable);

        var NextObj := CurDict.Get('Next');
        if NextObj <> nil then
        begin
          NextObj := NextObj.Dereference;
          if NextObj.IsDictionary then
            CurDict := TPDFDictionary(NextObj)
          else
            CurDict := nil;
        end
        else
          CurDict := nil;
      end;
    end;
  end;

  // If top-level item was created, add to root
  if (AParent <> nil) and (AParent.Parent = nil) and (Item <> nil) then
    FItems.Add(Item);
end;

procedure TPDFOutline.LoadFromCatalog(ACatalog: TPDFDictionary;
  AResolver: IObjectResolver);
var
  OutlineObj: TPDFObject;
  OutlineDict: TPDFDictionary;
  PagesObj:    TPDFObject;
  PageTable:   TDictionary<Integer, Integer>;
  Idx:         Integer;
begin
  FItems.Clear;

  OutlineObj := ACatalog.Get('Outlines');
  if OutlineObj = nil then Exit;
  OutlineObj := OutlineObj.Dereference;
  if not OutlineObj.IsDictionary then Exit;
  OutlineDict := TPDFDictionary(OutlineObj);

  // Build page object-number → index table
  PageTable := TDictionary<Integer, Integer>.Create;
  try
    PagesObj := ACatalog.Get('Pages');
    if (PagesObj <> nil) then
    begin
      PagesObj := PagesObj.Dereference;
      if PagesObj.IsDictionary then
      begin
        Idx := 0;
        BuildPageTable(TPDFDictionary(PagesObj), AResolver, PageTable, Idx);
      end;
    end;

    // Parse the outline tree; pass a dummy root so ParseNode knows it's the top level
    var DummyRoot := TPDFOutlineItem.Create;
    try
      DummyRoot.Parent := nil;
      ParseNode(OutlineDict, DummyRoot, AResolver, PageTable);
    finally
      DummyRoot.Free;
    end;
  finally
    PageTable.Free;
  end;
end;

end.
