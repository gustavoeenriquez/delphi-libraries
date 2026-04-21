unit uPDF.Watermark;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Document,
  uPDF.Writer, uPDF.PageCopy;

type
  // -------------------------------------------------------------------------
  // Placement: on top of existing content (Overlay) or beneath it (Underlay).
  // -------------------------------------------------------------------------
  TPDFWatermarkMode = (Overlay, Underlay);

  // -------------------------------------------------------------------------
  // Common watermark options
  // -------------------------------------------------------------------------
  TPDFWatermarkOptions = record
    Mode:     TPDFWatermarkMode;
    Opacity:  Single;   // 0.0 (invisible) … 1.0 (opaque). Default 0.30
    Rotation: Single;   // CCW degrees applied to text watermark. Default 45
    class function Default: TPDFWatermarkOptions; static;
  end;

  // -------------------------------------------------------------------------
  // TPDFWatermark
  //
  // Applies a text or JPEG-image watermark to every page of a PDF document
  // and writes the result to a stream or file.
  //
  // Each watermark is implemented as a self-contained Form XObject that is
  // registered in the page's /Resources and invoked from a small injected
  // content stream (overlay) or prepended to the existing streams (underlay).
  //
  // Text usage:
  //   var Opts := TPDFWatermarkOptions.Default;
  //   TPDFWatermark.ApplyText(Doc, 'CONFIDENTIAL', 'Helvetica', 48,
  //                           0.5, 0.5, 0.5, Opts, OutStream);
  //
  // Image usage:
  //   TPDFWatermark.ApplyImage(Doc, JpegBytes, 640, 480,
  //                            100, 100, 300, 225, Opts, OutStream);
  // -------------------------------------------------------------------------
  TPDFWatermark = class
  private
    // ---- Helpers ----

    class function  AllocNum(var ANext: Integer): Integer; static; inline;

    // Serialise all copied pages + pool into a complete PDF on AOutput.
    class procedure BuildAndWrite(
      const APages: TArray<TPDFDictionary>;
      AObjects:     TObjectDictionary<Integer, TPDFObject>;
      ANextObjNum:  Integer;
      AOutput:      TStream); static;

    // Return the /Resources dict from a page dict.
    // Follows one level of indirection via AObjects if /Resources is a reference.
    // Creates and inserts a new inline dict if absent.
    class function EnsurePageResources(
      APageDict: TPDFDictionary;
      AObjects:  TObjectDictionary<Integer, TPDFObject>): TPDFDictionary; static;

    // Return a sub-dict (e.g. /XObject) from AParent, following one reference
    // level if needed.  Creates and inserts a new inline dict if absent.
    class function EnsureSubDict(
      AParent:  TPDFDictionary;
      const AKey: string;
      AObjects: TObjectDictionary<Integer, TPDFObject>): TPDFDictionary; static;

    // Build the raw content stream bytes for a text watermark Form XObject.
    class function BuildTextFormBytes(
      APageW, APageH,
      AFontSize, AR, AG, AB, ARotation: Single;
      const AText: string): TBytes; static;

    // Build the raw content stream bytes for an image watermark Form XObject.
    class function BuildImageFormBytes(
      AX, AY, AWidth, AHeight: Single): TBytes; static;

    // Create a Form XObject stream in AObjects and return its object number.
    // AFontName = '' means no /Font resource (image watermark).
    // AImgNum  = 0 means no /XObject resource (text watermark).
    class function AddFormXObject(
      AObjects:          TObjectDictionary<Integer, TPDFObject>;
      var ANext:         Integer;
      const AFormBytes:  TBytes;
      APageW, APageH:    Single;
      const AFontName:   string;
      AImgNum:           Integer;
      AOpacity:          Single): Integer; static;

    // Register the Form XObject on the page and inject the invocation stream.
    class procedure InjectWatermark(
      APageDict: TPDFDictionary;
      AObjects:  TObjectDictionary<Integer, TPDFObject>;
      var ANext: Integer;
      AFormNum:  Integer;
      AMode:     TPDFWatermarkMode); static;

  public
    // ---- Text watermark ----

    // Full version: font, size, RGB color and all options explicit.
    // AFontName should be a standard Type 1 base font (e.g. 'Helvetica').
    // AR, AG, AB are fill-color components in [0, 1].
    class procedure ApplyText(
      ASource:         TPDFDocument;
      const AText:     string;
      const AFontName: string;
      AFontSize:       Single;
      AR, AG, AB:      Single;
      const AOptions:  TPDFWatermarkOptions;
      AOutput:         TStream); overload; static;

    class procedure ApplyText(
      ASource:         TPDFDocument;
      const AText:     string;
      const AFontName: string;
      AFontSize:       Single;
      AR, AG, AB:      Single;
      const AOptions:  TPDFWatermarkOptions;
      const APath:     string); overload; static;

    // Convenience: Helvetica 48 pt, 50% gray, 45° rotation, 30% opacity, overlay.
    class procedure ApplyText(
      ASource:     TPDFDocument;
      const AText: string;
      AOutput:     TStream); overload; static;

    class procedure ApplyText(
      ASource:     TPDFDocument;
      const AText: string;
      const APath: string); overload; static;

    // ---- Image watermark (JPEG) ----

    // AJpegBytes        : raw JPEG file bytes.
    // AImgPixelWidth/H  : pixel dimensions declared in the image XObject dict.
    // AX, AY            : lower-left corner in page user-space points.
    // AWidth, AHeight   : display size in page user-space points.
    class procedure ApplyImage(
      ASource:               TPDFDocument;
      const AJpegBytes:      TBytes;
      AImgPixelWidth,
      AImgPixelHeight:       Integer;
      AX, AY,
      AWidth, AHeight:       Single;
      const AOptions:        TPDFWatermarkOptions;
      AOutput:               TStream); overload; static;

    class procedure ApplyImage(
      ASource:               TPDFDocument;
      const AJpegBytes:      TBytes;
      AImgPixelWidth,
      AImgPixelHeight:       Integer;
      AX, AY,
      AWidth, AHeight:       Single;
      const AOptions:        TPDFWatermarkOptions;
      const APath:           string); overload; static;
  end;

