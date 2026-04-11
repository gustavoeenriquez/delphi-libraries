unit uPDF.AcroForms;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Generics.Collections,
  uPDF.Types, uPDF.Errors, uPDF.Objects;

type
  // -------------------------------------------------------------------------
  // Field types (§12.7.3.1)
  // -------------------------------------------------------------------------
  TPDFFieldType = (
    Unknown,
    Button,     // Btn — pushbutton, checkbox, radio
    Text,       // Tx  — single/multi-line text
    Choice,     // Ch  — list box, combo box
    Signature   // Sig — digital signature
  );

  // -------------------------------------------------------------------------
  // Button sub-types (determined by flags)
  // -------------------------------------------------------------------------
  TPDFButtonKind = (
    PushButton,
    CheckBox,
    RadioButton
  );

  // -------------------------------------------------------------------------
  // Choice sub-types
  // -------------------------------------------------------------------------
  TPDFChoiceKind = (
    ListBox,
    ComboBox
  );

  // -------------------------------------------------------------------------
  // Field flags (§12.7.3.1 Table 221  +  subtype tables)
  // -------------------------------------------------------------------------
  // We store the raw integer and expose typed helpers per field type.

  // -------------------------------------------------------------------------
  // One option in a Choice field  (/Opt array entry)
  // -------------------------------------------------------------------------
  TPDFChoiceOption = record
    ExportValue:  string;   // the value actually stored
    DisplayText:  string;   // shown to user (may equal ExportValue)
  end;

  // -------------------------------------------------------------------------
  // Single form field
  // -------------------------------------------------------------------------
  TPDFFormField = class
  private
    function GetIsReadOnly:  Boolean;
    function GetIsRequired:  Boolean;
    function GetIsNoExport:  Boolean;
    // Button helpers
    function GetIsPushButton:   Boolean;
    function GetIsCheckBox:     Boolean;
    function GetIsRadioButton:  Boolean;
    // Choice helpers
    function GetIsComboBox:     Boolean;
    function GetIsMultiSelect:  Boolean;
    // Text helpers
    function GetIsMultiLine:    Boolean;
    function GetIsPassword:     Boolean;
    function GetIsFileSelect:   Boolean;
    function GetIsRichText:     Boolean;
  public
    FieldType:    TPDFFieldType;
    FullName:     string;           // dotted path: Parent.Child.Grandchild
    PartialName:  string;           // /T — local name
    AltName:      string;           // /TU — user-facing label
    MappingName:  string;           // /TM — export name
    FlagsRaw:     Integer;          // /Ff

    // Current value
    ValueString:  string;           // /V as string (Text, Choice)
    ValueBool:    Boolean;          // /V as Boolean (CheckBox)
    DefaultValue: string;           // /DV

    // Choice options
    Options:      TArray<TPDFChoiceOption>;
    SelectedIndices: TArray<Integer>;  // /I (multi-select indices)

    // Text constraints
    MaxLen:       Integer;          // /MaxLen (0 = unlimited)

    // Structure
    Parent:       TPDFFormField;    // non-owning
    Children:     TObjectList<TPDFFormField>;  // owned

    // Appearance
    PageIndex:    Integer;          // page where widget lives (-1 if unknown)
    Rect:         TPDFRect;         // widget rect on page

    // Raw dict
    Dict:         TPDFDictionary;   // non-owning

    constructor Create;
    destructor  Destroy; override;

    // Common flags
    property IsReadOnly:    Boolean read GetIsReadOnly;
    property IsRequired:    Boolean read GetIsRequired;
    property IsNoExport:    Boolean read GetIsNoExport;
    // Button
    property IsPushButton:  Boolean read GetIsPushButton;
    property IsCheckBox:    Boolean read GetIsCheckBox;
    property IsRadioButton: Boolean read GetIsRadioButton;
    // Choice
    property IsComboBox:    Boolean read GetIsComboBox;
    property IsMultiSelect: Boolean read GetIsMultiSelect;
    // Text
    property IsMultiLine:   Boolean read GetIsMultiLine;
    property IsPassword:    Boolean read GetIsPassword;
    property IsFileSelect:  Boolean read GetIsFileSelect;
    property IsRichText:    Boolean read GetIsRichText;
  end;

  TPDFFormFieldList = TObjectList<TPDFFormField>;

  // -------------------------------------------------------------------------
  // AcroForm — the document-level form
  // -------------------------------------------------------------------------
  TPDFAcroForm = class
  private
    FFields: TPDFFormFieldList;  // all leaf + container fields (flat list)
    FRoots:  TPDFFormFieldList;  // top-level fields only (non-owning refs)

    class function FieldTypeFromName(const AName: string): TPDFFieldType; static;
    class procedure ParseOptions(AArr: TPDFArray;
                                 out AOpts: TArray<TPDFChoiceOption>); static;
    class procedure ParseSelectedIndices(AArr: TPDFArray;
                                         out AIdx: TArray<Integer>); static;

    procedure LoadField(ADict: TPDFDictionary;
                        AResolver: IObjectResolver;
                        AParent: TPDFFormField;
                        const AParentName: string;
                        APageTable: TDictionary<Integer, Integer>);
  public
    constructor Create;
    destructor  Destroy; override;

    // Load from /AcroForm entry in the catalog
    procedure LoadFromCatalog(ACatalog: TPDFDictionary;
                              AResolver: IObjectResolver;
                              APageTable: TDictionary<Integer, Integer> = nil);

    // Lookup by full dotted name (case-sensitive)
    function FindField(const AFullName: string): TPDFFormField;

    // All fields flat (includes container nodes)
    property Fields: TPDFFormFieldList read FFields;
    // Top-level fields only
    property Roots:  TPDFFormFieldList read FRoots;

    // Convenience: all leaf fields (no children)
    function LeafFields: TArray<TPDFFormField>;
  end;

