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
end;

class function TPDFSearchOptions.CaseSensitiveExact: TPDFSearchOptions;
begin
  Result.CaseSensitive := True;
  Result.WholeWord     := False;
end;

// ===========================================================================
// TPDFTextSearch
// ===========================================================================

constructor TPDFTextSearch.Create(ADocument: TPDFDocument);
begin
  inherited Create;
  FDocument  := ADocument;
  FExtractor := TPDFTextExtractor.Create(ADocument);
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
    Result := not (C.IsLetterOrDigit or (C = '_'));
  end;

begin
  BuildLineTextAndMap(ALine, LineText, Map);
  if LineText = '' then Exit;

  if AOptions.CaseSensitive then
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
  while Pos <= Length(LineNorm) - Length(SearchIn) + 1 do
  begin
    var Found := PosEx(SearchIn, LineNorm, Pos);
    if Found = 0 then Break;

    // Whole-word check
    if AOptions.WholeWord then
    begin
      if not IsWordBoundary(Found - 1) or
         not IsWordBoundary(Found + Length(SearchIn)) then
      begin
        Pos := Found + 1;
        Continue;
      end;
    end;

    Match.PageIndex := APageIndex;
    Match.LineIndex := ALineIndex;
    Match.Text      := Copy(LineText, Found, Length(AQuery));
    Match.Bounds    := ComputeMatchBounds(ALine, Map, Found - 1, Length(AQuery));

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

  PageText := FExtractor.ExtractPage(APageIndex);
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
