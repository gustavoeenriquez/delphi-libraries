# mp3-encoder — Codificador MP3 (MPEG-1 Layer III) en Delphi puro

Codificador CBR mono / estéreo / joint-stereo (MS) con conmutación de ventana
(bloques cortos) sin dependencias externas. Licencia CC0 1.0. Referencias: norma
ISO 11172-3 (y dist10, Shine); LAME solo como referencia de comparación.

## Calidad perceptual (PEAQ, 2026-10-20)

ODG de PEAQ básico (GstPEAQ; 0 = transparente, −4 = muy molesto) sobre cinco piezas
de 4–30 s a 44,1 kHz (dos músicas estéreo, voz, batería estéreo, castañuelas),
decodificando con ffmpeg y remuestreando a 48 kHz. Media de las cinco:

| CBR | antes de las correcciones | correcciones | + regiones Huffman | + reparto de bits | + M/S (defecto) | LAME 3.100 |
|---|---:|---:|---:|---:|---:|---:|
| 96 kbps | — | −1.62 | −1.59 | −1.49 | **−1.30** | −1.32 |
| 128 kbps | −1.35 | −1.03 | −1.00 | −0.90 | **−0.76** | −0.76 |
| 192 kbps | — | −0.40 | −0.38 | −0.28 | **−0.18** | −0.13 |

(El modelo FFT opcional da −1.59 / −1.02 / −0.38 sin las dos últimas mejoras.)

Regiones Huffman: en bloques largos `region0_count`/`region1_count` se eligen por
gránulo (la división más barata de las 125 que admite la side info, con la mejor
tabla en cada región) en vez de 10/3 fijos: −1.9 % de bits Huffman, que el bucle
convierte en menos ruido (la música gana 0.03–0.1; VBR, la misma calidad con
1.5–2 % menos de bits). La búsqueda binaria de global_gain cuenta con la división
fija y solo los últimos pasos con la óptima: codificar es unas 2 veces más lento
(30 s de estéreo a 128 kbps en ~3 s).

Reparto de bits entre gránulos: la demanda que estima el modelo psicoacústico
(0.5 log2(E/xmin) por línea) no cuenta el coste del Huffman ni de los
scalefactors; medido en modo calidad, los bits codificados son ~2.5 veces la
estimación en bloques largos y 3–8 veces en cortos. Escalada así (×2.5 y ×4), los
gránulos con transitorios piden al reservorio lo que de verdad necesitan: la
batería pasa de −0.82 a −0.33 a 128 kbps (LAME −0.14) y la media mejora 0.1 en los
tres bitrates. VBR no cambia (cuantiza al umbral sin reparto).

M/S: el modo automático usaba M/S solo si S era débil (E(S) ≤ 0.3 E(M)) y el modelo
estimaba menos bits que para L/R; como los umbrales de M/S son el mínimo de los de
L, R y el propio, esa estimación es pesimista y la música estéreo quedaba casi
toda en L/R (LAME: M/S en ~95 % de los frames). Ahora se usa M/S salvo que
necesite más del doble de bits que L/R, lo que deja L/R para los casos en que M/S
cuesta de verdad (un canal casi mudo, cuyo silencio M/S llenaría con el ruido del
otro). Música 1 a 128 kbps: −1.81 → −1.45; batería −0.33 → −0.12 (LAME −0.14).

Las dos correcciones de esta fecha (ver la historia al final) son la mejora: los
cuartetos count1 iban con el índice de la tabla invertido y ffmpeg descartaba
frames cuando el modo de canal cambiaba entre stereo y joint stereo. El modelo
psicoacústico con FFT (`EncDefaultPsyModel := 1`, modelo 2 de la ISO para los
bloques largos) queda a la par del modelo sobre las líneas MDCT: +0.01–0.03 de
media en CBR, pero peor en la batería, y en VBR reparte peor los bits (da a la
música densa demasiados pocos). Por eso no es el modelo por defecto. La distancia
que queda con LAME no es del modelo psicoacústico: a igual tasa media, ni el
modelo ni sus parámetros (TMN/NMT, minval, ATH, control de pre-eco) la cambian;
queda en la música densa a 128 kbps y más (música 1: −1.45 frente a −1.32; a
192 kbps la media −0.18 frente a −0.13). Redondear al nivel de reconstrucción más
cercano en vez del sesgo 0.4054 se probó y empeora (0.03).

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

## VBR (2026-10-20)

`EncEnableVBR(Enc, Calidad)` (0 = mejor … 9 = archivos más pequeños, como `-V` de
LAME) o `EncodeWAVFileVBR` / `EncodeWAVStreamVBR`. Cada gránulo se cuantiza con la
cuantización más gruesa cuyo ruido queda bajo el umbral psicoacústico desplazado por
la calidad, y la trama toma el bitrate más bajo que, con el reservorio, aloja esos
bits. El archivo lleva cabecera Xing (VBR) con número de tramas, bytes, tabla de
búsqueda real y extensión LAME (gapless). La escala de calidad está calibrada para
quedar cerca de los bitrates de LAME (kbps / ODG de PEAQ):

