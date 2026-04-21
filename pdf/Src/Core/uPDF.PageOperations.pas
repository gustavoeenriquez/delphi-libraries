unit uPDF.PageOperations;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.Math,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Document,
  uPDF.Writer, uPDF.PageCopy;

type
  // ---------------------------------------------------------------------------
  // TPDFPageOperations
  //
  // Static helpers for rearranging, splitting, merging, and rotating pages in
  // existing PDF documents.  All write operations produce a new PDF file —
  // the source document is never modified.
  //
  // Split / ExtractPages / DeletePages / ReorderPages
  //   All reduce to ExtractPages with different index sets.
  //
  // Merge
  //   Combines pages from multiple source documents into one PDF.
  //   Resources from each source are prefixed to avoid name collisions;
  //   content streams are patched accordingly.
  //
  // RotatePages
  //   Modifies /Rotate in the in-memory page dicts of ASource.
  //   Call ASource.SaveToStream / SaveToFile afterwards to persist.
  // ---------------------------------------------------------------------------
  TPDFPageOperations = class
  private
    class procedure BuildAndWrite(
      const APages:   TArray<TPDFDictionary>;
      AObjects:       TObjectDictionary<Integer, TPDFObject>;
      ANextObjNum:    Integer;
      AOutput:        TStream); static;

    class function  PatchContentStream(const ABytes: TBytes;
      const ARenames: TDictionary<string, string>): TBytes; static;

    class function  PrefixPageResources(APageDict: TPDFDictionary;
      const APrefix: string): TDictionary<string, string>; static;
  public
    // ---- Split ---------------------------------------------------------------

    // Extract pages [AFrom..ATo] (0-based, inclusive) into a new PDF.
    class procedure Split(ASource: TPDFDocument; AFrom, ATo: Integer;
      AOutput: TStream); overload; static;
    class procedure Split(ASource: TPDFDocument; AFrom, ATo: Integer;
      const APath: string); overload; static;

    // ---- ExtractPages --------------------------------------------------------

    // Extract an arbitrary subset of pages (in the supplied order).
    // APageIndices may be in any order; duplicates are allowed (page appears twice).
    class procedure ExtractPages(ASource: TPDFDocument;
      const APageIndices: TArray<Integer>;
      AOutput: TStream); overload; static;
    class procedure ExtractPages(ASource: TPDFDocument;
      const APageIndices: TArray<Integer>;
      const APath: string); overload; static;

    // ---- DeletePages ---------------------------------------------------------

    // Delete the specified pages from ASource and write the rest to AOutput.
    class procedure DeletePages(ASource: TPDFDocument;
      const APageIndices: TArray<Integer>;
      AOutput: TStream); overload; static;
    class procedure DeletePages(ASource: TPDFDocument;
      const APageIndices: TArray<Integer>;
      const APath: string); overload; static;

    // ---- ReorderPages --------------------------------------------------------

    // Write ASource pages in the order given by ANewOrder.
    // ANewOrder[i] = original 0-based page index that should appear at position i.
    class procedure ReorderPages(ASource: TPDFDocument;
      const ANewOrder: TArray<Integer>;
      AOutput: TStream); overload; static;
    class procedure ReorderPages(ASource: TPDFDocument;
      const ANewOrder: TArray<Integer>;
      const APath: string); overload; static;

    // ---- Merge ---------------------------------------------------------------

    // Merge all pages from every document in ASources into one PDF.
    class procedure Merge(const ASources: TArray<TPDFDocument>;
      AOutput: TStream); overload; static;
    class procedure Merge(const ASources: TArray<TPDFDocument>;
      const APath: string); overload; static;

    // Convenience: open files, merge, close.
    class procedure MergeFiles(const AFiles: TArray<string>;
      const AOutput: string); static;

    // ---- RotatePages ---------------------------------------------------------

    // Add ARotation degrees to each target page's /Rotate value.
    // ARotation must be a multiple of 90.  APageIndices = nil means all pages.
    // Modifies ASource in memory; caller saves with ASource.SaveToFile.
    class procedure RotatePages(ASource: TPDFDocument;
      ARotation: Integer;
      const APageIndices: TArray<Integer> = nil); static;
  end;

implementation

