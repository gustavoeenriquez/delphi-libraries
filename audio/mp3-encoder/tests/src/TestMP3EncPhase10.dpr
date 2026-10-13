program TestMP3EncPhase10;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Classes,
  MP3EncID3,
  MP3EncEncoder,
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
begin
  MS.WriteBuffer(Pointer(S)^, Length(S));
end;

procedure WU16(MS: TMemoryStream; V: Word);
begin
  MS.WriteBuffer(V, 2);
end;

procedure WU32(MS: TMemoryStream; V: Cardinal);
begin
  MS.WriteBuffer(V, 4);
end;

function MakeSilenceWAV: TMemoryStream;
var
  zeros : array[0..1151] of SmallInt;
  dBytes: Cardinal;
begin
  FillChar(zeros, SizeOf(zeros), 0);
  dBytes := 1152 * 2;
  Result := TMemoryStream.Create;
  WS(Result, 'RIFF');
  WU32(Result, 36 + dBytes);
  WS(Result, 'WAVE');
  WS(Result, 'fmt ');
  WU32(Result, 16);
  WU16(Result, 1);           { PCM }
  WU16(Result, 1);           { mono }
  WU32(Result, 44100);
  WU32(Result, 88200);       { byte rate }
  WU16(Result, 2);           { block align }
  WU16(Result, 16);          { bits/sample }
  WS(Result, 'data');
  WU32(Result, dBytes);
  Result.WriteBuffer(zeros, dBytes);
  Result.Position := 0;
end;

function MakeTag: TID3v1Tag;
begin
  Result         := Default(TID3v1Tag);
  Result.Title   := 'Test Title';
  Result.Artist  := 'Test Artist';
  Result.Album   := 'Test Album';
  Result.Year    := '2024';
  Result.Comment := 'Test comment';
  Result.Track   := 7;
  Result.Genre   := 12;
end;

// ---------------------------------------------------------------------------
// TW: ID3WriteTag — binary layout
// ---------------------------------------------------------------------------

procedure TestWriteTag;
var
  MS  : TMemoryStream;
  Tag : TID3v1Tag;
  buf : array[0..127] of Byte;
begin
  WriteLn('TW: ID3WriteTag');
  Tag := MakeTag;
  MS  := TMemoryStream.Create;
  try
    ID3WriteTag(MS, Tag);
    Check('TW01 size = 128',          MS.Size = 128);

    MS.Position := 0;
    MS.ReadBuffer(buf, 128);

    Check('TW02 magic[0] = T',        buf[0] = Ord('T'));
    Check('TW03 magic[1] = A',        buf[1] = Ord('A'));
    Check('TW04 magic[2] = G',        buf[2] = Ord('G'));

    { Title at offset 3: "Test Title" (10 chars), bytes 13..32 must be 0 }
    Check('TW05 title[0] = T',        buf[3]  = Ord('T'));
    Check('TW06 title[4] = ' + ' ',   buf[7]  = Ord(' '));
    Check('TW07 title pad = 0',       buf[13] = 0);

    { Artist at offset 33: "Test Artist" }
    Check('TW08 artist[0] = T',       buf[33] = Ord('T'));

    { Year at offset 93: "2024" }
    Check('TW09 year[0] = 2',         buf[93] = Ord('2'));
    Check('TW10 year[3] = 4',         buf[96] = Ord('4'));

    { ID3v1.1 marker at offset 125 = 0 }
    Check('TW11 marker = 0',          buf[125] = 0);

    { Track at 126, Genre at 127 }
    Check('TW12 track = 7',           buf[126] = 7);
    Check('TW13 genre = 12',          buf[127] = 12);
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// TR: ID3ReadTag — roundtrip
// ---------------------------------------------------------------------------

procedure TestReadTag;
var
  MS  : TMemoryStream;
  In_, Out_: TID3v1Tag;
begin
  WriteLn('TR: ID3ReadTag');
  In_ := MakeTag;
  MS  := TMemoryStream.Create;
  try
    ID3WriteTag(MS, In_);
    Check('TR01 ReadTag -> True',     ID3ReadTag(MS, Out_));
    Check('TR02 Title',               Out_.Title   = 'Test Title');
    Check('TR03 Artist',              Out_.Artist  = 'Test Artist');
    Check('TR04 Album',               Out_.Album   = 'Test Album');
    Check('TR05 Year',                Out_.Year    = '2024');
    Check('TR06 Comment',             Out_.Comment = 'Test comment');
    Check('TR07 Track',               Out_.Track   = 7);
    Check('TR08 Genre',               Out_.Genre   = 12);
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// TH: ID3HasTag / ID3RemoveTag
// ---------------------------------------------------------------------------

procedure TestHasRemoveTag;
var
  MS   : TMemoryStream;
  Tag  : TID3v1Tag;
  dummy: array[0..9] of Byte;
