unit OpusSilkEncDefs;

{
  OpusSilkEncDefs.pas - SILK encoder constants, state records and codebooks

  Port of libopus 1.5.2 silk/define.h, tuning_parameters.h, structs.h,
  float/structs_FLP.h, resampler_structs.h, pitch_est_defines.h and the
  pointer tables / codebook structs of tables_*.c.
  Copyright (c) 2006-2011 Skype Limited; Xiph.Org Foundation.

  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

interface

uses
  OpusSilkMath, OpusSilkEncTables;

const
  ENCODER_NUM_CHANNELS = 2;
  MAX_FRAMES_PER_PACKET = 3;
  MIN_TARGET_RATE_BPS = 5000;
  MAX_TARGET_RATE_BPS = 80000;
  LBRR_NB_MIN_RATE_BPS = 12000;
  LBRR_MB_MIN_RATE_BPS = 14000;
  LBRR_WB_MIN_RATE_BPS = 16000;
  NB_SPEECH_FRAMES_BEFORE_DTX = 10;
  MAX_CONSECUTIVE_DTX = 20;
  VAD_NO_DECISION = -1;
  VAD_NO_ACTIVITY = 0;
  VAD_ACTIVITY = 1;
  MAX_FS_KHZ = 16;
  MAX_API_FS_KHZ = 48;
  TYPE_NO_VOICE_ACTIVITY = 0;
  TYPE_UNVOICED = 1;
  TYPE_VOICED = 2;
  CODE_INDEPENDENTLY = 0;
  CODE_INDEPENDENTLY_NO_LTP_SCALING = 1;
  CODE_CONDITIONALLY = 2;
  STEREO_QUANT_TAB_SIZE = 16;
  STEREO_QUANT_SUB_STEPS = 5;
  STEREO_INTERP_LEN_MS = 8;
  PITCH_EST_MIN_LAG_MS = 2;
  PITCH_EST_MAX_LAG_MS = 18;
  MAX_NB_SUBFR = 4;
  LTP_MEM_LENGTH_MS = 20;
  SUB_FRAME_LENGTH_MS = 5;
  MAX_SUB_FRAME_LENGTH = SUB_FRAME_LENGTH_MS * MAX_FS_KHZ;
  MAX_FRAME_LENGTH_MS = SUB_FRAME_LENGTH_MS * MAX_NB_SUBFR;
  MAX_FRAME_LENGTH = MAX_FRAME_LENGTH_MS * MAX_FS_KHZ;
  LA_PITCH_MS = 2;
  LA_PITCH_MAX = LA_PITCH_MS * MAX_FS_KHZ;
  MAX_FIND_PITCH_LPC_ORDER = 16;
  FIND_PITCH_LPC_WIN_MS = 20 + (LA_PITCH_MS shl 1);
  FIND_PITCH_LPC_WIN_MS_2_SF = 10 + (LA_PITCH_MS shl 1);
  FIND_PITCH_LPC_WIN_MAX = FIND_PITCH_LPC_WIN_MS * MAX_FS_KHZ;
  LA_SHAPE_MS = 5;
  LA_SHAPE_MAX = LA_SHAPE_MS * MAX_FS_KHZ;
  SHAPE_LPC_WIN_MAX = 15 * MAX_FS_KHZ;
  MIN_QGAIN_DB = 2;
  MAX_QGAIN_DB = 88;
  N_LEVELS_QGAIN = 64;
  MAX_DELTA_GAIN_QUANT = 36;
  MIN_DELTA_GAIN_QUANT = -4;
  OFFSET_VL_Q10 = 32;
  OFFSET_VH_Q10 = 100;
  OFFSET_UVL_Q10 = 100;
  OFFSET_UVH_Q10 = 240;
  QUANT_LEVEL_ADJUST_Q10 = 80;
  MAX_LPC_STABILIZE_ITERATIONS = 16;
  MAX_LPC_ORDER = 16;
  MIN_LPC_ORDER = 10;
  LTP_ORDER = 5;
  NB_LTP_CBKS = 3;
  MAX_SHAPE_LPC_ORDER = 24;
  HARM_SHAPE_FIR_TAPS = 3;
  MAX_DEL_DEC_STATES = 4;
  DECISION_DELAY = 40;
  SHELL_CODEC_FRAME_LENGTH = 16;
  LOG2_SHELL_CODEC_FRAME_LENGTH = 4;
  MAX_NB_SHELL_BLOCKS = MAX_FRAME_LENGTH div SHELL_CODEC_FRAME_LENGTH;
  N_RATE_LEVELS = 10;
  SILK_MAX_PULSES = 16;
  NSQ_LPC_BUF_LENGTH = MAX_LPC_ORDER;
  VAD_N_BANDS = 4;
  VAD_INTERNAL_SUBFRAMES_LOG2 = 2;
  VAD_INTERNAL_SUBFRAMES = 1 shl VAD_INTERNAL_SUBFRAMES_LOG2;
  VAD_NOISE_LEVEL_SMOOTH_COEF_Q16 = 1024;
  VAD_NOISE_LEVELS_BIAS = 50;
  VAD_NEGATIVE_OFFSET_Q5 = 128;
  VAD_SNR_FACTOR_Q16 = 45000;
  VAD_SNR_SMOOTH_COEF_Q18 = 4096;
  LSF_COS_TAB_SZ_FIX = 128;
  NLSF_W_Q = 2;
  NLSF_VQ_MAX_VECTORS = 32;
  NLSF_QUANT_MAX_AMPLITUDE = 4;
  NLSF_QUANT_MAX_AMPLITUDE_EXT = 10;
  NLSF_QUANT_DEL_DEC_STATES_LOG2 = 2;
  NLSF_QUANT_DEL_DEC_STATES = 1 shl NLSF_QUANT_DEL_DEC_STATES_LOG2;
  TRANSITION_TIME_MS = 5120;
  TRANSITION_NB = 3;
  TRANSITION_NA = 2;
  TRANSITION_INT_NUM = 5;
  TRANSITION_FRAMES = TRANSITION_TIME_MS div MAX_FRAME_LENGTH_MS;
  TRANSITION_INT_STEPS = TRANSITION_FRAMES div (TRANSITION_INT_NUM - 1);

  // tuning_parameters.h (C float literals -> Single, used in float code)
  BITRESERVOIR_DECAY_TIME_MS = 500;
  VARIABLE_HP_MIN_CUTOFF_HZ = 60;
  VARIABLE_HP_MAX_CUTOFF_HZ = 100;
  REDUCE_BITRATE_10_MS_BPS = 2200;
  MAX_BANDWIDTH_SWITCH_DELAY_MS = 5000;

  // pitch_est_defines.h
  PE_MAX_FS_KHZ = 16;
  PE_MAX_NB_SUBFR = 4;
  PE_SUBFR_LENGTH_MS = 5;
  PE_LTP_MEM_LENGTH_MS = 4 * PE_SUBFR_LENGTH_MS;
  PE_MAX_FRAME_LENGTH_MS = PE_LTP_MEM_LENGTH_MS + PE_MAX_NB_SUBFR * PE_SUBFR_LENGTH_MS;
  PE_MAX_FRAME_LENGTH = PE_MAX_FRAME_LENGTH_MS * PE_MAX_FS_KHZ;
  PE_MAX_FRAME_LENGTH_ST_1 = PE_MAX_FRAME_LENGTH shr 2;
  PE_MAX_FRAME_LENGTH_ST_2 = PE_MAX_FRAME_LENGTH shr 1;
  PE_MAX_LAG_MS = 18;
  PE_MIN_LAG_MS = 2;
  PE_MAX_LAG = PE_MAX_LAG_MS * PE_MAX_FS_KHZ;
  PE_MIN_LAG = PE_MIN_LAG_MS * PE_MAX_FS_KHZ;
  PE_D_SRCH_LENGTH = 24;
  PE_NB_STAGE3_LAGS = 5;
  PE_NB_CBKS_STAGE2 = 3;
  PE_NB_CBKS_STAGE2_EXT = 11;
  PE_NB_CBKS_STAGE3_MAX = 34;
  PE_NB_CBKS_STAGE3_MID = 24;
  PE_NB_CBKS_STAGE3_MIN = 16;
  PE_NB_CBKS_STAGE3_10MS = 12;
  PE_NB_CBKS_STAGE2_10MS = 3;
  SILK_PE_MIN_COMPLEX = 0;
  SILK_PE_MID_COMPLEX = 1;
  SILK_PE_MAX_COMPLEX = 2;

  // resampler
  SILK_RESAMPLER_MAX_FIR_ORDER = 36;
  SILK_RESAMPLER_MAX_IIR_ORDER = 6;
  RESAMPLER_DOWN_ORDER_FIR0 = 18;
  RESAMPLER_DOWN_ORDER_FIR1 = 24;
  RESAMPLER_DOWN_ORDER_FIR2 = 36;
  RESAMPLER_ORDER_FIR_12 = 8;
  RESAMPLER_MAX_BATCH_SIZE_MS = 10;
  RESAMPLER_MAX_FS_KHZ = 48;
  RESAMPLER_MAX_BATCH_SIZE_IN = RESAMPLER_MAX_BATCH_SIZE_MS * RESAMPLER_MAX_FS_KHZ;
  SILK_RESAMPLER_DOWN2_0 = 9872;
  SILK_RESAMPLER_DOWN2_1 = 39809 - 65536;

  SILK_INT32_MAX = 2147483647;
  SILK_INT32_MIN = Integer($80000000);
  SILK_INT16_MAX = 32767;
  SILK_INT16_MIN = -32768;

  // Error codes (errors.h)
  SILK_NO_ERROR = 0;
  SILK_ENC_INPUT_INVALID_NO_OF_SAMPLES = -101;
  SILK_ENC_FS_NOT_SUPPORTED = -102;
  SILK_ENC_PACKET_SIZE_NOT_SUPPORTED = -103;
  SILK_ENC_PAYLOAD_BUF_TOO_SHORT = -104;
  SILK_ENC_INVALID_LOSS_RATE = -105;
  SILK_ENC_INVALID_COMPLEXITY_SETTING = -106;
  SILK_ENC_INVALID_INBAND_FEC_SETTING = -107;
  SILK_ENC_INVALID_DTX_SETTING = -108;
  SILK_ENC_INVALID_CBR_SETTING = -109;
  SILK_ENC_INTERNAL_ERROR = -110;
  SILK_ENC_INVALID_NUMBER_OF_CHANNELS_ERROR = -111;

type

  TSilkNLSFCB = record
    nVectors           : Integer;
    order              : Integer;
    quantStepSize_Q16  : Integer;
    invQuantStepSize_Q6: Integer;
    CB1_NLSF_Q8        : PByte;
    CB1_Wght_Q9        : PSmallInt;
    CB1_iCDF           : PByte;
    pred_Q8            : PByte;
    ec_sel             : PByte;
    ec_iCDF            : PByte;
    ec_Rates_Q5        : PByte;
    deltaMin_Q15       : PSmallInt;
  end;
  PSilkNLSFCB = ^TSilkNLSFCB;

  TSilkNSQState = record
    xq              : array[0..2 * MAX_FRAME_LENGTH - 1] of SmallInt;
    sLTP_shp_Q14    : array[0..2 * MAX_FRAME_LENGTH - 1] of Integer;
    sLPC_Q14        : array[0..MAX_SUB_FRAME_LENGTH + NSQ_LPC_BUF_LENGTH - 1] of Integer;
    sAR2_Q14        : array[0..MAX_SHAPE_LPC_ORDER - 1] of Integer;
    sLF_AR_shp_Q14  : Integer;
    sDiff_shp_Q14   : Integer;
    lagPrev         : Integer;
    sLTP_buf_idx    : Integer;
    sLTP_shp_buf_idx: Integer;
    rand_seed       : Integer;
    prev_gain_Q16   : Integer;
    rewhite_flag    : Integer;
  end;

  TSilkVADState = record
    AnaState       : array[0..1] of Integer;
    AnaState1      : array[0..1] of Integer;
    AnaState2      : array[0..1] of Integer;
    XnrgSubfr      : array[0..VAD_N_BANDS - 1] of Integer;
    NrgRatioSmth_Q8: array[0..VAD_N_BANDS - 1] of Integer;
    HPstate        : SmallInt;
    NL             : array[0..VAD_N_BANDS - 1] of Integer;
    inv_NL         : array[0..VAD_N_BANDS - 1] of Integer;
    NoiseLevelBias : array[0..VAD_N_BANDS - 1] of Integer;
    counter        : Integer;
  end;

  TSilkLPState = record
    In_LP_State        : array[0..1] of Integer;
    transition_frame_no: Integer;
    mode               : Integer;
    saved_fs_kHz       : Integer;
  end;

  TStereoEncState = record
    pred_prev_Q13  : array[0..1] of SmallInt;
    sMid           : array[0..1] of SmallInt;
    sSide          : array[0..1] of SmallInt;
    mid_side_amp_Q0: array[0..3] of Integer;
    smth_width_Q14 : SmallInt;
    width_prev_Q14 : SmallInt;
    silent_side_len: SmallInt;
    predIx         : array[0..MAX_FRAMES_PER_PACKET - 1, 0..1, 0..2] of ShortInt;
    mid_only_flags : array[0..MAX_FRAMES_PER_PACKET - 1] of ShortInt;
  end;

  TSideInfoIndices = record
    GainsIndices     : array[0..MAX_NB_SUBFR - 1] of ShortInt;
    LTPIndex         : array[0..MAX_NB_SUBFR - 1] of ShortInt;
    NLSFIndices      : array[0..MAX_LPC_ORDER] of ShortInt;
    lagIndex         : SmallInt;
    contourIndex     : ShortInt;
    signalType       : ShortInt;
    quantOffsetType  : ShortInt;
    NLSFInterpCoef_Q2: ShortInt;
    PERIndex         : ShortInt;
    LTP_scaleIndex   : ShortInt;
    Seed             : ShortInt;
  end;

  TSilkResamplerState = record
    sIIR              : array[0..SILK_RESAMPLER_MAX_IIR_ORDER - 1] of Integer;
    sFIR              : array[0..SILK_RESAMPLER_MAX_FIR_ORDER - 1] of Integer;
    delayBuf          : array[0..47] of SmallInt;
    resampler_function: Integer;
    batchSize         : Integer;
    invRatio_Q16      : Integer;
    FIR_Order         : Integer;
    FIR_Fracs         : Integer;
    Fs_in_kHz         : Integer;
    Fs_out_kHz        : Integer;
    inputDelay        : Integer;
    Coefs             : PSmallInt;
  end;

  TSilkEncoderState = record
    In_HP_State                  : array[0..1] of Integer;
    variable_HP_smth1_Q15        : Integer;
    variable_HP_smth2_Q15        : Integer;
    sLP                          : TSilkLPState;
    sVAD                         : TSilkVADState;
    sNSQ                         : TSilkNSQState;
    prev_NLSFq_Q15               : array[0..MAX_LPC_ORDER - 1] of SmallInt;
    speech_activity_Q8           : Integer;
    allow_bandwidth_switch       : Integer;
    LBRRprevLastGainIndex        : ShortInt;
    prevSignalType               : ShortInt;
    prevLag                      : Integer;
    pitch_LPC_win_length         : Integer;
    max_pitch_lag                : Integer;
    API_fs_Hz                    : Integer;
    prev_API_fs_Hz               : Integer;
    maxInternal_fs_Hz            : Integer;
    minInternal_fs_Hz            : Integer;
    desiredInternal_fs_Hz        : Integer;
    fs_kHz                       : Integer;
    nb_subfr                     : Integer;
    frame_length                 : Integer;
    subfr_length                 : Integer;
    ltp_mem_length               : Integer;
    la_pitch                     : Integer;
    la_shape                     : Integer;
    shapeWinLength               : Integer;
    TargetRate_bps               : Integer;
    PacketSize_ms                : Integer;
    PacketLoss_perc              : Integer;
    frameCounter                 : Integer;
    Complexity                   : Integer;
    nStatesDelayedDecision       : Integer;
    useInterpolatedNLSFs         : Integer;
    shapingLPCOrder              : Integer;
    predictLPCOrder              : Integer;
    pitchEstimationComplexity    : Integer;
    pitchEstimationLPCOrder      : Integer;
    pitchEstimationThreshold_Q16 : Integer;
    sum_log_gain_Q7              : Integer;
    NLSF_MSVQ_Survivors          : Integer;
    first_frame_after_reset      : Integer;
    controlled_since_last_payload: Integer;
    warping_Q16                  : Integer;
    useCBR                       : Integer;
    prefillFlag                  : Integer;
    pitch_lag_low_bits_iCDF      : PByte;
    pitch_contour_iCDF           : PByte;
    psNLSF_CB                    : PSilkNLSFCB;
    input_quality_bands_Q15      : array[0..VAD_N_BANDS - 1] of Integer;
    input_tilt_Q15               : Integer;
    SNR_dB_Q7                    : Integer;
    VAD_flags                    : array[0..MAX_FRAMES_PER_PACKET - 1] of ShortInt;
    LBRR_flag                    : ShortInt;
    LBRR_flags                   : array[0..MAX_FRAMES_PER_PACKET - 1] of Integer;
    indices                      : TSideInfoIndices;
    pulses                       : array[0..MAX_FRAME_LENGTH - 1] of ShortInt;
    inputBuf                     : array[0..MAX_FRAME_LENGTH + 1] of SmallInt;
    inputBufIx                   : Integer;
    nFramesPerPacket             : Integer;
    nFramesEncoded               : Integer;
    nChannelsAPI                 : Integer;
    nChannelsInternal            : Integer;
    channelNb                    : Integer;
    frames_since_onset           : Integer;
    ec_prevSignalType            : Integer;
    ec_prevLagIndex              : SmallInt;
    resampler_state              : TSilkResamplerState;
    useDTX                       : Integer;
    inDTX                        : Integer;
    noSpeechCounter              : Integer;
    useInBandFEC                 : Integer;
    LBRR_enabled                 : Integer;
    LBRR_GainIncreases           : Integer;
    indices_LBRR                 : array[0..MAX_FRAMES_PER_PACKET - 1] of TSideInfoIndices;
    pulses_LBRR                  : array[0..MAX_FRAMES_PER_PACKET - 1, 0..MAX_FRAME_LENGTH - 1] of ShortInt;
  end;
  PSilkEncoderState = ^TSilkEncoderState;

  TSilkShapeStateFLP = record
    LastGainIndex     : ShortInt;
    HarmShapeGain_smth: Single;
    Tilt_smth         : Single;
  end;

  TSilkEncoderStateFLP = record
    sCmn   : TSilkEncoderState;
    sShape : TSilkShapeStateFLP;
    x_buf  : array[0..2 * MAX_FRAME_LENGTH + LA_SHAPE_MAX - 1] of Single;
    LTPCorr: Single;
  end;
  PSilkEncoderStateFLP = ^TSilkEncoderStateFLP;

  TSilkEncoderControlFLP = record
    Gains            : array[0..MAX_NB_SUBFR - 1] of Single;
    PredCoef         : array[0..1, 0..MAX_LPC_ORDER - 1] of Single;
    LTPCoef          : array[0..LTP_ORDER * MAX_NB_SUBFR - 1] of Single;
    LTP_scale        : Single;
    pitchL           : array[0..MAX_NB_SUBFR - 1] of Integer;
    AR               : array[0..MAX_NB_SUBFR * MAX_SHAPE_LPC_ORDER - 1] of Single;
    LF_MA_shp        : array[0..MAX_NB_SUBFR - 1] of Single;
    LF_AR_shp        : array[0..MAX_NB_SUBFR - 1] of Single;
    Tilt             : array[0..MAX_NB_SUBFR - 1] of Single;
    HarmShapeGain    : array[0..MAX_NB_SUBFR - 1] of Single;
    Lambda           : Single;
    input_quality    : Single;
    coding_quality   : Single;
    predGain         : Single;
    LTPredCodGain    : Single;
    ResNrg           : array[0..MAX_NB_SUBFR - 1] of Single;
    GainsUnq_Q16     : array[0..MAX_NB_SUBFR - 1] of Integer;
    lastGainIndexPrev: ShortInt;
  end;

  TSilkEncoder = record
    state_Fxx                : array[0..ENCODER_NUM_CHANNELS - 1] of TSilkEncoderStateFLP;
    sStereo                  : TStereoEncState;
    nBitsUsedLBRR            : Integer;
    nBitsExceeded            : Integer;
    nChannelsAPI             : Integer;
    nChannelsInternal        : Integer;
    nPrevChannelsInternal    : Integer;
    timeSinceSwitchAllowed_ms: Integer;
    allowBandwidthSwitch     : Integer;
    prev_decode_only_middle  : Integer;
  end;
  PSilkEncoder = ^TSilkEncoder;

var
  SILK_NLSF_CB_NB_MB: TSilkNLSFCB;
  SILK_NLSF_CB_WB   : TSilkNLSFCB;
  SILK_LTP_GAIN_ICDF_PTRS   : array[0..NB_LTP_CBKS - 1] of PByte;
  SILK_LTP_GAIN_BITS_Q5_PTRS: array[0..NB_LTP_CBKS - 1] of PByte;
  SILK_LTP_VQ_PTRS_Q7       : array[0..NB_LTP_CBKS - 1] of PShortInt;
  SILK_LTP_VQ_GAIN_PTRS_Q7  : array[0..NB_LTP_CBKS - 1] of PByte;

implementation

initialization
  with SILK_NLSF_CB_NB_MB do
  begin
    nVectors := 32;
    order := 10;
    quantStepSize_Q16 := 11796;     // SILK_FIX_CONST(0.18, 16)
    invQuantStepSize_Q6 := 356;     // SILK_FIX_CONST(1.0 / 0.18, 6)
    CB1_NLSF_Q8 := @SE_NLSF_CB1_NB_MB_Q8[0];
    CB1_Wght_Q9 := @SE_NLSF_CB1_WGHT_Q9[0];
    CB1_iCDF := @SE_NLSF_CB1_ICDF_NB_MB[0];
    pred_Q8 := @SE_NLSF_PRED_NB_MB_Q8[0];
    ec_sel := @SE_NLSF_CB2_SELECT_NB_MB[0];
    ec_iCDF := @SE_NLSF_CB2_ICDF_NB_MB[0];
    ec_Rates_Q5 := @SE_NLSF_CB2_BITS_NB_MB_Q5[0];
    deltaMin_Q15 := @SE_NLSF_DELTA_MIN_NB_MB_Q15[0];
  end;
  with SILK_NLSF_CB_WB do
  begin
    nVectors := 32;
    order := 16;
    quantStepSize_Q16 := 9830;      // SILK_FIX_CONST(0.15, 16)
    invQuantStepSize_Q6 := 427;     // SILK_FIX_CONST(1.0 / 0.15, 6)
    CB1_NLSF_Q8 := @SE_NLSF_CB1_WB_Q8[0];
    CB1_Wght_Q9 := @SE_NLSF_CB1_WB_WGHT_Q9[0];
    CB1_iCDF := @SE_NLSF_CB1_ICDF_WB[0];
    pred_Q8 := @SE_NLSF_PRED_WB_Q8[0];
    ec_sel := @SE_NLSF_CB2_SELECT_WB[0];
    ec_iCDF := @SE_NLSF_CB2_ICDF_WB[0];
    ec_Rates_Q5 := @SE_NLSF_CB2_BITS_WB_Q5[0];
    deltaMin_Q15 := @SE_NLSF_DELTA_MIN_WB_Q15[0];
  end;
  SILK_LTP_GAIN_ICDF_PTRS[0] := @SE_LTP_GAIN_ICDF_0[0];
  SILK_LTP_GAIN_ICDF_PTRS[1] := @SE_LTP_GAIN_ICDF_1[0];
  SILK_LTP_GAIN_ICDF_PTRS[2] := @SE_LTP_GAIN_ICDF_2[0];
  SILK_LTP_GAIN_BITS_Q5_PTRS[0] := @SE_LTP_GAIN_BITS_Q5_0[0];
  SILK_LTP_GAIN_BITS_Q5_PTRS[1] := @SE_LTP_GAIN_BITS_Q5_1[0];
  SILK_LTP_GAIN_BITS_Q5_PTRS[2] := @SE_LTP_GAIN_BITS_Q5_2[0];
  SILK_LTP_VQ_PTRS_Q7[0] := @SE_LTP_GAIN_VQ_0[0, 0];
  SILK_LTP_VQ_PTRS_Q7[1] := @SE_LTP_GAIN_VQ_1[0, 0];
  SILK_LTP_VQ_PTRS_Q7[2] := @SE_LTP_GAIN_VQ_2[0, 0];
  SILK_LTP_VQ_GAIN_PTRS_Q7[0] := @SE_LTP_GAIN_VQ_0_GAIN[0];
  SILK_LTP_VQ_GAIN_PTRS_Q7[1] := @SE_LTP_GAIN_VQ_1_GAIN[0];
  SILK_LTP_VQ_GAIN_PTRS_Q7[2] := @SE_LTP_GAIN_VQ_2_GAIN[0];
end.
