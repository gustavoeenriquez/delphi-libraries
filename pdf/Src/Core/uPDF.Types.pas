unit uPDF.Types;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Math;

const
  PDF_HEADER_MIN      = '%PDF-';
  PDF_EOF_MARKER      = '%%EOF';
  PDF_XREF_MARKER     = 'xref';
  PDF_STARTXREF       = 'startxref';
  PDF_OBJ_MARKER      = 'obj';
  PDF_ENDOBJ_MARKER   = 'endobj';
  PDF_STREAM_MARKER   = 'stream';
  PDF_ENDSTREAM       = 'endstream';
  PDF_TRAILER         = 'trailer';

  PDF_MAX_GENERATION  = 65535;
  PDF_FREE_ENTRY      = 'f';
  PDF_INUSE_ENTRY     = 'n';
  PDF_COMPRESSED_ENTRY = 'c';

  // PDF page sizes (points = 1/72 inch)
  PDF_A4_WIDTH        = 595.28;
  PDF_A4_HEIGHT       = 841.89;
  PDF_LETTER_WIDTH    = 612.0;
  PDF_LETTER_HEIGHT   = 792.0;
  PDF_A3_WIDTH        = 841.89;
  PDF_A3_HEIGHT       = 1190.55;

type
  // -------------------------------------------------------------------------
  // PDF version
  // -------------------------------------------------------------------------
  TPDFVersion = record
    Major: Byte;
    Minor: Byte;
    function ToString: string;
    class function Parse(const AStr: string): TPDFVersion; static;
    class function Make(AMajor, AMinor: Byte): TPDFVersion; static;
  end;

  // -------------------------------------------------------------------------
  // Object identifier
  // -------------------------------------------------------------------------
  TPDFObjectID = record
    Number:     Integer;
    Generation: Integer;
    function ToString: string; inline;
    function IsNull: Boolean; inline;
    class function Make(ANumber, AGeneration: Integer): TPDFObjectID; static; inline;
    class function Null: TPDFObjectID; static; inline;
    class operator Equal(const A, B: TPDFObjectID): Boolean; inline;
    class operator NotEqual(const A, B: TPDFObjectID): Boolean; inline;
  end;

  // -------------------------------------------------------------------------
  // PDF Color (device-independent, components 0.0 .. 1.0)
  // -------------------------------------------------------------------------
  TPDFColorModel = (Unknown, DeviceGray, DeviceRGB, DeviceCMYK, Pattern);

  TPDFColor = record
    Model:  TPDFColorModel;
    C0, C1, C2, C3: Single;  // Gray=C0; RGB=C0,C1,C2; CMYK=C0..C3
    Alpha:  Single;           // 0.0=transparent, 1.0=opaque
    function ToAlphaColor: TAlphaColor;
    class function MakeGray(const AG: Single): TPDFColor; static; inline;
    class function MakeRGB(const AR, AG, AB: Single): TPDFColor; static; inline;
    class function MakeCMYK(const AC, AM, AY, AK: Single): TPDFColor; static; inline;
    class function Black: TPDFColor; static; inline;
    class function White: TPDFColor; static; inline;
    class function Transparent: TPDFColor; static; inline;
  end;

  // -------------------------------------------------------------------------
  // PDF Rectangle  (llx, lly, urx, ury in user-space units)
  // -------------------------------------------------------------------------
  TPDFRect = record
    LLX, LLY: Single;   // Lower-Left
    URX, URY: Single;   // Upper-Right
    function Width: Single; inline;
    function Height: Single; inline;
    function ToRectF: TRectF; inline;
    function IsEmpty: Boolean; inline;
    function Normalize: TPDFRect;
    class function MakeEmpty: TPDFRect; static; inline;
    class function FromRectF(const R: TRectF): TPDFRect; static; inline;
    class function Make(ALLX, ALLY, AURX, AURY: Single): TPDFRect; static; inline;
    class operator Equal(const A, B: TPDFRect): Boolean; inline;
  end;

  // -------------------------------------------------------------------------
  // PDF Matrix (a b c d e f  — same as PostScript/PDF spec Table 4)
  //
  //   | a  b  0 |
  //   | c  d  0 |
  //   | e  f  1 |
  //
  // Point transform:  x' = a*x + c*y + e
  //                   y' = b*x + d*y + f
  // -------------------------------------------------------------------------
  TPDFMatrix = record
    A, B, C, D, E, F: Single;
    function Concat(const AOther: TPDFMatrix): TPDFMatrix;
    function Inverse: TPDFMatrix;
    function Transform(const APoint: TPointF): TPointF; inline;
    function TransformRect(const ARect: TPDFRect): TPDFRect;
    function IsIdentity: Boolean; inline;
    class function Identity: TPDFMatrix; static; inline;
    class function MakeScale(ASX, ASY: Single): TPDFMatrix; static; inline;
    class function MakeTranslate(ATX, ATY: Single): TPDFMatrix; static; inline;
    class function MakeRotate(AAngleDeg: Single): TPDFMatrix; static;
    class function Make(AA, AB, AC, AD, AE, AF: Single): TPDFMatrix; static; inline;
    class operator Multiply(const A, B: TPDFMatrix): TPDFMatrix; inline;
    class operator Equal(const A, B: TPDFMatrix): Boolean; inline;
  end;

  // -------------------------------------------------------------------------
  // Line cap / join styles
  // -------------------------------------------------------------------------
  TPDFLineCap = (ButtCap = 0, RoundCap = 1, ProjectingSquareCap = 2);
  TPDFLineJoin = (MiterJoin = 0, RoundJoin = 1, BevelJoin = 2);

  // -------------------------------------------------------------------------
  // Text rendering mode (PDF spec Table 106)
  // -------------------------------------------------------------------------
  TPDFTextRenderMode = (
    Fill            = 0,
    Stroke          = 1,
    FillThenStroke  = 2,
    Invisible       = 3,
    FillAndClip     = 4,
    StrokeAndClip   = 5,
    FillStrokeClip  = 6,
    Clip            = 7
  );

  // -------------------------------------------------------------------------
  // Rendering intent names (PDF spec 8.6.5.8)
  // -------------------------------------------------------------------------
  TPDFRenderingIntent = (
    AbsoluteColorimetric,
    RelativeColorimetric,
    Saturation,
    Perceptual
  );

  // -------------------------------------------------------------------------
  // Blend modes (PDF spec Table 136)
  // -------------------------------------------------------------------------
  TPDFBlendMode = (
    Normal,
    Multiply,
    Screen,
    Overlay,
    Darken,
    Lighten,
    ColorDodge,
    ColorBurn,
    HardLight,
    SoftLight,
    Difference,
    Exclusion,
    Hue,
    Saturation,
    Color,
    Luminosity
  );

  // -------------------------------------------------------------------------
  // Save mode for PDF writer
  // -------------------------------------------------------------------------
  TPDFSaveMode = (
    FullRewrite,    // Rebuild entire file from object graph
    Incremental     // Append update section (preserves original bytes)
  );

  // -------------------------------------------------------------------------
  // XRef entry type
  // -------------------------------------------------------------------------
  TPDFXRefEntryType = (Free, InUse, Compressed);

  TPDFXRefEntry = record
    EntryType:    TPDFXRefEntryType;
    Offset:       Int64;    // Byte offset (InUse) or container object# (Compressed)
    Generation:   Integer;
    IndexInStream: Integer; // Index within object stream (Compressed only)
  end;

  // -------------------------------------------------------------------------
  // Filter names (PDF spec Table 5)
  // -------------------------------------------------------------------------
  TPDFFilterKind = (
    Unknown,
    FlateDecode,
    LZWDecode,
    DCTDecode,
    CCITTFaxDecode,
    JBIG2Decode,
    JPXDecode,
    ASCII85Decode,
    ASCIIHexDecode,
    RunLengthDecode,
    Crypt
  );

  // -------------------------------------------------------------------------
  // Utility functions
  // -------------------------------------------------------------------------
  function PDFFilterKindFromName(const AName: string): TPDFFilterKind;
  function PDFFilterKindToName(AKind: TPDFFilterKind): string;
  function PDFRenderingIntentFromName(const AName: string): TPDFRenderingIntent;
  function PDFBlendModeFromName(const AName: string): TPDFBlendMode;
  function PDFBlendModeToName(AMode: TPDFBlendMode): string;

