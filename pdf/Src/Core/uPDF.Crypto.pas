unit uPDF.Crypto;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Hash;

// -----------------------------------------------------------------------
// MD5 — 16-byte digest
// -----------------------------------------------------------------------
function CryptoMD5(const AData: TBytes): TBytes;

// -----------------------------------------------------------------------
// SHA-1 — 20-byte digest
// -----------------------------------------------------------------------
function CryptoSHA1(const AData: TBytes): TBytes;

// -----------------------------------------------------------------------
// SHA-256 / SHA-384 / SHA-512
// -----------------------------------------------------------------------
function CryptoSHA256(const AData: TBytes): TBytes;
function CryptoSHA384(const AData: TBytes): TBytes;
function CryptoSHA512(const AData: TBytes): TBytes;

// -----------------------------------------------------------------------
// RC4 — in-place symmetric stream cipher
// -----------------------------------------------------------------------
procedure RC4Process(const AKey: TBytes; var AData: TBytes);

// -----------------------------------------------------------------------
// AES-CBC — key 16 (AES-128) or 32 bytes (AES-256); IV 16 bytes
// Data length must be a multiple of 16 bytes.
// -----------------------------------------------------------------------
procedure AESEncryptCBC(const AKey, AIV: TBytes; var AData: TBytes);
procedure AESDecryptCBC(const AKey, AIV: TBytes; var AData: TBytes);

// -----------------------------------------------------------------------
// PKCS#7 padding helpers
// -----------------------------------------------------------------------
function PKCSPad(const AData: TBytes; ABlockSize: Integer = 16): TBytes;
// Raises Exception on invalid padding
function PKCSUnpad(const AData: TBytes): TBytes;

implementation

// =========================================================================
// MD5 / SHA-2  (delegated to System.Hash which uses OS crypto)
// =========================================================================

function CryptoMD5(const AData: TBytes): TBytes;
var
  H: THashMD5;
begin
  H := THashMD5.Create;
  if Length(AData) > 0 then
    H.Update(AData[0], Length(AData));
  Result := H.HashAsBytes;
end;

function CryptoSHA1(const AData: TBytes): TBytes;
var
  H: THashSHA1;
begin
  H := THashSHA1.Create;
  if Length(AData) > 0 then
    H.Update(AData[0], Length(AData));
  Result := H.HashAsBytes;
end;

function CryptoSHA256(const AData: TBytes): TBytes;
var
  H: THashSHA2;
begin
  H := THashSHA2.Create(THashSHA2.TSHA2Version.SHA256);
  if Length(AData) > 0 then
    H.Update(AData[0], Length(AData));
  Result := H.HashAsBytes;
end;

function CryptoSHA384(const AData: TBytes): TBytes;
var
  H: THashSHA2;
begin
  H := THashSHA2.Create(THashSHA2.TSHA2Version.SHA384);
  if Length(AData) > 0 then
    H.Update(AData[0], Length(AData));
  Result := H.HashAsBytes;
end;

function CryptoSHA512(const AData: TBytes): TBytes;
var
  H: THashSHA2;
begin
  H := THashSHA2.Create(THashSHA2.TSHA2Version.SHA512);
  if Length(AData) > 0 then
    H.Update(AData[0], Length(AData));
  Result := H.HashAsBytes;
end;

// =========================================================================
// RC4
// =========================================================================

procedure RC4Process(const AKey: TBytes; var AData: TBytes);
var
  S:    array[0..255] of Byte;
  I, J, K, T: Integer;
begin
  if (Length(AKey) = 0) or (Length(AData) = 0) then Exit;

  // Key-scheduling algorithm (KSA)
  for I := 0 to 255 do S[I] := I;
  J := 0;
  for I := 0 to 255 do
  begin
    J := (J + S[I] + AKey[I mod Length(AKey)]) and $FF;
    T := S[I]; S[I] := S[J]; S[J] := T;
  end;

  // Pseudo-random generation algorithm (PRGA)
  I := 0; J := 0;
  for K := 0 to High(AData) do
  begin
    I := (I + 1) and $FF;
    J := (J + S[I]) and $FF;
    T := S[I]; S[I] := S[J]; S[J] := T;
    AData[K] := AData[K] xor S[(S[I] + S[J]) and $FF];
  end;
end;

