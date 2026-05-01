# extract — Multi-Format Document-to-Text Converter

Pure-Delphi library that extracts readable text from thirteen document formats
and returns it as Markdown-friendly plain text.  
No DLLs, no COM, no external dependencies beyond the Delphi RTL and the
companion `pdf/` library (required only for PDF support).

**License: [CC0 1.0 Universal (Public Domain)](../LICENSE.md)**

---

## Supported formats

| Format | Extensions | Output |
|--------|-----------|--------|
| Plain text | `.txt` `.log` `.text` `.bat` `.sh` `.py` `.pas` … | Pass-through |
| Markdown | `.md` `.markdown` | Pass-through |
| CSV / TSV | `.csv` `.tsv` | Markdown table |
| JSON | `.json` `.geojson` | Flat object → property table; array of objects → data table; nested → fenced block |
| XML | `.xml` `.rss` `.atom` `.svg` `.xsl` | Fenced code block |
| INI / config | `.ini` `.cfg` `.inf` `.conf` `.env` | Sections as `##` headings; keys as table |
| RTF | `.rtf` | Strips control words; outputs paragraph text |
| HTML | `.html` `.htm` `.xhtml` | Headings, tables, lists, links, blockquotes, code blocks |
| Word (OOXML) | `.docx` `.docm` | Headings, paragraphs, tables; deleted text skipped |
| Excel (OOXML) | `.xlsx` `.xlsm` `.xltx` `.xltm` | Each worksheet as a Markdown table (max 500 rows × 50 cols) |
| PowerPoint (OOXML) | `.pptx` `.pptm` `.ppsx` `.ppsm` | Each slide as `## Slide N`; separated by `---` |
| PDF | `.pdf` | Text extraction via the `pdf/` library; supports encrypted files |
| EPUB | `.epub` | Reads OPF spine order; each chapter as `## Chapter N` |

---

## Library paths (IDE)

In **Tools → Options → Language → Delphi → Library** add, for each target platform:

```
...\delphi-libraries\extract\Src
...\delphi-libraries\extract\Src\Converters
...\delphi-libraries\pdf\Src\Core          ← required only for PDF support
```

---

## Quick start

### Convert a file

```pascal
uses uExtract.Engine, uExtract.Result;

var Engine := TMarkItDown.Create;   // all 13 converters registered by default
try
  var R := Engine.ConvertFile('C:\Docs\report.xlsx');
  if R.Success then
    WriteLn(R.Markdown)
  else
    WriteLn('Error: ', R.ErrorMessage);
finally
  Engine.Free;
end;
```

### Convert a stream

```pascal
uses uExtract.Engine, uExtract.Result, uExtract.StreamInfo;

var Engine := TMarkItDown.Create;
try
  var Stream := TFileStream.Create('brochure.pdf', fmOpenRead or fmShareDenyWrite);
  try
    var Info := TStreamInfo.FromFile('brochure.pdf');
    var R    := Engine.ConvertStream(Stream, Info);
    if R.Success then
    begin
      WriteLn('Title: ', R.Title);    // available for PDF and HTML
      WriteLn(R.Markdown);
    end;
  finally
    Stream.Free;
  end;
finally
  Engine.Free;
end;
```

### Stream without a filename (magic-byte detection)

When no extension is available the engine inspects the first bytes of the
stream to identify the format automatically:

```pascal
// extension is empty → engine falls back to magic-byte detection
var Info := TStreamInfo.From('', '');
var R    := Engine.ConvertStream(MyStream, Info);
```

| Magic bytes | Detected format |
|-------------|----------------|
| `%PDF-` | PDF |
| `PK\x03\x04` | ZIP-based (DOCX / XLSX / PPTX / EPUB) |
| `<?` | XML |
| `<` | HTML |

---

## API reference

### `TMarkItDown`

```pascal
// All 13 built-in converters registered (default).
Engine := TMarkItDown.Create;

// Empty engine — add only what you need.
Engine := TMarkItDown.Create(False {ARegisterDefaults});
Engine.RegisterConverter(TCSVConverter.Create);
Engine.RegisterConverter(THTMLConverter.Create);

// Convert a file on disk.
R := Engine.ConvertFile('path\to\file.docx');

// Convert any stream (caller retains ownership of the stream).
R := Engine.ConvertStream(AStream, AInfo);
```

The engine owns all registered converters and frees them on `Destroy`.  
Converters are sorted by `Priority` (ascending) so lower-priority numbers win.

---

### `TConversionResult`

```pascal
type
  TConversionResult = record
    Success     : Boolean;
    Markdown    : string;   // extracted text (empty on failure)
    Title       : string;   // document title when available (PDF, HTML)
    ErrorMessage: string;   // reason for failure (empty on success)

    class function Ok  (const AMarkdown: string;
                        const ATitle: string = ''): TConversionResult; static;
    class function Fail(const AError: string): TConversionResult; static;
  end;
```

