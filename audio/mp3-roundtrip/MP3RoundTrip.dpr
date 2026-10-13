program MP3RoundTrip;

(*
  MP3RoundTrip — consola demo de decodificación y re-codificación de MP3

  Flujo:
    1. Lee un archivo MP3 y muestra su información (MP3EncProbe)
    2. Decodifica MP3 -> WAV con la API unificada de audio-codec
       (mp3-decoder: TMP3StreamDecoder, bit reservoir incluido)
    3. Re-codifica WAV -> MP3 con mp3-encoder (EncodeWAVStreamLame:
       psicoacústica, reservorio, MS automático, cabecera LAME gapless)
    4. Deja los tres archivos en el mismo directorio para comparación

  Uso:
    MP3RoundTrip.exe <archivo.mp3> [kbps]
    (sin argumento: se pide la ruta interactivamente; kbps por defecto = el del original)
*)

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Classes,
  AudioTypes,
  WAVWriter,
  AudioCodec,
  MP3EncProbe,
  MP3EncID3v2,
  MP3EncXing,
  MP3EncEncoder,
  MP3EncWAV;

function FmtBytes(N: Int64): string;
begin
  if N >= 1048576 then Result := Format('%.1f MB', [N / 1048576.0])
  else if N >= 1024  then Result := Format('%.0f KB', [N / 1024.0])
  else                    Result := Format('%d B', [N]);
end;

function FmtDur(AMs: Cardinal): string;
var
  S, M, H: Integer;
begin
  S := Integer(AMs) div 1000;
  H := S div 3600; S := S - H * 3600;
  M := S div 60;   S := S mod 60;
  if H > 0 then Result := Format('%d:%02d:%02d', [H, M, S])
  else           Result := Format('%d:%02d', [M, S]);
end;

function BitrateToIdx(AKbps: Integer): Byte;
const
  BR: array[1..14] of Integer =
    (32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320);
var
  i: Integer;
begin
  for i := 1 to 14 do
    if BR[i] = AKbps then Exit(i);
  Result := 9;  { 128 kbps }
end;

function ChanStr(ACh: Integer): string;
begin
  case ACh of
    1: Result := 'Mono';
    2: Result := 'Stereo';
  else
    Result := Format('%d canales', [ACh]);
  end;
end;

// ---------------------------------------------------------------------------
// Paso 1: MP3 -> WAV (decoder unificado; devuelve muestras por canal o -1)
// ---------------------------------------------------------------------------

function DecodeMP3ToWAV(const ASrcMP3, ADstWAV: string; out AInfo: TAudioInfo): Int64;
var
  Dec : IAudioDecoder;
  Enc : IAudioEncoder;
  Buf : TAudioBuffer;
  R   : TAudioDecodeResult;
  Bad : Integer;
begin
  Result := -1;
  Dec := CreateAudioDecoderFromFile(ASrcMP3);
  if Dec = nil then Exit;
  AInfo := Dec.Info;
  Enc := nil;
  Result := 0; Bad := 0;
  repeat
    R := Dec.Decode(Buf);
    case R of
      adrOK: begin
        if Enc = nil then
          Enc := CreateWAVEncoderToFile(ADstWAV, AInfo.SampleRate, Length(Buf), woPCM16);
        Enc.Encode(Buf);
        Inc(Result, AudioBufferFrameCount(Buf));
      end;
      adrCorrupted: begin
        Inc(Bad);
        if Bad > 100 then Break;
      end;
    end;
  until R in [adrEndOfStream, adrError];
  if Enc <> nil then Enc.Finalize;
  if Result = 0 then Result := -1;
end;

// ---------------------------------------------------------------------------
// Paso 2: WAV -> MP3 (con cabecera LAME gapless)
// ---------------------------------------------------------------------------

function ReEncodeWAVToMP3(const ASrcWAV, ADstMP3: string; ABrIdx: Byte): Integer;
var
  WavIn  : TFileStream;
  MP3Out : TMemoryStream;
begin
  WavIn  := TFileStream.Create(ASrcWAV, fmOpenRead or fmShareDenyWrite);
  MP3Out := TMemoryStream.Create;
  try
    Result := EncodeWAVStreamLame(WavIn, MP3Out, ABrIdx, 0);
    if Result > 0 then MP3Out.SaveToFile(ADstMP3);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;
end;

// ---------------------------------------------------------------------------

