# webcrawl — URL to Markdown Converter

Pure-Delphi library with two complementary classes for fetching web pages
and returning their content as Markdown-friendly plain text.

| Class | Technique | JavaScript support |
|---|---|---|
| `TWebCrawl` | Direct HTTP with `THTTPClient` | ❌ static HTML only |
| `TWebDriver` | Headless Chrome via W3C WebDriver | ✅ full JS execution |

No DLLs, no COM — only the Delphi RTL and the companion `extract/` library.  
`TWebDriver` also requires `chromedriver.exe` (see [Requirements](#requirements)).

**License: [CC0 1.0 Universal (Public Domain)](../LICENSE.md)**

---

## Which class should I use?

```
Does the page load its content with JavaScript?
 │
 ├─ NO  → use TWebCrawl   (fast, ~100 ms, no extra setup)
 │
 └─ YES → use TWebDriver  (real Chrome, ~2–5 s per URL, needs chromedriver)
```

Examples of JS-rendered pages: React / Angular / Vue SPAs, dashboards with
AJAX-loaded data, pages that set `document.title` dynamically, infinite-scroll feeds.

---

## Quick start

### `TWebCrawl` — static pages

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

### `TWebDriver` — JavaScript-rendered pages

```pascal
uses uWebDriver, uExtract.Result;

var WD := TWebDriver.Create;   // searches PATH for chromedriver.exe
try
  WD.WaitMs := 2000;           // extra wait after DOM ready (ms)
  var R := WD.ConvertUrl('https://app.example.com/dashboard');
  if R.Success then
    WriteLn(R.Markdown);
finally
  WD.Free;   // closes Chrome session automatically
end;
```

### Reusing a session for multiple URLs

`TWebDriver` keeps Chrome running between calls — no need to restart it:

```pascal
var WD := TWebDriver.Create;
try
  var R1 := WD.ConvertUrl('https://site.com/page1');
  var R2 := WD.ConvertUrl('https://site.com/page2');
  var R3 := WD.ConvertUrl('https://site.com/page3');
finally
  WD.Free;
end;
```

---

## Requirements

### `TWebCrawl`

- Delphi RTL (`System.Net.HttpClient`) — included with every Delphi installation.
- `extract/` library from this repo.

### `TWebDriver`

- **Chrome** — any recent version.  
  Check yours: `"C:\Program Files\Google\Chrome\Application\chrome.exe" --version`

- **chromedriver.exe** — must match your Chrome major version.  
  Download: <https://googlechromelabs.github.io/chrome-for-testing/>

  Quick install (PowerShell — replace the version number if needed):
  ```powershell
  $ver  = "147.0.7727.138"   # match your Chrome version exactly
  $url  = "https://storage.googleapis.com/chrome-for-testing-public/$ver/win64/chromedriver-win64.zip"
  $dir  = "C:\tools\chromedriver"
  Invoke-WebRequest $url -OutFile "$env:TEMP\cd.zip" -UseBasicParsing
  Expand-Archive "$env:TEMP\cd.zip" $dir -Force
  Copy-Item "$dir\chromedriver-win64\chromedriver.exe" "$dir\chromedriver.exe"
  ```

  Then either add `C:\tools\chromedriver` to your system PATH, or pass the
  full path to the constructor:
  ```pascal
  var WD := TWebDriver.Create('C:\tools\chromedriver\chromedriver.exe');
  ```

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

## API reference

### `TWebCrawl`

```pascal
constructor Create;

property Timeout  : Integer;   // HTTP response timeout in ms  (default: 15000)
property UserAgent: string;    // User-Agent request header

function ConvertUrl(const AUrl: string): TConversionResult;
```

`ConvertUrl` selects the converter from the HTTP `Content-Type` header:

| Content-Type | Converter |
|---|---|
| `text/html`, `application/xhtml+xml` | HTML → Markdown |
| `application/json` | JSON → property/data table |
| `application/xml`, `text/xml` | XML → fenced code block |
| `text/csv` | CSV → Markdown table |
| `text/plain` | Plain text pass-through |
| *(unknown — fallback to URL extension)* | Extension-based detection |

---

### `TWebDriver`

```pascal
constructor Create(const ADriverPath: string = '');
  // ADriverPath: explicit path to chromedriver.exe.
  // Leave empty to search the running exe folder, then PATH.

property Port    : Integer;   // chromedriver TCP port    (default: 9515)
property WaitMs  : Integer;   // extra wait after DOM ready, ms (default: 1500)
property Headless: Boolean;   // hide Chrome window       (default: True)

function  ConvertUrl(const AUrl: string): TConversionResult;
procedure Close;              // stop Chrome + chromedriver (also called by Destroy)
```

**How `WaitMs` works:**  
After `document.readyState` becomes `'complete'`, the driver waits an
additional `WaitMs` milliseconds. This covers pages that kick off AJAX
requests immediately after the initial load. Raise it (e.g. 3000) for
heavy SPAs; lower it (e.g. 0) for fast static-ish pages.

---

### `TConversionResult` (shared by both classes)

```pascal
type
  TConversionResult = record
    Success     : Boolean;
    Markdown    : string;      // converted text (empty on failure)
    Title       : string;      // page <title>, when available
    ErrorMessage: string;      // failure reason (empty on success)
  end;
```

---

## Error reference

### `TWebCrawl`

| Situation | `Success` | `ErrorMessage` |
|---|---|---|
| Empty URL | `False` | `'URL cannot be empty'` |
| Network / DNS error | `False` | `'HTTP request failed: …'` |
| Non-2xx status | `False` | `'HTTP 404: Not Found'` |
| Empty response body | `False` | *(from extract/ converter)* |

### `TWebDriver`

| Situation | `Success` | `ErrorMessage` |
|---|---|---|
| Empty URL | `False` | `'URL cannot be empty'` |
| chromedriver not found | `False` | `'WebDriver error: Cannot launch chromedriver…'` |
| Chrome not installed | `False` | `'WebDriver error: …session not created…'` |
| Page load timeout | `False` | *(WaitForReady times out after 30 s)* |
| Empty rendered page | `False` | `'Empty page source for: …'` |

---

## Architecture

### `TWebCrawl`

```
TWebCrawl.ConvertUrl(url)
  │
  ├─ THTTPClient.Get(url)              ← System.Net.HttpClient (RTL)
  │    HTTPS, redirects, timeout
  │
  ├─ GetHeaderValue('Content-Type') → extension
  │
  └─ TAiExtractLib.ConvertStream(body, TStreamInfo)
       └─ THTMLConverter / TJSONConverter / …
            └─ TConversionResult
```

### `TWebDriver`

```
TWebDriver.ConvertUrl(url)
  │
  ├─ [first call] CreateProcess(chromedriver.exe --port=9515)
  │                Poll GET /status until ready
  │                POST /session  → Chrome headless session
  │
  ├─ POST /session/{id}/url           ← W3C WebDriver (JSON over HTTP)
  │    Chrome downloads + executes JavaScript
  │
  ├─ Poll: document.readyState = 'complete'
  │    + Sleep(WaitMs)
  │
  ├─ GET /session/{id}/source         ← fully-rendered DOM
  │
  └─ TAiExtractLib.ConvertStream(html, TStreamInfo('.html'))
       └─ THTMLConverter
            └─ TConversionResult
```

---

## Dependencies

| Dependency | Required for |
|---|---|
| Delphi RTL (`System.Net.HttpClient`, `System.JSON`, `WinAPI.Windows`) | Both classes |
| `extract/Src` (this repo) | HTML → Markdown conversion |
| `pdf/Src/Core` (this repo) | Transitively required by extract/ |
| `chromedriver.exe` + Chrome | `TWebDriver` only |

---

## Project layout

```
webcrawl/
  AiWebCrawl.dpk                Delphi package
  Src/
    uWebCrawl.pas               TWebCrawl  — direct HTTP fetch
    uWebDriver.pas              TWebDriver — headless Chrome / W3C WebDriver
  Tests/
    TestWebCrawl.dpr/.dproj     32 tests (unit) + 1 integration (WEBCRAWL_INTEGRATION=1)
    TestWebDriver.dpr/.dproj    10 tests (unit) + 3 integration (WEBDRIVER_INTEGRATION=1)
```

### Running integration tests

```bat
:: TWebCrawl — requires network only
set WEBCRAWL_INTEGRATION=1
TestWebCrawl.exe

:: TWebDriver — requires chromedriver.exe + Chrome
set WEBDRIVER_INTEGRATION=1
TestWebDriver.exe
```