type
  // -------------------------------------------------------------------------
  // Decryption context interface
  // Implemented by TPDFDecryptor in uPDF.Encryption.
  // Used by TPDFStream and TPDFParser to decrypt encrypted PDF content.
  // -------------------------------------------------------------------------
  IDecryptionContext = interface
    ['{C7A3F2D8-5E91-4B6C-A0D3-E8F1C2B74A9D}']
    // Decrypt bytes belonging to object (AObjNum, AGenNum).
    // AIsStream = True for pre-stream-filter data; False for string values.
    function DecryptBytes(const AData: TBytes; AObjNum, AGenNum: Integer;
      AIsStream: Boolean): TBytes;
  end;

implementation

// -------------------------------------------------------------------------
// TPDFVersion
// -------------------------------------------------------------------------

function TPDFVersion.ToString: string;
begin
  Result := Format('%d.%d', [Major, Minor]);
end;

class function TPDFVersion.Parse(const AStr: string): TPDFVersion;
begin
  var Parts := AStr.Split(['.']);
  if Length(Parts) >= 2 then
  begin
    Result.Major := StrToIntDef(Parts[0], 1);
    Result.Minor := StrToIntDef(Parts[1], 0);
  end else
  begin
    Result.Major := 1;
    Result.Minor := 0;
  end;
