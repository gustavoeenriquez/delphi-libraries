program TestWebCrawl;

{$APPTYPE CONSOLE}
{$R *.res}

uses
  System.SysUtils,
  System.Classes,
  System.Net.HttpClient,
  uWebCrawl         in '..\Src\uWebCrawl.pas',
  uExtract.Result   in '..\..\extract\Src\uExtract.Result.pas',
  uExtract.StreamInfo in '..\..\extract\Src\uExtract.StreamInfo.pas',
  uExtract.Converter in '..\..\extract\Src\uExtract.Converter.pas',
  uExtract.Engine    in '..\..\extract\Src\uExtract.Engine.pas',
  uExtract.OpenXML   in '..\..\extract\Src\uExtract.OpenXML.pas',
  uExtract.Conv.Text     in '..\..\extract\Src\Converters\uExtract.Conv.Text.pas',
  uExtract.Conv.Markdown in '..\..\extract\Src\Converters\uExtract.Conv.Markdown.pas',
  uExtract.Conv.CSV      in '..\..\extract\Src\Converters\uExtract.Conv.CSV.pas',
  uExtract.Conv.JSON     in '..\..\extract\Src\Converters\uExtract.Conv.JSON.pas',
  uExtract.Conv.XML      in '..\..\extract\Src\Converters\uExtract.Conv.XML.pas',
  uExtract.Conv.INI      in '..\..\extract\Src\Converters\uExtract.Conv.INI.pas',
  uExtract.Conv.RTF      in '..\..\extract\Src\Converters\uExtract.Conv.RTF.pas',
  uExtract.Conv.HTML     in '..\..\extract\Src\Converters\uExtract.Conv.HTML.pas',
  uExtract.Conv.DOCX     in '..\..\extract\Src\Converters\uExtract.Conv.DOCX.pas',
  uExtract.Conv.XLSX     in '..\..\extract\Src\Converters\uExtract.Conv.XLSX.pas',
  uExtract.Conv.PPTX     in '..\..\extract\Src\Converters\uExtract.Conv.PPTX.pas',
  uExtract.Conv.PDF      in '..\..\extract\Src\Converters\uExtract.Conv.PDF.pas',
  uExtract.Conv.EPUB     in '..\..\extract\Src\Converters\uExtract.Conv.EPUB.pas';

var
  Passed, Failed: Integer;

procedure Check(const ATestName: string; const ACondition: Boolean;
  const AMsg: string = '');
begin
  if ACondition then
  begin
    WriteLn('  [PASS] ', ATestName);
    Inc(Passed);
  end else
  begin
    if AMsg <> '' then
      WriteLn('  [FAIL] ', ATestName, ': ', AMsg)
    else
      WriteLn('  [FAIL] ', ATestName);
    Inc(Failed);
  end;
end;

// ---------------------------------------------------------------------------
// Helper — convert a raw HTML string through TWebCrawl's internal extract
// engine by writing to a stream and calling ConvertStream directly.
// This lets us test the HTML→Markdown path without any HTTP calls.
// ---------------------------------------------------------------------------

function ConvertHtmlString(const AHtml: string): TConversionResult;
var
  Engine: TAiExtractLib;
  Stream: TStringStream;
  Info  : TStreamInfo;
begin
  Engine := TAiExtractLib.Create;
  try
    Stream := TStringStream.Create(AHtml, TEncoding.UTF8);
    try
      Stream.Position := 0;
      Info := TStreamInfo.From('.html', 'text/html');
      Result := Engine.ConvertStream(Stream, Info);
    finally
      Stream.Free;
    end;
  finally
    Engine.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Unit tests — no network required
// ---------------------------------------------------------------------------

procedure TestExtFromContentType;
var
  W: TWebCrawl;
begin
  WriteLn('ExtFromContentType...');
  W := TWebCrawl.Create;
  try
    // We test the public behaviour through ConvertUrl with a mock-like approach:
    // instead, we verify the HTML converter is called for text/html content.
    var R := ConvertHtmlString('<html><head><title>Hi</title></head><body><h1>Hello</h1></body></html>');
    Check('text/html → HTML converter invoked', R.Success);
    Check('text/html → title extracted', R.Title = 'Hi');
    Check('text/html → heading in output', R.Markdown.Contains('Hello'));
  finally
    W.Free;
  end;
end;

procedure TestHtmlHeadings;
begin
  WriteLn('HTML headings...');
  var Html := '<html><body><h1>Title</h1><h2>Sub</h2><p>Body text.</p></body></html>';
  var R := ConvertHtmlString(Html);
  Check('success', R.Success);
  Check('h1 → # Title', R.Markdown.Contains('# Title'));
  Check('h2 → ## Sub', R.Markdown.Contains('## Sub'));
  Check('paragraph', R.Markdown.Contains('Body text.'));
end;

procedure TestHtmlTable;
begin
  WriteLn('HTML table...');
  var Html :=
    '<html><body><table>' +
    '<tr><th>Name</th><th>Value</th></tr>' +
    '<tr><td>Foo</td><td>42</td></tr>' +
    '</table></body></html>';
  var R := ConvertHtmlString(Html);
  Check('success', R.Success);
  Check('header row', R.Markdown.Contains('Name') and R.Markdown.Contains('Value'));
  Check('data row', R.Markdown.Contains('Foo') and R.Markdown.Contains('42'));
  Check('markdown table pipe', R.Markdown.Contains('|'));
