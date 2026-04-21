unit uPDF.PageCopy;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Generics.Collections,
  uPDF.Types, uPDF.Errors, uPDF.Objects;

type
  // ---------------------------------------------------------------------------
  // TPDFObjectCopier
  //
  // Copies a page (and every object reachable from it) from a source document
  // into a caller-supplied dest object map.  All indirect references are
  // resolved, deep-cloned, and assigned fresh object numbers that are unique
  // within ADest.
  //
  // Typical usage — see uPDF.PageOperations for complete examples:
  //
  //   var Dest     : TDictionary<Integer, TPDFObject>;
  //   var NextNum  : Integer := 1;
  //   var Copier   := TPDFObjectCopier.Create(SrcDoc.Resolver, Dest, @NextNum);
  //   try
  //     var PageCopy := Copier.CopyPage(SrcDoc.Pages[I].Dict);
  //     var PageNum  := NextNum; Inc(NextNum);
  //     Dest[PageNum] := PageCopy;
  //   finally
  //     Copier.Free;
  //   end;
  // ---------------------------------------------------------------------------
  TPDFObjectCopier = class
  private
    FResolver:   IObjectResolver;
    FDest:       TDictionary<Integer, TPDFObject>;
    FRemap:      TDictionary<Integer, Integer>;  // src obj# → dest obj#
    FNextObjNum: PInteger;

    function  AllocNum: Integer; inline;

    // Deep-copy AObj, turning every embedded TPDFReference into a new reference
    // that points to a freshly-allocated copy in FDest.
    // Does NOT add the returned object itself to FDest — caller does that.
    function  DeepCopyInline(AObj: TPDFObject): TPDFObject;

    // Guarantee that source indirect object ASrcNum is present in FDest.
    // Returns a TPDFReference (owned by caller) pointing to the dest copy.
    function  EnsureCopied(ASrcNum: Integer): TPDFReference;

  public
    constructor Create(AResolver: IObjectResolver;
                       ADest: TDictionary<Integer, TPDFObject>;
                       ANextObjNum: PInteger);
    destructor  Destroy; override;

    // Copy a page dict and all reachable objects.
    // /Parent is stripped (caller sets it when building the new page tree).
    // Returns the new page dict; the caller must assign it an obj# and add it
    // to FDest.
    function  CopyPage(APageDict: TPDFDictionary): TPDFDictionary;

    // Copy an arbitrary object graph rooted at ASrcNum into FDest.
    // Returns the dest reference (new number).  Idempotent: calling twice for
    // the same source number returns the same reference without re-copying.
    function  CopyObject(ASrcNum: Integer): TPDFReference;

    // Query the remap table: given a source object number, return the
    // corresponding dest object number.  Returns False if not yet copied.
    function  GetDestNum(ASrcNum: Integer; out ADestNum: Integer): Boolean;

    // Merge all resource sub-dicts from ASrcRes into ADstRes.
    // When a name already exists in a sub-dict, it is renamed to APrefix+name.
    // Returns a map of renamed keys: original name → renamed name (only changed).
    // Ownership of ADstRes entries stays with the dict; caller must not free them.
    function  MergeResources(ASrcRes, ADstRes: TPDFDictionary;
                             const APrefix: string): TDictionary<string, string>;
  end;

implementation

// Resource sub-dict types that need name-collision handling during merge
const
  RESOURCE_SUBDICTS: array[0..5] of string = (
    'Font', 'XObject', 'ColorSpace', 'ExtGState', 'Pattern', 'Shading'
  );

// ---------------------------------------------------------------------------
// TPDFObjectCopier
// ---------------------------------------------------------------------------

constructor TPDFObjectCopier.Create(AResolver: IObjectResolver;
  ADest: TDictionary<Integer, TPDFObject>; ANextObjNum: PInteger);
begin
  inherited Create;
  FResolver   := AResolver;
  FDest       := ADest;
  FRemap      := TDictionary<Integer, Integer>.Create;
  FNextObjNum := ANextObjNum;
end;

destructor TPDFObjectCopier.Destroy;
begin
  FRemap.Free;
  inherited;
end;

function TPDFObjectCopier.AllocNum: Integer;
begin
  Result := FNextObjNum^;
  Inc(FNextObjNum^);
end;

// ---------------------------------------------------------------------------
// EnsureCopied
// ---------------------------------------------------------------------------

