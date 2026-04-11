unit uPDF.Annotations;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Types, System.Generics.Collections,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Outline;

type
  // -------------------------------------------------------------------------
  // Annotation subtypes (§12.5.6)
  // -------------------------------------------------------------------------
  TPDFAnnotType = (
    Unknown,
    Text,           // sticky note
    Link,           // hyperlink or destination
    FreeText,       // text box
    Line,
    Square,
    Circle,
    Polygon,
    PolyLine,
    Highlight,
    Underline,
    Squiggly,
    StrikeOut,
    Stamp,
    Caret,
    Ink,
    Popup,
    FileAttachment,
    Sound,
    Movie,
    Screen,
    Widget,         // form field visual (handled by AcroForms module)
    PrinterMark,
    TrapNet,
    Watermark,
    Redact
  );

  // -------------------------------------------------------------------------
  // Annotation flags (§12.5.3 Table 165)
  // -------------------------------------------------------------------------
  TPDFAnnotFlags = set of (
    Invisible      = 0,
    Hidden         = 1,
    Print          = 2,
    NoZoom         = 3,
    NoRotate       = 4,
    NoView         = 5,
    ReadOnly       = 6,
    Locked         = 7,
    ToggleNoView   = 8,
    LockedContents = 9
  );

  // -------------------------------------------------------------------------
  // One annotation on a page
  // -------------------------------------------------------------------------
  TPDFAnnotation = class
  public
    AnnotType:  TPDFAnnotType;
    PageIndex:  Integer;
    Rect:       TPDFRect;

    // Common fields
    Contents:   string;           // /Contents — human-readable text
    Name:       string;           // /NM — unique annotation name
    Author:     string;           // /T — annotation title / author
    Color:      TPDFColor;        // /C
    FlagsRaw:   Integer;          // /F raw bit field
    IsReadOnly: Boolean;
    IsPrinted:  Boolean;
    IsHidden:   Boolean;

    // Text annotation
    IsOpen:     Boolean;          // /Open
    IconName:   string;           // /Name (e.g. "Note", "Warning")

    // Link / GoTo action
    Dest:       TPDFDestination;  // resolved destination
    URI:        string;           // non-empty for URI actions

    // Markup annotations (highlight, underline, etc.)
    QuadPoints: TArray<TPointF>;  // /QuadPoints — 8 per rect

    // Popup (applies to Text/FreeText/etc.)
    HasPopup:   Boolean;
    PopupRect:  TPDFRect;

    // Appearance streams available
    HasNormalAppearance: Boolean;

    // Raw dict (for advanced consumers)
    Dict:       TPDFDictionary;  // non-owning reference

    // Build a human-readable type label
    function TypeLabel: string;
  end;

  TPDFAnnotationList = TObjectList<TPDFAnnotation>;

  // -------------------------------------------------------------------------
  // Annotation parser
  // -------------------------------------------------------------------------
  TPDFAnnotationLoader = class
  private
    class function ParseAnnotType(const AName: string): TPDFAnnotType; static;
    class procedure ParseQuadPoints(AArr: TPDFArray;
                                    out APoints: TArray<TPointF>); static;
    class procedure ParseAction(ADict: TPDFDictionary;
                                APageTable: TDictionary<Integer, Integer>;
                                AAnnot: TPDFAnnotation); static;
  public
    // Load all annotations for a single page.
    // APageDict — the page dictionary.
    // APageIndex — 0-based page index (stored in each annotation).
    // APageTable — optional map of page-object-number → index (for destination resolution).
    class function LoadForPage(APageDict: TPDFDictionary;
                               APageIndex: Integer;
                               AResolver: IObjectResolver;
                               APageTable: TDictionary<Integer, Integer> = nil)
                               : TPDFAnnotationList; static;
  end;

implementation

// =========================================================================
// TPDFAnnotation
// =========================================================================

function TPDFAnnotation.TypeLabel: string;
begin
  case AnnotType of
    TPDFAnnotType.Text:          Result := 'Text';
    TPDFAnnotType.Link:          Result := 'Link';
    TPDFAnnotType.FreeText:      Result := 'FreeText';
    TPDFAnnotType.Line:          Result := 'Line';
    TPDFAnnotType.Square:        Result := 'Square';
    TPDFAnnotType.Circle:        Result := 'Circle';
    TPDFAnnotType.Polygon:       Result := 'Polygon';
    TPDFAnnotType.PolyLine:      Result := 'PolyLine';
    TPDFAnnotType.Highlight:     Result := 'Highlight';
    TPDFAnnotType.Underline:     Result := 'Underline';
    TPDFAnnotType.Squiggly:      Result := 'Squiggly';
    TPDFAnnotType.StrikeOut:     Result := 'StrikeOut';
    TPDFAnnotType.Stamp:         Result := 'Stamp';
    TPDFAnnotType.Caret:         Result := 'Caret';
    TPDFAnnotType.Ink:           Result := 'Ink';
    TPDFAnnotType.Popup:         Result := 'Popup';
    TPDFAnnotType.FileAttachment:Result := 'FileAttachment';
    TPDFAnnotType.Widget:        Result := 'Widget';
    TPDFAnnotType.Watermark:     Result := 'Watermark';
    TPDFAnnotType.Redact:        Result := 'Redact';
  else
    Result := 'Unknown';
  end;