var
  MP3Path, WavPath, OutMP3, Dir, Base: string;
  Probe   : TMP3ProbeResult;
  ProbeSt : TMemoryStream;
  Info    : TAudioInfo;
  BrIdx   : Byte;
  Kbps    : Integer;
  T0      : TDateTime;
  Samples : Int64;
  FrEnc   : Integer;
  InSz, WavSz, OutSz: Int64;
begin
  try
    WriteLn('=== MP3 Round-Trip Demo ===');
    WriteLn('    Decoder : mp3-decoder (via audio-codec)');
    WriteLn('    Encoder : mp3-encoder (EncodeWAVStreamLame)');
    WriteLn;

    if ParamCount > 0 then
      MP3Path := Trim(ParamStr(1))
    else begin
      Write('Ruta del archivo MP3: ');
      ReadLn(MP3Path);
      MP3Path := Trim(MP3Path);
      if (Length(MP3Path) >= 2) and (MP3Path[1] = '"') then
        MP3Path := Copy(MP3Path, 2, Length(MP3Path) - 2);
    end;
    if not FileExists(MP3Path) then begin
      WriteLn('Archivo no encontrado: ', MP3Path);
      ExitCode := 1;
      Exit;
    end;

    { info del original }
    ProbeSt := TMemoryStream.Create;
    try
      ProbeSt.LoadFromFile(MP3Path);
      InSz := ProbeSt.Size;
      if not MP3ProbeStream(ProbeSt, Probe) then
        Probe := Default(TMP3ProbeResult);
    finally
      ProbeSt.Free;
    end;

    WriteLn('Entrada : ', ExtractFileName(MP3Path), '  (', FmtBytes(InSz), ')');
    if Probe.IsValid then begin
      if Probe.IsVBR then Base := ' VBR' else Base := ' CBR';
      WriteLn(Format('  %d Hz, %s, %d kbps%s', [Probe.SampleRate, ChanStr(Probe.Channels),
        Probe.BitRateKbps, Base]));
      if Probe.DurationMs > 0 then WriteLn('  Duracion : ', FmtDur(Probe.DurationMs));
      if Probe.HasID3v2 and (Probe.TagV2.Title <> '') then
        WriteLn('  Titulo   : ', Probe.TagV2.Title, '  ', Probe.TagV2.Artist);
    end;

    Dir  := IncludeTrailingPathDelimiter(ExtractFilePath(MP3Path));
    Base := ChangeFileExt(ExtractFileName(MP3Path), '');
    WavPath := Dir + Base + '_decoded.wav';
    OutMP3  := Dir + Base + '_roundtrip.mp3';

    { 1. decodificar }
    Write('Decodificando ... ');
    T0 := Now;
    Samples := DecodeMP3ToWAV(MP3Path, WavPath, Info);
    if Samples < 0 then begin
      WriteLn('ERROR: no se pudo decodificar');
      ExitCode := 2;
      Exit;
    end;
    WavSz := 0;
    with TFileStream.Create(WavPath, fmOpenRead or fmShareDenyWrite) do begin WavSz := Size; Free; end;
    WriteLn(Format('%d muestras, %d Hz, %s -> %s (%s) en %.1f s',
      [Samples, Info.SampleRate, ChanStr(Info.Channels), ExtractFileName(WavPath),
       FmtBytes(WavSz), (Now - T0) * 86400]));

    { 2. re-codificar }
    if ParamCount > 1 then Kbps := StrToIntDef(ParamStr(2), 128)
    else if Probe.IsValid and (Probe.BitRateKbps > 0) then Kbps := Probe.BitRateKbps
    else Kbps := 128;
    BrIdx := BitrateToIdx(Kbps);
    Write('Codificando a ', Kbps, ' kbps ... ');
    T0 := Now;
    FrEnc := ReEncodeWAVToMP3(WavPath, OutMP3, BrIdx);
    if FrEnc <= 0 then begin
      WriteLn('ERROR: no se pudo codificar (frecuencia no soportada?)');
      ExitCode := 3;
      Exit;
    end;
    OutSz := 0;
    with TFileStream.Create(OutMP3, fmOpenRead or fmShareDenyWrite) do begin OutSz := Size; Free; end;
    WriteLn(Format('%d frames -> %s (%s) en %.1f s',
      [FrEnc, ExtractFileName(OutMP3), FmtBytes(OutSz), (Now - T0) * 86400]));
    WriteLn;
    WriteLn('Listo. Compare ', ExtractFileName(MP3Path), ' con ', ExtractFileName(OutMP3));
  except
    on E: Exception do begin
      WriteLn('EXCEPCION: ', E.ClassName, ': ', E.Message);
      ExitCode := 9;
    end;
  end;
end.
