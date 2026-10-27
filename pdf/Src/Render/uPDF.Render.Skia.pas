unit uPDF.Render.Skia;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Math.Vectors,
  System.Types, System.UITypes, System.Generics.Collections,
  System.Skia,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Document,
  uPDF.ContentStream, uPDF.GraphicsState, uPDF.ColorSpace, uPDF.Font,
  uPDF.Image, uPDF.Render.Types, uPDF.Render.FontCache;

type
  // -------------------------------------------------------------------------
  // Resources wrapper used internally by TPDFSkiaRenderer
  // Implements IPDFResources and delegates to a TPDFPage.
  // -------------------------------------------------------------------------
  TPDFPageResources = class(TInterfacedObject, IPDFResources)
  private
    FPage:     TPDFPage;
    FOverride: TPDFDictionary;  // optional override (for form XObjects)
    // AType/AName in the form's resources, then in the page's
    function Lookup(const AType, AName: string): TPDFObject;
  public
    constructor Create(APage: TPDFPage; AOverride: TPDFDictionary = nil);
    function GetFont(const AName: string): TPDFFont;
    function GetXObject(const AName: string): TPDFStream;
    function GetColorSpace(const AName: string): TPDFColorSpace;
    function GetExtGState(const AName: string): TPDFDictionary;
    function GetPattern(const AName: string): TPDFObject;
    function GetShading(const AName: string): TPDFObject;
  end;

  // -------------------------------------------------------------------------
  // Skia-based PDF page renderer
  //
  // Usage:
  //   var R := TPDFSkiaRenderer.Create(TPDFRenderOptions.Default);
  //   try
  //     R.RenderPage(Doc[0], Canvas, 595, 842);
  //   finally
  //     R.Free;
  //   end;
  // -------------------------------------------------------------------------
  TPDFSkiaRenderer = class
  private
    FOptions:   TPDFRenderOptions;
    FFontCache: TPDFFontCache;

    // ---- Per-render context (reset in RenderPage) ----
    FCanvas:           ISkCanvas;
    FPage:             TPDFPage;
    FCurrentResources: IPDFResources;  // active resource set (page or form)
    FPageW:            Single;   // page width in PDF points
    FPageH:            Single;   // page height in PDF points
    FScaleX:           Single;   // PDF points → render pixels
    FScaleY:           Single;
    FRenderW:          Single;   // render target size in pixels
    FRenderH:          Single;
    // Page-flip + scale matrix (PDF → screen)
    FPageFlip:         TMatrix;
    FFormDepth:        Integer;  // nesting of form XObjects being drawn
    // Accumulates glyph outlines (device space) during a BT..ET block for clip modes
    FTextClipBuilder:  ISkPathBuilder;

    // ---- Content-stream callbacks ----
    procedure OnPaintPath(const APath: TPDFPath;
                          const AState: TPDFGraphicsState;
                          AOp: TPDFPaintOp);
    procedure PaintGlyphPath(const APath: ISkPath; const AGlyph: TPDFGlyphInfo;
      const AState: TPDFGraphicsState);
    procedure OnPaintGlyph(const AGlyph: TPDFGlyphInfo;
                           const AState: TPDFGraphicsState);
    procedure OnPaintXObject(const AName: string;
                             const AMatrix: TPDFMatrix;
                             const AState: TPDFGraphicsState);
    procedure OnPaintInlineImage(const AImageDict: TPDFDictionary;
                                 const AImageData: TBytes;
                                 const AState: TPDFGraphicsState);
    procedure OnSaveRestore(AIsSave: Boolean;
                            const AState: TPDFGraphicsState);
    procedure OnTextBlock(AIsBT: Boolean;
                          const AState: TPDFGraphicsState);
    procedure OnPaintShading(const AName: string;
                             const AState: TPDFGraphicsState);

    // ---- Internal helpers ----
    function  BuildSkPath(const APath: TPDFPath;
                          AFillType: TSkPathFillType): ISkPath;
    function  PDFMatrixToSkia(const AM: TPDFMatrix): TMatrix; inline;
    // Matrix for drawing text: corrects Y-axis flip so glyphs render right-side-up
    function  TextMatrix(const AGM: TPDFMatrix): TMatrix; inline;
    // Matrix for drawing images: corrects top-left vs bottom-left origin
    function  ImageMatrix(const ACM: TPDFMatrix): TMatrix; inline;

    function  PDFColorToAlpha(const AColor: TPDFColor; AAlpha: Single): TAlphaColor;
    function  PDFLineCapToSkia(ACap: TPDFLineCap): TSkStrokeCap;
    function  PDFLineJoinToSkia(AJoin: TPDFLineJoin): TSkStrokeJoin;
    function  PDFBlendToSkia(ABM: TPDFBlendMode): TSkBlendMode;

    procedure ConfigureStrokePaint(APaint: ISkPaint;
                                   const AState: TPDFGraphicsState);
    procedure ConfigureFillPaint(APaint: ISkPaint;
                                 const AState: TPDFGraphicsState;
                                 AEvenOdd: Boolean);

    // Draw a decoded TPDFImage (or inline image) at the current CTM position;
    // image masks paint with the fill colour of AState
    function  ImageSampling(AImage: TPDFImage; const ACanvasMatrix: TMatrix): TSkSamplingOptions;
    procedure DrawPDFImage(AImage: TPDFImage; const ACanvasMatrix: TMatrix;
      const AState: TPDFGraphicsState);

    // ---- Shading / pattern helpers ----
    // Evaluate a PDF function (Type 2 or 3) at parameter t → color components
    function  EvalPDFFunction(AFunc: TPDFObject; T: Single): TArray<Single>;
    // Convert shading color components to TAlphaColor
    function  ShadingComponentsToAlpha(const AComps: TArray<Single>;
                const ACSName: string): TAlphaColor;
    // Build a Skia gradient shader from a shading dict.
    // APreMatrix transforms from shading/pattern space to user space.
    function  BuildShadingShader(AShading: TPDFDictionary;
                const APreMatrix: TPDFMatrix): ISkShader;
    // Look up a pattern and build its fill shader (nil if not a gradient pattern)
    function  BuildPatternShader(const APatternName: string;
                const AState: TPDFGraphicsState): ISkShader;

    // Process a form XObject (recursive)
    procedure RenderFormXObject(AStream: TPDFStream;
                                const APlacementCTM: TPDFMatrix; const AState: TPDFGraphicsState);

  public
    constructor Create(const AOptions: TPDFRenderOptions);
    destructor  Destroy; override;

    // Render APage onto ACanvas.
    // ARenderWidth/Height are the target pixel dimensions for the page.
    // The canvas origin must be at (0,0); caller handles offset/clip externally.
    procedure RenderPage(APage: TPDFPage; ACanvas: ISkCanvas;
                         ARenderWidth, ARenderHeight: Single);

    // Convenience: render to an off-screen ISkImage (RGBA8888).
    function  RenderPageToImage(APage: TPDFPage;
                                ARenderWidth, ARenderHeight: Integer): ISkImage;

    // Headless helpers — no UI required, safe to call from services/APIs.

    // Render to PNG bytes (suitable for HTTP responses, file storage, etc.)
    function  RenderPageToPng(APage: TPDFPage;
                              ARenderWidth, ARenderHeight: Integer): TBytes;

    // Render to JPEG bytes.  AQuality: 0–100 (default 90).
    function  RenderPageToJpeg(APage: TPDFPage;
                               ARenderWidth, ARenderHeight: Integer;
                               AQuality: Integer = 90): TBytes;

    // Render and save directly to a file.
    // Format is inferred from the extension: .png → PNG, anything else → JPEG.
    procedure RenderPageToFile(APage: TPDFPage;
                               ARenderWidth, ARenderHeight: Integer;
                               const AFilePath: string);

    property  Options:   TPDFRenderOptions read FOptions;
    property  FontCache: TPDFFontCache     read FFontCache;
  end;

implementation

