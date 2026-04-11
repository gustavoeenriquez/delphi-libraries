unit uPDF.Viewer.Control;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Math,
  FMX.Types, FMX.Controls, FMX.Graphics,
  System.Skia, FMX.Skia,
  uPDF.Document, uPDF.Render.Types, uPDF.Viewer.Cache;

const
  PDF_MIN_ZOOM =  0.1;   // 10 %
  PDF_MAX_ZOOM = 10.0;   // 1000 %
  PDF_ZOOM_STEP = 1.2;   // zoom in/out step (×1.2 per wheel click)
  PDF_PAGE_SPACING = 8;  // pixels between pages at Zoom = 1.0

type
  TPDFZoomMode = (
    Custom,     // explicit FZoom value
    FitWidth,   // fill horizontal viewport
    FitPage,    // fit entire page in viewport
    FitHeight   // fill vertical viewport
  );

  // -------------------------------------------------------------------------
  // TPDFViewerControl
  //
  // FMX control that renders a TPDFDocument page-by-page using the Skia
  // renderer.  Supports smooth pan (drag), scroll wheel, and zoom (Ctrl+wheel
  // or ZoomToFit / ZoomToWidth / ZoomToPage).
  //
  // Usage:
  //   Viewer := TPDFViewerControl.Create(Self);
  //   Viewer.Parent := Self;
  //   Viewer.Align  := TAlignLayout.Client;
  //   Viewer.Document := MyDoc;   // opens and shows immediately
  // -------------------------------------------------------------------------
  TPDFViewerControl = class(TSkCustomControl)
  private
    FDocument:     TPDFDocument;
    FCache:        TPDFPageCache;
    FOptions:      TPDFRenderOptions;
    FZoom:         Single;         // screen pixels per PDF point
    FZoomMode:     TPDFZoomMode;
    FMinZoom:      Single;
    FMaxZoom:      Single;
    FScrollOffset: TPointF;        // content pixels scrolled (positive = down/right)
    FPageSpacing:  Single;         // gap between pages in content pixels at Zoom=1
    FPageLayout:   TArray<TRectF>; // page rects in content space (points × Zoom)
    FLayoutDirty:  Boolean;

    // ---- Page background / placeholder colors ----
    FPageShadowColor:  TAlphaColor;
    FPageBGColor:      TAlphaColor;
    FViewerBGColor:    TAlphaColor;

    // ---- Pan state ----
    FIsDragging:   Boolean;
    FDragStart:    TPointF;  // screen pos at mouse-down
    FScrollStart:  TPointF;  // scroll offset at mouse-down

    // ---- Events ----
    FOnPageChanged:  TNotifyEvent;
    FOnZoomChanged:  TNotifyEvent;
    FLastCurrentPage: Integer;

    // ---- Internal helpers ----
    procedure SetDocument(ADoc: TPDFDocument);
    procedure SetZoom(AValue: Single);
    procedure SetScrollOffset(const AValue: TPointF);
    procedure ClampScrollOffset;
    procedure ApplyZoomMode;
    procedure RebuildLayout;
    procedure InvalidateCache;
    procedure OnCachePageReady(APageIndex: Integer);

    function  GetPageCount: Integer;
    function  GetCurrentPage: Integer;
    function  ContentToScreen(const P: TPointF): TPointF; inline;
    function  ScreenToContent(const P: TPointF): TPointF; inline;
    function  TotalContentSize: TSizeF;
    function  ViewportRect: TRectF; inline;

    // Render one page onto ACanvas (AScreenRect is in screen/control coords)
    procedure DrawPage(const ACanvas: ISkCanvas; AIndex: Integer;
                       const AScreenRect: TRectF);
    procedure DrawPageShadow(const ACanvas: ISkCanvas; const ARect: TRectF);
    procedure DrawPagePlaceholder(const ACanvas: ISkCanvas;
                                  const ARect: TRectF; AIndex: Integer);

    // Zoom around a pivot point (in screen coords)
    procedure ZoomAround(ANewZoom: Single; const APivotScreen: TPointF);

    procedure NotifyPageChanged;
    procedure NotifyZoomChanged;

  protected
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF;
                   const AOpacity: Single); override;

    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
                        X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
                      X, Y: Single); override;
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer;
                         var Handled: Boolean); override;
    procedure KeyDown(var Key: Word; var KeyChar: Char;
                      Shift: TShiftState); override;
    procedure Resize; override;

  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;

    // ---- Navigation ----
    procedure GotoPage(AIndex: Integer);
    procedure NextPage;
    procedure PrevPage;

    // ---- Zoom presets ----
    procedure ZoomToFit;
    procedure ZoomToWidth;
    procedure ZoomToActualSize;   // Zoom = 72/96 ≈ 0.75 (one PDF point ≈ 1 CSS pixel)

    // ---- Properties ----
    property Document:     TPDFDocument read FDocument    write SetDocument;
    property Zoom:         Single       read FZoom        write SetZoom;
    property ZoomMode:     TPDFZoomMode read FZoomMode;
    property MinZoom:      Single       read FMinZoom     write FMinZoom;
    property MaxZoom:      Single       read FMaxZoom     write FMaxZoom;
    property PageSpacing:  Single       read FPageSpacing write FPageSpacing;
    property PageCount:    Integer      read GetPageCount;
    property CurrentPage:  Integer      read GetCurrentPage;
    property ScrollOffset: TPointF      read FScrollOffset write SetScrollOffset;
    property RenderOptions: TPDFRenderOptions read FOptions write FOptions;

    property ViewerBGColor:  TAlphaColor read FViewerBGColor  write FViewerBGColor;
    property PageBGColor:    TAlphaColor read FPageBGColor    write FPageBGColor;
    property PageShadowColor:TAlphaColor read FPageShadowColor write FPageShadowColor;

    // ---- Events ----
    property OnPageChanged: TNotifyEvent read FOnPageChanged write FOnPageChanged;
    property OnZoomChanged: TNotifyEvent read FOnZoomChanged write FOnZoomChanged;

  published
    property Align;
    property Anchors;
    property ClipChildren default True;
    property Cursor;
    property Enabled;
    property Height;
    property HitTest default True;
    property Padding;
    property TabStop default True;
    property Visible;
    property Width;
    property OnClick;
    property OnDblClick;
    property OnKeyDown;
    property OnKeyUp;
    property OnMouseDown;
    property OnMouseMove;
    property OnMouseUp;
    property OnMouseWheel;
  end;

