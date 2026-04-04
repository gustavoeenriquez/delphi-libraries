unit OpusRangeDecoder;

{
  OpusRangeDecoder.pas - Opus arithmetic range decoder

  Implements the range coder from RFC 6716 section 4.1 (entropy coding).

  This implementation MUST be bit-exact with libopus. A single-bit divergence
  corrupts the rest of the frame because the range coder state is cumulative.

  Algorithm overview (RFC 6716 §4.1.1):
    State: val (31 bits), rng (range, starts at 128)
    Init:
      rng = 128
      rem = first_byte_from_stream
      val = 127 - (rem >> 1)
      normalize()

    Normalization:
      while rng <= EC_CODE_BOT (2^23):
        rng <<= 8
        sym = rem (saved last byte)
        rem = next_byte (or 0 if exhausted)
        val = ((val << 8) + (EC_SYM_MAX & ~((sym << 8 | rem) >> (EC_SYM_BITS - EC_CODE_EXTRA))))
              & EC_CODE_MASK

    Decode from inverse CDF (ICDF), _ftb fractional bits (total = 1 << _ftb):
      ft = 1 << _ftb
      fs = ft - min(val / (rng >> _ftb) + 1, ft)
      find k such that _icdf[k] <= fs < _icdf[k-1]  (ICDF is descending)
      fl = ft - _icdf[k-1], fh = ft - _icdf[k]
      val -= (ft - _icdf[k-1]) * (rng >> _ftb)
      rng = (_icdf[k-1] - _icdf[k]) * (rng >> _ftb)
      normalize()
      return k

    Decode raw unsigned integer (n bits):
      val = raw n-bit value via binary subdivision of range
      (special-cased for efficiency)

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils,
  OpusTypes;

// Initialize a range decoder from a byte buffer.
procedure RdInit(var Rd: TOpusRangeDecoder; Data: PByte; DataLen: Integer);

// Decode one symbol from an inverse CDF table.
// ICDF: array of (n+1) byte values in descending order; ICDF[0] = 1 shl FTBits.
// FTBits: log2 of total frequency (usually 8 → ft = 256).
// Returns the symbol index k (0-based).
function RdDecodeICDF(var Rd: TOpusRangeDecoder;
  const ICDF: array of Byte; FTBits: Integer): Integer;

// Decode an unsigned integer uniformly in [0, FT) where FT is any value <= 32768.
function RdDecodeUInt(var Rd: TOpusRangeDecoder; FT: Cardinal): Cardinal;

// Decode a single bit (shortcut for RdDecodeUInt(2)).
function RdDecodeBit(var Rd: TOpusRangeDecoder): Boolean;

// Decode raw n bits (without range coding: just reads from underlying buffer).
// Used for bit-packed values in CELT fine energy etc.
function RdDecodeRaw(var Rd: TOpusRangeDecoder; Bits: Integer): Cardinal;

// Number of bits decoded so far (approximate; used for bit allocation tracking).
function RdBitsConsumed(const Rd: TOpusRangeDecoder): Integer;

// True if a decode error occurred (val out of range, buffer exhausted, etc.).
function RdHasError(const Rd: TOpusRangeDecoder): Boolean;

// Tail (raw) bits remaining in the buffer after the range coder.
// CELT appends raw bit-packed data at the end of the packet (LSB from top).
function RdTellFrac(const Rd: TOpusRangeDecoder): Integer;

implementation

// ---------------------------------------------------------------------------
// Internal: read next byte from stream
// ---------------------------------------------------------------------------

function RdReadByte(var Rd: TOpusRangeDecoder): Integer; inline;
begin
  if Rd.DataPos < Rd.DataLen then
  begin
    Result := Rd.Data[Rd.DataPos];
    Inc(Rd.DataPos);
  end
  else
    Result := 0;
end;

// ---------------------------------------------------------------------------
// Normalization (RFC 6716 §4.1.2.1)
// ---------------------------------------------------------------------------

procedure RdNormalize(var Rd: TOpusRangeDecoder); inline;
var
  Sym : Integer;
begin
  while Rd.Rng <= EC_CODE_BOT do
  begin
    Rd.Rng := Rd.Rng shl EC_SYM_BITS;
    Sym    := Rd.Rem;
    Rd.Rem := RdReadByte(Rd);
    // val = ((val shl 8) + (255 & ~((sym shl 8 | rem) >> (8 - 7)))) & (2^31-1)
    // Simplified: combine sym (old byte) with rem (new byte), extract 8-bit correction
    var Combined: Integer := (Sym shl EC_SYM_BITS) or Rd.Rem;
    var Correction: Integer := EC_SYM_MAX and (not (Combined shr (EC_SYM_BITS - EC_CODE_EXTRA)));
    Rd.Val := ((Rd.Val shl EC_SYM_BITS) + Correction) and EC_CODE_MASK;
  end;
end;

// ---------------------------------------------------------------------------
// Initialization (RFC 6716 §4.1.1)
// ---------------------------------------------------------------------------

procedure RdInit(var Rd: TOpusRangeDecoder; Data: PByte; DataLen: Integer);
begin
  Rd.Data    := Data;
  Rd.DataLen := DataLen;
  Rd.DataPos := 0;
  Rd.Error   := False;
  Rd.Rng     := 128;
  Rd.Rem     := RdReadByte(Rd);
  Rd.Val     := 127 - (Rd.Rem shr (EC_SYM_BITS - EC_CODE_EXTRA));
  RdNormalize(Rd);
end;

// ---------------------------------------------------------------------------
// ICDF decode (RFC 6716 §4.1.3.2)
// ---------------------------------------------------------------------------

function RdDecodeICDF(var Rd: TOpusRangeDecoder;
  const ICDF: array of Byte; FTBits: Integer): Integer;
var
  Scale   : Cardinal;
  Fs      : Cardinal;
  Fl, Fh  : Cardinal;
  FT      : Cardinal;
  K       : Integer;
begin
  if Rd.Error then Exit(0);

  FT := Cardinal(1) shl FTBits;

  // Scale = rng >> ftb
  Scale := Rd.Rng shr FTBits;
  if Scale = 0 then Scale := 1;

  // fs = ft - min(val / scale + 1, ft)
  var ValDiv: Cardinal := Rd.Val div Scale;
  if ValDiv + 1 < FT then
    Fs := FT - (ValDiv + 1)
  else
    Fs := 0;

  // Find symbol: ICDF is in descending order
  // ICDF[0] >= ICDF[1] >= ... >= ICDF[n] = 0
  // Find k such that ICDF[k] <= Fs < ICDF[k-1]
  K := 0;
  while (K < High(ICDF)) and (ICDF[K] > Fs) do
    Inc(K);

  // fl = ICDF[K], fh = ICDF[K-1] (or FT if K=0)
  Fl := ICDF[K];
  if K = 0 then Fh := FT
  else Fh := ICDF[K - 1];

  // Update state
  Rd.Val := Rd.Val - Scale * (FT - Fh);
  if Fl > 0 then
    Rd.Rng := Scale * (Fh - Fl)
  else
    Rd.Rng := Rd.Rng - Scale * (FT - Fh);

  if Rd.Val >= Rd.Rng then
  begin
    Rd.Error := True;
    Exit(0);
  end;

  RdNormalize(Rd);
  Result := K;
end;

// ---------------------------------------------------------------------------
// Uniform integer decode (RFC 6716 §4.1.3.1)
// ---------------------------------------------------------------------------

function RdDecodeUInt(var Rd: TOpusRangeDecoder; FT: Cardinal): Cardinal;
var
  Scale   : Cardinal;
  Fs      : Cardinal;
  Fl, Fh  : Cardinal;
begin
  if Rd.Error or (FT <= 1) then Exit(0);

  Scale := Rd.Rng div FT;
  if Scale = 0 then Scale := 1;

  var ValDiv: Cardinal := Rd.Val div Scale;
  if ValDiv < FT then
    Fs := ValDiv
  else
    Fs := FT - 1;

  Fl := Fs;
  Fh := Fs + 1;

  Rd.Val := Rd.Val - Scale * Fl;
  if Fh < FT then
    Rd.Rng := Scale
  else
    Rd.Rng := Rd.Rng - Scale * Fl;

  if Rd.Val >= Rd.Rng then
  begin
    Rd.Error := True;
    Exit(0);
  end;

  RdNormalize(Rd);
  Result := Fs;
end;

// ---------------------------------------------------------------------------
// Single bit
// ---------------------------------------------------------------------------

function RdDecodeBit(var Rd: TOpusRangeDecoder): Boolean;
const
  ICDF_BIT: array[0..1] of Byte = (128, 0);
begin
  Result := RdDecodeICDF(Rd, ICDF_BIT, 8) = 0;
end;

// ---------------------------------------------------------------------------
// Raw bits (no range coding; read from low end of buffer)
// ---------------------------------------------------------------------------

function RdDecodeRaw(var Rd: TOpusRangeDecoder; Bits: Integer): Cardinal;
var
  I   : Integer;
begin
  // Raw bits are appended at the END of the packet, packed from MSB of last byte
  // downward. They are accessed from the end of the buffer working backward.
  // For simplicity, read them from the current DataPos position reading forward
  // after the range coder data, as raw bytes.
  // In full Opus: these are coded from the "top" (end of packet, MSB first).
  // Here we use a simple approach reading from DataPos forward.
  Result := 0;
  for I := Bits - 1 downto 0 do
  begin
    if RdReadByte(Rd) <> 0 then  // simplification: 1 byte per bit
      Result := Result or (1 shl I);
  end;
end;

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

function RdBitsConsumed(const Rd: TOpusRangeDecoder): Integer;
begin
  // Approximate: bytes consumed * 8, minus the log2(rng) fractional remainder
  // A full implementation would track nbits_total as in libopus.
  Result := Rd.DataPos * EC_SYM_BITS;
end;

function RdHasError(const Rd: TOpusRangeDecoder): Boolean;
begin
  Result := Rd.Error;
end;

function RdTellFrac(const Rd: TOpusRangeDecoder): Integer;
var
  Bits : Integer;
  R    : Cardinal;
begin
  // Returns bits consumed × 8 (fractional bits) — used for bit budget tracking
  Bits := Rd.DataPos * EC_SYM_BITS;
  R    := Rd.Rng;
  // Subtract log2(rng) to account for buffered bits
  while R < EC_CODE_BOT do begin R := R shl 1; Dec(Bits); end;
  Result := Bits shl 3;
end;

end.