implementation

// =========================================================================
// TPDFFormField
// =========================================================================

constructor TPDFFormField.Create;
begin
  inherited;
  Children  := TObjectList<TPDFFormField>.Create(True);
  PageIndex := -1;
  MaxLen    := 0;
end;

destructor TPDFFormField.Destroy;
begin
  Children.Free;
  inherited;
end;

// ---- Common flags (§12.7.3.1 Table 221) ----
//  Bit 1  (0x0001) = ReadOnly
//  Bit 2  (0x0002) = Required
//  Bit 3  (0x0004) = NoExport

function TPDFFormField.GetIsReadOnly:  Boolean; begin Result := (FlagsRaw and $0001) <> 0; end;
function TPDFFormField.GetIsRequired:  Boolean; begin Result := (FlagsRaw and $0002) <> 0; end;
function TPDFFormField.GetIsNoExport:  Boolean; begin Result := (FlagsRaw and $0004) <> 0; end;

// ---- Button flags (Table 226) ----
//  Bit 17 (0x010000) = NoToggleToOff (radio)
//  Bit 16 (0x008000) = Radio
//  Bit 15 (0x004000) = PushButton

function TPDFFormField.GetIsPushButton:  Boolean; begin Result := (FieldType = TPDFFieldType.Button) and ((FlagsRaw and $10000) <> 0); end;
function TPDFFormField.GetIsRadioButton: Boolean; begin Result := (FieldType = TPDFFieldType.Button) and ((FlagsRaw and $08000) <> 0) and not GetIsPushButton; end;
function TPDFFormField.GetIsCheckBox:    Boolean; begin Result := (FieldType = TPDFFieldType.Button) and not GetIsPushButton and not GetIsRadioButton; end;

// ---- Choice flags (Table 228) ----
//  Bit 18 (0x020000) = Combo
//  Bit 22 (0x200000) = MultiSelect

