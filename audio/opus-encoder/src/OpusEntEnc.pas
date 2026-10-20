unit OpusEntEnc;

{
  OpusEntEnc.pas - Opus range encoder (RFC 6716 section 5.1)

  Port of libopus 1.5.2 celt/entenc.c, celt/entcode.c (ec_tell*) and the
  encoder half of celt/laplace.c. Bit-exact with the reference encoder.

  Copyright (c) 2001-2011 Timothy B. Terriberry
  Copyright (c) 2008-2009 Xiph.Org Foundation
  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$Q-}{$R-}

interface

const
  EC_SYM_BITS    = 8;
  EC_CODE_BITS   = 32;
  EC_SYM_MAX     = (1 shl EC_SYM_BITS) - 1;
  EC_CODE_SHIFT  = EC_CODE_BITS - EC_SYM_BITS - 1;
  EC_CODE_TOP    = Cardinal(1) shl (EC_CODE_BITS - 1);
  EC_CODE_BOT    = EC_CODE_TOP shr EC_SYM_BITS;
  EC_UINT_BITS   = 8;
  EC_WINDOW_SIZE = 32;
  BITRES         = 3;

type
  TEcEnc = record
    Buf       : PByte;
    Storage   : Cardinal;
    EndOffs   : Cardinal;
    EndWindow : Cardinal;
    NEndBits  : Integer;
    NBitsTotal: Integer;
    Offs      : Cardinal;
    Rng       : Cardinal;
    Val       : Cardinal;
    Ext       : Cardinal;
    Rem       : Integer;
    Error     : Integer;
  end;
  PEcEnc = ^TEcEnc;

function  EcIlog(V: Cardinal): Integer; inline;
procedure EcEncInit(var E: TEcEnc; Buf: PByte; Size: Cardinal);
procedure EcEncode(var E: TEcEnc; Fl, Fh, Ft: Cardinal);
procedure EcEncodeBin(var E: TEcEnc; Fl, Fh, Bits: Cardinal);
procedure EcEncBitLogp(var E: TEcEnc; Val: Integer; Logp: Cardinal);
procedure EcEncIcdf(var E: TEcEnc; S: Integer; Icdf: PByte; Ftb: Cardinal);
procedure EcEncIcdf16(var E: TEcEnc; S: Integer; Icdf: PWord; Ftb: Cardinal);
procedure EcEncUInt(var E: TEcEnc; Fl, Ft: Cardinal);
procedure EcEncBits(var E: TEcEnc; Fl: Cardinal; Bits: Cardinal);
procedure EcEncPatchInitialBits(var E: TEcEnc; Val, NBits: Cardinal);
procedure EcEncShrink(var E: TEcEnc; Size: Cardinal);
procedure EcEncDone(var E: TEcEnc);
function  EcTell(const E: TEcEnc): Integer; inline;
function  EcTellFrac(const E: TEcEnc): Cardinal;
function  EcRangeBytes(const E: TEcEnc): Cardinal; inline;
procedure EcLaplaceEncode(var E: TEcEnc; var Value: Integer; Fs: Cardinal; Decay: Integer);

implementation

function EcIlog(V: Cardinal): Integer;
begin
  Result := 0;
  while V <> 0 do
  begin
    Inc(Result);
    V := V shr 1;
  end;
end;

function EcWriteByte(var E: TEcEnc; Value: Cardinal): Integer; inline;
begin
  if E.Offs + E.EndOffs >= E.Storage then Exit(-1);
  E.Buf[E.Offs] := Byte(Value);
  Inc(E.Offs);
  Result := 0;
end;

function EcWriteByteAtEnd(var E: TEcEnc; Value: Cardinal): Integer; inline;
begin
  if E.Offs + E.EndOffs >= E.Storage then Exit(-1);
  Inc(E.EndOffs);
  E.Buf[E.Storage - E.EndOffs] := Byte(Value);
  Result := 0;
end;

