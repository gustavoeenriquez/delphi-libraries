# STATUS: FUNCIONAL

**Fecha:** 2026-10-13 (antes: "NO FUNCIONAL — EN PAUSA", 2026-05-29)

## Resultado

El codificador produce MP3 válidos con calidad comparable a LAME (SNR medida
decodificando con ffmpeg; ver tabla en `README.md`): mono 128 kbps 41.9 dB
(LAME 39.1), estéreo joint 128 kbps 40.6 dB (LAME 37.3), mono 32 kbps 14.8 dB
(LAME 13.8). ffmpeg y `mp3-decoder` decodifican los archivos sin errores y
coinciden entre sí (93 dB). Cabecera LAME gapless correcta (ffmpeg recorta
delay 528 + padding y la duración queda exacta).

## Causas del fallo anterior (todas corregidas)

1. `MP3EncMDCT`: faltaba el factor 1/9 (= 1/(N/4)) que exige la IMDCT ISO sin
   escala; todas las líneas salían 9× más grandes (salida saturada).
2. `MP3EncQuantize`: la fórmula era |xr|^0.75 / step en vez de (|xr|/step)^0.75,
   y el PCM no estaba normalizado a ±1.
3. `MP3EncRateCtrl`: la selección de tabla Huffman ignoraba la capacidad de
   linbits; los códigos de más de 32 bits se truncaban; los valores
   incodificables contaban 0 bits, por lo que la búsqueda binaria convergía a
   global_gain = 0 y gránulos vacíos (silencio desde el segundo frame).
4. Partición big_values/count1 al estilo Shine (cuadrupletas desde el final).
5. `MP3EncXing`: la extensión LAME estaba desplazada un byte (ffmpeg leía
   delay = 39); corregido al layout real (36 bytes, delays en +21).

## Añadido

- `MP3EncPsy`: modelo psicoacústico sobre las líneas MDCT (energía por banda,
  spreading de Schroeder en Bark, tonalidad por SFM, minval, ATH con 96 dB
  SPL para escala completa). Devuelve ruido permitido por línea y una
  estimación de bits.
- `MP3EncLoop`: bucle interno (búsqueda binaria de global_gain con |xr|^0.75
  precalculado) y externo (scalefactors por banda, scalefac_scale, preflag,
  scalefac_compress mínimo). Criterio de mejor solución de LAME (suma de
  excesos² sobre el umbral); fase de ahorro de bits con mínimo configurable.
- `MP3EncEncoder`: asignación de bits entre gránulos/canales proporcional a
  la demanda estimada, reservorio de bits (main_data_begin ≤ 511 bytes, cola
  de frames, `EncFlush`), MS estéreo en el dominio MDCT con decisión
  automática por frame (`EncodeFrameAuto`), paso bajo por tasa (tabla LAME).
- `MP3EncWAV`: reservorio activado, MS automático, frame final de vaciado,
  delay 528 declarado en la etiqueta LAME.
- Tests: `TestMP3EncPhase19` (69 checks: psy, loop, tablas rápidas,
  reservorio, MS, round trips con `mp3-decoder`). Las 19 fases pasan
  (843 checks). `mp3-roundtrip` reescrito sobre `audio-codec`.

## 2026-10-20

- Conmutación de ventana: bloques cortos, ventanas start/stop, detector de
  ataques, gránulo de anticipación (ENC_DELAY 528 → 1104). Pre-eco al nivel de
  LAME o mejor (ver README).
- Joint stereo: umbrales M/S = mínimo de L, R y el propio (antes el máximo, que
  descartaba el canal S); decisión M/S por estimación de bits.
- Bucles: si ni con global_gain 255 caben los bits, el intento se descarta
  (antes devolvía más bits que el presupuesto → "main data overflow").
- Fase 20 de tests (13 checks); fases 13, 18 y 19 actualizadas al nuevo retardo.
- VBR: modo calidad por gránulo, bitrate mínimo por trama, cabecera Xing con TOC
  real y extensión LAME; calidades 0..9 calibradas contra LAME -V. Fase 21 (14 checks).

## Pendiente / ideas

- ABR (bitrate medio objetivo).
- La decisión automática M/S por bits estimados no siempre elige el modo de
  mejor SNR (en ruido sintético ancho elige L/R aunque M/S conserva mejor S).
- Modelo psicoacústico con FFT y particiones más finas que las 22 bandas.
- Intensity stereo; MPEG-2/2.5 (tasas bajas de muestreo).
- Evaluación perceptual (PEAQ) además de la SNR.
