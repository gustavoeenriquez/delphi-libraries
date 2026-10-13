program TestMP3EncPhase16;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Classes,
  MP3EncFrame,
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
// WAV builder helpers
// ---------------------------------------------------------------------------

procedure WS(MS: TMemoryStream; const S: AnsiString);
begin MS.WriteBuffer(Pointer(S)^, Length(S)); end;
procedure WU16(MS: TMemoryStream; V: Word);     begin MS.WriteBuffer(V, 2); end;
procedure WU32(MS: TMemoryStream; V: Cardinal); begin MS.WriteBuffer(V, 4); end;

{ Build a WAV with arbitrary format, bit depth, channel count and raw sample bytes. }
function MakeRawWAV(AChannels: Word; ASampleRate: Cardinal;
  ABitsPerSample: Word; AFormat: Word;
  const AData: TBytes): TMemoryStream;
var
  blockAlign: Word;
  byteRate  : Cardinal;
begin
  blockAlign := AChannels * (ABitsPerSample div 8);
  byteRate   := ASampleRate * blockAlign;
  Result     := TMemoryStream.Create;
  WS(Result, 'RIFF'); WU32(Result, 36 + Cardinal(Length(AData)));
  WS(Result, 'WAVE');
  WS(Result, 'fmt '); WU32(Result, 16);
  WU16(Result, AFormat);
  WU16(Result, AChannels);
  WU32(Result, ASampleRate);
  WU32(Result, byteRate);
  WU16(Result, blockAlign);
  WU16(Result, ABitsPerSample);
  WS(Result, 'data'); WU32(Result, Cardinal(Length(AData)));
  if Length(AData) > 0 then
    Result.WriteBuffer(AData[0], Length(AData));
  Result.Position := 0;
end;

{ 1152 silence samples in a given bit depth / format. }
function MakeSilenceWAV(AChannels: Word; ABitsPerSample: Word;
  AFormat: Word): TMemoryStream;
var
  bytesPerSample: Integer;
  data          : TBytes;
  i             : Integer;
begin
  bytesPerSample := ABitsPerSample div 8;
  SetLength(data, 1152 * AChannels * bytesPerSample);
  FillChar(data[0], Length(data), 0);
  { 8-bit PCM silence = 128, not 0 }
  if (AFormat = 1) and (ABitsPerSample = 8) then
    for i := 0 to Length(data) - 1 do
      data[i] := 128;
  Result := MakeRawWAV(AChannels, 44100, ABitsPerSample, AFormat, data);
end;

// ---------------------------------------------------------------------------
// TW: WAVReaderOpen format validation
// ---------------------------------------------------------------------------

procedure TestWAVOpen;
var
  MS    : TMemoryStream;
  R     : TWAVReader;
  data  : TBytes;
begin
  WriteLn('TW: WAVReaderOpen format validation');

  SetLength(data, 1152);  { 1-channel 8-bit: 1 byte per sample }
  FillChar(data[0], 1152, 128);

  { TW01: 8-bit PCM mono }
  MS := MakeRawWAV(1, 44100, 8, 1, data);
  try Check('TW01 8-bit PCM opens OK',   WAVReaderOpen(MS, R));
  finally MS.Free; end;

  { TW02: 24-bit PCM mono (3 bytes per sample) }
  SetLength(data, 1152 * 3);  FillChar(data[0], Length(data), 0);
  MS := MakeRawWAV(1, 44100, 24, 1, data);
  try Check('TW02 24-bit PCM opens OK',  WAVReaderOpen(MS, R));
  finally MS.Free; end;

  { TW03: 32-bit PCM mono }
  SetLength(data, 1152 * 4);  FillChar(data[0], Length(data), 0);
  MS := MakeRawWAV(1, 44100, 32, 1, data);
  try Check('TW03 32-bit PCM opens OK',  WAVReaderOpen(MS, R));
  finally MS.Free; end;

  { TW04: 32-bit float mono (format 3) }
  SetLength(data, 1152 * 4);  FillChar(data[0], Length(data), 0);
  MS := MakeRawWAV(1, 44100, 32, 3, data);
  try Check('TW04 32-bit float opens OK', WAVReaderOpen(MS, R));
  finally MS.Free; end;

  { TW05: 3-channel (surround) 16-bit }
  SetLength(data, 1152 * 3 * 2);  FillChar(data[0], Length(data), 0);
  MS := MakeRawWAV(3, 44100, 16, 1, data);
  try Check('TW05 3-channel opens OK',   WAVReaderOpen(MS, R));
  finally MS.Free; end;

  { TW06: format 2 (ADPCM) -> False }
  SetLength(data, 1152 * 2);  FillChar(data[0], Length(data), 0);
  MS := MakeRawWAV(1, 44100, 16, 2, data);
  try Check('TW06 ADPCM -> False',       not WAVReaderOpen(MS, R));
  finally MS.Free; end;

  { TW07: 4-bit PCM -> False }
  SetLength(data, 1152);  FillChar(data[0], Length(data), 0);
  MS := MakeRawWAV(1, 44100, 4, 1, data);
  try Check('TW07 4-bit PCM -> False',   not WAVReaderOpen(MS, R));
  finally MS.Free; end;

  { TW08: 64-bit float -> False }
  SetLength(data, 1152 * 8);  FillChar(data[0], Length(data), 0);
  MS := MakeRawWAV(1, 44100, 64, 3, data);
  try Check('TW08 64-bit float -> False', not WAVReaderOpen(MS, R));
  finally MS.Free; end;
