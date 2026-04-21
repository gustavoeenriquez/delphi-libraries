program TestWriter;
// Tests uPDF.Writer: TPDFBuilder, TPDFContentBuilder, TPDFObjectSerializer
// Round-trip: create PDF -> save -> reload -> verify with TPDFDocument/TextExtractor

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}
{$R *.res}

uses
  System.SysUtils, System.Classes, System.StrUtils, System.Math,
  System.IOUtils,
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
  uPDF.TOC           in '..\Src\Core\uPDF.TOC.pas';

// =========================================================================
// Helpers
// =========================================================================

var
  PassCount: Integer = 0;
  FailCount: Integer = 0;
  OutDir:    string;        // directory of this executable

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

// Register a standard Type1 font in a page's Resources/Font dict
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

// Attach a finished content stream to a page dict
procedure AttachContent(APageDict: TPDFDictionary; CB: TPDFContentBuilder);
var
  Stm: TPDFStream;
begin
  Stm := TPDFStream.Create;
  Stm.SetRawData(CB.Build);
  APageDict.SetValue('Contents', Stm);
end;

// =========================================================================
// T01 — Create a minimal blank PDF and verify structure after reload
// =========================================================================

procedure TestMinimalCreate;
var
  TmpFile: string;
  Builder: TPDFBuilder;
  Page:    TPDFDictionary;
  CB:      TPDFContentBuilder;
  Doc:     TPDFDocument;
begin
  Section('T01 — Minimal PDF Create + Reload');
  TmpFile := TPath.Combine(OutDir,'test_writer_minimal.pdf');
  Builder := TPDFBuilder.Create;
    try
      Page := Builder.AddPage(595, 842);  // A4 portrait
      Check(Builder.PageCount = 1, 'PageCount = 1 after AddPage');

      AddStdFont(Page, 'F1', 'Helvetica');
      CB := TPDFContentBuilder.Create;
      try
        CB.SetFillRGB(0.2, 0.4, 0.8);
        CB.Rectangle(40, 790, 515, 30);
        CB.Fill;
        CB.SetFillRGB(1, 1, 1);
        CB.BeginText;
        CB.SetFont('F1', 18);
        CB.SetTextMatrix(1, 0, 0, 1, 50, 797);
        CB.ShowText('T01 — Minimal PDF (A4  595 x 842 pt)');
        CB.EndText;
        CB.SetFillRGB(0, 0, 0);
        CB.BeginText;
        CB.SetFont('F1', 12);
        CB.SetTextMatrix(1, 0, 0, 1, 50, 750);
        CB.ShowText('This PDF was created by TPDFBuilder.AddPage(595, 842).');
        CB.MoveTextPos(0, -20);
        CB.ShowText('It contains one A4 page and a basic content stream.');
        CB.MoveTextPos(0, -20);
        CB.ShowText('Purpose: verify minimal PDF structure and round-trip reload.');
        CB.EndText;
        AttachContent(Page, CB);
      finally
        CB.Free;
      end;

      try
        Builder.SaveToFile(TmpFile);
        Check(FileExists(TmpFile), Format('File created  (%s)', [TmpFile]));
        Check(TFile.GetSize(TmpFile) > 100, Format('File size > 100 bytes  (got %d)',
          [TFile.GetSize(TmpFile)]));
      except
        on E: Exception do
        begin
          Fail('SaveToFile raised ' + E.ClassName, E.Message);
          Exit;
        end;
      end;
    finally
      Builder.Free;
    end;

    Doc := TPDFDocument.Create;
    try
      try
        Doc.LoadFromFile(TmpFile);
        Check(Doc.PageCount = 1, Format('Reloaded PageCount = 1  (got %d)', [Doc.PageCount]));
        var P := Doc.Pages[0];
        Check(Abs(P.Width  - 595) < 1,
          Format('Page width  ≈ 595  (got %.1f)', [P.Width]));
        Check(Abs(P.Height - 842) < 1,
          Format('Page height ≈ 842  (got %.1f)', [P.Height]));
      except
        on E: Exception do
          Fail('Reload raised ' + E.ClassName, E.Message);
      end;
    finally
      Doc.Free;
    end;
end;

// =========================================================================
// T02 — Metadata round-trip (title / author / subject)
// =========================================================================

procedure TestMetadataRoundTrip;
var
  TmpFile: string;
  Builder: TPDFBuilder;
  Page:    TPDFDictionary;
  CB:      TPDFContentBuilder;
  Doc:     TPDFDocument;
begin
  Section('T02 — Metadata Round-Trip');
  TmpFile := TPath.Combine(OutDir,'test_writer_meta.pdf');
  Builder := TPDFBuilder.Create;
    try
      Builder.SetTitle('Test Title');
      Builder.SetAuthor('Test Author');
      Builder.SetSubject('Test Subject');
      Builder.SetCreator('TestWriter');
      Page := Builder.AddPage(595, 842);
      AddStdFont(Page, 'F1', 'Helvetica');
      AddStdFont(Page, 'F2', 'Helvetica-Bold');
      CB := TPDFContentBuilder.Create;
      try
        CB.SetFillRGB(0.1, 0.5, 0.2);
        CB.Rectangle(40, 790, 515, 30);
        CB.Fill;
        CB.SetFillRGB(1, 1, 1);
        CB.BeginText;
        CB.SetFont('F2', 18);
        CB.SetTextMatrix(1, 0, 0, 1, 50, 797);
        CB.ShowText('T02 — Metadata Round-Trip');
        CB.EndText;
        CB.SetFillRGB(0, 0, 0);
        CB.BeginText;
        CB.SetFont('F2', 11);
        CB.SetTextMatrix(1, 0, 0, 1, 50, 750);
        CB.ShowText('Metadata embedded in this PDF:');
        CB.SetFont('F1', 11);
        CB.MoveTextPos(0, -22);
        CB.ShowText('Title   : Test Title');
        CB.MoveTextPos(0, -18);
        CB.ShowText('Author  : Test Author');
        CB.MoveTextPos(0, -18);
        CB.ShowText('Subject : Test Subject');
        CB.MoveTextPos(0, -18);
        CB.ShowText('Creator : TestWriter');
        CB.MoveTextPos(0, -30);
        CB.SetFont('F1', 10);
        CB.ShowText('Open File > Properties in your PDF viewer to verify the metadata above.');
        CB.EndText;
        AttachContent(Page, CB);
      finally
        CB.Free;
      end;
      Builder.SaveToFile(TmpFile);
    finally
      Builder.Free;
    end;

    Doc := TPDFDocument.Create;
    try
      try
        Doc.LoadFromFile(TmpFile);
        Check(Doc.Title  = 'Test Title',
          Format('Title  = "Test Title"   (got "%s")', [Doc.Title]));
        Check(Doc.Author = 'Test Author',
          Format('Author = "Test Author"  (got "%s")', [Doc.Author]));
      except
        on E: Exception do
          Fail('Metadata reload raised ' + E.ClassName, E.Message);
      end;
    finally
      Doc.Free;
    end;
