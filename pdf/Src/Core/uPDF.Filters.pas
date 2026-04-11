unit uPDF.Filters;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.ZLib,
  uPDF.Types, uPDF.Errors;

type
  // -------------------------------------------------------------------------
  // Base filter — decode/encode a byte stream
  // -------------------------------------------------------------------------
  TPDFFilter = class abstract
  public
    // Decode AInput → AOutput.  AParams may be nil.
    procedure Decode(AInput: TStream; AOutput: TStream;
      AParams: TObject {TPDFDictionary — use TObject to avoid circular unit ref}); virtual; abstract;
    // Encode AInput → AOutput.
    procedure Encode(AInput: TStream; AOutput: TStream;
      AParams: TObject); virtual; abstract;
  end;

  // -------------------------------------------------------------------------
  // FlateDecode  (zlib/deflate, PDF 1.2+)
  // Supports PNG predictor (DecodeParms /Predictor >= 10)
  // -------------------------------------------------------------------------
  TPDFFlateFilter = class(TPDFFilter)
  public
    procedure Decode(AInput: TStream; AOutput: TStream; AParams: TObject); override;
    procedure Encode(AInput: TStream; AOutput: TStream; AParams: TObject); override;
  end;

  // -------------------------------------------------------------------------
  // ASCII85Decode
  // -------------------------------------------------------------------------
  TPDFAscii85Filter = class(TPDFFilter)
  public
    procedure Decode(AInput: TStream; AOutput: TStream; AParams: TObject); override;
    procedure Encode(AInput: TStream; AOutput: TStream; AParams: TObject); override;
  end;

  // -------------------------------------------------------------------------
  // ASCIIHexDecode
  // -------------------------------------------------------------------------
  TPDFAsciiHexFilter = class(TPDFFilter)
  public
    procedure Decode(AInput: TStream; AOutput: TStream; AParams: TObject); override;
    procedure Encode(AInput: TStream; AOutput: TStream; AParams: TObject); override;
  end;

  // -------------------------------------------------------------------------
  // RunLengthDecode  (PackBits)
  // -------------------------------------------------------------------------
  TPDFRunLengthFilter = class(TPDFFilter)
  public
    procedure Decode(AInput: TStream; AOutput: TStream; AParams: TObject); override;
    procedure Encode(AInput: TStream; AOutput: TStream; AParams: TObject); override;
  end;

  // -------------------------------------------------------------------------
  // LZWDecode  (LZW compression, PDF 1.1)
  // -------------------------------------------------------------------------
  TPDFLZWFilter = class(TPDFFilter)
  private
    type
      TLZWTable = array[0..4096] of record
        Prefix: Integer;
        Suffix: Byte;
      end;
  public
    procedure Decode(AInput: TStream; AOutput: TStream; AParams: TObject); override;
    procedure Encode(AInput: TStream; AOutput: TStream; AParams: TObject); override;
  end;

  // -------------------------------------------------------------------------
  // DCTDecode  (JPEG) — pass-through (Skia/OS decodes JPEG natively)
  // -------------------------------------------------------------------------
  TPDFDCTFilter = class(TPDFFilter)
  public
    procedure Decode(AInput: TStream; AOutput: TStream; AParams: TObject); override;
    procedure Encode(AInput: TStream; AOutput: TStream; AParams: TObject); override;
  end;

  // -------------------------------------------------------------------------
  // CCITTFaxDecode  — stub (complex; full implementation in Phase 2+)
  // -------------------------------------------------------------------------
  TPDFCCITTFilter = class(TPDFFilter)
  public
    procedure Decode(AInput: TStream; AOutput: TStream; AParams: TObject); override;
    procedure Encode(AInput: TStream; AOutput: TStream; AParams: TObject); override;
  end;

  // -------------------------------------------------------------------------
  // JBIG2Decode — stub
  // -------------------------------------------------------------------------
  TPDFJBIG2Filter = class(TPDFFilter)
  public
    procedure Decode(AInput: TStream; AOutput: TStream; AParams: TObject); override;
    procedure Encode(AInput: TStream; AOutput: TStream; AParams: TObject); override;
  end;

  // -------------------------------------------------------------------------
  // Filter pipeline — applies a sequence of filters
  // -------------------------------------------------------------------------
  TPDFFilterPipeline = class
  public
    // Decode AData through the given chain of filters (innermost first).
    // AFilterNames: array of filter name strings (without '/')
    // AParamsList: array of TPDFDictionary (or nil items); same length as AFilterNames
    class function Decode(const AData: TBytes;
      const AFilterNames: TArray<string>;
      const AParamsList:  TArray<TObject>): TBytes; static;

    // Encode AData through the given chain (applied in reverse order for encoding)
    class function Encode(const AData: TBytes;
      const AFilterNames: TArray<string>;
      const AParamsList:  TArray<TObject>): TBytes; static;
  end;

  // -------------------------------------------------------------------------
  // PNG predictor application (used by FlateDecode and LZWDecode)
  // -------------------------------------------------------------------------
