program TestExtract;

{
  Test suite for the extract/ library (Fase 1 + Fase 2 + Fase 3 + Fase 4).
  Uses the same lightweight Pass/Fail/Check pattern as the PDF test suite.
}

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}
{$R *.res}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Zip,
  uExtract.Result        in '..\Src\uExtract.Result.pas',
  uExtract.StreamInfo    in '..\Src\uExtract.StreamInfo.pas',
  uExtract.Converter     in '..\Src\uExtract.Converter.pas',
  uExtract.Engine        in '..\Src\uExtract.Engine.pas',
  uExtract.Conv.Text     in '..\Src\Converters\uExtract.Conv.Text.pas',
  uExtract.Conv.Markdown in '..\Src\Converters\uExtract.Conv.Markdown.pas',
  uExtract.Conv.CSV      in '..\Src\Converters\uExtract.Conv.CSV.pas',
  uExtract.Conv.JSON     in '..\Src\Converters\uExtract.Conv.JSON.pas',
  uExtract.Conv.XML      in '..\Src\Converters\uExtract.Conv.XML.pas',
  uExtract.Conv.INI      in '..\Src\Converters\uExtract.Conv.INI.pas',
  uExtract.Conv.RTF      in '..\Src\Converters\uExtract.Conv.RTF.pas',
  uExtract.Conv.HTML     in '..\Src\Converters\uExtract.Conv.HTML.pas',
  uExtract.OpenXML       in '..\Src\uExtract.OpenXML.pas',
  uExtract.Conv.DOCX     in '..\Src\Converters\uExtract.Conv.DOCX.pas',
  uExtract.Conv.XLSX     in '..\Src\Converters\uExtract.Conv.XLSX.pas',
  uExtract.Conv.PPTX     in '..\Src\Converters\uExtract.Conv.PPTX.pas',
  uExtract.Conv.PDF      in '..\Src\Converters\uExtract.Conv.PDF.pas',
  uExtract.Conv.EPUB     in '..\Src\Converters\uExtract.Conv.EPUB.pas',
  uPDF.Objects           in '..\..\pdf\Src\Core\uPDF.Objects.pas',
  uPDF.Writer            in '..\..\pdf\Src\Core\uPDF.Writer.pas';

// ==========================================================================
// Helpers
// ==========================================================================

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
  if AReason <> '' then WriteLn('  [FAIL] ', AMsg, ' — ', AReason)
  else              WriteLn('  [FAIL] ', AMsg);
end;

procedure Check(ACondition: Boolean; const AMsg: string; const AReason: string = '');
begin
  if ACondition then Pass(AMsg) else Fail(AMsg, AReason);
end;

function FixturePath(const AName: string): string;
begin
  Result := TPath.Combine(TPath.GetDirectoryName(ParamStr(0)), 'Fixtures' + PathDelim + AName);
end;

procedure Section(const ATitle: string);
begin
  WriteLn;
  WriteLn('--- ', ATitle, ' ---');
end;

// ==========================================================================
// TConversionResult record
// ==========================================================================

procedure TestResult;
begin
  Section('TConversionResult');
  var R := TConversionResult.Ok('# Hello', 'Title');
  Check(R.Success,            'Ok.Success is True');
  Check(R.Markdown = '# Hello','Ok.Markdown preserved');
  Check(R.Title = 'Title',    'Ok.Title preserved');
  Check(R.ErrorMessage = '',  'Ok.ErrorMessage empty');

  var F := TConversionResult.Fail('oops');
  Check(not F.Success,        'Fail.Success is False');
  Check(F.ErrorMessage = 'oops','Fail.ErrorMessage set');
  Check(F.Markdown = '',      'Fail.Markdown empty');
end;

// ==========================================================================
// TStreamInfo record
// ==========================================================================

procedure TestStreamInfo;
begin
  Section('TStreamInfo');
  var SI := TStreamInfo.FromFile('report.CSV');
  Check(SI.Extension = '.csv',       'FromFile: extension lowercased');
  Check(SI.FileName = 'report.CSV',  'FromFile: filename preserved');

  var SI2 := TStreamInfo.From('json', 'application/json');
  Check(SI2.Extension = '.json',     'From: dot added automatically');

  var SI3 := TStreamInfo.From('.JSON', '');
  Check(SI3.Extension = '.json',     'From: dot already present, lowercase');

  Check(SI2.HasExtension('.json'),   'HasExtension: match');
  Check(SI2.HasExtension('json'),    'HasExtension: without dot');
  Check(not SI2.HasExtension('.csv'),'HasExtension: no match');

  var SI4 := TStreamInfo.From('.md', '');
  Check(SI4.HasAnyExtension(['.csv', '.md', '.txt']), 'HasAnyExtension: match');
  Check(not SI4.HasAnyExtension(['.csv', '.xml']),    'HasAnyExtension: no match');
end;

// ==========================================================================
// TTextConverter
// ==========================================================================

procedure TestTextConverter;
var
  Conv: TTextConverter;
  Info: TStreamInfo;
begin
  Section('TTextConverter');
  Conv := TTextConverter.Create;
  try
    Info := TStreamInfo.From('.txt', '');
    Check(Conv.Accepts(Info),          'Accepts .txt');
    Info := TStreamInfo.From('.log', '');
    Check(Conv.Accepts(Info),          'Accepts .log');
    Info := TStreamInfo.From('.csv', '');
    Check(not Conv.Accepts(Info),      'Rejects .csv');

    var FP := FixturePath('hello.txt');
    if TFile.Exists(FP) then
    begin
      var FS := TFileStream.Create(FP, fmOpenRead or fmShareDenyWrite);
      try
        var R := Conv.Convert(FS, TStreamInfo.FromFile(FP));
        Check(R.Success,                   'Convert: success');
        Check(R.Markdown.Contains('Hello'),'Convert: contains Hello');
      finally
        FS.Free;
      end;
    end
    else
      Fail('hello.txt fixture missing');
  finally
    Conv.Free;
  end;
