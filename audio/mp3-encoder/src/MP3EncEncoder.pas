unit MP3EncEncoder;

(*
  MP3EncEncoder.pas — MPEG1 Layer III encoder pipeline (mono / stereo / MS)

  Per channel and granule:
    Polyphase analysis  (MP3EncPolyphase) : 32 PCM samples -> 32 subbands
    MDCT + antialias    (MP3EncMDCT)      : 36 subband samples -> 18 lines
    Psychoacoustics     (MP3EncPsy)       : allowed noise per scalefactor band
                                            (on the MDCT lines; optionally
                                            ISO model 2 on a 1024-point FFT
                                            of the PCM for the long blocks)
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
                        L/R otherwise; decided per frame.  Every frame
                        says joint stereo in its header and only the
                        ms_stereo bit of mode_extension changes, as LAME
                        does: some decoders (ffmpeg) take a channel mode
                        change between the first frames for lost sync

  Window switching
    The subband samples of each new granule are scanned for attacks (energy
    jumps above 1.4 kHz in 2 ms segments).  The MDCT runs one granule behind
    the analysis so that the block type of a granule can depend on the next
    one: a granule with an early attack is coded with short blocks, the one
    before it with a start window, the one after with a stop window; a late
    attack (last third of the granule, where the start window is zero) only
    makes the next granule short.  Both channels share the block type.

  VBR (EncEnableVBR)
    Every granule is quantized in "quality mode": the coarsest quantization
    whose noise stays under the psychoacoustic threshold, shifted by the VBR
    quality (0 best .. 9 smallest files).  The frame then gets the lowest
    bitrate index whose main data, together with the bit reservoir, holds
    those bits.  When even 320 kbps is not enough the frame is coded as CBR
    at 320 kbps.

  PCM input: 1152 samples per channel per call, oldest first, +-32768 scale.
  Encoder delay: ENC_DELAY (1104) samples (polyphase + MDCT overlap + one
  granule of look-ahead for the window switching).

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
  ENC_DELAY          = 1104;  { analysis delay (528) + one granule of look-ahead }
  ENC_RESV_MAX_BITS  = 511 * 8;  { main_data_begin is a 9-bit byte offset }
  ENC_MAX_PART23     = 4095;     { part2_3_length is a 12-bit field }
  ENC_PSY_HIST       = 2048;     { PCM history per channel for the FFT model }
  { first history sample of the 1024-point FFT window of the granule being
    transformed: the long MDCT of subband granules n-2 and n-1 is centred
    1391.5 samples before the newest input sample (polyphase delay of
    255.5 - 31 samples, half a subband block, one granule of look-ahead and
    the granule itself) }
  ENC_PSY_WIN0       = ENC_PSY_HIST - 1904;

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

  TSubGranule = array[0..MDCT_SUBBANDS - 1, 0..MDCT_LONG_COEFS - 1] of Double;

  TMP3Encoder = record
    Cfg       : TEncConfig;
    Channels  : Byte;   { 1 = mono, 2 = stereo }
    QState    : TQuantState;
    MDCTSt    : TMDCTState;
    PolySt    : array[0..1] of TPolyphaseState;
    { window switching: subband samples of granules n-2 and n-1 per channel }
    SubOld    : array[0..1] of TSubGranule;
    SubPrev   : array[0..1] of TSubGranule;
    SegPrev   : array[0..1, 0..5] of Double;  { attack-detector segment energies }
    ShortPrev : Boolean;   { granule n-1 must use short blocks }
    LatePrev  : Boolean;   { granule n-1 had a late attack: granule n must be short }
    PrevType  : Integer;   { block type of the last coded granule }
    BlockType : array[0..ENC_GRANULES - 1] of Integer;  { of the frame being coded }
    SwitchMode: Integer;   { 0 = automatic, 1 = always long, 2 = always short }
    ShortGranules: Integer;  { statistics: granules coded with short blocks }
    { VBR }
    Vbr       : Boolean;
    VbrQuality: Integer;   { 0 (best) .. 9 }
    VbrNoiseScale: Double; { allowed noise x this factor }
    LastBrIdx : Integer;   { bitrate index of the last encoded frame }
    BrHist    : array[1..14] of Integer;  { frames per bitrate index }
    TargBits  : Integer;   { mean main-data bits per granule per channel }
    FrameBytes: Integer;   { frame size in bytes }
    Psy       : TPsyModel;
    { FFT psychoacoustic model (long blocks) of L, R, M and S }
    PsyFFT    : Boolean;
    PsyHist   : array[0..1, 0..ENC_PSY_HIST - 1] of Double;
    PsySt     : array[0..3] of TPsyFFTState;
    PsyRatio  : array[0..ENC_GRANULES - 1, 0..3] of TPsyBandArr;
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
    LastMS    : Boolean;   { the last encoded frame used mid/side }
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

{ Window switching: 0 = automatic (default), 1 = long blocks only,
  2 = short blocks only (testing). }
procedure EncSetWindowSwitching(var AEnc: TMP3Encoder; AMode: Integer);

var
  { window switching mode given to every new encoder (EncInit*) }
  EncDefaultWindowSwitching: Integer = 0;
  { psychoacoustic model of the long blocks for every new encoder:
    0 = model on the MDCT lines (default), 1 = FFT model (ISO model 2).
    Measured with PEAQ the two are on a par in CBR; the VBR quality scale
    is calibrated for model 0 (model 1 gives tonal music more bits and
    dense music fewer) }
  EncDefaultPsyModel: Integer = 0;

{ Variable bitrate: AQuality 0 (best, ~230-260 kbps on stereo music) ..
  9 (smallest).  Enables the bit reservoir and sets a lowpass for the
  quality.  The configured BrIdx is ignored (each frame picks its own). }
procedure EncEnableVBR(var AEnc: TMP3Encoder; AQuality: Integer);

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

uses
  System.Math;

const
  C_BITRATE_BPS: array[0..14] of Integer = (
    0, 32000, 40000, 48000, 56000, 64000,
    80000, 96000, 112000, 128000, 160000, 192000, 224000, 256000, 320000);

  C_SAMPLERATE_HZ: array[0..2] of Integer = (44100, 48000, 32000);

  ISQRT2 = 0.70710678118654752;
  EST_SCALE_LONG  = 2.5;   { bit demand estimate -> coded bits, long blocks }
  EST_SCALE_SHORT = 4.0;   { idem, short blocks }

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
  dataBits, siBits, k: Integer;
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
  AEnc.SwitchMode := EncDefaultWindowSwitching;

  HuffInit;
  QuantInit(AEnc.QState);
  MDCTInit(AEnc.MDCTSt);
  PolyphaseInit(AEnc.PolySt[0]);
  if AChannels > 1 then PolyphaseInit(AEnc.PolySt[1]);
  PsyInit(AEnc.Psy, ACfg.SrIdx);
  AEnc.PsyFFT := EncDefaultPsyModel = 1;
  for k := 0 to 3 do PsyFFTReset(AEnc.PsySt[k]);
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

procedure EncSetWindowSwitching(var AEnc: TMP3Encoder; AMode: Integer);
begin
  AEnc.SwitchMode := AMode;
end;

procedure EncEnableVBR(var AEnc: TMP3Encoder; AQuality: Integer);
const
  { equivalent (stereo) bitrate of each quality, for the lowpass table }
  EQ_KBPS: array[0..9] of Integer = (256, 224, 192, 176, 160, 128, 112, 96, 80, 64);
  { allowed noise relative to the masking threshold (dB); calibrated so that
    stereo music lands near the bitrates of LAME -V0 .. -V9 }
  NOISE_DB: array[0..9] of Double = (0, 2, 4, 6, 8, 9.5, 11, 11.5, 12, 12.5);
var
  kb: Integer;
begin
  AQuality := EnsureRange(AQuality, 0, 9);
  AEnc.Vbr := True;
  AEnc.VbrQuality := AQuality;
  AEnc.VbrNoiseScale := Power(10.0, NOISE_DB[AQuality] / 10.0);
  EncEnableReservoir(AEnc, True);
  kb := EQ_KBPS[AQuality];
  if AEnc.Channels = 1 then kb := kb * 3 div 4;
  if AEnc.Channels = 1 then
    EncSetLowpass(AEnc, EncDefaultLowpassHz(kb * 3 div 2))
  else
    EncSetLowpass(AEnc, EncDefaultLowpassHz(kb));
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

{ Polyphase analysis of one granule (18 x 32 subband samples). }
procedure SubbandGranule(var AEnc: TMP3Encoder; const APCM: T1152;
  AGr, ACh: Integer; out ASub: TSubGranule);
var
  b, j, k: Integer;
  Block   : TPCMBlock;
  Sub     : TSubbandSamples;
begin
  { PCM normalised to +-1.0; ASamples[0] is the newest sample of the block }
  for j := 0 to 17 do begin
    for k := 0 to POLY_SUBBANDS - 1 do
      Block[k] := APCM[AGr * 576 + j * 32 + (31 - k)] * (1.0 / 32768.0);
    PolyphaseFilter(AEnc.PolySt[ACh], Block, Sub);
    for b := 0 to MDCT_SUBBANDS - 1 do
      ASub[b][j] := Sub[b];
  end;
  { frequency inversion compensation: odd subbands, odd time index }
  for b := 1 to MDCT_SUBBANDS - 1 do
    if Odd(b) then
      for j := 1 to 17 do
        if Odd(j) then
          ASub[b][j] := -ASub[b][j];
end;

const
  ATTACK_RATIO = 10.0;    { segment energy jump (10 dB) }
  ATTACK_FLOOR = 1.0e-6;  { ignore jumps below ~ -60 dBFS }

{ Attack detection on a new granule: energies of six segments of 3 subband
  samples (about 2 ms) above subband 0, each compared with the mean of the
  three previous segments.  AEarly: attack in samples 0..11 (covered by the
  short windows of this granule); ALate: attack in samples 12..17 (the start
  window is zero there, so only the next granule needs short blocks). }
procedure DetectAttack(var AEnc: TMP3Encoder; ACh: Integer; const ASub: TSubGranule;
  out AEarly, ALate: Boolean);
var
  e: array[0..11] of Double;
  s, b, j: Integer;
  ref, v: Double;
begin
  AEarly := False; ALate := False;
  for s := 0 to 5 do e[s] := AEnc.SegPrev[ACh][s];
  for s := 0 to 5 do begin
    v := 0.0;
    for b := 1 to MDCT_SUBBANDS - 1 do
      for j := 3 * s to 3 * s + 2 do v := v + Sqr(ASub[b][j]);
    e[6 + s] := v;
  end;
  for s := 6 to 11 do begin
    ref := (e[s - 1] + e[s - 2] + e[s - 3]) / 3.0;
    if (e[s] > ATTACK_FLOOR) and (e[s] > ATTACK_RATIO * ref) then
      if s < 10 then AEarly := True else ALate := True;
  end;
  for s := 0 to 5 do AEnc.SegPrev[ACh][s] := e[6 + s];
end;

{ Block type of granule n-1 from its own short flag, the next one's and the
  previous block type (ISO window sequence rules). }
function DecideBlockType(var AEnc: TMP3Encoder; AShortCur, AShortNext: Boolean): Integer;
begin
  case AEnc.SwitchMode of
    1: Exit(0);
    2: Exit(2);
  end;
  if AShortCur then Result := 2
  else if AShortNext then begin
    { a start window cannot follow a short block }
    if AEnc.PrevType = 2 then Result := 2 else Result := 1;
  end
  else if AEnc.PrevType = 2 then Result := 3
  else Result := 0;
end;

{ MDCT of the granule held in SubOld/SubPrev with block type ABlockType.
  Short blocks are returned in bit-stream order (sfb, window, line). }
procedure MDCTGranule(var AEnc: TMP3Encoder; ACh, ABlockType: Integer; out AXr: T576);
var
  b, m, j, w, f, sfb, lo, wid: Integer;
  MDCTIn  : TMDCTInput;
  MDCTOut : TMDCTOutput;
begin
  for b := 0 to MDCT_SUBBANDS - 1 do
    for j := 0 to 17 do begin
      MDCTIn[b][j]      := AEnc.SubOld[ACh][b][j];
      MDCTIn[b][18 + j] := AEnc.SubPrev[ACh][b][j];
    end;
  MDCTProcessType(AEnc.MDCTSt, MDCTIn, MDCTOut, ABlockType);
  if ABlockType <> 2 then begin
    for b := 0 to MDCT_SUBBANDS - 1 do
      for m := 0 to MDCT_LONG_COEFS - 1 do
        AXr[b * 18 + m] := MDCTOut[b][m];
    Exit;
  end;
  { short: window w, line f = 6b + m is MDCTOut[b][3m + w] }
  for sfb := 0 to QUANT_SFB_SMAX - 1 do begin
    lo  := QuantSfbShort(AEnc.Cfg.SrIdx, sfb);
    wid := QuantSfbShort(AEnc.Cfg.SrIdx, sfb + 1) - lo;
    for w := 0 to 2 do
      for f := lo to lo + wid - 1 do
        AXr[3 * lo + w * wid + (f - lo)] := MDCTOut[f div 6][3 * (f mod 6) + w];
  end;
end;

{ Short spectrum in bit-stream order -> [window][line] for the psy model. }
procedure ShortToSpec(ASrIdx: Integer; const AXr: T576; out ASpec: TPsyShortSpec);
var
  sfb, w, f, lo, wid: Integer;
begin
  for sfb := 0 to QUANT_SFB_SMAX - 1 do begin
    lo  := QuantSfbShort(ASrIdx, sfb);
    wid := QuantSfbShort(ASrIdx, sfb + 1) - lo;
    for w := 0 to 2 do
      for f := lo to lo + wid - 1 do
        ASpec[w][f] := AXr[3 * lo + w * wid + (f - lo)];
  end;
end;

{ FFT psychoacoustic model of the granule about to be transformed: the new
  input granule AGr enters the PCM history, then the model runs on the
  1024 samples centred on the MDCT of that granule (L and R; with stereo
  also M and S, for mid/side coding). }
procedure PsyGranule(var AEnc: TMP3Encoder; const APCM_L, APCM_R: T1152; AGr: Integer);
var
  ch, i: Integer;
  buf: TPsyFFTBuf;
begin
  for ch := 0 to AEnc.Channels - 1 do begin
    Move(AEnc.PsyHist[ch][576], AEnc.PsyHist[ch][0], (ENC_PSY_HIST - 576) * SizeOf(Double));
    for i := 0 to 575 do
      if ch = 0 then AEnc.PsyHist[0][ENC_PSY_HIST - 576 + i] := APCM_L[AGr * 576 + i]
      else AEnc.PsyHist[1][ENC_PSY_HIST - 576 + i] := APCM_R[AGr * 576 + i];
    for i := 0 to PSY_FFT_LONG - 1 do buf[i] := AEnc.PsyHist[ch][ENC_PSY_WIN0 + i];
    PsyAnalyseFFT(AEnc.Psy, AEnc.PsySt[ch], buf, AEnc.PsyRatio[AGr][ch]);
  end;
  if AEnc.Channels = 2 then begin
    for i := 0 to PSY_FFT_LONG - 1 do
      buf[i] := (AEnc.PsyHist[0][ENC_PSY_WIN0 + i] + AEnc.PsyHist[1][ENC_PSY_WIN0 + i]) * ISQRT2;
    PsyAnalyseFFT(AEnc.Psy, AEnc.PsySt[2], buf, AEnc.PsyRatio[AGr][2]);
    for i := 0 to PSY_FFT_LONG - 1 do
      buf[i] := (AEnc.PsyHist[0][ENC_PSY_WIN0 + i] - AEnc.PsyHist[1][ENC_PSY_WIN0 + i]) * ISQRT2;
    PsyAnalyseFFT(AEnc.Psy, AEnc.PsySt[3], buf, AEnc.PsyRatio[AGr][3]);
  end;
end;

{ Analysis of one frame: the two new granules enter the look-ahead and the
  two granules before them are transformed into AXr. }
procedure AnalyseFrame(var AEnc: TMP3Encoder; const APCM_L, APCM_R: T1152;
  var AXr: TFrameXr);
var
  g, ch: Integer;
  sub: array[0..1] of TSubGranule;
  early, late, shortNew: Boolean;
begin
  for g := 0 to ENC_GRANULES - 1 do begin
    shortNew := AEnc.LatePrev;
    AEnc.LatePrev := False;
    for ch := 0 to AEnc.Channels - 1 do begin
      if ch = 0 then SubbandGranule(AEnc, APCM_L, g, 0, sub[0])
      else SubbandGranule(AEnc, APCM_R, g, 1, sub[1]);
      DetectAttack(AEnc, ch, sub[ch], early, late);
      if early then shortNew := True;
      if late then AEnc.LatePrev := True;
    end;
    AEnc.BlockType[g] := DecideBlockType(AEnc, AEnc.ShortPrev, shortNew);
    if AEnc.PsyFFT then PsyGranule(AEnc, APCM_L, APCM_R, g);
    for ch := 0 to AEnc.Channels - 1 do begin
      MDCTGranule(AEnc, ch, AEnc.BlockType[g], AXr[g][ch]);
      AEnc.SubOld[ch] := AEnc.SubPrev[ch];
      AEnc.SubPrev[ch] := sub[ch];
    end;
    AEnc.PrevType := AEnc.BlockType[g];
    AEnc.ShortPrev := shortNew;
    if AEnc.BlockType[g] = 2 then Inc(AEnc.ShortGranules);
  end;
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

procedure XrToMS(var AXr: TFrameXr); forward;

type
  TFramePsy = record
    Est   : array[0..3] of Double;          { bit demand per granule/channel }
    Xmin  : array[0..3] of TPsyBandArr;     { allowed noise, long blocks }
    XminS : array[0..3] of TPsyShortArr;    { allowed noise, short blocks }
  end;

{ Lowpass and psychoacoustic analysis of a frame (index k = granule *
  channels + channel).  AXr holds L/R (or mono) spectra; with AMS it is
  converted to mid/side and the thresholds are combined as explained below. }
procedure FramePsy(var AEnc: TMP3Encoder; var AXr: TFrameXr; AMS: Boolean;
  out AP: TFramePsy);
var
  n, k, g, c, j, w, ss: Integer;
  psyR  : array[0..3] of TPsyResult;
  psyS  : array[0..3] of TPsyShortResult;
  spec  : TPsyShortSpec;
  tmpL  : TPsyBandArr;
  tmpS  : TPsyShortArr;
  v     : Double;
begin
  AP := Default(TFramePsy);
  n := ENC_GRANULES * AEnc.Channels;
  { lowpass: drop the lines above the cutoff }
  if AEnc.LowpassLine < QUANT_GRANULE then
    for k := 0 to n - 1 do begin
      g := k div AEnc.Channels; c := k mod AEnc.Channels;
      if AEnc.BlockType[g] = 2 then begin
        { short blocks: one third of the lines per window }
        ShortToSpec(AEnc.Cfg.SrIdx, AXr[g][c], spec);
        for w := 0 to 2 do
          for j := AEnc.LowpassLine div 3 to 191 do spec[w][j] := 0.0;
        for ss := 0 to QUANT_SFB_SMAX - 1 do
          for w := 0 to 2 do
            for j := QuantSfbShort(AEnc.Cfg.SrIdx, ss) to QuantSfbShort(AEnc.Cfg.SrIdx, ss + 1) - 1 do
              AXr[g][c][3 * QuantSfbShort(AEnc.Cfg.SrIdx, ss) +
                w * (QuantSfbShort(AEnc.Cfg.SrIdx, ss + 1) - QuantSfbShort(AEnc.Cfg.SrIdx, ss)) +
                (j - QuantSfbShort(AEnc.Cfg.SrIdx, ss))] := spec[w][j];
      end else
        for j := AEnc.LowpassLine to QUANT_GRANULE - 1 do AXr[g][c][j] := 0.0;
    end;

  { psychoacoustic analysis of every granule / channel }
  for k := 0 to n - 1 do begin
    g := k div AEnc.Channels; c := k mod AEnc.Channels;
    if AEnc.BlockType[g] = 2 then begin
      ShortToSpec(AEnc.Cfg.SrIdx, AXr[g][c], spec);
      PsyAnalyseShort(AEnc.Psy, spec, psyS[k]);
    end else begin
      PsyAnalyse(AEnc.Psy, AXr[g][c], psyR[k]);
      if AEnc.PsyFFT then PsyApplyRatio(AEnc.Psy, AEnc.PsyRatio[g][c], psyR[k]);
    end;
  end;
  if AMS and (AEnc.Channels = 2) then begin
    { L = (M + S)/sqrt2 and R = (M - S)/sqrt2: the noise energies of M and S
      add up in both L and R (halved), so with the same allowed noise t in M
      and S the noise in L and R is t.  t must stay under both the L and
      the R threshold.  The thresholds come from the L/R analysis above.
      Each of M and S must also stay under the threshold of its own
      spectrum: a weak S below the L/R threshold would otherwise be dropped,
      and noise in S (opposite phase in L and R) is easier to hear than the
      L/R model predicts (binaural unmasking). }
    XrToMS(AXr);
    for g := 0 to ENC_GRANULES - 1 do
      if AEnc.BlockType[g] = 2 then begin
        for j := 0 to QUANT_SFB_SMAX - 1 do
          for w := 0 to 2 do begin
            v := Min(psyS[g * 2].Xmin[j][w], psyS[g * 2 + 1].Xmin[j][w]);
            psyS[g * 2].Xmin[j][w] := v;
            psyS[g * 2 + 1].Xmin[j][w] := v;
          end;
        for c := 0 to 1 do begin
          ShortToSpec(AEnc.Cfg.SrIdx, AXr[g][c], spec);
          tmpS := psyS[g * 2 + c].Xmin;
          PsyAnalyseShort(AEnc.Psy, spec, psyS[g * 2 + c]);
          for j := 0 to QUANT_SFB_SMAX - 1 do
            for w := 0 to 2 do
              psyS[g * 2 + c].Xmin[j][w] := Min(psyS[g * 2 + c].Xmin[j][w], tmpS[j][w]);
          psyS[g * 2 + c].EstBits := PsyEstimateBitsShort(AEnc.Psy, psyS[g * 2 + c].Energy, psyS[g * 2 + c].Xmin);
        end;
      end else begin
        for j := 0 to PSY_BANDS - 1 do begin
          v := Min(psyR[g * 2].Xmin[j], psyR[g * 2 + 1].Xmin[j]);
          psyR[g * 2].Xmin[j]     := v;
          psyR[g * 2 + 1].Xmin[j] := v;
        end;
        for c := 0 to 1 do begin
          tmpL := psyR[g * 2 + c].Xmin;
          PsyAnalyse(AEnc.Psy, AXr[g][c], psyR[g * 2 + c]);
          if AEnc.PsyFFT then PsyApplyRatio(AEnc.Psy, AEnc.PsyRatio[g][2 + c], psyR[g * 2 + c]);
          for j := 0 to PSY_BANDS - 1 do
            psyR[g * 2 + c].Xmin[j] := Min(psyR[g * 2 + c].Xmin[j], tmpL[j]);
          psyR[g * 2 + c].EstBits := PsyEstimateBits(AEnc.Psy, psyR[g * 2 + c].Energy, psyR[g * 2 + c].Xmin);
        end;
      end;
  end;
  for k := 0 to n - 1 do begin
    g := k div AEnc.Channels;
    if AEnc.BlockType[g] = 2 then begin
      AP.Est[k] := psyS[k].EstBits;
      AP.XminS[k] := psyS[k].Xmin;
    end else begin
      AP.Est[k]  := psyR[k].EstBits;
      AP.Xmin[k] := psyR[k].Xmin;
    end;
  end;

end;


{ AXr holds L/R (or mono) spectra; with FRAME_CH_JOINT and ms_stereo in
  AModeExt the core converts them to mid/side after the psychoacoustic
  analysis. }
function EncodeFrameCore(var AEnc: TMP3Encoder; var AXr: TFrameXr;
  AChannelMode, AModeExt: Byte): TBytes;
var
  n, k, g, c, siBits, regionBytes, mainBits: Integer;
  pool, nominal, carry, remaining, spare, extra, want, over, maxb, minb, used: Integer;
  usedTotal, usedBytes, newResv, stuffing, j, brIdx, padding, b, w: Integer;
  vbrDone: Boolean;
  est   : array[0..3] of Double;
  targ  : array[0..3] of Double;
  xmin  : array[0..3] of TPsyBandArr;
  xminS : array[0..3] of TPsyShortArr;
  FP    : TFramePsy;
  sumEst, sumT, mean: Double;
  SI    : TFrameSideInfo;
  FCfg  : TFrameConfig;
  BW    : TMP3BitWriter;
  hdr, main: TBytes;
  pf    : TEncPendingFrame;
begin
  Result := nil;
  n := ENC_GRANULES * AEnc.Channels;
  if AEnc.Channels = 1 then siBits := FRAME_SIDEINFO_MONO else siBits := FRAME_SIDEINFO_STEREO;
  brIdx   := AEnc.Cfg.BrIdx;
  padding := AEnc.Cfg.Padding;

  FramePsy(AEnc, AXr, (AChannelMode = FRAME_CH_JOINT) and (AModeExt and 2 <> 0) and (AEnc.Channels = 2), FP);
  for k := 0 to n - 1 do begin
    { the psychoacoustic estimate (0.5 log2(E/xmin) per line) leaves out
      the Huffman and scalefactor overhead: bits coded / estimate measured
      in quality mode ~ 2.5 for long blocks and 3-8 for short ones }
    if AEnc.BlockType[k div AEnc.Channels] = 2 then
      est[k] := FP.Est[k] * EST_SCALE_SHORT
    else
      est[k] := FP.Est[k] * EST_SCALE_LONG;
    xmin[k] := FP.Xmin[k];
    xminS[k] := FP.XminS[k];
    if AEnc.Vbr then begin
      for j := 0 to PSY_BANDS - 1 do xmin[k][j] := xmin[k][j] * AEnc.VbrNoiseScale;
      for j := 0 to QUANT_SFB_SMAX - 1 do
        for w := 0 to 2 do xminS[k][j][w] := xminS[k][j][w] * AEnc.VbrNoiseScale;
    end;
  end;

  SI := Default(TFrameSideInfo);
  vbrDone := False;
  usedTotal := 0;
  if AEnc.Vbr then begin
    { quality mode: the fewest bits that keep the noise under the threshold }
    padding := 0;
    for k := 0 to n - 1 do begin
      g := k div AEnc.Channels; c := k mod AEnc.Channels;
      if AEnc.BlockType[g] = 2 then
        used := LoopEncodeGranuleShort(AEnc.Loop, AEnc.QState, AXr[g][c], xminS[k],
          ENC_MAX_PART23, 0, AEnc.Cfg.SrIdx, SI.Gr[g][c], AEnc.LastStats[g][c])
      else
        used := LoopEncodeGranule(AEnc.Loop, AEnc.QState, AXr[g][c], xmin[k],
          ENC_MAX_PART23, 0, AEnc.Cfg.SrIdx, SI.Gr[g][c], AEnc.LastStats[g][c], AEnc.BlockType[g]);
      Inc(usedTotal, used);
    end;
    { lowest bitrate whose frame (plus the reservoir) holds them }
    for b := 1 to 14 do
      if AEnc.ResvBits + (EncFrameBytes(b, AEnc.Cfg.SrIdx, 0) - 4 - siBits div 8) * 8 >= usedTotal then begin
        brIdx := b; vbrDone := True; Break;
      end;
    if not vbrDone then begin
      brIdx := 14;            { too many bits even at 320 kbps: CBR at 320 }
      SI := Default(TFrameSideInfo);
      usedTotal := 0;
    end;
  end;
  regionBytes := EncFrameBytes(brIdx, AEnc.Cfg.SrIdx, padding) - 4 - siBits div 8;
  mainBits    := regionBytes * 8;

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
  SI.MainDataBegin := AEnc.ResvBits div 8;
  pool  := AEnc.ResvBits + mainBits;
  carry := 0;
  if not vbrDone then
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

    if AEnc.BlockType[g] = 2 then
      used := LoopEncodeGranuleShort(AEnc.Loop, AEnc.QState, AXr[g][c], xminS[k],
        maxb, minb, AEnc.Cfg.SrIdx, SI.Gr[g][c], AEnc.LastStats[g][c])
    else
      used := LoopEncodeGranule(AEnc.Loop, AEnc.QState, AXr[g][c], xmin[k],
        maxb, minb, AEnc.Cfg.SrIdx, SI.Gr[g][c], AEnc.LastStats[g][c], AEnc.BlockType[g]);
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
  FCfg.BitrateIndex    := brIdx;
  FCfg.SamplerateIndex := AEnc.Cfg.SrIdx;
  FCfg.Padding         := padding;
  AEnc.LastBrIdx := brIdx;
  Inc(AEnc.BrHist[brIdx]);
  FCfg.ChannelMode     := AChannelMode;
  FCfg.ModeExt         := AModeExt;
  FCfg.Original        := 1;
  FCfg.Channels        := AEnc.Channels;
  FCfg.Granules        := ENC_GRANULES;
  AEnc.LastChannelMode := AChannelMode;
  AEnc.LastMS := (AChannelMode = FRAME_CH_JOINT) and (AModeExt and 2 <> 0);

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
begin
  AnalyseFrame(AEnc, APCM, APCM, Xr);
  Result := EncodeFrameCore(AEnc, Xr, FRAME_CH_MONO, 0);
end;

function EncodeFrameStereo(var AEnc: TMP3Encoder;
  const APCM_L, APCM_R: T1152): TBytes;
var
  Xr: TFrameXr;
begin
  AnalyseFrame(AEnc, APCM_L, APCM_R, Xr);
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
begin
  AnalyseFrame(AEnc, APCM_L, APCM_R, Xr);
  Result := EncodeFrameCore(AEnc, Xr, FRAME_CH_JOINT, 2);
end;

function EncodeFrameAuto(var AEnc: TMP3Encoder;
  const APCM_L, APCM_R: T1152): TBytes;
var
  Xr, X1, X2: TFrameXr;
  g, i: Integer;
  eM, eS, l, r, estLR, estMS: Double;
  P1, P2: TFramePsy;
  useMS: Boolean;
begin
  eM := 0.0; eS := 0.0;
  AnalyseFrame(AEnc, APCM_L, APCM_R, Xr);
  for g := 0 to ENC_GRANULES - 1 do begin
    for i := 0 to QUANT_GRANULE - 1 do begin
      l := Xr[g][0][i]; r := Xr[g][1][i];
      eM := eM + Sqr(l + r);
      eS := eS + Sqr(l - r);
    end;
  end;
  { MS only when the side signal is clearly weaker, and then only if the
    psychoacoustic model expects fewer bits for M/S than for L/R }
  useMS := eS <= AEnc.AutoMSThreshold * eM;
  if useMS then begin
    X1 := Xr; X2 := Xr;
    FramePsy(AEnc, X1, False, P1);
    FramePsy(AEnc, X2, True, P2);
    estLR := 0.0; estMS := 0.0;
    for i := 0 to ENC_GRANULES * 2 - 1 do begin
      estLR := estLR + P1.Est[i];
      estMS := estMS + P2.Est[i];
    end;
    useMS := estMS < estLR;
  end;
  if useMS then begin
    Result := EncodeFrameCore(AEnc, Xr, FRAME_CH_JOINT, 2);
  end else
    Result := EncodeFrameCore(AEnc, Xr, FRAME_CH_JOINT, 0);
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
