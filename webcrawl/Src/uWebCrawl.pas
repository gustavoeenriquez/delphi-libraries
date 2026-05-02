unit uWebCrawl;

{
  TWebCrawl — Fetch a web page and return its content as Markdown.

  Internally:
    1. Downloads the URL with THTTPClient (System.Net.HttpClient).
    2. Wraps the response body in a TMemoryStream.
    3. Delegates HTML→Markdown conversion to TAiExtractLib from the extract/ library.

  Only HTML/XHTML responses are converted to Markdown; all other MIME types
  are returned as a fenced code block (via the extract/ Text fallback).

  Usage:
    var W := TWebCrawl.Create;
    try
      var R := W.ConvertUrl('https://example.com');
      if R.Success then WriteLn(R.Markdown);
    finally
      W.Free;
    end;
}

interface

uses
  System.Classes,
  System.SysUtils,
  System.Net.HttpClient,
  uExtract.Result,
  uExtract.StreamInfo,
  uExtract.Engine;

type
  TWebCrawl = class
  private
    FTimeout  : Integer;
    FUserAgent: string;
    FExtract  : TAiExtractLib;
    function ExtFromContentType(const AContentType, AUrl: string): string;
  public
    constructor Create;
    destructor  Destroy; override;

    // HTTP response timeout in milliseconds (default: 15000).
    property Timeout  : Integer read FTimeout   write FTimeout;
    // Value sent in the User-Agent request header.
    property UserAgent: string  read FUserAgent  write FUserAgent;

    // Fetch AUrl and return its content converted to Markdown.
    function ConvertUrl(const AUrl: string): TConversionResult;
  end;

implementation

uses
  System.IOUtils;

const
  CDefaultTimeout   = 15000;
  CDefaultUserAgent = 'Mozilla/5.0 (compatible; AiWebCrawl/1.0; +https://github.com/gustavoeenriquez/delphi-libraries)';

{ TWebCrawl }

constructor TWebCrawl.Create;
begin
  inherited;
  FTimeout   := CDefaultTimeout;
  FUserAgent := CDefaultUserAgent;
  FExtract   := TAiExtractLib.Create; // all converters — HTML wins for text/html
end;

destructor TWebCrawl.Destroy;
begin
  FExtract.Free;
  inherited;
end;

// ---------------------------------------------------------------------------
// Map Content-Type (or URL extension) to a file extension for TStreamInfo.
// ---------------------------------------------------------------------------

function TWebCrawl.ExtFromContentType(const AContentType, AUrl: string): string;
var
  CT: string;
begin
  // Normalise: take only the type/subtype part, strip parameters like "; charset=utf-8"
  CT := LowerCase(Trim(AContentType));
  var SemiColon := CT.IndexOf(';');
  if SemiColon >= 0 then
    CT := Trim(CT.Substring(0, SemiColon));

  if (CT = 'text/html') or (CT = 'application/xhtml+xml') then
    Result := '.html'
  else if CT = 'application/xml' then
    Result := '.xml'
  else if CT = 'text/xml' then
    Result := '.xml'
  else if CT = 'application/json' then
    Result := '.json'
  else if CT = 'text/csv' then
    Result := '.csv'
  else if CT = 'text/plain' then
    Result := '.txt'
  else
  begin
    // Fall back to the URL extension (ignore query/fragment)
    var Path := AUrl;
    var Q := Path.IndexOf('?');
    if Q >= 0 then Path := Path.Substring(0, Q);
    var F := Path.IndexOf('#');
    if F >= 0 then Path := Path.Substring(0, F);
    Result := LowerCase(TPath.GetExtension(Path));
    if Result = '' then
      Result := '.html'; // default for bare URLs
  end;
end;

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

function TWebCrawl.ConvertUrl(const AUrl: string): TConversionResult;
var
  Http  : THTTPClient;
  Resp  : IHTTPResponse;
  Body  : TMemoryStream;
  Info  : TStreamInfo;
  Ext   : string;
begin
  if AUrl.Trim = '' then
    Exit(TConversionResult.Fail('URL cannot be empty'));

  Http := THTTPClient.Create;
  try
    Http.ResponseTimeout  := FTimeout;
    Http.UserAgent        := FUserAgent;
    Http.HandleRedirects  := True;
    Http.Accept           := 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';

    Body := TMemoryStream.Create;
    try
      try
        Resp := Http.Get(AUrl, Body);
      except
        on E: Exception do
          Exit(TConversionResult.Fail('HTTP request failed: ' + E.Message));
      end;

      if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
        Exit(TConversionResult.Fail(
          Format('HTTP %d: %s', [Resp.StatusCode, Resp.StatusText])));

      Body.Position := 0;
      var CT := Resp.GetHeaderValue('Content-Type');
      Ext  := ExtFromContentType(CT, AUrl);
      Info := TStreamInfo.From(Ext, CT, AUrl);

      Result := FExtract.ConvertStream(Body, Info);
    finally
      Body.Free;
    end;
  finally
    Http.Free;
  end;
end;

end.