implementation

// ===========================================================================
// TPDFWatermarkOptions
// ===========================================================================

class function TPDFWatermarkOptions.Default: TPDFWatermarkOptions;
begin
  Result.Mode     := TPDFWatermarkMode.Overlay;
  Result.Opacity  := 0.30;
  Result.Rotation := 45;
end;

// ===========================================================================
// TPDFWatermark — private helpers
// ===========================================================================

class function TPDFWatermark.AllocNum(var ANext: Integer): Integer;
begin
  Result := ANext;
  Inc(ANext);
end;

// ---------------------------------------------------------------------------
// BuildAndWrite
// ---------------------------------------------------------------------------

class procedure TPDFWatermark.BuildAndWrite(
  const APages: TArray<TPDFDictionary>;
  AObjects:     TObjectDictionary<Integer, TPDFObject>;
  ANextObjNum:  Integer;
  AOutput:      TStream);
var
  NextNum:   Integer;
  PageNums:  TArray<Integer>;
  PagesNum:  Integer;
  CatNum:    Integer;
  PagesDict: TPDFDictionary;
  KidsArr:   TPDFArray;
  CatDict:   TPDFDictionary;
  I:         Integer;
  Writer:    TPDFWriter;
begin
  NextNum := ANextObjNum;

  SetLength(PageNums, Length(APages));
  for I := 0 to High(APages) do
  begin
    PageNums[I] := NextNum;
    Inc(NextNum);
  end;

  PagesNum  := NextNum; Inc(NextNum);
  PagesDict := TPDFDictionary.Create;
  PagesDict.SetValue('Type',  TPDFName.Create('Pages'));
  PagesDict.SetValue('Count', TPDFInteger.Create(Length(APages)));
  KidsArr := TPDFArray.Create;
  for I := 0 to High(APages) do
    KidsArr.Add(TPDFReference.CreateNum(PageNums[I], 0));
  PagesDict.SetValue('Kids', KidsArr);
  AObjects.AddOrSetValue(PagesNum, PagesDict);

  for I := 0 to High(APages) do
  begin
    APages[I].SetValue('Parent', TPDFReference.CreateNum(PagesNum, 0));
    AObjects.AddOrSetValue(PageNums[I], APages[I]);
  end;

  CatNum  := NextNum; Inc(NextNum);
  CatDict := TPDFDictionary.Create;
  CatDict.SetValue('Type',  TPDFName.Create('Catalog'));
  CatDict.SetValue('Pages', TPDFReference.CreateNum(PagesNum, 0));
  AObjects.AddOrSetValue(CatNum, CatDict);

  Writer := TPDFWriter.Create(AOutput, TPDFWriteOptions.Default);
  try
    Writer.WriteFull(CatDict, nil, AObjects);
  finally
    Writer.Free;
  end;
