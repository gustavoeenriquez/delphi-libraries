program TestAdvanced;
// Tests: uPDF.Metadata, uPDF.Outline, uPDF.Annotations,
//        uPDF.AcroForms, uPDF.ImageExtractor, uPDF.TextSearch,
//        uPDF.TOC, uPDF.Signatures, uPDF.Crypto (SHA-1)
// Uses existing real-world PDFs as test fixtures.

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}
{$R *.res}

uses
  System.SysUtils, System.Classes, System.StrUtils, System.Math,
  System.DateUtils, System.Generics.Collections, System.TypInfo,
  uPDF.Types         in '..\Src\Core\uPDF.Types.pas',
  uPDF.Errors        in '..\Src\Core\uPDF.Errors.pas',
  uPDF.Objects       in '..\Src\Core\uPDF.Objects.pas',
  uPDF.Lexer         in '..\Src\Core\uPDF.Lexer.pas',
  uPDF.Filters       in '..\Src\Core\uPDF.Filters.pas',
  uPDF.XRef          in '..\Src\Core\uPDF.XRef.pas',
  uPDF.Crypto        in '..\Src\Core\uPDF.Crypto.pas',
  uPDF.Encryption    in '..\Src\Core\uPDF.Encryption.pas',
  uPDF.Parser        in '..\Src\Core\uPDF.Parser.pas',
  uPDF.Document      in '..\Src\Core\uPDF.Document.pas',
  uPDF.GraphicsState in '..\Src\Core\uPDF.GraphicsState.pas',
  uPDF.ColorSpace    in '..\Src\Core\uPDF.ColorSpace.pas',
  uPDF.FontCMap      in '..\Src\Core\uPDF.FontCMap.pas',
  uPDF.Font          in '..\Src\Core\uPDF.Font.pas',
  uPDF.ContentStream in '..\Src\Core\uPDF.ContentStream.pas',
  uPDF.Image         in '..\Src\Core\uPDF.Image.pas',
  uPDF.TextExtractor in '..\Src\Core\uPDF.TextExtractor.pas',
  uPDF.ImageExtractor in '..\Src\Core\uPDF.ImageExtractor.pas',
  uPDF.Writer        in '..\Src\Core\uPDF.Writer.pas',
  uPDF.Outline       in '..\Src\Core\uPDF.Outline.pas',
  uPDF.Annotations   in '..\Src\Core\uPDF.Annotations.pas',
  uPDF.Metadata      in '..\Src\Core\uPDF.Metadata.pas',
  uPDF.AcroForms     in '..\Src\Core\uPDF.AcroForms.pas',
  uPDF.ScanDetector  in '..\Src\Core\uPDF.ScanDetector.pas',
  uPDF.PageOperations in '..\Src\Core\uPDF.PageOperations.pas',
  uPDF.PageCopy      in '..\Src\Core\uPDF.PageCopy.pas',
  uPDF.AcroForms.Fill in '..\Src\Core\uPDF.AcroForms.Fill.pas',
  uPDF.TextSearch    in '..\Src\Core\uPDF.TextSearch.pas',
  uPDF.Watermark     in '..\Src\Core\uPDF.Watermark.pas',
  uPDF.TOC           in '..\Src\Core\uPDF.TOC.pas',
  uPDF.Signatures         in '..\Src\Core\uPDF.Signatures.pas',
  uPDF.Writer             in '..\Src\Core\uPDF.Writer.pas',
  uPDF.IncrementalUpdate  in '..\Src\Core\uPDF.IncrementalUpdate.pas';

// =========================================================================
// Helpers
// =========================================================================

var
  PassCount: Integer = 0;
  FailCount: Integer = 0;

procedure Pass(const AMsg: string);
begin
  Inc(PassCount);
  WriteLn('  [PASS] ', AMsg);
end;

procedure Fail(const AMsg: string; const AReason: string = '');
begin
  Inc(FailCount);
  if AReason <> '' then WriteLn('  [FAIL] ', AMsg, ' — ', AReason)
  else              WriteLn('  [FAIL] ', AMsg);
end;

procedure Check(ACondition: Boolean; const AMsg: string;
  const ADetail: string = '');
begin
  if ACondition then Pass(AMsg) else Fail(AMsg, ADetail);
end;

procedure Section(const ATitle: string);
begin
  WriteLn;
  WriteLn('=== ', ATitle, ' ===');
end;

// =========================================================================
// T01 — TPDFInfoRecord.ParseDate — pure unit tests, no PDF needed
// =========================================================================

procedure TestDateParser;
var
  D: TDateTime;
  B: Boolean;
