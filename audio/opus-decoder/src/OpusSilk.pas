unit OpusSilk;

{
  OpusSilk.pas - SILK decoder (RFC 6716 section 4.2)

  Port of libopus 1.5.2 silk/ decoder: dec_API.c, decode_frame.c,
  decode_indices.c, decode_parameters.c, decode_pulses.c, shell_coder.c,
  code_signs.c, decode_pitch.c, decode_core.c, NLSF_decode.c, NLSF_unpack.c,
  gain_quant.c, stereo_decode_pred.c, stereo_MS_to_LR.c, PLC.c, CNG.c,
  decoder_set_fs.c, init_decoder.c, resampler.c, resampler_private_up2_HQ.c,
  resampler_private_IIR_FIR.c. Copyright (c) 2006-2011 Skype Limited,
  Xiph.Org Foundation; BSD license. Fixed-point, bit-exact with the reference.

  Output: interleaved int16 at 48 kHz (API sample rate fixed to 48000).

  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  SysUtils, Math,
  OpusEntDec,
  OpusSilkTables,
  OpusSilkMath;

const
  SILK_FLAG_DECODE_NORMAL = 0;
  SILK_FLAG_PACKET_LOST   = 1;
  SILK_FLAG_DECODE_LBRR   = 2;
  SILK_API_FS_HZ          = 48000;

type
  TSilkDecControl = record
    nChannelsAPI      : Integer;
    nChannelsInternal : Integer;
    internalSampleRate: Integer;
    payloadSize_ms    : Integer;
    prevPitchLag      : Integer;
  end;

  TSilkNLSFCB = record
    nVectors          : Integer;
    order             : Integer;
    quantStepSize_Q16 : Integer;
    invQuantStepSize_Q6: Integer;
    CB1_NLSF_Q8       : PByte;
    CB1_Wght_Q9       : PSmallInt;
    CB1_iCDF          : PByte;
    pred_Q8           : PByte;
    ec_sel            : PByte;
    ec_iCDF           : PByte;
    deltaMin_Q15      : PSmallInt;
  end;
  PSilkNLSFCB = ^TSilkNLSFCB;

  TSilkResamplerState = record
    sIIR         : array[0..5] of Integer;
    sFIR16       : array[0..35] of SmallInt;
    delayBuf     : array[0..47] of SmallInt;
    resamplerFunction: Integer;   // 0 copy, 1 up2 HQ, 2 IIR_FIR
    batchSize    : Integer;
    invRatio_Q16 : Integer;
    Fs_in_kHz    : Integer;
    Fs_out_kHz   : Integer;
    inputDelay   : Integer;
  end;

  TSideInfoIndices = record
    GainsIndices     : array[0..SILK_MAX_NB_SUBFR - 1] of ShortInt;
    LTPIndex         : array[0..SILK_MAX_NB_SUBFR - 1] of ShortInt;
    NLSFIndices      : array[0..SILK_MAX_LPC_ORDER] of ShortInt;
    lagIndex         : SmallInt;
    contourIndex     : ShortInt;
    signalType       : ShortInt;
    quantOffsetType  : ShortInt;
    NLSFInterpCoef_Q2: ShortInt;
    PERIndex         : ShortInt;
    LTP_scaleIndex   : ShortInt;
    Seed             : ShortInt;
  end;

  TSilkDecoderControl = record
    pitchL       : array[0..SILK_MAX_NB_SUBFR - 1] of Integer;
    Gains_Q16    : array[0..SILK_MAX_NB_SUBFR - 1] of Integer;
    PredCoef_Q12 : array[0..1, 0..SILK_MAX_LPC_ORDER - 1] of SmallInt;
    LTPCoef_Q14  : array[0..SILK_LTP_ORDER * SILK_MAX_NB_SUBFR - 1] of SmallInt;
    LTP_scale_Q14: Integer;
  end;

  TSilkPLC = record
    pitchL_Q8        : Integer;
    LTPCoef_Q14      : array[0..SILK_LTP_ORDER - 1] of SmallInt;
    prevLPC_Q12      : array[0..SILK_MAX_LPC_ORDER - 1] of SmallInt;
    last_frame_lost  : Integer;
    rand_seed        : Integer;
    randScale_Q14    : SmallInt;
    conc_energy      : Integer;
    conc_energy_shift: Integer;
    prevLTP_scale_Q14: SmallInt;
    prevGain_Q16     : array[0..1] of Integer;
    fs_kHz           : Integer;
    nb_subfr         : Integer;
    subfr_length     : Integer;
  end;

  TSilkCNG = record
    CNG_exc_buf_Q14  : array[0..SILK_MAX_FRAME_LENGTH - 1] of Integer;
    CNG_smth_NLSF_Q15: array[0..SILK_MAX_LPC_ORDER - 1] of SmallInt;
    CNG_synth_state  : array[0..SILK_MAX_LPC_ORDER - 1] of Integer;
    CNG_smth_Gain_Q16: Integer;
    rand_seed        : Integer;
    fs_kHz           : Integer;
  end;

  TSilkChannelState = record
    prev_gain_Q16    : Integer;
    exc_Q14          : array[0..SILK_MAX_FRAME_LENGTH - 1] of Integer;
    sLPC_Q14_buf     : array[0..SILK_MAX_LPC_ORDER - 1] of Integer;
    outBuf           : array[0..SILK_MAX_FRAME_LENGTH + 2 * SILK_MAX_SUB_FRAME_LENGTH - 1] of SmallInt;
    lagPrev          : Integer;
    LastGainIndex    : ShortInt;
    fs_kHz           : Integer;
    fs_API_hz        : Integer;
    nb_subfr         : Integer;
    frame_length     : Integer;
    subfr_length     : Integer;
    ltp_mem_length   : Integer;
    LPC_order        : Integer;
    prevNLSF_Q15     : array[0..SILK_MAX_LPC_ORDER - 1] of SmallInt;
    first_frame_after_reset: Integer;
    pitch_lag_low_bits_iCDF: PByte;
    pitch_contour_iCDF: PByte;
    nFramesDecoded   : Integer;
    nFramesPerPacket : Integer;
    ec_prevSignalType: Integer;
    ec_prevLagIndex  : SmallInt;
    VAD_flags        : array[0..SILK_MAX_FRAMES_PER_PACKET - 1] of Integer;
    LBRR_flag        : Integer;
    LBRR_flags       : array[0..SILK_MAX_FRAMES_PER_PACKET - 1] of Integer;
    resampler_state  : TSilkResamplerState;
    psNLSF_CB        : PSilkNLSFCB;
    indices          : TSideInfoIndices;
    sCNG             : TSilkCNG;
    lossCnt          : Integer;
    prevSignalType   : Integer;
    sPLC             : TSilkPLC;
  end;
  PSilkChannelState = ^TSilkChannelState;

  TSilkStereoDecState = record
    pred_prev_Q13: array[0..1] of SmallInt;
    sMid         : array[0..1] of SmallInt;
    sSide        : array[0..1] of SmallInt;
  end;

  TSilkDecoder = class
  private
    FChannel : array[0..1] of TSilkChannelState;
    FStereo  : TSilkStereoDecState;
    FnChannelsAPI, FnChannelsInternal: Integer;
    FPrevDecodeOnlyMiddle: Integer;
  public
    constructor Create;
    procedure Reset;
    // silk_Decode: decodes one SILK frame (10/20 ms) into SamplesOut
    // (interleaved int16 at 48 kHz, nChannelsAPI channels).
    function Decode(var Ctl: TSilkDecControl; LostFlag: Integer; NewPacketFlag: Boolean;
      var Rd: TEcDec; SamplesOut: PSmallInt; out nSamplesOut: Integer): Integer;
  end;

var
  // Debug hook: when assigned, receives channel 0 decoded samples at the
  // internal rate (int16) before resampling.
  SilkDebugStream: TObject = nil;
  SilkDebugWrite: procedure(P: Pointer; Bytes: Integer) = nil;

implementation

var
  NLSF_CB_NB_MB: TSilkNLSFCB;
  NLSF_CB_WB   : TSilkNLSFCB;

// ---------------------------------------------------------------------------
// Resampler (decoder side: 8/12/16 kHz -> 48 kHz)
// ---------------------------------------------------------------------------

const
  RESAMPLER_MAX_BATCH_SIZE_MS = 10;
  RESAMPLER_ORDER_FIR_12 = 8;
  DelayMatrixDec: array[0..2, 0..4] of ShortInt = (
    (4, 0, 2, 0, 0),
    (0, 9, 4, 7, 4),
    (0, 3, 12, 7, 7));

function RateID(R: Integer): Integer;
begin
  Result := (((R shr 12) - Ord(R > 16000)) shr Ord(R > 24000)) - 1;
end;

function SilkResamplerInit(var S: TSilkResamplerState; FsHzIn, FsHzOut: Integer): Integer;
var
  Up2x: Integer;
begin
  FillChar(S, SizeOf(S), 0);
  if (FsHzIn <> 8000) and (FsHzIn <> 12000) and (FsHzIn <> 16000) then Exit(-1);
  if (FsHzOut <> 8000) and (FsHzOut <> 12000) and (FsHzOut <> 16000) and (FsHzOut <> 24000) and (FsHzOut <> 48000) then Exit(-1);
  S.inputDelay := DelayMatrixDec[RateID(FsHzIn)][RateID(FsHzOut)];
  S.Fs_in_kHz := FsHzIn div 1000;
  S.Fs_out_kHz := FsHzOut div 1000;
  S.batchSize := S.Fs_in_kHz * RESAMPLER_MAX_BATCH_SIZE_MS;
  Up2x := 0;
  if FsHzOut > FsHzIn then
  begin
    if FsHzOut = FsHzIn * 2 then
      S.resamplerFunction := 1
    else
    begin
      S.resamplerFunction := 2;
      Up2x := 1;
    end;
  end
  else if FsHzOut < FsHzIn then
    Exit(-1)   // downsampling is not needed by the decoder (API rate 48 kHz)
  else
    S.resamplerFunction := 0;
  S.invRatio_Q16 := ((FsHzIn shl (14 + Up2x)) div FsHzOut) shl 2;
  while SilkSMULWW(S.invRatio_Q16, FsHzOut) < (FsHzIn shl Up2x) do
    Inc(S.invRatio_Q16);
  Result := 0;
end;

procedure ResamplerUp2HQ(S: PInteger; OutP: PSmallInt; InP: PSmallInt; Len: Integer);
var
  K: Integer;
  In32, Out32_1, Out32_2, Y, X: Integer;
begin
  for K := 0 to Len - 1 do
  begin
    In32 := Integer(InP[K]) shl 10;
    Y := In32 - S[0];
    X := SilkSMULWB(Y, SILK_RESAMPLER_UP2_HQ_0[0]);
    Out32_1 := S[0] + X;
    S[0] := In32 + X;
    Y := Out32_1 - S[1];
    X := SilkSMULWB(Y, SILK_RESAMPLER_UP2_HQ_0[1]);
    Out32_2 := S[1] + X;
    S[1] := Out32_1 + X;
    Y := Out32_2 - S[2];
    X := SilkSMLAWB(Y, Y, SILK_RESAMPLER_UP2_HQ_0[2]);
    Out32_1 := S[2] + X;
    S[2] := Out32_2 + X;
    OutP[2 * K] := SmallInt(SilkSat16(SilkRShiftRound(Out32_1, 10)));
    Y := In32 - S[3];
    X := SilkSMULWB(Y, SILK_RESAMPLER_UP2_HQ_1[0]);
    Out32_1 := S[3] + X;
    S[3] := In32 + X;
    Y := Out32_1 - S[4];
    X := SilkSMULWB(Y, SILK_RESAMPLER_UP2_HQ_1[1]);
    Out32_2 := S[4] + X;
    S[4] := Out32_1 + X;
    Y := Out32_2 - S[5];
    X := SilkSMLAWB(Y, Y, SILK_RESAMPLER_UP2_HQ_1[2]);
    Out32_1 := S[5] + X;
    S[5] := Out32_2 + X;
    OutP[2 * K + 1] := SmallInt(SilkSat16(SilkRShiftRound(Out32_1, 10)));
  end;
end;

function IIRFIRInterpol(OutP: PSmallInt; Buf: PSmallInt; MaxIndexQ16, IndexIncrementQ16: Integer): PSmallInt;
var
  IndexQ16, ResQ15, TableIndex: Integer;
  BufPtr: PSmallInt;
  T1, T2: PSmallInt;
begin
  IndexQ16 := 0;
  while IndexQ16 < MaxIndexQ16 do
  begin
    TableIndex := SilkSMULWB(IndexQ16 and $FFFF, 12);
    BufPtr := Buf + (IndexQ16 shr 16);
    T1 := @SILK_RESAMPLER_FRAC_FIR_12[TableIndex * 4];
    T2 := @SILK_RESAMPLER_FRAC_FIR_12[(11 - TableIndex) * 4];
    ResQ15 := SilkSMULBB(BufPtr[0], T1[0]);
    ResQ15 := SilkSMLABB(ResQ15, BufPtr[1], T1[1]);
    ResQ15 := SilkSMLABB(ResQ15, BufPtr[2], T1[2]);
    ResQ15 := SilkSMLABB(ResQ15, BufPtr[3], T1[3]);
    ResQ15 := SilkSMLABB(ResQ15, BufPtr[4], T2[3]);
    ResQ15 := SilkSMLABB(ResQ15, BufPtr[5], T2[2]);
    ResQ15 := SilkSMLABB(ResQ15, BufPtr[6], T2[1]);
    ResQ15 := SilkSMLABB(ResQ15, BufPtr[7], T2[0]);
    OutP^ := SmallInt(SilkSat16(SilkRShiftRound(ResQ15, 15)));
    Inc(OutP);
    Inc(IndexQ16, IndexIncrementQ16);
  end;
  Result := OutP;
end;

procedure ResamplerIIRFIR(var S: TSilkResamplerState; OutP: PSmallInt; InP: PSmallInt; InLen: Integer);
var
  Buf: array[0..2 * 160 + RESAMPLER_ORDER_FIR_12 - 1] of SmallInt;
  nSamplesIn, MaxIndexQ16, IndexIncrementQ16: Integer;
begin
  Move(S.sFIR16[0], Buf[0], RESAMPLER_ORDER_FIR_12 * SizeOf(SmallInt));
  IndexIncrementQ16 := S.invRatio_Q16;
  while True do
  begin
    nSamplesIn := Min(InLen, S.batchSize);
    ResamplerUp2HQ(@S.sIIR[0], @Buf[RESAMPLER_ORDER_FIR_12], InP, nSamplesIn);
    MaxIndexQ16 := nSamplesIn shl (16 + 1);
    OutP := IIRFIRInterpol(OutP, @Buf[0], MaxIndexQ16, IndexIncrementQ16);
    Inc(InP, nSamplesIn);
    Dec(InLen, nSamplesIn);
    if InLen > 0 then
      Move(Buf[nSamplesIn shl 1], Buf[0], RESAMPLER_ORDER_FIR_12 * SizeOf(SmallInt))
    else
      Break;
  end;
  Move(Buf[nSamplesIn shl 1], S.sFIR16[0], RESAMPLER_ORDER_FIR_12 * SizeOf(SmallInt));
end;

function SilkResampler(var S: TSilkResamplerState; OutP: PSmallInt; InP: PSmallInt; InLen: Integer): Integer;
var
  nSamples: Integer;
begin
  nSamples := S.Fs_in_kHz - S.inputDelay;
  Move(InP^, S.delayBuf[S.inputDelay], nSamples * SizeOf(SmallInt));
  case S.resamplerFunction of
    1: begin
         ResamplerUp2HQ(@S.sIIR[0], OutP, @S.delayBuf[0], S.Fs_in_kHz);
         ResamplerUp2HQ(@S.sIIR[0], OutP + S.Fs_out_kHz, InP + nSamples, InLen - S.Fs_in_kHz);
       end;
    2: begin
         ResamplerIIRFIR(S, OutP, @S.delayBuf[0], S.Fs_in_kHz);
         ResamplerIIRFIR(S, OutP + S.Fs_out_kHz, InP + nSamples, InLen - S.Fs_in_kHz);
       end;
  else
    Move(S.delayBuf[0], OutP^, S.Fs_in_kHz * SizeOf(SmallInt));
    Move((InP + nSamples)^, (OutP + S.Fs_out_kHz)^, (InLen - S.Fs_in_kHz) * SizeOf(SmallInt));
  end;
  Move((InP + (InLen - S.inputDelay))^, S.delayBuf[0], S.inputDelay * SizeOf(SmallInt));
  Result := 0;
end;

// ---------------------------------------------------------------------------
// CNG / PLC reset, decoder reset, set_fs
// ---------------------------------------------------------------------------

procedure SilkCNGReset(var P: TSilkChannelState);
var
  I, NLSFStepQ15, NLSFAccQ15: Integer;
begin
  NLSFStepQ15 := SILK_INT16_MAX div (P.LPC_order + 1);
  NLSFAccQ15 := 0;
  for I := 0 to P.LPC_order - 1 do
  begin
    NLSFAccQ15 := NLSFAccQ15 + NLSFStepQ15;
    P.sCNG.CNG_smth_NLSF_Q15[I] := SmallInt(NLSFAccQ15);
  end;
  P.sCNG.CNG_smth_Gain_Q16 := 0;
  P.sCNG.rand_seed := 3176576;
end;

procedure SilkPLCReset(var P: TSilkChannelState);
begin
  P.sPLC.pitchL_Q8 := P.frame_length shl (8 - 1);
  P.sPLC.prevGain_Q16[0] := 1 shl 16;
  P.sPLC.prevGain_Q16[1] := 1 shl 16;
  P.sPLC.subfr_length := 20;
  P.sPLC.nb_subfr := 2;
end;

procedure SilkResetDecoder(var P: TSilkChannelState);
var
  Saved: TSilkChannelState;
begin
  // Everything from prev_gain_Q16 onwards is cleared (the whole record here)
  FillChar(P, SizeOf(P), 0);
  P.first_frame_after_reset := 1;
  P.prev_gain_Q16 := 65536;
  SilkCNGReset(P);
  SilkPLCReset(P);
end;

function SilkDecoderSetFs(var P: TSilkChannelState; FsKHz, FsAPIHz: Integer): Integer;
var
  FrameLength: Integer;
begin
  Result := 0;
  P.subfr_length := SILK_SUB_FRAME_LENGTH_MS * FsKHz;
  FrameLength := P.nb_subfr * P.subfr_length;
  if (P.fs_kHz <> FsKHz) or (P.fs_API_hz <> FsAPIHz) then
  begin
    Result := Result + SilkResamplerInit(P.resampler_state, FsKHz * 1000, FsAPIHz);
    P.fs_API_hz := FsAPIHz;
  end;
  if (P.fs_kHz <> FsKHz) or (FrameLength <> P.frame_length) then
  begin
    if FsKHz = 8 then
    begin
      if P.nb_subfr = SILK_MAX_NB_SUBFR then P.pitch_contour_iCDF := @SILK_PITCH_CONTOUR_NB_ICDF[0]
      else P.pitch_contour_iCDF := @SILK_PITCH_CONTOUR_10_MS_NB_ICDF[0];
    end
    else
    begin
      if P.nb_subfr = SILK_MAX_NB_SUBFR then P.pitch_contour_iCDF := @SILK_PITCH_CONTOUR_ICDF[0]
      else P.pitch_contour_iCDF := @SILK_PITCH_CONTOUR_10_MS_ICDF[0];
    end;
    if P.fs_kHz <> FsKHz then
    begin
      P.ltp_mem_length := SILK_LTP_MEM_LENGTH_MS * FsKHz;
      if (FsKHz = 8) or (FsKHz = 12) then
      begin
        P.LPC_order := SILK_MIN_LPC_ORDER;
        P.psNLSF_CB := @NLSF_CB_NB_MB;
      end
      else
      begin
        P.LPC_order := SILK_MAX_LPC_ORDER;
        P.psNLSF_CB := @NLSF_CB_WB;
      end;
      if FsKHz = 16 then P.pitch_lag_low_bits_iCDF := @SILK_UNIFORM8_ICDF[0]
      else if FsKHz = 12 then P.pitch_lag_low_bits_iCDF := @SILK_UNIFORM6_ICDF[0]
      else P.pitch_lag_low_bits_iCDF := @SILK_UNIFORM4_ICDF[0];
      P.first_frame_after_reset := 1;
      P.lagPrev := 100;
      P.LastGainIndex := 10;
      P.prevSignalType := SILK_TYPE_NO_VOICE_ACTIVITY;
      FillChar(P.outBuf, SizeOf(P.outBuf), 0);
      FillChar(P.sLPC_Q14_buf, SizeOf(P.sLPC_Q14_buf), 0);
    end;
    P.fs_kHz := FsKHz;
    P.frame_length := FrameLength;
  end;
end;

// ---------------------------------------------------------------------------
// decode_indices / decode_pulses / decode_parameters
// ---------------------------------------------------------------------------

procedure SilkNLSFUnpack(EcIx: PSmallInt; PredQ8: PByte; const CB: TSilkNLSFCB; CB1Index: Integer);
var
  I: Integer;
  Entry: Byte;
  EcSelPtr: PByte;
begin
  EcSelPtr := CB.ec_sel + (CB1Index * CB.order div 2);
  I := 0;
  while I < CB.order do
  begin
    Entry := EcSelPtr^;
    Inc(EcSelPtr);
    EcIx[I] := SmallInt(((Entry shr 1) and 7) * (2 * SILK_NLSF_QUANT_MAX_AMPLITUDE + 1));
    PredQ8[I] := CB.pred_Q8[I + (Entry and 1) * (CB.order - 1)];
    EcIx[I + 1] := SmallInt(((Entry shr 5) and 7) * (2 * SILK_NLSF_QUANT_MAX_AMPLITUDE + 1));
    PredQ8[I + 1] := CB.pred_Q8[I + ((Entry shr 4) and 1) * (CB.order - 1) + 1];
    Inc(I, 2);
  end;
end;

procedure SilkDecodeIndices(var P: TSilkChannelState; var Rd: TEcDec; FrameIndex: Integer;
  DecodeLBRR: Boolean; CondCoding: Integer);
var
  I, K, Ix: Integer;
  DecodeAbsoluteLagIndex, DeltaLagIndex: Integer;
  EcIx: array[0..SILK_MAX_LPC_ORDER - 1] of SmallInt;
  PredQ8: array[0..SILK_MAX_LPC_ORDER - 1] of Byte;
begin
  if DecodeLBRR or (P.VAD_flags[FrameIndex] <> 0) then
    Ix := EcDecIcdf(Rd, @SILK_TYPE_OFFSET_VAD_ICDF[0], 8) + 2
  else
    Ix := EcDecIcdf(Rd, @SILK_TYPE_OFFSET_NO_VAD_ICDF[0], 8);
  P.indices.signalType := ShortInt(Ix shr 1);
  P.indices.quantOffsetType := ShortInt(Ix and 1);

  if CondCoding = SILK_CODE_CONDITIONALLY then
    P.indices.GainsIndices[0] := ShortInt(EcDecIcdf(Rd, @SILK_DELTA_GAIN_ICDF[0], 8))
  else
  begin
    P.indices.GainsIndices[0] := ShortInt(EcDecIcdf(Rd, @SILK_GAIN_ICDF[P.indices.signalType * 8], 8) shl 3);
    P.indices.GainsIndices[0] := P.indices.GainsIndices[0] + ShortInt(EcDecIcdf(Rd, @SILK_UNIFORM8_ICDF[0], 8));
  end;
  for I := 1 to P.nb_subfr - 1 do
    P.indices.GainsIndices[I] := ShortInt(EcDecIcdf(Rd, @SILK_DELTA_GAIN_ICDF[0], 8));

  P.indices.NLSFIndices[0] := ShortInt(EcDecIcdf(Rd,
    P.psNLSF_CB^.CB1_iCDF + ((P.indices.signalType shr 1) * P.psNLSF_CB^.nVectors), 8));
  SilkNLSFUnpack(@EcIx[0], @PredQ8[0], P.psNLSF_CB^, P.indices.NLSFIndices[0]);
  for I := 0 to P.psNLSF_CB^.order - 1 do
  begin
    Ix := EcDecIcdf(Rd, P.psNLSF_CB^.ec_iCDF + EcIx[I], 8);
    if Ix = 0 then
      Ix := Ix - EcDecIcdf(Rd, @SILK_NLSF_EXT_ICDF[0], 8)
    else if Ix = 2 * SILK_NLSF_QUANT_MAX_AMPLITUDE then
      Ix := Ix + EcDecIcdf(Rd, @SILK_NLSF_EXT_ICDF[0], 8);
    P.indices.NLSFIndices[I + 1] := ShortInt(Ix - SILK_NLSF_QUANT_MAX_AMPLITUDE);
  end;

  if P.nb_subfr = SILK_MAX_NB_SUBFR then
    P.indices.NLSFInterpCoef_Q2 := ShortInt(EcDecIcdf(Rd, @SILK_NLSF_INTERPOLATION_FACTOR_ICDF[0], 8))
  else
    P.indices.NLSFInterpCoef_Q2 := 4;

  if P.indices.signalType = SILK_TYPE_VOICED then
  begin
    DecodeAbsoluteLagIndex := 1;
    if (CondCoding = SILK_CODE_CONDITIONALLY) and (P.ec_prevSignalType = SILK_TYPE_VOICED) then
    begin
      DeltaLagIndex := EcDecIcdf(Rd, @SILK_PITCH_DELTA_ICDF[0], 8);
      if DeltaLagIndex > 0 then
      begin
        DeltaLagIndex := DeltaLagIndex - 9;
        P.indices.lagIndex := SmallInt(P.ec_prevLagIndex + DeltaLagIndex);
        DecodeAbsoluteLagIndex := 0;
      end;
    end;
    if DecodeAbsoluteLagIndex <> 0 then
    begin
      P.indices.lagIndex := SmallInt(EcDecIcdf(Rd, @SILK_PITCH_LAG_ICDF[0], 8) * (P.fs_kHz shr 1));
      P.indices.lagIndex := P.indices.lagIndex + SmallInt(EcDecIcdf(Rd, P.pitch_lag_low_bits_iCDF, 8));
    end;
    P.ec_prevLagIndex := P.indices.lagIndex;
    P.indices.contourIndex := ShortInt(EcDecIcdf(Rd, P.pitch_contour_iCDF, 8));
    P.indices.PERIndex := ShortInt(EcDecIcdf(Rd, @SILK_LTP_PER_INDEX_ICDF[0], 8));
    for K := 0 to P.nb_subfr - 1 do
    begin
      case P.indices.PERIndex of
        0: P.indices.LTPIndex[K] := ShortInt(EcDecIcdf(Rd, @SILK_LTP_GAIN_ICDF_0[0], 8));
        1: P.indices.LTPIndex[K] := ShortInt(EcDecIcdf(Rd, @SILK_LTP_GAIN_ICDF_1[0], 8));
      else
        P.indices.LTPIndex[K] := ShortInt(EcDecIcdf(Rd, @SILK_LTP_GAIN_ICDF_2[0], 8));
      end;
    end;
    if CondCoding = SILK_CODE_INDEPENDENTLY then
      P.indices.LTP_scaleIndex := ShortInt(EcDecIcdf(Rd, @SILK_LTPSCALE_ICDF[0], 8))
    else
      P.indices.LTP_scaleIndex := 0;
  end;
  P.ec_prevSignalType := P.indices.signalType;
  P.indices.Seed := ShortInt(EcDecIcdf(Rd, @SILK_UNIFORM4_ICDF[0], 8));
end;

procedure DecodeSplit(out PChild1, PChild2: SmallInt; var Rd: TEcDec; P: Integer; ShellTable: PByte);
begin
  if P > 0 then
  begin
    PChild1 := SmallInt(EcDecIcdf(Rd, ShellTable + SILK_SHELL_CODE_TABLE_OFFSETS[P], 8));
    PChild2 := SmallInt(P - PChild1);
  end
  else
  begin
    PChild1 := 0;
    PChild2 := 0;
  end;
end;

procedure SilkShellDecoder(Pulses0: PSmallInt; var Rd: TEcDec; Pulses4: Integer);
var
  Pulses3: array[0..1] of SmallInt;
  Pulses2: array[0..3] of SmallInt;
  Pulses1: array[0..7] of SmallInt;
  T0, T1, T2, T3: PByte;
begin
  T0 := @SILK_SHELL_CODE_TABLE0[0];
  T1 := @SILK_SHELL_CODE_TABLE1[0];
  T2 := @SILK_SHELL_CODE_TABLE2[0];
  T3 := @SILK_SHELL_CODE_TABLE3[0];
  DecodeSplit(Pulses3[0], Pulses3[1], Rd, Pulses4, T3);
  DecodeSplit(Pulses2[0], Pulses2[1], Rd, Pulses3[0], T2);
  DecodeSplit(Pulses1[0], Pulses1[1], Rd, Pulses2[0], T1);
  DecodeSplit(Pulses0[0], Pulses0[1], Rd, Pulses1[0], T0);
  DecodeSplit(Pulses0[2], Pulses0[3], Rd, Pulses1[1], T0);
  DecodeSplit(Pulses1[2], Pulses1[3], Rd, Pulses2[1], T1);
  DecodeSplit(Pulses0[4], Pulses0[5], Rd, Pulses1[2], T0);
  DecodeSplit(Pulses0[6], Pulses0[7], Rd, Pulses1[3], T0);
  DecodeSplit(Pulses2[2], Pulses2[3], Rd, Pulses3[1], T2);
  DecodeSplit(Pulses1[4], Pulses1[5], Rd, Pulses2[2], T1);
  DecodeSplit(Pulses0[8], Pulses0[9], Rd, Pulses1[4], T0);
  DecodeSplit(Pulses0[10], Pulses0[11], Rd, Pulses1[5], T0);
  DecodeSplit(Pulses1[6], Pulses1[7], Rd, Pulses2[3], T1);
  DecodeSplit(Pulses0[12], Pulses0[13], Rd, Pulses1[6], T0);
  DecodeSplit(Pulses0[14], Pulses0[15], Rd, Pulses1[7], T0);
end;

procedure SilkDecodeSigns(var Rd: TEcDec; Pulses: PSmallInt; Length: Integer;
  SignalType, QuantOffsetType: Integer; SumPulses: PInteger);
var
  I, J, P: Integer;
  Icdf: array[0..1] of Byte;
  QPtr: PSmallInt;
  IcdfPtr: PByte;
begin
  Icdf[1] := 0;
  QPtr := Pulses;
  I := 7 * (QuantOffsetType + (SignalType shl 1));
  IcdfPtr := @SILK_SIGN_ICDF[I];
  Length := (Length + SILK_SHELL_CODEC_FRAME_LENGTH div 2) shr SILK_LOG2_SHELL_CODEC_FRAME_LENGTH;
  for I := 0 to Length - 1 do
  begin
    P := SumPulses[I];
    if P > 0 then
    begin
      Icdf[0] := IcdfPtr[Min(P and $1F, 6)];
      for J := 0 to SILK_SHELL_CODEC_FRAME_LENGTH - 1 do
        if QPtr[J] > 0 then
          QPtr[J] := SmallInt(QPtr[J] * ((EcDecIcdf(Rd, @Icdf[0], 8) shl 1) - 1));
    end;
    Inc(QPtr, SILK_SHELL_CODEC_FRAME_LENGTH);
  end;
end;

procedure SilkDecodePulses(var Rd: TEcDec; Pulses: PSmallInt; SignalType, QuantOffsetType, FrameLength: Integer);
var
  I, J, K, Iter, AbsQ, NLS, RateLevelIndex: Integer;
  SumPulses, NLShifts: array[0..SILK_MAX_NB_SHELL_BLOCKS - 1] of Integer;
  PulsesPtr: PSmallInt;
  CdfPtr: PByte;
begin
  RateLevelIndex := EcDecIcdf(Rd, @SILK_RATE_LEVELS_ICDF[(SignalType shr 1) * 9], 8);
  Iter := FrameLength shr SILK_LOG2_SHELL_CODEC_FRAME_LENGTH;
  if Iter * SILK_SHELL_CODEC_FRAME_LENGTH < FrameLength then
    Inc(Iter);
  CdfPtr := @SILK_PULSES_PER_BLOCK_ICDF[RateLevelIndex * 18];
  for I := 0 to Iter - 1 do
  begin
    NLShifts[I] := 0;
    SumPulses[I] := EcDecIcdf(Rd, CdfPtr, 8);
    while SumPulses[I] = SILK_MAX_PULSES + 1 do
    begin
      Inc(NLShifts[I]);
      SumPulses[I] := EcDecIcdf(Rd, @SILK_PULSES_PER_BLOCK_ICDF[(SILK_N_RATE_LEVELS - 1) * 18 + Ord(NLShifts[I] = 10)], 8);
    end;
  end;
  for I := 0 to Iter - 1 do
  begin
    if SumPulses[I] > 0 then
      SilkShellDecoder(Pulses + I * SILK_SHELL_CODEC_FRAME_LENGTH, Rd, SumPulses[I])
    else
      FillChar((Pulses + I * SILK_SHELL_CODEC_FRAME_LENGTH)^, SILK_SHELL_CODEC_FRAME_LENGTH * SizeOf(SmallInt), 0);
  end;
  for I := 0 to Iter - 1 do
  begin
    if NLShifts[I] > 0 then
    begin
      NLS := NLShifts[I];
      PulsesPtr := Pulses + I * SILK_SHELL_CODEC_FRAME_LENGTH;
      for K := 0 to SILK_SHELL_CODEC_FRAME_LENGTH - 1 do
      begin
        AbsQ := PulsesPtr[K];
        for J := 0 to NLS - 1 do
        begin
          AbsQ := AbsQ shl 1;
          AbsQ := AbsQ + EcDecIcdf(Rd, @SILK_LSB_ICDF[0], 8);
        end;
        PulsesPtr[K] := SmallInt(AbsQ);
      end;
      SumPulses[I] := SumPulses[I] or (NLS shl 5);
    end;
  end;
  SilkDecodeSigns(Rd, Pulses, FrameLength, SignalType, QuantOffsetType, @SumPulses[0]);
end;

procedure SilkGainsDequant(GainQ16: PInteger; Ind: PShortInt; var PrevInd: ShortInt;
  Conditional: Boolean; NbSubfr: Integer);
const
  OFFSET = ((SILK_MIN_QGAIN_DB * 128) div 6 + 16 * 128);
  INV_SCALE_Q16 = ((65536 * (((SILK_MAX_QGAIN_DB - SILK_MIN_QGAIN_DB) * 128) div 6)) div (SILK_N_LEVELS_QGAIN - 1));
var
  K, IndTmp, DoubleStepSizeThreshold: Integer;
  PI: Integer;
begin
  PI := PrevInd;
  for K := 0 to NbSubfr - 1 do
  begin
    if (K = 0) and (not Conditional) then
      PI := Max(Ind[K], PI - 16)
    else
    begin
      IndTmp := Ind[K] + SILK_MIN_DELTA_GAIN_QUANT;
      DoubleStepSizeThreshold := 2 * SILK_MAX_DELTA_GAIN_QUANT - SILK_N_LEVELS_QGAIN + PI;
      if IndTmp > DoubleStepSizeThreshold then
        PI := PI + ((IndTmp shl 1) - DoubleStepSizeThreshold)
      else
        PI := PI + IndTmp;
    end;
    PI := SilkLimit(PI, 0, SILK_N_LEVELS_QGAIN - 1);
    GainQ16[K] := SilkLog2Lin(Min(SilkSMULWB(INV_SCALE_Q16, PI) + OFFSET, 3967));
  end;
  PrevInd := ShortInt(PI);
end;

procedure SilkNLSFResidualDequant(XQ10: PSmallInt; Indices: PShortInt; PredCoefQ8: PByte;
  QuantStepSizeQ16: Integer; Order: Integer);
var
  I, OutQ10, PredQ10: Integer;
begin
  OutQ10 := 0;
  for I := Order - 1 downto 0 do
  begin
    PredQ10 := Sar32(SilkSMULBB(OutQ10, SmallInt(PredCoefQ8[I])), 8);
    OutQ10 := Integer(Indices[I]) shl 10;
    if OutQ10 > 0 then
      OutQ10 := OutQ10 - 102   // SILK_FIX_CONST(NLSF_QUANT_LEVEL_ADJ=0.1, 10)
    else if OutQ10 < 0 then
      OutQ10 := OutQ10 + 102;
    OutQ10 := SilkSMLAWB(PredQ10, OutQ10, QuantStepSizeQ16);
    XQ10[I] := SmallInt(OutQ10);
  end;
end;

procedure SilkNLSFDecode(PNLSFQ15: PSmallInt; NLSFIndices: PShortInt; const CB: TSilkNLSFCB);
var
  I: Integer;
  PredQ8: array[0..SILK_MAX_LPC_ORDER - 1] of Byte;
  EcIx: array[0..SILK_MAX_LPC_ORDER - 1] of SmallInt;
  ResQ10: array[0..SILK_MAX_LPC_ORDER - 1] of SmallInt;
  NLSFQ15Tmp: Integer;
  PCBElement: PByte;
  PCBWghtQ9: PSmallInt;
begin
  SilkNLSFUnpack(@EcIx[0], @PredQ8[0], CB, NLSFIndices[0]);
  SilkNLSFResidualDequant(@ResQ10[0], NLSFIndices + 1, @PredQ8[0], CB.quantStepSize_Q16, CB.order);
  PCBElement := CB.CB1_NLSF_Q8 + (NLSFIndices[0] * CB.order);
  PCBWghtQ9 := CB.CB1_Wght_Q9 + (NLSFIndices[0] * CB.order);
  for I := 0 to CB.order - 1 do
  begin
    NLSFQ15Tmp := ((Integer(ResQ10[I]) shl 14) div PCBWghtQ9[I]) + (Integer(PCBElement[I]) shl 7);
    PNLSFQ15[I] := SmallInt(SilkLimit(NLSFQ15Tmp, 0, 32767));
  end;
  SilkNLSFStabilize(PNLSFQ15, CB.deltaMin_Q15, CB.order);
end;

procedure SilkDecodePitch(LagIndex: SmallInt; ContourIndex: ShortInt; PitchLags: PInteger;
  FsKHz, NbSubfr: Integer);
var
  Lag, K, MinLag, MaxLag, CbkSize: Integer;
  LagCB: PShortInt;
begin
  if FsKHz = 8 then
  begin
    if NbSubfr = SILK_PE_MAX_NB_SUBFR then
    begin
      LagCB := @SILK_CB_LAGS_STAGE2[0];
      CbkSize := SILK_PE_NB_CBKS_STAGE2_EXT;
    end
    else
    begin
      LagCB := @SILK_CB_LAGS_STAGE2_10_MS[0];
      CbkSize := SILK_PE_NB_CBKS_STAGE2_10MS;
    end;
  end
  else
  begin
    if NbSubfr = SILK_PE_MAX_NB_SUBFR then
    begin
      LagCB := @SILK_CB_LAGS_STAGE3[0];
      CbkSize := SILK_PE_NB_CBKS_STAGE3_MAX;
    end
    else
    begin
      LagCB := @SILK_CB_LAGS_STAGE3_10_MS[0];
      CbkSize := SILK_PE_NB_CBKS_STAGE3_10MS;
    end;
  end;
  MinLag := SILK_PE_MIN_LAG_MS * FsKHz;
  MaxLag := SILK_PE_MAX_LAG_MS * FsKHz;
  Lag := MinLag + LagIndex;
  for K := 0 to NbSubfr - 1 do
  begin
    PitchLags[K] := Lag + LagCB[K * CbkSize + ContourIndex];
    PitchLags[K] := SilkLimit(PitchLags[K], MinLag, MaxLag);
  end;
end;

procedure SilkDecodeParameters(var P: TSilkChannelState; var Ctl: TSilkDecoderControl; CondCoding: Integer);
var
  I, K, Ix: Integer;
  PNLSFQ15, PNLSF0Q15: array[0..SILK_MAX_LPC_ORDER - 1] of SmallInt;
  CbkPtrQ7: PShortInt;
begin
  SilkGainsDequant(@Ctl.Gains_Q16[0], @P.indices.GainsIndices[0], P.LastGainIndex,
    CondCoding = SILK_CODE_CONDITIONALLY, P.nb_subfr);
  SilkNLSFDecode(@PNLSFQ15[0], @P.indices.NLSFIndices[0], P.psNLSF_CB^);
  SilkNLSF2A(@Ctl.PredCoef_Q12[1][0], @PNLSFQ15[0], P.LPC_order);
  if P.first_frame_after_reset = 1 then
    P.indices.NLSFInterpCoef_Q2 := 4;
  if P.indices.NLSFInterpCoef_Q2 < 4 then
  begin
    for I := 0 to P.LPC_order - 1 do
      PNLSF0Q15[I] := SmallInt(P.prevNLSF_Q15[I] + Sar32(Integer(P.indices.NLSFInterpCoef_Q2) *
        (PNLSFQ15[I] - P.prevNLSF_Q15[I]), 2));
    SilkNLSF2A(@Ctl.PredCoef_Q12[0][0], @PNLSF0Q15[0], P.LPC_order);
  end
  else
    Move(Ctl.PredCoef_Q12[1][0], Ctl.PredCoef_Q12[0][0], P.LPC_order * SizeOf(SmallInt));
  Move(PNLSFQ15[0], P.prevNLSF_Q15[0], P.LPC_order * SizeOf(SmallInt));
  if P.lossCnt <> 0 then
  begin
    SilkBwExpander(@Ctl.PredCoef_Q12[0][0], P.LPC_order, SILK_BWE_AFTER_LOSS_Q16);
    SilkBwExpander(@Ctl.PredCoef_Q12[1][0], P.LPC_order, SILK_BWE_AFTER_LOSS_Q16);
  end;
  if P.indices.signalType = SILK_TYPE_VOICED then
  begin
    SilkDecodePitch(P.indices.lagIndex, P.indices.contourIndex, @Ctl.pitchL[0], P.fs_kHz, P.nb_subfr);
    case P.indices.PERIndex of
      0: CbkPtrQ7 := @SILK_LTP_GAIN_VQ_0[0];
      1: CbkPtrQ7 := @SILK_LTP_GAIN_VQ_1[0];
    else CbkPtrQ7 := @SILK_LTP_GAIN_VQ_2[0];
    end;
    for K := 0 to P.nb_subfr - 1 do
    begin
      Ix := P.indices.LTPIndex[K];
      for I := 0 to SILK_LTP_ORDER - 1 do
        Ctl.LTPCoef_Q14[K * SILK_LTP_ORDER + I] := SmallInt(Integer(CbkPtrQ7[Ix * SILK_LTP_ORDER + I]) shl 7);
    end;
    Ix := P.indices.LTP_scaleIndex;
    Ctl.LTP_scale_Q14 := SILK_LTPSCALES_TABLE_Q14[Ix];
  end
  else
  begin
    FillChar(Ctl.pitchL, SizeOf(Ctl.pitchL), 0);
    FillChar(Ctl.LTPCoef_Q14, SizeOf(Ctl.LTPCoef_Q14), 0);
    P.indices.PERIndex := 0;
    Ctl.LTP_scale_Q14 := 0;
  end;
end;

// ---------------------------------------------------------------------------
// decode_core
// ---------------------------------------------------------------------------

procedure SilkDecodeCore(var P: TSilkChannelState; var Ctl: TSilkDecoderControl;
  Xq: PSmallInt; Pulses: PSmallInt);
var
  I, K, Lag, StartIdx, SLTPBufIdx, NLSFInterpolationFlag, SignalType: Integer;
  AQ12: PSmallInt;
  BQ14: PSmallInt;
  Pxq: PSmallInt;
  AQ12Tmp: array[0..SILK_MAX_LPC_ORDER - 1] of SmallInt;
  SLTP: array[0..SILK_LTP_MEM_LENGTH_MS * SILK_MAX_FS_KHZ - 1] of SmallInt;
  SLTPQ15: array[0..(SILK_LTP_MEM_LENGTH_MS * SILK_MAX_FS_KHZ) + SILK_MAX_FRAME_LENGTH - 1] of Integer;
  ResQ14: array[0..SILK_MAX_SUB_FRAME_LENGTH - 1] of Integer;
  SLPCQ14: array[0..SILK_MAX_SUB_FRAME_LENGTH + SILK_MAX_LPC_ORDER - 1] of Integer;
  LTPPredQ13, LPCPredQ10, GainQ10, InvGainQ31, GainAdjQ16, RandSeed, OffsetQ10: Integer;
  PredLagPtr, PexcQ14, PresQ14: PInteger;
begin
  Lag := 0;
  OffsetQ10 := SILK_QUANTIZATION_OFFSETS_Q10[(P.indices.signalType shr 1) * 2 + P.indices.quantOffsetType];
  if P.indices.NLSFInterpCoef_Q2 < (1 shl 2) then NLSFInterpolationFlag := 1
  else NLSFInterpolationFlag := 0;

  RandSeed := P.indices.Seed;
  for I := 0 to P.frame_length - 1 do
  begin
    RandSeed := SilkRand(RandSeed);
    P.exc_Q14[I] := Integer(Pulses[I]) shl 14;
    if P.exc_Q14[I] > 0 then
      P.exc_Q14[I] := P.exc_Q14[I] - (SILK_QUANT_LEVEL_ADJUST_Q10 shl 4)
    else if P.exc_Q14[I] < 0 then
      P.exc_Q14[I] := P.exc_Q14[I] + (SILK_QUANT_LEVEL_ADJUST_Q10 shl 4);
    P.exc_Q14[I] := P.exc_Q14[I] + (OffsetQ10 shl 4);
    if RandSeed < 0 then
      P.exc_Q14[I] := -P.exc_Q14[I];
    RandSeed := Integer(Cardinal(RandSeed) + Cardinal(Integer(Pulses[I])));
  end;

  Move(P.sLPC_Q14_buf[0], SLPCQ14[0], SILK_MAX_LPC_ORDER * SizeOf(Integer));
  PexcQ14 := @P.exc_Q14[0];
  Pxq := Xq;
  SLTPBufIdx := P.ltp_mem_length;
  for K := 0 to P.nb_subfr - 1 do
  begin
    PresQ14 := @ResQ14[0];
    AQ12 := @Ctl.PredCoef_Q12[K shr 1][0];
    Move(AQ12^, AQ12Tmp[0], P.LPC_order * SizeOf(SmallInt));
    BQ14 := @Ctl.LTPCoef_Q14[K * SILK_LTP_ORDER];
    SignalType := P.indices.signalType;
    GainQ10 := Sar32(Ctl.Gains_Q16[K], 6);
    InvGainQ31 := SilkINVERSE32VarQ(Ctl.Gains_Q16[K], 47);

    if Ctl.Gains_Q16[K] <> P.prev_gain_Q16 then
    begin
      GainAdjQ16 := SilkDIV32VarQ(P.prev_gain_Q16, Ctl.Gains_Q16[K], 16);
      for I := 0 to SILK_MAX_LPC_ORDER - 1 do
        SLPCQ14[I] := SilkSMULWW(GainAdjQ16, SLPCQ14[I]);
    end
    else
      GainAdjQ16 := 1 shl 16;
    P.prev_gain_Q16 := Ctl.Gains_Q16[K];

    if (P.lossCnt <> 0) and (P.prevSignalType = SILK_TYPE_VOICED) and
       (P.indices.signalType <> SILK_TYPE_VOICED) and (K < SILK_MAX_NB_SUBFR div 2) then
    begin
      FillChar(BQ14^, SILK_LTP_ORDER * SizeOf(SmallInt), 0);
      BQ14[SILK_LTP_ORDER div 2] := 4096;   // 0.25 in Q14
      SignalType := SILK_TYPE_VOICED;
      Ctl.pitchL[K] := P.lagPrev;
    end;

    if SignalType = SILK_TYPE_VOICED then
    begin
      Lag := Ctl.pitchL[K];
      if (K = 0) or ((K = 2) and (NLSFInterpolationFlag <> 0)) then
      begin
        StartIdx := P.ltp_mem_length - Lag - P.LPC_order - SILK_LTP_ORDER div 2;
        if K = 2 then
          Move(Xq^, P.outBuf[P.ltp_mem_length], 2 * P.subfr_length * SizeOf(SmallInt));
        SilkLPCAnalysisFilter(@SLTP[StartIdx], @P.outBuf[StartIdx + K * P.subfr_length],
          AQ12, P.ltp_mem_length - StartIdx, P.LPC_order);
        if K = 0 then
          InvGainQ31 := SilkSMULWB(InvGainQ31, Ctl.LTP_scale_Q14) shl 2;
        for I := 0 to Lag + SILK_LTP_ORDER div 2 - 1 do
          SLTPQ15[SLTPBufIdx - I - 1] := SilkSMULWB(InvGainQ31, SLTP[P.ltp_mem_length - I - 1]);
      end
      else
      begin
        if GainAdjQ16 <> (1 shl 16) then
          for I := 0 to Lag + SILK_LTP_ORDER div 2 - 1 do
            SLTPQ15[SLTPBufIdx - I - 1] := SilkSMULWW(GainAdjQ16, SLTPQ15[SLTPBufIdx - I - 1]);
      end;
    end;

    if SignalType = SILK_TYPE_VOICED then
    begin
      PredLagPtr := @SLTPQ15[SLTPBufIdx - Lag + SILK_LTP_ORDER div 2];
      for I := 0 to P.subfr_length - 1 do
      begin
        LTPPredQ13 := 2;
        LTPPredQ13 := SilkSMLAWB(LTPPredQ13, PredLagPtr[0], BQ14[0]);
        LTPPredQ13 := SilkSMLAWB(LTPPredQ13, PredLagPtr[-1], BQ14[1]);
        LTPPredQ13 := SilkSMLAWB(LTPPredQ13, PredLagPtr[-2], BQ14[2]);
        LTPPredQ13 := SilkSMLAWB(LTPPredQ13, PredLagPtr[-3], BQ14[3]);
        LTPPredQ13 := SilkSMLAWB(LTPPredQ13, PredLagPtr[-4], BQ14[4]);
        Inc(PredLagPtr);
        PresQ14[I] := PexcQ14[I] + (LTPPredQ13 shl 1);
        SLTPQ15[SLTPBufIdx] := PresQ14[I] shl 1;
        Inc(SLTPBufIdx);
      end;
    end
    else
      PresQ14 := PexcQ14;

    for I := 0 to P.subfr_length - 1 do
    begin
      LPCPredQ10 := Sar32(P.LPC_order, 1);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14[SILK_MAX_LPC_ORDER + I - 1], AQ12Tmp[0]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14[SILK_MAX_LPC_ORDER + I - 2], AQ12Tmp[1]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14[SILK_MAX_LPC_ORDER + I - 3], AQ12Tmp[2]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14[SILK_MAX_LPC_ORDER + I - 4], AQ12Tmp[3]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14[SILK_MAX_LPC_ORDER + I - 5], AQ12Tmp[4]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14[SILK_MAX_LPC_ORDER + I - 6], AQ12Tmp[5]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14[SILK_MAX_LPC_ORDER + I - 7], AQ12Tmp[6]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14[SILK_MAX_LPC_ORDER + I - 8], AQ12Tmp[7]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14[SILK_MAX_LPC_ORDER + I - 9], AQ12Tmp[8]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14[SILK_MAX_LPC_ORDER + I - 10], AQ12Tmp[9]);
      if P.LPC_order = 16 then
      begin
        LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14[SILK_MAX_LPC_ORDER + I - 11], AQ12Tmp[10]);
        LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14[SILK_MAX_LPC_ORDER + I - 12], AQ12Tmp[11]);
        LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14[SILK_MAX_LPC_ORDER + I - 13], AQ12Tmp[12]);
        LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14[SILK_MAX_LPC_ORDER + I - 14], AQ12Tmp[13]);
        LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14[SILK_MAX_LPC_ORDER + I - 15], AQ12Tmp[14]);
        LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14[SILK_MAX_LPC_ORDER + I - 16], AQ12Tmp[15]);
      end;
      SLPCQ14[SILK_MAX_LPC_ORDER + I] := SilkAddSat32(PresQ14[I], SilkLShiftSat32(LPCPredQ10, 4));
      Pxq[I] := SmallInt(SilkSat16(SilkRShiftRound(SilkSMULWW(SLPCQ14[SILK_MAX_LPC_ORDER + I], GainQ10), 8)));
    end;
    Move(SLPCQ14[P.subfr_length], SLPCQ14[0], SILK_MAX_LPC_ORDER * SizeOf(Integer));
    Inc(PexcQ14, P.subfr_length);
    Inc(Pxq, P.subfr_length);
  end;
  Move(SLPCQ14[0], P.sLPC_Q14_buf[0], SILK_MAX_LPC_ORDER * SizeOf(Integer));
