program OpusEncoderTests;

{
  OpusEncoderTests.dpr - Exhaustive tests for opus-encoder

  Test layers:
    E01-E08: OpusEncTypes  - config init, TOC config lookup, TOC byte build
    E09-E25: OpusRangeEncoder - init state, ICDF encode, UInt encode, bit encode,
                                raw bits, flush output, round-trip vs decoder

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$APPTYPE CONSOLE}

uses
  SysUtils, Math,
  OpusTypes,
  OpusEncTypes,
  OpusRangeEncoder,
  OpusRangeDecoder;

var
  Passed, Failed: Integer;

procedure Check(Cond: Boolean; const Name: string);
begin
  if Cond then begin WriteLn('  PASS: ', Name); Inc(Passed); end
  else          begin WriteLn('  FAIL: ', Name); Inc(Failed); end;
end;

procedure CheckNear(A, B, Eps: Double; const Name: string);
begin
  Check(Abs(A - B) <= Eps, Name + Format(' (%.8f vs %.8f)', [A, B]));
end;

// ===========================================================================
// E01: OpusEncConfigInit defaults
// ===========================================================================
procedure TestE01_ConfigDefaults;
var
  Cfg: TOpusEncConfig;
begin
  WriteLn('E01: OpusEncConfigInit defaults');
  OpusEncConfigInit(Cfg, 2, 48000);
  Check(Cfg.Channels = 2,                      'Channels = 2');
  Check(Cfg.SampleRate = 48000,                'SampleRate = 48000');
  Check(Cfg.Bitrate = OPUS_ENC_BITRATE_DEFAULT,'Bitrate = 96000');
  Check(Cfg.Complexity = OPUS_ENC_COMPLEXITY_DEFAULT, 'Complexity = 5');
  CheckNear(Cfg.FrameSizeMs, 20.0, 0.001,      'FrameSizeMs = 20');
  Check(Cfg.Mode = -1,                         'Mode = auto (-1)');
  Check(Cfg.Bandwidth = -1,                    'Bandwidth = auto (-1)');
end;

// ===========================================================================
// E02: OpusEncConfigInit mono 8 kHz
// ===========================================================================
procedure TestE02_ConfigMono8k;
var
  Cfg: TOpusEncConfig;
begin
  WriteLn('E02: OpusEncConfigInit mono 8 kHz');
  OpusEncConfigInit(Cfg, 1, 8000);
  Check(Cfg.Channels = 1,   'Channels = 1');
  Check(Cfg.SampleRate = 8000, 'SampleRate = 8000');
end;

// ===========================================================================
// E03: OpusEncTOCConfig - CELT FB 20ms
// ===========================================================================
procedure TestE03_TOCConfigCeltFB20;
var
  C: Integer;
begin
  WriteLn('E03: TOCConfig CELT FB 20ms');
  C := OpusEncTOCConfig(OPUS_MODE_CELT, OPUS_BW_FULLBAND, 20.0);
  Check(C = 31, Format('Config = 31 (got %d)', [C]));
end;

// ===========================================================================
// E04: OpusEncTOCConfig - SILK NB 40ms
// ===========================================================================
procedure TestE04_TOCConfigSilkNB40;
var
  C: Integer;
begin
  WriteLn('E04: TOCConfig SILK NB 40ms');
  C := OpusEncTOCConfig(OPUS_MODE_SILK, OPUS_BW_NARROWBAND, 40.0);
  Check(C = 2, Format('Config = 2 (got %d)', [C]));
end;

// ===========================================================================
// E05: OpusEncTOCConfig - Hybrid SWB 10ms
// ===========================================================================
procedure TestE05_TOCConfigHybridSWB10;
var
  C: Integer;
begin
  WriteLn('E05: TOCConfig Hybrid SWB 10ms');
  C := OpusEncTOCConfig(OPUS_MODE_HYBRID, OPUS_BW_SUPERWIDEBAND, 10.0);
  Check(C = 12, Format('Config = 12 (got %d)', [C]));
end;