// ---------------------------------------------------------------------------
// PDF delimiter set used by the content stream patcher
// ---------------------------------------------------------------------------
function IsPDFDelimiter(C: AnsiChar): Boolean; inline;
begin
  Result := C in [' ', #9, #10, #12, #13, '(', ')', '<', '>', '[', ']',
                  '{', '}', '/', '%'];
end;

// ---------------------------------------------------------------------------
// PatchContentStream
//
// Replaces PDF name tokens in ABytes according to ARenames.
// Key   = original name (without leading slash)
// Value = replacement name (without leading slash)
// ---------------------------------------------------------------------------
class function TPDFPageOperations.PatchContentStream(const ABytes: TBytes;
  const ARenames: TDictionary<string, string>): TBytes;
var
  Src:      TBytes;
  Out:      TBytesStream;
  I, J:     Integer;
  N:        Integer;
  RunStart: Integer;
  RunLen:   Integer;
  Name:     AnsiString;
  NewName:  string;
  NewNameB: TBytes;
begin
  if (Length(ABytes) = 0) or (ARenames.Count = 0) then
    Exit(ABytes);

  Src := ABytes;
  Out := TBytesStream.Create;
  try
    I := 0;
    N := Length(Src);

    while I < N do
    begin
      if AnsiChar(Src[I]) = '/' then
      begin
        // Scan to end of name token.
        J := I + 1;
        while (J < N) and not IsPDFDelimiter(AnsiChar(Src[J])) do
          Inc(J);

        // Extract the name (without leading slash).
        SetLength(Name, J - I - 1);
        if Length(Name) > 0 then
          Move(Src[I + 1], Name[1], Length(Name));

        if ARenames.TryGetValue(string(Name), NewName) then
        begin
          // Write the replacement name (ASCII, so byte-by-byte is fine).
          var Slash: Byte := Ord('/');
          Out.Write(Slash, 1);
          NewNameB := TEncoding.UTF8.GetBytes(NewName);
          Out.Write(NewNameB, Length(NewNameB));
        end
        else
        begin
          // No rename: write the original token verbatim.
          Out.Write(Src[I], J - I);
        end;
        I := J;
      end
      else
      begin
        // Batch-copy the non-name run up to the next '/' (or end).
        RunStart := I;
        while (I < N) and (AnsiChar(Src[I]) <> '/') do
          Inc(I);
        RunLen := I - RunStart;
        if RunLen > 0 then
          Out.Write(Src[RunStart], RunLen);
      end;
    end;

    Result := Out.Bytes;
    SetLength(Result, Out.Size);
  finally
    Out.Free;
  end;
end;

// ---------------------------------------------------------------------------
// PrefixPageResources
//
// Renames every resource entry in APageDict's /Resources sub-dicts by
// prepending APrefix.  The renamed copies are placed in the same sub-dicts.
// Returns a name-remap table (originalName → prefixedName) for use by the
// content stream patcher.
//
// This is used by Merge to guarantee cross-document name uniqueness.
// ---------------------------------------------------------------------------
class function TPDFPageOperations.PrefixPageResources(APageDict: TPDFDictionary;
  const APrefix: string): TDictionary<string, string>;
const
  SUBDICTS: array[0..5] of string = (
    'Font', 'XObject', 'ColorSpace', 'ExtGState', 'Pattern', 'Shading');
var
  ResObj:  TPDFObject;
  ResDict: TPDFDictionary;
  SubName: string;
  SubObj:  TPDFObject;
  SubDict: TPDFDictionary;
  Keys:    TArray<string>;
  Key:     string;
  Val:     TPDFObject;
begin
  Result := TDictionary<string, string>.Create;

  ResObj := APageDict.RawGet('Resources');
  if ResObj = nil then Exit;
  ResObj := ResObj.Dereference;
  if not ResObj.IsDictionary then Exit;
  ResDict := TPDFDictionary(ResObj);

  for SubName in SUBDICTS do
  begin
    SubObj := ResDict.RawGet(SubName);
    if SubObj = nil then Continue;
    SubObj := SubObj.Dereference;
    if not SubObj.IsDictionary then Continue;
    SubDict := TPDFDictionary(SubObj);

    // Collect current keys before modifying.
    Keys := SubDict.Keys;
    for Key in Keys do
    begin
      Val := SubDict.RawGet(Key);
      if Val = nil then Continue;
      var NewKey := APrefix + Key;
      SubDict.SetValue(NewKey, Val.Clone);
      SubDict.Remove(Key);
      Result.AddOrSetValue(Key, NewKey);
    end;
  end;
