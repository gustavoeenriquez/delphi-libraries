unit OpusTypes;

{
  OpusTypes.pas - Opus codec types and constants

  Implements the Opus packet format as defined in RFC 6716
  (https://www.rfc-editor.org/rfc/rfc6716)

  Key structural facts:
    - Every Opus packet begins with a TOC (Table of Contents) byte
    - TOC bits [7:3] = config (0-31): determines mode, bandwidth, frame size
    - TOC bit  [2]   = stereo flag (0=mono, 1=stereo)
    - TOC bits [1:0] = code: 0=1 frame, 1=2 equal, 2=2 different, 3=N frames

    Mode by config:
      0-11  = SILK-only  (NB/MB/WB, frame sizes 10/20/40/60ms)
      12-15 = Hybrid SILK+CELT (SWB/FB, 10/20ms)
      16-31 = CELT-only  (NB/WB/SWB/FB, 2.5/5/10/20ms)

    Opus always outputs 48kHz (v1). Internal decode may be at lower rates
    but resampling to 48kHz is the decoder's responsibility.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const
  OPUS_SAMPLE_RATE     = 48000;

  // Modes
  OPUS_MODE_SILK       = 0;
  OPUS_MODE_HYBRID     = 1;
  OPUS_MODE_CELT       = 2;

  // Bandwidths
  OPUS_BW_NARROWBAND   = 0;   // 4kHz, 8kHz internal
  OPUS_BW_MEDIUMBAND   = 1;   // 6kHz, 12kHz internal
  OPUS_BW_WIDEBAND     = 2;   // 8kHz, 16kHz internal
  OPUS_BW_SUPERWIDEBAND= 3;   // 12kHz, 24kHz internal
  OPUS_BW_FULLBAND     = 4;   // 20kHz, 48kHz internal

  // SILK-related
  SILK_MAX_ORDER_LPC   = 16;  // max LPC order in SILK
  SILK_SUBFRAMES       = 4;   // subframes per SILK frame
  SILK_MAX_PITCH_LAG   = 288; // max pitch lag in samples

  // CELT-related
  CELT_OVERLAP         = 120;             // overlap in samples at 48kHz
  CELT_MAX_BANDS       = 21;             // number of frequency bands
  CELT_HISTORY         = 2 * CELT_OVERLAP;
  CELT_NB_IMDCT_SIZE   = 120;            // 2.5ms at 48kHz
  CELT_MAX_FRAME_SIZE  = 960;            // 20ms at 48kHz

  // Range coder constants (RFC 6716 section 4.1)
  EC_SYM_BITS          = 8;
  EC_CODE_BITS         = 32;
  EC_SYM_MAX           = $FF;
  EC_CODE_BOT          = 1 shl 23;       // = 2^23
  EC_CODE_TOP          = 1 shl 30;       // = 2^30 (unused but useful)
  EC_CODE_SHIFT        = EC_CODE_BITS - EC_SYM_BITS - 1;  // = 23
  EC_CODE_EXTRA        = (EC_CODE_BITS - 2) mod EC_SYM_BITS + 1;  // = 7
  EC_CODE_MASK         = $7FFFFFFF;                        // = 2^31 - 1

// ---------------------------------------------------------------------------
// TOC byte parsing
// ---------------------------------------------------------------------------

type
  TOpusTOC = record
    Config    : Integer;   // 0..31
    Stereo    : Boolean;   // S bit
    Code      : Integer;   // 0..3 (frame count code)
    // Derived
    Mode      : Integer;   // OPUS_MODE_*
    Bandwidth : Integer;   // OPUS_BW_*
    FrameSizeMs: Single;   // frame duration in milliseconds
    FrameSamples: Integer; // frame samples at 48kHz
  end;

// Parse the TOC byte and fill a TOpusTOC record.
procedure OpusParseTOC(Byte_: Byte; out TOC: TOpusTOC);

// Internal sample rate for a given config (SILK: 8000/12000/16000; CELT: 48000)
function OpusInternalSampleRate(Config: Integer): Integer;

// ---------------------------------------------------------------------------
// Packet frame count and frame boundaries
// ---------------------------------------------------------------------------

type
  TOpusFrameInfo = record
    NumFrames    : Integer;          // total frames in packet
    FrameSize    : Integer;          // size in bytes of each frame (0 if VBR)
    FrameSizes   : TArray<Integer>;  // sizes for code 3 VBR
    Padding      : Integer;          // padding bytes (code 3 only)
    CBR          : Boolean;          // code 3: CBR flag
  end;

// Parse frame boundaries from a packet.
// Data: full packet bytes (including TOC).
// Returns False if the packet is malformed.
function OpusParseFrames(
  Data    : PByte;
  DataLen : Integer;
  const TOC: TOpusTOC;
  out Info : TOpusFrameInfo
): Boolean;

// ---------------------------------------------------------------------------
// Range decoder state (RFC 6716 section 4.1)
// ---------------------------------------------------------------------------

type
  TOpusRangeDecoder = record
    Data    : PByte;    // input buffer
    DataLen : Integer;  // total bytes
    DataPos : Integer;  // current read position (bytes)
    Val     : Cardinal; // current value (31-bit)
    Rng     : Cardinal; // current range
    Rem     : Integer;  // last byte read (for normalization)
    Error   : Boolean;  // decode error flag
  end;

// ---------------------------------------------------------------------------
// Config lookup tables (interface so other units can reference them)
// ---------------------------------------------------------------------------

const
  OPUS_FRAME_SIZE_MS: array[0..31] of Single = (
    10, 20, 40, 60,   // SILK NB
    10, 20, 40, 60,   // SILK MB
    10, 20, 40, 60,   // SILK WB
    10, 20,           // Hybrid SWB
    10, 20,           // Hybrid FB
    2.5, 5, 10, 20,   // CELT NB
    2.5, 5, 10, 20,   // CELT WB
    2.5, 5, 10, 20,   // CELT SWB
    2.5, 5, 10, 20    // CELT FB
  );

  OPUS_CONFIG_MODE: array[0..31] of Integer = (
    0,0,0,0,  0,0,0,0,  0,0,0,0,  // SILK (0-11)
    1,1,1,1,                        // Hybrid (12-15)
    2,2,2,2,  2,2,2,2,  2,2,2,2,  2,2,2,2  // CELT (16-31)
  );

  OPUS_CONFIG_BANDWIDTH: array[0..31] of Integer = (
    0,0,0,0,   // NB
    1,1,1,1,   // MB
    2,2,2,2,   // WB
    3,3,       // SWB hybrid
    4,4,       // FB hybrid
    0,0,0,0,   // CELT NB
    2,2,2,2,   // CELT WB
    3,3,3,3,   // CELT SWB
    4,4,4,4    // CELT FB
  );

implementation

// ---------------------------------------------------------------------------
// TOC byte parse
// ---------------------------------------------------------------------------

// (Constants moved to interface section)

procedure OpusParseTOC(Byte_: Byte; out TOC: TOpusTOC);
begin
  TOC.Config      := Byte_ shr 3;
  TOC.Stereo      := (Byte_ and $04) <> 0;
  TOC.Code        := Byte_ and $03;
  TOC.Mode        := OPUS_CONFIG_MODE[TOC.Config];
  TOC.Bandwidth   := OPUS_CONFIG_BANDWIDTH[TOC.Config];
  TOC.FrameSizeMs := OPUS_FRAME_SIZE_MS[TOC.Config];
  // Frame samples at 48kHz
  TOC.FrameSamples := Round(TOC.FrameSizeMs * OPUS_SAMPLE_RATE / 1000.0);
end;

function OpusInternalSampleRate(Config: Integer): Integer;
begin
  case OPUS_CONFIG_MODE[Config] of
    OPUS_MODE_SILK:
      case OPUS_CONFIG_BANDWIDTH[Config] of
        OPUS_BW_NARROWBAND: Result := 8000;
        OPUS_BW_MEDIUMBAND: Result := 12000;
        OPUS_BW_WIDEBAND:   Result := 16000;
      else                  Result := 16000;
      end;
    OPUS_MODE_HYBRID:
      Result := 16000;  // SILK part always at 16kHz in hybrid
    else // CELT
      Result := OPUS_SAMPLE_RATE;  // 48kHz
  end;
end;

// ---------------------------------------------------------------------------
// Frame boundary parse
// ---------------------------------------------------------------------------

function OpusParseFrames(
  Data    : PByte;
  DataLen : Integer;
  const TOC: TOpusTOC;
  out Info : TOpusFrameInfo
): Boolean;
var
  Pos        : Integer;
  I          : Integer;
  PayloadLen : Integer;
begin
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  if DataLen < 1 then Exit;

  Pos := 1;  // skip TOC byte
  PayloadLen := DataLen - Pos;

  case TOC.Code of
    0:
    begin
      // 1 frame: entire payload is the frame
      Info.NumFrames := 1;
      Info.CBR := True;
      SetLength(Info.FrameSizes, 1);
      Info.FrameSizes[0] := PayloadLen;
    end;

    1:
    begin
      // 2 CBR frames of equal size
      if (PayloadLen and 1) <> 0 then Exit;  // must be even
      Info.NumFrames := 2;
      Info.CBR := True;
      SetLength(Info.FrameSizes, 2);
      Info.FrameSizes[0] := PayloadLen div 2;
      Info.FrameSizes[1] := PayloadLen div 2;
    end;

    2:
    begin
      // 2 VBR frames; first frame size is self-delimited
      Info.NumFrames := 2;
      Info.CBR := False;
      SetLength(Info.FrameSizes, 2);
      if Pos >= DataLen then Exit;

      // Read self-delimited length of first frame
      var Len1: Integer := Data[Pos];
      Inc(Pos);
      if Len1 = 252 then
      begin
        if Pos >= DataLen then Exit;
        Len1 := Len1 + Data[Pos] * 4;
        Inc(Pos);
      end
      else if Len1 > 251 then
      begin
        if Pos >= DataLen then Exit;
        Len1 := (Len1 - 252) + Data[Pos] * 4 + 252;
        Inc(Pos);
      end;

      Info.FrameSizes[0] := Len1;
      Info.FrameSizes[1] := DataLen - Pos - Len1;
      if Info.FrameSizes[1] < 0 then Exit;
    end;

    3:
    begin
      // Arbitrary frames: read M byte
      if Pos >= DataLen then Exit;
      var MByte: Integer := Data[Pos];
      Inc(Pos);

      Info.CBR := (MByte and $80) <> 0;
      var VBR := (MByte and $40) <> 0;
      var HasPad := (MByte and $40) <> 0;
      Info.NumFrames := MByte and $3F;
      if Info.NumFrames = 0 then Exit;
      if Info.NumFrames > 48 then Exit;  // spec max

      // Padding
      Info.Padding := 0;
      if HasPad then
      begin
        repeat
          if Pos >= DataLen then Exit;
          var PadByte := Data[Pos];
          Inc(Pos);
          Inc(Info.Padding, PadByte);
        until Data[Pos - 1] <> 255;
      end;

      var Payload := DataLen - Pos - Info.Padding;
      if Payload < 0 then Exit;

      SetLength(Info.FrameSizes, Info.NumFrames);

      if not VBR then
      begin
        // CBR: all frames equal size
        if Info.NumFrames > 0 then
          Info.FrameSize := Payload div Info.NumFrames;
        for I := 0 to Info.NumFrames - 1 do
          Info.FrameSizes[I] := Info.FrameSize;
      end
      else
      begin
        // VBR: self-delimited lengths for first N-1 frames
        var Remaining := Payload;
        for I := 0 to Info.NumFrames - 2 do
        begin
          if Pos >= DataLen then Exit;
          var FLen: Integer := Data[Pos];
          Inc(Pos);
          if FLen = 252 then
          begin
            if Pos >= DataLen then Exit;
            FLen := FLen + Data[Pos] * 4;
            Inc(Pos);
          end
          else if FLen > 251 then
          begin
            if Pos >= DataLen then Exit;
            FLen := (FLen - 252) + Data[Pos] * 4 + 252;
            Inc(Pos);
          end;
          Info.FrameSizes[I] := FLen;
          Dec(Remaining, FLen);
        end;
        if Remaining < 0 then Exit;
        Info.FrameSizes[Info.NumFrames - 1] := Remaining;
      end;
    end;
  end;

  Result := True;
end;

end.
