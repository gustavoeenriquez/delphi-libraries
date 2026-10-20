unit uPDF.FontCFF;

// CFF font programs (Adobe Technical Note #5176) with Type 2 charstrings
// (Technical Note #5177): bare FontFile3 /Type1C and /CIDFontType0C streams
// and the 'CFF ' table of OpenType fonts. Name-keyed and CID-keyed fonts,
// predefined and custom charsets and encodings, FDArray/FDSelect, local and
// global subroutines, flex and seac-style endchar.

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections,
  uPDF.Types, uPDF.FontProgram;

type
  TCFFIndex = record
    Offsets: TArray<Integer>;   // absolute offsets, Count + 1 entries
    function Count: Integer;
    function Item(I: Integer; out AStart, ALen: Integer): Boolean;
  end;

  TCFFPrivate = record
    Subrs: TCFFIndex;
  end;

  TCFFProgram = class(TPDFFontProgram)
  private
    FData:        TBytes;
    FBase:        Integer;               // offset of the CFF data in FData
    FCharStrings: TCFFIndex;
    FGlobalSubrs: TCFFIndex;
    FStrings:     TCFFIndex;
    FPrivates:    TArray<TCFFPrivate>;   // one per font DICT (one if not CID-keyed)
    FFDSelect:    TArray<Byte>;          // font DICT of each glyph (CID-keyed)
    FIsCID:       Boolean;
    FGlyphNames:  TArray<string>;        // name-keyed: name of each glyph
    FNameToGID:   TDictionary<string, Integer>;
    FCIDToGID:    TDictionary<Integer, Integer>;
    FEncoding:    array[0..255] of Integer;   // built-in encoding: code → glyph, -1
    FHasEncoding: Boolean;
    function  Byte_(AOff: Integer): Integer; inline;
    function  Card16(AOff: Integer): Integer; inline;
    function  ReadIndex(var AOff: Integer): TCFFIndex;
    function  ReadDict(AStart, ALen: Integer): TDictionary<Integer, TArray<Double>>;
    function  SIDName(ASID: Integer): string;
    procedure Parse(ABase: Integer);
    procedure ReadPrivate(const AOperands: TArray<Double>; var APriv: TCFFPrivate);
    procedure ReadCharset(AOff: Integer);
    procedure ReadEncoding(AOff: Integer);
    procedure ReadFDSelect(AOff: Integer);
    procedure RunGlyph(AGID: Integer; var B: TGlyphOutlineBuilder;
      ADX, ADY: Double; ASeacDepth: Integer);
  public
    // ABase: offset of the CFF data in AData
    constructor Create(const AData: TBytes; ABase: Integer = 0);
    // The 'CFF ' table of an OpenType font
    class function FromOpenType(const AData: TBytes): TCFFProgram;
    destructor  Destroy; override;
    function  Kind: TFontProgramKind; override;
    function  GlyphCount: Integer; override;
    function  GlyphOutline(AGID: Integer): TGlyphOutline; override;
    function  GlyphByName(const AName: string): Integer; override;
    function  GlyphName(AGID: Integer): string; override;
    function  GlyphByCID(ACID: Integer): Integer; override;
    function  HasBuiltinEncoding: Boolean; override;
    function  BuiltinGlyphName(ACode: Integer): string; override;
    property  IsCIDKeyed: Boolean read FIsCID;
  end;

implementation

uses
  uPDF.StdFonts;

