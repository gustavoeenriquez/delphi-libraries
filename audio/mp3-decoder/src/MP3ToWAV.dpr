program MP3ToWAV;

{
  MP3ToWAV.dpr - MP3 to WAV converter using minimp3 Delphi translation

  Supports MPEG1, MPEG2, and MPEG2.5 Layer III
  Based on minimp3 by lieff (https://github.com/lieff/minimp3)

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/

  To the extent possible under law, the author(s) of the original minimp3
  have dedicated all copyright and related and neighboring rights to this
  software to the public domain worldwide. This Delphi implementation
  maintains the same public domain dedication.
}

{$APPTYPE CONSOLE}

{$R *.res}

uses
  SysUtils,
  Classes,
  Math,
  MP3Types in 'MP3Types.pas',
  MP3BitStream in 'MP3BitStream.pas',
  MP3Frame in 'MP3Frame.pas',
  MP3Huffman in 'MP3Huffman.pas',
  MP3ScaleFactors in 'MP3ScaleFactors.pas',
  MP3Layer3 in 'MP3Layer3.pas',
  WAVWriter in 'WAVWriter.pas';

procedure ConvertMP3ToWAV(const InputFile, OutputFile: string);
const
  RESERVOIR_SIZE = 4096;  // Max bit reservoir bytes
var
  MP3Stream: TFileStream;
  Header: TMP3FrameHeader;
  SideInfo: TMP3SideInfo;
  Decoder: TMP3Layer3Decoder;
  WAV: TWAVWriter;
  FrameCount: Integer;
  TotalSamples: Int64;

  // Bit reservoir
  Reservoir: TBytes;
  ReservoirLen: Integer;

  // Frame data
  FrameBytes: TBytes;
  SideInfoSize: Integer;
  FrameDataLen: Integer;
  MainDataStart: Integer;
  SBS: TMP3BitStream;

  PCMLeft, PCMRight: TArray<Single>;

  FrameStartPos: Int64;
  BytesAfterHeader: Integer;
  MainDataBuf: TBytes;
  MainDataOffset: Integer;

  SampleRate: Integer;
  Channels: Integer;
begin
  if not FileExists(InputFile) then
  begin
    Writeln('Error: Input file not found: ', InputFile);
    Exit;
  end;

  Writeln('Opening: ', InputFile);

  MP3Stream := TFileStream.Create(InputFile, fmOpenRead or fmShareDenyNone);
  try
    Decoder := TMP3Layer3Decoder.Create;
    WAV := nil;
    FrameCount := 0;
    TotalSamples := 0;
    ReservoirLen := 0;
    SetLength(Reservoir, RESERVOIR_SIZE);

    try
      while MP3Stream.Position < MP3Stream.Size - 4 do
      begin
        FrameStartPos := MP3Stream.Position;

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
        FrameDataLen := Header.FrameSize - 4;  // minus header bytes

        // Read the entire frame data (side info + main data)
        SetLength(FrameBytes, FrameDataLen);
        if MP3Stream.Read(FrameBytes[0], FrameDataLen) < FrameDataLen then
          Break;

        // Parse side info from frame bytes
        SBS := TMP3BitStream.Create(FrameBytes, 0);
        try
          if not TMP3FrameParser.ParseSideInfo(SBS, Header, SideInfo) then
            Continue;
        finally
          SBS.Free;
        end;

        // Main data begins after side info bytes
        MainDataStart := SideInfoSize;

        // The main_data_begin pointer tells us how many bytes of main data
        // come from the reservoir (before current frame)
        // MainDataBegin = SideInfo.MainDataBegin bytes before current frame's main data

        // Build the main data buffer:
        // [last MainDataBegin bytes from reservoir] + [current frame main data]
        // We then pass offset 0 into this combined buffer

        BytesAfterHeader := FrameDataLen - SideInfoSize;
        if BytesAfterHeader < 0 then BytesAfterHeader := 0;

        // How many bytes we need from the reservoir
        MainDataOffset := SideInfo.MainDataBegin;

        if MainDataOffset > ReservoirLen then
          MainDataOffset := ReservoirLen;

        // Build main data buffer
        SetLength(MainDataBuf, MainDataOffset + BytesAfterHeader);
        if MainDataOffset > 0 then
          Move(Reservoir[ReservoirLen - MainDataOffset], MainDataBuf[0], MainDataOffset);

        if BytesAfterHeader > 0 then
          Move(FrameBytes[MainDataStart], MainDataBuf[MainDataOffset], BytesAfterHeader);

        // Decode the frame
        Decoder.DecodeFrame(Header, SideInfo, MainDataBuf, 0,
          PCMLeft, PCMRight);

        // Write PCM to WAV
        WAV.WriteSamples(PCMLeft, PCMRight, 576);
        if HDR_TEST_MPEG1(Header.hdr) then
        begin
          WAV.WriteSamples(
            Copy(PCMLeft,  576, 576),
            Copy(PCMRight, 576, 576),
            576);
          Inc(TotalSamples, 1152);
        end
        else
          Inc(TotalSamples, 576);

        // Update reservoir: append current frame's main data
        // Shift existing reservoir data
        if BytesAfterHeader > 0 then
        begin
          // Shift reservoir left if needed to make room
          if ReservoirLen + BytesAfterHeader > RESERVOIR_SIZE then
          begin
            // Remove oldest data
            var Excess := ReservoirLen + BytesAfterHeader - RESERVOIR_SIZE;
            if Excess < ReservoirLen then
            begin
              Move(Reservoir[Excess], Reservoir[0], ReservoirLen - Excess);
              Dec(ReservoirLen, Excess);
            end
            else
              ReservoirLen := 0;
          end;

          // Append new data
          Move(FrameBytes[MainDataStart], Reservoir[ReservoirLen], BytesAfterHeader);
          Inc(ReservoirLen, BytesAfterHeader);
        end;

        Inc(FrameCount);

        // Progress every 100 frames
        if FrameCount mod 100 = 0 then
        begin
          Write(Format(#13'Decoded: %d frames, %.1f seconds',
            [FrameCount, TotalSamples / Header.SampleRate]));
        end;
      end;

      Writeln;
      Writeln(Format('Done. Decoded %d frames, %d samples (%.2f seconds)',
        [FrameCount, TotalSamples,
         IfThen(Header.SampleRate > 0, TotalSamples / Header.SampleRate, 0)]));

    finally
      Decoder.Free;
      if WAV <> nil then
        WAV.Free;
    end;
  finally
    MP3Stream.Free;
  end;

  Writeln('Output written to: ', OutputFile);
end;

var
  InputFile, OutputFile: string;

begin
  try
    if ParamCount >= 2 then
    begin
      InputFile := ParamStr(1);
      OutputFile := ParamStr(2);
    end
    else if ParamCount = 1 then
    begin
      InputFile := ParamStr(1);
      OutputFile := ChangeFileExt(InputFile, '.wav');
    end
    else
    begin
      // Default for testing
      InputFile := 'input.mp3';
      OutputFile := 'output.wav';
      Writeln('Usage: MP3ToWAV <input.mp3> [output.wav]');
      Writeln('Using defaults: input.mp3 -> output.wav');
    end;

    ConvertMP3ToWAV(InputFile, OutputFile);

  except
    on E: Exception do
    begin
      Writeln('Exception: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
