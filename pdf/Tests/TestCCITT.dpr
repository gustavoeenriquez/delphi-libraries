program TestCCITT;
// Tests: uPDF.CCITTFax (CCITT Group 3 / Group 4 decoder), the CCITTFaxDecode
// filter of uPDF.Filters and the CCITT path of uPDF.Image.
// Vectors in data\ccitt come from libtiff (encoder) and MuPDF (expected
// output); see tools\gen_ccitt_vectors.py.

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}

uses
  System.SysUtils, System.Classes, System.Hash, System.IOUtils,
  uPDF.Types         in '..\Src\Core\uPDF.Types.pas',
  uPDF.Errors        in '..\Src\Core\uPDF.Errors.pas',
  uPDF.CCITTFax      in '..\Src\Core\uPDF.CCITTFax.pas',
  uPDF.Objects       in '..\Src\Core\uPDF.Objects.pas',
  uPDF.Filters       in '..\Src\Core\uPDF.Filters.pas',
  uPDF.ColorSpace    in '..\Src\Core\uPDF.ColorSpace.pas',
  uPDF.Image         in '..\Src\Core\uPDF.Image.pas';

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

// '0'/'1' string (spaces ignored) -> bytes, zero padded
function Bits(const S: string): TBytes;
var
  I, N: Integer;
begin
  Result := nil;
  N := 0;
  for I := 1 to Length(S) do
    if CharInSet(S[I], ['0', '1']) then
    begin
      if N mod 8 = 0 then
      begin
        SetLength(Result, N div 8 + 1);
        Result[N div 8] := 0;
      end;
      if S[I] = '1' then
        Result[N div 8] := Result[N div 8] or ($80 shr (N mod 8));
      Inc(N);
    end;
end;