// ===========================================================================
// E06: OpusEncTOCConfig - invalid combination
// ===========================================================================
procedure TestE06_TOCConfigInvalid;
var
  C: Integer;
begin
  WriteLn('E06: TOCConfig invalid combination');
  // SILK with FULLBAND does not exist in the spec
  C := OpusEncTOCConfig(OPUS_MODE_SILK, OPUS_BW_FULLBAND, 20.0);
  Check(C = -1, Format('Config = -1 for invalid (got %d)', [C]));
end;

// ===========================================================================
// E07: OpusEncTOCByte - build TOC byte
// ===========================================================================
procedure TestE07_TOCByte;
var
  B: Byte;
  TOC: TOpusTOC;
begin
  WriteLn('E07: OpusEncTOCByte round-trip');
  // CELT FB 20ms (config=31), stereo, code=0
  B := OpusEncTOCByte(31, True, 0);
  OpusParseTOC(B, TOC);
  Check(TOC.Config = 31,              'Round-trip Config = 31');
  Check(TOC.Stereo,                   'Round-trip Stereo = True');
  Check(TOC.Code = 0,                 'Round-trip Code = 0');
  Check(TOC.Mode = OPUS_MODE_CELT,    'Round-trip Mode = CELT');
  Check(TOC.Bandwidth = OPUS_BW_FULLBAND, 'Round-trip BW = FB');
end;

// ===========================================================================
// E08: OpusEncTOCByte - SILK NB 10ms stereo code=1
// ===========================================================================
procedure TestE08_TOCByteSilk;
var
  B: Byte;
  TOC: TOpusTOC;
begin
  WriteLn('E08: OpusEncTOCByte SILK NB 10ms stereo code=1');
  B := OpusEncTOCByte(0, True, 1);   // config=0: SILK NB 10ms
  OpusParseTOC(B, TOC);
  Check(TOC.Config = 0,              'Config = 0');
  Check(TOC.Stereo,                  'Stereo = True');
  Check(TOC.Code = 1,                'Code = 1');
  Check(TOC.Mode = OPUS_MODE_SILK,   'Mode = SILK');
end;

// ===========================================================================
// E09: ReInit - initial state invariants
// ===========================================================================
procedure TestE09_ReInitState;
var
  Re : TOpusRangeEncoder;
  Buf: array[0..63] of Byte;
begin
  WriteLn('E09: ReInit initial state');
  ReInit(Re, @Buf[0], 64);
  Check(Re.Rng = $80000000, Format('Rng = $80000000 (got $%x)', [Re.Rng]));
  Check(Re.Val = 0,         'Val = 0');
  Check(Re.Rem = -1,        'Rem = -1 (sentinel)');
  Check(Re.Ext = 0,         'Ext = 0');
  Check(Re.Offs = 0,        'Offs = 0');
  Check(Re.EndOffs = 0,     'EndOffs = 0');
  Check(Re.NBitsTotal = 33, 'NBitsTotal = 33');
  Check(not Re.Error,       'Error = False');
end;

// ===========================================================================
// E10: ReTell after init = 1 (33 - log2($80000000)=31 → 33-32=1)
// ===========================================================================
procedure TestE10_TellAfterInit;
var
  Re : TOpusRangeEncoder;
  Buf: array[0..63] of Byte;
begin
  WriteLn('E10: ReTell after init = 1');
  ReInit(Re, @Buf[0], 64);
  Check(ReTell(Re) = 1, Format('ReTell = 1 (got %d)', [ReTell(Re)]));
end;

// ===========================================================================
// E11: ReFlush empty encoder produces 0 bytes or 1 zero byte
// ===========================================================================
procedure TestE11_FlushEmpty;
var
  Re  : TOpusRangeEncoder;
  Buf : array[0..63] of Byte;
  Len : Integer;
begin
  WriteLn('E11: ReFlush empty encoder');
  FillChar(Buf, SizeOf(Buf), $AA);
  ReInit(Re, @Buf[0], 64);
  Len := ReFlush(Re);
  Check(Len >= 0,       Format('Len >= 0 (got %d)', [Len]));
  Check(not Re.Error,   'No overflow error');
