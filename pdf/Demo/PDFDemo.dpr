program PDFDemo;

{$APPTYPE CONSOLE}
{$R *.res}

uses
  System.SysUtils, System.Classes,
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
  uPDF.ContentStream   in '..\Src\Core\uPDF.ContentStream.pas',
  uPDF.Image           in '..\Src\Core\uPDF.Image.pas',
  uPDF.TextExtractor   in '..\Src\Core\uPDF.TextExtractor.pas',
  uPDF.ImageExtractor  in '..\Src\Core\uPDF.ImageExtractor.pas',
  uPDF.Writer          in '..\Src\Core\uPDF.Writer.pas',
  uPDF.Render.Types    in '..\Src\Render\uPDF.Render.Types.pas',
  uPDF.Render.FontCache in '..\Src\Render\uPDF.Render.FontCache.pas',
  uPDF.Render.Skia     in '..\Src\Render\uPDF.Render.Skia.pas',
  uPDF.Outline         in '..\Src\Core\uPDF.Outline.pas',
  uPDF.Annotations     in '..\Src\Core\uPDF.Annotations.pas',
  uPDF.Metadata        in '..\Src\Core\uPDF.Metadata.pas',
  uPDF.AcroForms       in '..\Src\Core\uPDF.AcroForms.pas';

// -------------------------------------------------------------------------
// Demo 1: Open a PDF and display basic info
// -------------------------------------------------------------------------

procedure DemoOpenPDF(const APath: string);
begin
  WriteLn('=== Opening: ', APath, ' ===');
  var Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      WriteLn('Version   : ', Doc.Version.ToString);
      WriteLn('Pages     : ', Doc.PageCount);
      WriteLn('Title     : ', Doc.Title);
      WriteLn('Author    : ', Doc.Author);
      WriteLn;
      for var I := 0 to Min(4, Doc.PageCount - 1) do
      begin
        var Page := Doc.Pages[I];
        WriteLn(Format('  Page %d: %.1f x %.1f pts  rotation=%d',
          [I + 1, Page.Width, Page.Height, Page.Rotation]));
      end;
    except
      on E: Exception do
        WriteLn('ERROR: ', E.Message);
    end;
  finally
    Doc.Free;
  end;
  WriteLn;
end;

// -------------------------------------------------------------------------
// Demo 2: Extract text
// -------------------------------------------------------------------------

procedure DemoExtractText(const APath: string; AMaxPages: Integer = 2);
begin
  WriteLn('=== Text Extraction: ', APath, ' ===');
  var Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      var Extractor := TPDFTextExtractor.Create(Doc);
      try
        for var I := 0 to Min(AMaxPages - 1, Doc.PageCount - 1) do
        begin
          WriteLn('--- Page ', I + 1, ' ---');
          var PageText := Extractor.ExtractPage(I);
          WriteLn('  Fragments: ', Length(PageText.Fragments));
          WriteLn('  Lines:     ', Length(PageText.Lines));
          WriteLn;
          var PlainText := PageText.PlainText;
          // Print first 500 chars
          if Length(PlainText) > 500 then
            WriteLn(PlainText.Substring(0, 500), '...')
          else
            WriteLn(PlainText);
          WriteLn;
        end;
      finally
        Extractor.Free;
      end;
    except
      on E: Exception do
        WriteLn('ERROR: ', E.Message);
    end;
  finally
    Doc.Free;
  end;
  WriteLn;
end;

// -------------------------------------------------------------------------
// Demo 3: Content stream operator walkthrough
// -------------------------------------------------------------------------

