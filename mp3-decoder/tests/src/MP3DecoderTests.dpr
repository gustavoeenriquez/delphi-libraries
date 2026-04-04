program MP3DecoderTests;

{
  MP3DecoderTests.dpr - Automated test suite for the mp3-decoder library

  Tests cover:
    M01-M05  TMP3BitStream operations
    M06      hdr_valid validation rules
    M07      hdr_sample_rate_hz
    M08      hdr_bitrate_kbps
    M09      hdr_frame_bytes / hdr_padding
    M10      hdr_frame_samples
    M11      HDR_IS_MONO
    M12      TMP3FrameParser.SideInfoSize
    M13      L3_pow_43
    M14      HDR_TEST_MPEG1 / HDR_TEST_NOT_MPEG25
    M15      HDR_TEST_PADDING / hdr_padding
    M16      HDR_GET_LAYER
    M17      HDR_GET_BITRATE
    M18      ParseHeader on real MP3 file (skipped if absent)
    M19-M24  Integration decode of real MP3 file

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$APPTYPE CONSOLE}
{$R *.res}

uses
  SysUtils, Classes, Math,
  MP3Types        in '..\..\src\MP3Types.pas',
  MP3BitStream    in '..\..\src\MP3BitStream.pas',
  MP3Frame        in '..\..\src\MP3Frame.pas',
  MP3Huffman      in '..\..\src\MP3Huffman.pas',
  MP3ScaleFactors in '..\..\src\MP3ScaleFactors.pas',
  MP3Layer3       in '..\..\src\MP3Layer3.pas';

// ---------------------------------------------------------------------------
// Test infrastructure
// ---------------------------------------------------------------------------

var
  GPass, GFail: Integer;

procedure Pass(const Name: string);
begin
  Inc(GPass);
  WriteLn('  PASS  ', Name);
end;

procedure Fail(const Name, Reason: string);
begin
  Inc(GFail);
  WriteLn('  FAIL  ', Name, ' [', Reason, ']');
end;

procedure Check(Cond: Boolean; const Name: string; const Reason: string = '');
begin
  if Cond then Pass(Name) else Fail(Name, Reason);
end;

procedure CheckEq(A, B: Integer; const Name: string); overload;
begin
  if A = B then Pass(Name)
  else Fail(Name, Format('got %d expected %d', [A, B]));
end;

procedure CheckNear(A, B, Eps: Single; const Name: string);
begin
  if Abs(A - B) <= Eps then Pass(Name)
  else Fail(Name, Format('got %g expected %g (eps=%g)', [A, B, Eps]));
end;

// ---------------------------------------------------------------------------
// Test header constants
//
// MPEG1 Layer3:  h[1] = $FB  (sync + NOT_MPEG25=1 + MPEG1=1 + Layer=01 + CRC=1)
// MPEG2 Layer3:  h[1] = $F3  (sync + NOT_MPEG25=1 + MPEG1=0 + Layer=01 + CRC=1)
// MPEG2.5 Layer3:h[1] = $E3  ((h[1]&$FE)=$E2 + Layer=01 + CRC=1)
// ---------------------------------------------------------------------------

const
  // MPEG1 Layer3 stereo 128kbps 44100Hz — no padding
  // h[2]=$90: bitrate_idx=9 (halfrate[1][0][9]=64->128k), sr=0->44100, pad=0
  HDR_MPEG1_STEREO_128K_44100:  array[0..3] of Byte = ($FF, $FB, $90, $04);

  // MPEG1 Layer3 mono 128kbps 44100Hz
  // h[3]=$C4: stereo_mode=3 (mono)
  HDR_MPEG1_MONO_128K_44100:    array[0..3] of Byte = ($FF, $FB, $90, $C4);

  // MPEG1 Layer3 stereo 128kbps 44100Hz — padded (+1 byte)
  // h[2]=$92: pad bit set
  HDR_MPEG1_STEREO_128K_PADDED: array[0..3] of Byte = ($FF, $FB, $92, $04);

  // MPEG2 Layer3 stereo 64kbps 22050Hz
  // h[2]=$80: bitrate_idx=8 (halfrate[0][0][8]=32->64k), sr=0->22050, pad=0
  HDR_MPEG2_STEREO_64K_22050:   array[0..3] of Byte = ($FF, $F3, $80, $04);

  // MPEG2.5 Layer3 stereo 24kbps 11025Hz
  // h[2]=$30: bitrate_idx=3 (halfrate[0][0][3]=12->24k), sr=0->11025, pad=0
  HDR_MPEG25_STEREO_24K_11025:  array[0..3] of Byte = ($FF, $E3, $30, $04);

  // Invalid: bitrate_index=15
  HDR_INVALID_BITRATE15:        array[0..3] of Byte = ($FF, $FB, $F0, $04);

  // Invalid: sample_rate_index=3
  HDR_INVALID_SR3:              array[0..3] of Byte = ($FF, $FB, $9C, $04);

  // Invalid: no sync (h[0] != $FF)
  HDR_INVALID_NOSYNC:           array[0..3] of Byte = ($AA, $FB, $90, $04);

