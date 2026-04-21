unit uPDF.TOC;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Outline;

type
  // -------------------------------------------------------------------------
  // TPDFTOCEntry — one node in the bookmark / outline tree.
  //
  // Build the tree by calling Add (top-level) or AddChild (nested), then pass
  // the TPDFTOCBuilder to TPDFBuilder.TOCBuilder before calling SaveToStream.
  //
  // Example:
  //   var TOC := TPDFTOCBuilder.Create;
  //   var Ch1 := TOC.Add('Chapter 1', 0);           // goes to page 1 (0-based)
  //       Ch1.AddChild('Section 1.1', 0);
  //       Ch1.AddChild('Section 1.2', 1);
  //   TOC.Add('Chapter 2', 2);
  //   Builder.TOCBuilder := TOC;
  //   Builder.SaveToFile('out.pdf');
  //   TOC.Free;
  // -------------------------------------------------------------------------
  TPDFTOCEntry = class
  private
    FChildren: TObjectList<TPDFTOCEntry>;
  public
    Title:    string;
    PageIndex: Integer;       // 0-based; -1 = no destination
    DestKind: TPDFDestKind;   // default = Fit
    DestTop:  Single;         // page Y for FitH / XYZ (0 = null / keep)
    DestLeft: Single;         // page X for FitV / XYZ (0 = null / keep)
    Bold:     Boolean;
    Italic:   Boolean;
    IsOpen:   Boolean;        // show children expanded by default

    constructor Create;
    destructor  Destroy; override;

    // Add a child entry; returns the new child so you can configure it.
    function AddChild(const ATitle: string; APageIndex: Integer): TPDFTOCEntry;

    property Children:   TObjectList<TPDFTOCEntry> read FChildren;
    function ChildCount: Integer; inline;
  end;

  // -------------------------------------------------------------------------
  // TPDFTOCBuilder — manages the root list and serialises the tree to PDF.
  // -------------------------------------------------------------------------
  TPDFTOCBuilder = class
  private
    FItems: TObjectList<TPDFTOCEntry>;

    // Pass 1: assign one object number to every entry in the subtree.
    procedure AssignNumbers(AItems: TObjectList<TPDFTOCEntry>;
      var ANext: Integer; AMap: TDictionary<TPDFTOCEntry, Integer>);

    // Count ALL descendant entries (for the outline root's /Count).
    function CountAll(AItems: TObjectList<TPDFTOCEntry>): Integer;

    // Build a [pageRef /Fit*] destination array for AEntry.
    // Returns nil if the page index is out of range.
    function MakeDestArray(AEntry: TPDFTOCEntry;
      const APageObjNums: TArray<Integer>): TPDFArray;

    // Encode ATitle as a PDF UTF-16BE string (with BOM).
    class function MakeTitleString(const ATitle: string): TPDFString; static;

    // Pass 2: create the dict for every entry and add to ADest.
    procedure BuildDicts(AItems: TObjectList<TPDFTOCEntry>;
      AParentNum: Integer; AMap: TDictionary<TPDFTOCEntry, Integer>;
      const APageObjNums: TArray<Integer>;
      ADest: TDictionary<Integer, TPDFObject>);

  public
    constructor Create;
    destructor  Destroy; override;

    // Add a top-level bookmark; returns the entry for further configuration.
    function Add(const ATitle: string; APageIndex: Integer): TPDFTOCEntry;

    function IsEmpty: Boolean; inline;
    function Count: Integer;   inline;

    property Items: TObjectList<TPDFTOCEntry> read FItems;

    // ---------------------------------------------------------------------------
    // SerializeTo
    //
    // Adds all outline objects to ADest with object numbers starting at ANextNum.
    // APageObjNums[i] must contain the indirect-object number of page i.
    // Returns the object number of the /Outlines root dict (add it to the catalog
    // as /Outlines, and set /PageMode /UseOutlines so viewers open the panel).
    // Returns -1 if the TOC is empty.
    // ---------------------------------------------------------------------------
    function SerializeTo(ADest: TDictionary<Integer, TPDFObject>;
      var ANextNum: Integer;
      const APageObjNums: TArray<Integer>): Integer;
  end;

implementation

// ===========================================================================
// TPDFTOCEntry
// ===========================================================================

constructor TPDFTOCEntry.Create;
begin
  inherited;
  FChildren  := TObjectList<TPDFTOCEntry>.Create(True);
  PageIndex  := -1;
  DestKind   := TPDFDestKind.Fit;
  IsOpen     := True;
end;

destructor TPDFTOCEntry.Destroy;
begin
  FChildren.Free;
  inherited;
end;

