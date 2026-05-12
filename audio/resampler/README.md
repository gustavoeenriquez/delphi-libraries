# resampler — Pure-Delphi Polyphase FIR Audio Resampler

Converts audio between arbitrary sample rates using a Kaiser-windowed sinc
FIR filter bank (polyphase decomposition). No DLLs, no C bindings — only the Delphi RTL.

**License: [CC0 1.0 Universal (Public Domain)](../../LICENSE.md)**

---

## Status: Active

| Capability | Status |
|---|:---:|
| Arbitrary integer rate conversion (e.g. 44100 ↔ 48000, 22050 ↔ 96000) | ✅ |
| Batch processing (`Resample`) | ✅ |
| Streaming Push/Pull API | ✅ |
| Multi-channel (mono, stereo, surround) | ✅ |
| Three quality tiers (Fast / Medium / High) | ✅ |

---

## Library path

Add to **Tools → Options → Language → Delphi → Library**:

```
...\delphi-libraries\audio\resampler\src
...\delphi-libraries\audio\src
```

---

## Algorithm

Rational resampling ratio P/Q = DstRate/GCD : SrcRate/GCD.

1. A Kaiser-windowed sinc prototype FIR filter of length `N = L×P` is designed,
   where `L` = taps per phase and cutoff `fc = 0.5 / max(P, Q)` (normalised, 1 = Nyquist).
2. The filter is decomposed into `P` polyphase subfilters `FCoeffs[phase][0..L-1]`.
3. For each output sample at index `m`, subfilter `phase = (accum) mod P` is applied
   to `L` consecutive input samples at position `(accum) div P`, where
   `accum = FAccum + m×Q` accumulates across calls for streaming continuity.

| Quality | Kaiser β | Taps/phase | Latency (approx.) |
|---|:---:|:---:|:---|
| `rqFast` | 6 | 8 | ≈ 4 output frames |
| `rqMedium` (default) | 8 | 16 | ≈ 8 output frames |
| `rqHigh` | 10 | 32 | ≈ 16 output frames |

Latency arises from the FIR filter's zero-padded history at startup. For offline
processing this is negligible; for real-time use, compensate by delaying the
output by `Latency` frames.

---

## Usage

### Batch (one-shot or chunked)

```pascal
uses AudioResampler, AudioTypes;

var
  R   : TAudioResampler;
  Src : TAudioBuffer;  // planar: Src[channel][sample]
  Dst : TAudioBuffer;
begin
  // Load Src from WAV/FLAC decoder (SampleRate=44100, Channels=2)

  R := TAudioResampler.Create(44100, 48000, 2, rqMedium);
  try
    Dst := R.Resample(Src);
    // Dst[0..1][0..OutLen-1] at 48000 Hz
  finally
    R.Free;
  end;
end;
```

Calling `Resample` repeatedly on successive chunks is safe — the resampler
preserves filter history and phase state between calls.

### Streaming (Push / Pull)

```pascal
R := TAudioResampler.Create(44100, 48000, 2);
try
  while ReadNextChunk(Chunk) do
  begin
    R.Push(Chunk);
    while R.Available > 0 do
      ProcessOutput(R.Pull(512));  // pull up to 512 frames at a time
  end;
finally
  R.Free;
end;
```

---

## API reference

### `TAudioResampler`

| Member | Description |
|---|---|
| `Create(SrcRate, DstRate, Channels [, Quality])` | Build filter bank for the given conversion |
| `Resample(Input [, FrameCount])` | Resample batch; returns `TAudioBuffer` |
| `Push(Input [, FrameCount])` | Queue input frames |
| `Pull([MaxFrames])` | Dequeue available output frames |
| `Available` | Frames queued but not yet pulled |
| `SrcRate / DstRate / Channels / Quality` | Read-only properties |
| `Latency` | Taps-per-phase; approximate intro latency in output frames |

### `TResamplerQuality`

```pascal
type TResamplerQuality = (rqFast, rqMedium, rqHigh);
```

---

## Output length formula

For `InLen` input frames with phase accumulator `FAccum ∈ [0, FQ-1]`:

```
OutLen = (FP × InLen − 1 − FAccum) div FQ + 1
```

where `FP = DstRate / GCD`, `FQ = SrcRate / GCD`. The average ratio over many
batches converges to `DstRate / SrcRate`.

---

## Test coverage

| Suite | Tests |
|---|:---:|
| ResamplerTests (construction, lengths, DC/zero, RMS, continuity, streaming, quality) | 30 ✅ |

```bash
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat"
msbuild audio\resampler\tests\src\ResamplerTests.dproj /p:Config=Debug /p:Platform=Win64
```