end;

// ==========================================================================
// TMarkdownConverter
// ==========================================================================

procedure TestMarkdownConverter;
var
  Conv: TMarkdownConverter;
begin
  Section('TMarkdownConverter');
  Conv := TMarkdownConverter.Create;
  try
    Check(Conv.Accepts(TStreamInfo.From('.md', '')),       'Accepts .md');
    Check(Conv.Accepts(TStreamInfo.From('.markdown', '')), 'Accepts .markdown');
    Check(not Conv.Accepts(TStreamInfo.From('.txt', '')),  'Rejects .txt');

    var FP := FixturePath('sample.md');
    if TFile.Exists(FP) then
    begin
      var FS := TFileStream.Create(FP, fmOpenRead or fmShareDenyWrite);
      try
        var R := Conv.Convert(FS, TStreamInfo.FromFile(FP));
        Check(R.Success,                     'Convert: success');
        Check(R.Markdown.Contains('# Hello'),'Convert: heading preserved');
        Check(R.Markdown.Contains('**Markdown**'), 'Convert: bold preserved');
      finally
        FS.Free;
      end;
    end
    else
      Fail('sample.md fixture missing');
  finally
    Conv.Free;
  end;
end;

// ==========================================================================
// TCSVConverter
// ==========================================================================

procedure TestCSVConverter;
var
  Conv: TCSVConverter;

  function ConvertFixture(const AName: string): TConversionResult;
  var FP: string; FS: TFileStream;
  begin
    FP := FixturePath(AName);
    FS := TFileStream.Create(FP, fmOpenRead or fmShareDenyWrite);
    try
      Result := Conv.Convert(FS, TStreamInfo.FromFile(FP));
    finally
      FS.Free;
    end;
  end;

begin
  Section('TCSVConverter');
  Conv := TCSVConverter.Create;
  try
    Check(Conv.Accepts(TStreamInfo.From('.csv', '')), 'Accepts .csv');
    Check(Conv.Accepts(TStreamInfo.From('.tsv', '')), 'Accepts .tsv');
    Check(not Conv.Accepts(TStreamInfo.From('.txt','')), 'Rejects .txt');

    // comma-delimited
    var R := ConvertFixture('simple.csv');
    Check(R.Success,                          'simple.csv: success');
    Check(R.Markdown.Contains('| Name |'),    'simple.csv: header Name');
    Check(R.Markdown.Contains('| Alice |'),   'simple.csv: row Alice');
    Check(R.Markdown.Contains('| --- |'),     'simple.csv: separator row');
    // quoted field with comma
    Check(R.Markdown.Contains('García, Juan') or
          R.Markdown.Contains('Garc'), 'simple.csv: quoted field parsed');

    // semicolon-delimited
    var R2 := ConvertFixture('semicolon.csv');
    Check(R2.Success,                          'semicolon.csv: success');
    Check(R2.Markdown.Contains('| Nombre |'), 'semicolon.csv: header Nombre');
    Check(R2.Markdown.Contains('| Pedro |'),  'semicolon.csv: row Pedro (semicolon detected)');

    // pipe character escaping
    var Stream := TStringStream.Create('A|B,C' + sLineBreak + '1|2,3',
                                       TEncoding.UTF8);
    try
      var R3 := Conv.Convert(Stream, TStreamInfo.From('.csv', ''));
      Check(R3.Success,                           'pipe escape: success');
      Check(R3.Markdown.Contains('\|'),            'pipe escape: | escaped');
    finally
      Stream.Free;
    end;

    // empty input
    var Empty := TStringStream.Create('', TEncoding.UTF8);
    try
      var R4 := Conv.Convert(Empty, TStreamInfo.From('.csv', ''));
      Check(not R4.Success, 'empty CSV: returns failure');
    finally
      Empty.Free;
    end;
  finally
    Conv.Free;
  end;
end;

// ==========================================================================
// TJSONConverter
// ==========================================================================

procedure TestJSONConverter;
var
  Conv: TJSONConverter;

  function ConvertStr(const AContent: string): TConversionResult;
  var S: TStringStream;
  begin
    S := TStringStream.Create(AContent, TEncoding.UTF8);
    try
      Result := Conv.Convert(S, TStreamInfo.From('.json', ''));
    finally
      S.Free;
    end;
  end;

  function ConvertFixture(const AName: string): TConversionResult;
  var FP: string; FS: TFileStream;
  begin
    FP := FixturePath(AName);
    FS := TFileStream.Create(FP, fmOpenRead or fmShareDenyWrite);
    try
      Result := Conv.Convert(FS, TStreamInfo.FromFile(FP));
    finally
      FS.Free;
    end;
  end;

begin
  Section('TJSONConverter');
  Conv := TJSONConverter.Create;
  try
    Check(Conv.Accepts(TStreamInfo.From('.json', '')),    'Accepts .json');
    Check(Conv.Accepts(TStreamInfo.From('.geojson', '')), 'Accepts .geojson');
    Check(not Conv.Accepts(TStreamInfo.From('.xml', '')), 'Rejects .xml');

    // flat object → property table
    var R1 := ConvertFixture('flat_object.json');
    Check(R1.Success,                            'flat_object: success');
    Check(R1.Markdown.Contains('| Property |'), 'flat_object: has Property header');
    Check(R1.Markdown.Contains('| name |'),     'flat_object: row for name key');
    Check(R1.Markdown.Contains('Alice'),        'flat_object: value Alice');

    // array of objects → data table
    var R2 := ConvertFixture('array_of_objects.json');
    Check(R2.Success,                           'array_of_objects: success');
    Check(R2.Markdown.Contains('| name |'),    'array_of_objects: header name');
    Check(R2.Markdown.Contains('| Alice |'),   'array_of_objects: row Alice');
    Check(R2.Markdown.Contains('| Carlos |'),  'array_of_objects: row Carlos');

    // nested → fenced code block
    var R3 := ConvertFixture('nested.json');
    Check(R3.Success,                           'nested: success');
    Check(R3.Markdown.Contains('```json'),      'nested: fenced block');

    // invalid JSON
    var R4 := ConvertStr('{broken json');
    Check(not R4.Success,                       'invalid JSON: failure result');

    // empty
    var R5 := ConvertStr('');
    Check(not R5.Success,                       'empty: failure result');
  finally
    Conv.Free;
  end;
