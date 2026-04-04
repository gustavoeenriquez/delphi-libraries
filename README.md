# Delphi Libraries Collection

A growing collection of pure-Delphi libraries covering audio codecs,
compression, cryptography, image formats, and data serialization.

No DLLs. No C bindings. No external dependencies.
Everything compiles with stock Delphi on Windows, Linux, and any RTL-supported platform.

**License: [CC0 1.0 Universal (Public Domain)](./LICENSE.md)** — use however you like.

---

## Categories

| Category | Status | Description |
|---|:---:|---|
| [audio/](./audio/) | ✅ Active | WAV, FLAC, Vorbis, Opus, MP3 decoders + WAV & FLAC encoders |
| [compression/](./compression/) | 🚧 Planned | LZ4, Zstd, LZMA, Brotli |
| [crypto/](./crypto/) | 🚧 Planned | ChaCha20-Poly1305, Argon2id, X25519 |
| [imaging/](./imaging/) | 🚧 Planned | QOI, TGA, WebP lossless |
| [formats/](./formats/) | 🚧 Planned | TOML, resampler, FFT |

---

## Audio — what is implemented

### Core layer — `audio/audio-common`

| Unit | Responsibility |
|---|---|
| `AudioTypes.pas` | `TAudioBuffer` (planar `Single [-1..1]`), `TAudioInfo`, `TAudioDecodeResult` |
| `AudioBitReader.pas` | MSB-first and LSB-first bit reader |
| `AudioSampleConv.pas` | PCM ↔ float conversions: Int8/16/24/32/Float32/64 ↔ `Single` |
| `AudioCRC.pas` | CRC-8 (FLAC headers), CRC-16 (FLAC frames), CRC-32 (Ogg pages) |

### Format libraries

| Library | Decoder | Encoder | Notes |
|---|:---:|:---:|---|
| `audio/wav-codec` | ✅ | ✅ | PCM 8/16/24/32, Float32/64, EXTENSIBLE multichannel |
| `audio/flac-codec` | ✅ | ✅ | Lossless, all block sizes, all channel counts, stereo modes |
| `audio/ogg-container` | ✅ | ✅ | Ogg page reader/writer, packet segmentation, CRC-32 |
| `audio/vorbis-decoder` | ✅ | — | Ogg Vorbis I — Floor 0/1, all residue types, full VQ |
| `audio/opus-decoder` | ✅ | — | SILK + CELT + Hybrid, 48 kHz, mono/stereo (RFC 6716) |
| `audio/mp3-decoder` | ✅ | — | MPEG 1/2/2.5, Layer III, 8–320 kbps, all sample rates |
| `audio/audio-codec` | ✅ | — | Unified `IAudioDecoder` factory (auto-detect format) |
| `audio/mp3-encoder` | 🚧 | 🚧 | Architecture ready, implementation in progress |

### Test coverage

| Suite | Tests |
|---|:---:|
| AudioCommonTests | 78 ✅ |
| WAVCodecTests | 70 ✅ |
| FLACCodecTests | 99 ✅ |
| FLACEncoderTests | 60 ✅ |
| OggContainerTests | 69 ✅ |
| VorbisDecoderTests | 119 ✅ |
| OpusDecoderTests | 85 ✅ |
| MP3DecoderTests | 66 ✅ |
| AudioCodecTests | 30 ✅ |
| **Total** | **676 ✅** |

---

## How to use — native Delphi

### Requirements

- Delphi 12 Athens (or Delphi 11 Alexandria)
- No external packages. Add the `src/` folders you need to your project's library path.

### Adding library paths in the IDE

In **Tools → Options → Language → Delphi → Library** add one entry per library
you use (per platform):

```
...\delphi-libraries\audio\audio-common\src
...\delphi-libraries\audio\wav-codec\src
...\delphi-libraries\audio\flac-codec\src
...\delphi-libraries\audio\ogg-container\src
...\delphi-libraries\audio\vorbis-decoder\src
...\delphi-libraries\audio\opus-decoder\src
...\delphi-libraries\audio\mp3-decoder\src
...\delphi-libraries\audio\audio-codec\src
```

`audio-common` is always required. Add only the libraries you actually `uses`.

### Decode any audio file (unified API)

```pascal
uses AudioTypes, AudioCodec;

var
  Dec: IAudioDecoder;
  Buf: TAudioBuffer;
begin
  Dec := CreateAudioDecoderFromFile('music.flac'); // .wav .ogg .opus .mp3 also work
  if (Dec = nil) or not Dec.Ready then Exit;

  WriteLn(Format('%d Hz, %d ch', [Dec.Info.SampleRate, Dec.Info.Channels]));
  while Dec.Decode(Buf) = adrOK do
    ProcessAudio(Buf);
end;
```

### Decode specific formats directly

```pascal
// WAV
var R := TWAVReader.Create;
R.Open('track.wav');
while R.Decode(Buf) = adrOK do ProcessAudio(Buf);

// FLAC — with seek
var D := TFLACStreamDecoder.Create('album.flac');
while D.Decode(Buf) = adrOK do ProcessAudio(Buf);
D.SeekToSample(44100); // jump to 1 second

// Ogg Vorbis
var V := TVorbisDecoder.Create(TOggPageReader.Create(TFileStream.Create('audio.ogg', fmOpenRead), True));
while V.Decode(Buf) = adrOK do ProcessAudio(Buf);

// Opus
var O := TOpusDecoder.Create('podcast.opus');
while O.Decode(Buf) = adrOK do ProcessAudio(Buf);
```