end;

// ---------------------------------------------------------------------------
// BuildAndWrite
//
// Given a list of copied page dicts and the object pool they reference,
// builds the page tree + catalog, then serialises with TPDFWriter.WriteFull.
// ---------------------------------------------------------------------------
class procedure TPDFPageOperations.BuildAndWrite(
  const APages:   TArray<TPDFDictionary>;
  AObjects:       TObjectDictionary<Integer, TPDFObject>;
  ANextObjNum:    Integer;
  AOutput:        TStream);
var
  NextNum:   Integer;
  PagesNum:  Integer;
  CatNum:    Integer;
  KidsArr:   TPDFArray;
  PagesDict: TPDFDictionary;
  CatDict:   TPDFDictionary;
  PageNums:  TArray<Integer>;
  I:         Integer;
  Writer:    TPDFWriter;
begin
  NextNum := ANextObjNum;

  // Allocate numbers for each page dict.
  SetLength(PageNums, Length(APages));
  for I := 0 to High(APages) do
  begin
    PageNums[I] := NextNum;
    Inc(NextNum);
  end;

  // /Pages root.
  PagesNum  := NextNum; Inc(NextNum);
  PagesDict := TPDFDictionary.Create;
  PagesDict.SetValue('Type',  TPDFName.Create('Pages'));
  PagesDict.SetValue('Count', TPDFInteger.Create(Length(APages)));
  KidsArr := TPDFArray.Create;
  for I := 0 to High(APages) do
    KidsArr.Add(TPDFReference.CreateNum(PageNums[I], 0));
  PagesDict.SetValue('Kids', KidsArr);
  AObjects.AddOrSetValue(PagesNum, PagesDict);

  // Link each page to the /Pages node.
  for I := 0 to High(APages) do
  begin
    APages[I].SetValue('Parent', TPDFReference.CreateNum(PagesNum, 0));
    AObjects.AddOrSetValue(PageNums[I], APages[I]);
  end;

  // /Catalog.
  CatNum  := NextNum; Inc(NextNum);
  CatDict := TPDFDictionary.Create;
  CatDict.SetValue('Type',  TPDFName.Create('Catalog'));
  CatDict.SetValue('Pages', TPDFReference.CreateNum(PagesNum, 0));
  AObjects.AddOrSetValue(CatNum, CatDict);

  // Write.
  Writer := TPDFWriter.Create(AOutput, TPDFWriteOptions.Default);
  try
    Writer.WriteFull(CatDict, nil, AObjects);
  finally
    Writer.Free;
  end;
end;

// ===========================================================================
// Split
// ===========================================================================

class procedure TPDFPageOperations.Split(ASource: TPDFDocument;
  AFrom, ATo: Integer; AOutput: TStream);
var
  Indices: TArray<Integer>;
  I:       Integer;
begin
  AFrom := EnsureRange(AFrom, 0, ASource.PageCount - 1);
  ATo   := EnsureRange(ATo,   0, ASource.PageCount - 1);
  if AFrom > ATo then
    raise EPDFError.Create('Split: AFrom must be <= ATo');
  SetLength(Indices, ATo - AFrom + 1);
  for I := 0 to High(Indices) do
    Indices[I] := AFrom + I;
  ExtractPages(ASource, Indices, AOutput);
end;

class procedure TPDFPageOperations.Split(ASource: TPDFDocument;
  AFrom, ATo: Integer; const APath: string);
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(APath, fmCreate);
  try
    Split(ASource, AFrom, ATo, FS);
  finally
    FS.Free;
  end;
end;

// ===========================================================================
// ExtractPages  (core implementation)
// ===========================================================================

class procedure TPDFPageOperations.ExtractPages(ASource: TPDFDocument;
  const APageIndices: TArray<Integer>; AOutput: TStream);
var
  Objects:   TObjectDictionary<Integer, TPDFObject>;
  NextNum:   Integer;
  Copier:    TPDFObjectCopier;
  Pages:     TArray<TPDFDictionary>;
  I:         Integer;
  PageIdx:   Integer;
  PageCopy:  TPDFDictionary;
