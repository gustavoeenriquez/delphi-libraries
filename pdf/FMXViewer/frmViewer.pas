unit frmViewer;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Dialogs, FMX.Layouts,
  FMX.StdCtrls, FMX.Edit, FMX.Objects, FMX.Menus,
  FMX.Controls.Presentation,
  uPDF.Document,
  uPDF.Viewer.Control;

type
  TViewerForm = class(TForm)
  private
    // ---- Layout ----
    FMainLayout:    TLayout;
    FToolBar:       TToolBar;
    FStatusBar:     TStatusBar;

    // ---- Toolbar controls ----
    FBtnOpen:       TButton;
    FBtnFitPage:    TButton;
    FBtnFitWidth:   TButton;
    FBtnZoomIn:     TButton;
    FBtnZoomOut:    TButton;
    FBtnPrev:       TButton;
    FBtnNext:       TButton;
    FLblPage:       TLabel;
    FLblZoom:       TLabel;

    // ---- Viewer ----
    FViewer:        TPDFViewerControl;

    // ---- Document ----
    FDocument:      TPDFDocument;
    FCurrentPath:   string;

    // ---- Event handlers ----
    procedure OnBtnOpenClick(Sender: TObject);
    procedure OnBtnFitPageClick(Sender: TObject);
    procedure OnBtnFitWidthClick(Sender: TObject);
    procedure OnBtnZoomInClick(Sender: TObject);
    procedure OnBtnZoomOutClick(Sender: TObject);
    procedure OnBtnPrevClick(Sender: TObject);
    procedure OnBtnNextClick(Sender: TObject);
    procedure OnViewerPageChanged(Sender: TObject);
    procedure OnViewerZoomChanged(Sender: TObject);

    procedure OpenPDF(const APath: string; const APassword: string = '');
    procedure UpdateStatusBar;
    procedure BuildUI;

  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
  end;

var
  ViewerForm: TViewerForm;

implementation

{$R *.fmx}

uses
  System.Math;

// =========================================================================
// Constructor / destructor
// =========================================================================

constructor TViewerForm.Create(AOwner: TComponent);
begin
  inherited;
  BuildUI;

  Caption := 'PDF Viewer';
  Width   := 900;
  Height  := 700;
end;

destructor TViewerForm.Destroy;
begin
  FDocument.Free;
  inherited;
end;

// =========================================================================
// UI construction (done in code so no .fmx dependency)
// =========================================================================

procedure TViewerForm.BuildUI;

  function MakeButton(const AText: string; AParent: TFmxObject;
    AHandler: TNotifyEvent): TButton;
  begin
    Result         := TButton.Create(Self);
    Result.Parent  := AParent;
    Result.Text    := AText;
    Result.Width   := 80;
    Result.Align   := TAlignLayout.Left;
    Result.OnClick := AHandler;
  end;

begin
  // ---- Toolbar ----
  FToolBar        := TToolBar.Create(Self);
  FToolBar.Parent := Self;
  FToolBar.Align  := TAlignLayout.Top;
  FToolBar.Height := 44;

  FBtnOpen     := MakeButton('Open',      FToolBar, OnBtnOpenClick);
  FBtnFitWidth := MakeButton('Fit Width', FToolBar, OnBtnFitWidthClick);
  FBtnFitPage  := MakeButton('Fit Page',  FToolBar, OnBtnFitPageClick);
  FBtnZoomOut  := MakeButton('–',         FToolBar, OnBtnZoomOutClick);
  FBtnZoomIn   := MakeButton('+',         FToolBar, OnBtnZoomInClick);

  FLblZoom         := TLabel.Create(Self);
  FLblZoom.Parent  := FToolBar;
  FLblZoom.Text    := '100%';
  FLblZoom.Width   := 60;
  FLblZoom.Align   := TAlignLayout.Left;
  FLblZoom.TextSettings.HorzAlign := TTextAlign.Center;

  FBtnPrev := MakeButton('◀', FToolBar, OnBtnPrevClick);
  FBtnNext := MakeButton('▶', FToolBar, OnBtnNextClick);

  FLblPage         := TLabel.Create(Self);
  FLblPage.Parent  := FToolBar;
  FLblPage.Text    := '';
  FLblPage.Width   := 120;
  FLblPage.Align   := TAlignLayout.Left;
  FLblPage.TextSettings.HorzAlign := TTextAlign.Center;

  // ---- Status bar ----
  FStatusBar        := TStatusBar.Create(Self);
  FStatusBar.Parent := Self;
  FStatusBar.Align  := TAlignLayout.Bottom;
  FStatusBar.Height := 24;

  // ---- Main layout ----
  FMainLayout        := TLayout.Create(Self);
  FMainLayout.Parent := Self;
  FMainLayout.Align  := TAlignLayout.Client;

  // ---- Viewer ----
  FViewer              := TPDFViewerControl.Create(Self);
  FViewer.Parent       := FMainLayout;
  FViewer.Align        := TAlignLayout.Client;
  FViewer.OnPageChanged := OnViewerPageChanged;
  FViewer.OnZoomChanged := OnViewerZoomChanged;
