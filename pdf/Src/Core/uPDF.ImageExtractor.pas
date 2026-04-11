unit uPDF.ImageExtractor;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Document,
  uPDF.GraphicsState, uPDF.ColorSpace, uPDF.Font,
  uPDF.ContentStream, uPDF.TextExtractor, uPDF.Image;

type
  // -------------------------------------------------------------------------
  // Extracted image record
  // -------------------------------------------------------------------------
  TPDFExtractedImage = record
    Image:        TPDFImage;      // caller owns; call Free when done
    PageIndex:    Integer;
    XObjectName:  string;         // e.g. 'Im1' (empty for inline images)
    IsInline:     Boolean;
    CTM:          TPDFMatrix;     // transform at time of Do / BI..EI
    Width:        Integer;
    Height:       Integer;
    function IsJPEG: Boolean;
    function ColorSpaceName: string;
  end;

  // -------------------------------------------------------------------------
  // Image extractor
  // -------------------------------------------------------------------------
  TPDFImageExtractor = class
  private
    FDocument:  TPDFDocument;
    FImages:    TList<TPDFExtractedImage>;
    FPageIndex: Integer;

    procedure OnXObject(const AName: string; const AMatrix: TPDFMatrix;
      const AState: TPDFGraphicsState);
    procedure OnInlineImage(const AImageDict: TPDFDictionary;
      const AImageData: TBytes; const AState: TPDFGraphicsState);
    procedure ProcessPage(APage: TPDFPage; APageIndex: Integer);
    procedure ProcessFormXObject(AStream: TPDFStream;
      const AMatrix: TPDFMatrix; APage: TPDFPage);
  public
    constructor Create(ADocument: TPDFDocument);
    destructor  Destroy; override;

    // Extract all images from a specific page (0-based)
    // Returns a list; caller must call Image.Free on each entry
    function  ExtractPage(APageIndex: Integer): TArray<TPDFExtractedImage>;

    // Extract from all pages
    function  ExtractAll: TArray<TPDFExtractedImage>;

    // Save all images from a page to a directory
    // Files named: page{N}_img{I}.bmp or page{N}_img{I}.jpg
    procedure SavePageImages(APageIndex: Integer; const AOutDir: string);

    // Save all images from all pages
    procedure SaveAllImages(const AOutDir: string);
  end;

implementation

// =========================================================================
// TPDFExtractedImage helpers
// =========================================================================

function TPDFExtractedImage.IsJPEG: Boolean;
begin
  Result := (Image <> nil) and Image.IsJPEG;
end;

function TPDFExtractedImage.ColorSpaceName: string;
begin
  if Image <> nil then
    Result := Image.Info.ColorSpaceName
  else
    Result := '';
end;

// =========================================================================
// TPDFImageExtractor
// =========================================================================

constructor TPDFImageExtractor.Create(ADocument: TPDFDocument);
begin
  inherited Create;
  FDocument := ADocument;
  FImages   := TList<TPDFExtractedImage>.Create;
end;

destructor TPDFImageExtractor.Destroy;
begin
  FImages.Free;
  inherited;
end;

// -------------------------------------------------------------------------
// Handle Do operator (XObject invocation)
// -------------------------------------------------------------------------

procedure TPDFImageExtractor.OnXObject(const AName: string;
  const AMatrix: TPDFMatrix; const AState: TPDFGraphicsState);
var
  Rec: TPDFExtractedImage;
begin
  // Find the page's current resources
  // We need to look up the XObject stream from page resources
  // The page reference was stashed in FPageIndex; retrieve via document
  if (FPageIndex < 0) or (FPageIndex >= FDocument.PageCount) then Exit;
  var Page := FDocument.Pages[FPageIndex];

  var XObj := Page.GetResource('XObject', AName);
  if XObj = nil then Exit;
  XObj := XObj.Dereference;
  if not XObj.IsStream then Exit;

  var Stm := TPDFStream(XObj);
  var Subtype := Stm.Dict.GetAsName('Subtype');

  if Subtype = 'Image' then
  begin
    var Img := TPDFImage.FromXObject(Stm, FDocument.Resolver);
    if Img = nil then Exit;
    Img.Decode;

    Rec.Image       := Img;
    Rec.PageIndex   := FPageIndex;
    Rec.XObjectName := AName;
    Rec.IsInline    := False;
    Rec.CTM         := AState.CTM;
    Rec.Width       := Img.Width;
    Rec.Height      := Img.Height;
    FImages.Add(Rec);
  end
  else if Subtype = 'Form' then
  begin
    // Recurse into Form XObjects (they may contain images)
    ProcessFormXObject(Stm, AState.CTM, Page);
  end;
end;

// -------------------------------------------------------------------------
// Handle inline images (BI...ID...EI)
// -------------------------------------------------------------------------

procedure TPDFImageExtractor.OnInlineImage(const AImageDict: TPDFDictionary;
  const AImageData: TBytes; const AState: TPDFGraphicsState);
var
  Rec: TPDFExtractedImage;
begin
  var Img := TPDFImage.FromInline(AImageDict, AImageData);
  if Img = nil then Exit;
  Img.Decode;

  Rec.Image       := Img;
  Rec.PageIndex   := FPageIndex;
  Rec.XObjectName := '';
  Rec.IsInline    := True;
  Rec.CTM         := AState.CTM;
  Rec.Width       := Img.Width;
  Rec.Height      := Img.Height;
  FImages.Add(Rec);