// ---------------------------------------------------------------------------
// M01-M05  TMP3BitStream
// ---------------------------------------------------------------------------

procedure TestBitStream;
var
  Data: TBytes;
  BS: TMP3BitStream;
begin
  WriteLn('--- M01 BitStream ReadBits ---');
  SetLength(Data, 4);
  Data[0] := $A5; // 1010_0101
  Data[1] := $3C; // 0011_1100
  Data[2] := $FF;
  Data[3] := $00;
  BS := TMP3BitStream.Create(Data);
  try
    // Read 4 bits: 1010 = 10
    CheckEq(Integer(BS.ReadBits(4)), 10, 'M01 Read 4 MSB of $A5');
    // Read next 4 bits: 0101 = 5
    CheckEq(Integer(BS.ReadBits(4)),  5, 'M01 Read 4 LSB of $A5');
    // Read 8 bits: $3C = 60
    CheckEq(Integer(BS.ReadBits(8)), 60, 'M01 Read full byte $3C');
  finally
    BS.Free;
  end;

  WriteLn('--- M02 BitStream PeekBits ---');
  BS := TMP3BitStream.Create(Data);
  try
    var V1 := BS.PeekBits(8);
    var V2 := BS.PeekBits(8);
    CheckEq(Integer(V1), Integer(V2), 'M02 PeekBits does not advance');
    CheckEq(Integer(V1), $A5,         'M02 PeekBits value = $A5');
  finally
    BS.Free;
  end;

  WriteLn('--- M03 BitStream SkipBits ---');
  BS := TMP3BitStream.Create(Data);
  try
    BS.SkipBits(8);  // skip $A5
    CheckEq(Integer(BS.ReadBits(8)), $3C, 'M03 Skip 8 bits lands on $3C');
  finally
    BS.Free;
  end;

  WriteLn('--- M04 BitStream BitsLeft ---');
  BS := TMP3BitStream.Create(Data);
  try
    CheckEq(Integer(BS.BitsLeft), 32, 'M04 BitsLeft=32 at start');
    BS.ReadBits(8);
    CheckEq(Integer(BS.BitsLeft), 24, 'M04 BitsLeft=24 after 8 bits');
    BS.ReadBits(24);
    CheckEq(Integer(BS.BitsLeft),  0, 'M04 BitsLeft=0 at end');
  finally
    BS.Free;
  end;

  WriteLn('--- M05 BitStream SetPosition ---');
  BS := TMP3BitStream.Create(Data);
  try
    BS.SetPosition(2);         // jump to byte 2 ($FF)
    CheckEq(Integer(BS.ReadBits(8)), $FF, 'M05 SetPosition to byte 2');
    BS.SetPosition(0);         // rewind to start
    CheckEq(Integer(BS.ReadBits(8)), $A5, 'M05 SetPosition rewind to 0');
  finally
    BS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// M06  hdr_valid
// ---------------------------------------------------------------------------

procedure TestHdrValid;
begin
  WriteLn('--- M06 hdr_valid ---');

  Check(hdr_valid(@HDR_MPEG1_STEREO_128K_44100[0]),  'M06 Valid MPEG1 Layer3 stereo');
  Check(hdr_valid(@HDR_MPEG2_STEREO_64K_22050[0]),   'M06 Valid MPEG2 Layer3 stereo');
  Check(hdr_valid(@HDR_MPEG25_STEREO_24K_11025[0]),  'M06 Valid MPEG2.5 Layer3 stereo');
  Check(not hdr_valid(@HDR_INVALID_BITRATE15[0]),    'M06 Invalid bitrate_idx=15');
  Check(not hdr_valid(@HDR_INVALID_SR3[0]),          'M06 Invalid sr_idx=3');
  Check(not hdr_valid(@HDR_INVALID_NOSYNC[0]),       'M06 Invalid no sync byte');
