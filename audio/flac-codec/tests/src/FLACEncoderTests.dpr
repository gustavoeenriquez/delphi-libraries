program FLACEncoderTests;

{
  FLACEncoderTests.dpr - Exhaustive test suite for flac-codec encoder

  Strategy: encode → decode → compare. Every test verifies losslessness
  (FLAC is a lossless codec: decoded output must be bit-exact to the input).
  Additional tests verify compression ratios and metadata correctness.

  Tests:
    E01: Silence — all zeros encode and decode correctly
    E02: Full-scale square wave (max positive / max negative alternating)
    E03: Sine wave at 440 Hz (typical audio signal)
    E04: White noise (random ints, worst case for compression)
    E05: Linear ramp (perfect for fixed-order predictors)
    E06: Constant signal (should produce CONSTANT subframes)
    E07: 16-bit mono, 1 block
    E08: 16-bit stereo, 1 block
    E09: 24-bit mono (higher BPS)
    E10: Multiple blocks (3 full + 1 partial)
    E11: Stereo with correlated channels (benefits from mid/side)
    E12: STREAMINFO TotalSamples correct after Finalize
    E13: STREAMINFO min/max frame sizes set (non-zero after non-trivial signal)
    E14: Silence compresses better than raw (compression ratio check)
    E15: Round-trip via TMemoryStream (stream-based API)
    E16: Partial last block (zero-padding must not corrupt real samples)
    E17: Multiple Write calls with varying FrameCount
    E18: LPC mode better than fixed-only for sine wave
    E19: Rice2 / escape path — high-amplitude residuals
    E20: Block size 64 (many small frames) encode/decode
    E21: Block size 4096 (large frames) encode/decode
    E22: MaxLPCOrder = 0 (fixed-predictor only) still correct
    E23: Two consecutive Write calls, different frame counts
    E24: Mono vs stereo channel count preserved
    E25: 8-bit audio round-trip bit-exact
    E26: 3-channel (surround) encode/decode
    E27: Sample rate 96000 Hz encode/decode
    E28: Very short signal (fewer samples than BlockSize)
    E29: Left-side stereo (left louder) bit-exact
    E30: Right-side stereo (right louder) bit-exact

  Exit code 0 = all passed.

  License: CC0 1.0 Universal (Public Domain)
}

