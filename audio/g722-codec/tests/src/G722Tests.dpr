program G722Tests;

{
  G722Tests.dpr - Tests for g722-codec

    G01  Encoder: inpsp.bin -> codspw.cod, bit-exact (ITU-T test sequence)
    G02  Decoder mode 1 (64 kbit/s): codspw.cod -> outsp1.bin, bit-exact
    G03  Decoder mode 2 (56 kbit/s): codspw.cod -> outsp2.bin, bit-exact
    G04  Decoder mode 3 (48 kbit/s): codspw.cod -> outsp3.bin, bit-exact
    G05  Encoder + decoder chain (64 kbit/s) equals outsp1.bin
    G06  Block API: odd block sizes give the same octets as one call
    G07  Independent instances: interleaved encoders/decoders match
    G08  Round trip of a 1 kHz tone: SNR and level
    G09  Reset restores the initial state; array overloads
    G10  G.722 Appendix II digital test sequences, encoder (no QMF, with resets)
    G11  G.722 Appendix II digital test sequences, decoder in modes 1/2/3

  The test sequences (../samples) come from the ITU-T Software Tool Library
  (G.191, openitu/STL, src/g722/test_data): 16-bit little-endian samples,
  codspw.cod holds one octet per 16-bit word.
  The Appendix II sequences (bt*.xmt/.cod/.rc*, little-endian) are not
  redistributed: copy them to ../samples/itu-appII (see README); G10/G11
  are skipped when they are missing.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  SysUtils, Classes, Math,
  G722Codec;

var
  Passed, Failed: Integer;

procedure Check(Cond: Boolean; const Name: string);
begin
  if Cond then begin WriteLn('  PASS: ', Name); Inc(Passed); end
  else         begin WriteLn('  FAIL: ', Name); Inc(Failed); end;
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
  FS := TFileStream.Create(SamplesDir + FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, FS.Size div 2);
    if Length(Result) > 0 then FS.ReadBuffer(Result[0], Length(Result) * 2);
  finally
    FS.Free;
  end;
end;

function LoadCodes: TBytes;
var
  W: TArray<SmallInt>;
  I: Integer;
begin
  W := LoadWords('codspw.cod');
  SetLength(Result, Length(W));
  for I := 0 to High(W) do Result[I] := Byte(W[I]);
end;

// Index of the first difference, or -1
function FirstDiff(const A, B: TArray<SmallInt>): Integer; overload;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then Exit(Min(Length(A), Length(B)));
  for I := 0 to High(A) do
    if A[I] <> B[I] then Exit(I);
  Result := -1;
end;

function FirstDiff(const A, B: TBytes): Integer; overload;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then Exit(Min(Length(A), Length(B)));
  for I := 0 to High(A) do
    if A[I] <> B[I] then Exit(I);
  Result := -1;
end;

procedure ReportDiff(D: Integer; const Name: string);
begin
  if D < 0 then Check(True, Name + ' (bit-exact)')
  else Check(False, Format('%s (first difference at %d)', [Name, D]));
end;

var
  InPCM: TArray<SmallInt>;
  RefCodes: TBytes;

procedure TestG01_Encoder;
var
  Enc: TG722Encoder;
begin
  WriteLn('G01: encoder vs codspw.cod');
  Enc := TG722Encoder.Create;
  try
    ReportDiff(FirstDiff(Enc.Encode(InPCM), RefCodes),
      Format('%d samples -> %d octets', [Length(InPCM), Length(RefCodes)]));
  finally
    Enc.Free;
  end;
end;

procedure TestDecoderMode(const Tag: string; Mode: TG722Mode; const RefFile: string);
var
  Dec: TG722Decoder;
begin
  WriteLn(Tag, ': decoder vs ', RefFile);
  Dec := TG722Decoder.Create(Mode);
  try
    ReportDiff(FirstDiff(Dec.Decode(RefCodes), LoadWords(RefFile)), RefFile);
  finally
    Dec.Free;
  end;
end;

procedure TestG05_Chain;
var
  Enc: TG722Encoder;
  Dec: TG722Decoder;
begin
  WriteLn('G05: encoder + decoder chain');
  Enc := TG722Encoder.Create;
  Dec := TG722Decoder.Create;
  try
    ReportDiff(FirstDiff(Dec.Decode(Enc.Encode(InPCM)), LoadWords('outsp1.bin')), 'inpsp.bin -> outsp1.bin');
  finally
    Enc.Free; Dec.Free;
  end;
end;

procedure TestG06_Blocks;
const
  Sizes: array[0..5] of Integer = (1, 7, 160, 3, 320, 33);
var
  Enc: TG722Encoder;
  Out: TBytes;
  Pos, Total, K, N: Integer;
begin
  WriteLn('G06: odd block sizes');
  Enc := TG722Encoder.Create;
  try
    SetLength(Out, Length(InPCM) div 2 + 1);
    Pos := 0; Total := 0; K := 0;
    while Pos < Length(InPCM) do
    begin
      N := Min(Sizes[K mod Length(Sizes)], Length(InPCM) - Pos);
      Inc(Total, Enc.Encode(@InPCM[Pos], N, @Out[Total]));
      Inc(Pos, N);
      Inc(K);
    end;
    SetLength(Out, Total);
    ReportDiff(FirstDiff(Out, RefCodes), Format('%d blocks', [K]));
  finally
    Enc.Free;
  end;
end;

procedure TestG07_Instances;
var
  E1, E2: TG722Encoder;
  D1, D2: TG722Decoder;
  C1, C2: TBytes;
  P1, P2, Ref1, Ref3: TArray<SmallInt>;
  Silence: TArray<SmallInt>;
  I, Pos: Integer;
  Ok: Boolean;
begin
  WriteLn('G07: independent instances');
  E1 := TG722Encoder.Create; E2 := TG722Encoder.Create;
  D1 := TG722Decoder.Create(g722m64); D2 := TG722Decoder.Create(g722m48);
  try
    SetLength(C1, Length(RefCodes)); SetLength(C2, Length(RefCodes));
    SetLength(Silence, 320);
    Pos := 0;
    // E1 encodes the test sequence, E2 encodes silence in between
    while Pos < Length(InPCM) do
    begin
      I := Min(320, Length(InPCM) - Pos);
      E1.Encode(@InPCM[Pos], I, @C1[Pos div 2]);
      E2.Encode(@Silence[0], 320, @C2[0]);
      Inc(Pos, I);
    end;
    ReportDiff(FirstDiff(C1, RefCodes), 'interleaved encoders');

    Ref1 := LoadWords('outsp1.bin');
    Ref3 := LoadWords('outsp3.bin');
    SetLength(P1, Length(Ref1)); SetLength(P2, Length(Ref3));
    Pos := 0;
    while Pos < Length(RefCodes) do
    begin
      I := Min(80, Length(RefCodes) - Pos);
      D1.Decode(@RefCodes[Pos], I, @P1[2 * Pos]);
      D2.Decode(@RefCodes[Pos], I, @P2[2 * Pos]);
      Inc(Pos, I);
    end;
    Ok := (FirstDiff(P1, Ref1) < 0) and (FirstDiff(P2, Ref3) < 0);
    Check(Ok, 'interleaved decoders (64 and 48 kbit/s)');
  finally
    E1.Free; E2.Free; D1.Free; D2.Free;
  end;
end;

procedure TestG08_Tone;
const
  N = 16000;
var
  Enc: TG722Encoder;
  Dec: TG722Decoder;
  X, Y: TArray<SmallInt>;
  I, Lag, BestLag: Integer;
  Sig, Err, E, BestErr: Double;
begin
  WriteLn('G08: 1 kHz tone round trip');
  SetLength(X, N);
  for I := 0 to N - 1 do X[I] := Round(10000 * Sin(2 * Pi * 1000 * I / 16000));
  Enc := TG722Encoder.Create; Dec := TG722Decoder.Create;
  try
    Y := Dec.Decode(Enc.Encode(X));
    Check(Length(Y) = N, 'length preserved');
    // Codec delay (QMF) is 22 samples; search a small window
    BestErr := MaxDouble; BestLag := 0;
    for Lag := 0 to 40 do
    begin
      Err := 0;
      for I := 2000 to N - 100 do begin E := Y[I + Lag] - X[I]; Err := Err + E * E; end;
      if Err < BestErr then begin BestErr := Err; BestLag := Lag; end;
    end;
    Sig := 0;
    for I := 2000 to N - 100 do Sig := Sig + Sqr(X[I]);
    Check(BestLag = 22, Format('delay = %d samples', [BestLag]));
    Check(10 * Log10(Sig / Max(BestErr, 1)) > 30,
      Format('SNR %.1f dB', [10 * Log10(Sig / Max(BestErr, 1))]));
  finally
    Enc.Free; Dec.Free;
  end;
end;

procedure TestG09_Reset;
var
  Enc: TG722Encoder;
  Dec: TG722Decoder;
  A, B: TBytes;
  Z: TArray<SmallInt>;
begin
  WriteLn('G09: reset and overloads');
  Enc := TG722Encoder.Create; Dec := TG722Decoder.Create;
  try
    A := Enc.Encode(Copy(InPCM, 0, 1000));
    Enc.Encode(Copy(InPCM, 5000, 777));        // leaves state and a pending sample
    Enc.Reset;
    B := Enc.Encode(Copy(InPCM, 0, 1000));
    Check(FirstDiff(A, B) < 0, 'encoder reset');
    Dec.Decode(Copy(RefCodes, 3000, 100));
    Dec.Reset;
    Check(FirstDiff(Dec.Decode(Copy(RefCodes, 0, 500)), Copy(LoadWords('outsp1.bin'), 0, 1000)) < 0, 'decoder reset');
    Check(Length(Enc.Encode([])) = 0, 'empty input');
    Z := Dec.Decode([]);
    Check(Length(Z) = 0, 'empty decode');
    Enc.Mode := g722m48;
    A := Enc.Encode(Copy(InPCM, 0, 2000));
    Check((A[100] and 3 = 0) and (A[700] and 3 = 0), '48 kbit/s mode clears the auxiliary bits');
  finally
    Enc.Free; Dec.Free;
  end;
end;

function AppIIPath(const FileName: string): string;
begin
  Result := SamplesDir + 'itu-appII' + PathDelim + FileName;
end;

function LoadAppII(const FileName: string): TArray<SmallInt>;
begin
  Result := LoadWords('itu-appII' + PathDelim + FileName);
end;

// Each input word: bits 15..1 = sub-band sample (same for both bands), bit 0 = reset.
// Reference word: code in the high byte, or 1 for reset frames.
procedure TestG10_AppIIEncoder;
const
  Pairs: array[0..1, 0..1] of string = (('bt1c1.xmt', 'bt2r1.cod'), ('bt1c2.xmt', 'bt2r2.cod'));
var
  Enc: TG722Encoder;
  X, Ref: TArray<SmallInt>;
  K, I, Bad, Got, X15: Integer;
begin
  WriteLn('G10: Appendix II encoder sequences');
  if not FileExists(AppIIPath('bt1c1.xmt')) then
  begin
    WriteLn('  SKIP: vectors not found in samples/itu-appII');
    Exit;
  end;
  for K := 0 to 1 do
  begin
    X := LoadAppII(Pairs[K, 0]);
    Ref := LoadAppII(Pairs[K, 1]);
    Enc := TG722Encoder.Create;
    try
      Bad := -1;
      for I := 0 to High(X) do
      begin
        if X[I] and 1 <> 0 then
        begin
          Enc.ResetSubbands;
          Got := 1;
        end
        else
        begin
          X15 := X[I] div 2;          // even word: exact arithmetic shift
          Got := (Enc.EncodeSubbands(X15, X15) shl 8) and $FF00;
        end;
        if (Got <> Word(Ref[I])) and (Bad < 0) then Bad := I;
      end;
      ReportDiff(Bad, Format('%s -> %s (%d words)', [Pairs[K, 0], Pairs[K, 1], Length(X)]));
    finally
      Enc.Free;
    end;
  end;
end;

procedure TestG11_AppIIDecoder;
const
  Seqs: array[0..2, 0..1] of string = (('bt2r1.cod', '1'), ('bt2r2.cod', '2'), ('bt1d3.cod', '3'));
  Modes: array[1..3] of TG722Mode = (g722m64, g722m56, g722m48);
var
  Dec: TG722Decoder;
  C, RefL, RefH: TArray<SmallInt>;
  K, M, I, Bad, RL, RH, GotL, GotH: Integer;
  LName: string;
begin
  WriteLn('G11: Appendix II decoder sequences');
  if not FileExists(AppIIPath('bt2r1.cod')) then
  begin
    WriteLn('  SKIP: vectors not found in samples/itu-appII');
    Exit;
  end;
  for K := 0 to 2 do
  begin
    C := LoadAppII(Seqs[K, 0]);
    RefH := LoadAppII('bt3h' + Seqs[K, 1] + '.rc0');
    for M := 1 to 3 do
    begin
      LName := Format('bt3l%s.rc%d', [Seqs[K, 1], M]);
      RefL := LoadAppII(LName);
      Dec := TG722Decoder.Create(Modes[M]);
      try
        Bad := -1;
        for I := 0 to High(C) do
        begin
          if C[I] and 1 <> 0 then
          begin
            Dec.ResetSubbands;
            GotL := 1; GotH := 1;
          end
          else
          begin
            Dec.DecodeSubbands(Byte(Word(C[I]) shr 8), RL, RH);
            GotL := (RL shl 1) and $FFFE;
            GotH := (RH shl 1) and $FFFE;
          end;
          if ((GotL <> Word(RefL[I])) or (GotH <> Word(RefH[I]))) and (Bad < 0) then Bad := I;
        end;
        ReportDiff(Bad, Format('%s mode %d -> %s', [Seqs[K, 0], M, LName]));
      finally
        Dec.Free;
      end;
    end;
  end;
end;

begin
  Passed := 0;
  Failed := 0;
  WriteLn('=== G.722 Codec Tests ===');
  WriteLn;
  InPCM := LoadWords('inpsp.bin');
  RefCodes := LoadCodes;

  TestG01_Encoder;
  TestDecoderMode('G02', g722m64, 'outsp1.bin');
  TestDecoderMode('G03', g722m56, 'outsp2.bin');
  TestDecoderMode('G04', g722m48, 'outsp3.bin');
  TestG05_Chain;
  TestG06_Blocks;
  TestG07_Instances;
  TestG08_Tone;
  TestG09_Reset;
  TestG10_AppIIEncoder;
  TestG11_AppIIDecoder;

  WriteLn;
  WriteLn(Format('Results: %d passed, %d failed', [Passed, Failed]));
  if Failed = 0 then
    WriteLn('All tests PASSED.')
  else
    WriteLn('Some tests FAILED.');
  WriteLn;
  ExitCode := Failed;
end.