end;

// =========================================================================
// TPDFAnnotationLoader helpers
// =========================================================================

class function TPDFAnnotationLoader.ParseAnnotType(
  const AName: string): TPDFAnnotType;
begin
  if      AName = 'Text'          then Result := TPDFAnnotType.Text
  else if AName = 'Link'          then Result := TPDFAnnotType.Link
  else if AName = 'FreeText'      then Result := TPDFAnnotType.FreeText
  else if AName = 'Line'          then Result := TPDFAnnotType.Line
  else if AName = 'Square'        then Result := TPDFAnnotType.Square
  else if AName = 'Circle'        then Result := TPDFAnnotType.Circle
  else if AName = 'Polygon'       then Result := TPDFAnnotType.Polygon
  else if AName = 'PolyLine'      then Result := TPDFAnnotType.PolyLine
  else if AName = 'Highlight'     then Result := TPDFAnnotType.Highlight
  else if AName = 'Underline'     then Result := TPDFAnnotType.Underline
  else if AName = 'Squiggly'      then Result := TPDFAnnotType.Squiggly
  else if AName = 'StrikeOut'     then Result := TPDFAnnotType.StrikeOut
  else if AName = 'Stamp'         then Result := TPDFAnnotType.Stamp
  else if AName = 'Caret'         then Result := TPDFAnnotType.Caret
  else if AName = 'Ink'           then Result := TPDFAnnotType.Ink
  else if AName = 'Popup'         then Result := TPDFAnnotType.Popup
  else if AName = 'FileAttachment'then Result := TPDFAnnotType.FileAttachment
  else if AName = 'Sound'         then Result := TPDFAnnotType.Sound
  else if AName = 'Movie'         then Result := TPDFAnnotType.Movie
  else if AName = 'Screen'        then Result := TPDFAnnotType.Screen
  else if AName = 'Widget'        then Result := TPDFAnnotType.Widget
  else if AName = 'PrinterMark'   then Result := TPDFAnnotType.PrinterMark
  else if AName = 'TrapNet'       then Result := TPDFAnnotType.TrapNet
  else if AName = 'Watermark'     then Result := TPDFAnnotType.Watermark
  else if AName = 'Redact'        then Result := TPDFAnnotType.Redact
  else                                 Result := TPDFAnnotType.Unknown;
end;

class procedure TPDFAnnotationLoader.ParseQuadPoints(AArr: TPDFArray;
  out APoints: TArray<TPointF>);
var
  I, N: Integer;
begin
  APoints := nil;
  if AArr = nil then Exit;
  N := AArr.Count div 2;
  SetLength(APoints, N);
  for I := 0 to N - 1 do
  begin
    APoints[I].X := AArr.GetAsNumber(I * 2,     0);
    APoints[I].Y := AArr.GetAsNumber(I * 2 + 1, 0);
  end;
end;

class procedure TPDFAnnotationLoader.ParseAction(ADict: TPDFDictionary;
  APageTable: TDictionary<Integer, Integer>; AAnnot: TPDFAnnotation);
var
  ActType: string;
  DArr:    TPDFArray;
  DObj:    TPDFObject;
begin
  if ADict = nil then Exit;
  ActType := ADict.GetAsName('S');

  if (ActType = 'GoTo') or (ActType = '') then
  begin
    DArr := ADict.GetAsArray('D');
    if DArr <> nil then
      AAnnot.Dest := ResolvePDFDestination(DArr, APageTable);
  end
  else if ActType = 'URI' then
    AAnnot.URI := ADict.GetAsUnicodeString('URI');
end;

// =========================================================================
// TPDFAnnotationLoader.LoadForPage
// =========================================================================

class function TPDFAnnotationLoader.LoadForPage(APageDict: TPDFDictionary;
  APageIndex: Integer; AResolver: IObjectResolver;
  APageTable: TDictionary<Integer, Integer>): TPDFAnnotationList;
