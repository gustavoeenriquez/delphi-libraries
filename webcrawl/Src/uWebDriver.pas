unit uWebDriver;

{
  TWebDriver — headless Chrome via the W3C WebDriver protocol.

  Launches chromedriver.exe as a subprocess, opens a browser session,
  navigates to a URL, waits for JavaScript to finish rendering, retrieves
  the fully-rendered DOM, and converts the HTML to Markdown via TAiExtractLib.

  Requirements:
    chromedriver.exe matching your installed Chrome version.
    Download: https://googlechromelabs.github.io/chrome-for-testing/

  Usage:
    var WD := TWebDriver.Create;   // searches PATH for chromedriver.exe
    try
      var R := WD.ConvertUrl('https://react-spa.example.com');
      if R.Success then WriteLn(R.Markdown);
    finally
      WD.Free;   // closes session + kills chromedriver automatically
    end;

  Multiple URLs in one session:
    WD.ConvertUrl('https://a.com');
    WD.ConvertUrl('https://b.com');   // reuses the same Chrome session
    WD.Close;                         // or just let Destroy handle it
}

interface

uses
  System.Classes,
  System.SysUtils,
  System.IOUtils,
  System.Net.HttpClient,
  System.Net.URLClient,
  System.JSON,
  WinAPI.Windows,
  uExtract.Result,
  uExtract.StreamInfo,
  uExtract.Engine;

type
  TWebDriver = class
  private
    FDriverPath: string;
    FPort      : Integer;
    FWaitMs    : Integer;
    FHeadless  : Boolean;
    FExtract   : TAiExtractLib;
    FProcess   : THandle;
    FSessionId : string;
    FHttp      : THTTPClient;

    function  BaseUrl: string; inline;
    function  IsDriverRunning: Boolean;
    procedure EnsureStarted;
    procedure LaunchDriver;
    procedure KillDriver;
    procedure OpenSession;
    procedure CloseSession;
    function  DoPost(const APath, ABody: string): TJSONValue;
    function  DoGet(const APath: string): TJSONValue;
    procedure DoDelete(const APath: string);
    function  GetJsonValueStr(AOwned: TJSONValue): string;
    function  ExecScript(const AScript: string): string;
    procedure WaitForReady;
    function  GetPageSource: string;
  public
    constructor Create(const ADriverPath: string = '');
    destructor  Destroy; override;

    // TCP port for chromedriver (default: 9515).
    property Port    : Integer read FPort    write FPort;
    // Extra milliseconds to wait after document.readyState = 'complete' (default: 1500).
    // Raise this for SPAs that issue AJAX calls after initial load.
    property WaitMs  : Integer read FWaitMs  write FWaitMs;
    // Run Chrome without a visible window (default: True).
    property Headless: Boolean read FHeadless write FHeadless;

    // Navigate to AUrl with a real browser (JavaScript fully executed),
    // then return the rendered content as Markdown.
    function ConvertUrl(const AUrl: string): TConversionResult;

    // Explicitly close the browser session and stop chromedriver.
    // Called automatically by Destroy if still running.
    procedure Close;
  end;

implementation

const
  CDefaultPort      = 9515;
  CDefaultWaitMs    = 1500;
  CDriverStartupMs  = 5000;
  CPageReadyMs      = 30000;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function FindDriverExe(const AHint: string): string;
const
  ExeName = 'chromedriver.exe';
var
  Dir: string;
begin
  // 1. Explicit path provided
  if (AHint <> '') and TFile.Exists(AHint) then
    Exit(AHint);

  // 2. Same folder as the running executable
  var SameDir := TPath.Combine(TPath.GetDirectoryName(ParamStr(0)), ExeName);
  if TFile.Exists(SameDir) then
    Exit(SameDir);

  // 3. Scan PATH
  for Dir in GetEnvironmentVariable('PATH').Split([';']) do
  begin
    var Candidate := TPath.Combine(Dir.Trim, ExeName);
    if TFile.Exists(Candidate) then
      Exit(Candidate);
  end;

  // 4. Return bare name — OS will resolve; CreateProcess will fail with a clear message
  Result := ExeName;
end;

function JsonEncode(const S: string): string;
var
  JS: TJSONString;
