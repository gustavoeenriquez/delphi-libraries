unit uPDF.Encryption;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections,
  uPDF.Types, uPDF.Errors, uPDF.Objects, uPDF.Crypto;

// =========================================================================
// Encryption info parsed from the /Encrypt dictionary
// =========================================================================

type
  TPDFCryptFilter = (
    None,
    RC4_40,    // Rev 2: 40-bit RC4
    RC4_128,   // Rev 3/4: 128-bit RC4
    AES_128,   // Rev 4: AES-128 CBC (CFM = AESV2)
    AES_256    // Rev 5/6: AES-256 CBC (CFM = AESV3)
  );

  TPDFEncryptionInfo = record
    Revision:        Integer;        // 2, 3, 4, 5, 6
    KeyBits:         Integer;        // 40, 128, or 256
    StmFilter:       TPDFCryptFilter; // for streams
    StrFilter:       TPDFCryptFilter; // for strings
    Permissions:     Integer;        // 32-bit permission flags
    EncryptMetadata: Boolean;
    // Rev 2-4: 32-byte arrays
    O:               TBytes;         // /O  — 32 or 48 bytes
    U:               TBytes;         // /U  — 32 or 48 bytes
    // Rev 5-6: additional 32-byte encrypted file keys
    OE:              TBytes;         // /OE — 32 bytes
    UE:              TBytes;         // /UE — 32 bytes
    Perms:           TBytes;         // /Perms — 16 bytes (Rev 6 verification)
    FileID:          TBytes;         // First element of /ID array
    IsValid:         Boolean;

    class function FromEncryptDict(ADict: TPDFDictionary;
      const AFileID: TBytes): TPDFEncryptionInfo; static;
  end;

// =========================================================================
// PDF Standard Security Handler decryptor
// Implements IDecryptionContext from uPDF.Types
// =========================================================================

  TPDFDecryptor = class(TInterfacedObject, IDecryptionContext)
  private
    FInfo:          TPDFEncryptionInfo;
    FFileKey:       TBytes;     // encryption key (derived after authentication)
    FAuthenticated: Boolean;

    // ----- Rev 2-4 algorithms (RC4 / AES-128) -----
    function  PadPassword(const APwd: TBytes): TBytes;
    function  ComputeEncKey_Rev24(const APwd: TBytes): TBytes;
    function  ComputeU_Rev2(const AFileKey: TBytes): TBytes;
    function  ComputeU_Rev34(const AFileKey: TBytes): TBytes;
    function  AuthUserPwd_Rev24(const APwd: TBytes): Boolean;
    function  AuthOwnerPwd_Rev24(const APwd: TBytes): Boolean;
    function  ObjectKey_Rev24(AObjNum, AGenNum: Integer;
                              AUseAES: Boolean): TBytes;

    // ----- Rev 5-6 algorithms (AES-256) -----
    // Algorithm 2.B: iterative SHA-256/384/512 KDF
    function  Alg2B(const APwd, ASalt, AUserKey: TBytes): TBytes;
    function  AuthUserPwd_Rev56(const APwd: TBytes): Boolean;
    function  AuthOwnerPwd_Rev56(const APwd: TBytes): Boolean;
    function  DeriveFileKey_Rev56(const APwd: TBytes; AIsOwner: Boolean): TBytes;

    // ----- IDecryptionContext -----
    function  DecryptBytes(const AData: TBytes; AObjNum, AGenNum: Integer;
                           AIsStream: Boolean): TBytes;
  public
    constructor Create(const AInfo: TPDFEncryptionInfo);

    // Try authenticating with the given password (UTF-8 encoded).
    // Returns True if the password is correct (user or owner).
    // Calling with empty string tries the empty/user password first.
    function  Authenticate(const APassword: string): Boolean;

    property  Authenticated: Boolean read FAuthenticated;
    property  Info: TPDFEncryptionInfo read FInfo;
  end;

implementation

// =========================================================================
// Standard padding string (PDF spec §7.6.3.3)
// =========================================================================