procedure EcEncCarryOut(var E: TEcEnc; C: Integer);
var
  Carry: Integer;
  Sym  : Cardinal;
begin
  if C <> EC_SYM_MAX then
  begin
    Carry := C shr EC_SYM_BITS;
    if E.Rem >= 0 then
      E.Error := E.Error or EcWriteByte(E, Cardinal(E.Rem + Carry));
    if E.Ext > 0 then
    begin
      Sym := Cardinal(EC_SYM_MAX + Carry) and EC_SYM_MAX;
      repeat
        E.Error := E.Error or EcWriteByte(E, Sym);
        Dec(E.Ext);
      until E.Ext = 0;
    end;
    E.Rem := C and EC_SYM_MAX;
  end
  else
    Inc(E.Ext);
end;

procedure EcEncNormalize(var E: TEcEnc); inline;
begin
  while E.Rng <= EC_CODE_BOT do
  begin
    EcEncCarryOut(E, Integer(E.Val shr EC_CODE_SHIFT));
    E.Val := (E.Val shl EC_SYM_BITS) and (EC_CODE_TOP - 1);
    E.Rng := E.Rng shl EC_SYM_BITS;
    Inc(E.NBitsTotal, EC_SYM_BITS);
  end;
end;

procedure EcEncInit(var E: TEcEnc; Buf: PByte; Size: Cardinal);
begin
  E.Buf := Buf;
  E.EndOffs := 0;
  E.EndWindow := 0;
  E.NEndBits := 0;
  E.NBitsTotal := EC_CODE_BITS + 1;
  E.Offs := 0;
  E.Rng := EC_CODE_TOP;
  E.Rem := -1;
  E.Val := 0;
  E.Ext := 0;
  E.Storage := Size;
  E.Error := 0;
end;

procedure EcEncode(var E: TEcEnc; Fl, Fh, Ft: Cardinal);
var
  R: Cardinal;
begin
  R := E.Rng div Ft;
  if Fl > 0 then
  begin
    E.Val := E.Val + E.Rng - R * (Ft - Fl);
    E.Rng := R * (Fh - Fl);
  end
  else
    E.Rng := E.Rng - R * (Ft - Fh);
  EcEncNormalize(E);
end;

procedure EcEncodeBin(var E: TEcEnc; Fl, Fh, Bits: Cardinal);
var
  R: Cardinal;
begin
  R := E.Rng shr Bits;
  if Fl > 0 then
  begin
    E.Val := E.Val + E.Rng - R * ((Cardinal(1) shl Bits) - Fl);
    E.Rng := R * (Fh - Fl);
  end
  else
    E.Rng := E.Rng - R * ((Cardinal(1) shl Bits) - Fh);
  EcEncNormalize(E);
end;

procedure EcEncBitLogp(var E: TEcEnc; Val: Integer; Logp: Cardinal);
var
  R, S, L: Cardinal;
begin
  R := E.Rng;
  L := E.Val;
  S := R shr Logp;
  R := R - S;
  if Val <> 0 then
  begin
    E.Val := L + R;
    E.Rng := S;
  end
  else
    E.Rng := R;
  EcEncNormalize(E);
end;

procedure EcEncIcdf(var E: TEcEnc; S: Integer; Icdf: PByte; Ftb: Cardinal);
var
  R: Cardinal;
begin
  R := E.Rng shr Ftb;
  if S > 0 then
  begin
    E.Val := E.Val + E.Rng - R * Icdf[S - 1];
    E.Rng := R * Cardinal(Icdf[S - 1] - Icdf[S]);
  end
  else
    E.Rng := E.Rng - R * Icdf[S];
  EcEncNormalize(E);
end;

procedure EcEncIcdf16(var E: TEcEnc; S: Integer; Icdf: PWord; Ftb: Cardinal);
var
  R: Cardinal;
begin
  R := E.Rng shr Ftb;
  if S > 0 then
  begin
    E.Val := E.Val + E.Rng - R * Icdf[S - 1];
    E.Rng := R * Cardinal(Icdf[S - 1] - Icdf[S]);
  end
  else
    E.Rng := E.Rng - R * Icdf[S];
  EcEncNormalize(E);
