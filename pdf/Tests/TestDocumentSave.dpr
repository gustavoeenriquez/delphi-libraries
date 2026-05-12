program TestDocumentSave;
// Tests TPDFDocument.SaveToStream / SaveToFile  (Phase 5)
// Strategy: build fixture PDFs in memory with TPDFBuilder, then exercise
// the TPDFDocument load  modify  save  reload cycle.
// No external PDF files required.

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}
{$R *.res}

uses
  System.SysUtils, System.Classes, System.StrUtils, System.Math,
  System.IOUtils, System.NetEncoding,
  uPDF.Types          in '..\Src\Core\uPDF.Types.pas',
  uPDF.Errors         in '..\Src\Core\uPDF.Errors.pas',
  uPDF.Objects        in '..\Src\Core\uPDF.Objects.pas',
  uPDF.Lexer          in '..\Src\Core\uPDF.Lexer.pas',
  uPDF.Filters        in '..\Src\Core\uPDF.Filters.pas',
  uPDF.XRef           in '..\Src\Core\uPDF.XRef.pas',
  uPDF.Crypto         in '..\Src\Core\uPDF.Crypto.pas',
  uPDF.Encryption     in '..\Src\Core\uPDF.Encryption.pas',
  uPDF.Parser         in '..\Src\Core\uPDF.Parser.pas',
  uPDF.Document       in '..\Src\Core\uPDF.Document.pas',
  uPDF.GraphicsState  in '..\Src\Core\uPDF.GraphicsState.pas',
  uPDF.ColorSpace     in '..\Src\Core\uPDF.ColorSpace.pas',
  uPDF.FontCMap       in '..\Src\Core\uPDF.FontCMap.pas',
  uPDF.Font           in '..\Src\Core\uPDF.Font.pas',
  uPDF.ContentStream  in '..\Src\Core\uPDF.ContentStream.pas',
  uPDF.Image          in '..\Src\Core\uPDF.Image.pas',
  uPDF.TextExtractor  in '..\Src\Core\uPDF.TextExtractor.pas',
  uPDF.ImageExtractor in '..\Src\Core\uPDF.ImageExtractor.pas',
  uPDF.Writer         in '..\Src\Core\uPDF.Writer.pas',
  uPDF.Outline        in '..\Src\Core\uPDF.Outline.pas',
  uPDF.Annotations    in '..\Src\Core\uPDF.Annotations.pas',
  uPDF.Metadata       in '..\Src\Core\uPDF.Metadata.pas',
  uPDF.AcroForms      in '..\Src\Core\uPDF.AcroForms.pas',
  uPDF.PageOperations in '..\Src\Core\uPDF.PageOperations.pas',
  uPDF.PageCopy       in '..\Src\Core\uPDF.PageCopy.pas',
  uPDF.TOC            in '..\Src\Core\uPDF.TOC.pas';

// =========================================================================
// Helpers
// =========================================================================

var
  PassCount: Integer = 0;
  FailCount: Integer = 0;
  OutDir:    string;

procedure Pass(const AMsg: string);
begin
  Inc(PassCount);
  WriteLn('  [PASS] ', AMsg);
end;

procedure Fail(const AMsg: string; const AReason: string = '');
begin
  Inc(FailCount);
  if AReason <> '' then WriteLn('  [FAIL] ', AMsg, ' -- ', AReason)
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

// Add a standard Type1 font to a page dict's /Resources/Font sub-dict
procedure AddStdFont(APageDict: TPDFDictionary;
  const AResName, ABaseName: string);
var
  ResDict, FontDict, FD: TPDFDictionary;
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

// Build a multi-page fixture PDF using TPDFBuilder and return as bytes.
// Each page carries a text label "Page N" at a standard position.
function MakeFixturePDF(APageCount: Integer): TBytes;
var
  Builder: TPDFBuilder;
  Stm:     TBytesStream;
  I:       Integer;
  Page:    TPDFDictionary;
  CB:      TPDFContentBuilder;
  Content: TPDFStream;
