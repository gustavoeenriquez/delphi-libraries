unit uPDF.ScanDetector;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Math,
  uPDF.Document,
  uPDF.TextExtractor, uPDF.ImageExtractor;

type
  // -------------------------------------------------------------------------
  // Per-page analysis result
  // -------------------------------------------------------------------------
  TPDFPageScanResult = record
    PageIndex:     Integer;
    IsScanned:     Boolean;
    TextFragments: Integer;  // number of text fragments found on the page
    ImageCoverage: Single;   // 0.0–1.0: fraction of page area covered by images
  end;

  // -------------------------------------------------------------------------
  // TPDFScanDetector
  //
  // Detects whether a PDF page (or document) consists of scanned raster images
  // rather than native text content.
  //
  // A page is considered scanned when both conditions hold:
  //   1. TextFragments < MinTextFragments  (no meaningful text layer)
  //   2. ImageCoverage >= MinImageCoverage (large image fills the page)
  //
  // Usage:
  //   var D := TPDFScanDetector.Create(Doc);
  //   try
  //     if D.IsScanned then
  //       WriteLn('Document appears to be scanned');
  //     for var R in D.AnalyzeDocument do
  //       WriteLn(Format('Page %d — scanned=%s coverage=%.0f%%',
  //         [R.PageIndex, BoolToStr(R.IsScanned, True),
  //          R.ImageCoverage * 100]));
  //   finally
  //     D.Free;
  //   end;
  // -------------------------------------------------------------------------
  TPDFScanDetector = class
  private
    FDocument:         TPDFDocument;
    FMinTextFragments: Integer;
    FMinImageCoverage: Single;
  public
    constructor Create(ADocument: TPDFDocument;
                       AMinTextFragments: Integer = 5;
                       AMinImageCoverage: Single  = 0.75);

    // Analyze a single page (0-based index).
    function  AnalyzePage(APageIndex: Integer): TPDFPageScanResult;

    // Analyze every page in the document.
    function  AnalyzeDocument: TArray<TPDFPageScanResult>;

    // True when the majority (>=50%) of pages appear to be scanned.
    function  IsScanned: Boolean;

    // Pages with fewer text fragments than this threshold are candidates.
    property MinTextFragments: Integer read FMinTextFragments write FMinTextFragments;
    // Pages where images cover at least this fraction are candidates.
    property MinImageCoverage: Single  read FMinImageCoverage write FMinImageCoverage;
  end;

implementation

// =========================================================================
// TPDFScanDetector
// =========================================================================

constructor TPDFScanDetector.Create(ADocument: TPDFDocument;
  AMinTextFragments: Integer; AMinImageCoverage: Single);
begin
  inherited Create;
  FDocument         := ADocument;
  FMinTextFragments := AMinTextFragments;
  FMinImageCoverage := AMinImageCoverage;
end;

function TPDFScanDetector.AnalyzePage(APageIndex: Integer): TPDFPageScanResult;
var
  TextExtr: TPDFTextExtractor;
  ImgExtr:  TPDFImageExtractor;
  PageText: TPDFPageText;
  Images:   TArray<TPDFExtractedImage>;
  Page:     TPDFPage;
  PageArea: Single;
  TotalCov: Single;
  Img:      TPDFExtractedImage;
begin
  Result.PageIndex     := APageIndex;
  Result.TextFragments := 0;
  Result.ImageCoverage := 0;
  Result.IsScanned     := False;

  Page     := FDocument.Pages[APageIndex];
  PageArea := Page.Width * Page.Height;

  // --- 1. Count text fragments ---
  TextExtr := TPDFTextExtractor.Create(FDocument);
  try
    PageText             := TextExtr.ExtractPage(APageIndex);
    Result.TextFragments := Length(PageText.Fragments);
  finally
    TextExtr.Free;
  end;

  // --- 2. Compute image coverage ---
  if PageArea > 0 then
  begin
    ImgExtr := TPDFImageExtractor.Create(FDocument);
    try
      Images   := ImgExtr.ExtractPage(APageIndex);
      TotalCov := 0;
      for Img in Images do
      begin
        // The image occupies a 1×1 unit square mapped to page space by CTM.
        // Rendered area = |det(CTM)| = |A*D - B*C|.
        TotalCov := TotalCov +
          Abs(Img.CTM.A * Img.CTM.D - Img.CTM.B * Img.CTM.C);
        Img.Image.Free;
      end;
      Result.ImageCoverage := EnsureRange(TotalCov / PageArea, 0, 1);
    finally
      ImgExtr.Free;
    end;
  end;

  Result.IsScanned := (Result.TextFragments < FMinTextFragments) and
                      (Result.ImageCoverage >= FMinImageCoverage);
end;

function TPDFScanDetector.AnalyzeDocument: TArray<TPDFPageScanResult>;
var
  I: Integer;
begin
  SetLength(Result, FDocument.PageCount);
  for I := 0 to FDocument.PageCount - 1 do
    Result[I] := AnalyzePage(I);
end;

function TPDFScanDetector.IsScanned: Boolean;
var
  Results:      TArray<TPDFPageScanResult>;
  ScannedCount: Integer;
  R:            TPDFPageScanResult;
begin
  Results      := AnalyzeDocument;
  ScannedCount := 0;
  for R in Results do
    if R.IsScanned then
      Inc(ScannedCount);
  Result := (Length(Results) > 0) and (ScannedCount * 2 >= Length(Results));
end;

end.
