program TestRedaction;

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}
{$R *.res}

uses
  System.SysUtils, System.Classes, System.StrUtils, System.Math, System.Types,
  uPDF.Types        in '..\Src\Core\uPDF.Types.pas',
  uPDF.Errors       in '..\Src\Core\uPDF.Errors.pas',
  uPDF.Objects      in '..\Src\Core\uPDF.Objects.pas',
  uPDF.Lexer        in '..\Src\Core\uPDF.Lexer.pas',
  uPDF.Filters      in '..\Src\Core\uPDF.Filters.pas',
  uPDF.XRef         in '..\Src\Core\uPDF.XRef.pas',
  uPDF.Crypto       in '..\Src\Core\uPDF.Crypto.pas',
  uPDF.Encryption   in '..\Src\Core\uPDF.Encryption.pas',
  uPDF.Parser       in '..\Src\Core\uPDF.Parser.pas',
  uPDF.Document     in '..\Src\Core\uPDF.Document.pas',
  uPDF.GraphicsState in '..\Src\Core\uPDF.GraphicsState.pas',
  uPDF.ColorSpace   in '..\Src\Core\uPDF.ColorSpace.pas',
  uPDF.FontCMap     in '..\Src\Core\uPDF.FontCMap.pas',
  uPDF.Font         in '..\Src\Core\uPDF.Font.pas',
  uPDF.ContentStream in '..\Src\Core\uPDF.ContentStream.pas',
  uPDF.Image        in '..\Src\Core\uPDF.Image.pas',
  uPDF.TextExtractor in '..\Src\Core\uPDF.TextExtractor.pas',
  uPDF.ImageExtractor in '..\Src\Core\uPDF.ImageExtractor.pas',
  uPDF.Writer       in '..\Src\Core\uPDF.Writer.pas',
  uPDF.Outline      in '..\Src\Core\uPDF.Outline.pas',
  uPDF.Annotations  in '..\Src\Core\uPDF.Annotations.pas',
  uPDF.Metadata     in '..\Src\Core\uPDF.Metadata.pas',
  uPDF.AcroForms    in '..\Src\Core\uPDF.AcroForms.pas',
  uPDF.TextSearch   in '..\Src\Core\uPDF.TextSearch.pas',
  uPDF.Redaction    in '..\Src\Core\uPDF.Redaction.pas';

var
  PassCount: Integer = 0;
  FailCount: Integer = 0;

procedure Check(ACond: Boolean; const AMsg: string; const ADetail: string = '');
begin
  if ACond then
  begin
    Inc(PassCount);
    WriteLn('  [PASS] ', AMsg);
  end
  else
  begin
    Inc(FailCount);
    if ADetail <> '' then
      WriteLn('  [FAIL] ', AMsg, ' -- ', ADetail)
    else
      WriteLn('  [FAIL] ', AMsg);
  end;
end;

// First space-delimited token that is all ASCII letters, length in [6..14].
function FindCandidate(const S: string): string;
var
  Tokens: TArray<string>;
  T, Clean: string;
  C: Char;
  Ok: Boolean;
begin
  Result := '';
  Tokens := S.Split([' ', #10, #13, #9, ',', '.', ';', ':', '(', ')']);
  for T in Tokens do
  begin
    Clean := T.Trim;
    if (Length(Clean) < 6) or (Length(Clean) > 14) then Continue;
    Ok := True;
    for C in Clean do
      if not (((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z'))) then
      begin
        Ok := False;
        Break;
      end;
    if Ok then Exit(Clean);
  end;
end;

procedure RunTest(const APath: string);
var
  Doc, Doc2:  TPDFDocument;
  Ext:        TPDFTextExtractor;
  Search:     TPDFTextSearch;
  Page:       TPDFPage;
  Plain, Plain2, Cand, XRun: string;
  Matches:    TArray<TPDFSearchMatch>;
  Boxes:      TArray<TRectF>;
  R:          TRectF;
  M:          TPDFSearchMatch;
  W, H:       Single;
  Cnt:        Integer;
  Ok:         Boolean;
  OutS:       TBytesStream;
  Tmp:        string;
begin
  WriteLn;
  WriteLn('=== Redaction test: ', ExtractFileName(APath), ' ===');
  if not FileExists(APath) then
  begin
    Check(False, 'archivo existe', APath);
    Exit;
  end;

  Doc := TPDFDocument.Create;
  try
    Doc.LoadFromFile(APath);
    Page := Doc.Pages[0];
    W := Page.Width; H := Page.Height;

    Ext := TPDFTextExtractor.Create(Doc);
    try
      Plain := Ext.ExtractPage(0).PlainText;
    finally
      Ext.Free;
    end;

    if Plain.Trim = '' then
    begin
      Check(False, 'pagina 0 tiene capa de texto', 'sin texto (escaneado?)');
      Exit;
    end;

    Cand := FindCandidate(Plain);
    Check(Cand <> '', Format('palabra candidata encontrada: "%s"', [Cand]));
    if Cand = '' then Exit;

    // Buscar la palabra y construir cajas normalizadas Y-down
    Search := TPDFTextSearch.Create(Doc);
    try
      Matches := Search.SearchPage(0, Cand, TPDFSearchOptions.CaseSensitiveExact);
    finally
      Search.Free;
    end;
    Check(Length(Matches) > 0, Format('ocurrencias en pagina 0: %d', [Length(Matches)]));

    SetLength(Boxes, 0);
    for M in Matches do
    begin
      R.Left   := M.Bounds.LLX / W;
      R.Right  := M.Bounds.URX / W;
      R.Top    := (H - M.Bounds.URY) / H;
      R.Bottom := (H - M.Bounds.LLY) / H;
      Boxes := Boxes + [R];
    end;

    Ok := TPDFRedactor.ScrubPageTextLayer(Doc, 0, Boxes, 'X', Cnt);
    Check(Ok, Format('ScrubPageTextLayer ok (glifos sustituidos: %d)', [Cnt]));

    // Guardar y recargar
    Tmp := IncludeTrailingPathDelimiter(GetEnvironmentVariable('TEMP')) +
           'redact_out.pdf';
    OutS := TBytesStream.Create;
    try
      Doc.SaveToStream(OutS);
      OutS.SaveToFile(Tmp);
    finally
      OutS.Free;
    end;
  finally
    Doc.Free;
  end;

  // Re-extraer del PDF redactado
  Doc2 := TPDFDocument.Create;
  try
    Doc2.LoadFromFile(Tmp);
    Ext := TPDFTextExtractor.Create(Doc2);
    try
      Plain2 := Ext.ExtractPage(0).PlainText;
    finally
      Ext.Free;
    end;
  finally
    Doc2.Free;
  end;

  XRun := StringOfChar('X', Length(Cand));
  Check(not ContainsStr(Plain2, Cand),
    Format('el texto redactado YA NO contiene "%s"', [Cand]));
  Check(ContainsStr(Plain2, XRun),
    Format('aparece la corrida de %d X', [Length(Cand)]));

  WriteLn('  PDF redactado: ', Tmp);
end;

begin
  WriteLn('======================================================');
  WriteLn(' TestRedaction -- redaccion real de capa de texto');
  WriteLn('======================================================');

  RunTest('E:\Copilot\AvanceJuridico\pruebas\24 de octubre de 2024 FALLO DE PRIMERA INSTANCIA.pdf');

  WriteLn;
  WriteLn('======================================================');
  WriteLn(Format(' TOTAL: %d passed, %d failed', [PassCount, FailCount]));
  WriteLn('======================================================');
  if FailCount > 0 then ExitCode := 1;
end.