const
  // The predefined strings of CFF (TN 5176, Appendix A)
  CFF_STD_STRINGS: array[0..390] of string = (
    '.notdef', 'space', 'exclam', 'quotedbl', 'numbersign', 'dollar',
    'percent', 'ampersand', 'quoteright', 'parenleft', 'parenright', 'asterisk',
    'plus', 'comma', 'hyphen', 'period', 'slash', 'zero',
    'one', 'two', 'three', 'four', 'five', 'six',
    'seven', 'eight', 'nine', 'colon', 'semicolon', 'less',
    'equal', 'greater', 'question', 'at', 'A', 'B',
    'C', 'D', 'E', 'F', 'G', 'H',
    'I', 'J', 'K', 'L', 'M', 'N',
    'O', 'P', 'Q', 'R', 'S', 'T',
    'U', 'V', 'W', 'X', 'Y', 'Z',
    'bracketleft', 'backslash', 'bracketright', 'asciicircum', 'underscore', 'quoteleft',
    'a', 'b', 'c', 'd', 'e', 'f',
    'g', 'h', 'i', 'j', 'k', 'l',
    'm', 'n', 'o', 'p', 'q', 'r',
    's', 't', 'u', 'v', 'w', 'x',
    'y', 'z', 'braceleft', 'bar', 'braceright', 'asciitilde',
    'exclamdown', 'cent', 'sterling', 'fraction', 'yen', 'florin',
    'section', 'currency', 'quotesingle', 'quotedblleft', 'guillemotleft', 'guilsinglleft',
    'guilsinglright', 'fi', 'fl', 'endash', 'dagger', 'daggerdbl',
    'periodcentered', 'paragraph', 'bullet', 'quotesinglbase', 'quotedblbase', 'quotedblright',
    'guillemotright', 'ellipsis', 'perthousand', 'questiondown', 'grave', 'acute',
    'circumflex', 'tilde', 'macron', 'breve', 'dotaccent', 'dieresis',
    'ring', 'cedilla', 'hungarumlaut', 'ogonek', 'caron', 'emdash',
    'AE', 'ordfeminine', 'Lslash', 'Oslash', 'OE', 'ordmasculine',
    'ae', 'dotlessi', 'lslash', 'oslash', 'oe', 'germandbls',
    'onesuperior', 'logicalnot', 'mu', 'trademark', 'Eth', 'onehalf',
    'plusminus', 'Thorn', 'onequarter', 'divide', 'brokenbar', 'degree',
    'thorn', 'threequarters', 'twosuperior', 'registered', 'minus', 'eth',
    'multiply', 'threesuperior', 'copyright', 'Aacute', 'Acircumflex', 'Adieresis',
    'Agrave', 'Aring', 'Atilde', 'Ccedilla', 'Eacute', 'Ecircumflex',
    'Edieresis', 'Egrave', 'Iacute', 'Icircumflex', 'Idieresis', 'Igrave',
    'Ntilde', 'Oacute', 'Ocircumflex', 'Odieresis', 'Ograve', 'Otilde',
    'Scaron', 'Uacute', 'Ucircumflex', 'Udieresis', 'Ugrave', 'Yacute',
    'Ydieresis', 'Zcaron', 'aacute', 'acircumflex', 'adieresis', 'agrave',
    'aring', 'atilde', 'ccedilla', 'eacute', 'ecircumflex', 'edieresis',
    'egrave', 'iacute', 'icircumflex', 'idieresis', 'igrave', 'ntilde',
    'oacute', 'ocircumflex', 'odieresis', 'ograve', 'otilde', 'scaron',
    'uacute', 'ucircumflex', 'udieresis', 'ugrave', 'yacute', 'ydieresis',
    'zcaron', 'exclamsmall', 'Hungarumlautsmall', 'dollaroldstyle', 'dollarsuperior', 'ampersandsmall',
    'Acutesmall', 'parenleftsuperior', 'parenrightsuperior', 'twodotenleader', 'onedotenleader', 'zerooldstyle',
    'oneoldstyle', 'twooldstyle', 'threeoldstyle', 'fouroldstyle', 'fiveoldstyle', 'sixoldstyle',
    'sevenoldstyle', 'eightoldstyle', 'nineoldstyle', 'commasuperior', 'threequartersemdash', 'periodsuperior',
    'questionsmall', 'asuperior', 'bsuperior', 'centsuperior', 'dsuperior', 'esuperior',
    'isuperior', 'lsuperior', 'msuperior', 'nsuperior', 'osuperior', 'rsuperior',
    'ssuperior', 'tsuperior', 'ff', 'ffi', 'ffl', 'parenleftinferior',
    'parenrightinferior', 'Circumflexsmall', 'hyphensuperior', 'Gravesmall', 'Asmall', 'Bsmall',
    'Csmall', 'Dsmall', 'Esmall', 'Fsmall', 'Gsmall', 'Hsmall',
    'Ismall', 'Jsmall', 'Ksmall', 'Lsmall', 'Msmall', 'Nsmall',
    'Osmall', 'Psmall', 'Qsmall', 'Rsmall', 'Ssmall', 'Tsmall',
    'Usmall', 'Vsmall', 'Wsmall', 'Xsmall', 'Ysmall', 'Zsmall',
    'colonmonetary', 'onefitted', 'rupiah', 'Tildesmall', 'exclamdownsmall', 'centoldstyle',
    'Lslashsmall', 'Scaronsmall', 'Zcaronsmall', 'Dieresissmall', 'Brevesmall', 'Caronsmall',
    'Dotaccentsmall', 'Macronsmall', 'figuredash', 'hypheninferior', 'Ogoneksmall', 'Ringsmall',
    'Cedillasmall', 'questiondownsmall', 'oneeighth', 'threeeighths', 'fiveeighths', 'seveneighths',
    'onethird', 'twothirds', 'zerosuperior', 'foursuperior', 'fivesuperior', 'sixsuperior',
    'sevensuperior', 'eightsuperior', 'ninesuperior', 'zeroinferior', 'oneinferior', 'twoinferior',
    'threeinferior', 'fourinferior', 'fiveinferior', 'sixinferior', 'seveninferior', 'eightinferior',
    'nineinferior', 'centinferior', 'dollarinferior', 'periodinferior', 'commainferior', 'Agravesmall',
    'Aacutesmall', 'Acircumflexsmall', 'Atildesmall', 'Adieresissmall', 'Aringsmall', 'AEsmall',
    'Ccedillasmall', 'Egravesmall', 'Eacutesmall', 'Ecircumflexsmall', 'Edieresissmall', 'Igravesmall',
    'Iacutesmall', 'Icircumflexsmall', 'Idieresissmall', 'Ethsmall', 'Ntildesmall', 'Ogravesmall',
    'Oacutesmall', 'Ocircumflexsmall', 'Otildesmall', 'Odieresissmall', 'OEsmall', 'Oslashsmall',
    'Ugravesmall', 'Uacutesmall', 'Ucircumflexsmall', 'Udieresissmall', 'Yacutesmall', 'Thornsmall',
    'Ydieresissmall', '001.000', '001.001', '001.002', '001.003', 'Black',
    'Bold', 'Book', 'Light', 'Medium', 'Regular', 'Roman',
    'Semibold');

  // Top DICT / Private DICT operators (escaped ones are 1200 + second byte)
  OP_CHARSET      = 15;
  OP_ENCODING     = 16;
  OP_CHARSTRINGS  = 17;
  OP_PRIVATE      = 18;
  OP_SUBRS        = 19;
  OP_FONTMATRIX   = 1207;
  OP_ROS          = 1230;
  OP_FDARRAY      = 1236;
  OP_FDSELECT     = 1237;

  MAX_SUBR_DEPTH  = 10;
  MAX_STACK       = 48;