end;

// ---------------------------------------------------------------------------
// PLC
// ---------------------------------------------------------------------------

const
  HARM_ATT_Q15: array[0..1] of SmallInt = (32440, 31130);
  PLC_RAND_ATTENUATE_V_Q15: array[0..1] of SmallInt = (31130, 26214);
  PLC_RAND_ATTENUATE_UV_Q15: array[0..1] of SmallInt = (32440, 29491);
  V_PITCH_GAIN_START_MIN_Q14 = 11469;
  V_PITCH_GAIN_START_MAX_Q14 = 15565;
  MAX_PITCH_LAG_MS = 18;
  RAND_BUF_SIZE = 128;
  RAND_BUF_MASK = RAND_BUF_SIZE - 1;
  LOG2_INV_LPC_GAIN_HIGH_THRES = 3;
  LOG2_INV_LPC_GAIN_LOW_THRES = 8;
  PITCH_DRIFT_FAC_Q16 = 655;
  BWE_COEF_Q16 = 64881;   // SILK_FIX_CONST(0.99, 16)

procedure SilkPLCUpdate(var P: TSilkChannelState; var Ctl: TSilkDecoderControl);
var
  LTPGainQ14, TempLTPGainQ14: Integer;
  I, J: Integer;
  ScaleQ10, ScaleQ14, Tmp: Integer;