begin
  Builder := TPDFBuilder.Create;
  try
    for I := 0 to APageCount - 1 do
    begin
      Page := Builder.AddPage(595, 841);  // A4 portrait
      AddStdFont(Page, 'F1', 'Helvetica');
      CB := TPDFContentBuilder.Create;
      try
        CB.BeginText;
        CB.SetFont('F1', 14);
        CB.SetTextMatrix(1, 0, 0, 1, 50, 780);
        CB.ShowText(Format('Page %d of %d', [I + 1, APageCount]));
        CB.EndText;
        Content := TPDFStream.Create;
        Content.SetRawData(CB.Build);
        Page.SetValue('Contents', Content);
      finally
        CB.Free;
      end;
    end;
    Stm := TBytesStream.Create;
    try
      Builder.SaveToStream(Stm);
      Result := Copy(Stm.Bytes, 0, Stm.Size);
    finally
      Stm.Free;
    end;
  finally
    Builder.Free;
  end;
end;

// Load FixtureBytes into a fresh TPDFDocument and save via SaveToStream.
// Returns the re-saved bytes.  Caller frees nothing extra.
function RoundTrip(const AFixture: TBytes): TBytes;
var
  Doc: TPDFDocument;
  Src: TBytesStream;
  Out: TBytesStream;
begin
  Src := TBytesStream.Create(AFixture);
  Out := TBytesStream.Create;
  Doc := TPDFDocument.Create;
  try
    Doc.LoadFromStream(Src);
    Doc.SaveToStream(Out);
    Result := Copy(Out.Bytes, 0, Out.Size);
  finally
    Doc.Free;
    Out.Free;
    Src.Free;
  end;
end;

// Open bytes as a TPDFDocument, run AProc(Doc), free Doc.
procedure WithDoc(const ABytes: TBytes;
  AProc: TProc<TPDFDocument>);
var
  Stm: TBytesStream;
  Doc: TPDFDocument;
begin
  Stm := TBytesStream.Create(ABytes);
  Doc := TPDFDocument.Create;
  try
    Doc.LoadFromStream(Stm);
    AProc(Doc);
  finally
    Doc.Free;
    Stm.Free;
  end;
end;

// =========================================================================
// T01 -- Round-trip fidelity: page count and geometry preserved
// =========================================================================

procedure TestRoundTripFidelity;
var
  Fix, Rt: TBytes;
begin
  Section('T01 -- Round-trip fidelity (3 pages)');
  try
    Fix := MakeFixturePDF(3);
    Check(Length(Fix) > 200, 'Fixture PDF created');

    Rt := RoundTrip(Fix);
    Check(Length(Rt) > 200, 'Round-trip output non-empty');

    WithDoc(Rt,
      procedure(Doc: TPDFDocument)
      var
        P: TPDFPage;
      begin
        Check(Doc.PageCount = 3,
          Format('PageCount = 3  (got %d)', [Doc.PageCount]));
        if Doc.PageCount >= 1 then
        begin
          P := Doc.Pages[0];
          Check(Abs(P.Width  - 595) < 1,
            Format('Page 0 width  ~= 595  (got %.1f)', [P.Width]));
          Check(Abs(P.Height - 841) < 1,
            Format('Page 0 height ~= 841  (got %.1f)', [P.Height]));
        end;
        if Doc.PageCount >= 3 then
        begin
          P := Doc.Pages[2];
          Check(Abs(P.Width  - 595) < 1,
            Format('Page 2 width  ~= 595  (got %.1f)', [P.Width]));
        end;
      end);
  except
    on E: Exception do
      Fail('Unhandled exception', E.ClassName + ': ' + E.Message);
  end;
end;

// =========================================================================
// T02 -- Content streams survive round-trip (non-empty after reload)
// =========================================================================

procedure TestContentPreserved;
var
  Fix, Rt: TBytes;
begin
  Section('T02 -- Content streams survive round-trip');
  try
    Fix := MakeFixturePDF(2);
    Rt  := RoundTrip(Fix);

    WithDoc(Rt,
      procedure(Doc: TPDFDocument)
      var
        Bytes: TBytes;
      begin
        if Doc.PageCount < 1 then begin Fail('No pages after round-trip'); Exit; end;
        Bytes := Doc.Pages[0].ContentStreamBytes;
        Check(Length(Bytes) > 10,
          Format('Page 0 content stream non-empty  (got %d bytes)',
            [Length(Bytes)]));
        if Doc.PageCount >= 2 then
        begin
          Bytes := Doc.Pages[1].ContentStreamBytes;
          Check(Length(Bytes) > 10,
            Format('Page 1 content stream non-empty  (got %d bytes)',
              [Length(Bytes)]));
        end;
      end);
  except
    on E: Exception do
      Fail('Unhandled exception', E.ClassName + ': ' + E.Message);
  end;