begin
  JS := TJSONString.Create(S);
  try
    Result := JS.ToJSON; // includes surrounding quotes
  finally
    JS.Free;
  end;
end;

// ---------------------------------------------------------------------------

{ TWebDriver }

constructor TWebDriver.Create(const ADriverPath: string);
begin
  inherited Create;
  FPort       := CDefaultPort;
  FWaitMs     := CDefaultWaitMs;
  FHeadless   := True;
  FProcess    := 0;
  FSessionId  := '';
  FDriverPath := FindDriverExe(ADriverPath);
  FExtract    := TAiExtractLib.Create;
  FHttp       := THTTPClient.Create;
  FHttp.ResponseTimeout := 60000;
end;

destructor TWebDriver.Destroy;
begin
  Close;
  FHttp.Free;
  FExtract.Free;
  inherited;
end;

function TWebDriver.BaseUrl: string;
begin
  Result := Format('http://localhost:%d', [FPort]);
end;

function TWebDriver.IsDriverRunning: Boolean;
begin
  Result := (FProcess <> 0) and
    (WaitForSingleObject(FProcess, 0) = WAIT_TIMEOUT);
end;

// ---------------------------------------------------------------------------
// Driver process lifecycle
// ---------------------------------------------------------------------------

procedure TWebDriver.LaunchDriver;
var
  SI : TStartupInfo;
  PI : TProcessInformation;
  Cmd: string;
begin
  FillChar(SI, SizeOf(SI), 0);
  SI.cb      := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES;
  SI.hStdInput  := INVALID_HANDLE_VALUE;
  SI.hStdOutput := INVALID_HANDLE_VALUE;
  SI.hStdError  := INVALID_HANDLE_VALUE;

  Cmd := Format('"%s" --port=%d', [FDriverPath, FPort]);
  if not CreateProcess(nil, PChar(Cmd), nil, nil, False,
    CREATE_NO_WINDOW, nil, nil, SI, PI) then
    raise Exception.CreateFmt(
      'Cannot launch chromedriver (%s): %s',
      [FDriverPath, SysErrorMessage(GetLastError)]);

  CloseHandle(PI.hThread);
  FProcess := PI.hProcess;

  // Poll /status until chromedriver accepts connections
  var Deadline := GetTickCount64 + CDriverStartupMs;
  var Ready := False;
  repeat
    Sleep(200);
    try
      var Resp := FHttp.Get(BaseUrl + '/status');
      Ready := Resp.StatusCode = 200;
    except
      // Not ready yet — keep waiting
    end;
  until Ready or (GetTickCount64 > Deadline);

  if not Ready then
  begin
    TerminateProcess(FProcess, 1);
    CloseHandle(FProcess);
    FProcess := 0;
    raise Exception.CreateFmt(
      'chromedriver did not respond within %d ms on port %d',
      [CDriverStartupMs, FPort]);
  end;
end;

procedure TWebDriver.KillDriver;
begin
  if FProcess <> 0 then
  begin
    TerminateProcess(FProcess, 0);
    WaitForSingleObject(FProcess, 3000);
    CloseHandle(FProcess);
    FProcess := 0;
  end;
end;

// ---------------------------------------------------------------------------
// WebDriver HTTP primitives
// ---------------------------------------------------------------------------

function TWebDriver.DoPost(const APath, ABody: string): TJSONValue;
var
  Body: TStringStream;
  Resp: IHTTPResponse;
  RespText: string;
begin
  Body := TStringStream.Create(ABody, TEncoding.UTF8);
  try
    Resp := FHttp.Post(
      BaseUrl + APath, Body, nil,
      [TNameValuePair.Create('Content-Type', 'application/json')]);
    RespText := Resp.ContentAsString(TEncoding.UTF8);
    Result := TJSONObject.ParseJSONValue(RespText);
  finally
    Body.Free;
  end;
end;

function TWebDriver.DoGet(const APath: string): TJSONValue;
var
  Resp: IHTTPResponse;
begin
  Resp := FHttp.Get(BaseUrl + APath);
  Result := TJSONObject.ParseJSONValue(Resp.ContentAsString(TEncoding.UTF8));
end;

procedure TWebDriver.DoDelete(const APath: string);
begin
  FHttp.Delete(BaseUrl + APath);