function Hex(const B: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(B) do
    Result := Result + IntToHex(B[I], 2);
end;

function Params(K, Columns, Rows: Integer): TCCITTFaxParams;
begin
  Result := TCCITTFaxParams.Default;
  Result.K       := K;
  Result.Columns := Columns;
  Result.Rows    := Rows;
end;

function TryDecode(const AData: TBytes; const AParams: TCCITTFaxParams): string;
begin
  try
    Result := Hex(CCITTFaxDecode(AData, AParams));
  except
    on E: ECCITTFaxError do Result := 'error';
  end;
end;

const
  EOL  = '000000000001';
  EOFB = EOL + EOL;
  // 8 pixels: white 3, black 2, white 3 -> 11100111
  ROW_A_1D = '1000 11 1000';

function FindDataDir: string;
var
  D: string;
  I: Integer;
begin
  // optional argument: the vector directory
  if (ParamCount > 0) and FileExists(TPath.Combine(ParamStr(1), 'manifest.txt')) then
    Exit(ParamStr(1));
  D := ExtractFilePath(ParamStr(0));
  for I := 0 to 6 do
  begin
    Result := TPath.Combine(D, TPath.Combine('data', 'ccitt'));
    if FileExists(TPath.Combine(Result, 'manifest.txt')) then Exit;
    Result := TPath.Combine(D, TPath.Combine('Tests', TPath.Combine('data', 'ccitt')));
    if FileExists(TPath.Combine(Result, 'manifest.txt')) then Exit;
    D := ExtractFilePath(ExcludeTrailingPathDelimiter(D));
    if D = '' then Break;
  end;
  Result := '';
end;

// =========================================================================
// T1: hand-coded bit streams
// =========================================================================

procedure TestHandCoded;
var
  P: TCCITTFaxParams;
  N: Integer;
begin
  Section('T1: flujos codificados a mano');

  P := TCCITTFaxParams.Default;
  Check((P.K = 0) and (P.Columns = 1728) and (P.Rows = 0) and P.EndOfBlock and
    not P.BlackIs1 and not P.EndOfLine and not P.EncodedByteAlign,
    'T01 valores por defecto de PDF');

  Check(TryDecode(Bits(ROW_A_1D), Params(0, 8, 1)) = 'E7',
    'T02 1-D: blanco 3, negro 2, blanco 3');

  P := Params(0, 8, 1);
  P.BlackIs1 := True;
  Check(TryDecode(Bits(ROW_A_1D), P) = '18', 'T03 BlackIs1 invierte la salida');

  // G4: row 1 horizontal + V0, row 2 = row 1 (V0 x3), row 3 shifted right (VR1 VR1 V0)
  Check(TryDecode(Bits('001 1000 11 1' + '111' + '011 011 1' + EOFB), Params(-1, 8, 3)) = 'E7E7F3',
    'T04 G4 modos horizontal y vertical (V0, VR1)');

  // G4: row 1 white 2, black 2, white 4; row 2 all white: pass mode, then V0
  Check(TryDecode(Bits('001 0111 11 1' + '0001 1' + EOFB), Params(-1, 8, 2)) = 'CFFF',
    'T05 G4 modo de paso');

  // G4 with left vertical modes: row 1 W4 B2 W2, row 2 W3 B2 W3 (VL1 VL1 V0)
  Check(TryDecode(Bits('001 1011 11 1' + '010 010 1' + EOFB), Params(-1, 8, 2)) = 'F3E7',
    'T06 G4 VL1');

  // Rows unknown: the EOFB ends the data
  Check((TryDecode(Bits('111' + EOFB), Params(-1, 8, 0)) = 'FFFFFF'),
    'T07 G4 sin Rows termina en EOFB');

  // Rows known but the data ends early: white rows are added
  Check(TryDecode(Bits('1' + EOFB), Params(-1, 8, 3)) = 'FFFFFF',
    'T08 filas faltantes se completan en blanco');

  // G3 mixed: EOL + tag 1 (1-D row), EOL + tag 0 (2-D row equal to it)
  P := Params(1, 8, 2);
  P.EndOfLine := True;
  Check(TryDecode(Bits(EOL + '1' + ROW_A_1D + EOL + '0' + '111'), P) = 'E7E7',
    'T09 G3 2-D con bit de etiqueta');

  // G3 RTC (6 x EOL+1) ends the data when Rows is unknown
  P := Params(1, 8, 0);
  Check(TryDecode(Bits(EOL + '1' + ROW_A_1D + EOL + '1' + EOL + '1' + EOL + '1' +
    EOL + '1' + EOL + '1' + EOL + '1'), P) = 'E7', 'T10 G3 RTC termina los datos');

  // Fill bits before EOL
  P := Params(0, 8, 2);
  P.EndOfLine := True;
  Check(TryDecode(Bits('0000' + EOL + ROW_A_1D + '0000000' + EOL + '10011'), P) = 'E7FF',
    'T11 G3 bits de relleno antes del EOL');

  // Damaged row between EOLs: replaced by the previous one
  P := Params(0, 8, 3);
  P.EndOfLine := True;
  Check(TryDecode(Bits(EOL + ROW_A_1D + EOL + '0000000011111' + EOL + '10011'), P) = 'E7E7FF',
    'T12 G3 fila dañada se reemplaza por la anterior');

  // EncodedByteAlign in G4: every row starts on a byte boundary
  P := Params(-1, 8, 2);
  P.EncodedByteAlign := True;
  Check(TryDecode(Bits('001 1000 11 1 000000' + '111 00000' + EOFB), P) = 'E7E7',
    'T13 G4 EncodedByteAlign');

  // Modified Huffman as in TIFF compression 2: byte aligned 1-D rows, no EOL
  P := Params(0, 8, 2);
  P.EncodedByteAlign := True;
  P.EndOfBlock := False;
  Check(TryDecode(Bits('1000 11 1000 000000' + '10011 000'), P) = 'E7FF',
    'T14 MH alineado sin EOL');

  // Columns not a multiple of 8: 10 pixels, white 1, black 9 (padding bits white)
  Check(TryDecode(Bits('000111 000100'), Params(0, 10, 1)) = '803F',
    'T15 ancho de 10 píxeles');

  // Make-up + terminating code: white 70 (64 + 6), black 2 in a 72 wide row
  Check(TryDecode(Bits('11011 1110 11'), Params(0, 72, 1)) = 'FFFFFFFFFFFFFFFFFC',
    'T16 código de complemento (make-up)');

  Check(TryDecode(Bits('0000000011111111'), Params(-1, 8, 0)) = 'error',
    'T17 datos inválidos: ECCITTFaxError');

  N := 0;
  CCITTFaxDecode(Bits('111' + EOFB), Params(-1, 8, 0), N);
  Check(N = 3, 'T18 cantidad de filas devuelta', IntToStr(N));
end;

// =========================================================================
// T2: libtiff / MuPDF vectors
// =========================================================================

procedure TestVectors;
var
  Dir, Name, Expected, Got: string;
  Lines: TStringList;
  F: TArray<string>;
  P: TCCITTFaxParams;
  Data, Pixels: TBytes;
  I, Row, Rows, RowBytes: Integer;
begin
  Section('T2: vectores libtiff / MuPDF');
  Dir := FindDataDir;
  if Dir = '' then
  begin
    Fail('V00 no se encontró data/ccitt/manifest.txt');
    Exit;
  end;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(TPath.Combine(Dir, 'manifest.txt'));
    for I := 0 to Lines.Count - 1 do
    begin
      F := Lines[I].Trim.Split([' ']);
      if Length(F) <> 9 then Continue;
      Name := F[0];
      P := TCCITTFaxParams.Default;
      P.K                := StrToInt(F[1]);
      P.Columns          := StrToInt(F[2]);
      P.Rows             := StrToInt(F[3]);
      P.EndOfLine        := F[4] = '1';
      P.EncodedByteAlign := F[5] = '1';
      P.EndOfBlock       := F[6] = '1';
      P.BlackIs1         := F[7] = '1';
      Expected := F[8];
      Data := TFile.ReadAllBytes(TPath.Combine(Dir, Name + '.fax'));
      try
        Pixels := CCITTFaxDecode(Data, P, Rows);
        // the expected hash has the padding bits of each row cleared
        RowBytes := (P.Columns + 7) div 8;
        if P.Columns mod 8 <> 0 then
          for Row := 0 to Rows - 1 do
            Pixels[Row * RowBytes + RowBytes - 1] := Pixels[Row * RowBytes + RowBytes - 1] and
              Byte($FF shl (8 - P.Columns mod 8));
        var H := THashSHA1.Create;
        H.Update(Pixels);
        Got := LowerCase(H.HashAsString);
      except
        on E: Exception do Got := E.ClassName + ': ' + E.Message;
      end;
      Check(Got = Expected, Format('V%.2d %s', [I + 1, Name]), Got);
    end;
  finally
    Lines.Free;
  end;
end;

// =========================================================================
// T3: CCITTFaxDecode filter and TPDFImage
// =========================================================================

function MakeDecodeParms(K, Columns, Rows: Integer): TPDFDictionary;
begin
  Result := TPDFDictionary.Create;
  Result.SetValue('K', TPDFInteger.Create(K));
  if Columns > 0 then Result.SetValue('Columns', TPDFInteger.Create(Columns));
  if Rows > 0 then Result.SetValue('Rows', TPDFInteger.Create(Rows));
end;

// Image XObject: 8 x 3, the G4 rows of T04
function MakeImage(AMask, AColumns: Boolean): TPDFStream;
var
  DP: TPDFDictionary;
begin
  Result := TPDFStream.Create;
  Result.Dict.SetValue('Type', TPDFName.Create('XObject'));
  Result.Dict.SetValue('Subtype', TPDFName.Create('Image'));
  Result.Dict.SetValue('Width', TPDFInteger.Create(8));
  Result.Dict.SetValue('Height', TPDFInteger.Create(3));
  if AMask then
    Result.Dict.SetValue('ImageMask', TPDFBoolean.Create(True))
  else
  begin
    Result.Dict.SetValue('BitsPerComponent', TPDFInteger.Create(1));
    Result.Dict.SetValue('ColorSpace', TPDFName.Create('DeviceGray'));
  end;
  Result.Dict.SetValue('Filter', TPDFName.Create('CCITTFaxDecode'));
  if AColumns then DP := MakeDecodeParms(-1, 8, 3)
  else DP := MakeDecodeParms(-1, 0, 0);   // /Columns missing: 1728 by default
  Result.Dict.SetValue('DecodeParms', DP);
  Result.SetRawData(Bits('001 1000 11 1' + '111' + '011 011 1' + EOFB));
end;

function Expanded(const S: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(S) do
    if S[I] = 0 then Result := Result + '0' else Result := Result + '1';
end;

procedure TestFilterAndImage;
const
  EXPECT = '11100111' + '11100111' + '11110011';
var
  DP: TPDFDictionary;
  Out_: TBytes;
  St: TPDFStream;
  Img: TPDFImage;
begin
  Section('T3: filtro CCITTFaxDecode y TPDFImage');

  DP := MakeDecodeParms(-1, 8, 3);
  try
    Out_ := TPDFFilterPipeline.Decode(Bits('001 1000 11 1' + '111' + '011 011 1' + EOFB),
      ['CCITTFaxDecode'], [DP]);
    Check(Hex(Out_) = 'E7E7F3', 'F01 TPDFFilterPipeline con /DecodeParms', Hex(Out_));
    Out_ := TPDFFilterPipeline.Decode(Bits('001 1000 11 1' + '111' + '011 011 1' + EOFB),
      ['CCF'], [DP]);
    Check(Hex(Out_) = 'E7E7F3', 'F02 abreviatura CCF', Hex(Out_));
  finally
    DP.Free;
  end;

  try
    TPDFFilterPipeline.Decode(Bits('0000000011111111'), ['CCITTFaxDecode'], [nil]);
    Fail('F03 datos inválidos levantan EPDFFilterError');
  except
    on E: EPDFFilterError do Pass('F03 datos inválidos levantan EPDFFilterError');
  end;

  St := MakeImage(False, True);
  try
    Img := TPDFImage.FromXObject(St);
    try
      Img.Decode;
      Check(Img.Info.Encoding = TPDFImageEncoding.Raw, 'F04 imagen CCITT queda como Raw');
      Check(Img.Info.ColorSpaceName = 'DeviceGray', 'F05 espacio DeviceGray');
      Check(Expanded(Img.Samples) = EXPECT, 'F06 muestras de la imagen', Expanded(Img.Samples));
    finally
      Img.Free;
    end;
  finally
    St.Free;
  end;

  St := MakeImage(True, True);
  try
    Img := TPDFImage.FromXObject(St);
    try
      Img.Decode;
      Check(Img.Info.IsImageMask and (Img.Info.Encoding = TPDFImageEncoding.Raw),
        'F07 /ImageMask con CCITT se decodifica');
      Check(Expanded(Img.Samples) = EXPECT, 'F08 muestras de la máscara', Expanded(Img.Samples));
    finally
      Img.Free;
    end;
  finally
    St.Free;
  end;

  // /Columns missing (1728 by default) and Width 8: retried with Columns = Width
  St := MakeImage(False, False);
  try
    Img := TPDFImage.FromXObject(St);
    try
      Img.Decode;
      Check(Expanded(Img.Samples) = EXPECT, 'F09 sin /Columns se usa /Width',
        Expanded(Img.Samples));
    finally
      Img.Free;
    end;
  finally
    St.Free;
  end;

  // inline image: abbreviations /W /H /IM /F /DP
  var Dict := TPDFDictionary.Create;
  try
    Dict.SetValue('W', TPDFInteger.Create(8));
    Dict.SetValue('H', TPDFInteger.Create(3));
    Dict.SetValue('IM', TPDFBoolean.Create(True));
    Dict.SetValue('F', TPDFName.Create('CCF'));
    Dict.SetValue('DP', MakeDecodeParms(-1, 8, 0));
    Img := TPDFImage.FromInline(Dict, Bits('001 1000 11 1' + '111' + '011 011 1' + EOFB));
    try
      Img.Decode;
      Check(Expanded(Img.Samples) = EXPECT, 'F10 imagen inline con /DP', Expanded(Img.Samples));
    finally
      Img.Free;
    end;
  finally
    Dict.Free;
  end;
end;

begin
  try
    TestHandCoded;
    TestVectors;
    TestFilterAndImage;
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
