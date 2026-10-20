program TestMP3EncPhase21;

{
  Phase 21 tests — variable bitrate (VBR).

  VB: per-frame bitrate choice, quality ordering, reservoir limits,
      round trips (mono and stereo) through mp3-decoder,
      WAV -> VBR file with Xing (VBR) header, seek table and LAME extension
}

{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, Math,
  MP3EncEncoder, MP3EncXing, MP3EncWAV,
  AudioTypes, AudioCodec;

var
  GPassed, GFailed: Integer;

procedure Check(const AName: string; ACondition: Boolean);
begin
  if ACondition then begin Inc(GPassed); WriteLn('  PASS  ', AName); end
  else begin Inc(GFailed); WriteLn('** FAIL  ', AName); end;
end;

type
  TDoubles = TArray<Double>;

const
  SR = 44100;
  NFR = 40;
  RT_DELAY = ENC_DELAY + 529;
  KBPS: array[0..15] of Integer = (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0);

var
  RandState: Cardinal = 777;

function Rnd: Double;
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

{ Music-like test signal: chords + noise bursts, with a silent stretch }
function TestSignal(ACount: Integer; APhase: Double): TDoubles;
var
  i: Integer;
  t, env: Double;
begin
  SetLength(Result, ACount);
  for i := 0 to ACount - 1 do begin
    t := i / SR;
    if (i > ACount div 3) and (i < ACount div 2) then begin Result[i] := 0; Continue; end;
    env := 0.5 + 0.5 * Sin(2 * Pi * 2.0 * t + APhase);
    Result[i] := 0.15 * Sin(2 * Pi * 220 * t + APhase) + 0.1 * Sin(2 * Pi * 554 * t)
               + 0.08 * Sin(2 * Pi * 1318 * t) + 0.05 * env * Rnd;
  end;
end;

{ Encode with VBR quality AQ; returns the stream, the bitrate index of every
  frame and the largest main_data_begin. }
function EncodeVBR(const L, R: TDoubles; AStereo: Boolean; AQ: Integer;
  out ABr: TArray<Integer>; out AMaxMdb: Integer): TBytes;
var
  Enc: TMP3Encoder;
  Cfg: TEncConfig;
  P1, P2: T1152;
  f, i, p, len, nf: Integer;
begin
  Cfg.SrIdx := 0; Cfg.BrIdx := 9; Cfg.Padding := 0;
  if AStereo then EncInitStereo(Enc, Cfg) else EncInit(Enc, Cfg);
  EncEnableVBR(Enc, AQ);
  Result := nil;
  nf := Length(L) div 1152;
  for f := 0 to nf do begin
    for i := 0 to 1151 do
      if f < nf then begin P1[i] := L[f * 1152 + i] * 32768; P2[i] := R[f * 1152 + i] * 32768; end
      else begin P1[i] := 0; P2[i] := 0; end;
    if AStereo then AppendBytes(Result, EncodeFrameAuto(Enc, P1, P2))
    else AppendBytes(Result, EncodeFrame(Enc, P1));
  end;
  AppendBytes(Result, EncFlush(Enc));
  { walk the frames }
  ABr := nil; AMaxMdb := 0; p := 0;
  while p + 6 <= Length(Result) do begin
    if (Result[p] <> $FF) or ((Result[p + 1] and $E0) <> $E0) then Break;
    SetLength(ABr, Length(ABr) + 1);
    ABr[High(ABr)] := Result[p + 2] shr 4;
    AMaxMdb := Max(AMaxMdb, (Result[p + 4] shl 1) or (Result[p + 5] shr 7));
    len := 144000 * KBPS[ABr[High(ABr)]] div SR + ((Result[p + 2] shr 1) and 1);
    Inc(p, len);
  end;
end;

var
  EncM, EncS, EncC: TMP3Encoder;   { global: too large for the stack }

procedure TestVBR;
var
  L, R: TDoubles;
  Dec: array[0..1] of TDoubles;
  Br0, Br5, Br9: TArray<Integer>;
  D0, D5, D9: TBytes;
  i, f, mdb0, mdb5, mdb9, distinct, nSilent32: Integer;
  used: array[1..14] of Boolean;
  snrL, snrR: Double;
  Cfg: TEncConfig;
  P: T1152;
begin
  WriteLn('VB: variable bitrate');
  L := TestSignal(NFR * 1152, 0.0);
  R := TestSignal(NFR * 1152, 0.7);

  D0 := EncodeVBR(L, L, False, 0, Br0, mdb0);
  D5 := EncodeVBR(L, L, False, 5, Br5, mdb5);
  D9 := EncodeVBR(L, L, False, 9, Br9, mdb9);
  Check('VB01 one frame per 1152 samples', Length(Br5) = NFR + 1);
  FillChar(used, SizeOf(used), 0);
  for i := 0 to High(Br5) do if (Br5[i] >= 1) and (Br5[i] <= 14) then used[Br5[i]] := True;
  distinct := 0;
  for i := 1 to 14 do if used[i] then Inc(distinct);
  Check('VB02 several bitrates used (>= 3)', distinct >= 3);
  nSilent32 := 0;
  for i := (NFR div 3) div 1 + 3 to (NFR div 2) - 2 do
    if Br5[i] = 1 then Inc(nSilent32);
  Check('VB03 silence coded at 32 kbps', nSilent32 > 0);
  WriteLn(Format('       sizes: V0 %d, V5 %d, V9 %d bytes', [Length(D0), Length(D5), Length(D9)]));
  Check('VB04 size decreases with the quality setting', (Length(D0) > Length(D5)) and (Length(D5) > Length(D9)));
  Check('VB05 main_data_begin <= 511', Max(mdb0, Max(mdb5, mdb9)) <= 511);

  DecodeMP3(D0, Dec);
  snrL := SnrDb(L, 0, Dec[0], RT_DELAY, (NFR - 2) * 1152);
  WriteLn(Format('       mono V0 round trip SNR: %.1f dB', [snrL]));
  Check('VB06 mono V0 round trip SNR > 25 dB', snrL > 25);

  D5 := EncodeVBR(L, R, True, 2, Br5, mdb5);
  DecodeMP3(D5, Dec);
  snrL := SnrDb(L, 0, Dec[0], RT_DELAY, (NFR - 2) * 1152);
  snrR := SnrDb(R, 0, Dec[1], RT_DELAY, (NFR - 2) * 1152);
  WriteLn(Format('       stereo V2 round trip SNR: L %.1f dB, R %.1f dB', [snrL, snrR]));
  Check('VB07 stereo V2 round trip SNR > 20 dB', (snrL > 20) and (snrR > 20));

  { mono: allowed noise 1 dB under the stereo scale (M/S thresholds are
    the minimum of three analyses, stricter than a single channel's) }
  Cfg.SrIdx := 0; Cfg.BrIdx := 9; Cfg.Padding := 0;
  EncInit(EncM, Cfg); EncEnableVBR(EncM, 2);
  EncInitStereo(EncS, Cfg); EncEnableVBR(EncS, 2);
  Check('VB08 mono quality scale 1 dB stricter than stereo',
    Abs(10 * Log10(EncS.VbrNoiseScale / EncM.VbrNoiseScale) - 1.0) < 1e-9);
  { pre-echo control keeps the thresholds of the last granules in VBR only }
  EncInit(EncC, Cfg);
  for f := 0 to 7 do begin
    for i := 0 to 1151 do P[i] := 8000 * Sin(2 * Pi * 440 * (f * 1152 + i) / SR);
    EncodeFrame(EncM, P);
    EncodeFrame(EncC, P);
  end;
  Check('VB09 pre-echo state: tracked in VBR, not in CBR',
    (EncM.PrevXmin1[0][5] < 1e29) and (EncC.PrevXmin1[0][5] >= 1e29));
end;

{ minimal 16-bit PCM WAV writer }
procedure WriteWav(AStream: TStream; const L, R: TDoubles; AChannels: Integer);
var
  i, c, n: Integer;
  v: SmallInt;
  u32: Cardinal;
  u16: Word;
begin
  n := Length(L);
  AStream.WriteBuffer(AnsiString('RIFF')[1], 4);
  u32 := 36 + n * 2 * AChannels; AStream.WriteBuffer(u32, 4);
  AStream.WriteBuffer(AnsiString('WAVEfmt ')[1], 8);
  u32 := 16; AStream.WriteBuffer(u32, 4);
  u16 := 1; AStream.WriteBuffer(u16, 2);
  u16 := AChannels; AStream.WriteBuffer(u16, 2);
  u32 := SR; AStream.WriteBuffer(u32, 4);
  u32 := SR * 2 * AChannels; AStream.WriteBuffer(u32, 4);
  u16 := 2 * AChannels; AStream.WriteBuffer(u16, 2);
  u16 := 16; AStream.WriteBuffer(u16, 2);
  AStream.WriteBuffer(AnsiString('data')[1], 4);
  u32 := n * 2 * AChannels; AStream.WriteBuffer(u32, 4);
  for i := 0 to n - 1 do
    for c := 0 to AChannels - 1 do begin
      if c = 0 then v := Round(EnsureRange(L[i] * 32767, -32768, 32767))
      else v := Round(EnsureRange(R[i] * 32767, -32768, 32767));
      AStream.WriteBuffer(v, 2);
    end;
end;

procedure TestVBRFile;
var
  L, R: TDoubles;
  Wav, Mp3: TMemoryStream;
  frames, i: Integer;
  Cfg: TEncConfig;
  XT: TXingTag;
  LT: TLameTag;
  ok, mono: Boolean;
begin
  WriteLn('VF: WAV -> VBR file');
  L := TestSignal(NFR * 1152 + 500, 0.0);
  R := TestSignal(NFR * 1152 + 500, 0.4);
  Wav := TMemoryStream.Create;
  Mp3 := TMemoryStream.Create;
  try
    WriteWav(Wav, L, R, 2);
    Wav.Position := 0;
    frames := EncodeWAVStreamVBR(Wav, Mp3, 4);
    Check('VF01 encodes', frames > NFR);
    Cfg.SrIdx := 0; Cfg.BrIdx := 9; Cfg.Padding := 0;
    Mp3.Position := 0;
    ok := LameReadFrame(Mp3, Cfg, 2, XT, LT);
    Check('VF02 Xing (VBR) header with LAME extension', ok and XT.IsVBR);
    Check('VF03 frame count in the header', XT.FrameCount = Cardinal(frames));
    Check('VF04 byte count = file - header frame', XT.FileSize = Cardinal(Mp3.Size) - 417);
    mono := True;
    for i := 1 to 99 do if XT.TOC[i] < XT.TOC[i - 1] then mono := False;
    Check('VF05 seek table is monotonic', mono and (XT.TOC[0] = 0) and (XT.TOC[99] > 200));
    Check('VF06 gapless delay/padding', (LT.EncoderDelay = ENC_DELAY) and
      (LT.EncoderPadding = frames * 1152 - ENC_DELAY - (NFR * 1152 + 500)));
    Check('VF07 VBR method in the LAME tag', LT.VBRMethod = LAME_VBR_VBR);
  finally
    Wav.Free; Mp3.Free;
  end;
end;

var
  T0: TDateTime;
begin
  T0 := Now;
  GPassed := 0; GFailed := 0;
  WriteLn('=== MP3 encoder phase 21: VBR ===');
  TestVBR;
  TestVBRFile;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%d ms)', [GPassed, GPassed + GFailed,
    Round((Now - T0) * 86400000)]));
  if GFailed = 0 then WriteLn('ALL PASSED') else WriteLn(GFailed, ' FAILED');
  ExitCode := GFailed;
end.