procedure ApplyPNGPredictor(AInput: TStream; AOutput: TStream;
  APredictor, AColumns, AColors, ABitsPerComponent: Integer);

procedure UndoPNGPredictor(AInput: TStream; AOutput: TStream;
  AColumns, AColors, ABitsPerComponent: Integer);

implementation

uses
  System.Math;

// =========================================================================
// Helpers
// =========================================================================

procedure WriteByte(AStream: TStream; AValue: Byte); inline;
begin
  AStream.Write(AValue, 1);
end;

function ReadByte(AStream: TStream; out AValue: Byte): Boolean; inline;
begin
  Result := AStream.Read(AValue, 1) = 1;
end;

procedure CopyStreamFull(ASrc, ADst: TStream);
const
  COPY_BUF_SIZE = 65536;
var
  CopyBuf: TBytes;
  N:       Integer;
begin
  SetLength(CopyBuf, COPY_BUF_SIZE);
  ASrc.Position := 0;
  repeat
    N := ASrc.Read(CopyBuf[0], COPY_BUF_SIZE);
    if N > 0 then ADst.Write(CopyBuf[0], N);
  until N < COPY_BUF_SIZE;
end;

// =========================================================================
// PNG Predictor (Sub, Up, Average, Paeth — per-row)
// =========================================================================

function PaethPredictor(A, B, C: Integer): Integer; inline;
var
  PA, PB, PC: Integer;
begin
  PA := Abs(B - C);
  PB := Abs(A - C);
  PC := Abs(A + B - 2 * C);
  if (PA <= PB) and (PA <= PC) then Result := A
  else if PB <= PC then Result := B
  else Result := C;
end;

procedure UndoPNGPredictor(AInput: TStream; AOutput: TStream;
  AColumns, AColors, ABitsPerComponent: Integer);
var
  BytesPerPixel: Integer;
  RowSize:       Integer;
  Row:           TBytes;
  PrevRow:       TBytes;
  PredByte:      Integer;
  I:             Integer;
  Left, Up, UL:  Integer;
begin
  BytesPerPixel := Max(1, (AColors * ABitsPerComponent + 7) div 8);
  RowSize       := (AColumns * AColors * ABitsPerComponent + 7) div 8;

  if RowSize <= 0 then Exit;

  SetLength(Row,     RowSize);
  SetLength(PrevRow, RowSize);
  FillChar(PrevRow[0], RowSize, 0);

  while AInput.Position < AInput.Size do
  begin
    var PB: Byte := 0;
    if not ReadByte(AInput, PB) then Break;
    PredByte := PB;
    if AInput.Read(Row[0], RowSize) = 0 then Break;

    case PredByte of
      0: ; // None
      1: // Sub
        for I := BytesPerPixel to RowSize - 1 do
          Row[I] := (Row[I] + Row[I - BytesPerPixel]) and $FF;
      2: // Up
        for I := 0 to RowSize - 1 do
          Row[I] := (Row[I] + PrevRow[I]) and $FF;
      3: // Average
        for I := 0 to RowSize - 1 do
        begin
          Left := 0;
          if I >= BytesPerPixel then Left := Row[I - BytesPerPixel];
          Up   := PrevRow[I];
          Row[I] := (Row[I] + (Left + Up) div 2) and $FF;
        end;
      4: // Paeth
        for I := 0 to RowSize - 1 do
        begin
          Left := 0; UL := 0;
          if I >= BytesPerPixel then
          begin
            Left := Row[I - BytesPerPixel];
            UL   := PrevRow[I - BytesPerPixel];
          end;
          Up := PrevRow[I];
          Row[I] := (Row[I] + PaethPredictor(Left, Up, UL)) and $FF;
        end;
    end;

    AOutput.Write(Row[0], RowSize);
    Move(Row[0], PrevRow[0], RowSize);
  end;
