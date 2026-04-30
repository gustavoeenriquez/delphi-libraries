unit uExtract.Conv.CSV;

{
  Converts CSV and TSV files to Markdown tables.

  Auto-detects delimiter (comma / semicolon / tab) from file content.
  Handles RFC 4180 quoting: double-quoted fields, escaped double-quotes ("").
  First row is treated as the header row.
  Output is capped at MaxRows to avoid huge documents.
}

interface

uses
  System.Classes,
  uExtract.Converter,
  uExtract.Result,
  uExtract.StreamInfo;

type
  TCSVConverter = class(TDocumentConverter)
  public
    function Accepts(const AInfo: TStreamInfo): Boolean; override;
    function Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult; override;
    function Priority: Double; override;
  private
    function  DetectDelimiter(const ASample: string): Char;
    function  ParseLine(const ALine: string; ADelim: Char): TArray<string>;
    function  EscapeCell(const AValue: string): string;
    function  BuildTable(const ALines: TArray<string>; ADelim: Char;
                         ATotalLines: Integer): string;
  end;

implementation

uses
  System.SysUtils,
  System.Math,
  System.Generics.Collections;

const
  MaxRows = 500;

{ TCSVConverter }

function TCSVConverter.Priority: Double;
begin
  Result := 0.0;
end;

function TCSVConverter.Accepts(const AInfo: TStreamInfo): Boolean;
begin
  Result := AInfo.HasAnyExtension(['.csv', '.tsv']) or
            (AInfo.MimeType = 'text/csv');
end;

// ---- delimiter detection ---------------------------------------------------

function TCSVConverter.DetectDelimiter(const ASample: string): Char;
var
  Comma, Semi, Tab: Integer;
  C: Char;
begin
  Comma := 0; Semi := 0; Tab := 0;
  for C in ASample do
    case C of
      ',': Inc(Comma);
      ';': Inc(Semi);
      #9 : Inc(Tab);
    end;
  if (Tab > Comma) and (Tab > Semi) then Exit(#9);
  if Semi > Comma then Exit(';');
  Result := ',';
end;

// ---- RFC 4180 field parser -------------------------------------------------

function TCSVConverter.ParseLine(const ALine: string; ADelim: Char): TArray<string>;
var
  Fields: TList<string>;
  I: Integer;
  InQuotes: Boolean;
  Field: string;
  C: Char;
begin
  Fields := TList<string>.Create;
  try
    InQuotes := False;
    Field    := '';
    I        := 1;
    while I <= Length(ALine) do
    begin
      C := ALine[I];
      if InQuotes then
      begin
        if C = '"' then
        begin
          if (I < Length(ALine)) and (ALine[I + 1] = '"') then
          begin
            Field := Field + '"';
            Inc(I);
          end
          else
            InQuotes := False;
        end
        else
          Field := Field + C;
      end
      else
      begin
        if C = '"' then
          InQuotes := True
        else if C = ADelim then
        begin
          Fields.Add(Field);
          Field := '';
        end
        else
          Field := Field + C;
      end;
      Inc(I);
    end;
    Fields.Add(Field);
    Result := Fields.ToArray;
  finally
    Fields.Free;
  end;
end;

// ---- Markdown cell escaping ------------------------------------------------

function TCSVConverter.EscapeCell(const AValue: string): string;
begin
  Result := AValue.Trim;
  Result := Result.Replace(#13#10, ' ').Replace(#10, ' ').Replace(#13, ' ');
  Result := Result.Replace('|', '\|');
  if Result = '' then Result := ' '; // empty cell keeps table valid
end;

// ---- table builder ---------------------------------------------------------

function TCSVConverter.BuildTable(const ALines: TArray<string>; ADelim: Char;
                                  ATotalLines: Integer): string;
var
  SB       : TStringBuilder;
  ColCount : Integer;
  I, Row   : Integer;
  Fields   : TArray<string>;
begin
  if Length(ALines) = 0 then Exit('');

  // compute max column count across all lines
  ColCount := 0;
  for Row := 0 to High(ALines) do
  begin
    Fields := ParseLine(ALines[Row], ADelim);
    if Length(Fields) > ColCount then ColCount := Length(Fields);
  end;
  if ColCount = 0 then Exit('');

  SB := TStringBuilder.Create;
  try
    for Row := 0 to High(ALines) do
    begin
      Fields := ParseLine(ALines[Row], ADelim);
      SB.Append('|');
      for I := 0 to ColCount - 1 do
      begin
        if I < Length(Fields) then
          SB.Append(' ').Append(EscapeCell(Fields[I])).Append(' |')
        else
          SB.Append('  |');
      end;
      SB.AppendLine;

      // separator after header row
      if Row = 0 then
      begin
        SB.Append('|');
        for I := 0 to ColCount - 1 do
          SB.Append(' --- |');
        SB.AppendLine;
      end;
    end;

    if ATotalLines > MaxRows then
      SB.AppendLine.AppendFormat('> *Showing %d of %d rows*', [MaxRows, ATotalLines]);

    Result := SB.ToString.TrimRight;
  finally
    SB.Free;
  end;
end;

// ---- main conversion -------------------------------------------------------

function TCSVConverter.Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult;
var
  Reader     : TStreamReader;
  AllLines   : TStringList;
  Trimmed    : TArray<string>;
  Count, I   : Integer;
  Delim      : Char;
  Sample     : string;
begin
  AllLines := TStringList.Create;
  Reader   := TStreamReader.Create(AStream, TEncoding.UTF8, True);
  try
    while not Reader.EndOfStream do
      AllLines.Add(Reader.ReadLine);

  finally
    Reader.Free;
  end;

  try
    if AllLines.Count = 0 then
      Exit(TConversionResult.Fail('Empty CSV file'));

    // detect delimiter from first two lines
    Sample := AllLines[0];
    if AllLines.Count > 1 then Sample := Sample + AllLines[1];
    Delim := DetectDelimiter(Sample);
    if AInfo.HasExtension('.tsv') then Delim := #9;

    // collect up to MaxRows non-empty lines
    Count := 0;
    SetLength(Trimmed, Min(AllLines.Count, MaxRows));
    for I := 0 to AllLines.Count - 1 do
    begin
      if Count >= MaxRows then Break;
      if AllLines[I].Trim <> '' then
      begin
        Trimmed[Count] := AllLines[I];
        Inc(Count);
      end;
    end;
    SetLength(Trimmed, Count);

    Result := TConversionResult.Ok(BuildTable(Trimmed, Delim, AllLines.Count));
  finally
    AllLines.Free;
  end;
end;

end.
