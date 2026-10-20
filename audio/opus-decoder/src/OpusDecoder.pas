unit OpusDecoder;

{
  OpusDecoder.pas - Opus stream decoder (packet level) and Ogg Opus reader

  TOpusStreamDecoder mirrors libopus src/opus_decoder.c (opus_decode_frame /
  opus_decode_native): SILK-only, hybrid and CELT-only modes, redundancy
  frames, mode transitions and packet loss concealment. Output is planar
  float at 48 kHz.

  TOpusDecoder reads an Ogg Opus stream (RFC 7845): OpusHead/OpusTags,
  pre-skip, output gain and end trimming from the granule position.

  Copyright (c) 2010-2011 Xiph.Org Foundation, Skype Limited.
  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  SysUtils, Classes, Math,
  AudioTypes,
  OggTypes,
  OggPageReader,
  OpusTypes,
  OpusEntDec,
  OpusCeltTables,
  OpusCelt,
  OpusSilk;

const
  OPUS_F20  = 960;
  OPUS_F10  = 480;
  OPUS_F5   = 240;
  OPUS_F2_5 = 120;

type
  // Decodes raw Opus packets to planar float 48 kHz
  TOpusStreamDecoder = class
  private
    FChannels       : Integer;
    FStreamChannels : Integer;
    FCelt           : TCeltDecoder;
    FSilk           : TSilkDecoder;
    FSilkCtl        : TSilkDecControl;
    FMode           : Integer;
    FPrevMode       : Integer;    // -1 = none yet
    FBandwidth      : Integer;
    FFrameSize      : Integer;
    FPrevRedundancy : Boolean;
    FLastPacketDuration: Integer;
    FPcmSilk        : TArray<SmallInt>;
    function DecodeFrame(Data: PByte; Len: Integer; const Pcm: array of PSingle;
      FrameSize: Integer): Integer;
    procedure SmoothFade(In1, In2, OutP: array of PSingle; Offset1, Offset2, OffsetOut, Overlap: Integer);
  public
    constructor Create(AChannels: Integer);
    destructor Destroy; override;
    // Decode one packet (TOC + frames) into Output (allocated here).
    // Returns samples per channel, 0 for an empty packet, < 0 on error.
    function DecodePacket(Data: PByte; Len: Integer; out Output: TAudioBuffer): Integer;
    // Conceal LostSamples (multiple of 120) samples
    function DecodeLost(LostSamples: Integer; out Output: TAudioBuffer): Integer;
    property Channels: Integer read FChannels;
    property LastMode: Integer read FMode;
  end;

  TOpusHead = record
    Version          : Byte;
    Channels         : Byte;
    PreSkip          : Word;
    InputSampleRate  : Cardinal;
    OutputGainQ8     : SmallInt;
    ChannelMappingFamily: Byte;
    StreamCount      : Byte;
    CoupledCount     : Byte;
    ChannelMap       : array[0..255] of Byte;
  end;

  TOpusDecoder = class
  private
    FReader      : TOggPageReader;
    FHead        : TOpusHead;
    FReady       : Boolean;
    FPreSkipLeft : Integer;
    FGranulePos  : Int64;
    FTotalOut    : Int64;
    FStream      : TOpusStreamDecoder;
    FHeaderCount : Integer;
    FGain        : Single;
    function ParseOpusHead(const Pkt: TOggPacket): Boolean;
    function ReadHeaders: Boolean;
  public
    constructor Create(AStream: TStream; OwnsStream: Boolean = False);
    destructor  Destroy; override;
    function Decode(out Buffer: TAudioBuffer; out Samples: Integer): TAudioDecodeResult;
    property Ready      : Boolean  read FReady;
    property Channels   : Byte     read FHead.Channels;
    property SampleRate : Cardinal read FHead.InputSampleRate;
    property PreSkip    : Word     read FHead.PreSkip;
    property GranulePos : Int64    read FGranulePos;
  end;

implementation

// ---------------------------------------------------------------------------
// TOpusStreamDecoder
// ---------------------------------------------------------------------------

constructor TOpusStreamDecoder.Create(AChannels: Integer);
begin
  inherited Create;
  if AChannels > 2 then AChannels := 2;
  if AChannels < 1 then AChannels := 1;
  FChannels := AChannels;
  FStreamChannels := AChannels;
  FCelt := TCeltDecoder.Create(AChannels);
  FSilk := TSilkDecoder.Create;
  FPrevMode := -1;
  FMode := -1;
  FFrameSize := 960;
  FPrevRedundancy := False;
  SetLength(FPcmSilk, 2 * 3 * OPUS_F20);  // up to 60 ms stereo
  FillChar(FSilkCtl, SizeOf(FSilkCtl), 0);
  FSilkCtl.nChannelsAPI := AChannels;
end;

destructor TOpusStreamDecoder.Destroy;
begin
  FSilk.Free;
  FCelt.Free;
  inherited;
end;

// out = w*in2 + (1-w)*in1 over Overlap samples, w = window^2
procedure TOpusStreamDecoder.SmoothFade(In1, In2, OutP: array of PSingle;
  Offset1, Offset2, OffsetOut, Overlap: Integer);
var
  C, I: Integer;
  W: Single;
begin
  for C := 0 to FChannels - 1 do
    for I := 0 to Overlap - 1 do
    begin
      W := CELT_WINDOW120[I] * CELT_WINDOW120[I];
      OutP[C][OffsetOut + I] := W * In2[C][Offset2 + I] + (1 - W) * In1[C][Offset1 + I];
    end;
end;

function TOpusStreamDecoder.DecodeFrame(Data: PByte; Len: Integer;
  const Pcm: array of PSingle; FrameSize: Integer): Integer;
var
  Rd           : TEcDec;
  C, I         : Integer;
  AudioSize    : Integer;
  Mode, Bandwidth: Integer;
  Transition   : Boolean;
  StartBand    : Integer;
  Redundancy   : Boolean;
  RedundancyBytes: Integer;
  CeltToSilk   : Integer;
  EndBand      : Integer;
  CeltRet      : Integer;
  SilkFrameSize, DecodedSamples, LostFlag: Integer;
  PcmTransition: array[0..1] of TArray<Single>;
  Redundant    : array[0..1] of TArray<Single>;
  TransPtrs, RedPtrs, PcmPtrs: array[0..1] of PSingle;
  Silence      : array[0..1] of Byte;
  Ret          : Integer;
  CeltFrame    : Integer;
begin
  Result := 0;
  if Len <= 1 then Data := nil;
  if FrameSize < OPUS_F2_5 then Exit(-2);
  FrameSize := Min(FrameSize, 48000 div 25 * 3);
  if Data = nil then
    FrameSize := Min(FrameSize, FFrameSize);

  if Data <> nil then
  begin
    AudioSize := FFrameSize;
    Mode := FMode;
    Bandwidth := FBandwidth;
    EcDecInit(Rd, Data, Len);
  end
  else
  begin
    AudioSize := FrameSize;
    if FPrevRedundancy then Mode := OPUS_MODE_CELT else Mode := FPrevMode;
    Bandwidth := -1;
    if Mode < 0 then
    begin
      for C := 0 to FChannels - 1 do
        for I := 0 to AudioSize - 1 do Pcm[C][I] := 0;
      Exit(AudioSize);
    end;
    if AudioSize > OPUS_F20 then
    begin
      I := 0;
      while I < AudioSize do
      begin
        PcmPtrs[0] := Pcm[0] + I;
        PcmPtrs[1] := Pcm[Min(1, FChannels - 1)] + I;
        Ret := DecodeFrame(nil, 0, PcmPtrs, Min(AudioSize - I, OPUS_F20));
        if Ret < 0 then Exit(Ret);
        Inc(I, Ret);
      end;
      Exit(FrameSize);
    end
    else if AudioSize < OPUS_F20 then
    begin
      if AudioSize > OPUS_F10 then AudioSize := OPUS_F10
      else if (Mode <> OPUS_MODE_SILK) and (AudioSize > OPUS_F5) and (AudioSize < OPUS_F10) then AudioSize := OPUS_F5;
    end;
  end;

  for C := 0 to 1 do
  begin
    PcmPtrs[C] := Pcm[Min(C, FChannels - 1)];
  end;

  Transition := (Data <> nil) and (FPrevMode >= 0) and (
    ((Mode = OPUS_MODE_CELT) and (FPrevMode <> OPUS_MODE_CELT) and (not FPrevRedundancy)) or
    ((Mode <> OPUS_MODE_CELT) and (FPrevMode = OPUS_MODE_CELT)));
  if Transition then
  begin
    for C := 0 to FChannels - 1 do
    begin
      SetLength(PcmTransition[C], OPUS_F5);
      TransPtrs[C] := @PcmTransition[C][0];
    end;
    if FChannels = 1 then TransPtrs[1] := TransPtrs[0];
  end;
  if Transition and (Mode = OPUS_MODE_CELT) then
    DecodeFrame(nil, 0, TransPtrs, Min(OPUS_F5, AudioSize));

  if AudioSize > FrameSize then Exit(-1)
  else FrameSize := AudioSize;

  // ---- SILK ----
  if Mode <> OPUS_MODE_CELT then
  begin
    if FPrevMode = OPUS_MODE_CELT then
      FSilk.Reset;
    FSilkCtl.nChannelsAPI := FChannels;
    FSilkCtl.payloadSize_ms := Max(10, 1000 * AudioSize div 48000);
    if Data <> nil then
    begin
      FSilkCtl.nChannelsInternal := FStreamChannels;
      if Mode = OPUS_MODE_SILK then
      begin
        case Bandwidth of
          OPUS_BW_NARROWBAND: FSilkCtl.internalSampleRate := 8000;
          OPUS_BW_MEDIUMBAND: FSilkCtl.internalSampleRate := 12000;
        else FSilkCtl.internalSampleRate := 16000;
        end;
      end
      else
        FSilkCtl.internalSampleRate := 16000;
    end;
    if Data = nil then LostFlag := SILK_FLAG_PACKET_LOST else LostFlag := SILK_FLAG_DECODE_NORMAL;
    DecodedSamples := 0;
    repeat
      Ret := FSilk.Decode(FSilkCtl, LostFlag, DecodedSamples = 0, Rd,
        @FPcmSilk[DecodedSamples * FChannels], SilkFrameSize);
      if Ret <> 0 then
      begin
        if LostFlag <> 0 then
        begin
          SilkFrameSize := FrameSize;
          for I := 0 to FrameSize * FChannels - 1 do FPcmSilk[I] := 0;
        end
        else
          Exit(-3);
      end;
      Inc(DecodedSamples, SilkFrameSize);
    until DecodedSamples >= FrameSize;
  end;

  StartBand := 0;
  Redundancy := False;
  RedundancyBytes := 0;
  CeltToSilk := 0;
  if (Mode <> OPUS_MODE_CELT) and (Data <> nil) and
     (EcTell(Rd) + 17 + 20 * Ord(Mode = OPUS_MODE_HYBRID) <= 8 * Len) then
  begin
    if Mode = OPUS_MODE_HYBRID then
      Redundancy := EcDecBitLogp(Rd, 12) <> 0
    else
      Redundancy := True;
    if Redundancy then
    begin
      CeltToSilk := EcDecBitLogp(Rd, 1);
      if Mode = OPUS_MODE_HYBRID then
        RedundancyBytes := Integer(EcDecUInt(Rd, 256)) + 2
      else
        RedundancyBytes := Len - ((EcTell(Rd) + 7) shr 3);
      Len := Len - RedundancyBytes;
      if Len * 8 < EcTell(Rd) then
      begin
        Len := 0;
        RedundancyBytes := 0;
        Redundancy := False;
      end;
      Rd.Storage := Rd.Storage - Cardinal(RedundancyBytes);
    end;
  end;
  if Mode <> OPUS_MODE_CELT then
    StartBand := 17;

  if Redundancy then
    Transition := False;

  if Transition and (Mode <> OPUS_MODE_CELT) then
    DecodeFrame(nil, 0, TransPtrs, Min(OPUS_F5, AudioSize));

  if Bandwidth >= 0 then
  begin
    case Bandwidth of
      OPUS_BW_NARROWBAND:    EndBand := 13;
      OPUS_BW_MEDIUMBAND,
      OPUS_BW_WIDEBAND:      EndBand := 17;
      OPUS_BW_SUPERWIDEBAND: EndBand := 19;
    else                     EndBand := 21;
    end;
    FCelt.EndBand := EndBand;
  end;
  FCelt.StreamChannels := FStreamChannels;

  if Redundancy then
  begin
    for C := 0 to FChannels - 1 do
    begin
      SetLength(Redundant[C], OPUS_F5);
      RedPtrs[C] := @Redundant[C][0];
    end;
    if FChannels = 1 then RedPtrs[1] := RedPtrs[0];
  end;

  // 5 ms redundant frame for CELT -> SILK
  if Redundancy and (CeltToSilk <> 0) then
  begin
    FCelt.StartBand := 0;
    FCelt.Decode(Data + Len, RedundancyBytes, RedPtrs, OPUS_F5, nil);
  end;

  FCelt.StartBand := StartBand;

  CeltRet := 0;
  if Mode <> OPUS_MODE_SILK then
  begin
    CeltFrame := Min(OPUS_F20, FrameSize);
    if (Mode <> FPrevMode) and (FPrevMode >= 0) and (not FPrevRedundancy) then
      FCelt.Reset;
    CeltRet := FCelt.Decode(Data, Len, PcmPtrs, CeltFrame, @Rd);
  end
  else
  begin
    for C := 0 to FChannels - 1 do
      for I := 0 to FrameSize - 1 do Pcm[C][I] := 0;
    if (FPrevMode = OPUS_MODE_HYBRID) and not (Redundancy and (CeltToSilk <> 0) and FPrevRedundancy) then
    begin
      Silence[0] := $FF; Silence[1] := $FF;
      FCelt.StartBand := 0;
      FCelt.Decode(@Silence[0], 2, PcmPtrs, OPUS_F2_5, nil);
    end;
  end;

  if Mode <> OPUS_MODE_CELT then
    for C := 0 to FChannels - 1 do
      for I := 0 to FrameSize - 1 do
        Pcm[C][I] := Pcm[C][I] + FPcmSilk[I * FChannels + C] * (1.0 / 32768.0);

  // 5 ms redundant frame for SILK -> CELT
  if Redundancy and (CeltToSilk = 0) then
  begin
    FCelt.Reset;
    FCelt.StartBand := 0;
    FCelt.Decode(Data + Len, RedundancyBytes, RedPtrs, OPUS_F5, nil);
    SmoothFade(Pcm, RedPtrs, Pcm, FrameSize - OPUS_F2_5, OPUS_F2_5, FrameSize - OPUS_F2_5, OPUS_F2_5);
  end;
  if Redundancy and (CeltToSilk <> 0) and ((FPrevMode <> OPUS_MODE_SILK) or FPrevRedundancy) then
  begin
    for C := 0 to FChannels - 1 do
      for I := 0 to OPUS_F2_5 - 1 do
        Pcm[C][I] := RedPtrs[C][I];
    SmoothFade(RedPtrs, Pcm, Pcm, OPUS_F2_5, OPUS_F2_5, OPUS_F2_5, OPUS_F2_5);
  end;
  if Transition then
  begin
    if AudioSize >= OPUS_F5 then
    begin
      for C := 0 to FChannels - 1 do
        for I := 0 to OPUS_F2_5 - 1 do
          Pcm[C][I] := TransPtrs[C][I];
      SmoothFade(TransPtrs, Pcm, Pcm, OPUS_F2_5, OPUS_F2_5, OPUS_F2_5, OPUS_F2_5);
    end
    else
      SmoothFade(TransPtrs, Pcm, Pcm, 0, 0, 0, OPUS_F2_5);
  end;

  FPrevMode := Mode;
  FPrevRedundancy := Redundancy and (CeltToSilk = 0);
  if CeltRet < 0 then Exit(CeltRet);
  Result := AudioSize;
end;

function TOpusStreamDecoder.DecodePacket(Data: PByte; Len: Integer; out Output: TAudioBuffer): Integer;
var
  Info: TOpusPacketInfo;
  I, Total, Off, Ret: Integer;
  Ptrs: array[0..1] of PSingle;
begin
  Output := nil;
  if (Data = nil) or (Len <= 0) then Exit(0);
  if not OpusParsePacket(Data, Len, Info) then Exit(-4);
  Total := Info.NumFrames * Info.TOC.FrameSamples;
  if Total > 5760 then Exit(-4);
  FMode := Info.TOC.Mode;
  FBandwidth := Info.TOC.Bandwidth;
  FFrameSize := Info.TOC.FrameSamples;
  if Info.TOC.Stereo then FStreamChannels := 2 else FStreamChannels := 1;
  Output := AudioBufferCreate(FChannels, Total);
  Off := 0;
  for I := 0 to Info.NumFrames - 1 do
  begin
    Ptrs[0] := @Output[0][Off];
    if FChannels = 2 then Ptrs[1] := @Output[1][Off] else Ptrs[1] := Ptrs[0];
    Ret := DecodeFrame(Data + Info.FrameOffsets[I], Info.FrameSizes[I], Ptrs, Info.TOC.FrameSamples);
    if Ret < 0 then Exit(Ret);
    Inc(Off, Info.TOC.FrameSamples);
  end;
  FLastPacketDuration := Total;
  Result := Total;
end;

function TOpusStreamDecoder.DecodeLost(LostSamples: Integer; out Output: TAudioBuffer): Integer;
var
  Ptrs: array[0..1] of PSingle;
  Count, Ret: Integer;
begin
  Output := AudioBufferCreate(FChannels, LostSamples);
  Count := 0;
  while Count < LostSamples do
  begin
    Ptrs[0] := @Output[0][Count];
    if FChannels = 2 then Ptrs[1] := @Output[1][Count] else Ptrs[1] := Ptrs[0];
    Ret := DecodeFrame(nil, 0, Ptrs, LostSamples - Count);
    if Ret <= 0 then Exit(Ret);
    Inc(Count, Ret);
  end;
  Result := Count;
end;

// ---------------------------------------------------------------------------
// TOpusDecoder (Ogg Opus)
// ---------------------------------------------------------------------------

constructor TOpusDecoder.Create(AStream: TStream; OwnsStream: Boolean);
begin
  inherited Create;
  FReader      := TOggPageReader.Create(AStream, OwnsStream);
  FReady       := False;
  FHeaderCount := 0;
  FPreSkipLeft := 0;
  FGranulePos  := 0;
  FTotalOut    := 0;
  FGain        := 1.0;
  FillChar(FHead, SizeOf(FHead), 0);
  ReadHeaders;
end;

destructor TOpusDecoder.Destroy;
begin
  FStream.Free;
  FReader.Free;
  inherited Destroy;
end;

function TOpusDecoder.ParseOpusHead(const Pkt: TOggPacket): Boolean;
const
  MAGIC: array[0..7] of Byte = (79,112,117,115,72,101,97,100);  // 'OpusHead'
var
  D   : PByte;
  Len : Integer;
  I   : Integer;
begin
  Result := False;
  if Pkt.Length < 19 then Exit;
  D   := @Pkt.Data[0];
  Len := Pkt.Length;
  for I := 0 to 7 do
    if D[I] <> MAGIC[I] then Exit;
  FHead.Version := D[8];
  if (FHead.Version shr 4) <> 0 then Exit;
  FHead.Channels        := D[9];
  FHead.PreSkip         := Word(D[10]) or (Word(D[11]) shl 8);
  FHead.InputSampleRate := Cardinal(D[12]) or (Cardinal(D[13]) shl 8) or
                           (Cardinal(D[14]) shl 16) or (Cardinal(D[15]) shl 24);
  FHead.OutputGainQ8    := SmallInt(Word(D[16]) or (Word(D[17]) shl 8));
  FHead.ChannelMappingFamily := D[18];
  if FHead.Channels = 0 then Exit;
  if FHead.ChannelMappingFamily = 0 then
  begin
    if FHead.Channels > 2 then Exit;
  end
  else
  begin
    if Len < 21 + FHead.Channels then Exit;
    FHead.StreamCount  := D[19];
    FHead.CoupledCount := D[20];
    for I := 0 to FHead.Channels - 1 do
      FHead.ChannelMap[I] := D[21 + I];
    if (FHead.StreamCount <> 1) or (FHead.Channels > 2) then Exit;
  end;
  Result := True;
end;

function TOpusDecoder.ReadHeaders: Boolean;
var
  Pkt: TOggPacket;
begin
  Result := False;
  while FHeaderCount < 2 do
  begin
    if FReader.ReadPacket(Pkt) <> orrPacket then Exit;
    if FHeaderCount = 0 then
    begin
      if not ParseOpusHead(Pkt) then Exit;
      FPreSkipLeft := FHead.PreSkip;
      FStream := TOpusStreamDecoder.Create(FHead.Channels);
      if FHead.OutputGainQ8 <> 0 then
        FGain := Power(10.0, FHead.OutputGainQ8 / (20.0 * 256.0));
    end;
    Inc(FHeaderCount);
  end;
  FReady := True;
  Result := True;
end;

function TOpusDecoder.Decode(out Buffer: TAudioBuffer; out Samples: Integer): TAudioDecodeResult;
var
  Pkt    : TOggPacket;
  Res    : TOggReadResult;
  Ret    : Integer;
  Ch, I  : Integer;
  Skip   : Integer;
  Limit  : Int64;
  V      : Single;
begin
  Buffer  := nil;
  Samples := 0;
  if not FReady then Exit(adrError);
  repeat
    Res := FReader.ReadPacket(Pkt);
    if Res = orrEndOfStream then Exit(adrEndOfStream);
    if Res <> orrPacket then Exit(adrCorrupted);
    if Pkt.Length < 1 then Continue;

    Ret := FStream.DecodePacket(@Pkt.Data[0], Pkt.Length, Buffer);
    if Ret < 0 then
    begin
      Buffer := nil;
      Exit(adrCorrupted);
    end;
    Samples := Ret;
    if Samples = 0 then Continue;

    if FPreSkipLeft > 0 then
    begin
      Skip := Min(FPreSkipLeft, Samples);
      Dec(FPreSkipLeft, Skip);
      if Skip >= Samples then
      begin
        Buffer := nil;
        Samples := 0;
        Continue;
      end;
      for Ch := 0 to FHead.Channels - 1 do
        Move(Buffer[Ch][Skip], Buffer[Ch][0], (Samples - Skip) * SizeOf(Single));
      Dec(Samples, Skip);
      AudioBufferResize(Buffer, Samples);
    end;

    if Pkt.IsEOS and (Pkt.GranulePos >= 0) then
    begin
      Limit := Pkt.GranulePos - FHead.PreSkip;
      if FTotalOut + Samples > Limit then
      begin
        Samples := Integer(Max(0, Limit - FTotalOut));
        if Samples = 0 then
        begin
          Buffer := nil;
          Exit(adrEndOfStream);
        end;
        AudioBufferResize(Buffer, Samples);
      end;
    end;

    for Ch := 0 to FHead.Channels - 1 do
      for I := 0 to Samples - 1 do
      begin
        V := Buffer[Ch][I] * FGain;
        if V > 1.0 then V := 1.0
        else if V < -1.0 then V := -1.0;
        Buffer[Ch][I] := V;
      end;

    Inc(FTotalOut, Samples);
    if Pkt.GranulePos > 0 then FGranulePos := Pkt.GranulePos;
    Exit(adrOK);
  until False;
end;

end.
