unit uPDF.Render.Types;

{$SCOPEDENUMS ON}

interface

uses
  System.UITypes;

type
  // -------------------------------------------------------------------------
  // Render options passed to TPDFSkiaRenderer
  // -------------------------------------------------------------------------
  TPDFRenderOptions = record
    DPI:             Single;           // target resolution (default 96)
    BackgroundColor: TAlphaColor;      // page background (default white)
    Antialias:       Boolean;          // enable antialiasing (default true)
    RenderAnnotations: Boolean;        // render annotation overlays (default false)
    SubpixelText:    Boolean;          // LCD subpixel rendering (default false)

    class function Default: TPDFRenderOptions; static;
    class function ForScreen: TPDFRenderOptions; static;   // 96 DPI
    class function ForPrint(ADPI: Single = 300): TPDFRenderOptions; static;
  end;

implementation

class function TPDFRenderOptions.Default: TPDFRenderOptions;
begin
  Result.DPI              := 96;
  Result.BackgroundColor  := TAlphaColors.White;
  Result.Antialias        := True;
  Result.RenderAnnotations:= False;
  Result.SubpixelText     := False;
end;

class function TPDFRenderOptions.ForScreen: TPDFRenderOptions;
begin
  Result := Default;
end;

class function TPDFRenderOptions.ForPrint(ADPI: Single): TPDFRenderOptions;
begin
  Result := Default;
  Result.DPI         := ADPI;
  Result.SubpixelText:= False;
end;

end.