const
  PDF_PADDING: array[0..31] of Byte = (
    $28,$BF,$4E,$5E,$4E,$75,$8A,$41,$64,$00,$4E,$56,$FF,$FA,$01,$08,
    $2E,$2E,$00,$B6,$D0,$68,$3E,$80,$2F,$0C,$A9,$FE,$64,$53,$69,$7A
  );

// =========================================================================
// Helpers
// =========================================================================

function BytesToHex(const B: TBytes): string;
var I: Integer;
begin
  Result := '';
  for I := 0 to High(B) do
    Result := Result + IntToHex(B[I], 2);
end;

function ConcatBytes(const A, B: TBytes): TBytes; overload;
begin
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then Move(B[0], Result[Length(A)], Length(B));
end;

function ConcatBytes(const A, B, C: TBytes): TBytes; overload;
begin
  SetLength(Result, Length(A) + Length(B) + Length(C));
  var P := 0;
  if Length(A) > 0 then begin Move(A[0], Result[P], Length(A)); Inc(P, Length(A)); end;
  if Length(B) > 0 then begin Move(B[0], Result[P], Length(B)); Inc(P, Length(B)); end;
  if Length(C) > 0 then begin Move(C[0], Result[P], Length(C)); end;
end;

function HexToBytes(const AHex: TPDFString): TBytes;
begin
  var S := AHex.Bytes;
  var Len := System.Length(S) div 2;
  SetLength(Result, Len);
  for var I := 0 to Len - 1 do
    Result[I] := StrToInt('$' + string(S[I*2+1]) + string(S[I*2+2]));
end;

function StrToBytes(const S: RawByteString): TBytes;
begin
  SetLength(Result, System.Length(S));
  if System.Length(S) > 0 then
    Move(S[1], Result[0], System.Length(S));
end;

function PwdToBytes(const APassword: string): TBytes;
begin
  // PDF Rev 2-4: Latin-1 (ISO-8859-1), truncated to 32 bytes
  // PDF Rev 5-6: UTF-8, up to 127 bytes per spec (we use 127-byte limit)
  Result := TEncoding.UTF8.GetBytes(APassword);
  if Length(Result) > 127 then
    SetLength(Result, 127);
end;

// =========================================================================
// TPDFEncryptionInfo
// =========================================================================

class function TPDFEncryptionInfo.FromEncryptDict(ADict: TPDFDictionary;
  const AFileID: TBytes): TPDFEncryptionInfo;
