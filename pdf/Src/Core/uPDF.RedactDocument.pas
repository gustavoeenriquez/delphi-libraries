unit uPDF.RedactDocument;

{
  Tachado real de un documento PDF: lo que queda bajo cada recuadro desaparece
  del archivo, no solo de la vista.

  Por página, para cada recuadro (normalizado al CropBox, 0,0 arriba a la
  izquierda, Y hacia abajo):
    - El texto: se QUITAN los glifos cuyo centro cae en el recuadro
      (TPDFRedactor.RemoveTextInContent), en el contenido de la página y en
      cada formulario XObject que se pinte sobre el recuadro (con su matriz).
    - Las imágenes que se pintan sobre el recuadro: sus píxeles bajo él pasan
      a negro y la imagen se reescribe (Flate; las JPEG con el códec que se
      le dé, JpegDecode/JpegEncode). Su máscara suave queda opaca ahí.
    - Encima, un recuadro negro (así se ve lo mismo en cualquier visor).
    - Las anotaciones que tocan el recuadro se quitan.
  Del documento entero (CleanDocument): Info (menos Producer), XMP, adjuntos,
  JavaScript, acciones de apertura, formularios, marcadores, estructura
  etiquetada (su texto alterno puede repetir lo tachado) y miniaturas.

  Un formulario o una imagen compartidos se cambian donde se usen: se tacha de
  más, nunca de menos.

  Lo que no se puede hacer con seguridad no se hace a medias: queda en
  Problems (página girada, imagen en línea sobre un recuadro, JPEG sin códec,
  JPEG 2000 o JBIG2, operadores de texto ' y "...) y el llamador decide (lo
  normal: no publicar esa versión).

  Guardar siempre con TPDFSaveMode.FullRewrite: no deja el contenido anterior
  como objetos sueltos.
}

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Types, System.Math,
  System.Generics.Collections, System.ZLib,
  uPDF.Types, uPDF.Objects, uPDF.Document, uPDF.Font, uPDF.ColorSpace,
  uPDF.GraphicsState, uPDF.ContentStream, uPDF.TextExtractor, uPDF.Image,
  uPDF.Redaction;

type
  TPDFRedactZone = record
    PageIndex: Integer;
    Box:       TRectF;   // normalizado al CropBox, Y hacia abajo
    class function Make(APage: Integer; AX, AY, AW, AH: Single): TPDFRedactZone; static;
  end;

  /// JPEG -> muestras de 8 bits (1 o 3 componentes, fila a fila desde arriba)
  TPDFJpegDecodeFunc = reference to function(const AJpeg: TBytes;
    out APixels: TBytes; out AWidth, AHeight, AComps: Integer): Boolean;
  /// muestras de 8 bits (1 o 3 componentes) -> JPEG
  TPDFJpegEncodeFunc = reference to function(const APixels: TBytes;
    AWidth, AHeight, AComps: Integer; out AJpeg: TBytes): Boolean;

  TPDFRedactReport = record
    Glyphs:      Integer;   // glifos quitados
    Images:      Integer;   // imágenes reescritas
    Forms:       Integer;   // formularios reescritos
    Annotations: Integer;   // anotaciones quitadas
    Problems:    TArray<string>;
    function Ok: Boolean;
  end;

  TPDFDocumentRedactor = class
  private
    FDoc:    TPDFDocument;
    FReport: TPDFRedactReport;
    FDone:   TDictionary<TPDFStream, Boolean>;
    procedure Problem(APage: Integer; const AMsg: string);
    function ToPage(APage: TPDFPage; const P: TPointF): TPointF;
    function BoundsOf(APage: TPDFPage; const AM: TPDFMatrix;
      const ARect: TPDFRect): TRectF;
    function Touches(const R: TRectF; const ABoxes: TArray<TRectF>): Boolean;
    procedure WalkXObjects(APage: TPDFPage; APageIndex: Integer;
      const AData: TBytes; AResDict: TPDFDictionary; const ABase: TPDFMatrix;
      const ABoxes: TArray<TRectF>; ADepth: Integer);
    procedure RedactForm(APage: TPDFPage; APageIndex: Integer; AStm: TPDFStream;
      const AM: TPDFMatrix; const ABoxes: TArray<TRectF>; ADepth: Integer);
    procedure RedactImage(APage: TPDFPage; APageIndex: Integer; AStm: TPDFStream;
      const ACTM: TPDFMatrix; const ABoxes: TArray<TRectF>);
    procedure RemoveAnnotations(APage: TPDFPage; const ABoxes: TArray<TRectF>);
  public
    JpegDecode: TPDFJpegDecodeFunc;
    JpegEncode: TPDFJpegEncodeFunc;
    JpegQuality: Integer;   // informativo para el códec (por omisión 90)
    constructor Create(ADoc: TPDFDocument);
    destructor Destroy; override;
    /// tacha las zonas y limpia el documento; el resultado se guarda aparte
    function Redact(const AZones: TArray<TPDFRedactZone>;
      ACleanDocument: Boolean = True): TPDFRedactReport;
    /// quita del documento lo que no se ve y puede repetir lo tachado
    procedure CleanDocument;
    /// el texto de los glifos con el centro dentro de las zonas (página y
    /// formularios): vacío después de un tachado bien hecho
    class function TextInZones(ADoc: TPDFDocument;
      const AZones: TArray<TPDFRedactZone>): string; static;
  end;