end;

// ---------------------------------------------------------------------------
// EnsurePageResources
// ---------------------------------------------------------------------------

class function TPDFWatermark.EnsurePageResources(
  APageDict: TPDFDictionary;
  AObjects:  TObjectDictionary<Integer, TPDFObject>): TPDFDictionary;
var
  Raw: TPDFObject;
  Obj: TPDFObject;
begin
  Raw := APageDict.RawGet('Resources');
  if Raw <> nil then
  begin
    if Raw.IsDictionary then
      Exit(TPDFDictionary(Raw));
    if Raw.IsReference then
      if AObjects.TryGetValue(TPDFReference(Raw).RefID.Number, Obj)
         and Obj.IsDictionary then
        Exit(TPDFDictionary(Obj));
  end;
  Result := TPDFDictionary.Create;
  APageDict.SetValue('Resources', Result);
end;

// ---------------------------------------------------------------------------
// EnsureSubDict
// ---------------------------------------------------------------------------

class function TPDFWatermark.EnsureSubDict(
  AParent:  TPDFDictionary;
  const AKey: string;
  AObjects: TObjectDictionary<Integer, TPDFObject>): TPDFDictionary;
var
  Raw: TPDFObject;
  Obj: TPDFObject;
begin
  Raw := AParent.RawGet(AKey);
  if Raw <> nil then
  begin
    if Raw.IsDictionary then
      Exit(TPDFDictionary(Raw));
    if Raw.IsReference then
      if AObjects.TryGetValue(TPDFReference(Raw).RefID.Number, Obj)
         and Obj.IsDictionary then
        Exit(TPDFDictionary(Obj));
  end;
  Result := TPDFDictionary.Create;
  AParent.SetValue(AKey, Result);
end;

// ---------------------------------------------------------------------------
// BuildTextFormBytes
//
// Produces the content stream for a text Form XObject.
// The text baseline is placed at the page centre, rotated by ARotation°.
// ---------------------------------------------------------------------------

class function TPDFWatermark.BuildTextFormBytes(
  APageW, APageH,
  AFontSize, AR, AG, AB, ARotation: Single;
  const AText: string): TBytes;
var
  SB:      TStringBuilder;
  CX, CY:  Single;
  Co, Si:  Double;
begin
  CX := APageW / 2;
  CY := APageH / 2;
  Co := Cos(Double(ARotation) * Pi / 180);
  Si := Sin(Double(ARotation) * Pi / 180);

  SB := TStringBuilder.Create;
  try
    SB.AppendLine('q');
    SB.AppendLine('/WmGS gs');
    SB.AppendLine('BT');
    SB.AppendLine(Format('/WmFont %s Tf', [PDFRealToStr(AFontSize)]));
    SB.AppendLine(Format('%s %s %s rg',
      [PDFRealToStr(AR), PDFRealToStr(AG), PDFRealToStr(AB)]));
    SB.AppendLine(Format('%s %s %s %s %s %s Tm',
      [PDFRealToStr(Single(Co)),  PDFRealToStr(Single(Si)),
       PDFRealToStr(Single(-Si)), PDFRealToStr(Single(Co)),
       PDFRealToStr(CX),          PDFRealToStr(CY)]));
    SB.AppendLine(Format('(%s) Tj', [PDFEscapeString(AText)]));
    SB.AppendLine('ET');
    SB.AppendLine('Q');
    Result := TEncoding.ASCII.GetBytes(SB.ToString);
  finally
    SB.Free;
  end;
end;

// ---------------------------------------------------------------------------
// BuildImageFormBytes
//
// Produces the content stream for an image Form XObject.
// Places the image at (AX, AY) scaled to AWidth × AHeight in page units.
// ---------------------------------------------------------------------------

class function TPDFWatermark.BuildImageFormBytes(
  AX, AY, AWidth, AHeight: Single): TBytes;
