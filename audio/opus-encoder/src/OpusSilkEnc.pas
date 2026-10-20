unit OpusSilkEnc;

{
  OpusSilkEnc.pas - SILK encoder (float analysis build)

  Port of libopus 1.5.2 silk/enc_API.c, float/encode_frame_FLP.c,
  init_encoder.c, control_codec.c, control_SNR.c, control_audio_bandwidth.c,
  check_control_input.c, HP_variable_cutoff.c.
  Copyright (c) 2006-2011 Skype Limited; Xiph.Org Foundation.

  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$EXCESSPRECISION OFF}
{$Q-}{$R-}

interface

uses
  OpusEntEnc, OpusEncTypes, OpusSilkMath, OpusSilkEncTables, OpusSilkEncDefs, OpusSilkEncCore,
  OpusSilkEncCode, OpusSilkEncDSP, OpusSilkEncFLP;

function SilkInitEncoder(var Enc: TSilkEncoder; var Status: TSilkEncControl): Integer;
function SilkEncode(var Enc: TSilkEncoder; var Ctl: TSilkEncControl; SamplesIn: PSmallInt; NSamplesIn: Integer;
  var RangeEnc: TEcEnc; var NBytesOut: Integer; PrefillFlag, Activity: Integer): Integer;

implementation

const
  F_INV65536: Single = 1.0 / 65536.0;
  F_65536: Single = 65536.0;
  F_1E6: Single = 1e-6;
  F_15: Single = 1.5;
  ACTIVITY_THRESHOLD_Q8 = 13;   // SILK_FIX_CONST(SPEECH_ACTIVITY_DTX_THRES, 8)
  LBRR_SPEECH_ACTIVITY_THRES_Q8 = 77;

  SILK_TARGETRATE_NB_21: array[0..116 - 10] of Byte = (
    0, 15, 39, 52, 61, 68,
    74, 79, 84, 88, 92, 95, 99, 102, 105, 108, 111, 114, 117, 119, 122, 124,
    126, 129, 131, 133, 135, 137, 139, 142, 143, 145, 147, 149, 151, 153, 155, 157,
    158, 160, 162, 163, 165, 167, 168, 170, 171, 173, 174, 176, 177, 179, 180, 182,
    183, 185, 186, 187, 189, 190, 192, 193, 194, 196, 197, 199, 200, 201, 203, 204,
    205, 207, 208, 209, 211, 212, 213, 215, 216, 217, 219, 220, 221, 223, 224, 225,
    227, 228, 230, 231, 232, 234, 235, 236, 238, 239, 241, 242, 243, 245, 246, 248,
    249, 250, 252, 253, 255);
  SILK_TARGETRATE_MB_21: array[0..164 - 10] of Byte = (
    0, 0, 28, 43, 52, 59,
    65, 70, 74, 78, 81, 85, 87, 90, 93, 95, 98, 100, 102, 105, 107, 109,
    111, 113, 115, 116, 118, 120, 122, 123, 125, 127, 128, 130, 131, 133, 134, 136,
    137, 138, 140, 141, 143, 144, 145, 147, 148, 149, 151, 152, 153, 154, 156, 157,
    158, 159, 160, 162, 163, 164, 165, 166, 167, 168, 169, 171, 172, 173, 174, 175,
    176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 188, 189, 190,
    191, 192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 202, 203, 203, 204, 205,
    206, 207, 208, 209, 210, 211, 212, 213, 214, 214, 215, 216, 217, 218, 219, 220,
    221, 222, 223, 224, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235,
    236, 236, 237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250,
    251, 252, 253, 254, 255);
  SILK_TARGETRATE_WB_21: array[0..200 - 10] of Byte = (
    0, 0, 0, 8, 29, 41,
    49, 56, 62, 66, 70, 74, 77, 80, 83, 86, 88, 91, 93, 95, 97, 99,
    101, 103, 105, 107, 108, 110, 112, 113, 115, 116, 118, 119, 121, 122, 123, 125,
    126, 127, 129, 130, 131, 132, 134, 135, 136, 137, 138, 140, 141, 142, 143, 144,
    145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 156, 157, 158, 159, 159, 160,
    161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 171, 172, 173, 174, 175,
    176, 177, 177, 178, 179, 180, 181, 181, 182, 183, 184, 185, 185, 186, 187, 188,
    189, 189, 190, 191, 192, 192, 193, 194, 195, 195, 196, 197, 198, 198, 199, 200,
    200, 201, 202, 203, 203, 204, 205, 206, 206, 207, 208, 209, 209, 210, 211, 211,
    212, 213, 214, 214, 215, 216, 216, 217, 218, 219, 219, 220, 221, 221, 222, 223,
    224, 224, 225, 226, 226, 227, 228, 229, 229, 230, 231, 232, 232, 233, 234, 234,
    235, 236, 237, 237, 238, 239, 240, 240, 241, 242, 243, 243, 244, 245, 246, 246,
    247, 248, 249, 249, 250, 251, 252, 253, 255);

// ---------------------------------------------------------------------------
// Init / control
// ---------------------------------------------------------------------------

function SilkInitEncoderState(var E: TSilkEncoderStateFLP): Integer;
begin
  FillChar(E, SizeOf(E), 0);
  E.sCmn.variable_HP_smth1_Q15 := (SilkLin2Log(3932160) - (16 shl 7)) shl 8;
  E.sCmn.variable_HP_smth2_Q15 := E.sCmn.variable_HP_smth1_Q15;
  E.sCmn.first_frame_after_reset := 1;
  Result := SilkVADInit(E.sCmn.sVAD);
end;

function SilkControlSNR(var E: TSilkEncoderState; TargetRateBps: Integer): Integer;
var
  Id, Bound: Integer;
  Tab: PByte;
begin
  E.TargetRate_bps := TargetRateBps;
  if E.nb_subfr = 2 then
    TargetRateBps := TargetRateBps - (2000 + E.fs_kHz div 16);
  if E.fs_kHz = 8 then
  begin
    Bound := Length(SILK_TARGETRATE_NB_21);
    Tab := @SILK_TARGETRATE_NB_21[0];
  end
  else if E.fs_kHz = 12 then
  begin
    Bound := Length(SILK_TARGETRATE_MB_21);
    Tab := @SILK_TARGETRATE_MB_21[0];
  end
  else
  begin
    Bound := Length(SILK_TARGETRATE_WB_21);
    Tab := @SILK_TARGETRATE_WB_21[0];
  end;
  Id := (TargetRateBps + 200) div 400;
  Id := Id - 10;
  if Id > Bound - 1 then Id := Bound - 1;
  if Id <= 0 then
    E.SNR_dB_Q7 := 0
  else
    E.SNR_dB_Q7 := Tab[Id] * 21;
  Result := SILK_NO_ERROR;
end;

function SilkControlAudioBandwidth(var E: TSilkEncoderState; var Ctl: TSilkEncControl): Integer;
var
  FsKHz, OrigKHz, FsHz: Integer;
