program TestMP3EncPhase17;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Classes,
  MP3EncID3v2,
  MP3EncWAV;

var
  GPassed, GFailed: Integer;

procedure Check(const AName: string; ACondition: Boolean);
begin
  if ACondition then begin
    Inc(GPassed);
    WriteLn('  PASS  ', AName);
  end else begin
    Inc(GFailed);
    WriteLn('** FAIL  ', AName);
  end;
end;

// ---------------------------------------------------------------------------
// WAV builder helpers
// ---------------------------------------------------------------------------

procedure WS(MS: TMemoryStream; const S: AnsiString);
begin MS.WriteBuffer(Pointer(S)^, Length(S)); end;
procedure WU16(MS: TMemoryStream; V: Word);     begin MS.WriteBuffer(V, 2); end;
procedure WU32(MS: TMemoryStream; V: Cardinal); begin MS.WriteBuffer(V, 4); end;

function MakeSilenceWAV16(AChannels: Word; APairs: Integer): TMemoryStream;
var
  zeros : TBytes;
  dBytes: Cardinal;
begin
  dBytes := APairs * AChannels * 2;
  SetLength(zeros, dBytes);
  FillChar(zeros[0], dBytes, 0);
  Result := TMemoryStream.Create;
  WS(Result, 'RIFF'); WU32(Result, 36 + dBytes);
  WS(Result, 'WAVE');
  WS(Result, 'fmt '); WU32(Result, 16);
  WU16(Result, 1); WU16(Result, AChannels);
  WU32(Result, 44100); WU32(Result, 44100 * AChannels * 2);
  WU16(Result, AChannels * 2); WU16(Result, 16);
  WS(Result, 'data'); WU32(Result, dBytes);
  if dBytes > 0 then Result.WriteBuffer(zeros[0], dBytes);
  Result.Position := 0;
end;

{ Minimal fake JPEG: SOI + a few bytes + EOI. }
function MakeFakeJPEG(ASize: Integer): TBytes;
var i: Integer;
begin
  SetLength(Result, ASize);
  Result[0] := $FF; Result[1] := $D8;  { SOI }
  for i := 2 to ASize - 3 do Result[i] := Byte(i);
  Result[ASize-2] := $FF; Result[ASize-1] := $D9;  { EOI }
end;

function MakeFakePNG(ASize: Integer): TBytes;
var i: Integer;
begin
  SetLength(Result, ASize);
  { PNG signature }
  Result[0]:=$89; Result[1]:=$50; Result[2]:=$4E; Result[3]:=$47;
  Result[4]:=$0D; Result[5]:=$0A; Result[6]:=$1A; Result[7]:=$0A;
  for i := 8 to ASize - 1 do Result[i] := Byte(i);
end;

function MakeTag(const ATitle, AAlbum: string;
  const APicData: TBytes; APicMime: string;
  AHasPic: Boolean): TID3v2Tag;
begin
  Result := Default(TID3v2Tag);
  Result.Title  := ATitle;
  Result.Artist := 'Test Artist';
  Result.Album  := AAlbum;
  Result.Year   := '2025';
  if AHasPic then begin
    Result.HasPicture          := True;
    Result.Picture.MimeType    := APicMime;
    Result.Picture.PictureType := ID3V2_PIC_FRONT_COVER;
    Result.Picture.Description := '';
    Result.Picture.Data        := APicData;
  end;
end;

// Scan buf for 4-byte ASCII tag starting at offset 10 (skip ID3 header)
function FindFrame(const ABuf: TBytes; const AID: AnsiString;
  out AFramePayloadOfs: Integer; out AFramePayloadSize: Cardinal): Boolean;
var
  off: Integer;
  fid: AnsiString;
  sz : Cardinal;
begin
  Result := False;
  off    := 10;
  SetLength(fid, 4);
  while off + 10 <= Length(ABuf) do begin
    Move(ABuf[off], fid[1], 4);
    if fid[1] = #0 then Break;
    sz := (Cardinal(ABuf[off+4]) shl 24) or (Cardinal(ABuf[off+5]) shl 16)
        or (Cardinal(ABuf[off+6]) shl 8)  or Cardinal(ABuf[off+7]);
    if fid = AID then begin
      AFramePayloadOfs  := off + 10;
      AFramePayloadSize := sz;
      Result := True;
      Exit;
    end;
    Inc(off, 10 + Integer(sz));
  end;
end;

// ---------------------------------------------------------------------------
// TP: APIC write — binary layout
// ---------------------------------------------------------------------------