uses
  System.Character;

const
  MAX_FORM_DEPTH = 32;

// =========================================================================
// TPDFPageResources
// =========================================================================

constructor TPDFPageResources.Create(APage: TPDFPage; AOverride: TPDFDictionary);
begin
  inherited Create;
  FPage     := APage;
  FOverride := AOverride;
end;

function TPDFPageResources.Lookup(const AType, AName: string): TPDFObject;
begin
  Result := nil;
  if FOverride <> nil then
  begin
    var TypeDict := FOverride.GetAsDictionary(AType);
    if TypeDict <> nil then
      Result := TypeDict.Get(AName);
  end;
  if Result = nil then
    Result := FPage.GetResource(AType, AName);
end;

function TPDFPageResources.GetFont(const AName: string): TPDFFont;
var
  Obj: TPDFObject;
begin
  Result := nil;
  Obj := Lookup('Font', AName);
  if (Obj <> nil) and Obj.IsDictionary then
    Result := TPDFFontFactory.Build(TPDFDictionary(Obj),
                FPage.Document.Resolver);
end;

function TPDFPageResources.GetXObject(const AName: string): TPDFStream;
var
  Obj: TPDFObject;
begin
  Result := nil;
  Obj := Lookup('XObject', AName);
  if (Obj <> nil) and Obj.IsStream then
    Result := TPDFStream(Obj);
end;

function TPDFPageResources.GetColorSpace(const AName: string): TPDFColorSpace;
var
  Obj: TPDFObject;
begin
  Result := nil;
  Obj := Lookup('ColorSpace', AName);
  if Obj <> nil then
    Result := TPDFColorSpaceFactory.Build(Obj, FPage.Document.Resolver);
end;

function TPDFPageResources.GetExtGState(const AName: string): TPDFDictionary;
var
  Obj: TPDFObject;
begin
  Result := nil;
  Obj := Lookup('ExtGState', AName);
  if (Obj <> nil) and Obj.IsDictionary then
    Result := TPDFDictionary(Obj);
end;

function TPDFPageResources.GetPattern(const AName: string): TPDFObject;
begin
  Result := Lookup('Pattern', AName);
end;

function TPDFPageResources.GetShading(const AName: string): TPDFObject;
begin
  Result := Lookup('Shading', AName);
end;

// =========================================================================
// TPDFSkiaRenderer
// =========================================================================

constructor TPDFSkiaRenderer.Create(const AOptions: TPDFRenderOptions);
begin
  inherited Create;
  FOptions   := AOptions;
  FFontCache := TPDFFontCache.Create;
end;

destructor TPDFSkiaRenderer.Destroy;
begin
  FFontCache.Free;
  inherited;
end;

// =========================================================================
// Matrix helpers
// =========================================================================

// PDF matrix [A,B,C,D,E,F] → Delphi TMatrix (row-major, row vectors)
// Row-vector convention: x' = a*x + c*y + e,  y' = b*x + d*y + f
// Delphi TMatrix: x' = m11*x + m21*y + m31
//                 y' = m12*x + m22*y + m32
// So: m11=A, m12=B, m21=C, m22=D, m31=E, m32=F
function TPDFSkiaRenderer.PDFMatrixToSkia(const AM: TPDFMatrix): TMatrix;
begin
  Result.m11 := AM.A;  Result.m12 := AM.B;  Result.m13 := 0;
  Result.m21 := AM.C;  Result.m22 := AM.D;  Result.m23 := 0;
  Result.m31 := AM.E;  Result.m32 := AM.F;  Result.m33 := 1;
end;

// Matrix for placing text glyphs on screen. Skia glyphs grow downward (y
// down) while glyph space grows upward, so a vertical flip goes first:
//   Result = TextFlip * GlyphMatrix * PageFlip,  TextFlip = [[1,0],[0,-1]]
// PageFlip carries the page rotation and the CropBox origin.
function TPDFSkiaRenderer.TextMatrix(const AGM: TPDFMatrix): TMatrix;
var
  Flip: TMatrix;
begin
  Flip := TMatrix.Identity;
  Flip.m22 := -1;
  Result := Flip * PDFMatrixToSkia(AGM) * FPageFlip;
end;

// Matrix for placing image XObjects on screen.
// PDF images store row 0 at the TOP of the unit square (y=1 in PDF space).
// We correct this by inserting a vertical flip within the unit square:
//   ImageFlip = [[1,0,0],[0,-1,0],[0,1,1]]   (y' = 1 - y)
// Combined: ImageFlip * CTM_skia * PageFlip
function TPDFSkiaRenderer.ImageMatrix(const ACM: TPDFMatrix): TMatrix;
var
  CM: TMatrix;
begin
  // ImageFlip pre-multiplied into the CTM before PageFlip
  // Computes: [[A,B,0],[C,D,0],[E+(-F+C_row2_y),F_corrected,1]] * PageFlip
  // Simpler: let Skia multiply ImageFlip * CTM, then apply PageFlip
  CM := PDFMatrixToSkia(ACM);
  // ImageFlip = TMatrix.Create(1, 0, 0, -1, 0, 1)
  var ImgFlip: TMatrix;
  ImgFlip.m11 := 1;  ImgFlip.m12 := 0;  ImgFlip.m13 := 0;
  ImgFlip.m21 := 0;  ImgFlip.m22 := -1; ImgFlip.m23 := 0;
  ImgFlip.m31 := 0;  ImgFlip.m32 := 1;  ImgFlip.m33 := 1;
  Result := ImgFlip * CM * FPageFlip;
end;

// =========================================================================
// Color helpers
// =========================================================================

function TPDFSkiaRenderer.PDFColorToAlpha(const AColor: TPDFColor;
  AAlpha: Single): TAlphaColor;
var
  Base: TAlphaColor;
  A:    Byte;
begin
  Base := AColor.ToAlphaColor;
  A    := Round(Max(0.0, Min(1.0, AAlpha)) * 255);
  // Replace alpha channel (keep RGB)
  Result := (Base and $00FFFFFF) or (TAlphaColor(A) shl 24);
end;

// =========================================================================
// Line-cap / join / blend mode conversion
// =========================================================================

function TPDFSkiaRenderer.PDFLineCapToSkia(ACap: TPDFLineCap): TSkStrokeCap;
begin
  case ACap of
    TPDFLineCap.RoundCap:            Result := TSkStrokeCap.Round;
    TPDFLineCap.ProjectingSquareCap: Result := TSkStrokeCap.Square;
  else
    Result := TSkStrokeCap.Butt;
  end;
end;

function TPDFSkiaRenderer.PDFLineJoinToSkia(AJoin: TPDFLineJoin): TSkStrokeJoin;
begin
  case AJoin of
    TPDFLineJoin.RoundJoin: Result := TSkStrokeJoin.Round;
    TPDFLineJoin.BevelJoin: Result := TSkStrokeJoin.Bevel;
  else
    Result := TSkStrokeJoin.Miter;
  end;
end;

function TPDFSkiaRenderer.PDFBlendToSkia(ABM: TPDFBlendMode): TSkBlendMode;
begin
  case ABM of
    TPDFBlendMode.Multiply:   Result := TSkBlendMode.Multiply;
    TPDFBlendMode.Screen:     Result := TSkBlendMode.Screen;
    TPDFBlendMode.Overlay:    Result := TSkBlendMode.Overlay;
    TPDFBlendMode.Darken:     Result := TSkBlendMode.Darken;
    TPDFBlendMode.Lighten:    Result := TSkBlendMode.Lighten;
    TPDFBlendMode.ColorDodge: Result := TSkBlendMode.ColorDodge;
    TPDFBlendMode.ColorBurn:  Result := TSkBlendMode.ColorBurn;
    TPDFBlendMode.HardLight:  Result := TSkBlendMode.HardLight;
    TPDFBlendMode.SoftLight:  Result := TSkBlendMode.SoftLight;
    TPDFBlendMode.Difference: Result := TSkBlendMode.Difference;
    TPDFBlendMode.Exclusion:  Result := TSkBlendMode.Exclusion;
    TPDFBlendMode.Hue:        Result := TSkBlendMode.Hue;
    TPDFBlendMode.Saturation: Result := TSkBlendMode.Saturation;
    TPDFBlendMode.Color:      Result := TSkBlendMode.Color;
    TPDFBlendMode.Luminosity: Result := TSkBlendMode.Luminosity;
  else
    Result := TSkBlendMode.SrcOver;
  end;