procedure DemoWalkOperators(const APath: string);
begin
  WriteLn('=== Content Stream Walk: ', APath, ' ===');
  var Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      if Doc.PageCount = 0 then Exit;
      var Page := Doc.Pages[0];
      var Data := Page.ContentStreamBytes;
      WriteLn('Content stream size: ', Length(Data), ' bytes (decoded)');
      WriteLn;

      var Paths := 0; var Glyphs := 0; var XObjs := 0;

      var Res  := TPDFPageResources.Create(Page);
      var Proc := TPDFContentStreamProcessor.Create;
      try
        Proc.OnPaintPath :=
          procedure(const APath: TPDFPath;
            const AState: TPDFGraphicsState; AOp: TPDFPaintOp)
          begin
            Inc(Paths);
          end;

        Proc.OnPaintGlyph :=
          procedure(const AGlyph: TPDFGlyphInfo;
            const AState: TPDFGraphicsState)
          begin
            Inc(Glyphs);
          end;

        Proc.OnPaintXObject :=
          procedure(const AName: string; const AMatrix: TPDFMatrix;
            const AState: TPDFGraphicsState)
          begin
            Inc(XObjs);
          end;

        Proc.Process(Data, Res, Doc.Resolver);

        WriteLn(Format('  Paint operations: paths=%d  glyphs=%d  xobjects=%d',
          [Paths, Glyphs, XObjs]));
      finally
        Proc.Free;
        Res.Free;
      end;
    except
      on E: Exception do
        WriteLn('ERROR: ', E.Message);
    end;
  finally
    Doc.Free;
  end;
  WriteLn;
end;

// -------------------------------------------------------------------------
// Demo 4: Image extraction
// -------------------------------------------------------------------------

procedure DemoExtractImages(const APath: string; const AOutDir: string = '');
begin
  WriteLn('=== Image Extraction: ', APath, ' ===');
  var Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      var Extractor := TPDFImageExtractor.Create(Doc);
      try
        var All := Extractor.ExtractAll;
        try
          WriteLn(Format('Total images found: %d', [Length(All)]));
          var JPEGs := 0; var BMPs := 0;
          for var Rec in All do
          begin
            if Rec.Image <> nil then
            begin
              WriteLn(Format('  Page %d  %s  %dx%d  CS=%s  %s',
                [Rec.PageIndex + 1,
                 IfThen(Rec.IsInline, '(inline)', Rec.XObjectName),
                 Rec.Width, Rec.Height,
                 Rec.ColorSpaceName,
                 IfThen(Rec.IsJPEG, 'JPEG', 'raw')]));
              if Rec.IsJPEG then Inc(JPEGs) else Inc(BMPs);
            end;
          end;
          WriteLn(Format('  JPEG: %d  Raw: %d', [JPEGs, BMPs]));

          // Save images if output dir provided
          if AOutDir <> '' then
          begin
            if not System.SysUtils.DirectoryExists(AOutDir) then
              System.SysUtils.ForceDirectories(AOutDir);
            WriteLn('Saving to: ', AOutDir);
            var Counter := 0;
            for var Rec in All do
            begin
              if Rec.Image = nil then Continue;
              Inc(Counter);
              var Ext  := IfThen(Rec.IsJPEG, '.jpg', '.bmp');
              var Name := Format('page%d_img%d%s',
                [Rec.PageIndex + 1, Counter, Ext]);
              var FPath := IncludeTrailingPathDelimiter(AOutDir) + Name;
              try
                if Rec.IsJPEG then
                begin
                  var FS := TFileStream.Create(FPath, fmCreate);
                  try
                    var Bytes := Rec.Image.Samples;
                    if Length(Bytes) > 0 then FS.Write(Bytes[0], Length(Bytes));
                  finally
                    FS.Free;
                  end;
                end else
                  Rec.Image.SaveToBMP(FPath);
                WriteLn('  Saved: ', Name);
              except
                on E: Exception do
                  WriteLn('  SKIP: ', Name, ' — ', E.Message);
              end;
            end;
          end;
        finally
          for var Rec in All do
            Rec.Image.Free;
        end;
      finally
        Extractor.Free;
      end;
    except
      on E: Exception do
        WriteLn('ERROR: ', E.Message);
    end;
  finally
    Doc.Free;
  end;
  WriteLn;
