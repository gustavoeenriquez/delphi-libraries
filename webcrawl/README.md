# webcrawl — URL to Markdown Converter

Pure-Delphi library that fetches a web page and returns its content as
Markdown-friendly plain text.  
No DLLs, no COM — only the Delphi RTL (`System.Net.HttpClient`) and the
companion `extract/` library (required for HTML→Markdown conversion).

**License: [CC0 1.0 Universal (Public Domain)](../LICENSE.md)**

---

## What it does

`TWebCrawl` performs two steps in a single call:

1. **Fetch** — downloads the URL with `THTTPClient` (HTTPS supported, redirects followed).
2. **Convert** — passes the response body through `TAiExtractLib` (from the `extract/` library) to produce clean Markdown text.

The correct converter is chosen from the HTTP `Content-Type` header:

| Content-Type | Converter used |
|---|---|
| `text/html`, `application/xhtml+xml` | HTML → Markdown (headings, tables, links, code blocks, lists) |
| `application/xml`, `text/xml` | XML → fenced code block |
| `application/json` | JSON → property table or data table |
| `text/csv` | CSV → Markdown table |
| `text/plain` | Plain text pass-through |
| *(other / bare URL with extension)* | Extension-based detection via extract/ |

> **JavaScript-rendered pages**: `TWebCrawl` fetches the raw HTTP response.
> Pages that load their content via JavaScript after the initial HTML is delivered
> will return the shell HTML only. Use a headless browser for those cases.

---

## Library paths (IDE)

In **Tools → Options → Language → Delphi → Library** add, for each target platform:

```
...\delphi-libraries\webcrawl\Src
...\delphi-libraries\extract\Src
...\delphi-libraries\extract\Src\Converters
...\delphi-libraries\pdf\Src\Core          ← required transitively for PDF support
```

---

## Quick start

```pascal
uses uWebCrawl, uExtract.Result;

var Web := TWebCrawl.Create;
try
  var R := Web.ConvertUrl('https://example.com');
  if R.Success then
  begin
    WriteLn('Title: ', R.Title);
    WriteLn(R.Markdown);
  end
  else
    WriteLn('Error: ', R.ErrorMessage);
finally
  Web.Free;
end;
```

---

## API reference

### `TWebCrawl`

```pascal
// Create with defaults (15 s timeout, standard User-Agent).
Web := TWebCrawl.Create;

// Adjust before calling ConvertUrl.
Web.Timeout   := 30000;                   // milliseconds
Web.UserAgent := 'MyBot/1.0';

// Fetch a URL and return its content as Markdown.
R := Web.ConvertUrl('https://example.com/page.html');
```

| Member | Type | Default | Description |
|---|---|---|---|
| `Timeout` | `Integer` | `15000` | HTTP response timeout in milliseconds |
| `UserAgent` | `string` | `Mozilla/5.0 (compatible; AiWebCrawl/1.0; …)` | `User-Agent` request header |
| `ConvertUrl(AUrl)` | `TConversionResult` | — | Fetch + convert |

### `TConversionResult`

```pascal
type
  TConversionResult = record
    Success     : Boolean;
    Markdown    : string;   // extracted text (empty on failure)
    Title       : string;   // page <title> when available
    ErrorMessage: string;   // reason for failure (empty on success)
  end;
```

---

## Error cases

| Scenario | `Success` | `ErrorMessage` |
|---|---|---|
| Empty URL | `False` | `'URL cannot be empty'` |
| Network error / DNS failure | `False` | `'HTTP request failed: …'` |
| Non-2xx HTTP status | `False` | `'HTTP 404: Not Found'` |
| No content in response | `False` | (from extract/ converter) |

---

## Architecture

```
TWebCrawl
  │
  ├─ THTTPClient.Get(AUrl, Body)      ← System.Net.HttpClient
  │    redirects followed, timeout applied
  │
  ├─ ExtFromContentType(Content-Type, Url) → extension string
  │
  └─ TAiExtractLib.ConvertStream(Body, TStreamInfo)
       │
       └─ THTMLConverter (or JSON/XML/CSV/… based on extension)
            └─ TConversionResult { Markdown, Title }
```

---

## Dependencies

| Dependency | Required for |
|---|---|
| Delphi RTL (`System.Net.HttpClient`) | HTTP/HTTPS fetching |
| `extract/Src` (this repo) | HTML → Markdown conversion |
| `pdf/Src/Core` (this repo) | Transitively required by extract/ (PDF support) |

---

## Project layout

```
webcrawl/
  AiWebCrawl.dpk              Delphi package
  Src/
    uWebCrawl.pas             TWebCrawl
  Tests/
    TestWebCrawl.dpr          Console test runner (32 unit tests + optional integration)
    TestWebCrawl.dproj
```

### Running the integration test

The integration test fetches `https://example.com` and is skipped by default.
Set the environment variable `WEBCRAWL_INTEGRATION=1` before running to enable it:

```bat
set WEBCRAWL_INTEGRATION=1
TestWebCrawl.exe
```