end;

// =========================================================================
// Paint configuration
// =========================================================================

procedure TPDFSkiaRenderer.ConfigureStrokePaint(APaint: ISkPaint;
  const AState: TPDFGraphicsState);
var
  Intervals: TArray<Single>;
  I: Integer;
begin
  APaint.Style     := TSkPaintStyle.Stroke;
  APaint.AntiAlias := FOptions.Antialias;

  // Pattern color space: use gradient shader if available
  if (AState.StrokeColorSpace = 'Pattern') and (AState.StrokePatternName <> '') then
  begin
    var Shader := BuildPatternShader(AState.StrokePatternName, AState);
    if Shader <> nil then
      APaint.Shader := Shader
    else
      APaint.Color := PDFColorToAlpha(AState.StrokeColor, AState.StrokeAlpha);
  end
  else
    APaint.Color := PDFColorToAlpha(AState.StrokeColor, AState.StrokeAlpha);
  // in user space: the canvas matrix (CTM x page) scales it to pixels
  APaint.StrokeWidth := AState.LineWidth;
  APaint.StrokeCap   := PDFLineCapToSkia(AState.LineCap);
  APaint.StrokeJoin  := PDFLineJoinToSkia(AState.LineJoin);
  APaint.StrokeMiter := AState.MiterLimit;
  APaint.Blender     := TSkBlender.MakeMode(PDFBlendToSkia(AState.BlendMode));

  // Dash pattern
  if not AState.Dash.IsEmpty then
  begin
    SetLength(Intervals, Length(AState.Dash.Lengths));
    for I := 0 to High(AState.Dash.Lengths) do
      Intervals[I] := AState.Dash.Lengths[I];
    APaint.PathEffect := TSkPathEffect.MakeDash(Intervals, AState.Dash.Phase);
  end;
end;

procedure TPDFSkiaRenderer.ConfigureFillPaint(APaint: ISkPaint;
  const AState: TPDFGraphicsState; AEvenOdd: Boolean);
begin
  APaint.Style     := TSkPaintStyle.Fill;
  APaint.AntiAlias := FOptions.Antialias;
  APaint.Blender   := TSkBlender.MakeMode(PDFBlendToSkia(AState.BlendMode));

  // Pattern color space: use gradient shader if available
  if (AState.FillColorSpace = 'Pattern') and (AState.FillPatternName <> '') then
  begin
    var Shader := BuildPatternShader(AState.FillPatternName, AState);
    if Shader <> nil then
    begin
      APaint.Shader := Shader;
      Exit;
    end;
  end;

  APaint.Color := PDFColorToAlpha(AState.FillColor, AState.FillAlpha);
  // EvenOdd fill type is set on the ISkPath, not the paint
end;

// =========================================================================
// Path conversion
// =========================================================================

function TPDFSkiaRenderer.BuildSkPath(const APath: TPDFPath;
  AFillType: TSkPathFillType): ISkPath;
var
  B:    ISkPathBuilder;
  Segs: TList<TPDFPathSegment>;
  Seg:  TPDFPathSegment;
begin
  B    := TSkPathBuilder.Create(AFillType);
  Segs := APath.Segments;
  for Seg in Segs do
  begin
    case Seg.Kind of
      TPDFPathSegKind.MoveTo:
        B.MoveTo(Seg.P1.X, Seg.P1.Y);
      TPDFPathSegKind.LineTo:
        B.LineTo(Seg.P1.X, Seg.P1.Y);
      TPDFPathSegKind.CurveTo:
        B.CubicTo(Seg.P1.X, Seg.P1.Y,
                  Seg.P2.X, Seg.P2.Y,
                  Seg.P3.X, Seg.P3.Y);
      TPDFPathSegKind.CurveToV:
        // 'v' operator: first CP = current point (P1 = current, already in B)
        // PDF spec: x1,y1 omitted, use current point as first CP
        // P2 = second CP, P3 = endpoint. Expand to cubic with repeated first CP:
        B.CubicTo(Seg.P1.X, Seg.P1.Y,
                  Seg.P2.X, Seg.P2.Y,
                  Seg.P3.X, Seg.P3.Y);
      TPDFPathSegKind.CurveToY:
        // 'y' operator: last CP = endpoint. P1 = first CP, P3 = endpoint (= last CP)
        B.CubicTo(Seg.P1.X, Seg.P1.Y,
                  Seg.P3.X, Seg.P3.Y,
                  Seg.P3.X, Seg.P3.Y);
      TPDFPathSegKind.Close:
        B.Close;
    end;
  end;
  Result := B.Detach;
end;

// =========================================================================
// Content-stream callbacks
// =========================================================================

procedure TPDFSkiaRenderer.OnSaveRestore(AIsSave: Boolean;
  const AState: TPDFGraphicsState);
begin
  if AIsSave then
    FCanvas.Save
  else
    FCanvas.Restore;
end;

// -------------------------------------------------------------------------
procedure TPDFSkiaRenderer.OnTextBlock(AIsBT: Boolean;
  const AState: TPDFGraphicsState);
begin
  if AIsBT then
    FTextClipBuilder := nil
  else
  begin
    if FTextClipBuilder <> nil then
    begin
      var ClipPath := FTextClipBuilder.Detach;
      FCanvas.SetMatrix(TMatrix.Identity);
      FCanvas.ClipPath(ClipPath, TSkClipOp.Intersect, FOptions.Antialias);
      FTextClipBuilder := nil;
    end;
  end;
end;

// -------------------------------------------------------------------------
procedure TPDFSkiaRenderer.OnPaintPath(const APath: TPDFPath;
  const AState: TPDFGraphicsState; AOp: TPDFPaintOp);
var
  SkPath:    ISkPath;
  FillType:  TSkPathFillType;
  FillPaint: ISkPaint;
  StrPaint:  ISkPaint;
  M:         TMatrix;
begin
  if APath.IsEmpty then Exit;

  M := PDFMatrixToSkia(AState.CTM) * FPageFlip;
  FCanvas.SetMatrix(M);

  case AOp of
    TPDFPaintOp.ClipNonZero:
    begin
      SkPath := BuildSkPath(APath, TSkPathFillType.Winding);
      FCanvas.ClipPath(SkPath, TSkClipOp.Intersect, FOptions.Antialias);
    end;

    TPDFPaintOp.ClipEvenOdd:
    begin
      SkPath := BuildSkPath(APath, TSkPathFillType.EvenOdd);
      FCanvas.ClipPath(SkPath, TSkClipOp.Intersect, FOptions.Antialias);
    end;

    TPDFPaintOp.Stroke:
    begin
      SkPath    := BuildSkPath(APath, TSkPathFillType.Winding);
      StrPaint  := TSkPaint.Create;
      ConfigureStrokePaint(StrPaint, AState);
      FCanvas.DrawPath(SkPath, StrPaint);
    end;

    TPDFPaintOp.Fill:
    begin
      SkPath    := BuildSkPath(APath, TSkPathFillType.Winding);
      FillPaint := TSkPaint.Create;
      ConfigureFillPaint(FillPaint, AState, False);
      FCanvas.DrawPath(SkPath, FillPaint);
    end;

    TPDFPaintOp.FillEvenOdd:
    begin
      SkPath    := BuildSkPath(APath, TSkPathFillType.EvenOdd);
      FillPaint := TSkPaint.Create;
      ConfigureFillPaint(FillPaint, AState, True);
      FCanvas.DrawPath(SkPath, FillPaint);
    end;

    TPDFPaintOp.FillAndStroke:
    begin
      SkPath    := BuildSkPath(APath, TSkPathFillType.Winding);
      FillPaint := TSkPaint.Create;
      StrPaint  := TSkPaint.Create;
      ConfigureFillPaint(FillPaint, AState, False);
      ConfigureStrokePaint(StrPaint, AState);
      FCanvas.DrawPath(SkPath, FillPaint);
      FCanvas.DrawPath(SkPath, StrPaint);
    end;

    TPDFPaintOp.FillEvenOddAndStroke:
    begin
      SkPath    := BuildSkPath(APath, TSkPathFillType.EvenOdd);
      FillPaint := TSkPaint.Create;
      StrPaint  := TSkPaint.Create;
      ConfigureFillPaint(FillPaint, AState, True);
      ConfigureStrokePaint(StrPaint, AState);
      FCanvas.DrawPath(SkPath, FillPaint);
      FCanvas.DrawPath(SkPath, StrPaint);
    end;
  end;