end;

// -------------------------------------------------------------------------
// Demo 5: Create a PDF from scratch with TPDFBuilder + TPDFContentBuilder
// -------------------------------------------------------------------------

// Register a standard Type1 font in a page's /Resources/Font dict.
// APageDict  : the dict returned by TPDFBuilder.AddPage
// AResName   : the name used in Tf operator, e.g. 'Helvetica-Bold'
// ABaseName  : PDF base font name, e.g. 'Helvetica-Bold'
procedure AddStdFont(APageDict: TPDFDictionary;
  const AResName, ABaseName: string);
var
  ResDict:  TPDFDictionary;
  FontDict: TPDFDictionary;
  FD:       TPDFDictionary;
begin
  ResDict := APageDict.GetAsDictionary('Resources');
  if ResDict = nil then
  begin
    ResDict := TPDFDictionary.Create;
    APageDict.SetValue('Resources', ResDict);
  end;
  FontDict := ResDict.GetAsDictionary('Font');
  if FontDict = nil then
  begin
    FontDict := TPDFDictionary.Create;
    ResDict.SetValue('Font', FontDict);
  end;
  FD := TPDFDictionary.Create;
  FD.SetValue('Type',     TPDFName.Create('Font'));
  FD.SetValue('Subtype',  TPDFName.Create('Type1'));
  FD.SetValue('BaseFont', TPDFName.Create(ABaseName));
  FD.SetValue('Encoding', TPDFName.Create('WinAnsiEncoding'));
  FontDict.SetValue(AResName, FD);
end;

// Attach a finished content stream to a page dict so TPDFBuilder picks it up.
procedure AttachContent(APageDict: TPDFDictionary; CB: TPDFContentBuilder);
var
  Stm: TPDFStream;
begin
  Stm := TPDFStream.Create;
  Stm.SetRawData(CB.Build);
  APageDict.SetValue('Contents', Stm);
end;

procedure DemoCreatePDF(const AOutPath: string);
var
  Builder: TPDFBuilder;
  Page1, Page2: TPDFDictionary;
  CB1, CB2: TPDFContentBuilder;
  Doc: TPDFDocument;
  CX, CY, R, K: Single;
  Ang, J, I: Integer;
  Rad, CosA, SinA, OX, OY, BX, T: Single;
  JoinLabels: array[0..2] of string;
