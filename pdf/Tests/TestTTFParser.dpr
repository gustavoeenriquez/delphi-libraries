program TestTTFParser;

// Tests for uPDF.TTFParser — Phase 1 of TTF/OTF font embedding.
// Uses Windows system fonts (arial.ttf, calibri.ttf) as fixtures;
// each test section skips gracefully if the font file is absent.

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}
{$R *.res}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Math,
  System.Generics.Collections,
  uPDF.Errors    in '..\Src\Core\uPDF.Errors.pas',
  uPDF.TTFParser in '..\Src\Core\uPDF.TTFParser.pas';

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

procedure Check(ACond: Boolean; const AMsg: string; const ADetail: string = '');
begin
  if ACond then Pass(AMsg) else Fail(AMsg, ADetail);
end;

procedure Section(const ATitle: string);
begin
  WriteLn;
  WriteLn('=== ', ATitle, ' ===');
end;

// =========================================================================
// T01 — Parse: structural validity and basic properties
// =========================================================================

procedure TestParse(const APath, ALabel: string);
var
  Parser: TTTFParser;
  Bytes:  TBytes;
  OK:     Boolean;
begin
  Section('T01 — Parse: ' + ALabel);
  Bytes  := TFile.ReadAllBytes(APath);
  Parser := TTTFParser.Create(Bytes);
  try
    try
      OK := Parser.Parse;
      Check(OK, 'Parse returns True (valid + embeddable)');
      Check(Parser.Valid, 'Valid = True');
      Check(Parser.EmbeddingPermitted, 'EmbeddingPermitted = True');
      Check(not Parser.IsCFF, 'IsCFF = False (TTF, not CFF/OTF)');

      Check(Parser.PSName <> '', Format('PSName non-empty  ("%s")', [Parser.PSName]));
      Check(Parser.FamilyName <> '', Format('FamilyName non-empty  ("%s")', [Parser.FamilyName]));

      Check(Parser.Metrics.UnitsPerEm > 0,
        Format('UnitsPerEm > 0  (got %d)', [Parser.Metrics.UnitsPerEm]));
      var UPM := Parser.Metrics.UnitsPerEm;
      Check((UPM = 256) or (UPM = 512) or (UPM = 1000) or (UPM = 2048),
        Format('UnitsPerEm is a common value  (got %d)', [UPM]));

      Check(Parser.Metrics.Ascender > 0,
        Format('Ascender > 0  (got %d)', [Parser.Metrics.Ascender]));
      Check(Parser.Metrics.Descender < 0,
        Format('Descender < 0  (got %d)', [Parser.Metrics.Descender]));
      Check(Parser.Metrics.CapHeight > 0,
        Format('CapHeight > 0  (got %d)', [Parser.Metrics.CapHeight]));

      Check(Parser.Metrics.XMax > Parser.Metrics.XMin,
        Format('BBox XMax > XMin  (%d > %d)',
               [Parser.Metrics.XMax, Parser.Metrics.XMin]));
      Check(Parser.Metrics.YMax > Parser.Metrics.YMin,
        Format('BBox YMax > YMin  (%d > %d)',
               [Parser.Metrics.YMax, Parser.Metrics.YMin]));

      Check(Parser.NumGlyphs > 100,
        Format('NumGlyphs > 100  (got %d)', [Parser.NumGlyphs]));

      WriteLn(Format('  UnitsPerEm=%d  Glyphs=%d  Asc=%d  Desc=%d  Cap=%d',
        [Parser.Metrics.UnitsPerEm, Parser.NumGlyphs,
         Parser.Metrics.Ascender, Parser.Metrics.Descender,
         Parser.Metrics.CapHeight]));
      WriteLn(Format('  PSName="%s"  Family="%s"',
        [Parser.PSName, Parser.FamilyName]));
      WriteLn(Format('  Bold=%s  Italic=%s  FixedPitch=%s  CFF=%s',
        [BoolToStr(Parser.Metrics.IsBold,   True),
         BoolToStr(Parser.Metrics.IsItalic, True),
         BoolToStr(Parser.Metrics.IsFixedPitch, True),
         BoolToStr(Parser.IsCFF, True)]));

    except
      on E: Exception do
        Fail('Parse raised ' + E.ClassName, E.Message);
    end;
  finally
    Parser.Free;
  end;
