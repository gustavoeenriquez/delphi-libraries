# compression — Compression Libraries

Pure-Delphi data compression codecs. No zlib.dll, no external DLLs.

## Status: Planned

This category is open for contributions.

## Landscape

| Library | Covers | License |
|---|---|---|
| [ZLib](https://docwiki.embarcadero.com/Libraries/en/System.ZLib) | Deflate / zlib / gzip | Built into Delphi RTL |
| [synapse](https://github.com/grijjy/GrijjyFoundation) | Various | Mixed |

## Gaps worth implementing (CC0, no native Delphi library)

| Algorithm | Difficulty | Notes |
|---|---|---|
| **LZ4** | Medium | Extremely fast block + frame format. Reference: [lz4.org](https://lz4.org). No complete native Delphi port exists. |
| **Zstandard (zstd)** | Hard | Modern general-purpose compressor (Facebook). Reference: [RFC 8878](https://datatracker.ietf.org/doc/html/rfc8878). |
| **LZMA / XZ** | Hard | Used in `.xz`, `.7z`. Reference: [7-zip LZMA spec](https://www.7-zip.org/sdk.html). |
| **Brotli** | Hard | HTTP compression (RFC 7932). Reference: [brotli spec](https://datatracker.ietf.org/doc/html/rfc7932). |
| **Snappy** | Medium | Google's fast compressor. Simple format, good starting point. |

## Suggested starting point

**LZ4 block format** is the most approachable: the algorithm is simple,
the spec is short, and there is a strong demand in the Delphi community.
Start with the block format before tackling the frame format.

## Want to contribute?

Follow the same structure as `audio/audio-common`:
- `src/` — `.pas` source files
- `tests/src/` — test project (`.dpr` + `.dproj`), ≥ 30 assertions
- `README.md` + `LICENSE.md` (CC0 1.0)

See the root [CONTRIBUTING.md](../CONTRIBUTING.md).
