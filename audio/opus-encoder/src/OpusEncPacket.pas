unit OpusEncPacket;

{
  OpusEncPacket.pas - Capa de compatibilidad con la API anterior (OBSOLETA)

  TOpusCeltEncoder y TOpusWriter eran la API del encoder CELT experimental
  previo (no compatible con libopus). Se conservan con la misma firma, pero
  ahora delegan en el port fiel de libopus:
    - TOpusCeltEncoder -> TOpusEncoder (OPUS_APPLICATION_RESTRICTED_LOWDELAY,
      CELT siempre, CBR que usa los MaxLen bytes disponibles, como antes).
    - TOpusWriter      -> TOggOpusWriter.
  Código nuevo: usar TOpusEncoder (unit OpusEncoder) y TOggOpusWriter.

  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

interface

uses
  SysUtils, Classes,
  OpusEncTypes,
  OpusEncoder,
  OggOpusWriter;

const
  OPUS_MAX_PACKET = 1276;

type
  TOpusCeltEncoder = class
  private
    FEnc       : TOpusEncoder;
    FChannels  : Integer;
    FFrameSize : Integer;
    FLM        : Integer;
    FConfig    : Integer;
  public
    // FrameSizeMs: 5, 10 o 20 (cualquier otro valor: 20 ms, como antes).
    // SampleRate: 8000, 12000, 16000, 24000 o 48000.
    constructor Create(Channels, SampleRate, FrameSizeMs: Integer);
    destructor Destroy; override;
    // Codifica FrameSize muestras int16 intercaladas. Devuelve la longitud
    // del paquete (>= 1) o 0 si hay error.
    function EncodeFrame(PCM: PSmallInt; PacketBuf: PByte; MaxLen: Integer): Integer;
    property Channels  : Integer read FChannels;
    property FrameSize : Integer read FFrameSize;
    property LM        : Integer read FLM;
    property Config    : Integer read FConfig;   // config del TOC del último paquete
    property Encoder   : TOpusEncoder read FEnc;
  end deprecated 'Use TOpusEncoder (unit OpusEncoder)';

  TOpusWriter = class
  private
    FWriter   : TOggOpusWriter;
    FFrameSize: Integer;
  public
    constructor Create(AStream: TStream; Channels, SampleRate, FrameSizeMs: Integer;
      OwnsStream: Boolean = False);
    destructor Destroy; override;
    procedure WriteFrame(PCM: PSmallInt);   // FrameSize muestras intercaladas
    procedure Finish;
    property Writer: TOggOpusWriter read FWriter;
  end deprecated 'Use TOggOpusWriter (unit OggOpusWriter)';

implementation

constructor TOpusCeltEncoder.Create(Channels, SampleRate, FrameSizeMs: Integer);
begin
  inherited Create;
  FChannels := Channels;
  case FrameSizeMs of
    5 : FLM := 1;
    10: FLM := 2;
  else
    FLM := 3;
  end;
  FFrameSize := (SampleRate div 400) shl FLM;
  FEnc := TOpusEncoder.Create(SampleRate, Channels, oaRestrictedLowDelay);
  FEnc.Bitrate := OPUS_BITRATE_MAX;
  FEnc.Vbr := False;
  FConfig := 28 + FLM;
end;

destructor TOpusCeltEncoder.Destroy;
begin
  FEnc.Free;
  inherited;
end;

function TOpusCeltEncoder.EncodeFrame(PCM: PSmallInt; PacketBuf: PByte; MaxLen: Integer): Integer;
begin
  Result := FEnc.Encode(PCM, FFrameSize, PacketBuf, MaxLen);
  if Result <= 0 then
    Exit(0);
  FConfig := PacketBuf[0] shr 3;
end;

constructor TOpusWriter.Create(AStream: TStream; Channels, SampleRate, FrameSizeMs: Integer;
  OwnsStream: Boolean);
begin
  inherited Create;
  if not (FrameSizeMs in [5, 10, 20]) then
    FrameSizeMs := 20;
  FWriter := TOggOpusWriter.Create(AStream, SampleRate, Channels, oaAudio, FrameSizeMs * 10, OwnsStream);
  FFrameSize := FWriter.FrameSize;
end;

destructor TOpusWriter.Destroy;
begin
  FWriter.Free;
  inherited;
end;

procedure TOpusWriter.WriteFrame(PCM: PSmallInt);
begin
  FWriter.WriteInt16(PCM, FFrameSize);
end;

procedure TOpusWriter.Finish;
begin
  FWriter.Finish;
end;

end.
