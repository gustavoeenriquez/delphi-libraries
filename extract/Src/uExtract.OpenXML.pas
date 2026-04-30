unit uExtract.OpenXML;

{
  Shared helpers for Open XML (DOCX / XLSX / PPTX) converters.

  All Office Open XML documents are ZIP archives whose content parts are XML.
  This unit provides:
    OXReadEntry  — read a ZIP entry as a UTF-8 string
    OXAttr       — extract an attribute value from a raw attribute string
    OXStripNs    — strip the XML namespace prefix from a tag name
    OXDecode     — decode XML character entities
    OXScanXML    — minimal event-based XML scanner

  The scanner calls AOnTag(tagName, attrs, isOpen) where:
    - tagName   is lowercased and namespace-stripped ("w:document" → "document")
    - attrs     is the raw attribute substring (namespace prefixes intact)
    - isOpen    is True for opening tags, False for closing tags
  Self-closing tags produce two consecutive calls: True then False.
  AOnText receives decoded text from text nodes (not CDATA content).
  Comments and processing instructions are silently skipped.
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Zip,
  System.StrUtils;

function OXReadEntry(AZip: TZipFile; const APath: string): string;
function OXAttr(const AAttrs, AName: string): string;
function OXStripNs(const ATag: string): string;
function OXDecode(const S: string): string;

type
  TXMLTagCB  = reference to procedure(const ATag, AAttrs: string; AIsOpen: Boolean);
  TXMLTextCB = reference to procedure(const AText: string);

procedure OXScanXML(const AXml: string; AOnTag: TXMLTagCB; AOnText: TXMLTextCB);

implementation

function OXReadEntry(AZip: TZipFile; const APath: string): string;
var
  S: TStream;
  H: TZipHeader;
  R: TStreamReader;
begin
  Result := '';
  if AZip.IndexOf(APath) < 0 then Exit;
  AZip.Read(APath, S, H);
  try
    R := TStreamReader.Create(S, TEncoding.UTF8, True);
    try
      Result := R.ReadToEnd;
    finally
      R.Free;
    end;
  finally
    S.Free;
  end;
end;

function OXAttr(const AAttrs, AName: string): string;
var
  P, Q: Integer;
  QC: Char;
begin
  Result := '';
  P := Pos(AName + '="', AAttrs);
  if P > 0 then
  begin
    QC := '"';
    Inc(P, Length(AName) + 2);
  end
  else
  begin
    P := Pos(AName + '=''', AAttrs);
    if P = 0 then Exit;
    QC := '''';
    Inc(P, Length(AName) + 2);
  end;
  Q := PosEx(QC, AAttrs, P);
  if Q >= P then Result := Copy(AAttrs, P, Q - P);
end;

function OXStripNs(const ATag: string): string;
var
  P: Integer;
begin
  P := Pos(':', ATag);
  if P > 0 then Result := Copy(ATag, P + 1, MaxInt)
  else Result := ATag;
end;

function OXDecode(const S: string): string;
var
  SB      : TStringBuilder;
  I, N, Q : Integer;
  CV      : Integer;
  E       : string;
begin
  if Pos('&', S) = 0 then Exit(S);
  N := Length(S);
  I := 1;
  SB := TStringBuilder.Create(N);
  try
    while I <= N do
    begin
      if S[I] <> '&' then
      begin
        SB.Append(S[I]);
        Inc(I);
      end
      else
      begin
        Q := PosEx(';', S, I + 1);
        if Q = 0 then begin SB.Append(S[I]); Inc(I); Continue; end;
        E := Copy(S, I + 1, Q - I - 1);
        I := Q + 1;
        if      E = 'amp'  then SB.Append('&')
        else if E = 'lt'   then SB.Append('<')
        else if E = 'gt'   then SB.Append('>')
        else if E = 'quot' then SB.Append('"')
        else if E = 'apos' then SB.Append('''')
        else if E = 'nbsp' then SB.Append(#160)
        else if (Length(E) >= 2) and (E[1] = '#') then
        begin
          if (Length(E) >= 3) and (E[2] = 'x') then
            CV := StrToIntDef('$' + Copy(E, 3, MaxInt), 0)
          else
            CV := StrToIntDef(Copy(E, 2, MaxInt), 0);
          if CV > 0 then SB.Append(Char(CV));
        end
        else
          SB.Append('&').Append(E).Append(';');
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure OXScanXML(const AXml: string; AOnTag: TXMLTagCB; AOnText: TXMLTextCB);
var
  I, N          : Integer;
  TStart        : Integer;
  IsClose, IsSelf: Boolean;
  InQ           : Boolean;
  QC            : Char;
  TagName, Attrs: string;
  AStart, ALen  : Integer;
begin
  I := 1;
  N := Length(AXml);
  while I <= N do
  begin
    if AXml[I] <> '<' then
    begin
      TStart := I;
      while (I <= N) and (AXml[I] <> '<') do Inc(I);
      AOnText(OXDecode(Copy(AXml, TStart, I - TStart)));
    end
    else
    begin
      Inc(I);
      if I > N then Break;

      // <!-- comment -->
      if (I + 2 <= N) and (AXml[I] = '!') and (AXml[I+1] = '-') and (AXml[I+2] = '-') then
      begin
        Inc(I, 3);
        while (I + 2 <= N) and
              not ((AXml[I] = '-') and (AXml[I+1] = '-') and (AXml[I+2] = '>')) do
          Inc(I);
        Inc(I, 3);
        Continue;
      end;

      // <![CDATA[...]]>
      if (I + 7 <= N) and (Copy(AXml, I, 8) = '![CDATA[') then
      begin
        Inc(I, 8);
        TStart := I;
        while (I + 2 <= N) and
              not ((AXml[I] = ']') and (AXml[I+1] = ']') and (AXml[I+2] = '>')) do
          Inc(I);
        AOnText(Copy(AXml, TStart, I - TStart));
        Inc(I, 3);
        Continue;
      end;

      // <?...?> processing instruction
      if (I <= N) and (AXml[I] = '?') then
      begin
        while (I + 1 <= N) and not ((AXml[I] = '?') and (AXml[I+1] = '>')) do Inc(I);
        Inc(I, 2);
        Continue;
      end;

      // <!DOCTYPE ...> or other <!...>
      if (I <= N) and (AXml[I] = '!') then
      begin
        while (I <= N) and (AXml[I] <> '>') do Inc(I);
        Inc(I);
        Continue;
      end;

      // closing tag: </tagName>
      IsClose := (I <= N) and (AXml[I] = '/');
      if IsClose then Inc(I);

      // read tag name
      TStart := I;
      while (I <= N) and not CharInSet(AXml[I], [' ', #9, #10, #13, '>', '/']) do Inc(I);
      TagName := LowerCase(OXStripNs(Copy(AXml, TStart, I - TStart)));

      // skip whitespace before attributes
      while (I <= N) and CharInSet(AXml[I], [' ', #9, #10, #13]) do Inc(I);

      // read raw attribute string up to > or />
      AStart := I;
      InQ := False;
      QC := '"';
      while I <= N do
      begin
        if InQ then
        begin
          if AXml[I] = QC then InQ := False;
        end
        else if CharInSet(AXml[I], ['"', '''']) then
        begin
          InQ := True;
          QC := AXml[I];
        end
        else if AXml[I] = '>' then
          Break;
        Inc(I);
      end;
      IsSelf := (I > AStart) and (AXml[I - 1] = '/');
      ALen := I - AStart;
      if IsSelf and (ALen > 0) then Dec(ALen);
      Attrs := Copy(AXml, AStart, ALen);
      if (I <= N) and (AXml[I] = '>') then Inc(I);

      if TagName = '' then Continue;

      if IsClose then
        AOnTag(TagName, '', False)
      else
      begin
        AOnTag(TagName, Attrs, True);
        if IsSelf then AOnTag(TagName, '', False);
      end;
    end;
  end;
end;

end.
