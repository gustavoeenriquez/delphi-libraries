unit uPDF.Font;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.Math,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.StdFonts, uPDF.FontProgram;

type
  // -------------------------------------------------------------------------
  // Font encoding kind
  // -------------------------------------------------------------------------
  TPDFFontEncodingKind = (
    Standard,         // StandardEncoding
    MacRoman,         // MacRomanEncoding
    WinAnsi,          // WinAnsiEncoding
    MacExpert,        // MacExpertEncoding
    PdfDoc,           // PDFDocEncoding
    Differences,      // custom Differences array
    CMap,             // ToUnicode CMap
    Identity          // Identity-H / Identity-V (char code = glyph index)
  );

  // -------------------------------------------------------------------------
  // Font types
  // -------------------------------------------------------------------------
  TPDFFontType = (
    Unknown,
    Type1,      // /Type1
    TrueType,   // /TrueType
    Type3,      // /Type3 (glyph programs)
    CIDType0,   // /CIDFontType0 (CFF/Type1 CID)
    CIDType2,   // /CIDFontType2 (TrueType CID)
    Type0       // /Type0 composite (wraps CID font)
  );

  // -------------------------------------------------------------------------
  // Character width entry
  // -------------------------------------------------------------------------
  TPDFFontWidths = class
  private
    FFirstChar: Integer;
    FLastChar:  Integer;
    FWidths:    TArray<Single>;
    FMissingWidth: Single;
  public
    constructor Create(AFirstChar, ALastChar: Integer;
      const AWidths: TArray<Single>; AMissingWidth: Single);
    function  GetWidth(ACharCode: Integer): Single;
    property  FirstChar: Integer read FFirstChar;
    property  LastChar:  Integer read FLastChar;
    property  MissingWidth: Single read FMissingWidth;
  end;

  // -------------------------------------------------------------------------
  // Font descriptor
  // -------------------------------------------------------------------------
  TPDFFontDescriptor = record
    FontName:   string;
    Flags:      Integer;
    FontBBox:   TPDFRect;
    ItalicAngle:Single;
    Ascent:     Single;
    Descent:    Single;
    CapHeight:  Single;
    XHeight:    Single;
    StemV:      Single;
    StemH:      Single;
    // Embedded font bytes (one of these may be present)
    FontFile:   TBytes;   // Type1 font program
    FontFile2:  TBytes;   // TrueType font program
    FontFile3:  TBytes;   // CFF/OpenType font program
    FontFile3Subtype: string;   // Type1C, CIDFontType0C or OpenType
    function HasEmbeddedFont: Boolean; inline;
  end;

  // -------------------------------------------------------------------------
  // Base font class
  // -------------------------------------------------------------------------
  TPDFFont = class abstract
  protected
    FName:        string;
    FFontType:    TPDFFontType;
    FDescriptor:  TPDFFontDescriptor;
    FWidths:      TPDFFontWidths;    // may be nil (e.g. Type0)
    // ToUnicode CMap
    FToUnicode:   TDictionary<Integer, string>;   // charcode → Unicode string
    FProgram:     TPDFFontProgram;   // embedded font program, loaded on demand
    FProgramDone: Boolean;
  public
    constructor Create; virtual;
    destructor  Destroy; override;

    // Decode a character code to a Unicode string (for text extraction)
    function  CharCodeToUnicode(ACharCode: Integer): string; virtual;

    // Get advance width for a character code (in glyph units, 1000 = 1em)
    function  GetWidth(ACharCode: Integer): Single; virtual;

    // Does this font have embedded font data?
    function  HasEmbeddedFont: Boolean; inline;

    // Font program bytes (for Skia typeface loading)
    function  FontBytes: TBytes; virtual;

    // The parsed embedded font program (TrueType, CFF or Type 1); nil when
    // the font is not embedded or its program cannot be read
    function  FontProgram: TPDFFontProgram; virtual;

    // Glyph of a character code in FontProgram; -1 when there is no program
    // or the program has no glyph for the code
    function  GlyphID(ACharCode: Integer): Integer; virtual;

    // Reverse-encode a Unicode char to its byte code(s) in this font's
    // codespace. Used by content-stream redaction to substitute a glyph
    // (e.g. 'X') keeping the SAME code byte-length so the surrounding
    // operand layout/offsets stay stable. ACodeByteLen is the byte width of
    // the code being replaced (1 for simple fonts, 2 for Type0/CID).
    // Returns False if no code in the font maps to AUnicode at that width.
    function  TryEncodeChar(const AUnicode: string; ACodeByteLen: Integer;
      out ACode: TBytes): Boolean;

    property  Name:        string read FName;
    property  FontType:    TPDFFontType read FFontType;
    property  Descriptor:  TPDFFontDescriptor read FDescriptor;
    property  Widths:      TPDFFontWidths read FWidths write FWidths;
    property  ToUnicode:   TDictionary<Integer, string> read FToUnicode;
  end;

  // -------------------------------------------------------------------------
  // Type1 / TrueType (simple fonts)
  // -------------------------------------------------------------------------
  TPDFSimpleFont = class(TPDFFont)
  protected
    FEncoding:     TPDFFontEncodingKind;
    FBaseEncoding: TPDFStdEncoding;               // codes not in Differences
    FExplicitBase: Boolean;                       // /Encoding names a base encoding
    FDifferences:  TDictionary<Integer, string>;  // charcode → glyph name
    function  TrueTypeGlyph(AProgram: TTrueTypeProgram; ACharCode: Integer): Integer;
  public
    constructor Create; override;
    destructor  Destroy; override;

    procedure SetDifferences(ADiffs: TPDFDictionary);
    // Glyph name of a code: Differences, then the base encoding — the
    // built-in encoding of an embedded Type 1/CFF program when /Encoding
    // names none ('' if unknown)
    function  GlyphName(ACharCode: Integer): string;
    function  CharCodeToUnicode(ACharCode: Integer): string; override;
    function  GlyphID(ACharCode: Integer): Integer; override;
    property  Encoding: TPDFFontEncodingKind read FEncoding write FEncoding;
    property  BaseEncoding: TPDFStdEncoding read FBaseEncoding write FBaseEncoding;
  end;

  TPDFType1Font   = class(TPDFSimpleFont);
  TPDFTrueTypeFont= class(TPDFSimpleFont);

  // -------------------------------------------------------------------------
  // Type3 font (glyph programs)
  // -------------------------------------------------------------------------
  TPDFType3Font = class(TPDFFont)
  private
    FCharProcs:    TDictionary<string, TPDFStream>; // name → content stream
    FFontMatrix:   TPDFMatrix;
    FResources:    TPDFDictionary;
    FEncoding:     TDictionary<Integer, string>;    // charcode → proc name
  public
    constructor Create; override;
    destructor  Destroy; override;

    function  GetCharProc(ACharCode: Integer): TPDFStream;
    function  GetWidth(ACharCode: Integer): Single; override;
    property  FontMatrix: TPDFMatrix read FFontMatrix write FFontMatrix;
    property  Resources:  TPDFDictionary read FResources write FResources;
  end;

  // -------------------------------------------------------------------------
  // CID fonts (used inside Type0 composite fonts)
  // -------------------------------------------------------------------------
  TPDFCIDFont = class(TPDFFont)
  private
    FDW:     Single;                          // default width
    FW:      TDictionary<Integer, Single>;    // individual widths
    FW2:     TDictionary<Integer, Single>;    // vertical writing widths
    FCIDToGID: TArray<Word>;                  // CIDFontType2 /CIDToGIDMap stream (nil = Identity)
  public
    constructor Create; override;
    destructor  Destroy; override;

    procedure LoadWidths(ADict: TPDFDictionary);
    function  GetWidth(ACharCode: Integer): Single; override;
    // ACharCode is the CID
    function  GlyphID(ACharCode: Integer): Integer; override;
    property  DefaultWidth: Single read FDW write FDW;
  end;

  TPDFCIDType0Font = class(TPDFCIDFont);
  TPDFCIDType2Font = class(TPDFCIDFont);

  // -------------------------------------------------------------------------
  // Type0 composite font
  // -------------------------------------------------------------------------
  TPDFType0Font = class(TPDFFont)
  private
    FDescendant:   TPDFCIDFont;    // owns
    FCMapName:     string;         // e.g. "Identity-H"
  public
    constructor Create; override;
    destructor  Destroy; override;

    function  CharCodeToUnicode(ACharCode: Integer): string; override;
    function  GetWidth(ACharCode: Integer): Single; override;
    function  GlyphID(ACharCode: Integer): Integer; override;
    function  FontProgram: TPDFFontProgram; override;
    property  Descendant: TPDFCIDFont read FDescendant write FDescendant;
    property  CMapName:   string read FCMapName write FCMapName;
  end;

  // -------------------------------------------------------------------------
  // Font factory: build TPDFFont from a PDF font dictionary
  // -------------------------------------------------------------------------
  TPDFFontFactory = class
  public
    class function Build(AFontDict: TPDFDictionary;
      AResolver: IObjectResolver = nil): TPDFFont; static;
  private
    class procedure LoadToUnicode(AFont: TPDFFont; AFontDict: TPDFDictionary;
      AResolver: IObjectResolver); static;
    class procedure LoadDescriptor(AFont: TPDFFont; ADescDict: TPDFDictionary;
      AResolver: IObjectResolver); static;
    class procedure LoadSimpleEncoding(AFont: TPDFSimpleFont;
      AFontDict: TPDFDictionary); static;
    class procedure LoadWidthsSimple(AFont: TPDFSimpleFont;
      AFontDict: TPDFDictionary); static;
    class procedure LoadWidthsCID(AFont: TPDFCIDFont;
      AFontDict: TPDFDictionary); static;
  end;

