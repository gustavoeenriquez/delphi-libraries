unit FLACBitWriter;

{
  FLACBitWriter.pas - MSB-first bit writer for FLAC frame encoding

  TFLACBitWriter is the encoder counterpart of TAudioBitReader.
  Accumulates bits into a growable TBytes buffer, MSB-first.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Math;

type
  TFLACBitWriter = record
  private
    FBuf  : TBytes;
    FNBits: Integer;
  public
    procedure Init(InitCapacity: Integer = 1024);

    // Write 1 bit (0 or non-zero → 1)
    procedure PushBit(B: Integer);

    // Write N bits of V, MSB first (N = 1..32)
    procedure PushBits(V: Cardinal; N: Integer);

    // Write a signed integer in two's complement, N bits wide
    procedure PushSigned(V: Integer; N: Integer);

    // Write a unary code: Q zero bits followed by one 1 bit
    procedure PushUnary(Q: Cardinal);

    // Write a Rice-coded signed integer with parameter K
    // Zig-zag encoding: 0→0, 1→2, -1→1, 2→4, -2→3 ...
    procedure PushRice(V: Integer; K: Integer);

    // Pad to the next byte boundary with zero bits
    procedure ByteAlign;

    // Number of complete bytes written so far
    function ByteCount: Integer; inline;

    // Total bits written
    function BitCount: Integer; inline;

    // Return only the written bytes (ByteCount bytes)
    function GetBytes: TBytes;

    // Append all written bytes into Dest TBytes at offset DestOff
    procedure AppendTo(var Dest: TBytes; var DestLen: Integer);
  end;

implementation

procedure TFLACBitWriter.Init(InitCapacity: Integer);
begin
  SetLength(FBuf, InitCapacity);
  FillChar(FBuf[0], InitCapacity, 0);
  FNBits := 0;
end;

procedure TFLACBitWriter.PushBit(B: Integer);
var
  ByteIdx, BitOff: Integer;
begin
  ByteIdx := FNBits shr 3;
  BitOff  := 7 - (FNBits and 7);
  if ByteIdx >= Length(FBuf) then
  begin
    SetLength(FBuf, Length(FBuf) * 2);
    FillChar(FBuf[Length(FBuf) div 2], Length(FBuf) div 2, 0);
  end;
  if B <> 0 then
    FBuf[ByteIdx] := FBuf[ByteIdx] or Byte(1 shl BitOff);
  Inc(FNBits);
end;

procedure TFLACBitWriter.PushBits(V: Cardinal; N: Integer);
var
  J: Integer;
begin
  for J := N - 1 downto 0 do
    PushBit((V shr J) and 1);
end;

procedure TFLACBitWriter.PushSigned(V: Integer; N: Integer);
var
  U: Cardinal;
begin
  // Two's complement: mask to N bits
  U := Cardinal(V) and ((Cardinal(1) shl N) - 1);
  PushBits(U, N);
end;

procedure TFLACBitWriter.PushUnary(Q: Cardinal);
var
  J: Cardinal;
begin
  if Q > 524288 then  // sanity guard: > ~512k unary bits = corrupted residual
    raise ERangeError.CreateFmt('PushUnary: Q=%u exceeds limit (corrupted residual)', [Q]);
  for J := 1 to Q do PushBit(0);
  PushBit(1);
end;

procedure TFLACBitWriter.PushRice(V: Integer; K: Integer);
var
  U, Q, R: Cardinal;
begin
  // Zig-zag encode signed → unsigned
  if V >= 0 then U := Cardinal(V) shl 1
  else U := (Cardinal(-V) shl 1) - 1;

  Q := U shr K;
  R := U and ((1 shl K) - 1);
  PushUnary(Q);
  if K > 0 then PushBits(R, K);
end;

procedure TFLACBitWriter.ByteAlign;
begin
  while (FNBits and 7) <> 0 do PushBit(0);
end;

function TFLACBitWriter.ByteCount: Integer;
begin
  Result := FNBits shr 3;
end;

function TFLACBitWriter.BitCount: Integer;
begin
  Result := FNBits;
end;

function TFLACBitWriter.GetBytes: TBytes;
var
  N: Integer;
begin
  N := ByteCount;
  SetLength(Result, N);
  if N > 0 then Move(FBuf[0], Result[0], N);
end;

procedure TFLACBitWriter.AppendTo(var Dest: TBytes; var DestLen: Integer);
var
  N: Integer;
begin
  N := ByteCount;
  if N = 0 then Exit;
  if DestLen + N > Length(Dest) then
    SetLength(Dest, Max(DestLen + N, Length(Dest) * 2));
  Move(FBuf[0], Dest[DestLen], N);
  Inc(DestLen, N);
end;

end.