end;

// ---------------------------------------------------------------------------
// M07  hdr_sample_rate_hz
// ---------------------------------------------------------------------------

procedure TestSampleRate;
begin
  WriteLn('--- M07 hdr_sample_rate_hz ---');

  CheckEq(Integer(hdr_sample_rate_hz(@HDR_MPEG1_STEREO_128K_44100[0])), 44100,
    'M07 MPEG1 sr=44100');
  CheckEq(Integer(hdr_sample_rate_hz(@HDR_MPEG2_STEREO_64K_22050[0])), 22050,
    'M07 MPEG2 sr=22050');
  CheckEq(Integer(hdr_sample_rate_hz(@HDR_MPEG25_STEREO_24K_11025[0])), 11025,
    'M07 MPEG2.5 sr=11025');
end;

// ---------------------------------------------------------------------------
// M08  hdr_bitrate_kbps
// ---------------------------------------------------------------------------

procedure TestBitrateKbps;
begin
  WriteLn('--- M08 hdr_bitrate_kbps ---');

  CheckEq(Integer(hdr_bitrate_kbps(@HDR_MPEG1_STEREO_128K_44100[0])), 128,
    'M08 MPEG1 128kbps');
  CheckEq(Integer(hdr_bitrate_kbps(@HDR_MPEG2_STEREO_64K_22050[0])), 64,
    'M08 MPEG2 64kbps');
end;

// ---------------------------------------------------------------------------
// M09  hdr_frame_bytes / hdr_padding
// ---------------------------------------------------------------------------

procedure TestFrameBytes;
begin
  WriteLn('--- M09 hdr_frame_bytes ---');

  // MPEG1 Layer3 128k 44100: (1152*128*125)/44100 = 417
  CheckEq(hdr_frame_bytes(@HDR_MPEG1_STEREO_128K_44100[0], 0), 417,
    'M09 MPEG1 128k 44100 no-pad=417');

  // Padded: frame_bytes + padding = 417 + 1 = 418
  CheckEq(hdr_frame_bytes(@HDR_MPEG1_STEREO_128K_PADDED[0], 0) +
          hdr_padding(@HDR_MPEG1_STEREO_128K_PADDED[0]), 418,
    'M09 MPEG1 128k 44100 padded total=418');

  // MPEG2 Layer3 64k 22050: (576*64*125)/22050 = 208
  CheckEq(hdr_frame_bytes(@HDR_MPEG2_STEREO_64K_22050[0], 0), 208,
    'M09 MPEG2 64k 22050=208');

  // hdr_padding values
  CheckEq(hdr_padding(@HDR_MPEG1_STEREO_128K_PADDED[0]), 1,
    'M09 padding=1 for padded header');
  CheckEq(hdr_padding(@HDR_MPEG1_STEREO_128K_44100[0]), 0,
    'M09 padding=0 for unpadded header');
end;

// ---------------------------------------------------------------------------
// M10  hdr_frame_samples
// ---------------------------------------------------------------------------

procedure TestFrameSamples;
begin
  WriteLn('--- M10 hdr_frame_samples ---');

  CheckEq(Integer(hdr_frame_samples(@HDR_MPEG1_STEREO_128K_44100[0])), 1152,
    'M10 MPEG1 Layer3=1152 samples');
  CheckEq(Integer(hdr_frame_samples(@HDR_MPEG2_STEREO_64K_22050[0])), 576,
    'M10 MPEG2 Layer3=576 samples');
end;

// ---------------------------------------------------------------------------
// M11  HDR_IS_MONO
// ---------------------------------------------------------------------------

procedure TestIsMono;
begin
  WriteLn('--- M11 HDR_IS_MONO ---');

  Check(not HDR_IS_MONO(HDR_MPEG1_STEREO_128K_44100), 'M11 Stereo header is NOT mono');
  Check(HDR_IS_MONO(HDR_MPEG1_MONO_128K_44100),       'M11 Mono header IS mono');
end;

// ---------------------------------------------------------------------------
// M12  TMP3FrameParser.SideInfoSize
// ---------------------------------------------------------------------------