var
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    SB.AppendLine('q');
    SB.AppendLine('/WmGS gs');
    // [a b c d e f] cm where [AWidth 0 0 AHeight AX AY] scales + translates
    SB.AppendLine(Format('%s 0 0 %s %s %s cm',
      [PDFRealToStr(AWidth), PDFRealToStr(AHeight),
       PDFRealToStr(AX), PDFRealToStr(AY)]));
    SB.AppendLine('/WmImg Do');
    SB.AppendLine('Q');
    Result := TEncoding.ASCII.GetBytes(SB.ToString);
  finally
    SB.Free;
  end;
end;

// ---------------------------------------------------------------------------
// AddFormXObject
// ---------------------------------------------------------------------------

class function TPDFWatermark.AddFormXObject(
  AObjects:         TObjectDictionary<Integer, TPDFObject>;
  var ANext:        Integer;
  const AFormBytes: TBytes;
  APageW, APageH:   Single;
  const AFontName:  string;
  AImgNum:          Integer;
  AOpacity:         Single): Integer;
var
  FormStm:   TPDFStream;
  BBox:      TPDFArray;
  ResDict:   TPDFDictionary;
  GSDict:    TPDFDictionary;
  GSEntry:   TPDFDictionary;
  FontDict:  TPDFDictionary;
  FontEntry: TPDFDictionary;
  XODict:    TPDFDictionary;
begin
  FormStm := TPDFStream.Create;
  FormStm.Dict.SetValue('Type',    TPDFName.Create('XObject'));
  FormStm.Dict.SetValue('Subtype', TPDFName.Create('Form'));

  BBox := TPDFArray.Create;
  BBox.Add(TPDFReal.Create(0));
  BBox.Add(TPDFReal.Create(0));
  BBox.Add(TPDFReal.Create(APageW));
  BBox.Add(TPDFReal.Create(APageH));
  FormStm.Dict.SetValue('BBox', BBox);

  // Self-contained resources — all watermark state lives here.
  ResDict := TPDFDictionary.Create;

  GSEntry := TPDFDictionary.Create;
  GSEntry.SetValue('Type', TPDFName.Create('ExtGState'));
  GSEntry.SetValue('ca',   TPDFReal.Create(AOpacity));  // fill alpha
  GSEntry.SetValue('CA',   TPDFReal.Create(AOpacity));  // stroke alpha
  GSDict := TPDFDictionary.Create;
  GSDict.SetValue('WmGS', GSEntry);
  ResDict.SetValue('ExtGState', GSDict);

  if AFontName <> '' then
  begin
    FontEntry := TPDFDictionary.Create;
    FontEntry.SetValue('Type',     TPDFName.Create('Font'));
    FontEntry.SetValue('Subtype',  TPDFName.Create('Type1'));
    FontEntry.SetValue('BaseFont', TPDFName.Create(AFontName));
    FontDict := TPDFDictionary.Create;
    FontDict.SetValue('WmFont', FontEntry);
    ResDict.SetValue('Font', FontDict);
  end;

  if AImgNum > 0 then
  begin
    XODict := TPDFDictionary.Create;
    XODict.SetValue('WmImg', TPDFReference.CreateNum(AImgNum, 0));
    ResDict.SetValue('XObject', XODict);
  end;

  FormStm.Dict.SetValue('Resources', ResDict);
  FormStm.SetRawData(AFormBytes);

  Result := AllocNum(ANext);
  AObjects.AddOrSetValue(Result, FormStm);
end;

// ---------------------------------------------------------------------------
// InjectWatermark
//
// 1. Adds /WmFrm → Form XObject ref to the page's /Resources/XObject.
// 2. Creates a tiny injection stream: q /WmFrm Do Q
// 3. Replaces /Contents with an array that puts the injection before or after
//    the original content streams, depending on AMode.
// ---------------------------------------------------------------------------

class procedure TPDFWatermark.InjectWatermark(
  APageDict: TPDFDictionary;
  AObjects:  TObjectDictionary<Integer, TPDFObject>;
  var ANext: Integer;
  AFormNum:  Integer;
  AMode:     TPDFWatermarkMode);
var
  PageRes:    TPDFDictionary;
  XOSub:      TPDFDictionary;
  InjectStm:  TPDFStream;
  InjectNum:  Integer;
  OldCon:     TPDFObject;
  NewArr:     TPDFArray;
  I:          Integer;
