unit uPDF.Metadata;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.DateUtils,
  uPDF.Types, uPDF.Errors, uPDF.Objects;

type
  // -------------------------------------------------------------------------
  // Standard Info dictionary (§14.3.3)
  // -------------------------------------------------------------------------
  TPDFInfoRecord = record
    Title:        string;
    Author:       string;
    Subject:      string;
    Keywords:     string;
    Creator:      string;   // app that created the original document
    Producer:     string;   // app that converted to PDF
    CreationDate: TDateTime;
    ModDate:      TDateTime;
    Trapped:      string;   // True / False / Unknown
    HasCreationDate: Boolean;
    HasModDate:      Boolean;

    // Parse a PDF date string → TDateTime (returns 0 and False on failure)
    // Format: D:YYYYMMDDHHmmSSOHH'mm'  (all parts after D:YYYY are optional)
    class function ParseDate(const AStr: string;
                             out ADate: TDateTime): Boolean; static;
  end;

  // -------------------------------------------------------------------------
  // XMP metadata (§14.3.2) — we expose the raw XML and a handful of parsed
  // Dublin Core / PDF schema fields that duplicate the Info dict.
  // -------------------------------------------------------------------------
  TPDFXMPData = record
    RawXML:       string;   // full XMP packet as UTF-8 string
    // Dublin Core (dc:)
    DCTitle:      string;
    DCCreator:    string;
    DCDescription:string;
    DCSubject:    string;
    // PDF schema (pdf:)
    PDFProducer:  string;
    PDFKeywords:  string;
    // XMP basic (xmp:)
    XMPCreator:   string;
    XMPCreateDate:string;   // raw string; use XMPCreateDateValue for parsed
    XMPModifyDate:string;
  end;

  // -------------------------------------------------------------------------
  // Combined metadata accessor
  // -------------------------------------------------------------------------
  TPDFMetadata = class
  private
    FInfo:    TPDFInfoRecord;
    FXMP:     TPDFXMPData;
    FHasInfo: Boolean;
    FHasXMP:  Boolean;

    class procedure ParseXMP(const AXML: string;
                             out AData: TPDFXMPData); static;

    // Extract text content between <tag> and </tag> (simple, non-recursive)
    class function ExtractXMLTag(const AXML, ATag: string): string; static;
    // Extract first <rdf:li> element within a sequence/alt
    class function ExtractFirstRDFLi(const AXML, AContainerTag: string): string; static;
  public
    // Load from /Info dict (may be nil)
    procedure LoadFromInfoDict(ADict: TPDFDictionary);
    // Load from /Metadata XObject stream (may be nil)
    procedure LoadFromMetadataStream(AStream: TPDFStream);

    property Info:    TPDFInfoRecord read FInfo;
    property XMP:     TPDFXMPData   read FXMP;
    property HasInfo: Boolean        read FHasInfo;
    property HasXMP:  Boolean        read FHasXMP;

    // Convenience: best available value (XMP preferred if present)
    function BestTitle:    string;
    function BestAuthor:   string;
    function BestSubject:  string;
    function BestKeywords: string;
    function BestCreator:  string;
    function BestProducer: string;
  end;

  // -------------------------------------------------------------------------
  // Factory: load both Info (from trailer) and XMP (from catalog)
  // -------------------------------------------------------------------------
  TPDFMetadataLoader = class
  public
    // Load Info dict from ATrailer (/Info key) + XMP stream from ACatalog (/Metadata).
    // Caller must free the returned object.
    class function Load(ATrailer, ACatalog: TPDFDictionary;
                        AResolver: IObjectResolver): TPDFMetadata; static;
  end;

// Standalone convenience (same as TPDFMetadataLoader.Load but fills an
// already-created instance).
procedure LoadPDFMetadata(ATrailer, ACatalog: TPDFDictionary;
                          AResolver: IObjectResolver;
                          AMeta: TPDFMetadata);

implementation

uses
  System.StrUtils;

// =========================================================================
// TPDFInfoRecord
// =========================================================================

class function TPDFInfoRecord.ParseDate(const AStr: string;
  out ADate: TDateTime): Boolean;
