program OpusEncoderTests;

{
  OpusEncoderTests.dpr - Pruebas del encoder Opus (port de libopus 1.5.2)

  RC  codificador de rango: ida y vuelta contra el range decoder del port
      (opus-decoder), incluidos Laplace, ICDF, enteros y bits crudos.
  PV  PVQ: encode_pulses -> decode_pulses para varios (N, K).
  GV  vectores de referencia de libopus 1.5.2: señales sintéticas deterministas
      codificadas con el oráculo (tests/tools/opus_oracle, variante sin
      análisis para complejidad >= 7) -> número de paquetes, bytes, CRC32 y
      XOR de final_range deben ser idénticos (byte a byte).
  DE  todos los paquetes se decodifican con el decoder del port, con la
      duración correcta.
  CB  CBR: todos los paquetes del tamaño exacto.
  VB  VBR/CVBR: bitrate medio dentro de +-5 % del objetivo.
  IN  tres instancias intercaladas (CELT, SILK, híbrido) producen los mismos bytes
      que por separado.
  OG  Ogg Opus: pre-skip, y el decodificado tiene exactamente las muestras de
      entrada (recorte del final).
  CO  capa de compatibilidad TOpusCeltEncoder (TOC y duración).
  CT  validación de CTLs y argumentos.

  Licencia de las pruebas: CC0 1.0.
}

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  SysUtils, Classes, Math,
  AudioTypes,
  OpusEntDec,
  OpusCeltTables,
  OpusCeltMath,
  OpusDecoder,
  OpusEntEnc,
  OpusCeltEncMath,
  OpusEncTypes,
  OpusEncoder,
  OpusRepacketizer,
  OggOpusWriter,
  OpusEncPacket,
  OpusEncTestSignals;

var
  Passed, Failed: Integer;

procedure Check(Cond: Boolean; const Name: string);
begin
  if Cond then begin WriteLn('  PASS: ', Name); Inc(Passed); end
  else         begin WriteLn('  FAIL: ', Name); Inc(Failed); end;
end;

// CRC-32 (IEEE, reflejado), igual que zlib.crc32
var
  Crc32Table: array[0..255] of Cardinal;

procedure InitCrc32;
var
  I, K: Integer;
  C: Cardinal;
begin
  for I := 0 to 255 do
  begin
    C := I;
    for K := 0 to 7 do
      if (C and 1) <> 0 then C := $EDB88320 xor (C shr 1) else C := C shr 1;
    Crc32Table[I] := C;
  end;
end;

function Crc32Update(Crc: Cardinal; P: PByte; Len: Integer): Cardinal;
var
  I: Integer;
begin
  Crc := not Crc;
  for I := 0 to Len - 1 do
    Crc := Crc32Table[(Crc xor P[I]) and $FF] xor (Crc shr 8);
  Result := not Crc;
end;

// ---------------------------------------------------------------------------
// Encode helpers
// ---------------------------------------------------------------------------

type
  TCase = record
    Name     : string;
    Kind     : TTestSignal;
    Fs, Ch   : Integer;
    Samples  : Integer;
    App      : TOpusApplication;
    Ms10     : Integer;   // frame duration in 0.1 ms
    Bitrate  : Integer;
    Vbr, Cvbr: Boolean;
    Cx       : Integer;
    Mode     : Integer;   // MODE_* or OPUS_AUTO
    Fec, Loss: Integer;
    // reference (libopus 1.5.2)
    NPk      : Integer;
    Bytes    : Integer;
    Crc      : Cardinal;
    RngXor   : Cardinal;
  end;

  TPackets = TArray<TBytes>;