end;

// =========================================================================
// T03 -- RotatePages: modifications in FPages.FDict survive save/reload
// =========================================================================

procedure TestRotatePages;
var
  Fix:  TBytes;
  Stm:  TBytesStream;
  Out:  TBytesStream;
  Doc:  TPDFDocument;
  Rt:   TBytes;
begin
  Section('T03 -- RotatePages 90 degrees');
  try
    Fix := MakeFixturePDF(2);
    Stm := TBytesStream.Create(Fix);
    Out := TBytesStream.Create;
    Doc := TPDFDocument.Create;
    try
      Doc.LoadFromStream(Stm);
      TPDFPageOperations.RotatePages(Doc, 90, nil);
      Doc.SaveToStream(Out);
      Rt := Copy(Out.Bytes, 0, Out.Size);
    finally
      Doc.Free;
      Out.Free;
      Stm.Free;
    end;

    WithDoc(Rt,
      procedure(Doc2: TPDFDocument)
      begin
        Check(Doc2.PageCount = 2,
          Format('PageCount = 2 after rotate  (got %d)', [Doc2.PageCount]));
        if Doc2.PageCount >= 1 then
          Check(Doc2.Pages[0].Rotation = 90,
            Format('Page 0 Rotation = 90  (got %d)', [Doc2.Pages[0].Rotation]));
        if Doc2.PageCount >= 2 then
          Check(Doc2.Pages[1].Rotation = 90,
            Format('Page 1 Rotation = 90  (got %d)', [Doc2.Pages[1].Rotation]));
      end);
  except
    on E: Exception do
      Fail('Unhandled exception', E.ClassName + ': ' + E.Message);
  end;
end;

// =========================================================================
// T04 -- RemovePage: page count decreases after save/reload
// =========================================================================

procedure TestRemovePage;
var
  Fix:  TBytes;
  Stm:  TBytesStream;
  Out:  TBytesStream;
  Doc:  TPDFDocument;
  Rt:   TBytes;
begin
  Section('T04 -- RemovePage (remove index 1 from 3-page doc)');
  try
    Fix := MakeFixturePDF(3);
    Stm := TBytesStream.Create(Fix);
    Out := TBytesStream.Create;
    Doc := TPDFDocument.Create;
    try
      Doc.LoadFromStream(Stm);
      Check(Doc.PageCount = 3, 'Fixture has 3 pages');
      Doc.RemovePage(1);   // remove middle page
      Check(Doc.PageCount = 2, 'PageCount = 2 after RemovePage');
      Doc.SaveToStream(Out);
      Rt := Copy(Out.Bytes, 0, Out.Size);
    finally
      Doc.Free;
      Out.Free;
      Stm.Free;
    end;

    WithDoc(Rt,
      procedure(Doc2: TPDFDocument)
      begin
        Check(Doc2.PageCount = 2,
          Format('Reloaded PageCount = 2  (got %d)', [Doc2.PageCount]));
      end);
  except
    on E: Exception do
      Fail('Unhandled exception', E.ClassName + ': ' + E.Message);
  end;
end;

// =========================================================================
// T05 -- AddPage: blank page appended to parsed doc survives save/reload
// =========================================================================

procedure TestAddPage;
var
  Fix:  TBytes;
  Stm:  TBytesStream;
  Out:  TBytesStream;
  Doc:  TPDFDocument;
  Rt:   TBytes;
begin
  Section('T05 -- AddPage (append blank to 3-page doc)');
  try
    Fix := MakeFixturePDF(3);
    Stm := TBytesStream.Create(Fix);
    Out := TBytesStream.Create;
    Doc := TPDFDocument.Create;
    try
      Doc.LoadFromStream(Stm);
      Doc.AddPage(595, 841);
      Check(Doc.PageCount = 4, 'PageCount = 4 after AddPage');
      Doc.SaveToStream(Out);
      Rt := Copy(Out.Bytes, 0, Out.Size);
    finally
      Doc.Free;
      Out.Free;
      Stm.Free;
    end;

    WithDoc(Rt,
      procedure(Doc2: TPDFDocument)
      var P: TPDFPage;
      begin
        Check(Doc2.PageCount = 4,
          Format('Reloaded PageCount = 4  (got %d)', [Doc2.PageCount]));
        if Doc2.PageCount >= 4 then
        begin
          P := Doc2.Pages[3];
          Check(Abs(P.Width  - 595) < 1,
            Format('New page width  ~= 595  (got %.1f)', [P.Width]));
          Check(Abs(P.Height - 841) < 1,
            Format('New page height ~= 841  (got %.1f)', [P.Height]));
        end;
      end);
  except
    on E: Exception do
      Fail('Unhandled exception', E.ClassName + ': ' + E.Message);
  end;
