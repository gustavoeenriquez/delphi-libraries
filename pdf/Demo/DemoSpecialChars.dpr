program DemoSpecialChars;
// Generates a PDF that exercises special-character encoding (WinAnsiEncoding / CP1252):
//   - Latin accents: a e i o u with tildes, umlauts, circumflex, cedilla
//   - Spanish n-tilde, French cedilla, German sharp-s
//   - Currency and punctuation symbols in CP1252
//   - Metadata stored as UTF-16BE (supports full Unicode in viewer Properties)

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}
{$R *.res}

uses
  System.SysUtils, System.Classes, System.IOUtils,
  uPDF.Types         in '..\Src\Core\uPDF.Types.pas',
  uPDF.Errors        in '..\Src\Core\uPDF.Errors.pas',
  uPDF.Objects       in '..\Src\Core\uPDF.Objects.pas',
  uPDF.Lexer         in '..\Src\Core\uPDF.Lexer.pas',
  uPDF.Filters       in '..\Src\Core\uPDF.Filters.pas',
  uPDF.XRef          in '..\Src\Core\uPDF.XRef.pas',
  uPDF.Crypto        in '..\Src\Core\uPDF.Crypto.pas',
  uPDF.Encryption    in '..\Src\Core\uPDF.Encryption.pas',
  uPDF.Parser        in '..\Src\Core\uPDF.Parser.pas',
  uPDF.Document      in '..\Src\Core\uPDF.Document.pas',
  uPDF.GraphicsState in '..\Src\Core\uPDF.GraphicsState.pas',
  uPDF.ColorSpace    in '..\Src\Core\uPDF.ColorSpace.pas',
  uPDF.FontCMap      in '..\Src\Core\uPDF.FontCMap.pas',
  uPDF.Font          in '..\Src\Core\uPDF.Font.pas',
  uPDF.ContentStream in '..\Src\Core\uPDF.ContentStream.pas',
  uPDF.Image         in '..\Src\Core\uPDF.Image.pas',
  uPDF.TextExtractor in '..\Src\Core\uPDF.TextExtractor.pas',
  uPDF.ImageExtractor in '..\Src\Core\uPDF.ImageExtractor.pas',
  uPDF.Writer        in '..\Src\Core\uPDF.Writer.pas',
  uPDF.Outline       in '..\Src\Core\uPDF.Outline.pas',
  uPDF.Annotations   in '..\Src\Core\uPDF.Annotations.pas',
  uPDF.Metadata      in '..\Src\Core\uPDF.Metadata.pas',
  uPDF.AcroForms     in '..\Src\Core\uPDF.AcroForms.pas';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

procedure AddStdFont(APageDict: TPDFDictionary; const AResName, ABaseName: string);
var
  ResDict, FontDict, FD: TPDFDictionary;
begin
  ResDict := APageDict.GetAsDictionary('Resources');
  if ResDict = nil then
  begin
    ResDict := TPDFDictionary.Create;
    APageDict.SetValue('Resources', ResDict);
  end;
  FontDict := ResDict.GetAsDictionary('Font');
  if FontDict = nil then
  begin
    FontDict := TPDFDictionary.Create;
    ResDict.SetValue('Font', FontDict);
  end;
  FD := TPDFDictionary.Create;
  FD.SetValue('Type',     TPDFName.Create('Font'));
  FD.SetValue('Subtype',  TPDFName.Create('Type1'));
  FD.SetValue('BaseFont', TPDFName.Create(ABaseName));
  FD.SetValue('Encoding', TPDFName.Create('WinAnsiEncoding'));
  FontDict.SetValue(AResName, FD);
end;

procedure AttachContent(APageDict: TPDFDictionary; CB: TPDFContentBuilder);
var
  Stm: TPDFStream;
begin
  Stm := TPDFStream.Create;
  Stm.SetRawData(CB.Build);
  APageDict.SetValue('Contents', Stm);
end;

procedure SectionBar(CB: TPDFContentBuilder; Y: Single;
  const ALabel: string; R, G, B: Single);
begin
  CB.SaveState;
  CB.SetFillRGB(R, G, B);
  CB.Rectangle(40, Y, 515, 20);
  CB.Fill;
  CB.SetFillRGB(1, 1, 1);
  CB.BeginText;
  CB.SetFont('Bold', 11);
  CB.SetTextMatrix(1, 0, 0, 1, 46, Y + 5);
  CB.ShowText(ALabel);
  CB.EndText;
  CB.RestoreState;