begin
  if Length(APageIndices) = 0 then
    raise EPDFError.Create('ExtractPages: no pages specified');

  Objects := TObjectDictionary<Integer, TPDFObject>.Create([doOwnsValues]);
  try
    NextNum := 1;
    Copier  := TPDFObjectCopier.Create(ASource.Resolver, Objects, @NextNum);
    try
      SetLength(Pages, Length(APageIndices));
      for I := 0 to High(APageIndices) do
      begin
        PageIdx  := APageIndices[I];
        if (PageIdx < 0) or (PageIdx >= ASource.PageCount) then
          raise EPDFPageNotFoundError.CreateFmt(
            'ExtractPages: page index %d out of range', [PageIdx]);
        PageCopy := Copier.CopyPage(ASource.Pages[PageIdx].Dict);
        Pages[I] := PageCopy;
      end;
    finally
      Copier.Free;
    end;

    BuildAndWrite(Pages, Objects, NextNum, AOutput);
  finally
    Objects.Free;
  end;
end;

class procedure TPDFPageOperations.ExtractPages(ASource: TPDFDocument;
  const APageIndices: TArray<Integer>; const APath: string);
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(APath, fmCreate);
  try
    ExtractPages(ASource, APageIndices, FS);
  finally
    FS.Free;
  end;
end;

// ===========================================================================
// DeletePages
// ===========================================================================

class procedure TPDFPageOperations.DeletePages(ASource: TPDFDocument;
  const APageIndices: TArray<Integer>; AOutput: TStream);
var
  DeleteSet: TDictionary<Integer, Boolean>;
  Kept:      TArray<Integer>;
  I:         Integer;
begin
  DeleteSet := TDictionary<Integer, Boolean>.Create;
  try
    for I in APageIndices do
      DeleteSet.AddOrSetValue(I, True);

    SetLength(Kept, 0);
    for I := 0 to ASource.PageCount - 1 do
      if not DeleteSet.ContainsKey(I) then
      begin
        SetLength(Kept, Length(Kept) + 1);
        Kept[High(Kept)] := I;
      end;
  finally
    DeleteSet.Free;
  end;

  if Length(Kept) = 0 then
    raise EPDFError.Create('DeletePages: all pages would be deleted');

  ExtractPages(ASource, Kept, AOutput);
end;

class procedure TPDFPageOperations.DeletePages(ASource: TPDFDocument;
  const APageIndices: TArray<Integer>; const APath: string);
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(APath, fmCreate);
  try
    DeletePages(ASource, APageIndices, FS);
  finally
    FS.Free;
  end;
end;

// ===========================================================================
// ReorderPages
// ===========================================================================

class procedure TPDFPageOperations.ReorderPages(ASource: TPDFDocument;
  const ANewOrder: TArray<Integer>; AOutput: TStream);
begin
  ExtractPages(ASource, ANewOrder, AOutput);
end;

class procedure TPDFPageOperations.ReorderPages(ASource: TPDFDocument;
  const ANewOrder: TArray<Integer>; const APath: string);
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(APath, fmCreate);
  try
    ReorderPages(ASource, ANewOrder, FS);
  finally
    FS.Free;
  end;
end;

// ===========================================================================
// Merge
// ===========================================================================

class procedure TPDFPageOperations.Merge(const ASources: TArray<TPDFDocument>;
  AOutput: TStream);
var
  Objects:   TObjectDictionary<Integer, TPDFObject>;
  NextNum:   Integer;
  Pages:     TArray<TPDFDictionary>;
  DocIdx:    Integer;
  Doc:       TPDFDocument;
  Copier:    TPDFObjectCopier;
  I:         Integer;
  Prefix:    string;
  PageCopy:  TPDFDictionary;
  Renames:    TDictionary<string, string>;
  ContentObj: TPDFObject;
  ContentArr: TPDFArray;

  // Patch a stream already stored in Objects under ARefNum.
  procedure PatchRefStream(ARefNum: Integer);
  var
    StmObj: TPDFObject;
    Stm:    TPDFStream;
    Patched: TBytes;
  begin
    if not Objects.TryGetValue(ARefNum, StmObj) then Exit;
    if not StmObj.IsStream then Exit;
    Stm     := TPDFStream(StmObj);
    Patched := PatchContentStream(Stm.DecodedBytes, Renames);
    Stm.Dict.Remove('Filter');
    Stm.Dict.Remove('DecodeParms');
    Stm.SetRawData(Patched);
  end;

