unit uPDF.TTFSubset;

{$SCOPEDENUMS ON}

// ============================================================================
// TTTFSubsetter — Phase 2 of TTF/OTF font embedding
//
// Takes a parsed TTF (TTTFParser) + a set of requested glyph IDs, performs
// composite-glyph closure (adds component glyphs automatically), then emits
// a spec-compliant TTF subset containing exactly those glyphs.
//
// Tables written in alphabetical order (as required by the spec):
//   OS/2 · cmap · glyf · head · hhea · hmtx · loca · maxp · name · post
//
// Usage:
//   var Sub := TTTFSubsetter.Create(Parser, [GlyphID1, GlyphID2, ...]);
//   try
//     FontFileBytes := Sub.Build;           // raw TTF bytes for /FontFile2
//     NewID         := Sub.MapGlyph(OldID); // old → new glyph ID mapping
//   finally Sub.Free; end;
// ============================================================================

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.Generics.Defaults,
  uPDF.Errors, uPDF.TTFParser;

type
  TTTFSubsetter = class
  private
    FParser   : TTTFParser;
    FNewGlyphs: TList<Word>;             // index = newID, value = oldID
    FGlyphMap : TDictionary<Word, Word>; // oldID → newID

    procedure BuildClosure(const AInput: array of Word);

    function BuildOS2  : TBytes;
    function BuildCmap : TBytes;
    function BuildGlyf (out ALoca: TBytes; out ALocaFmt: SmallInt): TBytes;
    function BuildHead (ALocaFmt: SmallInt): TBytes;
    function BuildHhea : TBytes;
    function BuildHmtx : TBytes;
    function BuildMaxp : TBytes;
    function BuildName : TBytes;
    function BuildPost : TBytes;

    function  GlyphLSB(AOldID: Word): SmallInt;
    function  TableChecksum(const AData: TBytes): Cardinal;
    function  GetGlyphCount: Integer;
  public
    constructor Create(AParser: TTTFParser; const AGlyphIDs: array of Word);
    destructor  Destroy; override;

    { Build the subset font.  Returns raw TTF bytes ready for /FontFile2. }
    function Build: TBytes;

    { Map old GlyphID → new GlyphID in the subset.
      Returns 0 (notdef) for IDs not included. }
    function MapGlyph(AOldGlyphID: Word): Word;

    { Reverse of MapGlyph: new GlyphID → old GlyphID.  Returns 0 if out of range. }
    function OldGlyphID(ANewGlyphID: Word): Word;

    property GlyphCount: Integer read GetGlyphCount;
  end;

implementation

// ============================================================================
// Implementation-level types
// ============================================================================

type
  TTTFTableEntry = record
    Tag    : array[0..3] of AnsiChar;
    Data   : TBytes;
    CSum   : Cardinal;
    Offset : Cardinal;
    Len    : Cardinal;
  end;

// ============================================================================
// Stream write helpers (big-endian, module-level so all builders can use them)
// ============================================================================

procedure BW2(S: TBytesStream; V: Word);
var B: array[0..1] of Byte;
begin B[0] := V shr 8; B[1] := V and $FF; S.Write(B, 2); end;

procedure BW4(S: TBytesStream; V: Cardinal);
var B: array[0..3] of Byte;
begin
  B[0] := (V shr 24) and $FF; B[1] := (V shr 16) and $FF;
  B[2] := (V shr  8) and $FF; B[3] :=  V and $FF; S.Write(B, 4);
end;

procedure BWS2(S: TBytesStream; V: SmallInt);
begin BW2(S, Word(V)); end;

procedure PadTo4(S: TBytesStream);
var Rem: Integer; Z: array[0..2] of Byte;
begin
  Rem := S.Size mod 4;
  if Rem > 0 then begin FillChar(Z, SizeOf(Z), 0); S.Write(Z, 4 - Rem); end;
end;

function StreamBytes(S: TBytesStream): TBytes;
begin
  SetLength(Result, S.Size);
  if S.Size > 0 then Move(S.Bytes[0], Result[0], S.Size);
end;

// ============================================================================
// Constructor / Destructor
// ============================================================================

constructor TTTFSubsetter.Create(AParser: TTTFParser; const AGlyphIDs: array of Word);
begin
  inherited Create;
  FParser    := AParser;
  FNewGlyphs := TList<Word>.Create;
  FGlyphMap  := TDictionary<Word, Word>.Create;
  BuildClosure(AGlyphIDs);