procedure TestAPICWrite;
var
  MS    : TMemoryStream;
  Tag   : TID3v2Tag;
  buf   : TBytes;
  pic   : TBytes;
  payOfs: Integer;
  paySz : Cardinal;
  p     : Integer;
  noTagSz, withTagSz: Integer;
begin
  WriteLn('TP: APIC write — binary layout');

  pic := MakeFakeJPEG(32);  { 32-byte fake JPEG }

  { Write tag without picture, then with picture; size must grow }
  MS := TMemoryStream.Create;
  try
    Tag := MakeTag('Song', 'Album', nil, '', False);
    ID3v2WriteTag(MS, Tag);
    noTagSz := MS.Size;
  finally MS.Free; end;

  MS := TMemoryStream.Create;
  try
    Tag := MakeTag('Song', 'Album', pic, 'image/jpeg', True);
    ID3v2WriteTag(MS, Tag);
    withTagSz := MS.Size;
    SetLength(buf, MS.Size);
    MS.Position := 0;
    MS.ReadBuffer(buf[0], MS.Size);
  finally MS.Free; end;

  { TP01: tag with picture is larger }
  Check('TP01 tag with picture > tag without', withTagSz > noTagSz);

  { TP02: APIC frame is present }
  Check('TP02 APIC frame present',
    FindFrame(buf, 'APIC', payOfs, paySz));

  { TP03: APIC payload size = 1(enc)+10(mime)+1(null)+1(pictype)+1(desc-null)+32(data) = 46 }
  { 'image/jpeg' = 10 chars; desc = '' = 0 chars; data = 32 bytes }
  Check('TP03 APIC payload size = 46',  paySz = 46);

  { TP04: encoding byte = 0 (ISO-8859-1) }
  Check('TP04 encoding byte = 0',  (payOfs < Length(buf) - 1) and (buf[payOfs] = 0));

  { TP05: MIME type starts at payload+1 = 'i','m','a','g','e','/','j','p','e','g' }
  p := payOfs + 1;
  Check('TP05 MIME starts with "image"',
    (buf[p]=$69) and (buf[p+1]=$6D) and (buf[p+2]=$61) and (buf[p+3]=$67) and
    (buf[p+4]=$65));  { 'i','m','a','g','e' }

  { TP06: MIME null terminator at payload+1+10 = payload+11 }
  Check('TP06 MIME null terminator',  buf[payOfs + 11] = 0);

  { TP07: picture type byte = 3 (front cover) at payload+12 }
  Check('TP07 picture type = 3',  buf[payOfs + 12] = 3);

  { TP08: description null at payload+13 }
  Check('TP08 desc null byte',  buf[payOfs + 13] = 0);

  { TP09: image data starts at payload+14; first bytes = $FF $D8 (JPEG SOI) }
  Check('TP09 image SOI $FF $D8',
    (buf[payOfs + 14] = $FF) and (buf[payOfs + 15] = $D8));

  { TP10: tag without HasPicture has no APIC }
  MS := TMemoryStream.Create;
  try
    Tag := MakeTag('Song', 'Album', nil, '', False);
    ID3v2WriteTag(MS, Tag);
    SetLength(buf, MS.Size);
    MS.Position := 0;
    MS.ReadBuffer(buf[0], MS.Size);
    Check('TP10 no APIC when HasPicture=False',
      not FindFrame(buf, 'APIC', payOfs, paySz));
  finally MS.Free; end;

  { TP11: HasPicture=True but empty Data -> no APIC }
  MS := TMemoryStream.Create;
  try
    Tag                 := Default(TID3v2Tag);
    Tag.Title           := 'Test';
    Tag.HasPicture      := True;
    Tag.Picture.MimeType:= 'image/jpeg';
    Tag.Picture.Data    := nil;  { empty }
    ID3v2WriteTag(MS, Tag);
    SetLength(buf, MS.Size);
    MS.Position := 0;
    MS.ReadBuffer(buf[0], MS.Size);
    Check('TP11 no APIC when Data is empty',
      not FindFrame(buf, 'APIC', payOfs, paySz));
  finally MS.Free; end;
end;

// ---------------------------------------------------------------------------
// TR: APIC roundtrip
// ---------------------------------------------------------------------------

procedure TestAPICRoundtrip;
var
  MS     : TMemoryStream;
  TagIn  : TID3v2Tag;
  TagOut : TID3v2Tag;
  pic    : TBytes;
  i      : Integer;
  allOK  : Boolean;
