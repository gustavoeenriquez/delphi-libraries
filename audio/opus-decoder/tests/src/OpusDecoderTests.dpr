program OpusDecoderTests;

{
  OpusDecoderTests.dpr - Tests for opus-decoder

  Unit level:
    O01-O02  TOC byte and packet framing (codes 0-3, padding, invalid packets)
    O03      Range decoder: raw bits from the end of the buffer, ec_tell
    O04      PVQ enumeration: V(N,K) and the pulse vectors of every index
    O05      Bit-exact helpers (isqrt32, bitexact_cos) and SILK fixed-point math
    O06      SILK NLSF -> LPC conversion yields stable filters
  Integration (real files produced by libopus via ffmpeg, in ../samples):
    O07      CELT stereo 20 ms, O08 CELT 2.5 ms, O09 CELT mono tone (440 Hz)
    O10      SILK-only WB mono: bit-exact with libopus 1.5.2 (CRC32 of int16 output)
    O11      Hybrid stereo 20 ms, O12 hybrid 60 ms (3 frames per packet)
    O13      Packet loss concealment keeps running (SILK and CELT)

  Reference values (sample counts, RMS, CRC) were measured with libopus 1.5.2.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  SysUtils, Math, Classes,
  AudioTypes,
  OggTypes,
  OggPageReader,
  OpusTypes,
  OpusEntDec,
  OpusCeltMath,
  OpusSilkMath,
  OpusDecoder;

var
  Passed, Failed: Integer;

procedure Check(Cond: Boolean; const Name: string);
begin
  if Cond then begin WriteLn('  PASS: ', Name); Inc(Passed); end
  else         begin WriteLn('  FAIL: ', Name); Inc(Failed); end;
end;

procedure CheckNear(A, B, Eps: Double; const Name: string);
begin
  Check(Abs(A - B) <= Eps, Name + Format(' (%.6g vs %.6g)', [A, B]));
end;

function SamplesDir: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + '..\..\..\..\samples\';
end;

// ---------------------------------------------------------------------------
// O01-O02 packet format
// ---------------------------------------------------------------------------

procedure TestO01_TOC;
var
  T: TOpusTOC;
begin
  WriteLn('O01: TOC byte');
  OpusParseTOC($F8 or $04 or 0, T);   // config 31, stereo, code 0
  Check((T.Config = 31) and T.Stereo and (T.Code = 0), 'config 31 stereo code 0');
  Check((T.Mode = OPUS_MODE_CELT) and (T.Bandwidth = OPUS_BW_FULLBAND) and (T.FrameSamples = 960), 'CELT FB 20 ms');
  OpusParseTOC(16 shl 3, T);
  Check((T.Mode = OPUS_MODE_CELT) and (T.Bandwidth = OPUS_BW_NARROWBAND) and (T.FrameSamples = 120), 'CELT NB 2.5 ms');
  OpusParseTOC(9 shl 3, T);
  Check((T.Mode = OPUS_MODE_SILK) and (T.Bandwidth = OPUS_BW_WIDEBAND) and (T.FrameSamples = 960), 'SILK WB 20 ms');
  OpusParseTOC(3 shl 3, T);
  Check((T.Mode = OPUS_MODE_SILK) and (T.FrameSamples = 2880), 'SILK NB 60 ms');
  OpusParseTOC(13 shl 3, T);
  Check((T.Mode = OPUS_MODE_HYBRID) and (T.Bandwidth = OPUS_BW_SUPERWIDEBAND) and (T.FrameSamples = 960), 'Hybrid SWB 20 ms');
  OpusParseTOC(14 shl 3, T);
  Check((T.Mode = OPUS_MODE_HYBRID) and (T.Bandwidth = OPUS_BW_FULLBAND) and (T.FrameSamples = 480), 'Hybrid FB 10 ms');
end;

procedure TestO02_Packets;
var
  P   : TBytes;
  Info: TOpusPacketInfo;
begin
  WriteLn('O02: packet framing');
  // code 0: one frame
  P := TBytes.Create($F8, 1, 2, 3);
  Check(OpusParsePacket(@P[0], 4, Info) and (Info.NumFrames = 1) and (Info.FrameSizes[0] = 3) and (Info.FrameOffsets[0] = 1), 'code 0');
  // code 1: two equal frames
  P := TBytes.Create($F9, 1, 2, 3, 4);
  Check(OpusParsePacket(@P[0], 5, Info) and (Info.NumFrames = 2) and (Info.FrameSizes[0] = 2) and (Info.FrameSizes[1] = 2)
        and (Info.FrameOffsets[1] = 3), 'code 1');
  P := TBytes.Create($F9, 1, 2, 3);
  Check(not OpusParsePacket(@P[0], 4, Info), 'code 1 odd payload rejected');
  // code 2: two frames, first size 1
  P := TBytes.Create($FA, 1, 9, 8, 7);
  Check(OpusParsePacket(@P[0], 5, Info) and (Info.NumFrames = 2) and (Info.FrameSizes[0] = 1) and (Info.FrameSizes[1] = 2)
        and (Info.FrameOffsets[0] = 2) and (Info.FrameOffsets[1] = 3), 'code 2');
  // code 2 with two-byte size: 252 + 4*1 = 256 -> payload too short
  P := TBytes.Create($FA, 252, 1, 0);
  Check(not OpusParsePacket(@P[0], 4, Info), 'code 2 size larger than packet rejected');
  // code 3 CBR, 3 frames of 2 bytes
  P := TBytes.Create($FB, 3, 1, 2, 3, 4, 5, 6);
  Check(OpusParsePacket(@P[0], 8, Info) and (Info.NumFrames = 3) and (Info.FrameSizes[2] = 2) and (Info.FrameOffsets[2] = 6), 'code 3 CBR');
  // code 3 VBR with padding: v=1 p=1 count=2; pad byte 1; sizes: 1 ; frames 'A' then 2 bytes; 1 pad byte
  P := TBytes.Create($FB, $C0 or 2, 1, 1, $41, $42, $43, $00);
  Check(OpusParsePacket(@P[0], 8, Info) and (Info.NumFrames = 2) and (Info.Padding = 1) and
        (Info.FrameSizes[0] = 1) and (Info.FrameSizes[1] = 2) and (Info.FrameOffsets[0] = 4) and (Info.FrameOffsets[1] = 5), 'code 3 VBR + padding');
  // code 3 with 255 padding continuation: 255 adds 254 then next byte
  P := TBytes.Create($FB, $40 or 1, 255, 0);
  Check(not OpusParsePacket(@P[0], 4, Info), 'padding longer than packet rejected');
  P := TBytes.Create($FB, 0);
  Check(not OpusParsePacket(@P[0], 2, Info), 'zero frames rejected');
  P := TBytes.Create($1B, 49);  // SILK NB 60 ms x 49 frames > 120 ms
  Check(not OpusParsePacket(@P[0], 2, Info), 'more than 120 ms rejected');
end;

// ---------------------------------------------------------------------------
// O03 range decoder
// ---------------------------------------------------------------------------

procedure TestO03_RangeDecoder;
var
  Buf: array[0..7] of Byte;
  D  : TEcDec;
  V  : Cardinal;
begin
  WriteLn('O03: range decoder raw bits and ec_tell');
  FillChar(Buf, SizeOf(Buf), 0);
  Buf[7] := $AB; Buf[6] := $CD;
  EcDecInit(D, @Buf[0], 8);
  Check(EcTell(D) = 1, Format('ec_tell after init = 1 (got %d)', [EcTell(D)]));
  V := EcDecBits(D, 8);
  Check(V = $AB, Format('raw bits read from the end: $%X', [V]));
  V := EcDecBits(D, 4);
  Check(V = $D, Format('next 4 raw bits: $%X', [V]));
  Check(EcTell(D) = 13, 'ec_tell counts raw bits');
  // A zero buffer decodes symbol 0 for a uniform 2-symbol icdf
  EcDecInit(D, @Buf[0], 8);
  V := EcDecBitLogp(D, 1);
  Check(V = 0, 'bit_logp on zero data = 0');
  Check(EcDecUInt(D, 100) = 0, 'dec_uint on zero data = 0');
  Check(D.Error = 0, 'no decoder error');
end;

// ---------------------------------------------------------------------------
// O04 PVQ enumeration
// ---------------------------------------------------------------------------

procedure TestO04_Cwrs;
var
  N, K, I, J, Sum: Integer;
  V: Cardinal;
  Y: array[0..15] of Integer;
  OK: Boolean;
  Seen: TArray<string>;
  S: string;
begin
  WriteLn('O04: PVQ V(N,K) and cwrsi');
  Check(CeltPvqV(2, 1) = 4,    'V(2,1) = 4');
  Check(CeltPvqV(3, 2) = 18,   'V(3,2) = 18');
  Check(CeltPvqV(4, 3) = 88,   'V(4,3) = 88');
  Check(CeltPvqV(5, 4) = 450,  'V(5,4) = 450');
  Check(CeltPvqV(8, 8) = 157184, 'V(8,8) = 157184');
  N := 4; K := 3; V := CeltPvqV(N, K);
  OK := True;
  SetLength(Seen, 0);
  for I := 0 to Integer(V) - 1 do
  begin
    CeltCwrsi(N, K, Cardinal(I), @Y[0]);
    Sum := 0; S := '';
    for J := 0 to N - 1 do begin Sum := Sum + Abs(Y[J]); S := S + IntToStr(Y[J]) + ','; end;
    if Sum <> K then OK := False;
    for J := 0 to High(Seen) do if Seen[J] = S then OK := False;
    SetLength(Seen, Length(Seen) + 1); Seen[High(Seen)] := S;
  end;
  Check(OK, 'all 88 indices of V(4,3) give distinct vectors with 3 pulses');
  CeltCwrsi(2, 1, 0, @Y[0]);
  Check((Y[0] = 1) and (Y[1] = 0), 'cwrsi(2,1,0) = (1,0)');
  CeltCwrsi(2, 1, 1, @Y[0]);
  Check((Y[0] = 0) and (Y[1] = 1), 'cwrsi(2,1,1) = (0,1)');
  CeltCwrsi(2, 1, 3, @Y[0]);
  Check((Y[0] = -1) and (Y[1] = 0), 'cwrsi(2,1,3) = (-1,0)');
end;

// ---------------------------------------------------------------------------
// O05 helpers
// ---------------------------------------------------------------------------

procedure TestO05_Math;
var
  X: Integer;
  OK: Boolean;
begin
  WriteLn('O05: bit-exact helpers');
  Check(ISqrt32(1000000) = 1000, 'isqrt32(1e6) = 1000');
  Check(ISqrt32(4294967295) = 65535, 'isqrt32(2^32-1) = 65535');
  Check(ISqrt32(2) = 1, 'isqrt32(2) = 1');
  Check(Abs(BitexactCos(8192) - 23170) < 60, Format('bitexact_cos(8192) ~ 23170 (got %d)', [BitexactCos(8192)]));
  Check(Abs(BitexactCos(16383)) < 60, Format('bitexact_cos(16383) ~ 0 (got %d)', [BitexactCos(16383)]));
  Check(Sar32(-8, 2) = -2, 'arithmetic shift of negative');
  Check(Sar32(-1, 31) = -1, 'arithmetic shift keeps sign');
  Check(SilkRShiftRound(-5, 1) = -2, 'RSHIFT_ROUND(-5,1) = -2');
  Check(SilkRShiftRound(7, 2) = 2, 'RSHIFT_ROUND(7,2) = 2');
  Check(SilkSMULWB(65536, -3) = -3, 'SMULWB');
  Check(SilkSMULWW(1 shl 20, 1 shl 20) = 1 shl 24, 'SMULWW');
  Check(SilkCLZ32(1) = 31, 'CLZ32(1) = 31');
  Check(SilkCLZ32(0) = 32, 'CLZ32(0) = 32');
  Check(SilkCLZ32(-1) = 0, 'CLZ32(-1) = 0');
  OK := True;
  for X := 1 to 2000 do
    if Abs(SilkLog2Lin(SilkLin2Log(X * 1000)) - X * 1000) > X * 1000 * 3 div 100 + 2 then OK := False;
  Check(OK, 'log2lin(lin2log(x)) within 3% (piecewise approximation, max 2.2%)');
  Check(Abs(SilkSqrtApprox(1 shl 20) - 1024) <= 26, Format('sqrt_approx(2^20) ~ 1024 (got %d)', [SilkSqrtApprox(1 shl 20)]));
  Check(SilkLog2Lin(3967) = SILK_INT32_MAX, 'log2lin saturates');
end;

// ---------------------------------------------------------------------------
// O06 NLSF2A
// ---------------------------------------------------------------------------

procedure TestO06_NLSF2A;
var
  NLSF: array[0..15] of SmallInt;
  A: array[0..15] of SmallInt;
  I, T, Order: Integer;
  OK: Boolean;
begin
  WriteLn('O06: NLSF2A produces stable LPC filters');
  OK := True;
  RandSeed := 7;
  for T := 0 to 199 do
  begin
    if Odd(T) then Order := 16 else Order := 10;
    for I := 0 to Order - 1 do
      NLSF[I] := SmallInt((I + 1) * 32768 div (Order + 1) + Random(600) - 300);
    SilkNLSF2A(@A[0], @NLSF[0], Order);
    if SilkLPCInversePredGain(@A[0], Order) = 0 then OK := False;
  end;
  Check(OK, '200 random NLSF vectors -> stable (inverse prediction gain > 0)');
  // Evenly spaced NLSFs give a nearly flat filter (small coefficients)
  for I := 0 to 15 do NLSF[I] := SmallInt((I + 1) * 32768 div 17);
  SilkNLSF2A(@A[0], @NLSF[0], 16);
  OK := True;
  for I := 0 to 15 do if Abs(A[I]) > 400 then OK := False;
  Check(OK, 'evenly spaced NLSFs -> near-flat filter');
end;

// ---------------------------------------------------------------------------
// Integration helpers
// ---------------------------------------------------------------------------

type
  TDecodeStats = record
    Frames   : Int64;
    Channels : Integer;
    RMS      : array[0..1] of Double;
    CRC      : Cardinal;      // CRC32 of the interleaved int16 output
    Goertzel : Double;
    Errors   : Integer;
    MaxAbs   : Double;
  end;

var
  CrcTable: array[0..255] of Cardinal;

procedure InitCrc;
var
  I, J: Integer;
  C: Cardinal;
begin
  for I := 0 to 255 do
  begin
    C := I;
    for J := 0 to 7 do
      if (C and 1) <> 0 then C := $EDB88320 xor (C shr 1) else C := C shr 1;
    CrcTable[I] := C;
  end;
end;

function DecodeFile(const FileName: string; TargetHz: Double; out St: TDecodeStats;
  LoseEvery: Integer = 0): Boolean;
var
  FS     : TFileStream;
  Dec    : TOpusDecoder;
  Buf    : TAudioBuffer;
  Samples: Integer;
  R      : TAudioDecodeResult;
  Ch, I  : Integer;
  SumSq  : array[0..1] of Double;
  Coef, S0, S1, S2, Total: Double;
  V      : Integer;
  Crc    : Cardinal;
  B      : Byte;
begin
  Result := False;
  St := Default(TDecodeStats);
  if not FileExists(FileName) then Exit;
  SumSq[0] := 0; SumSq[1] := 0;
  S1 := 0; S2 := 0; Total := 0;
  Coef := 2 * Cos(2 * Pi * TargetHz / 48000);
  Crc := $FFFFFFFF;
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  Dec := TOpusDecoder.Create(FS, False);
  try
    if not Dec.Ready then Exit;
    St.Channels := Dec.Channels;
    repeat
      R := Dec.Decode(Buf, Samples);
      if R = adrEndOfStream then Break;
      if R <> adrOK then begin Inc(St.Errors); Continue; end;
      for I := 0 to Samples - 1 do
      begin
        for Ch := 0 to St.Channels - 1 do
        begin
          SumSq[Ch] := SumSq[Ch] + Sqr(Buf[Ch][I]);
          if Abs(Buf[Ch][I]) > St.MaxAbs then St.MaxAbs := Abs(Buf[Ch][I]);
          V := Round(Buf[Ch][I] * 32768);
          if V > 32767 then V := 32767 else if V < -32768 then V := -32768;
          B := Byte(V and $FF);        Crc := CrcTable[(Crc xor B) and $FF] xor (Crc shr 8);
          B := Byte((V shr 8) and $FF); Crc := CrcTable[(Crc xor B) and $FF] xor (Crc shr 8);
        end;
        S0 := Buf[0][I] + Coef * S1 - S2;
        S2 := S1; S1 := S0;
        Total := Total + Sqr(Buf[0][I]);
      end;
      Inc(St.Frames, Samples);
    until False;
  finally
    Dec.Free;
    FS.Free;
  end;
  if St.Frames = 0 then Exit;
  for Ch := 0 to St.Channels - 1 do
    St.RMS[Ch] := Sqrt(SumSq[Ch] / St.Frames);
  St.CRC := Crc xor $FFFFFFFF;
  St.Goertzel := (Sqr(S1) + Sqr(S2) - Coef * S1 * S2) / (St.Frames * 0.5) / Max(Total, 1e-20);
  Result := True;
end;

procedure IntegrationTest(const Id, FileName: string; Channels: Integer; Frames: Int64;
  RMS: Double; const CRCHex: string; TargetHz: Double);
var
  St: TDecodeStats;
  Ch: Integer;
begin
  WriteLn(Id, ': ', FileName);
  if not DecodeFile(SamplesDir + FileName, TargetHz, St) then
  begin
    Check(False, 'decode failed or sample missing');
    Exit;
  end;
  Check(St.Errors = 0, 'no packet errors');
  Check(St.Channels = Channels, Format('%d channel(s)', [Channels]));
  Check(St.Frames = Frames, Format('%d frames (got %d)', [Frames, St.Frames]));
  for Ch := 0 to Channels - 1 do
    CheckNear(St.RMS[Ch], RMS, RMS * 0.01, Format('RMS ch%d within 1%% of libopus', [Ch]));
  if CRCHex <> '' then
    Check(IntToHex(St.CRC, 8) = CRCHex, Format('bit-exact with libopus 1.5.2 (CRC32 %s, expected %s)', [IntToHex(St.CRC, 8), CRCHex]));
  if TargetHz > 0 then
    Check(St.Goertzel > 0.98, Format('energy concentrated at %.0f Hz (%.3f)', [TargetHz, St.Goertzel]));
end;

procedure TestO13_PacketLoss;
var
  FS     : TFileStream;
  Rd     : TOggPageReader;
  Pkt    : TOggPacket;
  Dec    : TOpusStreamDecoder;
  Buf    : TAudioBuffer;
  N, Ret, I, Ch: Integer;
  OK     : Boolean;
  FN     : string;
  MaxAbs : Single;
  Total  : Integer;
begin
  WriteLn('O13: packet loss concealment (every 5th packet lost)');
  for FN in [SamplesDir + 'speech_48k_mono_silk_wb20k.opus', SamplesDir + 'speech_48k_stereo_celt96k.opus'] do
  begin
    if not FileExists(FN) then begin Check(False, 'sample missing'); Continue; end;
    FS := TFileStream.Create(FN, fmOpenRead or fmShareDenyWrite);
    Rd := TOggPageReader.Create(FS, False);
    Dec := nil;
    try
      N := 0; OK := True; MaxAbs := 0; Total := 0;
      while Rd.ReadPacket(Pkt) = orrPacket do
      begin
        Inc(N);
        if N = 1 then begin Dec := TOpusStreamDecoder.Create(Pkt.Data[9]); Continue; end;
        if N = 2 then Continue;
        if (N mod 5) = 0 then
          Ret := Dec.DecodeLost(960, Buf)
        else
          Ret := Dec.DecodePacket(@Pkt.Data[0], Pkt.Length, Buf);
        if Ret <= 0 then OK := False
        else
        begin
          Inc(Total, Ret);
          for Ch := 0 to Dec.Channels - 1 do
            for I := 0 to Ret - 1 do
            begin
              if IsNan(Buf[Ch][I]) then OK := False;
              if Abs(Buf[Ch][I]) > MaxAbs then MaxAbs := Abs(Buf[Ch][I]);
            end;
        end;
      end;
      Check(OK, ExtractFileName(FN) + ': all packets decoded or concealed');
      Check(Total = (N - 2) * 960, ExtractFileName(FN) + ': output length preserved');
      Check((MaxAbs > 0.01) and (MaxAbs <= 1.0), ExtractFileName(FN) + Format(': output level sane (max %.3f)', [MaxAbs]));
    finally
      Dec.Free; Rd.Free; FS.Free;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
begin
  Passed := 0;
  Failed := 0;
  InitCrc;
  WriteLn('=== Opus Decoder Tests ===');
  WriteLn;

  TestO01_TOC;
  TestO02_Packets;
  TestO03_RangeDecoder;
  TestO04_Cwrs;
  TestO05_Math;
  TestO06_NLSF2A;
  IntegrationTest('O07', 'speech_48k_stereo_celt96k.opus', 2, 190080, 0.07069, '', 0);
  IntegrationTest('O08', 'speech_48k_stereo_celt2_5ms_64k.opus', 2, 190080, 0.07291, '', 0);
  IntegrationTest('O09', 'tone440_44k_mono_celt64k.opus', 1, 144000, 0.04423, '', 440);
  IntegrationTest('O10', 'speech_48k_mono_silk_wb20k.opus', 1, 190080, 0.06776, 'F6D84F2B', 0);
  IntegrationTest('O11', 'speech_48k_stereo_silk32k.opus', 2, 190080, 0.06886, '', 0);
  IntegrationTest('O12', 'speech_48k_stereo_hybrid60ms_48k.opus', 2, 190080, 0.06935, '', 0);
  TestO13_PacketLoss;

  WriteLn;
  WriteLn(Format('Results: %d passed, %d failed', [Passed, Failed]));
  if Failed = 0 then
    WriteLn('All tests PASSED.')
  else
    WriteLn('Some tests FAILED.');
  WriteLn;
  ExitCode := Failed;
end.
