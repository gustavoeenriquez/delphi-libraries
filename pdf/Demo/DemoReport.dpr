program DemoReport;
{
  PDF Report demo with bands, pie chart and bar chart.
  Page 1: report header bands + data table + KPI cards
  Page 2: pie chart (Q2 distribution) + bar chart (Q1 vs Q2)
}
{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}
{$R *.res}

uses
  System.SysUtils, System.Classes, System.Math,
  uPDF.Types          in '..\Src\Core\uPDF.Types.pas',
  uPDF.Errors         in '..\Src\Core\uPDF.Errors.pas',
  uPDF.Objects        in '..\Src\Core\uPDF.Objects.pas',
  uPDF.Lexer          in '..\Src\Core\uPDF.Lexer.pas',
  uPDF.Filters        in '..\Src\Core\uPDF.Filters.pas',
  uPDF.XRef           in '..\Src\Core\uPDF.XRef.pas',
  uPDF.Crypto         in '..\Src\Core\uPDF.Crypto.pas',
  uPDF.Encryption     in '..\Src\Core\uPDF.Encryption.pas',
  uPDF.Parser         in '..\Src\Core\uPDF.Parser.pas',
  uPDF.Document       in '..\Src\Core\uPDF.Document.pas',
  uPDF.GraphicsState  in '..\Src\Core\uPDF.GraphicsState.pas',
  uPDF.ColorSpace     in '..\Src\Core\uPDF.ColorSpace.pas',
  uPDF.FontCMap       in '..\Src\Core\uPDF.FontCMap.pas',
  uPDF.Font           in '..\Src\Core\uPDF.Font.pas',
  uPDF.ContentStream  in '..\Src\Core\uPDF.ContentStream.pas',
  uPDF.Image          in '..\Src\Core\uPDF.Image.pas',
  uPDF.TextExtractor  in '..\Src\Core\uPDF.TextExtractor.pas',
  uPDF.ImageExtractor in '..\Src\Core\uPDF.ImageExtractor.pas',
  uPDF.Writer         in '..\Src\Core\uPDF.Writer.pas',
  uPDF.Outline        in '..\Src\Core\uPDF.Outline.pas',
  uPDF.Annotations    in '..\Src\Core\uPDF.Annotations.pas',
  uPDF.Metadata       in '..\Src\Core\uPDF.Metadata.pas',
  uPDF.AcroForms      in '..\Src\Core\uPDF.AcroForms.pas';

// =============================================================================
// Report data
// =============================================================================

const
  NREG = 5;
  REG_NAME : array[0..NREG-1] of string  = ('Norte','Sur','Este','Oeste','Centro');
  REG_Q1   : array[0..NREG-1] of Integer = (45200, 32800, 28500, 18900, 12600);
  REG_Q2   : array[0..NREG-1] of Integer = (52300, 31500, 34200, 21400, 15800);

function Q1Total: Integer;
var I: Integer;
begin Result := 0; for I := 0 to NREG-1 do Inc(Result, REG_Q1[I]); end;

function Q2Total: Integer;
var I: Integer;
begin Result := 0; for I := 0 to NREG-1 do Inc(Result, REG_Q2[I]); end;

function FmtMoney(V: Integer): string;
begin
  // Insert thousands separators
  var S := IntToStr(Abs(V));
  var R := '';
  for var I := 1 to Length(S) do
  begin
    if (I > 1) and ((Length(S) - I + 1) mod 3 = 0) then R := R + ',';
    R := R + S[I];
  end;
  if V < 0 then Result := '-$' + R else Result := '$' + R;
end;

function FmtPct(V: Double): string;
begin
  if V >= 0 then Result := Format('+%.1f%%', [V])
  else            Result := Format('%.1f%%',  [V]);
end;

function GrowthPct(I: Integer): Double;
begin
  Result := (REG_Q2[I] - REG_Q1[I]) * 100.0 / REG_Q1[I];
end;

// =============================================================================
// Font / stream helpers
// =============================================================================