var
  StmF, StrF, CFM: string;
  CFDict:          TPDFDictionary;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.FileID := AFileID;
  Result.EncryptMetadata := True; // default

  var Filter := ADict.GetAsName('Filter');
  if Filter <> 'Standard' then Exit;  // only Standard security handler

  Result.Revision    := ADict.GetAsInteger('R');
  Result.Permissions := ADict.GetAsInteger('P');
  Result.KeyBits     := ADict.GetAsInteger('Length');
  if Result.KeyBits <= 0 then
    Result.KeyBits := 40; // default for Rev 2

  // Read /O and /U (owner/user hash)
  var OObj := ADict.RawGet('O');
  if OObj <> nil then Result.O := StrToBytes(OObj.AsString);
  var UObj := ADict.RawGet('U');
  if UObj <> nil then Result.U := StrToBytes(UObj.AsString);

  // Rev 5-6: OE, UE, Perms
  if Result.Revision >= 5 then
  begin
    var OEObj := ADict.RawGet('OE');
    if OEObj <> nil then Result.OE := StrToBytes(OEObj.AsString);
    var UEObj := ADict.RawGet('UE');
    if UEObj <> nil then Result.UE := StrToBytes(UEObj.AsString);
    var PermsObj := ADict.RawGet('Perms');
    if PermsObj <> nil then Result.Perms := StrToBytes(PermsObj.AsString);
  end;

  // EncryptMetadata (Rev 4+)
  var EMObj := ADict.RawGet('EncryptMetadata');
  if (EMObj <> nil) and EMObj.IsBoolean then
    Result.EncryptMetadata := EMObj.AsBoolean;

  // Determine crypt filter
  case Result.Revision of
    2: begin
         Result.StmFilter := TPDFCryptFilter.RC4_40;
         Result.StrFilter := TPDFCryptFilter.RC4_40;
         Result.KeyBits   := 40;
       end;
    3: begin
         Result.StmFilter := TPDFCryptFilter.RC4_128;
         Result.StrFilter := TPDFCryptFilter.RC4_128;
         if Result.KeyBits <= 0 then Result.KeyBits := 128;
       end;
    4: begin
         // Rev 4: use /CF dict with /StmF and /StrF entries
         StmF := ADict.GetAsName('StmF');
         StrF := ADict.GetAsName('StrF');
         var CFsDict := ADict.GetAsDictionary('CF');
         Result.StmFilter := TPDFCryptFilter.RC4_128;  // default
         Result.StrFilter := TPDFCryptFilter.RC4_128;

         if (CFsDict <> nil) and (StmF <> '') and (StmF <> 'Identity') then
         begin
           CFDict := CFsDict.GetAsDictionary(StmF);
           if CFDict <> nil then
           begin
             CFM := CFDict.GetAsName('CFM');
             if CFM = 'AESV2' then Result.StmFilter := TPDFCryptFilter.AES_128
             else                   Result.StmFilter := TPDFCryptFilter.RC4_128;
           end;
         end;
         if (CFsDict <> nil) and (StrF <> '') and (StrF <> 'Identity') then
         begin
           CFDict := CFsDict.GetAsDictionary(StrF);
           if CFDict <> nil then
           begin
             CFM := CFDict.GetAsName('CFM');
             if CFM = 'AESV2' then Result.StrFilter := TPDFCryptFilter.AES_128
             else                   Result.StrFilter := TPDFCryptFilter.RC4_128;
           end;
         end;
         if Result.KeyBits <= 0 then Result.KeyBits := 128;
       end;
    5, 6: begin
         Result.StmFilter := TPDFCryptFilter.AES_256;
         Result.StrFilter := TPDFCryptFilter.AES_256;
         Result.KeyBits   := 256;
       end;
  end;

  Result.IsValid := (Result.Revision >= 2) and (Result.Revision <= 6) and
                    (Length(Result.O) >= 32) and (Length(Result.U) >= 32);
end;

// =========================================================================
// TPDFDecryptor
// =========================================================================

constructor TPDFDecryptor.Create(const AInfo: TPDFEncryptionInfo);
begin
  inherited Create;
  FInfo := AInfo;
end;

// -------------------------------------------------------------------------
// Password padding (Rev 2-4, Algorithm 2 step 1)
// -------------------------------------------------------------------------

function TPDFDecryptor.PadPassword(const APwd: TBytes): TBytes;
var
  L: Integer;
begin
  SetLength(Result, 32);
  L := Min(Length(APwd), 32);
  if L > 0 then Move(APwd[0], Result[0], L);
  if L < 32 then Move(PDF_PADDING[0], Result[L], 32 - L);
end;

// -------------------------------------------------------------------------
// Compute file encryption key (Rev 2-4, Algorithm 2)
// -------------------------------------------------------------------------

function TPDFDecryptor.ComputeEncKey_Rev24(const APwd: TBytes): TBytes;
var
  Input: TBytes;
  KeyLen, InputLen: Integer;
  Pos: Integer;
