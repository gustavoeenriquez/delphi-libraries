program TestMP3EncPhase18;

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
// Helpers
// ---------------------------------------------------------------------------

function RBU32(const Buf: TBytes; Pos: Integer): Cardinal;
begin
  Result := (Cardinal(Buf[Pos]) shl 24) or (Cardinal(Buf[Pos+1]) shl 16)
          or (Cardinal(Buf[Pos+2]) shl 8) or Cardinal(Buf[Pos+3]);
end;

procedure WS(MS: TMemoryStream; const S: AnsiString);
begin MS.WriteBuffer(Pointer(S)^, Length(S)); end;
procedure WU16(MS: TMemoryStream; V: Word);     begin MS.WriteBuffer(V, 2); end;
procedure WU32(MS: TMemoryStream; V: Cardinal); begin MS.WriteBuffer(V, 4); end;

function MakeSilenceWAV16(AChannels: Word; APairs: Integer): TMemoryStream;
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
  WU32(Result, 44100); WU32(Result, 44100 * AChannels * 2);
  WU16(Result, AChannels * 2); WU16(Result, 16);
  WS(Result, 'data'); WU32(Result, dBytes);
  if dBytes > 0 then Result.WriteBuffer(zeros[0], dBytes);
  Result.Position := 0;
end;

function MakeCfg(ABrIdx, ASrIdx, APadding: Byte): TEncConfig;
begin
  Result.BrIdx   := ABrIdx;
  Result.SrIdx   := ASrIdx;
  Result.Padding := APadding;
end;

function MakeXingTag(AIsVBR: Boolean; AFrameCount, AFileSize: Cardinal): TXingTag;
begin
  Result            := Default(TXingTag);
  Result.IsVBR      := AIsVBR;
  Result.Flags      := XING_FLAG_FRAMES or XING_FLAG_BYTES
                     or XING_FLAG_TOC   or XING_FLAG_QUALITY;
  Result.FrameCount := AFrameCount;
  Result.FileSize   := AFileSize;
  XingBuildCBRTOC(Result.TOC);
end;

function MakeLameTag(ADelay, APadding: Word; AVBRMethod: Byte;
  AMusicLength: Cardinal): TLameTag;
begin
  Result                := Default(TLameTag);
  Result.EncoderDelay   := ADelay;
  Result.EncoderPadding := APadding;
  Result.VBRMethod      := AVBRMethod;
  Result.MusicLength    := AMusicLength;
end;

// ---------------------------------------------------------------------------
// TL: LAME frame binary layout
// ---------------------------------------------------------------------------

procedure TestLAMEBinaryLayout;
const
  BRID  = 9;
  SRID  = 0;
  PAD   = 0;
  CH    = 1;   { mono }
var
  MS      : TMemoryStream;
  Cfg     : TEncConfig;
  XTag    : TXingTag;
  LTag    : TLameTag;
  buf     : TBytes;
  fBytes  : Integer;
  xOfs    : Integer;
  lOfs    : Integer;