end;

// ===========================================================================
// E12: ReEncodeICDF single symbol (only 1 choice) - no bits consumed
// ===========================================================================
procedure TestE12_EncodeICDFSingleSymbol;
var
  Re  : TOpusRangeEncoder;
  Buf : array[0..63] of Byte;
const
  // Only 1 symbol: ICDF[0]=1<<8=256→stored as 0 because table is byte-scaled
  // Actually single-symbol ICDF: ICDF = [0] meaning prob[0] = FT = 256.
  // ICDF[0] must be 0 (FT - FT = 0), representing 100% probability.
  ICDF1: array[0..0] of Byte = (0);
begin
  WriteLn('E12: ReEncodeICDF single-symbol (trivial)');
  ReInit(Re, @Buf[0], 64);
  // Sym=0, ICDF[0]=0, FTBits=8: Rng -= (Rng>>8)*0 → Rng unchanged
  ReEncodeICDF(Re, 0, ICDF1, 8);
  Check(not Re.Error, 'No error after trivial encode');
  // Rng should still be $80000000 (no bits consumed)
  Check(Re.Rng = $80000000, Format('Rng unchanged (got $%x)', [Re.Rng]));
end;

// ===========================================================================
// E13: ReEncodeICDF + decoder round-trip — 2-symbol equiprobable
// ===========================================================================
procedure TestE13_ICDFRoundTrip2Sym;
var
  Re  : TOpusRangeEncoder;
  Rd  : TOpusRangeDecoder;
  Buf : array[0..63] of Byte;
  Len : Integer;
  Got : Integer;
const
  ICDF2: array[0..1] of Byte = (128, 0);  // 50/50 split, FT=256
begin
  WriteLn('E13: ICDF 2-symbol round-trip (sym=1)');
  FillChar(Buf, SizeOf(Buf), 0);
  ReInit(Re, @Buf[0], 64);
  ReEncodeICDF(Re, 1, ICDF2, 8);  // encode symbol 1
  Len := ReFlush(Re);
  Check(Len > 0, Format('Flushed %d bytes', [Len]));
  // Decode it back
  RdInit(Rd, @Buf[0], Len);
  Got := RdDecodeICDF(Rd, ICDF2, 8);
  Check(Got = 1, Format('Decoded = 1 (got %d)', [Got]));
  Check(not Rd.Error, 'Decoder no error');
end;

// ===========================================================================
// E14: ICDF round-trip — 4 symbols, encode sym=2
// ===========================================================================
procedure TestE14_ICDFRoundTrip4Sym;
var
  Re  : TOpusRangeEncoder;
  Rd  : TOpusRangeDecoder;
  Buf : array[0..63] of Byte;
  Len : Integer;
  Got : Integer;
const
  // 4 equiprobable symbols (64 each), FT=256
  ICDF4: array[0..3] of Byte = (192, 128, 64, 0);
begin
  WriteLn('E14: ICDF 4-symbol round-trip (sym=2)');
  FillChar(Buf, SizeOf(Buf), 0);
  ReInit(Re, @Buf[0], 64);
  ReEncodeICDF(Re, 2, ICDF4, 8);
  Len := ReFlush(Re);
  RdInit(Rd, @Buf[0], Len);
  Got := RdDecodeICDF(Rd, ICDF4, 8);
  Check(Got = 2, Format('Decoded = 2 (got %d)', [Got]));
end;

// ===========================================================================
// E15: ICDF round-trip — encode all 4 symbols in sequence
// ===========================================================================
procedure TestE15_ICDFMultiSymbol;
var
  Re  : TOpusRangeEncoder;
  Rd  : TOpusRangeDecoder;
  Buf : array[0..63] of Byte;
  Len, I: Integer;
  Syms: array[0..3] of Integer;
const
  ICDF4: array[0..3] of Byte = (192, 128, 64, 0);
