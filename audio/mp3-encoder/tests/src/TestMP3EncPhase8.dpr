program TestMP3EncPhase8;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Classes,
  MP3EncEncoder,
  MP3EncWAV;

var
  GPassed, GFailed: Integer;

procedure Check(const AName: string; ACondition: Boolean);
begin
  if ACondition then begin
    Inc(GPassed);
    WriteLn('  PASS  ', AName);
  end else begin
    Inc(GFailed);
    WriteLn('** FAIL  ', AName);
  end;
end;

// ---------------------------------------------------------------------------
// Minimal WAV builder helpers
// ---------------------------------------------------------------------------

procedure WStr(MS: TMemoryStream; const S: AnsiString);
begin
  MS.WriteBuffer(Pointer(S)^, Length(S));
end;

procedure WU16(MS: TMemoryStream; V: Word);
begin
  MS.WriteBuffer(V, 2);
end;

procedure WU32(MS: TMemoryStream; V: Cardinal);
begin
  MS.WriteBuffer(V, 4);
end;

{ Build a 16-bit PCM WAV in memory (mono or stereo).
  ASamples contains interleaved samples: [L0, R0, L1, R1, ...] for stereo
  or [S0, S1, ...] for mono.  AChannels must be 1 or 2. }
function MakeWAV(const ASamples: array of SmallInt;
  AChannels: Word; ASampleRate: Cardinal): TMemoryStream;
var
  dataBytes: Cardinal;
begin
  dataBytes := Cardinal(Length(ASamples)) * 2;
  Result := TMemoryStream.Create;
  WStr(Result, 'RIFF');
  WU32(Result, 36 + dataBytes);
  WStr(Result, 'WAVE');
  WStr(Result, 'fmt ');
  WU32(Result, 16);
  WU16(Result, 1);                              { PCM }
  WU16(Result, AChannels);
  WU32(Result, ASampleRate);
  WU32(Result, ASampleRate * AChannels * 2);   { byte rate }
  WU16(Result, AChannels * 2);                 { block align }
  WU16(Result, 16);                            { bits per sample }
  WStr(Result, 'data');
  WU32(Result, dataBytes);
  if Length(ASamples) > 0 then
    Result.WriteBuffer(ASamples[0], dataBytes);
  Result.Position := 0;
end;

{ Build an array of N silence (zero) SmallInt samples }
function ZeroSamples(N: Integer): TArray<SmallInt>;
var
  i: Integer;
begin
  SetLength(Result, N);
  for i := 0 to N - 1 do Result[i] := 0;
end;

{ Build an array of N SmallInt samples with a constant value V }
function ConstSamples(N: Integer; V: SmallInt): TArray<SmallInt>;
var
  i: Integer;
begin
  SetLength(Result, N);
  for i := 0 to N - 1 do Result[i] := V;
end;

// ---------------------------------------------------------------------------
// WS: WAVSrIdx
// ---------------------------------------------------------------------------

procedure TestWAVSrIdx;
begin
  WriteLn('WS: WAVSrIdx');
  Check('WS01 44100 -> 0',  WAVSrIdx(44100) = 0);
  Check('WS02 48000 -> 1',  WAVSrIdx(48000) = 1);
  Check('WS03 32000 -> 2',  WAVSrIdx(32000) = 2);
  Check('WS04 22050 -> -1', WAVSrIdx(22050) = -1);
end;

// ---------------------------------------------------------------------------
// WO: WAVReaderOpen
// ---------------------------------------------------------------------------

procedure TestWAVReaderOpen;
var
  MS    : TMemoryStream;
  Reader: TWAVReader;
begin
  WriteLn('WO: WAVReaderOpen');
  MS := MakeWAV(ZeroSamples(1152), 1, 44100);
  try
    Check('WO01 valid mono WAV -> True', WAVReaderOpen(MS, Reader));
    Check('WO02 Channels = 1',           Reader.Header.Channels = 1);
    Check('WO03 SampleRate = 44100',     Reader.Header.SampleRate = 44100);
    Check('WO04 BitsPerSample = 16',     Reader.Header.BitsPerSample = 16);
    Check('WO05 SampleCount = 1152',     Reader.Header.SampleCount = 1152);
  finally
    MS.Free;
  end;

  { Invalid stream: truncated header -> False }
  MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(PAnsiChar('RIFF')^, 4);
    MS.Position := 0;
    Check('WO06 truncated header -> False', not WAVReaderOpen(MS, Reader));
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// WR: WAVReaderReadFrame
// ---------------------------------------------------------------------------

procedure TestWAVReaderReadFrame;
var
  MS    : TMemoryStream;
  Samp  : TArray<SmallInt>;
  Reader: TWAVReader;
  PCM   : T1152;
  cnt   : Integer;
