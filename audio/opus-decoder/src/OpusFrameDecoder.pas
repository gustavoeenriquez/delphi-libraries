unit OpusFrameDecoder;

{
  OpusFrameDecoder.pas - Single Opus frame decode dispatcher

  Dispatches one Opus frame to the appropriate backend:
    - SILK-only  (configs 0-11):  SILK decoder
    - Hybrid     (configs 12-15): SILK (LP part) + CELT (HP part) summed
    - CELT-only  (configs 16-31): CELT decoder

  RFC 6716 sections 4.2 (SILK), 4.3 (CELT), 4.4 (frame assembly).

  Output is always 48kHz PCM in TAudioBuffer format (planar float [-1..1]).
  SILK frames are decoded at internal rate then up-sampled to 48kHz via
  a simple linear interpolation (proper polyphase resampler is future work).

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  SysUtils, Math,
  AudioTypes,
  OpusTypes,
  OpusRangeDecoder,
  OpusSilk,
  OpusCelt;

type
  TOpusFrameDecoderState = record
    Silk      : TSilkDecodeState;
    Celt      : TCeltDecodeState;
    Channels  : Integer;
    InternalFs: Integer;
    // Resampler state (trivial linear interpolation)
    ResampPhase : array[0..1] of Single;  // per channel
    PrevSample  : array[0..1] of Single;
  end;

// Initialize frame decoder state.
procedure OpusFrameDecoderInit(var State: TOpusFrameDecoderState;
  Channels: Integer; Config: Integer);

// Decode one Opus frame from raw bytes (single frame, no TOC).
// FrameData: pointer to frame bytes (after TOC has been stripped).
// FrameLen: byte count of this frame.
// TOC: the parsed TOC byte for this packet.
// Output: pre-allocated TAudioBuffer with Channels × FrameSamples.
// Returns False on error.
function OpusDecodeFrame(
  var State    : TOpusFrameDecoderState;
  const TOC    : TOpusTOC;
  FrameData    : PByte;
  FrameLen     : Integer;
  const Output : TAudioBuffer;
  FrameSamples : Integer
): Boolean;

implementation

// ---------------------------------------------------------------------------
// Linear resampler: upscale from InFs to 48000
// ---------------------------------------------------------------------------

procedure LinearResample(
  const Input   : PSmallInt;
  InputCount    : Integer;
  InputRate     : Integer;
  Output        : PSingle;
  OutputCount   : Integer;
  var Phase     : Single;
  var Prev      : Single
);
var
  I       : Integer;
  InPos   : Single;
  InIdx   : Integer;
  Frac    : Single;
  CurSamp : Single;
begin
  if InputCount = 0 then
  begin
    for I := 0 to OutputCount - 1 do Output[I] := 0.0;
    Exit;
  end;

  var InStep: Single := InputRate / OPUS_SAMPLE_RATE;

  InPos := Phase;
  for I := 0 to OutputCount - 1 do
  begin
    InIdx := Trunc(InPos);
    Frac  := InPos - InIdx;

    var S0: Single := Prev;
    if InIdx >= 0 then S0 := Input[Min(InIdx, InputCount - 1)] / 32768.0;
    var S1: Single := Input[Min(InIdx + 1, InputCount - 1)] / 32768.0;
    Output[I] := S0 + (S1 - S0) * Frac;

    InPos := InPos + InStep;
  end;

  // Update state
  InIdx := Trunc(InPos);
  Phase := InPos - InIdx;
  if InIdx < InputCount then
    Prev := Input[InIdx] / 32768.0
  else
    Prev := Input[InputCount - 1] / 32768.0;
end;

// ---------------------------------------------------------------------------
// State init
// ---------------------------------------------------------------------------

procedure OpusFrameDecoderInit(var State: TOpusFrameDecoderState;
  Channels: Integer; Config: Integer);
var
  LPCOrder: Integer;
begin
  FillChar(State, SizeOf(State), 0);
  State.Channels   := Channels;
  State.InternalFs := OpusInternalSampleRate(Config);

  // LPC order depends on internal bandwidth
  if State.InternalFs <= 8000 then
    LPCOrder := 10
  else if State.InternalFs <= 12000 then
    LPCOrder := 12
  else
    LPCOrder := 16;

  if OPUS_CONFIG_MODE[Config] <> OPUS_MODE_CELT then
    SilkDecodeStateInit(State.Silk, State.InternalFs, LPCOrder);

  if OPUS_CONFIG_MODE[Config] <> OPUS_MODE_SILK then
    CeltDecodeStateInit(State.Celt, Channels);
end;

// ---------------------------------------------------------------------------
// Single frame decode
// ---------------------------------------------------------------------------

function OpusDecodeFrame(
  var State    : TOpusFrameDecoderState;
  const TOC    : TOpusTOC;
  FrameData    : PByte;
  FrameLen     : Integer;
  const Output : TAudioBuffer;
  FrameSamples : Integer
): Boolean;
var
  Rd          : TOpusRangeDecoder;
  Ch          : Integer;
  I           : Integer;
  SilkPCM     : array[0..1, 0..SILK_MAX_FRAME_LENGTH - 1] of SmallInt;
  SilkSamples : Integer;
  CeltOutput  : TArray<TArray<Single>>;
  CeltSamples : Integer;
begin
  Result := False;

  if FrameLen <= 0 then
  begin
    // Packet loss concealment: output silence
    for Ch := 0 to State.Channels - 1 do
      for I := 0 to FrameSamples - 1 do
        Output[Ch][I] := 0.0;
    Exit(True);
  end;

  RdInit(Rd, FrameData, FrameLen);

  // ---- SILK-only ----
  if TOC.Mode = OPUS_MODE_SILK then
  begin
    // Decode mono; if stereo, decode second channel with same parameters
    SilkSamples := 0;
    if not SilkDecodeFrame(Rd, State.Silk, @SilkPCM[0][0], SilkSamples) then
      Exit;

    // Resample to 48kHz and convert to float
    for Ch := 0 to State.Channels - 1 do
    begin
      var InCh: Integer := Min(Ch, 0);  // mono SILK: always use ch 0
      LinearResample(@SilkPCM[InCh][0], SilkSamples, State.InternalFs,
        @Output[Ch][0], FrameSamples,
        State.ResampPhase[Ch], State.PrevSample[Ch]);
    end;
    Result := True;
    Exit;
  end;

  // ---- CELT-only ----
  if TOC.Mode = OPUS_MODE_CELT then
  begin
    CeltSamples := FrameSamples;
    SetLength(CeltOutput, State.Channels);
    for Ch := 0 to State.Channels - 1 do
    begin
      SetLength(CeltOutput[Ch], CeltSamples);
      FillChar(CeltOutput[Ch][0], CeltSamples * SizeOf(Single), 0);
    end;

    if not CeltDecodeFrame(Rd, State.Celt, State.Channels,
      CeltSamples, CeltOutput) then Exit;

    for Ch := 0 to State.Channels - 1 do
      Move(CeltOutput[Ch][0], Output[Ch][0], CeltSamples * SizeOf(Single));

    Result := True;
    Exit;
  end;

  // ---- Hybrid: SILK (LP 0-8kHz) + CELT (HP 8-20kHz) ----
  if TOC.Mode = OPUS_MODE_HYBRID then
  begin
    // SILK decode for low-frequency part
    SilkSamples := 0;
    if not SilkDecodeFrame(Rd, State.Silk, @SilkPCM[0][0], SilkSamples) then
      Exit;

    // CELT decode for high-frequency part
    CeltSamples := FrameSamples;
    SetLength(CeltOutput, State.Channels);
    for Ch := 0 to State.Channels - 1 do
    begin
      SetLength(CeltOutput[Ch], CeltSamples);
      FillChar(CeltOutput[Ch][0], CeltSamples * SizeOf(Single), 0);
    end;

    if not CeltDecodeFrame(Rd, State.Celt, State.Channels,
      CeltSamples, CeltOutput) then Exit;

    // Mix: resample SILK to 48kHz and add CELT
    for Ch := 0 to State.Channels - 1 do
    begin
      var SilkFloat: TArray<Single>;
      SetLength(SilkFloat, FrameSamples);
      LinearResample(@SilkPCM[0][0], SilkSamples, State.InternalFs,
        @SilkFloat[0], FrameSamples,
        State.ResampPhase[Ch], State.PrevSample[Ch]);

      for I := 0 to FrameSamples - 1 do
      begin
        var S: Single := SilkFloat[I] + CeltOutput[Ch][I];
        if S >  1.0 then S :=  1.0;
        if S < -1.0 then S := -1.0;
        Output[Ch][I] := S;
      end;
    end;

    Result := True;
  end;
end;

end.
