unit MP3EncEncoder;

(*
  MP3EncEncoder.pas — MPEG1 Layer III encoder pipeline (mono / stereo / MS)

  Per channel and granule:
    Polyphase analysis  (MP3EncPolyphase) : 32 PCM samples -> 32 subbands
    MDCT + antialias    (MP3EncMDCT)      : 36 subband samples -> 18 lines
    Psychoacoustics     (MP3EncPsy)       : allowed noise per scalefactor band
    Noise shaping loop  (MP3EncLoop)      : global_gain + scalefactors so the
                                            Huffman data fits the bit budget
    Frame assembly      (MP3EncFrame)     : header + side info + main data

  Bit allocation
    The main-data bits of a frame are shared between its granules/channels
    in proportion to the bit demand estimated by the psychoacoustic model.
    With the bit reservoir enabled (EncEnableReservoir) unused bits are
    carried to later frames (main_data_begin, up to 511 bytes), so loud or
    complex granules can borrow bits from quiet ones.  Frames are then
    emitted with a delay: EncodeFrame* return the bytes of every frame
    that is complete (possibly none, possibly several) and EncFlush returns
    the rest at the end of the stream.  Without the reservoir every call
    returns exactly FrameBytes bytes.

  Stereo
    EncodeFrameStereo : independent L/R (FRAME_CH_STEREO)
    EncodeFrameMS     : mid/side on the MDCT lines (FRAME_CH_JOINT, ms_stereo)
    EncodeFrameAuto   : MS when the side energy is small compared to mid,
                        L/R otherwise; decided per frame

  PCM input: 1152 samples per channel per call, oldest first, +-32768 scale.
  Encoder delay: ENC_DELAY (528) samples (polyphase + MDCT overlap).

  Reference: ISO 11172-3 dist10, toots/shine, LAME (structure only)
  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
*)

interface

uses
  SysUtils,
  MP3EncBitWriter,
  MP3EncQuantize,
  MP3EncHuffman,
  MP3EncMDCT,
  MP3EncPolyphase,
  MP3EncFrame,
  MP3EncRateCtrl,
  MP3EncPsy,
  MP3EncLoop;

const
  ENC_PCM_PER_FRAME  = 1152;  { 2 granules * 576 }
  ENC_GRANULES       = 2;
  ENC_DELAY          = 528;   { samples of delay introduced by the analysis }
  ENC_RESV_MAX_BITS  = 511 * 8;  { main_data_begin is a 9-bit byte offset }
  ENC_MAX_PART23     = 4095;     { part2_3_length is a 12-bit field }