function TPDFFormField.GetIsComboBox:   Boolean; begin Result := (FieldType = TPDFFieldType.Choice) and ((FlagsRaw and $020000) <> 0); end;
function TPDFFormField.GetIsMultiSelect:Boolean; begin Result := (FieldType = TPDFFieldType.Choice) and ((FlagsRaw and $200000) <> 0); end;

// ---- Text flags (Table 227) ----
//  Bit 13 (0x001000) = Multiline
//  Bit 14 (0x002000) = Password
//  Bit 21 (0x100000) = FileSelect
//  Bit 26 (0x2000000) = RichText

function TPDFFormField.GetIsMultiLine:  Boolean; begin Result := (FieldType = TPDFFieldType.Text) and ((FlagsRaw and $001000) <> 0); end;
function TPDFFormField.GetIsPassword:   Boolean; begin Result := (FieldType = TPDFFieldType.Text) and ((FlagsRaw and $002000) <> 0); end;
function TPDFFormField.GetIsFileSelect: Boolean; begin Result := (FieldType = TPDFFieldType.Text) and ((FlagsRaw and $100000) <> 0); end;
function TPDFFormField.GetIsRichText:   Boolean; begin Result := (FieldType = TPDFFieldType.Text) and ((FlagsRaw and $2000000) <> 0); end;

// =========================================================================
// TPDFAcroForm helpers
// =========================================================================

class function TPDFAcroForm.FieldTypeFromName(const AName: string): TPDFFieldType;
begin
  if      AName = 'Btn' then Result := TPDFFieldType.Button
  else if AName = 'Tx'  then Result := TPDFFieldType.Text
  else if AName = 'Ch'  then Result := TPDFFieldType.Choice
  else if AName = 'Sig' then Result := TPDFFieldType.Signature
  else                       Result := TPDFFieldType.Unknown;
end;

class procedure TPDFAcroForm.ParseOptions(AArr: TPDFArray;
  out AOpts: TArray<TPDFChoiceOption>);
var
  I: Integer;
  Entry: TPDFObject;
  SubArr: TPDFArray;
  Opt: TPDFChoiceOption;
begin
  AOpts := nil;
  if AArr = nil then Exit;
  SetLength(AOpts, AArr.Count);
  for I := 0 to AArr.Count - 1 do
  begin
    Entry := AArr.Get(I);
    if Entry = nil then Continue;
    Entry := Entry.Dereference;
    if Entry.IsArray then
    begin
      SubArr := TPDFArray(Entry);
      if SubArr.Count >= 1 then
      begin
        var E0 := SubArr.Get(0);
        if E0 <> nil then begin E0 := E0.Dereference; Opt.ExportValue := E0.AsUnicodeString; end;
      end;
      if SubArr.Count >= 2 then
      begin
        var E1 := SubArr.Get(1);
        if E1 <> nil then begin E1 := E1.Dereference; Opt.DisplayText := E1.AsUnicodeString; end
        else Opt.DisplayText := Opt.ExportValue;
      end
      else
        Opt.DisplayText := Opt.ExportValue;
    end
    else if Entry.IsString then
    begin
      Opt.ExportValue := Entry.AsUnicodeString;
      Opt.DisplayText := Opt.ExportValue;
    end
    else
    begin
      Opt.ExportValue := '';
      Opt.DisplayText := '';
    end;
    AOpts[I] := Opt;
  end;
end;

class procedure TPDFAcroForm.ParseSelectedIndices(AArr: TPDFArray;
  out AIdx: TArray<Integer>);
var
  I: Integer;
begin
  AIdx := nil;
  if AArr = nil then Exit;
  SetLength(AIdx, AArr.Count);
  for I := 0 to AArr.Count - 1 do
    AIdx[I] := Round(AArr.GetAsNumber(I, -1));
end;

// =========================================================================
// TPDFAcroForm — field loading (recursive)
// =========================================================================

procedure TPDFAcroForm.LoadField(ADict: TPDFDictionary;
  AResolver: IObjectResolver; AParent: TPDFFormField;
  const AParentName: string; APageTable: TDictionary<Integer, Integer>);
