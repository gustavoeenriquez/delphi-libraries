program TestMP3EncPhase14;

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

function MakeSilenceWAV(AChannels: Word; ASampleRate: Cardinal;
  APairs: Integer): TMemoryStream;
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
  WU32(Result, ASampleRate);
  WU32(Result, ASampleRate * AChannels * 2);
  WU16(Result, AChannels * 2); WU16(Result, 16);
  WS(Result, 'data'); WU32(Result, dBytes);
  if dBytes > 0 then Result.WriteBuffer(zeros[0], dBytes);
  Result.Position := 0;
end;

function MakeTag: TID3v2Tag;
begin
  Result := Default(TID3v2Tag);
  Result.Title  := 'Test Song';
  Result.Artist := 'Test Artist';
  Result.Album  := 'Test Album';
  Result.Year   := '2024';
  Result.Track  := '3';
  Result.Genre  := 'Electronic';
end;

// ---------------------------------------------------------------------------
// TS: Syncsafe integer
// ---------------------------------------------------------------------------

procedure TestSyncsafe;
var
  MS: TMemoryStream;
  b : array[0..3] of Byte;
  v : Cardinal;
begin
  WriteLn('TS: syncsafe integer');

  { TS01: encode 0 -> 00 00 00 00 }
  MS := TMemoryStream.Create;
  try
    ID3v2WriteSyncsafe(MS, 0);
    MS.Position := 0;
    MS.ReadBuffer(b, 4);
    Check('TS01 encode 0 -> all zeros',
      (b[0]=0) and (b[1]=0) and (b[2]=0) and (b[3]=0));
  finally MS.Free; end;

  { TS02: encode 127 ($7F) -> $00 $00 $00 $7F }
  MS := TMemoryStream.Create;
  try
    ID3v2WriteSyncsafe(MS, 127);
    MS.Position := 0;
    MS.ReadBuffer(b, 4);
    Check('TS02 encode 127 -> last byte $7F', (b[0]=0) and (b[3]=$7F));
  finally MS.Free; end;

  { TS03: encode 128 -> overflow to next byte: $00 $00 $01 $00 }
  MS := TMemoryStream.Create;
  try
    ID3v2WriteSyncsafe(MS, 128);
    MS.Position := 0;
    MS.ReadBuffer(b, 4);
    Check('TS03 encode 128 -> byte[2]=$01 byte[3]=$00',
      (b[0]=0) and (b[1]=0) and (b[2]=$01) and (b[3]=$00));
  finally MS.Free; end;

  { TS04: encode 256 -> $00 $00 $02 $00 }
  MS := TMemoryStream.Create;
  try
    ID3v2WriteSyncsafe(MS, 256);
    MS.Position := 0;
    MS.ReadBuffer(b, 4);
    Check('TS04 encode 256 -> byte[2]=$02', (b[2]=$02) and (b[3]=$00));
  finally MS.Free; end;

  { TS05: roundtrip identity for several values }
  for v in [0, 1, 127, 128, 255, 1000, 16383, 16384, 100000, $FFFFFFF] do begin
    MS := TMemoryStream.Create;
    try
      ID3v2WriteSyncsafe(MS, v);
      MS.Position := 0;
      Check(Format('TS05 roundtrip %d', [v]), ID3v2ReadSyncsafe(MS) = v);
    finally MS.Free; end;
  end;

  { TS06: all 7-bit bytes (no bit 7 set) }
  MS := TMemoryStream.Create;
  try
    ID3v2WriteSyncsafe(MS, $1234567);
    MS.Position := 0;
    MS.ReadBuffer(b, 4);
    Check('TS06 no byte has bit 7 set',
      ((b[0] and $80)=0) and ((b[1] and $80)=0) and
      ((b[2] and $80)=0) and ((b[3] and $80)=0));
  finally MS.Free; end;
end;

// ---------------------------------------------------------------------------
// TW: ID3v2WriteTag — binary layout
// ---------------------------------------------------------------------------

procedure TestWriteTag;
var
  MS  : TMemoryStream;
  Tag : TID3v2Tag;
  buf : TBytes;
  off : Integer;
  fid : AnsiString;
  fsz : Cardinal;
