unit AudioResampler;

{
  AudioResampler.pas — Polyphase FIR audio resampler

  Converts audio between arbitrary sample rates using a Kaiser-windowed
  sinc FIR filter bank with polyphase decomposition.

  Rational ratio P/Q = DstRate/GCD(Dst,Src) : SrcRate/GCD(Dst,Src).
  State between batches: FAccum tracks the fractional input position for
  the next output, encoded as (next_output_index × FQ) mod FQ (i.e. the
  residual after subtracting consumed input samples × FP). FAccum ∈ [0, FQ-1].

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  SysUtils, Math, AudioTypes;

type
  TResamplerQuality = (
    rqFast,    // Kaiser β=6,   8 taps/phase — fast; adequate for speech
    rqMedium,  // Kaiser β=8,  16 taps/phase — balanced; default
    rqHigh     // Kaiser β=10, 32 taps/phase — best quality; higher CPU cost
  );

  TAudioResampler = class
  private
    FSrcRate   : Cardinal;
    FDstRate   : Cardinal;
    FChannels  : Integer;
    FQuality   : TResamplerQuality;
    FP         : Integer;    // upsample factor  = DstRate / GCD
    FQ         : Integer;    // downsample factor = SrcRate / GCD
    FTaps      : Integer;    // taps per polyphase subfilter
    FAccum     : Integer;    // state in [0, FQ-1]; advances by FQ per output, resets by FP per input
    FCoeffs    : array of TArray<Double>;  // FCoeffs[phase][tap]
    FHistory   : TAudioBuffer;             // FHistory[ch][0..FTaps-2], newest at highest index
    FStream    : TAudioBuffer;
    FStreamLen : Integer;

    function  FGCD(A, B: Integer): Integer;
    function  BesselI0(X: Double): Double;
    procedure BuildFilter;
    function  ProcessBatch(const Input: TAudioBuffer; InLen: Integer): TAudioBuffer;
    procedure AppendToStream(const Buf: TAudioBuffer);
  public
    constructor Create(SrcRate, DstRate: Cardinal; Channels: Integer;
      Quality: TResamplerQuality = rqMedium);
    destructor Destroy; override;

    // Stateful batch resample; call repeatedly for successive chunks.
    function Resample(const Input: TAudioBuffer; FrameCount: Integer = -1): TAudioBuffer;

    // Streaming: push input frames; pull available output frames.
    procedure Push(const Input: TAudioBuffer; FrameCount: Integer = -1);
    function  Pull(MaxFrames: Integer = -1): TAudioBuffer;
    function  Available: Integer;

    property SrcRate  : Cardinal          read FSrcRate;
    property DstRate  : Cardinal          read FDstRate;
    property Channels : Integer           read FChannels;
    property Quality  : TResamplerQuality read FQuality;
    // Intro latency in output frames (FIR length / 2, from zero-padded history).
    property Latency  : Integer           read FTaps;
  end;

implementation

const
  KAISER_BETA    : array[TResamplerQuality] of Double  = (6.0,  8.0,  10.0);
  TAPS_PER_PHASE : array[TResamplerQuality] of Integer = (8,    16,    32  );

// ---------------------------------------------------------------------------

function TAudioResampler.FGCD(A, B: Integer): Integer;
var T: Integer;
begin
  while B <> 0 do begin T := B; B := A mod B; A := T; end;
  Result := A;
end;

function TAudioResampler.BesselI0(X: Double): Double;
// Modified Bessel function I0(X) via power series: Σ (x/2)^(2k) / (k!)^2
var D, DS, S: Double;
begin
  D := 1.0; DS := 1.0; S := 1.0;
  repeat
    DS := DS * (X * X) / (4.0 * D * D);
    S  := S + DS;
    D  := D + 1.0;
  until DS < S * 1E-12;
  Result := S;
end;

procedure TAudioResampler.BuildFilter;
// Builds Kaiser-windowed sinc prototype filter h[0..N-1], N = FTaps*FP,
// then decomposes it into FP polyphase subfilters FCoeffs[phase][tap].
var
  NLen : Integer;
  fc, beta, center, I0beta : Double;
  i, ph, k : Integer;
  xn, w, sa, hv, total : Double;
  h : array of Double;
begin
  NLen   := FTaps * FP;
  fc     := 0.5 / Max(FP, FQ);  // normalized cutoff; 1.0 = Nyquist
  beta   := KAISER_BETA[FQuality];
  center := (NLen - 1) * 0.5;
  I0beta := BesselI0(beta);

  SetLength(h, NLen);
  total := 0.0;
  for i := 0 to NLen - 1 do
  begin
    xn := 2.0 * i / (NLen - 1) - 1.0;            // Kaiser window parameter ∈ [-1, 1]
    w  := BesselI0(beta * Sqrt(Max(0.0, 1.0 - xn * xn))) / I0beta;
    sa := 2.0 * fc * (i - center);                // sinc argument
    if Abs(sa) < 1E-12 then
      hv := 2.0 * fc
    else
      hv := Sin(Pi * sa) / (Pi * sa) * 2.0 * fc;
    h[i] := w * hv;
    total := total + h[i];
  end;

  // Normalize so Σh[i] = FP (DC gain = FP compensates for P-fold upsampling)
  if total > 1E-15 then
    for i := 0 to NLen - 1 do
      h[i] := h[i] * FP / total;

  // Polyphase decomposition: FCoeffs[ph][k] = h[ph + k*FP]
  SetLength(FCoeffs, FP);
  for ph := 0 to FP - 1 do
  begin
    SetLength(FCoeffs[ph], FTaps);
    for k := 0 to FTaps - 1 do
      FCoeffs[ph][k] := h[ph + k * FP];
  end;
end;

function TAudioResampler.ProcessBatch(const Input: TAudioBuffer; InLen: Integer): TAudioBuffer;
// Computes OutLen output frames from InLen input frames using polyphase FIR.
// Convolution: y = Σ FCoeffs[phase][k] * x[in_pos - k], where x[<0] uses FHistory.
// After the batch: FAccum updated, FHistory updated with last FTaps-1 input samples.
var
  OutLen, Ch, ph, k, in_pos, out_pos, idx: Integer;
  acc: Double;
  accum: Int64;
begin
  SetLength(Result, FChannels);
  for Ch := 0 to FChannels - 1 do
    SetLength(Result[Ch], 0);

  if InLen <= 0 then
    Exit;

  // OutLen = count of m ≥ 0 s.t. (FAccum + m*FQ) div FP ≤ InLen-1
  if Int64(FP) * InLen - 1 < FAccum then
    OutLen := 0
  else
    OutLen := Integer((Int64(FP) * InLen - 1 - FAccum) div FQ) + 1;

  for Ch := 0 to FChannels - 1 do
    SetLength(Result[Ch], OutLen);

  accum := FAccum;

  for out_pos := 0 to OutLen - 1 do
  begin
    in_pos := Integer(accum div FP);  // integer input position, 0..InLen-1
    ph     := Integer(accum mod FP);  // polyphase subfilter index, 0..FP-1

    for Ch := 0 to FChannels - 1 do
    begin
      acc := 0.0;
      for k := 0 to FTaps - 1 do
      begin
        idx := in_pos - k;
        if idx < 0 then
          acc := acc + FCoeffs[ph][k] * FHistory[Ch][idx + FTaps - 1]
        else
          acc := acc + FCoeffs[ph][k] * Input[Ch][idx];
      end;
      // Clamp to prevent slight FIR overshoot from exceeding [-1, 1]
      if acc > 1.0 then acc := 1.0
      else if acc < -1.0 then acc := -1.0;
      Result[Ch][out_pos] := Single(acc);
    end;

    accum := accum + FQ;
  end;

  // FAccum_new = FAccum + OutLen*FQ - InLen*FP, always in [0, FQ-1]
  FAccum := Integer(accum - Int64(InLen) * FP);

  // Update history: keep the last FTaps-1 samples of Input
  if InLen >= FTaps - 1 then
  begin
    for Ch := 0 to FChannels - 1 do
      for k := 0 to FTaps - 2 do
        FHistory[Ch][k] := Input[Ch][InLen - (FTaps - 1) + k];
  end
  else
  begin
    // Short batch: shift older history down, append new input at the tail
    for Ch := 0 to FChannels - 1 do
    begin
      for k := 0 to FTaps - 2 - InLen do
        FHistory[Ch][k] := FHistory[Ch][k + InLen];
      for k := 0 to InLen - 1 do
        FHistory[Ch][FTaps - 1 - InLen + k] := Input[Ch][k];
    end;
  end;
end;

procedure TAudioResampler.AppendToStream(const Buf: TAudioBuffer);
var
  Ch, N, OldLen: Integer;
begin
  if (Length(Buf) = 0) or (Length(Buf[0]) = 0) then Exit;
  N := Length(Buf[0]);
  OldLen := FStreamLen;
  FStreamLen := OldLen + N;
  for Ch := 0 to FChannels - 1 do
  begin
    SetLength(FStream[Ch], FStreamLen);
    Move(Buf[Ch][0], FStream[Ch][OldLen], N * SizeOf(Single));
  end;
end;

// ---------------------------------------------------------------------------

constructor TAudioResampler.Create(SrcRate, DstRate: Cardinal; Channels: Integer;
  Quality: TResamplerQuality);
var
  G, Ch: Integer;
begin
  inherited Create;
  FSrcRate  := SrcRate;
  FDstRate  := DstRate;
  FChannels := Channels;
  FQuality  := Quality;

  G      := FGCD(Integer(DstRate), Integer(SrcRate));
  FP     := Integer(DstRate) div G;
  FQ     := Integer(SrcRate) div G;
  FTaps  := TAPS_PER_PHASE[Quality];
  FAccum := 0;

  // History initialized to zero (causes intro latency of ≈ FTaps/2 output frames)
  SetLength(FHistory, Channels);
  for Ch := 0 to Channels - 1 do
    SetLength(FHistory[Ch], FTaps - 1);

  SetLength(FStream, Channels);
  for Ch := 0 to Channels - 1 do
    SetLength(FStream[Ch], 0);
  FStreamLen := 0;

  BuildFilter;
end;

destructor TAudioResampler.Destroy;
begin
  inherited;
end;

function TAudioResampler.Resample(const Input: TAudioBuffer; FrameCount: Integer): TAudioBuffer;
var
  InLen: Integer;
begin
  if (Length(Input) = 0) or (Length(Input[0]) = 0) then
  begin
    SetLength(Result, FChannels);
    Exit;
  end;
  if FrameCount < 0 then
    InLen := Length(Input[0])
  else
    InLen := FrameCount;
  Result := ProcessBatch(Input, InLen);
end;

procedure TAudioResampler.Push(const Input: TAudioBuffer; FrameCount: Integer);
var
  InLen: Integer;
begin
  if (Length(Input) = 0) or (Length(Input[0]) = 0) then Exit;
  if FrameCount < 0 then
    InLen := Length(Input[0])
  else
    InLen := FrameCount;
  AppendToStream(ProcessBatch(Input, InLen));
end;

function TAudioResampler.Pull(MaxFrames: Integer): TAudioBuffer;
var
  OutFrames, Ch, Remaining: Integer;
begin
  if MaxFrames < 0 then
    OutFrames := FStreamLen
  else
    OutFrames := Min(MaxFrames, FStreamLen);

  SetLength(Result, FChannels);
  for Ch := 0 to FChannels - 1 do
  begin
    SetLength(Result[Ch], OutFrames);
    if OutFrames > 0 then
      Move(FStream[Ch][0], Result[Ch][0], OutFrames * SizeOf(Single));
  end;

  Remaining := FStreamLen - OutFrames;
  for Ch := 0 to FChannels - 1 do
  begin
    if Remaining > 0 then
      Move(FStream[Ch][OutFrames], FStream[Ch][0], Remaining * SizeOf(Single));
    SetLength(FStream[Ch], Remaining);
  end;
  FStreamLen := Remaining;
end;

function TAudioResampler.Available: Integer;
begin
  Result := FStreamLen;
end;

end.
