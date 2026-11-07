unit uPDF.SignatureWriter;

{$SCOPEDENUMS ON}

// ============================================================================
// TPDFSignatureWriter — PAdES signing without a crypto dependency
//
// Adds a signature to an existing PDF as an incremental update (ISO 32000-1
// §12.8, ETSI EN 319 142 PAdES): the original bytes are kept as they are and
// a new section appends
//   - the signature dictionary (/Type /Sig, /SubFilter /ETSI.CAdES.detached,
//     /ByteRange, /Contents with a zero-filled hole, /M, /Name, /Reason),
//   - an invisible signature widget on page 1 (its /Annots is extended),
//   - the catalog with /AcroForm (/Fields + /SigFlags 3).
// Then /ByteRange is patched with the real offsets, the signed bytes (all of
// the file except the /Contents hole) are handed to ASign, and the returned
// CMS (DER, detached) is written into the hole as hex.
//
// The CMS is built by the caller (OpenSSL, a token agent, a remote signer):
// this unit only knows PDF. Each call adds one more signature, so signing a
// signed file again gives a co-signature (both stay valid).
//
//   var Opts := TPDFSignatureOptions.Defaults;
//   Opts.Name := 'Ana Pérez';
//   Opts.Reason := 'Aprobación';
//   Signed := TPDFSignatureWriter.Sign(PdfBytes, Opts,
//     function(const AData: TBytes): TBytes
//     begin
//       Result := MyCmsSignDetached(AData);   // DER
//     end);
//
// TPDFSignatureReader.Read lists the signatures of a file with what a verifier
// needs: the bytes covered by /ByteRange and the CMS from /Contents.
// ============================================================================

interface

uses
  System.SysUtils, System.Classes, System.DateUtils, System.Math,
  System.Generics.Collections,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Document, uPDF.IncrementalUpdate;

type
  /// returns the detached CMS (DER) over the given bytes
  TPDFSignFunc = reference to function(const AData: TBytes): TBytes;

  TPDFSignatureOptions = record
    Name: string;          // /Name (signer)
    Reason: string;        // /Reason
    Location: string;      // /Location
    ContactInfo: string;   // /ContactInfo
    SigningTime: TDateTime; // /M, local time; 0 = now
    UtcOffsetMinutes: Integer; // for /M (e.g. -300 for Colombia)
    FieldName: string;     // '' = "Firma<n>"
    /// bytes reserved for the CMS (the hex hole is twice this); must hold the
    /// signature, certificates and the timestamp token
    ContentsSize: Integer;
    class function Defaults: TPDFSignatureOptions; static;
  end;

  TPDFSignatureWriter = class
  public
    class function Sign(const ASource: TBytes; const AOptions: TPDFSignatureOptions;
      const ASign: TPDFSignFunc): TBytes; static;
  end;

  TPDFFoundSignature = record
    FieldName: string;
    SubFilter: string;
    Name: string;
    Reason: string;
    SigningTime: string;    // raw /M
    ByteRange: array[0..3] of Int64;
    /// true if the signature covers the whole file up to its own end
    /// (a later incremental update is allowed: it is a newer revision)
    CoversRevision: Boolean;
    RevisionEnd: Int64;     // ByteRange[2] + ByteRange[3]
    Cms: TBytes;            // /Contents without the zero padding
    SignedData: TBytes;     // the bytes covered by /ByteRange
  end;

  TPDFSignatureReader = class
  public
    class function Read(const APdf: TBytes): TArray<TPDFFoundSignature>; static;
  end;

implementation

const
  BR_PLACEHOLDER = 9999999999; // 10 digits: the patch never needs more room

// UTF-16BE with BOM: the safe text string for any language (ISO 32000 §7.9.2.2)
function TextString(const S: string): TPDFString;
var
  B: RawByteString;
  I: Integer;