end;

procedure Row(CB: TPDFContentBuilder; Y: Single;
  const ALabel, AText: string);
begin
  CB.BeginText;
  CB.SetFont('Bold', 9);
  CB.SetTextMatrix(1, 0, 0, 1, 46, Y);
  CB.ShowText(ALabel + ':');
  CB.SetFont('Regular', 10);
  CB.SetTextMatrix(1, 0, 0, 1, 150, Y);
  CB.ShowText(AText);
  CB.EndText;
end;

// ---------------------------------------------------------------------------
// Build page 1: accents by language
// ---------------------------------------------------------------------------

procedure BuildPage1(Builder: TPDFBuilder);
var
  CB: TPDFContentBuilder;
  Page: TPDFDictionary;
  Y: Single;
begin
  Page := Builder.AddPage(595, 842);
  AddStdFont(Page, 'Regular', 'Helvetica');
  AddStdFont(Page, 'Bold',    'Helvetica-Bold');
  AddStdFont(Page, 'Mono',    'Courier');

  CB := TPDFContentBuilder.Create;
  try
    // Header bar
    CB.SetFillRGB(0.15, 0.35, 0.65);
    CB.Rectangle(40, 800, 515, 32);
    CB.Fill;
    CB.SetFillRGB(1, 1, 1);
    CB.BeginText;
    CB.SetFont('Bold', 15);
    CB.SetTextMatrix(1, 0, 0, 1, 46, 810);
    CB.ShowText('Caracteres Especiales ' + Chr($2014) + ' Acentos por Idioma');
    CB.EndText;
    CB.SetFillRGB(0, 0, 0);

    Y := 770;

    // Spanish
    SectionBar(CB, Y, 'Espa' + Chr($F1) + 'ol', 0.7, 0.2, 0.2);  Y := Y - 22;
    Row(CB, Y, 'Vocales',
        Chr($E1) + ' ' + Chr($E9) + ' ' + Chr($ED) + ' ' + Chr($F3) + ' ' + Chr($FA) +
        '  ' +
        Chr($C1) + ' ' + Chr($C9) + ' ' + Chr($CD) + ' ' + Chr($D3) + ' ' + Chr($DA));
    Y := Y - 17;
    Row(CB, Y, Chr($D1) + '/' + Chr($F1),
        Chr($F1) + ' ' + Chr($D1) + '  ' + Chr($BF) + 'C' + Chr($F3) + 'mo est' +
        Chr($E1) + 's? ' + Chr($A1) + 'Muy bien, gracias!');
    Y := Y - 17;
    Row(CB, Y, 'Frase',
        'El ni' + Chr($F1) + 'o jug' + Chr($F3) + ' f' + Chr($FA) + 'tbol en el parqu' + Chr($E9) + '.');
    Y := Y - 20;

    // French
    SectionBar(CB, Y, 'Fran' + Chr($E7) + 'ais', 0.1, 0.5, 0.3);  Y := Y - 22;
    Row(CB, Y, 'Accents',
        Chr($E0) + ' ' + Chr($E2) + ' ' + Chr($E4) + ' ' + Chr($E9) + ' ' + Chr($E8) +
        ' ' + Chr($EA) + ' ' + Chr($EB) + ' ' + Chr($EE) + ' ' + Chr($EF) + ' ' + Chr($F4) +
        ' ' + Chr($F9) + ' ' + Chr($FB) + ' ' + Chr($FC) + ' ' + Chr($FF) +
        '  ' + Chr($C7) + ' ' + Chr($E7));
    Y := Y - 17;
    Row(CB, Y, 'Ligatures', Chr($E6) + ' ' + Chr($F8) + ' ' + Chr($C6) + ' ' + Chr($D8));
    Y := Y - 17;
    Row(CB, Y, 'Frase',
        'L' + Chr($27) + Chr($E9) + 't' + Chr($E9) + ' dernier, C' + Chr($E9) + 'cile a visit' +
        Chr($E9) + ' le ch' + Chr($E2) + 'teau pr' + Chr($E8) + 's de Fran' + Chr($E7) + 'ois.');
    Y := Y - 20;

    // German
    SectionBar(CB, Y, 'Deutsch', 0.4, 0.2, 0.6);  Y := Y - 22;
    Row(CB, Y, 'Umlauts',
        Chr($E4) + ' ' + Chr($F6) + ' ' + Chr($FC) + '  ' +
        Chr($C4) + ' ' + Chr($D6) + ' ' + Chr($DC) + '  ' + Chr($DF));
    Y := Y - 17;
    Row(CB, Y, 'Frase',
        'Zw' + Chr($F6) + 'lf Boxk' + Chr($E4) + 'mpfer jagen Viktor ' +
        Chr($FC) + 'ber den gro' + Chr($DF) + 'en Sylter Deich.');
    Y := Y - 20;

    // Portuguese
    SectionBar(CB, Y, 'Portugu' + Chr($EA) + 's', 0.2, 0.5, 0.6);  Y := Y - 22;
    Row(CB, Y, 'Til',
        Chr($E3) + ' ' + Chr($F5) + '  ' + Chr($C3) + ' ' + Chr($D5));
    Y := Y - 17;
    Row(CB, Y, 'Frase',
        'A av' + Chr($F3) + ' de Jo' + Chr($E3) + 'o n' + Chr($E3) +
        'o gosta de p' + Chr($E3) + 'o com a' + Chr($E7) + Chr($FA) + 'car.');
    Y := Y - 20;

    // Italian
    SectionBar(CB, Y, 'Italiano', 0.6, 0.4, 0.1);  Y := Y - 22;
    Row(CB, Y, 'Accenti',
        Chr($E0) + ' ' + Chr($E8) + ' ' + Chr($E9) + ' ' + Chr($EC) + ' ' + Chr($ED) +
        ' ' + Chr($F2) + ' ' + Chr($F3) + ' ' + Chr($F9) + ' ' + Chr($FA));
    Y := Y - 17;
    Row(CB, Y, 'Frase',
        'Perch' + Chr($E9) + ' Nicol' + Chr($F2) + ' ' + Chr($E8) + ' andato l' +
        Chr($E0) + ' senza pagare l' + Chr($27) + 'universit' + Chr($E0) + '?');
    Y := Y - 20;

    // Symbols
    SectionBar(CB, Y, 'S' + Chr($ED) + 'mbolos y Monedas', 0.5, 0.5, 0.1);  Y := Y - 22;
    Row(CB, Y, 'Monedas',
        Chr($80) + ' ' + Chr($A3) + ' ' + Chr($A5) + ' ' + Chr($A2) + ' ' + Chr($83));
    Y := Y - 17;
    Row(CB, Y, 'Legal',
        Chr($A9) + ' ' + Chr($AE) + ' ' + Chr($99) + ' ' + Chr($A7) + ' ' + Chr($B6));
    Y := Y - 17;
    Row(CB, Y, 'Matem.',
        Chr($B0) + ' ' + Chr($B1) + ' ' + Chr($D7) + ' ' + Chr($F7) + ' ' + Chr($BD) +
        ' ' + Chr($BC) + ' ' + Chr($BE) + ' ' + Chr($B9) + ' ' + Chr($B2) + ' ' + Chr($B3) + ' ' + Chr($B5));
    Y := Y - 17;
    Row(CB, Y, 'Tipog.',
        Chr($AB) + ' ' + Chr($BB) + ' ' + Chr($84) + ' ' + Chr($93) + ' ' + Chr($94) +
        ' ' + Chr($91) + ' ' + Chr($92) + ' ' + Chr($97) + ' ' + Chr($96) + ' ' + Chr($85) +
        ' ' + Chr($B7) + ' ' + Chr($95));

    // Footer
    CB.SetFillRGB(0.5, 0.5, 0.5);
    CB.SetLineWidth(0.5);
    CB.MoveTo(40, 55);
    CB.LineTo(555, 55);
    CB.Stroke;
    CB.BeginText;
    CB.SetFont('Regular', 8);
    CB.SetTextMatrix(1, 0, 0, 1, 40, 43);
    CB.ShowText('PDFLib Delphi ' + Chr($2014) + ' WinAnsiEncoding (CP1252) ' + Chr($2014) + ' P' + Chr($E1) + 'gina 1 / 2');
    CB.EndText;

    AttachContent(Page, CB);
  finally
    CB.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Build page 2: CP1252 table + stress test