begin
  Section('T01 — TPDFInfoRecord.ParseDate');
  try
    // Full date with timezone offset
    B := TPDFInfoRecord.ParseDate('D:20250305143022+05''00''', D);
    Check(B, 'Full date D:20250305143022+05''00'' parsed');
    if B then
    begin
      Check(YearOf(D)   = 2025, Format('Year = 2025   (got %d)', [YearOf(D)]));
      Check(MonthOf(D)  = 3,    Format('Month = 3     (got %d)', [MonthOf(D)]));
      Check(DayOf(D)    = 5,    Format('Day = 5       (got %d)', [DayOf(D)]));
    end;

    // Date without timezone
    B := TPDFInfoRecord.ParseDate('D:20231231120000', D);
    Check(B, 'Date without timezone D:20231231120000 parsed');
    if B then
    begin
      Check(YearOf(D)   = 2023, Format('Year = 2023  (got %d)', [YearOf(D)]));
      Check(MonthOf(D)  = 12,   Format('Month = 12   (got %d)', [MonthOf(D)]));
      Check(DayOf(D)    = 31,   Format('Day = 31     (got %d)', [DayOf(D)]));
    end;

    // Minimal date: year only
    B := TPDFInfoRecord.ParseDate('D:2024', D);
    Check(B, 'Minimal date D:2024 parsed');
    if B then
      Check(YearOf(D) = 2024, Format('Year = 2024  (got %d)', [YearOf(D)]));

    // UTC 'Z' timezone (PDF 2.0 / some generators use Z)
    B := TPDFInfoRecord.ParseDate('D:20220601090000Z', D);
    // Z may or may not be supported — just check it doesn't raise an exception
    Pass(Format('D:...Z handled without exception (parsed=%s)', [BoolToStr(B, True)]));

    // Invalid strings should return False
    B := TPDFInfoRecord.ParseDate('not a date', D);
    Check(not B, 'Invalid string "not a date" → False');

    B := TPDFInfoRecord.ParseDate('', D);
    Check(not B, 'Empty string → False');

    B := TPDFInfoRecord.ParseDate('D:', D);
    // Could be True (empty date) or False — just no exception
    Pass(Format('D: (empty) handled without exception (parsed=%s)', [BoolToStr(B, True)]));

  except
    on E: Exception do
      Fail('ParseDate raised ' + E.ClassName, E.Message);
  end;
end;

// =========================================================================
// T02 — Metadata loading from the Word-generated PDF
// =========================================================================

procedure TestMetadataLoad(const APath: string);
var
  Doc:  TPDFDocument;
  Meta: TPDFMetadata;
