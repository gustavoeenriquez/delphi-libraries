$enc = New-Object System.Text.UTF8Encoding $true
$files = @(
  'E:\copilot\pdf\FMXViewer\PDFViewerApp.dpr',
  'E:\copilot\pdf\FMXViewer\frmViewer.pas',
  'E:\copilot\pdf\Src\Render\uPDF.Render.Types.pas',
  'E:\copilot\pdf\Src\Render\uPDF.Render.FontCache.pas',
  'E:\copilot\pdf\Src\Render\uPDF.Render.Skia.pas',
  'E:\copilot\pdf\Src\FMX\uPDF.Viewer.Cache.pas',
  'E:\copilot\pdf\Src\FMX\uPDF.Viewer.Control.pas'
)
foreach ($path in $files) {
  $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
  [System.IO.File]::WriteAllText($path, $content, $enc)
  $bytes = [System.IO.File]::ReadAllBytes($path)
  Write-Host ('BOM OK: {0}  [{1:X2} {2:X2} {3:X2}]' -f (Split-Path $path -Leaf), $bytes[0], $bytes[1], $bytes[2])
}
