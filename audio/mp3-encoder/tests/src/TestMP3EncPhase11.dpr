program TestMP3EncPhase11;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Classes,
  MP3EncEncoder,
  MP3EncXing,
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

procedure WS(MS: TMemoryStream; const S: AnsiString);
begin
  MS.WriteBuffer(Pointer(S)^, Length(S));
end;
procedure WU16(MS: TMemoryStream; V: Word);    begin MS.WriteBuffer(V, 2); end;
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

function MakeTestTag(AChannels: Integer): TXingTag;
begin
  Result            := Default(TXingTag);
  Result.IsVBR      := False;
  Result.Flags      := XING_FLAG_FRAMES or XING_FLAG_BYTES or XING_FLAG_TOC;
  Result.FrameCount := 42;
  Result.FileSize   := 42 * 417;  { 17514 }
  XingBuildCBRTOC(Result.TOC);
end;

function MakeCfg128k44100: TEncConfig;
begin
  Result.SrIdx   := 0;  { 44100 Hz }
  Result.BrIdx   := 9;  { 128 kbps }
  Result.Padding := 0;
end;

// ---------------------------------------------------------------------------
// XO: XingDataOffset
// ---------------------------------------------------------------------------

procedure TestXingDataOffset;
begin
  WriteLn('XO: XingDataOffset');
  { MPEG1 mono:   4 + 17 = 21 }
  Check('XO01 mono offset = 21',   XingDataOffset(1) = 21);
  { MPEG1 stereo: 4 + 32 = 36 }
  Check('XO02 stereo offset = 36', XingDataOffset(2) = 36);
end;

// ---------------------------------------------------------------------------
// XT: XingBuildCBRTOC
// ---------------------------------------------------------------------------

procedure TestXingBuildCBRTOC;
var
  TOC: array[0..99] of Byte;
begin
  WriteLn('XT: XingBuildCBRTOC');
  XingBuildCBRTOC(TOC);
  Check('XT01 TOC[0]  = 0',   TOC[0]  = 0);
  Check('XT02 TOC[25] = 64',  TOC[25] = 64);   { Round(25*256/100) = 64 }
  Check('XT03 TOC[50] = 128', TOC[50] = 128);  { Round(50*256/100) = 128 }
  Check('XT04 TOC[99] = 253', TOC[99] = 253);  { Round(99*256/100) = 253 }
end;

// ---------------------------------------------------------------------------
// XW: XingWriteFrame (mono)
// ---------------------------------------------------------------------------

procedure TestXingWriteFrame;
var
  MS  : TMemoryStream;
  Cfg : TEncConfig;
  Tag : TXingTag;
  buf : TBytes;
begin
  WriteLn('XW: XingWriteFrame');
  Cfg := MakeCfg128k44100;
  Tag := MakeTestTag(1);

  MS := TMemoryStream.Create;
  try
    XingWriteFrame(MS, Cfg, 1, Tag);

    { Frame size = 417 bytes }
    Check('XW01 frame size = 417', MS.Size = 417);

    SetLength(buf, 417);
    MS.Position := 0;
    MS.ReadBuffer(buf[0], 417);

    { MPEG sync + mono header identical to audio frames }
    Check('XW02 sync[0] = 0xFF', buf[0] = $FF);
    Check('XW03 sync[1] = 0xFB', buf[1] = $FB);
    Check('XW04 byte[2] = 0x90', buf[2] = $90);
    Check('XW05 byte[3] = 0xC4', buf[3] = $C4);  { mono }

    { "Info" magic at offset 21 }
    Check('XW06 Info[0] = I',    buf[21] = Ord('I'));
    Check('XW07 Info[1] = n',    buf[22] = Ord('n'));
    Check('XW08 Info[2] = f',    buf[23] = Ord('f'));
    Check('XW09 Info[3] = o',    buf[24] = Ord('o'));

    { Flags (big-endian uint32) at offset 25: low byte = FRAMES|BYTES|TOC = 7 }
    Check('XW10 flags byte = 7',  buf[28] = 7);

    { FrameCount = 42 at offset 29: big-endian -> last byte = 42 }
    Check('XW11 FrameCount = 42', buf[32] = 42);

    { FileSize = 17514 = 0x0000446A at offset 33 }
    Check('XW12 FileSize hi = 0', buf[33] = 0);
    Check('XW13 FileSize b2 = 0', buf[34] = 0);
    Check('XW14 FileSize b3 = $44', buf[35] = $44);
    Check('XW15 FileSize b4 = $6A', buf[36] = $6A);
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// XR: XingReadFrame roundtrip
// ---------------------------------------------------------------------------

procedure TestXingReadFrame;
var
  MS     : TMemoryStream;
  Cfg    : TEncConfig;
  TagIn  : TXingTag;
  TagOut : TXingTag;