const
  CASES: array[0..11] of TCase = (
    (Name: 'A chirp 48k mono lowdelay 20ms CBR 64k cx0'; Kind: tsChirp; Fs: 48000; Ch: 1; Samples: 48000;
     App: oaRestrictedLowDelay; Ms10: 200; Bitrate: 64000; Vbr: False; Cvbr: True; Cx: 0; Mode: MODE_CELT_ONLY; Fec: 0; Loss: 0;
     NPk: 50; Bytes: 8000; Crc: $430BA29F; RngXor: $6AFD7B7A),
    (Name: 'B music 48k stereo audio 20ms CVBR 96k cx10'; Kind: tsMusicLike; Fs: 48000; Ch: 2; Samples: 48000;
     App: oaAudio; Ms10: 200; Bitrate: 96000; Vbr: True; Cvbr: True; Cx: 10; Mode: MODE_CELT_ONLY; Fec: 0; Loss: 0;
     NPk: 50; Bytes: 12050; Crc: $E52DE5D7; RngXor: $4A8D9FAD),
    (Name: 'C speech 16k mono voip 20ms CVBR 24k cx5'; Kind: tsSpeechLike; Fs: 16000; Ch: 1; Samples: 16000;
     App: oaVoip; Ms10: 200; Bitrate: 24000; Vbr: True; Cvbr: True; Cx: 5; Mode: MODE_CELT_ONLY; Fec: 0; Loss: 0;
     NPk: 50; Bytes: 3050; Crc: $EEDBF762; RngXor: $7F85C420),
    (Name: 'D music 48k stereo lowdelay 2.5ms CBR 128k cx10'; Kind: tsMusicLike; Fs: 48000; Ch: 2; Samples: 24000;
     App: oaRestrictedLowDelay; Ms10: 25; Bitrate: 128000; Vbr: False; Cvbr: True; Cx: 10; Mode: MODE_CELT_ONLY; Fec: 0; Loss: 0;
     NPk: 200; Bytes: 8000; Crc: $988E9B00; RngXor: $13D6BD63),
    (Name: 'E speech 48k mono audio 60ms VBR 32k cx9'; Kind: tsSpeechLike; Fs: 48000; Ch: 1; Samples: 57600;
     App: oaAudio; Ms10: 600; Bitrate: 32000; Vbr: True; Cvbr: False; Cx: 9; Mode: MODE_CELT_ONLY; Fec: 0; Loss: 0;
     NPk: 20; Bytes: 4780; Crc: $87AC7650; RngXor: $5A130F00),
    (Name: 'F speech 8k mono voip 10ms CBR 16k cx10'; Kind: tsSpeechLike; Fs: 8000; Ch: 1; Samples: 8000;
     App: oaVoip; Ms10: 100; Bitrate: 16000; Vbr: False; Cvbr: True; Cx: 10; Mode: MODE_CELT_ONLY; Fec: 0; Loss: 0;
     NPk: 100; Bytes: 2000; Crc: $B12B557B; RngXor: $0647D209),
    (Name: 'G music 24k stereo audio 10ms CVBR 48k cx8'; Kind: tsMusicLike; Fs: 24000; Ch: 2; Samples: 24000;
     App: oaAudio; Ms10: 100; Bitrate: 48000; Vbr: True; Cvbr: True; Cx: 8; Mode: MODE_CELT_ONLY; Fec: 0; Loss: 0;
     NPk: 100; Bytes: 6100; Crc: $0CA3D93A; RngXor: $16C70163),
    (Name: 'H speech 16k mono voip 20ms VBR 16k cx10 auto (SILK WB)'; Kind: tsSpeechLike; Fs: 16000; Ch: 1;
     Samples: 16000; App: oaVoip; Ms10: 200; Bitrate: 16000; Vbr: True; Cvbr: True; Cx: 10;
     Mode: OPUS_AUTO; Fec: 0; Loss: 0;
     NPk: 50; Bytes: 1539; Crc: $9DBB0E33; RngXor: $74951E42),
    (Name: 'I speech 8k mono voip 20ms 24k cx9 FEC 10% (SILK NB + LBRR)'; Kind: tsSpeechLike; Fs: 8000; Ch: 1;
     Samples: 16000; App: oaVoip; Ms10: 200; Bitrate: 24000; Vbr: True; Cvbr: True; Cx: 9;
     Mode: OPUS_AUTO; Fec: 1; Loss: 10;
     NPk: 100; Bytes: 5272; Crc: $058C9093; RngXor: $5DF9017B),
    (Name: 'J speech 48k mono voip 20ms 24k cx6 auto (hybrid FB)'; Kind: tsSpeechLike; Fs: 48000; Ch: 1;
     Samples: 48000; App: oaVoip; Ms10: 200; Bitrate: 24000; Vbr: True; Cvbr: True; Cx: 6;
     Mode: OPUS_AUTO; Fec: 0; Loss: 0;
     NPk: 50; Bytes: 3115; Crc: $780592B2; RngXor: $258D7629),
    (Name: 'K speech 48k stereo voip 40ms 32k cx8 auto (hybrid stereo)'; Kind: tsSpeechLike; Fs: 48000; Ch: 2;
     Samples: 96000; App: oaVoip; Ms10: 400; Bitrate: 32000; Vbr: True; Cvbr: True; Cx: 8;
     Mode: OPUS_AUTO; Fec: 0; Loss: 0;
     NPk: 50; Bytes: 6775; Crc: $48269885; RngXor: $54C12BD9),
    (Name: 'L speech 16k mono voip 10ms CBR 20k cx2 SILK'; Kind: tsSpeechLike; Fs: 16000; Ch: 1;
     Samples: 16000; App: oaVoip; Ms10: 100; Bitrate: 20000; Vbr: False; Cvbr: True; Cx: 2;
     Mode: MODE_SILK_ONLY; Fec: 0; Loss: 0;
     NPk: 100; Bytes: 2500; Crc: $D343547D; RngXor: $1F4184C2));

