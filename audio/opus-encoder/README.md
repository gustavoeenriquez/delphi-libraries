# opus-encoder — Encoder Opus (RFC 6716) en Delphi puro

Port fiel del encoder de **libopus 1.5.2** (build float) a Object Pascal, sin DLLs.
Entrada: PCM int16 o float intercalado a 8, 12, 16, 24 o 48 kHz, mono o estéreo.
Salida: paquetes Opus crudos (RTP, RFC 7587) o un flujo Ogg Opus (RFC 7845).

Es obra derivada de libopus (BSD de Xiph.Org y otros): ver [Licencia](#licencia).

## Estado (E3 cerrada el 2026-10-20: port completo)

| Etapa | Contenido | Estado |
|---|---|---|
| **E1 – CELT** | `celt_encoder.c` completo (transitorios, prefiltro de pitch, MDCT, tf_select, spread, dynalloc, trim, energía Laplace con doble pasada, PVQ, theta RDO, intensity/dual stereo, CBR/VBR/CVBR), capa `opus_encoder.c` para modo CELT, repaquetizador (40/60 ms), relleno CBR, Ogg Opus | ✅ **byte a byte idéntico a libopus** |
| **E2 – SILK** | encoder SILK float completo (`enc_API.c`, `encode_frame_FLP.c`: VAD, pitch, LPC/Burg, NLSF con trellis, LTP, análisis de ruido, NSQ y NSQ con decisión diferida, ganancias con control de tasa, LBRR/FEC in-band, DTX, estéreo mid/side, remuestreo y cambio de ancho de banda NB/MB/WB), y en `opus_encoder.c` los modos SILK e híbrido, `decide_fec`, el reparto SILK/CELT del híbrido, las transiciones con trama CELT redundante y el prefill | ✅ **byte a byte idéntico a libopus** |
| **E3 – Análisis** | `analysis.c` + MLP (`mlp.c`, `mlp_data.c`): análisis tonal a 24 kHz con FFT de 480, probabilidad voz/música y de actividad (red densa + GRU), ancho de banda detectado, `leak_boost`/`max_pitch_ratio` para CELT; en `opus_encoder.c` la decisión de modo por `voice_ratio`, la reducción por ancho de banda detectado, la actividad para la DTX de Opus (con energía pico) y el análisis por subtrama en tramas largas | ✅ **byte a byte idéntico a libopus** |

El encoder reproduce libopus 1.5.2 (build float por defecto) en todos sus
caminos: CELT, SILK, híbrido, transiciones, FEC, DTX y análisis tonal. No
incluye las extensiones experimentales que libopus deja desactivadas por
defecto (DRED, OSCE, enmascaramiento de surround).

## Validación

Oráculo: libopus 1.5.2 compilado en WSL (`tests/tools/build_oracle.sh`,
`--disable-intrinsics`, configuración por defecto con `FLOAT_APPROX`). Durante
E1–E2 se usó además una variante parcheada que descarta el análisis tonal. libopus
**no** es dependencia de la librería.

### E3 (análisis tonal; validación del encoder completo)

| Criterio | Resultado |
|---|---|
| (b) Fidelidad | **287.272 / 287.272 paquetes idénticos byte a byte** contra libopus normal (con su análisis): la matriz CELT de E1 completa (87.668), 210 configuraciones aleatorias SILK/híbrido/CELT/auto (162.526) y 44 dirigidas (37.078) que incluyen duración experta (`efd`, el análisis lee por delante de la trama), tramas de 80/100/120 ms, DTX con detección de actividad del MLP, API float y cambios de bitrate con decisiones voz/música |
| (a) Validez | decodifican en libopus (`final_range` igual) y en el decoder del port |
| (c) Calidad | PESQ idéntico a libopus por defecto (mismos bytes) |
| (g) Plataformas | Win64 y Linux64: 57/57 pruebas con los mismos CRC32, y bytes idénticos entre plataformas en las 33 configuraciones dirigidas de E2 (ya con análisis activo) |

### E2 (SILK e híbrido)

| Criterio | Resultado |
|---|---|
| (b) Fidelidad | **125.258 / 125.258 paquetes idénticos byte a byte** (y `final_range` idéntico): 33 configuraciones dirigidas (SILK NB/MB/WB, híbrido SWB/FB, estéreo, 10/20/40/60 ms, complejidad 0–10, CBR/VBR/CVBR, FEC con 5–30 % de pérdidas, DTX, API float, ancho de banda forzado, predicción desactivada) más 140 configuraciones aleatorias; incluye cambios de bitrate cada pocas tramas (`brcyc`) que fuerzan transiciones SILK↔híbrido↔CELT con trama redundante, cambios de ancho de banda interno de SILK (NB↔MB↔WB) y estéreo↔mono |
| (a) Validez | todos los paquetes decodifican en libopus (`final_range` igual al del encoder) y en el decoder del port |
| (c) Calidad | PESQ igual a libopus por defecto: idéntico a 8 kHz y ≤ 0,011 MOS a 16 kHz (donde libopus corre además el análisis tonal); la voz VoIP mejora 0,4–0,9 MOS respecto a E1 (CELT) |
| (d) Bitrate | idéntico a libopus (mismos bytes); CBR SILK de tamaño exacto |
| (e) Instancias | 3 encoders intercalados (CELT, SILK, híbrido y mezcla) producen los mismos bytes que por separado |
| (f) FEC / DTX | LBRR y DTX idénticos a libopus; vectores de FEC en `tests/vectors/lbrr` (paquetes con pérdidas + salida de libopus con `decode_fec`) |
| (g) Plataformas | Win64 y Linux64 (Delphi 13, SDK ubuntu24.04, en WSL): 53/53 pruebas con los mismos CRC32/`final_range`, y las 33 configuraciones dirigidas producen bytes idénticos en ambas |

PESQ de voz (mismo archivo, VoIP, 20 ms, CVBR, complejidad 10):

| Frecuencia | kbps | Este port (E2, sin análisis) | libopus por defecto | Este port en E1 (CELT) |
|---|---|---|---|---|
| 16 kHz (WB) | 12 | 3,556 | 3,545 | 2,735 |
| 16 kHz (WB) | 16 | 4,038 | 4,038 | 3,191 |
| 16 kHz (WB) | 24 | 4,407 | 4,404 | 3,783 |
| 16 kHz (WB) | 32 | 4,501 | 4,501 | 4,148 |
| 8 kHz (NB) | 10 | 4,118 | 4,118 | 3,171 |
| 8 kHz (NB) | 12 | 4,258 | 4,258 | 3,412 |
| 8 kHz (NB) | 16 | 4,402 | 4,402 | 3,798 |

### E1 (CELT)

| Criterio | Resultado |
|---|---|
| (b) Fidelidad | **87.668 / 87.668 paquetes idénticos byte a byte** (y `final_range` idéntico) en una matriz de 3 aplicaciones × CBR/VBR/CVBR × voz/música × mono/estéreo, 2,5/5/10/20/40/60 ms, 8/12/16/24/48 kHz, 6–510 kbps, complejidad 0–10, y CTLs (force channels, phase inversion, prediction disabled, LSB depth, signal, bandwidth, loss %, `maxbytes`) |
| (a) Validez | los 117.630 paquetes generados en la validación decodifican sin error en libopus (con `final_range` idéntico al del encoder) y en el decoder del port |
| (c) Calidad | PESQ igual a libopus forzado a CELT (diferencia 0,000 a 8 kHz; ≤ 0,03 a 16 kHz, donde libopus además corre su análisis tonal) |
| (d) Bitrate | CBR: tamaño exacto en todos los paquetes. CVBR: desvío medio +0,3 % a +3,3 % del objetivo, idéntico a libopus |
| (g) Plataformas | Win64 (Debug y Release) y Linux64: bytes idénticos entre plataformas |

## Uso

```pascal
uses OpusEncTypes, OpusEncoder;

// opus_encoder_create / opus_encoder_ctl / opus_encode
Enc := TOpusEncoder.Create(16000, 1, oaVoip);
Enc.Bitrate := 32000;           // OPUS_SET_BITRATE (o OPUS_AUTO / OPUS_BITRATE_MAX)
Enc.Complexity := 10;           // OPUS_SET_COMPLEXITY
Enc.Vbr := True;                // OPUS_SET_VBR / OPUS_SET_VBR_CONSTRAINT
Len := Enc.Encode(@Pcm16[0], 320, @Packet[0], Length(Packet));   // 20 ms a 16 kHz
// Len > 0: paquete listo para RTP (RFC 7587); Len < 0: código OPUS_*
// Len = 1 o 2 con Dtx activo: trama DTX (no hace falta enviarla)

// VoIP con FEC in-band (LBRR) y DTX
Enc.InbandFec := 1;             // OPUS_SET_INBAND_FEC
Enc.PacketLossPerc := 10;       // OPUS_SET_PACKET_LOSS_PERC: activa LBRR si el bitrate alcanza
Enc.Dtx := True;                // OPUS_SET_DTX

// Ogg Opus
W := TOggOpusWriter.Create(Stream, 48000, 2, oaAudio);   // 20 ms por defecto
W.Encoder.Bitrate := 96000;
W.WriteInt16(@Pcm[0], NumSamples);   // cualquier cantidad de muestras
W.Finish;                            // EOS con recorte exacto del final
```

CTLs disponibles como propiedades de `TOpusEncoder`: `Application`, `Bitrate`,
`Complexity`, `Vbr`, `VbrConstraint`, `InbandFec`, `PacketLossPerc`, `Dtx`,
`Signal`, `Bandwidth`, `MaxBandwidth`, `ForceChannels`, `LsbDepth`,
`ExpertFrameDuration`, `PredictionDisabled`, `PhaseInversionDisabled`,
`ForceMode`, `VoiceRatio`, `Lfe`; lectura: `Lookahead`, `SampleRate`,
`FinalRange`, `InDTX`, `Mode`. `Reset` equivale a `OPUS_RESET_STATE`.
Los argumentos inválidos lanzan `EArgumentException` (donde libopus devuelve
`OPUS_BAD_ARG`).

### Compatibilidad

`OpusEncPacket` conserva la API anterior (`TOpusCeltEncoder.EncodeFrame`,
`TOpusWriter`) marcada `deprecated`: ahora delega en `TOpusEncoder`
(`RESTRICTED_LOWDELAY`, CBR que usa los `MaxLen` bytes) y en `TOggOpusWriter`.
Las unidades `OpusEncCelt` y `OpusRangeEncoder` del encoder experimental anterior
se eliminaron.

## Unidades

| Unidad | Contenido (origen en libopus 1.5.2) |
|---|---|
| `OpusEntEnc` | Codificador de rango + Laplace (`entenc.c`, `entcode.c`, `laplace.c`) |
| `OpusCeltEncTables` | Twiddles de la FFT, bitrev y trig de la MDCT (generadas con `tools/gen_celt_enc_tables.py` desde `static_modes_float.h`) |
| `OpusCeltEncMath` | FFT kiss y MDCT directa, `celt_log2/exp2` (FLOAT_APPROX), PVQ (`vq.c`, `cwrs.c`), pitch (`pitch.c`, `celt_lpc.c`), comb filter |
| `OpusCeltEncBands` | Energías, cuantización gruesa/fina (`quant_bands.c`), asignación (`rate.c`), `quant_all_bands` con theta RDO (`bands.c`) |
| `OpusCeltEnc` | `TCeltEncoder` (`celt_encoder.c`) |
| `OpusSilkEncTables` | Tablas SILK (generadas con `tools/gen_silk_enc_tables.py` desde `silk/tables_*.c`, `pitch_est_tables.c`, `resampler_rom.c`) |
| `OpusSilkEncDefs` | Constantes (`define.h`, `tuning_parameters.h`), estados y codebooks NLSF/LTP (`structs.h`, `structs_FLP.h`) |
| `OpusSilkEncCore` | Remuestreador (`resampler*.c`), VAD (`VAD.c`, `ana_filt_bank_1.c`, `sigm_Q15.c`), filtro de transición (`LP_variable_cutoff.c`, `biquad_alt.c`), ganancias (`gain_quant.c`) |
| `OpusSilkEncNLSF` | `A2NLSF.c`, `NLSF2A.c`, `LPC_inv_pred_gain.c`, cuantización NLSF con trellis (`NLSF_encode.c`, `NLSF_del_dec_quant.c`, …), `process_NLSFs.c` |
| `OpusSilkEncNSQ` | `NSQ.c`, `NSQ_del_dec.c`, `quant_LTP_gains.c`, `VQ_WMat_EC.c` |
| `OpusSilkEncCode` | Codificación de índices, pulsos, shell y signos; estéreo mid/side (`stereo_*.c`) |
| `OpusSilkEncDSP` | Primitivas float (`silk/float/*_FLP.c`: Burg, Schur, autocorrelación warped, …) y `pitch_analysis_core_FLP.c` |
| `OpusSilkEncFLP` | Análisis float del encoder: pitch, forma de ruido, LPC/LTP, ganancias, envoltorios a punto fijo (`silk/float/`) |
| `OpusSilkEnc` | `silk_Encode`/`silk_InitEncoder` (`enc_API.c`), `encode_frame_FLP.c` con LBRR y control de tasa, `control_*.c`, `init_encoder.c`, `HP_variable_cutoff.c` |
| `OpusAnalysisTables` | Ventana, DCT, bandas y pesos del MLP (generadas con `tools/gen_analysis_tables.py` desde `analysis.c` y `mlp_data.c`) |
| `OpusAnalysis` | Análisis tonal y MLP (`analysis.c`, `mlp.c`) |
| `OpusRepacketizer` | `opus_packet_pad`, repaquetizador (`repacketizer.c`, `opus.c`) |
| `OpusEncoder` | `TOpusEncoder` (`opus_encoder.c`) |
| `OggOpusWriter` | `TOggOpusWriter` (RFC 7845) |
| `OpusEncTypes` | Constantes `OPUS_*`, `TAnalysisInfo`, `TSilkInfo`, `TSilkEncControl` |
| `OpusEncPacket` | Capa de compatibilidad (obsoleta) |

Reutiliza del `opus-decoder` (sin modificarlo) las tablas CELT, `cwrs`/PVQ-V,
Haar/Hadamard, `bitexact_cos` y la aritmética de punto fijo de SILK
(`OpusSilkMath`). `NLSF2A` y `LPC_inverse_pred_gain` tienen copia propia en el
encoder porque su umbral `SILK_FIX_CONST(1/MAX_PREDICTION_POWER_GAIN, 30)` debe
truncarse a 107374 como en C.

## Notas del port

- **Semántica `float` de C.** Todas las unidades usan `{$EXCESSPRECISION OFF}`.
  Los literales `f` de C son constantes tipadas `Single`; los literales `double`
  de C (p. ej. `QCONST32(0.139,28)`, `.5*len2`) se dejan como `Double`. `Sqrt`
  de Delphi devuelve `Extended`/`Double` y convierte en doble toda la expresión:
  se usa `SqrtF` (`(float)sqrt(x)`). Sin estos cuidados las distancias del
  theta RDO difieren en 1 ulp y cambian decisiones.
- `celt_log2`/`celt_exp2` son las aproximaciones `FLOAT_APPROX` de libopus
  (configuración por defecto del `configure`), no `log`/`exp`.
- La FFT es la kiss_fft de libopus con sus mismas tablas (los literales de 8
  cifras no siempre coinciden con recalcular `cos`/`sin`).
- `shr` de Delphi es lógico: los `>>` de valores con signo usan `Sar`.
- **SILK float.** Los productos `float*float` que C acumula en `double`
  (`energy += a*b - c*d` en `corrMatrix_FLP.c`, Burg, energías de pitch) se
  calculan en un temporal `Single` antes de sumarse, como hace C; los
  acumuladores `double` de C son `Double`. Las constantes `SILK_FIX_CONST` se
  tomaron del compilador C (truncamiento, no redondeo).
- **Análisis tonal.** Las comparaciones que C hace en `double` (p. ej.
  `highE > lowE + 7.5`) se hacen en `Double`; las constantes derivadas de
  `M_PI` (`(float)(.5f/M_PI)`, `40.f*16.f*pi4`) se tomaron del compilador C.
  `opus_encode` analiza el PCM int16 original (`downmix_int`): el port lo
  pasa como float x/32768, conversión exacta, así que el análisis ve los
  mismos valores.
- `silk_float2int` (`lrintf`) es `Round` (redondeo al par más cercano). Las
  conversiones a `opus_int8`/`opus_int16` de C se reproducen con `ShortInt`/
  `SmallInt` (envolviendo como en C).

## Pruebas

- `tests/src/OpusEncoderTests.dpr` (57 pruebas): codificador de rango y PVQ
  (ida y vuelta con el decoder del port), 14 vectores de referencia de libopus
  1.5.2 sobre señales sintéticas deterministas (CRC32 de los paquetes y
  `final_range`; 7 CELT, 5 SILK/híbrido con LBRR, estéreo, 10/20/40 ms y
  CBR, y 2 donde el análisis tonal decide el modo), decodificación, CBR/VBR, instancias intercaladas (CELT, SILK,
  híbrido), Ogg Opus (pre-skip y recorte exacto del final), compatibilidad,
  CTLs y relleno.
- `tests/tools/opus_oracle.c` + `build_oracle.sh`: oráculo libopus (WSL/Linux):
  `encode` (con `brcyc=b1,b2,...,N` para cambiar el bitrate cada N tramas y
  `efd=` para OPUS_SET_EXPERT_FRAME_DURATION),
  `decode` y `fecdec` (decodificación con pérdidas y `decode_fec`).
- `tests/tools/OpusEncTool.dpr`: espejo del oráculo (`encode`, `decode`,
  `compare` paquete a paquete, `gensig`) para comparar byte a byte.
- `tests/tools/lbrr_vectors.py` → `tests/vectors/lbrr/`: vectores de FEC in-band
  (ver su README).


## Licencia

Este encoder es una obra derivada de libopus 1.5.2. Se distribuye bajo la
licencia BSD de libopus:

```
Copyright 2001-2023 Xiph.Org, Skype Limited, Octasic,
                    Jean-Marc Valin, Timothy B. Terriberry,
                    CSIRO, Gregory Maxwell, Mark Borgerding,
                    Erik de Castro Lopo, Mozilla, Amazon

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of Internet Society, IETF or IETF Trust, nor the
names of specific contributors, may be used to endorse or promote
products derived from this software without specific prior written
permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

Opus está sujeto a las licencias de patentes libres de regalías indicadas en
https://datatracker.ietf.org/ipr/1524/ (Xiph.Org),
https://datatracker.ietf.org/ipr/1914/ (Microsoft) y
https://datatracker.ietf.org/ipr/1526/ (Broadcom).

Las pruebas (`tests/src/OpusEncTestSignals.pas`, `OpusEncoderTests.dpr`), los
vectores de `tests/vectors` y las herramientas de validación son CC0 1.0.
