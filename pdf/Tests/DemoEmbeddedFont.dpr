program DemoEmbeddedFont;

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}

// ============================================================================
// Phase 5 — End-to-end visual validation
// Produces a 3-page PDF with embedded TrueType fonts and opens it.
// ============================================================================

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.IOUtils, System.Math,
  WinAPI.Windows, WinAPI.ShellAPI,
  uPDF.Types, uPDF.Errors, uPDF.Objects,
  uPDF.TTFParser, uPDF.TTFSubset, uPDF.EmbeddedFont, uPDF.Writer;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function LoadFont(const AFileName: string): TBytes;
var
  F: TFileStream;
begin
  Result := nil;
  var Path := 'C:\Windows\Fonts\' + AFileName;
  if not FileExists(Path) then Exit;
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then F.Read(Result[0], F.Size);
  finally
    F.Free;
  end;
end;

// Return unique glyph IDs for the full printable ASCII range (chars 32-126).
// Always includes GID 0 (notdef) as first entry.
function BuildASCIIGIDs(AParser: TTTFParser): TArray<Word>;
var
  Seen : TDictionary<Word, Boolean>;
  List : TList<Word>;
  GID  : Word;
begin
  Seen := TDictionary<Word, Boolean>.Create;
  List := TList<Word>.Create;
  try
    Seen.Add(0, True); List.Add(0);
    for var CP := 32 to 126 do
    begin
      GID := AParser.CharToGlyph(Cardinal(CP));
      if (GID > 0) and not Seen.ContainsKey(GID) then
      begin
        Seen.Add(GID, True);
        List.Add(GID);
      end;
    end;
    Result := List.ToArray;
  finally
    List.Free;
    Seen.Free;
  end;
end;

procedure AttachContent(APage: TPDFDictionary; ACB: TPDFContentBuilder);
var
  Stm: TPDFStream;
begin
  Stm := TPDFStream.Create;
  try
    Stm.SetRawData(ACB.Build);
    APage.SetValue('Contents', Stm);
  except
    Stm.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// Page 1 — Embedded Arial: title, body paragraphs, decorative text
// ---------------------------------------------------------------------------

procedure BuildPage1(APage: TPDFDictionary; AFont: TTTFEmbeddedFont);
const
  X = 72.0;
var
  CB  : TPDFContentBuilder;
  WFox: Single;
