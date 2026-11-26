unit uPDF.TIFF;

{$SCOPEDENUMS ON}

// ============================================================================
// uPDF.TIFF — reads a TIFF (classic, II or MM, one or many pages) into the
// pieces a PDF needs to show it, without changing what was scanned:
//
//   CCITT Group 4   the strips go to the PDF as they are (/CCITTFaxDecode,
//                   K -1), after checking that they decode; one image per
//                   strip, stacked on the page.
//   JPEG (7)        the strips go as they are (/DCTDecode), with the
//                   JPEGTables merged in.
//   the rest        decoded to pixels (none, LZW, PackBits, Deflate, CCITT
//                   Group 3 and Modified Huffman): 1-bit images stay 1-bit;
//                   gray, RGB and palette become 8-bit gray or RGB; alpha is
//                   composited on white.
//
// Not supported (Why says so): BigTIFF, tiles, planar configuration 2, CMYK,
// YCbCr without JPEG, old-style JPEG (6), floating point samples. Reduced
// resolution images (thumbnails, NewSubfileType bit 0) are skipped.
//
// License: CC0 1.0 Universal (public domain).
// ============================================================================

interface

uses
  System.SysUtils;

type
  TTiffPieceKind = (Pixels, CCITT, JPEG);

  /// one image of a page: the whole page, or one strip (CCITT, JPEG)
  TTiffPiece = record
    Kind: TTiffPieceKind;
    Data: TBytes;
    Width, Rows: Integer;
    /// first row of the piece on the page
    Top: Integer;
    /// DeviceGray or DeviceRGB
    ColorSpace: string;
    /// 1 or 8 (Pixels and CCITT: 1 for bilevel)
    Bpc: Integer;
    /// Pixels, 1-bit: /Decode [1 0] (0 is white in the TIFF)
    Invert: Boolean;
    /// CCITT: /BlackIs1
    BlackIs1: Boolean;
    /// JPEG: /ColorTransform 0 (RGB JPEG, not YCbCr)
    NoColorTransform: Boolean;
  end;

  TTiffPage = record
    Width, Height: Integer;
    DpiX, DpiY: Double;
    Pieces: TArray<TTiffPiece>;
  end;

function IsTiff(const B: TBytes): Boolean;

/// all the pages of B; False with Why when one of them cannot be read
function ReadTiff(const B: TBytes; out Pages: TArray<TTiffPage>; out Why: string): Boolean;

/// TIFF LZW (MSB first, early change), as libtiff writes it
function TiffLzwDecode(const Src: TBytes; MaxOut: Integer): TBytes;
function PackBitsDecode(const Src: TBytes; MaxOut: Integer): TBytes;

implementation

uses
  System.Classes, System.Math, System.ZLib, System.Generics.Collections,
  uPDF.CCITTFax;

const
  T_NEWSUBFILETYPE = 254;
  T_WIDTH = 256;
  T_HEIGHT = 257;
  T_BITS = 258;
  T_COMPRESSION = 259;
  T_PHOTOMETRIC = 262;
  T_FILLORDER = 266;
  T_STRIPOFFSETS = 273;
  T_SAMPLES = 277;
  T_ROWSPERSTRIP = 278;
  T_STRIPBYTES = 279;
  T_XRES = 282;
  T_YRES = 283;
  T_PLANAR = 284;
  T_T4OPTIONS = 292;
  T_RESUNIT = 296;
  T_PREDICTOR = 317;
  T_COLORMAP = 320;
  T_TILEWIDTH = 322;
  T_EXTRASAMPLES = 338;
  T_SAMPLEFORMAT = 339;
  T_JPEGTABLES = 347;

  MAX_PIXELS = 400000000; // 400 MP: an A0 at 600 dpi is about 140 MP
  MAX_PAGES = 10000;

