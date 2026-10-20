program G729Tests;

{
  G729Tests.dpr - Tests for g729-codec (G.729 Annex A, floating point)

  Unit level:
    T01  Bit-stream packing (Table 8) round trip
    T02  Pitch delay coding: P1/P2 decode, parity bit
    T03  Fixed-codebook index/sign decoding covers every pulse track
    T04  LSF -> LP -> LSF round trip and LSF stabilization
  Synthetic signals (no external files):
    T05  Encoder -> decoder on a voiced synthetic signal: level and SNR
    T06  Lost frames, Reset determinism, independent instances
    T07  Block API (odd sizes), DecodePayload with several frames
  ITU-T test vectors (skipped when ../samples/itu-* is missing, see README):
    T08  Decoder vs G.729A reference output (.BIT -> .PST), segmental SNR
    T09  Decoder accepts full G.729 bit streams (main-body vectors)
    T10  Encoder vs reference encoder: same quality with the same decoder

  The codec is a floating-point implementation written from the text of the
  Recommendation; it is not bit-exact with the fixed-point reference, so the
  ITU vectors are checked with SNR thresholds.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  SysUtils, Classes, Math,
  G729Common, G729Decoder, G729Encoder;

var
  Passed, Failed, Skipped: Integer;

procedure Check(Cond: Boolean; const Name: string);
begin
  if Cond then begin WriteLn('  PASS: ', Name); Inc(Passed); end
  else         begin WriteLn('  FAIL: ', Name); Inc(Failed); end;
end;

procedure Skip(const Name: string);
begin
  WriteLn('  SKIP: ', Name);
  Inc(Skipped);
end;

function SamplesDir: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..' + PathDelim +
    '..' + PathDelim + '..' + PathDelim + 'samples' + PathDelim;
end;

function LoadWords(const FileName: string): TArray<SmallInt>;
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, FS.Size div 2);
    if Length(Result) > 0 then FS.ReadBuffer(Result[0], Length(Result) * 2);
  finally
    FS.Free;
  end;
end;

// Finds a file ignoring the case of its name (the ITU vectors mix cases)
function FindFile(const Dir, Name: string): string;
var
  SR: TSearchRec;
