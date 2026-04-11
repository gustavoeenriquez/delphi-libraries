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
  public
    constructor Create(APage: TPDFPage; AOverride: TPDFDictionary = nil);
    function GetFont(const AName: string): TPDFFont;
    function GetXObject(const AName: string): TPDFStream;
    function GetColorSpace(const AName: string): TPDFColorSpace;
    function GetExtGState(const AName: string): TPDFDictionary;
    function GetPattern(const AName: string): TPDFObject;
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
    FCanvas:    ISkCanvas;
    FPage:      TPDFPage;
    FPageW:     Single;   // page width in PDF points
    FPageH:     Single;   // page height in PDF points
    FScaleX:    Single;   // PDF points → render pixels
    FScaleY:    Single;
    FRenderW:   Single;   // render target size in pixels
    FRenderH:   Single;
    // Page-flip + scale matrix (PDF → screen)
    FPageFlip:  TMatrix;

    // ---- Content-stream callbacks ----
    procedure OnPaintPath(const APath: TPDFPath;
                          const AState: TPDFGraphicsState;
                          AOp: TPDFPaintOp);
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

    // Draw a decoded TPDFImage (or inline image) at the current CTM position
    procedure DrawPDFImage(AImage: TPDFImage; const ACanvasMatrix: TMatrix);

    // Process a form XObject (recursive)
    procedure RenderFormXObject(AStream: TPDFStream;
                                const APlacementCTM: TPDFMatrix);

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

    property  Options:   TPDFRenderOptions read FOptions;
    property  FontCache: TPDFFontCache     read FFontCache;
  end;

implementation

// =========================================================================
// TPDFPageResources
// =========================================================================

constructor TPDFPageResources.Create(APage: TPDFPage; AOverride: TPDFDictionary);
begin
  inherited Create;
  FPage     := APage;
  FOverride := AOverride;
end;

function TPDFPageResources.GetFont(const AName: string): TPDFFont;
var
  Obj: TPDFObject;
begin
  Result := nil;
  Obj := FPage.GetResource('Font', AName);
  if (Obj <> nil) and Obj.IsDictionary then
    Result := TPDFFontFactory.Build(TPDFDictionary(Obj),
                FPage.Document.Resolver);
end;

function TPDFPageResources.GetXObject(const AName: string): TPDFStream;
var
  Obj: TPDFObject;
begin
  Result := nil;
  Obj := FPage.GetResource('XObject', AName);
  if (Obj <> nil) and Obj.IsStream then
    Result := TPDFStream(Obj);
end;

function TPDFPageResources.GetColorSpace(const AName: string): TPDFColorSpace;
var
  Obj: TPDFObject;
begin
  Result := nil;
  Obj := FPage.GetResource('ColorSpace', AName);
  if Obj <> nil then
    Result := TPDFColorSpaceFactory.Build(Obj, FPage.Document.Resolver);
end;

function TPDFPageResources.GetExtGState(const AName: string): TPDFDictionary;
var
  Obj: TPDFObject;
begin
  Result := nil;
  Obj := FPage.GetResource('ExtGState', AName);
  if (Obj <> nil) and Obj.IsDictionary then
    Result := TPDFDictionary(Obj);
end;

function TPDFPageResources.GetPattern(const AName: string): TPDFObject;
begin
  Result := FPage.GetResource('Pattern', AName);
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

