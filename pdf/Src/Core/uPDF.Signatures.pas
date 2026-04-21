unit uPDF.Signatures;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Document,
  uPDF.AcroForms, uPDF.Crypto;

type
  // -------------------------------------------------------------------------
  // Hash verification outcome for one signature
  // -------------------------------------------------------------------------
  TPDFHashStatus = (
    NotChecked,   // No stream supplied; hash was not attempted
    Match,        // Hash over byte ranges matches messageDigest in PKCS#7
    Mismatch,     // Hash computed but does not match
    ParseError    // ByteRange, /Contents, or PKCS#7 structure could not be parsed
  );

  // -------------------------------------------------------------------------
  // One PDF signature
  // -------------------------------------------------------------------------
  TPDFSignatureInfo = record
    FieldName:     string;           // dotted AcroForm field name
    SignerName:    string;           // /Name (may be empty)
    SigningTime:   string;           // /M raw PDF date string (may be empty)
    Reason:        string;           // /Reason (may be empty)
    Location:      string;           // /Location (may be empty)
    SubFilter:     string;           // /SubFilter name
    HashAlgorithm: string;           // 'SHA-1', 'SHA-256', etc. (from PKCS#7 DER)
    HashStatus:    TPDFHashStatus;
  end;

  // -------------------------------------------------------------------------
  // TPDFSignatureVerifier
  //
  // Finds all AcroForm signature fields in a document, reads their metadata,
  // and (when AStream is provided) verifies that the byte-range hash matches
  // the messageDigest attribute embedded in the PKCS#7 /Contents blob.
  //
  // Usage:
  //   var FS := TFileStream.Create('signed.pdf', fmOpenRead);
  //   try
  //     var Doc := TPDFDocument.Create;
  //     try
  //       Doc.LoadFromStream(FS);
  //       FS.Seek(0, soBeginning);   // rewind before Verify
  //       for var Sig in TPDFSignatureVerifier.Verify(Doc, FS) do
  //         WriteLn(Format('%s  %s  %s',
  //           [Sig.FieldName, Sig.HashAlgorithm,
  //            TRttiEnumerationType.GetName(Sig.HashStatus)]));
  //     finally
  //       Doc.Free;
  //     end;
  //   finally
  //     FS.Free;
  //   end;
  // -------------------------------------------------------------------------
  TPDFSignatureVerifier = class
  private

    // --- Minimal DER/ASN.1 helpers -------------------------------------------

    // Read the BER/DER length field at D[Off]; advances Off past the length.
    // Returns -1 on parse error.
    class function DERReadLen(const D: TBytes;
      var Off: Integer): Integer; static;

    // Skip one complete TLV entry at D[Off]; advances Off past it.
    class function DERSkip(const D: TBytes;
      var Off: Integer): Boolean; static;

    // Scan D[AStart..AStart+ALen-1] recursively; when it finds a SEQUENCE
    // whose first child is the messageDigest OID, it extracts the OCTET STRING
    // value and writes it to ADigest, then returns immediately.
    class procedure ScanForDigest(const D: TBytes; AStart, ALen: Integer;
      var ADigest: TBytes); static;

    // Scan for the first OID matching a known hash algorithm in D[0..High(D)].
    // Returns 'SHA-1', 'SHA-256', 'SHA-384', or 'SHA-512' (empty string if none).
    class function FindHashAlgorithm(const D: TBytes): string; static;

    // --- Byte-range hashing --------------------------------------------------

    // Hash the two byte ranges from AStream using the given algorithm name.
    // Returns empty TBytes on error.
    class function HashRanges(AStream: TStream;
      B0, L0, B1, L1: Int64;
      const AAlgName: string): TBytes; static;

    // --- Per-signature processing --------------------------------------------

    // Fill AInfo from a resolved signature dictionary + optional raw stream.
    class procedure ProcessSigDict(ASigDict: TPDFDictionary;
      const AFieldName: string;
      AStream: TStream;
      out AInfo: TPDFSignatureInfo); static;

  public
    // Walk every AcroForm signature field in ADoc.
    // Pass AStream = nil to skip hash verification (HashStatus = NotChecked).
    // If AStream is provided it must be positioned at byte 0 of the PDF data
    // (i.e. the same stream from which ADoc was loaded).
    class function Verify(ADoc: TPDFDocument;
      AStream: TStream): TArray<TPDFSignatureInfo>; static;
  end;

implementation

// ===========================================================================
// DER helpers
// ===========================================================================

