unit uPDF.Viewer.Cache;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.SyncObjs, System.Threading,
  System.Skia,
  uPDF.Document, uPDF.Render.Types, uPDF.Render.Skia;

type
  // -------------------------------------------------------------------------
  // Cached render entry: page index + pixel size → ISkImage
  // -------------------------------------------------------------------------
  TPDFCacheKey = record
    PageIndex:    Integer;
    PixelWidth:   Integer;
    PixelHeight:  Integer;
  end;

  // -------------------------------------------------------------------------
  // Async render request queued for the background thread
  // -------------------------------------------------------------------------
  TPDFRenderRequest = record
    Key: TPDFCacheKey;
  end;

  // -------------------------------------------------------------------------
  // Page render cache
  //
  // Thread-safe: GetPageImage / RequestRender may be called from the main
  // thread while a background TTask renders pages.
  // -------------------------------------------------------------------------
  TPDFPageCache = class
  private
    FDocument:     TPDFDocument;
    FRenderer:     TPDFSkiaRenderer;
    FCache:        TDictionary<string, ISkImage>;
    FLock:         TCriticalSection;
    FPending:      TQueue<TPDFRenderRequest>;
    FPendingLock:  TCriticalSection;
    FTask:         ITask;
    FCancelFlag:   Boolean;
    FOnPageReady:  TProc<Integer>;  // called on main thread after each render

    class function MakeKey(const AKey: TPDFCacheKey): string; static; inline;
    procedure BackgroundLoop;
    procedure ProcessOne(const AReq: TPDFRenderRequest);
    function  IsInQueue(const AKey: TPDFCacheKey): Boolean;

  public
    constructor Create(ADocument: TPDFDocument;
                       const AOptions: TPDFRenderOptions);
    destructor  Destroy; override;

    // Return cached ISkImage for (pageIndex, width, height).
    // Returns nil when not yet rendered; queues a background render.
    function  GetPageImage(AIndex, AWidth, AHeight: Integer): ISkImage;

    // Synchronously render and cache the page (call from main thread when
    // immediate result is acceptable — e.g. printing or export).
    function  RenderSync(AIndex, AWidth, AHeight: Integer): ISkImage;

    // Discard all cached images AND pending queue (e.g. document change).
    procedure InvalidateAll;
    // Discard one page (e.g. after document update).
    procedure InvalidatePage(AIndex: Integer);
    // Clear only the pending render queue; keep cached images as stale fallback.
    procedure ClearPendingQueue;
    // Return any cached image for AIndex regardless of size (stale fallback).
    function  GetStalePageImage(AIndex: Integer): ISkImage;

    // Called on the main thread when a background-rendered page is ready.
    // Typically wired to call Repaint on the viewer control.
    property OnPageReady: TProc<Integer> read FOnPageReady write FOnPageReady;
  end;

implementation

class function TPDFPageCache.MakeKey(const AKey: TPDFCacheKey): string;
begin
  Result := IntToStr(AKey.PageIndex) + '_' +
            IntToStr(AKey.PixelWidth) + 'x' +
            IntToStr(AKey.PixelHeight);
end;

// =========================================================================
// Constructor / destructor
// =========================================================================

constructor TPDFPageCache.Create(ADocument: TPDFDocument;
  const AOptions: TPDFRenderOptions);
begin
  inherited Create;
  FDocument    := ADocument;
  FRenderer    := TPDFSkiaRenderer.Create(AOptions);
  FCache       := TDictionary<string, ISkImage>.Create;
  FLock        := TCriticalSection.Create;
  FPending     := TQueue<TPDFRenderRequest>.Create;
  FPendingLock := TCriticalSection.Create;
  FCancelFlag  := False;

  // Start background render worker
  FTask := TTask.Run(BackgroundLoop);
end;

destructor TPDFPageCache.Destroy;
begin
  // Signal background loop to exit
  FCancelFlag := True;
  if (FTask <> nil) and (FTask.Status <> TTaskStatus.Completed) then
    FTask.Wait(2000);  // up to 2 s

  FPendingLock.Free;
  FPending.Free;
  FLock.Free;
  FCache.Free;
  FRenderer.Free;
  inherited;
end;

// =========================================================================
// Background rendering loop
// =========================================================================

procedure TPDFPageCache.BackgroundLoop;
var
  Req: TPDFRenderRequest;
  HasReq: Boolean;
begin
  while not FCancelFlag do
  begin
    HasReq := False;
    FPendingLock.Enter;
    try
      if FPending.Count > 0 then
      begin
        Req    := FPending.Dequeue;
        HasReq := True;
      end;
    finally
      FPendingLock.Leave;
    end;

    if HasReq then
      ProcessOne(Req)
    else
      Sleep(20);  // idle — wait for new requests
  end;
end;

procedure TPDFPageCache.ProcessOne(const AReq: TPDFRenderRequest);
var
  Key:   string;
  Image: ISkImage;
  Idx:   Integer;
