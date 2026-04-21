program TestTTFEmbeddedFont;

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}

// ============================================================================
// Phase 3 validation — TTTFEmbeddedFont
// Runs against arial.ttf / cour.ttf (skips gracefully if absent)
// ============================================================================

uses
  System.SysUtils, System.Classes, System.ZLib,
  System.Generics.Collections,
  uPDF.Errors, uPDF.TTFParser, uPDF.TTFSubset, uPDF.EmbeddedFont;

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
var F: TFileStream;
begin
  Result := nil;
  var Path := 'C:\Windows\Fonts\' + AName;
  if not FileExists(Path) then Exit;
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then F.Read(Result[0], F.Size);
  finally F.Free; end;
end;

{ Returns True if the byte sequence B contains the ASCII pattern Pat. }
function BytesContain(const B: TBytes; const Pat: string): Boolean;
var I, J, Len: Integer; Ok: Boolean;
begin
  Result := False;
  Len := Length(Pat);
  if Len = 0 then Exit(True);
  for I := 0 to Length(B) - Len do
  begin
    Ok := True;
    for J := 0 to Len - 1 do
      if B[I + J] <> Byte(Ord(Pat[J + 1])) then begin Ok := False; Break; end;
    if Ok then Exit(True);
  end;
end;

// ============================================================================
// T01 — Constructor: basic properties
// ============================================================================

procedure T01_Construction;
var
  Data  : TBytes;
  Parser: TTTFParser;
  Sub   : TTTFSubsetter;
  Font  : TTTFEmbeddedFont;
  GIDs  : array[0..25] of Word;
  I     : Integer;
begin
  WriteLn;
  WriteLn('=== T01 — Construction: Arial A-Z ===');
  Data := LoadFont('arial.ttf');
  if Length(Data) = 0 then begin WriteLn('  [SKIP] arial.ttf not found'); Exit; end;

  Parser := TTTFParser.Create(Data);
  try
    if not Parser.Parse then begin WriteLn('  [SKIP] Arial parse failed'); Exit; end;

    for I := 0 to 25 do GIDs[I] := Parser.CharToGlyph(Cardinal(Ord('A') + I));
    Sub := TTTFSubsetter.Create(Parser, GIDs);
    try
      Font := TTTFEmbeddedFont.Create(Parser, Sub);
      try
        Check(Font.PSName <> '', 'PSName non-empty');
        Check(Font.FamilyName <> '', 'FamilyName non-empty');
        Check(Pos('Arial', Font.FamilyName) > 0,
          Format('FamilyName contains "Arial"  (got "%s")', [Font.FamilyName]));
        Check(Font.GlyphCount >= 27,
          Format('GlyphCount >= 27  (got %d)', [Font.GlyphCount]));
        Check(Font.GlyphCount <= 30,
          Format('GlyphCount <= 30  (got %d)', [Font.GlyphCount]));
        Check(TTTFEmbeddedFont.ObjectCount = 5, 'ObjectCount = 5');
        Check(Length(Font.SubsetTTFBytes) > 0, 'SubsetTTFBytes non-empty');
        WriteLn(Format('  PSName="%s"  FamilyName="%s"  GlyphCount=%d',
          [Font.PSName, Font.FamilyName, Font.GlyphCount]));
      finally Font.Free; end;
    finally Sub.Free; end;
  finally Parser.Free; end;
end;

// ============================================================================
// T02 — MeasureText: accumulation and proportional widths
// ============================================================================

procedure T02_MeasureText;
var
  Data  : TBytes;
  Parser: TTTFParser;
  Sub   : TTTFSubsetter;
  Font  : TTTFEmbeddedFont;
  GIDs  : array[0..25] of Word;
  I     : Integer;
begin
  WriteLn;
  WriteLn('=== T02 — MeasureText ===');
  Data := LoadFont('arial.ttf');
  if Length(Data) = 0 then begin WriteLn('  [SKIP] arial.ttf not found'); Exit; end;

  Parser := TTTFParser.Create(Data);
  try
    if not Parser.Parse then begin WriteLn('  [SKIP] Arial parse failed'); Exit; end;

    for I := 0 to 25 do GIDs[I] := Parser.CharToGlyph(Cardinal(Ord('A') + I));
    Sub := TTTFSubsetter.Create(Parser, GIDs);
    try
      Font := TTTFEmbeddedFont.Create(Parser, Sub);
      try
        var WEmpty := Font.MeasureText('', 12.0);
        Check(WEmpty = 0, 'MeasureText("") = 0');

        var WA := Font.MeasureText('A', 12.0);
        Check(WA > 0,
          Format('MeasureText("A", 12) > 0  (got %.3f)', [WA]));

        var WAA := Font.MeasureText('AA', 12.0);
        Check(Abs(WAA - 2.0 * WA) < 0.001,
          Format('MeasureText("AA") = 2×MeasureText("A")  (%.3f vs 2×%.3f)', [WAA, WA]));

        var WM := Font.MeasureText('M', 1000.0);
        var WI := Font.MeasureText('I', 1000.0);
        Check(WM > WI,
          Format('MeasureText("M") > MeasureText("I") — proportional  (M=%.1f, I=%.1f)', [WM, WI]));

        WriteLn(Format('  A=%.3f pt at 12pt;  M=%.1f vs I=%.1f at 1000pt', [WA, WM, WI]));
      finally Font.Free; end;
    finally Sub.Free; end;
  finally Parser.Free; end;
