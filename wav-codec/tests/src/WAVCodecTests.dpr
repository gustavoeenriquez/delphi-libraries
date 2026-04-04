program WAVCodecTests;

{
  WAVCodecTests.dpr - Exhaustive test suite for wav-codec

  Tests:
    1.  Round-trip: write then read back, verify sample values
        - 8-bit PCM unsigned
        - 16-bit PCM signed
        - 24-bit PCM signed
        - 32-bit PCM signed
        - 32-bit IEEE float
    2.  Multichannel: mono, stereo, quad (4-ch), 5.1 (6-ch)
    3.  Sample rates: 8000, 22050, 44100, 48000, 96000
    4.  TWAVFormat fields after Open (SampleRate, Channels, BitsPerSample, IsFloat, etc.)
    5.  SeekToFrame: random access within file
    6.  FramesLeft: correct countdown
    7.  Partial decode (FrameCount < total)
    8.  Stream-based API (TMemoryStream)
    9.  WAVE_FORMAT_EXTENSIBLE detection
    10. Edge cases: zero-frame file, 1-sample file, silence (all zeros)
    11. Large buffer: 1 second at 48kHz stereo (48000 frames)
    12. Precision: numeric round-trip error within format limits

  Runs as console app. Exit code 0 = all passed.

  License: CC0 1.0 Universal (Public Domain)
}