function NewEncoder(const C: TCase): TOpusEncoder;
begin
  Result := TOpusEncoder.Create(C.Fs, C.Ch, C.App);
  Result.Bitrate := C.Bitrate;
  Result.Vbr := C.Vbr;
  Result.VbrConstraint := C.Cvbr;
  Result.Complexity := C.Cx;
  Result.ForceMode := C.Mode;
  Result.InbandFec := C.Fec;
  Result.PacketLossPerc := C.Loss;
end;

// Encodes frame number Index of the case signal; returns the packet
function EncodeOne(Enc: TOpusEncoder; const C: TCase; const Pcm: TArray<SmallInt>;
  Index: Integer; out Rng: Cardinal): TBytes;
var
  Frame, Len: Integer;
  Pkt: array[0..1499] of Byte;
  Tmp: TArray<SmallInt>;
  Start, Avail: Integer;
begin
  Frame := C.Fs * C.Ms10 div 10000;
  SetLength(Tmp, Frame * C.Ch);
  Start := Index * Frame;
  Avail := Min(Frame, C.Samples - Start);
  if Avail > 0 then
    Move(Pcm[Start * C.Ch], Tmp[0], Avail * C.Ch * 2);
  Len := Enc.Encode(@Tmp[0], Frame, @Pkt[0], 1276);
  if Len < 0 then
    raise Exception.CreateFmt('encode error %d', [Len]);
  Rng := Enc.FinalRange;
  SetLength(Result, Len);
  Move(Pkt[0], Result[0], Len);
end;

function EncodeCase(const C: TCase; out Rngs: TArray<Cardinal>): TPackets;
var
  Enc: TOpusEncoder;
  Pcm: TArray<SmallInt>;
  Frame, N, I: Integer;
begin
  Pcm := MakeTestSignal(C.Kind, C.Fs, C.Ch, C.Samples);
  Frame := C.Fs * C.Ms10 div 10000;
  N := (C.Samples + Frame - 1) div Frame;
  SetLength(Result, N);
  SetLength(Rngs, N);
  Enc := NewEncoder(C);
  try
    for I := 0 to N - 1 do
      Result[I] := EncodeOne(Enc, C, Pcm, I, Rngs[I]);
  finally
    Enc.Free;
  end;
