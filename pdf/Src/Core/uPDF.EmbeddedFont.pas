unit uPDF.EmbeddedFont;

{$SCOPEDENUMS ON}

// ============================================================================
// TTTFEmbeddedFont — Phase 3 of TTF/OTF font embedding
//
// Builds the 5 PDF objects required to embed a TTF subset in a PDF file:
//   1. Type0 font dict     — /Subtype /Type0, /Encoding /Identity-H
//   2. CIDFont dict        — /Subtype /CIDFontType2, /W array, /CIDToGIDMap /Identity
//   3. FontDescriptor dict — metrics, /Flags, /FontFile2 reference
//   4. FontFile2 stream    — FlateDecode-compressed subset TTF bytes
//   5. ToUnicode CMap      — FlateDecode-compressed PostScript CMap for copy/paste
//
// Text is encoded as big-endian 2-byte glyph IDs (Identity-H):
//   EncodeTextHex('Hello') → '<00010002030405>' (GIDs for H,e,l,l,o in the subset)
//
// Usage:
//   Sub  := TTTFSubsetter.Create(Parser, GlyphIDs);
//   Font := TTTFEmbeddedFont.Create(Parser, Sub);
//   try
//     ObjBytes := Font.BuildObjectStream(FirstObjNum);  // inject into PDF file
//     HexStr   := Font.EncodeTextHex('Hello');          // for Tj content operator
//     Width    := Font.MeasureText('Hello', 12);        // in PDF points
//   finally Font.Free; end;
// ============================================================================

interface

uses
  System.SysUtils, System.Classes, System.ZLib, System.Math,
  System.Generics.Collections, System.Generics.Defaults,
  uPDF.Errors, uPDF.TTFParser, uPDF.TTFSubset;

type
  TTTFEmbeddedFont = class
  private
    FPSName      : string;
    FFamilyName  : string;
    FUPM         : Word;
    FGlyphCount  : Integer;
    FFlags       : Integer;
    FStemV       : Integer;
    FMetrics     : TTTFMetrics;
    FWidthsPDF   : TArray<Integer>;            // PDF-unit width (×1000/UPM) per new GlyphID
    FSubsetBytes : TBytes;                     // raw (uncompressed) subset TTF
    FUniToNewGID : TDictionary<Cardinal, Word>;// Unicode CP → new GlyphID
    FGIDToUni    : TDictionary<Word, Cardinal>;// new GlyphID → primary Unicode CP

    function  PDFUnits(ADesignUnits: Integer): Integer; inline;
    function  FmtAngle(AValue: Single): string;
    function  CompressBytes(const AData: TBytes): TBytes;
    function  BuildToUnicodeCMapBytes: TBytes;
    procedure WriteText(S: TStream; const AText: string);
    procedure WriteRaw (S: TStream; const AData: TBytes);
    function  NewGIDFor(AUnicode: Cardinal): Word;
  public
    constructor Create(AParser: TTTFParser; ASubsetter: TTTFSubsetter);
    destructor  Destroy; override;

    { Serialize all 5 font objects as a raw PDF byte sequence.
      AFirstObjNum is assigned to the Type0 dict; the next 4 numbers follow
      sequentially (+1=CIDFont, +2=FontDescriptor, +3=FontFile2, +4=ToUnicode). }
    function BuildObjectStream(AFirstObjNum: Integer): TBytes;

    { Width of AText in PDF points at AFontSize (same unit as standard fonts). }
    function MeasureText(const AText: string; AFontSize: Single): Single;

    { Encode AText as a PDF hex string of big-endian 2-byte glyph IDs.
      Example: 'A' with newGID=1 → '<0001>' }
    function EncodeTextHex(const AText: string): string;

    { Encode AText as raw 2-byte-per-char TBytes (for PDF string literal). }
    function EncodeTextBytes(const AText: string): TBytes;

    { Uncompressed ToUnicode CMap text (for inspection / testing). }
    function BuildToUnicodeCMapText: string;

    { Always 5 — Type0 / CIDFont / FontDescriptor / FontFile2 / ToUnicode. }
    class function ObjectCount: Integer;

    { Advance width in PDF units (×1000/UPM) for new glyph index AIndex. }
    function GlyphWidthPDF(AIndex: Integer): Integer;

    property PSName        : string      read FPSName;
    property FamilyName    : string      read FFamilyName;
    property GlyphCount    : Integer     read FGlyphCount;
    property SubsetTTFBytes: TBytes      read FSubsetBytes; // raw (uncompressed) TTF bytes
    property Flags         : Integer     read FFlags;       // PDF FontDescriptor Flags
    property StemV         : Integer     read FStemV;       // stem thickness estimate
    property Metrics       : TTTFMetrics read FMetrics;     // design-unit font metrics
  end;