end;

procedure EcEncUInt(var E: TEcEnc; Fl, Ft: Cardinal);
var
  Ftb: Integer;
  Ft1, Fl1: Cardinal;
begin
  Dec(Ft);
  Ftb := EcIlog(Ft);
  if Ftb > EC_UINT_BITS then
  begin
    Dec(Ftb, EC_UINT_BITS);
    Ft1 := (Ft shr Ftb) + 1;
    Fl1 := Fl shr Ftb;
    EcEncode(E, Fl1, Fl1 + 1, Ft1);
    EcEncBits(E, Fl and ((Cardinal(1) shl Ftb) - 1), Ftb);
  end
  else
    EcEncode(E, Fl, Fl + 1, Ft + 1);
end;

procedure EcEncBits(var E: TEcEnc; Fl: Cardinal; Bits: Cardinal);
var
  Window: Cardinal;
  Used  : Integer;
begin
  Window := E.EndWindow;
  Used := E.NEndBits;
  if Used + Integer(Bits) > EC_WINDOW_SIZE then
  begin
    repeat
      E.Error := E.Error or EcWriteByteAtEnd(E, Window and EC_SYM_MAX);
      Window := Window shr EC_SYM_BITS;
      Dec(Used, EC_SYM_BITS);
    until Used < EC_SYM_BITS;
  end;
  Window := Window or (Fl shl Used);
  Inc(Used, Bits);
  E.EndWindow := Window;
  E.NEndBits := Used;
  Inc(E.NBitsTotal, Bits);
end;

procedure EcEncPatchInitialBits(var E: TEcEnc; Val, NBits: Cardinal);
var
  Shift: Integer;
  Mask : Cardinal;
begin
  Shift := EC_SYM_BITS - Integer(NBits);
  Mask := ((Cardinal(1) shl NBits) - 1) shl Shift;
  if E.Offs > 0 then
    E.Buf[0] := Byte((E.Buf[0] and not Mask) or (Val shl Shift))
  else if E.Rem >= 0 then
    E.Rem := Integer((Cardinal(E.Rem) and not Mask) or (Val shl Shift))
  else if E.Rng <= (EC_CODE_TOP shr NBits) then
    E.Val := (E.Val and not (Mask shl EC_CODE_SHIFT)) or (Val shl (EC_CODE_SHIFT + Shift))
  else
    E.Error := -1;
end;

procedure EcEncShrink(var E: TEcEnc; Size: Cardinal);
begin
  if E.EndOffs > 0 then
    Move(E.Buf[E.Storage - E.EndOffs], E.Buf[Size - E.EndOffs], E.EndOffs);
  E.Storage := Size;
end;

procedure EcEncDone(var E: TEcEnc);
var
  Window, Msk, EndV: Cardinal;
  Used, L: Integer;
begin
  L := EC_CODE_BITS - EcIlog(E.Rng);
  Msk := (EC_CODE_TOP - 1) shr L;
  EndV := (E.Val + Msk) and not Msk;
  if (EndV or Msk) >= E.Val + E.Rng then
  begin
    Inc(L);
    Msk := Msk shr 1;
    EndV := (E.Val + Msk) and not Msk;
  end;
  while L > 0 do
  begin
    EcEncCarryOut(E, Integer(EndV shr EC_CODE_SHIFT));
    EndV := (EndV shl EC_SYM_BITS) and (EC_CODE_TOP - 1);
    Dec(L, EC_SYM_BITS);
  end;
  if (E.Rem >= 0) or (E.Ext > 0) then
    EcEncCarryOut(E, 0);
  Window := E.EndWindow;
  Used := E.NEndBits;
  while Used >= EC_SYM_BITS do
  begin
    E.Error := E.Error or EcWriteByteAtEnd(E, Window and EC_SYM_MAX);
    Window := Window shr EC_SYM_BITS;
    Dec(Used, EC_SYM_BITS);
  end;
  if E.Error = 0 then
  begin
    if E.Storage > E.Offs + E.EndOffs then
      FillChar(E.Buf[E.Offs], E.Storage - E.Offs - E.EndOffs, 0);
    if Used > 0 then
    begin
      if E.EndOffs >= E.Storage then
        E.Error := -1
      else
      begin
        L := -L;
        if (E.Offs + E.EndOffs >= E.Storage) and (L < Used) then
        begin
          Window := Window and ((Cardinal(1) shl L) - 1);
          E.Error := -1;
        end;
        E.Buf[E.Storage - E.EndOffs - 1] := E.Buf[E.Storage - E.EndOffs - 1] or Byte(Window);
      end;
    end;
  end;
