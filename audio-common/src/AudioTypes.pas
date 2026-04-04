unit AudioTypes;

{
  AudioTypes.pas - Shared types for the delphi-libraries audio codec stack

  This unit defines the canonical types used by all audio libraries in this
  repository: wav-codec, flac-codec, ogg-container, vorbis-decoder,
  opus-decoder, mp3-encoder, and audio-codec.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

// ---------------------------------------------------------------------------
// Audio format identifier
// ---------------------------------------------------------------------------

type
  TAudioFormat = (
    afUnknown,   // Not detected or unsupported
    afWAV,       // RIFF WAVE (PCM, IEEE float, extensible)
    afMP3,       // MPEG-1/2 Layer III
    afFLAC,      // Free Lossless Audio Codec
    afVorbis,    // Ogg Vorbis
    afOpus       // Opus (RFC 6716)
  );

// ---------------------------------------------------------------------------
// Stream metadata
// ---------------------------------------------------------------------------

type
  TAudioInfo = record
    Format    : TAudioFormat;
    SampleRate: Cardinal;  // Hz, e.g. 44100, 48000
    Channels  : Byte;      // 1 = mono, 2 = stereo, up to 8
    BitDepth  : Byte;      // Bits per sample in source file; 0 for lossy formats
    IsFloat   : Boolean;   // True if source is IEEE float PCM
    DurationMs: Int64;     // Total duration in milliseconds; -1 if unknown
    BitRate   : Cardinal;  // Encoded bitrate in kbps; 0 if unknown/lossless
  end;

// ---------------------------------------------------------------------------
// Audio sample buffer
// Planar layout: Buffer[channel][sample_index]
// All samples are normalized to the range [-1.0 .. 1.0]
// ---------------------------------------------------------------------------

type
  TAudioBuffer = array of TArray<Single>;

// ---------------------------------------------------------------------------
// Decoder/encoder operation results
// ---------------------------------------------------------------------------

type
  TAudioDecodeResult = (
    adrOK,           // One frame/block decoded successfully
    adrEndOfStream,  // No more data; stream finished cleanly
    adrNeedMoreData, // Input buffer exhausted; feed more bytes and retry
    adrCorrupted,    // Sync or CRC error; caller may try to recover
    adrError         // Unrecoverable error (bad header, unsupported feature)
  );

  TAudioEncodeResult = (
    aerOK,           // Samples accepted and encoded
    aerNeedFlush,    // Internal buffer partially full; call Flush to drain
    aerError         // Unrecoverable encoding error
  );

// ---------------------------------------------------------------------------
// Bit-reader order convention
// ---------------------------------------------------------------------------

type
  TBitOrder = (
    boMSBFirst,  // Most-significant bit first  (FLAC, Ogg, Vorbis, Opus, MP3)
    boLSBFirst   // Least-significant bit first (used by some container fields)
  );

// ---------------------------------------------------------------------------
// Bit reader state record
// Actual implementation is in AudioBitReader.pas
// ---------------------------------------------------------------------------

type
  TAudioBitReader = record
    Buf     : PByte;    // Pointer to start of input buffer
    Pos     : Integer;  // Current bit position (0 = first bit of Buf^)
    Limit   : Integer;  // Total number of valid bits in buffer
    BitOrder: TBitOrder;
  end;

// ---------------------------------------------------------------------------
// Helper: create an empty TAudioBuffer with the given channel count
// Samples arrays start empty (length 0)
// ---------------------------------------------------------------------------

// Create an empty buffer (channel arrays have zero length).
function AudioBufferCreate(Channels: Integer): TAudioBuffer; overload;

// Create a buffer with all channel arrays pre-allocated to Samples length.
function AudioBufferCreate(Channels: Integer; Samples: Integer): TAudioBuffer; overload;

// Helper: resize all channel arrays to SampleCount
procedure AudioBufferResize(var Buf: TAudioBuffer; SampleCount: Integer);

// Helper: total sample frames (assuming all channels have the same length)
function AudioBufferFrameCount(const Buf: TAudioBuffer): Integer;

implementation

function AudioBufferCreate(Channels: Integer): TAudioBuffer;
begin
  SetLength(Result, Channels);
end;

function AudioBufferCreate(Channels: Integer; Samples: Integer): TAudioBuffer;
var
  Ch: Integer;
begin
  SetLength(Result, Channels);
  for Ch := 0 to Channels - 1 do
    SetLength(Result[Ch], Samples);
end;

procedure AudioBufferResize(var Buf: TAudioBuffer; SampleCount: Integer);
var
  Ch: Integer;
begin
  for Ch := 0 to High(Buf) do
    SetLength(Buf[Ch], SampleCount);
end;

function AudioBufferFrameCount(const Buf: TAudioBuffer): Integer;
begin
  if Length(Buf) = 0 then
    Result := 0
  else
    Result := Length(Buf[0]);
end;

end.