type
  T1152 = array[0..ENC_PCM_PER_FRAME - 1] of Double;

  TEncConfig = record
    SrIdx   : Byte;  { 0 = 44100 Hz, 1 = 48000 Hz, 2 = 32000 Hz }
    BrIdx   : Byte;  { MPEG1 Layer III bitrate index 1..14 (ISO Table B.2) }
    Padding : Byte;  { 0 = standard, 1 = +1 padding slot }
  end;

  TEncPendingFrame = record
    HdrSI   : TBytes;   { header + side info, already final }
    Region  : Integer;  { main-data bytes that follow the side info }
    DataPos : Int64;    { logical main-data stream offset of that region }
  end;

  TMP3Encoder = record
    Cfg       : TEncConfig;
    Channels  : Byte;   { 1 = mono, 2 = stereo }
    QState    : TQuantState;
    MDCTSt    : TMDCTState;
    PolySt    : array[0..1] of TPolyphaseState;
    PrevSub   : array[0..1, 0..MDCT_SUBBANDS - 1, 0..MDCT_LONG_COEFS - 1] of Double;
    TargBits  : Integer;   { mean main-data bits per granule per channel }
    FrameBytes: Integer;   { frame size in bytes }
    Psy       : TPsyModel;
    Loop      : TLoopState;
    AutoMSThreshold : Double;  { EncodeFrameAuto uses MS when E(S) <= thr * E(M) }
    LowpassHz : Integer;       { MDCT lines above this frequency are zeroed (0 = none) }
    LowpassLine : Integer;     { first zeroed line (576 = none) }
    { bit reservoir and output queue }
    Reservoir : Boolean;
    ResvBits  : Integer;   { bits available before this frame's region (= main_data_begin*8) }
    ResvMax   : Integer;
    Stream    : TBytes;    { main-data bytes not yet emitted }
    StreamLen : Integer;
    StreamBase: Int64;     { logical offset of Stream[0] }
    NextDataPos: Int64;    { logical offset where the next frame's region starts }
    Pending   : array of TEncPendingFrame;
    FramesIn  : Integer;   { frames encoded }
    FramesOut : Integer;   { frames emitted }
    LastChannelMode : Byte;{ FRAME_CH_* used by the last encoded frame }
    LastStats : array[0..ENC_GRANULES - 1, 0..1] of TLoopStats;
  end;

{ Frame size in bytes: floor(144 * bitrate_bps / samplerate) + Padding. }
function EncFrameBytes(ABrIdx, ASrIdx, APadding: Byte): Integer;

{ Initialise a mono encoder. }
procedure EncInit(out AEnc: TMP3Encoder; const ACfg: TEncConfig);

{ Initialise a stereo encoder (L/R, MS or automatic). }
procedure EncInitStereo(out AEnc: TMP3Encoder; const ACfg: TEncConfig);

{ Identical to EncInitStereo; kept for API clarity. }
procedure EncInitJointStereo(out AEnc: TMP3Encoder; const ACfg: TEncConfig);

{ Enable / disable the bit reservoir (default: disabled). }
procedure EncEnableReservoir(var AEnc: TMP3Encoder; AEnable: Boolean);

{ Set the lowpass (Hz, 0 = none).  EncInit* choose a default from the
  bitrate per channel, like LAME does. }
procedure EncSetLowpass(var AEnc: TMP3Encoder; AHz: Integer);

{ Default lowpass frequency (Hz) for a stream bitrate (kbps, LAME table;
  mono streams pass 1.5x their bitrate).  0 = no lowpass. }
function EncDefaultLowpassHz(AKbpsPerChannel: Integer): Integer;

{ Encode 1152 mono PCM samples.  Returns the bytes of the frames completed
  by this call (exactly FrameBytes bytes when the reservoir is disabled). }
function EncodeFrame(var AEnc: TMP3Encoder; const APCM: T1152): TBytes;

{ Encode 1152 samples per channel as independent stereo (FRAME_CH_STEREO). }
function EncodeFrameStereo(var AEnc: TMP3Encoder;
  const APCM_L, APCM_R: T1152): TBytes;

{ Encode 1152 samples per channel with mid/side stereo (FRAME_CH_JOINT). }
function EncodeFrameMS(var AEnc: TMP3Encoder;
  const APCM_L, APCM_R: T1152): TBytes;

{ Encode 1152 samples per channel choosing MS or L/R per frame. }
function EncodeFrameAuto(var AEnc: TMP3Encoder;
  const APCM_L, APCM_R: T1152): TBytes;

{ Emit every frame still queued (reservoir).  Call once at the end. }
function EncFlush(var AEnc: TMP3Encoder): TBytes;

{ Number of encoded frames not yet emitted. }
function EncPendingFrames(const AEnc: TMP3Encoder): Integer;

{ L/R -> M/S on PCM (ISO 11172-3 matrix, energy preserving). }
procedure PCMToMS(const APCM_L, APCM_R: T1152;
  out APCM_M, APCM_S: T1152);

implementation

const
  C_BITRATE_BPS: array[0..14] of Integer = (
    0, 32000, 40000, 48000, 56000, 64000,
    80000, 96000, 112000, 128000, 160000, 192000, 224000, 256000, 320000);

  C_SAMPLERATE_HZ: array[0..2] of Integer = (44100, 48000, 32000);

  ISQRT2 = 0.70710678118654752;

type
  TFrameXr = array[0..ENC_GRANULES - 1, 0..1] of T576;

// ---------------------------------------------------------------------------

function EncFrameBytes(ABrIdx, ASrIdx, APadding: Byte): Integer;
begin
  Result := (144 * C_BITRATE_BPS[ABrIdx]) div C_SAMPLERATE_HZ[ASrIdx]
            + Integer(APadding);
end;

// ---------------------------------------------------------------------------

procedure InitCommon(out AEnc: TMP3Encoder; const ACfg: TEncConfig; AChannels: Integer);
var
  dataBits, siBits: Integer;
begin
  AEnc := Default(TMP3Encoder);
  AEnc.Cfg        := ACfg;
  AEnc.Channels   := AChannels;
  AEnc.FrameBytes := EncFrameBytes(ACfg.BrIdx, ACfg.SrIdx, ACfg.Padding);
  if AChannels = 1 then siBits := FRAME_SIDEINFO_MONO else siBits := FRAME_SIDEINFO_STEREO;
  dataBits      := AEnc.FrameBytes * 8 - 32 - siBits;
  AEnc.TargBits := dataBits div (ENC_GRANULES * AChannels);
  AEnc.AutoMSThreshold := 0.3;
  AEnc.LastChannelMode := FRAME_CH_MONO;

  HuffInit;
  QuantInit(AEnc.QState);
  MDCTInit(AEnc.MDCTSt);
  PolyphaseInit(AEnc.PolySt[0]);
  if AChannels > 1 then PolyphaseInit(AEnc.PolySt[1]);
  PsyInit(AEnc.Psy, ACfg.SrIdx);
  LoopInit(AEnc.Loop);
  { effective rate for the lowpass table: the LAME table is keyed by the
    total bitrate of a (joint) stereo stream; mono gets 1.5x its rate
    (measured: LAME mono 32 kbps keeps ~8 kHz, stereo 64 kbps ~11 kHz) }
  if AChannels = 1 then
    EncSetLowpass(AEnc, EncDefaultLowpassHz(C_BITRATE_BPS[ACfg.BrIdx] * 3 div 2000))
  else
    EncSetLowpass(AEnc, EncDefaultLowpassHz(C_BITRATE_BPS[ACfg.BrIdx] div 1000));
end;

function EncDefaultLowpassHz(AKbpsPerChannel: Integer): Integer;
const
  { LAME lame_init_params defaults (kbps per channel -> lowpass Hz) }
  KB: array[0..13] of Integer = (8,    16,   24,   32,   40,   48,   56,    64,    80,    96,    112,   128,   160,   192);
  LP: array[0..13] of Integer = (2000, 3700, 3900, 5500, 7000, 7500, 10000, 11000, 13500, 15300, 16000, 17500, 18600, 19700);
var
  i: Integer;
begin
  if AKbpsPerChannel >= 224 then Exit(0);   { no lowpass }
  for i := 0 to 13 do
    if AKbpsPerChannel <= KB[i] then Exit(LP[i]);
  Result := 20500;
end;

procedure EncSetLowpass(var AEnc: TMP3Encoder; AHz: Integer);
begin
  AEnc.LowpassHz := AHz;
  if AHz <= 0 then
    AEnc.LowpassLine := QUANT_GRANULE
  else begin
    AEnc.LowpassLine := Trunc(AHz * 1152.0 / C_SAMPLERATE_HZ[AEnc.Cfg.SrIdx]);
    if AEnc.LowpassLine > QUANT_GRANULE then AEnc.LowpassLine := QUANT_GRANULE;
    if AEnc.LowpassLine < 0 then AEnc.LowpassLine := 0;
  end;
end;

procedure EncInit(out AEnc: TMP3Encoder; const ACfg: TEncConfig);
begin
  InitCommon(AEnc, ACfg, 1);
end;

procedure EncInitStereo(out AEnc: TMP3Encoder; const ACfg: TEncConfig);
begin
  InitCommon(AEnc, ACfg, 2);
end;

procedure EncInitJointStereo(out AEnc: TMP3Encoder; const ACfg: TEncConfig);
begin
  InitCommon(AEnc, ACfg, 2);
end;

procedure EncEnableReservoir(var AEnc: TMP3Encoder; AEnable: Boolean);
begin
  AEnc.Reservoir := AEnable;
  if AEnable then AEnc.ResvMax := ENC_RESV_MAX_BITS else AEnc.ResvMax := 0;
end;

function EncPendingFrames(const AEnc: TMP3Encoder): Integer;
begin
  Result := Length(AEnc.Pending);
end;

// ---------------------------------------------------------------------------
// Analysis: PCM -> 576 MDCT lines for one granule of one channel
// ---------------------------------------------------------------------------

procedure AnalyseChannel(var AEnc: TMP3Encoder; const APCM: T1152;
  AGr, ACh: Integer; out AXr: T576);
var
  b, m, j, k: Integer;
  CurrSub : array[0..MDCT_SUBBANDS - 1, 0..MDCT_LONG_COEFS - 1] of Double;
  MDCTIn  : TMDCTInput;
  MDCTOut : TMDCTOutput;
  Block   : TPCMBlock;
  Sub     : TSubbandSamples;
begin
  { PCM normalised to +-1.0; ASamples[0] is the newest sample of the block }
  for j := 0 to 17 do begin
    for k := 0 to POLY_SUBBANDS - 1 do
      Block[k] := APCM[AGr * 576 + j * 32 + (31 - k)] * (1.0 / 32768.0);
    PolyphaseFilter(AEnc.PolySt[ACh], Block, Sub);
    for b := 0 to MDCT_SUBBANDS - 1 do
      CurrSub[b][j] := Sub[b];
  end;

  { frequency inversion compensation: odd subbands, odd time index }
  for b := 1 to MDCT_SUBBANDS - 1 do
    if Odd(b) then
      for j := 1 to 17 do
        if Odd(j) then
          CurrSub[b][j] := -CurrSub[b][j];

  for b := 0 to MDCT_SUBBANDS - 1 do
    for j := 0 to 17 do begin
      MDCTIn[b][j]      := AEnc.PrevSub[ACh][b][j];
      MDCTIn[b][18 + j] := CurrSub[b][j];
    end;

  MDCTProcess(AEnc.MDCTSt, MDCTIn, MDCTOut);
  for b := 0 to MDCT_SUBBANDS - 1 do
    for m := 0 to MDCT_LONG_COEFS - 1 do
      AXr[b * 18 + m] := MDCTOut[b][m];

  Move(CurrSub[0][0], AEnc.PrevSub[ACh][0][0], SizeOf(CurrSub));
end;

// ---------------------------------------------------------------------------
// Output queue helpers
// ---------------------------------------------------------------------------

procedure StreamAppend(var AEnc: TMP3Encoder; const AData: TBytes; AZeros: Integer);
var
  n: Integer;
begin
  n := Length(AData) + AZeros;
  if AEnc.StreamLen + n > Length(AEnc.Stream) then
    SetLength(AEnc.Stream, (AEnc.StreamLen + n) * 2 + 1024);
  if Length(AData) > 0 then
    Move(AData[0], AEnc.Stream[AEnc.StreamLen], Length(AData));
  if AZeros > 0 then
    FillChar(AEnc.Stream[AEnc.StreamLen + Length(AData)], AZeros, 0);
  Inc(AEnc.StreamLen, n);
end;

{ Append every pending frame whose main-data region is complete to AOut. }
procedure EmitCompleted(var AEnc: TMP3Encoder; var AOut: TBytes);
var
  pf: TEncPendingFrame;
  ofs, consumed, start, i: Integer;
begin
  while Length(AEnc.Pending) > 0 do begin
    pf := AEnc.Pending[0];
    if AEnc.StreamBase + AEnc.StreamLen < pf.DataPos + pf.Region then Break;
    ofs := Integer(pf.DataPos - AEnc.StreamBase);
    start := Length(AOut);
    SetLength(AOut, start + Length(pf.HdrSI) + pf.Region);
    if Length(pf.HdrSI) > 0 then
      Move(pf.HdrSI[0], AOut[start], Length(pf.HdrSI));
    if pf.Region > 0 then
      Move(AEnc.Stream[ofs], AOut[start + Length(pf.HdrSI)], pf.Region);
    { drop the consumed bytes and the frame }
    consumed := ofs + pf.Region;
    if AEnc.StreamLen > consumed then
      Move(AEnc.Stream[consumed], AEnc.Stream[0], AEnc.StreamLen - consumed);
    Dec(AEnc.StreamLen, consumed);
    Inc(AEnc.StreamBase, consumed);
    for i := 1 to Length(AEnc.Pending) - 1 do
      AEnc.Pending[i - 1] := AEnc.Pending[i];
    SetLength(AEnc.Pending, Length(AEnc.Pending) - 1);
    Inc(AEnc.FramesOut);
  end;
end;

// ---------------------------------------------------------------------------
// Frame core: psychoacoustics, allocation, loop, reservoir, assembly
// ---------------------------------------------------------------------------

function EncodeFrameCore(var AEnc: TMP3Encoder; var AXr: TFrameXr;
  AChannelMode, AModeExt: Byte): TBytes;
var
  n, k, g, c, siBits, regionBytes, mainBits: Integer;
  pool, nominal, carry, remaining, spare, extra, want, over, maxb, minb, used: Integer;
  usedTotal, usedBytes, newResv, stuffing, j: Integer;
  est   : array[0..3] of Double;
  targ  : array[0..3] of Double;
  xmin  : array[0..3] of TPsyBandArr;
  psyR  : array[0..3] of TPsyResult;
  sumEst, sumT, mean, v: Double;
  SI    : TFrameSideInfo;
  FCfg  : TFrameConfig;
  BW    : TMP3BitWriter;
  hdr, main: TBytes;
  pf    : TEncPendingFrame;
begin
  Result := nil;
  n := ENC_GRANULES * AEnc.Channels;
  if AEnc.Channels = 1 then siBits := FRAME_SIDEINFO_MONO else siBits := FRAME_SIDEINFO_STEREO;
  regionBytes := AEnc.FrameBytes - 4 - siBits div 8;
  mainBits    := regionBytes * 8;

  { lowpass: drop the lines above the cutoff }
  if AEnc.LowpassLine < QUANT_GRANULE then
    for k := 0 to n - 1 do begin
      g := k div AEnc.Channels; c := k mod AEnc.Channels;
      for j := AEnc.LowpassLine to QUANT_GRANULE - 1 do AXr[g][c][j] := 0.0;
    end;

  { psychoacoustic analysis of every granule / channel }
  for k := 0 to n - 1 do begin
    g := k div AEnc.Channels; c := k mod AEnc.Channels;
    PsyAnalyse(AEnc.Psy, AXr[g][c], psyR[k]);
  end;
  if (AChannelMode = FRAME_CH_JOINT) and (AEnc.Channels = 2) then
    { the noise of M and S is heard in both L and R: use the larger of the
      two thresholds for both channels }
    for g := 0 to ENC_GRANULES - 1 do begin
      for j := 0 to PSY_BANDS - 1 do begin
        v := psyR[g * 2].Xmin[j];
        if psyR[g * 2 + 1].Xmin[j] > v then v := psyR[g * 2 + 1].Xmin[j];
        psyR[g * 2].Xmin[j]     := v;
        psyR[g * 2 + 1].Xmin[j] := v;
      end;
      psyR[g * 2].EstBits     := PsyEstimateBits(AEnc.Psy, psyR[g * 2].Energy, psyR[g * 2].Xmin);
      psyR[g * 2 + 1].EstBits := PsyEstimateBits(AEnc.Psy, psyR[g * 2 + 1].Energy, psyR[g * 2 + 1].Xmin);
    end;
  for k := 0 to n - 1 do begin
    est[k]  := psyR[k].EstBits;
    xmin[k] := psyR[k].Xmin;
  end;

  { nominal bit targets proportional to the estimated demand }
  mean := mainBits / n;
  sumEst := 0.0;
  for k := 0 to n - 1 do sumEst := sumEst + est[k];
  for k := 0 to n - 1 do begin
    if sumEst > 1.0 then targ[k] := mainBits * est[k] / sumEst else targ[k] := mean;
    if targ[k] < 0.25 * mean then targ[k] := 0.25 * mean;
    if targ[k] > 2.5 * mean  then targ[k] := 2.5 * mean;
  end;
  sumT := 0.0;
  for k := 0 to n - 1 do sumT := sumT + targ[k];
  for k := 0 to n - 1 do targ[k] := targ[k] * mainBits / sumT;

  { encode granules sequentially; unused bits flow to the next ones }
  SI := Default(TFrameSideInfo);
  SI.MainDataBegin := AEnc.ResvBits div 8;
  pool  := AEnc.ResvBits + mainBits;
  carry := 0;
  usedTotal := 0;
  for k := 0 to n - 1 do begin
    g := k div AEnc.Channels; c := k mod AEnc.Channels;
    nominal := Round(targ[k]) + carry;
    remaining := 0;
    for j := k + 1 to n - 1 do remaining := remaining + Round(targ[j]);
    spare := pool - nominal - remaining;
    if spare < 0 then spare := 0;
    extra := 0;
    if AEnc.Reservoir then begin
      want := Round(est[k] * 1.3) - nominal;
      if want > 100 then begin
        extra := Round(spare * 0.6);
        if extra > want then extra := want;
      end;
      { keep the reservoir below 80 % of its capacity }
      over := (spare - extra) - Round(AEnc.ResvMax * 0.8);
      if over > 0 then extra := extra + over;
    end;
    maxb := nominal + extra;
    if maxb > pool - remaining then maxb := pool - remaining;
    if maxb > ENC_MAX_PART23 then maxb := ENC_MAX_PART23;
    if maxb < 0 then maxb := 0;
    { bits saved below the nominal share go to the reservoir; when it has no
      room for them they would be wasted, so spend them instead }
    minb := nominal - (AEnc.ResvMax - spare);
    if minb < 0 then minb := 0;
    if minb > maxb then minb := maxb;

    used := LoopEncodeGranule(AEnc.Loop, AEnc.QState, AXr[g][c], xmin[k],
      maxb, minb, AEnc.Cfg.SrIdx, SI.Gr[g][c], AEnc.LastStats[g][c]);
    Dec(pool, used);
    Inc(usedTotal, used);
    carry := nominal - used;
    if carry < 0 then carry := 0;
  end;

  { header + side info }
  FCfg := Default(TFrameConfig);
  FCfg.VersionBits     := FRAME_VER_MPEG1;
  FCfg.LayerBits       := FRAME_LAY_III;
  FCfg.ProtectionBit   := FRAME_NO_CRC;
  FCfg.BitrateIndex    := AEnc.Cfg.BrIdx;
  FCfg.SamplerateIndex := AEnc.Cfg.SrIdx;
  FCfg.Padding         := AEnc.Cfg.Padding;
  FCfg.ChannelMode     := AChannelMode;
  FCfg.ModeExt         := AModeExt;
  FCfg.Original        := 1;
  FCfg.Channels        := AEnc.Channels;
  FCfg.Granules        := ENC_GRANULES;
  AEnc.LastChannelMode := AChannelMode;

  BW := TMP3BitWriter.Create;
  try
    FrameWriteHeader(BW, FCfg);
    FrameWriteSideInfo(BW, FCfg, SI);
    hdr := BW.GetBytes;
  finally
    BW.Free;
  end;
  BW := TMP3BitWriter.Create;
  try
    FrameWriteMainData(BW, FCfg, SI);
    main := BW.GetBytes;
  finally
    BW.Free;
  end;
  usedBytes := Length(main);
  Assert(usedBytes = (usedTotal + 7) div 8, 'main data size mismatch');
  Assert(usedBytes * 8 <= AEnc.ResvBits + mainBits, 'main data overflow');

  { reservoir bookkeeping: bytes left in the regions written so far }
  newResv := AEnc.ResvBits + mainBits - usedBytes * 8;
  stuffing := 0;
  if newResv > AEnc.ResvMax then begin
    stuffing := (newResv - AEnc.ResvMax) div 8;
    newResv  := newResv - stuffing * 8;
  end;
  AEnc.ResvBits := newResv;

  { queue the frame; its main data starts main_data_begin bytes before its region }
  Assert(AEnc.StreamBase + AEnc.StreamLen = AEnc.NextDataPos - SI.MainDataBegin,
    'main_data_begin mismatch');
  pf.HdrSI   := hdr;
  pf.Region  := regionBytes;
  pf.DataPos := AEnc.NextDataPos;
  Inc(AEnc.NextDataPos, regionBytes);
  SetLength(AEnc.Pending, Length(AEnc.Pending) + 1);
  AEnc.Pending[Length(AEnc.Pending) - 1] := pf;
  StreamAppend(AEnc, main, stuffing);
  Inc(AEnc.FramesIn);

  EmitCompleted(AEnc, Result);
end;

// ---------------------------------------------------------------------------

function EncFlush(var AEnc: TMP3Encoder): TBytes;
var
  last: TEncPendingFrame;
  need: Int64;
begin
  Result := nil;
  if Length(AEnc.Pending) = 0 then Exit;
  last := AEnc.Pending[Length(AEnc.Pending) - 1];
  need := (last.DataPos + last.Region) - (AEnc.StreamBase + AEnc.StreamLen);
  if need > 0 then StreamAppend(AEnc, nil, Integer(need));
  AEnc.ResvBits := 0;
  EmitCompleted(AEnc, Result);
end;

// ---------------------------------------------------------------------------

function EncodeFrame(var AEnc: TMP3Encoder; const APCM: T1152): TBytes;
var
  Xr: TFrameXr;
  g: Integer;
begin
  for g := 0 to ENC_GRANULES - 1 do
    AnalyseChannel(AEnc, APCM, g, 0, Xr[g][0]);
  Result := EncodeFrameCore(AEnc, Xr, FRAME_CH_MONO, 0);
end;

function EncodeFrameStereo(var AEnc: TMP3Encoder;
  const APCM_L, APCM_R: T1152): TBytes;
var
  Xr: TFrameXr;
  g: Integer;
begin
  for g := 0 to ENC_GRANULES - 1 do begin
    AnalyseChannel(AEnc, APCM_L, g, 0, Xr[g][0]);
    AnalyseChannel(AEnc, APCM_R, g, 1, Xr[g][1]);
  end;
  Result := EncodeFrameCore(AEnc, Xr, FRAME_CH_STEREO, 0);
end;

procedure XrToMS(var AXr: TFrameXr);
var
  g, i: Integer;
  l, r: Double;
begin
  for g := 0 to ENC_GRANULES - 1 do
    for i := 0 to QUANT_GRANULE - 1 do begin
      l := AXr[g][0][i]; r := AXr[g][1][i];
      AXr[g][0][i] := (l + r) * ISQRT2;
      AXr[g][1][i] := (l - r) * ISQRT2;
    end;
end;

function EncodeFrameMS(var AEnc: TMP3Encoder;
  const APCM_L, APCM_R: T1152): TBytes;
var
  Xr: TFrameXr;
  g: Integer;
begin
  for g := 0 to ENC_GRANULES - 1 do begin
    AnalyseChannel(AEnc, APCM_L, g, 0, Xr[g][0]);
    AnalyseChannel(AEnc, APCM_R, g, 1, Xr[g][1]);
  end;
  XrToMS(Xr);
  Result := EncodeFrameCore(AEnc, Xr, FRAME_CH_JOINT, 2);
end;

function EncodeFrameAuto(var AEnc: TMP3Encoder;
  const APCM_L, APCM_R: T1152): TBytes;
var
  Xr: TFrameXr;
  g, i: Integer;
  eM, eS, l, r: Double;
begin
  eM := 0.0; eS := 0.0;
  for g := 0 to ENC_GRANULES - 1 do begin
    AnalyseChannel(AEnc, APCM_L, g, 0, Xr[g][0]);
    AnalyseChannel(AEnc, APCM_R, g, 1, Xr[g][1]);
    for i := 0 to QUANT_GRANULE - 1 do begin
      l := Xr[g][0][i]; r := Xr[g][1][i];
      eM := eM + Sqr(l + r);
      eS := eS + Sqr(l - r);
    end;
  end;
  if eS <= AEnc.AutoMSThreshold * eM then begin
    XrToMS(Xr);
    Result := EncodeFrameCore(AEnc, Xr, FRAME_CH_JOINT, 2);
  end else
    Result := EncodeFrameCore(AEnc, Xr, FRAME_CH_STEREO, 0);
end;

// ---------------------------------------------------------------------------

procedure PCMToMS(const APCM_L, APCM_R: T1152;
  out APCM_M, APCM_S: T1152);
var
  i: Integer;
begin
  for i := 0 to ENC_PCM_PER_FRAME - 1 do begin
    APCM_M[i] := (APCM_L[i] + APCM_R[i]) * ISQRT2;
    APCM_S[i] := (APCM_L[i] - APCM_R[i]) * ISQRT2;
  end;
end;

end.
