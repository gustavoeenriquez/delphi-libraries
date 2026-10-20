program TestMP3EncPhase9;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Classes,
  System.Math,
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
// WAV builder helpers (copied from Phase 8 tests)
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
  WU16(Result, 1);
  WU16(Result, AChannels);
  WU32(Result, ASampleRate);
  WU32(Result, ASampleRate * AChannels * 2);
  WU16(Result, AChannels * 2);
  WU16(Result, 16);
  WStr(Result, 'data');
  WU32(Result, dataBytes);
  if Length(ASamples) > 0 then
    Result.WriteBuffer(ASamples[0], dataBytes);
  Result.Position := 0;
end;

function ZeroSamples(N: Integer): TArray<SmallInt>;
var i: Integer;
begin
  SetLength(Result, N);
  for i := 0 to N - 1 do Result[i] := 0;
end;

function ConstSamples(N: Integer; V: SmallInt): TArray<SmallInt>;
var i: Integer;
begin
  SetLength(Result, N);
  for i := 0 to N - 1 do Result[i] := V;
end;

function MakeSilence: T1152;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

function MakeSine(AFreqHz, ASampleRate: Double): T1152;
var i: Integer;
begin
  for i := 0 to ENC_PCM_PER_FRAME - 1 do
    Result[i] := 16384.0 * Sin(2 * Pi * AFreqHz * i / ASampleRate);
end;

// ---------------------------------------------------------------------------
// SI: EncInitStereo
// ---------------------------------------------------------------------------

procedure TestEncInitStereo;
var
  Enc: TMP3Encoder;
  Cfg: TEncConfig;
begin
  WriteLn('SI: EncInitStereo');
  Cfg.SrIdx := 0; Cfg.BrIdx := 9; Cfg.Padding := 0;
  EncInitStereo(Enc, Cfg);

  Check('SI01 FrameBytes = 417',  Enc.FrameBytes = 417);
  { (417*8 - 32 - 256) div 4 = 3048 div 4 = 762 }
  Check('SI02 TargBits = 762',    Enc.TargBits = 762);
  Check('SI03 Channels = 2',      Enc.Channels = 2);
end;

// ---------------------------------------------------------------------------
// SF: EncodeFrameStereo (silence)
// ---------------------------------------------------------------------------

procedure TestEncFrameStereoSilence;
var
  Enc: TMP3Encoder;
  Cfg: TEncConfig;
  PCM_L, PCM_R: T1152;
  Frame: TBytes;
begin
  WriteLn('SF: EncodeFrameStereo (silence)');
  Cfg.SrIdx := 0; Cfg.BrIdx := 9; Cfg.Padding := 0;
  EncInitStereo(Enc, Cfg);
  PCM_L := MakeSilence;
  PCM_R := MakeSilence;

  Frame := EncodeFrameStereo(Enc, PCM_L, PCM_R);
  Check('SF01 length = 417',        Length(Frame) = 417);
  Check('SF02 sync [0] = 0xFF',     Frame[0] = $FF);
  Check('SF03 sync [1] = 0xFB',     Frame[1] = $FB);
  Check('SF04 header [2] = 0x90',   Frame[2] = $90);
  { FRAME_CH_STEREO=0 -> byte 3 = 00 00 0 1 00 = 0x04 }
  Check('SF05 header [3] = 0x04',   Frame[3] = $04);

  Frame := EncodeFrameStereo(Enc, PCM_L, PCM_R);
  Check('SF06 frame 2 length = 417', Length(Frame) = 417);
end;

// ---------------------------------------------------------------------------
// SS: EncodeFrameStereo (sine wave)
// ---------------------------------------------------------------------------

procedure TestEncFrameStereoSine;
var
  Enc: TMP3Encoder;
  Cfg: TEncConfig;
  PCM_L, PCM_R: T1152;
  Frame: TBytes;
begin
  WriteLn('SS: EncodeFrameStereo (sine)');
  Cfg.SrIdx := 0; Cfg.BrIdx := 9; Cfg.Padding := 0;
  EncInitStereo(Enc, Cfg);
  PCM_L := MakeSine(440.0, 44100.0);
  PCM_R := MakeSine(880.0, 44100.0);

  Frame := EncodeFrameStereo(Enc, PCM_L, PCM_R);
  Check('SS01 sine length = 417',     Length(Frame) = 417);
  Check('SS02 sine [0] = 0xFF',       Frame[0] = $FF);
  Check('SS03 sine [1] = 0xFB',       Frame[1] = $FB);
  Check('SS04 sine [3] = 0x04',       Frame[3] = $04);

  Frame := EncodeFrameStereo(Enc, PCM_L, PCM_R);
  Check('SS05 sine frame 2 = 417',    Length(Frame) = 417);
end;

// ---------------------------------------------------------------------------
// RS: WAVReaderReadFrameStereo (stereo WAV)
// ---------------------------------------------------------------------------

procedure TestReadFrameStereo;
var
  Samp  : TArray<SmallInt>;
  MS    : TMemoryStream;
  Reader: TWAVReader;
  PCM_L, PCM_R: T1152;
  cnt   : Integer;