end;

// =========================================================================
// T02 — CharToGlyph: basic Latin characters must be mapped
// =========================================================================

procedure TestCharToGlyph(const APath, ALabel: string);
const
  // Characters that every Latin font must have
  MustHave: array[0..9] of Cardinal = (
    Ord(' '),    // space
    Ord('A'), Ord('Z'),
    Ord('a'), Ord('z'),
    Ord('0'), Ord('9'),
    Ord('.'), Ord(','),
    Ord('?')
  );
  MustHaveNames: array[0..9] of string = (
    'space','A','Z','a','z','0','9','.', ',', '?'
  );
  // Characters that should NOT be mapped (non-characters / surrogates)
  MustMiss: array[0..2] of Cardinal = ($FFFE, $FFFF, $D800);
  MustMissNames: array[0..2] of string = ('U+FFFE','U+FFFF','U+D800(surrogate)');
var
  Parser: TTTFParser;
  I: Integer;
  GID: Word;
begin
  Section('T02 — CharToGlyph: ' + ALabel);
  Parser := TTTFParser.Create(TFile.ReadAllBytes(APath));
  try
    try
      if not Parser.Parse then begin Fail('Parse failed — skipping T02'); Exit; end;

      for I := 0 to High(MustHave) do
      begin
        GID := Parser.CharToGlyph(MustHave[I]);
        Check(GID <> 0,
          Format('CharToGlyph(%s) → GlyphID %d (non-zero)',
                 [MustHaveNames[I], GID]));
      end;

      for I := 0 to High(MustMiss) do
      begin
        GID := Parser.CharToGlyph(MustMiss[I]);
        Check(GID = 0,
          Format('CharToGlyph(%s) = 0 (unmapped)',
                 [MustMissNames[I]]),
          Format('got %d', [GID]));
      end;

      // Verify CmapEntries dictionary size is reasonable
      Check(Parser.CmapEntries.Count > 50,
        Format('CmapEntries count > 50  (got %d)', [Parser.CmapEntries.Count]));
      WriteLn(Format('  Total mapped codepoints: %d', [Parser.CmapEntries.Count]));

    except
      on E: Exception do
        Fail('CharToGlyph raised ' + E.ClassName, E.Message);
    end;
  finally
    Parser.Free;
  end;
end;

// =========================================================================
// T03 — GlyphAdvanceWidth: widths must be positive and within bounds
// =========================================================================

procedure TestGlyphWidths(const APath, ALabel: string);
var
  Parser:   TTTFParser;
  GID_A, GID_I, GID_M: Word;
  W_A, W_I, W_M:       Word;
  UPM: Word;
begin
  Section('T03 — GlyphAdvanceWidth: ' + ALabel);
  Parser := TTTFParser.Create(TFile.ReadAllBytes(APath));
  try
    try
      if not Parser.Parse then begin Fail('Parse failed — skipping T03'); Exit; end;
      UPM := Parser.Metrics.UnitsPerEm;

      GID_A := Parser.CharToGlyph(Ord('A'));
      GID_I := Parser.CharToGlyph(Ord('I'));
      GID_M := Parser.CharToGlyph(Ord('M'));

      if GID_A > 0 then
      begin
        W_A := Parser.GlyphAdvanceWidth(GID_A);
        Check(W_A > 0, Format('Width("A") > 0  (got %d)', [W_A]));
        Check(W_A < UPM * 3,
          Format('Width("A") < 3×UPM  (got %d, UPM=%d)', [W_A, UPM]));
      end;

      if (GID_I > 0) and (GID_M > 0) then
      begin
        W_I := Parser.GlyphAdvanceWidth(GID_I);
        W_M := Parser.GlyphAdvanceWidth(GID_M);
        // In a proportional font, M is usually wider than I
        if not Parser.Metrics.IsFixedPitch then
          Check(W_M > W_I,
            Format('Width("M") > Width("I") in proportional font  (%d > %d)',
                   [W_M, W_I]));
        WriteLn(Format('  Width "I"=%d  "A"=%d  "M"=%d  UPM=%d',
          [W_I, W_A, W_M, UPM]));
      end;

      // Width of GlyphID 0 (notdef) must be accessible without crash
      var W0 := Parser.GlyphAdvanceWidth(0);
      Pass(Format('GlyphAdvanceWidth(0) = %d (no crash)', [W0]));

      // Out-of-range ID should return 0 (not crash)
      var WOut := Parser.GlyphAdvanceWidth($FFFE);
      Check(WOut = 0, 'GlyphAdvanceWidth($FFFE) = 0 (out-of-range)');

    except
      on E: Exception do
        Fail('GlyphAdvanceWidth raised ' + E.ClassName, E.Message);
    end;
  finally
    Parser.Free;
  end;
