unit VorbisCodebook;

{
  VorbisCodebook.pas - Vorbis codebook: Huffman codeword assignment, decode and VQ lookup

  Codeword assignment follows the Vorbis I spec section 3.2.1: entries are
  processed in order and each receives the lowest available leaf of its
  length (this is NOT canonical Huffman ordering by length).

  Decode uses a fast table for codes up to VORBIS_FAST_BITS bits and a
  binary search over MSB-aligned sorted codewords for longer codes, the
  same scheme as stb_vorbis (public domain, nothings/stb).

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  SysUtils, Math,
  AudioTypes,
  AudioBitReader,
  VorbisTypes;

// Build the decode tables and VQ vectors. Lengths, Entries, Dimensions,
// LookupType and the raw Multiplicands must already be filled.
// Returns False if the length set is over-subscribed (invalid stream).
function VorbisCodebookInit(var CB: TVorbisCodebook): Boolean;

// Decode one codeword (entry index). Returns -1 on end of packet / bad code.
function VorbisCodebookDecode(var CB: TVorbisCodebook;
  var Br: TAudioBitReader): Integer;

// Decode one VQ vector into Output[0..CB.Dimensions-1]. Returns False on error.
function VorbisCodebookDecodeVQ(var CB: TVorbisCodebook;
  var Br: TAudioBitReader; Output: PSingle): Boolean;

// Pointer to the expanded VQ vector of an entry (Dimensions floats).
function VorbisCodebookVQRow(const CB: TVorbisCodebook; Entry: Integer): PSingle; inline;

// Reverse all 32 bits.
function BitReverse32(V: Cardinal): Cardinal;

implementation

function BitReverse32(V: Cardinal): Cardinal;
begin
  V := ((V and $AAAAAAAA) shr 1) or ((V and $55555555) shl 1);
  V := ((V and $CCCCCCCC) shr 2) or ((V and $33333333) shl 2);
  V := ((V and $F0F0F0F0) shr 4) or ((V and $0F0F0F0F) shl 4);
  V := ((V and $FF00FF00) shr 8) or ((V and $00FF00FF) shl 8);
  Result := (V shr 16) or (V shl 16);
end;

// ---------------------------------------------------------------------------
// Codeword assignment (spec 3.2.1, same algorithm as stb_vorbis compute_codewords)
// ---------------------------------------------------------------------------

function ComputeCodewords(var CB: TVorbisCodebook): Boolean;
var
  Available : array[0..32] of Cardinal;
  I, K, Z, Y: Integer;
  Res       : Cardinal;
  N         : Integer;
begin
  N := CB.Entries;
  SetLength(CB.Codewords, N);
  FillChar(Available, SizeOf(Available), 0);

  // First used entry gets codeword 0
  K := 0;
  while (K < N) and (CB.Lengths[K] = 0) do Inc(K);
  if K = N then Exit(True);  // no used entries (allowed, never decoded)

  CB.Codewords[K] := 0;
  for I := 1 to CB.Lengths[K] do
    Available[I] := Cardinal(1) shl (32 - I);

  for I := K + 1 to N - 1 do
  begin
    Z := CB.Lengths[I];
    if Z = 0 then Continue;
    // Lowest available leaf at depth <= Z
    while (Z > 0) and (Available[Z] = 0) do Dec(Z);
    if Z = 0 then Exit(False);  // over-subscribed
    Res := Available[Z];
    Available[Z] := 0;
    CB.Codewords[I] := BitReverse32(Res);  // stream order: first bit = bit 0
    // Propagate the remaining sub-leaves down to length Z+1..Len
    if Z <> CB.Lengths[I] then
      for Y := CB.Lengths[I] downto Z + 1 do
        Available[Y] := Res + (Cardinal(1) shl (32 - Y));
  end;
  Result := True;
end;

procedure QuickSortCodes(var Codes: TArray<Cardinal>; var Syms: TArray<Integer>; L, R: Integer);
var
  I, J  : Integer;
  P     : Cardinal;
  TC    : Cardinal;
  TS    : Integer;
begin
  while L < R do
  begin
    I := L; J := R; P := Codes[(L + R) shr 1];
    repeat
      while Codes[I] < P do Inc(I);
      while Codes[J] > P do Dec(J);
      if I <= J then
      begin
        TC := Codes[I]; Codes[I] := Codes[J]; Codes[J] := TC;
        TS := Syms[I];  Syms[I]  := Syms[J];  Syms[J]  := TS;
        Inc(I); Dec(J);
      end;
    until I > J;
    if J - L < R - I then
    begin
      QuickSortCodes(Codes, Syms, L, J);
      L := I;
    end
    else
    begin
      QuickSortCodes(Codes, Syms, I, R);
      R := J;
    end;
  end;
end;

function VorbisCodebookInit(var CB: TVorbisCodebook): Boolean;
var
  I, D, E     : Integer;
  FastSize    : Integer;
  Z           : Cardinal;
  LongCount   : Integer;
  Last        : Single;
  Off, Divisor: Integer;
begin
  Result := False;
  if CB.Entries <= 0 then Exit;
  if Length(CB.Lengths) < CB.Entries then Exit;

  CB.HuffMinLen := 0;
  CB.HuffMaxLen := 0;
  for I := 0 to CB.Entries - 1 do
    if CB.Lengths[I] > 0 then
    begin
      if CB.Lengths[I] > 32 then Exit;
      if (CB.HuffMinLen = 0) or (CB.Lengths[I] < CB.HuffMinLen) then
        CB.HuffMinLen := CB.Lengths[I];
      if CB.Lengths[I] > CB.HuffMaxLen then CB.HuffMaxLen := CB.Lengths[I];
    end;

  if not ComputeCodewords(CB) then Exit;

  // ---- Fast table ----
  FastSize := 1 shl VORBIS_FAST_BITS;
  SetLength(CB.FastTable, FastSize);
  for I := 0 to FastSize - 1 do CB.FastTable[I] := -1;
  LongCount := 0;
  for I := 0 to CB.Entries - 1 do
  begin
    if CB.Lengths[I] = 0 then Continue;
    if CB.Lengths[I] <= VORBIS_FAST_BITS then
    begin
      Z := CB.Codewords[I];
      while Z < Cardinal(FastSize) do
      begin
        CB.FastTable[Z] := I;
        Inc(Z, Cardinal(1) shl CB.Lengths[I]);
      end;
    end
    else
      Inc(LongCount);
  end;

  // ---- Sorted long codes (MSB-aligned) ----
  CB.SortedCount := LongCount;
  SetLength(CB.SortedCodes, LongCount);
  SetLength(CB.SortedSyms,  LongCount);
  D := 0;
  for I := 0 to CB.Entries - 1 do
    if CB.Lengths[I] > VORBIS_FAST_BITS then
    begin
      CB.SortedCodes[D] := BitReverse32(CB.Codewords[I]);
      CB.SortedSyms[D]  := I;
      Inc(D);
    end;
  if LongCount > 1 then
    QuickSortCodes(CB.SortedCodes, CB.SortedSyms, 0, LongCount - 1);

  // ---- VQ vectors ----
  CB.VQValues := nil;
  if CB.LookupType = VORBIS_LOOKUP_NONE then Exit(True);
  if CB.Dimensions <= 0 then Exit;

  if CB.LookupType = VORBIS_LOOKUP_TYPE1 then
    CB.Lookup1Count := VorbisLookup1Values(CB.Entries, CB.Dimensions)
  else
    CB.Lookup1Count := 0;

  // Multiplicands arrive as raw integers stored in Single; scale them.
  for I := 0 to High(CB.Multiplicands) do
    CB.Multiplicands[I] := CB.MinValue + CB.DeltaValue * CB.Multiplicands[I];

  SetLength(CB.VQValues, CB.Entries * CB.Dimensions);
  for E := 0 to CB.Entries - 1 do
  begin
    Last := 0.0;
    Divisor := 1;
    for D := 0 to CB.Dimensions - 1 do
    begin
      if CB.LookupType = VORBIS_LOOKUP_TYPE1 then
      begin
        if CB.Lookup1Count <= 0 then Exit;
        Off := (E div Divisor) mod CB.Lookup1Count;
        Divisor := Divisor * CB.Lookup1Count;
      end
      else
        Off := E * CB.Dimensions + D;
      if Off >= Length(CB.Multiplicands) then Exit;
      CB.VQValues[E * CB.Dimensions + D] := CB.Multiplicands[Off] + Last;
      if CB.SequenceP then Last := CB.VQValues[E * CB.Dimensions + D];
    end;
  end;
  Result := True;
end;

// ---------------------------------------------------------------------------
// Huffman decode
// ---------------------------------------------------------------------------

// Peek the next 32 bits (LSB-first) without advancing; bits past the end read as 0.
function PeekBits32(const Br: TAudioBitReader): Cardinal;
var
  ByteIdx, ByteCount, B: Integer;
  Acc: UInt64;
begin
  ByteIdx   := Br.Pos shr 3;
  ByteCount := (Br.Limit + 7) shr 3;
  Acc := 0;
  for B := 0 to 4 do
    if ByteIdx + B < ByteCount then
      Acc := Acc or (UInt64(Br.Buf[ByteIdx + B]) shl (8 * B));
  Result := Cardinal(Acc shr (Br.Pos and 7));
end;

function VorbisCodebookDecode(var CB: TVorbisCodebook;
  var Br: TAudioBitReader): Integer;
var
  Acc   : Cardinal;
  Sym   : Integer;
  Len   : Integer;
  Code  : Cardinal;
  X, N, M: Integer;
begin
  Result := -1;
  if Br.Pos >= Br.Limit then Exit;
  if Length(CB.FastTable) = 0 then Exit;

  Acc := PeekBits32(Br);
  Sym := CB.FastTable[Acc and ((1 shl VORBIS_FAST_BITS) - 1)];
  if Sym < 0 then
  begin
    if CB.SortedCount = 0 then Exit;
    Code := BitReverse32(Acc);
    // Largest sorted code <= Code
    X := 0; N := CB.SortedCount;
    while N > 1 do
    begin
      M := X + (N shr 1);
      if CB.SortedCodes[M] <= Code then
      begin
        X := M;
        N := N - (N shr 1);
      end
      else
        N := N shr 1;
    end;
    Sym := CB.SortedSyms[X];
    Len := CB.Lengths[Sym];
    // Verify prefix match
    if (Code shr (32 - Len)) <> (CB.SortedCodes[X] shr (32 - Len)) then Exit;
  end
  else
    Len := CB.Lengths[Sym];

  if Br.Pos + Len > Br.Limit then Exit;  // truncated packet
  Inc(Br.Pos, Len);
  Result := Sym;
end;

// ---------------------------------------------------------------------------
// VQ
// ---------------------------------------------------------------------------

function VorbisCodebookVQRow(const CB: TVorbisCodebook; Entry: Integer): PSingle;
begin
  Result := @CB.VQValues[Entry * CB.Dimensions];
end;

function VorbisCodebookDecodeVQ(var CB: TVorbisCodebook;
  var Br: TAudioBitReader; Output: PSingle): Boolean;
var
  Sym, I: Integer;
  Row   : PSingle;
begin
  Result := False;
  if CB.LookupType = VORBIS_LOOKUP_NONE then Exit;
  if Length(CB.VQValues) = 0 then Exit;
  Sym := VorbisCodebookDecode(CB, Br);
  if Sym < 0 then Exit;
  Row := VorbisCodebookVQRow(CB, Sym);
  for I := 0 to CB.Dimensions - 1 do
    Output[I] := Row[I];
  Result := True;
end;

end.