end;

// -------------------------------------------------------------------------
procedure TPDFSkiaRenderer.OnPaintGlyph(const AGlyph: TPDFGlyphInfo;
  const AState: TPDFGraphicsState);
var
  Typeface: ISkTypeface;
  Font:     ISkFont;
  Paint:    ISkPaint;
  Unicode:  string;
  Mode:     TPDFTextRenderMode;
begin
  Mode := AState.Text.RenderMode;
  if Mode = TPDFTextRenderMode.Invisible then Exit;

  // Embedded font program: draw the glyph outline itself
  var PDFFont := AState.Text.Font;
  if (PDFFont <> nil) and (PDFFont.FontProgram <> nil) then
  begin
    var GID := PDFFont.GlyphID(AGlyph.CharCode);
    if GID >= 0 then
      PaintGlyphPath(FFontCache.GetGlyphPath(PDFFont, GID), AGlyph, AState);
    Exit;
  end;

  Unicode := AGlyph.Unicode;
  if Unicode = '' then Exit;   // no mapping available — skip

  Typeface := FFontCache.GetTypeface(AState.Text.Font);
  // Characters the substitute lacks (Greek of Symbol, dingbats...) come
  // from another system font
  var CP := Ord(Unicode[1]);
  if (Length(Unicode) >= 2) and Unicode[1].IsHighSurrogate then
    CP := Char.ConvertToUtf32(Unicode, 0);
  var Probe: ISkFont := TSkFont.Create(Typeface, 1, 1, 0);
  if Probe.UnicharToGlyph(CP) = 0 then
  begin
    var FB := FFontCache.FallbackFor(CP);
    if FB <> nil then Typeface := FB;
  end;
  // Font size = 1.0 because all scaling is in the GlyphMatrix
  Font     := TSkFont.Create(Typeface, 1.0, 1.0, 0);
  Font.Subpixel := FOptions.SubpixelText;
  // size 1 with the scale in the matrix: hinting at 1 px distorts the glyphs
  Font.Hinting := TSkFontHinting.None;
  Font.LinearMetrics := True;
  if FOptions.Antialias then
    Font.Edging := TSkFontEdging.AntiAlias
  else
    Font.Edging := TSkFontEdging.Alias;

  FCanvas.SetMatrix(TextMatrix(AGlyph.GlyphMatrix));

  // For clip-variant modes: accumulate glyph outlines in device space for ET
  if Mode in [TPDFTextRenderMode.FillAndClip, TPDFTextRenderMode.StrokeAndClip,
              TPDFTextRenderMode.FillStrokeClip, TPDFTextRenderMode.Clip] then
  begin
    var Glyphs := Font.GetGlyphs(Unicode);
    if FTextClipBuilder = nil then
      FTextClipBuilder := TSkPathBuilder.Create;
    var DevMat := FCanvas.GetLocalToDeviceAs3x3;
    for var G in Glyphs do
    begin
      var P := Font.GetPath(G);
      if P <> nil then
        FTextClipBuilder.AddPath(P.Transform(DevMat));
    end;
  end;

  case Mode of
    TPDFTextRenderMode.Fill,
    TPDFTextRenderMode.FillAndClip:
    begin
      Paint := TSkPaint.Create;
      Paint.Style     := TSkPaintStyle.Fill;
      Paint.Color     := PDFColorToAlpha(AState.FillColor, AState.FillAlpha);
      Paint.AntiAlias := FOptions.Antialias;
      Paint.Blender   := TSkBlender.MakeMode(PDFBlendToSkia(AState.BlendMode));
      FCanvas.DrawSimpleText(Unicode, 0, 0, Font, Paint);
    end;

    TPDFTextRenderMode.Stroke,
    TPDFTextRenderMode.StrokeAndClip:
    begin
      Paint := TSkPaint.Create;
      Paint.Style       := TSkPaintStyle.Stroke;
      Paint.Color       := PDFColorToAlpha(AState.StrokeColor, AState.StrokeAlpha);
      Paint.AntiAlias   := FOptions.Antialias;
      Paint.StrokeWidth := AState.LineWidth;
      Paint.Blender     := TSkBlender.MakeMode(PDFBlendToSkia(AState.BlendMode));
      FCanvas.DrawSimpleText(Unicode, 0, 0, Font, Paint);
    end;

    TPDFTextRenderMode.FillThenStroke,
    TPDFTextRenderMode.FillStrokeClip:
    begin
      Paint := TSkPaint.Create;
      Paint.Style     := TSkPaintStyle.Fill;
      Paint.Color     := PDFColorToAlpha(AState.FillColor, AState.FillAlpha);
      Paint.AntiAlias := FOptions.Antialias;
      Paint.Blender   := TSkBlender.MakeMode(PDFBlendToSkia(AState.BlendMode));
      FCanvas.DrawSimpleText(Unicode, 0, 0, Font, Paint);

      Paint := TSkPaint.Create;
      Paint.Style       := TSkPaintStyle.Stroke;
      Paint.Color       := PDFColorToAlpha(AState.StrokeColor, AState.StrokeAlpha);
      Paint.AntiAlias   := FOptions.Antialias;
      Paint.StrokeWidth := AState.LineWidth;
      Paint.Blender     := TSkBlender.MakeMode(PDFBlendToSkia(AState.BlendMode));
      FCanvas.DrawSimpleText(Unicode, 0, 0, Font, Paint);
    end;

    TPDFTextRenderMode.Clip: ; // path-only clip — outline accumulated above, applied at ET
  end;
end;

// -------------------------------------------------------------------------
// Fills / strokes / clips a glyph outline of an embedded font program. The
// path is in text space (1 unit = 1 em), placed by the glyph matrix.
procedure TPDFSkiaRenderer.PaintGlyphPath(const APath: ISkPath;
  const AGlyph: TPDFGlyphInfo; const AState: TPDFGraphicsState);
var
  Paint: ISkPaint;
  Mode:  TPDFTextRenderMode;

  procedure Fill;
  begin
    Paint := TSkPaint.Create;
    Paint.Style     := TSkPaintStyle.Fill;
    Paint.Color     := PDFColorToAlpha(AState.FillColor, AState.FillAlpha);
    Paint.AntiAlias := FOptions.Antialias;
    Paint.Blender   := TSkBlender.MakeMode(PDFBlendToSkia(AState.BlendMode));
    FCanvas.DrawPath(APath, Paint);
  end;

  procedure Stroke;
  begin
    // the line width is in user space; the canvas is in text space
    var GM := AGlyph.GlyphMatrix;
    var CM := AState.CTM;
    var DetT := Abs(GM.A * GM.D - GM.B * GM.C);
    var DetU := Abs(CM.A * CM.D - CM.B * CM.C);
    var Scale: Single := 1;
    if (DetT > 0) and (DetU > 0) then Scale := Sqrt(DetT / DetU);
    Paint := TSkPaint.Create;
    Paint.Style       := TSkPaintStyle.Stroke;
    Paint.Color       := PDFColorToAlpha(AState.StrokeColor, AState.StrokeAlpha);
    Paint.AntiAlias   := FOptions.Antialias;
    Paint.StrokeWidth := Max(AState.LineWidth, 0) / Scale;
    Paint.Blender     := TSkBlender.MakeMode(PDFBlendToSkia(AState.BlendMode));
    FCanvas.DrawPath(APath, Paint);
  end;