begin
  // Skip if already in cache (may have been rendered by a RenderSync call)
  Key := MakeKey(AReq.Key);
  FLock.Enter;
  try
    if FCache.ContainsKey(Key) then Exit;
  finally
    FLock.Leave;
  end;

  // Guard against invalid page index
  Idx := AReq.Key.PageIndex;
  if (FDocument = nil) or (Idx < 0) or (Idx >= FDocument.PageCount) then Exit;

  try
    Image := FRenderer.RenderPageToImage(
      FDocument.Pages[Idx],
      AReq.Key.PixelWidth,
      AReq.Key.PixelHeight);
  except
    Image := nil;
  end;

  if Image = nil then Exit;

  FLock.Enter;
  try
    // Remove stale images for this page (other zoom levels) before storing new one
    var Prefix := IntToStr(Idx) + '_';
    var OldKeys := FCache.Keys.ToArray;
    for var K in OldKeys do
      if K.StartsWith(Prefix) and (K <> Key) then
        FCache.Remove(K);
    FCache.AddOrSetValue(Key, Image);
  finally
    FLock.Leave;
  end;

  // Notify main thread
  if Assigned(FOnPageReady) then
    TThread.Queue(nil, procedure begin
      if Assigned(FOnPageReady) then
        FOnPageReady(Idx);
    end);
end;

// =========================================================================
// Public API
// =========================================================================

function TPDFPageCache.IsInQueue(const AKey: TPDFCacheKey): Boolean;
var
  R: TPDFRenderRequest;
begin
  Result := False;
  for R in FPending do
    if (R.Key.PageIndex   = AKey.PageIndex) and
       (R.Key.PixelWidth  = AKey.PixelWidth) and
       (R.Key.PixelHeight = AKey.PixelHeight) then
    begin
      Result := True;
      Break;
    end;
end;

function TPDFPageCache.GetPageImage(AIndex, AWidth, AHeight: Integer): ISkImage;
var
  Key: TPDFCacheKey;
  K:   string;
  Req: TPDFRenderRequest;
begin
  Result := nil;
  if (AWidth <= 0) or (AHeight <= 0) then Exit;

  Key.PageIndex   := AIndex;
  Key.PixelWidth  := AWidth;
  Key.PixelHeight := AHeight;
  K := MakeKey(Key);

  FLock.Enter;
  try
    FCache.TryGetValue(K, Result);
  finally
    FLock.Leave;
  end;

  if Result <> nil then Exit;

  // Queue background render (avoid duplicates)
  FPendingLock.Enter;
  try
    if not IsInQueue(Key) then
    begin
      Req.Key := Key;
      FPending.Enqueue(Req);
    end;
  finally
    FPendingLock.Leave;
  end;
end;

function TPDFPageCache.RenderSync(AIndex, AWidth, AHeight: Integer): ISkImage;
var
  Key: TPDFCacheKey;
  K:   string;
begin
  Key.PageIndex   := AIndex;
  Key.PixelWidth  := AWidth;
  Key.PixelHeight := AHeight;
  K := MakeKey(Key);

  // Already cached?
  FLock.Enter;
  try
    if FCache.TryGetValue(K, Result) then Exit;
  finally
    FLock.Leave;
  end;

  try
    Result := FRenderer.RenderPageToImage(
      FDocument.Pages[AIndex], AWidth, AHeight);
  except
    Result := nil;
  end;

  if Result = nil then Exit;

  FLock.Enter;
  try
    FCache.AddOrSetValue(K, Result);
  finally
    FLock.Leave;
  end;
end;

procedure TPDFPageCache.InvalidateAll;
begin
  FLock.Enter;
  try
    FCache.Clear;
  finally
    FLock.Leave;
  end;
  FPendingLock.Enter;
  try
    FPending.Clear;
  finally
    FPendingLock.Leave;
  end;
end;

procedure TPDFPageCache.InvalidatePage(AIndex: Integer);
var
  Keys: TArray<string>;
  K:    string;
begin
  FLock.Enter;
  try
    Keys := FCache.Keys.ToArray;
    for K in Keys do
      if K.StartsWith(IntToStr(AIndex) + '_') then
        FCache.Remove(K);
  finally
    FLock.Leave;
  end;
end;

procedure TPDFPageCache.ClearPendingQueue;
begin
  FPendingLock.Enter;
  try
    FPending.Clear;
  finally
    FPendingLock.Leave;
  end;
end;

function TPDFPageCache.GetStalePageImage(AIndex: Integer): ISkImage;
var
  Prefix: string;
  K:      string;
begin
  Result := nil;
  Prefix := IntToStr(AIndex) + '_';
  FLock.Enter;
  try
    for K in FCache.Keys do
      if K.StartsWith(Prefix) then
      begin
        FCache.TryGetValue(K, Result);
        if Result <> nil then Break;
      end;
  finally
    FLock.Leave;
  end;
end;

end.