end;

// =========================================================================
// T04 — GlyphOffset / GlyphLength: subsetter data access
// =========================================================================

procedure TestGlyphBounds(const APath, ALabel: string);
var
  Parser:   TTTFParser;
  GID_A:    Word;
  Off, Len: Cardinal;
begin
  Section('T04 — GlyphOffset/Length: ' + ALabel);
  Parser := TTTFParser.Create(TFile.ReadAllBytes(APath));
  try
    try
      if not Parser.Parse then begin Fail('Parse failed — skipping T04'); Exit; end;
      if Parser.IsCFF then
      begin
        Pass('CFF font — GlyphOffset/Length are 0 (subsetter handles CFF separately)');
        Exit;
      end;

      GID_A := Parser.CharToGlyph(Ord('A'));
      if GID_A = 0 then begin Fail('CharToGlyph("A") = 0'); Exit; end;

      Off := Parser.GlyphOffset(GID_A);
      Len := Parser.GlyphLength(GID_A);

      Check(Off > 0, Format('GlyphOffset("A") > 0  (got %d)', [Off]));
      Check(Len > 0, Format('GlyphLength("A") > 0  (got %d)', [Len]));
      Check(Off + Len <= Cardinal(Length(Parser.RawData)),
        Format('Offset+Length within file bounds  (%d+%d <= %d)',
               [Off, Len, Length(Parser.RawData)]));

      WriteLn(Format('  Glyph "A" (ID=%d): offset=%d  length=%d', [GID_A, Off, Len]));

      // Glyph 0 (notdef) must also be accessible
      var Off0 := Parser.GlyphOffset(0);
      Pass(Format('GlyphOffset(0) = %d (no crash)', [Off0]));

      // Out-of-range must return 0 without crash
      Check(Parser.GlyphOffset($FFFE) = 0, 'GlyphOffset($FFFE) = 0');
      Check(Parser.GlyphLength($FFFE) = 0, 'GlyphLength($FFFE) = 0');

    except
      on E: Exception do
        Fail('GlyphOffset/Length raised ' + E.ClassName, E.Message);
    end;
  finally
    Parser.Free;
  end;
end;

// =========================================================================
// T05 — HasTable / GetTable: raw table access
// =========================================================================

procedure TestTableAccess(const APath, ALabel: string);
const
  RequiredTags: array[0..6] of string = (
    'head', 'hhea', 'maxp', 'hmtx', 'cmap', 'name', 'OS/2');
  OptionalTags:  array[0..1] of string = ('kern', 'post');
var
  Parser: TTTFParser;
  Tag:    string;
  Tbl:    TBytes;
begin
  Section('T05 — HasTable/GetTable: ' + ALabel);
  Parser := TTTFParser.Create(TFile.ReadAllBytes(APath));
  try
    try
      if not Parser.Parse then begin Fail('Parse failed — skipping T05'); Exit; end;

      for Tag in RequiredTags do
        Check(Parser.HasTable(Tag), Format('HasTable("%s") = True', [Tag]));

      for Tag in OptionalTags do
        Pass(Format('HasTable("%s") = %s (optional)',
                    [Tag, BoolToStr(Parser.HasTable(Tag), True)]));

      // GetTable must return non-empty bytes for a present table
      Tbl := Parser.GetTable('head');
      Check(Length(Tbl) >= 54, Format('GetTable("head") length >= 54  (got %d)', [Length(Tbl)]));

      Tbl := Parser.GetTable('hmtx');
      Check(Length(Tbl) > 0, Format('GetTable("hmtx") non-empty  (got %d)', [Length(Tbl)]));

      // Absent table must return empty (not crash)
      Tbl := Parser.GetTable('ZZZZ');
      Check(Length(Tbl) = 0, 'GetTable("ZZZZ") returns empty array');

    except
      on E: Exception do
        Fail('HasTable/GetTable raised ' + E.ClassName, E.Message);
    end;
  finally
    Parser.Free;
  end;