end;

// =========================================================================
// T06 -- From-scratch: TPDFDocument.Create + AddPage + SaveToStream
// =========================================================================

procedure TestFromScratch;
var
  Out: TBytesStream;
  Doc: TPDFDocument;
  Rt:  TBytes;
begin
  Section('T06 -- From-scratch save (no parser, 2 blank pages)');
  try
    Out := TBytesStream.Create;
    Doc := TPDFDocument.Create;
    try
      Doc.AddPage(612, 792);   // US Letter
      Doc.AddPage(595, 841);   // A4
      Check(Doc.PageCount = 2, 'PageCount = 2 before save');
      Doc.SaveToStream(Out);
      Rt := Copy(Out.Bytes, 0, Out.Size);
    finally
      Doc.Free;
      Out.Free;
    end;

    Check(Length(Rt) > 100, 'From-scratch output non-empty');

    WithDoc(Rt,
      procedure(Doc2: TPDFDocument)
      var P: TPDFPage;
      begin
        Check(Doc2.PageCount = 2,
          Format('Reloaded PageCount = 2  (got %d)', [Doc2.PageCount]));
        if Doc2.PageCount >= 1 then
        begin
          P := Doc2.Pages[0];
          Check(Abs(P.Width  - 612) < 1,
            Format('Page 0 width  ~= 612  (got %.1f)', [P.Width]));
          Check(Abs(P.Height - 792) < 1,
            Format('Page 0 height ~= 792  (got %.1f)', [P.Height]));
        end;
        if Doc2.PageCount >= 2 then
        begin
          P := Doc2.Pages[1];
          Check(Abs(P.Width  - 595) < 1,
            Format('Page 1 width  ~= 595  (got %.1f)', [P.Width]));
        end;
      end);
  except
    on E: Exception do
      Fail('Unhandled exception', E.ClassName + ': ' + E.Message);
  end;
end;

// =========================================================================
// T07 -- SaveToFile round-trip (file path variant)
// =========================================================================

procedure TestSaveToFile;
var
  Fix:     TBytes;
  SrcFile: string;
  OutFile: string;
  Stm:     TBytesStream;
  Doc:     TPDFDocument;
begin
  Section('T07 -- SaveToFile round-trip');
  SrcFile := TPath.Combine(OutDir, 'doc_save_src.pdf');
  OutFile := TPath.Combine(OutDir, 'doc_save_out.pdf');
  try
    // Write fixture to disk first
    Fix := MakeFixturePDF(2);
    TFile.WriteAllBytes(SrcFile, Fix);
    Check(FileExists(SrcFile), 'Source fixture written to disk');

    // Load from file, save to different file
    Doc := TPDFDocument.Create;
    try
      Doc.LoadFromFile(SrcFile);
      Doc.SaveToFile(OutFile);
    finally
      Doc.Free;
    end;
    Check(FileExists(OutFile), 'Output file created');
    Check(TFile.GetSize(OutFile) > 200,
      Format('Output file size > 200  (got %d)', [TFile.GetSize(OutFile)]));

    // Reload from output file
    Doc := TPDFDocument.Create;
    try
      Doc.LoadFromFile(OutFile);
      Check(Doc.PageCount = 2,
        Format('Reloaded PageCount = 2  (got %d)', [Doc.PageCount]));
    finally
      Doc.Free;
    end;
  except
    on E: Exception do
      Fail('Unhandled exception', E.ClassName + ': ' + E.Message);
  end;
end;

// =========================================================================
// T08 -- Error cases: Incremental mode raises EPDFNotSupportedError
// =========================================================================

procedure TestErrorCases;
var
  Fix: TBytes;
  Stm: TBytesStream;
  Out: TBytesStream;
  Doc: TPDFDocument;
  Got: Boolean;