begin
  P.prevSignalType := P.indices.signalType;
  LTPGainQ14 := 0;
  if P.indices.signalType = SILK_TYPE_VOICED then
  begin
    J := 0;
    while J * P.subfr_length < Ctl.pitchL[P.nb_subfr - 1] do
    begin
      if J = P.nb_subfr then Break;
      TempLTPGainQ14 := 0;
      for I := 0 to SILK_LTP_ORDER - 1 do
        TempLTPGainQ14 := TempLTPGainQ14 + Ctl.LTPCoef_Q14[(P.nb_subfr - 1 - J) * SILK_LTP_ORDER + I];
      if TempLTPGainQ14 > LTPGainQ14 then
      begin
        LTPGainQ14 := TempLTPGainQ14;
        Move(Ctl.LTPCoef_Q14[(P.nb_subfr - 1 - J) * SILK_LTP_ORDER], P.sPLC.LTPCoef_Q14[0], SILK_LTP_ORDER * SizeOf(SmallInt));
        P.sPLC.pitchL_Q8 := Ctl.pitchL[P.nb_subfr - 1 - J] shl 8;
      end;
      Inc(J);
    end;
    FillChar(P.sPLC.LTPCoef_Q14, SizeOf(P.sPLC.LTPCoef_Q14), 0);
    P.sPLC.LTPCoef_Q14[SILK_LTP_ORDER div 2] := SmallInt(LTPGainQ14);
    if LTPGainQ14 < V_PITCH_GAIN_START_MIN_Q14 then
    begin
      Tmp := V_PITCH_GAIN_START_MIN_Q14 shl 10;
      ScaleQ10 := Tmp div Max(LTPGainQ14, 1);
      for I := 0 to SILK_LTP_ORDER - 1 do
        P.sPLC.LTPCoef_Q14[I] := SmallInt(Sar32(SilkSMULBB(P.sPLC.LTPCoef_Q14[I], ScaleQ10), 10));
    end
    else if LTPGainQ14 > V_PITCH_GAIN_START_MAX_Q14 then
    begin
      Tmp := V_PITCH_GAIN_START_MAX_Q14 shl 14;
      ScaleQ14 := Tmp div Max(LTPGainQ14, 1);
      for I := 0 to SILK_LTP_ORDER - 1 do
        P.sPLC.LTPCoef_Q14[I] := SmallInt(Sar32(SilkSMULBB(P.sPLC.LTPCoef_Q14[I], ScaleQ14), 14));
    end;
  end
  else
  begin
    P.sPLC.pitchL_Q8 := (P.fs_kHz * 18) shl 8;
    FillChar(P.sPLC.LTPCoef_Q14, SizeOf(P.sPLC.LTPCoef_Q14), 0);
  end;
  Move(Ctl.PredCoef_Q12[1][0], P.sPLC.prevLPC_Q12[0], P.LPC_order * SizeOf(SmallInt));
  P.sPLC.prevLTP_scale_Q14 := SmallInt(Ctl.LTP_scale_Q14);
  P.sPLC.prevGain_Q16[0] := Ctl.Gains_Q16[P.nb_subfr - 2];
  P.sPLC.prevGain_Q16[1] := Ctl.Gains_Q16[P.nb_subfr - 1];
  P.sPLC.subfr_length := P.subfr_length;
  P.sPLC.nb_subfr := P.nb_subfr;
