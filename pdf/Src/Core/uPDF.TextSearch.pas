unit uPDF.TextSearch;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.StrUtils, System.Character, System.Math,
  System.Generics.Collections,
  uPDF.Types, uPDF.Errors, uPDF.Document,
  uPDF.TextExtractor;

type
  // -------------------------------------------------------------------------
  // Search options
  // -------------------------------------------------------------------------
  TPDFSearchOptions = record
    CaseSensitive: Boolean;
    WholeWord:     Boolean;
    // OCR-tolerant matching: folds á→a, ñ→n, etc. on BOTH query and line
    // text, treats U+FFFD (replacement char, common in OCR text layers whose
    // fonts lack a Unicode map) in the line as a one-char wildcard, and is
    // elastic with spaces (the line may have extra spaces anywhere, e.g.
    // letter-spaced OCR like "D U R Á N").
    AccentFold:    Boolean;

    class function Default: TPDFSearchOptions; static;
    class function CaseSensitiveExact: TPDFSearchOptions; static;
  end;

  // -------------------------------------------------------------------------
  // A single search match
  // -------------------------------------------------------------------------
  TPDFSearchMatch = record
    PageIndex:  Integer;     // 0-based page
    LineIndex:  Integer;     // 0-based line within page
    Text:       string;      // exact matched text segment (preserves original case)
    Bounds:     TPDFRect;    // bounding box in PDF user-space points (page coords)
  end;

  // -------------------------------------------------------------------------
  // TPDFTextSearch
  //
  // Searches for a query string across pages, returning position-accurate
  // match records with bounding boxes for highlighting / navigation.
  //
  // Usage:
  //   var S := TPDFTextSearch.Create(Doc);
  //   try
  //     for var M in S.Search('invoice') do
  //       WriteLn(Format('Page %d  (%.1f, %.1f)', [M.PageIndex+1, M.Bounds.Left, M.Bounds.Bottom]));
  //   finally
  //     S.Free;
  //   end;
  // -------------------------------------------------------------------------
  TPDFTextSearch = class
  private
    FDocument:  TPDFDocument;
    FExtractor: TPDFTextExtractor;

    // Cache of the last extracted page, so repeated SearchPage calls on the
    // same page (e.g. searching many terms page by page) extract only once.
    FCachePageIndex: Integer;
    FCachePageText:  TPDFPageText;

    // Per-character position descriptor for reconstructed line text.
    type TCharPos = record
      FragIndex:  Integer;   // index into line's Fragments[] array; -1 = injected space
      CharInFrag: Integer;   // character index within fragment's Text (0-based)
    end;

    // Rebuild the line text and a parallel character-position map using the
    // same gap-to-space heuristic as TPDFTextLine.Text.
    procedure BuildLineTextAndMap(const ALine: TPDFTextLine;
      out AText: string; out AMap: TArray<TCharPos>);

    // Compute the bounding rect for a substring of the line using the char map.
    function  ComputeMatchBounds(const ALine: TPDFTextLine;
      const AMap: TArray<TCharPos>;
      AStartChar, ALen: Integer): TPDFRect;

    // Search one line; append matches to AResult.
    procedure SearchLine(const ALine: TPDFTextLine; APageIndex, ALineIndex: Integer;
      const AQuery, AQueryNorm: string;
      const AOptions: TPDFSearchOptions;
      AResult: TList<TPDFSearchMatch>);

  public
    constructor Create(ADocument: TPDFDocument);
    destructor  Destroy; override;

    // Search all pages; returns matches ordered by page then position.
    function Search(const AQuery: string;
      const AOptions: TPDFSearchOptions): TArray<TPDFSearchMatch>; overload;
    function Search(const AQuery: string): TArray<TPDFSearchMatch>; overload;

    // Search a single page.
    function SearchPage(APageIndex: Integer; const AQuery: string;
      const AOptions: TPDFSearchOptions): TArray<TPDFSearchMatch>; overload;
    function SearchPage(APageIndex: Integer;
      const AQuery: string): TArray<TPDFSearchMatch>; overload;
  end;

implementation

// ===========================================================================
// TPDFSearchOptions
// ===========================================================================

class function TPDFSearchOptions.Default: TPDFSearchOptions;
begin
  Result.CaseSensitive := False;
  Result.WholeWord     := False;
  Result.AccentFold    := False;
end;