function TPDFObjectCopier.EnsureCopied(ASrcNum: Integer): TPDFReference;
var
  DestNum: Integer;
  SrcObj:  TPDFObject;
  Copy:    TPDFObject;
begin
  // If already remapped (or currently being remapped — cycle guard), return ref.
  if FRemap.TryGetValue(ASrcNum, DestNum) then
    Exit(TPDFReference.CreateNum(DestNum, 0));

  // Resolve the source object.
  if FResolver = nil then
    raise EPDFObjectError.CreateFmt(
      'PageCopy: no resolver — cannot copy reference %d', [ASrcNum]);

  SrcObj := FResolver.ResolveNumber(ASrcNum, 0);
  if SrcObj = nil then
  begin
    // Unresolvable reference — emit a null placeholder.
    DestNum := AllocNum;
    FRemap.Add(ASrcNum, DestNum);
    FDest.AddOrSetValue(DestNum, TPDFNull.Instance.Clone);
    Exit(TPDFReference.CreateNum(DestNum, 0));
  end;

  // Allocate destination number BEFORE recursing to break potential cycles.
  DestNum := AllocNum;
  FRemap.Add(ASrcNum, DestNum);

  // Deep-copy the resolved object and store in dest map.
  Copy := DeepCopyInline(SrcObj);
  FDest.AddOrSetValue(DestNum, Copy);

  Result := TPDFReference.CreateNum(DestNum, 0);
end;

// ---------------------------------------------------------------------------
// DeepCopyInline
// ---------------------------------------------------------------------------

function TPDFObjectCopier.DeepCopyInline(AObj: TPDFObject): TPDFObject;
var
  Arr:     TPDFArray;
  NewArr:  TPDFArray;
  Dict:    TPDFDictionary;
  NewDict: TPDFDictionary;
  Stm:     TPDFStream;
  NewStm:  TPDFStream;
  Ref:     TPDFReference;
  I:       Integer;
begin
  if AObj = nil then
    Exit(TPDFNull.Instance.Clone);

  // Resolve any outer reference before dispatching.
  if AObj.IsReference then
  begin
    Ref    := TPDFReference(AObj);
    Result := EnsureCopied(Ref.RefID.Number);
    Exit;
  end;

  case AObj.Kind of
    // Scalars: Clone produces a fully independent copy.
    TPDFObjectKind.Null,
    TPDFObjectKind.Boolean,
    TPDFObjectKind.Integer,
    TPDFObjectKind.Real,
    TPDFObjectKind.String_,
    TPDFObjectKind.Name:
      Result := AObj.Clone;

    TPDFObjectKind.Array_:
    begin
      Arr    := TPDFArray(AObj);
      NewArr := TPDFArray.Create;
      for I := 0 to Arr.Count - 1 do
        NewArr.Add(DeepCopyInline(Arr.Items(I)));
      Result := NewArr;
    end;

    TPDFObjectKind.Dictionary:
    begin
      Dict    := TPDFDictionary(AObj);
      NewDict := TPDFDictionary.Create;
      Dict.ForEach(procedure(Key: string; Val: TPDFObject)
      begin
        NewDict.SetValue(Key, DeepCopyInline(Val));
      end);
      Result := NewDict;
    end;

    TPDFObjectKind.Stream:
    begin
      Stm    := TPDFStream(AObj);
      NewStm := TPDFStream.Create;
      // Deep-copy the stream dict into the new stream's own empty dict.
      // /Length is recalculated by TPDFWriter; /Filter and /DecodeParms are
      // stripped so the writer can apply fresh compression on the decoded bytes.
      Stm.Dict.ForEach(procedure(Key: string; Val: TPDFObject)
      begin
        if (Key <> 'Length') and (Key <> 'Filter') and (Key <> 'DecodeParms') then
          NewStm.Dict.SetValue(Key, DeepCopyInline(Val));
      end);
      // Store decoded (and decrypted) bytes — safe regardless of source encryption.
      NewStm.SetRawData(Stm.DecodedBytes);
      Result := NewStm;
    end;

  else
    // Fallback (should not happen for well-formed PDFs).
    Result := AObj.Clone;
  end;
end;

// ---------------------------------------------------------------------------
// CopyPage
// ---------------------------------------------------------------------------

function TPDFObjectCopier.CopyPage(APageDict: TPDFDictionary): TPDFDictionary;
var
  NewDict: TPDFDictionary;
  Keys:    TArray<string>;
  Key:     string;
  Val:     TPDFObject;
