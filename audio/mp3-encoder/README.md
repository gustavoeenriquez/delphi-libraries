# mp3-encoder — Codificador MP3 (MPEG-1 Layer III) en Delphi puro

Codificador CBR mono / estéreo / joint-stereo (MS) con conmutación de ventana
(bloques cortos) sin dependencias externas. Licencia CC0 1.0. Referencias: norma
ISO 11172-3 (y dist10, Shine); LAME solo como referencia de comparación.

## Conmutación de ventana y pre-eco (2026-10-20)

Los gránulos con ataques se codifican con bloques cortos (3 MDCT de 12 puntos) y
ventanas de transición start/stop, según ISO 11172-3 §2.4.2.7 y Anexo C. Pre-eco
medido como ruido en dBFS en los 25–7 ms previos a cada ataque (decodificado con
ffmpeg; menor es mejor; LAME 3.100 como referencia):

| Señal | kbps | sin bloques cortos | con conmutación | LAME |
|---|---:|---:|---:|---:|
| castañuelas (ráfagas sobre silencio) | 64 | −50.7 | **−74.5** | −72.5 |
| castañuelas | 128 | −50.9 | **−72.9** | −75.5 |
| batería sobre acorde, mono (peor golpe) | 128 | −46.5 | **−69.4** | −54.4 |
| batería sobre acorde, estéreo (peor golpe) | 128 | −44.5 | **−67.6** | −51.4 |

En música y voz reales los bloques cortos se activan en 1.7–7 % de los gránulos
(LAME: 0.1–3.5 %).

## Corrección del joint stereo (2026-10-20)

Los umbrales de M/S se calculaban sobre M y S y se usaba el **mayor** para ambos:
el canal S, más débil, recibía el umbral de M y quedaba descartado (imagen estéreo
estrechada; en música estéreo real la SNR por canal era 9 dB). Ahora el modelo se
calcula sobre L/R y M y S usan el **mínimo** de los umbrales de L, R y su propio
umbral (el ruido de M y S se suma en L y en R), y el modo automático elige M/S solo
si el modelo estima menos bits que para L/R. Música estéreo real a 128 kbps: SNR
9.2 → 17.1 dB (LAME 19.5).

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

Limitaciones: solo MPEG-1 (32/44.1/48 kHz), sin VBR, sin intensity stereo,
sin bloques mixtos. Partición psicoacústica = bandas de scalefactor (22 largas,
13 × 3 cortas; no usa FFT independiente).

## Pipeline

| Unidad | Contenido |
|---|---|
| `MP3EncPolyphase` | Banco de análisis polifásico ISO (32 subbandas) |
| `MP3EncMDCT` | MDCT 36→18 para ventanas normal/start/stop y 3 × 12→6 para bloques cortos, escala 1/(N/4) (inversa exacta de la IMDCT ISO), butterflies antialias (solo bloques largos) |
| `MP3EncPsy` | Modelo psicoacústico sobre las líneas MDCT: energía por banda, spreading (Schroeder, Bark), tonalidad (SFM), minval, ATH; versión de bloques cortos por ventana; devuelve ruido permitido por línea y estimación de bits |
| `MP3EncLoop` | Bucle interno (búsqueda binaria de global_gain) + externo (scalefactors por banda, scalefac_scale, preflag, scalefac_compress); criterio de LAME (suma de excesos²); fase de ahorro de bits; variante de bloques cortos con subblock_gain |
| `MP3EncQuantize` | Fórmulas ISO de cuantización/decuantización, tablas de bandas |
| `MP3EncHuffman` / `MP3EncRateCtrl` | Tablas Huffman, big_values/count1/rzero (Shine), elección rápida de tabla por máximo de región |
| `MP3EncFrame` / `MP3EncBitWriter` | Cabecera, side info, scalefactors, datos Huffman |
| `MP3EncEncoder` | `TMP3Encoder`: análisis con un gránulo de anticipación, detector de ataques y secuencia de ventanas, MS espectral (automático por frame según la estimación de bits), asignación de bits entre gránulos/canales, reservorio (main_data_begin ≤ 511 B), paso bajo por tasa (tabla LAME), cola de emisión |
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

`EncSetLowpass(Enc, Hz)` cambia el paso bajo (0 = ninguno).
`EncSetWindowSwitching(Enc, Modo)`: 0 = automático (por defecto), 1 = solo bloques
largos, 2 = solo bloques cortos (pruebas); `EncDefaultWindowSwitching` fija el modo
de los encoders nuevos. El retardo del codificador es `ENC_DELAY` = 1104 muestras
(528 del análisis + un gránulo de anticipación para decidir las ventanas);
`EncodeWAVStream*` añaden un frame de silencio final y la cabecera LAME lo declara,
así que los decodificadores gapless (ffmpeg, LAME) recuperan la duración exacta.

## Tests

`tests/src/TestMP3EncPhase1..20.dpr` (un programa por fase, 856 checks; la 19
cubre el modelo psicoacústico, el bucle, el reservorio, MS automático y round trips
decodificados con `mp3-decoder`; la 20, bloques cortos (round trips solo cortos y
automáticos, secuencia legal de ventanas, pre-eco frente a solo bloques largos,
bucle corto) y la conservación del canal S en M/S). `../mp3-roundtrip` decodifica cualquier MP3
con `audio-codec` y lo vuelve a codificar.

## Historia de los errores corregidos (2026-10-13)

- MDCT sin el factor 1/(N/4): líneas 9× demasiado grandes → salida saturada.
- Cuantizador con |xr|^0.75/step en vez de (|xr|/step)^0.75; PCM sin normalizar.
- Elección de tabla Huffman ignorando linbits; códigos > 32 bits truncados.
- Control de tasa contaba 0 bits para valores incodificables → global_gain 0 y
  gránulos vacíos (silencio a partir del segundo frame).
- A 32 kbps el criterio "menos bandas por encima" (dist10) elegía soluciones
  con SNR ≈ 0 dB; sustituido por la suma de excesos al cuadrado (LAME).