var
  Field:       TPDFFormField;
  PartName:    string;
  FullName:    string;
  FTName:      string;
  ValObj:      TPDFObject;
  KidsArr:     TPDFArray;
  WidgetObj:   TPDFObject;
  WidgetDict:  TPDFDictionary;
  I:           Integer;
  ObjNum:      Integer;
  RectArr:     TPDFArray;
  PageRef:     TPDFObject;
begin
  if ADict = nil then Exit;

  // Inherit /FT from parent if not present here
  FTName := ADict.GetAsName('FT');
  if (FTName = '') and (AParent <> nil) and (AParent.FieldType <> TPDFFieldType.Unknown) then
    FTName := ''; // will remain Unknown; parent type used for display

  PartName := ADict.GetAsUnicodeString('T');

  if AParentName <> '' then
    FullName := AParentName + '.' + PartName
  else
    FullName := PartName;

  Field              := TPDFFormField.Create;
  Field.Parent       := AParent;
  Field.PartialName  := PartName;
  Field.FullName     := FullName;
  Field.AltName      := ADict.GetAsUnicodeString('TU');
  Field.MappingName  := ADict.GetAsUnicodeString('TM');
  Field.FlagsRaw     := ADict.GetAsInteger('Ff', 0);
  Field.Dict         := ADict;

  // Field type — may be inherited through the tree
  if FTName <> '' then
    Field.FieldType := FieldTypeFromName(FTName)
  else if AParent <> nil then
    Field.FieldType := AParent.FieldType
  else
    Field.FieldType := TPDFFieldType.Unknown;

  // /V value
  ValObj := ADict.Get('V');
  if ValObj <> nil then
  begin
    ValObj := ValObj.Dereference;
    if ValObj.IsName then
    begin
      Field.ValueString := ValObj.AsName;
      Field.ValueBool   := (ValObj.AsName <> 'Off') and (ValObj.AsName <> '');
    end
    else if ValObj.IsString then
      Field.ValueString := ValObj.AsUnicodeString
    else if ValObj.IsBoolean then
      Field.ValueBool := ValObj.AsBoolean;
  end;

  // /DV default value
  ValObj := ADict.Get('DV');
  if ValObj <> nil then
  begin
    ValObj := ValObj.Dereference;
    if ValObj.IsString then
      Field.DefaultValue := ValObj.AsUnicodeString
    else if ValObj.IsName then
      Field.DefaultValue := ValObj.AsName;
  end;

  // Text /MaxLen
  Field.MaxLen := ADict.GetAsInteger('MaxLen', 0);

  // Choice /Opt and /I
  if Field.FieldType = TPDFFieldType.Choice then
  begin
    ParseOptions(ADict.GetAsArray('Opt'), Field.Options);
    ParseSelectedIndices(ADict.GetAsArray('I'), Field.SelectedIndices);
  end;

  // Widget annotation: get page + rect
  // A field dict may itself be a widget (merged), or have a separate /Kids
  // that are widget annotations.  Check if this dict has /Rect (it's a widget).
  RectArr := ADict.GetAsArray('Rect');
  if RectArr <> nil then
  begin
    Field.Rect := ADict.GetRect('Rect').Normalize;
    // Page: /P is a reference to the page dict
    PageRef := ADict.Get('P');
    if (PageRef <> nil) and (APageTable <> nil) then
    begin
      ObjNum := 0;
      if PageRef.IsReference then
        ObjNum := TPDFReference(PageRef).RefID.Number;
      if APageTable.ContainsKey(ObjNum) then
        Field.PageIndex := APageTable[ObjNum];
    end;
  end;

  // Register in master list
  FFields.Add(Field);

  // Parent linkage
  if AParent <> nil then
    AParent.Children.Add(Field)
  else
    FRoots.Add(Field);   // FRoots is non-owning, FFields owns

  // Recurse into /Kids
  KidsArr := ADict.GetAsArray('Kids');
  if KidsArr = nil then Exit;

  for I := 0 to KidsArr.Count - 1 do
  begin
    WidgetObj := KidsArr.Get(I);
    if WidgetObj = nil then Continue;
    WidgetObj := WidgetObj.Dereference;
    if not WidgetObj.IsDictionary then Continue;
    WidgetDict := TPDFDictionary(WidgetObj);

    // If the kid has /T it is a field node; otherwise it's a pure widget annotation.
    // Pure widgets (only /Subtype=Widget, no /T) are merged into the parent field.
    if WidgetDict.GetAsUnicodeString('T') <> '' then
      LoadField(WidgetDict, AResolver, Field, FullName, APageTable)
    else
    begin
      // Pure widget annotation — pull rect/page into parent field
      RectArr := WidgetDict.GetAsArray('Rect');
      if (RectArr <> nil) and (Field.Rect.IsEmpty) then
      begin
        Field.Rect := WidgetDict.GetRect('Rect').Normalize;
        PageRef    := WidgetDict.Get('P');
        if (PageRef <> nil) and (APageTable <> nil) then
        begin
          ObjNum := 0;
          if PageRef.IsReference then
            ObjNum := TPDFReference(PageRef).RefID.Number;
          if APageTable.ContainsKey(ObjNum) then
            Field.PageIndex := APageTable[ObjNum];
        end;
      end;
    end;
  end;