procedure AddFonts(APage: TPDFDictionary);
  procedure F(const Res, Base: string);
  var ResD, FntD, FD: TPDFDictionary;
  begin
    ResD := APage.GetAsDictionary('Resources');
    if ResD = nil then begin ResD := TPDFDictionary.Create; APage.SetValue('Resources', ResD); end;
    FntD := ResD.GetAsDictionary('Font');
    if FntD = nil then begin FntD := TPDFDictionary.Create; ResD.SetValue('Font', FntD); end;
    FD := TPDFDictionary.Create;
    FD.SetValue('Type',     TPDFName.Create('Font'));
    FD.SetValue('Subtype',  TPDFName.Create('Type1'));
    FD.SetValue('BaseFont', TPDFName.Create(Base));
    FD.SetValue('Encoding', TPDFName.Create('WinAnsiEncoding'));
    FntD.SetValue(Res, FD);
  end;
begin
  F('Reg',  'Helvetica');
  F('Bold', 'Helvetica-Bold');
  F('Ital', 'Helvetica-Oblique');
  F('Mono', 'Courier');
end;

procedure Attach(APage: TPDFDictionary; CB: TPDFContentBuilder);
var Stm: TPDFStream;
begin
  Stm := TPDFStream.Create;
  Stm.SetRawData(CB.Build);
  APage.SetValue('Contents', Stm);
end;

// =============================================================================
// Colors
// =============================================================================

procedure RegColor(I: Integer; out R, G, B: Single);
begin
  case I of
    0: begin R:=0.20; G:=0.45; B:=0.75; end;  // Blue
    1: begin R:=0.87; G:=0.30; B:=0.10; end;  // Red
    2: begin R:=0.13; G:=0.62; B:=0.20; end;  // Green
    3: begin R:=0.57; G:=0.38; B:=0.74; end;  // Purple
    4: begin R:=0.92; G:=0.60; B:=0.00; end;  // Amber
    else begin R:=0.5; G:=0.5; B:=0.5; end;
  end;
end;

// Lighter version of region color for Q1 bars
procedure RegColorLight(I: Integer; out R, G, B: Single);
begin
  RegColor(I, R, G, B);
  R := R * 0.55 + 0.45;
  G := G * 0.55 + 0.45;
  B := B * 0.55 + 0.45;
end;

// =============================================================================
// Bezier arc helper
// =============================================================================

procedure ArcBezier(CB: TPDFContentBuilder; cx, cy, r, a0, a1: Single);
var
  n, I: Integer;
  span, step, k, a, na: Single;
begin
  span := a1 - a0;
  if Abs(span) < 1e-6 then Exit;
  n := Max(1, Ceil(Abs(span) / (Pi / 2)));
  step := span / n;
  a := a0;
  for I := 1 to n do
  begin
    na := a + step;
    k  := (4.0 / 3.0) * Tan(step / 2);
    CB.CurveTo(
      cx + r * (Cos(a)  - k * Sin(a)),   cy + r * (Sin(a)  + k * Cos(a)),
      cx + r * (Cos(na) + k * Sin(na)),  cy + r * (Sin(na) - k * Cos(na)),
      cx + r *  Cos(na),                  cy + r *  Sin(na));
    a := na;
  end;
end;

// =============================================================================
// Pie chart primitives
// =============================================================================

procedure PieSlice(CB: TPDFContentBuilder;
  cx, cy, r, aStart, aEnd, cr, cg, cb_: Single);
begin
  CB.SaveState;
  CB.SetFillRGB(cr, cg, cb_);
  CB.SetStrokeRGB(1, 1, 1);
  CB.SetLineWidth(1.5);
  CB.MoveTo(cx, cy);
  CB.LineTo(cx + r * Cos(aStart), cy + r * Sin(aStart));
  ArcBezier(CB, cx, cy, r, aStart, aEnd);
  CB.ClosePath;
  CB.FillAndStroke;
  CB.RestoreState;
end;

procedure PieLabel(CB: TPDFContentBuilder;
  cx, cy, r, aStart, aEnd: Single; const ATxt: string);
var
  aMid, lx, ly: Single;
