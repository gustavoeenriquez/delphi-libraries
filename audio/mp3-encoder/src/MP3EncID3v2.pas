unit MP3EncID3v2;

(*
  MP3EncID3v2.pas — ID3v2.3 tag writer and reader for MP3 files

  ID3v2.3 tag structure (prepended to the start of the MP3 file):

  Tag header (10 bytes):
    Offset 0   "ID3"         (3 bytes magic)
    Offset 3   Version 0x03  (major = 2.3, always)
    Offset 4   Revision 0x00
    Offset 5   Flags    0x00 (no unsynchronisation, no extended header)
    Offset 6   Size  4 bytes syncsafe (28-bit, each byte has bit 7 = 0)

  Each frame:
    Offset 0   Frame ID   4 ASCII bytes
    Offset 4   Frame size 4 bytes big-endian (NOT syncsafe in v2.3)
    Offset 8   Flags      2 bytes (0x00 0x00)
    Offset 10  Data       ...

  Text frames (TIT2 TPE1 TALB TYER TRCK TCON):
    Data: encoding byte (0x00=ISO-8859-1) + text bytes

  APIC frame (attached picture / cover art):
    Data: encoding(1) + MIME-type\0 + picture-type(1) + description\0 + image-data

  Text encoding: ISO-8859-1 only (encoding byte = 0x00).
  Non-ASCII characters in string fields are silently replaced with '?'.
  APIC picture type 0x03 = front cover.

  Syncsafe integer:
    byte[0] = (v >> 21) & 0x7F
    byte[1] = (v >> 14) & 0x7F
    byte[2] = (v >>  7) & 0x7F
    byte[3] =  v        & 0x7F

  Reference: https://id3.org/id3v2.3.0
  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
*)

interface

uses
  SysUtils,
  Classes;

const
  ID3V2_PIC_FRONT_COVER = 3;   { APIC picture type: front cover }

type
  TID3v2Picture = record
    MimeType    : string;   { 'image/jpeg' or 'image/png' }
    PictureType : Byte;     { see ID3V2_PIC_* constants; 3 = front cover }
    Description : string;   { usually empty }
    Data        : TBytes;   { raw image bytes (JPEG, PNG, …) }
  end;

  TID3v2Tag = record
    Title      : string;   { TIT2 — song name }
    Artist     : string;   { TPE1 — lead artist }
    Album      : string;   { TALB — collection name }
    Year       : string;   { TYER — 4-digit year }
    Track      : string;   { TRCK — track number }
    Genre      : string;   { TCON — freeform genre text }
    HasPicture : Boolean;  { True when Picture.Data is set }
    Picture    : TID3v2Picture;
  end;

{ Write a 28-bit value to AStream as 4 syncsafe bytes. }
procedure ID3v2WriteSyncsafe(AStream: TStream; AValue: Cardinal);

{ Read 4 syncsafe bytes from AStream and return the 28-bit value. }
function  ID3v2ReadSyncsafe(AStream: TStream): Cardinal;

{ Write a complete ID3v2.3 tag to AStream at the current position.
  Empty string fields are omitted.  Picture is written when HasPicture is True
  and Picture.Data is non-empty. }
procedure ID3v2WriteTag(AStream: TStream; const ATag: TID3v2Tag);

{ Read an ID3v2.3 tag from position 0 of AStream.
  Stream position is saved and restored after the call.
  Returns True when "ID3" magic and version 2.3.x are found.
  Text frames are decoded as ISO-8859-1; APIC is read into Tag.Picture. }
function ID3v2ReadTag(AStream: TStream; out ATag: TID3v2Tag): Boolean;

{ Return True if AStream starts with a valid ID3v2.3 tag. }
function ID3v2HasTag(AStream: TStream): Boolean;

{ Return the total byte size of the ID3v2 tag (10-byte header + body).
  Returns 0 if no tag is present. }
function ID3v2TagSize(AStream: TStream): Integer;

implementation

// ---------------------------------------------------------------------------
// Syncsafe helpers
// ---------------------------------------------------------------------------

procedure ID3v2WriteSyncsafe(AStream: TStream; AValue: Cardinal);
var
  b: array[0..3] of Byte;
begin
  b[0] := (AValue shr 21) and $7F;
  b[1] := (AValue shr 14) and $7F;
  b[2] := (AValue shr  7) and $7F;
  b[3] :=  AValue         and $7F;
  AStream.WriteBuffer(b, 4);
end;

function ID3v2ReadSyncsafe(AStream: TStream): Cardinal;
var
  b: array[0..3] of Byte;
begin
  AStream.ReadBuffer(b, 4);
  Result := (Cardinal(b[0]) shl 21)
          or (Cardinal(b[1]) shl 14)
          or (Cardinal(b[2]) shl 7)
          or  Cardinal(b[3]);
end;

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

procedure WriteU32BE(AStream: TStream; AValue: Cardinal);
var
  b: array[0..3] of Byte;
