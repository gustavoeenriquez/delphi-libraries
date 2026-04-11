unit uPDF.ContentStream;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.Math,
  System.Types,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Lexer,
  uPDF.GraphicsState, uPDF.ColorSpace, uPDF.Font;

type
  // -------------------------------------------------------------------------
  // Path segments (used to accumulate path before painting)
  // -------------------------------------------------------------------------
  TPDFPathSegKind = (MoveTo, LineTo, CurveTo, CurveToV, CurveToY, Close);

  TPDFPathSegment = record
    Kind: TPDFPathSegKind;
    P1, P2, P3: TPointF;  // P1=endpoint for MoveTo/LineTo; P1..P3 for curves
  end;

  TPDFPath = class
  private
    FSegments: TList<TPDFPathSegment>;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure MoveTo(X, Y: Single);
    procedure LineTo(X, Y: Single);
    procedure CurveTo(X1, Y1, X2, Y2, X3, Y3: Single);
    procedure CurveToV(X2, Y2, X3, Y3: Single); // first CP = current point
    procedure CurveToY(X1, Y1, X3, Y3: Single); // last  CP = end point
    procedure ClosePath;
    procedure Clear;
    function  Count: Integer; inline;
    function  Segments: TList<TPDFPathSegment>;
    function  IsEmpty: Boolean; inline;
    // Append a rectangle sub-path
    procedure AddRect(X, Y, W, H: Single);
  end;

  // -------------------------------------------------------------------------
  // Fill rule
  // -------------------------------------------------------------------------
  TPDFFillRule = (NonZeroWinding, EvenOdd);

  // -------------------------------------------------------------------------
  // Paint operation kind (what to do with the current path)
  // -------------------------------------------------------------------------
  TPDFPaintOp = (
    Stroke,
    Fill,
    FillAndStroke,
    FillEvenOdd,
    FillEvenOddAndStroke,
    ClipNonZero,
    ClipEvenOdd
  );

  // -------------------------------------------------------------------------
  // Text glyph info (emitted per glyph during Tj/TJ/etc.)
  // -------------------------------------------------------------------------
  TPDFGlyphInfo = record
    CharCode:  Integer;
    Unicode:   string;
    Width:     Single;  // in text-space units (before scaling)
    X, Y:      Single;  // text-space position
    GlyphMatrix: TPDFMatrix; // text rendering matrix for this glyph
  end;

  // -------------------------------------------------------------------------
  // XObject type
  // -------------------------------------------------------------------------
  TPDFXObjectKind = (Image, Form);

  // -------------------------------------------------------------------------
  // Event callbacks for the content stream processor.
  // The renderer subscribes to these; so does the text extractor.
  // Using callbacks (not virtual methods) allows multiple simultaneous
  // subscribers and clean separation from Skia.
  // -------------------------------------------------------------------------

  // Called when current path should be painted
  TPDFOnPaintPath  = reference to procedure(
    const APath: TPDFPath;
    const AState: TPDFGraphicsState;
    AOp: TPDFPaintOp);

  // Called for each glyph in a text operation
  TPDFOnPaintGlyph = reference to procedure(
    const AGlyph: TPDFGlyphInfo;
    const AState: TPDFGraphicsState);

  // Called when an XObject should be painted
  TPDFOnPaintXObject = reference to procedure(
    const AName: string;
    const AMatrix: TPDFMatrix;
    const AState: TPDFGraphicsState);

  // Called for inline images
  TPDFOnPaintInlineImage = reference to procedure(
    const AImageDict: TPDFDictionary;
    const AImageData: TBytes;
    const AState: TPDFGraphicsState);

  // Called on q/Q (save/restore)
  TPDFOnSaveRestore = reference to procedure(AIsSave: Boolean;
    const AState: TPDFGraphicsState);

  // -------------------------------------------------------------------------
  // Resources wrapper (abstracts /Font, /XObject, /ColorSpace lookups)
  // -------------------------------------------------------------------------
  IPDFResources = interface
    ['{F3A7B2C1-5E8D-4B9A-A2C4-D1E5F8A07C3B}']
    function  GetFont(const AName: string): TPDFFont;
    function  GetXObject(const AName: string): TPDFStream;
    function  GetColorSpace(const AName: string): TPDFColorSpace;
    function  GetExtGState(const AName: string): TPDFDictionary;
    function  GetPattern(const AName: string): TPDFObject;
  end;

  // -------------------------------------------------------------------------
  // Content stream processor
  //
  // Reads a PDF content stream byte-by-byte, maintains the graphics state,
  // dispatches PDF operators to registered callbacks.
  // Thread-safe per instance (single-threaded use).
  // -------------------------------------------------------------------------
  TPDFContentStreamProcessor = class
  private
    FGS:          TPDFGraphicsStateStack;
    FPath:        TPDFPath;
    FResources:   IPDFResources;
    FResolver:    IObjectResolver;

    // Operator callbacks
    FOnPaintPath:       TPDFOnPaintPath;
    FOnPaintGlyph:      TPDFOnPaintGlyph;
    FOnPaintXObject:    TPDFOnPaintXObject;
    FOnPaintInlineImage:TPDFOnPaintInlineImage;
    FOnSaveRestore:     TPDFOnSaveRestore;

    // Current text position (redundant with GS.Text but easier to access)
    FCurrentX, FCurrentY: Single;  // current point (user space)

    // Operator dispatch table: string → method pointer
    type TOperatorProc = procedure(const AArgs: TArray<TPDFObject>) of object;
    var  FOperators: TDictionary<string, TOperatorProc>;

    procedure RegisterOperators;

    // ---- Graphics state operators ----
    procedure Op_q(const A: TArray<TPDFObject>);     // save
    procedure Op_QUC(const A: TArray<TPDFObject>);   // restore
    procedure Op_cm(const A: TArray<TPDFObject>);    // concat matrix
    procedure Op_w(const A: TArray<TPDFObject>);     // set line width
    procedure Op_JUC(const A: TArray<TPDFObject>);   // set line cap
    procedure Op_j(const A: TArray<TPDFObject>);     // set line join
    procedure Op_MUC(const A: TArray<TPDFObject>);   // set miter limit
    procedure Op_d(const A: TArray<TPDFObject>);     // set dash
    procedure Op_ri(const A: TArray<TPDFObject>);    // set rendering intent
    procedure Op_i(const A: TArray<TPDFObject>);     // set flatness
    procedure Op_gs(const A: TArray<TPDFObject>);    // set ext graphics state

    // ---- Path construction ----
    procedure Op_m(const A: TArray<TPDFObject>);     // moveto
    procedure Op_l(const A: TArray<TPDFObject>);     // lineto
    procedure Op_c(const A: TArray<TPDFObject>);     // curveto
    procedure Op_v(const A: TArray<TPDFObject>);     // curveto (v)
    procedure Op_y(const A: TArray<TPDFObject>);     // curveto (y)
    procedure Op_h(const A: TArray<TPDFObject>);     // closepath
    procedure Op_re(const A: TArray<TPDFObject>);    // rectangle

    // ---- Path painting ----
    procedure Op_SUC(const A: TArray<TPDFObject>);   // stroke
    procedure Op_s(const A: TArray<TPDFObject>);     // close + stroke
    procedure Op_f(const A: TArray<TPDFObject>);     // fill nonzero
    procedure Op_FUC(const A: TArray<TPDFObject>);   // fill nonzero (compat)
    procedure Op_fstar(const A: TArray<TPDFObject>); // fill evenodd  (f*)
    procedure Op_BUC(const A: TArray<TPDFObject>);   // fill+stroke nonzero
    procedure Op_BstarUC(const A: TArray<TPDFObject>);// fill+stroke evenodd (B*)
    procedure Op_b(const A: TArray<TPDFObject>);     // close+fill+stroke
    procedure Op_bstar(const A: TArray<TPDFObject>); // close+fill*+stroke (b*)
    procedure Op_n(const A: TArray<TPDFObject>);     // end path (no paint)

    // ---- Clipping ----
    procedure Op_WUC(const A: TArray<TPDFObject>);   // clip nonzero
    procedure Op_Wstar(const A: TArray<TPDFObject>); // clip evenodd (W*)

    // ---- Color ----
    procedure Op_CSUC(const A: TArray<TPDFObject>);  // set stroke color space
    procedure Op_cs(const A: TArray<TPDFObject>);    // set fill color space
    procedure Op_SCUC(const A: TArray<TPDFObject>);  // set stroke color
    procedure Op_sc(const A: TArray<TPDFObject>);    // set fill color
    procedure Op_SCNUC(const A: TArray<TPDFObject>); // set stroke color (extended)
    procedure Op_scn(const A: TArray<TPDFObject>);   // set fill color (extended)
    procedure Op_GUC(const A: TArray<TPDFObject>);   // set stroke gray
    procedure Op_g(const A: TArray<TPDFObject>);     // set fill gray
    procedure Op_RGUC(const A: TArray<TPDFObject>);  // set stroke RGB
    procedure Op_rg(const A: TArray<TPDFObject>);    // set fill RGB
    procedure Op_KUC(const A: TArray<TPDFObject>);   // set stroke CMYK
    procedure Op_k(const A: TArray<TPDFObject>);     // set fill CMYK

    // ---- Text state ----
    procedure Op_Tf(const A: TArray<TPDFObject>);    // set font
    procedure Op_Tc(const A: TArray<TPDFObject>);    // char spacing
    procedure Op_Tw(const A: TArray<TPDFObject>);    // word spacing
    procedure Op_Tz(const A: TArray<TPDFObject>);    // horiz scaling
    procedure Op_TL(const A: TArray<TPDFObject>);    // leading
    procedure Op_Tr(const A: TArray<TPDFObject>);    // text render mode
    procedure Op_Ts(const A: TArray<TPDFObject>);    // text rise

    // ---- Text positioning ----
    procedure Op_Td(const A: TArray<TPDFObject>);    // move to next line
    procedure Op_TDUC(const A: TArray<TPDFObject>);  // move to next line + set leading
    procedure Op_Tm(const A: TArray<TPDFObject>);    // set text matrix
    procedure Op_Tstar(const A: TArray<TPDFObject>); // next line (T*)

    // ---- Text showing ----
    procedure Op_Tj(const A: TArray<TPDFObject>);    // show string
    procedure Op_TJUC(const A: TArray<TPDFObject>);  // show strings with kerning
    procedure Op_Quote(const A: TArray<TPDFObject>); // ' (next line + show)
    procedure Op_DQuote(const A: TArray<TPDFObject>);// " (set spacing + show)

    // ---- Text block ----
    procedure Op_BT(const A: TArray<TPDFObject>);   // begin text
    procedure Op_ET(const A: TArray<TPDFObject>);   // end text

    // ---- XObjects ----
    procedure Op_Do(const A: TArray<TPDFObject>);   // invoke XObject

    // ---- Marked content (ignored) ----
    procedure Op_BMC(const A: TArray<TPDFObject>);
    procedure Op_BDC(const A: TArray<TPDFObject>);
    procedure Op_EMC(const A: TArray<TPDFObject>);
    procedure Op_MP(const A: TArray<TPDFObject>);
    procedure Op_DP(const A: TArray<TPDFObject>);

    // ---- Compatibility ----
    procedure Op_BX(const A: TArray<TPDFObject>);
    procedure Op_EX(const A: TArray<TPDFObject>);

    // ---- Internal helpers ----
    function  ArgsAsNumbers(const AArgs: TArray<TPDFObject>): TArray<Single>;
    procedure ShowString(const ABytes: RawByteString);
    procedure EmitGlyph(ACharCode: Integer; AGlyphWidth: Single);
    procedure ApplyExtGState(ADict: TPDFDictionary);
    procedure SetColorFromArgs(const AArgs: TArray<TPDFObject>;
      AIsStroke: Boolean; const ACSName: string);

    function  GetCurrentPoint: TPointF; inline;
    procedure SetCurrentPoint(X, Y: Single); inline;

  public
    constructor Create;
    destructor  Destroy; override;

    // Process a decoded content stream
    procedure Process(const AData: TBytes; AResources: IPDFResources;
      AResolver: IObjectResolver = nil);
    procedure ProcessStream(AStream: TStream; AResources: IPDFResources;
      AResolver: IObjectResolver = nil);

    // Event callbacks
    property OnPaintPath:        TPDFOnPaintPath        read FOnPaintPath        write FOnPaintPath;
    property OnPaintGlyph:       TPDFOnPaintGlyph       read FOnPaintGlyph       write FOnPaintGlyph;
    property OnPaintXObject:     TPDFOnPaintXObject      read FOnPaintXObject     write FOnPaintXObject;
    property OnPaintInlineImage: TPDFOnPaintInlineImage  read FOnPaintInlineImage write FOnPaintInlineImage;
    property OnSaveRestore:      TPDFOnSaveRestore       read FOnSaveRestore      write FOnSaveRestore;

    // Access graphics state (read-only during processing)
    function GraphicsState: TPDFGraphicsStateStack;
  end;