function TPDFTOCEntry.AddChild(const ATitle: string; APageIndex: Integer): TPDFTOCEntry;
begin
  Result            := TPDFTOCEntry.Create;
  Result.Title      := ATitle;
  Result.PageIndex  := APageIndex;
  FChildren.Add(Result);
end;

function TPDFTOCEntry.ChildCount: Integer;
begin
  Result := FChildren.Count;
end;

// ===========================================================================
// TPDFTOCBuilder
// ===========================================================================

constructor TPDFTOCBuilder.Create;
begin
  inherited;
  FItems := TObjectList<TPDFTOCEntry>.Create(True);
end;

destructor TPDFTOCBuilder.Destroy;
begin
  FItems.Free;
  inherited;
end;

function TPDFTOCBuilder.Add(const ATitle: string; APageIndex: Integer): TPDFTOCEntry;
begin
  Result           := TPDFTOCEntry.Create;
  Result.Title     := ATitle;
  Result.PageIndex := APageIndex;
  FItems.Add(Result);
end;

function TPDFTOCBuilder.IsEmpty: Boolean; begin Result := FItems.Count = 0; end;
function TPDFTOCBuilder.Count: Integer;   begin Result := FItems.Count;    end;

// ---------------------------------------------------------------------------
// AssignNumbers — pass 1
// ---------------------------------------------------------------------------

procedure TPDFTOCBuilder.AssignNumbers(AItems: TObjectList<TPDFTOCEntry>;
  var ANext: Integer; AMap: TDictionary<TPDFTOCEntry, Integer>);
begin
  for var Entry in AItems do
  begin
    AMap[Entry] := ANext;
    Inc(ANext);
    if Entry.ChildCount > 0 then
      AssignNumbers(Entry.FChildren, ANext, AMap);
  end;
end;

// ---------------------------------------------------------------------------
// CountAll — total descendant count for the root /Count
// ---------------------------------------------------------------------------

function TPDFTOCBuilder.CountAll(AItems: TObjectList<TPDFTOCEntry>): Integer;
begin
  Result := AItems.Count;
  for var Entry in AItems do
    if Entry.ChildCount > 0 then
      Inc(Result, CountAll(Entry.FChildren));
end;

// ---------------------------------------------------------------------------
// MakeTitleString — UTF-16BE with BOM, same encoding as /Info strings
// ---------------------------------------------------------------------------

class function TPDFTOCBuilder.MakeTitleString(const ATitle: string): TPDFString;
var
  UTF16BE: TBytes;
  Raw:     RawByteString;
begin
  UTF16BE := TEncoding.BigEndianUnicode.GetBytes(ATitle);
  SetLength(Raw, 2 + Length(UTF16BE));
  Raw[1] := #$FE;
  Raw[2] := #$FF;
  if Length(UTF16BE) > 0 then
    Move(UTF16BE[0], Raw[3], Length(UTF16BE));
  Result := TPDFString.Create(Raw);
end;

// ---------------------------------------------------------------------------
// MakeDestArray
// ---------------------------------------------------------------------------

function TPDFTOCBuilder.MakeDestArray(AEntry: TPDFTOCEntry;
  const APageObjNums: TArray<Integer>): TPDFArray;
var
  Arr:        TPDFArray;
  PageObjNum: Integer;
begin
  Result := nil;
  if (AEntry.PageIndex < 0) or (AEntry.PageIndex >= Length(APageObjNums)) then
    Exit;

  PageObjNum := APageObjNums[AEntry.PageIndex];
  Arr := TPDFArray.Create;
  Arr.Add(TPDFReference.CreateNum(PageObjNum, 0));

  case AEntry.DestKind of
    TPDFDestKind.XYZ:
    begin
      Arr.Add(TPDFName.Create('XYZ'));
      // null = keep current viewer position unless caller set an explicit value
      if AEntry.DestLeft > 0 then Arr.Add(TPDFReal.Create(AEntry.DestLeft))
      else                        Arr.Add(TPDFNull.Instance.Clone);
      if AEntry.DestTop  > 0 then Arr.Add(TPDFReal.Create(AEntry.DestTop))
      else                        Arr.Add(TPDFNull.Instance.Clone);
      Arr.Add(TPDFNull.Instance.Clone);  // zoom = keep current
    end;
    TPDFDestKind.FitH:
    begin
      Arr.Add(TPDFName.Create('FitH'));
      if AEntry.DestTop > 0 then Arr.Add(TPDFReal.Create(AEntry.DestTop))
      else                       Arr.Add(TPDFNull.Instance.Clone);
    end;
    TPDFDestKind.FitV:
    begin
      Arr.Add(TPDFName.Create('FitV'));
      if AEntry.DestLeft > 0 then Arr.Add(TPDFReal.Create(AEntry.DestLeft))
      else                        Arr.Add(TPDFNull.Instance.Clone);
    end;
    else  // Fit, FitB, and everything else — use /Fit (safest default)
      Arr.Add(TPDFName.Create('Fit'));
  end;

  Result := Arr;
