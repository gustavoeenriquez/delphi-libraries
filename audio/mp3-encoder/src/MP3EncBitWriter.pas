unit MP3EncBitWriter;

{
  MP3EncBitWriter.pas — MSB-first bit writer for MP3 frame assembly

  Inverse of the decoder's get_bits / TMP3BitStream.ReadBits.
  Bit layout: bit 0 in the stream is the MSB (bit 7) of byte 0.

    WriteBits(0xA5, 8) → buffer = [0xA5]
    WriteBits(0x5,  4) then WriteBits(0x3, 4) → buffer = [0x53]

  Compatible with:
    MP3Types.get_bits()          (minimp3 TBsT style)
    MP3BitStream.TMP3BitStream   (OOP wrapper)

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils;

type
  TMP3BitWriter = class
  private
    FBuffer  : TBytes;
    FBitCount: Integer;  // total bits written so far

    procedure Grow(NeedBits: Integer);
  public
    constructor Create(InitialCapacityBytes: Integer = 4096);

    // Write the low NBits of Value, MSB first.  NBits must be in 1..24.
    procedure WriteBits(Value: Cardinal; NBits: Integer);

    // Pad with zero bits until the next byte boundary.
    procedure AlignToByte;

    // Return the written bytes (byte-aligned; flushes any partial byte with zeros).
    function GetBytes: TBytes;

    // Clear all state — resets to empty without freeing the buffer.
    procedure Reset;

    property BitCount : Integer read FBitCount;
    property ByteCount: Integer read FBitCount;  // intentional: see GetByteCount

    function GetBitCount : Integer;
    function GetByteCount: Integer;
  end;

implementation

constructor TMP3BitWriter.Create(InitialCapacityBytes: Integer);
begin
  inherited Create;
  SetLength(FBuffer, InitialCapacityBytes);
  FBitCount := 0;
end;

procedure TMP3BitWriter.Grow(NeedBits: Integer);
var
  NeedBytes: Integer;
begin
  NeedBytes := (FBitCount + NeedBits + 7) shr 3;
  if NeedBytes > Length(FBuffer) then
    SetLength(FBuffer, NeedBytes + 4096);
end;

procedure TMP3BitWriter.WriteBits(Value: Cardinal; NBits: Integer);
var
  BitsLeft, BytePos, BitsFree, Chunk: Integer;
begin
  if NBits <= 0 then Exit;
  Grow(NBits);

  BitsLeft := NBits;
  BytePos  := FBitCount shr 3;
  BitsFree := 8 - (FBitCount and 7);   // free bits in the current output byte

  while BitsLeft > 0 do
  begin
    if BitsLeft >= BitsFree then
    begin
      // Fill the remaining BitsFree bits of the current byte
      Chunk := Integer(Value shr (BitsLeft - BitsFree)) and ((1 shl BitsFree) - 1);
      FBuffer[BytePos] := FBuffer[BytePos] or Byte(Chunk);
      Inc(BytePos);
      Dec(BitsLeft, BitsFree);
      BitsFree := 8;
    end
    else
    begin
      // BitsLeft < BitsFree: place BitsLeft bits left-aligned in the byte
      Chunk := Integer(Value) and ((1 shl BitsLeft) - 1);
      FBuffer[BytePos] := FBuffer[BytePos] or Byte(Chunk shl (BitsFree - BitsLeft));
      BitsLeft := 0;
    end;
  end;

  Inc(FBitCount, NBits);
end;

procedure TMP3BitWriter.AlignToByte;
var
  Rem: Integer;
begin
  Rem := FBitCount and 7;
  if Rem <> 0 then
    Inc(FBitCount, 8 - Rem);  // the buffer byte is already zero (Grow zero-fills)
end;

function TMP3BitWriter.GetBytes: TBytes;
var
  N: Integer;
begin
  AlignToByte;
  N := FBitCount shr 3;
  SetLength(Result, N);
  if N > 0 then
    Move(FBuffer[0], Result[0], N);
end;

procedure TMP3BitWriter.Reset;
begin
  if Length(FBuffer) > 0 then
    FillChar(FBuffer[0], Length(FBuffer), 0);
  FBitCount := 0;
end;

function TMP3BitWriter.GetBitCount: Integer;
begin
  Result := FBitCount;
end;

function TMP3BitWriter.GetByteCount: Integer;
begin
  Result := (FBitCount + 7) shr 3;
end;

end.