end;

// =========================================================================
// T06 — Metrics sanity: scaled values are in expected ranges
// =========================================================================

procedure TestMetricsSanity(const APath, ALabel: string);
var
  Parser: TTTFParser;
  M:      TTTFMetrics;
  UPM:    Single;
begin
  Section('T06 — Metrics sanity: ' + ALabel);
  Parser := TTTFParser.Create(TFile.ReadAllBytes(APath));
  try
    try
      if not Parser.Parse then begin Fail('Parse failed — skipping T06'); Exit; end;
      M   := Parser.Metrics;
      UPM := M.UnitsPerEm;

      // Ascender should be 50–95% of UPM (typical range for Latin fonts)
      var AscRatio := M.Ascender / UPM;
      Check((AscRatio > 0.5) and (AscRatio < 1.0),
        Format('Ascender/UPM in (0.5, 1.0)  (got %.3f)', [AscRatio]));

      // Descender should be negative, abs value < 50% of UPM
      var DescRatio := Abs(M.Descender) / UPM;
      Check((M.Descender < 0) and (DescRatio < 0.5),
        Format('Descender < 0 and |Descender|/UPM < 0.5  (got %.3f)', [DescRatio]));

      // CapHeight: 0 < CapHeight <= Ascender
      Check((M.CapHeight > 0) and (M.CapHeight <= M.Ascender),
        Format('0 < CapHeight <= Ascender  (%d, %d)', [M.CapHeight, M.Ascender]));

      // Italic angle: −90 to +90 degrees (virtually always −45 to 0)
      Check((M.ItalicAngle >= -90) and (M.ItalicAngle <= 90),
        Format('ItalicAngle in [-90, 90]  (got %.4f)', [M.ItalicAngle]));

      // PDF-scaled values (1000/UPM): ascender > 500, descender < -50
      var AscPDF  := Round(M.Ascender  * 1000 / UPM);
      var DescPDF := Round(M.Descender * 1000 / UPM);
      var CapPDF  := Round(M.CapHeight * 1000 / UPM);
      WriteLn(Format('  PDF-scaled (1000/em): Asc=%d  Desc=%d  Cap=%d',
        [AscPDF, DescPDF, CapPDF]));
      Check(AscPDF  >  400, Format('PDF Ascender > 400  (got %d)',   [AscPDF]));
      Check(DescPDF < -50,  Format('PDF Descender < -50  (got %d)',  [DescPDF]));
      Check(CapPDF  >  300, Format('PDF CapHeight > 300  (got %d)',  [CapPDF]));

    except
      on E: Exception do
        Fail('Metrics sanity raised ' + E.ClassName, E.Message);
    end;
  finally
    Parser.Free;
  end;
end;

// =========================================================================
// T07 — Error handling: invalid input must not crash or leak
// =========================================================================

procedure TestErrorHandling;
var
  Parser: TTTFParser;
  Empty:  TBytes;
  Junk:   TBytes;
begin
  Section('T07 — Error handling: invalid inputs');
  try
    // Empty bytes
    SetLength(Empty, 0);
    Parser := TTTFParser.Create(Empty);
    try
      var OK := Parser.Parse;
      Check(not OK, 'Parse(empty) returns False');
      Check(not Parser.Valid, 'Valid = False after empty input');
    finally Parser.Free; end;

    // Random junk bytes
    SetLength(Junk, 100);
    FillChar(Junk[0], 100, $AB);
    Parser := TTTFParser.Create(Junk);
    try
      var OK := Parser.Parse;
      Check(not OK, 'Parse(junk) returns False');
    finally Parser.Free; end;

    // Truncated TTF header (valid magic, too short for table directory)
    var Truncated: TBytes;
    SetLength(Truncated, 8);
    // sfVersion = $00010000
    Truncated[0] := $00; Truncated[1] := $01; Truncated[2] := $00; Truncated[3] := $00;
    // numTables = 10 (but no table entries follow)
    Truncated[4] := $00; Truncated[5] := $0A;
    Truncated[6] := $00; Truncated[7] := $00;
    Parser := TTTFParser.Create(Truncated);
    try
      var OK := Parser.Parse;
      Check(not OK, 'Parse(truncated) returns False');
    finally Parser.Free; end;

    Pass('All invalid-input cases handled without exception leak');
  except
    on E: Exception do
      Fail('Error handling raised unexpected ' + E.ClassName, E.Message);
  end;
