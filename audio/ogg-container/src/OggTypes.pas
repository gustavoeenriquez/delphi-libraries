unit OggTypes;

{
  OggTypes.pas - Ogg container types and constants

  Implements the Ogg bitstream format as defined in RFC 3533
  (https://www.rfc-editor.org/rfc/rfc3533).

  Key structural facts:
    - Every Ogg page starts with capture pattern "OggS" (0x4F676753)
    - Pages contain 1..255 segments; each segment is 0..255 bytes
    - A lace value of 255 means the packet continues into the next segment
    - A lace value < 255 terminates the packet in that segment
    - If a packet length is an exact multiple of 255, a 0-byte final segment
      is required to mark packet end
    - The CRC-32 field covers the entire page with that field zeroed during
      computation (Ogg-specific poly: 0x04C11DB7, no reflection, init 0)
    - Granule position of a page = position of the last complete packet ending
      on that page; -1 if no packet ends on this page

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const
  OGG_CAPTURE_PATTERN : array[0..3] of Byte = ($4F, $67, $67, $53); // 'OggS'
  OGG_CAPTURE_DWORD   = $5367674F;  // little-endian dword for fast check

  OGG_VERSION         = $00;

  // Header type flags
  OGG_HEADER_CONTINUED = $01;  // this page is a continuation of the previous packet
  OGG_HEADER_BOS       = $02;  // first page of a logical bitstream
  OGG_HEADER_EOS       = $04;  // last page of a logical bitstream

  // Page segment limits
  OGG_MAX_SEGMENTS     = 255;
  OGG_MAX_SEGMENT_SIZE = 255;
  OGG_MAX_PAGE_DATA    = OGG_MAX_SEGMENTS * OGG_MAX_SEGMENT_SIZE; // 65025 bytes

  // Granule position sentinel meaning "no packet ends on this page"
  OGG_GRANULE_NONE     = Int64(-1);

  // Minimum page header size (without segment table):
  // 4 (capture) + 1 (ver) + 1 (htype) + 8 (gran) + 4 (serial) + 4 (seq) + 4 (crc) + 1 (nseg)
  OGG_PAGE_HEADER_MIN  = 27;

// ---------------------------------------------------------------------------
// Page header record (reflects the on-disk layout)
// All multi-byte fields are little-endian.
// ---------------------------------------------------------------------------

type
  TOggPageHeader = record
    // Fixed fields (27 bytes)
    Version         : Byte;
    HeaderType      : Byte;      // OGG_HEADER_* flags
    GranulePosition : Int64;     // codec-specific sample position
    SerialNumber    : Cardinal;  // logical bitstream serial
    SequenceNumber  : Cardinal;  // monotonically increasing per stream
    Checksum        : Cardinal;  // CRC-32 over entire page (field zeroed)
    SegmentCount    : Byte;      // number of lace values (1..255)
    SegmentTable    : array[0..OGG_MAX_SEGMENTS - 1] of Byte;
  end;

// ---------------------------------------------------------------------------
// Complete page (header + data in one structure)
// ---------------------------------------------------------------------------

type
  TOggPage = record
    Header     : TOggPageHeader;
    Data       : TBytes;    // concatenated payload of all segments
    DataLength : Integer;   // valid bytes in Data

    function IsBOS       : Boolean; inline;
    function IsEOS       : Boolean; inline;
    function IsContinued : Boolean; inline;
  end;

// ---------------------------------------------------------------------------
// Logical packet (reassembled from one or more pages)
// ---------------------------------------------------------------------------

type
  TOggPacket = record
    Data         : TBytes;
    Length       : Integer;   // valid bytes in Data
    GranulePos   : Int64;     // from the page on which this packet ends
    SerialNumber : Cardinal;
    IsBOS        : Boolean;   // packet came from a BOS page
    IsEOS        : Boolean;   // packet came from or ends on an EOS page
    PacketIndex  : Integer;   // 0-based within the logical stream
  end;

// ---------------------------------------------------------------------------
// Reader/writer state machine result codes
// ---------------------------------------------------------------------------

type
  TOggReadResult = (
    orrPage,         // a complete page was read successfully
    orrPacket,       // a complete packet is available
    orrNeedMore,     // need more input data
    orrEndOfStream,  // EOS page encountered and all packets delivered
    orrCRCError,     // CRC mismatch on a page
    orrSyncLost,     // capture pattern not found at expected position
    orrError         // unrecoverable error
  );

// ---------------------------------------------------------------------------
// TOggPage methods
// ---------------------------------------------------------------------------

implementation

function TOggPage.IsBOS: Boolean;
begin
  Result := (Header.HeaderType and OGG_HEADER_BOS) <> 0;
end;

function TOggPage.IsEOS: Boolean;
begin
  Result := (Header.HeaderType and OGG_HEADER_EOS) <> 0;
end;

function TOggPage.IsContinued: Boolean;
begin
  Result := (Header.HeaderType and OGG_HEADER_CONTINUED) <> 0;
end;

end.