begin
  WriteLn('E15: ICDF encode 4 symbols in sequence, decode all');
  FillChar(Buf, SizeOf(Buf), 0);
  ReInit(Re, @Buf[0], 64);
  for I := 0 to 3 do
    ReEncodeICDF(Re, I, ICDF4, 8);
  Len := ReFlush(Re);
  RdInit(Rd, @Buf[0], Len);
  for I := 0 to 3 do
    Syms[I] := RdDecodeICDF(Rd, ICDF4, 8);
  Check(Syms[0] = 0, Format('Sym[0]=0 (got %d)', [Syms[0]]));
  Check(Syms[1] = 1, Format('Sym[1]=1 (got %d)', [Syms[1]]));
  Check(Syms[2] = 2, Format('Sym[2]=2 (got %d)', [Syms[2]]));
  Check(Syms[3] = 3, Format('Sym[3]=3 (got %d)', [Syms[3]]));
end;

// ===========================================================================
// E16: ReEncodeUInt round-trip — small value
// ===========================================================================
procedure TestE16_UIntSmall;
var
  Re  : TOpusRangeEncoder;
  Rd  : TOpusRangeDecoder;
  Buf : array[0..63] of Byte;
  Len : Integer;
  Got : Cardinal;
begin
  WriteLn('E16: ReEncodeUInt small value round-trip');
  FillChar(Buf, SizeOf(Buf), 0);
  ReInit(Re, @Buf[0], 64);
  ReEncodeUInt(Re, 5, 10);  // val=5 in [0,10)
  Len := ReFlush(Re);
  RdInit(Rd, @Buf[0], Len);
  Got := RdDecodeUInt(Rd, 10);
  Check(Got = 5, Format('Decoded = 5 (got %d)', [Got]));
end;

// ===========================================================================
// E17: ReEncodeUInt round-trip — val=0
// ===========================================================================
procedure TestE17_UIntZero;
var
  Re  : TOpusRangeEncoder;
  Rd  : TOpusRangeDecoder;
  Buf : array[0..63] of Byte;
  Len : Integer;
  Got : Cardinal;
begin
  WriteLn('E17: ReEncodeUInt val=0 round-trip');
  FillChar(Buf, SizeOf(Buf), 0);
  ReInit(Re, @Buf[0], 64);
  ReEncodeUInt(Re, 0, 16);
  Len := ReFlush(Re);
  RdInit(Rd, @Buf[0], Len);
  Got := RdDecodeUInt(Rd, 16);
  Check(Got = 0, Format('Decoded = 0 (got %d)', [Got]));
end;

// ===========================================================================
// E18: ReEncodeUInt round-trip — val=max-1
// ===========================================================================
procedure TestE18_UIntMax;
var
  Re  : TOpusRangeEncoder;
  Rd  : TOpusRangeDecoder;
  Buf : array[0..63] of Byte;
  Len : Integer;
  Got : Cardinal;
begin
  WriteLn('E18: ReEncodeUInt val=max-1 round-trip');
  FillChar(Buf, SizeOf(Buf), 0);
  ReInit(Re, @Buf[0], 64);
  ReEncodeUInt(Re, 15, 16);
  Len := ReFlush(Re);
  RdInit(Rd, @Buf[0], Len);
  Got := RdDecodeUInt(Rd, 16);
  Check(Got = 15, Format('Decoded = 15 (got %d)', [Got]));
end;

// ===========================================================================
// E19: ReEncodeUInt large FT (> 256, triggers high/low split)
// ===========================================================================
procedure TestE19_UIntLarge;
var
  Re  : TOpusRangeEncoder;
  Rd  : TOpusRangeDecoder;
  Buf : array[0..127] of Byte;
  Len : Integer;
  Got : Cardinal;
begin
  WriteLn('E19: ReEncodeUInt large FT=1000, val=777');
  FillChar(Buf, SizeOf(Buf), 0);
  ReInit(Re, @Buf[0], 128);
  ReEncodeUInt(Re, 777, 1000);
  Len := ReFlush(Re);
  // Raw bits for the low part land at the end of Storage, so pass full buffer
  RdInit(Rd, @Buf[0], SizeOf(Buf));
  Got := RdDecodeUInt(Rd, 1000);
  Check(Got = 777, Format('Decoded = 777 (got %d)', [Got]));
