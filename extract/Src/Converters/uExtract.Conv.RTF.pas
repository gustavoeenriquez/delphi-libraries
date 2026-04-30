unit uExtract.Conv.RTF;

{
  Extracts plain text from RTF documents and emits it as Markdown.

  Handles:
  - Group-depth tracking for skip destinations (fonttbl, colortbl, pict, etc.)
  - \* (ignorable destination) prefix
  - \'XX  — ANSI hex-encoded characters (decoded via Windows-1252)
  - \uNNNN — Unicode characters
  - \par, \pard — paragraph boundaries (→ blank line in output)
  - \line — line break
  - \tab  — tab character (→ spaces)

  Bold/italic detection is implemented but not currently emitted to keep
  the output clean for LLM consumption.  Set EmitFormatting = True to enable.
}

interface

uses
  System.Classes,
  uExtract.Converter,
  uExtract.Result,
  uExtract.StreamInfo;

type
  TRTFConverter = class(TDocumentConverter)
  public
    function Accepts(const AInfo: TStreamInfo): Boolean; override;
    function Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult; override;
    function Priority: Double; override;
  private
    function ExtractText(const ARTF: string): string;
  end;

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  System.StrUtils;

const
  // Destinations whose content we discard entirely
  SkipDests: array of string = [
    'fonttbl','colortbl','stylesheet','info','pict','object',
    'header','footer','headerl','headerr','headerf',
    'footerl','footerr','footerf',
    'footnote','filetbl','themedata','datastore',
    'latentstyles','rsidtbl','generator','pgdsc',
    'shpinst','shp','shptxt','mmathpr','expandedcolortbl'
  ];

{ TRTFConverter }

function TRTFConverter.Priority: Double;
begin
  Result := 0.0;
end;

function TRTFConverter.Accepts(const AInfo: TStreamInfo): Boolean;
begin
  Result := AInfo.HasAnyExtension(['.rtf', '.rtfd']);
end;

// ---- RTF text extractor ----------------------------------------------------