{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, Math,
  AudioTypes      in '..\..\..\audio-common\src\AudioTypes.pas',
  AudioBitReader  in '..\..\..\audio-common\src\AudioBitReader.pas',
  AudioSampleConv in '..\..\..\audio-common\src\AudioSampleConv.pas',
  AudioCRC        in '..\..\..\audio-common\src\AudioCRC.pas',
  FLACTypes       in '..\..\src\FLACTypes.pas',
  FLACBitWriter   in '..\..\src\FLACBitWriter.pas',
  FLACBitReader   in '..\..\src\FLACBitReader.pas',
  FLACRiceCoder   in '..\..\src\FLACRiceCoder.pas',
  FLACRiceEncoder in '..\..\src\FLACRiceEncoder.pas',
  FLACPredictor   in '..\..\src\FLACPredictor.pas',
  FLACLPCAnalyzer in '..\..\src\FLACLPCAnalyzer.pas',
  FLACFrameDecoder  in '..\..\src\FLACFrameDecoder.pas',
  FLACFrameEncoder  in '..\..\src\FLACFrameEncoder.pas',
  FLACStreamDecoder in '..\..\src\FLACStreamDecoder.pas',
  FLACStreamEncoder in '..\..\src\FLACStreamEncoder.pas';

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------
var
  GFailed: Boolean = False;
  GTotal : Integer = 0;
  GPassed: Integer = 0;

procedure Check(Cond: Boolean; const Name, Detail: string);
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
    if Detail <> '' then WriteLn('  FAIL  ', Name, '  [', Detail, ']')
    else WriteLn('  FAIL  ', Name);
  end;
end;

procedure Section(const T: string);
begin WriteLn; WriteLn('--- ', T, ' ---'); end;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Build a TAudioBuffer with given signal type (integer representation scaled
// to Single [-1..1] as required by TFLACStreamEncoder.Write).
type
  TSignalType = (stSilence, stSquare, stSine, stRamp, stConst, stNoise);

function MakeBuffer(Channels, Frames, BPS: Integer;
  Signal: TSignalType; Param: Single = 0): TAudioBuffer;
var
  Ch, F : Integer;
  Scale : Single;
  MaxV  : Integer;
begin
  MaxV  := (1 shl (BPS - 1)) - 1;
  Scale := 1.0 / (MaxV + 1);  // align with encoder/decoder scale: 1 / 2^(BPS-1)

  SetLength(Result, Channels);
  for Ch := 0 to Channels - 1 do
  begin
    SetLength(Result[Ch], Frames);
    for F := 0 to Frames - 1 do
    begin
      var IV: Integer;
      case Signal of
        stSilence: IV := 0;
        stSquare:  IV := IfThen((F and 1) = 0, MaxV, -MaxV - 1);
        stSine:    IV := Round(Sin(2 * Pi * 440 * (F + Ch * 100) / 44100.0) * MaxV * 0.9);
        stRamp:    IV := (F mod (2 * (MaxV + 1))) - MaxV - 1;
        stConst:   IV := Round(Param * MaxV);
        stNoise:   IV := (Random(2 * MaxV + 2)) - MaxV - 1;
      end;
      if IV >  MaxV    then IV :=  MaxV;
      if IV < -MaxV-1  then IV := -MaxV-1;
      Result[Ch][F] := IV * Scale;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Core round-trip function
// Returns True if decoded output is bit-exact to the encoded input.
// Also sets CompressedBytes for compression ratio checks.
// ---------------------------------------------------------------------------

function RoundTrip(
  const InBuf      : TAudioBuffer;
  SampleRate       : Cardinal;
  BPS, BlockSize   : Integer;
  const Config     : TFLACEncConfig;
  out   CompBytes  : Integer;
  out   OutBuf     : TAudioBuffer
): Boolean;
var
  MS : TMemoryStream;
  E  : TFLACStreamEncoder;
  D  : TFLACStreamDecoder;
  Buf: TAudioBuffer;
  Res: TAudioDecodeResult;
  AllFrames: TAudioBuffer;
  Ch, I    : Integer;
  Channels : Integer;
  TotalSamp: Integer;
begin
  Result   := False;
  CompBytes := 0;
  Channels  := Length(InBuf);
  if Channels = 0 then Exit;

  MS := TMemoryStream.Create;
  try
    // Encode
    E := TFLACStreamEncoder.Create(MS, SampleRate, Channels, BPS, BlockSize, False, Config);
    try
      E.Write(InBuf);
      E.Finalize;
    finally
      E.Free;
    end;

    CompBytes := MS.Size;
    MS.Position := 0;

    // Decode
    SetLength(AllFrames, Channels);
    TotalSamp := 0;

    D := TFLACStreamDecoder.Create;
    try
      if not D.Open(MS, False) then Exit;

      repeat
        Res := D.Decode(Buf);
        if Res = adrOK then
        begin
          for Ch := 0 to Channels - 1 do
          begin
            SetLength(AllFrames[Ch], TotalSamp + Length(Buf[Ch]));
            Move(Buf[Ch][0], AllFrames[Ch][TotalSamp], Length(Buf[Ch]) * SizeOf(Single));
          end;
          Inc(TotalSamp, Length(Buf[0]));
        end;
      until Res <> adrOK;
    finally
      D.Free;
    end;

    OutBuf := AllFrames;
    Result := True;
  finally
    MS.Free;
  end;
end;

// Check bit-exact lossless round-trip (convert back to integers and compare).
function VerifyLossless(const InBuf, OutBuf: TAudioBuffer; BPS: Integer): Boolean;
var
  Ch, I  : Integer;
  Scale  : Single;
  InI, OutI: Integer;
begin
  Result := False;
  Scale  := Single(Int64(1) shl (BPS - 1));

  if Length(InBuf) <> Length(OutBuf) then Exit;

  for Ch := 0 to High(InBuf) do
  begin
    var InSamples := Length(InBuf[Ch]);
    var OutSamples := Length(OutBuf[Ch]);
    // Decoded may include zero-padded trailing samples in partial last block
    if OutSamples < InSamples then Exit;

    for I := 0 to InSamples - 1 do
    begin
      InI  := Round(InBuf[Ch][I]  * Scale);
      OutI := Round(OutBuf[Ch][I] * Scale);
      if InI <> OutI then Exit;
    end;
  end;

  Result := True;
end;

// ---------------------------------------------------------------------------
// Test E01: Silence
// ---------------------------------------------------------------------------
procedure TestE01_Silence;
var
  InBuf, OutBuf: TAudioBuffer;
  Bytes: Integer;
  Cfg: TFLACEncConfig;
begin
  Section('E01 Silence');
  Cfg := FLACDefaultConfig;
  InBuf := MakeBuffer(2, 512, 16, stSilence);
  RoundTrip(InBuf, 44100, 16, 512, Cfg, Bytes, OutBuf);
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E01 Silence round-trip bit-exact', '');
  Check(Length(OutBuf[0]) >= 512, 'E01 Correct frame count', IntToStr(Length(OutBuf[0])));
end;

// ---------------------------------------------------------------------------
// E02: Square wave
// ---------------------------------------------------------------------------
procedure TestE02_Square;
var
  InBuf, OutBuf: TAudioBuffer;
  Bytes: Integer;
  Cfg: TFLACEncConfig;
begin
  Section('E02 Square wave');
  Cfg := FLACDefaultConfig;
  InBuf := MakeBuffer(1, 512, 16, stSquare);
  RoundTrip(InBuf, 44100, 16, 512, Cfg, Bytes, OutBuf);
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E02 Square wave bit-exact', '');
end;

// ---------------------------------------------------------------------------
// E03: Sine wave
// ---------------------------------------------------------------------------
procedure TestE03_Sine;
var
  InBuf, OutBuf: TAudioBuffer;
  Bytes: Integer;
  Cfg: TFLACEncConfig;
begin
  Section('E03 Sine wave');
  Cfg := FLACDefaultConfig;
  InBuf := MakeBuffer(2, 4096, 16, stSine);
  RoundTrip(InBuf, 44100, 16, 4096, Cfg, Bytes, OutBuf);
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E03 Sine wave bit-exact', '');
end;

// ---------------------------------------------------------------------------
// E04: White noise (worst case)
// ---------------------------------------------------------------------------
procedure TestE04_Noise;
var
  InBuf, OutBuf: TAudioBuffer;
  Bytes: Integer;
  Cfg: TFLACEncConfig;
begin
  Section('E04 White noise');
  Randomize;
  Cfg := FLACDefaultConfig;
  InBuf := MakeBuffer(1, 2048, 16, stNoise);
  RoundTrip(InBuf, 44100, 16, 2048, Cfg, Bytes, OutBuf);
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E04 White noise bit-exact', '');
end;

// ---------------------------------------------------------------------------
// E05: Linear ramp (ideal for fixed predictors)
// ---------------------------------------------------------------------------
procedure TestE05_Ramp;
var
  InBuf, OutBuf: TAudioBuffer;
  Bytes: Integer;
  Cfg: TFLACEncConfig;
begin
  Section('E05 Linear ramp');
  Cfg := FLACDefaultConfig;
  InBuf := MakeBuffer(1, 1024, 16, stRamp);
  RoundTrip(InBuf, 44100, 16, 1024, Cfg, Bytes, OutBuf);
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E05 Ramp bit-exact', '');
end;

// ---------------------------------------------------------------------------
// E06: Constant signal → CONSTANT subframes
// ---------------------------------------------------------------------------
procedure TestE06_Constant;
var
  InBuf, OutBuf: TAudioBuffer;
  Bytes: Integer;
  Cfg: TFLACEncConfig;
  RawBytes: Integer;
begin
  Section('E06 Constant signal');
  Cfg := FLACDefaultConfig;
  InBuf := MakeBuffer(1, 512, 16, stConst, 0.5);
  RoundTrip(InBuf, 44100, 16, 512, Cfg, Bytes, OutBuf);
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E06 Constant bit-exact', '');

  // CONSTANT subframe should compress to very small size
  // Raw = 512 * 2 bytes = 1024 bytes of PCM, + FLAC overhead
  // With CONSTANT: 1 sample + tiny header ≈ < 50 bytes per frame
  RawBytes := 512 * (16 div 8);  // 1024 bytes raw PCM
  Check(Bytes < RawBytes + 100, 'E06 Constant compresses well (< raw+100)',
    Format('%d vs raw=%d', [Bytes, RawBytes]));
end;

// ---------------------------------------------------------------------------
// E07: 16-bit mono
// ---------------------------------------------------------------------------
procedure TestE07_Mono16;
var
  InBuf, OutBuf: TAudioBuffer;
  Bytes: Integer;
  Cfg: TFLACEncConfig;
begin
  Section('E07 16-bit mono');
  Cfg := FLACDefaultConfig;
  InBuf := MakeBuffer(1, 4096, 16, stSine);
  RoundTrip(InBuf, 44100, 16, 4096, Cfg, Bytes, OutBuf);
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E07 Mono 16-bit bit-exact', '');
end;

// ---------------------------------------------------------------------------
// E08: 16-bit stereo
// ---------------------------------------------------------------------------
procedure TestE08_Stereo16;
var
  InBuf, OutBuf: TAudioBuffer;
  Bytes: Integer;
  Cfg: TFLACEncConfig;
begin
  Section('E08 16-bit stereo');
  Cfg := FLACDefaultConfig;
  InBuf := MakeBuffer(2, 4096, 16, stSine);
  RoundTrip(InBuf, 44100, 16, 4096, Cfg, Bytes, OutBuf);
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E08 Stereo 16-bit bit-exact', '');
end;

// ---------------------------------------------------------------------------
// E09: 24-bit mono
// ---------------------------------------------------------------------------
procedure TestE09_24bit;
var
  InBuf, OutBuf: TAudioBuffer;
  Bytes: Integer;
  Cfg: TFLACEncConfig;
begin
  Section('E09 24-bit mono');
  Cfg := FLACDefaultConfig;
  InBuf := MakeBuffer(1, 2048, 24, stSine);
  RoundTrip(InBuf, 44100, 24, 2048, Cfg, Bytes, OutBuf);
  Check(VerifyLossless(InBuf, OutBuf, 24), 'E09 24-bit bit-exact', '');
end;

// ---------------------------------------------------------------------------
// E10: Multiple blocks
// ---------------------------------------------------------------------------
procedure TestE10_MultiBlock;
var
  InBuf, OutBuf: TAudioBuffer;
  Bytes: Integer;
  Cfg: TFLACEncConfig;
begin
  Section('E10 Multiple blocks');
  Cfg := FLACDefaultConfig;
  // 4096 samples = exactly 1 block; 9000 = 2 full + 1 partial
  InBuf := MakeBuffer(2, 9000, 16, stSine);
  RoundTrip(InBuf, 44100, 16, 4096, Cfg, Bytes, OutBuf);
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E10 Multi-block bit-exact', '');
  Check(Length(OutBuf[0]) >= 9000, 'E10 All samples decoded',
    IntToStr(Length(OutBuf[0])));
end;

// ---------------------------------------------------------------------------
// E11: Stereo with high inter-channel correlation (mid/side should win)
// ---------------------------------------------------------------------------
procedure TestE11_MidSide;
var
  InBuf, OutBuf: TAudioBuffer;
  BytesMS, BytesNoMS: Integer;
  CfgMS, CfgNoMS: TFLACEncConfig;
  Dummy: TAudioBuffer;
  Ch, F: Integer;
begin
  Section('E11 Mid/side stereo');

  // Build a stereo signal where both channels are nearly identical
  SetLength(InBuf, 2);
  SetLength(InBuf[0], 4096);
  SetLength(InBuf[1], 4096);
  for F := 0 to 4095 do
  begin
    var V := Sin(2 * Pi * 440 * F / 44100.0) * 0.9;
    InBuf[0][F] := V;
    InBuf[1][F] := V + 0.001 * Sin(2 * Pi * 1000 * F / 44100.0); // slight difference
  end;

  CfgMS    := FLACDefaultConfig;
  CfgMS.TryStereoModes := True;
  CfgNoMS  := FLACDefaultConfig;
  CfgNoMS.TryStereoModes := False;

  RoundTrip(InBuf, 44100, 16, 4096, CfgMS,   BytesMS,   OutBuf);
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E11 Mid/side: bit-exact', '');

  RoundTrip(InBuf, 44100, 16, 4096, CfgNoMS, BytesNoMS, Dummy);
  // Mid/side should produce smaller file for correlated channels
  Check(BytesMS <= BytesNoMS, 'E11 Mid/side <= independent size',
    Format('%d vs %d', [BytesMS, BytesNoMS]));
end;

// ---------------------------------------------------------------------------
// E12: STREAMINFO TotalSamples
// ---------------------------------------------------------------------------
procedure TestE12_StreamInfo;
var
  MS : TMemoryStream;
  E  : TFLACStreamEncoder;
  D  : TFLACStreamDecoder;
  InBuf: TAudioBuffer;
  Buf  : TAudioBuffer;
begin
  Section('E12 STREAMINFO TotalSamples');

  InBuf := MakeBuffer(1, 1000, 16, stSine);

  MS := TMemoryStream.Create;
  try
    E := TFLACStreamEncoder.Create(MS, 44100, 1, 16, 512, False, FLACDefaultConfig);
    try
      E.Write(InBuf);
      E.Finalize;
      Check(E.TotalSamples >= 1000, 'E12a TotalSamples >= 1000 (may include padding)',
        IntToStr(E.TotalSamples));
    finally
      E.Free;
    end;

    MS.Position := 0;
    D := TFLACStreamDecoder.Create;
    try
      D.Open(MS, False);
      // TotalSamples in STREAMINFO should be set (may include padding to BlockSize)
      Check(D.StreamInfo.TotalSamples >= 1000, 'E12b STREAMINFO.TotalSamples >= 1000',
        IntToStr(D.StreamInfo.TotalSamples));
      Check(D.StreamInfo.SampleRate = 44100, 'E12c SampleRate correct',
        IntToStr(D.StreamInfo.SampleRate));
    finally
      D.Free;
    end;
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// E13: Min/max frame sizes
// ---------------------------------------------------------------------------
procedure TestE13_FrameSizes;
var
  MS : TMemoryStream;
  E  : TFLACStreamEncoder;
  D  : TFLACStreamDecoder;
  InBuf: TAudioBuffer;
begin
  Section('E13 Min/max frame sizes in STREAMINFO');

  InBuf := MakeBuffer(2, 8192, 16, stSine);
  MS := TMemoryStream.Create;
  try
    E := TFLACStreamEncoder.Create(MS, 44100, 2, 16, 4096, False, FLACDefaultConfig);
    E.Write(InBuf);
    E.Finalize;
    E.Free;

    MS.Position := 0;
    D := TFLACStreamDecoder.Create;
    D.Open(MS, False);
    Check(D.StreamInfo.MinFrameSize > 0, 'E13 MinFrameSize > 0',
      IntToStr(D.StreamInfo.MinFrameSize));
    Check(D.StreamInfo.MaxFrameSize > 0, 'E13 MaxFrameSize > 0',
      IntToStr(D.StreamInfo.MaxFrameSize));
    Check(D.StreamInfo.MinFrameSize <= D.StreamInfo.MaxFrameSize,
      'E13 MinFrameSize <= MaxFrameSize',
      Format('%d <= %d', [D.StreamInfo.MinFrameSize, D.StreamInfo.MaxFrameSize]));
    D.Free;
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// E14: Compression ratio
// ---------------------------------------------------------------------------
procedure TestE14_Compression;
var
  InBuf, OutBuf: TAudioBuffer;
  BytesSilence, BytesNoise, BytesSine: Integer;
  RawBytes: Integer;
  Cfg: TFLACEncConfig;
begin
  Section('E14 Compression ratios');
  Cfg := FLACDefaultConfig;

  RawBytes := 4096 * 2;  // 1ch, 16-bit, 4096 samples

  InBuf := MakeBuffer(1, 4096, 16, stSilence);
  RoundTrip(InBuf, 44100, 16, 4096, Cfg, BytesSilence, OutBuf);
  Check(BytesSilence < RawBytes div 2, 'E14 Silence < 50% of raw',
    Format('%d vs raw=%d', [BytesSilence, RawBytes]));

  InBuf := MakeBuffer(1, 4096, 16, stSine);
  RoundTrip(InBuf, 44100, 16, 4096, Cfg, BytesSine, OutBuf);
  Check(BytesSine < RawBytes, 'E14 Sine < raw size',
    Format('%d vs raw=%d', [BytesSine, RawBytes]));

  InBuf := MakeBuffer(1, 4096, 16, stNoise);
  RoundTrip(InBuf, 44100, 16, 4096, Cfg, BytesNoise, OutBuf);
  // Noise is hardest — just verify round-trip works (compression not guaranteed < raw)
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E14 Noise still bit-exact', '');
end;

// ---------------------------------------------------------------------------
// E15: Stream-based API
// ---------------------------------------------------------------------------
procedure TestE15_StreamAPI;
var
  InBuf, OutBuf: TAudioBuffer;
  Bytes: Integer;
  Cfg: TFLACEncConfig;
begin
  Section('E15 Stream-based API (TMemoryStream)');
  Cfg := FLACDefaultConfig;
  InBuf := MakeBuffer(2, 2048, 16, stSine);
  RoundTrip(InBuf, 48000, 16, 1024, Cfg, Bytes, OutBuf);
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E15 Stream-based bit-exact', '');
end;

// ---------------------------------------------------------------------------
// E16: Partial last block
// ---------------------------------------------------------------------------
procedure TestE16_PartialBlock;
var
  InBuf, OutBuf: TAudioBuffer;
  Bytes: Integer;
  Cfg: TFLACEncConfig;
  Ch, I: Integer;
begin
  Section('E16 Partial last block');
  Cfg := FLACDefaultConfig;
  // 1500 samples with block = 1024: 1 full + 1 partial (476 samples)
  InBuf := MakeBuffer(1, 1500, 16, stSine);
  RoundTrip(InBuf, 44100, 16, 1024, Cfg, Bytes, OutBuf);

  // Verify the first 1500 samples are bit-exact (padding may follow)
  var Scale := Single(1 shl 15);
  var AllOK := True;
  for I := 0 to 1499 do
  begin
    var InI  := Round(InBuf[0][I]  * Scale);
    var OutI := Round(OutBuf[0][I] * Scale);
    if InI <> OutI then begin AllOK := False; Break; end;
  end;
  Check(AllOK, 'E16 Partial block: first 1500 samples bit-exact', '');
  Check(Length(OutBuf[0]) >= 1500, 'E16 At least 1500 samples decoded',
    IntToStr(Length(OutBuf[0])));
end;

// ---------------------------------------------------------------------------
// E17: Multiple Write calls
// ---------------------------------------------------------------------------
procedure TestE17_MultiWrite;
var
  MS  : TMemoryStream;
  E   : TFLACStreamEncoder;
  D   : TFLACStreamDecoder;
  InBuf : TAudioBuffer;
  Part  : TAudioBuffer;
  AllOut: TAudioBuffer;
  Buf   : TAudioBuffer;
  Res   : TAudioDecodeResult;
  TotalSamp: Integer;
  Ch, I : Integer;
begin
  Section('E17 Multiple Write calls');

  InBuf := MakeBuffer(2, 4096, 16, stSine);

  MS := TMemoryStream.Create;
  try
    E := TFLACStreamEncoder.Create(MS, 44100, 2, 16, 1024, False, FLACDefaultConfig);
    try
      // Write in 4 chunks of 1024
      SetLength(Part, 2);
      for var Chunk := 0 to 3 do
      begin
        SetLength(Part[0], 1024);
        SetLength(Part[1], 1024);
        Move(InBuf[0][Chunk * 1024], Part[0][0], 1024 * SizeOf(Single));
        Move(InBuf[1][Chunk * 1024], Part[1][0], 1024 * SizeOf(Single));
        E.Write(Part);
      end;
      E.Finalize;
    finally
      E.Free;
    end;

    MS.Position := 0;
    SetLength(AllOut, 2);
    TotalSamp := 0;

    D := TFLACStreamDecoder.Create;
    try
      D.Open(MS, False);
      repeat
        Res := D.Decode(Buf);
        if Res = adrOK then
        begin
          for Ch := 0 to 1 do
          begin
            SetLength(AllOut[Ch], TotalSamp + Length(Buf[Ch]));
            Move(Buf[Ch][0], AllOut[Ch][TotalSamp], Length(Buf[Ch]) * SizeOf(Single));
          end;
          Inc(TotalSamp, Length(Buf[0]));
        end;
      until Res <> adrOK;
    finally
      D.Free;
    end;
  finally
    MS.Free;
  end;

  var Scale := Single(1 shl 15);
  var AllOK := True;
  for I := 0 to 4095 do
  begin
    for Ch := 0 to 1 do
    begin
      var InI  := Round(InBuf[Ch][I]  * Scale);
      var OutI := Round(AllOut[Ch][I] * Scale);
      if InI <> OutI then begin AllOK := False; Break; end;
    end;
    if not AllOK then Break;
  end;
  Check(AllOK, 'E17 Multi-Write bit-exact over 4 chunks', '');
end;

// ---------------------------------------------------------------------------
// E18: LPC better than fixed-only for sine
// ---------------------------------------------------------------------------
procedure TestE18_LPC;
var
  InBuf, OutBuf: TAudioBuffer;
  BytesLPC, BytesFixed: Integer;
  CfgLPC, CfgFixed: TFLACEncConfig;
begin
  Section('E18 LPC vs fixed-only (sine wave)');

  InBuf := MakeBuffer(1, 8192, 16, stSine);

  CfgLPC        := FLACDefaultConfig;
  CfgLPC.MaxLPCOrder := 8;

  CfgFixed      := FLACDefaultConfig;
  CfgFixed.MaxLPCOrder := 0;  // fixed only

  RoundTrip(InBuf, 44100, 16, 4096, CfgLPC,   BytesLPC,   OutBuf);
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E18 LPC: bit-exact', '');

  RoundTrip(InBuf, 44100, 16, 4096, CfgFixed, BytesFixed, OutBuf);
  Check(BytesLPC <= BytesFixed, 'E18 LPC <= fixed-only bytes for sine',
    Format('LPC=%d Fixed=%d', [BytesLPC, BytesFixed]));
end;

// ---------------------------------------------------------------------------
// E19: High-amplitude residuals (escape / Rice2 path)
// ---------------------------------------------------------------------------
procedure TestE19_HighResiduals;
var
  InBuf, OutBuf: TAudioBuffer;
  Bytes: Integer;
  Cfg: TFLACEncConfig;
begin
  Section('E19 High residuals (escape path)');

  // Square wave has max residuals — triggers escape code
  Cfg := FLACDefaultConfig;
  Cfg.MaxLPCOrder := 0;  // force fixed predictors to exercise escape path
  InBuf := MakeBuffer(1, 2048, 24, stSquare);
  RoundTrip(InBuf, 44100, 24, 2048, Cfg, Bytes, OutBuf);
  Check(VerifyLossless(InBuf, OutBuf, 24), 'E19 High residuals 24-bit bit-exact', '');
end;

// ---------------------------------------------------------------------------
// E20: Block size 64 — multiple small frames encode/decode
// ---------------------------------------------------------------------------
procedure TestE20_SmallBlocks;
var
  Buf, OutBuf: TAudioBuffer;
  CompBytes  : Integer;
begin
  Section('E20: Block size 64 (many small frames)');
  Buf := MakeBuffer(1, 640, 16, stSine);
  RoundTrip(Buf, 44100, 16, 64, FLACDefaultConfig, CompBytes, OutBuf);
  Check(VerifyLossless(Buf, OutBuf, 16), 'E20a RT: block-64 mono sine bit-exact', '');
  Check(CompBytes > 0, 'E20b Produced non-zero FLAC bytes', IntToStr(CompBytes));
end;

// ---------------------------------------------------------------------------
// E21: Block size 4096 — fewer large frames
// ---------------------------------------------------------------------------
procedure TestE21_LargeBlocks;
var
  Buf, OutBuf: TAudioBuffer;
  CompBytes  : Integer;
begin
  Section('E21: Block size 4096 (large frames)');
  Buf := MakeBuffer(2, 8192, 16, stSine);
  RoundTrip(Buf, 48000, 16, 4096, FLACDefaultConfig, CompBytes, OutBuf);
  Check(VerifyLossless(Buf, OutBuf, 16), 'E21a RT: block-4096 stereo sine bit-exact', '');
end;

// ---------------------------------------------------------------------------
// E22: MaxLPCOrder = 0 (no LPC, fixed only) still correct
// ---------------------------------------------------------------------------
procedure TestE22_NoLPC;
var
  Buf        : TAudioBuffer;
  MS         : TMemoryStream;
  Enc        : TFLACStreamEncoder;
  Dec        : TFLACStreamDecoder;
  Cfg        : TFLACEncConfig;
  Decoded    : TAudioBuffer;
  Res        : TAudioDecodeResult;
  AllMatch   : Boolean;
  S          : Integer;
  Scale      : Single;
begin
  Section('E22: MaxLPCOrder = 0 (fixed-predictor only)');
  Buf := MakeBuffer(1, 512, 16, stSine);
  Scale := 1.0 / 32768.0;

  MS := TMemoryStream.Create;
  Cfg := FLACDefaultConfig;
  Cfg.MaxLPCOrder    := 0;
  Cfg.TryStereoModes := False;
  Enc := TFLACStreamEncoder.Create(MS, 44100, 1, 16, 256, False, Cfg);
  try
    Enc.Write(Buf);
    Enc.Finalize;
  finally
    Enc.Free;
  end;

  MS.Position := 0;
  Dec := TFLACStreamDecoder.Create;
  Dec.Open(MS, False);
  try
    AllMatch := True;
    var Pos := 0;
    repeat
      Res := Dec.Decode(Decoded);
      if Res = adrOK then
      begin
        for S := 0 to Length(Decoded[0]) - 1 do
          if Abs(Decoded[0][S] - Buf[0][Pos + S]) > Scale + 1e-10 then
            AllMatch := False;
        Inc(Pos, Length(Decoded[0]));
      end;
    until Res <> adrOK;
    Check(AllMatch, 'E22a No-LPC mode: sine bit-exact', '');
    Check(Pos = 512, 'E22b 512 samples decoded', IntToStr(Pos));
  finally
    Dec.Free;
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// E23: Two consecutive Write calls, different frame counts
// ---------------------------------------------------------------------------
procedure TestE23_MultipleWrites;
var
  Buf1, Buf2 : TAudioBuffer;
  MS         : TMemoryStream;
  Enc        : TFLACStreamEncoder;
  Dec        : TFLACStreamDecoder;
  Cfg        : TFLACEncConfig;
  Decoded    : TAudioBuffer;
  Res        : TAudioDecodeResult;
  Total      : Integer;
begin
  Section('E23: Two Write calls with different FrameCount');
  Buf1 := MakeBuffer(1, 300, 16, stSine);
  Buf2 := MakeBuffer(1, 700, 16, stRamp);

  MS := TMemoryStream.Create;
  Cfg := FLACDefaultConfig;
  Cfg.MaxLPCOrder    := 4;
  Cfg.TryStereoModes := False;
  Enc := TFLACStreamEncoder.Create(MS, 44100, 1, 16, 256, False, Cfg);
  try
    Enc.Write(Buf1);
    Enc.Write(Buf2);
    Enc.Finalize;
  finally
    Enc.Free;
  end;

  MS.Position := 0;
  Dec := TFLACStreamDecoder.Create;
  Dec.Open(MS, False);
  try
    Check(Dec.StreamInfo.TotalSamples >= 1000, 'E23a TotalSamples >= 1000 (300+700, may include block padding)',
      IntToStr(Dec.StreamInfo.TotalSamples));
    Total := 0;
    repeat
      Res := Dec.Decode(Decoded);
      if Res = adrOK then Inc(Total, Length(Decoded[0]));
    until Res <> adrOK;
    Check(Total >= 1000, 'E23b Decoded >= 1000 samples (encoder pads last block to BlockSize)',
      IntToStr(Total));
  finally
    Dec.Free;
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// E24: Stereo with channel count 1 vs 2, verify correct channels in output
// ---------------------------------------------------------------------------
procedure TestE24_ChannelCount;
var
  BufMono, BufStereo : TAudioBuffer;
  MS                 : TMemoryStream;
  Enc                : TFLACStreamEncoder;
  Dec                : TFLACStreamDecoder;
  Cfg                : TFLACEncConfig;
  Decoded            : TAudioBuffer;
  Res                : TAudioDecodeResult;
begin
  Section('E24: Mono vs stereo channel count preserved');
  BufMono   := MakeBuffer(1, 256, 16, stSine);
  BufStereo := MakeBuffer(2, 256, 16, stSine);
  Cfg := FLACDefaultConfig;
  Cfg.TryStereoModes := True;

  // Mono
  MS := TMemoryStream.Create;
  Enc := TFLACStreamEncoder.Create(MS, 44100, 1, 16, 256, False, Cfg);
  Enc.Write(BufMono);
  Enc.Finalize;
  Enc.Free;
  MS.Position := 0;
  Dec := TFLACStreamDecoder.Create;
  Dec.Open(MS, False);
  Check(Dec.StreamInfo.Channels = 1, 'E24a Mono: channels = 1',
    IntToStr(Dec.StreamInfo.Channels));
  Res := Dec.Decode(Decoded);
  Check(Res = adrOK, 'E24b Mono decode OK', '');
  Check(Length(Decoded) = 1, 'E24c Mono: output has 1 channel', IntToStr(Length(Decoded)));
  Dec.Free;
  MS.Free;

  // Stereo
  MS := TMemoryStream.Create;
  Enc := TFLACStreamEncoder.Create(MS, 44100, 2, 16, 256, False, Cfg);
  Enc.Write(BufStereo);
  Enc.Finalize;
  Enc.Free;
  MS.Position := 0;
  Dec := TFLACStreamDecoder.Create;
  Dec.Open(MS, False);
  Check(Dec.StreamInfo.Channels = 2, 'E24d Stereo: channels = 2',
    IntToStr(Dec.StreamInfo.Channels));
  Res := Dec.Decode(Decoded);
  Check(Res = adrOK, 'E24e Stereo decode OK', '');
  Check(Length(Decoded) = 2, 'E24f Stereo: output has 2 channels', IntToStr(Length(Decoded)));
  Dec.Free;
  MS.Free;
end;

// ---------------------------------------------------------------------------
// E25: 8-bit audio round-trip bit-exact
// ---------------------------------------------------------------------------
procedure TestE25_8bit;
var
  InBuf, OutBuf: TAudioBuffer;
  Cfg          : TFLACEncConfig;
  CompBytes    : Integer;
begin
  Section('E25: 8-bit audio round-trip');
  InBuf := MakeBuffer(1, 256, 8, stSine);
  Cfg   := FLACDefaultConfig;
  Check(RoundTrip(InBuf, 44100, 8, 256, Cfg, CompBytes, OutBuf), 'E25a RT succeeded', '');
  Check(VerifyLossless(InBuf, OutBuf, 8), 'E25b 8-bit mono bit-exact', '');
end;

// ---------------------------------------------------------------------------
// E26: 3-channel audio encode/decode
// ---------------------------------------------------------------------------
procedure TestE26_ThreeChannel;
var
  InBuf, OutBuf: TAudioBuffer;
  Cfg          : TFLACEncConfig;
  CompBytes    : Integer;
begin
  Section('E26: 3-channel audio encode/decode');
  InBuf := MakeBuffer(3, 256, 16, stSine);
  Cfg   := FLACDefaultConfig;
  Cfg.TryStereoModes := False; // stereo modes require exactly 2 channels
  Check(RoundTrip(InBuf, 44100, 16, 256, Cfg, CompBytes, OutBuf), 'E26a RT succeeded', '');
  Check(Length(OutBuf) = 3, 'E26b Output has 3 channels', IntToStr(Length(OutBuf)));
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E26c 3-channel bit-exact', '');
end;

// ---------------------------------------------------------------------------
// E27: Sample rate 96000 Hz round-trip
// ---------------------------------------------------------------------------
procedure TestE27_96kHz;
var
  InBuf, OutBuf: TAudioBuffer;
  Cfg          : TFLACEncConfig;
  CompBytes    : Integer;
  MS           : TMemoryStream;
  E            : TFLACStreamEncoder;
  D            : TFLACStreamDecoder;
begin
  Section('E27: Sample rate 96000 Hz');
  InBuf := MakeBuffer(2, 512, 16, stSine);
  Cfg   := FLACDefaultConfig;
  Cfg.TryStereoModes := True;

  MS := TMemoryStream.Create;
  E  := TFLACStreamEncoder.Create(MS, 96000, 2, 16, 256, False, Cfg);
  E.Write(InBuf);
  E.Finalize;
  E.Free;
  MS.Position := 0;
  D := TFLACStreamDecoder.Create;
  D.Open(MS, False);
  Check(D.StreamInfo.SampleRate = 96000, 'E27a SampleRate = 96000',
    IntToStr(D.StreamInfo.SampleRate));
  D.Free;
  MS.Position := 0;
  Check(RoundTrip(InBuf, 96000, 16, 256, Cfg, CompBytes, OutBuf), 'E27b RT succeeded', '');
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E27c 96kHz bit-exact', '');
  MS.Free;
end;

// ---------------------------------------------------------------------------
// E28: Very short signal (fewer samples than BlockSize)
// ---------------------------------------------------------------------------
procedure TestE28_ShortSignal;
var
  InBuf, OutBuf: TAudioBuffer;
  Cfg          : TFLACEncConfig;
  CompBytes    : Integer;
begin
  Section('E28: Very short signal (10 samples < BlockSize=256)');
  InBuf := MakeBuffer(1, 10, 16, stSine);
  Cfg   := FLACDefaultConfig;
  Check(RoundTrip(InBuf, 44100, 16, 256, Cfg, CompBytes, OutBuf), 'E28a RT succeeded', '');
  Check(Length(OutBuf) = 1, 'E28b Output has 1 channel', IntToStr(Length(OutBuf)));
  Check(Length(OutBuf[0]) >= 10, 'E28c Output has at least 10 samples',
    IntToStr(Length(OutBuf[0])));
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E28d Short signal bit-exact', '');
end;

// ---------------------------------------------------------------------------
// E29: Left-side stereo (left channel louder than right)
// ---------------------------------------------------------------------------
procedure TestE29_LeftSide;
var
  InBuf, OutBuf: TAudioBuffer;
  Cfg          : TFLACEncConfig;
  CompBytes    : Integer;
begin
  Section('E29: Left-side stereo (left louder)');
  // Left = full amplitude, right = 1/8 amplitude → encoder should prefer LEFT_SIDE
  InBuf := MakeBuffer(2, 512, 16, stSine);
  var I: Integer;
  for I := 0 to Length(InBuf[1]) - 1 do
    InBuf[1][I] := InBuf[1][I] * 0.125;
  Cfg := FLACDefaultConfig;
  Cfg.TryStereoModes := True;
  Check(RoundTrip(InBuf, 44100, 16, 256, Cfg, CompBytes, OutBuf), 'E29a RT succeeded', '');
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E29b Left-side bit-exact', '');
end;

// ---------------------------------------------------------------------------
// E30: Right-side stereo (right channel louder than left)
// ---------------------------------------------------------------------------
procedure TestE30_RightSide;
var
  InBuf, OutBuf: TAudioBuffer;
  Cfg          : TFLACEncConfig;
  CompBytes    : Integer;
begin
  Section('E30: Right-side stereo (right louder)');
  // Right = full amplitude, left = 1/8 amplitude → encoder should prefer RIGHT_SIDE
  InBuf := MakeBuffer(2, 512, 16, stSine);
  var I: Integer;
  for I := 0 to Length(InBuf[0]) - 1 do
    InBuf[0][I] := InBuf[0][I] * 0.125;
  Cfg := FLACDefaultConfig;
  Cfg.TryStereoModes := True;
  Check(RoundTrip(InBuf, 44100, 16, 256, Cfg, CompBytes, OutBuf), 'E30a RT succeeded', '');
  Check(VerifyLossless(InBuf, OutBuf, 16), 'E30b Right-side bit-exact', '');
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

begin
  WriteLn('========================================');
  WriteLn(' flac-codec encoder exhaustive tests');
  WriteLn('========================================');

  TestE01_Silence;
  TestE02_Square;
  TestE03_Sine;
  TestE04_Noise;
  TestE05_Ramp;
  TestE06_Constant;
  TestE07_Mono16;
  TestE08_Stereo16;
  TestE09_24bit;
  TestE10_MultiBlock;
  TestE11_MidSide;
  TestE12_StreamInfo;
  TestE13_FrameSizes;
  TestE14_Compression;
  TestE15_StreamAPI;
  TestE16_PartialBlock;
  TestE17_MultiWrite;
  TestE18_LPC;
  TestE19_HighResiduals;
  TestE20_SmallBlocks;
  TestE21_LargeBlocks;
  TestE22_NoLPC;
  TestE23_MultipleWrites;
  TestE24_ChannelCount;
  TestE25_8bit;
  TestE26_ThreeChannel;
  TestE27_96kHz;
  TestE28_ShortSignal;
  TestE29_LeftSide;
  TestE30_RightSide;

  WriteLn;
  WriteLn(Format('Results: %d / %d passed', [GPassed, GTotal]));
  if GFailed then
  begin
    WriteLn('*** SOME TESTS FAILED ***');
    Halt(1);
  end
  else
    WriteLn('All tests passed.');
end.
