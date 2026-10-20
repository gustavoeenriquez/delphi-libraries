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
- Evaluación con PEAQ (GstPEAQ). Corregidos el índice invertido de los cuartetos
  count1 (6af75c4) y la alternancia stereo/joint stereo de la cabecera que hacía
  descartar frames a ffmpeg (fbc120e): ODG medio a 128 kbps −1.35 → −1.03.
- Modelo psicoacústico 2 de la ISO con FFT de 1024 puntos para bloques largos,
  opcional (`EncDefaultPsyModel := 1`): a la par del modelo MDCT en CBR, peor
  reparto en VBR. Fase 19 ampliada (PF01–PF10, RV28–RV30).
- Regiones Huffman óptimas por gránulo (bloques largos): −1.9 % de bits Huffman,
  ODG medio 128 kbps −1.03 → −1.00. Fase 19: RC04–RC08.
- Reparto de bits: demanda estimada ×2.5 (largos) / ×4 (cortos), medido contra los
  bits reales en modo calidad. ODG medio 96/128/192: −1.49 / −0.90 / −0.28
  (batería a 128: −0.82 → −0.33).
- M/S salvo que estime más del doble de bits que L/R (antes: solo si E(S) ≤
  0.3 E(M) y menos bits): ODG medio 96/128/192 −1.30 / −0.76 / −0.18, a la par de
  LAME (−1.32 / −0.76 / −0.13). Fase 19: RV25 (canal mudo → L/R) y RV31.
- VBR con cuantización directa en modo calidad (paso por banda, global_gain y
  scalefactors como `vbr_mtrh`; antes el bucle de CBR engrosaba todas las bandas a
  la vez). Modelo revisado a partir del NMR por banda de PEAQ: ATH en agudos según
  la tasa, umbral ≤ energía propia − 12 dB, dispersión hacia arriba 1.5× más
  empinada; minval 32 dB en VBR. Escala recalibrada. ODG medio (6 piezas) V0/V2/V5
  −0.18 / −0.63 / −2.01 → −0.07 / −0.41 / −1.48 (LAME −0.01 / −0.29 / −1.25); CBR
  96/128/192 (5 piezas) −1.34 / −0.73 / −0.08 (LAME −1.32 / −0.76 / −0.13). Fase 19:
  PS15 y PS22–PS25, LP20–LP23; fase 20: WS11–WS13.
- Reparto VBR entre materiales: mono 1.5 dB más estricto (calibrado aparte),
  bloques cortos 8 dB más estrictos, control de pre-eco ISO (2× / 16×) en bloques
  largos; escala recalibrada. ODG medio (6 piezas) V0/V2/V5/V7 −0.02 / −0.26 /
  −1.13 / −1.83, a la par o por delante de LAME (−0.01 / −0.29 / −1.25 / −2.06).
  Fase 21: VB08–VB09.

## Pendiente / ideas

- ABR (bitrate medio objetivo).
- La decisión automática M/S por bits estimados no siempre elige el modo de
  mejor SNR (en ruido sintético ancho elige L/R aunque M/S conserva mejor S).
- Intensity stereo; MPEG-2/2.5 (tasas bajas de muestreo).
- CBR a la par de LAME en la media (por delante a 192 kbps); queda música densa
  a 96–128 kbps (música 1 a 128 kbps −1.53 frente a −1.32). Ideas: scfsi,
  estrategias de amplificación del bucle externo. Probado sin ventaja: redondeo
  al nivel más cercano (adj43).
- VBR: queda el reparto dentro de la música estéreo (música 2 en V2 −0.65 frente
  a −0.27; recibe menos bits que en LAME y música 1 más) y la batería en V0 (−0.26;
  LAME corta a ~19.5 kHz). Probado sin ventaja: umbral absoluto más bajo en
  silencios, ATH que sigue la sonoridad con decaimiento, tope del ruido VBR por la
  energía propia, minval con más pendiente, umbral de ataque más sensible, modelo
  FFT en VBR, paso bajo en V0.
