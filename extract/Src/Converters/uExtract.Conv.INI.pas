unit uExtract.Conv.INI;

{
  Converts INI / CFG / properties files to Markdown.

  Output:
  - Each [Section] becomes ## heading + key-value table.
  - Keys before any section are grouped under ## (global).
  - Supports both = and : as key-value separators.
  - Lines starting with ; or # are treated as comments (skipped).
}

interface

uses
  System.Classes,
  uExtract.Converter,
  uExtract.Result,
  uExtract.StreamInfo;

type
  TINIConverter = class(TDocumentConverter)
  public
    function Accepts(const AInfo: TStreamInfo): Boolean; override;
    function Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult; override;
    function Priority: Double; override;
  end;

implementation

uses
  System.SysUtils;

{ TINIConverter }

function TINIConverter.Priority: Double;
begin
  Result := 0.0;
end;

function TINIConverter.Accepts(const AInfo: TStreamInfo): Boolean;
begin
  Result := AInfo.HasAnyExtension(['.ini', '.cfg', '.conf', '.properties', '.env']);
end;

function TINIConverter.Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult;
var
  Reader     : TStreamReader;
  Lines      : TStringList;
  Line, Trim : string;
  SB         : TStringBuilder;
  Section    : string;
  Key, Value : string;
  EqPos      : Integer;
  SectionOpen: Boolean;
  HasContent : Boolean;

  procedure OpenSection(const AName: string);
  begin
    if SectionOpen then SB.AppendLine;
    SB.AppendLine('## ' + AName);
    SB.AppendLine;
    SB.AppendLine('| Key | Value |');
    SB.AppendLine('| --- | --- |');
    SectionOpen := True;
  end;

begin
  Lines  := TStringList.Create;
  Reader := TStreamReader.Create(AStream, TEncoding.UTF8, True);
  try
    while not Reader.EndOfStream do
      Lines.Add(Reader.ReadLine);
  finally
    Reader.Free;
  end;

  SB         := TStringBuilder.Create;
  SectionOpen := False;
  HasContent  := False;
  try
    for Line in Lines do
    begin
      Trim := Line.Trim;

      if (Trim = '') or Trim.StartsWith(';') or Trim.StartsWith('#') then
        Continue;

      // [Section]
      if Trim.StartsWith('[') and Trim.EndsWith(']') then
      begin
        Section := Copy(Trim, 2, Length(Trim) - 2).Trim;
        OpenSection(Section);
        HasContent := True;
        Continue;
      end;

      // key = value  or  key : value
      EqPos := Pos('=', Trim);
      if EqPos = 0 then EqPos := Pos(':', Trim);
      if EqPos > 0 then
      begin
        Key   := Copy(Trim, 1, EqPos - 1).Trim;
        Value := Copy(Trim, EqPos + 1, MaxInt).Trim;
        // strip surrounding quotes from value (common in .env files)
        if (Length(Value) >= 2) and
           ((Value[1] = '"') and (Value[Length(Value)] = '"') or
            (Value[1] = '''') and (Value[Length(Value)] = '''')) then
          Value := Copy(Value, 2, Length(Value) - 2);

        if not SectionOpen then
          OpenSection('(global)');

        SB.AppendLine(Format('| %s | %s |',
          [Key.Replace('|', '\|'), Value.Replace('|', '\|')]));
        HasContent := True;
      end;
    end;

    if not HasContent then
      Exit(TConversionResult.Fail('No key-value pairs found'));

    Result := TConversionResult.Ok(SB.ToString.TrimRight);
  finally
    SB.Free;
    Lines.Free;
  end;
end;

end.
