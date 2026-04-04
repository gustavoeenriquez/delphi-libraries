unit OggPageReader;

{
  OggPageReader.pas - Ogg page and packet reader

  Reads Ogg pages from a TStream and reassembles logical packets.

  Two-level API:
    Low level  — ReadPage: reads exactly one Ogg page, verifies CRC
    High level — ReadPacket: accumulates segments across pages until a
                 complete logical packet is available

  Multi-stream support:
    By default the reader accepts pages from any logical bitstream.
    Set FilterSerial = True and FilterSerialNumber to restrict to one stream.

  Sync recovery:
    If the stream is corrupt or we are re-synchronising after a seek,
    call FindSync to scan forward for the next "OggS" capture pattern.

  Usage:
    var R: TOggPageReader;
    R := TOggPageReader.Create(Stream);
    try
      while R.ReadPacket(Pkt) = orrPacket do
        ProcessPacket(Pkt);
    finally
      R.Free;
    end;

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Classes,
  AudioCRC,
  OggTypes;

type
  TOggPageReader = class
  private
    FStream           : TStream;
    FOwnsStream       : Boolean;

    // Packet reassembly state
    FPartialPacket    : TBytes;     // accumulated data for current in-progress packet
    FPartialLength    : Integer;
    FPartialBOS       : Boolean;
    FPartialSerial    : Cardinal;
    FPartialGranule   : Int64;
    FInPacket         : Boolean;    // True when a packet is being accumulated
    FPacketIndex      : Integer;    // count of packets delivered so far

    FReachedEOS       : Boolean;
    FLastPage         : TOggPage;   // the most recently read page
    FPageSegsRemaining: Integer;    // segments from FLastPage not yet consumed
    FPageSegIdx       : Integer;    // next segment index in FLastPage.Header.SegmentTable
    FPageDataOff      : Integer;    // byte offset into FLastPage.Data

    // Serial number filtering
    FFilterSerial     : Boolean;
    FFilterSerialNum  : Cardinal;

    function ReadPageInternal(out Page: TOggPage): TOggReadResult;

  public
    constructor Create(AStream: TStream; OwnsStream: Boolean = False);
    destructor  Destroy; override;

    // Read exactly one Ogg page from the stream.
    // Returns orrPage on success, orrCRCError, orrSyncLost, orrEndOfStream, orrNeedMore.
    function ReadPage(out Page: TOggPage): TOggReadResult;

    // Scan forward in the stream for the "OggS" capture pattern.
    // Useful for sync recovery after corruption or after a seek.
    // Returns True if sync is found and the stream is positioned at the capture pattern.
    function FindSync: Boolean;

    // Read pages until a complete packet is ready.
    // Returns orrPacket with Pkt filled, or orrEndOfStream / orrCRCError / orrNeedMore.
    function ReadPacket(out Pkt: TOggPacket): TOggReadResult;

    property FilterSerial    : Boolean  read FFilterSerial   write FFilterSerial;
    property FilterSerialNum : Cardinal read FFilterSerialNum write FFilterSerialNum;
    property ReachedEOS      : Boolean  read FReachedEOS;
    property PacketIndex     : Integer  read FPacketIndex;
  end;

implementation

// ---------------------------------------------------------------------------
// Helpers: little-endian reads from raw bytes
// ---------------------------------------------------------------------------

function ReadLE32(P: PByte): Cardinal; inline;
begin
  Result := Cardinal(P^) or (Cardinal((P+1)^) shl 8) or
            (Cardinal((P+2)^) shl 16) or (Cardinal((P+3)^) shl 24);
end;

function ReadLE64(P: PByte): Int64; inline;
begin
  Result := Int64(ReadLE32(P)) or (Int64(ReadLE32(P+4)) shl 32);
end;

// ---------------------------------------------------------------------------
// Constructor / Destructor
// ---------------------------------------------------------------------------

constructor TOggPageReader.Create(AStream: TStream; OwnsStream: Boolean);
begin
  inherited Create;
  FStream       := AStream;
  FOwnsStream   := OwnsStream;
  FInPacket     := False;
  FPartialLength:= 0;
  FPacketIndex  := 0;
  FReachedEOS   := False;
  FPageSegsRemaining := 0;
  FPageSegIdx   := 0;
  FPageDataOff  := 0;
  FFilterSerial := False;
  FFilterSerialNum := 0;
  SetLength(FPartialPacket, 4096);
end;

destructor TOggPageReader.Destroy;
begin
  if FOwnsStream then FStream.Free;
  inherited Destroy;
end;

// ---------------------------------------------------------------------------
// FindSync
// ---------------------------------------------------------------------------

function TOggPageReader.FindSync: Boolean;
var
  B     : array[0..3] of Byte;
  Got   : Integer;
  Match : Integer;
begin
  Result := False;
  Match  := 0;

  while True do
  begin
    Got := FStream.Read(B[0], 1);
    if Got = 0 then Exit;

    if B[0] = OGG_CAPTURE_PATTERN[Match] then
    begin
      Inc(Match);
      if Match = 4 then
      begin
        // Found — back up 4 bytes so ReadPage can re-read the capture pattern
        FStream.Seek(-4, soCurrent);
        Result := True;
        Exit;
      end;
    end
    else
      Match := 0;
  end;
end;

// ---------------------------------------------------------------------------
// ReadPageInternal
// ---------------------------------------------------------------------------

function TOggPageReader.ReadPageInternal(out Page: TOggPage): TOggReadResult;
var
  Hdr         : array[0..OGG_PAGE_HEADER_MIN - 1] of Byte;
  Got         : Integer;
  NSeg        : Integer;
  DataLen     : Integer;
  I           : Integer;
  FullPage    : TBytes;
  FullLen     : Integer;
  StoredCRC   : Cardinal;
  ComputedCRC : Cardinal;
begin
  Result := orrError;
  FillChar(Page, SizeOf(Page), 0);

  // Read fixed header (27 bytes)
  Got := FStream.Read(Hdr[0], OGG_PAGE_HEADER_MIN);
  if Got = 0 then Exit(orrEndOfStream);
  if Got < OGG_PAGE_HEADER_MIN then Exit(orrNeedMore);

  // Verify capture pattern
  if (Hdr[0] <> OGG_CAPTURE_PATTERN[0]) or (Hdr[1] <> OGG_CAPTURE_PATTERN[1]) or
     (Hdr[2] <> OGG_CAPTURE_PATTERN[2]) or (Hdr[3] <> OGG_CAPTURE_PATTERN[3]) then
    Exit(orrSyncLost);

  Page.Header.Version         := Hdr[4];
  Page.Header.HeaderType      := Hdr[5];
  Page.Header.GranulePosition := ReadLE64(@Hdr[6]);
  Page.Header.SerialNumber    := ReadLE32(@Hdr[14]);
  Page.Header.SequenceNumber  := ReadLE32(@Hdr[18]);
  Page.Header.Checksum        := ReadLE32(@Hdr[22]);
  Page.Header.SegmentCount    := Hdr[26];
  NSeg := Page.Header.SegmentCount;

  if NSeg = 0 then Exit(orrError);

  // Read segment table
  Got := FStream.Read(Page.Header.SegmentTable[0], NSeg);
  if Got < NSeg then Exit(orrNeedMore);

  // Compute data length from segment table
  DataLen := 0;
  for I := 0 to NSeg - 1 do
    Inc(DataLen, Page.Header.SegmentTable[I]);

  // Read page data
  SetLength(Page.Data, DataLen);
  Page.DataLength := DataLen;
  if DataLen > 0 then
  begin
    Got := FStream.Read(Page.Data[0], DataLen);
    if Got < DataLen then Exit(orrNeedMore);
  end;

  // ---- Verify CRC-32 ----
  // Build the full page in a buffer with the CRC field zeroed
  FullLen := OGG_PAGE_HEADER_MIN + NSeg + DataLen;
  SetLength(FullPage, FullLen);
  // Copy capture pattern + fixed header
  Move(Hdr[0], FullPage[0], OGG_PAGE_HEADER_MIN);
  // Zero out the CRC field (bytes 22-25)
  FullPage[22] := 0; FullPage[23] := 0; FullPage[24] := 0; FullPage[25] := 0;
  // Append segment table
  Move(Page.Header.SegmentTable[0], FullPage[OGG_PAGE_HEADER_MIN], NSeg);
  // Append data
  if DataLen > 0 then
    Move(Page.Data[0], FullPage[OGG_PAGE_HEADER_MIN + NSeg], DataLen);

  StoredCRC   := Page.Header.Checksum;
  ComputedCRC := CRC32Ogg_Calc(@FullPage[0], FullLen);

  if ComputedCRC <> StoredCRC then Exit(orrCRCError);

  Result := orrPage;
end;

// ---------------------------------------------------------------------------
// ReadPage (public, with serial filtering)
// ---------------------------------------------------------------------------

function TOggPageReader.ReadPage(out Page: TOggPage): TOggReadResult;
begin
  repeat
    Result := ReadPageInternal(Page);
    if Result <> orrPage then Exit;

    // Skip pages for other logical streams if filtering is active
    if FFilterSerial and (Page.Header.SerialNumber <> FFilterSerialNum) then
      Continue;

    Exit;
  until False;
end;

// ---------------------------------------------------------------------------
// ReadPacket — high-level packet reassembly
// ---------------------------------------------------------------------------

function TOggPageReader.ReadPacket(out Pkt: TOggPacket): TOggReadResult;
var
  Page    : TOggPage;
  PageRes : TOggReadResult;
  SegLen  : Integer;
  SegIdx  : Integer;
  DataOff : Integer;
  IsLast  : Boolean;
  PacketDone: Boolean;
begin
  FillChar(Pkt, SizeOf(Pkt), 0);
  PacketDone := False;

  while not PacketDone do
  begin
    // If we have no unconsumed page, read the next one
    if FPageSegsRemaining = 0 then
    begin
      PageRes := ReadPage(FLastPage);
      if PageRes = orrEndOfStream then
      begin
        FReachedEOS := True;
        Exit(orrEndOfStream);
      end;
      if PageRes <> orrPage then Exit(PageRes);

      FPageSegsRemaining := FLastPage.Header.SegmentCount;
      FPageSegIdx        := 0;
      FPageDataOff       := 0;

      // If this page is a continuation, the first segment belongs to the
      // in-progress packet (FInPacket must already be True)
    end;

    // Consume segments from FLastPage one by one
    while (FPageSegsRemaining > 0) and not PacketDone do
    begin
      SegLen := FLastPage.Header.SegmentTable[FPageSegIdx];
      IsLast := (SegLen < OGG_MAX_SEGMENT_SIZE);

      // Start a new packet if we're not already in one
      if not FInPacket then
      begin
        FPartialLength := 0;
        FPartialBOS    := FLastPage.IsBOS;
        FPartialSerial := FLastPage.Header.SerialNumber;
        FPartialGranule:= OGG_GRANULE_NONE;
        FInPacket      := True;
      end;

      // Append segment data to partial packet
      if SegLen > 0 then
      begin
        if FPartialLength + SegLen > Length(FPartialPacket) then
          SetLength(FPartialPacket, (FPartialLength + SegLen) * 2);
        Move(FLastPage.Data[FPageDataOff], FPartialPacket[FPartialLength], SegLen);
        Inc(FPartialLength, SegLen);
      end;

      Inc(FPageDataOff, SegLen);
      Inc(FPageSegIdx);
      Dec(FPageSegsRemaining);

      if IsLast then
      begin
        // Packet complete. Granule position comes from the current page.
        FPartialGranule := FLastPage.Header.GranulePosition;
        PacketDone      := True;
        FInPacket       := False;
      end;
    end;
  end;

  // Fill the output packet
  Pkt.Length       := FPartialLength;
  Pkt.GranulePos   := FPartialGranule;
  Pkt.SerialNumber := FPartialSerial;
  Pkt.IsBOS        := FPartialBOS;
  Pkt.IsEOS        := FLastPage.IsEOS and (FPageSegsRemaining = 0);
  Pkt.PacketIndex  := FPacketIndex;

  SetLength(Pkt.Data, FPartialLength);
  if FPartialLength > 0 then
    Move(FPartialPacket[0], Pkt.Data[0], FPartialLength);

  Inc(FPacketIndex);

  if Pkt.IsEOS then
    FReachedEOS := True;

  Result := orrPacket;
end;

end.