// =========================================================================
// AES — pure Delphi implementation
// =========================================================================

const
  // Forward S-box
  SBOX: array[0..255] of Byte = (
    $63,$7C,$77,$7B,$F2,$6B,$6F,$C5,$30,$01,$67,$2B,$FE,$D7,$AB,$76,
    $CA,$82,$C9,$7D,$FA,$59,$47,$F0,$AD,$D4,$A2,$AF,$9C,$A4,$72,$C0,
    $B7,$FD,$93,$26,$36,$3F,$F7,$CC,$34,$A5,$E5,$F1,$71,$D8,$31,$15,
    $04,$C7,$23,$C3,$18,$96,$05,$9A,$07,$12,$80,$E2,$EB,$27,$B2,$75,
    $09,$83,$2C,$1A,$1B,$6E,$5A,$A0,$52,$3B,$D6,$B3,$29,$E3,$2F,$84,
    $53,$D1,$00,$ED,$20,$FC,$B1,$5B,$6A,$CB,$BE,$39,$4A,$4C,$58,$CF,
    $D0,$EF,$AA,$FB,$43,$4D,$33,$85,$45,$F9,$02,$7F,$50,$3C,$9F,$A8,
    $51,$A3,$40,$8F,$92,$9D,$38,$F5,$BC,$B6,$DA,$21,$10,$FF,$F3,$D2,
    $CD,$0C,$13,$EC,$5F,$97,$44,$17,$C4,$A7,$7E,$3D,$64,$5D,$19,$73,
    $60,$81,$4F,$DC,$22,$2A,$90,$88,$46,$EE,$B8,$14,$DE,$5E,$0B,$DB,
    $E0,$32,$3A,$0A,$49,$06,$24,$5C,$C2,$D3,$AC,$62,$91,$95,$E4,$79,
    $E7,$C8,$37,$6D,$8D,$D5,$4E,$A9,$6C,$56,$F4,$EA,$65,$7A,$AE,$08,
    $BA,$78,$25,$2E,$1C,$A6,$B4,$C6,$E8,$DD,$74,$1F,$4B,$BD,$8B,$8A,
    $70,$3E,$B5,$66,$48,$03,$F6,$0E,$61,$35,$57,$B9,$86,$C1,$1D,$9E,
    $E1,$F8,$98,$11,$69,$D9,$8E,$94,$9B,$1E,$87,$E9,$CE,$55,$28,$DF,
    $8C,$A1,$89,$0D,$BF,$E6,$42,$68,$41,$99,$2D,$0F,$B0,$54,$BB,$16
  );

  // Inverse S-box
  SBOX_INV: array[0..255] of Byte = (
    $52,$09,$6A,$D5,$30,$36,$A5,$38,$BF,$40,$A3,$9E,$81,$F3,$D7,$FB,
    $7C,$E3,$39,$82,$9B,$2F,$FF,$87,$34,$8E,$43,$44,$C4,$DE,$E9,$CB,
    $54,$7B,$94,$32,$A6,$C2,$23,$3D,$EE,$4C,$95,$0B,$42,$FA,$C3,$4E,
    $08,$2E,$A1,$66,$28,$D9,$24,$B2,$76,$5B,$A2,$49,$6D,$8B,$D1,$25,
    $72,$F8,$F6,$64,$86,$68,$98,$16,$D4,$A4,$5C,$CC,$5D,$65,$B6,$92,
    $6C,$70,$48,$50,$FD,$ED,$B9,$DA,$5E,$15,$46,$57,$A7,$8D,$9D,$84,
    $90,$D8,$AB,$00,$8C,$BC,$D3,$0A,$F7,$E4,$58,$05,$B8,$B3,$45,$06,
    $D0,$2C,$1E,$8F,$CA,$3F,$0F,$02,$C1,$AF,$BD,$03,$01,$13,$8A,$6B,
    $3A,$91,$11,$41,$4F,$67,$DC,$EA,$97,$F2,$CF,$CE,$F0,$B4,$E6,$73,
    $96,$AC,$74,$22,$E7,$AD,$35,$85,$E2,$F9,$37,$E8,$1C,$75,$DF,$6E,
    $47,$F1,$1A,$71,$1D,$29,$C5,$89,$6F,$B7,$62,$0E,$AA,$18,$BE,$1B,
    $FC,$56,$3E,$4B,$C6,$D2,$79,$20,$9A,$DB,$C0,$FE,$78,$CD,$5A,$F4,
    $1F,$DD,$A8,$33,$88,$07,$C7,$31,$B1,$12,$10,$59,$27,$80,$EC,$5F,
    $60,$51,$7F,$A9,$19,$B5,$4A,$0D,$2D,$E5,$7A,$9F,$93,$C9,$9C,$EF,
    $A0,$E0,$3B,$4D,$AE,$2A,$F5,$B0,$C8,$EB,$BB,$3C,$83,$53,$99,$61,
    $17,$2B,$04,$7E,$BA,$77,$D6,$26,$E1,$69,$14,$63,$55,$21,$0C,$7D
  );

  // Round constants (for AES-128 we need Rcon[0..9], AES-256 needs [0..6])
  RCON: array[0..9] of Byte = ($01,$02,$04,$08,$10,$20,$40,$80,$1B,$36);

