unit uPDF.Redaction;

{
  Content-stream text-layer redaction.

  Problem: drawing a black rectangle over a name only hides it visually — the
  glyphs remain in the page content stream and any text extractor (or an LLM)
  can still read the original text.

  This unit performs TRUE redaction of the text layer: for every glyph whose
  center falls inside a redaction box, it rewrites that glyph's code in the
  content stream to the code of a replacement character (e.g. 'X'), keeping the
  SAME code byte-length so the surrounding layout/advances are preserved. The
  caller then draws the black rectangles on top (so the visible result is the
  same), but the underlying extractable text now reads "XXXX".

  Strategy (per page):
    Pass 1 — run the content-stream processor; for each emitted glyph use its
             (StringOffset, GlyphIndex, CodeByteLen, Font) source mapping plus
             its no-CTM position (same space the text extractor / search use to
             build the boxes) to decide if it must be scrubbed. Group targets
             by the operand (string token) they belong to.
    Pre-check — every targeted operand's font must be able to re-encode the
             replacement char at the same code byte-length. If ANY cannot, the
             whole page is left UNCHANGED and the function returns False so the
             caller can fall back to rasterizing the page (full safety).
    Pass 2 — splice the content stream: copy original bytes verbatim except the
             targeted string operands, which are re-emitted as hex strings with
             the targeted glyph codes replaced. Write back via TPDFPage.SetContent.

  Boxes are given normalized [0..1] with (0,0) at the top-left and y growing
  downward — the same convention used to draw the black rectangles.
}

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.Types, System.Math,
  uPDF.Types, uPDF.Objects, uPDF.Lexer, uPDF.Document, uPDF.Font,
  uPDF.GraphicsState, uPDF.ContentStream, uPDF.TextExtractor;

type
  TPDFRedactor = class
  public
    // Scrub the page text layer. ABoxes are normalized [0..1], Y-down.
    // Replaces every glyph whose center is inside any box with AReplacement
    // (default 'X'), preserving code byte-length, and rewrites the page content.
    // Returns True if the page was processed safely (whether or not any glyph
    // was scrubbed). Returns False and leaves the page UNCHANGED if some
    // targeted glyph's font cannot encode AReplacement — caller should then
    // rasterize the page. ACount returns the number of glyphs scrubbed.
    class function ScrubPageTextLayer(ADoc: TPDFDocument; APageIndex: Integer;
      const ABoxes: TArray<TRectF>; const AReplacement: string;
      out ACount: Integer): Boolean; static;

    // Igual que ScrubPageTextLayer, pero QUITA los glifos en vez de cambiarlos
    // por una letra: cada tramo borrado se sustituye por un ajuste de TJ con su
    // avance exacto (ancho del glifo + Tc + Tw), así el texto que sigue en el
    // renglón queda en su sitio. Con la 'X' el renglón se desplazaba: la 'X'
    // no mide lo mismo que la letra que reemplaza, y lo siguiente se corría
    // (incluso bajo el recuadro vecino). Un Tj tocado se reescribe como TJ.
    // Devuelve False y deja la página INTACTA si no puede hacerlo con
    // seguridad (operadores ' y ", tamaño de letra 0): el llamador rasteriza.
    class function RemovePageTextLayer(ADoc: TPDFDocument; APageIndex: Integer;
      const ABoxes: TArray<TRectF>; out ACount: Integer): Boolean; static;
  end;

implementation

type
  // Targets within a single string operand (identified by its source offset).
  TOperandInfo = class
    Font:        TPDFFont;
    CodeByteLen: Integer;
    Idxs:        TList<Integer>;   // 0-based glyph indices to scrub
    constructor Create;
    destructor  Destroy; override;
  end;

constructor TOperandInfo.Create;
begin
  inherited Create;
  Idxs := TList<Integer>.Create;
end;

destructor TOperandInfo.Destroy;
begin
  Idxs.Free;
  inherited;
end;

// Re-emit one string operand as a hex string <..>, substituting the codes at
// the targeted glyph indices with AReplCode (same byte-length).
function OperandToHexBytes(const ADecoded: RawByteString; AIdxs: TList<Integer>;
  ACodeLen: Integer; const AReplCode: TBytes): TBytes;
var
  SB:         TStringBuilder;
  TotalCodes: Integer;
  I, J, Base: Integer;
