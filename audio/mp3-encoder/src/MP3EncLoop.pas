unit MP3EncLoop;

(*
  MP3EncLoop.pas — Noise-shaping quantization loop (ISO "outer loop")

  For one granule/channel:
    inner loop : binary search of global_gain so that the Huffman-coded
                 spectrum fits the bit budget (minus the scalefactor bits)
    outer loop : measure the quantization noise per scalefactor band against
                 the allowed noise from the psychoacoustic model (Xmin); the
                 bands that exceed it get their scalefactor incremented
                 (finer quantization there, 3 dB per step, or 6 dB once
                 scalefac_scale is set) and the inner loop runs again.
                 The best result seen (fewest / smallest violations) is kept.

  Finally scalefac_compress (slen1/slen2) and preflag are chosen to code the
  scalefactors with as few bits as possible.

  Short blocks (LoopEncodeGranuleShort) run the same loops on 13 bands x 3
  windows of the spectrum in bit-stream order; a window whose scalefactors
  saturate gets a subblock_gain step (12 dB finer quantization).

  Quality mode (AVbr, used by VBR): no bit budget, every band is quantized
  as coarsely as its allowed noise permits.  A binary search per band
  finds the coarsest step whose noise stays under Xmin; global_gain takes
  the coarsest of them and the scalefactors (and subblock_gain) bring the
  other bands down to their own step, lowering global_gain when a cap is
  in the way; scalefac_scale 0 and 1 are both tried (LAME vbr_mtrh).  The
  noise-shaping loop is the fallback when the result does not fit.

  Quantization uses the ISO formula on precomputed |xr|^(3/4):
      ix = trunc( |xr|^(3/4) * 2^(-3*(global_gain - 210 + adj)/16) + 0.4054 )
      adj = -2*(1 + scalefac_scale)*(scalefac + preflag*pretab)

  Reference: ISO 11172-3 dist10 loop.c (outer_loop / inner_loop /
  amp_scalefac_bands / calc_noise), LAME quantize.c (structure)
  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
*)

interface

uses
  MP3EncQuantize, MP3EncHuffman, MP3EncFrame, MP3EncRateCtrl, MP3EncPsy;

const
  LOOP_MAX_ITER  = 30;
  LOOP_MAX_SAVE_STEPS = 60;  { max global_gain increments in the saving phase }
  LOOP_TAB_OFS   = 300;    { table index offset for exponents -300..300 }

type
  TLoopState = record
    Pow2Q   : array[0..2 * LOOP_TAB_OFS] of Double;  { 2^((k-ofs)/4)      }
    Pow2Q34 : array[0..2 * LOOP_TAB_OFS] of Double;  { 2^(-3*(k-ofs)/16) }
  end;

  TLoopStats = record
    Iterations : Integer;
    OverBands  : Integer;   { bands still above Xmin in the chosen result }
    OverDb     : Double;    { sum of the excess (dB) over those bands }
    SignalE    : Double;    { sum xr^2 of the granule }
    NoiseE     : Double;    { total quantization noise energy of the result }
    GlobalGain : Integer;
    ScalefacScale, Preflag, MaxSf : Integer;
  end;

{ Build the power tables.  Call once per encoder. }
procedure LoopInit(out AState: TLoopState);

{ Quantize a granule so that scalefactor bits + Huffman bits <= AMaxBits,
  shaping the noise under AXmin (allowed noise energy per line, per band).
  Once every band is below its threshold the quantization is coarsened to
  save bits, but not below AMinBits (pass AMaxBits to always spend the
  whole budget, 0 to save as much as possible).
  Fills AGr completely (Ix signed, tables, regions, gain, scalefactors,
  scalefac_compress, preflag, scalefac_scale, Part2_3_Length).
  Returns Part2_3_Length. }
function LoopEncodeGranule(const AState: TLoopState; const AQ: TQuantState;
  const AXr: T576; const AXmin: TPsyBandArr; AMaxBits, AMinBits, ASrIdx: Integer;
  out AGr: TGrInfo; out AStats: TLoopStats; ABlockType: Integer = 0;
  AVbr: Boolean = False): Integer;

{ Same for a short-block granule (block_type 2).  AXr is in bit-stream order
  (scalefactor band, then window); AXmin is the allowed noise per line of
  each [sfb][window]. }
function LoopEncodeGranuleShort(const AState: TLoopState; const AQ: TQuantState;
  const AXr: T576; const AXmin: TPsyShortArr; AMaxBits, AMinBits, ASrIdx: Integer;
  out AGr: TGrInfo; out AStats: TLoopStats; AVbr: Boolean = False): Integer;

{ Smallest scalefac_compress index whose slen1/slen2 can hold the
  scalefactors (sfb 0..10 with slen1, 11..20 with slen2).  -1 if none. }
function LoopChooseScalefacCompress(const ASf: TScalefacL): Integer;

{ Scalefactor side-information bits for a scalefac_compress index
  (scfsi = 0: 6+5 bands with slen1, 5+5 bands with slen2). }
function LoopScalefacBits(AScalefacCompress: Integer): Integer;

implementation

uses
  System.Math;