end;

// ---------------------------------------------------------------------------
// TR: Sample conversion accuracy (1-sample WAVs)
// ---------------------------------------------------------------------------

procedure TestSampleConversion;
var
  MS     : TMemoryStream;
  Reader : TWAVReader;
  PCM    : T1152;
  cnt    : Integer;
  data   : TBytes;
begin
  WriteLn('TR: sample conversion accuracy');

  { TR01: 8-bit byte=255 -> (255-128)*256 = 127*256 = 32512 }
  SetLength(data, 1); data[0] := 255;
  MS := MakeRawWAV(1, 44100, 8, 1, data);
  try
    WAVReaderOpen(MS, Reader);
    WAVReaderReadFrame(Reader, PCM, cnt);
    Check('TR01 8-bit 255 -> 32512',  Abs(PCM[0] - 32512.0) < 0.5);
  finally MS.Free; end;

  { TR02: 8-bit byte=128 -> 0.0 (silence) }
  SetLength(data, 1); data[0] := 128;
  MS := MakeRawWAV(1, 44100, 8, 1, data);
  try
    WAVReaderOpen(MS, Reader);
    WAVReaderReadFrame(Reader, PCM, cnt);
    Check('TR02 8-bit 128 -> 0.0',    Abs(PCM[0]) < 0.5);
  finally MS.Free; end;

  { TR03: 8-bit byte=0 -> (0-128)*256 = -32768 }
  SetLength(data, 1); data[0] := 0;
  MS := MakeRawWAV(1, 44100, 8, 1, data);
  try
    WAVReaderOpen(MS, Reader);
    WAVReaderReadFrame(Reader, PCM, cnt);
    Check('TR03 8-bit 0 -> -32768',   Abs(PCM[0] + 32768.0) < 0.5);
  finally MS.Free; end;

  { TR04: 24-bit max positive = $7FFFFF (LE: FF FF 7F) -> 8388607/256 ~= 32767.996 }
  SetLength(data, 3); data[0] := $FF; data[1] := $FF; data[2] := $7F;
  MS := MakeRawWAV(1, 44100, 24, 1, data);
  try
    WAVReaderOpen(MS, Reader);
    WAVReaderReadFrame(Reader, PCM, cnt);
    Check('TR04 24-bit max positive >= 32767', PCM[0] >= 32767.9);
  finally MS.Free; end;

  { TR05: 24-bit max negative = $800000 (LE: 00 00 80) -> -32768.0 }
  SetLength(data, 3); data[0] := $00; data[1] := $00; data[2] := $80;
  MS := MakeRawWAV(1, 44100, 24, 1, data);
  try
    WAVReaderOpen(MS, Reader);
    WAVReaderReadFrame(Reader, PCM, cnt);
    Check('TR05 24-bit max negative = -32768', Abs(PCM[0] + 32768.0) < 0.01);
  finally MS.Free; end;

  { TR06: 32-bit PCM max positive = $7FFFFFFF -> ~32768.0 }
  SetLength(data, 4); data[0]:=$FF; data[1]:=$FF; data[2]:=$FF; data[3]:=$7F;
  MS := MakeRawWAV(1, 44100, 32, 1, data);
  try
    WAVReaderOpen(MS, Reader);
    WAVReaderReadFrame(Reader, PCM, cnt);
    Check('TR06 32-bit PCM max positive >= 32767', PCM[0] >= 32767.9);
  finally MS.Free; end;

  { TR07: 32-bit float +1.0 (LE: 00 00 80 3F) -> 32768.0 }
  SetLength(data, 4); data[0]:=$00; data[1]:=$00; data[2]:=$80; data[3]:=$3F;
  MS := MakeRawWAV(1, 44100, 32, 3, data);
  try
    WAVReaderOpen(MS, Reader);
    WAVReaderReadFrame(Reader, PCM, cnt);
    Check('TR07 float +1.0 -> 32768.0', Abs(PCM[0] - 32768.0) < 0.01);
  finally MS.Free; end;

  { TR08: 32-bit float -1.0 (LE: 00 00 80 BF) -> -32768.0 }
  SetLength(data, 4); data[0]:=$00; data[1]:=$00; data[2]:=$80; data[3]:=$BF;
  MS := MakeRawWAV(1, 44100, 32, 3, data);
  try
    WAVReaderOpen(MS, Reader);
    WAVReaderReadFrame(Reader, PCM, cnt);
    Check('TR08 float -1.0 -> -32768.0', Abs(PCM[0] + 32768.0) < 0.01);
  finally MS.Free; end;

  { TR09: 16-bit regression — still works (original format) }
  SetLength(data, 2); data[0] := $00; data[1] := $40;  { $4000 = 16384 }
  MS := MakeRawWAV(1, 44100, 16, 1, data);
  try
    WAVReaderOpen(MS, Reader);
    WAVReaderReadFrame(Reader, PCM, cnt);
    Check('TR09 16-bit $4000 = 16384', Abs(PCM[0] - 16384.0) < 0.5);
  finally MS.Free; end;