begin
  Section('T02 — Metadata Load (Word PDF)');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      Check(Doc.PageCount > 0,
        Format('Document loaded, %d page(s)', [Doc.PageCount]));

      Meta := TPDFMetadataLoader.Load(Doc.Trailer, Doc.Catalog, Doc.Resolver);
      try
        // At minimum one of Info or XMP should be present in any real PDF
        var HasAny := Meta.HasInfo or Meta.HasXMP;
        Check(HasAny, 'Has Info dict or XMP metadata');

        WriteLn(Format('  HasInfo: %s   HasXMP: %s',
          [BoolToStr(Meta.HasInfo, True), BoolToStr(Meta.HasXMP, True)]));
        WriteLn(Format('  Title    : "%s"', [Meta.BestTitle]));
        WriteLn(Format('  Author   : "%s"', [Meta.BestAuthor]));
        WriteLn(Format('  Creator  : "%s"', [Meta.BestCreator]));
        WriteLn(Format('  Producer : "%s"', [Meta.BestProducer]));

        if Meta.Info.HasCreationDate then
          WriteLn(Format('  Created  : %s', [DateTimeToStr(Meta.Info.CreationDate)]));
        if Meta.Info.HasModDate then
          WriteLn(Format('  Modified : %s', [DateTimeToStr(Meta.Info.ModDate)]));
        if Meta.HasXMP then
          WriteLn(Format('  XMP size : %d bytes', [Length(Meta.XMP.RawXML)]));

        // Sanity: BestProducer should mention PDF generation tool (non-empty)
        Check((Length(Meta.BestProducer) > 0) or
              (Length(Meta.BestCreator) > 0) or
              (Length(Meta.BestTitle)   > 0),
          'At least one metadata field is non-empty');

      finally
        Meta.Free;
      end;

    except
      on E: Exception do
        Fail('Metadata load raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T03 — Outline (bookmarks) loading — tests graceful handling of any PDF
// =========================================================================

procedure TestOutlineLoad(const APath: string; const ALabel: string);
var
  Doc:     TPDFDocument;
  Outline: TPDFOutline;
  I:       Integer;
begin
  Section('T03 — Outline Load (' + ALabel + ')');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      Outline := TPDFOutline.Create;
      try
        Outline.LoadFromCatalog(Doc.Catalog, Doc.Resolver);
        // Just verify it doesn't crash; empty outline is valid
        Pass(Format('LoadFromCatalog completed  (%d top-level items)',
          [Outline.Items.Count]));

        if Outline.Items.Count > 0 then
        begin
          // Verify children are accessible
          var TotalItems := 0;
          for I := 0 to Outline.Items.Count - 1 do
          begin
            Inc(TotalItems);
            var Item := Outline.Items[I];
            Check(Length(Item.Title) >= 0,
              Format('[%d] Title accessible: "%s"', [I, Item.Title]));
            Inc(TotalItems, Item.ChildCount);
          end;
          WriteLn(Format('  Total items (top + children): %d', [TotalItems]));
          WriteLn(Format('  First item: "%s"  (dest valid=%s)',
            [Outline.Items[0].Title,
             BoolToStr(Outline.Items[0].Dest.IsValid, True)]));
        end else
          WriteLn('  (no bookmarks — normal for simple PDFs)');

      finally
        Outline.Free;
      end;
    except
      on E: Exception do
        Fail('Outline load raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T04 — Annotations loading
// =========================================================================

procedure TestAnnotationsLoad(const APath: string; const ALabel: string;
  AMaxPages: Integer = 3);
var
  Doc:    TPDFDocument;
  Annots: TPDFAnnotationList;
  I:      Integer;
  Total:  Integer;
begin
  Section('T04 — Annotations Load (' + ALabel + ')');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      Total := 0;
      for I := 0 to Min(AMaxPages - 1, Doc.PageCount - 1) do
      begin
        var Page := Doc.Pages[I];
        Annots := TPDFAnnotationLoader.LoadForPage(Page.Dict, I, Doc.Resolver);
        try
          Inc(Total, Annots.Count);
          if Annots.Count > 0 then
          begin
            WriteLn(Format('  Page[%d]: %d annotation(s)', [I, Annots.Count]));
            for var J := 0 to Min(2, Annots.Count - 1) do
            begin
              var A := Annots[J];
              // Each annotation must have a valid type string
              Check(Length(A.TypeLabel) > 0,
                Format('  Annot[%d] TypeLabel non-empty: "%s"', [J, A.TypeLabel]));
            end;
          end;
        finally
          Annots.Free;
        end;
      end;
      Pass(Format('Annotations loaded from %d page(s), total=%d',
        [Min(AMaxPages, Doc.PageCount), Total]));
    except
      on E: Exception do
        Fail('Annotations load raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T05 — AcroForms loading
// =========================================================================

procedure TestAcroFormsLoad(const APath: string; const ALabel: string);
var
  Doc:   TPDFDocument;
  Forms: TPDFAcroForm;
begin
  Section('T05 — AcroForms Load (' + ALabel + ')');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      Forms := TPDFAcroForm.Create;
      try
        Forms.LoadFromCatalog(Doc.Catalog, Doc.Resolver);
        Pass(Format('LoadFromCatalog completed  (%d total fields, %d leaf fields)',
          [Forms.Fields.Count, Length(Forms.LeafFields)]));

        if Forms.Fields.Count > 0 then
        begin
          var Leaves := Forms.LeafFields;
          WriteLn(Format('  Fields: %d total, %d leaves',
            [Forms.Fields.Count, Length(Leaves)]));
          for var I := 0 to Min(4, Length(Leaves) - 1) do
          begin
            var F := Leaves[I];
            WriteLn(Format('  [%d] "%s"  type=%s  value="%s"',
              [I, F.FullName,
               GetEnumName(TypeInfo(TPDFFieldType), Ord(F.FieldType)),
               F.ValueString]));
            Check(Length(F.FullName) > 0,
              Format('Field[%d] FullName non-empty', [I]));
          end;

          // FindField must return non-nil for any leaf field's full name
          if Length(Leaves) > 0 then
          begin
            var First := Leaves[0];
            var Found := Forms.FindField(First.FullName);
            Check(Found <> nil,
              Format('FindField("%s") returns non-nil', [First.FullName]));
          end;
        end else
          WriteLn('  (no form fields — normal for non-form PDFs)');

      finally
        Forms.Free;
      end;
    except
      on E: Exception do
        Fail('AcroForms load raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T06 — ImageExtractor on Word PDF (may have embedded images or none)
// =========================================================================

procedure TestImageExtractorWord(const APath: string);
var
  Doc:  TPDFDocument;
  Extr: TPDFImageExtractor;
  All:  TArray<TPDFExtractedImage>;
  I:    Integer;
begin
  Section('T06 — ImageExtractor (Word PDF)');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      Extr := TPDFImageExtractor.Create(Doc);
      try
        All := Extr.ExtractAll;
        try
          // Word PDFs may or may not have embedded images — no crash is the key test
          Pass(Format('ExtractAll completed without exception  (%d images found)',
            [Length(All)]));

          var JPEGs := 0;
          var Raws  := 0;
          for I := 0 to High(All) do
          begin
            var Rec := All[I];
            if Rec.Image = nil then Continue;
            if Rec.IsJPEG then Inc(JPEGs) else Inc(Raws);
            Check(Rec.Width  > 0, Format('Image[%d] Width > 0  (got %d)',  [I, Rec.Width]));
            Check(Rec.Height > 0, Format('Image[%d] Height > 0  (got %d)', [I, Rec.Height]));
            Check(Rec.PageIndex >= 0,
              Format('Image[%d] PageIndex >= 0  (got %d)', [I, Rec.PageIndex]));
            WriteLn(Format('  Image[%d] page=%d  %dx%d  cs=%s  %s  inline=%s',
              [I, Rec.PageIndex,
               Rec.Width, Rec.Height,
               Rec.ColorSpaceName,
               IfThen(Rec.IsJPEG, 'JPEG', 'raw'),
               BoolToStr(Rec.IsInline, True)]));
          end;
          WriteLn(Format('  JPEG: %d   Raw: %d', [JPEGs, Raws]));
        finally
          for I := 0 to High(All) do
            All[I].Image.Free;
        end;
      finally
        Extr.Free;
      end;
    except
      on E: Exception do
        Fail('ImageExtractor (Word) raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T07 — ImageExtractor on scanned PDF (must have images)
// =========================================================================

procedure TestImageExtractorScanned(const APath: string);
var
  Doc:  TPDFDocument;
  Extr: TPDFImageExtractor;
  All:  TArray<TPDFExtractedImage>;
  I:    Integer;
begin
  Section('T07 — ImageExtractor (Scanned PDF — expects images)');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      Check(Doc.PageCount > 0,
        Format('Scanned PDF loaded  (%d pages)', [Doc.PageCount]));

      Extr := TPDFImageExtractor.Create(Doc);
      try
        // Extract just first page to keep test fast
        All := Extr.ExtractPage(0);
        try
          Check(Length(All) > 0,
            Format('Page 0 has %d images  (scanned PDF must have at least 1)',
              [Length(All)]));

          for I := 0 to High(All) do
          begin
            var Rec := All[I];
            if Rec.Image = nil then Continue;
            Check(Rec.Width  > 0, Format('Scan Image[%d] Width > 0',  [I]));
            Check(Rec.Height > 0, Format('Scan Image[%d] Height > 0', [I]));
            WriteLn(Format('  Scan Image[%d] %dx%d  cs=%s  %s  inline=%s',
              [I, Rec.Width, Rec.Height,
               Rec.ColorSpaceName,
               IfThen(Rec.IsJPEG, 'JPEG', 'raw'),
               BoolToStr(Rec.IsInline, True)]));
          end;
        finally
          for I := 0 to High(All) do
            All[I].Image.Free;
        end;

        // Also verify multi-page traversal doesn't crash
        var AllPages := Extr.ExtractAll;
        try
          Pass(Format('ExtractAll completed on %d-page scanned PDF  (%d images total)',
            [Doc.PageCount, Length(AllPages)]));
        finally
          for I := 0 to High(AllPages) do
            AllPages[I].Image.Free;
        end;

      finally
        Extr.Free;
      end;
    except
      on E: Exception do
        Fail('ImageExtractor (scanned) raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T08 — TPDFMetadata: BestXxx methods (prefer XMP over Info dict)
// =========================================================================

procedure TestMetadataBestFields(const APath: string);
var
  Doc:  TPDFDocument;
  Meta: TPDFMetadata;
begin
  Section('T08 — Metadata BestXxx preference (XMP > Info)');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      Meta := TPDFMetadataLoader.Load(Doc.Trailer, Doc.Catalog, Doc.Resolver);
      try
        // BestXxx must never raise — return empty string when data absent
        var T := Meta.BestTitle;
        var A := Meta.BestAuthor;
        var S := Meta.BestSubject;
        var K := Meta.BestKeywords;
        var C := Meta.BestCreator;
        var P := Meta.BestProducer;

        Pass('BestTitle completed without exception');
        Pass('BestAuthor completed without exception');
        Pass('BestSubject completed without exception');
        Pass('BestKeywords completed without exception');
        Pass('BestCreator completed without exception');
        Pass('BestProducer completed without exception');

        // If XMP present, BestTitle should equal XMP title (when available)
        if Meta.HasXMP and (Meta.XMP.DCTitle <> '') then
          Check(Meta.BestTitle = Meta.XMP.DCTitle,
            Format('BestTitle = XMP DCTitle when XMP present  ("%s")',
              [Meta.XMP.DCTitle]));

        WriteLn(Format('  Title/Author/Creator/Producer: "%s" / "%s" / "%s" / "%s"',
          [T, A, C, P]));
        WriteLn(Format('  Subject/Keywords: "%s" / "%s"', [S, K]));
      finally
        Meta.Free;
      end;
    except
      on E: Exception do
        Fail('BestXxx raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T09 — Annotations: type coverage (verify TypeLabel for every known type)
// =========================================================================

procedure TestAnnotationTypeCoverage;
begin
  Section('T09 — Annotation TypeLabel coverage');
  // TPDFAnnotation.TypeLabel must return a non-empty string for every enum value
  try
    for var AnnotType := Low(TPDFAnnotType) to High(TPDFAnnotType) do
    begin
      var A := TPDFAnnotation.Create;
      try
        A.AnnotType := AnnotType;
        var Lbl := A.TypeLabel;
        Check(Length(Lbl) > 0,
          Format('TypeLabel(%s) non-empty  (got "%s")',
            [GetEnumName(TypeInfo(TPDFAnnotType), Ord(AnnotType)), Lbl]));
      finally
        A.Free;
      end;
    end;
  except
    on E: Exception do
      Fail('TypeLabel coverage raised ' + E.ClassName, E.Message);
  end;
end;

// =========================================================================
// T10 — AcroForms: field flag helpers (unit test with synthetic field)
// =========================================================================

procedure TestFormFieldFlags;
var
  F: TPDFFormField;
begin
  Section('T10 — AcroForms field flag helpers');
  F := TPDFFormField.Create;
  try
    try
      // Button: PushButton = bit 16 (0-indexed bit 17 in spec, mask $10000)
      F.FieldType := TPDFFieldType.Button;
      F.FlagsRaw  := $10000;  // Pushbutton flag (bit 17 = 1 << 16)
      Check(F.IsPushButton,  Format('PushButton flag set  (flags=$%x)', [F.FlagsRaw]));
      Check(not F.IsCheckBox,'Not CheckBox when PushButton set');
      Check(not F.IsRadioButton, 'Not RadioButton when PushButton set');

      // CheckBox: no PushButton bit, no RadioButton bit
      F.FlagsRaw := 0;
      Check(not F.IsPushButton, 'IsPushButton=False when flags=0');
      Check(F.IsCheckBox,       'IsCheckBox=True when no special button flags');
      Check(not F.IsRadioButton,'IsRadioButton=False when flags=0');

      // RadioButton: bit 16 (1 << 15 = $8000)
      F.FlagsRaw := $8000;  // RadioButton flag
      Check(not F.IsPushButton, 'IsPushButton=False for RadioButton');
      Check(F.IsRadioButton,    Format('IsRadioButton=True  (flags=$%x)', [F.FlagsRaw]));

      // ReadOnly bit 0 (1 << 0 = 1)
      F.FieldType := TPDFFieldType.Text;
      F.FlagsRaw  := 1;
      Check(F.IsReadOnly, 'IsReadOnly=True when bit 0 set');
      F.FlagsRaw  := 0;
      Check(not F.IsReadOnly, 'IsReadOnly=False when bit 0 clear');

      // Required bit 1 (1 << 1 = 2)
      F.FlagsRaw := 2;
      Check(F.IsRequired, 'IsRequired=True when bit 1 set');
      F.FlagsRaw := 0;
      Check(not F.IsRequired, 'IsRequired=False when bit 1 clear');

      // Text: MultiLine bit 12 (1 << 12 = $1000)
      F.FlagsRaw := $1000;
      Check(F.IsMultiLine, Format('IsMultiLine=True  (flags=$%x)', [F.FlagsRaw]));
      F.FlagsRaw := 0;
      Check(not F.IsMultiLine, 'IsMultiLine=False when bit 12 clear');

      // Choice: ComboBox bit 17 (1 << 17 = $20000)
      F.FieldType := TPDFFieldType.Choice;
      F.FlagsRaw  := $20000;
      Check(F.IsComboBox, Format('IsComboBox=True  (flags=$%x)', [F.FlagsRaw]));
      F.FlagsRaw  := 0;
      Check(not F.IsComboBox, 'IsComboBox=False when bit 17 clear');

    except
      on E: Exception do
        Fail('FormField flags raised ' + E.ClassName, E.Message);
    end;
  finally
    F.Free;
  end;
end;

// =========================================================================
// T11 — Outline: item creation and tree structure (in-memory, no PDF)
// =========================================================================

procedure TestOutlineTree;
var
  Root: TPDFOutlineItem;
  C1, C2, G1: TPDFOutlineItem;
begin
  Section('T11 — Outline item tree (in-memory)');
  Root := TPDFOutlineItem.Create;
  try
    try
      Root.Title  := 'Root';
      Root.IsOpen := True;

      C1 := Root.AddChild;
      C1.Title := 'Chapter 1';
      C1.Dest.IsValid  := True;
      C1.Dest.PageIndex := 0;
      C1.Dest.Kind     := TPDFDestKind.XYZ;

      C2 := Root.AddChild;
      C2.Title := 'Chapter 2';

      G1 := C1.AddChild;
      G1.Title  := 'Section 1.1';
      G1.Parent := C1;

      Check(Root.ChildCount = 2, Format('Root has 2 children  (got %d)', [Root.ChildCount]));
      Check(C1.ChildCount   = 1, Format('C1 has 1 child  (got %d)',   [C1.ChildCount]));
      Check(C2.ChildCount   = 0, Format('C2 has 0 children  (got %d)', [C2.ChildCount]));
      Check(Root.Children[0].Title = 'Chapter 1', 'First child is Chapter 1');
      Check(Root.Children[1].Title = 'Chapter 2', 'Second child is Chapter 2');
      Check(C1.Children[0].Title  = 'Section 1.1', 'Grand-child is Section 1.1');
      Check(G1.Parent = C1, 'G1.Parent = C1');
      Check(C1.Dest.IsValid,    'C1 destination is valid');
      Check(C1.Dest.PageIndex = 0, 'C1 dest page = 0');

    except
      on E: Exception do
        Fail('Outline tree raised ' + E.ClassName, E.Message);
    end;
  finally
    Root.Free;  // owns all children
  end;
end;

// =========================================================================
// T12 — CryptoSHA1 — known-answer test
// =========================================================================

procedure TestCryptoSHA1;
var
  Empty: TBytes;
  ABCHash: TBytes;
  Got: TBytes;
  S: string;
  I: Integer;
begin
  Section('T12 — CryptoSHA1 known-answer test');
  try
    // SHA-1('') = da39a3ee5e6b4b0d3255bfef95601890afd80709
    SetLength(Empty, 0);
    Got := CryptoSHA1(Empty);
    Check(Length(Got) = 20, Format('SHA-1 empty: digest length = 20  (got %d)', [Length(Got)]));
    if Length(Got) = 20 then
    begin
      S := '';
      for I := 0 to 19 do S := S + IntToHex(Got[I], 2);
      Check(LowerCase(S) = 'da39a3ee5e6b4b0d3255bfef95601890afd80709',
        Format('SHA-1("") = da39a3ee...  (got %s)', [LowerCase(S)]));
    end;

    // SHA-1('abc') = a9993e364706816aba3e25717850c26c9cd0d89d
    SetLength(ABCHash, 3);
    ABCHash[0] := Ord('a'); ABCHash[1] := Ord('b'); ABCHash[2] := Ord('c');
    Got := CryptoSHA1(ABCHash);
    Check(Length(Got) = 20, 'SHA-1 "abc": digest length = 20');
    if Length(Got) = 20 then
    begin
      S := '';
      for I := 0 to 19 do S := S + IntToHex(Got[I], 2);
      Check(LowerCase(S) = 'a9993e364706816aba3e25717850c26c9cd0d89d',
        Format('SHA-1("abc") = a9993e36...  (got %s)', [LowerCase(S)]));
    end;
  except
    on E: Exception do
      Fail('CryptoSHA1 raised ' + E.ClassName, E.Message);
  end;
end;

// =========================================================================
// T13 — TPDFTOCBuilder — in-memory tree + serialization sanity check
// =========================================================================

procedure TestTOCBuilder;
var
  TOC: TPDFTOCBuilder;
  Ch1, Ch2: TPDFTOCEntry;
  Objects: TObjectDictionary<Integer, TPDFObject>;
  PageNums: TArray<Integer>;
  RootNum: Integer;
  I: Integer;
begin
  Section('T13 — TPDFTOCBuilder in-memory tree');
  TOC := TPDFTOCBuilder.Create;
  Objects := TObjectDictionary<Integer, TPDFObject>.Create([doOwnsValues]);
  try
    try
      Check(TOC.IsEmpty, 'New TOC is empty');
      Check(TOC.Count = 0, 'New TOC count = 0');

      Ch1 := TOC.Add('Chapter 1', 0);
      Ch2 := TOC.Add('Chapter 2', 1);
      Ch1.AddChild('Section 1.1', 0);
      Ch1.AddChild('Section 1.2', 1);

      Check(not TOC.IsEmpty, 'TOC non-empty after Add');
      Check(TOC.Count = 2, Format('TOC has 2 top-level entries  (got %d)', [TOC.Count]));
      Check(Ch1.ChildCount = 2, Format('Ch1 has 2 children  (got %d)', [Ch1.ChildCount]));
      Check(Ch2.ChildCount = 0, 'Ch2 has 0 children');

      // Serialize to a dummy objects dictionary
      SetLength(PageNums, 3);
      for I := 0 to 2 do PageNums[I] := 100 + I;  // fake page obj numbers
      var NextNum := 10;
      RootNum := TOC.SerializeTo(Objects, NextNum, PageNums);

      Check(RootNum = 10, Format('Root dict at obj#10  (got %d)', [RootNum]));
      // 4 entries (2 top + 2 children) + 1 root = 5 objects total from 10..14
      Check(Objects.Count = 5,
        Format('Objects count = 5 (root + 4 entries)  (got %d)', [Objects.Count]));
      Check(NextNum = 15, Format('NextNum advanced to 15  (got %d)', [NextNum]));

      // All objects must be TPDFDictionary
      for var Pair in Objects do
        Check(Pair.Value.IsDictionary,
          Format('Object %d is TPDFDictionary', [Pair.Key]));

    except
      on E: Exception do
        Fail('TOCBuilder raised ' + E.ClassName, E.Message);
    end;
  finally
    Objects.Free;
    TOC.Free;
  end;
end;

// =========================================================================
// T14 — TPDFTextSearch — search in real PDF
// =========================================================================

procedure TestTextSearch(const APath: string);
var
  Doc:     TPDFDocument;
  Search:  TPDFTextSearch;
  Matches: TArray<TPDFSearchMatch>;
begin
  Section('T14 — TPDFTextSearch (Word PDF)');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      Search := TPDFTextSearch.Create(Doc);
      try
        // Search for a common short word; we just verify no exception and
        // that the result is an array (possibly empty).
        Matches := Search.Search('de');
        Pass(Format('Search("de") completed — %d match(es) found', [Length(Matches)]));

        if Length(Matches) > 0 then
        begin
          var M := Matches[0];
          Check(M.PageIndex >= 0, Format('Match[0] PageIndex >= 0  (got %d)', [M.PageIndex]));
          Check(Length(M.Text) > 0, 'Match[0] Text non-empty');
          WriteLn(Format('  First match: page=%d  line=%d  text="%s"  bounds=(%.1f,%.1f,%.1f,%.1f)',
            [M.PageIndex, M.LineIndex, M.Text,
             M.Bounds.Left, M.Bounds.Bottom, M.Bounds.Right, M.Bounds.Top]));
        end;

        // Case-sensitive whole-word search must not crash
        Matches := Search.Search('el',
          TPDFSearchOptions.CaseSensitiveExact);
        Pass(Format('CaseSensitiveExact search("el") — %d match(es)', [Length(Matches)]));

      finally
        Search.Free;
      end;
    except
      on E: Exception do
        Fail('TextSearch raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T15 — TPDFSignatureVerifier — graceful handling with no signed PDF
// =========================================================================

procedure TestSignatureVerifier(const APath: string);
var
  Doc:  TPDFDocument;
  FS:   TFileStream;
  Sigs: TArray<TPDFSignatureInfo>;
  I:    Integer;
begin
  Section('T15 — TPDFSignatureVerifier');
  Doc := TPDFDocument.Create;
  FS  := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    try
      Doc.LoadFromStream(FS);
      FS.Seek(0, soBeginning);
      Sigs := TPDFSignatureVerifier.Verify(Doc, FS);
      Pass(Format('Verify completed — %d signature(s) found', [Length(Sigs)]));
      for I := 0 to High(Sigs) do
      begin
        var Sig := Sigs[I];
        WriteLn(Format('  Sig[%d]: field="%s"  signer="%s"  alg="%s"  status=%s',
          [I, Sig.FieldName, Sig.SignerName, Sig.HashAlgorithm,
           GetEnumName(TypeInfo(TPDFHashStatus), Ord(Sig.HashStatus))]));
      end;
      // A PDF without signatures must still return an empty array, not raise
      Check(Length(Sigs) >= 0, 'Result is a valid (possibly empty) array');
    except
      on E: Exception do
        Fail('SignatureVerifier raised ' + E.ClassName, E.Message);
    end;
  finally
    FS.Free;
    Doc.Free;
  end;
end;

// =========================================================================
// T16 — TPDFIncrementalUpdater — basic round-trip (add 1 page)
// =========================================================================

procedure TestIncrementalAddPage;
var
  Builder:   TPDFBuilder;
  Upd:       TPDFIncrementalUpdater;
  CB:        TPDFContentBuilder;
  Page:      TPDFDictionary;
  BaseStm:   TBytesStream;
  OutStm:    TBytesStream;
  BaseBytes: TBytes;
  FinalDoc:  TPDFDocument;
  FinalStm:  TBytesStream;
begin
  Section('T16 — TPDFIncrementalUpdater (add 1 page)');
  BaseStm := TBytesStream.Create(nil);
  OutStm  := TBytesStream.Create(nil);
  try
    try
      // --- Build base PDF (1 blank page) ---
      Builder := TPDFBuilder.Create;
      try
        Builder.AddPage;
        Builder.SaveToStream(BaseStm);
      finally
        Builder.Free;
      end;

      BaseBytes := Copy(BaseStm.Bytes, 0, BaseStm.Size);
      Check(Length(BaseBytes) > 0, Format('Base PDF built  (%d bytes)', [Length(BaseBytes)]));

      // --- Apply incremental update ---
      Upd := TPDFIncrementalUpdater.Create(BaseBytes);
      try
        Check(Upd.Document.PageCount = 1,
          Format('Loaded base doc has 1 page  (got %d)', [Upd.Document.PageCount]));
        Check(Upd.Document.MaxObjectNumber > 0,
          Format('MaxObjectNumber > 0  (got %d)', [Upd.Document.MaxObjectNumber]));

        Page := Upd.AddPage;
        Check(Page <> nil, 'AddPage returned non-nil dict');
        Upd.AddStandardFont(Page, 'F1', 'Helvetica');

        CB := TPDFContentBuilder.Create;
        try
          CB.BeginText;
          CB.SetFont('F1', 12);
          CB.SetTextMatrix(1, 0, 0, 1, 72, 720);
          CB.ShowText('Appended page via incremental update');
          CB.EndText;
          Upd.SetPageContent(Page, CB.Build);
        finally
          CB.Free;
        end;

        Upd.SaveToStream(OutStm);
      finally
        Upd.Free;
      end;

      var FinalBytes := Copy(OutStm.Bytes, 0, OutStm.Size);
      Check(Length(FinalBytes) > Length(BaseBytes),
        Format('Final size (%d) > base size (%d)',
               [Length(FinalBytes), Length(BaseBytes)]));

      // --- Reload and verify page count ---
      FinalStm := TBytesStream.Create(FinalBytes);
      FinalDoc := TPDFDocument.Create;
      try
        FinalDoc.LoadFromStream(FinalStm);
        Check(FinalDoc.PageCount = 2,
          Format('Reloaded doc has 2 pages  (got %d)', [FinalDoc.PageCount]));
      finally
        FinalDoc.Free;
        FinalStm.Free;
      end;

    except
      on E: Exception do
        Fail('IncrementalAddPage raised ' + E.ClassName, E.Message);
    end;
  finally
    OutStm.Free;
    BaseStm.Free;
  end;
end;

// =========================================================================
// T17 — TPDFIncrementalUpdater — multiple AddPage calls in one session
// =========================================================================

procedure TestIncrementalMultiPage;
var
  Builder:   TPDFBuilder;
  Upd:       TPDFIncrementalUpdater;
  Page:      TPDFDictionary;
  BaseStm:   TBytesStream;
  OutStm:    TBytesStream;
  BaseBytes: TBytes;
  FinalDoc:  TPDFDocument;
  FinalStm:  TBytesStream;
  I:         Integer;
begin
  Section('T17 — TPDFIncrementalUpdater (3 pages added in one session)');
  BaseStm := TBytesStream.Create(nil);
  OutStm  := TBytesStream.Create(nil);
  try
    try
      // Build 1-page base
      Builder := TPDFBuilder.Create;
      try
        Builder.AddPage;
        Builder.SaveToStream(BaseStm);
      finally
        Builder.Free;
      end;
      BaseBytes := Copy(BaseStm.Bytes, 0, BaseStm.Size);

      // Add 3 pages incrementally
      Upd := TPDFIncrementalUpdater.Create(BaseBytes);
      try
        for I := 1 to 3 do
        begin
          Page := Upd.AddPage;
          var CB := TPDFContentBuilder.Create;
          try
            CB.BeginText;
            CB.SetFont('F1', 12);
            CB.SetTextMatrix(1, 0, 0, 1, 72, 720);
            CB.ShowText(Format('Incremental page %d', [I]));
            CB.EndText;
            Upd.AddStandardFont(Page, 'F1', 'Helvetica');
            Upd.SetPageContent(Page, CB.Build);
          finally
            CB.Free;
          end;
        end;
        Upd.SaveToStream(OutStm);
      finally
        Upd.Free;
      end;

      var FinalBytes := Copy(OutStm.Bytes, 0, OutStm.Size);
      Check(Length(FinalBytes) > Length(BaseBytes),
        Format('Final (%d bytes) > base (%d bytes)',
               [Length(FinalBytes), Length(BaseBytes)]));

      // Verify 4 pages total
      FinalStm := TBytesStream.Create(FinalBytes);
      FinalDoc := TPDFDocument.Create;
      try
        FinalDoc.LoadFromStream(FinalStm);
        Check(FinalDoc.PageCount = 4,
          Format('Reloaded doc has 4 pages (1 base + 3 added)  (got %d)',
                 [FinalDoc.PageCount]));
      finally
        FinalDoc.Free;
        FinalStm.Free;
      end;

    except
      on E: Exception do
        Fail('IncrementalMultiPage raised ' + E.ClassName, E.Message);
    end;
  finally
    OutStm.Free;
    BaseStm.Free;
  end;
end;

// =========================================================================
// Main
// =========================================================================

const
  PDF_WORD = 'D:\Documentos\Cuentas de Cobro\2026\pdf\Cuenta de Cobro 452 - Avance Juridico.pdf';
  PDF_SCAN = 'E:\Copilot\AvanceJuridico\Docs\pdfocr\14DESE_1.PDF';

begin
  WriteLn('======================================================');
  WriteLn(' TestAdvanced — PDF Library Phase 9 Validation');
  WriteLn('======================================================');
  WriteLn('  Word PDF: ', PDF_WORD);
  WriteLn('  Scan PDF: ', PDF_SCAN);

  // ---- Pure unit tests (no PDF file needed) ----
  TestDateParser;
  TestAnnotationTypeCoverage;
  TestFormFieldFlags;
  TestOutlineTree;
  TestCryptoSHA1;
  TestTOCBuilder;
  TestIncrementalAddPage;
  TestIncrementalMultiPage;

  // ---- Tests against real PDF files ----
  if not FileExists(PDF_WORD) then
  begin
    WriteLn;
    WriteLn('  [SKIP] Word PDF not found — skipping file-based tests T02..T08');
  end else
  begin
    TestMetadataLoad(PDF_WORD);
    TestOutlineLoad(PDF_WORD, 'Word PDF');
    TestAnnotationsLoad(PDF_WORD, 'Word PDF');
    TestAcroFormsLoad(PDF_WORD, 'Word PDF');
    TestImageExtractorWord(PDF_WORD);
    TestMetadataBestFields(PDF_WORD);
    TestTextSearch(PDF_WORD);
    TestSignatureVerifier(PDF_WORD);
  end;

  if not FileExists(PDF_SCAN) then
  begin
    WriteLn;
    WriteLn('  [SKIP] Scan PDF not found — skipping T07 (ImageExtractor scanned)');
  end else
  begin
    TestImageExtractorScanned(PDF_SCAN);
    TestOutlineLoad(PDF_SCAN, 'Scanned PDF');
    TestAnnotationsLoad(PDF_SCAN, 'Scanned PDF', 2);
    TestAcroFormsLoad(PDF_SCAN, 'Scanned PDF');
  end;

  WriteLn;
  WriteLn('======================================================');
  WriteLn(Format(' TOTAL: %d passed,  %d failed', [PassCount, FailCount]));
  WriteLn('======================================================');

  if FailCount > 0 then ExitCode := 1;

  WriteLn('Press Enter...');
  ReadLn;
end.