end;

// -------------------------------------------------------------------------
// Process a Form XObject recursively
// -------------------------------------------------------------------------

procedure TPDFImageExtractor.ProcessFormXObject(AStream: TPDFStream;
  const AMatrix: TPDFMatrix; APage: TPDFPage);
var
  Proc:     TPDFContentStreamProcessor;
  Data:     TBytes;
begin
  Data := AStream.DecodedBytes;
  if Length(Data) = 0 then Exit;

  // Build a resource adapter for the form's own resources
  // Form XObjects have their own /Resources dict; if absent, inherit from page
  var FormResDict := AStream.Dict.GetAsDictionary('Resources');

  // For simplicity, use the page resources adapter (inherits page fonts/XObjects)
  // A full implementation would merge form resources over page resources
  var Res: IPDFResources := TPDFPageResources.Create(APage);
  Proc := TPDFContentStreamProcessor.Create;
  try
    Proc.OnPaintXObject :=
      procedure(const AName: string; const AM: TPDFMatrix;
        const AState: TPDFGraphicsState)
      begin
        OnXObject(AName, AM, AState);
      end;
    Proc.OnPaintInlineImage :=
      procedure(const ADict: TPDFDictionary; const AData: TBytes;
        const AState: TPDFGraphicsState)
      begin
        OnInlineImage(ADict, AData, AState);
      end;
    Proc.Process(Data, Res, FDocument.Resolver);
  finally
    Proc.Free;
    // Res is IPDFResources — lifetime managed by interface reference counting
  end;
end;

// -------------------------------------------------------------------------
// Process a single page
// -------------------------------------------------------------------------

procedure TPDFImageExtractor.ProcessPage(APage: TPDFPage; APageIndex: Integer);
var
  Proc: TPDFContentStreamProcessor;
  Data: TBytes;
  Res:  IPDFResources;
begin
  FPageIndex := APageIndex;
  Data       := APage.ContentStreamBytes;
  if Length(Data) = 0 then Exit;

  Res  := TPDFPageResources.Create(APage);
  Proc := TPDFContentStreamProcessor.Create;
  try
    Proc.OnPaintXObject :=
      procedure(const AName: string; const AMatrix: TPDFMatrix;
        const AState: TPDFGraphicsState)
      begin
        OnXObject(AName, AMatrix, AState);
      end;
    Proc.OnPaintInlineImage :=
      procedure(const ADict: TPDFDictionary; const AData: TBytes;
        const AState: TPDFGraphicsState)
      begin
        OnInlineImage(ADict, AData, AState);
      end;
    Proc.Process(Data, Res, FDocument.Resolver);
  finally
    Proc.Free;
    // Res is IPDFResources — lifetime managed by interface reference counting
  end;
end;

// =========================================================================
// Public API
// =========================================================================

function TPDFImageExtractor.ExtractPage(APageIndex: Integer): TArray<TPDFExtractedImage>;
begin
  FImages.Clear;

  if (APageIndex < 0) or (APageIndex >= FDocument.PageCount) then
    raise EPDFPageNotFoundError.CreateFmt('Page index %d out of range', [APageIndex]);

  ProcessPage(FDocument.Pages[APageIndex], APageIndex);
  Result := FImages.ToArray;
  FImages.Clear; // ownership transferred to caller
end;

function TPDFImageExtractor.ExtractAll: TArray<TPDFExtractedImage>;
var
  All: TList<TPDFExtractedImage>;
begin
  All := TList<TPDFExtractedImage>.Create;
  try
    for var I := 0 to FDocument.PageCount - 1 do
    begin
      var PageImgs := ExtractPage(I);
      for var Img in PageImgs do
        All.Add(Img);
    end;
    Result := All.ToArray;
  finally
    All.Free;
  end;
end;

procedure TPDFImageExtractor.SavePageImages(APageIndex: Integer;
  const AOutDir: string);
begin
  var Images := ExtractPage(APageIndex);
  try
    for var I := 0 to High(Images) do
    begin
      var Rec := Images[I];
      if Rec.Image = nil then Continue;

      var Ext  := '.bmp';
      if Rec.IsJPEG then Ext := '.jpg';
      var Name := Format('page%d_img%d%s', [APageIndex + 1, I + 1, Ext]);
      var Path := IncludeTrailingPathDelimiter(AOutDir) + Name;

      try
        if Rec.IsJPEG then
        begin
          // Save raw JPEG bytes
          var FS := TFileStream.Create(Path, fmCreate);
          try
            var Bytes := Rec.Image.Samples;
            if Length(Bytes) > 0 then
              FS.Write(Bytes[0], Length(Bytes));
          finally
            FS.Free;
          end;
        end else
          Rec.Image.SaveToBMP(Path);
      except
        on E: Exception do
          ; // Skip images that fail to save
      end;
    end;
  finally
    for var Rec in Images do
      Rec.Image.Free;
  end;
end;

procedure TPDFImageExtractor.SaveAllImages(const AOutDir: string);
begin
  for var I := 0 to FDocument.PageCount - 1 do
    SavePageImages(I, AOutDir);
end;

end.
