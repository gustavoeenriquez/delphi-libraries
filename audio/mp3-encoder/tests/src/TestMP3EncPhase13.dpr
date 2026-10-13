program TestMP3EncPhase13;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Math,
  Classes,
  MP3EncEncoder,
  MP3EncFrame,
  MP3DecFrame,
  MP3EncBitReader,
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

function MakeEncCfg128k44100: TEncConfig;
begin
  Result.SrIdx   := 0;
  Result.BrIdx   := 9;
  Result.Padding := 0;
end;

procedure FillSine(out APCM: T1152; AAmplitude, AFreqHz: Double);
var
  i: Integer;
begin
  for i := 0 to ENC_PCM_PER_FRAME - 1 do
    APCM[i] := AAmplitude * Sin(2 * Pi * AFreqHz * i / 44100.0);
end;

// ---------------------------------------------------------------------------
// MS: PCMToMS math
// ---------------------------------------------------------------------------

procedure TestPCMToMS;
const
  EPS = 1e-9;
var
  L, R, M, S : T1152;
  i           : Integer;
  EnergyErr   : Double;
begin
  WriteLn('MS: PCMToMS math');

  { MS01-MS02: in-phase L=R=1000 -> M=1000*sqrt(2), S=0 }
  for i := 0 to ENC_PCM_PER_FRAME - 1 do begin L[i] := 1000; R[i] := 1000; end;
  PCMToMS(L, R, M, S);
  Check('MS01 in-phase M = 1000*sqrt2', Abs(M[0] - 1000 * Sqrt(2)) < EPS);
  Check('MS02 in-phase S = 0',          Abs(S[0]) < EPS);

  { MS03-MS04: anti-phase L=-R -> M=0, S=L*sqrt(2) }
  for i := 0 to ENC_PCM_PER_FRAME - 1 do begin L[i] := 1000; R[i] := -1000; end;
  PCMToMS(L, R, M, S);
  Check('MS03 anti-phase M = 0',           Abs(M[0]) < EPS);
  Check('MS04 anti-phase S = 1000*sqrt2',  Abs(S[0] - 1000 * Sqrt(2)) < EPS);

  { MS05-MS06: L=2, R=0 -> M=sqrt(2), S=sqrt(2) }
  for i := 0 to ENC_PCM_PER_FRAME - 1 do begin L[i] := 2; R[i] := 0; end;
  PCMToMS(L, R, M, S);
  Check('MS05 L=2 R=0 -> M = sqrt2', Abs(M[0] - Sqrt(2)) < EPS);
  Check('MS06 L=2 R=0 -> S = sqrt2', Abs(S[0] - Sqrt(2)) < EPS);

  { MS07: all zeros -> M=S=0 }
  for i := 0 to ENC_PCM_PER_FRAME - 1 do begin L[i] := 0; R[i] := 0; end;
  PCMToMS(L, R, M, S);
  Check('MS07 zeros -> M=S=0', (Abs(M[0]) < EPS) and (Abs(S[0]) < EPS));

  { MS08: energy preservation: sum(M^2+S^2) = sum(L^2+R^2) }
  FillSine(L, 10000, 440);
  FillSine(R, 8000,  880);
  PCMToMS(L, R, M, S);
  EnergyErr := 0;
  for i := 0 to ENC_PCM_PER_FRAME - 1 do
    EnergyErr := EnergyErr
      + Abs((M[i]*M[i] + S[i]*S[i]) - (L[i]*L[i] + R[i]*R[i]));
  Check('MS08 energy preservation', EnergyErr < 1e-2);

  { MS09-MS10: last sample check }
  for i := 0 to ENC_PCM_PER_FRAME - 1 do begin L[i] := i; R[i] := -i; end;
  PCMToMS(L, R, M, S);
  Check('MS09 last M ~ 0',         Abs(M[ENC_PCM_PER_FRAME - 1]) < EPS);
  Check('MS10 last S = 1151*sqrt2',
    Abs(S[ENC_PCM_PER_FRAME - 1] - (ENC_PCM_PER_FRAME - 1) * Sqrt(2)) < 1e-6);
