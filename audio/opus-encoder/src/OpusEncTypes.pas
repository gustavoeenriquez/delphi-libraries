unit OpusEncTypes;

{
  OpusEncTypes.pas - Opus encoder types and configuration

  Mirrors OpusTypes.pas (decoder side) with encoder-specific additions.
  Encoder state is built up in phases; only Phase 1 fields are present here.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  OpusTypes;

// ---------------------------------------------------------------------------
// Encoder configuration
// ---------------------------------------------------------------------------

const
  OPUS_ENC_COMPLEXITY_DEFAULT = 5;
  OPUS_ENC_BITRATE_DEFAULT    = 96000;   // 96 kbps
  OPUS_ENC_BITRATE_MIN        = 6000;
  OPUS_ENC_BITRATE_MAX        = 510000;

  // Maximum Opus packet size per RFC 6716
  OPUS_MAX_PACKET_SIZE        = 1276;    // 1 TOC + 3*255 + 255 bytes max

type
  TOpusEncConfig = record
    Channels   : Integer;  // 1 or 2
    SampleRate : Integer;  // input sample rate (8000-48000)
    Bitrate    : Integer;  // target bitrate in bps
    Complexity : Integer;  // 0 (lowest) .. 10 (highest quality)
    FrameSizeMs: Single;   // 2.5, 5, 10, 20, 40, or 60ms (default 20)
    Mode       : Integer;  // OPUS_MODE_* or -1 for auto
    Bandwidth  : Integer;  // OPUS_BW_* or -1 for auto
  end;

// Fill config with defaults for the given channel count and sample rate.
procedure OpusEncConfigInit(out Cfg: TOpusEncConfig;
  AChannels, ASampleRate: Integer);

// Compute the TOC config byte (0..31) for a given mode, bandwidth and
// frame size in ms. Returns -1 if the combination is invalid.
function OpusEncTOCConfig(Mode, Bandwidth: Integer;
  FrameSizeMs: Single): Integer;

// Build the TOC byte from a config index, stereo flag and frame-code.
function OpusEncTOCByte(Config: Integer; Stereo: Boolean;
  Code: Integer): Byte;

// ---------------------------------------------------------------------------
// Encoder output packet
// ---------------------------------------------------------------------------

type
  TOpusEncPacket = record
    Data    : array[0..OPUS_MAX_PACKET_SIZE - 1] of Byte;
    Len     : Integer;   // valid bytes in Data
    Samples : Integer;   // PCM samples encoded (at input sample rate)
  end;

// ---------------------------------------------------------------------------
// Range encoder state (RFC 6716 §4.1 write side)
// Initialized by ReInit; finalized by ReFlush.
// ---------------------------------------------------------------------------

type
  TOpusRangeEncoder = record
    Buf       : PByte;    // output buffer (caller owns)
    Storage   : Cardinal; // buffer capacity in bytes
    Offs      : Cardinal; // bytes written from buffer start (range coder)
    EndOffs   : Cardinal; // bytes written from buffer end (raw bits)
    EndWindow : Cardinal; // bit accumulator for raw bits
    NEndBits  : Integer;  // valid bits in EndWindow
    NBitsTotal: Integer;  // total bits produced (for ec_tell)
    Rng       : Cardinal; // current range
    Val       : Cardinal; // current low bound of interval
    Ext       : Cardinal; // count of pending 0xFF carry bytes
    Rem       : Integer;  // last buffered output byte, -1 = none
    Error     : Boolean;  // true if buffer overflow occurred
  end;

implementation

// ---------------------------------------------------------------------------
// Config tables for TOC config byte lookup
// (mirror of OPUS_CONFIG_MODE / OPUS_CONFIG_BANDWIDTH; OpusTypes ya no
//  exporta la tabla de duraciones, así que se define aquí — RFC 6716 §3.1)
// ---------------------------------------------------------------------------

const
  OPUS_ENC_FRAME_SIZE_MS: array[0..31] of Single = (
    10, 20, 40, 60,  10, 20, 40, 60,  10, 20, 40, 60,   // SILK NB/MB/WB
    10, 20,  10, 20,                                     // Hybrid SWB/FB
    2.5, 5, 10, 20,  2.5, 5, 10, 20,                     // CELT NB/WB
    2.5, 5, 10, 20,  2.5, 5, 10, 20);                    // CELT SWB/FB

procedure OpusEncConfigInit(out Cfg: TOpusEncConfig;
  AChannels, ASampleRate: Integer);
begin
  FillChar(Cfg, SizeOf(Cfg), 0);
  Cfg.Channels    := AChannels;
  Cfg.SampleRate  := ASampleRate;
  Cfg.Bitrate     := OPUS_ENC_BITRATE_DEFAULT;
  Cfg.Complexity  := OPUS_ENC_COMPLEXITY_DEFAULT;
  Cfg.FrameSizeMs := 20.0;
  Cfg.Mode        := -1;   // auto
  Cfg.Bandwidth   := -1;   // auto
end;

function OpusEncTOCConfig(Mode, Bandwidth: Integer;
  FrameSizeMs: Single): Integer;
var
  I: Integer;
begin
  for I := 0 to 31 do
    if (OPUS_CONFIG_MODE[I] = Mode) and
       (OPUS_CONFIG_BANDWIDTH[I] = Bandwidth) and
       (Abs(OPUS_ENC_FRAME_SIZE_MS[I] - FrameSizeMs) < 0.01) then
      Exit(I);
  Result := -1;
end;

function OpusEncTOCByte(Config: Integer; Stereo: Boolean;
  Code: Integer): Byte;
begin
  Result := Byte((Config shl 3) or (Ord(Stereo) shl 2) or (Code and $03));
end;

end.