begin
  WriteLn('TR: APIC roundtrip');

  pic := MakeFakeJPEG(64);

  { TR01-TR06: full roundtrip with picture }
  MS := TMemoryStream.Create;
  try
    TagIn := MakeTag('Roundtrip Song', 'Best Album', pic, 'image/jpeg', True);
    ID3v2WriteTag(MS, TagIn);
    Check('TR01 ReadTag -> True',          ID3v2ReadTag(MS, TagOut));
    Check('TR02 HasPicture -> True',       TagOut.HasPicture);
    Check('TR03 MimeType preserved',       TagOut.Picture.MimeType = 'image/jpeg');
    Check('TR04 PictureType = front cover',TagOut.Picture.PictureType = ID3V2_PIC_FRONT_COVER);
    Check('TR05 Data length preserved',    Length(TagOut.Picture.Data) = Length(pic));
    allOK := Length(TagOut.Picture.Data) = Length(pic);
    if allOK then
      for i := 0 to Length(pic) - 1 do
        if pic[i] <> TagOut.Picture.Data[i] then begin allOK := False; Break; end;
    Check('TR06 Data bytes identical',     allOK);
    { Text fields must survive alongside the picture }
    Check('TR07 Title preserved',          TagOut.Title = 'Roundtrip Song');
    Check('TR08 Album preserved',          TagOut.Album = 'Best Album');
    Check('TR09 Artist preserved',         TagOut.Artist = 'Test Artist');
    Check('TR10 Year preserved',           TagOut.Year = '2025');
  finally MS.Free; end;

  { TR11: tag without APIC -> HasPicture = False }
  MS := TMemoryStream.Create;
  try
    TagIn := MakeTag('No Picture', 'Album', nil, '', False);
    ID3v2WriteTag(MS, TagIn);
    ID3v2ReadTag(MS, TagOut);
    Check('TR11 no APIC -> HasPicture=False', not TagOut.HasPicture);
  finally MS.Free; end;

  { TR12: PNG picture }
  MS := TMemoryStream.Create;
  try
    pic := MakeFakePNG(48);
    TagIn := MakeTag('PNG Song', 'PNG Album', pic, 'image/png', True);
    ID3v2WriteTag(MS, TagIn);
    ID3v2ReadTag(MS, TagOut);
    Check('TR12 PNG MimeType preserved',   TagOut.Picture.MimeType = 'image/png');
    Check('TR13 PNG data length ok',       Length(TagOut.Picture.Data) = 48);
  finally MS.Free; end;
end;

// ---------------------------------------------------------------------------
// TI: Integration with EncodeWAVStreamTaggedV2
// ---------------------------------------------------------------------------

procedure TestIntegration;
var
  WavIn  : TMemoryStream;
  MP3Out : TMemoryStream;
  TagIn  : TID3v2Tag;
  TagOut : TID3v2Tag;
  pic    : TBytes;
  r      : Integer;
  allOK  : Boolean;
  i      : Integer;
begin
  WriteLn('TI: integration with EncodeWAVStreamTaggedV2');

  pic   := MakeFakeJPEG(100);
  TagIn := MakeTag('WAV+Art', 'Cover Album', pic, 'image/jpeg', True);

  WavIn  := MakeSilenceWAV16(1, 1152);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStreamTaggedV2(WavIn, MP3Out, 9, 0, TagIn);
    Check('TI01 encode returns 2',         r = 2);
    Check('TI02 HasTag -> True',           ID3v2HasTag(MP3Out));
    Check('TI03 ReadTag -> True',          ID3v2ReadTag(MP3Out, TagOut));
    Check('TI04 HasPicture after encode',  TagOut.HasPicture);
    Check('TI05 MimeType ok',              TagOut.Picture.MimeType = 'image/jpeg');
    Check('TI06 Data length = 100',        Length(TagOut.Picture.Data) = 100);
    allOK := Length(TagOut.Picture.Data) = 100;
    if allOK then
      for i := 0 to 99 do
        if pic[i] <> TagOut.Picture.Data[i] then begin allOK := False; Break; end;
    Check('TI07 image data bit-exact',     allOK);
    Check('TI08 Title preserved',          TagOut.Title = 'WAV+Art');
  finally
    WavIn.Free;
    MP3Out.Free;
  end;
end;

// ---------------------------------------------------------------------------

var
  T0: TDateTime;
begin
  T0 := Now;
  WriteLn('=== TestMP3EncPhase17 ===');
  WriteLn;
  TestAPICWrite;
  WriteLn;
  TestAPICRoundtrip;
  WriteLn;
  TestIntegration;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%.0f ms)',
    [GPassed, GPassed + GFailed, (Now - T0) * 86400000]));
  if GFailed = 0 then WriteLn('ALL PASSED')
  else             WriteLn(Format('%d FAILED', [GFailed]));
  ExitCode := GFailed;
end.