end;

procedure SilkPLCEnergy(out Energy1, Shift1, Energy2, Shift2: Integer; ExcQ14: PInteger;
  PrevGainQ10: PInteger; SubfrLength, NbSubfr: Integer);
var
  I, K: Integer;
  ExcBuf: array[0..2 * SILK_MAX_SUB_FRAME_LENGTH - 1] of SmallInt;
  Ptr: Integer;
begin
  Ptr := 0;
  for K := 0 to 1 do
  begin
    for I := 0 to SubfrLength - 1 do
      ExcBuf[Ptr + I] := SmallInt(SilkSat16(Sar32(SilkSMULWW(ExcQ14[I + (K + NbSubfr - 2) * SubfrLength], PrevGainQ10[K]), 8)));
    Inc(Ptr, SubfrLength);
  end;
  SilkSumSqrShift(Energy1, Shift1, @ExcBuf[0], SubfrLength);
  SilkSumSqrShift(Energy2, Shift2, @ExcBuf[SubfrLength], SubfrLength);
end;

procedure SilkPLCConceal(var P: TSilkChannelState; var Ctl: TSilkDecoderControl; Frame: PSmallInt);
var
  I, J, K: Integer;
  Lag, Idx, SLTPBufIdx, Shift1, Shift2: Integer;
  RandSeed, HarmGainQ15, RandGainQ15, InvGainQ30: Integer;
  Energy1, Energy2: Integer;
  RandPtr, PredLagPtr: PInteger;
  LPCPredQ10, LTPPredQ12: Integer;
  RandScaleQ14: SmallInt;
  BQ14: PSmallInt;
  SLPCQ14Ptr: PInteger;
  AQ12: array[0..SILK_MAX_LPC_ORDER - 1] of SmallInt;
  SLTP: array[0..SILK_LTP_MEM_LENGTH_MS * SILK_MAX_FS_KHZ - 1] of SmallInt;
  SLTPQ14: array[0..(SILK_LTP_MEM_LENGTH_MS * SILK_MAX_FS_KHZ) + SILK_MAX_FRAME_LENGTH - 1] of Integer;
  PrevGainQ10: array[0..1] of Integer;
  InvGainQ30b, DownScaleQ30: Integer;
