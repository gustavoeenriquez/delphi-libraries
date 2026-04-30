unit uExtract.Conv.HTML;

{
  Converts HTML to Markdown.

  Supported:
  - Headings      h1-h6  →  # through ######
  - Block         p, div, article, section, main, header, footer, nav, aside...
  - Inline        strong/b, em/i, code, a (links), img
  - Lists         ul / ol / li  (nested, indented)
  - Tables        table / tr / th / td
  - Blockquote    →  > prefixed lines
  - Code block    pre  →  ``` fence
  - Special       hr → ---, br → newline

  Tags whose content is discarded:
  script, style, noscript, iframe, object, embed, svg, math, canvas

  <head> is skipped except for <title>.
}

interface

uses
  System.Classes,
  uExtract.Converter,
  uExtract.Result,
  uExtract.StreamInfo;

type
  THTMLConverter = class(TDocumentConverter)
  public
    function Accepts(const AInfo: TStreamInfo): Boolean; override;
    function Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult; override;
    function Priority: Double; override;
  end;

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  System.StrUtils;

// ==========================================================================
// Internal parser
// ==========================================================================

type
  TListEntry = record Kind: Char; Counter: Integer; end;

  THTMLParser = class
  private
    FSrc      : string;
    FPos      : Integer;
    // output redirect stack
    FMain     : TStringBuilder;
    FOut      : TStringBuilder;
    FOutStack : TList<TStringBuilder>;
    // metadata
    FTitle    : string;
    FTitleBuf : TStringBuilder;
    // context flags / depth
    FSkip     : Integer;
    FHead     : Integer;
    FInTitle  : Boolean;
    FPre      : Integer;
    FBold     : Integer;
    FItalic   : Integer;
    FCode     : Integer;
    // blockquote buffers  (owned by caller, not by FBQBufs)
    FBQBufs   : TObjectList<TStringBuilder>;
    // links
    FInLink   : Boolean;
    FLinkHref : string;
    FLinkBuf  : TStringBuilder;
    // lists
    FLists    : TList<TListEntry>;
    // tables
    FInTable  : Boolean;
    FTRows    : TObjectList<TStringList>;
    FCurRow   : TStringList;
    FCellBuf  : TStringBuilder;
    FInCell   : Boolean;
    // output control
    FPendNL   : Integer;

    // tokenizer
    function  Cur: Char; inline;
    function  Peek(AOfs: Integer = 1): Char; inline;
    function  AtEnd: Boolean; inline;
    procedure Adv; inline;
    procedure SkipWS;
    function  ReadIdent: string;
    function  ReadAttrVal: string;
    function  ParseAttrs: TDictionary<string, string>;
    procedure ParseTag;
    procedure ParseComment;

    // handlers
    procedure OnOpen(const ATag: string; const AAttrs: TDictionary<string, string>; AIsSelf: Boolean);
    procedure OnClose(const ATag: string);
    procedure OnText(const ARaw: string);

    // output helpers
    function  DecodeEntities(const S: string): string;
    procedure NeedNL(ACount: Integer); inline;
    procedure Emit(const S: string);
    procedure PushBuf(ABuf: TStringBuilder);
    procedure PopBuf;

    // classify
    function  IsVoid(const ATag: string): Boolean;
    function  IsSkip(const ATag: string): Boolean;
    function  IsBlock(const ATag: string): Boolean;

    // list / table helpers
    function  ListPrefix: string;
    procedure CloseBlockquote;
    procedure FlushTable;

  public
    constructor Create;
    destructor  Destroy; override;
    procedure   Parse(const AHTML: string);
    function    GetMarkdown: string;
    property    Title: string read FTitle;
  end;

// --------------------------------------------------------------------------

constructor THTMLParser.Create;
begin
  inherited;
  FMain     := TStringBuilder.Create;
  FOut      := FMain;
  FOutStack := TList<TStringBuilder>.Create;
  FTitleBuf := TStringBuilder.Create;
  FLinkBuf  := TStringBuilder.Create;
  FCellBuf  := TStringBuilder.Create;
  FBQBufs   := TObjectList<TStringBuilder>.Create(True {owns});
  FLists    := TList<TListEntry>.Create;
  FTRows    := TObjectList<TStringList>.Create(True);
end;

destructor THTMLParser.Destroy;
begin
  FMain.Free; FOutStack.Free;
  FTitleBuf.Free; FLinkBuf.Free; FCellBuf.Free;
  FBQBufs.Free; FLists.Free; FTRows.Free;
  if Assigned(FCurRow) then FCurRow.Free;
  inherited;
end;

function THTMLParser.GetMarkdown: string;
begin
  Result := FMain.ToString;
end;

// --------------------------------------------------------------------------
// Tokenizer helpers
// --------------------------------------------------------------------------

function THTMLParser.Cur: Char;
begin
  if FPos <= Length(FSrc) then Result := FSrc[FPos] else Result := #0;
end;

function THTMLParser.Peek(AOfs: Integer): Char;
begin
  if FPos + AOfs <= Length(FSrc) then Result := FSrc[FPos + AOfs] else Result := #0;
end;

function THTMLParser.AtEnd: Boolean;
begin
  Result := FPos > Length(FSrc);
end;

procedure THTMLParser.Adv;
begin
  Inc(FPos);
end;

procedure THTMLParser.SkipWS;
begin
  while not AtEnd and CharInSet(Cur, [' ', #9, #10, #13]) do Adv;
end;

function THTMLParser.ReadIdent: string;
begin
  Result := '';
  while not AtEnd and CharInSet(Cur, ['a'..'z','A'..'Z','0'..'9','-','_',':','.']) do
  begin
    Result := Result + Cur; Adv;
  end;
end;

function THTMLParser.ReadAttrVal: string;
var
  Q: Char;
begin
  Result := '';
  if AtEnd then Exit;
  if CharInSet(Cur, ['"','''']) then
  begin
    Q := Cur; Adv;
    while not AtEnd and (Cur <> Q) do begin Result := Result + Cur; Adv; end;
    if not AtEnd then Adv;
  end
  else
    while not AtEnd and not CharInSet(Cur, [' ',#9,#10,#13,'>','/']) do
    begin Result := Result + Cur; Adv; end;
end;

function THTMLParser.ParseAttrs: TDictionary<string, string>;
var
  Name, Val: string;
begin
  Result := TDictionary<string, string>.Create;
  try
    while not AtEnd and not CharInSet(Cur, ['>','/']) do
    begin
      SkipWS;
      if AtEnd or CharInSet(Cur, ['>','/']) then Break;
      Name := LowerCase(ReadIdent);
      if Name = '' then begin Adv; Continue; end;
      SkipWS;
      if Cur = '=' then begin Adv; SkipWS; Val := ReadAttrVal; end
      else Val := '';
      if not Result.ContainsKey(Name) then Result.Add(Name, Val);
    end;
  except
    Result.Free; raise;
  end;
end;

procedure THTMLParser.ParseComment;
begin
  // entered after '<!--', skip until '-->'
  while not AtEnd do
  begin
    if (Cur = '-') and (Peek = '-') and (Peek(2) = '>') then
    begin
      Adv; Adv; Adv; Exit;
    end;
    Adv;
  end;
end;

procedure THTMLParser.ParseTag;
var
  IsClose : Boolean;
  IsSelf  : Boolean;
  TagName : string;
  Attrs   : TDictionary<string, string>;
begin
  IsClose := Cur = '/';
  if IsClose then Adv;

  TagName := LowerCase(ReadIdent);
  if TagName = '' then
  begin
    while not AtEnd and (Cur <> '>') do Adv;
    if not AtEnd then Adv;
    Exit;
  end;

  if IsClose then
  begin
    while not AtEnd and (Cur <> '>') do Adv;
    if not AtEnd then Adv;
    OnClose(TagName);
    Exit;
  end;

  Attrs := ParseAttrs;
  try
    SkipWS;
    IsSelf := (Cur = '/') or IsVoid(TagName);
    if Cur = '/' then Adv;
    if not AtEnd and (Cur = '>') then Adv;
    OnOpen(TagName, Attrs, IsSelf);
  finally
    Attrs.Free;
  end;
end;

// --------------------------------------------------------------------------
// Output helpers
// --------------------------------------------------------------------------

procedure THTMLParser.NeedNL(ACount: Integer);
begin
  if ACount > FPendNL then FPendNL := ACount;
end;

// Emit flushes pending newlines then appends S.
// Does NOT trim S — list prefixes with spaces must be preserved.
procedure THTMLParser.Emit(const S: string);
begin
  if S = '' then Exit;
  if (FPendNL > 0) and (FOut.Length > 0) then
    FOut.Append(StringOfChar(#10, FPendNL));
  FPendNL := 0;
  FOut.Append(S);
end;

procedure THTMLParser.PushBuf(ABuf: TStringBuilder);
begin
  FOutStack.Add(FOut);
  ABuf.Clear;
  FOut    := ABuf;
  FPendNL := 0;
end;

procedure THTMLParser.PopBuf;
begin
  if FOutStack.Count > 0 then
  begin
    FOut := FOutStack[FOutStack.Count - 1];
    FOutStack.Delete(FOutStack.Count - 1);
    FPendNL := 0;
  end;
end;

// --------------------------------------------------------------------------
// Classifiers
// --------------------------------------------------------------------------

function THTMLParser.IsVoid(const ATag: string): Boolean;
begin
  Result := AnsiMatchStr(ATag,
    ['area','base','br','col','embed','hr','img','input',
     'link','meta','param','source','track','wbr']);
end;

function THTMLParser.IsSkip(const ATag: string): Boolean;
begin
  Result := AnsiMatchStr(ATag,
    ['script','style','noscript','iframe','object',
     'embed','svg','math','canvas']);
end;

function THTMLParser.IsBlock(const ATag: string): Boolean;
begin
  Result := AnsiMatchStr(ATag,
    ['div','article','section','main','header','footer','nav',
     'aside','address','details','summary','figure','figcaption',
     'form','fieldset','hgroup','dialog']);
end;

// --------------------------------------------------------------------------
// Entity decoder
// --------------------------------------------------------------------------

function THTMLParser.DecodeEntities(const S: string): string;
var
  I, J : Integer;
  SB   : TStringBuilder;
  E    : string;
  C    : Char;
begin
  if Pos('&', S) = 0 then Exit(S);
  SB := TStringBuilder.Create;
  try
    I := 1;
    while I <= Length(S) do
    begin
      if S[I] = '&' then
      begin
        J := I + 1;
        while (J <= Length(S)) and (S[J] <> ';') and (J - I < 14) do Inc(J);
        if (J <= Length(S)) and (S[J] = ';') then
        begin
          E := Copy(S, I + 1, J - I - 1);
          C := #0;
          if      E = 'amp'    then C := '&'
          else if E = 'lt'     then C := '<'
          else if E = 'gt'     then C := '>'
          else if E = 'quot'   then C := '"'
          else if E = 'apos'   then C := ''''
          else if E = 'nbsp'   then C := ' '
          else if E = 'mdash'  then C := '—'
          else if E = 'ndash'  then C := '–'
          else if E = 'hellip' then C := '…'
          else if E = 'copy'   then C := '©'
          else if E = 'reg'    then C := '®'
          else if E = 'trade'  then C := '™'
          else if E = 'laquo'  then C := '«'
          else if E = 'raquo'  then C := '»'
          else if E.StartsWith('#') then
          begin
            try
              var NumStr := Copy(E, 2, MaxInt);
              var CP: Integer;
              if (NumStr <> '') and CharInSet(NumStr[1], ['x','X']) then
                CP := StrToInt('$' + Copy(NumStr, 2, MaxInt))
              else
                CP := StrToInt(NumStr);
              if (CP > 0) and (CP < $D800) then C := Char(CP)
              else if (CP >= $E000) and (CP < $110000) then C := Char(CP);
            except end;
          end;
          if C <> #0 then begin SB.Append(C); I := J + 1; Continue; end;
        end;
      end;
      SB.Append(S[I]); Inc(I);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

// --------------------------------------------------------------------------
// List prefix
// --------------------------------------------------------------------------

function THTMLParser.ListPrefix: string;
var
  E: TListEntry; Upd: TListEntry;
begin
  if FLists.Count = 0 then Exit('- ');
  E := FLists[FLists.Count - 1];
  var Indent := StringOfChar(' ', (FLists.Count - 1) * 2);
  if E.Kind = 'o' then
  begin
    Result  := Indent + IntToStr(E.Counter) + '. ';
    Upd     := E; Upd.Counter := E.Counter + 1;
    FLists[FLists.Count - 1] := Upd;
  end
  else
    Result := Indent + '- ';
end;

// --------------------------------------------------------------------------
// Blockquote close
// --------------------------------------------------------------------------

procedure THTMLParser.CloseBlockquote;
var
  BQBuf  : TStringBuilder;
  Content: string;
  Lines  : TArray<string>;
  I      : Integer;
begin
  if FBQBufs.Count = 0 then Exit;

  // Extract WITHOUT freeing (OwnsObjects = True would free it on Delete)
  BQBuf := FBQBufs.Extract(FBQBufs[FBQBufs.Count - 1]);
  PopBuf;
  Content := BQBuf.ToString.Trim;
  BQBuf.Free;

  if Content = '' then Exit;
  Lines := Content.Split([#10]);
  NeedNL(2);
  for I := 0 to High(Lines) do
  begin
    Emit('> ' + Lines[I]);
    if I < High(Lines) then
    begin
      if FOut.Length > 0 then FOut.Append(#10);
    end;
  end;
  NeedNL(2);
end;

// --------------------------------------------------------------------------
// Table flush
// --------------------------------------------------------------------------

procedure THTMLParser.FlushTable;
var
  Row  : TStringList;
  I, J : Integer;
  Cols : Integer;
  Cell : string;
  SB   : TStringBuilder;
begin
  if Assigned(FCurRow) then
  begin
    FTRows.Add(FCurRow); FCurRow := nil;
  end;
  if FTRows.Count = 0 then begin FInTable := False; Exit; end;

  Cols := 0;
  for Row in FTRows do
    if Row.Count > Cols then Cols := Row.Count;

  SB := TStringBuilder.Create;
  try
    for I := 0 to FTRows.Count - 1 do
    begin
      Row := FTRows[I];
      SB.Append('|');
      for J := 0 to Cols - 1 do
      begin
        if J < Row.Count then Cell := Row[J].Replace('|','\|').Replace(#10,' ')
        else Cell := '';
        SB.Append(' ').Append(Cell.Trim).Append(' |');
      end;
      SB.AppendLine;
      if I = 0 then
      begin
        SB.Append('|');
        for J := 0 to Cols - 1 do SB.Append(' --- |');
        SB.AppendLine;
      end;
    end;
    NeedNL(2);
    Emit(SB.ToString.TrimRight);
    NeedNL(2);
  finally
    SB.Free;
  end;

  FTRows.Clear;
  FInTable := False;
end;

// --------------------------------------------------------------------------
// OnText
// --------------------------------------------------------------------------

procedure THTMLParser.OnText(const ARaw: string);
var
  Decoded, Col: string;
  WS: Boolean;
  Ch: Char;
begin
  if FSkip > 0 then Exit;
  if FHead > 0 then begin if FInTitle then FTitleBuf.Append(ARaw); Exit; end;

  Decoded := DecodeEntities(ARaw);

  if FPre > 0 then
  begin
    Emit(Decoded); Exit;
  end;

  // collapse whitespace
  Col := ''; WS := False;
  for Ch in Decoded do
    if CharInSet(Ch, [' ',#9,#10,#13]) then begin if not WS then Col := Col + ' '; WS := True; end
    else begin Col := Col + Ch; WS := False; end;

  // trim leading space at block boundary or document start
  if (FOut.Length = 0) or (FPendNL > 0) then
    Col := Col.TrimLeft;

  if Col.Trim <> '' then Emit(Col);
end;

// --------------------------------------------------------------------------
// OnOpen
// --------------------------------------------------------------------------

procedure THTMLParser.OnOpen(const ATag: string; const AAttrs: TDictionary<string, string>; AIsSelf: Boolean);
var
  ListE : TListEntry;
  BQBuf : TStringBuilder;
begin
  if FSkip > 0 then begin if not AIsSelf then Inc(FSkip); Exit; end;

  if IsSkip(ATag) then begin if not AIsSelf then FSkip := 1; Exit; end;

  if ATag = 'head' then begin Inc(FHead); Exit; end;
  if FHead > 0 then begin if ATag = 'title' then begin FInTitle := True; FTitleBuf.Clear; end; Exit; end;

  // headings
  if (Length(ATag) = 2) and (ATag[1] = 'h') and CharInSet(ATag[2], ['1'..'6']) then
  begin
    NeedNL(2); Emit(StringOfChar('#', Ord(ATag[2]) - Ord('0')) + ' '); Exit;
  end;

  if (ATag = 'p') or IsBlock(ATag) then begin NeedNL(2); Exit; end;
  if (ATag = 'html') or (ATag = 'body') then Exit;

  if ATag = 'hr' then begin NeedNL(2); Emit('---'); NeedNL(2); Exit; end;
  if ATag = 'br' then begin NeedNL(1); Exit; end;

  if ATag = 'pre' then
  begin
    Inc(FPre); NeedNL(2); Emit('```'); NeedNL(1); Exit;
  end;

  if ATag = 'blockquote' then
  begin
    BQBuf := TStringBuilder.Create;
    FBQBufs.Add(BQBuf);
    PushBuf(BQBuf); Exit;
  end;

  if (ATag = 'strong') or (ATag = 'b') then
  begin
    Inc(FBold); if FBold = 1 then Emit('**'); Exit;
  end;

  if (ATag = 'em') or (ATag = 'i') then
  begin
    Inc(FItalic); if FItalic = 1 then Emit('*'); Exit;
  end;

  if ATag = 'code' then
  begin
    Inc(FCode); if (FCode = 1) and (FPre = 0) then Emit('`'); Exit;
  end;

  if ATag = 'a' then
  begin
    if not FInLink then
    begin
      FLinkHref := ''; AAttrs.TryGetValue('href', FLinkHref);
      FInLink := True; PushBuf(FLinkBuf);
    end;
    Exit;
  end;

  if ATag = 'img' then
  begin
    var Alt := ''; AAttrs.TryGetValue('alt', Alt);
    var Src := ''; AAttrs.TryGetValue('src', Src);
    Emit('![' + Alt + '](' + Src + ')'); Exit;
  end;

  if ATag = 'ul' then
  begin
    ListE.Kind := 'u'; ListE.Counter := 0; FLists.Add(ListE); NeedNL(2); Exit;
  end;
  if ATag = 'ol' then
  begin
    ListE.Kind := 'o'; ListE.Counter := 1; FLists.Add(ListE); NeedNL(2); Exit;
  end;
  if ATag = 'li' then begin NeedNL(1); Emit(ListPrefix); Exit; end;

  if ATag = 'table' then begin FInTable := True; FCurRow := nil; FTRows.Clear; NeedNL(2); Exit; end;
  if (ATag = 'tr') and FInTable then begin FCurRow := TStringList.Create; Exit; end;
  if ((ATag = 'th') or (ATag = 'td')) and FInTable then begin FInCell := True; PushBuf(FCellBuf); Exit; end;
end;

// --------------------------------------------------------------------------
// OnClose
// --------------------------------------------------------------------------

procedure THTMLParser.OnClose(const ATag: string);
var
  CellText: string;
begin
  if FSkip > 0 then begin Dec(FSkip); Exit; end;

  if ATag = 'head' then begin Dec(FHead); Exit; end;
  if FHead > 0 then
  begin
    if ATag = 'title' then
    begin FTitle := DecodeEntities(FTitleBuf.ToString).Trim; FInTitle := False; end;
    Exit;
  end;

  if (Length(ATag) = 2) and (ATag[1] = 'h') and CharInSet(ATag[2], ['1'..'6']) then
  begin NeedNL(2); Exit; end;

  if (ATag = 'p') or IsBlock(ATag) then begin NeedNL(2); Exit; end;
  if (ATag = 'html') or (ATag = 'body') then Exit;

  if ATag = 'pre' then
  begin
    if FPre > 0 then Dec(FPre);
    NeedNL(1); Emit('```'); NeedNL(2); Exit;
  end;

  if ATag = 'blockquote' then begin CloseBlockquote; Exit; end;

  if (ATag = 'strong') or (ATag = 'b') then
  begin
    if FBold > 0 then begin if FBold = 1 then Emit('**'); Dec(FBold); end; Exit;
  end;

  if (ATag = 'em') or (ATag = 'i') then
  begin
    if FItalic > 0 then begin if FItalic = 1 then Emit('*'); Dec(FItalic); end; Exit;
  end;

  if ATag = 'code' then
  begin
    if FCode > 0 then begin if (FCode = 1) and (FPre = 0) then Emit('`'); Dec(FCode); end; Exit;
  end;

  if (ATag = 'a') and FInLink then
  begin
    var LinkText := FLinkBuf.ToString.Trim;
    PopBuf; FInLink := False;
    if LinkText <> '' then
    begin
      if FLinkHref <> '' then Emit('[' + LinkText + '](' + FLinkHref + ')')
      else Emit(LinkText);
    end;
    Exit;
  end;

  if (ATag = 'ul') or (ATag = 'ol') then
  begin
    if FLists.Count > 0 then FLists.Delete(FLists.Count - 1);
    NeedNL(2); Exit;
  end;
  if ATag = 'li' then begin NeedNL(1); Exit; end;

  if ((ATag = 'th') or (ATag = 'td')) and FInCell then
  begin
    PopBuf;
    CellText := FCellBuf.ToString.Trim;
    if Assigned(FCurRow) then FCurRow.Add(CellText);
    FInCell := False;
    Exit;
  end;

  if (ATag = 'tr') and FInTable then
  begin
    if Assigned(FCurRow) then begin FTRows.Add(FCurRow); FCurRow := nil; end;
    Exit;
  end;

  if ATag = 'table' then begin FlushTable; Exit; end;

  if (ATag = 'thead') or (ATag = 'tbody') or (ATag = 'tfoot') then Exit;
end;

// --------------------------------------------------------------------------
// Main parse loop
// --------------------------------------------------------------------------

procedure THTMLParser.Parse(const AHTML: string);
var
  Start: Integer;
begin
  FSrc := AHTML;
  FPos := 1;

  while not AtEnd do
  begin
    if Cur = '<' then
    begin
      Adv;
      if AtEnd then Break;

      if Cur = '!' then
      begin
        Adv;
        if (Cur = '-') and (Peek = '-') then
          ParseComment
        else
          begin while not AtEnd and (Cur <> '>') do Adv; if not AtEnd then Adv; end;
      end
      else if Cur = '?' then
      begin
        while not AtEnd and not ((Cur = '?') and (Peek = '>')) do Adv;
        if not AtEnd then begin Adv; Adv; end;
      end
      else
        ParseTag;
    end
    else
    begin
      Start := FPos;
      while not AtEnd and (Cur <> '<') do Adv;
      OnText(Copy(FSrc, Start, FPos - Start));
    end;
  end;

  // Cleanup: flush any unclosed table or blockquote
  if FInTable then FlushTable;
  while FBQBufs.Count > 0 do CloseBlockquote;
end;

// ==========================================================================
// THTMLConverter
// ==========================================================================

function THTMLConverter.Priority: Double;
begin
  Result := 0.0;
end;

function THTMLConverter.Accepts(const AInfo: TStreamInfo): Boolean;
begin
  Result := AInfo.HasAnyExtension(['.html', '.htm', '.xhtml', '.shtml']) or
            (AInfo.MimeType = 'text/html');
end;

function THTMLConverter.Convert(AStream: TStream; const AInfo: TStreamInfo): TConversionResult;
var
  Reader : TStreamReader;
  Content: string;
  Parser : THTMLParser;
  MD     : string;
begin
  Reader := TStreamReader.Create(AStream, TEncoding.UTF8, True);
  try
    Content := Reader.ReadToEnd;
  finally
    Reader.Free;
  end;

  if Content.Trim = '' then
    Exit(TConversionResult.Fail('Empty HTML file'));

  Parser := THTMLParser.Create;
  try
    Parser.Parse(Content);
    MD := Parser.GetMarkdown.Trim;
    if MD = '' then
      Exit(TConversionResult.Fail('No content extracted from HTML'));
    Result := TConversionResult.Ok(MD, Parser.Title);
  finally
    Parser.Free;
  end;
end;

end.
