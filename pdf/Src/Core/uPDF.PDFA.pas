unit uPDF.PDFA;

{$SCOPEDENUMS ON}

// ============================================================================
// uPDF.PDFA — conversion to PDF/A-2b and PDF/A-3b (ISO 19005-2, -3)
//
// Three entry points, all in memory:
//   FromPdf    an existing PDF. Not rasterised: what can be fixed is fixed
//              (XMP metadata, sRGB OutputIntent, trailer /ID, JavaScript and
//              other forbidden actions, LZW streams, annotation flags, image
//              interpolation, XFA); what cannot (fonts that are not embedded,
//              encryption, CMYK images, attachments in 2b, annotations
//              without appearance...) is returned in Problems and Ok=False.
//              A file that already declares PDF/A is returned as it is.
//   FromImages JPEG, PNG and TIFF (every page; Group 4 and JPEG strips go as
//              they are, see uPDF.TIFF), one page per image, at its own
//              resolution.
//   FromText   plain text paginated on A4 with an embedded TrueType subset;
//              with Attach, PDF/A-3b with the original as an associated file
//              (e-mail: the .eml with AFRelationship /Source).
//
// Every output is a full rewrite (header with binary comment, classic xref),
// with an XMP packet consistent with the Info dictionary and an sRGB ICC
// profile generated in code (no third-party profile file). Validate with
// veraPDF. No dependencies beyond this library and the RTL.
// ============================================================================

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  TPDFAPart = (pdfa2b, pdfa3b);

  TPDFAOptions = record
    Part: TPDFAPart;
    Title, Author, Subject, Producer: string;
    /// TrueType font for new text (FromText); e.g. DejaVuSans.ttf
    FontFile: string;
    /// where the substitutes for standard fonts without their program are
    /// (Liberation Sans, Serif and Mono, metric-compatible with Arial, Times and
    /// Courier); empty = no substitution
    SubstituteFontDir: string;
    class function Defaults: TPDFAOptions; static;
  end;

  TPDFAResult = record
    Ok: Boolean;
    Pdf: TBytes;
    /// why it could not be converted (Ok = False)
    Problems: TArray<string>;
    /// the source already declared PDF/A: Pdf is the source, untouched
    AlreadyPdfA: Boolean;
  end;

  TPDFAConverter = class
  public
    class function FromPdf(const Src: TBytes; const Opt: TPDFAOptions): TPDFAResult; static;
    class function FromImages(const Images: TArray<TBytes>;
      const Opt: TPDFAOptions): TPDFAResult; static;
    class function FromText(const Text: string; const Attach: TBytes;
      const AttachName, AttachMime: string; const Opt: TPDFAOptions): TPDFAResult; static;
  end;

/// an sRGB IEC 61966-2.1 ICC v2 display profile, built in code
function PDFASRGBProfile: TBytes;

implementation

uses
  System.Math, System.DateUtils, System.ZLib, System.Hash, System.IOUtils,
  uPDF.Types, uPDF.Objects, uPDF.Parser, uPDF.XRef, uPDF.Writer,
  uPDF.TTFParser, uPDF.TTFSubset, uPDF.EmbeddedFont, uPDF.TIFF;

{ ---- small helpers ---- }

class function TPDFAOptions.Defaults: TPDFAOptions;
begin
  Result := Default(TPDFAOptions);
  Result.Part := TPDFAPart.pdfa2b;
  Result.Producer := 'delphi-libraries PDF/A';
  {$IFDEF LINUX}
  Result.SubstituteFontDir := '/usr/share/fonts/truetype/liberation';
  {$ENDIF}
end;

function Raw(const B: TBytes): RawByteString;
begin
  SetLength(Result, Length(B));
  if Length(B) > 0 then
    Move(B[0], Result[1], Length(B));
end;

function FromRaw(const S: RawByteString): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

// UTF-16BE with BOM (ISO 32000 §7.9.2.2): any language, as PDF/A expects
function TextString(const S: string): TPDFString;
var
  B: RawByteString;
  I: Integer;
begin
  SetLength(B, 2 + Length(S) * 2);
  B[1] := #$FE;
  B[2] := #$FF;
  for I := 1 to Length(S) do
  begin
    B[1 + I * 2] := AnsiChar(Ord(S[I]) shr 8);
    B[2 + I * 2] := AnsiChar(Ord(S[I]) and $FF);
  end;
  Result := TPDFString.Create(B, True);
end;