type
  ETiff = class(Exception);

  TEntry = record
    Typ: Integer;
    Count: Int64;
    Pos: Int64; // where the values are
  end;

  TReader = class
  private
    B: TBytes;
    LE: Boolean;
    Tags: TDictionary<Integer, TEntry>;
    function U16(P: Int64): Integer;
    function U32(P: Int64): Int64;
    procedure Need(P, N: Int64);
    function TypeSize(T: Integer): Integer;
    function Has(Tag: Integer): Boolean;
    function Ints(Tag: Integer): TArray<Int64>;
    function Int(Tag: Integer; Def: Int64): Int64;
    function Rational(Tag: Integer; Def: Double): Double;
    function Bytes(Tag: Integer): TBytes;
    procedure LoadIfd(P: Int64; out Next: Int64);
    function ReadPage: TTiffPage;
  public
    constructor Create(const AB: TBytes);
    destructor Destroy; override;
  end;

function IsTiff(const B: TBytes): Boolean;
begin
  Result := (Length(B) >= 8) and
    (((B[0] = Ord('I')) and (B[1] = Ord('I')) and (B[2] = 42) and (B[3] = 0)) or
     ((B[0] = Ord('M')) and (B[1] = Ord('M')) and (B[2] = 0) and (B[3] = 42)));
end;

var
  BitRev: array[Byte] of Byte;

procedure InitBitRev;
begin
  for var I := 0 to 255 do
  begin
    var R := 0;
    for var J := 0 to 7 do
      if (I and (1 shl J)) <> 0 then
        R := R or (1 shl (7 - J));
    BitRev[I] := R;
  end;
end;

{ ---- decoders ---- }

function TiffLzwDecode(const Src: TBytes; MaxOut: Integer): TBytes;
const
  CLEAR = 256;
  EOI = 257;
var
  Prefix: array[0..4095] of Integer;
  Suffix, First: array[0..4095] of Byte;
  Len: array[0..4095] of Integer;
  Bits, Next, Old, Code, BitPos, N, OutLen: Integer;
  TotalBits: Int64;

  function ReadCode: Integer;
  begin
    if BitPos + Bits > TotalBits then
      Exit(EOI);
    Result := 0;
    for var I := 0 to Bits - 1 do
    begin
      Result := (Result shl 1) or ((Src[BitPos shr 3] shr (7 - (BitPos and 7))) and 1);
      Inc(BitPos);
    end;
  end;

  procedure Emit(C: Integer);
  var
    L, P: Integer;
  begin
    L := Len[C];
    if OutLen + L > Length(Result) then
      SetLength(Result, Max(OutLen + L, Length(Result) * 2));
    P := OutLen + L - 1;
    while C > 255 do
    begin
      Result[P] := Suffix[C];
      Dec(P);
      C := Prefix[C];
    end;
    Result[P] := C;
    Inc(OutLen, L);
  end;

begin
  for var I := 0 to 255 do
  begin
    Prefix[I] := -1;
    Suffix[I] := I;
    First[I] := I;
    Len[I] := 1;
  end;
  SetLength(Result, Max(1024, Min(MaxOut, Length(Src) * 4)));
  OutLen := 0;
  BitPos := 0;
  TotalBits := Int64(Length(Src)) * 8;
  Bits := 9;
  Next := 258;
  Old := -1;
  while OutLen < MaxOut do
  begin
    Code := ReadCode;
    if Code = EOI then
      Break;
    if Code = CLEAR then
    begin
      Bits := 9;
      Next := 258;
      Old := -1;
      Continue;
    end;
    if Old = -1 then
    begin
      if Code > 255 then
        raise ETiff.Create('LZW dañado');
      Emit(Code);
      Old := Code;
      Continue;
    end;
    // the new entry is Old + the first byte of Code (of Old itself when Code
    // is the one being defined: the KwKwK case)
    if Code < Next then
      N := First[Code]
    else if (Code = Next) and (Next < 4096) then
      N := First[Old]
    else
      raise ETiff.Create('LZW dañado');
    if Next < 4096 then
    begin
      Prefix[Next] := Old;
      Suffix[Next] := N;
      First[Next] := First[Old];
      Len[Next] := Len[Old] + 1;
      Inc(Next);
    end;
    Emit(Code);
    // early change: libtiff switches one code before the table fills
    if (Next + 1 >= (1 shl Bits)) and (Bits < 12) then
      Inc(Bits);
    Old := Code;
  end;
  SetLength(Result, Min(OutLen, MaxOut));
