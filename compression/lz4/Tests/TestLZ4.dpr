program TestLZ4;

{
  TestLZ4.dpr -- 30 unit tests for uLZ4 (LZ4 block + frame codec)

  Tests cover:
    LZ01-LZ05 : LZ4BlockBound + block compress basics
    LZ06-LZ11 : Block roundtrips (short, long, patterns)
    LZ12-LZ15 : Block compress properties (compression ratio, edge cases)
    LZ16-LZ24 : Frame format (magic, roundtrips, multi-block, checksums)
    LZ25-LZ30 : Error handling (bad magic, bad checksum, corrupt data)

  Each test prints PASS/FAIL. Exit code 1 if any test fails.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$APPTYPE CONSOLE}

uses
  SysUtils, Math,
  uLZ4;

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
// Helpers
// ---------------------------------------------------------------------------

function BytesEqual(const A, B: TBytes): Boolean;
var I: Integer;
begin
  if Length(A) <> Length(B) then Exit(False);
  for I := 0 to High(A) do
    if A[I] <> B[I] then Exit(False);
  Result := True;
end;

function MakeRepetitive(Size: Integer; Value: Byte = $AB): TBytes;
begin
  SetLength(Result, Size);
  FillChar(Result[0], Size, Value);
end;

function MakeRamp(Size: Integer): TBytes;
var I: Integer;
begin
  SetLength(Result, Size);
  for I := 0 to Size - 1 do
    Result[I] := Byte(I and $FF);
end;

function MakePseudoRandom(Size: Integer): TBytes;
var I: Integer; V: Cardinal;
begin
  SetLength(Result, Size);
  V := $DEADBEEF;
  for I := 0 to Size - 1 do
  begin
    V := V * 1664525 + 1013904223;
    Result[I] := Byte(V shr 16);
  end;
end;

// ---------------------------------------------------------------------------
// LZ01-LZ05: LZ4BlockBound and basic compress
// ---------------------------------------------------------------------------

procedure TestLZ01_BoundExceedsSource;
begin
  Check('LZ01: LZ4BlockBound(1000) > 1000', LZ4BlockBound(1000) > 1000);
end;

procedure TestLZ02_BoundZero;
begin
  Check('LZ02: LZ4BlockBound(0) >= 1', LZ4BlockBound(0) >= 1);
end;

procedure TestLZ03_CompressEmptyReturnsOneByte;
var
  Src, Dst: TBytes;
  Len: Integer;
begin
  SetLength(Src, 0);
  SetLength(Dst, 16);
  Len := LZ4BlockCompress(nil, 0, @Dst[0], 16);
  Check('LZ03: LZ4BlockCompress empty → 1 byte token', Len = 1);
end;

procedure TestLZ04_DecompressEmptyToken;
var
  Src, Dst: TBytes;
  Len: Integer;
begin
  SetLength(Src, 1); Src[0] := 0;  // token: 0 literals, no match
  SetLength(Dst, 16);
  Len := LZ4BlockDecompress(@Src[0], 1, @Dst[0], 16);
  Check('LZ04: LZ4BlockDecompress empty token → 0 bytes', Len = 0);
end;

procedure TestLZ05_CompressInsufficientDstReturnsZero;
var
  Src: TBytes;
  Dst: array[0..15] of Byte;
  Len: Integer;
begin
  Src := MakeRamp(1000);
  Len := LZ4BlockCompress(@Src[0], Length(Src), @Dst[0], 16);  // 16 < LZ4BlockBound(1000)
  Check('LZ05: LZ4BlockCompress with tiny dst → 0', Len = 0);
end;

// ---------------------------------------------------------------------------
// LZ06-LZ11: Block roundtrips
// ---------------------------------------------------------------------------

procedure TestLZ06_BlockRoundtripSingleByte;
var
  Src: TBytes;
  Comp, Decomp: TBytes;
  CompLen, DecompLen: Integer;
