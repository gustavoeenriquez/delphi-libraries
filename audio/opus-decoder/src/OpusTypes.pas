unit OpusTypes;

{
  OpusTypes.pas - Opus packet format (RFC 6716 section 3)

  TOC byte parsing and packet frame splitting, ported from libopus
  src/opus.c (opus_packet_parse_impl, opus_packet_get_samples_per_frame).

  Copyright (c) 2011 Xiph.Org Foundation.
  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}

interface

const
  OPUS_SAMPLE_RATE     = 48000;

  OPUS_MODE_SILK       = 0;
  OPUS_MODE_HYBRID     = 1;
  OPUS_MODE_CELT       = 2;

  OPUS_BW_NARROWBAND   = 0;   // 4 kHz
  OPUS_BW_MEDIUMBAND   = 1;   // 6 kHz
  OPUS_BW_WIDEBAND     = 2;   // 8 kHz
  OPUS_BW_SUPERWIDEBAND= 3;   // 12 kHz
  OPUS_BW_FULLBAND     = 4;   // 20 kHz

  OPUS_MAX_FRAMES      = 48;
  OPUS_MAX_PACKET      = 1275;

type
  TOpusTOC = record
    Config      : Integer;   // 0..31
    Stereo      : Boolean;   // S bit
    Code        : Integer;   // 0..3 (frame count code)
    Mode        : Integer;   // OPUS_MODE_*
    Bandwidth   : Integer;   // OPUS_BW_*
    FrameSamples: Integer;   // samples per frame at 48 kHz
  end;

  TOpusPacketInfo = record
    TOC         : TOpusTOC;
    NumFrames   : Integer;
    FrameSizes  : array[0..OPUS_MAX_FRAMES - 1] of Integer;
    FrameOffsets: array[0..OPUS_MAX_FRAMES - 1] of Integer;  // byte offset in packet
    Padding     : Integer;
  end;

procedure OpusParseTOC(B: Byte; out TOC: TOpusTOC);

// Split a packet into frames (RFC 6716 section 3.2). Returns False if the
// packet is malformed.
function OpusParsePacket(Data: PByte; Len: Integer; out Info: TOpusPacketInfo): Boolean;

const
  OPUS_CONFIG_MODE: array[0..31] of Integer = (
    0,0,0,0, 0,0,0,0, 0,0,0,0,
    1,1,1,1,
    2,2,2,2, 2,2,2,2, 2,2,2,2, 2,2,2,2);
  OPUS_CONFIG_BANDWIDTH: array[0..31] of Integer = (
    0,0,0,0, 1,1,1,1, 2,2,2,2,
    3,3, 4,4,
    0,0,0,0, 2,2,2,2, 3,3,3,3, 4,4,4,4);

implementation

function SamplesPerFrame(B: Byte): Integer;
var
  A: Integer;
begin
  if (B and $80) <> 0 then
  begin
    A := (B shr 3) and 3;
    Result := (OPUS_SAMPLE_RATE shl A) div 400;
  end
  else if (B and $60) = $60 then
  begin
    if (B and $08) <> 0 then Result := OPUS_SAMPLE_RATE div 50
    else Result := OPUS_SAMPLE_RATE div 100;
  end
  else
  begin
    A := (B shr 3) and 3;
    if A = 3 then Result := OPUS_SAMPLE_RATE * 60 div 1000
    else Result := (OPUS_SAMPLE_RATE shl A) div 100;
  end;
end;

procedure OpusParseTOC(B: Byte; out TOC: TOpusTOC);
begin
  TOC.Config    := B shr 3;
  TOC.Stereo    := (B and $04) <> 0;
  TOC.Code      := B and $03;
  TOC.Mode      := OPUS_CONFIG_MODE[TOC.Config];
  TOC.Bandwidth := OPUS_CONFIG_BANDWIDTH[TOC.Config];
  TOC.FrameSamples := SamplesPerFrame(B);
end;

function ParseSize(Data: PByte; Len: Integer; out Size: Integer): Integer;
begin
  if Len < 1 then
  begin
    Size := -1;
    Exit(-1);
  end
  else if Data[0] < 252 then
  begin
    Size := Data[0];
    Exit(1);
  end
  else if Len < 2 then
  begin
    Size := -1;
    Exit(-1);
  end
  else
  begin
    Size := 4 * Data[1] + Data[0];
    Exit(2);
  end;
end;

function OpusParsePacket(Data: PByte; Len: Integer; out Info: TOpusPacketInfo): Boolean;
var
  Pos, I, Bytes, Count, LastSize, Pad, P, Tmp: Integer;
  Ch: Byte;
  Cbr: Boolean;
begin
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  if Len <= 0 then Exit;
  OpusParseTOC(Data[0], Info.TOC);
  Pos := 1;
  Dec(Len);
  LastSize := Len;
  Cbr := False;
  Pad := 0;
  case Info.TOC.Code of
    0: Count := 1;
    1: begin
         Count := 2;
         Cbr := True;
         if (Len and 1) <> 0 then Exit;
         LastSize := Len div 2;
         Info.FrameSizes[0] := LastSize;
       end;
    2: begin
         Count := 2;
         Bytes := ParseSize(Data + Pos, Len, Info.FrameSizes[0]);
         if Bytes < 0 then Exit;
         Len := Len - Bytes;
         if (Info.FrameSizes[0] < 0) or (Info.FrameSizes[0] > Len) then Exit;
         Pos := Pos + Bytes;
         LastSize := Len - Info.FrameSizes[0];
       end;
  else
    begin
      if Len < 1 then Exit;
      Ch := Data[Pos];
      Inc(Pos);
      Count := Ch and $3F;
      if (Count <= 0) or (Info.TOC.FrameSamples * Count > 5760) then Exit;
      Dec(Len);
      if (Ch and $40) <> 0 then
      begin
        repeat
          if Len <= 0 then Exit;
          P := Data[Pos];
          Inc(Pos);
          Dec(Len);
          if P = 255 then Tmp := 254 else Tmp := P;
          Len := Len - Tmp;
          Pad := Pad + Tmp;
        until P <> 255;
      end;
      if Len < 0 then Exit;
      Cbr := (Ch and $80) = 0;
      if not Cbr then
      begin
        LastSize := Len;
        for I := 0 to Count - 2 do
        begin
          Bytes := ParseSize(Data + Pos, Len, Info.FrameSizes[I]);
          if Bytes < 0 then Exit;
          Len := Len - Bytes;
          if (Info.FrameSizes[I] < 0) or (Info.FrameSizes[I] > Len) then Exit;
          Pos := Pos + Bytes;
          LastSize := LastSize - (Bytes + Info.FrameSizes[I]);
        end;
        if LastSize < 0 then Exit;
      end
      else
      begin
        LastSize := Len div Count;
        if LastSize * Count <> Len then Exit;
        for I := 0 to Count - 2 do
          Info.FrameSizes[I] := LastSize;
      end;
    end;
  end;
  if LastSize > OPUS_MAX_PACKET then Exit;
  Info.FrameSizes[Count - 1] := LastSize;
  Info.NumFrames := Count;
  Info.Padding := Pad;
  for I := 0 to Count - 1 do
  begin
    Info.FrameOffsets[I] := Pos;
    Pos := Pos + Info.FrameSizes[I];
  end;
  Result := True;
end;

end.