end;

// ==========================================================================
// TXMLConverter
// ==========================================================================

procedure TestXMLConverter;
var
  Conv: TXMLConverter;

  function ConvertFixture(const AName: string): TConversionResult;
  var FP: string; FS: TFileStream;
  begin
    FP := FixturePath(AName);
    FS := TFileStream.Create(FP, fmOpenRead or fmShareDenyWrite);
    try
      Result := Conv.Convert(FS, TStreamInfo.FromFile(FP));
    finally
      FS.Free;
    end;
  end;

begin
  Section('TXMLConverter');
  Conv := TXMLConverter.Create;
  try
    Check(Conv.Accepts(TStreamInfo.From('.xml', '')),  'Accepts .xml');
    Check(Conv.Accepts(TStreamInfo.From('.rss', '')),  'Accepts .rss');
    Check(Conv.Accepts(TStreamInfo.From('.svg', '')),  'Accepts .svg');
    Check(not Conv.Accepts(TStreamInfo.From('.json','')), 'Rejects .json');

    var R := ConvertFixture('sample.xml');
    Check(R.Success,                           'sample.xml: success');
    Check(R.Markdown.Contains('```xml'),       'sample.xml: fenced block');
    Check(R.Markdown.Contains('<catalog>'),    'sample.xml: content present');
    Check(R.Markdown.Contains('Clean Code'),  'sample.xml: book title present');

    // empty
    var Empty := TStringStream.Create('', TEncoding.UTF8);
    try
      var R2 := Conv.Convert(Empty, TStreamInfo.From('.xml', ''));
      Check(not R2.Success, 'empty XML: failure result');
    finally
      Empty.Free;
    end;
  finally
    Conv.Free;
  end;
end;

// ==========================================================================
// TMarkItDown engine integration
// ==========================================================================

procedure TestEngine;
var
  MD: TMarkItDown;
begin
  Section('TMarkItDown engine');
  MD := TMarkItDown.Create;
  try
    // file not found
    var R1 := MD.ConvertFile('nonexistent_xyz.txt');
    Check(not R1.Success, 'ConvertFile: file not found → failure');

    // route by extension
    var R2 := MD.ConvertFile(FixturePath('simple.csv'));
    Check(R2.Success,                        'ConvertFile: CSV routed correctly');
    Check(R2.Markdown.Contains('| Name |'), 'ConvertFile: CSV markdown output');

    var R3 := MD.ConvertFile(FixturePath('flat_object.json'));
    Check(R3.Success,                        'ConvertFile: JSON routed correctly');

    var R4 := MD.ConvertFile(FixturePath('sample.xml'));
    Check(R4.Success,                        'ConvertFile: XML routed correctly');

    var R5 := MD.ConvertFile(FixturePath('hello.txt'));
    Check(R5.Success,                        'ConvertFile: TXT routed correctly');

    var R6 := MD.ConvertFile(FixturePath('sample.md'));
    Check(R6.Success,                        'ConvertFile: MD routed correctly');

    // unsupported format
    var S := TStringStream.Create('data', TEncoding.UTF8);
    try
      var R7 := MD.ConvertStream(S, TStreamInfo.From('.xyz', ''));
      Check(not R7.Success, 'ConvertStream: unknown format → failure');
    finally
      S.Free;
    end;

    // stream without extension — magic bytes
    var XmlStream := TStringStream.Create('<?xml version="1.0"?><r/>', TEncoding.UTF8);
    try
      var R8 := MD.ConvertStream(XmlStream, TStreamInfo.From('', ''));
      Check(R8.Success, 'ConvertStream: XML detected via magic bytes');
    finally
      XmlStream.Free;
    end;

    // custom converter registration
    var MD2 := TMarkItDown.Create(False {no defaults});
    try
      MD2.RegisterConverter(TTextConverter.Create);
      var R9 := MD2.ConvertFile(FixturePath('hello.txt'));
      Check(R9.Success, 'Custom registration: TXT converter works');
      var R10 := MD2.ConvertFile(FixturePath('simple.csv'));
      Check(not R10.Success, 'Custom registration: CSV not registered → failure');
    finally
      MD2.Free;
    end;

  finally
    MD.Free;
  end;
end;

// ==========================================================================
// TINIConverter
// ==========================================================================

procedure TestINIConverter;
var
  Conv: TINIConverter;

  function ConvStr(const S: string): TConversionResult;
  var St: TStringStream;
  begin
    St := TStringStream.Create(S, TEncoding.UTF8);
    try Result := Conv.Convert(St, TStreamInfo.From('.ini',''));
    finally St.Free; end;
  end;

  function ConvFixture(const AName: string): TConversionResult;
  var FP: string; FS: TFileStream;
  begin
    FP := FixturePath(AName);
    FS := TFileStream.Create(FP, fmOpenRead or fmShareDenyWrite);
    try Result := Conv.Convert(FS, TStreamInfo.FromFile(FP));
    finally FS.Free; end;
  end;