begin
  KeyLen   := FInfo.KeyBits div 8;
  InputLen := 32 + 32 + 4 + Length(FInfo.FileID);
  if (FInfo.Revision >= 4) and (not FInfo.EncryptMetadata) then
    Inc(InputLen, 4);

  SetLength(Input, InputLen);
  Pos := 0;

  var Padded := PadPassword(APwd);
  Move(Padded[0], Input[Pos], 32); Inc(Pos, 32);
  Move(FInfo.O[0], Input[Pos], 32); Inc(Pos, 32);
  // P as little-endian 32-bit signed integer
  Input[Pos]   :=  FInfo.Permissions        and $FF;
  Input[Pos+1] := (FInfo.Permissions shr  8) and $FF;
  Input[Pos+2] := (FInfo.Permissions shr 16) and $FF;
  Input[Pos+3] := (FInfo.Permissions shr 24) and $FF;
  Inc(Pos, 4);
  if Length(FInfo.FileID) > 0 then
  begin
    Move(FInfo.FileID[0], Input[Pos], Length(FInfo.FileID));
    Inc(Pos, Length(FInfo.FileID));
  end;
  if (FInfo.Revision >= 4) and (not FInfo.EncryptMetadata) then
  begin
    Input[Pos]   := $FF; Input[Pos+1] := $FF;
    Input[Pos+2] := $FF; Input[Pos+3] := $FF;
  end;

  Result := CryptoMD5(Input);

  if FInfo.Revision >= 3 then
    for var I := 0 to 49 do
      Result := CryptoMD5(Copy(Result, 0, KeyLen));

  SetLength(Result, KeyLen);
end;

// -------------------------------------------------------------------------
// Compute U entry for verification (Rev 2, Algorithm 4)
// -------------------------------------------------------------------------

function TPDFDecryptor.ComputeU_Rev2(const AFileKey: TBytes): TBytes;
begin
  SetLength(Result, 32);
  Move(PDF_PADDING[0], Result[0], 32);
  RC4Process(AFileKey, Result);
end;

// -------------------------------------------------------------------------
// Compute U entry for verification (Rev 3/4, Algorithm 5)
// -------------------------------------------------------------------------

function TPDFDecryptor.ComputeU_Rev34(const AFileKey: TBytes): TBytes;
var
  MD5Input: TBytes;
  KeyLen:   Integer;
  TempKey:  TBytes;
begin
  KeyLen := Length(AFileKey);

  SetLength(MD5Input, 32 + Length(FInfo.FileID));
  Move(PDF_PADDING[0], MD5Input[0], 32);
  if Length(FInfo.FileID) > 0 then
    Move(FInfo.FileID[0], MD5Input[32], Length(FInfo.FileID));

  // RC4 of MD5(padding + FileID) using file key
  SetLength(Result, 16);
  var Hash := CryptoMD5(MD5Input);
  Move(Hash[0], Result[0], 16);
  RC4Process(AFileKey, Result);

  // 19 more passes with XOR'd key
  SetLength(TempKey, KeyLen);
  for var I := 1 to 19 do
  begin
    for var J := 0 to KeyLen - 1 do
      TempKey[J] := AFileKey[J] xor Byte(I);
    RC4Process(TempKey, Result);
  end;

  // Pad to 32 bytes (second half is arbitrary)
  SetLength(Result, 32);
  FillChar(Result[16], 16, 0);
end;

// -------------------------------------------------------------------------
// Rev 2-4: authenticate user password
// -------------------------------------------------------------------------

function TPDFDecryptor.AuthUserPwd_Rev24(const APwd: TBytes): Boolean;
var
  FileKey, UComp: TBytes;
begin
  FileKey := ComputeEncKey_Rev24(APwd);

  if FInfo.Revision = 2 then
    UComp := ComputeU_Rev2(FileKey)
  else
    UComp := ComputeU_Rev34(FileKey);

  if FInfo.Revision = 2 then
    Result := CompareMem(PByte(UComp), PByte(FInfo.U), 32)
  else
    Result := CompareMem(PByte(UComp), PByte(FInfo.U), 16);

  if Result then FFileKey := FileKey;
end;

// -------------------------------------------------------------------------
// Rev 2-4: authenticate owner password
// -------------------------------------------------------------------------

function TPDFDecryptor.AuthOwnerPwd_Rev24(const APwd: TBytes): Boolean;
var
  OMD5:     TBytes;
  OKey:     TBytes;
  UserPwd:  TBytes;
  TempKey:  TBytes;
  KeyLen:   Integer;
