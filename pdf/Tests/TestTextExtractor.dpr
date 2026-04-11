program TestTextExtractor;

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}
{$R *.res}

uses
  System.SysUtils, System.Classes, System.StrUtils, System.Math,
  uPDF.Types        in '..\Src\Core\uPDF.Types.pas',
  uPDF.Errors       in '..\Src\Core\uPDF.Errors.pas',
  uPDF.Objects      in '..\Src\Core\uPDF.Objects.pas',
  uPDF.Lexer        in '..\Src\Core\uPDF.Lexer.pas',
  uPDF.Filters      in '..\Src\Core\uPDF.Filters.pas',
  uPDF.XRef         in '..\Src\Core\uPDF.XRef.pas',
  uPDF.Crypto       in '..\Src\Core\uPDF.Crypto.pas',
  uPDF.Encryption   in '..\Src\Core\uPDF.Encryption.pas',
  uPDF.Parser       in '..\Src\Core\uPDF.Parser.pas',
  uPDF.Document     in '..\Src\Core\uPDF.Document.pas',
  uPDF.GraphicsState in '..\Src\Core\uPDF.GraphicsState.pas',
  uPDF.ColorSpace   in '..\Src\Core\uPDF.ColorSpace.pas',
  uPDF.FontCMap     in '..\Src\Core\uPDF.FontCMap.pas',
  uPDF.Font         in '..\Src\Core\uPDF.Font.pas',
  uPDF.ContentStream in '..\Src\Core\uPDF.ContentStream.pas',
  uPDF.Image        in '..\Src\Core\uPDF.Image.pas',
  uPDF.TextExtractor in '..\Src\Core\uPDF.TextExtractor.pas',
  uPDF.ImageExtractor in '..\Src\Core\uPDF.ImageExtractor.pas',
  uPDF.Writer       in '..\Src\Core\uPDF.Writer.pas',
  uPDF.Outline      in '..\Src\Core\uPDF.Outline.pas',
  uPDF.Annotations  in '..\Src\Core\uPDF.Annotations.pas',
  uPDF.Metadata     in '..\Src\Core\uPDF.Metadata.pas',
  uPDF.AcroForms    in '..\Src\Core\uPDF.AcroForms.pas';

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
  if AReason <> '' then
    WriteLn('  [FAIL] ', AMsg, ' — ', AReason)
  else
    WriteLn('  [FAIL] ', AMsg);
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

// Preview: first N chars, replacing control chars with '.'
function Preview(const S: string; N: Integer = 120): string;
var
  I: Integer;
begin
  Result := S.Substring(0, Min(N, Length(S)));
  for I := 1 to Length(Result) do
    if Ord(Result[I]) < 32 then
      Result[I] := ' ';
  if Length(S) > N then Result := Result + '…';
end;

// =========================================================================
// T01 — Basic extraction: fragments and lines
// =========================================================================

procedure TestBasicExtraction(const APath: string);
var
  Doc:       TPDFDocument;
  Extractor: TPDFTextExtractor;
  PageText:  TPDFPageText;