begin
  Section('TINIConverter');
  Conv := TINIConverter.Create;
  try
    Check(Conv.Accepts(TStreamInfo.From('.ini','')),  'Accepts .ini');
    Check(Conv.Accepts(TStreamInfo.From('.cfg','')),  'Accepts .cfg');
    Check(Conv.Accepts(TStreamInfo.From('.env','')),  'Accepts .env');
    Check(not Conv.Accepts(TStreamInfo.From('.csv','')), 'Rejects .csv');

    var R := ConvFixture('sample.ini');
    Check(R.Success,                            'sample.ini: success');
    Check(R.Markdown.Contains('## Database'),  'sample.ini: Database section');
    Check(R.Markdown.Contains('## Server'),    'sample.ini: Server section');
    Check(R.Markdown.Contains('| host |'),     'sample.ini: host key');
    Check(R.Markdown.Contains('localhost'),    'sample.ini: localhost value');
    Check(R.Markdown.Contains('| port |'),     'sample.ini: port key');

    var R2 := ConvFixture('global.ini');
    Check(R2.Success,                           'global.ini: success');
    Check(R2.Markdown.Contains('(global)'),    'global.ini: global section heading');
    Check(R2.Markdown.Contains('debug'),       'global.ini: debug key');

    var R3 := ConvStr('# comment only');
    Check(not R3.Success,                       'comment-only: failure');

    // env-style with quotes
    var R4 := ConvStr('KEY="my value"' + sLineBreak + 'OTHER=simple');
    Check(R4.Success,                           'env-style: success');
    Check(R4.Markdown.Contains('my value'),    'env-style: quoted value stripped');
  finally
    Conv.Free;
  end;
end;

// ==========================================================================
// TRTFConverter
// ==========================================================================

procedure TestRTFConverter;
var
  Conv: TRTFConverter;

  function ConvFixture(const AName: string): TConversionResult;
  var FP: string; FS: TFileStream;
  begin
    FP := FixturePath(AName);
    FS := TFileStream.Create(FP, fmOpenRead or fmShareDenyWrite);
    try Result := Conv.Convert(FS, TStreamInfo.FromFile(FP));
    finally FS.Free; end;
  end;

  function ConvStr(const S: string): TConversionResult;
  var St: TStringStream;
  begin
    St := TStringStream.Create(S, TEncoding.ASCII);
    try Result := Conv.Convert(St, TStreamInfo.From('.rtf',''));
    finally St.Free; end;
  end;

begin
  Section('TRTFConverter');
  Conv := TRTFConverter.Create;
  try
    Check(Conv.Accepts(TStreamInfo.From('.rtf','')),  'Accepts .rtf');
    Check(not Conv.Accepts(TStreamInfo.From('.doc','')), 'Rejects .doc');

    var R := ConvFixture('sample.rtf');
    Check(R.Success,                          'sample.rtf: success');
    Check(R.Markdown.Contains('Hello'),      'sample.rtf: Hello text');
    Check(R.Markdown.Contains('World'),      'sample.rtf: World text');
    Check(R.Markdown.Contains('RTF'),        'sample.rtf: RTF text');

    // font table should not appear in output
    Check(not R.Markdown.Contains('fonttbl'), 'sample.rtf: fonttbl skipped');
    Check(not R.Markdown.Contains('Arial'),   'sample.rtf: font names skipped');

    // invalid RTF
    var R2 := ConvStr('not rtf content');
    Check(not R2.Success,                     'invalid RTF: failure');

    // empty
    var R3 := ConvStr('');
    Check(not R3.Success,                     'empty: failure');

    // paragraphs produce blank lines
    var RTF4 := '{\rtf1 Hello\par World\par}';
    var R4 := ConvStr(RTF4);
    Check(R4.Success,                         'minimal RTF: success');
    Check(R4.Markdown.Contains('Hello'),     'minimal RTF: Hello');
    Check(R4.Markdown.Contains('World'),     'minimal RTF: World');
  finally
    Conv.Free;
  end;
end;

// ==========================================================================
// THTMLConverter
// ==========================================================================

procedure TestHTMLConverter;
var
  Conv: THTMLConverter;

  function ConvFixture(const AName: string): TConversionResult;
  var FP: string; FS: TFileStream;
  begin
    FP := FixturePath(AName);
    FS := TFileStream.Create(FP, fmOpenRead or fmShareDenyWrite);
    try Result := Conv.Convert(FS, TStreamInfo.FromFile(FP));
    finally FS.Free; end;
  end;

  function ConvStr(const S: string): TConversionResult;
  var St: TStringStream;
  begin
    St := TStringStream.Create(S, TEncoding.UTF8);
    try Result := Conv.Convert(St, TStreamInfo.From('.html',''));
    finally St.Free; end;
  end;