end;

destructor TTTFSubsetter.Destroy;
begin
  FNewGlyphs.Free;
  FGlyphMap.Free;
  inherited;
end;

// ============================================================================
// Composite-glyph closure (BFS)
// Starts with glyph 0 + requested IDs, then walks composite components
// recursively until no new glyphs are discovered.
// ============================================================================

procedure TTTFSubsetter.BuildClosure(const AInput: array of Word);
const MORE_COMP  = Word($0020);
      ARG_WORDS  = Word($0001);
      SC_SCALE   = Word($0008);
      SC_XYSCALE = Word($0040);
      SC_2X2     = Word($0080);
var
  Seen  : TDictionary<Word, Boolean>;
  Queue : TQueue<Word>;
  Sorted: TList<Word>;
  ID, CID, Flags: Word;
  GData : TBytes;
  Off   : Integer;
  NC    : SmallInt;

  procedure Enq(G: Word);
  begin
    if not Seen.ContainsKey(G) then
    begin Seen.Add(G, True); Queue.Enqueue(G); end;
  end;

begin
  Seen   := TDictionary<Word, Boolean>.Create;
  Queue  := TQueue<Word>.Create;
  Sorted := TList<Word>.Create;
  try
    Enq(0);                              // notdef always included
    for ID in AInput do Enq(ID);

    while Queue.Count > 0 do
    begin
      ID    := Queue.Dequeue;
      GData := FParser.GetGlyphData(ID);
      if Length(GData) < 10 then Continue;
      NC := SmallInt((Word(GData[0]) shl 8) or GData[1]);
      if NC >= 0 then Continue;          // simple glyph — no components to add

      Off := 10;
      repeat
        if Off + 4 > Length(GData) then Break;
        Flags := (Word(GData[Off]) shl 8) or GData[Off + 1];
        CID   := (Word(GData[Off + 2]) shl 8) or GData[Off + 3];
        Inc(Off, 4);
        Enq(CID);
        if (Flags and ARG_WORDS)  <> 0 then Inc(Off, 4) else Inc(Off, 2);
        if      (Flags and SC_2X2)    <> 0 then Inc(Off, 8)
        else if (Flags and SC_XYSCALE)<> 0 then Inc(Off, 4)
        else if (Flags and SC_SCALE)  <> 0 then Inc(Off, 2);
      until (Flags and MORE_COMP) = 0;
    end;

    // Assign new IDs: 0 = notdef, then remaining sorted by old ID
    FNewGlyphs.Clear; FGlyphMap.Clear;
    FNewGlyphs.Add(0); FGlyphMap.AddOrSetValue(0, 0);
    for ID in Seen.Keys do if ID <> 0 then Sorted.Add(ID);
    Sorted.Sort;
    for ID in Sorted do
    begin
      FGlyphMap.AddOrSetValue(ID, Word(FNewGlyphs.Count));
      FNewGlyphs.Add(ID);
    end;
  finally
    Seen.Free; Queue.Free; Sorted.Free;
  end;
end;

// ============================================================================
// Helpers
// ============================================================================

function TTTFSubsetter.GlyphLSB(AOldID: Word): SmallInt;
var Hmtx: TBytes; NHM: Word; Off: Integer;
begin
  Result := 0;
  Hmtx := FParser.GetTable('hmtx');
  NHM  := FParser.NumHMetrics;
  if (NHM = 0) or (Length(Hmtx) = 0) then Exit;
  if AOldID < NHM then
    Off := Integer(AOldID) * 4 + 2         // full {advW(2), lsb(2)} entry
  else
    Off := Integer(NHM) * 4 + Integer(AOldID - NHM) * 2; // lsb-only section
  if Off + 2 > Length(Hmtx) then Exit;
  Result := SmallInt((Word(Hmtx[Off]) shl 8) or Hmtx[Off + 1]);
end;

