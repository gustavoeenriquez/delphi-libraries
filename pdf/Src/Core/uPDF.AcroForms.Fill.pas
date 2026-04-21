unit uPDF.AcroForms.Fill;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.StrUtils, System.Classes, System.Math,
  System.Generics.Collections,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Document,
  uPDF.AcroForms, uPDF.Writer, uPDF.PageCopy;

type
  // ---------------------------------------------------------------------------
  // TPDFFormFiller
  //
  // Fills AcroForm fields in an existing PDF and writes the result as a new
  // file (full rewrite).
  //
  // The source document is never modified.  All pages and their resources are
  // copied via TPDFObjectCopier; field /V values are injected into the copies.
  // Appearance streams (/AP /N) are generated for Text, CheckBox and Radio
  // fields so the result renders correctly without viewer synthesis.
  //
  // Usage:
  //   var F := TPDFFormFiller.Create(Doc);
  //   try
  //     F.LoadForm;
  //     F.SetTextField('FullName', 'John Doe');
  //     F.SetCheckBox('AgreeTerms', True);
  //     F.SetRadioButton('Gender', 'Male');
  //     F.SetChoice('Country', 'Mexico');
  //     F.Save('filled.pdf');
  //   finally
  //     F.Free;
  //   end;
  // ---------------------------------------------------------------------------
  TPDFFormFiller = class
  private
    FDocument: TPDFDocument;
    FForm:     TPDFAcroForm;

    // Pending changes: field FullName → new value string
    FTextValues:   TDictionary<string, string>;
    FCheckValues:  TDictionary<string, Boolean>;
    FRadioValues:  TDictionary<string, string>;   // group name → selected export value
    FChoiceValues: TDictionary<string, string>;

    // --- Appearance stream helpers ---

    // Parse /DA string (e.g. "/Helv 12 Tf 0 g") → font name, size, gray level
    class procedure ParseDA(const ADA: string;
      out AFontName: string; out AFontSize: Single; out AGray: Single); static;

    // Build /AP /N stream bytes for a text field
    class function  BuildTextAP(const AValue: string;
      const ARect: TPDFRect; const ADA: string): TBytes; static;

    // Build /AP /N stream bytes for a checkbox (checked = on value, unchecked = off)
    class function  BuildCheckBoxAP(AChecked: Boolean;
      const ARect: TPDFRect; const AOnValue: string): TBytes; static;

    // Build /AP /N stream bytes for a radio button
    class function  BuildRadioAP(ASelected: Boolean;
      const ARect: TPDFRect): TBytes; static;

    // Apply field changes into a copied object map.
    // ACopier must have already processed all pages of FDocument.
    procedure ApplyChanges(ACopier: TPDFObjectCopier;
      ADest: TObjectDictionary<Integer, TPDFObject>;
      var ANextNum: Integer);

    // Copy /AcroForm from catalog into ADest and return its dest obj number.
    function  CopyAcroForm(ACopier: TPDFObjectCopier;
      ADest: TObjectDictionary<Integer, TPDFObject>;
      var ANextNum: Integer): Integer;

  public
    constructor Create(ADocument: TPDFDocument);
    destructor  Destroy; override;

    // Load form fields from the document (required before Set* calls).
    procedure LoadForm;

    // Set field values.  AFieldName is the full dotted name (e.g. 'Address.City').
    procedure SetTextField(const AFieldName, AValue: string);
    procedure SetCheckBox(const AFieldName: string; AChecked: Boolean);
    // AValue = export value of the selected radio button in the group.
    procedure SetRadioButton(const AGroupName, AValue: string);
    // AValue = export value of the selected option.
    procedure SetChoice(const AFieldName, AValue: string);

    // Write the filled PDF to AOutput.
    procedure Save(AOutput: TStream); overload;
    procedure Save(const APath: string); overload;
  end;

implementation

// ---------------------------------------------------------------------------
// ParseDA  —  parse a Default Appearance string such as "/Helv 12 Tf 0 g"
// ---------------------------------------------------------------------------
class procedure TPDFFormFiller.ParseDA(const ADA: string;
  out AFontName: string; out AFontSize: Single; out AGray: Single);
var
  Tokens: TArray<string>;
  I:      Integer;