begin
  SB := TStringBuilder.Create;
  try
    SB.Append('<');
    if ACodeLen < 1 then ACodeLen := 1;
    TotalCodes := Length(ADecoded) div ACodeLen;
    for I := 0 to TotalCodes - 1 do
    begin
      Base := I * ACodeLen;  // 0-based offset into ADecoded
      if AIdxs.Contains(I) then
      begin
        for J := 0 to High(AReplCode) do
          SB.Append(IntToHex(AReplCode[J], 2));
      end
      else
      begin
        for J := 0 to ACodeLen - 1 do
          SB.Append(IntToHex(Ord(ADecoded[Base + J + 1]), 2)); // RawByteString is 1-based
      end;
    end;
    // Emit any trailing bytes that don't fill a full code unit, unchanged.
    for J := TotalCodes * ACodeLen to Length(ADecoded) - 1 do
      SB.Append(IntToHex(Ord(ADecoded[J + 1]), 2));
    SB.Append('>');
    Result := TEncoding.ASCII.GetBytes(SB.ToString);
  finally
    SB.Free;
  end;
end;

class function TPDFRedactor.ScrubPageTextLayer(ADoc: TPDFDocument;
  APageIndex: Integer; const ABoxes: TArray<TRectF>; const AReplacement: string;
  out ACount: Integer): Boolean;
var
  Page:    TPDFPage;
  Data:    TBytes;
  Res:     IPDFResources;
  Proc:    TPDFContentStreamProcessor;
  Targets: TObjectDictionary<Int64, TOperandInfo>;
  RCache:  TDictionary<TPDFFont, TBytes>;
  PageW, PageH: Single;
  Offs:    TList<Int64>;
  LexStream: TBytesStream;
  Lexer:   TPDFLexer;
  Outp:    TBytesStream;
  LastPos: Int64;
  AllOk:   Boolean;
begin
  ACount := 0;

  if (ADoc = nil) or (APageIndex < 0) or (APageIndex >= ADoc.PageCount) then
    Exit(False);

  Page  := ADoc.Pages[APageIndex];
  PageW := Page.Width;
  PageH := Page.Height;
  if (PageW <= 0) or (PageH <= 0) then Exit(True);

  Data := Page.ContentStreamBytes;
  if Length(Data) = 0 then Exit(True);

  Targets := TObjectDictionary<Int64, TOperandInfo>.Create([doOwnsValues]);
  RCache  := TDictionary<TPDFFont, TBytes>.Create;
  try
    // -------- Pass 1: collect glyphs to scrub, grouped by operand --------
    Res  := TPDFPageResources.Create(Page);
    Proc := TPDFContentStreamProcessor.Create;
    try
      Proc.OnPaintGlyph :=
        procedure(const G: TPDFGlyphInfo; const St: TPDFGraphicsState)
        var
          FS, W, CX, CY, NX, NY: Single;
          B: TRectF;
          Inside: Boolean;
          Info: TOperandInfo;
        begin
          if (G.StringOffset < 0) or (G.Font = nil) then Exit;

          FS := St.Text.FontSize;
          W  := G.Width / 1000.0 * FS;
          CX := G.X + W * 0.5;          // glyph center, no-CTM user space
          CY := G.Y + FS * 0.35;        // ~vertical center above baseline
          NX := CX / PageW;
          NY := (PageH - CY) / PageH;   // Y-up -> Y-down normalized

          Inside := False;
          for B in ABoxes do
            if (NX >= B.Left) and (NX <= B.Right) and
               (NY >= B.Top)  and (NY <= B.Bottom) then
            begin
              Inside := True;
              Break;
            end;
          if not Inside then Exit;

          if not Targets.TryGetValue(G.StringOffset, Info) then
          begin
            Info := TOperandInfo.Create;
            Info.Font        := G.Font;
            Info.CodeByteLen := G.CodeByteLen;
            Targets.Add(G.StringOffset, Info);
          end;
          if not Info.Idxs.Contains(G.GlyphIndex) then
            Info.Idxs.Add(G.GlyphIndex);
        end;

      Proc.Process(Data, Res, Page.Document.Resolver);
    finally
      Proc.Free;
      // NOTE: keep Res alive — it owns the TPDFFont instances referenced by
      // the collected targets. Releasing it here would free those fonts and the
      // pre-check (TryEncodeChar) would dereference dangling pointers. Res is a
      // local interface and is released when the method returns.
    end;

    if Targets.Count = 0 then
      Exit(True);  // no text-layer names on this page

    // -------- Pre-check: every targeted font must encode the replacement --------
    AllOk := True;
    for var Pair in Targets do
    begin
      var Code: TBytes;
      if RCache.ContainsKey(Pair.Value.Font) then Continue;
      if Pair.Value.Font.TryEncodeChar(AReplacement, Pair.Value.CodeByteLen, Code) then
        RCache.Add(Pair.Value.Font, Code)
      else
      begin
        AllOk := False;
        Break;
      end;
    end;
    if not AllOk then
      Exit(False);  // leave page UNCHANGED; caller rasterizes

    // -------- Pass 2: splice content, rewriting targeted operands --------
    Offs := TList<Int64>.Create;
    LexStream := TBytesStream.Create(Data);
    Lexer := TPDFLexer.Create(LexStream, False);
    Outp  := TBytesStream.Create;
    try
      for var K in Targets.Keys do
        Offs.Add(K);
      Offs.Sort;

      LastPos := 0;
      for var O in Offs do
      begin
        if O > LastPos then
          Outp.Write(Data[LastPos], O - LastPos);

        Lexer.SeekTo(O);
        var Tok := Lexer.NextToken;
        var EndOff := Lexer.Position;

        var Info := Targets[O];
        var NewOp := OperandToHexBytes(Tok.RawData, Info.Idxs,
          Info.CodeByteLen, RCache[Info.Font]);
        if Length(NewOp) > 0 then
          Outp.Write(NewOp[0], Length(NewOp));

        Inc(ACount, Info.Idxs.Count);
        LastPos := EndOff;
      end;

      if Length(Data) > LastPos then
        Outp.Write(Data[LastPos], Length(Data) - LastPos);

      Page.SetContent(Copy(Outp.Bytes, 0, Outp.Size));
    finally
      Outp.Free;
      Lexer.Free;
      LexStream.Free;
      Offs.Free;
    end;

    Result := True;
  finally
    RCache.Free;
    Targets.Free;
  end;