begin
  if APath = nil then Exit;          // empty glyph (space)
  Mode := AState.Text.RenderMode;
  FCanvas.SetMatrix(TextMatrix(AGlyph.GlyphMatrix));

  if Mode in [TPDFTextRenderMode.FillAndClip, TPDFTextRenderMode.StrokeAndClip,
              TPDFTextRenderMode.FillStrokeClip, TPDFTextRenderMode.Clip] then
  begin
    if FTextClipBuilder = nil then
      FTextClipBuilder := TSkPathBuilder.Create;
    FTextClipBuilder.AddPath(APath.Transform(FCanvas.GetLocalToDeviceAs3x3));
  end;

  case Mode of
    TPDFTextRenderMode.Fill, TPDFTextRenderMode.FillAndClip: Fill;
    TPDFTextRenderMode.Stroke, TPDFTextRenderMode.StrokeAndClip: Stroke;
    TPDFTextRenderMode.FillThenStroke, TPDFTextRenderMode.FillStrokeClip:
    begin
      Fill;
      Stroke;
    end;
  end;
end;

// -------------------------------------------------------------------------
procedure TPDFSkiaRenderer.OnPaintXObject(const AName: string;
  const AMatrix: TPDFMatrix; const AState: TPDFGraphicsState);
var
  XStream:  TPDFStream;
  SubType:  string;
  PDFImage: TPDFImage;
  CanvasMat: TMatrix;
begin
  // names are resolved in the current resources (those of the form being
  // drawn, if any): a form may reuse a page name for another object
  if FCurrentResources <> nil then
    XStream := FCurrentResources.GetXObject(AName)
  else
    XStream := nil;
  if XStream = nil then Exit;

  SubType := XStream.Dict.GetAsName('Subtype');

  if SubType = 'Image' then
  begin
    PDFImage := nil;
    try
      PDFImage := TPDFImage.FromXObject(XStream, FPage.Document.Resolver);
      PDFImage.Decode;
      CanvasMat := ImageMatrix(AMatrix);
      DrawPDFImage(PDFImage, CanvasMat, AState);
    finally
      PDFImage.Free;
    end;
  end
  else if SubType = 'Form' then
  begin
    RenderFormXObject(XStream, AMatrix, AState);
  end;
end;

// -------------------------------------------------------------------------
procedure TPDFSkiaRenderer.OnPaintInlineImage(
  const AImageDict: TPDFDictionary; const AImageData: TBytes;
  const AState: TPDFGraphicsState);
var
  PDFImage: TPDFImage;
  CanvasMat: TMatrix;
begin
  PDFImage := nil;
  try
    PDFImage := TPDFImage.FromInline(AImageDict, AImageData);
    PDFImage.Decode;
    CanvasMat := ImageMatrix(AState.CTM);
    DrawPDFImage(PDFImage, CanvasMat, AState);
  finally
    PDFImage.Free;
  end;
end;

// =========================================================================
// Image rendering
// =========================================================================

// Sampling for an image drawn into the unit square by ACanvasMatrix. A scan
// shown smaller than its resolution is averaged through mipmaps (nearest
// neighbour drops whole rows of a 300 dpi fax page); a magnified image is
// interpolated bilinearly, as MuPDF does.
function TPDFSkiaRenderer.ImageSampling(AImage: TPDFImage;
  const ACanvasMatrix: TMatrix): TSkSamplingOptions;
begin
  if not FOptions.Antialias then
    Exit(TSkSamplingOptions.Create(TSkFilterMode.Nearest, TSkMipmapMode.None));
  // device pixels per image pixel along each image axis
  var SX := Sqrt(Sqr(ACanvasMatrix.m11) + Sqr(ACanvasMatrix.m12)) / AImage.Width;
  var SY := Sqrt(Sqr(ACanvasMatrix.m21) + Sqr(ACanvasMatrix.m22)) / AImage.Height;
  if Min(SX, SY) < 1 then
    Result := TSkSamplingOptions.Create(TSkFilterMode.Linear, TSkMipmapMode.Linear)
  else
    Result := TSkSamplingOptions.Create(TSkFilterMode.Linear, TSkMipmapMode.None);
end;

procedure TPDFSkiaRenderer.DrawPDFImage(AImage: TPDFImage;
  const ACanvasMatrix: TMatrix; const AState: TPDFGraphicsState);
var
  SkImg:   ISkImage;
  ImgInfo: TSkImageInfo;
  RGBA:    TBytes;
  Paint:   ISkPaint;
begin
  if (AImage.Width <= 0) or (AImage.Height <= 0) then Exit;

  SkImg := nil;

  // A JPEG soft mask is decoded here (the core has no JPEG decoder)
  if (AImage.SMask <> nil) and AImage.SMask.IsJPEG then
  begin
    var MaskImg := TSkImage.MakeFromEncoded(AImage.SMask.Samples);
    if (MaskImg <> nil) and (MaskImg.Width = AImage.SMask.Width) and
       (MaskImg.Height = AImage.SMask.Height) then
    begin
      var MW := MaskImg.Width;
      var MH := MaskImg.Height;
      var Px: TBytes;
      SetLength(Px, MW * MH * 4);
      if MaskImg.ReadPixels(TSkImageInfo.Create(MW, MH, TSkColorType.RGBA8888,
           TSkAlphaType.Unpremul), @Px[0], NativeUInt(MW) * 4) then
      begin
        var Gray: TBytes;
        SetLength(Gray, MW * MH);
        for var I := 0 to MW * MH - 1 do
          Gray[I] := Px[I * 4];
        AImage.SMask.SetDecodedGray(Gray);
      end;
    end;
  end;

  if AImage.IsJPEG then
  begin
    var Samples := AImage.Samples;
    if Length(Samples) > 0 then
    begin
      var JpegImg := TSkImage.MakeFromEncoded(Samples);
      if (JpegImg <> nil) and (AImage.SMask <> nil) then
      begin
        // JPEG + soft-mask: decode JPEG pixels via ReadPixels, then bake SMask into alpha.
        var W := AImage.Width;
        var H := AImage.Height;
        var ReadInfo := TSkImageInfo.Create(W, H, TSkColorType.RGBA8888, TSkAlphaType.Unpremul);
        SetLength(RGBA, W * H * 4);
        var Alpha: TBytes;
        if JpegImg.ReadPixels(ReadInfo, @RGBA[0], NativeUInt(W) * 4) and
           AImage.MaskAlpha(W, H, Alpha) then
        begin
          for var I := 0 to W * H - 1 do
            RGBA[I*4+3] := Alpha[I];
          ImgInfo := TSkImageInfo.Create(W, H, TSkColorType.RGBA8888, TSkAlphaType.Unpremul);
          SkImg := TSkImage.MakeFromRaster(ImgInfo, @RGBA[0], NativeUInt(W) * 4);
        end
        else
          SkImg := JpegImg; // ReadPixels failed — render opaque
      end
      else
        SkImg := JpegImg;
    end;
  end
  else
  begin
    // Raw pixels: ToRGBA already applies SMask into the alpha channel;
    // image masks are stencils painted with the fill colour
    if AImage.Info.IsImageMask then
    begin
      var C := TAlphaColorRec(PDFColorToAlpha(AState.FillColor, AState.FillAlpha));
      RGBA := AImage.ToStencilRGBA(C.R, C.G, C.B, C.A);
    end
    else
      RGBA := AImage.ToRGBA;
    if Length(RGBA) > 0 then
    begin
      ImgInfo := TSkImageInfo.Create(AImage.Width, AImage.Height,
                   TSkColorType.RGBA8888, TSkAlphaType.Unpremul);
      SkImg   := TSkImage.MakeFromRaster(ImgInfo, @RGBA[0],
                   NativeUInt(AImage.Width) * 4);
    end;
  end;

  if SkImg = nil then Exit;

  Paint := TSkPaint.Create;
  Paint.AntiAlias := FOptions.Antialias;

  FCanvas.SetMatrix(ACanvasMatrix);
  // Draw into the unit square [0,0]-[1,1]; ImageMatrix already corrects Y-flip
  FCanvas.DrawImageRect(SkImg, TRectF.Create(0, 0, 1, 1),
    ImageSampling(AImage, ACanvasMatrix), Paint, TSkSrcRectConstraint.Fast);