implementation

{ ---- Constructor / Destructor ---------------------------------------------- }

constructor TTTFEmbeddedFont.Create(AParser: TTTFParser; ASubsetter: TTTFSubsetter);
var
  Entry  : TPair<Cardinal, Word>;
  NewGID : Word;
  I      : Integer;
begin
  inherited Create;
  FPSName     := AParser.PSName;
  FFamilyName := AParser.FamilyName;
  FUPM        := AParser.Metrics.UnitsPerEm;
  FMetrics    := AParser.Metrics;
  FGlyphCount := ASubsetter.GlyphCount;
  FSubsetBytes := ASubsetter.Build;

  // PDF font descriptor flags (bit positions per PDF spec)
  FFlags := 32;  // Bit 6 = Nonsymbolic (standard Unicode/Latin font)
  if FMetrics.IsFixedPitch then FFlags := FFlags or   1;  // bit 1
  if FMetrics.IsItalic     then FFlags := FFlags or  64;  // bit 7
  if FMetrics.IsBold       then FFlags := FFlags or 262144; // bit 19 ForceBold

  FStemV := IfThen(FMetrics.IsBold, 150, 80);

  // PDF-unit advance widths for each new glyph ID
  SetLength(FWidthsPDF, FGlyphCount);
  for I := 0 to FGlyphCount - 1 do
  begin
    var OldGID := ASubsetter.OldGlyphID(Word(I));
    FWidthsPDF[I] := PDFUnits(Integer(AParser.GlyphAdvanceWidth(OldGID)));
  end;

  // Unicode ↔ new-GID tables (for MeasureText, EncodeText, ToUnicode CMap)
  FUniToNewGID := TDictionary<Cardinal, Word>.Create;
  FGIDToUni    := TDictionary<Word, Cardinal>.Create;

  for Entry in AParser.CmapEntries do
  begin
    NewGID := ASubsetter.MapGlyph(Entry.Value);
    if NewGID = 0 then Continue; // not in subset, or maps to notdef — skip
    FUniToNewGID.AddOrSetValue(Entry.Key, NewGID);
    if not FGIDToUni.ContainsKey(NewGID) then
      FGIDToUni.Add(NewGID, Entry.Key); // lowest codepoint wins
  end;
end;

destructor TTTFEmbeddedFont.Destroy;
begin
  FUniToNewGID.Free;
  FGIDToUni.Free;
  inherited;
end;

{ ---- Helpers --------------------------------------------------------------- }

function TTTFEmbeddedFont.PDFUnits(ADesignUnits: Integer): Integer;
begin
  if FUPM = 0 then Result := ADesignUnits
  else Result := Round(ADesignUnits * 1000.0 / FUPM);
end;

function TTTFEmbeddedFont.FmtAngle(AValue: Single): string;
begin
  if AValue = 0.0 then Result := '0'
  else Result := FloatToStrF(AValue, ffGeneral, 7, 2, TFormatSettings.Invariant);
end;

function TTTFEmbeddedFont.CompressBytes(const AData: TBytes): TBytes;
var CS: TCompressionStream; MS: TMemoryStream;
begin
  Result := nil;
  if Length(AData) = 0 then Exit;
  MS := TMemoryStream.Create;
  try
    CS := TCompressionStream.Create(clDefault, MS);
    try
      CS.Write(AData[0], Length(AData));
    finally CS.Free; end;  // free flushes remaining compressed data
    SetLength(Result, MS.Size);
    MS.Position := 0;
    if MS.Size > 0 then MS.Read(Result[0], MS.Size);
  finally MS.Free; end;
end;

procedure TTTFEmbeddedFont.WriteText(S: TStream; const AText: string);
var B: TBytes;
begin
  B := TEncoding.ASCII.GetBytes(AText);
  if Length(B) > 0 then S.Write(B[0], Length(B));
end;

procedure TTTFEmbeddedFont.WriteRaw(S: TStream; const AData: TBytes);
begin
  if Length(AData) > 0 then S.Write(AData[0], Length(AData));
end;

function TTTFEmbeddedFont.NewGIDFor(AUnicode: Cardinal): Word;
begin
  if not FUniToNewGID.TryGetValue(AUnicode, Result) then Result := 0;
end;

class function TTTFEmbeddedFont.ObjectCount: Integer;
begin Result := 5; end;