begin
  OrigKHz := E.fs_kHz;
  if OrigKHz = 0 then OrigKHz := E.sLP.saved_fs_kHz;
  FsKHz := OrigKHz;
  FsHz := FsKHz * 1000;
  if FsHz = 0 then
  begin
    if E.desiredInternal_fs_Hz < E.API_fs_Hz then FsHz := E.desiredInternal_fs_Hz else FsHz := E.API_fs_Hz;
    FsKHz := FsHz div 1000;
  end
  else if (FsHz > E.API_fs_Hz) or (FsHz > E.maxInternal_fs_Hz) or (FsHz < E.minInternal_fs_Hz) then
  begin
    FsHz := E.API_fs_Hz;
    if FsHz > E.maxInternal_fs_Hz then FsHz := E.maxInternal_fs_Hz;
    if FsHz < E.minInternal_fs_Hz then FsHz := E.minInternal_fs_Hz;
    FsKHz := FsHz div 1000;
  end
  else
  begin
    if E.sLP.transition_frame_no >= TRANSITION_FRAMES then
      E.sLP.mode := 0;
    if (E.allow_bandwidth_switch <> 0) or (Ctl.OpusCanSwitch <> 0) then
    begin
      if OrigKHz * 1000 > E.desiredInternal_fs_Hz then
      begin
        if E.sLP.mode = 0 then
        begin
          E.sLP.transition_frame_no := TRANSITION_FRAMES;
          FillChar(E.sLP.In_LP_State, SizeOf(E.sLP.In_LP_State), 0);
        end;
        if Ctl.OpusCanSwitch <> 0 then
        begin
          E.sLP.mode := 0;
          if OrigKHz = 16 then FsKHz := 12 else FsKHz := 8;
        end
        else
        begin
          if E.sLP.transition_frame_no <= 0 then
          begin
            Ctl.SwitchReady := 1;
            Ctl.MaxBits := Ctl.MaxBits - Ctl.MaxBits * 5 div (Ctl.PayloadSizeMs + 5);
          end
          else
            E.sLP.mode := -2;
        end;
      end
      else if OrigKHz * 1000 < E.desiredInternal_fs_Hz then
      begin
        if Ctl.OpusCanSwitch <> 0 then
        begin
          if OrigKHz = 8 then FsKHz := 12 else FsKHz := 16;
          E.sLP.transition_frame_no := 0;
          FillChar(E.sLP.In_LP_State, SizeOf(E.sLP.In_LP_State), 0);
          E.sLP.mode := 1;
        end
        else
        begin
          if E.sLP.mode = 0 then
          begin
            Ctl.SwitchReady := 1;
            Ctl.MaxBits := Ctl.MaxBits - Ctl.MaxBits * 5 div (Ctl.PayloadSizeMs + 5);
          end
          else
            E.sLP.mode := 1;
        end;
      end
      else
      begin
        if E.sLP.mode < 0 then
          E.sLP.mode := 1;
      end;
    end;
  end;
  Result := FsKHz;
end;

function CheckControlInput(const Ctl: TSilkEncControl): Integer;
  function IsInternal(R: Integer): Boolean;
  begin
    Result := (R = 8000) or (R = 12000) or (R = 16000);
  end;
begin
  if not ((Ctl.APISampleRate = 8000) or (Ctl.APISampleRate = 12000) or (Ctl.APISampleRate = 16000) or
          (Ctl.APISampleRate = 24000) or (Ctl.APISampleRate = 32000) or (Ctl.APISampleRate = 44100) or
          (Ctl.APISampleRate = 48000)) or
     not IsInternal(Ctl.DesiredInternalSampleRate) or not IsInternal(Ctl.MaxInternalSampleRate) or
     not IsInternal(Ctl.MinInternalSampleRate) or
     (Ctl.MinInternalSampleRate > Ctl.DesiredInternalSampleRate) or
     (Ctl.MaxInternalSampleRate < Ctl.DesiredInternalSampleRate) or
     (Ctl.MinInternalSampleRate > Ctl.MaxInternalSampleRate) then
    Exit(SILK_ENC_FS_NOT_SUPPORTED);
  if (Ctl.PayloadSizeMs <> 10) and (Ctl.PayloadSizeMs <> 20) and (Ctl.PayloadSizeMs <> 40) and (Ctl.PayloadSizeMs <> 60) then
    Exit(SILK_ENC_PACKET_SIZE_NOT_SUPPORTED);
  if (Ctl.PacketLossPercentage < 0) or (Ctl.PacketLossPercentage > 100) then
    Exit(SILK_ENC_INVALID_LOSS_RATE);
  if (Ctl.UseDTX < 0) or (Ctl.UseDTX > 1) then
    Exit(SILK_ENC_INVALID_DTX_SETTING);
  if (Ctl.UseCBR < 0) or (Ctl.UseCBR > 1) then
    Exit(SILK_ENC_INVALID_CBR_SETTING);
  if (Ctl.UseInBandFEC < 0) or (Ctl.UseInBandFEC > 1) then
    Exit(SILK_ENC_INVALID_INBAND_FEC_SETTING);
  if (Ctl.NChannelsAPI < 1) or (Ctl.NChannelsAPI > ENCODER_NUM_CHANNELS) then
    Exit(SILK_ENC_INVALID_NUMBER_OF_CHANNELS_ERROR);
  if (Ctl.NChannelsInternal < 1) or (Ctl.NChannelsInternal > ENCODER_NUM_CHANNELS) then
    Exit(SILK_ENC_INVALID_NUMBER_OF_CHANNELS_ERROR);
  if Ctl.NChannelsInternal > Ctl.NChannelsAPI then
    Exit(SILK_ENC_INVALID_NUMBER_OF_CHANNELS_ERROR);
  if (Ctl.Complexity < 0) or (Ctl.Complexity > 10) then
    Exit(SILK_ENC_INVALID_COMPLEXITY_SETTING);
  Result := SILK_NO_ERROR;
end;

function SetupResamplers(var Enc: TSilkEncoderStateFLP; FsKHz: Integer): Integer;
var
  BufLengthMs, OldBufSamples, NewBufSamples, ApiBufSamples: Integer;
  XBufFIX: array[0..2 * MAX_FRAME_LENGTH + LA_SHAPE_MAX - 1] of SmallInt;
  XBufAPI: array[0..(2 * MAX_FRAME_LENGTH_MS + LA_SHAPE_MS) * MAX_API_FS_KHZ - 1] of SmallInt;
  TempState: TSilkResamplerState;
  C: ^TSilkEncoderState;
begin
  Result := SILK_NO_ERROR;
  C := @Enc.sCmn;
  if (C.fs_kHz <> FsKHz) or (C.prev_API_fs_Hz <> C.API_fs_Hz) then
  begin
    if C.fs_kHz = 0 then
      Result := Result + SilkResamplerInit(C.resampler_state, C.API_fs_Hz, FsKHz * 1000, True)
    else
    begin
      BufLengthMs := ((C.nb_subfr * 5) shl 1) + LA_SHAPE_MS;
      OldBufSamples := BufLengthMs * C.fs_kHz;
      NewBufSamples := BufLengthMs * FsKHz;
      SilkFloat2ShortArray(@XBufFIX[0], @Enc.x_buf[0], OldBufSamples);
      Result := Result + SilkResamplerInit(TempState, C.fs_kHz * 1000, C.API_fs_Hz, False);
      ApiBufSamples := BufLengthMs * (C.API_fs_Hz div 1000);
      Result := Result + SilkResampler(TempState, @XBufAPI[0], @XBufFIX[0], OldBufSamples);
      Result := Result + SilkResamplerInit(C.resampler_state, C.API_fs_Hz, FsKHz * 1000, True);
      Result := Result + SilkResampler(C.resampler_state, @XBufFIX[0], @XBufAPI[0], ApiBufSamples);
      SilkShort2FloatArray(@Enc.x_buf[0], @XBufFIX[0], NewBufSamples);
    end;
  end;
  C.prev_API_fs_Hz := C.API_fs_Hz;
end;

function SetupFs(var Enc: TSilkEncoderStateFLP; FsKHz, PacketSizeMs: Integer): Integer;
var
  C: ^TSilkEncoderState;