begin
  WriteLn('=== Creating PDF: ', AOutPath, ' ===');
  Builder := TPDFBuilder.Create;
  try
    Builder.SetTitle('PDF Library Demo');
    Builder.SetAuthor('Delphi PDF Library');
    Builder.SetSubject('Phase 5 — PDF Writer');
    Builder.SetCreator('PDFDemo');

    // ----------------------------------------------------------------
    // Page 1: shapes and text
    // ----------------------------------------------------------------
    Page1 := Builder.AddPage(595, 842); // A4 portrait
    AddStdFont(Page1, 'Helvetica',         'Helvetica');
    AddStdFont(Page1, 'Helvetica-Bold',    'Helvetica-Bold');
    AddStdFont(Page1, 'Helvetica-Oblique', 'Helvetica-Oblique');
    AddStdFont(Page1, 'Courier',           'Courier');

    CB1 := TPDFContentBuilder.Create;
    try
      // Blue header bar
      CB1.SaveState;
      CB1.SetFillRGB(0.2, 0.4, 0.8);
      CB1.Rectangle(50, 780, 495, 40);
      CB1.Fill;
      CB1.RestoreState;

      // White title on blue bar
      CB1.SaveState;
      CB1.SetFillRGB(1, 1, 1);
      CB1.BeginText;
      CB1.SetFont('Helvetica-Bold', 18);
      CB1.SetTextMatrix(1, 0, 0, 1, 60, 793);
      CB1.ShowText('Delphi PDF Library - Phase 5 Demo');
      CB1.EndText;
      CB1.RestoreState;

      // Section header: shapes
      CB1.SaveState;
      CB1.SetFillRGB(0, 0, 0);
      CB1.BeginText;
      CB1.SetFont('Helvetica-Bold', 14);
      CB1.SetTextMatrix(1, 0, 0, 1, 50, 745);
      CB1.ShowText('1. Basic Shapes');
      CB1.EndText;
      CB1.RestoreState;

      // Stroked rectangle
      CB1.SaveState;
      CB1.SetLineWidth(2);
      CB1.SetStrokeRGB(0.8, 0.2, 0.2);
      CB1.Rectangle(50, 680, 150, 50);
      CB1.Stroke;
      CB1.RestoreState;

      // Filled ellipse via Bezier (4-arc approximation, K = 0.5523)
      CX := 290; CY := 705; R := 25; K := 0.5523;
      CB1.SaveState;
      CB1.SetFillRGB(0.2, 0.7, 0.3);
      CB1.MoveTo(CX + R, CY);
      CB1.CurveTo(CX + R, CY + K*R, CX + K*R, CY + R, CX,       CY + R);
      CB1.CurveTo(CX - K*R, CY + R, CX - R,   CY + K*R, CX - R, CY);
      CB1.CurveTo(CX - R,   CY - K*R, CX - K*R, CY - R, CX,     CY - R);
      CB1.CurveTo(CX + K*R, CY - R,   CX + R, CY - K*R, CX + R, CY);
      CB1.ClosePath;
      CB1.Fill;
      CB1.RestoreState;

      // Dashed diagonal line
      CB1.SaveState;
      CB1.SetLineWidth(1.5);
      CB1.SetDash([6, 3], 0);
      CB1.SetStrokeRGB(0.5, 0.2, 0.7);
      CB1.MoveTo(380, 680);
      CB1.LineTo(530, 730);
      CB1.Stroke;
      CB1.RestoreState;

      // Section header: typography
      CB1.SaveState;
      CB1.SetFillRGB(0, 0, 0);
      CB1.BeginText;
      CB1.SetFont('Helvetica-Bold', 14);
      CB1.SetTextMatrix(1, 0, 0, 1, 50, 645);
      CB1.ShowText('2. Typography');
      CB1.EndText;
      CB1.RestoreState;

      // Multi-font text block
      CB1.SaveState;
      CB1.SetFillRGB(0, 0, 0);
      CB1.BeginText;
      CB1.SetFont('Helvetica', 11);
      CB1.SetLeading(16);
      CB1.SetTextMatrix(1, 0, 0, 1, 50, 620);
      CB1.ShowText('Regular  - The quick brown fox jumps over the lazy dog.');
      CB1.NextLine;
      CB1.SetFont('Helvetica-Bold', 11);
      CB1.ShowText('Bold     - Pack my box with five dozen liquor jugs.');
      CB1.NextLine;
      CB1.SetFont('Helvetica-Oblique', 11);
      CB1.ShowText('Italic   - How vexingly quick daft zebras jump!');
      CB1.NextLine;
      CB1.SetFont('Courier', 11);
      CB1.ShowText('Mono     - 0123456789  !@#$%^&*()');
      CB1.EndText;
      CB1.RestoreState;

      // Section header: color bands
      CB1.SaveState;
      CB1.SetFillRGB(0, 0, 0);
      CB1.BeginText;
      CB1.SetFont('Helvetica-Bold', 14);
      CB1.SetTextMatrix(1, 0, 0, 1, 50, 545);
      CB1.ShowText('3. Color Bands');
      CB1.EndText;
      CB1.RestoreState;

      for I := 0 to 9 do
      begin
        T := I / 9.0;
        CB1.SaveState;
        CB1.SetFillRGB(T, 0.3, 1.0 - T);
        CB1.Rectangle(50 + I * 49, 505, 49, 25);
        CB1.Fill;
        CB1.RestoreState;
      end;

      // Footer rule + page number
      CB1.SaveState;
      CB1.SetLineWidth(0.5);
      CB1.SetStrokeGray(0.6);
      CB1.MoveTo(50, 60);
      CB1.LineTo(545, 60);
      CB1.Stroke;
      CB1.SetFillGray(0.4);
      CB1.BeginText;
      CB1.SetFont('Helvetica', 9);
      CB1.SetTextMatrix(1, 0, 0, 1, 50, 48);
      CB1.ShowText('Generated by Delphi PDF Library - Phase 5 (PDF Writer)');
      CB1.SetTextMatrix(1, 0, 0, 1, 510, 48);
      CB1.ShowText('Page 1');
      CB1.EndText;
      CB1.RestoreState;

      AttachContent(Page1, CB1);
    finally
      CB1.Free;
    end;

    // ----------------------------------------------------------------
    // Page 2: transforms and paths
    // ----------------------------------------------------------------
    Page2 := Builder.AddPage(595, 842);
    AddStdFont(Page2, 'Helvetica',      'Helvetica');
    AddStdFont(Page2, 'Helvetica-Bold', 'Helvetica-Bold');

    CB2 := TPDFContentBuilder.Create;
    try
      // Green header bar + title
      CB2.SaveState;
      CB2.SetFillRGB(0.2, 0.6, 0.4);
      CB2.Rectangle(50, 780, 495, 40);
      CB2.Fill;
      CB2.SetFillRGB(1, 1, 1);
      CB2.BeginText;
      CB2.SetFont('Helvetica-Bold', 18);
      CB2.SetTextMatrix(1, 0, 0, 1, 60, 793);
      CB2.ShowText('Page 2 - Transforms and Paths');
      CB2.EndText;
      CB2.RestoreState;

      // Section: CTM transforms
      CB2.SaveState;
      CB2.SetFillRGB(0, 0, 0);
      CB2.BeginText;
      CB2.SetFont('Helvetica-Bold', 14);
      CB2.SetTextMatrix(1, 0, 0, 1, 50, 745);
      CB2.ShowText('1. CTM Transforms (rotated squares)');
      CB2.EndText;
      CB2.RestoreState;

      for Ang := 0 to 5 do
      begin
        Rad  := Ang * 30 * Pi / 180;
        CosA := Cos(Rad);
        SinA := Sin(Rad);
        OX   := 160 + Ang * 60;
        OY   := 690;
        CB2.SaveState;
        CB2.ConcatMatrix(CosA, SinA, -SinA, CosA, OX, OY);
        CB2.SetFillRGB(Ang * 0.15, 0.5, 1 - Ang * 0.15);
        CB2.SetStrokeRGB(0, 0, 0);
        CB2.SetLineWidth(0.5);
        CB2.Rectangle(-18, -18, 36, 36);
        CB2.FillAndStroke;
        CB2.RestoreState;
      end;

      // Section: Bezier curves
      CB2.SaveState;
      CB2.SetFillRGB(0, 0, 0);
      CB2.BeginText;
      CB2.SetFont('Helvetica-Bold', 14);
      CB2.SetTextMatrix(1, 0, 0, 1, 50, 635);
      CB2.ShowText('2. Bezier Curves');
      CB2.EndText;
      CB2.RestoreState;

      CB2.SaveState;
      CB2.SetLineWidth(2);
      CB2.SetStrokeRGB(0.8, 0.3, 0.1);
      CB2.MoveTo(50, 610);
      CB2.CurveTo(120, 570, 200, 650, 260, 590);
      CB2.CurveTo(320, 530, 380, 620, 450, 580);
      CB2.CurveTo(490, 560, 520, 545, 545, 550);
      CB2.Stroke;
      CB2.RestoreState;

      // Section: line join styles
      CB2.SaveState;
      CB2.SetFillRGB(0, 0, 0);
      CB2.BeginText;
      CB2.SetFont('Helvetica-Bold', 14);
      CB2.SetTextMatrix(1, 0, 0, 1, 50, 520);
      CB2.ShowText('3. Line Join Styles');
      CB2.EndText;
      CB2.RestoreState;

      JoinLabels[0] := 'Miter';
      JoinLabels[1] := 'Round';
      JoinLabels[2] := 'Bevel';
      for J := 0 to 2 do
      begin
        BX := 80 + J * 155;
        CB2.SaveState;
        CB2.SetLineWidth(8);
        CB2.SetLineJoin(J);
        CB2.SetStrokeRGB(0.1, 0.3, 0.7);
        CB2.MoveTo(BX - 20, 475);
        CB2.LineTo(BX, 505);
        CB2.LineTo(BX + 20, 475);
        CB2.Stroke;
        CB2.SetFillRGB(0.3, 0.3, 0.3);
        CB2.BeginText;
        CB2.SetFont('Helvetica', 9);
        CB2.SetTextMatrix(1, 0, 0, 1, BX - 12, 458);
        CB2.ShowText(JoinLabels[J]);
        CB2.EndText;
        CB2.RestoreState;
      end;

      // Footer
      CB2.SaveState;
      CB2.SetLineWidth(0.5);
      CB2.SetStrokeGray(0.6);
      CB2.MoveTo(50, 60);
      CB2.LineTo(545, 60);
      CB2.Stroke;
      CB2.SetFillGray(0.4);
      CB2.BeginText;
      CB2.SetFont('Helvetica', 9);
      CB2.SetTextMatrix(1, 0, 0, 1, 50, 48);
      CB2.ShowText('Generated by Delphi PDF Library - Phase 5 (PDF Writer)');
      CB2.SetTextMatrix(1, 0, 0, 1, 510, 48);
      CB2.ShowText('Page 2');
      CB2.EndText;
      CB2.RestoreState;

      AttachContent(Page2, CB2);
    finally
      CB2.Free;
    end;

    // Save and verify
    Builder.SaveToFile(AOutPath);
    WriteLn('  Saved: ', AOutPath);

    Doc := TPDFDocument.Create;
    try
      Doc.LoadFromFile(AOutPath);
      WriteLn(Format('  Verified: %d pages, title="%s"',
        [Doc.PageCount, Doc.Title]));
    finally
      Doc.Free;
    end;
  finally
    Builder.Free;
  end;
  WriteLn;