// ---------------------------------------------------------------------------

procedure BuildPage2(Builder: TPDFBuilder);
var
  CB: TPDFContentBuilder;
  Page: TPDFDictionary;
  Y: Single;
  Code: Integer;
  LineStr: string;
begin
  Page := Builder.AddPage(595, 842);
  AddStdFont(Page, 'Regular', 'Helvetica');
  AddStdFont(Page, 'Bold',    'Helvetica-Bold');
  AddStdFont(Page, 'Mono',    'Courier');

  CB := TPDFContentBuilder.Create;
  try
    // Header
    CB.SetFillRGB(0.15, 0.35, 0.65);
    CB.Rectangle(40, 800, 515, 32);
    CB.Fill;
    CB.SetFillRGB(1, 1, 1);
    CB.BeginText;
    CB.SetFont('Bold', 15);
    CB.SetTextMatrix(1, 0, 0, 1, 46, 810);
    CB.ShowText('Caracteres Especiales ' + Chr($2014) + ' Tabla CP1252');
    CB.EndText;
    CB.SetFillRGB(0, 0, 0);

    Y := 770;

    // CP1252 0x80-0x9F (Windows extensions)
    SectionBar(CB, Y, 'CP1252 rango 0x80-0x9F (extensiones Windows)', 0.3, 0.3, 0.6);
    Y := Y - 22;
    CB.BeginText;
    CB.SetFont('Mono', 10);
    CB.SetTextMatrix(1, 0, 0, 1, 46, Y);
    CB.ShowText(Chr($80) + '  ' + Chr($82) + ' ' + Chr($83) + ' ' + Chr($84) + ' ' +
                Chr($85) + ' ' + Chr($86) + ' ' + Chr($87) + ' ' + Chr($88) + ' ' +
                Chr($89) + ' ' + Chr($8A) + ' ' + Chr($8B) + ' ' + Chr($8C) + '  ' + Chr($8E));
    Y := Y - 16;
    CB.SetTextMatrix(1, 0, 0, 1, 46, Y);
    CB.ShowText(Chr($91) + ' ' + Chr($92) + ' ' + Chr($93) + ' ' + Chr($94) + ' ' +
                Chr($95) + ' ' + Chr($96) + ' ' + Chr($97) + ' ' + Chr($98) + ' ' +
                Chr($99) + ' ' + Chr($9A) + ' ' + Chr($9B) + ' ' + Chr($9C) + '  ' +
                Chr($9E) + ' ' + Chr($9F));
    Y := Y - 16;
    CB.EndText;

    // CP1252 0xA0-0xFF (Latin-1 supplement)
    SectionBar(CB, Y - 4, 'CP1252 rango 0xA0-0xFF (tabla completa, 16 por fila)', 0.2, 0.5, 0.3);
    Y := Y - 26;
    CB.BeginText;
    CB.SetFont('Mono', 9);
    LineStr := '';
    for Code := $A0 to $FF do
    begin
      LineStr := LineStr + Chr(Code) + ' ';
      if (Code - $A0 + 1) mod 16 = 0 then
      begin
        CB.SetTextMatrix(1, 0, 0, 1, 46, Y);
        CB.ShowText(Format('$%2.2X: ', [Code - 15]) + LineStr.Trim);
        Y := Y - 13;
        LineStr := '';
      end;
    end;
    CB.EndText;

    // Mixed stress test
    SectionBar(CB, Y - 4, 'Texto mixto ' + Chr($2014) + ' prueba de estr' + Chr($E9) + 's', 0.6, 0.2, 0.2);
    Y := Y - 22;
    CB.BeginText;
    CB.SetFont('Regular', 10);
    CB.SetTextMatrix(1, 0, 0, 1, 46, Y);
    CB.ShowText('H' + Chr($E9) + 'llo W' + Chr($F6) + 'rld ' + Chr($2014) +
                ' ' + Chr($D1) + 'o' + Chr($F1) + 'o Garc' + Chr($ED) + 'a visita S' +
                Chr($E3) + 'o Paulo.');
    Y := Y - 16;
    CB.SetTextMatrix(1, 0, 0, 1, 46, Y);
    CB.ShowText('La fa' + Chr($E7) + 'ade de l' + Chr($27) + 'h' + Chr($F4) +
                'tel co' + Chr($FB) + 'te 1.500 ' + Chr($80) + ' ' + Chr($2014) +
                ' ' + Chr($A1) + 'Incre' + Chr($ED) + 'ble precio!');
    Y := Y - 16;
    CB.SetTextMatrix(1, 0, 0, 1, 46, Y);
    CB.ShowText('Stra' + Chr($DF) + 'e, B' + Chr($E4) + 'ckerei, ' + Chr($DC) +
                'ber ' + Chr($2014) + ' M' + Chr($FC) + 'nchen (20' + Chr($B0) +
                'C ' + Chr($B1) + ' 5' + Chr($B0) + 'C).');
    Y := Y - 16;
    CB.SetTextMatrix(1, 0, 0, 1, 46, Y);
    CB.ShowText('Fracciones: ' + Chr($BD) + ' ' + Chr($BC) + ' ' + Chr($BE) +
                '   Pot.: 2' + Chr($B2) + '=4  2' + Chr($B3) + '=8' +
                '   Griego (fuera CP1252): ??? ' + Chr($2014) + ' muestran "?"');
    CB.EndText;

    // Note about emojis / beyond CP1252
    SectionBar(CB, Y - 20, 'Nota: l' + Chr($ED) + 'mites de WinAnsiEncoding', 0.5, 0.5, 0.5);
    Y := Y - 42;
    CB.BeginText;
    CB.SetFont('Regular', 9);
    CB.SetTextMatrix(1, 0, 0, 1, 46, Y);
    CB.ShowText('Las fuentes Type1 est' + Chr($E1) + 'ndar (Helvetica, Times, Courier) usan WinAnsiEncoding.');
    Y := Y - 14;
    CB.SetTextMatrix(1, 0, 0, 1, 46, Y);
    CB.ShowText('Cubren el rango CP1252 (256 caracteres). Emojis, CJK, ' + Chr($C1) + 'rabe ' + Chr($2192) + ' aparecen "?".');
    Y := Y - 14;
    CB.SetTextMatrix(1, 0, 0, 1, 46, Y);
    CB.ShowText('Para Unicode completo se deben embeber fuentes TrueType/OpenType (fase pendiente).');
    CB.EndText;

    // Footer
    CB.SetFillRGB(0.5, 0.5, 0.5);
    CB.SetLineWidth(0.5);
    CB.MoveTo(40, 55);
    CB.LineTo(555, 55);
    CB.Stroke;
    CB.BeginText;
    CB.SetFont('Regular', 8);
    CB.SetTextMatrix(1, 0, 0, 1, 40, 43);
    CB.ShowText('PDFLib Delphi ' + Chr($2014) + ' WinAnsiEncoding (CP1252) ' + Chr($2014) + ' P' + Chr($E1) + 'gina 2 / 2');
    CB.EndText;

    AttachContent(Page, CB);
  finally
    CB.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