end;

procedure ApplyPNGPredictor(AInput: TStream; AOutput: TStream;
  APredictor, AColumns, AColors, ABitsPerComponent: Integer);
var
  BytesPerPixel: Integer;
  RowSize:       Integer;
  Row:           TBytes;
  PrevRow:       TBytes;
  I:             Integer;
  Left, Up, UL:  Integer;
begin
  BytesPerPixel := Max(1, (AColors * ABitsPerComponent + 7) div 8);
  RowSize       := (AColumns * AColors * ABitsPerComponent + 7) div 8;

  if RowSize <= 0 then Exit;

  SetLength(Row,     RowSize);
  SetLength(PrevRow, RowSize);
  FillChar(PrevRow[0], RowSize, 0);

  while AInput.Position < AInput.Size do
  begin
    if AInput.Read(Row[0], RowSize) = 0 then Break;

    // Write predictor byte (use Sub=1 as default, or passed APredictor-10)
    var PredType: Byte := APredictor - 10;
    if PredType > 4 then PredType := 0;

    var Encoded: TBytes;
    SetLength(Encoded, RowSize);

    case PredType of
      0: Move(Row[0], Encoded[0], RowSize); // None
      1: // Sub
      begin
        for I := 0 to RowSize - 1 do
        begin
          Left := 0;
          if I >= BytesPerPixel then Left := Row[I - BytesPerPixel];
          Encoded[I] := (Row[I] - Left) and $FF;
        end;
      end;
      2: // Up
        for I := 0 to RowSize - 1 do
          Encoded[I] := (Row[I] - PrevRow[I]) and $FF;
    else
      Move(Row[0], Encoded[0], RowSize);
    end;

    WriteByte(AOutput, PredType);
    AOutput.Write(Encoded[0], RowSize);
    Move(Row[0], PrevRow[0], RowSize);
  end;
end;

// =========================================================================
// TPDFFlateFilter
// =========================================================================

procedure TPDFFlateFilter.Decode(AInput: TStream; AOutput: TStream; AParams: TObject);
var
  DecompStream: TZDecompressionStream;
begin
  AInput.Position := 0;
  DecompStream := TZDecompressionStream.Create(AInput, 15);
  try
    AOutput.CopyFrom(DecompStream, 0);
  finally
    DecompStream.Free;
  end;

  // Apply PNG predictor if requested
  // AParams is TPDFDictionary — check /Predictor
  // To avoid circular dependency we use late binding via interface
  // (Actual predictor application is wired up when TPDFStream.EnsureDecoded calls this)
end;

procedure TPDFFlateFilter.Encode(AInput: TStream; AOutput: TStream; AParams: TObject);
var
  CompStream: TZCompressionStream;
begin
  AInput.Position := 0;
  CompStream := TZCompressionStream.Create(AOutput, zcDefault, 15);
  try
    CompStream.CopyFrom(AInput, 0);
  finally
    CompStream.Free;
  end;
end;

// =========================================================================
// TPDFAscii85Filter
// =========================================================================

procedure TPDFAscii85Filter.Decode(AInput: TStream; AOutput: TStream; AParams: TObject);
var
  B:    Integer;
  Grp:  array[0..4] of Byte;
  GrpCount: Integer;
  V:    UInt32;

  function ReadNextChar: Integer;
  begin
    while True do
    begin
      var RB: Byte;
      if AInput.Read(RB, 1) = 0 then Exit(-1);
      Result := RB;
      if Result in [10, 13, 32, 9] then Continue; // skip whitespace
      Break;
    end;
  end;

