unit uExtract.Conv.XLSX;

{
  Converts XLSX (Office Open XML Spreadsheet) to Markdown.

  Each worksheet becomes a ## section with a Markdown table.
  Sheet order and names come from xl/workbook.xml.
  Shared strings are resolved from xl/sharedStrings.xml.
  Numbers are output as their raw string representation.
  Boolean cells: 1 → TRUE, 0 → FALSE.
  Maximum 500 rows and 50 columns per sheet.
}

interface

uses
  System.Classes,
  uExtract.Converter,
  uExtract.Result,
  uExtract.StreamInfo;

type
  TXLSXConverter = class(TDocumentConverter)
  public
    function Accepts(const AInfo: TStreamInfo): Boolean; override;
    function Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult; override;
    function Priority: Double; override;
  end;

implementation

uses
  System.SysUtils,
  System.Zip,
  System.Math,
  System.Generics.Collections,
  System.StrUtils,
  uExtract.OpenXML;

// ---- helpers ---------------------------------------------------------------

// "B3" → column index 1 (0-based). "AA3" → 26.
function XlsxColIndex(const ARef: string): Integer;
var I: Integer;
begin
  Result := 0; I := 1;
  while (I <= Length(ARef)) and CharInSet(ARef[I], ['A'..'Z', 'a'..'z']) do
  begin
    Result := Result * 26 + (Ord(UpCase(ARef[I])) - Ord('A') + 1);
    Inc(I);
  end;
  Dec(Result);
end;

// "B3" → "B"
function XlsxColStr(const ARef: string): string;
var I: Integer;
begin
  Result := '';
  for I := 1 to Length(ARef) do
    if CharInSet(ARef[I], ['A'..'Z', 'a'..'z']) then Result := Result + ARef[I]
    else Break;
end;

procedure XlsxEnsureSize(AList: TStringList; ASize: Integer);
begin
  while AList.Count < ASize do AList.Add('');
end;

function XlsxLoadSharedStrings(AZip: TZipFile): TStringList;
var
  Xml    : string;
  InSI   : Boolean;
  InT    : Boolean;
  CurStr : TStringBuilder;
  Lst    : TStringList;  // named var — Result cannot be captured by anonymous methods
begin
  Lst    := TStringList.Create;
  Result := Lst;
  Xml := OXReadEntry(AZip, 'xl/sharedStrings.xml');
  if Xml = '' then Exit;
  InSI := False; InT := False;
  CurStr := TStringBuilder.Create;
  try
    OXScanXML(Xml,
      procedure(const ATag, AAttrs: string; AIsOpen: Boolean)
      begin
        if AIsOpen then
        begin
          if ATag = 'si' then begin InSI := True; CurStr.Clear; end
          else if ATag = 't' then InT := True;
        end
        else
        begin
          if ATag = 't'  then InT := False
          else if ATag = 'si' then begin InSI := False; Lst.Add(CurStr.ToString); end;
        end;
      end,
      procedure(const AText: string)
      begin
        if InSI and InT then CurStr.Append(AText);
      end);
  finally
    CurStr.Free;
  end;
end;

function XlsxConvertSheet(AZip: TZipFile; const AXmlPath: string;
  const ASharedStrings: TStringList; ASB: TStringBuilder): Boolean;
const
  MaxRows = 500;
  MaxCols = 50;
var
  Xml        : string;
  Grid       : TObjectList<TStringList>;
  CurRowList : TStringList;
  CellRef    : string;
  CellType   : string;
  CellVal    : string;
  InV        : Boolean;
  InIS       : Boolean;
  InIT       : Boolean;
  MaxColCount: Integer;
  I, J       : Integer;
  Row        : TStringList;
  LineB, SepB: TStringBuilder;
begin
  Result := False;
  Xml := OXReadEntry(AZip, AXmlPath);
  if Xml = '' then Exit;

  Grid := TObjectList<TStringList>.Create(True);
  CurRowList := nil;
  InV := False; InIS := False; InIT := False;
  MaxColCount := 0;
  CellRef := ''; CellType := ''; CellVal := '';
  try
    OXScanXML(Xml,
      procedure(const ATag, AAttrs: string; AIsOpen: Boolean)
      var
        RAttr   : string;
        RowIdx  : Integer;
        ColIdx  : Integer;
        SSIdx   : Integer;
        Resolved: string;
      begin
        if AIsOpen then
        begin
          if ATag = 'row' then
          begin
            RAttr  := OXAttr(AAttrs, 'r');
            RowIdx := StrToIntDef(RAttr, Grid.Count + 1) - 1;
            while Grid.Count <= RowIdx do Grid.Add(TStringList.Create);
            CurRowList := Grid[RowIdx];
          end
          else if ATag = 'c' then
          begin
            CellRef  := OXAttr(AAttrs, 'r');
            CellType := LowerCase(OXAttr(AAttrs, 't'));
            CellVal  := '';
          end
          else if ATag = 'v'  then InV  := True
          else if ATag = 'is' then InIS := True
          else if ATag = 't'  then InIT := InIS;
        end
        else
        begin
          if ATag = 'v'  then InV  := False
          else if ATag = 'is' then InIS := False
          else if ATag = 't'  then InIT := False
          else if ATag = 'c'  then
          begin
            if CellType = 's' then
            begin
              SSIdx := StrToIntDef(CellVal.Trim, -1);
              if (SSIdx >= 0) and (SSIdx < ASharedStrings.Count) then
                Resolved := ASharedStrings[SSIdx]
              else
                Resolved := '';
            end
            else if CellType = 'b' then
              Resolved := IfThen(CellVal.Trim = '1', 'TRUE', 'FALSE')
            else
              Resolved := CellVal.Trim;

            ColIdx := XlsxColIndex(XlsxColStr(CellRef));
            if (CurRowList <> nil) and (ColIdx >= 0) and (ColIdx < MaxCols) and
               (Grid.Count <= MaxRows) then
            begin
              XlsxEnsureSize(CurRowList, ColIdx + 1);
              CurRowList[ColIdx] := Resolved;
              if ColIdx + 1 > MaxColCount then MaxColCount := ColIdx + 1;
            end;
          end
          else if ATag = 'row' then
            CurRowList := nil;
        end;
      end,
      procedure(const AText: string)
      begin
        if InV or InIT then CellVal := CellVal + AText;
      end);

    if (Grid.Count = 0) or (MaxColCount = 0) then Exit;

    LineB := TStringBuilder.Create;
    SepB  := TStringBuilder.Create;
    try
      for I := 0 to Min(Grid.Count, MaxRows) - 1 do
      begin
        Row := Grid[I];
        XlsxEnsureSize(Row, MaxColCount);
        LineB.Clear;
        LineB.Append('| ');
        for J := 0 to MaxColCount - 1 do
        begin
          LineB.Append(Row[J].Replace('|', '\|'));
          if J < MaxColCount - 1 then LineB.Append(' | ')
          else LineB.Append(' |');
        end;
        ASB.AppendLine(LineB.ToString);
        if I = 0 then
        begin
          SepB.Clear;
          SepB.Append('|');
          for J := 0 to MaxColCount - 1 do SepB.Append(' --- |');
          ASB.AppendLine(SepB.ToString);
        end;
      end;
    finally
      LineB.Free;
      SepB.Free;
    end;
    Result := True;
  finally
    Grid.Free;
  end;
