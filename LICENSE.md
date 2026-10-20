# License

## Collection License: CC0 1.0 Universal (Public Domain)

All libraries in this repository are dedicated to the public domain under the **CC0 1.0 Universal** license,
except `audio/opus-decoder` and `audio/opus-encoder`: they are derivative works of libopus
(Copyright Xiph.Org, Skype Limited and others) and are distributed under the libopus BSD 3-clause
license, whose full text is in their README files.

Third-party data that is **not** covered by CC0:

- `audio/g729-codec/src/G729Tables.pas`: the numeric codebook tables of ITU-T G.729 / G.729 Annex A
  and Annex B (LSP, MA predictor, gain codebooks and maps, b30 filter, SID/VAD tables), taken from
  `TAB_LD8A.C` and `tab_dtx.c` of the ITU-T G.729 software package (Copyright (c) 1996 AT&T,
  France Telecom, NTT, Universite de Sherbrooke, Rockwell International). Only the numbers are
  reproduced, because bit-stream interoperability with G.729 requires these exact values; the
  copyright on them, if any, stays with their authors. All the code of `audio/g729-codec` is CC0.
- `audio/g722-codec/samples/` (`inpsp.bin`, `codspw.cod`, `outsp1.bin`, `outsp2.bin`,
  `outsp3.bin`): test vectors of the ITU-T Software Tool Library (G.191), G.722 module
  (copyright CNET / France Telecom), redistributed unmodified under the ITU-T Software Tools
  General Public License (`audio/g722-codec/samples/LICENSE-ITU-STL.md`, notice in
  `audio/g722-codec/samples/NOTICE.md`).

https://creativecommons.org/publicdomain/zero/1.0/

### Full Legal Text

To the extent possible under law, the authors of these libraries have dedicated all copyright and related and neighboring rights to this software to the public domain worldwide. This software is distributed without any warranty.

### What You Can Do

✅ **Commercial use** — Use these libraries in commercial products without royalties  
✅ **Modification** — Modify, adapt, and extend the code  
✅ **Redistribution** — Redistribute the original or modified code  
✅ **Private use** — Use in closed-source projects  
✅ **No attribution required** — You don't need to credit the authors (but appreciated!)

### What You Cannot Do

❌ There are no restrictions. This is the public domain.

---

## Individual Library Licenses

All libraries in this collection maintain the CC0 1.0 Universal dedication. However, some libraries are based on other open-source projects:

### mp3-decoder

- **Based on**: minimp3 by lieff
- **Original license**: CC0 1.0 Universal (Public Domain)
- **Original repository**: https://github.com/lieff/minimp3
- **Our license**: CC0 1.0 Universal (Public Domain)

The translation to Delphi maintains the same public domain dedication as the original.

---

## No Warranty

**THESE LIBRARIES ARE PROVIDED "AS IS" WITHOUT ANY WARRANTY, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, AND NONINFRINGEMENT.**

The authors assume no liability for any claim, damages, or other liability arising from or related to the use of these libraries.

---

## Attribution (Optional)

While not legally required, we appreciate attribution. If you use these libraries, consider:

1. **In your code**:
   ```pascal
   { Based on Delphi Libraries Collection
     https://github.com/your-username/delphi-libraries
     License: CC0 1.0 Universal (Public Domain) }
   ```

2. **In your documentation**:
   ```
   This project uses the Delphi Libraries Collection, specifically the MP3 Decoder.
   See https://github.com/your-username/delphi-libraries
   ```

3. **In your README**:
   - Add a link to this repository
   - Mention the specific libraries you use

---

## About CC0 1.0 Universal

CC0 is the most permissive license available. It allows you to:
- Copy, modify, distribute, and perform the work
- Make commercial and private use
- All without asking permission or providing attribution

More info: https://creativecommons.org/publicdomain/zero/1.0/

---

## License Compatibility

CC0 1.0 Universal is compatible with:
- ✅ MIT License
- ✅ Apache 2.0
- ✅ GPL (both v2 and v3)
- ✅ BSD License
- ✅ ISC License
- ✅ Any other open-source license

You can use these libraries in projects with other licenses without conflict.

---

**Last Updated:** 2026-04-02
