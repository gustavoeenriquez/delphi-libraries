# extract/ — Multi-format Document to Markdown Converter

Pure-Delphi library inspired by [markitdown](https://github.com/microsoft/markitdown).  
Converts documents of various formats into Markdown text, optimised for LLM ingestion and text analysis pipelines.

## Quick start

```pascal
uses uExtract.Engine, uExtract.Result;

var MD := TMarkItDown.Create;        // registers all built-in converters
try
  var R := MD.ConvertFile('report.csv');
  if R.Success then
    WriteLn(R.Markdown)
  else
    WriteLn('Error: ', R.ErrorMessage);
finally
  MD.Free;
end;
```

You can also convert any `TStream`:

```pascal
var S := TMemoryStream.Create;
// ... fill stream ...
var R := MD.ConvertStream(S, TStreamInfo.From('.json', 'application/json'));
```

## Supported formats (Fase 1)

| Format | Extensions | Output |
| --- | --- | --- |
| Plain text | `.txt` `.log` | passthrough |
| Markdown | `.md` `.markdown` `.mdx` | passthrough |
| CSV / TSV | `.csv` `.tsv` | Markdown table |
| JSON | `.json` `.jsonl` `.geojson` | table or fenced block |
| XML | `.xml` `.rss` `.atom` `.opml` `.svg` `.xsd` | fenced block |

### CSV / TSV
- Auto-detects delimiter: comma, semicolon, or tab.
- RFC 4180 quoting (`"field with, comma"`, `""escaped quote""`).
- First row is header; output capped at 500 rows.

### JSON
- **Flat object** → two-column property table.
- **Array of flat objects** → multi-column data table (up to 500 rows).
- **Nested / complex** → pretty-printed fenced ` ```json ` block.

### XML
- Files ≤ 50 KB → verbatim fenced ` ```xml ` block.
- Larger files → truncated block with notice.
- RSS/Atom/OPML structure parsing planned for Fase 2.

## Extensibility

Register a custom converter by subclassing `TDocumentConverter`:

```pascal
type
  TMyConverter = class(TDocumentConverter)
  public
    function Accepts(const AInfo: TStreamInfo): Boolean; override;
    function Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult; override;
    function Priority: Double; override;   // 0.0 = first, 10.0 = last
  end;

// Register (engine takes ownership)
MD.RegisterConverter(TMyConverter.Create);
```

Use `TMarkItDown.Create(False)` to start with no built-in converters and add only what you need.

## Roadmap

| Phase | Formats | Status |
| --- | --- | --- |
| **1** | Text, Markdown, CSV, JSON, XML | ✅ done |
| **2** | HTML, RTF, INI | planned |
| **3** | DOCX, XLSX, PPTX (Open XML = ZIP + XML) | planned |
| **4** | PDF (via `pdf/` library), EPUB | planned |

## Project files

| File | Purpose |
| --- | --- |
| `AiExtract.dpk` | Delphi package (open in IDE to compile) |
| `Src/` | Source units |
| `Src/Converters/` | One unit per format |
| `Tests/TestExtract.dpr` | Console test runner (all phases) |
| `Tests/Fixtures/` | Test input files |

## Library paths

Add to your IDE Library Path:
```
<repo>\extract\Src
<repo>\extract\Src\Converters
```

## License

CC0 1.0 Universal — public domain.
