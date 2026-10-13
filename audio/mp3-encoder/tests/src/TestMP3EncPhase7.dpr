program TestMP3EncPhase7;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  System.Math,
  MP3EncEncoder;

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

function MakeSilence: T1152;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

function MakeSine(AFreqHz, ASampleRate: Double): T1152;
var
  i: Integer;
begin
  for i := 0 to ENC_PCM_PER_FRAME - 1 do
    Result[i] := 16384.0 * Sin(2 * Pi * AFreqHz * i / ASampleRate);
end;

// -- FB: EncFrameBytes -------------------------------------------------------

procedure TestFrameBytes;
begin
  WriteLn('FB: EncFrameBytes');
  Check('FB01 128kbps 44100 no pad = 417',  EncFrameBytes(9, 0, 0) = 417);
  Check('FB02 128kbps 44100 pad=1 = 418',   EncFrameBytes(9, 0, 1) = 418);
  Check('FB03 64kbps  44100 no pad = 208',  EncFrameBytes(5, 0, 0) = 208);
  Check('FB04 320kbps 44100 no pad = 1044', EncFrameBytes(14, 0, 0) = 1044);
  Check('FB05 128kbps 48000 no pad = 384',  EncFrameBytes(9, 1, 0) = 384);
end;

// -- EI: EncInit -------------------------------------------------------------

procedure TestEncInit;
var
  Enc: TMP3Encoder;
  Cfg: TEncConfig;
begin
  WriteLn('EI: EncInit');
  Cfg.SrIdx := 0; Cfg.BrIdx := 9; Cfg.Padding := 0;
  EncInit(Enc, Cfg);

  Check('EI01 FrameBytes = 417',   Enc.FrameBytes = 417);
  Check('EI02 TargBits = 1584',    Enc.TargBits = 1584);  { (417*8 - 168) / 2 }
  Check('EI03 TargBits > 0',       Enc.TargBits > 0);

  Cfg.BrIdx := 5;  { 64 kbps }
  EncInit(Enc, Cfg);
  Check('EI04 64kbps FrameBytes = 208', Enc.FrameBytes = 208);
  Check('EI05 64kbps TargBits > 0',     Enc.TargBits > 0);
end;

// -- EF: EncodeFrame (silence) -----------------------------------------------

procedure TestEncFrameSilence;
var
  Enc: TMP3Encoder;
  Cfg: TEncConfig;
  PCM: T1152;
  Frame: TBytes;
begin
  WriteLn('EF: EncodeFrame (silence)');
  Cfg.SrIdx := 0; Cfg.BrIdx := 9; Cfg.Padding := 0;
  EncInit(Enc, Cfg);
  PCM := MakeSilence;

  Frame := EncodeFrame(Enc, PCM);
  Check('EF01 silence length = 417',   Length(Frame) = 417);
  Check('EF02 silence [0] = 0xFF',     Frame[0] = $FF);
  Check('EF03 silence [1] = 0xFB',     Frame[1] = $FB);
  Check('EF04 silence [2] = 0x90',     Frame[2] = $90);
  Check('EF05 silence [3] = 0xC4',     Frame[3] = $C4);

  { Second frame — same silence, state has updated PrevSub but output length is stable }
  Frame := EncodeFrame(Enc, PCM);
  Check('EF06 frame 2 length = 417',   Length(Frame) = 417);
  Check('EF07 frame 2 [0] = 0xFF',     Frame[0] = $FF);
  Check('EF08 frame 2 [1] = 0xFB',     Frame[1] = $FB);
end;

// -- ES: EncodeFrame (sine wave) ---------------------------------------------

procedure TestEncFrameSine;
var
  Enc: TMP3Encoder;
  Cfg: TEncConfig;
  PCM: T1152;
  Frame: TBytes;
begin
  WriteLn('ES: EncodeFrame (sine wave)');
  Cfg.SrIdx := 0; Cfg.BrIdx := 9; Cfg.Padding := 0;
  EncInit(Enc, Cfg);
  PCM := MakeSine(440.0, 44100.0);

  Frame := EncodeFrame(Enc, PCM);
  Check('ES01 sine length = 417',   Length(Frame) = 417);
  Check('ES02 sine [0] = 0xFF',     Frame[0] = $FF);
  Check('ES03 sine [1] = 0xFB',     Frame[1] = $FB);
  Check('ES04 sine [2] = 0x90',     Frame[2] = $90);
  Check('ES05 sine [3] = 0xC4',     Frame[3] = $C4);

  { Encode a second sine frame — encoder state now includes prev subband samples }
  Frame := EncodeFrame(Enc, PCM);
  Check('ES06 sine frame 2 length = 417', Length(Frame) = 417);
end;

var
  T0: TDateTime;
begin
  T0 := Now;
  WriteLn('=== TestMP3EncPhase7 ===');
  WriteLn;
  TestFrameBytes;
  WriteLn;
  TestEncInit;
  WriteLn;
  TestEncFrameSilence;
  WriteLn;
  TestEncFrameSine;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%.0f ms)',
    [GPassed, GPassed + GFailed, (Now - T0) * 86400000]));
  if GFailed = 0 then WriteLn('ALL PASSED')
  else             WriteLn(Format('%d FAILED', [GFailed]));
  ExitCode := GFailed;
end.