end;

// =========================================================================
// Open / load
// =========================================================================

procedure TViewerForm.OpenPDF(const APath: string; const APassword: string);
var
  NewDoc: TPDFDocument;
begin
  NewDoc := TPDFDocument.Create;
  try
    NewDoc.LoadFromFile(APath);

    if NewDoc.IsEncrypted then
    begin
      var Pwd := APassword;
      if Pwd = '' then
      begin
        // Prompt for password
        if InputQuery('Password Required',
                      'Enter the PDF password:', Pwd) then
          NewDoc.Authenticate(Pwd)
        else
        begin
          NewDoc.Free;
          Exit;
        end;
      end
      else
        NewDoc.Authenticate(Pwd);
    end;
  except
    on E: Exception do
    begin
      NewDoc.Free;
      ShowMessage('Failed to open PDF:' + sLineBreak + E.Message);
      Exit;
    end;
  end;

  // Replace document
  FViewer.Document := nil;
  FDocument.Free;
  FDocument     := NewDoc;
  FCurrentPath  := APath;
  Caption       := 'PDF Viewer — ' + ExtractFileName(APath);

  FViewer.Document := FDocument;
  FViewer.ZoomToWidth;
  UpdateStatusBar;
end;

procedure TViewerForm.UpdateStatusBar;
begin
  // Update page label
  if (FDocument <> nil) and (FDocument.PageCount > 0) then
    FLblPage.Text := Format('Page %d / %d',
      [FViewer.CurrentPage + 1, FDocument.PageCount])
  else
    FLblPage.Text := '';

  // Update zoom label
  FLblZoom.Text := Format('%.0f%%', [FViewer.Zoom * 100]);
end;

// =========================================================================
// Event handlers
// =========================================================================

procedure TViewerForm.OnBtnOpenClick(Sender: TObject);
var
  OD: TOpenDialog;
begin
  OD := TOpenDialog.Create(Self);
  try
    OD.Title  := 'Open PDF';
    OD.Filter := 'PDF Files (*.pdf)|*.pdf|All Files (*.*)|*.*';
    OD.FilterIndex := 1;
    if OD.Execute then
      OpenPDF(OD.FileName);
  finally
    OD.Free;
  end;
end;

procedure TViewerForm.OnBtnFitPageClick(Sender: TObject);
begin
  FViewer.ZoomToFit;
end;

procedure TViewerForm.OnBtnFitWidthClick(Sender: TObject);
begin
  FViewer.ZoomToWidth;
end;

procedure TViewerForm.OnBtnZoomInClick(Sender: TObject);
begin
  FViewer.Zoom := FViewer.Zoom * 1.2;
end;

procedure TViewerForm.OnBtnZoomOutClick(Sender: TObject);
begin
  FViewer.Zoom := FViewer.Zoom / 1.2;
end;

procedure TViewerForm.OnBtnPrevClick(Sender: TObject);
begin
  FViewer.PrevPage;
end;

procedure TViewerForm.OnBtnNextClick(Sender: TObject);
begin
  FViewer.NextPage;
end;

procedure TViewerForm.OnViewerPageChanged(Sender: TObject);
begin
  UpdateStatusBar;
end;

procedure TViewerForm.OnViewerZoomChanged(Sender: TObject);
begin
  UpdateStatusBar;
end;

end.
