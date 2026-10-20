unit uPDF.Image;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Math,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Filters, uPDF.ColorSpace,
  uPDF.CCITTFax;

type
  // -------------------------------------------------------------------------
  // Image encoding format (after decoding filters)
  // -------------------------------------------------------------------------
  TPDFImageEncoding = (
    Raw,      // raw uncompressed samples (after Flate/LZW/RunLength decode)
    JPEG,     // DCT — keep as JPEG bytes for the renderer / OS codec
    JPEG2000, // JPX — keep as-is
    JBIG2,    // 1-bit bilevel
    CCITT     // fax-compressed bilevel
  );

  // -------------------------------------------------------------------------
  // Decoded image descriptor
  // -------------------------------------------------------------------------
  TPDFImageInfo = record
    Width:           Integer;
    Height:          Integer;
    BitsPerComponent:Integer;     // 1, 2, 4, 8, 16
    ComponentCount:  Integer;     // from color space
    ColorSpaceName:  string;      // DeviceRGB, DeviceGray, DeviceCMYK, ...
    Encoding:        TPDFImageEncoding;
    IsImageMask:     Boolean;     // /ImageMask true → 1-bit bilevel stencil
    Interpolate:     Boolean;     // /Interpolate
    Intent:          string;      // /Intent rendering intent
    // For inline images: filter abbreviations already expanded
    HasSMask:        Boolean;     // soft-mask channel present
    DecodeArray:     TArray<Double>;  // /Decode (Dmin Dmax per component); empty = default

    // CCITT parameters (only relevant when Encoding = CCITT)
    CCITTKFactor:    Integer;     // K param: <0=Group4, 0=Group3-1D, >0=Group3-2D
    CCITTBlackIs1:   Boolean;     // BlackIs1 param (default false)
    CCITTParams:     TCCITTFaxParams;  // all the /DecodeParms entries

    // Computed helpers
    function BytesPerRow: Integer;       // after decode, before ColorSpace conversion
    function TotalSampleBytes: Integer;  // Width × Height × ComponentCount × BPC/8
    function IsGrayscale: Boolean;
    function IsRGB: Boolean;
    function IsCMYK: Boolean;
  end;

  // -------------------------------------------------------------------------
  // Decoded image data carrier
  // -------------------------------------------------------------------------
  TPDFImage = class
  private
    FInfo:       TPDFImageInfo;
    FSamples:    TBytes;   // decoded raw samples OR JPEG/CCITT bytes
    FSMask:      TPDFImage;  // optional soft-mask channel (owns)
    FColorSpace: TPDFColorSpace;  // the image colour space, nil if unknown (owns)
    procedure BuildColorSpace(ADict: TPDFDictionary; AResolver: IObjectResolver);
    // Takes APixels (CCITTFaxDecode or JBIG2Decode output) as 1-bit samples
    // when they have the image size
    function AcceptBilevel(const APixels: TBytes): Boolean;
    procedure ApplyDecodeArray;
  public
    constructor Create;
    destructor  Destroy; override;

    // Build from an XObject Image stream
    class function FromXObject(AStream: TPDFStream;
      AResolver: IObjectResolver = nil): TPDFImage; static;

    // Build from an inline image (BI...ID data EI already parsed)
    class function FromInline(ADict: TPDFDictionary;
      const AData: TBytes): TPDFImage; static;

    // Decode filters and store samples
    procedure Decode;

    // Convert raw samples to RGBA8888 (4 bytes per pixel, top-left origin)
    // Caller owns the returned TBytes.
    function ToRGBA: TBytes;

    // Image masks: RGBA with the colour (R, G, B, A) where the mask paints and
    // transparent elsewhere.  Other images: same as ToRGBA.
    function ToStencilRGBA(R, G, B, A: Byte): TBytes;

    // Save as BMP (no external libs needed — for testing/debugging)
    procedure SaveToBMP(const APath: string);

    // Access
    property Info:    TPDFImageInfo read FInfo;
    property Samples: TBytes        read FSamples;
    property SMask:   TPDFImage     read FSMask write FSMask;

    // Convenience
    function Width:  Integer; inline;
    function Height: Integer; inline;
    function IsJPEG: Boolean; inline;
  end;

  // -------------------------------------------------------------------------
  // Utilities
  // -------------------------------------------------------------------------

  // Expand 1-bit samples to 8-bit (1 byte per pixel)
  function ExpandBits1To8(const AData: TBytes; AWidth, AHeight: Integer): TBytes;
  // Expand 2-bit samples to 8-bit
  function ExpandBits2To8(const AData: TBytes; AWidth, AHeight: Integer): TBytes;
  // Expand 4-bit samples to 8-bit
  function ExpandBits4To8(const AData: TBytes; AWidth, AHeight: Integer): TBytes;

  // Wrap raw CCITT-encoded data in a minimal TIFF container (pure Pascal,
  // cross-platform). Useful both for WIC decoding on Windows and for sending
  // scanned page images to OCR services that accept TIFF.
  // AK = K from /DecodeParms (<0 = G4, >0 = G3 2D, 0 = G3 1D).
  function BuildCCITTTIFF(const AData: TBytes; AW, AH, AK: Integer;
    ABlackIs1: Boolean): TBytes;