procedure TestSideInfoSize;
var
  Hdr: TMP3FrameHeader;
begin
  WriteLn('--- M12 SideInfoSize ---');

  // MPEG1 stereo = 32
  FillChar(Hdr, SizeOf(Hdr), 0);
  Move(HDR_MPEG1_STEREO_128K_44100[0], Hdr.hdr[0], 4);
  Hdr.Channels := 2;
  CheckEq(TMP3FrameParser.SideInfoSize(Hdr), 32, 'M12 MPEG1 stereo SideInfo=32');

  // MPEG1 mono = 17
  Move(HDR_MPEG1_MONO_128K_44100[0], Hdr.hdr[0], 4);
  Hdr.Channels := 1;
  CheckEq(TMP3FrameParser.SideInfoSize(Hdr), 17, 'M12 MPEG1 mono SideInfo=17');

  // MPEG2 stereo = 17
  FillChar(Hdr, SizeOf(Hdr), 0);
  Move(HDR_MPEG2_STEREO_64K_22050[0], Hdr.hdr[0], 4);
  Hdr.Channels := 2;
  CheckEq(TMP3FrameParser.SideInfoSize(Hdr), 17, 'M12 MPEG2 stereo SideInfo=17');

  // MPEG2 mono = 9
  Move(HDR_MPEG2_STEREO_64K_22050[0], Hdr.hdr[0], 4);
  Hdr.Channels := 1;
  CheckEq(TMP3FrameParser.SideInfoSize(Hdr), 9, 'M12 MPEG2 mono SideInfo=9');
end;

// ---------------------------------------------------------------------------
// M13  L3_pow_43
// ---------------------------------------------------------------------------

procedure TestPow43;
begin
  WriteLn('--- M13 L3_pow_43 ---');

  // x^(4/3): uses g_pow43 table for x < 129
  CheckNear(L3_pow_43(0),  0.0,      1e-5, 'M13 L3_pow_43(0)=0');
  CheckNear(L3_pow_43(1),  1.0,      1e-5, 'M13 L3_pow_43(1)=1');
  CheckNear(L3_pow_43(4),  6.349604, 1e-4, 'M13 L3_pow_43(4)=6.349604');
  CheckNear(L3_pow_43(8), 16.0,      1e-4, 'M13 L3_pow_43(8)=16.0');
end;

// ---------------------------------------------------------------------------
// M14  HDR_TEST_MPEG1 / HDR_TEST_NOT_MPEG25
// ---------------------------------------------------------------------------

procedure TestMpegVersionFlags;
begin
  WriteLn('--- M14 MPEG version flags ---');

  Check(HDR_TEST_MPEG1(HDR_MPEG1_STEREO_128K_44100),
    'M14 MPEG1 header: MPEG1=True');
  Check(HDR_TEST_NOT_MPEG25(HDR_MPEG1_STEREO_128K_44100),
    'M14 MPEG1 header: NOT_MPEG25=True');

  Check(not HDR_TEST_MPEG1(HDR_MPEG2_STEREO_64K_22050),
    'M14 MPEG2 header: MPEG1=False');
  Check(HDR_TEST_NOT_MPEG25(HDR_MPEG2_STEREO_64K_22050),
    'M14 MPEG2 header: NOT_MPEG25=True');

  Check(not HDR_TEST_MPEG1(HDR_MPEG25_STEREO_24K_11025),
    'M14 MPEG2.5 header: MPEG1=False');
  Check(not HDR_TEST_NOT_MPEG25(HDR_MPEG25_STEREO_24K_11025),
    'M14 MPEG2.5 header: NOT_MPEG25=False');
end;

// ---------------------------------------------------------------------------
// M15  HDR_TEST_PADDING / hdr_padding
// ---------------------------------------------------------------------------

procedure TestPaddingFlag;
begin
  WriteLn('--- M15 Padding flag ---');

  Check(not HDR_TEST_PADDING(HDR_MPEG1_STEREO_128K_44100),
    'M15 No-pad header: TEST_PADDING=False');
  CheckEq(hdr_padding(@HDR_MPEG1_STEREO_128K_44100[0]), 0,
    'M15 No-pad header: hdr_padding=0');

  Check(HDR_TEST_PADDING(HDR_MPEG1_STEREO_128K_PADDED),
    'M15 Padded header: TEST_PADDING=True');
  CheckEq(hdr_padding(@HDR_MPEG1_STEREO_128K_PADDED[0]), 1,
    'M15 Padded header: hdr_padding=1');
