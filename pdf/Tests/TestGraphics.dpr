program TestGraphics;
// Tests: paths and graphics state of uPDF.ContentStream (current point of the
// 'v' operator, the inherited initial state of form XObjects) and the soft
// masks of uPDF.Image (resampling, images that cannot be decoded).

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}

uses
  System.SysUtils, System.Classes, System.Types, System.Math,
  uPDF.Types          in '..\Src\Core\uPDF.Types.pas',
  uPDF.Errors         in '..\Src\Core\uPDF.Errors.pas',
  uPDF.Objects        in '..\Src\Core\uPDF.Objects.pas',
  uPDF.GraphicsState  in '..\Src\Core\uPDF.GraphicsState.pas',
  uPDF.ContentStream  in '..\Src\Core\uPDF.ContentStream.pas',
  uPDF.Image          in '..\Src\Core\uPDF.Image.pas';

// =========================================================================
// Helpers
// =========================================================================

var
  PassCount: Integer = 0;
  FailCount: Integer = 0;

procedure Pass(const AMsg: string);
begin
  Inc(PassCount);
  WriteLn('  [PASS] ', AMsg);
end;

procedure Fail(const AMsg: string; const AReason: string = '');
begin
  Inc(FailCount);
  if AReason <> '' then WriteLn('  [FAIL] ', AMsg, ' - ', AReason)
  else              WriteLn('  [FAIL] ', AMsg);
end;

procedure Check(ACondition: Boolean; const AMsg: string;
  const ADetail: string = '');
begin
  if ACondition then Pass(AMsg) else Fail(AMsg, ADetail);
end;

procedure Section(const ATitle: string);
begin
  WriteLn;
  WriteLn('=== ', ATitle, ' ===');
end;

function Bytes(const S: AnsiString): TBytes;
begin
  SetLength(Result, Length(S));
  if S <> '' then Move(S[1], Result[0], Length(S));
end;

function SamePt(const P: TPointF; X, Y: Single): Boolean;
begin
  Result := SameValue(P.X, X, 1e-4) and SameValue(P.Y, Y, 1e-4);
end;

function ImageStream(AW, AH: Integer; const AData: TBytes; const AFilter: string = ''): TPDFStream;
begin
  Result := TPDFStream.Create;
  Result.SetRawData(AData);
  Result.Dict.SetValue('Type', TPDFName.Create('XObject'));
  Result.Dict.SetValue('Subtype', TPDFName.Create('Image'));
  Result.Dict.SetValue('Width', TPDFInteger.Create(AW));
  Result.Dict.SetValue('Height', TPDFInteger.Create(AH));
  Result.Dict.SetValue('BitsPerComponent', TPDFInteger.Create(8));
  Result.Dict.SetValue('ColorSpace', TPDFName.Create('DeviceGray'));
  Result.Dict.SetValue('Length', TPDFInteger.Create(Length(AData)));
  if AFilter <> '' then
    Result.Dict.SetValue('Filter', TPDFName.Create(AFilter));
end;

// =========================================================================
// Paths
// =========================================================================

procedure TestPaths;
var
  P: TPDFPath;
begin
  Section('Trazos');
  P := TPDFPath.Create;
  try
    P.MoveTo(0, 0);
    P.LineTo(10, 0);
    P.CurveToV(20, 20, 30, 30);
    var S := P.Segments[2];
    Check((S.Kind = TPDFPathSegKind.CurveToV) and SamePt(S.P1, 10, 0) and
      SamePt(S.P2, 20, 20) and SamePt(S.P3, 30, 30),
      'G01 v: el primer punto de control es el punto actual');
    P.ClosePath;
    P.CurveToV(5, 5, 6, 6);
    Check(SamePt(P.Segments[4].P1, 0, 0), 'G02 v tras closepath: inicio del subtrazo');
    P.CurveTo(1, 1, 2, 2, 3, 3);
    P.CurveToY(7, 7, 8, 8);
    P.CurveToV(9, 9, 10, 10);
    Check(SamePt(P.Segments[7].P1, 8, 8), 'G03 v tras y: extremo del segmento anterior');
    P.AddRect(100, 200, 10, 10);
    P.CurveToV(1, 1, 2, 2);
    Check(SamePt(P.Segments[P.Count - 1].P1, 100, 200), 'G04 v tras re: origen del rectángulo');
    P.Clear;
    P.CurveToV(1, 1, 2, 2);
    Check(SamePt(P.Segments[0].P1, 0, 0), 'G05 trazo vacío: punto actual en el origen');
  finally
    P.Free;
  end;
end;

// =========================================================================
// Initial graphics state (form XObjects)
// =========================================================================

procedure TestInitialState;
var
  Proc: TPDFContentStreamProcessor;
  CTMs: TArray<TPDFMatrix>;
  Widths: TArray<Single>;