end;

class function TPDFVersion.Make(AMajor, AMinor: Byte): TPDFVersion;
begin
  Result.Major := AMajor;
  Result.Minor := AMinor;
end;

// -------------------------------------------------------------------------
// TPDFObjectID
// -------------------------------------------------------------------------

function TPDFObjectID.ToString: string;
begin
  Result := Format('%d %d R', [Number, Generation]);
end;

function TPDFObjectID.IsNull: Boolean;
begin
  Result := (Number = 0) and (Generation = 0);
end;

class function TPDFObjectID.Make(ANumber, AGeneration: Integer): TPDFObjectID;
begin
  Result.Number     := ANumber;
  Result.Generation := AGeneration;
end;

class function TPDFObjectID.Null: TPDFObjectID;
begin
  Result.Number     := 0;
  Result.Generation := 0;
end;

class operator TPDFObjectID.Equal(const A, B: TPDFObjectID): Boolean;
begin
  Result := (A.Number = B.Number) and (A.Generation = B.Generation);
end;

class operator TPDFObjectID.NotEqual(const A, B: TPDFObjectID): Boolean;
begin
  Result := not (A = B);
end;

// -------------------------------------------------------------------------
// TPDFColor
// -------------------------------------------------------------------------

function TPDFColor.ToAlphaColor: TAlphaColor;
var
  R, G, B: Byte;
  CR, CG, CB: Single;
begin
  case Model of
    TPDFColorModel.DeviceGray:
    begin
      CR := C0; CG := C0; CB := C0;
    end;
    TPDFColorModel.DeviceRGB:
    begin
      CR := C0; CG := C1; CB := C2;
    end;
    TPDFColorModel.DeviceCMYK:
    begin
      // Simple CMYK -> RGB conversion
      CR := (1 - C0) * (1 - C3);
      CG := (1 - C1) * (1 - C3);
      CB := (1 - C2) * (1 - C3);
    end;
  else
    CR := 0; CG := 0; CB := 0;
  end;

  R := Round(EnsureRange(CR, 0, 1) * 255);
  G := Round(EnsureRange(CG, 0, 1) * 255);
  B := Round(EnsureRange(CB, 0, 1) * 255);
  var A: Byte := Round(EnsureRange(Alpha, 0, 1) * 255);
  Result := (Cardinal(A) shl 24) or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B);
end;

class function TPDFColor.MakeGray(const AG: Single): TPDFColor;
begin
  Result.Model := TPDFColorModel.DeviceGray;
  Result.C0    := AG;
  Result.C1    := 0;
  Result.C2    := 0;
  Result.C3    := 0;
  Result.Alpha := 1.0;
end;

class function TPDFColor.MakeRGB(const AR, AG, AB: Single): TPDFColor;
begin
  Result.Model := TPDFColorModel.DeviceRGB;
  Result.C0    := AR;
  Result.C1    := AG;
  Result.C2    := AB;
  Result.C3    := 0;
  Result.Alpha := 1.0;