const
  SLEN1_TAB: array[0..15] of Byte = (0, 0, 0, 0, 3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4);
  SLEN2_TAB: array[0..15] of Byte = (0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 3, 1, 2, 3, 2, 3);
  QUANT_BIAS = 0.4054;
  SF_CAP_LOW  = 15;   { max scalefactor sfb 0..10 (slen1 <= 4 bits) }
  SF_CAP_HIGH = 7;    { max scalefactor sfb 11..20 (slen2 <= 3 bits) }
  VBR_E_MAX   = 45;   { coarsest effective exponent: global_gain 255, adj 0 }

procedure LoopInit(out AState: TLoopState);
var
  k: Integer;
begin
  for k := 0 to 2 * LOOP_TAB_OFS do begin
    AState.Pow2Q[k]   := Power(2.0, (k - LOOP_TAB_OFS) / 4.0);
    AState.Pow2Q34[k] := Power(2.0, -3.0 * (k - LOOP_TAB_OFS) / 16.0);
  end;
end;

function LoopScalefacBits(AScalefacCompress: Integer): Integer;
begin
  if (AScalefacCompress < 0) or (AScalefacCompress > 15) then Exit(0);
  Result := 11 * SLEN1_TAB[AScalefacCompress] + 10 * SLEN2_TAB[AScalefacCompress];
end;

function LoopChooseScalefacCompress(const ASf: TScalefacL): Integer;
var
  b, m1, m2, i, bits, bestBits: Integer;
begin
  m1 := 0; m2 := 0;
  for b := 0 to 10 do  if ASf[b] > m1 then m1 := ASf[b];
  for b := 11 to 20 do if ASf[b] > m2 then m2 := ASf[b];
  Result := -1; bestBits := MaxInt;
  for i := 0 to 15 do
    if (m1 < (1 shl SLEN1_TAB[i])) and (m2 < (1 shl SLEN2_TAB[i])) then begin
      bits := LoopScalefacBits(i);
      if bits < bestBits then begin bestBits := bits; Result := i; end;
    end;
end;

{ Coarsest effective exponent (global_gain - 210 + adj, 1.5 dB steps) at
  which the noise per line of the lines ALo..AHi-1 stays under AXmin;
  VBR_E_MAX when any step will do.  The noise is taken as growing with the
  step, which holds up to the rounding of single lines. }
function VbrBandExp(const AState: TLoopState; const AQ: TQuantState;
  const AXrAbs, AXr34: T576; ALo, AHi: Integer; AXmin: Double; AHasEnergy: Boolean): Integer;
var
  lo, hi, mid, i, q: Integer;
  m, f, st, v, n: Double;

  function NoiseAt(AE: Integer): Double;
  var ii: Integer;
  begin
    f := AState.Pow2Q34[AE + LOOP_TAB_OFS];
    st := AState.Pow2Q[AE + LOOP_TAB_OFS];
    Result := 0.0;
    for ii := ALo to AHi - 1 do begin
      if AXr34[ii] = 0.0 then Continue;
      q := Trunc(AXr34[ii] * f + QUANT_BIAS);
      if q = 0 then v := 0.0
      else if q < QUANT_POW43_MAX then v := AQ.Pow43[q] * st
      else v := Power(q, 4.0 / 3.0) * st;
      Result := Result + Sqr(AXrAbs[ii] - v);
    end;
    Result := Result / (AHi - ALo);
  end;

begin
  if (AXmin <= 0.0) or not AHasEnergy or (AHi <= ALo) then Exit(VBR_E_MAX);
  { the finest step without overflow (ix <= 8206) }
  m := 0.0;
  for i := ALo to AHi - 1 do if AXr34[i] > m then m := AXr34[i];
  lo := -LOOP_TAB_OFS; hi := VBR_E_MAX;
  while lo < hi do begin
    mid := lo + (hi - lo) div 2;
    if m * AState.Pow2Q34[mid + LOOP_TAB_OFS] + QUANT_BIAS < 8207.0 then hi := mid
    else lo := mid + 1;
  end;
  { largest step in lo..VBR_E_MAX whose noise is under the threshold }
  n := NoiseAt(lo);
  if n > AXmin then Exit(lo);
  hi := VBR_E_MAX;
  while lo < hi do begin
    mid := lo + (hi - lo + 1) div 2;
    if NoiseAt(mid) <= AXmin then lo := mid else hi := mid - 1;
  end;
  Result := lo;
end;

function LoopEncodeGranule(const AState: TLoopState; const AQ: TQuantState;
  const AXr: T576; const AXmin: TPsyBandArr; AMaxBits, AMinBits, ASrIdx: Integer;
  out AGr: TGrInfo; out AStats: TLoopStats; ABlockType: Integer; AVbr: Boolean): Integer;