end;

function PackBitsDecode(const Src: TBytes; MaxOut: Integer): TBytes;
var
  I, O, N: Integer;
begin
  SetLength(Result, MaxOut);
  I := 0;
  O := 0;
  while (I < Length(Src)) and (O < MaxOut) do
  begin
    N := ShortInt(Src[I]);
    Inc(I);
    if N >= 0 then
    begin
      N := Min(N + 1, Min(Length(Src) - I, MaxOut - O));
      Move(Src[I], Result[O], N);
      Inc(I, N);
      Inc(O, N);
    end
    else if N <> -128 then
    begin
      if I >= Length(Src) then
        Break;
      N := Min(1 - N, MaxOut - O);
      FillChar(Result[O], N, Src[I]);
      Inc(I);
      Inc(O, N);
    end;
  end;
  SetLength(Result, O);
end;

function Inflate(const Src: TBytes; MaxOut: Integer): TBytes;
var
  Inp, Out_: TBytesStream;
  Z: TZDecompressionStream;
begin
  Inp := TBytesStream.Create(Src);
  Out_ := TBytesStream.Create;
  try
    Z := TZDecompressionStream.Create(Inp);
    try
      try
        Out_.CopyFrom(Z, 0);
      except
        // a truncated stream: keep what came out (checked by the caller)
      end;
    finally
      Z.Free;
    end;
    Result := Copy(Out_.Bytes, 0, Min(Out_.Size, MaxOut));
  finally
    Out_.Free;
    Inp.Free;
  end;
end;

{ ---- TReader ---- }

constructor TReader.Create(const AB: TBytes);
begin
  inherited Create;
  B := AB;
  LE := B[0] = Ord('I');
  Tags := TDictionary<Integer, TEntry>.Create;
end;

destructor TReader.Destroy;
begin
  Tags.Free;
  inherited;
end;

procedure TReader.Need(P, N: Int64);
begin
  if (P < 0) or (N < 0) or (P + N > Length(B)) then
    raise ETiff.Create('TIFF incompleto o dañado');
end;

function TReader.U16(P: Int64): Integer;
begin
  Need(P, 2);
  if LE then
    Result := B[P] or (B[P + 1] shl 8)
  else
    Result := (B[P] shl 8) or B[P + 1];
end;

function TReader.U32(P: Int64): Int64;
begin
  Need(P, 4);
  if LE then
    Result := Int64(B[P]) or (Int64(B[P + 1]) shl 8) or (Int64(B[P + 2]) shl 16) or (Int64(B[P + 3]) shl 24)
  else
    Result := (Int64(B[P]) shl 24) or (Int64(B[P + 1]) shl 16) or (Int64(B[P + 2]) shl 8) or Int64(B[P + 3]);
end;

function TReader.TypeSize(T: Integer): Integer;
begin
  case T of
    1, 2, 6, 7: Result := 1;
    3, 8: Result := 2;
    4, 9, 11: Result := 4;
    5, 10, 12: Result := 8;
  else
    Result := 0;
  end;
end;

procedure TReader.LoadIfd(P: Int64; out Next: Int64);
var
  N: Integer;
  E: TEntry;
begin
  Tags.Clear;
  N := U16(P);
  Need(P + 2, Int64(N) * 12 + 4);
  for var I := 0 to N - 1 do
  begin
    var Q := P + 2 + I * 12;
    var Tag := U16(Q);
    E.Typ := U16(Q + 2);
    E.Count := U32(Q + 4);
    var Size := TypeSize(E.Typ) * E.Count;
    if Size <= 4 then
      E.Pos := Q + 8
    else
      E.Pos := U32(Q + 8);
    if TypeSize(E.Typ) = 0 then
      Continue; // unknown type: ignored, as the spec says
    Need(E.Pos, Size);
    Tags.AddOrSetValue(Tag, E);
  end;
  Next := U32(P + 2 + Int64(N) * 12);