begin
  Section('T08 -- Error cases');
  try
    Fix := MakeFixturePDF(1);
    Stm := TBytesStream.Create(Fix);
    Out := TBytesStream.Create;
    Doc := TPDFDocument.Create;
    try
      Doc.LoadFromStream(Stm);
      Got := False;
      try
        Doc.SaveToStream(Out, TPDFSaveMode.Incremental);
      except
        on E: EPDFNotSupportedError do
          Got := True;
        on E: Exception do
          Fail('Incremental mode raised wrong exception type', E.ClassName);
      end;
      Check(Got, 'Incremental mode raises EPDFNotSupportedError');
    finally
      Doc.Free;
      Out.Free;
      Stm.Free;
    end;
  except
    on E: Exception do
      Fail('Unhandled exception', E.ClassName + ': ' + E.Message);
  end;
end;

// =========================================================================
// T09 -- Metadata setters on from-scratch document survive save/reload
// =========================================================================

procedure TestMetadataFromScratch;
var
  Out: TBytesStream;
  Doc: TPDFDocument;
  Rt:  TBytes;
begin
  Section('T09 -- Metadata setters (from-scratch document)');
  try
    Out := TBytesStream.Create;
    Doc := TPDFDocument.Create;
    try
      // Check defaults are empty before any setter
      Check(Doc.Title    = '', 'Title empty before setter');
      Check(Doc.Author   = '', 'Author empty before setter');
      Check(Doc.Subject  = '', 'Subject empty before setter');
      Check(Doc.Creator  = '', 'Creator empty before setter');
      Check(Doc.Producer = '', 'Producer empty before setter');

      Doc.AddPage(595, 841);
      Doc.Title    := 'My Title';
      Doc.Author   := 'My Author';
      Doc.Subject  := 'My Subject';
      Doc.Creator  := 'My Creator';
      Doc.Producer := 'My Producer';

      // Getters visible immediately after setting
      Check(Doc.Title    = 'My Title',    Format('Title set  (got "%s")',    [Doc.Title]));
      Check(Doc.Author   = 'My Author',   Format('Author set  (got "%s")',   [Doc.Author]));
      Check(Doc.Subject  = 'My Subject',  Format('Subject set  (got "%s")',  [Doc.Subject]));
      Check(Doc.Creator  = 'My Creator',  Format('Creator set  (got "%s")',  [Doc.Creator]));
      Check(Doc.Producer = 'My Producer', Format('Producer set  (got "%s")', [Doc.Producer]));

      Doc.SaveToStream(Out);
      Rt := Copy(Out.Bytes, 0, Out.Size);
    finally
      Doc.Free;
      Out.Free;
    end;

    WithDoc(Rt,
      procedure(Doc2: TPDFDocument)
      begin
        Check(Doc2.Title    = 'My Title',    Format('Reloaded Title    (got "%s")', [Doc2.Title]));
        Check(Doc2.Author   = 'My Author',   Format('Reloaded Author   (got "%s")', [Doc2.Author]));
        Check(Doc2.Subject  = 'My Subject',  Format('Reloaded Subject  (got "%s")', [Doc2.Subject]));
        Check(Doc2.Creator  = 'My Creator',  Format('Reloaded Creator  (got "%s")', [Doc2.Creator]));
        Check(Doc2.Producer = 'My Producer', Format('Reloaded Producer (got "%s")', [Doc2.Producer]));
      end);
  except
    on E: Exception do
      Fail('Unhandled exception', E.ClassName + ': ' + E.Message);
  end;
end;

// =========================================================================
// T10 -- Metadata setters on a loaded (parsed) document survive save/reload
// =========================================================================

procedure TestMetadataOnLoadedDoc;
var
  Fix:  TBytes;
  Stm:  TBytesStream;
  Out:  TBytesStream;
  Doc:  TPDFDocument;
  Rt:   TBytes;
