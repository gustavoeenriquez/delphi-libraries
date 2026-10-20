unit uPDF.Render.FontCache;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.Skia,
  uPDF.Types, uPDF.Font, uPDF.FontProgram, uPDF.StdFonts;

type
  // -------------------------------------------------------------------------
  // Font cache: maps TPDFFont instances → ISkTypeface
  // The cache holds a strong reference to each ISkTypeface so they are only
  // loaded once per document lifetime.
  // -------------------------------------------------------------------------
  TPDFFontCache = class
  private
    // Key = pointer to TPDFFont (stable lifetime — owned by parser pool)
    FCache: TDictionary<Pointer, ISkTypeface>;
    // Glyph outlines of embedded font programs: font → (glyph → path)
    FGlyphPaths: TObjectDictionary<Pointer, TDictionary<Integer, ISkPath>>;
    // System fonts tried for characters the substitute font lacks
    FFallbacks: TArray<ISkTypeface>;
    FFallbacksLoaded: Boolean;
    FCharFallback: TDictionary<Integer, ISkTypeface>;

    function LoadEmbeddedTypeface(const ABytes: TBytes): ISkTypeface;
    function FallbackTypeface(AFont: TPDFFont): ISkTypeface;

  public
    constructor Create;
    destructor  Destroy; override;

    // Return (and cache) the ISkTypeface for the given PDF font.
    // Never returns nil — falls back to a system font if needed.
    function GetTypeface(AFont: TPDFFont): ISkTypeface;

    // Outline of glyph AGID of the embedded program of AFont, in text space
    // with Skia's downward y (1 unit = 1 em); nil for an empty glyph
    function GetGlyphPath(AFont: TPDFFont; AGID: Integer): ISkPath;

    // A system typeface that has ACodePoint, for characters missing from a
    // substitute font; nil when none has it
    function FallbackFor(ACodePoint: Integer): ISkTypeface;

    procedure Clear;
  end;

implementation

// -------------------------------------------------------------------------
// Standard PDF Type1 font name → Windows/cross-platform system font family
// -------------------------------------------------------------------------
const
  FONT_SUBSTITUTIONS: array[0..27] of array[0..1] of string = (
    ('Helvetica',             'Arial'),
    ('Helvetica-Bold',        'Arial'),
    ('Helvetica-Oblique',     'Arial'),
    ('Helvetica-BoldOblique', 'Arial'),
    ('Times-Roman',           'Times New Roman'),
    ('Times-Bold',            'Times New Roman'),
    ('Times-Italic',          'Times New Roman'),
    ('Times-BoldItalic',      'Times New Roman'),
    ('Courier',               'Courier New'),
    ('Courier-Bold',          'Courier New'),
    ('Courier-Oblique',       'Courier New'),
    ('Courier-BoldOblique',   'Courier New'),
    // Symbol and ZapfDingbats text arrives as Unicode (Greek, math, U+27xx
    // dingbats); symbol-encoded system fonts (Symbol, Wingdings) lack those
    ('Symbol',                'Times New Roman'),
    ('ZapfDingbats',          'Segoe UI Symbol'),
    // OpenType/CFF variants (sometimes used as base font names)
    ('Arial',                 'Arial'),
    ('Arial,Bold',            'Arial'),
    ('Arial,Italic',          'Arial'),
    ('Arial,BoldItalic',      'Arial'),
    ('TimesNewRoman',         'Times New Roman'),
    ('TimesNewRomanPS',       'Times New Roman'),
    ('TimesNewRomanPSMT',     'Times New Roman'),
    ('CourierNew',            'Courier New'),
    ('CourierNewPS',          'Courier New'),
    ('CourierNewPSMT',        'Courier New'),
    ('Calibri',               'Calibri'),
    ('Cambria',               'Cambria'),
    ('Georgia',               'Georgia'),
    ('Verdana',               'Verdana')
  );

// -------------------------------------------------------------------------
// Resolve a PDF font name to a Windows font style
// -------------------------------------------------------------------------
function IsBold(const AName: string): Boolean;
begin
  Result := (Pos('Bold', AName) > 0) or (Pos('bold', AName) > 0) or
            (Pos(',B', AName) > 0);
end;

function IsItalic(const AName: string): Boolean;
begin
  Result := (Pos('Italic', AName) > 0) or (Pos('italic', AName) > 0) or
            (Pos('Oblique', AName) > 0) or (Pos('oblique', AName) > 0) or
            (Pos(',I', AName) > 0);
end;

function ResolveSystemFamily(const APDFName: string): string;
var
  I: Integer;
  BaseName: string;