function TTTFSubsetter.TableChecksum(const AData: TBytes): Cardinal;
var I, N: Integer; V: Cardinal;
begin
  Result := 0;
  N := (Length(AData) + 3) div 4;
  for I := 0 to N - 1 do
  begin
    V := 0;
    if I*4   < Length(AData) then V := V or (Cardinal(AData[I*4  ]) shl 24);
    if I*4+1 < Length(AData) then V := V or (Cardinal(AData[I*4+1]) shl 16);
    if I*4+2 < Length(AData) then V := V or (Cardinal(AData[I*4+2]) shl  8);
    if I*4+3 < Length(AData) then V := V or  Cardinal(AData[I*4+3]);
    Inc(Result, V);
  end;
end;

function TTTFSubsetter.GetGlyphCount: Integer;
begin Result := FNewGlyphs.Count; end;

function TTTFSubsetter.MapGlyph(AOldGlyphID: Word): Word;
begin
  if not FGlyphMap.TryGetValue(AOldGlyphID, Result) then Result := 0;
end;

function TTTFSubsetter.OldGlyphID(ANewGlyphID: Word): Word;
begin
  if ANewGlyphID < Word(FNewGlyphs.Count) then
    Result := FNewGlyphs[ANewGlyphID]
  else
    Result := 0;
end;

// ============================================================================
// Table builders
// ============================================================================

function TTTFSubsetter.BuildOS2: TBytes;
begin Result := FParser.GetTable('OS/2'); end;

function TTTFSubsetter.BuildName: TBytes;
begin Result := FParser.GetTable('name'); end;

function TTTFSubsetter.BuildHead(ALocaFmt: SmallInt): TBytes;
var Orig: TBytes;
begin
  Orig := FParser.GetTable('head');
  if Length(Orig) < 54 then raise EPDFParseError.Create('TTF: head table too short');
  Result := Copy(Orig, 0, Length(Orig));
  // checkSumAdjustment at offset 8 — zeroed here, patched after file assembly
  Result[ 8] := 0; Result[ 9] := 0; Result[10] := 0; Result[11] := 0;
  // indexToLocFormat at offset 50
  Result[50] := Byte(Word(ALocaFmt) shr 8);
  Result[51] := Byte(Word(ALocaFmt) and $FF);
end;

function TTTFSubsetter.BuildHhea: TBytes;
var Orig: TBytes; N: Word;
begin
  Orig := FParser.GetTable('hhea');
  if Length(Orig) < 36 then raise EPDFParseError.Create('TTF: hhea table too short');
  Result := Copy(Orig, 0, Length(Orig));
  N := Word(FNewGlyphs.Count);
  Result[34] := N shr 8; Result[35] := N and $FF; // numberOfHMetrics
end;

function TTTFSubsetter.BuildMaxp: TBytes;
var Orig: TBytes; N: Word;
begin
  Orig := FParser.GetTable('maxp');
  if Length(Orig) < 6 then raise EPDFParseError.Create('TTF: maxp table too short');
  Result := Copy(Orig, 0, Length(Orig));
  N := Word(FNewGlyphs.Count);
  Result[4] := N shr 8; Result[5] := N and $FF; // numGlyphs
end;

function TTTFSubsetter.BuildPost: TBytes;
// Emit format 3.0 (no glyph name table): 32 bytes
var Orig: TBytes; S: TBytesStream;
begin
  Orig := FParser.GetTable('post');
  S    := TBytesStream.Create;
  try
    BW4(S, $00030000); // version 3.0
    if Length(Orig) >= 16 then
      // Copy italicAngle(4) + underlinePos(2) + underlineThick(2) + isFixedPitch(4)
      S.Write(Orig[4], 12)
    else
    begin
      BW4(S, 0); BW2(S, 0); BW2(S, 0); BW4(S, 0);
    end;
    BW4(S, 0); BW4(S, 0); BW4(S, 0); BW4(S, 0); // minMemType42..maxMemType1
    Result := StreamBytes(S);
  finally S.Free; end;
end;

function TTTFSubsetter.BuildHmtx: TBytes;
var S: TBytesStream; I: Integer; OldID: Word;
begin
  S := TBytesStream.Create;
  try
    for I := 0 to FNewGlyphs.Count - 1 do
    begin
      OldID := FNewGlyphs[I];
      BW2 (S, FParser.GlyphAdvanceWidth(OldID));
      BWS2(S, GlyphLSB(OldID));
    end;
    Result := StreamBytes(S);
  finally S.Free; end;
end;

