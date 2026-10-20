unit uPDF.FontProgram;

// Embedded font programs for rendering: glyph lookup (by name, CID, cmap,
// built-in encoding) and glyph outlines, independent of the platform font
// engine (DirectWrite does not load bare CFF or Type 1 programs, and the
// subset TrueType programs of PDF files often lack the tables it requires).
//
// This unit holds the common class and the TrueType reader ('glyf', 'loca',
// 'cmap' formats 0/4/6/12, 'post' names); uPDF.FontCFF reads CFF (Type1C,
// CIDFontType0C, OpenType 'CFF ') and uPDF.FontType1 Type 1 programs.

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Types, System.Math, System.Generics.Collections,
  uPDF.Types;

type
  TGlyphOpKind = (MoveTo, LineTo, CurveTo, Close);

  TGlyphOp = record
    Kind: TGlyphOpKind;
    X1, Y1, X2, Y2, X3, Y3: Single;   // MoveTo / LineTo use X1, Y1
  end;

  // Outline in glyph space (font units, y up); FontMatrix maps it to text space
  TGlyphOutline = TArray<TGlyphOp>;

  TGlyphOutlineBuilder = record
  private
    FOps:   TGlyphOutline;
    FCount: Integer;
    FOpen:  Boolean;
    procedure Add(const AOp: TGlyphOp);
  public
    procedure Init;
    procedure MoveTo(X, Y: Single);
    procedure LineTo(X, Y: Single);
    procedure CurveTo(X1, Y1, X2, Y2, X3, Y3: Single);
    procedure Close;
    // Appends AOutline transformed by the matrix [A B C D E F]
    procedure Append(const AOutline: TGlyphOutline; A, B, C, D, E, F: Single);
    function  Build: TGlyphOutline;
  end;

  TFontProgramKind = (TrueType, CFF, Type1);

  TPDFFontProgram = class abstract
  protected
    FFontMatrix: TPDFMatrix;
  public
    constructor Create;
    function  Kind: TFontProgramKind; virtual; abstract;
    function  GlyphCount: Integer; virtual; abstract;
    // Outline of a glyph; nil for an empty glyph or an invalid index
    function  GlyphOutline(AGID: Integer): TGlyphOutline; virtual; abstract;
    // Glyph by PostScript name; -1 when the program has no such glyph
    function  GlyphByName(const AName: string): Integer; virtual;
    // PostScript name of a glyph; '' when the program has no names
    function  GlyphName(AGID: Integer): string; virtual;
    // Glyph by CID (CID-keyed CFF); the CID itself for other programs
    function  GlyphByCID(ACID: Integer): Integer; virtual;
    // Built-in encoding (Type 1, CFF): glyph name of a code, '' if none
    function  HasBuiltinEncoding: Boolean; virtual;
    function  BuiltinGlyphName(ACode: Integer): string; virtual;
    // Glyph space → text space (1 unit = 1 em)
    property  FontMatrix: TPDFMatrix read FFontMatrix;
  end;

  TTrueTypeProgram = class(TPDFFontProgram)
  private
    FData:      TBytes;
    FNumGlyphs: Integer;
    FLocaLong:  Boolean;
    FGlyf, FLoca, FGlyfLen: Integer;
    FCmaps:     TObjectDictionary<Integer, TDictionary<Cardinal, Integer>>;  // platform*65536+encoding
    FNames:     TDictionary<string, Integer>;
    FGlyphNames: TArray<string>;
    function  U8(AOff: Integer): Integer; inline;
    function  U16(AOff: Integer): Integer; inline;
    function  S16(AOff: Integer): Integer; inline;
    function  U32(AOff: Integer): Cardinal; inline;
    function  FindTable(ADir: Integer; const ATag: AnsiString; out AOff, ALen: Integer): Boolean;
    procedure ParseCmap(AOff, ALen: Integer);
    procedure ParsePost(AOff, ALen: Integer);
    function  GlyphRange(AGID: Integer; out AStart, ALen: Integer): Boolean;
    procedure AddGlyph(var B: TGlyphOutlineBuilder; AGID: Integer;
      A, BB, C, D, E, F: Single; ADepth: Integer);
  public
    // AData: a TrueType font (sfnt version 1.0 or 'true', or the first font of a 'ttcf')
    constructor Create(const AData: TBytes);
    destructor  Destroy; override;
    function  Kind: TFontProgramKind; override;
    function  GlyphCount: Integer; override;
    function  GlyphOutline(AGID: Integer): TGlyphOutline; override;
    function  GlyphByName(const AName: string): Integer; override;
    function  GlyphName(AGID: Integer): string; override;
    function  HasCmap(APlatform, AEncoding: Integer): Boolean;
    // Glyph of a code in a cmap subtable; 0 when it is not mapped
    function  CmapGlyph(APlatform, AEncoding: Integer; ACode: Cardinal): Integer;
  end;

  EFontProgramError = class(Exception);