begin
  WriteLn('TW: ID3v2WriteTag binary layout');
  Tag := MakeTag;
  MS  := TMemoryStream.Create;
  try
    ID3v2WriteTag(MS, Tag);
    SetLength(buf, MS.Size);
    MS.Position := 0;
    MS.ReadBuffer(buf[0], MS.Size);

    { TW01-TW03: magic "ID3" }
    Check('TW01 magic[0] = I', buf[0] = Ord('I'));
    Check('TW02 magic[1] = D', buf[1] = Ord('D'));
    Check('TW03 magic[2] = 3', buf[2] = Ord('3'));

    { TW04-TW05: version 2.3.0 }
    Check('TW04 version major = 3',   buf[3] = 3);
    Check('TW05 version revision = 0', buf[4] = 0);

    { TW06: flags = 0 }
    Check('TW06 flags = 0', buf[5] = 0);

    { TW07: size bytes have no bit 7 set (syncsafe) }
    Check('TW07 syncsafe bytes',
      ((buf[6] and $80)=0) and ((buf[7] and $80)=0) and
      ((buf[8] and $80)=0) and ((buf[9] and $80)=0));

    { TW08: total size = 10 + body size matches MS.Size }
    MS.Position := 6;
    fsz := ID3v2ReadSyncsafe(MS);
    Check('TW08 header size consistent', MS.Size = Integer(10 + fsz));

    { TW09-TW14: each frame ID present (search by scanning) }
    off := 10;
    SetLength(fid, 4);
    while off + 10 <= Integer(MS.Size) do begin
      Move(buf[off], fid[1], 4);
      Move(buf[off+4], fsz, 0);
      { read 4-byte big-endian size }
      fsz := (Cardinal(buf[off+4]) shl 24) or (Cardinal(buf[off+5]) shl 16)
           or (Cardinal(buf[off+6]) shl 8)  or  Cardinal(buf[off+7]);
      if      fid = 'TIT2' then Check('TW09 TIT2 present', True)
      else if fid = 'TPE1' then Check('TW10 TPE1 present', True)
      else if fid = 'TALB' then Check('TW11 TALB present', True)
      else if fid = 'TYER' then Check('TW12 TYER present', True)
      else if fid = 'TRCK' then Check('TW13 TRCK present', True)
      else if fid = 'TCON' then Check('TW14 TCON present', True);
      Inc(off, 10 + Integer(fsz));
    end;

    { TW15: empty field -> no frame (tag with only title) }
    MS.Size := 0;
    Tag := Default(TID3v2Tag);
    Tag.Title := 'Only Title';
    ID3v2WriteTag(MS, Tag);
    SetLength(buf, MS.Size);
    MS.Position := 0;
    MS.ReadBuffer(buf[0], MS.Size);
    { only one frame expected: TIT2 }
    Check('TW15 only TIT2 for single-field tag',
      (MS.Size = 10 + (10 + 1 + Length('Only Title'))) );
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// TR: ID3v2ReadTag roundtrip
// ---------------------------------------------------------------------------

procedure TestReadTag;
var
  MS     : TMemoryStream;
  TagIn  : TID3v2Tag;
  TagOut : TID3v2Tag;
begin
  WriteLn('TR: ID3v2ReadTag roundtrip');
  TagIn := MakeTag;
  MS    := TMemoryStream.Create;
  try
    ID3v2WriteTag(MS, TagIn);

    Check('TR01 ReadTag -> True',    ID3v2ReadTag(MS, TagOut));
    Check('TR02 Title preserved',    TagOut.Title  = TagIn.Title);
    Check('TR03 Artist preserved',   TagOut.Artist = TagIn.Artist);
    Check('TR04 Album preserved',    TagOut.Album  = TagIn.Album);
    Check('TR05 Year preserved',     TagOut.Year   = TagIn.Year);
    Check('TR06 Track preserved',    TagOut.Track  = TagIn.Track);
    Check('TR07 Genre preserved',    TagOut.Genre  = TagIn.Genre);

    { TR08: stream position restored after read }
    MS.Position := 5;
    ID3v2ReadTag(MS, TagOut);
    Check('TR08 position restored = 5', MS.Position = 5);
  finally
    MS.Free;
  end;

  { TR09: partial tag (only artist + year) }
  MS := TMemoryStream.Create;
  try
    TagIn := Default(TID3v2Tag);
    TagIn.Artist := 'Solo Artist';
    TagIn.Year   := '1999';
    ID3v2WriteTag(MS, TagIn);
    Check('TR09 partial ReadTag -> True', ID3v2ReadTag(MS, TagOut));
    Check('TR10 Artist ok', TagOut.Artist = 'Solo Artist');
    Check('TR11 Year ok',   TagOut.Year   = '1999');
    Check('TR12 Title empty', TagOut.Title = '');
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// TH: HasTag and TagSize
// ---------------------------------------------------------------------------