end;

// ===========================================================================
// E20: ReEncodeBit round-trip — bit=False, LogP=1
// ===========================================================================
procedure TestE20_BitFalse;
var
  Re  : TOpusRangeEncoder;
  Rd  : TOpusRangeDecoder;
  Buf : array[0..63] of Byte;
  Len : Integer;
begin
  WriteLn('E20: ReEncodeBit False (logp=1) round-trip');
  FillChar(Buf, SizeOf(Buf), 0);
  ReInit(Re, @Buf[0], 64);
  ReEncodeBit(Re, False, 1);
  Len := ReFlush(Re);
  RdInit(Rd, @Buf[0], Len);
  Check(not RdDecodeBit(Rd), 'Decoded = False');
end;

// ===========================================================================
// E21: ReEncodeBit round-trip — bit=True, LogP=1
// ===========================================================================
procedure TestE21_BitTrue;
var
  Re  : TOpusRangeEncoder;
  Rd  : TOpusRangeDecoder;
  Buf : array[0..63] of Byte;
  Len : Integer;
begin
  WriteLn('E21: ReEncodeBit True (logp=1) round-trip');
  FillChar(Buf, SizeOf(Buf), 0);
  ReInit(Re, @Buf[0], 64);
  ReEncodeBit(Re, True, 1);
  Len := ReFlush(Re);
  RdInit(Rd, @Buf[0], Len);
  Check(RdDecodeBit(Rd), 'Decoded = True');
end;

// ===========================================================================
// E22: ReEncodeRaw round-trip — 4 raw bits value=9
// ===========================================================================
procedure TestE22_RawBits;
var
  Re  : TOpusRangeEncoder;
  Rd  : TOpusRangeDecoder;
  Buf : array[0..63] of Byte;
  Len : Integer;
  Got : Cardinal;
begin
  WriteLn('E22: ReEncodeRaw 4 bits val=9 round-trip');
  FillChar(Buf, SizeOf(Buf), 0);
  ReInit(Re, @Buf[0], 64);
  ReEncodeRaw(Re, 9, 4);   // 9 = 1001b
  Len := ReFlush(Re);
  // Raw bits sit at end of Storage; pass full buffer so decoder can find them
  RdInit(Rd, @Buf[0], SizeOf(Buf));
  Got := RdDecodeRaw(Rd, 4);
  Check(Got = 9, Format('Raw decoded = 9 (got %d)', [Got]));
end;

// ===========================================================================
// E23: Mixed ICDF + raw bits round-trip
// ===========================================================================
procedure TestE23_MixedICDFAndRaw;
var
  Re   : TOpusRangeEncoder;
  Rd   : TOpusRangeDecoder;
  Buf  : array[0..127] of Byte;
  Len  : Integer;
  GSym : Integer;
  GRaw : Cardinal;
const
  ICDF4: array[0..3] of Byte = (192, 128, 64, 0);
begin
  WriteLn('E23: Mixed ICDF sym=3 + raw 5 bits val=21');
  FillChar(Buf, SizeOf(Buf), 0);
  ReInit(Re, @Buf[0], 128);
  ReEncodeICDF(Re, 3, ICDF4, 8);
  ReEncodeRaw(Re, 21, 5);
  Len := ReFlush(Re);
  // Raw bits at end of Storage; pass full buffer
  RdInit(Rd, @Buf[0], SizeOf(Buf));
  GSym := RdDecodeICDF(Rd, ICDF4, 8);
  GRaw := RdDecodeRaw(Rd, 5);
  Check(GSym = 3, Format('ICDF sym = 3 (got %d)', [GSym]));
  Check(GRaw = 21, Format('Raw = 21 (got %d)', [GRaw]));
end;