begin
  aMid := (aStart + aEnd) * 0.5;
  lx := cx + r * 0.62 * Cos(aMid) - 8;
  ly := cy + r * 0.62 * Sin(aMid) - 4;
  CB.SaveState;
  CB.SetFillRGB(1, 1, 1);
  CB.BeginText;
  CB.SetFont('Bold', 8);
  CB.SetTextMatrix(1, 0, 0, 1, lx, ly);
  CB.ShowText(ATxt);
  CB.EndText;
  CB.RestoreState;
end;

procedure DrawPieChart(CB: TPDFContentBuilder; cx, cy, r: Single);
var
  Total, a0, a1, pct, cr, cg, cb_: Single;
  I: Integer;
  LegX, LegY: Single;
begin
  // Total
  Total := Q2Total;

  // Slices (clockwise from top = PI/2, so angle decreases)
  a0 := Pi / 2;
  for I := 0 to NREG - 1 do
  begin
    pct := REG_Q2[I] / Total;
    a1  := a0 - pct * 2 * Pi;
    RegColor(I, cr, cg, cb_);
    PieSlice(CB, cx, cy, r, a1, a0, cr, cg, cb_);
    if pct >= 0.07 then
      PieLabel(CB, cx, cy, r, a1, a0, Format('%.1f%%', [pct * 100]));
    a0 := a1;
  end;

  // Legend (2 columns, below pie)
  LegY := cy - r - 28;
  for I := 0 to NREG - 1 do
  begin
    RegColor(I, cr, cg, cb_);
    LegX := cx - 90 + (I mod 2) * 100;
    LegY := (cy - r - 28) - (I div 2) * 16;
    CB.SaveState;
    CB.SetFillRGB(cr, cg, cb_);
    CB.Rectangle(LegX, LegY + 1, 10, 10);
    CB.Fill;
    CB.RestoreState;
    CB.SaveState;
    CB.SetFillRGB(0.15, 0.15, 0.15);
    CB.BeginText;
    CB.SetFont('Reg', 8.5);
    CB.SetTextMatrix(1, 0, 0, 1, LegX + 13, LegY + 1);
    CB.ShowText(REG_NAME[I] + '  ' + FmtMoney(REG_Q2[I]));
    CB.EndText;
    CB.RestoreState;
  end;
end;

// =============================================================================
// Bar chart
// =============================================================================

procedure DrawBarChart(CB: TPDFContentBuilder;
  x0, y0, w, h: Single);
const
  MAX_Y    = 60000;
  TICK_INT = 10000;
  N_TICKS  = 7;      // 0, 10k, 20k, 30k, 40k, 50k, 60k
var
  LMargin, BMargin, TMargin, RMargin: Single;
  PX0, PY0, PW, PH: Single;   // plot area
  GrpW, BarW, Gap: Single;
  I, T: Integer;
  tx, ty, bx, by, bh: Single;
  cr, cg, cb_: Single;
  cr2, cg2, cb_2: Single;