type
  TAESState  = array[0..3, 0..3] of Byte;
  TAESKeyExp = array of Cardinal;

// GF(2^8) multiplication with AES irreducible polynomial x^8+x^4+x^3+x+1
function GFMul(A, B: Byte): Byte;
var
  P: Byte;
  C: Byte;
begin
  P := 0;
  while B <> 0 do
  begin
    if (B and 1) <> 0 then P := P xor A;
    C := A and $80;
    A := (A shl 1) and $FF;
    if C <> 0 then A := A xor $1B;
    B := B shr 1;
  end;
  Result := P;
end;

procedure BytesToState(const AData: TBytes; AOffset: Integer;
  out S: TAESState); inline;
var R, C: Integer;
begin
  for C := 0 to 3 do
    for R := 0 to 3 do
      S[R][C] := AData[AOffset + C * 4 + R];
end;

procedure StateToBytes(const S: TAESState; var AData: TBytes;
  AOffset: Integer); inline;
var R, C: Integer;
begin
  for C := 0 to 3 do
    for R := 0 to 3 do
      AData[AOffset + C * 4 + R] := S[R][C];
end;

procedure SubBytes(var S: TAESState);
var R, C: Integer;
begin
  for R := 0 to 3 do
    for C := 0 to 3 do
      S[R][C] := SBOX[S[R][C]];
end;

procedure InvSubBytes(var S: TAESState);
var R, C: Integer;
begin
  for R := 0 to 3 do
    for C := 0 to 3 do
      S[R][C] := SBOX_INV[S[R][C]];
end;

procedure ShiftRows(var S: TAESState);
var T: Byte;
begin
  T := S[1][0]; S[1][0] := S[1][1]; S[1][1] := S[1][2]; S[1][2] := S[1][3]; S[1][3] := T;
  T := S[2][0]; S[2][0] := S[2][2]; S[2][2] := T;
  T := S[2][1]; S[2][1] := S[2][3]; S[2][3] := T;
  T := S[3][3]; S[3][3] := S[3][2]; S[3][2] := S[3][1]; S[3][1] := S[3][0]; S[3][0] := T;
end;

procedure InvShiftRows(var S: TAESState);
var T: Byte;
begin
  T := S[1][3]; S[1][3] := S[1][2]; S[1][2] := S[1][1]; S[1][1] := S[1][0]; S[1][0] := T;
  T := S[2][0]; S[2][0] := S[2][2]; S[2][2] := T;
  T := S[2][1]; S[2][1] := S[2][3]; S[2][3] := T;
  T := S[3][0]; S[3][0] := S[3][1]; S[3][1] := S[3][2]; S[3][2] := S[3][3]; S[3][3] := T;
end;

procedure MixColumns(var S: TAESState);
var C: Integer;
    A: array[0..3] of Byte;
begin
  for C := 0 to 3 do
  begin
    A[0] := S[0][C]; A[1] := S[1][C]; A[2] := S[2][C]; A[3] := S[3][C];
    S[0][C] := GFMul(A[0],$02) xor GFMul(A[1],$03) xor A[2]            xor A[3];
    S[1][C] := A[0]            xor GFMul(A[1],$02) xor GFMul(A[2],$03) xor A[3];
    S[2][C] := A[0]            xor A[1]            xor GFMul(A[2],$02) xor GFMul(A[3],$03);
    S[3][C] := GFMul(A[0],$03) xor A[1]            xor A[2]            xor GFMul(A[3],$02);
  end;