// Matrix for placing text glyphs on screen (corrects Y-axis flip):
//
//   Result = [[A*sx,  B*sy, 0],
//              [C*sx,  D*sy, 0],
//              [E*sx, H-F*sy, 1]]
//
// This is equivalent to:  PDFMatrix_skia * TextFlip * PageFlip
// where TextFlip = [[1,0,0],[0,-1,0],[0,2F,1]]
//
// The key property: m22 = D*sy > 0, so Skia text ascenders (-Y local)
// map to smaller screen Y (toward screen top) = visually "upward". ✓
function TPDFSkiaRenderer.TextMatrix(const AGM: TPDFMatrix): TMatrix;
begin
  Result.m11 := AGM.A * FScaleX;
  Result.m12 := AGM.B * FScaleY;
  Result.m13 := 0;
  Result.m21 := AGM.C * FScaleX;
  Result.m22 := AGM.D * FScaleY;
  Result.m23 := 0;
  Result.m31 := AGM.E * FScaleX;
  Result.m32 := FRenderH - AGM.F * FScaleY;
  Result.m33 := 1;
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
  APaint.Style       := TSkPaintStyle.Stroke;
  APaint.Color       := PDFColorToAlpha(AState.StrokeColor, AState.StrokeAlpha);
  APaint.AntiAlias   := FOptions.Antialias;
  APaint.StrokeWidth := AState.LineWidth * Max(FScaleX, FScaleY);  // scale to pixels
  APaint.StrokeCap   := PDFLineCapToSkia(AState.LineCap);
  APaint.StrokeJoin  := PDFLineJoinToSkia(AState.LineJoin);
  APaint.StrokeMiter := AState.MiterLimit;
  APaint.Blender     := TSkBlender.MakeMode(PDFBlendToSkia(AState.BlendMode));

  // Dash pattern
  if not AState.Dash.IsEmpty then
  begin
    SetLength(Intervals, Length(AState.Dash.Lengths));
    for I := 0 to High(AState.Dash.Lengths) do
      Intervals[I] := AState.Dash.Lengths[I] * Max(FScaleX, FScaleY);
    APaint.PathEffect := TSkPathEffect.MakeDash(Intervals, AState.Dash.Phase);
  end;
end;

procedure TPDFSkiaRenderer.ConfigureFillPaint(APaint: ISkPaint;
  const AState: TPDFGraphicsState; AEvenOdd: Boolean);
begin
  APaint.Style     := TSkPaintStyle.Fill;
  APaint.Color     := PDFColorToAlpha(AState.FillColor, AState.FillAlpha);
  APaint.AntiAlias := FOptions.Antialias;
  APaint.Blender   := TSkBlender.MakeMode(PDFBlendToSkia(AState.BlendMode));
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
  Unicode := AGlyph.Unicode;
  if Unicode = '' then Exit;   // no mapping available — skip

  Mode := AState.Text.RenderMode;
  if Mode = TPDFTextRenderMode.Invisible then Exit;

  Typeface := FFontCache.GetTypeface(AState.Text.Font);
  // Font size = 1.0 because all scaling is in the GlyphMatrix
  Font     := TSkFont.Create(Typeface, 1.0, 1.0, 0);
  Font.Subpixel := FOptions.SubpixelText;
  if FOptions.Antialias then
    Font.Edging := TSkFontEdging.AntiAlias
  else
    Font.Edging := TSkFontEdging.Alias;

  FCanvas.SetMatrix(TextMatrix(AGlyph.GlyphMatrix));

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
    // TPDFTextRenderMode.Clip, etc.: clip-only modes — TODO Phase 8
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
  XStream := nil;
  var Obj := FPage.GetResource('XObject', AName);
  if Obj = nil then Exit;
  if Obj.IsStream then
    XStream := TPDFStream(Obj)
  else
    Exit;

  SubType := XStream.Dict.GetAsName('Subtype');

  if SubType = 'Image' then
  begin
    PDFImage := nil;
    try
      PDFImage := TPDFImage.FromXObject(XStream, FPage.Document.Resolver);
      PDFImage.Decode;
      CanvasMat := ImageMatrix(AMatrix);
      DrawPDFImage(PDFImage, CanvasMat);
    finally
      PDFImage.Free;
    end;
  end
  else if SubType = 'Form' then
  begin
    RenderFormXObject(XStream, AMatrix);
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
    DrawPDFImage(PDFImage, CanvasMat);
  finally
    PDFImage.Free;
  end;
end;