function XmlEscape(const S: string): string;
begin
  Result := S.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    .Replace('"', '&quot;');
  // control characters are not allowed in XML 1.0
  for var I := 1 to Length(Result) do
    if (Ord(Result[I]) < 32) and not CharInSet(Result[I], [#9, #10, #13]) then
      Result[I] := ' ';
end;

procedure AddProblem(var R: TPDFAResult; const S: string);
begin
  for var P in R.Problems do
    if P = S then
      Exit;
  R.Problems := R.Problems + [S];
end;

{ ---- dates: Info (D:YYYYMMDDHHmmSSOHH'mm') and XMP (ISO 8601), the same instant ---- }

type
  TPdfaDate = record
    Info, Xmp: string;
  end;

function NowDate: TPdfaDate;
var
  U: TDateTime;
begin
  U := TTimeZone.Local.ToUniversalTime(Now);
  Result.Info := 'D:' + FormatDateTime('yyyymmddhhnnss', U) + 'Z';
  Result.Xmp := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss', U) + 'Z';
end;

// a PDF date as written by the producer; False if it is not one
function ParsePdfDate(const S: string; out D: TPdfaDate): Boolean;
var
  T: string;
  Y, Mo, Dd, H, Mi, Se: Integer;
  Tz: string;
  function Part(From, Len, Def: Integer): Integer;
  begin
    if Length(T) >= From + Len - 1 then
      Result := StrToIntDef(Copy(T, From, Len), -1)
    else
      Result := Def;
  end;
begin
  Result := False;
  T := S.Trim;
  if T.StartsWith('D:') then
    Delete(T, 1, 2);
  if (Length(T) < 4) or not CharInSet(T[1], ['0'..'9']) then
    Exit;
  Y := Part(1, 4, -1);
  Mo := Part(5, 2, 1);
  Dd := Part(7, 2, 1);
  H := Part(9, 2, 0);
  Mi := Part(11, 2, 0);
  Se := Part(13, 2, 0);
  if (Y < 1000) or (Mo < 1) or (Mo > 12) or (Dd < 1) or (Dd > 31) or (H < 0) or (H > 23) or
     (Mi < 0) or (Mi > 59) or (Se < 0) or (Se > 59) then
    Exit;
  Tz := '';
  if Length(T) > 14 then
  begin
    Tz := Copy(T, 15, MaxInt);
    if Tz[1] = 'Z' then
      Tz := 'Z'
    else if CharInSet(Tz[1], ['+', '-']) and (Length(Tz) >= 3) then
    begin
      // +HH'mm' -> +HH:mm
      var Hh := Copy(Tz, 2, 2);
      var Mm := '00';
      var Rest := Copy(Tz, 4, MaxInt).Replace('''', '');
      if Length(Rest) >= 2 then
        Mm := Copy(Rest, 1, 2);
      if (StrToIntDef(Hh, -1) < 0) or (StrToIntDef(Mm, -1) < 0) then
        Tz := ''
      else
        Tz := Tz[1] + Hh + ':' + Mm;
    end
    else
      Tz := '';
  end;
  D.Info := Format('D:%.4d%.2d%.2d%.2d%.2d%.2d', [Y, Mo, Dd, H, Mi, Se]);
  D.Xmp := Format('%.4d-%.2d-%.2dT%.2d:%.2d:%.2d', [Y, Mo, Dd, H, Mi, Se]);
  if Tz = 'Z' then
  begin
    D.Info := D.Info + 'Z';
    D.Xmp := D.Xmp + 'Z';
  end
  else if Tz <> '' then
  begin
    D.Info := D.Info + Tz[1] + Copy(Tz, 2, 2) + '''' + Copy(Tz, 5, 2) + '''';
    D.Xmp := D.Xmp + Tz;
  end;
  Result := True;
end;

{ ---- sRGB ICC profile (v2.1, matrix/TRC; D50-adapted primaries) ---- }

procedure PutU32(var B: TBytes; Ofs: Integer; V: Cardinal);
begin
  B[Ofs] := (V shr 24) and $FF;
  B[Ofs + 1] := (V shr 16) and $FF;
  B[Ofs + 2] := (V shr 8) and $FF;
  B[Ofs + 3] := V and $FF;
end;

procedure PutTag(var B: TBytes; Ofs: Integer; const Tag: AnsiString);
begin
  for var I := 1 to 4 do
    B[Ofs + I - 1] := Ord(Tag[I]);
end;

function S15(V: Double): Cardinal;
begin
  Result := Cardinal(Round(V * 65536));
end;

function PDFASRGBProfile: TBytes;
type
  TTag = record
    Sig: AnsiString;
    Data: TBytes;
  end;
var
  Tags: TArray<TTag>;

  function XYZ(X, Y, Z: Double): TBytes;
  begin
    SetLength(Result, 20);
    FillChar(Result[0], 20, 0);
    PutTag(Result, 0, 'XYZ ');
    PutU32(Result, 8, S15(X));
    PutU32(Result, 12, S15(Y));
    PutU32(Result, 16, S15(Z));
  end;

  function Curve: TBytes;
  const
    N = 256;
  begin
    // the sRGB transfer function, sampled (it is not a pure gamma)
    SetLength(Result, 12 + N * 2);
    FillChar(Result[0], Length(Result), 0);
    PutTag(Result, 0, 'curv');
    PutU32(Result, 8, N);
    for var I := 0 to N - 1 do
    begin
      var C := I / (N - 1);
      var L: Double;
      if C <= 0.04045 then
        L := C / 12.92
      else
        L := Power((C + 0.055) / 1.055, 2.4);
      var V := Round(L * 65535);
      Result[12 + I * 2] := (V shr 8) and $FF;
      Result[13 + I * 2] := V and $FF;
    end;
  end;

  function Desc(const S: AnsiString): TBytes;
  begin
    // textDescriptionType: ASCII + empty Unicode and ScriptCode parts
    SetLength(Result, 12 + Length(S) + 1 + 4 + 4 + 2 + 1 + 67);
    FillChar(Result[0], Length(Result), 0);
    PutTag(Result, 0, 'desc');
    PutU32(Result, 8, Length(S) + 1);
    Move(S[1], Result[12], Length(S));
  end;

  function Text(const S: AnsiString): TBytes;
  begin
    SetLength(Result, 8 + Length(S) + 1);
    FillChar(Result[0], Length(Result), 0);
    PutTag(Result, 0, 'text');
    Move(S[1], Result[8], Length(S));
  end;

  procedure Add(const Sig: AnsiString; const Data: TBytes);
  var
    T: TTag;
  begin
    T.Sig := Sig;
    T.Data := Data;
    Tags := Tags + [T];
  end;

var
  Size, Ofs, I, Count: Integer;
  Offsets: TArray<Integer>;
  Trc: TBytes;
begin
  Add('desc', Desc('sRGB IEC61966-2.1'));
  Add('cprt', Text('No copyright, use freely'));
  Add('wtpt', XYZ(0.9642, 1.0, 0.8249));
  Add('rXYZ', XYZ(0.4360747, 0.2225045, 0.0139322));
  Add('gXYZ', XYZ(0.3850649, 0.7168786, 0.0971045));
  Add('bXYZ', XYZ(0.1430804, 0.0606169, 0.7141733));
  Trc := Curve;
  Add('rTRC', Trc);
  Count := Length(Tags);
  // the three TRC tags share the same data
  Size := 128 + 4 + (Count + 2) * 12;
  SetLength(Offsets, Count);
  for I := 0 to Count - 1 do
  begin
    Size := (Size + 3) and not 3;
    Offsets[I] := Size;
    Inc(Size, Length(Tags[I].Data));
  end;
  Size := (Size + 3) and not 3;
  SetLength(Result, Size);
  FillChar(Result[0], Size, 0);
  // header
  PutU32(Result, 0, Size);
  PutU32(Result, 8, $02100000);       // version 2.1
  PutTag(Result, 12, 'mntr');
  PutTag(Result, 16, 'RGB ');
  PutTag(Result, 20, 'XYZ ');
  // date: 2026-01-01
  Result[24] := $07; Result[25] := $EA; Result[27] := 1; Result[29] := 1;
  PutTag(Result, 36, 'acsp');
  PutU32(Result, 64, 0);              // perceptual
  PutU32(Result, 68, S15(0.9642));    // PCS illuminant D50
  PutU32(Result, 72, S15(1.0));
  PutU32(Result, 76, S15(0.8249));
  // tag table
  PutU32(Result, 128, Count + 2);
  Ofs := 132;
  for I := 0 to Count - 1 do
  begin
    PutTag(Result, Ofs, Tags[I].Sig);
    PutU32(Result, Ofs + 4, Offsets[I]);
    PutU32(Result, Ofs + 8, Length(Tags[I].Data));
    Inc(Ofs, 12);
    Move(Tags[I].Data[0], Result[Offsets[I]], Length(Tags[I].Data));
  end;
  for var Sig in ['gTRC', 'bTRC'] do
  begin
    PutTag(Result, Ofs, AnsiString(Sig));
    PutU32(Result, Ofs + 4, Offsets[Count - 1]);
    PutU32(Result, Ofs + 8, Length(Trc));
    Inc(Ofs, 12);
  end;
end;

{ ---- the conversion of a parsed PDF ---- }

type
  TPdfaJob = class
  private
    FObjects: TObjectDictionary<Integer, TPDFObject>;
    // the parser stays alive while the clones exist: they resolve through it
    FStm: TBytesStream;
    FParser: TPDFParser;
    FNext: Integer;
    FCatalog, FInfo: TPDFDictionary;
    FCatNum, FInfoNum: Integer;
    FResult: TPDFAResult;
    FOpt: TPDFAOptions;
    function Res(O: TPDFObject): TPDFObject;
    function ResDict(O: TPDFObject): TPDFDictionary;
    function Add(O: TPDFObject): Integer;
    procedure Load(const Src: TBytes);
    function AlreadyPdfA: Boolean;
    procedure FixObject(Num: Integer; O: TPDFObject);
    procedure FixDict(D: TPDFDictionary; IsStream: Boolean);
    /// embeds a metric-compatible substitute (Liberation) for a standard font
    // that came without its program; False if there is none
    function Substitute(D, Fd: TPDFDictionary): Boolean;
    procedure FixCatalog;
    procedure Metadata;
    procedure Attach(const Data: TBytes; const Name, Mime: string);
    /// equal objects written once (the per-page copies of a font, for example)
    procedure Dedupe;
    function Save: TBytes;
  public
    constructor Create(const Opt: TPDFAOptions);
    destructor Destroy; override;
  end;

const
  FORBIDDEN_ACTIONS: array[0..10] of string = ('Launch', 'Sound', 'Movie', 'ResetForm',
    'ImportData', 'JavaScript', 'Hide', 'SetOCGState', 'Rendition', 'Trans', 'GoTo3DView');
  FORBIDDEN_ANNOTS: array[0..5] of string = ('Sound', 'Movie', 'Screen', '3D', 'RichMedia',
    'TrapNet');

constructor TPdfaJob.Create(const Opt: TPDFAOptions);
begin
  inherited Create;
  FOpt := Opt;
  FObjects := TObjectDictionary<Integer, TPDFObject>.Create([doOwnsValues]);
end;

destructor TPdfaJob.Destroy;
begin
  FObjects.Free;
  FParser.Free;
  FStm.Free;
  inherited;
end;

function TPdfaJob.Res(O: TPDFObject): TPDFObject;
var
  T: TPDFObject;
begin
  Result := O;
  if (O <> nil) and O.IsReference then
    if FObjects.TryGetValue(TPDFReference(O).RefID.Number, T) then
      Result := T
    else
      Result := nil;
end;

function TPdfaJob.ResDict(O: TPDFObject): TPDFDictionary;
begin
  O := Res(O);
  if O = nil then
    Exit(nil);
  if O.IsStream then
    Exit(TPDFStream(O).Dict);
  if O.IsDictionary then
    Exit(TPDFDictionary(O));
  Result := nil;
end;

function TPdfaJob.Add(O: TPDFObject): Integer;
begin
  Result := FNext;
  Inc(FNext);
  FObjects.Add(Result, O);
end;

procedure TPdfaJob.Load(const Src: TBytes);
var
  Parser: TPDFParser;
  O: TPDFObject;
begin
  FStm := TBytesStream.Create(Src);
  FParser := TPDFParser.Create(FStm, False);
  Parser := FParser;
  begin
    Parser.Open;
    if Parser.IsEncrypted then
    begin
      AddProblem(FResult, 'el PDF está cifrado');
      Exit;
    end;
    FNext := Parser.XRef.HighestObjectNumber + 1;
    Parser.XRef.ForEach(
      procedure(ObjNum: Integer; Entry: TPDFXRefEntry)
      var
        Obj: TPDFObject;
        T: string;
      begin
        if Entry.EntryType = TPDFXRefEntryType.Free then
          Exit;
        Obj := Parser.LoadObject(ObjNum, Entry.Generation);
        if (Obj = nil) or Obj.IsNull then
          Exit;
        if Obj.IsStream then
        begin
          T := TPDFStream(Obj).Dict.GetAsName('Type');
          if (T = 'ObjStm') or (T = 'XRef') then
            Exit;
          TPDFStream(Obj).RawBytes; // load before cloning
        end
        else if Obj.IsDictionary and (TPDFDictionary(Obj).GetAsName('Type') = 'XRef') then
          Exit;
        FObjects.AddOrSetValue(ObjNum, Obj.Clone);
      end);
    O := Parser.Trailer.RawGet('Root');
    if (O <> nil) and O.IsReference then
      FCatNum := TPDFReference(O).RefID.Number;
    O := Parser.Trailer.RawGet('Info');
    if (O <> nil) and O.IsReference then
      FInfoNum := TPDFReference(O).RefID.Number;
  end;
  FCatalog := nil;
  if (FCatNum > 0) and FObjects.TryGetValue(FCatNum, O) and O.IsDictionary then
    FCatalog := TPDFDictionary(O);
  if FCatalog = nil then
    AddProblem(FResult, 'el PDF no tiene catálogo');
  FInfo := nil;
  if (FInfoNum > 0) and FObjects.TryGetValue(FInfoNum, O) and O.IsDictionary then
    FInfo := TPDFDictionary(O);
end;

function TPdfaJob.AlreadyPdfA: Boolean;
var
  M: TPDFObject;
begin
  Result := False;
  M := Res(FCatalog.RawGet('Metadata'));
  if (M <> nil) and M.IsStream then
    Result := Pos('pdfaid:part', string(TEncoding.UTF8.GetString(TPDFStream(M).DecodedBytes))) > 0;
end;

function InList(const S: string; const L: array of string): Boolean;
begin
  for var X in L do
    if X = S then
      Exit(True);
  Result := False;
end;

// WinAnsiEncoding (cp1252) to Unicode; the rest of 32..255 is Latin-1
function WinAnsiToUnicode(Code: Integer): Cardinal;
const
  HI: array[$80..$9F] of Word = ($20AC, 0, $201A, $0192, $201E, $2026, $2020, $2021, $02C6,
    $2030, $0160, $2039, $0152, 0, $017D, 0, 0, $2018, $2019, $201C, $201D, $2022, $2013,
    $2014, $02DC, $2122, $0161, $203A, $0153, 0, $017E, $0178);
begin
  if (Code >= $80) and (Code <= $9F) then
    Result := HI[Code]
  else
    Result := Code;
end;

// the metric-compatible free substitute of a standard font that came without
// its program: Arial/Helvetica, Times and Courier -> Liberation ('' if none)
function SubstituteFile(const Dir, BaseFont: string; Bold, Italic: Boolean): string;
var
  N, Family, Style: string;
begin
  Result := '';
  if Dir = '' then
    Exit;
  N := BaseFont;
  if (Length(N) > 7) and (N[7] = '+') then
    Delete(N, 1, 7); // subset tag
  N := N.ToLower.Replace(' ', '').Replace('-', '').Replace(',', '');
  if N.Contains('bold') then Bold := True;
  if N.Contains('italic') or N.Contains('oblique') then Italic := True;
  if N.StartsWith('arialnarrow') then
    Family := 'LiberationSansNarrow'
  else if N.StartsWith('arial') or N.StartsWith('helvetica') then
    Family := 'LiberationSans'
  else if N.StartsWith('timesnewroman') or N.StartsWith('times') then
    Family := 'LiberationSerif'
  else if N.StartsWith('couriernew') or N.StartsWith('courier') then
    Family := 'LiberationMono'
  else
    Exit;
  if Bold and Italic then Style := 'BoldItalic'
  else if Bold then Style := 'Bold'
  else if Italic then Style := 'Italic'
  else Style := 'Regular';
  Result := IncludeTrailingPathDelimiter(Dir) + Family + '-' + Style + '.ttf';
  if not FileExists(Result) then
    Result := '';
end;

function TPdfaJob.Substitute(D, Fd: TPDFDictionary): Boolean;
var
  St, Base, Path: string;
  Enc: TPDFObject;
  Bold, Italic: Boolean;
  Fc, Lc, C: Integer;
  P: TTTFParser;
  Sub: TTTFSubsetter;
  Gids: TList<Word>;
  Prog: TBytes;
  W: TPDFArray;
  Ff: TPDFStream;
  Upm: Double;
  M: TTTFMetrics;
begin
  Result := False;
  St := D.GetAsName('Subtype');
  if not InList(St, ['TrueType', 'Type1']) then
    Exit;
  // only simple Latin text: WinAnsi or no encoding (no Differences, no symbols)
  Enc := Res(D.RawGet('Encoding'));
  if (Enc <> nil) and not (Enc.IsName and InList(Enc.AsName, ['WinAnsiEncoding',
     'StandardEncoding'])) then
    Exit;
  Base := D.GetAsName('BaseFont');
  Bold := False;
  Italic := False;
  if Fd <> nil then
  begin
    if Fd.GetAsInteger('Flags', 0) and 4 <> 0 then
      Exit; // symbolic
    Bold := (Fd.GetAsInteger('FontWeight', 400) >= 600) or
      (Fd.GetAsInteger('Flags', 0) and $40000 <> 0);
    Italic := Fd.GetAsNumber('ItalicAngle', 0) <> 0;
  end;
  Path := SubstituteFile(FOpt.SubstituteFontDir, Base, Bold, Italic);
  if Path = '' then
    Exit;
  Fc := D.GetAsInteger('FirstChar', 32);
  Lc := D.GetAsInteger('LastChar', 255);
  if (Fc < 0) or (Lc > 255) or (Lc < Fc) then
  begin
    Fc := 32;
    Lc := 255;
  end;
  P := TTTFParser.Create(TFile.ReadAllBytes(Path));
  Gids := TList<Word>.Create;
  try
    if not P.Parse or not P.EmbeddingPermitted then
      Exit;
    Gids.Add(0);
    for C := Fc to Lc do
    begin
      var G := P.CharToGlyph(WinAnsiToUnicode(C));
      if (G > 0) and not Gids.Contains(G) then
        Gids.Add(G);
    end;
    Sub := TTTFSubsetter.Create(P, Gids.ToArray);
    try
      Prog := Sub.Build;
    finally
      Sub.Free;
    end;
    M := P.Metrics;
    Upm := Max(1, M.UnitsPerEm);
    // the widths of the embedded program (6.2.11.5)
    W := TPDFArray.Create;
    for C := Fc to Lc do
    begin
      var G := P.CharToGlyph(WinAnsiToUnicode(C));
      if G > 0 then
        W.Add(TPDFInteger.Create(Round(P.GlyphAdvanceWidth(G) * 1000 / Upm)))
      else
        W.Add(TPDFInteger.Create(0));
    end;
    Ff := TPDFStream.Create;
    Ff.SetRawData(Prog);
    Ff.Dict.SetValue('Length1', TPDFInteger.Create(Length(Prog)));
    if Fd = nil then
    begin
      Fd := TPDFDictionary.Create;
      D.SetValue('FontDescriptor', TPDFReference.CreateNum(Add(Fd), 0));
    end;
    Fd.SetValue('Type', TPDFName.Create('FontDescriptor'));
    Fd.SetValue('FontName', TPDFName.Create(Base));
    var Flags := 32;
    if M.IsFixedPitch then Flags := Flags or 1;
    if Path.Contains('Serif') then Flags := Flags or 2;
    if Italic or M.IsItalic then Flags := Flags or 64;
    Fd.SetValue('Flags', TPDFInteger.Create(Flags));
    var Bb := TPDFArray.Create;
    Bb.Add(TPDFInteger.Create(Round(M.XMin * 1000 / Upm)));
    Bb.Add(TPDFInteger.Create(Round(M.YMin * 1000 / Upm)));
    Bb.Add(TPDFInteger.Create(Round(M.XMax * 1000 / Upm)));
    Bb.Add(TPDFInteger.Create(Round(M.YMax * 1000 / Upm)));
    Fd.SetValue('FontBBox', Bb);
    Fd.SetValue('ItalicAngle', TPDFReal.Create(M.ItalicAngle));
    Fd.SetValue('Ascent', TPDFInteger.Create(Round(M.Ascender * 1000 / Upm)));
    Fd.SetValue('Descent', TPDFInteger.Create(Round(M.Descender * 1000 / Upm)));
    Fd.SetValue('CapHeight', TPDFInteger.Create(Round(M.CapHeight * 1000 / Upm)));
    if not Fd.Contains('StemV') then
      Fd.SetValue('StemV', TPDFInteger.Create(IfThen(Bold, 150, 80)));
    Fd.Remove('FontFile');
    Fd.Remove('FontFile3');
    Fd.Remove('CharSet');
    Fd.Remove('CIDSet');
    Fd.SetValue('FontFile2', TPDFReference.CreateNum(Add(Ff), 0));
    D.SetValue('Subtype', TPDFName.Create('TrueType'));
    D.SetValue('FirstChar', TPDFInteger.Create(Fc));
    D.SetValue('LastChar', TPDFInteger.Create(Lc));
    D.SetValue('Widths', W);
    D.SetValue('Encoding', TPDFName.Create('WinAnsiEncoding'));
    Result := True;
  finally
    Gids.Free;
    P.Free;
  end;
end;

procedure TPdfaJob.FixDict(D: TPDFDictionary; IsStream: Boolean);
var
  A: TPDFDictionary;
  T, St: string;
  F: Int64;
begin
  // no additional actions anywhere (6.5.2)
  D.Remove('AA');
  // an action that PDF/A forbids goes away (6.5.1)
  A := ResDict(D.RawGet('A'));
  if (A <> nil) and InList(A.GetAsName('S'), FORBIDDEN_ACTIONS) then
    D.Remove('A');
  T := D.GetAsName('Type');
  St := D.GetAsName('Subtype');
  if (T = 'Annot') or (D.Contains('Rect') and (St <> '') and not IsStream and
     (D.Contains('P') or D.Contains('AP'))) then
  begin
    if InList(St, FORBIDDEN_ANNOTS) then
      AddProblem(FResult, 'tiene una anotación de tipo ' + St + ' (no se permite en PDF/A)');
    if (St = 'FileAttachment') and (FOpt.Part = TPDFAPart.pdfa2b) then
      AddProblem(FResult, 'tiene archivos adjuntos en una anotación');
    // printable, not hidden (6.3.2)
    if St <> 'Popup' then
    begin
      F := D.GetAsInteger('F', 0);
      F := (F or 4) and not (1 or 2 or 32);
      D.SetValue('F', TPDFInteger.Create(F));
    end;
    // with an appearance (6.3.3), except links and popups
    if not InList(St, ['Popup', 'Link']) and not D.Contains('AP') then
    begin
      var Ro := Res(D.RawGet('Rect'));
      var Empty := True;
      if (Ro <> nil) and Ro.IsArray and (Ro.AsArray.Count >= 4) then
      begin
        var R := Ro.AsArray;
        var Nums: array[0..3] of Double;
        for var K := 0 to 3 do
        begin
          var V := Res(R.Items(K));
          if (V <> nil) and V.IsNumber then Nums[K] := V.AsNumber else Nums[K] := 0;
        end;
        Empty := (Nums[2] - Nums[0] = 0) and (Nums[3] - Nums[1] = 0);
      end;
      if not Empty then
        AddProblem(FResult, 'tiene una anotación ' + St + ' sin apariencia');
    end;
  end;
  if IsStream and (St = 'Image') then
  begin
    if D.GetAsBoolean('Interpolate', False) then
      D.SetValue('Interpolate', TPDFBoolean.Create(False));
    D.Remove('Alternates');
    D.Remove('OPI');
    var Cs := D.RawGet('ColorSpace');
    if (Cs <> nil) and Cs.IsName and (Cs.AsName = 'DeviceCMYK') then
      AddProblem(FResult, 'tiene imágenes en CMYK sin perfil de color');
  end;
  if IsStream and (St = 'Form') then
  begin
    D.Remove('OPI');
    if D.GetAsName('Subtype2') = 'PS' then
      AddProblem(FResult, 'tiene PostScript embebido');
  end;
  if IsStream and (St = 'PS') then
    AddProblem(FResult, 'tiene PostScript embebido');
  // fonts: the program has to be embedded (6.2.11.4)
  if (T = 'Font') and InList(St, ['Type1', 'MMType1', 'TrueType', 'CIDFontType0',
     'CIDFontType2']) then
  begin
    var Fd := ResDict(D.RawGet('FontDescriptor'));
    if ((Fd = nil) or not (Fd.Contains('FontFile') or Fd.Contains('FontFile2') or
       Fd.Contains('FontFile3'))) and not Substitute(D, Fd) then
      AddProblem(FResult, 'la fuente ' + D.GetAsName('BaseFont') + ' no está embebida');
  end;
end;

procedure TPdfaJob.FixObject(Num: Integer; O: TPDFObject);
var
  S: TPDFStream;
  Fl: TPDFObject;
  Lzw: Boolean;
begin
  if O.IsStream then
  begin
    S := TPDFStream(O);
    // LZW is not allowed (6.1.7.2): decode and let the writer use Flate
    Fl := Res(S.Dict.RawGet('Filter'));
    Lzw := False;
    if Fl <> nil then
      if Fl.IsName then
        Lzw := InList(Fl.AsName, ['LZWDecode', 'LZW'])
      else if Fl.IsArray then
        for var I := 0 to Fl.AsArray.Count - 1 do
          if Fl.AsArray.Items(I).IsName and
             InList(Fl.AsArray.Items(I).AsName, ['LZWDecode', 'LZW']) then
            Lzw := True;
    if Lzw then
    begin
      var D := S.DecodedBytes;
      S.Dict.Remove('Filter');
      S.Dict.Remove('DecodeParms');
      S.SetRawData(D);
      S.Dict.SetValue('Length', TPDFInteger.Create(Length(D)));
    end;
    FixDict(S.Dict, True);
  end
  else if O.IsDictionary then
    FixDict(TPDFDictionary(O), False);
end;

procedure TPdfaJob.FixCatalog;
var
  Names, Af: TPDFDictionary;
  O: TPDFObject;
begin
  O := Res(FCatalog.RawGet('OpenAction'));
  if (O <> nil) and O.IsDictionary and
     InList(TPDFDictionary(O).GetAsName('S'), FORBIDDEN_ACTIONS) then
    FCatalog.Remove('OpenAction');
  FCatalog.Remove('AA');
  Names := ResDict(FCatalog.RawGet('Names'));
  if Names <> nil then
  begin
    Names.Remove('JavaScript');
    if Names.Contains('EmbeddedFiles') and (FOpt.Part = TPDFAPart.pdfa2b) then
      AddProblem(FResult, 'tiene archivos adjuntos (PDF/A-2b solo admite adjuntos PDF/A)');
  end;
  Af := ResDict(FCatalog.RawGet('AcroForm'));
  if Af <> nil then
  begin
    Af.Remove('XFA');
    if Af.GetAsBoolean('NeedAppearances', False) then
      Af.Remove('NeedAppearances');
  end;
  // OCProperties: an optional content configuration needs a name (6.9)
  var Oc := ResDict(FCatalog.RawGet('OCProperties'));
  if Oc <> nil then
  begin
    var Dd := ResDict(Oc.RawGet('D'));
    if (Dd <> nil) and not Dd.Contains('Name') then
      Dd.SetValue('Name', TextString('Default'));
    if Dd <> nil then
      Dd.Remove('AS');
  end;
  FCatalog.Remove('Perms');
end;

procedure TPdfaJob.Metadata;
var
  Title, Author, Subject, Keywords, Creator, Producer: string;
  Created, Modified: TPdfaDate;
  Info: TPDFDictionary;
  X: TStringBuilder;
  Xmp: TBytes;
  Meta, Icc: TPDFStream;
  Oi: TPDFDictionary;
  Arr: TPDFArray;
  Part: string;

  function InfoText(const K: string): string;
  begin
    Result := '';
    if FInfo <> nil then
    begin
      var V := Res(FInfo.RawGet(K));
      if (V <> nil) and V.IsString then
        Result := TPDFString(V).ToUnicode.Trim;
    end;
  end;

begin
  Title := InfoText('Title');
  Author := InfoText('Author');
  Subject := InfoText('Subject');
  Keywords := InfoText('Keywords');
  Creator := InfoText('Creator');
  Producer := InfoText('Producer');
  if FOpt.Title <> '' then Title := FOpt.Title;
  if FOpt.Author <> '' then Author := FOpt.Author;
  if FOpt.Subject <> '' then Subject := FOpt.Subject;
  if FOpt.Producer <> '' then Producer := FOpt.Producer;
  Modified := NowDate;
  if not ParsePdfDate(InfoText('CreationDate'), Created) then
    Created := Modified;
  // the Info dictionary, only with what the XMP also says (6.6.2.3)
  Info := TPDFDictionary.Create;
  if Title <> '' then Info.SetValue('Title', TextString(Title));
  if Author <> '' then Info.SetValue('Author', TextString(Author));
  if Subject <> '' then Info.SetValue('Subject', TextString(Subject));
  if Keywords <> '' then Info.SetValue('Keywords', TextString(Keywords));
  if Creator <> '' then Info.SetValue('Creator', TextString(Creator));
  if Producer <> '' then Info.SetValue('Producer', TextString(Producer));
  Info.SetValue('CreationDate', TPDFString.Create(RawByteString(Created.Info)));
  Info.SetValue('ModDate', TPDFString.Create(RawByteString(Modified.Info)));
  if FInfoNum > 0 then
    FObjects.AddOrSetValue(FInfoNum, Info)
  else
    FInfoNum := Add(Info);
  FInfo := Info;
  if FOpt.Part = TPDFAPart.pdfa3b then
    Part := '3'
  else
    Part := '2';
  X := TStringBuilder.Create;
  try
    X.Append('<?xpacket begin="'#$FEFF'" id="W5M0MpCehiHzreSzNTczkc9d"?>'#10);
    X.Append('<x:xmpmeta xmlns:x="adobe:ns:meta/">'#10);
    X.Append('<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'#10);
    X.Append('<rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">'#10);
    X.Append('<pdfaid:part>' + Part + '</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance>'#10);
    X.Append('</rdf:Description>'#10);
    X.Append('<rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">'#10);
    X.Append('<dc:format>application/pdf</dc:format>'#10);
    if Title <> '' then
      X.Append('<dc:title><rdf:Alt><rdf:li xml:lang="x-default">' + XmlEscape(Title) +
        '</rdf:li></rdf:Alt></dc:title>'#10);
    if Author <> '' then
      X.Append('<dc:creator><rdf:Seq><rdf:li>' + XmlEscape(Author) + '</rdf:li></rdf:Seq></dc:creator>'#10);
    if Subject <> '' then
      X.Append('<dc:description><rdf:Alt><rdf:li xml:lang="x-default">' + XmlEscape(Subject) +
        '</rdf:li></rdf:Alt></dc:description>'#10);
    X.Append('</rdf:Description>'#10);
    X.Append('<rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/">'#10);
    X.Append('<xmp:CreateDate>' + Created.Xmp + '</xmp:CreateDate>'#10);
    X.Append('<xmp:ModifyDate>' + Modified.Xmp + '</xmp:ModifyDate>'#10);
    X.Append('<xmp:MetadataDate>' + Modified.Xmp + '</xmp:MetadataDate>'#10);
    if Creator <> '' then
      X.Append('<xmp:CreatorTool>' + XmlEscape(Creator) + '</xmp:CreatorTool>'#10);
    X.Append('</rdf:Description>'#10);
    X.Append('<rdf:Description rdf:about="" xmlns:pdf="http://ns.adobe.com/pdf/1.3/">'#10);
    if Producer <> '' then
      X.Append('<pdf:Producer>' + XmlEscape(Producer) + '</pdf:Producer>'#10);
    if Keywords <> '' then
      X.Append('<pdf:Keywords>' + XmlEscape(Keywords) + '</pdf:Keywords>'#10);
    X.Append('</rdf:Description>'#10);
    X.Append('</rdf:RDF>'#10'</x:xmpmeta>'#10);
    // room to edit in place, as the XMP spec suggests
    X.Append(StringOfChar(' ', 1024) + #10);
    X.Append('<?xpacket end="w"?>');
    Xmp := TEncoding.UTF8.GetBytes(X.ToString);
  finally
    X.Free;
  end;
  Meta := TPDFStream.Create;
  Meta.Dict.SetValue('Type', TPDFName.Create('Metadata'));
  Meta.Dict.SetValue('Subtype', TPDFName.Create('XML'));
  Meta.SetRawData(Xmp);
  Meta.Dict.SetValue('Length', TPDFInteger.Create(Length(Xmp)));
  FCatalog.SetValue('Metadata', TPDFReference.CreateNum(Add(Meta), 0));
  // sRGB output intent (6.2.3)
  Icc := TPDFStream.Create;
  var P := PDFASRGBProfile;
  Icc.Dict.SetValue('N', TPDFInteger.Create(3));
  Icc.SetRawData(P);
  Icc.Dict.SetValue('Length', TPDFInteger.Create(Length(P)));
  Oi := TPDFDictionary.Create;
  Oi.SetValue('Type', TPDFName.Create('OutputIntent'));
  Oi.SetValue('S', TPDFName.Create('GTS_PDFA1'));
  Oi.SetValue('OutputConditionIdentifier', TPDFString.Create('sRGB IEC61966-2.1'));
  Oi.SetValue('Info', TPDFString.Create('sRGB IEC61966-2.1'));
  Oi.SetValue('DestOutputProfile', TPDFReference.CreateNum(Add(Icc), 0));
  Arr := TPDFArray.Create;
  Arr.Add(Oi);
  FCatalog.SetValue('OutputIntents', Arr);
end;

procedure TPdfaJob.Attach(const Data: TBytes; const Name, Mime: string);
var
  Ef: TPDFStream;
  Fs, EfD, Params, Names, Tree: TPDFDictionary;
  FsNum: Integer;
  Arr, Pair: TPDFArray;
  M: TPDFDictionary;
begin
  // the original as an associated file (PDF/A-3 6.8): /AF from the catalog
  Ef := TPDFStream.Create;
  Ef.Dict.SetValue('Type', TPDFName.Create('EmbeddedFile'));
  Ef.Dict.SetValue('Subtype', TPDFName.Create(Mime));
  Params := TPDFDictionary.Create;
  Params.SetValue('Size', TPDFInteger.Create(Length(Data)));
  Params.SetValue('ModDate', TPDFString.Create(RawByteString(NowDate.Info)));
  var Md5 := THashMD5.Create;
  Md5.Update(Data);
  Params.SetValue('CheckSum', TPDFString.Create(Raw(Md5.HashAsBytes), True));
  Ef.Dict.SetValue('Params', Params);
  Ef.SetRawData(Data);
  Ef.Dict.SetValue('Length', TPDFInteger.Create(Length(Data)));
  Fs := TPDFDictionary.Create;
  Fs.SetValue('Type', TPDFName.Create('Filespec'));
  Fs.SetValue('F', TextString(Name));
  Fs.SetValue('UF', TextString(Name));
  Fs.SetValue('Desc', TextString('Original'));
  Fs.SetValue('AFRelationship', TPDFName.Create('Source'));
  EfD := TPDFDictionary.Create;
  var EfNum := Add(Ef);
  EfD.SetValue('F', TPDFReference.CreateNum(EfNum, 0));
  EfD.SetValue('UF', TPDFReference.CreateNum(EfNum, 0));
  Fs.SetValue('EF', EfD);
  FsNum := Add(Fs);
  Arr := TPDFArray.Create;
  Arr.Add(TPDFReference.CreateNum(FsNum, 0));
  FCatalog.SetValue('AF', Arr);
  M := ResDict(FCatalog.RawGet('Names'));
  if M = nil then
  begin
    Names := TPDFDictionary.Create;
    FCatalog.SetValue('Names', Names);
  end
  else
    Names := M;
  Tree := TPDFDictionary.Create;
  Pair := TPDFArray.Create;
  Pair.Add(TextString(Name));
  Pair.Add(TPDFReference.CreateNum(FsNum, 0));
  Tree.SetValue('Names', Pair);
  Names.SetValue('EmbeddedFiles', Tree);
end;

function ObjKey(O: TPDFObject): string;
var
  S: TBytesStream;
  Md5: THashMD5;
begin
  // the serialized object (and the bytes of a stream): equal key, equal object
  S := TBytesStream.Create;
  try
    if O.IsStream then
    begin
      TPDFObjectSerializer.WriteValue(TPDFStream(O).Dict, S);
      Md5 := THashMD5.Create;
      Md5.Update(TPDFStream(O).RawBytes);
      Result := 'S' + Md5.HashAsString + TEncoding.ANSI.GetString(S.Bytes, 0, S.Size);
    end
    else
    begin
      TPDFObjectSerializer.WriteValue(O, S);
      Result := 'D' + TEncoding.ANSI.GetString(S.Bytes, 0, S.Size);
    end;
  finally
    S.Free;
  end;
end;

procedure TPdfaJob.Dedupe;
var
  Map: TDictionary<Integer, Integer>;
  Seen: TDictionary<string, Integer>;
  Nums: TArray<Integer>;
  O: TPDFObject;
  T: string;
  Pass: Integer;

  procedure Remap(X: TPDFObject);
  var
    D: TPDFDictionary;
    A: TPDFArray;
    V: TPDFObject;
    N: Integer;
  begin
    if X = nil then
      Exit;
    if X.IsStream then
      X := TPDFStream(X).Dict;
    if X.IsDictionary then
    begin
      D := TPDFDictionary(X);
      for var K in D.Keys do
      begin
        V := D.RawGet(K);
        if (V <> nil) and V.IsReference and Map.TryGetValue(TPDFReference(V).RefID.Number, N) then
          D.SetValue(K, TPDFReference.CreateNum(N, 0))
        else
          Remap(V);
      end;
    end
    else if X.IsArray then
    begin
      A := TPDFArray(X);
      for var I := 0 to A.Count - 1 do
      begin
        V := A.Items(I);
        if (V <> nil) and V.IsReference and Map.TryGetValue(TPDFReference(V).RefID.Number, N) then
        begin
          A.Delete(I);
          A.Insert(I, TPDFReference.CreateNum(N, 0));
        end
        else
          Remap(V);
      end;
    end;
  end;

begin
  // equal objects once (fonts repeated per page, the same image twice...):
  // a few passes, because merging streams makes their dictionaries equal
  for Pass := 1 to 4 do
  begin
    Map := TDictionary<Integer, Integer>.Create;
    Seen := TDictionary<string, Integer>.Create;
    try
      Nums := FObjects.Keys.ToArray;
      TArray.Sort<Integer>(Nums);
      for var N in Nums do
      begin
        O := FObjects[N];
        if (N = FCatNum) or (N = FInfoNum) then
          Continue;
        if O.IsDictionary then
        begin
          T := TPDFDictionary(O).GetAsName('Type');
          if InList(T, ['Page', 'Pages', 'Catalog', 'Annot', 'StructElem', 'StructTreeRoot',
             'OBJR', 'MCR', 'Outlines', 'Sig', 'DocTimeStamp']) or
             TPDFDictionary(O).Contains('Parent') or TPDFDictionary(O).Contains('P') then
            Continue;
        end
        else if not O.IsStream then
          Continue;
        var K := ObjKey(O);
        var First: Integer;
        if Seen.TryGetValue(K, First) then
          Map.Add(N, First)
        else
          Seen.Add(K, N);
      end;
      if Map.Count = 0 then
        Break;
      for var N in FObjects.Keys.ToArray do
        if not Map.ContainsKey(N) then
          Remap(FObjects[N]);
      for var N in Map.Keys.ToArray do
        FObjects.Remove(N);
    finally
      Seen.Free;
      Map.Free;
    end;
  end;
end;

function TPdfaJob.Save: TBytes;
var
  Out_: TBytesStream;
  W: TPDFWriter;
  Opts: TPDFWriteOptions;
  Id: TBytes;
begin
  Opts := TPDFWriteOptions.Default;
  Opts.UseObjectStreams := False;
  Opts.UseXRefStream := False;
  Opts.CompressStreams := True;
  Opts.Version := TPDFVersion.Make(1, 7);
  Out_ := TBytesStream.Create;
  try
    W := TPDFWriter.Create(Out_, Opts);
    try
      // a fresh identifier for the new file (6.1.3)
      Id := THashMD5.GetHashBytes(TGUID.NewGuid.ToString + IntToStr(Length(FObjects.Keys.ToArray)));
      W.FileID := Id;
      W.WriteFull(FCatalog, FInfo, TDictionary<Integer, TPDFObject>(FObjects));
    finally
      W.Free;
    end;
    Result := Copy(Out_.Bytes, 0, Out_.Size);
  finally
    Out_.Free;
  end;
end;

function RunJob(const Src: TBytes; const Opt: TPDFAOptions; const Attach: TBytes;
  const AttachName, AttachMime: string): TPDFAResult;
var
  Job: TPdfaJob;
begin
  Job := TPdfaJob.Create(Opt);
  try
    try
      Job.Load(Src);
      if Length(Job.FResult.Problems) > 0 then
        Exit(Job.FResult);
      if (Length(Attach) = 0) and Job.AlreadyPdfA then
      begin
        Job.FResult.Ok := True;
        Job.FResult.AlreadyPdfA := True;
        Job.FResult.Pdf := Src;
        Exit(Job.FResult);
      end;
      for var Pair in Job.FObjects.ToArray do
        Job.FixObject(Pair.Key, Pair.Value);
      Job.FixCatalog;
      if Length(Job.FResult.Problems) > 0 then
        Exit(Job.FResult);
      Job.Metadata;
      if Length(Attach) > 0 then
        Job.Attach(Attach, AttachName, AttachMime);
      Job.Dedupe;
      Job.FResult.Pdf := Job.Save;
      Job.FResult.Ok := True;
      Result := Job.FResult;
    except
      on E: Exception do
      begin
        Result := Job.FResult;
        Result.Ok := False;
        AddProblem(Result, 'no se pudo leer o escribir el PDF: ' + E.Message);
      end;
    end;
  finally
    Job.Free;
  end;
end;

class function TPDFAConverter.FromPdf(const Src: TBytes; const Opt: TPDFAOptions): TPDFAResult;
begin
  Result := RunJob(Src, Opt, nil, '', '');
end;

{ ---- new documents: images ---- }

type
  TImageInfo = record
    Ok: Boolean;
    IsJpeg: Boolean;
    Width, Height: Integer;
    Dpi: Double;
    ColorSpace: string;
    Pixels: TBytes; // PNG: RGB 8 bpc, composited on white
    Why: string;
  end;

function U16(const B: TBytes; I: Integer): Integer; inline;
begin
  Result := (B[I] shl 8) or B[I + 1];
end;

function U32(const B: TBytes; I: Integer): Cardinal; inline;
begin
  Result := (Cardinal(B[I]) shl 24) or (Cardinal(B[I + 1]) shl 16) or
    (Cardinal(B[I + 2]) shl 8) or B[I + 3];
end;

function JpegInfo(const B: TBytes): TImageInfo;
var
  I, L, M: Integer;
begin
  Result := Default(TImageInfo);
  Result.IsJpeg := True;
  Result.Dpi := 150;
  I := 2;
  while I + 4 < Length(B) do
  begin
    if B[I] <> $FF then
    begin
      Inc(I);
      Continue;
    end;
    M := B[I + 1];
    if (M = $D8) or (M = $01) or ((M >= $D0) and (M <= $D7)) or (M = $FF) then
    begin
      Inc(I, 2 - Ord(M = $FF));
      Continue;
    end;
    L := U16(B, I + 2);
    // JFIF density
    if (M = $E0) and (I + 15 < Length(B)) and (B[I + 4] = Ord('J')) and (B[I + 5] = Ord('F')) then
    begin
      var Units := B[I + 11];
      var Xd := U16(B, I + 12);
      if (Units = 1) and (Xd >= 50) then
        Result.Dpi := Xd
      else if (Units = 2) and (Xd >= 20) then
        Result.Dpi := Xd * 2.54;
    end;
    if (M >= $C0) and (M <= $CF) and not (M in [$C4, $C8, $CC]) then
    begin
      Result.Height := U16(B, I + 5);
      Result.Width := U16(B, I + 7);
      case B[I + 9] of
        1: Result.ColorSpace := 'DeviceGray';
        3: Result.ColorSpace := 'DeviceRGB';
      else
        Result.Why := 'JPEG en CMYK o con componentes que PDF/A no admite sin perfil';
        Exit;
      end;
      Result.Ok := (Result.Width > 0) and (Result.Height > 0);
      Exit;
    end;
    Inc(I, 2 + L);
  end;
  Result.Why := 'no es un JPEG válido';
end;

function Paeth(A, B, C: Integer): Integer; inline;
var
  P, Pa, Pb, Pc: Integer;
begin
  P := A + B - C;
  Pa := Abs(P - A);
  Pb := Abs(P - B);
  Pc := Abs(P - C);
  if (Pa <= Pb) and (Pa <= Pc) then
    Result := A
  else if Pb <= Pc then
    Result := B
  else
    Result := C;
end;

function PngInfo(const B: TBytes): TImageInfo;
var
  I, Len, Depth, CType, Channels, Bpp, Stride, X, Y: Integer;
  Typ: string;
  Idat: TBytesStream;
  Plte, Data, Prev, Cur: TBytes;
  Z: TZDecompressionStream;
  Inp: TBytesStream;
  Out_: TBytesStream;

  function Sample(const Row: TBytes; Xp, Ch: Integer): Integer;
  begin
    // the value of channel Ch of pixel Xp, scaled to 0..255
    case Depth of
      8: Result := Row[1 + Xp * Channels + Ch];
      16: Result := Row[1 + (Xp * Channels + Ch) * 2];
    else
      begin
        var Bit := Xp * Depth;
        var V := (Row[1 + Bit div 8] shr (8 - Depth - Bit mod 8)) and ((1 shl Depth) - 1);
        if CType = 3 then
          Result := V
        else
          Result := V * 255 div ((1 shl Depth) - 1);
      end;
    end;
  end;

begin
  Result := Default(TImageInfo);
  Result.Dpi := 150;
  if (Length(B) < 33) or (B[1] <> Ord('P')) or (B[2] <> Ord('N')) or (B[3] <> Ord('G')) then
  begin
    Result.Why := 'no es un PNG válido';
    Exit;
  end;
  Idat := TBytesStream.Create;
  try
    I := 8;
    Depth := 8;
    CType := 2;
    while I + 8 <= Length(B) do
    begin
      Len := U32(B, I);
      Typ := Chr(B[I + 4]) + Chr(B[I + 5]) + Chr(B[I + 6]) + Chr(B[I + 7]);
      if I + 8 + Len > Length(B) then
        Break;
      if Typ = 'IHDR' then
      begin
        Result.Width := U32(B, I + 8);
        Result.Height := U32(B, I + 12);
        Depth := B[I + 16];
        CType := B[I + 17];
        if B[I + 20] <> 0 then
        begin
          Result.Why := 'PNG entrelazado (no se admite todavía)';
          Exit;
        end;
      end
      else if Typ = 'PLTE' then
        Plte := Copy(B, I + 8, Len)
      else if Typ = 'pHYs' then
      begin
        if B[I + 16] = 1 then // por metro
        begin
          var Ppm := U32(B, I + 8);
          if Ppm > 1000 then
            Result.Dpi := Ppm * 0.0254;
        end;
      end
      else if Typ = 'IDAT' then
        Idat.Write(B[I + 8], Len)
      else if Typ = 'IEND' then
        Break;
      Inc(I, 12 + Len);
    end;
    case CType of
      0: Channels := 1;
      2: Channels := 3;
      3: Channels := 1;
      4: Channels := 2;
      6: Channels := 4;
    else
      Result.Why := 'tipo de color PNG desconocido';
      Exit;
    end;
    if (Result.Width <= 0) or (Result.Height <= 0) or (Idat.Size = 0) then
    begin
      Result.Why := 'PNG sin imagen';
      Exit;
    end;
    Inp := TBytesStream.Create(Copy(Idat.Bytes, 0, Idat.Size));
    Out_ := TBytesStream.Create;
    try
      Z := TZDecompressionStream.Create(Inp);
      try
        Out_.CopyFrom(Z, 0);
      finally
        Z.Free;
      end;
      Data := Copy(Out_.Bytes, 0, Out_.Size);
    finally
      Out_.Free;
      Inp.Free;
    end;
  finally
    Idat.Free;
  end;
  Bpp := Max(1, (Channels * Depth) div 8);
  Stride := (Result.Width * Channels * Depth + 7) div 8;
  if Length(Data) < Result.Height * (Stride + 1) then
  begin
    Result.Why := 'PNG incompleto';
    Exit;
  end;
  SetLength(Result.Pixels, Result.Width * Result.Height * 3);
  SetLength(Prev, Stride + 1);
  FillChar(Prev[0], Length(Prev), 0);
  SetLength(Cur, Stride + 1);
  for Y := 0 to Result.Height - 1 do
  begin
    Move(Data[Y * (Stride + 1)], Cur[0], Stride + 1);
    // unfilter (byte 0 is the filter type)
    for X := 1 to Stride do
    begin
      var A := 0;
      if X > Bpp then
        A := Cur[X - Bpp];
      var C := 0;
      if X > Bpp then
        C := Prev[X - Bpp];
      case Cur[0] of
        1: Cur[X] := Byte(Cur[X] + A);
        2: Cur[X] := Byte(Cur[X] + Prev[X]);
        3: Cur[X] := Byte(Cur[X] + (A + Prev[X]) div 2);
        4: Cur[X] := Byte(Cur[X] + Paeth(A, Prev[X], C));
      end;
    end;
    for X := 0 to Result.Width - 1 do
    begin
      var R, G, Bb, Al: Integer;
      Al := 255;
      case CType of
        0: begin R := Sample(Cur, X, 0); G := R; Bb := R; end;
        2: begin R := Sample(Cur, X, 0); G := Sample(Cur, X, 1); Bb := Sample(Cur, X, 2); end;
        3:
          begin
            var Ix := Sample(Cur, X, 0);
            if Ix * 3 + 2 < Length(Plte) then
            begin
              R := Plte[Ix * 3]; G := Plte[Ix * 3 + 1]; Bb := Plte[Ix * 3 + 2];
            end
            else
            begin
              R := 0; G := 0; Bb := 0;
            end;
          end;
        4: begin R := Sample(Cur, X, 0); G := R; Bb := R; Al := Sample(Cur, X, 1); end;
      else
        begin
          R := Sample(Cur, X, 0); G := Sample(Cur, X, 1); Bb := Sample(Cur, X, 2);
          Al := Sample(Cur, X, 3);
        end;
      end;
      // transparency onto white (the preservation copy has no alpha)
      if Al < 255 then
      begin
        R := (R * Al + 255 * (255 - Al)) div 255;
        G := (G * Al + 255 * (255 - Al)) div 255;
        Bb := (Bb * Al + 255 * (255 - Al)) div 255;
      end;
      var P := (Y * Result.Width + X) * 3;
      Result.Pixels[P] := R;
      Result.Pixels[P + 1] := G;
      Result.Pixels[P + 2] := Bb;
    end;
    Move(Cur[0], Prev[0], Stride + 1);
  end;
  Result.ColorSpace := 'DeviceRGB';
  Result.Ok := True;
end;

function BuilderBytes(B: TPDFBuilder): TBytes;
var
  S: TBytesStream;
begin
  S := TBytesStream.Create;
  try
    B.SaveToStream(S);
    Result := Copy(S.Bytes, 0, S.Size);
  finally
    S.Free;
  end;
end;

// the pages of a TIFF; False with the problem in R
function AddTiffPages(B: TPDFBuilder; const Img: TBytes; var R: TPDFAResult): Boolean;
var
  Pages: TArray<TTiffPage>;
  Why: string;
  Page: TPDFDictionary;
  W, H, Sy: Single;
  Cb: TPDFContentBuilder;
  Stm: TPDFStream;
  Parms, Arr: TPDFObject;
begin
  Result := ReadTiff(Img, Pages, Why);
  if not Result then
  begin
    AddProblem(R, Why);
    Exit;
  end;
  for var P in Pages do
  begin
    // the page at the scan's own resolution (a fax: 204 x 98 dpi)
    W := P.Width * 72 / P.DpiX;
    H := P.Height * 72 / P.DpiY;
    Sy := 72 / P.DpiY;
    Page := B.AddPage(W, H);
    Cb := TPDFContentBuilder.Create;
    try
      for var Pc in P.Pieces do
      begin
        Stm := TPDFStream.Create;
        Stm.Dict.SetValue('Width', TPDFInteger.Create(Pc.Width));
        Stm.Dict.SetValue('Height', TPDFInteger.Create(Pc.Rows));
        Stm.Dict.SetValue('ColorSpace', TPDFName.Create(Pc.ColorSpace));
        Stm.Dict.SetValue('BitsPerComponent', TPDFInteger.Create(Pc.Bpc));
        case Pc.Kind of
          TTiffPieceKind.CCITT:
            begin
              Stm.Dict.SetValue('Filter', TPDFName.Create('CCITTFaxDecode'));
              var D := TPDFDictionary.Create;
              D.SetValue('K', TPDFInteger.Create(-1));
              D.SetValue('Columns', TPDFInteger.Create(Pc.Width));
              D.SetValue('Rows', TPDFInteger.Create(Pc.Rows));
              if Pc.BlackIs1 then
                D.SetValue('BlackIs1', TPDFBoolean.Create(True));
              Parms := D;
              Stm.Dict.SetValue('DecodeParms', Parms);
            end;
          TTiffPieceKind.JPEG:
            begin
              Stm.Dict.SetValue('Filter', TPDFName.Create('DCTDecode'));
              if Pc.NoColorTransform then
              begin
                var D := TPDFDictionary.Create;
                D.SetValue('ColorTransform', TPDFInteger.Create(0));
                Parms := D;
                Stm.Dict.SetValue('DecodeParms', Parms);
              end;
            end;
        else
          if Pc.Invert then
          begin
            var A := TPDFArray.Create;
            A.Add(TPDFInteger.Create(1));
            A.Add(TPDFInteger.Create(0));
            Arr := A;
            Stm.Dict.SetValue('Decode', Arr);
          end;
        end;
        Stm.SetRawData(Pc.Data);
        Stm.Dict.SetValue('Length', TPDFInteger.Create(Length(Pc.Data)));
        var Name := B.AddImageXObject(Page, Stm);
        // strips stacked from the top
        Cb.DrawXObject(Name, 0, H - (Pc.Top + Pc.Rows) * Sy, W, Pc.Rows * Sy);
      end;
      B.SetPageContent(Page, Cb.Build);
    finally
      Cb.Free;
    end;
  end;
end;

class function TPDFAConverter.FromImages(const Images: TArray<TBytes>;
  const Opt: TPDFAOptions): TPDFAResult;
var
  B: TPDFBuilder;
  Info: TImageInfo;
  Page: TPDFDictionary;
  Name: string;
  W, H: Single;
  Cb: TPDFContentBuilder;
begin
  Result := Default(TPDFAResult);
  if Length(Images) = 0 then
  begin
    AddProblem(Result, 'no hay imágenes');
    Exit;
  end;
  B := TPDFBuilder.Create;
  try
    for var Img in Images do
    begin
      // II or MM (a BigTIFF too: ReadTiff says why it is not read)
      if (Length(Img) > 3) and (((Img[0] = Ord('I')) and (Img[1] = Ord('I'))) or
         ((Img[0] = Ord('M')) and (Img[1] = Ord('M')))) then
      begin
        // TIFF: every page, G4 and JPEG strips as they are
        if not AddTiffPages(B, Img, Result) then
          Exit;
        Continue;
      end;
      if (Length(Img) > 3) and (Img[0] = $FF) and (Img[1] = $D8) then
        Info := JpegInfo(Img)
      else
        Info := PngInfo(Img);
      if not Info.Ok then
      begin
        AddProblem(Result, Info.Why);
        Exit;
      end;
      // the page at the image's own resolution
      W := Info.Width * 72 / Info.Dpi;
      H := Info.Height * 72 / Info.Dpi;
      Page := B.AddPage(W, H);
      if Info.IsJpeg then
        Name := B.AddJPEGImage(Page, Img, Info.Width, Info.Height, Info.ColorSpace)
      else
        Name := B.AddRawImage(Page, Info.Pixels, Info.Width, Info.Height, Info.ColorSpace);
      Cb := TPDFContentBuilder.Create;
      try
        Cb.DrawXObject(Name, 0, 0, W, H);
        B.SetPageContent(Page, Cb.Build);
      finally
        Cb.Free;
      end;
    end;
    Result := RunJob(BuilderBytes(B), Opt, nil, '', '');
  finally
    B.Free;
  end;
end;

{ ---- new documents: text ---- }

class function TPDFAConverter.FromText(const Text: string; const Attach: TBytes;
  const AttachName, AttachMime: string; const Opt: TPDFAOptions): TPDFAResult;
const
  PAGE_W = 595.28;
  PAGE_H = 841.89;
  MARGIN = 56.0;
  SIZE = 10.5;
  LEADING = 14.0;
var
  FontData: TBytes;
  Parser: TTTFParser;
  Sub: TTTFSubsetter;
  Font: TTTFEmbeddedFont;
  Gids: TList<Word>;
  Seen: TDictionary<Word, Boolean>;
  Clean: string;
  Lines: TList<string>;
  B: TPDFBuilder;
  O: TPDFAOptions;
begin
  Result := Default(TPDFAResult);
  O := Opt;
  if (Length(Attach) > 0) then
    O.Part := TPDFAPart.pdfa3b;
  if (O.FontFile = '') or not FileExists(O.FontFile) then
  begin
    AddProblem(Result, 'falta la fuente TrueType para el texto (FontFile)');
    Exit;
  end;
  FontData := TFile.ReadAllBytes(O.FontFile);
  Parser := TTTFParser.Create(FontData);
  Gids := TList<Word>.Create;
  Seen := TDictionary<Word, Boolean>.Create;
  Lines := TList<string>.Create;
  Sub := nil;
  Font := nil;
  B := TPDFBuilder.Create;
  try
    if not Parser.Parse then
    begin
      AddProblem(Result, 'la fuente no es un TrueType válido');
      Exit;
    end;
    // only characters the font has (.notdef is not allowed in PDF/A, 6.2.11.8)
    var Sb := TStringBuilder.Create;
    try
      for var Ch in Text.Replace(#13#10, #10).Replace(#13, #10).Replace(#9, '    ') do
        if Ch = #10 then
          Sb.Append(Ch)
        else if Ord(Ch) < 32 then
          Continue
        else if Parser.CharToGlyph(Ord(Ch)) = 0 then
          Sb.Append('?')
        else
          Sb.Append(Ch);
      Clean := Sb.ToString;
    finally
      Sb.Free;
    end;
    Seen.Add(0, True);
    Gids.Add(0);
    for var Ch in Clean + '?' do
      if Ch <> #10 then
      begin
        var G := Parser.CharToGlyph(Ord(Ch));
        if (G > 0) and not Seen.ContainsKey(G) then
        begin
          Seen.Add(G, True);
          Gids.Add(G);
        end;
      end;
    Sub := TTTFSubsetter.Create(Parser, Gids.ToArray);
    Font := TTTFEmbeddedFont.Create(Parser, Sub);
    // wrap to the text width, word by word
    for var Para in Clean.Split([#10]) do
    begin
      var Line := '';
      for var Word in Para.Split([' ']) do
      begin
        var Cand := Word;
        if Line <> '' then
          Cand := Line + ' ' + Word;
        if (Line <> '') and (Font.MeasureText(Cand, SIZE) > PAGE_W - 2 * MARGIN) then
        begin
          Lines.Add(Line);
          Line := Word;
        end
        else
          Line := Cand;
        // a word longer than the line: cut it
        while Font.MeasureText(Line, SIZE) > PAGE_W - 2 * MARGIN do
        begin
          var N := Length(Line);
          while (N > 1) and (Font.MeasureText(Copy(Line, 1, N), SIZE) > PAGE_W - 2 * MARGIN) do
            Dec(N);
          Lines.Add(Copy(Line, 1, N));
          Line := Copy(Line, N + 1, MaxInt);
        end;
      end;
      Lines.Add(Line);
    end;
    // pages
    var PerPage := Trunc((PAGE_H - 2 * MARGIN) / LEADING);
    var I := 0;
    repeat
      var Page := B.AddPage(PAGE_W, PAGE_H);
      // each page registers the font (the builder writes one copy per page)
      var Pf := B.AddEmbeddedFont(Page, 'EF1', Parser, Sub);
      var Cb := TPDFContentBuilder.Create;
      try
        Cb.SetFillRGB(0, 0, 0);
        Cb.BeginText;
        Cb.SetFont('EF1', SIZE);
        var K := 0;
        while (K < PerPage) and (I < Lines.Count) do
        begin
          if Lines[I] <> '' then
          begin
            Cb.SetTextMatrix(1, 0, 0, 1, MARGIN, PAGE_H - MARGIN - (K + 1) * LEADING);
            Cb.ShowTextHex(Pf.EncodeTextHex(Lines[I]));
          end;
          Inc(K);
          Inc(I);
        end;
        Cb.EndText;
        B.SetPageContent(Page, Cb.Build);
      finally
        Cb.Free;
      end;
    until I >= Lines.Count;
    Result := RunJob(BuilderBytes(B), O, Attach, AttachName, AttachMime);
  finally
    B.Free;
    Font.Free;
    Sub.Free;
    Lines.Free;
    Seen.Free;
    Gids.Free;
    Parser.Free;
  end;
end;

end.