class function TPDFSearchOptions.CaseSensitiveExact: TPDFSearchOptions;
begin
  Result.CaseSensitive := True;
  Result.WholeWord     := False;
  Result.AccentFold    := False;
end;

// ---------------------------------------------------------------------------
// FoldAccents — 1:1 accent folding (length is preserved, which keeps the
// char-position map valid for ComputeMatchBounds).
// ---------------------------------------------------------------------------
function FoldAccents(const S: string): string;
var
  I: Integer;
begin
  SetLength(Result, Length(S));
  for I := 1 to Length(S) do
    case S[I] of
      'á','à','â','ä','ã': Result[I] := 'a';
      'é','è','ê','ë':     Result[I] := 'e';
      'í','ì','î','ï':     Result[I] := 'i';
      'ó','ò','ô','ö','õ': Result[I] := 'o';
      'ú','ù','û','ü':     Result[I] := 'u';
      'ñ':                 Result[I] := 'n';
      'ç':                 Result[I] := 'c';
      'Á','À','Â','Ä','Ã': Result[I] := 'A';
      'É','È','Ê','Ë':     Result[I] := 'E';
      'Í','Ì','Î','Ï':     Result[I] := 'I';
      'Ó','Ò','Ô','Ö','Õ': Result[I] := 'O';
      'Ú','Ù','Û','Ü':     Result[I] := 'U';
      'Ñ':                 Result[I] := 'N';
      'Ç':                 Result[I] := 'C';
    else
      Result[I] := S[I];
    end;
end;

// ===========================================================================
// TPDFTextSearch
// ===========================================================================

constructor TPDFTextSearch.Create(ADocument: TPDFDocument);
begin
  inherited Create;
  FDocument  := ADocument;
  FExtractor := TPDFTextExtractor.Create(ADocument);
  FCachePageIndex := -1;
end;

destructor TPDFTextSearch.Destroy;
begin
  FExtractor.Free;
  inherited;
end;

// ---------------------------------------------------------------------------
// BuildLineTextAndMap
//
// Reconstructs the display text for a line AND records, for every character
// in that string, which fragment it came from and its position within the
// fragment.  Injected inter-fragment spaces get FragIndex = -1.
//
// Uses the same logic as TPDFTextLine.Text (gap > 25% of font size → space).
// ---------------------------------------------------------------------------
procedure TPDFTextSearch.BuildLineTextAndMap(const ALine: TPDFTextLine;
  out AText: string; out AMap: TArray<TCharPos>);
var
  SB:        TStringBuilder;
  MapList:   TList<TCharPos>;
  PrevEndX:  Single;
  Threshold: Single;
  FI:        Integer;
  CI:        Integer;
  F:         TPDFTextFragment;
  CP:        TCharPos;
begin
  SB      := TStringBuilder.Create;
  MapList := TList<TCharPos>.Create;
  try
    PrevEndX := 0;
    for FI := 0 to High(ALine.Fragments) do
    begin
      F := ALine.Fragments[FI];

      if SB.Length > 0 then
      begin
        Threshold := F.FontSize * 0.25;
        if (F.X - PrevEndX) > Threshold then
        begin
          // Inject an inter-fragment space.
          SB.Append(' ');
          CP.FragIndex  := -1;
          CP.CharInFrag := 0;
          MapList.Add(CP);
        end;
      end;

      // Add each character of this fragment.
      for CI := 1 to Length(F.Text) do
      begin
        SB.Append(F.Text[CI]);
        CP.FragIndex  := FI;
        CP.CharInFrag := CI - 1;
        MapList.Add(CP);
      end;

      PrevEndX := F.X + F.Width;
    end;

    AText := SB.ToString;
    AMap  := MapList.ToArray;
  finally
    MapList.Free;
    SB.Free;
  end;
end;

// ---------------------------------------------------------------------------
// ComputeMatchBounds
//
// Builds a TPDFRect covering all fragments touched by the match at
// [AStartChar .. AStartChar + ALen - 1] in the line's reconstructed text.
//
// Fragment width is distributed uniformly across its characters as an
// approximation (actual per-glyph metrics are not stored by the extractor).
// ---------------------------------------------------------------------------
function TPDFTextSearch.ComputeMatchBounds(const ALine: TPDFTextLine;
  const AMap: TArray<TCharPos>; AStartChar, ALen: Integer): TPDFRect;