implementation

uses
  System.Character, uPDF.FontCMap, uPDF.FontCFF;

// =========================================================================
// TPDFFontDescriptor
// =========================================================================

function TPDFFontDescriptor.HasEmbeddedFont: Boolean;
begin
  Result := (Length(FontFile) > 0) or
            (Length(FontFile2) > 0) or
            (Length(FontFile3) > 0);
end;

// =========================================================================
// TPDFFontWidths
// =========================================================================

constructor TPDFFontWidths.Create(AFirstChar, ALastChar: Integer;
  const AWidths: TArray<Single>; AMissingWidth: Single);
begin
  inherited Create;
  FFirstChar    := AFirstChar;
  FLastChar     := ALastChar;
  FWidths       := AWidths;
  FMissingWidth := AMissingWidth;
end;

function TPDFFontWidths.GetWidth(ACharCode: Integer): Single;
begin
  if (ACharCode < FFirstChar) or (ACharCode > FLastChar) then
    Result := FMissingWidth
  else
  begin
    var Idx := ACharCode - FFirstChar;
    if Idx < Length(FWidths) then
      Result := FWidths[Idx]
    else
      Result := FMissingWidth;
  end;
end;

// =========================================================================
// TPDFFont base
// =========================================================================

constructor TPDFFont.Create;
begin
  inherited;
  FFontType   := TPDFFontType.Unknown;
  FToUnicode  := TDictionary<Integer, string>.Create;
