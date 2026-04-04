unit OggPageWriter;

{
  OggPageWriter.pas - Ogg page and packet writer

  Writes logical Ogg packets to a TStream, packaging them into Ogg pages.

  Key rules implemented (RFC 3533):
    - Each page carries up to 255 segments of up to 255 bytes each
      (max payload: 65025 bytes per page)
    - A segment of 255 bytes means the packet continues; < 255 terminates it
    - If a packet is exactly a multiple of 255 bytes, a 0-byte terminal
      segment is appended on the next page
    - The BOS page must be the first page; EOS page must be the last
    - CRC-32 (Ogg poly 0x04C11DB7, no reflection, init 0) is computed
      over the full page with the CRC field zeroed
    - Pages are emitted when either:
        (a) the current page reaches 255 segments, or
        (b) the caller explicitly flushes with WriteBOS / WriteEOS / FlushPage

  Usage:
    var W: TOggPageWriter;
    W := TOggPageWriter.Create(Stream, SerialNumber);
    try
      W.WritePacket(HeaderData, True, False, 0);   // BOS
      while HavePackets do
        W.WritePacket(Data, False, False, GranulePos);
      W.WritePacket(LastData, False, True, FinalGranule);  // EOS
    finally
      W.Free;
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
  TOggPageWriter = class
  private
    FStream        : TStream;
    FOwnsStream    : Boolean;
    FSerial        : Cardinal;
    FSeqNum        : Cardinal;   // next page sequence number
    FFirstPage     : Boolean;   // True until first page is written

    // Pending page accumulation
    FSegTable      : array[0..OGG_MAX_SEGMENTS - 1] of Byte;
    FSegCount      : Integer;
    FPageData      : TBytes;
    FPageDataLen   : Integer;
    FPageGranule   : Int64;
    FPageContinued : Boolean;   // next page will carry the CONTINUED flag

    procedure EmitPage(HeaderType: Byte; GranulePos: Int64);
    procedure EmitPageIfFull;

  public
    constructor Create(AStream: TStream; SerialNumber: Cardinal;
      OwnsStream: Boolean = False);
    destructor Destroy; override;

    // Write one logical packet. If BOS or EOS is True, the corresponding
    // header type flag is set on the page that ends this packet.
    // GranulePos: codec-specific end-of-packet position (-1 = not applicable).
    procedure WritePacket(
      Data       : PByte;
      DataLen    : Integer;
      IsBOS      : Boolean;
      IsEOS      : Boolean;
      GranulePos : Int64
    ); overload;

    procedure WritePacket(
      const Data : TBytes;
      IsBOS      : Boolean;
      IsEOS      : Boolean;
      GranulePos : Int64
    ); overload;

    // Force emission of the current page even if not full.
    // GranulePos overrides the accumulated granule for this page.
    procedure FlushPage(GranulePos: Int64 = OGG_GRANULE_NONE);

    property SerialNumber  : Cardinal read FSerial;
    property PagesWritten  : Cardinal read FSeqNum;
  end;

implementation

// ---------------------------------------------------------------------------
// Little-endian write helpers
// ---------------------------------------------------------------------------

procedure WriteLE16(P: PByte; V: Word); inline;
begin P^ := V and $FF; (P+1)^ := (V shr 8) and $FF; end;

procedure WriteLE32(P: PByte; V: Cardinal); inline;
begin
  P^ := V and $FF; (P+1)^ := (V shr 8) and $FF;
  (P+2)^ := (V shr 16) and $FF; (P+3)^ := (V shr 24) and $FF;
end;

procedure WriteLE64(P: PByte; V: Int64); inline;
begin
  WriteLE32(P,   Cardinal(V and $FFFFFFFF));
  WriteLE32(P+4, Cardinal((V shr 32) and $FFFFFFFF));
end;

// ---------------------------------------------------------------------------
// Constructor / Destructor
// ---------------------------------------------------------------------------

constructor TOggPageWriter.Create(AStream: TStream; SerialNumber: Cardinal;
  OwnsStream: Boolean);
begin
  inherited Create;
  FStream      := AStream;
  FOwnsStream  := OwnsStream;
  FSerial      := SerialNumber;
  FSeqNum      := 0;
  FFirstPage   := True;
  FSegCount    := 0;
  FPageDataLen := 0;
  FPageGranule := OGG_GRANULE_NONE;
  FPageContinued := False;
  SetLength(FPageData, OGG_MAX_PAGE_DATA);
end;

destructor TOggPageWriter.Destroy;
begin
  if FOwnsStream then FStream.Free;
  inherited Destroy;
end;

// ---------------------------------------------------------------------------
// EmitPage
// ---------------------------------------------------------------------------

procedure TOggPageWriter.EmitPage(HeaderType: Byte; GranulePos: Int64);
var
  HdrLen   : Integer;
  PageLen  : Integer;
  PageBuf  : TBytes;
  CRC      : Cardinal;
  P        : PByte;
begin
  if FSegCount = 0 then Exit;

  HdrLen  := OGG_PAGE_HEADER_MIN + FSegCount;
  PageLen := HdrLen + FPageDataLen;
  SetLength(PageBuf, PageLen);
  FillChar(PageBuf[0], PageLen, 0);

  P := @PageBuf[0];

  // Capture pattern
  P^ := OGG_CAPTURE_PATTERN[0]; Inc(P);
  P^ := OGG_CAPTURE_PATTERN[1]; Inc(P);
  P^ := OGG_CAPTURE_PATTERN[2]; Inc(P);
  P^ := OGG_CAPTURE_PATTERN[3]; Inc(P);

  P^ := OGG_VERSION; Inc(P);

  if FPageContinued then HeaderType := HeaderType or OGG_HEADER_CONTINUED;
  P^ := HeaderType; Inc(P);

  WriteLE64(P, GranulePos); Inc(P, 8);
  WriteLE32(P, FSerial);    Inc(P, 4);
  WriteLE32(P, FSeqNum);    Inc(P, 4);

  // CRC placeholder (4 zeros already from FillChar)
  Inc(P, 4);

  P^ := Byte(FSegCount); Inc(P);
  Move(FSegTable[0], P^, FSegCount); Inc(P, FSegCount);

  if FPageDataLen > 0 then
    Move(FPageData[0], P^, FPageDataLen);

  // Compute and insert CRC
  CRC := CRC32Ogg_Calc(@PageBuf[0], PageLen);
  WriteLE32(@PageBuf[22], CRC);

  FStream.WriteBuffer(PageBuf[0], PageLen);

  // Advance state
  Inc(FSeqNum);
  FSegCount    := 0;
  FPageDataLen := 0;
  FPageGranule := OGG_GRANULE_NONE;
  FPageContinued := False;
end;

procedure TOggPageWriter.EmitPageIfFull;
begin
  if FSegCount >= OGG_MAX_SEGMENTS then
  begin
    // Emit with granule = -1 (no packet ends here, packet continues)
    EmitPage(0, OGG_GRANULE_NONE);
    FPageContinued := True;
  end;
end;

// ---------------------------------------------------------------------------
// FlushPage
// ---------------------------------------------------------------------------

procedure TOggPageWriter.FlushPage(GranulePos: Int64);
begin
  if FSegCount > 0 then
    EmitPage(0, GranulePos);
end;

// ---------------------------------------------------------------------------
// WritePacket
// ---------------------------------------------------------------------------

procedure TOggPageWriter.WritePacket(
  Data: PByte; DataLen: Integer;
  IsBOS, IsEOS: Boolean; GranulePos: Int64);
var
  Remaining  : Integer;
  Take       : Integer;
  HeaderType : Byte;
begin
  Remaining := DataLen;

  // Determine base header type for the page ending this packet
  HeaderType := 0;
  if IsBOS and FFirstPage then HeaderType := HeaderType or OGG_HEADER_BOS;
  if IsEOS then HeaderType := HeaderType or OGG_HEADER_EOS;

  // Segment the packet data
  repeat
    // Flush current page if it's full
    EmitPageIfFull;

    // How much fits in the current page?
    var FreeSegs := OGG_MAX_SEGMENTS - FSegCount;

    if Remaining = 0 then
    begin
      // Zero-byte terminal segment (needed when previous segment was 255)
      // This handles the edge case: packet length is exact multiple of 255
      FSegTable[FSegCount] := 0;
      Inc(FSegCount);
      Break;
    end;

    Take := Remaining;
    if Take > OGG_MAX_SEGMENT_SIZE then Take := OGG_MAX_SEGMENT_SIZE;

    // How many full 255-byte segments fit in the remaining page slots?
    // We need at least 1 segment slot; if only 1 slot left and Take=255,
    // we'll have to continue on the next page.
    if Take = OGG_MAX_SEGMENT_SIZE then
    begin
      // Write 255-byte segment; packet continues
      Move(Data^, FPageData[FPageDataLen], 255);
      Inc(FPageDataLen, 255);
      FSegTable[FSegCount] := 255;
      Inc(FSegCount);
      Dec(Remaining, 255);
      Inc(Data, 255);
      // If remaining > 0 and we haven't run out of segments, keep looping
    end
    else
    begin
      // Last segment of this packet (< 255 bytes)
      Move(Data^, FPageData[FPageDataLen], Take);
      Inc(FPageDataLen, Take);
      FSegTable[FSegCount] := Byte(Take);
      Inc(FSegCount);
      Dec(Remaining, Take);
      Inc(Data, Take);
      // Packet terminated
      Break;
    end;
  until Remaining < 0;  // never, loop managed by Break

  // Emit the page now if:
  //   - BOS (always flush BOS page immediately)
  //   - EOS (always flush EOS page)
  //   - The page is full
  if IsBOS or IsEOS or (FSegCount >= OGG_MAX_SEGMENTS) then
  begin
    EmitPage(HeaderType, GranulePos);
    FFirstPage := False;
  end
  else
  begin
    // Accumulate granule for this page: take the last non-negative granule
    if GranulePos >= 0 then
      FPageGranule := GranulePos;
    FFirstPage := False;
  end;
end;

procedure TOggPageWriter.WritePacket(
  const Data: TBytes; IsBOS, IsEOS: Boolean; GranulePos: Int64);
begin
  if Length(Data) = 0 then
    WritePacket(nil, 0, IsBOS, IsEOS, GranulePos)
  else
    WritePacket(@Data[0], Length(Data), IsBOS, IsEOS, GranulePos);
end;

end.