| Calidad | música 1 | LAME | música 2 | LAME | voz | LAME | batería | LAME | castañuelas | LAME |
|---|---|---|---|---|---|---|---|---|---|---|
| V0 | 230 / 0.07 | 232 / 0.06 | 253 / −0.39 | 244 / −0.07 | 105 / −0.16 | 114 / −0.03 | 92 / −0.51 | 143 / 0.01 | 144 / −0.05 | 140 / −0.08 |
| V2 | 184 / −0.27 | 180 / −0.26 | 194 / −0.96 | 191 / −0.27 | 81 / −0.67 | 87 / −0.25 | 76 / −0.85 | 84 / −0.22 | 103 / −0.37 | 104 / −0.43 |
| V4 | 153 / −0.91 | 150 / −0.94 | 158 / −1.63 | 155 / −1.06 | 66 / −1.44 | 70 / −0.73 | 63 / −1.29 | 67 / −0.43 | 82 / −0.47 | 77 / −0.43 |
| V6 | 114 / −2.40 | 121 / −1.79 | 114 / −2.77 | 103 / −2.34 | 48 / −2.57 | 51 / −1.80 | 49 / −2.25 | 52 / −1.37 | 36 / −0.84 | 44 / −0.89 |
| V9 | 79 / −3.44 | 80 / −3.09 | 81 / −3.27 | 75 / −2.65 | 41 / −3.04 | 37 / −2.55 | 39 / −2.39 | 41 / −2.58 | 33 / −0.86 | 36 / −1.80 |

Recalibrada el 2026-10-20 tras el cambio de M/S, y con umbral absoluto adaptativo:
en los gránulos silenciosos (pausas de la voz, finales) el umbral absoluto baja
hasta 20 dB, porque el oyente sube el volumen y ese detalle se oye. Sin él la voz
quedaba a 54 kbps con −1.75 en V2 (pausas con 4 dB de SNR; LAME 25 dB). Solo en
VBR: en CBR los gránulos silenciosos ya reciben bits sobrantes y bajar el umbral
les quita reservorio a los transitorios (castañuelas −0.39 → −0.77 a 96 kbps).
Ahora los bitrates siguen a los de LAME en las cinco piezas; la calidad queda a la
par en música 1 y castañuelas y por detrás en música 2 y batería (el umbral de los
transitorios en modo calidad).

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

Limitaciones: solo MPEG-1 (32/44.1/48 kHz), sin ABR, sin intensity stereo,
sin bloques mixtos. Partición psicoacústica por defecto = bandas de scalefactor
(22 largas, 13 × 3 cortas); el modelo FFT opcional usa particiones de 1/3 Bark
solo en bloques largos.

## Pipeline

| Unidad | Contenido |
|---|---|
| `MP3EncPolyphase` | Banco de análisis polifásico ISO (32 subbandas) |
| `MP3EncMDCT` | MDCT 36→18 para ventanas normal/start/stop y 3 × 12→6 para bloques cortos, escala 1/(N/4) (inversa exacta de la IMDCT ISO), butterflies antialias (solo bloques largos) |
| `MP3EncPsy` | Modelo psicoacústico sobre las líneas MDCT: energía por banda, spreading (Schroeder, Bark), tonalidad (SFM), minval, ATH; versión de bloques cortos por ventana; devuelve ruido permitido por línea y estimación de bits. Opcional para bloques largos: modelo 2 de la ISO sobre una FFT de 1024 puntos del PCM (particiones de 1/3 Bark, tonalidad por impredecibilidad de cada línea), que da la relación umbral/energía por banda y se aplica a las energías MDCT |
| `MP3EncLoop` | Bucle interno (búsqueda binaria de global_gain) + externo (scalefactors por banda, scalefac_scale, preflag, scalefac_compress); criterio de LAME (suma de excesos²); fase de ahorro de bits; variante de bloques cortos con subblock_gain |
| `MP3EncQuantize` | Fórmulas ISO de cuantización/decuantización, tablas de bandas |
| `MP3EncHuffman` / `MP3EncRateCtrl` | Tablas Huffman, big_values/count1/rzero (Shine), elección rápida de tabla por máximo de región, división óptima de las regiones (bloques largos) |
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

`tests/src/TestMP3EncPhase1..21.dpr` (un programa por fase, 848 checks; la 19
cubre los modelos psicoacústicos (MDCT y FFT), el bucle, el reservorio, MS automático y round trips
decodificados con `mp3-decoder`; la 20, bloques cortos (round trips solo cortos y
automáticos, secuencia legal de ventanas, pre-eco frente a solo bloques largos,
bucle corto) y la conservación del canal S en M/S; la 21, VBR (tasas por trama,
orden de tamaños por calidad, reservorio, round trips y cabecera Xing con tabla de
búsqueda y datos gapless). `../mp3-roundtrip` decodifica cualquier MP3
con `audio-codec` y lo vuelve a codificar.

## Historia de los errores corregidos (2026-10-13)

- MDCT sin el factor 1/(N/4): líneas 9× demasiado grandes → salida saturada.
- Cuantizador con |xr|^0.75/step en vez de (|xr|/step)^0.75; PCM sin normalizar.
- Elección de tabla Huffman ignorando linbits; códigos > 32 bits truncados.
- Control de tasa contaba 0 bits para valores incodificables → global_gain 0 y
  gránulos vacíos (silencio a partir del segundo frame).
- A 32 kbps el criterio "menos bandas por encima" (dist10) elegía soluciones
  con SNR ≈ 0 dB; sustituido por la suma de excesos al cuadrado (LAME).

## Errores corregidos el 2026-10-20 (hallados al medir con PEAQ)

- Cuartetos count1 con el índice de la tabla A/B invertido (v + 2w + 4x + 8y en
  vez de 8v + 4w + 2x + y): todo cuarteto asimétrico se decodificaba en orden
  inverso. En bloques largos el ruido en agudos igualaba a la señal; en bloques
  cortos, un cuarteto entre dos ventanas con distinta subblock_gain producía
  basura audible (+26 dB de error en un golpe de batería).
- Modo de canal de la cabecera alternando stereo / joint stereo según la decisión
  M/S: ffmpeg da por perdida la sincronía y descarta los primeros frames. Ahora
  todos los frames (y el Xing/Info) dicen joint stereo; solo cambia ms_stereo.
