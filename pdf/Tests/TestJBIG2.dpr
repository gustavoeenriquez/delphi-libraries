program TestJBIG2;
// Tests: uPDF.JBIG2 (JBIG2 decoder, ITU-T T.88), the JBIG2Decode filter of
// uPDF.Filters and the JBIG2 path of uPDF.Image.
// Vectors in data\jbig2 come from jbig2enc (encoder) and MuPDF (expected
// output); see tools\gen_jbig2_vectors.py.  Optional argument: a folder
// with the ITU-T T.88 conformance data (Annex K); see the README.

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}

uses
  System.SysUtils, System.Classes, System.Hash, System.IOUtils,
  uPDF.Types         in '..\Src\Core\uPDF.Types.pas',
  uPDF.Errors        in '..\Src\Core\uPDF.Errors.pas',
  uPDF.CCITTFax      in '..\Src\Core\uPDF.CCITTFax.pas',
  uPDF.JBIG2         in '..\Src\Core\uPDF.JBIG2.pas',
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

function HexBytes(const S: string): TBytes;
var
  I: Integer;
  T: string;
begin
  T := S.Replace(' ', '');
  SetLength(Result, Length(T) div 2);
  for I := 0 to High(Result) do
    Result[I] := StrToInt('$' + Copy(T, 2 * I + 1, 2));
end;

// SHA-1 of packed rows with the padding bits cleared
function PageHash(const ABits: TBytes; W, H: Integer): string;
var
  B: TBytes;
  RowBytes, Y: Integer;
  Hs: THashSHA1;
begin
  B := Copy(ABits);
  RowBytes := (W + 7) div 8;
  if W mod 8 <> 0 then
    for Y := 0 to H - 1 do
      B[Y * RowBytes + RowBytes - 1] := B[Y * RowBytes + RowBytes - 1] and
        Byte($FF shl (8 - W mod 8));
  Hs := THashSHA1.Create;
  Hs.Update(B);
  Result := LowerCase(Hs.HashAsString);
end;

function FindDataDir: string;
var
  D: string;
  I: Integer;
begin
  D := ExtractFilePath(ParamStr(0));
  for I := 0 to 6 do
  begin
    Result := TPath.Combine(D, TPath.Combine('data', 'jbig2'));
    if FileExists(TPath.Combine(Result, 'manifest.txt')) then Exit;
    Result := TPath.Combine(D, TPath.Combine('Tests', TPath.Combine('data', 'jbig2')));
    if FileExists(TPath.Combine(Result, 'manifest.txt')) then Exit;
    D := ExtractFilePath(ExcludeTrailingPathDelimiter(D));
    if D = '' then Break;
  end;
  Result := '';
end;

// Embedded segments: page information WxH, one immediate lossless generic
// region with AData (arithmetic, template AFlags), end of page
function MakeGenericStream(W, H: Integer; AFlags: Byte; const AAT, AData: TBytes): TBytes;
var
  S: TBytesStream;

  procedure U8(V: Byte); begin S.Write(V, 1); end;
  procedure U32(V: Cardinal);
  begin
    U8(V shr 24); U8(V shr 16); U8(V shr 8); U8(V);
  end;

begin
  S := TBytesStream.Create;
  try
    // segment 0: page information
    U32(0); U8(48); U8(0); U8(1); U32(19);
    U32(W); U32(H); U32(0); U32(0); U8(0); U8(0); U8(0);
    // segment 1: immediate lossless generic region
    U32(1); U8(39); U8(0); U8(1); U32(17 + 1 + Length(AAT) + Length(AData));
    U32(W); U32(H); U32(0); U32(0); U8(0);
    U8(AFlags);
    if Length(AAT) > 0 then S.Write(AAT[0], Length(AAT));
    if Length(AData) > 0 then S.Write(AData[0], Length(AData));
    // segment 2: end of page
    U32(2); U8(49); U8(0); U8(1); U32(0);
    Result := Copy(S.Bytes, 0, S.Size);
  finally
    S.Free;
  end;
end;

// =========================================================================
// T1: structure, MMR and errors
// =========================================================================

procedure TestStructure;
var
  B, Bits: TBytes;
  W, H: Integer;
