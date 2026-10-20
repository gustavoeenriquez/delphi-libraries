# opus-decoder — Decoder Opus (RFC 6716) en Delphi puro

Port fiel de libopus 1.5.2 (CELT + SILK + híbrido) a Object Pascal, sin DLLs.
Salida: float planar a 48 kHz, rango [-1, 1]. Es obra derivada de libopus
(licencia BSD de Xiph.Org y otros): ver [Licencia](#licencia).

## Estado (validado 2026-10-13)

| Modo | Estado | Verificación contra libopus 1.5.2 |
|---|---|---|
| CELT (2.5/5/10/20 ms, NB..FB, mono/estéreo, transitorios, post-filtro) | ✅ | SNR 104-106 dB (float) |
| SILK (NB/MB/WB, 10/20/40/60 ms, mono/estéreo, LBRR skip) | ✅ | **bit-exacto** (int16, CRC idéntico) |
| Híbrido (SILK + CELT con range decoder compartido, redundancia, transiciones) | ✅ | maxdiff 1 LSB |
| Ocultación de pérdidas | ✅ SILK (PLC/CNG completos), CELT solo ruido (libopus usa PLC por pitch) | no comparable |
| Ogg Opus (RFC 7845): OpusHead/Tags, pre-skip, ganancia, recorte por granule | ✅ | conteo exacto |
| Multistream (mapping family 1 con más de 2 canales) | ❌ | — |

Comparar siempre contra `ffmpeg -c:a libopus` o contra una `opus.dll` real: el decoder
nativo de ffmpeg difiere ~50-60 dB de libopus y no sirve como referencia exacta.

## Unidades

| Unidad | Contenido (origen en libopus) |
|---|---|
| `OpusTypes` | TOC y partición de paquetes (`opus.c`) |
| `OpusEntDec` | Range decoder + Laplace (`entdec.c`, `laplace.c`), bit-exacto |
| `OpusCeltTables` | Tablas del modo 48 kHz/960 (generadas desde `static_modes_float.h`) |
| `OpusCeltMath` | cwrs, vq, Haar/Hadamard, IMDCT (FFT mixed-radix 480/240/120/60), comb filter |
| `OpusCeltBands` | Energías, asignación de bits, decodificación de bandas (`quant_bands.c`, `rate.c`, `bands.c`) |
| `OpusCelt` | `TCeltDecoder` (`celt_decoder.c`) |
| `OpusSilkTables` | Tablas SILK (generadas desde `silk/tables_*.c`) |
| `OpusSilkMath` | Aritmética de punto fijo, NLSF2A, LPC, bwexpander |
| `OpusSilk` | `TSilkDecoder` (`dec_API.c`, `decode_*.c`, PLC, CNG, estéreo, resampler) |
| `OpusDecoder` | `TOpusStreamDecoder` (`opus_decoder.c`) y `TOpusDecoder` (Ogg Opus) |

## Uso

```pascal
Dec := CreateAudioDecoderFromFile('voz.opus');   // vía audio-codec, autodetección
while Dec.Decode(Buf) = adrOK do Procesar(Buf);  // Buf: TAudioBuffer planar float

// O directamente con paquetes Opus crudos:
Stream := TOpusStreamDecoder.Create(2);
N := Stream.DecodePacket(@Pkt[0], Len, Buf);     // N muestras por canal
```

## Tests y muestras

`tests/src/OpusDecoderTests.dpr` (88 tests): formato de paquetes, range decoder, PVQ,
helpers de punto fijo, NLSF2A, y decodificación de las muestras reales de `samples/`
(generadas con ffmpeg/libopus) con conteo, RMS y CRC de referencia medidos con libopus.
La herramienta `audio/tools/AudioProbe` compara cualquier archivo contra ffmpeg.

## Notas de port

- Los parámetros no pueden llamarse `Dec` en Delphi (ocultan el intrínseco `Dec()`).
- Desplazamientos aritméticos: `shr` de Delphi es lógico; usar `Sar32/Sar64` de `OpusSilkMath`.
- Las tablas del C contienen macros (`OFFSET_UVL_Q10`...): el generador las sustituye y
  aborta si queda algún identificador sin resolver.

## Licencia

Este decoder es una obra derivada de libopus 1.5.2 y se distribuye bajo la
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

Las pruebas (`tests/src/OpusDecoderTests.dpr`) son CC0 1.0.
