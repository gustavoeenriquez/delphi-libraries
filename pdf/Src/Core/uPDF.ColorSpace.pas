unit uPDF.ColorSpace;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.Math,
  uPDF.Types, uPDF.Errors, uPDF.Objects;

type
  // Forward
  TPDFColorSpace = class;

  // -------------------------------------------------------------------------
  // Color space kinds
  // -------------------------------------------------------------------------
  TPDFColorSpaceKind = (
    DeviceGray,
    DeviceRGB,
    DeviceCMYK,
    CalGray,
    CalRGB,
    Lab,
    ICCBased,
    Indexed,
    Separation,
    DeviceN,
    Pattern
  );

  // -------------------------------------------------------------------------
  // Base color space
  // -------------------------------------------------------------------------
  TPDFColorSpace = class abstract
  public
    function  Kind: TPDFColorSpaceKind; virtual; abstract;
    function  ComponentCount: Integer; virtual; abstract;
    // Convert AComponents (in this color space) to DeviceRGB [0..1]
    procedure ToRGB(const AComponents: TArray<Single>;
      out AR, AG, AB: Single); virtual; abstract;
    // Convert to a TPDFColor record
    function  ToColor(const AComponents: TArray<Single>): TPDFColor;
    // Default color (all zeros, or paper white for some)
    function  DefaultColor: TArray<Single>; virtual;
    // Name for debug
    function  Name: string; virtual; abstract;
  end;

  // -------------------------------------------------------------------------
  // DeviceGray
  // -------------------------------------------------------------------------
  TPDFDeviceGray = class(TPDFColorSpace)
  public
    function  Kind: TPDFColorSpaceKind; override;
    function  ComponentCount: Integer; override;
    procedure ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single); override;
    function  Name: string; override;
  end;

  // -------------------------------------------------------------------------
  // DeviceRGB
  // -------------------------------------------------------------------------
  TPDFDeviceRGB = class(TPDFColorSpace)
  public
    function  Kind: TPDFColorSpaceKind; override;
    function  ComponentCount: Integer; override;
    procedure ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single); override;
    function  Name: string; override;
  end;

  // -------------------------------------------------------------------------
  // DeviceCMYK
  // -------------------------------------------------------------------------
  TPDFDeviceCMYK = class(TPDFColorSpace)
  public
    function  Kind: TPDFColorSpaceKind; override;
    function  ComponentCount: Integer; override;
    procedure ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single); override;
    function  Name: string; override;
    function  DefaultColor: TArray<Single>; override;
  end;

  // -------------------------------------------------------------------------
  // CalGray  (gamma-corrected gray)
  // -------------------------------------------------------------------------
  TPDFCalGray = class(TPDFColorSpace)
  private
    FGamma:     Single;
    FWhiteX, FWhiteY, FWhiteZ: Single;
  public
    constructor Create(AGamma: Single; AWhiteX, AWhiteY, AWhiteZ: Single);
    function  Kind: TPDFColorSpaceKind; override;
    function  ComponentCount: Integer; override;
    procedure ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single); override;
    function  Name: string; override;
  end;

  // -------------------------------------------------------------------------
  // CalRGB  (calibrated RGB)
  // -------------------------------------------------------------------------
  TPDFCalRGB = class(TPDFColorSpace)
  private
    FGamma:     array[0..2] of Single;
    FMatrix:    array[0..8] of Single;  // 3×3 column-major to XYZ
    FWhiteX, FWhiteY, FWhiteZ: Single;
  public
    constructor Create(const AGamma: array of Single;
      const AMatrix: array of Single;
      AWhiteX, AWhiteY, AWhiteZ: Single);
    function  Kind: TPDFColorSpaceKind; override;
    function  ComponentCount: Integer; override;
    procedure ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single); override;
    function  Name: string; override;
  end;

  // -------------------------------------------------------------------------
  // ICCBased  — ICC profile embedded in a stream
  // The actual ICC conversion is handled by Skia in the render tier.
  // Here we store the raw profile bytes and fall back to an alternate space.
  // -------------------------------------------------------------------------
  TPDFICCBased = class(TPDFColorSpace)
  private
    FComponents:    Integer;
    FAlternate:     TPDFColorSpace;  // owns
    FProfileBytes:  TBytes;
  public
    constructor Create(AComponents: Integer; AAlternate: TPDFColorSpace;
      const AProfileBytes: TBytes);
    destructor  Destroy; override;
    function  Kind: TPDFColorSpaceKind; override;
    function  ComponentCount: Integer; override;
    procedure ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single); override;
    function  Name: string; override;
    function  ProfileBytes: TBytes;
    function  Alternate: TPDFColorSpace;
  end;

  // -------------------------------------------------------------------------
  // Indexed  — lookup table into a base color space
  // -------------------------------------------------------------------------
  TPDFIndexed = class(TPDFColorSpace)
  private
    FBase:     TPDFColorSpace;  // owns
    FHiVal:    Integer;         // max valid index (0..255)
    FLookup:   TBytes;          // HiVal+1 entries, each N bytes (N = base components)
  public
    constructor Create(ABase: TPDFColorSpace; AHiVal: Integer; const ALookup: TBytes);
    destructor  Destroy; override;
    function  Kind: TPDFColorSpaceKind; override;
    function  ComponentCount: Integer; override;  // always 1
    procedure ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single); override;
    function  Name: string; override;
  end;

  // -------------------------------------------------------------------------
  // Separation  — named ink (spot color)
  // -------------------------------------------------------------------------
  TPDFSeparation = class(TPDFColorSpace)
  private
    FColorName: string;
    FAlternate: TPDFColorSpace;  // owns
    // Tint transform function is complex; store as raw PDF object for now
    FTintFunction: TPDFObject;   // not owned
  public
    constructor Create(const AColorName: string; AAlternate: TPDFColorSpace;
      ATintFunction: TPDFObject);
    destructor  Destroy; override;
    function  Kind: TPDFColorSpaceKind; override;
    function  ComponentCount: Integer; override;
    procedure ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single); override;
    function  Name: string; override;
    function  ColorName: string; inline;
  end;

  // -------------------------------------------------------------------------
  // DeviceN  — multiple colorants
  // -------------------------------------------------------------------------
  TPDFDeviceN = class(TPDFColorSpace)
  private
    FColorants:   TArray<string>;
    FAlternate:   TPDFColorSpace;  // owns
    FTintFunction: TPDFObject;     // not owned
  public
    constructor Create(const AColorants: TArray<string>;
      AAlternate: TPDFColorSpace; ATintFunction: TPDFObject);
    destructor  Destroy; override;
    function  Kind: TPDFColorSpaceKind; override;
    function  ComponentCount: Integer; override;
    procedure ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single); override;
    function  Name: string; override;
  end;

  // -------------------------------------------------------------------------
  // Color space factory: builds a TPDFColorSpace from a PDF object
  // -------------------------------------------------------------------------
  TPDFColorSpaceFactory = class
  public
    // AObj can be a Name object (e.g. /DeviceRGB) or an Array object
    // AResolver is used to dereference stream objects (for ICCBased)
    class function Build(AObj: TPDFObject;
      AResolver: IObjectResolver = nil): TPDFColorSpace; static;
  private
    class function BuildFromName(const AName: string): TPDFColorSpace; static;
    class function BuildFromArray(AArr: TPDFArray;
      AResolver: IObjectResolver): TPDFColorSpace; static;
  end;

  // -------------------------------------------------------------------------
  // Color space registry: singleton map of name → color space instance
  // (for /Resources /ColorSpace dict lookup)
  // -------------------------------------------------------------------------
  TPDFColorSpaceRegistry = class
  private
    FMap: TObjectDictionary<string, TPDFColorSpace>;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure Register(const AName: string; ACS: TPDFColorSpace);
    function  Lookup(const AName: string): TPDFColorSpace;  // nil if not found
    procedure Clear;
  end;

  // Utility: simple CMYK → sRGB (no ICC)
  procedure CMYKToRGB(C, M, Y, K: Single; out R, G, B: Single);
  // XYZ D65 → sRGB (linearized)
  procedure XYZToSRGB(X, Y, Z: Single; out R, G, B: Single);

