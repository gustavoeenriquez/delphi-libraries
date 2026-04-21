unit uPDF.TTFParser;

{$SCOPEDENUMS ON}

// ============================================================================
// TTTFParser
//
// Pure binary parser for TrueType (.ttf) and OpenType (.otf) font files.
// No PDF coupling — only extracts the data that the embedding pipeline needs:
//   • font metrics (unitsPerEm, ascender, descender, capHeight, bbox)
//   • character-to-glyph-ID mapping (from cmap formats 4 and 12)
//   • per-glyph advance widths (from hmtx)
//   • glyph byte offsets/lengths in glyf (for the subsetter)
//   • raw table bytes (for the subsetter to rebuild the subset font)
//   • embedding permission check (fsType from OS/2)
//
// All multi-byte values in TTF are big-endian. This parser converts every
// read to host byte order via explicit shift+or operations.
// ============================================================================

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  uPDF.Errors;

type
  // -------------------------------------------------------------------------
  // Metrics record (design units; divide by UnitsPerEm to get em fractions)
  // -------------------------------------------------------------------------
  TTTFMetrics = record
    UnitsPerEm:   Word;
    Ascender:     SmallInt;   // from hhea
    Descender:    SmallInt;
    CapHeight:    SmallInt;   // from OS/2 v2+; estimated from Ascender if absent
    ItalicAngle:  Single;     // from post table
    XMin, YMin, XMax, YMax: SmallInt;  // font bbox
    IsBold:       Boolean;
    IsItalic:     Boolean;
    IsFixedPitch: Boolean;
  end;

  // -------------------------------------------------------------------------
  // TTTFParser — main class
  // -------------------------------------------------------------------------
  TTTFParser = class
  private
    FData:             TBytes;
    FTableOffsets:     TDictionary<string, Cardinal>;  // tag → byte offset in FData
    FTableLengths:     TDictionary<string, Cardinal>;  // tag → byte length
    FMetrics:          TTTFMetrics;
    FNumGlyphs:        Word;
    FNumHMetrics:      Word;
    FIndexToLocFormat: SmallInt;      // 0 = short loca, 1 = long loca
    FLocaOffsets:      TArray<Cardinal>;  // [0..NumGlyphs], byte offsets in glyf table
    FAdvWidths:        TArray<Word>;      // [0..NumGlyphs-1] advance widths (design units)
    FCmap:             TDictionary<Cardinal, Word>;  // Unicode codepoint → GlyphID
    FFamilyName:       string;
    FFullName:         string;
    FPSName:           string;
    FIsCFF:            Boolean;
    FEmbedOK:          Boolean;
    FValid:            Boolean;

    // Bounds check + raw big-endian reads
    procedure CheckBounds(AOffset, ASize: Cardinal);
    function  RU16 (Offset: Cardinal): Word;     inline;
    function  RS16 (Offset: Cardinal): SmallInt; inline;
    function  RU32 (Offset: Cardinal): Cardinal; inline;
    function  RFixed(Offset: Cardinal): Single;  inline;  // 16.16 fixed → Single

    // Table parsers (called in order by Parse)
    procedure ParseTableDirectory;
    procedure ParseMaxp;
    procedure ParseHead;
    procedure ParseHhea;
    procedure ParseOS2;
    procedure ParsePost;
    procedure ParseName;
    procedure ParseHmtx;
    procedure ParseLoca;
    procedure ParseCmap;

    // cmap subtable parsers
    procedure ParseCmapFormat4 (ACmapBase, ASubtableOffset: Cardinal);
    procedure ParseCmapFormat12(ACmapBase, ASubtableOffset: Cardinal);

    // name table string decoder (UTF-16BE or Mac Roman)
    function  ReadNameString(AStorageBase, ARecordOffset,
                ARecordLength: Cardinal; APlatformID: Word): string;

  public
    constructor Create(const AFontData: TBytes);
    destructor  Destroy; override;

    // Parse all required tables.
    // Returns True only when the font is structurally valid AND embedding
    // is permitted (fsType bit 1 not set).
    // On failure, Valid and EmbeddingPermitted carry the specific reason.
    function  Parse: Boolean;

    // ---- Properties (meaningful after Parse) ----
    property Valid:              Boolean     read FValid;
    property IsCFF:              Boolean     read FIsCFF;   // OTF with CFF table
    property Metrics:            TTTFMetrics read FMetrics;
    property NumGlyphs:          Word        read FNumGlyphs;
    property PSName:             string      read FPSName;
    property FamilyName:         string      read FFamilyName;
    property FullName:           string      read FFullName;
    property EmbeddingPermitted: Boolean     read FEmbedOK;
    property RawData:            TBytes      read FData;

    // All Unicode → GlyphID mappings built from cmap (read-only)
    property CmapEntries: TDictionary<Cardinal, Word> read FCmap;

    // ---- Lookups ----

    // Unicode code point → GlyphID; returns 0 for unmapped characters (notdef)
    function CharToGlyph(AUnicode: Cardinal): Word;

    // Advance width in design units for a given GlyphID
    function GlyphAdvanceWidth(AGlyphID: Word): Word;

    // Absolute byte offset and byte length of a glyph in the glyf table
    // (both 0 for CFF fonts or out-of-range IDs — subsetter handles CFF separately)
    function GlyphOffset(AGlyphID: Word): Cardinal;
    function GlyphLength(AGlyphID: Word): Cardinal;

    // Raw table access (empty result if tag absent)
    function  GetTable(const ATag: string): TBytes;
    function  HasTable(const ATag: string): Boolean;

    // Raw glyph bytes from the glyf table (empty for CFF, empty/zero-length glyphs)
    function  GetGlyphData(AGlyphID: Word): TBytes;

    property NumHMetrics: Word read FNumHMetrics;
  end;