end;

// -------------------------------------------------------------------------
// Demo 7: Render pages to PNG using the Skia renderer
// -------------------------------------------------------------------------

procedure DemoRenderPages(const APath: string; const AOutDir: string;
  AMaxPages: Integer = 3; ADPI: Single = 96);
begin
  WriteLn('=== Render to PNG: ', APath, ' ===');
  var Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      var Renderer := TPDFSkiaRenderer.Create(TPDFRenderOptions.Default);
      try
        var PageCount := Min(AMaxPages, Doc.PageCount);
        for var I := 0 to PageCount - 1 do
        begin
          var Page := Doc.Pages[I];
          // Scale page from PDF points to pixels at the requested DPI
          // 1 PDF point = 1/72 inch → at ADPI DPI: pixels = points * DPI / 72
          var Scale  := ADPI / 72.0;
          var W := Round(Page.Width  * Scale);
          var H := Round(Page.Height * Scale);

          var Image := Renderer.RenderPageToImage(Page, W, H);
          if Image = nil then
          begin
            WriteLn(Format('  Page %d: render failed', [I + 1]));
            Continue;
          end;

          var OutName := Format('page_%d.png', [I + 1]);
          if AOutDir <> '' then
            OutName := IncludeTrailingPathDelimiter(AOutDir) + OutName;

          var PNGData := Image.EncodeToFile(OutName, TSkEncodedImageFormat.PNG, 100);
          if PNGData then
            WriteLn(Format('  Page %d: %dx%d → %s', [I + 1, W, H, OutName]))
          else
            WriteLn(Format('  Page %d: failed to save PNG', [I + 1]));
        end;
      finally
        Renderer.Free;
      end;
    except
      on E: Exception do
        WriteLn('ERROR: ', E.Message);
    end;
  finally
    Doc.Free;
  end;
  WriteLn;
