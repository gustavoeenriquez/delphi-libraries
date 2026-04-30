unit uExtract.Conv.XML;

{
  Converts XML files to Markdown.

  Strategy:
  - Files <= MaxFencedBytes : fenced ```xml block (verbatim, trimmed)
  - Larger files            : fenced block truncated to MaxFencedBytes
                              followed by a truncation notice

  Proper tree-based extraction (RSS, OPML, generic element→heading)
  is planned for Fase 2.
}

interface

uses
  System.Classes,
  uExtract.Converter,
  uExtract.Result,
  uExtract.StreamInfo;

type
  TXMLConverter = class(TDocumentConverter)
  public
    function Accepts(const AInfo: TStreamInfo): Boolean; override;
    function Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult; override;
    function Priority: Double; override;
  end;

implementation

uses
  System.SysUtils,
  System.StrUtils;

const
  MaxFencedBytes = 50 * 1024; // 50 KB

{ TXMLConverter }

function TXMLConverter.Priority: Double;
begin
  Result := 0.0;
end;

function TXMLConverter.Accepts(const AInfo: TStreamInfo): Boolean;
begin
  Result := AInfo.HasAnyExtension(['.xml', '.xsd', '.xsl', '.xslt',
                                   '.rss', '.atom', '.opml', '.svg']) or
            (AInfo.MimeType = 'text/xml') or
            (AInfo.MimeType = 'application/xml');
end;

function TXMLConverter.Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult;
var
  Reader   : TStreamReader;
  Content  : string;
  Truncated: Boolean;
begin
  Reader := TStreamReader.Create(AStream, TEncoding.UTF8, True);
  try
    Content := Reader.ReadToEnd;
  finally
    Reader.Free;
  end;

  if Content.Trim = '' then
    Exit(TConversionResult.Fail('Empty XML file'));

  Truncated := False;
  if Length(Content) > MaxFencedBytes then
  begin
    Content   := Copy(Content, 1, MaxFencedBytes);
    Truncated := True;
  end;

  Result := TConversionResult.Ok(
    '```xml' + sLineBreak +
    Content.Trim + sLineBreak +
    '```' +
    IfThen(Truncated, sLineBreak + sLineBreak + '> *Output truncated to 50 KB*', '')
  );
end;

end.
