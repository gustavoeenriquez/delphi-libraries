unit uExtract.Conv.PPTX;

{
  Converts PPTX (Office Open XML Presentation) to Markdown.

  Each slide becomes a ## Slide N section.
  Slides are discovered by probing ppt/slides/slide1.xml, slide2.xml, …
  Text is extracted from <a:t> elements; <a:p> boundaries become new lines.
  Slides are separated by --- (Markdown horizontal rule).
}

interface

uses
  System.Classes,
  uExtract.Converter,
  uExtract.Result,
  uExtract.StreamInfo;

type
  TPPTXConverter = class(TDocumentConverter)
  public
    function Accepts(const AInfo: TStreamInfo): Boolean; override;
    function Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult; override;
    function Priority: Double; override;
  end;

implementation

uses
  System.SysUtils,
  System.Zip,
  uExtract.OpenXML;

// ---- helper ----------------------------------------------------------------

function PptxConvertSlide(const AXml: string; ASB: TStringBuilder): Boolean;
var
  InT     : Boolean;
  InTxBody: Boolean;
  StartLen: Integer;
  ParBuf  : TStringBuilder;
begin
  InT := False; InTxBody := False;
  StartLen := ASB.Length;
  ParBuf := TStringBuilder.Create;
  try
    OXScanXML(AXml,
      procedure(const ATag, AAttrs: string; AIsOpen: Boolean)
      var Line: string;
      begin
        if AIsOpen then
        begin
          if ATag = 'txbody' then InTxBody := True
          else if ATag = 't'  then InT := True
          else if (ATag = 'br') and InTxBody then
          begin
            if ParBuf.Length > 0 then
            begin
              if ASB.Length > StartLen then ASB.AppendLine;
              ASB.Append(ParBuf.ToString.Trim);
              ParBuf.Clear;
            end;
          end;
        end
        else
        begin
          if ATag = 'txbody' then InTxBody := False
          else if ATag = 't'  then InT := False
          else if (ATag = 'p') and InTxBody then
          begin
            Line := ParBuf.ToString.Trim;
            if Line <> '' then
            begin
              if ASB.Length > StartLen then ASB.AppendLine;
              ASB.Append(Line);
            end;
            ParBuf.Clear;
          end;
        end;
      end,
      procedure(const AText: string)
      begin
        if InT and InTxBody then ParBuf.Append(AText);
      end);
  finally
    ParBuf.Free;
  end;
  Result := ASB.Length > StartLen;
end;

// ---- TPPTXConverter --------------------------------------------------------

function TPPTXConverter.Priority: Double;
begin
  Result := 0.0;
end;

function TPPTXConverter.Accepts(const AInfo: TStreamInfo): Boolean;
begin
  Result := AInfo.HasAnyExtension(['.pptx', '.pptm', '.ppsx', '.ppsm']);
end;

function TPPTXConverter.Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult;
var
  Zip       : TZipFile;
  SB        : TStringBuilder;
  SlideNum  : Integer;
  SlideXml  : string;
  SlideEntry: string;
  HasContent: Boolean;
  FirstSlide: Boolean;
begin
  Zip := TZipFile.Create;
  SB  := TStringBuilder.Create;
  try
    try
      Zip.Open(AStream, zmRead);
    except
      Exit(TConversionResult.Fail('Not a valid ZIP/PPTX file'));
    end;

    if (Zip.IndexOf('ppt/presentation.xml') < 0) and
       (Zip.IndexOf('ppt/slides/slide1.xml') < 0) then
      Exit(TConversionResult.Fail('Not a valid PPTX file'));

    HasContent := False;
    FirstSlide := True;
    SlideNum   := 1;

    while True do
    begin
      SlideEntry := Format('ppt/slides/slide%d.xml', [SlideNum]);
      if Zip.IndexOf(SlideEntry) < 0 then Break;

      SlideXml := OXReadEntry(Zip, SlideEntry);
      if SlideXml <> '' then
      begin
        if not FirstSlide then
        begin
          SB.AppendLine;
          SB.AppendLine('---');
          SB.AppendLine;
        end;
        SB.AppendLine(Format('## Slide %d', [SlideNum]));
        SB.AppendLine;
        if PptxConvertSlide(SlideXml, SB) then
          HasContent := True;
        FirstSlide := False;
      end;
      Inc(SlideNum);
    end;

    if not HasContent then
      Exit(TConversionResult.Fail('No text content found in PPTX'));

    Result := TConversionResult.Ok(SB.ToString.TrimRight);
  finally
    Zip.Free;
    SB.Free;
  end;
end;

end.
