unit FLACStreamDecoder;

{
  FLACStreamDecoder.pas - FLAC stream reader and decoder

  Reads a FLAC stream (file or TStream) from the fLaC magic through all
  metadata blocks, then decodes audio frames one block at a time.

  Public API:

    var D := TFLACStreamDecoder.Create;
    if D.Open('track.flac') then
    begin
      WriteLn(D.StreamInfo.SampleRate);
      while D.Decode(Buffer) = adrOK do
        ProcessBuffer(Buffer);
    end;
    D.Free;

  Seeking:
    SeekToSample(N) works only if:
      a) The file has a SEEKTABLE metadata block, OR
      b) The stream is seekable and we scan from the beginning

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Classes,
  AudioTypes,
  AudioCRC,
  FLACTypes,
  FLACFrameDecoder;

type
  TFLACStreamDecoder = class
  private
    FStream      : TStream;
    FOwnsStream  : Boolean;
    FStreamInfo  : TFLACStreamInfo;
    FSeekTable   : array of TFLACSeekPoint;
    FFirstFrameOffset: Int64;  // stream offset of first audio frame
    FReady       : Boolean;
    FSamplesDecoded: Int64;

    // Read-ahead frame buffer
    FFrameBuf    : TBytes;
    FFrameBufSize: Integer;  // valid bytes in FFrameBuf

    function ReadMetadataBlocks: Boolean;
    function ParseStreamInfo(BlockLen: Cardinal): Boolean;
    function ParseSeekTable(BlockLen: Cardinal): Boolean;
    function SkipMetaBlock(BlockLen: Cardinal): Boolean;
    function FillFrameBuffer: Boolean;
    function FindSync(out Offset: Integer): Boolean;

  public
    constructor Create;
    destructor Destroy; override;

    function Open(const FileName: string): Boolean; overload;
    function Open(AStream: TStream; OwnsStream: Boolean = False): Boolean; overload;
    procedure Close;

    // Decode the next block of audio samples.
    function Decode(var Buffer: TAudioBuffer): TAudioDecodeResult;

    // Seek to the nearest seek point at or before SampleIndex.
    // Returns False if seeking is not supported.
    function SeekToSample(SampleIndex: Int64): Boolean;

    property StreamInfo: TFLACStreamInfo read FStreamInfo;
    property Ready     : Boolean         read FReady;
    property SamplesDecoded: Int64       read FSamplesDecoded;
  end;

implementation

// ---------------------------------------------------------------------------
// Frame buffer management constants
// ---------------------------------------------------------------------------

const
  // Initial and refill chunk size. 512 KB is comfortably larger than any
  // realistic FLAC frame (even 32-bit 8-channel 65535-sample blocks ~2 MB
  // uncompressed, but heavily compressed in practice).
  FRAME_BUF_CHUNK = 512 * 1024;
  // Maximum frame buffer size. If a frame is larger than this something is
  // wrong with the stream.
  FRAME_BUF_MAX   = 4 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Constructor / Destructor
// ---------------------------------------------------------------------------

constructor TFLACStreamDecoder.Create;
begin
  inherited Create;
  FStream      := nil;
  FOwnsStream  := False;
  FReady       := False;
  FSamplesDecoded := 0;
end;

destructor TFLACStreamDecoder.Destroy;
begin
  Close;
  inherited Destroy;
end;

// ---------------------------------------------------------------------------
// Open
// ---------------------------------------------------------------------------

function TFLACStreamDecoder.Open(const FileName: string): Boolean;
var S: TFileStream;
begin
  Result := False;
  try
    S := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  except
    Exit;
  end;
  Result := Open(S, True);
  if not Result then S.Free;
end;

function TFLACStreamDecoder.Open(AStream: TStream; OwnsStream: Boolean): Boolean;
var
  Magic: array[0..3] of Byte;