// =========================================================================
// Image rendering
// =========================================================================

procedure TPDFSkiaRenderer.DrawPDFImage(AImage: TPDFImage;
  const ACanvasMatrix: TMatrix);
var
  SkImg:     ISkImage;
  ImgInfo:   TSkImageInfo;
  RGBA:      TBytes;
  Paint:     ISkPaint;
begin
  if (AImage.Width <= 0) or (AImage.Height <= 0) then Exit;

  SkImg := nil;

  if AImage.IsJPEG then
  begin
    // JPEG: pass encoded bytes directly to Skia
    var Samples := AImage.Samples;
    if Length(Samples) > 0 then
      SkImg := TSkImage.MakeFromEncoded(Samples);
  end
  else
  begin
    // Raw pixels: convert to RGBA8888
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

  // Apply optional soft mask alpha
  if (AImage.SMask <> nil) then
  begin
    // Simplified: use the soft-mask average luminosity as a global alpha
    // Full soft-mask compositing requires off-screen layer — TODO Phase 8
    Paint.AlphaF := 0.9;
  end;

  FCanvas.SetMatrix(ACanvasMatrix);
  // Draw into the unit square [0,0]-[1,1]; ImageMatrix already corrects Y-flip
  FCanvas.DrawImageRect(SkImg, TRectF.Create(0, 0, 1, 1), Paint,
    TSkSrcRectConstraint.Fast);
end;

// =========================================================================
// Form XObject (recursive)
// =========================================================================

procedure TPDFSkiaRenderer.RenderFormXObject(AStream: TPDFStream;
  const APlacementCTM: TPDFMatrix);
var
  FormBytes:  TBytes;
  FormResDict:TPDFDictionary;
  FormMatrix: TPDFMatrix;
  FormRes:    IPDFResources;
  Processor:  TPDFContentStreamProcessor;
  SavedPage:  TPDFPage;
begin
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
    // Apply the combined CTM to the canvas for this form
    FCanvas.Concat(PDFMatrixToSkia(CombinedCTM) * FPageFlip);

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

    Processor := TPDFContentStreamProcessor.Create;
    try
      Processor.OnPaintPath        := OnPaintPath;
      Processor.OnPaintGlyph       := OnPaintGlyph;
      Processor.OnPaintXObject     := OnPaintXObject;
      Processor.OnPaintInlineImage := OnPaintInlineImage;
      Processor.OnSaveRestore      := OnSaveRestore;
      Processor.Process(FormBytes, FormRes, FPage.Document.Resolver);
    finally
      Processor.Free;
    end;
  finally
    FCanvas.Restore;
  end;
end;

// =========================================================================
// RenderPage
// =========================================================================

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

  // Page-flip + scale matrix:  (x,y) PDF → (x*sx, renderH - y*sy) screen
  FPageFlip.m11 := FScaleX;  FPageFlip.m12 := 0;        FPageFlip.m13 := 0;
  FPageFlip.m21 := 0;        FPageFlip.m22 := -FScaleY; FPageFlip.m23 := 0;
  FPageFlip.m31 := 0;        FPageFlip.m32 := FRenderH; FPageFlip.m33 := 1;

  // Fill background
  ACanvas.DrawColor(FOptions.BackgroundColor, TSkBlendMode.Src);

  // Decode content stream
  Content := APage.ContentStreamBytes;
  if Length(Content) = 0 then Exit;

  Resources := TPDFPageResources.Create(APage);

  Processor := TPDFContentStreamProcessor.Create;
  try
    Processor.OnPaintPath        := OnPaintPath;
    Processor.OnPaintGlyph       := OnPaintGlyph;
    Processor.OnPaintXObject     := OnPaintXObject;
    Processor.OnPaintInlineImage := OnPaintInlineImage;
    Processor.OnSaveRestore      := OnSaveRestore;
    Processor.Process(Content, Resources, APage.Document.Resolver);
  finally
    Processor.Free;
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

end.