begin
  CB := TPDFContentBuilder.Create;
  try
    // ---- Title -------------------------------------------------------
    CB.BeginText;
    CB.SetFont('EF1', 28);
    CB.SetTextMatrix(1, 0, 0, 1, X, 762);
    CB.ShowTextHex(AFont.EncodeTextHex('TTF Font Embedding Demo'));
    CB.EndText;

    // Decorative rule
    CB.SetStrokeRGB(0.25, 0.45, 0.70);
    CB.SetLineWidth(1.5);
    CB.DrawLine(X, 751, 595 - X, 751);

    // ---- Subtitle ----------------------------------------------------
    CB.BeginText;
    CB.SetFillRGB(0.3, 0.3, 0.5);
    CB.SetFont('EF1', 13);
    CB.SetTextMatrix(1, 0, 0, 1, X, 734);
    CB.ShowTextHex(AFont.EncodeTextHex(
      'Pure Delphi  |  Identity-H  |  CIDFontType2  |  ISO 32000'));
    CB.EndText;

    // ---- Body paragraphs ---------------------------------------------
    CB.SetFillRGB(0.08, 0.08, 0.08);
    CB.BeginText;
    CB.SetFont('EF1', 11);
    var Body: array[0..7] of string;
    Body[0] := 'This document was generated entirely from scratch using a pure-Delphi';
    Body[1] := 'PDF library with no third-party dependencies or runtime components.';
    Body[2] := '';
    Body[3] := 'The text you are reading is rendered with an embedded subset of the';
    Body[4] := 'Arial TrueType font. Only the glyphs actually used in the document';
    Body[5] := 'are included, keeping the file size small.';
    Body[6] := '';
    Body[7] := 'Glyph IDs are encoded as big-endian 2-byte hex strings per ISO 32000.';
    for var L := 0 to High(Body) do
    begin
      CB.SetTextMatrix(1, 0, 0, 1, X, 706 - L * 16);
      if Body[L] <> '' then
        CB.ShowTextHex(AFont.EncodeTextHex(Body[L]));
    end;
    CB.EndText;

    // ---- Decorative big text -----------------------------------------
    CB.SetFillRGB(0.75, 0.82, 0.95);
    CB.BeginText;
    CB.SetFont('EF1', 54);
    CB.SetTextMatrix(1, 0, 0, 1, X, 465);
    CB.ShowTextHex(AFont.EncodeTextHex('Typography'));
    CB.EndText;

    // ---- Metrics info ------------------------------------------------
    WFox := AFont.MeasureText('The quick brown fox jumps over the lazy dog', 12.0);
    CB.SetFillRGB(0.35, 0.35, 0.35);
    CB.BeginText;
    CB.SetFont('EF1', 9);
    CB.SetTextMatrix(1, 0, 0, 1, X, 444);
    CB.ShowTextHex(AFont.EncodeTextHex(Format(
      'MeasureText("The quick brown fox...", 12pt) = %.1f pt  |  ' +
      'GlyphCount = %d', [WFox, AFont.GlyphCount])));
    CB.EndText;

    // ---- Character grid  (A-Z at 16pt) -------------------------------
    CB.SetFillRGB(0.96, 0.97, 1.0);
    CB.Rectangle(X - 4, 370, 451, 56);
    CB.Fill;
    CB.SetStrokeRGB(0.7, 0.75, 0.85);
    CB.SetLineWidth(0.5);
    CB.Rectangle(X - 4, 370, 451, 56);
    CB.Stroke;

    CB.SetFillRGB(0.1, 0.1, 0.3);
    CB.BeginText;
    CB.SetFont('EF1', 14);
    CB.SetTextMatrix(1, 0, 0, 1, X + 4, 404);
    CB.ShowTextHex(AFont.EncodeTextHex('A B C D E F G H I J K L M N O P Q R S T U V W X Y Z'));
    CB.SetTextMatrix(1, 0, 0, 1, X + 4, 382);
    CB.ShowTextHex(AFont.EncodeTextHex('a b c d e f g h i j k l m n o p q r s t u v w x y z'));
    CB.EndText;

    CB.SetFillRGB(0.15, 0.15, 0.15);
    CB.BeginText;
    CB.SetFont('EF1', 11);
    CB.SetTextMatrix(1, 0, 0, 1, X, 350);
    CB.ShowTextHex(AFont.EncodeTextHex('0123456789  ! " # $ % & ( ) * + , - . / : ; < = > ? @ [ \ ] ^ _ { | } ~'));
    CB.EndText;

    // ---- Footer ------------------------------------------------------
    CB.SetStrokeRGB(0.7, 0.7, 0.7);
    CB.SetLineWidth(0.25);
    CB.DrawLine(X, 60, 595 - X, 60);
    CB.SetFillRGB(0.4, 0.4, 0.4);
    CB.BeginText;
    CB.SetFont('EF1', 8);
    CB.SetTextMatrix(1, 0, 0, 1, X, 48);
    CB.ShowTextHex(AFont.EncodeTextHex('Page 1 of 3  -  Arial embedded subset'));
    CB.SetTextMatrix(1, 0, 0, 1, 440, 48);
    CB.ShowTextHex(AFont.EncodeTextHex('Delphi PDF Library'));
    CB.EndText;

    AttachContent(APage, CB);
  finally
    CB.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Page 2 — Embedded Courier New: monospace / fixed-pitch showcase
// ---------------------------------------------------------------------------

procedure BuildPage2(APage: TPDFDictionary; AFont: TTTFEmbeddedFont);
const
  X = 72.0;
