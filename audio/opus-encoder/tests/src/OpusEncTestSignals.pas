unit OpusEncTestSignals;

{
  OpusEncTestSignals.pas - Señales de prueba deterministas (solo aritmética entera)

  Generan exactamente el mismo PCM en cualquier plataforma (no usan Sin/Cos
  de la RTL), para poder fijar vectores de referencia de libopus en los tests.

  Licencia de las pruebas: CC0 1.0 (las pruebas no derivan de libopus).
}

{$Q-}{$R-}

interface

type
  TTestSignal = (tsChirp, tsMusicLike, tsSpeechLike);

// PCM int16 intercalado: Samples muestras por canal
function MakeTestSignal(Kind: TTestSignal; SampleRate, Channels, Samples: Integer): TArray<SmallInt>;

implementation

// Triangle wave from a 32-bit phase accumulator: amplitude +-32767
function Tri(Phase: Cardinal): Integer; inline;
var
  P: Integer;
begin
  P := Integer(Phase shr 16);           // 0..65535
  if P < 32768 then Result := P - 16384 else Result := 49151 - P;
  Result := Result * 2;                 // -32768..32766
end;

function MakeTestSignal(Kind: TTestSignal; SampleRate, Channels, Samples: Integer): TArray<SmallInt>;
var
  N, C, V, Env: Integer;
  Ph: array[0..3] of Cardinal;
  Inc0, Inc1, Inc2, Inc3: Cardinal;
  Seed: Cardinal;
  Noise, Lp: Integer;
begin
  SetLength(Result, Samples * Channels);
  FillChar(Ph, SizeOf(Ph), 0);
  Seed := 12345;
  Lp := 0;
  for N := 0 to Samples - 1 do
  begin
    Seed := Seed * 1664525 + 1013904223;
    Noise := Integer(Seed shr 17) - 16384;           // +-16384
    case Kind of
      tsChirp:
        begin
          // 100 Hz .. ~SampleRate/2.5 linear sweep over the signal
          Inc0 := Cardinal((Int64(100) + Int64(N) * (SampleRate div 3) div Samples) * 4294967 div (SampleRate div 1000));
          Inc(Ph[0], Inc0);
          V := Tri(Ph[0]) div 3 + Noise div 64;
        end;
      tsMusicLike:
        begin
          // three "notes" + bass, slowly changing, plus a little noise
          Inc0 := Cardinal(Int64(220 + (N div 4800) mod 5 * 55) * 4294967 div (SampleRate div 1000));
          Inc1 := Cardinal(Int64(330 + (N div 7200) mod 4 * 41) * 4294967 div (SampleRate div 1000));
          Inc2 := Cardinal(Int64(55 + (N div 9600) mod 3 * 7) * 4294967 div (SampleRate div 1000));
          Inc3 := Cardinal(Int64(1760) * 4294967 div (SampleRate div 1000));
          Inc(Ph[0], Inc0); Inc(Ph[1], Inc1); Inc(Ph[2], Inc2); Inc(Ph[3], Inc3);
          Env := (N mod 4800) * 8 div 4800;              // decaying "pluck" envelope 0..7
          V := Tri(Ph[0]) div 6 + Tri(Ph[1]) div 8 + Tri(Ph[2]) div 5 +
               Tri(Ph[3]) * (8 - Env) div 160 + Noise div 128;
        end;
    else
      begin
        // speech-like: pitch-varying pulse train through a crude resonator,
        // voiced/unvoiced segments of ~120 ms
        Inc0 := Cardinal(Int64(110 + (N div 960) mod 7 * 9) * 4294967 div (SampleRate div 1000));
        Inc(Ph[0], Inc0);
        if ((N * 1000 div SampleRate) div 120) mod 3 = 2 then
          V := Noise div 3                                // unvoiced
        else
        begin
          if Ph[0] < Inc0 then V := 24000 else V := 0;   // glottal pulse
        end;
        Lp := Lp + (V - Lp) div 3;                       // resonance-ish smoothing
        V := Lp + Tri(Ph[0] * 7) div 12;
      end;
    end;
    if V > 32767 then V := 32767;
    if V < -32768 then V := -32768;
    for C := 0 to Channels - 1 do
    begin
      if C = 0 then
        Result[N * Channels] := V
      else
        Result[N * Channels + C] := (V * 3 + Noise div 8) div 4;   // correlated right channel
    end;
  end;
end;

end.