begin
  // Step 1: derive RC4 key from owner password
  var OPad := PadPassword(APwd);
  OMD5 := CryptoMD5(OPad);
  if FInfo.Revision >= 3 then
    for var I := 0 to 49 do
      OMD5 := CryptoMD5(OMD5);
  KeyLen := FInfo.KeyBits div 8;
  OKey := Copy(OMD5, 0, KeyLen);

  // Step 2: decrypt O entry to recover (padded) user password
  UserPwd := Copy(FInfo.O, 0, 32);
  if FInfo.Revision = 2 then
    RC4Process(OKey, UserPwd)
  else
  begin
    SetLength(TempKey, KeyLen);
    for var I := 19 downto 0 do
    begin
      for var J := 0 to KeyLen - 1 do
        TempKey[J] := OKey[J] xor Byte(I);
      RC4Process(TempKey, UserPwd);
    end;
  end;

  // Step 3: authenticate recovered user password
  Result := AuthUserPwd_Rev24(UserPwd);
end;

// -------------------------------------------------------------------------
// Per-object encryption key for Rev 2-4
// -------------------------------------------------------------------------

function TPDFDecryptor.ObjectKey_Rev24(AObjNum, AGenNum: Integer;
  AUseAES: Boolean): TBytes;
var
  Input: TBytes;
begin
  var Len := Length(FFileKey);
  SetLength(Input, Len + 5 + IfThen(AUseAES, 4, 0));
  var P := 0;
  Move(FFileKey[0], Input[P], Len); Inc(P, Len);
  Input[P]   :=  AObjNum        and $FF;
  Input[P+1] := (AObjNum shr  8) and $FF;
  Input[P+2] := (AObjNum shr 16) and $FF;
  Input[P+3] :=  AGenNum        and $FF;
  Input[P+4] := (AGenNum shr  8) and $FF;
  Inc(P, 5);
  if AUseAES then
  begin
    Input[P]   := $73;  // 's'
    Input[P+1] := $41;  // 'A'
    Input[P+2] := $6C;  // 'l'
    Input[P+3] := $54;  // 'T'
  end;

  Result := CryptoMD5(Input);
  var KeyLen := Min(Len + 5, 16);
  SetLength(Result, KeyLen);
end;

// -------------------------------------------------------------------------
// Algorithm 2.B (Rev 5/6 iterative KDF — ISO 32000-2 §7.6.4.3.4)
// -------------------------------------------------------------------------

function TPDFDecryptor.Alg2B(const APwd, ASalt, AUserKey: TBytes): TBytes;
var
  K:        TBytes;
  Segment:  TBytes;
  K1:       TBytes;
  E:        TBytes;
  AESKey:   TBytes;
  AESIV:    TBytes;
  Round:    Integer;
  I, J:     Integer;
  SegLen:   Integer;
  TotalLen: Integer;
  Sum:      Cardinal;