end;

// ============================================================================
// T03 — EncodeTextHex: format and GID mapping
// ============================================================================

procedure T03_EncodeTextHex;
var
  Data  : TBytes;
  Parser: TTTFParser;
  Sub   : TTTFSubsetter;
  Font  : TTTFEmbeddedFont;
  GIDs  : array[0..25] of Word;
  GID_A : Word;
  I     : Integer;
begin
  WriteLn;
  WriteLn('=== T03 — EncodeTextHex ===');
  Data := LoadFont('arial.ttf');
  if Length(Data) = 0 then begin WriteLn('  [SKIP] arial.ttf not found'); Exit; end;

  Parser := TTTFParser.Create(Data);
  try
    if not Parser.Parse then begin WriteLn('  [SKIP] Arial parse failed'); Exit; end;

    for I := 0 to 25 do GIDs[I] := Parser.CharToGlyph(Cardinal(Ord('A') + I));
    GID_A := GIDs[0];

    Sub := TTTFSubsetter.Create(Parser, GIDs);
    try
      Font := TTTFEmbeddedFont.Create(Parser, Sub);
      try
        var HexEmpty := Font.EncodeTextHex('');
        Check(HexEmpty = '<>', Format('EncodeTextHex("") = "<>"  got "%s"', [HexEmpty]));

        var HexA := Font.EncodeTextHex('A');
        Check(Length(HexA) = 6,
          Format('EncodeTextHex("A") length = 6  got %d', [Length(HexA)]));
        Check((Length(HexA) >= 1) and (HexA[1] = '<'),
          'EncodeTextHex("A") starts with "<"');
        Check((Length(HexA) >= 1) and (HexA[Length(HexA)] = '>'),
          'EncodeTextHex("A") ends with ">"');

        var GID_A_New := Sub.MapGlyph(GID_A);
        var Expected := '<' + IntToHex(GID_A_New, 4) + '>';
        Check(HexA = Expected,
          Format('EncodeTextHex("A") = "%s"  expected "%s"', [HexA, Expected]));

        var HexAB := Font.EncodeTextHex('AB');
        Check(Length(HexAB) = 10,
          Format('EncodeTextHex("AB") length = 10  got %d', [Length(HexAB)]));

        WriteLn(Format('  EncodeTextHex("A")=%s  EncodeTextHex("AB")=%s', [HexA, HexAB]));
      finally Font.Free; end;
    finally Sub.Free; end;
  finally Parser.Free; end;
end;

// ============================================================================
// T04 — BuildToUnicodeCMapText: structure and content
// ============================================================================

procedure T04_ToUnicodeCMap;
var
  Data  : TBytes;
  Parser: TTTFParser;
  Sub   : TTTFSubsetter;
  Font  : TTTFEmbeddedFont;
  GIDs  : array[0..25] of Word;
  I     : Integer;
  CMap  : string;
begin
  WriteLn;
  WriteLn('=== T04 — BuildToUnicodeCMapText ===');
  Data := LoadFont('arial.ttf');
  if Length(Data) = 0 then begin WriteLn('  [SKIP] arial.ttf not found'); Exit; end;

  Parser := TTTFParser.Create(Data);
  try
    if not Parser.Parse then begin WriteLn('  [SKIP] Arial parse failed'); Exit; end;

    for I := 0 to 25 do GIDs[I] := Parser.CharToGlyph(Cardinal(Ord('A') + I));
    Sub := TTTFSubsetter.Create(Parser, GIDs);
    try
      Font := TTTFEmbeddedFont.Create(Parser, Sub);
      try
        CMap := Font.BuildToUnicodeCMapText;

        Check(Length(CMap) > 0, 'CMap text non-empty');
        Check(Pos('beginbfchar', CMap) > 0, 'CMap contains "beginbfchar"');
        Check(Pos('endbfchar', CMap) > 0, 'CMap contains "endbfchar"');
        Check(Pos('endcmap', CMap) > 0, 'CMap contains "endcmap"');
        Check(Pos('begincodespacerange', CMap) > 0,
          'CMap contains "begincodespacerange"');
        Check(Pos('/CIDInit', CMap) > 0, 'CMap contains "/CIDInit"');
        // 'A' = U+0041 — its codepoint must appear on the right side of a mapping
        Check(Pos('<0041>', CMap) > 0, 'CMap contains "<0041>" (U+0041 = A)');

        WriteLn(Format('  CMap length: %d chars', [Length(CMap)]));
      finally Font.Free; end;
    finally Sub.Free; end;
  finally Parser.Free; end;
