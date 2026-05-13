program TestMP3EncPhase1;

{$APPTYPE CONSOLE}

{
  Phase 1 tests — MP3EncTypes + MP3EncBitWriter

  Verifies:
    - Bit writer basic operations
    - MSB-first ordering matches the decoder's get_bits (MP3Types)
    - Round-trip with TMP3BitStream (MP3BitStream)
    - Alignment and reset
}

uses
  SysUtils,
  MP3EncTypes,    // encoder types (smoke test: just needs to compile)
  MP3EncBitWriter,
  MP3Types,       // for get_bits / bs_init
  MP3BitStream;   // for TMP3BitStream round-trip

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
// BW01-BW02: Construction
// ---------------------------------------------------------------------------

procedure TestConstruct;
var W: TMP3BitWriter;
begin
  W := TMP3BitWriter.Create;
  try
    Check('BW01 BitCount=0 after create',  W.GetBitCount  = 0);
    Check('BW02 ByteCount=0 after create', W.GetByteCount = 0);
  finally W.Free; end;
end;

// ---------------------------------------------------------------------------
// BW03-BW06: Basic WriteBits + GetBytes
// ---------------------------------------------------------------------------

procedure TestBasicWrite;
var
  W: TMP3BitWriter;
  B: TBytes;
begin
  // BW03: Write 1 bit = 1
  W := TMP3BitWriter.Create;
  try
    W.WriteBits(1, 1);
    B := W.GetBytes;
    Check('BW03 Write 1 bit (1)', (Length(B) = 1) and (B[0] = $80));
  finally W.Free; end;

  // BW04: Write 1 bit = 0
  W := TMP3BitWriter.Create;
  try
    W.WriteBits(0, 1);
    B := W.GetBytes;
    Check('BW04 Write 1 bit (0)', (Length(B) = 1) and (B[0] = $00));
  finally W.Free; end;

  // BW05: Write 8 bits = 0xA5 → byte must be 0xA5
  W := TMP3BitWriter.Create;
  try
    W.WriteBits($A5, 8);
    B := W.GetBytes;
    Check('BW05 Write 8 bits 0xA5', (Length(B) = 1) and (B[0] = $A5));
  finally W.Free; end;

  // BW06: Write 16 bits = 0x1234 → two bytes [0x12, 0x34]
  W := TMP3BitWriter.Create;
  try
    W.WriteBits($1234, 16);
    B := W.GetBytes;
    Check('BW06 Write 16 bits 0x1234', (Length(B) = 2) and (B[0] = $12) and (B[1] = $34));
  finally W.Free; end;
end;

// ---------------------------------------------------------------------------
// BW07-BW08: Cross-byte writes
// ---------------------------------------------------------------------------

procedure TestCrossByte;
var
  W: TMP3BitWriter;
  B: TBytes;
begin
  // BW07: 4 bits (0xB) + 4 bits (0x7) → single byte 0xB7
  W := TMP3BitWriter.Create;
  try
    W.WriteBits($B, 4);
    W.WriteBits($7, 4);
    B := W.GetBytes;
    Check('BW07 4+4 bits → 0xB7', (Length(B) = 1) and (B[0] = $B7));
  finally W.Free; end;

  // BW08: 3 bits (5=101) + 5 bits (13=01101) → byte 10101101 = 0xAD
  W := TMP3BitWriter.Create;
  try
    W.WriteBits(5,  3);  // 101
    W.WriteBits(13, 5);  // 01101
    B := W.GetBytes;
    Check('BW08 3+5 bits → 0xAD', (Length(B) = 1) and (B[0] = $AD));
  finally W.Free; end;
end;

// ---------------------------------------------------------------------------
// BW09-BW10: AlignToByte and Reset
// ---------------------------------------------------------------------------

procedure TestAlignReset;
var
  W: TMP3BitWriter;
  B: TBytes;
begin
  // BW09: Write 3 bits, Align pads to 8, byte = 101_00000 = 0xA0
  W := TMP3BitWriter.Create;
  try
    W.WriteBits(5, 3);   // 101
    W.AlignToByte;
    B := W.GetBytes;
    Check('BW09 Align 3 bits → 0xA0', (Length(B) = 1) and (B[0] = $A0));
  finally W.Free; end;

  // BW10: Reset clears state
  W := TMP3BitWriter.Create;
  try
    W.WriteBits($FF, 8);
    W.Reset;
    Check('BW10 Reset clears BitCount', W.GetBitCount = 0);
    Check('BW11 Reset clears ByteCount', W.GetByteCount = 0);
  finally W.Free; end;
end;

// ---------------------------------------------------------------------------
// BW12-BW15: Compatibility with MP3Types.get_bits
// ---------------------------------------------------------------------------

procedure TestGetBitsCompat;
var
  W  : TMP3BitWriter;
  B  : TBytes;
  BS : TBsT;
  V  : Cardinal;