implementation

// =========================================================================
// Utility color conversions
// =========================================================================

procedure CMYKToRGB(C, M, Y, K: Single; out R, G, B: Single);
begin
  R := EnsureRange((1 - C) * (1 - K), 0, 1);
  G := EnsureRange((1 - M) * (1 - K), 0, 1);
  B := EnsureRange((1 - Y) * (1 - K), 0, 1);
end;

procedure XYZToSRGB(X, Y, Z: Single; out R, G, B: Single);

  function LinearToSRGB(V: Single): Single; inline;
  begin
    if V <= 0.0031308 then
      Result := 12.92 * V
    else
      Result := 1.055 * Power(V, 1 / 2.4) - 0.055;
  end;

begin
  // D65 reference white, sRGB matrix (IEC 61966-2-1)
  var Rl :=  3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z;
  var Gl := -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z;
  var Bl :=  0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z;
  R := EnsureRange(LinearToSRGB(Rl), 0, 1);
  G := EnsureRange(LinearToSRGB(Gl), 0, 1);
  B := EnsureRange(LinearToSRGB(Bl), 0, 1);
end;

// =========================================================================
// TPDFColorSpace base
// =========================================================================

function TPDFColorSpace.ToColor(const AComponents: TArray<Single>): TPDFColor;
var
  R, G, B: Single;
