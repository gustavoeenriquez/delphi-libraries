unit FLACBitReader;

{
  FLACBitReader.pas - FLAC-specific bit-reader helpers

  Thin layer on top of AudioBitReader that adds:
    - UTF-8 encoded integer reading (FLAC frame/sample numbers, up to 36 bits)
    - CRC-8/CRC-16 accumulation during reading
    - Convenience re-exports of commonly used AudioBitReader functions

  All FLAC bitstream data is MSB-first (boMSBFirst).

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  AudioTypes,
  AudioBitReader,
  AudioCRC;

// ---------------------------------------------------------------------------
// Convenience re-exports (thin wrappers keep call-site code readable)
// ---------------------------------------------------------------------------

// Read N bits MSB-first and advance.
function FBrRead(var Br: TAudioBitReader; N: Integer): Cardinal; inline;

// Read signed N-bit value MSB-first.
function FBrReadSigned(var Br: TAudioBitReader; N: Integer): Integer; inline;

// Skip N bits.
procedure FBrSkip(var Br: TAudioBitReader; N: Integer); inline;

// Align to byte boundary.
procedure FBrAlign(var Br: TAudioBitReader); inline;

// Read unary (count leading zeros, consume terminating 1).
function FBrUnary(var Br: TAudioBitReader): Cardinal; inline;

// Read Rice-signed residual with parameter K.
function FBrRiceSigned(var Br: TAudioBitReader; K: Integer): Integer; inline;

// ---------------------------------------------------------------------------
// UTF-8 encoded integer (FLAC frame/sample number)
// Decodes the variable-length UTF-8 encoding used in FLAC frame headers.
// For fixed blocking: frame number (up to 31 bits → max 6 bytes).
// For variable blocking: sample number (up to 36 bits → max 7 bytes).
// Reads bytes from Buf[] starting at byte position BytePos.
// Returns the decoded value; advances BytePos past the encoded bytes.
// Returns -1 on error (invalid byte sequence).
// ---------------------------------------------------------------------------

function FLACReadUTF8Int(Buf: PByte; var BytePos: Integer; BufLen: Integer;
  out Value: Int64): Boolean;

// ---------------------------------------------------------------------------
// CRC-tracked read helpers
// These update a running CRC-8 or CRC-16 while consuming bytes.
// Use when building a CRC over bytes as they are parsed.
// ---------------------------------------------------------------------------

// Read one byte from Buf at BytePos, update Crc8, advance BytePos.
function FBrReadByteCRC8(Buf: PByte; var BytePos: Integer; var Crc8: Byte): Byte;

// Read one byte, update Crc16.
function FBrReadByteCRC16(Buf: PByte; var BytePos: Integer; var Crc16: Word): Byte;

implementation

// ---------------------------------------------------------------------------
// Inline re-exports
// ---------------------------------------------------------------------------

function FBrRead(var Br: TAudioBitReader; N: Integer): Cardinal;
begin
  Result := BrReadMSB(Br, N);
end;

function FBrReadSigned(var Br: TAudioBitReader; N: Integer): Integer;
begin
  Result := BrReadSignedMSB(Br, N);
end;

procedure FBrSkip(var Br: TAudioBitReader; N: Integer);
begin
  BrSkip(Br, N);
end;

procedure FBrAlign(var Br: TAudioBitReader);
begin
  BrByteAlign(Br);
end;

function FBrUnary(var Br: TAudioBitReader): Cardinal;
begin
  Result := BrReadUnary(Br);
end;

function FBrRiceSigned(var Br: TAudioBitReader; K: Integer): Integer;
begin
  Result := BrReadRiceSigned(Br, K);
end;

// ---------------------------------------------------------------------------
// UTF-8 integer decoding (FLAC extension: up to 7 bytes = 36 bits)
// ---------------------------------------------------------------------------

function FLACReadUTF8Int(Buf: PByte; var BytePos: Integer; BufLen: Integer;
  out Value: Int64): Boolean;
var
  First     : Byte;
  ExtraBytes: Integer;
  I         : Integer;
  B         : Byte;
begin
  Result := False;
  Value  := 0;

  if BytePos >= BufLen then Exit;
  First := (Buf + BytePos)^;
  Inc(BytePos);

  if (First and $80) = 0 then
  begin
    // 0xxxxxxx — 7 bits, 1 byte
    Value      := First;
    Result     := True;
    Exit;
  end;

  // Determine byte count from leading ones:
  // 110xxxxx = 2 bytes (11 bits)
  // 1110xxxx = 3 bytes (16 bits)
  // 11110xxx = 4 bytes (21 bits)
  // 111110xx = 5 bytes (26 bits)
  // 1111110x = 6 bytes (31 bits)
  // 11111110 = 7 bytes (36 bits)
  if    (First and $FE) = $FC then ExtraBytes := 5  // 1111110x
  else if (First and $FE) = $FE then ExtraBytes := 6  // 11111110 (36-bit)
  else if (First and $FC) = $F8 then ExtraBytes := 4  // 111110xx
  else if (First and $F8) = $F0 then ExtraBytes := 3  // 11110xxx
  else if (First and $F0) = $E0 then ExtraBytes := 2  // 1110xxxx
  else if (First and $E0) = $C0 then ExtraBytes := 1  // 110xxxxx
  else Exit; // invalid leading byte

  if BytePos + ExtraBytes > BufLen then Exit;

  // Extract data bits from the first byte
  case ExtraBytes of
    1: Value := First and $1F;
    2: Value := First and $0F;
    3: Value := First and $07;
    4: Value := First and $03;
    5: Value := First and $01;
    6: Value := 0;  // 11111110: no data bits in first byte
  end;

  // Read continuation bytes (each contributes 6 bits)
  for I := 1 to ExtraBytes do
  begin
    B := (Buf + BytePos)^;
    Inc(BytePos);
    if (B and $C0) <> $80 then Exit;  // not a continuation byte
    Value := (Value shl 6) or (B and $3F);
  end;

  Result := True;
end;

// ---------------------------------------------------------------------------
// CRC-tracked byte reads
// ---------------------------------------------------------------------------

function FBrReadByteCRC8(Buf: PByte; var BytePos: Integer; var Crc8: Byte): Byte;
begin
  Result := (Buf + BytePos)^;
  Inc(BytePos);
  Crc8 := CRC8_Update(Crc8, @Result, 1);
end;

function FBrReadByteCRC16(Buf: PByte; var BytePos: Integer; var Crc16: Word): Byte;
begin
  Result := (Buf + BytePos)^;
  Inc(BytePos);
  Crc16 := CRC16_Update(Crc16, @Result, 1);
end;

end.