/// Flate (zlib) de unos bytes
function PDFDeflate(const AData: TBytes): TBytes;

implementation

{ TPDFRedactZone }

class function TPDFRedactZone.Make(APage: Integer; AX, AY, AW, AH: Single): TPDFRedactZone;
begin
  Result.PageIndex := APage;
  Result.Box := TRectF.Create(AX, AY, AX + AW, AY + AH);
end;

{ TPDFRedactReport }

function TPDFRedactReport.Ok: Boolean;
begin
  Result := Length(Problems) = 0;
end;

function PDFDeflate(const AData: TBytes): TBytes;
var
  CS: TCompressionStream;
  MS: TMemoryStream;
begin
  MS := TMemoryStream.Create;
  try
    CS := TCompressionStream.Create(clDefault, MS);
    try
      if Length(AData) > 0 then
        CS.Write(AData[0], Length(AData));
    finally
      CS.Free;
    end;
    SetLength(Result, MS.Size);
    if MS.Size > 0 then
      Move(MS.Memory^, Result[0], MS.Size);
  finally
    MS.Free;
  end;
end;

type
  /// recursos de un formulario: los suyos y, si no los tiene, los de la página
  TPDFFormResources = class(TInterfacedObject, IPDFResources)
  private
    FPage:  TPDFPage;
    FDict:  TPDFDictionary;
    FFonts: TObjectDictionary<string, TPDFFont>;
    FCS:    TObjectDictionary<string, TPDFColorSpace>;
    function Lookup(const AType, AName: string): TPDFObject;
  public
    constructor Create(APage: TPDFPage; ADict: TPDFDictionary);
    destructor Destroy; override;
    function GetFont(const AName: string): TPDFFont;
    function GetXObject(const AName: string): TPDFStream;
    function GetColorSpace(const AName: string): TPDFColorSpace;
    function GetExtGState(const AName: string): TPDFDictionary;
    function GetPattern(const AName: string): TPDFObject;
    function GetShading(const AName: string): TPDFObject;
  end;

constructor TPDFFormResources.Create(APage: TPDFPage; ADict: TPDFDictionary);
begin
  inherited Create;
  FPage := APage;
  FDict := ADict;
  FFonts := TObjectDictionary<string, TPDFFont>.Create([doOwnsValues]);
  FCS := TObjectDictionary<string, TPDFColorSpace>.Create([doOwnsValues]);
end;

destructor TPDFFormResources.Destroy;
begin
  FCS.Free;
  FFonts.Free;
  inherited;
end;

function TPDFFormResources.Lookup(const AType, AName: string): TPDFObject;
begin
  Result := nil;
  if FDict <> nil then
  begin
    var Sub := FDict.GetAsDictionary(AType);
    if Sub <> nil then
      Result := Sub.Get(AName);
    // un formulario con sus propios recursos no hereda los de la página
    Exit;
  end;
  Result := FPage.GetResource(AType, AName);
end;

function TPDFFormResources.GetFont(const AName: string): TPDFFont;
begin
  if FFonts.TryGetValue(AName, Result) then Exit;
  Result := nil;
  var O := Lookup('Font', AName);
  if (O <> nil) and O.IsDictionary then
  begin
    Result := TPDFFontFactory.Build(TPDFDictionary(O), FPage.Document.Resolver);
    if Result <> nil then
      FFonts.Add(AName, Result);
  end;
end;

function TPDFFormResources.GetXObject(const AName: string): TPDFStream;
begin
  var O := Lookup('XObject', AName);
  if (O <> nil) and O.IsStream then
    Result := TPDFStream(O)
  else
    Result := nil;
end;