begin
  Section('THTMLConverter');
  Conv := THTMLConverter.Create;
  try
    Check(Conv.Accepts(TStreamInfo.From('.html','')),  'Accepts .html');
    Check(Conv.Accepts(TStreamInfo.From('.htm','')),   'Accepts .htm');
    Check(Conv.Accepts(TStreamInfo.From('.xhtml','')), 'Accepts .xhtml');
    Check(not Conv.Accepts(TStreamInfo.From('.xml','')), 'Rejects .xml');

    var R := ConvFixture('sample.html');
    Check(R.Success,                               'sample.html: success');
    Check(R.Title = 'Test Page',                  'sample.html: title extracted');
    Check(R.Markdown.Contains('# Hello World'),   'sample.html: h1 converted');
    Check(R.Markdown.Contains('## Links'),        'sample.html: h2 converted');
    Check(R.Markdown.Contains('**bold**'),        'sample.html: bold converted');
    Check(R.Markdown.Contains('*italic*'),        'sample.html: italic converted');
    Check(R.Markdown.Contains('[Example]'),       'sample.html: link text');
    Check(R.Markdown.Contains('https://example.com'), 'sample.html: link href');
    Check(R.Markdown.Contains('- Item one'),      'sample.html: list item');
    Check(R.Markdown.Contains('| Name |'),        'sample.html: table header');
    Check(R.Markdown.Contains('| Alice |'),       'sample.html: table data');
    // script/style content must be absent
    Check(not R.Markdown.Contains('var x = 1'),  'sample.html: script skipped');
    Check(not R.Markdown.Contains('color: red'),  'sample.html: style skipped');

    // headings
    var R2 := ConvStr('<h1>H1</h1><h2>H2</h2><h3>H3</h3>');
    Check(R2.Markdown.Contains('# H1'),   'headings: h1');
    Check(R2.Markdown.Contains('## H2'),  'headings: h2');
    Check(R2.Markdown.Contains('### H3'), 'headings: h3');

    // blockquote
    var R3 := ConvStr('<blockquote><p>Quoted text</p></blockquote>');
    Check(R3.Success,                           'blockquote: success');
    Check(R3.Markdown.Contains('> '),          'blockquote: > prefix');
    Check(R3.Markdown.Contains('Quoted text'), 'blockquote: content');

    // code block
    var R4 := ConvStr('<pre><code>x := 1;</code></pre>');
    Check(R4.Markdown.Contains('```'),   'code block: fence');
    Check(R4.Markdown.Contains('x := '), 'code block: content');

    // hr
    var R5 := ConvStr('<p>A</p><hr><p>B</p>');
    Check(R5.Markdown.Contains('---'), 'hr: converted');

    // empty
    var R6 := ConvStr('');
    Check(not R6.Success, 'empty HTML: failure');
  finally
    Conv.Free;
  end;
end;

// ==========================================================================
// ==========================================================================
// Fixture builders for Open XML formats (created at test time)
// ==========================================================================

procedure AddZipEntry(AZip: TZipFile; const AName, AContent: string);
var
  MS: TMemoryStream;
  B : TBytes;
begin
  B  := TEncoding.UTF8.GetBytes(AContent);
  MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(B[0], Length(B));
    MS.Position := 0;
    AZip.Add(MS, AName);
  finally
    MS.Free;
  end;
end;

procedure CreateDocxFixture(const APath: string);
const
  CT =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
    '<Default Extension="xml" ContentType="application/xml"/>' +
    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
    '</Types>';
  RELS =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
    '</Relationships>';
  DRELS =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>';
  DOC =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
    '<w:body>' +
    '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Hello World</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>This is a test document.</w:t></w:r></w:p>' +
    '<w:tbl>' +
    '<w:tr>' +
    '<w:tc><w:p><w:r><w:t>Name</w:t></w:r></w:p></w:tc>' +
    '<w:tc><w:p><w:r><w:t>Age</w:t></w:r></w:p></w:tc>' +
    '</w:tr>' +
    '<w:tr>' +
    '<w:tc><w:p><w:r><w:t>Alice</w:t></w:r></w:p></w:tc>' +
    '<w:tc><w:p><w:r><w:t>30</w:t></w:r></w:p></w:tc>' +
    '</w:tr>' +
    '</w:tbl>' +
    '<w:sectPr/>' +
    '</w:body>' +
    '</w:document>';
var
  Zip: TZipFile;
begin
  Zip := TZipFile.Create;
  try
    Zip.Open(APath, zmWrite);
    AddZipEntry(Zip, '[Content_Types].xml',       CT);
    AddZipEntry(Zip, '_rels/.rels',               RELS);
    AddZipEntry(Zip, 'word/_rels/document.xml.rels', DRELS);
    AddZipEntry(Zip, 'word/document.xml',         DOC);
  finally
    Zip.Free;
  end;
end;

procedure CreateXlsxFixture(const APath: string);
const
  CT =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
    '<Default Extension="xml" ContentType="application/xml"/>' +
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' +
    '</Types>';
  RELS =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
    '</Relationships>';
  WB =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
    '<sheets><sheet name="Products" sheetId="1" r:id="rId1"/></sheets>' +
    '</workbook>';
  WB_RELS =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>' +
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>' +
    '</Relationships>';
  SS =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="4" uniqueCount="4">' +
    '<si><t>Product</t></si>' +
    '<si><t>Price</t></si>' +
    '<si><t>Widget</t></si>' +
    '<si><t>Gadget</t></si>' +
    '</sst>';
  SHEET =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
    '<sheetData>' +
    '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>' +
    '<row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>9.99</v></c></row>' +
    '<row r="3"><c r="A3" t="s"><v>3</v></c><c r="B3"><v>19.99</v></c></row>' +
    '</sheetData>' +
    '</worksheet>';
var
  Zip: TZipFile;
begin
  Zip := TZipFile.Create;
  try
    Zip.Open(APath, zmWrite);
    AddZipEntry(Zip, '[Content_Types].xml',          CT);
    AddZipEntry(Zip, '_rels/.rels',                  RELS);
    AddZipEntry(Zip, 'xl/workbook.xml',              WB);
    AddZipEntry(Zip, 'xl/_rels/workbook.xml.rels',   WB_RELS);
    AddZipEntry(Zip, 'xl/sharedStrings.xml',         SS);
    AddZipEntry(Zip, 'xl/worksheets/sheet1.xml',     SHEET);
  finally
    Zip.Free;
  end;
end;