// ---------------------------------------------------------------------------
// DERReadLen
// Reads a BER/DER length encoding starting at D[Off].
// Short form: single byte 0x00..0x7F → length.
// Long form:  0x80|N followed by N big-endian bytes → length.
// Returns -1 on overflow or truncation.
// ---------------------------------------------------------------------------
class function TPDFSignatureVerifier.DERReadLen(const D: TBytes;
  var Off: Integer): Integer;
var
  B, N, I: Integer;
begin
  if Off >= Length(D) then Exit(-1);
  B := D[Off];
  Inc(Off);
  if (B and $80) = 0 then
    Exit(B);           // short form
  N := B and $7F;
  if (N = 0) or (N > 4) then Exit(-1);  // indefinite or > 4-byte length
  Result := 0;
  for I := 0 to N - 1 do
  begin
    if Off >= Length(D) then Exit(-1);
    Result := (Result shl 8) or D[Off];
    Inc(Off);
  end;
end;

// ---------------------------------------------------------------------------
// DERSkip — advance Off past one TLV entry
// ---------------------------------------------------------------------------
class function TPDFSignatureVerifier.DERSkip(const D: TBytes;
  var Off: Integer): Boolean;
var
  Len: Integer;
begin
  if Off >= Length(D) then Exit(False);
  Inc(Off);  // skip tag
  Len := DERReadLen(D, Off);
  if Len < 0 then Exit(False);
  Inc(Off, Len);
  Result := True;
end;

// ---------------------------------------------------------------------------
// ScanForDigest
//
// Recursively walks the DER tree looking for an Attribute SEQUENCE whose
// first child is the messageDigest OID ($2A $86 $48 $86 $F7 $0D $01 $09 $04),
// then extracts the first OCTET STRING from the following SET.
//
// Sets ADigest (non-empty) on the first successful find.
// ---------------------------------------------------------------------------
class procedure TPDFSignatureVerifier.ScanForDigest(const D: TBytes;
  AStart, ALen: Integer; var ADigest: TBytes);
const
  OID_MSG_DIGEST: array[0..8] of Byte =
    ($2A, $86, $48, $86, $F7, $0D, $01, $09, $04);
var
  Off, EndOff: Integer;
  Tag, ContentOff, ContentLen: Integer;
  OOff, OLen: Integer;
  SetOff, SetLen: Integer;
  OctetLen: Integer;
  K: Integer;
  Match: Boolean;
begin
  Off    := AStart;
  EndOff := AStart + ALen;

  while Off < EndOff do
  begin
    if Off >= Length(D) then Break;
    Tag := D[Off];
    Inc(Off);
    ContentLen := DERReadLen(D, Off);
    if ContentLen < 0 then Break;
    ContentOff := Off;

    // Check for Attribute SEQUENCE ($30) whose first child is the
    // messageDigest OID.
    if (Tag = $30) and (ContentLen >= 13) then
    begin
      OOff := ContentOff;
      // First child must be OID ($06) of length 9
      if (OOff + 1 < Length(D)) and (D[OOff] = $06) then
      begin
        Inc(OOff);
        OLen := DERReadLen(D, OOff);
        if (OLen = 9) and (OOff + OLen <= Length(D)) then
        begin
          Match := True;
          for K := 0 to 8 do
            if D[OOff + K] <> OID_MSG_DIGEST[K] then
            begin
              Match := False;
              Break;
            end;
          if Match then
          begin
            // Found the messageDigest Attribute.
            // Skip the OID value, then read the SET OF OCTET STRING.
            Inc(OOff, OLen);
            if (OOff < Length(D)) and (D[OOff] = $31) then
            begin
              Inc(OOff);
              SetLen := DERReadLen(D, OOff);
              SetOff := OOff;
              if (SetLen > 0) and (SetOff < Length(D)) and (D[SetOff] = $04) then
              begin
                Inc(SetOff);
                OctetLen := DERReadLen(D, SetOff);
                if (OctetLen > 0) and (SetOff + OctetLen <= Length(D)) then
                begin
                  SetLength(ADigest, OctetLen);
                  Move(D[SetOff], ADigest[0], OctetLen);
                  Exit;
                end;
              end;
            end;
          end;
        end;
      end;
    end;

    // Recurse into any constructed entry (bit 5 of tag set)
    if (Tag and $20) <> 0 then
    begin
      ScanForDigest(D, ContentOff, ContentLen, ADigest);
      if Length(ADigest) > 0 then Exit;
    end;

    Off := ContentOff + ContentLen;
  end;
end;