begin
  WriteLn('TH: ID3HasTag / ID3RemoveTag');
  Tag   := MakeTag;
  FillChar(dummy, SizeOf(dummy), $AA);  { 10 recognisable bytes }

  { HasTag on stream that has a tag }
  MS := TMemoryStream.Create;
  try
    ID3WriteTag(MS, Tag);
    Check('TH01 HasTag -> True',       ID3HasTag(MS));
  finally
    MS.Free;
  end;

  { HasTag on empty stream }
  MS := TMemoryStream.Create;
  try
    Check('TH02 HasTag empty -> False', not ID3HasTag(MS));
  finally
    MS.Free;
  end;

  { RemoveTag removes exactly 128 bytes }
  MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(dummy, SizeOf(dummy));  { 10 dummy bytes }
    ID3WriteTag(MS, Tag);
    Check('TH03 size before = 138',    MS.Size = 138);
    Check('TH04 RemoveTag -> True',    ID3RemoveTag(MS));
    Check('TH05 size after = 10',      MS.Size = 10);
    Check('TH06 HasTag after -> False', not ID3HasTag(MS));
  finally
    MS.Free;
  end;

  { RemoveTag when no tag present }
  MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(dummy, SizeOf(dummy));
    Check('TH07 no-tag -> False',      not ID3RemoveTag(MS));
    Check('TH08 size unchanged',       MS.Size = 10);
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// TT: Truncation — field too long is clamped at the field boundary
// ---------------------------------------------------------------------------

procedure TestTruncation;
var
  MS  : TMemoryStream;
  Tag : TID3v1Tag;
  Out_: TID3v1Tag;
  buf : array[0..127] of Byte;
begin
  WriteLn('TT: Truncation');
  Tag := Default(TID3v1Tag);
  { "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890" = 36 chars; only 30 stored.
    Char #30 = '4' (A=1..Z=26, then 1=27,2=28,3=29,4=30). }
  Tag.Title := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890';
  { "20249999" = 8 chars; only 4 stored -> "2024" }
  Tag.Year  := '20249999';

  MS := TMemoryStream.Create;
  try
    ID3WriteTag(MS, Tag);
    MS.Position := 0;
    MS.ReadBuffer(buf, 128);

    Check('TT01 title[0] = A',        buf[3]  = Ord('A'));
    Check('TT02 title[29] = 4',       buf[32] = Ord('4'));  { 30th char = '4' }
    Check('TT03 year[0] = 2',         buf[93] = Ord('2'));
    Check('TT04 year[3] = 4',         buf[96] = Ord('4'));

    ID3ReadTag(MS, Out_);
    Check('TT05 title len = 30',      Length(Out_.Title) = 30);
    Check('TT06 year = "2024"',       Out_.Year = '2024');
    Check('TT07 title[1] = A',        Out_.Title[1] = 'A');
    Check('TT08 title[30] = 4',       Out_.Title[30] = '4');
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// TE: Empty tag roundtrip
// ---------------------------------------------------------------------------

procedure TestEmptyTag;
var
  MS  : TMemoryStream;
  In_ : TID3v1Tag;
  Out_: TID3v1Tag;
begin
  WriteLn('TE: Empty tag roundtrip');
  In_ := Default(TID3v1Tag);
  MS  := TMemoryStream.Create;
  try
    ID3WriteTag(MS, In_);
    Check('TE01 size = 128',          MS.Size = 128);
    Check('TE02 ReadTag -> True',     ID3ReadTag(MS, Out_));
    Check('TE03 Title = ""',          Out_.Title  = '');
    Check('TE04 Artist = ""',         Out_.Artist = '');
    Check('TE05 Track = 0',           Out_.Track  = 0);
    Check('TE06 Genre = 0',           Out_.Genre  = 0);
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// TV: EncodeWAVStreamTagged
// ---------------------------------------------------------------------------

procedure TestEncodeTagged;
var
  WavIn, MP3Out: TMemoryStream;
  Tag, TagOut  : TID3v1Tag;
  r            : Integer;
begin
  WriteLn('TV: EncodeWAVStreamTagged');
  Tag   := MakeTag;
  WavIn := MakeSilenceWAV;
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStreamTagged(WavIn, MP3Out, 9, 0, Tag);
    Check('TV01 frames = 2',                r = 2);
    Check('TV02 size = 834 + 128 = 962',    MP3Out.Size = 962);
    Check('TV03 HasTag -> True',            ID3HasTag(MP3Out));
    Check('TV04 ReadTag -> True',           ID3ReadTag(MP3Out, TagOut));
    Check('TV05 tag Title correct',         TagOut.Title  = 'Test Title');
    Check('TV06 tag Artist correct',        TagOut.Artist = 'Test Artist');
    Check('TV07 tag Track correct',         TagOut.Track  = 7);

    { After removing tag, what's left is the raw MP3 frame }
    ID3RemoveTag(MP3Out);
    Check('TV08 size after remove = 834',   MP3Out.Size = 834);
  finally
    WavIn.Free;
    MP3Out.Free;
  end;

  { Invalid WAV -> -1, no tag written }
  WavIn  := TMemoryStream.Create;
  MP3Out := TMemoryStream.Create;
  try
    r := EncodeWAVStreamTagged(WavIn, MP3Out, 9, 0, Tag);
    Check('TV09 invalid WAV -> -1',         r = -1);
    Check('TV10 no tag on error',           not ID3HasTag(MP3Out));
  finally
    WavIn.Free;
    MP3Out.Free;
  end;
end;

var
  T0: TDateTime;
begin
  T0 := Now;
  WriteLn('=== TestMP3EncPhase10 ===');
  WriteLn;
  TestWriteTag;
  WriteLn;
  TestReadTag;
  WriteLn;
  TestHasRemoveTag;
  WriteLn;
  TestTruncation;
  WriteLn;
  TestEmptyTag;
  WriteLn;
  TestEncodeTagged;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%.0f ms)',
    [GPassed, GPassed + GFailed, (Now - T0) * 86400000]));
  if GFailed = 0 then WriteLn('ALL PASSED')
  else             WriteLn(Format('%d FAILED', [GFailed]));
  ExitCode := GFailed;
end.