begin
  AFontName := 'Helv';
  AFontSize := 10;
  AGray     := 0;

  if ADA = '' then Exit;

  Tokens := ADA.Split([' ', #9, #10, #13], TStringSplitOptions.ExcludeEmpty);
  I := 0;
  while I < Length(Tokens) do
  begin
    if Tokens[I] = 'Tf' then
    begin
      // /FontName size Tf  — font name is two tokens back, size is one token back
      if I >= 2 then
      begin
        var FontTok := Tokens[I - 2];
        if FontTok.StartsWith('/') then
          AFontName := Copy(FontTok, 2, MaxInt);
        AFontSize := StrToFloatDef(Tokens[I - 1], 10);
      end;
    end
    else if Tokens[I] = 'g' then
    begin
      if I >= 1 then
        AGray := StrToFloatDef(Tokens[I - 1], 0);
    end;
    Inc(I);
  end;
end;

// ---------------------------------------------------------------------------
// BuildTextAP  —  appearance stream for a text widget
// ---------------------------------------------------------------------------
class function TPDFFormFiller.BuildTextAP(const AValue: string;
  const ARect: TPDFRect; const ADA: string): TBytes;
var
  FontName: string;
  FontSize: Single;
  Gray:     Single;
  W, H:     Single;
  TX, TY:   Single;
  DA:       string;
  Content:  TStringBuilder;
  Encoded:  string;
  B:        TBytes;
  I:        Integer;
  C:        Char;
begin
  ParseDA(ADA, FontName, FontSize, Gray);
  W := ARect.Width;
  H := ARect.Height;

  // Auto-size: if /DA specifies 0 as font size, pick a reasonable default
  if FontSize < 1 then
    FontSize := Min(H * 0.75, 12);

  // Vertical centering: baseline ≈ (H - FontSize) / 2 + small descender offset
  TY := (H - FontSize) / 2 + FontSize * 0.15;
  TX := 2;   // standard 2pt left padding

  // Encode value as PDF literal string (basic ASCII escape; UTF-16BE for non-ASCII)
  Encoded := '';
  for I := 1 to Length(AValue) do
  begin
    C := AValue[I];
    if Ord(C) < 128 then
    begin
      if C in ['(', ')', '\'] then
        Encoded := Encoded + '\' + C
      else
        Encoded := Encoded + C;
    end
    else
      Encoded := Encoded + '?';  // non-ASCII: replace (proper UTF-16BE encoding omitted for brevity)
  end;

  Content := TStringBuilder.Create;
  try
    Content.AppendLine('/Tx BMC');
    Content.AppendLine('q');
    Content.AppendFormat('0 0 %.4f %.4f re W n', [W, H]);
    Content.AppendLine;
    Content.AppendLine('BT');
    Content.AppendFormat('/%s %.4f Tf', [FontName, FontSize]);
    Content.AppendLine;
    Content.AppendFormat('%.4f g', [Gray]);
    Content.AppendLine;
    Content.AppendFormat('%.4f %.4f Td', [TX, TY]);
    Content.AppendLine;
    Content.AppendFormat('(%s) Tj', [Encoded]);
    Content.AppendLine;
    Content.AppendLine('ET');
    Content.AppendLine('Q');
    Content.Append('EMC');

    Result := TEncoding.UTF8.GetBytes(Content.ToString);
  finally
    Content.Free;
  end;
end;

// ---------------------------------------------------------------------------
// BuildCheckBoxAP  —  appearance stream for a checkbox widget
// ---------------------------------------------------------------------------
class function TPDFFormFiller.BuildCheckBoxAP(AChecked: Boolean;
  const ARect: TPDFRect; const AOnValue: string): TBytes;
var
  W, H:    Single;
  Content: TStringBuilder;
  Pad:     Single;
begin
  W   := ARect.Width;
  H   := ARect.Height;
  Pad := Min(W, H) * 0.2;

  Content := TStringBuilder.Create;
  try
    Content.AppendLine('q');
    if AChecked then
    begin
      // Draw a checkmark using line segments
      Content.AppendFormat('%.4f %.4f m', [Pad, H * 0.4]);      Content.AppendLine;
      Content.AppendFormat('%.4f %.4f l', [W * 0.4, Pad]);       Content.AppendLine;
      Content.AppendFormat('%.4f %.4f l', [W - Pad, H - Pad]);   Content.AppendLine;
      Content.AppendLine('0 g');
      Content.AppendFormat('%.4f w', [Min(W, H) * 0.1]);         Content.AppendLine;
      Content.AppendLine('S');
    end;
    Content.Append('Q');

    Result := TEncoding.UTF8.GetBytes(Content.ToString);
  finally
    Content.Free;
  end;
end;

// ---------------------------------------------------------------------------
// BuildRadioAP  —  appearance stream for a radio button widget
// ---------------------------------------------------------------------------
class function TPDFFormFiller.BuildRadioAP(ASelected: Boolean;
  const ARect: TPDFRect): TBytes;
var
  W, H, CX, CY, R: Single;
  Content: TStringBuilder;
  K: Single;
begin
  W  := ARect.Width;
  H  := ARect.Height;
  CX := W / 2;
  CY := H / 2;
  R  := Min(W, H) * 0.3;
  K  := 0.5523;  // Bezier approximation constant for circles

  Content := TStringBuilder.Create;
  try
    Content.AppendLine('q');
    if ASelected then
    begin
      // Filled circle using 4 cubic Bezier curves
      Content.AppendFormat('%.4f %.4f m', [CX, CY + R]);  Content.AppendLine;
      Content.AppendFormat('%.4f %.4f %.4f %.4f %.4f %.4f c',
        [CX + R*K, CY + R,  CX + R, CY + R*K,  CX + R, CY]);  Content.AppendLine;
      Content.AppendFormat('%.4f %.4f %.4f %.4f %.4f %.4f c',
        [CX + R, CY - R*K,  CX + R*K, CY - R,  CX, CY - R]);  Content.AppendLine;
      Content.AppendFormat('%.4f %.4f %.4f %.4f %.4f %.4f c',
        [CX - R*K, CY - R,  CX - R, CY - R*K,  CX - R, CY]);  Content.AppendLine;
      Content.AppendFormat('%.4f %.4f %.4f %.4f %.4f %.4f c',
        [CX - R, CY + R*K,  CX - R*K, CY + R,  CX, CY + R]);  Content.AppendLine;
      Content.AppendLine('0 g f');
    end;
    Content.Append('Q');

    Result := TEncoding.UTF8.GetBytes(Content.ToString);
  finally
    Content.Free;
  end;
end;

// ---------------------------------------------------------------------------
// TPDFFormFiller
// ---------------------------------------------------------------------------

constructor TPDFFormFiller.Create(ADocument: TPDFDocument);
begin
  inherited Create;
  FDocument    := ADocument;
  FTextValues  := TDictionary<string, string>.Create;
  FCheckValues := TDictionary<string, Boolean>.Create;
  FRadioValues := TDictionary<string, string>.Create;
  FChoiceValues:= TDictionary<string, string>.Create;
end;

destructor TPDFFormFiller.Destroy;
begin
  FForm.Free;
  FChoiceValues.Free;
  FRadioValues.Free;
  FCheckValues.Free;
  FTextValues.Free;
  inherited;
end;

procedure TPDFFormFiller.LoadForm;
begin
  FreeAndNil(FForm);
  FForm := TPDFAcroForm.Create;
  FForm.LoadFromCatalog(FDocument.Catalog, FDocument.Resolver);
end;

procedure TPDFFormFiller.SetTextField(const AFieldName, AValue: string);
begin
  FTextValues.AddOrSetValue(AFieldName, AValue);
end;

procedure TPDFFormFiller.SetCheckBox(const AFieldName: string; AChecked: Boolean);
begin
  FCheckValues.AddOrSetValue(AFieldName, AChecked);
end;

procedure TPDFFormFiller.SetRadioButton(const AGroupName, AValue: string);
begin
  FRadioValues.AddOrSetValue(AGroupName, AValue);
end;

procedure TPDFFormFiller.SetChoice(const AFieldName, AValue: string);
begin
  FChoiceValues.AddOrSetValue(AFieldName, AValue);
end;

// ---------------------------------------------------------------------------
// CopyAcroForm
// ---------------------------------------------------------------------------

function TPDFFormFiller.CopyAcroForm(ACopier: TPDFObjectCopier;
  ADest: TObjectDictionary<Integer, TPDFObject>;
  var ANextNum: Integer): Integer;
var
  AcroObj:  TPDFObject;
  AcroDict: TPDFDictionary;
  SrcNum:   Integer;
  DestNum:  Integer;
  Ref:      TPDFReference;
begin
  Result := 0;
  if FDocument.Catalog = nil then Exit;

  AcroObj := FDocument.Catalog.RawGet('AcroForm');
  if AcroObj = nil then Exit;

  if AcroObj.IsReference then
  begin
    SrcNum := TPDFReference(AcroObj).RefID.Number;
    Ref    := ACopier.CopyObject(SrcNum);
    Result := Ref.RefID.Number;
    Ref.Free;
  end
  else if AcroObj.IsDictionary then
  begin
    // Inline AcroForm dict (rare) — copy it as a page-like dict (no /Parent stripping needed).
    AcroDict := ACopier.CopyPage(TPDFDictionary(AcroObj));
    DestNum  := ANextNum; Inc(ANextNum);
    ADest.AddOrSetValue(DestNum, AcroDict);
    Result   := DestNum;
  end;
end;

// ---------------------------------------------------------------------------
// ApplyChanges — inject field values and AP streams into copied objects
// ---------------------------------------------------------------------------

procedure TPDFFormFiller.ApplyChanges(ACopier: TPDFObjectCopier;
  ADest: TObjectDictionary<Integer, TPDFObject>;
  var ANextNum: Integer);
var
  Field:    TPDFFormField;
  SrcNum:   Integer;
  DestNum:  Integer;
  DestObj:  TPDFObject;
  DestDict: TPDFDictionary;
  Value:    string;
  Checked:  Boolean;
  APStm:    TPDFStream;
  APDict:   TPDFDictionary;
  APNRef:   TPDFReference;
  APStmNum: Integer;
  APBytes:  TBytes;
  DA:       string;
  OnVal:    string;
  BBoxArr:  TPDFArray;
begin
  if FForm = nil then Exit;

  for Field in FForm.Fields do
  begin
    SrcNum := Field.Dict.ID.Number;
    if SrcNum <= 0 then Continue;  // inline field dict — skip
    if not ACopier.GetDestNum(SrcNum, DestNum) then Continue;
    if not ADest.TryGetValue(DestNum, DestObj) then Continue;
    if not DestObj.IsDictionary then Continue;
    DestDict := TPDFDictionary(DestObj);

    APBytes := nil;
    DA      := Field.Dict.GetAsUnicodeString('DA');

    case Field.FieldType of

      TPDFFieldType.Text:
      begin
        if FTextValues.TryGetValue(Field.FullName, Value) then
        begin
          DestDict.SetValue('V', TPDFString.Create(
            RawByteString(TEncoding.UTF8.GetBytes(Value)), False));
          APBytes := BuildTextAP(Value, Field.Rect, DA);
        end;
      end;

      TPDFFieldType.Button:
      begin
        if Field.IsCheckBox then
        begin
          if FCheckValues.TryGetValue(Field.FullName, Checked) then
          begin
            // Determine /On value (may be custom; default is 'Yes')
            OnVal := 'Yes';
            var APEntry := Field.Dict.RawGet('AP');
            if (APEntry <> nil) and APEntry.IsDictionary then
            begin
              var NEntry := TPDFDictionary(APEntry.Dereference).RawGet('N');
              if (NEntry <> nil) and NEntry.IsDictionary then
              begin
                var Names := TPDFDictionary(NEntry.Dereference).Keys;
                for var K in Names do
                  if K <> 'Off' then begin OnVal := K; Break; end;
              end;
            end;
            if Checked then
              DestDict.SetValue('V', TPDFName.Create(OnVal))
            else
              DestDict.SetValue('V', TPDFName.Create('Off'));
            APBytes := BuildCheckBoxAP(Checked, Field.Rect, OnVal);
            DestDict.SetValue('AS', TPDFName.Create(
              IfThen(Checked, OnVal, 'Off')));
          end;
        end
        else if Field.IsRadioButton then
        begin
          if FRadioValues.TryGetValue(Field.FullName, Value) then
          begin
            DestDict.SetValue('V', TPDFName.Create(Value));
            DestDict.SetValue('AS', TPDFName.Create(Value));
            APBytes := BuildRadioAP(True, Field.Rect);
          end;
        end;
      end;

      TPDFFieldType.Choice:
      begin
        if FChoiceValues.TryGetValue(Field.FullName, Value) then
        begin
          DestDict.SetValue('V', TPDFString.Create(
            RawByteString(Value), False));
          APBytes := BuildTextAP(Value, Field.Rect, DA);
        end;
      end;

    end;

    // Attach the appearance stream to the field dict
    if APBytes <> nil then
    begin
      APStm := TPDFStream.Create;
      APStm.Dict.SetValue('Type',    TPDFName.Create('XObject'));
      APStm.Dict.SetValue('Subtype', TPDFName.Create('Form'));

      BBoxArr := TPDFArray.Create;
      BBoxArr.Add(TPDFReal.Create(0));
      BBoxArr.Add(TPDFReal.Create(0));
      BBoxArr.Add(TPDFReal.Create(Field.Rect.Width));
      BBoxArr.Add(TPDFReal.Create(Field.Rect.Height));
      APStm.Dict.SetValue('BBox', BBoxArr);
      APStm.SetRawData(APBytes);

      APStmNum := ANextNum; Inc(ANextNum);
      ADest.AddOrSetValue(APStmNum, APStm);

      // /AP << /N ref >>
      APNRef  := TPDFReference.CreateNum(APStmNum, 0);
      APDict  := TPDFDictionary.Create;
      APDict.SetValue('N', APNRef);
      DestDict.SetValue('AP', APDict);
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Save
// ---------------------------------------------------------------------------

procedure TPDFFormFiller.Save(AOutput: TStream);
var
  Objects:    TObjectDictionary<Integer, TPDFObject>;
  NextNum:    Integer;
  Copier:     TPDFObjectCopier;
  Pages:      TArray<TPDFDictionary>;
  I:          Integer;
  AcroFormNum: Integer;
  PagesNum:   Integer;
  CatNum:     Integer;
  KidsArr:    TPDFArray;
  PagesDict:  TPDFDictionary;
  CatDict:    TPDFDictionary;
  PageNums:   TArray<Integer>;
  Writer:     TPDFWriter;
begin
  if FForm = nil then
    raise EPDFError.Create('FormFiller.Save: call LoadForm first');

  Objects := TObjectDictionary<Integer, TPDFObject>.Create([doOwnsValues]);
  try
    NextNum := 1;
    Copier  := TPDFObjectCopier.Create(FDocument.Resolver, Objects, @NextNum);
    try
      // Copy all pages (this also copies field dicts via /Annots references)
      SetLength(Pages, FDocument.PageCount);
      for I := 0 to FDocument.PageCount - 1 do
        Pages[I] := Copier.CopyPage(FDocument.Pages[I].Dict);

      // Inject field values and appearance streams into the copied dicts
      ApplyChanges(Copier, Objects, NextNum);

      // Copy (and possibly patch) the AcroForm
      AcroFormNum := CopyAcroForm(Copier, Objects, NextNum);
    finally
      Copier.Free;
    end;

    // Build page tree
    SetLength(PageNums, Length(Pages));
    for I := 0 to High(Pages) do
    begin
      PageNums[I] := NextNum; Inc(NextNum);
    end;

    PagesNum  := NextNum; Inc(NextNum);
    PagesDict := TPDFDictionary.Create;
    PagesDict.SetValue('Type',  TPDFName.Create('Pages'));
    PagesDict.SetValue('Count', TPDFInteger.Create(Length(Pages)));
    KidsArr := TPDFArray.Create;
    for I := 0 to High(Pages) do
      KidsArr.Add(TPDFReference.CreateNum(PageNums[I], 0));
    PagesDict.SetValue('Kids', KidsArr);
    Objects.AddOrSetValue(PagesNum, PagesDict);

    for I := 0 to High(Pages) do
    begin
      Pages[I].SetValue('Parent', TPDFReference.CreateNum(PagesNum, 0));
      Objects.AddOrSetValue(PageNums[I], Pages[I]);
    end;

    // Build catalog
    CatNum  := NextNum; Inc(NextNum);
    CatDict := TPDFDictionary.Create;
    CatDict.SetValue('Type',  TPDFName.Create('Catalog'));
    CatDict.SetValue('Pages', TPDFReference.CreateNum(PagesNum, 0));
    if AcroFormNum > 0 then
    begin
      CatDict.SetValue('AcroForm', TPDFReference.CreateNum(AcroFormNum, 0));
      // Tell viewers to re-generate appearances if needed
      var AcroObj: TPDFObject;
      if Objects.TryGetValue(AcroFormNum, AcroObj) and AcroObj.IsDictionary then
        TPDFDictionary(AcroObj).SetValue('NeedAppearances', TPDFBoolean.Create(False));
    end;
    Objects.AddOrSetValue(CatNum, CatDict);

    Writer := TPDFWriter.Create(AOutput, TPDFWriteOptions.Default);
    try
      Writer.WriteFull(CatDict, nil, Objects);
    finally
      Writer.Free;
    end;
  finally
    Objects.Free;
  end;
end;

procedure TPDFFormFiller.Save(const APath: string);
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(APath, fmCreate);
  try
    Save(FS);
  finally
    FS.Free;
  end;
end;

end.