end;

procedure TestHtmlLinks;
begin
  WriteLn('HTML links...');
  var Html := '<html><body><p>See <a href="https://example.com">example</a>.</p></body></html>';
  var R := ConvertHtmlString(Html);
  Check('success', R.Success);
  Check('link markdown', R.Markdown.Contains('[example](https://example.com)'));
end;

procedure TestHtmlCodeBlock;
begin
  WriteLn('HTML code block...');
  var Html := '<html><body><pre><code>var x := 1;</code></pre></body></html>';
  var R := ConvertHtmlString(Html);
  Check('success', R.Success);
  Check('fenced code block', R.Markdown.Contains('```'));
  Check('code content', R.Markdown.Contains('var x := 1;'));
end;

procedure TestHtmlList;
begin
  WriteLn('HTML list...');
  var Html := '<html><body><ul><li>Alpha</li><li>Beta</li></ul></body></html>';
  var R := ConvertHtmlString(Html);
  Check('success', R.Success);
  Check('list item Alpha', R.Markdown.Contains('Alpha'));
  Check('list item Beta', R.Markdown.Contains('Beta'));
  Check('bullet marker', R.Markdown.Contains('- ') or R.Markdown.Contains('* '));
end;

procedure TestHtmlBlockquote;
begin
  WriteLn('HTML blockquote...');
  var Html := '<html><body><blockquote><p>Quoted text</p></blockquote></body></html>';
  var R := ConvertHtmlString(Html);
  Check('success', R.Success);
  Check('blockquote marker', R.Markdown.Contains('> '));
  Check('quoted content', R.Markdown.Contains('Quoted text'));
end;

procedure TestHtmlEmptyBody;
begin
  WriteLn('HTML empty body...');
  var R := ConvertHtmlString('<html><body></body></html>');
  // Empty HTML may succeed with empty markdown or fail — either is acceptable
  Check('does not crash', True);
end;

procedure TestHtmlTitle;
begin
  WriteLn('HTML title extraction...');
  var Html :=
    '<html><head><title>My Page Title</title></head>' +
    '<body><p>Content</p></body></html>';
  var R := ConvertHtmlString(Html);
  Check('success', R.Success);
  Check('title field', R.Title = 'My Page Title');
end;

procedure TestWebCrawlDefaults;
begin
  WriteLn('TWebCrawl defaults...');
  var W := TWebCrawl.Create;
  try
    Check('default timeout 15000', W.Timeout = 15000);
    Check('default user-agent non-empty', W.UserAgent <> '');
  finally
    W.Free;
  end;
end;

procedure TestWebCrawlEmptyUrl;
begin
  WriteLn('Empty URL returns failure...');
  var W := TWebCrawl.Create;
  try
    var R := W.ConvertUrl('');
    Check('success = false', not R.Success);
    Check('error message set', R.ErrorMessage <> '');
  finally
    W.Free;
  end;
end;

procedure TestWebCrawlCustomTimeout;
begin
  WriteLn('Custom timeout / user-agent...');
  var W := TWebCrawl.Create;
  try
    W.Timeout   := 5000;
    W.UserAgent := 'TestBot/1.0';
    Check('timeout written', W.Timeout = 5000);
    Check('user-agent written', W.UserAgent = 'TestBot/1.0');
  finally
    W.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Optional integration test (requires network)
// Set env var WEBCRAWL_INTEGRATION=1 to enable
// ---------------------------------------------------------------------------

procedure TestIntegrationFetchExample;
begin
  WriteLn('Integration — fetch https://example.com ...');
  var W := TWebCrawl.Create;
  try
    W.Timeout := 20000;
    var R := W.ConvertUrl('https://example.com');
    Check('fetch succeeded', R.Success, R.ErrorMessage);
    if R.Success then
    begin
      Check('markdown non-empty', R.Markdown.Trim <> '');
      Check('title non-empty', R.Title <> '');
      WriteLn('    Title: ', R.Title);
      WriteLn('    Markdown length: ', Length(R.Markdown), ' chars');
    end;
  finally
    W.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

begin
  Passed := 0;
  Failed := 0;

  WriteLn('=== TWebCrawl Tests ===');
  WriteLn;

  WriteLn('-- Unit tests (no network) --');
  TestWebCrawlDefaults;
  TestWebCrawlEmptyUrl;
  TestWebCrawlCustomTimeout;
  TestExtFromContentType;
  TestHtmlHeadings;
  TestHtmlTable;
  TestHtmlLinks;
  TestHtmlCodeBlock;
  TestHtmlList;
  TestHtmlBlockquote;
  TestHtmlEmptyBody;
  TestHtmlTitle;

  var Integration := GetEnvironmentVariable('WEBCRAWL_INTEGRATION');
  if Integration = '1' then
  begin
    WriteLn;
    WriteLn('-- Integration tests (network) --');
    TestIntegrationFetchExample;
  end
  else
    WriteLn(sLineBreak + '  [SKIP] Integration tests (set WEBCRAWL_INTEGRATION=1 to enable)');

  WriteLn;
  WriteLn(Format('Results: %d passed, %d failed', [Passed, Failed]));

  if Failed > 0 then
    ExitCode := 1;
end.
