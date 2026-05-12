program ResamplerTests;

{$APPTYPE CONSOLE}

uses
  SysUtils, Math, AudioTypes, AudioResampler;

var
  GTotal, GPassed: Integer;

procedure Check(const Name: string; Cond: Boolean);
begin
  Inc(GTotal);
  if Cond then
  begin
    Inc(GPassed);
    WriteLn('  OK  ', Name);
  end
  else
    WriteLn('FAIL  ', Name);
end;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function MakeBuf(Channels, Frames: Integer; Value: Single): TAudioBuffer;
var Ch, I: Integer;
begin
  SetLength(Result, Channels);
  for Ch := 0 to Channels - 1 do
  begin
    SetLength(Result[Ch], Frames);
    for I := 0 to Frames - 1 do
      Result[Ch][I] := Value;
  end;
end;

function MakeSine(Channels, Frames: Integer; Freq, SampleRate: Double): TAudioBuffer;
var Ch, I: Integer;
begin
  SetLength(Result, Channels);
  for Ch := 0 to Channels - 1 do
  begin
    SetLength(Result[Ch], Frames);
    for I := 0 to Frames - 1 do
      Result[Ch][I] := Sin(2.0 * Pi * Freq / SampleRate * I);
  end;
end;

// Slice InputBuf[StartFrame..StartFrame+Frames-1]
function SliceBuf(const Src: TAudioBuffer; StartFrame, Frames: Integer): TAudioBuffer;
var Ch, I: Integer;
begin
  SetLength(Result, Length(Src));
  for Ch := 0 to Length(Src) - 1 do
  begin
    SetLength(Result[Ch], Frames);
    for I := 0 to Frames - 1 do
      Result[Ch][I] := Src[Ch][StartFrame + I];
  end;
end;

// RMS of Buf[Ch][Start..Start+Len-1]
function RMS(const Buf: TAudioBuffer; Ch, Start, Len: Integer): Double;
var I: Integer;
begin
  Result := 0.0;
  for I := Start to Start + Len - 1 do
    Result := Result + Buf[Ch][I] * Buf[Ch][I];
  if Len > 0 then Result := Sqrt(Result / Len);
end;

// Mean of Buf[Ch][Start..Start+Len-1]
function Mean(const Buf: TAudioBuffer; Ch, Start, Len: Integer): Double;
var I: Integer;
begin
  Result := 0.0;
  for I := Start to Start + Len - 1 do
    Result := Result + Buf[Ch][I];
  if Len > 0 then Result := Result / Len;
end;

function AllInRange(const Buf: TAudioBuffer; Lo, Hi: Single): Boolean;
var Ch, I: Integer;
begin
  Result := True;
  for Ch := 0 to Length(Buf) - 1 do
    for I := 0 to Length(Buf[Ch]) - 1 do
      if (Buf[Ch][I] < Lo) or (Buf[Ch][I] > Hi) then
      begin
        Result := False;
        Exit;
      end;
end;

function BuffersEqual(const A, B: TAudioBuffer; Tol: Double): Boolean;
var Ch, I: Integer;
begin
  Result := False;
  if Length(A) <> Length(B) then Exit;
  for Ch := 0 to Length(A) - 1 do
  begin
    if Length(A[Ch]) <> Length(B[Ch]) then Exit;
    for I := 0 to Length(A[Ch]) - 1 do
      if Abs(A[Ch][I] - B[Ch][I]) > Tol then Exit;
  end;
  Result := True;
end;

// ---------------------------------------------------------------------------
// RS01-RS05: Constructor and properties
// ---------------------------------------------------------------------------

procedure TestRS01;
var R: TAudioResampler;
begin
  R := TAudioResampler.Create(44100, 48000, 2, rqMedium);
  try
    Check('RS01 SrcRate', R.SrcRate = 44100);
    Check('RS02 DstRate', R.DstRate = 48000);
    Check('RS03 Channels', R.Channels = 2);
    Check('RS04 Quality', R.Quality = rqMedium);
    Check('RS05 Available=0 initially', R.Available = 0);
  finally
    R.Free;
  end;
end;

// ---------------------------------------------------------------------------
// RS06-RS10: Output lengths
// ---------------------------------------------------------------------------

procedure TestOutputLengths;
var
  R  : TAudioResampler;
  In100 : TAudioBuffer;
  Out   : TAudioBuffer;