begin
  if Length(ASources) = 0 then
    raise EPDFError.Create('Merge: no source documents');

  Objects := TObjectDictionary<Integer, TPDFObject>.Create([doOwnsValues]);
  try
    NextNum := 1;
    SetLength(Pages, 0);

    for DocIdx := 0 to High(ASources) do
    begin
      Doc    := ASources[DocIdx];
      Prefix := Format('_D%d_', [DocIdx]);
      Copier := TPDFObjectCopier.Create(Doc.Resolver, Objects, @NextNum);
      try
        for I := 0 to Doc.PageCount - 1 do
        begin
          PageCopy := Copier.CopyPage(Doc.Pages[I].Dict);

          // Rename all resources in this page with the document prefix
          // to prevent cross-document name collisions.
          Renames := PrefixPageResources(PageCopy, Prefix);
          try
            if Renames.Count > 0 then
            begin
              // Patch /Contents stream(s).
              // Copied references in PageCopy have no resolver — look up in Objects.
              ContentObj := PageCopy.RawGet('Contents');
              if ContentObj <> nil then
              begin
                if ContentObj.IsReference then
                  PatchRefStream(TPDFReference(ContentObj).RefID.Number)
                else if ContentObj.IsArray then
                begin
                  ContentArr := TPDFArray(ContentObj);
                  for var J := 0 to ContentArr.Count - 1 do
                  begin
                    var Item := ContentArr.Items(J);
                    if Item.IsReference then
                      PatchRefStream(TPDFReference(Item).RefID.Number);
                  end;
                end;
              end;
            end;
          finally
            Renames.Free;
          end;

          SetLength(Pages, Length(Pages) + 1);
          Pages[High(Pages)] := PageCopy;
        end;
      finally
        Copier.Free;
      end;
    end;

    BuildAndWrite(Pages, Objects, NextNum, AOutput);
  finally
    Objects.Free;
  end;
end;

class procedure TPDFPageOperations.Merge(const ASources: TArray<TPDFDocument>;
  const APath: string);
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(APath, fmCreate);
  try
    Merge(ASources, FS);
  finally
    FS.Free;
  end;
end;

class procedure TPDFPageOperations.MergeFiles(const AFiles: TArray<string>;
  const AOutput: string);
var
  Docs:   TArray<TPDFDocument>;
  I:      Integer;
begin
  SetLength(Docs, Length(AFiles));
  try
    for I := 0 to High(AFiles) do
    begin
      Docs[I] := TPDFDocument.Create;
      Docs[I].LoadFromFile(AFiles[I]);
    end;
    Merge(Docs, AOutput);
  finally
    for I := 0 to High(Docs) do
      Docs[I].Free;
  end;
end;

// ===========================================================================
// RotatePages
// ===========================================================================

class procedure TPDFPageOperations.RotatePages(ASource: TPDFDocument;
  ARotation: Integer; const APageIndices: TArray<Integer>);
var
  ApplyAll:   Boolean;
  PageIdx:    Integer;
  I:          Integer;
  Page:       TPDFPage;
  Current:    Integer;
  NewRot:     Integer;
begin
  if (ARotation mod 90) <> 0 then
    raise EPDFError.Create('RotatePages: rotation must be a multiple of 90');

  ApplyAll := Length(APageIndices) = 0;

  if ApplyAll then
  begin
    for I := 0 to ASource.PageCount - 1 do
    begin
      Page    := ASource.Pages[I];
      Current := Page.Dict.GetAsInteger('Rotate', 0);
      NewRot  := ((Current + ARotation) mod 360 + 360) mod 360;
      Page.Dict.SetValue('Rotate', TPDFInteger.Create(NewRot));
    end;
  end
  else
  begin
    for PageIdx in APageIndices do
    begin
      if (PageIdx < 0) or (PageIdx >= ASource.PageCount) then
        raise EPDFPageNotFoundError.CreateFmt(
          'RotatePages: page index %d out of range', [PageIdx]);
      Page    := ASource.Pages[PageIdx];
      Current := Page.Dict.GetAsInteger('Rotate', 0);
      NewRot  := ((Current + ARotation) mod 360 + 360) mod 360;
      Page.Dict.SetValue('Rotate', TPDFInteger.Create(NewRot));
    end;
  end;
end;

end.