function TTTFEmbeddedFont.GlyphWidthPDF(AIndex: Integer): Integer;
begin
  if (AIndex >= 0) and (AIndex < Length(FWidthsPDF)) then
    Result := FWidthsPDF[AIndex]
  else
    Result := 0;
end;

{ ---- ToUnicode CMap -------------------------------------------------------- }

function TTTFEmbeddedFont.BuildToUnicodeCMapText: string;
type
  TGIDPair = record GID: Word; CP: Cardinal; end;
var
  Pairs: TList<TGIDPair>;
  P: TGIDPair; E: TPair<Word, Cardinal>;
  SB: TStringBuilder;
  I, ChunkSize: Integer;
begin
  // Collect (newGID, unicode) for all non-notdef mapped glyphs, sorted by GID
  Pairs := TList<TGIDPair>.Create;
  try
    for E in FGIDToUni do
      if E.Key > 0 then  // skip notdef
      begin P.GID := E.Key; P.CP := E.Value; Pairs.Add(P); end;

    Pairs.Sort(TComparer<TGIDPair>.Construct(
      function(const A, B: TGIDPair): Integer
      begin Result := Integer(A.GID) - Integer(B.GID); end));

    SB := TStringBuilder.Create;
    try
      SB.AppendLine('/CIDInit /ProcSet findresource begin');
      SB.AppendLine('12 dict begin');
      SB.AppendLine('begincmap');
      SB.AppendLine('/CIDSystemInfo');
      SB.AppendLine('<< /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def');
      SB.AppendLine('/CMapName /Adobe-Identity-UCS def');
      SB.AppendLine('/CMapType 2 def');
      SB.AppendLine('1 begincodespacerange');
      SB.AppendLine('<0000> <FFFF>');
      SB.AppendLine('endcodespacerange');

      I := 0;
      while I < Pairs.Count do
      begin
        ChunkSize := Min(100, Pairs.Count - I);
        SB.AppendLine(IntToStr(ChunkSize) + ' beginbfchar');
        for var J := I to I + ChunkSize - 1 do
        begin
          P := Pairs[J];
          if P.CP <= $FFFF then
            SB.AppendLine('<' + IntToHex(P.GID, 4) + '> <' + IntToHex(P.CP, 4) + '>')
          else
          begin
            // SMP: encode as UTF-16BE surrogate pair
            var Base   := P.CP - $10000;
            var SurrHi := $D800 + (Base shr 10);
            var SurrLo := $DC00 + (Base and $3FF);
            SB.AppendLine('<' + IntToHex(P.GID, 4) + '> <' +
              IntToHex(SurrHi, 4) + IntToHex(SurrLo, 4) + '>');
          end;
        end;
        SB.AppendLine('endbfchar');
        Inc(I, ChunkSize);
      end;

      SB.AppendLine('endcmap');
      SB.AppendLine('CMapName currentdict /CMap defineresource pop');
      SB.AppendLine('end');
      SB.AppendLine('end');
      Result := SB.ToString;
    finally SB.Free; end;
  finally Pairs.Free; end;
end;

function TTTFEmbeddedFont.BuildToUnicodeCMapBytes: TBytes;
begin
  Result := TEncoding.ASCII.GetBytes(BuildToUnicodeCMapText);
end;

{ ---- Public text utilities ------------------------------------------------- }

function TTTFEmbeddedFont.MeasureText(const AText: string; AFontSize: Single): Single;
var I: Integer; W: Integer;
begin
  Result := 0;
  if (FUPM = 0) or (Length(AText) = 0) then Exit;
  for I := 1 to Length(AText) do
  begin
    var GID := NewGIDFor(Cardinal(Ord(AText[I])));
    W := FWidthsPDF[Min(Integer(GID), FGlyphCount - 1)];
    Result := Result + W * AFontSize / 1000.0;
  end;
end;

function TTTFEmbeddedFont.EncodeTextHex(const AText: string): string;
var SB: TStringBuilder; I: Integer;
begin
  SB := TStringBuilder.Create;
  try
    SB.Append('<');
    for I := 1 to Length(AText) do
      SB.Append(IntToHex(NewGIDFor(Cardinal(Ord(AText[I]))), 4));
    SB.Append('>');
    Result := SB.ToString;
  finally SB.Free; end;
end;

function TTTFEmbeddedFont.EncodeTextBytes(const AText: string): TBytes;
var I: Integer; GID: Word;
begin
  SetLength(Result, Length(AText) * 2);
  for I := 1 to Length(AText) do
  begin
    GID := NewGIDFor(Cardinal(Ord(AText[I])));
    Result[(I - 1) * 2    ] := GID shr 8;
    Result[(I - 1) * 2 + 1] := GID and $FF;
  end;
