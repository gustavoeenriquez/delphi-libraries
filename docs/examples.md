# Code Examples

Practical examples of using the Delphi Libraries Collection.

## MP3 Decoder Examples

### Example 1: Simple MP3 to WAV Conversion

Command line usage:

```bash
MP3ToWAV input.mp3 output.wav
```

**What happens:**
1. Opens `input.mp3`
2. Decodes all frames
3. Writes 16-bit signed PCM to `output.wav`
4. Closes and exits

---

### Example 2: Batch Conversion

Create `convert-batch.bat`:

```batch
@echo off
setlocal enabledelayedexpansion

set "DECODER=Win64\Release\MP3ToWAV.exe"

for %%F in (*.mp3) do (
    echo Converting %%~nxF ...
    "%DECODER%" "%%F" "%%~dpnF.wav"
    if errorlevel 1 (
        echo FAILED: %%~nxF
    ) else (
        echo OK: %%~nxF
    )
)

echo Done.
```

Usage:
```bash
cd samples
convert-batch.bat
```

---

### Example 3: Programmatic Usage (Delphi Code)

Integrate MP3 decoding into your own Delphi application:

```pascal
program MyMP3App;

uses
  SysUtils,
  Classes,
  MP3Types in 'mp3-decoder/src/MP3Types.pas',
  MP3BitStream in 'mp3-decoder/src/MP3BitStream.pas',
  MP3Frame in 'mp3-decoder/src/MP3Frame.pas',
  MP3Huffman in 'mp3-decoder/src/MP3Huffman.pas',
  MP3ScaleFactors in 'mp3-decoder/src/MP3ScaleFactors.pas',
  MP3Layer3 in 'mp3-decoder/src/MP3Layer3.pas',
  WAVWriter in 'mp3-decoder/src/WAVWriter.pas';

const
  RESERVOIR_SIZE = 4096;

procedure DecodeMP3(const InputFile, OutputFile: string);
var
  MP3Stream: TFileStream;
  Header: TMP3FrameHeader;
  SideInfo: TMP3SideInfo;
  Decoder: TMP3Layer3Decoder;
  WAV: TWAVWriter;
  FrameCount: Integer;
  TotalSamples: Int64;
  
  Reservoir: TBytes;
  ReservoirLen: Integer;
  
  FrameBytes: TBytes;
  SideInfoSize: Integer;
  FrameDataLen: Integer;
  MainDataStart: Integer;
  SBS: TMP3BitStream;
  
  PCMLeft, PCMRight: TArray<Single>;
  MainDataBuf: TBytes;
  MainDataOffset: Integer;
  BytesAfterHeader: Integer;
  
  SampleRate: Integer;
  Channels: Integer;
begin
  Writeln('Opening: ', InputFile);
  
  MP3Stream := TFileStream.Create(InputFile, fmOpenRead);
  Decoder := TMP3Layer3Decoder.Create;
  WAV := nil;
  FrameCount := 0;
  TotalSamples := 0;
  ReservoirLen := 0;
  SetLength(Reservoir, RESERVOIR_SIZE);

  try
    while MP3Stream.Position < MP3Stream.Size - 4 do
    begin
      // Parse frame header
      if not TMP3FrameParser.ParseHeader(MP3Stream, Header) then
        Break;

      // Create WAV writer after first valid header
      if WAV = nil then
      begin
        SampleRate := Header.SampleRate;
        Channels := Header.Channels;
        Writeln(Format('MP3 format: %d Hz, %d ch, %d kbps',
          [SampleRate, Channels, Header.Bitrate]));
        WAV := TWAVWriter.Create(OutputFile, SampleRate, Channels, 16);
      end;

      SideInfoSize := TMP3FrameParser.SideInfoSize(Header);
      FrameDataLen := Header.FrameSize - 4;

      // Read frame data
      SetLength(FrameBytes, FrameDataLen);
      if MP3Stream.Read(FrameBytes[0], FrameDataLen) < FrameDataLen then
        Break;

      // Parse side info
      SBS := TMP3BitStream.Create(FrameBytes, 0);
      try
        if not TMP3FrameParser.ParseSideInfo(SBS, Header, SideInfo) then
          Continue;
      finally
        SBS.Free;
      end;

      // Build main data buffer from reservoir + current frame
      MainDataStart := SideInfoSize;
      BytesAfterHeader := FrameDataLen - SideInfoSize;
      if BytesAfterHeader < 0 then BytesAfterHeader := 0;

      MainDataOffset := SideInfo.MainDataBegin;
      if MainDataOffset > ReservoirLen then
        MainDataOffset := ReservoirLen;

      SetLength(MainDataBuf, MainDataOffset + BytesAfterHeader);
      if MainDataOffset > 0 then
        Move(Reservoir[ReservoirLen - MainDataOffset], MainDataBuf[0], MainDataOffset);
      if BytesAfterHeader > 0 then
        Move(FrameBytes[MainDataStart], MainDataBuf[MainDataOffset], BytesAfterHeader);

      // Decode
      Decoder.DecodeFrame(Header, SideInfo, MainDataBuf, 0, PCMLeft, PCMRight);

      // Write samples
      var nSamples := Length(PCMLeft);
      WAV.WriteSamples(PCMLeft, PCMRight, nSamples);
      Inc(TotalSamples, nSamples);

      // Update reservoir
      if BytesAfterHeader > 0 then
      begin
        if ReservoirLen + BytesAfterHeader > RESERVOIR_SIZE then
        begin
          var Excess := ReservoirLen + BytesAfterHeader - RESERVOIR_SIZE;
          if Excess < ReservoirLen then
          begin
            Move(Reservoir[Excess], Reservoir[0], ReservoirLen - Excess);
            Dec(ReservoirLen, Excess);
          end else
            ReservoirLen := 0;
        end;
        Move(FrameBytes[MainDataStart], Reservoir[ReservoirLen], BytesAfterHeader);
        Inc(ReservoirLen, BytesAfterHeader);
      end;

      Inc(FrameCount);
    end;

    Writeln(Format('Done. Decoded %d frames, %d samples (%.2f seconds)',
      [FrameCount, TotalSamples,
       IfThen(SampleRate > 0, TotalSamples / SampleRate, 0)]));

  finally
    Decoder.Free;
    if WAV <> nil then WAV.Free;
    MP3Stream.Free;
  end;
  
  Writeln('Output written to: ', OutputFile);
end;

begin
  try
    if ParamCount >= 2 then
      DecodeMP3(ParamStr(1), ParamStr(2))
    else
      Writeln('Usage: MyMP3App <input.mp3> <output.wav>');
  except
    on E: Exception do
      Writeln('Error: ', E.Message);
  end;
end.
```