end;

// -------------------------------------------------------------------------
// Demo 8: Phase 9 — Metadata, Outline, Annotations, AcroForms
// -------------------------------------------------------------------------

procedure DemoPhase9(const APath: string);
var
  Doc:   TPDFDocument;
  Meta:  TPDFMetadata;
  Outline: TPDFOutline;
  Forms: TPDFAcroForm;
  I:     Integer;
  Annots: TPDFAnnotationList;
  F:     TPDFFormField;
begin
  WriteLn('=== Phase 9 (Metadata/Outline/Annotations/AcroForms): ', APath, ' ===');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);

      // ---- Metadata ----
      Meta := TPDFMetadataLoader.Load(Doc.Trailer, Doc.Catalog, Doc.Resolver);
      try
        WriteLn('--- Metadata ---');
        WriteLn('  Title    : ', Meta.BestTitle);
        WriteLn('  Author   : ', Meta.BestAuthor);
        WriteLn('  Subject  : ', Meta.BestSubject);
        WriteLn('  Keywords : ', Meta.BestKeywords);
        WriteLn('  Creator  : ', Meta.BestCreator);
        WriteLn('  Producer : ', Meta.BestProducer);
        if Meta.Info.HasCreationDate then
          WriteLn('  Created  : ', DateTimeToStr(Meta.Info.CreationDate));
        if Meta.Info.HasModDate then
          WriteLn('  Modified : ', DateTimeToStr(Meta.Info.ModDate));
        if Meta.HasXMP then
          WriteLn('  XMP      : ', Length(Meta.XMP.RawXML), ' bytes');
      finally
        Meta.Free;
      end;
      WriteLn;

      // ---- Outline (bookmarks) ----
      Outline := TPDFOutline.Create;
      try
        Outline.LoadFromCatalog(Doc.Catalog, Doc.Resolver);
        WriteLn('--- Outline ---');
        WriteLn('  Top-level items: ', Outline.Items.Count);
        for I := 0 to Min(4, Outline.Items.Count - 1) do
        begin
          var Item := Outline.Items[I];
          WriteLn(Format('  [%d] %s  (children: %d)',
            [I, Item.Title, Item.Children.Count]));
        end;
      finally
        Outline.Free;
      end;
      WriteLn;

      // ---- Annotations ----
      WriteLn('--- Annotations (first 3 pages) ---');
      for I := 0 to Min(2, Doc.PageCount - 1) do
      begin
        var Page := Doc.Pages[I];
        Annots := TPDFAnnotationLoader.LoadForPage(Page.Dict, I, Doc.Resolver);
        try
          if Annots.Count > 0 then
          begin
            WriteLn(Format('  Page %d: %d annotation(s)', [I + 1, Annots.Count]));
            for var J := 0 to Min(2, Annots.Count - 1) do
            begin
              var A := Annots[J];
              WriteLn(Format('    [%d] %s  contents="%s"',
                [J, A.TypeLabel,
                 IfThen(Length(A.Contents) > 60, A.Contents.Substring(0,60)+'…', A.Contents)]));
            end;
          end;
        finally
          Annots.Free;
        end;
      end;
      WriteLn;

      // ---- AcroForms ----
      Forms := TPDFAcroForm.Create;
      try
        Forms.LoadFromCatalog(Doc.Catalog, Doc.Resolver);
        WriteLn('--- AcroForms ---');
        var Leaves := Forms.LeafFields;
        WriteLn(Format('  Total fields (all): %d   Leaf fields: %d',
          [Forms.Fields.Count, Length(Leaves)]));
        for I := 0 to Min(4, Length(Leaves) - 1) do
        begin
          F := Leaves[I];
          WriteLn(Format('  [%d] "%s"  type=%d  value="%s"',
            [I, F.FullName, Ord(F.FieldType), F.ValueString]));
        end;
      finally
        Forms.Free;
      end;

    except
      on E: Exception do
        WriteLn('ERROR: ', E.Message);
    end;
  finally
    Doc.Free;
  end;
  WriteLn;