end;

destructor TPDFFont.Destroy;
begin
  FProgram.Free;
  FWidths.Free;
  FToUnicode.Free;
  inherited;
end;

function TPDFFont.CharCodeToUnicode(ACharCode: Integer): string;
begin
  if FToUnicode.TryGetValue(ACharCode, Result) then Exit;
  // Fallback: treat as Latin-1
  if (ACharCode >= 32) and (ACharCode <= 255) then
    Result := Char(ACharCode)
  else
    Result := '';
end;

function TPDFFont.GetWidth(ACharCode: Integer): Single;
begin
  if FWidths <> nil then
    Result := FWidths.GetWidth(ACharCode)
  else
    Result := 1000; // default 1em
end;

function TPDFFont.HasEmbeddedFont: Boolean;
begin
  Result := FDescriptor.HasEmbeddedFont;
end;

function TPDFFont.FontBytes: TBytes;
begin
  if Length(FDescriptor.FontFile2) > 0 then Result := FDescriptor.FontFile2
  else if Length(FDescriptor.FontFile3) > 0 then Result := FDescriptor.FontFile3
  else Result := FDescriptor.FontFile;
end;

function TPDFFont.FontProgram: TPDFFontProgram;
begin
  if not FProgramDone then
  begin
    FProgramDone := True;
    if Length(FDescriptor.FontFile2) > 0 then
      FProgram := LoadFontProgram(FDescriptor.FontFile2, 'FontFile2', '')
    else if Length(FDescriptor.FontFile3) > 0 then
      FProgram := LoadFontProgram(FDescriptor.FontFile3, 'FontFile3', FDescriptor.FontFile3Subtype)
    else if Length(FDescriptor.FontFile) > 0 then
      FProgram := LoadFontProgram(FDescriptor.FontFile, 'FontFile', '');
  end;
  Result := FProgram;
end;

function TPDFFont.GlyphID(ACharCode: Integer): Integer;
begin
  Result := -1;
end;

function TPDFFont.TryEncodeChar(const AUnicode: string; ACodeByteLen: Integer;
  out ACode: TBytes): Boolean;
var
  C:    Integer;
  Pair: TPair<Integer, string>;
begin
  Result := False;
  SetLength(ACode, 0);
  if AUnicode = '' then Exit;

  if ACodeByteLen >= 2 then
  begin
    // Type0 / CID (2-byte codes): find a code whose ToUnicode maps to AUnicode.
    // We can only reuse a CID/code the document already maps to this char; if
    // the char never appears, fail so the caller can fall back (e.g. raster).
    if FToUnicode <> nil then
      for Pair in FToUnicode do
        if (Pair.Value = AUnicode) and (Pair.Key >= 0) and (Pair.Key <= $FFFF) then
        begin
          SetLength(ACode, 2);
          ACode[0] := Byte((Pair.Key shr 8) and $FF);
          ACode[1] := Byte(Pair.Key and $FF);
          Exit(True);
        end;
    Exit(False);
  end;

  // Simple font (1-byte codes): scan 0..255 for a code that decodes to AUnicode.
  // CharCodeToUnicode is virtual (ToUnicode → Differences → standard/Latin-1),
  // so for a normally-encoded font 'X' resolves to code $58.
  for C := 0 to 255 do
    if CharCodeToUnicode(C) = AUnicode then
    begin
      SetLength(ACode, 1);
      ACode[0] := Byte(C);
      Exit(True);
    end;
  Result := False;
