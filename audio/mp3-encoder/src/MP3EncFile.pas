unit MP3EncFile;

(*
  MP3EncFile.pas — File-level API for the MP3 encoder

  Filename-based wrappers around the stream-level functions in
  MP3EncWAV, MP3EncID3, MP3EncID3v2, and MP3EncProbe.

  Encode functions return the number of encoded audio frames (>=1) on
  success, or -1 on error (missing file, invalid WAV, write failure).
  Boolean functions return False on error.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
*)

interface

uses
  SysUtils,
  Classes,
  MP3EncWAV,
  MP3EncID3,
  MP3EncID3v2,
  MP3EncProbe;

{ Encode a WAV file to an MP3 file with the gapless Info/LAME header frame
  (decoders such as ffmpeg trim the encoder delay and the padding).
  ABrIdx 1..14, APadding 0..1.  Returns frame count or -1 on error. }
function EncodeWAVFile(const AWavPath, AMP3Path: string;
  ABrIdx, APadding: Byte): Integer;

{ Encode a WAV file to an MP3 file and append an ID3v1.1 tag. }
function EncodeWAVFileTagged(const AWavPath, AMP3Path: string;
  ABrIdx, APadding: Byte; const ATag: TID3v1Tag): Integer;

{ WAV file -> VBR MP3 with a Xing/LAME header.  AQuality 0 (best) .. 9.
  Returns the number of audio frames or -1 on error. }
function EncodeWAVFileVBR(const AWavPath, AMP3Path: string; AQuality: Integer): Integer;

{ Encode a WAV file to an MP3 file and prepend an ID3v2.3 tag. }
function EncodeWAVFileTaggedV2(const AWavPath, AMP3Path: string;
  ABrIdx, APadding: Byte; const ATag: TID3v2Tag): Integer;

{ Probe an MP3 file.  Returns False when the file cannot be opened or
  does not contain a valid MPEG1 Layer III frame. }
function MP3ProbeFile(const APath: string; out AResult: TMP3ProbeResult): Boolean;

{ Read an ID3v1 tag from an MP3 file.  Returns False when no tag is found. }
function MP3ReadTagV1(const APath: string; out ATag: TID3v1Tag): Boolean;

{ Read an ID3v2.3 tag from an MP3 file.  Returns False when no tag is found. }
function MP3ReadTagV2(const APath: string; out ATag: TID3v2Tag): Boolean;

{ Write (or replace) an ID3v1.1 tag in an existing MP3 file.
  Removes any existing ID3v1 tag first, then appends the new one.
  Returns False on file error. }
function MP3WriteTagV1(const APath: string; const ATag: TID3v1Tag): Boolean;

{ Write (or replace) an ID3v2.3 tag in an existing MP3 file.
  Strips the existing ID3v2 tag (if any) and prepends the new one,
  preserving audio data and any trailing ID3v1 tag.
  Returns False on file error. }
function MP3WriteTagV2(const APath: string; const ATag: TID3v2Tag): Boolean;

implementation

// ---------------------------------------------------------------------------

function EncodeWAVFile(const AWavPath, AMP3Path: string;
  ABrIdx, APadding: Byte): Integer;
var
  WavIn  : TMemoryStream;
  MP3Out : TMemoryStream;
begin
  Result := -1;
  WavIn  := TMemoryStream.Create;
  MP3Out := TMemoryStream.Create;
  try
    try
      WavIn.LoadFromFile(AWavPath);
    except
      Exit;
    end;
    Result := EncodeWAVStreamLame(WavIn, MP3Out, ABrIdx, APadding);
    if Result > 0 then
      try
        MP3Out.SaveToFile(AMP3Path);
      except
        Result := -1;
      end;
  finally
    WavIn.Free;
    MP3Out.Free;
  end;
end;

// ---------------------------------------------------------------------------

function EncodeWAVFileVBR(const AWavPath, AMP3Path: string; AQuality: Integer): Integer;
var
  WavIn  : TMemoryStream;
  MP3Out : TMemoryStream;
begin
  Result := -1;
  WavIn  := TMemoryStream.Create;
  MP3Out := TMemoryStream.Create;
  try
    try
      WavIn.LoadFromFile(AWavPath);
    except
      Exit;
    end;
    Result := EncodeWAVStreamVBR(WavIn, MP3Out, AQuality);
    if Result > 0 then
      try
        MP3Out.SaveToFile(AMP3Path);
      except
        Result := -1;
      end;
  finally
    WavIn.Free;
    MP3Out.Free;
  end;
