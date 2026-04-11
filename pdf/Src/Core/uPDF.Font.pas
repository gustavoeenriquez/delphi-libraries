unit uPDF.Font;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.Math,
  uPDF.Types, uPDF.Errors, uPDF.Objects;

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
    FDifferences:  TDictionary<Integer, string>;  // charcode → glyph name
    FGlyphNameToUnicode: TDictionary<string, string>;
  public
    constructor Create; override;
    destructor  Destroy; override;

    procedure SetDifferences(ADiffs: TPDFDictionary);
    function  CharCodeToUnicode(ACharCode: Integer): string; override;
    property  Encoding: TPDFFontEncodingKind read FEncoding write FEncoding;
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
  public
    constructor Create; override;
    destructor  Destroy; override;

    procedure LoadWidths(ADict: TPDFDictionary);
    function  GetWidth(ACharCode: Integer): Single; override;
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
    class procedure LoadWidthsSimple(AFont: TPDFSimpleFont;
      AFontDict: TPDFDictionary); static;
    class procedure LoadWidthsCID(AFont: TPDFCIDFont;
      AFontDict: TPDFDictionary); static;
  end;

implementation

uses
  uPDF.FontCMap;

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

// =========================================================================
// TPDFSimpleFont
// =========================================================================

constructor TPDFSimpleFont.Create;
begin
  inherited;
  FEncoding   := TPDFFontEncodingKind.Standard;
  FDifferences := TDictionary<Integer, string>.Create;
  // Build glyph name → Unicode table (Adobe Glyph List, partial)
  FGlyphNameToUnicode := TDictionary<string, string>.Create;
  // Most common entries:
  FGlyphNameToUnicode.Add('space',     ' ');
  FGlyphNameToUnicode.Add('period',    '.');
  FGlyphNameToUnicode.Add('comma',     ',');
  FGlyphNameToUnicode.Add('hyphen',    '-');
  FGlyphNameToUnicode.Add('parenleft', '(');
  FGlyphNameToUnicode.Add('parenright',')');
  FGlyphNameToUnicode.Add('quotedbl',  '"');
  FGlyphNameToUnicode.Add('quoteleft', #$2018);
  FGlyphNameToUnicode.Add('quoteright',#$2019);
  FGlyphNameToUnicode.Add('quotedblleft', #$201C);
  FGlyphNameToUnicode.Add('quotedblright',#$201D);
  FGlyphNameToUnicode.Add('endash',    #$2013);
  FGlyphNameToUnicode.Add('emdash',    #$2014);
  FGlyphNameToUnicode.Add('bullet',    #$2022);
  FGlyphNameToUnicode.Add('ellipsis',  #$2026);
  FGlyphNameToUnicode.Add('fi',        #$FB01);
  FGlyphNameToUnicode.Add('fl',        #$FB02);
  FGlyphNameToUnicode.Add('ae',        #$00E6);
  FGlyphNameToUnicode.Add('AE',        #$00C6);
  FGlyphNameToUnicode.Add('oe',        #$0153);
  FGlyphNameToUnicode.Add('OE',        #$0152);
  FGlyphNameToUnicode.Add('germandbls',#$00DF);
  // a-z, A-Z map to themselves
  for var C := Ord('a') to Ord('z') do
    FGlyphNameToUnicode.TryAdd(Char(C), Char(C));
  for var C := Ord('A') to Ord('Z') do
    FGlyphNameToUnicode.TryAdd(Char(C), Char(C));
  for var C := Ord('0') to Ord('9') do
    FGlyphNameToUnicode.TryAdd(Char(C), Char(C));
end;

destructor TPDFSimpleFont.Destroy;
begin
  FGlyphNameToUnicode.Free;
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

function TPDFSimpleFont.CharCodeToUnicode(ACharCode: Integer): string;
begin
  // Priority 1: ToUnicode CMap
  if FToUnicode.TryGetValue(ACharCode, Result) then Exit;

  // Priority 2: Differences array → glyph name → AGL
  var GlyphName: string;
  if FDifferences.TryGetValue(ACharCode, GlyphName) then
  begin
    if FGlyphNameToUnicode.TryGetValue(GlyphName, Result) then Exit;
    // Try parsing 'uniXXXX' or 'uXXXX' glyph names
    if GlyphName.StartsWith('uni') and (Length(GlyphName) = 7) then
    begin
      var Hex := GlyphName.Substring(3);
      var V: Integer;
      if TryStrToInt('$' + Hex, V) then
      begin
        Result := Char(V);
        Exit;
      end;
    end;
    if GlyphName.StartsWith('u') and (Length(GlyphName) in [5, 6, 7]) then
    begin
      var Hex := GlyphName.Substring(1);
      var V: Integer;
      if TryStrToInt('$' + Hex, V) and (V >= $20) then
      begin
        Result := Char(V);
        Exit;
      end;
    end;
  end;

  // Priority 3: Encoding-based fallback
  case FEncoding of
    TPDFFontEncodingKind.WinAnsi,
    TPDFFontEncodingKind.Standard:
      if (ACharCode >= 32) and (ACharCode <= 255) then
        Result := Char(ACharCode)
      else
        Result := '';
    TPDFFontEncodingKind.MacRoman:
    begin
      // MacRoman high bytes differ from Latin-1; partial mapping
      if ACharCode < 128 then Result := Char(ACharCode)
      else Result := Char(ACharCode); // simplified
    end;
  else
    Result := inherited CharCodeToUnicode(ACharCode);
  end;
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

  if (Subtype = 'Type1') or (Subtype = 'MMType1') then
  begin
    var F := TPDFType1Font.Create;
    F.FFontType := TPDFFontType.Type1;
    F.FName     := AFontDict.GetAsName('BaseFont');
    LoadWidthsSimple(F, AFontDict);
    LoadToUnicode(F, AFontDict, AResolver);
    EncObj := AFontDict.Get('Encoding');
    if EncObj <> nil then
    begin
      if EncObj.IsName then
      begin
        var EN := EncObj.AsName;
        if EN = 'WinAnsiEncoding'    then F.FEncoding := TPDFFontEncodingKind.WinAnsi
        else if EN = 'MacRomanEncoding' then F.FEncoding := TPDFFontEncodingKind.MacRoman
        else F.FEncoding := TPDFFontEncodingKind.Standard;
      end else if EncObj.IsDictionary then
      begin
        var EncDict := TPDFDictionary(EncObj);
        var BaseEnc := EncDict.GetAsName('BaseEncoding');
        if BaseEnc = 'WinAnsiEncoding'  then F.FEncoding := TPDFFontEncodingKind.WinAnsi
        else if BaseEnc = 'MacRomanEncoding' then F.FEncoding := TPDFFontEncodingKind.MacRoman
        else F.FEncoding := TPDFFontEncodingKind.Standard;
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
              F.FDifferences.AddOrSetValue(Code, Item.AsName);
              Inc(Code);
            end;
          end;
          if F.FDifferences.Count > 0 then
            F.FEncoding := TPDFFontEncodingKind.Differences;
        end;
      end;
    end;
    DescObj := AFontDict.Get('FontDescriptor');
    if (DescObj <> nil) and DescObj.IsDictionary then
      LoadDescriptor(F, TPDFDictionary(DescObj), AResolver);
    Result := F;
  end
  else if Subtype = 'TrueType' then
  begin
    var F := TPDFTrueTypeFont.Create;
    F.FFontType := TPDFFontType.TrueType;
    F.FName     := AFontDict.GetAsName('BaseFont');
    LoadWidthsSimple(F, AFontDict);
    LoadToUnicode(F, AFontDict, AResolver);
    DescObj := AFontDict.Get('FontDescriptor');
    if (DescObj <> nil) and DescObj.IsDictionary then
      LoadDescriptor(F, TPDFDictionary(DescObj), AResolver);
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
        CIDFont.FFontType := TPDFFontType.CIDType2;
        CIDFont.LoadWidths(DescDict);
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
    LoadWidthsSimple(F, AFontDict);
    LoadToUnicode(F, AFontDict, AResolver);
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

  if WArr = nil then Exit;

  var Widths: TArray<Single>;
  SetLength(Widths, WArr.Count);
  for var I := 0 to WArr.Count - 1 do
    Widths[I] := WArr.GetAsReal(I);

  AFont.FWidths := TPDFFontWidths.Create(FirstChar, LastChar, Widths, Missing);
end;

class procedure TPDFFontFactory.LoadWidthsCID(AFont: TPDFCIDFont;
  AFontDict: TPDFDictionary);
begin
  AFont.LoadWidths(AFontDict);
end;

end.