begin
  SetLength(B, 2 + Length(S) * 2);
  B[1] := #$FE;
  B[2] := #$FF;
  for I := 1 to Length(S) do
  begin
    B[1 + I * 2] := AnsiChar(Ord(S[I]) shr 8);
    B[2 + I * 2] := AnsiChar(Ord(S[I]) and $FF);
  end;
  Result := TPDFString.Create(B, True);
end;

function PdfDate(ATime: TDateTime; AOffsetMin: Integer): string;
var
  Sign: Char;
  Off: Integer;
begin
  Off := Abs(AOffsetMin);
  if AOffsetMin < 0 then Sign := '-' else Sign := '+';
  Result := 'D:' + FormatDateTime('yyyymmddhhnnss', ATime) +
    Format('%s%.2d''%.2d''', [Sign, Off div 60, Off mod 60]);
end;

function Ascii(const S: string): RawByteString;
begin
  Result := RawByteString(S);
end;

/// position of ANeedle in AHay starting at AFrom (0-based); -1 if absent
function FindBytes(const AHay: TBytes; const ANeedle: RawByteString; AFrom: Integer): Integer;
var
  I, J, N: Integer;
begin
  N := Length(ANeedle);
  for I := Max(AFrom, 0) to Length(AHay) - N do
  begin
    J := 0;
    while (J < N) and (AHay[I + J] = Ord(ANeedle[J + 1])) do
      Inc(J);
    if J = N then
      Exit(I);
  end;
  Result := -1;
end;

/// the first leaf of the page tree
function FirstPage(ANode: TPDFDictionary): TPDFDictionary;
var
  Kids: TPDFObject;
  Depth: Integer;
begin
  Result := ANode;
  Depth := 0;
  while (Result <> nil) and (Result.GetAsName('Type') = 'Pages') and (Depth < 64) do
  begin
    Kids := Result.Get('Kids');
    if (Kids = nil) or not Kids.IsArray or (TPDFArray(Kids).Count = 0) then
      Exit(nil);
    Kids := TPDFArray(Kids).Get(0);
    if (Kids = nil) or not Kids.IsDictionary then
      Exit(nil);
    Result := TPDFDictionary(Kids);
    Inc(Depth);
  end;
end;

class function TPDFSignatureOptions.Defaults: TPDFSignatureOptions;
begin
  Result := Default(TPDFSignatureOptions);
  Result.ContentsSize := 32768;
  Result.UtcOffsetMinutes := -300;
end;

{ TPDFSignatureWriter }

class function TPDFSignatureWriter.Sign(const ASource: TBytes;
  const AOptions: TPDFSignatureOptions; const ASign: TPDFSignFunc): TBytes;
var
  Upd: TPDFIncrementalUpdater;
  Doc: TPDFDocument;
  CatNum, PageNum, SigNum, FieldNum, I, N, FieldCount: Integer;
  SigDict, Field, NewCat, NewPage, AcroForm, PageDict: TPDFDictionary;
  Fields, Annots, BR, Rect: TPDFArray;
  Old: TPDFObject;
  Out_: TBytesStream;
  Buf, Signed, Cms: TBytes;
  P, BrOpen, BrClose, CtOpen, CtClose, SigStart: Integer;
  BrText: RawByteString;
  Hex: string;
  Opt: TPDFSignatureOptions;
