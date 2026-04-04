unit FLACRiceCoder;

{
  FLACRiceCoder.pas - FLAC Rice residual decoding

  Decodes Rice-coded residuals for FLAC FIXED and LPC subframes.

  Two coding methods:
    FLAC_RESIDUAL_RICE  (method 0): 4-bit Rice parameter per partition
    FLAC_RESIDUAL_RICE2 (method 1): 5-bit Rice parameter per partition

  Escape coding: if Rice parameter = 0b1111 (method 0) or 0b11111 (method 1),
  the next 5 bits give the raw sample size; then samples are stored verbatim
  (unencoded, signed integers of that many bits each).

  Partition structure:
    partition_count = 2 ^ partition_order
    Partition 0 contains (BlockSize >> partition_order) - WarmupCount samples.
    Partitions 1..N-1 contain (BlockSize >> partition_order) samples each.

  Output: Residuals[] is filled in order from partition 0 to N-1.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  AudioTypes,
  AudioBitReader,
  FLACTypes,
  FLACBitReader;

// Decode all residuals for a subframe.
// Br          : bit reader positioned immediately after the warm-up samples
// CodingMethod: FLAC_RESIDUAL_RICE (0) or FLAC_RESIDUAL_RICE2 (1)
// PartitionOrder: 0..15
// WarmupCount : number of warm-up samples already read (predictor order)
// BlockSize   : total samples in the block
// Residuals   : output array, must be pre-allocated to (BlockSize - WarmupCount)
// Returns True on success.
function FLACDecodeResiduals(
  var Br           : TAudioBitReader;
  CodingMethod     : Integer;
  PartitionOrder   : Integer;
  WarmupCount      : Integer;
  BlockSize        : Integer;
  Residuals        : PInteger;     // pointer to output buffer
  ResidualCount    : Integer       // = BlockSize - WarmupCount
): Boolean;

implementation

function FLACDecodeResiduals(
  var Br           : TAudioBitReader;
  CodingMethod     : Integer;
  PartitionOrder   : Integer;
  WarmupCount      : Integer;
  BlockSize        : Integer;
  Residuals        : PInteger;
  ResidualCount    : Integer
): Boolean;
var
  PartitionCount : Integer;
  SamplesPerPart : Integer;
  RiceParamBits  : Integer;
  EscapeParam    : Integer;
  PartIdx        : Integer;
  SampCount      : Integer;
  RiceParam      : Integer;
  SampIdx        : Integer;
  RawBits        : Integer;
  OutPtr         : PInteger;
  V              : Integer;
begin
  Result := False;

  if CodingMethod = FLAC_RESIDUAL_RICE then
  begin
    RiceParamBits := 4;
    EscapeParam   := FLAC_RICE_ESCAPE_PARAM;
  end
  else if CodingMethod = FLAC_RESIDUAL_RICE2 then
  begin
    RiceParamBits := 5;
    EscapeParam   := FLAC_RICE2_ESCAPE_PARAM;
  end
  else
    Exit;

  PartitionCount := 1 shl PartitionOrder;
  SamplesPerPart := BlockSize shr PartitionOrder;
  OutPtr         := Residuals;

  for PartIdx := 0 to PartitionCount - 1 do
  begin
    // Number of samples in this partition
    if PartIdx = 0 then
      SampCount := SamplesPerPart - WarmupCount
    else
      SampCount := SamplesPerPart;

    if SampCount < 0 then Exit;

    // Read Rice parameter
    RiceParam := Integer(FBrRead(Br, RiceParamBits));

    if RiceParam = EscapeParam then
    begin
      // Escape: next 5 bits = raw sample size
      RawBits := Integer(FBrRead(Br, 5));
      for SampIdx := 0 to SampCount - 1 do
      begin
        OutPtr^ := FBrReadSigned(Br, RawBits);
        Inc(OutPtr);
      end;
    end
    else
    begin
      // Rice-coded samples
      for SampIdx := 0 to SampCount - 1 do
      begin
        OutPtr^ := FBrRiceSigned(Br, RiceParam);
        Inc(OutPtr);
      end;
    end;
  end;

  Result := True;
end;

end.