begin
  LMargin := 50; BMargin := 36; TMargin := 12; RMargin := 8;
  PX0 := x0 + LMargin;
  PY0 := y0 + BMargin;
  PW  := w - LMargin - RMargin;
  PH  := h - BMargin - TMargin;

  // ---- Grid lines + Y axis labels ----
  CB.SaveState;
  CB.SetLineWidth(0.4);
  for T := 0 to N_TICKS - 1 do
  begin
    ty := PY0 + PH * T / (N_TICKS - 1);
    // Grid line
    CB.SetStrokeRGB(0.85, 0.85, 0.85);
    CB.SetDash([4, 3], 0);
    CB.MoveTo(PX0, ty);
    CB.LineTo(PX0 + PW, ty);
    CB.Stroke;
    // Y label
    CB.SetDash([], 0);
    CB.SetFillRGB(0.35, 0.35, 0.35);
    CB.BeginText;
    CB.SetFont('Reg', 7.5);
    var V := TICK_INT * T;
    var Lbl := IntToStr(V div 1000) + 'K';
    CB.SetTextMatrix(1, 0, 0, 1, PX0 - 8 - Length(Lbl) * 4.5, ty - 3);
    CB.ShowText(Lbl);
    CB.EndText;
  end;
  CB.RestoreState;

  // ---- Axis lines ----
  CB.SaveState;
  CB.SetStrokeRGB(0.3, 0.3, 0.3);
  CB.SetLineWidth(1.0);
  CB.MoveTo(PX0, PY0);
  CB.LineTo(PX0, PY0 + PH);
  CB.MoveTo(PX0, PY0);
  CB.LineTo(PX0 + PW, PY0);
  CB.Stroke;
  CB.RestoreState;

  // ---- Bars ----
  GrpW := PW / NREG;
  BarW := GrpW * 0.34;
  Gap  := GrpW * 0.04;

  for I := 0 to NREG - 1 do
  begin
    bx := PX0 + I * GrpW + (GrpW - 2 * BarW - Gap) / 2;

    RegColorLight(I, cr, cg, cb_);
    bh := PH * REG_Q1[I] / MAX_Y;
    by := PY0;
    CB.SaveState;
    CB.SetFillRGB(cr, cg, cb_);
    CB.SetStrokeRGB(cr * 0.7, cg * 0.7, cb_ * 0.7);
    CB.SetLineWidth(0.5);
    CB.Rectangle(bx, by, BarW, bh);
    CB.FillAndStroke;
    CB.RestoreState;

    RegColor(I, cr2, cg2, cb_2);
    bh := PH * REG_Q2[I] / MAX_Y;
    CB.SaveState;
    CB.SetFillRGB(cr2, cg2, cb_2);
    CB.SetStrokeRGB(cr2 * 0.7, cg2 * 0.7, cb_2 * 0.7);
    CB.SetLineWidth(0.5);
    CB.Rectangle(bx + BarW + Gap, by, BarW, bh);
    CB.FillAndStroke;
    CB.RestoreState;

    // X axis label
    CB.SaveState;
    CB.SetFillRGB(0.25, 0.25, 0.25);
    CB.BeginText;
    CB.SetFont('Reg', 8);
    tx := PX0 + I * GrpW + GrpW / 2 - 8;
    CB.SetTextMatrix(1, 0, 0, 1, tx, PY0 - 14);
    CB.ShowText(REG_NAME[I]);
    CB.EndText;
    CB.RestoreState;
  end;

  // ---- Legend ----
  CB.SaveState;
  var LX := PX0 + PW * 0.3;
  var LY := PY0 + PH + 4;
  // Q1 swatch
  CB.SetFillRGB(0.7, 0.75, 0.85);
  CB.Rectangle(LX, LY, 10, 8);
  CB.Fill;
  CB.SetFillRGB(0.2, 0.2, 0.2);
  CB.BeginText;
  CB.SetFont('Reg', 8);
  CB.SetTextMatrix(1, 0, 0, 1, LX + 13, LY);
  CB.ShowText('Q1');
  CB.EndText;
  // Q2 swatch
  CB.SetFillRGB(0.20, 0.45, 0.75);
  CB.Rectangle(LX + 40, LY, 10, 8);
  CB.Fill;
  CB.SetFillRGB(0.2, 0.2, 0.2);
  CB.BeginText;
  CB.SetFont('Reg', 8);
  CB.SetTextMatrix(1, 0, 0, 1, LX + 53, LY);
  CB.ShowText('Q2');
  CB.EndText;
  CB.RestoreState;
end;

// =============================================================================
// Page 1 helpers
// =============================================================================

// Horizontal rule
procedure HRule(CB: TPDFContentBuilder; y, x0, x1, lw: Single;
  r, g, b: Single);
begin
  CB.SaveState;
  CB.SetStrokeRGB(r, g, b);
  CB.SetLineWidth(lw);
  CB.MoveTo(x0, y); CB.LineTo(x1, y); CB.Stroke;
  CB.RestoreState;
end;

// Filled band
procedure Band(CB: TPDFContentBuilder; y, ht, x0, wd, r, g, b: Single);
begin
  CB.SaveState;
  CB.SetFillRGB(r, g, b);
  CB.Rectangle(x0, y, wd, ht);
  CB.Fill;
  CB.RestoreState;
end;