begin
  Section('T10 -- Metadata setters (loaded document)');
  try
    Fix := MakeFixturePDF(2);
    Stm := TBytesStream.Create(Fix);
    Out := TBytesStream.Create;
    Doc := TPDFDocument.Create;
    try
      Doc.LoadFromStream(Stm);
      Doc.Title    := 'Loaded Title';
      Doc.Author   := 'Loaded Author';
      Doc.Subject  := 'Loaded Subject';
      Doc.Creator  := 'Loaded Creator';
      Doc.Producer := 'Loaded Producer';
      Doc.SaveToStream(Out);
      Rt := Copy(Out.Bytes, 0, Out.Size);
    finally
      Doc.Free;
      Out.Free;
      Stm.Free;
    end;

    WithDoc(Rt,
      procedure(Doc2: TPDFDocument)
      begin
        Check(Doc2.Title    = 'Loaded Title',    Format('Reloaded Title    (got "%s")', [Doc2.Title]));
        Check(Doc2.Author   = 'Loaded Author',   Format('Reloaded Author   (got "%s")', [Doc2.Author]));
        Check(Doc2.Subject  = 'Loaded Subject',  Format('Reloaded Subject  (got "%s")', [Doc2.Subject]));
        Check(Doc2.Creator  = 'Loaded Creator',  Format('Reloaded Creator  (got "%s")', [Doc2.Creator]));
        Check(Doc2.Producer = 'Loaded Producer', Format('Reloaded Producer (got "%s")', [Doc2.Producer]));
      end);
  except
    on E: Exception do
      Fail('Unhandled exception', E.ClassName + ': ' + E.Message);
  end;
end;

// =========================================================================
// T11 -- Unicode metadata (non-ASCII characters) round-trips correctly
// =========================================================================

procedure TestMetadataUnicode;
var
  Out: TBytesStream;
  Doc: TPDFDocument;
  Rt:  TBytes;
begin
  Section('T11 -- Unicode metadata round-trip');
  try
    Out := TBytesStream.Create;
    Doc := TPDFDocument.Create;
    try
      Doc.AddPage(595, 841);
      Doc.Title  := 'Gu' + #$00E9 + 'nther M' + #$00FC + 'ller';  // Günther Müller
      Doc.Author := #$00C9 + 'l' + #$00E8 + 've';                  // Élève
      Doc.SaveToStream(Out);
      Rt := Copy(Out.Bytes, 0, Out.Size);
    finally
      Doc.Free;
      Out.Free;
    end;

    WithDoc(Rt,
      procedure(Doc2: TPDFDocument)
      begin
        Check(Doc2.Title  = 'Gu' + #$00E9 + 'nther M' + #$00FC + 'ller',
          Format('Unicode Title round-trips  (got "%s")', [Doc2.Title]));
        Check(Doc2.Author = #$00C9 + 'l' + #$00E8 + 've',
          Format('Unicode Author round-trips  (got "%s")', [Doc2.Author]));
      end);
  except
    on E: Exception do
      Fail('Unhandled exception', E.ClassName + ': ' + E.Message);
  end;
end;

// =========================================================================
// T12 -- LZW encode / decode round-trip
// =========================================================================

procedure TestLZWRoundTrip;
var
  Filter:    TPDFLZWFilter;
  Src, Enc, Dec: TBytesStream;

  function RoundTrip(const AInput: TBytes): TBytes;
  begin
    Src := TBytesStream.Create(AInput);
    Enc := TBytesStream.Create;
    Dec := TBytesStream.Create;
    try
      Filter.Encode(Src, Enc, nil);
      Enc.Position := 0;
      Filter.Decode(Enc, Dec, nil);
      Result := Copy(Dec.Bytes, 0, Dec.Size);
    finally
      Dec.Free; Enc.Free; Src.Free;
    end;
  end;

  function BytesEqual(const A, B: TBytes): Boolean;
  var I: Integer;
  begin
    if Length(A) <> Length(B) then Exit(False);
    for I := 0 to High(A) do
      if A[I] <> B[I] then Exit(False);
    Result := True;
  end;

var
  Input, Got: TBytes;
  I:          Integer;