implementation

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows, Winapi.ActiveX, Winapi.Wincodec;
{$ENDIF}

// =========================================================================
// CCITT helpers (TIFF wrap is cross-platform; WIC decode is Windows-only)
// =========================================================================

// Wrap raw CCITT-encoded data in a minimal TIFF container.
function BuildCCITTTIFF(const AData: TBytes; AW, AH, AK: Integer;
  ABlackIs1: Boolean): TBytes;
var
  S: TBytesStream;
  procedure WW(V: Word);    begin S.Write(V, 2); end;
  procedure WD(V: Cardinal); begin S.Write(V, 4); end;
  procedure WTag(ATag, AType: Word; ACount, AValue: Cardinal);
  begin WW(ATag); WW(AType); WD(ACount); WD(AValue); end;
const
  TT_SHORT  = 3;
  TT_LONG   = 4;
  // IFD layout: 8 (header) + 2 (entry count) + 10×12 (entries) + 4 (next IFD) = 134
  DATA_OFF  = 134;
var
  Comp, Photo: Cardinal;
begin
  if AK < 0 then Comp := 4       // T.6 Group 4
  else if AK > 0 then Comp := 3  // T.4 Group 3
  else Comp := 2;                 // Modified Huffman / 1D
  // PDF BlackIs1=false (default): 0=white → TIFF MinIsWhite (0)
  // PDF BlackIs1=true:            0=black → TIFF MinIsBlack (1)
  if ABlackIs1 then Photo := 1 else Photo := 0;
  S := TBytesStream.Create;
  try
    // 8-byte TIFF header
    WW($4949); WW(42); WD(8);
    // IFD: 10 entries (tags must be in ascending order)
    WW(10);
    WTag(256, TT_SHORT, 1, AW);              // ImageWidth
    WTag(257, TT_SHORT, 1, AH);              // ImageLength
    WTag(258, TT_SHORT, 1, 1);               // BitsPerSample = 1
    WTag(259, TT_SHORT, 1, Comp);            // Compression
    WTag(262, TT_SHORT, 1, Photo);           // PhotometricInterpretation
    WTag(273, TT_LONG,  1, DATA_OFF);        // StripOffsets
    WTag(277, TT_SHORT, 1, 1);               // SamplesPerPixel = 1
    WTag(278, TT_LONG,  1, AH);              // RowsPerStrip = full image
    WTag(279, TT_LONG,  1, Length(AData));   // StripByteCounts
    WTag(293, TT_LONG,  1, 0);               // T6Options = 0
    WD(0);  // no next IFD
    if Length(AData) > 0 then
      S.Write(AData[0], Length(AData));
    Result := Copy(S.Bytes, 0, S.Size);
  finally
    S.Free;
  end;
end;

{$IFDEF MSWINDOWS}

// Decode a TIFF-wrapped CCITT stream to AW×AH 8bpp grayscale using WIC.
// Returns empty on failure.
function DecodeCCITTWithWIC(const ATIFFData: TBytes; AW, AH: Integer): TBytes;
var
  COMInit:    HRESULT;
  Factory:    IWICImagingFactory;
  WICStream:  IWICStream;
  Decoder:    IWICBitmapDecoder;
  Frame:      IWICBitmapFrameDecode;
  Converter:  IWICFormatConverter;
  W, H:       UINT;
  Stride:     UINT;
  DataSize:   UINT;
  Row:        Integer;
  Compact:    TBytes;
  VendorGUID: TGUID;
begin
  Result := nil;
  if Length(ATIFFData) = 0 then Exit;
  FillChar(VendorGUID, SizeOf(VendorGUID), 0);
  COMInit := CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
    if Failed(CoCreateInstance(CLSID_WICImagingFactory, nil,
       CLSCTX_INPROC_SERVER, IID_IWICImagingFactory, Factory)) then Exit;
    if Failed(Factory.CreateStream(WICStream)) then Exit;
    if Failed(WICStream.InitializeFromMemory(@ATIFFData[0],
       DWORD(Length(ATIFFData)))) then Exit;
    if Failed(Factory.CreateDecoderFromStream(WICStream,
       VendorGUID, WICDecodeOptions(WICDecodeMetadataCacheOnDemand),
       Decoder)) then Exit;
    if Failed(Decoder.GetFrame(0, Frame)) then Exit;
    if Failed(Frame.GetSize(W, H)) then Exit;
    if (W = 0) or (H = 0) then Exit;
    if Failed(Factory.CreateFormatConverter(Converter)) then Exit;
    if Failed(Converter.Initialize(Frame, GUID_WICPixelFormat8bppGray,
       WICBitmapDitherType(WICBitmapDitherTypeNone), nil, 0.0,
       WICBitmapPaletteType(WICBitmapPaletteTypeCustom))) then Exit;
    Stride   := (W + 3) and not 3;  // DWORD-aligned
    DataSize := Stride * H;
    SetLength(Result, DataSize);
    if DataSize = 0 then Exit;
    if Failed(Converter.CopyPixels(nil, Stride, DataSize, @Result[0])) then
    begin
      SetLength(Result, 0);
      Exit;
    end;
    // Remove row padding: compact to exactly AW × AH bytes
    if (Stride > UINT(AW)) and (Integer(H) > 0) then
    begin
      SetLength(Compact, AW * AH);
      for Row := 0 to Integer(H) - 1 do
        Move(Result[Row * Stride], Compact[Row * AW], AW);
      Result := Compact;
    end;
  finally
    if COMInit = S_OK then CoUninitialize;
  end;