function TTTFSubsetter.BuildGlyf(out ALoca: TBytes; out ALocaFmt: SmallInt): TBytes;
const MORE_COMP  = Word($0020);
      ARG_WORDS  = Word($0001);
      SC_SCALE   = Word($0008);
      SC_XYSCALE = Word($0040);
      SC_2X2     = Word($0080);
var
  GBuf    : TBytesStream;
  Offs    : TArray<Cardinal>;
  I, Off  : Integer;
  OldID   : Word;
  GData   : TBytes;
  ModData : TBytes;
  NC      : SmallInt;
  Flags, CID, NewCID: Word;
  ShOff   : Cardinal;
begin
  GBuf := TBytesStream.Create;
  try
    SetLength(Offs, FNewGlyphs.Count + 1);

    for I := 0 to FNewGlyphs.Count - 1 do
    begin
      Offs[I] := GBuf.Size;
      OldID   := FNewGlyphs[I];
      GData   := FParser.GetGlyphData(OldID);
      if Length(GData) = 0 then Continue; // empty glyph (space, etc.)

      NC := SmallInt((Word(GData[0]) shl 8) or GData[1]);
      if NC >= 0 then
        GBuf.Write(GData[0], Length(GData))   // simple: copy verbatim
      else
      begin
        // Composite: remap component glyph IDs to new IDs
        ModData := Copy(GData, 0, Length(GData));
        Off     := 10;
        repeat
          if Off + 4 > Length(ModData) then Break;
          Flags := (Word(ModData[Off]) shl 8) or ModData[Off + 1];
          CID   := (Word(ModData[Off + 2]) shl 8) or ModData[Off + 3];
          Inc(Off, 4);
          if not FGlyphMap.TryGetValue(CID, NewCID) then NewCID := 0;
          ModData[Off - 2] := NewCID shr 8;
          ModData[Off - 1] := NewCID and $FF;
          if (Flags and ARG_WORDS)  <> 0 then Inc(Off, 4) else Inc(Off, 2);
          if      (Flags and SC_2X2)    <> 0 then Inc(Off, 8)
          else if (Flags and SC_XYSCALE)<> 0 then Inc(Off, 4)
          else if (Flags and SC_SCALE)  <> 0 then Inc(Off, 2);
        until (Flags and MORE_COMP) = 0;
        GBuf.Write(ModData[0], Length(ModData));
      end;
      PadTo4(GBuf); // align each glyph to 4-byte boundary
    end;
    Offs[FNewGlyphs.Count] := GBuf.Size; // sentinel

    // Auto-select loca format: short (offset/2 as UInt16, max 128 KB) or long
    if Cardinal(GBuf.Size) > $1FFFE then
    begin
      ALocaFmt := 1;
      SetLength(ALoca, (FNewGlyphs.Count + 1) * 4);
      for I := 0 to FNewGlyphs.Count do
      begin
        ALoca[I*4  ] := (Offs[I] shr 24) and $FF;
        ALoca[I*4+1] := (Offs[I] shr 16) and $FF;
        ALoca[I*4+2] := (Offs[I] shr  8) and $FF;
        ALoca[I*4+3] :=  Offs[I] and $FF;
      end;
    end else
    begin
      ALocaFmt := 0;
      SetLength(ALoca, (FNewGlyphs.Count + 1) * 2);
      for I := 0 to FNewGlyphs.Count do
      begin
        ShOff := Offs[I] div 2;
        ALoca[I*2  ] := (ShOff shr 8) and $FF;
        ALoca[I*2+1] :=  ShOff and $FF;
      end;
    end;

    Result := StreamBytes(GBuf);
  finally GBuf.Free; end;
end;

function TTTFSubsetter.BuildCmap: TBytes;
// Emits a format 4 cmap (platform 3, encoding 1) containing only the
// codepoints whose original glyph IDs are in the subset.
type
  TCPair = record CP: Cardinal; GID: Word; end;
var
  Pairs   : TList<TCPair>;
  P       : TCPair;
  Entry   : TPair<Cardinal, Word>;
  NewGID  : Word;
  I, J    : Integer;
  Delta   : Integer;
  NSeg    : Integer;
  SegS, SegE, SegD: array of Word; // startCode, endCode, idDelta
  SRng, EntSel, RShift: Word;
  SubLen  : Integer;
  S       : TBytesStream;