end;

{ ---- BuildObjectStream ----------------------------------------------------- }

function TTTFEmbeddedFont.BuildObjectStream(AFirstObjNum: Integer): TBytes;
var
  N0, N1, N2, N3, N4: Integer;  // object numbers for the 5 objects
  WArr  : TStringBuilder;
  I     : Integer;
  BBox  : string;
  S     : TMemoryStream;
  FF    : TBytes;  // compressed FontFile2 bytes
  TU    : TBytes;  // compressed ToUnicode bytes
begin
  N0 := AFirstObjNum;      // Type0 font dict
  N1 := AFirstObjNum + 1;  // CIDFont dict
  N2 := AFirstObjNum + 2;  // FontDescriptor dict
  N3 := AFirstObjNum + 3;  // FontFile2 stream
  N4 := AFirstObjNum + 4;  // ToUnicode CMap stream

  // /W array: [0 [w0 w1 ... wN-1]]
  WArr := TStringBuilder.Create;
  try
    WArr.Append('[0 [');
    for I := 0 to FGlyphCount - 1 do
    begin
      if I > 0 then WArr.Append(' ');
      WArr.Append(FWidthsPDF[I]);
    end;
    WArr.Append(']]');

    // /FontBBox in PDF units
    BBox := Format('[%d %d %d %d]', [
      PDFUnits(FMetrics.XMin), PDFUnits(FMetrics.YMin),
      PDFUnits(FMetrics.XMax), PDFUnits(FMetrics.YMax)]);

    // Compress both streams
    FF := CompressBytes(FSubsetBytes);
    TU := CompressBytes(BuildToUnicodeCMapBytes);

    S := TMemoryStream.Create;
    try
      // ---- Object 1: Type0 font dict ----
      WriteText(S, Format(
        '%d 0 obj'#10 +
        '<< /Type /Font /Subtype /Type0 /BaseFont /%s'#10 +
        '   /Encoding /Identity-H'#10 +
        '   /DescendantFonts [%d 0 R]'#10 +
        '   /ToUnicode %d 0 R'#10 +
        '>>'#10'endobj'#10,
        [N0, FPSName, N1, N4]));

      // ---- Object 2: CIDFont dict ----
      WriteText(S, Format(
        '%d 0 obj'#10 +
        '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /%s'#10 +
        '   /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>'#10 +
        '   /DW %d'#10 +
        '   /W %s'#10 +
        '   /FontDescriptor %d 0 R'#10 +
        '   /CIDToGIDMap /Identity'#10 +
        '>>'#10'endobj'#10,
        [N1, FPSName, FWidthsPDF[0], WArr.ToString, N2]));

      // ---- Object 3: FontDescriptor dict ----
      WriteText(S, Format(
        '%d 0 obj'#10 +
        '<< /Type /FontDescriptor /FontName /%s'#10 +
        '   /Flags %d /FontBBox %s'#10 +
        '   /ItalicAngle %s /Ascent %d /Descent %d'#10 +
        '   /CapHeight %d /StemV %d'#10 +
        '   /FontFile2 %d 0 R'#10 +
        '>>'#10'endobj'#10,
        [N2, FPSName,
         FFlags, BBox,
         FmtAngle(FMetrics.ItalicAngle),
         PDFUnits(FMetrics.Ascender), PDFUnits(FMetrics.Descender),
         PDFUnits(FMetrics.CapHeight), FStemV,
         N3]));

      // ---- Object 4: FontFile2 stream ----
      WriteText(S, Format(
        '%d 0 obj'#10 +
        '<< /Length %d /Filter /FlateDecode >>'#10 +
        'stream'#10,
        [N3, Length(FF)]));
      WriteRaw(S, FF);
      WriteText(S, #10'endstream'#10'endobj'#10);

      // ---- Object 5: ToUnicode CMap stream ----
      WriteText(S, Format(
        '%d 0 obj'#10 +
        '<< /Length %d /Filter /FlateDecode >>'#10 +
        'stream'#10,
        [N4, Length(TU)]));
      WriteRaw(S, TU);
      WriteText(S, #10'endstream'#10'endobj'#10);

      SetLength(Result, S.Size);
      S.Position := 0;
      if S.Size > 0 then S.Read(Result[0], S.Size);
    finally S.Free; end;
  finally WArr.Free; end;
end;

end.