implementation

// ============================================================================
// Constructor / Destructor
// ============================================================================

constructor TTTFParser.Create(const AFontData: TBytes);
begin
  inherited Create;
  FData         := AFontData;
  FTableOffsets := TDictionary<string, Cardinal>.Create;
  FTableLengths := TDictionary<string, Cardinal>.Create;
  FCmap         := TDictionary<Cardinal, Word>.Create;
  FEmbedOK      := True;
end;

destructor TTTFParser.Destroy;
begin
  FTableOffsets.Free;
  FTableLengths.Free;
  FCmap.Free;
  inherited;
end;

// ============================================================================
// Bounds checking + big-endian reads
// ============================================================================

procedure TTTFParser.CheckBounds(AOffset, ASize: Cardinal);
begin
  // Safe: check Length >= ASize first to avoid underflow in subtraction
  if (ASize > 0) and
     ((Cardinal(Length(FData)) < ASize) or
      (AOffset > Cardinal(Length(FData)) - ASize)) then
    raise EPDFParseError.CreateFmt(
      'TTF: read out of bounds (offset=%d, size=%d, fileLen=%d)',
      [AOffset, ASize, Length(FData)]);
end;

function TTTFParser.RU16(Offset: Cardinal): Word;
begin
  CheckBounds(Offset, 2);
  Result := (Word(FData[Offset]) shl 8) or FData[Offset + 1];
end;

function TTTFParser.RS16(Offset: Cardinal): SmallInt;
begin
  Result := SmallInt(RU16(Offset));
end;

function TTTFParser.RU32(Offset: Cardinal): Cardinal;
begin
  CheckBounds(Offset, 4);
  Result := (Cardinal(FData[Offset    ]) shl 24) or
            (Cardinal(FData[Offset + 1]) shl 16) or
            (Cardinal(FData[Offset + 2]) shl 8 ) or
             Cardinal(FData[Offset + 3]);
end;

function TTTFParser.RFixed(Offset: Cardinal): Single;
begin
  // Signed 16.16 fixed-point: treat raw 32-bit value as signed integer / 65536
  Result := Integer(RU32(Offset)) / 65536.0;
end;

// ============================================================================
// Table directory
// ============================================================================

procedure TTTFParser.ParseTableDirectory;
var
  SfVersion: Cardinal;
  NumTables: Word;
  I:         Integer;
  Base:      Cardinal;
  Tag:       string;