// Text at position (no state save — caller manages)
procedure Txt(CB: TPDFContentBuilder; x, y: Single;
  const Font: string; Sz: Single;
  r, g, b: Single; const S: string);
begin
  CB.SetFillRGB(r, g, b);
  CB.BeginText;
  CB.SetFont(Font, Sz);
  CB.SetTextMatrix(1, 0, 0, 1, x, y);
  CB.ShowText(S);
  CB.EndText;
end;

// Rounded rectangle (approximated with Bezier corners)
procedure RoundRect(CB: TPDFContentBuilder;
  x, y, w, h, rr: Single; fr, fg, fb: Single);
begin
  CB.SaveState;
  CB.SetFillRGB(fr, fg, fb);
  CB.MoveTo(x + rr, y);
  CB.LineTo(x + w - rr, y);
  ArcBezier(CB, x + w - rr, y + rr, rr, -Pi/2, 0);
  CB.LineTo(x + w, y + h - rr);
  ArcBezier(CB, x + w - rr, y + h - rr, rr, 0, Pi/2);
  CB.LineTo(x + rr, y + h);
  ArcBezier(CB, x + rr, y + h - rr, rr, Pi/2, Pi);
  CB.LineTo(x, y + rr);
  ArcBezier(CB, x + rr, y + rr, rr, Pi, 3*Pi/2);
  CB.ClosePath;
  CB.Fill;
  CB.RestoreState;
end;

// =============================================================================
// Page 1: report header + table + KPIs
// =============================================================================

procedure BuildPage1(Builder: TPDFBuilder);
const
  ColX:   array[0..4] of Single = (48, 175, 280, 375, 460);
  ColHdr: array[0..4] of string = ('Region', 'Q1 Sales', 'Q2 Sales', 'Change', 'Share Q2');
var
  CB: TPDFContentBuilder;
  Page: TPDFDictionary;
  Y: Single;
  I: Integer;
  cr, cg, cb_: Single;
  Q1T, Q2T: Integer;
  BestI, TopGrowthI: Integer;