end;

// =========================================================================
// TPDFSimpleFont
// =========================================================================

constructor TPDFSimpleFont.Create;
begin
  inherited;
  FEncoding     := TPDFFontEncodingKind.Standard;
  FBaseEncoding := TPDFStdEncoding.Standard;
  FDifferences  := TDictionary<Integer, string>.Create;
end;

destructor TPDFSimpleFont.Destroy;
begin
  FDifferences.Free;
  inherited;
end;

procedure TPDFSimpleFont.SetDifferences(ADiffs: TPDFDictionary);
begin
  // /Differences is actually an array: [code /GlyphName code /GlyphName ...]
  // Caller should pass the array's parent dict or we receive the array directly
  // This method accepts an array-shaped access via PDFDictionary workaround.
  // Actual loading is done in TPDFFontFactory.Build
end;

function TPDFSimpleFont.GlyphName(ACharCode: Integer): string;
begin
  if FDifferences.TryGetValue(ACharCode, Result) then Exit;
  if not FExplicitBase and (FFontType <> TPDFFontType.TrueType) and
     ((Length(FDescriptor.FontFile) > 0) or (Length(FDescriptor.FontFile3) > 0)) then
  begin
    var P := FontProgram;
    if (P <> nil) and P.HasBuiltinEncoding then
      Exit(P.BuiltinGlyphName(ACharCode));
  end;
  Result := StdEncodingGlyph(FBaseEncoding, ACharCode);
end;

function TPDFSimpleFont.GlyphID(ACharCode: Integer): Integer;
var
  P: TPDFFontProgram;
begin
  P := FontProgram;
  if P = nil then Exit(-1);
  if P is TTrueTypeProgram then
    Result := TrueTypeGlyph(TTrueTypeProgram(P), ACharCode)
  else
  begin
    // Type 1 and CFF glyphs are found by name
    var Name := GlyphName(ACharCode);
    Result := P.GlyphByName(Name);
    if (Result < 0) and P.HasBuiltinEncoding then
      Result := P.GlyphByName(P.BuiltinGlyphName(ACharCode));
    if (Result < 0) and (P is TCFFProgram) and TCFFProgram(P).IsCIDKeyed then
      Result := P.GlyphByCID(ACharCode);     // CID-keyed program used as a simple font
  end;
  if Result >= P.GlyphCount then Result := -1;
end;

// Glyph of a code in an embedded TrueType program (ISO 32000-1, 9.6.6.4):
// for a nonsymbolic font the code goes through its glyph name and Unicode to
// the (3,1) cmap; a symbolic font maps codes through the (3,0) cmap (also at
// 0xF000 + code) or the (1,0) cmap; the 'post' names are the last resort.
function TPDFSimpleFont.TrueTypeGlyph(AProgram: TTrueTypeProgram; ACharCode: Integer): Integer;
const
  SYMBOLIC = 4;
var
  Name, U: string;
begin
  Result := 0;
  Name := GlyphName(ACharCode);
  var IsSymbolic := FDescriptor.Flags and SYMBOLIC <> 0;
  var Uni31 := AProgram.HasCmap(3, 1);
  var Uni03 := AProgram.HasCmap(0, 3);
  if (Uni31 or Uni03) and (not IsSymbolic or FExplicitBase or (FDifferences.Count > 0)) then
  begin
    U := GlyphNameToUnicode(Name);
    if U <> '' then
    begin
      var CP := Ord(U[1]);
      if (Length(U) >= 2) and Char.IsSurrogatePair(U, 0) then
        CP := Char.ConvertToUtf32(U, 0);
      if Uni31 then Result := AProgram.CmapGlyph(3, 1, CP);
      if (Result = 0) and Uni03 then Result := AProgram.CmapGlyph(0, 3, CP);
    end;
    if (Result = 0) and (Name <> '') then
      Result := Max(0, AProgram.GlyphByName(Name));
    if Result > 0 then Exit;
  end;
  if AProgram.HasCmap(3, 0) then
    for var Base in [0, $F000, $F100, $F200] do
    begin
      Result := AProgram.CmapGlyph(3, 0, Base + ACharCode);
      if Result > 0 then Exit;
    end;
  if AProgram.HasCmap(1, 0) then
  begin
    Result := AProgram.CmapGlyph(1, 0, ACharCode);
    if Result > 0 then Exit;
  end;
  if Uni31 then
  begin
    // symbolic fonts written with a Unicode cmap keyed by the codes
    Result := AProgram.CmapGlyph(3, 1, ACharCode);
    if Result = 0 then Result := AProgram.CmapGlyph(3, 1, $F000 + ACharCode);
    if Result > 0 then Exit;
  end;
  if Name <> '' then
    Result := Max(0, AProgram.GlyphByName(Name));
  // no usable cmap at all: codes are glyph indices
  if (Result = 0) and not Uni31 and not AProgram.HasCmap(3, 0) and
     not AProgram.HasCmap(1, 0) and not Uni03 then
    Result := ACharCode;