// =========================================================================
// TCFFIndex
// =========================================================================

function TCFFIndex.Count: Integer;
begin
  Result := Max(0, Length(Offsets) - 1);
end;

function TCFFIndex.Item(I: Integer; out AStart, ALen: Integer): Boolean;
begin
  Result := (I >= 0) and (I < Count);
  if Result then
  begin
    AStart := Offsets[I];
    ALen   := Offsets[I + 1] - Offsets[I];
    Result := ALen >= 0;
  end;
end;

function SubrBias(ACount: Integer): Integer;
begin
  if ACount < 1240 then Result := 107
  else if ACount < 33900 then Result := 1131
  else Result := 32768;
end;

// =========================================================================
// TCFFProgram
// =========================================================================

constructor TCFFProgram.Create(const AData: TBytes; ABase: Integer);
begin
  inherited Create;
  FData := AData;
  FNameToGID := TDictionary<string, Integer>.Create;
  FCIDToGID  := TDictionary<Integer, Integer>.Create;
  Parse(ABase);
end;

class function TCFFProgram.FromOpenType(const AData: TBytes): TCFFProgram;

  function U16(AOff: Integer): Integer;
  begin
    if AOff + 2 > Length(AData) then
      raise EFontProgramError.Create('OpenType: truncated');
    Result := (AData[AOff] shl 8) or AData[AOff + 1];
  end;

begin
  var N := U16(4);
  for var I := 0 to N - 1 do
  begin
    var R := 12 + I * 16;
    if (U16(R) = $4346) and (U16(R + 2) = $4620) then      // 'CFF '
      Exit(TCFFProgram.Create(AData, (U16(R + 8) shl 16) or U16(R + 10)));
  end;
  raise EFontProgramError.Create('OpenType: no CFF table');
end;

destructor TCFFProgram.Destroy;
begin
  FCIDToGID.Free;
  FNameToGID.Free;
  inherited;
end;

function TCFFProgram.Byte_(AOff: Integer): Integer;
begin
  if (AOff < 0) or (AOff >= Length(FData)) then
    raise EFontProgramError.Create('CFF: read out of bounds');
  Result := FData[AOff];
end;

function TCFFProgram.Card16(AOff: Integer): Integer;
begin
  Result := (Byte_(AOff) shl 8) or Byte_(AOff + 1);
end;

function TCFFProgram.ReadIndex(var AOff: Integer): TCFFIndex;
var
  Count, OffSize, Base: Integer;
begin
  Result.Offsets := nil;
  Count := Card16(AOff);
  if Count = 0 then
  begin
    Inc(AOff, 2);
    Exit;
  end;
  OffSize := Byte_(AOff + 2);
  if not (OffSize in [1..4]) then
    raise EFontProgramError.Create('CFF: bad INDEX offSize');
  SetLength(Result.Offsets, Count + 1);
  Base := AOff + 3 + (Count + 1) * OffSize - 1;   // offsets are 1-based
  for var I := 0 to Count do
  begin
    var V := 0;
    for var K := 0 to OffSize - 1 do
      V := (V shl 8) or Byte_(AOff + 3 + I * OffSize + K);
    Result.Offsets[I] := Base + V;
  end;
  AOff := Result.Offsets[Count];
  if AOff > Length(FData) then
    raise EFontProgramError.Create('CFF: INDEX past the end');
end;

function TCFFProgram.ReadDict(AStart, ALen: Integer): TDictionary<Integer, TArray<Double>>;
var
  P, B0: Integer;
  Ops: TArray<Double>;

  procedure Push(V: Double);
  begin
    Ops := Ops + [V];
  end;

  function ReadReal: Double;
  var
    S: string;
    Done: Boolean;
  begin
    S := '';
    Done := False;
    while not Done do
    begin
      var Bt := Byte_(P);
      Inc(P);
      for var N in [Bt shr 4, Bt and 15] do
      begin
        if Done then Break;
        case N of
          0..9: S := S + Char(Ord('0') + N);
          10: S := S + '.';
          11: S := S + 'E';
          12: S := S + 'E-';
          14: S := S + '-';
          15: Done := True;
        end;
      end;
    end;
    if not TryStrToFloat(S, Result, TFormatSettings.Invariant) then
      Result := 0;
  end;