var
  S:     string;
  Y, Mo, D, H, Mi, Sec: Integer;
  TZSign: Integer;
  TZH, TZM: Integer;
  BaseUTC: TDateTime;
begin
  Result := False;
  ADate  := 0;
  S := Trim(AStr);

  // Strip D: prefix
  if S.StartsWith('D:') then
    S := Copy(S, 3, MaxInt);

  // Need at least 4 chars for year
  if Length(S) < 4 then Exit;

  // Pad with defaults
  while Length(S) < 14 do
    if Length(S) < 6 then S := S + '01'
    else if Length(S) < 8 then S := S + '01'
    else S := S + '00';

  try
    Y   := StrToInt(Copy(S, 1, 4));
    Mo  := StrToInt(Copy(S, 5, 2));
    D   := StrToInt(Copy(S, 7, 2));
    H   := StrToInt(Copy(S, 9, 2));
    Mi  := StrToInt(Copy(S, 11, 2));
    Sec := StrToInt(Copy(S, 13, 2));
  except
    Exit;
  end;

  if not TryEncodeDateTime(Y, Mo, D, H, Mi, Sec, 0, BaseUTC) then Exit;

  // Optional timezone: (+|-|Z)HH'mm'
  TZSign := 0;
  TZH    := 0;
  TZM    := 0;
  if Length(S) >= 15 then
  begin
    case S[15] of
      '+': TZSign := -1;  // subtract offset to get UTC
      '-': TZSign := +1;
      'Z': TZSign :=  0;
    end;
    if (TZSign <> 0) and (Length(S) >= 17) then
    begin
      try TZH := StrToInt(Copy(S, 16, 2)); except TZH := 0; end;
      if Length(S) >= 20 then
        try TZM := StrToInt(Copy(S, 19, 2)); except TZM := 0; end;
    end;
  end;

  ADate  := BaseUTC + TZSign * (TZH / 24.0 + TZM / 1440.0);
  Result := True;
end;

// =========================================================================
// TPDFMetadata — XMP helpers
// =========================================================================

class function TPDFMetadata.ExtractXMLTag(const AXML, ATag: string): string;
var
  OpenTag, CloseTag: string;
  P1, P2: Integer;
begin
  Result   := '';
  OpenTag  := '<' + ATag + '>';
  CloseTag := '</' + ATag + '>';
  P1 := Pos(OpenTag, AXML);
  if P1 = 0 then Exit;
  Inc(P1, Length(OpenTag));
  P2 := PosEx(CloseTag, AXML, P1);
  if P2 = 0 then Exit;
  Result := Trim(Copy(AXML, P1, P2 - P1));
end;

class function TPDFMetadata.ExtractFirstRDFLi(const AXML,
  AContainerTag: string): string;
var
  Block: string;
begin
  Result := '';
  Block  := ExtractXMLTag(AXML, AContainerTag);
  if Block = '' then Exit;
  Result := ExtractXMLTag(Block, 'rdf:li');
  if Result = '' then
    Result := Trim(Block);  // plain text fallback
end;

class procedure TPDFMetadata.ParseXMP(const AXML: string;
  out AData: TPDFXMPData);
begin
  AData.RawXML        := AXML;
  // Dublin Core
  AData.DCTitle       := ExtractFirstRDFLi(AXML, 'dc:title');
  if AData.DCTitle = '' then
    AData.DCTitle     := ExtractXMLTag(AXML, 'dc:title');
  AData.DCCreator     := ExtractFirstRDFLi(AXML, 'dc:creator');
  AData.DCDescription := ExtractFirstRDFLi(AXML, 'dc:description');
  AData.DCSubject     := ExtractFirstRDFLi(AXML, 'dc:subject');
  // PDF schema
  AData.PDFProducer   := ExtractXMLTag(AXML, 'pdf:Producer');
  AData.PDFKeywords   := ExtractXMLTag(AXML, 'pdf:Keywords');
  // XMP basic
  AData.XMPCreator    := ExtractXMLTag(AXML, 'xmp:CreatorTool');
  AData.XMPCreateDate := ExtractXMLTag(AXML, 'xmp:CreateDate');
  AData.XMPModifyDate := ExtractXMLTag(AXML, 'xmp:ModifyDate');
end;

// =========================================================================
// TPDFMetadata — load
// =========================================================================