end;

// ---------------------------------------------------------------------------
// M16  HDR_GET_LAYER
// ---------------------------------------------------------------------------

procedure TestGetLayer;
begin
  WriteLn('--- M16 HDR_GET_LAYER ---');

  // Layer3 encoding in header bits = 01 -> GET_LAYER returns 1
  CheckEq(HDR_GET_LAYER(HDR_MPEG1_STEREO_128K_44100), 1,
    'M16 MPEG1 Layer3 GET_LAYER=1');
  CheckEq(HDR_GET_LAYER(HDR_MPEG2_STEREO_64K_22050), 1,
    'M16 MPEG2 Layer3 GET_LAYER=1');
end;

// ---------------------------------------------------------------------------
// M17  HDR_GET_BITRATE
// ---------------------------------------------------------------------------

procedure TestGetBitrate;
begin
  WriteLn('--- M17 HDR_GET_BITRATE ---');

  CheckEq(HDR_GET_BITRATE(HDR_MPEG1_STEREO_128K_44100), 9,
    'M17 MPEG1 128k: bitrate_idx=9');
  CheckEq(HDR_GET_BITRATE(HDR_MPEG2_STEREO_64K_22050), 8,
    'M17 MPEG2 64k: bitrate_idx=8');
end;

// ---------------------------------------------------------------------------
// M18  ParseHeader on real file
// ---------------------------------------------------------------------------

procedure TestParseHeaderRealFile(const SamplePath: string);
var
  Stream: TFileStream;
  Header: TMP3FrameHeader;
begin
  WriteLn('--- M18 ParseHeader real file ---');
  if not FileExists(SamplePath) then
  begin
    WriteLn('  SKIP  M18 sample file not found: ', SamplePath);
    Exit;
  end;

  Stream := TFileStream.Create(SamplePath, fmOpenRead or fmShareDenyNone);
  try
    if not TMP3FrameParser.ParseHeader(Stream, Header) then
    begin
      Fail('M18 ParseHeader returns True', 'returned False');
      Exit;
    end;
    Check(True, 'M18 ParseHeader returns True');
    CheckEq(Header.Layer, 3, 'M18 Layer=3');
    Check(Header.SampleRate > 0,  'M18 SampleRate > 0');
    Check(Header.Bitrate > 0,     'M18 Bitrate > 0');
    Check(Header.FrameSize > 20,  'M18 FrameSize > 20 bytes');
    Check(hdr_valid(@Header.hdr[0]), 'M18 hdr_valid on parsed header');
    Check((Header.Channels = 1) or (Header.Channels = 2), 'M18 Channels is 1 or 2');
  finally
    Stream.Free;
  end;
end;

// ---------------------------------------------------------------------------
// M19-M24  Integration decode of real file
// ---------------------------------------------------------------------------

procedure TestDecodeRealFile(const SamplePath: string);
var
  Stream: TFileStream;
  Header: TMP3FrameHeader;
  SideInfo: TMP3SideInfo;
  BS: TMP3BitStream;
  Decoder: TMP3Layer3Decoder;
  PCMLeft, PCMRight: TArray<Single>;
  ReservBuf: array[0..MAX_BITRESERVOIR_BYTES - 1] of Byte;
  ReservSize: Integer;
  MainDataBuf: TBytes;
  FrameData: TBytes;
  SideInfoSz, FrameDataLen, MainDataBegin: Integer;
  SamplesPerFrame, FrameCount, TotalSamples: Integer;
  AllInRange: Boolean;
  V: Single;
  I: Integer;