implementation

// =========================================================================
// Local helpers
// =========================================================================

function Clamp(const AValue, AMin, AMax: Single): Single; overload; inline;
begin
  Result := Max(AMin, Min(AMax, AValue));
end;

function Clamp(const AValue, AMin, AMax: Integer): Integer; overload; inline;
begin
  if AValue < AMin then Result := AMin
  else if AValue > AMax then Result := AMax
  else Result := AValue;
end;

// =========================================================================
// Constructor / destructor
// =========================================================================

constructor TPDFViewerControl.Create(AOwner: TComponent);
begin
  inherited;
  FZoom         := 1.0;
  FZoomMode     := TPDFZoomMode.FitWidth;
  FMinZoom      := PDF_MIN_ZOOM;
  FMaxZoom      := PDF_MAX_ZOOM;
  FPageSpacing  := PDF_PAGE_SPACING;
  FScrollOffset := TPointF.Zero;
  FLayoutDirty  := True;
  FLastCurrentPage := -1;
  FOptions      := TPDFRenderOptions.Default;

  FViewerBGColor   := $FF606060;  // opaque medium gray
  FPageBGColor     := TAlphaColors.White;
  FPageShadowColor := $70000000;  // 44% translucent black

  ClipChildren  := True;
  HitTest       := True;
  TabStop       := True;
  AutoCapture   := True;
  CanFocus      := True;

  // TSkCustomControl caches the Skia surface by default (DrawCacheKind = Always).
  // That means Repaint() reuses the cached bitmap without calling Draw() again.
  // A PDF viewer has dynamic content (scroll, zoom, async page renders), so we
  // must disable caching so Draw() is always called on every Repaint().
  DrawCacheKind := TSkDrawCacheKind.Never;
