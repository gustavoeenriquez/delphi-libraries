program TestMP3EncPhase20;

{
  Phase 20 tests — window switching (short blocks) and mid/side thresholds.

  WS: block sequence, short/start/stop MDCT round trips through mp3-decoder,
      attack detection, pre-echo against long blocks only, short-block loop
  MS: side signal kept on wide stereo, L/R chosen when M/S does not pay off
}

{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, Math,
  MP3EncQuantize, MP3EncFrame, MP3EncPsy, MP3EncLoop, MP3EncEncoder,
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

const
  SR = 48000;
  NFR = 40;
  RT_DELAY = ENC_DELAY + 529;   { encoder delay + ISO decoder delay }

var
  RandState: Cardinal = 12345;

function Rnd: Double;   { uniform -1..1, deterministic }
begin
  RandState := RandState * 1103515245 + 12345;
  Result := ((RandState shr 8) and $FFFF) / 32768.0 - 1.0;
end;

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

procedure AppendBytes(var ADst: TBytes; const ASrc: TBytes);
var
  n: Integer;
begin
  n := Length(ADst);
  SetLength(ADst, n + Length(ASrc));
  if Length(ASrc) > 0 then Move(ASrc[0], ADst[n], Length(ASrc));
end;

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

{ Castanet-like signal (+-1 scale): bright decaying bursts on near silence.
  AAttacks receives the burst positions. }
function Castanets(ACount: Integer; out AAttacks: TArray<Integer>): TDoubles;
var
  i, t, k, L: Integer;
  prev: Double;
begin
  SetLength(Result, ACount);
  for i := 0 to ACount - 1 do Result[i] := 1e-4 * Rnd;
  AAttacks := nil;
  t := 9000;
  while t + 4000 < ACount - 3000 do begin
    SetLength(AAttacks, Length(AAttacks) + 1);
    AAttacks[High(AAttacks)] := t;
    L := 2000; prev := 0;
    for k := 0 to L - 1 do begin
      Result[t + k] := Result[t + k] + 0.3 * (Rnd - 0.8 * prev) * Exp(-k / 200.0);
      prev := Rnd;
    end;
    Inc(t, 11000 + Trunc(3000 * (Rnd + 1)));
  end;
end;

{ Encode a mono signal; AMode = window switching mode. Returns the stream and
  the block types used (2 per frame). }
function EncodeMono(const AX: TDoubles; ABrIdx, AMode: Integer;
  out ATypes: TArray<Integer>): TBytes;
var
  Enc: TMP3Encoder;
  Cfg: TEncConfig;
  PCM: T1152;
  f, i, nf: Integer;
begin
  Cfg.SrIdx := 1; Cfg.BrIdx := ABrIdx; Cfg.Padding := 0;
  EncInit(Enc, Cfg);
  EncEnableReservoir(Enc, True);
  EncSetWindowSwitching(Enc, AMode);
  Result := nil;
  nf := Length(AX) div 1152;
  SetLength(ATypes, 2 * (nf + 1));
  for f := 0 to nf do begin
    for i := 0 to 1151 do
      if f < nf then PCM[i] := AX[f * 1152 + i] * 32768 else PCM[i] := 0;
    AppendBytes(Result, EncodeFrame(Enc, PCM));
    ATypes[2 * f] := Enc.BlockType[0];
    ATypes[2 * f + 1] := Enc.BlockType[1];
  end;
  AppendBytes(Result, EncFlush(Enc));
end;

{ Mean noise energy (dB, +-1 scale) in the 25..7 ms before each attack. }
function PreEchoDb(const AX, AY: TDoubles; const AAttacks: TArray<Integer>): Double;
var
  a, i, lo, hi: Integer;
  e: Double;
begin
  e := 0;
  for a := 0 to High(AAttacks) do begin
    lo := AAttacks[a] - SR * 25 div 1000;
    hi := AAttacks[a] - SR * 7 div 1000;
    for i := lo to hi - 1 do e := e + Sqr(AY[i + RT_DELAY] - AX[i]);
  end;
  Result := 10 * Log10(e / (Length(AAttacks) * (SR * 18 div 1000)) + 1e-20);
end;

// ---------------------------------------------------------------------------
// WS: window switching
// ---------------------------------------------------------------------------

procedure TestWindowSwitching;
var
  X, Steady: TDoubles;
  Dec: array[0..0] of TDoubles;
  Attacks: TArray<Integer>;
  Types: TArray<Integer>;
  Data: TBytes;
  i, nShort, n: Integer;
  legal: Boolean;
  snr, preLong, preAuto: Double;
  Xr: T576;
  Xmin: TPsyShortArr;
  Gr: TGrInfo;
  St: TLoopStats;
  LS: TLoopState;
  QS: TQuantState;
  bits, sbgMax, w: Integer;
begin
  WriteLn('WS: window switching');
  X := Castanets(NFR * 1152, Attacks);

  { all-short stream: 12-point MDCTs, reordering, short scalefactors }
  Data := EncodeMono(X, 14, 2, Types);
  n := DecodeMP3(Data, Dec);
  Check('WS01 short-only stream decodes', n >= NFR * 1152);
  snr := SnrDb(X, 0, Dec[0], RT_DELAY, (NFR - 2) * 1152);
  WriteLn(Format('       short-only 320 kbps round trip SNR: %.1f dB', [snr]));
  Check('WS02 short-only round trip SNR > 25 dB', snr > 25);

  { automatic switching: legal sequences, start/stop round trip }
  Data := EncodeMono(X, 14, 0, Types);
  nShort := 0; legal := True;
  for i := 0 to High(Types) do begin
    if Types[i] = 2 then Inc(nShort);
    if i > 0 then begin
      if (Types[i - 1] = 1) and (Types[i] <> 2) then legal := False;    { start -> short }
      if (Types[i] = 3) and (Types[i - 1] <> 2) then legal := False;    { stop after short }
      if (Types[i - 1] = 2) and (Types[i] in [0, 1]) then legal := False;
    end;
  end;
  Check('WS03 attacks switch to short blocks', nShort >= Length(Attacks));
  Check('WS04 window sequence is legal', legal);
  DecodeMP3(Data, Dec);
  snr := SnrDb(X, 0, Dec[0], RT_DELAY, (NFR - 2) * 1152);
  WriteLn(Format('       automatic 320 kbps round trip SNR: %.1f dB (%d short granules)', [snr, nShort]));
  Check('WS05 automatic round trip SNR > 25 dB', snr > 25);

  { a steady tone never switches }
  SetLength(Steady, NFR * 1152);
  for i := 0 to High(Steady) do
    Steady[i] := 0.3 * Sin(2 * Pi * 1000 * i / SR) + 0.1 * Sin(2 * Pi * 3100 * i / SR);
  EncodeMono(Steady, 9, 0, Types);
  nShort := 0;
  { the onset of the tone (granules 0..3) is a real attack }
  for i := 4 to High(Types) - 2 do if Types[i] <> 0 then Inc(nShort);
  Check('WS06 steady tone: long blocks after the onset', nShort = 0);

  { pre-echo at 128 kbps: switching vs long blocks only }
  Data := EncodeMono(X, 9, 1, Types);
  DecodeMP3(Data, Dec);
  preLong := PreEchoDb(X, Dec[0], Attacks);
  Data := EncodeMono(X, 9, 0, Types);
  DecodeMP3(Data, Dec);
  preAuto := PreEchoDb(X, Dec[0], Attacks);
  WriteLn(Format('       pre-echo 25..7 ms before the attacks: long %.1f dB, switching %.1f dB', [preLong, preAuto]));
  Check('WS07 window switching lowers the pre-echo by > 10 dB', preAuto < preLong - 10);

  { short-block loop: budget respected, quiet window gets subblock gain }
  QuantInit(QS);
  LoopInit(LS);
  for i := 0 to 575 do Xr[i] := 0;
  { window 2 loud, windows 0/1 very quiet (sfb-major order: band j has 3 windows) }
  for i := 0 to 575 do Xr[i] := 1e-5 * Rnd;
  for i := 0 to 12 do
    for w := QuantSfbShort(1, i) to QuantSfbShort(1, i + 1) - 1 do
      Xr[3 * QuantSfbShort(1, i) + 2 * (QuantSfbShort(1, i + 1) - QuantSfbShort(1, i)) +
        (w - QuantSfbShort(1, i))] := 0.3 * Rnd;
  for i := 0 to 12 do
    for w := 0 to 2 do Xmin[i][w] := 1e-14;
  bits := LoopEncodeGranuleShort(LS, QS, Xr, Xmin, 1500, 0, 1, Gr, St);
  Check('WS08 short loop fits the budget', (bits > 0) and (bits <= 1500));
  Check('WS09 short granule fields', (Gr.BlockType = 2) and (Gr.Part2_3_Length = bits));
  sbgMax := 0;
  for w := 0 to 2 do sbgMax := Max(sbgMax, Gr.SubblockGain[w]);
  Check('WS10 subblock_gain within 0..7', sbgMax <= 7);
end;

// ---------------------------------------------------------------------------
// MS: thresholds and decision
// ---------------------------------------------------------------------------

{ Side-signal SNR (dB) and level change (dB) of a stereo encode;
  AMode 0 = automatic, 1 = L/R, 2 = M/S. }
procedure SideQuality(const L, R: TDoubles; AMode: Integer; out ASnr, ALevel: Double;
  out AFramesMS: Integer);
var
  Enc: TMP3Encoder;
  Cfg: TEncConfig;
  PCM_L, PCM_R: T1152;
  Data: TBytes;
  Dec: array[0..1] of TDoubles;
  f, i: Integer;
  sSig, sDec, sErr, so, sd: Double;
begin
  Cfg.SrIdx := 1; Cfg.BrIdx := 9; Cfg.Padding := 0;
  EncInitStereo(Enc, Cfg);
  EncEnableReservoir(Enc, True);
  Data := nil; AFramesMS := 0;
  for f := 0 to NFR do begin
    for i := 0 to 1151 do
      if f < NFR then begin PCM_L[i] := L[f * 1152 + i] * 32768; PCM_R[i] := R[f * 1152 + i] * 32768; end
      else begin PCM_L[i] := 0; PCM_R[i] := 0; end;
    case AMode of
      1: AppendBytes(Data, EncodeFrameStereo(Enc, PCM_L, PCM_R));
      2: AppendBytes(Data, EncodeFrameMS(Enc, PCM_L, PCM_R));
    else AppendBytes(Data, EncodeFrameAuto(Enc, PCM_L, PCM_R));
    end;
    if Enc.LastMS then Inc(AFramesMS);
  end;
  AppendBytes(Data, EncFlush(Enc));
  DecodeMP3(Data, Dec);
  sSig := 0; sErr := 0; sDec := 0;
  for i := 2304 to (NFR - 2) * 1152 do begin
    so := (L[i] - R[i]) / 2;
    sd := (Dec[0][i + RT_DELAY] - Dec[1][i + RT_DELAY]) / 2;
    sSig := sSig + Sqr(so); sDec := sDec + Sqr(sd); sErr := sErr + Sqr(so - sd);
  end;
  ASnr := 10 * Log10(sSig / sErr);
  ALevel := 10 * Log10(sDec / sSig);
end;

procedure TestMidSide;
var
  L, R: TDoubles;
  i, nMS, dummy: Integer;
  common, snrLR, snrMS, snrAuto, lvLR, lvMS, lvAuto: Double;
begin
  WriteLn('MS: mid/side');
  { wide stereo: a common part plus an independent part per channel }
  SetLength(L, NFR * 1152); SetLength(R, NFR * 1152);
  for i := 0 to High(L) do begin
    common := 0.25 * Rnd;
    L[i] := common + 0.08 * Rnd + 0.1 * Sin(2 * Pi * 700 * i / SR);
    R[i] := common + 0.08 * Rnd + 0.1 * Sin(2 * Pi * 900 * i / SR);
  end;
  SideQuality(L, R, 1, snrLR, lvLR, dummy);
  SideQuality(L, R, 2, snrMS, lvMS, dummy);
  SideQuality(L, R, 0, snrAuto, lvAuto, nMS);
  WriteLn(Format('       side signal SNR / level: L/R %.1f / %.1f dB, M/S %.1f / %.1f dB, auto %.1f / %.1f dB (%d M/S frames)',
    [snrLR, lvLR, snrMS, lvMS, snrAuto, lvAuto, nMS]));
  { the side signal must not be thrown away in M/S (it used to get the
    threshold of the much louder mid signal) }
  Check('MS01 forced M/S keeps the side signal as well as L/R (-3 dB)', snrMS > snrLR - 3);
  Check('MS02 side level within 3 dB in every mode',
    (Abs(lvLR) < 3) and (Abs(lvMS) < 3) and (Abs(lvAuto) < 3));
  Check('MS03 automatic mode is not worse than L/R for the side signal', snrAuto > snrLR - 1);
end;

// ---------------------------------------------------------------------------

var
  T0: TDateTime;
begin
  T0 := Now;
  GPassed := 0; GFailed := 0;
  WriteLn('=== MP3 encoder phase 20: window switching and M/S ===');
  TestWindowSwitching;
  TestMidSide;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%d ms)', [GPassed, GPassed + GFailed,
    Round((Now - T0) * 86400000)]));
  if GFailed = 0 then WriteLn('ALL PASSED') else WriteLn(GFailed, ' FAILED');
  ExitCode := GFailed;
end.