end;

// ---------------------------------------------------------------------------

function EncodeWAVFileTagged(const AWavPath, AMP3Path: string;
  ABrIdx, APadding: Byte; const ATag: TID3v1Tag): Integer;
var
  WavIn  : TMemoryStream;
  MP3Out : TMemoryStream;
begin
  Result := -1;
  WavIn  := TMemoryStream.Create;
  MP3Out := TMemoryStream.Create;
  try
    try
      WavIn.LoadFromFile(AWavPath);
    except
      Exit;
    end;
    Result := EncodeWAVStreamTagged(WavIn, MP3Out, ABrIdx, APadding, ATag);
    if Result > 0 then
      try
        MP3Out.SaveToFile(AMP3Path);
      except
        Result := -1;
      end;
  finally
    WavIn.Free;
    MP3Out.Free;
  end;
end;

// ---------------------------------------------------------------------------

function EncodeWAVFileTaggedV2(const AWavPath, AMP3Path: string;
  ABrIdx, APadding: Byte; const ATag: TID3v2Tag): Integer;
var
  WavIn  : TMemoryStream;
  MP3Out : TMemoryStream;
begin
  Result := -1;
  WavIn  := TMemoryStream.Create;
  MP3Out := TMemoryStream.Create;
  try
    try
      WavIn.LoadFromFile(AWavPath);
    except
      Exit;
    end;
    Result := EncodeWAVStreamTaggedV2(WavIn, MP3Out, ABrIdx, APadding, ATag);
    if Result > 0 then
      try
        MP3Out.SaveToFile(AMP3Path);
      except
        Result := -1;
      end;
  finally
    WavIn.Free;
    MP3Out.Free;
  end;
end;

// ---------------------------------------------------------------------------

function MP3ProbeFile(const APath: string; out AResult: TMP3ProbeResult): Boolean;
var
  MS: TMemoryStream;
begin
  Result  := False;
  AResult := Default(TMP3ProbeResult);
  MS      := TMemoryStream.Create;
  try
    try
      MS.LoadFromFile(APath);
    except
      Exit;
    end;
    Result := MP3ProbeStream(MS, AResult);
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------

function MP3ReadTagV1(const APath: string; out ATag: TID3v1Tag): Boolean;
var
  MS: TMemoryStream;
begin
  Result := False;
  ATag   := Default(TID3v1Tag);
  MS     := TMemoryStream.Create;
  try
    try
      MS.LoadFromFile(APath);
    except
      Exit;
    end;
    Result := ID3ReadTag(MS, ATag);
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------

function MP3ReadTagV2(const APath: string; out ATag: TID3v2Tag): Boolean;
var
  MS: TMemoryStream;
begin
  Result := False;
  ATag   := Default(TID3v2Tag);
  MS     := TMemoryStream.Create;
  try
    try
      MS.LoadFromFile(APath);
    except
      Exit;
    end;
    Result := ID3v2ReadTag(MS, ATag);
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------

function MP3WriteTagV1(const APath: string; const ATag: TID3v1Tag): Boolean;
var
  MS: TMemoryStream;
begin
  Result := False;
  MS     := TMemoryStream.Create;
  try
    try
      MS.LoadFromFile(APath);
    except
      Exit;
    end;
    ID3RemoveTag(MS);
    MS.Position := MS.Size;
    ID3WriteTag(MS, ATag);
    try
      MS.SaveToFile(APath);
      Result := True;
    except
    end;
  finally
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------

function MP3WriteTagV2(const APath: string; const ATag: TID3v2Tag): Boolean;
var
  Src    : TMemoryStream;
  Tmp    : TMemoryStream;
  aStart : Integer;
begin
  Result := False;
  Src    := TMemoryStream.Create;
  Tmp    := TMemoryStream.Create;
  try
    try
      Src.LoadFromFile(APath);
    except
      Exit;
    end;
    { skip existing ID3v2 if present }
    if ID3v2HasTag(Src) then
      aStart := ID3v2TagSize(Src)
    else
      aStart := 0;
    { write new tag, then copy audio + any trailing ID3v1 }
    ID3v2WriteTag(Tmp, ATag);
    Src.Position := aStart;
    if Src.Size - aStart > 0 then
      Tmp.CopyFrom(Src, Src.Size - aStart);
    try
      Tmp.SaveToFile(APath);
      Result := True;
    except
    end;
  finally
    Src.Free;
    Tmp.Free;
  end;
end;

end.
