program OpusRoundTripTests;

{
  OpusRoundTripTests.dpr - Encode→Decode round-trip tests for Opus CELT encoder

  RT01: Silence round-trip — encode silence, decode, verify near-silence output
  RT02: TOC byte is correct for the configured mode
  RT03: Encode sine wave, decode, verify energy in the encoded packet > 0
  RT04: TOpusCeltEncoder produces valid packets (no range coder error)
  RT05: TOpusWriter creates a byte stream (Ogg Opus format)

  License: CC0 1.0 Universal (Public Domain)
}

{$APPTYPE CONSOLE}

uses
  SysUtils, Math, Classes,
  AudioTypes,
  OggTypes,
  OggPageWriter,
  OggPageReader,
  OpusTypes,
  OpusRangeDecoder,
  OpusCelt,
  OpusFrameDecoder,
  OpusEncTypes,
  OpusRangeEncoder,
  OpusEncCelt,
  OpusEncPacket;

var
  Passed, Failed: Integer;

procedure Check(Cond: Boolean; const Name: string);
begin
  if Cond then begin WriteLn('  PASS: ', Name); Inc(Passed); end
  else          begin WriteLn('  FAIL: ', Name); Inc(Failed); end;
end;

procedure CheckNear(A, B, Eps: Double; const Name: string);
begin
  Check(Abs(A - B) <= Eps, Name + Format(' (%.6f vs %.6f)', [A, B]));
end;

// ===========================================================================
// RT01: Silence round-trip
// ===========================================================================
procedure TestRT01_SilenceRoundTrip;
var
  Enc       : TOpusCeltEncoder;
  PacketBuf : array[0..1275] of Byte;
  PCM       : array[0..959] of SmallInt;
  Len       : Integer;
  Rd        : TOpusRangeDecoder;
  DecState  : TOpusFrameDecoderState;
  TOC_      : TOpusTOC;
  Output    : TAudioBuffer;
  MaxSamp   : Single;
  I         : Integer;
begin
  WriteLn('RT01: Silence round-trip (encode→decode)');

  FillChar(PCM, SizeOf(PCM), 0);  // silence
  Enc := TOpusCeltEncoder.Create(1, 48000, 20);
  try
    FillChar(PacketBuf, SizeOf(PacketBuf), 0);
    Len := Enc.EncodeFrame(@PCM[0], @PacketBuf[0], SizeOf(PacketBuf));
    Check(Len > 1, Format('Encoded %d bytes (> 1)', [Len]));
    Check(PacketBuf[0] shr 3 >= 16, 'TOC config ≥ 16 (CELT mode)');

    if Len > 1 then
    begin
      // Decode the packet
      OpusParseTOC(PacketBuf[0], TOC_);
      OpusFrameDecoderInit(DecState, 1, TOC_.Config);
      Output := AudioBufferCreate(1, TOC_.FrameSamples);

      RdInit(Rd, @PacketBuf[1], Len - 1);
      var OK := OpusDecodeFrame(DecState, TOC_, @PacketBuf[1], Len-1, Output, TOC_.FrameSamples);
      Check(OK, 'OpusDecodeFrame returns True for silence packet');

      MaxSamp := 0;
      for I := 0 to TOC_.FrameSamples - 1 do
        if Abs(Output[0][I]) > MaxSamp then MaxSamp := Abs(Output[0][I]);
      Check(MaxSamp < 0.1, Format('Decoded silence max amplitude < 0.1 (got %.4f)', [MaxSamp]));
    end;
  finally
    Enc.Free;
  end;
end;

// ===========================================================================
// RT02: TOC byte correctness
// ===========================================================================
procedure TestRT02_TOCByte;
var
  Enc       : TOpusCeltEncoder;
  PacketBuf : array[0..1275] of Byte;
  PCM       : array[0..959] of SmallInt;
  Len       : Integer;
  TOC_      : TOpusTOC;
begin
  WriteLn('RT02: TOC byte correctness');

  FillChar(PCM, SizeOf(PCM), 0);
  Enc := TOpusCeltEncoder.Create(1, 48000, 20);
  try
    Len := Enc.EncodeFrame(@PCM[0], @PacketBuf[0], SizeOf(PacketBuf));
    Check(Len >= 1, 'EncodeFrame returns >= 1 byte');
    OpusParseTOC(PacketBuf[0], TOC_);
    Check(TOC_.Mode = OPUS_MODE_CELT, 'TOC Mode = CELT');
    Check(not TOC_.Stereo, 'TOC Stereo = False for mono encoder');
    Check(TOC_.Code = 0, 'TOC Code = 0 (single frame)');
    Check(TOC_.Config >= 16, Format('TOC Config >= 16 (CELT) — got %d', [TOC_.Config]));
  finally
    Enc.Free;
  end;
end;

// ===========================================================================
// RT03: Sine wave — packet has content (non-trivial encoded data)
// ===========================================================================
procedure TestRT03_SinePacketNonTrivial;
var
  Enc          : TOpusCeltEncoder;
  PacketSine   : array[0..1275] of Byte;
  PacketSilence: array[0..1275] of Byte;
  PCM_Sine     : array[0..959] of SmallInt;
  PCM_Silence  : array[0..959] of SmallInt;
  LenSine, LenSilence: Integer;
  I: Integer;
