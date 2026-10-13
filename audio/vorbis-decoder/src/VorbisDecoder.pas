unit VorbisDecoder;

{
  VorbisDecoder.pas - Vorbis I audio packet decode

  Decode pipeline for one audio packet (spec section 4.3):
    1. Packet type bit, mode number, long-block prev/next window flags
    2. Window boundaries (left/right overlap regions) from the block flags
    3. Floor 1 decode per channel (unused floor => zero channel)
    4. Residue decode per submap (channels re-enabled by coupling)
    5. Inverse channel coupling (square polar), in reverse coupling order
    6. Floor curve synthesis multiplied into the residue spectrum
    7. Inverse MDCT (DCT-IV via N/4-point complex FFT)
    8. Overlap-add of the left slope with the saved right slope of the
       previous block; output [left_start, right_start); save [right_start,
       right_end) for the next packet (same bookkeeping as stb_vorbis)

  The IMDCT implements y[n] = sum_k X[k] cos(2*pi/N * (n + 1/2 + N/4) * (k + 1/2))
  with no extra scaling (the Vorbis window is power complementary).

  Reference: Vorbis I specification; stb_vorbis (public domain).

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  SysUtils, Math,
  AudioBitReader,
  AudioTypes,
  VorbisTypes,
  VorbisCodebook,
  VorbisFloor,
  VorbisResidue,
  VorbisSetup;

type
  // Precomputed tables for an N-point IMDCT (N = block size)
  TVorbisIMDCTPlan = record
    N, M, H   : Integer;            // block size, N/2, N/4
    PreCos    : TArray<Single>;     // exp(-i*pi*j/M)
    PreSin    : TArray<Single>;
    PostCos   : TArray<Single>;     // exp(-i*pi*(j+1/4)/M)
    PostSin   : TArray<Single>;
    BitRev    : TArray<Integer>;    // H-point bit reversal
    TwCos     : TArray<Single>;     // exp(-2*pi*i*k/H), k < H/2
    TwSin     : TArray<Single>;
    // scratch
    Re, Im    : TArray<Single>;
    D         : TArray<Single>;
  end;

// Build the IMDCT plan for block size N (power of two, >= 8).
procedure VorbisIMDCTInit(var P: TVorbisIMDCTPlan; N: Integer);

// Inverse MDCT: X = N/2 coefficients, Y = N output samples.
procedure VorbisIMDCT(var P: TVorbisIMDCTPlan; X: PSingle; Y: PSingle);

// Inverse square-polar channel coupling (spec 4.3.6), exported for tests.
// Steps are undone in reverse order.
procedure DecoupleChannels(
  const Coupling : TArray<TVorbisMappingCoupling>;
  CoupCount      : Integer;
  const Spectra  : TArray<TArray<Single>>;
  N              : Integer
);

// Vorbis window rising slope of length L: w[j] = sin(pi/2 * sin^2(pi*(j+0.5)/(2L)))
function VorbisWindowSlope(L: Integer): TArray<Single>;

type
  TVorbisDecoder = class
  private
    FSetup       : TVorbisSetup;
    FReady       : Boolean;
    FHeaderCount : Integer;
    // Per-channel working buffers
    FSpectrum    : TArray<TArray<Single>>;   // N1/2 floats
    FBlock       : TArray<TArray<Single>>;   // N1 floats (IMDCT output)
    FPrev        : TArray<TArray<Single>>;   // saved right slope, N1/2 floats
    FPrevLen     : Integer;                  // valid floats in FPrev (0 = none)
    FFinalY      : TArray<TArray<Integer>>;
    FStep2       : TArray<TArray<Boolean>>;
    FPlan0, FPlan1: TVorbisIMDCTPlan;
    FSlope0, FSlope1: TArray<Single>;        // slopes of length N0/2 and N1/2
    procedure PrepareBuffers;
    function DecodeAudioPacket(
      Data    : PByte;
      DataLen : Integer;
      out Buffer  : TAudioBuffer;
      out Samples : Integer
    ): TVorbisDecodeResult;
  public
    constructor Create;
    destructor  Destroy; override;

    // Feed Vorbis packets in order.
    // First three calls consume the three header packets (ident/comment/setup).
    // After that, each call decodes one audio packet.
    function DecodePacket(
      Data    : PByte;
      DataLen : Integer;
      out Buffer  : TAudioBuffer;
      out Samples : Integer
    ): TVorbisDecodeResult;

    // Drop overlap state (e.g. after a seek); the next packet yields no output.
    procedure Reset;

    property VSetup    : TVorbisSetup read FSetup;
    property Ready     : Boolean      read FReady;
    property Channels  : Byte         read FSetup.Ident.Channels;
    property SampleRate: Cardinal     read FSetup.Ident.SampleRate;
  end;

implementation

// ---------------------------------------------------------------------------
// IMDCT
// ---------------------------------------------------------------------------

procedure VorbisIMDCTInit(var P: TVorbisIMDCTPlan; N: Integer);
var
  J, K, Bits, R, V: Integer;
begin
  P.N := N;
  P.M := N shr 1;
  P.H := N shr 2;
  SetLength(P.PreCos,  P.H); SetLength(P.PreSin,  P.H);
  SetLength(P.PostCos, P.H); SetLength(P.PostSin, P.H);
  for J := 0 to P.H - 1 do
  begin
    P.PreCos[J]  :=  Cos(Pi * J / P.M);
    P.PreSin[J]  := -Sin(Pi * J / P.M);
    P.PostCos[J] :=  Cos(Pi * (J + 0.25) / P.M);
    P.PostSin[J] := -Sin(Pi * (J + 0.25) / P.M);
  end;
  // bit reversal
  Bits := 0;
  while (1 shl Bits) < P.H do Inc(Bits);
  SetLength(P.BitRev, P.H);
  for J := 0 to P.H - 1 do
  begin
    R := 0; V := J;
    for K := 0 to Bits - 1 do
    begin
      R := (R shl 1) or (V and 1);
      V := V shr 1;
    end;
    P.BitRev[J] := R;
  end;
  SetLength(P.TwCos, Max(P.H shr 1, 1));
  SetLength(P.TwSin, Max(P.H shr 1, 1));
  for K := 0 to (P.H shr 1) - 1 do
  begin
    P.TwCos[K] :=  Cos(2 * Pi * K / P.H);
    P.TwSin[K] := -Sin(2 * Pi * K / P.H);
  end;
  SetLength(P.Re, P.H);
  SetLength(P.Im, P.H);
  SetLength(P.D,  P.M);
end;

procedure VorbisIMDCT(var P: TVorbisIMDCTPlan; X: PSingle; Y: PSingle);
var
  J, K, I       : Integer;
  A, B, C, S    : Single;
  Len, Half, Step: Integer;
  Wr, Wi, Tr, Ti: Single;
  Ur, Ui        : Single;
  M, H, N4      : Integer;
begin
  M := P.M; H := P.H; N4 := P.H;

  // Pre-twiddle: t[j] = (X[2j] + i X[M-1-2j]) * exp(-i pi j / M), stored bit-reversed
  for J := 0 to H - 1 do
  begin
    A := X[2 * J];
    B := X[M - 1 - 2 * J];
    C := P.PreCos[J];
    S := P.PreSin[J];
    P.Re[P.BitRev[J]] := A * C - B * S;
    P.Im[P.BitRev[J]] := A * S + B * C;
  end;

  // In-place iterative radix-2 DIT FFT (forward)
  Len := 2;
  while Len <= H do
  begin
    Half := Len shr 1;
    Step := H div Len;
    I := 0;
    while I < H do
    begin
      for K := 0 to Half - 1 do
      begin
        Wr := P.TwCos[K * Step];
        Wi := P.TwSin[K * Step];
        Tr := P.Re[I + K + Half] * Wr - P.Im[I + K + Half] * Wi;
        Ti := P.Re[I + K + Half] * Wi + P.Im[I + K + Half] * Wr;
        P.Re[I + K + Half] := P.Re[I + K] - Tr;
        P.Im[I + K + Half] := P.Im[I + K] - Ti;
        P.Re[I + K] := P.Re[I + K] + Tr;
        P.Im[I + K] := P.Im[I + K] + Ti;
      end;
      Inc(I, Len);
    end;
    Len := Len shl 1;
  end;

  // Post-twiddle and DCT-IV unpack: d[2j] = Re u, d[M-1-2j] = -Im u
  for J := 0 to H - 1 do
  begin
    C := P.PostCos[J];
    S := P.PostSin[J];
    Ur := P.Re[J] * C - P.Im[J] * S;
    Ui := P.Re[J] * S + P.Im[J] * C;
    P.D[2 * J]         := Ur;
    P.D[M - 1 - 2 * J] := -Ui;
  end;

  // IMDCT from DCT-IV (N outputs)
  for J := 0 to N4 - 1 do
    Y[J] := P.D[J + N4];
  for J := N4 to 3 * N4 - 1 do
    Y[J] := -P.D[3 * N4 - 1 - J];
  for J := 3 * N4 to P.N - 1 do
    Y[J] := -P.D[J - 3 * N4];
end;

// ---------------------------------------------------------------------------
// Coupling and window
// ---------------------------------------------------------------------------

procedure DecoupleChannels(
  const Coupling : TArray<TVorbisMappingCoupling>;
  CoupCount      : Integer;
  const Spectra  : TArray<TArray<Single>>;
  N              : Integer
);
var
  K, I   : Integer;
  M, A   : Single;
  M2, A2 : Single;
  MC, AC : Integer;
begin
  for K := CoupCount - 1 downto 0 do
  begin
    MC := Coupling[K].Magnitude;
    AC := Coupling[K].Angle;
    for I := 0 to N - 1 do
    begin
      M := Spectra[MC][I];
      A := Spectra[AC][I];
      if M > 0 then
      begin
        if A > 0 then begin M2 := M;     A2 := M - A; end
        else          begin A2 := M;     M2 := M + A; end;
      end
      else
      begin
        if A > 0 then begin M2 := M;     A2 := M + A; end
        else          begin A2 := M;     M2 := M - A; end;
      end;
      Spectra[MC][I] := M2;
      Spectra[AC][I] := A2;
    end;
  end;
end;

function VorbisWindowSlope(L: Integer): TArray<Single>;
var
  J : Integer;
  S : Double;
begin
  SetLength(Result, L);
  for J := 0 to L - 1 do
  begin
    S := Sin(Pi * (J + 0.5) / (2.0 * L));
    Result[J] := Sin(Pi / 2.0 * S * S);
  end;
end;

// ---------------------------------------------------------------------------
// TVorbisDecoder
// ---------------------------------------------------------------------------

constructor TVorbisDecoder.Create;
begin
  inherited Create;
  FHeaderCount := 0;
  FReady       := False;
  FPrevLen     := 0;
end;

destructor TVorbisDecoder.Destroy;
begin
  inherited Destroy;
end;

procedure TVorbisDecoder.Reset;
begin
  FPrevLen := 0;
end;

procedure TVorbisDecoder.PrepareBuffers;
var
  Ch, NumCh, N1, MaxValues, F: Integer;
begin
  NumCh := FSetup.Ident.Channels;
  N1    := FSetup.Ident.BlockSize1;
  SetLength(FSpectrum, NumCh);
  SetLength(FBlock,    NumCh);
  SetLength(FPrev,     NumCh);
  SetLength(FFinalY,   NumCh);
  SetLength(FStep2,    NumCh);
  MaxValues := 2;
  for F := 0 to FSetup.FloorCount - 1 do
    if FSetup.Floors[F].Floor1.XListCount > MaxValues then
      MaxValues := FSetup.Floors[F].Floor1.XListCount;
  for Ch := 0 to NumCh - 1 do
  begin
    SetLength(FSpectrum[Ch], N1 shr 1);
    SetLength(FBlock[Ch],    N1);
    SetLength(FPrev[Ch],     N1 shr 1);
    SetLength(FFinalY[Ch],   MaxValues);
    SetLength(FStep2[Ch],    MaxValues);
  end;
  VorbisIMDCTInit(FPlan0, FSetup.Ident.BlockSize0);
  VorbisIMDCTInit(FPlan1, FSetup.Ident.BlockSize1);
  FSlope0 := VorbisWindowSlope(FSetup.Ident.BlockSize0 shr 1);
  FSlope1 := VorbisWindowSlope(FSetup.Ident.BlockSize1 shr 1);
  FPrevLen := 0;
end;

function TVorbisDecoder.DecodeAudioPacket(
  Data    : PByte;
  DataLen : Integer;
  out Buffer  : TAudioBuffer;
  out Samples : Integer
): TVorbisDecodeResult;
var
  Br          : TAudioBitReader;
  ModeNum     : Integer;
  IsLong      : Boolean;
  PrevFlag, NextFlag: Integer;
  N, N0, N2   : Integer;
  WindowCenter: Integer;
  LeftStart, LeftEnd, RightStart, RightEnd: Integer;
  Ch, NumCh   : Integer;
  Map         : TVorbisMapping;
  FloorIdx    : Integer;
  ZeroCh      : TArray<Boolean>;
  ReallyZero  : TArray<Boolean>;
  I, J, K, SM : Integer;
  SmCh        : Integer;
  SmChannels  : TArray<Integer>;
  DoNot       : TArray<Boolean>;
  Outputs     : TArray<PSingle>;
  HadPrev     : Boolean;
  L           : Integer;
  W           : TArray<Single>;
  V           : Single;
begin
  Result  := vdrCorrupted;
  Samples := 0;
  Buffer  := nil;

  BrInit(Br, Data, DataLen, boLSBFirst);
  if DataLen <= 0 then Exit;

  // Packet type bit must be 0 for audio
  if BrRead(Br, 1) <> 0 then Exit(vdrCorrupted);

  NumCh := FSetup.Ident.Channels;
  N0    := FSetup.Ident.BlockSize0;

  ModeNum := BrRead(Br, VorbisILog(FSetup.ModeCount - 1));
  if ModeNum >= FSetup.ModeCount then Exit(vdrCorrupted);

  IsLong := FSetup.Modes[ModeNum].BlockFlag;
  if IsLong then
  begin
    N := FSetup.Ident.BlockSize1;
    PrevFlag := BrRead(Br, 1);
    NextFlag := BrRead(Br, 1);
  end
  else
  begin
    N := N0;
    PrevFlag := 0;
    NextFlag := 0;
  end;
  N2 := N shr 1;

  // ---- Window boundaries (spec 4.3.1 / stb_vorbis vorbis_decode_initial) ----
  WindowCenter := N shr 1;
  if IsLong and (PrevFlag = 0) then
  begin
    LeftStart := (N - N0) shr 2;
    LeftEnd   := (N + N0) shr 2;
  end
  else
  begin
    LeftStart := 0;
    LeftEnd   := WindowCenter;
  end;
  if IsLong and (NextFlag = 0) then
  begin
    RightStart := (N * 3 - N0) shr 2;
    RightEnd   := (N * 3 + N0) shr 2;
  end
  else
  begin
    RightStart := WindowCenter;
    RightEnd   := N;
  end;

  Map := FSetup.Mappings[FSetup.Modes[ModeNum].Mapping];

  // ---- Floors ----
  SetLength(ZeroCh, NumCh);
  SetLength(ReallyZero, NumCh);
  for Ch := 0 to NumCh - 1 do
  begin
    FloorIdx := Map.SubMapFloor[Map.Mux[Ch]];
    if FSetup.Floors[FloorIdx].FloorType <> VORBIS_FLOOR_TYPE_1 then
      Exit(vdrError);  // floor 0 not supported
    ZeroCh[Ch] := not VorbisFloor1Decode(FSetup.Floors[FloorIdx].Floor1,
      FSetup.Codebooks, Br, FFinalY[Ch], FStep2[Ch]);
    ReallyZero[Ch] := ZeroCh[Ch];
  end;

  // Re-enable coupled channels when either side is active
  for I := 0 to Map.Couplings - 1 do
    if (not ZeroCh[Map.CouplingList[I].Magnitude]) or
       (not ZeroCh[Map.CouplingList[I].Angle]) then
    begin
      ZeroCh[Map.CouplingList[I].Magnitude] := False;
      ZeroCh[Map.CouplingList[I].Angle]     := False;
    end;

  // ---- Residues, per submap ----
  for SM := 0 to Map.SubMaps - 1 do
  begin
    SmCh := 0;
    SetLength(SmChannels, NumCh);
    for Ch := 0 to NumCh - 1 do
      if Map.Mux[Ch] = SM then
      begin
        SmChannels[SmCh] := Ch;
        Inc(SmCh);
      end;
    if SmCh = 0 then Continue;
    SetLength(DoNot, SmCh);
    SetLength(Outputs, SmCh);
    for K := 0 to SmCh - 1 do
    begin
      DoNot[K]   := ZeroCh[SmChannels[K]];
      Outputs[K] := @FSpectrum[SmChannels[K]][0];
    end;
    VorbisDecodeResidue(FSetup.Residues[Map.SubMapResidue[SM]], FSetup.Codebooks,
      Br, SmCh, DoNot, Outputs, N2);
  end;

  // ---- Inverse coupling ----
  if Map.Couplings > 0 then
    DecoupleChannels(Map.CouplingList, Map.Couplings, FSpectrum, N2);

  // ---- Floor curve synthesis and multiply ----
  for Ch := 0 to NumCh - 1 do
  begin
    if ReallyZero[Ch] then
      FillChar(FSpectrum[Ch][0], N2 * SizeOf(Single), 0)
    else
    begin
      FloorIdx := Map.SubMapFloor[Map.Mux[Ch]];
      VorbisFloor1Render(FSetup.Floors[FloorIdx].Floor1, FFinalY[Ch], FStep2[Ch],
        N2, @FSpectrum[Ch][0]);
    end;
  end;

  // ---- IMDCT ----
  for Ch := 0 to NumCh - 1 do
    if IsLong then VorbisIMDCT(FPlan1, @FSpectrum[Ch][0], @FBlock[Ch][0])
    else           VorbisIMDCT(FPlan0, @FSpectrum[Ch][0], @FBlock[Ch][0]);

  // ---- Overlap-add with the previous block's right slope ----
  HadPrev := FPrevLen > 0;
  if HadPrev then
  begin
    L := Min(FPrevLen, LeftEnd - LeftStart);
    if L = Length(FSlope0) then W := FSlope0
    else if L = Length(FSlope1) then W := FSlope1
    else W := VorbisWindowSlope(L);
    for Ch := 0 to NumCh - 1 do
      for J := 0 to L - 1 do
        FBlock[Ch][LeftStart + J] :=
          FBlock[Ch][LeftStart + J] * W[J] + FPrev[Ch][J] * W[L - 1 - J];
  end;

  // Save the right slope (unwindowed) for the next packet
  FPrevLen := RightEnd - RightStart;
  for Ch := 0 to NumCh - 1 do
    Move(FBlock[Ch][RightStart], FPrev[Ch][0], FPrevLen * SizeOf(Single));

  if not HadPrev then
  begin
    // First packet after headers/reset: overlap data missing, no output
    Samples := 0;
    Exit(vdrOK);
  end;

  // ---- Output [LeftStart, RightStart) ----
  Samples := RightStart - LeftStart;
  Buffer  := AudioBufferCreate(NumCh, Samples);
  for Ch := 0 to NumCh - 1 do
    for I := 0 to Samples - 1 do
    begin
      V := FBlock[Ch][LeftStart + I];
      if V > 1.0 then V := 1.0
      else if V < -1.0 then V := -1.0;
      Buffer[Ch][I] := V;
    end;

  Result := vdrOK;
end;

// ---------------------------------------------------------------------------
// DecodePacket
// ---------------------------------------------------------------------------

function TVorbisDecoder.DecodePacket(
  Data    : PByte;
  DataLen : Integer;
  out Buffer  : TAudioBuffer;
  out Samples : Integer
): TVorbisDecodeResult;
begin
  Buffer  := nil;
  Samples := 0;

  if (Data = nil) or (DataLen <= 0) then Exit(vdrCorrupted);

  // Header packets have bit 0 of first byte = 1 (types 1, 3, 5 are all odd)
  if (Data^ and 1) <> 0 then
  begin
    case FHeaderCount of
      0: begin
           if not VorbisParseIdent(Data, DataLen, FSetup) then Exit(vdrError);
           Inc(FHeaderCount);
           Exit(vdrHeader);
         end;
      1: begin
           if not VorbisParseComment(Data, DataLen) then Exit(vdrError);
           Inc(FHeaderCount);
           Exit(vdrHeader);
         end;
      2: begin
           if not VorbisParseSetup(Data, DataLen, FSetup) then Exit(vdrError);
           Inc(FHeaderCount);
           PrepareBuffers;
           FReady := True;
           Exit(vdrHeader);
         end;
    else
      Exit(vdrError);
    end;
  end;

  if not FReady then Exit(vdrError);
  Result := DecodeAudioPacket(Data, DataLen, Buffer, Samples);
end;

end.