begin
  ToRGB(AComponents, R, G, B);
  Result       := TPDFColor.MakeRGB(R, G, B);
  Result.Alpha := 1.0;
end;

function TPDFColorSpace.DefaultColor: TArray<Single>;
begin
  SetLength(Result, ComponentCount);
  FillChar(Result[0], Length(Result) * SizeOf(Single), 0);
end;

// =========================================================================
// TPDFDeviceGray
// =========================================================================

function TPDFDeviceGray.Kind: TPDFColorSpaceKind; begin Result := TPDFColorSpaceKind.DeviceGray; end;
function TPDFDeviceGray.ComponentCount: Integer;   begin Result := 1; end;
function TPDFDeviceGray.Name: string;              begin Result := 'DeviceGray'; end;

procedure TPDFDeviceGray.ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single);
begin
  var G := EnsureRange(AComponents[0], 0, 1);
  AR := G; AG := G; AB := G;
end;

// =========================================================================
// TPDFDeviceRGB
// =========================================================================

function TPDFDeviceRGB.Kind: TPDFColorSpaceKind; begin Result := TPDFColorSpaceKind.DeviceRGB; end;
function TPDFDeviceRGB.ComponentCount: Integer;   begin Result := 3; end;
function TPDFDeviceRGB.Name: string;              begin Result := 'DeviceRGB'; end;

procedure TPDFDeviceRGB.ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single);
begin
  AR := EnsureRange(AComponents[0], 0, 1);
  AG := EnsureRange(AComponents[1], 0, 1);
  AB := EnsureRange(AComponents[2], 0, 1);
end;

// =========================================================================
// TPDFDeviceCMYK
// =========================================================================

function TPDFDeviceCMYK.Kind: TPDFColorSpaceKind; begin Result := TPDFColorSpaceKind.DeviceCMYK; end;
function TPDFDeviceCMYK.ComponentCount: Integer;   begin Result := 4; end;
function TPDFDeviceCMYK.Name: string;              begin Result := 'DeviceCMYK'; end;

function TPDFDeviceCMYK.DefaultColor: TArray<Single>;
begin
  // Default CMYK = 0 0 0 1 (black)
  Result := [0, 0, 0, 1];
end;

procedure TPDFDeviceCMYK.ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single);
begin
  CMYKToRGB(AComponents[0], AComponents[1], AComponents[2], AComponents[3], AR, AG, AB);
end;

// =========================================================================
// TPDFCalGray
// =========================================================================

constructor TPDFCalGray.Create(AGamma: Single; AWhiteX, AWhiteY, AWhiteZ: Single);
begin
  inherited Create;
  FGamma  := AGamma;
  FWhiteX := AWhiteX;
  FWhiteY := AWhiteY;
  FWhiteZ := AWhiteZ;
end;

