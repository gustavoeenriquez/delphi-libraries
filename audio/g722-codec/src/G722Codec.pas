unit G722Codec;

{
  G722Codec.pas - ITU-T G.722 (SB-ADPCM, 7 kHz audio at 64/56/48 kbit/s)

  Implemented from the text of Recommendation ITU-T G.722 (09/2012):
  transmit/receive QMF (24 taps) and the two ADPCM sub-band coders
  (lower band 6 bits, higher band 2 bits), using the block names of the
  Recommendation (SUBTRA, QUANTL, INVQAL, LOGSCL, SCALEL, UPPOL1/2,
  UPZERO, FILTEP, FILTEZ, PREDIC, QUANTH, INVQAH, LOGSCH, SCALEH, INVQBL,
  LIMIT). Bit-exact against the ITU-T test sequences (see README).

  - Input/output: 16 kHz linear PCM, int16.
  - One octet per pair of input samples: bits 7..6 = I_H, bits 5..0 = I_L.
  - Modes 2 and 3 (56/48 kbit/s) differ only in the decoder, which ignores
    1 or 2 LSBs of I_L (they carry auxiliary data); the encoder clears
    them in those modes.
  - Every instance keeps its own state; instances are independent.
  - Packet loss concealment (TG722Decoder.Conceal, or Decode with Data = nil):
    the G.722 PLC appendices are informative and their text is not used here.
    Own design with well-known techniques: pitch-synchronous waveform
    substitution on the 16 kHz output (one, then two, then three pitch
    periods, with overlap-add when the period count changes; 20 % attenuation
    per 10 ms after the first 10 ms, silence after 60 ms), re-encoding of the
    first 10 ms of the concealed signal with an encoder that starts from the
    decoder state (22 samples ahead of the output: the QMF delay) so that the
    ADPCM predictors and scale factors follow it, and a cross-fade from the
    concealment into the first good packet.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils;

type
  TG722Mode = (g722m64, g722m56, g722m48);

  // State of one ADPCM sub-band (lower or higher band)
  TG722Band = record
    S: Integer;                    // signal estimate (SL / SH)
    SZ: Integer;                   // zero-section estimate
    NB: Integer;                   // log scale factor (NBL / NBH)
    DET: Integer;                  // scale factor (DETL / DETH)
    R: array[1..2] of Integer;     // reconstructed signal, delayed
    P: array[1..2] of Integer;     // partial reconstructed signal, delayed
    A: array[1..2] of Integer;     // pole predictor coefficients
    D: array[1..6] of Integer;     // quantized difference signal, delayed
    B: array[1..6] of Integer;     // zero predictor coefficients
  end;

  TG722Encoder = class
  private
    FMode: TG722Mode;
    FLow, FHigh: TG722Band;
    FX: array[0..23] of Integer;   // transmit QMF delay line
    FPending: SmallInt;            // odd sample left over from the previous call
    FHasPending: Boolean;
    function EncodePair(X0, X1: Integer): Byte;
  public
    constructor Create(Mode: TG722Mode = g722m64);
    procedure Reset;
    // Encodes N samples (16 kHz) and writes (N + pending) div 2 octets to Output.
    // An odd sample is kept for the next call. Returns the number of octets.
    function Encode(PCM: PSmallInt; N: Integer; Output: PByte): Integer; overload;
    function Encode(const PCM: array of SmallInt): TBytes; overload;
    // Sub-band coder without the QMF (G.722 Appendix II test configuration):
    // XL, XH are the 15-bit sub-band signals; returns I_H shl 6 or I_L.
    function EncodeSubbands(XL, XH: Integer): Byte;
    procedure ResetSubbands;
    property Mode: TG722Mode read FMode write FMode;
  end;

  TG722Decoder = class
  private
    FMode: TG722Mode;
    FLow, FHigh: TG722Band;
    FX: array[0..23] of Integer;   // receive QMF delay line
    // packet loss concealment
    FHist: array[0..1023] of SmallInt;          // last output samples, oldest first
    FLost: Integer;                             // samples concealed in this erasure
    FPitch: Integer;
    FPitchBuf: array[0..3 * 288 - 1] of Double; // last three periods before the loss
    FPeriods: Integer;                          // periods being repeated (1..3)
    FPos: Integer;                              // read position inside them
    FFadePos, FFadeLen, FFadePeriods: Integer;  // overlap-add when FPeriods changes
    FShadow: TG722Encoder;                      // re-encodes the concealed signal
    // the ADPCM state runs 22 samples (QMF delay) ahead of the output: the
    // concealment is generated 22 samples in advance and the shadow encoder
    // consumes it at that point
    FAhead: array[0..21] of SmallInt;
    FAheadPos, FAheadLeft: Integer;
    procedure DecodeCore(Data: PByte; Len: Integer; Output: PSmallInt);
    procedure PushHistory(P: PSmallInt; N: Integer);
    function EstimatePitch: Integer;
    function PeriodicSample(APeriods, APos: Integer): Double;
    function NextConcealSample: Double;
    function GenerateSample: SmallInt;
    function NextOutputSample: SmallInt;
    procedure StartErasure;
    procedure ResyncAdpcm(P: PSmallInt; N: Integer);
  public
    constructor Create(Mode: TG722Mode = g722m64);
    destructor Destroy; override;
    procedure Reset;
    // Decodes Len octets into 2*Len samples (16 kHz). Returns the sample count.
    // Data = nil: the packet of Len octets was lost; 2*Len samples are concealed.
    function Decode(Data: PByte; Len: Integer; Output: PSmallInt): Integer; overload;
    // Conceals N lost samples (N even; 320 for a 20 ms packet). Returns N.
    function Conceal(Output: PSmallInt; N: Integer): Integer;
    function Decode(const Data: array of Byte): TArray<SmallInt>; overload;
    // Sub-band decoder without the QMF (G.722 Appendix II test configuration):
    // returns the reconstructed lower and higher band signals RL and RH.
    procedure DecodeSubbands(Code: Byte; out RL, RH: Integer);
    procedure ResetSubbands;
    property Mode: TG722Mode read FMode write FMode;
  end;

const
  G722_SAMPLE_RATE = 16000;
  // RFC 3551: the RTP clock rate of G.722 is 8000 although audio is 16 kHz
  G722_RTP_CLOCK_RATE = 8000;

implementation

uses
  Math;

const
  // QMF coefficients h(0)..h(23) (symmetric, Table 2/G.722)
  QMF_H: array[0..23] of Integer = (
    3, -11, -11, 53, 12, -156, 32, 362, -210, -805, 951, 3876,
    3876, 951, -805, -210, 362, 32, -156, 12, 53, -11, -11, 3);

  // QUANTL decision levels Q6(i) (Table 6/G.722), index 1..29
  Q6: array[0..30] of Integer = (
    0, 35, 72, 110, 150, 190, 233, 276, 323, 370, 422, 473, 530, 587, 650,
    714, 786, 858, 940, 1023, 1121, 1219, 1339, 1458, 1612, 1765, 1980,
    2195, 2557, 2919, 0);
  // QUANTL output codes for negative / positive EL by interval
  ILN: array[0..30] of Integer = (
    0, 63, 62, 31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17,
    16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4);
  ILP: array[0..30] of Integer = (
    0, 61, 60, 59, 58, 57, 56, 55, 54, 53, 52, 51, 50, 49, 48, 47, 46, 45,
    44, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 32);

  // Inverse quantizer outputs QQ6/QQ5/QQ4 (scaled by 8) indexed by the code
  QM6: array[0..63] of Integer = (
    -136, -136, -136, -136, -24808, -21904, -19008, -16704, -14984, -13512,
    -12280, -11192, -10232, -9360, -8576, -7856, -7192, -6576, -6000, -5456,
    -4944, -4464, -4008, -3576, -3168, -2776, -2400, -2032, -1688, -1360,
    -1040, -728, 24808, 21904, 19008, 16704, 14984, 13512, 12280, 11192,
    10232, 9360, 8576, 7856, 7192, 6576, 6000, 5456, 4944, 4464, 4008, 3576,
    3168, 2776, 2400, 2032, 1688, 1360, 1040, 728, 432, 136, -432, -136);
  QM5: array[0..31] of Integer = (
    -280, -280, -23352, -17560, -14120, -11664, -9752, -8184, -6864, -5712,
    -4696, -3784, -2960, -2208, -1520, -880, 23352, 17560, 14120, 11664,
    9752, 8184, 6864, 5712, 4696, 3784, 2960, 2208, 1520, 880, 280, -280);
  QM4: array[0..15] of Integer = (
    0, -20456, -12896, -8968, -6288, -4240, -2584, -1200,
    20456, 12896, 8968, 6288, 4240, 2584, 1200, 0);
  QM2: array[0..3] of Integer = (-7408, -1616, 7408, 1616);

  // LOGSCL: 4-bit code -> RIL index, and log scale factor multipliers WL
  RL42: array[0..15] of Integer = (0, 7, 6, 5, 4, 3, 2, 1, 7, 6, 5, 4, 3, 2, 1, 0);
  WL: array[0..7] of Integer = (-60, -30, 58, 172, 334, 538, 1198, 3042);
  // LOGSCH
  RH2: array[0..3] of Integer = (2, 1, 2, 1);
  WH: array[0..2] of Integer = (0, -214, 798);
  // QUANTH codes for negative / positive EH
  IHN: array[1..2] of Integer = (1, 0);
  IHP: array[1..2] of Integer = (3, 2);

  // SCALEL/SCALEH: inverse log base 2 table ILB
  ILB: array[0..31] of Integer = (
    2048, 2093, 2139, 2186, 2233, 2282, 2332, 2383, 2435, 2489, 2543, 2599,
    2656, 2714, 2774, 2834, 2896, 2960, 3025, 3091, 3158, 3228, 3298, 3371,
    3444, 3520, 3597, 3676, 3756, 3838, 3922, 4008);

// Arithmetic right shift (Delphi's shr is logical)
function Sar(X: Integer; N: Integer): Integer; inline;
begin
  if X >= 0 then Result := X shr N
  else Result := not ((not X) shr N);
end;

function Sat16(X: Integer): Integer; inline;
begin
  if X > 32767 then Result := 32767
  else if X < -32768 then Result := -32768
  else Result := X;
end;

function Clamp(X, Lo, Hi: Integer): Integer; inline;
begin
  if X < Lo then Result := Lo
  else if X > Hi then Result := Hi
  else Result := X;
end;

procedure BandReset(var Bd: TG722Band; Det: Integer);
begin
  FillChar(Bd, SizeOf(Bd), 0);
  Bd.DET := Det;
end;

// LOGSCL / LOGSCH followed by SCALEL / SCALEH
procedure UpdateScale(var Bd: TG722Band; W, NBMax, Shift: Integer);
var
  NB, WD1, WD2: Integer;
begin
  NB := Clamp(Sar(Bd.NB * 127, 7) + W, 0, NBMax);
  Bd.NB := NB;
  WD1 := Sar(NB, 6) and 31;
  WD2 := Shift - Sar(NB, 11);
  if WD2 < 0 then Bd.DET := (ILB[WD1] shl (-WD2)) shl 2
  else Bd.DET := Sar(ILB[WD1], WD2) shl 2;
end;

// Block 4: RECONS, PARREC, UPPOL2, UPPOL1, UPZERO, DELAYA, FILTEP, FILTEZ, PREDIC
procedure AdaptPredictor(var Bd: TG722Band; DLT: Integer);
var
  R0, P0, AP1, AP2, WD1, WD2, WD3, SP, SZ, I: Integer;
  BP: array[1..6] of Integer;
  SG0, SG1, SG2: Boolean;
begin
  // RECONS / PARREC
  R0 := Sat16(Bd.S + DLT);
  P0 := Sat16(Bd.SZ + DLT);

  // UPPOL2
  SG0 := P0 < 0;
  SG1 := Bd.P[1] < 0;
  SG2 := Bd.P[2] < 0;
  WD1 := Sat16(Bd.A[1] * 4);
  if SG0 = SG1 then WD2 := -WD1 else WD2 := WD1;
  if WD2 > 32767 then WD2 := 32767;
  if SG0 = SG2 then WD3 := 128 else WD3 := -128;
  AP2 := Clamp(Sar(WD2, 7) + WD3 + Sar(Bd.A[2] * 32512, 15), -12288, 12288);

  // UPPOL1
  if SG0 = SG1 then WD1 := 192 else WD1 := -192;
  AP1 := Sat16(WD1 + Sar(Bd.A[1] * 32640, 15));
  WD3 := 15360 - AP2;
  AP1 := Clamp(AP1, -WD3, WD3);

  // UPZERO
  if DLT = 0 then WD1 := 0 else WD1 := 128;
  SG0 := DLT < 0;
  for I := 1 to 6 do
  begin
    if (Bd.D[I] < 0) = SG0 then WD2 := WD1 else WD2 := -WD1;
    BP[I] := Sat16(WD2 + Sar(Bd.B[I] * 32640, 15));
  end;

  // DELAYA
  for I := 6 downto 2 do Bd.D[I] := Bd.D[I - 1];
  Bd.D[1] := DLT;
  for I := 1 to 6 do Bd.B[I] := BP[I];
  Bd.R[2] := Bd.R[1]; Bd.R[1] := R0;
  Bd.P[2] := Bd.P[1]; Bd.P[1] := P0;
  Bd.A[1] := AP1; Bd.A[2] := AP2;

  // FILTEP
  SP := Sat16(Sar(Bd.A[1] * Sat16(Bd.R[1] + Bd.R[1]), 15) +
              Sar(Bd.A[2] * Sat16(Bd.R[2] + Bd.R[2]), 15));
  // FILTEZ
  SZ := 0;
  for I := 6 downto 1 do
    SZ := Sat16(SZ + Sar(Bd.B[I] * Sat16(Bd.D[I] + Bd.D[I]), 15));
  Bd.SZ := SZ;
  // PREDIC
  Bd.S := Sat16(SP + SZ);
end;

{ TG722Encoder }

constructor TG722Encoder.Create(Mode: TG722Mode);
begin
  inherited Create;
  FMode := Mode;
  Reset;
end;

procedure TG722Encoder.Reset;
begin
  ResetSubbands;
  FillChar(FX, SizeOf(FX), 0);
  FHasPending := False;
end;

procedure TG722Encoder.ResetSubbands;
begin
  BandReset(FLow, 32);
  BandReset(FHigh, 8);
end;

function TG722Encoder.EncodePair(X0, X1: Integer): Byte;
var
  I, SumA, SumB: Integer;
begin
  // Transmit QMF: X0 is the earlier sample of the pair
  Move(FX[2], FX[0], 22 * SizeOf(Integer));
  FX[22] := X0;
  FX[23] := X1;
  SumA := 0; SumB := 0;
  for I := 0 to 11 do
  begin
    SumA := SumA + QMF_H[2 * I] * FX[23 - 2 * I];
    SumB := SumB + QMF_H[2 * I + 1] * FX[22 - 2 * I];
  end;
  Result := EncodeSubbands(Sat16(Sar(SumA + SumB, 14)), Sat16(Sar(SumA - SumB, 14)));
end;

function TG722Encoder.EncodeSubbands(XL, XH: Integer): Byte;
var
  I, EL, EH, WD, IL, IH, RIL, DLT: Integer;
begin
  // Lower band: SUBTRA, QUANTL
  EL := Sat16(XL - FLow.S);
  if EL >= 0 then WD := EL else WD := -(EL + 1);
  I := 1;
  while (I < 30) and (WD >= Sar(Q6[I] * FLow.DET, 12)) do Inc(I);
  if EL < 0 then IL := ILN[I] else IL := ILP[I];
  // INVQAL (4-bit core), LOGSCL, SCALEL, predictor
  RIL := IL shr 2;
  DLT := Sar(FLow.DET * QM4[RIL], 15);
  UpdateScale(FLow, WL[RL42[RIL]], 18432, 8);
  AdaptPredictor(FLow, DLT);

  // Higher band: SUBTRA, QUANTH
  EH := Sat16(XH - FHigh.S);
  if EH >= 0 then WD := EH else WD := -(EH + 1);
  if WD >= Sar(564 * FHigh.DET, 12) then I := 2 else I := 1;
  if EH < 0 then IH := IHN[I] else IH := IHP[I];
  // INVQAH, LOGSCH, SCALEH, predictor
  DLT := Sar(FHigh.DET * QM2[IH], 15);
  UpdateScale(FHigh, WH[RH2[IH]], 22528, 10);
  AdaptPredictor(FHigh, DLT);

  case FMode of
    g722m56: IL := IL and not 1;
    g722m48: IL := IL and not 3;
  end;
  Result := Byte((IH shl 6) or IL);
end;

function TG722Encoder.Encode(PCM: PSmallInt; N: Integer; Output: PByte): Integer;
var
  I: Integer;
begin
  Result := 0;
  I := 0;
  if FHasPending and (N > 0) then
  begin
    Output^ := EncodePair(FPending, PCM^);
    Inc(Output); Inc(Result);
    FHasPending := False;
    I := 1;
  end;
  while I + 1 < N do
  begin
    Output^ := EncodePair(PSmallInt(PByte(PCM) + I * 2)^, PSmallInt(PByte(PCM) + (I + 1) * 2)^);
    Inc(Output); Inc(Result);
    Inc(I, 2);
  end;
  if I < N then
  begin
    FPending := PSmallInt(PByte(PCM) + I * 2)^;
    FHasPending := True;
  end;
end;

function TG722Encoder.Encode(const PCM: array of SmallInt): TBytes;
var
  N: Integer;
begin
  SetLength(Result, (Length(PCM) + Ord(FHasPending)) div 2);
  if Length(PCM) = 0 then Exit;
  N := Encode(@PCM[0], Length(PCM), PByte(Result));
  SetLength(Result, N);
end;

{ TG722Decoder }

constructor TG722Decoder.Create(Mode: TG722Mode);
begin
  inherited Create;
  FMode := Mode;
  FShadow := TG722Encoder.Create(Mode);
  Reset;
end;

destructor TG722Decoder.Destroy;
begin
  FShadow.Free;
  inherited;
end;

procedure TG722Decoder.Reset;
begin
  ResetSubbands;
  FillChar(FX, SizeOf(FX), 0);
  FillChar(FHist, SizeOf(FHist), 0);
  FLost := 0;
  FPitch := 0;
  FPeriods := 1;
  FPos := 0;
  FFadeLen := 0;
end;

procedure TG722Decoder.ResetSubbands;
begin
  BandReset(FLow, 32);
  BandReset(FHigh, 8);
end;

procedure TG722Decoder.DecodeSubbands(Code: Byte; out RL, RH: Integer);
var
  IL, IH, RIL, WD, DLT: Integer;
begin
  IL := Code and $3F;
  IH := Code shr 6;

  // Lower band: INVQBL (mode dependent), RECONS, LIMIT
  case FMode of
    g722m56: WD := QM5[IL shr 1];
    g722m48: WD := QM4[IL shr 2];
  else
    WD := QM6[IL];
  end;
  RL := Clamp(FLow.S + Sar(FLow.DET * WD, 15), -16384, 16383);
  // INVQAL, LOGSCL, SCALEL, predictor (always the 4-bit core)
  RIL := IL shr 2;
  DLT := Sar(FLow.DET * QM4[RIL], 15);
  UpdateScale(FLow, WL[RL42[RIL]], 18432, 8);
  AdaptPredictor(FLow, DLT);

  // Higher band: INVQAH, RECONS, LIMIT
  DLT := Sar(FHigh.DET * QM2[IH], 15);
  RH := Clamp(FHigh.S + DLT, -16384, 16383);
  UpdateScale(FHigh, WH[RH2[IH]], 22528, 10);
  AdaptPredictor(FHigh, DLT);
end;

procedure TG722Decoder.DecodeCore(Data: PByte; Len: Integer; Output: PSmallInt);
var
  K, I, RL, RH, Sum0, Sum1: Integer;
begin
  for K := 0 to Len - 1 do
  begin
    DecodeSubbands(Data^, RL, RH);
    Inc(Data);

    // Receive QMF
    Move(FX[2], FX[0], 22 * SizeOf(Integer));
    FX[22] := RL + RH;
    FX[23] := RL - RH;
    Sum0 := 0; Sum1 := 0;
    for I := 0 to 11 do
    begin
      Sum0 := Sum0 + QMF_H[2 * I] * FX[23 - 2 * I];
      Sum1 := Sum1 + QMF_H[2 * I + 1] * FX[22 - 2 * I];
    end;
    Output^ := Sat16(Sar(Sum0, 11));
    Inc(Output);
    Output^ := Sat16(Sar(Sum1, 11));
    Inc(Output);
  end;
end;

function TG722Decoder.Decode(Data: PByte; Len: Integer; Output: PSmallInt): Integer;
var
  N, R, I: Integer;
  W: Double;
  P: PSmallInt;
begin
  Result := 2 * Len;
  if Len <= 0 then Exit(0);
  if Data = nil then
    Exit(Conceal(Output, 2 * Len));
  DecodeCore(Data, Len, Output);
  if FLost > 0 then
  begin
    // first packet after a loss: cross-fade from the continued concealment
    // (4 ms, plus 2 ms per 10 ms lost, up to 10 ms)
    R := Min(64 + 32 * (FLost div 160), 160);
    R := Min(R, 2 * Len);
    P := Output;
    for I := 0 to R - 1 do
    begin
      W := (I + 1) / (R + 1);
      N := Round(W * P^ + (1 - W) * NextOutputSample);
      P^ := SmallInt(EnsureRange(N, -32768, 32767));
      Inc(P);
    end;
    FLost := 0;
  end;
  PushHistory(Output, 2 * Len);
end;

{ --- packet loss concealment --- }

procedure TG722Decoder.PushHistory(P: PSmallInt; N: Integer);
var
  K: Integer;
begin
  if N >= Length(FHist) then
  begin
    Inc(P, N - Length(FHist));
    N := Length(FHist);
  end;
  Move(FHist[N], FHist[0], (Length(FHist) - N) * SizeOf(SmallInt));
  for K := 0 to N - 1 do
  begin
    FHist[Length(FHist) - N + K] := P^;
    Inc(P);
  end;
end;

// Pitch period (samples at 16 kHz, 32..288) of the last 16 ms of output:
// normalized correlation on a 2:1 decimated signal, refined at full rate.
function TG722Decoder.EstimatePitch: Integer;
const
  L = 256;
var
  D: array[0..511] of Double;
  NH, K, Lag, Best, BestLag: Integer;
  C, E, V, BestV: Double;

  function Score(ALag: Integer): Double;   // full rate
  var
    J: Integer;
    CC, EE: Double;
  begin
    CC := 0; EE := 0;
    for J := NH - L to NH - 1 do
    begin
      CC := CC + FHist[J] * FHist[J - ALag];
      EE := EE + Sqr(Double(FHist[J - ALag]));
    end;
    if EE > 0 then Result := CC / Sqrt(EE) else Result := 0;
  end;

begin
  NH := Length(FHist);
  for K := 0 to 511 do
    D[K] := 0.5 * (FHist[NH - 1024 + 2 * K] + FHist[NH - 1024 + 2 * K + 1]);
  BestV := -MaxDouble; BestLag := 16;
  for Lag := 16 to 144 do
  begin
    C := 0; E := 0;
    for K := 512 - L div 2 to 511 do
    begin
      C := C + D[K] * D[K - Lag];
      E := E + Sqr(D[K - Lag]);
    end;
    if E > 0 then V := C / Sqrt(E) else V := 0;
    if V > BestV then begin BestV := V; BestLag := Lag; end;
  end;
  Result := 2 * BestLag;
  BestV := -MaxDouble;
  for Lag := Max(32, 2 * BestLag - 2) to Min(288, 2 * BestLag + 2) do
  begin
    V := Score(Lag);
    if V > BestV then begin BestV := V; Best := Lag; Result := Best; end;
  end;
end;

procedure TG722Decoder.StartErasure;
var
  K, NH: Integer;
begin
  FPitch := EstimatePitch;
  NH := Length(FHist);
  for K := 0 to 3 * FPitch - 1 do
    FPitchBuf[K] := FHist[NH - 3 * FPitch + K];
  FPeriods := 1;
  FPos := 0;
  FFadeLen := 0;
  // the shadow encoder starts from the decoder state and the recent output
  FShadow.FLow := FLow;
  FShadow.FHigh := FHigh;
  for K := 0 to 23 do FShadow.FX[K] := FHist[NH - 24 + K];
  FShadow.FHasPending := False;
  // first 22 samples: their input is already inside the decoder pipeline
  for K := 0 to 21 do FAhead[K] := GenerateSample;
  FAheadPos := 0;
  FAheadLeft := 22;
end;

function TG722Decoder.GenerateSample: SmallInt;
begin
  Result := SmallInt(EnsureRange(Round(NextConcealSample), -32768, 32767));
end;

// Next concealed output sample (from the look-ahead queue, then the generator)
function TG722Decoder.NextOutputSample: SmallInt;
begin
  if FAheadLeft > 0 then
  begin
    Result := FAhead[FAheadPos];
    FAheadPos := (FAheadPos + 1) mod 22;
    Dec(FAheadLeft);
  end
  else
    Result := GenerateSample;
end;

// Sample APos (0 .. APeriods*P - 1) of the last APeriods periods
function TG722Decoder.PeriodicSample(APeriods, APos: Integer): Double;
begin
  Result := FPitchBuf[3 * FPitch - APeriods * FPitch + APos mod (APeriods * FPitch)];
end;

function TG722Decoder.NextConcealSample: Double;
var
  G, W: Double;
  Want: Integer;
begin
  // more periods after 10 and 20 ms (less buzz), switched with overlap-add
  if FLost < 160 then Want := 1 else if FLost < 320 then Want := 2 else Want := 3;
  if (Want <> FPeriods) and (FFadeLen = 0) then
  begin
    FFadePeriods := FPeriods;
    FFadeLen := Max(FPitch div 4, 1);
    FFadePos := 0;
    FPeriods := Want;
  end;
  Result := PeriodicSample(FPeriods, FPos);
  if FFadeLen > 0 then
  begin
    W := (FFadePos + 1) / (FFadeLen + 1);
    Result := W * Result + (1 - W) * PeriodicSample(FFadePeriods, FPos);
    Inc(FFadePos);
    if FFadePos >= FFadeLen then FFadeLen := 0;
  end;
  FPos := (FPos + 1) mod (FPeriods * FPitch);
  // 20 % attenuation per 10 ms after the first 10 ms; silence after 60 ms
  if FLost < 160 then G := 1
  else G := Max(0.0, 1 - 0.2 * (FLost - 160) / 160);
  Result := Result * G;
  Inc(FLost);
end;

// Run the concealed samples through an encoder that shares the decoder state
// and decode its codes, so the ADPCM predictors and scale factors (and the
// receive QMF memory) follow the concealed signal.
procedure TG722Decoder.ResyncAdpcm(P: PSmallInt; N: Integer);
var
  K, RL, RH: Integer;
  X0: SmallInt;
  Code: Byte;
begin
  K := 0;
  while K + 1 < N do
  begin
    X0 := P^; Inc(P);
    Code := FShadow.EncodePair(X0, P^);
    Inc(P);
    DecodeSubbands(Code, RL, RH);
    Move(FX[2], FX[0], 22 * SizeOf(Integer));
    FX[22] := RL + RH;
    FX[23] := RL - RH;
    Inc(K, 2);
  end;
end;

function TG722Decoder.Conceal(Output: PSmallInt; N: Integer): Integer;
var
  K: Integer;
  P: PSmallInt;
  Ahead: TArray<SmallInt>;
begin
  N := N and not 1;
  Result := N;
  if N <= 0 then Exit;
  if FLost = 0 then StartErasure;
  SetLength(Ahead, N);
  P := Output;
  for K := 0 to N - 1 do
  begin
    // output the sample generated 22 samples ago, queue a new one
    P^ := FAhead[FAheadPos];
    Inc(P);
    Ahead[K] := GenerateSample;
    FAhead[FAheadPos] := Ahead[K];
    FAheadPos := (FAheadPos + 1) mod 22;
  end;
  FAheadLeft := 22;
  // re-encode only the first 10 ms (unattenuated) of the erasure: following
  // the fade-out would leave the ADPCM scale factors too small when the
  // packets come back (measured: worse PESQ on burst losses)
  K := 160 + 22 - (FLost - N);
  if K > 0 then ResyncAdpcm(@Ahead[0], Min(N, K and not 1));
  PushHistory(Output, N);
end;

function TG722Decoder.Decode(const Data: array of Byte): TArray<SmallInt>;
begin
  SetLength(Result, 2 * Length(Data));
  if Length(Data) > 0 then
    Decode(@Data[0], Length(Data), PSmallInt(Result));
end;

end.