begin
  // Strip leading subset prefix (e.g. "ABCDEF+Helvetica" → "Helvetica")
  BaseName := APDFName;
  if (Length(BaseName) > 7) and (BaseName[7] = '+') then
    BaseName := Copy(BaseName, 8, MaxInt);

  for I := Low(FONT_SUBSTITUTIONS) to High(FONT_SUBSTITUTIONS) do
    if SameText(BaseName, FONT_SUBSTITUTIONS[I][0]) or
       SameText(APDFName, FONT_SUBSTITUTIONS[I][0]) then
      Exit(FONT_SUBSTITUTIONS[I][1]);

  // Not in table: try the name as-is (might be a system font)
  Result := BaseName;
end;

// =========================================================================
// TPDFFontCache
// =========================================================================

constructor TPDFFontCache.Create;
begin
  inherited;
  FCache := TDictionary<Pointer, ISkTypeface>.Create;
  FGlyphPaths := TObjectDictionary<Pointer, TDictionary<Integer, ISkPath>>.Create([doOwnsValues]);
  FCharFallback := TDictionary<Integer, ISkTypeface>.Create;
end;

destructor TPDFFontCache.Destroy;
begin
  FCharFallback.Free;
  FGlyphPaths.Free;
  FCache.Free;
  inherited;
end;

procedure TPDFFontCache.Clear;
begin
  FCache.Clear;
  FGlyphPaths.Clear;
end;

function TPDFFontCache.GetGlyphPath(AFont: TPDFFont; AGID: Integer): ISkPath;
var
  Paths: TDictionary<Integer, ISkPath>;
  M: TPDFMatrix;
  B: ISkPathBuilder;
begin
  if not FGlyphPaths.TryGetValue(Pointer(AFont), Paths) then
  begin
    Paths := TDictionary<Integer, ISkPath>.Create;
    FGlyphPaths.Add(Pointer(AFont), Paths);
  end;
  if Paths.TryGetValue(AGID, Result) then Exit;
  Result := nil;
  var Prog := AFont.FontProgram;
  if Prog <> nil then
  begin
    var Outline := Prog.GlyphOutline(AGID);
    if Length(Outline) > 0 then
    begin
      // glyph space → text space (FontMatrix), then y down as Skia glyphs
      M := Prog.FontMatrix;
      B := TSkPathBuilder.Create(TSkPathFillType.Winding);
      for var Op in Outline do
        case Op.Kind of
          TGlyphOpKind.MoveTo:
            B.MoveTo(Op.X1 * M.A + Op.Y1 * M.C + M.E, -(Op.X1 * M.B + Op.Y1 * M.D + M.F));
          TGlyphOpKind.LineTo:
            B.LineTo(Op.X1 * M.A + Op.Y1 * M.C + M.E, -(Op.X1 * M.B + Op.Y1 * M.D + M.F));
          TGlyphOpKind.CurveTo:
            B.CubicTo(Op.X1 * M.A + Op.Y1 * M.C + M.E, -(Op.X1 * M.B + Op.Y1 * M.D + M.F),
                      Op.X2 * M.A + Op.Y2 * M.C + M.E, -(Op.X2 * M.B + Op.Y2 * M.D + M.F),
                      Op.X3 * M.A + Op.Y3 * M.C + M.E, -(Op.X3 * M.B + Op.Y3 * M.D + M.F));
          TGlyphOpKind.Close:
            B.Close;
        end;
      Result := B.Detach;
    end;
  end;
  Paths.Add(AGID, Result);
end;

function TPDFFontCache.FallbackFor(ACodePoint: Integer): ISkTypeface;
const
  CANDIDATES: array[0..7] of string = ('Segoe UI Symbol', 'Segoe UI', 'Cambria Math',
    'Arial Unicode MS', 'DejaVu Sans', 'Noto Sans Symbols2', 'Noto Sans Symbols', 'Noto Sans');
begin
  if FCharFallback.TryGetValue(ACodePoint, Result) then Exit;
  if not FFallbacksLoaded then
  begin
    FFallbacksLoaded := True;
    for var Name in CANDIDATES do
    begin
      var TF := TSkTypeface.MakeFromName(Name, TSkFontStyle.Normal);
      // MakeFromName may return the default face for an unknown family
      if (TF <> nil) and SameText(TF.FamilyName, Name) then
        FFallbacks := FFallbacks + [TF];
    end;
  end;
  Result := nil;
  for var TF in FFallbacks do
  begin
    var F: ISkFont := TSkFont.Create(TF, 1, 1, 0);
    if F.UnicharToGlyph(ACodePoint) <> 0 then
    begin
      Result := TF;
      Break;
    end;
  end;
  FCharFallback.Add(ACodePoint, Result);
end;

