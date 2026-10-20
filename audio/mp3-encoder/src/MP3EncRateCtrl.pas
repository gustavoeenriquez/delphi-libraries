unit MP3EncRateCtrl;

{
  MP3EncRateCtrl.pas — Rate control loop for MP3 Layer III granules

  Finds the minimum global_gain (0..255) such that the Huffman-coded
  spectral data fits within a given bit budget, using binary search over
  QuantizeBlock().

  Also provides helpers to:
    - Locate the big-values boundary (last non-zero pair)
    - Count count1 quads (trailing pairs in [-1, 0, +1])
    - Select the best Huffman table for each spectral region
    - Fill a complete TRCtrlParams descriptor for one granule

  Fixed region layout (standard MPEG1 44100 Hz long blocks):
    Region 0: sfb bands 0..10  (region0_count = 10)
    Region 1: sfb bands 11..14 (region1_count = 3)
    Region 2: remainder up to big_values * 2

  Reference: ISO 11172-3 §2.4.3.4 / toots/shine l3loop.c
  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  MP3EncQuantize, MP3EncHuffman, MP3EncFrame;

const
  RC_REGION0_COUNT = 10;  { standard region0_count for MPEG1 }
  RC_REGION1_COUNT = 3;   { standard region1_count for MPEG1 }

type
  TRCtrlParams = record
    BigValues         : Integer;  { number of big-values pairs (9 bits) }
    Count1            : Integer;  { number of count1 quads }
    Count1TableSelect : Byte;     { 0 = table 32 (A), 1 = table 33 (B) }
    TableSelect       : array[0..2] of Byte;  { Huffman table per region }
    Region0Count      : Byte;     { = RC_REGION0_COUNT }
    Region1Count      : Byte;     { = RC_REGION1_COUNT }
    SrIdx             : Byte;     { sample rate index 0/1/2 }
    BlockType         : Byte;     { 0..3: region layout (window switching) }
  end;

{ Return the number of big-values pairs: the last non-zero pair index + 1.
  Returns 0 if all AIx[] = 0. }
function RateCtrlBigValues(const AIx: T576Int): Integer;

{ Count consecutive count1 quads starting at ABigValuesEnd.
  A quad qualifies when all four |values| ≤ 1 AND at least one is non-zero.
  Stops at the first all-zero quad or any |value| > 1. }
function RateCtrlCount1(const AIx: T576Int; ABigValuesEnd: Integer): Integer;

{ Select the best count1 table (returns 0 for table 32, 1 for table 33)
  by comparing total bit counts over ACount1 quads starting at ABigValuesEnd. }
function RateCtrlCount1Table(const AIx: T576Int;
  ABigValuesEnd, ACount1: Integer): Byte;

{ Return the table index (0..31) with the fewest bits for pairs in
  AIx[AStart..AEnd-1].  Returns 0 for an empty or all-zero region. }
function RateCtrlBestTable(const AIx: T576Int; AStart, AEnd: Integer): Integer;

{ Same result as RateCtrlBestTable in practice but only counts the bits of
  the few tables that can hold the region maximum (Shine choose_table). }
function RateCtrlBestTableFast(const AIx: T576Int; AStart, AEnd: Integer): Integer;

{ Fill all coding parameters for one granule given its quantized Ix[] array.
  Uses RC_REGION0_COUNT / RC_REGION1_COUNT for the region layout.
  Count1 is determined by trailing [-1,0,+1] quads beyond big_values. }
procedure RateCtrlFillParams(const AIx: T576Int; ASrIdx: Byte;
  out AParams: TRCtrlParams; ABlockType: Byte = 0);

{ First line of Huffman regions 1 and 2 for a parameter set. }
procedure RateCtrlRegionStarts(const AParams: TRCtrlParams; out AR1Start, AR2Start: Integer);

{ Total Huffman bits for a granule: big-values regions + count1 quads. }
function RateCtrlHuffBits(const AIx: T576Int;
  const AParams: TRCtrlParams): Integer;

{ Find the minimum global_gain in [0..255] such that
  RateCtrlHuffBits(Quantize(AXr, gain)) ≤ ATargetBits.
  Returns 255 if no such gain exists (target too small).
  Writes the quantized Ix[] and coding params for the found gain. }
function RateCtrlFindGain(const AQState: TQuantState;
  const AXr: T576; ATargetBits: Integer;
  const AScalefacL: TScalefacL; AScalefacScale, APreflag, ASrIdx: Integer;
  out AIx: T576Int; out AParams: TRCtrlParams): Integer;

implementation

// ---------------------------------------------------------------------------

function RateCtrlBigValues(const AIx: T576Int): Integer;
var
  i: Integer;
begin
  for i := QUANT_GRANULE - 1 downto 0 do
    if AIx[i] <> 0 then begin
      Result := i div 2 + 1;
      Exit;
    end;
  Result := 0;
end;

// ---------------------------------------------------------------------------

function RateCtrlCount1(const AIx: T576Int; ABigValuesEnd: Integer): Integer;
var
  i: Integer;
begin
  Result := 0;
  i := ABigValuesEnd;
  while i + 3 < QUANT_GRANULE do begin
    { Stop if any value exceeds ±1 }
    if (Abs(AIx[i])   > 1) or (Abs(AIx[i + 1]) > 1) or
       (Abs(AIx[i + 2]) > 1) or (Abs(AIx[i + 3]) > 1) then Break;
    { Stop at first all-zero quad (rzero region begins here) }
    if (AIx[i] = 0) and (AIx[i + 1] = 0) and
       (AIx[i + 2] = 0) and (AIx[i + 3] = 0) then Break;
    Inc(Result);
    Inc(i, 4);
  end;
end;

// ---------------------------------------------------------------------------

function RateCtrlCount1Table(const AIx: T576Int;
  ABigValuesEnd, ACount1: Integer): Byte;
var
  bitsA, bitsB, i, b: Integer;
begin
  bitsA := 0; bitsB := 0;
  i := ABigValuesEnd;
  while i < ABigValuesEnd + ACount1 * 4 do begin
    b := HuffCountQuadBits(HUFF_QUAD_A, Abs(AIx[i]),     Abs(AIx[i + 1]),
                                         Abs(AIx[i + 2]), Abs(AIx[i + 3]));
    if b <> HUFF_INVALID then Inc(bitsA, b);
    b := HuffCountQuadBits(HUFF_QUAD_B, Abs(AIx[i]),     Abs(AIx[i + 1]),
                                         Abs(AIx[i + 2]), Abs(AIx[i + 3]));
    if b <> HUFF_INVALID then Inc(bitsB, b);
    Inc(i, 4);
  end;
  if bitsA <= bitsB then Result := 0   { table 32 = HUFF_QUAD_A }
  else                   Result := 1;  { table 33 = HUFF_QUAD_B }
end;

// ---------------------------------------------------------------------------

function RateCtrlBestTable(const AIx: T576Int; AStart, AEnd: Integer): Integer;
var
  t, bits, bestBits, best, i, b: Integer;
begin
  best := 0; bestBits := MaxInt;

  for t := 0 to 31 do begin
    bits := 0;
    i    := AStart;
    while i < AEnd do begin
      b := HuffCountPairBits(t, Abs(AIx[i]), Abs(AIx[i + 1]));
      if b = HUFF_INVALID then begin bits := MaxInt; Break; end;
      Inc(bits, b);
      Inc(i, 2);
    end;
    if bits < bestBits then begin bestBits := bits; best := t; end;
  end;

  Result := best;
end;

// ---------------------------------------------------------------------------

function RateCtrlBestTableFast(const AIx: T576Int; AStart, AEnd: Integer): Integer;
var
  i, mx, t, bits, bestBits, b, lin, c: Integer;
  cand: array[0..2] of Integer;
  nCand: Integer;
begin
  Result := 0;
  if AEnd <= AStart then Exit;
  mx := 0;
  for i := AStart to AEnd - 1 do
    if Abs(AIx[i]) > mx then mx := Abs(AIx[i]);
  if mx = 0 then Exit;
  nCand := 0;
  if mx <= 15 then begin
    case mx of
      1:    begin cand[0] := 1; nCand := 1; end;
      2:    begin cand[0] := 2; cand[1] := 3; nCand := 2; end;
      3:    begin cand[0] := 5; cand[1] := 6; nCand := 2; end;
      4, 5: begin cand[0] := 7; cand[1] := 8; cand[2] := 9; nCand := 3; end;
      6, 7: begin cand[0] := 10; cand[1] := 11; cand[2] := 12; nCand := 3; end;
    else    begin cand[0] := 13; cand[1] := 15; nCand := 2; end;
    end;
  end else begin
    lin := mx - 15;
    for t := 16 to 23 do
      if (1 shl HuffLinBits(t)) > lin then begin cand[nCand] := t; Inc(nCand); Break; end;
    for t := 24 to 31 do
      if (1 shl HuffLinBits(t)) > lin then begin cand[nCand] := t; Inc(nCand); Break; end;
    if nCand = 0 then Exit;   { value too large for every table }
  end;
  bestBits := MaxInt;
  for c := 0 to nCand - 1 do begin
    t := cand[c];
    bits := 0;
    i := AStart;
    while i < AEnd do begin
      b := HuffCountPairBits(t, Abs(AIx[i]), Abs(AIx[i + 1]));
      if b = HUFF_INVALID then begin bits := MaxInt; Break; end;
      Inc(bits, b);
      Inc(i, 2);
    end;
    if bits < bestBits then begin bestBits := bits; Result := t; end;
  end;
end;

// ---------------------------------------------------------------------------

procedure RateCtrlRegionStarts(const AParams: TRCtrlParams; out AR1Start, AR2Start: Integer);
begin
  case AParams.BlockType of
    2:    begin AR1Start := 36; AR2Start := QUANT_GRANULE; end;
    1, 3: begin AR1Start := QuantSfbBand(AParams.SrIdx, 8); AR2Start := QUANT_GRANULE; end;
  else
    AR1Start := QuantSfbBand(AParams.SrIdx, AParams.Region0Count + 1);
    AR2Start := QuantSfbBand(AParams.SrIdx, AParams.Region0Count + AParams.Region1Count + 2);
  end;
end;

procedure RateCtrlFillParams(const AIx: T576Int; ASrIdx: Byte;
  out AParams: TRCtrlParams; ABlockType: Byte);
var
  bigEnd, r1Start, r2Start, i: Integer;
begin
  FillChar(AParams, SizeOf(AParams), 0);
  AParams.Region0Count := RC_REGION0_COUNT;
  AParams.Region1Count := RC_REGION1_COUNT;
  AParams.SrIdx        := ASrIdx;
  AParams.BlockType    := ABlockType;

  { Region layout as in Shine calc_runlen: rzero = trailing all-zero pairs,
    count1 = quads of |v| <= 1 walked backwards from rzero, big_values = rest.
    Walking backwards keeps the quads aligned with the end of the data, so
    every non-zero line is coded either as a pair or inside a quad. }
  i := QUANT_GRANULE;
  while i > 1 do begin
    if (AIx[i - 1] <> 0) or (AIx[i - 2] <> 0) then Break;
    Dec(i, 2);
  end;
  AParams.Count1 := 0;
  while i > 3 do begin
    if (Abs(AIx[i - 1]) <= 1) and (Abs(AIx[i - 2]) <= 1) and
       (Abs(AIx[i - 3]) <= 1) and (Abs(AIx[i - 4]) <= 1) then begin
      Inc(AParams.Count1);
      Dec(i, 4);
    end else
      Break;
  end;
  AParams.BigValues := i div 2;
  bigEnd := i;
  AParams.Count1TableSelect := RateCtrlCount1Table(AIx, bigEnd, AParams.Count1);

  { Region boundaries (scalefactor band table, or fixed with window switching) }
  RateCtrlRegionStarts(AParams, r1Start, r2Start);
  if r1Start > bigEnd then r1Start := bigEnd;
  if r2Start > bigEnd then r2Start := bigEnd;

  { Best Huffman table per region (candidates chosen from the region maximum) }
  AParams.TableSelect[0] := RateCtrlBestTableFast(AIx, 0,       r1Start);
  AParams.TableSelect[1] := RateCtrlBestTableFast(AIx, r1Start, r2Start);
  AParams.TableSelect[2] := RateCtrlBestTableFast(AIx, r2Start, bigEnd);
end;

// ---------------------------------------------------------------------------

function RateCtrlHuffBits(const AIx: T576Int;
  const AParams: TRCtrlParams): Integer;
var
  bigEnd, r1Start, r2Start, i, t, b: Integer;
begin
  Result  := 0;
  bigEnd  := AParams.BigValues * 2;

  RateCtrlRegionStarts(AParams, r1Start, r2Start);
  if r1Start > bigEnd then r1Start := bigEnd;
  if r2Start > bigEnd then r2Start := bigEnd;

  { Big-values: three regions }
  i := 0;
  while i < bigEnd do begin
    if i < r1Start      then t := AParams.TableSelect[0]
    else if i < r2Start then t := AParams.TableSelect[1]
    else                     t := AParams.TableSelect[2];
    b := HuffCountPairBits(t, Abs(AIx[i]), Abs(AIx[i + 1]));
    if b = HUFF_INVALID then begin
      { A value no table can code (> 15 + 2^linbits - 1): this gain is
        unusable.  Report "infinite" so the gain search moves on; counting
        it as zero bits used to make the search converge on global_gain=0
        and emit empty granules. }
      Result := MaxInt;
      Exit;
    end;
    Inc(Result, b);
    Inc(i, 2);
  end;

  { Count1 quads }
  t := HUFF_QUAD_A + AParams.Count1TableSelect;
  i := bigEnd;
  while i < bigEnd + AParams.Count1 * 4 do begin
    b := HuffCountQuadBits(t, Abs(AIx[i]),     Abs(AIx[i + 1]),
                               Abs(AIx[i + 2]), Abs(AIx[i + 3]));
    if b <> HUFF_INVALID then Inc(Result, b);
    Inc(i, 4);
  end;
end;

// ---------------------------------------------------------------------------

function RateCtrlFindGain(const AQState: TQuantState;
  const AXr: T576; ATargetBits: Integer;
  const AScalefacL: TScalefacL; AScalefacScale, APreflag, ASrIdx: Integer;
  out AIx: T576Int; out AParams: TRCtrlParams): Integer;
var
  lo, hi, mid, bits: Integer;
  Ix    : T576Int;
  Params: TRCtrlParams;
begin
  { Default output: maximum quantization (worst quality) }
  Result := 255;
  QuantizeBlock(AQState, AXr, 255, AScalefacL, AScalefacScale, APreflag, ASrIdx, AIx);
  RateCtrlFillParams(AIx, ASrIdx, AParams);

  lo := 0; hi := 255;
  while lo <= hi do begin
    mid := (lo + hi) shr 1;
    QuantizeBlock(AQState, AXr, mid, AScalefacL, AScalefacScale, APreflag, ASrIdx, Ix);
    RateCtrlFillParams(Ix, ASrIdx, Params);
    bits := RateCtrlHuffBits(Ix, Params);

    if bits <= ATargetBits then begin
      { This gain works; try smaller gain (higher quality) }
      Result  := mid;
      AIx     := Ix;
      AParams := Params;
      hi := mid - 1;
    end else
      lo := mid + 1;  { need more quantization }
  end;
end;

end.