begin
  AInput.Position := 0;
  GrpCount := 0;

  while True do
  begin
    B := ReadNextChar;
    if B = -1 then Break;

    if (B = Ord('~')) then
    begin
      // End of data marker ~>
      ReadNextChar; // consume '>'
      Break;
    end;

    if B = Ord('z') then
    begin
      // Special case: 'z' = 4 zero bytes
      WriteByte(AOutput, 0);
      WriteByte(AOutput, 0);
      WriteByte(AOutput, 0);
      WriteByte(AOutput, 0);
      Continue;
    end;

    if (B < Ord('!')) or (B > Ord('u')) then
      raise EPDFFilterError.CreateFmt('Invalid ASCII85 char: %d', [B]);

    Grp[GrpCount] := B - Ord('!');
    Inc(GrpCount);

    if GrpCount = 5 then
    begin
      V := UInt32(Grp[0]) * 52200625
         + UInt32(Grp[1]) * 614125
         + UInt32(Grp[2]) * 7225
         + UInt32(Grp[3]) * 85
         + UInt32(Grp[4]);
      WriteByte(AOutput, (V shr 24) and $FF);
      WriteByte(AOutput, (V shr 16) and $FF);
      WriteByte(AOutput, (V shr 8)  and $FF);
      WriteByte(AOutput, V and $FF);
      GrpCount := 0;
    end;
  end;

  // Handle partial group at end
  if GrpCount > 0 then
  begin
    // Pad with 'u' (84)
    var PaddedCount := GrpCount;
    for var I := GrpCount to 4 do
      Grp[I] := 84;
    V := UInt32(Grp[0]) * 52200625
       + UInt32(Grp[1]) * 614125
       + UInt32(Grp[2]) * 7225
       + UInt32(Grp[3]) * 85
       + UInt32(Grp[4]);
    for var I := 0 to PaddedCount - 2 do
      WriteByte(AOutput, (V shr (24 - I * 8)) and $FF);
  end;
end;

procedure TPDFAscii85Filter.Encode(AInput: TStream; AOutput: TStream; AParams: TObject);
var
  Buf:   array[0..3] of Byte;
  N:     Integer;
  V:     UInt32;
  Chars: array[0..4] of Byte;
  Col:   Integer;

  procedure WriteChar(C: Byte);
  begin
    WriteByte(AOutput, C);
    Inc(Col);
    if Col >= 75 then
    begin
      WriteByte(AOutput, 10);
      Col := 0;
    end;
  end;

begin
  AInput.Position := 0;
  Col := 0;

  while True do
  begin
    FillChar(Buf, SizeOf(Buf), 0);
    N := AInput.Read(Buf[0], 4);
    if N = 0 then Break;

    V := (UInt32(Buf[0]) shl 24)
       or (UInt32(Buf[1]) shl 16)
       or (UInt32(Buf[2]) shl 8)
       or UInt32(Buf[3]);

    if (V = 0) and (N = 4) then
    begin
      WriteChar(Ord('z'));
    end else
    begin
      Chars[4] := V mod 85; V := V div 85;
      Chars[3] := V mod 85; V := V div 85;
      Chars[2] := V mod 85; V := V div 85;
      Chars[1] := V mod 85; V := V div 85;
      Chars[0] := V mod 85;
      for var I := 0 to N do
        WriteChar(Chars[I] + Ord('!'));
    end;
  end;

  // Write EOD marker
  WriteByte(AOutput, Ord('~'));
  WriteByte(AOutput, Ord('>'));
end;

// =========================================================================
// TPDFAsciiHexFilter
// =========================================================================

procedure TPDFAsciiHexFilter.Decode(AInput: TStream; AOutput: TStream; AParams: TObject);
var
  B: Byte;
  Hi, Lo: Integer;

  function HexVal(C: Byte): Integer;
  begin
    if (C >= Ord('0')) and (C <= Ord('9')) then Result := C - Ord('0')
    else if (C >= Ord('a')) and (C <= Ord('f')) then Result := C - Ord('a') + 10
    else if (C >= Ord('A')) and (C <= Ord('F')) then Result := C - Ord('A') + 10
    else Result := -1;
  end;

