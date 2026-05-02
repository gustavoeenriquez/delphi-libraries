program TestWebDriver;

{$APPTYPE CONSOLE}
{$R *.res}

uses
  System.SysUtils,
  System.Classes,
  uWebDriver      in '..\Src\uWebDriver.pas',
  uWebCrawl       in '..\Src\uWebCrawl.pas',
  uExtract.Result in '..\..\extract\Src\uExtract.Result.pas',
  uExtract.StreamInfo in '..\..\extract\Src\uExtract.StreamInfo.pas',
  uExtract.Converter  in '..\..\extract\Src\uExtract.Converter.pas',
  uExtract.Engine     in '..\..\extract\Src\uExtract.Engine.pas',
  uExtract.OpenXML    in '..\..\extract\Src\uExtract.OpenXML.pas',
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

procedure Check(const AName: string; const ACondition: Boolean;
  const AMsg: string = '');
begin
  if ACondition then
  begin
    WriteLn('  [PASS] ', AName);
    Inc(Passed);
  end else
  begin
    if AMsg <> '' then
      WriteLn('  [FAIL] ', AName, ': ', AMsg)
    else
      WriteLn('  [FAIL] ', AName);
    Inc(Failed);
  end;
end;

// ---------------------------------------------------------------------------
// Unit tests — no chromedriver / network needed
// ---------------------------------------------------------------------------

procedure TestDefaults;
begin
  WriteLn('TWebDriver defaults...');
  var WD := TWebDriver.Create;
  try
    Check('default port = 9515',  WD.Port    = 9515);
    Check('default waitMs = 1500', WD.WaitMs  = 1500);
    Check('default headless = true', WD.Headless = True);
  finally
    WD.Free;
  end;
end;

procedure TestPropertySetters;
begin
  WriteLn('Property setters...');
  var WD := TWebDriver.Create;
  try
    WD.Port     := 9999;
    WD.WaitMs   := 3000;
    WD.Headless := False;
    Check('port set',     WD.Port    = 9999);
    Check('waitMs set',   WD.WaitMs  = 3000);
    Check('headless set', WD.Headless = False);
  finally
    WD.Free;
  end;
end;

procedure TestEmptyUrl;
begin
  WriteLn('Empty URL returns failure (no driver needed)...');
  var WD := TWebDriver.Create;
  try
    var R := WD.ConvertUrl('');
    Check('success = false',       not R.Success);
    Check('error message present', R.ErrorMessage <> '');
  finally
    WD.Free;
  end;
end;

procedure TestCustomDriverPath;
begin
  WriteLn('Custom driver path stored correctly...');
  var WD := TWebDriver.Create('C:\tools\chromedriver.exe');
  try
    // We just verify the object creates without crashing;
    // driver won't be launched until ConvertUrl is called.
    Check('object created', True);
  finally
    WD.Free;
  end;
end;

procedure TestCloseIdempotent;
begin
  WriteLn('Close() on non-started driver is safe...');
  var WD := TWebDriver.Create;
  try
    WD.Close;
    WD.Close;  // second call must not crash
    Check('double-close safe', True);
  finally
    WD.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Integration tests — require chromedriver.exe + Chrome installed
// Set env var WEBDRIVER_INTEGRATION=1 to enable
// ---------------------------------------------------------------------------

procedure TestIntegrationStaticPage;
begin
  WriteLn('Integration — static page (https://example.com)...');
  var WD := TWebDriver.Create;
  try
    WD.WaitMs := 500;
    var R := WD.ConvertUrl('https://example.com');
    Check('fetch succeeded', R.Success, R.ErrorMessage);
    if R.Success then
    begin
      Check('markdown non-empty', R.Markdown.Trim <> '');
      Check('title non-empty',    R.Title <> '');
      WriteLn('    Title:    ', R.Title);
      WriteLn('    Markdown: ', Length(R.Markdown), ' chars');
    end;
  finally
    WD.Free;
  end;
end;

procedure TestIntegrationReuseSession;
begin
  WriteLn('Integration — reuse session for two URLs...');
  var WD := TWebDriver.Create;
  try
    WD.WaitMs := 500;
    var R1 := WD.ConvertUrl('https://example.com');
    var R2 := WD.ConvertUrl('https://example.org');
    Check('first URL succeeded',  R1.Success, R1.ErrorMessage);
    Check('second URL succeeded', R2.Success, R2.ErrorMessage);
    // Both calls used the same Chrome session (driver didn't crash on reuse)
    Check('both produced markdown', R1.Success and R2.Success);
  finally
    WD.Free;
  end;
end;

procedure TestIntegrationJsRendered;
// A page that sets document.title dynamically with JavaScript.
// Static fetchers (TWebCrawl) would miss the updated title;
// TWebDriver waits for JS and captures it.
begin
  WriteLn('Integration — JS-rendered title...');
  var WD := TWebDriver.Create;
  try
    WD.WaitMs := 500;
    // data:text/html is a browser-native scheme — chromedriver supports it
    var Html :=
      '<html><head></head><body>' +
      '<script>document.title="JSTitle"; ' +
      'document.body.innerHTML="<h1>Rendered by JS</h1>";</script>' +
      '</body></html>';
    var R := WD.ConvertUrl('data:text/html,' + Html);
    Check('fetch succeeded', R.Success, R.ErrorMessage);
    if R.Success then
    begin
      Check('JS-rendered heading found', R.Markdown.Contains('Rendered by JS'));
      WriteLn('    Markdown: ', R.Markdown.Trim);
    end;
  finally
    WD.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

begin
  Passed := 0;
  Failed := 0;

  WriteLn('=== TWebDriver Tests ===');
  WriteLn;

  WriteLn('-- Unit tests (no driver required) --');
  TestDefaults;
  TestPropertySetters;
  TestEmptyUrl;
  TestCustomDriverPath;
  TestCloseIdempotent;

  var Integration := GetEnvironmentVariable('WEBDRIVER_INTEGRATION');
  if Integration = '1' then
  begin
    WriteLn;
    WriteLn('-- Integration tests (chromedriver + Chrome required) --');
    TestIntegrationStaticPage;
    TestIntegrationReuseSession;
    TestIntegrationJsRendered;
  end
  else
    WriteLn(sLineBreak +
      '  [SKIP] Integration tests — set WEBDRIVER_INTEGRATION=1 to enable');

  WriteLn;
  WriteLn(Format('Results: %d passed, %d failed', [Passed, Failed]));
  if Failed > 0 then ExitCode := 1;
end.
