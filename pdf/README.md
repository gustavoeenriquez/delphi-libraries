# pdf — Pure-Delphi PDF Library

Full PDF read/write/manipulation stack written entirely in Delphi.
No DLLs, no C bindings, no external dependencies beyond the Delphi RTL.

**License: [CC0 1.0 Universal (Public Domain)](../LICENSE.md)**

---

## Status: Active

| Capability | Status |
|---|:---:|
| PDF reader (1.0 – 1.7, linearized) | ✅ |
| PDF writer / creator (incl. standard fonts, word-wrap, tables) | ✅ |
| **TTF/OTF font embedding (Identity-H, CIDFontType2, ISO 32000 §9.9)** | ✅ |
| Text extraction | ✅ |
| Image extraction | ✅ |
| Encryption (RC4 + AES-128/256) | ✅ |
| AcroForms field enumeration | ✅ |
| AcroForms fill + appearance stream generation | ✅ |
| Annotations, Outline (bookmarks) | ✅ |
| Metadata (Info dict + XMP) | ✅ |
| Page operations (split, merge, reorder, rotate) | ✅ |
| Text search with bounding boxes | ✅ |
| Watermark (text + image, overlay/underlay) | ✅ |
| Table of contents / bookmarks builder | ✅ |
| Digital signature verification (PKCS#7 byte-range hash) | ✅ |
| Scan detection (text vs. raster heuristic) | ✅ |
| FMX visual viewer (Skia) | ✅ |

---

## Library paths (IDE)

In **Tools → Options → Language → Delphi → Library** add the paths you need:

```
...\delphi-libraries\pdf\Src\Core
...\delphi-libraries\pdf\Src\FMX      (only for the FMX viewer control)
...\delphi-libraries\pdf\Src\Render   (only for the Skia renderer)
```

For most use cases only `Src\Core` is required.

---

## Usage examples

### Open a PDF and read its pages

```pascal
uses uPDF.Types, uPDF.Document;

var Doc := TPDFDocument.Create;
try
  Doc.LoadFromFile('report.pdf');
  WriteLn(Format('%d pages, PDF %.1f',
    [Doc.PageCount, Doc.Version.Major + Doc.Version.Minor / 10]));
  WriteLn('Title: ', Doc.Title);
finally
  Doc.Free;
end;
```

### Open an encrypted PDF

```pascal
uses uPDF.Types, uPDF.Document;

var Doc := TPDFDocument.Create;
try
  Doc.LoadFromFile('protected.pdf');
  if Doc.IsEncrypted then
    if not Doc.Authenticate('userpassword') then
      raise Exception.Create('Wrong password');
  // read pages normally ...
finally
  Doc.Free;
end;
```

### Extract all text

```pascal
uses uPDF.Types, uPDF.Document, uPDF.TextExtractor;

var
  Doc  : TPDFDocument;
  Extr : TPDFTextExtractor;
begin
  Doc  := TPDFDocument.Create;
  Extr := TPDFTextExtractor.Create(Doc);
  try
    Doc.LoadFromFile('document.pdf');
    for var Page in Extr.ExtractAll do
      WriteLn(Page.PlainText);
  finally
    Extr.Free;
    Doc.Free;
  end;
end;
```

### Search text with bounding boxes

```pascal
uses uPDF.Types, uPDF.Document, uPDF.TextSearch;

var Doc := TPDFDocument.Create;
try
  Doc.LoadFromFile('document.pdf');
  var S := TPDFTextSearch.Create(Doc);
  try
    for var M in S.Search('invoice') do
      WriteLn(Format('Page %d  (%.1f, %.1f, %.1f, %.1f)',
        [M.PageIndex + 1, M.Bounds.Left, M.Bounds.Bottom,
         M.Bounds.Right, M.Bounds.Top]));
  finally
    S.Free;
  end;
finally
  Doc.Free;
end;
```

### Extract embedded images

```pascal
uses uPDF.Types, uPDF.Document, uPDF.ImageExtractor;

var
  Doc  : TPDFDocument;
  Extr : TPDFImageExtractor;
begin
  Doc  := TPDFDocument.Create;
  Extr := TPDFImageExtractor.Create(Doc);
  try
    Doc.LoadFromFile('slides.pdf');
    Extr.SaveAllImages('C:\Output\Images');
  finally
    Extr.Free;
    Doc.Free;
  end;
end;
```

### Embed a TrueType / OpenType font

```pascal
uses uPDF.Types, uPDF.Writer, uPDF.TTFParser, uPDF.TTFSubset, uPDF.EmbeddedFont;

var
  FontData  : TBytes;
  Parser    : TTTFParser;
  Subsetter : TTTFSubsetter;
  GIDs      : TArray<Word>;
  Builder   : TPDFBuilder;
  Content   : TPDFContentBuilder;
  Page      : TPDFDictionary;
  Font      : TTTFEmbeddedFont;
begin
  FontData := TFile.ReadAllBytes('C:\Windows\Fonts\arial.ttf');

  Parser := TTTFParser.Create(FontData);
  try
    Parser.Parse;   // raises EPDFError if embedding is restricted by the font vendor

    // Collect the glyph IDs for every character you intend to use.
    // Here we include the full printable ASCII range (space … ~).
    SetLength(GIDs, 95);
    for var I := 0 to 94 do
      GIDs[I] := Parser.CharToGlyph(Cardinal(32 + I));

    Subsetter := TTTFSubsetter.Create(Parser, GIDs);
    try
      Builder := TPDFBuilder.Create;
      Content := TPDFContentBuilder.Create;
      try
        Builder.SetTitle('Embedded Font Demo');
        Page := Builder.AddPage(PDF_A4_WIDTH, PDF_A4_HEIGHT);

        // Register the embedded font on this page; get back the font object
        // for EncodeTextHex and MeasureText.  'EF1' is the resource name.
        Font := Builder.AddEmbeddedFont(Page, 'EF1', Parser, Subsetter);

        // Text must be encoded as big-endian glyph-ID hex strings.
        // Font.EncodeTextHex handles the Unicode → subset-GID mapping.
        Content.BeginText;
        Content.SetFont('EF1', 24);
        Content.SetTextMatrix(1, 0, 0, 1, 50, 750);
        Content.ShowTextHex(Font.EncodeTextHex('Hello, World!'));

        // MeasureText returns the rendered width in points at the given size.
        var W := Font.MeasureText('Hello, World!', 24);
        Content.SetFont('EF1', 10);
        Content.SetTextMatrix(1, 0, 0, 1, 50, 720);
        Content.ShowTextHex(Font.EncodeTextHex(
          Format('Width: %.1f pt  |  Glyphs in subset: %d', [W, Font.GlyphCount])));
        Content.EndText;

        var Stm := TPDFStream.Create;
        Stm.SetRawData(Content.Build);
        Page.SetValue('Contents', Stm);

        Builder.SaveToFile('embedded.pdf');
      finally
        Content.Free;
        Builder.Free;
      end;
    finally
      Subsetter.Free;
    end;
  finally
    Parser.Free;
  end;
end;
```

**How it works under the hood**

Each embedded font produces exactly five PDF objects following ISO 32000 §9.9:

```
Type0 dict  →  CIDFontType2 dict  →  FontDescriptor dict
                                   →  FontFile2 stream  (FlateDecode subset TTF)
             →  ToUnicode CMap stream
```

The `BaseFont` / `FontName` entries carry a six-letter subset tag
(`AAAAAA+ArialMT`), and the FontFile2 stream includes a `/Length1` entry
with the uncompressed TTF size — both required by the spec.

---

### Create a PDF from scratch

```pascal
uses uPDF.Types, uPDF.Writer;

var
  Builder : TPDFBuilder;
  Content : TPDFContentBuilder;
  Page    : TPDFDictionary;
begin
  Builder := TPDFBuilder.Create;
  Content := TPDFContentBuilder.Create;
  try
    Builder.SetTitle('My Report');
    Builder.SetAuthor('Gustavo Enriquez');

    Page := Builder.AddPage(PDF_A4_WIDTH, PDF_A4_HEIGHT);

    // Register standard PDF Type1 fonts — no font files needed
    Builder.AddStandardFont(Page, 'FH',  'Helvetica');
    Builder.AddStandardFont(Page, 'FHB', 'Helvetica-Bold');

    Content.BeginText;
    Content.SetFont('FHB', 18);
    Content.DrawText(50, 780, 'Hello, World!');
    Content.SetFont('FH', 12);
    Content.DrawText(50, 750, 'Pure-Delphi PDF generation.');
    Content.EndText;

    Content.SetStrokeRGB(0.2, 0.4, 0.8);
    Content.SetLineWidth(2);
    Content.DrawRect(50, 100, 495, 600);

    Page.SetBytes('Contents', Content.Build);
    Builder.SaveToFile('output.pdf');
  finally
    Content.Free;
    Builder.Free;
  end;
end;
```

### Word-wrap long text into a column

```pascal
uses uPDF.Types, uPDF.Writer;

var
  Builder : TPDFBuilder;
  Content : TPDFContentBuilder;
  Page    : TPDFDictionary;
  NextY   : Single;
begin
  Builder := TPDFBuilder.Create;
  Content := TPDFContentBuilder.Create;
  try
    Page := Builder.AddPage(PDF_A4_WIDTH, PDF_A4_HEIGHT);
    Builder.AddStandardFont(Page, 'F1', 'Helvetica');

    // DrawTextWrapped returns the baseline Y of the last line rendered,
    // so the next element can be placed directly below.
    NextY := Content.DrawTextWrapped(
      50, 750,            // top-left origin
      495,                // column width (A4 - 50pt margins each side)
      16,                 // line height (baseline-to-baseline)
      'Long paragraph text that will be broken at word boundaries to ' +
      'fit within the specified column width automatically.',
      'F1', 'Helvetica',  // resource name + base name for measurement
      12,                 // font size
      0                   // 0=left, 1=center, 2=right
    );

    Page.SetBytes('Contents', Content.Build);
    Builder.SaveToFile('wrapped.pdf');
  finally
    Content.Free;
    Builder.Free;
  end;
end;
```

### Draw a table with a header row

```pascal
uses uPDF.Types, uPDF.Writer;

var
  Builder : TPDFBuilder;
  Content : TPDFContentBuilder;
  Page    : TPDFDictionary;
begin
  Builder := TPDFBuilder.Create;
  Content := TPDFContentBuilder.Create;
  try
    Page := Builder.AddPage(PDF_A4_WIDTH, PDF_A4_HEIGHT);
    Builder.AddStandardFont(Page, 'F1', 'Helvetica');

    // Column widths and row heights in points
    const ColW: array[0..2] of Single = (180, 80, 100);
    const RowH: array[0..3] of Single = (22, 18, 18, 18);
    const Data: array[0..11] of string = (
      'Description', 'Qty', 'Amount',   // header row
      'Widget A',    '10',  '$50.00',
      'Widget B',    '3',   '$37.50',
      'Total',       '',    '$87.50'
    );

    Content.DrawTableGrid(
      50, 700,           // top-left corner
      ColW, RowH, Data,
      'F1', 'Helvetica', // font resource + base name
      10,                // font size
      4, 3,              // cell padding X / Y
      1                  // 1 header row (light-gray background)
    );

    Page.SetBytes('Contents', Content.Build);
    Builder.SaveToFile('table.pdf');
  finally
    Content.Free;
    Builder.Free;
  end;
end;
```

### Embed a JPEG image when creating a PDF

```pascal
uses uPDF.Types, uPDF.Writer;

var
  Builder : TPDFBuilder;
  Content : TPDFContentBuilder;
  Page    : TPDFDictionary;
  JPEG    : TBytes;
  ImgName : string;
begin
  Builder := TPDFBuilder.Create;
  Content := TPDFContentBuilder.Create;
  try
    Page := Builder.AddPage(PDF_A4_WIDTH, PDF_A4_HEIGHT);

    // Load a JPEG file into bytes
    JPEG := TFile.ReadAllBytes('photo.jpg');

    // Register it as an XObject resource on this page (480 x 320 px)
    ImgName := Builder.AddJPEGImage(Page, JPEG, 480, 320);

    // Draw the image at position (50, 500), scaled to 200 x 133 pt
    Content.DrawXObject(ImgName, 50, 500, 200, 133);

    Page.SetBytes('Contents', Content.Build);
    Builder.SaveToFile('with-image.pdf');
  finally
    Content.Free;
    Builder.Free;
  end;
end;
```

### Create a PDF with bookmarks (table of contents)

```pascal
uses uPDF.Types, uPDF.Writer, uPDF.TOC;

var
  Builder : TPDFBuilder;
  TOC     : TPDFTOCBuilder;
  Ch1     : TPDFTOCEntry;
begin
  Builder := TPDFBuilder.Create;
  TOC     := TPDFTOCBuilder.Create;
  try
    // Add pages ...
    Builder.AddPage; Builder.AddPage; Builder.AddPage;

    // Build bookmark tree
    Ch1 := TOC.Add('Chapter 1', 0);
    Ch1.AddChild('Section 1.1', 0);
    Ch1.AddChild('Section 1.2', 1);
    TOC.Add('Chapter 2', 2);

    Builder.TOCBuilder := TOC;
    Builder.SaveToFile('bookmarked.pdf');
  finally
    TOC.Free;
    Builder.Free;
  end;
end;
```

### Apply a text watermark to an existing PDF

```pascal
uses uPDF.Types, uPDF.Document, uPDF.Watermark;

var Doc := TPDFDocument.Create;
try
  Doc.LoadFromFile('original.pdf');
  TPDFWatermark.ApplyText(Doc, 'CONFIDENTIAL',
    TFileStream.Create('watermarked.pdf', fmCreate));
finally
  Doc.Free;
end;
```

### Split / merge pages

```pascal
uses uPDF.Types, uPDF.Document, uPDF.PageOperations;

var Doc := TPDFDocument.Create;
try
  Doc.LoadFromFile('big.pdf');

  // Extract pages 2..5 into a new file
  TPDFPageOperations.Split(Doc, 1, 4, 'pages-2-to-5.pdf');

  // Delete page 3 (keep all others)
  var Keep: TArray<Integer>;
  SetLength(Keep, Doc.PageCount - 1);
  var J := 0;
  for var I := 0 to Doc.PageCount - 1 do
    if I <> 2 then begin Keep[J] := I; Inc(J); end;
  TPDFPageOperations.ExtractPages(Doc, Keep, 'without-page3.pdf');
finally
  Doc.Free;
end;
```

### Fill AcroForm fields

```pascal
uses uPDF.Types, uPDF.Document, uPDF.AcroForms.Fill;

var Doc := TPDFDocument.Create;
try
  Doc.LoadFromFile('form.pdf');
  var F := TPDFFormFiller.Create(Doc);
  try
    F.LoadForm;
    F.SetTextField('FullName', 'John Doe');
    F.SetCheckBox('AgreeTerms', True);
    F.SetRadioButton('Gender', 'Male');
    F.SetChoice('Country', 'Mexico');
    F.Save('filled.pdf');
  finally
    F.Free;
  end;
finally
  Doc.Free;
end;
```

### Verify digital signatures

```pascal
uses uPDF.Types, uPDF.Document, uPDF.Signatures, System.TypInfo;

var FS := TFileStream.Create('signed.pdf', fmOpenRead);
try
  var Doc := TPDFDocument.Create;
  try
    Doc.LoadFromStream(FS);
    FS.Seek(0, soBeginning);
    for var Sig in TPDFSignatureVerifier.Verify(Doc, FS) do
      WriteLn(Format('Field: %s  Signer: %s  Algorithm: %s  Status: %s',
        [Sig.FieldName, Sig.SignerName, Sig.HashAlgorithm,
         GetEnumName(TypeInfo(TPDFHashStatus), Ord(Sig.HashStatus))]));
  finally
    Doc.Free;
  end;
finally
  FS.Free;
end;
```

### Detect whether a PDF is scanned

```pascal
uses uPDF.Types, uPDF.Document, uPDF.ScanDetector;

var Doc := TPDFDocument.Create;
try
  Doc.LoadFromFile('unknown.pdf');
  var D := TPDFScanDetector.Create(Doc);
  try
    if D.IsScanned then
      WriteLn('Scanned document — OCR may be needed');
    for var R in D.AnalyzeDocument do
      WriteLn(Format('Page %d — scanned=%s  coverage=%.0f%%',
        [R.PageIndex + 1, BoolToStr(R.IsScanned, True),
         R.ImageCoverage * 100]));
  finally
    D.Free;
  end;
finally
  Doc.Free;
end;
```

### FMX visual viewer

```pascal
uses uPDF.Types, uPDF.Document, uPDF.Viewer.Control;

// Drop a TPDFViewerControl on your FMX form, then:
PDFViewerControl1.LoadFromFile('document.pdf');
PDFViewerControl1.ZoomFit;
```

---

## Unit map — `Src/Core`

| Unit | Responsibility |
|---|---|
| `uPDF.Types` | Primitive types, `TPDFVersion`, `TPDFRect`, save-mode enum, A4/Letter constants |
| `uPDF.Errors` | Exception hierarchy (`EPDFError`, `EPDFParseError`, `EPDFEncryptionError`, …) |
| `uPDF.Objects` | Full object model: Null, Boolean, Integer, Real, String, Name, Array, Dictionary, Stream, Reference |
| `uPDF.Lexer` | Low-level tokenizer — all token types, hex strings, inline-image data |
| `uPDF.XRef` | Cross-reference table + XRef stream; linearized and damaged-PDF recovery |
| `uPDF.Parser` | High-level parser: indirect-object resolver, xref rebuilder |
| `uPDF.Document` | `TPDFDocument` (open/create/save) · `TPDFPage` (geometry, resources, content stream) |
| `uPDF.Crypto` | MD5, SHA-1, SHA-256/384/512, RC4, AES-128/256 primitives |
| `uPDF.Encryption` | Standard security handler Rev 2/3/4/6 — RC4 + AES, user/owner auth |
| `uPDF.Filters` | FlateDecode, ASCIIHex, ASCII85, LZW, RunLength, DCT (JPEG passthrough) |
| `uPDF.ContentStream` | Content-stream interpreter (all path/text/color/clip/transform operators) |
| `uPDF.GraphicsState` | Full graphics-state stack: CTM, colors, fonts, line params, clipping |
| `uPDF.ColorSpace` | DeviceGray/RGB/CMYK, CalGray/RGB, ICCBased, Indexed, Pattern, Separation |
| `uPDF.Font` | Type0/1/3/TrueType + CIDFont: glyph widths, ToUnicode CMap, encoding maps |
| `uPDF.FontCMap` | CMaps: predefined identities, embedded, Adobe-CNS1/GB1/Japan1/Korea1 |
| `uPDF.Image` | `TPDFImage` — inline and XObject images; raw bytes + JPEG/Flate decode |
| `uPDF.TextExtractor` | `TPDFTextExtractor` — fragments, line grouping, plain-text export |
| `uPDF.ImageExtractor` | `TPDFImageExtractor` — enumerate and save embedded images per page |
| `uPDF.TTFParser` | Binary TrueType/OpenType parser: tables `head`, `hhea`, `OS/2`, `cmap` (format 4), `hmtx`, `loca`, `glyf`; `CharToGlyph`, advance widths, embedding-permission check (`fsType`) |
| `uPDF.TTFSubset` | Glyph subsetter: expands composite glyphs, rebuilds `glyf`/`loca`/`hmtx`/`cmap`/`maxp`, patches `checkSumAdjustment` in `head` |
| `uPDF.EmbeddedFont` | PDF font emitter: builds the 5-object Type0/CIDFontType2 structure, `EncodeTextHex` (Unicode → subset GID → hex), `MeasureText`, ToUnicode CMap generator |
| `uPDF.Writer` | `TPDFWriter` · `TPDFBuilder` · `TPDFContentBuilder` — full PDF serialization with image and TTF font embedding |
| `uPDF.Metadata` | `TPDFInfoRecord` — Info dict + XMP, date parsing |
| `uPDF.Outline` | Bookmark tree (`TPDFOutlineNode`), named destinations |
| `uPDF.Annotations` | Link, text, highlight and other annotation types |
| `uPDF.AcroForms` | AcroForm field enumeration (text, checkbox, radio, listbox, signature) |
| `uPDF.AcroForms.Fill` | `TPDFFormFiller` — fill fields + generate appearance streams (/AP /N) |
| `uPDF.PageCopy` | `TPDFObjectCopier` — deep-clone pages and all reachable objects between documents |
| `uPDF.PageOperations` | `TPDFPageOperations` — split, merge, extract, delete, reorder, rotate |
| `uPDF.TextSearch` | `TPDFTextSearch` — substring search with per-match bounding boxes |
| `uPDF.Watermark` | `TPDFWatermark` — text and JPEG image watermarks (overlay or underlay) |
| `uPDF.TOC` | `TPDFTOCBuilder` — builds /Outlines tree for new documents |
| `uPDF.Signatures` | `TPDFSignatureVerifier` — PKCS#7 byte-range hash verification |
| `uPDF.ScanDetector` | `TPDFScanDetector` — heuristic to identify scanned-image pages |

## Unit map — `Src/FMX` + `Src/Render`

| Unit | Responsibility |
|---|---|
| `uPDF.Render.Types` | `TPDFRenderTarget`, tile size, resolution constants |
| `uPDF.Render.FontCache` | Platform font resolver + glyph-metric cache |
| `uPDF.Render.Skia` | Page rasterizer backed by **Skia4Delphi** — paths, text, images |
| `uPDF.Viewer.Cache` | Tile + page-bitmap LRU cache |
| `uPDF.Viewer.Control` | `TPDFViewerControl` — scrollable FMX control, zoom, page navigation |

---

## Test coverage

| Suite | Tests |
|---|:---:|
| TestParser (open, geometry, xref, linearized) | 67 ✅ |
| TestWriter (create, metadata, content, compression, images, TOC) | 96 ✅ |
| TestTextExtractor (fragments, lines, plain text) | 17 ✅ |
| TestAdvanced (metadata, outline, annotations, forms, images, search, signatures) | ✅ |
| TestTTFParser (tables, CharToGlyph, metrics, embedding permission) | 51 ✅ |
| TestTTFEmbeddedFont (widths, EncodeTextHex, CMap, subset bytes, PDF objects) | 51 ✅ |
| TestPDFEmbeddedWriter (structure, content encoding, multi-page, conformance) | 40 ✅ |
| **Total** | **322+ ✅** |

Run the tests:

```bash
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat"
msbuild pdf\Tests\TestParser.dproj             /p:Config=Debug /p:Platform=Win64
msbuild pdf\Tests\TestWriter.dproj             /p:Config=Debug /p:Platform=Win64
msbuild pdf\Tests\TestTextExtractor.dproj      /p:Config=Debug /p:Platform=Win64
msbuild pdf\Tests\TestAdvanced.dproj           /p:Config=Debug /p:Platform=Win64
msbuild pdf\Tests\TestTTFParser.dproj          /p:Config=Debug /p:Platform=Win64
msbuild pdf\Tests\TestTTFEmbeddedFont.dproj    /p:Config=Debug /p:Platform=Win64
msbuild pdf\Tests\TestPDFEmbeddedWriter.dproj  /p:Config=Debug /p:Platform=Win64
```

---

## Folder layout

```
pdf/
├── Src/
│   ├── Core/      # 34 .pas units — parser through writer + TTF embedding + tooling
│   ├── FMX/       # FMX viewer control + cache
│   └── Render/    # Skia renderer + font cache
├── Tests/
│   ├── TestParser.dpr
│   ├── TestWriter.dpr
│   ├── TestTextExtractor.dpr
│   ├── TestAdvanced.dpr
│   ├── TestTTFParser.dpr          # TTF binary parser
│   ├── TestTTFEmbeddedFont.dpr    # Glyph subsetter + PDF object emitter
│   ├── TestPDFEmbeddedWriter.dpr  # End-to-end writer integration + conformance
│   └── DemoEmbeddedFont.dpr       # Visual demo: 3-page PDF with Arial + Courier New
├── Demo/
│   ├── PDFDemo.dpr           # console: open + inspect
│   ├── DemoReport.dpr        # console: generate a report PDF
│   └── DemoSpecialChars.dpr  # console: Unicode / special characters
├── FMXViewer/
│   └── PDFViewerApp.dpr      # FMX desktop viewer demo
├── AiPdf.dpk                 # Delphi design-time package
└── PDFLib.dpr                # Standalone project (no package)
```

---

## References

- [PDF 1.7 Reference — ISO 32000-1](https://www.adobe.com/content/dam/acom/en/devnet/pdf/pdfs/PDF32000_2008.pdf)
- [PDF 2.0 — ISO 32000-2](https://www.iso.org/standard/75839.html)
- [Skia4Delphi](https://github.com/skia4delphi/skia4delphi) — required for `Src/Render` and `Src/FMX`