begin
  // Initial K = SHA256(pwd + salt + userKey)
  K := CryptoSHA256(ConcatBytes(ConcatBytes(APwd, ASalt), AUserKey));

  Round := 0;
  while True do
  begin
    // K1 = 64 repetitions of (pwd + K + userKey)
    SegLen   := Length(APwd) + 32 + Length(AUserKey);
    TotalLen := SegLen * 64;

    SetLength(Segment, SegLen);
    J := 0;
    if Length(APwd) > 0 then
    begin
      Move(APwd[0], Segment[J], Length(APwd));
      Inc(J, Length(APwd));
    end;
    Move(K[0], Segment[J], 32);
    Inc(J, 32);
    if Length(AUserKey) > 0 then
      Move(AUserKey[0], Segment[J], Length(AUserKey));

    SetLength(K1, TotalLen);
    for I := 0 to 63 do
      Move(Segment[0], K1[I * SegLen], SegLen);

    // AES-128-CBC encrypt K1 using K[0:16] and K[16:32]
    AESKey := Copy(K, 0, 16);
    AESIV  := Copy(K, 16, 16);

    // Ensure K1 length is block-aligned (it always is since 64 * SegLen where
    // 64 mod 16 = 0; but guard against edge cases)
    if (Length(K1) mod 16) <> 0 then
    begin
      var Pad := 16 - (Length(K1) mod 16);
      SetLength(K1, Length(K1) + Pad);
      FillChar(K1[Length(K1) - Pad], Pad, 0);
    end;
    E := Copy(K1);
    AESEncryptCBC(AESKey, AESIV, E);

    // Determine next hash: E[0:16] as 128-bit big-endian integer mod 3
    // Since 256 = 1 mod 3, we just sum all bytes mod 3
    Sum := 0;
    for I := 0 to 15 do
      Sum := (Sum + E[I]) mod 3;

    case Sum of
      0: K := CryptoSHA256(E);
      1: K := CryptoSHA384(E);
    else   K := CryptoSHA512(E);
    end;

    // Truncate to 32 bytes (SHA-384/512 produce more)
    if Length(K) > 32 then SetLength(K, 32);

    Inc(Round);

    // Termination: Round >= 64 and last byte of E <= Round - 32
    if (Round >= 64) and (E[High(E)] <= Byte(Round - 32)) then Break;

    // Safety limit
    if Round >= 256 then Break;
  end;

  Result := Copy(K, 0, 32);
end;

// -------------------------------------------------------------------------
// Rev 5/6: authenticate user password
// -------------------------------------------------------------------------

function TPDFDecryptor.AuthUserPwd_Rev56(const APwd: TBytes): Boolean;
var
  Hash: TBytes;
begin
  if Length(FInfo.U) < 48 then Exit(False);

  var ValSalt := Copy(FInfo.U, 32, 8);  // U[32:40]
  if FInfo.Revision = 5 then
    Hash := CryptoSHA256(ConcatBytes(APwd, ValSalt))
  else
    Hash := Alg2B(APwd, ValSalt, nil);

  Result := CompareMem(PByte(Hash), PByte(FInfo.U), 32);
  if Result then
    FFileKey := DeriveFileKey_Rev56(APwd, False);
end;

// -------------------------------------------------------------------------
// Rev 5/6: authenticate owner password
// -------------------------------------------------------------------------

function TPDFDecryptor.AuthOwnerPwd_Rev56(const APwd: TBytes): Boolean;
var
  Hash:    TBytes;
  UserKey: TBytes;
begin
  if (Length(FInfo.O) < 48) or (Length(FInfo.U) < 48) then Exit(False);

  var ValSalt := Copy(FInfo.O, 32, 8);  // O[32:40]
  UserKey  := Copy(FInfo.U, 0, 48);

  if FInfo.Revision = 5 then
    Hash := CryptoSHA256(ConcatBytes(ConcatBytes(APwd, ValSalt), UserKey))
  else
    Hash := Alg2B(APwd, ValSalt, UserKey);

  Result := CompareMem(PByte(Hash), PByte(FInfo.O), 32);
  if Result then
    FFileKey := DeriveFileKey_Rev56(APwd, True);
end;

// -------------------------------------------------------------------------
// Rev 5/6: derive actual file encryption key
// -------------------------------------------------------------------------

function TPDFDecryptor.DeriveFileKey_Rev56(const APwd: TBytes;
  AIsOwner: Boolean): TBytes;
var
  KeySalt: TBytes;
  IntKey:  TBytes;
  IV:      TBytes;
  EncKey:  TBytes;
