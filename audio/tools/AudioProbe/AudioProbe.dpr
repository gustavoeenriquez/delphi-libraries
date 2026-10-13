program AudioProbe;
{$APPTYPE CONSOLE}
uses
  SysUtils, Classes, AudioTypes, AudioCodec, WAVWriter;
var
  Dec: IAudioDecoder; Enc: IAudioEncoder; Buf: TAudioBuffer; R: TAudioDecodeResult;
  Info: TAudioInfo; Frames: Int64; Blocks, Bad: Integer;
begin
  ExitCode := 0;
  try
    Dec := CreateAudioDecoderFromFile(ParamStr(1));
    if Dec = nil then begin WriteLn('ERROR: formato no soportado o archivo invalido'); ExitCode := 2; Exit; end;
    Info := Dec.Info;
    WriteLn('Info: ', Info.SampleRate, ' Hz, ', Info.Channels, ' ch');
    Enc := nil;
    Frames := 0; Blocks := 0; Bad := 0;
    repeat
      R := Dec.Decode(Buf);
      case R of
        adrOK: begin if Enc = nil then Enc := CreateWAVEncoderToFile(ParamStr(2), Info.SampleRate, Length(Buf), woPCM16); Enc.Encode(Buf); Inc(Frames, AudioBufferFrameCount(Buf)); Inc(Blocks); end;
        adrCorrupted: begin Inc(Bad); if Bad > 50 then Break; end;
      end;
    until R in [adrEndOfStream, adrError];
    if Enc <> nil then Enc.Finalize;
    WriteLn('Result: ', Ord(R), ' blocks=', Blocks, ' frames=', Frames, ' corrupted=', Bad);
    if R = adrError then ExitCode := 3;
  except
    on E: Exception do begin WriteLn('EXCEPTION: ', E.ClassName, ': ', E.Message); ExitCode := 4; end;
  end;
end.