procedure CreatePptxFixture(const APath: string);
const
  CT =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
    '<Default Extension="xml" ContentType="application/xml"/>' +
    '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>' +
    '</Types>';
  RELS =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>' +
    '</Relationships>';
  PRES =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
    '<p:sldIdLst><p:sldId id="256" r:id="rId1"/><p:sldId id="257" r:id="rId2"/></p:sldIdLst>' +
    '</p:presentation>';
  SLIDE1 =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"' +
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
    '<p:cSld><p:spTree>' +
    '<p:sp><p:txBody>' +
    '<a:p><a:r><a:t>Slide One Title</a:t></a:r></a:p>' +
    '</p:txBody></p:sp>' +
    '<p:sp><p:txBody>' +
    '<a:p><a:r><a:t>First bullet</a:t></a:r></a:p>' +
    '<a:p><a:r><a:t>Second bullet</a:t></a:r></a:p>' +
    '</p:txBody></p:sp>' +
    '</p:spTree></p:cSld>' +
    '</p:sld>';
  SLIDE2 =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"' +
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
    '<p:cSld><p:spTree>' +
    '<p:sp><p:txBody>' +
    '<a:p><a:r><a:t>Slide Two Content</a:t></a:r></a:p>' +
    '</p:txBody></p:sp>' +
    '</p:spTree></p:cSld>' +
    '</p:sld>';
var
  Zip: TZipFile;
begin
  Zip := TZipFile.Create;
  try
    Zip.Open(APath, zmWrite);
    AddZipEntry(Zip, '[Content_Types].xml',    CT);
    AddZipEntry(Zip, '_rels/.rels',            RELS);
    AddZipEntry(Zip, 'ppt/presentation.xml',   PRES);
    AddZipEntry(Zip, 'ppt/slides/slide1.xml',  SLIDE1);
    AddZipEntry(Zip, 'ppt/slides/slide2.xml',  SLIDE2);
  finally
    Zip.Free;
  end;
end;

// ==========================================================================
// TDOCXConverter
// ==========================================================================

procedure TestDOCXConverter;
var
  Conv    : TDOCXConverter;
  DocxPath: string;

  function ConvFile(const APath: string): TConversionResult;
  var FS: TFileStream;
  begin
    FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
    try Result := Conv.Convert(FS, TStreamInfo.FromFile(APath));
    finally FS.Free; end;
  end;

begin
  Section('TDOCXConverter');
  Conv := TDOCXConverter.Create;
  try
    Check(Conv.Accepts(TStreamInfo.From('.docx', '')),     'Accepts .docx');
    Check(Conv.Accepts(TStreamInfo.From('.docm', '')),     'Accepts .docm');
    Check(not Conv.Accepts(TStreamInfo.From('.doc', '')),  'Rejects .doc');

    DocxPath := FixturePath('sample.docx');
    CreateDocxFixture(DocxPath);
    try
      var R := ConvFile(DocxPath);
      Check(R.Success,                            'sample.docx: success');
      Check(R.Markdown.Contains('# Hello World'), 'sample.docx: heading');
      Check(R.Markdown.Contains('test document'), 'sample.docx: paragraph text');
      Check(R.Markdown.Contains('Name'),          'sample.docx: table header');
      Check(R.Markdown.Contains('Alice'),         'sample.docx: table data');
      Check(R.Markdown.Contains('30'),            'sample.docx: table value');
      Check(R.Markdown.Contains('---'),           'sample.docx: table separator');
    finally
      TFile.Delete(DocxPath);
    end;

    var MS := TMemoryStream.Create;
    try
      var R2 := Conv.Convert(MS, TStreamInfo.From('.docx', ''));
      Check(not R2.Success, 'empty stream: failure');
    finally
      MS.Free;
    end;
  finally
    Conv.Free;
  end;
end;

// ==========================================================================
// TXLSXConverter
// ==========================================================================

procedure TestXLSXConverter;
var
  Conv    : TXLSXConverter;
  XlsxPath: string;

  function ConvFile(const APath: string): TConversionResult;
  var FS: TFileStream;
  begin
    FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
    try Result := Conv.Convert(FS, TStreamInfo.FromFile(APath));
    finally FS.Free; end;
  end;

begin
  Section('TXLSXConverter');
  Conv := TXLSXConverter.Create;
  try
    Check(Conv.Accepts(TStreamInfo.From('.xlsx', '')),     'Accepts .xlsx');
    Check(Conv.Accepts(TStreamInfo.From('.xlsm', '')),     'Accepts .xlsm');
    Check(not Conv.Accepts(TStreamInfo.From('.xls', '')),  'Rejects .xls');

    XlsxPath := FixturePath('sample.xlsx');
    CreateXlsxFixture(XlsxPath);
    try
      var R := ConvFile(XlsxPath);
      Check(R.Success,                          'sample.xlsx: success');
      Check(R.Markdown.Contains('## Products'), 'sample.xlsx: sheet heading');
      Check(R.Markdown.Contains('Product'),     'sample.xlsx: header Product');
      Check(R.Markdown.Contains('Price'),       'sample.xlsx: header Price');
      Check(R.Markdown.Contains('Widget'),      'sample.xlsx: row Widget');
      Check(R.Markdown.Contains('9.99'),        'sample.xlsx: row price');
      Check(R.Markdown.Contains('Gadget'),      'sample.xlsx: row Gadget');
      Check(R.Markdown.Contains('---'),         'sample.xlsx: table separator');
    finally
      TFile.Delete(XlsxPath);
    end;
  finally
    Conv.Free;
  end;
end;

// ==========================================================================
// TPPTXConverter
// ==========================================================================

procedure TestPPTXConverter;
var
  Conv    : TPPTXConverter;
  PptxPath: string;

  function ConvFile(const APath: string): TConversionResult;
  var FS: TFileStream;
  begin
    FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
    try Result := Conv.Convert(FS, TStreamInfo.FromFile(APath));
    finally FS.Free; end;
  end;