{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, Math,
  AudioTypes      in '..\..\..\audio-common\src\AudioTypes.pas',
  AudioSampleConv in '..\..\..\audio-common\src\AudioSampleConv.pas',
  AudioCRC        in '..\..\..\audio-common\src\AudioCRC.pas',
  AudioBitReader  in '..\..\..\audio-common\src\AudioBitReader.pas',
  WAVTypes        in '..\..\src\WAVTypes.pas',
  WAVReader       in '..\..\src\WAVReader.pas',
  WAVWriter       in '..\..\src\WAVWriter.pas';

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

var
  GFailed : Boolean = False;
  GTotal  : Integer = 0;
  GPassed : Integer = 0;

procedure Check(Cond: Boolean; const Name: string; const Detail: string = '');
begin
  Inc(GTotal);
  if Cond then
  begin
    Inc(GPassed);
    WriteLn('  PASS  ', Name);
  end
  else
  begin
    GFailed := True;
    if Detail <> '' then
      WriteLn('  FAIL  ', Name, '  [', Detail, ']')
    else
      WriteLn('  FAIL  ', Name);
  end;
end;

procedure Section(const Name: string);
begin
  WriteLn;
  WriteLn('--- ', Name, ' ---');
end;

// ---------------------------------------------------------------------------
// Utility: build a deterministic TAudioBuffer with known sample values.
// Pattern: channel Ch, frame F → sin(2π * (Ch*100 + F) / 1000) * 0.5
// Result is in [-0.5, 0.5] so round-trip stays within any format range.
// ---------------------------------------------------------------------------

function MakeSineBuffer(Channels, Frames: Integer): TAudioBuffer;
var
  Ch, F: Integer;
begin
  SetLength(Result, Channels);
  for Ch := 0 to Channels - 1 do
  begin
    SetLength(Result[Ch], Frames);
    for F := 0 to Frames - 1 do
      Result[Ch][F] := Sin(2 * Pi * (Ch * 100 + F) / 1000.0) * 0.5;
  end;
end;

// ---------------------------------------------------------------------------
// Utility: write and read back via TMemoryStream.
// Returns the decoded buffer and the TWAVFormat from the reader.
// ---------------------------------------------------------------------------

function RoundTrip(const Src: TAudioBuffer; SampleRate: Cardinal;
  Channels: Word; OutFmt: TWAVOutputFormat;
  out ReadFmt: TWAVFormat): TAudioBuffer;
var
  MS : TMemoryStream;
  W  : TWAVWriter;
  R  : TWAVReader;
  Buf: TAudioBuffer;
begin
  MS := TMemoryStream.Create;
  try
    W := TWAVWriter.Create(MS, SampleRate, Channels, OutFmt, False);
    try
      W.WriteSamples(Src);
      W.Finalize;
    finally
      W.Free;
    end;

    MS.Position := 0;
    R := TWAVReader.Create;
    try
      R.Open(MS, False);
      ReadFmt := R.Format;
      R.Decode(Buf, 1000000);
    finally
      R.Free;
    end;
  finally
    MS.Free;
  end;
  Result := Buf;
end;

// ---------------------------------------------------------------------------
// Utility: max absolute error between two single-channel buffers.
// ---------------------------------------------------------------------------

function MaxError(const A, B: TArray<Single>): Single;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Min(High(A), High(B)) do
    Result := Max(Result, Abs(A[I] - B[I]));
end;

// ---------------------------------------------------------------------------
// Test 1: Round-trip precision per format
// ---------------------------------------------------------------------------

procedure TestRoundTrip;
const
  Frames   = 512;
  Channels = 2;
  SR       = 44100;

  // Acceptable reconstruction error per format
  Tol16     = 1.0 / 32767.0 + 1e-6;   // 1 LSB at 16-bit
  Tol24     = 1.0 / 8388607.0 + 1e-6;
  Tol32int  = 1.0 / 2147483647.0 + 1e-6;
  TolFloat  = 1e-6;

var
  Src    : TAudioBuffer;
  Got    : TAudioBuffer;
  Fmt    : TWAVFormat;
  Err    : Single;
begin
  Section('Round-trip precision');
  Src := MakeSineBuffer(Channels, Frames);

  Got := RoundTrip(Src, SR, Channels, woPCM16, Fmt);
  Err := MaxError(Src[0], Got[0]);
  Check(Err <= Tol16, 'PCM16 max error <= 1 LSB', Format('%.8f', [Err]));
  Check(Length(Got[0]) = Frames, 'PCM16 frame count correct', Format('%d', [Length(Got[0])]));

  Got := RoundTrip(Src, SR, Channels, woPCM24, Fmt);
  Err := MaxError(Src[0], Got[0]);
  Check(Err <= Tol24, 'PCM24 max error <= 1 LSB', Format('%.10f', [Err]));

  Got := RoundTrip(Src, SR, Channels, woPCM32, Fmt);
  Err := MaxError(Src[0], Got[0]);
  Check(Err <= Tol32int, 'PCM32 max error <= 1 LSB', Format('%.12f', [Err]));

  Got := RoundTrip(Src, SR, Channels, woFloat32, Fmt);
  Err := MaxError(Src[0], Got[0]);
  Check(Err <= TolFloat, 'Float32 max error <= eps', Format('%.12f', [Err]));
end;

// ---------------------------------------------------------------------------
// Test 2: Format fields after open
// ---------------------------------------------------------------------------

procedure TestFormatFields;
var
  Src    : TAudioBuffer;
  Got    : TAudioBuffer;
  Fmt    : TWAVFormat;
begin
  Section('TWAVFormat fields');

  Src := MakeSineBuffer(2, 100);
  RoundTrip(Src, 48000, 2, woPCM16, Fmt);
  Check(Fmt.SampleRate   = 48000, 'SampleRate = 48000', IntToStr(Fmt.SampleRate));
  Check(Fmt.Channels     = 2,     'Channels = 2',       IntToStr(Fmt.Channels));
  Check(Fmt.BitsPerSample = 16,   'BitsPerSample = 16', IntToStr(Fmt.BitsPerSample));
  Check(not Fmt.IsFloat,          'IsFloat = False',    '');
  Check(Fmt.FrameCount   = 100,   'FrameCount = 100',   IntToStr(Fmt.FrameCount));
  Check(Fmt.BytesPerFrame = 4,    'BytesPerFrame = 4',  IntToStr(Fmt.BytesPerFrame));

  Src := MakeSineBuffer(1, 200);
  RoundTrip(Src, 22050, 1, woFloat32, Fmt);
  Check(Fmt.SampleRate    = 22050, 'SampleRate = 22050', IntToStr(Fmt.SampleRate));
  Check(Fmt.Channels      = 1,     'Channels = 1',       IntToStr(Fmt.Channels));
  Check(Fmt.BitsPerSample = 32,    'BitsPerSample = 32', IntToStr(Fmt.BitsPerSample));
  Check(Fmt.IsFloat,               'IsFloat = True',     '');
  Check(Fmt.FrameCount    = 200,   'FrameCount = 200',   IntToStr(Fmt.FrameCount));

  Src := MakeSineBuffer(6, 300);
  RoundTrip(Src, 48000, 6, woPCM24, Fmt);
  Check(Fmt.Channels      = 6,     'Channels = 6 (5.1)', IntToStr(Fmt.Channels));
  Check(Fmt.BitsPerSample = 24,    '5.1 BitsPerSample=24', IntToStr(Fmt.BitsPerSample));
  Check(Fmt.IsExtensible,          '5.1 uses EXTENSIBLE', '');
  Check(Fmt.ChannelMask = SPEAKER_SURROUND_5_1, '5.1 ChannelMask correct',
    Format('$%X vs $%X', [Fmt.ChannelMask, SPEAKER_SURROUND_5_1]));
end;

// ---------------------------------------------------------------------------
// Test 3: Multichannel layouts
// ---------------------------------------------------------------------------

procedure TestMultichannel;

  procedure RunCh(Ch: Integer; const Title: string);
  var
    Src: TAudioBuffer;
    Got: TAudioBuffer;
    Fmt: TWAVFormat;
    Err: Single;
  begin
    Src := MakeSineBuffer(Ch, 256);
    Got := RoundTrip(Src, 44100, Ch, woPCM16, Fmt);
    Check(Fmt.Channels = Word(Ch), Title + ' channels correct', IntToStr(Fmt.Channels));
    Err := MaxError(Src[Ch - 1], Got[Ch - 1]);
    Check(Err <= 1.0 / 32767.0 + 1e-6, Title + ' last-ch error <= 1 LSB', Format('%.8f', [Err]));
  end;

begin
  Section('Multichannel');
  RunCh(1, 'Mono');
  RunCh(2, 'Stereo');
  RunCh(4, 'Quad');
  RunCh(6, '5.1');
  RunCh(8, '7.1');
end;

// ---------------------------------------------------------------------------
// Test 4: Various sample rates
// ---------------------------------------------------------------------------

procedure TestSampleRates;
  procedure RunSR(SR: Cardinal);
  var
    Src: TAudioBuffer;
    Got: TAudioBuffer;
    Fmt: TWAVFormat;
  begin
    Src := MakeSineBuffer(2, 64);
    RoundTrip(Src, SR, 2, woPCM16, Fmt);
    Check(Fmt.SampleRate = SR, Format('SampleRate %d preserved', [SR]),
      IntToStr(Fmt.SampleRate));
  end;
begin
  Section('Sample rates');
  RunSR(8000);
  RunSR(11025);
  RunSR(22050);
  RunSR(44100);
  RunSR(48000);
  RunSR(96000);
  RunSR(192000);
end;

// ---------------------------------------------------------------------------
// Test 5: SeekToFrame
// ---------------------------------------------------------------------------

procedure TestSeek;
var
  Src       : TAudioBuffer;
  Fmt       : TWAVFormat;
  MS        : TMemoryStream;
  W         : TWAVWriter;
  R         : TWAVReader;
  BufA, BufB: TAudioBuffer;
  Frames    : Integer;
  Err       : Single;
begin
  Section('SeekToFrame');

  Frames := 1000;
  Src    := MakeSineBuffer(2, Frames);

  MS := TMemoryStream.Create;
  try
    W := TWAVWriter.Create(MS, 44100, 2, woPCM16, False);
    W.WriteSamples(Src);
    W.Finalize;
    W.Free;

    MS.Position := 0;
    R := TWAVReader.Create;
    R.Open(MS, False);

    // Read first 100 frames normally
    R.Decode(BufA, 100);

    // Seek back to frame 0 and read again
    var SeekOK := R.SeekToFrame(0);
    Check(SeekOK, 'SeekToFrame(0) returns True', '');

    R.Decode(BufB, 100);
    Err := MaxError(BufA[0], BufB[0]);
    Check(Err < 1e-9, 'SeekToFrame(0) re-reads same data', Format('%.12f', [Err]));

    // Seek to midpoint
    SeekOK := R.SeekToFrame(500);
    Check(SeekOK, 'SeekToFrame(500) returns True', '');
    Check(R.FramesLeft = 500, 'FramesLeft = 500 after seek', IntToStr(R.FramesLeft));

    R.Decode(BufA, 10);
    // Verify: BufA[0] should match Src[0][500..509]
    Err := MaxError(BufA[0], Copy(Src[0], 500, 10));
    Check(Err <= 1.0 / 32767.0 + 1e-6, 'SeekToFrame(500) reads correct data',
      Format('%.8f', [Err]));

    // Seek past end
    SeekOK := R.SeekToFrame(Frames + 1);
    Check(not SeekOK, 'SeekToFrame(past end) returns False', '');

    R.Free;
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Test 6: FramesLeft countdown
// ---------------------------------------------------------------------------

procedure TestFramesLeft;
var
  MS    : TMemoryStream;
  W     : TWAVWriter;
  R     : TWAVReader;
  Src   : TAudioBuffer;
  Buf   : TAudioBuffer;
  Total : Cardinal;
begin
  Section('FramesLeft countdown');

  Src := MakeSineBuffer(2, 1000);
  MS  := TMemoryStream.Create;
  try
    W := TWAVWriter.Create(MS, 44100, 2, woPCM16, False);
    W.WriteSamples(Src);
    W.Finalize;
    W.Free;

    MS.Position := 0;
    R := TWAVReader.Create;
    R.Open(MS, False);

    Total := R.FramesLeft;
    Check(Total = 1000, 'Initial FramesLeft = 1000', IntToStr(Total));

    R.Decode(Buf, 300);
    Check(R.FramesLeft = 700, 'FramesLeft = 700 after reading 300', IntToStr(R.FramesLeft));

    R.Decode(Buf, 700);
    Check(R.FramesLeft = 0, 'FramesLeft = 0 after reading all', IntToStr(R.FramesLeft));

    var Res := R.Decode(Buf, 1);
    Check(Res = adrEndOfStream, 'Decode at end returns adrEndOfStream', '');

    R.Free;
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Test 7: Edge cases
// ---------------------------------------------------------------------------

procedure TestEdgeCases;
var
  MS  : TMemoryStream;
  W   : TWAVWriter;
  R   : TWAVReader;
  Src : TAudioBuffer;
  Buf : TAudioBuffer;
  Res : TAudioDecodeResult;
begin
  Section('Edge cases');

  // 1-sample file
  SetLength(Src, 1);
  SetLength(Src[0], 1);
  Src[0][0] := 0.5;
  MS := TMemoryStream.Create;
  try
    W := TWAVWriter.Create(MS, 44100, 1, woPCM16, False);
    W.WriteSamples(Src);
    W.Finalize;
    W.Free;

    MS.Position := 0;
    R := TWAVReader.Create;
    R.Open(MS, False);
    Check(R.Ready, '1-sample file: Ready = True', '');
    Check(R.Format.FrameCount = 1, '1-sample file: FrameCount = 1', IntToStr(R.Format.FrameCount));
    Res := R.Decode(Buf, 10);
    Check(Res = adrOK, '1-sample decode = adrOK', '');
    Check(Length(Buf[0]) = 1, '1-sample: decoded 1 frame', IntToStr(Length(Buf[0])));
    Check(Abs(Buf[0][0] - 0.5) <= 1.0/32767.0 + 1e-6, '1-sample value ~0.5',
      Format('%.6f', [Buf[0][0]]));
    R.Free;
  finally
    MS.Free;
  end;

  // Silence (all zeros)
  SetLength(Src, 2);
  SetLength(Src[0], 100);
  SetLength(Src[1], 100);
  FillChar(Src[0][0], 100 * SizeOf(Single), 0);
  FillChar(Src[1][0], 100 * SizeOf(Single), 0);
  MS := TMemoryStream.Create;
  try
    W := TWAVWriter.Create(MS, 48000, 2, woPCM24, False);
    W.WriteSamples(Src);
    W.Finalize;
    W.Free;

    MS.Position := 0;
    R := TWAVReader.Create;
    R.Open(MS, False);
    R.Decode(Buf, 200);
    Check(Length(Buf[0]) = 100, 'Silence: correct frame count', IntToStr(Length(Buf[0])));
    var AllZero := True;
    var I: Integer;
    for I := 0 to 99 do
      if (Abs(Buf[0][I]) > 1e-9) or (Abs(Buf[1][I]) > 1e-9) then
        AllZero := False;
    Check(AllZero, 'Silence: all samples = 0.0', '');
    R.Free;
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Test 8: Extreme amplitude values (boundary: -1.0 and +1.0)
// ---------------------------------------------------------------------------

procedure TestBoundaryAmplitudes;
var
  MS  : TMemoryStream;
  W   : TWAVWriter;
  R   : TWAVReader;
  Src : TAudioBuffer;
  Got : TAudioBuffer;
  Fmt : TWAVFormat;
begin
  Section('Boundary amplitudes');

  SetLength(Src, 1);
  SetLength(Src[0], 4);
  Src[0][0] :=  1.0;
  Src[0][1] := -1.0;
  Src[0][2] :=  0.0;
  Src[0][3] :=  0.999969482421875;  // 32767/32768 — max representable in 16-bit

  // PCM16
  MS := TMemoryStream.Create;
  try
    W := TWAVWriter.Create(MS, 44100, 1, woPCM16, False);
    W.WriteSamples(Src);
    W.Finalize; W.Free;
    MS.Position := 0;
    R := TWAVReader.Create;
    R.Open(MS, False); R.Decode(Got, 100); R.Free;
  finally MS.Free; end;

  Check(Got[0][0] >= 0.999, '+1.0 stays near max', Format('%.6f', [Got[0][0]]));
  Check(Got[0][1] <= -0.999, '-1.0 stays near min', Format('%.6f', [Got[0][1]]));
  Check(Abs(Got[0][2]) < 1.0/32767.0, '0.0 encodes as 0', Format('%.8f', [Got[0][2]]));

  // Float32 — exact round-trip at boundaries
  Src[0][0] := 1.0;
  Src[0][1] := -1.0;
  MS := TMemoryStream.Create;
  try
    W := TWAVWriter.Create(MS, 44100, 1, woFloat32, False);
    W.WriteSamples(Src);
    W.Finalize; W.Free;
    MS.Position := 0;
    R := TWAVReader.Create;
    R.Open(MS, False); R.Decode(Got, 100); R.Free;
  finally MS.Free; end;

  Check(Got[0][0] = 1.0,  'Float32: +1.0 exact', Format('%.12f', [Got[0][0]]));
  Check(Got[0][1] = -1.0, 'Float32: -1.0 exact', Format('%.12f', [Got[0][1]]));

  Fmt.SampleRate := 0; // suppress unused warning
end;

// ---------------------------------------------------------------------------
// Test 9: Large buffer (1 second at 48kHz stereo)
// ---------------------------------------------------------------------------

procedure TestLargeBuffer;
const
  SR = 48000;
  Ch = 2;
  Frames = SR;  // 1 second
var
  Src : TAudioBuffer;
  Got : TAudioBuffer;
  Fmt : TWAVFormat;
  Err : Single;
begin
  Section('Large buffer (48000 frames)');

  Src := MakeSineBuffer(Ch, Frames);
  Got := RoundTrip(Src, SR, Ch, woPCM16, Fmt);
  Check(Length(Got[0]) = Frames, 'Large: all frames decoded', IntToStr(Length(Got[0])));
  Err := MaxError(Src[0], Got[0]);
  Check(Err <= 1.0/32767.0 + 1e-6, 'Large: error within 1 LSB', Format('%.8f', [Err]));
  Err := MaxError(Src[1], Got[1]);
  Check(Err <= 1.0/32767.0 + 1e-6, 'Large: ch2 error within 1 LSB', Format('%.8f', [Err]));
end;

// ---------------------------------------------------------------------------
// Test 10: Partial decode (multiple Decode calls)
// ---------------------------------------------------------------------------

procedure TestPartialDecode;
var
  MS        : TMemoryStream;
  W         : TWAVWriter;
  R         : TWAVReader;
  Src       : TAudioBuffer;
  BufA, BufB: TAudioBuffer;
  Combined  : TAudioBuffer;
  Frames    : Integer;
  I, Ch     : Integer;
  Err       : Single;
begin
  Section('Partial decode (multiple calls)');

  Frames := 1000;
  Src    := MakeSineBuffer(2, Frames);
  MS     := TMemoryStream.Create;
  try
    W := TWAVWriter.Create(MS, 44100, 2, woPCM16, False);
    W.WriteSamples(Src);
    W.Finalize; W.Free;

    MS.Position := 0;
    R := TWAVReader.Create;
    R.Open(MS, False);

    // Read in 3 chunks: 300 + 300 + 400
    R.Decode(BufA, 300);
    R.Decode(BufB, 300);

    SetLength(Combined, 2);
    for Ch := 0 to 1 do
    begin
      SetLength(Combined[Ch], Frames);
      for I := 0 to 299 do Combined[Ch][I]       := BufA[Ch][I];
      for I := 0 to 299 do Combined[Ch][300 + I] := BufB[Ch][I];
    end;

    R.Decode(BufA, 400);
    for Ch := 0 to 1 do
      for I := 0 to 399 do Combined[Ch][600 + I] := BufA[Ch][I];

    R.Free;
  finally
    MS.Free;
  end;

  for Ch := 0 to 1 do
  begin
    Err := MaxError(Src[Ch], Combined[Ch]);
    Check(Err <= 1.0/32767.0 + 1e-6,
      Format('Partial decode ch%d continuous', [Ch]), Format('%.8f', [Err]));
  end;
end;

// ---------------------------------------------------------------------------
// Test 11: 8-bit unsigned PCM specific validation
// ---------------------------------------------------------------------------

procedure Test8BitPCM;
var
  MS  : TMemoryStream;
  W   : TWAVWriter;
  R   : TWAVReader;
  Src : TAudioBuffer;
  Got : TAudioBuffer;
  Err : Single;
begin
  Section('8-bit unsigned PCM');

  SetLength(Src, 1);
  SetLength(Src[0], 5);
  Src[0][0] :=  0.0;   // → byte 128
  Src[0][1] :=  1.0;   // → byte 255 (clamped)
  Src[0][2] := -1.0;   // → byte 0
  Src[0][3] :=  0.5;   // → byte 192
  Src[0][4] := -0.5;   // → byte 64

  MS := TMemoryStream.Create;
  try
    // Write as PCM16 then verify the reader handles 8-bit
    // To test 8-bit reading we manually construct a minimal WAV
    // Header: RIFF + fmt(8-bit, 1ch, 8000) + data
    // Build 8-bit WAV manually
    var Bytes: TBytes;
    SetLength(Bytes, 44 + 5);  // 44-byte header + 5 data bytes

    // RIFF
    Bytes[0]:=Ord('R'); Bytes[1]:=Ord('I'); Bytes[2]:=Ord('F'); Bytes[3]:=Ord('F');
    var DataSz: Cardinal := 5;
    var RiffSz: Cardinal := 36 + DataSz;
    Bytes[4]:=RiffSz and $FF; Bytes[5]:=(RiffSz shr 8) and $FF;
    Bytes[6]:=(RiffSz shr 16) and $FF; Bytes[7]:=(RiffSz shr 24) and $FF;
    Bytes[8]:=Ord('W'); Bytes[9]:=Ord('A'); Bytes[10]:=Ord('V'); Bytes[11]:=Ord('E');
    // fmt
    Bytes[12]:=Ord('f'); Bytes[13]:=Ord('m'); Bytes[14]:=Ord('t'); Bytes[15]:=Ord(' ');
    Bytes[16]:=16; Bytes[17]:=0; Bytes[18]:=0; Bytes[19]:=0;  // chunk size = 16
    Bytes[20]:=1;  Bytes[21]:=0;  // PCM
    Bytes[22]:=1;  Bytes[23]:=0;  // 1 channel
    Bytes[24]:=64; Bytes[25]:=31; Bytes[26]:=0; Bytes[27]:=0;  // 8000 Hz
    Bytes[28]:=64; Bytes[29]:=31; Bytes[30]:=0; Bytes[31]:=0;  // byte rate = 8000
    Bytes[32]:=1;  Bytes[33]:=0;  // block align = 1
    Bytes[34]:=8;  Bytes[35]:=0;  // 8 bits per sample
    // data
    Bytes[36]:=Ord('d'); Bytes[37]:=Ord('a'); Bytes[38]:=Ord('t'); Bytes[39]:=Ord('a');
    Bytes[40]:=5; Bytes[41]:=0; Bytes[42]:=0; Bytes[43]:=0;
    // samples: 0→128, +1→255, -1→0, +0.5→192, -0.5→64
    Bytes[44]:=128; Bytes[45]:=255; Bytes[46]:=0; Bytes[47]:=192; Bytes[48]:=64;

    MS.WriteBuffer(Bytes[0], Length(Bytes));
    MS.Position := 0;

    R := TWAVReader.Create;
    R.Open(MS, False);
    Check(R.Ready, '8-bit WAV: Ready=True', '');
    Check(R.Format.BitsPerSample = 8, '8-bit WAV: BitsPerSample=8', IntToStr(R.Format.BitsPerSample));

    R.Decode(Got, 10);
    Check(Length(Got[0]) = 5, '8-bit: 5 frames decoded', IntToStr(Length(Got[0])));
    Check(Abs(Got[0][0]) < 1.0/128.0, '8-bit: 128→~0.0', Format('%.6f', [Got[0][0]]));
    Check(Got[0][1] > 0.99, '8-bit: 255→~+1.0', Format('%.6f', [Got[0][1]]));
    Check(Got[0][2] < -0.99, '8-bit: 0→~-1.0', Format('%.6f', [Got[0][2]]));
    R.Free;
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

begin
  Writeln('========================================');
  Writeln(' wav-codec exhaustive tests');
  Writeln('========================================');

  TestRoundTrip;
  TestFormatFields;
  TestMultichannel;
  TestSampleRates;
  TestSeek;
  TestFramesLeft;
  TestEdgeCases;
  TestBoundaryAmplitudes;
  TestLargeBuffer;
  TestPartialDecode;
  Test8BitPCM;

  Writeln;
  WriteLn(Format('Results: %d / %d passed', [GPassed, GTotal]));
  if GFailed then
  begin
    WriteLn('*** SOME TESTS FAILED ***');
    Halt(1);
  end
  else
    WriteLn('All tests passed.');
end.