begin
  CheckBounds(0, 12);
  SfVersion := RU32(0);
  // Valid sfnt signatures
  if (SfVersion <> $00010000) and   // TrueType
     (SfVersion <> $4F54544F) and   // 'OTTO' — OpenType/CFF
     (SfVersion <> $74727565) and   // 'true' — older Mac TrueType
     (SfVersion <> $74797031) then  // 'typ1' — obsolete Mac Type 1
    raise EPDFParseError.Create('Not a valid TrueType or OpenType font file');

  NumTables := RU16(4);
  if NumTables = 0 then
    raise EPDFParseError.Create('TTF: table directory is empty');
  CheckBounds(12, Cardinal(NumTables) * 16);

  for I := 0 to NumTables - 1 do
  begin
    Base := 12 + Cardinal(I) * 16;
    SetLength(Tag, 4);
    Tag[1] := Char(FData[Base    ]);
    Tag[2] := Char(FData[Base + 1]);
    Tag[3] := Char(FData[Base + 2]);
    Tag[4] := Char(FData[Base + 3]);
    FTableOffsets.AddOrSetValue(Tag, RU32(Base + 8));
    FTableLengths.AddOrSetValue(Tag, RU32(Base + 12));
  end;
end;

// ============================================================================
// Individual table parsers
// ============================================================================

procedure TTTFParser.ParseMaxp;
var
  Off: Cardinal;
begin
  if not FTableOffsets.TryGetValue('maxp', Off) then
    raise EPDFParseError.Create('TTF: missing required "maxp" table');
  CheckBounds(Off, 6);
  FNumGlyphs := RU16(Off + 4);
  if FNumGlyphs = 0 then
    raise EPDFParseError.Create('TTF: numGlyphs = 0');
end;

procedure TTTFParser.ParseHead;
var
  Off:      Cardinal;
  MacStyle: Word;
begin
  if not FTableOffsets.TryGetValue('head', Off) then
    raise EPDFParseError.Create('TTF: missing required "head" table');
  CheckBounds(Off, 54);
  FMetrics.UnitsPerEm := RU16(Off + 18);
  if FMetrics.UnitsPerEm = 0 then
    raise EPDFParseError.Create('TTF: unitsPerEm = 0');
  FMetrics.XMin := RS16(Off + 36);
  FMetrics.YMin := RS16(Off + 38);
  FMetrics.XMax := RS16(Off + 40);
  FMetrics.YMax := RS16(Off + 42);
  MacStyle := RU16(Off + 44);
  FMetrics.IsBold   := (MacStyle and 1) <> 0;
  FMetrics.IsItalic := (MacStyle and 2) <> 0;
  FIndexToLocFormat := RS16(Off + 50);
end;

procedure TTTFParser.ParseHhea;
var
  Off: Cardinal;
begin
  if not FTableOffsets.TryGetValue('hhea', Off) then
    raise EPDFParseError.Create('TTF: missing required "hhea" table');
  CheckBounds(Off, 36);
  FMetrics.Ascender  := RS16(Off + 4);
  FMetrics.Descender := RS16(Off + 6);
  FNumHMetrics       := RU16(Off + 34);
  // numberOfHMetrics = 0 is invalid; fall back to numGlyphs
  if FNumHMetrics = 0 then
    FNumHMetrics := FNumGlyphs;
end;

procedure TTTFParser.ParseOS2;
var
  Off, TblLen: Cardinal;
  Version, FsType, FsSelection: Word;
