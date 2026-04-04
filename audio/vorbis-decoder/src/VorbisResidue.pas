unit VorbisResidue;

{
  VorbisResidue.pas - Vorbis residue decode (types 0, 1, and 2)

  Residue decoding recovers the spectral residual signal after floor removal.
  Spec reference: Vorbis I spec section 8.

  Three residue types share the same decode structure but differ in how
  the decoded values are placed into output vectors:

    Type 0: values interleave within a partition (class-based VQ)
    Type 1: values are sequential (no interleave)
    Type 2: channels are interleaved before partition decode, then de-interleaved

  All types use the same multi-pass approach:
    - Pass 0..7 (up to 8 passes)
    - For each pass: classify all partitions using class_book, then decode
      each active partition using the per-class/per-pass book

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  SysUtils, Math,
  AudioTypes,
  AudioBitReader,
  VorbisTypes,
  VorbisCodebook;

// Decode residue for one or more channels.
// Res: the residue configuration from setup.
// CBs: all codebooks.
// Br: the packet bit reader.
// Channels: number of channels to decode into (may be 1 for type 0/1, or 2 for coupled type 2).
// DoNotDecode: boolean per channel — if True, skip that channel's output.
// Output: array of Channels pointers, each pointing to N floats (N = block spectral lines).
// N: number of spectral lines (block_size/2).
procedure VorbisDecodeResidue(
  const Res      : TVorbisResidue;
  const CBs      : TArray<TVorbisCodebook>;
  var Br         : TAudioBitReader;
  Channels       : Integer;
  const DoNotDecode: TArray<Boolean>;
  const Output   : TArray<PSingle>;
  N              : Integer
);

implementation

// ---------------------------------------------------------------------------
// Residue decode
// ---------------------------------------------------------------------------

procedure VorbisDecodeResidue(
  const Res      : TVorbisResidue;
  const CBs      : TArray<TVorbisCodebook>;
  var Br         : TAudioBitReader;
  Channels       : Integer;
  const DoNotDecode: TArray<Boolean>;
  const Output   : TArray<PSingle>;
  N              : Integer
);
var
  PassIdx     : Integer;
  PartIdx     : Integer;
  PartCount   : Integer;
  ChIdx       : Integer;
  ClassBook   : Integer;
  PartClass   : TArray<TArray<Integer>>;  // PartClass[ch][part] = class index
  ResBegin    : Integer;
  ResEnd      : Integer;
  PartSize    : Integer;
  Classifications: Integer;
  I           : Integer;
  ClassVal    : Integer;
  BookIdx     : Integer;
  VecBuf      : TArray<Single>;
  // For type 2: interleaved buffer
  Interleaved : TArray<Single>;
  IntN        : Integer;
  // Stage count
  PassCount   : Integer;
begin
  ResBegin    := Res.Begin_;
  ResEnd      := Res.End_;
  if ResEnd > N then ResEnd := N;
  PartSize    := Res.PartitionSize;
  Classifications := Res.Classifications;
  ClassBook   := Res.ClassBook;
  PassCount   := Res.StageCount;

  if PartSize <= 0 then Exit;
  if ResEnd <= ResBegin then Exit;

  PartCount := (ResEnd - ResBegin) div PartSize;
  if PartCount <= 0 then Exit;

  // Allocate partition class arrays
  SetLength(PartClass, Channels);
  for ChIdx := 0 to Channels - 1 do
    SetLength(PartClass[ChIdx], PartCount);

  SetLength(VecBuf, CBs[0].Dimensions + 1);  // sized below per book

  // For type 2: build interleaved residue vector, decode it, then scatter
  if Res.ResType = VORBIS_RESIDUE_TYPE_2 then
  begin
    IntN := N * Channels;
    SetLength(Interleaved, IntN);
    for I := 0 to IntN - 1 do Interleaved[I] := 0.0;
  end;

  // ---- Pass 0: classify all partitions ----
  // For each channel, read partition classes using class_book
  // The class_book gives Classifications^(partition_count / CB.Dimensions) entries
  // per read, covering multiple partitions at once.

  var ClassbookDim := CBs[ClassBook].Dimensions;
  var PartsPerRead := ClassbookDim;  // number of partitions per codebook entry

  for ChIdx := 0 to Channels - 1 do
  begin
    if (Res.ResType < VORBIS_RESIDUE_TYPE_2) and DoNotDecode[ChIdx] then Continue;

    var PartRead := 0;
    while PartRead < PartCount do
    begin
      ClassVal := VorbisCodebookDecode(CBs[ClassBook], Br);
      if ClassVal < 0 then
      begin
        // Truncated packet — fill remaining with class 0
        while PartRead < PartCount do
        begin
          PartClass[ChIdx][PartRead] := 0;
          Inc(PartRead);
        end;
        Break;
      end;
      // Extract per-partition class indices from ClassVal
      // (class book encodes multiple partition classes in one codeword)
      var Temp := ClassVal;
      var K: Integer;
      for K := PartRead + PartsPerRead - 1 downto PartRead do
      begin
        if K < PartCount then
          PartClass[ChIdx][K] := Temp mod Classifications;
        Temp := Temp div Classifications;
      end;
      Inc(PartRead, PartsPerRead);
    end;
  end;

  // ---- Passes 0..7: decode residue values ----
  for PassIdx := 0 to PassCount - 1 do
  begin
    for ChIdx := 0 to Channels - 1 do
    begin
      if (Res.ResType < VORBIS_RESIDUE_TYPE_2) and DoNotDecode[ChIdx] then Continue;

      for PartIdx := 0 to PartCount - 1 do
      begin
        var Cls := PartClass[ChIdx][PartIdx];
        BookIdx := Res.Books[Cls][PassIdx];
        if BookIdx < 0 then Continue;  // no book for this pass/class

        var Offset := ResBegin + PartIdx * PartSize;
        var CBook  := CBs[BookIdx];
        SetLength(VecBuf, CBook.Dimensions);

        case Res.ResType of
          VORBIS_RESIDUE_TYPE_0:
          begin
            // Decode VQ vectors; each vector dimension interleaves within partition
            // step = PartSize / Dimensions
            var Steps := PartSize div CBook.Dimensions;
            var Step: Integer;
            for Step := 0 to Steps - 1 do
            begin
              if not VorbisCodebookDecodeVQ(CBook, Br, @VecBuf[0]) then Break;
              for I := 0 to CBook.Dimensions - 1 do
              begin
                var Pos := Offset + Step + I * Steps;
                if (Pos >= ResBegin) and (Pos < ResEnd) then
                  Output[ChIdx][Pos] := Output[ChIdx][Pos] + VecBuf[I];
              end;
            end;
          end;

          VORBIS_RESIDUE_TYPE_1:
          begin
            // Sequential: decode VQ vectors; place consecutively
            var Pos := Offset;
            while Pos < Offset + PartSize do
            begin
              if not VorbisCodebookDecodeVQ(CBook, Br, @VecBuf[0]) then Break;
              for I := 0 to CBook.Dimensions - 1 do
              begin
                if (Pos + I >= ResBegin) and (Pos + I < ResEnd) then
                  Output[ChIdx][Pos + I] := Output[ChIdx][Pos + I] + VecBuf[I];
              end;
              Inc(Pos, CBook.Dimensions);
            end;
          end;

          VORBIS_RESIDUE_TYPE_2:
          begin
            // Interleaved: decode as if it were type 1 on the merged vector
            // ChIdx here is always 0 (we pass a single merged vector)
            var Pos := Offset;
            while Pos < Offset + PartSize do
            begin
              if not VorbisCodebookDecodeVQ(CBook, Br, @VecBuf[0]) then Break;
              for I := 0 to CBook.Dimensions - 1 do
              begin
                if (Pos + I < IntN) then
                  Interleaved[Pos + I] := Interleaved[Pos + I] + VecBuf[I];
              end;
              Inc(Pos, CBook.Dimensions);
            end;
          end;
        end; // case
      end; // PartIdx
    end; // ChIdx
  end; // PassIdx

  // ---- Type 2: de-interleave ----
  if Res.ResType = VORBIS_RESIDUE_TYPE_2 then
  begin
    for I := 0 to IntN - 1 do
    begin
      ChIdx := I mod Channels;
      var LineIdx := I div Channels;
      if (LineIdx < N) and not DoNotDecode[ChIdx] then
        Output[ChIdx][LineIdx] := Output[ChIdx][LineIdx] + Interleaved[I];
    end;
  end;
end;

end.
