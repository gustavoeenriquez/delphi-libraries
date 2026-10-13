unit VorbisResidue;

{
  VorbisResidue.pas - Vorbis residue decode, formats 0, 1 and 2 (spec section 8.6)

  All three formats share one decode loop (8.6.2):
    for each pass 0..7
      for each group of classwords_per_codeword partitions
        pass 0: read one classification codeword per decoded channel
        decode each partition of the group with residue_books[class][pass]

  Format 2 interleaves all channels of the submap into a single vector of
  length ch * n/2, decodes it like format 1, then de-interleaves (8.6.4).

  Reference: Vorbis I spec; stb_vorbis decode_residue (public domain).

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

// Decode the residue of one submap.
//   Ch          : number of channels in this submap
//   DoNotDecode : per-channel flag (floor unused and not re-enabled by coupling)
//   Outputs     : per-channel spectrum buffers, N2 floats each; decoded channels
//                 are zeroed first, skipped channels are left untouched
//   N2          : blocksize / 2
procedure VorbisDecodeResidue(
  const Res        : TVorbisResidue;
  var CBs          : TArray<TVorbisCodebook>;
  var Br           : TAudioBitReader;
  Ch               : Integer;
  const DoNotDecode: TArray<Boolean>;
  const Outputs    : TArray<PSingle>;
  N2               : Integer
);

implementation

// Decode one partition into Target[Offset..Offset+PartSize) (spec 8.6.3 / 8.6.4).
// Limit bounds writes (actual vector size).
function DecodePartition(var Book: TVorbisCodebook; var Br: TAudioBitReader;
  Target: PSingle; Offset, PartSize, Limit, RType: Integer): Boolean;
var
  Dim, Step, K, D, Sym: Integer;
  Row: PSingle;
begin
  Result := False;
  Dim := Book.Dimensions;
  if (Dim <= 0) or (Length(Book.VQValues) = 0) then Exit;

  if RType = VORBIS_RESIDUE_TYPE_0 then
  begin
    Step := PartSize div Dim;
    for K := 0 to Step - 1 do
    begin
      Sym := VorbisCodebookDecode(Book, Br);
      if Sym < 0 then Exit;
      Row := VorbisCodebookVQRow(Book, Sym);
      for D := 0 to Dim - 1 do
        if Offset + K + D * Step < Limit then
          Target[Offset + K + D * Step] := Target[Offset + K + D * Step] + Row[D];
    end;
  end
  else
  begin
    K := 0;
    while K < PartSize do
    begin
      Sym := VorbisCodebookDecode(Book, Br);
      if Sym < 0 then Exit;
      Row := VorbisCodebookVQRow(Book, Sym);
      for D := 0 to Dim - 1 do
        if Offset + K + D < Limit then
          Target[Offset + K + D] := Target[Offset + K + D] + Row[D];
      Inc(K, Dim);
    end;
  end;
  Result := True;
end;

// Generic loop over Ch vectors of ActualSize floats (formats 0/1, or the
// single interleaved vector of format 2).
procedure DecodeVectors(
  const Res        : TVorbisResidue;
  var CBs          : TArray<TVorbisCodebook>;
  var Br           : TAudioBitReader;
  Ch               : Integer;
  const DoNotDecode: TArray<Boolean>;
  const Vectors    : TArray<PSingle>;
  ActualSize       : Integer;
  RType            : Integer
);
var
  LimitBegin, LimitEnd, NRead, PartRead: Integer;
  ClassWords   : Integer;
  Classif      : TArray<TArray<Integer>>;
  Pass, PCount : Integer;
  I, J, Temp   : Integer;
  C, B, Offset : Integer;
begin
  if Res.PartitionSize <= 0 then Exit;
  LimitBegin := Min(Integer(Res.Begin_), ActualSize);
  LimitEnd   := Min(Integer(Res.End_),   ActualSize);
  NRead      := LimitEnd - LimitBegin;
  if NRead <= 0 then Exit;
  PartRead   := NRead div Res.PartitionSize;
  if PartRead <= 0 then Exit;

  ClassWords := CBs[Res.ClassBook].Dimensions;
  if ClassWords <= 0 then Exit;

  SetLength(Classif, Ch);
  for J := 0 to Ch - 1 do
    SetLength(Classif[J], PartRead + ClassWords);

  for Pass := 0 to 7 do
  begin
    PCount := 0;
    while PCount < PartRead do
    begin
      if Pass = 0 then
        for J := 0 to Ch - 1 do
          if not DoNotDecode[J] then
          begin
            Temp := VorbisCodebookDecode(CBs[Res.ClassBook], Br);
            if Temp < 0 then Exit;  // end of packet: stop, keep what we have
            for I := ClassWords - 1 downto 0 do
            begin
              Classif[J][I + PCount] := Temp mod Res.Classifications;
              Temp := Temp div Res.Classifications;
            end;
          end;
      I := 0;
      while (I < ClassWords) and (PCount < PartRead) do
      begin
        for J := 0 to Ch - 1 do
          if not DoNotDecode[J] then
          begin
            C := Classif[J][PCount];
            B := Res.Books[C][Pass];
            if B >= 0 then
            begin
              Offset := Integer(Res.Begin_) + PCount * Res.PartitionSize;
              if not DecodePartition(CBs[B], Br, Vectors[J], Offset,
                                     Res.PartitionSize, ActualSize, RType) then
                Exit;
            end;
          end;
        Inc(I);
        Inc(PCount);
      end;
    end;
  end;
end;

procedure VorbisDecodeResidue(
  const Res        : TVorbisResidue;
  var CBs          : TArray<TVorbisCodebook>;
  var Br           : TAudioBitReader;
  Ch               : Integer;
  const DoNotDecode: TArray<Boolean>;
  const Outputs    : TArray<PSingle>;
  N2               : Integer
);
var
  J, I       : Integer;
  AnyDecode  : Boolean;
  Merged     : TArray<Single>;
  MergedPtr  : TArray<PSingle>;
  MergedFlag : TArray<Boolean>;
begin
  for J := 0 to Ch - 1 do
    if not DoNotDecode[J] then
      FillChar(Outputs[J]^, N2 * SizeOf(Single), 0);

  if Res.ResType <> VORBIS_RESIDUE_TYPE_2 then
  begin
    DecodeVectors(Res, CBs, Br, Ch, DoNotDecode, Outputs, N2, Res.ResType);
    Exit;
  end;

  // Format 2: all channels interleaved into one vector of Ch * N2 values.
  AnyDecode := False;
  for J := 0 to Ch - 1 do
    if not DoNotDecode[J] then AnyDecode := True;
  if not AnyDecode then Exit;

  SetLength(Merged, Ch * N2);
  FillChar(Merged[0], Ch * N2 * SizeOf(Single), 0);
  SetLength(MergedPtr, 1);  MergedPtr[0]  := @Merged[0];
  SetLength(MergedFlag, 1); MergedFlag[0] := False;
  DecodeVectors(Res, CBs, Br, 1, MergedFlag, MergedPtr, Ch * N2, VORBIS_RESIDUE_TYPE_1);

  for I := 0 to N2 - 1 do
    for J := 0 to Ch - 1 do
      if not DoNotDecode[J] then
        Outputs[J][I] := Merged[I * Ch + J];
end;

end.
