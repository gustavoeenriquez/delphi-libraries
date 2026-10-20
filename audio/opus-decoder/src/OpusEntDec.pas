unit OpusEntDec;

{
  OpusEntDec.pas - Opus range decoder (RFC 6716 section 4.1)

  Faithful port of libopus celt/entdec.c, entcode.c and laplace.c
  (Copyright (c) 2001-2011 Timothy B. Terriberry, 2008-2009 Xiph.Org
  Foundation, BSD license). Bit-exact with the reference decoder, which
  matters because bit allocation decisions depend on ec_tell().

  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$Q-}{$R-}

interface

const
  EC_SYM_BITS   = 8;
  EC_CODE_BITS  = 32;
  EC_SYM_MAX    = (1 shl EC_SYM_BITS) - 1;
  EC_CODE_SHIFT = EC_CODE_BITS - EC_SYM_BITS - 1;
  EC_CODE_TOP   = Cardinal(1) shl (EC_CODE_BITS - 1);
  EC_CODE_BOT   = EC_CODE_TOP shr EC_SYM_BITS;
  EC_CODE_EXTRA = ((EC_CODE_BITS - 2) mod EC_SYM_BITS) + 1;
  EC_UINT_BITS  = 8;
  EC_WINDOW_SIZE = 32;
  BITRES        = 3;

type
  TEcDec = record
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

function  EcIlog(V: Cardinal): Integer;
procedure EcDecInit(var D: TEcDec; Buf: PByte; Storage: Cardinal);
function  EcDecode(var D: TEcDec; Ft: Cardinal): Cardinal;
function  EcDecodeBin(var D: TEcDec; Bits: Cardinal): Cardinal;
procedure EcDecUpdate(var D: TEcDec; Fl, Fh, Ft: Cardinal);
function  EcDecBitLogp(var D: TEcDec; Logp: Cardinal): Integer;
function  EcDecIcdf(var D: TEcDec; Icdf: PByte; Ftb: Cardinal): Integer;
function  EcDecIcdf16(var D: TEcDec; Icdf: PWord; Ftb: Cardinal): Integer;
function  EcDecUInt(var D: TEcDec; Ft: Cardinal): Cardinal;
function  EcDecBits(var D: TEcDec; Bits: Cardinal): Cardinal;
function  EcTell(const D: TEcDec): Integer; inline;
function  EcTellFrac(const D: TEcDec): Cardinal;
function  EcLaplaceDecode(var D: TEcDec; Fs: Cardinal; Decay: Integer): Integer;

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

function EcReadByte(var D: TEcDec): Integer; inline;
begin
  if D.Offs < D.Storage then
  begin
    Result := D.Buf[D.Offs];
    Inc(D.Offs);
  end
  else
    Result := 0;
end;

function EcReadByteFromEnd(var D: TEcDec): Integer; inline;
begin
  if D.EndOffs < D.Storage then
  begin
    Inc(D.EndOffs);
    Result := D.Buf[D.Storage - D.EndOffs];
  end
  else
    Result := 0;
end;

procedure EcDecNormalize(var D: TEcDec);
var
  Sym: Integer;
begin
  while D.Rng <= EC_CODE_BOT do
  begin
    Inc(D.NBitsTotal, EC_SYM_BITS);
    D.Rng := D.Rng shl EC_SYM_BITS;
    Sym := D.Rem;
    D.Rem := EcReadByte(D);
    Sym := ((Sym shl EC_SYM_BITS) or D.Rem) shr (EC_SYM_BITS - EC_CODE_EXTRA);
    D.Val := ((D.Val shl EC_SYM_BITS) + Cardinal(EC_SYM_MAX and not Sym)) and (EC_CODE_TOP - 1);
  end;
end;

procedure EcDecInit(var D: TEcDec; Buf: PByte; Storage: Cardinal);
begin
  D.Buf       := Buf;
  D.Storage   := Storage;
  D.EndOffs   := 0;
  D.EndWindow := 0;
  D.NEndBits  := 0;
  D.NBitsTotal := EC_CODE_BITS + 1 - ((EC_CODE_BITS - EC_CODE_EXTRA) div EC_SYM_BITS) * EC_SYM_BITS;
  D.Offs      := 0;
  D.Rng       := Cardinal(1) shl EC_CODE_EXTRA;
  D.Rem       := EcReadByte(D);
  D.Val       := D.Rng - 1 - Cardinal(D.Rem shr (EC_SYM_BITS - EC_CODE_EXTRA));
  D.Error     := 0;
  EcDecNormalize(D);
end;

function EcDecode(var D: TEcDec; Ft: Cardinal): Cardinal;
var
  S: Cardinal;
begin
  D.Ext := D.Rng div Ft;
  S := D.Val div D.Ext;
  if S + 1 < Ft then Result := Ft - (S + 1)
  else               Result := 0;
end;

function EcDecodeBin(var D: TEcDec; Bits: Cardinal): Cardinal;
var
  S, Ft: Cardinal;
begin
  D.Ext := D.Rng shr Bits;
  S := D.Val div D.Ext;
  Ft := Cardinal(1) shl Bits;
  if S + 1 < Ft then Result := Ft - (S + 1)
  else               Result := 0;
end;

procedure EcDecUpdate(var D: TEcDec; Fl, Fh, Ft: Cardinal);
var
  S: Cardinal;
begin
  S := D.Ext * (Ft - Fh);
  D.Val := D.Val - S;
  if Fl > 0 then D.Rng := D.Ext * (Fh - Fl)
  else           D.Rng := D.Rng - S;
  EcDecNormalize(D);
end;

function EcDecBitLogp(var D: TEcDec; Logp: Cardinal): Integer;
var
  R, DV, S: Cardinal;