begin
  AInput.Position := 0;
  Hi := -1;
  while AInput.Read(B, 1) > 0 do
  begin
    if B = Ord('>') then Break; // EOD
    if B in [9, 10, 13, 32] then Continue;
    var V := HexVal(B);
    if V < 0 then raise EPDFFilterError.CreateFmt('Invalid hex char: %d', [B]);
    if Hi < 0 then Hi := V
    else
    begin
      Lo := V;
      var Out := Byte((Hi shl 4) or Lo);
      AOutput.Write(Out, 1);
      Hi := -1;
    end;
  end;
  if Hi >= 0 then
  begin
    var Out := Byte(Hi shl 4);
    AOutput.Write(Out, 1);
  end;
end;

procedure TPDFAsciiHexFilter.Encode(AInput: TStream; AOutput: TStream; AParams: TObject);
const
  HexChars: array[0..15] of AnsiChar = '0123456789ABCDEF';
var
  B: Byte;
begin
  AInput.Position := 0;
  while AInput.Read(B, 1) > 0 do
  begin
    var Hi: AnsiChar := HexChars[B shr 4];
    var Lo: AnsiChar := HexChars[B and $F];
    AOutput.Write(Hi, 1);
    AOutput.Write(Lo, 1);
  end;
  var EOD: AnsiChar := '>';
  AOutput.Write(EOD, 1);
end;

// =========================================================================
// TPDFRunLengthFilter  (PackBits / PDF RunLength)
// =========================================================================

procedure TPDFRunLengthFilter.Decode(AInput: TStream; AOutput: TStream; AParams: TObject);
var
  Len: Byte;
  B:   Byte;
  Buf: TBytes;
begin
  AInput.Position := 0;
  while AInput.Read(Len, 1) > 0 do
  begin
    if Len = 128 then Break; // EOD
    if Len <= 127 then
    begin
      // Literal run: copy Len+1 bytes
      SetLength(Buf, Len + 1);
      AInput.Read(Buf[0], Len + 1);
      AOutput.Write(Buf[0], Len + 1);
    end else
    begin
      // Repeat run: replicate next byte (257 - Len) times
      AInput.Read(B, 1);
      SetLength(Buf, 257 - Len);
      FillChar(Buf[0], 257 - Len, B);
      AOutput.Write(Buf[0], 257 - Len);
    end;
  end;
end;

procedure TPDFRunLengthFilter.Encode(AInput: TStream; AOutput: TStream; AParams: TObject);
var
  Buf:   TBytes;
  Pos:   Integer;
  Total: Integer;
begin
  // Simple non-compressing implementation: emit literal runs of 128
  AInput.Position := 0;
  Total := AInput.Size;
  SetLength(Buf, 128);
  while Total > 0 do
  begin
    var Take := Min(128, Total);
    AInput.Read(Buf[0], Take);
    var RunLen := Byte(Take - 1);
    AOutput.Write(RunLen, 1);
    AOutput.Write(Buf[0], Take);
    Dec(Total, Take);
  end;
  var EOD: Byte := 128;
  AOutput.Write(EOD, 1);
end;

// =========================================================================
// TPDFLZWFilter — LZW decode (early change = 1 by default in PDF)
// =========================================================================

procedure TPDFLZWFilter.Decode(AInput: TStream; AOutput: TStream; AParams: TObject);
const
  CLEAR_CODE = 256;
  EOD_CODE   = 257;
  MAX_CODES  = 4096;