begin
  SetLength(Src, 1); Src[0] := $42;
  SetLength(Comp, LZ4BlockBound(1));
  CompLen   := LZ4BlockCompress(@Src[0], 1, @Comp[0], Length(Comp));
  SetLength(Decomp, 1);
  DecompLen := LZ4BlockDecompress(@Comp[0], CompLen, @Decomp[0], 1);
  Check('LZ06: block roundtrip single byte',
    (DecompLen = 1) and (Decomp[0] = $42));
end;

procedure TestLZ07_BlockRoundtripShortString;
var
  Src, Comp, Decomp: TBytes;
  Orig: string;
  CompLen, DecompLen: Integer;
begin
  Orig := 'Hello, LZ4 World!';
  SetLength(Src, Length(Orig));
  Move(Orig[1], Src[0], Length(Orig));
  SetLength(Comp, LZ4BlockBound(Length(Src)));
  CompLen   := LZ4BlockCompress(@Src[0], Length(Src), @Comp[0], Length(Comp));
  SetLength(Decomp, Length(Src));
  DecompLen := LZ4BlockDecompress(@Comp[0], CompLen, @Decomp[0], Length(Decomp));
  Check('LZ07: block roundtrip short ASCII string',
    (DecompLen = Length(Src)) and BytesEqual(Src, Decomp));
end;

procedure TestLZ08_BlockRoundtripRepetitive;
var
  Src, Comp, Decomp: TBytes;
  CompLen, DecompLen: Integer;
begin
  Src       := MakeRepetitive(4096, $CC);
  SetLength(Comp, LZ4BlockBound(4096));
  CompLen   := LZ4BlockCompress(@Src[0], 4096, @Comp[0], Length(Comp));
  SetLength(Decomp, 4096);
  DecompLen := LZ4BlockDecompress(@Comp[0], CompLen, @Decomp[0], 4096);
  Check('LZ08: block roundtrip 4KB repetitive data',
    (DecompLen = 4096) and BytesEqual(Src, Decomp));
end;

procedure TestLZ09_BlockRoundtripRamp;
var
  Src, Comp, Decomp: TBytes;
  CompLen, DecompLen: Integer;
begin
  Src       := MakeRamp(8192);
  SetLength(Comp, LZ4BlockBound(8192));
  CompLen   := LZ4BlockCompress(@Src[0], 8192, @Comp[0], Length(Comp));
  SetLength(Decomp, 8192);
  DecompLen := LZ4BlockDecompress(@Comp[0], CompLen, @Decomp[0], 8192);
  Check('LZ09: block roundtrip 8KB ramp pattern',
    (DecompLen = 8192) and BytesEqual(Src, Decomp));
end;

procedure TestLZ10_BlockCompressBytesRoundtrip;
var
  Src, Comp, Decomp: TBytes;
begin
  Src    := MakeRepetitive(1024, $7F);
  Comp   := LZ4BlockCompressBytes(Src);
  Decomp := LZ4BlockDecompressBytes(Comp, 1024);
  Check('LZ10: LZ4BlockCompressBytes/DecompressBytes roundtrip 1KB',
    BytesEqual(Src, Decomp));
end;

procedure TestLZ11_BlockRoundtripPseudoRandom;
var
  Src, Comp, Decomp: TBytes;
  CompLen, DecompLen: Integer;
begin
  Src       := MakePseudoRandom(32768);
  SetLength(Comp, LZ4BlockBound(32768));
  CompLen   := LZ4BlockCompress(@Src[0], 32768, @Comp[0], Length(Comp));
  SetLength(Decomp, 32768);
  DecompLen := LZ4BlockDecompress(@Comp[0], CompLen, @Decomp[0], 32768);
  Check('LZ11: block roundtrip 32KB pseudo-random',
    (DecompLen = 32768) and BytesEqual(Src, Decomp));
end;

// ---------------------------------------------------------------------------
// LZ12-LZ15: Compression properties
// ---------------------------------------------------------------------------

procedure TestLZ12_RepetitiveCompressesSmaller;
var
  Src, Comp: TBytes;
  CompLen: Integer;
begin
  Src     := MakeRepetitive(4096, $55);
  SetLength(Comp, LZ4BlockBound(4096));
  CompLen := LZ4BlockCompress(@Src[0], 4096, @Comp[0], Length(Comp));
  Check('LZ12: 4KB repetitive compresses to < 100 bytes', CompLen < 100);
