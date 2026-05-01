unit uExtract.Conv.PDF;

{
  Converts PDF to plain text using the pure-Delphi pdf/ library.

  Uses TPDFDocument (uPDF.Document) and TPDFTextExtractor (uPDF.TextExtractor).
  Encrypted PDFs are attempted with an empty password before failing.
  Scanned PDFs (no text layer) produce a failure result.
  The PDF document title, when available, is surfaced as TConversionResult.Title.
}

interface

uses
  System.Classes,
  uExtract.Converter,
  uExtract.Result,
  uExtract.StreamInfo;

type
  TPDFExtractConverter = class(TDocumentConverter)
  public
    function Accepts(const AInfo: TStreamInfo): Boolean; override;
    function Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult; override;
    function Priority: Double; override;
  end;

implementation

uses
  System.SysUtils,
  uPDF.Document,
  uPDF.TextExtractor;

function TPDFExtractConverter.Priority: Double;
begin
  Result := 0.0;
end;

function TPDFExtractConverter.Accepts(const AInfo: TStreamInfo): Boolean;
begin
  Result := AInfo.HasExtension('.pdf');
end;

function TPDFExtractConverter.Convert(AStream: TStream;
  const AInfo: TStreamInfo): TConversionResult;
var
  Doc  : TPDFDocument;
  Ext  : TPDFTextExtractor;
  Text : string;
  Title: string;
begin
  Doc := TPDFDocument.Create;
  try
    try
      Doc.LoadFromStream(AStream);
    except
      on E: Exception do
        Exit(TConversionResult.Fail('Cannot parse PDF: ' + E.Message));
    end;

    if Doc.IsEncrypted then
    begin
      if not Doc.Authenticate('') then
        Exit(TConversionResult.Fail('PDF is encrypted and password-protected'));
    end;

    Title := Doc.Title;

    Ext := TPDFTextExtractor.Create(Doc);
    try
      try
        Text := Ext.ExtractAllText;
      except
        on E: Exception do
          Exit(TConversionResult.Fail('Text extraction failed: ' + E.Message));
      end;
    finally
      Ext.Free;
    end;

    if Text.Trim = '' then
      Exit(TConversionResult.Fail('No text content found (possibly a scanned PDF)'));

    Result := TConversionResult.Ok(Text.TrimRight, Title);
  finally
    Doc.Free;
  end;
end;

end.