begin
  b[0] := (AValue shr 24) and $FF;
  b[1] := (AValue shr 16) and $FF;
  b[2] := (AValue shr  8) and $FF;
  b[3] :=  AValue         and $FF;
  AStream.WriteBuffer(b, 4);
end;

function ReadU32BE(AStream: TStream): Cardinal;
var
  b: array[0..3] of Byte;
begin
  AStream.ReadBuffer(b, 4);
  Result := (Cardinal(b[0]) shl 24) or (Cardinal(b[1]) shl 16)
          or (Cardinal(b[2]) shl 8)  or  Cardinal(b[3]);
end;

function ToLatin1(const S: string): AnsiString;
var
  i: Integer;
begin
  SetLength(Result, Length(S));
  for i := 1 to Length(S) do
    if Ord(S[i]) <= 255 then
      Result[i] := AnsiChar(Ord(S[i]))
    else
      Result[i] := AnsiChar($3F);  { '?' for non-Latin1 }
end;

procedure WriteTextFrame(ABody: TStream; const AFrameID: AnsiString;
  const AText: string);
var
  latin1 : AnsiString;
  encByte: Byte;
begin
  if AText = '' then Exit;
  latin1  := ToLatin1(AText);
  encByte := 0;
  ABody.WriteBuffer(Pointer(AFrameID)^, 4);
  WriteU32BE(ABody, 1 + Cardinal(Length(latin1)));
  ABody.WriteBuffer(#0#0, 2);
  ABody.WriteBuffer(encByte, 1);
  if Length(latin1) > 0 then
    ABody.WriteBuffer(Pointer(latin1)^, Length(latin1));
end;

procedure WriteAPICFrame(ABody: TStream; const APic: TID3v2Picture);
var
  mime  : AnsiString;
  desc  : AnsiString;
  enc   : Byte;
  ptype : Byte;
  fSize : Cardinal;
  zero  : Byte;
begin
  if Length(APic.Data) = 0 then Exit;
  mime  := ToLatin1(APic.MimeType);
  desc  := ToLatin1(APic.Description);
  enc   := 0;   { ISO-8859-1 }
  ptype := APic.PictureType;
  zero  := 0;

  { payload = enc(1) + mime + null(1) + pictype(1) + desc + null(1) + data }
  fSize := 1 + Cardinal(Length(mime)) + 1
         + 1
         + Cardinal(Length(desc)) + 1
         + Cardinal(Length(APic.Data));

  ABody.WriteBuffer(AnsiString('APIC')[1], 4);  { frame ID }
  WriteU32BE(ABody, fSize);
  ABody.WriteBuffer(#0#0, 2);                   { frame flags }
  ABody.WriteBuffer(enc, 1);
  if Length(mime) > 0 then
    ABody.WriteBuffer(Pointer(mime)^, Length(mime));
  ABody.WriteBuffer(zero, 1);                   { null-terminate MIME }
  ABody.WriteBuffer(ptype, 1);
  if Length(desc) > 0 then
    ABody.WriteBuffer(Pointer(desc)^, Length(desc));
  ABody.WriteBuffer(zero, 1);                   { null-terminate description }
  ABody.WriteBuffer(APic.Data[0], Length(APic.Data));
end;

// ---------------------------------------------------------------------------

procedure ID3v2WriteTag(AStream: TStream; const ATag: TID3v2Tag);
var
  Body : TMemoryStream;
  hdr  : array[0..5] of Byte;
begin
  Body := TMemoryStream.Create;
  try
    WriteTextFrame(Body, 'TIT2', ATag.Title);
    WriteTextFrame(Body, 'TPE1', ATag.Artist);
    WriteTextFrame(Body, 'TALB', ATag.Album);
    WriteTextFrame(Body, 'TYER', ATag.Year);
    WriteTextFrame(Body, 'TRCK', ATag.Track);
    WriteTextFrame(Body, 'TCON', ATag.Genre);
    if ATag.HasPicture and (Length(ATag.Picture.Data) > 0) then
      WriteAPICFrame(Body, ATag.Picture);

    hdr[0] := Ord('I'); hdr[1] := Ord('D'); hdr[2] := Ord('3');
    hdr[3] := 3;
    hdr[4] := 0;
    hdr[5] := 0;
    AStream.WriteBuffer(hdr, 6);
    ID3v2WriteSyncsafe(AStream, Cardinal(Body.Size));

    if Body.Size > 0 then begin
      Body.Position := 0;
      AStream.CopyFrom(Body, Body.Size);
    end;
  finally
    Body.Free;
  end;
end;

// ---------------------------------------------------------------------------

function ID3v2ReadTag(AStream: TStream; out ATag: TID3v2Tag): Boolean;
var
  savedPos  : Int64;
  magic     : array[0..2] of Byte;
  verMajor  : Byte;
  verRev    : Byte;
  flags     : Byte;
  tagSize   : Cardinal;
  bytesLeft : Integer;
  frameID   : AnsiString;
  fSize     : Cardinal;
  fflags    : array[0..1] of Byte;
  frameData : TBytes;
  enc       : Byte;
  txt       : AnsiString;
  i, p      : Integer;
  mEnd      : Integer;
  imgLen    : Integer;
  mimeStr   : AnsiString;
begin
  Result := False;
  ATag   := Default(TID3v2Tag);
  savedPos := AStream.Position;
  try
    AStream.Position := 0;
    if AStream.Size < 10 then Exit;

    AStream.ReadBuffer(magic, 3);
    if (magic[0] <> Ord('I')) or (magic[1] <> Ord('D')) or (magic[2] <> Ord('3')) then
      Exit;

    AStream.ReadBuffer(verMajor, 1);
    AStream.ReadBuffer(verRev,   1);
    AStream.ReadBuffer(flags,    1);
    if verMajor <> 3 then Exit;

    tagSize   := ID3v2ReadSyncsafe(AStream);
    bytesLeft := Integer(tagSize);

    while bytesLeft >= 10 do begin
      SetLength(frameID, 4);
      AStream.ReadBuffer(frameID[1], 4);
      if frameID[1] = #0 then Break;

      fSize := ReadU32BE(AStream);
      AStream.ReadBuffer(fflags, 2);
      Dec(bytesLeft, 10);

      if (fSize = 0) or (Integer(fSize) > bytesLeft) then Break;

      SetLength(frameData, fSize);
      AStream.ReadBuffer(frameData[0], fSize);
      Dec(bytesLeft, Integer(fSize));

      { Text frames }
      if (frameID[1] = 'T') and (fSize > 1) then begin
        enc := frameData[0];
        if enc = 0 then begin
          SetLength(txt, Integer(fSize) - 1);
          if Integer(fSize) > 1 then
            Move(frameData[1], txt[1], Integer(fSize) - 1);
          i := Length(txt);
          while (i > 0) and (txt[i] = #0) do Dec(i);
          SetLength(txt, i);
          if      frameID = 'TIT2' then ATag.Title  := String(txt)
          else if frameID = 'TPE1' then ATag.Artist := String(txt)
          else if frameID = 'TALB' then ATag.Album  := String(txt)
          else if frameID = 'TYER' then ATag.Year   := String(txt)
          else if frameID = 'TRCK' then ATag.Track  := String(txt)
          else if frameID = 'TCON' then ATag.Genre  := String(txt);
        end;
      end
      { APIC frame }
      else if (frameID = 'APIC') and (Integer(fSize) >= 4) then begin
        enc := frameData[0];
        if enc = 0 then begin
          p := 1;
          { find end of MIME type (null-terminated) }
          mEnd := p;
          while (mEnd < Integer(fSize)) and (frameData[mEnd] <> 0) do
            Inc(mEnd);
          SetLength(mimeStr, mEnd - p);
          if mEnd > p then
            Move(frameData[p], mimeStr[1], mEnd - p);
          p := mEnd + 1;   { skip null terminator }
          if p >= Integer(fSize) then Continue;

          ATag.Picture.PictureType := frameData[p];
          Inc(p);
          if p >= Integer(fSize) then Continue;

          { skip description (null-terminated) }
          mEnd := p;
          while (mEnd < Integer(fSize)) and (frameData[mEnd] <> 0) do
            Inc(mEnd);
          p := mEnd + 1;   { skip null terminator }

          imgLen := Integer(fSize) - p;
          if imgLen > 0 then begin
            ATag.HasPicture          := True;
            ATag.Picture.MimeType    := String(mimeStr);
            ATag.Picture.Description := '';
            SetLength(ATag.Picture.Data, imgLen);
            Move(frameData[p], ATag.Picture.Data[0], imgLen);
          end;
        end;
      end;
    end;

    Result := True;
  finally
    AStream.Position := savedPos;
  end;
end;

// ---------------------------------------------------------------------------

function ID3v2HasTag(AStream: TStream): Boolean;
var
  Tag: TID3v2Tag;
begin
  Result := ID3v2ReadTag(AStream, Tag);
end;

function ID3v2TagSize(AStream: TStream): Integer;
var
  savedPos : Int64;
  magic    : array[0..2] of Byte;
  verMajor : Byte;
  verRev   : Byte;
  flags    : Byte;
  bodySize : Cardinal;
begin
  Result := 0;
  savedPos := AStream.Position;
  try
    AStream.Position := 0;
    if AStream.Size < 10 then Exit;
    AStream.ReadBuffer(magic, 3);
    if (magic[0] <> Ord('I')) or (magic[1] <> Ord('D')) or (magic[2] <> Ord('3')) then
      Exit;
    AStream.ReadBuffer(verMajor, 1);
    AStream.ReadBuffer(verRev,   1);
    AStream.ReadBuffer(flags,    1);
    if verMajor <> 3 then Exit;
    bodySize := ID3v2ReadSyncsafe(AStream);
    Result   := 10 + Integer(bodySize);
  finally
    AStream.Position := savedPos;
  end;
end;

end.