end;

procedure TestLZ13_CompressOutputNonZero;
var
  Src, Comp: TBytes;
  CompLen: Integer;
begin
  Src     := MakePseudoRandom(1024);
  SetLength(Comp, LZ4BlockBound(1024));
  CompLen := LZ4BlockCompress(@Src[0], 1024, @Comp[0], Length(Comp));
  Check('LZ13: pseudo-random data compresses to non-zero bytes', CompLen > 0);
end;

procedure TestLZ14_ShortInputRoundtrip;
var
  Src: TBytes;
  Comp, Decomp: TBytes;
  CompLen, DecompLen: Integer;
begin
  SetLength(Src, 3); Src[0] := $AA; Src[1] := $BB; Src[2] := $CC;
  SetLength(Comp, LZ4BlockBound(3));
  CompLen   := LZ4BlockCompress(@Src[0], 3, @Comp[0], Length(Comp));
  SetLength(Decomp, 3);
  DecompLen := LZ4BlockDecompress(@Comp[0], CompLen, @Decomp[0], 3);
  Check('LZ14: 3-byte input roundtrip', (DecompLen = 3) and BytesEqual(Src, Decomp));
end;

procedure TestLZ15_BlockBytesEmptyRoundtrip;
var
  Src, Comp, Decomp: TBytes;
begin
  SetLength(Src, 0);
  Comp   := LZ4BlockCompressBytes(Src);
  Decomp := LZ4BlockDecompressBytes(Comp, 0);
  Check('LZ15: LZ4BlockCompressBytes empty roundtrip', Length(Decomp) = 0);
end;

// ---------------------------------------------------------------------------
// LZ16-LZ24: Frame format
// ---------------------------------------------------------------------------

procedure TestLZ16_FrameMagicBytes;
var
  Src, Frame: TBytes;
  Magic: Cardinal;
begin
  Src   := MakeRamp(64);
  Frame := LZ4FrameCompress(Src);
  Move(Frame[0], Magic, 4);
  Check('LZ16: LZ4FrameCompress starts with magic $184D2204', Magic = $184D2204);
end;

procedure TestLZ17_FrameRoundtripEmpty;
var
  Frame, Decomp: TBytes;
begin
  SetLength(Frame, 0);
  Frame  := LZ4FrameCompress(Frame);
  Decomp := LZ4FrameDecompress(Frame);
  Check('LZ17: LZ4FrameCompress/Decompress empty input', Length(Decomp) = 0);
end;

procedure TestLZ18_FrameRoundtripShortString;
var
  Src: TBytes;
  Frame, Decomp: TBytes;
  Msg: string;
begin
  Msg := 'Pure-Delphi LZ4 frame format roundtrip test';
  SetLength(Src, Length(Msg));
  Move(Msg[1], Src[0], Length(Msg));
  Frame  := LZ4FrameCompress(Src);
  Decomp := LZ4FrameDecompress(Frame);
  Check('LZ18: frame roundtrip short string', BytesEqual(Src, Decomp));
end;

procedure TestLZ19_FrameRoundtripRepetitive;
var
  Src, Frame, Decomp: TBytes;
begin
  Src    := MakeRepetitive(65536, $A0);
  Frame  := LZ4FrameCompress(Src);
  Decomp := LZ4FrameDecompress(Frame);
  Check('LZ19: frame roundtrip 64KB repetitive (single block)', BytesEqual(Src, Decomp));
end;

procedure TestLZ20_FrameCompressesRepetitiveSmaller;
var
  Src, Frame: TBytes;
begin
  Src   := MakeRepetitive(65536, $D0);
  Frame := LZ4FrameCompress(Src);
  Check('LZ20: frame compresses 64KB repetitive to < 1KB', Length(Frame) < 1024);
end;

procedure TestLZ21_FrameRoundtripMultiBlock;
var
  Src, Frame, Decomp: TBytes;