function TPDFCalGray.Kind: TPDFColorSpaceKind; begin Result := TPDFColorSpaceKind.CalGray; end;
function TPDFCalGray.ComponentCount: Integer;   begin Result := 1; end;
function TPDFCalGray.Name: string;              begin Result := 'CalGray'; end;

procedure TPDFCalGray.ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single);
begin
  // A → X = Aw * A^Gamma (using white point)
  var A    := EnsureRange(AComponents[0], 0, 1);
  var AGray := Power(A, FGamma);
  var X    := FWhiteX * AGray;
  var Y    := FWhiteY * AGray;
  var Z    := FWhiteZ * AGray;
  XYZToSRGB(X, Y, Z, AR, AG, AB);
end;

// =========================================================================
// TPDFCalRGB
// =========================================================================

constructor TPDFCalRGB.Create(const AGamma: array of Single;
  const AMatrix: array of Single; AWhiteX, AWhiteY, AWhiteZ: Single);
begin
  inherited Create;
  for var I := 0 to 2 do FGamma[I]  := AGamma[I];
  for var I := 0 to 8 do FMatrix[I] := AMatrix[I];
  FWhiteX := AWhiteX;
  FWhiteY := AWhiteY;
  FWhiteZ := AWhiteZ;
end;

function TPDFCalRGB.Kind: TPDFColorSpaceKind; begin Result := TPDFColorSpaceKind.CalRGB; end;
function TPDFCalRGB.ComponentCount: Integer;   begin Result := 3; end;
function TPDFCalRGB.Name: string;              begin Result := 'CalRGB'; end;

procedure TPDFCalRGB.ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single);
begin
  var R := Power(EnsureRange(AComponents[0], 0, 1), FGamma[0]);
  var G := Power(EnsureRange(AComponents[1], 0, 1), FGamma[1]);
  var B := Power(EnsureRange(AComponents[2], 0, 1), FGamma[2]);
  // Apply matrix to get XYZ
  var X := FMatrix[0]*R + FMatrix[3]*G + FMatrix[6]*B;
  var Y := FMatrix[1]*R + FMatrix[4]*G + FMatrix[7]*B;
  var Z := FMatrix[2]*R + FMatrix[5]*G + FMatrix[8]*B;
  XYZToSRGB(X, Y, Z, AR, AG, AB);
end;

// =========================================================================
// TPDFICCBased
// =========================================================================

constructor TPDFICCBased.Create(AComponents: Integer; AAlternate: TPDFColorSpace;
  const AProfileBytes: TBytes);
begin
  inherited Create;
  FComponents   := AComponents;
  FAlternate    := AAlternate;
  FProfileBytes := AProfileBytes;
end;

destructor TPDFICCBased.Destroy;
begin
  FAlternate.Free;
  inherited;
end;

function TPDFICCBased.Kind: TPDFColorSpaceKind; begin Result := TPDFColorSpaceKind.ICCBased; end;
function TPDFICCBased.ComponentCount: Integer;   begin Result := FComponents; end;
function TPDFICCBased.Name: string;              begin Result := 'ICCBased'; end;
function TPDFICCBased.ProfileBytes: TBytes;      begin Result := FProfileBytes; end;
function TPDFICCBased.Alternate: TPDFColorSpace; begin Result := FAlternate; end;

procedure TPDFICCBased.ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single);
begin
  // Fallback: use alternate color space
  // The Skia render tier overrides this with proper ICC conversion
  if FAlternate <> nil then
    FAlternate.ToRGB(AComponents, AR, AG, AB)
  else
  begin
    case FComponents of
      1: begin AR := AComponents[0]; AG := AR; AB := AR; end;
      3: begin AR := AComponents[0]; AG := AComponents[1]; AB := AComponents[2]; end;
      4: CMYKToRGB(AComponents[0], AComponents[1], AComponents[2], AComponents[3], AR, AG, AB);
    else
      AR := 0; AG := 0; AB := 0;
    end;
  end;
end;

// =========================================================================
// TPDFIndexed
// =========================================================================

constructor TPDFIndexed.Create(ABase: TPDFColorSpace; AHiVal: Integer;
  const ALookup: TBytes);
