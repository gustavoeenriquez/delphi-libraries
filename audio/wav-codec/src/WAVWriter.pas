unit WAVWriter;

{
  WAVWriter.pas - RIFF/WAVE file and stream writer

  Writes a WAV file from TAudioBuffer (planar Single [-1..1]).

  Supported output formats (choose at construction time):
    woPCM16    — 16-bit signed PCM  (default, widest compatibility)
    woPCM24    — 24-bit signed PCM  (lossless archival quality)
    woPCM32    — 32-bit signed PCM
    woFloat32  — 32-bit IEEE float

  For > 2 channels, writes WAVE_FORMAT_EXTENSIBLE automatically.

  Usage:
    var W: TWAVWriter;
    W := TWAVWriter.Create('out.wav', 44100, 2, woPCM16);
    try
      while HaveData do
        W.WriteSamples(Buffer);
      W.Finalize;
    finally
      W.Free;
    end;

  Note: Finalize is also called by the destructor, but call it explicitly
  when you need to verify the final file is complete before freeing.

  This unit replaces the earlier WAVWriter.pas in mp3-decoder/src/ and
  extends it with:
    - TAudioBuffer planar input (vs. separate Left/Right arrays)
    - 24-bit and 32-bit PCM output
    - 32-bit IEEE float output
    - Multichannel (> 2 channels) via WAVE_FORMAT_EXTENSIBLE
    - Stream-based output (not just file path)

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Classes,
  AudioTypes,
  AudioSampleConv,
  WAVTypes;

type
  // Output sample format
  TWAVOutputFormat = (
    woPCM16,   // 16-bit signed PCM  (2 bytes/sample)
    woPCM24,   // 24-bit signed PCM  (3 bytes/sample)
    woPCM32,   // 32-bit signed PCM  (4 bytes/sample)
    woFloat32  // 32-bit IEEE float  (4 bytes/sample)
  );

type
  TWAVWriter = class
  private
    FStream          : TStream;
    FOwnsStream      : Boolean;
    FSampleRate      : Cardinal;
    FChannels        : Word;
    FOutputFormat    : TWAVOutputFormat;
    FBitsPerSample   : Word;
    FBytesPerSample  : Word;
    FBytesPerFrame   : Word;
    FIsFloat         : Boolean;
    FDataSize        : Cardinal;  // bytes written to data chunk
    FRIFFSizeOffset  : Int64;
    FDataSizeOffset  : Int64;
    FFinalized       : Boolean;

    procedure WriteLE16(V: Word);
    procedure WriteLE32(V: Cardinal);
    procedure WriteTag(const Tag: AnsiString);
    procedure WriteHeader;

  public
    // Create writing to a file path.
    constructor Create(const FileName: string;
      SampleRate: Cardinal; Channels: Word;
      OutputFormat: TWAVOutputFormat = woPCM16); overload;

    // Create writing to an existing stream.
    // If OwnsStream = True, stream is freed on Finalize/Destroy.
    constructor Create(AStream: TStream;
      SampleRate: Cardinal; Channels: Word;
      OutputFormat: TWAVOutputFormat = woPCM16;
      OwnsStream: Boolean = False); overload;

    destructor Destroy; override;

    // Write FrameCount frames from Buffer (planar, all channels must have >= FrameCount samples).
    // Returns aerOK or aerError.
    function WriteSamples(const Buffer: TAudioBuffer; FrameCount: Integer = -1): TAudioEncodeResult;

    // Patch the RIFF and data chunk sizes in the header. Must be called once when done.
    // Safe to call multiple times (subsequent calls are no-ops).
    procedure Finalize;

    property SampleRate   : Cardinal        read FSampleRate;
    property Channels     : Word            read FChannels;
    property OutputFormat : TWAVOutputFormat read FOutputFormat;
    property DataBytesWritten: Cardinal     read FDataSize;
  end;

implementation

// ---------------------------------------------------------------------------
// Constructor / Destructor
// ---------------------------------------------------------------------------

constructor TWAVWriter.Create(const FileName: string;
  SampleRate: Cardinal; Channels: Word; OutputFormat: TWAVOutputFormat);
var
  S: TFileStream;
begin
  S := TFileStream.Create(FileName, fmCreate);
  Create(S, SampleRate, Channels, OutputFormat, True {owns});
end;

constructor TWAVWriter.Create(AStream: TStream;
  SampleRate: Cardinal; Channels: Word;
  OutputFormat: TWAVOutputFormat; OwnsStream: Boolean);
begin
  inherited Create;
  FStream       := AStream;
  FOwnsStream   := OwnsStream;
  FSampleRate   := SampleRate;
  FChannels     := Channels;
  FOutputFormat := OutputFormat;
  FDataSize     := 0;
  FFinalized    := False;

  case OutputFormat of
    woPCM16  : begin FBitsPerSample := 16; FBytesPerSample := 2; FIsFloat := False; end;
    woPCM24  : begin FBitsPerSample := 24; FBytesPerSample := 3; FIsFloat := False; end;
    woPCM32  : begin FBitsPerSample := 32; FBytesPerSample := 4; FIsFloat := False; end;
    woFloat32: begin FBitsPerSample := 32; FBytesPerSample := 4; FIsFloat := True;  end;
  end;

  FBytesPerFrame := FChannels * FBytesPerSample;
  WriteHeader;
end;

destructor TWAVWriter.Destroy;
begin
  Finalize;
  if FOwnsStream then
    FreeAndNil(FStream);
  inherited Destroy;
end;

// ---------------------------------------------------------------------------
// Low-level write helpers
// ---------------------------------------------------------------------------

procedure TWAVWriter.WriteLE16(V: Word);
var B: array[0..1] of Byte;
begin
  B[0] := V and $FF;
  B[1] := (V shr 8) and $FF;
  FStream.WriteBuffer(B, 2);
end;

procedure TWAVWriter.WriteLE32(V: Cardinal);
var B: array[0..3] of Byte;
begin
  B[0] :=  V         and $FF;
  B[1] := (V shr  8) and $FF;
  B[2] := (V shr 16) and $FF;
  B[3] := (V shr 24) and $FF;
  FStream.WriteBuffer(B, 4);
end;

procedure TWAVWriter.WriteTag(const Tag: AnsiString);
begin
  FStream.WriteBuffer(Tag[1], Length(Tag));
end;

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

procedure TWAVWriter.WriteHeader;
var
  UseExtensible: Boolean;
  FormatTag    : Word;
  FmtChunkSize : Cardinal;
  ByteRate     : Cardinal;
begin
  // Use EXTENSIBLE for > 2 channels or for 32-bit float (best practice)
  UseExtensible := (FChannels > 2) or (FOutputFormat = woFloat32) or
                   (FOutputFormat = woPCM32);

  if UseExtensible then
    FormatTag := WAVE_FORMAT_EXTENSIBLE
  else if FIsFloat then
    FormatTag := WAVE_FORMAT_IEEE_FLOAT
  else
    FormatTag := WAVE_FORMAT_PCM;

  // fmt chunk size: 16 (base) + 2 (cbSize) + 22 (extensible) if applicable
  if UseExtensible then
    FmtChunkSize := 40   // 16 + 2 + 22
  else
    FmtChunkSize := 16;  // classic PCM (no cbSize for pure PCM, but we write it as 18 for IEEE_FLOAT)

  // For WAVE_FORMAT_IEEE_FLOAT without extensible, cbSize = 0 must be written (fmt = 18 bytes)
  if (not UseExtensible) and FIsFloat then
    FmtChunkSize := 18;

  ByteRate := FSampleRate * FBytesPerFrame;

  // RIFF header
  WriteTag('RIFF');
  FRIFFSizeOffset := FStream.Position;
  WriteLE32(0);        // placeholder
  WriteTag('WAVE');

  // fmt chunk
  WriteTag('fmt ');
  WriteLE32(FmtChunkSize);
  WriteLE16(FormatTag);
  WriteLE16(FChannels);
  WriteLE32(FSampleRate);
  WriteLE32(ByteRate);
  WriteLE16(FBytesPerFrame);
  WriteLE16(FBitsPerSample);

  if UseExtensible then
  begin
    WriteLE16(22);           // cbSize = 22
    WriteLE16(FBitsPerSample); // wValidBitsPerSample
    // Channel mask
    case FChannels of
      1: WriteLE32(SPEAKER_MONO);
      2: WriteLE32(SPEAKER_STEREO);
      4: WriteLE32(SPEAKER_QUAD);
      6: WriteLE32(SPEAKER_SURROUND_5_1);
      8: WriteLE32(SPEAKER_SURROUND_7_1);
    else
      WriteLE32(0); // unspecified
    end;
    // SubFormat GUID
    if FIsFloat then
    begin
      WriteLE32(KSDATAFORMAT_SUBTYPE_IEEE_FLOAT_DATA1);
    end
    else
    begin
      WriteLE32(KSDATAFORMAT_SUBTYPE_PCM_DATA1);
    end;
    // Remaining 12 bytes of GUID (standard Microsoft PCM/float GUID tail)
    WriteLE32($00100000);
    WriteLE32($AA000080);
    WriteLE32($719B3800);
  end
  else if FIsFloat then
  begin
    WriteLE16(0);  // cbSize = 0
  end;

  // data chunk header
  WriteTag('data');
  FDataSizeOffset := FStream.Position;
  WriteLE32(0);  // placeholder
end;

// ---------------------------------------------------------------------------
// WriteSamples
// ---------------------------------------------------------------------------

function TWAVWriter.WriteSamples(const Buffer: TAudioBuffer; FrameCount: Integer): TAudioEncodeResult;
var
  Ch, Frame: Integer;
  Actual   : Integer;
  V16      : SmallInt;
  V32      : Integer;
  VF       : Single;
  PBuf     : array[0..2] of Byte;
begin
  if FFinalized then Exit(aerError);
  if Length(Buffer) = 0 then Exit(aerOK);

  // Determine actual frame count
  if FrameCount < 0 then
    Actual := Length(Buffer[0])
  else
    Actual := FrameCount;

  if Actual <= 0 then Exit(aerOK);

  // Verify all channels have enough samples
  for Ch := 0 to FChannels - 1 do
    if Ch >= Length(Buffer) then Exit(aerError)
    else if Length(Buffer[Ch]) < Actual then
      Actual := Length(Buffer[Ch]);

  // Write interleaved samples
  for Frame := 0 to Actual - 1 do
    for Ch := 0 to FChannels - 1 do
    begin
      VF := Buffer[Ch][Frame];

      case FOutputFormat of
        woPCM16:
          begin
            V16 := SampleFloatToInt16(VF);
            FStream.WriteBuffer(V16, 2);
            Inc(FDataSize, 2);
          end;
        woPCM24:
          begin
            SampleFloatToInt24(VF, @PBuf[0]);
            FStream.WriteBuffer(PBuf, 3);
            Inc(FDataSize, 3);
          end;
        woPCM32:
          begin
            V32 := SampleFloatToInt32(VF);
            FStream.WriteBuffer(V32, 4);
            Inc(FDataSize, 4);
          end;
        woFloat32:
          begin
            VF := SampleFloatToFloat32(VF);
            FStream.WriteBuffer(VF, 4);
            Inc(FDataSize, 4);
          end;
      end;
    end;

  Result := aerOK;
end;

// ---------------------------------------------------------------------------
// Finalize
// ---------------------------------------------------------------------------

procedure TWAVWriter.Finalize;
var
  RIFFSize: Cardinal;
begin
  if FFinalized or not Assigned(FStream) then Exit;
  FFinalized := True;

  // Pad data chunk to even size (WAV chunk alignment requirement)
  if (FDataSize and 1) <> 0 then
  begin
    var Pad: Byte := 0;
    FStream.WriteBuffer(Pad, 1);
  end;

  // Patch data chunk size
  FStream.Seek(FDataSizeOffset, soBeginning);
  WriteLE32(FDataSize);

  // Patch RIFF chunk size = total file size - 8
  // = 4 (WAVE) + 8+FmtChunkSize (fmt) + 8+DataSize (+pad) (data)
  RIFFSize := Cardinal(FStream.Size) - 8;
  FStream.Seek(FRIFFSizeOffset, soBeginning);
  WriteLE32(RIFFSize);

  // Return to end
  FStream.Seek(0, soEnd);
end;

end.