begin
  Src    := MakeRamp(200000);   // spans more than three 64KB blocks
  Frame  := LZ4FrameCompress(Src);
  Decomp := LZ4FrameDecompress(Frame);
  Check('LZ21: frame roundtrip 200KB ramp (multi-block)', BytesEqual(Src, Decomp));
end;

procedure TestLZ22_FrameRoundtripBinaryRandom;
var
  Src, Frame, Decomp: TBytes;
begin
  Src    := MakePseudoRandom(131072);
  Frame  := LZ4FrameCompress(Src);
  Decomp := LZ4FrameDecompress(Frame);
  Check('LZ22: frame roundtrip 128KB pseudo-random', BytesEqual(Src, Decomp));
end;

procedure TestLZ23_FrameDecompressBadMagic;
var
  Frame: TBytes;
  Raised: Boolean;
begin
  SetLength(Frame, 16);
  Frame[0] := $DE; Frame[1] := $AD; Frame[2] := $BE; Frame[3] := $EF;
  Raised := False;
  try
    LZ4FrameDecompress(Frame);
  except
    on E: ELZ4Error do Raised := True;
  end;
  Check('LZ23: LZ4FrameDecompress bad magic → ELZ4Error', Raised);
end;

procedure TestLZ24_FrameDecompressTruncated;
var
  Src, Frame, Truncated: TBytes;
  Raised: Boolean;
begin
  Src   := MakeRamp(200);
  Frame := LZ4FrameCompress(Src);
  // Truncate to 4 bytes (only magic)
  SetLength(Truncated, 4);
  Move(Frame[0], Truncated[0], 4);
  Raised := False;
  try
    LZ4FrameDecompress(Truncated);
  except
    on E: ELZ4Error do Raised := True;
  end;
  Check('LZ24: LZ4FrameDecompress truncated frame → ELZ4Error', Raised);
end;

// ---------------------------------------------------------------------------
// LZ25-LZ30: Error handling and edge cases
// ---------------------------------------------------------------------------

procedure TestLZ25_BlockDecompressInvalidOffset;
var
  Compressed: TBytes;
  Dst: TBytes;
  Raised: Boolean;
begin
  // Token: 1 literal, matchlen nibble = 0 (= MINMATCH=4), offset = 0 (invalid)
  SetLength(Compressed, 4);
  Compressed[0] := $10;  // token: 1 literal, match nibble=0
  Compressed[1] := $41;  // literal 'A'
  Compressed[2] := $00;  // offset low byte = 0
  Compressed[3] := $00;  // offset high byte = 0  → offset = 0 (invalid)
  SetLength(Dst, 64);
  Raised := False;
  try
    LZ4BlockDecompress(@Compressed[0], 4, @Dst[0], 64);
  except
    on E: ELZ4Error do Raised := True;
  end;
  Check('LZ25: LZ4BlockDecompress offset=0 → ELZ4Error', Raised);
end;

procedure TestLZ26_BlockDecompressOutputOverflow;
var
  Src, Comp, Dst: TBytes;
  CompLen: Integer;
  Raised: Boolean;
begin
  Src := MakeRepetitive(1024, $BB);
  SetLength(Comp, LZ4BlockBound(1024));
  CompLen := LZ4BlockCompress(@Src[0], 1024, @Comp[0], Length(Comp));
  SetLength(Comp, CompLen);
  // Provide output buffer that is too small
  SetLength(Dst, 512);
  Raised := False;
  try
    LZ4BlockDecompress(@Comp[0], CompLen, @Dst[0], 512);
  except
    on E: ELZ4Error do Raised := True;
  end;
  Check('LZ26: LZ4BlockDecompress output too small → ELZ4Error', Raised);
end;

procedure TestLZ27_BlockDecompressTruncatedLiteral;
var
  Compressed: TBytes;
  Dst: TBytes;
  Raised: Boolean;
begin
  // Token: 10 literals (nibble = 10), but only 4 literal bytes follow
  SetLength(Compressed, 5);
  Compressed[0] := $A0;  // token: 10 literals (nibble = $A = 10)
  Compressed[1] := $41; Compressed[2] := $42; Compressed[3] := $43; Compressed[4] := $44;
  SetLength(Dst, 64);
  Raised := False;
  try
    LZ4BlockDecompress(@Compressed[0], 5, @Dst[0], 64);
  except
    on E: ELZ4Error do Raised := True;
  end;
  Check('LZ27: LZ4BlockDecompress truncated literal → ELZ4Error', Raised);