end;

procedure Summarize(const P: TPackets; const R: TArray<Cardinal>; out Bytes: Integer;
  out Crc, RngXor: Cardinal);
var
  I: Integer;
begin
  Bytes := 0; Crc := 0; RngXor := 0;
  for I := 0 to High(P) do
  begin
    Inc(Bytes, Length(P[I]));
    if Length(P[I]) > 0 then
      Crc := Crc32Update(Crc, @P[I][0], Length(P[I]));
    RngXor := RngXor xor R[I];
  end;
end;

// ---------------------------------------------------------------------------

procedure TestRangeCoder;
const
  NOPS = 4000;
  ICDF: array[0..3] of Byte = (200, 120, 30, 0);
var
  Buf: array[0..65535] of Byte;
  E: TEcEnc;
  D: TEcDec;
  Ops, Vals, Params: array of Integer;
  I, V, Len, Bad, Seed: Integer;
  Lap: Integer;
  TellsE, TellsD: array of Integer;
begin
  WriteLn('--- RC: range coder ---');
  SetLength(Ops, NOPS); SetLength(Vals, NOPS); SetLength(Params, NOPS);
  SetLength(TellsE, NOPS); SetLength(TellsD, NOPS);
  Seed := 1;
  EcEncInit(E, @Buf[0], SizeOf(Buf));
  for I := 0 to NOPS - 1 do
  begin
    Seed := Seed * 1103515245 + 12345;
    Ops[I] := (Seed shr 16) mod 6;
    Seed := Seed * 1103515245 + 12345;
    V := (Seed shr 8) and $FFFF;
    case Ops[I] of
      0: begin Params[I] := 1 + V mod 15; Vals[I] := (V shr 4) and 1; EcEncBitLogp(E, Vals[I], Params[I]); end;
      1: begin Params[I] := 2 + V mod 3000; Vals[I] := (V * 7) mod Params[I]; EcEncUInt(E, Vals[I], Params[I]); end;
      2: begin Params[I] := 1 + V mod 24; Vals[I] := (V * 13) and ((1 shl Params[I]) - 1); EcEncBits(E, Vals[I], Params[I]); end;
      3: begin Vals[I] := V mod 4; EcEncIcdf(E, Vals[I], @ICDF[0], 8); end;
      4: begin
           // fs/decay pairs of the real coarse-energy models (e_prob_model)
           Lap := (V mod 21) - 10; Params[I] := (V shr 5) mod 168;
           EcLaplaceEncode(E, Lap, Cardinal(CELT_E_PROB_MODEL[2 * Params[I]]) shl 7,
             Integer(CELT_E_PROB_MODEL[2 * Params[I] + 1]) shl 6);
           Vals[I] := Lap;
         end;
    else
      begin Params[I] := 2 + V mod 200; Vals[I] := V mod Params[I]; EcEncode(E, Vals[I], Vals[I] + 1, Params[I]); end;
    end;
    TellsE[I] := EcTellFrac(E);
  end;
  EcEncDone(E);
  Check(E.Error = 0, 'RC01 encoder sin error');
  Len := E.Storage;
  EcDecInit(D, @Buf[0], Len);
  Bad := 0;
  for I := 0 to NOPS - 1 do
  begin
    case Ops[I] of
      0: V := EcDecBitLogp(D, Params[I]);
      1: V := EcDecUInt(D, Params[I]);
      2: V := EcDecBits(D, Params[I]);
      3: V := EcDecIcdf(D, @ICDF[0], 8);
      4: V := EcLaplaceDecode(D, Cardinal(CELT_E_PROB_MODEL[2 * Params[I]]) shl 7,
           Integer(CELT_E_PROB_MODEL[2 * Params[I] + 1]) shl 6);
    else
      begin V := EcDecode(D, Params[I]); EcDecUpdate(D, V, V + 1, Params[I]); end;
    end;
    TellsD[I] := OpusEntDec.EcTellFrac(D);
    if (V <> Vals[I]) or (TellsD[I] <> TellsE[I]) then
    begin
      if Bad = 0 then
        WriteLn(Format('    primer error: símbolo %d op %d param %d: %d <> %d, tell %d <> %d',
          [I, Ops[I], Params[I], V, Vals[I], TellsD[I], TellsE[I]]));
      Inc(Bad);
    end;
  end;
  Check(Bad = 0, Format('RC02 %d símbolos decodificados igual y ec_tell_frac idéntico (%d errores)', [NOPS, Bad]));
  Check(D.Rng = E.Rng, 'RC03 rango final del decoder = encoder');