begin
  Result := SILK_NO_ERROR;
  C := @Enc.sCmn;
  if PacketSizeMs <> C.PacketSize_ms then
  begin
    if (PacketSizeMs <> 10) and (PacketSizeMs <> 20) and (PacketSizeMs <> 40) and (PacketSizeMs <> 60) then
      Result := SILK_ENC_PACKET_SIZE_NOT_SUPPORTED;
    if PacketSizeMs <= 10 then
    begin
      C.nFramesPerPacket := 1;
      if PacketSizeMs = 10 then C.nb_subfr := 2 else C.nb_subfr := 1;
      C.frame_length := PacketSizeMs * FsKHz;
      C.pitch_LPC_win_length := FIND_PITCH_LPC_WIN_MS_2_SF * FsKHz;
      if C.fs_kHz = 8 then
        C.pitch_contour_iCDF := @SE_PITCH_CONTOUR_10_MS_NB_ICDF[0]
      else
        C.pitch_contour_iCDF := @SE_PITCH_CONTOUR_10_MS_ICDF[0];
    end
    else
    begin
      C.nFramesPerPacket := PacketSizeMs div MAX_FRAME_LENGTH_MS;
      C.nb_subfr := MAX_NB_SUBFR;
      C.frame_length := 20 * FsKHz;
      C.pitch_LPC_win_length := FIND_PITCH_LPC_WIN_MS * FsKHz;
      if C.fs_kHz = 8 then
        C.pitch_contour_iCDF := @SE_PITCH_CONTOUR_NB_ICDF[0]
      else
        C.pitch_contour_iCDF := @SE_PITCH_CONTOUR_ICDF[0];
    end;
    C.PacketSize_ms := PacketSizeMs;
    C.TargetRate_bps := 0;
  end;
  if C.fs_kHz <> FsKHz then
  begin
    FillChar(Enc.sShape, SizeOf(Enc.sShape), 0);
    FillChar(C.sNSQ, SizeOf(C.sNSQ), 0);
    FillChar(C.prev_NLSFq_Q15, SizeOf(C.prev_NLSFq_Q15), 0);
    FillChar(C.sLP.In_LP_State, SizeOf(C.sLP.In_LP_State), 0);
    C.inputBufIx := 0;
    C.nFramesEncoded := 0;
    C.TargetRate_bps := 0;
    C.prevLag := 100;
    C.first_frame_after_reset := 1;
    Enc.sShape.LastGainIndex := 10;
    C.sNSQ.lagPrev := 100;
    C.sNSQ.prev_gain_Q16 := 65536;
    C.prevSignalType := TYPE_NO_VOICE_ACTIVITY;
    C.fs_kHz := FsKHz;
    if C.fs_kHz = 8 then
    begin
      if C.nb_subfr = MAX_NB_SUBFR then
        C.pitch_contour_iCDF := @SE_PITCH_CONTOUR_NB_ICDF[0]
      else
        C.pitch_contour_iCDF := @SE_PITCH_CONTOUR_10_MS_NB_ICDF[0];
    end
    else
    begin
      if C.nb_subfr = MAX_NB_SUBFR then
        C.pitch_contour_iCDF := @SE_PITCH_CONTOUR_ICDF[0]
      else
        C.pitch_contour_iCDF := @SE_PITCH_CONTOUR_10_MS_ICDF[0];
    end;
    if (C.fs_kHz = 8) or (C.fs_kHz = 12) then
    begin
      C.predictLPCOrder := MIN_LPC_ORDER;
      C.psNLSF_CB := @SILK_NLSF_CB_NB_MB;
    end
    else
    begin
      C.predictLPCOrder := MAX_LPC_ORDER;
      C.psNLSF_CB := @SILK_NLSF_CB_WB;
    end;
    C.subfr_length := SUB_FRAME_LENGTH_MS * FsKHz;
    C.frame_length := C.subfr_length * C.nb_subfr;
    C.ltp_mem_length := LTP_MEM_LENGTH_MS * FsKHz;
    C.la_pitch := LA_PITCH_MS * FsKHz;
    C.max_pitch_lag := 18 * FsKHz;
    if C.nb_subfr = MAX_NB_SUBFR then
      C.pitch_LPC_win_length := FIND_PITCH_LPC_WIN_MS * FsKHz
    else
      C.pitch_LPC_win_length := FIND_PITCH_LPC_WIN_MS_2_SF * FsKHz;
    if C.fs_kHz = 16 then
      C.pitch_lag_low_bits_iCDF := @SE_UNIFORM8_ICDF[0]
    else if C.fs_kHz = 12 then
      C.pitch_lag_low_bits_iCDF := @SE_UNIFORM6_ICDF[0]
    else
      C.pitch_lag_low_bits_iCDF := @SE_UNIFORM4_ICDF[0];
  end;
end;

function SetupComplexity(var C: TSilkEncoderState; Complexity: Integer): Integer;
const
  WARPING_MULTIPLIER_Q16 = 983;
begin
  if Complexity < 1 then
  begin
    C.pitchEstimationComplexity := SILK_PE_MIN_COMPLEX;
    C.pitchEstimationThreshold_Q16 := 52429;
    C.pitchEstimationLPCOrder := 6;
    C.shapingLPCOrder := 12;
    C.la_shape := 3 * C.fs_kHz;
    C.nStatesDelayedDecision := 1;
    C.useInterpolatedNLSFs := 0;
    C.NLSF_MSVQ_Survivors := 2;
    C.warping_Q16 := 0;
  end
  else if Complexity < 2 then
  begin
    C.pitchEstimationComplexity := SILK_PE_MID_COMPLEX;
    C.pitchEstimationThreshold_Q16 := 49807;
    C.pitchEstimationLPCOrder := 8;
    C.shapingLPCOrder := 14;
    C.la_shape := 5 * C.fs_kHz;
    C.nStatesDelayedDecision := 1;
    C.useInterpolatedNLSFs := 0;
    C.NLSF_MSVQ_Survivors := 3;
    C.warping_Q16 := 0;
  end
  else if Complexity < 3 then
  begin
    C.pitchEstimationComplexity := SILK_PE_MIN_COMPLEX;
    C.pitchEstimationThreshold_Q16 := 52429;
    C.pitchEstimationLPCOrder := 6;
    C.shapingLPCOrder := 12;
    C.la_shape := 3 * C.fs_kHz;
    C.nStatesDelayedDecision := 2;
    C.useInterpolatedNLSFs := 0;
    C.NLSF_MSVQ_Survivors := 2;
    C.warping_Q16 := 0;
  end
  else if Complexity < 4 then
  begin
    C.pitchEstimationComplexity := SILK_PE_MID_COMPLEX;
    C.pitchEstimationThreshold_Q16 := 49807;
    C.pitchEstimationLPCOrder := 8;
    C.shapingLPCOrder := 14;
    C.la_shape := 5 * C.fs_kHz;
    C.nStatesDelayedDecision := 2;
    C.useInterpolatedNLSFs := 0;
    C.NLSF_MSVQ_Survivors := 4;
    C.warping_Q16 := 0;
  end
  else if Complexity < 6 then
  begin
    C.pitchEstimationComplexity := SILK_PE_MID_COMPLEX;
    C.pitchEstimationThreshold_Q16 := 48497;
    C.pitchEstimationLPCOrder := 10;
    C.shapingLPCOrder := 16;
    C.la_shape := 5 * C.fs_kHz;
    C.nStatesDelayedDecision := 2;
    C.useInterpolatedNLSFs := 1;
    C.NLSF_MSVQ_Survivors := 6;
    C.warping_Q16 := C.fs_kHz * WARPING_MULTIPLIER_Q16;
  end
  else if Complexity < 8 then
  begin
    C.pitchEstimationComplexity := SILK_PE_MID_COMPLEX;
    C.pitchEstimationThreshold_Q16 := 47186;
    C.pitchEstimationLPCOrder := 12;
    C.shapingLPCOrder := 20;
    C.la_shape := 5 * C.fs_kHz;
    C.nStatesDelayedDecision := 3;
    C.useInterpolatedNLSFs := 1;
    C.NLSF_MSVQ_Survivors := 8;
    C.warping_Q16 := C.fs_kHz * WARPING_MULTIPLIER_Q16;
  end
  else
  begin
    C.pitchEstimationComplexity := SILK_PE_MAX_COMPLEX;
    C.pitchEstimationThreshold_Q16 := 45875;
    C.pitchEstimationLPCOrder := 16;
    C.shapingLPCOrder := 24;
    C.la_shape := 5 * C.fs_kHz;
    C.nStatesDelayedDecision := MAX_DEL_DEC_STATES;
    C.useInterpolatedNLSFs := 1;
    C.NLSF_MSVQ_Survivors := 16;
    C.warping_Q16 := C.fs_kHz * WARPING_MULTIPLIER_Q16;
  end;
  if C.pitchEstimationLPCOrder > C.predictLPCOrder then
    C.pitchEstimationLPCOrder := C.predictLPCOrder;
  C.shapeWinLength := SUB_FRAME_LENGTH_MS * C.fs_kHz + 2 * C.la_shape;
  C.Complexity := Complexity;
  Result := 0;
end;

function SetupLBRR(var C: TSilkEncoderState; const Ctl: TSilkEncControl): Integer;
var
  LBRRInPreviousPacket, T: Integer;
begin
  LBRRInPreviousPacket := C.LBRR_enabled;
  C.LBRR_enabled := Ctl.LBRRCoded;
  if C.LBRR_enabled <> 0 then
  begin
    if LBRRInPreviousPacket = 0 then
      C.LBRR_GainIncreases := 7
    else
    begin
      T := 7 - SilkSMULWB(C.PacketLoss_perc, 13107);
      if T < 3 then T := 3;
      C.LBRR_GainIncreases := T;
    end;
  end;
  Result := SILK_NO_ERROR;
end;

function SilkControlEncoder(var Enc: TSilkEncoderStateFLP; var Ctl: TSilkEncControl; AllowBwSwitch, ChannelNb,
  ForceFsKHz: Integer): Integer;
