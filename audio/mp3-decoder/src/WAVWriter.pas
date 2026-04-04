unit WAVWriter;

{
  WAVWriter.pas - WAV file writer for PCM audio

  Writes standard RIFF/WAV files with 16-bit signed PCM
  to accompany the minimp3 Delphi translation.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Classes, Math;

type
  TWAVWriter = class
  private
    FStream: TFileStream;
    FSampleRate: Integer;
    FChannels: Integer;
    FBitsPerSample: Integer;
    FDataSize: Cardinal;
    FRIFFSizeOffset: Int64;
    FDataSizeOffset: Int64;

    procedure WriteHeader;
  public
    constructor Create(const FileName: string;
      SampleRate, Channels, BitsPerSample: Integer);
    destructor Destroy; override;

    // Write interleaved PCM samples (Left[0], Right[0], Left[1], Right[1], ...)
    procedure WriteSamples(const Left, Right: TArray<Single>; Count: Integer);

    // Finalize: patch RIFF and data chunk sizes
    procedure Finalize;
  end;

implementation

procedure WriteWord(Stream: TStream; Value: Word);
begin
  Stream.WriteBuffer(Value, 2);
end;

procedure WriteDWord(Stream: TStream; Value: Cardinal);
begin
  Stream.WriteBuffer(Value, 4);
end;

procedure WriteString(Stream: TStream; const S: AnsiString);
begin
  if Length(S) > 0 then
    Stream.WriteBuffer(S[1], Length(S));
end;

constructor TWAVWriter.Create(const FileName: string;
  SampleRate, Channels, BitsPerSample: Integer);
begin
  inherited Create;
  FSampleRate := SampleRate;
  FChannels := Channels;
  FBitsPerSample := BitsPerSample;
  FDataSize := 0;
  FStream := TFileStream.Create(FileName, fmCreate);
  WriteHeader;
end;

destructor TWAVWriter.Destroy;
begin
  if Assigned(FStream) then
  begin
    Finalize;
    FStream.Free;
    FStream := nil;
  end;
  inherited Destroy;
end;

procedure TWAVWriter.WriteHeader;
var
  ByteRate: Cardinal;
  BlockAlign: Word;
begin
  // RIFF chunk
  WriteString(FStream, 'RIFF');
  FRIFFSizeOffset := FStream.Position;
  WriteDWord(FStream, 0);  // placeholder for file size - 8
  WriteString(FStream, 'WAVE');

  // fmt subchunk
  WriteString(FStream, 'fmt ');
  WriteDWord(FStream, 16);  // PCM format chunk size
  WriteWord(FStream, 1);    // PCM = 1
  WriteWord(FStream, FChannels);
  WriteDWord(FStream, FSampleRate);

  ByteRate := FSampleRate * FChannels * (FBitsPerSample div 8);
  BlockAlign := FChannels * (FBitsPerSample div 8);

  WriteDWord(FStream, ByteRate);
  WriteWord(FStream, BlockAlign);
  WriteWord(FStream, FBitsPerSample);

  // data subchunk header
  WriteString(FStream, 'data');
  FDataSizeOffset := FStream.Position;
  WriteDWord(FStream, 0);  // placeholder for data size
end;

procedure TWAVWriter.WriteSamples(const Left, Right: TArray<Single>; Count: Integer);
var
  I: Integer;
  S16: SmallInt;
  F: Single;
begin
  for I := 0 to Count - 1 do
  begin
    // Left channel
    if I < Length(Left) then
      F := Left[I]
    else
      F := 0.0;

    // Clamp and convert to 16-bit
    if F > 1.0 then F := 1.0;
    if F < -1.0 then F := -1.0;
    S16 := SmallInt(Round(F * 32767.0));
    FStream.WriteBuffer(S16, 2);
    Inc(FDataSize, 2);

    // Right channel
    if FChannels > 1 then
    begin
      if I < Length(Right) then
        F := Right[I]
      else
        F := 0.0;

      if F > 1.0 then F := 1.0;
      if F < -1.0 then F := -1.0;
      S16 := SmallInt(Round(F * 32767.0));
      FStream.WriteBuffer(S16, 2);
      Inc(FDataSize, 2);
    end;
  end;
end;

procedure TWAVWriter.Finalize;
var
  RIFFSize: Cardinal;
begin
  if not Assigned(FStream) then Exit;

  // Patch data chunk size
  FStream.Position := FDataSizeOffset;
  WriteDWord(FStream, FDataSize);

  // Patch RIFF chunk size = file size - 8
  // = 4 (WAVE) + 8 (fmt tag+size) + 16 (fmt data) + 8 (data tag+size) + data
  RIFFSize := 4 + 8 + 16 + 8 + FDataSize;
  FStream.Position := FRIFFSizeOffset;
  WriteDWord(FStream, RIFFSize);

  // Return to end of file
  FStream.Seek(0, soEnd);
end;

end.