// ---------------------------------------------------------------------------
// FindHashAlgorithm
//
// Byte-scans the DER blob for any OID tag ($06) followed immediately by the
// encoded bytes of a known hash algorithm OID.  Returns the first match.
// This works because hash algorithm OIDs are recognizable and do not overlap
// with other OIDs appearing in PKCS#7 structures.
// ---------------------------------------------------------------------------
class function TPDFSignatureVerifier.FindHashAlgorithm(
  const D: TBytes): string;
const
  OID_SHA1:   array[0..4] of Byte = ($2B, $0E, $03, $02, $1A);
  OID_SHA256: array[0..8] of Byte = ($60, $86, $48, $01, $65, $03, $04, $02, $01);
  OID_SHA384: array[0..8] of Byte = ($60, $86, $48, $01, $65, $03, $04, $02, $02);
  OID_SHA512: array[0..8] of Byte = ($60, $86, $48, $01, $65, $03, $04, $02, $03);

  function CheckOID(I, OIDLen: Integer;
    const Pat: array of Byte; const Name: string): string;
  var K: Integer;
  begin
    Result := '';
    if OIDLen <> Length(Pat) then Exit;
    if I + 2 + OIDLen > Length(D) then Exit;
    for K := 0 to OIDLen - 1 do
      if D[I + 2 + K] <> Pat[K] then Exit;
    Result := Name;
  end;

var
  I, OIDLen: Integer;
  S: string;
begin
  Result := '';
  for I := 0 to Length(D) - 3 do
  begin
    if D[I] <> $06 then Continue;
    OIDLen := D[I + 1];
    if (OIDLen and $80) <> 0 then Continue;  // skip multi-byte length OIDs
    S := CheckOID(I, OIDLen, OID_SHA256, 'SHA-256');
    if S <> '' then Exit(S);
    S := CheckOID(I, OIDLen, OID_SHA384, 'SHA-384');
    if S <> '' then Exit(S);
    S := CheckOID(I, OIDLen, OID_SHA512, 'SHA-512');
    if S <> '' then Exit(S);
    S := CheckOID(I, OIDLen, OID_SHA1, 'SHA-1');
    if S <> '' then Exit(S);
  end;
end;

// ===========================================================================
// HashRanges
// ===========================================================================

class function TPDFSignatureVerifier.HashRanges(AStream: TStream;
  B0, L0, B1, L1: Int64; const AAlgName: string): TBytes;
var
  Buf: TBytes;
  Combined: TBytes;
  CombLen: Int64;
begin
  Result := nil;
  if AStream = nil then Exit;
  CombLen := L0 + L1;
  if CombLen <= 0 then Exit;

  SetLength(Combined, Integer(CombLen));

  // Read first range
  if L0 > 0 then
  begin
    AStream.Seek(B0, soBeginning);
    SetLength(Buf, Integer(L0));
    if AStream.Read(Buf[0], Integer(L0)) <> L0 then Exit;
    Move(Buf[0], Combined[0], Integer(L0));
  end;

  // Read second range
  if L1 > 0 then
  begin
    AStream.Seek(B1, soBeginning);
    SetLength(Buf, Integer(L1));
    if AStream.Read(Buf[0], Integer(L1)) <> L1 then Exit;
    Move(Buf[0], Combined[Integer(L0)], Integer(L1));
  end;

  if      AAlgName = 'SHA-256' then Result := CryptoSHA256(Combined)
  else if AAlgName = 'SHA-1'   then Result := CryptoSHA1(Combined)
  else if AAlgName = 'SHA-384' then Result := CryptoSHA384(Combined)
  else if AAlgName = 'SHA-512' then Result := CryptoSHA512(Combined);
end;

// ===========================================================================
// ProcessSigDict
// ===========================================================================

class procedure TPDFSignatureVerifier.ProcessSigDict(ASigDict: TPDFDictionary;
  const AFieldName: string; AStream: TStream;
  out AInfo: TPDFSignatureInfo);
var
  ByteRangeArr: TPDFArray;
  B0, L0, B1, L1: Int64;
  ContentsRaw: RawByteString;
  Contents: TBytes;
  Digest: TBytes;
  Computed: TBytes;
  I: Integer;
  MatchOK: Boolean;