var
  FsKHz: Integer;
  C: ^TSilkEncoderState;
begin
  Result := 0;
  C := @Enc.sCmn;
  C.useDTX := Ctl.UseDTX;
  C.useCBR := Ctl.UseCBR;
  C.API_fs_Hz := Ctl.APISampleRate;
  C.maxInternal_fs_Hz := Ctl.MaxInternalSampleRate;
  C.minInternal_fs_Hz := Ctl.MinInternalSampleRate;
  C.desiredInternal_fs_Hz := Ctl.DesiredInternalSampleRate;
  C.useInBandFEC := Ctl.UseInBandFEC;
  C.nChannelsAPI := Ctl.NChannelsAPI;
  C.nChannelsInternal := Ctl.NChannelsInternal;
  C.allow_bandwidth_switch := AllowBwSwitch;
  C.channelNb := ChannelNb;
  if (C.controlled_since_last_payload <> 0) and (C.prefillFlag = 0) then
  begin
    if (C.API_fs_Hz <> C.prev_API_fs_Hz) and (C.fs_kHz > 0) then
      Result := Result + SetupResamplers(Enc, C.fs_kHz);
    Exit;
  end;
  FsKHz := SilkControlAudioBandwidth(C^, Ctl);
  if ForceFsKHz <> 0 then FsKHz := ForceFsKHz;
  Result := Result + SetupResamplers(Enc, FsKHz);
  Result := Result + SetupFs(Enc, FsKHz, Ctl.PayloadSizeMs);
  Result := Result + SetupComplexity(C^, Ctl.Complexity);
  C.PacketLoss_perc := Ctl.PacketLossPercentage;
  Result := Result + SetupLBRR(C^, Ctl);
  C.controlled_since_last_payload := 1;
end;

procedure SilkHPVariableCutoff(var States: array of TSilkEncoderStateFLP);
var
  QualityQ15, PitchFreqHzQ16, PitchFreqLogQ7, DeltaFreqQ7: Integer;
  C: ^TSilkEncoderState;
begin
  C := @States[0].sCmn;
  if C.prevSignalType = TYPE_VOICED then
  begin
    PitchFreqHzQ16 := ((C.fs_kHz * 1000) shl 16) div C.prevLag;
    PitchFreqLogQ7 := SilkLin2Log(PitchFreqHzQ16) - (16 shl 7);
    QualityQ15 := C.input_quality_bands_Q15[0];
    PitchFreqLogQ7 := SilkSMLAWB(PitchFreqLogQ7, SilkSMULWB((-QualityQ15) shl 2, QualityQ15),
      PitchFreqLogQ7 - (SilkLin2Log(3932160) - (16 shl 7)));
    DeltaFreqQ7 := PitchFreqLogQ7 - Sar32(C.variable_HP_smth1_Q15, 8);
    if DeltaFreqQ7 < 0 then
      DeltaFreqQ7 := DeltaFreqQ7 * 3;
    DeltaFreqQ7 := SilkLimit(DeltaFreqQ7, -51, 51);
    C.variable_HP_smth1_Q15 := SilkSMLAWB(C.variable_HP_smth1_Q15,
      SilkSMULBB(C.speech_activity_Q8, DeltaFreqQ7), 6554);
    C.variable_HP_smth1_Q15 := SilkLimit(C.variable_HP_smth1_Q15,
      SilkLin2Log(VARIABLE_HP_MIN_CUTOFF_HZ) shl 8, SilkLin2Log(VARIABLE_HP_MAX_CUTOFF_HZ) shl 8);
  end;
end;

// ---------------------------------------------------------------------------
// Frame encoding
// ---------------------------------------------------------------------------

procedure SilkEncodeDoVADFLP(var Enc: TSilkEncoderStateFLP; Activity: Integer);
var
  C: ^TSilkEncoderState;
begin
  C := @Enc.sCmn;
  SilkVADGetSAQ8(C^, @C.inputBuf[1]);
  if (Activity = VAD_NO_ACTIVITY) and (C.speech_activity_Q8 >= ACTIVITY_THRESHOLD_Q8) then
    C.speech_activity_Q8 := ACTIVITY_THRESHOLD_Q8 - 1;
  if C.speech_activity_Q8 < ACTIVITY_THRESHOLD_Q8 then
  begin
    C.indices.signalType := TYPE_NO_VOICE_ACTIVITY;
    Inc(C.noSpeechCounter);
    if C.noSpeechCounter <= NB_SPEECH_FRAMES_BEFORE_DTX then
      C.inDTX := 0
    else if C.noSpeechCounter > MAX_CONSECUTIVE_DTX + NB_SPEECH_FRAMES_BEFORE_DTX then
    begin
      C.noSpeechCounter := NB_SPEECH_FRAMES_BEFORE_DTX;
      C.inDTX := 0;
    end;
    C.VAD_flags[C.nFramesEncoded] := 0;
  end
  else
  begin
    C.noSpeechCounter := 0;
    C.inDTX := 0;
    C.indices.signalType := TYPE_UNVOICED;
    C.VAD_flags[C.nFramesEncoded] := 1;
  end;
end;

procedure SilkLBRREncodeFLP(var Enc: TSilkEncoderStateFLP; var Ctrl: TSilkEncoderControlFLP; Xfw: PSingle;
  CondCoding: Integer);
var
  K, Cond: Integer;
  GainsQ16: array[0..MAX_NB_SUBFR - 1] of Integer;
  TempGains: array[0..MAX_NB_SUBFR - 1] of Single;
  IndLBRR: ^TSideInfoIndices;
  NSQLBRR: TSilkNSQState;
  C: ^TSilkEncoderState;
begin
  C := @Enc.sCmn;
  IndLBRR := @C.indices_LBRR[C.nFramesEncoded];
  if (C.LBRR_enabled <> 0) and (C.speech_activity_Q8 > LBRR_SPEECH_ACTIVITY_THRES_Q8) then
  begin
    C.LBRR_flags[C.nFramesEncoded] := 1;
    NSQLBRR := C.sNSQ;
    IndLBRR^ := C.indices;
    Move(Ctrl.Gains[0], TempGains[0], C.nb_subfr * SizeOf(Single));
    if (C.nFramesEncoded = 0) or (C.LBRR_flags[C.nFramesEncoded - 1] = 0) then
    begin
      C.LBRRprevLastGainIndex := Enc.sShape.LastGainIndex;
      K := IndLBRR.GainsIndices[0] + C.LBRR_GainIncreases;
      if K > N_LEVELS_QGAIN - 1 then K := N_LEVELS_QGAIN - 1;
      IndLBRR.GainsIndices[0] := ShortInt(K);
    end;
    if CondCoding = CODE_CONDITIONALLY then Cond := 1 else Cond := 0;
    SilkGainsDequant(@GainsQ16[0], @IndLBRR.GainsIndices[0], C.LBRRprevLastGainIndex, Cond, C.nb_subfr);
    for K := 0 to C.nb_subfr - 1 do
      Ctrl.Gains[K] := GainsQ16[K] * F_INV65536;
    SilkNSQWrapperFLP(Enc, Ctrl, IndLBRR^, NSQLBRR, @C.pulses_LBRR[C.nFramesEncoded, 0], Xfw);
    Move(TempGains[0], Ctrl.Gains[0], C.nb_subfr * SizeOf(Single));
  end;
end;

function SilkEncodeFrameFLP(var Enc: TSilkEncoderStateFLP; var NBytesOut: Integer; var RangeEnc: TEcEnc;
  CondCoding, MaxBits, UseCBR: Integer): Integer;
var
  Ctrl: TSilkEncoderControlFLP;
  I, J, Iter, MaxIter, FoundUpper, FoundLower, Sum: Integer;
  XFrame, ResPitchFrame: PSingle;
  ResPitch: array[0..2 * MAX_FRAME_LENGTH + LA_PITCH_MAX - 1] of Single;
  RangeEncCopy, RangeEncCopy2: TEcEnc;
  NSQCopy, NSQCopy2: TSilkNSQState;
  SeedCopy, NBits, NBitsLower, NBitsUpper, GainMultLower, GainMultUpper: Integer;
  GainsID, GainsIDLower, GainsIDUpper: Integer;
  GainMultQ8, Tmp: SmallInt;
  EcPrevLagIndexCopy: SmallInt;
  EcPrevSignalTypeCopy: Integer;
  LastGainIndexCopy2: ShortInt;
  PGainsQ16: array[0..MAX_NB_SUBFR - 1] of Integer;
  EcBufCopy: array[0..1274] of Byte;
  GainLock: array[0..MAX_NB_SUBFR - 1] of Integer;
  BestGainMult: array[0..MAX_NB_SUBFR - 1] of SmallInt;
  BestSum: array[0..MAX_NB_SUBFR - 1] of Integer;
  BitsMargin, Cond: Integer;
  C: ^TSilkEncoderState;
  F: Single;