begin
  inherited Create;
  FBase   := ABase;
  FHiVal  := AHiVal;
  FLookup := ALookup;
end;

destructor TPDFIndexed.Destroy;
begin
  FBase.Free;
  inherited;
end;

function TPDFIndexed.Kind: TPDFColorSpaceKind; begin Result := TPDFColorSpaceKind.Indexed; end;
function TPDFIndexed.ComponentCount: Integer;   begin Result := 1; end;
function TPDFIndexed.Name: string;              begin Result := 'Indexed'; end;

procedure TPDFIndexed.ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single);
begin
  var Idx    := EnsureRange(Round(AComponents[0]), 0, FHiVal);
  var N      := FBase.ComponentCount;
  var Offset := Idx * N;

  if (Offset + N - 1) >= Length(FLookup) then
  begin
    AR := 0; AG := 0; AB := 0;
    Exit;
  end;

  var BaseComps: TArray<Single>;
  SetLength(BaseComps, N);
  for var I := 0 to N - 1 do
    BaseComps[I] := FLookup[Offset + I] / 255.0;

  FBase.ToRGB(BaseComps, AR, AG, AB);
end;

// =========================================================================
// TPDFSeparation
// =========================================================================

constructor TPDFSeparation.Create(const AColorName: string;
  AAlternate: TPDFColorSpace; ATintFunction: TPDFObject);
begin
  inherited Create;
  FColorName     := AColorName;
  FAlternate     := AAlternate;
  FTintFunction  := ATintFunction;
end;

destructor TPDFSeparation.Destroy;
begin
  FAlternate.Free;
  inherited;
end;

function TPDFSeparation.Kind: TPDFColorSpaceKind; begin Result := TPDFColorSpaceKind.Separation; end;
function TPDFSeparation.ComponentCount: Integer;   begin Result := 1; end;
function TPDFSeparation.Name: string;              begin Result := 'Separation'; end;
function TPDFSeparation.ColorName: string;         begin Result := FColorName; end;

procedure TPDFSeparation.ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single);
begin
  // Simplified: map tint directly to alternate space (ignores tint function)
  // Full tint function evaluation requires the function interpreter (Phase 7)
  var Tint := EnsureRange(AComponents[0], 0, 1);

  if (FColorName = 'All') then
  begin
    AR := 1 - Tint; AG := AR; AB := AR;
    Exit;
  end;

  if FAlternate = nil then
  begin
    AR := 1 - Tint; AG := AR; AB := AR;
    Exit;
  end;

  // Map tint to alternate components (linear approximation)
  var AltComps: TArray<Single>;
  SetLength(AltComps, FAlternate.ComponentCount);
  var Default := FAlternate.DefaultColor;
  for var I := 0 to FAlternate.ComponentCount - 1 do
    AltComps[I] := Tint * Default[I];
  FAlternate.ToRGB(AltComps, AR, AG, AB);
end;

// =========================================================================
// TPDFDeviceN
// =========================================================================

constructor TPDFDeviceN.Create(const AColorants: TArray<string>;
  AAlternate: TPDFColorSpace; ATintFunction: TPDFObject);
begin
  inherited Create;
  FColorants    := AColorants;
  FAlternate    := AAlternate;
  FTintFunction := ATintFunction;
end;

destructor TPDFDeviceN.Destroy;
begin
  FAlternate.Free;
  inherited;
end;

function TPDFDeviceN.Kind: TPDFColorSpaceKind; begin Result := TPDFColorSpaceKind.DeviceN; end;
function TPDFDeviceN.ComponentCount: Integer;   begin Result := Length(FColorants); end;
function TPDFDeviceN.Name: string;              begin Result := 'DeviceN'; end;

procedure TPDFDeviceN.ToRGB(const AComponents: TArray<Single>; out AR, AG, AB: Single);
begin
  // Simplified: convert via alternate (ignores tint function)
  if FAlternate = nil then
  begin
    AR := 0; AG := 0; AB := 0;
    Exit;
  end;

  // Use first N components mapped to alternate
  var AltCount := FAlternate.ComponentCount;
  var AltComps: TArray<Single>;
  SetLength(AltComps, AltCount);
  for var I := 0 to Min(AltCount, Length(AComponents)) - 1 do
    AltComps[I] := AComponents[I];
  FAlternate.ToRGB(AltComps, AR, AG, AB);