end;

// =========================================================================
// Shading / pattern helpers
// =========================================================================

function TPDFSkiaRenderer.EvalPDFFunction(AFunc: TPDFObject;
  T: Single): TArray<Single>;
var
  Dict:    TPDFDictionary;
  FuncType: Integer;
  N:       Double;
  C0Arr, C1Arr: TPDFArray;
  NOut, I: Integer;
  TN:      Single;
  BoundsArr, EncodeArr, FuncsArr: TPDFArray;
  NFunc, FuncIdx: Integer;
  FD0, FD1, E0, E1: Single;
  DomainArr: TPDFArray;
begin
  Result := nil;
  if AFunc = nil then Exit;
  if AFunc.IsStream then
    Dict := TPDFStream(AFunc).Dict
  else if AFunc.IsDictionary then
    Dict := TPDFDictionary(AFunc)
  else
    Exit;

  FuncType := Dict.GetAsInteger('FunctionType', -1);

  case FuncType of
    2: // Exponential interpolation: f(t) = C0 + t^N * (C1 - C0)
    begin
      N     := Dict.GetAsReal('N', 1);
      C0Arr := Dict.GetAsArray('C0');
      C1Arr := Dict.GetAsArray('C1');
      NOut  := 3; // default DeviceRGB
      if C0Arr <> nil then NOut := C0Arr.Count;
      SetLength(Result, NOut);
      if N = 1 then TN := T
      else TN := Single(Power(T, N));
      for I := 0 to NOut - 1 do
      begin
        var C0v: Single := 0;
        var C1v: Single := 1;
        if C0Arr <> nil then C0v := C0Arr.GetAsReal(I, 0);
        if C1Arr <> nil then C1v := C1Arr.GetAsReal(I, 1);
        Result[I] := C0v + TN * (C1v - C0v);
      end;
    end;

    3: // Stitching: composed sub-functions
    begin
      FuncsArr  := Dict.GetAsArray('Functions');
      BoundsArr := Dict.GetAsArray('Bounds');
      EncodeArr := Dict.GetAsArray('Encode');
      if (FuncsArr = nil) or (FuncsArr.Count = 0) then Exit;
      NFunc := FuncsArr.Count;

      DomainArr := Dict.GetAsArray('Domain');
      var D0: Single := 0;
      var D1: Single := 1;
      if DomainArr <> nil then
      begin
        D0 := DomainArr.GetAsReal(0, 0);
        D1 := DomainArr.GetAsReal(1, 1);
      end;
      T := Max(D0, Min(D1, T));

      // Find which sub-function t falls in
      FuncIdx := NFunc - 1;
      FD0     := D0;
      FD1     := D1;
      if NFunc = 1 then begin FD0 := D0; FD1 := D1; end
      else
      begin
        for I := 0 to NFunc - 2 do
        begin
          var Bi: Single := 0;
          if BoundsArr <> nil then Bi := BoundsArr.GetAsReal(I, 0);
          if T <= Bi then
          begin
            FuncIdx := I;
            if I = 0 then FD0 := D0
            else FD0 := Single(BoundsArr.GetAsReal(I - 1, 0));
            FD1 := Bi;
            Break;
          end;
          if I = NFunc - 2 then // last interval: Bounds[N-2] .. D1
          begin
            FD0 := Bi;
            FD1 := D1;
          end;
        end;
      end;

      // Map t into sub-function domain via Encode
      E0 := 0; E1 := 1;
      if EncodeArr <> nil then
      begin
        E0 := EncodeArr.GetAsReal(FuncIdx * 2,     0);
        E1 := EncodeArr.GetAsReal(FuncIdx * 2 + 1, 1);
      end;
      if FD1 > FD0 then
        T := E0 + (T - FD0) / (FD1 - FD0) * (E1 - E0)
      else
        T := E0;

      Result := EvalPDFFunction(FuncsArr.Get(FuncIdx), T);
    end;
  else
  begin
    // Unsupported / unknown — return black DeviceRGB
    SetLength(Result, 3);
    Result[0] := 0; Result[1] := 0; Result[2] := 0;
  end;
  end;
end;

// -------------------------------------------------------------------------

function TPDFSkiaRenderer.ShadingComponentsToAlpha(const AComps: TArray<Single>;
  const ACSName: string): TAlphaColor;
var
  R, G, B, Gv, C, M, Y, K: Single;
begin
  if ACSName = 'DeviceGray' then
  begin
    Gv := EnsureRange(AComps[0], 0, 1);
    Result := (Cardinal($FF) shl 24) or (Round(Gv*255) shl 16) or
              (Round(Gv*255) shl 8) or Round(Gv*255);
  end
  else if ACSName = 'DeviceCMYK' then
  begin
    C := AComps[0]; M := AComps[1]; Y := AComps[2]; K := AComps[3];
    R := EnsureRange((1 - C) * (1 - K), 0, 1);
    G := EnsureRange((1 - M) * (1 - K), 0, 1);
    B := EnsureRange((1 - Y) * (1 - K), 0, 1);
    Result := (Cardinal($FF) shl 24) or (Round(R*255) shl 16) or
              (Round(G*255) shl 8) or Round(B*255);
  end
  else // DeviceRGB (default)
  begin
    if Length(AComps) >= 3 then
    begin
      R := EnsureRange(AComps[0], 0, 1);
      G := EnsureRange(AComps[1], 0, 1);
      B := EnsureRange(AComps[2], 0, 1);
    end else if Length(AComps) = 1 then
    begin
      Gv := EnsureRange(AComps[0], 0, 1);
      R := Gv; G := Gv; B := Gv;
    end else
    begin
      R := 0; G := 0; B := 0;
    end;
    Result := (Cardinal($FF) shl 24) or (Round(R*255) shl 16) or
              (Round(G*255) shl 8) or Round(B*255);
  end;
end;

// -------------------------------------------------------------------------
// Transform a 2-D point by a PDF matrix: x' = A*x+C*y+E, y' = B*x+D*y+F
function PDFTransformPoint(const AP: TPointF; const AM: TPDFMatrix): TPointF; inline;
begin
  Result.X := AM.A * AP.X + AM.C * AP.Y + AM.E;
  Result.Y := AM.B * AP.X + AM.D * AP.Y + AM.F;
end;

function PDFScaleRadius(const AR: Single; const AM: TPDFMatrix): Single; inline;
begin
  // Approximate: use magnitude of x-basis vector for uniform-scale patterns
  Result := AR * Sqrt(AM.A * AM.A + AM.B * AM.B);
end;

// -------------------------------------------------------------------------

function TPDFSkiaRenderer.BuildShadingShader(AShading: TPDFDictionary;
  const APreMatrix: TPDFMatrix): ISkShader;
const
  NGradStops = 16;
var
  ShadingType: Integer;
  CSName:      string;
  FuncObj:     TPDFObject;
  CoordsArr:   TPDFArray;
  Colors:      TArray<TAlphaColor>;
  Positions:   TArray<Single>;
  I:           Integer;
  T:           Single;
  Comps:       TArray<Single>;