end;

function TPDFSimpleFont.CharCodeToUnicode(ACharCode: Integer): string;
begin
  // Priority 1: ToUnicode CMap
  if FToUnicode.TryGetValue(ACharCode, Result) then Exit;

  // Priority 2: glyph name (Differences or base encoding) → Adobe Glyph List
  Result := GlyphNameToUnicode(GlyphName(ACharCode));
  if Result <> '' then Exit;

  // Priority 3: unknown glyph name or no encoding — treat as Latin-1
  Result := inherited CharCodeToUnicode(ACharCode);
end;

// =========================================================================
// TPDFType3Font
// =========================================================================

constructor TPDFType3Font.Create;
begin
  inherited;
  FFontType  := TPDFFontType.Type3;
  FCharProcs := TDictionary<string, TPDFStream>.Create;
  FEncoding  := TDictionary<Integer, string>.Create;
  FFontMatrix:= TPDFMatrix.Make(0.001, 0, 0, 0.001, 0, 0);
end;

destructor TPDFType3Font.Destroy;
begin
  FEncoding.Free;
  FCharProcs.Free;
  inherited;
end;

function TPDFType3Font.GetCharProc(ACharCode: Integer): TPDFStream;
var
  ProcName: string;
begin
  if FEncoding.TryGetValue(ACharCode, ProcName) then
  begin
    if not FCharProcs.TryGetValue(ProcName, Result) then
      Result := nil;
  end else
    Result := nil;
end;

function TPDFType3Font.GetWidth(ACharCode: Integer): Single;
begin
  Result := inherited GetWidth(ACharCode);
end;

// =========================================================================
// TPDFCIDFont
// =========================================================================

constructor TPDFCIDFont.Create;
begin
  inherited;
  FDW := 1000;
  FW  := TDictionary<Integer, Single>.Create;
  FW2 := TDictionary<Integer, Single>.Create;
end;

destructor TPDFCIDFont.Destroy;
begin
  FW2.Free;
  FW.Free;
  inherited;
end;

function TPDFCIDFont.GlyphID(ACharCode: Integer): Integer;
var
  P: TPDFFontProgram;
begin
  P := FontProgram;
  if P = nil then Exit(-1);
  if P is TTrueTypeProgram then
  begin
    if FCIDToGID = nil then
      Result := ACharCode
    else if (ACharCode >= 0) and (ACharCode < Length(FCIDToGID)) then
      Result := FCIDToGID[ACharCode]
    else
      Result := 0;
  end else
    Result := P.GlyphByCID(ACharCode);
  if (Result < 0) or (Result >= P.GlyphCount) then Result := -1;
end;

// PDF spec: /W array format is one of:
//   c [w1 w2 ...]      — individual widths starting at c
//   cfirst clast w     — range with same width
procedure TPDFCIDFont.LoadWidths(ADict: TPDFDictionary);
begin
  FDW := ADict.GetAsReal('DW', 1000);
  var WArr := ADict.GetAsArray('W');
  if WArr = nil then Exit;

  var I := 0;
  while I < WArr.Count do
  begin
    var First := WArr.GetAsInteger(I);
    Inc(I);
    if I >= WArr.Count then Break;

    var Next := WArr.Items(I);
    if Next.IsArray then
    begin
      // First [w0 w1 w2 ...]
      var SubArr := TPDFArray(Next.Dereference);
      for var J := 0 to SubArr.Count - 1 do
        FW.AddOrSetValue(First + J, SubArr.GetAsReal(J));
      Inc(I);
    end else
    begin
      // First Last W
      var Last := WArr.GetAsInteger(I); Inc(I);
      if I >= WArr.Count then Break;
      var W := WArr.GetAsReal(I); Inc(I);
      for var CID := First to Last do
        FW.AddOrSetValue(CID, W);
    end;
  end;
end;

function TPDFCIDFont.GetWidth(ACharCode: Integer): Single;
begin
  if not FW.TryGetValue(ACharCode, Result) then
    Result := FDW;
end;

// =========================================================================
// TPDFType0Font
// =========================================================================

constructor TPDFType0Font.Create;
begin
  inherited;
  FFontType := TPDFFontType.Type0;
end;

destructor TPDFType0Font.Destroy;
begin
  FDescendant.Free;
  inherited;
