program OpusEncTool;

{
  OpusEncTool.dpr - Herramienta de validación del encoder Opus (espejo de opus_oracle.c)

    OpusEncTool encode in.raw out.opk clave=valor...   (mismas claves que opus_oracle)
    OpusEncTool decode in.opk out.raw ch=1              (decoder Delphi, salida 48 kHz s16le)
    OpusEncTool compare a.opk b.opk                     (paquete a paquete)
    OpusEncTool gensig out.raw kind=chirp|music|speech fs=48000 ch=1 n=48000

  El formato .opk es "OPK1" + por paquete: int32 LE longitud, uint32 LE
  final_range, bytes.

  Herramienta de pruebas del repositorio (no forma parte de la librería).
}

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  SysUtils, Classes, Math,
  AudioTypes,
  OpusDecoder,
  OpusEncTypes,
  OpusEncoder,
  OpusEncTestSignals in '..\src\OpusEncTestSignals.pas';

function GetArg(const Key, Def: string): string;
var
  I: Integer;
begin
  for I := 2 to ParamCount do
    if ParamStr(I).StartsWith(Key + '=') then
      Exit(ParamStr(I).Substring(Length(Key) + 1));
  Result := Def;
end;

function BwVal(const S: string): Integer;
begin
  if S = 'nb' then Result := OPUS_BANDWIDTH_NARROWBAND
  else if S = 'mb' then Result := OPUS_BANDWIDTH_MEDIUMBAND
  else if S = 'wb' then Result := OPUS_BANDWIDTH_WIDEBAND
  else if S = 'swb' then Result := OPUS_BANDWIDTH_SUPERWIDEBAND
  else if S = 'fb' then Result := OPUS_BANDWIDTH_FULLBAND
  else Result := OPUS_AUTO;
end;

type
  TOpk = record
    Data : TArray<TBytes>;
    Rng  : TArray<Cardinal>;
  end;

function LoadOpk(const FileName: string): TOpk;
var
  F: TFileStream;
  Magic: array[0..3] of AnsiChar;
  Len: Integer;
  Rng: Cardinal;
  N: Integer;
begin
  F := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    F.ReadBuffer(Magic, 4);
    if Magic <> 'OPK1' then raise Exception.Create('no es OPK1: ' + FileName);
    N := 0;
    while F.Position < F.Size do
    begin
      F.ReadBuffer(Len, 4);
      F.ReadBuffer(Rng, 4);
      SetLength(Result.Data, N + 1);
      SetLength(Result.Rng, N + 1);
      SetLength(Result.Data[N], Len);
      if Len > 0 then F.ReadBuffer(Result.Data[N][0], Len);
      Result.Rng[N] := Rng;
      Inc(N);
    end;
  finally
    F.Free;
  end;
end;

function DoEncode: Integer;
var
  Fs, Ch, App, Frame, Br, Len, N, I: Integer;
  Ms: Double;
  S: string;
  Enc: TOpusEncoder;
  Fi, Fo: TFileStream;
  Pcm: TArray<SmallInt>;
  PcmF: TArray<Single>;
  Pkt: array[0..1499] of Byte;
  Got: Integer;
  Total: Int64;
  UseFloat: Boolean;
  MaxBytes: Integer;
  Rng: Cardinal;
  FS_: TFormatSettings;
  BrCyc: TArray<string>;
  BrPeriod: Integer;