end;

// V(N,K) with 64-bit arithmetic: V(N,K) = V(N-1,K) + V(N,K-1) + V(N-1,K-1)
function PvqV64(N, K: Integer): Int64;
var
  V: array of array of Int64;
  I, J: Integer;
begin
  SetLength(V, N + 1, K + 1);
  for I := 0 to N do V[I][0] := 1;
  for J := 1 to K do V[0][J] := 0;
  for I := 1 to N do
    for J := 1 to K do
      V[I][J] := V[I - 1][J] + V[I][J - 1] + V[I - 1][J - 1];
  Result := V[N][K];
end;

procedure TestPvq;
var
  N, K, T, I, J, Bad, Seed, Total: Integer;
  Y, Y2: array of Integer;
  Buf: array[0..255] of Byte;
  E: TEcEnc;
  D: TEcDec;
begin
  WriteLn('--- PV: PVQ (cwrs) ---');
  Bad := 0;
  Total := 0;
  Seed := 7;
  for N := 2 to 24 do
    for K := 1 to 12 do
      for T := 0 to 3 do
      begin
        SetLength(Y, N); SetLength(Y2, N);
        for I := 0 to N - 1 do Y[I] := 0;
        if PvqV64(N, K) > High(Cardinal) then Continue;
        for I := 1 to K do
        begin
          Seed := Seed * 1103515245 + 12345;
          J := (Seed shr 16) mod N;
          if ((Seed shr 8) and 1) <> 0 then
          begin
            if Y[J] <= 0 then Dec(Y[J]) else Inc(Y[J]);
          end
          else if Y[J] >= 0 then Inc(Y[J]) else Dec(Y[J]);
        end;
        if PvqV64(N, K) > High(Cardinal) then Continue;   // CELT keeps V(N,K) < 2^32
        EcEncInit(E, @Buf[0], SizeOf(Buf));
        EncodePulses(@Y[0], N, K, E);
        EcEncDone(E);
        EcDecInit(D, @Buf[0], E.Storage);
        DecodePulses(@Y2[0], N, K, D);
        for I := 0 to N - 1 do
          if Y[I] <> Y2[I] then begin Inc(Bad); Break; end;
        Inc(Total);
      end;
  Check(Bad = 0, Format('PV01 %d vectores PVQ ida y vuelta (%d errores)', [Total, Bad]));
end;

procedure TestGoldenVectors;
var
  K: Integer;
  P: TPackets;
  R: TArray<Cardinal>;
  Bytes: Integer;
  Crc, RngX: Cardinal;
begin
  WriteLn('--- GV: vectores de referencia libopus 1.5.2 ---');
  for K := 0 to High(CASES) do
  begin
    P := EncodeCase(CASES[K], R);
    Summarize(P, R, Bytes, Crc, RngX);
    Check((Length(P) = CASES[K].NPk) and (Bytes = CASES[K].Bytes) and (Crc = CASES[K].Crc) and
      (RngX = CASES[K].RngXor),
      Format('GV%.2d %s: %d paquetes, %d bytes, CRC %.8x, rng %.8x', [K + 1, CASES[K].Name,
        Length(P), Bytes, Crc, RngX]));
  end;
end;

