unit uLZ4;

{
  uLZ4.pas -- LZ4 block + frame codec

  Block format:  raw LZ4 sequences with no headers or checksums.
  Frame format:  LZ4 Frame v1.6, independent blocks, content checksum.
                 Compatible with the lz4 CLI tool and liblz4.

  Public API
  ----------
  LZ4BlockBound(Len)               -- safe upper bound for compressed output
  LZ4BlockCompress(...)            -- compress a block (pointer overload)
  LZ4BlockDecompress(...)          -- decompress a block (pointer overload)
  LZ4BlockCompressBytes(...)       -- TBytes convenience wrapper
  LZ4BlockDecompressBytes(...)     -- TBytes convenience wrapper
  LZ4FrameCompress(...)            -- encode to LZ4 frame format
  LZ4FrameDecompress(...)          -- decode an LZ4 frame

  LZ4BlockDecompress and LZ4FrameDecompress raise ELZ4Error on malformed input.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  SysUtils, Math;

type
  ELZ4Error = class(Exception);

// ---------------------------------------------------------------------------
// Block format (raw, no headers)
// ---------------------------------------------------------------------------

// Returns the maximum compressed output size for a sourceLen-byte input.
// Always allocate at least this many bytes before calling LZ4BlockCompress.
function LZ4BlockBound(ASourceLen: Integer): Integer; inline;

// Compress ASrc into ADst. ADst must be at least LZ4BlockBound(ASrcLen) bytes.
// Returns the compressed byte count, or 0 if ADst was too small.
function LZ4BlockCompress(ASrc: PByte; ASrcLen: Integer;
  ADst: PByte; AMaxDst: Integer): Integer;

// Decompress a compressed block into ADst (pre-allocated, AMaxDst bytes).
// Returns the decompressed byte count; raises ELZ4Error on corrupt data.
function LZ4BlockDecompress(ASrc: PByte; ASrcLen: Integer;
  ADst: PByte; AMaxDst: Integer): Integer;

// TBytes convenience wrappers
function LZ4BlockCompressBytes(const ASrc: TBytes): TBytes;
function LZ4BlockDecompressBytes(const ASrc: TBytes; AOriginalLen: Integer): TBytes;

// ---------------------------------------------------------------------------
// Frame format  (magic = 0x184D2204)
// ---------------------------------------------------------------------------

// Compress ASrc to an LZ4 frame (64 KB blocks, content checksum on).
// Output is compatible with liblz4 and the lz4 command-line tool.
function LZ4FrameCompress(const ASrc: TBytes): TBytes;

// Decompress an LZ4 frame. Raises ELZ4Error on bad magic or corrupt data.
function LZ4FrameDecompress(const ASrc: TBytes): TBytes;

implementation

// ===========================================================================
// Constants
// ===========================================================================

const
  LZ4_MINMATCH     = 4;
  LZ4_HASHBITS     = 12;
  LZ4_HASHTABLE    = 1 shl LZ4_HASHBITS;   // 4096 entries
  LZ4_HASHMASK     = LZ4_HASHTABLE - 1;
  LZ4_MAXOFFSET    = $FFFF;
  LZ4_MFLIMIT      = 12;   // matches may not start in the last MFLIMIT bytes
  LZ4_LASTLITERALS = 5;    // last 5 bytes of input are always literals

  LZ4_FRAME_MAGIC    = Cardinal($184D2204);
  LZ4_FRAME_MAXBLOCK = 64 * 1024;            // 64 KB blocks
  LZ4_FRAME_FLG      = Byte($64);            // version=01 | B.Indep=1 | C.Checksum=1
  LZ4_FRAME_BD       = Byte($40);            // maxBlockSize code 4 = 64 KB

// ===========================================================================
// xxHash-32 (frame header + content checksums)
// ===========================================================================

const
  XXH_P1 = Cardinal(2654435761);
  XXH_P2 = Cardinal(2246822519);
  XXH_P3 = Cardinal(3266489917);
  XXH_P4 = Cardinal(668265263);
  XXH_P5 = Cardinal(374761393);

function XXH_Rot(V: Cardinal; N: Byte): Cardinal; inline;
begin
  Result := (V shl N) or (V shr (32 - N));
end;

function XXHash32(AData: PByte; ALen: Integer; ASeed: Cardinal = 0): Cardinal;
var
  V1, V2, V3, V4, H: Cardinal;
  P, PEnd: PByte;
  K: Cardinal;
begin
  if ALen = 0 then
  begin
    H := ASeed + XXH_P5;
    H := H xor (H shr 15); H := H * XXH_P2;
    H := H xor (H shr 13); H := H * XXH_P3;
    H := H xor (H shr 16);
    Exit(H);
  end;

  P    := AData;
  PEnd := AData + ALen;

  if ALen >= 16 then
  begin
    V1 := ASeed + XXH_P1 + XXH_P2;
    V2 := ASeed + XXH_P2;
    V3 := ASeed;
    V4 := ASeed - XXH_P1;
    repeat
      Move(P[0], K, 4); V1 := XXH_Rot(V1 + K * XXH_P2, 13) * XXH_P1; Inc(P, 4);
      Move(P[0], K, 4); V2 := XXH_Rot(V2 + K * XXH_P2, 13) * XXH_P1; Inc(P, 4);
      Move(P[0], K, 4); V3 := XXH_Rot(V3 + K * XXH_P2, 13) * XXH_P1; Inc(P, 4);
      Move(P[0], K, 4); V4 := XXH_Rot(V4 + K * XXH_P2, 13) * XXH_P1; Inc(P, 4);
    until PEnd - P < 16;
    H := XXH_Rot(V1, 1) + XXH_Rot(V2, 7) + XXH_Rot(V3, 12) + XXH_Rot(V4, 18);
  end
  else
    H := ASeed + XXH_P5;

  Inc(H, Cardinal(ALen));

  while PEnd - P >= 4 do
  begin
    Move(P[0], K, 4);
    H := XXH_Rot(H + K * XXH_P3, 17) * XXH_P4;
    Inc(P, 4);
  end;
  while P < PEnd do
  begin
    H := XXH_Rot(H + P^ * XXH_P5, 11) * XXH_P1;
    Inc(P);
  end;

  H := H xor (H shr 15); H := H * XXH_P2;
  H := H xor (H shr 13); H := H * XXH_P3;
  H := H xor (H shr 16);
  Result := H;
end;

// ===========================================================================
// Block helpers
// ===========================================================================

function LZ4BlockBound(ASourceLen: Integer): Integer;
begin
  Result := ASourceLen + (ASourceLen div 255) + 16;
end;

function LZ4Hash4(P: PByte): Integer; inline;
var V: Cardinal;
begin
  Move(P^, V, 4);
  Result := Integer(((V * 2654435761) shr (32 - LZ4_HASHBITS)) and LZ4_HASHMASK);
end;

procedure WriteVarLen(var P: PByte; V: Integer); inline;
begin
  while V >= 255 do begin P^ := 255; Inc(P); Dec(V, 255); end;
  P^ := Byte(V); Inc(P);
end;

function ReadVarLen(var P: PByte; PEnd: PByte; var Acc: Integer): Boolean;
var B: Byte;
begin
  repeat
    if P >= PEnd then Exit(False);
    B := P^; Inc(P);
    Inc(Acc, B);
  until B <> 255;
  Result := True;
end;

// ===========================================================================
// LZ4BlockCompress
// ===========================================================================

function LZ4BlockCompress(ASrc: PByte; ASrcLen: Integer;
  ADst: PByte; AMaxDst: Integer): Integer;
var
  HashTable: array[0..LZ4_HASHTABLE - 1] of Integer;
  Base, Src, SrcEnd, SrcLimit, MatchEnd, LitStart: PByte;
  Ref, Dst, DstEnd, Token: PByte;
  LitLen, MatchLen, ML: Integer;
  Offset: Word;
  H: Integer;
begin
  Result := 0;

  if AMaxDst < LZ4BlockBound(ASrcLen) then Exit;

  if ASrcLen = 0 then
  begin
    ADst^ := 0;
    Result := 1;
    Exit;
  end;

  FillChar(HashTable, SizeOf(HashTable), $FF); // -1 = no entry

  Base     := ASrc;
  Src      := ASrc;
  SrcEnd   := ASrc + ASrcLen;
  SrcLimit := SrcEnd - LZ4_MFLIMIT;
  MatchEnd := SrcEnd - LZ4_LASTLITERALS;
  LitStart := ASrc;
  Dst      := ADst;
  DstEnd   := ADst + AMaxDst;

  // Inputs shorter than MFLIMIT cannot start any match; emit all as literals
  if ASrcLen < LZ4_MFLIMIT then
  begin
    LitLen := ASrcLen;
    Token  := Dst; Inc(Dst);
    Token^ := Byte(Min(LitLen, 15) shl 4);
    if LitLen >= 15 then WriteVarLen(Dst, LitLen - 15);
    Move(ASrc^, Dst^, LitLen);
    Inc(Dst, LitLen);
    Result := Dst - ADst;
    Exit;
  end;

  // Main loop: find matches using a 4096-entry hash table
  while Src < SrcLimit do
  begin
    H   := LZ4Hash4(Src);
    Ref := Base + HashTable[H];
    HashTable[H] := Src - Base;

    if (Ref >= Base) and
       (Integer(Src - Ref) <= LZ4_MAXOFFSET) and
       (PCardinal(Src)^ = PCardinal(Ref)^) then
    begin
      // Extend the 4-byte match as far as possible
      MatchLen := LZ4_MINMATCH;
      while (Src + MatchLen < MatchEnd) and
            ((Src + MatchLen)^ = (Ref + MatchLen)^) do
        Inc(MatchLen);

      LitLen := Src - LitStart;
      ML     := MatchLen - LZ4_MINMATCH;

      Token  := Dst; Inc(Dst);
      Token^ := Byte((Min(LitLen, 15) shl 4) or Min(ML, 15));
      if LitLen >= 15 then WriteVarLen(Dst, LitLen - 15);
      Move(LitStart^, Dst^, LitLen); Inc(Dst, LitLen);

      Offset := Word(Src - Ref);
      Move(Offset, Dst^, 2); Inc(Dst, 2);

      if ML >= 15 then WriteVarLen(Dst, ML - 15);

      Inc(Src, MatchLen);
      LitStart := Src;
    end
    else
      Inc(Src);
  end;

  // Final literal run (remaining bytes after last match, including last MFLIMIT)
  LitLen := SrcEnd - LitStart;
  Token  := Dst; Inc(Dst);
  Token^ := Byte(Min(LitLen, 15) shl 4);  // low nibble = 0 (no match follows)
  if LitLen >= 15 then WriteVarLen(Dst, LitLen - 15);
  Move(LitStart^, Dst^, LitLen); Inc(Dst, LitLen);

  if Dst > DstEnd then Result := 0
  else                  Result := Dst - ADst;
end;

// ===========================================================================
// LZ4BlockDecompress
// ===========================================================================

function LZ4BlockDecompress(ASrc: PByte; ASrcLen: Integer;
  ADst: PByte; AMaxDst: Integer): Integer;
var
  Src, SrcEnd, Dst, DstEnd, DstBase, MatchSrc: PByte;
  Token: Byte;
  LitLen, MatchLen, I: Integer;
  Offset: Word;
begin
  Src     := ASrc;
  SrcEnd  := ASrc + ASrcLen;
  Dst     := ADst;
  DstEnd  := ADst + AMaxDst;
  DstBase := ADst;

  while Src < SrcEnd do
  begin
    Token := Src^; Inc(Src);

    // Literal length
    LitLen := Token shr 4;
    if (LitLen = 15) and not ReadVarLen(Src, SrcEnd, LitLen) then
      raise ELZ4Error.Create('LZ4: truncated literal length');

    if Src + LitLen > SrcEnd then
      raise ELZ4Error.Create('LZ4: literal run extends beyond compressed block');
    if Dst + LitLen > DstEnd then
      raise ELZ4Error.Create('LZ4: output overflow in literal copy');
    Move(Src^, Dst^, LitLen);
    Inc(Src, LitLen);
    Inc(Dst, LitLen);

    if Src >= SrcEnd then Break; // last sequence has no match

    // Match offset (LE16)
    if Src + 2 > SrcEnd then
      raise ELZ4Error.Create('LZ4: truncated match offset');
    Move(Src^, Offset, 2); Inc(Src, 2);
    if Offset = 0 then
      raise ELZ4Error.Create('LZ4: invalid match offset = 0');

    // Match length
    MatchLen := (Token and $0F) + LZ4_MINMATCH;
    if (Token and $0F = 15) and not ReadVarLen(Src, SrcEnd, MatchLen) then
      raise ELZ4Error.Create('LZ4: truncated match length');

    if Dst + MatchLen > DstEnd then
      raise ELZ4Error.Create('LZ4: output overflow in match copy');
    MatchSrc := Dst - Offset;
    if MatchSrc < DstBase then
      raise ELZ4Error.Create('LZ4: match offset references before start of output');

    // Byte-by-byte copy handles overlapping matches correctly (e.g. RLE with offset=1)
    for I := 0 to MatchLen - 1 do
    begin
      Dst^ := (MatchSrc + I)^;
      Inc(Dst);
    end;
  end;

  Result := Dst - DstBase;
end;

// ===========================================================================
// TBytes wrappers
// ===========================================================================

function LZ4BlockCompressBytes(const ASrc: TBytes): TBytes;
var
  Bound, Len: Integer;
begin
  if Length(ASrc) = 0 then
  begin
    SetLength(Result, 1);
    Result[0] := 0;
    Exit;
  end;
  Bound := LZ4BlockBound(Length(ASrc));
  SetLength(Result, Bound);
  Len := LZ4BlockCompress(@ASrc[0], Length(ASrc), @Result[0], Bound);
  if Len = 0 then
    raise ELZ4Error.Create('LZ4BlockCompressBytes: compression failed');
  SetLength(Result, Len);
end;

function LZ4BlockDecompressBytes(const ASrc: TBytes; AOriginalLen: Integer): TBytes;
begin
  if AOriginalLen = 0 then begin Result := nil; Exit; end;
  SetLength(Result, AOriginalLen);
  LZ4BlockDecompress(@ASrc[0], Length(ASrc), @Result[0], AOriginalLen);
end;

// ===========================================================================
// Frame format
// ===========================================================================

function LZ4FrameCompress(const ASrc: TBytes): TBytes;
var
  SrcLen, SPos, DPos, BlockLen, CompLen: Integer;
  Dst       : TBytes;
  CompBuf   : TBytes;
  BlockSrc  : PByte;
  BlockWord : Cardinal;
  FLGBDs    : array[0..1] of Byte;
  HC        : Byte;
  ContentCRC: Cardinal;
begin
  SrcLen := Length(ASrc);

  // Over-allocate: frame header (7) + worst-case blocks + end mark (4) + checksum (4)
  SetLength(Dst, 7 + ((SrcLen div LZ4_FRAME_MAXBLOCK) + 1) *
    (LZ4BlockBound(LZ4_FRAME_MAXBLOCK) + 4) + 8);
  DPos := 0;

  // Magic
  BlockWord := LZ4_FRAME_MAGIC;
  Move(BlockWord, Dst[DPos], 4); Inc(DPos, 4);

  // FLG + BD
  Dst[DPos] := LZ4_FRAME_FLG; Inc(DPos);
  Dst[DPos] := LZ4_FRAME_BD;  Inc(DPos);

  // Header checksum: (xxhash32(FLG||BD) >> 8) & 0xFF
  FLGBDs[0] := LZ4_FRAME_FLG;
  FLGBDs[1] := LZ4_FRAME_BD;
  HC := Byte((XXHash32(@FLGBDs[0], 2) shr 8) and $FF);
  Dst[DPos] := HC; Inc(DPos);

  // Data blocks
  SetLength(CompBuf, LZ4BlockBound(LZ4_FRAME_MAXBLOCK));
  SPos := 0;
  while SPos < SrcLen do
  begin
    BlockLen := Min(LZ4_FRAME_MAXBLOCK, SrcLen - SPos);
    BlockSrc := @ASrc[SPos];

    CompLen := LZ4BlockCompress(BlockSrc, BlockLen, @CompBuf[0], Length(CompBuf));

    if (CompLen = 0) or (CompLen >= BlockLen) then
    begin
      // Store uncompressed (high bit set in block size)
      BlockWord := Cardinal(BlockLen) or $80000000;
      Move(BlockWord, Dst[DPos], 4); Inc(DPos, 4);
      Move(BlockSrc^, Dst[DPos], BlockLen); Inc(DPos, BlockLen);
    end
    else
    begin
      BlockWord := Cardinal(CompLen);
      Move(BlockWord, Dst[DPos], 4); Inc(DPos, 4);
      Move(CompBuf[0], Dst[DPos], CompLen); Inc(DPos, CompLen);
    end;

    Inc(SPos, BlockLen);
  end;

  // End mark
  BlockWord := 0;
  Move(BlockWord, Dst[DPos], 4); Inc(DPos, 4);

  // Content checksum
  if SrcLen > 0 then
    ContentCRC := XXHash32(@ASrc[0], SrcLen)
  else
    ContentCRC := XXHash32(nil, 0);
  Move(ContentCRC, Dst[DPos], 4); Inc(DPos, 4);

  SetLength(Dst, DPos);
  Result := Dst;
end;

function LZ4FrameDecompress(const ASrc: TBytes): TBytes;
var
  SrcLen, SPos, OPos, BlockLen, DecompLen: Integer;
  Magic     : Cardinal;
  FLG, BD   : Byte;
  HC, HCExp : Byte;
  FLGBDs    : array[0..1] of Byte;
  HasCksum  : Boolean;
  BlockWord : Cardinal;
  IsUncomp  : Boolean;
  OutBuf    : TBytes;
  ContentCRC, ExpCRC: Cardinal;
begin
  SrcLen := Length(ASrc);
  if SrcLen < 7 then
    raise ELZ4Error.Create('LZ4: frame too short');

  SPos := 0;

  // Magic number
  Move(ASrc[SPos], Magic, 4); Inc(SPos, 4);
  if Magic <> LZ4_FRAME_MAGIC then
    raise ELZ4Error.Create('LZ4: invalid frame magic number');

  // FLG byte
  FLG := ASrc[SPos]; Inc(SPos);
  if (FLG shr 6) <> 1 then
    raise ELZ4Error.Create('LZ4: unsupported frame version');
  HasCksum := (FLG and $04) <> 0;
  if (FLG and $08) <> 0 then Inc(SPos, 8);  // skip content size
  if (FLG and $01) <> 0 then Inc(SPos, 4);  // skip dict ID

  // BD byte
  if SPos >= SrcLen then raise ELZ4Error.Create('LZ4: truncated frame header');
  BD := ASrc[SPos]; Inc(SPos);

  // Verify header checksum
  if SPos >= SrcLen then raise ELZ4Error.Create('LZ4: truncated frame header');
  FLGBDs[0] := FLG; FLGBDs[1] := BD;
  HCExp := Byte((XXHash32(@FLGBDs[0], 2) shr 8) and $FF);
  HC    := ASrc[SPos]; Inc(SPos);
  if HC <> HCExp then
    raise ELZ4Error.Create('LZ4: header checksum mismatch');

  // Decode blocks
  SetLength(OutBuf, Max(SrcLen * 4, LZ4_FRAME_MAXBLOCK));
  OPos := 0;

  while SPos + 4 <= SrcLen do
  begin
    Move(ASrc[SPos], BlockWord, 4); Inc(SPos, 4);
    if BlockWord = 0 then Break; // end mark

    IsUncomp := (BlockWord and $80000000) <> 0;
    BlockLen := Integer(BlockWord and $7FFFFFFF);

    if SPos + BlockLen > SrcLen then
      raise ELZ4Error.Create('LZ4: block extends beyond frame');

    // Ensure output buffer has room for a full decompressed block
    while Length(OutBuf) - OPos < LZ4_FRAME_MAXBLOCK + 256 do
      SetLength(OutBuf, Length(OutBuf) + LZ4_FRAME_MAXBLOCK * 2);

    if IsUncomp then
    begin
      Move(ASrc[SPos], OutBuf[OPos], BlockLen);
      Inc(OPos, BlockLen);
    end
    else
    begin
      DecompLen := LZ4BlockDecompress(@ASrc[SPos], BlockLen,
        @OutBuf[OPos], Length(OutBuf) - OPos);
      Inc(OPos, DecompLen);
    end;

    Inc(SPos, BlockLen);
  end;

  // Content checksum
  if HasCksum and (SPos + 4 <= SrcLen) then
  begin
    Move(ASrc[SPos], ContentCRC, 4);
    if OPos > 0 then
      ExpCRC := XXHash32(@OutBuf[0], OPos)
    else
      ExpCRC := XXHash32(nil, 0);
    if ContentCRC <> ExpCRC then
      raise ELZ4Error.Create('LZ4: content checksum mismatch');
  end;

  SetLength(OutBuf, OPos);
  Result := OutBuf;
end;

end.