begin
  R  := D.Rng;
  DV := D.Val;
  S  := R shr Logp;
  if DV < S then Result := 1 else Result := 0;
  if Result = 0 then D.Val := DV - S;
  if Result <> 0 then D.Rng := S else D.Rng := R - S;
  EcDecNormalize(D);
end;

function EcDecIcdf(var D: TEcDec; Icdf: PByte; Ftb: Cardinal): Integer;
var
  R, DV, S, T: Cardinal;
begin
  S  := D.Rng;
  DV := D.Val;
  R  := S shr Ftb;
  Result := -1;
  repeat
    T := S;
    Inc(Result);
    S := R * Icdf[Result];
  until DV >= S;
  D.Val := DV - S;
  D.Rng := T - S;
  EcDecNormalize(D);
end;

function EcDecIcdf16(var D: TEcDec; Icdf: PWord; Ftb: Cardinal): Integer;
var
  R, DV, S, T: Cardinal;
begin
  S  := D.Rng;
  DV := D.Val;
  R  := S shr Ftb;
  Result := -1;
  repeat
    T := S;
    Inc(Result);
    S := R * Icdf[Result];
  until DV >= S;
  D.Val := DV - S;
  D.Rng := T - S;
  EcDecNormalize(D);
end;

function EcDecBits(var D: TEcDec; Bits: Cardinal): Cardinal;
var
  Window   : Cardinal;
  Available: Integer;
begin
  Window    := D.EndWindow;
  Available := D.NEndBits;
  if Cardinal(Available) < Bits then
  begin
    repeat
      Window := Window or (Cardinal(EcReadByteFromEnd(D)) shl Available);
      Inc(Available, EC_SYM_BITS);
    until Available > EC_WINDOW_SIZE - EC_SYM_BITS;
  end;
  Result := Window and ((Cardinal(1) shl Bits) - 1);
  Window := Window shr Bits;
  Dec(Available, Bits);
  D.EndWindow := Window;
  D.NEndBits  := Available;
  Inc(D.NBitsTotal, Bits);
end;

function EcDecUInt(var D: TEcDec; Ft: Cardinal): Cardinal;
var
  Ftb: Integer;
  Ft2, S, T: Cardinal;
begin
  Dec(Ft);
  Ftb := EcIlog(Ft);
  if Ftb > EC_UINT_BITS then
  begin
    Dec(Ftb, EC_UINT_BITS);
    Ft2 := (Ft shr Ftb) + 1;
    S := EcDecode(D, Ft2);
    EcDecUpdate(D, S, S + 1, Ft2);
    T := (S shl Ftb) or EcDecBits(D, Ftb);
    if T <= Ft then Exit(T);
    D.Error := 1;
    Result := Ft;
  end
  else
  begin
    Inc(Ft);
    S := EcDecode(D, Ft);
    EcDecUpdate(D, S, S + 1, Ft);
    Result := S;
  end;
end;

function EcTell(const D: TEcDec): Integer;
begin
  Result := D.NBitsTotal - EcIlog(D.Rng);
end;

function EcTellFrac(const D: TEcDec): Cardinal;
const
  Correction: array[0..7] of Cardinal = (35733, 38967, 42495, 46340, 50535, 55109, 60097, 65535);
var
  NBits, R: Cardinal;
  L: Integer;
  B: Cardinal;
begin
  NBits := Cardinal(D.NBitsTotal) shl BITRES;
  L := EcIlog(D.Rng);
  R := D.Rng shr (L - 16);
  B := (R shr 12) - 8;
  if R > Correction[B] then Inc(B);
  L := (L shl 3) + Integer(B);
  Result := NBits - Cardinal(L);
end;

// ---------------------------------------------------------------------------
// Laplace (coarse energy)
// ---------------------------------------------------------------------------

const
  LAPLACE_LOG_MINP = 0;
  LAPLACE_MINP     = 1 shl LAPLACE_LOG_MINP;
  LAPLACE_NMIN     = 16;

function EcLaplaceGetFreq1(Fs0: Cardinal; Decay: Integer): Cardinal;
var
  Ft: Cardinal;
begin
  Ft := 32768 - LAPLACE_MINP * (2 * LAPLACE_NMIN) - Fs0;
  Result := Cardinal((Integer(Ft) * (16384 - Decay)) shr 15);
end;

function EcLaplaceDecode(var D: TEcDec; Fs: Cardinal; Decay: Integer): Integer;
var
  Val: Integer;
  Fl, Fm: Cardinal;
  Di: Integer;
begin
  Val := 0;
  Fm := EcDecodeBin(D, 15);
  Fl := 0;
  if Fm >= Fs then
  begin
    Inc(Val);
    Fl := Fs;
    Fs := EcLaplaceGetFreq1(Fs, Decay) + LAPLACE_MINP;
    while (Fs > LAPLACE_MINP) and (Fm >= Fl + 2 * Fs) do
    begin
      Fs := Fs * 2;
      Fl := Fl + Fs;
      Fs := Cardinal((Integer(Fs - 2 * LAPLACE_MINP) * Decay) shr 15);
      Fs := Fs + LAPLACE_MINP;
      Inc(Val);
    end;
    if Fs <= LAPLACE_MINP then
    begin
      Di := Integer((Fm - Fl) shr (LAPLACE_LOG_MINP + 1));
      Inc(Val, Di);
      Fl := Fl + Cardinal(2 * Di * LAPLACE_MINP);
    end;
    if Fm < Fl + Fs then Val := -Val
    else Fl := Fl + Fs;
  end;
  if Fl + Fs < 32768 then EcDecUpdate(D, Fl, Fl + Fs, 32768)
  else                    EcDecUpdate(D, Fl, 32768, 32768);
  Result := Val;
end;

end.