end;

// ============================================================================
// T05 — SubsetTTFBytes: re-parse roundtrip
// ============================================================================

procedure T05_SubsetTTFReparse;
var
  Data    : TBytes;
  Parser  : TTTFParser;
  Sub     : TTTFSubsetter;
  Font    : TTTFEmbeddedFont;
  GIDs    : array[0..25] of Word;
  I       : Integer;
  SubParse: TTTFParser;
begin
  WriteLn;
  WriteLn('=== T05 — SubsetTTFBytes re-parse ===');
  Data := LoadFont('arial.ttf');
  if Length(Data) = 0 then begin WriteLn('  [SKIP] arial.ttf not found'); Exit; end;

  Parser := TTTFParser.Create(Data);
  try
    if not Parser.Parse then begin WriteLn('  [SKIP] Arial parse failed'); Exit; end;

    for I := 0 to 25 do GIDs[I] := Parser.CharToGlyph(Cardinal(Ord('A') + I));
    Sub := TTTFSubsetter.Create(Parser, GIDs);
    try
      Font := TTTFEmbeddedFont.Create(Parser, Sub);
      try
        var SubBytes := Font.SubsetTTFBytes;
        Check(Length(SubBytes) > 0, 'SubsetTTFBytes non-empty');

        if Length(SubBytes) >= 4 then
          Check((SubBytes[0] = 0) and (SubBytes[1] = 1) and
                (SubBytes[2] = 0) and (SubBytes[3] = 0),
            'SubsetTTFBytes starts with sfnt signature 0x00010000');

        SubParse := TTTFParser.Create(SubBytes);
        try
          Check(SubParse.Parse,
            'SubsetTTFBytes re-parses as valid TTF (Parse = True)');
          Check(SubParse.NumGlyphs >= 27,
            Format('Re-parsed NumGlyphs >= 27  (got %d)', [SubParse.NumGlyphs]));
          Check(SubParse.Metrics.UnitsPerEm = 2048,
            Format('UnitsPerEm preserved (got %d)', [SubParse.Metrics.UnitsPerEm]));
          // 'A' cmap entry must survive the round-trip
          var NewGID_A := Sub.MapGlyph(GIDs[0]);
          Check(SubParse.CharToGlyph(Ord('A')) = NewGID_A,
            Format('cmap "A" entry preserved in subset  (got %d, expected %d)',
              [SubParse.CharToGlyph(Ord('A')), NewGID_A]));
          WriteLn(Format('  SubBytes=%d B  NumGlyphs=%d  UPM=%d  GID_A_new=%d',
            [Length(SubBytes), SubParse.NumGlyphs,
             SubParse.Metrics.UnitsPerEm, NewGID_A]));
        finally SubParse.Free; end;
      finally Font.Free; end;
    finally Sub.Free; end;
  finally Parser.Free; end;
end;

// ============================================================================
// T06 — BuildObjectStream: PDF structure and keyword presence
// ============================================================================

procedure T06_ObjectStream;
var
  Data  : TBytes;
  Parser: TTTFParser;
  Sub   : TTTFSubsetter;
  Font  : TTTFEmbeddedFont;
  GIDs  : array[0..25] of Word;
  I     : Integer;