implementation

// =========================================================================
// TPDFPath
// =========================================================================

constructor TPDFPath.Create;
begin
  inherited;
  FSegments := TList<TPDFPathSegment>.Create;
end;

destructor TPDFPath.Destroy;
begin
  FSegments.Free;
  inherited;
end;

function TPDFPath.Count: Integer;   begin Result := FSegments.Count; end;
function TPDFPath.IsEmpty: Boolean; begin Result := FSegments.Count = 0; end;
function TPDFPath.Segments: TList<TPDFPathSegment>; begin Result := FSegments; end;

procedure TPDFPath.Clear;
begin
  FSegments.Clear;
end;

procedure TPDFPath.MoveTo(X, Y: Single);
var S: TPDFPathSegment;
begin
  S.Kind := TPDFPathSegKind.MoveTo;
  S.P1   := TPointF.Create(X, Y);
  FSegments.Add(S);
end;

procedure TPDFPath.LineTo(X, Y: Single);
var S: TPDFPathSegment;
begin
  S.Kind := TPDFPathSegKind.LineTo;
  S.P1   := TPointF.Create(X, Y);
  FSegments.Add(S);
end;

procedure TPDFPath.CurveTo(X1, Y1, X2, Y2, X3, Y3: Single);
var S: TPDFPathSegment;
begin
  S.Kind := TPDFPathSegKind.CurveTo;
  S.P1   := TPointF.Create(X1, Y1);
  S.P2   := TPointF.Create(X2, Y2);
  S.P3   := TPointF.Create(X3, Y3);
  FSegments.Add(S);