begin
  Close;
  FStream     := AStream;
  FOwnsStream := OwnsStream;

  // Verify magic 'fLaC'
  if FStream.Read(Magic, 4) <> 4 then Exit(False);
  if (Magic[0] <> FLAC_MAGIC[0]) or (Magic[1] <> FLAC_MAGIC[1]) or
     (Magic[2] <> FLAC_MAGIC[2]) or (Magic[3] <> FLAC_MAGIC[3]) then
    Exit(False);

  if not ReadMetadataBlocks then Exit(False);

  FFirstFrameOffset := FStream.Position;
  FSamplesDecoded   := 0;
  SetLength(FFrameBuf, FRAME_BUF_CHUNK);
  FFrameBufSize := 0;

  FReady := True;
  Result := True;
end;

procedure TFLACStreamDecoder.Close;
begin
  FReady := False;
  if FOwnsStream then
    FreeAndNil(FStream)
  else
    FStream := nil;
  FFrameBuf     := nil;
  FFrameBufSize := 0;
  FSeekTable    := nil;
  FSamplesDecoded := 0;
  FillChar(FStreamInfo, SizeOf(FStreamInfo), 0);
end;

// ---------------------------------------------------------------------------
// Metadata parsing
// ---------------------------------------------------------------------------

function TFLACStreamDecoder.ParseStreamInfo(BlockLen: Cardinal): Boolean;
var
  Buf: TBytes;
  V20, V3, V5: Cardinal;
  V36Lo, V36Hi: Cardinal;
begin
  Result := False;
  if BlockLen < 34 then Exit;

  SetLength(Buf, BlockLen);
  if FStream.Read(Buf[0], BlockLen) <> Integer(BlockLen) then Exit;

  // min/max block size (2 + 2 bytes)
  FStreamInfo.MinBlockSize := Word(Buf[0] shl 8 or Buf[1]);
  FStreamInfo.MaxBlockSize := Word(Buf[2] shl 8 or Buf[3]);

  // min/max frame size (3 + 3 bytes)
  FStreamInfo.MinFrameSize := Cardinal(Buf[4]) shl 16 or Cardinal(Buf[5]) shl 8 or Buf[6];
  FStreamInfo.MaxFrameSize := Cardinal(Buf[7]) shl 16 or Cardinal(Buf[8]) shl 8 or Buf[9];

  // Sample rate (20 bits), channels-1 (3 bits), BPS-1 (5 bits), total samples (36 bits)
  // Bytes 10-17 (8 bytes = 64 bits): 20+3+5+36 = 64 bits exactly
  V20 := (Cardinal(Buf[10]) shl 12) or (Cardinal(Buf[11]) shl 4) or (Buf[12] shr 4);
  FStreamInfo.SampleRate := V20;

  V3 := (Buf[12] shr 1) and $07;
  FStreamInfo.Channels := Byte(V3 + 1);

  V5 := ((Buf[12] and $01) shl 4) or (Buf[13] shr 4);
  FStreamInfo.BitsPerSample := Byte(V5 + 1);

  V36Hi := Buf[13] and $0F;
  V36Lo := (Cardinal(Buf[14]) shl 24) or (Cardinal(Buf[15]) shl 16) or
           (Cardinal(Buf[16]) shl 8) or Buf[17];
  FStreamInfo.TotalSamples := (Int64(V36Hi) shl 32) or V36Lo;

  // MD5 (16 bytes starting at offset 18)
  Move(Buf[18], FStreamInfo.MD5[0], 16);

  Result := True;
end;

function TFLACStreamDecoder.ParseSeekTable(BlockLen: Cardinal): Boolean;
var
  NumPoints: Integer;
  I        : Integer;
  Buf      : TBytes;
  Off      : Integer;