end;

// ---------------------------------------------------------------------------
// TE: EncodeWAVStream with extended PCM formats
// ---------------------------------------------------------------------------

procedure TestEncodeExtended;
var
  WavIn  : TMemoryStream;
  MP3Out : TMemoryStream;
  r      : Integer;
begin
  WriteLn('TE: EncodeWAVStream extended formats');

  MP3Out := TMemoryStream.Create;
  try
    { TE01: 8-bit mono }
    WavIn := MakeSilenceWAV(1, 8, 1);
    try
      MP3Out.Size := 0;
      r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
      Check('TE01 8-bit mono -> 2 frames',      r = 2);
    finally WavIn.Free; end;

    { TE02: 24-bit mono }
    WavIn := MakeSilenceWAV(1, 24, 1);
    try
      MP3Out.Size := 0;
      r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
      Check('TE02 24-bit mono -> 2 frames',      r = 2);
    finally WavIn.Free; end;

    { TE03: 32-bit PCM mono }
    WavIn := MakeSilenceWAV(1, 32, 1);
    try
      MP3Out.Size := 0;
      r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
      Check('TE03 32-bit PCM mono -> 2 frames',  r = 2);
    finally WavIn.Free; end;

    { TE04: 32-bit float mono }
    WavIn := MakeSilenceWAV(1, 32, 3);
    try
      MP3Out.Size := 0;
      r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
      Check('TE04 32-bit float mono -> 2 frames', r = 2);
    finally WavIn.Free; end;

    { TE05: 8-bit stereo }
    WavIn := MakeSilenceWAV(2, 8, 1);
    try
      MP3Out.Size := 0;
      r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
      Check('TE05 8-bit stereo -> 2 frames',     r = 2);
    finally WavIn.Free; end;

    { TE06: 24-bit stereo }
    WavIn := MakeSilenceWAV(2, 24, 1);
    try
      MP3Out.Size := 0;
      r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
      Check('TE06 24-bit stereo -> 2 frames',    r = 2);
    finally WavIn.Free; end;

  finally MP3Out.Free; end;
end;

// ---------------------------------------------------------------------------
// TM: Multichannel downmix
// ---------------------------------------------------------------------------

procedure TestMultichannel;
var
  MS     : TMemoryStream;
  Reader : TWAVReader;
  WavIn  : TMemoryStream;
  MP3Out : TMemoryStream;
  PCM    : T1152;
  PCM_L  : T1152;
  PCM_R  : T1152;
  cnt, r : Integer;
  data   : TBytes;