end;

// =========================================================================
// T03 — Multi-page PDF with varying page sizes
// =========================================================================

procedure TestMultiPage;
const
  PW:    array[0..4] of Single = (595, 842, 612, 420, 595);
  PH:    array[0..4] of Single = (842, 595, 792, 595, 842);
  PNAME: array[0..4] of string = ('A4 Portrait', 'A4 Landscape', 'US Letter Portrait',
                                   'A5 Portrait', 'A4 Portrait');
var
  TmpFile: string;
  Builder: TPDFBuilder;
  Page:    TPDFDictionary;
  CB:      TPDFContentBuilder;
  Doc:     TPDFDocument;
  I:       Integer;
begin
  Section('T03 — Multi-Page PDF (5 pages, varying sizes)');
  TmpFile := TPath.Combine(OutDir,'test_writer_multi.pdf');
  Builder := TPDFBuilder.Create;
    try
      for I := 0 to 4 do
      begin
        Page := Builder.AddPage(PW[I], PH[I]);
        AddStdFont(Page, 'F1', 'Helvetica');
        AddStdFont(Page, 'F2', 'Helvetica-Bold');
        CB := TPDFContentBuilder.Create;
        try
          // Colored header bar
          CB.SetFillRGB(0.5, 0.1 * I, 0.8 - 0.1 * I);
          CB.Rectangle(40, PH[I] - 50, PW[I] - 80, 38);
          CB.Fill;
          CB.SetFillRGB(1, 1, 1);
          CB.BeginText;
          CB.SetFont('F2', 16);
          CB.SetTextMatrix(1, 0, 0, 1, 50, PH[I] - 32);
          CB.ShowText(Format('Page %d of 5  —  %s', [I + 1, PNAME[I]]));
          CB.EndText;
          CB.SetFillRGB(0, 0, 0);
          CB.BeginText;
          CB.SetFont('F1', 11);
          CB.SetTextMatrix(1, 0, 0, 1, 50, PH[I] - 80);
          CB.ShowText(Format('Size: %.0f x %.0f pt', [PW[I], PH[I]]));
          CB.MoveTextPos(0, -18);
          CB.ShowText('T03 — Multi-Page PDF test (5 pages with varying sizes).');
          CB.EndText;
          AttachContent(Page, CB);
        finally
          CB.Free;
        end;
      end;
      Check(Builder.PageCount = 5, 'Builder.PageCount = 5');
      Builder.SaveToFile(TmpFile);
    finally
      Builder.Free;
    end;

    Doc := TPDFDocument.Create;
    try
      try
        Doc.LoadFromFile(TmpFile);
        Check(Doc.PageCount = 5,
          Format('Reloaded 5 pages  (got %d)', [Doc.PageCount]));

        for I := 0 to Min(4, Doc.PageCount - 1) do
        begin
          var P := Doc.Pages[I];
          Check(Abs(P.Width  - PW[I]) < 1,
            Format('Page[%d] width  = %.0f  (got %.1f)', [I, PW[I], P.Width]));
          Check(Abs(P.Height - PH[I]) < 1,
            Format('Page[%d] height = %.0f  (got %.1f)', [I, PH[I], P.Height]));
        end;
      except
        on E: Exception do
          Fail('Multi-page reload raised ' + E.ClassName, E.Message);
      end;
    finally
      Doc.Free;
    end;
end;

// =========================================================================
// T04 — Text content round-trip (write text, extract and verify)
// =========================================================================

procedure TestTextRoundTrip;
var
  TmpFile: string;
  Builder: TPDFBuilder;
  Page:    TPDFDictionary;
  CB:      TPDFContentBuilder;
  Doc:     TPDFDocument;
  Ext:     TPDFTextExtractor;
begin
  Section('T04 — Text Content Round-Trip');
  TmpFile := TPath.Combine(OutDir,'test_writer_text.pdf');
  Builder := TPDFBuilder.Create;
    try
      Page := Builder.AddPage(595, 842);
      AddStdFont(Page, 'F1', 'Helvetica');

      CB := TPDFContentBuilder.Create;
      try
        CB.BeginText;
        CB.SetFont('F1', 12);
        CB.SetTextMatrix(1, 0, 0, 1, 50, 750);
        CB.ShowText('Hello World');
        CB.MoveTextPos(0, -20);
        CB.ShowText('PDF Writer Test');
        CB.MoveTextPos(0, -20);
        CB.ShowText('Round Trip OK');
        CB.EndText;
        AttachContent(Page, CB);
      finally
        CB.Free;
      end;

      Builder.SaveToFile(TmpFile);
      Pass('PDF with text saved');
    finally
      Builder.Free;
    end;

    Doc := TPDFDocument.Create;
    try
      try
        Doc.LoadFromFile(TmpFile);
        Ext := TPDFTextExtractor.Create(Doc);
        try
          var PT := Ext.ExtractPage(0);
          Check(Length(PT.Fragments) > 0,
            Format('Extracted %d fragments from created PDF',
              [Length(PT.Fragments)]));
          var Plain := PT.PlainText;
          Check(ContainsText(Plain, 'Hello'),
            'PlainText contains "Hello"');
          Check(ContainsText(Plain, 'Writer'),
            'PlainText contains "Writer"');
          Check(ContainsText(Plain, 'Round'),
            'PlainText contains "Round"');
          WriteLn(Format('  PlainText: "%s"', [Plain.Trim.Substring(0, Min(80, Length(Plain.Trim)))]));
        finally
          Ext.Free;
        end;
      except
        on E: Exception do
          Fail('Text round-trip raised ' + E.ClassName, E.Message);
      end;
    finally
      Doc.Free;
    end;
end;

// =========================================================================
// T05 — ContentBuilder: verify PDF operator output
// =========================================================================

procedure TestContentBuilderOutput;
var
  CB: TPDFContentBuilder;
  S:  string;