// Builds the program of a font file stream; nil when the format is unknown or
// the data is unreadable. AKey is FontFile, FontFile2 or FontFile3 and
// ASubtype the /Subtype of a FontFile3 stream.
function LoadFontProgram(const AData: TBytes; const AKey, ASubtype: string): TPDFFontProgram;

implementation

uses
  uPDF.FontCFF, uPDF.FontType1;

const
  // Standard Macintosh glyph order ('post' formats 1.0 and 2.0)
  MAC_GLYPHS: array[0..257] of string = (
    '.notdef', '.null', 'nonmarkingreturn', 'space', 'exclam', 'quotedbl',
    'numbersign', 'dollar', 'percent', 'ampersand', 'quotesingle', 'parenleft',
    'parenright', 'asterisk', 'plus', 'comma', 'hyphen', 'period',
    'slash', 'zero', 'one', 'two', 'three', 'four',
    'five', 'six', 'seven', 'eight', 'nine', 'colon',
    'semicolon', 'less', 'equal', 'greater', 'question', 'at',
    'A', 'B', 'C', 'D', 'E', 'F',
    'G', 'H', 'I', 'J', 'K', 'L',
    'M', 'N', 'O', 'P', 'Q', 'R',
    'S', 'T', 'U', 'V', 'W', 'X',
    'Y', 'Z', 'bracketleft', 'backslash', 'bracketright', 'asciicircum',
    'underscore', 'grave', 'a', 'b', 'c', 'd',
    'e', 'f', 'g', 'h', 'i', 'j',
    'k', 'l', 'm', 'n', 'o', 'p',
    'q', 'r', 's', 't', 'u', 'v',
    'w', 'x', 'y', 'z', 'braceleft', 'bar',
    'braceright', 'asciitilde', 'Adieresis', 'Aring', 'Ccedilla', 'Eacute',
    'Ntilde', 'Odieresis', 'Udieresis', 'aacute', 'agrave', 'acircumflex',
    'adieresis', 'atilde', 'aring', 'ccedilla', 'eacute', 'egrave',
    'ecircumflex', 'edieresis', 'iacute', 'igrave', 'icircumflex', 'idieresis',
    'ntilde', 'oacute', 'ograve', 'ocircumflex', 'odieresis', 'otilde',
    'uacute', 'ugrave', 'ucircumflex', 'udieresis', 'dagger', 'degree',
    'cent', 'sterling', 'section', 'bullet', 'paragraph', 'germandbls',
    'registered', 'copyright', 'trademark', 'acute', 'dieresis', 'notequal',
    'AE', 'Oslash', 'infinity', 'plusminus', 'lessequal', 'greaterequal',
    'yen', 'mu', 'partialdiff', 'summation', 'product', 'pi',
    'integral', 'ordfeminine', 'ordmasculine', 'Omega', 'ae', 'oslash',
    'questiondown', 'exclamdown', 'logicalnot', 'radical', 'florin', 'approxequal',
    'Delta', 'guillemotleft', 'guillemotright', 'ellipsis', 'nonbreakingspace', 'Agrave',
    'Atilde', 'Otilde', 'OE', 'oe', 'endash', 'emdash',
    'quotedblleft', 'quotedblright', 'quoteleft', 'quoteright', 'divide', 'lozenge',
    'ydieresis', 'Ydieresis', 'fraction', 'currency', 'guilsinglleft', 'guilsinglright',
    'fi', 'fl', 'daggerdbl', 'periodcentered', 'quotesinglbase', 'quotedblbase',
    'perthousand', 'Acircumflex', 'Ecircumflex', 'Aacute', 'Edieresis', 'Egrave',
    'Iacute', 'Icircumflex', 'Idieresis', 'Igrave', 'Oacute', 'Ocircumflex',
    'apple', 'Ograve', 'Uacute', 'Ucircumflex', 'Ugrave', 'dotlessi',
    'circumflex', 'tilde', 'macron', 'breve', 'dotaccent', 'ring',
    'cedilla', 'hungarumlaut', 'ogonek', 'caron', 'Lslash', 'lslash',
    'Scaron', 'scaron', 'Zcaron', 'zcaron', 'brokenbar', 'Eth',
    'eth', 'Yacute', 'yacute', 'Thorn', 'thorn', 'minus',
    'multiply', 'onesuperior', 'twosuperior', 'threesuperior', 'onehalf', 'onequarter',
    'threequarters', 'franc', 'Gbreve', 'gbreve', 'Idotaccent', 'Scedilla',
    'scedilla', 'Cacute', 'cacute', 'Ccaron', 'ccaron', 'dcroat');

  MAX_COMPOSITE_DEPTH = 8;