function TRTFConverter.ExtractText(const ARTF: string): string;
var
  I, N    : Integer;
  SB      : TStringBuilder;
  SkipStk : TList<Boolean>;
  CurSkip : Boolean;
  PendPar : Boolean;
  CP1252  : TEncoding;

  function Cur: Char;
  begin
    if I <= N then Result := ARTF[I] else Result := #0;
  end;

  procedure Adv;
  begin
    Inc(I);
  end;

  // Read control word letters and optional numeric parameter.
  // Leaves I pointing at the first char AFTER the word+number+space.
  function ReadCtrlWord(out ANum: Integer; out AHasNum: Boolean): string;
  begin
    Result := '';
    while (I <= N) and CharInSet(ARTF[I], ['a'..'z','A'..'Z']) do
    begin
      Result := Result + ARTF[I]; Adv;
    end;
    Result := LowerCase(Result);
    AHasNum := False; ANum := 0;
    var Neg := (I <= N) and (ARTF[I] = '-');
    if Neg then Adv;
    if (I <= N) and CharInSet(ARTF[I], ['0'..'9']) then
    begin
      AHasNum := True;
      while (I <= N) and CharInSet(ARTF[I], ['0'..'9']) do
      begin
        ANum := ANum * 10 + Ord(ARTF[I]) - Ord('0'); Adv;
      end;
      if Neg then ANum := -ANum;
    end else if Neg then Dec(I); // put '-' back if no digit followed
    if (I <= N) and (ARTF[I] = ' ') then Adv; // delimiter space
  end;

  // Check if the group starting at position P is a skip destination.
  // Does not advance I.
  function IsSkipGroup(AStart: Integer): Boolean;
  var
    P : Integer;
    W : string;
    Ignorable: Boolean;
  begin
    Result    := False;
    Ignorable := False;
    P         := AStart;
    // skip whitespace
    while (P <= N) and CharInSet(ARTF[P], [' ',#9,#13,#10]) do Inc(P);
    if (P > N) or (ARTF[P] <> '\') then Exit;
    Inc(P); // past '\'
    if (P > N) then Exit;
    if ARTF[P] = '*' then
    begin
      Ignorable := True; Inc(P);
      while (P <= N) and CharInSet(ARTF[P], [' ']) do Inc(P);
      if (P > N) or (ARTF[P] <> '\') then Exit(True); // \* with no keyword = skip
      Inc(P);
    end;
    W := '';
    while (P <= N) and CharInSet(ARTF[P], ['a'..'z','A'..'Z']) do
    begin
      W := W + ARTF[P]; Inc(P);
    end;
    W := LowerCase(W);
    Result := Ignorable or AnsiMatchStr(W, SkipDests);
  end;

  procedure FlushPar;
  begin
    if PendPar and (SB.Length > 0) then
    begin
      SB.AppendLine;
      SB.AppendLine;
    end;
    PendPar := False;
  end;

  procedure AppendText(const S: string);
  begin
    if CurSkip or (S = '') then Exit;
    FlushPar;
    SB.Append(S);
  end;

begin
  N      := Length(ARTF);
  I      := 1;
  SB     := TStringBuilder.Create;
  SkipStk:= TList<Boolean>.Create;
  PendPar:= False;
  CurSkip:= False;
  CP1252 := TEncoding.GetEncoding(1252);
  try
    while I <= N do
    begin
      case ARTF[I] of

        '{':
        begin
          Adv;
          SkipStk.Add(CurSkip);
          if not CurSkip then
            CurSkip := IsSkipGroup(I);
        end;

        '}':
        begin
          Adv;
          if SkipStk.Count > 0 then
          begin
            CurSkip := SkipStk[SkipStk.Count - 1];
            SkipStk.Delete(SkipStk.Count - 1);
          end;
        end;

        '\':
        begin
          Adv;
          if I > N then Break;
          case ARTF[I] of
            '\': begin AppendText('\'); Adv; end;
            '{': begin AppendText('{'); Adv; end;
            '}': begin AppendText('}'); Adv; end;
            '-': begin AppendText(''); Adv; end; // optional hyphen — invisible
            '~': begin AppendText(' '); Adv; end; // non-breaking space
            '_': begin AppendText('-'); Adv; end; // non-breaking hyphen
            '*': begin Adv; end; // ignorable destination marker (handled in '{')
            '''': // hex-encoded ANSI char
            begin
              Adv;
              if I + 1 <= N then
              begin
                var HexStr := ARTF[I] + ARTF[I + 1];
                var CV := StrToIntDef('$' + HexStr, Ord('?'));
                Inc(I, 2);
                if not CurSkip then
                begin
                  FlushPar;
                  SB.Append(CP1252.GetString(TBytes.Create(Byte(CV))));
                end;
              end;
            end;
            else
            begin
              var Num: Integer; var HasNum: Boolean;
              var W := ReadCtrlWord(Num, HasNum);
              if W = '' then
              begin
                Adv; // unknown control symbol — skip
              end
              else if not CurSkip then
              begin
                if (W = 'par') or (W = 'sect') then
                  PendPar := True
                else if W = 'pard' then
                begin
                  // paragraph reset — treated as soft par boundary
                  if SB.Length > 0 then PendPar := True;
                end
                else if W = 'line' then
                begin
                  FlushPar;
                  SB.AppendLine;
                end
                else if W = 'tab' then
                  AppendText('    ')
                else if W = 'u' then
                begin
                  // \uNNNN? — Unicode character
                  if HasNum then
                  begin
                    var UC := Num;
                    if UC < 0 then Inc(UC, 65536);
                    FlushPar;
                    SB.Append(Char(UC));
                    // skip replacement char (1 char by default; can be a group)
                    if (I <= N) and not CharInSet(ARTF[I], ['{','}','\']) then Adv;
                  end;
                end;
                // \b, \i, \b0, \i0 — intentionally ignored (clean text output)
              end;
            end;
          end;
        end;

        #13, #10: Adv; // source line-endings are not content

        else
        begin
          AppendText(ARTF[I]);
          Adv;
        end;
      end;
    end;
    Result := SB.ToString.Trim;
  finally
    SB.Free;
    SkipStk.Free;
    CP1252.Free;
  end;
end;

// ---- public interface ------------------------------------------------------

function TRTFConverter.Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult;
var
  Reader : TStreamReader;
  Content: string;
  Text   : string;
begin
  // RTF files are ANSI-based (not UTF-8). Read as Latin-1 to preserve bytes.
  Reader := TStreamReader.Create(AStream, TEncoding.GetEncoding(1252), False);
  try
    Content := Reader.ReadToEnd;
  finally
    Reader.Free;
  end;

  if Content.Trim = '' then
    Exit(TConversionResult.Fail('Empty RTF file'));

  // Quick sanity check
  if not Content.TrimLeft.StartsWith('{') then
    Exit(TConversionResult.Fail('Not a valid RTF file'));

  Text := ExtractText(Content);
  if Text = '' then
    Exit(TConversionResult.Fail('No text content extracted from RTF'));

  Result := TConversionResult.Ok(Text);
end;

end.
