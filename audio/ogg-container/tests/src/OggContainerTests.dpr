program OggContainerTests;

{
  OggContainerTests.dpr - Exhaustive test suite for ogg-container

  Tests are organized in layers:

  Layer 1 — OggTypes (constants and flag helpers)
    T01: Capture pattern bytes
    T02: Header type flag combinations
    T03: TOggPage.IsBOS / IsEOS / IsContinued

  Layer 2 — CRC-32 (Ogg-specific, already in AudioCRC)
    T04: CRC-32 of "OggS" magic = known vector
    T05: CRC-32 of empty = 0
    T06: Incremental == one-shot

  Layer 3 — TOggPageWriter (page serialisation)
    T07: Single small packet → 1 page, correct structure
    T08: BOS flag on first page
    T09: EOS flag on last page
    T10: Sequence numbers increment per page
    T11: Packet exactly 255 bytes → terminal zero-byte segment
    T12: Packet exactly 510 bytes → segments [255,255,0]
    T13: Large packet spanning 2 pages
    T14: Multiple small packets on one page (auto-flush)
    T15: Granule position propagated correctly
    T16: CRC-32 correct in written page
    T17: Zero-length packet

  Layer 4 — TOggPageReader (page + packet round-trip)
    T18: Write 1 packet, read 1 packet: data identical
    T19: Write 3 packets, read 3 packets: all data identical
    T20: BOS / EOS flags preserved
    T21: GranulePos preserved per packet
    T22: Packet exactly 255 bytes round-trip
    T23: Packet exactly 510 bytes round-trip (zero-byte terminal segment)
    T24: Large multi-page packet round-trip
    T25: CRC corruption → orrCRCError
    T26: Truncated stream → orrNeedMore / orrEndOfStream
    T27: FindSync after junk prefix
    T28: Serial number filtering (skip other stream)
    T29: PacketIndex increments correctly
    T30: 1000 tiny packets round-trip (stress)

  Exit code 0 = all passed.

  License: CC0 1.0 Universal (Public Domain)
}