begin
  if not FTableOffsets.TryGetValue('OS/2', Off) then
  begin
    FEmbedOK := True;  // OS/2 absent → no restriction info → allow
    Exit;
  end;
  TblLen := FTableLengths['OS/2'];

  // Minimum 10 bytes to read fsType
  if TblLen < 10 then begin FEmbedOK := True; Exit; end;
  CheckBounds(Off, 10);
  Version := RU16(Off + 0);
  FsType  := RU16(Off + 8);
  // Bit 1 (value 2) = Restricted License Embedding — block embedding
  FEmbedOK := (FsType and 2) = 0;

  // fsSelection at offset 62 (needs at least 64 bytes)
  if TblLen >= 64 then
  begin
    CheckBounds(Off, 64);
    FsSelection := RU16(Off + 62);
    FMetrics.IsBold   := (FsSelection and $20) <> 0;  // bit 5
    FMetrics.IsItalic := (FsSelection and $01) <> 0;  // bit 0
  end;

  // sCapHeight at offset 88 — available from OS/2 version 2+
  if (Version >= 2) and (TblLen >= 90) then
  begin
    CheckBounds(Off, 90);
    FMetrics.CapHeight := RS16(Off + 88);
  end;
end;

procedure TTTFParser.ParsePost;
var
  Off: Cardinal;
begin
  if not FTableOffsets.TryGetValue('post', Off) then Exit;
  CheckBounds(Off, 16);
  FMetrics.ItalicAngle  := RFixed(Off + 4);
  FMetrics.IsFixedPitch := RU32(Off + 12) <> 0;
end;

procedure TTTFParser.ParseName;
var
  Off, StorageBase: Cardinal;
  Count:            Word;
  I:                Integer;
  RecBase:          Cardinal;
  PlatformID, EncodingID, NameID, RecLen, RecOff: Word;
  S:                string;
  BestFamScore, BestFullScore, BestPSScore: Integer;
  Score: Integer;
begin
  if not FTableOffsets.TryGetValue('name', Off) then Exit;
  CheckBounds(Off, 6);
  Count       := RU16(Off + 2);
  StorageBase := Off + RU16(Off + 4);  // absolute file offset of string storage

  if Count = 0 then Exit;
  CheckBounds(Off + 6, Cardinal(Count) * 12);

  BestFamScore  := -1;
  BestFullScore := -1;
  BestPSScore   := -1;

  for I := 0 to Count - 1 do
  begin
    RecBase    := Off + 6 + Cardinal(I) * 12;
    PlatformID := RU16(RecBase + 0);
    EncodingID := RU16(RecBase + 2);
    NameID     := RU16(RecBase + 6);
    RecLen     := RU16(RecBase + 8);
    RecOff     := RU16(RecBase + 10);

    if not (NameID in [1, 4, 6]) then Continue;
    // Accept Windows Unicode (3,1) or Mac Roman (1,0)
    if not ((PlatformID = 3) and (EncodingID = 1)) and
       not ((PlatformID = 1) and (EncodingID = 0)) then Continue;

    // Windows Unicode preferred over Mac Roman
    if PlatformID = 3 then Score := 1 else Score := 0;

    S := ReadNameString(StorageBase, RecOff, RecLen, PlatformID);
    if S = '' then Continue;

    case NameID of
      1: if Score > BestFamScore  then begin FFamilyName := S; BestFamScore  := Score; end;
      4: if Score > BestFullScore then begin FFullName   := S; BestFullScore := Score; end;
      6: if Score > BestPSScore   then begin FPSName     := S; BestPSScore   := Score; end;
    end;
  end;

  // Fallback chain: PSName → FullName → FamilyName
  if FPSName     = '' then FPSName     := FFullName;
  if FPSName     = '' then FPSName     := FFamilyName;
  if FFamilyName = '' then FFamilyName := FFullName;
end;

function TTTFParser.ReadNameString(AStorageBase, ARecordOffset,
  ARecordLength: Cardinal; APlatformID: Word): string;
var
  AbsOff: Cardinal;
  I:      Integer;
  Ch:     Word;
begin
  if ARecordLength = 0 then Exit('');
  AbsOff := AStorageBase + ARecordOffset;
  CheckBounds(AbsOff, ARecordLength);
  Result := '';
  if APlatformID = 3 then
  begin
    // UTF-16BE: 2 bytes per code unit
    I := 0;
    while I + 1 < Integer(ARecordLength) do
    begin
      Ch := (Word(FData[AbsOff + Cardinal(I)]) shl 8) or
             FData[AbsOff + Cardinal(I) + 1];
      Result := Result + Char(Ch);
      Inc(I, 2);
    end;
  end else
  begin
    // Mac Roman: 1 byte per char (ASCII-compatible for typical name strings)
    for I := 0 to Integer(ARecordLength) - 1 do
      Result := Result + Char(FData[AbsOff + Cardinal(I)]);
  end;