// =========================================================================
// TGlyphOutlineBuilder
// =========================================================================

procedure TGlyphOutlineBuilder.Init;
begin
  FOps   := nil;
  FCount := 0;
  FOpen  := False;
end;

procedure TGlyphOutlineBuilder.Add(const AOp: TGlyphOp);
begin
  if FCount = Length(FOps) then
    SetLength(FOps, Max(16, FCount * 2));
  FOps[FCount] := AOp;
  Inc(FCount);
end;

procedure TGlyphOutlineBuilder.MoveTo(X, Y: Single);
var
  Op: TGlyphOp;
begin
  Close;
  Op := Default(TGlyphOp);
  Op.Kind := TGlyphOpKind.MoveTo;
  Op.X1 := X;
  Op.Y1 := Y;
  // A moveto right after another one replaces it (no empty contours)
  if (FCount > 0) and (FOps[FCount - 1].Kind = TGlyphOpKind.MoveTo) then
    FOps[FCount - 1] := Op
  else
    Add(Op);
  FOpen := True;
end;

procedure TGlyphOutlineBuilder.LineTo(X, Y: Single);
var
  Op: TGlyphOp;
begin
  Op := Default(TGlyphOp);
  Op.Kind := TGlyphOpKind.LineTo;
  Op.X1 := X;
  Op.Y1 := Y;
  Add(Op);
  FOpen := True;
end;

procedure TGlyphOutlineBuilder.CurveTo(X1, Y1, X2, Y2, X3, Y3: Single);
var
  Op: TGlyphOp;
begin
  Op.Kind := TGlyphOpKind.CurveTo;
  Op.X1 := X1; Op.Y1 := Y1;
  Op.X2 := X2; Op.Y2 := Y2;
  Op.X3 := X3; Op.Y3 := Y3;
  Add(Op);
  FOpen := True;
end;

procedure TGlyphOutlineBuilder.Close;
var
  Op: TGlyphOp;
begin
  if not FOpen then Exit;
  FOpen := False;
  if FOps[FCount - 1].Kind = TGlyphOpKind.MoveTo then
  begin
    Dec(FCount);               // a contour with no segments
    Exit;
  end;
  Op := Default(TGlyphOp);
  Op.Kind := TGlyphOpKind.Close;
  Add(Op);
end;

procedure TGlyphOutlineBuilder.Append(const AOutline: TGlyphOutline;
  A, B, C, D, E, F: Single);
var
  Op: TGlyphOp;
