unit VorbisDecoder;

{
  VorbisDecoder.pas - Vorbis I audio packet decode

  Full Vorbis I decode pipeline (spec section 4.3):
    1. Read mode number; for long blocks read prev/next window flags
    2. Decode floor curves for each channel
    3. Decode residue vectors for each channel
    4. Apply inverse M/S channel decoupling
    5. Apply floor × residue in spectral domain
    6. Apply inverse MDCT (N/4-point complex FFT method)
    7. Apply window function and overlap-add with previous block
    8. Return center N/2 samples from the previous block

  Window switching (spec section 4.3.2):
    Long blocks can have mixed left/right window widths when adjacent to
    short blocks. This implementation correctly handles all four window
    transition cases (LL, LS, SL, SS).

  MDCT:
    The inverse type-IV DCT is factored as pre-rotation + N/4-pt complex
    FFT + post-rotation + unfolding into the N-point output.

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

// Apply inverse M/S channel decoupling (exported for unit testing).
procedure DecoupleChannels(
  const Coupling : TArray<TVorbisMappingCoupling>;
  CoupCount      : Integer;
  const Spectra  : TArray<TArray<Single>>;
  N              : Integer
);

// Apply Vorbis window function to one channel's MDCT output (exported for testing).
procedure ApplyWindow(
  Buf          : PSingle;
  N            : Integer;
  N0           : Integer;
  N1           : Integer;
  IsLong       : Boolean;
  PrevIsLong   : Boolean;
  NextIsLong   : Boolean
);

type
  TVorbisDecoder = class
  private
    FSetup       : TVorbisSetup;
    FPrevBuf     : TArray<TArray<Single>>;  // per channel, BlockSize1 samples
    FPrevN       : Integer;     // block size of previous frame (0 = first)
    FPrevIsLong  : Boolean;     // was the previous block long?
    FReady       : Boolean;
    FHeaderCount : Integer;

    procedure IMDCT(Input: PSingle; N: Integer; Output: PSingle);

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

    property VSetup    : TVorbisSetup read FSetup;
    property Ready     : Boolean      read FReady;
    property Channels  : Byte         read FSetup.Ident.Channels;
    property SampleRate: Cardinal     read FSetup.Ident.SampleRate;
  end;

implementation

// ---------------------------------------------------------------------------
// MDCT (type-IV DCT inverse) — N/4-point complex FFT method
// ---------------------------------------------------------------------------
//
// Input:  N/2 spectral coefficients X[k], k = 0..N/2-1
// Output: N time samples x[n], n = 0..N-1
//
// Algorithm (Malvar / Odaka-Nishitani):
//   1. Pre-rotate: form complex array A[k] of length N/4
//   2. Apply N/4-pt inverse DFT (= forward FFT with sign flip)
//   3. Post-rotate and unfold to N output samples

procedure TVorbisDecoder.IMDCT(Input: PSingle; N: Integer; Output: PSingle);
var
  N2, N4  : Integer;
  K       : Integer;
  Ar, Ai  : TArray<Single>;
  Angle   : Double;
  Cs, Sn  : Double;
  // FFT
  Len, Step, J, I : Integer;
  Wr, Wi, Ur, Ui, Tr, Ti: Single;
  Tmp     : Single;
begin
  N2 := N shr 1;
  N4 := N shr 2;

  SetLength(Ar, N4);
  SetLength(Ai, N4);

  // Pre-rotate: A[k] = X[2k] * e^(-j*pi*(k+1/8)/N/2) + ...
  // Using the Malvar formulation:
  // A[k] = (X[N/2-1-2k] + j*X[2k]) * e^(-j*pi*(4k+1)/(2N))
  for K := 0 to N4 - 1 do
  begin
    Angle := Pi * (4.0 * K + 1) / (2.0 * N);
    Cs := Cos(Angle);
    Sn := Sin(Angle);
    Ar[K] := Input[N2 - 1 - 2*K] * Cs - Input[2*K] * Sn;
    Ai[K] := Input[N2 - 1 - 2*K] * Sn + Input[2*K] * Cs;
  end;

  // Bit-reverse permutation for N4-point FFT
  J := 0;
  for I := 0 to N4 - 2 do
  begin
    if I < J then
    begin
      Tmp := Ar[I]; Ar[I] := Ar[J]; Ar[J] := Tmp;
      Tmp := Ai[I]; Ai[I] := Ai[J]; Ai[J] := Tmp;
    end;
    var Bit := N4 shr 1;
    while (J and Bit) <> 0 do begin J := J xor Bit; Bit := Bit shr 1; end;
    J := J xor Bit;
  end;

  // Cooley-Tukey DIT FFT (forward, so twiddle = e^(-j*2*pi*k/N))
  Len := 1;
  while Len < N4 do
  begin
    Step := Len * 2;
    for K := 0 to Len - 1 do
    begin
      Angle := -Pi * K / Len;
      Wr := Cos(Angle);
      Wi := Sin(Angle);
      I := K;
      while I < N4 do
      begin
        Ur := Ar[I];    Ui := Ai[I];
        Tr := Ar[I+Len]; Ti := Ai[I+Len];
        Ar[I+Len] := Ur - (Wr*Tr - Wi*Ti);
        Ai[I+Len] := Ui - (Wr*Ti + Wi*Tr);
        Ar[I]     := Ur + (Wr*Tr - Wi*Ti);
        Ai[I]     := Ui + (Wr*Ti + Wi*Tr);
        Inc(I, Step);
      end;
    end;
    Len := Step;
  end;

  // Post-rotate and unfold to N-point output:
  // out[N/4+K]         =  Re(A[K]) * cos + Im(A[K]) * sin
  // out[N/4-1-K]       = -Re(A[K]) * sin + Im(A[K]) * cos  (mirrored)
  // out[N/4*3+K]       = -(same as above but negated)
  // out[N-1 - (N/4+K)] = -(same as above)
  for K := 0 to N4 - 1 do
  begin
    Angle := Pi * (4.0 * K + 1) / (2.0 * N);
    Cs := Cos(Angle);
    Sn := Sin(Angle);
    Tr := (Ar[K] * Cs + Ai[K] * Sn) * (1.0 / N4);
    Ti := (Ar[K] * Sn - Ai[K] * Cs) * (1.0 / N4);
    // Unfold
    Output[N4 + K]         :=  Tr;
    Output[N4 - 1 - K]     :=  Ti;
    Output[N4*3 + K]       := -Ti;
    Output[N - 1 - K - N4] := -Tr;
  end;
end;

// ---------------------------------------------------------------------------
// Channel M/S decoupling (spec section 4.3.9)
// ---------------------------------------------------------------------------

procedure DecoupleChannels(
  const Coupling : TArray<TVorbisMappingCoupling>;
  CoupCount      : Integer;
  const Spectra  : TArray<TArray<Single>>;
  N              : Integer
);
var
  K, I : Integer;
  M, A : Single;
  MC, AC: Integer;
begin
  for K := 0 to CoupCount - 1 do
  begin
    MC := Coupling[K].Magnitude;
    AC := Coupling[K].Angle;
    for I := 0 to N - 1 do
    begin
      M := Spectra[MC][I];
      A := Spectra[AC][I];
      if M > 0 then
      begin
        if A > 0 then begin Spectra[MC][I] := M;     Spectra[AC][I] := M - A; end
        else           begin Spectra[MC][I] := M + A; Spectra[AC][I] := M;     end;
      end
      else
      begin
        if A > 0 then begin Spectra[MC][I] := M;     Spectra[AC][I] := M - A; end
        else           begin Spectra[MC][I] := M + A; Spectra[AC][I] := M;     end;
      end;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Apply window function (in-place), with asymmetric slope support
// ---------------------------------------------------------------------------

// Vorbis window slope: w(n) = sin(pi/2 * sin^2(pi*(n+0.5)/n_w))
function WinSlope(N, I: Integer): Single; inline;
var
  S: Single;
begin
  S := Sin(Pi * (I + 0.5) / N);
  Result := Sin(Pi / 2.0 * S * S);
end;

// Apply windowing to one channel's MDCT output.
// For short blocks: symmetric window using N.
// For long blocks: left and right slopes may use different widths
//   (determined by prev and next block flags).
procedure ApplyWindow(
  Buf          : PSingle;
  N            : Integer;    // current block size
  N0           : Integer;    // short block size
  N1           : Integer;    // long block size
  IsLong       : Boolean;
  PrevIsLong   : Boolean;
  NextIsLong   : Boolean
);
var
  I           : Integer;
  N4          : Integer;
  N0h, N1h    : Integer;  // half block sizes
  // Left slope parameters
  LW          : Integer;  // slope width
  LStart      : Integer;  // where the slope starts in the window
  // Right slope parameters
  RW          : Integer;
  RStart      : Integer;
begin
  N4   := N shr 2;
  N0h  := N0 shr 1;
  N1h  := N1 shr 1;

  if not IsLong then
  begin
    // Short block: full symmetric window
    for I := 0 to N - 1 do
      Buf[I] := Buf[I] * WinSlope(N, I);
  end
  else
  begin
    // Long block: handle mixed windows
    // Left slope
    if PrevIsLong then begin LW := N1h; LStart := 0;           end
    else               begin LW := N0h; LStart := N4 - N0h div 2; end;
    // Right slope (mirror)
    if NextIsLong then begin RW := N1h; RStart := N - N1h;     end
    else               begin RW := N0h; RStart := N - N4 - N0h div 2; end;

    // Zero before left slope
    for I := 0 to LStart - 1 do Buf[I] := 0.0;
    // Left slope: rising from 0 to 1
    for I := 0 to LW - 1 do
      Buf[LStart + I] := Buf[LStart + I] * WinSlope(LW * 2, I);
    // Flat section = 1 (no change needed)
    // Right slope: falling from 1 to 0
    for I := 0 to RW - 1 do
      Buf[RStart + I] := Buf[RStart + I] * WinSlope(RW * 2, RW - 1 - I);
    // Zero after right slope
    for I := RStart + RW to N - 1 do Buf[I] := 0.0;
  end;
end;

// ---------------------------------------------------------------------------
// DecodeAudioPacket
// ---------------------------------------------------------------------------

function TVorbisDecoder.DecodeAudioPacket(
  Data    : PByte;
  DataLen : Integer;
  out Buffer  : TAudioBuffer;
  out Samples : Integer
): TVorbisDecodeResult;
var
  Br          : TAudioBitReader;
  ModeNum     : Integer;
  ModeIsLong  : Boolean;
  PrevWinFlag : Boolean;
  NextWinFlag : Boolean;
  N, N2       : Integer;
  Ch          : Integer;
  NumCh       : Integer;
  MapIdx      : Integer;
  FloorOutput : TArray<TArray<Single>>;
  FloorActive : TArray<Boolean>;
  Spectrum    : TArray<TArray<Single>>;
  MDCTOut     : TArray<TArray<Single>>;
  DoNotDecode : TArray<Boolean>;
  ResOutputs  : TArray<PSingle>;
  SmDoNot     : TArray<Boolean>;
  I, K, SM    : Integer;
begin
  Result := vdrCorrupted;
  Samples := 0;
  Buffer  := nil;

  BrInit(Br, Data, DataLen, boLSBFirst);

  // Bit 0 of audio packet is always 0
  if BrRead(Br, 1) <> 0 then Exit(vdrCorrupted);

  NumCh := FSetup.Ident.Channels;

  // Mode number
  ModeNum := BrRead(Br, VorbisILog(FSetup.ModeCount - 1));
  if ModeNum >= FSetup.ModeCount then Exit(vdrCorrupted);

  ModeIsLong := FSetup.Modes[ModeNum].BlockFlag;
  N  := IfThen(ModeIsLong, FSetup.Ident.BlockSize1, FSetup.Ident.BlockSize0);
  N2 := N shr 1;

  // For long blocks: read prev/next window flags (spec section 4.3.2)
  PrevWinFlag := ModeIsLong;  // default: same-size transition
  NextWinFlag := ModeIsLong;
  if ModeIsLong then
  begin
    PrevWinFlag := BrRead(Br, 1) <> 0;
    NextWinFlag := BrRead(Br, 1) <> 0;
  end;

  MapIdx := FSetup.Modes[ModeNum].Mapping;
  var Map := FSetup.Mappings[MapIdx];

  // Allocate per-channel arrays
  SetLength(FloorOutput, NumCh);
  SetLength(FloorActive, NumCh);
  SetLength(Spectrum, NumCh);
  SetLength(MDCTOut,  NumCh);
  SetLength(DoNotDecode, NumCh);
  for Ch := 0 to NumCh - 1 do
  begin
    SetLength(FloorOutput[Ch], N2);
    SetLength(Spectrum[Ch], N2);
    SetLength(MDCTOut[Ch], N);
    DoNotDecode[Ch] := False;
    FillChar(Spectrum[Ch][0], N2 * SizeOf(Single), 0);
    FillChar(MDCTOut[Ch][0],  N  * SizeOf(Single), 0);
  end;

  // ---- Floor decode ----
  for Ch := 0 to NumCh - 1 do
  begin
    var SubMap   := Map.Mux[Ch];
    var FloorIdx := Map.SubMapFloor[SubMap];
    var Floor    := FSetup.Floors[FloorIdx];

    if Floor.FloorType = VORBIS_FLOOR_TYPE_1 then
      FloorActive[Ch] := VorbisDecodeFloor1(Floor.Floor1,
        FSetup.Codebooks, Br, N2, @FloorOutput[Ch][0])
    else
      FloorActive[Ch] := VorbisDecodeFloor0(Floor.Floor0,
        FSetup.Codebooks, Br, N2, Integer(FSetup.Ident.SampleRate), @FloorOutput[Ch][0]);

    DoNotDecode[Ch] := not FloorActive[Ch];
  end;

  // ---- Residue decode (per submap) ----
  for SM := 0 to Map.SubMaps - 1 do
  begin
    var SmChannels: TArray<Integer>;
    var SmCh: Integer := 0;
    for Ch := 0 to NumCh - 1 do
      if Map.Mux[Ch] = SM then
      begin
        SetLength(SmChannels, SmCh + 1);
        SmChannels[SmCh] := Ch;
        Inc(SmCh);
      end;
    if SmCh = 0 then Continue;

    var ResIdx := Map.SubMapResidue[SM];
    var Res    := FSetup.Residues[ResIdx];

    SetLength(ResOutputs, SmCh);
    SetLength(SmDoNot, SmCh);
    for K := 0 to SmCh - 1 do
    begin
      ResOutputs[K] := @Spectrum[SmChannels[K]][0];
      SmDoNot[K]    := DoNotDecode[SmChannels[K]];
    end;

    VorbisDecodeResidue(Res, FSetup.Codebooks, Br, SmCh, SmDoNot, ResOutputs, N2);
  end;

  // ---- Inverse channel coupling ----
  if Map.Couplings > 0 then
    DecoupleChannels(Map.CouplingList, Map.Couplings, Spectrum, N2);

  // ---- Floor × Residue ----
  for Ch := 0 to NumCh - 1 do
    if FloorActive[Ch] then
      for I := 0 to N2 - 1 do
        Spectrum[Ch][I] := Spectrum[Ch][I] * FloorOutput[Ch][I];

  // ---- IMDCT ----
  for Ch := 0 to NumCh - 1 do
    IMDCT(@Spectrum[Ch][0], N, @MDCTOut[Ch][0]);

  // ---- Window ----
  for Ch := 0 to NumCh - 1 do
    ApplyWindow(@MDCTOut[Ch][0], N,
      FSetup.Ident.BlockSize0, FSetup.Ident.BlockSize1,
      ModeIsLong, PrevWinFlag, NextWinFlag);

  // ---- Overlap-add and output ----
  if FPrevN = 0 then
  begin
    // First audio frame: no output yet; store current block
    for Ch := 0 to NumCh - 1 do
    begin
      SetLength(FPrevBuf[Ch], N);
      Move(MDCTOut[Ch][0], FPrevBuf[Ch][0], N * SizeOf(Single));
    end;
    FPrevN      := N;
    FPrevIsLong := ModeIsLong;
    Samples := 0;
    Buffer  := nil;
    Result  := vdrOK;
    Exit;
  end;

  // Output: center of previous block = left half (N_prev/2 samples)
  var PrevN   := FPrevN;
  var OutN    := PrevN shr 1;         // samples to output from previous block center
  var OverLen := Min(OutN, N shr 1);  // overlap region

  Buffer := AudioBufferCreate(NumCh, OutN);
  Samples := OutN;

  for Ch := 0 to NumCh - 1 do
  begin
    for I := 0 to OutN - 1 do
    begin
      var Samp: Single := FPrevBuf[Ch][PrevN div 2 + I];
      if I < OverLen then
        Samp := Samp + MDCTOut[Ch][I];
      // Normalize and clamp
      if Samp >  1.0 then Samp :=  1.0
      else if Samp < -1.0 then Samp := -1.0;
      Buffer[Ch][I] := Samp;
    end;
  end;

  // Store current block for next frame
  for Ch := 0 to NumCh - 1 do
  begin
    if Length(FPrevBuf[Ch]) < N then
      SetLength(FPrevBuf[Ch], N);
    Move(MDCTOut[Ch][0], FPrevBuf[Ch][0], N * SizeOf(Single));
  end;
  FPrevN      := N;
  FPrevIsLong := ModeIsLong;

  Result := vdrOK;
end;

// ---------------------------------------------------------------------------
// Constructor / Destructor
// ---------------------------------------------------------------------------

constructor TVorbisDecoder.Create;
begin
  inherited Create;
  FHeaderCount := 0;
  FReady       := False;
  FPrevN       := 0;
  FPrevIsLong  := False;
end;

destructor TVorbisDecoder.Destroy;
begin
  inherited Destroy;
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
           SetLength(FPrevBuf, FSetup.Ident.Channels);
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