begin
  AInfo := Default(TPDFSignatureInfo);
  AInfo.FieldName  := AFieldName;
  AInfo.HashStatus := TPDFHashStatus.NotChecked;

  if ASigDict = nil then
  begin
    AInfo.HashStatus := TPDFHashStatus.ParseError;
    Exit;
  end;

  // Metadata
  AInfo.SignerName  := ASigDict.GetAsUnicodeString('Name');
  AInfo.SigningTime := ASigDict.GetAsUnicodeString('M');
  AInfo.Reason      := ASigDict.GetAsUnicodeString('Reason');
  AInfo.Location    := ASigDict.GetAsUnicodeString('Location');
  AInfo.SubFilter   := ASigDict.GetAsName('SubFilter');

  if AStream = nil then Exit;   // HashStatus stays NotChecked

  // /ByteRange [b0 l0 b1 l1]
  ByteRangeArr := ASigDict.GetAsArray('ByteRange');
  if (ByteRangeArr = nil) or (ByteRangeArr.Count < 4) then
  begin
    AInfo.HashStatus := TPDFHashStatus.ParseError;
    Exit;
  end;
  B0 := Round(ByteRangeArr.GetAsNumber(0, -1));
  L0 := Round(ByteRangeArr.GetAsNumber(1, -1));
  B1 := Round(ByteRangeArr.GetAsNumber(2, -1));
  L1 := Round(ByteRangeArr.GetAsNumber(3, -1));
  if (B0 < 0) or (L0 <= 0) or (B1 < 0) or (L1 <= 0) then
  begin
    AInfo.HashStatus := TPDFHashStatus.ParseError;
    Exit;
  end;

  // /Contents — raw PKCS#7 DER bytes
  ContentsRaw := ASigDict.GetAsString('Contents');
  if Length(ContentsRaw) = 0 then
  begin
    AInfo.HashStatus := TPDFHashStatus.ParseError;
    Exit;
  end;
  SetLength(Contents, Length(ContentsRaw));
  Move(ContentsRaw[1], Contents[0], Length(ContentsRaw));

  // Identify hash algorithm from DER
  AInfo.HashAlgorithm := FindHashAlgorithm(Contents);

  // Fall back: infer from SubFilter when DER scan finds nothing
  if AInfo.HashAlgorithm = '' then
  begin
    if AInfo.SubFilter = 'adbe.pkcs7.sha1' then
      AInfo.HashAlgorithm := 'SHA-1'
    else
      AInfo.HashAlgorithm := 'SHA-256';   // safest modern default
  end;

  // Extract messageDigest from PKCS#7
  Digest := nil;
  ScanForDigest(Contents, 0, Length(Contents), Digest);
  if Length(Digest) = 0 then
  begin
    AInfo.HashStatus := TPDFHashStatus.ParseError;
    Exit;
  end;

  // Compute hash over the byte ranges
  Computed := HashRanges(AStream, B0, L0, B1, L1, AInfo.HashAlgorithm);
  if Length(Computed) = 0 then
  begin
    AInfo.HashStatus := TPDFHashStatus.ParseError;
    Exit;
  end;

  // Compare
  if Length(Computed) <> Length(Digest) then
  begin
    AInfo.HashStatus := TPDFHashStatus.Mismatch;
    Exit;
  end;
  MatchOK := True;
  for I := 0 to High(Computed) do
    if Computed[I] <> Digest[I] then
    begin
      MatchOK := False;
      Break;
    end;

  if MatchOK then
    AInfo.HashStatus := TPDFHashStatus.Match
  else
    AInfo.HashStatus := TPDFHashStatus.Mismatch;
end;

// ===========================================================================
// Verify
// ===========================================================================

class function TPDFSignatureVerifier.Verify(ADoc: TPDFDocument;
  AStream: TStream): TArray<TPDFSignatureInfo>;
var
  Form:    TPDFAcroForm;
  Field:   TPDFFormField;
  SigDict: TPDFDictionary;
  ValObj:  TPDFObject;
  Info:    TPDFSignatureInfo;
  Results: TList<TPDFSignatureInfo>;
begin
  Result := nil;
  if (ADoc = nil) or not ADoc.IsOpen then Exit;

  Results := TList<TPDFSignatureInfo>.Create;
  try
    Form := TPDFAcroForm.Create;
    try
      Form.LoadFromCatalog(ADoc.Catalog, ADoc.Resolver);

      for Field in Form.Fields do
      begin
        if Field.FieldType <> TPDFFieldType.Signature then Continue;

        SigDict := nil;

        // The signature dict may be inline in the field dict (common) or
        // under /V (explicit value reference).
        if (Field.Dict <> nil) and Field.Dict.Contains('ByteRange') then
          SigDict := Field.Dict
        else if Field.Dict <> nil then
        begin
          ValObj := Field.Dict.Get('V');
          if (ValObj <> nil) and ValObj.IsDictionary then
            SigDict := TPDFDictionary(ValObj);
        end;

        ProcessSigDict(SigDict, Field.FullName, AStream, Info);
        Results.Add(Info);
      end;

    finally
      Form.Free;
    end;

    Result := Results.ToArray;
  finally
    Results.Free;
  end;
end;

end.