function TPDFFormResources.GetColorSpace(const AName: string): TPDFColorSpace;
begin
  if FCS.TryGetValue(AName, Result) then Exit;
  if AName = 'DeviceGray' then Exit(TPDFDeviceGray.Create);
  if AName = 'DeviceRGB'  then Exit(TPDFDeviceRGB.Create);
  if AName = 'DeviceCMYK' then Exit(TPDFDeviceCMYK.Create);
  Result := nil;
  var O := Lookup('ColorSpace', AName);
  if O <> nil then
  begin
    Result := TPDFColorSpaceFactory.Build(O, FPage.Document.Resolver);
    if Result <> nil then
      FCS.Add(AName, Result);
  end;
end;

function TPDFFormResources.GetExtGState(const AName: string): TPDFDictionary;
begin
  var O := Lookup('ExtGState', AName);
  if (O <> nil) and O.IsDictionary then
    Result := TPDFDictionary(O)
  else
    Result := nil;
end;

function TPDFFormResources.GetPattern(const AName: string): TPDFObject;
begin
  Result := Lookup('Pattern', AName);
end;

function TPDFFormResources.GetShading(const AName: string): TPDFObject;
begin
  Result := Lookup('Shading', AName);
end;

{ TPDFDocumentRedactor }

constructor TPDFDocumentRedactor.Create(ADoc: TPDFDocument);
begin
  inherited Create;
  FDoc := ADoc;
  FDone := TDictionary<TPDFStream, Boolean>.Create;
  JpegQuality := 90;
end;

destructor TPDFDocumentRedactor.Destroy;
begin
  FDone.Free;
  inherited;
end;

procedure TPDFDocumentRedactor.Problem(APage: Integer; const AMsg: string);
begin
  FReport.Problems := FReport.Problems + ['página ' + IntToStr(APage + 1) + ': ' + AMsg];
end;

function TPDFDocumentRedactor.ToPage(APage: TPDFPage; const P: TPointF): TPointF;
var
  Crop: TPDFRect;
begin
  Crop := APage.CropBox;
  Result.X := (P.X - Crop.LLX) / Crop.Width;
  Result.Y := (Crop.URY - P.Y) / Crop.Height;
end;

function TPDFDocumentRedactor.BoundsOf(APage: TPDFPage; const AM: TPDFMatrix;
  const ARect: TPDFRect): TRectF;
var
  Pts: array[0..3] of TPointF;
  I: Integer;
begin
  Pts[0] := ToPage(APage, AM.Transform(TPointF.Create(ARect.LLX, ARect.LLY)));
  Pts[1] := ToPage(APage, AM.Transform(TPointF.Create(ARect.URX, ARect.LLY)));
  Pts[2] := ToPage(APage, AM.Transform(TPointF.Create(ARect.LLX, ARect.URY)));
  Pts[3] := ToPage(APage, AM.Transform(TPointF.Create(ARect.URX, ARect.URY)));
  Result := TRectF.Create(Pts[0].X, Pts[0].Y, Pts[0].X, Pts[0].Y);
  for I := 1 to 3 do
  begin
    Result.Left   := Min(Result.Left, Pts[I].X);
    Result.Right  := Max(Result.Right, Pts[I].X);
    Result.Top    := Min(Result.Top, Pts[I].Y);
    Result.Bottom := Max(Result.Bottom, Pts[I].Y);
  end;
end;

function TPDFDocumentRedactor.Touches(const R: TRectF;
  const ABoxes: TArray<TRectF>): Boolean;
begin
  for var B in ABoxes do
    if (R.Left <= B.Right) and (R.Right >= B.Left) and
       (R.Top <= B.Bottom) and (R.Bottom >= B.Top) then
      Exit(True);
  Result := False;
end;

procedure TPDFDocumentRedactor.WalkXObjects(APage: TPDFPage; APageIndex: Integer;
  const AData: TBytes; AResDict: TPDFDictionary; const ABase: TPDFMatrix;
  const ABoxes: TArray<TRectF>; ADepth: Integer);
var
  Proc: TPDFContentStreamProcessor;
  Res:  IPDFResources;
  Run:  TBytes;
  Hits: TList<TPair<TPDFStream, TPDFMatrix>>;
