unit uExtract.Conv.EPUB;

{
  Converts EPUB (Electronic Publication) to Markdown.

  EPUB is a ZIP archive containing:
    META-INF/container.xml  — points to the OPF package descriptor
    OPF file                — <manifest> (id → href) and <spine> (reading order)
    Content XHTML files     — the actual chapter text

  Steps:
    1. Read META-INF/container.xml → locate the OPF file (rootfile @full-path).
    2. Parse OPF manifest (id→href) and spine (ordered idrefs).
    3. For each spine item, read the XHTML content file and extract body text.
    4. Output as ## Chapter N sections separated by ---.

  Text extraction strips <head>, <script>, <style>, <noscript> and emits
  newlines at block element boundaries (p, div, h1-h6, li, br).
}

interface

uses
  System.Classes,
  uExtract.Converter,
  uExtract.Result,
  uExtract.StreamInfo;

type
  TEPUBConverter = class(TDocumentConverter)
  public
    function Accepts(const AInfo: TStreamInfo): Boolean; override;
    function Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult; override;
    function Priority: Double; override;
  end;

implementation

uses
  System.SysUtils,
  System.Zip,
  System.Generics.Collections,
  uExtract.OpenXML;

// ---- XHTML text extractor --------------------------------------------------

function EpubReadXhtmlText(const AXml: string): string;
var
  SB    : TStringBuilder;
  InBody: Boolean;
  InSkip: Integer;
  PendNL: Integer;
begin
  SB := TStringBuilder.Create;
  InBody := False;
  InSkip := 0;
  PendNL := 0;
  try
    OXScanXML(AXml,
      procedure(const ATag, AAttrs: string; AIsOpen: Boolean)
      begin
        if AIsOpen then
        begin
          if ATag = 'body' then
            InBody := True
          else if (ATag = 'head') or (ATag = 'script') or
                  (ATag = 'style') or (ATag = 'noscript') then
            Inc(InSkip)
          else if InBody and (InSkip = 0) then
          begin
            if (ATag = 'p') or (ATag = 'div') or (ATag = 'section') or
               (ATag = 'article') or (ATag = 'blockquote') or
               (ATag = 'h1') or (ATag = 'h2') or (ATag = 'h3') or
               (ATag = 'h4') or (ATag = 'h5') or (ATag = 'h6') then
            begin
              if PendNL < 2 then PendNL := 2;
            end
            else if ATag = 'br' then
            begin
              if PendNL < 1 then PendNL := 1;
            end
            else if ATag = 'li' then
            begin
              if PendNL < 1 then PendNL := 1;
            end;
          end;
        end
        else
        begin
          if ATag = 'body' then
            InBody := False
          else if (ATag = 'head') or (ATag = 'script') or
                  (ATag = 'style') or (ATag = 'noscript') then
          begin
            if InSkip > 0 then Dec(InSkip);
          end
          else if InBody and (InSkip = 0) then
          begin
            if (ATag = 'p') or (ATag = 'div') or (ATag = 'section') or
               (ATag = 'article') or (ATag = 'blockquote') or
               (ATag = 'h1') or (ATag = 'h2') or (ATag = 'h3') or
               (ATag = 'h4') or (ATag = 'h5') or (ATag = 'h6') or
               (ATag = 'li') then
            begin
              if PendNL < 1 then PendNL := 1;
            end;
          end;
        end;
      end,
      procedure(const AText: string)
      var T: string; K: Integer;
      begin
        if InBody and (InSkip = 0) then
        begin
          T := AText.Trim;
          if T = '' then Exit;
          if SB.Length > 0 then
            for K := 1 to PendNL do SB.AppendLine;
          PendNL := 0;
          SB.Append(T);
        end;
      end);
    Result := SB.ToString.Trim;
  finally
    SB.Free;
  end;
end;

// ---- TEPUBConverter --------------------------------------------------------

function TEPUBConverter.Priority: Double;
begin
  Result := 0.0;
end;

function TEPUBConverter.Accepts(const AInfo: TStreamInfo): Boolean;
begin
  Result := AInfo.HasAnyExtension(['.epub']);
end;

function TEPUBConverter.Convert(AStream: TStream;
  const AInfo: TStreamInfo): TConversionResult;