begin
  WriteLn('--- M19-M24 Integration decode ---');
  if not FileExists(SamplePath) then
  begin
    WriteLn('  SKIP  M19-M24 sample file not found: ', SamplePath);
    Exit;
  end;

  Stream := TFileStream.Create(SamplePath, fmOpenRead or fmShareDenyNone);
  Decoder := TMP3Layer3Decoder.Create;
  try
    FrameCount   := 0;
    TotalSamples := 0;
    AllInRange   := True;
    SamplesPerFrame := 1152;
    FillChar(ReservBuf, SizeOf(ReservBuf), 0);
    ReservSize := 0;

    // Decode up to 10 frames to verify basic correctness
    while (FrameCount < 10) and (Stream.Position < Stream.Size - 4) do
    begin
      if not TMP3FrameParser.ParseHeader(Stream, Header) then Break;

      SideInfoSz := TMP3FrameParser.SideInfoSize(Header);
      SamplesPerFrame := hdr_frame_samples(@Header.hdr[0]);

      // Read frame payload (everything after 4-byte header)
      FrameDataLen := Header.FrameSize - 4;
      if FrameDataLen <= SideInfoSz then Break;

      SetLength(FrameData, FrameDataLen);
      if Stream.Read(FrameData[0], FrameDataLen) <> FrameDataLen then Break;

      // Parse side info from beginning of frame payload
      BS := TMP3BitStream.Create(FrameData, 0);
      try
        if not TMP3FrameParser.ParseSideInfo(BS, Header, SideInfo) then Break;
      finally
        BS.Free;
      end;

      MainDataBegin := SideInfo.MainDataBegin;

      // Build main data buffer: reservoir prefix + main data from this frame
      var MainDataOffset := SideInfoSz;
      var MainDataBytes  := FrameDataLen - SideInfoSz;

      SetLength(MainDataBuf, ReservSize + MainDataBytes);
      if ReservSize > 0 then
        Move(ReservBuf[0], MainDataBuf[0], ReservSize);
      if MainDataBytes > 0 then
        Move(FrameData[MainDataOffset], MainDataBuf[ReservSize], MainDataBytes);

      // Decode
      Decoder.DecodeFrame(Header, SideInfo, MainDataBuf, MainDataBegin,
        PCMLeft, PCMRight);

      // Update reservoir: keep tail of accumulated buffer
      var NewReserv := ReservSize + MainDataBytes;
      if NewReserv > MAX_BITRESERVOIR_BYTES then NewReserv := MAX_BITRESERVOIR_BYTES;
      if NewReserv > 0 then
        Move(MainDataBuf[Length(MainDataBuf) - NewReserv],
             ReservBuf[0], NewReserv);
      ReservSize := NewReserv;

      // Check PCM samples are in reasonable range
      for I := 0 to Length(PCMLeft) - 1 do
      begin
        V := PCMLeft[I];
        if (V < -1.1) or (V > 1.1) then AllInRange := False;
      end;

      Inc(FrameCount);
      Inc(TotalSamples, SamplesPerFrame);
    end;

    // M19: decoded at least 3 frames
    Check(FrameCount >= 3, 'M19 Decoded >= 3 frames');

    // M20: total samples > 0
    Check(TotalSamples > 0, 'M20 TotalSamples > 0');

    // M21: PCM samples in reasonable range
    Check(AllInRange, 'M21 PCM samples in [-1.1, 1.1]');

    // M22: PCMLeft non-empty after last decode
    Check(Length(PCMLeft) > 0, 'M22 PCMLeft non-empty');

    // M23: channel count consistent with header
    if Header.Channels = 1 then
      Check(Length(PCMLeft) > 0, 'M23 Mono: PCMLeft non-empty')
    else
      Check(Length(PCMLeft) = Length(PCMRight), 'M23 Stereo: PCMLeft=PCMRight length');

    // M24: sample count per frame is 576 or 1152
    Check((SamplesPerFrame = 576) or (SamplesPerFrame = 1152),
      'M24 SamplesPerFrame is 576 or 1152');

  finally
    Decoder.Free;
    Stream.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

begin
  WriteLn('========================================');
  WriteLn(' mp3-decoder unit tests');
  WriteLn('========================================');
  WriteLn;

  var SamplePath := ExpandFileName(
    ExtractFilePath(ParamStr(0)) + '..\..\..\..\samples\file_7461.mp3');

  TestBitStream;
  TestHdrValid;
  TestSampleRate;
  TestBitrateKbps;
  TestFrameBytes;
  TestFrameSamples;
  TestIsMono;
  TestSideInfoSize;
  TestPow43;
  TestMpegVersionFlags;
  TestPaddingFlag;
  TestGetLayer;
  TestGetBitrate;
  TestParseHeaderRealFile(SamplePath);
  TestDecodeRealFile(SamplePath);

  WriteLn;
  WriteLn('========================================');
  WriteLn(Format(' Results: %d passed, %d failed', [GPass, GFail]));
  WriteLn('========================================');

  if GFail > 0 then
    Halt(1);
end.