begin
  Result := nil;
  if AShading = nil then Exit;

  ShadingType := AShading.GetAsInteger('ShadingType', 0);
  if not (ShadingType in [2, 3]) then Exit;  // only axial and radial implemented

  CSName    := AShading.GetAsName('ColorSpace', 'DeviceRGB');
  FuncObj   := AShading.Get('Function');
  CoordsArr := AShading.GetAsArray('Coords');
  if (CoordsArr = nil) or (FuncObj = nil) then Exit;

  // Build gradient colour stops by sampling the function at NGradStops points
  SetLength(Colors,    NGradStops);
  SetLength(Positions, NGradStops);
  for I := 0 to NGradStops - 1 do
  begin
    T := I / (NGradStops - 1);
    Positions[I] := T;
    Comps := EvalPDFFunction(FuncObj, T);
    if Length(Comps) > 0 then
      Colors[I] := ShadingComponentsToAlpha(Comps, CSName)
    else
      Colors[I] := TAlphaColors.Black;
  end;

  case ShadingType of
    2: // Axial (linear) gradient
    begin
      if CoordsArr.Count < 4 then Exit;
      var P0 := TPointF.Create(CoordsArr.GetAsReal(0, 0), CoordsArr.GetAsReal(1, 0));
      var P1 := TPointF.Create(CoordsArr.GetAsReal(2, 1), CoordsArr.GetAsReal(3, 0));
      // Transform shading coords to canvas user space via APreMatrix
      P0 := PDFTransformPoint(P0, APreMatrix);
      P1 := PDFTransformPoint(P1, APreMatrix);
      Result := TSkShader.MakeGradientLinear(P0, P1, Colors, Positions,
        TSkTileMode.Clamp);
    end;

    3: // Radial (two-point conical) gradient
    begin
      if CoordsArr.Count < 6 then Exit;
      var P0  := TPointF.Create(CoordsArr.GetAsReal(0, 0), CoordsArr.GetAsReal(1, 0));
      var R0  := Single(CoordsArr.GetAsReal(2, 0));
      var P1  := TPointF.Create(CoordsArr.GetAsReal(3, 0), CoordsArr.GetAsReal(4, 0));
      var R1  := Single(CoordsArr.GetAsReal(5, 1));
      P0 := PDFTransformPoint(P0, APreMatrix);
      P1 := PDFTransformPoint(P1, APreMatrix);
      R0 := PDFScaleRadius(R0, APreMatrix);
      R1 := PDFScaleRadius(R1, APreMatrix);
      Result := TSkShader.MakeGradientTwoPointConical(P0, R0, P1, R1,
        Colors, Positions, TSkTileMode.Clamp);
    end;
  end;
end;

// -------------------------------------------------------------------------

function TPDFSkiaRenderer.BuildPatternShader(const APatternName: string;
  const AState: TPDFGraphicsState): ISkShader;
var
  PatObj:     TPDFObject;
  PatDict:    TPDFDictionary;
  PatType:    Integer;
  PatMatrix:  TPDFMatrix;
  ShadingObj: TPDFObject;
  ShadingDict:TPDFDictionary;
begin
  Result := nil;
  if (FCurrentResources = nil) or (APatternName = '') then Exit;
  PatObj := FCurrentResources.GetPattern(APatternName);
  if PatObj = nil then Exit;

  if PatObj.IsDictionary then
    PatDict := TPDFDictionary(PatObj)
  else if PatObj.IsStream then
    PatDict := TPDFStream(PatObj).Dict
  else
    Exit;

  PatType := PatDict.GetAsInteger('PatternType', 0);
  if PatType <> 2 then Exit;  // only shading patterns implemented

  PatMatrix := PatDict.GetMatrix('Matrix');

  // Get the shading dict — may be inline dict or a reference to another dict
  ShadingObj := PatDict.Get('Shading');
  if ShadingObj = nil then Exit;
  if ShadingObj.IsDictionary then
    ShadingDict := TPDFDictionary(ShadingObj)
  else if ShadingObj.IsStream then
    ShadingDict := TPDFStream(ShadingObj).Dict
  else
    Exit;

  Result := BuildShadingShader(ShadingDict, PatMatrix);
end;

// -------------------------------------------------------------------------

procedure TPDFSkiaRenderer.OnPaintShading(const AName: string;
  const AState: TPDFGraphicsState);
var
  ShadingObj:  TPDFObject;
  ShadingDict: TPDFDictionary;
  Shader:      ISkShader;
  Paint:       ISkPaint;
begin
  if FCurrentResources = nil then Exit;
  ShadingObj := FCurrentResources.GetShading(AName);
  if ShadingObj = nil then Exit;

  if ShadingObj.IsDictionary then
    ShadingDict := TPDFDictionary(ShadingObj)
  else if ShadingObj.IsStream then
    ShadingDict := TPDFStream(ShadingObj).Dict
  else
    Exit;

  // For 'sh', shading coords are in user space (no additional pattern matrix)
  Shader := BuildShadingShader(ShadingDict, TPDFMatrix.Identity);
  if Shader = nil then Exit;

  Paint := TSkPaint.Create;
  Paint.AntiAlias := FOptions.Antialias;
  Paint.Shader    := Shader;
  Paint.Blender   := TSkBlender.MakeMode(PDFBlendToSkia(AState.BlendMode));

  // Set canvas matrix to CTM * page-flip so shader coords align with user space
  FCanvas.SetMatrix(PDFMatrixToSkia(AState.CTM) * FPageFlip);
  // Fill the entire clipping region with the shading
  FCanvas.DrawRect(TRectF.Create(-1e6, -1e6, 1e6, 1e6), Paint);
end;

// =========================================================================
// Form XObject (recursive)
// =========================================================================

procedure TPDFSkiaRenderer.RenderFormXObject(AStream: TPDFStream;
  const APlacementCTM: TPDFMatrix; const AState: TPDFGraphicsState);
var
  FormBytes:  TBytes;
  FormResDict:TPDFDictionary;
  FormMatrix: TPDFMatrix;
  FormRes:    IPDFResources;
  Processor:  TPDFContentStreamProcessor;
  SavedPage:  TPDFPage;
  FormState:  TPDFGraphicsState;
begin
  // cyclic or absurdly deep form nesting would overflow the stack
  if FFormDepth >= MAX_FORM_DEPTH then Exit;
  FormBytes := AStream.DecodedBytes;
  if Length(FormBytes) = 0 then Exit;

  // Optional /Matrix attribute (transform applied before placement CTM)
  FormMatrix := TPDFMatrix.Identity;
  var MatrixArr := AStream.Dict.GetAsArray('Matrix');
  if (MatrixArr <> nil) and (MatrixArr.Count >= 6) then
    FormMatrix := TPDFMatrix.Make(
      MatrixArr.Get(0).AsNumber, MatrixArr.Get(1).AsNumber,
      MatrixArr.Get(2).AsNumber, MatrixArr.Get(3).AsNumber,
      MatrixArr.Get(4).AsNumber, MatrixArr.Get(5).AsNumber);

  // Combined CTM: form matrix * placement CTM
  var CombinedCTM := FormMatrix * APlacementCTM;

  // Form's own resources (fall back to page resources)
  FormResDict := AStream.Dict.GetAsDictionary('Resources');

  // We reuse the page for GetResource lookups; override with form resources
  // This is a simplification: a proper impl would create a new resource wrapper
  FormRes := TPDFPageResources.Create(FPage, FormResDict);

  FCanvas.Save;
  try
    // The /BBox clip is in form space; the painting callbacks set their own
    // matrix from the CTM the form content starts with (CombinedCTM)
    FCanvas.SetMatrix(PDFMatrixToSkia(CombinedCTM) * FPageFlip);

    // Optional /BBox clip
    var BBoxArr := AStream.Dict.GetAsArray('BBox');
    if (BBoxArr <> nil) and (BBoxArr.Count >= 4) then
    begin
      var BBox := TRectF.Create(
        BBoxArr.Get(0).AsNumber, BBoxArr.Get(1).AsNumber,
        BBoxArr.Get(2).AsNumber, BBoxArr.Get(3).AsNumber);
      // Clip to form bounding box (in local form coordinate space)
      var BBoxBuilder: ISkPathBuilder := TSkPathBuilder.Create;
      BBoxBuilder.AddRect(BBox);
      FCanvas.ClipPath(BBoxBuilder.Detach, TSkClipOp.Intersect, False);
    end;

    var SavedClipBuilder := FTextClipBuilder;
    var SavedResources   := FCurrentResources;
    FTextClipBuilder  := nil;
    FCurrentResources := FormRes;
    Processor := TPDFContentStreamProcessor.Create;
    Inc(FFormDepth);
    try
      Processor.OnPaintPath        := OnPaintPath;
      Processor.OnPaintGlyph       := OnPaintGlyph;
      Processor.OnPaintXObject     := OnPaintXObject;
      Processor.OnPaintInlineImage := OnPaintInlineImage;
      Processor.OnSaveRestore      := OnSaveRestore;
      Processor.OnTextBlock        := OnTextBlock;
      Processor.OnPaintShading     := OnPaintShading;
      // the form inherits the graphics state at its Do, in the form's space
      FormState := AState;
      FormState.CTM := CombinedCTM;
      Processor.SetInitialState(FormState);
      Processor.Process(FormBytes, FormRes, FPage.Document.Resolver);
    finally
      Dec(FFormDepth);
      Processor.Free;
      FTextClipBuilder  := SavedClipBuilder;
      FCurrentResources := SavedResources;
    end;
  finally
    FCanvas.Restore;
  end;