begin
  if ADepth > 16 then
  begin
    Problem(APageIndex, 'formularios anidados de más');
    Exit;
  end;
  Run := AData;
  if not ABase.IsIdentity then
    Run := TEncoding.ASCII.GetBytes(
      FormatFloat('0.######', ABase.A, TFormatSettings.Invariant) + ' ' +
      FormatFloat('0.######', ABase.B, TFormatSettings.Invariant) + ' ' +
      FormatFloat('0.######', ABase.C, TFormatSettings.Invariant) + ' ' +
      FormatFloat('0.######', ABase.D, TFormatSettings.Invariant) + ' ' +
      FormatFloat('0.######', ABase.E, TFormatSettings.Invariant) + ' ' +
      FormatFloat('0.######', ABase.F, TFormatSettings.Invariant) + ' cm'#10) + AData;
  Res := TPDFFormResources.Create(APage, AResDict);
  Hits := TList<TPair<TPDFStream, TPDFMatrix>>.Create;
  Proc := TPDFContentStreamProcessor.Create;
  try
    Proc.OnPaintXObject :=
      procedure(const AName: string; const AM: TPDFMatrix; const AState: TPDFGraphicsState)
      begin
        var S := Res.GetXObject(AName);
        if S <> nil then
          Hits.Add(TPair<TPDFStream, TPDFMatrix>.Create(S, AState.CTM));
      end;
    Proc.OnPaintInlineImage :=
      procedure(const ADict: TPDFDictionary; const AImg: TBytes; const AState: TPDFGraphicsState)
      begin
        if Touches(BoundsOf(APage, AState.CTM, TPDFRect.Make(0, 0, 1, 1)), ABoxes) then
          Problem(APageIndex, 'una imagen en línea (BI…EI) bajo un recuadro');
      end;
    Proc.Process(Run, Res, FDoc.Resolver);
    // después de recorrer: cambiar un flujo mientras se recorre no es seguro
    for var H in Hits do
    begin
      var Sub := H.Key.Dict.GetAsName('Subtype');
      if Sub = 'Image' then
      begin
        if Touches(BoundsOf(APage, H.Value, TPDFRect.Make(0, 0, 1, 1)), ABoxes) then
          RedactImage(APage, APageIndex, H.Key, H.Value, ABoxes);
      end
      else if Sub = 'Form' then
      begin
        var FM := H.Key.Dict.GetMatrix('Matrix').Concat(H.Value);
        var BB: TPDFRect;
        if H.Key.Dict.Contains('BBox') then
          BB := H.Key.Dict.GetRect('BBox')
        else
          BB := APage.MediaBox;
        if Touches(BoundsOf(APage, FM, BB), ABoxes) then
          RedactForm(APage, APageIndex, H.Key, FM, ABoxes, ADepth + 1);
      end;
    end;
  finally
    Proc.Free;
    Hits.Free;
  end;
end;

procedure TPDFDocumentRedactor.RedactForm(APage: TPDFPage; APageIndex: Integer;
  AStm: TPDFStream; const AM: TPDFMatrix; const ABoxes: TArray<TRectF>;
  ADepth: Integer);
var
  Data, NewData: TBytes;
  N: Integer;
begin
  Data := AStm.DecodedBytes;
  var ResDict := AStm.Dict.GetAsDictionary('Resources');
  var Res: IPDFResources := TPDFFormResources.Create(APage, ResDict);
  if not TPDFRedactor.RemoveTextInContent(APage, Data, Res, AM, ABoxes, NewData, N) then
    Problem(APageIndex, 'texto de un formulario que no se puede quitar con seguridad')
  else if N > 0 then
  begin
    Inc(FReport.Glyphs, N);
    Inc(FReport.Forms);
    var Z := PDFDeflate(NewData);
    AStm.SetRawData(Z);
    AStm.Dict.SetValue('Filter', TPDFName.Create('FlateDecode'));
    AStm.Dict.Remove('DecodeParms');
    AStm.Dict.SetValue('Length', TPDFInteger.Create(Length(Z)));
    AStm.InvalidateCache;
    Data := NewData;
  end;
  // lo que el formulario pinta adentro (imágenes, otros formularios)
  WalkXObjects(APage, APageIndex, Data, ResDict, AM, ABoxes, ADepth);
end;

procedure TPDFDocumentRedactor.RedactImage(APage: TPDFPage; APageIndex: Integer;
  AStm: TPDFStream; const ACTM: TPDFMatrix; const ABoxes: TArray<TRectF>);
var
  Img: TPDFImage;
  W, H, Comps, X, Y, X0, X1, Y0, Y1: Integer;
  Pix, Alpha, Out: TBytes;
  Inv: TPDFMatrix;
  IsJpeg, IsMask, Changed: Boolean;

  // ¿el píxel (X, Y) (Y desde arriba) toca algún recuadro?
  function PixelTouches(PX, PY: Integer): Boolean;
  var
    Pts: array[0..3] of TPointF;
    R: TRectF;
  begin
    Pts[0] := ToPage(APage, ACTM.Transform(TPointF.Create(PX / W, 1 - PY / H)));
    Pts[1] := ToPage(APage, ACTM.Transform(TPointF.Create((PX + 1) / W, 1 - PY / H)));
    Pts[2] := ToPage(APage, ACTM.Transform(TPointF.Create(PX / W, 1 - (PY + 1) / H)));
    Pts[3] := ToPage(APage, ACTM.Transform(TPointF.Create((PX + 1) / W, 1 - (PY + 1) / H)));
    R := TRectF.Create(Pts[0].X, Pts[0].Y, Pts[0].X, Pts[0].Y);
    for var K := 1 to 3 do
    begin
      R.Left := Min(R.Left, Pts[K].X);
      R.Right := Max(R.Right, Pts[K].X);
      R.Top := Min(R.Top, Pts[K].Y);
      R.Bottom := Max(R.Bottom, Pts[K].Y);
    end;
    Result := Touches(R, ABoxes);
  end;

  // los píxeles de la imagen que tocan los recuadros: se recorre solo el
  // rango que cada recuadro ocupa en la imagen
  procedure Paint(AProc: TProc<Integer, Integer>);
  var
    Crop: TPDFRect;
  begin
    Crop := APage.CropBox;
    for var B in ABoxes do
    begin
      var MinX := MaxDouble; var MaxX := -MaxDouble;
      var MinY := MaxDouble; var MaxY := -MaxDouble;
      var Corners: array[0..3] of TPointF;
      Corners[0] := TPointF.Create(B.Left, B.Top);
      Corners[1] := TPointF.Create(B.Right, B.Top);
      Corners[2] := TPointF.Create(B.Left, B.Bottom);
      Corners[3] := TPointF.Create(B.Right, B.Bottom);
      for var C in Corners do
      begin
        // normalizado -> página -> espacio de la imagen (cuadrado unidad)
        var U := Inv.Transform(TPointF.Create(Crop.LLX + C.X * Crop.Width,
          Crop.URY - C.Y * Crop.Height));
        MinX := Min(MinX, U.X * W); MaxX := Max(MaxX, U.X * W);
        MinY := Min(MinY, (1 - U.Y) * H); MaxY := Max(MaxY, (1 - U.Y) * H);
      end;
      X0 := Max(0, Floor(MinX) - 1); X1 := Min(W - 1, Ceil(MaxX) + 1);
      Y0 := Max(0, Floor(MinY) - 1); Y1 := Min(H - 1, Ceil(MaxY) + 1);
      for var PY := Y0 to Y1 do
        for var PX := X0 to X1 do
          if PixelTouches(PX, PY) then
            AProc(PX, PY);
    end;
  end;

begin
  if FDone.ContainsKey(AStm) then
  begin
    // compartida y ya reescrita: se vuelve a tachar con las zonas de aquí
    // (la imagen reescrita es Flate o JPEG, que sí se decodifican)
  end;
  W := AStm.Dict.GetAsInteger('Width');
  H := AStm.Dict.GetAsInteger('Height');
  if (W <= 0) or (H <= 0) then Exit;
  Inv := ACTM.Inverse;
  IsMask := AStm.Dict.GetAsBoolean('ImageMask');
  var Filters: TArray<string>;
  var F := AStm.Dict.Get('Filter');
  if (F <> nil) and F.IsName then
    Filters := [F.AsName]
  else if (F <> nil) and F.IsArray then
    for var I := 0 to TPDFArray(F).Count - 1 do
      Filters := Filters + [TPDFArray(F).GetAsName(I)];
  IsJpeg := (Length(Filters) > 0) and (Filters[High(Filters)] = 'DCTDecode');

  Changed := False;
  if IsJpeg and not IsMask then
  begin
    if (Length(Filters) <> 1) or not Assigned(JpegDecode) or not Assigned(JpegEncode) then
    begin
      Problem(APageIndex, 'una imagen JPEG bajo un recuadro y no hay códec JPEG');
      Exit;
    end;
    if not JpegDecode(AStm.RawBytes, Pix, W, H, Comps) or not (Comps in [1, 3]) then
    begin
      Problem(APageIndex, 'una imagen JPEG que no se pudo decodificar (¿CMYK?)');
      Exit;
    end;
    Paint(procedure(PX, PY: Integer)
      begin
        FillChar(Pix[(PY * W + PX) * Comps], Comps, 0);
        Changed := True;
      end);
    if not Changed then Exit;
    if not JpegEncode(Pix, W, H, Comps, Out) then
    begin
      Problem(APageIndex, 'no se pudo volver a codificar una imagen JPEG');
      Exit;
    end;
    AStm.SetRawData(Out);
    AStm.Dict.SetValue('Filter', TPDFName.Create('DCTDecode'));
    if Comps = 1 then
      AStm.Dict.SetValue('ColorSpace', TPDFName.Create('DeviceGray'))
    else
      AStm.Dict.SetValue('ColorSpace', TPDFName.Create('DeviceRGB'));
  end
  else
  begin
    Img := TPDFImage.FromXObject(AStm, FDoc.Resolver);
    if Img = nil then
    begin
      Problem(APageIndex, 'una imagen que no se pudo leer');
      Exit;
    end;
    try
      Img.Decode;
      if IsMask then
        Pix := Img.ToStencilRGBA(0, 0, 0, 255)
      else
        Pix := Img.ToRGBA;
      if Length(Pix) <> W * H * 4 then
      begin
        Problem(APageIndex, 'una imagen bajo un recuadro en un formato que no se ' +
          'puede decodificar (JPEG 2000, JBIG2...)');
        Exit;
      end;
      if IsMask then
      begin
        // máscara: lo tachado deja de pintarse (1 = no pinta, Decode [0 1])
        Paint(procedure(PX, PY: Integer)
          begin
            Pix[(PY * W + PX) * 4 + 3] := 0;
            Changed := True;
          end);
        if not Changed then Exit;
        var RowBytes := (W + 7) div 8;
        SetLength(Out, RowBytes * H);
        FillChar(Out[0], Length(Out), 0);
        for Y := 0 to H - 1 do
          for X := 0 to W - 1 do
            if Pix[(Y * W + X) * 4 + 3] < 128 then
              Out[Y * RowBytes + X div 8] := Out[Y * RowBytes + X div 8] or (128 shr (X mod 8));
        Out := PDFDeflate(Out);
        AStm.SetRawData(Out);
        AStm.Dict.SetValue('Filter', TPDFName.Create('FlateDecode'));
        AStm.Dict.SetValue('BitsPerComponent', TPDFInteger.Create(1));
        AStm.Dict.Remove('Decode');
      end
      else
      begin
        Comps := 3;
        if Img.Info.IsGrayscale or (Img.Info.ComponentCount = 1) and
           (Img.Info.ColorSpaceName = 'DeviceGray') then
          Comps := 1;
        Paint(procedure(PX, PY: Integer)
          begin
            var K := (PY * W + PX) * 4;
            Pix[K] := 0; Pix[K + 1] := 0; Pix[K + 2] := 0; Pix[K + 3] := 255;
            Changed := True;
          end);
        if not Changed then Exit;
        SetLength(Out, W * H * Comps);
        for var I := 0 to W * H - 1 do
          if Comps = 1 then
            Out[I] := Pix[I * 4]
          else
          begin
            Out[I * 3] := Pix[I * 4];
            Out[I * 3 + 1] := Pix[I * 4 + 1];
            Out[I * 3 + 2] := Pix[I * 4 + 2];
          end;
        // la máscara suave: opaca bajo lo tachado (el negro se ve)
        if AStm.Dict.Contains('SMask') then
        begin
          var SM := AStm.Dict.Get('SMask');
          if Img.MaskAlpha(W, H, Alpha) and (SM <> nil) and SM.IsStream then
          begin
            Paint(procedure(PX, PY: Integer)
              begin
                Alpha[PY * W + PX] := 255;
              end);
            var SS := TPDFStream(SM);
            var Z := PDFDeflate(Alpha);
            SS.SetRawData(Z);
            SS.Dict.SetValue('Filter', TPDFName.Create('FlateDecode'));
            SS.Dict.Remove('DecodeParms');
            SS.Dict.Remove('Decode');
            SS.Dict.SetValue('Width', TPDFInteger.Create(W));
            SS.Dict.SetValue('Height', TPDFInteger.Create(H));
            SS.Dict.SetValue('BitsPerComponent', TPDFInteger.Create(8));
            SS.Dict.SetValue('ColorSpace', TPDFName.Create('DeviceGray'));
            SS.Dict.SetValue('Length', TPDFInteger.Create(Length(Z)));
            SS.InvalidateCache;
          end
          else
            AStm.Dict.Remove('SMask');
        end;
        Out := PDFDeflate(Out);
        AStm.SetRawData(Out);
        AStm.Dict.SetValue('Filter', TPDFName.Create('FlateDecode'));
        AStm.Dict.SetValue('BitsPerComponent', TPDFInteger.Create(8));
        if Comps = 1 then
          AStm.Dict.SetValue('ColorSpace', TPDFName.Create('DeviceGray'))
        else
          AStm.Dict.SetValue('ColorSpace', TPDFName.Create('DeviceRGB'));
        AStm.Dict.Remove('Decode');
        AStm.Dict.Remove('Mask');
      end;
    finally
      Img.Free;
    end;
  end;
  AStm.Dict.Remove('DecodeParms');
  AStm.Dict.Remove('Alternates');
  AStm.Dict.Remove('Metadata');
  AStm.Dict.SetValue('Width', TPDFInteger.Create(W));
  AStm.Dict.SetValue('Height', TPDFInteger.Create(H));
  AStm.Dict.SetValue('Length', TPDFInteger.Create(Length(AStm.RawBytes)));
  AStm.InvalidateCache;
  FDone.AddOrSetValue(AStm, True);
  Inc(FReport.Images);
end;

procedure TPDFDocumentRedactor.RemoveAnnotations(APage: TPDFPage;
  const ABoxes: TArray<TRectF>);
begin
  var A := APage.Dict.GetAsArray('Annots');
  if A = nil then Exit;
  var Removed := 0;
  for var I := A.Count - 1 downto 0 do
  begin
    var Annot := A.Get(I);
    var Drop := False;
    if (Annot <> nil) and Annot.IsDictionary then
    begin
      var R := TPDFDictionary(Annot).GetRect('Rect');
      Drop := Touches(BoundsOf(APage, TPDFMatrix.Identity, R), ABoxes);
    end;
    if Drop then
    begin
      A.Delete(I);
      Inc(Removed);
    end;
  end;
  Inc(FReport.Annotations, Removed);
end;

procedure TPDFDocumentRedactor.CleanDocument;
begin
  var Cat := FDoc.Catalog;
  if Cat <> nil then
    for var K in ['Metadata', 'AcroForm', 'Names', 'OpenAction', 'AA', 'Outlines',
                  'PieceInfo', 'StructTreeRoot', 'MarkInfo', 'Threads', 'SpiderInfo',
                  'Perms', 'Legal', 'Collection', 'Dests'] do
      Cat.Remove(K);
  for var I := 0 to FDoc.PageCount - 1 do
    for var K in ['Thumb', 'PieceInfo', 'Metadata', 'AA', 'StructParents', 'B'] do
      FDoc.Pages[I].Dict.Remove(K);
  // Info: solo el productor
  var Info := FDoc.Trailer.Get('Info');
  if (Info <> nil) and Info.IsDictionary then
    for var K in TPDFDictionary(Info).Keys do
      TPDFDictionary(Info).Remove(K);
  FDoc.Producer := 'MakerDocs (versión pública)';
end;

function TPDFDocumentRedactor.Redact(const AZones: TArray<TPDFRedactZone>;
  ACleanDocument: Boolean): TPDFRedactReport;
var
  Pages: TDictionary<Integer, TArray<TRectF>>;
begin
  FReport := Default(TPDFRedactReport);
  Pages := TDictionary<Integer, TArray<TRectF>>.Create;
  try
    for var Z in AZones do
    begin
      if (Z.PageIndex < 0) or (Z.PageIndex >= FDoc.PageCount) then
      begin
        FReport.Problems := FReport.Problems + ['no existe la página ' + IntToStr(Z.PageIndex + 1)];
        Continue;
      end;
      var L: TArray<TRectF>;
      if not Pages.TryGetValue(Z.PageIndex, L) then
        L := nil;
      Pages.AddOrSetValue(Z.PageIndex, L + [Z.Box]);
    end;
    for var P in Pages do
    begin
      var Page := FDoc.Pages[P.Key];
      var Boxes := P.Value;
      if (Page.Rotation mod 360) <> 0 then
      begin
        Problem(P.Key, 'página girada (/Rotate)');
        Continue;
      end;
      if (Page.CropBox.Width <= 0) or (Page.CropBox.Height <= 0) then
      begin
        Problem(P.Key, 'página sin tamaño');
        Continue;
      end;
      var Data := Page.ContentStreamBytes;
      // 1. lo que pintan sus imágenes y formularios
      WalkXObjects(Page, P.Key, Data, nil, TPDFMatrix.Identity, Boxes, 0);
      // 2. el texto de la página
      var N: Integer;
      if not TPDFRedactor.RemovePageTextLayer(FDoc, P.Key, Boxes, N,
           TPDFRedactBoxSpace.Page) then
        Problem(P.Key, 'texto que no se puede quitar con seguridad (operadores '' o ", ' +
          'letra de tamaño 0)')
      else
        Inc(FReport.Glyphs, N);
      // 3. anotaciones sobre los recuadros
      RemoveAnnotations(Page, Boxes);
      // 4. el recuadro negro encima, en el espacio de la página
      var Crop := Page.CropBox;
      var SB := TStringBuilder.Create;
      try
        SB.Append('q 0 g 0 G'#10);
        for var B in Boxes do
          SB.Append(FormatFloat('0.###', Crop.LLX + B.Left * Crop.Width, TFormatSettings.Invariant))
            .Append(' ')
            .Append(FormatFloat('0.###', Crop.URY - B.Bottom * Crop.Height, TFormatSettings.Invariant))
            .Append(' ')
            .Append(FormatFloat('0.###', (B.Right - B.Left) * Crop.Width, TFormatSettings.Invariant))
            .Append(' ')
            .Append(FormatFloat('0.###', (B.Bottom - B.Top) * Crop.Height, TFormatSettings.Invariant))
            .Append(' re f'#10);
        SB.Append('Q'#10);
        Page.AppendContent(TEncoding.ASCII.GetBytes(SB.ToString));
      finally
        SB.Free;
      end;
    end;
    if ACleanDocument then
      CleanDocument;
  finally
    Pages.Free;
  end;
  Result := FReport;
end;

class function TPDFDocumentRedactor.TextInZones(ADoc: TPDFDocument;
  const AZones: TArray<TPDFRedactZone>): string;
var
  SB: TStringBuilder;

  procedure Scan(APage: TPDFPage; const AData: TBytes; AResDict: TPDFDictionary;
    const ABase: TPDFMatrix; const ABoxes: TArray<TRectF>; ADepth: Integer);
  var
    Proc: TPDFContentStreamProcessor;
    Run:  TBytes;
    Forms: TList<TPair<TPDFStream, TPDFMatrix>>;
  begin
    if ADepth > 16 then Exit;
    Run := AData;
    if not ABase.IsIdentity then
      Run := TEncoding.ASCII.GetBytes(
        FormatFloat('0.######', ABase.A, TFormatSettings.Invariant) + ' ' +
        FormatFloat('0.######', ABase.B, TFormatSettings.Invariant) + ' ' +
        FormatFloat('0.######', ABase.C, TFormatSettings.Invariant) + ' ' +
        FormatFloat('0.######', ABase.D, TFormatSettings.Invariant) + ' ' +
        FormatFloat('0.######', ABase.E, TFormatSettings.Invariant) + ' ' +
        FormatFloat('0.######', ABase.F, TFormatSettings.Invariant) + ' cm'#10) + AData;
    var Res: IPDFResources := TPDFFormResources.Create(APage, AResDict);
    Forms := TList<TPair<TPDFStream, TPDFMatrix>>.Create;
    Proc := TPDFContentStreamProcessor.Create;
    try
      Proc.OnPaintGlyph :=
        procedure(const G: TPDFGlyphInfo; const St: TPDFGraphicsState)
        begin
          var C := TPDFRedactor.GlyphCenter(G, St, APage, TPDFRedactBoxSpace.Page);
          for var B in ABoxes do
            if (C.X >= B.Left) and (C.X <= B.Right) and (C.Y >= B.Top) and (C.Y <= B.Bottom) then
            begin
              if G.Font <> nil then
                SB.Append(G.Font.CharCodeToUnicode(G.CharCode))
              else
                SB.Append('?');
              Break;
            end;
        end;
      Proc.OnPaintXObject :=
        procedure(const AName: string; const AM: TPDFMatrix; const AState: TPDFGraphicsState)
        begin
          var S := Res.GetXObject(AName);
          if (S <> nil) and (S.Dict.GetAsName('Subtype') = 'Form') then
            Forms.Add(TPair<TPDFStream, TPDFMatrix>.Create(S,
              S.Dict.GetMatrix('Matrix').Concat(AState.CTM)));
        end;
      Proc.Process(Run, Res, ADoc.Resolver);
      for var F in Forms do
        Scan(APage, F.Key.DecodedBytes, F.Key.Dict.GetAsDictionary('Resources'),
          F.Value, ABoxes, ADepth + 1);
    finally
      Proc.Free;
      Forms.Free;
    end;
  end;

begin
  SB := TStringBuilder.Create;
  try
    for var Z in AZones do
      if (Z.PageIndex >= 0) and (Z.PageIndex < ADoc.PageCount) then
      begin
        var Page := ADoc.Pages[Z.PageIndex];
        Scan(Page, Page.ContentStreamBytes, nil, TPDFMatrix.Identity, [Z.Box], 0);
      end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

end.
