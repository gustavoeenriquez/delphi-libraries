program VorbisDecoderTests;

{
  VorbisDecoderTests.dpr - Tests for vorbis-decoder

  Unit level (spec-derived expectations):
    V01-V03  VorbisTypes helpers: ilog, float32_unpack, lookup1_values
    V04-V08  Codebooks: codeword assignment (spec 3.2.1), decode, VQ type 1/2, long codes
    V09      Floor 1 render_point
    V10      IMDCT against the direct O(N^2) formula
    V11      Window slope is power complementary
    V12      Inverse channel coupling (all four sign cases)
    V13-V15  Header parsing and header sequence
    V19-V21  Error handling: over-subscribed codebook, truncated packet, Reset

  Integration (real files produced by libvorbis via ffmpeg, in ../samples):
    V16      Setup header of a real stream parses completely
    V17      440 Hz mono tone decodes to the right length, level and frequency
    V18      Stereo speech decodes to the right length and level

  Reference values were measured against ffmpeg's decoder (SNR > 99 dB).

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  SysUtils, Math, Classes,
  AudioBitReader,
  AudioCRC,
  AudioTypes,
  OggTypes,
  OggPageReader,
  VorbisTypes,
  VorbisCodebook,
  VorbisFloor,
  VorbisResidue,
  VorbisSetup,
  VorbisDecoder;

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
// Helpers: bit writer that emits codewords MSB-first into an LSB-first stream
// (the Vorbis convention: codeword bits are read one at a time, first bit first)
// ---------------------------------------------------------------------------

type
  TBitWriter = record
    Buf   : TBytes;
    BitPos: Integer;
    procedure Init(Bytes: Integer);
    procedure PutBit(B: Integer);
    procedure PutCode(const Code: string);      // e.g. '110'
    procedure PutValueLSB(V: Cardinal; N: Integer);
  end;

procedure TBitWriter.Init(Bytes: Integer);
begin
  SetLength(Buf, Bytes);
  FillChar(Buf[0], Bytes, 0);
  BitPos := 0;
end;

procedure TBitWriter.PutBit(B: Integer);
begin
  if B <> 0 then
    Buf[BitPos div 8] := Buf[BitPos div 8] or (1 shl (BitPos mod 8));
  Inc(BitPos);
end;

procedure TBitWriter.PutCode(const Code: string);
var
  I: Integer;
begin
  for I := 1 to Length(Code) do
    PutBit(Ord(Code[I] = '1'));
end;

procedure TBitWriter.PutValueLSB(V: Cardinal; N: Integer);
var
  I: Integer;
begin
  for I := 0 to N - 1 do
    PutBit((V shr I) and 1);
end;

procedure MakeCB(var CB: TVorbisCodebook; const Lengths: array of Byte; Dim: Integer = 1);
var
  I: Integer;
begin
  CB := Default(TVorbisCodebook);
  CB.Dimensions := Dim;
  CB.Entries    := Length(Lengths);
  CB.LookupType := VORBIS_LOOKUP_NONE;
  SetLength(CB.Lengths, Length(Lengths));
  for I := 0 to High(Lengths) do CB.Lengths[I] := Lengths[I];
end;

// Codeword of entry I as a string of '0'/'1' in transmission order
function CodeStr(const CB: TVorbisCodebook; I: Integer): string;
var
  K: Integer;
begin
  Result := '';
  for K := 0 to CB.Lengths[I] - 1 do
    Result := Result + Chr(Ord('0') + ((CB.Codewords[I] shr K) and 1));
end;

// ---------------------------------------------------------------------------
// V01-V03 helpers
// ---------------------------------------------------------------------------

procedure TestV01_ILog;
begin
  WriteLn('V01: VorbisILog');
  Check(VorbisILog(0) = 0, 'ilog(0) = 0');
  Check(VorbisILog(1) = 1, 'ilog(1) = 1');
  Check(VorbisILog(2) = 2, 'ilog(2) = 2');
  Check(VorbisILog(3) = 2, 'ilog(3) = 2');
  Check(VorbisILog(4) = 3, 'ilog(4) = 3');
  Check(VorbisILog(7) = 3, 'ilog(7) = 3');
  Check(VorbisILog(255) = 8, 'ilog(255) = 8');
  Check(VorbisILog(256) = 9, 'ilog(256) = 9');
end;

procedure TestV02_Float32Unpack;
var
  V: Cardinal;
begin
  WriteLn('V02: VorbisFloat32Unpack (spec 9.2.2: mantissa * 2^(exponent-788))');
  V := (788 shl 21) or 1;
  CheckNear(VorbisFloat32Unpack(V), 1.0, 1e-9, 'exp=788 mant=1 -> 1.0');
  V := (789 shl 21) or 3;
  CheckNear(VorbisFloat32Unpack(V), 6.0, 1e-9, 'exp=789 mant=3 -> 6.0');
  V := $80000000 or (788 shl 21) or 5;
  CheckNear(VorbisFloat32Unpack(V), -5.0, 1e-9, 'sign bit -> -5.0');
  V := (786 shl 21) or 1;
  CheckNear(VorbisFloat32Unpack(V), 0.25, 1e-9, 'exp=786 mant=1 -> 0.25');
  // Typical libvorbis delta value: raw 0x4A8C0000 area is not needed; check zero
  Check(VorbisFloat32Unpack(0) = 0.0, 'zero -> 0.0');
end;

procedure TestV03_Lookup1;
begin
  WriteLn('V03: VorbisLookup1Values');
  Check(VorbisLookup1Values(4, 2) = 2,     'lookup1(4,2) = 2');
  Check(VorbisLookup1Values(6561, 8) = 3,  'lookup1(6561,8) = 3');
  Check(VorbisLookup1Values(625, 4) = 5,   'lookup1(625,4) = 5');
  Check(VorbisLookup1Values(289, 2) = 17,  'lookup1(289,2) = 17');
  Check(VorbisLookup1Values(100, 2) = 10,  'lookup1(100,2) = 10');
  Check(VorbisLookup1Values(99, 2) = 9,    'lookup1(99,2) = 9');
end;

// ---------------------------------------------------------------------------
// V04-V08 codebooks
// ---------------------------------------------------------------------------

procedure TestV04_CodewordAssignment;
var
  CB: TVorbisCodebook;
begin
  WriteLn('V04: codeword assignment follows spec 3.2.1 (first available leaf)');
  MakeCB(CB, [1, 2, 3, 3]);
  Check(VorbisCodebookInit(CB), 'init [1,2,3,3]');
  Check(CodeStr(CB, 0) = '0',   'entry0 = 0');
  Check(CodeStr(CB, 1) = '10',  'entry1 = 10');
  Check(CodeStr(CB, 2) = '110', 'entry2 = 110');
  Check(CodeStr(CB, 3) = '111', 'entry3 = 111');
  Check(CB.HuffMinLen = 1, 'MinLen = 1');
  Check(CB.HuffMaxLen = 3, 'MaxLen = 3');

  // Not canonical-by-length: entry order decides
  MakeCB(CB, [2, 1, 2]);
  Check(VorbisCodebookInit(CB), 'init [2,1,2]');
  Check(CodeStr(CB, 0) = '00', 'entry0 (len2) = 00');
  Check(CodeStr(CB, 1) = '1',  'entry1 (len1) = 1');
  Check(CodeStr(CB, 2) = '01', 'entry2 (len2) = 01');

  // Spec example (section 3.2.1): lengths 2,4,4,4,4,2,3,3
  MakeCB(CB, [2, 4, 4, 4, 4, 2, 3, 3]);
  Check(VorbisCodebookInit(CB), 'init spec example');
  Check(CodeStr(CB, 0) = '00',   'spec entry0 = 00');
  Check(CodeStr(CB, 1) = '0100', 'spec entry1 = 0100');
  Check(CodeStr(CB, 2) = '0101', 'spec entry2 = 0101');
  Check(CodeStr(CB, 3) = '0110', 'spec entry3 = 0110');
  Check(CodeStr(CB, 4) = '0111', 'spec entry4 = 0111');
  Check(CodeStr(CB, 5) = '10',   'spec entry5 = 10');
  Check(CodeStr(CB, 6) = '110',  'spec entry6 = 110');
  Check(CodeStr(CB, 7) = '111',  'spec entry7 = 111');

  // Unused entries (length 0) are skipped
  MakeCB(CB, [0, 1, 0, 1]);
  Check(VorbisCodebookInit(CB), 'init with unused entries');
  Check(CodeStr(CB, 1) = '0', 'sparse entry1 = 0');
  Check(CodeStr(CB, 3) = '1', 'sparse entry3 = 1');
end;

procedure TestV05_CodebookDecode;
var
  CB : TVorbisCodebook;
  W  : TBitWriter;
  Br : TAudioBitReader;
begin
  WriteLn('V05: VorbisCodebookDecode reads codewords first-bit-first');
  MakeCB(CB, [2, 4, 4, 4, 4, 2, 3, 3]);
  VorbisCodebookInit(CB);
  W.Init(8);
  W.PutCode('111');   // 7
  W.PutCode('0101');  // 2
  W.PutCode('00');    // 0
  W.PutCode('10');    // 5
  W.PutCode('0111');  // 4
  W.PutCode('110');   // 6
  BrInit(Br, @W.Buf[0], 8, boLSBFirst);
  Br.Limit := W.BitPos;  // exact packet length in bits
  Check(VorbisCodebookDecode(CB, Br) = 7, 'decode 111 -> 7');
  Check(VorbisCodebookDecode(CB, Br) = 2, 'decode 0101 -> 2');
  Check(VorbisCodebookDecode(CB, Br) = 0, 'decode 00 -> 0');
  Check(VorbisCodebookDecode(CB, Br) = 5, 'decode 10 -> 5');
  Check(VorbisCodebookDecode(CB, Br) = 4, 'decode 0111 -> 4');
  Check(VorbisCodebookDecode(CB, Br) = 6, 'decode 110 -> 6');
  Check(Br.Pos = W.BitPos, 'all bits consumed');
  Check(VorbisCodebookDecode(CB, Br) = -1, 'end of packet -> -1');
end;

procedure TestV06_VQType1;
var
  CB : TVorbisCodebook;
  Vec: array[0..1] of Single;
  W  : TBitWriter;
  Br : TAudioBitReader;
begin
  WriteLn('V06: VQ lookup type 1 (spec 3.2.1: dimension 0 uses divisor 1)');
  MakeCB(CB, [2, 2, 2, 2], 2);
  CB.LookupType := VORBIS_LOOKUP_TYPE1;
  CB.MinValue   := -1.0;
  CB.DeltaValue := 2.0;
  CB.ValueBits  := 1;
  CB.SequenceP  := False;
  SetLength(CB.Multiplicands, 2);
  CB.Multiplicands[0] := 0;   // -> -1.0
  CB.Multiplicands[1] := 1;   // ->  1.0
  Check(VorbisCodebookInit(CB), 'init VQ type 1');
  Check(CB.Lookup1Count = 2, 'lookup1_values = 2');
  // entry e: dim0 = mult[e mod 2], dim1 = mult[(e div 2) mod 2]
  Check(VorbisCodebookVQRow(CB, 1)[0] = 1.0,  'entry1 dim0 = +1');
  Check(VorbisCodebookVQRow(CB, 1)[1] = -1.0, 'entry1 dim1 = -1');
  Check(VorbisCodebookVQRow(CB, 2)[0] = -1.0, 'entry2 dim0 = -1');
  Check(VorbisCodebookVQRow(CB, 2)[1] = 1.0,  'entry2 dim1 = +1');

  W.Init(4);
  W.PutCode('01');  // entry 1
  W.PutCode('10');  // entry 2
  BrInit(Br, @W.Buf[0], 4, boLSBFirst);
  Check(VorbisCodebookDecodeVQ(CB, Br, @Vec[0]), 'DecodeVQ entry 1');
  Check((Vec[0] = 1.0) and (Vec[1] = -1.0), 'DecodeVQ entry 1 values');
  Check(VorbisCodebookDecodeVQ(CB, Br, @Vec[0]), 'DecodeVQ entry 2');
  Check((Vec[0] = -1.0) and (Vec[1] = 1.0), 'DecodeVQ entry 2 values');
end;

procedure TestV07_VQType2Sequence;
var
  CB : TVorbisCodebook;
begin
  WriteLn('V07: VQ lookup type 2 with sequence_p');
  MakeCB(CB, [1, 1], 3);
  CB.LookupType := VORBIS_LOOKUP_TYPE2;
  CB.MinValue   := 0.0;
  CB.DeltaValue := 0.5;
  CB.ValueBits  := 2;
  CB.SequenceP  := True;
  SetLength(CB.Multiplicands, 6);
  CB.Multiplicands[0] := 1; CB.Multiplicands[1] := 2; CB.Multiplicands[2] := 3;
  CB.Multiplicands[3] := 0; CB.Multiplicands[4] := 1; CB.Multiplicands[5] := 0;
  Check(VorbisCodebookInit(CB), 'init VQ type 2');
  // entry0: 0.5, 0.5+1.0, 1.5+1.5 = 0.5, 1.5, 3.0 (cumulative)
  CheckNear(VorbisCodebookVQRow(CB, 0)[0], 0.5, 1e-6, 'entry0[0]');
  CheckNear(VorbisCodebookVQRow(CB, 0)[1], 1.5, 1e-6, 'entry0[1]');
  CheckNear(VorbisCodebookVQRow(CB, 0)[2], 3.0, 1e-6, 'entry0[2]');
  CheckNear(VorbisCodebookVQRow(CB, 1)[0], 0.0, 1e-6, 'entry1[0]');
  CheckNear(VorbisCodebookVQRow(CB, 1)[1], 0.5, 1e-6, 'entry1[1]');
  CheckNear(VorbisCodebookVQRow(CB, 1)[2], 0.5, 1e-6, 'entry1[2]');
end;

procedure TestV08_LongCodes;
var
  CB   : TVorbisCodebook;
  Lens : array[0..14] of Byte;
  I    : Integer;
  W    : TBitWriter;
  Br   : TAudioBitReader;
  OK   : Boolean;
begin
  WriteLn('V08: codewords longer than the fast table (binary search path)');
  // Unary-like tree: entry i (i<14) = "1"*i + "0", entry 14 = "1"*14
  for I := 0 to 13 do Lens[I] := I + 1;
  Lens[14] := 14;
  MakeCB(CB, Lens);
  Check(VorbisCodebookInit(CB), 'init 15-entry chain');
  Check(CB.SortedCount = 5, 'five codes longer than 10 bits');
  Check(CodeStr(CB, 12) = '1111111111110', 'entry12 = 1^12 0');
  Check(CodeStr(CB, 14) = '11111111111111', 'entry14 = 1^14');

  W.Init(32);
  W.PutCode('1111111111110');     // 12
  W.PutCode('0');                 // 0
  W.PutCode('11111111111111');    // 14
  W.PutCode('11111111110');       // 10
  W.PutCode('1111111111111');     // 13 -> "1"*13 + "0"? no: entry13 = 1^13 0
  BrInit(Br, @W.Buf[0], 32, boLSBFirst);
  Br.Limit := W.BitPos;
  Check(VorbisCodebookDecode(CB, Br) = 12, 'decode entry 12');
  Check(VorbisCodebookDecode(CB, Br) = 0,  'decode entry 0');
  Check(VorbisCodebookDecode(CB, Br) = 14, 'decode entry 14');
  Check(VorbisCodebookDecode(CB, Br) = 10, 'decode entry 10');
  // Remaining 13 bits "1111111111111" are a prefix of entry 13/14 but truncated
  OK := VorbisCodebookDecode(CB, Br) = -1;
  Check(OK, 'truncated final codeword -> -1');
end;

// ---------------------------------------------------------------------------
// V09 floor helpers, V10 IMDCT, V11 window, V12 coupling
// ---------------------------------------------------------------------------

procedure TestV09_RenderPoint;
begin
  WriteLn('V09: render_point (spec 9.2.6)');
  Check(VorbisRenderPoint(0, 0, 10, 10, 5) = 5,   'linear midpoint');
  Check(VorbisRenderPoint(0, 10, 10, 0, 3) = 7,   'descending');
  Check(VorbisRenderPoint(0, 0, 8, 3, 5) = 1,     'integer truncation 15/8=1');
  Check(VorbisRenderPoint(10, 20, 20, 5, 15) = 13,'descending truncation');
end;

procedure TestV10_IMDCT;
var
  N, N2, I, J : Integer;
  X, Y, Yref  : TArray<Single>;
  Plan        : TVorbisIMDCTPlan;
  Acc         : Double;
  MaxErr, MaxVal: Double;
begin
  WriteLn('V10: IMDCT matches y[n] = sum X[k] cos(2pi/N (n+1/2+N/4)(k+1/2))');
  for N in [64, 256, 2048] do
  begin
    N2 := N div 2;
    SetLength(X, N2); SetLength(Y, N); SetLength(Yref, N);
    RandSeed := N;
    for I := 0 to N2 - 1 do X[I] := Random * 2 - 1;
    VorbisIMDCTInit(Plan, N);
    VorbisIMDCT(Plan, @X[0], @Y[0]);
    MaxErr := 0; MaxVal := 0;
    for I := 0 to N - 1 do
    begin
      Acc := 0;
      for J := 0 to N2 - 1 do
        Acc := Acc + X[J] * Cos(2 * Pi / N * (I + 0.5 + N / 4) * (J + 0.5));
      Yref[I] := Acc;
      MaxErr := Max(MaxErr, Abs(Acc - Y[I]));
      MaxVal := Max(MaxVal, Abs(Acc));
    end;
    Check(MaxErr < 1e-3 * MaxVal, Format('N=%d max error %.3g (max value %.3g)', [N, MaxErr, MaxVal]));
  end;
end;

procedure TestV11_WindowSlope;
var
  W : TArray<Single>;
  L, J : Integer;
  OK : Boolean;
begin
  WriteLn('V11: window slope is power complementary (w[j]^2 + w[L-1-j]^2 = 1)');
  for L in [128, 1024] do
  begin
    W := VorbisWindowSlope(L);
    OK := True;
    for J := 0 to L - 1 do
      if Abs(Sqr(W[J]) + Sqr(W[L - 1 - J]) - 1.0) > 1e-5 then OK := False;
    Check(OK, Format('L=%d', [L]));
    Check((W[0] > 0) and (W[0] < 0.01) and (W[L - 1] > 0.99), 'rises from ~0 to ~1');
  end;
end;

procedure TestV12_Decoupling;
var
  Coupling: TArray<TVorbisMappingCoupling>;
  Spectra : TArray<TArray<Single>>;
begin
  WriteLn('V12: inverse square polar coupling (spec 4.3.6)');
  SetLength(Coupling, 1);
  Coupling[0].Magnitude := 0;
  Coupling[0].Angle     := 1;
  SetLength(Spectra, 2);
  SetLength(Spectra[0], 4);
  SetLength(Spectra[1], 4);
  // M>0,A>0 | M>0,A<=0 | M<=0,A>0 | M<=0,A<=0
  Spectra[0][0] := 5;  Spectra[1][0] := 2;
  Spectra[0][1] := 5;  Spectra[1][1] := -2;
  Spectra[0][2] := -5; Spectra[1][2] := 2;
  Spectra[0][3] := -5; Spectra[1][3] := -2;
  DecoupleChannels(Coupling, 1, Spectra, 4);
  Check((Spectra[0][0] = 5)  and (Spectra[1][0] = 3),  'M>0,A>0  -> (M, M-A)');
  Check((Spectra[0][1] = 3)  and (Spectra[1][1] = 5),  'M>0,A<=0 -> (M+A, M)');
  Check((Spectra[0][2] = -5) and (Spectra[1][2] = -3), 'M<=0,A>0 -> (M, M+A)');
  Check((Spectra[0][3] = -3) and (Spectra[1][3] = -5), 'M<=0,A<=0-> (M-A, M)');
end;

// ---------------------------------------------------------------------------
// V13-V15 headers
// ---------------------------------------------------------------------------

function BuildIdent(Channels: Byte; Rate: Cardinal; BS0Exp, BS1Exp: Byte): TBytes;
begin
  SetLength(Result, 30);
  FillChar(Result[0], 30, 0);
  Result[0] := 1;
  Move(PAnsiChar('vorbis')^, Result[1], 6);
  PCardinal(@Result[7])^  := 0;          // version
  Result[11] := Channels;
  PCardinal(@Result[12])^ := Rate;
  PInteger(@Result[16])^  := 0;
  PInteger(@Result[20])^  := 128000;
  PInteger(@Result[24])^  := 0;
  Result[28] := BS0Exp or (BS1Exp shl 4);
  Result[29] := 1;                        // framing bit
end;

procedure TestV13_ParseIdent;
var
  Pkt  : TBytes;
  Setup: TVorbisSetup;
begin
  WriteLn('V13: VorbisParseIdent');
  Setup := Default(TVorbisSetup);
  Pkt := BuildIdent(2, 44100, 8, 11);
  Check(VorbisParseIdent(@Pkt[0], Length(Pkt), Setup), 'parse ok');
  Check(Setup.Ident.Channels = 2, 'channels = 2');
  Check(Setup.Ident.SampleRate = 44100, 'rate = 44100');
  Check(Setup.Ident.BlockSize0 = 256, 'blocksize0 = 256');
  Check(Setup.Ident.BlockSize1 = 2048, 'blocksize1 = 2048');
  Check(Setup.Ident.BitrateNominal = 128000, 'nominal bitrate');
  Pkt[29] := 0;
  Check(not VorbisParseIdent(@Pkt[0], Length(Pkt), Setup), 'missing framing bit rejected');
  Pkt := BuildIdent(2, 44100, 11, 8);
  Check(not VorbisParseIdent(@Pkt[0], Length(Pkt), Setup), 'blocksize1 < blocksize0 rejected');
  Pkt := BuildIdent(0, 44100, 8, 11);
  Check(not VorbisParseIdent(@Pkt[0], Length(Pkt), Setup), 'zero channels rejected');
end;

procedure TestV14_ParseComment;
var
  Pkt: TBytes;
begin
  WriteLn('V14: VorbisParseComment');
  SetLength(Pkt, 16);
  FillChar(Pkt[0], 16, 0);
  Pkt[0] := 3;
  Move(PAnsiChar('vorbis')^, Pkt[1], 6);
  Check(VorbisParseComment(@Pkt[0], 16), 'comment header accepted');
  Pkt[0] := 1;
  Check(not VorbisParseComment(@Pkt[0], 16), 'wrong packet type rejected');
  Pkt[0] := 3; Pkt[3] := Ord('X');
  Check(not VorbisParseComment(@Pkt[0], 16), 'bad magic rejected');
end;

procedure TestV15_HeaderSequence;
var
  Dec   : TVorbisDecoder;
  Pkt   : TBytes;
  Buf   : TAudioBuffer;
  Samples: Integer;
begin
  WriteLn('V15: header sequence through TVorbisDecoder');
  Dec := TVorbisDecoder.Create;
  try
    Pkt := BuildIdent(1, 8000, 6, 8);
    Check(Dec.DecodePacket(@Pkt[0], Length(Pkt), Buf, Samples) = vdrHeader, 'ident -> vdrHeader');
    Check(not Dec.Ready, 'not ready after ident');
    SetLength(Pkt, 8); FillChar(Pkt[0], 8, 0); Pkt[0] := 3; Move(PAnsiChar('vorbis')^, Pkt[1], 6);
    Check(Dec.DecodePacket(@Pkt[0], Length(Pkt), Buf, Samples) = vdrHeader, 'comment -> vdrHeader');
    Check(not Dec.Ready, 'not ready after comment');
    Pkt[0] := 0;
    Check(Dec.DecodePacket(@Pkt[0], Length(Pkt), Buf, Samples) = vdrError, 'audio before setup -> vdrError');
    Check(Dec.Channels = 1, 'Channels property');
    Check(Dec.SampleRate = 8000, 'SampleRate property');
  finally
    Dec.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Integration with real files
// ---------------------------------------------------------------------------

type
  TDecodeStats = record
    Frames   : Int64;
    Channels : Integer;
    Rate     : Cardinal;
    RMS      : array[0..7] of Double;
    Goertzel : Double;   // energy ratio at TargetHz (channel 0)
    Errors   : Integer;
  end;

function DecodeFile(const FileName: string; TargetHz: Double; out St: TDecodeStats;
  var Dec: TVorbisDecoder): Boolean;
var
  FS     : TFileStream;
  Rd     : TOggPageReader;
  Pkt    : TOggPacket;
  Buf    : TAudioBuffer;
  Samples: Integer;
  VR     : TVorbisDecodeResult;
  Ch, I  : Integer;
  SumSq  : array[0..7] of Double;
  // Goertzel
  Coef, S0, S1, S2: Double;
  Total : Double;
begin
  Result := False;
  St := Default(TDecodeStats);
  if not FileExists(FileName) then Exit;
  FillChar(SumSq, SizeOf(SumSq), 0);
  S1 := 0; S2 := 0; Total := 0; Coef := 0;
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  Rd := TOggPageReader.Create(FS, False);
  try
    repeat
      if Rd.ReadPacket(Pkt) <> orrPacket then Break;
      VR := Dec.DecodePacket(@Pkt.Data[0], Pkt.Length, Buf, Samples);
      if VR = vdrHeader then
      begin
        if Dec.Ready then
        begin
          St.Channels := Dec.Channels;
          St.Rate     := Dec.SampleRate;
          Coef := 2 * Cos(2 * Pi * TargetHz / Dec.SampleRate);
        end;
        Continue;
      end;
      if VR <> vdrOK then begin Inc(St.Errors); Continue; end;
      if Samples = 0 then Continue;
      // EOS trimming as the audio-codec adapter does it
      if Pkt.IsEOS and (St.Frames + Samples > Pkt.GranulePos) then
        Samples := Max(0, Integer(Pkt.GranulePos - St.Frames));
      for Ch := 0 to St.Channels - 1 do
        for I := 0 to Samples - 1 do
          SumSq[Ch] := SumSq[Ch] + Sqr(Buf[Ch][I]);
      for I := 0 to Samples - 1 do
      begin
        S0 := Buf[0][I] + Coef * S1 - S2;
        S2 := S1; S1 := S0;
        Total := Total + Sqr(Buf[0][I]);
      end;
      Inc(St.Frames, Samples);
    until False;
  finally
    Rd.Free;
    FS.Free;
  end;
  if St.Frames = 0 then Exit;
  for Ch := 0 to St.Channels - 1 do
    St.RMS[Ch] := Sqrt(SumSq[Ch] / St.Frames);
  // Goertzel power normalised by total energy
  St.Goertzel := (Sqr(S1) + Sqr(S2) - Coef * S1 * S2) / (St.Frames * 0.5) / Max(Total, 1e-20) * 1.0;
  Result := True;
end;

procedure TestV16_RealSetupHeader;
var
  FS   : TFileStream;
  Rd   : TOggPageReader;
  Pkt  : TOggPacket;
  Setup: TVorbisSetup;
  N, I : Integer;
  OK   : Boolean;
  FN   : string;
begin
  WriteLn('V16: setup header of a real libvorbis stream');
  FN := SamplesDir + 'speech_48k_stereo_q5.ogg';
  if not FileExists(FN) then begin Check(False, 'sample file missing: ' + FN); Exit; end;
  Setup := Default(TVorbisSetup);
  FS := TFileStream.Create(FN, fmOpenRead or fmShareDenyWrite);
  Rd := TOggPageReader.Create(FS, False);
  try
    N := 0;
    while (N < 3) and (Rd.ReadPacket(Pkt) = orrPacket) do
    begin
      Inc(N);
      case N of
        1: Check(VorbisParseIdent(@Pkt.Data[0], Pkt.Length, Setup), 'ident parses');
        2: Check(VorbisParseComment(@Pkt.Data[0], Pkt.Length), 'comment parses');
        3: Check(VorbisParseSetup(@Pkt.Data[0], Pkt.Length, Setup), 'setup parses');
      end;
    end;
  finally
    Rd.Free; FS.Free;
  end;
  Check(Setup.Initialized, 'Setup.Initialized');
  Check(Setup.CodebookCount = 42, Format('42 codebooks (got %d)', [Setup.CodebookCount]));
  Check((Setup.FloorCount = 2) and (Setup.ResidueCount = 2) and (Setup.ModeCount = 2),
    'two floors, residues and modes');
  OK := True;
  for I := 0 to Setup.FloorCount - 1 do
  begin
    if Setup.Floors[I].FloorType <> VORBIS_FLOOR_TYPE_1 then OK := False;
    if Setup.Floors[I].Floor1.XList[1] <> (1 shl Setup.Floors[I].Floor1.RangeBits) then OK := False;
  end;
  Check(OK, 'floor1 X[1] = 1 shl rangebits');
  Check((Setup.Residues[0].ResType = 2) and (Setup.Residues[1].ResType = 2), 'residue type 2');
  Check((Setup.Residues[1].Begin_ = 0) and (Setup.Residues[1].End_ = 1728) and
        (Setup.Residues[1].ClassBook = 41), 'residue 1 fields (begin 0, end 1728, classbook 41)');
  Check(Setup.Codebooks[16].HuffMaxLen = 22, 'codebook 16 max length 22');
  Check(Setup.Codebooks[28].Lookup1Count = 3, 'codebook 28 lookup1 values = 3');
  Check(Setup.Mappings[0].Couplings = 1, 'one coupling step');
end;

procedure TestV17_RealTone;
var
  St : TDecodeStats;
  Dec: TVorbisDecoder;
begin
  WriteLn('V17: 440 Hz mono tone (tone440_44k_mono_q5.ogg) vs ffmpeg reference');
  Dec := TVorbisDecoder.Create;
  try
    if not DecodeFile(SamplesDir + 'tone440_44k_mono_q5.ogg', 440.0, St, Dec) then
    begin
      Check(False, 'decode failed or sample missing');
      Exit;
    end;
    Check(St.Errors = 0, 'no packet errors');
    Check((St.Channels = 1) and (St.Rate = 44100), 'mono 44.1 kHz');
    Check(St.Frames = 132300, Format('132300 frames (got %d)', [St.Frames]));
    CheckNear(St.RMS[0], 0.0445, 0.001, 'RMS 0.0445 (ffmpeg)');
    Check(St.Goertzel > 0.98, Format('energy concentrated at 440 Hz (%.3f)', [St.Goertzel]));
  finally
    Dec.Free;
  end;
end;

procedure TestV18_RealSpeech;
var
  St : TDecodeStats;
  Dec: TVorbisDecoder;
begin
  WriteLn('V18: stereo speech (speech_48k_stereo_q5.ogg) vs ffmpeg reference');
  Dec := TVorbisDecoder.Create;
  try
    if not DecodeFile(SamplesDir + 'speech_48k_stereo_q5.ogg', 1000.0, St, Dec) then
    begin
      Check(False, 'decode failed or sample missing');
      Exit;
    end;
    Check(St.Errors = 0, 'no packet errors');
    Check((St.Channels = 2) and (St.Rate = 48000), 'stereo 48 kHz');
    Check(St.Frames = 190080, Format('190080 frames (got %d)', [St.Frames]));
    CheckNear(St.RMS[0], 0.0704, 0.0015, 'RMS L 0.0704 (ffmpeg)');
    CheckNear(St.RMS[1], 0.0704, 0.0015, 'RMS R 0.0704 (ffmpeg)');
  finally
    Dec.Free;
  end;
end;

// ---------------------------------------------------------------------------
// V19-V21 robustness
// ---------------------------------------------------------------------------

procedure TestV19_OverSubscribed;
var
  CB: TVorbisCodebook;
begin
  WriteLn('V19: over-subscribed code lengths are rejected');
  MakeCB(CB, [1, 1, 1]);
  Check(not VorbisCodebookInit(CB), '[1,1,1] rejected');
  MakeCB(CB, [1, 2, 2, 2]);
  Check(not VorbisCodebookInit(CB), '[1,2,2,2] rejected');
  MakeCB(CB, [1, 2, 2]);
  Check(VorbisCodebookInit(CB), '[1,2,2] accepted (complete tree)');
  MakeCB(CB, [1, 2]);
  Check(VorbisCodebookInit(CB), '[1,2] accepted (under-specified tree is legal)');
end;

procedure TestV20_TruncatedPacket;
var
  FS     : TFileStream;
  Rd     : TOggPageReader;
  Pkt    : TOggPacket;
  Dec    : TVorbisDecoder;
  Buf    : TAudioBuffer;
  Samples: Integer;
  N      : Integer;
  VR     : TVorbisDecodeResult;
  FN     : string;
  OK     : Boolean;
begin
  WriteLn('V20: truncated audio packets do not crash and keep the stream going');
  FN := SamplesDir + 'tone440_44k_mono_q5.ogg';
  if not FileExists(FN) then begin Check(False, 'sample missing'); Exit; end;
  Dec := TVorbisDecoder.Create;
  FS := TFileStream.Create(FN, fmOpenRead or fmShareDenyWrite);
  Rd := TOggPageReader.Create(FS, False);
  try
    N := 0; OK := True;
    while (N < 12) and (Rd.ReadPacket(Pkt) = orrPacket) do
    begin
      Inc(N);
      if N <= 3 then
        Dec.DecodePacket(@Pkt.Data[0], Pkt.Length, Buf, Samples)
      else
      begin
        // feed only the first third of every audio packet
        VR := Dec.DecodePacket(@Pkt.Data[0], Max(1, Pkt.Length div 3), Buf, Samples);
        if not (VR in [vdrOK, vdrCorrupted]) then OK := False;
      end;
    end;
    Check(OK, 'truncated packets return vdrOK or vdrCorrupted');
    Check(N = 12, 'twelve packets processed');
    // A full packet afterwards still decodes
    if Rd.ReadPacket(Pkt) = orrPacket then
    begin
      VR := Dec.DecodePacket(@Pkt.Data[0], Pkt.Length, Buf, Samples);
      Check((VR = vdrOK) and (Samples > 0), 'next full packet decodes');
    end;
  finally
    Rd.Free; FS.Free; Dec.Free;
  end;
end;

procedure TestV21_Reset;
var
  FS     : TFileStream;
  Rd     : TOggPageReader;
  Pkt    : TOggPacket;
  Dec    : TVorbisDecoder;
  Buf    : TAudioBuffer;
  Samples: Integer;
  N      : Integer;
  FN     : string;
begin
  WriteLn('V21: Reset drops overlap state (next packet yields no samples)');
  FN := SamplesDir + 'tone440_44k_mono_q5.ogg';
  if not FileExists(FN) then begin Check(False, 'sample missing'); Exit; end;
  Dec := TVorbisDecoder.Create;
  FS := TFileStream.Create(FN, fmOpenRead or fmShareDenyWrite);
  Rd := TOggPageReader.Create(FS, False);
  try
    N := 0;
    while (N < 6) and (Rd.ReadPacket(Pkt) = orrPacket) do
    begin
      Inc(N);
      Dec.DecodePacket(@Pkt.Data[0], Pkt.Length, Buf, Samples);
    end;
    Check(Samples > 0, 'packet 6 produced samples');
    Dec.Reset;
    if Rd.ReadPacket(Pkt) = orrPacket then
    begin
      Dec.DecodePacket(@Pkt.Data[0], Pkt.Length, Buf, Samples);
      Check(Samples = 0, 'first packet after Reset produces 0 samples');
    end;
    if Rd.ReadPacket(Pkt) = orrPacket then
    begin
      Dec.DecodePacket(@Pkt.Data[0], Pkt.Length, Buf, Samples);
      Check(Samples > 0, 'second packet after Reset produces samples');
    end;
  finally
    Rd.Free; FS.Free; Dec.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
begin
  Passed := 0;
  Failed := 0;
  WriteLn('=== Vorbis Decoder Tests ===');
  WriteLn;

  TestV01_ILog;
  TestV02_Float32Unpack;
  TestV03_Lookup1;
  TestV04_CodewordAssignment;
  TestV05_CodebookDecode;
  TestV06_VQType1;
  TestV07_VQType2Sequence;
  TestV08_LongCodes;
  TestV09_RenderPoint;
  TestV10_IMDCT;
  TestV11_WindowSlope;
  TestV12_Decoupling;
  TestV13_ParseIdent;
  TestV14_ParseComment;
  TestV15_HeaderSequence;
  TestV16_RealSetupHeader;
  TestV17_RealTone;
  TestV18_RealSpeech;
  TestV19_OverSubscribed;
  TestV20_TruncatedPacket;
  TestV21_Reset;

  WriteLn;
  WriteLn(Format('Results: %d passed, %d failed', [Passed, Failed]));
  if Failed = 0 then
    WriteLn('All tests PASSED.')
  else
    WriteLn('Some tests FAILED.');
  WriteLn;
  ExitCode := Failed;
end.