end;

// ---------------------------------------------------------------------------
// BuildDicts — pass 2: create TPDFDictionary for every entry
// ---------------------------------------------------------------------------

procedure TPDFTOCBuilder.BuildDicts(AItems: TObjectList<TPDFTOCEntry>;
  AParentNum: Integer; AMap: TDictionary<TPDFTOCEntry, Integer>;
  const APageObjNums: TArray<Integer>;
  ADest: TDictionary<Integer, TPDFObject>);
var
  I:       Integer;
  Entry:   TPDFTOCEntry;
  ItemNum: Integer;
  D:       TPDFDictionary;
  DestArr: TPDFArray;
  StyleF:  Integer;
begin
  for I := 0 to AItems.Count - 1 do
  begin
    Entry   := AItems[I];
    ItemNum := AMap[Entry];
    D := TPDFDictionary.Create;

    // Title and parent link
    D.SetValue('Title',  MakeTitleString(Entry.Title));
    D.SetValue('Parent', TPDFReference.CreateNum(AParentNum, 0));

    // Sibling links — both neighbours are already known from the map
    if I > 0 then
      D.SetValue('Prev', TPDFReference.CreateNum(AMap[AItems[I - 1]], 0));
    if I < AItems.Count - 1 then
      D.SetValue('Next', TPDFReference.CreateNum(AMap[AItems[I + 1]], 0));

    // Destination
    DestArr := MakeDestArray(Entry, APageObjNums);
    if DestArr <> nil then
      D.SetValue('Dest', DestArr);

    // Style flags (/F: bit 0 = italic, bit 1 = bold)
    StyleF := 0;
    if Entry.Italic then StyleF := StyleF or 1;
    if Entry.Bold   then StyleF := StyleF or 2;
    if StyleF <> 0 then
      D.SetValue('F', TPDFInteger.Create(StyleF));

    // Children
    if Entry.ChildCount > 0 then
    begin
      var FirstChildNum := AMap[Entry.FChildren[0]];
      var LastChildNum  := AMap[Entry.FChildren[Entry.ChildCount - 1]];
      var ChildCount    := Entry.ChildCount;

      D.SetValue('First', TPDFReference.CreateNum(FirstChildNum, 0));
      D.SetValue('Last',  TPDFReference.CreateNum(LastChildNum, 0));
      // PDF spec: positive /Count = item is open; negative = closed.
      // We use direct child count (not deep count) for simplicity.
      if Entry.IsOpen then
        D.SetValue('Count', TPDFInteger.Create(ChildCount))
      else
        D.SetValue('Count', TPDFInteger.Create(-ChildCount));

      BuildDicts(Entry.FChildren, ItemNum, AMap, APageObjNums, ADest);
    end;

    ADest.AddOrSetValue(ItemNum, D);
  end;
end;

// ---------------------------------------------------------------------------
// SerializeTo
// ---------------------------------------------------------------------------

function TPDFTOCBuilder.SerializeTo(ADest: TDictionary<Integer, TPDFObject>;
  var ANextNum: Integer;
  const APageObjNums: TArray<Integer>): Integer;
var
  RootNum:  Integer;
  RootDict: TPDFDictionary;
  Map:      TDictionary<TPDFTOCEntry, Integer>;
begin
  if FItems.Count = 0 then Exit(-1);

  // Allocate outline root obj#.
  RootNum  := ANextNum;
  Inc(ANextNum);

  // Pass 1: assign numbers to every entry.
  Map := TDictionary<TPDFTOCEntry, Integer>.Create;
  try
    AssignNumbers(FItems, ANextNum, Map);

    // Pass 2: build the entry dicts.
    BuildDicts(FItems, RootNum, Map, APageObjNums, ADest);

    // Build the outline root dict.
    RootDict := TPDFDictionary.Create;
    RootDict.SetValue('Type',  TPDFName.Create('Outlines'));
    RootDict.SetValue('First', TPDFReference.CreateNum(Map[FItems[0]], 0));
    RootDict.SetValue('Last',  TPDFReference.CreateNum(Map[FItems[FItems.Count - 1]], 0));
    RootDict.SetValue('Count', TPDFInteger.Create(CountAll(FItems)));
    ADest.AddOrSetValue(RootNum, RootDict);

    Result := RootNum;
  finally
    Map.Free;
  end;
end;

end.
