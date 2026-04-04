# Delphi Audio Libraries

A collection of pure-Delphi audio codecs and utilities — no DLLs, no C bindings,
no external dependencies. Everything compiles and runs with stock Delphi on
Windows, Linux, and any platform the RTL supports.

All code is **CC0 1.0 Universal (Public Domain)**. Use it however you like.

---

## What is implemented

### Core layer — `audio-common`

Shared types and primitives used by every library above it.

| Unit | Responsibility |
|---|---|
| `AudioTypes.pas` | `TAudioBuffer` (planar `Single [-1..1]`), `TAudioInfo`, `TAudioDecodeResult` |
| `AudioBitReader.pas` | MSB-first and LSB-first bit reader used by all stream decoders |
| `AudioSampleConv.pas` | PCM ↔ float conversions: Int8/16/24/32/Float32/64 ↔ `Single` |
| `AudioCRC.pas` | CRC-8 (FLAC headers), CRC-16 (FLAC frames), CRC-32 (Ogg pages) |

### Format libraries

| Library | Decoder | Encoder | Notes |
|---|:---:|:---:|---|
| `wav-codec` | ✅ | ✅ | PCM 8/16/24/32, Float32/64, EXTENSIBLE multichannel |
| `flac-codec` | ✅ | ✅ | Lossless, all block sizes, all channel counts, stereo modes |
| `ogg-container` | ✅ | ✅ | Ogg page reader/writer, packet segmentation, CRC-32 |
| `vorbis-decoder` | ✅ | — | Ogg Vorbis I — Floor 0/1, all residue types, full VQ |
| `opus-decoder` | ✅ | — | SILK + CELT + Hybrid modes, 48 kHz, mono/stereo (RFC 6716) |
| `mp3-decoder` | ✅ | — | MPEG 1/2/2.5, Layer III, 8–320 kbps, all sample rates |

### Unified API — `audio-codec`

`IAudioDecoder` interface + factory that auto-detects WAV/FLAC/Vorbis/Opus/MP3
from a stream or file path. One call, any format.

### Test coverage

| Suite | Tests | Status |
|---|:---:|:---:|
| AudioCommonTests | 78 | ✅ |
| WAVCodecTests | 70 | ✅ |
| FLACCodecTests | 99 | ✅ |
| FLACEncoderTests | 60 | ✅ |
| OggContainerTests | 69 | ✅ |
| VorbisDecoderTests | 119 | ✅ |
| OpusDecoderTests | 85 | ✅ |
| MP3DecoderTests | 66 | ✅ |
| AudioCodecTests | 30 | ✅ |
| **Total** | **676** | **✅ all pass** |

---

## What is missing — call for contributors

This is where the community can help. Below is the honest gap list ordered by
estimated impact:

### Encoders

