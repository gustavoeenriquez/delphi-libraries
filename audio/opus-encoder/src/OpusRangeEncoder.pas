unit OpusRangeEncoder;

{
  OpusRangeEncoder.pas - Opus arithmetic range encoder (write side)

  Implements the range encoder from RFC 6716 section 4.1.
  This is the bit-exact inverse of OpusRangeDecoder.pas.

  Key differences from the decoder:
    Init:  rng = $80000000, val = 0, rem = -1 (no byte buffered)
    Decoder init: rng = 128, val derived from first input byte

  Carry propagation:
    The encoder defers the most recent byte into Rem and counts consecutive
    0xFF bytes in Ext. When a non-0xFF byte arrives, any pending carry
    propagates backward: Rem+1 is emitted and all Ext bytes become 0x00.

  Dual buffers:
    Range-coded bytes grow from buf[0] forward (Offs).
    Raw bits (ReEncodeRaw) grow from buf[Storage-1] backward (EndOffs).
    ReFlush zeroes the gap and OR's any partial raw byte.

  Reference: xiph/opus celt/entenc.c (MIT), Concentus EntropyCoder.cs (BSD-3)

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  OpusTypes,
  OpusEncTypes;

procedure ReInit(var Re: TOpusRangeEncoder; Buf: PByte; Storage: Cardinal);

// Encode one symbol via inverse CDF table (power-of-2 denominator).
// Sym:    symbol index (0-based).
// ICDF:   descending table; ICDF[0] = 1 shl FTBits; ICDF[last] = 0.
// FTBits: log2 of total frequency (usually 8).
procedure ReEncodeICDF(var Re: TOpusRangeEncoder;
  Sym: Integer; const ICDF: array of Byte; FTBits: Integer);

// Encode a uniform integer Val in [0, FT).
procedure ReEncodeUInt(var Re: TOpusRangeEncoder; Val, FT: Cardinal);

// Encode a single bit. prob(1) = 1 / 2^LogP.
procedure ReEncodeBit(var Re: TOpusRangeEncoder; Val: Boolean; LogP: Integer);

// Pack Bits raw bits into the END of the buffer (bypass mode).
procedure ReEncodeRaw(var Re: TOpusRangeEncoder; Val: Cardinal; Bits: Integer);

// Finalize encoding. Returns total bytes written into Buf.
function ReFlush(var Re: TOpusRangeEncoder): Integer;

// Symbolic bits encoded so far (excludes raw bits).
function ReTell(const Re: TOpusRangeEncoder): Integer;

// Fractional bits × 8 (3 fractional bits; mirrors RdTellFrac).
function ReTellFrac(const Re: TOpusRangeEncoder): Integer;

// Patch the first NbBits bits already in the pipeline (CELT mode signaling).
procedure RePatchInitialBits(var Re: TOpusRangeEncoder;
  Val: Cardinal; NbBits: Integer);

implementation

// ---------------------------------------------------------------------------
// Local constants not in OpusTypes
// ---------------------------------------------------------------------------

const
  // Encoder range starts at 2^31 (Cardinal — avoids signed overflow).
  RE_CODE_TOP  = Cardinal($80000000);
  // Maximum chunk size for uniform-integer high/low split.
  EC_UINT_BITS = 8;
  // Constantes del range coder (RFC 6716 §4.1 / entcode.h). Antes venían de
  // OpusTypes; la reescritura del decoder las movió a OpusEntDec.
  EC_SYM_BITS   = 8;
  EC_CODE_BITS  = 32;
  EC_SYM_MAX    = $FF;
  EC_CODE_BOT   = 1 shl 23;
  EC_CODE_SHIFT = EC_CODE_BITS - EC_SYM_BITS - 1;  // 23
  EC_CODE_MASK  = $7FFFFFFF;

// ---------------------------------------------------------------------------
// EcILog: position of highest set bit, 1-based. EcILog(0) = 0.
// Equivalent to libopus EC_ILOG / fls().
// ---------------------------------------------------------------------------

function EcILog(X: Cardinal): Integer; inline;
begin
  Result := 0;
  if X = 0 then Exit;
  // Binary-search for MSB — portable, no intrinsics needed.
  if X >= $00010000 then begin Inc(Result, 16); X := X shr 16; end;
  if X >= $00000100 then begin Inc(Result,  8); X := X shr  8; end;
  if X >= $00000010 then begin Inc(Result,  4); X := X shr  4; end;
  if X >= $00000004 then begin Inc(Result,  2); X := X shr  2; end;
  Inc(Result, Integer(X shr 1) + 1);
end;

// ---------------------------------------------------------------------------
// Internal: write one byte to the FRONT of the output buffer (range coder).
// ---------------------------------------------------------------------------

procedure ReWriteByte(var Re: TOpusRangeEncoder; B: Byte); inline;
begin
  if Re.Offs + Re.EndOffs >= Re.Storage then
    Re.Error := True
  else
  begin
    Re.Buf[Re.Offs] := B;
    Inc(Re.Offs);
  end;
end;

// Write one byte to the END of the output buffer (raw bits, inward).
procedure ReWriteByteAtEnd(var Re: TOpusRangeEncoder; B: Byte); inline;
begin
  if Re.Offs + Re.EndOffs >= Re.Storage then
    Re.Error := True
  else
  begin
    Inc(Re.EndOffs);
    Re.Buf[Re.Storage - Re.EndOffs] := B;
  end;
end;

// ---------------------------------------------------------------------------
// Internal: carry-deferred byte output.
//
// C is the 8- or 9-bit symbol from (val >> EC_CODE_SHIFT):
//   C = $FF: defer — may receive a carry later; increment Ext.
//   C <  $FF (or C = $100 with carry): resolve pending chain.
// ---------------------------------------------------------------------------

procedure ReCarryOut(var Re: TOpusRangeEncoder; C: Integer); inline;
var
  Carry: Integer;
  Sym  : Byte;
begin
  if C <> EC_SYM_MAX then
  begin
    Carry := C shr EC_SYM_BITS;   // 0 or 1
    // Flush the previously buffered byte with carry applied.
    if Re.Rem >= 0 then
      ReWriteByte(Re, Byte(Re.Rem + Carry));
    // Flush all pending 0xFF bytes: with carry they become 0x00, else 0xFF.
    if Re.Ext > 0 then
    begin
      Sym := Byte((EC_SYM_MAX + Carry) and EC_SYM_MAX);
      repeat
        ReWriteByte(Re, Sym);
        Dec(Re.Ext);
      until Re.Ext = 0;
    end;
    Re.Rem := C and EC_SYM_MAX;   // buffer the new low byte
  end
  else
    Inc(Re.Ext);  // 0xFF: defer — might carry
end;

// ---------------------------------------------------------------------------
// Internal: normalization — emit bytes while rng <= EC_CODE_BOT (2^23).
// ---------------------------------------------------------------------------

procedure ReNormalize(var Re: TOpusRangeEncoder); inline;
begin
  while Re.Rng <= EC_CODE_BOT do
  begin
    ReCarryOut(Re, Integer(Re.Val shr EC_CODE_SHIFT));
    Re.Val := (Re.Val shl EC_SYM_BITS) and EC_CODE_MASK;
    Re.Rng := Re.Rng shl EC_SYM_BITS;
    Inc(Re.NBitsTotal, EC_SYM_BITS);
  end;
end;

// ---------------------------------------------------------------------------
// Internal: core range update (general denominator, integer division).
// Fl=cumulative low, Fh=cumulative high, FT=total frequency.
// ---------------------------------------------------------------------------

procedure ReEncode(var Re: TOpusRangeEncoder;
  Fl, Fh, FT: Cardinal); inline;
var
  R: Cardinal;
begin
  R := Re.Rng div FT;
  if R = 0 then R := 1;
  if Fl > 0 then
  begin
    Re.Val := Re.Val + Re.Rng - R * (FT - Fl);
    Re.Rng := R * (Fh - Fl);
  end
  else
    Re.Rng := Re.Rng - R * (FT - Fh);
  ReNormalize(Re);
end;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

procedure ReInit(var Re: TOpusRangeEncoder; Buf: PByte; Storage: Cardinal);
begin
  FillChar(Re, SizeOf(Re), 0);
  Re.Buf        := Buf;
  Re.Storage    := Storage;
  Re.Rng        := RE_CODE_TOP;       // $80000000
  Re.Val        := 0;
  Re.Rem        := -1;                // sentinel: no byte buffered yet
  Re.Ext        := 0;
  Re.NBitsTotal := EC_CODE_BITS + 1;  // 33 (libopus convention)
end;

procedure ReEncodeICDF(var Re: TOpusRangeEncoder;
  Sym: Integer; const ICDF: array of Byte; FTBits: Integer);
var
  R: Cardinal;
begin
  if Re.Error then Exit;
  R := Re.Rng shr FTBits;   // ft = 1 << ftb; use shift (power-of-2 denom)
  if R = 0 then R := 1;
  if Sym > 0 then
  begin
    // Symbol occupies [FT - ICDF[Sym-1], FT - ICDF[Sym]) out of [0, FT)
    Re.Val := Re.Val + Re.Rng - R * ICDF[Sym - 1];
    Re.Rng := R * Cardinal(ICDF[Sym - 1] - ICDF[Sym]);
  end
  else
    Re.Rng := Re.Rng - R * ICDF[Sym];
  ReNormalize(Re);
end;

procedure ReEncodeUInt(var Re: TOpusRangeEncoder; Val, FT: Cardinal);
var
  FTb : Integer;
  Ftm : Cardinal;
begin
  if Re.Error or (FT <= 1) then Exit;
  Dec(FT);   // inclusive max
  FTb := EcILog(FT);
  if FTb > EC_UINT_BITS then
  begin
    // High part as symbol, low (FTb - EC_UINT_BITS) bits raw.
    Dec(FTb, EC_UINT_BITS);
    Ftm := (FT shr FTb) + 1;
    ReEncode(Re, Val shr FTb, (Val shr FTb) + 1, Ftm);
    ReEncodeRaw(Re, Val and ((Cardinal(1) shl FTb) - 1), FTb);
  end
  else
    ReEncode(Re, Val, Val + 1, FT + 1);
end;

procedure ReEncodeBit(var Re: TOpusRangeEncoder; Val: Boolean; LogP: Integer);
var
  R, S, L: Cardinal;
begin
  if Re.Error then Exit;
  R := Re.Rng;
  S := R shr LogP;   // prob(1) = 1 / 2^LogP
  if S = 0 then S := 1;
  L := R - S;
  if Val then
  begin
    Re.Val := Re.Val + L;
    Re.Rng := S;
  end
  else
    Re.Rng := L;
  ReNormalize(Re);
end;

procedure ReEncodeRaw(var Re: TOpusRangeEncoder; Val: Cardinal; Bits: Integer);
var
  Window: Cardinal;
  Used  : Integer;
begin
  if Re.Error or (Bits <= 0) then Exit;
  Window := Re.EndWindow;
  Used   := Re.NEndBits;
  // Flush full bytes from EndWindow before packing new bits.
  if Used + Bits > 32 then
  begin
    repeat
      ReWriteByteAtEnd(Re, Byte(Window and EC_SYM_MAX));
      Window := Window shr EC_SYM_BITS;
      Dec(Used, EC_SYM_BITS);
    until Used < EC_SYM_BITS;
  end;
  Re.EndWindow := Window or (Val shl Used);
  Re.NEndBits  := Used + Bits;
  Inc(Re.NBitsTotal, Bits);
end;

function ReFlush(var Re: TOpusRangeEncoder): Integer;
var
  L      : Integer;
  Msk    : Cardinal;
  EndVal : Cardinal;
  Window : Cardinal;
  Used   : Integer;
begin
  // Step 1: bits needed to pin down the final range interval.
  L := EC_CODE_BITS - EcILog(Re.Rng);

  // Step 2: shortest valid completion of val — round up to nearest 1<<L boundary.
  Msk    := (RE_CODE_TOP - 1) shr L;
  EndVal := (Re.Val + Msk) and (not Msk);
  if (EndVal or Msk) >= Re.Val + Re.Rng then
  begin
    Inc(L);
    Msk    := Msk shr 1;
    EndVal := (Re.Val + Msk) and (not Msk);
  end;

  // Step 3: emit L bits of EndVal through carry machinery (8 bits at a time).
  while L > 0 do
  begin
    ReCarryOut(Re, Integer(EndVal shr EC_CODE_SHIFT));
    EndVal := (EndVal shl EC_SYM_BITS) and EC_CODE_MASK;
    Dec(L, EC_SYM_BITS);
  end;

  // Step 4: flush any remaining Rem / Ext bytes.
  if (Re.Rem >= 0) or (Re.Ext > 0) then
    ReCarryOut(Re, 0);

  // Step 5: flush EndWindow raw bits to buffer end (byte at a time).
  Window := Re.EndWindow;
  Used   := Re.NEndBits;
  while Used >= EC_SYM_BITS do
  begin
    ReWriteByteAtEnd(Re, Byte(Window and EC_SYM_MAX));
    Window := Window shr EC_SYM_BITS;
    Dec(Used, EC_SYM_BITS);
  end;

  // Step 6: zero the middle gap; OR partial raw byte if one exists.
  if not Re.Error then
  begin
    FillChar(Re.Buf[Re.Offs],
      Integer(Re.Storage - Re.Offs - Re.EndOffs), 0);
    if Used > 0 then
    begin
      if Re.Offs + Re.EndOffs >= Re.Storage then
        Re.Error := True
      else
        Re.Buf[Re.Storage - Re.EndOffs - 1] :=
          Re.Buf[Re.Storage - Re.EndOffs - 1] or Byte(Window);
    end;
  end;

  Result := Integer(Re.Offs + Re.EndOffs);
end;

function ReTell(const Re: TOpusRangeEncoder): Integer;
begin
  // Symbolic bits used = nbits_total - floor(log2(rng))
  Result := Re.NBitsTotal - EcILog(Re.Rng);
end;

function ReTellFrac(const Re: TOpusRangeEncoder): Integer;
// Returns bits × 8 with 3 fractional bits (BITRES=3 in libopus).
// Algorithm: fixed-point log2 via repeated squaring.
var
  NbBits: Integer;
  R     : Cardinal;
  B, I  : Integer;
begin
  NbBits := Re.NBitsTotal shl 3;   // × 8 (BITRES=3 → shift by 3)
  R      := Re.Rng;
  for I := 2 downto 0 do           // 3 iterations for 3 fractional bits
  begin
    R := Cardinal(UInt64(R) * UInt64(R) shr 31);
    B := Integer(R shr 31);        // 0 or 1: top bit
    NbBits := NbBits or (B shl I);
    R := R shr B;
  end;
  Result := NbBits;
end;

procedure RePatchInitialBits(var Re: TOpusRangeEncoder;
  Val: Cardinal; NbBits: Integer);
var
  Shift: Integer;
  Mask : Cardinal;
begin
  Shift := EC_SYM_BITS - NbBits;
  Mask  := ((Cardinal(1) shl NbBits) - 1) shl Shift;
  if Re.Offs > 0 then
    Re.Buf[0] := Byte((Cardinal(Re.Buf[0]) and (not Mask)) or (Val shl Shift))
  else if Re.Rem >= 0 then
    Re.Rem := Integer((Cardinal(Re.Rem) and (not Mask)) or (Val shl Shift))
  else if Re.Rng <= (RE_CODE_TOP shr NbBits) then
    Re.Val := (Re.Val and (not (Mask shl EC_CODE_SHIFT)))
              or (Val shl (EC_CODE_SHIFT + Shift))
  else
    Re.Error := True;
end;

end.
