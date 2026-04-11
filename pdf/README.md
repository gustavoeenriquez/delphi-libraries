# pdf — Pure-Delphi PDF Library

Full PDF read/write stack written entirely in Delphi.
No DLLs, no C bindings, no external dependencies beyond the Delphi RTL.

**License: [CC0 1.0 Universal (Public Domain)](../LICENSE.md)**

---

## Status: Active

| Capability | Status |
|---|:---:|
| PDF reader (1.0 – 1.7, linearized) | ✅ |
| PDF writer / creator | ✅ |
| Text extraction | ✅ |
| Image extraction | ✅ |
| Encryption (RC4 + AES-128/256) | ✅ |
| AcroForms field enumeration | ✅ |
| Annotations, Outline (bookmarks) | ✅ |
| Metadata (Info dict + XMP) | ✅ |
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
  begin
    if not Doc.Authenticate('userpassword') then
      raise Exception.Create('Wrong password');
  end;
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
  Pages: TArray<TPDFPageText>;
  I    : Integer;
begin
  Doc  := TPDFDocument.Create;
  Extr := TPDFTextExtractor.Create(Doc);
  try
    Doc.LoadFromFile('document.pdf');
    Pages := Extr.ExtractAll;
    for I := 0 to High(Pages) do
      WriteLn(Pages[I].PlainText);
  finally
    Extr.Free;
    Doc.Free;
  end;
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
    Extr.SaveAllImages('C:\Output\Images');   // saves as .jpg or .bin per page
  finally
    Extr.Free;
    Doc.Free;
  end;
end;
```

### Create a PDF from scratch

```pascal
uses uPDF.Types, uPDF.Writer;

var
  Builder : TPDFBuilder;
  Content : TPDFContentBuilder;
  PageDict: TPDFDictionary;
begin
  Builder := TPDFBuilder.Create;
  Content := TPDFContentBuilder.Create;
  try
    Builder.SetTitle('My Report');
    Builder.SetAuthor('Gustavo Enriquez');

    PageDict := Builder.AddPage(PDF_A4_WIDTH, PDF_A4_HEIGHT);

    // Draw page content
    Content.BeginText;
    Content.SetFont('Helvetica-Bold', 18);
    Content.DrawText(50, 780, 'Hello, World!');
    Content.SetFont('Helvetica', 12);
    Content.DrawText(50, 750, 'Pure-Delphi PDF generation.');
    Content.EndText;

    // Draw a rectangle
    Content.SetStrokeRGB(0.2, 0.4, 0.8);
    Content.SetLineWidth(2);
    Content.DrawRect(50, 100, 495, 600);

    // Attach content stream to the page
    PageDict.SetBytes('Contents', Content.Build);

    Builder.SaveToFile('output.pdf');
  finally
    Content.Free;
    Builder.Free;
  end;
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
| `uPDF.Crypto` | MD5, RC4, AES-128/256 primitives (used internally by encryption) |
| `uPDF.Encryption` | Standard security handler Rev 2/3/4/6 — RC4 + AES, user/owner auth |
| `uPDF.Filters` | FlateDecode, ASCIIHexDecode, ASCII85Decode, DCTDecode (JPEG passthrough) |
| `uPDF.ContentStream` | Content-stream interpreter (all path/text/color/clip/transform operators) |
| `uPDF.GraphicsState` | Full graphics-state stack: CTM, colors, fonts, line params, clipping |
| `uPDF.ColorSpace` | DeviceGray/RGB/CMYK, CalGray/RGB, ICCBased, Indexed, Pattern, Separation |
| `uPDF.Font` | Type0/1/3/TrueType + CIDFont: glyph widths, ToUnicode CMap, encoding maps |
| `uPDF.FontCMap` | CMaps: predefined identities, embedded, Adobe-CNS1/GB1/Japan1/Korea1 |
| `uPDF.Image` | `TPDFImage` — inline and XObject images; raw bytes + JPEG/Flate decode |
| `uPDF.TextExtractor` | `TPDFTextExtractor` — fragments, line grouping, plain-text export |
| `uPDF.ImageExtractor` | `TPDFImageExtractor` — enumerate and save embedded images per page |
| `uPDF.Writer` | `TPDFWriter` · `TPDFBuilder` · `TPDFContentBuilder` — full PDF serialization |
| `uPDF.Metadata` | `TPDFInfoRecord` — Info dict + XMP, date parsing |
| `uPDF.Outline` | Bookmark tree (`TPDFOutlineNode`), named destinations |
| `uPDF.Annotations` | Link, text, highlight and other annotation types |
| `uPDF.AcroForms` | AcroForm field enumeration (text, checkbox, radio, listbox, signature) |

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
| TestParser (basic open, geometry, xref, linearized) | 67 ✅ |
| TestWriter (create, metadata, content, compression) | 96 ✅ |
| TestTextExtractor (fragments, lines, plain text) | 17 ✅ |
| TestAdvanced (metadata, outline, annotations, forms, images) | ✅ |
| **Total** | **180+ ✅** |

Run the tests:

```bash
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat"
msbuild pdf\Tests\TestParser.dproj     /p:Config=Debug /p:Platform=Win64
msbuild pdf\Tests\TestWriter.dproj     /p:Config=Debug /p:Platform=Win64
msbuild pdf\Tests\TestTextExtractor.dproj /p:Config=Debug /p:Platform=Win64
msbuild pdf\Tests\TestAdvanced.dproj   /p:Config=Debug /p:Platform=Win64
```

---

## Folder layout

```
pdf/
├── Src/
│   ├── Core/      # 23 .pas units — parser through writer
│   ├── FMX/       # FMX viewer control + cache
│   └── Render/    # Skia renderer + font cache
├── Tests/
│   ├── TestParser.dpr
│   ├── TestWriter.dpr
│   ├── TestTextExtractor.dpr
│   └── TestAdvanced.dpr
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