end;

// =========================================================================
// T08 — Courier New (monospaced): fixed-pitch flag and equal widths
// =========================================================================

procedure TestCourierNew(const APath: string);
var
  Parser: TTTFParser;
  W_A, W_I, W_M, W_Space: Word;
begin
  Section('T08 — Courier New (monospaced)');
  Parser := TTTFParser.Create(TFile.ReadAllBytes(APath));
  try
    try
      if not Parser.Parse then begin Fail('Parse failed — skipping T08'); Exit; end;

      Check(Parser.Metrics.IsFixedPitch,
        'IsFixedPitch = True for Courier New');

      W_A     := Parser.GlyphAdvanceWidth(Parser.CharToGlyph(Ord('A')));
      W_I     := Parser.GlyphAdvanceWidth(Parser.CharToGlyph(Ord('I')));
      W_M     := Parser.GlyphAdvanceWidth(Parser.CharToGlyph(Ord('M')));
      W_Space := Parser.GlyphAdvanceWidth(Parser.CharToGlyph(Ord(' ')));

      Check(W_A = W_I,
        Format('Width("A") = Width("I") in monospace  (%d = %d)', [W_A, W_I]));
      Check(W_A = W_M,
        Format('Width("A") = Width("M") in monospace  (%d = %d)', [W_A, W_M]));
      Check(W_A = W_Space,
        Format('Width("A") = Width(space) in monospace  (%d = %d)', [W_A, W_Space]));

      WriteLn(Format('  All glyphs width = %d / %d UPM  (%.1f%%)',
        [W_A, Parser.Metrics.UnitsPerEm,
         W_A * 100.0 / Parser.Metrics.UnitsPerEm]));

    except
      on E: Exception do
        Fail('CourierNew test raised ' + E.ClassName, E.Message);
    end;
  finally
    Parser.Free;
  end;
end;

// =========================================================================
// Main
// =========================================================================

const
  FONT_ARIAL   = 'C:\Windows\Fonts\arial.ttf';
  FONT_CALIBRI = 'C:\Windows\Fonts\calibri.ttf';
  FONT_COURIER = 'C:\Windows\Fonts\cour.ttf';

begin
  WriteLn('======================================================');
  WriteLn(' TestTTFParser — Phase 1 Validation');
  WriteLn('======================================================');

  // T07 does not need a font file — always runs
  TestErrorHandling;

  if FileExists(FONT_ARIAL) then
  begin
    TestParse(FONT_ARIAL, 'Arial Regular');
    TestCharToGlyph(FONT_ARIAL, 'Arial Regular');
    TestGlyphWidths(FONT_ARIAL, 'Arial Regular');
    TestGlyphBounds(FONT_ARIAL, 'Arial Regular');
    TestTableAccess(FONT_ARIAL, 'Arial Regular');
    TestMetricsSanity(FONT_ARIAL, 'Arial Regular');
  end else
    WriteLn('  [SKIP] ', FONT_ARIAL, ' not found');

  if FileExists(FONT_CALIBRI) then
  begin
    TestParse(FONT_CALIBRI, 'Calibri Regular');
    TestCharToGlyph(FONT_CALIBRI, 'Calibri Regular');
    TestGlyphWidths(FONT_CALIBRI, 'Calibri Regular');
    TestMetricsSanity(FONT_CALIBRI, 'Calibri Regular');
  end else
    WriteLn('  [SKIP] ', FONT_CALIBRI, ' not found');

  if FileExists(FONT_COURIER) then
    TestCourierNew(FONT_COURIER)
  else
    WriteLn('  [SKIP] ', FONT_COURIER, ' not found');

  WriteLn;
  WriteLn('======================================================');
  WriteLn(Format(' TOTAL: %d passed,  %d failed', [PassCount, FailCount]));
  WriteLn('======================================================');
  if FailCount > 0 then ExitCode := 1;
  WriteLn('Press Enter...');
  ReadLn;
end.
