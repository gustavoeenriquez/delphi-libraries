program AudioCodecTests;

{
  AudioCodecTests.dpr — 30 unit tests for audio-codec (Phase 7)

  Tests cover:
    AC01-AC10 : AudioFormatDetect — magic byte detection for all formats
    AC11-AC20 : IAudioDecoder factory + WAV adapter
    AC21-AC30 : FLAC adapter, Ogg Opus adapter, edge cases

  Each test prints PASS/FAIL. Exit code 1 if any test fails.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, Math,
  AudioTypes,
  AudioFormatDetect,
  AudioCodec,
  WAVTypes;

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

var
  GTotal  : Integer = 0;
  GPassed : Integer = 0;

procedure Check(const Name: string; Cond: Boolean);
begin
  Inc(GTotal);
  if Cond then
  begin
    WriteLn('PASS: ', Name);
    Inc(GPassed);
  end
  else
    WriteLn('FAIL: ', Name);
end;

// ---------------------------------------------------------------------------
// Stream builders — minimal valid byte sequences
// ---------------------------------------------------------------------------

// RIFF WAVE header: 1-channel, 44100 Hz, 16-bit PCM, 4 sample frames (8 bytes)
function MakeWAVStream(Channels: Word = 1; SampleRate: Cardinal = 44100;
  BitsPerSample: Word = 16): TBytesStream;
var
  B  : TBytes;
  SR : Cardinal;
  BA : Cardinal;  // byte rate
  BA2: Word;      // block align
  DataBytes: Cardinal;
begin
  BA2       := Channels * (BitsPerSample div 8);
  SR        := SampleRate;
  BA        := SR * BA2;
  DataBytes := 8;  // 4 sample frames * 2 bytes each

  SetLength(B, 44 + DataBytes);
  // RIFF header
  B[0] := Ord('R'); B[1] := Ord('I'); B[2] := Ord('F'); B[3] := Ord('F');
  PCardinal(@B[4])^ := 36 + DataBytes;  // file size - 8
  B[8]  := Ord('W'); B[9]  := Ord('A'); B[10] := Ord('V'); B[11] := Ord('E');
  // fmt chunk
  B[12] := Ord('f'); B[13] := Ord('m'); B[14] := Ord('t'); B[15] := Ord(' ');
  PCardinal(@B[16])^ := 16;       // chunk size
  PWord(@B[20])^     := 1;        // PCM
  PWord(@B[22])^     := Channels;
  PCardinal(@B[24])^ := SR;
  PCardinal(@B[28])^ := BA;
  PWord(@B[32])^     := BA2;      // block align
  PWord(@B[34])^     := BitsPerSample;
  // data chunk
  B[36] := Ord('d'); B[37] := Ord('a'); B[38] := Ord('t'); B[39] := Ord('a');
  PCardinal(@B[40])^ := DataBytes;
  // samples: silence (zeros already)
  Result := TBytesStream.Create(B);
end;

// RIFF WAVE with IEEE float format tag (float32)
function MakeFloat32WAVStream: TBytesStream;
var
  B  : TBytes;
  DataBytes: Cardinal;
begin
  DataBytes := 16;  // 4 frames * 2 channels * 4 bytes
  SetLength(B, 44 + DataBytes);
  B[0] := Ord('R'); B[1] := Ord('I'); B[2] := Ord('F'); B[3] := Ord('F');
  PCardinal(@B[4])^  := 36 + DataBytes;
  B[8]  := Ord('W'); B[9]  := Ord('A'); B[10] := Ord('V'); B[11] := Ord('E');
  B[12] := Ord('f'); B[13] := Ord('m'); B[14] := Ord('t'); B[15] := Ord(' ');
  PCardinal(@B[16])^ := 16;
  PWord(@B[20])^     := WAVE_FORMAT_IEEE_FLOAT;
  PWord(@B[22])^     := 2;       // stereo
  PCardinal(@B[24])^ := 48000;
  PCardinal(@B[28])^ := 48000 * 8;  // byte rate
  PWord(@B[32])^     := 8;          // block align
  PWord(@B[34])^     := 32;         // bits per sample
  B[36] := Ord('d'); B[37] := Ord('a'); B[38] := Ord('t'); B[39] := Ord('a');
  PCardinal(@B[40])^ := DataBytes;
  Result := TBytesStream.Create(B);
end;

// Minimal FLAC stream: 'fLaC' + STREAMINFO metadata block (34 bytes)
function MakeFLACStream(SampleRate: Cardinal = 44100; Channels: Byte = 2;
  BitsPerSample: Byte = 16; TotalSamples: Int64 = 0): TBytesStream;
var
  B  : TBytes;
  I  : Integer;
begin
  // fLaC marker (4) + block header (4) + STREAMINFO data (34) = 42 bytes
  SetLength(B, 42);
  B[0] := Ord('f'); B[1] := Ord('L'); B[2] := Ord('a'); B[3] := Ord('C');
  // STREAMINFO block header: last-block(1) | type(0=STREAMINFO) | length=34
  B[4] := $80;  // last-metadata-block=1, type=0
  B[5] := 0; B[6] := 0; B[7] := 34;  // block length (big-endian 24-bit)
  // STREAMINFO data (34 bytes): min/max blocksize, min/max framesize,
  // sample_rate(20), channels(3), bps(5), total_samples(36), MD5(16)
  // min blocksize (16-bit): 4096
  B[8]  := $10; B[9]  := $00;
  // max blocksize (16-bit): 4096
  B[10] := $10; B[11] := $00;
  // min framesize (24-bit): 0 (unknown)
  B[12] := 0; B[13] := 0; B[14] := 0;
  // max framesize (24-bit): 0 (unknown)
  B[15] := 0; B[16] := 0; B[17] := 0;
  // [20-bit samplerate | 3-bit channels-1 | 5-bit bps-1 | 36-bit total_samples]
  // Bytes 18-25 pack: samplerate=44100 (0xAC44), channels=2, bps=16, total=0
  // 44100 = 0xAC44
  // bits: [19:0]=samplerate, [22:20]=channels-1, [27:23]=bps-1, [63:28]=total_samples
  // Bit packing into bytes 18..25 (64 bits total):
  //   bits 63-44: samplerate (20 bits) = 0xAC44
  //   bits 43-41: channels-1 (3 bits)  = channels-1
  //   bits 40-36: bps-1 (5 bits)       = bps-1
  //   bits 35-0:  total samples (36 bits) = 0
  var Rate20  : Cardinal := SampleRate and $FFFFF;
  var ChM1    : Byte     := (Channels - 1) and $7;
  var BpsM1   : Byte     := (BitsPerSample - 1) and $1F;
  // Pack into 8 bytes (64 bits), MSB first
  // Byte 18: bits 63-56 = Rate20[19:12]
  B[18] := (Rate20 shr 12) and $FF;
  // Byte 19: bits 55-48 = Rate20[11:4]
  B[19] := (Rate20 shr 4) and $FF;
  // Byte 20: bits 47-40 = Rate20[3:0] | ChM1[2:0] | BpsM1[4:1]
  B[20] := Byte((Rate20 and $F) shl 4) or Byte(ChM1 shl 1) or Byte(BpsM1 shr 4);
  // Byte 21: bits 39-32 = BpsM1[3:0] | TotalSamples[35:32]
  B[21] := Byte((BpsM1 and $F) shl 4);  // total_samples = 0
  // Bytes 22-25: total samples remaining bits = 0
  B[22] := 0; B[23] := 0; B[24] := 0; B[25] := 0;
  // MD5 checksum (16 bytes): zeros
  for I := 26 to 41 do B[I] := 0;

  Result := TBytesStream.Create(B);
end;

// Ogg page bytes for format detection (no valid CRC, just magic + packet content)
function MakeOggPageBytes(const PacketData: array of Byte): TBytes;
var
  NSeg    : Integer;
  SegSize : Integer;
  PktLen  : Integer;
  HeaderLen: Integer;
begin
  PktLen  := Length(PacketData);
  SegSize := PktLen;
  NSeg    := 1;
  // Ogg page: 27-byte capture pattern + NSeg lacing table + packet data
  HeaderLen := 27 + NSeg;
  SetLength(Result, HeaderLen + PktLen);
  // Magic
  Result[0] := Ord('O'); Result[1] := Ord('g');
  Result[2] := Ord('g'); Result[3] := Ord('S');
  Result[4]  := 0;    // version
  Result[5]  := 2;    // header_type: first page
  // granule_pos (8 bytes): 0
  FillChar(Result[6], 8, 0);
  // serial_no (4 bytes): 1
  Result[14] := 1; Result[15] := 0; Result[16] := 0; Result[17] := 0;
  // page_seq (4 bytes): 0
  FillChar(Result[18], 4, 0);
  // CRC (4 bytes): 0 (invalid, but detection does not check CRC)
  FillChar(Result[22], 4, 0);
  // n_segments
  Result[26] := NSeg;
  // segment table
  Result[27] := SegSize;
  // packet data
  Move(PacketData[0], Result[28], PktLen);
end;

function MakeOggVorbisStream: TBytesStream;
const
  VorbisIdPacket: array[0..6] of Byte = (
    $01, Ord('v'), Ord('o'), Ord('r'), Ord('b'), Ord('i'), Ord('s')
  );
var
  B: TBytes;
begin
  B := MakeOggPageBytes(VorbisIdPacket);
  Result := TBytesStream.Create(B);
end;

function MakeOggOpusStream: TBytesStream;
const
  OpusHeadPacket: array[0..7] of Byte = (
    Ord('O'), Ord('p'), Ord('u'), Ord('s'), Ord('H'), Ord('e'), Ord('a'), Ord('d')
  );
var
  B: TBytes;
begin
  B := MakeOggPageBytes(OpusHeadPacket);
  Result := TBytesStream.Create(B);
end;

// ---------------------------------------------------------------------------
// AC01-AC10: AudioFormatDetect
// ---------------------------------------------------------------------------

procedure TestAC01_DetectWAV;
var
  S: TBytesStream;
begin
  S := MakeWAVStream;
  try
    Check('AC01: DetectAudioFormat WAV', DetectAudioFormat(S) = afWAV);
  finally
    S.Free;
  end;
end;

procedure TestAC02_DetectFLAC;
var
  S: TBytesStream;
begin
  S := MakeFLACStream;
  try
    Check('AC02: DetectAudioFormat FLAC', DetectAudioFormat(S) = afFLAC);
  finally
    S.Free;
  end;
end;

procedure TestAC03_DetectOggVorbis;
var
  S: TBytesStream;
begin
  S := MakeOggVorbisStream;
  try
    Check('AC03: DetectAudioFormat Ogg Vorbis', DetectAudioFormat(S) = afVorbis);
  finally
    S.Free;
  end;
end;

procedure TestAC04_DetectOggOpus;
var
  S: TBytesStream;
begin
  S := MakeOggOpusStream;
  try
    Check('AC04: DetectAudioFormat Ogg Opus', DetectAudioFormat(S) = afOpus);
  finally
    S.Free;
  end;
end;

procedure TestAC05_DetectMP3Sync;
var
  B: TBytes;
  S: TBytesStream;
begin
  SetLength(B, 4);
  B[0] := $FF; B[1] := $FB; B[2] := $90; B[3] := $00;  // MPEG-1 Layer3 CBR sync
  S := TBytesStream.Create(B);
  try
    Check('AC05: DetectAudioFormat MP3 sync', DetectAudioFormat(S) = afMP3);
  finally
    S.Free;
  end;
end;

procedure TestAC06_DetectMP3ID3;
var
  B: TBytes;
  S: TBytesStream;
begin
  SetLength(B, 10);
  B[0] := Ord('I'); B[1] := Ord('D'); B[2] := Ord('3');
  B[3] := 3; B[4] := 0; B[5] := 0;  // ID3v2.3
  B[6] := 0; B[7] := 0; B[8] := 0; B[9] := 0;
  S := TBytesStream.Create(B);
  try
    Check('AC06: DetectAudioFormat MP3 ID3', DetectAudioFormat(S) = afMP3);
  finally
    S.Free;
  end;
end;

procedure TestAC07_DetectUnknown;
var
  B: TBytes;
  S: TBytesStream;
begin
  SetLength(B, 8);
  B[0] := $DE; B[1] := $AD; B[2] := $BE; B[3] := $EF;
  B[4] := $CA; B[5] := $FE; B[6] := $BA; B[7] := $BE;
  S := TBytesStream.Create(B);
  try
    Check('AC07: DetectAudioFormat unknown → afUnknown', DetectAudioFormat(S) = afUnknown);
  finally
    S.Free;
  end;
end;

procedure TestAC08_DetectNilStream;
begin
  Check('AC08: DetectAudioFormat nil → afUnknown', DetectAudioFormat(nil) = afUnknown);
end;

procedure TestAC09_StreamPositionRestored;
var
  S    : TBytesStream;
  Before, After: Int64;
begin
  S := MakeWAVStream;
  try
    S.Position := 4;
    Before := S.Position;
    DetectAudioFormat(S);
    After := S.Position;
    Check('AC09: Stream position restored after DetectAudioFormat', Before = After);
  finally
    S.Free;
  end;
end;

procedure TestAC10_EmptyStream;
var
  S: TBytesStream;
begin
  S := TBytesStream.Create(nil);
  try
    Check('AC10: DetectAudioFormat empty stream → afUnknown', DetectAudioFormat(S) = afUnknown);
  finally
    S.Free;
  end;
end;

// ---------------------------------------------------------------------------
// AC11-AC20: CreateAudioDecoder + WAV adapter
// ---------------------------------------------------------------------------

procedure TestAC11_CreateFromNil;
begin
  Check('AC11: CreateAudioDecoder(nil) → nil', CreateAudioDecoder(nil) = nil);
end;

procedure TestAC12_CreateFromWAV;
var
  S   : TBytesStream;
  Dec : IAudioDecoder;
begin
  S   := MakeWAVStream;
  Dec := CreateAudioDecoder(S, True {owns});
  Check('AC12: CreateAudioDecoder WAV → non-nil', Dec <> nil);
end;

procedure TestAC13_WAVAdapterReady;
var
  Dec: IAudioDecoder;
begin
  Dec := CreateAudioDecoder(MakeWAVStream, True);
  Check('AC13: WAV adapter Ready = True', (Dec <> nil) and Dec.Ready);
end;

procedure TestAC14_WAVAdapterInfoFormat;
var
  Dec: IAudioDecoder;
begin
  Dec := CreateAudioDecoder(MakeWAVStream, True);
  Check('AC14: WAV adapter Info.Format = afWAV',
    (Dec <> nil) and (Dec.Info.Format = afWAV));
end;

procedure TestAC15_WAVAdapterSampleRate;
var
  Dec: IAudioDecoder;
begin
  Dec := CreateAudioDecoder(MakeWAVStream(1, 44100, 16), True);
  Check('AC15: WAV adapter Info.SampleRate = 44100',
    (Dec <> nil) and (Dec.Info.SampleRate = 44100));
end;

procedure TestAC16_WAVAdapterChannels;
var
  Dec: IAudioDecoder;
begin
  Dec := CreateAudioDecoder(MakeWAVStream(2, 44100, 16), True);
  Check('AC16: WAV adapter Info.Channels = 2',
    (Dec <> nil) and (Dec.Info.Channels = 2));
end;

procedure TestAC17_WAVDecodeReturnsOK;
var
  Dec  : IAudioDecoder;
  Buf  : TAudioBuffer;
  Res  : TAudioDecodeResult;
begin
  Dec := CreateAudioDecoder(MakeWAVStream(1, 44100, 16), True);
  Buf := nil;
  if Dec <> nil then
    Res := Dec.Decode(Buf)
  else
    Res := adrError;
  Check('AC17: WAV Decode → adrOK or adrEndOfStream',
    Res in [adrOK, adrEndOfStream]);
end;

procedure TestAC18_WAVDecodeUntilEOS;
var
  Dec   : IAudioDecoder;
  Buf   : TAudioBuffer;
  Res   : TAudioDecodeResult;
  Steps : Integer;
begin
  Dec := CreateAudioDecoder(MakeWAVStream(1, 44100, 16), True);
  Steps := 0;
  if Dec <> nil then
  begin
    repeat
      Buf := nil;
      Res := Dec.Decode(Buf);
      Inc(Steps);
    until (Res <> adrOK) or (Steps > 100);
  end
  else
    Res := adrError;
  Check('AC18: WAV Decode eventually returns adrEndOfStream',
    Res = adrEndOfStream);
end;

procedure TestAC19_WAVBitDepth;
var
  Dec: IAudioDecoder;
begin
  Dec := CreateAudioDecoder(MakeWAVStream(1, 44100, 24), True);
  Check('AC19: WAV adapter Info.BitDepth = 24',
    (Dec <> nil) and (Dec.Info.BitDepth = 24));
end;

procedure TestAC20_WAVFloatFlag;
var
  Dec: IAudioDecoder;
begin
  Dec := CreateAudioDecoder(MakeFloat32WAVStream, True);
  Check('AC20: WAV float32 adapter Info.IsFloat = True',
    (Dec <> nil) and Dec.Info.IsFloat);
end;

// ---------------------------------------------------------------------------
// AC21-AC30: FLAC adapter, Opus, edge cases
// ---------------------------------------------------------------------------

procedure TestAC21_CreateFromFLAC;
var
  Dec: IAudioDecoder;
begin
  Dec := CreateAudioDecoder(MakeFLACStream, True);
  Check('AC21: CreateAudioDecoder FLAC → non-nil', Dec <> nil);
end;

procedure TestAC22_FLACAdapterInfoFormat;
var
  Dec: IAudioDecoder;
begin
  Dec := CreateAudioDecoder(MakeFLACStream, True);
  Check('AC22: FLAC adapter Info.Format = afFLAC',
    (Dec <> nil) and (Dec.Info.Format = afFLAC));
end;

procedure TestAC23_FLACAdapterSampleRate;
var
  Dec: IAudioDecoder;
begin
  Dec := CreateAudioDecoder(MakeFLACStream(48000, 1, 16), True);
  Check('AC23: FLAC adapter Info.SampleRate = 48000',
    (Dec <> nil) and (Dec.Info.SampleRate = 48000));
end;

procedure TestAC24_FLACAdapterChannels;
var
  Dec: IAudioDecoder;
begin
  Dec := CreateAudioDecoder(MakeFLACStream(44100, 2, 16), True);
  Check('AC24: FLAC adapter Info.Channels = 2',
    (Dec <> nil) and (Dec.Info.Channels = 2));
end;

procedure TestAC25_FLACAdapterBitDepth;
var
  Dec: IAudioDecoder;
begin
  Dec := CreateAudioDecoder(MakeFLACStream(44100, 1, 24), True);
  Check('AC25: FLAC adapter Info.BitDepth = 24',
    (Dec <> nil) and (Dec.Info.BitDepth = 24));
end;

procedure TestAC26_CreateFromFileNonExistent;
var
  Dec: IAudioDecoder;
begin
  Dec := CreateAudioDecoderFromFile('C:\nonexistent_file_that_cannot_exist.wav');
  Check('AC26: CreateAudioDecoderFromFile nonexistent → nil', Dec = nil);
end;

procedure TestAC27_UnknownFormatReturnsNil;
var
  B  : TBytes;
  S  : TBytesStream;
  Dec: IAudioDecoder;
begin
  SetLength(B, 16);
  FillChar(B[0], 16, $42);
  S   := TBytesStream.Create(B);
  Dec := CreateAudioDecoder(S, True);
  Check('AC27: Unknown format → CreateAudioDecoder returns nil', Dec = nil);
end;

procedure TestAC28_OggVorbisDetectionRoundTrip;
var
  S  : TBytesStream;
  Fmt: TAudioFormat;
begin
  S   := MakeOggVorbisStream;
  Fmt := DetectAudioFormat(S);
  S.Free;
  Check('AC28: Ogg Vorbis bytes → afVorbis (round-trip confirm)', Fmt = afVorbis);
end;

procedure TestAC29_OggOpusDetectionRoundTrip;
var
  S  : TBytesStream;
  Fmt: TAudioFormat;
begin
  S   := MakeOggOpusStream;
  Fmt := DetectAudioFormat(S);
  S.Free;
  Check('AC29: Ogg Opus bytes → afOpus (round-trip confirm)', Fmt = afOpus);
end;

procedure TestAC30_WAVDecodeBufferChannelCount;
var
  Dec  : IAudioDecoder;
  Buf  : TAudioBuffer;
  Res  : TAudioDecodeResult;
begin
  Dec := CreateAudioDecoder(MakeWAVStream(2, 44100, 16), True);
  Buf := nil;
  if Dec <> nil then
    Res := Dec.Decode(Buf)
  else
    Res := adrError;
  // On adrOK: buffer must have 2 channels; on adrEndOfStream: channels may be 0
  Check('AC30: WAV Decode buffer matches channel count',
    (Res = adrEndOfStream) or
    ((Res = adrOK) and (Length(Buf) = 2)));
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

begin
  WriteLn('=== AudioCodec Tests ===');
  WriteLn;

  // Detection
  TestAC01_DetectWAV;
  TestAC02_DetectFLAC;
  TestAC03_DetectOggVorbis;
  TestAC04_DetectOggOpus;
  TestAC05_DetectMP3Sync;
  TestAC06_DetectMP3ID3;
  TestAC07_DetectUnknown;
  TestAC08_DetectNilStream;
  TestAC09_StreamPositionRestored;
  TestAC10_EmptyStream;

  // WAV adapter
  TestAC11_CreateFromNil;
  TestAC12_CreateFromWAV;
  TestAC13_WAVAdapterReady;
  TestAC14_WAVAdapterInfoFormat;
  TestAC15_WAVAdapterSampleRate;
  TestAC16_WAVAdapterChannels;
  TestAC17_WAVDecodeReturnsOK;
  TestAC18_WAVDecodeUntilEOS;
  TestAC19_WAVBitDepth;
  TestAC20_WAVFloatFlag;

  // FLAC and other adapters
  TestAC21_CreateFromFLAC;
  TestAC22_FLACAdapterInfoFormat;
  TestAC23_FLACAdapterSampleRate;
  TestAC24_FLACAdapterChannels;
  TestAC25_FLACAdapterBitDepth;
  TestAC26_CreateFromFileNonExistent;
  TestAC27_UnknownFormatReturnsNil;
  TestAC28_OggVorbisDetectionRoundTrip;
  TestAC29_OggOpusDetectionRoundTrip;
  TestAC30_WAVDecodeBufferChannelCount;

  WriteLn;
  WriteLn(Format('%d/%d tests passed', [GPassed, GTotal]));
  if GPassed < GTotal then
    Halt(1);
end.
