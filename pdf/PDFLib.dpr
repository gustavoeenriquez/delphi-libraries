library PDFLib;

{$R *.res}

uses
  uPDF.Types           in 'Src\Core\uPDF.Types.pas',
  uPDF.Errors          in 'Src\Core\uPDF.Errors.pas',
  uPDF.Objects         in 'Src\Core\uPDF.Objects.pas',
  uPDF.Lexer           in 'Src\Core\uPDF.Lexer.pas',
  uPDF.Filters         in 'Src\Core\uPDF.Filters.pas',
  uPDF.XRef            in 'Src\Core\uPDF.XRef.pas',
  uPDF.Crypto          in 'Src\Core\uPDF.Crypto.pas',
  uPDF.Encryption      in 'Src\Core\uPDF.Encryption.pas',
  uPDF.Parser          in 'Src\Core\uPDF.Parser.pas',
  uPDF.Document        in 'Src\Core\uPDF.Document.pas',
  uPDF.GraphicsState   in 'Src\Core\uPDF.GraphicsState.pas',
  uPDF.ColorSpace      in 'Src\Core\uPDF.ColorSpace.pas',
  uPDF.FontCMap        in 'Src\Core\uPDF.FontCMap.pas',
  uPDF.Font            in 'Src\Core\uPDF.Font.pas',
  uPDF.ContentStream   in 'Src\Core\uPDF.ContentStream.pas',
  uPDF.Image           in 'Src\Core\uPDF.Image.pas',
  uPDF.TextExtractor   in 'Src\Core\uPDF.TextExtractor.pas',
  uPDF.ImageExtractor  in 'Src\Core\uPDF.ImageExtractor.pas',
  uPDF.Writer          in 'Src\Core\uPDF.Writer.pas',
  uPDF.Render.Types    in 'Src\Render\uPDF.Render.Types.pas',
  uPDF.Render.FontCache in 'Src\Render\uPDF.Render.FontCache.pas',
  uPDF.Render.Skia     in 'Src\Render\uPDF.Render.Skia.pas',
  uPDF.Outline         in 'Src\Core\uPDF.Outline.pas',
  uPDF.Annotations     in 'Src\Core\uPDF.Annotations.pas',
  uPDF.Metadata        in 'Src\Core\uPDF.Metadata.pas',
  uPDF.AcroForms       in 'Src\Core\uPDF.AcroForms.pas',
  uPDF.AcroForms.Fill  in 'Src\Core\uPDF.AcroForms.Fill.pas',
  uPDF.ScanDetector    in 'Src\Core\uPDF.ScanDetector.pas',
  uPDF.PageOperations  in 'Src\Core\uPDF.PageOperations.pas',
  uPDF.PageCopy        in 'Src\Core\uPDF.PageCopy.pas',
  uPDF.TextSearch      in 'Src\Core\uPDF.TextSearch.pas',
  uPDF.Watermark       in 'Src\Core\uPDF.Watermark.pas',
  uPDF.TOC             in 'Src\Core\uPDF.TOC.pas',
  uPDF.Signatures         in 'Src\Core\uPDF.Signatures.pas',
  uPDF.IncrementalUpdate  in 'Src\Core\uPDF.IncrementalUpdate.pas',
  uPDF.TTFParser          in 'Src\Core\uPDF.TTFParser.pas',
  uPDF.TTFSubset          in 'Src\Core\uPDF.TTFSubset.pas',
  uPDF.EmbeddedFont       in 'Src\Core\uPDF.EmbeddedFont.pas';

begin
end.