end;

procedure TPDFPath.CurveToV(X2, Y2, X3, Y3: Single);
var S: TPDFPathSegment;
begin
  S.Kind := TPDFPathSegKind.CurveToV;
  S.P2   := TPointF.Create(X2, Y2);
  S.P3   := TPointF.Create(X3, Y3);
  FSegments.Add(S);
end;

procedure TPDFPath.CurveToY(X1, Y1, X3, Y3: Single);
var S: TPDFPathSegment;
begin
  S.Kind := TPDFPathSegKind.CurveToY;
  S.P1   := TPointF.Create(X1, Y1);
  S.P3   := TPointF.Create(X3, Y3);
  FSegments.Add(S);
end;

procedure TPDFPath.ClosePath;
var S: TPDFPathSegment;
begin
  S.Kind := TPDFPathSegKind.Close;
  FSegments.Add(S);
end;

procedure TPDFPath.AddRect(X, Y, W, H: Single);
begin
  MoveTo(X, Y);
  LineTo(X + W, Y);
  LineTo(X + W, Y + H);
  LineTo(X, Y + H);
  ClosePath;
end;

// =========================================================================
// TPDFContentStreamProcessor
// =========================================================================

constructor TPDFContentStreamProcessor.Create;
begin
  inherited;
  FGS        := TPDFGraphicsStateStack.Create;
  FPath      := TPDFPath.Create;
  FOperators := TDictionary<string, TOperatorProc>.Create;
  RegisterOperators;
end;

destructor TPDFContentStreamProcessor.Destroy;
begin
  FOperators.Free;
  FPath.Free;
  FGS.Free;
  inherited;
end;

function TPDFContentStreamProcessor.GraphicsState: TPDFGraphicsStateStack;
begin
  Result := FGS;
end;

function TPDFContentStreamProcessor.GetCurrentPoint: TPointF;
begin
  Result := TPointF.Create(FCurrentX, FCurrentY);
end;

procedure TPDFContentStreamProcessor.SetCurrentPoint(X, Y: Single);
begin
  FCurrentX := X;
  FCurrentY := Y;
end;