begin
  PrevGainQ10[0] := Sar32(P.sPLC.prevGain_Q16[0], 6);
  PrevGainQ10[1] := Sar32(P.sPLC.prevGain_Q16[1], 6);
  if P.first_frame_after_reset <> 0 then
    FillChar(P.sPLC.prevLPC_Q12, SizeOf(P.sPLC.prevLPC_Q12), 0);
  SilkPLCEnergy(Energy1, Shift1, Energy2, Shift2, @P.exc_Q14[0], @PrevGainQ10[0], P.subfr_length, P.nb_subfr);
  if Sar32(Energy1, Shift2) < Sar32(Energy2, Shift1) then
    RandPtr := @P.exc_Q14[Max(0, (P.sPLC.nb_subfr - 1) * P.sPLC.subfr_length - RAND_BUF_SIZE)]
  else
    RandPtr := @P.exc_Q14[Max(0, P.sPLC.nb_subfr * P.sPLC.subfr_length - RAND_BUF_SIZE)];
  BQ14 := @P.sPLC.LTPCoef_Q14[0];
  RandScaleQ14 := P.sPLC.randScale_Q14;
  HarmGainQ15 := HARM_ATT_Q15[Min(1, P.lossCnt)];
  if P.prevSignalType = SILK_TYPE_VOICED then
    RandGainQ15 := PLC_RAND_ATTENUATE_V_Q15[Min(1, P.lossCnt)]
  else
    RandGainQ15 := PLC_RAND_ATTENUATE_UV_Q15[Min(1, P.lossCnt)];
  SilkBwExpander(@P.sPLC.prevLPC_Q12[0], P.LPC_order, BWE_COEF_Q16);
  Move(P.sPLC.prevLPC_Q12[0], AQ12[0], P.LPC_order * SizeOf(SmallInt));
  if P.lossCnt = 0 then
  begin
    RandScaleQ14 := 1 shl 14;
    if P.prevSignalType = SILK_TYPE_VOICED then
    begin
      for I := 0 to SILK_LTP_ORDER - 1 do
        RandScaleQ14 := RandScaleQ14 - BQ14[I];
      RandScaleQ14 := SmallInt(Max(3277, RandScaleQ14));
      RandScaleQ14 := SmallInt(Sar32(SilkSMULBB(RandScaleQ14, P.sPLC.prevLTP_scale_Q14), 14));
    end
    else
    begin
      InvGainQ30b := SilkLPCInversePredGain(@P.sPLC.prevLPC_Q12[0], P.LPC_order);
      DownScaleQ30 := Min(Sar32(1 shl 30, LOG2_INV_LPC_GAIN_HIGH_THRES), InvGainQ30b);
      DownScaleQ30 := Max(Sar32(1 shl 30, LOG2_INV_LPC_GAIN_LOW_THRES), DownScaleQ30);
      DownScaleQ30 := DownScaleQ30 shl LOG2_INV_LPC_GAIN_HIGH_THRES;
      RandGainQ15 := Sar32(SilkSMULWB(DownScaleQ30, RandGainQ15), 14);
    end;
  end;
  RandSeed := P.sPLC.rand_seed;
  Lag := SilkRShiftRound(P.sPLC.pitchL_Q8, 8);
  SLTPBufIdx := P.ltp_mem_length;
  Idx := P.ltp_mem_length - Lag - P.LPC_order - SILK_LTP_ORDER div 2;
  SilkLPCAnalysisFilter(@SLTP[Idx], @P.outBuf[Idx], @AQ12[0], P.ltp_mem_length - Idx, P.LPC_order);
  InvGainQ30 := SilkINVERSE32VarQ(P.sPLC.prevGain_Q16[1], 46);
  InvGainQ30 := Min(InvGainQ30, SILK_INT32_MAX shr 1);
  for I := Idx + P.LPC_order to P.ltp_mem_length - 1 do
    SLTPQ14[I] := SilkSMULWB(InvGainQ30, SLTP[I]);
  for K := 0 to P.nb_subfr - 1 do
  begin
    PredLagPtr := @SLTPQ14[SLTPBufIdx - Lag + SILK_LTP_ORDER div 2];
    for I := 0 to P.subfr_length - 1 do
    begin
      LTPPredQ12 := 2;
      LTPPredQ12 := SilkSMLAWB(LTPPredQ12, PredLagPtr[0], BQ14[0]);
      LTPPredQ12 := SilkSMLAWB(LTPPredQ12, PredLagPtr[-1], BQ14[1]);
      LTPPredQ12 := SilkSMLAWB(LTPPredQ12, PredLagPtr[-2], BQ14[2]);
      LTPPredQ12 := SilkSMLAWB(LTPPredQ12, PredLagPtr[-3], BQ14[3]);
      LTPPredQ12 := SilkSMLAWB(LTPPredQ12, PredLagPtr[-4], BQ14[4]);
      Inc(PredLagPtr);
      RandSeed := SilkRand(RandSeed);
      Idx := Sar32(RandSeed, 25) and RAND_BUF_MASK;
      SLTPQ14[SLTPBufIdx] := SilkSMLAWB(LTPPredQ12, RandPtr[Idx], RandScaleQ14) shl 2;
      Inc(SLTPBufIdx);
    end;
    for J := 0 to SILK_LTP_ORDER - 1 do
      BQ14[J] := SmallInt(Sar32(SilkSMULBB(HarmGainQ15, BQ14[J]), 15));
    RandScaleQ14 := SmallInt(Sar32(SilkSMULBB(RandScaleQ14, RandGainQ15), 15));
    P.sPLC.pitchL_Q8 := SilkSMLAWB(P.sPLC.pitchL_Q8, P.sPLC.pitchL_Q8, PITCH_DRIFT_FAC_Q16);
    P.sPLC.pitchL_Q8 := Min(P.sPLC.pitchL_Q8, (MAX_PITCH_LAG_MS * P.fs_kHz) shl 8);
    Lag := SilkRShiftRound(P.sPLC.pitchL_Q8, 8);
  end;
  SLPCQ14Ptr := @SLTPQ14[P.ltp_mem_length - SILK_MAX_LPC_ORDER];
  Move(P.sLPC_Q14_buf[0], SLPCQ14Ptr^, SILK_MAX_LPC_ORDER * SizeOf(Integer));
  for I := 0 to P.frame_length - 1 do
  begin
    LPCPredQ10 := Sar32(P.LPC_order, 1);
    LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14Ptr[SILK_MAX_LPC_ORDER + I - 1], AQ12[0]);
    LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14Ptr[SILK_MAX_LPC_ORDER + I - 2], AQ12[1]);
    LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14Ptr[SILK_MAX_LPC_ORDER + I - 3], AQ12[2]);
    LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14Ptr[SILK_MAX_LPC_ORDER + I - 4], AQ12[3]);
    LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14Ptr[SILK_MAX_LPC_ORDER + I - 5], AQ12[4]);
    LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14Ptr[SILK_MAX_LPC_ORDER + I - 6], AQ12[5]);
    LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14Ptr[SILK_MAX_LPC_ORDER + I - 7], AQ12[6]);
    LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14Ptr[SILK_MAX_LPC_ORDER + I - 8], AQ12[7]);
    LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14Ptr[SILK_MAX_LPC_ORDER + I - 9], AQ12[8]);
    LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14Ptr[SILK_MAX_LPC_ORDER + I - 10], AQ12[9]);
    for J := 10 to P.LPC_order - 1 do
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, SLPCQ14Ptr[SILK_MAX_LPC_ORDER + I - J - 1], AQ12[J]);
    SLPCQ14Ptr[SILK_MAX_LPC_ORDER + I] := SilkAddSat32(SLPCQ14Ptr[SILK_MAX_LPC_ORDER + I], SilkLShiftSat32(LPCPredQ10, 4));
    Frame[I] := SmallInt(SilkSat16(SilkRShiftRound(SilkSMULWW(SLPCQ14Ptr[SILK_MAX_LPC_ORDER + I], PrevGainQ10[1]), 8)));
  end;
  Move(SLPCQ14Ptr[P.frame_length], P.sLPC_Q14_buf[0], SILK_MAX_LPC_ORDER * SizeOf(Integer));
  P.sPLC.rand_seed := RandSeed;
  P.sPLC.randScale_Q14 := RandScaleQ14;
  for I := 0 to SILK_MAX_NB_SUBFR - 1 do
    Ctl.pitchL[I] := Lag;
