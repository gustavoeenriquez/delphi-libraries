program TestMP3EncPhase19;

{
  Phase 19 tests — psychoacoustic model, noise-shaping loop, bit reservoir,
  automatic MS stereo and decode round trips through mp3-decoder.

  PS: MP3EncPsy      (ATH, Bark, spreading, thresholds, tonality)
  PF: MP3EncPsy      (FFT model: partitions, tonal vs noise ratios)
  LP: MP3EncLoop     (scalefac_compress, loop budget, shaping, bit saving)
  RC: MP3EncRateCtrl (fast Huffman table choice, best region split)
  RV: MP3EncEncoder  (reservoir accounting, flush, lowpass, MS/LR, round trip)
}

{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, Math,
  MP3EncQuantize, MP3EncHuffman, MP3EncFrame, MP3EncRateCtrl,
  MP3EncPsy, MP3EncLoop, MP3EncEncoder,
  AudioTypes, AudioCodec;

var
  GPassed, GFailed: Integer;

procedure Check(const AName: string; ACondition: Boolean);
begin
  if ACondition then begin Inc(GPassed); WriteLn('  PASS  ', AName); end
  else begin Inc(GFailed); WriteLn('** FAIL  ', AName); end;
end;

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

type
  TDoubles = TArray<Double>;

function Sine(AFreq, AAmp: Double; AIdx: Integer): Double;
begin
  Result := AAmp * Sin(2 * Pi * AFreq * AIdx / 48000.0);
end;

{ Decode an MP3 byte array with mp3-decoder (via audio-codec); planar output. }
function DecodeMP3(const AData: TBytes; out AOut: array of TDoubles): Integer;
var
  St: TBytesStream;
  Dec: IAudioDecoder;
  Buf: TAudioBuffer;
  R: TAudioDecodeResult;
  ch, i, n, base: Integer;
begin
  Result := 0;
  for ch := 0 to High(AOut) do AOut[ch] := nil;
  St := TBytesStream.Create(AData);
  Dec := CreateAudioDecoder(St, True);
  if Dec = nil then Exit;
  repeat
    R := Dec.Decode(Buf);
    if R <> adrOK then Break;
    n := AudioBufferFrameCount(Buf);
    for ch := 0 to Min(High(AOut), Length(Buf) - 1) do begin
      base := Length(AOut[ch]);
      SetLength(AOut[ch], base + n);
      for i := 0 to n - 1 do AOut[ch][base + i] := Buf[ch][i];
    end;
    Inc(Result, n);
  until False;
end;

{ SNR (dB) of B[AOfsB..] against A[AOfsA..] over ACount samples. }
function SnrDb(const A: TDoubles; AOfsA: Integer; const B: TDoubles;
  AOfsB, ACount: Integer): Double;
var
  i: Integer;
  s, e: Double;
begin
  s := 0; e := 0;
  for i := 0 to ACount - 1 do begin
    s := s + Sqr(A[AOfsA + i]);
    e := e + Sqr(A[AOfsA + i] - B[AOfsB + i]);
  end;
  Result := 10 * Log10((s + 1e-30) / (e + 1e-30));
end;

function MainDataBegin(const AData: TBytes; AOfs: Integer): Integer;
begin
  Result := (AData[AOfs + 4] shl 1) or (AData[AOfs + 5] shr 7);
end;

procedure AppendBytes(var ADst: TBytes; const ASrc: TBytes);
var
  n: Integer;
begin
  n := Length(ADst);
  SetLength(ADst, n + Length(ASrc));
  if Length(ASrc) > 0 then Move(ASrc[0], ADst[n], Length(ASrc));
end;

// ---------------------------------------------------------------------------
// PS: psychoacoustic model
// ---------------------------------------------------------------------------

procedure TestPsy;
var
  M, M2: TPsyModel;
  R: TPsyResult;
  Xr: T576;
  b, i, w: Integer;
  s: Double;
begin
  WriteLn('PS: MP3EncPsy');
  Check('PS01 ATH(1 kHz) in 2..5 dB', (PsyAthDb(1000) > 2) and (PsyAthDb(1000) < 5));
  Check('PS02 ATH minimum near 3.3 kHz', (PsyAthDb(3300) < PsyAthDb(1000)) and (PsyAthDb(3300) < PsyAthDb(10000)));
  Check('PS03 ATH rises below 100 Hz', PsyAthDb(50) > 20);
  Check('PS04 Bark monotonic', (PsyBarkOf(100) < PsyBarkOf(1000)) and (PsyBarkOf(1000) < PsyBarkOf(10000)));
  Check('PS05 Bark(1 kHz) ~ 8.5', Abs(PsyBarkOf(1000) - 8.5) < 1.0);

  PsyInit(M, 1);
  PsyInit(M2, 1, 0.0, PSY_ATH_HF, PSY_MINVAL + 7.5);
  Check('PS24 minval parameter: 7.5 dB more in band 3', Abs(M2.MinValDb[3] - M.MinValDb[3] - 7.5) < 1e-9);
  Check('PS25 ATH high-frequency coefficient: 1e-4 is > 20 dB lower at 14 kHz',
    PsyAthDb(14000, 1e-4) < PsyAthDb(14000) - 20);
  w := 0;
  for b := 0 to PSY_BANDS - 1 do Inc(w, M.Width[b]);
  Check('PS06 widths sum to 576', w = 576);
  s := 0; for i := 0 to PSY_BANDS - 1 do s := s + M.Spread[8][i];
  Check('PS07 spreading rows normalised', (M.Spread[0][0] < 1.0) and (Abs(s - 1.0) < 1e-9));
  Check('PS08 ATH per band positive and tiny', (M.AthLin[6] > 0) and (M.AthLin[6] < 1e-8));
  Check('PS09 ATH huge above 16 kHz', M.AthLin[21] > M.AthLin[6] * 1e6);

  FillChar(Xr, SizeOf(Xr), 0);
  PsyAnalyse(M, Xr, R);
  Check('PS10 silence: xmin = ATH', Abs(R.Xmin[6] - M.AthLin[6]) < 1e-20);
  Check('PS11 silence: no bit demand', R.EstBits = 0);
  PsyAnalyse(M, Xr, R, 0.01);
  Check('PS21 adaptive ATH: silence xmin = ATH x scale', Abs(R.Xmin[6] - M.AthLin[6] * 0.01) < 1e-22);

  Xr[24] := 0.5;   { ~1 kHz line, sfb 6 at 48 kHz }
  PsyAnalyse(M, Xr, R);
  Check('PS12 tone: energy in band 6', Abs(R.Energy[6] - 0.25) < 1e-12);
  Check('PS13 tone: masking well above ATH', R.Xmin[6] > M.AthLin[6] * 1e3);
  Check('PS14 tone: threshold below the signal', R.Xmin[6] * M.Width[6] < 0.25);
  Check('PS15 upward spreading stronger than downward', M.Spread[8][6] > M.Spread[4][6]);
  Check('PS22 empty band next to a tone: not masked (xmin = ATH)', Abs(R.Xmin[8] - M.AthLin[8]) < M.AthLin[8] * 1e-9);
  Xr[31] := 0.005;  { weak line in band 7, right above the tone }
  PsyAnalyse(M, Xr, R);
  Check('PS23 weak band next to a tone: threshold <= its energy - 12 dB',
    (R.Xmin[7] * M.Width[7] <= R.Energy[7] * PSY_SELF_MASK * 1.000001) and (R.Xmin[7] > M.AthLin[7]));
  Xr[31] := 0.0;
  PsyAnalyse(M, Xr, R);
  Check('PS16 tone: far band at ATH', Abs(R.Xmin[21] - M.AthLin[21]) < M.AthLin[21] * 1e-6);
  Check('PS17 tone: tonal', R.Tonality > 0.5);
  Check('PS18 tone: bit demand > 0', R.EstBits > 10);

  RandSeed := 7;
  for i := 0 to 575 do Xr[i] := (Random - 0.5) * 0.2;
  PsyAnalyse(M, Xr, R);
  Check('PS19 noise: noise-like', R.Tonality < 0.3);
  s := 0; for b := 0 to PSY_BANDS - 1 do s := s + R.Energy[b];
  for i := 0 to 575 do s := s - Sqr(Xr[i]);
  Check('PS20 noise: energies sum to total', Abs(s) < 1e-9);
end;

{ FFT model: three granules (hop 576) of a signal, ratio of the last one. }
procedure FFTRatio(const AM: TPsyModel; AKind: Integer; out ARatio: TPsyBandArr);
var
  St: TPsyFFTState;
  Buf: TPsyFFTBuf;
  g, i: Integer;
begin
  PsyFFTReset(St);
  RandSeed := 11;
  for g := 0 to 2 do begin
    for i := 0 to PSY_FFT_LONG - 1 do
      case AKind of
        0: Buf[i] := 0.0;
        1: Buf[i] := Sine(1000, 8000, g * 576 + i);
      else Buf[i] := (Random - 0.5) * 16000;
      end;
    PsyAnalyseFFT(AM, St, Buf, ARatio);
  end;
end;

procedure TestPsyFFT;
var
  M: TPsyModel;
  RS, RT, RN: TPsyBandArr;
  R: TPsyResult;
  b: Integer;
  ok: Boolean;
begin
  WriteLn('PF: MP3EncPsy FFT model');
  PsyInit(M, 1);
  Check('PF01 about 1/3 Bark partitions', (M.NPart > 50) and (M.NPart <= PSY_MAXPART));
  Check('PF02 partitions cover the 512 lines', (M.PartLo[0] = 0) and (M.PartHi[M.NPart - 1] = PSY_FFT_LINES));
  ok := True;
  for b := 1 to PSY_BANDS - 1 do
    if M.SfbFftLo[b] < M.SfbFftHi[b - 1] - 1 then ok := False;
  Check('PF03 scalefactor bands map to increasing FFT lines', ok and (M.SfbFftHi[PSY_BANDS - 1] = PSY_FFT_LINES));

  FFTRatio(M, 0, RS);
  Check('PF04 silence: ratio 0', RS[6] = 0.0);
  FFTRatio(M, 1, RT);
  FFTRatio(M, 2, RN);
  { 1 kHz is in sfb 6 at 48 kHz: a steady tone is predictable (tonal, ~29 dB
    plus spreading), noise is not (6 dB, raised to minval = 24.5 - 8.5 Bark) }
  Check('PF05 tone: threshold > 20 dB under the signal', (RT[6] > 0) and (RT[6] < 0.01));
  Check('PF06 noise: threshold 10..20 dB under the signal', (RN[6] > 0.01) and (RN[6] < 0.1));
  Check('PF07 noise more masking than tone', RN[6] > 10 * RT[6]);

  { ratio applied to MDCT energies, ATH as the floor }
  FillChar(R, SizeOf(R), 0);
  R.Energy[6] := 0.25;
  PsyApplyRatio(M, RN, R);
  Check('PF08 apply: xmin = ratio * E / width', Abs(R.Xmin[6] - RN[6] * 0.25 / M.Width[6]) < 1e-15);
  Check('PF09 apply: empty band at ATH', Abs(R.Xmin[12] - M.AthLin[12]) < 1e-20);
  Check('PF10 apply: bit demand > 0', R.EstBits > 0);
end;

// ---------------------------------------------------------------------------
// LP: loop
// ---------------------------------------------------------------------------

procedure BandNoise(const AQ: TQuantState; const AXr: T576; const AGr: TGrInfo;
  ASrIdx: Integer; out ANoise: TPsyBandArr);
var
  Deq: T576;
  b, i: Integer;
begin
  DequantizeBlock(AQ, AGr.Ix, AXr, AGr.GlobalGain, AGr.ScalefacL,
    AGr.ScalefacScale, AGr.Preflag, ASrIdx, Deq);
  for b := 0 to QUANT_SFB_LMAX - 1 do begin
    ANoise[b] := 0;
    for i := QuantSfbBand(ASrIdx, b) to QuantSfbBand(ASrIdx, b + 1) - 1 do
      ANoise[b] := ANoise[b] + Sqr(AXr[i] - Deq[i]);
  end;
end;

procedure TestLoop;
var
  L: TLoopState;
  Q: TQuantState;
  Sf: TScalefacL;
  Xr: T576;
  Xmin, N1, N2: TPsyBandArr;
  Gr, Gr2: TGrInfo;
  St: TLoopStats;
  i, bits, bits2, b, n: Integer;
  scfsi: array[0..3] of Byte;
  ok: Boolean;
begin
  WriteLn('LP: MP3EncLoop');
  LoopInit(L);
  QuantInit(Q);
  FillChar(Sf, SizeOf(Sf), 0);
  Check('LP01 sfc(all zero) = 0', LoopChooseScalefacCompress(Sf) = 0);
  Sf[0] := 1;
  Check('LP02 sfc(sf0=1) = 5 (slen 1/1, 21 bits)', (LoopChooseScalefacCompress(Sf) = 5) and (LoopScalefacBits(5) = 21));
  FillChar(Sf, SizeOf(Sf), 0); Sf[15] := 7;
  Check('LP03 sfc(sf15=7) = 3 (slen 0/3)', LoopChooseScalefacCompress(Sf) = 3);
  FillChar(Sf, SizeOf(Sf), 0); Sf[0] := 15;
  Check('LP04 sfc(sf0=15) = 14 (slen 4/2)', LoopChooseScalefacCompress(Sf) = 14);
  Sf[15] := 8;
  Check('LP05 sfc(sf15=8) impossible = -1', LoopChooseScalefacCompress(Sf) = -1);

  for b := 0 to PSY_BANDS - 1 do Xmin[b] := 1e-10;
  FillChar(Xr, SizeOf(Xr), 0);
  bits := LoopEncodeGranule(L, Q, Xr, Xmin, 1000, 0, 1, Gr, St);
  Check('LP06 silence -> 0 bits', (bits = 0) and (Gr.BigValues = 0) and (Gr.Count1 = 0));

  Xr[24] := 0.5; Xr[25] := -0.1; Xr[100] := 0.02;
  bits := LoopEncodeGranule(L, Q, Xr, Xmin, 1000, 0, 1, Gr, St);
  Check('LP07 tone fits the budget', (bits > 0) and (bits <= 1000));
  Check('LP08 part2_3 = scalefac bits + huffman bits', bits = Gr.Part2_3_Length);
  FillChar(scfsi, SizeOf(scfsi), 0);
  Check('LP09 part2_3 consistent with frame writer',
    Gr.Part2_3_Length = FrameScalefacBits(Gr, 0, scfsi) + FrameHuffmanBits(Gr));
  Check('LP10 signs restored', (Gr.Ix[24] > 0) and (Gr.Ix[25] < 0));
  BandNoise(Q, Xr, Gr, 1, N1);
  Check('LP11 tone coded accurately (strict xmin)', N1[6] < 0.25 * 1e-4);

  bits2 := LoopEncodeGranule(L, Q, Xr, Xmin, 40, 0, 1, Gr2, St);
  Check('LP12 tiny budget respected', bits2 <= 40);

  { bit saving: loose thresholds -> few bits; AMinBits forces spending }
  RandSeed := 11;
  for i := 0 to 575 do Xr[i] := (Random - 0.5) * 0.2;
  for b := 0 to PSY_BANDS - 1 do Xmin[b] := 3e-3;   { ~0 dB SNR allowed }
  bits  := LoopEncodeGranule(L, Q, Xr, Xmin, 1500, 0, 1, Gr, St);
  bits2 := LoopEncodeGranule(L, Q, Xr, Xmin, 1500, 1400, 1, Gr2, St);
  Check('LP13 loose xmin + AMinBits=0 saves bits', bits < 1000);
  Check('LP14 AMinBits spends the bits', (bits2 >= 1300) and (bits2 <= 1500));
  BandNoise(Q, Xr, Gr, 1, N1); BandNoise(Q, Xr, Gr2, 1, N2);
  Check('LP15 more bits -> less noise', N2[10] < N1[10]);

  { noise shaping: strict threshold in band 10 only vs band 5 only
    (comfortable budget so the amplified band does not starve the rest) }
  for b := 0 to PSY_BANDS - 1 do Xmin[b] := 1e-2;
  Xmin[10] := 1e-9;
  LoopEncodeGranule(L, Q, Xr, Xmin, 1500, 0, 1, Gr, St);
  BandNoise(Q, Xr, Gr, 1, N1);
  Xmin[10] := 1e-2; Xmin[5] := 1e-9;
  LoopEncodeGranule(L, Q, Xr, Xmin, 1500, 0, 1, Gr2, St);
  BandNoise(Q, Xr, Gr2, 1, N2);
  Check('LP16 shaping: band 10 cleaner when demanded', N1[10] < N2[10]);
  Check('LP17 shaping: band 5 cleaner when demanded', N2[5] < N1[5]);
  Check('LP18 shaping uses scalefactors', (Gr.ScalefacL[10] > 0) or (Gr2.ScalefacL[5] > 0));
  Check('LP19 scalefac_compress representable', (Gr.ScalefacCompress >= 0) and (Gr.ScalefacCompress <= 15));

  { quality mode: every band at most at its threshold, fewer bits than the
    noise-shaping loop (which coarsens all bands together) }
  for b := 0 to PSY_BANDS - 1 do Xmin[b] := 1e-5 * (1 + (b mod 4) * 30);
  bits  := LoopEncodeGranule(L, Q, Xr, Xmin, 4095, 0, 1, Gr, St, 0, True);
  BandNoise(Q, Xr, Gr, 1, N1);
  ok := St.OverBands = 0;
  for b := 0 to PSY_BANDS - 1 do
    if N1[b] > Xmin[b] * (QuantSfbBand(1, b + 1) - QuantSfbBand(1, b)) * 1.000001 then ok := False;
  Check('LP20 quality mode: no band above its threshold', ok);
  Check('LP21 quality mode: part2_3 consistent with frame writer',
    Gr.Part2_3_Length = FrameScalefacBits(Gr, 0, scfsi) + FrameHuffmanBits(Gr));
  bits2 := LoopEncodeGranule(L, Q, Xr, Xmin, 4095, 0, 1, Gr2, St, 0, False);
  Check('LP22 quality mode: fewer bits than the noise-shaping loop', (bits > 0) and (bits < bits2));
  WriteLn(Format('       quality mode %d bits, noise-shaping loop %d bits', [bits, bits2]));
  n := 0;
  for b := 0 to 20 do
    if N1[b] > 0.25 * Xmin[b] * (QuantSfbBand(1, b + 1) - QuantSfbBand(1, b)) then Inc(n);
  Check('LP23 quality mode: most bands within 6 dB of their threshold', n >= 16);

  { short budget, every band above its threshold: the loop keeps shaping
    (one band amplified per iteration) instead of stopping after one round
    of amplifying them all }
  RandSeed := 5;
  for i := 0 to 575 do Xr[i] := (Random - 0.5) * 0.4 / (1 + i / 20);
  for b := 0 to PSY_BANDS - 1 do begin   { 20 dB under each band's energy }
    Xmin[b] := 0;
    for i := QuantSfbBand(1, b) to QuantSfbBand(1, b + 1) - 1 do Xmin[b] := Xmin[b] + Sqr(Xr[i]);
    Xmin[b] := 0.01 * Xmin[b] / (QuantSfbBand(1, b + 1) - QuantSfbBand(1, b));
  end;
  bits := LoopEncodeGranule(L, Q, Xr, Xmin, 700, 0, 1, Gr, St);
  WriteLn(Format('       short budget: %d iterations, %d bits', [St.Iterations, bits]));
  Check('LP24 short budget: the outer loop keeps shaping (> 5 iterations, budget kept)',
    (St.Iterations > 5) and (bits <= 700));
end;

// ---------------------------------------------------------------------------
// RC: fast table selection
// ---------------------------------------------------------------------------

function RegionBits(ATable: Integer; const AIx: T576Int; AStart, AEnd: Integer): Integer;
var
  i, b: Integer;
begin
  Result := 0; i := AStart;
  while i < AEnd do begin
    b := HuffCountPairBits(ATable, Abs(AIx[i]), Abs(AIx[i + 1]));
    if b = HUFF_INVALID then Exit(MaxInt);
    Inc(Result, b); Inc(i, 2);
  end;
end;

procedure TestFastTables;
var
  Ix: T576Int;
  i, trial, mx, tF, tE, bF, bE, worse: Integer;
begin
  WriteLn('RC: RateCtrlBestTableFast');
  HuffInit;
  RandSeed := 3;
  worse := 0;
  for trial := 0 to 59 do begin
    case trial mod 4 of
      0: mx := 1 + Random(3);
      1: mx := 4 + Random(12);
      2: mx := 16 + Random(100);
    else mx := 200 + Random(3000);
    end;
    for i := 0 to 575 do
      if Random(3) = 0 then Ix[i] := Random(mx + 1) - Random(mx + 1) else Ix[i] := 0;
    tF := RateCtrlBestTableFast(Ix, 0, 100);
    tE := RateCtrlBestTable(Ix, 0, 100);
    bF := RegionBits(tF, Ix, 0, 100);
    bE := RegionBits(tE, Ix, 0, 100);
    if (bF = MaxInt) or (bF > bE * 1.05 + 8) then Inc(worse);
  end;
  Check('RC01 fast choice within 5 % of exhaustive (60 trials)', worse = 0);
  FillChar(Ix, SizeOf(Ix), 0);
  Check('RC02 all-zero region -> table 0', RateCtrlBestTableFast(Ix, 0, 100) = 0);
  Ix[0] := 9000;
  Check('RC03 uncodable value -> 0', RateCtrlBestTableFast(Ix, 0, 2) = 0);
end;

{ Spectrum shaped like a real one: large at low frequencies, decaying. }
procedure SyntheticIx(ATrial: Integer; out AIx: T576Int);
var i, a: Integer;
begin
  for i := 0 to 575 do begin
    a := Round((5 + 40 * (ATrial mod 5)) * Exp(-i / (40.0 + 20 * (ATrial mod 7))) * Random);
    if Random(2) = 0 then a := -a;
    AIx[i] := a;
  end;
end;

procedure TestBestRegions;
var
  Ix: T576Int;
  P0, P1, P2: TRCtrlParams;
  Gr: TGrInfo;
  trial, b0, b1, b2, r0, r1, t0, t1, t2, s1, s2, bestB, worse, lim, wr, brute: Integer;
  sum0, sum1: Int64;
begin
  WriteLn('RC: best region split');
  RandSeed := 5;
  worse := 0; lim := 0; wr := 0; brute := 0; sum0 := 0; sum1 := 0;
  for trial := 0 to 39 do begin
    SyntheticIx(trial, Ix);
    RateCtrlFillParams(Ix, 0, P0, 0, False);
    RateCtrlFillParams(Ix, 0, P1, 0, True);
    b0 := RateCtrlHuffBits(Ix, P0);
    b1 := RateCtrlHuffBits(Ix, P1);
    Inc(sum0, b0); Inc(sum1, b1);
    if b1 > b0 then Inc(worse);
    if (P1.Region0Count > 15) or (P1.Region1Count > 7) or
       (P1.Region0Count + P1.Region1Count + 2 > QUANT_SFB_LMAX) then Inc(lim);
    { the frame writer must spend exactly the counted bits }
    Gr := Default(TGrInfo);
    Gr.SrIdx := 0; Gr.BlockType := 0; Gr.Ix := Ix;
    Gr.BigValues := P1.BigValues; Gr.Count1 := P1.Count1;
    Gr.Count1TableSelect := P1.Count1TableSelect;
    Gr.TableSelect[0] := P1.TableSelect[0]; Gr.TableSelect[1] := P1.TableSelect[1];
    Gr.TableSelect[2] := P1.TableSelect[2];
    Gr.Region0Count := P1.Region0Count; Gr.Region1Count := P1.Region1Count;
    if FrameHuffmanBits(Gr) <> b1 then Inc(wr);
    { exhaustive search over every split with the exhaustive table choice }
    if trial < 8 then begin
      bestB := MaxInt;
      for r0 := 0 to 15 do
        for r1 := 0 to 7 do begin
          if r0 + r1 + 2 > QUANT_SFB_LMAX then Break;
          P2 := P0; P2.Region0Count := r0; P2.Region1Count := r1;
          RateCtrlRegionStarts(P2, s1, s2);
          if s1 > P2.BigValues * 2 then s1 := P2.BigValues * 2;
          if s2 > P2.BigValues * 2 then s2 := P2.BigValues * 2;
          t0 := RateCtrlBestTable(Ix, 0, s1);
          t1 := RateCtrlBestTable(Ix, s1, s2);
          t2 := RateCtrlBestTable(Ix, s2, P2.BigValues * 2);
          P2.TableSelect[0] := t0; P2.TableSelect[1] := t1; P2.TableSelect[2] := t2;
          b2 := RateCtrlHuffBits(Ix, P2);
          if b2 < bestB then bestB := b2;
        end;
      if bestB <> b1 then Inc(brute);
    end;
  end;
  WriteLn(Format('       Huffman bits, fixed -> best split: %d -> %d (%.1f %%)',
    [sum0, sum1, 100.0 * (sum1 - sum0) / sum0]));
  Check('RC04 best split never costs more (40 trials)', worse = 0);
  Check('RC05 best split saves bits overall', sum1 < sum0);
  Check('RC06 region counts within the side info limits', lim = 0);
  Check('RC07 frame writer spends the counted bits', wr = 0);
  Check('RC08 equals the exhaustive search (8 trials)', brute = 0);
end;

// ---------------------------------------------------------------------------
// RV: encoder, reservoir, round trips
// ---------------------------------------------------------------------------

procedure TestEncoder;
const
  NFR = 12;
var
  Enc: TMP3Encoder;
  Cfg: TEncConfig;
  PCM, PCM_R: T1152;
  Frame, All, All2: TBytes;
  f, i, n, mdbMax, mdbNonZero, ofs: Integer;
  Input, InputR: TDoubles;
  Dec: array[0..1] of TDoubles;
  snr, snrR: Double;
begin
  WriteLn('RV: encoder / reservoir / round trip');
  Cfg.SrIdx := 1; Cfg.BrIdx := 9; Cfg.Padding := 0;

  { reference input }
  SetLength(Input, NFR * 1152);
  SetLength(InputR, NFR * 1152);
  for i := 0 to NFR * 1152 - 1 do begin
    Input[i]  := Sine(1000, 0.3, i) + Sine(3100, 0.1, i);
    InputR[i] := 0.5 * Input[i];
  end;

  { without reservoir: one frame in, one frame out }
  EncInit(Enc, Cfg);
  Check('RV01 FrameBytes 384 at 128k/48k', Enc.FrameBytes = 384);
  Check('RV02 lowpass default 128k mono = 19700 Hz', Enc.LowpassHz = 19700);
  All := nil;
  for f := 0 to NFR - 1 do begin
    for i := 0 to 1151 do PCM[i] := Input[f * 1152 + i] * 32768;
    Frame := EncodeFrame(Enc, PCM);
    if f = 0 then Check('RV03 no reservoir: 384 bytes per call', Length(Frame) = 384);
    AppendBytes(All, Frame);
  end;
  Frame := EncFlush(Enc);
  Check('RV04 no reservoir: flush is empty', Length(Frame) = 0);
  Check('RV05 no reservoir: total bytes', Length(All) = NFR * 384);
  mdbMax := 0;
  for f := 0 to NFR - 1 do mdbMax := Max(mdbMax, MainDataBegin(All, f * 384));
  Check('RV06 no reservoir: main_data_begin always 0', mdbMax = 0);
  n := DecodeMP3(All, Dec);
  Check('RV07 decodes all samples', n = NFR * 1152);
  snr := SnrDb(Input, 0, Dec[0], ENC_DELAY + 529, 8 * 1152);
  WriteLn(Format('       SNR without reservoir: %.1f dB', [snr]));
  Check('RV08 round trip SNR > 30 dB', snr > 30);

  { with reservoir }
  EncInit(Enc, Cfg);
  EncEnableReservoir(Enc, True);
  All2 := nil;
  for f := 0 to NFR - 1 do begin
    for i := 0 to 1151 do PCM[i] := Input[f * 1152 + i] * 32768;
    Frame := EncodeFrame(Enc, PCM);
    AppendBytes(All2, Frame);
  end;
  Check('RV09 reservoir: frames are delayed', (EncPendingFrames(Enc) > 0) or (Length(All2) = NFR * 384));
  Frame := EncFlush(Enc);
  AppendBytes(All2, Frame);
  Check('RV10 reservoir: total bytes after flush', Length(All2) = NFR * 384);
  Check('RV11 reservoir: FramesOut = FramesIn', (Enc.FramesOut = NFR) and (Enc.FramesIn = NFR));
  mdbMax := 0; mdbNonZero := 0;
  for f := 0 to NFR - 1 do begin
    ofs := f * 384;
    if (All2[ofs] <> $FF) or ((All2[ofs + 1] and $E0) <> $E0) then mdbMax := 9999;
    mdbMax := Max(mdbMax, MainDataBegin(All2, ofs));
    if MainDataBegin(All2, ofs) > 0 then Inc(mdbNonZero);
  end;
  Check('RV12 reservoir: sync on every frame, main_data_begin <= 511', mdbMax <= 511);
  Check('RV13 reservoir: used by some frames', mdbNonZero > 0);
  n := DecodeMP3(All2, Dec);
  Check('RV14 reservoir: decodes all samples', n = NFR * 1152);
  snr := SnrDb(Input, 0, Dec[0], ENC_DELAY + 529, 8 * 1152);
  WriteLn(Format('       SNR with reservoir: %.1f dB', [snr]));
  Check('RV15 reservoir: round trip SNR > 30 dB', snr > 30);

  { lowpass defaults }
  Cfg.BrIdx := 1; EncInit(Enc, Cfg);
  Check('RV16 lowpass 32k mono = 7500 Hz', Enc.LowpassHz = 7500);
  Cfg.BrIdx := 14; EncInit(Enc, Cfg);
  Check('RV17 no lowpass at 320k', (Enc.LowpassHz = 0) and (Enc.LowpassLine = 576));
  Cfg.BrIdx := 9; EncInitStereo(Enc, Cfg);
  Check('RV18 lowpass 128k stereo = 17500 Hz', Enc.LowpassHz = 17500);
  EncSetLowpass(Enc, 12000);
  Check('RV19 EncSetLowpass line = 12000*1152/48000', Enc.LowpassLine = 288);

  { stereo: automatic MS for correlated channels, round trip of both }
  Cfg.BrIdx := 9; EncInitStereo(Enc, Cfg);
  EncEnableReservoir(Enc, True);
  All := nil;
  for f := 0 to NFR - 1 do begin
    for i := 0 to 1151 do begin
      PCM[i]   := Input[f * 1152 + i] * 32768;
      PCM_R[i] := InputR[f * 1152 + i] * 32768;
    end;
    Frame := EncodeFrameAuto(Enc, PCM, PCM_R);
    AppendBytes(All, Frame);
  end;
  AppendBytes(All, EncFlush(Enc));
  Check('RV21 stereo bytes', Length(All) = NFR * 384);
  n := DecodeMP3(All, Dec);
  Check('RV22 stereo decodes', (n = NFR * 1152) and (Length(Dec[1]) = n));
  snr  := SnrDb(Input, 0, Dec[0], ENC_DELAY + 529, 8 * 1152);
  snrR := SnrDb(InputR, 0, Dec[1], ENC_DELAY + 529, 8 * 1152);
  WriteLn(Format('       MS round trip SNR: L %.1f dB  R %.1f dB', [snr, snrR]));
  Check('RV23 MS round trip L > 25 dB', snr > 25);
  Check('RV24 MS round trip R > 25 dB', snrR > 25);

  { identical channels -> MS (the side signal costs nothing) }
  EncInitStereo(Enc, Cfg);
  for i := 0 to 1151 do begin PCM[i] := Input[i] * 32768; PCM_R[i] := PCM[i]; end;
  EncodeFrameAuto(Enc, PCM, PCM_R);
  EncodeFrameAuto(Enc, PCM, PCM_R);
  Check('RV20 identical channels -> joint stereo (MS)', Enc.LastMS);

  { one silent channel -> L/R (M/S would spread the noise of L into R) }
  EncInitStereo(Enc, Cfg);
  EncEnableReservoir(Enc, True);
  All := nil;
  mdbMax := 0;
  for f := 0 to NFR - 1 do begin
    for i := 0 to 1151 do begin PCM[i] := Input[f * 1152 + i] * 32768; PCM_R[i] := 0; end;
    AppendBytes(All, EncodeFrameAuto(Enc, PCM, PCM_R));
    if Enc.LastMS then Inc(mdbMax);
  end;
  AppendBytes(All, EncFlush(Enc));
  Check('RV25 one silent channel -> L/R stereo', mdbMax = 0);
  n := DecodeMP3(All, Dec);
  snr := 0; for i := 0 to n - 1 do snr := Max(snr, Abs(Dec[1][i]));
  Check('RV31 one silent channel stays silent', (n = NFR * 1152) and (snr = 0));

  { low bitrate robustness: 32 kbps mono }
  Cfg.BrIdx := 1; EncInit(Enc, Cfg);
  EncEnableReservoir(Enc, True);
  All := nil;
  for f := 0 to NFR - 1 do begin
    for i := 0 to 1151 do PCM[i] := Input[f * 1152 + i] * 32768;
    AppendBytes(All, EncodeFrame(Enc, PCM));
  end;
  AppendBytes(All, EncFlush(Enc));
  Check('RV26 32k bytes', Length(All) = NFR * Enc.FrameBytes);
  n := DecodeMP3(All, Dec);
  snr := SnrDb(Input, 0, Dec[0], ENC_DELAY + 529, 8 * 1152);
  WriteLn(Format('       32 kbps round trip SNR: %.1f dB', [snr]));
  Check('RV27 32k round trip SNR > 15 dB', (n = NFR * 1152) and (snr > 15));

  { FFT psychoacoustic model: stereo (L, R, M and S analysed) and mono }
  EncDefaultPsyModel := 1;
  try
    Cfg.BrIdx := 9; EncInitStereo(Enc, Cfg);
    Check('RV28 FFT model selected', Enc.PsyFFT);
    EncEnableReservoir(Enc, True);
    All := nil;
    for f := 0 to NFR - 1 do begin
      for i := 0 to 1151 do begin
        PCM[i]   := Input[f * 1152 + i] * 32768;
        PCM_R[i] := InputR[f * 1152 + i] * 32768;
      end;
      AppendBytes(All, EncodeFrameAuto(Enc, PCM, PCM_R));
    end;
    AppendBytes(All, EncFlush(Enc));
    n := DecodeMP3(All, Dec);
    snr  := SnrDb(Input, 0, Dec[0], ENC_DELAY + 529, 8 * 1152);
    snrR := SnrDb(InputR, 0, Dec[1], ENC_DELAY + 529, 8 * 1152);
    WriteLn(Format('       FFT model stereo round trip SNR: L %.1f dB  R %.1f dB', [snr, snrR]));
    Check('RV29 FFT model stereo round trip > 25 dB', (n = NFR * 1152) and (snr > 25) and (snrR > 25));
    Cfg.BrIdx := 1; EncInit(Enc, Cfg);
    EncEnableReservoir(Enc, True);
    All := nil;
    for f := 0 to NFR - 1 do begin
      for i := 0 to 1151 do PCM[i] := Input[f * 1152 + i] * 32768;
      AppendBytes(All, EncodeFrame(Enc, PCM));
    end;
    AppendBytes(All, EncFlush(Enc));
    n := DecodeMP3(All, Dec);
    snr := SnrDb(Input, 0, Dec[0], ENC_DELAY + 529, 8 * 1152);
    WriteLn(Format('       FFT model 32 kbps round trip SNR: %.1f dB', [snr]));
    Check('RV30 FFT model 32k round trip SNR > 15 dB', (n = NFR * 1152) and (snr > 15));
  finally
    EncDefaultPsyModel := 0;
  end;
end;

// ---------------------------------------------------------------------------

var
  T0: TDateTime;
begin
  T0 := Now;
  GPassed := 0; GFailed := 0;
  try
    TestPsy;
    TestPsyFFT;
    TestLoop;
    TestFastTables;
    TestBestRegions;
    TestEncoder;
  except
    on E: Exception do begin
      WriteLn('** EXCEPTION ', E.ClassName, ': ', E.Message);
      Inc(GFailed);
    end;
  end;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%.0f ms)',
    [GPassed, GPassed + GFailed, (Now - T0) * 86400000]));
  if GFailed = 0 then WriteLn('ALL PASSED')
  else WriteLn(GFailed, ' FAILED');
  ExitCode := GFailed;
end.