begin
  Section('T1: estructura, MMR y errores');

  // MMR generic region of 8x2: two all-white G4 rows (V0 V0) and EOFB
  B := MakeGenericStream(8, 2, $01, nil, HexBytes('C0 04 00 40'));
  try
    Bits := JBIG2DecodeEmbedded(B, nil, W, H);
    Check((W = 8) and (H = 2) and (Length(Bits) = 2) and (Bits[0] = 0) and (Bits[1] = 0),
      'J01 región genérica MMR', Format('%dx%d', [W, H]));
  except
    on E: Exception do Fail('J01 región genérica MMR', E.Message);
  end;

  // MMR: row 1 = white 3, black 2, white 3 (horizontal + V0), row 2 = same
  B := MakeGenericStream(8, 2, $01, nil, HexBytes('31 F8'));
  try
    Bits := JBIG2DecodeEmbedded(B, nil, W, H);
    Check((Length(Bits) = 2) and (Bits[0] = $18) and (Bits[1] = $18),
      'J02 MMR: 1 = negro', Format('%.2x %.2x', [Bits[0], Bits[1]]));
  except
    on E: Exception do Fail('J02 MMR: 1 = negro', E.Message);
  end;

  try
    JBIG2DecodeEmbedded(HexBytes('00 00 00 00 30 00 01 00 00 00 13 00'), nil, W, H);
    Fail('J03 datos truncados levantan EJBIG2Error');
  except
    on E: EJBIG2Error do Pass('J03 datos truncados levantan EJBIG2Error');
  end;

  try
    JBIG2DecodeEmbedded(nil, nil, W, H);
    Fail('J04 sin información de página levanta EJBIG2Error');
  except
    on E: EJBIG2Error do Pass('J04 sin información de página levanta EJBIG2Error');
  end;

  try
    JBIG2DecodeFile(HexBytes('00 01 02 03 04 05 06 07 08'), 1, W, H);
    Fail('J05 archivo sin la firma JBIG2');
  except
    on E: EJBIG2Error do Pass('J05 archivo sin la firma JBIG2');
  end;
end;

// =========================================================================
// T2: jbig2enc / MuPDF vectors
// =========================================================================

procedure TestVectors;
var
  Dir, Name, Expected, Got, GotF: string;
  Lines: TStringList;
  F: TArray<string>;
  Data, Glob, Bits: TBytes;
  I, W, H, EW, EH: Integer;
begin
  Section('T2: vectores jbig2enc / MuPDF');
  Dir := FindDataDir;
  if Dir = '' then
  begin
    Fail('V00 no se encontró data/jbig2/manifest.txt');
    Exit;
  end;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(TPath.Combine(Dir, 'manifest.txt'));
    for I := 0 to Lines.Count - 1 do
    begin
      F := Lines[I].Trim.Split([' ']);
      if Length(F) <> 4 then Continue;
      Name := F[0];
      EW := StrToInt(F[1]);
      EH := StrToInt(F[2]);
      Expected := F[3];
      // embedded organisation, as in a PDF (with the globals stream)
      Data := TFile.ReadAllBytes(TPath.Combine(Dir, Name + '.jb2'));
      Glob := nil;
      if FileExists(TPath.Combine(Dir, Name + '.glb')) then
        Glob := TFile.ReadAllBytes(TPath.Combine(Dir, Name + '.glb'));
      try
        Bits := JBIG2DecodeEmbedded(Data, Glob, W, H);
        if (W <> EW) or (H <> EH) then Got := Format('%dx%d', [W, H])
        else Got := PageHash(Bits, W, H);
      except
        on E: Exception do Got := E.ClassName + ': ' + E.Message;
      end;
      Check(Got = Expected, Format('V%.2d %s (PDF)', [2 * I + 1, Name]), Got);
      // whole file
      try
        Bits := JBIG2DecodeFile(TFile.ReadAllBytes(TPath.Combine(Dir, Name + '.file')), 1, W, H);
        if (W <> EW) or (H <> EH) then GotF := Format('%dx%d', [W, H])
        else GotF := PageHash(Bits, W, H);
      except
        on E: Exception do GotF := E.ClassName + ': ' + E.Message;
      end;
      Check(GotF = Expected, Format('V%.2d %s (archivo)', [2 * I + 2, Name]), GotF);
    end;
  finally
    Lines.Free;
  end;
end;

// =========================================================================
// T3: JBIG2Decode filter and TPDFImage
// =========================================================================

procedure TestFilterAndImage;
var
  Dir: string;
  Data, Glob, Bits, Out_: TBytes;
  W, H: Integer;
  DP: TPDFDictionary;
  GS, St: TPDFStream;
  Img: TPDFImage;
  Same: Boolean;