end;

// -------------------------------------------------------------------------
// Demo 6: Open an encrypted PDF (with optional password)
// -------------------------------------------------------------------------

procedure DemoEncryptedPDF(const APath: string; const APassword: string = '');
begin
  WriteLn('=== Encrypted PDF: ', APath, ' ===');
  var Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);  // auto-tries empty password
      WriteLn('Encrypted : ', Doc.IsEncrypted);
      if Doc.IsEncrypted then
      begin
        // If empty password did not work, try supplied password
        var Authed := not Doc.IsEncrypted;  // already done by LoadFromFile
        if not Authed and (APassword <> '') then
          Authed := Doc.Authenticate(APassword);
        if not Authed then
          Authed := Doc.Authenticate('');
        if Authed then
          WriteLn('Auth      : SUCCESS')
        else
        begin
          WriteLn('Auth      : FAILED (wrong password)');
          Exit;
        end;
      end;
      WriteLn('Pages     : ', Doc.PageCount);
      WriteLn('Title     : ', Doc.Title);
      for var I := 0 to Min(1, Doc.PageCount - 1) do
      begin
        var Page := Doc.Pages[I];
        WriteLn(Format('  Page %d: %.0f x %.0f pts',
          [I + 1, Page.Width, Page.Height]));
        var Bytes := Page.ContentStreamBytes;
        WriteLn(Format('  Content stream: %d bytes', [Length(Bytes)]));
      end;
    except
      on E: EPDFEncryptionError do
        WriteLn('Encryption error: ', E.Message);
      on E: Exception do
        WriteLn('ERROR: ', E.Message);
    end;
  finally
    Doc.Free;
  end;
  WriteLn;
