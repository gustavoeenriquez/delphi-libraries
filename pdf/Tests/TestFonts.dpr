program TestFonts;
// Tests: uPDF.StdFonts (metrics of the 14 standard fonts, Annex D encodings,
// Adobe Glyph List), the simple-font loading of uPDF.Font (base encoding,
// Differences, widths of fonts without /Widths, character codes to Unicode)
// and the embedded font programs (uPDF.FontProgram, uPDF.FontCFF,
// uPDF.FontType1): outlines against data\fonts (see tools\gen_font_vectors.py)
// and the character code to glyph mapping of simple and CID fonts.

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}

uses
  System.SysUtils, System.Classes, System.Math, System.IOUtils, System.Generics.Collections,
  System.Generics.Defaults, System.Types,
  uPDF.Types         in '..\Src\Core\uPDF.Types.pas',
  uPDF.Errors        in '..\Src\Core\uPDF.Errors.pas',
  uPDF.Objects       in '..\Src\Core\uPDF.Objects.pas',
  uPDF.StdFonts      in '..\Src\Core\uPDF.StdFonts.pas',
  uPDF.FontProgram   in '..\Src\Core\uPDF.FontProgram.pas',
  uPDF.FontCFF       in '..\Src\Core\uPDF.FontCFF.pas',
  uPDF.FontType1     in '..\Src\Core\uPDF.FontType1.pas',
  uPDF.Font          in '..\Src\Core\uPDF.Font.pas',
  uPDF.Document      in '..\Src\Core\uPDF.Document.pas',
  uPDF.TextExtractor in '..\Src\Core\uPDF.TextExtractor.pas';

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
  if AReason <> '' then WriteLn('  [FAIL] ', AMsg, ' - ', AReason)
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

function Hex(const S: string): string;
begin
  Result := '';
  for var C in S do Result := Result + IntToHex(Ord(C), 4) + ' ';
  Result := Trim(Result);
end;

// A simple font dictionary: /Type /Font /Subtype ASubtype /BaseFont ABase
// plus an optional /Encoding (a name, or a dictionary with Differences).
function FontDict(const ASubtype, ABase: string; AEncoding: TPDFObject = nil): TPDFDictionary;
begin
  Result := TPDFDictionary.Create;
  Result.SetValue('Type', TPDFName.Create('Font'));
  Result.SetValue('Subtype', TPDFName.Create(ASubtype));
  Result.SetValue('BaseFont', TPDFName.Create(ABase));
  if AEncoding <> nil then
    Result.SetValue('Encoding', AEncoding);
end;

// << /BaseEncoding ABase /Differences [ACode /Name1 /Name2 ...] >>
function DiffEncoding(const ABase: string; ACode: Integer;
  const ANames: array of string): TPDFDictionary;
begin
  Result := TPDFDictionary.Create;
  Result.SetValue('Type', TPDFName.Create('Encoding'));
  if ABase <> '' then
    Result.SetValue('BaseEncoding', TPDFName.Create(ABase));
  var Arr := TPDFArray.Create;
  Arr.Add(TPDFInteger.Create(ACode));
  for var N in ANames do
    Arr.Add(TPDFName.Create(N));
  Result.SetValue('Differences', Arr);
end;

function Descriptor(AFlags: Integer): TPDFDictionary;
begin
  Result := TPDFDictionary.Create;
  Result.SetValue('Type', TPDFName.Create('FontDescriptor'));
  Result.SetValue('FontName', TPDFName.Create('X'));
  Result.SetValue('Flags', TPDFInteger.Create(AFlags));
end;

// Minimal one-page PDF whose page uses the font objects AFonts as /F1, /F2...
function MakePDF(const AFonts: array of AnsiString; const AContent: AnsiString): TBytes;
var
  Objs: TArray<AnsiString>;
  S, Res: AnsiString;
  Offs: TArray<Integer>;