begin
  Section('T3: filtro JBIG2Decode y TPDFImage');
  Dir := FindDataDir;
  if Dir = '' then
  begin
    Fail('F00 no se encontró data/jbig2');
    Exit;
  end;
  Data := TFile.ReadAllBytes(TPath.Combine(Dir, 'small_sym.jb2'));
  Glob := TFile.ReadAllBytes(TPath.Combine(Dir, 'small_sym.glb'));
  Bits := JBIG2DecodeEmbedded(Data, Glob, W, H);

  // the filter reads /JBIG2Globals and inverts the bits (1 = white)
  DP := TPDFDictionary.Create;
  try
    GS := TPDFStream.Create;
    GS.SetRawData(Glob);
    DP.SetValue('JBIG2Globals', GS);
    Out_ := TPDFFilterPipeline.Decode(Data, ['JBIG2Decode'], [DP]);
    Same := Length(Out_) = Length(Bits);
    if Same then
      for var I := 0 to High(Out_) do
        if Out_[I] <> Byte(not Bits[I]) then
        begin
          Same := False;
          Break;
        end;
    Check(Same, 'F01 filtro con /JBIG2Globals, salida invertida');
  finally
    DP.Free;
  end;

  try
    TPDFFilterPipeline.Decode(Data, ['JBIG2Decode'], [nil]);
    Fail('F02 sin los globales falla con EPDFFilterError');
  except
    on E: EPDFFilterError do Pass('F02 sin los globales falla con EPDFFilterError');
  end;

  // image XObject
  St := TPDFStream.Create;
  try
    St.Dict.SetValue('Subtype', TPDFName.Create('Image'));
    St.Dict.SetValue('Width', TPDFInteger.Create(W));
    St.Dict.SetValue('Height', TPDFInteger.Create(H));
    St.Dict.SetValue('BitsPerComponent', TPDFInteger.Create(1));
    St.Dict.SetValue('ColorSpace', TPDFName.Create('DeviceGray'));
    St.Dict.SetValue('Filter', TPDFName.Create('JBIG2Decode'));
    DP := TPDFDictionary.Create;
    GS := TPDFStream.Create;
    GS.SetRawData(Glob);
    DP.SetValue('JBIG2Globals', GS);
    St.Dict.SetValue('DecodeParms', DP);
    St.SetRawData(Data);
    Img := TPDFImage.FromXObject(St);
    try
      Img.Decode;
      Check(Img.Info.Encoding = TPDFImageEncoding.Raw, 'F03 imagen JBIG2 queda como Raw');
      Same := Length(Img.Samples) = W * H;
      if Same then
        for var Y := 0 to H - 1 do
          for var X := 0 to W - 1 do
            if (Img.Samples[Y * W + X] = 0) <>
               (((Bits[Y * ((W + 7) div 8) + X shr 3] shr (7 - X and 7)) and 1) = 1) then
              Same := False;
      Check(Same, 'F04 muestras: negro donde JBIG2 tiene 1');
    finally
      Img.Free;
    end;
  finally
    St.Free;
  end;
end;

// =========================================================================
// T4: ITU-T T.88 conformance data (optional, not distributed)
// =========================================================================

procedure TestConformance(const ADir: string);
const
  // streams that follow the Recommendation (the others were written by the
  // sample encoder of Annex K and depend on its own interpretations)
  NAMES: array[0..4] of string = ('F01_200_TT9', 'F01_200_TT10',
    'codeStreamTest1_TT3', 'codeStreamTest1_TT4', 'codeStreamTest1_TT7');
var
  N: string;
  Bits: TBytes;
  W, H, X, Y, Bad, Black: Integer;
  Bmp: TBytes;
  Off, Stride: Integer;
begin
  Section('T4: datos de conformidad T.88 (opcional)');
  if (ADir = '') or not DirectoryExists(ADir) then
  begin
    WriteLn('  (no se indicó la carpeta de datos de conformidad; se omite)');
    Exit;
  end;
  for N in NAMES do
  begin
    try
      Bits := JBIG2DecodeFile(TFile.ReadAllBytes(TPath.Combine(ADir, N + '.jb2')), 1, W, H);
      // expected: 1-bit BMP, bottom-up; the palette says which index is black
      Bmp := TFile.ReadAllBytes(TPath.Combine(ADir, N + '_TT00.bmp'));
      Off := PInteger(@Bmp[10])^;
      if Bmp[14 + PInteger(@Bmp[14])^ + 2] < 128 then Black := 0 else Black := 1;
      Stride := ((W + 31) div 32) * 4;
      Bad := 0;
      for Y := 0 to H - 1 do
        for X := 0 to W - 1 do
          if (((Bits[Y * ((W + 7) div 8) + X shr 3] shr (7 - X and 7)) and 1) = 1) <>
             (((Bmp[Off + (H - 1 - Y) * Stride + X shr 3] shr (7 - X and 7)) and 1) = Black) then
            Inc(Bad);
      Check(Bad = 0, 'C ' + N, Format('%d píxeles distintos', [Bad]));
    except
      on E: Exception do Fail('C ' + N, E.Message);
    end;
  end;
end;

begin
  try
    TestStructure;
    TestVectors;
    TestFilterAndImage;
    TestConformance(ParamStr(1));
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
