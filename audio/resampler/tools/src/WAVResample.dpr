program WAVResample;

{$APPTYPE CONSOLE}

{
  WAVResample.dpr
  Convierte un archivo WAV a 8000 Hz mono 16-bit PCM (voz telefónica G.711).

  Uso:   WAVResample <entrada.wav> <salida.wav>
  Si se omiten argumentos usa los paths hardcodeados por defecto.
}

uses
  SysUtils, Math,
  AudioTypes,
  AudioResampler,
  WAVReader,
  WAVWriter;

const
  DST_RATE = 8000;

procedure Run(const SrcFile, DstFile: string);
var
  Reader   : TWAVReader;
  Writer   : TWAVWriter;
  Resampler: TAudioResampler;
  Buf      : TAudioBuffer;
  OutBuf   : TAudioBuffer;
  Res      : TAudioDecodeResult;
  SrcRate  : Cardinal;
  Channels : Integer;
  TotalIn  : Int64;
  TotalOut : Int64;
begin
  Reader := TWAVReader.Create;
  try
    if not Reader.Open(SrcFile) then
    begin
      WriteLn('ERROR: no se pudo abrir ', SrcFile);
      Halt(1);
    end;

    SrcRate  := Reader.Format.SampleRate;
    Channels := Reader.Format.Channels;

    WriteLn('Fuente    : ', SrcFile);
    WriteLn(Format('Formato   : %d Hz, %d ch, %d-bit', [SrcRate, Channels, Reader.Format.BitsPerSample]));
    WriteLn(Format('Destino   : %d Hz, %d ch, 16-bit  →  %s', [DST_RATE, Channels, DstFile]));

    if SrcRate = DST_RATE then
    begin
      WriteLn('El archivo ya está a ', DST_RATE, ' Hz; copia directa.');
    end;

    Resampler := TAudioResampler.Create(SrcRate, DST_RATE, Channels, rqHigh);
    Writer    := TWAVWriter.Create(DstFile, DST_RATE, Channels, woPCM16);
    try
      TotalIn  := 0;
      TotalOut := 0;

      repeat
        Res := Reader.Decode(Buf, 4096);
        if (Res = adrOK) and (Length(Buf) > 0) and (Length(Buf[0]) > 0) then
        begin
          Inc(TotalIn, Length(Buf[0]));
          OutBuf := Resampler.Resample(Buf);
          if (Length(OutBuf) > 0) and (Length(OutBuf[0]) > 0) then
          begin
            Writer.WriteSamples(OutBuf);
            Inc(TotalOut, Length(OutBuf[0]));
          end;
        end;
      until Res <> adrOK;

      Writer.Finalize;

      WriteLn(Format('Frames    : %d in  →  %d out', [TotalIn, TotalOut]));
      WriteLn(Format('Duración  : %.2f s  →  %.2f s',
        [TotalIn / SrcRate, TotalOut / DST_RATE]));
      WriteLn('Listo.');
    finally
      Writer.Free;
      Resampler.Free;
    end;
  finally
    Reader.Free;
  end;
end;

var
  Src, Dst: string;
begin
  if ParamCount >= 2 then
  begin
    Src := ParamStr(1);
    Dst := ParamStr(2);
  end
  else
  begin
    Src := 'D:\Taller\Medios\saludo_cariñoso.wav';
    Dst := 'D:\Taller\Medios\saludo_cariñoso_tel.wav';
  end;

  try
    Run(Src, Dst);
  except
    on E: Exception do
    begin
      WriteLn('EXCEPCIÓN: ', E.Message);
      Halt(2);
    end;
  end;
end.