var
  // Table entries
  Prefix:  array[0..MAX_CODES-1] of Integer;
  Suffix:  array[0..MAX_CODES-1] of Byte;
  // Bit reader state
  BitBuf:   UInt32;
  BitsLeft: Integer;
  CodeSize: Integer;
  NextCode: Integer;

  function ReadCode: Integer;
  var
    B: Byte;
  begin
    while BitsLeft < CodeSize do
    begin
      if AInput.Read(B, 1) = 0 then Exit(-1);
      BitBuf   := (BitBuf shl 8) or B;
      Inc(BitsLeft, 8);
    end;
    Dec(BitsLeft, CodeSize);
    Result := (BitBuf shr BitsLeft) and ((1 shl CodeSize) - 1);
  end;

  procedure ResetTable;
  begin
    CodeSize := 9;
    NextCode := 258;
    for var I := 0 to 255 do
    begin
      Prefix[I] := -1;
      Suffix[I] := I;
    end;
  end;

  function DecodeString(ACode: Integer): TBytes;
  var
    Stack: array[0..4095] of Byte;
    Top:   Integer;
  begin
    Top := 0;
    while ACode > 255 do
    begin
      Stack[Top] := Suffix[ACode];
      Inc(Top);
      ACode := Prefix[ACode];
    end;
    Stack[Top] := ACode;
    Inc(Top);
    SetLength(Result, Top);
    for var I := 0 to Top - 1 do
      Result[I] := Stack[Top - 1 - I];
  end;

var
  Code, OldCode: Integer;
  S, Entry: TBytes;
begin
  AInput.Position := 0;
  BitBuf   := 0;
  BitsLeft := 0;
  ResetTable;
  OldCode := -1;

  while True do
  begin
    Code := ReadCode;
    if Code = -1 then Break;
    if Code = EOD_CODE then Break;
    if Code = CLEAR_CODE then
    begin
      ResetTable;
      OldCode := -1;
      Continue;
    end;

    if OldCode = -1 then
    begin
      S := DecodeString(Code);
      if Length(S) > 0 then AOutput.Write(S[0], Length(S));
      OldCode := Code;
      Continue;
    end;

    if Code < NextCode then
      Entry := DecodeString(Code)
    else
    begin
      // KwKwK case
      S := DecodeString(OldCode);
      if Length(S) = 0 then
      begin
        OldCode := Code;
        Continue;
      end;
      SetLength(Entry, Length(S) + 1);
      Move(S[0], Entry[0], Length(S));
      Entry[Length(S)] := S[0];
    end;

    if Length(Entry) > 0 then AOutput.Write(Entry[0], Length(Entry));

    if (NextCode < MAX_CODES) and (Length(Entry) > 0) then
    begin
      S := DecodeString(OldCode);
      Prefix[NextCode] := OldCode;
      Suffix[NextCode] := Entry[0];
      Inc(NextCode);
      // Early change: bump code size BEFORE next read
      if (NextCode = (1 shl CodeSize)) and (CodeSize < 12) then
        Inc(CodeSize);
    end;

    OldCode := Code;
  end;
end;

procedure TPDFLZWFilter.Encode(AInput: TStream; AOutput: TStream; AParams: TObject);
begin
  raise EPDFNotSupportedError.Create('LZW encoding not implemented');
end;

// =========================================================================
// TPDFDCTFilter (JPEG passthrough)
// =========================================================================

procedure TPDFDCTFilter.Decode(AInput: TStream; AOutput: TStream; AParams: TObject);
begin
  // JPEG is decoded by the renderer (Skia/OS codec) — pass raw bytes through
  AInput.Position := 0;
  AOutput.CopyFrom(AInput, 0);
end;

procedure TPDFDCTFilter.Encode(AInput: TStream; AOutput: TStream; AParams: TObject);
begin
  AInput.Position := 0;
  AOutput.CopyFrom(AInput, 0);
end;

// =========================================================================
// TPDFCCITTFilter — stub
// =========================================================================

procedure TPDFCCITTFilter.Decode(AInput: TStream; AOutput: TStream; AParams: TObject);
begin
  // TODO: Implement CCITT Group 3/4 decode
  AInput.Position := 0;
  AOutput.CopyFrom(AInput, 0);
end;

procedure TPDFCCITTFilter.Encode(AInput: TStream; AOutput: TStream; AParams: TObject);
begin
  raise EPDFNotSupportedError.Create('CCITTFax encoding not implemented');
end;

// =========================================================================
// TPDFJBIG2Filter — stub
// =========================================================================

procedure TPDFJBIG2Filter.Decode(AInput: TStream; AOutput: TStream; AParams: TObject);
begin
  raise EPDFNotSupportedError.Create('JBIG2 decode not implemented');
end;

