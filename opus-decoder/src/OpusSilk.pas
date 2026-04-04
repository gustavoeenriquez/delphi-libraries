unit OpusSilk;

{
  OpusSilk.pas - SILK LP voice decoder

  Decodes SILK frames from the range coder bitstream.
  SILK spec reference: Appendix B of RFC 6716 / SILK source code by Skype.

  SILK uses LP (Linear Predictive) coding with:
    - VAD (Voice Activity Detection) flag per frame
    - LTP (Long-Term Prediction) for voiced speech
    - LPC (Linear Prediction Coefficients) for short-term prediction
    - Residual quantized with adaptive codebooks (pulses)
    - Bandwidth: NB=8kHz, MB=12kHz, WB=16kHz internal
    - 4 subframes of 5ms each (20ms frame)

  The SILK decoder in Opus (RFC 6716 Appendix B.1):
    1. Decode frame header (VAD, LBRR flag)
    2. If LBRR: decode loss recovery data (skip or use)
    3. Decode 4 subframe LTP parameters
    4. Decode LPC coefficients
    5. Decode quantization gain and pulse codebook
    6. Synthesize speech via LPC filter

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  SysUtils, Math,
  OpusTypes,
  OpusRangeDecoder;

// Maximum output samples for one SILK frame at 16kHz, 20ms
const
  SILK_MAX_FRAME_LENGTH = 320;  // 20ms at 16kHz
  SILK_NB_SUBFR         = 4;    // subframes per frame

type
  TSilkDecodeState = record
    // LPC synthesis filter state
    SynthBuf     : array[0..SILK_MAX_ORDER_LPC - 1] of Integer;
    // LTP state (pitch buffer)
    PitchBuf     : array[0..SILK_MAX_PITCH_LAG + SILK_MAX_FRAME_LENGTH - 1] of Integer;
    PitchBufLen  : Integer;
    // Previous frame parameters (for interpolation)
    PrevGain     : Integer;
    PrevNLSF     : array[0..SILK_MAX_ORDER_LPC - 1] of Integer;
    LPCOrder     : Integer;       // 10 (NB/MB) or 16 (WB)
    InternalFs   : Integer;       // 8000, 12000, or 16000
    FirstFrame   : Boolean;
  end;

type
  TSilkFrameHeader = record
    VAD          : Boolean;
    LBRRFlag     : Boolean;
    // Per-subframe gains (log-domain)
    Gains        : array[0..SILK_NB_SUBFR - 1] of Integer;
    // LTP parameters (per subframe for voiced)
    IsVoiced     : Boolean;
    LTPOrder     : Integer;  // 5
    LTPCoeffs    : array[0..SILK_NB_SUBFR - 1, 0..4] of Integer;  // Q13
    LTPScaleIdx  : Integer;
    PitchLag     : array[0..SILK_NB_SUBFR - 1] of Integer;
    // LPC coefficients (NLSF decoded then converted)
    LPCCoeffs    : array[0..SILK_MAX_ORDER_LPC - 1] of Integer;  // Q12
    LPCOrder     : Integer;
    // Seed for pseudo-random quantization noise
    Seed         : Cardinal;
  end;

// Initialize SILK decode state.
procedure SilkDecodeStateInit(var State: TSilkDecodeState;
  InternalFs: Integer; LPCOrder: Integer);

// Decode one SILK frame (up to 20ms).
// Rd: range decoder positioned at start of SILK frame data.
// State: persistent decoder state (updated on exit).
// Output: decoded PCM samples (integer, Q0 at 16-bit range).
// NumSamples: returns number of samples decoded.
// Returns False on decode error.
function SilkDecodeFrame(
  var Rd        : TOpusRangeDecoder;
  var State     : TSilkDecodeState;
  Output        : PSmallInt;
  out NumSamples: Integer
): Boolean;

// Convert NLSF to LPC coefficients (exposed for testing).
procedure SilkNLSFToLPC(const NLSF: array of Integer; Order: Integer;
  LPCCoeffs: PInteger);

implementation

// ---------------------------------------------------------------------------
// SILK ICDF tables (from RFC 6716 Appendix B / SILK source)
// ---------------------------------------------------------------------------

// VAD flag ICDF
const
  SILK_VAD_ICDF: array[0..1] of Byte = (230, 0);

// LBRR flag ICDF (conditional on VAD)
  SILK_LBRR_ICDF: array[0..1] of Byte = (192, 0);

// Voiced/unvoiced ICDF
  SILK_VOICED_ICDF: array[0..1] of Byte = (171, 0);

// Gain index ICDF (3-stage: MSB, mid, LSB)
  SILK_GAIN_HIGHBITS_ICDF: array[0..8] of Byte = (255, 224, 178, 132, 97, 59, 29, 8, 0);
  SILK_GAIN_LOWBITS_ICDF: array[0..3] of Byte = (192, 128, 64, 0);

// Pitch lag (coarse) ICDF — 20ms frame, WB
  SILK_PITCH_LAG_WB_ICDF: array[0..35] of Byte = (
    255, 254, 252, 249, 245, 240, 234, 227, 219, 211,
    202, 192, 182, 172, 162, 151, 141, 131, 121, 111,
    102,  93,  84,  76,  68,  60,  52,  45,  38,  31,
     25,  19,  14,   9,   5,   0
  );

// Delta pitch ICDF
  SILK_PITCH_DELTA_ICDF: array[0..20] of Byte = (
    255, 250, 231, 201, 162, 119,  81,  50,
     28,  15,   7,   3,   1,   0,   0,   0,
      0,   0,   0,   0,   0
  );

// LTP order 5 coefficients ICDF (simplified — uses CB in real SILK)
  SILK_LTP_ORDER5_ICDF: array[0..9] of Byte = (
    255, 228, 185, 134,  90,  52,  23,   8,  1,  0
  );

// NLSF interpolation coefficient ICDF
  SILK_NLSF_INTERP_ICDF: array[0..4] of Byte = (243, 212, 151, 80, 0);

// Pulse count ICDF (simplified)
  SILK_PULSES_PER_BLOCK_ICDF: array[0..16] of Byte = (
    255, 252, 244, 229, 207, 179, 147, 112,
     80,  51,  28,  13,   4,   1,   0,   0,  0
  );

// ---------------------------------------------------------------------------
// NLSF decode (simplified — full implementation uses multi-stage vector CB)
// ---------------------------------------------------------------------------

// Decode NLSF (Normalized Line Spectral Frequencies) from range decoder.
// Uses a simplified single-stage codebook approximation.
procedure SilkDecodeNLSF(var Rd: TOpusRangeDecoder;
  NLSF: PInteger; Order: Integer);
var
  I : Integer;
  V : Cardinal;
begin
  // In full SILK: 3-stage split VQ codebook; we use uniform quantization.
  for I := 0 to Order - 1 do
  begin
    // Each NLSF in Q15: [0..32767] mapped to frequency [0..pi]
    V := RdDecodeUInt(Rd, 256);  // simplified: 8-bit uniform
    NLSF[I] := Integer(V shl 7);  // scale to Q15 range [0..32512]
  end;
  // Sort to ensure monotone (NLSF must be strictly increasing)
  for I := 1 to Order - 1 do
    if NLSF[I] <= NLSF[I-1] then
      NLSF[I] := NLSF[I-1] + 1;
end;

// Convert NLSF to LPC coefficients via LSF→LPC conversion.
// Output LPCCoeffs in Q12.
procedure SilkNLSFToLPC(const NLSF: array of Integer; Order: Integer;
  LPCCoeffs: PInteger);
var
  I, J : Integer;
  P, Q : array[0..SILK_MAX_ORDER_LPC div 2] of Double;
  Fj   : Double;
begin
  // LSF to LP polynomial conversion
  // P(z) = product of (1 - 2*cos(w_2k-1)*z^-1 + z^-2)
  // Q(z) = product of (1 - 2*cos(w_2k)*z^-1 + z^-2)
  var Half := Order div 2;
  for I := 0 to Half do begin P[I] := 0; Q[I] := 0; end;
  P[0] := 1.0; Q[0] := 1.0;

  for I := 0 to Half - 1 do
  begin
    // Odd NLSF for P, Even for Q
    var OddIdx  := 2 * I;
    var EvenIdx := 2 * I + 1;
    var WP: Double := NLSF[OddIdx]  * Pi / 32768.0;
    var WQ: Double := NLSF[EvenIdx] * Pi / 32768.0;
    var CP: Double := Cos(WP) * 2.0;
    var CQ: Double := Cos(WQ) * 2.0;

    // Convolve P with (1 - CP*z^-1 + z^-2)
    for J := I + 2 downto 2 do
      P[J] := P[J] - CP * P[J-1] + P[J-2];
    P[1] := P[1] - CP * P[0];
    // Convolve Q
    for J := I + 2 downto 2 do
      Q[J] := Q[J] - CQ * Q[J-1] + Q[J-2];
    Q[1] := Q[1] - CQ * Q[0];
  end;

  // Combine P and Q to get LPC coefficients
  for I := 0 to Half - 1 do
  begin
    Fj := (P[I + 1] + Q[I + 1]) * (1.0 / 2.0);
    LPCCoeffs[I] := Round(Fj * 4096.0);          // Q12
    LPCCoeffs[Order - 1 - I] := Round((P[I + 1] - Q[I + 1]) * (1.0 / 2.0) * 4096.0);
  end;
end;

// ---------------------------------------------------------------------------
// State init
// ---------------------------------------------------------------------------

procedure SilkDecodeStateInit(var State: TSilkDecodeState;
  InternalFs: Integer; LPCOrder: Integer);
begin
  FillChar(State, SizeOf(State), 0);
  State.InternalFs := InternalFs;
  State.LPCOrder   := LPCOrder;
  State.FirstFrame := True;
  State.PitchBufLen := SILK_MAX_PITCH_LAG;
end;

// ---------------------------------------------------------------------------
// SILK frame decode
// ---------------------------------------------------------------------------

function SilkDecodeFrame(
  var Rd        : TOpusRangeDecoder;
  var State     : TSilkDecodeState;
  Output        : PSmallInt;
  out NumSamples: Integer
): Boolean;
var
  Hdr          : TSilkFrameHeader;
  I, J         : Integer;
  SubfrLen     : Integer;
  Excitation   : array[0..SILK_MAX_FRAME_LENGTH - 1] of Integer;
  LPCBuf       : array[0..SILK_MAX_FRAME_LENGTH + SILK_MAX_ORDER_LPC - 1] of Integer;
  GainQ16      : Integer;
  PulseVal     : Integer;
  LTPFilterOut : Integer;
  LPCOut       : Int64;
  SubStart     : Integer;
  PitchLag     : Integer;
  Seed         : Cardinal;
  SignBit      : Integer;
begin
  Result := False;
  FillChar(Hdr, SizeOf(Hdr), 0);

  // Frame length depends on internal sample rate and frame duration (20ms)
  case State.InternalFs of
    8000:  begin SubfrLen := 40;  Hdr.LPCOrder := 10; end;
    12000: begin SubfrLen := 60;  Hdr.LPCOrder := 12; end;
    else   begin SubfrLen := 80;  Hdr.LPCOrder := 16; end; // 16000
  end;
  NumSamples := SubfrLen * SILK_NB_SUBFR;

  // ---- 1. Frame header ----
  Hdr.VAD      := RdDecodeICDF(Rd, SILK_VAD_ICDF, 8) = 0;
  Hdr.LBRRFlag := RdDecodeICDF(Rd, SILK_LBRR_ICDF, 8) = 0;

  // LBRR: decode redundancy data (ignored for in-band decode)
  // We skip LBRR packet for simplicity (future: could use for FEC)

  // ---- 2. Subframe gains ----
  var GainBase: Integer := RdDecodeICDF(Rd, SILK_GAIN_HIGHBITS_ICDF, 8) * 4
                         + RdDecodeICDF(Rd, SILK_GAIN_LOWBITS_ICDF, 8);
  // Delta gains for subframes 1-3
  Hdr.Gains[0] := GainBase;
  for I := 1 to SILK_NB_SUBFR - 1 do
  begin
    var Delta: Integer := RdDecodeICDF(Rd, SILK_GAIN_LOWBITS_ICDF, 8) - 2;
    Hdr.Gains[I] := Max(0, Hdr.Gains[I-1] + Delta);
  end;

  // ---- 3. LTP / Pitch (voiced) ----
  Hdr.IsVoiced := Hdr.VAD and (RdDecodeICDF(Rd, SILK_VOICED_ICDF, 8) = 0);

  if Hdr.IsVoiced then
  begin
    // Decode pitch lag for first subframe
    Hdr.PitchLag[0] := RdDecodeICDF(Rd, SILK_PITCH_LAG_WB_ICDF, 8) + 2;
    // Delta lags for remaining subframes
    for I := 1 to SILK_NB_SUBFR - 1 do
    begin
      var Delta: Integer := RdDecodeICDF(Rd, SILK_PITCH_DELTA_ICDF, 8) - 9;
      Hdr.PitchLag[I] := Max(2, Hdr.PitchLag[I-1] + Delta);
    end;

    // LTP coefficients (simplified: decode one coefficient set)
    for I := 0 to SILK_NB_SUBFR - 1 do
    begin
      var CIdx: Integer := RdDecodeICDF(Rd, SILK_LTP_ORDER5_ICDF, 8);
      // Convert codebook index to coefficients (simplified: linear mapping)
      for J := 0 to 4 do
        Hdr.LTPCoeffs[I][J] := (CIdx - 5) * 256;  // rough Q13 approximation
    end;
  end;

  // ---- 4. LPC (NLSF decode) ----
  // Interpolation factor
  var InterpIdx: Integer := RdDecodeICDF(Rd, SILK_NLSF_INTERP_ICDF, 8);
  var NLSF: array[0..SILK_MAX_ORDER_LPC - 1] of Integer;
  SilkDecodeNLSF(Rd, @NLSF[0], Hdr.LPCOrder);
  SilkNLSFToLPC(NLSF, Hdr.LPCOrder, @Hdr.LPCCoeffs[0]);

  // ---- 5. Excitation / Pulses ----
  // Seed for pseudo-random generator
  Seed := RdDecodeUInt(Rd, 4);  // 2-bit seed index
  Hdr.Seed := Seed;

  FillChar(Excitation, SizeOf(Excitation), 0);
  for I := 0 to NumSamples - 1 do
  begin
    // Decode pulse count per sample (simplified)
    PulseVal := RdDecodeICDF(Rd, SILK_PULSES_PER_BLOCK_ICDF, 8) - 8;
    if PulseVal <> 0 then
    begin
      SignBit := Integer(RdDecodeBit(Rd));
      if SignBit <> 0 then PulseVal := -PulseVal;
    end;
    Excitation[I] := PulseVal;
  end;

  // ---- 6. LPC synthesis ----
  // Copy LPC history
  var Order := Hdr.LPCOrder;
  for I := 0 to Order - 1 do
    LPCBuf[I] := State.SynthBuf[I];

  for I := 0 to NumSamples - 1 do
  begin
    SubStart := I div SubfrLen;
    GainQ16 := Max(1, Hdr.Gains[SubStart]) shl 10;  // rough scaling to Q26

    // LTP prediction (voiced)
    LTPFilterOut := 0;
    if Hdr.IsVoiced then
    begin
      PitchLag := Hdr.PitchLag[SubStart];
      var PBufIdx: Integer := State.PitchBufLen - PitchLag + I;
      if PBufIdx >= 0 then
      begin
        var LTPIdx: Integer := PBufIdx;
        for J := 0 to 4 do
        begin
          if LTPIdx - J >= 0 then
            LTPFilterOut := LTPFilterOut + Hdr.LTPCoeffs[SubStart][J] * State.PitchBuf[LTPIdx - J] div 8192;
        end;
      end;
    end;

    // Excitation scaled by gain
    var Exc: Int64 := Int64(Excitation[I]) * GainQ16 div 65536 + LTPFilterOut;

    // LPC synthesis filter
    LPCOut := Exc shl 12;  // to Q12
    for J := 0 to Order - 1 do
      LPCOut := LPCOut - Int64(Hdr.LPCCoeffs[J]) * LPCBuf[Order - 1 + I - J];

    LPCBuf[Order + I] := Integer(LPCOut shr 12);

    // Update pitch buffer
    if I + State.PitchBufLen < Length(State.PitchBuf) then
      State.PitchBuf[I + State.PitchBufLen] := LPCBuf[Order + I];

    // Clamp and output
    var OutSamp: Integer := LPCBuf[Order + I];
    if OutSamp >  32767 then OutSamp :=  32767;
    if OutSamp < -32768 then OutSamp := -32768;
    Output[I] := SmallInt(OutSamp);
  end;

  // Update LPC state
  for I := 0 to Order - 1 do
    State.SynthBuf[I] := LPCBuf[NumSamples + I - Order + Order];

  // Advance pitch buffer
  for I := 0 to State.PitchBufLen - 1 do
  begin
    var Src: Integer := I + NumSamples;
    if Src < State.PitchBufLen + NumSamples then
      State.PitchBuf[I] := State.PitchBuf[Src];
  end;

  State.FirstFrame := False;
  Result := not RdHasError(Rd);
end;

end.