procedure TestDecodeAndRates;
var
  K, I, N, Bad, Expected, Sz: Integer;
  P: TPackets;
  R: TArray<Cardinal>;
  Dec: TOpusStreamDecoder;
  Buf: TAudioBuffer;
  AllSame: Boolean;
begin
  WriteLn('--- DE / CB: decodificación y CBR ---');
  for K := 0 to High(CASES) do
  begin
    P := EncodeCase(CASES[K], R);
    Dec := TOpusStreamDecoder.Create(CASES[K].Ch);
    try
      Bad := 0;
      Expected := 48000 * CASES[K].Ms10 div 10000;
      for I := 0 to High(P) do
      begin
        N := Dec.DecodePacket(@P[I][0], Length(P[I]), Buf);
        if N <> Expected then Inc(Bad);
      end;
      Check(Bad = 0, Format('DE%.2d %s: %d paquetes decodificados con %d muestras', [K + 1,
        CASES[K].Name, Length(P), Expected]));
    finally
      Dec.Free;
    end;
    if not CASES[K].Vbr then
    begin
      Sz := CASES[K].Bitrate * CASES[K].Ms10 div 80000;
      AllSame := True;
      for I := 0 to High(P) do
        if Length(P[I]) <> Sz then AllSame := False;
      Check(AllSame, Format('CB%.2d %s: todos los paquetes de %d bytes', [K + 1, CASES[K].Name, Sz]));
    end;
  end;
end;

procedure TestVbrRate;
const
  TARGETS: array[0..2] of Integer = (24000, 64000, 128000);
var
  T, I, Frame, N, Len, Total: Integer;
  Pcm: TArray<SmallInt>;
  Enc: TOpusEncoder;
  Pkt: array[0..1499] of Byte;
  Rate, Err: Double;
begin
  WriteLn('--- VB: bitrate medio en CVBR ---');
  Pcm := MakeTestSignal(tsMusicLike, 48000, 2, 48000 * 10);
  Frame := 960;
  for T := 0 to High(TARGETS) do
  begin
    Enc := TOpusEncoder.Create(48000, 2, oaAudio);
    try
      Enc.Bitrate := TARGETS[T];
      Enc.Complexity := 10;
      N := Length(Pcm) div (2 * Frame);
      Total := 0;
      for I := 0 to N - 1 do
      begin
        Len := Enc.Encode(@Pcm[I * Frame * 2], Frame, @Pkt[0], 1276);
        Inc(Total, Len);
      end;
      Rate := Total * 8.0 / (N * 0.02);
      Err := 100 * (Rate - TARGETS[T]) / TARGETS[T];
      Check(Abs(Err) <= 5, Format('VB%.2d objetivo %d bps -> %.0f bps (%.2f %%)', [T + 1, TARGETS[T], Rate, Err]));
    finally
      Enc.Free;
    end;
  end;
end;

procedure TestInterleavedSet(const Tag: string; I0, I1, I2: Integer);
var
  K, I, MaxN: Integer;
  Sep, Int_: array[0..2] of TPackets;
  R: TArray<Cardinal>;
  Encs: array[0..2] of TOpusEncoder;
  Pcms: array[0..2] of TArray<SmallInt>;
  Rng: Cardinal;
  Same: Boolean;
  Idx: array[0..2] of Integer;
  N: array[0..2] of Integer;