end;

// =========================================================================
// TPDFAcroForm
// =========================================================================

constructor TPDFAcroForm.Create;
begin
  inherited;
  FFields := TPDFFormFieldList.Create(True);   // owns
  FRoots  := TPDFFormFieldList.Create(False);  // non-owning
end;

destructor TPDFAcroForm.Destroy;
begin
  FRoots.Free;
  FFields.Free;
  inherited;
end;

procedure TPDFAcroForm.LoadFromCatalog(ACatalog: TPDFDictionary;
  AResolver: IObjectResolver; APageTable: TDictionary<Integer, Integer>);
var
  AcroObj:   TPDFObject;
  AcroDict:  TPDFDictionary;
  FieldsArr: TPDFArray;
  I:         Integer;
  FldObj:    TPDFObject;
  FldDict:   TPDFDictionary;
  OwnTable:  TDictionary<Integer, Integer>;
begin
  if ACatalog = nil then Exit;

  AcroObj := ACatalog.Get('AcroForm');
  if AcroObj = nil then Exit;
  AcroObj := AcroObj.Dereference;
  if not AcroObj.IsDictionary then Exit;
  AcroDict := TPDFDictionary(AcroObj);

  FieldsArr := AcroDict.GetAsArray('Fields');
  if FieldsArr = nil then Exit;

  // Use an empty page table if none provided
  OwnTable := nil;
  if APageTable = nil then
  begin
    OwnTable   := TDictionary<Integer, Integer>.Create;
    APageTable := OwnTable;
  end;

  try
    for I := 0 to FieldsArr.Count - 1 do
    begin
      FldObj := FieldsArr.Get(I);
      if FldObj = nil then Continue;
      FldObj := FldObj.Dereference;
      if not FldObj.IsDictionary then Continue;
      FldDict := TPDFDictionary(FldObj);
      LoadField(FldDict, AResolver, nil, '', APageTable);
    end;
  finally
    OwnTable.Free;
  end;
end;

function TPDFAcroForm.FindField(const AFullName: string): TPDFFormField;
var
  F: TPDFFormField;
begin
  for F in FFields do
    if F.FullName = AFullName then Exit(F);
  Result := nil;
end;

function TPDFAcroForm.LeafFields: TArray<TPDFFormField>;
var
  F: TPDFFormField;
  Acc: TList<TPDFFormField>;
begin
  Acc := TList<TPDFFormField>.Create;
  try
    for F in FFields do
      if F.Children.Count = 0 then
        Acc.Add(F);
    Result := Acc.ToArray;
  finally
    Acc.Free;
  end;
end;

end.