begin
  In100 := MakeBuf(1, 100, 0.0);

  // RS06: 22050→44100 (P=2, Q=1): 100 in → 200 out
  R := TAudioResampler.Create(22050, 44100, 1, rqFast);
  try
    Out := R.Resample(In100);
    Check('RS06 2x upsample OutLen=200', Length(Out[0]) = 200);
  finally R.Free; end;

  // RS07: 44100→22050 (P=1, Q=2): 100 in → 50 out
  R := TAudioResampler.Create(44100, 22050, 1, rqFast);
  try
    Out := R.Resample(In100);
    Check('RS07 2x downsample OutLen=50', Length(Out[0]) = 50);
  finally R.Free; end;

  // RS08: 44100→48000 (P=160, Q=147), InLen=4096 → OutLen=4459
  R := TAudioResampler.Create(44100, 48000, 1, rqFast);
  try
    Out := R.Resample(MakeBuf(1, 4096, 0.0));
    Check('RS08 44100→48000 OutLen=4459', Length(Out[0]) = 4459);
  finally R.Free; end;

  // RS09: 48000→44100 (P=147, Q=160), InLen=4096 → OutLen=3764
  R := TAudioResampler.Create(48000, 44100, 1, rqFast);
  try
    Out := R.Resample(MakeBuf(1, 4096, 0.0));
    Check('RS09 48000→44100 OutLen=3764', Length(Out[0]) = 3764);
  finally R.Free; end;

  // RS10: same rate (P=Q=1), InLen=100 → OutLen=100
  R := TAudioResampler.Create(44100, 44100, 1, rqFast);
  try
    Out := R.Resample(In100);
    Check('RS10 same-rate OutLen=100', Length(Out[0]) = 100);
  finally R.Free; end;
end;

// ---------------------------------------------------------------------------
// RS11-RS15: Signal tests — zero and DC
// ---------------------------------------------------------------------------

procedure TestSignals;
var
  R       : TAudioResampler;
  ZeroIn, DCIn : TAudioBuffer;
  Out     : TAudioBuffer;
  Settle  : Integer;
  M       : Double;
begin
  ZeroIn := MakeBuf(1, 1000, 0.0);
  DCIn   := MakeBuf(1, 1000, 0.5);

  // RS11: zero input → zero output (2x upsample)
  R := TAudioResampler.Create(22050, 44100, 1, rqFast);
  try
    Out := R.Resample(ZeroIn);
    Check('RS11 zero→2x upsample: all zeros', AllInRange(Out, 0.0, 0.0));
  finally R.Free; end;

  // RS12: zero input → zero output (2x downsample)
  R := TAudioResampler.Create(44100, 22050, 1, rqFast);
  try
    Out := R.Resample(ZeroIn);
    Check('RS12 zero→2x downsample: all zeros', AllInRange(Out, 0.0, 0.0));
  finally R.Free; end;

  // RS13: DC 0.5 → 2x upsample: mean ≈ 0.5 after settling (skip 2×FTaps)
  R := TAudioResampler.Create(22050, 44100, 1, rqFast);
  try
    Out := R.Resample(DCIn);
    Settle := 2 * R.Latency;  // FTaps = Latency property
    M := Mean(Out, 0, Settle, Length(Out[0]) - Settle);
    Check('RS13 DC→2x upsample mean≈0.5', Abs(M - 0.5) < 0.005);
  finally R.Free; end;

  // RS14: DC 0.5 → 2x downsample: mean ≈ 0.5 after settling
  R := TAudioResampler.Create(44100, 22050, 1, rqFast);
  try
    Out := R.Resample(DCIn);
    Settle := 2 * R.Latency;
    if Settle >= Length(Out[0]) then Settle := 0;
    M := Mean(Out, 0, Settle, Length(Out[0]) - Settle);
    Check('RS14 DC→2x downsample mean≈0.5', Abs(M - 0.5) < 0.005);
  finally R.Free; end;

  // RS15: output values always in [-1, 1] for unit sine
  R := TAudioResampler.Create(22050, 44100, 1, rqMedium);
  try
    Out := R.Resample(MakeSine(1, 2000, 1000, 22050));
    Check('RS15 output clamped to [-1,1]', AllInRange(Out, -1.0, 1.0));
  finally R.Free; end;
end;

// ---------------------------------------------------------------------------
// RS16-RS20: Stereo and RMS tests
// ---------------------------------------------------------------------------

procedure TestStereoAndRMS;
var
  R   : TAudioResampler;
  In2 : TAudioBuffer;
  Out : TAudioBuffer;
  I   : Integer;
  RMSIn, RMSOut, Ratio : Double;
  Settle : Integer;