procedure TPDFMetadata.LoadFromInfoDict(ADict: TPDFDictionary);
begin
  if ADict = nil then Exit;
  FHasInfo              := True;
  FInfo.Title           := ADict.GetAsUnicodeString('Title');
  FInfo.Author          := ADict.GetAsUnicodeString('Author');
  FInfo.Subject         := ADict.GetAsUnicodeString('Subject');
  FInfo.Keywords        := ADict.GetAsUnicodeString('Keywords');
  FInfo.Creator         := ADict.GetAsUnicodeString('Creator');
  FInfo.Producer        := ADict.GetAsUnicodeString('Producer');
  FInfo.Trapped         := ADict.GetAsName('Trapped');
  FInfo.HasCreationDate := TPDFInfoRecord.ParseDate(
    ADict.GetAsUnicodeString('CreationDate'), FInfo.CreationDate);
  FInfo.HasModDate      := TPDFInfoRecord.ParseDate(
    ADict.GetAsUnicodeString('ModDate'), FInfo.ModDate);
end;

procedure TPDFMetadata.LoadFromMetadataStream(AStream: TPDFStream);
var
  Bytes: TBytes;
  XML:   string;
begin
  if AStream = nil then Exit;
  Bytes := AStream.DecodedBytes;
  if Length(Bytes) = 0 then Exit;
  // XMP is always UTF-8
  XML := TEncoding.UTF8.GetString(Bytes);
  FHasXMP := True;
  ParseXMP(XML, FXMP);
end;

// =========================================================================
// TPDFMetadata — convenience
// =========================================================================

function TPDFMetadata.BestTitle: string;
begin
  if FHasXMP and (FXMP.DCTitle <> '') then Result := FXMP.DCTitle
  else Result := FInfo.Title;
end;

function TPDFMetadata.BestAuthor: string;
begin
  if FHasXMP and (FXMP.DCCreator <> '') then Result := FXMP.DCCreator
  else Result := FInfo.Author;
end;

function TPDFMetadata.BestSubject: string;
begin
  if FHasXMP and (FXMP.DCDescription <> '') then Result := FXMP.DCDescription
  else Result := FInfo.Subject;
end;

function TPDFMetadata.BestKeywords: string;
begin
  if FHasXMP and (FXMP.PDFKeywords <> '') then Result := FXMP.PDFKeywords
  else Result := FInfo.Keywords;
end;

function TPDFMetadata.BestCreator: string;
begin
  if FHasXMP and (FXMP.XMPCreator <> '') then Result := FXMP.XMPCreator
  else Result := FInfo.Creator;
end;

function TPDFMetadata.BestProducer: string;
begin
  if FHasXMP and (FXMP.PDFProducer <> '') then Result := FXMP.PDFProducer
  else Result := FInfo.Producer;
end;

// =========================================================================
// TPDFMetadataLoader
// =========================================================================

class function TPDFMetadataLoader.Load(ATrailer, ACatalog: TPDFDictionary;
  AResolver: IObjectResolver): TPDFMetadata;
begin
  Result := TPDFMetadata.Create;
  LoadPDFMetadata(ATrailer, ACatalog, AResolver, Result);
end;

// =========================================================================
// LoadPDFMetadata — fills an existing TPDFMetadata instance
// =========================================================================

procedure LoadPDFMetadata(ATrailer, ACatalog: TPDFDictionary;
                          AResolver: IObjectResolver;
                          AMeta: TPDFMetadata);
var
  Obj: TPDFObject;
begin
  // /Info dict from trailer
  if ATrailer <> nil then
  begin
    Obj := ATrailer.Get('Info');
    if Obj <> nil then
    begin
      Obj := Obj.Dereference;
      if Obj.IsDictionary then
        AMeta.LoadFromInfoDict(TPDFDictionary(Obj));
    end;
  end;

  // /Metadata XMP stream from catalog
  if ACatalog <> nil then
  begin
    Obj := ACatalog.Get('Metadata');
    if Obj <> nil then
    begin
      Obj := Obj.Dereference;
      if Obj.IsStream then
        AMeta.LoadFromMetadataStream(TPDFStream(Obj));
    end;
  end;
end;

end.
