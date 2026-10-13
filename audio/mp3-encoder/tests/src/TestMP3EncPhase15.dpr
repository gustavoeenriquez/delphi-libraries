program TestMP3EncPhase15;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Classes,
  MP3EncFrame,
  MP3EncEncoder,
  MP3EncID3,
  MP3EncID3v2,
  MP3EncWAV,
  MP3EncProbe,
  MP3EncFile;

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

function MakeSilenceWAV(AChannels: Word; ASampleRate: Cardinal;
  APairs: Integer): TMemoryStream;
var
  zeros : TBytes;
  dBytes: Cardinal;
begin
  dBytes := APairs * AChannels * 2;
  SetLength(zeros, dBytes);
  FillChar(zeros[0], dBytes, 0);
  Result := TMemoryStream.Create;
  WS(Result, 'RIFF'); WU32(Result, 36 + dBytes);
  WS(Result, 'WAVE');
  WS(Result, 'fmt '); WU32(Result, 16);
  WU16(Result, 1); WU16(Result, AChannels);
  WU32(Result, ASampleRate);
  WU32(Result, ASampleRate * AChannels * 2);
  WU16(Result, AChannels * 2); WU16(Result, 16);
  WS(Result, 'data'); WU32(Result, dBytes);
  if dBytes > 0 then Result.WriteBuffer(zeros[0], dBytes);
  Result.Position := 0;
end;

procedure SaveWAV(const APath: string; MS: TMemoryStream);
begin
  MS.Position := 0;
  MS.SaveToFile(APath);
  MS.Position := 0;
end;

// ---------------------------------------------------------------------------
// TP: MP3ProbeStream
// ---------------------------------------------------------------------------

procedure TestProbeStream;
var
  WavIn  : TMemoryStream;
  MP3Out : TMemoryStream;
  Empty  : TMemoryStream;
  Tiny   : TMemoryStream;
  R      : TMP3ProbeResult;
  Tag1   : TID3v1Tag;
  Tag2   : TID3v2Tag;
  tinyBuf: array[0..2] of Byte;