var
  OutPath: string;

begin
  OutPath := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)))
             + 'demo_special_chars.pdf';

  WriteLn('Generando: ', OutPath);

  var Builder := TPDFBuilder.Create;
  try
    Builder.SetTitle('Demostraci' + Chr($F3) + 'n de Caracteres Especiales');
    Builder.SetAuthor(Chr($D1) + 'o' + Chr($F1) + 'o Garc' + Chr($ED) + 'a ' +
                      Chr($2014) + ' Andr' + Chr($E9) + ' C' + Chr($F4) + 't' + Chr($E9));
    Builder.SetSubject('Tildes, e' + Chr($F1) + 'es, acentos, s' + Chr($ED) + 'mbolos CP1252');
    Builder.SetCreator('PDFLib Delphi ' + Chr($2014) + ' DemoSpecialChars');

    BuildPage1(Builder);
    BuildPage2(Builder);

    Builder.SaveToFile(OutPath);
    WriteLn('Guardado:  ', OutPath);

    var Doc := TPDFDocument.Create;
    try
      Doc.LoadFromFile(OutPath);
      WriteLn('P' + Chr($E1) + 'ginas : ', Doc.PageCount);
      WriteLn('T' + Chr($ED) + 'tulo  : ', Doc.Title);
      WriteLn('Autor  : ', Doc.Author);
    finally
      Doc.Free;
    end;

  finally
    Builder.Free;
  end;

  WriteLn;
  WriteLn('Listo. Presione Enter...');
  ReadLn;
end.