begin
  Section('T12 -- LZW encode / decode round-trip');
  Filter := TPDFLZWFilter.Create;
  try
    // --- T12.1: empty input ---
    Input := nil;
    Got   := RoundTrip(Input);
    Check(Length(Got) = 0, 'LZW empty input round-trips');

    // --- T12.2: single byte ---
    SetLength(Input, 1); Input[0] := $41;
    Got := RoundTrip(Input);
    Check(BytesEqual(Got, Input), 'LZW single byte round-trips');

    // --- T12.3: short ASCII text ---
    Input := TEncoding.ASCII.GetBytes('Hello, PDF World!');
    Got   := RoundTrip(Input);
    Check(BytesEqual(Got, Input), 'LZW ASCII text round-trips');

    // --- T12.4: repetitive data (should compress well and exercise table growth) ---
    SetLength(Input, 1024);
    for I := 0 to High(Input) do Input[I] := I mod 16;
    Got := RoundTrip(Input);
    Check(BytesEqual(Got, Input), 'LZW repetitive 1024 bytes round-trips');

    // Verify compression actually happened
    Src := TBytesStream.Create(Input);
    Enc := TBytesStream.Create;
    try
      Filter.Encode(Src, Enc, nil);
      Check(Enc.Size < Length(Input),
        Format('LZW compresses repetitive data  (%d → %d bytes)', [Length(Input), Enc.Size]));
    finally
      Enc.Free; Src.Free;
    end;

    // --- T12.5: all 256 byte values (binary data) ---
    SetLength(Input, 256);
    for I := 0 to 255 do Input[I] := I;
    Got := RoundTrip(Input);
    Check(BytesEqual(Got, Input), 'LZW all 256 byte values round-trip');

    // --- T12.6: large repetitive data (forces table-full + CLEAR reset) ---
    SetLength(Input, 8192);
    for I := 0 to High(Input) do Input[I] := Byte(I * 7 mod 31);
    Got := RoundTrip(Input);
    Check(BytesEqual(Got, Input), 'LZW 8 KB round-trips (exercises table-full reset)');

  except
    on E: Exception do
      Fail('Unhandled exception', E.ClassName + ': ' + E.Message);
  end;
  Filter.Free;
end;

// =========================================================================
// T13 -- Full rewrite of encrypted document: save + reload succeeds
//
// Fixture: a 2-page RC4-128bit PDF with empty user password, page 0 has
// a content stream, page 1 is blank.  Generated with pypdf.
// =========================================================================

// Fixture: 2-page RC4-128 encrypted PDF, empty user password.
// Page 0: 595×841, has a content stream.  Page 1: 612×792, blank.
const
  EncryptedFixtureB64 =
    'JVBERi0xLjMKJeLjz9MKMSAwIG9iago8PAovUHJvZHVjZXIgPDU4MTI2YjgwMTQ+Cj4+CmVu' +
    'ZG9iagoyIDAgb2JqCjw8Ci9UeXBlIC9QYWdlcwovQ291bnQgMgovS2lkcyBbIDQgMCBSIDYg' +
    'MCBSIF0KPj4KZW5kb2JqCjMgMCBvYmoKPDwKL1R5cGUgL0NhdGFsb2cKL1BhZ2VzIDIgMCBS' +
    'Cj4+CmVuZG9iago0IDAgb2JqCjw8Ci9UeXBlIC9QYWdlCi9SZXNvdXJjZXMgPDwKPj4KL01l' +
    'ZGlhQm94IFsgMC4wIDAuMCA1OTUgODQxIF0KL1BhcmVudCAyIDAgUgovQ29udGVudHMgNSAw' +
    'IFIKPj4KZW5kb2JqCjUgMCBvYmoKPDwKL0xlbmd0aCA0Mgo+PgpzdHJlYW0KoK/FbDYSFWdR' +
    'RZuj0f7n1E9iAl9fYr79b2jhG6s2Gqu7KEOmkDefX9f6CmVuZHN0cmVhbQplbmRvYmoKNiAw' +
    'IG9iago8PAovVHlwZSAvUGFnZQovUmVzb3VyY2VzIDw8Cj4+Ci9NZWRpYUJveCBbIDAuMCAw' +
    'LjAgNjEyIDc5MiBdCi9QYXJlbnQgMiAwIFIKPj4KZW5kb2JqCjcgMCBvYmoKPDwKL1YgMgov' +
    'UiAzCi9MZW5ndGggMTI4Ci9QIDQyOTQ5NjcyOTIKL0ZpbHRlciAvU3RhbmRhcmQKL08gPDU2' +
    'NmZhODczZWUzM2M3OTdjZDNiOTA0ZmRhZGY4MTRhZmEzNGRmOWEzOGY2ZWQ0MWI5ODRlMmM2' +
    'ZGEyYWE2ZjU+Ci9VIDwyNTA0NzAxZTA2MjIzNTc0YTRjN2UzMmNlYzFhNmIwNzI4YmY0ZTVl' +
    'NGU3NThhNDE2NDAwNGU1NmZmZmEwMTA4Pgo+PgplbmRvYmoKeHJlZgowIDgKMDAwMDAwMDAw' +
    'MCA2NTUzNSBmIAowMDAwMDAwMDE1IDAwMDAwIG4gCjAwMDAwMDAwNTkgMDAwMDAgbiAKMDAw' +
    'MDAwMDEyNCAwMDAwMCBuIAowMDAwMDAwMTczIDAwMDAwIG4gCjAwMDAwMDAyODMgMDAwMDAg' +
    'biAKMDAwMDAwMDM3NSAwMDAwMCBuIAowMDAwMDAwNDY5IDAwMDAwIG4gCnRyYWlsZXIKPDwK' +
    'L1NpemUgOAovUm9vdCAzIDAgUgovSW5mbyAxIDAgUgovSUQgWyA8MzQzMzYzMzI2MzYzMzM2' +
    'MzM3NjE2NjM3MzY2NjY1NjMzNDMzMzYzMDM2NjM2NDM0NjE2MTM1MzY2MTM2MzUzOD4gPDM0' +
    'MzM2MzMyNjM2MzMzNjMzNzYxNjYzNzM2NjY2NTYzMzQzMzM2MzAzNjYzNjQzNDYxNjEzNTM2' +
    'NjEzNjM1Mzg+IF0KL0VuY3J5cHQgNyAwIFIKPj4Kc3RhcnR4cmVmCjY4NAolJUVPRgo=';

