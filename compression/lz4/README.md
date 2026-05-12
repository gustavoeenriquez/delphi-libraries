# lz4 — Pure-Delphi LZ4 Codec

Single-unit implementation of the LZ4 block and frame formats.
No DLLs, no C bindings — only the Delphi RTL.

**License: [CC0 1.0 Universal (Public Domain)](../../LICENSE.md)**

---

## Status: Active

| Capability | Status |
|---|:---:|
| LZ4 block compress | ✅ |
| LZ4 block decompress | ✅ |
| LZ4 frame compress (v1.6, 64 KB blocks, content checksum) | ✅ |
| LZ4 frame decompress | ✅ |
| Compatible with liblz4 / lz4 CLI tool | ✅ |

---

## Library path

Add to **Tools → Options → Language → Delphi → Library**:

```
...\delphi-libraries\compression\lz4\src
```

---

## Usage

### Block format (raw, no headers)

```pascal
uses uLZ4;

var
  Original   : TBytes;
  Compressed : TBytes;
  Recovered  : TBytes;
begin
  Original   := TEncoding.UTF8.GetBytes('Hello, World! Hello, World! Hello!');

  // Compress
  Compressed := LZ4BlockCompressBytes(Original);

  // Decompress (caller must supply the original length)
  Recovered  := LZ4BlockDecompressBytes(Compressed, Length(Original));
end;
```

For pointer-based usage (e.g. streaming or zero-copy):

```pascal
var
  Src, Dst : TBytes;
  CompLen  : Integer;
begin
  SetLength(Dst, LZ4BlockBound(Length(Src)));
  CompLen := LZ4BlockCompress(@Src[0], Length(Src), @Dst[0], Length(Dst));
  SetLength(Dst, CompLen);
end;
```

### Frame format (liblz4-compatible)

```pascal
uses uLZ4;

var Data, Compressed, Recovered: TBytes;
begin
  Data       := TFile.ReadAllBytes('input.bin');
  Compressed := LZ4FrameCompress(Data);
  TFile.WriteAllBytes('input.bin.lz4', Compressed);

  Recovered := LZ4FrameDecompress(Compressed);
  // Recovered = Data
end;
```

The frame format output is compatible with:
- `lz4 -d input.bin.lz4` (official CLI tool)
- liblz4 `LZ4F_decompress`

---

## API reference

| Function | Description |
|---|---|
| `LZ4BlockBound(Len)` | Safe upper bound for compressed output |
| `LZ4BlockCompress(ASrc, ASrcLen, ADst, AMaxDst)` | Compress block (pointer); returns compressed size or 0 |
| `LZ4BlockDecompress(ASrc, ASrcLen, ADst, AMaxDst)` | Decompress block (pointer); raises `ELZ4Error` on error |
| `LZ4BlockCompressBytes(ASrc)` | Compress to `TBytes` |
| `LZ4BlockDecompressBytes(ASrc, AOriginalLen)` | Decompress to `TBytes` |
| `LZ4FrameCompress(ASrc)` | Encode to LZ4 frame `TBytes` |
| `LZ4FrameDecompress(ASrc)` | Decode an LZ4 frame; raises `ELZ4Error` on bad magic or corrupt data |

---

## Test coverage

| Suite | Tests |
|---|:---:|
| TestLZ4 (block + frame compress/decompress, error paths) | 30 ✅ |

```bash
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat"
msbuild compression\lz4\Tests\TestLZ4.dproj /p:Config=Debug /p:Platform=Win64
```

---

## References

- [LZ4 Block Format](https://lz4.github.io/lz4/lz4_Block_format.html)
- [LZ4 Frame Format](https://lz4.github.io/lz4/lz4_Frame_format.html)
- [xxHash specification](https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md)
