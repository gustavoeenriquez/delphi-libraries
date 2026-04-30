unit uExtract.Engine;

{
  TMarkItDown — multi-format document-to-Markdown converter.

  Usage:
    var MD := TMarkItDown.CreateDefault;
    try
      R := MD.ConvertFile('report.csv');
      WriteLn(R.Markdown);
    finally
      MD.Free;
    end;

  To customise which converters are active, use Create(False) and call
  RegisterConverter manually with your own TDocumentConverter instances.
}

interface

uses
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
  uExtract.Result,
  uExtract.StreamInfo,
  uExtract.Converter;

type
  TMarkItDown = class
  private
    FConverters: TObjectList<TDocumentConverter>;
    procedure SortConverters;
    function  DetectMagicExt(AStream: TStream): string;
  public
    constructor Create(ARegisterDefaults: Boolean = True);
    destructor  Destroy; override;

    // Register a custom converter. Takes ownership.
    procedure RegisterConverter(AConverter: TDocumentConverter);

    // Convert a file on disk.
    function ConvertFile(const AFileName: string): TConversionResult;

    // Convert any stream; caller supplies metadata.
    function ConvertStream(AStream: TStream;
                           const AInfo: TStreamInfo): TConversionResult;
  end;

implementation

uses
  System.IOUtils,
  System.Generics.Defaults,
  uExtract.Conv.Text,
  uExtract.Conv.Markdown,
  uExtract.Conv.CSV,
  uExtract.Conv.JSON,
  uExtract.Conv.XML,
  uExtract.Conv.INI,
  uExtract.Conv.RTF,
  uExtract.Conv.HTML;

{ TMarkItDown }

constructor TMarkItDown.Create(ARegisterDefaults: Boolean);
begin
  inherited Create;
  FConverters := TObjectList<TDocumentConverter>.Create(True {owns});

  if ARegisterDefaults then
  begin
    // specific formats first (priority 0.0), generics last (10.0)
    RegisterConverter(TMarkdownConverter.Create);
    RegisterConverter(TCSVConverter.Create);
    RegisterConverter(TJSONConverter.Create);
    RegisterConverter(TXMLConverter.Create);
    RegisterConverter(TINIConverter.Create);
    RegisterConverter(TRTFConverter.Create);
    RegisterConverter(THTMLConverter.Create);
    RegisterConverter(TTextConverter.Create);
  end;
end;

destructor TMarkItDown.Destroy;
begin
  FConverters.Free;
  inherited;
end;

procedure TMarkItDown.SortConverters;
begin
  FConverters.Sort(TComparer<TDocumentConverter>.Construct(
    function(const A, B: TDocumentConverter): Integer
    begin
      if A.Priority < B.Priority then Result := -1
      else if A.Priority > B.Priority then Result :=  1
      else Result := 0;
    end));
end;

procedure TMarkItDown.RegisterConverter(AConverter: TDocumentConverter);
begin
  FConverters.Add(AConverter);
  SortConverters;
end;

// ---- magic byte detection --------------------------------------------------

function TMarkItDown.DetectMagicExt(AStream: TStream): string;
var
  Buf    : array[0..7] of Byte;
  N      : Integer;
  SavePos: Int64;
begin
  Result  := '';
  SavePos := AStream.Position;
  try
    N := AStream.Read(Buf, SizeOf(Buf));
    if N < 4 then Exit;

    if (Buf[0] = $25) and (Buf[1] = $50) and (Buf[2] = $44) and (Buf[3] = $46) then
      Result := '.pdf'
    else if (Buf[0] = $50) and (Buf[1] = $4B) and (Buf[2] = $03) and (Buf[3] = $04) then
      Result := '.zip'   // DOCX / XLSX / PPTX / EPUB are all ZIP-based
    else if (Buf[0] = $3C) then
    begin
      // '<?' → XML declaration; '<!', '<h', '<H' → HTML
      if (Buf[1] = $3F) then Result := '.xml'
      else Result := '.html';
    end;
  finally
    AStream.Position := SavePos;
  end;
end;

// ---- public API ------------------------------------------------------------

function TMarkItDown.ConvertFile(const AFileName: string): TConversionResult;
var
  FS  : TFileStream;
  Info: TStreamInfo;
begin
  if not TFile.Exists(AFileName) then
    Exit(TConversionResult.Fail('File not found: ' + AFileName));

  FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    Info   := TStreamInfo.FromFile(AFileName);
    Result := ConvertStream(FS, Info);
  finally
    FS.Free;
  end;
end;

function TMarkItDown.ConvertStream(AStream: TStream;
                                   const AInfo: TStreamInfo): TConversionResult;
var
  Info: TStreamInfo;
  Conv: TDocumentConverter;
begin
  Info := AInfo;

  // Supplement missing extension via magic bytes
  if Info.Extension = '' then
    Info.Extension := DetectMagicExt(AStream);

  for Conv in FConverters do
  begin
    if Conv.Accepts(Info) then
    begin
      try
        Result := Conv.Convert(AStream, Info);
      except
        on E: Exception do
          Result := TConversionResult.Fail(Conv.ClassName + ': ' + E.Message);
      end;
      Exit;
    end;
  end;

  Result := TConversionResult.Fail('No converter found for: ' + Info.Extension);
end;

end.