procedure TPDFJBIG2Filter.Encode(AInput: TStream; AOutput: TStream; AParams: TObject);
begin
  raise EPDFNotSupportedError.Create('JBIG2 encoding not implemented');
end;

// =========================================================================
// TPDFFilterPipeline
// =========================================================================

class function TPDFFilterPipeline.Decode(const AData: TBytes;
  const AFilterNames: TArray<string>;
  const AParamsList:  TArray<TObject>): TBytes;
var
  Streams: array of TBytesStream;
  I:       Integer;
  Filter:  TPDFFilter;
  Kind:    TPDFFilterKind;
begin
  if Length(AFilterNames) = 0 then
    Exit(AData);

  // Build stream chain
  SetLength(Streams, Length(AFilterNames) + 1);
  Streams[0] := TBytesStream.Create(AData);
  try
    for I := 0 to High(AFilterNames) do
    begin
      Kind   := PDFFilterKindFromName(AFilterNames[I]);
      Streams[I + 1] := TBytesStream.Create;

      var Params: TObject := nil;
      if I < Length(AParamsList) then Params := AParamsList[I];

      case Kind of
        TPDFFilterKind.FlateDecode:
          Filter := TPDFFlateFilter.Create;
        TPDFFilterKind.ASCII85Decode:
          Filter := TPDFAscii85Filter.Create;
        TPDFFilterKind.ASCIIHexDecode:
          Filter := TPDFAsciiHexFilter.Create;
        TPDFFilterKind.RunLengthDecode:
          Filter := TPDFRunLengthFilter.Create;
        TPDFFilterKind.LZWDecode:
          Filter := TPDFLZWFilter.Create;
        TPDFFilterKind.DCTDecode:
          Filter := TPDFDCTFilter.Create;
        TPDFFilterKind.CCITTFaxDecode:
          Filter := TPDFCCITTFilter.Create;
        TPDFFilterKind.JBIG2Decode:
          Filter := TPDFJBIG2Filter.Create;
      else
        raise EPDFFilterError.CreateFmt('Unknown filter: %s', [AFilterNames[I]]);
      end;

      try
        Filter.Decode(Streams[I], Streams[I + 1], Params);
      finally
        Filter.Free;
      end;
    end;

    Result := Streams[High(Streams)].Bytes;
    var ActualLen := Streams[High(Streams)].Size;
    SetLength(Result, ActualLen);
  finally
    for I := 0 to High(Streams) do
      Streams[I].Free;
  end;
end;

class function TPDFFilterPipeline.Encode(const AData: TBytes;
  const AFilterNames: TArray<string>;
  const AParamsList:  TArray<TObject>): TBytes;
var
  Streams: array of TBytesStream;
  I:       Integer;
  Filter:  TPDFFilter;
  Kind:    TPDFFilterKind;
begin
  if Length(AFilterNames) = 0 then
    Exit(AData);

  SetLength(Streams, Length(AFilterNames) + 1);
  Streams[0] := TBytesStream.Create(AData);
  try
    for I := 0 to High(AFilterNames) do
    begin
      Kind   := PDFFilterKindFromName(AFilterNames[I]);
      Streams[I + 1] := TBytesStream.Create;

      var Params: TObject := nil;
      if I < Length(AParamsList) then Params := AParamsList[I];

      case Kind of
        TPDFFilterKind.FlateDecode:    Filter := TPDFFlateFilter.Create;
        TPDFFilterKind.ASCII85Decode:  Filter := TPDFAscii85Filter.Create;
        TPDFFilterKind.ASCIIHexDecode: Filter := TPDFAsciiHexFilter.Create;
        TPDFFilterKind.RunLengthDecode:Filter := TPDFRunLengthFilter.Create;
      else
        raise EPDFFilterError.CreateFmt('Encoding not supported for filter: %s', [AFilterNames[I]]);
      end;

      try
        Filter.Encode(Streams[I], Streams[I + 1], Params);
      finally
        Filter.Free;
      end;
    end;

    Result := Streams[High(Streams)].Bytes;
    var ActualLen := Streams[High(Streams)].Size;
    SetLength(Result, ActualLen);
  finally
    for I := 0 to High(Streams) do
      Streams[I].Free;
  end;
end;

end.