begin
  Section('TPPTXConverter');
  Conv := TPPTXConverter.Create;
  try
    Check(Conv.Accepts(TStreamInfo.From('.pptx', '')),     'Accepts .pptx');
    Check(Conv.Accepts(TStreamInfo.From('.ppsx', '')),     'Accepts .ppsx');
    Check(not Conv.Accepts(TStreamInfo.From('.ppt', '')),  'Rejects .ppt');

    PptxPath := FixturePath('sample.pptx');
    CreatePptxFixture(PptxPath);
    try
      var R := ConvFile(PptxPath);
      Check(R.Success,                               'sample.pptx: success');
      Check(R.Markdown.Contains('## Slide 1'),       'sample.pptx: slide 1 heading');
      Check(R.Markdown.Contains('Slide One Title'),  'sample.pptx: slide 1 title text');
      Check(R.Markdown.Contains('First bullet'),     'sample.pptx: slide 1 bullet');
      Check(R.Markdown.Contains('---'),              'sample.pptx: slide separator');
      Check(R.Markdown.Contains('## Slide 2'),       'sample.pptx: slide 2 heading');
      Check(R.Markdown.Contains('Slide Two Content'),'sample.pptx: slide 2 text');
    finally
      TFile.Delete(PptxPath);
    end;
  finally
    Conv.Free;
  end;
end;

// ==========================================================================
// PDF fixture builder (uses TPDFBuilder from the pdf/ library)
// ==========================================================================

procedure CreatePdfFixture(const APath: string);
var
  Builder: TPDFBuilder;
  Page   : TPDFDictionary;
  CB     : TPDFContentBuilder;
  Stm    : TPDFStream;
begin
  Builder := TPDFBuilder.Create;
  try
    Builder.SetTitle('Extract Test PDF');
    Page := Builder.AddPage(612, 792);
    Builder.AddStandardFont(Page, 'F1', 'Helvetica');
    CB := TPDFContentBuilder.Create;
    try
      CB.BeginText;
      CB.SetFont('F1', 14);
      CB.SetTextMatrix(1, 0, 0, 1, 50, 700);
      CB.ShowText('Hello PDF');
      CB.MoveTextPos(0, -20);
      CB.ShowText('This is a test document for PDF extraction.');
      CB.EndText;
      Stm := TPDFStream.Create;
      Stm.SetRawData(CB.Build);
      Page.SetValue('Contents', Stm);
    finally
      CB.Free;
    end;
    Builder.SaveToFile(APath);
  finally
    Builder.Free;
  end;
end;

// ==========================================================================
// EPUB fixture builder
// ==========================================================================

procedure CreateEpubFixture(const APath: string);
const
  CONT =
    '<?xml version="1.0" encoding="UTF-8"?>' +
    '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">' +
    '<rootfiles>' +
    '<rootfile full-path="OEBPS/content.opf"' +
    ' media-type="application/oebps-package+xml"/>' +
    '</rootfiles>' +
    '</container>';
  OPF =
    '<?xml version="1.0" encoding="UTF-8"?>' +
    '<package xmlns="http://www.idpf.org/2007/opf" version="2.0">' +
    '<manifest>' +
    '<item id="ch1" href="chapter1.html" media-type="application/xhtml+xml"/>' +
    '<item id="ch2" href="chapter2.html" media-type="application/xhtml+xml"/>' +
    '</manifest>' +
    '<spine>' +
    '<itemref idref="ch1"/>' +
    '<itemref idref="ch2"/>' +
    '</spine>' +
    '</package>';
  CH1 =
    '<?xml version="1.0" encoding="UTF-8"?>' +
    '<html xmlns="http://www.w3.org/1999/xhtml">' +
    '<head><title>Chapter 1</title></head>' +
    '<body>' +
    '<h1>Introduction</h1>' +
    '<p>This is the first chapter of the book.</p>' +
    '</body>' +
    '</html>';
  CH2 =
    '<?xml version="1.0" encoding="UTF-8"?>' +
    '<html xmlns="http://www.w3.org/1999/xhtml">' +
    '<head><title>Chapter 2</title></head>' +
    '<body>' +
    '<h2>The Story Continues</h2>' +
    '<p>Second chapter content here.</p>' +
    '</body>' +
    '</html>';
var
  Zip: TZipFile;
begin
  Zip := TZipFile.Create;
  try
    Zip.Open(APath, zmWrite);
    AddZipEntry(Zip, 'META-INF/container.xml', CONT);
    AddZipEntry(Zip, 'OEBPS/content.opf',      OPF);
    AddZipEntry(Zip, 'OEBPS/chapter1.html',    CH1);
    AddZipEntry(Zip, 'OEBPS/chapter2.html',    CH2);
  finally
    Zip.Free;
  end;
end;

// ==========================================================================
// TPDFExtractConverter
// ==========================================================================

procedure TestPDFConverter;
var
  Conv   : TPDFExtractConverter;
  PdfPath: string;

  function ConvFile(const APath: string): TConversionResult;
  var FS: TFileStream;
  begin
    FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
    try Result := Conv.Convert(FS, TStreamInfo.FromFile(APath));
    finally FS.Free; end;
  end;

begin
  Section('TPDFExtractConverter');
  Conv := TPDFExtractConverter.Create;
  try
    Check(Conv.Accepts(TStreamInfo.From('.pdf', '')),     'Accepts .pdf');
    Check(not Conv.Accepts(TStreamInfo.From('.docx', '')), 'Rejects .docx');

    var MS := TMemoryStream.Create;
    try
      var R := Conv.Convert(MS, TStreamInfo.From('.pdf', ''));
      Check(not R.Success, 'empty stream: failure');
    finally
      MS.Free;
    end;

    PdfPath := FixturePath('sample.pdf');
    try
      CreatePdfFixture(PdfPath);
      var R2 := ConvFile(PdfPath);
      Check(R2.Success,                           'sample.pdf: success');
      Check(R2.Title = 'Extract Test PDF',        'sample.pdf: title extracted');
      Check(R2.Markdown.Contains('Hello PDF'),    'sample.pdf: text Hello PDF');
      Check(R2.Markdown.Contains('extraction'),   'sample.pdf: text extraction');
    finally
      TFile.Delete(PdfPath);
    end;
  finally
    Conv.Free;
  end;