begin
  WriteLn('RS: WAVReaderReadFrameStereo (stereo WAV)');

  { 2 stereo pairs: L=1000 R=2000, L=3000 R=4000 }
  SetLength(Samp, 4);
  Samp[0] := 1000; Samp[1] := 2000;
  Samp[2] := 3000; Samp[3] := 4000;
  MS := MakeWAV(Samp, 2, 44100);
  try
    WAVReaderOpen(MS, Reader);
    Check('RS01 read -> True',
      WAVReaderReadFrameStereo(Reader, PCM_L, PCM_R, cnt));
    Check('RS02 ACount = 2',           cnt = 2);
    Check('RS03 L[0] = 1000',          Abs(PCM_L[0] - 1000.0) < 0.5);
    Check('RS04 R[0] = 2000',          Abs(PCM_R[0] - 2000.0) < 0.5);
    Check('RS05 L[1] = 3000',          Abs(PCM_L[1] - 3000.0) < 0.5);
    Check('RS06 R[1] = 4000',          Abs(PCM_R[1] - 4000.0) < 0.5);
    Check('RS07 pad L[2] = 0.0',       PCM_L[2] = 0.0);
    Check('RS08 pad R[2] = 0.0',       PCM_R[2] = 0.0);
    Check('RS09 EOF -> False',
      not WAVReaderReadFrameStereo(Reader, PCM_L, PCM_R, cnt));
    Check('RS10 EOF count = 0',        cnt = 0);
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// RM: WAVReaderReadFrameStereo (mono WAV -> duplicate to both channels)
// ---------------------------------------------------------------------------

procedure TestReadFrameStereoMono;
var
  Samp  : TArray<SmallInt>;
  MS    : TMemoryStream;
  Reader: TWAVReader;
  PCM_L, PCM_R: T1152;
  cnt   : Integer;
begin
  WriteLn('RM: WAVReaderReadFrameStereo (mono WAV)');

  Samp := ConstSamples(3, 500);
  MS := MakeWAV(Samp, 1, 44100);
  try
    WAVReaderOpen(MS, Reader);
    WAVReaderReadFrameStereo(Reader, PCM_L, PCM_R, cnt);
    Check('RM01 ACount = 3',          cnt = 3);
    Check('RM02 L[0] = 500',          Abs(PCM_L[0] - 500.0) < 0.5);
    Check('RM03 R[0] = 500',          Abs(PCM_R[0] - 500.0) < 0.5);
    Check('RM04 L = R for all',
      Abs(PCM_L[0] - PCM_R[0]) < 0.5);
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// EW: EncodeWAVStream (stereo path)
// ---------------------------------------------------------------------------

procedure TestEncodeWAVStreamStereo;
var
  WavIn, MP3Out: TMemoryStream;
  Samp: TArray<SmallInt>;
  r: Integer;
  b: TBytes;
begin
  WriteLn('EW: EncodeWAVStream (stereo)');

  { 1152 stereo pairs = 2304 SmallInt values -> 1 frame }
  WavIn  := MakeWAV(ZeroSamples(2304), 2, 44100);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
    Check('EW01 1152 stereo pairs -> 2 frames', r = 2);
    Check('EW02 output = 834 bytes',            MP3Out.Size = 834);
    SetLength(b, 4);
    MP3Out.Position := 0;
    MP3Out.ReadBuffer(b[0], 4);
    Check('EW03 sync [0] = 0xFF',    b[0] = $FF);
    Check('EW04 sync [1] = 0xFB',    b[1] = $FB);
    Check('EW05 stereo [3] = 0x44 (joint, L/R) or 0x64 (joint, MS)',  (b[3] = $44) or (b[3] = $64));
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { 2304 stereo pairs -> 2 frames (4608 SmallInt values) }
  WavIn  := MakeWAV(ZeroSamples(4608), 2, 44100);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
    Check('EW06 2304 pairs -> 3 frames', r = 3);
    Check('EW07 output = 1251 bytes',    MP3Out.Size = 1251);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { Partial stereo frame (100 pairs) -> 1 frame + flush frame }
  WavIn  := MakeWAV(ZeroSamples(200), 2, 44100);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
    Check('EW08 partial stereo -> 2 frames', r = 2);
    Check('EW09 partial output = 834',      MP3Out.Size = 834);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;
end;

// ---------------------------------------------------------------------------
// BK: Backward compatibility — mono EncodeFrame still works
// ---------------------------------------------------------------------------

procedure TestBackwardCompat;
var
  Enc  : TMP3Encoder;
  Cfg  : TEncConfig;
  PCM  : T1152;
  Frame: TBytes;
begin
  WriteLn('BK: Backward compatibility (mono EncodeFrame)');
  Cfg.SrIdx := 0; Cfg.BrIdx := 9; Cfg.Padding := 0;
  EncInit(Enc, Cfg);
  PCM := MakeSilence;

  Frame := EncodeFrame(Enc, PCM);
  Check('BK01 mono length = 417',    Length(Frame) = 417);
  Check('BK02 mono [0] = 0xFF',      Frame[0] = $FF);
  Check('BK03 mono [3] = 0xC4',      Frame[3] = $C4);
  Check('BK04 mono Channels = 1',    Enc.Channels = 1);
  Check('BK05 mono TargBits = 1584', Enc.TargBits = 1584);
end;

var
  T0: TDateTime;
begin
  T0 := Now;
  WriteLn('=== TestMP3EncPhase9 ===');
  WriteLn;
  TestEncInitStereo;
  WriteLn;
  TestEncFrameStereoSilence;
  WriteLn;
  TestEncFrameStereoSine;
  WriteLn;
  TestReadFrameStereo;
  WriteLn;
  TestReadFrameStereoMono;
  WriteLn;
  TestEncodeWAVStreamStereo;
  WriteLn;
  TestBackwardCompat;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%.0f ms)',
    [GPassed, GPassed + GFailed, (Now - T0) * 86400000]));
  if GFailed = 0 then WriteLn('ALL PASSED')
  else             WriteLn(Format('%d FAILED', [GFailed]));
  ExitCode := GFailed;
end.