begin
  Result := TDictionary<Integer, TArray<Double>>.Create;
  P := AStart;
  Ops := nil;
  while P < AStart + ALen do
  begin
    B0 := Byte_(P);
    Inc(P);
    case B0 of
      0..21:
      begin
        var Op := B0;
        if B0 = 12 then
        begin
          Op := 1200 + Byte_(P);
          Inc(P);
        end;
        Result.AddOrSetValue(Op, Ops);
        Ops := nil;
      end;
      28:
      begin
        Push(SmallInt(Card16(P)));
        Inc(P, 2);
      end;
      29:
      begin
        Push(Integer((Card16(P) shl 16) or Card16(P + 2)));
        Inc(P, 4);
      end;
      30: Push(ReadReal);
      32..246: Push(B0 - 139);
      247..250:
      begin
        Push((B0 - 247) * 256 + Byte_(P) + 108);
        Inc(P);
      end;
      251..254:
      begin
        Push(-(B0 - 251) * 256 - Byte_(P) - 108);
        Inc(P);
      end;
    end;
  end;
end;

function TCFFProgram.SIDName(ASID: Integer): string;
var
  S, L: Integer;
begin
  if ASID <= High(CFF_STD_STRINGS) then
    Exit(CFF_STD_STRINGS[ASID]);
  if FStrings.Item(ASID - Length(CFF_STD_STRINGS), S, L) and (S + L <= Length(FData)) then
    Result := TEncoding.ANSI.GetString(FData, S, L)
  else
    Result := '';
end;

procedure TCFFProgram.ReadPrivate(const AOperands: TArray<Double>; var APriv: TCFFPrivate);
var
  V: TArray<Double>;
begin
  APriv.Subrs.Offsets := nil;
  if Length(AOperands) < 2 then Exit;
  var Size: Integer := Round(AOperands[0]);
  var Off: Integer := FBase + Round(AOperands[1]);
  if (Size <= 0) or (Off < 0) or (Off + Size > Length(FData)) then Exit;
  var D := ReadDict(Off, Size);
  try
    if D.TryGetValue(OP_SUBRS, V) and (Length(V) > 0) then
    begin
      var SOff: Integer := Off + Round(V[0]);
      APriv.Subrs := ReadIndex(SOff);
    end;
  finally
    D.Free;
  end;
end;

procedure TCFFProgram.Parse(ABase: Integer);
var
  P, S, L: Integer;
  V: TArray<Double>;
begin
  FBase := ABase;
  for var I := 0 to 255 do FEncoding[I] := -1;
  P := ABase + Byte_(ABase + 2);           // hdrSize
  ReadIndex(P);                             // Name INDEX
  var TopIdx := ReadIndex(P);
  FStrings := ReadIndex(P);
  FGlobalSubrs := ReadIndex(P);
  if not TopIdx.Item(0, S, L) then
    raise EFontProgramError.Create('CFF: no Top DICT');
  var Top := ReadDict(S, L);
  try
    if not Top.TryGetValue(OP_CHARSTRINGS, V) or (Length(V) = 0) then
      raise EFontProgramError.Create('CFF: no CharStrings');
    var CS: Integer := ABase + Round(V[0]);
    FCharStrings := ReadIndex(CS);
    if FCharStrings.Count = 0 then
      raise EFontProgramError.Create('CFF: empty CharStrings');

    if Top.TryGetValue(OP_FONTMATRIX, V) and (Length(V) = 6) then
      FFontMatrix := TPDFMatrix.Make(V[0], V[1], V[2], V[3], V[4], V[5]);
    FIsCID := Top.ContainsKey(OP_ROS);

    if FIsCID then
    begin
      // One Private DICT per font DICT of the FDArray
      if Top.TryGetValue(OP_FDARRAY, V) and (Length(V) > 0) then
      begin
        var FP: Integer := ABase + Round(V[0]);
        var FDs := ReadIndex(FP);
        SetLength(FPrivates, FDs.Count);
        for var I := 0 to FDs.Count - 1 do
          if FDs.Item(I, S, L) then
          begin
            var FD := ReadDict(S, L);
            try
              var PV: TArray<Double>;
              if FD.TryGetValue(OP_PRIVATE, PV) then
                ReadPrivate(PV, FPrivates[I]);
              // a font DICT may carry its own FontMatrix (relative to the top one)
            finally
              FD.Free;
            end;
          end;
      end;
      if Length(FPrivates) = 0 then SetLength(FPrivates, 1);
      SetLength(FFDSelect, FCharStrings.Count);
      if Top.TryGetValue(OP_FDSELECT, V) and (Length(V) > 0) then
        ReadFDSelect(ABase + Round(V[0]));
    end else
    begin
      SetLength(FPrivates, 1);
      if Top.TryGetValue(OP_PRIVATE, V) then
        ReadPrivate(V, FPrivates[0]);
    end;

    var CharsetOff := 0;
    if Top.TryGetValue(OP_CHARSET, V) and (Length(V) > 0) then
      CharsetOff := Round(V[0]);
    ReadCharset(CharsetOff);

    if not FIsCID then
    begin
      var EncOff := 0;
      if Top.TryGetValue(OP_ENCODING, V) and (Length(V) > 0) then
        EncOff := Round(V[0]);
      ReadEncoding(EncOff);
    end;
  finally
    Top.Free;
  end;