begin
  Section('T01 — Basic Extraction');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      Check(Doc.PageCount > 0, Format('Document loaded, %d page(s)', [Doc.PageCount]));

      Extractor := TPDFTextExtractor.Create(Doc);
      try
        PageText := Extractor.ExtractPage(0);

        Check(Length(PageText.Fragments) > 0,
          Format('Page 0 has fragments  (got %d)', [Length(PageText.Fragments)]));

        Check(Length(PageText.Lines) > 0,
          Format('Page 0 has lines  (got %d)', [Length(PageText.Lines)]));

      finally
        Extractor.Free;
      end;

    except
      on E: Exception do
        Fail('Basic extraction raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T02 — PlainText content
// =========================================================================

procedure TestPlainText(const APath: string;
  const AMustContain: array of string);
var
  Doc:       TPDFDocument;
  Extractor: TPDFTextExtractor;
  PageText:  TPDFPageText;
  PlainText: string;
  S:         string;
begin
  Section('T02 — PlainText Content');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      Extractor := TPDFTextExtractor.Create(Doc);
      try
        PageText  := Extractor.ExtractPage(0);
        PlainText := PageText.PlainText;

        Check(Length(PlainText) > 10,
          Format('PlainText length > 10  (got %d chars)', [Length(PlainText)]));

        WriteLn('  Preview: "', Preview(PlainText, 200), '"');
        WriteLn;

        // Check expected strings
        for S in AMustContain do
          Check(ContainsText(PlainText, S),
            Format('PlainText contains "%s"', [S]));

        // Sanity: no sequences of 10+ non-printable chars (encoding corruption)
        var BadRun := 0;
        var MaxBadRun := 0;
        for var C in PlainText do
        begin
          if (Ord(C) < 32) and (C <> #10) and (C <> #13) and (C <> #9) then
            Inc(BadRun)
          else
            BadRun := 0;
          if BadRun > MaxBadRun then MaxBadRun := BadRun;
        end;
        Check(MaxBadRun < 10,
          Format('No long runs of non-printable chars  (max run = %d)', [MaxBadRun]));

      finally
        Extractor.Free;
      end;

    except
      on E: Exception do
        Fail('PlainText test raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T03 — Line grouping quality
// =========================================================================

procedure TestLineGrouping(const APath: string);
var
  Doc:       TPDFDocument;
  Extractor: TPDFTextExtractor;
  PageText:  TPDFPageText;
  I:         Integer;
begin
  Section('T03 — Line Grouping');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      Extractor := TPDFTextExtractor.Create(Doc);
      try
        PageText := Extractor.ExtractPage(0);

        Check(Length(PageText.Lines) > 0,
          Format('At least 1 line  (got %d)', [Length(PageText.Lines)]));

        // Each line should have at least 1 fragment
        var EmptyLines := 0;
        for I := 0 to High(PageText.Lines) do
          if Length(PageText.Lines[I].Fragments) = 0 then
            Inc(EmptyLines);

        Check(EmptyLines = 0,
          Format('No empty lines  (%d empty out of %d)', [EmptyLines, Length(PageText.Lines)]));

        // Lines should be in descending Y order (PDF y-axis: top of page = large Y)
        var OutOfOrder := 0;
        for I := 1 to High(PageText.Lines) do
          if PageText.Lines[I].Y > PageText.Lines[I-1].Y + 2 then
            Inc(OutOfOrder);

        Check(OutOfOrder = 0,
          Format('Lines in descending Y order  (%d out-of-order)', [OutOfOrder]));

        // Print first few lines
        WriteLn(Format('  Lines count: %d', [Length(PageText.Lines)]));
        for I := 0 to Min(7, High(PageText.Lines)) do
          WriteLn(Format('  Line[%d] Y=%.1f  "%s"',
            [I, PageText.Lines[I].Y,
             Preview(PageText.Lines[I].Text, 80)]));

      finally
        Extractor.Free;
      end;

    except
      on E: Exception do
        Fail('Line grouping test raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T04 — Fragment positions are inside page bounds
// =========================================================================

procedure TestFragmentPositions(const APath: string);
var
  Doc:       TPDFDocument;
  Extractor: TPDFTextExtractor;
  PageText:  TPDFPageText;
  Page:      TPDFPage;
  OutOfBounds: Integer;
  I:         Integer;
begin
  Section('T04 — Fragment Positions');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      Page := Doc.Pages[0];
      Extractor := TPDFTextExtractor.Create(Doc);
      try
        PageText    := Extractor.ExtractPage(0);
        OutOfBounds := 0;

        for I := 0 to High(PageText.Fragments) do
        begin
          var F := PageText.Fragments[I];
          // X should be within -10..pageWidth+10 (loose, some PDFs have slight overflow)
          // Y should be within -10..pageHeight+10
          if (F.X < -10) or (F.X > Page.Width + 10) or
             (F.Y < -10) or (F.Y > Page.Height + 10) then
            Inc(OutOfBounds);
        end;

        Check(OutOfBounds = 0,
          Format('All fragments within page bounds  (%d out of %d out-of-bounds)',
            [OutOfBounds, Length(PageText.Fragments)]));

        // Font sizes should be positive
        var BadFontSize := 0;
        for I := 0 to High(PageText.Fragments) do
          if PageText.Fragments[I].FontSize <= 0 then
            Inc(BadFontSize);

        Check(BadFontSize = 0,
          Format('All fragments have positive FontSize  (%d bad)', [BadFontSize]));

        WriteLn(Format('  %d fragments checked  page=%.0fx%.0f',
          [Length(PageText.Fragments), Page.Width, Page.Height]));

      finally
        Extractor.Free;
      end;

    except
      on E: Exception do
        Fail('Fragment positions test raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T05 — Multi-page extraction
// =========================================================================

procedure TestMultiPage(const APath: string; AMaxPages: Integer = 5;
  AExpectText: Boolean = True);
var
  Doc:       TPDFDocument;
  Extractor: TPDFTextExtractor;
  I:         Integer;
  TotalFrags: Integer;
  TotalLines: Integer;
begin
  Section('T05 — Multi-page Extraction');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      Extractor := TPDFTextExtractor.Create(Doc);
      try
        TotalFrags := 0;
        TotalLines := 0;
        var PagesToTest := Min(AMaxPages, Doc.PageCount);

        for I := 0 to PagesToTest - 1 do
        begin
          var PT := Extractor.ExtractPage(I);
          Inc(TotalFrags, Length(PT.Fragments));
          Inc(TotalLines, Length(PT.Lines));
          WriteLn(Format('  Page[%d]: %d frags, %d lines',
            [I, Length(PT.Fragments), Length(PT.Lines)]));
        end;

        if AExpectText then
        begin
          Check(TotalFrags > 0,
            Format('Total fragments across %d pages > 0  (got %d)', [PagesToTest, TotalFrags]));
          Check(TotalLines > 0,
            Format('Total lines across %d pages > 0  (got %d)', [PagesToTest, TotalLines]));
        end else
          Check(True, Format('Page traversal completed without crash  (%d pages, %d frags)',
            [PagesToTest, TotalFrags]));

      finally
        Extractor.Free;
      end;

    except
      on E: Exception do
        Fail('Multi-page test raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T06 — Scanned PDF: expect few/zero text fragments (images only)
// =========================================================================

procedure TestScannedPDF(const APath: string);
var
  Doc:       TPDFDocument;
  Extractor: TPDFTextExtractor;
  PageText:  TPDFPageText;
begin
  Section('T06 — Scanned PDF (expect sparse text)');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);
      Check(Doc.PageCount >= 1, Format('Scanned PDF loaded, %d pages', [Doc.PageCount]));

      Extractor := TPDFTextExtractor.Create(Doc);
      try
        PageText := Extractor.ExtractPage(0);

        // Scanned PDFs may have 0 or very few text fragments
        // The important thing is it doesn't crash
        Pass(Format('ExtractPage(0) completed without exception  (%d frags, %d lines)',
          [Length(PageText.Fragments), Length(PageText.Lines)]));

        if Length(PageText.Fragments) = 0 then
          WriteLn('  (no text fragments — expected for scanned PDF)')
        else
          WriteLn(Format('  Found %d text fragments (OCR layer present?)',
            [Length(PageText.Fragments)]));

      finally
        Extractor.Free;
      end;

    except
      on E: Exception do
        Fail('Scanned PDF test raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
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
  WriteLn(' TestTextExtractor — PDF Library Phase 3 Validation');
  WriteLn('======================================================');

  // Primary test PDF: Word-generated, has real text, fonts, 1 page
  TestBasicExtraction(PDF_WORD);
  TestPlainText(PDF_WORD, ['Cuenta', 'Cobro']);
  TestLineGrouping(PDF_WORD);
  TestFragmentPositions(PDF_WORD);
  TestMultiPage(PDF_WORD, 1);

  // Secondary: scanned PDF — should not crash, text may be empty
  TestScannedPDF(PDF_SCAN);

  // Also test multi-page on scanned (exercises page tree traversal, no text expected)
  TestMultiPage(PDF_SCAN, 3, False);

  // ---- Summary ----
  WriteLn;
  WriteLn('======================================================');
  WriteLn(Format(' TOTAL: %d passed,  %d failed', [PassCount, FailCount]));
  WriteLn('======================================================');

  if FailCount > 0 then ExitCode := 1;

  WriteLn('Press Enter...');
  ReadLn;
end.