---

### `TStreamInfo`

Metadata passed to the engine to select and drive a converter.

```pascal
// From a file path — extension and filename filled automatically.
Info := TStreamInfo.FromFile('report.csv');

// Explicit extension (dot optional) + MIME type.
Info := TStreamInfo.From('.json', 'application/json');
Info := TStreamInfo.From('json',  '');   // dot added automatically

// No extension — engine uses magic-byte detection.
Info := TStreamInfo.From('', '');
```

---

### `TDocumentConverter` — writing your own

Subclass this to add a new format:

```pascal
type
  TDocumentConverter = class abstract
    // Return True when this converter handles the given format.
    function Accepts(const AInfo: TStreamInfo): Boolean; virtual; abstract;

    // Perform the conversion. Stream is positioned at offset 0.
    function Convert(AStream: TStream;
                     const AInfo: TStreamInfo): TConversionResult; virtual; abstract;

    // Lower value = higher priority (wins over higher values).
    // Default: 10.0  Built-in specific converters: 0.0  Text fallback: 10.0
    function Priority: Double; virtual;
  end;
```

#### Example

```pascal
type
  TMarkdownLogConverter = class(TDocumentConverter)
  public
    function Accepts(const AInfo: TStreamInfo): Boolean; override;
    function Convert(AStream: TStream;
                     const AInfo: TStreamInfo): TConversionResult; override;
    function Priority: Double; override;
  end;

function TMarkdownLogConverter.Priority: Double;
begin
  Result := 0.0;  // run before the generic text fallback
end;

function TMarkdownLogConverter.Accepts(const AInfo: TStreamInfo): Boolean;
begin
  Result := AInfo.HasExtension('.log');
end;

function TMarkdownLogConverter.Convert(AStream: TStream;
  const AInfo: TStreamInfo): TConversionResult;
var
  Reader: TStreamReader;
  Text  : string;
begin
  Reader := TStreamReader.Create(AStream, TEncoding.UTF8, True);
  try
    Text := Reader.ReadToEnd.Trim;
  finally
    Reader.Free;
  end;
  if Text = '' then
    Result := TConversionResult.Fail('Empty log file')
  else
    Result := TConversionResult.Ok('```' + sLineBreak + Text + sLineBreak + '```');
end;

// Register before converting:
Engine.RegisterConverter(TMarkdownLogConverter.Create);
```

---

## Architecture

```
TMarkItDown
  │
  ├─ RegisterConverter(TDocumentConverter)   sorted by Priority (ascending)
  │
  ├─ ConvertFile(path)
  │    └─ ConvertStream(TFileStream, TStreamInfo.FromFile(path))
  │
  └─ ConvertStream(stream, info)
       │
       ├─ if info.Extension = '' → DetectMagicExt(stream)
       │
       └─ first converter where Accepts(info) = True → Convert(stream, info)
```

### Open XML formats

DOCX, XLSX, PPTX, and EPUB are ZIP archives containing XML parts.  
The shared unit `uExtract.OpenXML` provides:

| Function | Description |
|----------|-------------|
| `OXScanXML` | Minimal event-driven XML scanner (no DOM allocation) |
| `OXReadEntry` | Read a ZIP entry as a UTF-8 string |
| `OXAttr` | Extract an attribute value from a raw attribute string |
| `OXDecode` | Decode XML character entities |

This avoids `System.XML` and any third-party XML library entirely.

---

## Project layout

```
extract/
  AiExtract.dpk               Delphi package (open in IDE to install)
  Src/
    uExtract.Result.pas       TConversionResult
    uExtract.StreamInfo.pas   TStreamInfo
    uExtract.Converter.pas    TDocumentConverter (abstract base)
    uExtract.Engine.pas       TMarkItDown (engine + converter registry)
    uExtract.OpenXML.pas      Shared XML/ZIP helpers for OOXML and EPUB
    Converters/
      uExtract.Conv.Text.pas
      uExtract.Conv.Markdown.pas
      uExtract.Conv.CSV.pas
      uExtract.Conv.JSON.pas
      uExtract.Conv.XML.pas
      uExtract.Conv.INI.pas
      uExtract.Conv.RTF.pas
      uExtract.Conv.HTML.pas
      uExtract.Conv.DOCX.pas
      uExtract.Conv.XLSX.pas
      uExtract.Conv.PPTX.pas
      uExtract.Conv.PDF.pas
      uExtract.Conv.EPUB.pas
  Tests/
    TestExtract.dpr           Console test runner (190 tests)
    TestExtract.dproj
    Fixtures/                 Static test input files
```

---

## Dependencies

| Dependency | Required for |
|-----------|-------------|
| Delphi RTL (`System.*`) | Everything |
| `pdf/Src/Core` (this repo) | `.pdf` conversion only |

All other converters depend exclusively on the Delphi RTL.