procedure TestHasTagSize;
var
  MS  : TMemoryStream;
  Tag : TID3v2Tag;
  sz  : Integer;
begin
  WriteLn('TH: HasTag / TagSize');

  { TH01: valid tag -> True }
  MS := TMemoryStream.Create;
  try
    Tag := MakeTag;
    ID3v2WriteTag(MS, Tag);
    Check('TH01 HasTag -> True',    ID3v2HasTag(MS));
    Check('TH02 TagSize > 10',      ID3v2TagSize(MS) > 10);
    sz := ID3v2TagSize(MS);
    Check('TH03 TagSize = MS.Size', sz = MS.Size);
  finally MS.Free; end;

  { TH04: no tag (empty stream) -> False / 0 }
  MS := TMemoryStream.Create;
  try
    Check('TH04 empty -> False',  not ID3v2HasTag(MS));
    Check('TH05 empty size = 0',  ID3v2TagSize(MS) = 0);
  finally MS.Free; end;

  { TH06: stream starting with "ID4" -> False }
  MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(AnsiString('ID4'#3#0#0)[1], 6);
    Check('TH06 wrong magic -> False', not ID3v2HasTag(MS));
  finally MS.Free; end;

  { TH07: TagSize is 10 + body size (cross-check via syncsafe) }
  MS := TMemoryStream.Create;
  try
    Tag := Default(TID3v2Tag);
    Tag.Title := 'A';
    ID3v2WriteTag(MS, Tag);
    { frame = 4+4+2+1+1 = 12 bytes; body = 12; total = 10+12 = 22 }
    Check('TH07 TagSize for 1-char title = 22', ID3v2TagSize(MS) = 22);
  finally MS.Free; end;
end;

// ---------------------------------------------------------------------------
// TE: EncodeWAVStreamTaggedV2 integration
// ---------------------------------------------------------------------------

procedure TestEncodeWAVStreamTaggedV2;
var
  WavIn  : TMemoryStream;
  MP3Out : TMemoryStream;
  Tag    : TID3v2Tag;
  TagOut : TID3v2Tag;
  r      : Integer;
  tagSz  : Integer;
  b      : Byte;
begin
  WriteLn('TE: EncodeWAVStreamTaggedV2');
  Tag := MakeTag;

  { mono 1152 samples -> 1 audio frame + ID3v2 tag prepended }
  WavIn  := MakeSilenceWAV(1, 44100, 1152);
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStreamTaggedV2(WavIn, MP3Out, 9, 0, Tag);
    Check('TE01 audio frames = 2',         r = 2);
    Check('TE02 HasTag -> True',           ID3v2HasTag(MP3Out));
    tagSz := ID3v2TagSize(MP3Out);
    Check('TE03 tagSize > 0',              tagSz > 0);
    { MP3 sync should start at tagSz }
    MP3Out.Position := tagSz;
    MP3Out.ReadBuffer(b, 1);
    Check('TE04 MP3 sync $FF after tag',   b = $FF);
    Check('TE05 total size = tag+834',     MP3Out.Size = tagSz + 834);

    { roundtrip tag fields }
    Check('TE06 ReadTag -> True',          ID3v2ReadTag(MP3Out, TagOut));
    Check('TE07 Title preserved',          TagOut.Title  = Tag.Title);
    Check('TE08 Artist preserved',         TagOut.Artist = Tag.Artist);
    Check('TE09 Album preserved',          TagOut.Album  = Tag.Album);
    Check('TE10 Year preserved',           TagOut.Year   = Tag.Year);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { invalid WAV -> -1, no output }
  WavIn  := TMemoryStream.Create;
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStreamTaggedV2(WavIn, MP3Out, 9, 0, Tag);
    Check('TE11 invalid WAV -> -1',        r = -1);
    Check('TE12 no output on error',       MP3Out.Size = 0);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;
end;

var
  T0: TDateTime;
begin
  T0 := Now;
  WriteLn('=== TestMP3EncPhase14 ===');
  WriteLn;
  TestSyncsafe;
  WriteLn;
  TestWriteTag;
  WriteLn;
  TestReadTag;
  WriteLn;
  TestHasTagSize;
  WriteLn;
  TestEncodeWAVStreamTaggedV2;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%.0f ms)',
    [GPassed, GPassed + GFailed, (Now - T0) * 86400000]));
  if GFailed = 0 then WriteLn('ALL PASSED')
  else             WriteLn(Format('%d FAILED', [GFailed]));
  ExitCode := GFailed;
end.