begin
  FS_ := TFormatSettings.Invariant;
  Fs := StrToInt(GetArg('fs', '48000'));
  Ch := StrToInt(GetArg('ch', '1'));
  S := GetArg('app', 'audio');
  if S = 'voip' then App := OPUS_APPLICATION_VOIP
  else if S = 'lowdelay' then App := OPUS_APPLICATION_RESTRICTED_LOWDELAY
  else App := OPUS_APPLICATION_AUDIO;
  Ms := StrToFloat(GetArg('ms', '20'), FS_);
  Frame := Round(Fs * Ms / 1000);
  S := GetArg('br', 'auto');
  if S = 'auto' then Br := OPUS_AUTO
  else if S = 'max' then Br := OPUS_BITRATE_MAX
  else Br := StrToInt(S);
  UseFloat := GetArg('float', '0') = '1';
  MaxBytes := StrToInt(GetArg('maxbytes', '1276'));
  // brcyc=b1,b2,...,N: cycle the bitrate through b1..bk every N frames
  BrCyc := GetArg('brcyc', '').Split([',']);
  BrPeriod := 0;
  if Length(BrCyc) >= 2 then
    BrPeriod := StrToInt(BrCyc[High(BrCyc)]);

  Enc := TOpusEncoder.Create(Fs, Ch, App);
  try
    Enc.Bitrate := Br;
    Enc.Vbr := GetArg('vbr', '1') = '1';
    Enc.VbrConstraint := GetArg('cvbr', '1') = '1';
    Enc.Complexity := StrToInt(GetArg('cx', '10'));
    S := GetArg('mode', 'auto');
    if S = 'celt' then Enc.ForceMode := MODE_CELT_ONLY
    else if S = 'silk' then Enc.ForceMode := MODE_SILK_ONLY
    else if S = 'hybrid' then Enc.ForceMode := MODE_HYBRID
    else Enc.ForceMode := OPUS_AUTO;
    Enc.Bandwidth := BwVal(GetArg('bw', 'auto'));
    Enc.MaxBandwidth := BwVal(GetArg('maxbw', 'fb'));
    Enc.PacketLossPerc := StrToInt(GetArg('loss', '0'));
    Enc.InbandFec := StrToInt(GetArg('fec', '0'));
    Enc.Dtx := GetArg('dtx', '0') = '1';
    S := GetArg('sig', 'auto');
    if S = 'voice' then Enc.Signal := OPUS_SIGNAL_VOICE
    else if S = 'music' then Enc.Signal := OPUS_SIGNAL_MUSIC
    else Enc.Signal := OPUS_AUTO;
    Enc.LsbDepth := StrToInt(GetArg('lsb', '24'));
    Enc.PhaseInversionDisabled := GetArg('pinv', '0') = '1';
    Enc.PredictionDisabled := GetArg('pred', '0') = '1';
    Enc.ExpertFrameDuration := StrToInt(GetArg('efd', '5000'));
    S := GetArg('fch', 'auto');
    if S = 'auto' then Enc.ForceChannels := OPUS_AUTO else Enc.ForceChannels := StrToInt(S);

    Fi := TFileStream.Create(ParamStr(2), fmOpenRead or fmShareDenyWrite);
    Fo := TFileStream.Create(ParamStr(3), fmCreate);
    try
      Fo.WriteBuffer(AnsiString('OPK1')[1], 4);
      SetLength(Pcm, Frame * Ch);
      SetLength(PcmF, Frame * Ch);
      Total := 0;
      N := 0;
      while True do
      begin
        Got := Fi.Read(Pcm[0], Frame * Ch * 2) div (2 * Ch);
        if Got = 0 then Break;
        if Got < Frame then
          FillChar(Pcm[Got * Ch], (Frame - Got) * Ch * 2, 0);
        if (BrPeriod > 0) and (N mod BrPeriod = 0) then
          Enc.Bitrate := StrToInt(BrCyc[(N div BrPeriod) mod (Length(BrCyc) - 1)]);
        if UseFloat then
        begin
          for I := 0 to Frame * Ch - 1 do
            PcmF[I] := Pcm[I] * Single(1.0 / 32768);
          Len := Enc.EncodeFloat(@PcmF[0], Frame, @Pkt[0], MaxBytes);
        end
        else
          Len := Enc.Encode(@Pcm[0], Frame, @Pkt[0], MaxBytes);
        if Len < 0 then
        begin
          WriteLn(ErrOutput, 'encode: ', Len);
          Exit(1);
        end;
        Rng := Enc.FinalRange;
        Fo.WriteBuffer(Len, 4);
        Fo.WriteBuffer(Rng, 4);
        Fo.WriteBuffer(Pkt[0], Len);
        Total := Total + Len;
        Inc(N);
      end;
      if N > 0 then
        WriteLn(ErrOutput, Format('%d paquetes, %d bytes, %.1f kbps', [N, Total, Total * 8.0 / (N * Ms)], FS_));
    finally
      Fi.Free;
      Fo.Free;
    end;
  finally
    Enc.Free;
  end;
  Result := 0;
end;

function DoDecode: Integer;
var
  Opk: TOpk;
  Dec: TOpusStreamDecoder;
  Buf: TAudioBuffer;
  I, J, C, N, Ch, Bad: Integer;
  Fo: TFileStream;
  Out16: TArray<SmallInt>;
  V: Single;