var
  I:          Integer;
  CP:         TCharPos;
  F:          TPDFTextFragment;
  CharCount:  Integer;
  CharW:      Single;
  CharX:      Single;
  CharRight:  Single;
  // Running bounds
  MinX, MaxX: Single;
  MinY, MaxY: Single;
  Initialized: Boolean;
begin
  MinX        := 0; MaxX := 0;
  MinY        := 0; MaxY := 0;
  Initialized := False;

  for I := AStartChar to AStartChar + ALen - 1 do
  begin
    if (I < 0) or (I >= Length(AMap)) then Continue;
    CP := AMap[I];
    if CP.FragIndex < 0 then Continue;  // injected space — skip
    if CP.FragIndex > High(ALine.Fragments) then Continue;

    F         := ALine.Fragments[CP.FragIndex];
    CharCount := Length(F.Text);
    if CharCount = 0 then Continue;

    CharW     := F.Width / CharCount;
    CharX     := F.X + CP.CharInFrag * CharW;
    CharRight := CharX + CharW;

    if not Initialized then
    begin
      MinX        := CharX;
      MaxX        := CharRight;
      MinY        := F.Y;
      MaxY        := F.Y + F.FontSize;
      Initialized := True;
    end
    else
    begin
      if CharX     < MinX then MinX := CharX;
      if CharRight > MaxX then MaxX := CharRight;
      if F.Y < MinY then MinY := F.Y;
      if (F.Y + F.FontSize) > MaxY then MaxY := F.Y + F.FontSize;
    end;
  end;

  if not Initialized then
    Result := TPDFRect.Make(0, 0, 0, 0)
  else
    Result := TPDFRect.Make(MinX, MinY, MaxX, MaxY);
end;

// ---------------------------------------------------------------------------
// SearchLine
// ---------------------------------------------------------------------------
procedure TPDFTextSearch.SearchLine(const ALine: TPDFTextLine;
  APageIndex, ALineIndex: Integer;
  const AQuery, AQueryNorm: string;
  const AOptions: TPDFSearchOptions;
  AResult: TList<TPDFSearchMatch>);