procedure TPDFContentStreamProcessor.RegisterOperators;
begin
  // Graphics state
  FOperators.Add('q',  Op_q);
  FOperators.Add('Q',  Op_QUC);
  FOperators.Add('cm', Op_cm);
  FOperators.Add('w',  Op_w);
  FOperators.Add('J',  Op_JUC);
  FOperators.Add('j',  Op_j);
  FOperators.Add('M',  Op_MUC);
  FOperators.Add('d',  Op_d);
  FOperators.Add('ri', Op_ri);
  FOperators.Add('i',  Op_i);
  FOperators.Add('gs', Op_gs);
  // Path construction
  FOperators.Add('m',  Op_m);
  FOperators.Add('l',  Op_l);
  FOperators.Add('c',  Op_c);
  FOperators.Add('v',  Op_v);
  FOperators.Add('y',  Op_y);
  FOperators.Add('h',  Op_h);
  FOperators.Add('re', Op_re);
  // Path painting
  FOperators.Add('S',  Op_SUC);
  FOperators.Add('s',  Op_s);
  FOperators.Add('f',  Op_f);
  FOperators.Add('F',  Op_FUC);
  FOperators.Add('f*', Op_fstar);
  FOperators.Add('B',  Op_BUC);
  FOperators.Add('B*', Op_BstarUC);
  FOperators.Add('b',  Op_b);
  FOperators.Add('b*', Op_bstar);
  FOperators.Add('n',  Op_n);
  // Clipping
  FOperators.Add('W',  Op_WUC);
  FOperators.Add('W*', Op_Wstar);
  // Color
  FOperators.Add('CS', Op_CSUC);
  FOperators.Add('cs', Op_cs);
  FOperators.Add('SC', Op_SCUC);
  FOperators.Add('sc', Op_sc);
  FOperators.Add('SCN',Op_SCNUC);
  FOperators.Add('scn',Op_scn);
  FOperators.Add('G',  Op_GUC);
  FOperators.Add('g',  Op_g);
  FOperators.Add('RG', Op_RGUC);
  FOperators.Add('rg', Op_rg);
  FOperators.Add('K',  Op_KUC);
  FOperators.Add('k',  Op_k);
  // Text state
  FOperators.Add('Tf', Op_Tf);
  FOperators.Add('Tc', Op_Tc);
  FOperators.Add('Tw', Op_Tw);
  FOperators.Add('Tz', Op_Tz);
  FOperators.Add('TL', Op_TL);
  FOperators.Add('Tr', Op_Tr);
  FOperators.Add('Ts', Op_Ts);
  // Text positioning
  FOperators.Add('Td', Op_Td);
  FOperators.Add('TD', Op_TDUC);
  FOperators.Add('Tm', Op_Tm);
  FOperators.Add('T*', Op_Tstar);
  // Text showing
  FOperators.Add('Tj', Op_Tj);
  FOperators.Add('TJ', Op_TJUC);
  FOperators.Add('''', Op_Quote);
  FOperators.Add('"',  Op_DQuote);
  // Text block
  FOperators.Add('BT', Op_BT);
  FOperators.Add('ET', Op_ET);
  // XObjects
  FOperators.Add('Do', Op_Do);
  // Marked content
  FOperators.Add('BMC', Op_BMC);
  FOperators.Add('BDC', Op_BDC);
  FOperators.Add('EMC', Op_EMC);
  FOperators.Add('MP',  Op_MP);
  FOperators.Add('DP',  Op_DP);
  // Compatibility
  FOperators.Add('BX', Op_BX);
  FOperators.Add('EX', Op_EX);
end;

// =========================================================================
// Process
// =========================================================================

procedure TPDFContentStreamProcessor.Process(const AData: TBytes;
  AResources: IPDFResources; AResolver: IObjectResolver);
begin
  if Length(AData) = 0 then Exit;
  var MS := TBytesStream.Create(AData);
  try
    ProcessStream(MS, AResources, AResolver);
  finally
    MS.Free;
  end;
end;

procedure TPDFContentStreamProcessor.ProcessStream(AStream: TStream;
  AResources: IPDFResources; AResolver: IObjectResolver);
var
  Lexer:  TPDFLexer;
  Args:   TList<TPDFObject>;
  Tok:    TPDFToken;
begin
  FResources := AResources;
  FResolver  := AResolver;
  FGS.Reset;

  Lexer := TPDFLexer.Create(AStream, False);
  Args  := TList<TPDFObject>.Create;
  try
    while True do
    begin
      Tok := Lexer.NextToken;
      if Tok.Kind = TPDFTokenKind.EndOfFile then Break;

      case Tok.Kind of
        TPDFTokenKind.Integer:
          Args.Add(TPDFInteger.Create(Tok.IntVal));
        TPDFTokenKind.Real:
          Args.Add(TPDFReal.Create(Tok.RealVal));
        TPDFTokenKind.LiteralString:
          Args.Add(TPDFString.Create(Tok.RawData, False));
        TPDFTokenKind.HexString:
          Args.Add(TPDFString.Create(Tok.RawData, True));
        TPDFTokenKind.Name:
          Args.Add(TPDFName.Create(Tok.Value));
        TPDFTokenKind.ArrayOpen:
        begin
          // Inline array (used in TJ operator)
          var Arr := TPDFArray.Create;
          while True do
          begin
            var ATok := Lexer.NextToken;
            if ATok.Kind in [TPDFTokenKind.ArrayClose, TPDFTokenKind.EndOfFile] then Break;
            case ATok.Kind of
              TPDFTokenKind.Integer: Arr.Add(TPDFInteger.Create(ATok.IntVal));
              TPDFTokenKind.Real:    Arr.Add(TPDFReal.Create(ATok.RealVal));
              TPDFTokenKind.LiteralString: Arr.Add(TPDFString.Create(ATok.RawData, False));
              TPDFTokenKind.HexString:     Arr.Add(TPDFString.Create(ATok.RawData, True));
              TPDFTokenKind.Name:          Arr.Add(TPDFName.Create(ATok.Value));
            end;
          end;
          Args.Add(Arr);
        end;
        TPDFTokenKind.DictOpen:
        begin
          // Skip dict (shouldn't appear in content streams normally)
          var Depth := 1;
          while Depth > 0 do
          begin
            var DTok := Lexer.NextToken;
            if DTok.Kind = TPDFTokenKind.EndOfFile then Break;
            if DTok.Kind = TPDFTokenKind.DictOpen  then Inc(Depth);
            if DTok.Kind = TPDFTokenKind.DictClose then Dec(Depth);
          end;
        end;

        TPDFTokenKind.InlineImageBegin:
        begin
          // BI ... ID <data> EI
          var ImgDict := TPDFDictionary.Create;
          // Read image dict (key/value pairs until ID)
          while True do
          begin
            var KTok := Lexer.NextToken;
            if (KTok.Kind = TPDFTokenKind.InlineImageData) or
               (KTok.Kind = TPDFTokenKind.EndOfFile) then Break;
            if KTok.Kind <> TPDFTokenKind.Name then Continue;
            var VTok := Lexer.NextToken;
            case VTok.Kind of
              TPDFTokenKind.Integer: ImgDict.SetValue(KTok.Value, TPDFInteger.Create(VTok.IntVal));
              TPDFTokenKind.Real:    ImgDict.SetValue(KTok.Value, TPDFReal.Create(VTok.RealVal));
              TPDFTokenKind.Name:    ImgDict.SetValue(KTok.Value, TPDFName.Create(VTok.Value));
              TPDFTokenKind.BooleanTrue:  ImgDict.SetValue(KTok.Value, TPDFBoolean.Create(True));
              TPDFTokenKind.BooleanFalse: ImgDict.SetValue(KTok.Value, TPDFBoolean.Create(False));
            end;
          end;
          // skip exactly 1 byte (whitespace) after ID
          Lexer.SkipBytes(1);
          // Read raw image data until EI marker
          // We scan for 'EI' preceded by whitespace
          // Simplified: read Width*Height*Components bytes based on dict
          var W := ImgDict.GetAsInteger('W', ImgDict.GetAsInteger('Width', 0));
          var H := ImgDict.GetAsInteger('H', ImgDict.GetAsInteger('Height', 0));
          var BPC := ImgDict.GetAsInteger('BPC', ImgDict.GetAsInteger('BitsPerComponent', 8));
          var CC := 3; // assume RGB; adjust by ColorSpace
          var CSName := ImgDict.GetAsName('CS', ImgDict.GetAsName('ColorSpace', 'DeviceRGB'));
          if CSName = 'DeviceGray' then CC := 1
          else if CSName = 'DeviceCMYK' then CC := 4;
          var DataLen := ((W * BPC * CC + 7) div 8) * H;
          var ImgData: TBytes;
          if DataLen > 0 then
            ImgData := Lexer.ReadRawBytes(DataLen);
          // Consume EI
          var EITok := Lexer.NextToken;
          if Assigned(FOnPaintInlineImage) then
            FOnPaintInlineImage(ImgDict, ImgData, FGS.Current);
          ImgDict.Free;
          Args.Clear;
          Continue;
        end;

        TPDFTokenKind.BooleanTrue:
          Args.Add(TPDFBoolean.Create(True));
        TPDFTokenKind.BooleanFalse:
          Args.Add(TPDFBoolean.Create(False));
        TPDFTokenKind.Null:
          Args.Add(TPDFNull.Instance);

        TPDFTokenKind.Keyword:
        begin
          // Dispatch operator
          var Op    := Tok.Value;
          var Proc: TOperatorProc;
          if FOperators.TryGetValue(Op, Proc) then
          try
            Proc(Args.ToArray);
          except
            on E: EPDFError do
              // Continue on non-fatal errors (spec allows malformed content)
              ;
          end;
          // Free operand objects
          for var Obj in Args do
            if not (Obj is TPDFNull) then // null is singleton
              Obj.Free;
          Args.Clear;
        end;
      end;
    end;
  finally
    // Free any remaining args
    for var Obj in Args do
      if not (Obj is TPDFNull) then Obj.Free;
    Args.Free;
    Lexer.Free;
  end;
end;

// =========================================================================
// Helper: extract numbers from args
// =========================================================================

function TPDFContentStreamProcessor.ArgsAsNumbers(const AArgs: TArray<TPDFObject>): TArray<Single>;
begin
  SetLength(Result, Length(AArgs));
  for var I := 0 to High(AArgs) do
    if AArgs[I].IsNumber then Result[I] := AArgs[I].AsNumber
    else Result[I] := 0;
end;

// =========================================================================
// Graphics state operators
// =========================================================================

procedure TPDFContentStreamProcessor.Op_q(const A: TArray<TPDFObject>);
begin
  FGS.Push;
  if Assigned(FOnSaveRestore) then FOnSaveRestore(True, FGS.Current);
end;

procedure TPDFContentStreamProcessor.Op_QUC(const A: TArray<TPDFObject>);
begin
  FGS.Pop;
  if Assigned(FOnSaveRestore) then FOnSaveRestore(False, FGS.Current);
end;

procedure TPDFContentStreamProcessor.Op_cm(const A: TArray<TPDFObject>);
begin
  if Length(A) < 6 then Exit;
  var N := ArgsAsNumbers(A);
  var M := TPDFMatrix.Make(N[0], N[1], N[2], N[3], N[4], N[5]);
  FGS.CurrentRef^.CTM := M * FGS.CurrentRef^.CTM;
end;

procedure TPDFContentStreamProcessor.Op_w(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 1 then
    FGS.CurrentRef^.LineWidth := A[0].AsNumber;
end;

procedure TPDFContentStreamProcessor.Op_JUC(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 1 then
    FGS.CurrentRef^.LineCap := TPDFLineCap(Round(A[0].AsNumber));
end;

procedure TPDFContentStreamProcessor.Op_j(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 1 then
    FGS.CurrentRef^.LineJoin := TPDFLineJoin(Round(A[0].AsNumber));
end;

procedure TPDFContentStreamProcessor.Op_MUC(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 1 then
    FGS.CurrentRef^.MiterLimit := A[0].AsNumber;
end;

procedure TPDFContentStreamProcessor.Op_d(const A: TArray<TPDFObject>);
begin
  if Length(A) < 2 then Exit;
  var Dash: TPDFDashPattern;
  Dash.Phase := A[1].AsNumber;
  if A[0].IsArray then
  begin
    var Arr := TPDFArray(A[0]);
    SetLength(Dash.Lengths, Arr.Count);
    for var I := 0 to Arr.Count - 1 do
      Dash.Lengths[I] := Arr.GetAsReal(I);
  end;
  FGS.CurrentRef^.Dash := Dash;
end;

procedure TPDFContentStreamProcessor.Op_ri(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 1 then
    FGS.CurrentRef^.RenderingIntent := PDFRenderingIntentFromName(A[0].AsName);
end;

procedure TPDFContentStreamProcessor.Op_i(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 1 then
    FGS.CurrentRef^.Flatness := A[0].AsNumber;
end;

procedure TPDFContentStreamProcessor.Op_gs(const A: TArray<TPDFObject>);
begin
  if (Length(A) < 1) or not A[0].IsName then Exit;
  if FResources = nil then Exit;
  var ExtGS := FResources.GetExtGState(A[0].AsName);
  if ExtGS <> nil then
    ApplyExtGState(ExtGS);
end;

procedure TPDFContentStreamProcessor.ApplyExtGState(ADict: TPDFDictionary);
begin
  if ADict.Contains('LW')  then FGS.CurrentRef^.LineWidth := ADict.GetAsReal('LW');
  if ADict.Contains('LC')  then FGS.CurrentRef^.LineCap   := TPDFLineCap(ADict.GetAsInteger('LC'));
  if ADict.Contains('LJ')  then FGS.CurrentRef^.LineJoin  := TPDFLineJoin(ADict.GetAsInteger('LJ'));
  if ADict.Contains('ML')  then FGS.CurrentRef^.MiterLimit:= ADict.GetAsReal('ML');
  if ADict.Contains('CA')  then FGS.CurrentRef^.StrokeAlpha := ADict.GetAsReal('CA', 1.0);
  if ADict.Contains('ca')  then FGS.CurrentRef^.FillAlpha   := ADict.GetAsReal('ca', 1.0);
  if ADict.Contains('BM')  then
  begin
    var BM := ADict.Get('BM');
    if BM <> nil then
      FGS.CurrentRef^.BlendMode := PDFBlendModeFromName(BM.AsName);
  end;
  if ADict.Contains('AIS') then FGS.CurrentRef^.AlphaIsShape := ADict.GetAsBoolean('AIS');
  if ADict.Contains('FL')  then FGS.CurrentRef^.Flatness := ADict.GetAsReal('FL');
  if ADict.Contains('SM')  then FGS.CurrentRef^.Smoothness := ADict.GetAsReal('SM');
  if ADict.Contains('ri')  then
    FGS.CurrentRef^.RenderingIntent := PDFRenderingIntentFromName(ADict.GetAsName('ri'));
end;

// =========================================================================
// Path construction
// =========================================================================

procedure TPDFContentStreamProcessor.Op_m(const A: TArray<TPDFObject>);
begin
  if Length(A) < 2 then Exit;
  var X := Single(A[0].AsNumber); var Y := Single(A[1].AsNumber);
  FPath.MoveTo(X, Y);
  SetCurrentPoint(X, Y);
end;

procedure TPDFContentStreamProcessor.Op_l(const A: TArray<TPDFObject>);
begin
  if Length(A) < 2 then Exit;
  var X := Single(A[0].AsNumber); var Y := Single(A[1].AsNumber);
  FPath.LineTo(X, Y);
  SetCurrentPoint(X, Y);
end;

procedure TPDFContentStreamProcessor.Op_c(const A: TArray<TPDFObject>);
begin
  if Length(A) < 6 then Exit;
  var N := ArgsAsNumbers(A);
  FPath.CurveTo(N[0], N[1], N[2], N[3], N[4], N[5]);
  SetCurrentPoint(N[4], N[5]);
end;

procedure TPDFContentStreamProcessor.Op_v(const A: TArray<TPDFObject>);
begin
  if Length(A) < 4 then Exit;
  var N := ArgsAsNumbers(A);
  FPath.CurveToV(N[0], N[1], N[2], N[3]);
  SetCurrentPoint(N[2], N[3]);
end;

procedure TPDFContentStreamProcessor.Op_y(const A: TArray<TPDFObject>);
begin
  if Length(A) < 4 then Exit;
  var N := ArgsAsNumbers(A);
  FPath.CurveToY(N[0], N[1], N[2], N[3]);
  SetCurrentPoint(N[2], N[3]);
end;

procedure TPDFContentStreamProcessor.Op_h(const A: TArray<TPDFObject>);
begin
  FPath.ClosePath;
end;

procedure TPDFContentStreamProcessor.Op_re(const A: TArray<TPDFObject>);
begin
  if Length(A) < 4 then Exit;
  var N := ArgsAsNumbers(A);
  FPath.AddRect(N[0], N[1], N[2], N[3]);
  SetCurrentPoint(N[0], N[1]);
end;

// =========================================================================
// Path painting
// =========================================================================

procedure TPDFContentStreamProcessor.Op_SUC(const A: TArray<TPDFObject>);
begin
  if Assigned(FOnPaintPath) then
    FOnPaintPath(FPath, FGS.Current, TPDFPaintOp.Stroke);
  FPath.Clear;
end;

procedure TPDFContentStreamProcessor.Op_s(const A: TArray<TPDFObject>);
begin
  FPath.ClosePath;
  Op_SUC(A);
end;

procedure TPDFContentStreamProcessor.Op_f(const A: TArray<TPDFObject>);
begin
  if Assigned(FOnPaintPath) then
    FOnPaintPath(FPath, FGS.Current, TPDFPaintOp.Fill);
  FPath.Clear;
end;

procedure TPDFContentStreamProcessor.Op_FUC(const A: TArray<TPDFObject>);
begin
  Op_f(A);
end;

procedure TPDFContentStreamProcessor.Op_fstar(const A: TArray<TPDFObject>);
begin
  if Assigned(FOnPaintPath) then
    FOnPaintPath(FPath, FGS.Current, TPDFPaintOp.FillEvenOdd);
  FPath.Clear;
end;

procedure TPDFContentStreamProcessor.Op_BUC(const A: TArray<TPDFObject>);
begin
  if Assigned(FOnPaintPath) then
    FOnPaintPath(FPath, FGS.Current, TPDFPaintOp.FillAndStroke);
  FPath.Clear;
end;

procedure TPDFContentStreamProcessor.Op_BstarUC(const A: TArray<TPDFObject>);
begin
  if Assigned(FOnPaintPath) then
    FOnPaintPath(FPath, FGS.Current, TPDFPaintOp.FillEvenOddAndStroke);
  FPath.Clear;
end;

procedure TPDFContentStreamProcessor.Op_b(const A: TArray<TPDFObject>);
begin
  FPath.ClosePath;
  Op_BUC(A);
end;

procedure TPDFContentStreamProcessor.Op_bstar(const A: TArray<TPDFObject>);
begin
  FPath.ClosePath;
  Op_BstarUC(A);
end;

procedure TPDFContentStreamProcessor.Op_n(const A: TArray<TPDFObject>);
begin
  FPath.Clear;
end;

// =========================================================================
// Clipping
// =========================================================================

procedure TPDFContentStreamProcessor.Op_WUC(const A: TArray<TPDFObject>);
begin
  if Assigned(FOnPaintPath) then
    FOnPaintPath(FPath, FGS.Current, TPDFPaintOp.ClipNonZero);
  // Path is NOT cleared after clip (painting op follows immediately)
end;

procedure TPDFContentStreamProcessor.Op_Wstar(const A: TArray<TPDFObject>);
begin
  if Assigned(FOnPaintPath) then
    FOnPaintPath(FPath, FGS.Current, TPDFPaintOp.ClipEvenOdd);
end;

// =========================================================================
// Color operators
// =========================================================================

procedure TPDFContentStreamProcessor.SetColorFromArgs(const AArgs: TArray<TPDFObject>;
  AIsStroke: Boolean; const ACSName: string);
var
  N:     TArray<Single>;
  Color: TPDFColor;
begin
  N := ArgsAsNumbers(AArgs);
  if ACSName = 'DeviceGray' then
    Color := TPDFColor.MakeGray(N[0])
  else if ACSName = 'DeviceRGB' then
    Color := TPDFColor.MakeRGB(N[0], N[1], N[2])
  else if ACSName = 'DeviceCMYK' then
    Color := TPDFColor.MakeCMYK(N[0], N[1], N[2], N[3])
  else
  begin
    // Try to resolve color space and convert
    Color := TPDFColor.Black;
    if (FResources <> nil) and (ACSName <> '') then
    begin
      var CS := FResources.GetColorSpace(ACSName);
      if (CS <> nil) and (Length(N) >= CS.ComponentCount) then
        Color := CS.ToColor(N);
    end;
  end;

  if AIsStroke then
    FGS.CurrentRef^.StrokeColor := Color
  else
    FGS.CurrentRef^.FillColor := Color;
end;

procedure TPDFContentStreamProcessor.Op_CSUC(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 1 then
    FGS.CurrentRef^.StrokeColorSpace := A[0].AsName;
end;

procedure TPDFContentStreamProcessor.Op_cs(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 1 then
    FGS.CurrentRef^.FillColorSpace := A[0].AsName;
end;

procedure TPDFContentStreamProcessor.Op_SCUC(const A: TArray<TPDFObject>);
begin
  SetColorFromArgs(A, True, FGS.Current.StrokeColorSpace);
end;

procedure TPDFContentStreamProcessor.Op_sc(const A: TArray<TPDFObject>);
begin
  SetColorFromArgs(A, False, FGS.Current.FillColorSpace);
end;

procedure TPDFContentStreamProcessor.Op_SCNUC(const A: TArray<TPDFObject>);
begin
  // Extended version — last arg may be a Name (pattern)
  SetColorFromArgs(A, True, FGS.Current.StrokeColorSpace);
end;

procedure TPDFContentStreamProcessor.Op_scn(const A: TArray<TPDFObject>);
begin
  SetColorFromArgs(A, False, FGS.Current.FillColorSpace);
end;

procedure TPDFContentStreamProcessor.Op_GUC(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 1 then
  begin
    FGS.CurrentRef^.StrokeColorSpace := 'DeviceGray';
    FGS.CurrentRef^.StrokeColor := TPDFColor.MakeGray(A[0].AsNumber);
  end;
end;

procedure TPDFContentStreamProcessor.Op_g(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 1 then
  begin
    FGS.CurrentRef^.FillColorSpace := 'DeviceGray';
    FGS.CurrentRef^.FillColor := TPDFColor.MakeGray(A[0].AsNumber);
  end;
end;

procedure TPDFContentStreamProcessor.Op_RGUC(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 3 then
  begin
    FGS.CurrentRef^.StrokeColorSpace := 'DeviceRGB';
    FGS.CurrentRef^.StrokeColor := TPDFColor.MakeRGB(A[0].AsNumber, A[1].AsNumber, A[2].AsNumber);
  end;
end;

procedure TPDFContentStreamProcessor.Op_rg(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 3 then
  begin
    FGS.CurrentRef^.FillColorSpace := 'DeviceRGB';
    FGS.CurrentRef^.FillColor := TPDFColor.MakeRGB(A[0].AsNumber, A[1].AsNumber, A[2].AsNumber);
  end;
end;

procedure TPDFContentStreamProcessor.Op_KUC(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 4 then
  begin
    FGS.CurrentRef^.StrokeColorSpace := 'DeviceCMYK';
    FGS.CurrentRef^.StrokeColor := TPDFColor.MakeCMYK(A[0].AsNumber, A[1].AsNumber,
      A[2].AsNumber, A[3].AsNumber);
  end;
end;

procedure TPDFContentStreamProcessor.Op_k(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 4 then
  begin
    FGS.CurrentRef^.FillColorSpace := 'DeviceCMYK';
    FGS.CurrentRef^.FillColor := TPDFColor.MakeCMYK(A[0].AsNumber, A[1].AsNumber,
      A[2].AsNumber, A[3].AsNumber);
  end;
end;

// =========================================================================
// Text state
// =========================================================================

procedure TPDFContentStreamProcessor.Op_Tf(const A: TArray<TPDFObject>);
begin
  if Length(A) < 2 then Exit;
  var FontName := A[0].AsName;
  var FontSize := Single(A[1].AsNumber);
  FGS.CurrentRef^.Text.FontSize := FontSize;
  if FResources <> nil then
    FGS.CurrentRef^.Text.Font := FResources.GetFont(FontName);
end;

procedure TPDFContentStreamProcessor.Op_Tc(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 1 then FGS.CurrentRef^.Text.CharSpacing := A[0].AsNumber;
end;

procedure TPDFContentStreamProcessor.Op_Tw(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 1 then FGS.CurrentRef^.Text.WordSpacing := A[0].AsNumber;
end;

procedure TPDFContentStreamProcessor.Op_Tz(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 1 then FGS.CurrentRef^.Text.HorizScaling := A[0].AsNumber / 100.0;
end;

procedure TPDFContentStreamProcessor.Op_TL(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 1 then FGS.CurrentRef^.Text.Leading := A[0].AsNumber;
end;

procedure TPDFContentStreamProcessor.Op_Tr(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 1 then
    FGS.CurrentRef^.Text.RenderMode := TPDFTextRenderMode(Round(A[0].AsNumber));
end;

procedure TPDFContentStreamProcessor.Op_Ts(const A: TArray<TPDFObject>);
begin
  if Length(A) >= 1 then FGS.CurrentRef^.Text.TextRise := A[0].AsNumber;
end;

// =========================================================================
// Text positioning
// =========================================================================

procedure TPDFContentStreamProcessor.Op_BT(const A: TArray<TPDFObject>);
begin
  FGS.CurrentRef^.Text.TextMatrix     := TPDFMatrix.Identity;
  FGS.CurrentRef^.Text.TextLineMatrix := TPDFMatrix.Identity;
end;

procedure TPDFContentStreamProcessor.Op_ET(const A: TArray<TPDFObject>);
begin
  // End text block — no state change needed beyond what BT reset
end;

procedure TPDFContentStreamProcessor.Op_Td(const A: TArray<TPDFObject>);
begin
  if Length(A) < 2 then Exit;
  var TX := Single(A[0].AsNumber); var TY := Single(A[1].AsNumber);
  var M := TPDFMatrix.MakeTranslate(TX, TY);
  FGS.CurrentRef^.Text.TextLineMatrix := M * FGS.Current.Text.TextLineMatrix;
  FGS.CurrentRef^.Text.TextMatrix     := FGS.Current.Text.TextLineMatrix;
end;

procedure TPDFContentStreamProcessor.Op_TDUC(const A: TArray<TPDFObject>);
begin
  if Length(A) < 2 then Exit;
  FGS.CurrentRef^.Text.Leading := -Single(A[1].AsNumber);
  Op_Td(A);
end;

procedure TPDFContentStreamProcessor.Op_Tm(const A: TArray<TPDFObject>);
begin
  if Length(A) < 6 then Exit;
  var N := ArgsAsNumbers(A);
  var M := TPDFMatrix.Make(N[0], N[1], N[2], N[3], N[4], N[5]);
  FGS.CurrentRef^.Text.TextMatrix     := M;
  FGS.CurrentRef^.Text.TextLineMatrix := M;
end;

procedure TPDFContentStreamProcessor.Op_Tstar(const A: TArray<TPDFObject>);
begin
  var L := FGS.Current.Text.Leading;
  var FakeArgs: TArray<TPDFObject> := [TPDFReal.Create(0), TPDFReal.Create(-L)];
  Op_Td(FakeArgs);
  FakeArgs[0].Free;
  FakeArgs[1].Free;
end;

// =========================================================================
// Text showing
// =========================================================================

procedure TPDFContentStreamProcessor.ShowString(const ABytes: RawByteString);
var
  I: Integer;
begin
  var Font := FGS.Current.Text.Font;
  var GS   := FGS.Current;
  I := 1;
  while I <= Length(ABytes) do
  begin
    var CharCode: Integer;
    // For multi-byte CID fonts (Type0), read 2 bytes; otherwise 1
    if (Font <> nil) and (Font.FontType = TPDFFontType.Type0) then
    begin
      if I + 1 <= Length(ABytes) then
      begin
        CharCode := (Ord(ABytes[I]) shl 8) or Ord(ABytes[I+1]);
        Inc(I, 2);
      end else
      begin
        CharCode := Ord(ABytes[I]);
        Inc(I);
      end;
    end else
    begin
      CharCode := Ord(ABytes[I]);
      Inc(I);
    end;

    var GlyphWidth: Single;
    if Font <> nil then
      GlyphWidth := Font.GetWidth(CharCode)
    else
      GlyphWidth := 1000;

    EmitGlyph(CharCode, GlyphWidth);

    // Advance text position
    var TS := GS.Text;
    var TW := Single(0);
    if CharCode = 32 then TW := TS.WordSpacing;
    var Advance := (GlyphWidth / 1000.0 * TS.FontSize + TS.CharSpacing + TW)
                   * TS.HorizScaling;
    FGS.CurrentRef^.Text.TextMatrix :=
      TPDFMatrix.MakeTranslate(Advance, 0) * FGS.Current.Text.TextMatrix;
  end;
end;

procedure TPDFContentStreamProcessor.EmitGlyph(ACharCode: Integer; AGlyphWidth: Single);
begin
  if not Assigned(FOnPaintGlyph) then Exit;

  var GS   := FGS.Current;
  var TS   := GS.Text;
  var Font := TS.Font;

  var Glyph: TPDFGlyphInfo;
  Glyph.CharCode := ACharCode;
  Glyph.Unicode  := '';
  if Font <> nil then
    Glyph.Unicode := Font.CharCodeToUnicode(ACharCode);
  Glyph.Width  := AGlyphWidth;

  // Text rendering matrix = [fontSize*Th 0 0 fontSize Th*Ts 0] × Tm × CTM
  var FS := TS.FontSize;
  var Th := TS.HorizScaling;
  var TRise := TS.TextRise;
  var TextRenderMatrix := TPDFMatrix.Make(FS * Th, 0, 0, FS, 0, TRise);
  Glyph.GlyphMatrix := TextRenderMatrix * TS.TextMatrix * GS.CTM;

  // Current text position in user space
  var P := TS.TextMatrix.Transform(TPointF.Create(0, 0));
  Glyph.X := P.X;
  Glyph.Y := P.Y;

  FOnPaintGlyph(Glyph, GS);
end;

procedure TPDFContentStreamProcessor.Op_Tj(const A: TArray<TPDFObject>);
begin
  if (Length(A) >= 1) and A[0].IsString then
    ShowString(A[0].AsString);
end;

procedure TPDFContentStreamProcessor.Op_TJUC(const A: TArray<TPDFObject>);
begin
  if (Length(A) < 1) or not A[0].IsArray then Exit;
  var Arr := TPDFArray(A[0]);
  for var I := 0 to Arr.Count - 1 do
  begin
    var Item := Arr.Items(I);
    if Item.IsString then
      ShowString(Item.AsString)
    else if Item.IsNumber then
    begin
      // Negative = move right; positive = move left (kerning adjust in 1/1000 em)
      var Adjust := -Item.AsNumber / 1000.0
                    * FGS.Current.Text.FontSize
                    * FGS.Current.Text.HorizScaling;
      FGS.CurrentRef^.Text.TextMatrix :=
        TPDFMatrix.MakeTranslate(Adjust, 0) * FGS.Current.Text.TextMatrix;
    end;
  end;
end;

procedure TPDFContentStreamProcessor.Op_Quote(const A: TArray<TPDFObject>);
begin
  // ' = T* Tj
  Op_Tstar([]);
  Op_Tj(A);
end;

procedure TPDFContentStreamProcessor.Op_DQuote(const A: TArray<TPDFObject>);
begin
  // " aw ac string = aw Tw ac Tc string '
  if Length(A) < 3 then Exit;
  Op_Tw([A[0]]);
  Op_Tc([A[1]]);
  Op_Quote([A[2]]);
end;

// =========================================================================
// XObjects
// =========================================================================

procedure TPDFContentStreamProcessor.Op_Do(const A: TArray<TPDFObject>);
begin
  if (Length(A) < 1) or not A[0].IsName then Exit;
  if Assigned(FOnPaintXObject) then
    FOnPaintXObject(A[0].AsName, FGS.Current.CTM, FGS.Current);
end;

// =========================================================================
// Marked content / compatibility — all ignored
// =========================================================================

procedure TPDFContentStreamProcessor.Op_BMC(const A: TArray<TPDFObject>); begin end;
procedure TPDFContentStreamProcessor.Op_BDC(const A: TArray<TPDFObject>); begin end;
procedure TPDFContentStreamProcessor.Op_EMC(const A: TArray<TPDFObject>); begin end;
procedure TPDFContentStreamProcessor.Op_MP(const A: TArray<TPDFObject>);  begin end;
procedure TPDFContentStreamProcessor.Op_DP(const A: TArray<TPDFObject>);  begin end;
procedure TPDFContentStreamProcessor.Op_BX(const A: TArray<TPDFObject>);  begin end;
procedure TPDFContentStreamProcessor.Op_EX(const A: TArray<TPDFObject>);  begin end;

end.