end;

procedure SilkPLC(var P: TSilkChannelState; var Ctl: TSilkDecoderControl; Frame: PSmallInt; Lost: Boolean);
begin
  if P.fs_kHz <> P.sPLC.fs_kHz then
  begin
    SilkPLCReset(P);
    P.sPLC.fs_kHz := P.fs_kHz;
  end;
  if Lost then
  begin
    SilkPLCConceal(P, Ctl, Frame);
    Inc(P.lossCnt);
  end
  else
    SilkPLCUpdate(P, Ctl);
end;

procedure SilkPLCGlueFrames(var P: TSilkChannelState; Frame: PSmallInt; Length: Integer);
var
  I, EnergyShift: Integer;
  Energy: Integer;
  FracQ24, LZ, GainQ16, SlopeQ16: Integer;
begin
  if P.lossCnt <> 0 then
  begin
    SilkSumSqrShift(P.sPLC.conc_energy, P.sPLC.conc_energy_shift, Frame, Length);
    P.sPLC.last_frame_lost := 1;
  end
  else
  begin
    if P.sPLC.last_frame_lost <> 0 then
    begin
      SilkSumSqrShift(Energy, EnergyShift, Frame, Length);
      if EnergyShift > P.sPLC.conc_energy_shift then
        P.sPLC.conc_energy := Sar32(P.sPLC.conc_energy, EnergyShift - P.sPLC.conc_energy_shift)
      else if EnergyShift < P.sPLC.conc_energy_shift then
        Energy := Sar32(Energy, P.sPLC.conc_energy_shift - EnergyShift);
      if Energy > P.sPLC.conc_energy then
      begin
        LZ := SilkCLZ32(P.sPLC.conc_energy);
        LZ := LZ - 1;
        P.sPLC.conc_energy := P.sPLC.conc_energy shl LZ;
        Energy := Sar32(Energy, Max(24 - LZ, 0));
        FracQ24 := P.sPLC.conc_energy div Max(Energy, 1);
        GainQ16 := SilkSqrtApprox(FracQ24) shl 4;
        SlopeQ16 := ((1 shl 16) - GainQ16) div Length;
        SlopeQ16 := SlopeQ16 shl 2;
        for I := 0 to Length - 1 do
        begin
          Frame[I] := SmallInt(SilkSMULWB(GainQ16, Frame[I]));
          GainQ16 := GainQ16 + SlopeQ16;
          if GainQ16 > (1 shl 16) then Break;
        end;
      end;
    end;
    P.sPLC.last_frame_lost := 0;
  end;
end;

// ---------------------------------------------------------------------------
// CNG
// ---------------------------------------------------------------------------

procedure SilkCNGExc(ExcQ14: PInteger; ExcBufQ14: PInteger; Length: Integer; var RandSeed: Integer);
var
  Seed, I, Idx, ExcMask: Integer;
begin
  ExcMask := SILK_CNG_BUF_MASK_MAX;
  while ExcMask > Length do
    ExcMask := Sar32(ExcMask, 1);
  Seed := RandSeed;
  for I := 0 to Length - 1 do
  begin
    Seed := SilkRand(Seed);
    Idx := Sar32(Seed, 24) and ExcMask;
    ExcQ14[I] := ExcBufQ14[Idx];
  end;
  RandSeed := Seed;
end;

procedure SilkCNG(var P: TSilkChannelState; var Ctl: TSilkDecoderControl; Frame: PSmallInt; Length: Integer);
var
  I, Subfr: Integer;
  LPCPredQ10, MaxGainQ16, GainQ16, GainQ10: Integer;
  AQ12: array[0..SILK_MAX_LPC_ORDER - 1] of SmallInt;
  CNGSigQ14: array[0..SILK_MAX_FRAME_LENGTH + SILK_MAX_LPC_ORDER - 1] of Integer;