end;

{$ENDIF MSWINDOWS}

// =========================================================================
// TPDFImageInfo helpers
// =========================================================================

function TPDFImageInfo.BytesPerRow: Integer;
begin
  Result := (Width * ComponentCount * BitsPerComponent + 7) div 8;
end;

function TPDFImageInfo.TotalSampleBytes: Integer;
begin
  Result := BytesPerRow * Height;
end;

function TPDFImageInfo.IsGrayscale: Boolean;
begin
  Result := (ColorSpaceName = 'DeviceGray') or (ComponentCount = 1);
end;

function TPDFImageInfo.IsRGB: Boolean;
begin
  Result := (ColorSpaceName = 'DeviceRGB') or (ComponentCount = 3);
end;

function TPDFImageInfo.IsCMYK: Boolean;
begin
  Result := (ColorSpaceName = 'DeviceCMYK') or (ComponentCount = 4);
end;

// =========================================================================
// Bit expansion utilities
// =========================================================================

function ExpandBits1To8(const AData: TBytes; AWidth, AHeight: Integer): TBytes;
var
  BytesPerRow: Integer;
  Out:         Integer;
  Row, Col:    Integer;
  ByteIdx:     Integer;
  BitIdx:      Integer;
begin
  BytesPerRow := (AWidth + 7) div 8;
  SetLength(Result, AWidth * AHeight);
  Out := 0;
  for Row := 0 to AHeight - 1 do
  begin
    for Col := 0 to AWidth - 1 do
    begin
      ByteIdx := Row * BytesPerRow + (Col shr 3);
      BitIdx  := 7 - (Col and 7);
      if ByteIdx < Length(AData) then
        Result[Out] := ((AData[ByteIdx] shr BitIdx) and 1) * 255
      else
        Result[Out] := 0;
      Inc(Out);
    end;
  end;
end;

function ExpandBits2To8(const AData: TBytes; AWidth, AHeight: Integer): TBytes;
var
  BytesPerRow: Integer;
  Out:         Integer;
  Row, Col:    Integer;
  ByteIdx:     Integer;
  Shift:       Integer;
  Val:         Byte;
begin
  BytesPerRow := (AWidth * 2 + 7) div 8;
  SetLength(Result, AWidth * AHeight);
  Out := 0;
  for Row := 0 to AHeight - 1 do
    for Col := 0 to AWidth - 1 do
    begin
      ByteIdx := Row * BytesPerRow + (Col shr 2);
      Shift   := 6 - (Col and 3) * 2;
      if ByteIdx < Length(AData) then
      begin
        Val := (AData[ByteIdx] shr Shift) and $03;
        Result[Out] := Val * 85; // 0→0, 1→85, 2→170, 3→255
      end else
        Result[Out] := 0;
      Inc(Out);
    end;
end;

function ExpandBits4To8(const AData: TBytes; AWidth, AHeight: Integer): TBytes;
var
  BytesPerRow: Integer;
  Out:         Integer;
  Row, Col:    Integer;
  ByteIdx:     Integer;
  Nibble:      Byte;
begin
  BytesPerRow := (AWidth * 4 + 7) div 8;
  SetLength(Result, AWidth * AHeight);
  Out := 0;
  for Row := 0 to AHeight - 1 do
    for Col := 0 to AWidth - 1 do
    begin
      ByteIdx := Row * BytesPerRow + (Col shr 1);
      if ByteIdx < Length(AData) then
      begin
        if (Col and 1) = 0 then
          Nibble := (AData[ByteIdx] shr 4) and $0F
        else
          Nibble := AData[ByteIdx] and $0F;
        Result[Out] := Nibble or (Nibble shl 4); // scale 0..15 → 0..255
      end else
        Result[Out] := 0;
      Inc(Out);
    end;
end;

// =========================================================================
// TPDFImage
// =========================================================================

constructor TPDFImage.Create;
begin
  inherited;
end;

destructor TPDFImage.Destroy;
begin
  FSMask.Free;
  FColorSpace.Free;
  inherited;
end;

function TPDFImage.Width:  Integer; begin Result := FInfo.Width;  end;
function TPDFImage.Height: Integer; begin Result := FInfo.Height; end;
function TPDFImage.IsJPEG: Boolean; begin Result := FInfo.Encoding = TPDFImageEncoding.JPEG; end;