var
  xrAbs, xr34 : T576;
  bandLo      : array[0..QUANT_SFB_LMAX] of Integer;
  width       : array[0..QUANT_SFB_LMAX - 1] of Integer;
  sf          : TScalefacL;
  adj         : array[0..QUANT_SFB_LMAX - 1] of Integer;
  sfScale     : Integer;
  ix          : T576Int;
  params      : TRCtrlParams;
  noise       : TPsyBandArr;
  over        : array[0..QUANT_SFB_LMAX - 1] of Boolean;
  amplified   : array[0..QUANT_SFB_LMAX - 1] of Boolean;
  hasEnergy   : array[0..QUANT_SFB_LMAX - 1] of Boolean;
  bestValid   : Boolean;
  bestOver    : Integer;
  bestOverDb  : Double;
  bestTotDb   : Double;
  bestGr      : TGrInfo;
  bestIter    : Integer;
  iter, b, i, k, sfc, part2, budget, gg, bits: Integer;
  overCount   : Integer;
  overDb, totDb, totNoiseE, bestNoiseE, overSsd, bestOverSsd: Double;
  anyAmp, allAmp, better, vbrOk: Boolean;

  procedure ComputeAdj;
  var bb: Integer;
  begin
    for bb := 0 to QUANT_SFB_LMAX - 1 do
      adj[bb] := -2 * (1 + sfScale) * sf[bb];   { preflag applied at the end }
  end;

  { Quantize with global gain AGain; returns the Huffman bit count
    (MaxInt when a value cannot be coded) and fills ix / params.  ABest:
    cheapest region split (exact count) instead of the fixed one (an upper
    bound, cheaper to compute). }
  function QuantizeAndCount(AGain: Integer; ABest: Boolean = True): Integer;
  var bb, ii, e, q: Integer; f: Double;
  begin
    for bb := 0 to QUANT_SFB_LMAX - 1 do begin
      e := AGain - 210 + adj[bb] + LOOP_TAB_OFS;
      if e < 0 then e := 0 else if e > 2 * LOOP_TAB_OFS then e := 2 * LOOP_TAB_OFS;
      f := AState.Pow2Q34[e];
      for ii := bandLo[bb] to bandLo[bb + 1] - 1 do begin
        if xr34[ii] = 0.0 then
          ix[ii] := 0
        else begin
          q := Trunc(xr34[ii] * f + QUANT_BIAS);
          if q > 8206 then begin Result := MaxInt; Exit; end;  { uncodable }
          ix[ii] := q;
        end;
      end;
    end;
    RateCtrlFillParams(ix, ASrIdx, params, ABlockType, ABest and RateCtrlBestRegions);
    Result := RateCtrlHuffBits(ix, params);
  end;

  { Binary search of the smallest global_gain whose Huffman bits fit ABudget.
    Leaves ix / params for that gain; returns the gain and its bit count.
    The search counts with the fixed region split; the best split never
    costs more, so the gain is then lowered while it still fits. }
  function InnerLoop(ABudget: Integer; out ABits: Integer): Integer;
  var lo, hi, mid, bb: Integer;
  begin
    lo := 0; hi := 255; Result := 255; ABits := 0;
    while lo <= hi do begin
      mid := (lo + hi) shr 1;
      bb := QuantizeAndCount(mid, False);
      if bb <= ABudget then begin
        Result := mid; ABits := bb; hi := mid - 1;
      end else
        lo := mid + 1;
    end;
    if RateCtrlBestRegions and (ABlockType = 0) then
      while (Result > 0) and (QuantizeAndCount(Result - 1) <= ABudget) do
        Dec(Result);
    { restore ix / params of the chosen gain (the last probe may differ) }
    ABits := QuantizeAndCount(Result);
  end;

  { Quantization noise per band for gain AGain (ix must be up to date);
    sets noise / over / overCount / overDb / totDb. }
  procedure MeasureNoise(AGain: Integer);
  var bb, ii, kk: Integer; st, vv, nn: Double;
  begin
    overCount := 0; overDb := 0.0; totDb := 0.0; totNoiseE := 0.0; overSsd := 0.0;
    for bb := 0 to QUANT_SFB_LMAX - 1 do begin
      kk := AGain - 210 + adj[bb] + LOOP_TAB_OFS;
      if kk < 0 then kk := 0 else if kk > 2 * LOOP_TAB_OFS then kk := 2 * LOOP_TAB_OFS;
      st := AState.Pow2Q[kk];
      nn := 0.0;
      for ii := bandLo[bb] to bandLo[bb + 1] - 1 do begin
        if ix[ii] = 0 then vv := 0.0
        else if ix[ii] < QUANT_POW43_MAX then vv := AQ.Pow43[ix[ii]] * st
        else vv := Power(ix[ii], 4.0 / 3.0) * st;
        nn := nn + Sqr(xrAbs[ii] - vv);
      end;
      totNoiseE := totNoiseE + nn;
      if width[bb] > 0 then nn := nn / width[bb];
      noise[bb] := nn;
      over[bb] := (AXmin[bb] > 0.0) and (nn > AXmin[bb]);
      if (AXmin[bb] > 0.0) and (nn > 0.0) then begin
        vv := 10.0 * Log10(nn / AXmin[bb]);
        totDb := totDb + vv;
        if over[bb] then begin Inc(overCount); overDb := overDb + vv; overSsd := overSsd + vv * vv; end;
      end;
    end;
  end;

  procedure SaveBest(AGain, AHuffBits, ASfc, APart2: Integer);
  var ii, bb, pre, sfcP, bitsP: Integer; sfOut: TScalefacL; usePre: Boolean;
  begin
    bestGr := Default(TGrInfo);
    bestGr.SrIdx          := ASrIdx;
    bestGr.BlockType      := ABlockType;
    bestGr.GlobalGain     := AGain;
    bestGr.BigValues      := params.BigValues;
    bestGr.Count1         := params.Count1;
    bestGr.Count1TableSelect := params.Count1TableSelect;
    bestGr.TableSelect[0] := params.TableSelect[0];
    bestGr.TableSelect[1] := params.TableSelect[1];
    bestGr.TableSelect[2] := params.TableSelect[2];
    bestGr.Region0Count   := params.Region0Count;
    bestGr.Region1Count   := params.Region1Count;
    bestGr.ScalefacScale  := sfScale;
    for ii := 0 to QUANT_GRANULE - 1 do
      if (ix[ii] <> 0) and (AXr[ii] < 0.0) then bestGr.Ix[ii] := -ix[ii]
      else bestGr.Ix[ii] := ix[ii];
    { preflag: if every band 11..20 carries at least pretab[b], subtracting
      the pretab may allow a smaller slen2 }
    usePre := False;
    sfOut := sf;
    pre := 0;
    for bb := 11 to 20 do begin
      if sf[bb] < QuantPretab(bb) then begin pre := -1; Break; end;
      Inc(pre, QuantPretab(bb));
    end;
    if pre > 0 then begin
      for bb := 11 to 20 do sfOut[bb] := sf[bb] - QuantPretab(bb);
      sfcP := LoopChooseScalefacCompress(sfOut);
      if sfcP >= 0 then begin
        bitsP := LoopScalefacBits(sfcP);
        if bitsP < APart2 then begin
          usePre := True; ASfc := sfcP; APart2 := bitsP;
        end;
      end;
    end;
    if not usePre then sfOut := sf;
    bestGr.Preflag          := Ord(usePre);
    bestGr.ScalefacL        := sfOut;
    bestGr.ScalefacCompress := ASfc;
    bestGr.Part2_3_Length   := APart2 + AHuffBits;
  end;

  { Quality mode: every band quantized as coarsely as its allowed noise
    permits.  global_gain follows the band that tolerates the coarsest
    step, the scalefactors bring the others down to theirs (LAME
    vbr_mtrh).  The noise-shaping loop instead raises the global gain
    until the first band reaches its threshold, which leaves every other
    band finer than needed.  Bands that any step satisfies (empty, below
    the threshold) would push global_gain to 255 and every other band
    onto its scalefactor cap: both starts, with and without them, and
    both scalefac_scale are tried and the cheapest kept.  False when the
    result does not fit AMaxBits. }
  function VbrQuantize: Boolean;
  var qe: array[0..QUANT_SFB_LMAX - 1] of Integer;
      bb, s, g, gTop, gTopC, cand, a, cap, st: Integer;
      bestBits: Integer;
  begin
    Result := False;
    gTop := 0; gTopC := 0;
    for bb := 0 to QUANT_SFB_LMAX - 1 do begin
      qe[bb] := VbrBandExp(AState, AQ, xrAbs, xr34, bandLo[bb], bandLo[bb + 1],
        AXmin[bb], hasEnergy[bb]);
      if qe[bb] + 210 > gTop then gTop := qe[bb] + 210;
      if (qe[bb] < VBR_E_MAX) and (qe[bb] + 210 > gTopC) then gTopC := qe[bb] + 210;
    end;
    if gTop > 255 then gTop := 255;
    if gTop = gTopC then gTopC := -1;
    bestBits := MaxInt;
    for cand := 0 to 3 do begin
      s := cand and 1;
      st := 2 * (1 + s);
      { coarsest global gain whose amplifications fit the scalefactor caps;
        sfb 21 has no scalefactor }
      if cand < 2 then g := gTop
      else if gTopC >= 0 then g := gTopC
      else Break;
      if g > qe[21] + 210 then g := qe[21] + 210;
      for bb := 0 to 20 do begin
        if bb < 11 then cap := SF_CAP_LOW else cap := SF_CAP_HIGH;
        if g > qe[bb] + 210 + cap * st then g := qe[bb] + 210 + cap * st;
      end;
      if g < 0 then g := 0;
      FillChar(sf, SizeOf(sf), 0);
      for bb := 0 to 20 do begin
        a := g - 210 - qe[bb];
        if a > 0 then sf[bb] := (a + st - 1) div st;
      end;
      sfScale := s;
      ComputeAdj;
      sfc := LoopChooseScalefacCompress(sf);
      if sfc < 0 then Continue;
      part2 := LoopScalefacBits(sfc);
      bits := QuantizeAndCount(g);
      if (bits = MaxInt) or (part2 + bits > AMaxBits) or (part2 + bits >= bestBits) then Continue;
      bestBits := part2 + bits;
      MeasureNoise(g);
      SaveBest(g, bits, sfc, part2);
      bestNoiseE := totNoiseE;
      bestValid := True; bestOver := overCount; bestOverDb := overDb;
      Result := True;
    end;
  end;