var
  CB: TPDFContentBuilder;
begin
  CB := TPDFContentBuilder.Create;
  try
    // ---- Title -------------------------------------------------------
    CB.BeginText;
    CB.SetFillRGB(0.08, 0.08, 0.08);
    CB.SetFont('EF2', 22);
    CB.SetTextMatrix(1, 0, 0, 1, X, 762);
    CB.ShowTextHex(AFont.EncodeTextHex('Fixed-Pitch Monospace'));
    CB.EndText;

    CB.SetStrokeRGB(0.55, 0.35, 0.05);
    CB.SetLineWidth(1.5);
    CB.DrawLine(X, 751, 595 - X, 751);

    CB.BeginText;
    CB.SetFillRGB(0.4, 0.25, 0.05);
    CB.SetFont('EF2', 11);
    CB.SetTextMatrix(1, 0, 0, 1, X, 734);
    CB.ShowTextHex(AFont.EncodeTextHex(
      'Courier New  |  Advance widths equal for all glyphs'));
    CB.EndText;

    // ---- Code listing ------------------------------------------------
    CB.SetFillRGB(0.96, 0.95, 0.90);
    CB.Rectangle(X - 8, 618, 451, 108);
    CB.Fill;
    CB.SetStrokeRGB(0.75, 0.60, 0.35);
    CB.SetLineWidth(0.5);
    CB.Rectangle(X - 8, 618, 451, 108);
    CB.Stroke;

    var Code: array[0..6] of string;
    Code[0] := 'function MeasureText(const AText: string;';
    Code[1] := '  AFontSize: Single): Single;';
    Code[2] := 'begin';
    Code[3] := '  Result := 0;';
    Code[4] := '  for var I := 1 to Length(AText) do';
    Code[5] := '    Result := Result + GlyphWidth(AText[I]) * AFontSize;';
    Code[6] := 'end;';

    CB.SetFillRGB(0.05, 0.05, 0.25);
    CB.BeginText;
    CB.SetFont('EF2', 10);
    for var L := 0 to High(Code) do
    begin
      CB.SetTextMatrix(1, 0, 0, 1, X, 716 - L * 14);
      CB.ShowTextHex(AFont.EncodeTextHex(Code[L]));
    end;
    CB.EndText;

    // ---- Width demo --------------------------------------------------
    CB.SetFillRGB(0.08, 0.08, 0.08);
    CB.BeginText;
    CB.SetFont('EF2', 11);
    CB.SetTextMatrix(1, 0, 0, 1, X, 598);
    CB.ShowTextHex(AFont.EncodeTextHex(
      'All glyphs same advance width - compare narrow vs wide:'));
    CB.EndText;

    CB.SetFillRGB(0.96, 0.95, 0.90);
    CB.Rectangle(X - 4, 558, 451, 30);
    CB.Fill;

    CB.SetFillRGB(0.1, 0.1, 0.3);
    CB.BeginText;
    CB.SetFont('EF2', 16);
    CB.SetTextMatrix(1, 0, 0, 1, X + 4, 568);
    CB.ShowTextHex(AFont.EncodeTextHex('I  l  i  1  |  W  M  m  @  #  ~'));
    CB.EndText;

    // Widths annotation
    CB.SetFillRGB(0.35, 0.35, 0.35);
    CB.BeginText;
    CB.SetFont('EF2', 9);
    CB.SetTextMatrix(1, 0, 0, 1, X, 545);
    var WI := AFont.MeasureText('I', 1000.0);
    var WM := AFont.MeasureText('M', 1000.0);
    CB.ShowTextHex(AFont.EncodeTextHex(Format(
      'Width("I", 1000pt) = %.0f  |  Width("M", 1000pt) = %.0f  (equal)', [WI, WM])));
    CB.EndText;

    // ---- Alphabet line -----------------------------------------------
    CB.SetFillRGB(0.08, 0.08, 0.08);
    CB.BeginText;
    CB.SetFont('EF2', 10);
    CB.SetTextMatrix(1, 0, 0, 1, X, 515);
    CB.ShowTextHex(AFont.EncodeTextHex('The quick brown fox jumps over the lazy dog (0123456789)'));
    CB.EndText;

    // ---- Footer ------------------------------------------------------
    CB.SetStrokeRGB(0.7, 0.7, 0.7);
    CB.SetLineWidth(0.25);
    CB.DrawLine(X, 60, 595 - X, 60);
    CB.SetFillRGB(0.4, 0.4, 0.4);
    CB.BeginText;
    CB.SetFont('EF2', 8);
    CB.SetTextMatrix(1, 0, 0, 1, X, 48);
    CB.ShowTextHex(AFont.EncodeTextHex('Page 2 of 3  -  Courier New embedded subset'));
    CB.SetTextMatrix(1, 0, 0, 1, 440, 48);
    CB.ShowTextHex(AFont.EncodeTextHex('Delphi PDF Library'));
    CB.EndText;

    AttachContent(APage, CB);
  finally
    CB.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Page 3 — Standard Type1 fonts: comparison reference