begin
  Idx[0] := I0; Idx[1] := I1; Idx[2] := I2;
  for K := 0 to 2 do
    Sep[K] := EncodeCase(CASES[Idx[K]], R);
  for K := 0 to 2 do
  begin
    Encs[K] := NewEncoder(CASES[Idx[K]]);
    Pcms[K] := MakeTestSignal(CASES[Idx[K]].Kind, CASES[Idx[K]].Fs, CASES[Idx[K]].Ch, CASES[Idx[K]].Samples);
    N[K] := Length(Sep[K]);
    SetLength(Int_[K], N[K]);
  end;
  try
    MaxN := Max(N[0], Max(N[1], N[2]));
    for I := 0 to MaxN - 1 do
      for K := 0 to 2 do
        if I < N[K] then
          Int_[K][I] := EncodeOne(Encs[K], CASES[Idx[K]], Pcms[K], I, Rng);
  finally
    for K := 0 to 2 do Encs[K].Free;
  end;
  Same := True;
  for K := 0 to 2 do
    for I := 0 to N[K] - 1 do
      if (Length(Sep[K][I]) <> Length(Int_[K][I])) or
         ((Length(Sep[K][I]) > 0) and not CompareMem(@Sep[K][I][0], @Int_[K][I][0], Length(Sep[K][I]))) then
        Same := False;
  Check(Same, Tag + ' 3 encoders intercalados = codificados por separado (byte a byte)');
end;

procedure TestInterleaved;
begin
  WriteLn('--- IN: instancias intercaladas ---');
  TestInterleavedSet('IN01 CELT (B, C, F):', 1, 2, 5);
  TestInterleavedSet('IN02 SILK/hibrido (H, I, J):', 7, 8, 9);
  TestInterleavedSet('IN03 mixto (K, L, B):', 10, 11, 1);
end;

procedure TestOgg;
const
  NIN = 48000 + 1234;
var
  Pcm: TArray<SmallInt>;
  Ms: TMemoryStream;
  W: TOggOpusWriter;
  D: TOpusDecoder;
  Buf: TAudioBuffer;
  Samples, Total: Integer;
  Res: TAudioDecodeResult;
begin
  WriteLn('--- OG: Ogg Opus ---');
  Pcm := MakeTestSignal(tsChirp, 48000, 2, NIN);
  Ms := TMemoryStream.Create;
  try
    W := TOggOpusWriter.Create(Ms, 48000, 2, oaAudio, 200);
    try
      W.Encoder.Bitrate := 96000;
      W.AddComment('TITLE=prueba');
      W.WriteInt16(@Pcm[0], 1000);
      W.WriteInt16(@Pcm[2000], NIN - 1000);
      W.Finish;
      Check(W.PreSkip = 312, Format('OG01 pre-skip = %d (lookahead 2,5 ms + 4 ms)', [W.PreSkip]));
    finally
      W.Free;
    end;
    Ms.Position := 0;
    D := TOpusDecoder.Create(Ms);
    try
      Total := 0;
      repeat
        Res := D.Decode(Buf, Samples);
        if Res = adrOK then Inc(Total, Samples);
      until Res <> adrOK;
      Check(D.PreSkip = 312, 'OG02 el decoder lee el pre-skip del OpusHead');
      Check(Total = NIN, Format('OG03 muestras decodificadas = entrada (%d / %d)', [Total, NIN]));
    finally
      D.Free;
    end;
  finally
    Ms.Free;
  end;
end;

{$WARN SYMBOL_DEPRECATED OFF}
procedure TestCompat;
const
  MSV: array[0..2] of Integer = (5, 10, 20);
var
  K, Len, N: Integer;
  E: TOpusCeltEncoder;
  Pcm: TArray<SmallInt>;
  Pkt: array[0..1275] of Byte;
  Dec: TOpusStreamDecoder;
  Buf: TAudioBuffer;
begin
  WriteLn('--- CO: compatibilidad TOpusCeltEncoder ---');
  for K := 0 to 2 do
  begin
    E := TOpusCeltEncoder.Create(1, 48000, MSV[K]);
    Dec := TOpusStreamDecoder.Create(1);
    try
      Pcm := MakeTestSignal(tsChirp, 48000, 1, E.FrameSize);
      Len := E.EncodeFrame(@Pcm[0], @Pkt[0], 160);
      N := Dec.DecodePacket(@Pkt[0], Len, Buf);
      Check((Len = 160) and (E.Config = 28 + E.LM) and (N = E.FrameSize),
        Format('CO%.2d %d ms: %d bytes, config TOC %d, %d muestras', [K + 1, MSV[K], Len, E.Config, N]));
    finally
      E.Free;
      Dec.Free;
    end;
  end;