begin
  Section('T05 — ContentBuilder Output Format');
  CB := TPDFContentBuilder.Create;
  try
    try
      CB.SaveState;                          // q
      CB.SetFillRGB(1, 0, 0);               // 1 0 0 rg
      CB.SetStrokeRGB(0, 0, 1);             // 0 0 1 RG
      CB.SetLineWidth(2.5);                  // 2.5 w
      CB.SetLineJoin(1);                     // 1 j
      CB.SetLineCap(2);                      // 2 J
      CB.Rectangle(10, 20, 100, 50);        // 10 20 100 50 re
      CB.FillAndStroke;                      // B
      CB.RestoreState;                       // Q

      CB.BeginText;                          // BT
      CB.SetFont('Helvetica', 14);           // /Helvetica 14 Tf
      CB.SetTextMatrix(1, 0, 0, 1, 50, 700);// 1 0 0 1 50 700 Tm
      CB.ShowText('Hello');                  // (Hello) Tj
      CB.MoveTextPos(0, -20);               // 0 -20 Td
      CB.SetLeading(15);                    // 15 TL
      CB.NextLine;                           // T*
      CB.EndText;                            // ET

      CB.MoveTo(0, 0);                       // 0 0 m
      CB.LineTo(100, 100);                   // 100 100 l
      CB.CurveTo(10, 50, 50, 90, 80, 100); // 10 50 50 90 80 100 c
      CB.ClosePath;                          // h
      CB.Stroke;                             // S

      S := CB.BuildAsString;

      // Verify PDF operators are present
      Check(Pos('q'#10, S) > 0,           'SaveState → "q" in stream');
      Check(Pos('Q'#10, S) > 0,           'RestoreState → "Q" in stream');
      Check(Pos(' rg'#10, S) > 0,         'SetFillRGB → "rg" operator');
      Check(Pos(' RG'#10, S) > 0,         'SetStrokeRGB → "RG" operator');
      Check(Pos(' w'#10, S) > 0,          'SetLineWidth → "w" operator');
      Check(Pos(' j'#10, S) > 0,          'SetLineJoin → "j" operator');
      Check(Pos(' J'#10, S) > 0,          'SetLineCap → "J" operator');
      Check(Pos(' re'#10, S) > 0,         'Rectangle → "re" operator');
      Check(Pos('B'#10, S) > 0,           'FillAndStroke → "B" operator');
      Check(Pos('BT'#10, S) > 0,          'BeginText → "BT" operator');
      Check(Pos('ET'#10, S) > 0,          'EndText → "ET" operator');
      Check(Pos(' Tf'#10, S) > 0,         'SetFont → "Tf" operator');
      Check(Pos(' Tm'#10, S) > 0,         'SetTextMatrix → "Tm" operator');
      Check(ContainsStr(S, 'Tj'),          'ShowText → "Tj" operator');
      Check(ContainsStr(S, 'Hello'),       'ShowText literal in stream');
      Check(Pos(' Td'#10, S) > 0,         'MoveTextPos → "Td" operator');
      Check(Pos(' TL'#10, S) > 0,         'SetLeading → "TL" operator');
      Check(Pos('T*'#10, S) > 0,          'NextLine → "T*" operator');
      Check(Pos(' m'#10, S) > 0,          'MoveTo → "m" operator');
      Check(Pos(' l'#10, S) > 0,          'LineTo → "l" operator');
      Check(Pos(' c'#10, S) > 0,          'CurveTo → "c" operator');
      Check(Pos('h'#10, S) > 0,           'ClosePath → "h" operator');
      Check(Pos('S'#10, S) > 0,           'Stroke → "S" operator');

      var Bytes := CB.Build;
      Check(Length(Bytes) = Length(TEncoding.ASCII.GetBytes(S)),
        Format('Build bytes = BuildAsString bytes  (%d)', [Length(Bytes)]));

      WriteLn(Format('  Stream size: %d bytes', [Length(Bytes)]));
    except
      on E: Exception do
        Fail('ContentBuilder raised ' + E.ClassName, E.Message);
    end;
  finally
    CB.Free;
  end;
end;

// =========================================================================
// T06 — Additional ContentBuilder operators
// =========================================================================

procedure TestContentBuilderExtras;
var
  CB: TPDFContentBuilder;
  S:  string;
begin
  Section('T06 — ContentBuilder Extras (CMYK, gray, ellipse, transforms)');
  CB := TPDFContentBuilder.Create;
  try
    try
      CB.SetFillGray(0.5);             // 0.5 g
      CB.SetStrokeGray(0.3);           // 0.3 G
      CB.SetFillCMYK(0.1, 0.2, 0.3, 0.4); // 0.1 0.2 0.3 0.4 k
      CB.SetStrokeCMYK(0, 0, 0, 1);    // 0 0 0 1 K
      CB.SetDash([6, 3], 0);           // [6 3] 0 d
      CB.SetMiterLimit(10);            // 10 M
      CB.SetFlat(1);                   // 1 i
      CB.Ellipse(100, 100, 50, 30);   // approx with c operators
      CB.Fill;                         // f
      CB.FillEvenOdd;                  // f*
      CB.FillEvenOddAndStroke;         // B*
      CB.EndPath;                      // n
      CB.Translate(10, 20);            // 1 0 0 1 10 20 cm
      CB.Scale(2, 3);                  // 2 0 0 3 0 0 cm
      CB.Rotate(45);                   // cos sin -sin cos 0 0 cm

      S := CB.BuildAsString;

      Check(Pos(' g'#10, S) > 0,        'SetFillGray → "g"');
      Check(Pos(' G'#10, S) > 0,        'SetStrokeGray → "G"');
      Check(Pos(' k'#10, S) > 0,        'SetFillCMYK → "k"');
      Check(Pos(' K'#10, S) > 0,        'SetStrokeCMYK → "K"');
      Check(Pos(' d'#10, S) > 0,        'SetDash → "d"');
      Check(Pos(' M'#10, S) > 0,        'SetMiterLimit → "M"');
      Check(Pos(' i'#10, S) > 0,        'SetFlat → "i"');
      Check(ContainsStr(S, ' c'#10),    'Ellipse uses curveto "c"');
      Check(Pos('f'#10, S) > 0,         'Fill → "f"');
      Check(ContainsStr(S, 'f*'),        'FillEvenOdd → "f*"');
      Check(ContainsStr(S, 'B*'),        'FillEvenOddAndStroke → "B*"');
      Check(Pos('n'#10, S) > 0,         'EndPath → "n"');
      Check(Pos(' cm'#10, S) > 0,       'Transform → "cm"');
    except
      on E: Exception do
        Fail('ContentBuilder extras raised ' + E.ClassName, E.Message);
    end;
  finally
    CB.Free;
  end;
end;

// =========================================================================
// T07 — Compressed PDF (FlateDecode content streams, round-trip)
// =========================================================================

procedure TestCompressedPDF;
var
  TmpFile:  string;
  Builder:  TPDFBuilder;
  Page:     TPDFDictionary;
  CB:       TPDFContentBuilder;
  Doc:      TPDFDocument;
  Ext:      TPDFTextExtractor;
  Opts:     TPDFWriteOptions;
  UncompSz: Int64;
  CompSz:   Int64;
begin
  Section('T07 — Compressed Content Streams (FlateDecode round-trip)');

  // First create uncompressed version to measure size difference
  var TmpUncomp := TPath.Combine(OutDir,'test_writer_uncomp.pdf');
  var TmpComp   := TPath.Combine(OutDir,'test_writer_comp.pdf');
  // Uncompressed
    Builder := TPDFBuilder.Create;
    try
      var P2 := Builder.AddPage(595, 842);
      AddStdFont(P2, 'F1', 'Helvetica');
      var C2 := TPDFContentBuilder.Create;
      try
        C2.BeginText;
        C2.SetFont('F1', 10);
        C2.SetLeading(14);
        C2.SetTextMatrix(1, 0, 0, 1, 50, 750);
        C2.ShowText('Compressed Content Test — FlateDecode Verification');
        for var J := 1 to 20 do
        begin
          C2.MoveTextPos(0, -14);
          C2.ShowText(Format('Line %d: The quick brown fox jumps over the lazy dog.', [J]));
        end;
        C2.EndText;
        AttachContent(P2, C2);
      finally
        C2.Free;
      end;
      Opts := TPDFWriteOptions.Default;
      Opts.CompressStreams := False;
      Builder.SaveToFile(TmpUncomp, Opts);
    finally
      Builder.Free;
    end;

    // Compressed
    Builder := TPDFBuilder.Create;
    try
      var P3 := Builder.AddPage(595, 842);
      AddStdFont(P3, 'F1', 'Helvetica');
      var C3 := TPDFContentBuilder.Create;
      try
        C3.BeginText;
        C3.SetFont('F1', 10);
        C3.SetLeading(14);
        C3.SetTextMatrix(1, 0, 0, 1, 50, 750);
        C3.ShowText('Compressed Content Test — FlateDecode Verification');
        for var K := 1 to 20 do
        begin
          C3.MoveTextPos(0, -14);
          C3.ShowText(Format('Line %d: The quick brown fox jumps over the lazy dog.', [K]));
        end;
        C3.EndText;
        AttachContent(P3, C3);
      finally
        C3.Free;
      end;
      Opts := TPDFWriteOptions.Default;
      Opts.CompressStreams := True;
      try
        Builder.SaveToFile(TmpComp, Opts);
        Pass('Compressed PDF saved');
      except
        on E: Exception do
        begin
          Fail('Compressed save raised ' + E.ClassName, E.Message);
          Exit;
        end;
      end;
    finally
      Builder.Free;
    end;

    UncompSz := TFile.GetSize(TmpUncomp);
    CompSz   := TFile.GetSize(TmpComp);
    WriteLn(Format('  Uncompressed: %d bytes   Compressed: %d bytes',
      [UncompSz, CompSz]));
    Check(CompSz < UncompSz,
      Format('Compressed file is smaller  (%d < %d)', [CompSz, UncompSz]));

    // Verify decompression: text extraction must still work
    Doc := TPDFDocument.Create;
    try
      try
        Doc.LoadFromFile(TmpComp);
        Ext := TPDFTextExtractor.Create(Doc);
        try
          var PT := Ext.ExtractPage(0);
          Check(Length(PT.Fragments) > 0,
            Format('Extracted %d fragments from compressed PDF', [Length(PT.Fragments)]));
          Check(ContainsText(PT.PlainText, 'Compressed'),
            'PlainText contains "Compressed" after FlateDecode decode');
        finally
          Ext.Free;
        end;
      except
        on E: Exception do
          Fail('Compressed reload raised ' + E.ClassName, E.Message);
      end;
    finally
      Doc.Free;
    end;
end;

// =========================================================================
// T08 — Object serializer (TPDFObjectSerializer)
// =========================================================================

procedure TestObjectSerializer;
var
  MS:    TMemoryStream;
  Bytes: TBytes;

  function ReadStr: string;
  begin
    SetLength(Bytes, MS.Size);
    if MS.Size > 0 then
    begin
      MS.Position := 0;
      MS.Read(Bytes[0], MS.Size);
    end;
    Result := TEncoding.ASCII.GetString(Bytes);
  end;

  procedure Ser(AObj: TPDFObject);
  begin
    MS.Clear;
    TPDFObjectSerializer.WriteValue(AObj, MS);
    AObj.Free;
  end;

begin
  Section('T08 — Object Serializer');
  MS := TMemoryStream.Create;
  try
    try
      Ser(TPDFInteger.Create(0));
      Check(ReadStr = '0',    'Integer 0 → "0"');

      Ser(TPDFInteger.Create(42));
      Check(ReadStr = '42',   'Integer 42 → "42"');

      Ser(TPDFInteger.Create(-7));
      Check(ReadStr = '-7',   'Integer -7 → "-7"');

      Ser(TPDFBoolean.Create(True));
      Check(ReadStr = 'true', 'Boolean true → "true"');

      Ser(TPDFBoolean.Create(False));
      Check(ReadStr = 'false','Boolean false → "false"');

      Ser(TPDFName.Create('Page'));
      Check(ReadStr = '/Page', 'Name "Page" → "/Page"');

      Ser(TPDFName.Create('XObject'));
      Check(ReadStr = '/XObject', 'Name "XObject" → "/XObject"');

      Ser(TPDFNull.Create);
      Check(ReadStr = 'null', 'Null → "null"');

      // Real — only check prefix since float formatting can vary slightly
      Ser(TPDFReal.Create(3.14));
      var S := ReadStr;
      Check(S.StartsWith('3.1'), Format('Real 3.14 starts with "3.1"  (got "%s")', [S]));

      Ser(TPDFReal.Create(-0.5));
      S := ReadStr;
      Check(S.StartsWith('-0.5') or S.StartsWith('-.5'),
        Format('Real -0.5 serialized  (got "%s")', [S]));

      // Array
      var Arr := TPDFArray.Create;
      Arr.Add(TPDFInteger.Create(1));
      Arr.Add(TPDFInteger.Create(2));
      Arr.Add(TPDFInteger.Create(3));
      MS.Clear;
      TPDFObjectSerializer.WriteValue(Arr, MS);
      Arr.Free;
      S := ReadStr;
      Check(ContainsStr(S, '1') and ContainsStr(S, '2') and ContainsStr(S, '3'),
        Format('Array [1,2,3] serialized  (got "%s")', [S]));
      Check(S.StartsWith('['), 'Array starts with "["');
      Check(S.TrimRight.EndsWith(']'), 'Array ends with "]"');

      // Dictionary
      var Dict := TPDFDictionary.Create;
      Dict.SetValue('Type',    TPDFName.Create('Page'));
      Dict.SetValue('Rotate',  TPDFInteger.Create(0));
      MS.Clear;
      TPDFObjectSerializer.WriteValue(Dict, MS);
      Dict.Free;
      S := ReadStr;
      Check(S.StartsWith('<<'), 'Dict starts with "<<"');
      Check(ContainsStr(S, '>>'), 'Dict ends with ">>"');
      Check(ContainsStr(S, '/Type'), 'Dict contains /Type key');
      Check(ContainsStr(S, '/Page'), 'Dict contains /Page value');

    except
      on E: Exception do
        Fail('Serializer raised ' + E.ClassName, E.Message);
    end;
  finally
    MS.Free;
  end;
end;

// =========================================================================
// T09 — Full demo page (complex content + reload + text extraction)
// =========================================================================

procedure TestComplexPage;
var
  TmpFile: string;
  Builder: TPDFBuilder;
  Page:    TPDFDictionary;
  CB:      TPDFContentBuilder;
  I:       Integer;
  Doc:     TPDFDocument;
  Ext:     TPDFTextExtractor;
  K, CX, CY, R, T: Single;
begin
  Section('T09 — Complex Page (shapes + text + multiple fonts)');
  TmpFile := TPath.Combine(OutDir,'test_writer_complex.pdf');
  Builder := TPDFBuilder.Create;
    try
      Builder.SetTitle('Complex Test');
      Builder.SetAuthor('TestWriter Suite');

      Page := Builder.AddPage(595, 842);
      AddStdFont(Page, 'Helvetica',         'Helvetica');
      AddStdFont(Page, 'Helvetica-Bold',    'Helvetica-Bold');
      AddStdFont(Page, 'Helvetica-Oblique', 'Helvetica-Oblique');
      AddStdFont(Page, 'Courier',           'Courier');

      CB := TPDFContentBuilder.Create;
      try
        // Blue header
        CB.SaveState;
        CB.SetFillRGB(0.2, 0.4, 0.8);
        CB.Rectangle(50, 780, 495, 40);
        CB.Fill;
        CB.SetFillRGB(1, 1, 1);
        CB.BeginText;
        CB.SetFont('Helvetica-Bold', 18);
        CB.SetTextMatrix(1, 0, 0, 1, 60, 793);
        CB.ShowText('Complex Test Page');
        CB.EndText;
        CB.RestoreState;

        // Stroked rectangle
        CB.SaveState;
        CB.SetLineWidth(2);
        CB.SetStrokeRGB(0.8, 0.2, 0.2);
        CB.Rectangle(50, 680, 150, 50);
        CB.Stroke;
        CB.RestoreState;

        // Filled ellipse
        CX := 290; CY := 705; R := 25; K := 0.5523;
        CB.SaveState;
        CB.SetFillRGB(0.2, 0.7, 0.3);
        CB.MoveTo(CX + R, CY);
        CB.CurveTo(CX+R, CY+K*R, CX+K*R, CY+R, CX, CY+R);
        CB.CurveTo(CX-K*R, CY+R, CX-R, CY+K*R, CX-R, CY);
        CB.CurveTo(CX-R, CY-K*R, CX-K*R, CY-R, CX, CY-R);
        CB.CurveTo(CX+K*R, CY-R, CX+R, CY-K*R, CX+R, CY);
        CB.ClosePath;
        CB.Fill;
        CB.RestoreState;

        // Typography section
        CB.BeginText;
        CB.SetFillRGB(0, 0, 0);
        CB.SetFont('Helvetica-Bold', 14);
        CB.SetTextMatrix(1, 0, 0, 1, 50, 640);
        CB.ShowText('Typography Test');
        CB.SetFont('Helvetica', 11);
        CB.MoveTextPos(0, -20);
        CB.ShowText('Regular — The quick brown fox jumps over the lazy dog.');
        CB.MoveTextPos(0, -16);
        CB.SetFont('Helvetica-Bold', 11);
        CB.ShowText('Bold text sample.');
        CB.MoveTextPos(0, -16);
        CB.SetFont('Courier', 11);
        CB.ShowText('Mono: 0123456789  Hello World');
        CB.EndText;

        // Color bands
        for I := 0 to 9 do
        begin
          T := I / 9.0;
          CB.SaveState;
          CB.SetFillRGB(T, 0.3, 1.0 - T);
          CB.Rectangle(50 + I * 49, 480, 49, 20);
          CB.Fill;
          CB.RestoreState;
        end;

        // Dashed line
        CB.SaveState;
        CB.SetLineWidth(1.5);
        CB.SetDash([8, 4], 0);
        CB.SetStrokeRGB(0.4, 0.1, 0.6);
        CB.MoveTo(50, 450);
        CB.LineTo(545, 450);
        CB.Stroke;
        CB.RestoreState;

        // Footer
        CB.SetFillGray(0.4);
        CB.BeginText;
        CB.SetFont('Helvetica', 9);
        CB.SetTextMatrix(1, 0, 0, 1, 50, 48);
        CB.ShowText('Generated by TestWriter — Delphi PDF Library Intensive Test');
        CB.EndText;

        AttachContent(Page, CB);
      finally
        CB.Free;
      end;

      try
        Builder.SaveToFile(TmpFile);
        Pass('Complex page saved');
      except
        on E: Exception do
        begin
          Fail('Complex save raised ' + E.ClassName, E.Message);
          Exit;
        end;
      end;
    finally
      Builder.Free;
    end;

    Doc := TPDFDocument.Create;
    try
      try
        Doc.LoadFromFile(TmpFile);
        Check(Doc.PageCount = 1, 'Complex PDF: 1 page reloaded');
        Check(Doc.Title  = 'Complex Test',
          Format('Title  = "Complex Test"  (got "%s")', [Doc.Title]));
        Check(Doc.Author = 'TestWriter Suite',
          Format('Author = "TestWriter Suite"  (got "%s")', [Doc.Author]));

        Ext := TPDFTextExtractor.Create(Doc);
        try
          var PT := Ext.ExtractPage(0);
          Check(Length(PT.Fragments) > 0,
            Format('Complex page: %d fragments extracted', [Length(PT.Fragments)]));
          Check(Length(PT.Lines) > 0,
            Format('Complex page: %d lines grouped', [Length(PT.Lines)]));

          var Plain := PT.PlainText;
          Check(ContainsText(Plain, 'Typography'),
            'PlainText contains "Typography"');
          Check(ContainsText(Plain, 'quick brown fox'),
            'PlainText contains "quick brown fox"');
          Check(ContainsText(Plain, 'Hello World'),
            'PlainText contains "Hello World"');

          WriteLn(Format('  Fragments: %d   Lines: %d',
            [Length(PT.Fragments), Length(PT.Lines)]));
        finally
          Ext.Free;
        end;
      except
        on E: Exception do
          Fail('Complex reload raised ' + E.ClassName, E.Message);
      end;
    finally
      Doc.Free;
    end;
end;

// =========================================================================
// T10 — TPDFWriteOptions.Default sanity
// =========================================================================

procedure TestWriteOptions;

// =========================================================================
// T11 — AddJPEGImage / AddRawImage / AddLinkURI / DrawXObject
// =========================================================================

procedure TestImageEmbedding;
var
  Builder : TPDFBuilder;
  Content : TPDFContentBuilder;
  Page    : TPDFDictionary;
  Doc     : TPDFDocument;
  MS      : TMemoryStream;
  // Minimal valid 1×1 gray JPEG (JFIF, 1 byte, monotone)
  MinJPEG : TBytes;
  // Minimal 2×2 RGB raw bitmap (12 bytes)
  MinRaw  : TBytes;
  ImgName : string;
  RawName : string;
begin
  Section('T11 — Image embedding + link annotation');
  Builder := TPDFBuilder.Create;
  Content := TPDFContentBuilder.Create;
  MS      := TMemoryStream.Create;
  try
    try
      Page := Builder.AddPage(PDF_A4_WIDTH, PDF_A4_HEIGHT);
      AddStdFont(Page, 'F1', 'Helvetica');

      // Build a minimal 1×1 JPEG (SOI + EOI = 4 bytes — degenerate but parseable
      // as a stream by most viewers, and enough to test the plumbing).
      MinJPEG := [$FF, $D8, $FF, $D9];  // SOI + EOI
      ImgName := Builder.AddJPEGImage(Page, MinJPEG, 1, 1, 'DeviceGray');

      // Raw 2×2 gray image (4 bytes)
      MinRaw  := [$80, $C0, $40, $FF];
      RawName := Builder.AddRawImage(Page, MinRaw, 2, 2, 'DeviceGray');

      // Add a link annotation
      Builder.AddLinkURI(Page, 50, 700, 100, 20, 'https://example.com');

      // Build content using DrawXObject for JPEG, InvokeXObject for raw
      Content.BeginText;
      Content.SetFont('F1', 12);
      Content.DrawText(50, 760, 'Image embedding test');
      Content.EndText;

      Content.DrawXObject(ImgName, 50, 600, 100, 100);
      Content.DrawXObject(RawName, 200, 600, 50, 50);

      Page.SetBytes('Contents', Content.Build);
      Builder.SaveToStream(MS);

      Check(MS.Size > 0, Format('SaveToStream produced bytes  (%d bytes)', [MS.Size]));

      // Reload and verify page count + resources
      MS.Seek(0, soBeginning);
      Doc := TPDFDocument.Create;
      try
        Doc.LoadFromStream(MS);
        Check(Doc.PageCount = 1, Format('Reloaded: 1 page  (got %d)', [Doc.PageCount]));

        var Res := Doc.Pages[0].Resources;
        Check(Res <> nil, 'Page has /Resources');
        if Res <> nil then
        begin
          var XObjDict := Res.GetAsDictionary('XObject');
          Check(XObjDict <> nil, '/Resources/XObject dict present');
          if XObjDict <> nil then
          begin
            Check(XObjDict.Contains(ImgName),
              Format('/XObject contains "%s" (JPEG)', [ImgName]));
            Check(XObjDict.Contains(RawName),
              Format('/XObject contains "%s" (raw)', [RawName]));
          end;
        end;
      finally
        Doc.Free;
      end;

      // Also save to file for manual inspection
      Builder.SaveToFile(OutDir + 'test_writer_images.pdf');
      Pass('SaveToFile test_writer_images.pdf');

    except
      on E: Exception do
        Fail('Image embedding raised ' + E.ClassName, E.Message);
    end;
  finally
    MS.Free;
    Content.Free;
    Builder.Free;
  end;
end;
begin
  Section('T10 — TPDFWriteOptions.Default');
  try
    var Opts := TPDFWriteOptions.Default;
    Check(not Opts.UseObjectStreams, 'Default: UseObjectStreams = False');
    Check(not Opts.UseXRefStream,   'Default: UseXRefStream = False');
    Check(Opts.CompressStreams, 'Default: CompressStreams = True');
    var Ver14 := TPDFVersion.Make(1, 4);
    Check((Opts.Version.Major > Ver14.Major) or
          ((Opts.Version.Major = Ver14.Major) and (Opts.Version.Minor >= Ver14.Minor)),
      Format('Default: Version >= 1.4  (got %s)', [Opts.Version.ToString]));
  except
    on E: Exception do
      Fail('TPDFWriteOptions.Default raised ' + E.ClassName, E.Message);
  end;
end;

// =========================================================================
// T12 — AddStandardFont (built-in method, no external helper)
// =========================================================================

procedure TestAddStandardFont;
var
  Builder : TPDFBuilder;
  Content : TPDFContentBuilder;
  Page    : TPDFDictionary;
  MS      : TMemoryStream;
  Doc     : TPDFDocument;
  Ext     : TPDFTextExtractor;
begin
  Section('T12 — AddStandardFont');
  Builder := TPDFBuilder.Create;
  Content := TPDFContentBuilder.Create;
  MS      := TMemoryStream.Create;
  try
    try
      Page := Builder.AddPage(PDF_A4_WIDTH, PDF_A4_HEIGHT);

      // Use the built-in method — no external helper needed
      Builder.AddStandardFont(Page, 'F1', 'Helvetica');
      Builder.AddStandardFont(Page, 'F2', 'Helvetica-Bold');
      Builder.AddStandardFont(Page, 'F3', 'Courier');

      // Verify Resources/Font dict was created with correct entries
      var ResDict := Page.GetAsDictionary('Resources');
      Check(ResDict <> nil, 'Resources dict created');
      if ResDict <> nil then
      begin
        var FontDict := ResDict.GetAsDictionary('Font');
        Check(FontDict <> nil, 'Resources/Font dict created');
        if FontDict <> nil then
        begin
          var FD := FontDict.GetAsDictionary('F1');
          Check(FD <> nil, 'F1 font dict created');
          if FD <> nil then
          begin
            Check(FD.GetAsName('Subtype')  = 'Type1',     'F1/Subtype = Type1');
            Check(FD.GetAsName('BaseFont') = 'Helvetica', 'F1/BaseFont = Helvetica');
            Check(FD.GetAsName('Encoding') = 'WinAnsiEncoding', 'F1/Encoding = WinAnsiEncoding');
          end;
          Check(FontDict.Contains('F2'), 'F2 (Helvetica-Bold) registered');
          Check(FontDict.Contains('F3'), 'F3 (Courier) registered');
        end;
      end;

      // Build a page using the fonts and round-trip through save/reload
      Content.BeginText;
      Content.SetFont('F1', 14);
      Content.SetTextMatrix(1, 0, 0, 1, 50, 780);
      Content.ShowText('Standard Fonts Test — Helvetica');
      Content.SetFont('F2', 14);
      Content.SetTextMatrix(1, 0, 0, 1, 50, 760);
      Content.ShowText('Helvetica-Bold via AddStandardFont');
      Content.SetFont('F3', 12);
      Content.SetTextMatrix(1, 0, 0, 1, 50, 740);
      Content.ShowText('Courier: fixed-pitch 0123456789');
      Content.EndText;
      Page.SetBytes('Contents', Content.Build);

      Builder.SaveToStream(MS);
      Check(MS.Size > 0, 'Stream produced');

      MS.Seek(0, soBeginning);
      Doc := TPDFDocument.Create;
      try
        Doc.LoadFromStream(MS);
        Check(Doc.PageCount = 1, 'Reload: 1 page');
        Ext := TPDFTextExtractor.Create(Doc);
        try
          var PT := Ext.ExtractPage(0);
          Check(ContainsText(PT.PlainText, 'Helvetica'),
            'PlainText contains "Helvetica"');
          Check(ContainsText(PT.PlainText, 'Courier'),
            'PlainText contains "Courier"');
        finally
          Ext.Free;
        end;
      finally
        Doc.Free;
      end;

      Builder.SaveToFile(OutDir + 'test_writer_stdfont.pdf');
      Pass('SaveToFile test_writer_stdfont.pdf');
    except
      on E: Exception do
        Fail('AddStandardFont raised ' + E.ClassName, E.Message);
    end;
  finally
    MS.Free;
    Content.Free;
    Builder.Free;
  end;
end;

// =========================================================================
// T13 — DrawTextWrapped + PDFMeasureText
// =========================================================================

procedure TestDrawTextWrapped;
const
  BodyText =
    'This is a demonstration of the DrawTextWrapped method. ' +
    'It automatically breaks long lines at word boundaries so that ' +
    'each line fits within the specified width. The method supports ' +
    'left, center, and right alignment and returns the baseline Y ' +
    'of the last rendered line so the caller can continue below.';
  ColumnW = 495.0;  // A4 width minus 50pt margins on each side
var
  Builder : TPDFBuilder;
  Content : TPDFContentBuilder;
  Page    : TPDFDictionary;
  S       : string;
begin
  Section('T13 — DrawTextWrapped + PDFMeasureText');

  // --- Unit tests for PDFMeasureText ---
  try
    var W0 := PDFMeasureText('', 'Helvetica', 12);
    Check(W0 = 0, 'PDFMeasureText("") = 0');

    // 'A' in Helvetica = 667/1000 em.  At 1000pt → 667pt.
    var WA := PDFMeasureText('A', 'Helvetica', 1000);
    Check(Abs(WA - 667) < 1, Format('PDFMeasureText("A", Helvetica, 1000) ≈ 667  (got %.1f)', [WA]));

    // Courier is fixed-pitch 600/1000 em.
    var WC := PDFMeasureText('X', 'Courier', 1000);
    Check(Abs(WC - 600) < 1, Format('PDFMeasureText("X", Courier, 1000) ≈ 600  (got %.1f)', [WC]));

    // Three-char string 'ABC' in Helvetica: 667+667+722 = 2056 at 1000pt
    var WABC := PDFMeasureText('ABC', 'Helvetica', 1000);
    Check(Abs(WABC - 2056) < 1, Format('PDFMeasureText("ABC", Helvetica, 1000) ≈ 2056  (got %.1f)', [WABC]));

    // Times-Roman 'A' = 722/1000 em
    var WT := PDFMeasureText('A', 'Times-Roman', 1000);
    Check(Abs(WT - 722) < 1, Format('PDFMeasureText("A", Times-Roman, 1000) ≈ 722  (got %.1f)', [WT]));
  except
    on E: Exception do
      Fail('PDFMeasureText raised ' + E.ClassName, E.Message);
  end;

  // --- DrawTextWrapped visual PDF test ---
  Builder := TPDFBuilder.Create;
  Content := TPDFContentBuilder.Create;
  try
    try
      Page := Builder.AddPage(PDF_A4_WIDTH, PDF_A4_HEIGHT);
      Builder.AddStandardFont(Page, 'F1', 'Helvetica');
      Builder.AddStandardFont(Page, 'F2', 'Helvetica-Bold');

      // Title
      Content.BeginText;
      Content.SetFont('F2', 16);
      Content.SetTextMatrix(1, 0, 0, 1, 50, 800);
      Content.ShowText('T13 — DrawTextWrapped Demo');
      Content.EndText;

      // Left-aligned body (default)
      var NextY := Content.DrawTextWrapped(50, 770, ColumnW, 16,
        BodyText, 'F1', 'Helvetica', 12, 0);

      // Centered short note
      Content.DrawTextWrapped(50, NextY - 10, ColumnW, 14,
        'Centered: Lorem ipsum dolor sit amet, consectetur adipiscing elit.', 'F1', 'Helvetica', 11, 1);

      // Right-aligned note
      Content.DrawTextWrapped(50, NextY - 50, ColumnW, 14,
        'Right-aligned text in the same column width.', 'F1', 'Helvetica', 11, 2);

      // Hard newline test
      Content.DrawTextWrapped(50, NextY - 90, ColumnW, 14,
        'Line one.'#10'Line two.'#10'Line three.', 'F1', 'Helvetica', 11, 0);

      Page.SetBytes('Contents', Content.Build);

      // Verify the content stream contains multiple Tm operators (one per wrapped line)
      S := TEncoding.ASCII.GetString(Content.Build);
      var TmCount := 0;
      var P2 := 1;
      repeat
        P2 := PosEx(' Tm', S, P2);
        if P2 > 0 then
        begin
          Inc(TmCount);
          Inc(P2, 3);
        end;
      until P2 = 0;
      Check(TmCount >= 5, Format('Content has ≥5 Tm operators (wrapped lines)  (got %d)', [TmCount]));

      Builder.SaveToFile(OutDir + 'test_writer_wrap.pdf');
      Pass('SaveToFile test_writer_wrap.pdf');
    except
      on E: Exception do
        Fail('DrawTextWrapped raised ' + E.ClassName, E.Message);
    end;
  finally
    Content.Free;
    Builder.Free;
  end;
end;

// =========================================================================
// T14 — DrawTableGrid
// =========================================================================

procedure TestDrawTableGrid;
const
  ColW:     array[0..3]  of Single = (120, 100, 130, 145);
  RowH:     array[0..4]  of Single = (22, 18, 18, 18, 18);
  CellData: array[0..19] of string = (
    'Product', 'Qty', 'Unit Price', 'Total',
    'Widget A', '10',  '$5.00',    '$50.00',
    'Widget B', '3',   '$12.50',   '$37.50',
    'Gadget X', '7',   '$8.00',    '$56.00',
    'Gizmo Z',  '1',   '$199.99',  '$199.99'
  );
var
  Builder : TPDFBuilder;
  Content : TPDFContentBuilder;
  Page    : TPDFDictionary;
  S       : string;
  BotY    : Single;
begin
  Section('T14 — DrawTableGrid');
  Builder := TPDFBuilder.Create;
  Content := TPDFContentBuilder.Create;
  try
    try
      Page := Builder.AddPage(PDF_A4_WIDTH, PDF_A4_HEIGHT);
      Builder.AddStandardFont(Page, 'F1', 'Helvetica');
      Builder.AddStandardFont(Page, 'FB', 'Helvetica-Bold');

      // Title
      Content.BeginText;
      Content.SetFont('FB', 14);
      Content.SetTextMatrix(1, 0, 0, 1, 50, 800);
      Content.ShowText('T14 — DrawTableGrid Demo');
      Content.EndText;

      BotY := Content.DrawTableGrid(50, 760,
        ColW, RowH, CellData,
        'F1', 'Helvetica', 10,
        4, 3,
        1);

      Check(BotY < 760, Format('Table bottom Y < top Y  (%.1f < 760)', [BotY]));
      var ExpectedH: Single := 22 + 18 + 18 + 18 + 18;
      Check(Abs((760 - BotY) - ExpectedH) < 1,
        Format('Table height = %.0f  (got %.1f)', [ExpectedH, 760 - BotY]));

      // Verify grid lines and text operators in the content stream
      S := TEncoding.ASCII.GetString(Content.Build);
      Check(Pos(' m'#10, S) > 0, 'Content has moveto (m) for grid lines');
      Check(Pos(' l'#10, S) > 0, 'Content has lineto (l) for grid lines');
      Check(Pos(' S'#10, S) > 0, 'Content has Stroke (S) for grid lines');
      Check(Pos('BT'#10, S) > 0, 'Content has BT block for cell text');
      Check(ContainsStr(S, '(Product)'), 'Header cell "Product" in stream');
      Check(ContainsStr(S, '(Widget A)'), 'Data cell "Widget A" in stream');

      // Truncation: a string wider than a narrow column must get '...' appended
      var TruncCB := TPDFContentBuilder.Create;
      try
        TruncCB.DrawTableGrid(50, 400,
          [50.0], [20.0],
          ['This long text definitely overflows the fifty point column'],
          'F1', 'Helvetica', 10, 4, 3, 0);
        var TS := TEncoding.ASCII.GetString(TruncCB.Build);
        Check(ContainsStr(TS, '...'), 'Long text in narrow column gets "..." truncation');
        Check(not ContainsStr(TS, 'definitely overflows'),
          'Overflow portion is clipped from stream');
      finally
        TruncCB.Free;
      end;

      Page.SetBytes('Contents', Content.Build);
      Builder.SaveToFile(OutDir + 'test_writer_table.pdf');
      Pass('SaveToFile test_writer_table.pdf');
    except
      on E: Exception do
        Fail('DrawTableGrid raised ' + E.ClassName, E.Message);
    end;
  finally
    Content.Free;
    Builder.Free;
  end;
end;

// =========================================================================
// Main
// =========================================================================

begin
  OutDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));

  WriteLn('======================================================');
  WriteLn(' TestWriter — PDF Library Writer Validation');
  WriteLn('======================================================');
  WriteLn(' Output dir: ', OutDir);

  TestMinimalCreate;
  TestMetadataRoundTrip;
  TestMultiPage;
  TestTextRoundTrip;
  TestContentBuilderOutput;
  TestContentBuilderExtras;
  TestCompressedPDF;
  TestObjectSerializer;
  TestComplexPage;
  TestWriteOptions;
  TestImageEmbedding;
  TestAddStandardFont;
  TestDrawTextWrapped;
  TestDrawTableGrid;

  WriteLn;
  WriteLn('======================================================');
  WriteLn(Format(' TOTAL: %d passed,  %d failed', [PassCount, FailCount]));
  WriteLn('======================================================');

  // List generated PDF files
  WriteLn;
  WriteLn('PDFs generados en: ', OutDir);
  var PDFFiles: TArray<string> := [
    'test_writer_minimal.pdf',
    'test_writer_meta.pdf',
    'test_writer_multi.pdf',
    'test_writer_text.pdf',
    'test_writer_uncomp.pdf',
    'test_writer_comp.pdf',
    'test_writer_complex.pdf',
    'test_writer_images.pdf',
    'test_writer_stdfont.pdf',
    'test_writer_wrap.pdf',
    'test_writer_table.pdf'
  ];
  for var F in PDFFiles do
  begin
    var Full := OutDir + F;
    if FileExists(Full) then
      WriteLn(Format('  [OK]   %s  (%d bytes)', [F, TFile.GetSize(Full)]))
    else
      WriteLn(Format('  [???]  %s  (no generado)', [F]));
  end;

  if FailCount > 0 then ExitCode := 1;

  WriteLn;
  WriteLn('Press Enter...');
  ReadLn;
end.