// ===========================================================================
// E24: ReTell grows after each symbol
// ===========================================================================
procedure TestE24_TellGrows;
var
  Re   : TOpusRangeEncoder;
  Buf  : array[0..127] of Byte;
  T0, T1, T2: Integer;
const
  ICDF2: array[0..1] of Byte = (128, 0);
begin
  WriteLn('E24: ReTell grows after encoding');
  ReInit(Re, @Buf[0], 128);
  T0 := ReTell(Re);
  ReEncodeICDF(Re, 0, ICDF2, 8);
  T1 := ReTell(Re);
  ReEncodeICDF(Re, 1, ICDF2, 8);
  T2 := ReTell(Re);
  Check(T1 > T0, Format('T1(%d) > T0(%d)', [T1, T0]));
  Check(T2 > T1, Format('T2(%d) > T1(%d)', [T2, T1]));
end;

// ===========================================================================
// E25: Stress — encode 16 uniform values [0,256), decode all back
// ===========================================================================
procedure TestE25_StressUInt16;
var
  Re   : TOpusRangeEncoder;
  Rd   : TOpusRangeDecoder;
  Buf  : array[0..255] of Byte;
  Len  : Integer;
  I    : Integer;
  Vals : array[0..15] of Cardinal;
  Got  : Cardinal;
  Ok   : Boolean;
begin
  WriteLn('E25: Stress — 16 uniform integers [0,256) round-trip');
  FillChar(Buf, SizeOf(Buf), 0);
  // Deterministic sequence
  Vals[0]:=0; Vals[1]:=1; Vals[2]:=7; Vals[3]:=42;
  Vals[4]:=64; Vals[5]:=100; Vals[6]:=127; Vals[7]:=128;
  Vals[8]:=129; Vals[9]:=200; Vals[10]:=210; Vals[11]:=220;
  Vals[12]:=230; Vals[13]:=240; Vals[14]:=250; Vals[15]:=255;
  ReInit(Re, @Buf[0], 256);
  for I := 0 to 15 do
    ReEncodeUInt(Re, Vals[I], 256);
  Len := ReFlush(Re);
  RdInit(Rd, @Buf[0], Len);
  Ok := True;
  for I := 0 to 15 do
  begin
    Got := RdDecodeUInt(Rd, 256);
    if Got <> Vals[I] then
    begin
      WriteLn(Format('    Mismatch at I=%d: expected %d got %d', [I, Vals[I], Got]));
      Ok := False;
    end;
  end;
  Check(Ok, 'All 16 values decoded correctly');
  Check(not Rd.Error, 'Decoder no error');
end;

// ===========================================================================
// Main
// ===========================================================================

begin
  Passed := 0; Failed := 0;
  WriteLn('=== Opus Encoder Tests — Phase 1 ===');
  WriteLn;

  WriteLn('--- OpusEncTypes ---');
  TestE01_ConfigDefaults;
  TestE02_ConfigMono8k;
  TestE03_TOCConfigCeltFB20;
  TestE04_TOCConfigSilkNB40;
  TestE05_TOCConfigHybridSWB10;
  TestE06_TOCConfigInvalid;
  TestE07_TOCByte;
  TestE08_TOCByteSilk;

  WriteLn;
  WriteLn('--- OpusRangeEncoder ---');
  TestE09_ReInitState;
  TestE10_TellAfterInit;
  TestE11_FlushEmpty;
  TestE12_EncodeICDFSingleSymbol;
  TestE13_ICDFRoundTrip2Sym;
  TestE14_ICDFRoundTrip4Sym;
  TestE15_ICDFMultiSymbol;
  TestE16_UIntSmall;
  TestE17_UIntZero;
  TestE18_UIntMax;
  TestE19_UIntLarge;
  TestE20_BitFalse;
  TestE21_BitTrue;
  TestE22_RawBits;
  TestE23_MixedICDFAndRaw;
  TestE24_TellGrows;
  TestE25_StressUInt16;

  WriteLn;
  WriteLn(Format('Results: %d passed, %d failed', [Passed, Failed]));
  if Failed > 0 then Halt(1);
end.