begin
  Pairs := TList<TCPair>.Create;
  try
    // Collect (codepoint, newGlyphID) for BMP codepoints in our subset
    for Entry in FParser.CmapEntries do
      if (Entry.Key <= $FFFE) and (Entry.Value <> 0) and
         FGlyphMap.TryGetValue(Entry.Value, NewGID) then
      begin
        P.CP := Entry.Key; P.GID := NewGID; Pairs.Add(P);
      end;

    Pairs.Sort(TComparer<TCPair>.Construct(
      function(const A, B: TCPair): Integer
      begin Result := Integer(A.CP) - Integer(B.CP); end));

    // Group consecutive codepoints with the same (newGID - cp) delta into segments
    NSeg := 0;
    SetLength(SegS, Pairs.Count + 1);
    SetLength(SegE, Pairs.Count + 1);
    SetLength(SegD, Pairs.Count + 1);
    I := 0;
    while I < Pairs.Count do
    begin
      Delta := Integer(Pairs[I].GID) - Integer(Pairs[I].CP);
      J := I + 1;
      while (J < Pairs.Count) and
            (Pairs[J].CP = Pairs[J-1].CP + 1) and
            (Integer(Pairs[J].GID) - Integer(Pairs[J].CP) = Delta) do
        Inc(J);
      SegS[NSeg] := Word(Pairs[I].CP);
      SegE[NSeg] := Word(Pairs[J-1].CP);
      SegD[NSeg] := Word(Delta and $FFFF);
      Inc(NSeg); I := J;
    end;
    // Terminal segment required by spec
    SegS[NSeg] := $FFFF; SegE[NSeg] := $FFFF; SegD[NSeg] := 1;
    Inc(NSeg);

    // searchRange / entrySelector / rangeShift
    SRng := 1; EntSel := 0;
    while SRng * 2 <= Word(NSeg) do begin SRng := SRng * 2; Inc(EntSel); end;
    SRng   := Word(SRng * 2);
    RShift := Word(NSeg * 2 - SRng);

    // subtable length = 14 (fixed header) + 2 (pad) + 4 arrays × NSeg × 2
    SubLen := 16 + NSeg * 8;
    if SubLen > $FFFF then
      raise EPDFParseError.Create('TTF: too many cmap segments for format 4');

    S := TBytesStream.Create;
    try
      // cmap table header: version=0, numTables=1 (4 bytes)
      BW2(S, 0); BW2(S, 1);
      // Encoding record: platform=3, encoding=1, subtableOffset=12 (8 bytes)
      BW2(S, 3); BW2(S, 1); BW4(S, 12);
      // Format 4 subtable
      BW2(S, 4);              // format
      BW2(S, Word(SubLen));   // length
      BW2(S, 0);              // language
      BW2(S, NSeg * 2);       // segCountX2
      BW2(S, SRng);           // searchRange
      BW2(S, EntSel);         // entrySelector
      BW2(S, RShift);         // rangeShift
      for I := 0 to NSeg - 1 do BW2(S, SegE[I]);  // endCount[]
      BW2(S, 0);                                    // reservedPad
      for I := 0 to NSeg - 1 do BW2(S, SegS[I]);  // startCount[]
      for I := 0 to NSeg - 1 do BW2(S, SegD[I]);  // idDelta[]
      for I := 0 to NSeg - 1 do BW2(S, 0);        // idRangeOffset[] — all 0
      Result := StreamBytes(S);
    finally S.Free; end;
  finally Pairs.Free; end;
end;

// ============================================================================
// Build — assembles the complete TTF file
// ============================================================================

function TTTFSubsetter.Build: TBytes;
const NUM_TABLES = 10;
var
  T          : array[0..NUM_TABLES - 1] of TTTFTableEntry;
  Loca       : TBytes;
  LocaFmt    : SmallInt;
  I, J       : Integer;
  DataOff    : Cardinal;
  FileBuf    : TBytesStream;
  HeadAdjOff : Integer; // byte offset of head.checkSumAdjustment in final file
  FileSum    : Cardinal;
  V, CSAdj   : Cardinal;
  SR, ES     : Word;

  procedure SetTag(var D: TTTFTableEntry; const S: string);
  begin
    D.Tag[0] := AnsiChar(S[1]); D.Tag[1] := AnsiChar(S[2]);
    D.Tag[2] := AnsiChar(S[3]); D.Tag[3] := AnsiChar(S[4]);
  end;