// -------------------------------------------------------------------------
// Fill TPDFImageInfo from a dict (shared between XObject and inline)
// -------------------------------------------------------------------------

// Filter list and /DecodeParms list of an image dict (inline abbreviations
// included); AParms has one entry (possibly nil) per filter.
procedure GetImageFilters(ADict: TPDFDictionary; out AFilters: TArray<string>;
  out AParms: TArray<TObject>);
begin
  AFilters := nil;
  AParms   := nil;
  var FilterObj := ADict.RawGet('Filter');
  if FilterObj = nil then FilterObj := ADict.RawGet('F');
  if FilterObj = nil then Exit;
  FilterObj := FilterObj.Dereference;
  if FilterObj.IsName then
    AFilters := [FilterObj.AsName.TrimLeft(['/'])]
  else if FilterObj.IsArray then
  begin
    var FA := TPDFArray(FilterObj);
    SetLength(AFilters, FA.Count);
    for var I := 0 to FA.Count - 1 do
      AFilters[I] := FA.GetAsName(I).TrimLeft(['/']);
  end;
  SetLength(AParms, Length(AFilters));
  var DPObj := ADict.RawGet('DecodeParms');
  if DPObj = nil then DPObj := ADict.RawGet('DP');  // inline image abbreviation
  if DPObj = nil then Exit;
  DPObj := DPObj.Dereference;
  if DPObj.IsDictionary then
  begin
    if Length(AParms) > 0 then AParms[0] := DPObj;
  end
  else if DPObj.IsArray then
  begin
    var DPA := TPDFArray(DPObj);
    for var I := 0 to Min(DPA.Count, Length(AParms)) - 1 do
      if DPA.Get(I).IsDictionary then
        AParms[I] := DPA.Get(I);
  end;
end;

// Encoding (from the last filter) and the CCITT parameters
procedure FillImageEncoding(var AInfo: TPDFImageInfo; ADict: TPDFDictionary);
var
  Filters: TArray<string>;
  Parms:   TArray<TObject>;
begin
  GetImageFilters(ADict, Filters, Parms);
  var FilterName := '';
  if Length(Filters) > 0 then FilterName := Filters[High(Filters)];

  // Map filter to encoding
  if FilterName.Contains('DCT') then
    AInfo.Encoding := TPDFImageEncoding.JPEG
  else if FilterName.Contains('JPX') then
    AInfo.Encoding := TPDFImageEncoding.JPEG2000
  else if FilterName.Contains('JBIG2') then
    AInfo.Encoding := TPDFImageEncoding.JBIG2
  else if FilterName.Contains('CCITTFax') or (FilterName = 'CCF') then
    AInfo.Encoding := TPDFImageEncoding.CCITT
  else
    AInfo.Encoding := TPDFImageEncoding.Raw;

  // SMask
  AInfo.HasSMask := ADict.Contains('SMask');

  // CCITT DecodeParms (those of the CCITT filter, the last one)
  AInfo.CCITTParams := TCCITTFaxParams.Default;
  if AInfo.Encoding = TPDFImageEncoding.CCITT then
    AInfo.CCITTParams := CCITTParamsFromDict(Parms[High(Parms)]);
  AInfo.CCITTKFactor  := AInfo.CCITTParams.K;
  AInfo.CCITTBlackIs1 := AInfo.CCITTParams.BlackIs1;
end;

procedure FillImageInfoFromDict(var AInfo: TPDFImageInfo;
  ADict: TPDFDictionary; AResolver: IObjectResolver);
