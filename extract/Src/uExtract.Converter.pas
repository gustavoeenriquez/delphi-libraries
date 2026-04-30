unit uExtract.Converter;

interface

uses
  System.Classes,
  uExtract.Result,
  uExtract.StreamInfo;

type
  // Abstract base for all format converters.
  // Lower Priority value = runs first (more specific converters use 0.0,
  // generic fallbacks use 10.0).
  TDocumentConverter = class abstract
  public
    function Accepts(const AInfo: TStreamInfo): Boolean; virtual; abstract;
    function Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult; virtual; abstract;
    function Priority: Double; virtual;
  end;

implementation

function TDocumentConverter.Priority: Double;
begin
  Result := 10.0;
end;

end.
