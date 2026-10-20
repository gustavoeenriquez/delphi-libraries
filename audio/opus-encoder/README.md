# opus-encoder — trabajo en curso

Encoder Opus CELT experimental (`TOpusCeltEncoder`, `TOpusWriter`). **No produce audio
compatible con libopus**: el bitstream de `OpusEncCelt` no sigue el formato CELT real
(energía gruesa sin Laplace, sin tf/spread/asignación de libopus, mapeo de bins propio).
El decoder fiel de `opus-decoder` lo lee sin error y con la duración correcta, pero la
SNR de un seno es ~0 dB. Pendiente: port de `celt_encoder.c`.

## Estado (2026-10-20)

| Aspecto | Estado |
|---|---|
| Compila contra el `opus-decoder` reescrito | ✅ (unidades `src/`) |
| TOC: config CELT FB = 28 + LM (29/30/31 para 5/10/20 ms) | ✅ verificado con `OpusEncFrameSizeTests` |
| Duración decodificada (240/480/960 muestras) | ✅ |
| 2,5 ms (LM 0) | ❌ no seleccionable: `Create` recibe `FrameSizeMs` entero y cae a 20 ms |
| Calidad de audio (SNR) | ❌ ~0 dB (bitstream no compatible con libopus) |
| Estéreo | ❌ el TOC marca estéreo pero `CeltEncodeFrame` solo procesa un canal |
| Control de bitrate | ❌ solo vía `MaxLen` de `EncodeFrame` (usa todos los bytes disponibles) |

## Tests

- `tests/src/OpusEncFrameSizeTests.dproj` — TOC y duración por tamaño de trama (23 checks, pasa).
- `OpusEncoderTests`, `OpusCeltEncTests`, `OpusRoundTripTests` — **no compilan**: usan
  `OpusRangeDecoder`/`OpusFrameDecoder`, eliminadas en la reescritura del decoder.
