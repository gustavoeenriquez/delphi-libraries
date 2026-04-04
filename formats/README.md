# formats — Data Format & Signal Processing Libraries

Pure-Delphi serialization formats and DSP utilities.

## Status: Planned

This category is open for contributions.

## Landscape

| Library | Covers | License |
|---|---|---|
| [SuperObject](https://github.com/hgourvest/superobject) | JSON | MIT |
| [mORMot2](https://github.com/synopse/mORMot2) | JSON, XML, CSV, MessagePack, CBOR, Protobuf | Apache 2 |
| [OmniThreadLibrary](https://github.com/gabr42/OmniThreadLibrary) | Threading | BSD |

## Gaps worth implementing (CC0, no native Delphi library)

### Serialization formats

| Format | Difficulty | Notes |
|---|---|---|
| **TOML** | Medium | Config file format (v1.0). No native Delphi parser. Reference: [toml.io](https://toml.io). |
| **MessagePack** (standalone) | Medium | Binary JSON. mORMot covers it but as part of a large framework. |
| **CBOR** (standalone) | Medium | RFC 7049. Same situation as MessagePack. |

### Signal processing

| Utility | Difficulty | Notes |
|---|---|---|
| **Resampler** | Medium | Polyphase FIR, quality levels. No native Delphi library. Critical for converting Opus (48 kHz) to 44.1 kHz. This is the highest-priority gap in this category. |
| **FFT** | Medium | Power-of-two DFT. Several Delphi implementations exist but none are CC0 public domain. |
| **IIR/FIR filter design** | Hard | Butterworth, Chebyshev, Parks-McClellan. |

## Suggested starting point

**Resampler**: a polyphase FIR resampler with at least 3 quality presets
(low/medium/high). It is self-contained, testable with SNR metrics, and
immediately useful to the `audio/` stack (e.g. resampling Opus output).

## Want to contribute?

Follow the same structure as `audio/audio-common`:
- `src/` — `.pas` source files
- `tests/src/` — test project (`.dpr` + `.dproj`), ≥ 30 assertions
- `README.md` + `LICENSE.md` (CC0 1.0)

See the root [CONTRIBUTING.md](../CONTRIBUTING.md).