end;

procedure TTTFParser.ParseHmtx;
var
  Off:          Cardinal;
  I:            Integer;
  LastAdvWidth: Word;
begin
  if not FTableOffsets.TryGetValue('hmtx', Off) then
    raise EPDFParseError.Create('TTF: missing required "hmtx" table');
  if FNumGlyphs = 0 then Exit;

  SetLength(FAdvWidths, FNumGlyphs);
  CheckBounds(Off, Cardinal(FNumHMetrics) * 4);

  LastAdvWidth := 0;
  for I := 0 to FNumHMetrics - 1 do
  begin
    LastAdvWidth  := RU16(Off + Cardinal(I) * 4);
    FAdvWidths[I] := LastAdvWidth;
  end;
  // Glyphs beyond numberOfHMetrics repeat the last advance width
  for I := FNumHMetrics to FNumGlyphs - 1 do
    FAdvWidths[I] := LastAdvWidth;
end;

procedure TTTFParser.ParseLoca;
var
  Off: Cardinal;
  I:   Integer;
begin
  // loca is only present for TrueType (glyf) fonts, not CFF
  if not HasTable('glyf') then Exit;
  if not FTableOffsets.TryGetValue('loca', Off) then
    raise EPDFParseError.Create('TTF: missing "loca" table (required for glyf font)');

  SetLength(FLocaOffsets, FNumGlyphs + 1);
  if FIndexToLocFormat = 0 then
  begin
    // Short format: USHORT values × 2 = byte offset
    CheckBounds(Off, Cardinal(FNumGlyphs + 1) * 2);
    for I := 0 to FNumGlyphs do
      FLocaOffsets[I] := Cardinal(RU16(Off + Cardinal(I) * 2)) * 2;
  end else
  begin
    // Long format: ULONG values = direct byte offset
    CheckBounds(Off, Cardinal(FNumGlyphs + 1) * 4);
    for I := 0 to FNumGlyphs do
      FLocaOffsets[I] := RU32(Off + Cardinal(I) * 4);
  end;
end;

procedure TTTFParser.ParseCmap;
var
  CmapOff:           Cardinal;
  NumSubtables:      Word;
  I:                 Integer;
  SubBase:           Cardinal;
  Platform, Encoding: Word;
  SubOffset, Format: Word;
  BestScore:         Integer;
  BestSubOff:        Cardinal;
  BestFmt:           Word;
  Score:             Integer;
begin
  if not FTableOffsets.TryGetValue('cmap', CmapOff) then
    raise EPDFParseError.Create('TTF: missing required "cmap" table');
  CheckBounds(CmapOff, 4);
  NumSubtables := RU16(CmapOff + 2);
  if NumSubtables = 0 then
    raise EPDFParseError.Create('TTF: cmap has no subtables');
  CheckBounds(CmapOff + 4, Cardinal(NumSubtables) * 8);

  BestScore  := -1;
  BestSubOff := 0;
  BestFmt    := 0;

  for I := 0 to NumSubtables - 1 do
  begin
    SubBase   := CmapOff + 4 + Cardinal(I) * 8;
    Platform  := RU16(SubBase + 0);
    Encoding  := RU16(SubBase + 2);
    SubOffset := RU32(SubBase + 4);  // offset from start of cmap table

    if CmapOff + SubOffset + 2 > Cardinal(Length(FData)) then Continue;
    Format := RU16(CmapOff + SubOffset);

    // Score: Windows full-Unicode/12 > Windows BMP > Unicode platform
    Score := 0;
    if   (Platform = 3) and (Encoding = 10) and (Format = 12) then Score := 4
    else if (Platform = 3) and (Encoding = 1) and (Format = 12) then Score := 3
    else if (Platform = 3) and (Encoding = 1) and (Format = 4)  then Score := 2
    else if (Platform = 0) and (Encoding in [3, 4]) and (Format = 12) then Score := 2
    else if (Platform = 0) and (Encoding in [3, 4]) and (Format = 4)  then Score := 1;

    if Score > BestScore then
    begin
      BestScore  := Score;
      BestSubOff := SubOffset;
      BestFmt    := Format;
    end;
  end;

  if BestScore < 0 then
    raise EPDFParseError.Create('TTF: no usable Unicode cmap subtable (need format 4 or 12)');

  case BestFmt of
    4:  ParseCmapFormat4 (CmapOff, BestSubOff);
    12: ParseCmapFormat12(CmapOff, BestSubOff);
  else
    raise EPDFParseError.CreateFmt('TTF: unsupported cmap format %d', [BestFmt]);
  end;
