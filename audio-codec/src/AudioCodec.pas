unit AudioCodec;

{
  AudioCodec.pas - Unified audio decoder interface and factory

  Provides a single IAudioDecoder interface that covers all supported formats
  (WAV, FLAC, Ogg Vorbis, Ogg Opus) through format-specific adapters.

  Typical usage:

    var Dec: IAudioDecoder;
    var Buf: TAudioBuffer;

    Dec := CreateAudioDecoderFromFile('music.flac');
    if (Dec <> nil) and Dec.Ready then
    begin
      WriteLn(Dec.Info.SampleRate);
      while Dec.Decode(Buf) = adrOK do
        ProcessSamples(Buf, Dec.Info.Channels);
    end;

  Supported formats:
    WAV   — via TWAVReader (PCM 8/16/24/32, float 32/64, EXTENSIBLE)
    FLAC  — via TFLACStreamDecoder (lossless, all valid stream configurations)
    Vorbis — via OggPageReader + TVorbisDecoder (Ogg Vorbis I)
    Opus  — via TOpusDecoder (Ogg Opus / RFC 7845)

  Factory functions:
    CreateAudioDecoder(Stream, OwnsStream)  — from TStream
    CreateAudioDecoderFromFile(FileName)    — from file path (owns stream)

  The factory detects the format via AudioFormatDetect.DetectAudioFormat and
  returns nil when the format is unknown or the stream is unreadable.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Classes,
  AudioTypes,
  AudioFormatDetect;

// ---------------------------------------------------------------------------
// IAudioDecoder — unified decode interface
// ---------------------------------------------------------------------------

type
  IAudioDecoder = interface
    ['{8A4F9E1C-2B7D-4F3A-9C5E-1D8F2A6B3E7C}']
    // Decode the next block of samples.
    // Buffer is nil and Samples = 0 on non-OK results.
    // Returns adrOK, adrEndOfStream, adrCorrupted, or adrError.
    function Decode(out Buffer: TAudioBuffer): TAudioDecodeResult;

    // Metadata (available after construction; Ready = True).
    function GetInfo: TAudioInfo;

    // True once headers have been parsed and the decoder is ready for audio.
    function GetReady: Boolean;

    property Info : TAudioInfo read GetInfo;
    property Ready: Boolean    read GetReady;
  end;

// ---------------------------------------------------------------------------
// Factory functions
// ---------------------------------------------------------------------------

// Create a decoder for the given stream.
// The format is auto-detected; returns nil for unknown or invalid streams.
// If OwnsStream = True the adapter takes ownership and frees it on release.
function CreateAudioDecoder(AStream: TStream;
  OwnsStream: Boolean = False): IAudioDecoder;

// Create a decoder for the given file path.
// Returns nil if the file does not exist or the format is not supported.
// The returned decoder owns its internal stream.
function CreateAudioDecoderFromFile(const FileName: string): IAudioDecoder;

implementation

uses
  Math,
  OggTypes,
  OggPageReader,
  WAVTypes,
  WAVReader,
  FLACTypes,
  FLACStreamDecoder,
  VorbisTypes,
  VorbisDecoder,
  OpusDecoder;

// ===========================================================================
// WAV adapter
// ===========================================================================

type
  TWAVDecoderAdapter = class(TInterfacedObject, IAudioDecoder)
  private
    FReader : TWAVReader;
    FInfo   : TAudioInfo;
  public
    constructor Create(AStream: TStream; OwnsStream: Boolean);
    destructor  Destroy; override;
    function Decode(out Buffer: TAudioBuffer): TAudioDecodeResult;
    function GetInfo: TAudioInfo;
    function GetReady: Boolean;
  end;

constructor TWAVDecoderAdapter.Create(AStream: TStream; OwnsStream: Boolean);
var
  Fmt: TWAVFormat;
begin
  inherited Create;
  FReader := TWAVReader.Create;
  if not FReader.Open(AStream, OwnsStream) then Exit;

  Fmt := FReader.Format;
  FInfo.Format     := afWAV;
  FInfo.SampleRate := Fmt.SampleRate;
  FInfo.Channels   := Fmt.Channels;
  FInfo.BitDepth   := Fmt.BitsPerSample;
  FInfo.IsFloat    := (Fmt.FormatTag = WAVE_FORMAT_IEEE_FLOAT);
  FInfo.DurationMs := -1;
  FInfo.BitRate    := 0;
end;

destructor TWAVDecoderAdapter.Destroy;
begin
  FReader.Free;
  inherited Destroy;
end;

function TWAVDecoderAdapter.Decode(out Buffer: TAudioBuffer): TAudioDecodeResult;
var
  Buf: TAudioBuffer;
begin
  Buffer := nil;
  Buf    := nil;
  Result := FReader.Decode(Buf);
  Buffer := Buf;
end;

function TWAVDecoderAdapter.GetInfo: TAudioInfo;
begin
  Result := FInfo;
end;

function TWAVDecoderAdapter.GetReady: Boolean;
begin
  Result := FReader.Ready;
end;

// ===========================================================================
// FLAC adapter
// ===========================================================================

type
  TFLACDecoderAdapter = class(TInterfacedObject, IAudioDecoder)
  private
    FDecoder : TFLACStreamDecoder;
    FInfo    : TAudioInfo;
  public
    constructor Create(AStream: TStream; OwnsStream: Boolean);
    destructor  Destroy; override;
    function Decode(out Buffer: TAudioBuffer): TAudioDecodeResult;
    function GetInfo: TAudioInfo;
    function GetReady: Boolean;
  end;

constructor TFLACDecoderAdapter.Create(AStream: TStream; OwnsStream: Boolean);
var
  SI: TFLACStreamInfo;
begin
  inherited Create;
  FDecoder := TFLACStreamDecoder.Create;
  if not FDecoder.Open(AStream, OwnsStream) then Exit;

  SI := FDecoder.StreamInfo;
  FInfo.Format     := afFLAC;
  FInfo.SampleRate := SI.SampleRate;
  FInfo.Channels   := SI.Channels;
  FInfo.BitDepth   := SI.BitsPerSample;
  FInfo.IsFloat    := False;
  FInfo.DurationMs := IfThen(SI.SampleRate > 0,
                       Int64(SI.TotalSamples) * 1000 div SI.SampleRate, -1);
  FInfo.BitRate    := 0;
end;

destructor TFLACDecoderAdapter.Destroy;
begin
  FDecoder.Free;
  inherited Destroy;
end;

function TFLACDecoderAdapter.Decode(out Buffer: TAudioBuffer): TAudioDecodeResult;
var
  Buf: TAudioBuffer;
begin
  Buffer := nil;
  Buf    := nil;
  Result := FDecoder.Decode(Buf);
  Buffer := Buf;
end;

function TFLACDecoderAdapter.GetInfo: TAudioInfo;
begin
  Result := FInfo;
end;

function TFLACDecoderAdapter.GetReady: Boolean;
begin
  Result := FDecoder.Ready;
end;

// ===========================================================================
// Ogg Vorbis adapter
// ===========================================================================

type
  TVorbisOggAdapter = class(TInterfacedObject, IAudioDecoder)
  private
    FReader  : TOggPageReader;
    FDecoder : TVorbisDecoder;
    FInfo    : TAudioInfo;
  public
    constructor Create(AStream: TStream; OwnsStream: Boolean);
    destructor  Destroy; override;
    function Decode(out Buffer: TAudioBuffer): TAudioDecodeResult;
    function GetInfo: TAudioInfo;
    function GetReady: Boolean;
  end;

constructor TVorbisOggAdapter.Create(AStream: TStream; OwnsStream: Boolean);
var
  Pkt          : TOggPacket;
  OggRes       : TOggReadResult;
  Buf          : TAudioBuffer;
  Samples      : Integer;
  VRes         : TVorbisDecodeResult;
  HeadersRead  : Integer;
begin
  inherited Create;
  FReader  := TOggPageReader.Create(AStream, OwnsStream);
  FDecoder := TVorbisDecoder.Create;
  FInfo.Format := afVorbis;

  // Eagerly consume the three Vorbis header packets so the decoder is ready
  // and TAudioInfo is populated immediately after construction.
  HeadersRead := 0;
  while HeadersRead < 3 do
  begin
    OggRes := FReader.ReadPacket(Pkt);
    if OggRes <> orrPacket then Break;
    Buf     := nil;
    Samples := 0;
    VRes    := FDecoder.DecodePacket(@Pkt.Data[0], Pkt.Length, Buf, Samples);
    if VRes = vdrHeader then
      Inc(HeadersRead)
    else
      Break;
  end;

  if FDecoder.Ready then
  begin
    FInfo.SampleRate := FDecoder.SampleRate;
    FInfo.Channels   := FDecoder.Channels;
    FInfo.BitDepth   := 0;
    FInfo.IsFloat    := True;
    FInfo.DurationMs := -1;
    FInfo.BitRate    := 0;
  end;
end;

destructor TVorbisOggAdapter.Destroy;
begin
  FDecoder.Free;
  FReader.Free;
  inherited Destroy;
end;

function TVorbisOggAdapter.Decode(out Buffer: TAudioBuffer): TAudioDecodeResult;
var
  Pkt     : TOggPacket;
  OggRes  : TOggReadResult;
  Samples : Integer;
  VRes    : TVorbisDecodeResult;
begin
  Buffer := nil;
  repeat
    OggRes := FReader.ReadPacket(Pkt);
    if OggRes = orrEndOfStream then Exit(adrEndOfStream);
    if OggRes <> orrPacket    then Exit(adrCorrupted);

    Samples := 0;
    VRes := FDecoder.DecodePacket(@Pkt.Data[0], Pkt.Length, Buffer, Samples);

    case VRes of
      vdrOK:
        if Samples > 0 then Exit(adrOK);
        // else: empty packet (first audio frame produces no output); continue
      vdrHeader:
        ; // late header; ignore
      vdrEndOfStream:
        Exit(adrEndOfStream);
      vdrCorrupted:
        Exit(adrCorrupted);
      vdrError:
        Exit(adrError);
    end;
  until False;
end;

function TVorbisOggAdapter.GetInfo: TAudioInfo;
begin
  Result := FInfo;
end;

function TVorbisOggAdapter.GetReady: Boolean;
begin
  Result := FDecoder.Ready;
end;

// ===========================================================================
// Opus adapter
// ===========================================================================

type
  TOpusDecoderAdapter = class(TInterfacedObject, IAudioDecoder)
  private
    FDecoder : TOpusDecoder;
    FInfo    : TAudioInfo;
  public
    constructor Create(AStream: TStream; OwnsStream: Boolean);
    destructor  Destroy; override;
    function Decode(out Buffer: TAudioBuffer): TAudioDecodeResult;
    function GetInfo: TAudioInfo;
    function GetReady: Boolean;
  end;

constructor TOpusDecoderAdapter.Create(AStream: TStream; OwnsStream: Boolean);
begin
  inherited Create;
  FDecoder         := TOpusDecoder.Create(AStream, OwnsStream);
  FInfo.Format     := afOpus;
  FInfo.SampleRate := 48000;  // Opus always outputs 48kHz
  FInfo.Channels   := 0;      // updated on first successful Decode
  FInfo.BitDepth   := 0;
  FInfo.IsFloat    := True;
  FInfo.DurationMs := -1;
  FInfo.BitRate    := 0;
end;

destructor TOpusDecoderAdapter.Destroy;
begin
  FDecoder.Free;
  inherited Destroy;
end;

function TOpusDecoderAdapter.Decode(out Buffer: TAudioBuffer): TAudioDecodeResult;
var
  Samples: Integer;
begin
  Buffer  := nil;
  Samples := 0;
  Result  := FDecoder.Decode(Buffer, Samples);
  if Result = adrOK then
    FInfo.Channels := FDecoder.Channels;
end;

function TOpusDecoderAdapter.GetInfo: TAudioInfo;
begin
  Result := FInfo;
end;

function TOpusDecoderAdapter.GetReady: Boolean;
begin
  Result := FDecoder.Ready;
end;

// ===========================================================================
// Factory
// ===========================================================================

function CreateAudioDecoder(AStream: TStream;
  OwnsStream: Boolean): IAudioDecoder;
var
  Fmt: TAudioFormat;
begin
  Result := nil;
  if AStream = nil then Exit;

  Fmt := DetectAudioFormat(AStream);

  case Fmt of
    afWAV:
      Result := TWAVDecoderAdapter.Create(AStream, OwnsStream);
    afFLAC:
      Result := TFLACDecoderAdapter.Create(AStream, OwnsStream);
    afVorbis:
      Result := TVorbisOggAdapter.Create(AStream, OwnsStream);
    afOpus:
      Result := TOpusDecoderAdapter.Create(AStream, OwnsStream);
  else
    // afMP3 and afUnknown: not supported yet
    if OwnsStream then
      AStream.Free;
  end;
end;

function CreateAudioDecoderFromFile(const FileName: string): IAudioDecoder;
var
  FS: TFileStream;
begin
  Result := nil;
  if not FileExists(FileName) then Exit;
  try
    FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  except
    Exit;
  end;
  Result := CreateAudioDecoder(FS, True {owns});
end;

end.
