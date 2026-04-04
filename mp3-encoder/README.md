# mp3-encoder — Work in Progress

MP3 Layer III encoder for Delphi — MPEG-1, CBR, mono/stereo.

## Status

Architecture and implementation plan are complete. Core development is pending.
See the root [README.md](../README.md#what-is-missing--call-for-contributors) for
context and contribution guidelines.

## Planned modules

| Unit | Responsibility |
|---|---|
| `MP3EncTypes.pas` | `TMP3EncConfig`, `TEncGranule`, `TPsyResult` |
| `MP3EncBitWriter.pas` | MSB-first bit stream writer |
| `MP3EncPolyphase.pas` | Polyphase analysis filter bank (PCM → 32 subbands) |
| `MP3EncMDCT.pas` | Forward 36-point MDCT |
| `MP3Psychoacoustic.pas` | FFT + Bark spreading + ATH |
| `MP3EncQuantize.pas` | Outer/inner quantization loop |
| `MP3EncScaleFactors.pas` | Scale factor encoding |
| `MP3EncHuffman.pas` | Huffman encode tables + codeword writing |
| `MP3Layer3Encoder.pas` | `TMP3Layer3Encoder` — full pipeline |

## Want to help?

This is a great place to contribute. Start with `MP3EncBitWriter.pas` (simple
bit writer, self-contained) or `MP3EncMDCT.pas` (forward MDCT, testable in
isolation). See [CONTRIBUTING.md](../CONTRIBUTING.md).