begin
  Result := 0;
  C := @Enc.sCmn;
  FillChar(Ctrl, SizeOf(Ctrl), 0);
  FillChar(GainLock, SizeOf(GainLock), 0);
  FillChar(BestGainMult, SizeOf(BestGainMult), 0);
  FillChar(BestSum, SizeOf(BestSum), 0);
  if UseCBR <> 0 then BitsMargin := 5 else BitsMargin := MaxBits div 4;
  LastGainIndexCopy2 := 0;
  NBitsLower := 0;
  NBitsUpper := 0;
  GainMultLower := 0;
  GainMultUpper := 0;
  C.indices.Seed := ShortInt(C.frameCounter and 3);
  Inc(C.frameCounter);
  XFrame := @Enc.x_buf[C.ltp_mem_length];
  ResPitchFrame := @ResPitch[C.ltp_mem_length];
  SilkLPVariableCutoff(C.sLP, @C.inputBuf[1], C.frame_length);
  SilkShort2FloatArray(XFrame + LA_SHAPE_MS * C.fs_kHz, @C.inputBuf[1], C.frame_length);
  for I := 0 to 7 do
  begin
    F := (1 - (I and 2)) * F_1E6;
    XFrame[LA_SHAPE_MS * C.fs_kHz + I * (C.frame_length shr 3)] :=
      XFrame[LA_SHAPE_MS * C.fs_kHz + I * (C.frame_length shr 3)] + F;
  end;
  if C.prefillFlag = 0 then
  begin
    SilkFindPitchLagsFLP(Enc, Ctrl, @ResPitch[0], XFrame);
    SilkNoiseShapeAnalysisFLP(Enc, Ctrl, ResPitchFrame, XFrame);
    SilkFindPredCoefsFLP(Enc, Ctrl, ResPitchFrame, XFrame, CondCoding);
    SilkProcessGainsFLP(Enc, Ctrl, CondCoding);
    SilkLBRREncodeFLP(Enc, Ctrl, XFrame, CondCoding);
    MaxIter := 6;
    GainMultQ8 := 256;
    FoundLower := 0;
    FoundUpper := 0;
    GainsID := SilkGainsID(@C.indices.GainsIndices[0], C.nb_subfr);
    GainsIDLower := -1;
    GainsIDUpper := -1;
    RangeEncCopy := RangeEnc;
    NSQCopy := C.sNSQ;
    SeedCopy := C.indices.Seed;
    EcPrevLagIndexCopy := C.ec_prevLagIndex;
    EcPrevSignalTypeCopy := C.ec_prevSignalType;
    if CondCoding = CODE_CONDITIONALLY then Cond := 1 else Cond := 0;
    Iter := 0;
    while True do
    begin
      if GainsID = GainsIDLower then
        NBits := NBitsLower
      else if GainsID = GainsIDUpper then
        NBits := NBitsUpper
      else
      begin
        if Iter > 0 then
        begin
          RangeEnc := RangeEncCopy;
          C.sNSQ := NSQCopy;
          C.indices.Seed := ShortInt(SeedCopy);
          C.ec_prevLagIndex := EcPrevLagIndexCopy;
          C.ec_prevSignalType := EcPrevSignalTypeCopy;
        end;
        SilkNSQWrapperFLP(Enc, Ctrl, C.indices, C.sNSQ, @C.pulses[0], XFrame);
        if (Iter = MaxIter) and (FoundLower = 0) then
          RangeEncCopy2 := RangeEnc;
        SilkEncodeIndices(C^, RangeEnc, C.nFramesEncoded, False, CondCoding);
        SilkEncodePulses(RangeEnc, C.indices.signalType, C.indices.quantOffsetType, @C.pulses[0], C.frame_length);
        NBits := EcTell(RangeEnc);
        if (Iter = MaxIter) and (FoundLower = 0) and (NBits > MaxBits) then
        begin
          RangeEnc := RangeEncCopy2;
          Enc.sShape.LastGainIndex := Ctrl.lastGainIndexPrev;
          for I := 0 to C.nb_subfr - 1 do
            C.indices.GainsIndices[I] := 4;
          if CondCoding <> CODE_CONDITIONALLY then
            C.indices.GainsIndices[0] := Ctrl.lastGainIndexPrev;
          C.ec_prevLagIndex := EcPrevLagIndexCopy;
          C.ec_prevSignalType := EcPrevSignalTypeCopy;
          for I := 0 to C.frame_length - 1 do
            C.pulses[I] := 0;
          SilkEncodeIndices(C^, RangeEnc, C.nFramesEncoded, False, CondCoding);
          SilkEncodePulses(RangeEnc, C.indices.signalType, C.indices.quantOffsetType, @C.pulses[0], C.frame_length);
          NBits := EcTell(RangeEnc);
        end;
        if (UseCBR = 0) and (Iter = 0) and (NBits <= MaxBits) then
          Break;
      end;
      if Iter = MaxIter then
      begin
        if (FoundLower <> 0) and ((GainsID = GainsIDLower) or (NBits > MaxBits)) then
        begin
          RangeEnc := RangeEncCopy2;
          Move(EcBufCopy[0], RangeEnc.Buf^, RangeEncCopy2.Offs);
          C.sNSQ := NSQCopy2;
          Enc.sShape.LastGainIndex := LastGainIndexCopy2;
        end;
        Break;
      end;
      if NBits > MaxBits then
      begin
        if (FoundLower = 0) and (Iter >= 2) then
        begin
          F := Ctrl.Lambda * F_15;
          if F > F_15 then Ctrl.Lambda := F else Ctrl.Lambda := F_15;
          C.indices.quantOffsetType := 0;
          FoundUpper := 0;
          GainsIDUpper := -1;
        end
        else
        begin
          FoundUpper := 1;
          NBitsUpper := NBits;
          GainMultUpper := GainMultQ8;
          GainsIDUpper := GainsID;
        end;
      end
      else if NBits < MaxBits - BitsMargin then
      begin
        FoundLower := 1;
        NBitsLower := NBits;
        GainMultLower := GainMultQ8;
        if GainsID <> GainsIDLower then
        begin
          GainsIDLower := GainsID;
          RangeEncCopy2 := RangeEnc;
          Move(RangeEnc.Buf^, EcBufCopy[0], RangeEnc.Offs);
          NSQCopy2 := C.sNSQ;
          LastGainIndexCopy2 := Enc.sShape.LastGainIndex;
        end;
      end
      else
        Break;
      if (FoundLower = 0) and (NBits > MaxBits) then
      begin
        for I := 0 to C.nb_subfr - 1 do
        begin
          Sum := 0;
          for J := I * C.subfr_length to (I + 1) * C.subfr_length - 1 do
            Sum := Sum + Abs(Integer(C.pulses[J]));
          if (Iter = 0) or ((Sum < BestSum[I]) and (GainLock[I] = 0)) then
          begin
            BestSum[I] := Sum;
            BestGainMult[I] := GainMultQ8;
          end
          else
            GainLock[I] := 1;
        end;
      end;
      if (FoundLower and FoundUpper) = 0 then
      begin
        if NBits > MaxBits then
        begin
          J := GainMultQ8 * 3 div 2;
          if J > 1024 then J := 1024;
          GainMultQ8 := SmallInt(J);
        end
        else
        begin
          J := GainMultQ8 * 4 div 5;
          if J < 64 then J := 64;
          GainMultQ8 := SmallInt(J);
        end;
      end
      else
      begin
        GainMultQ8 := SmallInt(GainMultLower + ((GainMultUpper - GainMultLower) * (MaxBits - NBitsLower)) div
          (NBitsUpper - NBitsLower));
        if GainMultQ8 > GainMultLower + Sar32(GainMultUpper - GainMultLower, 2) then
          GainMultQ8 := SmallInt(GainMultLower + Sar32(GainMultUpper - GainMultLower, 2))
        else if GainMultQ8 < GainMultUpper - Sar32(GainMultUpper - GainMultLower, 2) then
          GainMultQ8 := SmallInt(GainMultUpper - Sar32(GainMultUpper - GainMultLower, 2));
      end;
      for I := 0 to C.nb_subfr - 1 do
      begin
        if GainLock[I] <> 0 then Tmp := BestGainMult[I] else Tmp := GainMultQ8;
        PGainsQ16[I] := SilkLShiftSat32(SilkSMULWB(Ctrl.GainsUnq_Q16[I], Tmp), 8);
      end;
      Enc.sShape.LastGainIndex := Ctrl.lastGainIndexPrev;
      SilkGainsQuant(@C.indices.GainsIndices[0], @PGainsQ16[0], Enc.sShape.LastGainIndex, Cond, C.nb_subfr);
      GainsID := SilkGainsID(@C.indices.GainsIndices[0], C.nb_subfr);
      for I := 0 to C.nb_subfr - 1 do
        Ctrl.Gains[I] := PGainsQ16[I] / F_65536;
      Inc(Iter);
    end;
  end;
  Move(Enc.x_buf[C.frame_length], Enc.x_buf[0], (C.ltp_mem_length + LA_SHAPE_MS * C.fs_kHz) * SizeOf(Single));
  if C.prefillFlag <> 0 then
  begin
    NBytesOut := 0;
    Exit;
  end;
  C.prevLag := Ctrl.pitchL[C.nb_subfr - 1];
  C.prevSignalType := C.indices.signalType;
  C.first_frame_after_reset := 0;
  NBytesOut := Sar32(EcTell(RangeEnc) + 7, 3);