begin
  Result    := False;
  NumPoints := BlockLen div 18;
  if NumPoints = 0 then Exit(True);

  SetLength(Buf, BlockLen);
  if FStream.Read(Buf[0], BlockLen) <> Integer(BlockLen) then Exit;

  SetLength(FSeekTable, NumPoints);
  Off := 0;
  for I := 0 to NumPoints - 1 do
  begin
    // 8-byte sample number
    FSeekTable[I].SampleNumber :=
      (Int64(Buf[Off])   shl 56) or (Int64(Buf[Off+1]) shl 48) or
      (Int64(Buf[Off+2]) shl 40) or (Int64(Buf[Off+3]) shl 32) or
      (Int64(Buf[Off+4]) shl 24) or (Int64(Buf[Off+5]) shl 16) or
      (Int64(Buf[Off+6]) shl 8)  or  Int64(Buf[Off+7]);

    // 8-byte stream offset
    FSeekTable[I].StreamOffset :=
      (Int64(Buf[Off+8])  shl 56) or (Int64(Buf[Off+9])  shl 48) or
      (Int64(Buf[Off+10]) shl 40) or (Int64(Buf[Off+11]) shl 32) or
      (Int64(Buf[Off+12]) shl 24) or (Int64(Buf[Off+13]) shl 16) or
      (Int64(Buf[Off+14]) shl 8)  or  Int64(Buf[Off+15]);

    // 2-byte frame samples
    FSeekTable[I].FrameSamples :=
      Word(Buf[Off+16] shl 8 or Buf[Off+17]);

    Inc(Off, 18);
  end;

  Result := True;
end;

function TFLACStreamDecoder.SkipMetaBlock(BlockLen: Cardinal): Boolean;
begin
  Result := FStream.Seek(BlockLen, soCurrent) >= 0;
end;

function TFLACStreamDecoder.ReadMetadataBlocks: Boolean;
var
  Hdr         : array[0..3] of Byte;
  LastBlock   : Boolean;
  BlockType   : Byte;
  BlockLen    : Cardinal;
  GotStreamInfo: Boolean;
begin
  Result       := False;
  GotStreamInfo := False;

  repeat
    if FStream.Read(Hdr, 4) <> 4 then Exit;

    LastBlock := (Hdr[0] shr 7) = 1;
    BlockType := Hdr[0] and $7F;
    BlockLen  := (Cardinal(Hdr[1]) shl 16) or (Cardinal(Hdr[2]) shl 8) or Hdr[3];

    case BlockType of
      FLAC_META_STREAMINFO:
      begin
        if not ParseStreamInfo(BlockLen) then Exit;
        GotStreamInfo := True;
      end;

      FLAC_META_SEEKTABLE:
        if not ParseSeekTable(BlockLen) then Exit;

      else
        // PADDING, APPLICATION, VORBIS_COMMENT, CUESHEET, PICTURE — skip
        if not SkipMetaBlock(BlockLen) then Exit;
    end;
  until LastBlock;

  Result := GotStreamInfo;
end;

// ---------------------------------------------------------------------------
// Frame buffer helpers
// ---------------------------------------------------------------------------

function TFLACStreamDecoder.FillFrameBuffer: Boolean;
var
  ReadLen: Integer;
  Got    : Integer;
begin
  Result := False;

  // Grow buffer if needed
  if Length(FFrameBuf) < FRAME_BUF_CHUNK then
    SetLength(FFrameBuf, FRAME_BUF_CHUNK);

  // How much room is available?
  ReadLen := Length(FFrameBuf) - FFrameBufSize;
  if ReadLen <= 0 then
  begin
    // Buffer full — shouldn't happen normally; try growing
    if Length(FFrameBuf) >= FRAME_BUF_MAX then Exit;
    SetLength(FFrameBuf, Length(FFrameBuf) * 2);
    ReadLen := Length(FFrameBuf) - FFrameBufSize;
  end;

  Got := FStream.Read(FFrameBuf[FFrameBufSize], ReadLen);
  if Got <= 0 then Exit;
  Inc(FFrameBufSize, Got);
  Result := True;
end;

// Find the next FLAC frame sync code (0xFF 0xF8 or 0xFF 0xF9) in the buffer.
// Returns True and sets Offset to the byte index of 0xFF.
function TFLACStreamDecoder.FindSync(out Offset: Integer): Boolean;
var
  I: Integer;
  B0, B1: Byte;
begin
  Result := False;
  Offset := 0;

  for I := 0 to FFrameBufSize - 2 do
  begin
    B0 := FFrameBuf[I];
    B1 := FFrameBuf[I + 1];
    if (B0 = FLAC_SYNC_BYTE0) and
       ((B1 = FLAC_SYNC_BYTE1_FIXED) or (B1 = FLAC_SYNC_BYTE1_VARIABLE)) then
    begin
      Offset := I;
      Result := True;
      Exit;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