begin
  WriteLn('TP: MP3ProbeStream');

  { TP01-TP02: degenerate inputs }
  Empty := TMemoryStream.Create;
  try
    Check('TP01 empty stream -> False', not MP3ProbeStream(Empty, R));
  finally Empty.Free; end;

  Tiny := TMemoryStream.Create;
  try
    tinyBuf[0] := $FF; tinyBuf[1] := $FB; tinyBuf[2] := $90;
    Tiny.WriteBuffer(tinyBuf, 3);
    Check('TP02 3-byte stream -> False', not MP3ProbeStream(Tiny, R));
  finally Tiny.Free; end;

  { TP03-TP12: basic mono probe (1 frame, no tags) }
  WavIn  := MakeSilenceWAV(1, 44100, 1152);
  MP3Out := TMemoryStream.Create;
  try
    EncodeWAVStream(WavIn, MP3Out, 9, 0);
    Check('TP03 probe raw mono -> True',    MP3ProbeStream(MP3Out, R));
    Check('TP04 FrameCount = 2',            R.FrameCount   = 2);
    Check('TP05 BitRateKbps = 128',         R.BitRateKbps  = 128);
    Check('TP06 SampleRate = 44100',        R.SampleRate   = 44100);
    Check('TP07 Channels = 1',              R.Channels     = 1);
    Check('TP08 ChannelMode = MONO',        R.ChannelMode  = FRAME_CH_MONO);
    Check('TP09 HasXing = False',           not R.HasXing);
    Check('TP10 HasID3v1 = False',          not R.HasID3v1);
    Check('TP11 HasID3v2 = False',          not R.HasID3v2);
    Check('TP12 DurationMs = 52',           R.DurationMs   = 52);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { TP13-TP17: probe MP3 with Xing/Info frame (EncodeWAVStreamInfo) }
  WavIn  := MakeSilenceWAV(1, 44100, 1152);
  MP3Out := TMemoryStream.Create;
  try
    EncodeWAVStreamInfo(WavIn, MP3Out, 9, 0);
    Check('TP13 probe Info MP3 -> True',   MP3ProbeStream(MP3Out, R));
    Check('TP14 HasXing = True',           R.HasXing);
    Check('TP15 IsVBR = False (Info)',     not R.IsVBR);
    Check('TP16 FrameCount = 2 from Xing', R.FrameCount = 2);
    Check('TP17 DurationMs = 52',          R.DurationMs = 52);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { TP18-TP19: probe MP3 with ID3v1 }
  WavIn  := MakeSilenceWAV(1, 44100, 1152);
  MP3Out := TMemoryStream.Create;
  try
    Tag1          := Default(TID3v1Tag);
    Tag1.Title    := 'ProbeTest';
    Tag1.Track    := 7;
    EncodeWAVStreamTagged(WavIn, MP3Out, 9, 0, Tag1);
    Check('TP18 HasID3v1 = True',         MP3ProbeStream(MP3Out, R) and R.HasID3v1);
    Check('TP19 TagV1.Title preserved',   R.TagV1.Title = 'ProbeTest');
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { TP20-TP22: probe MP3 with ID3v2 }
  WavIn  := MakeSilenceWAV(1, 44100, 1152);
  MP3Out := TMemoryStream.Create;
  try
    Tag2         := Default(TID3v2Tag);
    Tag2.Title   := 'ProbeTestV2';
    Tag2.Artist  := 'Probe Artist';
    EncodeWAVStreamTaggedV2(WavIn, MP3Out, 9, 0, Tag2);
    Check('TP20 HasID3v2 = True',          MP3ProbeStream(MP3Out, R) and R.HasID3v2);
    Check('TP21 TagV2.Title preserved',    R.TagV2.Title = 'ProbeTestV2');
    { position must be restored after probe }
    MP3Out.Position := 42;
    MP3ProbeStream(MP3Out, R);
    Check('TP22 position restored = 42',  MP3Out.Position = 42);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { TP23-TP25: 3-frame stereo, no tags }
  WavIn  := MakeSilenceWAV(2, 44100, 3 * 1152);
  MP3Out := TMemoryStream.Create;
  try
    EncodeWAVStream(WavIn, MP3Out, 9, 0);
    MP3ProbeStream(MP3Out, R);
    Check('TP23 3-frame FrameCount = 4',  R.FrameCount = 4);
    Check('TP24 Channels = 2',            R.Channels   = 2);
    Check('TP25 DurationMs = 104',        R.DurationMs = 104);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;
end;

// ---------------------------------------------------------------------------
// TF: File-level API
// ---------------------------------------------------------------------------

procedure TestFileAPI;
var
  TempDir  : string;
  WavPath  : string;
  MP3Path  : string;
  WavMS    : TMemoryStream;
  R        : TMP3ProbeResult;
  Tag1     : TID3v1Tag;
  Tag2     : TID3v2Tag;
  TagOut1  : TID3v1Tag;
  TagOut2  : TID3v2Tag;
  n        : Integer;