| Format | Difficulty | Notes |
|---|---|---|
| **Vorbis encoder** | Hard | Requires psychoacoustic model + Huffman codebook building. Reference: [libvorbis](https://xiph.org/vorbis/doc/libvorbis/) |
| **Opus encoder** | Very hard | SILK + CELT hybrid is large. Possible path: port only CELT CBR as a starting point. Reference: [RFC 6716](https://datatracker.ietf.org/doc/html/rfc6716) |
| **MP3 encoder** | Hard | Architecture and plan exist (see `mp3-encoder/`). Blocker: Huffman encode tables from the packed minimp3 tree. Reference: ISO/IEC 11172-3, [shine](https://github.com/toots/shine) |

### Missing decoders / formats

| Format | Difficulty | Notes |
|---|---|---|
| **AAC decoder** | Very hard | MPEG-4 / HE-AAC. Substantial bit-parsing work. |
| **AIFF reader** | Easy | Close to WAV in structure; reuse `audio-common` primitives. |
| **MP4/M4A container** | Medium | ISO base media file format; needed to read AAC from files. |

### Utilities

| Utility | Difficulty | Notes |
|---|---|---|
| **Resampler** | Medium | Polyphase FIR, quality levels (low/medium/high). No native Delphi library exists for this. |
| **Audio normalization** | Easy | Peak + RMS normalization on `TAudioBuffer`. |
| **Ogg Vorbis encoder** | Hard | Depends on Vorbis encoder above. |
| **Unified encoder API** | Medium | Mirror of `IAudioDecoder` — `IAudioEncoder` with format-specific adapters. |

### How to contribute

1. **Fork** the repository and create a branch: `git checkout -b feature/aiff-reader`
2. Follow the same unit structure as existing libraries (see `audio-common` and `wav-codec` as minimal examples)
3. Add a test project under `your-library/tests/src/` — aim for ≥ 30 assertions
4. All code must be CC0 1.0 (public domain). Do not include GPL or LGPL code.
5. Submit a pull request. CI will build and run all test suites.

If you are unsure where to start, the **AIFF reader** and the **resampler** are
the most self-contained tasks. The resampler in particular would benefit many
use cases (e.g. converting 48 kHz Opus output to 44.1 kHz for playback).

See [CONTRIBUTING.md](./CONTRIBUTING.md) for coding style and PR checklist.

---

## How to use — native Delphi

### Requirements

- Delphi 12 Athens (or Delphi 11 Alexandria with minor adjustments)
- No external packages. No `{$IFDEF}` guards needed for Windows vs Linux.
- Add the `src/` folders you need to your project's library path.

---

### 1. Decode any audio file (unified API)

```pascal
uses AudioTypes, AudioCodec;

var
  Dec: IAudioDecoder;
  Buf: TAudioBuffer;
begin
  Dec := CreateAudioDecoderFromFile('music.flac'); // also works with .wav .ogg .opus .mp3
  if (Dec = nil) or not Dec.Ready then
  begin
    WriteLn('Unsupported format or file not found');
    Exit;
  end;

  WriteLn(Format('Format: %d Hz, %d ch', [Dec.Info.SampleRate, Dec.Info.Channels]));

  while Dec.Decode(Buf) = adrOK do
  begin
    // Buf.Samples  = number of sample frames in this block
    // Buf.Ch[0]    = PSingle pointing to left channel  (or mono)
    // Buf.Ch[1]    = PSingle pointing to right channel (nil if mono)
    ProcessAudio(Buf);
  end;
end;
```

The factory auto-detects format from magic bytes — the file extension is not
used. Passing a `TStream` instead of a filename also works:

```pascal
var S := TFileStream.Create('music.mp3', fmOpenRead or fmShareDenyWrite);
Dec := CreateAudioDecoder(S, {OwnsStream=}True);
```

---

### 2. Decode specific formats directly

#### WAV

```pascal
uses AudioTypes, WAVReader;

var R := TWAVReader.Create;
try
  if R.Open('track.wav') then
    while R.Decode(Buf) = adrOK do
      ProcessAudio(Buf);
finally
  R.Free;
end;
```

#### FLAC

```pascal
uses AudioTypes, FLACStreamDecoder;

var D := TFLACStreamDecoder.Create('album.flac');
try
  WriteLn(D.StreamInfo.TotalSamples);
  while D.Decode(Buf) = adrOK do
    ProcessAudio(Buf);
  D.SeekToSample(44100); // seek to 1 second
finally
  D.Free;
end;
```

#### Ogg Vorbis

```pascal
uses AudioTypes, OggPageReader, VorbisDecoder;

var S := TFileStream.Create('audio.ogg', fmOpenRead);
var Ogg := TOggPageReader.Create(S, True);
var V := TVorbisDecoder.Create(Ogg);
try
  while V.Decode(Buf) = adrOK do
    ProcessAudio(Buf);
finally
  V.Free; // frees Ogg and S too (ownership chain)
end;
```

#### Opus

```pascal
uses AudioTypes, OpusDecoder;

var D := TOpusDecoder.Create('podcast.opus');
try
  while D.Decode(Buf) = adrOK do
    ProcessAudio(Buf);
finally
  D.Free;
end;
```

#### MP3

```pascal
uses AudioTypes, MP3Layer3;

var D := TMP3Layer3Decoder.Create;
try
  // TMP3Layer3Decoder reads from MP3Frame / TBsT;
  // for file-level decode use the IAudioDecoder factory above.
finally
  D.Free;
end;
```

---

### 3. Write / encode audio

#### Write a WAV file

```pascal
uses AudioTypes, WAVWriter;

var W := TWAVWriter.Create('output.wav', 44100, 2, woPCM16);
try
  // Buf is a TAudioBuffer you filled from some source
  W.Write(Buf);
  W.Finalize;
finally
  W.Free;
end;
```

#### Encode FLAC (lossless)

```pascal
uses AudioTypes, FLACStreamEncoder;

var E := TFLACStreamEncoder.Create('output.flac', 44100, 2, {bits=}16);
try
  while HaveSamples do
  begin
    FillBuffer(Buf);    // fill TAudioBuffer with planar Single [-1..1]
    E.Write(Buf);
  end;
  E.Finalize;           // patches STREAMINFO with TotalSamples
finally
  E.Free;
end;
```

#### Transcode WAV → FLAC (10 lines)

```pascal
uses AudioTypes, WAVReader, FLACStreamEncoder;

var
  R: TWAVReader;
  E: TFLACStreamEncoder;
  Buf: TAudioBuffer;
begin
  R := TWAVReader.Create;
  R.Open('input.wav');
  E := TFLACStreamEncoder.Create('output.flac',
         R.Format.SampleRate, R.Format.Channels, R.Format.BitsPerSample);
  try
    while R.Decode(Buf) = adrOK do E.Write(Buf);
    E.Finalize;
  finally
    E.Free; R.Free;
  end;
end;
```

---

### 4. TAudioBuffer in detail

`TAudioBuffer` is the universal sample container throughout this library.

```pascal
type
  TAudioBuffer = record
    Ch     : array[0..7] of PSingle;  // planar channels, index 0..Channels-1
    Samples: Integer;                 // sample frames in this block
  end;
```

Samples are normalised `Single` in the range `[-1.0 .. 1.0]`. Planar layout
means all samples for channel 0 come first, then channel 1, etc. — no
interleaving. This matches what most DSP code expects.

To interleave for playback (e.g. `waveOut` or `WASAPI`):

```pascal
procedure InterleaveStereo(const Buf: TAudioBuffer; out PCM: TArray<SmallInt>);
var
  I: Integer;
begin
  SetLength(PCM, Buf.Samples * 2);
  for I := 0 to Buf.Samples - 1 do
  begin
    PCM[I * 2]     := Round(Buf.Ch[0][I] * 32767);
    PCM[I * 2 + 1] := Round(Buf.Ch[1][I] * 32767);
  end;
end;
```

---

### 5. Adding library paths in Delphi

In **Tools → Options → Language → Delphi → Library** add one entry per library
you use (per platform):

```
E:\your-path\delphi-libraries\audio-common\src
E:\your-path\delphi-libraries\wav-codec\src
E:\your-path\delphi-libraries\flac-codec\src
E:\your-path\delphi-libraries\ogg-container\src
E:\your-path\delphi-libraries\vorbis-decoder\src
E:\your-path\delphi-libraries\opus-decoder\src
E:\your-path\delphi-libraries\mp3-decoder\src
E:\your-path\delphi-libraries\audio-codec\src
```

You only need the libraries you actually `uses`. `audio-common` is always
required as it provides the base types.

---

## Repository structure

```
delphi-libraries/
├── audio-common/          # Base types, bit reader, sample conv, CRC
├── wav-codec/             # WAV reader + writer
├── flac-codec/            # FLAC decoder + encoder
├── ogg-container/         # Ogg page reader + writer
├── vorbis-decoder/        # Ogg Vorbis I decoder
├── opus-decoder/          # Ogg Opus decoder (SILK + CELT)
├── mp3-decoder/           # MP3 Layer III decoder (MPEG 1/2/2.5)
├── mp3-encoder/           # MP3 encoder — work in progress
├── audio-codec/           # Unified IAudioDecoder API + factory
└── docs/                  # Build instructions, architecture notes
```

Each library follows the same layout:
```
library-name/
├── src/           # .pas source files
├── tests/src/     # test project (.dpr + .dproj)
├── README.md      # library-specific docs
└── LICENSE.md     # CC0 1.0
```

---

## Building

```bash
# Load Delphi environment variables first
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat"

# Build a single library test suite
msbuild flac-codec\tests\src\FLACCodecTests.dproj /p:Config=Release /p:Platform=Win64

# Run the tests
Win64\Release\FLACCodecTests.exe
```

See [docs/BUILD.md](./docs/BUILD.md) for the full build guide including Win32,
Linux64, and troubleshooting `F2613: Unit not found` errors.

---

## License

All code in this repository is **CC0 1.0 Universal (Public Domain)**.

You may use, copy, modify, and distribute it for any purpose, commercial or
non-commercial, without asking permission or providing attribution (though
attribution is appreciated).

https://creativecommons.org/publicdomain/zero/1.0/

### Upstream attributions

| Library | Origin | License |
|---|---|---|
| `mp3-decoder` | Translated from [minimp3](https://github.com/lieff/minimp3) by lieff | CC0 1.0 |
| All other libraries | Written from scratch against public standards | CC0 1.0 |

---

## References

- ISO/IEC 11172-3 — MPEG-1 Audio (MP3)
- ISO/IEC 14496-3 — MPEG-4 Audio (AAC/Opus)
- [FLAC format specification](https://xiph.org/flac/format.html)
- [Ogg bitstream format — RFC 3533](https://datatracker.ietf.org/doc/html/rfc3533)
- [Vorbis I specification](https://xiph.org/vorbis/doc/Vorbis_I_spec.html)
- [Opus codec — RFC 6716](https://datatracker.ietf.org/doc/html/rfc6716)
- [Ogg Opus — RFC 7845](https://datatracker.ietf.org/doc/html/rfc7845)
