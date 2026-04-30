unit uExtract.Conv.Text;

interface

uses
  System.Classes,
  uExtract.Converter,
  uExtract.Result,
  uExtract.StreamInfo;

type
  TTextConverter = class(TDocumentConverter)
  public
    function Accepts(const AInfo: TStreamInfo): Boolean; override;
    function Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult; override;
    function Priority: Double; override;
  end;

implementation

uses
  System.SysUtils;

function TTextConverter.Priority: Double;
begin
  Result := 10.0; // lowest priority — generic fallback
end;

function TTextConverter.Accepts(const AInfo: TStreamInfo): Boolean;
begin
  Result := AInfo.HasAnyExtension(['.txt', '.log', '.text']) or
            (AInfo.MimeType = 'text/plain');
end;

function TTextConverter.Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult;
var
  Reader: TStreamReader;
begin
  Reader := TStreamReader.Create(AStream, TEncoding.UTF8, True {detectBOM});
  try
    Result := TConversionResult.Ok(Reader.ReadToEnd.TrimRight);
  finally
    Reader.Free;
  end;
end;

end.
