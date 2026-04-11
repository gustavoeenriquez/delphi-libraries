unit uPDF.Render.FontCache;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.Skia,
  uPDF.Font;

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

    function LoadEmbeddedTypeface(const ABytes: TBytes): ISkTypeface;
    function FallbackTypeface(const AFontName: string): ISkTypeface;

  public
    constructor Create;
    destructor  Destroy; override;

    // Return (and cache) the ISkTypeface for the given PDF font.
    // Never returns nil — falls back to a system font if needed.
    function GetTypeface(AFont: TPDFFont): ISkTypeface;

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
    ('Symbol',                'Symbol'),
    ('ZapfDingbats',          'Wingdings'),
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
end;

destructor TPDFFontCache.Destroy;
begin
  FCache.Free;
  inherited;
end;

procedure TPDFFontCache.Clear;
begin
  FCache.Clear;
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
function TPDFFontCache.FallbackTypeface(const AFontName: string): ISkTypeface;
var
  Family:    string;
  Bold:      Boolean;
  Italic:    Boolean;
  Style:     TSkFontStyle;
begin
  Family := ResolveSystemFamily(AFontName);
  Bold   := IsBold(AFontName);
  Italic := IsItalic(AFontName);

  if Bold and Italic then
    Style := TSkFontStyle.BoldItalic
  else if Bold then
    Style := TSkFontStyle.Bold
  else if Italic then
    Style := TSkFontStyle.Italic
  else
    Style := TSkFontStyle.Normal;

  Result := TSkTypeface.MakeFromName(Family, Style);
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
    Result := FallbackTypeface(AFont.Name);

  // Last resort
  if Result = nil then
    Result := TSkTypeface.MakeDefault;

  FCache.AddOrSetValue(Key, Result);
end;

end.
