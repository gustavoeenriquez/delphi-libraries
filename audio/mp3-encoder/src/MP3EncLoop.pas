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
  out AGr: TGrInfo; out AStats: TLoopStats): Integer;

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

function LoopEncodeGranule(const AState: TLoopState; const AQ: TQuantState;
  const AXr: T576; const AXmin: TPsyBandArr; AMaxBits, AMinBits, ASrIdx: Integer;
  out AGr: TGrInfo; out AStats: TLoopStats): Integer;
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
  anyAmp, allAmp, better: Boolean;

  procedure ComputeAdj;
  var bb: Integer;
  begin
    for bb := 0 to QUANT_SFB_LMAX - 1 do
      adj[bb] := -2 * (1 + sfScale) * sf[bb];   { preflag applied at the end }
  end;

  { Quantize with global gain AGain; returns the Huffman bit count
    (MaxInt when a value cannot be coded) and fills ix / params. }
  function QuantizeAndCount(AGain: Integer): Integer;
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
    RateCtrlFillParams(ix, ASrIdx, params);
    Result := RateCtrlHuffBits(ix, params);
  end;

  { Binary search of the smallest global_gain whose Huffman bits fit ABudget.
    Leaves ix / params for that gain; returns the gain and its bit count. }
  function InnerLoop(ABudget: Integer; out ABits: Integer): Integer;
  var lo, hi, mid, bb: Integer;
  begin
    lo := 0; hi := 255; Result := 255; ABits := 0;
    while lo <= hi do begin
      mid := (lo + hi) shr 1;
      bb := QuantizeAndCount(mid);
      if bb <= ABudget then begin
        Result := mid; ABits := bb; hi := mid - 1;
      end else
        lo := mid + 1;
    end;
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
  repeat
    ComputeAdj;
    sfc := LoopChooseScalefacCompress(sf);
    if sfc < 0 then Break;                     { cannot happen with the caps }
    part2  := LoopScalefacBits(sfc);
    budget := AMaxBits - part2;
    if budget < 0 then Break;

    gg := InnerLoop(budget, bits);
    if bits = MaxInt then Break;               { nothing codable: keep best }

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

end.
