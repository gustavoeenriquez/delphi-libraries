unit OpusEncPacket;

{
  OpusEncPacket.pas - Opus CELT packet assembler and Ogg Opus stream writer

  Assembles complete Opus packets (TOC byte + range-coded CELT frame) and
  writes Ogg Opus streams (.opus files).

  Packet structure (RFC 6716 §3.1):
    Byte 0:    TOC  (config[5] | stereo[1] | code[2])
    Bytes 1..: range-coded CELT frame data

  Ogg Opus stream (RFC 7845):
    Page 0: BOS + OpusHead identification header
    Page 1: OpusTags comment header
    Pages 2+: Audio packets, one Opus packet per Ogg packet

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, Math,
  AudioTypes,
  OggTypes,
  OggPageWriter,
  OpusTypes,
  OpusEncTypes,
  OpusRangeEncoder,
  OpusEncCelt;

const
  OPUS_MAX_PACKET = 1276;  // max Opus packet size per RFC 6716

// ---------------------------------------------------------------------------
// TOpusCeltEncoder: single-frame Opus/CELT encoder
// ---------------------------------------------------------------------------

type
  TOpusCeltEncoder = class
  private
    FState     : TCeltEncState;
    FChannels  : Integer;
    FSampleRate: Integer;    // input sample rate (for resampling, future use)
    FConfig    : Integer;    // TOC config index (16-31 for CELT)
    FLM        : Integer;    // frame size index
    FFrameSize : Integer;    // samples per frame

  public
    constructor Create(Channels, SampleRate, FrameSizeMs: Integer);

    // Encode one frame of int16 PCM → Opus packet bytes.
    // PCM: Channels × FrameSize samples (interleaved for stereo).
    // PacketBuf: output buffer (must be at least OPUS_MAX_PACKET bytes).
    // Returns number of bytes written (>= 1), or 0 on error.
    function EncodeFrame(PCM: PSmallInt; PacketBuf: PByte; MaxLen: Integer): Integer;

    property Channels  : Integer read FChannels;
    property FrameSize : Integer read FFrameSize;
    property LM        : Integer read FLM;
    property Config    : Integer read FConfig;
  end;

// ---------------------------------------------------------------------------
// TOpusWriter: writes an Ogg Opus stream to a TStream
// ---------------------------------------------------------------------------

type
  TOpusWriter = class
  private
    FStream   : TStream;
    FOwns     : Boolean;
    FWriter   : TOggPageWriter;
    FEncoder  : TOpusCeltEncoder;
    FGranule  : Int64;
    FPreSkip  : Integer;
    FSampleRate: Integer;

    procedure WriteOpusHead;
    procedure WriteOpusTags;

  public
    constructor Create(AStream: TStream; Channels, SampleRate, FrameSizeMs: Integer;
      OwnsStream: Boolean = False);
    destructor Destroy; override;

    // Encode one frame of int16 PCM and write to the Ogg stream.
    // PCM: Channels × FrameSize samples interleaved.
    procedure WriteFrame(PCM: PSmallInt);

    // Finalize the stream (writes EOS page).
    procedure Finish;

    property Encoder: TOpusCeltEncoder read FEncoder;
  end;

implementation

// ---------------------------------------------------------------------------
// TOpusCeltEncoder
// ---------------------------------------------------------------------------

constructor TOpusCeltEncoder.Create(Channels, SampleRate, FrameSizeMs: Integer);
const
  // LM index → frame size in ms: 0=2.5, 1=5, 2=10, 3=20
  LMTable: array[0..3] of Integer = (25, 5, 10, 20);  // × 0.1ms
  FrameMs:  array[0..3] of Integer = (3, 5, 10, 20);   // round ms
begin
  FChannels   := Channels;
  FSampleRate := SampleRate;

  // Choose LM based on requested frame size
  case FrameSizeMs of
    20: FLM := 3;
    10: FLM := 2;
     5: FLM := 1;
  else  FLM := 3;  // default 20ms
  end;

  // CELT fullband (FB) config: config 28 = CELT WB 20ms, config 29 = CELT SWB 20ms,
  // config 31 = CELT FB 20ms. Use config 28 for all frame sizes (compatible).
  // For LM=3 (20ms): CELT FB = config 31. For LM=2 (10ms): config 29. Etc.
  case FLM of
    3: FConfig := 31;  // CELT FB 20ms
    2: FConfig := 29;  // CELT SWB 10ms
    1: FConfig := 25;  // CELT WB 5ms
  else FConfig := 16;  // CELT NB 2.5ms
  end;

  CeltEncStateInit(FState, Channels, FLM);
  FFrameSize := FState.FrameSize;
end;

function TOpusCeltEncoder.EncodeFrame(PCM: PSmallInt; PacketBuf: PByte; MaxLen: Integer): Integer;
var
  Re     : TOpusRangeEncoder;
  Budget : Integer;
  Len    : Integer;
begin
  Result := 0;
  if MaxLen < 2 then Exit;

  // Build TOC byte: config[7:3] | stereo[2] | code[1:0]
  PacketBuf[0] := Byte((FConfig shl 3) or (Ord(FChannels > 1) shl 2) or 0);

  // Range-encode CELT frame into bytes 1..MaxLen-1
  ReInit(Re, PacketBuf + 1, Cardinal(MaxLen - 1));
  Budget := (MaxLen - 1) * 8;  // all available bits

  if not CeltEncodeFrame(FState, PCM, Re, Budget) then Exit;

  Len := ReFlush(Re);
  if Re.Error then Exit;

  Result := 1 + Len;  // TOC + payload
end;

// ---------------------------------------------------------------------------
// TOpusWriter
// ---------------------------------------------------------------------------

constructor TOpusWriter.Create(AStream: TStream; Channels, SampleRate, FrameSizeMs: Integer;
  OwnsStream: Boolean);
begin
  FStream    := AStream;
  FOwns      := OwnsStream;
  FSampleRate := SampleRate;
  FPreSkip   := 312;  // standard CELT pre-skip (about 6.5ms at 48kHz)
  FGranule   := -FPreSkip;  // starts negative (pre-skip counts down)

  FEncoder := TOpusCeltEncoder.Create(Channels, SampleRate, FrameSizeMs);
  FWriter  := TOggPageWriter.Create(AStream, $01020304);  // random serial

  WriteOpusHead;
  WriteOpusTags;
end;

destructor TOpusWriter.Destroy;
begin
  FEncoder.Free;
  FWriter.Free;
  if FOwns then FStream.Free;
  inherited;
end;

procedure TOpusWriter.WriteOpusHead;
var
  Head: TBytes;
begin
  // RFC 7845 §5.1 OpusHead
  SetLength(Head, 19);
  // Magic: 'OpusHead'
  Head[0] := 79; Head[1] := 112; Head[2] := 117; Head[3] := 115;
  Head[4] := 72; Head[5] := 101; Head[6] := 97;  Head[7] := 100;
  Head[8] := 1;                        // version = 1
  Head[9] := FEncoder.Channels;         // channel count
  // Pre-skip (little-endian 16-bit)
  Head[10] := FPreSkip and $FF;
  Head[11] := (FPreSkip shr 8) and $FF;
  // Input sample rate (little-endian 32-bit)
  Head[12] := FSampleRate and $FF;
  Head[13] := (FSampleRate shr 8) and $FF;
  Head[14] := (FSampleRate shr 16) and $FF;
  Head[15] := (FSampleRate shr 24) and $FF;
  Head[16] := 0; Head[17] := 0;        // output gain = 0
  Head[18] := 0;                        // channel mapping family = 0 (mono/stereo)

  FWriter.WritePacket(Head, True {BOS}, False, 0);
end;

procedure TOpusWriter.WriteOpusTags;
var
  Tags: TBytes;
  VendorStr: AnsiString;
  VL: Integer;
begin
  // RFC 7845 §5.2 OpusTags (minimal: vendor string + 0 comments)
  VendorStr := 'delphi-libraries/opus-encoder';
  VL := Length(VendorStr);

  SetLength(Tags, 8 + 4 + VL + 4);
  // Magic: 'OpusTags'
  Tags[0] := 79; Tags[1] := 112; Tags[2] := 117; Tags[3] := 115;
  Tags[4] := 84; Tags[5] := 97;  Tags[6] := 103; Tags[7] := 115;
  // Vendor string length (little-endian 32-bit)
  Tags[8] := VL and $FF;
  Tags[9] := (VL shr 8) and $FF;
  Tags[10] := 0; Tags[11] := 0;
  // Vendor string
  var VendorBytes := TEncoding.UTF8.GetBytes(string(VendorStr));
  Move(VendorBytes[0], Tags[12], Min(VL, Length(VendorBytes)));
  // User comment list length = 0
  Tags[12 + VL + 0] := 0;
  Tags[12 + VL + 1] := 0;
  Tags[12 + VL + 2] := 0;
  Tags[12 + VL + 3] := 0;

  FWriter.WritePacket(Tags, False, False, 0);
end;

procedure TOpusWriter.WriteFrame(PCM: PSmallInt);
var
  PacketBuf: array[0..OPUS_MAX_PACKET-1] of Byte;
  Len       : Integer;
  Packet    : TBytes;
begin
  FillChar(PacketBuf, SizeOf(PacketBuf), 0);
  Len := FEncoder.EncodeFrame(PCM, @PacketBuf[0], OPUS_MAX_PACKET);
  if Len <= 0 then Exit;

  SetLength(Packet, Len);
  Move(PacketBuf[0], Packet[0], Len);

  // Update granule position (samples at 48kHz)
  Inc(FGranule, FEncoder.FrameSize);
  var GPos: Int64 := Max(0, FGranule);

  FWriter.WritePacket(Packet, False, False, GPos);
end;

procedure TOpusWriter.Finish;
var
  Empty: TBytes;
begin
  SetLength(Empty, 0);
  FWriter.WritePacket(Empty, False, True {EOS}, FGranule);
end;

end.
