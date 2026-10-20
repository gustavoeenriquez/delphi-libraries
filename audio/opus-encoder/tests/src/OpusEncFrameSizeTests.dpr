program OpusEncFrameSizeTests;

{
  OpusEncFrameSizeTests.dpr - TOC y duración de trama de TOpusCeltEncoder

  Para cada tamaño de trama que acepta TOpusCeltEncoder.Create:
    FS01  config del TOC = 16 + 4*bw + LM (RFC 6716 §3.1). El encoder CELT
          codifica siempre las 21 bandas (end band 21 = fullband), así que
          el config esperado es 28 + LM: 29 (5 ms), 30 (10 ms), 31 (20 ms).
    FS02  TOpusStreamDecoder.DecodePacket (decoder fiel a libopus 1.5.2)
          devuelve exactamente FrameSize muestras por canal a 48 kHz
          (240 / 480 / 960).
    FS03  SNR del seno decodificado (informativa, ver nota).

  2,5 ms (LM 0) NO es seleccionable: Create recibe FrameSizeMs entero y
  cualquier valor distinto de 5/10/20 cae a 20 ms. Se verifica ese
  comportamiento en lugar de forzar LM 0.

  Nota SNR: el bitstream de OpusEncCelt no sigue el formato CELT de libopus
  (energía gruesa con ICDF propia en vez de Laplace, sin tf/spread/alloc,
  mapeo de bins distinto), así que el decoder fiel lo lee sin error pero el
  audio no se parece a la entrada. La SNR se imprime y solo se exige que la
  salida sea finita; cuando exista el port de celt_encoder.c hay que exigir
  una SNR mínima aquí.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  SysUtils, Math,
  AudioTypes,
  OpusTypes,
  OpusDecoder,
  OpusEncPacket;

var
  Passed, Failed: Integer;

procedure Check(Cond: Boolean; const Name: string);
begin
  if Cond then begin WriteLn('  PASS: ', Name); Inc(Passed); end
  else         begin WriteLn('  FAIL: ', Name); Inc(Failed); end;
end;

// SNR (dB) entre Ref y Dec buscando el mejor retardo en [0, MaxLag]
// sobre la ventana [Skip, Skip+Len) de Ref.
function BestSNR(const Ref, Dec: TArray<Single>; Skip, Len, MaxLag: Integer;
  out BestLag: Integer): Double;
var
  Lag, I: Integer;
  Sig, Err, D, S: Double;
begin
  Result := -1000;
  BestLag := -1;
  for Lag := 0 to MaxLag do
  begin
    if Skip + Lag + Len > Length(Dec) then Break;
    Sig := 0; Err := 0;
    for I := Skip to Skip + Len - 1 do
    begin
      D := Ref[I] - Dec[I + Lag];
      Sig := Sig + Sqr(Ref[I]);
      Err := Err + Sqr(D);
    end;
    if Err < 1e-30 then S := 200 else S := 10 * Log10(Sig / Err);
    if S > Result then begin Result := S; BestLag := Lag; end;
  end;
end;

procedure TestFrameSize(Ms, ExpFrame, ExpConfig: Integer);
const
  NFRAMES = 25;
  FREQ    = 440.0;
  AMP     = 0.5;
var
  Enc      : TOpusCeltEncoder;
  Dec      : TOpusStreamDecoder;
  PCM      : TArray<SmallInt>;
  Pkt      : array[0..OPUS_MAX_PACKET - 1] of Byte;
  Ref, Got : TArray<Single>;
  Output   : TAudioBuffer;
  MaxLen, Len, N, F, I, Lag: Integer;
  TOC      : TOpusTOC;
  ConfigOK, CountOK, LenOK, Finite: Boolean;
  SNR      : Double;
begin
  WriteLn(Format('FS %d ms: config esperado %d, %d muestras/trama', [Ms, ExpConfig, ExpFrame]));

  Enc := TOpusCeltEncoder.Create(1, 48000, Ms);
  Dec := TOpusStreamDecoder.Create(1);
  try
    Check(Enc.FrameSize = ExpFrame, Format('Encoder.FrameSize = %d (got %d)', [ExpFrame, Enc.FrameSize]));
    Check(Enc.Config = ExpConfig,   Format('Encoder.Config = %d (got %d)', [ExpConfig, Enc.Config]));

    // ~64 kbit/s: 8 bytes por ms + TOC
    MaxLen := 1 + 8 * Ms;
    SetLength(PCM, ExpFrame);
    SetLength(Ref, NFRAMES * ExpFrame);
    SetLength(Got, 0);
    ConfigOK := True; CountOK := True; LenOK := True; Finite := True;

    for F := 0 to NFRAMES - 1 do
    begin
      for I := 0 to ExpFrame - 1 do
      begin
        Ref[F * ExpFrame + I] := AMP * Sin(2 * Pi * FREQ * (F * ExpFrame + I) / 48000);
        PCM[I] := Round(32767 * Ref[F * ExpFrame + I]);
      end;

      FillChar(Pkt, SizeOf(Pkt), 0);
      Len := Enc.EncodeFrame(@PCM[0], @Pkt[0], MaxLen);
      if (Len < 2) or (Len > MaxLen) then
      begin
        LenOK := False;
        Continue;
      end;

      OpusParseTOC(Pkt[0], TOC);
      if (TOC.Config <> ExpConfig) or (Pkt[0] shr 3 <> ExpConfig) or TOC.Stereo or
         (TOC.Code <> 0) or (TOC.Mode <> OPUS_MODE_CELT) or
         (TOC.Bandwidth <> OPUS_BW_FULLBAND) or (TOC.FrameSamples <> ExpFrame) then
      begin
        if ConfigOK then
          WriteLn(Format('    trama %d: TOC $%.2x config %d bw %d frame %d',
            [F, Pkt[0], TOC.Config, TOC.Bandwidth, TOC.FrameSamples]));
        ConfigOK := False;
      end;

      N := Dec.DecodePacket(@Pkt[0], Len, Output);
      if N <> ExpFrame then
      begin
        if CountOK then
          WriteLn(Format('    trama %d: DecodePacket = %d', [F, N]));
        CountOK := False;
      end;
      if N > 0 then
      begin
        var Base := Length(Got);
        SetLength(Got, Base + N);
        for I := 0 to N - 1 do
        begin
          Got[Base + I] := Output[0][I];
          if IsNan(Output[0][I]) or IsInfinite(Output[0][I]) then Finite := False;
        end;
      end;
    end;

    Check(LenOK,    Format('%d paquetes de 2..%d bytes', [NFRAMES, MaxLen]));
    Check(ConfigOK, Format('TOC: config %d (CELT FB %d ms), mono, code 0, %d muestras', [ExpConfig, Ms, ExpFrame]));
    Check(CountOK,  Format('DecodePacket devuelve %d muestras por paquete', [ExpFrame]));
    Check(Length(Got) = NFRAMES * ExpFrame, Format('Total decodificado = %d (got %d)', [NFRAMES * ExpFrame, Length(Got)]));
    Check(Finite,   'Salida decodificada finita');

    // SNR informativa: salta 4 tramas de arranque, busca retardo hasta 2 tramas
    if Length(Got) = NFRAMES * ExpFrame then
    begin
      SNR := BestSNR(Ref, Got, 4 * ExpFrame, (NFRAMES - 7) * ExpFrame, 2 * ExpFrame, Lag);
      WriteLn(Format('    INFO: SNR seno 440 Hz = %.2f dB (retardo %d) -- no se exige, ver nota', [SNR, Lag]));
    end;
  finally
    Dec.Free;
    Enc.Free;
  end;
end;

procedure TestNoTwoPointFive;
var
  Enc: TOpusCeltEncoder;
  Ms : Integer;
begin
  WriteLn('FS 2,5 ms: no seleccionable con FrameSizeMs entero');
  for Ms in [2, 3] do
  begin
    Enc := TOpusCeltEncoder.Create(1, 48000, Ms);
    try
      Check((Enc.LM = 3) and (Enc.FrameSize = 960) and (Enc.Config = 31),
        Format('Create(FrameSizeMs=%d) cae a 20 ms: LM %d, %d muestras, config %d',
          [Ms, Enc.LM, Enc.FrameSize, Enc.Config]));
    finally
      Enc.Free;
    end;
  end;
end;

begin
  Passed := 0; Failed := 0;
  WriteLn('=== Opus Encoder - TOC config y duracion por tamano de trama ===');
  WriteLn;

  TestFrameSize( 5, 240, 29);
  TestFrameSize(10, 480, 30);
  TestFrameSize(20, 960, 31);
  TestNoTwoPointFive;

  WriteLn;
  WriteLn(Format('Results: %d passed, %d failed', [Passed, Failed]));
  if Failed > 0 then Halt(1);
end.