// ---------------------------------------------------------------------------

procedure BuildPage3(APage: TPDFDictionary);
const
  X = 72.0;
var
  CB: TPDFContentBuilder;
begin
  CB := TPDFContentBuilder.Create;
  try
    // ---- Title (Helvetica-Bold) ---------------------------------------
    CB.BeginText;
    CB.SetFillRGB(0.08, 0.08, 0.08);
    CB.SetFont('FB', 22);
    CB.SetTextMatrix(1, 0, 0, 1, X, 762);
    CB.ShowText('Standard Type1 Font Reference');
    CB.EndText;

    CB.SetStrokeRGB(0.20, 0.55, 0.25);
    CB.SetLineWidth(1.5);
    CB.DrawLine(X, 751, 595 - X, 751);

    CB.BeginText;
    CB.SetFillRGB(0.15, 0.45, 0.20);
    CB.SetFont('F1', 13);
    CB.SetTextMatrix(1, 0, 0, 1, X, 734);
    CB.ShowText('Helvetica  |  No font data embedded  |  Viewer substitution');
    CB.EndText;

    // ---- Explanation -------------------------------------------------
    CB.SetFillRGB(0.08, 0.08, 0.08);
    CB.BeginText;
    CB.SetFont('F1', 11);
    var Lines: array[0..7] of string;
    Lines[0] := 'This page uses only the 14 standard PDF Type1 fonts - no font data';
    Lines[1] := 'is embedded in the PDF file. The viewer provides its own substitute.';
    Lines[2] := '';
    Lines[3] := 'Standard fonts are limited to Latin characters via WinAnsiEncoding.';
    Lines[4] := 'They cannot represent CJK, Arabic, or most non-Latin scripts.';
    Lines[5] := '';
    Lines[6] := 'Embedded TrueType subsets (pages 1-2) guarantee exact rendering';
    Lines[7] := 'across all viewers and platforms regardless of installed fonts.';
    for var L := 0 to High(Lines) do
    begin
      CB.SetTextMatrix(1, 0, 0, 1, X, 706 - L * 16);
      if Lines[L] <> '' then CB.ShowText(Lines[L]);
    end;
    CB.EndText;

    // ---- Comparison table header (top = 578, gap of 16pt from last body line) --
    CB.SetFillRGB(0.85, 0.93, 0.87);
    CB.Rectangle(X - 4, 556, 221, 22);
    CB.Fill;
    CB.SetFillRGB(0.87, 0.93, 1.00);
    CB.Rectangle(X + 221, 556, 226, 22);
    CB.Fill;

    CB.SetFillRGB(0.08, 0.08, 0.08);
    CB.BeginText;
    CB.SetFont('FB', 10);
    CB.SetTextMatrix(1, 0, 0, 1, X + 4, 563);
    CB.ShowText('Standard Type1 (not embedded)');
    CB.SetTextMatrix(1, 0, 0, 1, X + 228, 563);
    CB.ShowText('Embedded TrueType (pages 1-2)');
    CB.EndText;

    // ---- Comparison rows ---------------------------------------------
    var Std : array[0..4] of string;
    var Emb : array[0..4] of string;
    Std[0] := 'Latin only (WinAnsiEncoding)'; Emb[0] := 'Full Unicode support';
    Std[1] := 'No glyph data in file';        Emb[1] := 'Subset embedded in PDF';
    Std[2] := 'Viewer may substitute font';   Emb[2] := 'Exact rendering guaranteed';
    Std[3] := 'Fixed set of 14 typefaces';    Emb[3] := 'Any TTF / OTF typeface';
    Std[4] := 'No file size overhead';        Emb[4] := 'Small subset size overhead';

    CB.SetFillRGB(0.12, 0.12, 0.12);
    CB.BeginText;
    CB.SetFont('F1', 10);
    for var R := 0 to High(Std) do
    begin
      CB.SetTextMatrix(1, 0, 0, 1, X + 4, 538 - R * 15);
      CB.ShowText(Std[R]);
      CB.SetTextMatrix(1, 0, 0, 1, X + 228, 538 - R * 15);
      CB.ShowText(Emb[R]);
    end;
    CB.EndText;

    // Grid divider line
    CB.SetStrokeRGB(0.7, 0.75, 0.7);
    CB.SetLineWidth(0.3);
    CB.DrawLine(X + 224, 556, X + 224, 463);

    // ---- Standard font showcase  -------------------------------------
    CB.SetFillRGB(0.08, 0.08, 0.08);
    CB.BeginText;
    CB.SetFont('FB', 11);
    CB.SetTextMatrix(1, 0, 0, 1, X, 439);
    CB.ShowText('Standard fonts available in every PDF viewer:');
    CB.EndText;

    var Fonts: array[0..5] of string;
    Fonts[0] := 'Helvetica - The quick brown fox jumps over the lazy dog';
    Fonts[1] := 'Times-Roman - The quick brown fox jumps over the lazy dog';
    Fonts[2] := 'Courier - The quick brown fox jumps over the lazy dog';
    Fonts[3] := 'Helvetica-Bold - Bold text sample 0123456789';
    Fonts[4] := 'Times-Italic - Italic text sample 0123456789';
    Fonts[5] := 'Courier-Bold - Bold monospace 0123456789';

    var FontNames: array[0..5] of string;
    FontNames[0] := 'F1';
    FontNames[1] := 'F2';
    FontNames[2] := 'F3';
    FontNames[3] := 'FB';
    FontNames[4] := 'F4';
    FontNames[5] := 'F5';

    for var F := 0 to High(Fonts) do
    begin
      CB.BeginText;
      CB.SetFont(FontNames[F], 10);
      CB.SetTextMatrix(1, 0, 0, 1, X, 418 - F * 16);
      CB.ShowText(Fonts[F]);
      CB.EndText;
    end;

    // ---- Footer ------------------------------------------------------
    CB.SetStrokeRGB(0.7, 0.7, 0.7);
    CB.SetLineWidth(0.25);
    CB.DrawLine(X, 60, 595 - X, 60);
    CB.SetFillRGB(0.4, 0.4, 0.4);
    CB.BeginText;
    CB.SetFont('F1', 8);
    CB.SetTextMatrix(1, 0, 0, 1, X, 48);
    CB.ShowText('Page 3 of 3  -  Standard Type1 fonts (no embedding)');
    CB.SetTextMatrix(1, 0, 0, 1, 440, 48);
    CB.ShowText('Delphi PDF Library');
    CB.EndText;

    AttachContent(APage, CB);
  finally
    CB.Free;
  end;
