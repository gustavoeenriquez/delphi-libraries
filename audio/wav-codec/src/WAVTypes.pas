unit WAVTypes;

{
  WAVTypes.pas - RIFF/WAVE format constants and structures

  Covers:
    WAVE_FORMAT_PCM        (wFormatTag = 1)  — 8, 16, 24, 32-bit integer PCM
    WAVE_FORMAT_IEEE_FLOAT (wFormatTag = 3)  — 32 or 64-bit IEEE float PCM
    WAVE_FORMAT_EXTENSIBLE (wFormatTag = 0xFFFE) — multichannel + high-res

  Channel mask bits follow the Microsoft WAVEFORMATEXTENSIBLE convention
  (same values used in Windows SPEAKER_* constants, but no WinAPI dependency).

  All multi-byte values in WAV files are little-endian.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

// ---------------------------------------------------------------------------
// wFormatTag values
// ---------------------------------------------------------------------------

const
  WAVE_FORMAT_PCM        = $0001;
  WAVE_FORMAT_IEEE_FLOAT = $0003;
  WAVE_FORMAT_ALAW       = $0006;
  WAVE_FORMAT_MULAW      = $0007;
  WAVE_FORMAT_EXTENSIBLE = $FFFE;

// ---------------------------------------------------------------------------
// Channel mask bits (WAVEFORMATEXTENSIBLE dwChannelMask)
// Bit positions follow the Microsoft Speaker Position spec.
// ---------------------------------------------------------------------------

const
  SPEAKER_FRONT_LEFT            = $00000001;
  SPEAKER_FRONT_RIGHT           = $00000002;
  SPEAKER_FRONT_CENTER          = $00000004;
  SPEAKER_LOW_FREQUENCY         = $00000008;
  SPEAKER_BACK_LEFT             = $00000010;
  SPEAKER_BACK_RIGHT            = $00000020;
  SPEAKER_FRONT_LEFT_OF_CENTER  = $00000040;
  SPEAKER_FRONT_RIGHT_OF_CENTER = $00000080;
  SPEAKER_BACK_CENTER           = $00000100;
  SPEAKER_SIDE_LEFT             = $00000200;
  SPEAKER_SIDE_RIGHT            = $00000400;
  SPEAKER_TOP_CENTER            = $00000800;

  // Common layout masks
  SPEAKER_MONO         = SPEAKER_FRONT_LEFT;
  SPEAKER_STEREO       = SPEAKER_FRONT_LEFT or SPEAKER_FRONT_RIGHT;
  SPEAKER_QUAD         = SPEAKER_FRONT_LEFT or SPEAKER_FRONT_RIGHT or
                         SPEAKER_BACK_LEFT  or SPEAKER_BACK_RIGHT;
  SPEAKER_SURROUND_5_1 = SPEAKER_FRONT_LEFT   or SPEAKER_FRONT_RIGHT or
                         SPEAKER_FRONT_CENTER  or SPEAKER_LOW_FREQUENCY or
                         SPEAKER_BACK_LEFT     or SPEAKER_BACK_RIGHT;
  SPEAKER_SURROUND_7_1 = SPEAKER_SURROUND_5_1 or
                         SPEAKER_SIDE_LEFT     or SPEAKER_SIDE_RIGHT;

// ---------------------------------------------------------------------------
// RIFF / WAVE FourCC codes (stored as little-endian 32-bit integers)
// ---------------------------------------------------------------------------

const
  FOURCC_RIFF = $46464952;  // 'RIFF'
  FOURCC_WAVE = $45564157;  // 'WAVE'
  FOURCC_fmt  = $20746D66;  // 'fmt '
  FOURCC_data = $61746164;  // 'data'
  FOURCC_fact = $74636166;  // 'fact'
  FOURCC_LIST = $5453494C;  // 'LIST'
  FOURCC_ID3  = $20334449;  // 'ID3 '

// ---------------------------------------------------------------------------
// SubFormat GUIDs for WAVE_FORMAT_EXTENSIBLE
// Only the first 4 bytes (data1) identify the sub-format in practice.
// ---------------------------------------------------------------------------

const
  KSDATAFORMAT_SUBTYPE_PCM_DATA1        = $00000001;
  KSDATAFORMAT_SUBTYPE_IEEE_FLOAT_DATA1 = $00000003;

// ---------------------------------------------------------------------------
// On-disk structures (packed, little-endian)
// These are for documentation / manual parsing — TWAVReader does not use
// these records directly to avoid alignment surprises across platforms.
// ---------------------------------------------------------------------------

type
  // Standard WAVEFORMATEX header (18 bytes when cbSize = 0)
  TWAVFormatChunk = packed record
    wFormatTag     : Word;     // WAVE_FORMAT_*
    nChannels      : Word;     // 1..8
    nSamplesPerSec : Cardinal; // e.g. 44100
    nAvgBytesPerSec: Cardinal; // nSamplesPerSec * nBlockAlign
    nBlockAlign    : Word;     // nChannels * wBitsPerSample / 8
    wBitsPerSample : Word;     // 8, 16, 24, 32, 64
    cbSize         : Word;     // size of extra bytes (0 for PCM)
  end;

  // Extra fields present when wFormatTag = WAVE_FORMAT_EXTENSIBLE
  TWAVFormatExtensible = packed record
    wValidBitsPerSample: Word;     // actual bits of precision
    dwChannelMask      : Cardinal; // SPEAKER_* combination
    SubFormat          : array[0..15] of Byte;  // GUID
  end;

// ---------------------------------------------------------------------------
// Parsed, platform-friendly representation of a WAV file's format
// ---------------------------------------------------------------------------

type
  TWAVFormat = record
    FormatTag       : Word;     // WAVE_FORMAT_PCM / IEEE_FLOAT / EXTENSIBLE
    Channels        : Word;     // 1..8
    SampleRate      : Cardinal; // Hz
    BitsPerSample   : Word;     // container bits (8, 16, 24, 32, 64)
    ValidBitsPerSample: Word;   // meaningful bits (may differ from BitsPerSample)
    IsFloat         : Boolean;  // True for IEEE float sub-format
    IsExtensible    : Boolean;  // True if WAVE_FORMAT_EXTENSIBLE was present
    ChannelMask     : Cardinal; // SPEAKER_* bitmask (0 = unspecified)
    BytesPerFrame   : Word;     // Channels * (BitsPerSample div 8) — nBlockAlign
    DataOffset      : Int64;    // byte offset of first sample in the file/stream
    DataBytes       : Cardinal; // total bytes in the data chunk (0 = unknown/streaming)
    FrameCount      : Cardinal; // DataBytes div BytesPerFrame (0 = unknown)
  end;

// ---------------------------------------------------------------------------
// Helper: compute FrameCount from a filled TWAVFormat record
// ---------------------------------------------------------------------------

function WAVCalcFrameCount(const Fmt: TWAVFormat): Cardinal;

implementation

function WAVCalcFrameCount(const Fmt: TWAVFormat): Cardinal;
begin
  if (Fmt.BytesPerFrame = 0) or (Fmt.DataBytes = 0) then
    Result := 0
  else
    Result := Fmt.DataBytes div Fmt.BytesPerFrame;
end;

end.