end;

destructor TPDFViewerControl.Destroy;
begin
  FCache.Free;
  inherited;
end;

// =========================================================================
// Document management
// =========================================================================

procedure TPDFViewerControl.SetDocument(ADoc: TPDFDocument);
begin
  if FDocument = ADoc then Exit;
  FDocument := ADoc;

  FCache.Free;
  FCache := nil;

  if FDocument <> nil then
  begin
    FCache := TPDFPageCache.Create(FDocument, FOptions);
    FCache.OnPageReady := OnCachePageReady;
  end;

  FScrollOffset := TPointF.Zero;
  FLayoutDirty  := True;
  FLastCurrentPage := -1;

  // Apply zoom mode after layout is calculated
  if FDocument <> nil then
  begin
    RebuildLayout;
    ApplyZoomMode;
  end;

  Repaint;
end;

procedure TPDFViewerControl.OnCachePageReady(APageIndex: Integer);
begin
  // Called on main thread from the background render worker
  Repaint;
end;

procedure TPDFViewerControl.InvalidateCache;
begin
  // Only clear the pending render queue; keep cached images so they can serve
  // as a stale (wrong-zoom) fallback while new renders are in progress.
  if FCache <> nil then
    FCache.ClearPendingQueue;
end;

// =========================================================================
// Layout
// =========================================================================

procedure TPDFViewerControl.RebuildLayout;
var
  I:    Integer;
  Y:    Single;
  PW, PH: Single;
begin
  if (FDocument = nil) or (FDocument.PageCount = 0) then
  begin
    SetLength(FPageLayout, 0);
    FLayoutDirty := False;
    Exit;
  end;

  SetLength(FPageLayout, FDocument.PageCount);
  Y := 0;
  for I := 0 to FDocument.PageCount - 1 do
  begin
    PW := FDocument.Pages[I].Width  * FZoom;
    PH := FDocument.Pages[I].Height * FZoom;
    FPageLayout[I] := TRectF.Create(0, Y, PW, Y + PH);
    Y := Y + PH + FPageSpacing * FZoom;
  end;

  FLayoutDirty := False;
end;

function TPDFViewerControl.TotalContentSize: TSizeF;
var
  Last: TRectF;
begin
  if Length(FPageLayout) = 0 then
    Exit(TSizeF.Create(0, 0));
  Last   := FPageLayout[High(FPageLayout)];
  Result := TSizeF.Create(Last.Right, Last.Bottom);
end;

// =========================================================================
// Coordinate helpers
// =========================================================================

function TPDFViewerControl.ViewportRect: TRectF;
begin
  Result := TRectF.Create(0, 0, Width, Height);
end;

function TPDFViewerControl.ContentToScreen(const P: TPointF): TPointF;
begin
  // Content is centred horizontally when narrower than viewport
  var ContentW := TotalContentSize.Width;
  var OffX: Single;
  if ContentW < Width then
    OffX := (Width - ContentW) / 2
  else
    OffX := 0;
  Result := TPointF.Create(P.X - FScrollOffset.X + OffX,
                            P.Y - FScrollOffset.Y);
end;

function TPDFViewerControl.ScreenToContent(const P: TPointF): TPointF;
begin
  var ContentW := TotalContentSize.Width;
  var OffX: Single;
  if ContentW < Width then
    OffX := (Width - ContentW) / 2
  else
    OffX := 0;
  Result := TPointF.Create(P.X + FScrollOffset.X - OffX,
                            P.Y + FScrollOffset.Y);
end;

// =========================================================================
// Scroll / zoom
// =========================================================================