var
  Zip       : TZipFile;
  SB        : TStringBuilder;
  ContXml   : string;
  OpfPath   : string;
  OpfXml    : string;
  OpfDir    : string;
  Manifest  : TDictionary<string, string>;
  Spine     : TList<string>;
  HasContent: Boolean;
  ChapterNum: Integer;
  IdRef     : string;
  Href      : string;
  ItemPath  : string;
  ChText    : string;
  SlashPos  : Integer;
  QPos      : Integer;
  HPos      : Integer;

  procedure ParseContainer;
  begin
    OXScanXML(ContXml,
      procedure(const ATag, AAttrs: string; AIsOpen: Boolean)
      begin
        if AIsOpen and (ATag = 'rootfile') and (OpfPath = '') then
          OpfPath := OXAttr(AAttrs, 'full-path');
      end,
      procedure(const AText: string) begin end);
  end;

  procedure ParseOpf;
  var
    InManifest: Boolean;
    InSpine   : Boolean;
  begin
    InManifest := False;
    InSpine    := False;
    OXScanXML(OpfXml,
      procedure(const ATag, AAttrs: string; AIsOpen: Boolean)
      var Id, HRef: string;
      begin
        if AIsOpen then
        begin
          if ATag = 'manifest' then InManifest := True
          else if ATag = 'spine' then InSpine := True
          else if (ATag = 'item') and InManifest then
          begin
            Id   := OXAttr(AAttrs, 'id');
            HRef := OXAttr(AAttrs, 'href');
            if (Id <> '') and (HRef <> '') then
              Manifest.AddOrSetValue(Id, HRef);
          end
          else if (ATag = 'itemref') and InSpine then
          begin
            Id := OXAttr(AAttrs, 'idref');
            if Id <> '' then Spine.Add(Id);
          end;
        end
        else
        begin
          if ATag = 'manifest' then InManifest := False
          else if ATag = 'spine' then InSpine := False;
        end;
      end,
      procedure(const AText: string) begin end);
  end;

begin
  Zip      := TZipFile.Create;
  SB       := TStringBuilder.Create;
  Manifest := TDictionary<string, string>.Create;
  Spine    := TList<string>.Create;
  try
    try
      Zip.Open(AStream, zmRead);
    except
      Exit(TConversionResult.Fail('Not a valid ZIP/EPUB file'));
    end;

    if Zip.IndexOf('META-INF/container.xml') < 0 then
      Exit(TConversionResult.Fail('Not a valid EPUB file (no container.xml)'));

    ContXml := OXReadEntry(Zip, 'META-INF/container.xml');
    OpfPath := '';
    ParseContainer;

    if OpfPath = '' then
      Exit(TConversionResult.Fail('EPUB container.xml has no rootfile'));

    OpfXml := OXReadEntry(Zip, OpfPath);
    if OpfXml = '' then
      Exit(TConversionResult.Fail('EPUB OPF file not found: ' + OpfPath));

    SlashPos := OpfPath.LastIndexOf('/');
    if SlashPos >= 0 then
      OpfDir := Copy(OpfPath, 1, SlashPos + 1)
    else
      OpfDir := '';

    ParseOpf;

    if Spine.Count = 0 then
      Exit(TConversionResult.Fail('EPUB spine is empty'));

    HasContent := False;
    ChapterNum := 1;

    for IdRef in Spine do
    begin
      if not Manifest.TryGetValue(IdRef, Href) then Continue;
      if Href = '' then Continue;

      if Href.StartsWith('/') then
        ItemPath := Copy(Href, 2, MaxInt)
      else
        ItemPath := OpfDir + Href;

      QPos := ItemPath.IndexOf('?');
      if QPos >= 0 then ItemPath := Copy(ItemPath, 1, QPos);
      HPos := ItemPath.IndexOf('#');
      if HPos >= 0 then ItemPath := Copy(ItemPath, 1, HPos);

      if Zip.IndexOf(ItemPath) < 0 then Continue;

      ChText := EpubReadXhtmlText(OXReadEntry(Zip, ItemPath));
      if ChText = '' then Continue;

      if SB.Length > 0 then
      begin
        SB.AppendLine;
        SB.AppendLine('---');
        SB.AppendLine;
      end;
      SB.AppendLine(Format('## Chapter %d', [ChapterNum]));
      SB.AppendLine;
      SB.Append(ChText);
      HasContent := True;
      Inc(ChapterNum);
    end;

    if not HasContent then
      Exit(TConversionResult.Fail('No text content found in EPUB'));

    Result := TConversionResult.Ok(SB.ToString.TrimRight);
  finally
    Zip.Free;
    SB.Free;
    Manifest.Free;
    Spine.Free;
  end;
end;

end.