begin
  Section('Estado inicial (formularios)');
  Proc := TPDFContentStreamProcessor.Create;
  try
    Proc.OnPaintPath :=
      procedure(const APath: TPDFPath; const AState: TPDFGraphicsState; AOp: TPDFPaintOp)
      begin
        CTMs := CTMs + [AState.CTM];
        Widths := Widths + [AState.LineWidth];
      end;
    var State: TPDFGraphicsState;
    State.Reset;
    State.CTM := TPDFMatrix.Make(2, 0, 0, 2, 5, 7);
    State.LineWidth := 3;
    Proc.SetInitialState(State);
    Proc.Process(Bytes('0 0 m 1 1 l S q 1 0 0 1 10 0 cm 0 0 m 1 1 l S Q 0 0 m 2 2 l S'), nil);
    Check(Length(CTMs) = 3, 'S01 tres trazos', IntToStr(Length(CTMs)));
    if Length(CTMs) = 3 then
    begin
      Check((CTMs[0] = TPDFMatrix.Make(2, 0, 0, 2, 5, 7)) and SameValue(Widths[0], 3),
        'S02 el contenido parte del CTM y del grosor heredados');
      Check(SameValue(CTMs[1].E, 25) and SameValue(CTMs[1].F, 7),
        'S03 cm se concatena sobre el CTM heredado', Format('%g %g', [CTMs[1].E, CTMs[1].F]));
      Check(CTMs[2] = TPDFMatrix.Make(2, 0, 0, 2, 5, 7), 'S04 Q vuelve al estado heredado');
    end;
  finally
    Proc.Free;
  end;
  // Without an initial state the processor starts from the default one
  Proc := TPDFContentStreamProcessor.Create;
  try
    CTMs := nil;
    Proc.OnPaintPath :=
      procedure(const APath: TPDFPath; const AState: TPDFGraphicsState; AOp: TPDFPaintOp)
      begin
        CTMs := CTMs + [AState.CTM];
      end;
    Proc.Process(Bytes('0 0 m 1 1 l S'), nil);
    Check((Length(CTMs) = 1) and CTMs[0].IsIdentity, 'S05 sin estado inicial: identidad');
  finally
    Proc.Free;
  end;
end;

// =========================================================================
// Soft masks
// =========================================================================

procedure TestSoftMasks;
var
  Img: TPDFImage;
  Alpha: TBytes;
begin
  Section('Máscaras suaves');
  // 4 x 2 image, 2 x 1 soft mask: each mask sample covers 2 x 2 pixels
  var S := ImageStream(4, 2, TBytes.Create(1, 2, 3, 4, 5, 6, 7, 8));
  S.Dict.SetValue('SMask', ImageStream(2, 1, TBytes.Create(10, 200)));
  Img := TPDFImage.FromXObject(S);
  try
    Img.Decode;
    Check(Img.MaskAlpha(4, 2, Alpha) and (Length(Alpha) = 8) and
      (Alpha[0] = 10) and (Alpha[1] = 10) and (Alpha[2] = 200) and (Alpha[3] = 200) and
      (Alpha[4] = 10) and (Alpha[7] = 200), 'M01 máscara de otro tamaño: muestra más cercana');
    var RGBA := Img.ToRGBA;
    Check((Length(RGBA) = 32) and (RGBA[3] = 10) and (RGBA[15] = 200) and (RGBA[4] = 2),
      'M02 ToRGBA aplica la máscara redimensionada');
  finally
    Img.Free;
    S.Free;
  end;

  // A JPEG soft mask is not decoded by the core: no alpha until the caller decodes it
  S := ImageStream(2, 1, TBytes.Create(1, 2));
  S.Dict.SetValue('SMask', ImageStream(2, 1, TBytes.Create($FF, $D8, $FF, $D9), 'DCTDecode'));
  Img := TPDFImage.FromXObject(S);
  try
    Img.Decode;
    Check(not Img.MaskAlpha(2, 1, Alpha), 'M03 máscara JPEG sin decodificar: sin alfa');
    Check(Img.ToRGBA[3] = 255, 'M04 sin alfa: opaco (no los bytes del JPEG)');
    Img.SMask.SetDecodedGray(TBytes.Create(0, 128));
    Check(Img.MaskAlpha(2, 1, Alpha) and (Alpha[1] = 128), 'M05 máscara decodificada por el llamador');
  finally
    Img.Free;
    S.Free;
  end;

  // JPEG 2000 is not supported: no pixels instead of the compressed bytes
  S := ImageStream(2, 2, TBytes.Create(0, 0, 0, $0C, $6A, $50), 'JPXDecode');
  Img := TPDFImage.FromXObject(S);
  try
    Img.Decode;
    Check(Length(Img.ToRGBA) = 0, 'M06 JPEG 2000: ToRGBA vacío (no se pinta)');
  finally
    Img.Free;
    S.Free;
  end;
end;

begin
  try
    TestPaths;
    TestInitialState;
    TestSoftMasks;
  except
    on E: Exception do
    begin
      Inc(FailCount);
      WriteLn('EXCEPCIÓN: ', E.ClassName, ': ', E.Message);
    end;
  end;
  WriteLn;
  WriteLn(Format('Total: %d pasan, %d fallan', [PassCount, FailCount]));
  if FailCount > 0 then ExitCode := 1;
end.