end;

function EcTell(const E: TEcEnc): Integer;
begin
  Result := E.NBitsTotal - EcIlog(E.Rng);
end;

function EcTellFrac(const E: TEcEnc): Cardinal;
const
  Correction: array[0..7] of Cardinal = (35733, 38967, 42495, 46340, 50535, 55109, 60097, 65535);
var
  NBits, R, B: Cardinal;
  L: Integer;
begin
  NBits := Cardinal(E.NBitsTotal) shl BITRES;
  L := EcIlog(E.Rng);
  R := E.Rng shr (L - 16);
  B := (R shr 12) - 8;
  if R > Correction[B] then Inc(B);
  L := (L shl 3) + Integer(B);
  Result := NBits - Cardinal(L);
end;

function EcRangeBytes(const E: TEcEnc): Cardinal;
begin
  Result := E.Offs;
end;

// ---------------------------------------------------------------------------
// Laplace (coarse energy), laplace.c
// ---------------------------------------------------------------------------

const
  LAPLACE_LOG_MINP = 0;
  LAPLACE_MINP     = 1 shl LAPLACE_LOG_MINP;
  LAPLACE_NMIN     = 16;

function EcLaplaceGetFreq1(Fs0: Cardinal; Decay: Integer): Cardinal; inline;
var
  Ft: Cardinal;
begin
  Ft := 32768 - LAPLACE_MINP * (2 * LAPLACE_NMIN) - Fs0;
  Result := (Ft * Cardinal(16384 - Decay)) shr 15;
end;

procedure EcLaplaceEncode(var E: TEcEnc; var Value: Integer; Fs: Cardinal; Decay: Integer);
var
  Fl: Cardinal;
  Val, S, I, Di, NdiMax: Integer;
begin
  Fl := 0;
  Val := Value;
  if Val <> 0 then
  begin
    if Val < 0 then S := -1 else S := 0;
    Val := (Val + S) xor S;
    Fl := Fs;
    Fs := EcLaplaceGetFreq1(Fs, Decay);
    I := 1;
    while (Fs > 0) and (I < Val) do
    begin
      Fs := Fs * 2;
      Fl := Fl + Fs + 2 * LAPLACE_MINP;
      Fs := (Fs * Cardinal(Decay)) shr 15;
      Inc(I);
    end;
    if Fs = 0 then
    begin
      NdiMax := Integer((32768 - Fl + LAPLACE_MINP - 1) shr LAPLACE_LOG_MINP);
      NdiMax := (NdiMax - S) shr 1;
      if Val - I < NdiMax - 1 then Di := Val - I else Di := NdiMax - 1;
      Fl := Fl + Cardinal((2 * Di + 1 + S) * LAPLACE_MINP);
      if LAPLACE_MINP < 32768 - Fl then Fs := LAPLACE_MINP else Fs := 32768 - Fl;
      Value := (I + Di + S) xor S;
    end
    else
    begin
      Fs := Fs + LAPLACE_MINP;
      Fl := Fl + (Fs and Cardinal(not S));
    end;
  end;
  EcEncodeBin(E, Fl, Fl + Fs, 15);
end;

end.