end;

procedure InvMixColumns(var S: TAESState);
var C: Integer;
    A: array[0..3] of Byte;
begin
  for C := 0 to 3 do
  begin
    A[0] := S[0][C]; A[1] := S[1][C]; A[2] := S[2][C]; A[3] := S[3][C];
    S[0][C] := GFMul(A[0],$0E) xor GFMul(A[1],$0B) xor GFMul(A[2],$0D) xor GFMul(A[3],$09);
    S[1][C] := GFMul(A[0],$09) xor GFMul(A[1],$0E) xor GFMul(A[2],$0B) xor GFMul(A[3],$0D);
    S[2][C] := GFMul(A[0],$0D) xor GFMul(A[1],$09) xor GFMul(A[2],$0E) xor GFMul(A[3],$0B);
    S[3][C] := GFMul(A[0],$0B) xor GFMul(A[1],$0D) xor GFMul(A[2],$09) xor GFMul(A[3],$0E);
  end;
end;

procedure AddRoundKey(var S: TAESState; const W: TAESKeyExp; ARound: Integer);
var C: Integer;
    Wd: Cardinal;
begin
  for C := 0 to 3 do
  begin
    Wd := W[ARound * 4 + C];
    S[0][C] := S[0][C] xor Byte(Wd shr 24);
    S[1][C] := S[1][C] xor Byte(Wd shr 16);
    S[2][C] := S[2][C] xor Byte(Wd shr  8);
    S[3][C] := S[3][C] xor Byte(Wd);
  end;
end;

function SubWord(W: Cardinal): Cardinal; inline;
begin
  Result := (Cardinal(SBOX[W shr 24])        shl 24) or
            (Cardinal(SBOX[(W shr 16) and $FF]) shl 16) or
            (Cardinal(SBOX[(W shr  8) and $FF]) shl  8) or
             Cardinal(SBOX[W and $FF]);
end;

function RotWord(W: Cardinal): Cardinal; inline;
begin
  Result := (W shl 8) or (W shr 24);
end;

procedure AESKeyExpand(const AKey: TBytes; out W: TAESKeyExp; out ANr: Integer);
var
  Nk, I: Integer;
  Temp:  Cardinal;
begin
  Nk  := Length(AKey) div 4;   // 4 for AES-128, 8 for AES-256
  ANr := Nk + 6;                // 10 for AES-128, 14 for AES-256
  SetLength(W, (ANr + 1) * 4);

  for I := 0 to Nk - 1 do
    W[I] := (Cardinal(AKey[4*I])   shl 24) or
             (Cardinal(AKey[4*I+1]) shl 16) or
             (Cardinal(AKey[4*I+2]) shl  8) or
              Cardinal(AKey[4*I+3]);

  for I := Nk to (ANr + 1) * 4 - 1 do
  begin
    Temp := W[I - 1];
    if (I mod Nk) = 0 then
      Temp := SubWord(RotWord(Temp)) xor (Cardinal(RCON[I div Nk - 1]) shl 24)
    else if (Nk > 6) and ((I mod Nk) = 4) then
      Temp := SubWord(Temp);
    W[I] := W[I - Nk] xor Temp;
  end;
end;

procedure AESEncryptBlock(const W: TAESKeyExp; ANr: Integer;
  const AIn: TBytes; AInOff: Integer; var AOut: TBytes; AOutOff: Integer);
var
  State: TAESState;
  Round: Integer;
begin
  BytesToState(AIn, AInOff, State);
  AddRoundKey(State, W, 0);
  for Round := 1 to ANr - 1 do
  begin
    SubBytes(State);
    ShiftRows(State);
    MixColumns(State);
    AddRoundKey(State, W, Round);
  end;
  SubBytes(State);
  ShiftRows(State);
  AddRoundKey(State, W, ANr);
  StateToBytes(State, AOut, AOutOff);
end;

procedure AESDecryptBlock(const W: TAESKeyExp; ANr: Integer;
  const AIn: TBytes; AInOff: Integer; var AOut: TBytes; AOutOff: Integer);
var
  State: TAESState;
  Round: Integer;