begin
  // Expand inline image abbreviations
  AInfo.Width   := ADict.GetAsInteger('Width',  ADict.GetAsInteger('W', 0));
  AInfo.Height  := ADict.GetAsInteger('Height', ADict.GetAsInteger('H', 0));
  AInfo.BitsPerComponent := ADict.GetAsInteger('BitsPerComponent',
                             ADict.GetAsInteger('BPC', 8));
  AInfo.IsImageMask := ADict.GetAsBoolean('ImageMask',
                        ADict.GetAsBoolean('IM', False));
  AInfo.Interpolate := ADict.GetAsBoolean('Interpolate',
                        ADict.GetAsBoolean('I', False));
  AInfo.Intent := ADict.GetAsName('Intent');

  // /Decode (inline abbreviation /D)
  AInfo.DecodeArray := nil;
  var DecObj := ADict.RawGet('Decode');
  if DecObj = nil then DecObj := ADict.RawGet('D');
  if DecObj <> nil then DecObj := DecObj.Dereference;
  if (DecObj <> nil) and DecObj.IsArray then
  begin
    var DA := TPDFArray(DecObj);
    SetLength(AInfo.DecodeArray, DA.Count);
    for var I := 0 to DA.Count - 1 do
      AInfo.DecodeArray[I] := DA.GetAsNumber(I);
  end;

  // For image masks: 1 component, 1 BPC
  if AInfo.IsImageMask then
  begin
    AInfo.ComponentCount := 1;
    AInfo.BitsPerComponent := 1;
    AInfo.ColorSpaceName := 'DeviceGray';
    FillImageEncoding(AInfo, ADict);
    Exit;
  end;

  // Color space
  var CSObj := ADict.RawGet('ColorSpace');
  if CSObj = nil then CSObj := ADict.RawGet('CS');
  if CSObj <> nil then
  begin
    CSObj := CSObj.Dereference;
    if CSObj.IsName then
      AInfo.ColorSpaceName := CSObj.AsName
    else if CSObj.IsArray then
    begin
      var A := TPDFArray(CSObj);
      AInfo.ColorSpaceName := A.GetAsName(0);
    end;
  end;

  // Expand abbreviated color space names (inline images)
  if AInfo.ColorSpaceName = 'G'    then AInfo.ColorSpaceName := 'DeviceGray';
  if AInfo.ColorSpaceName = 'RGB'  then AInfo.ColorSpaceName := 'DeviceRGB';
  if AInfo.ColorSpaceName = 'CMYK' then AInfo.ColorSpaceName := 'DeviceCMYK';
  if AInfo.ColorSpaceName = 'I'    then AInfo.ColorSpaceName := 'Indexed';

  // Derive component count
  if (AInfo.ColorSpaceName = 'DeviceGray') then AInfo.ComponentCount := 1
  else if AInfo.ColorSpaceName = 'DeviceRGB'  then AInfo.ComponentCount := 3
  else if AInfo.ColorSpaceName = 'DeviceCMYK' then AInfo.ComponentCount := 4
  else AInfo.ComponentCount := 3; // default

  FillImageEncoding(AInfo, ADict);
end;

// -------------------------------------------------------------------------
// FromXObject
// -------------------------------------------------------------------------

class function TPDFImage.FromXObject(AStream: TPDFStream;
  AResolver: IObjectResolver): TPDFImage;
begin
  if AStream = nil then Exit(nil);
  if AStream.Dict.GetAsName('Subtype') <> 'Image' then Exit(nil);

  Result := TPDFImage.Create;
  FillImageInfoFromDict(Result.FInfo, AStream.Dict, AResolver);
  Result.BuildColorSpace(AStream.Dict, AResolver);

  // Decode stream
  // JPEG: keep raw bytes; Skia decodes in DrawPDFImage.
  // CCITT: the filter chain decodes it to 1-bit samples; if that fails
  // (or /Columns does not match /Width), keep the raw bytes for Decode().
  // JBIG2: the filter chain decodes it to 1-bit samples; if that fails the
  // image keeps the JBIG2 encoding and is not drawn.
  if Result.FInfo.Encoding = TPDFImageEncoding.JPEG then
    Result.FSamples := AStream.RawBytes
  else if Result.FInfo.Encoding = TPDFImageEncoding.CCITT then
  begin
    if not Result.AcceptBilevel(AStream.DecodedBytes) then
      Result.FSamples := AStream.RawBytes;
  end
  else if Result.FInfo.Encoding = TPDFImageEncoding.JBIG2 then
  begin
    if not Result.AcceptBilevel(AStream.DecodedBytes) then
      Result.FSamples := nil;
  end
  else
    Result.FSamples := AStream.DecodedBytes;

  // Load SMask channel
  if Result.FInfo.HasSMask then
  begin
    var SMaskObj := AStream.Dict.Get('SMask');
    if (SMaskObj <> nil) and SMaskObj.IsStream then
    begin
      var SMaskImg := TPDFImage.FromXObject(TPDFStream(SMaskObj), AResolver);
      Result.FSMask := SMaskImg;
    end;
  end;
end;

// -------------------------------------------------------------------------
// FromInline
// -------------------------------------------------------------------------

class function TPDFImage.FromInline(ADict: TPDFDictionary;
  const AData: TBytes): TPDFImage;
begin
  Result := TPDFImage.Create;
  FillImageInfoFromDict(Result.FInfo, ADict, nil);
  Result.BuildColorSpace(ADict, nil);

  if Result.FInfo.Encoding = TPDFImageEncoding.JPEG then
    Result.FSamples := AData
  else
  begin
    // Apply filters (already decoded by lexer for simple cases)
    // For inline images with Flate/ASCII85, we need to decode here
    var Filters: TArray<string>;
    var Parms:   TArray<TObject>;
    GetImageFilters(ADict, Filters, Parms);

    if Length(Filters) > 0 then
    begin
      var Decoded: TBytes;
      try
        Decoded := TPDFFilterPipeline.Decode(AData, Filters, Parms);
      except
        Decoded := nil;
      end;
      if Result.FInfo.Encoding = TPDFImageEncoding.CCITT then
      begin
        if not Result.AcceptBilevel(Decoded) then
          Result.FSamples := AData;  // retried in Decode()
      end
      else if Decoded <> nil then
        Result.FSamples := Decoded
      else
        Result.FSamples := AData; // fallback: raw
    end else
      Result.FSamples := AData;
  end;
end;

// -------------------------------------------------------------------------
// Decode  (called after construction if samples need post-processing)
// -------------------------------------------------------------------------

