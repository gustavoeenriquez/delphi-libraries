unit uExtract.Conv.DOCX;

{
  Converts DOCX (Office Open XML) documents to Markdown.

  Reads word/document.xml from the ZIP archive and handles:
  - Headings  : pStyle Heading1–Heading6 / Title → # … ######
  - Paragraphs: blank-line separation
  - Tables    : first row = header row with | --- | separator
  - Line breaks (\w:br) and soft hyphens
  - Deleted text (\w:del) is skipped; field codes (\w:instrText) are skipped
}

interface

uses
  System.Classes,
  uExtract.Converter,
  uExtract.Result,
  uExtract.StreamInfo;

type
  TDOCXConverter = class(TDocumentConverter)
  public
    function Accepts(const AInfo: TStreamInfo): Boolean; override;
    function Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult; override;
    function Priority: Double; override;
  private
    function ConvertDocXml(const AXml: string): string;
  end;

implementation

uses
  System.SysUtils,
  System.Zip,
  System.Math,
  uExtract.OpenXML;

// ---- private parser class --------------------------------------------------

type
  TDOCXParser = class
  private
    FSB         : TStringBuilder;
    FCellBuf    : TStringBuilder;
    FCurRowCells: TStringList;
    FTblRowLines: TStringList;
    FPendNL     : Integer;
    FParLevel   : Integer;
    FTblDepth   : Integer;
    FInDel      : Integer;
    FAtParStart : Boolean;
    FInTblCell  : Boolean;
    FInT        : Boolean;
    FInInstr    : Boolean;
    FInPPr      : Boolean;

    procedure Need(N: Integer);
    procedure FlushPend;
    procedure Emit(const S: string);
    procedure FlushTableRow;
    procedure FlushTable;
    procedure OnTag(const ATag, AAttrs: string; AIsOpen: Boolean);
    procedure OnText(const AText: string);
  public
    constructor Create;
    destructor  Destroy; override;
    function    Parse(const AXml: string): string;
  end;

constructor TDOCXParser.Create;
begin
  inherited;
  FSB          := TStringBuilder.Create;
  FCellBuf     := TStringBuilder.Create;
  FCurRowCells := TStringList.Create;
  FTblRowLines := TStringList.Create;
  FAtParStart  := True;
end;

destructor TDOCXParser.Destroy;
begin
  FSB.Free;
  FCellBuf.Free;
  FCurRowCells.Free;
  FTblRowLines.Free;
  inherited;
end;

procedure TDOCXParser.Need(N: Integer);
begin
  if N > FPendNL then FPendNL := N;
end;

procedure TDOCXParser.FlushPend;
var K: Integer;
begin
  if (FPendNL > 0) and (FSB.Length > 0) then
    for K := 1 to FPendNL do FSB.AppendLine;
  FPendNL := 0;
end;

procedure TDOCXParser.Emit(const S: string);
begin
  if (S = '') or (FInDel > 0) then Exit;
  if FInTblCell then begin FCellBuf.Append(S); Exit; end;
  FlushPend;
  if FAtParStart then
  begin
    if FParLevel > 0 then
      FSB.Append(StringOfChar('#', FParLevel)).Append(' ');
    FAtParStart := False;
  end;
  FSB.Append(S);
end;

procedure TDOCXParser.FlushTableRow;
var
  I  : Integer;
  Row: TStringBuilder;
  Sep: TStringBuilder;