begin
  WriteLn('TM: multichannel downmix');

  { TM01: 3-channel WAVReaderOpen -> True }
  SetLength(data, 1152 * 3 * 2);  FillChar(data[0], Length(data), 0);
  MS := MakeRawWAV(3, 44100, 16, 1, data);
  try Check('TM01 3-ch opens OK',  WAVReaderOpen(MS, Reader));
  finally MS.Free; end;

  { TM02: 3-channel EncodeWAVStream -> 1 frame }
  SetLength(data, 1152 * 3 * 2);  FillChar(data[0], Length(data), 0);
  WavIn  := MakeRawWAV(3, 44100, 16, 1, data);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
    Check('TM02 3-ch encode -> 2 frames', r = 2);
  finally WavIn.Free; MP3Out.Free; end;

  { TM03: 4-channel WAVReaderOpen -> True }
  SetLength(data, 1152 * 4 * 2);  FillChar(data[0], Length(data), 0);
  MS := MakeRawWAV(4, 44100, 16, 1, data);
  try Check('TM03 4-ch opens OK',  WAVReaderOpen(MS, Reader));
  finally MS.Free; end;

  { TM04: 4-channel EncodeWAVStream -> 1 frame }
  SetLength(data, 1152 * 4 * 2);  FillChar(data[0], Length(data), 0);
  WavIn  := MakeRawWAV(4, 44100, 16, 1, data);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
    Check('TM04 4-ch encode -> 2 frames', r = 2);
  finally WavIn.Free; MP3Out.Free; end;

  { TM05: 6-channel (5.1) WAVReaderOpen -> True }
  SetLength(data, 1152 * 6 * 2);  FillChar(data[0], Length(data), 0);
  MS := MakeRawWAV(6, 44100, 16, 1, data);
  try Check('TM05 6-ch (5.1) opens OK', WAVReaderOpen(MS, Reader));
  finally MS.Free; end;

  { TM06: 6-channel EncodeWAVStream -> 1 frame }
  SetLength(data, 1152 * 6 * 2);  FillChar(data[0], Length(data), 0);
  WavIn  := MakeRawWAV(6, 44100, 16, 1, data);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStream(WavIn, MP3Out, 9, 0);
    Check('TM06 6-ch encode -> 2 frames', r = 2);
  finally WavIn.Free; MP3Out.Free; end;

  { TM07: center channel in 3-ch mixes to both L and R
    Build 3-ch WAV where ch0=ch1=0, ch2(center)=$1000
    ReadFrameStereo: L=0 + 0.707*4096 = 2895.87, R same }
  begin
    var cSample: SmallInt := $1000;  { 4096 }
    SetLength(data, 6);  { one frame, 3 channels * 2 bytes }
    data[0] := 0; data[1] := 0;  { ch0 = 0 }
    data[2] := 0; data[3] := 0;  { ch1 = 0 }
    data[4] := Lo(cSample); data[5] := Hi(cSample);  { ch2 = 4096 }
    MS := MakeRawWAV(3, 44100, 16, 1, data);
    try
      WAVReaderOpen(MS, Reader);
      WAVReaderReadFrameStereo(Reader, PCM_L, PCM_R, cnt);
      Check('TM07 centre mixes to L',    Abs(PCM_L[0] - 4096 * 0.707) < 1.0);
      Check('TM08 centre mixes to R',    Abs(PCM_R[0] - 4096 * 0.707) < 1.0);
    finally MS.Free; end;
  end;

  { TM09: WAVReaderReadFrame mono output from 3-ch: mean of L and R mix }
  begin
    var cSample: SmallInt := $1000;
    SetLength(data, 6);
    data[0] := 0; data[1] := 0;
    data[2] := 0; data[3] := 0;
    data[4] := Lo(cSample); data[5] := Hi(cSample);
    MS := MakeRawWAV(3, 44100, 16, 1, data);
    try
      WAVReaderOpen(MS, Reader);
      WAVReaderReadFrame(Reader, PCM, cnt);
      Check('TM09 3-ch mono mix > 0',    PCM[0] > 0);
    finally MS.Free; end;
  end;
end;

// ---------------------------------------------------------------------------

var
  T0: TDateTime;
begin
  T0 := Now;
  WriteLn('=== TestMP3EncPhase16 ===');
  WriteLn;
  TestWAVOpen;
  WriteLn;
  TestSampleConversion;
  WriteLn;
  TestEncodeExtended;
  WriteLn;
  TestMultichannel;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%.0f ms)',
    [GPassed, GPassed + GFailed, (Now - T0) * 86400000]));
  if GFailed = 0 then WriteLn('ALL PASSED')
  else             WriteLn(Format('%d FAILED', [GFailed]));
  ExitCode := GFailed;
end.