begin
  Loca := nil; LocaFmt := 0;

  // Build all 10 tables (alphabetical order: OS/2 cmap glyf head hhea hmtx loca maxp name post)
  SetTag(T[0], 'OS/2'); T[0].Data := BuildOS2;
  SetTag(T[1], 'cmap'); T[1].Data := BuildCmap;
  SetTag(T[2], 'glyf'); T[2].Data := BuildGlyf(Loca, LocaFmt);
  SetTag(T[3], 'head'); T[3].Data := BuildHead(LocaFmt);
  SetTag(T[4], 'hhea'); T[4].Data := BuildHhea;
  SetTag(T[5], 'hmtx'); T[5].Data := BuildHmtx;
  SetTag(T[6], 'loca'); T[6].Data := Loca;
  SetTag(T[7], 'maxp'); T[7].Data := BuildMaxp;
  SetTag(T[8], 'name'); T[8].Data := BuildName;
  SetTag(T[9], 'post'); T[9].Data := BuildPost;

  // Compute per-table checksums and file offsets
  DataOff := 12 + NUM_TABLES * 16; // sfnt header(12) + table directory(10×16=160)
  for I := 0 to NUM_TABLES - 1 do
  begin
    T[I].Len    := Length(T[I].Data);
    T[I].CSum   := TableChecksum(T[I].Data);
    T[I].Offset := DataOff;
    DataOff     := DataOff + (T[I].Len + 3) and not 3; // round up to 4
  end;

  FileBuf := TBytesStream.Create;
  try
    // sfnt header (12 bytes)
    BW4(FileBuf, $00010000);   // sfVersion = TrueType
    BW2(FileBuf, NUM_TABLES);
    SR := 1; ES := 0;
    while SR * 2 <= NUM_TABLES do begin SR := SR * 2; Inc(ES); end;
    BW2(FileBuf, SR * 16);                        // searchRange
    BW2(FileBuf, ES);                             // entrySelector
    BW2(FileBuf, (NUM_TABLES - SR) * 16);         // rangeShift

    // Table directory: 16 bytes × 10
    for I := 0 to NUM_TABLES - 1 do
    begin
      FileBuf.Write(T[I].Tag, 4);
      BW4(FileBuf, T[I].CSum);
      BW4(FileBuf, T[I].Offset);
      BW4(FileBuf, T[I].Len);
    end;

    // Table data
    HeadAdjOff := -1;
    for I := 0 to NUM_TABLES - 1 do
    begin
      // Track where head.checkSumAdjustment will be (+8 from table start)
      if (T[I].Tag[0]='h') and (T[I].Tag[1]='e') and
         (T[I].Tag[2]='a') and (T[I].Tag[3]='d') then
        HeadAdjOff := FileBuf.Size + 8;
      if T[I].Len > 0 then
        FileBuf.Write(T[I].Data[0], T[I].Len);
      PadTo4(FileBuf);
    end;

    Result := StreamBytes(FileBuf);
  finally FileBuf.Free; end;

  // Patch head.checkSumAdjustment = 0xB1B0AFBA - sum_of_whole_file
  if HeadAdjOff >= 0 then
  begin
    FileSum := 0;
    J := (Length(Result) + 3) div 4;
    for I := 0 to J - 1 do
    begin
      V := 0;
      if I*4   < Length(Result) then V := V or (Cardinal(Result[I*4  ]) shl 24);
      if I*4+1 < Length(Result) then V := V or (Cardinal(Result[I*4+1]) shl 16);
      if I*4+2 < Length(Result) then V := V or (Cardinal(Result[I*4+2]) shl  8);
      if I*4+3 < Length(Result) then V := V or  Cardinal(Result[I*4+3]);
      Inc(FileSum, V);
    end;
    CSAdj := Cardinal($B1B0AFBA - FileSum);
    Result[HeadAdjOff  ] := (CSAdj shr 24) and $FF;
    Result[HeadAdjOff+1] := (CSAdj shr 16) and $FF;
    Result[HeadAdjOff+2] := (CSAdj shr  8) and $FF;
    Result[HeadAdjOff+3] :=  CSAdj and $FF;
  end;
end;

end.