end;

class function TPDFColor.MakeCMYK(const AC, AM, AY, AK: Single): TPDFColor;
begin
  Result.Model := TPDFColorModel.DeviceCMYK;
  Result.C0    := AC;
  Result.C1    := AM;
  Result.C2    := AY;
  Result.C3    := AK;
  Result.Alpha := 1.0;
end;

class function TPDFColor.Black: TPDFColor;
begin
  Result := MakeGray(0);
end;

class function TPDFColor.White: TPDFColor;
begin
  Result := MakeGray(1);
end;

class function TPDFColor.Transparent: TPDFColor;
begin
  Result       := MakeGray(0);
  Result.Alpha := 0;
end;

// -------------------------------------------------------------------------
// TPDFRect
// -------------------------------------------------------------------------

function TPDFRect.Width: Single;
begin
  Result := URX - LLX;
end;

function TPDFRect.Height: Single;
begin
  Result := URY - LLY;
end;

function TPDFRect.ToRectF: TRectF;
begin
  Result := TRectF.Create(LLX, LLY, URX, URY);
end;

function TPDFRect.IsEmpty: Boolean;
begin
  Result := (Width <= 0) or (Height <= 0);
end;

function TPDFRect.Normalize: TPDFRect;
begin
  Result.LLX := Min(LLX, URX);
  Result.LLY := Min(LLY, URY);
  Result.URX := Max(LLX, URX);
  Result.URY := Max(LLY, URY);
end;

class function TPDFRect.MakeEmpty: TPDFRect;
begin
  Result.LLX := 0; Result.LLY := 0;
  Result.URX := 0; Result.URY := 0;
end;

class function TPDFRect.FromRectF(const R: TRectF): TPDFRect;
begin
  Result.LLX := R.Left;
  Result.LLY := R.Top;
  Result.URX := R.Right;
  Result.URY := R.Bottom;
end;

class function TPDFRect.Make(ALLX, ALLY, AURX, AURY: Single): TPDFRect;
begin
  Result.LLX := ALLX; Result.LLY := ALLY;
  Result.URX := AURX; Result.URY := AURY;
end;

class operator TPDFRect.Equal(const A, B: TPDFRect): Boolean;
begin
  Result := SameValue(A.LLX, B.LLX) and SameValue(A.LLY, B.LLY)
        and SameValue(A.URX, B.URX) and SameValue(A.URY, B.URY);
end;

// -------------------------------------------------------------------------
// TPDFMatrix
// -------------------------------------------------------------------------

function TPDFMatrix.Concat(const AOther: TPDFMatrix): TPDFMatrix;
begin
  // [self] x [AOther]
  Result.A := A * AOther.A + B * AOther.C;
  Result.B := A * AOther.B + B * AOther.D;
  Result.C := C * AOther.A + D * AOther.C;
  Result.D := C * AOther.B + D * AOther.D;
  Result.E := E * AOther.A + F * AOther.C + AOther.E;
  Result.F := E * AOther.B + F * AOther.D + AOther.F;
end;

function TPDFMatrix.Inverse: TPDFMatrix;
var
  Det: Single;
begin
  Det := A * D - B * C;
  if Abs(Det) < 1e-10 then
    Exit(Identity);
  Result.A :=  D / Det;
  Result.B := -B / Det;
  Result.C := -C / Det;
  Result.D :=  A / Det;
  Result.E := (C * F - D * E) / Det;
  Result.F := (B * E - A * F) / Det;
end;

function TPDFMatrix.Transform(const APoint: TPointF): TPointF;
begin
  Result.X := A * APoint.X + C * APoint.Y + E;
  Result.Y := B * APoint.X + D * APoint.Y + F;
end;

function TPDFMatrix.TransformRect(const ARect: TPDFRect): TPDFRect;
var
  P1, P2, P3, P4: TPointF;