end;

// ---------------------------------------------------------------------------
// MF: EncodeFrameMS frame structure
// ---------------------------------------------------------------------------

procedure TestEncodeFrameMS;
var
  Enc    : TMP3Encoder;
  Cfg    : TEncConfig;
  L, R   : T1152;
  Frame  : TBytes;
  FCfgP  : TFrameConfig;
  SIOut  : TFrameSideInfo;
  i      : Integer;
begin
  WriteLn('MF: EncodeFrameMS');
  Cfg := MakeEncCfg128k44100;
  EncInitJointStereo(Enc, Cfg);

  { silence input }
  FillChar(L, SizeOf(L), 0);
  FillChar(R, SizeOf(R), 0);
  Frame := EncodeFrameMS(Enc, L, R);

  Check('MF01 frame size = 417',    Length(Frame) = 417);
  Check('MF02 sync byte[0] = $FF',  Frame[0] = $FF);
  Check('MF03 sync byte[1] = $FB',  Frame[1] = $FB);
  { byte[3]: channel_mode=01(JOINT)=01, mode_ext=10, original=1
    -> 01_10_0_1_00 = 0x64 }
  Check('MF04 byte[3] = $64',       Frame[3] = $64);

  { FrameParseHeader round-trip }
  Check('MF05 ParseHeader -> True',  FrameParseHeader(Frame, 0, FCfgP));
  Check('MF06 ChannelMode = JOINT',  FCfgP.ChannelMode = FRAME_CH_JOINT);
  Check('MF07 ModeExt = 2',          FCfgP.ModeExt = 2);
  Check('MF08 Channels = 2',         FCfgP.Channels = 2);

  { non-trivial audio }
  FillSine(L, 16000, 440);
  FillSine(R, 12000, 880);
  EncInitJointStereo(Enc, Cfg);
  Frame := EncodeFrameMS(Enc, L, R);
  Check('MF09 non-trivial size = 417',  Length(Frame) = 417);
  Check('MF10 non-trivial header ok',   FrameParseHeader(Frame, 0, FCfgP));
  FrameParseSideInfo(Frame, 4, FCfgP, SIOut);
  Check('MF11 M-ch gr0 P23 > 0',        SIOut.Gr[0][0].Part2_3_Length > 0);

  { EncInitJointStereo == EncInitStereo for state (same FrameBytes and TargBits) }
  Check('MF12 FrameBytes = 417',  Enc.FrameBytes = 417);

  { sequential frames smoke test }
  EncInitJointStereo(Enc, Cfg);
  for i := 1 to 3 do begin
    FillSine(L, 16000, 440 * i);
    FillSine(R, 12000, 330 * i);
    Frame := EncodeFrameMS(Enc, L, R);
  end;
  Check('MF13 3 sequential frames = 417', Length(Frame) = 417);
end;

// ---------------------------------------------------------------------------
// MW: EncodeWAVStreamMS integration
// ---------------------------------------------------------------------------

procedure TestEncodeWAVStreamMS;
var
  WavIn  : TMemoryStream;
  MP3Out : TMemoryStream;
  Buf    : TBytes;
  Cfg    : TFrameConfig;
  r      : Integer;
  b      : Byte;