begin
  Opk := LoadOpk(ParamStr(2));
  Ch := StrToInt(GetArg('ch', '1'));
  Dec := TOpusStreamDecoder.Create(Ch);
  Fo := TFileStream.Create(ParamStr(3), fmCreate);
  Bad := 0;
  try
    for I := 0 to High(Opk.Data) do
    begin
      if Length(Opk.Data[I]) = 0 then
        N := Dec.DecodeLost(960, Buf)
      else
        N := Dec.DecodePacket(@Opk.Data[I][0], Length(Opk.Data[I]), Buf);
      if N < 0 then
      begin
        WriteLn(ErrOutput, 'paquete ', I, ': error ', N);
        Inc(Bad);
        Continue;
      end;
      SetLength(Out16, N * Ch);
      for J := 0 to N - 1 do
        for C := 0 to Ch - 1 do
        begin
          V := Buf[Min(C, High(Buf))][J] * 32768;
          if V > 32767 then V := 32767;
          if V < -32768 then V := -32768;
          Out16[J * Ch + C] := Round(V);
        end;
      if N > 0 then
        Fo.WriteBuffer(Out16[0], N * Ch * 2);
    end;
  finally
    Fo.Free;
    Dec.Free;
  end;
  WriteLn(ErrOutput, Length(Opk.Data), ' paquetes decodificados, ', Bad, ' con error');
  if Bad > 0 then Result := 2 else Result := 0;
end;

function DoCompare: Integer;
var
  A, B: TOpk;
  I, N, Same, FirstDiff, SameRng: Integer;
  TotA, TotB: Int64;
begin
  A := LoadOpk(ParamStr(2));
  B := LoadOpk(ParamStr(3));
  N := Min(Length(A.Data), Length(B.Data));
  Same := 0;
  SameRng := 0;
  FirstDiff := -1;
  TotA := 0; TotB := 0;
  for I := 0 to N - 1 do
  begin
    TotA := TotA + Length(A.Data[I]);
    TotB := TotB + Length(B.Data[I]);
    if (Length(A.Data[I]) = Length(B.Data[I])) and
       ((Length(A.Data[I]) = 0) or CompareMem(@A.Data[I][0], @B.Data[I][0], Length(A.Data[I]))) then
      Inc(Same)
    else if FirstDiff < 0 then
      FirstDiff := I;
    if A.Rng[I] = B.Rng[I] then Inc(SameRng);
  end;
  WriteLn(Format('paquetes: %d / %d   idénticos: %d (%.2f %%)   final_range igual: %d   primera diferencia: %d   bytes: %d / %d (%.2f %%)',
    [Length(A.Data), Length(B.Data), Same, 100.0 * Same / Max(1, N), SameRng, FirstDiff, TotA, TotB,
     100.0 * (TotA - TotB) / Max(Int64(1), TotB)]));
  if (Same = N) and (Length(A.Data) = Length(B.Data)) then Result := 0 else Result := 1;
end;

function DoGenSig: Integer;
var
  Kind: TTestSignal;
  S: string;
  Pcm: TArray<SmallInt>;
  F: TFileStream;
begin
  S := GetArg('kind', 'chirp');
  if S = 'music' then Kind := tsMusicLike
  else if S = 'speech' then Kind := tsSpeechLike
  else Kind := tsChirp;
  Pcm := MakeTestSignal(Kind, StrToInt(GetArg('fs', '48000')), StrToInt(GetArg('ch', '1')),
    StrToInt(GetArg('n', '48000')));
  F := TFileStream.Create(ParamStr(2), fmCreate);
  try
    F.WriteBuffer(Pcm[0], Length(Pcm) * 2);
  finally
    F.Free;
  end;
  Result := 0;
end;

begin
  try
    if ParamCount < 2 then
    begin
      WriteLn('uso: OpusEncTool encode|decode|compare ...');
      ExitCode := 1;
    end
    else if ParamStr(1) = 'encode' then ExitCode := DoEncode
    else if ParamStr(1) = 'decode' then ExitCode := DoDecode
    else if ParamStr(1) = 'compare' then ExitCode := DoCompare
    else if ParamStr(1) = 'gensig' then ExitCode := DoGenSig
    else
    begin
      WriteLn('modo desconocido');
      ExitCode := 1;
    end;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 3;
    end;
  end;
end.
