unit WAVReader;

{
  WAVReader.pas - RIFF/WAVE file and stream reader

  Decodes any standard WAV file into TAudioBuffer (planar Single [-1..1]).

  Supported formats:
    WAVE_FORMAT_PCM        — 8-bit unsigned, 16/24/32-bit signed
    WAVE_FORMAT_IEEE_FLOAT — 32-bit and 64-bit IEEE float
    WAVE_FORMAT_EXTENSIBLE — multichannel wrappers for the above

  Usage:
    var R: TWAVReader;
    R := TWAVReader.Create;
    try
      if R.Open('track.wav') then
      begin
        WriteLn(R.Format.SampleRate);      // e.g. 44100
        WriteLn(R.Format.Channels);        // e.g. 2
        while R.Decode(Buffer) = adrOK do
          ProcessBuffer(Buffer);
      end;
    finally
      R.Free;
    end;

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
  TWAVReader = class
  private
    FStream      : TStream;
    FOwnsStream  : Boolean;
    FFormat      : TWAVFormat;
    FBytesRead   : Cardinal;  // bytes consumed from data chunk so far
    FReady       : Boolean;

    function ReadLE16: Word;
    function ReadLE32: Cardinal;
    function SkipBytes(N: Integer): Boolean;
    function ParseHeader: Boolean;
    function ParseFmtChunk(ChunkSize: Cardinal): Boolean;

  public
    constructor Create;
    destructor Destroy; override;

    // Open a file by path. Returns True on success.
    function Open(const FileName: string): Boolean; overload;

    // Open from an existing stream. If OwnsStream = True, stream is freed on Close/Destroy.
    function Open(AStream: TStream; OwnsStream: Boolean = False): Boolean; overload;

    // Close and release resources.
    procedure Close;

    // Decode up to FrameCount sample frames into Buffer.
    // Buffer is resized to the actual number of frames decoded.
    // Returns adrOK (frames decoded), adrEndOfStream, or adrError.
    function Decode(var Buffer: TAudioBuffer; FrameCount: Integer = 4096): TAudioDecodeResult;

    // Seek to a specific frame (0-based). Only works on seekable streams.
    // Returns False if seeking is not supported or index is out of range.
    function SeekToFrame(FrameIndex: Cardinal): Boolean;

    property Format: TWAVFormat read FFormat;
    property Ready : Boolean    read FReady;

    // Remaining frames (0 if unknown / streaming)
    function FramesLeft: Cardinal;
  end;

implementation

// ---------------------------------------------------------------------------
// Constructor / Destructor
// ---------------------------------------------------------------------------

constructor TWAVReader.Create;
begin
  inherited Create;
  FStream     := nil;
  FOwnsStream := False;
  FReady      := False;
  FBytesRead  := 0;
  FillChar(FFormat, SizeOf(FFormat), 0);
end;

destructor TWAVReader.Destroy;
begin
  Close;
  inherited Destroy;
end;

// ---------------------------------------------------------------------------
// Low-level stream helpers (little-endian)
// ---------------------------------------------------------------------------

function TWAVReader.ReadLE16: Word;
var B: array[0..1] of Byte;
begin
  if FStream.Read(B, 2) <> 2 then Exit(0);
  Result := Word(B[0]) or (Word(B[1]) shl 8);
end;

function TWAVReader.ReadLE32: Cardinal;
var B: array[0..3] of Byte;
begin
  if FStream.Read(B, 4) <> 4 then Exit(0);
  Result := Cardinal(B[0]) or (Cardinal(B[1]) shl 8) or
            (Cardinal(B[2]) shl 16) or (Cardinal(B[3]) shl 24);
end;

function TWAVReader.SkipBytes(N: Integer): Boolean;
begin
  Result := FStream.Seek(N, soCurrent) >= 0;
end;

// ---------------------------------------------------------------------------
// Open
// ---------------------------------------------------------------------------

function TWAVReader.Open(const FileName: string): Boolean;
var S: TFileStream;
begin
  Result := False;
  try
    S := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  except
    Exit;
  end;
  Result := Open(S, True {owns});
  if not Result then S.Free;
end;

function TWAVReader.Open(AStream: TStream; OwnsStream: Boolean): Boolean;
begin
  Close;
  FStream     := AStream;
  FOwnsStream := OwnsStream;
  FBytesRead  := 0;
  FReady      := ParseHeader;
  Result      := FReady;
end;

procedure TWAVReader.Close;
begin
  FReady := False;
  if FOwnsStream then
    FreeAndNil(FStream)
  else
    FStream := nil;
  FBytesRead := 0;
  FillChar(FFormat, SizeOf(FFormat), 0);
end;

// ---------------------------------------------------------------------------
// Header parsing
// ---------------------------------------------------------------------------

function TWAVReader.ParseFmtChunk(ChunkSize: Cardinal): Boolean;
var
  FormatTag : Word;
  Channels  : Word;
  SampleRate: Cardinal;
  AvgBytes  : Cardinal;
  BlockAlign: Word;
  BitsPerSample: Word;
  cbSize    : Word;
  ValidBits : Word;
  ChannelMask: Cardinal;
  SubFmt    : array[0..15] of Byte;
  BytesRead : Integer;
begin
  Result := False;
  if ChunkSize < 16 then Exit;

  FormatTag    := ReadLE16;
  Channels     := ReadLE16;
  SampleRate   := ReadLE32;
  AvgBytes     := ReadLE32;
  BlockAlign   := ReadLE16;
  BitsPerSample:= ReadLE16;
  BytesRead    := 16;

  // cbSize field (only if ChunkSize >= 18)
  cbSize := 0;
  if ChunkSize >= 18 then
  begin
    cbSize    := ReadLE16;
    Inc(BytesRead, 2);
  end;

  // EXTENSIBLE extra fields (cbSize = 22)
  ValidBits   := BitsPerSample;
  ChannelMask := 0;
  FillChar(SubFmt, SizeOf(SubFmt), 0);
  var WasExtensible := (FormatTag = WAVE_FORMAT_EXTENSIBLE);

  if WasExtensible and (cbSize >= 22) then
  begin
    ValidBits   := ReadLE16;
    ChannelMask := ReadLE32;
    FStream.Read(SubFmt, 16);
    Inc(BytesRead, 22);
    // Determine actual sub-format from GUID data1 field
    var SubData1 := Cardinal(SubFmt[0]) or (Cardinal(SubFmt[1]) shl 8) or
                    (Cardinal(SubFmt[2]) shl 16) or (Cardinal(SubFmt[3]) shl 24);
    if SubData1 = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT_DATA1 then
      FormatTag := WAVE_FORMAT_IEEE_FLOAT
    else
      FormatTag := WAVE_FORMAT_PCM;
  end;

  // Skip any remaining bytes in this fmt chunk
  var Remaining := Integer(ChunkSize) - BytesRead;
  if Remaining > 0 then
    SkipBytes(Remaining);

  // Validate
  if Channels = 0 then Exit;
  if (BitsPerSample = 0) or (BitsPerSample mod 8 <> 0) then Exit;
  if FormatTag = WAVE_FORMAT_PCM then
  begin
    if not (BitsPerSample in [8, 16, 24, 32]) then Exit;
  end
  else if FormatTag = WAVE_FORMAT_IEEE_FLOAT then
  begin
    if not (BitsPerSample in [32, 64]) then Exit;
  end
  else
    Exit; // unsupported

  FFormat.FormatTag          := FormatTag;
  FFormat.Channels           := Channels;
  FFormat.SampleRate         := SampleRate;
  FFormat.BitsPerSample      := BitsPerSample;
  FFormat.ValidBitsPerSample := ValidBits;
  FFormat.IsFloat            := (FormatTag = WAVE_FORMAT_IEEE_FLOAT);
  FFormat.IsExtensible       := WasExtensible;
  FFormat.ChannelMask        := ChannelMask;
  FFormat.BytesPerFrame      := BlockAlign;
  Result := True;

  // Suppress unused warning
  if AvgBytes = 0 then ;
end;

function TWAVReader.ParseHeader: Boolean;
var
  ChunkID  : Cardinal;
  ChunkSize: Cardinal;
  WaveID   : Cardinal;
  FmtFound : Boolean;
  DataFound: Boolean;
  ChunkEnd : Int64;
begin
  Result    := False;
  FmtFound  := False;
  DataFound := False;

  // RIFF header
  ChunkID := ReadLE32;
  if ChunkID <> FOURCC_RIFF then Exit;

  ChunkSize := ReadLE32;  // file size - 8, not used directly

  WaveID := ReadLE32;
  if WaveID <> FOURCC_WAVE then Exit;

  // Scan chunks until fmt + data are both found
  while (not FmtFound or not DataFound) and (FStream.Position < FStream.Size) do
  begin
    ChunkID   := ReadLE32;
    ChunkSize := ReadLE32;
    ChunkEnd  := FStream.Position + ChunkSize;

    if ChunkID = FOURCC_fmt then
    begin
      if not ParseFmtChunk(ChunkSize) then Exit;
      FmtFound := True;
      // ParseFmtChunk already consumed ChunkSize bytes
      // Seek to ChunkEnd in case of rounding (chunks must be word-aligned)
      FStream.Seek(ChunkEnd, soBeginning);
    end
    else if ChunkID = FOURCC_data then
    begin
      if not FmtFound then Exit;  // data before fmt is invalid
      FFormat.DataOffset := FStream.Position;
      FFormat.DataBytes  := ChunkSize;
      FFormat.FrameCount := WAVCalcFrameCount(FFormat);
      DataFound := True;
      // Stay positioned at start of data — do NOT skip past it
    end
    else
    begin
      // Unknown/irrelevant chunk — skip. Pad to even byte boundary.
      var Skip := Int64(ChunkSize) + (ChunkSize and 1);
      FStream.Seek(Skip, soCurrent);
    end;
  end;

  Result := FmtFound and DataFound;
end;

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

function TWAVReader.Decode(var Buffer: TAudioBuffer; FrameCount: Integer): TAudioDecodeResult;
var
  Channels    : Integer;
  BytesPerSamp: Integer;  // bytes per single sample in one channel
  BytesPerFrame: Integer;
  MaxFrames   : Integer;
  Actual      : Integer;
  RawBytes    : Integer;
  Raw         : TBytes;
  Frame, Ch   : Integer;
  SrcBase     : PByte;
  S           : Single;
begin
  if not FReady then Exit(adrError);

  Channels      := FFormat.Channels;
  BytesPerFrame := FFormat.BytesPerFrame;
  BytesPerSamp  := FFormat.BitsPerSample div 8;

  // How many frames can we still read?
  if FFormat.DataBytes > 0 then
  begin
    var BytesLeft := FFormat.DataBytes - FBytesRead;
    MaxFrames := Integer(BytesLeft div Cardinal(BytesPerFrame));
    if MaxFrames <= 0 then Exit(adrEndOfStream);
    if FrameCount > MaxFrames then
      FrameCount := MaxFrames;
  end;

  RawBytes := FrameCount * BytesPerFrame;
  SetLength(Raw, RawBytes);

  Actual := FStream.Read(Raw[0], RawBytes);
  if Actual <= 0 then Exit(adrEndOfStream);

  // Align to complete frames
  Actual := (Actual div BytesPerFrame) * BytesPerFrame;
  if Actual = 0 then Exit(adrEndOfStream);

  Actual := Actual div BytesPerFrame;  // now = frame count

  // Resize output buffer
  if Length(Buffer) <> Channels then
    SetLength(Buffer, Channels);
  for Ch := 0 to Channels - 1 do
    SetLength(Buffer[Ch], Actual);

  // Decode each frame
  Inc(FBytesRead, Cardinal(Actual * BytesPerFrame));

  case FFormat.BitsPerSample of
    8:
      for Frame := 0 to Actual - 1 do
      begin
        SrcBase := @Raw[Frame * BytesPerFrame];
        for Ch := 0 to Channels - 1 do
        begin
          // 8-bit WAV PCM is unsigned (0..255)
          Buffer[Ch][Frame] := SampleUInt8ToFloat(SrcBase^);
          Inc(SrcBase);
        end;
      end;

    16:
      for Frame := 0 to Actual - 1 do
      begin
        SrcBase := @Raw[Frame * BytesPerFrame];
        for Ch := 0 to Channels - 1 do
        begin
          var V: SmallInt := SmallInt(Word(SrcBase^) or (Word((SrcBase+1)^) shl 8));
          Buffer[Ch][Frame] := SampleInt16ToFloat(V);
          Inc(SrcBase, 2);
        end;
      end;

    24:
      for Frame := 0 to Actual - 1 do
      begin
        SrcBase := @Raw[Frame * BytesPerFrame];
        for Ch := 0 to Channels - 1 do
        begin
          Buffer[Ch][Frame] := SampleInt24ToFloat(SrcBase);
          Inc(SrcBase, 3);
        end;
      end;

    32:
      if FFormat.IsFloat then
        for Frame := 0 to Actual - 1 do
        begin
          SrcBase := @Raw[Frame * BytesPerFrame];
          for Ch := 0 to Channels - 1 do
          begin
            var F: Single;
            Move(SrcBase^, F, 4);
            Buffer[Ch][Frame] := SampleFloat32ToFloat(F);
            Inc(SrcBase, 4);
          end;
        end
      else
        for Frame := 0 to Actual - 1 do
        begin
          SrcBase := @Raw[Frame * BytesPerFrame];
          for Ch := 0 to Channels - 1 do
          begin
            var I: Integer := Integer(Cardinal(SrcBase^) or
                                      (Cardinal((SrcBase+1)^) shl 8) or
                                      (Cardinal((SrcBase+2)^) shl 16) or
                                      (Cardinal((SrcBase+3)^) shl 24));
            Buffer[Ch][Frame] := SampleInt32ToFloat(I);
            Inc(SrcBase, 4);
          end;
        end;

    64:
      // IEEE 64-bit float
      for Frame := 0 to Actual - 1 do
      begin
        SrcBase := @Raw[Frame * BytesPerFrame];
        for Ch := 0 to Channels - 1 do
        begin
          var D: Double;
          Move(SrcBase^, D, 8);
          Buffer[Ch][Frame] := SampleFloat64ToFloat(D);
          Inc(SrcBase, 8);
        end;
      end;
  else
    Exit(adrError);
  end;

  // Suppress "S assigned but never used" hint
  S := 0; if S = 0 then ;

  Result := adrOK;
end;

// ---------------------------------------------------------------------------
// Seek
// ---------------------------------------------------------------------------

function TWAVReader.SeekToFrame(FrameIndex: Cardinal): Boolean;
var
  ByteOffset: Int64;
begin
  Result := False;
  if not FReady then Exit;
  if FFormat.BytesPerFrame = 0 then Exit;
  if (FFormat.FrameCount > 0) and (FrameIndex >= FFormat.FrameCount) then Exit;

  ByteOffset := FFormat.DataOffset + Int64(FrameIndex) * FFormat.BytesPerFrame;
  try
    FStream.Seek(ByteOffset, soBeginning);
    FBytesRead := FrameIndex * FFormat.BytesPerFrame;
    Result := True;
  except
    Result := False;
  end;
end;

// ---------------------------------------------------------------------------
// FramesLeft
// ---------------------------------------------------------------------------

function TWAVReader.FramesLeft: Cardinal;
begin
  if (not FReady) or (FFormat.BytesPerFrame = 0) or (FFormat.DataBytes = 0) then
    Result := 0
  else
  begin
    var BytesLeft := FFormat.DataBytes - FBytesRead;
    Result := BytesLeft div FFormat.BytesPerFrame;
  end;
end;

end.