begin
  AStats := Default(TLoopStats);
  for i := 0 to QUANT_GRANULE - 1 do begin
    xrAbs[i] := Abs(AXr[i]);
    if xrAbs[i] > 0.0 then xr34[i] := Power(xrAbs[i], 0.75) else xr34[i] := 0.0;
  end;
  for b := 0 to QUANT_SFB_LMAX do bandLo[b] := QuantSfbBand(ASrIdx, b);
  for b := 0 to QUANT_SFB_LMAX - 1 do begin
    width[b] := bandLo[b + 1] - bandLo[b];
    hasEnergy[b] := False;
    for i := bandLo[b] to bandLo[b + 1] - 1 do
      if xrAbs[i] > 0.0 then begin hasEnergy[b] := True; Break; end;
    amplified[b] := False;
  end;

  FillChar(sf, SizeOf(sf), 0);
  sfScale := 0;
  bestValid := False; bestOver := MaxInt; bestOverDb := 0; bestTotDb := 0; bestIter := 0; bestNoiseE := 0; bestOverSsd := 0;
  bestGr := Default(TGrInfo);
  if AMaxBits < 0 then AMaxBits := 0;

  iter := 0;
  vbrOk := AVbr and VbrQuantize;
  if not vbrOk then begin
    FillChar(sf, SizeOf(sf), 0);
    sfScale := 0;
  end;
  if not vbrOk then
  repeat
    ComputeAdj;
    sfc := LoopChooseScalefacCompress(sf);
    if sfc < 0 then Break;                     { cannot happen with the caps }
    part2  := LoopScalefacBits(sfc);
    budget := AMaxBits - part2;
    if budget < 0 then Break;

    gg := InnerLoop(budget, bits);
    { nothing codable within the budget, even at the coarsest gain: keep best }
    if (bits = MaxInt) or (bits > budget) then Break;

    MeasureNoise(gg);

    { bit saving: when every band is already below its threshold, coarsen
      the quantization while that stays true (the inner loop always spends
      the whole budget, which would waste bits on silence or masked signal) }
    if overCount = 0 then begin
      k := 0;
      while (gg < 255) and (k < LOOP_MAX_SAVE_STEPS) and (part2 + bits > AMinBits) do begin
        i := QuantizeAndCount(gg + 1);
        if i = MaxInt then Break;
        MeasureNoise(gg + 1);
        if (overCount > 0) or (part2 + i < AMinBits) then begin
          { undo: back to the last good gain }
          bits := QuantizeAndCount(gg);
          MeasureNoise(gg);
          Break;
        end;
        Inc(gg); bits := i; Inc(k);
      end;
    end;

    { LAME quant_compare (default): smallest sum of squared excesses over the
      threshold, then smallest total noise.  Counting bands (dist10) lets the
      loop pick solutions that drop whole bands by 20-30 dB. }
    better := not bestValid or (overSsd < bestOverSsd) or
              ((overSsd = bestOverSsd) and (totDb < bestTotDb));
    if better then begin
      SaveBest(gg, bits, sfc, part2);
      bestNoiseE := totNoiseE;
      bestValid := True; bestOver := overCount; bestOverDb := overDb; bestTotDb := totDb; bestOverSsd := overSsd;
      bestIter := iter;
    end;
    Inc(iter);
    if overCount = 0 then Break;
    if iter >= LOOP_MAX_ITER then Break;
    if gg = 255 then Break;                    { nothing coded at all }

    { amplify the bands above threshold (sfb 21 has no scalefactor) }
    anyAmp := False;
    for b := 0 to 20 do begin
      if not over[b] then Continue;
      if b < 11 then k := SF_CAP_LOW else k := SF_CAP_HIGH;
      if sf[b] < k then begin
        Inc(sf[b]); amplified[b] := True; anyAmp := True;
      end else if sfScale = 0 then begin
        { switch to 6 dB steps: halve every scalefactor (rounding up) }
        sfScale := 1;
        for i := 0 to 20 do sf[i] := (sf[i] + 1) div 2;
        Inc(sf[b]); amplified[b] := True; anyAmp := True;
      end;
      { else: band saturated, cannot be amplified further }
    end;
    if not anyAmp then Break;

    { every band with energy amplified at least once: a global gain change
      would do the same, stop (dist10 loop_break) }
    allAmp := True;
    for b := 0 to 20 do
      if hasEnergy[b] and not amplified[b] then begin allAmp := False; Break; end;
    if allAmp then Break;
  until False;

  if not bestValid then begin
    { budget too small even for empty scalefactors: emit silence }
    bestGr := Default(TGrInfo);
    bestGr.SrIdx := ASrIdx;
    bestGr.BlockType := ABlockType;
    bestGr.GlobalGain := 255;
    bestGr.Region0Count := RC_REGION0_COUNT;
    bestGr.Region1Count := RC_REGION1_COUNT;
    bestOver := 0; bestOverDb := 0;
  end;
  AGr := bestGr;
  AStats.Iterations := iter;
  AStats.OverBands  := bestOver;
  AStats.OverDb     := bestOverDb;
  AStats.NoiseE     := bestNoiseE;
  AStats.SignalE    := 0.0;
  for i := 0 to QUANT_GRANULE - 1 do AStats.SignalE := AStats.SignalE + Sqr(xrAbs[i]);
  AStats.GlobalGain := AGr.GlobalGain;
  AStats.ScalefacScale := AGr.ScalefacScale;
  AStats.Preflag := AGr.Preflag;
  AStats.MaxSf := 0;
  for b := 0 to 20 do if AGr.ScalefacL[b] > AStats.MaxSf then AStats.MaxSf := AGr.ScalefacL[b];
  if bestIter < 0 then AStats.Iterations := 0;
  Result := AGr.Part2_3_Length;