procedure TestEncryptedDocSave;
var
  FixBytes, SavedBytes: TBytes;
  Src, Out: TBytesStream;
  Doc: TPDFDocument;
begin
  Section('T13 -- Full rewrite of encrypted document');
  try
    FixBytes := TNetEncoding.Base64.DecodeStringToBytes(EncryptedFixtureB64);
    Check(Length(FixBytes) > 200, 'Encrypted fixture decoded');

    // Load: auto-authenticate with empty user password
    Src := TBytesStream.Create(FixBytes);
    Out := TBytesStream.Create;
    Doc := TPDFDocument.Create;
    try
      Doc.LoadFromStream(Src);
      Check(Doc.IsEncrypted, 'Fixture is encrypted');
      Check(Doc.PageCount = 2,
        Format('PageCount = 2 before save  (got %d)', [Doc.PageCount]));

      Doc.SaveToStream(Out);   // must not raise
      SavedBytes := Copy(Out.Bytes, 0, Out.Size);
    finally
      Doc.Free;
      Out.Free;
      Src.Free;
    end;

    Check(Length(SavedBytes) > 100, 'SaveToStream produced output');

    // Reload the saved (now unencrypted) document
    WithDoc(SavedBytes,
      procedure(Doc2: TPDFDocument)
      var
        CS: TBytes;
        P:  TPDFPage;
      begin
        Check(not Doc2.IsEncrypted,
          'Saved output is not encrypted');
        Check(Doc2.PageCount = 2,
          Format('Reloaded PageCount = 2  (got %d)', [Doc2.PageCount]));

        if Doc2.PageCount >= 1 then
        begin
          P := Doc2.Pages[0];
          Check(Abs(P.Width  - 595) < 1,
            Format('Page 0 width  ~= 595  (got %.1f)', [P.Width]));
          Check(Abs(P.Height - 841) < 1,
            Format('Page 0 height ~= 841  (got %.1f)', [P.Height]));
          CS := Doc2.Pages[0].ContentStreamBytes;
          Check(Length(CS) > 0,
            Format('Page 0 content stream non-empty  (got %d bytes)', [Length(CS)]));
        end;

        if Doc2.PageCount >= 2 then
        begin
          P := Doc2.Pages[1];
          Check(Abs(P.Width  - 612) < 1,
            Format('Page 1 width  ~= 612  (got %.1f)', [P.Width]));
          Check(Abs(P.Height - 792) < 1,
            Format('Page 1 height ~= 792  (got %.1f)', [P.Height]));
        end;
      end);
  except
    on E: Exception do
      Fail('Unhandled exception', E.ClassName + ': ' + E.Message);
  end;
end;

// =========================================================================
// Main
// =========================================================================

begin
  OutDir := ExtractFilePath(ParamStr(0));

  TestRoundTripFidelity;
  TestContentPreserved;
  TestRotatePages;
  TestRemovePage;
  TestAddPage;
  TestFromScratch;
  TestSaveToFile;
  TestErrorCases;
  TestMetadataFromScratch;
  TestMetadataOnLoadedDoc;
  TestMetadataUnicode;
  TestLZWRoundTrip;
  TestEncryptedDocSave;

  WriteLn;
  WriteLn(Format('Results: %d passed, %d failed', [PassCount, FailCount]));
  if FailCount > 0 then
    ExitCode := 1;
end.