end;

procedure TTTFParser.ParseCmapFormat4(ACmapBase, ASubtableOffset: Cardinal);
var
  Off:            Cardinal;
  SegCount:       Word;
  SegBytes:       Cardinal;
  EndBase, StartBase, DeltaBase, RangeBase: Cardinal;
  I:              Integer;
  EndC, StartC, RangeOff: Word;
  Delta:          SmallInt;
  C:              Cardinal;
  GlyphID:        Word;
  GlyphIdOff:     Cardinal;
  DataLen:        Cardinal;
begin
  Off := ACmapBase + ASubtableOffset;
  CheckBounds(Off, 14);
  SegCount := RU16(Off + 6) div 2;
  if SegCount = 0 then Exit;

  SegBytes   := Cardinal(SegCount) * 2;
  EndBase    := Off + 14;
  StartBase  := Off + 14 + SegBytes + 2;    // +2 skips the reserved padding
  DeltaBase  := Off + 14 + SegBytes * 2 + 2;
  RangeBase  := Off + 14 + SegBytes * 3 + 2;
  // glyphIdArray starts at Off + 14 + SegBytes*4 + 2 — accessed via self-relative RangeOff

  CheckBounds(EndBase, SegBytes * 4 + 2);  // all 4 arrays + padding
  DataLen := Cardinal(Length(FData));

  for I := 0 to SegCount - 1 do
  begin
    EndC     := RU16(EndBase   + Cardinal(I) * 2);
    StartC   := RU16(StartBase + Cardinal(I) * 2);
    Delta    := RS16(DeltaBase + Cardinal(I) * 2);
    RangeOff := RU16(RangeBase + Cardinal(I) * 2);

    // Last sentinel segment: startCode=$FFFF endCode=$FFFF
    if (StartC = $FFFF) and (EndC = $FFFF) then Continue;

    for C := StartC to EndC do
    begin
      if RangeOff = 0 then
      begin
        // GlyphID = (charCode + idDelta) mod 65536
        GlyphID := Word((Integer(C) + Integer(Delta)) and $FFFF);
      end else
      begin
        // Self-relative offset from &idRangeOffset[I] into glyphIdArray
        GlyphIdOff := (RangeBase + Cardinal(I) * 2) + RangeOff + (C - StartC) * 2;
        if GlyphIdOff + 2 > DataLen then Continue;
        GlyphID := (Word(FData[GlyphIdOff]) shl 8) or FData[GlyphIdOff + 1];
        if GlyphID <> 0 then
          GlyphID := Word((Integer(GlyphID) + Integer(Delta)) and $FFFF);
      end;
      if GlyphID <> 0 then
        FCmap.AddOrSetValue(C, GlyphID);
    end;
  end;
end;

procedure TTTFParser.ParseCmapFormat12(ACmapBase, ASubtableOffset: Cardinal);
var
  Off:                            Cardinal;
  NumGroups, I:                   Cardinal;
  GroupBase:                      Cardinal;
  StartChar, EndChar, StartGlyph: Cardinal;
  C, GID:                         Cardinal;
