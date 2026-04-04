unit AudioCRC;

{
  AudioCRC.pas - CRC routines for the audio codec stack

  Provides the three CRC variants used by the codecs:

    CRC-8  (FLAC frame header)
      Poly: 0x07  (x^8 + x^2 + x + 1), initial value 0x00

    CRC-16 (FLAC frame footer)
      Poly: 0x8005 reflected as 0xA001, BUT FLAC uses the non-reflected form:
      FLAC CRC-16 poly: 0x8005, init 0x0000, no reflection, no final XOR.
      This matches the FLAC reference decoder (libFLAC).

    CRC-32 (Ogg page checksum)
      Poly: 0x04C11DB7, init 0x00000000, no reflection, no final XOR.
      This matches the Ogg specification (RFC 3533).

  Usage:
    Incremental:
      Crc := CRC8_Init;
      Crc := CRC8_Update(Crc, Buf, Len);
      if Crc <> ExpectedCrc then ...

    One-shot:
      Crc := CRC8_Calc(Buf, Len);

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

// ---------------------------------------------------------------------------
// CRC-8  (FLAC frame header, poly 0x07)
// ---------------------------------------------------------------------------

function CRC8_Init: Byte; inline;
function CRC8_Update(Crc: Byte; Data: PByte; Len: Integer): Byte;
function CRC8_Calc(Data: PByte; Len: Integer): Byte;

// ---------------------------------------------------------------------------
// CRC-16  (FLAC frame footer, poly 0x8005, no reflection)
// ---------------------------------------------------------------------------

function CRC16_Init: Word; inline;
function CRC16_Update(Crc: Word; Data: PByte; Len: Integer): Word;
function CRC16_Calc(Data: PByte; Len: Integer): Word;

// ---------------------------------------------------------------------------
// CRC-32  (Ogg pages, poly 0x04C11DB7, no reflection)
// ---------------------------------------------------------------------------

function CRC32Ogg_Init: Cardinal; inline;
function CRC32Ogg_Update(Crc: Cardinal; Data: PByte; Len: Integer): Cardinal;
function CRC32Ogg_Calc(Data: PByte; Len: Integer): Cardinal;

implementation

// ---------------------------------------------------------------------------
// Table generation at unit initialisation
// ---------------------------------------------------------------------------

var
  Table8   : array[0..255] of Byte;
  Table16  : array[0..255] of Word;
  Table32Ogg: array[0..255] of Cardinal;

procedure BuildTable8;
var
  I, J: Integer;
  Crc: Byte;
begin
  for I := 0 to 255 do
  begin
    Crc := Byte(I);
    for J := 0 to 7 do
      if (Crc and $80) <> 0 then
        Crc := (Crc shl 1) xor $07
      else
        Crc := Crc shl 1;
    Table8[I] := Crc;
  end;
end;

procedure BuildTable16;
// FLAC CRC-16: poly 0x8005, MSB-first (no reflection)
var
  I, J: Integer;
  Crc: Word;
begin
  for I := 0 to 255 do
  begin
    Crc := Word(I shl 8);
    for J := 0 to 7 do
      if (Crc and $8000) <> 0 then
        Crc := (Crc shl 1) xor $8005
      else
        Crc := Crc shl 1;
    Table16[I] := Crc;
  end;
end;

procedure BuildTable32Ogg;
// Ogg CRC-32: poly 0x04C11DB7, MSB-first (no reflection), init 0
var
  I, J: Integer;
  Crc: Cardinal;
begin
  for I := 0 to 255 do
  begin
    Crc := Cardinal(I) shl 24;
    for J := 0 to 7 do
      if (Crc and $80000000) <> 0 then
        Crc := (Crc shl 1) xor $04C11DB7
      else
        Crc := Crc shl 1;
    Table32Ogg[I] := Crc;
  end;
end;

// ---------------------------------------------------------------------------
// CRC-8
// ---------------------------------------------------------------------------

function CRC8_Init: Byte;
begin
  Result := 0;
end;

function CRC8_Update(Crc: Byte; Data: PByte; Len: Integer): Byte;
var
  I: Integer;
begin
  for I := 0 to Len - 1 do
  begin
    Crc := Table8[Crc xor Data^];
    Inc(Data);
  end;
  Result := Crc;
end;

function CRC8_Calc(Data: PByte; Len: Integer): Byte;
begin
  Result := CRC8_Update(CRC8_Init, Data, Len);
end;

// ---------------------------------------------------------------------------
// CRC-16
// ---------------------------------------------------------------------------

function CRC16_Init: Word;
begin
  Result := 0;
end;

function CRC16_Update(Crc: Word; Data: PByte; Len: Integer): Word;
var
  I: Integer;
begin
  for I := 0 to Len - 1 do
  begin
    Crc := (Crc shl 8) xor Table16[(Crc shr 8) xor Data^];
    Inc(Data);
  end;
  Result := Crc;
end;

function CRC16_Calc(Data: PByte; Len: Integer): Word;
begin
  Result := CRC16_Update(CRC16_Init, Data, Len);
end;

// ---------------------------------------------------------------------------
// CRC-32 (Ogg)
// ---------------------------------------------------------------------------

function CRC32Ogg_Init: Cardinal;
begin
  Result := 0;
end;

function CRC32Ogg_Update(Crc: Cardinal; Data: PByte; Len: Integer): Cardinal;
var
  I: Integer;
begin
  for I := 0 to Len - 1 do
  begin
    Crc := (Crc shl 8) xor Table32Ogg[(Crc shr 24) xor Data^];
    Inc(Data);
  end;
  Result := Crc;
end;

function CRC32Ogg_Calc(Data: PByte; Len: Integer): Cardinal;
begin
  Result := CRC32Ogg_Update(CRC32Ogg_Init, Data, Len);
end;

// ---------------------------------------------------------------------------
// Initialisation
// ---------------------------------------------------------------------------

initialization
  BuildTable8;
  BuildTable16;
  BuildTable32Ogg;

end.