begin
  // Register the Form XObject in the page's own XObject sub-dict.
  PageRes := EnsurePageResources(APageDict, AObjects);
  XOSub   := EnsureSubDict(PageRes, 'XObject', AObjects);
  XOSub.SetValue('WmFrm', TPDFReference.CreateNum(AFormNum, 0));

  // Build the invocation stream.
  InjectStm := TPDFStream.Create;
  InjectStm.SetRawData(TEncoding.ASCII.GetBytes('q' + #10 + '/WmFrm Do' + #10 + 'Q' + #10));
  InjectNum := AllocNum(ANext);
  AObjects.AddOrSetValue(InjectNum, InjectStm);

  // Assemble new /Contents array.
  OldCon := APageDict.RawGet('Contents');
  NewArr := TPDFArray.Create;

  if AMode = TPDFWatermarkMode.Overlay then
  begin
    // Original streams first, watermark drawn on top.
    if OldCon <> nil then
    begin
      if OldCon.IsArray then
      begin
        var OA := TPDFArray(OldCon);
        for I := 0 to OA.Count - 1 do
          NewArr.Add(OA.Items(I).Clone);
      end else
        NewArr.Add(OldCon.Clone);
    end;
    NewArr.Add(TPDFReference.CreateNum(InjectNum, 0));
  end
  else
  begin
    // Watermark first so existing content paints over it (underlay).
    NewArr.Add(TPDFReference.CreateNum(InjectNum, 0));
    if OldCon <> nil then
    begin
      if OldCon.IsArray then
      begin
        var OA := TPDFArray(OldCon);
        for I := 0 to OA.Count - 1 do
          NewArr.Add(OA.Items(I).Clone);
      end else
        NewArr.Add(OldCon.Clone);
    end;
  end;

  APageDict.SetValue('Contents', NewArr);
end;

// ===========================================================================
// TPDFWatermark — public API
// ===========================================================================

// ---------------------------------------------------------------------------
// ApplyText (full)
// ---------------------------------------------------------------------------

class procedure TPDFWatermark.ApplyText(
  ASource:         TPDFDocument;
  const AText:     string;
  const AFontName: string;
  AFontSize:       Single;
  AR, AG, AB:      Single;
  const AOptions:  TPDFWatermarkOptions;
  AOutput:         TStream);
var
  Objects: TObjectDictionary<Integer, TPDFObject>;
  NextNum: Integer;
  Copier:  TPDFObjectCopier;
  Pages:   TArray<TPDFDictionary>;
  I:       Integer;
  PageW,
  PageH:   Single;
  Bytes:   TBytes;
  FormNum: Integer;
begin
  Objects := TObjectDictionary<Integer, TPDFObject>.Create([doOwnsValues]);
  NextNum := 1;
  try
    Copier := TPDFObjectCopier.Create(ASource.Resolver, Objects, @NextNum);
    try
      SetLength(Pages, ASource.PageCount);
      for I := 0 to ASource.PageCount - 1 do
      begin
        var SrcPage := ASource.Pages[I];
        Pages[I] := Copier.CopyPage(SrcPage.Dict);

        // Use user-space CropBox dimensions (unaffected by /Rotate display hint).
        PageW := SrcPage.CropBox.Width;
        PageH := SrcPage.CropBox.Height;

        Bytes   := BuildTextFormBytes(PageW, PageH,
                     AFontSize, AR, AG, AB, AOptions.Rotation, AText);
        FormNum := AddFormXObject(Objects, NextNum, Bytes,
                     PageW, PageH, AFontName, 0, AOptions.Opacity);
        InjectWatermark(Pages[I], Objects, NextNum, FormNum, AOptions.Mode);
      end;
    finally
      Copier.Free;
    end;
    BuildAndWrite(Pages, Objects, NextNum, AOutput);
  finally
    Objects.Free;
  end;
end;

class procedure TPDFWatermark.ApplyText(
  ASource:         TPDFDocument;
  const AText:     string;
  const AFontName: string;
  AFontSize:       Single;
  AR, AG, AB:      Single;
  const AOptions:  TPDFWatermarkOptions;
  const APath:     string);
begin
  var FS := TFileStream.Create(APath, fmCreate);
  try
    ApplyText(ASource, AText, AFontName, AFontSize, AR, AG, AB, AOptions, FS);
  finally
    FS.Free;
  end;
end;

class procedure TPDFWatermark.ApplyText(
  ASource:     TPDFDocument;
  const AText: string;
  AOutput:     TStream);
begin
  ApplyText(ASource, AText, 'Helvetica', 48,
            0.5, 0.5, 0.5, TPDFWatermarkOptions.Default, AOutput);
end;

class procedure TPDFWatermark.ApplyText(
  ASource:     TPDFDocument;
  const AText: string;
  const APath: string);
begin
  var FS := TFileStream.Create(APath, fmCreate);
  try
    ApplyText(ASource, AText, FS);
  finally
    FS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// ApplyImage (full)
// ---------------------------------------------------------------------------

class procedure TPDFWatermark.ApplyImage(
  ASource:             TPDFDocument;
  const AJpegBytes:    TBytes;
  AImgPixelWidth,
  AImgPixelHeight:     Integer;
  AX, AY,
  AWidth, AHeight:     Single;
  const AOptions:      TPDFWatermarkOptions;
  AOutput:             TStream);
var
  Objects: TObjectDictionary<Integer, TPDFObject>;
  NextNum: Integer;
  Copier:  TPDFObjectCopier;
  Pages:   TArray<TPDFDictionary>;
  I:       Integer;
  ImgStm:  TPDFStream;
  ImgNum:  Integer;
  PageW,
  PageH:   Single;
  Bytes:   TBytes;
  FormNum: Integer;
begin
  Objects := TObjectDictionary<Integer, TPDFObject>.Create([doOwnsValues]);
  NextNum := 1;
  try
    // Build the Image XObject once (shared across all pages via reference).
    ImgStm := TPDFStream.Create;
    ImgStm.Dict.SetValue('Type',             TPDFName.Create('XObject'));
    ImgStm.Dict.SetValue('Subtype',          TPDFName.Create('Image'));
    ImgStm.Dict.SetValue('Width',            TPDFInteger.Create(AImgPixelWidth));
    ImgStm.Dict.SetValue('Height',           TPDFInteger.Create(AImgPixelHeight));
    ImgStm.Dict.SetValue('ColorSpace',       TPDFName.Create('DeviceRGB'));
    ImgStm.Dict.SetValue('BitsPerComponent', TPDFInteger.Create(8));
    ImgStm.Dict.SetValue('Filter',           TPDFName.Create('DCTDecode'));
    ImgStm.SetRawData(AJpegBytes);
    ImgNum := AllocNum(NextNum);
    Objects.AddOrSetValue(ImgNum, ImgStm);

    Copier := TPDFObjectCopier.Create(ASource.Resolver, Objects, @NextNum);
    try
      SetLength(Pages, ASource.PageCount);
      for I := 0 to ASource.PageCount - 1 do
      begin
        var SrcPage := ASource.Pages[I];
        Pages[I] := Copier.CopyPage(SrcPage.Dict);

        PageW := SrcPage.CropBox.Width;
        PageH := SrcPage.CropBox.Height;

        Bytes   := BuildImageFormBytes(AX, AY, AWidth, AHeight);
        FormNum := AddFormXObject(Objects, NextNum, Bytes,
                     PageW, PageH, '', ImgNum, AOptions.Opacity);
        InjectWatermark(Pages[I], Objects, NextNum, FormNum, AOptions.Mode);
      end;
    finally
      Copier.Free;
    end;
    BuildAndWrite(Pages, Objects, NextNum, AOutput);
  finally
    Objects.Free;
  end;
end;

class procedure TPDFWatermark.ApplyImage(
  ASource:             TPDFDocument;
  const AJpegBytes:    TBytes;
  AImgPixelWidth,
  AImgPixelHeight:     Integer;
  AX, AY,
  AWidth, AHeight:     Single;
  const AOptions:      TPDFWatermarkOptions;
  const APath:         string);
begin
  var FS := TFileStream.Create(APath, fmCreate);
  try
    ApplyImage(ASource, AJpegBytes, AImgPixelWidth, AImgPixelHeight,
               AX, AY, AWidth, AHeight, AOptions, FS);
  finally
    FS.Free;
  end;
end;

end.
