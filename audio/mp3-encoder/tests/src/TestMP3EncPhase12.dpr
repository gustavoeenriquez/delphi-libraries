program TestMP3EncPhase12;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  MP3EncBitWriter,
  MP3EncFrame,
  MP3EncBitReader,
  MP3DecFrame;

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

function MakeBytes(const AVals: array of Byte): TBytes;
var
  i: Integer;
begin
  SetLength(Result, Length(AVals));
  for i := 0 to High(AVals) do
    Result[i] := AVals[i];
end;

procedure SetMonoCfg(out ACfg: TFrameConfig);
begin
  FillChar(ACfg, SizeOf(ACfg), 0);
  ACfg.VersionBits     := FRAME_VER_MPEG1;
  ACfg.LayerBits       := FRAME_LAY_III;
  ACfg.ProtectionBit   := FRAME_NO_CRC;
  ACfg.BitrateIndex    := 9;
  ACfg.SamplerateIndex := 0;
  ACfg.Original        := 1;
  ACfg.ChannelMode     := FRAME_CH_MONO;
  ACfg.Channels        := 1;
  ACfg.Granules        := 2;
end;

procedure SetStereoCfg(out ACfg: TFrameConfig);
begin
  FillChar(ACfg, SizeOf(ACfg), 0);
  ACfg.VersionBits     := FRAME_VER_MPEG1;
  ACfg.LayerBits       := FRAME_LAY_III;
  ACfg.ProtectionBit   := FRAME_NO_CRC;
  ACfg.BitrateIndex    := 9;
  ACfg.SamplerateIndex := 0;
  ACfg.Original        := 1;
  ACfg.ChannelMode     := FRAME_CH_DUAL;
  ACfg.Channels        := 2;
  ACfg.Granules        := 2;
end;

function BuildHeaderSI(const ACfg: TFrameConfig;
  const ASI: TFrameSideInfo): TBytes;
var
  BW: TMP3BitWriter;
begin
  BW := TMP3BitWriter.Create;
  try
    FrameWriteHeader(BW, ACfg);
    FrameWriteSideInfo(BW, ACfg, ASI);
    Result := BW.GetBytes;
  finally
    BW.Free;
  end;
end;

// ---------------------------------------------------------------------------
// BR: BitReader basic operations
// ---------------------------------------------------------------------------

procedure TestBitReaderBasic;
var
  BR  : TMP3BitReader;
  Buf : TBytes;
  V   : Cardinal;