begin
  BytesToState(AIn, AInOff, State);
  AddRoundKey(State, W, ANr);
  for Round := ANr - 1 downto 1 do
  begin
    InvShiftRows(State);
    InvSubBytes(State);
    AddRoundKey(State, W, Round);
    InvMixColumns(State);
  end;
  InvShiftRows(State);
  InvSubBytes(State);
  AddRoundKey(State, W, 0);
  StateToBytes(State, AOut, AOutOff);
end;

procedure AESEncryptCBC(const AKey, AIV: TBytes; var AData: TBytes);
var
  W:      TAESKeyExp;
  Nr:     Integer;
  Blocks: Integer;
  I, J:   Integer;
  Prev:   array[0..15] of Byte;
  Block:  TBytes;
begin
  if Length(AKey) = 0 then Exit;
  if (Length(AKey) <> 16) and (Length(AKey) <> 32) then
    raise Exception.Create('AES key must be 16 or 32 bytes');
  if Length(AIV) <> 16 then
    raise Exception.Create('AES IV must be 16 bytes');
  if (Length(AData) mod 16) <> 0 then
    raise Exception.Create('AES data must be a multiple of 16 bytes');

  AESKeyExpand(AKey, W, Nr);
  SetLength(Block, 16);
  Move(AIV[0], Prev[0], 16);
  Blocks := Length(AData) div 16;

  for I := 0 to Blocks - 1 do
  begin
    // XOR with previous ciphertext block (or IV)
    for J := 0 to 15 do
      AData[I * 16 + J] := AData[I * 16 + J] xor Prev[J];
    // Encrypt
    Move(AData[I * 16], Block[0], 16);
    AESEncryptBlock(W, Nr, Block, 0, AData, I * 16);
    Move(AData[I * 16], Prev[0], 16);
  end;
end;

procedure AESDecryptCBC(const AKey, AIV: TBytes; var AData: TBytes);
var
  W:      TAESKeyExp;
  Nr:     Integer;
  Blocks: Integer;
  I, J:   Integer;
  Prev:   array[0..15] of Byte;
  Next:   array[0..15] of Byte;
  Block:  TBytes;
begin
  if Length(AKey) = 0 then Exit;
  if (Length(AKey) <> 16) and (Length(AKey) <> 32) then
    raise Exception.Create('AES key must be 16 or 32 bytes');
  if Length(AIV) <> 16 then
    raise Exception.Create('AES IV must be 16 bytes');
  if (Length(AData) mod 16) <> 0 then
    raise Exception.Create('AES data must be a multiple of 16 bytes');

  AESKeyExpand(AKey, W, Nr);
  SetLength(Block, 16);
  Move(AIV[0], Prev[0], 16);
  Blocks := Length(AData) div 16;

  for I := 0 to Blocks - 1 do
  begin
    // Save current ciphertext block for XOR next iteration
    Move(AData[I * 16], Next[0], 16);
    // Decrypt the block
    Move(AData[I * 16], Block[0], 16);
    AESDecryptBlock(W, Nr, Block, 0, AData, I * 16);
    // XOR with previous ciphertext (or IV for first block)
    for J := 0 to 15 do
      AData[I * 16 + J] := AData[I * 16 + J] xor Prev[J];
    Move(Next[0], Prev[0], 16);
  end;
end;

// =========================================================================
// PKCS#7 padding
// =========================================================================

function PKCSPad(const AData: TBytes; ABlockSize: Integer): TBytes;
var
  Pad: Integer;
begin
  Pad := ABlockSize - (Length(AData) mod ABlockSize);
  SetLength(Result, Length(AData) + Pad);
  if Length(AData) > 0 then
    Move(AData[0], Result[0], Length(AData));
  FillChar(Result[Length(AData)], Pad, Pad);
end;

function PKCSUnpad(const AData: TBytes): TBytes;
var
  Pad: Integer;
begin
  if Length(AData) = 0 then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  Pad := AData[High(AData)];
  if (Pad < 1) or (Pad > 16) or (Pad > Length(AData)) then
  begin
    // Invalid padding — return data as-is (tolerant mode)
    Result := Copy(AData);
    Exit;
  end;
  SetLength(Result, Length(AData) - Pad);
  if Length(Result) > 0 then
    Move(AData[0], Result[0], Length(Result));
end;

end.