begin
  Opt := AOptions;
  if Opt.ContentsSize <= 0 then
    Opt.ContentsSize := 32768;
  if Opt.SigningTime = 0 then
    Opt.SigningTime := Now;
  Upd := TPDFIncrementalUpdater.Create(ASource);
  try
    Doc := Upd.Document;
    if Doc.IsEncrypted then
      raise EPDFError.Create('PDF cifrado: no se firma');
    if Doc.PageCount = 0 then
      raise EPDFError.Create('PDF sin páginas');
    CatNum := Doc.Catalog.ID.Number;
    if CatNum <= 0 then
    begin
      Old := Doc.Trailer.RawGet('Root');
      if (Old <> nil) and Old.IsReference then
        CatNum := TPDFReference(Old).RefID.Number;
    end;
    // the first page object as it is in the file (Pages[0].Dict is a merged
    // copy): down /Pages -> /Kids[0]; resolved objects carry their number
    PageDict := FirstPage(Doc.Catalog.GetAsDictionary('Pages'));
    if PageDict = nil then
      raise EPDFError.Create('no se pudo leer la página 1');
    PageNum := PageDict.ID.Number;
    if (CatNum <= 0) or (PageNum <= 0) then
      raise EPDFError.Create('el catálogo o la página 1 no son objetos indirectos');

    // existing AcroForm fields (a previous signature, a form)
    FieldCount := 0;
    AcroForm := Doc.Catalog.GetAsDictionary('AcroForm');
    if AcroForm <> nil then
    begin
      Old := AcroForm.Get('Fields');
      if (Old <> nil) and Old.IsArray then
        FieldCount := TPDFArray(Old).Count;
    end;

    // 1. the signature dictionary, with placeholders
    SigDict := TPDFDictionary.Create;
    SigDict.SetValue('Type', TPDFName.Create('Sig'));
    SigDict.SetValue('Filter', TPDFName.Create('Adobe.PPKLite'));
    SigDict.SetValue('SubFilter', TPDFName.Create('ETSI.CAdES.detached'));
    BR := TPDFArray.Create;
    for I := 0 to 3 do
      BR.Add(TPDFInteger.Create(BR_PLACEHOLDER));
    SigDict.SetValue('ByteRange', BR);
    SigDict.SetValue('Contents', TPDFString.Create(
      RawByteString(StringOfChar(#0, Opt.ContentsSize)), True));
    SigDict.SetValue('M', TPDFString.Create(Ascii(PdfDate(Opt.SigningTime, Opt.UtcOffsetMinutes))));
    if Opt.Name <> '' then SigDict.SetValue('Name', TextString(Opt.Name));
    if Opt.Reason <> '' then SigDict.SetValue('Reason', TextString(Opt.Reason));
    if Opt.Location <> '' then SigDict.SetValue('Location', TextString(Opt.Location));
    if Opt.ContactInfo <> '' then SigDict.SetValue('ContactInfo', TextString(Opt.ContactInfo));
    SigNum := Upd.AddObject(SigDict);

    // 2. the (invisible) signature field + widget on page 1
    Field := TPDFDictionary.Create;
    Field.SetValue('Type', TPDFName.Create('Annot'));
    Field.SetValue('Subtype', TPDFName.Create('Widget'));
    Field.SetValue('FT', TPDFName.Create('Sig'));
    if Opt.FieldName <> '' then
      Field.SetValue('T', TextString(Opt.FieldName))
    else
      Field.SetValue('T', TPDFString.Create(Ascii('Firma' + IntToStr(FieldCount + 1))));
    Field.SetValue('V', TPDFReference.CreateNum(SigNum, 0));
    Rect := TPDFArray.Create;
    for I := 0 to 3 do
      Rect.Add(TPDFInteger.Create(0));
    Field.SetValue('Rect', Rect);
    Field.SetValue('F', TPDFInteger.Create(132)); // print + locked
    Field.SetValue('P', TPDFReference.CreateNum(PageNum, 0));
    FieldNum := Upd.AddObject(Field);

    // 3. page 1 with the widget in /Annots
    NewPage := TPDFDictionary(PageDict.Clone);
    Annots := TPDFArray.Create;
    Old := PageDict.Get('Annots');
    if (Old <> nil) and Old.IsArray then
      for I := 0 to TPDFArray(Old).Count - 1 do
        Annots.Add(TPDFArray(Old).Items(I).Clone);
    Annots.Add(TPDFReference.CreateNum(FieldNum, 0));
    NewPage.SetValue('Annots', Annots);
    Upd.ReplaceObject(PageNum, NewPage);

    // 4. catalog with /AcroForm (direct dictionary)
    NewCat := TPDFDictionary(Doc.Catalog.Clone);
    if AcroForm <> nil then
      AcroForm := TPDFDictionary(AcroForm.Clone)
    else
      AcroForm := TPDFDictionary.Create;
    Fields := TPDFArray.Create;
    Old := AcroForm.Get('Fields');
    if (Old <> nil) and Old.IsArray then
      for I := 0 to TPDFArray(Old).Count - 1 do
        Fields.Add(TPDFArray(Old).Items(I).Clone);
    Fields.Add(TPDFReference.CreateNum(FieldNum, 0));
    AcroForm.SetValue('Fields', Fields);
    AcroForm.SetValue('SigFlags', TPDFInteger.Create(3));
    NewCat.SetValue('AcroForm', AcroForm);
    Upd.ReplaceObject(CatNum, NewCat);

    Out_ := TBytesStream.Create;
    try
      Upd.SaveToStream(Out_);
      Buf := Copy(Out_.Bytes, 0, Out_.Size);
    finally
      Out_.Free;
    end;
  finally
    Upd.Free;
  end;

  // 5. find the placeholders inside the new signature object
  SigStart := FindBytes(Buf, Ascii(Format('%d 0 obj', [SigNum])), Length(ASource));
  if SigStart < 0 then
    raise EPDFError.Create('no se encontró el objeto de la firma');
  P := FindBytes(Buf, '/ByteRange', SigStart);
  BrOpen := FindBytes(Buf, '[', P);
  BrClose := FindBytes(Buf, ']', BrOpen);
  P := FindBytes(Buf, '/Contents', SigStart);
  CtOpen := FindBytes(Buf, '<', P);
  CtClose := FindBytes(Buf, '>', CtOpen);
  if (P < 0) or (BrOpen < 0) or (BrClose < 0) or (CtOpen < 0) or (CtClose < 0) or
     (CtClose - CtOpen - 1 <> Opt.ContentsSize * 2) then
    raise EPDFError.Create('no se encontraron /ByteRange y /Contents');

  // 6. the real /ByteRange, padded with spaces to the same width
  BrText := Ascii(Format('0 %d %d %d', [CtOpen, CtClose + 1, Length(Buf) - (CtClose + 1)]));
  N := BrClose - BrOpen - 1;
  if Length(BrText) > N then
    raise EPDFError.Create('/ByteRange no cabe');
  for I := 0 to N - 1 do
    if I < Length(BrText) then
      Buf[BrOpen + 1 + I] := Ord(BrText[I + 1])
    else
      Buf[BrOpen + 1 + I] := Ord(' ');

  // 7. sign everything but the hole
  SetLength(Signed, CtOpen + (Length(Buf) - (CtClose + 1)));
  Move(Buf[0], Signed[0], CtOpen);
  if Length(Buf) - (CtClose + 1) > 0 then
    Move(Buf[CtClose + 1], Signed[CtOpen], Length(Buf) - (CtClose + 1));
  Cms := ASign(Signed);
  if Length(Cms) = 0 then
    raise EPDFError.Create('la firma vino vacía');
  if Length(Cms) > Opt.ContentsSize then
    raise EPDFError.CreateFmt('la firma (%d bytes) no cabe en el espacio reservado (%d)',
      [Length(Cms), Opt.ContentsSize]);
  Hex := '';
  for I := 0 to High(Cms) do
    Hex := Hex + IntToHex(Cms[I], 2);
  for I := 1 to Length(Hex) do
    Buf[CtOpen + I] := Ord(Hex[I]);
  Result := Buf;
end;

{ TPDFSignatureReader }

class function TPDFSignatureReader.Read(const APdf: TBytes): TArray<TPDFFoundSignature>;
var
  Doc: TPDFDocument;
  Stm: TBytesStream;
  AcroForm, Field, V: TPDFDictionary;
  Fields, BR: TPDFArray;
  Obj: TPDFObject;
  I, K, L: Integer;
  S: TPDFFoundSignature;
  Raw: RawByteString;
  List: TList<TPDFFoundSignature>;
  Len: Int64;
begin
  List := TList<TPDFFoundSignature>.Create;
  Stm := TBytesStream.Create(APdf);
  Doc := TPDFDocument.Create;
  try
    Doc.LoadFromStream(Stm);
    AcroForm := Doc.Catalog.GetAsDictionary('AcroForm');
    if AcroForm <> nil then
    begin
      Obj := AcroForm.Get('Fields');
      if (Obj <> nil) and Obj.IsArray then
      begin
        Fields := TPDFArray(Obj);
        for I := 0 to Fields.Count - 1 do
        begin
          Obj := Fields.Get(I);
          if (Obj = nil) or not Obj.IsDictionary then Continue;
          Field := TPDFDictionary(Obj);
          if Field.GetAsName('FT') <> 'Sig' then Continue;
          V := Field.GetAsDictionary('V');
          if V = nil then Continue;
          S := Default(TPDFFoundSignature);
          Obj := Field.Get('T');
          if (Obj <> nil) and Obj.IsString then S.FieldName := Obj.AsUnicodeString;
          S.SubFilter := V.GetAsName('SubFilter');
          Obj := V.Get('Name');
          if (Obj <> nil) and Obj.IsString then S.Name := Obj.AsUnicodeString;
          Obj := V.Get('Reason');
          if (Obj <> nil) and Obj.IsString then S.Reason := Obj.AsUnicodeString;
          Obj := V.Get('M');
          if (Obj <> nil) and Obj.IsString then S.SigningTime := string(Obj.AsString);
          Obj := V.Get('ByteRange');
          if (Obj = nil) or not Obj.IsArray or (TPDFArray(Obj).Count <> 4) then Continue;
          BR := TPDFArray(Obj);
          for K := 0 to 3 do
            S.ByteRange[K] := BR.GetAsInteger(K);
          Len := Length(APdf);
          if (S.ByteRange[0] <> 0) or (S.ByteRange[1] < 0) or (S.ByteRange[2] < S.ByteRange[1]) or
             (S.ByteRange[3] < 0) or (S.ByteRange[2] + S.ByteRange[3] > Len) then Continue;
          S.RevisionEnd := S.ByteRange[2] + S.ByteRange[3];
          S.CoversRevision := True;
          // the CMS from /Contents, without the zero padding of the hole
          Obj := V.Get('Contents');
          if (Obj = nil) or not Obj.IsString then Continue;
          Raw := Obj.AsString;
          L := Length(Raw);
          // DER length of the outer SEQUENCE gives the real size
          if (L > 4) and (Ord(Raw[1]) = $30) then
          begin
            if Ord(Raw[2]) < $80 then
              L := Min(L, 2 + Ord(Raw[2]))
            else
            begin
              K := Ord(Raw[2]) and $7F;
              var Total: Int64 := 0;
              for var J := 1 to K do
                Total := (Total shl 8) or Ord(Raw[2 + J]);
              L := Min(L, 2 + K + Total);
            end;
          end;
          SetLength(S.Cms, L);
          if L > 0 then
            Move(Raw[1], S.Cms[0], L);
          SetLength(S.SignedData, S.ByteRange[1] + S.ByteRange[3]);
          Move(APdf[0], S.SignedData[0], S.ByteRange[1]);
          if S.ByteRange[3] > 0 then
            Move(APdf[S.ByteRange[2]], S.SignedData[S.ByteRange[1]], S.ByteRange[3]);
          List.Add(S);
        end;
      end;
    end;
    Result := List.ToArray;
  finally
    Doc.Free;
    Stm.Free;
    List.Free;
  end;
end;

end.
