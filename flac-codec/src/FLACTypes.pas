unit FLACTypes;

{
  FLACTypes.pas - Types and constants for the FLAC codec

  Covers the FLAC stream format (https://xiph.org/flac/format.html):
    - Magic marker
    - Metadata block types and STREAMINFO layout
    - Frame header structure (channel assignment, block/sample-rate codes)
    - Subframe types (CONSTANT, VERBATIM, FIXED, LPC)
    - Residual coding methods

  All fields follow the FLAC spec (MSB-first bit packing, big-endian integers
  unless noted).

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

// ---------------------------------------------------------------------------
// Stream magic
// ---------------------------------------------------------------------------

const
  FLAC_MAGIC: array[0..3] of Byte = ($66, $4C, $61, $43); // 'fLaC'

// ---------------------------------------------------------------------------
// Metadata block types (7-bit field after the last-block flag)
// ---------------------------------------------------------------------------

const
  FLAC_META_STREAMINFO      = 0;
  FLAC_META_PADDING         = 1;
  FLAC_META_APPLICATION     = 2;
  FLAC_META_SEEKTABLE       = 3;
  FLAC_META_VORBIS_COMMENT  = 4;
  FLAC_META_CUESHEET        = 5;
  FLAC_META_PICTURE         = 6;

// ---------------------------------------------------------------------------
// Frame sync (first 14 bits of every frame header = 0x3FFE)
// In byte terms: first byte is 0xFF; high 6 bits of second byte are 0b111110
// Blocking strategy occupies bit 0 of byte 1:
//   0xFF 0xF8  → fixed-size blocks
//   0xFF 0xF9  → variable-size blocks
// ---------------------------------------------------------------------------

const
  FLAC_SYNC_BYTE0   = $FF;
  FLAC_SYNC_BYTE1_FIXED    = $F8;  // 14-bit sync + reserved(0) + blocking(0)
  FLAC_SYNC_BYTE1_VARIABLE = $F9;  // 14-bit sync + reserved(0) + blocking(1)

// ---------------------------------------------------------------------------
// Block size codes (4 bits in frame header byte 2 bits[7..4])
// ---------------------------------------------------------------------------

const
  FLAC_BLOCKSIZE_192   = 1;  // 192 samples
  // 2-5: 576 * 2^(code-2)
  FLAC_BLOCKSIZE_8BIT  = 6;  // read 8-bit value + 1
  FLAC_BLOCKSIZE_16BIT = 7;  // read 16-bit value + 1
  // 8-15: 256 * 2^(code-8)

// ---------------------------------------------------------------------------
// Sample rate codes (4 bits in frame header byte 2 bits[3..0])
// ---------------------------------------------------------------------------

const
  FLAC_SAMPLERATE_STREAMINFO = 0;   // from STREAMINFO
  FLAC_SAMPLERATE_88200  =  2;
  FLAC_SAMPLERATE_176400 =  3;
  FLAC_SAMPLERATE_192000 =  4;
  FLAC_SAMPLERATE_8000   =  5;
  FLAC_SAMPLERATE_16000  =  6;
  FLAC_SAMPLERATE_22050  =  7;
  FLAC_SAMPLERATE_24000  =  8;
  FLAC_SAMPLERATE_32000  =  9;
  FLAC_SAMPLERATE_44100  = 10;
  FLAC_SAMPLERATE_48000  = 11;
  FLAC_SAMPLERATE_96000  = 12;  // actually: 12=8-bit kHz, 13=16-bit Hz, 14=16-bit 10s-of-Hz
  FLAC_SAMPLERATE_8BIT_KHZ  = 12;
  FLAC_SAMPLERATE_16BIT_HZ  = 13;
  FLAC_SAMPLERATE_16BIT_TENHZ = 14;

// ---------------------------------------------------------------------------
// Channel assignment codes (4 bits in frame header byte 3 bits[7..4])
// ---------------------------------------------------------------------------

const
  // 0-7: independent channels, count = code + 1
  FLAC_CHANASSIGN_INDEPENDENT_MAX = 7;
  FLAC_CHANASSIGN_LEFT_SIDE  = 8;   // 2 ch: ch0=left, ch1=side(left-right), bps[1]+=1
  FLAC_CHANASSIGN_RIGHT_SIDE = 9;   // 2 ch: ch0=side(left-right), ch1=right, bps[0]+=1
  FLAC_CHANASSIGN_MID_SIDE   = 10;  // 2 ch: ch0=mid, ch1=side(left-right), bps[1]+=1

// ---------------------------------------------------------------------------
// Sample size codes (3 bits in frame header byte 3 bits[3..1])
// ---------------------------------------------------------------------------

const
  FLAC_BPS_STREAMINFO = 0;  // from STREAMINFO
  // 1..6: 8, 12, reserved, 16, 20, 24 bits
  // 7: 32 bits (FLAC 1.4+)

  FLAC_BPS_TABLE: array[0..7] of Byte = (0, 8, 12, 0, 16, 20, 24, 32);

// ---------------------------------------------------------------------------
// Subframe type codes (6 bits, first bit always 0)
// ---------------------------------------------------------------------------

const
  FLAC_SUBFRAME_CONSTANT  = 0;   // 0b000000
  FLAC_SUBFRAME_VERBATIM  = 1;   // 0b000001
  // 0b001xxx: FIXED, order = bits[2..0]
  FLAC_SUBFRAME_FIXED_BASE = 8;  // 0b001000
  FLAC_SUBFRAME_FIXED_MAX_ORDER = 4;
  // 0b1xxxxx: LPC, order = bits[4..0] + 1
  FLAC_SUBFRAME_LPC_BASE  = 32;  // 0b100000

// ---------------------------------------------------------------------------
// Residual coding methods (2 bits)
// ---------------------------------------------------------------------------

const
  FLAC_RESIDUAL_RICE  = 0;  // 4-bit Rice parameter
  FLAC_RESIDUAL_RICE2 = 1;  // 5-bit Rice parameter
  FLAC_RICE_ESCAPE_PARAM   = 15;  // 0b1111 — escape code for Rice
  FLAC_RICE2_ESCAPE_PARAM  = 31;  // 0b11111 — escape code for Rice2

// ---------------------------------------------------------------------------
// Parsed STREAMINFO record (34 bytes in the stream)
// ---------------------------------------------------------------------------

type
  TFLACStreamInfo = record
    MinBlockSize : Word;     // samples per block (minimum)
    MaxBlockSize : Word;     // samples per block (maximum)
    MinFrameSize : Cardinal; // bytes (0 = unknown)
    MaxFrameSize : Cardinal; // bytes (0 = unknown)
    SampleRate   : Cardinal; // Hz (20-bit field, 1..655350)
    Channels     : Byte;     // 1..8
    BitsPerSample: Byte;     // 4..32
    TotalSamples : Int64;    // 36-bit field, 0 = unknown
    MD5          : array[0..15] of Byte;
  end;

// ---------------------------------------------------------------------------
// Seek table entry
// ---------------------------------------------------------------------------

type
  TFLACSeekPoint = record
    SampleNumber : Int64;   // 0xFFFFFFFFFFFFFFFF = placeholder
    StreamOffset : Int64;   // bytes from start of first frame
    FrameSamples : Word;    // samples in the frame at this seek point
  end;

// ---------------------------------------------------------------------------
// Decoded frame header (filled by the frame decoder)
// ---------------------------------------------------------------------------

type
  TFLACFrameHeader = record
    BlockingStrategy    : Byte;     // 0 = fixed, 1 = variable
    BlockSize           : Cardinal; // samples per block
    SampleRate          : Cardinal; // Hz (0 = use STREAMINFO)
    ChannelAssignment   : Byte;     // 0-10
    Channels            : Byte;     // 1-8
    BitsPerSample       : Byte;     // 8, 12, 16, 20, 24, 32
    SampleOrFrameNumber : Int64;    // frame index (fixed) or first sample (variable)
    CRC8                : Byte;     // as read from stream
  end;

// ---------------------------------------------------------------------------
// Internal per-subframe context used during frame decode
// ---------------------------------------------------------------------------

type
  TFLACSubframeType = (sfConstant, sfVerbatim, sfFixed, sfLPC);

  TFLACSubframeInfo = record
    SubType     : TFLACSubframeType;
    WastedBits  : Byte;   // right-shift to apply after decode
    Order       : Byte;   // predictor order (FIXED 0-4, LPC 1-32)
    BPS         : Byte;   // effective bits-per-sample for this subframe
  end;

implementation

end.