### Encode audio

```pascal
// Write WAV
var W := TWAVWriter.Create('output.wav', 44100, 2, woPCM16);
W.Write(Buf); W.Finalize;

// Encode FLAC
var E := TFLACStreamEncoder.Create('output.flac', 44100, 2, {bits=}16);
while HaveSamples do begin FillBuffer(Buf); E.Write(Buf); end;
E.Finalize;
```

### Transcode WAV → FLAC (10 lines)

```pascal
uses AudioTypes, WAVReader, FLACStreamEncoder;

var R := TWAVReader.Create;
R.Open('input.wav');
var E := TFLACStreamEncoder.Create('output.flac',
           R.Format.SampleRate, R.Format.Channels, R.Format.BitsPerSample);
try
  while R.Decode(Buf) = adrOK do E.Write(Buf);
  E.Finalize;
finally
  E.Free; R.Free;
end;
```

### TAudioBuffer layout

```pascal
type
  TAudioBuffer = record
    Ch     : array[0..7] of PSingle;  // planar channels, index 0..Channels-1
    Samples: Integer;                 // sample frames in this block
  end;
```

Samples are normalised `Single` in `[-1.0 .. 1.0]`, planar (all channel-0
samples first, then channel-1, etc.). To interleave for `waveOut`/WASAPI:

```pascal
for I := 0 to Buf.Samples - 1 do
begin
  PCM[I * 2]     := Round(Buf.Ch[0][I] * 32767);
  PCM[I * 2 + 1] := Round(Buf.Ch[1][I] * 32767);
end;
```

---

## Contributing

We welcome contributions in any category. The most impactful open tasks are:

| Task | Category | Difficulty |
|---|---|---|
| Resampler (polyphase FIR) | formats | Medium |
| LZ4 block encoder/decoder | compression | Medium |
| QOI image codec | imaging | Easy |
| TOML parser | formats | Medium |
| MP3 encoder | audio | Hard |
| Vorbis encoder | audio | Hard |
| ChaCha20-Poly1305 AEAD | crypto | Medium |

**How to contribute:**
1. Fork the repo and create a branch
2. Add your library under the appropriate category folder
3. Include a test project with ≥ 30 assertions
4. All code must be **CC0 1.0** — no GPL/LGPL
5. Submit a pull request

See [CONTRIBUTING.md](./CONTRIBUTING.md) for coding style, naming conventions,
and the full PR checklist. Each category folder has its own `README.md` with
more detail on what's needed and relevant references.

---

## Repository structure

```
delphi-libraries/
├── audio/                 # Audio codecs and utilities
│   ├── audio-common/      #   Base types, bit reader, CRC, sample conv
│   ├── wav-codec/         #   WAV reader + writer
│   ├── flac-codec/        #   FLAC decoder + encoder
│   ├── ogg-container/     #   Ogg page reader + writer
│   ├── vorbis-decoder/    #   Ogg Vorbis I decoder
│   ├── opus-decoder/      #   Ogg Opus decoder (SILK + CELT)
│   ├── mp3-decoder/       #   MP3 Layer III decoder (MPEG 1/2/2.5)
│   ├── mp3-encoder/       #   MP3 encoder (work in progress)
│   └── audio-codec/       #   Unified IAudioDecoder API + factory
├── compression/           # Compression codecs (planned)
├── crypto/                # Cryptographic primitives (planned)
├── imaging/               # Image codecs (planned)
├── formats/               # Data formats + signal processing (planned)
└── docs/                  # Shared build and architecture docs
```

Each library follows the same layout:
```
category/library-name/
├── src/           # .pas source files
├── tests/src/     # test project (.dpr + .dproj)
├── README.md
└── LICENSE.md     # CC0 1.0
```

---

## Building

```bash
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat"
msbuild audio\flac-codec\tests\src\FLACCodecTests.dproj /p:Config=Release /p:Platform=Win64
Win64\Release\FLACCodecTests.exe
```

See [docs/BUILD.md](./docs/BUILD.md) for the full guide.

---

## License

All code is **CC0 1.0 Universal (Public Domain)**.
https://creativecommons.org/publicdomain/zero/1.0/

### Upstream attributions

| Library | Origin | License |
|---|---|---|
| `audio/mp3-decoder` | Translated from [minimp3](https://github.com/lieff/minimp3) | CC0 1.0 |
| All other libraries | Written from scratch against public standards | CC0 1.0 |

---

## References

- [FLAC format specification](https://xiph.org/flac/format.html)
- [Ogg bitstream — RFC 3533](https://datatracker.ietf.org/doc/html/rfc3533)
- [Vorbis I specification](https://xiph.org/vorbis/doc/Vorbis_I_spec.html)
- [Opus codec — RFC 6716](https://datatracker.ietf.org/doc/html/rfc6716)
- [Ogg Opus — RFC 7845](https://datatracker.ietf.org/doc/html/rfc7845)
- ISO/IEC 11172-3 — MPEG-1 Audio (MP3)
