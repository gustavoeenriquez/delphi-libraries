program PDFViewerApp;

uses
  System.StartUpCopy,
  FMX.Forms,
  frmViewer in 'frmViewer.pas' {ViewerForm};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TViewerForm, ViewerForm);
  Application.Run;
end.
