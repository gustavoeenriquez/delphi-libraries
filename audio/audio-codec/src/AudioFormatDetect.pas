unit AudioFormatDetect;

{
  AudioFormatDetect.pas - Detect audio format from stream magic bytes

  Reads the first bytes of a stream (restoring the stream position afterward)
  and identifies the format as one of the TAudioFormat values:

    afWAV     — RIFF.... WAVE
    afFLAC    — fLaC
    afVorbis  — Ogg container with first packet starting with 0x01 'vorbis'
    afOpus    — Ogg container with first packet starting with 'OpusHead'
    afMP3     — MPEG frame sync (0xFF 0xE?) or ID3v2 tag ('ID3')
    afUnknown — none of the above, or empty/nil stream

  The stream position is always restored after detection.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Classes,
  AudioTypes;

// Detect the audio format of AStream by inspecting magic bytes.
// Saves and restores the stream position. Returns afUnknown on any error.
function DetectAudioFormat(AStream: TStream): TAudioFormat;

implementation

const
  DETECT_BYTES = 256;  // how many bytes to peek at

// Inspect an Ogg page header (already read into Buf[0..BufLen-1]) and
// determine whether the first packet is Vorbis or Opus.
function DetectOggSubtype(const Buf: array of Byte; BufLen: Integer): TAudioFormat;
var
  NSeg    : Integer;
  DataOff : Integer;
begin
  Result := afUnknown;
  // Ogg page header: 27 bytes + n_segments lacing table
  if BufLen < 28 then Exit;
  NSeg    := Buf[26];
  DataOff := 27 + NSeg;
  if DataOff + 7 > BufLen then Exit;

  // Vorbis identification header: type byte 0x01 followed by 'vorbis' (7 bytes)
  if (Buf[DataOff] = $01) and
     (Buf[DataOff + 1] = Ord('v')) and
     (Buf[DataOff + 2] = Ord('o')) and
     (Buf[DataOff + 3] = Ord('r')) and
     (Buf[DataOff + 4] = Ord('b')) and
     (Buf[DataOff + 5] = Ord('i')) and
     (Buf[DataOff + 6] = Ord('s')) then
    Exit(afVorbis);

  // Opus identification header: 'OpusHead' (8 bytes)
  if (DataOff + 8 <= BufLen) and
     (Buf[DataOff]     = Ord('O')) and
     (Buf[DataOff + 1] = Ord('p')) and
     (Buf[DataOff + 2] = Ord('u')) and
     (Buf[DataOff + 3] = Ord('s')) and
     (Buf[DataOff + 4] = Ord('H')) and
     (Buf[DataOff + 5] = Ord('e')) and
     (Buf[DataOff + 6] = Ord('a')) and
     (Buf[DataOff + 7] = Ord('d')) then
    Exit(afOpus);
end;

function DetectAudioFormat(AStream: TStream): TAudioFormat;
var
  SavePos : Int64;
  Buf     : array[0..DETECT_BYTES - 1] of Byte;
  NRead   : Integer;
begin
  Result := afUnknown;
  if AStream = nil then Exit;

  // Save position; bail if stream doesn't support Position
  try
    SavePos := AStream.Position;
  except
    Exit;
  end;

  try
    NRead := AStream.Read(Buf[0], SizeOf(Buf));
  except
    NRead := 0;
  end;

  // Always restore position
  try
    AStream.Position := SavePos;
  except
    // Best-effort; not all streams are seekable
  end;

  if NRead < 4 then Exit;

  // ---- RIFF WAVE ----
  if (Buf[0] = Ord('R')) and (Buf[1] = Ord('I')) and
     (Buf[2] = Ord('F')) and (Buf[3] = Ord('F')) then
  begin
    if (NRead >= 12) and
       (Buf[8]  = Ord('W')) and (Buf[9]  = Ord('A')) and
       (Buf[10] = Ord('V')) and (Buf[11] = Ord('E')) then
      Result := afWAV;
    Exit;
  end;

  // ---- FLAC ----
  if (Buf[0] = Ord('f')) and (Buf[1] = Ord('L')) and
     (Buf[2] = Ord('a')) and (Buf[3] = Ord('C')) then
  begin
    Result := afFLAC;
    Exit;
  end;

  // ---- Ogg container (Vorbis or Opus) ----
  if (Buf[0] = Ord('O')) and (Buf[1] = Ord('g')) and
     (Buf[2] = Ord('g')) and (Buf[3] = Ord('S')) then
  begin
    Result := DetectOggSubtype(Buf, NRead);
    Exit;
  end;

  // ---- MP3: ID3v2 tag ----
  if (Buf[0] = Ord('I')) and (Buf[1] = Ord('D')) and (Buf[2] = Ord('3')) then
  begin
    Result := afMP3;
    Exit;
  end;

  // ---- MP3: MPEG frame sync (0xFF 0xE0 mask) ----
  if (Buf[0] = $FF) and ((Buf[1] and $E0) = $E0) then
  begin
    Result := afMP3;
    Exit;
  end;
end;

end.