begin
  // RS16: Stereo 2x upsample produces 2-channel output
  R := TAudioResampler.Create(22050, 44100, 2, rqFast);
  try
    In2 := MakeSine(2, 500, 200, 22050);
    Out := R.Resample(In2);
    Check('RS16 stereo upsample: 2 channels out', Length(Out) = 2);
  finally R.Free; end;

  // RS17: Stereo channels processed independently
  // Ch0 = 0.5 DC, Ch1 = -0.5 DC
  R := TAudioResampler.Create(22050, 44100, 2, rqFast);
  try
    SetLength(In2, 2);
    SetLength(In2[0], 500); SetLength(In2[1], 500);
    for I := 0 to 499 do begin In2[0][I] := 0.5; In2[1][I] := -0.5; end;
    Out := R.Resample(In2);
    Settle := 2 * R.Latency;
    Check('RS17 stereo ch0 mean≈+0.5', Abs(Mean(Out, 0, Settle, Length(Out[0])-Settle) - 0.5)  < 0.01);
    Check('RS18 stereo ch1 mean≈-0.5', Abs(Mean(Out, 1, Settle, Length(Out[1])-Settle) + 0.5)  < 0.01);
  finally R.Free; end;

  // RS19: Sine RMS preserved through 2x upsample (within 2%)
  R := TAudioResampler.Create(22050, 44100, 1, rqMedium);
  try
    In2 := MakeSine(1, 2000, 100, 22050);
    Out := R.Resample(In2);
    Settle := 2 * R.Latency;
    RMSIn  := RMS(In2, 0, Settle, Length(In2[0]) - Settle);
    RMSOut := RMS(Out, 0, Settle*2, Length(Out[0]) - Settle*2);
    Ratio  := RMSOut / RMSIn;
    Check('RS19 sine RMS preserved 2x upsample', Abs(Ratio - 1.0) < 0.02);
  finally R.Free; end;

  // RS20: Sine RMS preserved through 44100→48000 (within 3%)
  R := TAudioResampler.Create(44100, 48000, 1, rqMedium);
  try
    In2 := MakeSine(1, 4000, 100, 44100);
    Out := R.Resample(In2);
    Settle := 2 * R.Latency;
    RMSIn  := RMS(In2, 0, Settle, Length(In2[0]) - Settle);
    RMSOut := RMS(Out, 0, Settle, Length(Out[0]) - Settle);
    Ratio  := RMSOut / RMSIn;
    Check('RS20 sine RMS preserved 44100→48000', Abs(Ratio - 1.0) < 0.03);
  finally R.Free; end;
end;

// ---------------------------------------------------------------------------
// RS21-RS23: Batch and history continuity
// ---------------------------------------------------------------------------

procedure TestContinuity;
var
  R1, R2  : TAudioResampler;
  Input   : TAudioBuffer;
  Half1, Half2 : TAudioBuffer;
  Out1, Out2a, Out2b : TAudioBuffer;
  CatOut  : TAudioBuffer;
  Ch, I   : Integer;
  Equal   : Boolean;
begin
  // RS21: Full batch == two half-batches (2x upsample, 1000 frames)
  Input := MakeSine(1, 1000, 200, 22050);
  R1 := TAudioResampler.Create(22050, 44100, 1, rqFast);
  R2 := TAudioResampler.Create(22050, 44100, 1, rqFast);
  try
    Out1  := R1.Resample(Input);
    Out2a := R2.Resample(Input, 500);
    Half2 := SliceBuf(Input, 500, 500);
    Out2b := R2.Resample(Half2);

    // Concatenate Out2a + Out2b and compare with Out1
    Equal := (Length(Out1[0]) = Length(Out2a[0]) + Length(Out2b[0]));
    if Equal then
      for I := 0 to Length(Out2b[0]) - 1 do
        if Abs(Out1[0][Length(Out2a[0]) + I] - Out2b[0][I]) > 1E-5 then
        begin Equal := False; Break; end;
    Check('RS21 full batch == two half-batches', Equal);
  finally R1.Free; R2.Free; end;

  // RS22: Phase tracking — 6 batches of 147 frames at 44100→48000 → 160 each
  R1 := TAudioResampler.Create(44100, 48000, 1, rqFast);
  try
    Input := MakeBuf(1, 147, 0.0);
    Equal := True;
    for I := 1 to 6 do
    begin
      Out1 := R1.Resample(Input);
      if Length(Out1[0]) <> 160 then Equal := False;
    end;
    Check('RS22 phase tracking: 6×147→6×160', Equal);
  finally R1.Free; end;

  // RS23: History continuity — 44100→48000, 3 batches of 300 == 1 batch of 900
  Input := MakeSine(1, 900, 200, 44100);
  R1 := TAudioResampler.Create(44100, 48000, 1, rqFast);
  R2 := TAudioResampler.Create(44100, 48000, 1, rqFast);
  try
    Out1 := R1.Resample(Input);

    // R2: three batches of 300
    SetLength(CatOut, 1);
    SetLength(CatOut[0], 0);
    for I := 0 to 2 do
    begin
      Half1 := SliceBuf(Input, I * 300, 300);
      Out2a := R2.Resample(Half1);
      Ch := Length(CatOut[0]);
      SetLength(CatOut[0], Ch + Length(Out2a[0]));
      if Length(Out2a[0]) > 0 then
        Move(Out2a[0][0], CatOut[0][Ch], Length(Out2a[0]) * SizeOf(Single));
    end;

    Equal := (Length(CatOut[0]) = Length(Out1[0]));
    if Equal then
      for I := 0 to Length(CatOut[0]) - 1 do
        if Abs(CatOut[0][I] - Out1[0][I]) > 1E-5 then
        begin Equal := False; Break; end;
    Check('RS23 history continuity: 3×300 == 1×900', Equal);
  finally R1.Free; R2.Free; end;
