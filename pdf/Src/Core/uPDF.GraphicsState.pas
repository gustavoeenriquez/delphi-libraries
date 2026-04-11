unit uPDF.GraphicsState;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Generics.Collections,
  uPDF.Types, uPDF.Errors, uPDF.Font;

type

  // -------------------------------------------------------------------------
  // Text state (PDF spec Table 104)
  // -------------------------------------------------------------------------
  TPDFTextState = record
    Font:          TPDFFont;   // nil = not set
    FontSize:      Single;
    CharSpacing:   Single;     // Tc
    WordSpacing:   Single;     // Tw
    HorizScaling:  Single;     // Th (percent / 100, default 1.0)
    Leading:       Single;     // Tl
    RenderMode:    TPDFTextRenderMode;
    TextRise:      Single;     // Ts
    TextMatrix:    TPDFMatrix; // Tm  — current text position
    TextLineMatrix:TPDFMatrix; // Tlm — start of current line
    procedure Reset;
  end;

  // -------------------------------------------------------------------------
  // Dash pattern
  // -------------------------------------------------------------------------
  TPDFDashPattern = record
    Lengths: TArray<Single>;
    Phase:   Single;
    function IsEmpty: Boolean; inline;
    class function Solid: TPDFDashPattern; static; inline;
  end;

  // -------------------------------------------------------------------------
  // Soft mask
  // -------------------------------------------------------------------------
  TPDFSoftMaskKind = (None, Alpha, Luminosity);

  TPDFSoftMask = record
    Kind:   TPDFSoftMaskKind;
    // Rendered group image (filled in by renderer)
    // Keeping it as a generic TObject avoids Skia dependency here
    GroupImage: TObject;
    procedure Reset; inline;
  end;

  // -------------------------------------------------------------------------
  // Complete graphics state  (PDF spec Table 52 + Table 57)
  // -------------------------------------------------------------------------
  TPDFGraphicsState = record
    // ---- Device-independent ----
    CTM:               TPDFMatrix;
    StrokeColor:       TPDFColor;
    FillColor:         TPDFColor;
    StrokeColorSpace:  string;  // name of color space
    FillColorSpace:    string;
    LineWidth:         Single;
    LineCap:           TPDFLineCap;
    LineJoin:          TPDFLineJoin;
    MiterLimit:        Single;
    Dash:              TPDFDashPattern;
    RenderingIntent:   TPDFRenderingIntent;
    Flatness:          Single;
    Smoothness:        Single;
    StrokeAlpha:       Single;   // CA
    FillAlpha:         Single;   // ca
    AlphaIsShape:      Boolean;  // AIS
    BlendMode:         TPDFBlendMode;
    SoftMask:          TPDFSoftMask;
    // ---- Text ----
    Text:              TPDFTextState;
    // ---- Clipping ----
    // Clip path is maintained by the renderer; just track the rule here
    ClipRule:          Integer;   // 0=nonzero, 1=evenodd

    procedure Reset;
  end;

  // -------------------------------------------------------------------------
  // Graphics state stack
  // -------------------------------------------------------------------------
  PPDFGraphicsState = ^TPDFGraphicsState;

  TPDFGraphicsStateStack = class
  private
    FStack:   TStack<TPDFGraphicsState>;
    FCurrent: TPDFGraphicsState;
  public
    constructor Create;
    destructor  Destroy; override;

    procedure Push;                    // q — save
    procedure Pop;                     // Q — restore
    function  Current: TPDFGraphicsState; inline;
    function  CurrentRef: PPDFGraphicsState;  // direct mutation
    procedure SetCurrent(const AState: TPDFGraphicsState); inline;
    procedure Reset;
    function  Depth: Integer; inline;
  end;

implementation

// =========================================================================
// TPDFTextState
// =========================================================================

procedure TPDFTextState.Reset;
begin
  Font          := nil;
  FontSize      := 0;
  CharSpacing   := 0;
  WordSpacing   := 0;
  HorizScaling  := 1.0;
  Leading       := 0;
  RenderMode    := TPDFTextRenderMode.Fill;
  TextRise      := 0;
  TextMatrix    := TPDFMatrix.Identity;
  TextLineMatrix:= TPDFMatrix.Identity;
end;

// =========================================================================
// TPDFDashPattern
// =========================================================================

function TPDFDashPattern.IsEmpty: Boolean;
begin
  Result := Length(Lengths) = 0;
end;

class function TPDFDashPattern.Solid: TPDFDashPattern;
begin
  Result.Lengths := nil;
  Result.Phase   := 0;
end;

// =========================================================================
// TPDFSoftMask
// =========================================================================

procedure TPDFSoftMask.Reset;
begin
  Kind       := TPDFSoftMaskKind.None;
  GroupImage := nil;
end;

// =========================================================================
// TPDFGraphicsState
// =========================================================================

procedure TPDFGraphicsState.Reset;
begin
  CTM               := TPDFMatrix.Identity;
  StrokeColor       := TPDFColor.Black;
  FillColor         := TPDFColor.Black;
  StrokeColorSpace  := 'DeviceGray';
  FillColorSpace    := 'DeviceGray';
  LineWidth         := 1.0;
  LineCap           := TPDFLineCap.ButtCap;
  LineJoin          := TPDFLineJoin.MiterJoin;
  MiterLimit        := 10.0;
  Dash              := TPDFDashPattern.Solid;
  RenderingIntent   := TPDFRenderingIntent.RelativeColorimetric;
  Flatness          := 1.0;
  Smoothness        := 0;
  StrokeAlpha       := 1.0;
  FillAlpha         := 1.0;
  AlphaIsShape      := False;
  BlendMode         := TPDFBlendMode.Normal;
  SoftMask.Reset;
  Text.Reset;
  ClipRule          := 0;
end;

// =========================================================================
// TPDFGraphicsStateStack
// =========================================================================

constructor TPDFGraphicsStateStack.Create;
begin
  inherited;
  FStack := TStack<TPDFGraphicsState>.Create;
  FCurrent.Reset;
end;

destructor TPDFGraphicsStateStack.Destroy;
begin
  FStack.Free;
  inherited;
end;

procedure TPDFGraphicsStateStack.Push;
begin
  FStack.Push(FCurrent);
end;

procedure TPDFGraphicsStateStack.Pop;
begin
  if FStack.Count = 0 then
    raise EPDFError.Create('Graphics state stack underflow (unmatched Q)');
  FCurrent := FStack.Pop;
end;

function TPDFGraphicsStateStack.Current: TPDFGraphicsState;
begin
  Result := FCurrent;
end;

function TPDFGraphicsStateStack.CurrentRef: PPDFGraphicsState;
begin
  Result := @FCurrent;
end;

procedure TPDFGraphicsStateStack.SetCurrent(const AState: TPDFGraphicsState);
begin
  FCurrent := AState;
end;

procedure TPDFGraphicsStateStack.Reset;
begin
  FStack.Clear;
  FCurrent.Reset;
end;

function TPDFGraphicsStateStack.Depth: Integer;
begin
  Result := FStack.Count;
end;

end.