{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, Math,
  AudioTypes  in '..\..\..\audio-common\src\AudioTypes.pas',
  AudioCRC    in '..\..\..\audio-common\src\AudioCRC.pas',
  OggTypes    in '..\..\src\OggTypes.pas',
  OggPageReader in '..\..\src\OggPageReader.pas',
  OggPageWriter in '..\..\src\OggPageWriter.pas';

type
  TOggPacketArray = array of TOggPacket;

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------
var
  GFailed: Boolean = False;
  GTotal : Integer = 0;
  GPassed: Integer = 0;

procedure Check(Cond: Boolean; const Name, Detail: string);
begin
  Inc(GTotal);
  if Cond then
  begin
    Inc(GPassed);
    WriteLn('  PASS  ', Name);
  end
  else
  begin
    GFailed := True;
    if Detail <> '' then WriteLn('  FAIL  ', Name, '  [', Detail, ']')
    else WriteLn('  FAIL  ', Name);
  end;
end;

procedure Section(const T: string);
begin WriteLn; WriteLn('--- ', T, ' ---'); end;

// ---------------------------------------------------------------------------
// Layer 1: OggTypes
// ---------------------------------------------------------------------------
procedure TestOggTypes;
var
  Page: TOggPage;
begin
  Section('Layer 1 — OggTypes');

  // T01: Capture pattern bytes
  Check(OGG_CAPTURE_PATTERN[0] = $4F, 'T01a Capture[0] = O', '');
  Check(OGG_CAPTURE_PATTERN[1] = $67, 'T01b Capture[1] = g', '');
  Check(OGG_CAPTURE_PATTERN[2] = $67, 'T01c Capture[2] = g', '');
  Check(OGG_CAPTURE_PATTERN[3] = $53, 'T01d Capture[3] = S', '');
  Check(OGG_CAPTURE_DWORD = $5367674F, 'T01e Capture DWORD', Format('$%X', [OGG_CAPTURE_DWORD]));

  // T02: Header type flags
  Check(OGG_HEADER_CONTINUED = 1, 'T02a CONTINUED = 1', '');
  Check(OGG_HEADER_BOS = 2,       'T02b BOS = 2', '');
  Check(OGG_HEADER_EOS = 4,       'T02c EOS = 4', '');

  // T03: TOggPage flag helpers
  FillChar(Page, SizeOf(Page), 0);
  Page.Header.HeaderType := OGG_HEADER_BOS;
  Check(Page.IsBOS,       'T03a IsBOS when BOS set', '');
  Check(not Page.IsEOS,   'T03b not IsEOS when only BOS set', '');
  Check(not Page.IsContinued, 'T03c not IsContinued', '');

  Page.Header.HeaderType := OGG_HEADER_EOS or OGG_HEADER_CONTINUED;
  Check(not Page.IsBOS,   'T03d not IsBOS', '');
  Check(Page.IsEOS,       'T03e IsEOS set', '');
  Check(Page.IsContinued, 'T03f IsContinued set', '');
end;

// ---------------------------------------------------------------------------
// Layer 2: CRC-32 (Ogg variant)
// ---------------------------------------------------------------------------
procedure TestCRC32;
var
  D: TBytes;
  C: Cardinal;
begin
  Section('Layer 2 — Ogg CRC-32');

  // T04: Known vector — CRC-32 of "OggS"
  D := TBytes.Create($4F, $67, $67, $53);
  C := CRC32Ogg_Calc(@D[0], 4);
  Check(C = $5FB0A94F, 'T04 CRC32Ogg("OggS") = $5FB0A94F', Format('$%X', [C]));

  // T05: Empty
  C := CRC32Ogg_Calc(nil, 0);
  Check(C = 0, 'T05 CRC32Ogg(empty) = 0', Format('$%X', [C]));

  // T06: Incremental == one-shot
  D := TBytes.Create($11, $22, $33, $44, $55);
  var CInc := CRC32Ogg_Init;
  var I: Integer;
  for I := 0 to 4 do CInc := CRC32Ogg_Update(CInc, @D[I], 1);
  var COne := CRC32Ogg_Calc(@D[0], 5);
  Check(CInc = COne, 'T06 CRC32 incremental = one-shot', Format('$%X vs $%X', [CInc, COne]));
end;

// ---------------------------------------------------------------------------
// Helpers for Layer 3 & 4
// ---------------------------------------------------------------------------

// Build a packet of exactly N bytes with pattern: byte[i] = i mod 251
function MakePacket(N: Integer): TBytes;
var I: Integer;
begin
  SetLength(Result, N);
  for I := 0 to N - 1 do Result[I] := Byte(I mod 251);
end;

// Write packets and return the resulting stream bytes.
function WritePackets(
  const Packets   : array of TBytes;
  const Granules  : array of Int64;
  SerialNum       : Cardinal = $12345678
): TBytes;
var
  MS: TMemoryStream;
  W : TOggPageWriter;
  I : Integer;
begin
  MS := TMemoryStream.Create;
  try
    W := TOggPageWriter.Create(MS, SerialNum);
    try
      for I := 0 to High(Packets) do
        W.WritePacket(Packets[I], I = 0, I = High(Packets), Granules[I]);
      W.FlushPage;
    finally
      W.Free;
    end;
    SetLength(Result, MS.Size);
    if MS.Size > 0 then
    begin
      MS.Position := 0;
      MS.ReadBuffer(Result[0], MS.Size);
    end;
  finally
    MS.Free;
  end;
end;

// Read all packets from stream bytes.
function ReadAllPackets(const StreamData: TBytes): TOggPacketArray;
var
  MS  : TMemoryStream;
  R   : TOggPageReader;
  Pkt : TOggPacket;
  Res : TOggReadResult;
begin
  SetLength(Result, 0);
  MS := TMemoryStream.Create;
  try
    if Length(StreamData) > 0 then
      MS.WriteBuffer(StreamData[0], Length(StreamData));
    MS.Position := 0;
    R := TOggPageReader.Create(MS);
    try
      repeat
        Res := R.ReadPacket(Pkt);
        if Res = orrPacket then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := Pkt;
        end;
      until Res <> orrPacket;
    finally
      R.Free;
    end;
  finally
    MS.Free;
  end;
end;

// Check that two TBytes are identical.
function BytesEqual(const A, B: TBytes): Boolean;
var I: Integer;
begin
  if Length(A) <> Length(B) then Exit(False);
  for I := 0 to High(A) do
    if A[I] <> B[I] then Exit(False);
  Result := True;
end;

// ---------------------------------------------------------------------------
// Layer 3: TOggPageWriter
// ---------------------------------------------------------------------------
procedure TestWriter;
var
  Pkt1    : TBytes;
  SD      : TBytes;
  Packets : TOggPacketArray;
  MS      : TMemoryStream;
  W       : TOggPageWriter;
begin
  Section('Layer 3 — TOggPageWriter');

  // T07: Single small packet → 1 page, structure check
  Pkt1 := MakePacket(100);
  SD   := WritePackets([Pkt1], [Int64(100)]);

  // The page must start with 'OggS'
  Check(Length(SD) >= 4, 'T07a Page has data', '');
  if Length(SD) >= 4 then
    Check((SD[0]=$4F)and(SD[1]=$67)and(SD[2]=$67)and(SD[3]=$53),
      'T07b Starts with OggS', '');

  // Version = 0 at offset 4
  Check(SD[4] = 0, 'T07c Version = 0', IntToStr(SD[4]));

  // T08: BOS flag on first page (offset 5, bit 1)
  Check((SD[5] and OGG_HEADER_BOS) <> 0, 'T08 BOS flag set', Format('$%X', [SD[5]]));

  // T09: EOS flag set (we wrote one packet as both BOS and EOS)
  Check((SD[5] and OGG_HEADER_EOS) <> 0, 'T09 EOS flag set', Format('$%X', [SD[5]]));

  // T10: Sequence number = 0 for first page (offset 18-21, LE)
  var Seq := Cardinal(SD[18]) or (Cardinal(SD[19]) shl 8) or
             (Cardinal(SD[20]) shl 16) or (Cardinal(SD[21]) shl 24);
  Check(Seq = 0, 'T10 SeqNum = 0 on first page', IntToStr(Seq));

  // T11: Packet exactly 255 bytes → segment table [255, 0]
  // Write 255-byte packet
  Pkt1 := MakePacket(255);
  MS := TMemoryStream.Create;
  try
    W := TOggPageWriter.Create(MS, 1);
    W.WritePacket(Pkt1, True, True, 255);
    W.FlushPage;
    W.Free;
    // Read segment table: at offset 27 we have the segments
    MS.Position := 0;
    var B: TBytes;
    SetLength(B, MS.Size);
    MS.ReadBuffer(B[0], MS.Size);
    // Find first page
    var NSeg := B[26];
    // We expect 2 segments in segment table: [255, 0]
    Check(NSeg >= 2, 'T11 NSeg >= 2 for 255-byte packet', IntToStr(NSeg));
    if NSeg >= 2 then
    begin
      Check(B[27] = 255, 'T11 Seg[0] = 255', IntToStr(B[27]));
      Check(B[28] = 0,   'T11 Seg[1] = 0 (terminal)', IntToStr(B[28]));
    end;
  finally
    MS.Free;
  end;

  // T12: Packet exactly 510 bytes → segments include [255,255,0]
  Pkt1 := MakePacket(510);
  MS := TMemoryStream.Create;
  try
    W := TOggPageWriter.Create(MS, 1);
    W.WritePacket(Pkt1, True, True, 510);
    W.FlushPage;
    W.Free;
    MS.Position := 0;
    var B: TBytes;
    SetLength(B, MS.Size);
    MS.ReadBuffer(B[0], MS.Size);
    var NSeg := B[26];
    Check(NSeg >= 3, 'T12 NSeg >= 3 for 510-byte packet', IntToStr(NSeg));
    if NSeg >= 3 then
    begin
      Check(B[27] = 255, 'T12 Seg[0] = 255', IntToStr(B[27]));
      Check(B[28] = 255, 'T12 Seg[1] = 255', IntToStr(B[28]));
      Check(B[29] = 0,   'T12 Seg[2] = 0 (terminal)', IntToStr(B[29]));
    end;
  finally
    MS.Free;
  end;

  // T13: Large packet (70000 bytes) spanning 2+ pages
  var LargePkt := MakePacket(70000);
  Packets := ReadAllPackets(WritePackets([LargePkt], [Int64(70000)]));
  Check(Length(Packets) = 1, 'T13 Large packet → 1 logical packet', IntToStr(Length(Packets)));
  if Length(Packets) = 1 then
    Check(BytesEqual(LargePkt, Packets[0].Data), 'T13 Large packet data intact', '');

  // T14: Multiple small packets on one page
  var P1 := MakePacket(10);
  var P2 := MakePacket(20);
  var P3 := MakePacket(30);
  Packets := ReadAllPackets(WritePackets([P1, P2, P3], [Int64(10), Int64(30), Int64(60)]));
  Check(Length(Packets) = 3, 'T14 3 packets read back', IntToStr(Length(Packets)));
  if Length(Packets) = 3 then
  begin
    Check(BytesEqual(P1, Packets[0].Data), 'T14 Packet 0 data', '');
    Check(BytesEqual(P2, Packets[1].Data), 'T14 Packet 1 data', '');
    Check(BytesEqual(P3, Packets[2].Data), 'T14 Packet 2 data', '');
  end;

  // T15: Granule position
  var PA := MakePacket(50);
  var PB := MakePacket(50);
  Packets := ReadAllPackets(WritePackets([PA, PB], [Int64(1000), Int64(2000)]));
  if Length(Packets) = 2 then
    Check(Packets[1].GranulePos = 2000, 'T15 GranulePos of last packet = 2000',
      IntToStr(Packets[1].GranulePos));

  // T16: CRC-32 correct in written page
  // Re-read page and verify CRC (the reader already verifies CRC; use reader)
  var Px := MakePacket(200);
  MS := TMemoryStream.Create;
  try
    W := TOggPageWriter.Create(MS, 99);
    W.WritePacket(Px, True, True, 200);
    W.FlushPage;
    W.Free;

    MS.Position := 0;
    var R := TOggPageReader.Create(MS);
    var Page: TOggPage;
    var RR := R.ReadPage(Page);
    Check(RR = orrPage, 'T16 CRC correct → orrPage', '');
    R.Free;
  finally
    MS.Free;
  end;

  // T17: Zero-length packet
  var PZ: TBytes := nil;  // empty
  Packets := ReadAllPackets(WritePackets([PZ], [Int64(0)]));
  Check(Length(Packets) = 1, 'T17 Zero-length packet → 1 packet', IntToStr(Length(Packets)));
  if Length(Packets) = 1 then
    Check(Packets[0].Length = 0, 'T17 Decoded length = 0', IntToStr(Packets[0].Length));
end;

// ---------------------------------------------------------------------------
// Layer 4: Round-trip tests
// ---------------------------------------------------------------------------
procedure TestRoundTrip;
var
  Packets: TOggPacketArray;
  I      : Integer;
begin
  Section('Layer 4 — Round-trip (writer → reader)');

  // T18: Single packet
  var P := MakePacket(300);
  Packets := ReadAllPackets(WritePackets([P], [Int64(300)]));
  Check(Length(Packets) = 1, 'T18 1 packet round-trip', IntToStr(Length(Packets)));
  if Length(Packets) = 1 then
    Check(BytesEqual(P, Packets[0].Data), 'T18 Data identical', '');

  // T19: 3 packets
  var PA := MakePacket(100); var PB := MakePacket(200); var PC := MakePacket(150);
  Packets := ReadAllPackets(WritePackets([PA, PB, PC], [Int64(100), Int64(300), Int64(450)]));
  Check(Length(Packets) = 3, 'T19 3 packets', IntToStr(Length(Packets)));
  if Length(Packets) = 3 then
  begin
    Check(BytesEqual(PA, Packets[0].Data), 'T19 Pkt0 data', '');
    Check(BytesEqual(PB, Packets[1].Data), 'T19 Pkt1 data', '');
    Check(BytesEqual(PC, Packets[2].Data), 'T19 Pkt2 data', '');
  end;

  // T20: BOS / EOS preserved
  Check((Length(Packets) = 3) and Packets[0].IsBOS, 'T20a First packet IsBOS', '');
  Check((Length(Packets) = 3) and Packets[2].IsEOS, 'T20b Last packet IsEOS', '');
  Check((Length(Packets) = 3) and not Packets[1].IsBOS, 'T20c Middle packet not IsBOS', '');

  // T21: GranulePos
  var Pkts21 := ReadAllPackets(WritePackets([PA, PB], [Int64(44100), Int64(88200)]));
  if Length(Pkts21) = 2 then
  begin
    Check(Pkts21[0].GranulePos = 44100, 'T21a GranulePos[0] = 44100',
      IntToStr(Pkts21[0].GranulePos));
    Check(Pkts21[1].GranulePos = 88200, 'T21b GranulePos[1] = 88200',
      IntToStr(Pkts21[1].GranulePos));
  end;

  // T22: Exactly 255 bytes
  var P255 := MakePacket(255);
  Packets := ReadAllPackets(WritePackets([P255], [Int64(255)]));
  Check(Length(Packets) = 1, 'T22 255-byte packet round-trip', IntToStr(Length(Packets)));
  if Length(Packets) = 1 then
  begin
    Check(Packets[0].Length = 255, 'T22 Length = 255', IntToStr(Packets[0].Length));
    Check(BytesEqual(P255, Packets[0].Data), 'T22 Data identical', '');
  end;

  // T23: Exactly 510 bytes
  var P510 := MakePacket(510);
  Packets := ReadAllPackets(WritePackets([P510], [Int64(510)]));
  Check(Length(Packets) = 1, 'T23 510-byte packet round-trip', IntToStr(Length(Packets)));
  if Length(Packets) = 1 then
    Check(BytesEqual(P510, Packets[0].Data), 'T23 Data identical', '');

  // T24: Large multi-page packet (70000 bytes)
  var PLarge := MakePacket(70000);
  Packets := ReadAllPackets(WritePackets([PLarge], [Int64(70000)]));
  Check(Length(Packets) = 1, 'T24 70000-byte packet round-trip', IntToStr(Length(Packets)));
  if Length(Packets) = 1 then
    Check(BytesEqual(PLarge, Packets[0].Data), 'T24 Large data identical', '');

  // T25: CRC corruption → orrCRCError
  var GoodSD := WritePackets([MakePacket(50)], [Int64(50)]);
  // Corrupt a byte in the page data area (offset 27+nseg+10)
  var CorruptSD := Copy(GoodSD, 0, Length(GoodSD));
  if Length(CorruptSD) > 50 then
    CorruptSD[50] := CorruptSD[50] xor $FF;
  var MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(CorruptSD[0], Length(CorruptSD));
    MS.Position := 0;
    var R := TOggPageReader.Create(MS);
    var Page: TOggPage;
    var RR := R.ReadPage(Page);
    Check(RR = orrCRCError, 'T25 CRC corruption → orrCRCError', '');
    R.Free;
  finally
    MS.Free;
  end;

  // T26: Truncated stream
  var TruncSD := Copy(GoodSD, 0, Length(GoodSD) div 2);
  MS := TMemoryStream.Create;
  try
    if Length(TruncSD) > 0 then MS.WriteBuffer(TruncSD[0], Length(TruncSD));
    MS.Position := 0;
    var R := TOggPageReader.Create(MS);
    var Page: TOggPage;
    var RR := R.ReadPage(Page);
    Check(RR in [orrNeedMore, orrEndOfStream, orrSyncLost],
      'T26 Truncated stream returns error', '');
    R.Free;
  finally
    MS.Free;
  end;

  // T27: FindSync after junk prefix
  var GoodPage := WritePackets([MakePacket(10)], [Int64(10)]);
  var Junk: TBytes;
  SetLength(Junk, 20);
  FillChar(Junk[0], 20, $AA);
  var JunkSD: TBytes;
  SetLength(JunkSD, 20 + Length(GoodPage));
  Move(Junk[0], JunkSD[0], 20);
  Move(GoodPage[0], JunkSD[20], Length(GoodPage));
  MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(JunkSD[0], Length(JunkSD));
    MS.Position := 0;
    var R := TOggPageReader.Create(MS);
    var Found := R.FindSync;
    Check(Found, 'T27 FindSync finds OggS after junk', '');
    if Found then
    begin
      var Page: TOggPage;
      var RR := R.ReadPage(Page);
      Check(RR = orrPage, 'T27 Page reads correctly after FindSync', '');
    end;
    R.Free;
  finally
    MS.Free;
  end;

  // T28: Serial number filtering
  MS := TMemoryStream.Create;
  try
    var W := TOggPageWriter.Create(MS, $AABB, False);
    W.WritePacket(MakePacket(10), True, False, 10);
    W.FlushPage;
    W.Free;
    var W2 := TOggPageWriter.Create(MS, $CCDD, False);
    W2.WritePacket(MakePacket(20), True, True, 20);
    W2.FlushPage;
    W2.Free;

    MS.Position := 0;
    var R := TOggPageReader.Create(MS);
    R.FilterSerial    := True;
    R.FilterSerialNum := $CCDD;
    var Pkt: TOggPacket;
    var RR := R.ReadPacket(Pkt);
    Check(RR = orrPacket, 'T28 Filter: packet found for $CCDD', '');
    if RR = orrPacket then
      Check(Pkt.SerialNumber = $CCDD, 'T28 Serial = $CCDD',
        Format('$%X', [Pkt.SerialNumber]));
    R.Free;
  finally
    MS.Free;
  end;

  // T29: PacketIndex increments correctly
  var P1 := MakePacket(10); var P2 := MakePacket(10); var P3 := MakePacket(10);
  Packets := ReadAllPackets(WritePackets([P1, P2, P3], [Int64(1), Int64(2), Int64(3)]));
  if Length(Packets) = 3 then
  begin
    Check(Packets[0].PacketIndex = 0, 'T29 PacketIndex[0] = 0', IntToStr(Packets[0].PacketIndex));
    Check(Packets[1].PacketIndex = 1, 'T29 PacketIndex[1] = 1', IntToStr(Packets[1].PacketIndex));
    Check(Packets[2].PacketIndex = 2, 'T29 PacketIndex[2] = 2', IntToStr(Packets[2].PacketIndex));
  end;

  // T30: Stress — 1000 tiny packets
  var AllPkts : array of TBytes;
  var AllGran : array of Int64;
  SetLength(AllPkts, 1000);
  SetLength(AllGran, 1000);
  for I := 0 to 999 do
  begin
    AllPkts[I] := MakePacket(I mod 50 + 1);
    AllGran[I] := I;
  end;
  Packets := ReadAllPackets(WritePackets(AllPkts, AllGran));
  Check(Length(Packets) = 1000, 'T30 Stress: 1000 packets round-trip',
    IntToStr(Length(Packets)));
  var AllOK := True;
  for I := 0 to Min(999, High(Packets)) do
    if not BytesEqual(AllPkts[I], Packets[I].Data) then begin AllOK := False; Break; end;
  Check(AllOK, 'T30 Stress: all 1000 packet data identical', '');
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
begin
  WriteLn('========================================');
  WriteLn(' ogg-container exhaustive tests');
  WriteLn('========================================');

  TestOggTypes;
  TestCRC32;
  TestWriter;
  TestRoundTrip;

  WriteLn;
  WriteLn(Format('Results: %d / %d passed', [GPassed, GTotal]));
  if GFailed then
  begin
    WriteLn('*** SOME TESTS FAILED ***');
    Halt(1);
  end
  else
    WriteLn('All tests passed.');
end.