begin
  WriteLn('BR: BitReader basic');

  { BR01: init sets BitsLeft }
  Buf := MakeBytes([$A5]);
  BitReaderInit(BR, Buf);
  Check('BR01 BitsLeft = 8',       BitReaderBitsLeft(BR) = 8);

  { BR02-BR03: read full byte }
  V := BitReaderRead(BR, 8);
  Check('BR02 read $A5',           V = $A5);
  Check('BR03 BitsLeft after = 0', BitReaderBitsLeft(BR) = 0);

  { BR04-BR05: read two nibbles from $53 = 0101 0011 }
  Buf := MakeBytes([$53]);
  BitReaderInit(BR, Buf);
  V := BitReaderRead(BR, 4);
  Check('BR04 high nibble = 5',    V = 5);
  V := BitReaderRead(BR, 4);
  Check('BR05 low nibble = 3',     V = 3);

  { BR06-BR08: peek doesn't advance }
  Buf := MakeBytes([$AB]);
  BitReaderInit(BR, Buf);
  V := BitReaderPeek(BR, 4);
  Check('BR06 peek = $A',          V = $A);
  Check('BR07 peek pos unchanged', BitReaderBitsLeft(BR) = 8);
  V := BitReaderRead(BR, 4);
  Check('BR08 read = $A',          V = $A);

  { BR09: skip advances without returning value }
  Buf := MakeBytes([$AB]);
  BitReaderInit(BR, Buf);
  BitReaderSkip(BR, 4);
  V := BitReaderRead(BR, 4);
  Check('BR09 after skip read $B', V = $B);

  { BR10-BR11: cross-byte 12-bit read from $AB $CD -> $ABC, $D }
  Buf := MakeBytes([$AB, $CD]);
  BitReaderInit(BR, Buf);
  V := BitReaderRead(BR, 12);
  Check('BR10 12-bit = $ABC',      V = $ABC);
  V := BitReaderRead(BR, 4);
  Check('BR11 remaining = $D',     V = $D);

  { BR12: read 1 bit at a time from $FF }
  Buf := MakeBytes([$FF]);
  BitReaderInit(BR, Buf);
  Check('BR12 all bits 1',
    (BitReaderRead(BR,1)=1) and (BitReaderRead(BR,1)=1) and
    (BitReaderRead(BR,1)=1) and (BitReaderRead(BR,1)=1) and
    (BitReaderRead(BR,1)=1) and (BitReaderRead(BR,1)=1) and
    (BitReaderRead(BR,1)=1) and (BitReaderRead(BR,1)=1));

  { BR13: 16-bit read }
  Buf := MakeBytes([$12, $34]);
  BitReaderInit(BR, Buf);
  Check('BR13 16-bit = $1234',     BitReaderRead(BR, 16) = $1234);

  { BR14-BR15: InitBits with smaller bitcount }
  Buf := MakeBytes([$A5]);
  BitReaderInitBits(BR, Buf, 4);
  Check('BR14 initbits BitsLeft=4', BitReaderBitsLeft(BR) = 4);
  Check('BR15 initbits read = $A',  BitReaderRead(BR, 4) = $A);

  { BR16: InitAt starts reading mid-buffer }
  Buf := MakeBytes([$00, $5A]);
  BitReaderInitAt(BR, Buf, 1);
  Check('BR16 initAt read = $5A',  BitReaderRead(BR, 8) = $5A);
end;

// ---------------------------------------------------------------------------
// BW: BitWriter -> BitReader roundtrip
// ---------------------------------------------------------------------------

procedure TestBitReaderRoundtrip;
var
  BW  : TMP3BitWriter;
  BR  : TMP3BitReader;
  Buf : TBytes;
begin
  WriteLn('BW: BitWriter->BitReader roundtrip');

  BW := TMP3BitWriter.Create;
  try
    BW.WriteBits($1,    1);
    BW.WriteBits($A,    4);
    BW.WriteBits($1F5,  9);
    BW.WriteBits($0,    2);
    Buf := BW.GetBytes;
  finally
    BW.Free;
  end;

  BitReaderInit(BR, Buf);
  Check('BW01 read 1 = 1',     BitReaderRead(BR, 1) = 1);
  Check('BW02 read 4 = $A',    BitReaderRead(BR, 4) = $A);
  Check('BW03 read 9 = $1F5',  BitReaderRead(BR, 9) = $1F5);
  Check('BW04 read 2 = 0',     BitReaderRead(BR, 2) = 0);

  BW := TMP3BitWriter.Create;
  try
    BW.WriteBits($ABCDEF, 24);
    Buf := BW.GetBytes;
  finally
    BW.Free;
  end;
  BitReaderInit(BR, Buf);
  Check('BW05 24-bit = $ABCDEF', BitReaderRead(BR, 24) = $ABCDEF);
end;

// ---------------------------------------------------------------------------
// FH: FrameParseHeader
// ---------------------------------------------------------------------------

procedure TestFrameParseHeader;
var
  Buf : TBytes;
  Cfg : TFrameConfig;
begin
  WriteLn('FH: FrameParseHeader');

  { FH01: empty -> False }
  SetLength(Buf, 0);
  Check('FH01 empty -> False',    not FrameParseHeader(Buf, 0, Cfg));

  { FH02: 3 bytes -> False }
  Buf := MakeBytes([$FF, $FB, $90]);
  Check('FH02 3 bytes -> False',  not FrameParseHeader(Buf, 0, Cfg));

  { FH03: bad sync (first bit 0) -> False }
  Buf := MakeBytes([$FE, $FB, $90, $C4]);
  Check('FH03 bad sync -> False', not FrameParseHeader(Buf, 0, Cfg));

  { FH04: MPEG2 version (byte[1]=FF 10 01 1 = $F3) -> False }
  Buf := MakeBytes([$FF, $F3, $90, $C4]);
  Check('FH04 MPEG2 -> False',    not FrameParseHeader(Buf, 0, Cfg));

  { FH05: Layer II (byte[1]=111 11 10 1 = $FD) -> False }
  Buf := MakeBytes([$FF, $FD, $90, $C4]);
  Check('FH05 LayerII -> False',  not FrameParseHeader(Buf, 0, Cfg));

  { FH06-FH15: mono 128kbps/44100 = FF FB 90 C4 }
  Buf := MakeBytes([$FF, $FB, $90, $C4]);
  Check('FH06 mono -> True',       FrameParseHeader(Buf, 0, Cfg));
  Check('FH07 BitrateIndex = 9',   Cfg.BitrateIndex = 9);
  Check('FH08 SrIdx = 0',          Cfg.SamplerateIndex = 0);
  Check('FH09 Channels = 1',       Cfg.Channels = 1);
  Check('FH10 Granules = 2',       Cfg.Granules = 2);
  Check('FH11 Version = MPEG1',    Cfg.VersionBits = FRAME_VER_MPEG1);
  Check('FH12 Layer = III',        Cfg.LayerBits = FRAME_LAY_III);
  Check('FH13 Padding = 0',        Cfg.Padding = 0);
  Check('FH14 Original = 1',       Cfg.Original = 1);
  Check('FH15 ChannelMode = MONO', Cfg.ChannelMode = FRAME_CH_MONO);

  { FH16-FH18: stereo 128kbps/44100 = FF FB 90 84 }
  Buf := MakeBytes([$FF, $FB, $90, $84]);
  Check('FH16 stereo -> True',     FrameParseHeader(Buf, 0, Cfg));
  Check('FH17 Channels = 2',       Cfg.Channels = 2);
  Check('FH18 ChannelMode = DUAL', Cfg.ChannelMode = FRAME_CH_DUAL);

  { FH19-FH20: non-zero byte offset }
  Buf := MakeBytes([0, 0, $FF, $FB, $90, $C4]);
  Check('FH19 offset=2 -> True',   FrameParseHeader(Buf, 2, Cfg));
  Check('FH20 offset Channels=1',  Cfg.Channels = 1);
end;

// ---------------------------------------------------------------------------
// FS: FrameParseSideInfo
// ---------------------------------------------------------------------------

procedure TestFrameParseSideInfo;
var
  FCfg   : TFrameConfig;
  FCfgP  : TFrameConfig;
  SI     : TFrameSideInfo;
  SIOut  : TFrameSideInfo;
  Buf    : TBytes;
begin
  WriteLn('FS: FrameParseSideInfo');

  { FS01-FS05: silence mono frame (all-zero SI) }
  SetMonoCfg(FCfg);
  FillChar(SI, SizeOf(SI), 0);
  Buf := BuildHeaderSI(FCfg, SI);
  FrameParseHeader(Buf, 0, FCfgP);
  FrameParseSideInfo(Buf, 4, FCfgP, SIOut);

  Check('FS01 MainDataBegin = 0',      SIOut.MainDataBegin = 0);
  Check('FS02 gr0 Part2_3_Length = 0', SIOut.Gr[0][0].Part2_3_Length = 0);
  Check('FS03 gr1 Part2_3_Length = 0', SIOut.Gr[1][0].Part2_3_Length = 0);
  Check('FS04 BigValues = 0',          SIOut.Gr[0][0].BigValues = 0);
  Check('FS05 GlobalGain = 0',         SIOut.Gr[0][0].GlobalGain = 0);

  { FS06-FS09: silence stereo frame }
  SetStereoCfg(FCfg);
  FillChar(SI, SizeOf(SI), 0);
  Buf := BuildHeaderSI(FCfg, SI);
  FrameParseHeader(Buf, 0, FCfgP);
  FrameParseSideInfo(Buf, 4, FCfgP, SIOut);

  Check('FS06 stereo gr0ch0 P23=0', SIOut.Gr[0][0].Part2_3_Length = 0);
  Check('FS07 stereo gr0ch1 P23=0', SIOut.Gr[0][1].Part2_3_Length = 0);
  Check('FS08 stereo gr1ch0 P23=0', SIOut.Gr[1][0].Part2_3_Length = 0);
  Check('FS09 stereo gr1ch1 P23=0', SIOut.Gr[1][1].Part2_3_Length = 0);

  { FS10-FS25: roundtrip with non-trivial mono SI }
  SetMonoCfg(FCfg);
  FillChar(SI, SizeOf(SI), 0);
  SI.MainDataBegin            := 123;
  SI.Gr[0][0].Part2_3_Length  := 1500;
  SI.Gr[0][0].BigValues       := 200;
  SI.Gr[0][0].GlobalGain      := 200;
  SI.Gr[0][0].ScalefacCompress:= 7;
  SI.Gr[0][0].TableSelect[0]  := 15;
  SI.Gr[0][0].TableSelect[1]  := 9;
  SI.Gr[0][0].TableSelect[2]  := 3;
  SI.Gr[0][0].Region0Count    := 11;
  SI.Gr[0][0].Region1Count    := 3;
  SI.Gr[0][0].Preflag         := 1;
  SI.Gr[0][0].ScalefacScale   := 1;
  SI.Gr[0][0].Count1TableSelect := 1;
  SI.Gr[1][0].Part2_3_Length  := 800;
  SI.Gr[1][0].GlobalGain      := 150;
  SI.Gr[1][0].BigValues       := 100;
  SI.Scfsi[0][1]              := 1;
  SI.Scfsi[0][3]              := 1;

  Buf := BuildHeaderSI(FCfg, SI);
  FrameParseHeader(Buf, 0, FCfgP);
  FrameParseSideInfo(Buf, 4, FCfgP, SIOut);

  Check('FS10 MainDataBegin = 123',       SIOut.MainDataBegin = 123);
  Check('FS11 gr0 Part2_3_Length = 1500', SIOut.Gr[0][0].Part2_3_Length = 1500);
  Check('FS12 gr0 BigValues = 200',       SIOut.Gr[0][0].BigValues = 200);
  Check('FS13 gr0 GlobalGain = 200',      SIOut.Gr[0][0].GlobalGain = 200);
  Check('FS14 ScalefacCompress = 7',      SIOut.Gr[0][0].ScalefacCompress = 7);
  Check('FS15 TableSelect[0] = 15',       SIOut.Gr[0][0].TableSelect[0] = 15);
  Check('FS16 TableSelect[1] = 9',        SIOut.Gr[0][0].TableSelect[1] = 9);
  Check('FS17 TableSelect[2] = 3',        SIOut.Gr[0][0].TableSelect[2] = 3);
  Check('FS18 Region0Count = 11',         SIOut.Gr[0][0].Region0Count = 11);
  Check('FS19 Region1Count = 3',          SIOut.Gr[0][0].Region1Count = 3);
  Check('FS20 Preflag = 1',               SIOut.Gr[0][0].Preflag = 1);
  Check('FS21 ScalefacScale = 1',         SIOut.Gr[0][0].ScalefacScale = 1);
  Check('FS22 Count1TableSelect = 1',     SIOut.Gr[0][0].Count1TableSelect = 1);
  Check('FS23 gr1 Part2_3_Length = 800',  SIOut.Gr[1][0].Part2_3_Length = 800);
  Check('FS24 gr1 GlobalGain = 150',      SIOut.Gr[1][0].GlobalGain = 150);
  Check('FS25 scfsi[0][1] = 1',          SIOut.Scfsi[0][1] = 1);
  Check('FS26 scfsi[0][3] = 1',          SIOut.Scfsi[0][3] = 1);
  Check('FS27 scfsi[0][0] = 0',          SIOut.Scfsi[0][0] = 0);
end;

var
  T0: TDateTime;
begin
  T0 := Now;
  WriteLn('=== TestMP3EncPhase12 ===');
  WriteLn;
  TestBitReaderBasic;
  WriteLn;
  TestBitReaderRoundtrip;
  WriteLn;
  TestFrameParseHeader;
  WriteLn;
  TestFrameParseSideInfo;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%.0f ms)',
    [GPassed, GPassed + GFailed, (Now - T0) * 86400000]));
  if GFailed = 0 then WriteLn('ALL PASSED')
  else             WriteLn(Format('%d FAILED', [GFailed]));
  ExitCode := GFailed;
end.