begin
  P1 := Transform(TPointF.Create(ARect.LLX, ARect.LLY));
  P2 := Transform(TPointF.Create(ARect.URX, ARect.LLY));
  P3 := Transform(TPointF.Create(ARect.LLX, ARect.URY));
  P4 := Transform(TPointF.Create(ARect.URX, ARect.URY));
  Result.LLX := Min(Min(P1.X, P2.X), Min(P3.X, P4.X));
  Result.LLY := Min(Min(P1.Y, P2.Y), Min(P3.Y, P4.Y));
  Result.URX := Max(Max(P1.X, P2.X), Max(P3.X, P4.X));
  Result.URY := Max(Max(P1.Y, P2.Y), Max(P3.Y, P4.Y));
end;

function TPDFMatrix.IsIdentity: Boolean;
begin
  Result := SameValue(A, 1) and SameValue(B, 0)
        and SameValue(C, 0) and SameValue(D, 1)
        and SameValue(E, 0) and SameValue(F, 0);
end;

class function TPDFMatrix.Identity: TPDFMatrix;
begin
  Result.A := 1; Result.B := 0;
  Result.C := 0; Result.D := 1;
  Result.E := 0; Result.F := 0;
end;

class function TPDFMatrix.MakeScale(ASX, ASY: Single): TPDFMatrix;
begin
  Result.A := ASX; Result.B := 0;
  Result.C := 0;   Result.D := ASY;
  Result.E := 0;   Result.F := 0;
end;

class function TPDFMatrix.MakeTranslate(ATX, ATY: Single): TPDFMatrix;
begin
  Result.A := 1;   Result.B := 0;
  Result.C := 0;   Result.D := 1;
  Result.E := ATX; Result.F := ATY;
end;

class function TPDFMatrix.MakeRotate(AAngleDeg: Single): TPDFMatrix;
var
  S, Co: Single;
begin
  S  := Sin(DegToRad(AAngleDeg));
  Co := Cos(DegToRad(AAngleDeg));
  Result.A :=  Co; Result.B := S;
  Result.C := -S;  Result.D := Co;
  Result.E :=  0;  Result.F := 0;
end;

class function TPDFMatrix.Make(AA, AB, AC, AD, AE, AF: Single): TPDFMatrix;
begin
  Result.A := AA; Result.B := AB;
  Result.C := AC; Result.D := AD;
  Result.E := AE; Result.F := AF;
end;

class operator TPDFMatrix.Multiply(const A, B: TPDFMatrix): TPDFMatrix;
begin
  Result := A.Concat(B);
end;

class operator TPDFMatrix.Equal(const A, B: TPDFMatrix): Boolean;
begin
  Result := SameValue(A.A, B.A) and SameValue(A.B, B.B)
        and SameValue(A.C, B.C) and SameValue(A.D, B.D)
        and SameValue(A.E, B.E) and SameValue(A.F, B.F);
end;

// -------------------------------------------------------------------------
// Utility functions
// -------------------------------------------------------------------------

function PDFFilterKindFromName(const AName: string): TPDFFilterKind;
var
  N: string;
begin
  N := AName.TrimLeft(['/']);
  if (N = 'FlateDecode')   or (N = 'Fl')  then Exit(TPDFFilterKind.FlateDecode);
  if (N = 'LZWDecode')     or (N = 'LZW') then Exit(TPDFFilterKind.LZWDecode);
  if (N = 'DCTDecode')     or (N = 'DCT') then Exit(TPDFFilterKind.DCTDecode);
  if (N = 'CCITTFaxDecode')or (N = 'CCF') then Exit(TPDFFilterKind.CCITTFaxDecode);
  if N = 'JBIG2Decode'                    then Exit(TPDFFilterKind.JBIG2Decode);
  if N = 'JPXDecode'                      then Exit(TPDFFilterKind.JPXDecode);
  if (N = 'ASCII85Decode') or (N = 'A85') then Exit(TPDFFilterKind.ASCII85Decode);
  if (N = 'ASCIIHexDecode')or (N = 'AHx') then Exit(TPDFFilterKind.ASCIIHexDecode);
  if (N = 'RunLengthDecode')or (N = 'RL') then Exit(TPDFFilterKind.RunLengthDecode);
  if N = 'Crypt'                          then Exit(TPDFFilterKind.Crypt);
  Result := TPDFFilterKind.Unknown;
end;

