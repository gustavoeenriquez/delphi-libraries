# imaging — Image Codec Libraries

Pure-Delphi image decoders and encoders. No GDI+, no FreeImage DLL.

## Status: Planned

This category is open for contributions.

## Landscape

These areas are already well-covered by existing Delphi libraries:

| Library | Covers | License |
|---|---|---|
| [Image32](https://github.com/AngusJohnson/Image32) | PNG, JPEG, BMP, SVG, WebP | Boost |
| [Vampyre Imaging Library](https://github.com/galfar/imaginglib) | PNG, JPEG, GIF, TIFF, DDS | MPL 1.1 |
| [Skia4Delphi](https://github.com/skia4delphi/skia4delphi) | PNG, JPEG, WebP, AVIF | MIT |

## Gaps worth implementing (CC0, no native Delphi library)

| Format | Difficulty | Notes |
|---|---|---|
| **QOI** (Quite OK Image) | Easy | Lossless, extremely simple spec. Reference: [qoiformat.org](https://qoiformat.org). Great first contribution. |
| **TGA** reader/writer | Easy | Uncompressed + RLE. Widely used in game development. |
| **AVIF decoder** | Very hard | AV1-based. Requires AV1 bitstream parsing. |
| **WebP (lossless)** | Hard | VP8L format. Lossless only is more tractable than lossy. |

## Suggested starting point

**QOI** is the best entry point: the entire spec fits in a single web page,
the format is modern, and a complete implementation takes ~200 lines of Pascal.

## Want to contribute?

Follow the same structure as `audio/audio-common`:
- `src/` — `.pas` source files
- `tests/src/` — test project (`.dpr` + `.dproj`), ≥ 30 assertions
- `README.md` + `LICENSE.md` (CC0 1.0)

See the root [CONTRIBUTING.md](../CONTRIBUTING.md).