var
  AnnotsArr: TPDFArray;
  I:         Integer;
  AnnotObj:  TPDFObject;
  AnnotDict: TPDFDictionary;
  Annot:     TPDFAnnotation;
  ColorArr:  TPDFArray;
  DestObj:   TPDFObject;
  ActObj:    TPDFObject;
  PopupObj:  TPDFObject;
  EmptyTable: TDictionary<Integer, Integer>;
begin
  Result := TPDFAnnotationList.Create(True);

  AnnotsArr := APageDict.GetAsArray('Annots');
  if AnnotsArr = nil then Exit;

  // Use an empty table if none provided (destinations won't be resolved)
  EmptyTable := nil;
  if APageTable = nil then
  begin
    EmptyTable := TDictionary<Integer, Integer>.Create;
    APageTable := EmptyTable;
  end;

  try
    for I := 0 to AnnotsArr.Count - 1 do
    begin
      AnnotObj := AnnotsArr.Get(I);
      if AnnotObj = nil then Continue;
      AnnotObj := AnnotObj.Dereference;
      if not AnnotObj.IsDictionary then Continue;
      AnnotDict := TPDFDictionary(AnnotObj);

      Annot            := TPDFAnnotation.Create;
      Annot.PageIndex  := APageIndex;
      Annot.Dict       := AnnotDict;
      Annot.AnnotType  := ParseAnnotType(AnnotDict.GetAsName('Subtype'));
      Annot.Rect       := AnnotDict.GetRect('Rect').Normalize;
      Annot.Contents   := AnnotDict.GetAsUnicodeString('Contents');
      Annot.Name       := AnnotDict.GetAsUnicodeString('NM');
      Annot.Author     := AnnotDict.GetAsUnicodeString('T');
      Annot.FlagsRaw   := AnnotDict.GetAsInteger('F', 0);
      Annot.IsReadOnly := (Annot.FlagsRaw and $40) <> 0;   // bit 6
      Annot.IsPrinted  := (Annot.FlagsRaw and $04) <> 0;   // bit 2
      Annot.IsHidden   := (Annot.FlagsRaw and $02) <> 0;   // bit 1

      // Color /C [R G B] or [G] or [C M Y K]
      ColorArr := AnnotDict.GetAsArray('C');
      if ColorArr <> nil then
        case ColorArr.Count of
          1: Annot.Color := TPDFColor.MakeGray(ColorArr.GetAsNumber(0, 0));
          3: Annot.Color := TPDFColor.MakeRGB(
               ColorArr.GetAsNumber(0, 0),
               ColorArr.GetAsNumber(1, 0),
               ColorArr.GetAsNumber(2, 0));
          4: Annot.Color := TPDFColor.MakeCMYK(
               ColorArr.GetAsNumber(0, 0), ColorArr.GetAsNumber(1, 0),
               ColorArr.GetAsNumber(2, 0), ColorArr.GetAsNumber(3, 0));
        end;

      // Text annotation extras
      if Annot.AnnotType = TPDFAnnotType.Text then
      begin
        Annot.IsOpen  := AnnotDict.GetAsInteger('Open', 0) <> 0;
        Annot.IconName := AnnotDict.GetAsName('Name', 'Note');
      end;

      // QuadPoints (markup annotations)
      if Annot.AnnotType in [TPDFAnnotType.Highlight, TPDFAnnotType.Underline,
                              TPDFAnnotType.Squiggly,  TPDFAnnotType.StrikeOut] then
        ParseQuadPoints(AnnotDict.GetAsArray('QuadPoints'), Annot.QuadPoints);

      // Destination (direct /Dest)
      DestObj := AnnotDict.Get('Dest');
      if DestObj <> nil then
      begin
        DestObj := DestObj.Dereference;
        if DestObj.IsArray then
          Annot.Dest := ResolvePDFDestination(TPDFArray(DestObj), APageTable);
      end;

      // Action /A
      ActObj := AnnotDict.Get('A');
      if ActObj <> nil then
      begin
        ActObj := ActObj.Dereference;
        if ActObj.IsDictionary then
          ParseAction(TPDFDictionary(ActObj), APageTable, Annot);
      end;

      // Popup
      PopupObj := AnnotDict.Get('Popup');
      if PopupObj <> nil then
      begin
        PopupObj := PopupObj.Dereference;
        if PopupObj.IsDictionary then
        begin
          Annot.HasPopup  := True;
          Annot.PopupRect := TPDFDictionary(PopupObj).GetRect('Rect').Normalize;
        end;
      end;

      // Appearance
      Annot.HasNormalAppearance :=
        (AnnotDict.GetAsDictionary('AP') <> nil) and
        (AnnotDict.GetAsDictionary('AP').Get('N') <> nil);

      Result.Add(Annot);
    end;
  finally
    EmptyTable.Free;
  end;
end;

end.