begin
  Res := '';
  for var I := 0 to High(AFonts) do
    Res := Res + AnsiString(Format('/F%d %d 0 R ', [I + 1, I + 5]));
  Objs := ['<< /Type /Catalog /Pages 2 0 R >>',
           '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R ' +
           '/Resources << /Font << ' + Res + '>> >> >>',
           '<< /Length ' + AnsiString(IntToStr(Length(AContent))) + ' >>'#10'stream'#10 +
           AContent + #10'endstream'];
  for var F in AFonts do
    Objs := Objs + [F];
  S := '%PDF-1.4'#10;
  SetLength(Offs, Length(Objs));
  for var I := 0 to High(Objs) do
  begin
    Offs[I] := Length(S);
    S := S + AnsiString(IntToStr(I + 1)) + ' 0 obj'#10 + Objs[I] + #10'endobj'#10;
  end;
  var XRef := Length(S);
  S := S + 'xref'#10'0 ' + AnsiString(IntToStr(Length(Objs) + 1)) + #10'0000000000 65535 f '#10;
  for var I := 0 to High(Objs) do
    S := S + AnsiString(Format('%.10d 00000 n '#10, [Offs[I]]));
  S := S + 'trailer'#10'<< /Size ' + AnsiString(IntToStr(Length(Objs) + 1)) +
    ' /Root 1 0 R >>'#10'startxref'#10 + AnsiString(IntToStr(XRef)) + #10'%%EOF'#10;
  SetLength(Result, Length(S));
  Move(S[1], Result[0], Length(S));
end;

function ExtractFragments(const APDF: TBytes): TArray<TPDFTextFragment>;
begin
  var MS := TBytesStream.Create(APDF);
  var Doc := TPDFDocument.Create;
  try
    Doc.LoadFromStream(MS);
    var Ex := TPDFTextExtractor.Create(Doc);
    try
      Result := Ex.ExtractPage(0).Fragments;
    finally
      Ex.Free;
    end;
  finally
    Doc.Free;
    MS.Free;
  end;
end;

// =========================================================================
// uPDF.StdFonts
// =========================================================================

procedure TestStdFonts;
const
  ALIASES: array[0..12] of record N: string; I: Integer; end = (
    (N: 'Helvetica'; I: 4), (N: 'Helvetica-BoldOblique'; I: 7), (N: 'Arial'; I: 4),
    (N: 'Arial,Bold'; I: 5), (N: 'ABCDEF+Arial-BoldItalicMT'; I: 7), (N: 'ArialMT'; I: 4),
    (N: 'Times-Roman'; I: 8), (N: 'TimesNewRomanPS-ItalicMT'; I: 10),
    (N: 'Times New Roman,Bold'; I: 9), (N: 'CourierNew'; I: 0), (N: 'Courier-Oblique'; I: 2),
    (N: 'Symbol'; I: 12), (N: 'Calibri'; I: -1));
  WIDTHS: array[0..8] of record F: Integer; G: string; W: Integer; end = (
    (F: 4; G: 'a'; W: 556), (F: 4; G: 'space'; W: 278), (F: 5; G: 'A'; W: 722),
    (F: 8; G: 'a'; W: 444), (F: 11; G: 'Euro'; W: 500), (F: 0; G: 'W'; W: 600),
    (F: 12; G: 'alpha'; W: 631), (F: 13; G: 'a1'; W: 974),
    (F: 4; G: 'uni00E9'; W: 556));
var
  W: Integer;
begin
  Section('Fuentes estándar');
  for var A in ALIASES do
    Check(StdFontIndex(A.N) = A.I, Format('S01 índice de "%s" = %d', [A.N, A.I]),
      IntToStr(StdFontIndex(A.N)));
  for var A in WIDTHS do
    Check(StdGlyphWidth(A.F, A.G, W) and (W = A.W),
      Format('S02 ancho de %s en %s = %d', [A.G, STD_FONT_NAMES[A.F], A.W]), IntToStr(W));
  Check(not StdGlyphWidth(4, 'alpha', W), 'S03 Helvetica no tiene alpha');
  Check(StdFontSubstitute(0, 'Verdana') = STD_HELVETICA, 'S04 sustituta sans');
  Check(StdFontSubstitute(2, 'Garamond') = STD_TIMES, 'S04 sustituta serif');
  Check(StdFontSubstitute(1 or 64, 'Consolas') = STD_COURIER + 2, 'S04 sustituta mono itálica');
  Check(StdFontSubstitute(2, 'Georgia-Bold') = STD_TIMES + 1, 'S04 sustituta serif negrita');

  Section('Codificaciones (Anexo D)');
  Check(StdEncodingGlyph(TPDFStdEncoding.Standard, $27) = 'quoteright', 'E01 Standard 047 quoteright');
  Check(StdEncodingGlyph(TPDFStdEncoding.Standard, $E1) = 'AE', 'E01 Standard 341 AE');
  Check(StdEncodingGlyph(TPDFStdEncoding.Standard, $80) = '', 'E01 Standard 200 sin definir');
  Check(StdEncodingGlyph(TPDFStdEncoding.WinAnsi, $80) = 'Euro', 'E02 WinAnsi 200 Euro');
  Check(StdEncodingGlyph(TPDFStdEncoding.WinAnsi, $93) = 'quotedblleft', 'E02 WinAnsi 223 quotedblleft');
  Check(StdEncodingGlyph(TPDFStdEncoding.WinAnsi, $81) = 'bullet', 'E02 WinAnsi 201 bullet');
  Check(StdEncodingGlyph(TPDFStdEncoding.WinAnsi, $A0) = 'space', 'E02 WinAnsi 240 space');
  Check(StdEncodingGlyph(TPDFStdEncoding.WinAnsi, $E9) = 'eacute', 'E02 WinAnsi 351 eacute');
  Check(StdEncodingGlyph(TPDFStdEncoding.MacRoman, $8E) = 'eacute', 'E03 MacRoman 216 eacute');
  Check(StdEncodingGlyph(TPDFStdEncoding.MacRoman, $DB) = 'currency', 'E03 MacRoman 333 currency');
  Check(StdEncodingGlyph(TPDFStdEncoding.MacRoman, $D5) = 'quoteright', 'E03 MacRoman 325 quoteright');
  Check(StdEncodingGlyph(TPDFStdEncoding.Symbol, $61) = 'alpha', 'E04 Symbol 141 alpha');
  Check(StdEncodingGlyph(TPDFStdEncoding.ZapfDingbats, $21) = 'a1', 'E05 ZapfDingbats 041 a1');

  Section('Nombres de glifo a Unicode');
  Check(GlyphNameToUnicode('eacute') = #$00E9, 'G01 eacute');
  Check(GlyphNameToUnicode('Euro') = #$20AC, 'G01 Euro');
  Check(GlyphNameToUnicode('fi') = #$FB01, 'G01 fi');
  Check(GlyphNameToUnicode('alpha') = #$03B1, 'G01 alpha');
  Check(GlyphNameToUnicode('a1') = #$2701, 'G02 a1 (ZapfDingbats)');
  Check(GlyphNameToUnicode('uni00F1') = #$00F1, 'G03 uni00F1');
  Check(GlyphNameToUnicode('u1F600') = #$D83D#$DE00, 'G03 u1F600', Hex(GlyphNameToUnicode('u1F600')));
  Check(GlyphNameToUnicode('a.sc') = 'a', 'G04 a.sc');
  Check(GlyphNameToUnicode('g123') = '', 'G05 nombre desconocido');
end;

// =========================================================================
// uPDF.Font: simple fonts
// =========================================================================

procedure TestSimpleFonts;
var
  F: TPDFFont;
begin
  Section('Fuentes simples sin /Widths');
  F := TPDFFontFactory.Build(FontDict('Type1', 'Helvetica', TPDFName.Create('WinAnsiEncoding')));
  try
    Check(SameValue(F.GetWidth(Ord('a')), 556), 'F01 Helvetica WinAnsi a = 556', FloatToStr(F.GetWidth(Ord('a'))));
    Check(SameValue(F.GetWidth(32), 278), 'F01 Helvetica WinAnsi space = 278');
    Check(SameValue(F.GetWidth($E9), 556), 'F01 Helvetica WinAnsi eacute = 556');
    Check(SameValue(F.GetWidth($80), 556), 'F01 Helvetica WinAnsi Euro = 556');
    Check(F.CharCodeToUnicode($80) = #$20AC, 'F01 WinAnsi 200 -> euro');
    Check(F.CharCodeToUnicode($93) = #$201C, 'F01 WinAnsi 223 -> comilla');
    Check(F.CharCodeToUnicode($F1) = #$00F1, 'F01 WinAnsi 361 -> ñ');
  finally
    F.Free;
  end;

  F := TPDFFontFactory.Build(FontDict('Type1', 'Times-Bold'));
  try
    Check(SameValue(F.GetWidth(Ord('A')), 722), 'F02 Times-Bold sin /Encoding A = 722');
    Check(F.CharCodeToUnicode($27) = #$2019, 'F02 StandardEncoding 047 -> comilla derecha');
    Check(F.CharCodeToUnicode($E1) = #$00C6, 'F02 StandardEncoding 341 -> Æ');
  finally
    F.Free;
  end;

  F := TPDFFontFactory.Build(FontDict('Type1', 'Helvetica',
    DiffEncoding('WinAnsiEncoding', 65, ['Eacute', 'uni00F1', 'g7'])));
  try
    Check(SameValue(F.GetWidth(65), 667), 'F03 Differences Eacute = 667');
    Check(F.CharCodeToUnicode(65) = #$00C9, 'F03 Differences Eacute -> É');
    Check(SameValue(F.GetWidth(66), 556), 'F03 Differences uni00F1 = ancho de ntilde');
    Check(F.CharCodeToUnicode(66) = #$00F1, 'F03 Differences uni00F1 -> ñ');
    Check(F.CharCodeToUnicode(67) = 'C', 'F03 nombre desconocido -> Latin-1');
    Check(SameValue(F.GetWidth(Ord('z')), 500), 'F03 resto por WinAnsi z = 500');
  finally
    F.Free;
  end;

  F := TPDFFontFactory.Build(FontDict('Type1', 'Symbol'));
  try
    Check(F.CharCodeToUnicode($61) = #$03B1, 'F04 Symbol 141 -> alfa');
    Check(SameValue(F.GetWidth($61), 631), 'F04 Symbol alpha = 631');
  finally
    F.Free;
  end;

  F := TPDFFontFactory.Build(FontDict('Type1', 'ZapfDingbats'));
  try
    Check(F.CharCodeToUnicode($33) = #$2713, 'F05 ZapfDingbats 063 -> marca de verificación',
      Hex(F.CharCodeToUnicode($33)));
    Check(SameValue(F.GetWidth($33), 755), 'F05 ZapfDingbats a20 = 755', FloatToStr(F.GetWidth($33)));
  finally
    F.Free;
  end;

  var D := FontDict('TrueType', 'Arial,Bold', TPDFName.Create('WinAnsiEncoding'));
  F := TPDFFontFactory.Build(D);
  try
    Check(SameValue(F.GetWidth(Ord('A')), 722), 'F06 TrueType Arial,Bold = Helvetica-Bold');
  finally
    F.Free;
  end;

  D := FontDict('TrueType', 'Garamond');
  D.SetValue('FontDescriptor', Descriptor(2 or 32));
  F := TPDFFontFactory.Build(D);
  try
    Check(SameValue(F.GetWidth(Ord('a')), 444), 'F07 no estándar serif sin /Widths -> Times');
    Check(F.CharCodeToUnicode($80) = #$20AC, 'F07 TrueType sin /Encoding -> WinAnsi');
  finally
    F.Free;
  end;

  D := FontDict('Type1', 'Helvetica');
  var W := TPDFArray.Create;
  W.Add(TPDFInteger.Create(100));
  W.Add(TPDFInteger.Create(200));
  D.SetValue('FirstChar', TPDFInteger.Create(65));
  D.SetValue('LastChar', TPDFInteger.Create(66));
  D.SetValue('Widths', W);
  F := TPDFFontFactory.Build(D);
  try
    Check(SameValue(F.GetWidth(66), 200), 'F08 /Widths tiene prioridad sobre el AFM');
  finally
    F.Free;
  end;
end;

// =========================================================================
// uPDF.FontProgram / uPDF.FontCFF / uPDF.FontType1
// =========================================================================

function FindDataDir: string;
var
  D: string;
begin
  if (ParamCount > 0) and FileExists(TPath.Combine(ParamStr(1), 'manifest.txt')) then
    Exit(ParamStr(1));
  D := ExtractFilePath(ParamStr(0));
  for var I := 0 to 5 do
  begin
    Result := TPath.Combine(D, 'data' + PathDelim + 'fonts');
    if FileExists(TPath.Combine(Result, 'manifest.txt')) then Exit;
    D := ExtractFilePath(ExcludeTrailingPathDelimiter(D));
  end;
  Result := '';
end;

// Sorted set of the outline points rounded to integers, as in manifest.txt
function PointSet(const AOutline: TGlyphOutline): string;
var
  L: TList<TPoint>;

  procedure Add(X, Y: Single);
  begin
    var P := TPoint.Create(Round(X), Round(Y));
    if not L.Contains(P) then L.Add(P);
  end;

begin
  L := TList<TPoint>.Create;
  try
    for var Op in AOutline do
      case Op.Kind of
        TGlyphOpKind.MoveTo, TGlyphOpKind.LineTo: Add(Op.X1, Op.Y1);
        TGlyphOpKind.CurveTo:
        begin
          Add(Op.X1, Op.Y1);
          Add(Op.X2, Op.Y2);
          Add(Op.X3, Op.Y3);
        end;
      end;
    // numeric order of (x, y), as Python sorts the tuples
    L.Sort(TComparer<TPoint>.Construct(
      function(const A, B: TPoint): Integer
      begin
        Result := CompareValue(A.X, B.X);
        if Result = 0 then Result := CompareValue(A.Y, B.Y);
      end));
    Result := '';
    for var P in L do
    begin
      if Result <> '' then Result := Result + ' ';
      Result := Result + Format('%d,%d', [P.X, P.Y]);
    end;
  finally
    L.Free;
  end;
end;

function LoadProgram(const ADir, AFile: string): TPDFFontProgram;
var
  Key, Sub: string;
begin
  if AFile.EndsWith('.ttf') then Key := 'FontFile2'
  else if AFile.EndsWith('.cff') then
  begin
    Key := 'FontFile3';
    Sub := 'Type1C';
  end else
    Key := 'FontFile';
  Result := LoadFontProgram(TFile.ReadAllBytes(TPath.Combine(ADir, AFile)), Key, Sub);
end;

procedure TestPrograms;
var
  Dir: string;
  Progs: TObjectDictionary<string, TPDFFontProgram>;
begin
  Section('Programas de fuente: contornos (FreeType / fontTools)');
  Dir := FindDataDir;
  if Dir = '' then
  begin
    Fail('P00 no se encontró data/fonts/manifest.txt');
    Exit;
  end;
  Progs := TObjectDictionary<string, TPDFFontProgram>.Create([doOwnsValues]);
  try
    for var Line in TFile.ReadAllLines(TPath.Combine(Dir, 'manifest.txt')) do
    begin
      if (Line = '') or Line.StartsWith('#') then Continue;
      // file gid name points...: Split with a count drops the rest
      var Parts := Line.Split([' ']);
      var Prog: TPDFFontProgram;
      if not Progs.TryGetValue(Parts[0], Prog) then
      begin
        Prog := LoadProgram(Dir, Parts[0]);
        Progs.Add(Parts[0], Prog);
        Check(Prog <> nil, 'P01 carga ' + Parts[0]);
      end;
      if Prog = nil then Continue;
      var Expected := string.Join(' ', Copy(Parts, 3, MaxInt));
      var GID := StrToInt(Parts[1]);
      var Got := PointSet(Prog.GlyphOutline(GID));
      Check((Got = Expected) and (Prog.GlyphName(GID) = Parts[2]),
        Format('P02 %s glifo %d %s', [Parts[0], GID, Parts[2]]),
        Format('nombre %s; obtenido [%s] esperado [%s]', [Prog.GlyphName(GID), Got, Expected]));
    end;

    Section('Programas de fuente: búsqueda de glifos');
    var TT: TPDFFontProgram;
    if Progs.TryGetValue('tt.ttf', TT) and (TT is TTrueTypeProgram) then
    begin
      var T := TTrueTypeProgram(TT);
      Check(T.CmapGlyph(3, 1, $41) = 1, 'P03 TrueType cmap (3,1) A');
      Check(T.CmapGlyph(3, 0, $F062) = 2, 'P03 TrueType cmap (3,0) F062');
      Check(T.CmapGlyph(1, 0, $64) = 4, 'P03 TrueType cmap (1,0) d');
      Check(T.CmapGlyph(3, 1, $44) = 0, 'P03 TrueType código sin glifo');
      Check(T.GlyphByName('C') = 3, 'P03 TrueType nombre post');
      Check(SameValue(T.FontMatrix.A, 0.001, 1e-9), 'P03 TrueType FontMatrix 1/unitsPerEm');
    end else
      Fail('P03 TrueType');
    var C: TPDFFontProgram;
    if Progs.TryGetValue('cff.cff', C) then
    begin
      Check(C.HasBuiltinEncoding and (C.BuiltinGlyphName($64) = 'Aacute'), 'P04 CFF codificación propia');
      Check(C.GlyphByName('acute') = 5, 'P04 CFF charset');
      Check((C is TCFFProgram) and not TCFFProgram(C).IsCIDKeyed, 'P04 CFF por nombres');
    end;
    var T1: TPDFFontProgram;
    if Progs.TryGetValue('t1.pfa', T1) then
    begin
      Check(T1.HasBuiltinEncoding and (T1.BuiltinGlyphName($63) = 'C'), 'P05 Type 1 codificación propia');
      Check(T1.GlyphByName('Aacute') = 4, 'P05 Type 1 CharStrings');
      Check(SameValue(T1.FontMatrix.A, 0.001, 1e-9), 'P05 Type 1 FontMatrix');
    end;
    Check(LoadFontProgram(TBytes.Create(1, 2, 3, 4, 5), 'FontFile2', '') = nil,
      'P06 datos inválidos -> nil');
  finally
    Progs.Free;
  end;
end;

function FontFileStream(const AData: TBytes; const ASubtype: string = ''): TPDFStream;
begin
  Result := TPDFStream.Create;
  Result.SetRawData(AData);
  Result.Dict.SetValue('Length', TPDFInteger.Create(Length(AData)));
  if ASubtype <> '' then
    Result.Dict.SetValue('Subtype', TPDFName.Create(ASubtype));
end;

function EmbeddedFont(const ASubtype, ABase: string; AFlags: Integer; const AKey: string;
  AFile: TPDFStream; AEncoding: TPDFObject = nil): TPDFFont;
begin
  var D := FontDict(ASubtype, ABase, AEncoding);
  var Desc := Descriptor(AFlags);
  Desc.SetValue(AKey, AFile);
  D.SetValue('FontDescriptor', Desc);
  Result := TPDFFontFactory.Build(D);
  // the factory keeps references into D: it stays alive for the test run
end;

procedure TestEmbeddedFonts;
var
  F: TPDFFont;
  Dir: string;
begin
  Section('Fuentes incrustadas: código a glifo');
  Dir := FindDataDir;
  if Dir = '' then Exit;
  var TTData := TFile.ReadAllBytes(TPath.Combine(Dir, 'tt.ttf'));
  var CFFData := TFile.ReadAllBytes(TPath.Combine(Dir, 'cff.cff'));
  var T1Data := TFile.ReadAllBytes(TPath.Combine(Dir, 't1.pfa'));

  // nonsymbolic TrueType with WinAnsi: code -> name -> Unicode -> (3,1)
  F := EmbeddedFont('TrueType', 'ABCDEF+Test', 32, 'FontFile2', FontFileStream(TTData),
    TPDFName.Create('WinAnsiEncoding'));
  try
    Check(F.FontProgram is TTrueTypeProgram, 'E01 TrueType cargada');
    Check(F.GlyphID(Ord('B')) = 2, 'E01 no simbólica: B por (3,1)', IntToStr(F.GlyphID(Ord('B'))));
    Check(F.GlyphID(Ord('Z')) = 0, 'E01 sin glifo -> .notdef');
  finally
    F.Free;
  end;

  // symbolic TrueType without /Encoding: the (3,0) cmap at 0xF000 + code
  F := EmbeddedFont('TrueType', 'ABCDEF+Test', 4, 'FontFile2', FontFileStream(TTData));
  try
    Check(F.GlyphID($63) = 3, 'E02 simbólica: c por (3,0) F063', IntToStr(F.GlyphID($63)));
  finally
    F.Free;
  end;

  // Differences on a TrueType font: names through Unicode and 'post'
  F := EmbeddedFont('TrueType', 'ABCDEF+Test', 32, 'FontFile2', FontFileStream(TTData),
    DiffEncoding('WinAnsiEncoding', 1, ['C', 'B']));
  try
    Check((F.GlyphID(1) = 3) and (F.GlyphID(2) = 2), 'E03 TrueType con Differences');
  finally
    F.Free;
  end;

  // Type 1C without /Encoding: the built-in encoding of the program
  F := EmbeddedFont('Type1', 'ABCDEF+TestCFF', 4, 'FontFile3', FontFileStream(CFFData, 'Type1C'));
  try
    Check(F.FontProgram is TCFFProgram, 'E04 CFF cargada');
    Check(F.GlyphID($64) = 4, 'E04 CFF codificación interna d -> Aacute', IntToStr(F.GlyphID($64)));
    Check(F.CharCodeToUnicode($64) = #$00C1, 'E04 CFF Unicode por nombre de glifo');
  finally
    F.Free;
  end;

  // Type 1C with WinAnsi: codes by the PDF encoding
  F := EmbeddedFont('Type1', 'ABCDEF+TestCFF', 32, 'FontFile3', FontFileStream(CFFData, 'Type1C'),
    TPDFName.Create('WinAnsiEncoding'));
  try
    Check(F.GlyphID(Ord('C')) = 3, 'E05 CFF WinAnsi C');
    Check(F.GlyphID($C1) = 4, 'E05 CFF WinAnsi Á -> Aacute');
  finally
    F.Free;
  end;

  // Type 1 without /Encoding: the built-in encoding
  F := EmbeddedFont('Type1', 'ABCDEF+TestT1', 4, 'FontFile', FontFileStream(T1Data));
  try
    Check(F.FontProgram is TType1Program, 'E06 Type 1 cargada');
    Check(F.GlyphID($62) = 2, 'E06 Type 1 codificación interna b -> B');
    Check(F.GlyphID($41) = -1, 'E06 código sin glifo');
  finally
    F.Free;
  end;

  // CIDFontType2 with a /CIDToGIDMap stream: CID 5 -> glyph 3
  var CIDDict := TPDFDictionary.Create;
  CIDDict.SetValue('Type', TPDFName.Create('Font'));
  CIDDict.SetValue('Subtype', TPDFName.Create('CIDFontType2'));
  CIDDict.SetValue('BaseFont', TPDFName.Create('ABCDEF+Test'));
  var Desc := Descriptor(4);
  Desc.SetValue('FontFile2', FontFileStream(TTData));
  CIDDict.SetValue('FontDescriptor', Desc);
  CIDDict.SetValue('CIDToGIDMap', FontFileStream(TBytes.Create(0, 0, 0, 1, 0, 2, 0, 0, 0, 0, 0, 3)));
  var Desc0 := TPDFArray.Create;
  Desc0.Add(CIDDict);
  var T0 := FontDict('Type0', 'ABCDEF+Test', TPDFName.Create('Identity-H'));
  T0.SetValue('DescendantFonts', Desc0);
  F := TPDFFontFactory.Build(T0);
  try
    Check(F.FontProgram is TTrueTypeProgram, 'E07 Type0: programa de la descendiente');
    Check((F.GlyphID(5) = 3) and (F.GlyphID(1) = 1), 'E07 CIDToGIDMap', IntToStr(F.GlyphID(5)));
    Check(F.GlyphID(40) = 0, 'E07 CID fuera del mapa -> .notdef');
  finally
    F.Free;
  end;
end;

procedure TestTextLayout;
begin
  Section('Posición del texto');
  // A = 667, V = 667, W = 944 in Helvetica; 10 pt
  var Frags := ExtractFragments(MakePDF(
    ['<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>'],
    'BT /F1 10 Tf 10 50 Td (AVW) Tj (x) Tj ET'));
  if Length(Frags) < 1 then
  begin
    Fail('T01 texto extraído');
    Exit;
  end;
  // One fragment per glyph; x starts at 10 + 6.67 + 6.67 + 9.44 = 32.78
  var Txt := '';
  var XX := 0.0;
  for var Fr in Frags do
  begin
    Txt := Txt + Fr.Text;
    if Fr.Text = 'x' then XX := Fr.X;
  end;
  Check(Txt = 'AVWx', 'T01 texto "AVWx"', Txt);
  Check(Abs(XX - 32.78) < 0.02, 'T02 avance con métricas de Helvetica', FloatToStr(XX));
end;

begin
  try
    TestStdFonts;
    TestSimpleFonts;
    TestTextLayout;
    TestPrograms;
    TestEmbeddedFonts;
  except
    on E: Exception do
    begin
      Inc(FailCount);
      WriteLn('EXCEPCIÓN: ', E.ClassName, ': ', E.Message);
    end;
  end;
  WriteLn;
  WriteLn(Format('Total: %d pasan, %d fallan', [PassCount, FailCount]));
  if FailCount > 0 then ExitCode := 1;
end.
