unit uExtract.Conv.JSON;

{
  Converts JSON files to Markdown.

  Smart output strategy:
  - Flat JSON object   → two-column property table
  - Array of flat objs → multi-column data table  (up to MaxRows rows)
  - Everything else    → fenced ```json block (pretty-printed)
}

interface

uses
  System.Classes,
  uExtract.Converter,
  uExtract.Result,
  uExtract.StreamInfo;

type
  TJSONConverter = class(TDocumentConverter)
  public
    function Accepts(const AInfo: TStreamInfo): Boolean; override;
    function Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult; override;
    function Priority: Double; override;
  private
    function EscapeCell(const AValue: string): string;
    function TryFlatObject(AVal: TObject): string;
    function TryObjectArray(AVal: TObject): string;
  end;

implementation

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections;

const
  MaxRows = 500;

{ TJSONConverter }

function TJSONConverter.Priority: Double;
begin
  Result := 0.0;
end;

function TJSONConverter.Accepts(const AInfo: TStreamInfo): Boolean;
begin
  Result := AInfo.HasAnyExtension(['.json', '.jsonl', '.geojson']) or
            (AInfo.MimeType = 'application/json');
end;

function TJSONConverter.EscapeCell(const AValue: string): string;
begin
  Result := AValue.Trim;
  Result := Result.Replace(#13#10, ' ').Replace(#10, ' ').Replace(#13, ' ');
  Result := Result.Replace('|', '\|');
  if Result = '' then Result := ' ';
end;

// Returns a property table if AVal is a flat (non-nested) JSON object.
function TJSONConverter.TryFlatObject(AVal: TObject): string;
var
  JObj: TJSONObject;
  Pair: TJSONPair;
  SB  : TStringBuilder;
begin
  Result := '';
  if not (AVal is TJSONObject) then Exit;
  JObj := TJSONObject(AVal);

  for Pair in JObj do
    if (Pair.JsonValue is TJSONObject) or (Pair.JsonValue is TJSONArray) then
      Exit; // nested — skip

  SB := TStringBuilder.Create;
  try
    SB.AppendLine('| Property | Value |');
    SB.AppendLine('| --- | --- |');
    for Pair in JObj do
      SB.AppendLine(Format('| %s | %s |',
        [EscapeCell(Pair.JsonString.Value), EscapeCell(Pair.JsonValue.Value)]));
    Result := SB.ToString.TrimRight;
  finally
    SB.Free;
  end;
end;

// Returns a data table if AVal is an array of flat, uniform JSON objects.
function TJSONConverter.TryObjectArray(AVal: TObject): string;
var
  JArr   : TJSONArray;
  Elem   : TJSONValue;
  JObj   : TJSONObject;
  Pair   : TJSONPair;
  KeySet : TList<string>;
  Keys   : TArray<string>;
  SB     : TStringBuilder;
  I, Rows: Integer;
  V      : TJSONValue;
begin
  Result := '';
  if not (AVal is TJSONArray) then Exit;
  JArr := TJSONArray(AVal);
  if JArr.Count = 0 then Exit;

  KeySet := TList<string>.Create;
  try
    // Validate: all elements must be flat objects; collect union of keys
    for Elem in JArr do
    begin
      if not (Elem is TJSONObject) then Exit;
      JObj := TJSONObject(Elem);
      for Pair in JObj do
      begin
        if (Pair.JsonValue is TJSONObject) or (Pair.JsonValue is TJSONArray) then
          Exit; // nested — skip
        if not KeySet.Contains(Pair.JsonString.Value) then
          KeySet.Add(Pair.JsonString.Value);
      end;
    end;
    if KeySet.Count = 0 then Exit;
    Keys := KeySet.ToArray;
  finally
    KeySet.Free;
  end;

  SB := TStringBuilder.Create;
  try
    // header
    SB.Append('|');
    for I := 0 to High(Keys) do
      SB.Append(' ').Append(EscapeCell(Keys[I])).Append(' |');
    SB.AppendLine;
    // separator
    SB.Append('|');
    for I := 0 to High(Keys) do
      SB.Append(' --- |');
    SB.AppendLine;
    // rows
    Rows := 0;
    for Elem in JArr do
    begin
      if Rows >= MaxRows then Break;
      JObj := TJSONObject(Elem);
      SB.Append('|');
      for I := 0 to High(Keys) do
      begin
        V := JObj.Values[Keys[I]];
        if Assigned(V) then
          SB.Append(' ').Append(EscapeCell(V.Value)).Append(' |')
        else
          SB.Append('  |');
      end;
      SB.AppendLine;
      Inc(Rows);
    end;

    if JArr.Count > MaxRows then
      SB.AppendLine.AppendFormat('> *Showing %d of %d rows*', [MaxRows, JArr.Count]);

    Result := SB.ToString.TrimRight;
  finally
    SB.Free;
  end;
end;

// ---- main conversion -------------------------------------------------------

function TJSONConverter.Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult;
var
  Reader : TStreamReader;
  Content: string;
  JVal   : TJSONValue;
  MD     : string;
begin
  Reader := TStreamReader.Create(AStream, TEncoding.UTF8, True);
  try
    Content := Reader.ReadToEnd;
  finally
    Reader.Free;
  end;

  if Content.Trim = '' then
    Exit(TConversionResult.Fail('Empty JSON file'));

  JVal := TJSONObject.ParseJSONValue(Content);
  if JVal = nil then
    Exit(TConversionResult.Fail('Invalid JSON'));

  try
    MD := TryFlatObject(JVal);
    if MD = '' then MD := TryObjectArray(JVal);
    if MD = '' then
      MD := '```json' + sLineBreak + JVal.Format(2) + sLineBreak + '```';

    Result := TConversionResult.Ok(MD);
  finally
    JVal.Free;
  end;
end;

end.