// Colour space object of the image; its component count replaces the
// guess made from the name (ICCBased with 1 or 4 components, Indexed,
// Separation, DeviceN).  Names an inline image takes from the page
// resources cannot be resolved here and keep the guess.
procedure TPDFImage.BuildColorSpace(ADict: TPDFDictionary;
  AResolver: IObjectResolver);
begin
  if FInfo.IsImageMask then Exit;
  var CSObj := ADict.RawGet('ColorSpace');
  if CSObj = nil then CSObj := ADict.RawGet('CS');
  if CSObj = nil then Exit;
  CSObj := CSObj.Dereference;
  try
    if CSObj.IsName then
    begin
      // the factory maps unknown names to DeviceGray: only the device spaces
      if FInfo.ColorSpaceName = 'DeviceGray' then FColorSpace := TPDFDeviceGray.Create
      else if FInfo.ColorSpaceName = 'DeviceRGB' then FColorSpace := TPDFDeviceRGB.Create
      else if FInfo.ColorSpaceName = 'DeviceCMYK' then FColorSpace := TPDFDeviceCMYK.Create;
    end
    else
      FColorSpace := TPDFColorSpaceFactory.Build(CSObj, AResolver);
  except
    FColorSpace := nil;
  end;
  if FColorSpace <> nil then
    FInfo.ComponentCount := FColorSpace.ComponentCount;
end;

function TPDFImage.AcceptBilevel(const APixels: TBytes): Boolean;
begin
  Result := (FInfo.Width > 0) and (FInfo.Height > 0) and
    (Length(APixels) = FInfo.Height * ((FInfo.Width + 7) div 8));
  if not Result then Exit;
  FSamples               := APixels;
  FInfo.Encoding         := TPDFImageEncoding.Raw;
  FInfo.BitsPerComponent := 1;
  FInfo.ComponentCount   := 1;
  if not FInfo.IsImageMask then
    FInfo.ColorSpaceName := 'DeviceGray';
end;

procedure TPDFImage.Decode;
begin
  // CCITT data the filter chain could not decode: retry with the image
  // size (files that omit /Columns), then via WIC (Windows only)
  if FInfo.Encoding = TPDFImageEncoding.CCITT then
  begin
    var P := FInfo.CCITTParams;
    P.Columns := FInfo.Width;
    P.Rows    := FInfo.Height;
    try
      AcceptBilevel(CCITTFaxDecode(FSamples, P));
    except
      on ECCITTFaxError do ;
    end;
  end;
  {$IFDEF MSWINDOWS}
  if FInfo.Encoding = TPDFImageEncoding.CCITT then
  begin
    var TIFFBytes := BuildCCITTTIFF(FSamples, FInfo.Width, FInfo.Height,
      FInfo.CCITTKFactor, FInfo.CCITTBlackIs1);
    var Decoded := DecodeCCITTWithWIC(TIFFBytes, FInfo.Width, FInfo.Height);
    if Length(Decoded) > 0 then
    begin
      FSamples            := Decoded;
      FInfo.Encoding      := TPDFImageEncoding.Raw;
      FInfo.BitsPerComponent := 8;
      FInfo.ComponentCount   := 1;  // grayscale output
      FInfo.ColorSpaceName   := 'DeviceGray';
    end;
    // On decode failure, Encoding remains CCITT → falls through to exit below
  end;
  {$ENDIF}

  // For Raw images, apply bit expansion if BPC < 8
  if FInfo.Encoding <> TPDFImageEncoding.Raw then Exit;

  case FInfo.BitsPerComponent of
    1: FSamples := ExpandBits1To8(FSamples, FInfo.Width * FInfo.ComponentCount, FInfo.Height);
    2: FSamples := ExpandBits2To8(FSamples, FInfo.Width * FInfo.ComponentCount, FInfo.Height);
    4: FSamples := ExpandBits4To8(FSamples, FInfo.Width * FInfo.ComponentCount, FInfo.Height);
    // 8 and 16 need no expansion (16-bit: take high byte)
  end;
  if FInfo.BitsPerComponent = 16 then
  begin
    // Downsample 16→8: take high byte of each sample
    var N   := Length(FSamples) div 2;
    var New_: TBytes;
    SetLength(New_, N);
    for var I := 0 to N - 1 do
      New_[I] := FSamples[I * 2];
    FSamples := New_;
  end;

  ApplyDecodeArray;
end;

// /Decode on the 8-bit samples: sample' = 255 * (Dmin + sample/255 * (Dmax - Dmin)).
// Image masks keep the convention 0 = paint, so [1 0] inverts them.
// Indexed images are skipped (their Decode maps the index, not a colour).
procedure TPDFImage.ApplyDecodeArray;
var
  NC, I, C: Integer;
  Lut: array of array[0..255] of Byte;
  Identity: Boolean;
