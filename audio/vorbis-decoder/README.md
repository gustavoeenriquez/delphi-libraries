# vorbis-decoder — Decoder Ogg Vorbis I en Delphi puro

Decodificador completo de Vorbis I (especificación Xiph) sin dependencias externas.
Referencia de implementación: `stb_vorbis.c` (dominio público). Licencia: CC0 1.0.

## Estado (validado 2026-10-13)

Reescrito por completo el 2026-10-13 tras comprobar que la versión anterior no
decodificaba ningún archivo real (sus tests eran sintéticos). Ahora:

| Prueba contra ffmpeg (libvorbis) | Resultado |
|---|---|
| Voz estéreo 48 kHz q5 | SNR 103.6 dB, conteo de muestras exacto |
| Tono 440 Hz mono 44.1 kHz | SNR 103.2 dB |
| Mono 8 kHz q-1 (residuos tipo 0/1, bloques cortos) | SNR 104.6 dB |
| Estéreo 44.1 kHz q10 | SNR 105.0 dB |
| 5.1 canales (acoplamiento múltiple) | SNR 99.7 dB |
| 30 s estéreo (rendimiento, Debug) | 4.4 s, SNR 99.6 dB |

No soportado: floor tipo 0 (obsoleto, ningún codificador lo usa).

## Unidades

| Unidad | Contenido |
|---|---|
| `VorbisTypes` | Records de setup, codebooks, floor, residuos, mapeos; `ilog`, `float32_unpack`, `lookup1_values` |
| `VorbisSetup` | Parseo de las tres cabeceras (identification, comment, setup) |
| `VorbisCodebook` | Asignación de codewords (spec 3.2.1, primera hoja libre), decodificación con tabla rápida + búsqueda binaria, vectores VQ |
| `VorbisFloor` | Floor 1: decodificación (7.2.3), síntesis de amplitudes (7.2.4), render con `floor1_inverse_dB_table` (`VorbisInverseDb.inc`) |
| `VorbisResidue` | Residuos formato 0, 1 y 2 (8.6) con el orden de lectura por pases |
| `VorbisDecoder` | Ventanas, IMDCT (DCT-IV vía FFT N/4), acoplamiento, overlap-add y `TVorbisDecoder` |

El adaptador Ogg está en `audio-codec` (`TVorbisOggAdapter`), que además recorta el final
según la granule position de la página EOS.

## Uso

```pascal
Dec := CreateAudioDecoderFromFile('musica.ogg');
while Dec.Decode(Buf) = adrOK do Procesar(Buf);
```

## Tests y muestras

`tests/src/VorbisDecoderTests.dpr` (142 tests): helpers, codebooks (incluido el ejemplo de
la especificación), IMDCT contra la fórmula directa, ventana, acoplamiento, cabeceras,
y decodificación de las muestras reales de `samples/` con valores de referencia de ffmpeg.
