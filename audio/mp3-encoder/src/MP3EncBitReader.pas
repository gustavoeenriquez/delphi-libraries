unit MP3EncBitReader;

(*
  MP3EncBitReader.pas — MSB-first bit reader for MP3 frame parsing

  Mirror of TMP3BitWriter: bit 0 in the stream is bit 7 (MSB) of byte 0.

    [0xA5]  ReadBits(8) -> $A5
    [0x53]  ReadBits(4) -> 5  then ReadBits(4) -> 3

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
*)

interface

uses
  SysUtils;

type
  TMP3BitReader = record
    Buf   : TBytes;
    BitPos: Integer;   { next bit to read (0 = MSB of byte 0) }
    BitLen: Integer;   { total valid bits }
  end;

{ Initialize from a full byte array. BitLen = Length(ABytes) * 8. }
procedure BitReaderInit(out ABR: TMP3BitReader; const ABytes: TBytes);

{ Initialize with an explicit bit count. }
procedure BitReaderInitBits(out ABR: TMP3BitReader; const ABytes: TBytes;
  ABitLen: Integer);

{ Initialize starting at a byte offset inside ABytes. }
procedure BitReaderInitAt(out ABR: TMP3BitReader; const ABytes: TBytes;
  AByteOffset: Integer);

{ Read NBits (1..25) MSB-first and advance BitPos. Returns 0 on overflow. }
function BitReaderRead(var ABR: TMP3BitReader; NBits: Integer): Cardinal;

{ Read NBits without advancing BitPos. }
function BitReaderPeek(const ABR: TMP3BitReader; NBits: Integer): Cardinal;

{ Advance BitPos by NBits. }
procedure BitReaderSkip(var ABR: TMP3BitReader; NBits: Integer);

{ Remaining valid bits. }
function BitReaderBitsLeft(const ABR: TMP3BitReader): Integer;

implementation

// ---------------------------------------------------------------------------

procedure BitReaderInit(out ABR: TMP3BitReader; const ABytes: TBytes);
begin
  ABR.Buf    := ABytes;
  ABR.BitPos := 0;
  ABR.BitLen := Length(ABytes) * 8;
end;

procedure BitReaderInitBits(out ABR: TMP3BitReader; const ABytes: TBytes;
  ABitLen: Integer);
begin
  ABR.Buf    := ABytes;
  ABR.BitPos := 0;
  ABR.BitLen := ABitLen;
end;

procedure BitReaderInitAt(out ABR: TMP3BitReader; const ABytes: TBytes;
  AByteOffset: Integer);
begin
  ABR.Buf    := ABytes;
  ABR.BitPos := AByteOffset * 8;
  ABR.BitLen := Length(ABytes) * 8;
end;

// ---------------------------------------------------------------------------

function BitReaderPeek(const ABR: TMP3BitReader; NBits: Integer): Cardinal;
var
  Pos, Left, Avail, Shift: Integer;
begin
  Result := 0;
  Pos    := ABR.BitPos;
  Left   := NBits;
  while Left > 0 do begin
    Shift := 7 - (Pos and 7);     { MSB position within the current byte }
    Avail := Shift + 1;            { bits remaining in this byte }
    if Left < Avail then
      Avail := Left;
    Result := (Result shl Avail)
      or Cardinal((ABR.Buf[Pos shr 3] shr (Shift - Avail + 1))
                  and ((1 shl Avail) - 1));
    Inc(Pos, Avail);
    Dec(Left, Avail);
  end;
end;

function BitReaderRead(var ABR: TMP3BitReader; NBits: Integer): Cardinal;
begin
  Result := BitReaderPeek(ABR, NBits);
  Inc(ABR.BitPos, NBits);
end;

procedure BitReaderSkip(var ABR: TMP3BitReader; NBits: Integer);
begin
  Inc(ABR.BitPos, NBits);
end;

function BitReaderBitsLeft(const ABR: TMP3BitReader): Integer;
begin
  Result := ABR.BitLen - ABR.BitPos;
end;

end.