end;

function TReader.Has(Tag: Integer): Boolean;
begin
  Result := Tags.ContainsKey(Tag);
end;

function TReader.Ints(Tag: Integer): TArray<Int64>;
var
  E: TEntry;
begin
  Result := nil;
  if not Tags.TryGetValue(Tag, E) then
    Exit;
  SetLength(Result, E.Count);
  for var I := 0 to E.Count - 1 do
    case E.Typ of
      1, 6, 7: Result[I] := B[E.Pos + I];
      3, 8: Result[I] := U16(E.Pos + I * 2);
      4, 9: Result[I] := U32(E.Pos + I * 4);
    else
      raise ETiff.Create(Format('TIFF: la etiqueta %d no es un entero', [Tag]));
    end;
end;

function TReader.Int(Tag: Integer; Def: Int64): Int64;
var
  A: TArray<Int64>;
begin
  A := Ints(Tag);
  if A = nil then
    Result := Def
  else
    Result := A[0];
end;

function TReader.Rational(Tag: Integer; Def: Double): Double;
var
  E: TEntry;
begin
  Result := Def;
  if not Tags.TryGetValue(Tag, E) or (E.Count < 1) then
    Exit;
  if E.Typ = 5 then
  begin
    var D := U32(E.Pos + 4);
    if D <> 0 then
      Result := U32(E.Pos) / D;
  end
  else if E.Typ in [3, 4] then
    Result := Int(Tag, 0);
end;

function TReader.Bytes(Tag: Integer): TBytes;
var
  E: TEntry;
begin
  Result := nil;
  if Tags.TryGetValue(Tag, E) then
    Result := Copy(B, E.Pos, E.Count * TypeSize(E.Typ));
end;

function TReader.ReadPage: TTiffPage;
var
  W, H, Comp, Photo, Spp, Bps, Rps, Fill, Pred, Planar, Extra: Integer;
  Offs, Counts, Bits, Cmap, Ex: TArray<Int64>;
  Stride: Int64;
  Unit_: Integer;
  Gray, Bilevel, HasAlpha, Premult: Boolean;
  Strip, Raw, Pix: TBytes;
  Pieces: TList<TTiffPiece>;
  Piece: TTiffPiece;
  OutStride, Row0, Rows: Integer;

  function StripBytes(I: Integer): TBytes;
  begin
    Need(Offs[I], Counts[I]);
    Result := Copy(B, Offs[I], Counts[I]);
    if Fill = 2 then
      for var J := 0 to High(Result) do
        Result[J] := BitRev[Result[J]];
  end;

  function Sample(const Row: TBytes; RowPos: Int64; X, Ch: Integer): Integer;
  var
    Bit: Int64;
  begin
    case Bps of
      8: Result := Row[RowPos + X * Spp + Ch];
      16:
        if LE then
          Result := Row[RowPos + (X * Spp + Ch) * 2 + 1]
        else
          Result := Row[RowPos + (X * Spp + Ch) * 2];
    else
      begin
        Bit := Int64(X * Spp + Ch) * Bps;
        Result := (Row[RowPos + Bit div 8] shr (8 - Bps - Bit mod 8)) and ((1 shl Bps) - 1);
        if Photo <> 3 then
          Result := Result * 255 div ((1 shl Bps) - 1);
      end;
    end;
  end;

