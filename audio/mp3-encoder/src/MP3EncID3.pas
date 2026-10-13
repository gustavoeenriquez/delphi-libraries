unit MP3EncID3;

(*
  MP3EncID3.pas — ID3v1.1 tag writer and reader for MP3 files

  ID3v1.1 tag structure (128 bytes, appended to end of MP3 file):
    Offset   0  "TAG"       (3 bytes, magic)
    Offset   3  Title       (30 bytes, ASCII, zero-padded)
    Offset  33  Artist      (30 bytes)
    Offset  63  Album       (30 bytes)
    Offset  93  Year        (4 bytes, ASCII string, e.g. "2024")
    Offset  97  Comment     (28 bytes)
    Offset 125  Zero byte   (0x00, ID3v1.1 track field indicator)
    Offset 126  Track       (1 byte, 0 = not set)
    Offset 127  Genre       (1 byte, 255 = unknown)

  Strings longer than their field are silently truncated.
  Strings shorter than their field are zero-padded on the right.

  Reference: https://id3.org/ID3v1
  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
*)

interface

uses
  SysUtils,
  Classes;

const
  ID3_TAG_SIZE = 128;  { fixed size of one ID3v1 tag }

type
  TID3v1Tag = record
    Title   : string;  { max 30 chars }
    Artist  : string;  { max 30 chars }
    Album   : string;  { max 30 chars }
    Year    : string;  { max 4 chars  }
    Comment : string;  { max 28 chars }
    Track   : Byte;    { 0 = not set  }
    Genre   : Byte;    { 255 = unknown }
  end;

{ Write a 128-byte ID3v1.1 tag to AStream at current position. }
procedure ID3WriteTag(AStream: TStream; const ATag: TID3v1Tag);

{ Read an ID3v1.1 tag from the last 128 bytes of AStream.
  Returns True if a valid "TAG" magic was found. }
function ID3ReadTag(AStream: TStream; out ATag: TID3v1Tag): Boolean;

{ Return True if the last 128 bytes of AStream contain a valid ID3v1 tag. }
function ID3HasTag(AStream: TStream): Boolean;

{ Remove an existing ID3v1 tag by truncating the stream by 128 bytes.
  Returns True if a tag was found and removed; False if none was present. }
function ID3RemoveTag(AStream: TStream): Boolean;

implementation

const
  C_MAGIC: array[0..2] of Byte = ($54, $41, $47);  { 'T', 'A', 'G' }

// Write exactly N bytes from S (truncate if longer, zero-pad if shorter)
procedure WriteFixedStr(AStream: TStream; const S: string; N: Integer);
var
  buf: TBytes;
  i, len: Integer;
begin
  SetLength(buf, N);
  FillChar(buf[0], N, 0);
  len := Length(S);
  if len > N then len := N;
  for i := 1 to len do
    buf[i - 1] := Byte(Ord(S[i]));
  AStream.WriteBuffer(buf[0], N);
end;

// Read ALen bytes from ABuf at AOffset, stripping trailing zero bytes
function ReadFixedStr(const ABuf: array of Byte;
  AOffset, ALen: Integer): string;
var
  i, last: Integer;
begin
  last := AOffset + ALen - 1;
  while (last >= AOffset) and (ABuf[last] = 0) do
    Dec(last);
  if last < AOffset then begin
    Result := '';
    Exit;
  end;
  SetLength(Result, last - AOffset + 1);
  for i := AOffset to last do
    Result[i - AOffset + 1] := Char(ABuf[i]);
end;

// ---------------------------------------------------------------------------

procedure ID3WriteTag(AStream: TStream; const ATag: TID3v1Tag);
var
  zero: Byte;
begin
  AStream.WriteBuffer(C_MAGIC, 3);
  WriteFixedStr(AStream, ATag.Title,   30);
  WriteFixedStr(AStream, ATag.Artist,  30);
  WriteFixedStr(AStream, ATag.Album,   30);
  WriteFixedStr(AStream, ATag.Year,     4);
  WriteFixedStr(AStream, ATag.Comment, 28);
  zero := 0;
  AStream.WriteBuffer(zero, 1);        { ID3v1.1 marker }
  AStream.WriteBuffer(ATag.Track, 1);
  AStream.WriteBuffer(ATag.Genre, 1);
end;

function ID3ReadTag(AStream: TStream; out ATag: TID3v1Tag): Boolean;
var
  buf: array[0..ID3_TAG_SIZE - 1] of Byte;
begin
  Result := False;
  ATag   := Default(TID3v1Tag);
  if AStream.Size < ID3_TAG_SIZE then Exit;
  AStream.Seek(-ID3_TAG_SIZE, soEnd);
  AStream.ReadBuffer(buf, ID3_TAG_SIZE);
  if (buf[0] <> $54) or (buf[1] <> $41) or (buf[2] <> $47) then Exit;
  ATag.Title   := ReadFixedStr(buf,  3, 30);
  ATag.Artist  := ReadFixedStr(buf, 33, 30);
  ATag.Album   := ReadFixedStr(buf, 63, 30);
  ATag.Year    := ReadFixedStr(buf, 93,  4);
  ATag.Comment := ReadFixedStr(buf, 97, 28);
  ATag.Track   := buf[126];
  ATag.Genre   := buf[127];
  Result := True;
end;

function ID3HasTag(AStream: TStream): Boolean;
var
  Tag: TID3v1Tag;
begin
  Result := ID3ReadTag(AStream, Tag);
end;

function ID3RemoveTag(AStream: TStream): Boolean;
begin
  Result := ID3HasTag(AStream);
  if Result then
    AStream.Size := AStream.Size - ID3_TAG_SIZE;
end;

end.