end;

// ---- TXLSXConverter --------------------------------------------------------

function TXLSXConverter.Priority: Double;
begin
  Result := 0.0;
end;

function TXLSXConverter.Accepts(const AInfo: TStreamInfo): Boolean;
begin
  Result := AInfo.HasAnyExtension(['.xlsx', '.xlsm', '.xltx', '.xltm']);
end;

function TXLSXConverter.Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult;
type
  TSheetEntry = record Name, RId: string; end;
var
  Zip       : TZipFile;
  SS        : TStringList;
  WbXml     : string;
  RelsXml   : string;
  SB        : TStringBuilder;
  Sheets    : TList<TSheetEntry>;
  RelsMap   : TDictionary<string, string>;
  HasContent: Boolean;
  SE        : TSheetEntry;
  FullPath  : string;

  procedure ParseWorkbook;
  var InSheets: Boolean;
  begin
    InSheets := False;
    OXScanXML(WbXml,
      procedure(const ATag, AAttrs: string; AIsOpen: Boolean)
      var SE2: TSheetEntry;
      begin
        if AIsOpen then
        begin
          if ATag = 'sheets' then InSheets := True
          else if (ATag = 'sheet') and InSheets then
          begin
            SE2.Name := OXAttr(AAttrs, 'name');
            SE2.RId  := OXAttr(AAttrs, 'r:id');
            if SE2.RId = '' then SE2.RId := OXAttr(AAttrs, 'rid');
            Sheets.Add(SE2);
          end;
        end
        else if ATag = 'sheets' then InSheets := False;
      end,
      procedure(const AText: string) begin end);
  end;

  procedure ParseRels;
  begin
    OXScanXML(RelsXml,
      procedure(const ATag, AAttrs: string; AIsOpen: Boolean)
      var Id, Target: string;
      begin
        if AIsOpen and (ATag = 'relationship') then
        begin
          Id     := OXAttr(AAttrs, 'Id');
          Target := OXAttr(AAttrs, 'Target');
          if Id <> '' then RelsMap.AddOrSetValue(Id, Target);
        end;
      end,
      procedure(const AText: string) begin end);
  end;

begin
  Zip     := TZipFile.Create;
  SS      := nil;
  SB      := TStringBuilder.Create;
  Sheets  := TList<TSheetEntry>.Create;
  RelsMap := TDictionary<string, string>.Create;
  try
    try
      Zip.Open(AStream, zmRead);
    except
      Exit(TConversionResult.Fail('Not a valid ZIP/XLSX file'));
    end;

    if Zip.IndexOf('xl/workbook.xml') < 0 then
      Exit(TConversionResult.Fail('Not a valid XLSX file'));

    SS      := XlsxLoadSharedStrings(Zip);
    WbXml   := OXReadEntry(Zip, 'xl/workbook.xml');
    RelsXml := OXReadEntry(Zip, 'xl/_rels/workbook.xml.rels');

    ParseWorkbook;
    ParseRels;

    HasContent := False;
    var Target: string;
    for SE in Sheets do
    begin
      if not RelsMap.TryGetValue(SE.RId, Target) then Continue;
      if Target = '' then Continue;
      FullPath := 'xl/' + Target;

      if SB.Length > 0 then SB.AppendLine;
      SB.AppendLine('## ' + SE.Name);
      SB.AppendLine;
      if XlsxConvertSheet(Zip, FullPath, SS, SB) then
        HasContent := True
      else
        SB.AppendLine('*(empty sheet)*');
      SB.AppendLine;
    end;

    if not HasContent then
      Exit(TConversionResult.Fail('No content found in XLSX'));

    Result := TConversionResult.Ok(SB.ToString.TrimRight);
  finally
    Zip.Free;
    SS.Free;
    SB.Free;
    Sheets.Free;
    RelsMap.Free;
  end;
end;

end.