begin
  if FInfo.ColorSpaceName = 'Indexed' then Exit;
  if FInfo.IsImageMask then NC := 1 else NC := FInfo.ComponentCount;
  if (NC <= 0) or (Length(FInfo.DecodeArray) < 2 * NC) then Exit;
  SetLength(Lut, NC);
  Identity := True;
  for C := 0 to NC - 1 do
  begin
    var D0 := FInfo.DecodeArray[2 * C];
    var D1 := FInfo.DecodeArray[2 * C + 1];
    if (D0 <> 0) or (D1 <> 1) then Identity := False;
    for I := 0 to 255 do
      Lut[C][I] := Round(EnsureRange(D0 + I / 255 * (D1 - D0), 0, 1) * 255);
  end;
  if Identity then Exit;
  for I := 0 to High(FSamples) do
  begin
    C := I mod NC;
    FSamples[I] := Lut[C][FSamples[I]];
  end;
end;

function TPDFImage.ToStencilRGBA(R, G, B, A: Byte): TBytes;
var
  I, N: Integer;
begin
  if not FInfo.IsImageMask then Exit(ToRGBA);
  N := FInfo.Width * FInfo.Height;
  SetLength(Result, N * 4);
  for I := 0 to N - 1 do
    if (I < Length(FSamples)) and (FSamples[I] < 128) then
    begin
      Result[I * 4]     := R;
      Result[I * 4 + 1] := G;
      Result[I * 4 + 2] := B;
      Result[I * 4 + 3] := A;
    end
    else
      PCardinal(@Result[I * 4])^ := 0;
end;

// -------------------------------------------------------------------------
// ToRGBA  — convert decoded samples to 32-bit RGBA (bottom-up → top-down)
// -------------------------------------------------------------------------

// Sample N of A, 0 past the end of the data
function SampleAt(const A: TBytes; N: Integer): Byte; inline;
begin
  if N < Length(A) then Result := A[N] else Result := 0;
end;

function TPDFImage.ToRGBA: TBytes;
var
  W, H, I, J: Integer;
  R, G, B, A: Byte;
begin
  W := FInfo.Width;
  H := FInfo.Height;
  SetLength(Result, W * H * 4);

  if FInfo.Encoding = TPDFImageEncoding.JPEG then
    Exit; // JPEG decoded by OS/Skia; return empty here

  var Src := FSamples;
  var Dst := 0;
  var NC  := FInfo.ComponentCount;

  // One-component spaces other than gray (Indexed, Separation): a table of
  // the 256 possible 8-bit samples.  Indexed samples are palette indexes,
  // which the bit expansion scaled to 0..255.
  if (NC = 1) and (FColorSpace <> nil) and not (FColorSpace.Kind in
    [TPDFColorSpaceKind.DeviceGray, TPDFColorSpaceKind.CalGray,
     TPDFColorSpaceKind.ICCBased]) then
  begin
    var Lut: array[0..255, 0..2] of Byte;
    var MaxV := (1 shl Min(FInfo.BitsPerComponent, 8)) - 1;
    var Comp: TArray<Single>;
    SetLength(Comp, 1);
    for I := 0 to 255 do
    begin
      if FColorSpace.Kind = TPDFColorSpaceKind.Indexed then
        Comp[0] := Round(I * MaxV / 255)
      else
        Comp[0] := I / 255;
      var RF, GF, BF: Single;
      FColorSpace.ToRGB(Comp, RF, GF, BF);
      Lut[I, 0] := Round(EnsureRange(RF, 0, 1) * 255);
      Lut[I, 1] := Round(EnsureRange(GF, 0, 1) * 255);
      Lut[I, 2] := Round(EnsureRange(BF, 0, 1) * 255);
    end;
    for I := 0 to W * H - 1 do
    begin
      var V := SampleAt(Src, I);
      Result[Dst]   := Lut[V, 0];
      Result[Dst+1] := Lut[V, 1];
      Result[Dst+2] := Lut[V, 2];
      Result[Dst+3] := 255;
      Inc(Dst, 4);
    end;
  end
  else
  case NC of
    1: // Gray
    begin
      for I := 0 to W * H - 1 do
      begin
        var GV := SampleAt(Src, I);
        Result[Dst]   := GV;
        Result[Dst+1] := GV;
        Result[Dst+2] := GV;
        Result[Dst+3] := 255;
        Inc(Dst, 4);
      end;
    end;
    3: // RGB
    begin
      for I := 0 to W * H - 1 do
      begin
        Result[Dst]   := SampleAt(Src, I * 3);
        Result[Dst+1] := SampleAt(Src, I * 3 + 1);
        Result[Dst+2] := SampleAt(Src, I * 3 + 2);
        Result[Dst+3] := 255;
        Inc(Dst, 4);
      end;
    end;
    4: // CMYK → RGB
    begin
      for I := 0 to W * H - 1 do
      begin
        var RF, GF, BF: Single;
        CMYKToRGB(SampleAt(Src, I * 4) / 255.0, SampleAt(Src, I * 4 + 1) / 255.0,
          SampleAt(Src, I * 4 + 2) / 255.0, SampleAt(Src, I * 4 + 3) / 255.0, RF, GF, BF);
        Result[Dst]   := Round(EnsureRange(RF, 0, 1) * 255);
        Result[Dst+1] := Round(EnsureRange(GF, 0, 1) * 255);
        Result[Dst+2] := Round(EnsureRange(BF, 0, 1) * 255);
        Result[Dst+3] := 255;
        Inc(Dst, 4);
      end;
    end;
  else
    // other component counts (DeviceN): through the colour space, if known
    if (NC > 0) and (FColorSpace <> nil) then
    begin
      var Comp: TArray<Single>;
      SetLength(Comp, NC);
      for I := 0 to W * H - 1 do
      begin
        for J := 0 to NC - 1 do
          Comp[J] := SampleAt(Src, I * NC + J) / 255;
        var RF, GF, BF: Single;
        FColorSpace.ToRGB(Comp, RF, GF, BF);
        Result[Dst]   := Round(EnsureRange(RF, 0, 1) * 255);
        Result[Dst+1] := Round(EnsureRange(GF, 0, 1) * 255);
        Result[Dst+2] := Round(EnsureRange(BF, 0, 1) * 255);
        Result[Dst+3] := 255;
        Inc(Dst, 4);
      end;
    end;
  end;

  // Apply soft-mask alpha channel
  if (FSMask <> nil) then
  begin
    var MaskSamples := FSMask.FSamples;
    for I := 0 to W * H - 1 do
    begin
      if I < Length(MaskSamples) then
        Result[I * 4 + 3] := MaskSamples[I]
      else
        Result[I * 4 + 3] := 255;
    end;
  end;