end;

function TPDFType0Font.CharCodeToUnicode(ACharCode: Integer): string;
begin
  if FToUnicode.TryGetValue(ACharCode, Result) then Exit;
  // For Identity-H/V: char code is the Unicode codepoint
  if FCMapName.Contains('Identity') then
    Result := Char(ACharCode)
  else
    Result := inherited CharCodeToUnicode(ACharCode);
end;

function TPDFType0Font.FontProgram: TPDFFontProgram;
begin
  if FDescendant <> nil then
    Result := FDescendant.FontProgram
  else
    Result := nil;
end;

function TPDFType0Font.GlyphID(ACharCode: Integer): Integer;
begin
  // Identity-H/V: the code is the CID
  if FDescendant <> nil then
    Result := FDescendant.GlyphID(ACharCode)
  else
    Result := -1;
end;

function TPDFType0Font.GetWidth(ACharCode: Integer): Single;
begin
  if FDescendant <> nil then
    Result := FDescendant.GetWidth(ACharCode)
  else
    Result := 1000;
end;

// =========================================================================
// TPDFFontFactory
// =========================================================================

class function TPDFFontFactory.Build(AFontDict: TPDFDictionary;
  AResolver: IObjectResolver): TPDFFont;
var
  Subtype:  string;
  EncObj, DescObj, CPObj, ResObj: TPDFObject;
  DescFonts: TPDFArray;
begin
  if AFontDict = nil then Exit(nil);

  Subtype := AFontDict.GetAsName('Subtype');

  if (Subtype = 'Type1') or (Subtype = 'MMType1') or (Subtype = 'TrueType') then
  begin
    var F: TPDFSimpleFont;
    if Subtype = 'TrueType' then
    begin
      F := TPDFTrueTypeFont.Create;
      F.FFontType := TPDFFontType.TrueType;
    end else
    begin
      F := TPDFType1Font.Create;
      F.FFontType := TPDFFontType.Type1;
    end;
    F.FName := AFontDict.GetAsName('BaseFont');
    DescObj := AFontDict.Get('FontDescriptor');
    if (DescObj <> nil) and DescObj.IsDictionary then
      LoadDescriptor(F, TPDFDictionary(DescObj), AResolver);
    LoadToUnicode(F, AFontDict, AResolver);
    LoadSimpleEncoding(F, AFontDict);
    LoadWidthsSimple(F, AFontDict);
    Result := F;
  end
  else if Subtype = 'Type3' then
  begin
    var F := TPDFType3Font.Create;
    F.FName := AFontDict.GetAsName('Name');
    // Load CharProcs
    CPObj := AFontDict.Get('CharProcs');
    if (CPObj <> nil) and CPObj.IsDictionary then
      TPDFDictionary(CPObj).ForEach(procedure(K: string; V: TPDFObject)
      begin
        if V.IsStream then
          F.FCharProcs.AddOrSetValue(K, TPDFStream(V));
      end);
    // Load Encoding
    EncObj := AFontDict.Get('Encoding');
    if (EncObj <> nil) and EncObj.IsDictionary then
    begin
      var DiffArr := TPDFDictionary(EncObj).GetAsArray('Differences');
      if DiffArr <> nil then
      begin
        var Code := 0;
        for var I := 0 to DiffArr.Count - 1 do
        begin
          var Item := DiffArr.Items(I);
          if Item.IsInteger then Code := Item.AsInteger
          else if Item.IsName then
          begin
            F.FEncoding.AddOrSetValue(Code, Item.AsName);
            Inc(Code);
          end;
        end;
      end;
    end;
    // FontMatrix
    if AFontDict.Contains('FontMatrix') then
      F.FFontMatrix := AFontDict.GetMatrix('FontMatrix');
    // Resources
    ResObj := AFontDict.Get('Resources');
    if (ResObj <> nil) and ResObj.IsDictionary then
      F.FResources := TPDFDictionary(ResObj);
    LoadToUnicode(F, AFontDict, AResolver);
    Result := F;
  end
  else if Subtype = 'Type0' then
  begin
    var F := TPDFType0Font.Create;
    F.FName    := AFontDict.GetAsName('BaseFont');
    F.FCMapName:= AFontDict.GetAsName('Encoding'); // usually Identity-H
    // Load descendant font
    DescFonts := AFontDict.GetAsArray('DescendantFonts');
    if (DescFonts <> nil) and (DescFonts.Count > 0) then
    begin
      var DescObj2 := DescFonts.Get(0);
      if (DescObj2 <> nil) and DescObj2.IsDictionary then
      begin
        var DescDict := TPDFDictionary(DescObj2);
        var DescSubtype := DescDict.GetAsName('Subtype');
        var CIDFont: TPDFCIDFont;
        if DescSubtype = 'CIDFontType0' then
          CIDFont := TPDFCIDType0Font.Create
        else
          CIDFont := TPDFCIDType2Font.Create;
        CIDFont.FName     := DescDict.GetAsName('BaseFont');
        if DescSubtype = 'CIDFontType0' then
          CIDFont.FFontType := TPDFFontType.CIDType0
        else
          CIDFont.FFontType := TPDFFontType.CIDType2;
        CIDFont.LoadWidths(DescDict);
        var MapObj := DescDict.Get('CIDToGIDMap');
        if (MapObj <> nil) and MapObj.IsStream then
        begin
          var Map := TPDFStream(MapObj).DecodedBytes;
          SetLength(CIDFont.FCIDToGID, Length(Map) div 2);
          for var I := 0 to High(CIDFont.FCIDToGID) do
            CIDFont.FCIDToGID[I] := (Map[I * 2] shl 8) or Map[I * 2 + 1];
        end;
        var CIDDescObj := DescDict.Get('FontDescriptor');
        if (CIDDescObj <> nil) and CIDDescObj.IsDictionary then
          LoadDescriptor(CIDFont, TPDFDictionary(CIDDescObj), AResolver);
        F.FDescendant := CIDFont;
      end;
    end;
    LoadToUnicode(F, AFontDict, AResolver);
    Result := F;
  end
  else
  begin
    // Unknown font type — create a basic Type1-like font
    var F := TPDFType1Font.Create;
    F.FFontType := TPDFFontType.Type1;
    F.FName     := AFontDict.GetAsName('BaseFont');
    LoadToUnicode(F, AFontDict, AResolver);
    LoadSimpleEncoding(F, AFontDict);
    LoadWidthsSimple(F, AFontDict);
    Result := F;
  end;