end;
{$WARN SYMBOL_DEPRECATED ON}

procedure TestCtls;
var
  Enc: TOpusEncoder;
  Raised: Boolean;
  Pcm: array[0..959] of SmallInt;
  Pkt: array[0..1275] of Byte;
begin
  WriteLn('--- CT: CTLs y argumentos ---');
  Raised := False;
  try
    TOpusEncoder.Create(44100, 1, oaAudio).Free;
  except
    Raised := True;
  end;
  Check(Raised, 'CT01 frecuencia no soportada -> excepción');
  Enc := TOpusEncoder.Create(48000, 1, oaVoip);
  try
    Raised := False;
    try Enc.Complexity := 11; except Raised := True; end;
    Check(Raised, 'CT02 complejidad 11 -> excepción');
    Raised := False;
    try Enc.Bitrate := 0; except Raised := True; end;
    Check(Raised, 'CT03 bitrate 0 -> excepción');
    Enc.Bitrate := 100;
    Check(Enc.Bitrate = 500, 'CT04 bitrate < 500 se ajusta a 500');
    Check(Enc.Lookahead = 312, 'CT05 lookahead 48 kHz VoIP = 312');
    FillChar(Pcm, SizeOf(Pcm), 0);
    Check(Enc.Encode(@Pcm[0], 100, @Pkt[0], 1276) = OPUS_BAD_ARG, 'CT06 tamaño de trama inválido -> OPUS_BAD_ARG');
    Check(Enc.Encode(@Pcm[0], 960, @Pkt[0], 1276) > 0, 'CT07 trama válida');
  finally
    Enc.Free;
  end;
end;

procedure TestPad;
var
  Pkt, Pad: array[0..1275] of Byte;
  Enc: TOpusEncoder;
  Pcm: TArray<SmallInt>;
  Len: Integer;
  D1, D2: TOpusStreamDecoder;
  B1, B2: TAudioBuffer;
  N1, N2, I: Integer;
  Same: Boolean;
begin
  WriteLn('--- PA: relleno de paquetes ---');
  Pcm := MakeTestSignal(tsMusicLike, 48000, 1, 960);
  Enc := TOpusEncoder.Create(48000, 1, oaAudio);
  try
    Len := Enc.Encode(@Pcm[0], 960, @Pkt[0], 1276);
  finally
    Enc.Free;
  end;
  Move(Pkt, Pad, Len);
  Check(OpusPacketPad(@Pad[0], Len, Len + 300) = OPUS_OK, 'PA01 opus_packet_pad +300 bytes');
  D1 := TOpusStreamDecoder.Create(1);
  D2 := TOpusStreamDecoder.Create(1);
  try
    N1 := D1.DecodePacket(@Pkt[0], Len, B1);
    N2 := D2.DecodePacket(@Pad[0], Len + 300, B2);
    Same := (N1 = N2) and (N1 = 960);
    if Same then
      for I := 0 to N1 - 1 do
        if B1[0][I] <> B2[0][I] then Same := False;
    Check(Same, 'PA02 el paquete relleno decodifica igual que el original');
  finally
    D1.Free;
    D2.Free;
  end;
end;

begin
  InitCrc32;
  Passed := 0;
  Failed := 0;
  try
    TestRangeCoder;
    TestPvq;
    TestGoldenVectors;
    TestDecodeAndRates;
    TestVbrRate;
    TestInterleaved;
    TestOgg;
    TestCompat;
    TestCtls;
    TestPad;
  except
    on E: Exception do
    begin
      WriteLn('EXCEPCIÓN: ', E.ClassName, ': ', E.Message);
      Inc(Failed);
    end;
  end;
  WriteLn;
  WriteLn(Format('Resultado: %d pasan, %d fallan', [Passed, Failed]));
  if Failed > 0 then ExitCode := 1;
end.