begin
  if AIsOwner then
  begin
    KeySalt := Copy(FInfo.O, 40, 8);         // O[40:48]
    var UK := Copy(FInfo.U, 0, 48);
    if FInfo.Revision = 5 then
      IntKey := CryptoSHA256(ConcatBytes(ConcatBytes(APwd, KeySalt), UK))
    else
      IntKey := Alg2B(APwd, KeySalt, UK);
    EncKey := Copy(FInfo.OE);
  end else
  begin
    KeySalt := Copy(FInfo.U, 40, 8);         // U[40:48]
    if FInfo.Revision = 5 then
      IntKey := CryptoSHA256(ConcatBytes(APwd, KeySalt))
    else
      IntKey := Alg2B(APwd, KeySalt, nil);
    EncKey := Copy(FInfo.UE);
  end;

  // Decrypt UE/OE using derived key with all-zeros IV
  SetLength(IV, 16);
  FillChar(IV[0], 16, 0);
  AESDecryptCBC(IntKey, IV, EncKey);
  Result := EncKey; // 32 bytes = file encryption key
end;

// =========================================================================
// Public: Authenticate
// =========================================================================

function TPDFDecryptor.Authenticate(const APassword: string): Boolean;
var
  Pwd: TBytes;
begin
  FAuthenticated := False;
  Pwd := PwdToBytes(APassword);

  if FInfo.Revision <= 4 then
  begin
    // Try user password first, then owner password
    if AuthUserPwd_Rev24(Pwd) or AuthOwnerPwd_Rev24(Pwd) then
    begin
      FAuthenticated := True;
      Result := True;
      Exit;
    end;
  end else
  begin
    // Rev 5/6: try user then owner
    if AuthUserPwd_Rev56(Pwd) or AuthOwnerPwd_Rev56(Pwd) then
    begin
      FAuthenticated := True;
      Result := True;
      Exit;
    end;
  end;

  // Also try Latin-1 encoded password for Rev 2-4 compatibility
  if FInfo.Revision <= 4 then
  begin
    var PwdLatin := TEncoding.GetEncoding(1252).GetBytes(APassword);
    if Length(PwdLatin) > 32 then SetLength(PwdLatin, 32);
    if AuthUserPwd_Rev24(PwdLatin) or AuthOwnerPwd_Rev24(PwdLatin) then
    begin
      FAuthenticated := True;
      Result := True;
      Exit;
    end;
  end;

  Result := False;
end;

// =========================================================================
// IDecryptionContext: DecryptBytes
// =========================================================================

function TPDFDecryptor.DecryptBytes(const AData: TBytes; AObjNum, AGenNum: Integer;
  AIsStream: Boolean): TBytes;
var
  Filter: TPDFCryptFilter;
  ObjKey: TBytes;
  IV:     TBytes;
begin
  if not FAuthenticated or (Length(FFileKey) = 0) then
    Exit(AData);
  if Length(AData) = 0 then
    Exit(AData);

  if AIsStream then Filter := FInfo.StmFilter else Filter := FInfo.StrFilter;

  case Filter of
    TPDFCryptFilter.None:
      Result := AData;

    TPDFCryptFilter.RC4_40,
    TPDFCryptFilter.RC4_128:
    begin
      ObjKey := ObjectKey_Rev24(AObjNum, AGenNum, False);
      Result := Copy(AData);
      RC4Process(ObjKey, Result);
    end;

    TPDFCryptFilter.AES_128:
    begin
      // Rev 4 AES-128: first 16 bytes of stream are the IV
      if Length(AData) < 32 then Exit(AData);  // too short
      ObjKey := ObjectKey_Rev24(AObjNum, AGenNum, True);
      IV     := Copy(AData, 0, 16);
      var Body := Copy(AData, 16, Length(AData) - 16);
      if (Length(Body) mod 16) <> 0 then Exit(AData);
      AESDecryptCBC(ObjKey, IV, Body);
      Result := PKCSUnpad(Body);
    end;

    TPDFCryptFilter.AES_256:
    begin
      // Rev 5/6 AES-256: first 16 bytes are the IV; key is the file key
      if Length(AData) < 32 then Exit(AData);
      IV   := Copy(AData, 0, 16);
      var Body := Copy(AData, 16, Length(AData) - 16);
      if (Length(Body) mod 16) <> 0 then Exit(AData);
      AESDecryptCBC(FFileKey, IV, Body);
      Result := PKCSUnpad(Body);
    end;

  else
    Result := AData;
  end;
end;

end.
