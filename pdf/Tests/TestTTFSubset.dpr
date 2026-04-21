program TestTTFSubset;

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}

// ============================================================================
// Phase 2 validation — TTTFSubsetter
// Runs against arial.ttf, calibri.ttf, cour.ttf (skips gracefully if absent)
// ============================================================================

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  uPDF.Errors, uPDF.TTFParser, uPDF.TTFSubset;

// ---- minimal test harness --------------------------------------------------

var
  GPass, GFail: Integer;

procedure Check(ACondition: Boolean; const AMsg: string);
begin
  if ACondition then
  begin
    WriteLn('  [PASS] ', AMsg);
    Inc(GPass);
  end else
  begin
    WriteLn('  [FAIL] ', AMsg);
    Inc(GFail);
  end;
end;

function LoadFont(const AName: string): TBytes;
const DIRS: array[0..2] of string = (
  'C:\Windows\Fonts\',
  'C:\Windows\Fonts\',
  'C:\Windows\Fonts\');
var Path: string; F: TFileStream;
begin
  Result := nil;
  Path := 'C:\Windows\Fonts\' + AName;
  if not FileExists(Path) then Exit;
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then F.Read(Result[0], F.Size);
  finally F.Free; end;
end;

// ============================================================================
// T01 — basic subset: ASCII uppercase A-Z from Arial
// ============================================================================

procedure T01_BasicSubset;
var
  Data   : TBytes;
  Parser : TTTFParser;
  Sub    : TTTFSubsetter;
  SubData: TBytes;
  GIDs   : array[0..25] of Word;
  I      : Integer;
begin
  WriteLn;
  WriteLn('=== T01 — Basic subset: Arial A-Z ===');
  Data := LoadFont('arial.ttf');
  if Length(Data) = 0 then begin WriteLn('  [SKIP] arial.ttf not found'); Exit; end;

  Parser := TTTFParser.Create(Data);
  try
    if not Parser.Parse then begin WriteLn('  [SKIP] Arial parse failed'); Exit; end;

    // Collect glyph IDs for A..Z
    for I := 0 to 25 do
      GIDs[I] := Parser.CharToGlyph(Cardinal(Ord('A') + I));

    Sub := TTTFSubsetter.Create(Parser, GIDs);
    try
      // GlyphCount = 26 requested + notdef (glyph 0 may overlap if A-Z starts at 0, unlikely)
      Check(Sub.GlyphCount >= 27,
        Format('GlyphCount >= 27 (notdef + 26 letters)  got %d', [Sub.GlyphCount]));
      Check(Sub.GlyphCount <= 30,
        Format('GlyphCount <= 30 (no unexpected extras)  got %d', [Sub.GlyphCount]));
      Check(Sub.MapGlyph(0) = 0, 'MapGlyph(0) = 0 (notdef always 0)');
      var GID_A := GIDs[0];
      Check(Sub.MapGlyph(GID_A) > 0,
        Format('MapGlyph(GlyphID_A=%d) > 0', [GID_A]));
      Check(Sub.MapGlyph($FFFE) = 0, 'MapGlyph(unused) = 0');

      SubData := Sub.Build;
      Check(Length(SubData) > 0, 'Build returns non-empty bytes');
      // Valid TTF signature
      Check(Length(SubData) >= 4, 'Subset >= 4 bytes');
      if Length(SubData) >= 4 then
        Check((SubData[0] = 0) and (SubData[1] = 1) and (SubData[2] = 0) and (SubData[3] = 0),
          'Starts with sfnt signature 0x00010000');
      // Significantly smaller than original
      Check(Length(SubData) < Length(Data) div 2,
        Format('Subset (%d B) much smaller than original (%d B)', [Length(SubData), Length(Data)]));
      WriteLn(Format('  Subset size: %d B  (original: %d B)', [Length(SubData), Length(Data)]));
    finally Sub.Free; end;
  finally Parser.Free; end;
end;

// ============================================================================
// T02 — re-parse the subset and verify internal consistency
// ============================================================================

procedure T02_ReParseSubset;
var
  Data    : TBytes;
  Parser  : TTTFParser;
  Sub     : TTTFSubsetter;
  SubData : TBytes;
  SubParse: TTTFParser;
  GIDs    : array[0..25] of Word;
  I       : Integer;
  GID_A_Old, GID_A_New: Word;
begin
  WriteLn;
  WriteLn('=== T02 — Re-parse subset: Arial A-Z ===');
  Data := LoadFont('arial.ttf');
  if Length(Data) = 0 then begin WriteLn('  [SKIP] arial.ttf not found'); Exit; end;

  Parser := TTTFParser.Create(Data);
  try
    if not Parser.Parse then begin WriteLn('  [SKIP] Arial parse failed'); Exit; end;

    for I := 0 to 25 do GIDs[I] := Parser.CharToGlyph(Cardinal(Ord('A') + I));
    GID_A_Old := GIDs[0];

    Sub := TTTFSubsetter.Create(Parser, GIDs);
    try
      GID_A_New := Sub.MapGlyph(GID_A_Old);
      SubData   := Sub.Build;
    finally Sub.Free; end;
  finally Parser.Free; end;

  SubParse := TTTFParser.Create(SubData);
  try
    Check(SubParse.Parse, 'Re-parse of subset returns True (valid + embeddable)');
    Check(SubParse.Valid, 'SubParse.Valid = True');
    Check(SubParse.NumGlyphs >= 27,
      Format('SubParse.NumGlyphs >= 27  (got %d)', [SubParse.NumGlyphs]));
    Check(SubParse.NumGlyphs <= 30,
      Format('SubParse.NumGlyphs <= 30  (got %d)', [SubParse.NumGlyphs]));
    // cmap should map 'A' to GID_A_New
    var SubGlyph_A := SubParse.CharToGlyph(Ord('A'));
    Check(SubGlyph_A = GID_A_New,
      Format('cmap CharToGlyph(A) = mapped new ID  (%d = %d)', [SubGlyph_A, GID_A_New]));
    // Verify advance width preserved
    var OrigW  := TTTFParser.Create(LoadFont('arial.ttf'));
    try
      OrigW.Parse;
      var OrigAdvW := OrigW.GlyphAdvanceWidth(GID_A_Old);
      var SubAdvW  := SubParse.GlyphAdvanceWidth(GID_A_New);
      Check(OrigAdvW = SubAdvW,
        Format('Advance width A preserved: orig=%d, subset=%d', [OrigAdvW, SubAdvW]));
    finally OrigW.Free; end;
    // Verify metrics preserved
    Check(SubParse.Metrics.UnitsPerEm = 2048, 'UnitsPerEm preserved (2048)');
    Check(SubParse.Metrics.Ascender > 0, 'Ascender > 0');
    Check(SubParse.Metrics.Descender < 0, 'Descender < 0');
    WriteLn(Format('  NumGlyphs=%d  GID_A: old=%d new=%d  AdvW=%d',
      [SubParse.NumGlyphs, GID_A_Old, GID_A_New, SubParse.GlyphAdvanceWidth(GID_A_New)]));
  finally SubParse.Free; end;
end;

// ============================================================================
// T03 — composite glyph closure
// 'é' (U+00E9) is composite in Arial (e + combining accent component)
// ============================================================================

procedure T03_CompositeClosure;
var
  Data      : TBytes;
  Parser    : TTTFParser;
  Sub       : TTTFSubsetter;
  GID_E_Acc : Word;
  InputGIDs : array[0..0] of Word;
  SubData   : TBytes;
  SubParse  : TTTFParser;
begin
  WriteLn;
  WriteLn('=== T03 — Composite closure: é (U+00E9) ===');
  Data := LoadFont('arial.ttf');
  if Length(Data) = 0 then begin WriteLn('  [SKIP] arial.ttf not found'); Exit; end;

  Parser := TTTFParser.Create(Data);
  try
    if not Parser.Parse then begin WriteLn('  [SKIP] Arial parse failed'); Exit; end;

    GID_E_Acc := Parser.CharToGlyph($00E9); // é
    if GID_E_Acc = 0 then begin WriteLn('  [SKIP] é not in Arial cmap'); Exit; end;

    // Get raw glyph data to check if it's composite
    var GData := Parser.GetGlyphData(GID_E_Acc);
    if Length(GData) < 2 then begin WriteLn('  [SKIP] é has no glyph data'); Exit; end;
    var NC := SmallInt((Word(GData[0]) shl 8) or GData[1]);
    if NC >= 0 then
    begin
      // Simple glyph — closure won't add extra glyphs (font may precompose)
      WriteLn('  [INFO] é is a simple (pre-composed) glyph in this font');
      InputGIDs[0] := GID_E_Acc;
      Sub := TTTFSubsetter.Create(Parser, InputGIDs);
      try
        Check(Sub.GlyphCount = 2, Format('GlyphCount = 2 (notdef + é)  got %d', [Sub.GlyphCount]));
      finally Sub.Free; end;
      Exit;
    end;

    InputGIDs[0] := GID_E_Acc;
    Sub := TTTFSubsetter.Create(Parser, InputGIDs);
    try
      Check(Sub.GlyphCount > 2,
        Format('GlyphCount > 2 — composite components auto-added  (got %d)', [Sub.GlyphCount]));
      Check(Sub.MapGlyph(GID_E_Acc) > 0, 'é itself is in subset');

      SubData := Sub.Build;
      SubParse := TTTFParser.Create(SubData);
      try
        Check(SubParse.Parse, 'Subset with composite glyph re-parses OK');
        Check(SubParse.NumGlyphs = Sub.GlyphCount,
          Format('Re-parsed NumGlyphs matches GlyphCount (%d)', [Sub.GlyphCount]));
        // cmap should still map é to its new ID
        var NewGID := Sub.MapGlyph(GID_E_Acc);
        Check(SubParse.CharToGlyph($00E9) = NewGID,
          Format('é cmap entry preserved in subset (newGID=%d)', [NewGID]));
      finally SubParse.Free; end;

      WriteLn(Format('  GID_é=%d  Components included → total %d glyphs',
        [GID_E_Acc, Sub.GlyphCount]));
    finally Sub.Free; end;
  finally Parser.Free; end;
end;

// ============================================================================
// T04 — edge cases
// ============================================================================

procedure T04_EdgeCases;
var
  Data  : TBytes;
  Parser: TTTFParser;
  Sub   : TTTFSubsetter;
begin
  WriteLn;
  WriteLn('=== T04 — Edge cases ===');
  Data := LoadFont('arial.ttf');
  if Length(Data) = 0 then begin WriteLn('  [SKIP] arial.ttf not found'); Exit; end;

  Parser := TTTFParser.Create(Data);
  try
    if not Parser.Parse then begin WriteLn('  [SKIP] Arial parse failed'); Exit; end;

    // Empty input — only notdef
    Sub := TTTFSubsetter.Create(Parser, []);
    try
      Check(Sub.GlyphCount = 1, Format('Empty input → GlyphCount = 1 (notdef only)  got %d', [Sub.GlyphCount]));
      Check(Sub.MapGlyph(0) = 0, 'MapGlyph(0) = 0 for notdef-only subset');
      var B := Sub.Build;
      Check(Length(B) > 0, 'Build succeeds for notdef-only subset');
    finally Sub.Free; end;

    // Explicitly request glyph 0 — still just one glyph
    Sub := TTTFSubsetter.Create(Parser, [Word(0)]);
    try
      Check(Sub.GlyphCount = 1, Format('Request [0] → GlyphCount = 1  got %d', [Sub.GlyphCount]));
    finally Sub.Free; end;

    // Request a non-existent glyph ID ($FFFF)
    Sub := TTTFSubsetter.Create(Parser, [Word($FFFF)]);
    try
      // $FFFF > NumGlyphs so it gets included in set but GetGlyphData returns empty
      Check(Sub.MapGlyph(0) = 0, 'MapGlyph(notdef) = 0 even with $FFFF in input');
      var B := Sub.Build;
      Check(Length(B) > 0, 'Build does not crash for out-of-range glyph ID');
    finally Sub.Free; end;
  finally Parser.Free; end;
end;

// ============================================================================
// T05 — Calibri: advance widths and cmap preserved across subset
// ============================================================================

procedure T05_CalibriSubset;
var
  Data    : TBytes;
  Parser  : TTTFParser;
  Sub     : TTTFSubsetter;
  SubData : TBytes;
  SubParse: TTTFParser;
  GIDs    : array[0..9] of Word;
  I       : Integer;
begin
  WriteLn;
  WriteLn('=== T05 — Calibri: advance widths and cmap ===');
  Data := LoadFont('calibri.ttf');
  if Length(Data) = 0 then begin WriteLn('  [SKIP] calibri.ttf not found'); Exit; end;

  Parser := TTTFParser.Create(Data);
  try
    if not Parser.Parse then begin WriteLn('  [SKIP] Calibri parse failed'); Exit; end;

    // digits 0-9
    for I := 0 to 9 do
      GIDs[I] := Parser.CharToGlyph(Cardinal(Ord('0') + I));

    Sub := TTTFSubsetter.Create(Parser, GIDs);
    try
      SubData := Sub.Build;
      SubParse := TTTFParser.Create(SubData);
      try
        Check(SubParse.Parse, 'Calibri digit subset re-parses OK');
        // Verify each digit maps correctly and advance width is preserved
        var AllOK := True;
        for I := 0 to 9 do
        begin
          var CP     := Cardinal(Ord('0') + I);
          var OldGID := GIDs[I];
          var NewGID := Sub.MapGlyph(OldGID);
          var CmapGID := SubParse.CharToGlyph(CP);
          if CmapGID <> NewGID then AllOK := False;
          var OrigW := Parser.GlyphAdvanceWidth(OldGID);
          var SubW  := SubParse.GlyphAdvanceWidth(NewGID);
          if OrigW <> SubW then AllOK := False;
        end;
        Check(AllOK, 'All 10 digits: cmap + advance width preserved in subset');
        WriteLn(Format('  %d digit glyphs, subset size %d B', [Sub.GlyphCount - 1, Length(SubData)]));
      finally SubParse.Free; end;
    finally Sub.Free; end;
  finally Parser.Free; end;
end;

// ============================================================================
// T06 — Courier: monospaced property and isFixedPitch preserved
// ============================================================================

procedure T06_CourierSubset;
var
  Data    : TBytes;
  Parser  : TTTFParser;
  Sub     : TTTFSubsetter;
  SubData : TBytes;
  SubParse: TTTFParser;
  GIDs    : array[0..3] of Word;
begin
  WriteLn;
  WriteLn('=== T06 — Courier New: monospaced preserved ===');
  Data := LoadFont('cour.ttf');
  if Length(Data) = 0 then begin WriteLn('  [SKIP] cour.ttf not found'); Exit; end;

  Parser := TTTFParser.Create(Data);
  try
    if not Parser.Parse then begin WriteLn('  [SKIP] Courier parse failed'); Exit; end;

    GIDs[0] := Parser.CharToGlyph(Ord('A'));
    GIDs[1] := Parser.CharToGlyph(Ord('I'));
    GIDs[2] := Parser.CharToGlyph(Ord('M'));
    GIDs[3] := Parser.CharToGlyph(Ord('W'));
    Sub := TTTFSubsetter.Create(Parser, GIDs);
    try
      SubData  := Sub.Build;
      SubParse := TTTFParser.Create(SubData);
      try
        Check(SubParse.Parse, 'Courier subset re-parses OK');
        Check(SubParse.Metrics.IsFixedPitch, 'IsFixedPitch preserved in Courier subset');
        // All advance widths must be equal
        var W0 := SubParse.GlyphAdvanceWidth(Sub.MapGlyph(GIDs[0]));
        var AllEqual := True;
        for var K := 1 to 3 do
          if SubParse.GlyphAdvanceWidth(Sub.MapGlyph(GIDs[K])) <> W0 then AllEqual := False;
        Check(AllEqual, Format('All subset glyph widths equal (%d)', [W0]));
      finally SubParse.Free; end;
    finally Sub.Free; end;
  finally Parser.Free; end;
end;

// ============================================================================
// T07 — Large subset: printable ASCII (95 glyphs), re-parse roundtrip
// ============================================================================

procedure T07_LargeSubset;
var
  Data    : TBytes;
  Parser  : TTTFParser;
  Sub     : TTTFSubsetter;
  SubData : TBytes;
  SubParse: TTTFParser;
  GIDs    : TArray<Word>;
  I, N    : Integer;
  CP      : Cardinal;
begin
  WriteLn;
  WriteLn('=== T07 — Large subset: printable ASCII (32-126) from Arial ===');
  Data := LoadFont('arial.ttf');
  if Length(Data) = 0 then begin WriteLn('  [SKIP] arial.ttf not found'); Exit; end;

  Parser := TTTFParser.Create(Data);
  try
    if not Parser.Parse then begin WriteLn('  [SKIP] Arial parse failed'); Exit; end;

    SetLength(GIDs, 95);
    N := 0;
    for CP := 32 to 126 do
    begin
      var G := Parser.CharToGlyph(CP);
      if G <> 0 then begin GIDs[N] := G; Inc(N); end;
    end;
    SetLength(GIDs, N);

    Sub := TTTFSubsetter.Create(Parser, GIDs);
    try
      SubData  := Sub.Build;
      SubParse := TTTFParser.Create(SubData);
      try
        Check(SubParse.Parse, 'Large subset (printable ASCII) re-parses OK');
        Check(SubParse.NumGlyphs >= N,
          Format('NumGlyphs >= requested (%d >= %d)', [SubParse.NumGlyphs, N]));
        // All printable ASCII should map correctly
        var MissCount := 0;
        for CP := 32 to 126 do
        begin
          var OldGID := Parser.CharToGlyph(CP);
          if OldGID = 0 then Continue;
          var NewGID := Sub.MapGlyph(OldGID);
          if SubParse.CharToGlyph(CP) <> NewGID then Inc(MissCount);
        end;
        Check(MissCount = 0,
          Format('All printable ASCII cmap entries preserved (%d mismatches)', [MissCount]));
        WriteLn(Format('  %d glyphs, subset %d B, original %d B',
          [Sub.GlyphCount, Length(SubData), Length(Data)]));
      finally SubParse.Free; end;
    finally Sub.Free; end;
  finally Parser.Free; end;
end;

// ============================================================================
// Main
// ============================================================================

begin
  WriteLn('======================================================');
  WriteLn(' TestTTFSubset — Phase 2 Validation');
  WriteLn('======================================================');

  T01_BasicSubset;
  T02_ReParseSubset;
  T03_CompositeClosure;
  T04_EdgeCases;
  T05_CalibriSubset;
  T06_CourierSubset;
  T07_LargeSubset;

  WriteLn;
  WriteLn('======================================================');
  WriteLn(Format(' TOTAL: %d passed,  %d failed', [GPass, GFail]));
  WriteLn('======================================================');
  if GFail > 0 then ExitCode := 1;
end.