begin
  Result := Default(TTiffPage);
  if Has(T_TILEWIDTH) then
    raise ETiff.Create('TIFF en mosaicos (tiles): no se admite todavía');
  W := Int(T_WIDTH, 0);
  H := Int(T_HEIGHT, 0);
  if (W <= 0) or (H <= 0) then
    raise ETiff.Create('TIFF sin dimensiones');
  if Int64(W) * H > MAX_PIXELS then
    raise ETiff.Create('TIFF demasiado grande');
  Comp := Int(T_COMPRESSION, 1);
  Photo := Int(T_PHOTOMETRIC, -1);
  Spp := Int(T_SAMPLES, 1);
  Bits := Ints(T_BITS);
  if Bits = nil then
    Bps := 1
  else
    Bps := Bits[0];
  for var X in Bits do
    if X <> Bps then
      raise ETiff.Create('TIFF con muestras de distinto tamaño');
  Rps := Min(Int64(H), Int(T_ROWSPERSTRIP, H));
  if Rps <= 0 then
    Rps := H;
  Fill := Int(T_FILLORDER, 1);
  Pred := Int(T_PREDICTOR, 1);
  Planar := Int(T_PLANAR, 1);
  Offs := Ints(T_STRIPOFFSETS);
  Counts := Ints(T_STRIPBYTES);
  if (Offs = nil) or (Length(Counts) <> Length(Offs)) or
     (Length(Offs) < (H + Rps - 1) div Rps) then
    raise ETiff.Create('TIFF sin tiras (strips) válidas');
  if Int(T_SAMPLEFORMAT, 1) = 3 then
    raise ETiff.Create('TIFF con muestras de punto flotante: no se admite');
  if (Spp > 1) and (Planar = 2) then
    raise ETiff.Create('TIFF con planos separados (PlanarConfiguration 2): no se admite todavía');
  if Photo = -1 then
    if Comp in [2, 3, 4] then
      Photo := 0
    else if Spp >= 3 then
      Photo := 2
    else
      Photo := 1;
  case Photo of
    5: raise ETiff.Create('TIFF en CMYK: PDF/A no lo admite sin perfil de salida CMYK');
    6: if Comp <> 7 then
         raise ETiff.Create('TIFF en YCbCr sin JPEG: no se admite todavía');
    0, 1, 2, 3: ;
  else
    raise ETiff.Create(Format('TIFF con interpretación de color %d: no se admite', [Photo]));
  end;
  if not (Bps in [1, 2, 4, 8, 16]) then
    raise ETiff.Create(Format('TIFF con %d bits por muestra: no se admite', [Bps]));

  // resolution: unit 2 inch (default), 3 cm, 1 none (aspect ratio only)
  Unit_ := Int(T_RESUNIT, 2);
  Result.Width := W;
  Result.Height := H;
  Result.DpiX := Rational(T_XRES, 0);
  Result.DpiY := Rational(T_YRES, Result.DpiX);
  if Result.DpiX <= 0 then
    Result.DpiX := Result.DpiY;
  if Unit_ = 3 then
  begin
    Result.DpiX := Result.DpiX * 2.54;
    Result.DpiY := Result.DpiY * 2.54;
  end;
  if (Unit_ = 1) and (Result.DpiX > 0) then
  begin
    Result.DpiY := 150 * Result.DpiY / Result.DpiX;
    Result.DpiX := 150;
  end;
  if (Result.DpiX < 10) or (Result.DpiY < 10) or (Result.DpiX > 10000) or (Result.DpiY > 10000) then
  begin
    Result.DpiX := 150;
    Result.DpiY := 150;
  end;

  Pieces := TList<TTiffPiece>.Create;
  try
    case Comp of
      4: // CCITT Group 4: as it is, checked first
        begin
          if (Spp <> 1) or (Bps <> 1) then
            raise ETiff.Create('TIFF G4 que no es bitonal');
          Row0 := 0;
          for var I := 0 to (H + Rps - 1) div Rps - 1 do
          begin
            Rows := Min(Rps, H - Row0);
            Strip := StripBytes(I);
            var P := TCCITTFaxParams.Default;
            P.K := -1;
            P.Columns := W;
            P.Rows := Rows;
            P.EndOfBlock := False;
            var Got := 0;
            try
              CCITTFaxDecode(Strip, P, Got);
            except
              on E: ECCITTFaxError do
                Got := 0;
            end;
            if Got < Rows then
              raise ETiff.Create(Format('TIFF G4 dañado (tira %d)', [I + 1]));
            Piece := Default(TTiffPiece);
            Piece.Kind := TTiffPieceKind.CCITT;
            Piece.Data := Strip;
            Piece.Width := W;
            Piece.Rows := Rows;
            Piece.Top := Row0;
            Piece.ColorSpace := 'DeviceGray';
            Piece.Bpc := 1;
            // the codes say white and black runs; with BlackIsZero the
            // "white" runs are the zeros, shown black
            Piece.BlackIs1 := Photo = 1;
            Pieces.Add(Piece);
            Inc(Row0, Rows);
          end;
        end;
      7: // JPEG: as it is, with the tables
        begin
          var Tables := Bytes(T_JPEGTABLES);
          if (Bps <> 8) or not (Spp in [1, 3]) then
            raise ETiff.Create('TIFF JPEG que no es gris ni RGB de 8 bits');
          Row0 := 0;
          for var I := 0 to (H + Rps - 1) div Rps - 1 do
          begin
            Rows := Min(Rps, H - Row0);
            Strip := StripBytes(I);
            if (Length(Strip) < 4) or (Strip[0] <> $FF) or (Strip[1] <> $D8) then
              raise ETiff.Create('TIFF JPEG dañado');
            if Length(Tables) > 4 then
            begin
              // tables without their EOI + the strip without its SOI
              var J: TBytes;
              SetLength(J, Length(Tables) - 2 + Length(Strip) - 2);
              Move(Tables[0], J[0], Length(Tables) - 2);
              Move(Strip[2], J[Length(Tables) - 2], Length(Strip) - 2);
              Strip := J;
            end;
            Piece := Default(TTiffPiece);
            Piece.Kind := TTiffPieceKind.JPEG;
            Piece.Data := Strip;
            Piece.Width := W;
            Piece.Rows := Rows;
            Piece.Top := Row0;
            Piece.Bpc := 8;
            if Spp = 1 then
              Piece.ColorSpace := 'DeviceGray'
            else
              Piece.ColorSpace := 'DeviceRGB';
            Piece.NoColorTransform := (Spp = 3) and (Photo = 2);
            Pieces.Add(Piece);
            Inc(Row0, Rows);
          end;
        end;
      1, 2, 3, 5, 8, 32946, 32773:
        begin
          Bilevel := (Spp = 1) and (Bps = 1) and (Photo in [0, 1]);
          if (Comp in [2, 3]) and not Bilevel then
            raise ETiff.Create('TIFF G3 que no es bitonal');
          if (Pred = 2) and (Bps < 8) then
            raise ETiff.Create('TIFF con predictor y menos de 8 bits: no se admite');
          if not (Pred in [1, 2]) then
            raise ETiff.Create(Format('TIFF con predictor %d: no se admite', [Pred]));
          Gray := Photo in [0, 1];
          Extra := 0;
          Ex := Ints(T_EXTRASAMPLES);
          if Gray then
            Extra := Spp - 1
          else if Photo = 2 then
          begin
            if Spp < 3 then
              raise ETiff.Create('TIFF RGB con menos de 3 muestras');
            Extra := Spp - 3;
          end
          else if Spp <> 1 then
            raise ETiff.Create('TIFF con paleta y más de una muestra');
          HasAlpha := (Extra > 0) and (Ex <> nil) and ((Ex[0] = 1) or (Ex[0] = 2));
          Premult := HasAlpha and (Ex[0] = 1);
          if Photo = 3 then
          begin
            Cmap := Ints(T_COLORMAP);
            if Length(Cmap) < 3 * (1 shl Bps) then
              raise ETiff.Create('TIFF con paleta incompleta');
          end;
          Stride := (Int64(W) * Spp * Bps + 7) div 8;
          // all the strips, decoded, one after the other
          SetLength(Raw, Stride * H);
          Row0 := 0;
          for var I := 0 to (H + Rps - 1) div Rps - 1 do
          begin
            Rows := Min(Rps, H - Row0);
            var Want := Integer(Stride * Rows);
            Strip := StripBytes(I);
            case Comp of
              1: Pix := Strip;
              5: Pix := TiffLzwDecode(Strip, Want);
              8, 32946: Pix := Inflate(Strip, Want);
              32773: Pix := PackBitsDecode(Strip, Want);
            else
              begin
                var P := TCCITTFaxParams.Default;
                P.Columns := W;
                P.Rows := Rows;
                P.EndOfBlock := False;
                if Comp = 2 then
                begin
                  P.K := 0;
                  P.EncodedByteAlign := True;
                end
                else if (Int(T_T4OPTIONS, 0) and 1) <> 0 then
                  P.K := 1
                else
                  P.K := 0;
                if (Int(T_T4OPTIONS, 0) and 2) <> 0 then
                  raise ETiff.Create('TIFF G3 con modo sin comprimir: no se admite');
                var Got := 0;
                try
                  Pix := CCITTFaxDecode(Strip, P, Got);
                except
                  on E: ECCITTFaxError do
                    Got := 0;
                end;
                if Got < Rows then
                  raise ETiff.Create(Format('TIFF G3 dañado (tira %d)', [I + 1]));
                // the decoder gives 1 for the white runs; in the TIFF those are zeros
                for var J := 0 to High(Pix) do
                  Pix[J] := not Pix[J];
              end;
            end;
            if Length(Pix) < Want then
              raise ETiff.Create(Format('TIFF incompleto (tira %d)', [I + 1]));
            Move(Pix[0], Raw[Stride * Row0], Want);
            Inc(Row0, Rows);
          end;
          // horizontal differencing
          if Pred = 2 then
            for var Y := 0 to H - 1 do
            begin
              var R0 := Stride * Y;
              if Bps = 8 then
                for var X := Spp to Stride - 1 do
                  Raw[R0 + X] := Byte(Raw[R0 + X] + Raw[R0 + X - Spp])
              else
                for var X := Spp to W * Spp - 1 do
                begin
                  var P := R0 + X * 2;
                  var Q := P - Spp * 2;
                  var V, U: Integer;
                  if LE then
                  begin
                    V := Raw[P] or (Raw[P + 1] shl 8);
                    U := Raw[Q] or (Raw[Q + 1] shl 8);
                  end
                  else
                  begin
                    V := (Raw[P] shl 8) or Raw[P + 1];
                    U := (Raw[Q] shl 8) or Raw[Q + 1];
                  end;
                  V := (V + U) and $FFFF;
                  if LE then
                  begin
                    Raw[P] := V and $FF;
                    Raw[P + 1] := V shr 8;
                  end
                  else
                  begin
                    Raw[P] := V shr 8;
                    Raw[P + 1] := V and $FF;
                  end;
                end;
            end;
          Piece := Default(TTiffPiece);
          Piece.Kind := TTiffPieceKind.Pixels;
          Piece.Width := W;
          Piece.Rows := H;
          if Bilevel then
          begin
            // 1-bit as it is; with WhiteIsZero the zeros are white
            Piece.Data := Raw;
            Piece.ColorSpace := 'DeviceGray';
            Piece.Bpc := 1;
            Piece.Invert := Photo = 0;
          end
          else
          begin
            var Ch := 3;
            if Gray then
              Ch := 1;
            OutStride := W * Ch;
            SetLength(Piece.Data, Int64(OutStride) * H);
            for var Y := 0 to H - 1 do
            begin
              var R0 := Stride * Y;
              for var X := 0 to W - 1 do
              begin
                var R, G, Bb, Al: Integer;
                Al := 255;
                if Gray then
                begin
                  R := Sample(Raw, R0, X, 0);
                  if Photo = 0 then
                    R := 255 - R;
                  G := R;
                  Bb := R;
                  if HasAlpha then
                    Al := Sample(Raw, R0, X, 1);
                end
                else if Photo = 3 then
                begin
                  var Ix := Sample(Raw, R0, X, 0);
                  var N := 1 shl Bps;
                  R := Cmap[Ix] shr 8;
                  G := Cmap[N + Ix] shr 8;
                  Bb := Cmap[2 * N + Ix] shr 8;
                end
                else
                begin
                  R := Sample(Raw, R0, X, 0);
                  G := Sample(Raw, R0, X, 1);
                  Bb := Sample(Raw, R0, X, 2);
                  if HasAlpha then
                    Al := Sample(Raw, R0, X, 3);
                end;
                // transparency onto white (the preservation copy has no alpha)
                if Al < 255 then
                  if Premult then
                  begin
                    R := Min(255, R + 255 - Al);
                    G := Min(255, G + 255 - Al);
                    Bb := Min(255, Bb + 255 - Al);
                  end
                  else
                  begin
                    R := (R * Al + 255 * (255 - Al)) div 255;
                    G := (G * Al + 255 * (255 - Al)) div 255;
                    Bb := (Bb * Al + 255 * (255 - Al)) div 255;
                  end;
                var P := Int64(Y) * OutStride + X * Ch;
                if Gray then
                  Piece.Data[P] := R
                else
                begin
                  Piece.Data[P] := R;
                  Piece.Data[P + 1] := G;
                  Piece.Data[P + 2] := Bb;
                end;
              end;
            end;
            Piece.Bpc := 8;
            if Gray then
              Piece.ColorSpace := 'DeviceGray'
            else
              Piece.ColorSpace := 'DeviceRGB';
          end;
          Pieces.Add(Piece);
        end;
      6: raise ETiff.Create('TIFF con JPEG antiguo (compresión 6): no se admite');
    else
      raise ETiff.Create(Format('TIFF con compresión %d: no se admite', [Comp]));
    end;
    Result.Pieces := Pieces.ToArray;
  finally
    Pieces.Free;
  end;