begin
  WriteLn;
  WriteLn('=== T06 — BuildObjectStream PDF structure ===');
  Data := LoadFont('arial.ttf');
  if Length(Data) = 0 then begin WriteLn('  [SKIP] arial.ttf not found'); Exit; end;

  Parser := TTTFParser.Create(Data);
  try
    if not Parser.Parse then begin WriteLn('  [SKIP] Arial parse failed'); Exit; end;

    for I := 0 to 25 do GIDs[I] := Parser.CharToGlyph(Cardinal(Ord('A') + I));
    Sub := TTTFSubsetter.Create(Parser, GIDs);
    try
      Font := TTTFEmbeddedFont.Create(Parser, Sub);
      try
        var Obj := Font.BuildObjectStream(10);

        Check(Length(Obj) > 0, 'BuildObjectStream returns non-empty bytes');
        // Object numbering
        Check(BytesContain(Obj, '10 0 obj'), 'Stream starts with "10 0 obj" (Type0)');
        Check(BytesContain(Obj, '11 0 obj'), 'Contains "11 0 obj" (CIDFont)');
        Check(BytesContain(Obj, '12 0 obj'), 'Contains "12 0 obj" (FontDescriptor)');
        Check(BytesContain(Obj, '13 0 obj'), 'Contains "13 0 obj" (FontFile2)');
        Check(BytesContain(Obj, '14 0 obj'), 'Contains "14 0 obj" (ToUnicode CMap)');
        // Content keywords
        Check(BytesContain(Obj, '/Type /Font'), 'Contains "/Type /Font"');
        Check(BytesContain(Obj, '/Subtype /Type0'), 'Contains "/Subtype /Type0"');
        Check(BytesContain(Obj, '/CIDFontType2'), 'Contains "/CIDFontType2"');
        Check(BytesContain(Obj, '/Identity-H'), 'Contains "/Identity-H" encoding');
        Check(BytesContain(Obj, '/CIDToGIDMap /Identity'),
          'Contains "/CIDToGIDMap /Identity"');
        Check(BytesContain(Obj, '/FontDescriptor'), 'Contains "/FontDescriptor"');
        Check(BytesContain(Obj, '/FlateDecode'),
          'Contains "/FlateDecode" (compressed streams)');
        Check(BytesContain(Obj, 'stream'), 'Contains "stream" keyword');
        Check(BytesContain(Obj, 'endstream'), 'Contains "endstream" keyword');
        Check(BytesContain(Obj, 'endobj'), 'Contains "endobj" keyword');

        WriteLn(Format('  BuildObjectStream: %d bytes total', [Length(Obj)]));
      finally Font.Free; end;
    finally Sub.Free; end;
  finally Parser.Free; end;
end;

// ============================================================================
// T07 — Courier New: fixed-pitch flag + equal advance widths
// ============================================================================

procedure T07_CourierFixedPitch;
var
  Data  : TBytes;
  Parser: TTTFParser;
  Sub   : TTTFSubsetter;
  Font  : TTTFEmbeddedFont;
  GIDs  : array[0..5] of Word;
  Chars : string;
  I     : Integer;
begin
  WriteLn;
  WriteLn('=== T07 — Courier New: fixed-pitch flag and equal widths ===');
  Data := LoadFont('cour.ttf');
  if Length(Data) = 0 then begin WriteLn('  [SKIP] cour.ttf not found'); Exit; end;

  Parser := TTTFParser.Create(Data);
  try
    if not Parser.Parse then begin WriteLn('  [SKIP] Courier parse failed'); Exit; end;

    // Subset: A, I, M, W, !, . — wide variety of shapes in a monospace font
    Chars := 'AIMW!.';
    for I := 0 to 5 do GIDs[I] := Parser.CharToGlyph(Cardinal(Ord(Chars[I + 1])));
    Sub := TTTFSubsetter.Create(Parser, GIDs);
    try
      Font := TTTFEmbeddedFont.Create(Parser, Sub);
      try
        // FixedPitch (bit 1) + Nonsymbolic (bit 6) = 1 + 32 = 33
        var Obj := Font.BuildObjectStream(20);
        Check(BytesContain(Obj, '/Flags 33'),
          'FontDescriptor /Flags = 33 (FixedPitch + Nonsymbolic)');

        // All subset glyphs must have equal MeasureText (monospaced)
        var WA := Font.MeasureText('A', 1000.0);
        var WI := Font.MeasureText('I', 1000.0);
        var WM := Font.MeasureText('M', 1000.0);
        var WW := Font.MeasureText('W', 1000.0);
        Check(WA > 0, Format('MeasureText("A") > 0  (%.1f)', [WA]));
        Check(Abs(WA - WI) < 0.001,
          Format('"A" and "I" equal width in Courier  (%.3f vs %.3f)', [WA, WI]));
        Check(Abs(WA - WM) < 0.001,
          Format('"A" and "M" equal width in Courier  (%.3f vs %.3f)', [WA, WM]));
        Check(Abs(WA - WW) < 0.001,
          Format('"A" and "W" equal width in Courier  (%.3f vs %.3f)', [WA, WW]));

        WriteLn(Format('  Fixed-pitch advance width: %.1f pts at font-size 1000', [WA]));
      finally Font.Free; end;
    finally Sub.Free; end;
  finally Parser.Free; end;
end;

// ============================================================================
// Main
// ============================================================================

begin
  WriteLn('======================================================');
  WriteLn(' TestTTFEmbeddedFont — Phase 3 Validation');
  WriteLn('======================================================');

  T01_Construction;
  T02_MeasureText;
  T03_EncodeTextHex;
  T04_ToUnicodeCMap;
  T05_SubsetTTFReparse;
  T06_ObjectStream;
  T07_CourierFixedPitch;

  WriteLn;
  WriteLn('======================================================');
  WriteLn(Format(' TOTAL: %d passed,  %d failed', [GPass, GFail]));
  WriteLn('======================================================');
  if GFail > 0 then ExitCode := 1;
end.