end;

// ---------------------------------------------------------------------------
// Short blocks
// ---------------------------------------------------------------------------

const
  SF_CAP_S_LOW  = 15;   { sfb 0..5  (slen1 <= 4 bits) }
  SF_CAP_S_HIGH = 7;    { sfb 6..11 (slen2 <= 3 bits) }
  NB_SHORT = QUANT_SFB_SMAX * 3;   { 39 bands: sfb x window }

function LoopEncodeGranuleShort(const AState: TLoopState; const AQ: TQuantState;
  const AXr: T576; const AXmin: TPsyShortArr; AMaxBits, AMinBits, ASrIdx: Integer;
  out AGr: TGrInfo; out AStats: TLoopStats; AVbr: Boolean): Integer;
type
  TSfS = array[0..QUANT_SFB_SMAX - 1, 0..2] of Integer;
var
  xrAbs, xr34 : T576;
  bandLo      : array[0..NB_SHORT] of Integer;    { band j = sfb*3 + window }
  width       : array[0..NB_SHORT - 1] of Integer;
  xminB       : array[0..NB_SHORT - 1] of Double;
  hasEnergy, amplified, over : array[0..NB_SHORT - 1] of Boolean;
  adj         : array[0..NB_SHORT - 1] of Integer;
  sf          : TSfS;
  sbg         : array[0..2] of Integer;
  sfScale     : Integer;
  ix          : T576Int;
  params      : TRCtrlParams;
  bestGr      : TGrInfo;
  bestValid   : Boolean;
  bestOverSsd, bestTotDb, bestNoiseE, overDb, totDb, totNoiseE, overSsd: Double;
  overCount, bestOver, iter, j, b, w, i, k, sfc, part2, budget, gg, bits, lo: Integer;
  anyAmp, allAmp, better, vbrOk: Boolean;

  function ChooseSfc(out ABits: Integer): Integer;
  var m1, m2, bb, ww, ii: Integer;
  begin
    m1 := 0; m2 := 0;
    for bb := 0 to 11 do
      for ww := 0 to 2 do
        if bb < 6 then begin if sf[bb][ww] > m1 then m1 := sf[bb][ww]; end
        else if sf[bb][ww] > m2 then m2 := sf[bb][ww];
    Result := -1; ABits := MaxInt;
    for ii := 0 to 15 do
      if (m1 < (1 shl SLEN1_TAB[ii])) and (m2 < (1 shl SLEN2_TAB[ii])) and
         (18 * SLEN1_TAB[ii] + 18 * SLEN2_TAB[ii] < ABits) then begin
        ABits := 18 * SLEN1_TAB[ii] + 18 * SLEN2_TAB[ii];
        Result := ii;
      end;
  end;

  procedure ComputeAdj;
  var bb, ww: Integer;
  begin
    for bb := 0 to QUANT_SFB_SMAX - 1 do
      for ww := 0 to 2 do
        adj[bb * 3 + ww] := -2 * (1 + sfScale) * sf[bb][ww] - 8 * sbg[ww];
  end;

  function QuantizeAndCount(AGain: Integer): Integer;
  var jj, ii, e, q: Integer; f: Double;
  begin
    for jj := 0 to NB_SHORT - 1 do begin
      e := AGain - 210 + adj[jj] + LOOP_TAB_OFS;
      if e < 0 then e := 0 else if e > 2 * LOOP_TAB_OFS then e := 2 * LOOP_TAB_OFS;
      f := AState.Pow2Q34[e];
      for ii := bandLo[jj] to bandLo[jj + 1] - 1 do
        if xr34[ii] = 0.0 then ix[ii] := 0
        else begin
          q := Trunc(xr34[ii] * f + QUANT_BIAS);
          if q > 8206 then Exit(MaxInt);
          ix[ii] := q;
        end;
    end;
    RateCtrlFillParams(ix, ASrIdx, params, 2);
    Result := RateCtrlHuffBits(ix, params);
  end;

  function InnerLoop(ABudget: Integer; out ABits: Integer): Integer;
  var lo2, hi2, mid, bb: Integer;
  begin
    lo2 := 0; hi2 := 255; Result := 255;
    while lo2 <= hi2 do begin
      mid := (lo2 + hi2) shr 1;
      bb := QuantizeAndCount(mid);
      if bb <= ABudget then begin Result := mid; hi2 := mid - 1; end
      else lo2 := mid + 1;
    end;
    ABits := QuantizeAndCount(Result);
  end;

  procedure MeasureNoise(AGain: Integer);
  var jj, ii, kk: Integer; st, vv, nn: Double;
  begin
    overCount := 0; overDb := 0.0; totDb := 0.0; totNoiseE := 0.0; overSsd := 0.0;
    for jj := 0 to NB_SHORT - 1 do begin
      kk := AGain - 210 + adj[jj] + LOOP_TAB_OFS;
      if kk < 0 then kk := 0 else if kk > 2 * LOOP_TAB_OFS then kk := 2 * LOOP_TAB_OFS;
      st := AState.Pow2Q[kk];
      nn := 0.0;
      for ii := bandLo[jj] to bandLo[jj + 1] - 1 do begin
        if ix[ii] = 0 then vv := 0.0
        else if ix[ii] < QUANT_POW43_MAX then vv := AQ.Pow43[ix[ii]] * st
        else vv := Power(ix[ii], 4.0 / 3.0) * st;
        nn := nn + Sqr(xrAbs[ii] - vv);
      end;
      totNoiseE := totNoiseE + nn;
      if width[jj] > 0 then nn := nn / width[jj];
      over[jj] := (xminB[jj] > 0.0) and (nn > xminB[jj]);
      if (xminB[jj] > 0.0) and (nn > 0.0) then begin
        vv := 10.0 * Log10(nn / xminB[jj]);
        totDb := totDb + vv;
        if over[jj] then begin Inc(overCount); overDb := overDb + vv; overSsd := overSsd + vv * vv; end;
      end;
    end;
  end;

  procedure SaveBest(AGain, AHuffBits, ASfc, APart2: Integer);
  var ii, bb, ww: Integer;
  begin
    bestGr := Default(TGrInfo);
    bestGr.SrIdx := ASrIdx;
    bestGr.BlockType := 2;
    bestGr.GlobalGain := AGain;
    bestGr.BigValues := params.BigValues;
    bestGr.Count1 := params.Count1;
    bestGr.Count1TableSelect := params.Count1TableSelect;
    bestGr.TableSelect[0] := params.TableSelect[0];
    bestGr.TableSelect[1] := params.TableSelect[1];
    bestGr.ScalefacScale := sfScale;
    for ww := 0 to 2 do bestGr.SubblockGain[ww] := sbg[ww];
    for bb := 0 to QUANT_SFB_SMAX - 1 do
      for ww := 0 to 2 do bestGr.ScalefacS[bb][ww] := sf[bb][ww];
    for ii := 0 to QUANT_GRANULE - 1 do
      if (ix[ii] <> 0) and (AXr[ii] < 0.0) then bestGr.Ix[ii] := -ix[ii]
      else bestGr.Ix[ii] := ix[ii];
    bestGr.ScalefacCompress := ASfc;
    bestGr.Part2_3_Length := APart2 + AHuffBits;
  end;

  { Quality mode, as in LoopEncodeGranule: global_gain from the coarsest
    band, subblock_gain and scalefactors bring every band of each window
    down to its own step (sfb 12 has no scalefactor). }
  function VbrQuantize: Boolean;
  var qe: array[0..NB_SHORT - 1] of Integer;
      jj, bb, ww, s, g, gTop, gTopC, cand, a, cap, st, need, bestBits: Integer;
      ok: Boolean;
  begin
    Result := False;
    gTop := 0; gTopC := 0;
    for jj := 0 to NB_SHORT - 1 do begin
      qe[jj] := VbrBandExp(AState, AQ, xrAbs, xr34, bandLo[jj], bandLo[jj + 1],
        xminB[jj], hasEnergy[jj]);
      if qe[jj] + 210 > gTop then gTop := qe[jj] + 210;
      if (qe[jj] < VBR_E_MAX) and (qe[jj] + 210 > gTopC) then gTopC := qe[jj] + 210;
    end;
    if gTop > 255 then gTop := 255;
    if gTop = gTopC then gTopC := -1;
    bestBits := MaxInt;
    for cand := 0 to 3 do begin
      s := cand and 1;
      st := 2 * (1 + s);
      { coarsest global gain for which every window finds a subblock_gain
        (0..7, 8 steps each) that leaves its scalefactors within the caps;
        started from the coarsest band with and without the free ones }
      if cand < 2 then g := gTop + 1
      else if gTopC >= 0 then g := gTopC + 1
      else Break;
      repeat
        Dec(g);
        ok := True;
        for ww := 0 to 2 do begin
          need := 0;
          for bb := 0 to QUANT_SFB_SMAX - 1 do begin
            a := g - 210 - qe[bb * 3 + ww];
            if bb = 12 then cap := 0
            else if bb < 6 then cap := SF_CAP_S_LOW * st
            else cap := SF_CAP_S_HIGH * st;
            if a - cap > need then need := a - cap;
          end;
          sbg[ww] := (need + 7) div 8;
          if sbg[ww] > 7 then ok := False;
        end;
      until ok or (g = 0);
      if not ok then Continue;
      FillChar(sf, SizeOf(sf), 0);
      for bb := 0 to 11 do
        for ww := 0 to 2 do begin
          a := g - 210 - qe[bb * 3 + ww] - 8 * sbg[ww];
          if a > 0 then sf[bb][ww] := (a + st - 1) div st;
        end;
      sfScale := s;
      ComputeAdj;
      sfc := ChooseSfc(part2);
      if sfc < 0 then Continue;
      bits := QuantizeAndCount(g);
      if (bits = MaxInt) or (part2 + bits > AMaxBits) or (part2 + bits >= bestBits) then Continue;
      bestBits := part2 + bits;
      MeasureNoise(g);
      SaveBest(g, bits, sfc, part2);
      bestValid := True; bestOver := overCount; bestOverSsd := overSsd;
      bestTotDb := totDb; bestNoiseE := totNoiseE;
      Result := True;
    end;
  end;

