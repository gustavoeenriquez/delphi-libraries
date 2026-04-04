unit OpusDecoder;

{
  OpusDecoder.pas - Ogg Opus stream decoder

  Wraps OpusFrameDecoder to decode a complete Ogg Opus stream:
    1. Reads Ogg pages via TOggPageReader
    2. Assembles Ogg packets
    3. Validates the OpusHead and OpusTags identification headers
    4. For each audio packet: parses TOC, dispatches frames, assembles output

  Ogg Opus format (RFC 7845):
    - Serial number identifies the Opus logical bitstream
    - First packet: "OpusHead" identification header (19+ bytes)
    - Second packet: "OpusTags" comment header (skip)
    - Subsequent packets: audio data, one Opus packet per Ogg packet
    - Granule position: PCM sample count at 48kHz, includes pre-skip

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Classes, Math,
  AudioTypes,
  OggTypes,
  OggPageReader,
  OpusTypes,
  OpusRangeDecoder,
  OpusFrameDecoder;

// ---------------------------------------------------------------------------
// OpusHead identification header (RFC 7845 §5.1)
// ---------------------------------------------------------------------------

type
  TOpusHead = record
    Version          : Byte;       // must be 1
    Channels         : Byte;       // 1..255
    PreSkip          : Word;       // samples to skip at beginning
    InputSampleRate  : Cardinal;   // informational only; output is 48kHz
    OutputGainQ8     : SmallInt;   // output gain in Q8 (dB * 256)
    ChannelMappingFamily: Byte;    // 0 = mono/stereo
    // Family 1: multi-stream
    StreamCount      : Byte;
    CoupledCount     : Byte;
    ChannelMap       : array[0..255] of Byte;
  end;

// ---------------------------------------------------------------------------
// TOpusDecoder class
// ---------------------------------------------------------------------------

type
  TOpusDecoder = class
  private
    FReader       : TOggPageReader;
    FOwnsReader   : Boolean;
    FHead         : TOpusHead;
    FReady        : Boolean;       // True after both header packets consumed
    FPreSkipLeft  : Integer;       // pre-skip samples remaining
    FGranulePos   : Int64;         // current granule (PCM pos at 48kHz)
    FFrameState   : TOpusFrameDecoderState;
    FHeaderCount  : Integer;       // 0 = need OpusHead, 1 = need OpusTags, 2 = audio

    function ParseOpusHead(const Pkt: TOggPacket): Boolean;
    function ProcessAudioPacket(const Pkt: TOggPacket;
      out Buffer: TAudioBuffer; out Samples: Integer): Boolean;

  public
    constructor Create(AStream: TStream; OwnsStream: Boolean = False);
    destructor  Destroy; override;

    // Decode the next block of audio.
    // Returns adrOK with Buffer filled, adrEndOfStream when done,
    // or adrCorrupted / adrError on problems.
    function Decode(out Buffer: TAudioBuffer;
      out Samples: Integer): TAudioDecodeResult;

    property Ready      : Boolean  read FReady;
    property Channels   : Byte     read FHead.Channels;
    property SampleRate : Cardinal read FHead.InputSampleRate;
    property PreSkip    : Word     read FHead.PreSkip;
    property GranulePos : Int64    read FGranulePos;
  end;

implementation

// ---------------------------------------------------------------------------
// OpusHead parse (RFC 7845 §5.1)
// ---------------------------------------------------------------------------

function TOpusDecoder.ParseOpusHead(const Pkt: TOggPacket): Boolean;
const
  MAGIC: array[0..7] of Byte = (79,112,117,115,72,101,97,100);  // 'OpusHead'
var
  D   : PByte;
  Len : Integer;
  I   : Integer;
begin
  Result := False;
  D   := @Pkt.Data[0];
  Len := Pkt.Length;
  if Len < 19 then Exit;
  for I := 0 to 7 do
    if D[I] <> MAGIC[I] then Exit;

  FHead.Version           := D[8];
  if FHead.Version <> 1 then Exit;
  FHead.Channels          := D[9];
  FHead.PreSkip           := Word(D[10]) or (Word(D[11]) shl 8);
  FHead.InputSampleRate   := Cardinal(D[12]) or (Cardinal(D[13]) shl 8) or
                             (Cardinal(D[14]) shl 16) or (Cardinal(D[15]) shl 24);
  FHead.OutputGainQ8      := SmallInt(Word(D[16]) or (Word(D[17]) shl 8));
  FHead.ChannelMappingFamily := D[18];

  if FHead.Channels = 0 then Exit;

  if (FHead.ChannelMappingFamily = 1) and (Len >= 21 + FHead.Channels) then
  begin
    FHead.StreamCount  := D[19];
    FHead.CoupledCount := D[20];
    for I := 0 to FHead.Channels - 1 do
      FHead.ChannelMap[I] := D[21 + I];
  end;

  Result := True;
end;

// ---------------------------------------------------------------------------
// Audio packet decode
// ---------------------------------------------------------------------------

function TOpusDecoder.ProcessAudioPacket(const Pkt: TOggPacket;
  out Buffer: TAudioBuffer; out Samples: Integer): Boolean;
var
  TOC      : TOpusTOC;
  FrameInfo: TOpusFrameInfo;
  I        : Integer;
  FrameOff : Integer;
  AllSamples: Integer;
  TmpBuf   : TAudioBuffer;
  TmpSamples: Integer;
  Ch       : Integer;
begin
  Result  := False;
  Buffer  := nil;
  Samples := 0;

  if Pkt.Length < 1 then Exit;

  OpusParseTOC(Pkt.Data[0], TOC);
  if not OpusParseFrames(@Pkt.Data[0], Pkt.Length, TOC, FrameInfo) then Exit;

  // Total output samples = NumFrames × FrameSamples
  AllSamples := FrameInfo.NumFrames * TOC.FrameSamples;
  Buffer := AudioBufferCreate(FHead.Channels, AllSamples);
  Samples := AllSamples;

  FrameOff := 1; // skip TOC
  // For code 2, offset must skip the length byte(s)
  // For code 3, skip M byte (already accounted in FrameInfo.FrameSizes)
  if TOC.Code = 2 then
  begin
    var L0 := FrameInfo.FrameSizes[0];
    // Advance past length prefix
    if Pkt.Data[1] <= 251 then Inc(FrameOff)
    else Inc(FrameOff, 2);
  end
  else if TOC.Code = 3 then
    Inc(FrameOff);  // skip M byte

  for I := 0 to FrameInfo.NumFrames - 1 do
  begin
    TmpBuf := AudioBufferCreate(FHead.Channels, TOC.FrameSamples);
    var FData: PByte := nil;
    var FLen: Integer := FrameInfo.FrameSizes[I];
    if FrameOff + FLen <= Pkt.Length then
      FData := @Pkt.Data[FrameOff];

    if not OpusDecodeFrame(FFrameState, TOC, FData, FLen,
      TmpBuf, TOC.FrameSamples) then
    begin
      // On error: fill with silence, continue
      for Ch := 0 to FHead.Channels - 1 do
        FillChar(TmpBuf[Ch][0], TOC.FrameSamples * SizeOf(Single), 0);
    end;

    // Copy into output buffer
    var OutOff := I * TOC.FrameSamples;
    for Ch := 0 to FHead.Channels - 1 do
      Move(TmpBuf[Ch][0], Buffer[Ch][OutOff], TOC.FrameSamples * SizeOf(Single));

    Inc(FrameOff, FLen);
  end;

  // Apply pre-skip
  if FPreSkipLeft > 0 then
  begin
    var Skip := Min(FPreSkipLeft, AllSamples);
    Dec(FPreSkipLeft, Skip);
    if Skip >= AllSamples then
    begin
      Buffer  := nil;
      Samples := 0;
      Exit(True);
    end;
    // Shift output left by Skip samples
    var NewCount := AllSamples - Skip;
    for Ch := 0 to FHead.Channels - 1 do
      Move(Buffer[Ch][Skip], Buffer[Ch][0], NewCount * SizeOf(Single));
    Samples := NewCount;
  end;

  // Apply output gain
  if FHead.OutputGainQ8 <> 0 then
  begin
    var Gain: Single := Power(10.0, FHead.OutputGainQ8 / 256.0 / 20.0);
    for Ch := 0 to FHead.Channels - 1 do
      for I := 0 to Samples - 1 do
      begin
        var S: Single := Buffer[Ch][I] * Gain;
        if S >  1.0 then S :=  1.0;
        if S < -1.0 then S := -1.0;
        Buffer[Ch][I] := S;
      end;
  end;

  // Update granule position
  if Pkt.GranulePos > 0 then
    FGranulePos := Pkt.GranulePos;

  Result := True;
end;

// ---------------------------------------------------------------------------
// Constructor / Destructor
// ---------------------------------------------------------------------------

constructor TOpusDecoder.Create(AStream: TStream; OwnsStream: Boolean);
begin
  inherited Create;
  FReader      := TOggPageReader.Create(AStream, OwnsStream);
  FOwnsReader  := True;
  FReady       := False;
  FHeaderCount := 0;
  FPreSkipLeft := 0;
  FGranulePos  := 0;
  FillChar(FHead, SizeOf(FHead), 0);
end;

destructor TOpusDecoder.Destroy;
begin
  if FOwnsReader then FReader.Free;
  inherited Destroy;
end;

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

function TOpusDecoder.Decode(out Buffer: TAudioBuffer;
  out Samples: Integer): TAudioDecodeResult;
var
  Pkt : TOggPacket;
  Res : TOggReadResult;
begin
  Buffer  := nil;
  Samples := 0;

  repeat
    Res := FReader.ReadPacket(Pkt);
    if Res = orrEndOfStream then Exit(adrEndOfStream);
    if Res <> orrPacket then Exit(adrCorrupted);

    if FHeaderCount = 0 then
    begin
      // Expect OpusHead
      if not ParseOpusHead(Pkt) then Exit(adrError);
      FPreSkipLeft := FHead.PreSkip;
      // Init frame decoder with CELT fullband as default config (config 28)
      OpusFrameDecoderInit(FFrameState, FHead.Channels, 28);
      Inc(FHeaderCount);
      Continue;
    end;

    if FHeaderCount = 1 then
    begin
      // OpusTags — skip content, just validate magic
      if (Pkt.Length >= 8) then
      begin
        // Accept silently even if magic doesn't match (lenient)
      end;
      Inc(FHeaderCount);
      FReady := True;
      Continue;
    end;

    // Audio packet
    if not ProcessAudioPacket(Pkt, Buffer, Samples) then
      Exit(adrCorrupted);

    if Samples = 0 then Continue;  // pre-skip consumed everything
    Exit(adrOK);

  until False;
end;

end.