begin
  WriteLn('MW: EncodeWAVStreamMS');

  { stereo silence 1152 pairs -> 1 frame of 417 bytes }
  WavIn  := MakeSilenceWAV(2, 44100, 1152);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStreamMS(WavIn, MP3Out, 9, 0);
    Check('MW01 frames = 2',         r = 2);
    Check('MW02 output size = 834',  MP3Out.Size = 834);
    MP3Out.Position := 3;
    MP3Out.ReadBuffer(b, 1);
    Check('MW03 byte[3] = $64',      b = $64);
    SetLength(Buf, MP3Out.Size);
    MP3Out.Position := 0;
    MP3Out.ReadBuffer(Buf[0], MP3Out.Size);
    Check('MW04 ChannelMode = JOINT',
      FrameParseHeader(Buf, 0, Cfg) and (Cfg.ChannelMode = FRAME_CH_JOINT));
    Check('MW05 ModeExt = 2',
      FrameParseHeader(Buf, 0, Cfg) and (Cfg.ModeExt = 2));
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { mono WAV -> fallback to FRAME_CH_MONO }
  WavIn  := MakeSilenceWAV(1, 44100, 1152);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStreamMS(WavIn, MP3Out, 9, 0);
    Check('MW06 mono frames = 2',    r = 2);
    MP3Out.Position := 3;
    MP3Out.ReadBuffer(b, 1);
    Check('MW07 mono byte[3] = $C4', b = $C4);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { invalid WAV -> -1 }
  WavIn  := TMemoryStream.Create;
  MP3Out := TMemoryStream.Create;
  try
    Check('MW08 invalid -> -1',      EncodeWAVStreamMS(WavIn, MP3Out, 9, 0) = -1);
    Check('MW09 empty output',       MP3Out.Size = 0);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { 2304 pairs = 2 frames }
  WavIn  := MakeSilenceWAV(2, 44100, 2 * 1152);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStreamMS(WavIn, MP3Out, 9, 0);
    Check('MW10 3 frames returned',  r = 3);
    Check('MW11 3*417 = 1251 bytes', MP3Out.Size = 1251);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;
end;

// ---------------------------------------------------------------------------
// MC: consistency between MS and dual-channel
// ---------------------------------------------------------------------------

procedure TestConsistency;
var
  WavIn   : TMemoryStream;
  MSOut   : TMemoryStream;
  DualOut : TMemoryStream;
  Enc     : TMP3Encoder;
  Cfg     : TEncConfig;
  L, R    : T1152;
  FrMS    : TBytes;
  FrDual  : TBytes;
  rMS, rDual: Integer;
  i       : Integer;
begin
  WriteLn('MC: MS vs dual-channel consistency');

  { same WAV -> same frame count and total bytes }
  WavIn   := MakeSilenceWAV(2, 44100, 3 * 1152);
  MSOut   := TMemoryStream.Create;
  DualOut := TMemoryStream.Create;
  try
    rMS   := EncodeWAVStreamMS(WavIn, MSOut, 9, 0);
    WavIn.Position := 0;
    rDual := EncodeWAVStream(WavIn, DualOut, 9, 0);
    Check('MC01 MS frame count = dual',  rMS = rDual);
    Check('MC02 MS output size = dual',  MSOut.Size = DualOut.Size);
  finally
    WavIn.Free;
    MSOut.Free;
    DualOut.Free;
  end;

  { EncodeFrameMS and EncodeFrameStereo produce same byte count }
  Cfg := MakeEncCfg128k44100;
  FillSine(L, 16000, 440);
  FillSine(R, 12000, 550);
  EncInitJointStereo(Enc, Cfg);
  FrMS := EncodeFrameMS(Enc, L, R);
  EncInitStereo(Enc, Cfg);
  FrDual := EncodeFrameStereo(Enc, L, R);
  Check('MC03 MS frame bytes = dual frame bytes', Length(FrMS) = Length(FrDual));

  { 5 sequential frames all correct size }
  EncInitJointStereo(Enc, Cfg);
  for i := 0 to 4 do begin
    FillSine(L, 16000 - i * 1000, 440 + i * 110);
    FillSine(R, 12000 - i * 800,  330 + i * 90);
    FrMS := EncodeFrameMS(Enc, L, R);
  end;
  Check('MC04 5 sequential MS frames = 417', Length(FrMS) = 417);
end;

var
  T0: TDateTime;
begin
  T0 := Now;
  WriteLn('=== TestMP3EncPhase13 ===');
  WriteLn;
  TestPCMToMS;
  WriteLn;
  TestEncodeFrameMS;
  WriteLn;
  TestEncodeWAVStreamMS;
  WriteLn;
  TestConsistency;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%.0f ms)',
    [GPassed, GPassed + GFailed, (Now - T0) * 86400000]));
  if GFailed = 0 then WriteLn('ALL PASSED')
  else             WriteLn(Format('%d FAILED', [GFailed]));
  ExitCode := GFailed;
end.