begin
  Page := Builder.AddPage(595, 842);
  AddFonts(Page);
  CB := TPDFContentBuilder.Create;
  try
    // ---- Header band (dark navy) ----
    Band(CB, 798, 44, 40, 515, 0.13, 0.22, 0.40);

    // Company logo placeholder (white box + text)
    CB.SaveState;
    CB.SetFillRGB(0.95, 0.95, 0.95);
    CB.SetStrokeRGB(0.8, 0.8, 0.8);
    CB.SetLineWidth(0.5);
    CB.Rectangle(48, 803, 52, 32);
    CB.FillAndStroke;
    CB.RestoreState;
    Txt(CB, 52, 821, 'Bold', 8, 0.13, 0.22, 0.40, 'TC');
    Txt(CB, 52, 811, 'Reg',  6, 0.35, 0.35, 0.35, 'CORP');

    // Report title
    Txt(CB, 110, 827, 'Bold', 14, 1, 1, 1, 'Sales Performance Report');
    Txt(CB, 110, 811, 'Reg',  10, 0.75, 0.87, 1,  'Regional Overview  Q1 / Q2  2025');

    // Date tag (top-right)
    Txt(CB, 460, 827, 'Reg', 9, 0.60, 0.78, 0.95, '01 Apr 2025');
    Txt(CB, 460, 814, 'Reg', 8, 0.50, 0.68, 0.85, 'CONFIDENTIAL');

    // ---- Sub-header band (lighter blue) ----
    Band(CB, 771, 26, 40, 515, 0.86, 0.91, 0.97);
    Txt(CB, 48, 783, 'Bold', 9,  0.13, 0.22, 0.40, 'Region');
    Txt(CB, 48, 773, 'Reg',  8,  0.30, 0.30, 0.30, 'Report currency: USD  |  Scope: all regions  |  Prepared by: Sales Analytics');

    // ---- Column headers ----
    Band(CB, 746, 24, 40, 515, 0.23, 0.38, 0.57);
    for I := 0 to 4 do
      Txt(CB, ColX[I], 754, 'Bold', 9, 1, 1, 1, ColHdr[I]);

    HRule(CB, 746, 40, 555, 0.3, 0.23, 0.38, 0.57);

    // ---- Data rows ----
    Q2T := Q2Total;
    Y := 728;
    for I := 0 to NREG - 1 do
    begin
      // Row background (alternating)
      if Odd(I) then
        Band(CB, Y - 2, 20, 40, 515, 0.96, 0.97, 0.99)
      else
        Band(CB, Y - 2, 20, 40, 515, 1, 1, 1);

      // Color accent bar on left
      RegColor(I, cr, cg, cb_);
      CB.SaveState;
      CB.SetFillRGB(cr, cg, cb_);
      CB.Rectangle(40, Y - 2, 5, 20);
      CB.Fill;
      CB.RestoreState;

      var Gr := GrowthPct(I);
      var GrStr := FmtPct(Gr);
      var ShareStr := Format('%.1f%%', [REG_Q2[I] * 100.0 / Q2T]);

      Txt(CB, ColX[0] + 8, Y + 5, 'Bold', 9,  0.10, 0.15, 0.25, REG_NAME[I]);
      Txt(CB, ColX[1],     Y + 5, 'Reg',  9,  0.15, 0.15, 0.15, FmtMoney(REG_Q1[I]));
      Txt(CB, ColX[2],     Y + 5, 'Bold', 9,  0.10, 0.10, 0.10, FmtMoney(REG_Q2[I]));

      // Change column colored
      if Gr >= 0 then
        Txt(CB, ColX[3], Y + 5, 'Bold', 9, 0.06, 0.55, 0.18, GrStr)
      else
        Txt(CB, ColX[3], Y + 5, 'Bold', 9, 0.75, 0.10, 0.10, GrStr);

      Txt(CB, ColX[4], Y + 5, 'Reg', 9, 0.30, 0.30, 0.30, ShareStr);

      HRule(CB, Y - 2, 45, 555, 0.3, 0.88, 0.90, 0.93);
      Y := Y - 20;
    end;

    // ---- Totals row ----
    Q1T := Q1Total;
    Q2T := Q2Total;
    Band(CB, Y - 2, 22, 40, 515, 0.20, 0.32, 0.50);
    Txt(CB, ColX[0] + 8, Y + 7, 'Bold', 9, 1, 1, 1, 'TOTAL');
    Txt(CB, ColX[1],     Y + 7, 'Bold', 9, 1, 1, 1, FmtMoney(Q1T));
    Txt(CB, ColX[2],     Y + 7, 'Bold', 9, 1, 1, 1, FmtMoney(Q2T));
    var TotalGr := (Q2T - Q1T) * 100.0 / Q1T;
    Txt(CB, ColX[3], Y + 7, 'Bold', 9, 0.60, 0.90, 0.65, FmtPct(TotalGr));
    Txt(CB, ColX[4], Y + 7, 'Bold', 9, 1, 1, 1, '100%');
    HRule(CB, Y - 2, 40, 555, 1.0, 0.13, 0.22, 0.40);

    // ---- KPI cards ----
    Y := Y - 28;
    // Find best performer and highest growth
    BestI := 0; TopGrowthI := 0;
    for I := 1 to NREG - 1 do
    begin
      if REG_Q2[I] > REG_Q2[BestI] then BestI := I;
      if GrowthPct(I) > GrowthPct(TopGrowthI) then TopGrowthI := I;
    end;

    // Three KPI cards
    var KpiData: array[0..2] of record
      Title, Value, Sub: string;
      CR, CG, CB_: Single;
    end;
    KpiData[0].Title := 'Total Q2 Revenue';
    KpiData[0].Value := FmtMoney(Q2T);
    KpiData[0].Sub   := FmtPct(TotalGr) + ' vs Q1';
    KpiData[0].CR    := 0.13; KpiData[0].CG := 0.22; KpiData[0].CB_ := 0.40;

    KpiData[1].Title := 'Top Region (Q2)';
    KpiData[1].Value := REG_NAME[BestI];
    KpiData[1].Sub   := FmtMoney(REG_Q2[BestI]) + ' (' + FmtPct(GrowthPct(BestI)) + ')';
    RegColor(BestI, KpiData[1].CR, KpiData[1].CG, KpiData[1].CB_);

    KpiData[2].Title := 'Highest Growth';
    KpiData[2].Value := REG_NAME[TopGrowthI];
    KpiData[2].Sub   := FmtPct(GrowthPct(TopGrowthI)) + ' QoQ';
    RegColor(TopGrowthI, KpiData[2].CR, KpiData[2].CG, KpiData[2].CB_);

    var KW := 160.0;
    var KH := 70.0;
    var KSpacing := (515 - 3 * KW) / 4;
    for I := 0 to 2 do
    begin
      var KX := 40 + KSpacing + I * (KW + KSpacing);
      var KY := Y - KH;

      // Card shadow
      CB.SaveState;
      CB.SetFillRGB(0.88, 0.90, 0.93);
      CB.Rectangle(KX + 3, KY - 3, KW, KH);
      CB.Fill;
      CB.RestoreState;

      // Card body
      RoundRect(CB, KX, KY, KW, KH, 5, 1, 1, 1);

      // Top accent bar
      CB.SaveState;
      CB.SetFillRGB(KpiData[I].CR, KpiData[I].CG, KpiData[I].CB_);
      CB.Rectangle(KX, KY + KH - 5, KW, 5);
      CB.Fill;
      CB.RestoreState;

      // Texts
      Txt(CB, KX + 8, KY + KH - 20, 'Reg',  8,  0.45, 0.45, 0.45, KpiData[I].Title);
      Txt(CB, KX + 8, KY + KH - 40, 'Bold', 14, KpiData[I].CR, KpiData[I].CG, KpiData[I].CB_, KpiData[I].Value);
      Txt(CB, KX + 8, KY + 10,      'Reg',  8,  0.50, 0.50, 0.50, KpiData[I].Sub);
    end;

    Y := Y - KH - 18;

    // ---- Analysis notes box ----
    CB.SaveState;
    CB.SetFillRGB(0.97, 0.98, 0.99);
    CB.SetStrokeRGB(0.78, 0.85, 0.92);
    CB.SetLineWidth(0.8);
    CB.Rectangle(40, Y - 90, 515, 90);
    CB.FillAndStroke;
    CB.RestoreState;

    CB.SaveState;
    CB.SetFillRGB(0.13, 0.22, 0.40);
    CB.Rectangle(40, Y, 515, 5);
    CB.Fill;
    CB.RestoreState;

    Txt(CB, 50, Y - 16,  'Bold', 9,  0.13, 0.22, 0.40, 'Analysis Summary');
    Txt(CB, 50, Y - 32,  'Reg',  8.5, 0.20, 0.20, 0.20,
        'Q2 shows overall revenue growth of +12.5% driven by Norte and Este regions.');
    Txt(CB, 50, Y - 46,  'Reg',  8.5, 0.20, 0.20, 0.20,
        'Centro achieved the highest QoQ growth (+25.4%) despite its smaller base.');
    Txt(CB, 50, Y - 60,  'Reg',  8.5, 0.20, 0.20, 0.20,
        'Sur is the only region with negative growth (-4.0%) requiring attention.');
    Txt(CB, 50, Y - 74,  'Ital', 8,   0.40, 0.40, 0.40,
        'See Page 2 for visual breakdown (pie and bar charts).');

    // ---- Footer ----
    HRule(CB, 58, 40, 555, 0.5, 0.70, 0.75, 0.82);
    Txt(CB, 40,  46, 'Reg', 7.5, 0.50, 0.50, 0.50,
        'TechCorp International  |  Sales Analytics Department  |  Confidential');
    Txt(CB, 490, 46, 'Reg', 7.5, 0.50, 0.50, 0.50, 'Page 1 of 2');

    Attach(Page, CB);
  finally
    CB.Free;
  end;