end;

// =========================================================================
// TPDFColorSpaceFactory
// =========================================================================

class function TPDFColorSpaceFactory.Build(AObj: TPDFObject;
  AResolver: IObjectResolver): TPDFColorSpace;
begin
  if AObj = nil then
    Exit(TPDFDeviceGray.Create);

  var Deref := AObj.Dereference;

  if Deref.IsName then
    Exit(BuildFromName(Deref.AsName));

  if Deref.IsArray then
    Exit(BuildFromArray(TPDFArray(Deref), AResolver));

  Result := TPDFDeviceGray.Create; // fallback
end;

class function TPDFColorSpaceFactory.BuildFromName(const AName: string): TPDFColorSpace;
begin
  if (AName = 'DeviceGray') or (AName = 'G') then Result := TPDFDeviceGray.Create
  else if (AName = 'DeviceRGB')  or (AName = 'RGB') then Result := TPDFDeviceRGB.Create
  else if (AName = 'DeviceCMYK') or (AName = 'CMYK') then Result := TPDFDeviceCMYK.Create
  else if AName = 'Pattern' then Result := TPDFDeviceGray.Create  // stub
  else Result := TPDFDeviceGray.Create;
end;

class function TPDFColorSpaceFactory.BuildFromArray(AArr: TPDFArray;
  AResolver: IObjectResolver): TPDFColorSpace;
var
  TypeName: string;