end;

// Extract the "value" field from a WebDriver response and free the JSON object.
function TWebDriver.GetJsonValueStr(AOwned: TJSONValue): string;
begin
  Result := '';
  if AOwned = nil then Exit;
  try
    var Obj := AOwned as TJSONObject;
    var Val := Obj.GetValue('value');
    if Val <> nil then
      Result := Val.Value;
  finally
    AOwned.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Session management
// ---------------------------------------------------------------------------

procedure TWebDriver.OpenSession;
var
  Json   : TJSONValue;
  Body   : string;
  ChArgs : string;
begin
  if FHeadless then
    ChArgs := '"--headless=new","--no-sandbox","--disable-gpu","--disable-dev-shm-usage"'
  else
    ChArgs := '"--no-sandbox","--disable-gpu"';

  Body := Format(
    '{"capabilities":{"alwaysMatch":{"browserName":"chrome",' +
    '"goog:chromeOptions":{"args":[%s]}}}}',
    [ChArgs]);

  Json := DoPost('/session', Body);
  try
    if Json = nil then
      raise Exception.Create('Empty response from /session');
    var Root := Json as TJSONObject;
    var ValObj := Root.GetValue<TJSONObject>('value');
    if ValObj = nil then
      raise Exception.Create('No "value" in session response');
    var SessId := ValObj.GetValue('sessionId');
    if SessId = nil then
      raise Exception.Create('No "sessionId" in session response');
    FSessionId := SessId.Value;
  finally
    Json.Free;
  end;
end;

procedure TWebDriver.CloseSession;
begin
  if FSessionId <> '' then
  begin
    try DoDelete('/session/' + FSessionId); except end;
    FSessionId := '';
  end;
end;

procedure TWebDriver.EnsureStarted;
begin
  if not IsDriverRunning then
  begin
    LaunchDriver;
    OpenSession;
  end
  else if FSessionId = '' then
    OpenSession;
end;

// ---------------------------------------------------------------------------
// Page interaction
// ---------------------------------------------------------------------------

function TWebDriver.ExecScript(const AScript: string): string;
var
  Body: string;
  Json: TJSONValue;
begin
  Body := Format('{"script":%s,"args":[]}', [JsonEncode(AScript)]);
  Json := DoPost('/session/' + FSessionId + '/execute/sync', Body);
  Result := GetJsonValueStr(Json);
end;

procedure TWebDriver.WaitForReady;
var
  State   : string;
  Deadline: UInt64;
begin
  Deadline := GetTickCount64 + CPageReadyMs;
  repeat
    Sleep(250);
    State := ExecScript('return document.readyState;');
  until (State = 'complete') or (GetTickCount64 > Deadline);

  if FWaitMs > 0 then
    Sleep(FWaitMs);
end;

function TWebDriver.GetPageSource: string;
var
  Json: TJSONValue;
begin
  Json := DoGet('/session/' + FSessionId + '/source');
  Result := GetJsonValueStr(Json);
end;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

function TWebDriver.ConvertUrl(const AUrl: string): TConversionResult;
var
  Html  : string;
  Stream: TStringStream;
  Info  : TStreamInfo;
  Json  : TJSONValue;
begin
  if AUrl.Trim = '' then
    Exit(TConversionResult.Fail('URL cannot be empty'));

  try
    EnsureStarted;

    Json := DoPost('/session/' + FSessionId + '/url',
      Format('{"url":%s}', [JsonEncode(AUrl)]));
    if Json <> nil then Json.Free;  // {"value": null} — ignore

    WaitForReady;

    Html := GetPageSource;
    if Html.Trim = '' then
      Exit(TConversionResult.Fail('Empty page source for: ' + AUrl));

    Stream := TStringStream.Create(Html, TEncoding.UTF8);
    try
      Stream.Position := 0;
      Info := TStreamInfo.From('.html', 'text/html', AUrl);
      Result := FExtract.ConvertStream(Stream, Info);
    finally
      Stream.Free;
    end;

  except
    on E: Exception do
      Result := TConversionResult.Fail('WebDriver error: ' + E.Message);
  end;
end;

procedure TWebDriver.Close;
begin
  CloseSession;
  KillDriver;
end;

end.