end;

// -------------------------------------------------------------------------
// SaveToBMP  (24-bit uncompressed BMP — no external libs, for debugging)
// -------------------------------------------------------------------------

procedure TPDFImage.SaveToBMP(const APath: string);
var
  FS:    TFileStream;
  RGBA:  TBytes;
  W, H:  Integer;
  Row:   Integer;
  Pad:   Integer;
  PadBuf:array[0..3] of Byte;
begin
  if FInfo.Encoding = TPDFImageEncoding.JPEG then
  begin
    // Save raw JPEG bytes with .jpg extension
    var JPath := ChangeFileExt(APath, '.jpg');
    FS := TFileStream.Create(JPath, fmCreate);
    try
      if Length(FSamples) > 0 then
        FS.Write(FSamples[0], Length(FSamples));
    finally
      FS.Free;
    end;
    Exit;
  end;

  RGBA := ToRGBA;
  if Length(RGBA) = 0 then Exit;

  W := FInfo.Width;
  H := FInfo.Height;
  Pad := (4 - (W * 3) mod 4) mod 4;
  FillChar(PadBuf, SizeOf(PadBuf), 0);

  var PixelDataSize := (W * 3 + Pad) * H;
  var FileSize      := 54 + PixelDataSize;

  FS := TFileStream.Create(APath, fmCreate);
  try
    // BMP File Header (14 bytes)
    var BF_Type:       Word   := $4D42; // 'BM'
    var BF_Size:       Cardinal := FileSize;
    var BF_Reserved:   Cardinal := 0;
    var BF_OffBits:    Cardinal := 54;
    FS.Write(BF_Type,     2);
    FS.Write(BF_Size,     4);
    FS.Write(BF_Reserved, 4);
    FS.Write(BF_OffBits,  4);

    // DIB Header (BITMAPINFOHEADER, 40 bytes)
    var BI_Size:       Cardinal := 40;
    var BI_Width:      Integer  := W;
    var BI_Height:     Integer  := -H; // negative = top-down
    var BI_Planes:     Word     := 1;
    var BI_BitCount:   Word     := 24;
    var BI_Compress:   Cardinal := 0;
    var BI_SizeImage:  Cardinal := PixelDataSize;
    var BI_XPels:      Integer  := 2835;
    var BI_YPels:      Integer  := 2835;
    var BI_ClrUsed:    Cardinal := 0;
    var BI_ClrImportant: Cardinal := 0;
    FS.Write(BI_Size,          4);
    FS.Write(BI_Width,         4);
    FS.Write(BI_Height,        4);
    FS.Write(BI_Planes,        2);
    FS.Write(BI_BitCount,      2);
    FS.Write(BI_Compress,      4);
    FS.Write(BI_SizeImage,     4);
    FS.Write(BI_XPels,         4);
    FS.Write(BI_YPels,         4);
    FS.Write(BI_ClrUsed,       4);
    FS.Write(BI_ClrImportant,  4);

    // Pixel data: BGR24, row by row
    for Row := 0 to H - 1 do
    begin
      for var Col := 0 to W - 1 do
      begin
        var Src := (Row * W + Col) * 4;
        // BMP = BGR order
        FS.Write(RGBA[Src + 2], 1); // B
        FS.Write(RGBA[Src + 1], 1); // G
        FS.Write(RGBA[Src],     1); // R
      end;
      if Pad > 0 then
        FS.Write(PadBuf[0], Pad);
    end;
  finally
    FS.Free;
  end;
end;

end.