end;

// Glyph names (name-keyed) or CIDs (CID-keyed) of every glyph
procedure TCFFProgram.ReadCharset(AOff: Integer);
var
  N, G, P: Integer;

  procedure SetGlyph(AGID, ASID: Integer);
  begin
    if AGID >= N then Exit;
    if FIsCID then
      FCIDToGID.TryAdd(ASID, AGID)
    else
    begin
      FGlyphNames[AGID] := SIDName(ASID);
      FNameToGID.TryAdd(FGlyphNames[AGID], AGID);
    end;
  end;

begin
  N := FCharStrings.Count;
  if not FIsCID then SetLength(FGlyphNames, N);
  SetGlyph(0, 0);
  if AOff <= 2 then
  begin
    // 0 = ISOAdobe (SIDs 1..228 in order); Expert charsets are not used in PDF
    if AOff = 0 then
      for G := 1 to Min(N - 1, 228) do SetGlyph(G, G);
    Exit;
  end;
  P := FBase + AOff;
  var Fmt := Byte_(P);
  Inc(P);
  G := 1;
  case Fmt of
    0:
      while G < N do
      begin
        SetGlyph(G, Card16(P));
        Inc(P, 2);
        Inc(G);
      end;
    1, 2:
      while G < N do
      begin
        var First := Card16(P);
        var Left: Integer;
        if Fmt = 1 then
        begin
          Left := Byte_(P + 2);
          Inc(P, 3);
        end else
        begin
          Left := Card16(P + 2);
          Inc(P, 4);
        end;
        for var K := 0 to Left do
        begin
          SetGlyph(G, First + K);
          Inc(G);
          if G >= N then Break;
        end;
      end;
  end;
end;

procedure TCFFProgram.ReadEncoding(AOff: Integer);
var
  P, Fmt: Integer;
begin
  if AOff = 1 then Exit;           // Expert encoding: not used for PDF text
  FHasEncoding := True;
  if AOff = 0 then
  begin
    // StandardEncoding, through the glyph names of the charset
    for var C := 0 to 255 do
      FEncoding[C] := GlyphByName(StdEncodingGlyph(TPDFStdEncoding.Standard, C));
    for var C := 0 to 255 do
      if FEncoding[C] = 0 then FEncoding[C] := -1;
    Exit;
  end;
  P := FBase + AOff;
  Fmt := Byte_(P);
  Inc(P);
  case Fmt and $7F of
    0:
    begin
      var N := Byte_(P);
      Inc(P);
      for var I := 1 to N do
      begin
        FEncoding[Byte_(P)] := I;
        Inc(P);
      end;
    end;
    1:
    begin
      var NR := Byte_(P);
      Inc(P);
      var G := 1;
      for var I := 1 to NR do
      begin
        var First := Byte_(P);
        var Left := Byte_(P + 1);
        Inc(P, 2);
        for var K := 0 to Left do
        begin
          if First + K <= 255 then FEncoding[First + K] := G;
          Inc(G);
        end;
      end;
    end;
  end;
  if Fmt and $80 <> 0 then
  begin
    var NS := Byte_(P);
    Inc(P);
    for var I := 1 to NS do
    begin
      var Code := Byte_(P);
      var G := GlyphByName(SIDName(Card16(P + 1)));
      Inc(P, 3);
      if G > 0 then FEncoding[Code] := G;
    end;
  end;
  for var C := 0 to 255 do
    if FEncoding[C] >= FCharStrings.Count then FEncoding[C] := -1;
end;

procedure TCFFProgram.ReadFDSelect(AOff: Integer);
var
  P, N: Integer;
begin
  N := FCharStrings.Count;
  var Fmt := Byte_(AOff);
  P := AOff + 1;
  case Fmt of
    0:
      for var G := 0 to N - 1 do
        FFDSelect[G] := Byte_(P + G);
    3:
    begin
      var NR := Card16(P);
      Inc(P, 2);
      for var R := 0 to NR - 1 do
      begin
        var First := Card16(P);
        var FD := Byte_(P + 2);
        var Next := Card16(P + 3);
        Inc(P, 3);
        for var G := First to Min(Next, N) - 1 do
          FFDSelect[G] := FD;
      end;
    end;
  end;
  for var G := 0 to N - 1 do
    if FFDSelect[G] >= Length(FPrivates) then FFDSelect[G] := 0;
end;

// Type 2 charstring interpreter (TN 5177). The outline of AGID is appended
// to B, translated by (ADX, ADY); endchar with four arguments (seac) composes
// a base and an accent glyph of StandardEncoding.
procedure TCFFProgram.RunGlyph(AGID: Integer; var B: TGlyphOutlineBuilder;
  ADX, ADY: Double; ASeacDepth: Integer);