procedure TPDFViewerControl.ClampScrollOffset;
var
  CS:    TSizeF;
  MaxX, MaxY: Single;
begin
  CS   := TotalContentSize;
  MaxX := Max(0, CS.Width  - Width);
  MaxY := Max(0, CS.Height - Height);
  FScrollOffset.X := Clamp(FScrollOffset.X, 0, MaxX);
  FScrollOffset.Y := Clamp(FScrollOffset.Y, 0, MaxY);
end;

procedure TPDFViewerControl.SetScrollOffset(const AValue: TPointF);
begin
  FScrollOffset := AValue;
  ClampScrollOffset;
  NotifyPageChanged;
  Repaint;
end;

procedure TPDFViewerControl.SetZoom(AValue: Single);
begin
  AValue := Clamp(AValue, FMinZoom, FMaxZoom);
  if SameValue(FZoom, AValue, 1e-4) then Exit;
  FZoom        := AValue;
  FZoomMode    := TPDFZoomMode.Custom;
  FLayoutDirty := True;
  InvalidateCache;
  RebuildLayout;
  ClampScrollOffset;
  NotifyZoomChanged;
  Repaint;
end;

procedure TPDFViewerControl.ZoomAround(ANewZoom: Single;
  const APivotScreen: TPointF);
var
  OldZoom:   Single;
  PivotContent: TPointF;
begin
  ANewZoom := Clamp(ANewZoom, FMinZoom, FMaxZoom);
  if SameValue(FZoom, ANewZoom, 1e-4) then Exit;

  OldZoom      := FZoom;
  PivotContent := ScreenToContent(APivotScreen);

  FZoom        := ANewZoom;
  FZoomMode    := TPDFZoomMode.Custom;
  FLayoutDirty := True;
  InvalidateCache;
  RebuildLayout;

  // Adjust scroll so the content point under the pivot stays fixed
  var NewPivotContent := TPointF.Create(
    PivotContent.X * (ANewZoom / OldZoom),
    PivotContent.Y * (ANewZoom / OldZoom));

  var ContentW := TotalContentSize.Width;
  var OffX: Single;
  if ContentW < Width then
    OffX := (Width - ContentW) / 2
  else
    OffX := 0;

  FScrollOffset.X := NewPivotContent.X - APivotScreen.X + OffX;
  FScrollOffset.Y := NewPivotContent.Y - APivotScreen.Y;

  ClampScrollOffset;
  NotifyZoomChanged;
  Repaint;
end;

// =========================================================================
// Zoom presets
// =========================================================================

procedure TPDFViewerControl.ApplyZoomMode;
begin
  case FZoomMode of
    TPDFZoomMode.FitWidth:  ZoomToWidth;
    TPDFZoomMode.FitPage:   ZoomToFit;
    TPDFZoomMode.FitHeight:
      if (FDocument <> nil) and (FDocument.PageCount > 0) then
      begin
        var Z := Height / FDocument.Pages[0].Height;
        ZoomAround(Z, TPointF.Create(Width / 2, Height / 2));
      end;
  end;
end;

procedure TPDFViewerControl.ZoomToFit;
var
  Z: Single;
begin
  if (FDocument = nil) or (FDocument.PageCount = 0) then Exit;
  var Page := FDocument.Pages[0];
  Z := Min(Width / Max(Page.Width, 1), Height / Max(Page.Height, 1));
  FZoomMode := TPDFZoomMode.FitPage;
  var OldZoom := FZoom;
  FZoom     := Clamp(Z, FMinZoom, FMaxZoom);
  if not SameValue(FZoom, OldZoom, 1e-4) then
  begin
    FLayoutDirty := True;
    InvalidateCache;
    RebuildLayout;
  end;
  FScrollOffset := TPointF.Zero;
  ClampScrollOffset;
  NotifyZoomChanged;
  Repaint;
end;

procedure TPDFViewerControl.ZoomToWidth;
var
  Z: Single;