begin
  Off := ACmapBase + ASubtableOffset;
  CheckBounds(Off, 16);
  NumGroups := RU32(Off + 12);
  if NumGroups = 0 then Exit;

  GroupBase := Off + 16;
  CheckBounds(GroupBase, NumGroups * 12);

  for I := 0 to NumGroups - 1 do
  begin
    StartChar  := RU32(GroupBase + I * 12 + 0);
    EndChar    := RU32(GroupBase + I * 12 + 4);
    StartGlyph := RU32(GroupBase + I * 12 + 8);
    for C := StartChar to EndChar do
    begin
      GID := StartGlyph + (C - StartChar);
      if GID <= $FFFF then  // only store IDs that fit in Word
        FCmap.AddOrSetValue(C, Word(GID));
    end;
  end;
end;

// ============================================================================
// Parse entry point
// ============================================================================

function TTTFParser.Parse: Boolean;
begin
  FValid := False;
  try
    ParseTableDirectory;
    ParseMaxp;    // numGlyphs — needed by all subsequent parsers
    ParseHead;    // unitsPerEm, bbox, loca format
    ParseHhea;    // ascender/descender, numberOfHMetrics
    ParseOS2;     // embedding permission, capHeight, bold/italic flags
    ParsePost;    // italicAngle, isFixedPitch
    ParseName;    // family/full/PostScript names
    ParseHmtx;    // advance widths per glyph
    ParseLoca;    // glyph offsets (TrueType only; skip for CFF)
    ParseCmap;    // Unicode → GlyphID mapping
    FIsCFF := HasTable('CFF ');
    // Fall back to Ascender if capHeight not available from OS/2
    if FMetrics.CapHeight = 0 then
      FMetrics.CapHeight := FMetrics.Ascender;
    FValid := True;
    Result := FEmbedOK;  // False if font is structurally valid but embedding restricted
  except
    on E: Exception do
    begin
      FValid := False;
      Result := False;
    end;
  end;
end;

// ============================================================================
// Public accessors
// ============================================================================

function TTTFParser.CharToGlyph(AUnicode: Cardinal): Word;
begin
  if not FCmap.TryGetValue(AUnicode, Result) then
    Result := 0;
end;

function TTTFParser.GlyphAdvanceWidth(AGlyphID: Word): Word;
begin
  if AGlyphID < Word(Length(FAdvWidths)) then
    Result := FAdvWidths[AGlyphID]
  else
    Result := 0;
end;

function TTTFParser.GlyphOffset(AGlyphID: Word): Cardinal;
var
  GlyfOff: Cardinal;
begin
  if (AGlyphID >= FNumGlyphs) or (Length(FLocaOffsets) = 0) then Exit(0);
  if not FTableOffsets.TryGetValue('glyf', GlyfOff) then Exit(0);
  Result := GlyfOff + FLocaOffsets[AGlyphID];
end;

function TTTFParser.GlyphLength(AGlyphID: Word): Cardinal;
begin
  if (AGlyphID >= FNumGlyphs) or
     (Integer(AGlyphID) + 1 >= Length(FLocaOffsets)) then Exit(0);
  // loca[i+1] - loca[i] gives the byte count in the glyf table
  if FLocaOffsets[AGlyphID + 1] >= FLocaOffsets[AGlyphID] then
    Result := FLocaOffsets[AGlyphID + 1] - FLocaOffsets[AGlyphID]
  else
    Result := 0;
end;

function TTTFParser.GetTable(const ATag: string): TBytes;
var
  Off, Len: Cardinal;
begin
  if not FTableOffsets.TryGetValue(ATag, Off) or
     not FTableLengths.TryGetValue(ATag, Len) or
     (Len = 0) then
    Exit(nil);
  SetLength(Result, Len);
  CheckBounds(Off, Len);
  Move(FData[Off], Result[0], Len);
end;

function TTTFParser.HasTable(const ATag: string): Boolean;
begin
  Result := FTableOffsets.ContainsKey(ATag);
end;

function TTTFParser.GetGlyphData(AGlyphID: Word): TBytes;
var Off, Len: Cardinal;
begin
  Result := nil;
  Off := GlyphOffset(AGlyphID);
  Len := GlyphLength(AGlyphID);
  if (Len = 0) or (Off = 0) then Exit;
  SetLength(Result, Len);
  Move(FData[Off], Result[0], Len);
end;

end.