end;

// -------------------------------------------------------------------------
// Main
// -------------------------------------------------------------------------

begin
  try
    var PDFPath  := '';
    var OutDir   := '';
    var Password := '';
    if ParamCount > 0 then PDFPath  := ParamStr(1);
    if ParamCount > 1 then OutDir   := ParamStr(2);
    if ParamCount > 2 then Password := ParamStr(3);

    if PDFPath = '' then
    begin
      // Try to find any PDF in current directory
      var SR: TSearchRec;
      if FindFirst('*.pdf', faAnyFile, SR) = 0 then
      begin
        PDFPath := SR.Name;
        FindClose(SR);
      end;
    end;

    // Demo 5: always create a PDF from scratch
    var CreatedPDF: string;
    if PDFPath <> '' then
      CreatedPDF := ExtractFilePath(PDFPath) + 'demo_created.pdf'
    else
      CreatedPDF := 'demo_created.pdf';
    DemoCreatePDF(CreatedPDF);

    if PDFPath = '' then
    begin
      WriteLn('Usage: PDFDemo <path_to_pdf> [image_output_dir]');
      WriteLn('No input PDF specified — only creation demo was run.');
    end else
    begin
      DemoEncryptedPDF(PDFPath, Password);
      DemoOpenPDF(PDFPath);
      DemoWalkOperators(PDFPath);
      DemoExtractText(PDFPath, 3);
      DemoExtractImages(PDFPath, OutDir);
      DemoRenderPages(PDFPath, OutDir, 3);
      DemoPhase9(PDFPath);
    end;
  except
    on E: Exception do
    begin
      WriteLn('Fatal: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;

  WriteLn('Done. Press Enter...');
  ReadLn;
end.