end;

// ---------------------------------------------------------------------------
// RS24-RS28: Streaming (Push/Pull)
// ---------------------------------------------------------------------------

procedure TestStreaming;
var
  R1, R2 : TAudioResampler;
  Input  : TAudioBuffer;
  OutR, OutP : TAudioBuffer;
  Pulled1 : TAudioBuffer;
  I : Integer;
begin
  Input := MakeSine(1, 1000, 300, 22050);

  // RS24: Push+Pull gives same result as Resample
  R1 := TAudioResampler.Create(22050, 44100, 1, rqFast);
  R2 := TAudioResampler.Create(22050, 44100, 1, rqFast);
  try
    OutR := R1.Resample(Input);
    R2.Push(Input);
    OutP := R2.Pull;
    Check('RS24 Push+Pull == Resample', BuffersEqual(OutR, OutP, 1E-5));
  finally R1.Free; R2.Free; end;

  // RS25: Multiple small pushes accumulate correctly
  R1 := TAudioResampler.Create(22050, 44100, 1, rqFast);
  R2 := TAudioResampler.Create(22050, 44100, 1, rqFast);
  try
    OutR := R1.Resample(Input);
    for I := 0 to 9 do
      R2.Push(SliceBuf(Input, I * 100, 100));
    OutP := R2.Pull;
    Check('RS25 10×100 pushes == 1×1000', BuffersEqual(OutR, OutP, 1E-5));
  finally R1.Free; R2.Free; end;

  // RS26: Pull with MaxFrames
  R1 := TAudioResampler.Create(22050, 44100, 1, rqFast);
  try
    R1.Push(Input);
    Pulled1 := R1.Pull(100);
    Check('RS26 Pull MaxFrames=100 returns 100', Length(Pulled1[0]) = 100);
  finally R1.Free; end;

  // RS27: Available tracks pushed frames
  R1 := TAudioResampler.Create(22050, 44100, 1, rqFast);
  try
    Check('RS27a Available=0 before push', R1.Available = 0);
    R1.Push(SliceBuf(Input, 0, 500));
    Check('RS27b Available>0 after push', R1.Available > 0);
  finally R1.Free; end;

  // RS28: Pull all leaves Available=0
  R1 := TAudioResampler.Create(22050, 44100, 1, rqFast);
  try
    R1.Push(Input);
    Pulled1 := R1.Pull;   // pull everything
    Check('RS28 Available=0 after full pull', R1.Available = 0);
  finally R1.Free; end;
end;

// ---------------------------------------------------------------------------
// RS29-RS30: Quality levels
// ---------------------------------------------------------------------------

procedure TestQualities;
var
  R   : TAudioResampler;
  Out : TAudioBuffer;
  Buf : TAudioBuffer;
begin
  Buf := MakeBuf(1, 4096, 0.0);

  // RS29: rqFast produces correct output count
  R := TAudioResampler.Create(44100, 48000, 1, rqFast);
  try
    Out := R.Resample(Buf);
    Check('RS29 rqFast OutLen=4459', Length(Out[0]) = 4459);
  finally R.Free; end;

  // RS30: rqHigh produces correct output count
  R := TAudioResampler.Create(44100, 48000, 1, rqHigh);
  try
    Out := R.Resample(Buf);
    Check('RS30 rqHigh OutLen=4459', Length(Out[0]) = 4459);
  finally R.Free; end;
end;

// ---------------------------------------------------------------------------

begin
  GTotal  := 0;
  GPassed := 0;

  WriteLn('AudioResampler tests');
  WriteLn('--------------------');

  TestRS01;
  TestOutputLengths;
  TestSignals;
  TestStereoAndRMS;
  TestContinuity;
  TestStreaming;
  TestQualities;

  WriteLn('--------------------');
  WriteLn(GPassed, '/', GTotal, ' tests passed.');
  if GPassed < GTotal then Halt(1);
end.