begin
  WriteLn('TL: LAME frame binary layout');

  Cfg   := MakeCfg(BRID, SRID, PAD);
  XTag  := MakeXingTag(False, 10, 4170);
  LTag  := MakeLameTag(100, 200, LAME_VBR_CBR, 4170);

  fBytes := EncFrameBytes(BRID, SRID, PAD);
  xOfs   := XingDataOffset(CH);     { 21 for mono }
  lOfs   := xOfs + 120;             { 141 }

  MS := TMemoryStream.Create;
  try
    LameWriteFrame(MS, Cfg, CH, XTag, LTag);
    SetLength(buf, MS.Size);
    MS.Position := 0;
    MS.ReadBuffer(buf[0], MS.Size);
  finally MS.Free; end;

  { TL01: frame size matches EncFrameBytes }
  Check('TL01 frame size = EncFrameBytes', Length(buf) = fBytes);

  { TL02: MP3 sync byte = $FF }
  Check('TL02 sync byte $FF', buf[0] = $FF);

  { TL03: "Info" magic at xingOfs (CBR) }
  Check('TL03 Info magic at xingOfs',
    (buf[xOfs]   = Ord('I')) and (buf[xOfs+1] = Ord('n')) and
    (buf[xOfs+2] = Ord('f')) and (buf[xOfs+3] = Ord('o')));

  { TL04: LAME magic "LAME" at lameOfs }
  Check('TL04 LAME magic at lameOfs',
    (buf[lOfs]   = Ord('L')) and (buf[lOfs+1] = Ord('A')) and
    (buf[lOfs+2] = Ord('M')) and (buf[lOfs+3] = Ord('E')));

  { TL05: encoder string suffix "3.100" at lameOfs+4..8 }
  Check('TL05 encoder string 3.100',
    (buf[lOfs+4] = Ord('3')) and (buf[lOfs+5] = Ord('.')) and
    (buf[lOfs+6] = Ord('1')) and (buf[lOfs+7] = Ord('0')) and
    (buf[lOfs+8] = Ord('0')));

  { TL06: VBR method byte = LAME_VBR_CBR = 1 at lameOfs+9 }
  Check('TL06 VBR method byte = 1', (buf[lOfs+9] and $0F) = LAME_VBR_CBR);

  { TL07: delay byte[0] = (delay shr 4) = 6 for delay=100 }
  Check('TL07 delay byte[0] = delay shr 4', buf[lOfs+21] = (100 shr 4));

  { TL08: padding byte[2] = padding and $FF = 200 for padding=200 }
  Check('TL08 padding byte[2] = padding and $FF', buf[lOfs+23] = (200 and $FF));

  { TL09: music length at lameOfs+28 = 4170 }
  Check('TL09 music length bytes = MusicLength', RBU32(buf, lOfs+28) = 4170);

  { TL10: CRC at lameOfs+34..35 is non-zero (frame has meaningful content) }
  Check('TL10 CRC is non-zero',
    ((buf[lOfs+34] <> 0) or (buf[lOfs+35] <> 0)));
end;

// ---------------------------------------------------------------------------
// TR: LAME roundtrip
// ---------------------------------------------------------------------------

procedure TestLAMERoundtrip;
const
  BRID = 9; SRID = 0; PAD = 0; CH = 1;
var
  MS    : TMemoryStream;
  Cfg   : TEncConfig;
  XIn   : TXingTag;
  LIn   : TLameTag;
  XOut  : TXingTag;
  LOut  : TLameTag;
begin
  WriteLn('TR: LAME roundtrip');

  Cfg := MakeCfg(BRID, SRID, PAD);

  { TR01..TR07: standard values }
  MS := TMemoryStream.Create;
  try
    XIn := MakeXingTag(False, 25, 10425);
    LIn := MakeLameTag(100, 200, LAME_VBR_CBR, 10425);
    LameWriteFrame(MS, Cfg, CH, XIn, LIn);
    Check('TR01 LameReadFrame returns True',
      LameReadFrame(MS, Cfg, CH, XOut, LOut));
    Check('TR02 IsVBR = False',              not XOut.IsVBR);
    Check('TR03 FrameCount preserved',       XOut.FrameCount = 25);
    Check('TR04 FileSize preserved',         XOut.FileSize = 10425);
    Check('TR05 EncoderDelay = 100',         LOut.EncoderDelay = 100);
    Check('TR06 EncoderPadding = 200',       LOut.EncoderPadding = 200);
    Check('TR07 VBRMethod = LAME_VBR_CBR',  LOut.VBRMethod = LAME_VBR_CBR);
  finally MS.Free; end;

  { TR08: zero delay and zero padding preserved }
  MS := TMemoryStream.Create;
  try
    XIn := MakeXingTag(False, 1, 417);
    LIn := MakeLameTag(0, 0, LAME_VBR_CBR, 417);
    LameWriteFrame(MS, Cfg, CH, XIn, LIn);
    LameReadFrame(MS, Cfg, CH, XOut, LOut);
    Check('TR08 zero delay/padding preserved',
      (LOut.EncoderDelay = 0) and (LOut.EncoderPadding = 0));
  finally MS.Free; end;

  { TR09: maximum delay (4095) preserved }
  MS := TMemoryStream.Create;
  try
    XIn := MakeXingTag(False, 1, 417);
    LIn := MakeLameTag(4095, 0, LAME_VBR_CBR, 417);
    LameWriteFrame(MS, Cfg, CH, XIn, LIn);
    LameReadFrame(MS, Cfg, CH, XOut, LOut);
    Check('TR09 max delay (4095) preserved', LOut.EncoderDelay = 4095);
  finally MS.Free; end;

  { TR10: maximum padding (4095) preserved }
  MS := TMemoryStream.Create;
  try
    XIn := MakeXingTag(False, 1, 417);
    LIn := MakeLameTag(0, 4095, LAME_VBR_CBR, 417);
    LameWriteFrame(MS, Cfg, CH, XIn, LIn);
    LameReadFrame(MS, Cfg, CH, XOut, LOut);
    Check('TR10 max padding (4095) preserved', LOut.EncoderPadding = 4095);
  finally MS.Free; end;