end;

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

function SilkQueryEncoder(const Enc: TSilkEncoder; var Status: TSilkEncControl): Integer;
begin
  Status.NChannelsAPI := Enc.nChannelsAPI;
  Status.NChannelsInternal := Enc.nChannelsInternal;
  with Enc.state_Fxx[0].sCmn do
  begin
    Status.APISampleRate := API_fs_Hz;
    Status.MaxInternalSampleRate := maxInternal_fs_Hz;
    Status.MinInternalSampleRate := minInternal_fs_Hz;
    Status.DesiredInternalSampleRate := desiredInternal_fs_Hz;
    Status.PayloadSizeMs := PacketSize_ms;
    Status.BitRate := TargetRate_bps;
    Status.PacketLossPercentage := PacketLoss_perc;
    Status.Complexity := Complexity;
    Status.UseInBandFEC := useInBandFEC;
    Status.UseDTX := useDTX;
    Status.UseCBR := useCBR;
    Status.InternalSampleRate := fs_kHz * 1000;
    Status.AllowBandwidthSwitch := allow_bandwidth_switch;
    if (fs_kHz = 16) and (sLP.mode = 0) then
      Status.InWBmodeWithoutVariableLP := 1
    else
      Status.InWBmodeWithoutVariableLP := 0;
  end;
  Result := SILK_NO_ERROR;
end;

function SilkInitEncoder(var Enc: TSilkEncoder; var Status: TSilkEncControl): Integer;
var
  N: Integer;
begin
  FillChar(Enc, SizeOf(Enc), 0);
  Result := 0;
  for N := 0 to ENCODER_NUM_CHANNELS - 1 do
    Result := Result + SilkInitEncoderState(Enc.state_Fxx[N]);
  Enc.nChannelsAPI := 1;
  Enc.nChannelsInternal := 1;
  Result := Result + SilkQueryEncoder(Enc, Status);
end;

function SilkEncode(var Enc: TSilkEncoder; var Ctl: TSilkEncControl; SamplesIn: PSmallInt; NSamplesIn: Integer;
  var RangeEnc: TEcEnc; var NBytesOut: Integer; PrefillFlag, Activity: Integer): Integer;
var
  N, I, NBits, Flags, TmpPayloadSizeMs, TmpComplexity, Ret: Integer;
  NSamplesToBuffer, NSamplesToBufferMax, NBlocksOf10ms: Integer;
  NSamplesFromInput, SpeechActThrForSwitchQ8: Integer;
  TargetRateBps, ChannelRateBps, LBRRSymbol, Sum: Integer;
  MStargetRatesBps: array[0..1] of Integer;
  Buf: array of SmallInt;
  Transition, CurrBlock, TotBlocks, CurrNBitsUsedLBRR, Id, ForceFsKHz: Integer;
  SaveLP: TSilkLPState;
  ICDF: array[0..1] of Byte;
  MaxBits, UseCBR, CondCoding, BitsBalance, FIdx: Integer;
  S0, S1: ^TSilkEncoderState;