begin
  if FCurRowCells.Count = 0 then Exit;
  Row := TStringBuilder.Create;
  try
    Row.Append('| ');
    for I := 0 to FCurRowCells.Count - 1 do
    begin
      Row.Append(FCurRowCells[I].Replace('|', '\|').Replace(#10, ' ').Replace(#13, ' '));
      if I < FCurRowCells.Count - 1 then Row.Append(' | ')
      else Row.Append(' |');
    end;
    FTblRowLines.Add(Row.ToString);
  finally
    Row.Free;
  end;
  if FTblRowLines.Count = 1 then
  begin
    Sep := TStringBuilder.Create;
    try
      Sep.Append('|');
      for I := 0 to FCurRowCells.Count - 1 do Sep.Append(' --- |');
      FTblRowLines.Add(Sep.ToString);
    finally
      Sep.Free;
    end;
  end;
  FCurRowCells.Clear;
end;

procedure TDOCXParser.FlushTable;
var I: Integer;
begin
  if FTblRowLines.Count = 0 then Exit;
  FlushPend;
  for I := 0 to FTblRowLines.Count - 1 do
    FSB.AppendLine(FTblRowLines[I]);
  FTblRowLines.Clear;
end;

function HeadLevelFromStyle(const AVal: string): Integer;
var
  S: string;
  I: Integer;
begin
  Result := 0;
  S := LowerCase(AVal);
  if S = 'title' then Exit(1);
  I := Pos('heading', S);
  if I = 0 then Exit;
  I := I + 7;
  while (I <= Length(S)) and not CharInSet(S[I], ['1'..'6']) do Inc(I);
  if (I <= Length(S)) and CharInSet(S[I], ['1'..'6']) then
    Result := Ord(S[I]) - Ord('0');
end;

procedure TDOCXParser.OnTag(const ATag, AAttrs: string; AIsOpen: Boolean);
var BT: string;
begin
  if AIsOpen then
  begin
    if ATag = 'p' then
    begin
      if FTblDepth = 0 then Need(2);
      FAtParStart := True;
      FParLevel   := 0;
    end
    else if ATag = 'ppr'  then FInPPr  := True
    else if ATag = 'pstyle' then
    begin
      if FInPPr then
        FParLevel := HeadLevelFromStyle(OXAttr(AAttrs, 'w:val'));
    end
    else if ATag = 't'    then FInT    := True
    else if ATag = 'instrtext' then FInInstr := True
    else if ATag = 'del'  then Inc(FInDel)
    else if ATag = 'br'   then
    begin
      BT := LowerCase(OXAttr(AAttrs, 'w:type'));
      if BT = 'page' then Need(2) else Emit(sLineBreak);
    end
    else if ATag = 'tab'  then Emit(#9)
    else if ATag = 'nobreakhyphen' then Emit('-')
    else if ATag = 'tbl'  then
    begin
      Inc(FTblDepth);
      if FTblDepth = 1 then begin Need(2); FTblRowLines.Clear; end;
    end
    else if ATag = 'tc' then
    begin
      if FTblDepth = 1 then begin FCellBuf.Clear; FInTblCell := True; end;
    end;
  end
  else // close
  begin
    if ATag = 'p' then
    begin
      if FInTblCell and (FCellBuf.Length > 0) then FCellBuf.Append(' ');
    end
    else if ATag = 'ppr'  then FInPPr  := False
    else if ATag = 't'    then FInT    := False
    else if ATag = 'instrtext' then FInInstr := False
    else if ATag = 'del'  then begin if FInDel > 0 then Dec(FInDel); end
    else if ATag = 'tc'   then
    begin
      if FTblDepth = 1 then
      begin
        FCurRowCells.Add(FCellBuf.ToString.Trim);
        FCellBuf.Clear;
        FInTblCell := False;
      end;
    end
    else if ATag = 'tr' then
    begin
      if FTblDepth = 1 then FlushTableRow;
    end
    else if ATag = 'tbl' then
    begin
      if FTblDepth = 1 then begin FlushTable; Need(2); end;
      if FTblDepth > 0 then Dec(FTblDepth);
    end;
  end;
end;

procedure TDOCXParser.OnText(const AText: string);
begin
  if FInT and not FInInstr then Emit(AText);
end;

function TDOCXParser.Parse(const AXml: string): string;
begin
  OXScanXML(AXml, OnTag, OnText);
  Result := FSB.ToString.Trim;
end;

// ---- TDOCXConverter --------------------------------------------------------

function TDOCXConverter.Priority: Double;
begin
  Result := 0.0;
end;

function TDOCXConverter.Accepts(const AInfo: TStreamInfo): Boolean;
begin
  Result := AInfo.HasAnyExtension(['.docx', '.docm']);
end;

function TDOCXConverter.ConvertDocXml(const AXml: string): string;
var
  Parser: TDOCXParser;
begin
  Parser := TDOCXParser.Create;
  try
    Result := Parser.Parse(AXml);
  finally
    Parser.Free;
  end;
end;

function TDOCXConverter.Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult;
var
  Zip   : TZipFile;
  DocXml: string;
  Text  : string;
begin
  Zip := TZipFile.Create;
  try
    try
      Zip.Open(AStream, zmRead);
    except
      Exit(TConversionResult.Fail('Not a valid ZIP/DOCX file'));
    end;
    if Zip.IndexOf('word/document.xml') < 0 then
      Exit(TConversionResult.Fail('Not a DOCX file (word/document.xml not found)'));
    DocXml := OXReadEntry(Zip, 'word/document.xml');
  finally
    Zip.Free;
  end;

  if DocXml.Trim = '' then
    Exit(TConversionResult.Fail('Empty DOCX document'));

  Text := ConvertDocXml(DocXml);
  if Text = '' then
    Exit(TConversionResult.Fail('No text content in DOCX'));

  Result := TConversionResult.Ok(Text);
end;

end.
