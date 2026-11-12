program Mp3Enc;

{
  Mp3Enc — WAV (PCM 16 bits, 32/44.1/48 kHz) -> MP3 con mp3-encoder.

    Mp3Enc entrada.wav salida.mp3 --cbr 128     CBR con cabecera LAME (gapless)
    Mp3Enc entrada.wav salida.mp3 --vbr 2       VBR, calidad 0 (mejor) .. 9
    Mp3Enc entrada.wav salida.mp3 --abr 160     ABR, media en kbps (32..320)

  Pensado para evaluar el encoder (PEAQ, comparación con LAME): ver
  audio/tools/peaq.
}

{$APPTYPE CONSOLE}

uses
  SysUtils, MP3EncFile;

const
  KBPS: array[1..14] of Integer = (32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320);

function KbpsToBrIdx(AKbps: Integer): Integer;
var
  i: Integer;
begin
  for i := 1 to 14 do
    if KBPS[i] = AKbps then Exit(i);
  Result := -1;
end;

procedure Usage;
begin
  WriteLn('Uso: Mp3Enc entrada.wav salida.mp3 (--cbr KBPS | --vbr 0..9 | --abr KBPS)');
  Halt(2);
end;

var
  Mode: string;
  Value, Frames, BrIdx: Integer;
  T0: TDateTime;
begin
  if ParamCount <> 4 then Usage;
  Mode := LowerCase(ParamStr(3));
  Value := StrToIntDef(ParamStr(4), -1);
  T0 := Now;
  if Mode = '--cbr' then begin
    BrIdx := KbpsToBrIdx(Value);
    if BrIdx < 0 then begin WriteLn('Bitrate CBR no valido: ', Value); Halt(2); end;
    Frames := EncodeWAVFile(ParamStr(1), ParamStr(2), BrIdx, 0);
  end else if Mode = '--vbr' then begin
    if (Value < 0) or (Value > 9) then Usage;
    Frames := EncodeWAVFileVBR(ParamStr(1), ParamStr(2), Value);
  end else if Mode = '--abr' then begin
    if (Value < 32) or (Value > 320) then Usage;
    Frames := EncodeWAVFileABR(ParamStr(1), ParamStr(2), Value);
  end else begin
    Usage;
    Frames := -1;
  end;
  if Frames < 0 then begin
    WriteLn('ERROR: no se pudo codificar ', ParamStr(1));
    Halt(1);
  end;
  WriteLn(Format('%s: %d frames en %.1f s', [ExtractFileName(ParamStr(2)), Frames,
    (Now - T0) * 86400]));
end.
