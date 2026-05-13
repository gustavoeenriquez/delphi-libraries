unit MP3EncTypes;

{
  MP3EncTypes.pas — Encoder-side types for MP3 Layer III

  All encoder modules depend on this unit and on MP3Types (decoder types
  reused without modification).  No decoder units are imported here.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

// ---------------------------------------------------------------------------
// Encoder configuration
// ---------------------------------------------------------------------------

type
  TMP3EncConfig = record
    SampleRate  : Integer;  // 32000 | 44100 | 48000
    Channels    : Integer;  // 1 (mono) | 2 (stereo)
    BitrateKbps : Integer;  // 32 40 48 56 64 80 96 112 128 160 192 224 256 320
    Quality     : Integer;  // 0=fastest/worst … 9=slowest/best  (like LAME -q)
    JointStereo : Boolean;  // MS-stereo allowed (only when Channels=2)
  end;

// ---------------------------------------------------------------------------
// Per-granule encoder state  (one granule = 576 spectral lines)
// ---------------------------------------------------------------------------

type
  TEncGranule = record
    // Spectral coefficients
    mdct_coefs  : array[0..575] of Single;    // forward MDCT output
    xr          : array[0..575] of Single;    // dequantized (for distortion check)
    ix          : array[0..575] of Integer;   // quantized  |coef| after outer loop

    // Scale factors
    scalefac_l  : array[0..21] of Integer;    // long blocks (21 bands)
    scalefac_s  : array[0..2, 0..12] of Integer; // short blocks (3 windows × 13 bands)

    // Side information  (written to the MP3 side-info field)
    global_gain      : Integer;   // 0..255
    part2_3_bits     : Integer;   // total bits: scalefac + Huffman
    part2_bits       : Integer;   // scalefac bits only
    block_type       : Integer;   // 0=normal, 1=start, 2=short, 3=stop
    mixed_block      : Boolean;
    table_select     : array[0..2] of Integer; // Huffman table for each region
    region0_count    : Integer;   // r0 partition boundary
    region1_count    : Integer;   // r1 partition boundary
    big_values       : Integer;   // pairs encoded with big-values Huffman
    scalefac_scale   : Integer;   // 0 | 1
    count1_table     : Integer;   // 0 | 1
    preflag          : Integer;   // 0 | 1
    scalefac_compress: Integer;   // 0..15 (index into slen1/slen2 table)
  end;

// ---------------------------------------------------------------------------
// Psychoacoustic result (Phase 5 — placeholder for earlier phases)
// ---------------------------------------------------------------------------

type
  TPsyResult = record
    smr     : array[0..575] of Single;  // signal-to-mask ratio per line
    pe      : Single;                   // perceptual entropy
    use_short: Boolean;
  end;

// ---------------------------------------------------------------------------
// Frame assembly scratch buffer
// ---------------------------------------------------------------------------

const
  MAX_ENC_FRAME_BYTES = 2048;

type
  TEncFrameBuf = record
    Data : array[0..MAX_ENC_FRAME_BYTES - 1] of Byte;
    Used : Integer;   // bytes written so far
  end;

// ---------------------------------------------------------------------------
// Bitrate and sample-rate lookup tables
// ---------------------------------------------------------------------------

const
  // MPEG1 Layer III bitrate table (index 1..14; 0 = free, 15 = bad)
  BITRATE_TABLE: array[0..15] of Integer = (
    0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0
  );

  // Sample rate table for MPEG1 (sr_idx 0..2)
  SAMPLE_RATE_TABLE: array[0..2] of Integer = ( 44100, 48000, 32000 );

implementation

end.