var
  Stack: array[0..MAX_STACK - 1] of Double;
  Trans: array[0..31] of Double;
  SP, NStems: Integer;
  X, Y: Double;
  HaveWidth, Ended: Boolean;
  LocalSubrs: TCFFIndex;

  procedure Push(V: Double);
  begin
    if SP < MAX_STACK then
    begin
      Stack[SP] := V;
      Inc(SP);
    end;
  end;

  // The first stack-clearing operator may carry the advance width as an
  // extra first argument
  procedure TakeWidth(AHasExtra: Boolean);
  begin
    if not HaveWidth and AHasExtra and (SP > 0) then
    begin
      Move(Stack[1], Stack[0], (SP - 1) * SizeOf(Double));
      Dec(SP);
    end;
    HaveWidth := True;
  end;

  procedure MoveTo(DX, DY: Double);
  begin
    X := X + DX;
    Y := Y + DY;
    B.MoveTo(X + ADX, Y + ADY);
  end;

  procedure LineTo(DX, DY: Double);
  begin
    X := X + DX;
    Y := Y + DY;
    B.LineTo(X + ADX, Y + ADY);
  end;

  procedure CurveTo(DXA, DYA, DXB, DYB, DXC, DYC: Double);
  var
    XA, YA, XB, YB: Double;
  begin
    XA := X + DXA;  YA := Y + DYA;
    XB := XA + DXB; YB := YA + DYB;
    X  := XB + DXC; Y  := YB + DYC;
    B.CurveTo(XA + ADX, YA + ADY, XB + ADX, YB + ADY, X + ADX, Y + ADY);
  end;

  procedure Run(AStart, ALen, ADepth: Integer);
  var
    P, B0, I: Integer;
  begin
    if ADepth > MAX_SUBR_DEPTH then
      raise EFontProgramError.Create('CFF: subroutines nested too deep');
    P := AStart;
    while (P < AStart + ALen) and not Ended do
    begin
      B0 := Byte_(P);
      Inc(P);
      case B0 of
        1, 3, 18, 23:                          // hstem vstem hstemhm vstemhm
        begin
          TakeWidth(Odd(SP));
          Inc(NStems, SP div 2);
          SP := 0;
        end;
        19, 20:                                // hintmask cntrmask
        begin
          TakeWidth(Odd(SP));
          Inc(NStems, SP div 2);
          SP := 0;
          Inc(P, (NStems + 7) div 8);
        end;
        21:                                    // rmoveto
        begin
          TakeWidth(SP > 2);
          if SP >= 2 then MoveTo(Stack[SP - 2], Stack[SP - 1]);
          SP := 0;
        end;
        22:                                    // hmoveto
        begin
          TakeWidth(SP > 1);
          if SP >= 1 then MoveTo(Stack[SP - 1], 0);
          SP := 0;
        end;
        4:                                     // vmoveto
        begin
          TakeWidth(SP > 1);
          if SP >= 1 then MoveTo(0, Stack[SP - 1]);
          SP := 0;
        end;
        5:                                     // rlineto
        begin
          I := 0;
          while I + 1 < SP do
          begin
            LineTo(Stack[I], Stack[I + 1]);
            Inc(I, 2);
          end;
          SP := 0;
        end;
        6, 7:                                  // hlineto vlineto
        begin
          var Horz := B0 = 6;
          for I := 0 to SP - 1 do
          begin
            if Horz then LineTo(Stack[I], 0) else LineTo(0, Stack[I]);
            Horz := not Horz;
          end;
          SP := 0;
        end;
        8:                                     // rrcurveto
        begin
          I := 0;
          while I + 5 < SP do
          begin
            CurveTo(Stack[I], Stack[I + 1], Stack[I + 2], Stack[I + 3], Stack[I + 4], Stack[I + 5]);
            Inc(I, 6);
          end;
          SP := 0;
        end;
        24:                                    // rcurveline
        begin
          I := 0;
          while I + 5 < SP - 2 do
          begin
            CurveTo(Stack[I], Stack[I + 1], Stack[I + 2], Stack[I + 3], Stack[I + 4], Stack[I + 5]);
            Inc(I, 6);
          end;
          if I + 1 < SP then LineTo(Stack[I], Stack[I + 1]);
          SP := 0;
        end;
        25:                                    // rlinecurve
        begin
          I := 0;
          while I + 1 < SP - 6 do
          begin
            LineTo(Stack[I], Stack[I + 1]);
            Inc(I, 2);
          end;
          if I + 5 < SP then
            CurveTo(Stack[I], Stack[I + 1], Stack[I + 2], Stack[I + 3], Stack[I + 4], Stack[I + 5]);
          SP := 0;
        end;
        26:                                    // vvcurveto
        begin
          I := 0;
          var D1: Double := 0;
          if Odd(SP) then
          begin
            D1 := Stack[0];
            I := 1;
          end;
          while I + 3 < SP do
          begin
            CurveTo(D1, Stack[I], Stack[I + 1], Stack[I + 2], 0, Stack[I + 3]);
            D1 := 0;
            Inc(I, 4);
          end;
          SP := 0;
        end;
        27:                                    // hhcurveto
        begin
          I := 0;
          var D1: Double := 0;
          if Odd(SP) then
          begin
            D1 := Stack[0];
            I := 1;
          end;
          while I + 3 < SP do
          begin
            CurveTo(Stack[I], D1, Stack[I + 1], Stack[I + 2], Stack[I + 3], 0);
            D1 := 0;
            Inc(I, 4);
          end;
          SP := 0;
        end;
        30, 31:                                // vhcurveto hvcurveto
        begin
          var Horz := B0 = 31;
          I := 0;
          while I + 3 < SP do
          begin
            var Last: Double := 0;
            if SP - I = 5 then Last := Stack[I + 4];
            if Horz then
              CurveTo(Stack[I], 0, Stack[I + 1], Stack[I + 2], Last, Stack[I + 3])
            else
              CurveTo(0, Stack[I], Stack[I + 1], Stack[I + 2], Stack[I + 3], Last);
            Horz := not Horz;
            Inc(I, 4);
          end;
          SP := 0;
        end;
        10, 29:                                // callsubr callgsubr
        begin
          if SP = 0 then Exit;
          Dec(SP);
          var Idx := Round(Stack[SP]);
          var S, L: Integer;
          var Ok: Boolean;
          if B0 = 10 then
            Ok := LocalSubrs.Item(Idx + SubrBias(LocalSubrs.Count), S, L)
          else
            Ok := FGlobalSubrs.Item(Idx + SubrBias(FGlobalSubrs.Count), S, L);
          if not Ok then
            raise EFontProgramError.Create('CFF: bad subroutine');
          Run(S, L, ADepth + 1);
        end;
        11: Exit;                              // return
        14:                                    // endchar
        begin
          TakeWidth((SP = 1) or (SP = 5));
          B.Close;
          if (SP >= 4) and (ASeacDepth = 0) and not FIsCID then
          begin
            var BG := GlyphByName(StdEncodingGlyph(TPDFStdEncoding.Standard, Round(Stack[SP - 2])));
            var AG := GlyphByName(StdEncodingGlyph(TPDFStdEncoding.Standard, Round(Stack[SP - 1])));
            var AX := Stack[SP - 4];
            var AY := Stack[SP - 3];
            if BG >= 0 then RunGlyph(BG, B, ADX, ADY, ASeacDepth + 1);
            if AG >= 0 then RunGlyph(AG, B, ADX + AX, ADY + AY, ASeacDepth + 1);
          end;
          SP := 0;
          Ended := True;
        end;
        12:
        begin
          var B1 := Byte_(P);
          Inc(P);
          case B1 of
            3:  if SP >= 2 then begin Dec(SP); Stack[SP - 1] := Ord((Stack[SP - 1] <> 0) and (Stack[SP] <> 0)); end;
            4:  if SP >= 2 then begin Dec(SP); Stack[SP - 1] := Ord((Stack[SP - 1] <> 0) or (Stack[SP] <> 0)); end;
            5:  if SP >= 1 then Stack[SP - 1] := Ord(Stack[SP - 1] = 0);
            9:  if SP >= 1 then Stack[SP - 1] := Abs(Stack[SP - 1]);
            10: if SP >= 2 then begin Dec(SP); Stack[SP - 1] := Stack[SP - 1] + Stack[SP]; end;
            11: if SP >= 2 then begin Dec(SP); Stack[SP - 1] := Stack[SP - 1] - Stack[SP]; end;
            12: if SP >= 2 then
                begin
                  Dec(SP);
                  if Stack[SP] <> 0 then Stack[SP - 1] := Stack[SP - 1] / Stack[SP];
                end;
            14: if SP >= 1 then Stack[SP - 1] := -Stack[SP - 1];
            15: if SP >= 2 then begin Dec(SP); Stack[SP - 1] := Ord(Stack[SP - 1] = Stack[SP]); end;
            18: if SP >= 1 then Dec(SP);
            20: if SP >= 2 then
                begin
                  var K := Round(Stack[SP - 1]);
                  if K in [0..31] then Trans[K] := Stack[SP - 2];
                  Dec(SP, 2);
                end;
            21: if SP >= 1 then
                begin
                  var K := Round(Stack[SP - 1]);
                  if K in [0..31] then Stack[SP - 1] := Trans[K] else Stack[SP - 1] := 0;
                end;
            22: if SP >= 4 then
                begin
                  if Stack[SP - 2] > Stack[SP - 1] then Stack[SP - 4] := Stack[SP - 3];
                  Dec(SP, 3);
                end;
            23: Push(0.5);
            24: if SP >= 2 then begin Dec(SP); Stack[SP - 1] := Stack[SP - 1] * Stack[SP]; end;
            26: if SP >= 1 then Stack[SP - 1] := Sqrt(Abs(Stack[SP - 1]));
            27: if SP >= 1 then Push(Stack[SP - 1]);
            28: if SP >= 2 then
                begin
                  var T := Stack[SP - 1];
                  Stack[SP - 1] := Stack[SP - 2];
                  Stack[SP - 2] := T;
                end;
            29: if SP >= 1 then
                begin
                  var K := Round(Stack[SP - 1]);
                  if K < 0 then K := 0;
                  if K < SP - 1 then Stack[SP - 1] := Stack[SP - 2 - K];
                end;
            30: if SP >= 2 then
                begin
                  var N := Round(Stack[SP - 2]);
                  var J := Round(Stack[SP - 1]);
                  Dec(SP, 2);
                  if (N > 0) and (N <= SP) then
                  begin
                    var Tmp: TArray<Double>;
                    SetLength(Tmp, N);
                    for var K := 0 to N - 1 do
                      Tmp[(((K + J) mod N) + N) mod N] := Stack[SP - N + K];
                    for var K := 0 to N - 1 do
                      Stack[SP - N + K] := Tmp[K];
                  end;
                end;
            34:                                // hflex
            begin
              if SP >= 7 then
              begin
                var Y0 := Y;
                CurveTo(Stack[0], 0, Stack[1], Stack[2], Stack[3], 0);
                CurveTo(Stack[4], 0, Stack[5], Y0 - Y, Stack[6], 0);
              end;
              SP := 0;
            end;
            35:                                // flex
            begin
              if SP >= 12 then
              begin
                CurveTo(Stack[0], Stack[1], Stack[2], Stack[3], Stack[4], Stack[5]);
                CurveTo(Stack[6], Stack[7], Stack[8], Stack[9], Stack[10], Stack[11]);
              end;
              SP := 0;
            end;
            36:                                // hflex1
            begin
              if SP >= 9 then
              begin
                var Y0 := Y;
                CurveTo(Stack[0], Stack[1], Stack[2], Stack[3], Stack[4], 0);
                CurveTo(Stack[5], 0, Stack[6], Stack[7], Stack[8], Y0 - (Y + Stack[7]));
              end;
              SP := 0;
            end;
            37:                                // flex1
            begin
              if SP >= 11 then
              begin
                var X0 := X;
                var Y0 := Y;
                var DX: Double := 0;
                var DY: Double := 0;
                for var K := 0 to 4 do
                begin
                  DX := DX + Stack[K * 2];
                  DY := DY + Stack[K * 2 + 1];
                end;
                CurveTo(Stack[0], Stack[1], Stack[2], Stack[3], Stack[4], Stack[5]);
                if Abs(DX) > Abs(DY) then
                  CurveTo(Stack[6], Stack[7], Stack[8], Stack[9], Stack[10], Y0 - (Y + Stack[7] + Stack[9]))
                else
                  CurveTo(Stack[6], Stack[7], Stack[8], Stack[9], X0 - (X + Stack[6] + Stack[8]), Stack[10]);
              end;
              SP := 0;
            end;
          else
            SP := 0;
          end;
        end;
        28:
        begin
          Push(SmallInt(Card16(P)));
          Inc(P, 2);
        end;
        32..246: Push(B0 - 139);
        247..250:
        begin
          Push((B0 - 247) * 256 + Byte_(P) + 108);
          Inc(P);
        end;
        251..254:
        begin
          Push(-(B0 - 251) * 256 - Byte_(P) - 108);
          Inc(P);
        end;
        255:
        begin
          Push(Integer((Card16(P) shl 16) or Card16(P + 2)) / 65536);
          Inc(P, 4);
        end;
      end;
    end;
  end;