var
  LineText:  string;
  LineNorm:  string;
  Map:       TArray<TCharPos>;
  Pos:       Integer;
  SearchIn:  string;
  Match:     TPDFSearchMatch;

  function IsWordBoundary(ACharIdx: Integer): Boolean;
  var
    C: Char;
  begin
    if (ACharIdx < 1) or (ACharIdx > Length(LineText)) then
      Exit(True);
    C := LineText[ACharIdx];
    // In OCR-tolerant mode digits count as boundaries: OCR layers often glue
    // footnote numbers to words ("Durán15"), and these queries are names,
    // which never contain digits.
    if AOptions.AccentFold then
      Result := not (C.IsLetter or (C = '_'))
    else
      Result := not (C.IsLetterOrDigit or (C = '_'));
  end;

  // OCR-tolerant scan: U+FFFD in the line matches any single query char, and
  // spaces are elastic — the line may contain extra spaces anywhere (e.g.
  // letter-spaced OCR "D U R Á N"), and each query space matches one or more
  // line spaces. Returns the start position, and the actual matched length
  // in AMatchLen (variable, because of the elastic spaces).
  function ElasticPos(const ANeedle, AHaystack: string; AFrom: Integer;
    out AMatchLen: Integer): Integer;
  var
    I, J, K: Integer;
    LC, QC:  Char;
  begin
    AMatchLen := 0;
    for I := AFrom to Length(AHaystack) do
    begin
      if AHaystack[I] = ' ' then Continue;  // un match no inicia en espacio
      J := I;
      K := 1;
      while K <= Length(ANeedle) do
      begin
        if J > Length(AHaystack) then Break;
        LC := AHaystack[J];
        QC := ANeedle[K];
        if QC = ' ' then
        begin
          // un espacio del query consume 1+ espacios de la línea
          if LC <> ' ' then Break;
          while (J <= Length(AHaystack)) and (AHaystack[J] = ' ') do Inc(J);
          Inc(K);
        end
        else if (LC = QC) or (LC = #$FFFD) then
        begin
          Inc(J);
          Inc(K);
        end
        else if LC = ' ' then
          // espacio extra en la línea (letter-spacing del OCR): saltarlo
          Inc(J)
        else
          Break;
      end;
      if K > Length(ANeedle) then
      begin
        AMatchLen := J - I;
        Exit(I);
      end;
    end;
    Result := 0;
  end;

begin
  BuildLineTextAndMap(ALine, LineText, Map);
  if LineText = '' then Exit;

  if AOptions.AccentFold then
  begin
    // Fold BEFORE lowercasing: Delphi's LowerCase is ASCII-only, so 'Á'
    // survives it; folding first turns 'Á'→'A', which LowerCase does handle.
    LineNorm := FoldAccents(LineText);
    SearchIn := FoldAccents(AQuery);
    if not AOptions.CaseSensitive then
    begin
      LineNorm := LowerCase(LineNorm);
      SearchIn := LowerCase(SearchIn);
    end;
  end
  else if AOptions.CaseSensitive then
  begin
    LineNorm := LineText;
    SearchIn := AQueryNorm;  // AQueryNorm = AQuery when case-sensitive
  end
  else
  begin
    LineNorm := LowerCase(LineText);
    SearchIn := AQueryNorm;   // already lower-cased by caller
  end;

  Pos := 1;
  while Pos <= Length(LineNorm) do
  begin
    var Found, MatchLen: Integer;
    if AOptions.AccentFold then
      Found := ElasticPos(SearchIn, LineNorm, Pos, MatchLen)
    else
    begin
      Found    := PosEx(SearchIn, LineNorm, Pos);
      MatchLen := Length(SearchIn);
    end;
    if Found = 0 then Break;

    // Whole-word check
    if AOptions.WholeWord then
    begin
      if not IsWordBoundary(Found - 1) or
         not IsWordBoundary(Found + MatchLen) then
      begin
        Pos := Found + 1;
        Continue;
      end;
    end;

    Match.PageIndex := APageIndex;
    Match.LineIndex := ALineIndex;
    Match.Text      := Copy(LineText, Found, MatchLen);
    Match.Bounds    := ComputeMatchBounds(ALine, Map, Found - 1, MatchLen);

    AResult.Add(Match);
    Pos := Found + 1;  // allow overlapping matches
  end;
end;

// ---------------------------------------------------------------------------
// SearchPage
// ---------------------------------------------------------------------------
function TPDFTextSearch.SearchPage(APageIndex: Integer; const AQuery: string;
  const AOptions: TPDFSearchOptions): TArray<TPDFSearchMatch>;
var
  PageText:  TPDFPageText;
  QueryNorm: string;
  Results:   TList<TPDFSearchMatch>;
  LI:        Integer;
begin
  if AQuery = '' then Exit(nil);

  if AOptions.CaseSensitive then
    QueryNorm := AQuery
  else
    QueryNorm := LowerCase(AQuery);

  if APageIndex <> FCachePageIndex then
  begin
    FCachePageText  := FExtractor.ExtractPage(APageIndex);
    FCachePageIndex := APageIndex;
  end;
  PageText := FCachePageText;
  Results  := TList<TPDFSearchMatch>.Create;
  try
    for LI := 0 to High(PageText.Lines) do
      SearchLine(PageText.Lines[LI], APageIndex, LI,
        AQuery, QueryNorm, AOptions, Results);
    Result := Results.ToArray;
  finally
    Results.Free;
  end;
end;

function TPDFTextSearch.SearchPage(APageIndex: Integer;
  const AQuery: string): TArray<TPDFSearchMatch>;
begin
  Result := SearchPage(APageIndex, AQuery, TPDFSearchOptions.Default);
end;

// ---------------------------------------------------------------------------
// Search (all pages)
// ---------------------------------------------------------------------------
function TPDFTextSearch.Search(const AQuery: string;
  const AOptions: TPDFSearchOptions): TArray<TPDFSearchMatch>;
var
  All:      TList<TPDFSearchMatch>;
  I:        Integer;
  PageHits: TArray<TPDFSearchMatch>;
  M:        TPDFSearchMatch;
begin
  if AQuery = '' then Exit(nil);

  All := TList<TPDFSearchMatch>.Create;
  try
    for I := 0 to FDocument.PageCount - 1 do
    begin
      PageHits := SearchPage(I, AQuery, AOptions);
      for M in PageHits do
        All.Add(M);
    end;
    Result := All.ToArray;
  finally
    All.Free;
  end;
end;

function TPDFTextSearch.Search(const AQuery: string): TArray<TPDFSearchMatch>;
begin
  Result := Search(AQuery, TPDFSearchOptions.Default);
end;

end.
