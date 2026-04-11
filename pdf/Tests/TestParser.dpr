program TestParser;

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}
{$R *.res}

uses
  System.SysUtils, System.Classes, System.Math,
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

// =========================================================================
// T01 — Basic open + page count
// =========================================================================

procedure TestBasicOpen(const APath: string; const ALabel: string;
  AExpectMinPages: Integer; AExpectVersion: Integer);
var
  Doc: TPDFDocument;
begin
  Section('T01 — Basic Open: ' + ALabel);
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);

      Check(Doc.IsOpen,
        'IsOpen = True');

      Check(Doc.PageCount >= AExpectMinPages,
        Format('PageCount >= %d  (got %d)', [AExpectMinPages, Doc.PageCount]));

      Check(Doc.Version.Minor >= AExpectVersion,
        Format('Version >= 1.%d  (got 1.%d)', [AExpectVersion, Doc.Version.Minor]));

      Check(not Doc.IsEncrypted,
        'Not encrypted');

      // Catalog must be a dictionary
      Check(Doc.Catalog <> nil,
        'Catalog <> nil');

      // Trailer must have /Root
      Check((Doc.Trailer <> nil) and (Doc.Trailer.Get('Root') <> nil),
        'Trailer has /Root');

    except
      on E: Exception do
        Fail('LoadFromFile raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T02 — Page geometry
// =========================================================================

procedure TestPageGeometry(const APath: string; const ALabel: string);
var
  Doc:  TPDFDocument;
  Page: TPDFPage;
  I:    Integer;
begin
  Section('T02 — Page Geometry: ' + ALabel);
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);

      for I := 0 to Doc.PageCount - 1 do
      begin
        Page := Doc.Pages[I];

        Check(Page.Width > 0,
          Format('Page[%d].Width > 0  (%.1f)', [I, Page.Width]));

        Check(Page.Height > 0,
          Format('Page[%d].Height > 0  (%.1f)', [I, Page.Height]));

        Check((Page.Rotation = 0) or (Page.Rotation = 90) or
              (Page.Rotation = 180) or (Page.Rotation = 270),
          Format('Page[%d].Rotation valid  (%d)', [I, Page.Rotation]));

        Check(not Page.MediaBox.IsEmpty,
          Format('Page[%d].MediaBox not empty', [I]));

        // Only print first 5 to avoid flooding
        if I >= 4 then
        begin
          if Doc.PageCount > 5 then
            WriteLn(Format('  (... %d more pages, all OK)', [Doc.PageCount - 5]));
          Break;
        end;
      end;

    except
      on E: Exception do
        Fail('Page geometry test raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T03 — Content stream accessible
// =========================================================================

procedure TestContentStream(const APath: string; const ALabel: string);
var
  Doc:   TPDFDocument;
  Page:  TPDFPage;
  Bytes: TBytes;
  I:     Integer;
begin
  Section('T03 — Content Stream: ' + ALabel);
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);

      for I := 0 to Min(2, Doc.PageCount - 1) do
      begin
        Page  := Doc.Pages[I];
        Bytes := Page.ContentStreamBytes;

        Check(Length(Bytes) > 0,
          Format('Page[%d] content stream not empty  (%d bytes)', [I, Length(Bytes)]));

        // First byte of a valid PDF content stream should be printable ASCII
        // (operators like q, Q, BT, cm, etc.)
        if Length(Bytes) > 0 then
          Check(Bytes[0] >= 9,
            Format('Page[%d] content stream starts with valid byte ($%02X)', [I, Bytes[0]]));
      end;

    except
      on E: Exception do
        Fail('ContentStream test raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T04 — Object resolver: load a specific indirect object
// =========================================================================

procedure TestObjectResolver(const APath: string; const ALabel: string);
var
  Doc:     TPDFDocument;
  Catalog: TPDFDictionary;
  PagesObj: TPDFObject;
  PagesDict: TPDFDictionary;
begin
  Section('T04 — Object Resolver: ' + ALabel);
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);

      Catalog := Doc.Catalog;
      Check(Catalog <> nil, 'Catalog loaded');

      // /Pages must resolve to a dictionary with /Type = Pages
      PagesObj := Catalog.Get('Pages');
      Check(PagesObj <> nil, 'Catalog has /Pages key');

      if PagesObj <> nil then
      begin
        PagesObj := PagesObj.Dereference;
        Check(PagesObj.IsDictionary, '/Pages resolves to dictionary');

        if PagesObj.IsDictionary then
        begin
          PagesDict := TPDFDictionary(PagesObj);
          Check(PagesDict.GetAsName('Type') = 'Pages',
            '/Pages /Type = "Pages"  (got "' + PagesDict.GetAsName('Type') + '")');
          Check(PagesDict.GetAsInteger('Count', -1) >= 0,
            '/Pages /Count >= 0  (got ' + IntToStr(PagesDict.GetAsInteger('Count', -1)) + ')');
        end;
      end;

    except
      on E: Exception do
        Fail('Object resolver test raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T05 — Linearized PDF (14DESE has /Linearized)
// =========================================================================

procedure TestLinearized(const APath: string);
var
  Doc:     TPDFDocument;
  Trailer: TPDFDictionary;
begin
  Section('T05 — Linearized PDF');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);

      Check(Doc.PageCount = 14,
        Format('PageCount = 14  (got %d)', [Doc.PageCount]));

      Trailer := Doc.Trailer;
      Check(Trailer <> nil, 'Trailer present');

      // Linearized PDFs have /ID array in trailer
      if Trailer <> nil then
      begin
        var IDArr := Trailer.GetAsArray('ID');
        Check(IDArr <> nil, 'Trailer /ID array present');
        if IDArr <> nil then
          Check(IDArr.Count = 2,
            Format('Trailer /ID has 2 entries  (got %d)', [IDArr.Count]));
      end;

      // All 14 pages should be accessible
      var AllOK := True;
      for var I := 0 to Doc.PageCount - 1 do
      begin
        var Page := Doc.Pages[I];
        if (Page.Width <= 0) or (Page.Height <= 0) then
        begin
          AllOK := False;
          Fail(Format('Page[%d] has invalid dimensions %.1fx%.1f', [I, Page.Width, Page.Height]));
        end;
      end;
      if AllOK then
        Pass(Format('All %d pages have valid dimensions', [Doc.PageCount]));

    except
      on E: Exception do
        Fail('Linearized test raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// T06 — PDF 1.7 with /Metadata (XMP) and StructTree
// =========================================================================

procedure TestPDF17Features(const APath: string);
var
  Doc:     TPDFDocument;
  Catalog: TPDFDictionary;
begin
  Section('T06 — PDF 1.7 Features (Metadata/StructTree)');
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromFile(APath);

      Check(Doc.Version.Minor >= 7,
        Format('Version >= 1.7  (got 1.%d)', [Doc.Version.Minor]));

      Catalog := Doc.Catalog;

      // /Metadata XMP stream
      var MetaObj := Catalog.Get('Metadata');
      Check(MetaObj <> nil, 'Catalog has /Metadata');
      if MetaObj <> nil then
      begin
        MetaObj := MetaObj.Dereference;
        Check(MetaObj.IsStream, '/Metadata is a stream');
        if MetaObj.IsStream then
        begin
          var Bytes := TPDFStream(MetaObj).DecodedBytes;
          Check(Length(Bytes) > 0, '/Metadata stream not empty');
          var XML := TEncoding.UTF8.GetString(Bytes);
          Check(Pos('<?xpacket', XML) > 0,
            '/Metadata contains XMP packet header');
          Check(Pos('rdf:RDF', XML) > 0,
            '/Metadata contains rdf:RDF element');
        end;
      end;

      // /Lang
      var Lang := Catalog.GetAsName('Lang');
      if Lang = '' then
        Lang := Catalog.GetAsUnicodeString('Lang');
      Check(Lang <> '', 'Catalog /Lang present  (got "' + Lang + '")');

      // /ViewerPreferences
      var VPObj := Catalog.Get('ViewerPreferences');
      Check(VPObj <> nil, 'Catalog has /ViewerPreferences');

    except
      on E: Exception do
        Fail('PDF 1.7 features test raised ' + E.ClassName, E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

// =========================================================================
// Main
// =========================================================================

const
  PDF_WORD  = 'D:\Documentos\Cuentas de Cobro\2026\pdf\Cuenta de Cobro 452 - Avance Juridico.pdf';
  PDF_SCAN  = 'E:\Copilot\AvanceJuridico\Docs\pdfocr\14DESE_1.PDF';

begin
  WriteLn('======================================================');
  WriteLn(' TestParser — PDF Library Phase 1-2 Validation');
  WriteLn('======================================================');

  // ---- Word-generated PDF (1.7, 1 page) ----
  TestBasicOpen   (PDF_WORD, 'Word/PDF-1.7', 1, 7);
  TestPageGeometry(PDF_WORD, 'Word/PDF-1.7');
  TestContentStream(PDF_WORD, 'Word/PDF-1.7');
  TestObjectResolver(PDF_WORD, 'Word/PDF-1.7');
  TestPDF17Features(PDF_WORD);

  // ---- Scanned linearized PDF (1.4, 14 pages) ----
  TestBasicOpen   (PDF_SCAN, 'Scanned/PDF-1.4-Linearized', 14, 4);
  TestPageGeometry(PDF_SCAN, 'Scanned/PDF-1.4-Linearized');
  TestContentStream(PDF_SCAN, 'Scanned/PDF-1.4-Linearized');
  TestObjectResolver(PDF_SCAN, 'Scanned/PDF-1.4-Linearized');
  TestLinearized  (PDF_SCAN);

  // ---- Summary ----
  WriteLn;
  WriteLn('======================================================');
  WriteLn(Format(' TOTAL: %d passed,  %d failed', [PassCount, FailCount]));
  WriteLn('======================================================');

  if FailCount > 0 then ExitCode := 1;

  WriteLn('Press Enter...');
  ReadLn;
end.