end;

type
  // Glifos a quitar de un operando, con su avance (milésimas de unidad de texto).
  TOperandRemove = class
    CodeByteLen: Integer;
    Adv:         TDictionary<Integer, Double>;   // índice de glifo -> avance
    constructor Create;
    destructor  Destroy; override;
  end;

constructor TOperandRemove.Create;
begin
  inherited Create;
  Adv := TDictionary<Integer, Double>.Create;
end;

destructor TOperandRemove.Destroy;
begin
  Adv.Free;
  inherited;
end;

// Elementos de TJ para un operando con glifos quitados: tramos hex conservados
// y, en lugar de cada tramo quitado, -avance (un número positivo en TJ mueve a
// la izquierda; negativo, a la derecha).
function OperandToTJItems(const ADecoded: RawByteString; AInfo: TOperandRemove): string;
var
  SB, Run: TStringBuilder;
  CodeLen, Total, I, J: Integer;
  Skip: Double;

  procedure FlushRun;
  begin
    if Run.Length > 0 then
    begin
      SB.Append('<').Append(Run.ToString).Append('> ');
      Run.Clear;
    end;
  end;

  procedure FlushSkip;
  begin
    if Skip <> 0 then
    begin
      SB.Append(FormatFloat('0.###', -Skip, TFormatSettings.Invariant)).Append(' ');
      Skip := 0;
    end;
  end;

begin
  CodeLen := Max(1, AInfo.CodeByteLen);
  Total := Length(ADecoded) div CodeLen;
  SB  := TStringBuilder.Create;
  Run := TStringBuilder.Create;
  try
    Skip := 0;
    for I := 0 to Total - 1 do
      if AInfo.Adv.ContainsKey(I) then
      begin
        FlushRun;
        Skip := Skip + AInfo.Adv[I];
      end
      else
      begin
        FlushSkip;
        for J := 0 to CodeLen - 1 do
          Run.Append(IntToHex(Ord(ADecoded[I * CodeLen + J + 1]), 2));
      end;
    for J := Total * CodeLen to Length(ADecoded) - 1 do
      Run.Append(IntToHex(Ord(ADecoded[J + 1]), 2));
    FlushSkip;
    FlushRun;
    Result := SB.ToString.TrimRight;
  finally
    Run.Free;
    SB.Free;
  end;
end;

class function TPDFRedactor.RemovePageTextLayer(ADoc: TPDFDocument;
  APageIndex: Integer; const ABoxes: TArray<TRectF>; out ACount: Integer): Boolean;
var
  Page:    TPDFPage;
  Data:    TBytes;
  Res:     IPDFResources;
  Proc:    TPDFContentStreamProcessor;
  Targets: TObjectDictionary<Int64, TOperandRemove>;
  PageW, PageH: Single;
  Offs:    TList<Int64>;
  LexStream: TBytesStream;
  Lexer:   TPDFLexer;
  Outp:    TBytesStream;
  LastPos: Int64;
  Bad:     Boolean;