end;

class procedure TPDFFontFactory.LoadToUnicode(AFont: TPDFFont;
  AFontDict: TPDFDictionary; AResolver: IObjectResolver);
begin
  var TUObj := AFontDict.Get('ToUnicode');
  if (TUObj = nil) or not TUObj.IsStream then Exit;

  var CMapData := TPDFStream(TUObj).DecodedAsString;
  if CMapData = '' then Exit;

  // Parse ToUnicode CMap using the CMap parser
  TPDFCMapParser.ParseToUnicode(string(CMapData), AFont.FToUnicode);
end;

class procedure TPDFFontFactory.LoadDescriptor(AFont: TPDFFont;
  ADescDict: TPDFDictionary; AResolver: IObjectResolver);

  function LoadFontFile(AKey: string): TBytes;
  begin
    var FObj := ADescDict.Get(AKey);
    if (FObj <> nil) and FObj.IsStream then
      Result := TPDFStream(FObj).DecodedBytes
    else
      Result := nil;
  end;

begin
  AFont.FDescriptor.FontName    := ADescDict.GetAsName('FontName');
  AFont.FDescriptor.Flags       := ADescDict.GetAsInteger('Flags');
  AFont.FDescriptor.FontBBox    := ADescDict.GetRect('FontBBox');
  AFont.FDescriptor.ItalicAngle := ADescDict.GetAsReal('ItalicAngle');
  AFont.FDescriptor.Ascent      := ADescDict.GetAsReal('Ascent');
  AFont.FDescriptor.Descent     := ADescDict.GetAsReal('Descent');
  AFont.FDescriptor.CapHeight   := ADescDict.GetAsReal('CapHeight');
  AFont.FDescriptor.XHeight     := ADescDict.GetAsReal('XHeight');
  AFont.FDescriptor.StemV       := ADescDict.GetAsReal('StemV');
  AFont.FDescriptor.StemH       := ADescDict.GetAsReal('StemH');
  AFont.FDescriptor.FontFile    := LoadFontFile('FontFile');
  AFont.FDescriptor.FontFile2   := LoadFontFile('FontFile2');
  AFont.FDescriptor.FontFile3   := LoadFontFile('FontFile3');
  var FF3 := ADescDict.Get('FontFile3');
  if (FF3 <> nil) and FF3.IsStream then
    AFont.FDescriptor.FontFile3Subtype := TPDFStream(FF3).Dict.GetAsName('Subtype');
end;

class procedure TPDFFontFactory.LoadSimpleEncoding(AFont: TPDFSimpleFont;
  AFontDict: TPDFDictionary);
const
  SYMBOLIC    = 4;
  NONSYMBOLIC = 32;

  function NamedEncoding(const AName: string; out AKind: TPDFFontEncodingKind;
    out ABase: TPDFStdEncoding): Boolean;
  begin
    Result := True;
    if AName = 'WinAnsiEncoding' then
    begin
      AKind := TPDFFontEncodingKind.WinAnsi;
      ABase := TPDFStdEncoding.WinAnsi;
    end else if AName = 'MacRomanEncoding' then
    begin
      AKind := TPDFFontEncodingKind.MacRoman;
      ABase := TPDFStdEncoding.MacRoman;
    end else if AName = 'StandardEncoding' then
    begin
      AKind := TPDFFontEncodingKind.Standard;
      ABase := TPDFStdEncoding.Standard;
    end else
      Result := False;
  end;