begin
  if P.fs_kHz <> P.sCNG.fs_kHz then
  begin
    SilkCNGReset(P);
    P.sCNG.fs_kHz := P.fs_kHz;
  end;
  if (P.lossCnt = 0) and (P.prevSignalType = SILK_TYPE_NO_VOICE_ACTIVITY) then
  begin
    for I := 0 to P.LPC_order - 1 do
      P.sCNG.CNG_smth_NLSF_Q15[I] := SmallInt(P.sCNG.CNG_smth_NLSF_Q15[I] +
        SilkSMULWB(Integer(P.prevNLSF_Q15[I]) - Integer(P.sCNG.CNG_smth_NLSF_Q15[I]), SILK_CNG_NLSF_SMTH_Q16));
    MaxGainQ16 := 0;
    Subfr := 0;
    for I := 0 to P.nb_subfr - 1 do
      if Ctl.Gains_Q16[I] > MaxGainQ16 then
      begin
        MaxGainQ16 := Ctl.Gains_Q16[I];
        Subfr := I;
      end;
    Move(P.sCNG.CNG_exc_buf_Q14[0], P.sCNG.CNG_exc_buf_Q14[P.subfr_length], (P.nb_subfr - 1) * P.subfr_length * SizeOf(Integer));
    Move(P.exc_Q14[Subfr * P.subfr_length], P.sCNG.CNG_exc_buf_Q14[0], P.subfr_length * SizeOf(Integer));
    for I := 0 to P.nb_subfr - 1 do
    begin
      P.sCNG.CNG_smth_Gain_Q16 := P.sCNG.CNG_smth_Gain_Q16 +
        SilkSMULWB(Ctl.Gains_Q16[I] - P.sCNG.CNG_smth_Gain_Q16, SILK_CNG_GAIN_SMTH_Q16);
      if SilkSMULWW(P.sCNG.CNG_smth_Gain_Q16, SILK_CNG_GAIN_SMTH_THRESHOLD_Q16) > Ctl.Gains_Q16[I] then
        P.sCNG.CNG_smth_Gain_Q16 := Ctl.Gains_Q16[I];
    end;
  end;
  if P.lossCnt <> 0 then
  begin
    GainQ16 := SilkSMULWW(P.sPLC.randScale_Q14, P.sPLC.prevGain_Q16[1]);
    if (GainQ16 >= (1 shl 21)) or (P.sCNG.CNG_smth_Gain_Q16 > (1 shl 23)) then
    begin
      GainQ16 := SilkSMULTT(GainQ16, GainQ16);
      GainQ16 := SilkSMULTT(P.sCNG.CNG_smth_Gain_Q16, P.sCNG.CNG_smth_Gain_Q16) - (GainQ16 shl 5);
      GainQ16 := SilkSqrtApprox(GainQ16) shl 16;
    end
    else
    begin
      GainQ16 := SilkSMULWW(GainQ16, GainQ16);
      GainQ16 := SilkSMULWW(P.sCNG.CNG_smth_Gain_Q16, P.sCNG.CNG_smth_Gain_Q16) - (GainQ16 shl 5);
      GainQ16 := SilkSqrtApprox(GainQ16) shl 8;
    end;
    GainQ10 := Sar32(GainQ16, 6);
    SilkCNGExc(@CNGSigQ14[SILK_MAX_LPC_ORDER], @P.sCNG.CNG_exc_buf_Q14[0], Length, P.sCNG.rand_seed);
    SilkNLSF2A(@AQ12[0], @P.sCNG.CNG_smth_NLSF_Q15[0], P.LPC_order);
    Move(P.sCNG.CNG_synth_state[0], CNGSigQ14[0], SILK_MAX_LPC_ORDER * SizeOf(Integer));
    for I := 0 to Length - 1 do
    begin
      LPCPredQ10 := Sar32(P.LPC_order, 1);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, CNGSigQ14[SILK_MAX_LPC_ORDER + I - 1], AQ12[0]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, CNGSigQ14[SILK_MAX_LPC_ORDER + I - 2], AQ12[1]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, CNGSigQ14[SILK_MAX_LPC_ORDER + I - 3], AQ12[2]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, CNGSigQ14[SILK_MAX_LPC_ORDER + I - 4], AQ12[3]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, CNGSigQ14[SILK_MAX_LPC_ORDER + I - 5], AQ12[4]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, CNGSigQ14[SILK_MAX_LPC_ORDER + I - 6], AQ12[5]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, CNGSigQ14[SILK_MAX_LPC_ORDER + I - 7], AQ12[6]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, CNGSigQ14[SILK_MAX_LPC_ORDER + I - 8], AQ12[7]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, CNGSigQ14[SILK_MAX_LPC_ORDER + I - 9], AQ12[8]);
      LPCPredQ10 := SilkSMLAWB(LPCPredQ10, CNGSigQ14[SILK_MAX_LPC_ORDER + I - 10], AQ12[9]);
      if P.LPC_order = 16 then
      begin
        LPCPredQ10 := SilkSMLAWB(LPCPredQ10, CNGSigQ14[SILK_MAX_LPC_ORDER + I - 11], AQ12[10]);
        LPCPredQ10 := SilkSMLAWB(LPCPredQ10, CNGSigQ14[SILK_MAX_LPC_ORDER + I - 12], AQ12[11]);
        LPCPredQ10 := SilkSMLAWB(LPCPredQ10, CNGSigQ14[SILK_MAX_LPC_ORDER + I - 13], AQ12[12]);
        LPCPredQ10 := SilkSMLAWB(LPCPredQ10, CNGSigQ14[SILK_MAX_LPC_ORDER + I - 14], AQ12[13]);
        LPCPredQ10 := SilkSMLAWB(LPCPredQ10, CNGSigQ14[SILK_MAX_LPC_ORDER + I - 15], AQ12[14]);
        LPCPredQ10 := SilkSMLAWB(LPCPredQ10, CNGSigQ14[SILK_MAX_LPC_ORDER + I - 16], AQ12[15]);
      end;
      CNGSigQ14[SILK_MAX_LPC_ORDER + I] := SilkAddSat32(CNGSigQ14[SILK_MAX_LPC_ORDER + I], SilkLShiftSat32(LPCPredQ10, 4));
      Frame[I] := SmallInt(SilkSat16(Integer(Frame[I]) +
        SilkSat16(SilkRShiftRound(SilkSMULWW(CNGSigQ14[SILK_MAX_LPC_ORDER + I], GainQ10), 8))));
    end;
    Move(CNGSigQ14[Length], P.sCNG.CNG_synth_state[0], SILK_MAX_LPC_ORDER * SizeOf(Integer));
  end
  else
    FillChar(P.sCNG.CNG_synth_state, P.LPC_order * SizeOf(Integer), 0);
end;

// ---------------------------------------------------------------------------
// decode_frame
// ---------------------------------------------------------------------------

function SilkDecodeFrame(var P: TSilkChannelState; var Rd: TEcDec; POut: PSmallInt;
  out PN: Integer; LostFlag, CondCoding: Integer): Integer;
var
  Ctl: TSilkDecoderControl;
  L, MvLen: Integer;
  Pulses: array[0..SILK_MAX_FRAME_LENGTH + SILK_SHELL_CODEC_FRAME_LENGTH - 1] of SmallInt;
begin
  Result := 0;
  L := P.frame_length;
  FillChar(Ctl, SizeOf(Ctl), 0);
  Ctl.LTP_scale_Q14 := 0;
  if (LostFlag = SILK_FLAG_DECODE_NORMAL) or
     ((LostFlag = SILK_FLAG_DECODE_LBRR) and (P.LBRR_flags[P.nFramesDecoded] = 1)) then
  begin
    FillChar(Pulses, SizeOf(Pulses), 0);
    SilkDecodeIndices(P, Rd, P.nFramesDecoded, LostFlag <> 0, CondCoding);
    SilkDecodePulses(Rd, @Pulses[0], P.indices.signalType, P.indices.quantOffsetType, P.frame_length);
    SilkDecodeParameters(P, Ctl, CondCoding);
    SilkDecodeCore(P, Ctl, POut, @Pulses[0]);
    MvLen := P.ltp_mem_length - P.frame_length;
    Move(P.outBuf[P.frame_length], P.outBuf[0], MvLen * SizeOf(SmallInt));
    Move(POut^, P.outBuf[MvLen], P.frame_length * SizeOf(SmallInt));
    SilkPLC(P, Ctl, POut, False);
    P.lossCnt := 0;
    P.prevSignalType := P.indices.signalType;
    P.first_frame_after_reset := 0;
  end
  else
  begin
    SilkPLC(P, Ctl, POut, True);
    MvLen := P.ltp_mem_length - P.frame_length;
    Move(P.outBuf[P.frame_length], P.outBuf[0], MvLen * SizeOf(SmallInt));
    Move(POut^, P.outBuf[MvLen], P.frame_length * SizeOf(SmallInt));
  end;
  SilkCNG(P, Ctl, POut, L);
  SilkPLCGlueFrames(P, POut, L);
  P.lagPrev := Ctl.pitchL[P.nb_subfr - 1];
  PN := L;
end;

// ---------------------------------------------------------------------------
// Stereo
// ---------------------------------------------------------------------------

procedure SilkStereoDecodePred(var Rd: TEcDec; PredQ13: PInteger);
var
  N: Integer;
  Ix: array[0..1, 0..2] of Integer;
  LowQ13, StepQ13: Integer;
begin
  N := EcDecIcdf(Rd, @SILK_STEREO_PRED_JOINT_ICDF[0], 8);
  Ix[0][2] := N div 5;
  Ix[1][2] := N - 5 * Ix[0][2];
  for N := 0 to 1 do
  begin
    Ix[N][0] := EcDecIcdf(Rd, @SILK_UNIFORM3_ICDF[0], 8);
    Ix[N][1] := EcDecIcdf(Rd, @SILK_UNIFORM5_ICDF[0], 8);
  end;
  for N := 0 to 1 do
  begin
    Ix[N][0] := Ix[N][0] + 3 * Ix[N][2];
    LowQ13 := SILK_STEREO_PRED_QUANT_Q13[Ix[N][0]];
    StepQ13 := SilkSMULWB(SILK_STEREO_PRED_QUANT_Q13[Ix[N][0] + 1] - LowQ13, 6554);  // 0.5/5 in Q16
    PredQ13[N] := SilkSMLABB(LowQ13, StepQ13, 2 * Ix[N][1] + 1);
  end;
  PredQ13[0] := PredQ13[0] - PredQ13[1];
end;

procedure SilkStereoMSToLR(var St: TSilkStereoDecState; X1, X2: PSmallInt; PredQ13: PInteger;
  FsKHz, FrameLength: Integer);
var
  N, DenomQ16, Delta0Q13, Delta1Q13: Integer;
  Sum, Diff, Pred0Q13, Pred1Q13: Integer;
begin
  Move(St.sMid[0], X1^, 2 * SizeOf(SmallInt));
  Move(St.sSide[0], X2^, 2 * SizeOf(SmallInt));
  Move(X1[FrameLength], St.sMid[0], 2 * SizeOf(SmallInt));
  Move(X2[FrameLength], St.sSide[0], 2 * SizeOf(SmallInt));
  Pred0Q13 := St.pred_prev_Q13[0];
  Pred1Q13 := St.pred_prev_Q13[1];
  DenomQ16 := (1 shl 16) div (SILK_STEREO_INTERP_LEN_MS * FsKHz);
  Delta0Q13 := SilkRShiftRound(SilkSMULBB(PredQ13[0] - St.pred_prev_Q13[0], DenomQ16), 16);
  Delta1Q13 := SilkRShiftRound(SilkSMULBB(PredQ13[1] - St.pred_prev_Q13[1], DenomQ16), 16);
  for N := 0 to SILK_STEREO_INTERP_LEN_MS * FsKHz - 1 do
  begin
    Pred0Q13 := Pred0Q13 + Delta0Q13;
    Pred1Q13 := Pred1Q13 + Delta1Q13;
    Sum := ((Integer(X1[N]) + Integer(X1[N + 2])) + (Integer(X1[N + 1]) shl 1)) shl 9;
    Sum := SilkSMLAWB(Integer(X2[N + 1]) shl 8, Sum, Pred0Q13);
    Sum := SilkSMLAWB(Sum, Integer(X1[N + 1]) shl 11, Pred1Q13);
    X2[N + 1] := SmallInt(SilkSat16(SilkRShiftRound(Sum, 8)));
  end;
  Pred0Q13 := PredQ13[0];
  Pred1Q13 := PredQ13[1];
  for N := SILK_STEREO_INTERP_LEN_MS * FsKHz to FrameLength - 1 do
  begin
    Sum := ((Integer(X1[N]) + Integer(X1[N + 2])) + (Integer(X1[N + 1]) shl 1)) shl 9;
    Sum := SilkSMLAWB(Integer(X2[N + 1]) shl 8, Sum, Pred0Q13);
    Sum := SilkSMLAWB(Sum, Integer(X1[N + 1]) shl 11, Pred1Q13);
    X2[N + 1] := SmallInt(SilkSat16(SilkRShiftRound(Sum, 8)));
  end;
  St.pred_prev_Q13[0] := SmallInt(PredQ13[0]);
  St.pred_prev_Q13[1] := SmallInt(PredQ13[1]);
  for N := 0 to FrameLength - 1 do
  begin
    Sum := Integer(X1[N + 1]) + Integer(X2[N + 1]);
    Diff := Integer(X1[N + 1]) - Integer(X2[N + 1]);
    X1[N + 1] := SmallInt(SilkSat16(Sum));
    X2[N + 1] := SmallInt(SilkSat16(Diff));
  end;
end;

// ---------------------------------------------------------------------------
// TSilkDecoder (dec_API.c)
// ---------------------------------------------------------------------------

constructor TSilkDecoder.Create;
begin
  inherited Create;
  Reset;
end;

procedure TSilkDecoder.Reset;
var
  N: Integer;
begin
  for N := 0 to 1 do
    SilkResetDecoder(FChannel[N]);
  FillChar(FStereo, SizeOf(FStereo), 0);
  FPrevDecodeOnlyMiddle := 0;
  FnChannelsAPI := 0;
  FnChannelsInternal := 0;
end;

function TSilkDecoder.Decode(var Ctl: TSilkDecControl; LostFlag: Integer; NewPacketFlag: Boolean;
  var Rd: TEcDec; SamplesOut: PSmallInt; out nSamplesOut: Integer): Integer;
var
  I, N, DecodeOnlyMiddle: Integer;
  nSamplesOutDec, LBRRSymbol: Integer;
  Tmp1: array[0..1, 0..SILK_MAX_FRAME_LENGTH + 1] of SmallInt;
  Tmp2: array[0..48 * 20 - 1] of SmallInt;   // resampled mono channel at 48 kHz (20 ms)
  MSPredQ13: array[0..1] of Integer;
  HasSide: Boolean;
  StereoToMono: Boolean;
  FrameIndex, CondCoding: Integer;
  FsKHzDec: Integer;
  Pulses: array[0..SILK_MAX_FRAME_LENGTH - 1] of SmallInt;
  ResampleOut: PSmallInt;