// -------------------------------------------------------------------------
// Load an ISkTypeface from embedded font bytes (TrueType or CFF/OTF)
// -------------------------------------------------------------------------
function TPDFFontCache.LoadEmbeddedTypeface(const ABytes: TBytes): ISkTypeface;
var
  MS: TMemoryStream;
begin
  Result := nil;
  if Length(ABytes) = 0 then Exit;
  MS := TMemoryStream.Create;
  try
    MS.Write(ABytes[0], Length(ABytes));
    MS.Position := 0;
    try
      Result := TSkTypeface.MakeFromStream(MS);
    except
      Result := nil;  // corrupt font data — fall back to system font
    end;
  finally
    MS.Free;
  end;
end;

// -------------------------------------------------------------------------
// Create a system-font typeface by family name + weight/style
// -------------------------------------------------------------------------
function TPDFFontCache.FallbackTypeface(AFont: TPDFFont): ISkTypeface;
const
  // Families for the standard fonts: Windows names, then the metric-compatible
  // Liberation/DejaVu families of Linux
  STD_FAMILIES: array[0..4, 0..1] of string = (
    ('Courier New', 'Liberation Mono'),
    ('Arial', 'Liberation Sans'),
    ('Times New Roman', 'Liberation Serif'),
    ('Times New Roman', 'DejaVu Serif'),
    ('Segoe UI Symbol', 'DejaVu Sans'));
var
  Family, Base: string;
  Style: TSkFontStyle;

  // MakeFromName returns the default face for a family it does not know
  function TryFamily(const AFamily: string): ISkTypeface;
  begin
    Result := nil;
    if AFamily = '' then Exit;
    var TF := TSkTypeface.MakeFromName(AFamily, Style);
    if (TF <> nil) and SameText(TF.FamilyName, AFamily) then
      Result := TF;
  end;

begin
  var Name := AFont.Name;
  var Flags := AFont.Descriptor.Flags;
  var Bold := IsBold(Name) or (Flags and (1 shl 18) <> 0) or
              (Pos('Black', Name) > 0) or (Pos('Heavy', Name) > 0);
  var Italic := IsItalic(Name) or (Flags and 64 <> 0);
  if Bold and Italic then
    Style := TSkFontStyle.BoldItalic
  else if Bold then
    Style := TSkFontStyle.Bold
  else if Italic then
    Style := TSkFontStyle.Italic
  else
    Style := TSkFontStyle.Normal;

  // 1. the substitution table, 2. the family part of the PostScript name
  // (ArialMT, Calibri-Bold, TimesNewRomanPS-ItalicMT), 3. the standard font
  // closest to the descriptor flags
  Family := ResolveSystemFamily(Name);
  Result := TryFamily(Family);
  if Result <> nil then Exit;
  Base := Family;
  var P := Base.IndexOfAny([',', '-']);
  if P > 0 then Base := Base.Substring(0, P);
  for var Suffix in ['PSMT', 'MT', 'PS'] do
    if Base.EndsWith(Suffix) and (Length(Base) > Length(Suffix) + 2) then
    begin
      Base := Base.Substring(0, Length(Base) - Length(Suffix));
      Break;
    end;
  if Base <> Family then
  begin
    Result := TryFamily(ResolveSystemFamily(Base));
    if Result = nil then Result := TryFamily(Base);
    if Result <> nil then Exit;
  end;
  var Std := StdFontSubstitute(Flags, Name);
  var Row: Integer;
  case Std of
    STD_SYMBOL:   Row := 3;
    STD_DINGBATS: Row := 4;
  else
    Row := Std div 4;
  end;
  Result := TryFamily(STD_FAMILIES[Row, 0]);
  if Result = nil then Result := TryFamily(STD_FAMILIES[Row, 1]);
  if Result = nil then
    Result := TSkTypeface.MakeFromName(STD_FAMILIES[Row, 0], Style);
  if Result = nil then
    Result := TSkTypeface.MakeDefault;
end;

// -------------------------------------------------------------------------
// Main entry point
// -------------------------------------------------------------------------
function TPDFFontCache.GetTypeface(AFont: TPDFFont): ISkTypeface;
var
  Key:       Pointer;
  Bytes:     TBytes;
begin
  if AFont = nil then
    Exit(TSkTypeface.MakeDefault);

  Key := Pointer(AFont);
  if FCache.TryGetValue(Key, Result) then
    Exit;

  // Try embedded font bytes first (TrueType = FontFile2, CFF = FontFile3)
  Bytes := AFont.FontBytes;
  if Length(Bytes) > 0 then
    Result := LoadEmbeddedTypeface(Bytes);

  // Fall back to system font substitution
  if Result = nil then
    Result := FallbackTypeface(AFont);

  // Last resort
  if Result = nil then
    Result := TSkTypeface.MakeDefault;

  FCache.AddOrSetValue(Key, Result);
end;

end.