end;

// ===========================================================================
// Main
// ===========================================================================

begin
  WriteLn('======================================================');
  WriteLn(' DemoEmbeddedFont — Phase 5 Visual Validation');
  WriteLn('======================================================');

  var ArialData   := LoadFont('arial.ttf');
  var CourierData := LoadFont('cour.ttf');

  if Length(ArialData) = 0 then
  begin
    WriteLn('ERROR: arial.ttf not found in C:\Windows\Fonts\');
    Halt(1);
  end;
  if Length(CourierData) = 0 then
  begin
    WriteLn('ERROR: cour.ttf not found in C:\Windows\Fonts\');
    Halt(1);
  end;

  var ArialParser   := TTTFParser.Create(ArialData);
  var CourierParser := TTTFParser.Create(CourierData);
  try
    if not ArialParser.Parse then
    begin
      WriteLn('ERROR: Arial TTF parse failed');
      Halt(1);
    end;
    if not CourierParser.Parse then
    begin
      WriteLn('ERROR: Courier New TTF parse failed');
      Halt(1);
    end;

    var ArialGIDs   := BuildASCIIGIDs(ArialParser);
    var CourierGIDs := BuildASCIIGIDs(CourierParser);
    WriteLn(Format('Arial subset: %d glyphs  |  Courier subset: %d glyphs',
      [Length(ArialGIDs), Length(CourierGIDs)]));

    var ArialSub   := TTTFSubsetter.Create(ArialParser,   ArialGIDs);
    var CourierSub := TTTFSubsetter.Create(CourierParser, CourierGIDs);
    try
      var Builder := TPDFBuilder.Create;
      try
        Builder.SetTitle('TTF Font Embedding Demo');
        Builder.SetAuthor('Delphi PDF Library');
        Builder.SetCreator('DemoEmbeddedFont');

        var Page1 := Builder.AddPage;
        var Page2 := Builder.AddPage;
        var Page3 := Builder.AddPage;

        // Register embedded fonts (owned by Builder after this call)
        var ArialFont   := Builder.AddEmbeddedFont(Page1, 'EF1', ArialParser, ArialSub);
        var CourierFont := Builder.AddEmbeddedFont(Page2, 'EF2', CourierParser, CourierSub);

        // Standard fonts on page 3
        Builder.AddStandardFont(Page3, 'F1', 'Helvetica');
        Builder.AddStandardFont(Page3, 'F2', 'Times-Roman');
        Builder.AddStandardFont(Page3, 'F3', 'Courier');
        Builder.AddStandardFont(Page3, 'FB', 'Helvetica-Bold');
        Builder.AddStandardFont(Page3, 'F4', 'Times-Italic');
        Builder.AddStandardFont(Page3, 'F5', 'Courier-Bold');

        // Build page contents
        Write('Building Page 1 (Arial embedded)... ');
        BuildPage1(Page1, ArialFont);
        WriteLn('done');

        Write('Building Page 2 (Courier New embedded)... ');
        BuildPage2(Page2, CourierFont);
        WriteLn('done');

        Write('Building Page 3 (Standard Type1)... ');
        BuildPage3(Page3);
        WriteLn('done');

        // Save to exe directory
        var OutDir  := ExtractFilePath(ParamStr(0));
        var OutPath := OutDir + 'demo_embedded_fonts.pdf';

        Write('Saving to ' + OutPath + '... ');
        Builder.SaveToFile(OutPath);
        WriteLn('done');

        var FileSize := TFile.GetSize(OutPath);
        WriteLn(Format('File size: %d B  (%.1f KB)', [FileSize, FileSize / 1024]));

        WriteLn('Opening in default PDF viewer...');
        ShellExecute(0, 'open', PChar(OutPath), nil, nil, SW_SHOWNORMAL);

      finally
        Builder.Free;
      end;
    finally
      ArialSub.Free;
      CourierSub.Free;
    end;
  finally
    ArialParser.Free;
    CourierParser.Free;
  end;

  WriteLn('======================================================');
  WriteLn(' Phase 5 complete — verify visually in the viewer.');
  WriteLn('======================================================');
end.