begin
  Close;
  for var Src in AOutline do
  begin
    Op.Kind := Src.Kind;
    Op.X1 := Src.X1 * A + Src.Y1 * C + E;  Op.Y1 := Src.X1 * B + Src.Y1 * D + F;
    Op.X2 := Src.X2 * A + Src.Y2 * C + E;  Op.Y2 := Src.X2 * B + Src.Y2 * D + F;
    Op.X3 := Src.X3 * A + Src.Y3 * C + E;  Op.Y3 := Src.X3 * B + Src.Y3 * D + F;
    Add(Op);
  end;
end;

function TGlyphOutlineBuilder.Build: TGlyphOutline;
begin
  Close;
  Result := Copy(FOps, 0, FCount);
end;

// =========================================================================
// TPDFFontProgram
// =========================================================================

constructor TPDFFontProgram.Create;
begin
  inherited Create;
  FFontMatrix := TPDFMatrix.Make(0.001, 0, 0, 0.001, 0, 0);
end;

function TPDFFontProgram.GlyphByName(const AName: string): Integer;
begin
  Result := -1;
end;

function TPDFFontProgram.GlyphName(AGID: Integer): string;
begin
  Result := '';
end;

function TPDFFontProgram.GlyphByCID(ACID: Integer): Integer;
begin
  Result := ACID;
end;

function TPDFFontProgram.HasBuiltinEncoding: Boolean;
begin
  Result := False;
end;

function TPDFFontProgram.BuiltinGlyphName(ACode: Integer): string;
begin
  Result := '';
end;

// =========================================================================
// TTrueTypeProgram
// =========================================================================

constructor TTrueTypeProgram.Create(const AData: TBytes);
var
  Dir, Off, Len: Integer;
begin
  inherited Create;
  FData  := AData;
  FCmaps := TObjectDictionary<Integer, TDictionary<Cardinal, Integer>>.Create([doOwnsValues]);
  FNames := TDictionary<string, Integer>.Create;
  if Length(FData) < 12 then
    raise EFontProgramError.Create('TrueType: truncated');
  Dir := 0;
  if U32(0) = $74746366 then           // 'ttcf': first font of the collection
    Dir := U32(12);

  if not FindTable(Dir, 'head', Off, Len) or (Len < 54) then
    raise EFontProgramError.Create('TrueType: no head table');
  var UPM := U16(Off + 18);
  if (UPM < 16) or (UPM > 16384) then UPM := 1000;
  FFontMatrix := TPDFMatrix.Make(1 / UPM, 0, 0, 1 / UPM, 0, 0);
  FLocaLong := S16(Off + 50) <> 0;

  if FindTable(Dir, 'maxp', Off, Len) and (Len >= 6) then
    FNumGlyphs := U16(Off + 4);
  if not FindTable(Dir, 'loca', FLoca, Len) then FLoca := -1;
  if not FindTable(Dir, 'glyf', FGlyf, FGlyfLen) then FGlyf := -1;
  // Some subsets have no maxp: the loca table gives the count
  if (FLoca >= 0) and ((FNumGlyphs = 0) or
     (FNumGlyphs * IfThen(FLocaLong, 4, 2) > Len)) then
    FNumGlyphs := Len div IfThen(FLocaLong, 4, 2) - 1;
  if FindTable(Dir, 'cmap', Off, Len) then ParseCmap(Off, Len);
  if FindTable(Dir, 'post', Off, Len) then ParsePost(Off, Len);
end;

destructor TTrueTypeProgram.Destroy;
begin
  FNames.Free;
  FCmaps.Free;
  inherited;
end;

function TTrueTypeProgram.U8(AOff: Integer): Integer;
begin
  if (AOff < 0) or (AOff >= Length(FData)) then
    raise EFontProgramError.Create('TrueType: read out of bounds');
  Result := FData[AOff];
end;

function TTrueTypeProgram.U16(AOff: Integer): Integer;
begin
  if (AOff < 0) or (AOff + 2 > Length(FData)) then
    raise EFontProgramError.Create('TrueType: read out of bounds');
  Result := (FData[AOff] shl 8) or FData[AOff + 1];
end;

function TTrueTypeProgram.S16(AOff: Integer): Integer;
begin
  Result := SmallInt(U16(AOff));
end;