begin
  TmpPayloadSizeMs := 0;
  TmpComplexity := 0;
  S0 := @Enc.state_Fxx[0].sCmn;
  S1 := @Enc.state_Fxx[1].sCmn;
  if Ctl.ReducedDependency <> 0 then
  begin
    S0.first_frame_after_reset := 1;
    S1.first_frame_after_reset := 1;
  end;
  S0.nFramesEncoded := 0;
  S1.nFramesEncoded := 0;
  Ret := CheckControlInput(Ctl);
  if Ret <> 0 then Exit(Ret);
  Ctl.SwitchReady := 0;
  if Ctl.NChannelsInternal > Enc.nChannelsInternal then
  begin
    Ret := Ret + SilkInitEncoderState(Enc.state_Fxx[1]);
    FillChar(Enc.sStereo.pred_prev_Q13, SizeOf(Enc.sStereo.pred_prev_Q13), 0);
    FillChar(Enc.sStereo.sSide, SizeOf(Enc.sStereo.sSide), 0);
    Enc.sStereo.mid_side_amp_Q0[0] := 0;
    Enc.sStereo.mid_side_amp_Q0[1] := 1;
    Enc.sStereo.mid_side_amp_Q0[2] := 0;
    Enc.sStereo.mid_side_amp_Q0[3] := 1;
    Enc.sStereo.width_prev_Q14 := 0;
    Enc.sStereo.smth_width_Q14 := 1 shl 14;
    if Enc.nChannelsAPI = 2 then
    begin
      S1.resampler_state := S0.resampler_state;
      S1.In_HP_State := S0.In_HP_State;
    end;
  end;
  if (Ctl.PayloadSizeMs <> S0.PacketSize_ms) or (Enc.nChannelsInternal <> Ctl.NChannelsInternal) then
    Transition := 1
  else
    Transition := 0;
  Enc.nChannelsAPI := Ctl.NChannelsAPI;
  Enc.nChannelsInternal := Ctl.NChannelsInternal;
  NBlocksOf10ms := (100 * NSamplesIn) div Ctl.APISampleRate;
  if NBlocksOf10ms > 1 then TotBlocks := NBlocksOf10ms shr 1 else TotBlocks := 1;
  CurrBlock := 0;
  if PrefillFlag <> 0 then
  begin
    if NBlocksOf10ms <> 1 then Exit(SILK_ENC_INPUT_INVALID_NO_OF_SAMPLES);
    if PrefillFlag = 2 then
    begin
      SaveLP := S0.sLP;
      SaveLP.saved_fs_kHz := S0.fs_kHz;
    end;
    for N := 0 to Ctl.NChannelsInternal - 1 do
    begin
      Ret := SilkInitEncoderState(Enc.state_Fxx[N]);
      if PrefillFlag = 2 then
        Enc.state_Fxx[N].sCmn.sLP := SaveLP;
    end;
    TmpPayloadSizeMs := Ctl.PayloadSizeMs;
    Ctl.PayloadSizeMs := 10;
    TmpComplexity := Ctl.Complexity;
    Ctl.Complexity := 0;
    for N := 0 to Ctl.NChannelsInternal - 1 do
    begin
      Enc.state_Fxx[N].sCmn.controlled_since_last_payload := 0;
      Enc.state_Fxx[N].sCmn.prefillFlag := 1;
    end;
  end
  else
  begin
    if (NBlocksOf10ms * Ctl.APISampleRate <> 100 * NSamplesIn) or (NSamplesIn < 0) then
      Exit(SILK_ENC_INPUT_INVALID_NO_OF_SAMPLES);
    if 1000 * NSamplesIn > Ctl.PayloadSizeMs * Ctl.APISampleRate then
      Exit(SILK_ENC_INPUT_INVALID_NO_OF_SAMPLES);
  end;
  for N := 0 to Ctl.NChannelsInternal - 1 do
  begin
    if N = 1 then ForceFsKHz := S0.fs_kHz else ForceFsKHz := 0;
    Ret := SilkControlEncoder(Enc.state_Fxx[N], Ctl, Enc.allowBandwidthSwitch, N, ForceFsKHz);
    if Ret <> 0 then Exit(Ret);
    if (Enc.state_Fxx[N].sCmn.first_frame_after_reset <> 0) or (Transition <> 0) then
      for I := 0 to S0.nFramesPerPacket - 1 do
        Enc.state_Fxx[N].sCmn.LBRR_flags[I] := 0;
    Enc.state_Fxx[N].sCmn.inDTX := Enc.state_Fxx[N].sCmn.useDTX;
  end;
  NSamplesToBufferMax := 10 * NBlocksOf10ms * S0.fs_kHz;
  SetLength(Buf, (NSamplesToBufferMax * S0.API_fs_Hz) div (S0.fs_kHz * 1000) + 1);
  while True do
  begin
    CurrNBitsUsedLBRR := 0;
    NSamplesToBuffer := S0.frame_length - S0.inputBufIx;
    if NSamplesToBuffer > NSamplesToBufferMax then NSamplesToBuffer := NSamplesToBufferMax;
    NSamplesFromInput := (NSamplesToBuffer * S0.API_fs_Hz) div (S0.fs_kHz * 1000);
    if (Ctl.NChannelsAPI = 2) and (Ctl.NChannelsInternal = 2) then
    begin
      Id := S0.nFramesEncoded;
      for N := 0 to NSamplesFromInput - 1 do
        Buf[N] := SamplesIn[2 * N];
      if (Enc.nPrevChannelsInternal = 1) and (Id = 0) then
        S1.resampler_state := S0.resampler_state;
      Ret := Ret + SilkResampler(S0.resampler_state, @S0.inputBuf[S0.inputBufIx + 2], @Buf[0], NSamplesFromInput);
      Inc(S0.inputBufIx, NSamplesToBuffer);
      NSamplesToBuffer := S1.frame_length - S1.inputBufIx;
      if NSamplesToBuffer > 10 * NBlocksOf10ms * S1.fs_kHz then NSamplesToBuffer := 10 * NBlocksOf10ms * S1.fs_kHz;
      for N := 0 to NSamplesFromInput - 1 do
        Buf[N] := SamplesIn[2 * N + 1];
      Ret := Ret + SilkResampler(S1.resampler_state, @S1.inputBuf[S1.inputBufIx + 2], @Buf[0], NSamplesFromInput);
      Inc(S1.inputBufIx, NSamplesToBuffer);
    end
    else if (Ctl.NChannelsAPI = 2) and (Ctl.NChannelsInternal = 1) then
    begin
      for N := 0 to NSamplesFromInput - 1 do
      begin
        Sum := SamplesIn[2 * N] + SamplesIn[2 * N + 1];
        Buf[N] := SmallInt(SilkRShiftRound(Sum, 1));
      end;
      Ret := Ret + SilkResampler(S0.resampler_state, @S0.inputBuf[S0.inputBufIx + 2], @Buf[0], NSamplesFromInput);
      if (Enc.nPrevChannelsInternal = 2) and (S0.nFramesEncoded = 0) then
      begin
        Ret := Ret + SilkResampler(S1.resampler_state, @S1.inputBuf[S1.inputBufIx + 2], @Buf[0], NSamplesFromInput);
        for N := 0 to S0.frame_length - 1 do
          S0.inputBuf[S0.inputBufIx + N + 2] := SmallInt(Sar32(S0.inputBuf[S0.inputBufIx + N + 2] +
            S1.inputBuf[S1.inputBufIx + N + 2], 1));
      end;
      Inc(S0.inputBufIx, NSamplesToBuffer);
    end
    else
    begin
      Move(SamplesIn^, Buf[0], NSamplesFromInput * SizeOf(SmallInt));
      Ret := Ret + SilkResampler(S0.resampler_state, @S0.inputBuf[S0.inputBufIx + 2], @Buf[0], NSamplesFromInput);
      Inc(S0.inputBufIx, NSamplesToBuffer);
    end;
    Inc(SamplesIn, NSamplesFromInput * Ctl.NChannelsAPI);
    Dec(NSamplesIn, NSamplesFromInput);
    Enc.allowBandwidthSwitch := 0;
    if S0.inputBufIx >= S0.frame_length then
    begin
      if (S0.nFramesEncoded = 0) and (PrefillFlag = 0) then
      begin
        ICDF[0] := Byte(256 - (256 shr ((S0.nFramesPerPacket + 1) * Ctl.NChannelsInternal)));
        ICDF[1] := 0;
        EcEncIcdf(RangeEnc, 0, @ICDF[0], 8);
        CurrNBitsUsedLBRR := EcTell(RangeEnc);
        for N := 0 to Ctl.NChannelsInternal - 1 do
        begin
          LBRRSymbol := 0;
          for I := 0 to Enc.state_Fxx[N].sCmn.nFramesPerPacket - 1 do
            LBRRSymbol := LBRRSymbol or (Enc.state_Fxx[N].sCmn.LBRR_flags[I] shl I);
          if LBRRSymbol > 0 then Enc.state_Fxx[N].sCmn.LBRR_flag := 1 else Enc.state_Fxx[N].sCmn.LBRR_flag := 0;
          if (LBRRSymbol <> 0) and (Enc.state_Fxx[N].sCmn.nFramesPerPacket > 1) then
          begin
            if Enc.state_Fxx[N].sCmn.nFramesPerPacket = 2 then
              EcEncIcdf(RangeEnc, LBRRSymbol - 1, @SE_LBRR_FLAGS_2_ICDF[0], 8)
            else
              EcEncIcdf(RangeEnc, LBRRSymbol - 1, @SE_LBRR_FLAGS_3_ICDF[0], 8);
          end;
        end;
        for I := 0 to S0.nFramesPerPacket - 1 do
          for N := 0 to Ctl.NChannelsInternal - 1 do
            if Enc.state_Fxx[N].sCmn.LBRR_flags[I] <> 0 then
            begin
              if (Ctl.NChannelsInternal = 2) and (N = 0) then
              begin
                SilkStereoEncodePred(RangeEnc, PStereoIx(@Enc.sStereo.predIx[I])^);
                if S1.LBRR_flags[I] = 0 then
                  SilkStereoEncodeMidOnly(RangeEnc, Enc.sStereo.mid_only_flags[I]);
              end;
              if (I > 0) and (Enc.state_Fxx[N].sCmn.LBRR_flags[I - 1] <> 0) then
                CondCoding := CODE_CONDITIONALLY
              else
                CondCoding := CODE_INDEPENDENTLY;
              SilkEncodeIndices(Enc.state_Fxx[N].sCmn, RangeEnc, I, True, CondCoding);
              SilkEncodePulses(RangeEnc, Enc.state_Fxx[N].sCmn.indices_LBRR[I].signalType,
                Enc.state_Fxx[N].sCmn.indices_LBRR[I].quantOffsetType, @Enc.state_Fxx[N].sCmn.pulses_LBRR[I, 0],
                Enc.state_Fxx[N].sCmn.frame_length);
            end;
        for N := 0 to Ctl.NChannelsInternal - 1 do
          FillChar(Enc.state_Fxx[N].sCmn.LBRR_flags, SizeOf(Enc.state_Fxx[N].sCmn.LBRR_flags), 0);
        CurrNBitsUsedLBRR := EcTell(RangeEnc) - CurrNBitsUsedLBRR;
      end;
      SilkHPVariableCutoff(Enc.state_Fxx);
      NBits := (Ctl.BitRate * Ctl.PayloadSizeMs) div 1000;
      if PrefillFlag = 0 then
      begin
        if CurrNBitsUsedLBRR < 10 then
          Enc.nBitsUsedLBRR := 0
        else if Enc.nBitsUsedLBRR < 10 then
          Enc.nBitsUsedLBRR := CurrNBitsUsedLBRR
        else
          Enc.nBitsUsedLBRR := (Enc.nBitsUsedLBRR + CurrNBitsUsedLBRR) div 2;
        NBits := NBits - Enc.nBitsUsedLBRR;
      end;
      NBits := NBits div S0.nFramesPerPacket;
      if Ctl.PayloadSizeMs = 10 then
        TargetRateBps := SilkSMULBB(NBits, 100)
      else
        TargetRateBps := SilkSMULBB(NBits, 50);
      TargetRateBps := TargetRateBps - (Enc.nBitsExceeded * 1000) div BITRESERVOIR_DECAY_TIME_MS;
      if (PrefillFlag = 0) and (S0.nFramesEncoded > 0) then
      begin
        BitsBalance := EcTell(RangeEnc) - Enc.nBitsUsedLBRR - NBits * S0.nFramesEncoded;
        TargetRateBps := TargetRateBps - (BitsBalance * 1000) div BITRESERVOIR_DECAY_TIME_MS;
      end;
      TargetRateBps := SilkLimit(TargetRateBps, Ctl.BitRate, 5000);
      FIdx := S0.nFramesEncoded;
      if Ctl.NChannelsInternal = 2 then
      begin
        SilkStereoLRtoMS(Enc.sStereo, @S0.inputBuf[2], @S1.inputBuf[2], PStereoIx(@Enc.sStereo.predIx[FIdx])^,
          Enc.sStereo.mid_only_flags[FIdx], @MStargetRatesBps[0], TargetRateBps, S0.speech_activity_Q8,
          Ctl.ToMono, S0.fs_kHz, S0.frame_length);
        if Enc.sStereo.mid_only_flags[FIdx] = 0 then
        begin
          if Enc.prev_decode_only_middle = 1 then
          begin
            FillChar(Enc.state_Fxx[1].sShape, SizeOf(Enc.state_Fxx[1].sShape), 0);
            FillChar(S1.sNSQ, SizeOf(S1.sNSQ), 0);
            FillChar(S1.prev_NLSFq_Q15, SizeOf(S1.prev_NLSFq_Q15), 0);
            FillChar(S1.sLP.In_LP_State, SizeOf(S1.sLP.In_LP_State), 0);
            S1.prevLag := 100;
            S1.sNSQ.lagPrev := 100;
            Enc.state_Fxx[1].sShape.LastGainIndex := 10;
            S1.prevSignalType := TYPE_NO_VOICE_ACTIVITY;
            S1.sNSQ.prev_gain_Q16 := 65536;
            S1.first_frame_after_reset := 1;
          end;
          SilkEncodeDoVADFLP(Enc.state_Fxx[1], Activity);
        end
        else
          S1.VAD_flags[FIdx] := 0;
        if PrefillFlag = 0 then
        begin
          SilkStereoEncodePred(RangeEnc, PStereoIx(@Enc.sStereo.predIx[FIdx])^);
          if S1.VAD_flags[FIdx] = 0 then
            SilkStereoEncodeMidOnly(RangeEnc, Enc.sStereo.mid_only_flags[FIdx]);
        end;
      end
      else
      begin
        Move(Enc.sStereo.sMid[0], S0.inputBuf[0], 2 * SizeOf(SmallInt));
        Move(S0.inputBuf[S0.frame_length], Enc.sStereo.sMid[0], 2 * SizeOf(SmallInt));
      end;
      SilkEncodeDoVADFLP(Enc.state_Fxx[0], Activity);
      for N := 0 to Ctl.NChannelsInternal - 1 do
      begin
        MaxBits := Ctl.MaxBits;
        if (TotBlocks = 2) and (CurrBlock = 0) then
          MaxBits := MaxBits * 3 div 5
        else if TotBlocks = 3 then
        begin
          if CurrBlock = 0 then
            MaxBits := MaxBits * 2 div 5
          else if CurrBlock = 1 then
            MaxBits := MaxBits * 3 div 4;
        end;
        if (Ctl.UseCBR <> 0) and (CurrBlock = TotBlocks - 1) then UseCBR := 1 else UseCBR := 0;
        if Ctl.NChannelsInternal = 1 then
          ChannelRateBps := TargetRateBps
        else
        begin
          ChannelRateBps := MStargetRatesBps[N];
          if (N = 0) and (MStargetRatesBps[1] > 0) then
          begin
            UseCBR := 0;
            MaxBits := MaxBits - Ctl.MaxBits div (TotBlocks * 2);
          end;
        end;
        if ChannelRateBps > 0 then
        begin
          SilkControlSNR(Enc.state_Fxx[N].sCmn, ChannelRateBps);
          if S0.nFramesEncoded - N <= 0 then
            CondCoding := CODE_INDEPENDENTLY
          else if (N > 0) and (Enc.prev_decode_only_middle <> 0) then
            CondCoding := CODE_INDEPENDENTLY_NO_LTP_SCALING
          else
            CondCoding := CODE_CONDITIONALLY;
          Ret := SilkEncodeFrameFLP(Enc.state_Fxx[N], NBytesOut, RangeEnc, CondCoding, MaxBits, UseCBR);
        end;
        Enc.state_Fxx[N].sCmn.controlled_since_last_payload := 0;
        Enc.state_Fxx[N].sCmn.inputBufIx := 0;
        Inc(Enc.state_Fxx[N].sCmn.nFramesEncoded);
      end;
      Enc.prev_decode_only_middle := Enc.sStereo.mid_only_flags[S0.nFramesEncoded - 1];
      if (NBytesOut > 0) and (S0.nFramesEncoded = S0.nFramesPerPacket) then
      begin
        Flags := 0;
        for N := 0 to Ctl.NChannelsInternal - 1 do
        begin
          for I := 0 to Enc.state_Fxx[N].sCmn.nFramesPerPacket - 1 do
          begin
            Flags := Flags shl 1;
            Flags := Flags or Enc.state_Fxx[N].sCmn.VAD_flags[I];
          end;
          Flags := Flags shl 1;
          Flags := Flags or Enc.state_Fxx[N].sCmn.LBRR_flag;
        end;
        if PrefillFlag = 0 then
          EcEncPatchInitialBits(RangeEnc, Flags, (S0.nFramesPerPacket + 1) * Ctl.NChannelsInternal);
        if (S0.inDTX <> 0) and ((Ctl.NChannelsInternal = 1) or (S1.inDTX <> 0)) then
          NBytesOut := 0;
        Enc.nBitsExceeded := Enc.nBitsExceeded + NBytesOut * 8;
        Enc.nBitsExceeded := Enc.nBitsExceeded - (Ctl.BitRate * Ctl.PayloadSizeMs) div 1000;
        Enc.nBitsExceeded := SilkLimit(Enc.nBitsExceeded, 0, 10000);
        SpeechActThrForSwitchQ8 := SilkSMLAWB(ACTIVITY_THRESHOLD_Q8, 3188, Enc.timeSinceSwitchAllowed_ms);
        if S0.speech_activity_Q8 < SpeechActThrForSwitchQ8 then
        begin
          Enc.allowBandwidthSwitch := 1;
          Enc.timeSinceSwitchAllowed_ms := 0;
        end
        else
        begin
          Enc.allowBandwidthSwitch := 0;
          Inc(Enc.timeSinceSwitchAllowed_ms, Ctl.PayloadSizeMs);
        end;
      end;
      if NSamplesIn = 0 then Break;
    end
    else
      Break;
    Inc(CurrBlock);
  end;
  Enc.nPrevChannelsInternal := Ctl.NChannelsInternal;
  Ctl.AllowBandwidthSwitch := Enc.allowBandwidthSwitch;
  if (S0.fs_kHz = 16) and (S0.sLP.mode = 0) then
    Ctl.InWBmodeWithoutVariableLP := 1
  else
    Ctl.InWBmodeWithoutVariableLP := 0;
  Ctl.InternalSampleRate := S0.fs_kHz * 1000;
  if Ctl.ToMono <> 0 then Ctl.StereoWidthQ14 := 0 else Ctl.StereoWidthQ14 := Enc.sStereo.smth_width_Q14;
  if PrefillFlag <> 0 then
  begin
    Ctl.PayloadSizeMs := TmpPayloadSizeMs;
    Ctl.Complexity := TmpComplexity;
    for N := 0 to Ctl.NChannelsInternal - 1 do
    begin
      Enc.state_Fxx[N].sCmn.controlled_since_last_payload := 0;
      Enc.state_Fxx[N].sCmn.prefillFlag := 0;
    end;
  end;
  Ctl.SignalType := S0.indices.signalType;
  Ctl.Offset := SE_QUANTIZATION_OFFSETS_Q10[S0.indices.signalType shr 1, S0.indices.quantOffsetType];
  Result := Ret;
end;

end.