begin
  ACount := 0;
  if (ADoc = nil) or (APageIndex < 0) or (APageIndex >= ADoc.PageCount) then
    Exit(False);
  Page  := ADoc.Pages[APageIndex];
  PageW := Page.Width;
  PageH := Page.Height;
  if (PageW <= 0) or (PageH <= 0) then Exit(True);
  Data := Page.ContentStreamBytes;
  if Length(Data) = 0 then Exit(True);

  Targets := TObjectDictionary<Int64, TOperandRemove>.Create([doOwnsValues]);
  try
    // -------- Pass 1: glifos a quitar (mismo criterio de centro que Scrub) ----
    Bad := False;
    Res  := TPDFPageResources.Create(Page);
    Proc := TPDFContentStreamProcessor.Create;
    try
      Proc.OnPaintGlyph :=
        procedure(const G: TPDFGlyphInfo; const St: TPDFGraphicsState)
        var
          FS, W, CX, CY, NX, NY, A: Single;
          B: TRectF;
          Inside: Boolean;
          Info: TOperandRemove;
        begin
          if G.StringOffset < 0 then Exit;
          FS := St.Text.FontSize;
          W  := G.Width / 1000.0 * FS;
          CX := G.X + W * 0.5;
          CY := G.Y + FS * 0.35;
          NX := CX / PageW;
          NY := (PageH - CY) / PageH;
          Inside := False;
          for B in ABoxes do
            if (NX >= B.Left) and (NX <= B.Right) and
               (NY >= B.Top)  and (NY <= B.Bottom) then
            begin
              Inside := True;
              Break;
            end;
          if not Inside then Exit;
          if FS = 0 then
          begin
            Bad := True;   // sin tamaño no se puede expresar el avance en TJ
            Exit;
          end;
          // avance en milésimas: ancho + Tc (+ Tw si es el espacio de 1 byte)
          A := G.Width + St.Text.CharSpacing * 1000.0 / FS;
          if (G.CodeByteLen = 1) and (G.CharCode = 32) then
            A := A + St.Text.WordSpacing * 1000.0 / FS;
          if not Targets.TryGetValue(G.StringOffset, Info) then
          begin
            Info := TOperandRemove.Create;
            Info.CodeByteLen := G.CodeByteLen;
            Targets.Add(G.StringOffset, Info);
          end;
          Info.Adv.AddOrSetValue(G.GlyphIndex, A);
        end;
      Proc.Process(Data, Res, Page.Document.Resolver);
    finally
      Proc.Free;
    end;
    if Bad then Exit(False);
    if Targets.Count = 0 then Exit(True);

    // -------- Pass 2: reescribir; todo o nada --------
    Offs := TList<Int64>.Create;
    LexStream := TBytesStream.Create(Data);
    Lexer := TPDFLexer.Create(LexStream, False);
    Outp  := TBytesStream.Create;
    try
      for var K in Targets.Keys do
        Offs.Add(K);
      Offs.Sort;
      LastPos := 0;
      for var O in Offs do
      begin
        if O < LastPos then Exit(False);
        if O > LastPos then
          Outp.Write(Data[LastPos], O - LastPos);
        Lexer.SeekTo(O);
        var Tok := Lexer.NextToken;
        var EndOff := Lexer.Position;
        var Nxt := Lexer.NextToken;
        var NxtEnd := Lexer.Position;
        var Info := Targets[O];
        var Items := OperandToTJItems(Tok.RawData, Info);
        var NewOp: string;
        if (Nxt.Kind = TPDFTokenKind.Keyword) and (Nxt.Value = 'Tj') then
        begin
          // "<op> Tj" -> "[items] TJ"
          NewOp := '[' + Items + '] TJ';
          LastPos := NxtEnd;
        end
        else if Nxt.Kind in [TPDFTokenKind.Integer, TPDFTokenKind.Real,
                             TPDFTokenKind.LiteralString, TPDFTokenKind.HexString,
                             TPDFTokenKind.ArrayClose] then
        begin
          // dentro de un arreglo de TJ: los elementos van tal cual
          NewOp := Items;
          LastPos := EndOff;
        end
        else
          Exit(False);   // operadores ' y " (u otros): página intacta
        var NB := TEncoding.ASCII.GetBytes(NewOp);
        if Length(NB) > 0 then
          Outp.Write(NB[0], Length(NB));
        Inc(ACount, Info.Adv.Count);
      end;
      if Length(Data) > LastPos then
        Outp.Write(Data[LastPos], Length(Data) - LastPos);
      Page.SetContent(Copy(Outp.Bytes, 0, Outp.Size));
    finally
      Outp.Free;
      Lexer.Free;
      LexStream.Free;
      Offs.Free;
    end;
    Result := True;
  finally
    Targets.Free;
  end;
end;

end.