end;

// =========================================================================
// RenderPage
// =========================================================================

// PDF user space → render pixels for a page shown with /Rotate ARotation
// (clockwise, a multiple of 90). With u = x - CropBox.LLX, v = y - CropBox.LLY
// and cw x ch the CropBox size, the displayed page coordinates are
//     0: (u, ch - v)    90: (v, u)    180: (cw - u, v)    270: (ch - v, cw - u)
// scaled by (ASX, ASY) — the render size over the displayed page size.
function PageMatrix(const ACrop: TPDFRect; ARotation: Integer; ASX, ASY: Single): TMatrix;
var
  OX, OY, CW, CH: Single;
begin
  OX := ACrop.LLX;
  OY := ACrop.LLY;
  CW := ACrop.Width;
  CH := ACrop.Height;
  Result := TMatrix.Identity;
  case ARotation of
    90:
    begin
      Result.m11 := 0;    Result.m12 := ASY;
      Result.m21 := ASX;  Result.m22 := 0;
      Result.m31 := -OY * ASX;
      Result.m32 := -OX * ASY;
    end;
    180:
    begin
      Result.m11 := -ASX; Result.m12 := 0;
      Result.m21 := 0;    Result.m22 := ASY;
      Result.m31 := (CW + OX) * ASX;
      Result.m32 := -OY * ASY;
    end;
    270:
    begin
      Result.m11 := 0;    Result.m12 := -ASY;
      Result.m21 := -ASX; Result.m22 := 0;
      Result.m31 := (CH + OY) * ASX;
      Result.m32 := (CW + OX) * ASY;
    end;
  else
    Result.m11 := ASX;  Result.m12 := 0;
    Result.m21 := 0;    Result.m22 := -ASY;
    Result.m31 := -OX * ASX;
    Result.m32 := (CH + OY) * ASY;
  end;
end;

procedure TPDFSkiaRenderer.RenderPage(APage: TPDFPage; ACanvas: ISkCanvas;
  ARenderWidth, ARenderHeight: Single);
var
  Resources: IPDFResources;
  Processor: TPDFContentStreamProcessor;
  Content:   TBytes;
begin
  // Set up per-render state
  FCanvas  := ACanvas;
  FPage    := APage;
  FPageW   := APage.Width;
  FPageH   := APage.Height;
  FRenderW := ARenderWidth;
  FRenderH := ARenderHeight;
  FScaleX  := ARenderWidth  / Max(FPageW, 1);
  FScaleY  := ARenderHeight / Max(FPageH, 1);
  // the CropBox does not always start at (0, 0)
  var Crop := APage.CropBox.Normalize;

  FPageFlip := PageMatrix(Crop, APage.Rotation, FScaleX, FScaleY);

  // Fill background
  ACanvas.DrawColor(FOptions.BackgroundColor, TSkBlendMode.Src);

  // Decode content stream
  Content := APage.ContentStreamBytes;
  if Length(Content) = 0 then Exit;

  Resources         := TPDFPageResources.Create(APage);
  FCurrentResources := Resources;

  FTextClipBuilder := nil;
  Processor := TPDFContentStreamProcessor.Create;
  try
    Processor.OnPaintPath        := OnPaintPath;
    Processor.OnPaintGlyph       := OnPaintGlyph;
    Processor.OnPaintXObject     := OnPaintXObject;
    Processor.OnPaintInlineImage := OnPaintInlineImage;
    Processor.OnSaveRestore      := OnSaveRestore;
    Processor.OnTextBlock        := OnTextBlock;
    Processor.OnPaintShading     := OnPaintShading;
    Processor.Process(Content, Resources, APage.Document.Resolver);
  finally
    Processor.Free;
    FCurrentResources := nil;
  end;

  // Reset canvas matrix to identity when done
  ACanvas.ResetMatrix;
end;

// =========================================================================
// RenderPageToImage
// =========================================================================

function TPDFSkiaRenderer.RenderPageToImage(APage: TPDFPage;
  ARenderWidth, ARenderHeight: Integer): ISkImage;
var
  Surface: ISkSurface;
  Info:    TSkImageInfo;
begin
  Info    := TSkImageInfo.Create(ARenderWidth, ARenderHeight,
               TSkColorType.BGRA8888, TSkAlphaType.Premul);
  Surface := TSkSurface.MakeRaster(Info);
  if Surface = nil then
    raise EPDFRenderError.Create('Failed to create Skia surface');

  RenderPage(APage, Surface.Canvas, ARenderWidth, ARenderHeight);
  Result := Surface.MakeImageSnapshot;
end;

// =========================================================================
// RenderPageToPng
// =========================================================================

function TPDFSkiaRenderer.RenderPageToPng(APage: TPDFPage;
  ARenderWidth, ARenderHeight: Integer): TBytes;
var
  Img: ISkImage;
begin
  Img    := RenderPageToImage(APage, ARenderWidth, ARenderHeight);
  Result := Img.Encode(TSkEncodedImageFormat.PNG, 100);
end;

// =========================================================================
// RenderPageToJpeg
// =========================================================================

function TPDFSkiaRenderer.RenderPageToJpeg(APage: TPDFPage;
  ARenderWidth, ARenderHeight: Integer; AQuality: Integer): TBytes;
var
  Img: ISkImage;
begin
  Img    := RenderPageToImage(APage, ARenderWidth, ARenderHeight);
  Result := Img.Encode(TSkEncodedImageFormat.JPEG,
              EnsureRange(AQuality, 0, 100));
end;

// =========================================================================
// RenderPageToFile
// =========================================================================

procedure TPDFSkiaRenderer.RenderPageToFile(APage: TPDFPage;
  ARenderWidth, ARenderHeight: Integer; const AFilePath: string);
var
  Img:  ISkImage;
  Ext:  string;
  Fmt:  TSkEncodedImageFormat;
  Qual: Integer;
begin
  Img := RenderPageToImage(APage, ARenderWidth, ARenderHeight);
  Ext := LowerCase(ExtractFileExt(AFilePath));
  if Ext = '.png' then
  begin
    Fmt  := TSkEncodedImageFormat.PNG;
    Qual := 100;
  end
  else
  begin
    Fmt  := TSkEncodedImageFormat.JPEG;
    Qual := 90;
  end;
  Img.EncodeToFile(AFilePath, Fmt, Qual);
end;

end.