end;

// ==========================================================================
// TEPUBConverter
// ==========================================================================

procedure TestEPUBConverter;
var
  Conv    : TEPUBConverter;
  EpubPath: string;

  function ConvFile(const APath: string): TConversionResult;
  var FS: TFileStream;
  begin
    FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
    try Result := Conv.Convert(FS, TStreamInfo.FromFile(APath));
    finally FS.Free; end;
  end;

begin
  Section('TEPUBConverter');
  Conv := TEPUBConverter.Create;
  try
    Check(Conv.Accepts(TStreamInfo.From('.epub', '')),     'Accepts .epub');
    Check(not Conv.Accepts(TStreamInfo.From('.pdf', '')),  'Rejects .pdf');

    var MS := TMemoryStream.Create;
    try
      var R := Conv.Convert(MS, TStreamInfo.From('.epub', ''));
      Check(not R.Success, 'empty stream: failure');
    finally
      MS.Free;
    end;

    EpubPath := FixturePath('sample.epub');
    CreateEpubFixture(EpubPath);
    try
      var R2 := ConvFile(EpubPath);
      Check(R2.Success,                               'sample.epub: success');
      Check(R2.Markdown.Contains('## Chapter 1'),     'sample.epub: chapter 1 heading');
      Check(R2.Markdown.Contains('Introduction'),     'sample.epub: ch1 h1 text');
      Check(R2.Markdown.Contains('first chapter'),    'sample.epub: ch1 body text');
      Check(R2.Markdown.Contains('---'),              'sample.epub: chapter separator');
      Check(R2.Markdown.Contains('## Chapter 2'),     'sample.epub: chapter 2 heading');
      Check(R2.Markdown.Contains('Story Continues'),  'sample.epub: ch2 text');
      Check(R2.Markdown.Contains('Second chapter'),   'sample.epub: ch2 body text');
    finally
      TFile.Delete(EpubPath);
    end;
  finally
    Conv.Free;
  end;
end;

// ==========================================================================
// Engine integration — Fase 2
// ==========================================================================

procedure TestEnginePhase2;
var
  MD: TMarkItDown;
begin
  Section('TMarkItDown engine — Fase 2 formats');
  MD := TMarkItDown.Create;
  try
    Check(MD.ConvertFile(FixturePath('sample.ini')).Success, 'Engine routes .ini');
    Check(MD.ConvertFile(FixturePath('sample.rtf')).Success, 'Engine routes .rtf');
    Check(MD.ConvertFile(FixturePath('sample.html')).Success,'Engine routes .html');
  finally
    MD.Free;
  end;
end;

// ==========================================================================
// Engine integration — Fase 3
// ==========================================================================

procedure TestEnginePhase3;
var
  MD       : TMarkItDown;
  DocxPath : string;
  XlsxPath : string;
  PptxPath : string;
begin
  Section('TMarkItDown engine — Fase 3 formats');
  MD := TMarkItDown.Create;
  try
    DocxPath := FixturePath('eng3_test.docx');
    XlsxPath := FixturePath('eng3_test.xlsx');
    PptxPath := FixturePath('eng3_test.pptx');
    CreateDocxFixture(DocxPath);
    CreateXlsxFixture(XlsxPath);
    CreatePptxFixture(PptxPath);
    try
      Check(MD.ConvertFile(DocxPath).Success, 'Engine routes .docx');
      Check(MD.ConvertFile(XlsxPath).Success, 'Engine routes .xlsx');
      Check(MD.ConvertFile(PptxPath).Success, 'Engine routes .pptx');
    finally
      TFile.Delete(DocxPath);
      TFile.Delete(XlsxPath);
      TFile.Delete(PptxPath);
    end;
  finally
    MD.Free;
  end;
end;

// ==========================================================================
// Engine integration — Fase 4
// ==========================================================================

procedure TestEnginePhase4;
var
  MD      : TMarkItDown;
  PdfPath : string;
  EpubPath: string;
begin
  Section('TMarkItDown engine — Fase 4 formats');
  MD := TMarkItDown.Create;
  try
    PdfPath  := FixturePath('eng4_test.pdf');
    EpubPath := FixturePath('eng4_test.epub');
    CreatePdfFixture(PdfPath);
    CreateEpubFixture(EpubPath);
    try
      Check(MD.ConvertFile(PdfPath).Success,  'Engine routes .pdf');
      Check(MD.ConvertFile(EpubPath).Success, 'Engine routes .epub');
    finally
      TFile.Delete(PdfPath);
      TFile.Delete(EpubPath);
    end;
  finally
    MD.Free;
  end;
end;

// ==========================================================================
// Main
// ==========================================================================

begin
  WriteLn('=== Extract library — Fase 1 + Fase 2 + Fase 3 + Fase 4 tests ===');
  try
    TestResult;
    TestStreamInfo;
    TestTextConverter;
    TestMarkdownConverter;
    TestCSVConverter;
    TestJSONConverter;
    TestXMLConverter;
    TestEngine;
    TestINIConverter;
    TestRTFConverter;
    TestHTMLConverter;
    TestEnginePhase2;
    TestDOCXConverter;
    TestXLSXConverter;
    TestPPTXConverter;
    TestEnginePhase3;
    TestPDFConverter;
    TestEPUBConverter;
    TestEnginePhase4;
  except
    on E: Exception do
      WriteLn('UNHANDLED EXCEPTION: ', E.Message);
  end;

  WriteLn;
  WriteLn('=== Results: ', PassCount, ' passed  /  ', FailCount, ' failed ===');
  if FailCount > 0 then ExitCode := 1;
end.