var
  S, L: Integer;
begin
  if not FCharStrings.Item(AGID, S, L) then Exit;
  if FIsCID and (AGID < Length(FFDSelect)) then
    LocalSubrs := FPrivates[FFDSelect[AGID]].Subrs
  else if Length(FPrivates) > 0 then
    LocalSubrs := FPrivates[0].Subrs
  else
    LocalSubrs.Offsets := nil;
  SP := 0;
  NStems := 0;
  X := 0;
  Y := 0;
  HaveWidth := False;
  Ended := False;
  FillChar(Trans, SizeOf(Trans), 0);
  Run(S, L, 0);
  B.Close;
end;

function TCFFProgram.Kind: TFontProgramKind;
begin
  Result := TFontProgramKind.CFF;
end;

function TCFFProgram.GlyphCount: Integer;
begin
  Result := FCharStrings.Count;
end;

function TCFFProgram.GlyphOutline(AGID: Integer): TGlyphOutline;
var
  B: TGlyphOutlineBuilder;
begin
  B.Init;
  try
    RunGlyph(AGID, B, 0, 0, 0);
  except
    on EFontProgramError do ;
  end;
  Result := B.Build;
end;

function TCFFProgram.GlyphByName(const AName: string): Integer;
begin
  if not FNameToGID.TryGetValue(AName, Result) then
    Result := -1;
end;

function TCFFProgram.GlyphName(AGID: Integer): string;
begin
  if (AGID >= 0) and (AGID < Length(FGlyphNames)) then
    Result := FGlyphNames[AGID]
  else
    Result := '';
end;

function TCFFProgram.GlyphByCID(ACID: Integer): Integer;
begin
  if not FIsCID then
    Result := ACID
  else if not FCIDToGID.TryGetValue(ACID, Result) then
    Result := 0;
end;

function TCFFProgram.HasBuiltinEncoding: Boolean;
begin
  Result := FHasEncoding;
end;

function TCFFProgram.BuiltinGlyphName(ACode: Integer): string;
begin
  Result := '';
  if not FHasEncoding or (ACode < 0) or (ACode > 255) then Exit;
  var G := FEncoding[ACode];
  if (G >= 0) and (G < Length(FGlyphNames)) then
    Result := FGlyphNames[G];
end;

end.