begin
  Result := '';
  if FindFirst(Dir + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if SameText(SR.Name, Name) then Exit(Dir + SR.Name);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

// Decodes an ITU-T serial bit stream (sync word, size, one word per bit)
function DecodeSerial(const Bits: TArray<SmallInt>): TArray<SmallInt>;
var
  Dec: TG729Decoder;
  Pos, Size, I, F: Integer;
  Frame: array[0..9] of Byte;
  Erased: Boolean;
begin
  SetLength(Result, 0);
  Dec := TG729Decoder.Create;
  try
    Pos := 0; F := 0;
    while Pos + 2 <= Length(Bits) do
    begin
      Size := Bits[Pos + 1];
      SetLength(Result, (F + 1) * G729_FRAME);
      FillChar(Frame, SizeOf(Frame), 0);
      Erased := Size <> 80;
      for I := 0 to Size - 1 do
        case Word(Bits[Pos + 2 + I]) of
          $81: if I < 80 then Frame[I shr 3] := Frame[I shr 3] or (128 shr (I and 7));
          $7F: ;
        else
          Erased := True;
        end;
      if Erased then Dec.Decode(nil, 0, @Result[F * G729_FRAME])
      else Dec.Decode(@Frame[0], 10, @Result[F * G729_FRAME]);
      Inc(Pos, 2 + Size);
      Inc(F);
    end;
  finally
    Dec.Free;
  end;
end;

// Mean segmental SNR (dB) of X against Ref delayed by Delay samples, on active frames
function SegSnr(const Ref, X: TArray<SmallInt>; Delay: Integer): Double;
var
  F, I, N: Integer;
  S, E, Sum: Double;
begin
  Sum := 0; N := 0;
  for F := 0 to Length(X) div G729_FRAME - 1 do
  begin
    S := 0; E := 0;
    for I := F * G729_FRAME to F * G729_FRAME + G729_FRAME - 1 do
      if (I - Delay >= 0) and (I - Delay < Length(Ref)) then
      begin
        S := S + Sqr(Double(Ref[I - Delay]));
        E := E + Sqr(Double(Ref[I - Delay]) - X[I]);
      end;
    if S > G729_FRAME * 1000.0 then
    begin
      Sum := Sum + EnsureRange(10 * Log10((S + 1) / (E + 1)), -10, 60);
      Inc(N);
    end;
  end;
  if N = 0 then Result := 0 else Result := Sum / N;
end;

function Rms(const X: TArray<SmallInt>; From, Count: Integer): Double;
var
  I: Integer;
begin
  Result := 0;
  for I := From to From + Count - 1 do Result := Result + Sqr(Double(X[I]));
  Result := Sqrt(Result / Max(Count, 1));
end;

// Voiced synthetic signal: harmonics of a gliding pitch with a syllabic envelope
function SyntheticSpeech(N: Integer): TArray<SmallInt>;
var
  I, H: Integer;
  Phase, F0, Env, S: Double;
begin
  SetLength(Result, N);
  Phase := 0;
  for I := 0 to N - 1 do
  begin
    F0 := 120 + 40 * Sin(2 * Pi * I / 8000);
    Phase := Phase + 2 * Pi * F0 / 8000;
    Env := 0.55 + 0.45 * Sin(2 * Pi * 3 * I / 8000);
    S := 0;
    for H := 1 to 20 do
      if H * F0 < 3400 then
        S := S + Sin(H * Phase) / H * (1 + 0.8 * Cos(2 * Pi * H * F0 / 1600));
    Result[I] := Round(EnsureRange(4000 * Env * S, -32000, 32000));
  end;
end;

{ T01-T04 unit level }

procedure TestT01_Bits;
var
  P, Q: TG729Params;
  B: array[0..9] of Byte;
  K: Integer;
  Ok: Boolean;
begin
  WriteLn('T01: bit-stream packing');
  RandSeed := 1234;
  Ok := True;
  for K := 1 to 1000 do
  begin
    P.L0 := Random(2); P.L1 := Random(128); P.L2 := Random(32); P.L3 := Random(32);
    P.P1 := Random(256); P.P0 := Random(2); P.C1 := Random(8192); P.S1 := Random(16);
    P.GA1 := Random(8); P.GB1 := Random(16); P.P2 := Random(32); P.C2 := Random(8192);
    P.S2 := Random(16); P.GA2 := Random(8); P.GB2 := Random(16);
    PackFrame(P, @B[0]);
    UnpackFrame(@B[0], Q);
    if not CompareMem(@P, @Q, SizeOf(P)) then Ok := False;
  end;
  Check(Ok, '1000 random frames survive pack/unpack');
  FillChar(P, SizeOf(P), 0);
  P.L0 := 1;
  PackFrame(P, @B[0]);
  Check(B[0] = $80, 'L0 is the first (most significant) bit');
  FillChar(P, SizeOf(P), 0);
  P.GB2 := 1;
  PackFrame(P, @B[0]);
  Check(B[9] = $01, 'GB2 ends in the last bit');
end;

procedure TestT02_Pitch;
var
  P1, IntT, Frac, P2, IntT2, Frac2, TMin, TMax: Integer;
  Ok: Boolean;
begin
  WriteLn('T02: pitch delay coding');
  Ok := True;
  for P1 := 0 to 255 do
  begin
    DecodePitch1(P1, IntT, Frac);
    if P1 < 197 then
    begin
      if (3 * (IntT - 19) + Frac - 1 <> P1) or (Abs(Frac) > 1) then Ok := False;
    end
    else if (Frac <> 0) or (IntT - 85 + 197 <> P1) then
      Ok := False;
  end;
  Check(Ok, 'P1 decode/encode round trip (0..255)');
  Ok := True;
  for IntT := 20 to 143 do
  begin
    PitchRange2(IntT, TMin, TMax);
    for P2 := 0 to 30 do
    begin
      DecodePitch2(P2, IntT, IntT2, Frac2);
      if 3 * (IntT2 - TMin) + Frac2 + 2 <> P2 then Ok := False;
      if (3 * IntT2 + Frac2 < 3 * TMin - 2) or (3 * IntT2 + Frac2 > 3 * TMax + 2) then Ok := False;
    end;
  end;
  Check(Ok, 'P2 decode/encode round trip inside [tmin - 2/3, tmax + 2/3]');
  Check((PitchParity(0) = 1) and (PitchParity($04) = 0) and (PitchParity($03) = 1),
    'parity covers the six most significant bits of P1');
end;

procedure TestT03_FixedCodebook;
var
  Code: array[0..G729_SUBFR - 1] of Double;
  Used: array[0..G729_SUBFR - 1] of Boolean;
  C, N, Pulses: Integer;
  Ok: Boolean;
begin
  WriteLn('T03: fixed codebook');
  FillChar(Used, SizeOf(Used), 0);
  Ok := True;
  for C := 0 to 8191 do
  begin
    DecodeFixedCodebook(C, $A, Code);
    Pulses := 0;
    for N := 0 to G729_SUBFR - 1 do
      if Code[N] <> 0 then begin Inc(Pulses); Used[N] := True; end;
    if Pulses <> 4 then Ok := False;
  end;
  Check(Ok, 'every index gives four pulses');
  Ok := True;
  for N := 0 to G729_SUBFR - 1 do if not Used[N] then Ok := False;
  Check(Ok, 'all 40 positions are reachable');
  DecodeFixedCodebook(0, 1, Code);
  Check((Code[0] = 1) and (Code[1] = -1) and (Code[2] = -1) and (Code[3] = -1), 'signs: bit set = positive');
end;

procedure TestT04_Lsf;
var
  W, W2, Q: TLsf;
  A: TLpc;
  I: Integer;
  Err: Double;
  Ok: Boolean;
begin
  WriteLn('T04: LSF <-> LP');
  for I := 0 to G729_ORDER - 1 do W[I] := (I + 1) * Pi / 11 + 0.05 * Sin(3 * I);
  LsfToLsp(W, Q);
  LspToLp(Q, A);
  Ok := LpToLsf(A, W2);
  Err := 0;
  for I := 0 to G729_ORDER - 1 do Err := Max(Err, Abs(W[I] - W2[I]));
  Check(Ok and (Err < 1E-9), Format('round trip error %.2e rad', [Err]));
  for I := 0 to G729_ORDER - 1 do W[I] := 1.0;
  W[0] := 0.001;
  LsfStabilize(W);
  Ok := W[0] >= 0.005;
  for I := 1 to G729_ORDER - 1 do
    if W[I] - W[I - 1] < 0.0391 - 1E-12 then Ok := False;
  Check(Ok and (W[9] <= 3.135), 'stabilization enforces bounds and minimum distance');
end;

{ T05-T07 synthetic }

// Log-spectral distance (dB) on the bins within 20 dB of each frame's peak,
// 256-sample Hann frames every 1024 samples, Y delayed by Delay
function LogSpectralDistance(const X, Y: TArray<SmallInt>; Delay: Integer): Double;
const
  N = 256;
  KMax = 109;   // ~3.4 kHz
var
  O, K, I, C, Cnt: Integer;
  Px, Py: array[1..KMax] of Double;
  W, Re1, Im1, Re2, Im2, Ang, M, D, Sum: Double;
begin
  Result := 0; C := 0;
  O := 8000;
  while O + N + Delay < Length(Y) do
  begin
    M := 0;
    for K := 1 to KMax do
    begin
      Re1 := 0; Im1 := 0; Re2 := 0; Im2 := 0;
      for I := 0 to N - 1 do
      begin
        W := 0.5 - 0.5 * Cos(2 * Pi * I / N);
        Ang := 2 * Pi * K * I / N;
        Re1 := Re1 + W * X[O + I] * Cos(Ang); Im1 := Im1 - W * X[O + I] * Sin(Ang);
        Re2 := Re2 + W * Y[O + Delay + I] * Cos(Ang); Im2 := Im2 - W * Y[O + Delay + I] * Sin(Ang);
      end;
      Px[K] := Sqr(Re1) + Sqr(Im1) + 1;
      Py[K] := Sqr(Re2) + Sqr(Im2) + 1;
      if Px[K] > M then M := Px[K];
    end;
    Sum := 0; Cnt := 0;
    for K := 1 to KMax do
      if Px[K] > M / 100 then
      begin
        D := 10 * Log10(Px[K] / Py[K]);
        Sum := Sum + D * D; Inc(Cnt);
      end;
    Result := Result + Sqrt(Sum / Cnt);
    Inc(C);
    Inc(O, 1024);
  end;
  if C > 0 then Result := Result / C;
end;

// Correlation of the 20 ms energy contours of X and Y (Y delayed by Delay)
function EnvelopeCorrelation(const X, Y: TArray<SmallInt>; Delay: Integer): Double;
var
  E1, E2: TArray<Double>;
  F, I, Cnt: Integer;
  M1, M2, Num, D1, D2: Double;
begin
  Cnt := (Length(X) - 200) div 160;
  SetLength(E1, Cnt); SetLength(E2, Cnt);
  for F := 0 to Cnt - 1 do
  begin
    E1[F] := 0; E2[F] := 0;
    for I := F * 160 to F * 160 + 159 do
    begin
      E1[F] := E1[F] + Sqr(Double(X[I]));
      E2[F] := E2[F] + Sqr(Double(Y[I + Delay]));
    end;
  end;
  M1 := 0; M2 := 0;
  for F := 0 to Cnt - 1 do begin M1 := M1 + E1[F]; M2 := M2 + E2[F]; end;
  M1 := M1 / Cnt; M2 := M2 / Cnt;
  Num := 0; D1 := 0; D2 := 0;
  for F := 0 to Cnt - 1 do
  begin
    Num := Num + (E1[F] - M1) * (E2[F] - M2);
    D1 := D1 + Sqr(E1[F] - M1);
    D2 := D2 + Sqr(E2[F] - M2);
  end;
  Result := Num / Sqrt(D1 * D2);
end;

procedure TestT05_RoundTrip;
var
  Enc: TG729Encoder;
  Dec: TG729Decoder;
  X, Y: TArray<SmallInt>;
  Bits: TBytes;
  F: Integer;
  Lx, Ly, Lsd, Env: Double;
begin
  WriteLn('T05: encoder -> decoder round trip (synthetic voiced signal)');
  X := SyntheticSpeech(8000 * 4);
  Enc := TG729Encoder.Create;
  Dec := TG729Decoder.Create;
  try
    Bits := Enc.Encode(X);
    Check(Length(Bits) = Length(X) div G729_FRAME * G729_FRAME_BYTES, Format('%d octets for %d frames', [Length(Bits), Length(X) div 80]));
    SetLength(Y, Length(X));
    for F := 0 to Length(X) div G729_FRAME - 1 do
      Dec.Decode(@Bits[F * 10], 10, @Y[F * G729_FRAME]);
    Lx := Rms(X, 8000, 16000);
    Ly := Rms(Y, 8040, 16000);
    Check(Abs(20 * Log10(Ly / Lx)) < 1.5, Format('level preserved (%.2f dB)', [20 * Log10(Ly / Lx)]));
    // The postfilter changes the waveform, so the waveform SNR is meaningless here
    // (the ITU reference coder+decoder gives the same -2.7 dB on this signal).
    // Its log-spectral distance is 1.81 dB and its envelope correlation 0.887.
    Lsd := LogSpectralDistance(X, Y, 40);
    Env := EnvelopeCorrelation(X, Y, 40);
    Check(Lsd < 3, Format('log-spectral distance %.2f dB (reference chain: 1.81 dB)', [Lsd]));
    Check(Env > 0.8, Format('energy envelope correlation %.3f (reference chain: 0.887)', [Env]));
  finally
    Enc.Free; Dec.Free;
  end;
end;

procedure TestT06_LossAndInstances;
var
  Enc: TG729Encoder;
  D1, D2, D3: TG729Decoder;
  X, Y1, Y2, Y3: TArray<SmallInt>;
  Bits: TBytes;
  F, I: Integer;
  Same, Sane: Boolean;
  T: TG729FrameType;
begin
  WriteLn('T06: lost frames, reset and independent instances');
  X := SyntheticSpeech(8000 * 2);
  Enc := TG729Encoder.Create;
  D1 := TG729Decoder.Create; D2 := TG729Decoder.Create; D3 := TG729Decoder.Create;
  try
    Bits := Enc.Encode(X);
    SetLength(Y1, Length(X)); SetLength(Y2, Length(X)); SetLength(Y3, Length(X));
    for F := 0 to Length(X) div 80 - 1 do
    begin
      D1.Decode(@Bits[F * 10], 10, @Y1[F * 80]);
      // D2: every 7th frame lost, plus a burst of 5
      if (F mod 7 = 3) or ((F >= 100) and (F < 105)) then T := D2.Decode(nil, 0, @Y2[F * 80])
      else T := D2.Decode(@Bits[F * 10], 10, @Y2[F * 80]);
      if (F = 3) then Check(T = g729Lost, 'nil frame reported as lost');
      // D3 decodes silence frames in between and is reset before the real stream
      if F = 0 then
      begin
        for I := 1 to 20 do D3.Decode(nil, 0, @Y3[0]);
        D3.Reset;
      end;
      D3.Decode(@Bits[F * 10], 10, @Y3[F * 80]);
    end;
    Same := CompareMem(@Y1[0], @Y3[0], Length(Y1) * 2);
    Check(Same, 'Reset gives the same output as a new instance');
    Sane := Rms(Y2, 100 * 80, 5 * 80) < 3 * Rms(Y1, 100 * 80, 5 * 80) + 100;
    Check(Sane, 'concealment of a 5-frame burst stays bounded');
    Check(SegSnr(Y1, Y2, 0) > 0, Format('output with 18%% losses still tracks the clean one (%.1f dB)', [SegSnr(Y1, Y2, 0)]));
  finally
    Enc.Free; D1.Free; D2.Free; D3.Free;
  end;
end;

procedure TestT07_BlockApi;
const
  Sizes: array[0..4] of Integer = (1, 79, 160, 33, 240);
var
  E1, E2: TG729Encoder;
  Dec: TG729Decoder;
  X, Y1, Y2: TArray<SmallInt>;
  A, B: TBytes;
  Pos, N, K, Total, S: Integer;
begin
  WriteLn('T07: block API');
  X := SyntheticSpeech(8000);
  E1 := TG729Encoder.Create; E2 := TG729Encoder.Create;
  Dec := TG729Decoder.Create;
  try
    A := E1.Encode(X);
    SetLength(B, Length(A) + 10);
    Pos := 0; Total := 0; K := 0;
    while Pos < Length(X) do
    begin
      N := Min(Sizes[K mod Length(Sizes)], Length(X) - Pos);
      Inc(Total, E2.Encode(@X[Pos], N, @B[Total]));
      Inc(Pos, N); Inc(K);
    end;
    SetLength(B, Total);
    Check((Length(A) = Length(B)) and CompareMem(@A[0], @B[0], Length(A)), Format('%d blocks of odd sizes = one call', [K]));

    SetLength(Y1, 3 * 80); SetLength(Y2, 3 * 80);
    S := Dec.DecodePayload(@A[0], 30, @Y1[0]);
    Check(S = 240, 'DecodePayload: 3 frames -> 240 samples');
    Dec.Reset;
    for K := 0 to 2 do Dec.Decode(@A[K * 10], 10, @Y2[K * 80]);
    Check(CompareMem(@Y1[0], @Y2[0], 480), 'DecodePayload = frame by frame');
  finally
    E1.Free; E2.Free; Dec.Free;
  end;
end;

{ T08-T10 ITU-T vectors }

procedure TestT08_ItuDecoder;
const
  Names: array[0..8] of string = ('ALGTHM', 'ERASURE', 'FIXED', 'LSP', 'PARITY', 'PITCH', 'SPEECH', 'TAME', 'TEST');
  MinSnr: array[0..8] of Double = (29, 29, 26, 23, 32, 38, 31, 36, 29);
var
  Dir, FBit, FPst: string;
  K: Integer;
  Y, Ref: TArray<SmallInt>;
  Snr: Double;
begin
  WriteLn('T08: decoder vs G.729A reference output');
  Dir := SamplesDir + 'itu-g729a' + PathDelim;
  for K := 0 to High(Names) do
  begin
    FBit := FindFile(Dir, Names[K] + '.BIT');
    FPst := FindFile(Dir, Names[K] + '.PST');
    if (FBit = '') or (FPst = '') then begin Skip(Names[K] + ' (vectors not found)'); Continue; end;
    Y := DecodeSerial(LoadWords(FBit));
    Ref := LoadWords(FPst);
    Snr := SegSnr(Ref, Y, 0);
    Check(Snr >= MinSnr[K], Format('%s: segmental SNR %.1f dB (min %.0f)', [Names[K], Snr, MinSnr[K]]));
  end;
  FBit := FindFile(Dir, 'OVERFLOW.BIT');
  if FBit <> '' then
  begin
    Y := DecodeSerial(LoadWords(FBit));
    Check(Length(Y) = 384 * 80, 'OVERFLOW: decodes all frames (fixed-point overflow handling not reproduced)');
  end;
end;

procedure TestT09_FullG729;
const
  Names: array[0..4] of string = ('ALGTHM', 'LSP', 'PITCH', 'SPEECH', 'TAME');
var
  Dir, FBit, FPst: string;
  K: Integer;
  Y, Ref: TArray<SmallInt>;
  Snr: Double;
begin
  WriteLn('T09: full G.729 bit streams with the Annex A decoder');
  Dir := SamplesDir + 'itu-g729' + PathDelim;
  for K := 0 to High(Names) do
  begin
    FBit := FindFile(Dir, Names[K] + '.BIT');
    FPst := FindFile(Dir, Names[K] + '.PST');
    if (FBit = '') or (FPst = '') then begin Skip(Names[K] + ' (vectors not found)'); Continue; end;
    Y := DecodeSerial(LoadWords(FBit));
    Ref := LoadWords(FPst);
    Snr := SegSnr(Ref, Y, 0);
    // the reference output comes from the full decoder (different postfilter)
    Check(Snr >= 18, Format('%s: %.1f dB against the full G.729 decoder output', [Names[K], Snr]));
  end;
end;

procedure TestT10_ItuEncoder;
const
  Names: array[0..4] of string = ('SPEECH', 'PITCH', 'LSP', 'TAME', 'TEST');
var
  Dir, FIn, FBit: string;
  K, F: Integer;
  X, YOurs, YRef: TArray<SmallInt>;
  Enc: TG729Encoder;
  Dec: TG729Decoder;
  Frame: array[0..9] of Byte;
  SOurs, SRef: Double;
begin
  WriteLn('T10: encoder vs reference encoder (same decoder)');
  Dir := SamplesDir + 'itu-g729a' + PathDelim;
  for K := 0 to High(Names) do
  begin
    FIn := FindFile(Dir, Names[K] + '.IN');
    FBit := FindFile(Dir, Names[K] + '.BIT');
    if (FIn = '') or (FBit = '') then begin Skip(Names[K] + ' (vectors not found)'); Continue; end;
    X := LoadWords(FIn);
    Enc := TG729Encoder.Create;
    Dec := TG729Decoder.Create;
    try
      SetLength(YOurs, Length(X) div 80 * 80);
      for F := 0 to Length(X) div 80 - 1 do
      begin
        Enc.EncodeFrame10ms(@X[F * 80], @Frame[0]);
        Dec.Decode(@Frame[0], 10, @YOurs[F * 80]);
      end;
    finally
      Enc.Free; Dec.Free;
    end;
    YRef := DecodeSerial(LoadWords(FBit));
    SOurs := SegSnr(X, YOurs, 40);
    SRef := SegSnr(X, YRef, 40);
    Check(SOurs >= SRef - 0.5, Format('%s: %.2f dB (reference encoder %.2f dB)', [Names[K], SOurs, SRef]));
  end;
end;

begin
  Passed := 0;
  Failed := 0;
  Skipped := 0;
  WriteLn('=== G.729A Codec Tests ===');
  WriteLn;
  TestT01_Bits;
  TestT02_Pitch;
  TestT03_FixedCodebook;
  TestT04_Lsf;
  TestT05_RoundTrip;
  TestT06_LossAndInstances;
  TestT07_BlockApi;
  TestT08_ItuDecoder;
  TestT09_FullG729;
  TestT10_ItuEncoder;

  WriteLn;
  WriteLn(Format('Results: %d passed, %d failed, %d skipped', [Passed, Failed, Skipped]));
  if Failed = 0 then
    WriteLn('All tests PASSED.')
  else
    WriteLn('Some tests FAILED.');
  WriteLn;
  ExitCode := Failed;
end.
