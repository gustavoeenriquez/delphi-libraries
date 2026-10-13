# AudioProbe — validación de codecs contra ffmpeg

Decodifica cualquier archivo soportado por `audio-codec` (API unificada) y lo escribe a WAV PCM16.
`compare.py` alinea dos WAV por correlación y calcula SNR.

```
AudioProbe.exe entrada.ogg salida.wav
ffmpeg -y -i entrada.ogg -c:a pcm_s16le ref.wav
python compare.py salida.wav ref.wav      # requiere numpy
```

Criterio: lossless → bit-exacto; lossy → corr > 0.99 y SNR > 30 dB.
Muestras reales en `*/samples/` de cada codec (generadas con ffmpeg: libvorbis q5, libopus lowdelay/voip, flac).

Compilar: MSBuild sobre `AudioProbe.dproj` (Win64 Debug), rutas relativas a `audio/`.
