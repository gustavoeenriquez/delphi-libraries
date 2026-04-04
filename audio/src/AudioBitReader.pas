unit AudioBitReader;

{
  AudioBitReader.pas - Bit-level reader for compressed audio streams

  Provides MSB-first and LSB-first bit reading over a memory buffer.
  Used by flac-codec, ogg-container, vorbis-decoder, opus-decoder.

  MSB-first (boMSBFirst): FLAC, Ogg pages, Vorbis, Opus, MP3
  LSB-first (boLSBFirst): some auxiliary container fields

  All functions operate on TAudioBitReader defined in AudioTypes.pas.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  AudioTypes;

// ---------------------------------------------------------------------------
// Initialisation
// ---------------------------------------------------------------------------

// Point the reader at a memory region; BitOrder sets MSB/LSB convention.
// Limit is expressed in BYTES; internally converted to bits.
procedure BrInit(var Br: TAudioBitReader; Data: PByte; ByteCount: Integer;
  Order: TBitOrder = boMSBFirst);

// Re-initialise with a new buffer, preserving the bit-order setting.
procedure BrReset(var Br: TAudioBitReader; Data: PByte; ByteCount: Integer);

// ---------------------------------------------------------------------------
// Status queries
// ---------------------------------------------------------------------------

// Number of bits still available (not yet consumed).
function BrBitsLeft(const Br: TAudioBitReader): Integer; inline;

// True when all bits have been consumed.
function BrEOF(const Br: TAudioBitReader): Boolean; inline;

// ---------------------------------------------------------------------------
// Reading — MSB-first  (FLAC, Vorbis, Opus, MP3)
// ---------------------------------------------------------------------------

// Read N bits (1..32), advancing the position. MSB-first.
// Caller must ensure N <= BrBitsLeft.
function BrReadMSB(var Br: TAudioBitReader; N: Integer): Cardinal;

// Peek N bits without advancing. MSB-first.
function BrPeekMSB(const Br: TAudioBitReader; N: Integer): Cardinal;

// ---------------------------------------------------------------------------
// Reading — LSB-first
// ---------------------------------------------------------------------------

// Read N bits (1..32), advancing the position. LSB-first.
function BrReadLSB(var Br: TAudioBitReader; N: Integer): Cardinal;

// Peek N bits without advancing. LSB-first.
function BrPeekLSB(const Br: TAudioBitReader; N: Integer): Cardinal;

// ---------------------------------------------------------------------------
// Polymorphic wrappers — use the order stored in the record
// ---------------------------------------------------------------------------

function  BrRead(var Br: TAudioBitReader; N: Integer): Cardinal; inline;
function  BrPeek(const Br: TAudioBitReader; N: Integer): Cardinal; inline;
procedure BrSkip(var Br: TAudioBitReader; N: Integer); inline;

// ---------------------------------------------------------------------------
// Alignment helpers
// ---------------------------------------------------------------------------

// Discard bits until the position is on a byte boundary.
procedure BrByteAlign(var Br: TAudioBitReader);

// Current byte offset (rounded down).
function BrBytePos(const Br: TAudioBitReader): Integer; inline;

// ---------------------------------------------------------------------------
// FLAC / Vorbis unary and Exp-Golomb helpers
// ---------------------------------------------------------------------------

// Read a unary (truncated) value: count 0 bits until the first 1 bit.
// Returns the count of leading zeros. MSB-first.
function BrReadUnary(var Br: TAudioBitReader): Cardinal;

// Read a signed integer of N bits (two's complement sign-extension). MSB-first.
function BrReadSignedMSB(var Br: TAudioBitReader; N: Integer): Integer;

// ---------------------------------------------------------------------------
// Rice coding (FLAC residuals)
// ---------------------------------------------------------------------------

// Decode one Rice(k)-coded signed integer.
// Uses unary quotient then k-bit remainder, MSB-first.
function BrReadRiceSigned(var Br: TAudioBitReader; K: Integer): Integer;

implementation

// ---------------------------------------------------------------------------
// Internal helper: extract N bits starting at bit offset Pos from Buf (MSB).
// N must be 1..32 and (Pos+N) <= Limit.
// ---------------------------------------------------------------------------

function ExtractMSB(Buf: PByte; Pos, N: Integer): Cardinal;
var
  ByteIdx, BitOff, Remaining, Take, Shift: Integer;
  B: Byte;
begin
  Result    := 0;
  ByteIdx   := Pos shr 3;           // div 8
  BitOff    := Pos and 7;           // mod 8  (0 = MSB of byte)
  Remaining := N;

  while Remaining > 0 do
  begin
    B    := PByte(Buf + ByteIdx)^;
    Take := 8 - BitOff;             // bits available in this byte
    if Take > Remaining then
      Take := Remaining;
    Shift  := 8 - BitOff - Take;    // how many bits to shift right
    Result := (Result shl Take) or ((B shr Shift) and ((1 shl Take) - 1));
    Remaining := Remaining - Take;
    Inc(ByteIdx);
    BitOff := 0;
  end;
end;

// ---------------------------------------------------------------------------
// Internal helper: extract N bits at Pos (LSB-first).
// ---------------------------------------------------------------------------

function ExtractLSB(Buf: PByte; Pos, N: Integer): Cardinal;
var
  ByteIdx, BitOff, Remaining, Take: Integer;
  B: Byte;
  OutShift: Integer;
begin
  Result   := 0;
  ByteIdx  := Pos shr 3;
  BitOff   := Pos and 7;
  Remaining:= N;
  OutShift := 0;

  while Remaining > 0 do
  begin
    B    := PByte(Buf + ByteIdx)^;
    Take := 8 - BitOff;
    if Take > Remaining then
      Take := Remaining;
    Result := Result or (Cardinal((B shr BitOff) and ((1 shl Take) - 1)) shl OutShift);
    OutShift  := OutShift + Take;
    Remaining := Remaining - Take;
    Inc(ByteIdx);
    BitOff := 0;
  end;
end;

// ---------------------------------------------------------------------------
// Initialisation
// ---------------------------------------------------------------------------

procedure BrInit(var Br: TAudioBitReader; Data: PByte; ByteCount: Integer;
  Order: TBitOrder);
begin
  Br.Buf      := Data;
  Br.Pos      := 0;
  Br.Limit    := ByteCount shl 3;  // bytes → bits
  Br.BitOrder := Order;
end;

procedure BrReset(var Br: TAudioBitReader; Data: PByte; ByteCount: Integer);
begin
  Br.Buf   := Data;
  Br.Pos   := 0;
  Br.Limit := ByteCount shl 3;
end;

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

function BrBitsLeft(const Br: TAudioBitReader): Integer;
begin
  Result := Br.Limit - Br.Pos;
end;

function BrEOF(const Br: TAudioBitReader): Boolean;
begin
  Result := Br.Pos >= Br.Limit;
end;

// ---------------------------------------------------------------------------
// MSB-first
// ---------------------------------------------------------------------------

function BrReadMSB(var Br: TAudioBitReader; N: Integer): Cardinal;
begin
  Result := ExtractMSB(Br.Buf, Br.Pos, N);
  Inc(Br.Pos, N);
end;

function BrPeekMSB(const Br: TAudioBitReader; N: Integer): Cardinal;
begin
  Result := ExtractMSB(Br.Buf, Br.Pos, N);
end;

// ---------------------------------------------------------------------------
// LSB-first
// ---------------------------------------------------------------------------

function BrReadLSB(var Br: TAudioBitReader; N: Integer): Cardinal;
begin
  Result := ExtractLSB(Br.Buf, Br.Pos, N);
  Inc(Br.Pos, N);
end;

function BrPeekLSB(const Br: TAudioBitReader; N: Integer): Cardinal;
begin
  Result := ExtractLSB(Br.Buf, Br.Pos, N);
end;

// ---------------------------------------------------------------------------
// Polymorphic
// ---------------------------------------------------------------------------

function BrRead(var Br: TAudioBitReader; N: Integer): Cardinal;
begin
  if Br.BitOrder = boMSBFirst then
    Result := BrReadMSB(Br, N)
  else
    Result := BrReadLSB(Br, N);
end;

function BrPeek(const Br: TAudioBitReader; N: Integer): Cardinal;
begin
  if Br.BitOrder = boMSBFirst then
    Result := BrPeekMSB(Br, N)
  else
    Result := BrPeekLSB(Br, N);
end;

procedure BrSkip(var Br: TAudioBitReader; N: Integer);
begin
  Inc(Br.Pos, N);
end;

// ---------------------------------------------------------------------------
// Alignment
// ---------------------------------------------------------------------------

procedure BrByteAlign(var Br: TAudioBitReader);
var
  Rem: Integer;
begin
  Rem := Br.Pos and 7;  // bits into current byte
  if Rem <> 0 then
    Inc(Br.Pos, 8 - Rem);
end;

function BrBytePos(const Br: TAudioBitReader): Integer;
begin
  Result := Br.Pos shr 3;
end;

// ---------------------------------------------------------------------------
// Unary and signed
// ---------------------------------------------------------------------------

function BrReadUnary(var Br: TAudioBitReader): Cardinal;
begin
  Result := 0;
  // Count leading zero bits (MSB-first)
  while (Br.Pos < Br.Limit) and (BrReadMSB(Br, 1) = 0) do
    Inc(Result);
  // The terminating '1' bit has already been consumed by BrReadMSB above
end;

function BrReadSignedMSB(var Br: TAudioBitReader; N: Integer): Integer;
var
  V: Cardinal;
  SignBit: Cardinal;
begin
  V := BrReadMSB(Br, N);
  SignBit := Cardinal(1) shl (N - 1);
  if (V and SignBit) <> 0 then
    // Two's complement sign extension
    Result := Integer(V or (not (SignBit - 1)))
  else
    Result := Integer(V);
end;

// ---------------------------------------------------------------------------
// Rice coding
// ---------------------------------------------------------------------------

function BrReadRiceSigned(var Br: TAudioBitReader; K: Integer): Integer;
var
  Q, R, Unsigned: Cardinal;
begin
  Q        := BrReadUnary(Br);          // quotient: count of leading zeros
  if K > 0 then
    R      := BrReadMSB(Br, K)          // remainder
  else
    R      := 0;
  Unsigned := (Q shl K) or R;
  // Zig-zag decode: even → positive, odd → negative
  if (Unsigned and 1) = 0 then
    Result := Integer(Unsigned shr 1)
  else
    Result := -Integer((Unsigned + 1) shr 1);
end;

end.