end;

// =============================================================================
// Page 2: charts
// =============================================================================

procedure BuildPage2(Builder: TPDFBuilder);
var
  CB: TPDFContentBuilder;
  Page: TPDFDictionary;
begin
  Page := Builder.AddPage(595, 842);
  AddFonts(Page);
  CB := TPDFContentBuilder.Create;
  try
    // ---- Header (same style as page 1) ----
    Band(CB, 798, 44, 40, 515, 0.13, 0.22, 0.40);
    Txt(CB, 110, 827, 'Bold', 14, 1, 1, 1, 'Sales Performance Report');
    Txt(CB, 110, 811, 'Reg',  10, 0.75, 0.87, 1, 'Charts  —  Q1 / Q2  2025');
    Txt(CB, 460, 827, 'Reg',   9, 0.60, 0.78, 0.95, '01 Apr 2025');

    // ---- Sub-header ----
    Band(CB, 771, 26, 40, 515, 0.86, 0.91, 0.97);
    Txt(CB, 48, 780, 'Bold', 9, 0.13, 0.22, 0.40, 'Visual Analysis');
    Txt(CB, 48, 771, 'Reg',  8, 0.30, 0.30, 0.30,
        'Left: Q2 revenue distribution by region  |  Right: Q1 vs Q2 comparison per region');

    // ---- Divider between charts ----
    CB.SaveState;
    CB.SetStrokeRGB(0.80, 0.84, 0.88);
    CB.SetLineWidth(0.5);
    CB.SetDash([4, 4], 0);
    CB.MoveTo(297, 75);
    CB.LineTo(297, 765);
    CB.Stroke;
    CB.RestoreState;

    // ---- Pie chart section (left) ----
    // Section label
    Band(CB, 748, 18, 40, 252, 0.23, 0.38, 0.57);
    Txt(CB, 48, 752, 'Bold', 9, 1, 1, 1, 'Q2 Sales Distribution');

    // Pie chart centered at (165, 530), r=115
    DrawPieChart(CB, 165, 520, 115);

    // Total callout in center
    RoundRect(CB, 137, 513, 56, 22, 4, 0.97, 0.98, 1.0);
    Txt(CB, 143, 529, 'Bold', 7, 0.13, 0.22, 0.40, 'Q2 Total');
    Txt(CB, 140, 518, 'Bold', 8, 0.08, 0.18, 0.38, FmtMoney(Q2Total));

    // ---- Bar chart section (right) ----
    Band(CB, 748, 18, 302, 253, 0.23, 0.38, 0.57);
    Txt(CB, 310, 752, 'Bold', 9, 1, 1, 1, 'Q1 vs Q2 Comparison  (USD)');

    // Bar chart in right half: x0=302, y0=75, w=253, h=665
    DrawBarChart(CB, 302, 82, 253, 655);

    // ---- Footer ----
    HRule(CB, 58, 40, 555, 0.5, 0.70, 0.75, 0.82);
    Txt(CB, 40,  46, 'Reg', 7.5, 0.50, 0.50, 0.50,
        'TechCorp International  |  Sales Analytics Department  |  Confidential');
    Txt(CB, 490, 46, 'Reg', 7.5, 0.50, 0.50, 0.50, 'Page 2 of 2');

    Attach(Page, CB);
  finally
    CB.Free;
  end;
end;

// =============================================================================
// Main
// =============================================================================

var
  OutPath: string;

begin
  OutPath := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)))
             + 'demo_report.pdf';
  WriteLn('Generating: ', OutPath);

  var Builder := TPDFBuilder.Create;
  try
    Builder.SetTitle('Sales Performance Report  Q1/Q2 2025');
    Builder.SetAuthor('Sales Analytics  TechCorp International');
    Builder.SetSubject('Regional sales performance Q1 vs Q2 2025');
    Builder.SetCreator('PDFLib Delphi  DemoReport');

    BuildPage1(Builder);
    BuildPage2(Builder);

    Builder.SaveToFile(OutPath);
    WriteLn('Saved:    ', OutPath);

    var Doc := TPDFDocument.Create;
    try
      Doc.LoadFromFile(OutPath);
      WriteLn('Pages:    ', Doc.PageCount);
      WriteLn('Title:    ', Doc.Title);
    finally
      Doc.Free;
    end;
  finally
    Builder.Free;
  end;

  WriteLn;
  WriteLn('Done. Press Enter...');
  ReadLn;
end.