end;

procedure TestLZ28_FrameHeaderChecksumMismatch;
var
  Src, Frame: TBytes;
  Raised: Boolean;
begin
  Src   := MakeRamp(64);
  Frame := LZ4FrameCompress(Src);
  // Corrupt the header checksum byte (index 6)
  Frame[6] := Frame[6] xor $FF;
  Raised := False;
  try
    LZ4FrameDecompress(Frame);
  except
    on E: ELZ4Error do Raised := True;
  end;
  Check('LZ28: frame with bad header checksum → ELZ4Error', Raised);
end;

procedure TestLZ29_FrameContentChecksumMismatch;
var
  Src, Frame: TBytes;
  Raised: Boolean;
begin
  Src   := MakeRamp(200);
  Frame := LZ4FrameCompress(Src);
  // Corrupt the last 4 bytes (content checksum)
  Frame[High(Frame)] := Frame[High(Frame)] xor $FF;
  Raised := False;
  try
    LZ4FrameDecompress(Frame);
  except
    on E: ELZ4Error do Raised := True;
  end;
  Check('LZ29: frame with bad content checksum → ELZ4Error', Raised);
end;

procedure TestLZ30_BlockRoundtripAllZeros;
var
  Src, Comp, Decomp: TBytes;
  CompLen, DecompLen: Integer;
begin
  Src       := MakeRepetitive(65536, 0);
  SetLength(Comp, LZ4BlockBound(65536));
  CompLen   := LZ4BlockCompress(@Src[0], 65536, @Comp[0], Length(Comp));
  SetLength(Decomp, 65536);
  DecompLen := LZ4BlockDecompress(@Comp[0], CompLen, @Decomp[0], 65536);
  Check('LZ30: block roundtrip 64KB all-zero', (DecompLen = 65536) and BytesEqual(Src, Decomp));
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

begin
  WriteLn('=== LZ4 Tests ===');
  WriteLn;

  TestLZ01_BoundExceedsSource;
  TestLZ02_BoundZero;
  TestLZ03_CompressEmptyReturnsOneByte;
  TestLZ04_DecompressEmptyToken;
  TestLZ05_CompressInsufficientDstReturnsZero;

  TestLZ06_BlockRoundtripSingleByte;
  TestLZ07_BlockRoundtripShortString;
  TestLZ08_BlockRoundtripRepetitive;
  TestLZ09_BlockRoundtripRamp;
  TestLZ10_BlockCompressBytesRoundtrip;
  TestLZ11_BlockRoundtripPseudoRandom;

  TestLZ12_RepetitiveCompressesSmaller;
  TestLZ13_CompressOutputNonZero;
  TestLZ14_ShortInputRoundtrip;
  TestLZ15_BlockBytesEmptyRoundtrip;

  TestLZ16_FrameMagicBytes;
  TestLZ17_FrameRoundtripEmpty;
  TestLZ18_FrameRoundtripShortString;
  TestLZ19_FrameRoundtripRepetitive;
  TestLZ20_FrameCompressesRepetitiveSmaller;
  TestLZ21_FrameRoundtripMultiBlock;
  TestLZ22_FrameRoundtripBinaryRandom;
  TestLZ23_FrameDecompressBadMagic;
  TestLZ24_FrameDecompressTruncated;

  TestLZ25_BlockDecompressInvalidOffset;
  TestLZ26_BlockDecompressOutputOverflow;
  TestLZ27_BlockDecompressTruncatedLiteral;
  TestLZ28_FrameHeaderChecksumMismatch;
  TestLZ29_FrameContentChecksumMismatch;
  TestLZ30_BlockRoundtripAllZeros;

  WriteLn;
  WriteLn(Format('%d/%d tests passed', [GPassed, GTotal]));
  if GPassed < GTotal then
    Halt(1);
end.
