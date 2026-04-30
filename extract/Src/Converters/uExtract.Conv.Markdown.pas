unit uExtract.Conv.Markdown;

interface

uses
  System.Classes,
  uExtract.Converter,
  uExtract.Result,
  uExtract.StreamInfo;

type
  TMarkdownConverter = class(TDocumentConverter)
  public
    function Accepts(const AInfo: TStreamInfo): Boolean; override;
    function Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult; override;
    function Priority: Double; override;
  end;

implementation

uses
  System.SysUtils;

function TMarkdownConverter.Priority: Double;
begin
  Result := 5.0;
end;

function TMarkdownConverter.Accepts(const AInfo: TStreamInfo): Boolean;
begin
  Result := AInfo.HasAnyExtension(['.md', '.markdown', '.mdown', '.mkd', '.mdx']);
end;

function TMarkdownConverter.Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult;
var
  Reader: TStreamReader;
begin
  Reader := TStreamReader.Create(AStream, TEncoding.UTF8, True);
  try
    Result := TConversionResult.Ok(Reader.ReadToEnd.TrimRight);
  finally
    Reader.Free;
  end;
end;

end.
