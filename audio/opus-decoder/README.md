# opus-decoder — Decoder Opus (RFC 6716) en Delphi puro

Port fiel de libopus 1.5.2 (CELT + SILK + híbrido) a Object Pascal, sin DLLs.
Salida: float planar a 48 kHz, rango [-1, 1]. Licencia: CC0 1.0 (las tablas y el
algoritmo provienen de libopus, licencia BSD de Xiph.Org).

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