end;

function ReadTiff(const B: TBytes; out Pages: TArray<TTiffPage>; out Why: string): Boolean;
var
  R: TReader;
  P, Next: Int64;
  Seen: TDictionary<Int64, Boolean>;
  List: TList<TTiffPage>;
begin
  Pages := nil;
  Why := '';
  Result := False;
  if not IsTiff(B) then
  begin
    if (Length(B) >= 4) and (((B[0] = Ord('I')) and (B[2] = 43)) or ((B[0] = Ord('M')) and (B[3] = 43))) then
      Why := 'BigTIFF: no se admite todavía'
    else
      Why := 'no es un TIFF válido';
    Exit;
  end;
  R := TReader.Create(B);
  Seen := TDictionary<Int64, Boolean>.Create;
  List := TList<TTiffPage>.Create;
  try
    try
      P := R.U32(4);
      while P <> 0 do
      begin
        if Seen.ContainsKey(P) or (List.Count >= MAX_PAGES) then
          raise ETiff.Create('TIFF con IFD en ciclo');
        Seen.Add(P, True);
        R.LoadIfd(P, Next);
        // reduced resolution versions (thumbnails) are not pages
        if (R.Int(T_NEWSUBFILETYPE, 0) and 1) = 0 then
          try
            List.Add(R.ReadPage);
          except
            on E: ETiff do
              raise ETiff.Create(Format('página %d: %s', [List.Count + 1, E.Message]));
          end;
        P := Next;
      end;
      if List.Count = 0 then
        raise ETiff.Create('TIFF sin páginas');
      Pages := List.ToArray;
      Result := True;
    except
      on E: ETiff do
        Why := E.Message;
      on E: EOutOfMemory do
        Why := 'TIFF demasiado grande para la memoria';
    end;
  finally
    List.Free;
    Seen.Free;
    R.Free;
  end;
end;

initialization
  InitBitRev;

end.