begin
  if (FDocument = nil) or (FDocument.PageCount = 0) then Exit;
  var MaxW: Single := 1;
  for var I := 0 to FDocument.PageCount - 1 do
    MaxW := Max(MaxW, FDocument.Pages[I].Width);
  Z := Width / MaxW;
  FZoomMode := TPDFZoomMode.FitWidth;
  var OldZoom := FZoom;
  FZoom     := Clamp(Z, FMinZoom, FMaxZoom);
  if not SameValue(FZoom, OldZoom, 1e-4) then
  begin
    FLayoutDirty := True;
    InvalidateCache;
    RebuildLayout;
  end;
  FScrollOffset.X := 0;
  ClampScrollOffset;
  NotifyZoomChanged;
  Repaint;
end;

procedure TPDFViewerControl.ZoomToActualSize;
begin
  // 1 PDF point = 1 screen pixel (72 DPI — "actual size" for 72 DPI displays)
  FZoomMode := TPDFZoomMode.Custom;
  ZoomAround(1.0, TPointF.Create(Width / 2, Height / 2));
end;

// =========================================================================
// Navigation
// =========================================================================

function TPDFViewerControl.GetPageCount: Integer;
begin
  if FDocument <> nil then Result := FDocument.PageCount else Result := 0;
end;

function TPDFViewerControl.GetCurrentPage: Integer;
var
  I:         Integer;
  CenterY:   Single;
  PageScreenY: Single;
  BestDist:  Single;
  Dist:      Single;
begin
  Result := 0;
  if Length(FPageLayout) = 0 then Exit;

  CenterY  := Height / 2;
  BestDist := MaxSingle;

  for I := 0 to High(FPageLayout) do
  begin
    PageScreenY := ContentToScreen(FPageLayout[I].TopLeft).Y +
                   FPageLayout[I].Height / 2;
    Dist := Abs(PageScreenY - CenterY);
    if Dist < BestDist then
    begin
      BestDist := Dist;
      Result   := I;
    end;
  end;
end;

procedure TPDFViewerControl.GotoPage(AIndex: Integer);
var
  Y: Single;
begin
  if Length(FPageLayout) = 0 then Exit;
  AIndex := Clamp(AIndex, 0, High(FPageLayout));
  Y := FPageLayout[AIndex].Top;
  FScrollOffset.Y := Y;
  ClampScrollOffset;
  NotifyPageChanged;
  Repaint;
end;

procedure TPDFViewerControl.NextPage;
begin
  GotoPage(GetCurrentPage + 1);
end;

procedure TPDFViewerControl.PrevPage;
begin
  GotoPage(GetCurrentPage - 1);
end;

// =========================================================================
// Events / notifications
// =========================================================================

procedure TPDFViewerControl.NotifyPageChanged;
var
  Cur: Integer;
begin
  Cur := GetCurrentPage;
  if Cur <> FLastCurrentPage then
  begin
    FLastCurrentPage := Cur;
    if Assigned(FOnPageChanged) then FOnPageChanged(Self);
  end;
end;

procedure TPDFViewerControl.NotifyZoomChanged;
begin
  if Assigned(FOnZoomChanged) then FOnZoomChanged(Self);
end;

// =========================================================================
// Drawing
// =========================================================================

procedure TPDFViewerControl.Draw(const ACanvas: ISkCanvas;
  const ADest: TRectF; const AOpacity: Single);
var
  I:           Integer;
  ScreenRect:  TRectF;
  Visible:     TRectF;
  BgPaint:     ISkPaint;