begin
  WriteLn('XR: XingReadFrame');
  Cfg    := MakeCfg128k44100;
  TagIn  := MakeTestTag(1);

  MS := TMemoryStream.Create;
  try
    XingWriteFrame(MS, Cfg, 1, TagIn);

    Check('XR01 ReadFrame -> True',     XingReadFrame(MS, Cfg, 1, TagOut));
    Check('XR02 IsVBR = False',         not TagOut.IsVBR);
    Check('XR03 FrameCount = 42',       TagOut.FrameCount = 42);
    Check('XR04 FileSize = 17514',      TagOut.FileSize = 17514);
    Check('XR05 TOC[0] = 0',            TagOut.TOC[0] = 0);
    Check('XR06 TOC[50] = 128',         TagOut.TOC[50] = 128);
    Check('XR07 stream pos restored',   MS.Position = 417);  { saved/restored = 417 after write }

    { "Xing" magic roundtrip }
    TagIn.IsVBR := True;
    MS.Size := 0;
    XingWriteFrame(MS, Cfg, 1, TagIn);
    Check('XR08 IsVBR True roundtrip',  XingReadFrame(MS, Cfg, 1, TagOut));
    Check('XR09 IsVBR = True',          TagOut.IsVBR);
  finally
    MS.Free;
  end;

  { No magic -> False: write 417 explicit zero bytes }
  MS := TMemoryStream.Create;
  try
    MS.Size := 417;
    FillChar(MS.Memory^, 417, 0);  { SetSize does not zero-initialise the buffer }
    Check('XR10 no magic -> False', not XingReadFrame(MS, Cfg, 1, TagOut));
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// XI: EncodeWAVStreamInfo
// ---------------------------------------------------------------------------

procedure TestEncodeWAVStreamInfo;
var
  WavIn, MP3Out: TMemoryStream;
  Cfg  : TEncConfig;
  Tag  : TXingTag;
  r    : Integer;
  b    : Byte;
begin
  WriteLn('XI: EncodeWAVStreamInfo');
  Cfg := MakeCfg128k44100;

  { 1152 mono samples -> 1 audio frame + 1 Info frame }
  WavIn  := MakeSilenceWAV(1, 44100, 1152);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStreamInfo(WavIn, MP3Out, 9, 0);
    Check('XI01 audio frames = 2',              r = 2);
    { Info frame (417) + audio frame (417) = 834 }
    Check('XI02 total size = 1251',             MP3Out.Size = 1251);
    Check('XI03 XingReadFrame -> True',         XingReadFrame(MP3Out, Cfg, 1, Tag));
    Check('XI04 IsVBR = False',                 not Tag.IsVBR);
    Check('XI05 FrameCount = 2',                Tag.FrameCount = 2);
    Check('XI06 FileSize = 834',                Tag.FileSize = 834);
    Check('XI07 TOC[50] = 128',                 Tag.TOC[50] = 128);
    { Second frame (audio) must also be valid MP3 sync }
    MP3Out.Position := 417;
    MP3Out.ReadBuffer(b, 1);
    Check('XI08 audio frame sync 0xFF', b = $FF);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { Stereo WAV: 1152 pairs -> 1 audio frame; Info frame = stereo header byte 0x04 }
  WavIn  := MakeSilenceWAV(2, 44100, 1152);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStreamInfo(WavIn, MP3Out, 9, 0);
    Check('XI09 stereo frames = 2',             r = 2);
    Check('XI10 stereo total = 1251',           MP3Out.Size = 1251);
    Check('XI11 stereo XingReadFrame -> True',  XingReadFrame(MP3Out, Cfg, 2, Tag));
    Check('XI12 stereo FrameCount = 2',         Tag.FrameCount = 2);
    { Info frame byte[3] = 0x44 (joint stereo, like the audio frames) }
    MP3Out.Position := 3;
    MP3Out.ReadBuffer(b, 1);
    Check('XI13 stereo Info byte[3] = 0x44',    b = $44);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { Invalid WAV -> -1 }
  WavIn  := TMemoryStream.Create;
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStreamInfo(WavIn, MP3Out, 9, 0);
    Check('XI14 invalid WAV -> -1',             r = -1);
    Check('XI15 empty output on error',         MP3Out.Size = 0);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;
end;

var
  T0: TDateTime;
begin
  T0 := Now;
  WriteLn('=== TestMP3EncPhase11 ===');
  WriteLn;
  TestXingDataOffset;
  WriteLn;
  TestXingBuildCBRTOC;
  WriteLn;
  TestXingWriteFrame;
  WriteLn;
  TestXingReadFrame;
  WriteLn;
  TestEncodeWAVStreamInfo;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%.0f ms)',
    [GPassed, GPassed + GFailed, (Now - T0) * 86400000]));
  if GFailed = 0 then WriteLn('ALL PASSED')
  else             WriteLn(Format('%d FAILED', [GFailed]));
  ExitCode := GFailed;
end.
