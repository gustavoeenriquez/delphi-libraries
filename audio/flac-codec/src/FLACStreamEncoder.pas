unit FLACStreamEncoder;

{
  FLACStreamEncoder.pas - FLAC stream encoder

  Accepts TAudioBuffer (planar Single [-1..1]), accumulates samples into
  blocks, encodes each block as a FLAC frame, and writes to a TStream.

  On Close the encoder:
    1. Flushes any partial block (zero-padded to BlockSize)
    2. Seeks back and patches the STREAMINFO metadata block with
       correct MinFrameSize, MaxFrameSize, TotalSamples, and MD5
       (MD5 is left as zeros in Phase 2; a future commit can add it)

  Usage:
    var E := TFLACStreamEncoder.Create('out.flac', 44100, 2, 16);
    try
      while HaveSamples do E.Write(Buffer);
      E.Finalize;   // or call Close / let destructor do it
    finally
      E.Free;
    end;

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Classes, Math,
  AudioTypes,
  AudioSampleConv,
  FLACTypes,
  FLACFrameEncoder;

type
  TFLACStreamEncoder = class
  private
    FStream         : TStream;
    FOwnsStream     : Boolean;
    FStreamInfo     : TFLACStreamInfo;
    FConfig         : TFLACEncConfig;
    FBlockSize      : Integer;
    FFrameNum       : Integer;

    // Sample accumulation buffer (per channel, integer)
    FAccBuf         : array of TArray<Integer>;
    FAccFilled      : Integer;  // frames currently in FAccBuf

    // STREAMINFO patch location
    FSIOffset       : Int64;    // byte offset of STREAMINFO data in stream

    // Stats for STREAMINFO patch
    FTotalSamples   : Int64;
    FMinFrameSize   : Cardinal;
    FMaxFrameSize   : Cardinal;

    FFinalized      : Boolean;
    FReady          : Boolean;

    procedure WriteHeader;
    procedure FlushBlock(PadToFull: Boolean);
    procedure PatchStreamInfo;

  public
    constructor Create(
      const FileName  : string;
      SampleRate      : Cardinal;
      Channels        : Byte;
      BitsPerSample   : Byte;
      BlockSize       : Integer = 4096
    ); overload;

    constructor Create(
      AStream         : TStream;
      SampleRate      : Cardinal;
      Channels        : Byte;
      BitsPerSample   : Byte;
      BlockSize       : Integer;
      OwnsStream      : Boolean;
      const Config    : TFLACEncConfig
    ); overload;

    destructor Destroy; override;

    // Write samples from Buffer. FrameCount < 0 = all available in Buffer.
    function Write(const Buffer: TAudioBuffer; FrameCount: Integer = -1): TAudioEncodeResult;

    // Flush remaining samples and patch STREAMINFO. Safe to call multiple times.
    procedure Finalize;

    property StreamInfo  : TFLACStreamInfo read FStreamInfo;
    property Ready       : Boolean         read FReady;
    property TotalSamples: Int64           read FTotalSamples;
  end;

implementation

// ---------------------------------------------------------------------------
// Constructor / Destructor
// ---------------------------------------------------------------------------

constructor TFLACStreamEncoder.Create(
  const FileName: string;
  SampleRate: Cardinal; Channels: Byte; BitsPerSample: Byte;
  BlockSize: Integer);
var
  S: TFileStream;
begin
  S := TFileStream.Create(FileName, fmCreate);
  Create(S, SampleRate, Channels, BitsPerSample, BlockSize, True, FLACDefaultConfig);
end;

constructor TFLACStreamEncoder.Create(
  AStream: TStream;
  SampleRate: Cardinal; Channels: Byte; BitsPerSample: Byte;
  BlockSize: Integer; OwnsStream: Boolean; const Config: TFLACEncConfig);
var
  Ch: Integer;
begin
  inherited Create;
  FStream     := AStream;
  FOwnsStream := OwnsStream;
  FConfig     := Config;
  FBlockSize  := BlockSize;
  FFinalized  := False;
  FFrameNum   := 0;
  FTotalSamples  := 0;
  FMinFrameSize  := High(Cardinal);
  FMaxFrameSize  := 0;
  FAccFilled     := 0;

  FillChar(FStreamInfo, SizeOf(FStreamInfo), 0);
  FStreamInfo.SampleRate    := SampleRate;
  FStreamInfo.Channels      := Channels;
  FStreamInfo.BitsPerSample := BitsPerSample;
  FStreamInfo.MinBlockSize  := BlockSize;
  FStreamInfo.MaxBlockSize  := BlockSize;

  // Allocate accumulation buffer
  SetLength(FAccBuf, Channels);
  for Ch := 0 to Channels - 1 do
    SetLength(FAccBuf[Ch], BlockSize);

  WriteHeader;
  FReady := True;
end;

destructor TFLACStreamEncoder.Destroy;
begin
  Finalize;
  if FOwnsStream then FreeAndNil(FStream);
  inherited Destroy;
end;

// ---------------------------------------------------------------------------
// Header writing
// ---------------------------------------------------------------------------

procedure TFLACStreamEncoder.WriteHeader;
var
  SIBytes: array[0..33] of Byte;
  MetaHdr: array[0..3] of Byte;
  SR     : Cardinal;
  TS     : Int64;
begin
  // 'fLaC' magic
  FStream.WriteBuffer(FLAC_MAGIC[0], 4);

  // STREAMINFO metadata block (last block = True, type = 0, len = 34)
  MetaHdr[0] := $80 or 0;
  MetaHdr[1] := 0;
  MetaHdr[2] := 0;
  MetaHdr[3] := 34;
  FStream.WriteBuffer(MetaHdr, 4);

  // Record where STREAMINFO data starts (to patch later)
  FSIOffset := FStream.Position;

  // Write STREAMINFO data (34 bytes)
  FillChar(SIBytes, 34, 0);
  SIBytes[0] := FBlockSize shr 8;
  SIBytes[1] := FBlockSize and $FF;
  SIBytes[2] := FBlockSize shr 8;
  SIBytes[3] := FBlockSize and $FF;
  // MinFrameSize, MaxFrameSize = 0 (unknown at this point)

  SR := FStreamInfo.SampleRate;
  SIBytes[10] := (SR shr 12) and $FF;
  SIBytes[11] := (SR shr 4) and $FF;
  SIBytes[12] := Byte((SR and $0F) shl 4) or
                 Byte(((FStreamInfo.Channels - 1) and $07) shl 1) or
                 Byte((FStreamInfo.BitsPerSample - 1) shr 4);
  SIBytes[13] := Byte(((FStreamInfo.BitsPerSample - 1) and $0F) shl 4);
  // TotalSamples = 0 at header write time (patched on Close)
  FStream.WriteBuffer(SIBytes, 34);
end;

// ---------------------------------------------------------------------------
// Encoding a block
// ---------------------------------------------------------------------------

procedure TFLACStreamEncoder.FlushBlock(PadToFull: Boolean);
var
  Samps    : array of TArray<Integer>;
  Ch, F    : Integer;
  FrameData: TBytes;
  FSize    : Cardinal;
  Count    : Integer;
begin
  Count := FAccFilled;
  if Count = 0 then Exit;
  if PadToFull and (Count < FBlockSize) then
  begin
    // Zero-pad to full block size
    for Ch := 0 to FStreamInfo.Channels - 1 do
      FillChar(FAccBuf[Ch][Count], (FBlockSize - Count) * SizeOf(Integer), 0);
    Count := FBlockSize;
  end;

  // Build Samples array of TArray<Integer>
  SetLength(Samps, FStreamInfo.Channels);
  for Ch := 0 to FStreamInfo.Channels - 1 do
  begin
    SetLength(Samps[Ch], Count);
    Move(FAccBuf[Ch][0], Samps[Ch][0], Count * SizeOf(Integer));
  end;

  if FLACEncodeFrame(FConfig, FStreamInfo, FFrameNum, Samps, Count, FrameData) then
  begin
    FStream.WriteBuffer(FrameData[0], Length(FrameData));
    Inc(FFrameNum);
    Inc(FTotalSamples, Count);

    FSize := Cardinal(Length(FrameData));
    if FSize < FMinFrameSize then FMinFrameSize := FSize;
    if FSize > FMaxFrameSize then FMaxFrameSize := FSize;
  end;

  FAccFilled := 0;
end;

// ---------------------------------------------------------------------------
// Write
// ---------------------------------------------------------------------------

function TFLACStreamEncoder.Write(const Buffer: TAudioBuffer;
  FrameCount: Integer): TAudioEncodeResult;
var
  Channels : Integer;
  SrcOff   : Integer;
  Avail    : Integer;
  Take     : Integer;
  Ch       : Integer;
  ScaleFactor: Single;
  I        : Integer;
begin
  if not FReady or FFinalized then Exit(aerError);
  if Length(Buffer) = 0 then Exit(aerOK);

  Channels := FStreamInfo.Channels;
  if FrameCount < 0 then FrameCount := Length(Buffer[0]);
  if FrameCount = 0 then Exit(aerOK);

  // Scale factor: Single → integer PCM
  ScaleFactor := Single(Int64(1) shl (FStreamInfo.BitsPerSample - 1));

  SrcOff := 0;
  while SrcOff < FrameCount do
  begin
    Avail := FBlockSize - FAccFilled;
    Take  := Min(Avail, FrameCount - SrcOff);

    for Ch := 0 to Channels - 1 do
    begin
      if Ch >= Length(Buffer) then
      begin
        FillChar(FAccBuf[Ch][FAccFilled], Take * SizeOf(Integer), 0);
        Continue;
      end;
      for I := 0 to Take - 1 do
      begin
        var V := Round(Buffer[Ch][SrcOff + I] * ScaleFactor);
        var MaxV := Integer(Int64(1) shl (FStreamInfo.BitsPerSample - 1)) - 1;
        var MinV := -(MaxV + 1);
        if V > MaxV then V := MaxV else if V < MinV then V := MinV;
        FAccBuf[Ch][FAccFilled + I] := V;
      end;
    end;

    Inc(FAccFilled, Take);
    Inc(SrcOff, Take);

    if FAccFilled = FBlockSize then
      FlushBlock(False);
  end;

  Result := aerOK;
end;

// ---------------------------------------------------------------------------
// Finalize / PatchStreamInfo
// ---------------------------------------------------------------------------

procedure TFLACStreamEncoder.PatchStreamInfo;
var
  SIBytes: array[0..33] of Byte;
  SR     : Cardinal;
  TS     : Int64;
  SavePos: Int64;
begin
  SavePos := FStream.Position;
  FStream.Seek(FSIOffset, soBeginning);

  FillChar(SIBytes, 34, 0);

  // Block sizes
  SIBytes[0] := FBlockSize shr 8; SIBytes[1] := FBlockSize and $FF;
  SIBytes[2] := FBlockSize shr 8; SIBytes[3] := FBlockSize and $FF;

  // Min/max frame sizes
  if FMinFrameSize = High(Cardinal) then FMinFrameSize := 0;
  SIBytes[4] := (FMinFrameSize shr 16) and $FF;
  SIBytes[5] := (FMinFrameSize shr 8)  and $FF;
  SIBytes[6] :=  FMinFrameSize         and $FF;
  SIBytes[7] := (FMaxFrameSize shr 16) and $FF;
  SIBytes[8] := (FMaxFrameSize shr 8)  and $FF;
  SIBytes[9] :=  FMaxFrameSize         and $FF;

  // Sample rate, channels, BPS
  SR := FStreamInfo.SampleRate;
  SIBytes[10] := (SR shr 12) and $FF;
  SIBytes[11] := (SR shr 4)  and $FF;
  SIBytes[12] := Byte((SR and $0F) shl 4) or
                 Byte(((FStreamInfo.Channels - 1) and $07) shl 1) or
                 Byte((FStreamInfo.BitsPerSample - 1) shr 4);
  SIBytes[13] := Byte(((FStreamInfo.BitsPerSample - 1) and $0F) shl 4);

  // Total samples (36 bits)
  TS := FTotalSamples;
  SIBytes[13] := SIBytes[13] or Byte((TS shr 32) and $0F);
  SIBytes[14] := Byte((TS shr 24) and $FF);
  SIBytes[15] := Byte((TS shr 16) and $FF);
  SIBytes[16] := Byte((TS shr 8)  and $FF);
  SIBytes[17] := Byte(TS and $FF);
  // MD5: zeros (not computed in Phase 2)

  FStream.WriteBuffer(SIBytes, 34);
  FStream.Seek(SavePos, soBeginning);
  FStream.Seek(0, soEnd);
end;

procedure TFLACStreamEncoder.Finalize;
begin
  if FFinalized or not FReady then Exit;
  FFinalized := True;

  // Flush any remaining samples (padded to full block)
  if FAccFilled > 0 then
    FlushBlock(True);

  // Patch STREAMINFO with accurate totals
  if FStream.Position > FSIOffset then
    PatchStreamInfo;
end;

end.