begin
  // BW12: Single byte 0x5A round-trips through get_bits(8)
  W := TMP3BitWriter.Create;
  try
    W.WriteBits($5A, 8);
    B := W.GetBytes;
    bs_init(BS, @B[0], Length(B));
    V := get_bits(BS, 8);
    Check('BW12 get_bits(8) = 0x5A', V = $5A);
  finally W.Free; end;

  // BW13: Two packed nibbles 0xC and 0x3 → 0xC3 read as one byte
  W := TMP3BitWriter.Create;
  try
    W.WriteBits($C, 4);
    W.WriteBits($3, 4);
    B := W.GetBytes;
    bs_init(BS, @B[0], Length(B));
    V := get_bits(BS, 8);
    Check('BW13 4+4 → get_bits(8) = 0xC3', V = $C3);
  finally W.Free; end;

  // BW14: 12-bit value 0xABC packed across two bytes
  W := TMP3BitWriter.Create;
  try
    W.WriteBits($ABC, 12);
    B := W.GetBytes;
    bs_init(BS, @B[0], Length(B));
    V := get_bits(BS, 12);
    Check('BW14 get_bits(12) = 0xABC', V = $ABC);
  finally W.Free; end;

  // BW15: Sequential reads: write 5+7 bits, read 5 then 7
  W := TMP3BitWriter.Create;
  try
    W.WriteBits(21, 5);   // 10101
    W.WriteBits(99, 7);   // 1100011
    B := W.GetBytes;
    bs_init(BS, @B[0], Length(B));
    V := get_bits(BS, 5);
    Check('BW15a get_bits(5) = 21', V = 21);
    V := get_bits(BS, 7);
    Check('BW15b get_bits(7) = 99', V = 99);
  finally W.Free; end;
end;

// ---------------------------------------------------------------------------
// BW16-BW20: Round-trip with TMP3BitStream
// ---------------------------------------------------------------------------

procedure TestBitStreamCompat;
var
  W  : TMP3BitWriter;
  B  : TBytes;
  BS : TMP3BitStream;
  V  : Cardinal;
begin
  // BW16: ReadBits(8) from bit stream matches WriteBits(8)
  W := TMP3BitWriter.Create;
  try
    W.WriteBits($E7, 8);
    B := W.GetBytes;
    BS := TMP3BitStream.Create(B);
    try
      V := BS.ReadBits(8);
      Check('BW16 TMP3BitStream ReadBits(8) = 0xE7', V = $E7);
    finally BS.Free; end;
  finally W.Free; end;

  // BW17: 3-bit + 5-bit: ReadBits(3) then ReadBits(5)
  W := TMP3BitWriter.Create;
  try
    W.WriteBits(7, 3);   // 111
    W.WriteBits(18, 5);  // 10010
    B := W.GetBytes;
    BS := TMP3BitStream.Create(B);
    try
      V := BS.ReadBits(3);
      Check('BW17a ReadBits(3) = 7', V = 7);
      V := BS.ReadBits(5);
      Check('BW17b ReadBits(5) = 18', V = 18);
    finally BS.Free; end;
  finally W.Free; end;

  // BW18: 16-bit + 4-bit across 3 bytes
  W := TMP3BitWriter.Create;
  try
    W.WriteBits($ABCD, 16);
    W.WriteBits($A, 4);
    B := W.GetBytes;
    BS := TMP3BitStream.Create(B);
    try
      V := BS.ReadBits(16);
      Check('BW18a ReadBits(16) = 0xABCD', V = $ABCD);
      V := BS.ReadBits(4);
      Check('BW18b ReadBits(4) = 0xA', V = $A);
    finally BS.Free; end;
  finally W.Free; end;

  // BW19: 24-bit value 0x123456
  W := TMP3BitWriter.Create;
  try
    W.WriteBits($123456, 24);
    B := W.GetBytes;
    BS := TMP3BitStream.Create(B);
    try
      V := BS.ReadBits(24);
      Check('BW19 ReadBits(24) = 0x123456', V = $123456);
    finally BS.Free; end;
  finally W.Free; end;

  // BW20: BitCount tracks correctly over multiple writes
  W := TMP3BitWriter.Create;
  try
    W.WriteBits(1, 4);
    W.WriteBits(2, 4);
    W.WriteBits(3, 8);
    Check('BW20 BitCount=16 after 4+4+8', W.GetBitCount = 16);
  finally W.Free; end;
end;

// ---------------------------------------------------------------------------

begin
  GTotal  := 0;
  GPassed := 0;

  WriteLn('MP3 Encoder Phase 1 — BitWriter tests');
  WriteLn('--------------------------------------');

  TestConstruct;
  TestBasicWrite;
  TestCrossByte;
  TestAlignReset;
  TestGetBitsCompat;
  TestBitStreamCompat;

  WriteLn('--------------------------------------');
  WriteLn(GPassed, '/', GTotal, ' tests passed.');
  if GPassed < GTotal then Halt(1);
end.