function TTrueTypeProgram.U32(AOff: Integer): Cardinal;
begin
  if (AOff < 0) or (AOff + 4 > Length(FData)) then
    raise EFontProgramError.Create('TrueType: read out of bounds');
  Result := (Cardinal(FData[AOff]) shl 24) or (Cardinal(FData[AOff + 1]) shl 16) or
            (Cardinal(FData[AOff + 2]) shl 8) or FData[AOff + 3];
end;

function TTrueTypeProgram.FindTable(ADir: Integer; const ATag: AnsiString;
  out AOff, ALen: Integer): Boolean;
var
  N, R: Integer;
begin
  N := U16(ADir + 4);
  for var I := 0 to N - 1 do
  begin
    R := ADir + 12 + I * 16;
    if R + 16 > Length(FData) then Break;
    if (FData[R] = Ord(ATag[1])) and (FData[R + 1] = Ord(ATag[2])) and
       (FData[R + 2] = Ord(ATag[3])) and (FData[R + 3] = Ord(ATag[4])) then
    begin
      AOff := Integer(U32(R + 8));
      ALen := Integer(U32(R + 12));
      // Clamp tables that run past the end of a truncated subset
      if (AOff < 0) or (AOff > Length(FData)) then Exit(False);
      if AOff + ALen > Length(FData) then ALen := Length(FData) - AOff;
      Exit(True);
    end;
  end;
  Result := False;
end;

procedure TTrueTypeProgram.ParseCmap(AOff, ALen: Integer);
var
  N, Sub, Fmt: Integer;
  Map: TDictionary<Cardinal, Integer>;
begin
  N := U16(AOff + 2);
  for var I := 0 to N - 1 do
  begin
    var Key := U16(AOff + 4 + I * 8) * 65536 + U16(AOff + 6 + I * 8);
    if FCmaps.ContainsKey(Key) then Continue;
    Sub := AOff + Integer(U32(AOff + 8 + I * 8));
    Map := TDictionary<Cardinal, Integer>.Create;
    try
      Fmt := U16(Sub);
      case Fmt of
        0:
          for var C := 0 to 255 do
            if U8(Sub + 6 + C) <> 0 then Map.AddOrSetValue(C, U8(Sub + 6 + C));
        4:
        begin
          var SegX2 := U16(Sub + 6);
          var Ends := Sub + 14;
          var Starts := Ends + SegX2 + 2;
          var Deltas := Starts + SegX2;
          var Ranges := Deltas + SegX2;
          for var S := 0 to SegX2 div 2 - 1 do
          begin
            var EndC := U16(Ends + S * 2);
            var StartC := U16(Starts + S * 2);
            var Delta := S16(Deltas + S * 2);
            var RO := U16(Ranges + S * 2);
            if StartC > EndC then Continue;
            for var C := StartC to EndC do
            begin
              if C = $FFFF then Break;
              var G: Integer;
              if RO = 0 then
                G := (C + Delta) and $FFFF
              else
              begin
                var P := Ranges + S * 2 + RO + (C - StartC) * 2;
                if P + 2 > Length(FData) then Continue;
                G := U16(P);
                if G <> 0 then G := (G + Delta) and $FFFF;
              end;
              if G <> 0 then Map.AddOrSetValue(C, G);
            end;
          end;
        end;
        6:
        begin
          var First := U16(Sub + 6);
          var Count := U16(Sub + 8);
          for var C := 0 to Count - 1 do
            if U16(Sub + 10 + C * 2) <> 0 then
              Map.AddOrSetValue(First + C, U16(Sub + 10 + C * 2));
        end;
        12:
        begin
          var NGroups := Integer(U32(Sub + 12));
          for var G := 0 to NGroups - 1 do
          begin
            var StartC := U32(Sub + 16 + G * 12);
            var EndC := U32(Sub + 20 + G * 12);
            var StartG := U32(Sub + 24 + G * 12);
            if EndC - StartC > $10FFFF then Continue;
            for var C := StartC to EndC do
              Map.AddOrSetValue(C, Integer(StartG + (C - StartC)));
          end;
        end;
      end;
      FCmaps.Add(Key, Map);
      Map := nil;
    except
      Map.Free;   // an unreadable subtable is skipped
    end;
  end;