---

### Example 4: Format Detection

Detect MPEG version before decoding:

```pascal
procedure CheckMP3Format(const FileName: string);
var
  Stream: TFileStream;
  Header: TMP3FrameHeader;
  Version: string;
begin
  Stream := TFileStream.Create(FileName, fmOpenRead);
  try
    if TMP3FrameParser.ParseHeader(Stream, Header) then
    begin
      case Header.Version of
        0: Version := 'MPEG2.5';
        2: Version := 'MPEG2';
        3: Version := 'MPEG1';
      else
        Version := 'Unknown';
      end;
      
      Writeln(Format('%s: %s, %d Hz, %d ch, %d kbps, %d bytes',
        [FileName, Version, Header.SampleRate, 
         Header.Channels, Header.Bitrate, Header.FrameSize]));
    end
    else
      Writeln('Invalid MP3 file');
  finally
    Stream.Free;
  end;
end;

begin
  CheckMP3Format('song.mp3');
  // Output: song.mp3: MPEG1, 44100 Hz, 2 ch, 128 kbps, 417 bytes
end.
```

---

### Example 5: Get Audio Properties Without Decoding

Extract duration and properties quickly:

```pascal
function GetMP3Duration(const FileName: string): Double;
var
  Stream: TFileStream;
  Header: TMP3FrameHeader;
  FrameCount: Integer;
begin
  Result := 0;
  Stream := TFileStream.Create(FileName, fmOpenRead);
  try
    FrameCount := 0;
    while Stream.Position < Stream.Size - 4 do
    begin
      if not TMP3FrameParser.ParseHeader(Stream, Header) then
        Break;
      
      // Skip frame data
      Stream.Seek(Header.FrameSize - 4, soFromCurrent);
      Inc(FrameCount);
    end;
    
    // Calculate duration
    if Header.SampleRate > 0 then
    begin
      var SamplesPerFrame: Integer;
      if HDR_TEST_MPEG1(Header.hdr) then
        SamplesPerFrame := 1152
      else
        SamplesPerFrame := 576;
      
      Result := (FrameCount * SamplesPerFrame) / Header.SampleRate;
    end;
  finally
    Stream.Free;
  end;
end;

begin
  var Duration := GetMP3Duration('long-song.mp3');
  Writeln(Format('Duration: %.1f seconds (%.1f minutes)',
    [Duration, Duration / 60]));
end.
```

---

### Example 6: Progress Reporting

Show decoding progress:

```pascal
procedure DecodeWithProgress(const InputFile, OutputFile: string);
var
  MP3Stream: TFileStream;
  TotalFrames: Integer;
  FrameCount: Integer;
  PercentComplete: Integer;
  LastPercent: Integer;
begin
  // First pass: count total frames
  MP3Stream := TFileStream.Create(InputFile, fmOpenRead);
  try
    TotalFrames := 0;
    while MP3Stream.Position < MP3Stream.Size - 4 do
    begin
      var Header: TMP3FrameHeader;
      if not TMP3FrameParser.ParseHeader(MP3Stream, Header) then
        Break;
      MP3Stream.Seek(Header.FrameSize - 4, soFromCurrent);
      Inc(TotalFrames);
    end;
    Writeln(Format('Total frames: %d', [TotalFrames]));
  finally
    MP3Stream.Free;
  end;

  // Second pass: decode with progress
  FrameCount := 0;
  LastPercent := 0;
  
  // (Same decode loop as Example 3, but with progress:)
  // ...
  // Inc(FrameCount);
  // PercentComplete := Round(FrameCount * 100 / TotalFrames);
  // if PercentComplete <> LastPercent then
  // begin
  //   Writeln(Format(#13'%d%% complete...', [PercentComplete]));
  //   LastPercent := PercentComplete;
  // end;
  // ...
end;
```

---

### Example 7: Error Handling

Robust error handling:

```pascal
procedure SafeDecodeMP3(const InputFile, OutputFile: string);
var
  Decoder: TMP3Layer3Decoder;
  WAV: TWAVWriter;
begin
  try
    // Validate inputs
    if not FileExists(InputFile) then
    begin
      Writeln('Error: Input file not found: ', InputFile);
      Exit;
    end;

    if FileExists(OutputFile) then
    begin
      Write('Overwrite existing file? (y/n): ');
      var Response: string;
      Readln(Response);
      if Response <> 'y' then Exit;
    end;

    // Decode
    Decoder := TMP3Layer3Decoder.Create;
    WAV := nil;
    try
      ConvertMP3ToWAV(InputFile, OutputFile);
    finally
      if WAV <> nil then WAV.Free;
      Decoder.Free;
    end;

    Writeln('Success!');
  except
    on E: EFileNotFound do
      Writeln('File error: ', E.Message);
    on E: EAccessViolation do
      Writeln('Access violation (possible corrupted MP3): ', E.Message);
    on E: Exception do
      Writeln('Error: ', E.ClassName, ' - ', E.Message);
  end;
end;
```

---

### Example 8: Extract Specific Frames

Decode only a portion of an MP3:

```pascal
procedure DecodeFrameRange(const InputFile, OutputFile: string; 
                          StartFrame, EndFrame: Integer);
var
  Stream: TFileStream;
  FrameNum: Integer;
  // ... (similar to Example 3)
begin
  FrameNum := 0;
  while Stream.Position < Stream.Size - 4 do
  begin
    if not TMP3FrameParser.ParseHeader(Stream, Header) then Break;
    
    if (FrameNum >= StartFrame) and (FrameNum <= EndFrame) then
    begin
      // Decode this frame
      // ... write to WAV ...
    end
    else if FrameNum > EndFrame then
      Break
    else
    begin
      // Skip frame
      Stream.Seek(Header.FrameSize - 4, soFromCurrent);
    end;
    
    Inc(FrameNum);
  end;
end;

begin
  DecodeFrameRange('song.mp3', 'excerpt.wav', 100, 200);
  // Decodes frames 100-200 (about 5-10 seconds at 24 kHz)
end.
```

---

## Building Examples

Compile any example:

```bash
dcc32 example.pas -U"mp3-decoder\src"
```

Or in Delphi IDE:
1. Create new console project
2. Add `mp3-decoder\src\*.pas` files to project
3. Copy example code
4. Compile (Ctrl+F9)

---

## Testing Provided Samples

Test files are in `mp3-decoder/samples/`:

```bash
cd mp3-decoder
Win64\Release\MP3ToWAV.exe samples\file_7461.mp3 samples\output.wav
```

Expected output:
```
Opening: samples\file_7461.mp3
MP3 format: 24000 Hz, 1 ch, 128 kbps
Decoded: 100 frames, 2.4 seconds
Done. Decoded 165 frames, 95040 samples (3.96 seconds)
Output written to: samples\output.wav
```

---

## Troubleshooting

### "Unit not found"
```
Error: File not found: 'MP3Types.pas'
```

**Solution:** Adjust include paths in `dcc32` or project settings:
```bash
dcc32 myprogram.pas -U"path\to\mp3-decoder\src"
```

### "Access Violation"
```
Exception: Access Violation at address XXXXX
```

**Likely causes:**
- Corrupted MP3 file
- Insufficient memory for large files
- Buffer overflow in Huffman decoder

**Solution:**
- Test with provided sample files first
- Check file integrity: `mp3check.exe file.mp3`
- Ensure 64-bit build on large files

---

Last Updated: 2026-04-02