begin
  WriteLn('WR: WAVReaderReadFrame');

  { Full 1152-sample read }
  Samp := ConstSamples(1152, 1000);
  MS := MakeWAV(Samp, 1, 44100);
  try
    WAVReaderOpen(MS, Reader);
    Check('WR01 full read -> True',    WAVReaderReadFrame(Reader, PCM, cnt));
    Check('WR02 ACount = 1152',        cnt = 1152);
    Check('WR03 first sample = 1000',  PCM[0] = 1000.0);
    Check('WR04 EOF -> False',         not WAVReaderReadFrame(Reader, PCM, cnt));
    Check('WR05 EOF ACount = 0',       cnt = 0);
  finally
    MS.Free;
  end;

  { Partial read: 100 samples, rest should be zero }
  Samp := ConstSamples(100, 500);
  MS := MakeWAV(Samp, 1, 44100);
  try
    WAVReaderOpen(MS, Reader);
    WAVReaderReadFrame(Reader, PCM, cnt);
    Check('WR06 partial ACount = 100', cnt = 100);
    Check('WR07 pad[100] = 0.0',       PCM[100] = 0.0);
    Check('WR08 pad[1151] = 0.0',      PCM[1151] = 0.0);
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// WS2: Stereo down-mix
// ---------------------------------------------------------------------------

procedure TestStereoDownmix;
var
  Samp  : TArray<SmallInt>;
  MS    : TMemoryStream;
  Reader: TWAVReader;
  PCM   : T1152;
  cnt   : Integer;
begin
  WriteLn('WS2: Stereo down-mix');

  { Stereo: L=10000, R=6000 interleaved -> mono = 8000.0 }
  SetLength(Samp, 4);
  Samp[0] := 10000; Samp[1] := 6000;   { sample 0: L, R }
  Samp[2] := 10000; Samp[3] := 6000;   { sample 1: L, R }
  MS := MakeWAV(Samp, 2, 44100);
  try
    WAVReaderOpen(MS, Reader);
    Check('WS2_01 stereo channels = 2',   Reader.Header.Channels = 2);
    Check('WS2_02 stereo SampleCount = 2', Reader.Header.SampleCount = 2);
    WAVReaderReadFrame(Reader, PCM, cnt);
    Check('WS2_03 down-mix = 8000.0',     Abs(PCM[0] - 8000.0) < 0.5);
    Check('WS2_04 down-mix sample 1',     Abs(PCM[1] - 8000.0) < 0.5);
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// EW: EncodeWAVStream
// ---------------------------------------------------------------------------

procedure TestEncodeWAVStream;
var
  WavIn, MP3Out: TMemoryStream;
  r: Integer;
  b: TBytes;
begin
  WriteLn('EW: EncodeWAVStream');

  { 1152 mono samples -> exactly 1 MP3 frame }
  WavIn  := MakeWAV(ZeroSamples(1152), 1, 44100);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
    Check('EW01 1152 samples -> 2 frames (audio + flush)', r = 2);
    Check('EW02 output = 834 bytes',       MP3Out.Size = 834);
    SetLength(b, 4);
    MP3Out.Position := 0;
    MP3Out.ReadBuffer(b[0], 4);
    Check('EW03 sync [0] = 0xFF',          b[0] = $FF);
    Check('EW04 sync [1] = 0xFB',          b[1] = $FB);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { 2304 mono samples -> 2 frames }
  WavIn  := MakeWAV(ZeroSamples(2304), 1, 44100);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
    Check('EW05 2304 samples -> 3 frames', r = 3);
    Check('EW06 output = 1251 bytes',      MP3Out.Size = 1251);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { 1 sample (partial frame, zero-padded) -> 1 frame }
  WavIn  := MakeWAV(ConstSamples(1, 1000), 1, 44100);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
    Check('EW07 1 sample -> 2 frames',     r = 2);
    Check('EW08 partial output = 834',     MP3Out.Size = 834);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { Invalid stream -> -1 }
  WavIn  := TMemoryStream.Create;
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
    Check('EW09 invalid WAV -> -1',        r = -1);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { 48000 Hz WAV -> valid encode }
  WavIn  := MakeWAV(ZeroSamples(1152), 1, 48000);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
    Check('EW10 48000 Hz -> 2 frames',     r = 2);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;
end;

var
  T0: TDateTime;
begin
  T0 := Now;
  WriteLn('=== TestMP3EncPhase8 ===');
  WriteLn;
  TestWAVSrIdx;
  WriteLn;
  TestWAVReaderOpen;
  WriteLn;
  TestWAVReaderReadFrame;
  WriteLn;
  TestStereoDownmix;
  WriteLn;
  TestEncodeWAVStream;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%.0f ms)',
    [GPassed, GPassed + GFailed, (Now - T0) * 86400000]));
  if GFailed = 0 then WriteLn('ALL PASSED')
  else             WriteLn(Format('%d FAILED', [GFailed]));
  ExitCode := GFailed;
end.