var
  Kind: TPDFFontEncodingKind;
  Base: TPDFStdEncoding;
begin
  // Implicit base encoding (ISO 32000-1, 9.6.6): the font's built-in one. For
  // a Type1 font that is StandardEncoding unless it is Symbol/ZapfDingbats;
  // symbolic TrueType fonts map codes straight to glyphs, and the other
  // TrueType fonts are in practice written for WinAnsi.
  var Std := StdFontIndex(AFont.FName);
  if Std >= 0 then
    AFont.FBaseEncoding := StdFontEncoding(Std)
  else if AFont.FFontType <> TPDFFontType.TrueType then
    AFont.FBaseEncoding := TPDFStdEncoding.Standard
  else if (AFont.FDescriptor.Flags and SYMBOLIC <> 0) and
          (AFont.FDescriptor.Flags and NONSYMBOLIC = 0) then
    AFont.FBaseEncoding := TPDFStdEncoding.None
  else
    AFont.FBaseEncoding := TPDFStdEncoding.WinAnsi;
  AFont.FEncoding := TPDFFontEncodingKind.Standard;

  var EncObj := AFontDict.Get('Encoding');
  if EncObj = nil then Exit;
  if EncObj.IsName then
  begin
    if NamedEncoding(EncObj.AsName, Kind, Base) then
    begin
      AFont.FEncoding     := Kind;
      AFont.FBaseEncoding := Base;
      AFont.FExplicitBase := True;
    end;
  end else if EncObj.IsDictionary then
  begin
    var EncDict := TPDFDictionary(EncObj);
    if NamedEncoding(EncDict.GetAsName('BaseEncoding'), Kind, Base) then
    begin
      AFont.FEncoding     := Kind;
      AFont.FBaseEncoding := Base;
      AFont.FExplicitBase := True;
    end;
    // Load Differences array
    var DiffArr := EncDict.GetAsArray('Differences');
    if DiffArr <> nil then
    begin
      var Code := 0;
      for var I := 0 to DiffArr.Count - 1 do
      begin
        var Item := DiffArr.Items(I);
        if Item.IsInteger then
          Code := Item.AsInteger
        else if Item.IsName then
        begin
          AFont.FDifferences.AddOrSetValue(Code, Item.AsName);
          Inc(Code);
        end;
      end;
      if AFont.FDifferences.Count > 0 then
        AFont.FEncoding := TPDFFontEncodingKind.Differences;
    end;
  end;
end;

class procedure TPDFFontFactory.LoadWidthsSimple(AFont: TPDFSimpleFont;
  AFontDict: TPDFDictionary);
begin
  var FirstChar := AFontDict.GetAsInteger('FirstChar', 0);
  var LastChar  := AFontDict.GetAsInteger('LastChar',  255);
  var WArr      := AFontDict.GetAsArray('Widths');
  var Missing   := 0.0;

  var DescObj := AFontDict.Get('FontDescriptor');
  if (DescObj <> nil) and DescObj.IsDictionary then
    Missing := TPDFDictionary(DescObj).GetAsReal('MissingWidth', 0);

  var Widths: TArray<Single>;
  if (WArr <> nil) and (WArr.Count > 0) then
  begin
    SetLength(Widths, WArr.Count);
    for var I := 0 to WArr.Count - 1 do
      Widths[I] := WArr.GetAsReal(I);
    AFont.FWidths := TPDFFontWidths.Create(FirstChar, LastChar, Widths, Missing);
    Exit;
  end;

  // No /Widths: the 14 standard fonts take their AFM metrics (9.6.2.2); any
  // other font is approximated by the standard font closest to its flags.
  var Std := StdFontSubstitute(AFont.FDescriptor.Flags, AFont.FName);
  SetLength(Widths, 256);
  for var C := 0 to 255 do
  begin
    var G := AFont.GlyphName(C);
    if (G = '') and (AFont.FBaseEncoding = TPDFStdEncoding.None) then
      G := StdEncodingGlyph(StdFontEncoding(Std), C);
    var W: Integer;
    if (G <> '') and StdGlyphWidth(Std, G, W) then
      Widths[C] := W
    else
      Widths[C] := Missing;
  end;
  AFont.FWidths := TPDFFontWidths.Create(0, 255, Widths, Missing);
end;

class procedure TPDFFontFactory.LoadWidthsCID(AFont: TPDFCIDFont;
  AFontDict: TPDFDictionary);
begin
  AFont.LoadWidths(AFontDict);
end;

end.
