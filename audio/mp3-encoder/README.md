# mp3-encoder — Codificador MP3 (MPEG-1 Layer III) en Delphi puro

Codificador CBR mono / estéreo / joint-stereo (MS) sin dependencias externas.
Licencia CC0 1.0. Referencias de estructura: ISO 11172-3 dist10, Shine, LAME.

## Estado (validado 2026-10-13)

Funcional. Reescrito el núcleo el 2026-10-13 tras corregir los errores que lo
dejaban "no funcional" (escala del MDCT, cuantizador, Huffman, control de tasa)
y añadir modelo psicoacústico, bucle de conformado de ruido, reservorio de bits
y MS automático.

Medidas con voz de 4 s (48 kHz), decodificando con ffmpeg y comparando con el
original (SNR en dB; LAME 3.100 vía ffmpeg como referencia):

| Caso | mp3-encoder | LAME |
|---|---:|---:|
| mono 32 kbps | 14.8 | 13.8 |
| mono 64 kbps | 19.9 | 19.5 |
| mono 128 kbps | 41.9 | 39.1 |
| mono 320 kbps | 67.3 | — |
| estéreo (L≈R) 64 kbps, MS automático | 19.2 | 18.2 (joint) |
| estéreo (L≈R) 128 kbps, MS automático | 40.6 | 37.3 (joint) |

Los archivos los decodifican sin errores ffmpeg y `mp3-decoder` (idénticos entre
sí a 93 dB). La SNR no mide calidad perceptual; el modelo psicoacústico reparte
el ruido bajo el umbral de enmascaramiento, como LAME.

Limitaciones: solo MPEG-1 (32/44.1/48 kHz), solo bloques largos (sin
conmutación de ventana: puede haber pre-eco en transitorios fuertes), sin VBR,
sin intensity stereo. Partición psicoacústica = 22 bandas de scalefactor (no
usa FFT independiente).

## Pipeline

| Unidad | Contenido |
|---|---|
| `MP3EncPolyphase` | Banco de análisis polifásico ISO (32 subbandas) |
| `MP3EncMDCT` | MDCT 36→18 con ventana seno, escala 1/9 (inversa exacta de la IMDCT ISO), butterflies antialias |
| `MP3EncPsy` | Modelo psicoacústico sobre las líneas MDCT: energía por banda, spreading (Schroeder, Bark), tonalidad (SFM), minval, ATH; devuelve ruido permitido por línea y estimación de bits |
| `MP3EncLoop` | Bucle interno (búsqueda binaria de global_gain) + externo (scalefactors por banda, scalefac_scale, preflag, scalefac_compress); criterio de LAME (suma de excesos²); fase de ahorro de bits |
| `MP3EncQuantize` | Fórmulas ISO de cuantización/decuantización, tablas de bandas |
| `MP3EncHuffman` / `MP3EncRateCtrl` | Tablas Huffman, big_values/count1/rzero (Shine), elección rápida de tabla por máximo de región |
| `MP3EncFrame` / `MP3EncBitWriter` | Cabecera, side info, scalefactors, datos Huffman |
| `MP3EncEncoder` | `TMP3Encoder`: análisis, MS espectral (automático por frame), asignación de bits entre gránulos/canales, reservorio (main_data_begin ≤ 511 B), paso bajo por tasa (tabla LAME), cola de emisión |
| `MP3EncWAV` / `MP3EncFile` | WAV → MP3 (streams y archivos), etiquetas ID3v1/ID3v2, cabecera Xing/LAME gapless (delay 528) |
| `MP3EncXing`, `MP3EncID3`, `MP3EncID3v2`, `MP3EncProbe` | Info frame, etiquetas, sondeo de archivos |

## Uso

```pascal
// Archivo WAV -> MP3 con cabecera LAME (gapless), 128 kbps
EncodeWAVFile('voz.wav', 'voz.mp3', 9, 0);         // MP3EncFile; BrIdx 9 = 128 kbps

// Por frames (1152 muestras por canal, escala ±32768)
EncInitStereo(Enc, Cfg);            // Cfg.SrIdx: 0=44.1k 1=48k 2=32k; Cfg.BrIdx 1..14
EncEnableReservoir(Enc, True);      // opcional; sin él cada llamada devuelve un frame
repeat
  Bytes := EncodeFrameAuto(Enc, L, R);   // MS o L/R según la señal; EncodeFrame para mono
  if Length(Bytes) > 0 then Salida.Write(Bytes[0], Length(Bytes));
until Fin;
Bytes := EncFlush(Enc);             // frames retenidos por el reservorio
```

`EncSetLowpass(Enc, Hz)` cambia el paso bajo (0 = ninguno). El retardo del
codificador es `ENC_DELAY` = 528 muestras; `EncodeWAVStream*` añaden un frame
de silencio final y la cabecera LAME lo declara, así que los decodificadores
gapless (ffmpeg, LAME) recuperan la duración exacta.

## Tests

`tests/src/TestMP3EncPhase1..19.dpr` (un programa por fase; la 19 cubre el
modelo psicoacústico, el bucle, el reservorio, MS automático y round trips
decodificados con `mp3-decoder`). `../mp3-roundtrip` decodifica cualquier MP3
con `audio-codec` y lo vuelve a codificar.

## Historia de los errores corregidos (2026-10-13)

- MDCT sin el factor 1/(N/4): líneas 9× demasiado grandes → salida saturada.
- Cuantizador con |xr|^0.75/step en vez de (|xr|/step)^0.75; PCM sin normalizar.
- Elección de tabla Huffman ignorando linbits; códigos > 32 bits truncados.
- Control de tasa contaba 0 bits para valores incodificables → global_gain 0 y
  gránulos vacíos (silencio a partir del segundo frame).
- A 32 kbps el criterio "menos bandas por encima" (dist10) elegía soluciones
  con SNR ≈ 0 dB; sustituido por la suma de excesos al cuadrado (LAME).