end;

procedure TTrueTypeProgram.ParsePost(AOff, ALen: Integer);
begin
  try
    var Version := U32(AOff);
    if Version = $00010000 then
    begin
      SetLength(FGlyphNames, Min(FNumGlyphs, 258));
      for var G := 0 to High(FGlyphNames) do
      begin
        FGlyphNames[G] := MAC_GLYPHS[G];
        FNames.TryAdd(MAC_GLYPHS[G], G);
      end;
    end
    else if Version = $00020000 then
    begin
      var N := U16(AOff + 32);
      // the custom names follow the index array as Pascal strings
      var Custom := TList<string>.Create;
      try
        var P := AOff + 34 + N * 2;
        while P < AOff + ALen do
        begin
          var L := U8(P);
          if P + 1 + L > Length(FData) then Break;
          Custom.Add(TEncoding.ANSI.GetString(FData, P + 1, L));
          Inc(P, 1 + L);
        end;
        SetLength(FGlyphNames, N);
        for var G := 0 to N - 1 do
        begin
          var Idx := U16(AOff + 34 + G * 2);
          if Idx < 258 then
            FGlyphNames[G] := MAC_GLYPHS[Idx]
          else if Idx - 258 < Custom.Count then
            FGlyphNames[G] := Custom[Idx - 258];
          if FGlyphNames[G] <> '' then
            FNames.TryAdd(FGlyphNames[G], G);
        end;
      finally
        Custom.Free;
      end;
    end;
  except
    // names are optional
  end;
end;

function TTrueTypeProgram.Kind: TFontProgramKind;
begin
  Result := TFontProgramKind.TrueType;
end;

function TTrueTypeProgram.GlyphCount: Integer;
begin
  Result := FNumGlyphs;
end;

function TTrueTypeProgram.GlyphByName(const AName: string): Integer;
begin
  if not FNames.TryGetValue(AName, Result) then
    Result := -1;
end;

function TTrueTypeProgram.GlyphName(AGID: Integer): string;
begin
  if (AGID >= 0) and (AGID < Length(FGlyphNames)) then
    Result := FGlyphNames[AGID]
  else
    Result := '';
end;

function TTrueTypeProgram.HasCmap(APlatform, AEncoding: Integer): Boolean;
begin
  Result := FCmaps.ContainsKey(APlatform * 65536 + AEncoding);
end;

function TTrueTypeProgram.CmapGlyph(APlatform, AEncoding: Integer; ACode: Cardinal): Integer;
var
  Map: TDictionary<Cardinal, Integer>;
begin
  if not FCmaps.TryGetValue(APlatform * 65536 + AEncoding, Map) or
     not Map.TryGetValue(ACode, Result) then
    Result := 0;
end;

function TTrueTypeProgram.GlyphRange(AGID: Integer; out AStart, ALen: Integer): Boolean;
var
  A, B: Integer;
begin
  Result := False;
  if (FGlyf < 0) or (FLoca < 0) or (AGID < 0) or (AGID >= FNumGlyphs) then Exit;
  if FLocaLong then
  begin
    A := Integer(U32(FLoca + AGID * 4));
    B := Integer(U32(FLoca + AGID * 4 + 4));
  end else
  begin
    A := U16(FLoca + AGID * 2) * 2;
    B := U16(FLoca + AGID * 2 + 2) * 2;
  end;
  if (B <= A) or (A < 0) or (B > FGlyfLen) then Exit;
  AStart := FGlyf + A;
  ALen   := B - A;
  Result := ALen >= 10;
end;

// Appends glyph AGID transformed by [A BB C D E F]; composite glyphs recurse.
procedure TTrueTypeProgram.AddGlyph(var B: TGlyphOutlineBuilder; AGID: Integer;
  A, BB, C, D, E, F: Single; ADepth: Integer);
type
  TPt = record X, Y: Single; On: Boolean; end;