begin
  NewDict := TPDFDictionary.Create;

  // Copy all page keys except structural tree entries.
  // /Parent is stripped — caller rebuilds the page tree.
  Keys := APageDict.Keys;
  for Key in Keys do
  begin
    if (Key = 'Parent') or (Key = 'Kids') or (Key = 'Count') then
      Continue;

    Val := APageDict.RawGet(Key);
    if Val <> nil then
      NewDict.SetValue(Key, DeepCopyInline(Val));
  end;

  Result := NewDict;
end;

// ---------------------------------------------------------------------------
// MergeResources
// ---------------------------------------------------------------------------

function TPDFObjectCopier.MergeResources(ASrcRes, ADstRes: TPDFDictionary;
  const APrefix: string): TDictionary<string, string>;
var
  SubType:    string;
  SrcSub:     TPDFDictionary;
  DstSub:     TPDFDictionary;
  SrcKeys:    TArray<string>;
  SrcKey:     string;
  DstKey:     string;
  SrcVal:     TPDFObject;
  CopiedVal:  TPDFObject;
begin
  Result := TDictionary<string, string>.Create;

  if (ASrcRes = nil) or (ADstRes = nil) then
    Exit;

  for SubType in RESOURCE_SUBDICTS do
  begin
    // Resolve the source sub-dict for this resource type.
    var RawSrc := ASrcRes.RawGet(SubType);
    if RawSrc = nil then Continue;
    var Resolved := RawSrc.Dereference;
    if not Resolved.IsDictionary then Continue;
    SrcSub := TPDFDictionary(Resolved);

    // Get or create the dest sub-dict.
    var RawDst := ADstRes.RawGet(SubType);
    if (RawDst <> nil) and RawDst.Dereference.IsDictionary then
      DstSub := TPDFDictionary(RawDst.Dereference)
    else
    begin
      DstSub := TPDFDictionary.Create;
      ADstRes.SetValue(SubType, DstSub);
    end;

    // Merge each entry from the source sub-dict into the dest sub-dict.
    SrcKeys := SrcSub.Keys;
    for SrcKey in SrcKeys do
    begin
      SrcVal := SrcSub.RawGet(SrcKey);
      if SrcVal = nil then Continue;

      // Determine the dest key — rename on collision.
      if DstSub.Contains(SrcKey) then
      begin
        DstKey := APrefix + SrcKey;
        Result.AddOrSetValue(SubType + '/' + SrcKey, DstKey);
      end
      else
        DstKey := SrcKey;

      CopiedVal := DeepCopyInline(SrcVal);
      DstSub.SetValue(DstKey, CopiedVal);
    end;
  end;

  // /ProcSet is an array of names — union the two arrays.

  var SrcPS := ASrcRes.RawGet('ProcSet');
  if SrcPS <> nil then
  begin
    var ResolvedPS := SrcPS.Dereference;
    if ResolvedPS.IsArray then
    begin
      var SrcArr := TPDFArray(ResolvedPS);
      var DstPS  := ADstRes.RawGet('ProcSet');
      var DstArr: TPDFArray;
      if (DstPS <> nil) and DstPS.Dereference.IsArray then
        DstArr := TPDFArray(DstPS.Dereference)
      else
      begin
        DstArr := TPDFArray.Create;
        ADstRes.SetValue('ProcSet', DstArr);
      end;
      for var I := 0 to SrcArr.Count - 1 do
      begin
        var N := SrcArr.Items(I);
        if N.IsName then
        begin
          var Already := False;
          for var J := 0 to DstArr.Count - 1 do
            if DstArr.Items(J).IsName and
               (DstArr.Items(J).AsName = N.AsName) then
            begin
              Already := True;
              Break;
            end;
          if not Already then
            DstArr.Add(TPDFName.Create(N.AsName));
        end;
      end;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// CopyObject — public entry point for copying a named indirect object
// ---------------------------------------------------------------------------

function TPDFObjectCopier.CopyObject(ASrcNum: Integer): TPDFReference;
begin
  Result := EnsureCopied(ASrcNum);
end;

// ---------------------------------------------------------------------------
// GetDestNum — query the remap table
// ---------------------------------------------------------------------------

function TPDFObjectCopier.GetDestNum(ASrcNum: Integer;
  out ADestNum: Integer): Boolean;
begin
  Result := FRemap.TryGetValue(ASrcNum, ADestNum);
end;

end.