end;

// ---------------------------------------------------------------------------
// TI: integration with EncodeWAVStreamLame
// ---------------------------------------------------------------------------

procedure TestIntegration;
const
  TOTAL_SAMPLES = 1000;
  BRID = 9; SRID = 0; PAD = 0; CH = 1;
  FRAME_BYTES = 417;  { EncFrameBytes(9, 0, 0) for 44100 Hz, 128 kbps }
var
  WavIn  : TMemoryStream;
  MP3Out : TMemoryStream;
  Cfg    : TEncConfig;
  XOut   : TXingTag;
  LOut   : TLameTag;
  r      : Integer;
  xOk    : Boolean;
begin
  WriteLn('TI: integration with EncodeWAVStreamLame');

  WavIn  := MakeSilenceWAV16(CH, TOTAL_SAMPLES);
  MP3Out := TMemoryStream.Create;
  Cfg    := MakeCfg(BRID, SRID, PAD);
  try
    r := EncodeWAVStreamLame(WavIn, MP3Out, BRID, PAD);
    Check('TI01 returns 2 audio frames',    r = 2);

    { TI02: Xing/Info readable via XingReadFrame (basic sanity) }
    xOk := XingReadFrame(MP3Out, Cfg, CH, XOut);
    Check('TI02 XingReadFrame returns True', xOk);

    { TI03: LameReadFrame returns True }
    Check('TI03 LameReadFrame returns True',
      LameReadFrame(MP3Out, Cfg, CH, XOut, LOut));

    { Re-read for subsequent checks }
    LameReadFrame(MP3Out, Cfg, CH, XOut, LOut);

    Check('TI04 EncoderDelay = 528',         LOut.EncoderDelay = 528);
    Check('TI05 EncoderPadding = 2*1152-528-1000', LOut.EncoderPadding = (2 * 1152 - 528 - TOTAL_SAMPLES));
    Check('TI06 VBRMethod = LAME_VBR_CBR',  LOut.VBRMethod = LAME_VBR_CBR);
    Check('TI07 MusicLength = 2 * FRAME_BYTES', LOut.MusicLength = 2 * FRAME_BYTES);
    Check('TI08 XingTag.FrameCount = r',    XOut.FrameCount = Cardinal(r));
    Check('TI09 delay+pad+samples = frames*1152',
      (LOut.EncoderDelay + LOut.EncoderPadding + TOTAL_SAMPLES) = Cardinal(r * 1152));

    { TI10: plain XingWriteFrame (no LAME) -> LameReadFrame returns False }
    MP3Out.Size := 0;
    XingWriteFrame(MP3Out, Cfg, CH, MakeXingTag(False, 1, FRAME_BYTES));
    Check('TI10 plain Xing -> LameReadFrame False',
      not LameReadFrame(MP3Out, Cfg, CH, XOut, LOut));
  finally
    WavIn.Free;
    MP3Out.Free;
  end;
end;

// ---------------------------------------------------------------------------

var
  T0: TDateTime;
begin
  T0 := Now;
  WriteLn('=== TestMP3EncPhase18 ===');
  WriteLn;
  TestLAMEBinaryLayout;
  WriteLn;
  TestLAMERoundtrip;
  WriteLn;
  TestIntegration;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%.0f ms)',
    [GPassed, GPassed + GFailed, (Now - T0) * 86400000]));
  if GFailed = 0 then WriteLn('ALL PASSED')
  else             WriteLn(Format('%d FAILED', [GFailed]));
  ExitCode := GFailed;
end.