var
  Start, Len, NC, P: Integer;
  Ends: TArray<Integer>;
  Flags: TArray<Byte>;
  Pts: TArray<TPt>;

  function Tx(const Q: TPt): TPointF;
  begin
    Result.X := Q.X * A + Q.Y * C + E;
    Result.Y := Q.X * BB + Q.Y * D + F;
  end;

  procedure EmitContour(AFirst, ALast: Integer);
  var
    N, S: Integer;
    Cur, Ctl, P0: TPointF;
    HaveCtl: Boolean;

    procedure QuadTo(const Q, R: TPointF);
    begin
      // quadratic (Cur, Q, R) as a cubic
      B.CurveTo(Cur.X + 2 / 3 * (Q.X - Cur.X), Cur.Y + 2 / 3 * (Q.Y - Cur.Y),
                R.X + 2 / 3 * (Q.X - R.X),     R.Y + 2 / 3 * (Q.Y - R.Y), R.X, R.Y);
      Cur := R;
    end;

  begin
    N := ALast - AFirst + 1;
    if N < 2 then Exit;
    // Start on an on-curve point, or between two off-curve points
    S := -1;
    for var I := 0 to N - 1 do
      if Pts[AFirst + I].On then
      begin
        S := I;
        Break;
      end;
    if S < 0 then
    begin
      var Q0 := Tx(Pts[AFirst]);
      var Q1 := Tx(Pts[ALast]);
      P0 := TPointF.Create((Q0.X + Q1.X) / 2, (Q0.Y + Q1.Y) / 2);
      HaveCtl := False;
      B.MoveTo(P0.X, P0.Y);
      Cur := P0;
      for var K := 0 to N - 1 do
      begin
        var Q := Tx(Pts[AFirst + K]);
        if HaveCtl then
          QuadTo(Ctl, TPointF.Create((Ctl.X + Q.X) / 2, (Ctl.Y + Q.Y) / 2));
        Ctl := Q;
        HaveCtl := True;
      end;
      QuadTo(Ctl, P0);
      B.Close;
      Exit;
    end;
    P0 := Tx(Pts[AFirst + S]);
    B.MoveTo(P0.X, P0.Y);
    Cur := P0;
    HaveCtl := False;
    for var K := 1 to N do
    begin
      var Pt := Pts[AFirst + (S + K) mod N];
      var Q := Tx(Pt);
      if Pt.On then
      begin
        if HaveCtl then QuadTo(Ctl, Q) else
        begin
          B.LineTo(Q.X, Q.Y);
          Cur := Q;
        end;
        HaveCtl := False;
      end else
      begin
        if HaveCtl then
          QuadTo(Ctl, TPointF.Create((Ctl.X + Q.X) / 2, (Ctl.Y + Q.Y) / 2));
        Ctl := Q;
        HaveCtl := True;
      end;
    end;
    if HaveCtl then QuadTo(Ctl, P0);
    B.Close;
  end;

