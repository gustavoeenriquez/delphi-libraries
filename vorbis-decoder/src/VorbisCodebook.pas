unit VorbisCodebook;

{
  VorbisCodebook.pas - Vorbis codebook decode (Huffman + VQ)

  Implements section 3 of the Vorbis I spec:
    - Canonical Huffman decode from bit lengths
    - Lookup type 1 (implicit VQ: dimensions indexed combinatorially)
    - Lookup type 2 (explicit VQ: multiplicands stored per entry)
    - VorbisCodebookDecode -> one integer codeword index
    - VorbisCodebookDecodeVQ -> one float VQ vector

  Huffman flat-table approach (LSB-first):
    The stream uses LSB-first packing. Reading N bits with BrReadLSB gives
    an integer where bit 0 of the stream is bit 0 of the result. Therefore
    the canonical codeword value directly indexes the flat lookup table —
    no bit reversal is needed.

    For a codeword with value C and length L:
      - Fill table entries C, C+2^L, C+2*2^L, ... < 2^MaxLen
      - Each entry stores (symbol, actual_len)
    On decode: read MaxLen bits, look up table, put back (MaxLen-actual_len) bits.

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

// Build Huffman decode structures from the bit-length array already stored in CB.
// Must be called once after filling CB.Lengths, CB.LookupType, CB.MinValue,
// CB.DeltaValue, CB.ValueBits, CB.SequenceP, and CB.Multiplicands (raw ints as Single).
// Returns False if the codebook is invalid.
function VorbisCodebookInit(var CB: TVorbisCodebook): Boolean;

// Decode one codeword index from the bit stream.  Returns -1 on error.
function VorbisCodebookDecode(var CB: TVorbisCodebook;
  var Br: TAudioBitReader): Integer;

// Decode one VQ vector into Output[0..CB.Dimensions-1].  Returns False on error.
function VorbisCodebookDecodeVQ(var CB: TVorbisCodebook;
  var Br: TAudioBitReader; Output: PSingle): Boolean;

implementation

// ---------------------------------------------------------------------------
// Canonical Huffman table build (LSB-first, no bit reversal)
// ---------------------------------------------------------------------------

function VorbisCodebookInit(var CB: TVorbisCodebook): Boolean;
var
  EntryCount  : Integer;
  I, L, S     : Integer;
  MaxLen      : Integer;
  Code        : Cardinal;
  PrevLen     : Integer;
  TableSize   : Integer;
  Step        : Integer;
  J           : Integer;
  // Sorted list of (symbol, length) pairs
  SortedSym   : TArray<Integer>;
  SortedLen   : TArray<Integer>;
  Codewords   : TArray<Cardinal>;
  MultCount   : Integer;
begin
  Result := False;
  EntryCount := CB.Entries;
  if EntryCount <= 0 then Exit;

  // Find MaxLen; count used entries
  MaxLen := 0;
  for I := 0 to EntryCount - 1 do
    if CB.Lengths[I] > MaxLen then MaxLen := CB.Lengths[I];

  if MaxLen = 0 then Exit;
  if MaxLen > 24 then Exit;  // safety cap (practical max ~24 in real Vorbis files)

  CB.HuffMinLen := 32;
  CB.HuffMaxLen := MaxLen;
  for I := 0 to EntryCount - 1 do
    if (CB.Lengths[I] > 0) and (CB.Lengths[I] < CB.HuffMinLen) then
      CB.HuffMinLen := CB.Lengths[I];

  // Build sorted list: by (length ASC, symbol ASC)
  SetLength(SortedSym, EntryCount);
  SetLength(SortedLen, EntryCount);
  S := 0;
  for L := 1 to MaxLen do
    for I := 0 to EntryCount - 1 do
      if CB.Lengths[I] = L then
      begin
        SortedSym[S] := I;
        SortedLen[S] := L;
        Inc(S);
      end;
  // S = number of used entries

  // Assign canonical codewords (ascending within each length)
  SetLength(Codewords, S);
  Code := 0;
  PrevLen := 0;
  for I := 0 to S - 1 do
  begin
    L := SortedLen[I];
    if L <> PrevLen then
    begin
      Code := Code shl (L - PrevLen);
      PrevLen := L;
    end;
    Codewords[I] := Code;
    Inc(Code);
  end;

  // Build flat lookup table of size 2^MaxLen
  // For LSB-first: canonical code value C of length L occupies entries
  //   C, C + 2^L, C + 2*(2^L), ... < 2^MaxLen
  // because the first L bits of the read integer are exactly C.
  TableSize := 1 shl MaxLen;
  SetLength(CB.HuffSymbols, TableSize);
  // Reuse DecodeTable[0] = symbols, DecodeTable[1] = lengths
  SetLength(CB.DecodeTable, 2);
  SetLength(CB.DecodeTable[0], TableSize);
  SetLength(CB.DecodeTable[1], TableSize);
  for I := 0 to TableSize - 1 do
  begin
    CB.DecodeTable[0][I] := -1;
    CB.DecodeTable[1][I] := 0;
  end;

  for I := 0 to S - 1 do
  begin
    L := SortedLen[I];
    Step := 1 shl L;
    J := Integer(Codewords[I]);
    while J < TableSize do
    begin
      // Longer codes override shorter codes at shared entries (LSB-first table)
      CB.DecodeTable[0][J] := SortedSym[I];
      CB.DecodeTable[1][J] := L;
      Inc(J, Step);
    end;
  end;

  // ---- Build VQ multiplicands ----
  if CB.LookupType = VORBIS_LOOKUP_NONE then
  begin
    Result := True;
    Exit;
  end;

  if CB.LookupType = VORBIS_LOOKUP_TYPE1 then
    MultCount := VorbisLookup1Values(EntryCount, CB.Dimensions)
  else // TYPE2
    MultCount := EntryCount * CB.Dimensions;

  // Convert raw integer multiplicands (stored as Single) to float values
  // Value[i] = MinValue + DeltaValue * raw[i]
  for I := 0 to MultCount - 1 do
    CB.Multiplicands[I] := CB.MinValue + CB.DeltaValue * CB.Multiplicands[I];

  Result := True;
end;

// ---------------------------------------------------------------------------
// Huffman decode
// ---------------------------------------------------------------------------

function VorbisCodebookDecode(var CB: TVorbisCodebook;
  var Br: TAudioBitReader): Integer;
var
  Bits  : Cardinal;
  Sym   : Integer;
  Len   : Integer;
  ML    : Integer;
begin
  Result := -1;
  ML := CB.HuffMaxLen;
  if ML <= 0 then Exit;

  // Read ML bits (LSB-first); this advances Br.Pos by ML
  Bits := BrRead(Br, ML);

  // Bounds check: if Pos overshot Limit, packet is exhausted
  if Br.Pos > Br.Limit then Exit;

  Sym := CB.DecodeTable[0][Bits];
  Len := CB.DecodeTable[1][Bits];

  if (Sym < 0) or (Len <= 0) then Exit; // unassigned code

  // We read ML bits but only consumed Len; put back the rest
  Dec(Br.Pos, ML - Len);

  Result := Sym;
end;

// ---------------------------------------------------------------------------
// VQ vector decode
// ---------------------------------------------------------------------------

function VorbisCodebookDecodeVQ(var CB: TVorbisCodebook;
  var Br: TAudioBitReader; Output: PSingle): Boolean;
var
  Sym     : Integer;
  I       : Integer;
  Acc     : Single;
  Base    : Integer;
  Lookup  : Integer;
  Div_    : Integer;
begin
  Result := False;
  if CB.LookupType = VORBIS_LOOKUP_NONE then Exit;

  Sym := VorbisCodebookDecode(CB, Br);
  if Sym < 0 then Exit;

  if CB.LookupType = VORBIS_LOOKUP_TYPE2 then
  begin
    // Direct: entry Sym starts at Sym * Dimensions
    Base := Sym * CB.Dimensions;
    if CB.SequenceP then
    begin
      Acc := 0;
      for I := 0 to CB.Dimensions - 1 do
      begin
        Acc := Acc + CB.Multiplicands[Base + I];
        Output[I] := Acc;
      end;
    end
    else
      for I := 0 to CB.Dimensions - 1 do
        Output[I] := CB.Multiplicands[Base + I];
  end
  else // LOOKUP_TYPE1: implicit VQ
  begin
    // Enumerate dimensions from symbol index via modular indexing
    Lookup := VorbisLookup1Values(CB.Entries, CB.Dimensions);
    Div_ := 1;
    Acc := 0;
    for I := CB.Dimensions - 1 downto 0 do
    begin
      var Off: Integer := (Sym div Div_) mod Lookup;
      if CB.SequenceP then
      begin
        Acc := Acc + CB.Multiplicands[Off];
        Output[I] := Acc;
      end
      else
        Output[I] := CB.Multiplicands[Off];
      Div_ := Div_ * Lookup;
    end;
  end;

  Result := True;
end;

end.