function TFLACStreamDecoder.Decode(var Buffer: TAudioBuffer): TAudioDecodeResult;
var
  SyncOff   : Integer;
  FrameBytes: Integer;
  Header    : TFLACFrameHeader;
  Attempts  : Integer;
  MaxFrameHint: Integer;
begin
  if not FReady then Exit(adrError);

  MaxFrameHint := Integer(FStreamInfo.MaxFrameSize);
  if MaxFrameHint = 0 then
    MaxFrameHint := FRAME_BUF_CHUNK;

  // Ensure the buffer has data
  if FFrameBufSize < 8 then
    if not FillFrameBuffer then
      Exit(adrEndOfStream);

  Attempts := 0;
  repeat
    // Find sync in current buffer
    if not FindSync(SyncOff) then
    begin
      // No sync found; discard all but last byte (could be first byte of sync)
      if FFrameBufSize > 1 then
      begin
        FFrameBuf[0] := FFrameBuf[FFrameBufSize - 1];
        FFrameBufSize := 1;
      end;
      if not FillFrameBuffer then
        Exit(adrEndOfStream);
      Inc(Attempts);
      if Attempts > 4 then Exit(adrCorrupted);
      Continue;
    end;

    // Discard bytes before sync
    if SyncOff > 0 then
    begin
      Move(FFrameBuf[SyncOff], FFrameBuf[0], FFrameBufSize - SyncOff);
      FFrameBufSize := FFrameBufSize - SyncOff;
    end;

    // Ensure we have enough data for at least one frame
    while FFrameBufSize < MaxFrameHint do
    begin
      if not FillFrameBuffer then Break;
    end;

    // Attempt to decode
    if FLACDecodeFrame(@FFrameBuf[0], FFrameBufSize, FStreamInfo,
        Header, Buffer, FrameBytes) then
    begin
      // Success: consume the frame bytes from the buffer
      FFrameBufSize := FFrameBufSize - FrameBytes;
      if FFrameBufSize > 0 then
        Move(FFrameBuf[FrameBytes], FFrameBuf[0], FFrameBufSize);

      Inc(FSamplesDecoded, Header.BlockSize);
      Exit(adrOK);
    end
    else
    begin
      // Sync was false positive or corrupted frame — skip sync byte and retry
      FFrameBuf[0] := FFrameBuf[1];  // leave rest, just skip 1 byte
      Move(FFrameBuf[1], FFrameBuf[0], FFrameBufSize - 1);
      Dec(FFrameBufSize);
      if FFrameBufSize < 8 then
        if not FillFrameBuffer then
          Exit(adrEndOfStream);
      Inc(Attempts);
      if Attempts > 64 then Exit(adrCorrupted);
    end;
  until False;
end;

// ---------------------------------------------------------------------------
// Seek
// ---------------------------------------------------------------------------

function TFLACStreamDecoder.SeekToSample(SampleIndex: Int64): Boolean;
var
  I          : Integer;
  BestPoint  : Integer;
  BestSample : Int64;
  StreamOff  : Int64;
begin
  Result := False;
  if not FReady then Exit;

  // Use seek table if available
  BestPoint  := -1;
  BestSample := -1;

  for I := 0 to High(FSeekTable) do
  begin
    var SP := FSeekTable[I].SampleNumber;
    if (SP <> Int64($FFFFFFFFFFFFFFFF)) and (SP <= SampleIndex) then
    begin
      if SP > BestSample then
      begin
        BestSample := SP;
        BestPoint  := I;
      end;
    end;
  end;

  if BestPoint >= 0 then
    StreamOff := FFirstFrameOffset + FSeekTable[BestPoint].StreamOffset
  else
    StreamOff := FFirstFrameOffset;  // seek from beginning

  try
    FStream.Seek(StreamOff, soBeginning);
  except
    Exit;
  end;

  FFrameBufSize   := 0;
  FSamplesDecoded := BestSample;
  if BestSample < 0 then FSamplesDecoded := 0;

  // If SampleIndex > seek point, we must decode frames until we reach it.
  // For Phase 2 implementation we stop at the seek point and let the caller
  // handle the intra-block offset. Full sample-accurate seek can be added later.

  Result := True;
end;

end.
