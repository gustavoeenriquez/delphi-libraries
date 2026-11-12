program TestMP3EncPhase22;

{
  Phase 22 tests — average bitrate (ABR).

  AB: starting point of the quality scale, mean bitrate on target (mono and
      stereo, several rates), per-frame bitrate choice, reservoir limits,
      bounded controller, round trip through mp3-decoder
  AF: WAV -> ABR file with Xing header and LAME extension (method ABR)
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
  NFR = 240;              { ~6.3 s }
  RT_DELAY = ENC_DELAY + 529;
  KBPS: array[0..15] of Integer = (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0);

var
  RandState: Cardinal = 4242;

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

{ Music-like signal whose demand changes over time: chords with a moving
  melody, noise bursts of changing level and a quiet passage.  AQuietFrom /
  AQuietTo (in frames) mark a stretch at -40 dB. }
function TestSignal(ACount: Integer; APhase: Double; AQuietFrom, AQuietTo: Integer): TDoubles;
var
  i: Integer;
  t, env, mel, g: Double;
begin
  SetLength(Result, ACount);
  for i := 0 to ACount - 1 do begin
    t := i / SR;
    env := 0.5 + 0.5 * Sin(2 * Pi * 0.7 * t + APhase);
    mel := 440 * Power(2, Round(4 * Sin(2 * Pi * 0.25 * t)) / 12);
    g := 1.0;
    if (i div 1152 >= AQuietFrom) and (i div 1152 < AQuietTo) then g := 0.01;
    Result[i] := g * (0.12 * Sin(2 * Pi * 196 * t + APhase) + 0.08 * Sin(2 * Pi * 247 * t)
               + 0.07 * Sin(2 * Pi * mel * t) + 0.03 * Sin(2 * Pi * 3 * mel * t)
               + 0.06 * env * env * Rnd);
  end;
end;

{ Encode with ABR at AKbps; returns the stream, the bitrate index of every
  frame and the largest main_data_begin.  AEnc is left as after the flush. }
function EncodeABR(var AEnc: TMP3Encoder; const L, R: TDoubles; AStereo: Boolean;
  AKbps: Integer; out ABr: TArray<Integer>; out AMaxMdb: Integer;
  out AMinDb, AMaxDb: Double): TBytes;
var
  Cfg: TEncConfig;
  P1, P2: T1152;
  f, i, p, len, nf: Integer;
begin
  Cfg.SrIdx := 0; Cfg.BrIdx := 9; Cfg.Padding := 0;
  if AStereo then EncInitStereo(AEnc, Cfg) else EncInit(AEnc, Cfg);
  EncEnableABR(AEnc, AKbps);
  Result := nil;
  AMinDb := 1e9; AMaxDb := -1e9;
  nf := Length(L) div 1152;
  for f := 0 to nf do begin
    for i := 0 to 1151 do
      if f < nf then begin P1[i] := L[f * 1152 + i] * 32768; P2[i] := R[f * 1152 + i] * 32768; end
      else begin P1[i] := 0; P2[i] := 0; end;
    if AStereo then AppendBytes(Result, EncodeFrameAuto(AEnc, P1, P2))
    else AppendBytes(Result, EncodeFrame(AEnc, P1));
    AMinDb := Min(AMinDb, AEnc.AbrNoiseDb);
    AMaxDb := Max(AMaxDb, AEnc.AbrNoiseDb);
  end;
  AppendBytes(Result, EncFlush(AEnc));
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

{ mean bitrate (kbps) of a stream of ANFrames frames }
function MeanKbps(const AData: TBytes; ANFrames: Integer): Double;
begin
  Result := Length(AData) * 8.0 * SR / (ANFrames * 1152.0) / 1000.0;
end;

var
  Enc: TMP3Encoder;   { global: too large for the stack }

procedure TestABR;
const
  RATES: array[0..4] of Integer = (64, 96, 128, 192, 256);
var
  L, R, LQ, RQ: TDoubles;
  Dec: array[0..1] of TDoubles;
  Br: TArray<Integer>;
  D: TBytes;
  Sizes: array[0..4] of Integer;
  i, k, mdb, distinct, maxMdb: Integer;
  used: array[1..14] of Boolean;
  kb, err, maxErr, lo, hi, snrL, snrR: Double;
  ordered: Boolean;
  Cfg: TEncConfig;
begin
  WriteLn('AB: average bitrate');
  { starting point: on the VBR quality scale, falling with the bitrate }
  Check('AB01 start point = VBR scale at its rates',
    (Abs(EncAbrBaseDb(128) - 7.6) < 1e-9) and (Abs(EncAbrBaseDb(192) - 2.4) < 1e-9)
    and (Abs(EncAbrBaseDb(256) + 2.2) < 1e-9));
  Check('AB02 start point between rates and past the ends is monotonic',
    (EncAbrBaseDb(144) < EncAbrBaseDb(128)) and (EncAbrBaseDb(144) > EncAbrBaseDb(160))
    and (EncAbrBaseDb(320) < EncAbrBaseDb(256)) and (EncAbrBaseDb(48) > EncAbrBaseDb(64)));
  Cfg.SrIdx := 0; Cfg.BrIdx := 1; Cfg.Padding := 0;
  EncInit(Enc, Cfg); EncEnableABR(Enc, 128);
  Check('AB03 ABR runs on the VBR quality mode, target per frame',
    Enc.Vbr and Enc.Abr and (Abs(Enc.AbrFrameBits - 128000.0 * 1152 / SR) < 1e-6));

  L := TestSignal(NFR * 1152, 0.0, -1, -1);
  R := TestSignal(NFR * 1152, 0.9, -1, -1);

  { stereo: mean bitrate on target at every rate }
  maxErr := 0; ordered := True; maxMdb := 0;
  for k := 0 to High(RATES) do begin
    D := EncodeABR(Enc, L, R, True, RATES[k], Br, mdb, lo, hi);
    kb := MeanKbps(D, Length(Br));
    err := Abs(kb / RATES[k] - 1);
    maxErr := Max(maxErr, err);
    maxMdb := Max(maxMdb, mdb);
    Sizes[k] := Length(D);
    if (k > 0) and (Sizes[k] <= Sizes[k - 1]) then ordered := False;
    WriteLn(Format('       stereo ABR %3d: %6.1f kbps (%.1f %%), noise %.1f .. %.1f dB',
      [RATES[k], kb, 100 * (kb / RATES[k] - 1), lo, hi]));
    if RATES[k] = 128 then begin
      FillChar(used, SizeOf(used), 0);
      for i := 0 to High(Br) do if (Br[i] >= 1) and (Br[i] <= 14) then used[Br[i]] := True;
      distinct := 0;
      for i := 1 to 14 do if used[i] then Inc(distinct);
      Check('AB04 one frame per 1152 samples', Length(Br) = NFR + 1);
      Check('AB05 frames take their own bitrate (>= 3 indices)', distinct >= 3);
      Check('AB06 noise offset stays within the controller range',
        (lo >= Enc.AbrBaseDb - 12.0 - 1e-9) and (hi <= Enc.AbrBaseDb + 16.0 + 1e-9));
      DecodeMP3(D, Dec);
      snrL := SnrDb(L, 0, Dec[0], RT_DELAY, (NFR - 2) * 1152);
      snrR := SnrDb(R, 0, Dec[1], RT_DELAY, (NFR - 2) * 1152);
      WriteLn(Format('       stereo ABR 128 round trip SNR: L %.1f dB, R %.1f dB', [snrL, snrR]));
      Check('AB07 stereo ABR 128 round trip SNR > 15 dB', (snrL > 15) and (snrR > 15));
    end;
  end;
  Check('AB08 stereo mean bitrate within 3 % of the target (64..256)', maxErr < 0.03);
  Check('AB09 size grows with the target', ordered);
  Check('AB10 main_data_begin <= 511', maxMdb <= 511);

  { mono }
  maxErr := 0;
  for k := 0 to 2 do begin
    D := EncodeABR(Enc, L, L, False, RATES[k], Br, mdb, lo, hi);
    kb := MeanKbps(D, Length(Br));
    maxErr := Max(maxErr, Abs(kb / RATES[k] - 1));
    WriteLn(Format('       mono ABR %3d: %6.1f kbps (%.1f %%)', [RATES[k], kb, 100 * (kb / RATES[k] - 1)]));
  end;
  Check('AB11 mono mean bitrate within 3 % of the target (64..128)', maxErr < 0.03);

  { a quiet stretch: the offset stays bounded; one pass over 6 s cannot
    settle after a stretch of a third of the file, so the mean may end
    some percent over the target (+6 % measured; files use the multi-pass
    search instead) }
  LQ := TestSignal(NFR * 1152, 0.0, 40, 120);
  RQ := TestSignal(NFR * 1152, 0.9, 40, 120);
  D := EncodeABR(Enc, LQ, RQ, True, 128, Br, mdb, lo, hi);
  kb := MeanKbps(D, Length(Br));
  WriteLn(Format('       stereo ABR 128 with a quiet third: %.1f kbps, noise %.1f .. %.1f dB', [kb, lo, hi]));
  Check('AB12 quiet stretch: offset bounded and the mean within 8 % of the target',
    (lo >= Enc.AbrBaseDb - 12.0 - 1e-9) and (hi <= Enc.AbrBaseDb + 16.0 + 1e-9)
    and (Abs(kb / 128 - 1) < 0.08));
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

procedure TestABRFile;
var
  L, R: TDoubles;
  Wav, Mp3: TMemoryStream;
  frames, i, n: Integer;
  Cfg: TEncConfig;
  XT: TXingTag;
  LT: TLameTag;
  ok, mono: Boolean;
  kb: Double;
begin
  WriteLn('AF: WAV -> ABR file');
  n := 120 * 1152 + 500;
  L := TestSignal(n, 0.0, -1, -1);
  R := TestSignal(n, 0.4, -1, -1);
  Wav := TMemoryStream.Create;
  Mp3 := TMemoryStream.Create;
  try
    WriteWav(Wav, L, R, 2);
    Wav.Position := 0;
    frames := EncodeWAVStreamABR(Wav, Mp3, 160);
    Check('AF01 encodes', frames > 120);
    Cfg.SrIdx := 0; Cfg.BrIdx := 9; Cfg.Padding := 0;
    Mp3.Position := 0;
    ok := LameReadFrame(Mp3, Cfg, 2, XT, LT);
    Check('AF02 Xing (VBR) header with LAME extension', ok and XT.IsVBR);
    Check('AF03 frame count and byte count in the header',
      (XT.FrameCount = Cardinal(frames)) and (XT.FileSize = Cardinal(Mp3.Size) - 417));
    mono := True;
    for i := 1 to 99 do if XT.TOC[i] < XT.TOC[i - 1] then mono := False;
    Check('AF04 seek table is monotonic', mono and (XT.TOC[0] = 0) and (XT.TOC[99] > 200));
    Check('AF05 gapless delay/padding', (LT.EncoderDelay = ENC_DELAY) and
      (LT.EncoderPadding = frames * 1152 - ENC_DELAY - n));
    Check('AF06 ABR method and target in the LAME tag',
      (LT.VBRMethod = LAME_VBR_ABR) and (LT.AbrKbps = 160));
    kb := XT.FileSize * 8.0 * SR / (frames * 1152.0) / 1000.0;
    WriteLn(Format('       file: %.1f kbps', [kb]));
    Check('AF07 multi-pass file: mean bitrate within 3 % of 160', Abs(kb / 160 - 1) < 0.03);
    Mp3.Clear; Wav.Position := 0;
    EncodeWAVStreamABR(Wav, Mp3, 400);
    Mp3.Position := 0;
    LameReadFrame(Mp3, Cfg, 2, XT, LT);
    Check('AF08 target above 320 clamped, tag holds 255 (= 255 or more)', LT.AbrKbps = 255);
  finally
    Wav.Free; Mp3.Free;
  end;
end;

var
  T0: TDateTime;
begin
  T0 := Now;
  GPassed := 0; GFailed := 0;
  WriteLn('=== MP3 encoder phase 22: ABR ===');
  TestABR;
  TestABRFile;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%d ms)', [GPassed, GPassed + GFailed,
    Round((Now - T0) * 86400000)]));
  if GFailed = 0 then WriteLn('ALL PASSED') else WriteLn(GFailed, ' FAILED');
  ExitCode := GFailed;
end.