begin
  // Rebuild layout if dirty (first draw or zoom/document change)
  if FLayoutDirty then RebuildLayout;

  // Fill viewer background
  ACanvas.DrawColor(FViewerBGColor, TSkBlendMode.Src);

  if (FDocument = nil) or (Length(FPageLayout) = 0) then Exit;

  BgPaint := TSkPaint.Create;

  // Draw visible pages
  for I := 0 to High(FPageLayout) do
  begin
    // Compute screen rect for this page
    ScreenRect := TRectF.Create(
      ContentToScreen(FPageLayout[I].TopLeft),
      FPageLayout[I].Width,
      FPageLayout[I].Height);

    // Cull: skip pages not in the viewport
    if not ScreenRect.IntersectsWith(ADest) then Continue;

    DrawPageShadow(ACanvas, ScreenRect);
    DrawPage(ACanvas, I, ScreenRect);
  end;
end;

procedure TPDFViewerControl.DrawPageShadow(const ACanvas: ISkCanvas;
  const ARect: TRectF);
var
  Shadow:  TRectF;
  Paint: ISkPaint;
  Path:  ISkPath;
begin
  const SHADOW_OFFSET = 3;
  const SHADOW_BLUR   = 6;

  Shadow := TRectF.Create(
    ARect.Left   + SHADOW_OFFSET,
    ARect.Top    + SHADOW_OFFSET,
    ARect.Right  + SHADOW_OFFSET,
    ARect.Bottom + SHADOW_OFFSET);

  Paint := TSkPaint.Create;
  Paint.Color      := FPageShadowColor;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, SHADOW_BLUR);

  var BldrI: ISkPathBuilder := TSkPathBuilder.Create;
  BldrI.AddRect(Shadow);
  Path := BldrI.Detach;

  ACanvas.DrawPath(Path, Paint);
end;

procedure TPDFViewerControl.DrawPage(const ACanvas: ISkCanvas; AIndex: Integer;
  const AScreenRect: TRectF);
var
  W, H:  Integer;
  Image: ISkImage;
  Paint: ISkPaint;
begin
  W := Round(FPageLayout[AIndex].Width);
  H := Round(FPageLayout[AIndex].Height);

  if (W <= 0) or (H <= 0) then Exit;

  // Fill page white background first
  Paint := TSkPaint.Create;
  Paint.Color := FPageBGColor;
  ACanvas.DrawRect(AScreenRect, Paint);

  // Try exact-size cached render first
  Image := FCache.GetPageImage(AIndex, W, H);

  // Fall back to any stale image for this page (different zoom, stretched)
  // so the page shows instantly while the correct-size render is in progress.
  if Image = nil then
    Image := FCache.GetStalePageImage(AIndex);

  if Image <> nil then
  begin
    Paint := TSkPaint.Create;
    Paint.AntiAlias := True;
    ACanvas.DrawImageRect(Image, AScreenRect, Paint, TSkSrcRectConstraint.Fast);
  end
  else
    DrawPagePlaceholder(ACanvas, AScreenRect, AIndex);
end;

procedure TPDFViewerControl.DrawPagePlaceholder(const ACanvas: ISkCanvas;
  const ARect: TRectF; AIndex: Integer);
var
  Paint: ISkPaint;
  Font:  ISkFont;
  Text:  string;
  TX, TY: Single;
begin
  // Show page number while rendering
  Paint := TSkPaint.Create;
  Paint.Color := $40808080;  // light gray overlay
  ACanvas.DrawRect(ARect, Paint);

  // Draw page number centered
  Font := TSkFont.Create(TSkTypeface.MakeDefault, 14, 1.0, 0);
  Paint := TSkPaint.Create;
  Paint.Color := $80404040;
  Paint.AntiAlias := True;

  Text := 'Page ' + IntToStr(AIndex + 1);
  TX   := ARect.CenterPoint.X - 40;
  TY   := ARect.CenterPoint.Y;

  ACanvas.DrawSimpleText(Text, TX, TY, Font, Paint);
end;

// =========================================================================
// Mouse / keyboard input
// =========================================================================

procedure TPDFViewerControl.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Single);
begin
  inherited;
  if Button = TMouseButton.mbLeft then
  begin
    FIsDragging  := True;
    FDragStart   := TPointF.Create(X, Y);
    FScrollStart := FScrollOffset;
    SetFocus;
    // FMX routes mouse-move to this control automatically after mouse-down
  end;
