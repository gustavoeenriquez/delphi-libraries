unit OpusEncTypes;

{
  OpusEncTypes.pas - Constants and shared records of the Opus encoder

  Values of include/opus_defines.h, src/opus_private.h and the AnalysisInfo /
  SILKInfo records of celt/celt.h (libopus 1.5.2).

  Copyright (c) 2010-2011 Xiph.Org Foundation, Skype Limited.
  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

interface

const
  // Error codes
  OPUS_OK               = 0;
  OPUS_BAD_ARG          = -1;
  OPUS_BUFFER_TOO_SMALL = -2;
  OPUS_INTERNAL_ERROR   = -3;
  OPUS_INVALID_PACKET   = -4;
  OPUS_UNIMPLEMENTED    = -5;
  OPUS_INVALID_STATE    = -6;
  OPUS_ALLOC_FAIL       = -7;

  OPUS_AUTO        = -1000;
  OPUS_BITRATE_MAX = -1;

  OPUS_APPLICATION_VOIP                = 2048;
  OPUS_APPLICATION_AUDIO               = 2049;
  OPUS_APPLICATION_RESTRICTED_LOWDELAY = 2051;

  OPUS_SIGNAL_VOICE = 3001;
  OPUS_SIGNAL_MUSIC = 3002;

  OPUS_BANDWIDTH_NARROWBAND    = 1101;
  OPUS_BANDWIDTH_MEDIUMBAND    = 1102;
  OPUS_BANDWIDTH_WIDEBAND      = 1103;
  OPUS_BANDWIDTH_SUPERWIDEBAND = 1104;
  OPUS_BANDWIDTH_FULLBAND      = 1105;

  OPUS_FRAMESIZE_ARG    = 5000;
  OPUS_FRAMESIZE_2_5_MS = 5001;
  OPUS_FRAMESIZE_5_MS   = 5002;
  OPUS_FRAMESIZE_10_MS  = 5003;
  OPUS_FRAMESIZE_20_MS  = 5004;
  OPUS_FRAMESIZE_40_MS  = 5005;
  OPUS_FRAMESIZE_60_MS  = 5006;
  OPUS_FRAMESIZE_80_MS  = 5007;
  OPUS_FRAMESIZE_100_MS = 5008;
  OPUS_FRAMESIZE_120_MS = 5009;

  MODE_SILK_ONLY = 1000;
  MODE_HYBRID    = 1001;
  MODE_CELT_ONLY = 1002;

  LEAK_BANDS = 19;

type
  // Output of the tonality analysis (analysis.c), consumed by CELT
  TAnalysisInfo = record
    Valid              : Boolean;
    Tonality           : Single;
    TonalitySlope      : Single;
    Noisiness          : Single;
    Activity           : Single;
    MusicProb          : Single;
    MusicProbMin       : Single;
    MusicProbMax       : Single;
    Bandwidth          : Integer;
    ActivityProbability: Single;
    MaxPitchRatio      : Single;
    LeakBoost          : array[0..LEAK_BANDS - 1] of Byte;   // Q6
  end;

  TSilkInfo = record
    SignalType: Integer;
    Offset    : Integer;
  end;

  // silk_EncControlStruct (silk/control.h)
  TSilkEncControl = record
    NChannelsAPI             : Integer;
    NChannelsInternal        : Integer;
    APISampleRate            : Integer;
    MaxInternalSampleRate    : Integer;
    MinInternalSampleRate    : Integer;
    DesiredInternalSampleRate: Integer;
    PayloadSizeMs            : Integer;
    BitRate                  : Integer;
    PacketLossPercentage     : Integer;
    Complexity               : Integer;
    UseInBandFEC             : Integer;
    UseDRED                  : Integer;
    LBRRCoded                : Integer;
    UseDTX                   : Integer;
    UseCBR                   : Integer;
    MaxBits                  : Integer;
    ToMono                   : Integer;
    OpusCanSwitch            : Integer;
    ReducedDependency        : Integer;
    InternalSampleRate       : Integer;
    AllowBandwidthSwitch     : Integer;
    InWBmodeWithoutVariableLP: Integer;
    StereoWidthQ14           : Integer;
    SwitchReady              : Integer;
    SignalType               : Integer;
    Offset                   : Integer;
  end;

  TOpusApplication = (oaVoip, oaAudio, oaRestrictedLowDelay);

function OpusApplicationValue(A: TOpusApplication): Integer;

implementation

function OpusApplicationValue(A: TOpusApplication): Integer;
begin
  case A of
    oaVoip : Result := OPUS_APPLICATION_VOIP;
    oaAudio: Result := OPUS_APPLICATION_AUDIO;
  else
    Result := OPUS_APPLICATION_RESTRICTED_LOWDELAY;
  end;
end;

end.
