# opus-encoder — Encoder Opus (RFC 6716) en Delphi puro

Port fiel del encoder de **libopus 1.5.2** (build float) a Object Pascal, sin DLLs.
Entrada: PCM int16 o float intercalado a 8, 12, 16, 24 o 48 kHz, mono o estéreo.
Salida: paquetes Opus crudos (RTP, RFC 7587) o un flujo Ogg Opus (RFC 7845).

Es obra derivada de libopus (BSD de Xiph.Org y otros): ver [Licencia](#licencia).

## Estado (E1 cerrada el 2026-10-20)

| Etapa | Contenido | Estado |
|---|---|---|
| **E1 – CELT** | `celt_encoder.c` completo (transitorios, prefiltro de pitch, MDCT, tf_select, spread, dynalloc, trim, energía Laplace con doble pasada, PVQ, theta RDO, intensity/dual stereo, CBR/VBR/CVBR), capa `opus_encoder.c` para modo CELT, repaquetizador (40/60 ms), relleno CBR, Ogg Opus | ✅ **byte a byte idéntico a libopus** |
| E2 – SILK | encoder SILK float (LPC/pitch, NSQ, NLSF, ganancias, VAD, LBRR/FEC, DTX), NB/MB/WB | pendiente |
| E3 – Híbrido | modo híbrido, decisión de modo/ancho de banda, redundancia CELT, `analysis.c` + MLP | pendiente |

Mientras no esté E2, **toda trama se codifica en modo CELT** (como libopus con
`OPUS_SET_FORCE_MODE(MODE_CELT_ONLY)`). Hasta E3 no se ejecuta el análisis tonal
(`analysis.c`), que libopus usa con complejidad ≥ 7 a ≥ 16 kHz: en esos casos la
salida es la de libopus sin análisis. Los CTL de FEC in-band y la DTX de SILK
se aceptan pero todavía no tienen efecto.

## Validación de E1

Oráculo: libopus 1.5.2 compilado en WSL (`tests/tools/build_oracle.sh`,
`--disable-intrinsics`, configuración por defecto con `FLOAT_APPROX`), más una
variante parcheada que descarta el resultado del análisis tonal para comparar
complejidad 7–10. libopus **no** es dependencia de la librería.

| Criterio | Resultado |
|---|---|
| (b) Fidelidad | **87.668 / 87.668 paquetes idénticos byte a byte** (y `final_range` idéntico) en una matriz de 3 aplicaciones × CBR/VBR/CVBR × voz/música × mono/estéreo, 2,5/5/10/20/40/60 ms, 8/12/16/24/48 kHz, 6–510 kbps, complejidad 0–10, y CTLs (force channels, phase inversion, prediction disabled, LSB depth, signal, bandwidth, loss %, `maxbytes`) |
| (a) Validez | los 117.630 paquetes generados en la validación decodifican sin error en libopus (con `final_range` idéntico al del encoder) y en el decoder del port |
| (c) Calidad | PESQ igual a libopus forzado a CELT (diferencia 0,000 a 8 kHz; ≤ 0,03 a 16 kHz, donde libopus además corre su análisis tonal). Frente a libopus por defecto (SILK en VoIP) la voz a 12–32 kbps queda 0,4–0,9 MOS por debajo: es lo que aportará E2 |
| (d) Bitrate | CBR: tamaño exacto en todos los paquetes. CVBR: desvío medio +0,3 % a +3,3 % del objetivo, idéntico a libopus |
| (e) Instancias | 3 encoders intercalados producen exactamente los mismos bytes que por separado |
| (g) Plataformas | Win64 (Debug y Release). Linux64: pendiente del SDK en Delphi 13 |

PESQ de voz (mismo archivo, VoIP, 20 ms, CVBR, complejidad 10):

| Frecuencia | kbps | Este port (E1, CELT) | libopus CELT | libopus por defecto (SILK) |
|---|---|---|---|---|
| 16 kHz (WB) | 12 | 2,735 | 2,740 | 3,545 |
| 16 kHz (WB) | 16 | 3,191 | 3,213 | 4,038 |
| 16 kHz (WB) | 24 | 3,783 | 3,815 | 4,404 |
| 16 kHz (WB) | 32 | 4,148 | 4,151 | 4,501 |
| 8 kHz (NB) | 10 | 3,171 | 3,171 | 4,118 |
| 8 kHz (NB) | 12 | 3,412 | 3,412 | 4,258 |
| 8 kHz (NB) | 16 | 3,798 | 3,798 | 4,402 |

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
| `OpusRepacketizer` | `opus_packet_pad`, repaquetizador (`repacketizer.c`, `opus.c`) |
| `OpusEncoder` | `TOpusEncoder` (`opus_encoder.c`) |
| `OggOpusWriter` | `TOggOpusWriter` (RFC 7845) |
| `OpusEncTypes` | Constantes `OPUS_*`, `TAnalysisInfo`, `TSilkInfo`, `TSilkEncControl` |
| `OpusEncPacket` | Capa de compatibilidad (obsoleta) |

Reutiliza del `opus-decoder` (sin modificarlo) las tablas CELT, `cwrs`/PVQ-V,
Haar/Hadamard, `bitexact_cos` y la aritmética de punto fijo de SILK.

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

## Pruebas

- `tests/src/OpusEncoderTests.dpr` (40 pruebas): codificador de rango y PVQ
  (ida y vuelta con el decoder del port), 7 vectores de referencia de libopus
  1.5.2 sobre señales sintéticas deterministas (CRC32 de los paquetes y
  `final_range`), decodificación, CBR/VBR, instancias intercaladas, Ogg Opus
  (pre-skip y recorte exacto del final), compatibilidad, CTLs y relleno.
- `tests/tools/opus_oracle.c` + `build_oracle.sh`: oráculo libopus (WSL/Linux).
- `tests/tools/OpusEncTool.dpr`: espejo del oráculo (`encode`, `decode`,
  `compare` paquete a paquete, `gensig`) para comparar byte a byte.

Los vectores de complejidad ≥ 7 a ≥ 16 kHz corresponden a libopus sin análisis
tonal; habrá que regenerarlos con el oráculo normal al cerrar E3.

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

Las pruebas (`tests/src/OpusEncTestSignals.pas`, `OpusEncoderTests.dpr`) y las
herramientas de validación son CC0 1.0.