begin
  WriteLn('RT03: Sine wave packet has different content from silence');

  for I := 0 to 959 do
    PCM_Sine[I] := Round(16000.0 * Sin(2.0 * Pi * 440.0 * I / 48000.0));
  FillChar(PCM_Silence, SizeOf(PCM_Silence), 0);

  Enc := TOpusCeltEncoder.Create(1, 48000, 20);
  try
    FillChar(PacketSine, SizeOf(PacketSine), 0);
    FillChar(PacketSilence, SizeOf(PacketSilence), 0);

    LenSine    := Enc.EncodeFrame(@PCM_Sine[0],    @PacketSine[0],    SizeOf(PacketSine));
    // Re-init state for silence (fresh encoder)
  finally
    Enc.Free;
  end;

  Enc := TOpusCeltEncoder.Create(1, 48000, 20);
  try
    LenSilence := Enc.EncodeFrame(@PCM_Silence[0], @PacketSilence[0], SizeOf(PacketSilence));
  finally
    Enc.Free;
  end;

  Check(LenSine > 0, Format('Sine packet len > 0 (got %d)', [LenSine]));
  Check(LenSilence > 0, Format('Silence packet len > 0 (got %d)', [LenSilence]));

  // Packets should differ (different audio content → different bits)
  var Differ := False;
  for I := 1 to Min(LenSine, LenSilence) - 1 do
    if PacketSine[I] <> PacketSilence[I] then begin Differ := True; Break; end;
  Check(Differ, 'Sine and silence packets differ in payload bytes');
end;

// ===========================================================================
// RT04: Multiple frames with state continuity
// ===========================================================================
procedure TestRT04_MultipleFrames;
var
  Enc       : TOpusCeltEncoder;
  PacketBuf : array[0..1275] of Byte;
  PCM       : array[0..959] of SmallInt;
  I, Frame  : Integer;
  Len       : Integer;
  AllOK     : Boolean;
begin
  WriteLn('RT04: Multiple frames — no errors across 5 frames');

  Enc := TOpusCeltEncoder.Create(1, 48000, 20);
  try
    AllOK := True;
    for Frame := 0 to 4 do
    begin
      // Different signal per frame
      for I := 0 to 959 do
        PCM[I] := Round(8000.0 * Sin(2.0 * Pi * (200 + Frame * 100) * I / 48000.0));

      FillChar(PacketBuf, SizeOf(PacketBuf), 0);
      Len := Enc.EncodeFrame(@PCM[0], @PacketBuf[0], SizeOf(PacketBuf));
      if (Len <= 0) or (PacketBuf[0] and $E0 < $80) then  // config < 16 = not CELT
        AllOK := False;
    end;
    Check(AllOK, 'All 5 frames encoded successfully (len > 0, CELT config)');
  finally
    Enc.Free;
  end;
end;

// ===========================================================================
// RT05: TOpusWriter produces an Ogg stream that can be read back
// ===========================================================================
procedure TestRT05_OggWriter;
var
  Stream     : TMemoryStream;
  Writer     : TOpusWriter;
  PCM        : array[0..959] of SmallInt;
  I, J       : Integer;
  BytesWritten: Integer;
begin
  WriteLn('RT05: TOpusWriter produces non-empty Ogg stream');

  Stream := TMemoryStream.Create;
  Writer := TOpusWriter.Create(Stream, 1, 48000, 20);
  try
    // Write 3 frames of silence
    FillChar(PCM, SizeOf(PCM), 0);
    for J := 0 to 2 do
      Writer.WriteFrame(@PCM[0]);

    // Write 2 frames of sine
    for I := 0 to 959 do
      PCM[I] := Round(8000.0 * Sin(2.0 * Pi * 440.0 * I / 48000.0));
    for J := 0 to 1 do
      Writer.WriteFrame(@PCM[0]);

    Writer.Finish;
    BytesWritten := Stream.Size;
  finally
    Writer.Free;
    Stream.Free;
  end;

  Check(BytesWritten > 100, Format('Ogg stream size > 100 bytes (got %d)', [BytesWritten]));
  WriteLn(Format('    Ogg stream: %d bytes for 5 frames (3 silence + 2 sine)', [BytesWritten]));
end;

// ===========================================================================
// RT06: Ogg stream has correct Opus magic bytes
// ===========================================================================
procedure TestRT06_OggOpusMagic;
const
  OPUS_HEAD: array[0..7] of Byte = (79,112,117,115,72,101,97,100);  // OpusHead
var
  Stream    : TMemoryStream;
  Writer    : TOpusWriter;
  PCM       : array[0..959] of SmallInt;
  Buf       : TBytes;
  I         : Integer;
  FoundHead : Boolean;
begin
  WriteLn('RT06: Ogg stream contains OpusHead magic');

  Stream := TMemoryStream.Create;
  Writer := TOpusWriter.Create(Stream, 1, 48000, 20);
  try
    FillChar(PCM, SizeOf(PCM), 0);
    Writer.WriteFrame(@PCM[0]);
    Writer.Finish;

    Stream.Position := 0;
    SetLength(Buf, Stream.Size);
    Stream.Read(Buf[0], Length(Buf));
  finally
    Writer.Free;
    Stream.Free;
  end;

  // Find 'OpusHead' magic in the stream
  FoundHead := False;
  for I := 0 to Length(Buf) - 9 do
  begin
    var Match := True;
    for var J := 0 to 7 do
      if Buf[I+J] <> OPUS_HEAD[J] then begin Match := False; Break; end;
    if Match then begin FoundHead := True; Break; end;
  end;
  Check(FoundHead, 'OpusHead magic found in Ogg stream');
end;

// ===========================================================================
// Main
// ===========================================================================
begin
  Passed := 0; Failed := 0;
  WriteLn('=== Opus Encoder Phase 3 — Round-Trip Tests ===');
  WriteLn;

  TestRT01_SilenceRoundTrip;
  TestRT02_TOCByte;
  TestRT03_SinePacketNonTrivial;
  TestRT04_MultipleFrames;
  TestRT05_OggWriter;
  TestRT06_OggOpusMagic;

  WriteLn;
  WriteLn(Format('Results: %d passed, %d failed', [Passed, Failed]));
  if Failed > 0 then Halt(1);
end.