begin
  AStats := Default(TLoopStats);
  for i := 0 to QUANT_GRANULE - 1 do begin
    xrAbs[i] := Abs(AXr[i]);
    if xrAbs[i] > 0.0 then xr34[i] := Power(xrAbs[i], 0.75) else xr34[i] := 0.0;
  end;
  { bit-stream order: for each sfb, window 0, 1, 2 }
  lo := 0;
  for b := 0 to QUANT_SFB_SMAX - 1 do
    for w := 0 to 2 do begin
      j := b * 3 + w;
      bandLo[j] := lo;
      width[j] := QuantSfbShort(ASrIdx, b + 1) - QuantSfbShort(ASrIdx, b);
      xminB[j] := AXmin[b][w];
      Inc(lo, width[j]);
    end;
  bandLo[NB_SHORT] := lo;
  for j := 0 to NB_SHORT - 1 do begin
    hasEnergy[j] := False;
    for i := bandLo[j] to bandLo[j + 1] - 1 do
      if xrAbs[i] > 0.0 then begin hasEnergy[j] := True; Break; end;
    amplified[j] := False;
  end;

  FillChar(sf, SizeOf(sf), 0);
  FillChar(sbg, SizeOf(sbg), 0);
  sfScale := 0;
  bestValid := False; bestOver := 0; bestOverSsd := 0; bestTotDb := 0; bestNoiseE := 0;
  bestGr := Default(TGrInfo);
  if AMaxBits < 0 then AMaxBits := 0;

  iter := 0;
  vbrOk := AVbr and VbrQuantize;
  if not vbrOk then begin
    FillChar(sf, SizeOf(sf), 0);
    FillChar(sbg, SizeOf(sbg), 0);
    sfScale := 0;
  end;
  if not vbrOk then
  repeat
    ComputeAdj;
    sfc := ChooseSfc(part2);
    if sfc < 0 then Break;
    budget := AMaxBits - part2;
    if budget < 0 then Break;
    gg := InnerLoop(budget, bits);
    if (bits = MaxInt) or (bits > budget) then Break;
    MeasureNoise(gg);

    if overCount = 0 then begin
      k := 0;
      while (gg < 255) and (k < LOOP_MAX_SAVE_STEPS) and (part2 + bits > AMinBits) do begin
        i := QuantizeAndCount(gg + 1);
        if i = MaxInt then Break;
        MeasureNoise(gg + 1);
        if (overCount > 0) or (part2 + i < AMinBits) then begin
          bits := QuantizeAndCount(gg);
          MeasureNoise(gg);
          Break;
        end;
        Inc(gg); bits := i; Inc(k);
      end;
    end;

    better := not bestValid or (overSsd < bestOverSsd) or
              ((overSsd = bestOverSsd) and (totDb < bestTotDb));
    if better then begin
      SaveBest(gg, bits, sfc, part2);
      bestValid := True; bestOver := overCount; bestOverSsd := overSsd;
      bestTotDb := totDb; bestNoiseE := totNoiseE;
    end;
    Inc(iter);
    if (overCount = 0) or (iter >= LOOP_MAX_ITER) or (gg = 255) then Break;

    { amplify the bands above threshold (sfb 12 has no scalefactor) }
    anyAmp := False;
    for j := 0 to 12 * 3 - 1 do begin
      if not over[j] then Continue;
      b := j div 3; w := j mod 3;
      if b < 6 then k := SF_CAP_S_LOW else k := SF_CAP_S_HIGH;
      if sf[b][w] < k then begin
        Inc(sf[b][w]); amplified[j] := True; anyAmp := True;
      end else if sfScale = 0 then begin
        sfScale := 1;
        for i := 0 to QUANT_SFB_SMAX - 1 do
          for k := 0 to 2 do sf[i][k] := (sf[i][k] + 1) div 2;
        Inc(sf[b][w]); amplified[j] := True; anyAmp := True;
      end else if sbg[w] < 7 then begin
        { the whole window gets 12 dB finer: take that back from its
          scalefactors (2 steps of 6 dB) and amplify this band }
        Inc(sbg[w]);
        for i := 0 to 11 do sf[i][w] := Max(sf[i][w] - 2, 0);
        Inc(sf[b][w]); amplified[j] := True; anyAmp := True;
      end;
    end;
    if not anyAmp then Break;
    allAmp := True;
    for j := 0 to 12 * 3 - 1 do
      if hasEnergy[j] and not amplified[j] then begin allAmp := False; Break; end;
    if allAmp then Break;
  until False;

  if not bestValid then begin
    bestGr := Default(TGrInfo);
    bestGr.SrIdx := ASrIdx;
    bestGr.BlockType := 2;
    bestGr.GlobalGain := 255;
  end;
  AGr := bestGr;
  AStats.Iterations := iter;
  AStats.OverBands := bestOver;
  AStats.NoiseE := bestNoiseE;
  AStats.SignalE := 0.0;
  for i := 0 to QUANT_GRANULE - 1 do AStats.SignalE := AStats.SignalE + Sqr(xrAbs[i]);
  AStats.GlobalGain := AGr.GlobalGain;
  AStats.ScalefacScale := AGr.ScalefacScale;
  Result := AGr.Part2_3_Length;
end;

end.