begin
  WriteLn('TF: File-level API');

  TempDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  WavPath := TempDir + 'ph15_test.wav';
  MP3Path := TempDir + 'ph15_test.mp3';

  { save a silence WAV to disk }
  WavMS := MakeSilenceWAV(1, 44100, 1152);
  try
    SaveWAV(WavPath, WavMS);
  finally
    WavMS.Free;
  end;

  { TF01-TF02: EncodeWAVFile }
  n := EncodeWAVFile(WavPath, MP3Path, 9, 0);
  Check('TF01 EncodeWAVFile returns 2',   n = 2);
  Check('TF02 MP3 file exists on disk',   FileExists(MP3Path));

  { TF03-TF04: EncodeWAVFileTagged + MP3ReadTagV1 }
  Tag1         := Default(TID3v1Tag);
  Tag1.Title   := 'File Test';
  Tag1.Artist  := 'Test Artist';
  Tag1.Track   := 2;
  n := EncodeWAVFileTagged(WavPath, MP3Path, 9, 0, Tag1);
  Check('TF03 EncodeWAVFileTagged returns 2',  n = 2);
  Check('TF04 MP3ReadTagV1 -> Title ok',
    MP3ReadTagV1(MP3Path, TagOut1) and (TagOut1.Title = 'File Test'));

  { TF05-TF06: EncodeWAVFileTaggedV2 + MP3ReadTagV2 }
  Tag2         := Default(TID3v2Tag);
  Tag2.Title   := 'File Test V2';
  Tag2.Artist  := 'V2 Artist';
  Tag2.Year    := '2025';
  n := EncodeWAVFileTaggedV2(WavPath, MP3Path, 9, 0, Tag2);
  Check('TF05 EncodeWAVFileTaggedV2 returns 2',  n = 2);
  Check('TF06 MP3ReadTagV2 -> Title ok',
    MP3ReadTagV2(MP3Path, TagOut2) and (TagOut2.Title = 'File Test V2'));

  { TF07-TF08: MP3ProbeFile }
  Check('TF07 MP3ProbeFile -> True',       MP3ProbeFile(MP3Path, R));
  Check('TF08 MP3ProbeFile FrameCount=2',  R.FrameCount = 2);

  { TF09-TF10: MP3WriteTagV1 round-trip }
  { first write a plain MP3 so we have a file without tags }
  EncodeWAVFile(WavPath, MP3Path, 9, 0);
  Tag1         := Default(TID3v1Tag);
  Tag1.Title   := 'Updated V1';
  Tag1.Track   := 5;
  Check('TF09 MP3WriteTagV1 -> True',      MP3WriteTagV1(MP3Path, Tag1));
  Check('TF10 MP3ReadTagV1 -> new title',
    MP3ReadTagV1(MP3Path, TagOut1) and (TagOut1.Title = 'Updated V1'));

  { TF11-TF13: MP3WriteTagV2 round-trip + audio preserved }
  EncodeWAVFile(WavPath, MP3Path, 9, 0);
  Tag2         := Default(TID3v2Tag);
  Tag2.Title   := 'Updated V2';
  Tag2.Album   := 'Test Album';
  Check('TF11 MP3WriteTagV2 -> True',      MP3WriteTagV2(MP3Path, Tag2));
  Check('TF12 MP3ReadTagV2 -> new title',
    MP3ReadTagV2(MP3Path, TagOut2) and (TagOut2.Title = 'Updated V2'));
  { probe after tag write: frame count unchanged }
  MP3ProbeFile(MP3Path, R);
  Check('TF13 audio preserved after V2 write: FrameCount=2', R.FrameCount = 2);

  { TF14-TF15: error cases }
  Check('TF14 EncodeWAVFile nonexistent -> -1',
    EncodeWAVFile(TempDir + '__no_such_file__.wav', MP3Path, 9, 0) = -1);
  Check('TF15 MP3ProbeFile nonexistent -> False',
    not MP3ProbeFile(TempDir + '__no_such_file__.mp3', R));

  { cleanup }
  if FileExists(WavPath) then DeleteFile(WavPath);
  if FileExists(MP3Path) then DeleteFile(MP3Path);
end;

// ---------------------------------------------------------------------------

var
  T0: TDateTime;
begin
  T0 := Now;
  WriteLn('=== TestMP3EncPhase15 ===');
  WriteLn;
  TestProbeStream;
  WriteLn;
  TestFileAPI;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%.0f ms)',
    [GPassed, GPassed + GFailed, (Now - T0) * 86400000]));
  if GFailed = 0 then WriteLn('ALL PASSED')
  else             WriteLn(Format('%d FAILED', [GFailed]));
  ExitCode := GFailed;
end.