begin
  if (ADepth > MAX_COMPOSITE_DEPTH) or not GlyphRange(AGID, Start, Len) then Exit;
  NC := S16(Start);
  if NC >= 0 then
  begin
    // Simple glyph
    SetLength(Ends, NC);
    for var I := 0 to NC - 1 do
      Ends[I] := U16(Start + 10 + I * 2);
    if NC = 0 then Exit;
    var NPts := Ends[NC - 1] + 1;
    if (NPts <= 0) or (NPts > 65535) then Exit;
    P := Start + 10 + NC * 2;
    P := P + 2 + U16(P);                  // skip the instructions
    SetLength(Flags, NPts);
    var I := 0;
    while I < NPts do
    begin
      var Fl := U8(P);
      Inc(P);
      Flags[I] := Fl;
      Inc(I);
      if Fl and 8 <> 0 then
      begin
        var R := U8(P);
        Inc(P);
        while (R > 0) and (I < NPts) do
        begin
          Flags[I] := Fl;
          Inc(I);
          Dec(R);
        end;
      end;
    end;
    SetLength(Pts, NPts);
    var V := 0;
    for I := 0 to NPts - 1 do
    begin
      var Fl := Flags[I];
      if Fl and 2 <> 0 then
      begin
        if Fl and 16 <> 0 then Inc(V, U8(P)) else Dec(V, U8(P));
        Inc(P);
      end else if Fl and 16 = 0 then
      begin
        Inc(V, S16(P));
        Inc(P, 2);
      end;
      Pts[I].X := V;
      Pts[I].On := Fl and 1 <> 0;
    end;
    V := 0;
    for I := 0 to NPts - 1 do
    begin
      var Fl := Flags[I];
      if Fl and 4 <> 0 then
      begin
        if Fl and 32 <> 0 then Inc(V, U8(P)) else Dec(V, U8(P));
        Inc(P);
      end else if Fl and 32 = 0 then
      begin
        Inc(V, S16(P));
        Inc(P, 2);
      end;
      Pts[I].Y := V;
    end;
    var First := 0;
    for var K := 0 to NC - 1 do
    begin
      if (Ends[K] < First) or (Ends[K] >= NPts) then Break;
      EmitContour(First, Ends[K]);
      First := Ends[K] + 1;
    end;
  end else
  begin
    // Composite glyph
    P := Start + 10;
    repeat
      var Fl := U16(P);
      var Sub := U16(P + 2);
      Inc(P, 4);
      var DX, DY: Single;
      if Fl and 1 <> 0 then
      begin
        DX := S16(P); DY := S16(P + 2);
        Inc(P, 4);
      end else
      begin
        DX := ShortInt(U8(P)); DY := ShortInt(U8(P + 1));
        Inc(P, 2);
      end;
      if Fl and 2 = 0 then
      begin
        DX := 0;    // point matching: not supported, place at the origin
        DY := 0;
      end;
      var SA: Single := 1; var SB: Single := 0; var SC: Single := 0; var SD: Single := 1;
      if Fl and 8 <> 0 then
      begin
        SA := S16(P) / 16384; SD := SA;
        Inc(P, 2);
      end else if Fl and $40 <> 0 then
      begin
        SA := S16(P) / 16384; SD := S16(P + 2) / 16384;
        Inc(P, 4);
      end else if Fl and $80 <> 0 then
      begin
        SA := S16(P) / 16384;     SB := S16(P + 2) / 16384;
        SC := S16(P + 4) / 16384; SD := S16(P + 6) / 16384;
        Inc(P, 8);
      end;
      // component matrix [SA SB SC SD DX DY], then the parent's
      AddGlyph(B, Sub,
        SA * A + SB * C, SA * BB + SB * D,
        SC * A + SD * C, SC * BB + SD * D,
        DX * A + DY * C + E, DX * BB + DY * D + F, ADepth + 1);
      if Fl and $20 = 0 then Break;
    until False;
  end;
end;

function TTrueTypeProgram.GlyphOutline(AGID: Integer): TGlyphOutline;
var
  B: TGlyphOutlineBuilder;
begin
  B.Init;
  try
    AddGlyph(B, AGID, 1, 0, 0, 1, 0, 0, 0);
  except
    on EFontProgramError do ;   // a damaged glyph keeps what was read
  end;
  Result := B.Build;
end;

// =========================================================================
// Loader
// =========================================================================

function LoadFontProgram(const AData: TBytes; const AKey, ASubtype: string): TPDFFontProgram;
begin
  Result := nil;
  if Length(AData) < 4 then Exit;
  try
    var Tag := (Cardinal(AData[0]) shl 24) or (Cardinal(AData[1]) shl 16) or
               (Cardinal(AData[2]) shl 8) or AData[3];
    if Tag = $4F54544F then                       // 'OTTO': CFF-based OpenType
      Result := TCFFProgram.FromOpenType(AData)
    else if (Tag = $00010000) or (Tag = $74727565) or (Tag = $74746366) then
      Result := TTrueTypeProgram.Create(AData)
    else if (AKey = 'FontFile3') or ((AData[0] = 1) and (AData[1] = 0)) then
      Result := TCFFProgram.Create(AData)
    else if AKey = 'FontFile' then
      Result := TType1Program.Create(AData);
  except
    FreeAndNil(Result);
  end;
end;

end.
