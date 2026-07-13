unit QRImagePNG;

{
  QRImagePNG.pas -- Renderiza un TQRCode como PNG (escala de grises 1 bit),
  sin dependencias externas: implementa su propio CRC-32 (PNG/zlib), Adler-32
  y un envoltorio zlib/DEFLATE de bloques "stored" (sin compresion real).

  Un QR es en su mayoria blanco/negro homogeneo por bloques, asi que el
  ahorro de tamaño de un DEFLATE real es modesto frente a la complejidad de
  implementar Huffman dinamico; los bloques "stored" son validos DEFLATE
  (RFC 1951 §3.2.4) y cualquier lector PNG los descomprime igual.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Classes, QREncoder;

function QRRenderPNG(AQr: TQRCode; AScale: Integer = 8; AQuietZone: Integer = 4): TBytes;
procedure QRSavePNG(AQr: TQRCode; const AFileName: string; AScale: Integer = 8; AQuietZone: Integer = 4);

implementation

function PNGCrc32(const AData: TBytes): Cardinal;
var
  C: Cardinal;
  I, J: Integer;
begin
  C := $FFFFFFFF;
  for I := 0 to Length(AData) - 1 do
  begin
    C := C xor AData[I];
    for J := 0 to 7 do
      if (C and 1) <> 0 then
        C := (C shr 1) xor $EDB88320
      else
        C := C shr 1;
  end;
  Result := C xor $FFFFFFFF;
end;

function Adler32(const AData: TBytes): Cardinal;
const
  MOD_ADLER = 65521;
var
  A, B: Cardinal;
  I: Integer;
begin
  A := 1;
  B := 0;
  for I := 0 to Length(AData) - 1 do
  begin
    A := (A + AData[I]) mod MOD_ADLER;
    B := (B + A) mod MOD_ADLER;
  end;
  Result := (B shl 16) or A;
end;

// Empaqueta ABytes en bloques DEFLATE "stored" (BTYPE=00): validos sin
// compresion real. RFC 1951 3.2.4.
function DeflateStoreBytes(const AData: TBytes): TBytes;
var
  Stream: TMemoryStream;
  Pos, Remaining, ChunkLen: Integer;
  IsFinal: Byte;
  LenLE, NLenLE: Word;
begin
  Stream := TMemoryStream.Create;
  try
    Pos := 0;
    Remaining := Length(AData);
    if Remaining = 0 then
    begin
      IsFinal := 1;
      Stream.WriteBuffer(IsFinal, 1);
      LenLE := 0;
      NLenLE := LenLE xor $FFFF;
      Stream.WriteBuffer(LenLE, 2);
      Stream.WriteBuffer(NLenLE, 2);
    end;
    while Remaining > 0 do
    begin
      ChunkLen := Remaining;
      if ChunkLen > 65535 then
        ChunkLen := 65535;
      if ChunkLen = Remaining then
        IsFinal := 1
      else
        IsFinal := 0;
      Stream.WriteBuffer(IsFinal, 1);
      LenLE := ChunkLen;
      NLenLE := LenLE xor $FFFF;
      Stream.WriteBuffer(LenLE, 2);
      Stream.WriteBuffer(NLenLE, 2);
      Stream.WriteBuffer(AData[Pos], ChunkLen);
      Inc(Pos, ChunkLen);
      Dec(Remaining, ChunkLen);
    end;
    SetLength(Result, Stream.Size);
    Stream.Position := 0;
    Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function ZlibStore(const AData: TBytes): TBytes;
var
  Stream: TMemoryStream;
  Deflated: TBytes;
  Ad: Cardinal;
  AdBE: array[0..3] of Byte;
  ZlibHeader: array[0..1] of Byte;
begin
  Deflated := DeflateStoreBytes(AData);
  Ad := Adler32(AData);
  Stream := TMemoryStream.Create;
  try
    ZlibHeader[0] := $78;
    ZlibHeader[1] := $01;
    Stream.WriteBuffer(ZlibHeader, 2);
    if Length(Deflated) > 0 then
      Stream.WriteBuffer(Deflated[0], Length(Deflated));
    AdBE[0] := (Ad shr 24) and $FF;
    AdBE[1] := (Ad shr 16) and $FF;
    AdBE[2] := (Ad shr 8) and $FF;
    AdBE[3] := Ad and $FF;
    Stream.WriteBuffer(AdBE, 4);
    SetLength(Result, Stream.Size);
    Stream.Position := 0;
    Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

procedure WriteChunk(AStream: TStream; const AType: AnsiString; const AData: TBytes);
var
  LenBE, CrcBE: array[0..3] of Byte;
  TypeAndData: TBytes;
  Crc: Cardinal;
  ALen: Cardinal;
begin
  ALen := Cardinal(Length(AData));
  LenBE[0] := (ALen shr 24) and $FF;
  LenBE[1] := (ALen shr 16) and $FF;
  LenBE[2] := (ALen shr 8) and $FF;
  LenBE[3] := ALen and $FF;
  AStream.WriteBuffer(LenBE, 4);
  AStream.WriteBuffer(PAnsiChar(AType)^, 4);
  if Length(AData) > 0 then
    AStream.WriteBuffer(AData[0], Length(AData));

  SetLength(TypeAndData, 4 + Length(AData));
  Move(PAnsiChar(AType)^, TypeAndData[0], 4);
  if Length(AData) > 0 then
    Move(AData[0], TypeAndData[4], Length(AData));
  Crc := PNGCrc32(TypeAndData);
  CrcBE[0] := (Crc shr 24) and $FF;
  CrcBE[1] := (Crc shr 16) and $FF;
  CrcBE[2] := (Crc shr 8) and $FF;
  CrcBE[3] := Crc and $FF;
  AStream.WriteBuffer(CrcBE, 4);
end;

function QRRenderPNG(AQr: TQRCode; AScale, AQuietZone: Integer): TBytes;
var
  ImgSize, RowBytes: Integer;
  RawData: TBytes;
  Y, X, ModX, ModY, Idx: Integer;
  IHDRData: TBytes;
  Compressed: TBytes;
  Stream: TMemoryStream;
  Sig: array[0..7] of Byte;
  W: Cardinal;
begin
  if AScale < 1 then
    raise Exception.Create('QRRenderPNG: AScale debe ser >= 1');
  if AQuietZone < 0 then
    raise Exception.Create('QRRenderPNG: AQuietZone debe ser >= 0');

  ImgSize := (AQr.Size + AQuietZone * 2) * AScale;
  RowBytes := (ImgSize + 7) div 8;
  SetLength(RawData, (RowBytes + 1) * ImgSize);
  FillChar(RawData[0], Length(RawData), 0);

  for Y := 0 to ImgSize - 1 do
  begin
    Idx := Y * (RowBytes + 1);
    RawData[Idx] := 0; // byte de filtro: None
    ModY := (Y div AScale) - AQuietZone;
    for X := 0 to ImgSize - 1 do
    begin
      ModX := (X div AScale) - AQuietZone;
      // Escala de grises 1 bit: 0 = negro, 1 = blanco.
      if not ((ModX >= 0) and (ModX < AQr.Size) and (ModY >= 0) and (ModY < AQr.Size) and AQr.GetModule(ModX, ModY)) then
        RawData[Idx + 1 + (X shr 3)] := RawData[Idx + 1 + (X shr 3)] or ($80 shr (X and 7));
    end;
  end;

  Compressed := ZlibStore(RawData);

  Sig[0] := 137; Sig[1] := 80; Sig[2] := 78; Sig[3] := 71;
  Sig[4] := 13;  Sig[5] := 10; Sig[6] := 26; Sig[7] := 10;

  SetLength(IHDRData, 13);
  W := Cardinal(ImgSize);
  IHDRData[0] := (W shr 24) and $FF; IHDRData[1] := (W shr 16) and $FF;
  IHDRData[2] := (W shr 8) and $FF;  IHDRData[3] := W and $FF;
  IHDRData[4] := (W shr 24) and $FF; IHDRData[5] := (W shr 16) and $FF;
  IHDRData[6] := (W shr 8) and $FF;  IHDRData[7] := W and $FF;
  IHDRData[8] := 1;  // bit depth
  IHDRData[9] := 0;  // color type: grayscale
  IHDRData[10] := 0; // compression method: deflate
  IHDRData[11] := 0; // filter method
  IHDRData[12] := 0; // interlace: none

  Stream := TMemoryStream.Create;
  try
    Stream.WriteBuffer(Sig, 8);
    WriteChunk(Stream, 'IHDR', IHDRData);
    WriteChunk(Stream, 'IDAT', Compressed);
    WriteChunk(Stream, 'IEND', nil);
    SetLength(Result, Stream.Size);
    Stream.Position := 0;
    Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

procedure QRSavePNG(AQr: TQRCode; const AFileName: string; AScale, AQuietZone: Integer);
var
  Bytes: TBytes;
begin
  Bytes := QRRenderPNG(AQr, AScale, AQuietZone);
  with TFileStream.Create(AFileName, fmCreate) do
    try
      WriteBuffer(Bytes[0], Length(Bytes));
    finally
      Free;
    end;
end;

end.