begin
  Result := 0;
  DecodeOnlyMiddle := 0;
  MSPredQ13[0] := 0; MSPredQ13[1] := 0;
  nSamplesOutDec := 0;

  if NewPacketFlag then
    for N := 0 to Ctl.nChannelsInternal - 1 do
      FChannel[N].nFramesDecoded := 0;

  if Ctl.nChannelsInternal > FnChannelsInternal then
    SilkResetDecoder(FChannel[1]);

  StereoToMono := (Ctl.nChannelsInternal = 1) and (FnChannelsInternal = 2) and
                  (Ctl.internalSampleRate = 1000 * FChannel[0].fs_kHz);

  if FChannel[0].nFramesDecoded = 0 then
  begin
    for N := 0 to Ctl.nChannelsInternal - 1 do
    begin
      case Ctl.payloadSize_ms of
        0, 10: begin FChannel[N].nFramesPerPacket := 1; FChannel[N].nb_subfr := 2; end;
        20:    begin FChannel[N].nFramesPerPacket := 1; FChannel[N].nb_subfr := 4; end;
        40:    begin FChannel[N].nFramesPerPacket := 2; FChannel[N].nb_subfr := 4; end;
        60:    begin FChannel[N].nFramesPerPacket := 3; FChannel[N].nb_subfr := 4; end;
      else
        Exit(-1);
      end;
      FsKHzDec := (Ctl.internalSampleRate shr 10) + 1;
      if (FsKHzDec <> 8) and (FsKHzDec <> 12) and (FsKHzDec <> 16) then Exit(-1);
      Result := Result + SilkDecoderSetFs(FChannel[N], FsKHzDec, SILK_API_FS_HZ);
    end;
  end;

  if (Ctl.nChannelsAPI = 2) and (Ctl.nChannelsInternal = 2) and ((FnChannelsAPI = 1) or (FnChannelsInternal = 1)) then
  begin
    FillChar(FStereo.pred_prev_Q13, SizeOf(FStereo.pred_prev_Q13), 0);
    FillChar(FStereo.sSide, SizeOf(FStereo.sSide), 0);
    FChannel[1].resampler_state := FChannel[0].resampler_state;
  end;
  FnChannelsAPI := Ctl.nChannelsAPI;
  FnChannelsInternal := Ctl.nChannelsInternal;

  if (LostFlag <> SILK_FLAG_PACKET_LOST) and (FChannel[0].nFramesDecoded = 0) then
  begin
    for N := 0 to Ctl.nChannelsInternal - 1 do
    begin
      for I := 0 to FChannel[N].nFramesPerPacket - 1 do
        FChannel[N].VAD_flags[I] := EcDecBitLogp(Rd, 1);
      FChannel[N].LBRR_flag := EcDecBitLogp(Rd, 1);
    end;
    for N := 0 to Ctl.nChannelsInternal - 1 do
    begin
      FillChar(FChannel[N].LBRR_flags, SizeOf(FChannel[N].LBRR_flags), 0);
      if FChannel[N].LBRR_flag <> 0 then
      begin
        if FChannel[N].nFramesPerPacket = 1 then
          FChannel[N].LBRR_flags[0] := 1
        else
        begin
          if FChannel[N].nFramesPerPacket = 2 then
            LBRRSymbol := EcDecIcdf(Rd, @SILK_LBRR_FLAGS_2_ICDF[0], 8) + 1
          else
            LBRRSymbol := EcDecIcdf(Rd, @SILK_LBRR_FLAGS_3_ICDF[0], 8) + 1;
          for I := 0 to FChannel[N].nFramesPerPacket - 1 do
            FChannel[N].LBRR_flags[I] := (LBRRSymbol shr I) and 1;
        end;
      end;
    end;
    if LostFlag = SILK_FLAG_DECODE_NORMAL then
    begin
      // Regular decoding: skip all LBRR data
      for I := 0 to FChannel[0].nFramesPerPacket - 1 do
        for N := 0 to Ctl.nChannelsInternal - 1 do
          if FChannel[N].LBRR_flags[I] <> 0 then
          begin
            if (Ctl.nChannelsInternal = 2) and (N = 0) then
            begin
              SilkStereoDecodePred(Rd, @MSPredQ13[0]);
              if FChannel[1].LBRR_flags[I] = 0 then
                DecodeOnlyMiddle := EcDecIcdf(Rd, @SILK_STEREO_ONLY_CODE_MID_ICDF[0], 8);
            end;
            if (I > 0) and (FChannel[N].LBRR_flags[I - 1] <> 0) then
              CondCoding := SILK_CODE_CONDITIONALLY
            else
              CondCoding := SILK_CODE_INDEPENDENTLY;
            SilkDecodeIndices(FChannel[N], Rd, I, True, CondCoding);
            SilkDecodePulses(Rd, @Pulses[0], FChannel[N].indices.signalType,
              FChannel[N].indices.quantOffsetType, FChannel[N].frame_length);
          end;
    end;
  end;

  if Ctl.nChannelsInternal = 2 then
  begin
    if (LostFlag = SILK_FLAG_DECODE_NORMAL) or
       ((LostFlag = SILK_FLAG_DECODE_LBRR) and (FChannel[0].LBRR_flags[FChannel[0].nFramesDecoded] = 1)) then
    begin
      SilkStereoDecodePred(Rd, @MSPredQ13[0]);
      if ((LostFlag = SILK_FLAG_DECODE_NORMAL) and (FChannel[1].VAD_flags[FChannel[0].nFramesDecoded] = 0)) or
         ((LostFlag = SILK_FLAG_DECODE_LBRR) and (FChannel[1].LBRR_flags[FChannel[0].nFramesDecoded] = 0)) then
        DecodeOnlyMiddle := EcDecIcdf(Rd, @SILK_STEREO_ONLY_CODE_MID_ICDF[0], 8)
      else
        DecodeOnlyMiddle := 0;
    end
    else
      for N := 0 to 1 do
        MSPredQ13[N] := FStereo.pred_prev_Q13[N];
  end;

  if (Ctl.nChannelsInternal = 2) and (DecodeOnlyMiddle = 0) and (FPrevDecodeOnlyMiddle = 1) then
  begin
    FillChar(FChannel[1].outBuf, SizeOf(FChannel[1].outBuf), 0);
    FillChar(FChannel[1].sLPC_Q14_buf, SizeOf(FChannel[1].sLPC_Q14_buf), 0);
    FChannel[1].lagPrev := 100;
    FChannel[1].LastGainIndex := 10;
    FChannel[1].prevSignalType := SILK_TYPE_NO_VOICE_ACTIVITY;
    FChannel[1].first_frame_after_reset := 1;
  end;

  if LostFlag = SILK_FLAG_DECODE_NORMAL then
    HasSide := DecodeOnlyMiddle = 0
  else
    HasSide := (FPrevDecodeOnlyMiddle = 0) or
      ((Ctl.nChannelsInternal = 2) and (LostFlag = SILK_FLAG_DECODE_LBRR) and
       (FChannel[1].LBRR_flags[FChannel[1].nFramesDecoded] = 1));

  for N := 0 to Ctl.nChannelsInternal - 1 do
  begin
    if (N = 0) or HasSide then
    begin
      FrameIndex := FChannel[0].nFramesDecoded - N;
      if FrameIndex <= 0 then
        CondCoding := SILK_CODE_INDEPENDENTLY
      else if LostFlag = SILK_FLAG_DECODE_LBRR then
      begin
        if FChannel[N].LBRR_flags[FrameIndex - 1] <> 0 then CondCoding := SILK_CODE_CONDITIONALLY
        else CondCoding := SILK_CODE_INDEPENDENTLY;
      end
      else if (N > 0) and (FPrevDecodeOnlyMiddle <> 0) then
        CondCoding := SILK_CODE_INDEPENDENTLY_NO_LTP_SCALING
      else
        CondCoding := SILK_CODE_CONDITIONALLY;
      Result := Result + SilkDecodeFrame(FChannel[N], Rd, @Tmp1[N][2], nSamplesOutDec, LostFlag, CondCoding);
      if (N = 0) and Assigned(SilkDebugWrite) then
        SilkDebugWrite(@Tmp1[0][2], nSamplesOutDec * SizeOf(SmallInt));
    end
    else
      FillChar(Tmp1[N][2], nSamplesOutDec * SizeOf(SmallInt), 0);
    Inc(FChannel[N].nFramesDecoded);
  end;

  if (Ctl.nChannelsAPI = 2) and (Ctl.nChannelsInternal = 2) then
    SilkStereoMSToLR(FStereo, @Tmp1[0][0], @Tmp1[1][0], @MSPredQ13[0], FChannel[0].fs_kHz, nSamplesOutDec)
  else
  begin
    Move(FStereo.sMid[0], Tmp1[0][0], 2 * SizeOf(SmallInt));
    Move(Tmp1[0][nSamplesOutDec], FStereo.sMid[0], 2 * SizeOf(SmallInt));
  end;

  nSamplesOut := (nSamplesOutDec * SILK_API_FS_HZ) div (FChannel[0].fs_kHz * 1000);

  if Ctl.nChannelsAPI = 2 then ResampleOut := @Tmp2[0] else ResampleOut := SamplesOut;
  for N := 0 to Min(Ctl.nChannelsAPI, Ctl.nChannelsInternal) - 1 do
  begin
    Result := Result + SilkResampler(FChannel[N].resampler_state, ResampleOut, @Tmp1[N][1], nSamplesOutDec);
    if Ctl.nChannelsAPI = 2 then
      for I := 0 to nSamplesOut - 1 do
        SamplesOut[N + 2 * I] := ResampleOut[I];
  end;

  if (Ctl.nChannelsAPI = 2) and (Ctl.nChannelsInternal = 1) then
  begin
    if StereoToMono then
    begin
      Result := Result + SilkResampler(FChannel[1].resampler_state, ResampleOut, @Tmp1[0][1], nSamplesOutDec);
      for I := 0 to nSamplesOut - 1 do
        SamplesOut[1 + 2 * I] := ResampleOut[I];
    end
    else
      for I := 0 to nSamplesOut - 1 do
        SamplesOut[1 + 2 * I] := SamplesOut[2 * I];
  end;

  if FChannel[0].prevSignalType = SILK_TYPE_VOICED then
  begin
    case (FChannel[0].fs_kHz - 8) shr 2 of
      0: Ctl.prevPitchLag := FChannel[0].lagPrev * 6;
      1: Ctl.prevPitchLag := FChannel[0].lagPrev * 4;
    else Ctl.prevPitchLag := FChannel[0].lagPrev * 3;
    end;
  end
  else
    Ctl.prevPitchLag := 0;

  if LostFlag = SILK_FLAG_PACKET_LOST then
  begin
    for I := 0 to FnChannelsInternal - 1 do
      FChannel[I].LastGainIndex := 10;
  end
  else
    FPrevDecodeOnlyMiddle := DecodeOnlyMiddle;
end;

initialization
  NLSF_CB_NB_MB.nVectors := 32;
  NLSF_CB_NB_MB.order := 10;
  NLSF_CB_NB_MB.quantStepSize_Q16 := 11796;      // SILK_FIX_CONST(0.18, 16)
  NLSF_CB_NB_MB.invQuantStepSize_Q6 := 356;      // SILK_FIX_CONST(1/0.18, 6)
  NLSF_CB_NB_MB.CB1_NLSF_Q8 := @SILK_NLSF_CB1_NB_MB_Q8[0];
  NLSF_CB_NB_MB.CB1_Wght_Q9 := @SILK_NLSF_CB1_NB_MB_WGHT_Q9[0];
  NLSF_CB_NB_MB.CB1_iCDF := @SILK_NLSF_CB1_ICDF_NB_MB[0];
  NLSF_CB_NB_MB.pred_Q8 := @SILK_NLSF_PRED_NB_MB_Q8[0];
  NLSF_CB_NB_MB.ec_sel := @SILK_NLSF_CB2_SELECT_NB_MB[0];
  NLSF_CB_NB_MB.ec_iCDF := @SILK_NLSF_CB2_ICDF_NB_MB[0];
  NLSF_CB_NB_MB.deltaMin_Q15 := @SILK_NLSF_DELTA_MIN_NB_MB_Q15[0];

  NLSF_CB_WB.nVectors := 32;
  NLSF_CB_WB.order := 16;
  NLSF_CB_WB.quantStepSize_Q16 := 9830;          // SILK_FIX_CONST(0.15, 16)
  NLSF_CB_WB.invQuantStepSize_Q6 := 427;         // SILK_FIX_CONST(1/0.15, 6)
  NLSF_CB_WB.CB1_NLSF_Q8 := @SILK_NLSF_CB1_WB_Q8[0];
  NLSF_CB_WB.CB1_Wght_Q9 := @SILK_NLSF_CB1_WB_WGHT_Q9[0];
  NLSF_CB_WB.CB1_iCDF := @SILK_NLSF_CB1_ICDF_WB[0];
  NLSF_CB_WB.pred_Q8 := @SILK_NLSF_PRED_WB_Q8[0];
  NLSF_CB_WB.ec_sel := @SILK_NLSF_CB2_SELECT_WB[0];
  NLSF_CB_WB.ec_iCDF := @SILK_NLSF_CB2_ICDF_WB[0];
  NLSF_CB_WB.deltaMin_Q15 := @SILK_NLSF_DELTA_MIN_WB_Q15[0];

end.