begin
  if AArr.Count = 0 then
    Exit(TPDFDeviceGray.Create);

  TypeName := AArr.GetAsName(0);

  if TypeName = 'CalGray' then
  begin
    var Params: TPDFDictionary := nil;
    if (AArr.Count > 1) then
      Params := TPDFDictionary(AArr.Get(1));
    var Gamma  := 1.0;
    var Wx := 1.0; var Wy := 1.0; var Wz := 1.0;
    if Params <> nil then
    begin
      Gamma := Params.GetAsReal('Gamma', 1.0);
      var WP := Params.GetAsArray('WhitePoint');
      if (WP <> nil) and (WP.Count >= 3) then
      begin
        Wx := WP.GetAsReal(0, 1.0);
        Wy := WP.GetAsReal(1, 1.0);
        Wz := WP.GetAsReal(2, 1.0);
      end;
    end;
    Exit(TPDFCalGray.Create(Gamma, Wx, Wy, Wz));
  end;

  if TypeName = 'CalRGB' then
  begin
    var Params: TPDFDictionary := nil;
    if (AArr.Count > 1) then
      Params := TPDFDictionary(AArr.Get(1));
    var Gamma: array[0..2] of Single;
    var Matrix: array[0..8] of Single;
    var Wx := 1.0; var Wy := 1.0; var Wz := 1.0;
    Gamma[0] := 1; Gamma[1] := 1; Gamma[2] := 1;
    Matrix[0] := 1; Matrix[1] := 0; Matrix[2] := 0;
    Matrix[3] := 0; Matrix[4] := 1; Matrix[5] := 0;
    Matrix[6] := 0; Matrix[7] := 0; Matrix[8] := 1;
    if Params <> nil then
    begin
      var GA := Params.GetAsArray('Gamma');
      if (GA <> nil) and (GA.Count >= 3) then
        for var I := 0 to 2 do Gamma[I] := GA.GetAsReal(I, 1.0);
      var MA := Params.GetAsArray('Matrix');
      if (MA <> nil) and (MA.Count >= 9) then
        for var I := 0 to 8 do Matrix[I] := MA.GetAsReal(I, 0);
      var WP := Params.GetAsArray('WhitePoint');
      if (WP <> nil) and (WP.Count >= 3) then
      begin
        Wx := WP.GetAsReal(0, 1); Wy := WP.GetAsReal(1, 1); Wz := WP.GetAsReal(2, 1);
      end;
    end;
    Exit(TPDFCalRGB.Create(Gamma, Matrix, Wx, Wy, Wz));
  end;

  if TypeName = 'ICCBased' then
  begin
    var N := 3;
    var Alt: TPDFColorSpace := nil;
    var Profile: TBytes;
    if (AArr.Count > 1) and (AResolver <> nil) then
    begin
      var StmObj := AArr.Get(1);
      if StmObj.IsStream then
      begin
        var Stm := TPDFStream(StmObj);
        N       := Stm.Dict.GetAsInteger('N', 3);
        Profile := Stm.DecodedBytes;
        var AltObj := Stm.Dict.Get('Alternate');
        if AltObj <> nil then
          Alt := Build(AltObj, AResolver);
      end;
    end;
    if Alt = nil then
      case N of
        1: Alt := TPDFDeviceGray.Create;
        3: Alt := TPDFDeviceRGB.Create;
        4: Alt := TPDFDeviceCMYK.Create;
      else
        Alt := TPDFDeviceRGB.Create;
      end;
    Exit(TPDFICCBased.Create(N, Alt, Profile));
  end;

  if TypeName = 'Indexed' then
  begin
    // [/Indexed base hival lookup]
    var BaseCS: TPDFColorSpace := nil;
    if AArr.Count > 1 then
      BaseCS := Build(AArr.Items(1), AResolver)
    else
      BaseCS := TPDFDeviceRGB.Create;

    var HiVal := 255;
    if AArr.Count > 2 then
      HiVal := AArr.GetAsInteger(2);

    var Lookup: TBytes;
    if AArr.Count > 3 then
    begin
      var LookupObj := AArr.Get(3);
      if LookupObj.IsString then
      begin
        var S := LookupObj.AsString;
        SetLength(Lookup, Length(S));
        Move(S[1], Lookup[0], Length(S));
      end else if LookupObj.IsStream then
        Lookup := TPDFStream(LookupObj).DecodedBytes;
    end;
    Exit(TPDFIndexed.Create(BaseCS, HiVal, Lookup));
  end;

  if TypeName = 'Separation' then
  begin
    var ColorName := AArr.GetAsName(1, 'None');
    var Alt: TPDFColorSpace := nil;
    if AArr.Count > 2 then
      Alt := Build(AArr.Items(2), AResolver);
    if Alt = nil then Alt := TPDFDeviceGray.Create;
    var TintFn: TPDFObject := nil;
    if AArr.Count > 3 then TintFn := AArr.Items(3);
    Exit(TPDFSeparation.Create(ColorName, Alt, TintFn));
  end;

  if TypeName = 'DeviceN' then
  begin
    var Colorants: TArray<string>;
    if (AArr.Count > 1) and AArr.Items(1).IsArray then
    begin
      var CA := TPDFArray(AArr.Items(1));
      SetLength(Colorants, CA.Count);
      for var I := 0 to CA.Count - 1 do
        Colorants[I] := CA.GetAsName(I);
    end;
    var Alt: TPDFColorSpace := nil;
    if AArr.Count > 2 then
      Alt := Build(AArr.Items(2), AResolver);
    if Alt = nil then Alt := TPDFDeviceRGB.Create;
    var TintFn: TPDFObject := nil;
    if AArr.Count > 3 then TintFn := AArr.Items(3);
    Exit(TPDFDeviceN.Create(Colorants, Alt, TintFn));
  end;

  // Fallback: try as name
  Result := BuildFromName(TypeName);
end;

// =========================================================================
// TPDFColorSpaceRegistry
// =========================================================================

constructor TPDFColorSpaceRegistry.Create;
begin
  inherited;
  FMap := TObjectDictionary<string, TPDFColorSpace>.Create([doOwnsValues]);
end;

destructor TPDFColorSpaceRegistry.Destroy;
begin
  FMap.Free;
  inherited;
end;

procedure TPDFColorSpaceRegistry.Register(const AName: string; ACS: TPDFColorSpace);
begin
  FMap.AddOrSetValue(AName, ACS);
end;

function TPDFColorSpaceRegistry.Lookup(const AName: string): TPDFColorSpace;
begin
  if not FMap.TryGetValue(AName, Result) then
    Result := nil;
end;

procedure TPDFColorSpaceRegistry.Clear;
begin
  FMap.Clear;
end;

end.