function PDFFilterKindToName(AKind: TPDFFilterKind): string;
begin
  case AKind of
    TPDFFilterKind.FlateDecode:    Result := 'FlateDecode';
    TPDFFilterKind.LZWDecode:      Result := 'LZWDecode';
    TPDFFilterKind.DCTDecode:      Result := 'DCTDecode';
    TPDFFilterKind.CCITTFaxDecode: Result := 'CCITTFaxDecode';
    TPDFFilterKind.JBIG2Decode:    Result := 'JBIG2Decode';
    TPDFFilterKind.JPXDecode:      Result := 'JPXDecode';
    TPDFFilterKind.ASCII85Decode:  Result := 'ASCII85Decode';
    TPDFFilterKind.ASCIIHexDecode: Result := 'ASCIIHexDecode';
    TPDFFilterKind.RunLengthDecode:Result := 'RunLengthDecode';
    TPDFFilterKind.Crypt:          Result := 'Crypt';
  else
    Result := '';
  end;
end;

function PDFRenderingIntentFromName(const AName: string): TPDFRenderingIntent;
var
  N: string;
begin
  N := AName.TrimLeft(['/']);
  if N = 'AbsoluteColorimetric' then Exit(TPDFRenderingIntent.AbsoluteColorimetric);
  if N = 'Saturation'           then Exit(TPDFRenderingIntent.Saturation);
  if N = 'Perceptual'           then Exit(TPDFRenderingIntent.Perceptual);
  Result := TPDFRenderingIntent.RelativeColorimetric; // default per spec
end;

function PDFBlendModeFromName(const AName: string): TPDFBlendMode;
var
  N: string;
begin
  N := AName.TrimLeft(['/']);
  if N = 'Multiply'   then Exit(TPDFBlendMode.Multiply);
  if N = 'Screen'     then Exit(TPDFBlendMode.Screen);
  if N = 'Overlay'    then Exit(TPDFBlendMode.Overlay);
  if N = 'Darken'     then Exit(TPDFBlendMode.Darken);
  if N = 'Lighten'    then Exit(TPDFBlendMode.Lighten);
  if N = 'ColorDodge' then Exit(TPDFBlendMode.ColorDodge);
  if N = 'ColorBurn'  then Exit(TPDFBlendMode.ColorBurn);
  if N = 'HardLight'  then Exit(TPDFBlendMode.HardLight);
  if N = 'SoftLight'  then Exit(TPDFBlendMode.SoftLight);
  if N = 'Difference' then Exit(TPDFBlendMode.Difference);
  if N = 'Exclusion'  then Exit(TPDFBlendMode.Exclusion);
  if N = 'Hue'        then Exit(TPDFBlendMode.Hue);
  if N = 'Saturation' then Exit(TPDFBlendMode.Saturation);
  if N = 'Color'      then Exit(TPDFBlendMode.Color);
  if N = 'Luminosity' then Exit(TPDFBlendMode.Luminosity);
  Result := TPDFBlendMode.Normal;
end;

function PDFBlendModeToName(AMode: TPDFBlendMode): string;
begin
  case AMode of
    TPDFBlendMode.Multiply:   Result := 'Multiply';
    TPDFBlendMode.Screen:     Result := 'Screen';
    TPDFBlendMode.Overlay:    Result := 'Overlay';
    TPDFBlendMode.Darken:     Result := 'Darken';
    TPDFBlendMode.Lighten:    Result := 'Lighten';
    TPDFBlendMode.ColorDodge: Result := 'ColorDodge';
    TPDFBlendMode.ColorBurn:  Result := 'ColorBurn';
    TPDFBlendMode.HardLight:  Result := 'HardLight';
    TPDFBlendMode.SoftLight:  Result := 'SoftLight';
    TPDFBlendMode.Difference: Result := 'Difference';
    TPDFBlendMode.Exclusion:  Result := 'Exclusion';
    TPDFBlendMode.Hue:        Result := 'Hue';
    TPDFBlendMode.Saturation: Result := 'Saturation';
    TPDFBlendMode.Color:      Result := 'Color';
    TPDFBlendMode.Luminosity: Result := 'Luminosity';
  else
    Result := 'Normal';
  end;
end;

end.