end;

procedure TPDFViewerControl.MouseMove(Shift: TShiftState; X, Y: Single);
var
  Delta: TPointF;
begin
  inherited;
  if FIsDragging then
  begin
    Delta.X := FDragStart.X - X;
    Delta.Y := FDragStart.Y - Y;
    SetScrollOffset(TPointF.Create(
      FScrollStart.X + Delta.X,
      FScrollStart.Y + Delta.Y));
  end;
end;

procedure TPDFViewerControl.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Single);
begin
  inherited;
  if FIsDragging then
    FIsDragging := False;
end;

procedure TPDFViewerControl.MouseWheel(Shift: TShiftState;
  WheelDelta: Integer; var Handled: Boolean);
const
  SCROLL_STEP = 60;  // pixels per wheel notch
begin
  inherited;
  Handled := True;

  if ssCtrl in Shift then
  begin
    // Ctrl + wheel → zoom around control centre
    var Factor := Power(PDF_ZOOM_STEP, WheelDelta / 120);
    ZoomAround(FZoom * Factor, TPointF.Create(Width / 2, Height / 2));
  end
  else
  begin
    // Plain wheel → vertical scroll
    var Delta: Single := -WheelDelta / 120 * SCROLL_STEP;
    SetScrollOffset(TPointF.Create(
      FScrollOffset.X,
      FScrollOffset.Y + Delta));
  end;
end;

procedure TPDFViewerControl.KeyDown(var Key: Word; var KeyChar: Char;
  Shift: TShiftState);
const
  vkNext  = 34;  // Page Down
  vkPrior = 33;  // Page Up
  vkEnd   = 35;
  vkHome  = 36;
  vkDown  = 40;
  vkUp    = 38;
  vkAdd   = 107;  // numpad +
  vkSubtract = 109; // numpad -
  vkOemPlus   = 187;
  vkOemMinus  = 189;
begin
  inherited;
  case Key of
    vkNext:  begin NextPage;   Key := 0; end;
    vkPrior: begin PrevPage;   Key := 0; end;
    vkHome:  begin GotoPage(0);                  Key := 0; end;
    vkEnd:   begin GotoPage(GetPageCount - 1);   Key := 0; end;

    vkUp:
    begin
      SetScrollOffset(TPointF.Create(FScrollOffset.X, FScrollOffset.Y - 40));
      Key := 0;
    end;
    vkDown:
    begin
      SetScrollOffset(TPointF.Create(FScrollOffset.X, FScrollOffset.Y + 40));
      Key := 0;
    end;

    vkAdd, vkOemPlus:
    begin
      ZoomAround(FZoom * PDF_ZOOM_STEP,
                 TPointF.Create(Width / 2, Height / 2));
      Key := 0;
    end;
    vkSubtract, vkOemMinus:
    begin
      ZoomAround(FZoom / PDF_ZOOM_STEP,
                 TPointF.Create(Width / 2, Height / 2));
      Key := 0;
    end;
  end;

  // Ctrl+0 → fit page, Ctrl+1 → actual size, Ctrl+2 → fit width
  if ssCtrl in Shift then
    case KeyChar of
      '0': begin ZoomToFit;        KeyChar := #0; end;
      '1': begin ZoomToActualSize; KeyChar := #0; end;
      '2': begin ZoomToWidth;      KeyChar := #0; end;
    end;
end;

procedure TPDFViewerControl.Resize;
begin
  inherited;
  // Reapply zoom mode when control resizes (e.g. FitWidth should re-scale)
  if FZoomMode in [TPDFZoomMode.FitWidth, TPDFZoomMode.FitPage,
                   TPDFZoomMode.FitHeight] then
    ApplyZoomMode
  else
  begin
    if FLayoutDirty then RebuildLayout;
    ClampScrollOffset;
    Repaint;
  end;
end;

end.
