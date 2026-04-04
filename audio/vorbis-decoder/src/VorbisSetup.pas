unit VorbisSetup;

{
  VorbisSetup.pas - Vorbis header packet parsing

  Parses all three Vorbis header packets:
    1. Identification header: sample rate, channels, block sizes
    2. Comment header: vendor string and user comment tags (skipped)
    3. Setup header: codebooks, time domains, floors, residues, mappings, modes

  After calling VorbisParseHeaders in order on the three Ogg packets,
  TVorbisSetup is fully initialized and ready for audio decode.

  Spec references:
    Section 5 (headers), Section 3 (codebooks), Section 6 (setup)

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Math,
  AudioTypes,
  AudioBitReader,
  VorbisTypes,
  VorbisCodebook;

// Parse the identification header packet (packet type 1).
// Data/DataLen: the raw packet bytes (including the 7-byte header prefix).
// Returns False on parse error.
function VorbisParseIdent(
  Data    : PByte;
  DataLen : Integer;
  var Setup: TVorbisSetup
): Boolean;

// Parse the comment header packet (packet type 3).
// We skip the content but still validate the packet type and framing.
function VorbisParseComment(
  Data    : PByte;
  DataLen : Integer
): Boolean;

// Sort the floor1 X-list and build the XSorted (argsort) index array.
// Called during setup parse; exposed here for testing.
procedure SortFloor1X(var F: TVorbisFloor1);

// Parse the setup header packet (packet type 5).
// This populates all codebooks, floors, residues, mappings and modes.
// Also precomputes the MDCT window functions.
// Returns False on parse error.
function VorbisParseSetup(
  Data    : PByte;
  DataLen : Integer;
  var Setup: TVorbisSetup
): Boolean;

implementation

// ---------------------------------------------------------------------------
// Bit reader wrapper (LSB-first)
// ---------------------------------------------------------------------------

procedure BrInitLSB(var Br: TAudioBitReader; Data: PByte; ByteCount: Integer);
begin
  BrInit(Br, Data, ByteCount, boLSBFirst);
end;

// ---------------------------------------------------------------------------
// Identification header
// ---------------------------------------------------------------------------

function VorbisParseIdent(
  Data    : PByte;
  DataLen : Integer;
  var Setup: TVorbisSetup
): Boolean;
var
  Br         : TAudioBitReader;
  PacketType : Byte;
  I          : Integer;
  BS0, BS1   : Integer;
begin
  Result := False;
  if DataLen < 30 then Exit;

  // Packet type
  PacketType := Data^;
  if PacketType <> VORBIS_PACKET_IDENTIFICATION then Exit;
  // Magic 'vorbis'
  for I := 0 to 5 do
    if Data[1 + I] <> VORBIS_HEADER_MAGIC[I] then Exit;

  BrInitLSB(Br, Data + 7, DataLen - 7);

  Setup.Ident.Version        := BrRead(Br, 32);
  if Setup.Ident.Version <> 0 then Exit;

  Setup.Ident.Channels       := Byte(BrRead(Br, 8));
  Setup.Ident.SampleRate     := BrRead(Br, 32);
  Setup.Ident.BitrateMax     := Integer(BrRead(Br, 32));
  Setup.Ident.BitrateNominal := Integer(BrRead(Br, 32));
  Setup.Ident.BitrateMin     := Integer(BrRead(Br, 32));

  BS0 := BrRead(Br, 4);
  BS1 := BrRead(Br, 4);
  Setup.Ident.BlockSize0Exp := BS0;
  Setup.Ident.BlockSize1Exp := BS1;
  Setup.Ident.BlockSize0 := 1 shl BS0;
  Setup.Ident.BlockSize1 := 1 shl BS1;

  Setup.Ident.FramingBit := BrRead(Br, 1) <> 0;
  if not Setup.Ident.FramingBit then Exit;

  if Setup.Ident.Channels = 0 then Exit;
  if Setup.Ident.SampleRate = 0 then Exit;
  if BS0 < 6 then Exit;
  if BS1 < BS0 then Exit;

  Result := True;
end;

// ---------------------------------------------------------------------------
// Comment header (skip)
// ---------------------------------------------------------------------------

function VorbisParseComment(Data: PByte; DataLen: Integer): Boolean;
var
  I : Integer;
begin
  Result := False;
  if DataLen < 7 then Exit;
  if Data^ <> VORBIS_PACKET_COMMENT then Exit;
  for I := 0 to 5 do
    if Data[1 + I] <> VORBIS_HEADER_MAGIC[I] then Exit;
  // Content is metadata text — not needed for decode
  Result := True;
end;

// ---------------------------------------------------------------------------
// Setup header — codebook parse
// ---------------------------------------------------------------------------

function ParseCodebooks(var Br: TAudioBitReader;
  var CBs: TArray<TVorbisCodebook>; Count: Integer): Boolean;
var
  I, J       : Integer;
  CB         : TVorbisCodebook;
  SyncPat    : Cardinal;
  Ordered    : Boolean;
  Sparse     : Boolean;
  EntryCount : Integer;
  LookupType : Integer;
  ValueBits  : Integer;
  MultCount  : Integer;
  RawVal     : Cardinal;
begin
  Result := False;
  SetLength(CBs, Count);

  for I := 0 to Count - 1 do
  begin
    FillChar(CB, SizeOf(CB), 0);

    // Sync pattern: 0x564342 ("VCB" = 0x42 0x43 0x56 in MSB notation, but LSB-first)
    SyncPat := BrRead(Br, 24);
    if SyncPat <> $564342 then Exit;

    CB.Dimensions := BrRead(Br, 16);
    EntryCount    := BrRead(Br, 24);
    CB.Entries    := EntryCount;
    SetLength(CB.Lengths, EntryCount);

    Ordered := BrRead(Br, 1) <> 0;

    if not Ordered then
    begin
      Sparse := BrRead(Br, 1) <> 0;
      if Sparse then
      begin
        // Each entry: 1 flag bit, if set then 5-bit length
        for J := 0 to EntryCount - 1 do
        begin
          if BrRead(Br, 1) <> 0 then
            CB.Lengths[J] := Byte(BrRead(Br, 5) + 1)
          else
            CB.Lengths[J] := 0; // unused
        end;
      end
      else
      begin
        // All entries: 5-bit length each
        for J := 0 to EntryCount - 1 do
          CB.Lengths[J] := Byte(BrRead(Br, 5) + 1);
      end;
    end
    else
    begin
      // Ordered: lengths are run-length encoded
      var CurLen: Integer := BrRead(Br, 5) + 1;
      J := 0;
      while J < EntryCount do
      begin
        var RunLen: Integer := BrRead(Br, VorbisILog(EntryCount - J));
        while (RunLen > 0) and (J < EntryCount) do
        begin
          CB.Lengths[J] := Byte(CurLen);
          Inc(J);
          Dec(RunLen);
        end;
        Inc(CurLen);
      end;
    end;

    // Lookup type
    LookupType := BrRead(Br, 4);
    CB.LookupType := LookupType;

    if LookupType = VORBIS_LOOKUP_NONE then
    begin
      // No VQ
    end
    else if (LookupType = VORBIS_LOOKUP_TYPE1) or (LookupType = VORBIS_LOOKUP_TYPE2) then
    begin
      CB.MinValue   := VorbisFloat32Unpack(BrRead(Br, 32));
      CB.DeltaValue := VorbisFloat32Unpack(BrRead(Br, 32));
      ValueBits     := BrRead(Br, 4) + 1;
      CB.ValueBits  := ValueBits;
      CB.SequenceP  := BrRead(Br, 1) <> 0;

      if LookupType = VORBIS_LOOKUP_TYPE1 then
        MultCount := VorbisLookup1Values(EntryCount, CB.Dimensions)
      else
        MultCount := EntryCount * CB.Dimensions;

      SetLength(CB.Multiplicands, MultCount);
      for J := 0 to MultCount - 1 do
      begin
        RawVal := BrRead(Br, ValueBits);
        CB.Multiplicands[J] := RawVal;  // stored as raw int; VorbisCodebookInit converts
      end;
    end
    else
      Exit; // unknown lookup type

    // Build Huffman decode table
    if not VorbisCodebookInit(CB) then Exit;
    CBs[I] := CB;
  end;

  Result := True;
end;

// ---------------------------------------------------------------------------
// Setup header — floor parse
// ---------------------------------------------------------------------------

// Sort the floor1 X list and compute XSorted (argsort)
procedure SortFloor1X(var F: TVorbisFloor1);
var
  I, J, Tmp: Integer;
begin
  // XSorted[I] = original index of the I-th smallest X
  SetLength(F.XSorted, F.XListCount);
  for I := 0 to F.XListCount - 1 do F.XSorted[I] := I;
  // Insertion sort (list is small, <= 65 elements)
  for I := 1 to F.XListCount - 1 do
  begin
    J := I;
    while (J > 0) and (F.XList[F.XSorted[J]] < F.XList[F.XSorted[J-1]]) do
    begin
      Tmp := F.XSorted[J]; F.XSorted[J] := F.XSorted[J-1]; F.XSorted[J-1] := Tmp;
      Dec(J);
    end;
  end;
end;

function ParseFloors(var Br: TAudioBitReader;
  var Floors: TArray<TVorbisFloor>; Count: Integer;
  BlockSize0, BlockSize1: Integer): Boolean;
var
  I, J, K    : Integer;
  FType      : Integer;
  F          : TVorbisFloor;
  Partitions : Integer;
  ClassCount : Integer;
  MaxClass   : Integer;
  XListCount : Integer;
begin
  Result := False;
  SetLength(Floors, Count);

  for I := 0 to Count - 1 do
  begin
    FillChar(F, SizeOf(F), 0);
    FType := BrRead(Br, 16);
    F.FloorType := FType;

    if FType = VORBIS_FLOOR_TYPE_0 then
    begin
      F.Floor0.Order          := BrRead(Br, 8);
      F.Floor0.Rate           := BrRead(Br, 16);
      F.Floor0.BarkMapSize    := BrRead(Br, 16);
      F.Floor0.AmplitudeBits  := BrRead(Br, 6);
      F.Floor0.AmplitudeOffset:= BrRead(Br, 8);
      F.Floor0.NumberOfBooks  := BrRead(Br, 4) + 1;
      for J := 0 to F.Floor0.NumberOfBooks - 1 do
        F.Floor0.BookList[J] := BrRead(Br, 8);
    end
    else if FType = VORBIS_FLOOR_TYPE_1 then
    begin
      Partitions := BrRead(Br, 5);
      F.Floor1.Partitions := Partitions;
      SetLength(F.Floor1.PartitionClassList, Partitions);

      MaxClass := -1;
      for J := 0 to Partitions - 1 do
      begin
        F.Floor1.PartitionClassList[J] := BrRead(Br, 4);
        if F.Floor1.PartitionClassList[J] > MaxClass then
          MaxClass := F.Floor1.PartitionClassList[J];
      end;

      ClassCount := MaxClass + 1;
      F.Floor1.ClassCount := ClassCount;
      SetLength(F.Floor1.Classes, ClassCount);

      for J := 0 to ClassCount - 1 do
      begin
        F.Floor1.Classes[J].Dimensions := BrRead(Br, 3) + 1;
        F.Floor1.Classes[J].SubClasses := BrRead(Br, 2);
        if F.Floor1.Classes[J].SubClasses <> 0 then
          F.Floor1.Classes[J].MasterBook := BrRead(Br, 8)
        else
          F.Floor1.Classes[J].MasterBook := -1;
        for K := 0 to (1 shl F.Floor1.Classes[J].SubClasses) - 1 do
          F.Floor1.Classes[J].SubClassBooks[K] := Integer(BrRead(Br, 8)) - 1;
      end;

      F.Floor1.Multiplier := BrRead(Br, 2) + 1;
      F.Floor1.RangeBits  := BrRead(Br, 4);

      // X list: always starts with 0 and (BlockSize/2); then partition points
      XListCount := 2;
      for J := 0 to Partitions - 1 do
        Inc(XListCount, F.Floor1.Classes[F.Floor1.PartitionClassList[J]].Dimensions);

      SetLength(F.Floor1.XList, XListCount);
      F.Floor1.XList[0] := 0;
      F.Floor1.XList[1] := BlockSize1 div 2;  // n/2 of longest block

      var XIdx: Integer := 2;
      for J := 0 to Partitions - 1 do
      begin
        var Cls := F.Floor1.Classes[F.Floor1.PartitionClassList[J]];
        for K := 0 to Cls.Dimensions - 1 do
        begin
          F.Floor1.XList[XIdx] := BrRead(Br, F.Floor1.RangeBits);
          Inc(XIdx);
        end;
      end;
      F.Floor1.XListCount := XListCount;

      // Precompute sorted index
      SortFloor1X(F.Floor1);
    end
    else
      Exit; // unknown floor type

    Floors[I] := F;
  end;

  Result := True;
end;

// ---------------------------------------------------------------------------
// Setup header — residue parse
// ---------------------------------------------------------------------------

function ParseResidues(var Br: TAudioBitReader;
  var Residues: TArray<TVorbisResidue>; Count: Integer): Boolean;
var
  I, J, K    : Integer;
  Res        : TVorbisResidue;
  MaxPass    : Integer;
begin
  Result := False;
  SetLength(Residues, Count);

  for I := 0 to Count - 1 do
  begin
    FillChar(Res, SizeOf(Res), 0);
    Res.ResType      := BrRead(Br, 16);
    if Res.ResType > 2 then Exit;

    Res.Begin_       := BrRead(Br, 24);
    Res.End_         := BrRead(Br, 24);
    Res.PartitionSize:= BrRead(Br, 24) + 1;
    Res.Classifications := BrRead(Br, 6) + 1;
    Res.ClassBook    := BrRead(Br, 8);

    // For each classification: cascade bitmask + book indices
    MaxPass := 0;
    for J := 0 to Res.Classifications - 1 do
    begin
      var HighBits: Integer := 0;
      var LowBits : Integer := BrRead(Br, 3);
      if BrRead(Br, 1) <> 0 then
        HighBits := BrRead(Br, 5);
      var Cascade: Integer := (HighBits shl 3) or LowBits;
      for K := 0 to 7 do
      begin
        if (Cascade and (1 shl K)) <> 0 then
        begin
          Res.Books[J][K] := BrRead(Br, 8);
          if K + 1 > MaxPass then MaxPass := K + 1;
        end
        else
          Res.Books[J][K] := -1;
      end;
    end;
    Res.StageCount := MaxPass;
    Residues[I] := Res;
  end;

  Result := True;
end;

// ---------------------------------------------------------------------------
// Setup header — mapping parse
// ---------------------------------------------------------------------------

function ParseMappings(var Br: TAudioBitReader;
  var Mappings: TArray<TVorbisMapping>; Count, Channels: Integer): Boolean;
var
  I, J   : Integer;
  M      : TVorbisMapping;
  MType  : Integer;
  Submaps: Integer;
begin
  Result := False;
  SetLength(Mappings, Count);

  for I := 0 to Count - 1 do
  begin
    FillChar(M, SizeOf(M), 0);
    MType := BrRead(Br, 16);
    if MType <> 0 then Exit;  // only mapping type 0 defined in Vorbis I

    if BrRead(Br, 1) <> 0 then
      Submaps := BrRead(Br, 4) + 1
    else
      Submaps := 1;
    M.SubMaps := Submaps;

    if BrRead(Br, 1) <> 0 then
    begin
      // Square polar channel coupling
      M.Couplings := BrRead(Br, 8) + 1;
      SetLength(M.CouplingList, M.Couplings);
      for J := 0 to M.Couplings - 1 do
      begin
        M.CouplingList[J].Magnitude := BrRead(Br, VorbisILog(Channels - 1));
        M.CouplingList[J].Angle     := BrRead(Br, VorbisILog(Channels - 1));
        if M.CouplingList[J].Magnitude = M.CouplingList[J].Angle then Exit;
      end;
    end
    else
      M.Couplings := 0;

    if BrRead(Br, 2) <> 0 then Exit; // reserved field must be 0

    SetLength(M.Mux, Channels);
    if Submaps > 1 then
    begin
      for J := 0 to Channels - 1 do
        M.Mux[J] := BrRead(Br, 4);
    end
    else
      for J := 0 to Channels - 1 do M.Mux[J] := 0;

    for J := 0 to Submaps - 1 do
    begin
      BrRead(Br, 8);  // time configuration placeholder (unused in Vorbis I)
      M.SubMapFloor[J]   := BrRead(Br, 8);
      M.SubMapResidue[J] := BrRead(Br, 8);
    end;

    Mappings[I] := M;
  end;

  Result := True;
end;

// ---------------------------------------------------------------------------
// Setup header — mode parse
// ---------------------------------------------------------------------------

function ParseModes(var Br: TAudioBitReader;
  var Modes: TArray<TVorbisMode>; Count: Integer): Boolean;
var
  I : Integer;
begin
  Result := False;
  SetLength(Modes, Count);
  for I := 0 to Count - 1 do
  begin
    Modes[I].BlockFlag     := BrRead(Br, 1) <> 0;
    Modes[I].WindowType    := BrRead(Br, 16);
    Modes[I].TransformType := BrRead(Br, 16);
    Modes[I].Mapping       := BrRead(Br, 8);
    if Modes[I].WindowType <> 0 then Exit;    // only type 0 in Vorbis I
    if Modes[I].TransformType <> 0 then Exit; // only MDCT in Vorbis I
  end;
  Result := True;
end;

// ---------------------------------------------------------------------------
// Precompute sine windows
// ---------------------------------------------------------------------------

procedure BuildWindows(var Setup: TVorbisSetup);
var
  N0, N1 : Integer;
  I      : Integer;
begin
  N0 := Setup.Ident.BlockSize0;
  N1 := Setup.Ident.BlockSize1;

  SetLength(Setup.Window0, N0);
  SetLength(Setup.Window1, N1);

  // Vorbis I window: w[i] = sin(pi/2 * sin^2(pi*(i+0.5)/N))
  for I := 0 to N0 - 1 do
  begin
    var S: Single := Sin(Pi * (I + 0.5) / N0);
    Setup.Window0[I] := Sin(Pi / 2.0 * S * S);
  end;
  for I := 0 to N1 - 1 do
  begin
    var S: Single := Sin(Pi * (I + 0.5) / N1);
    Setup.Window1[I] := Sin(Pi / 2.0 * S * S);
  end;
end;

// ---------------------------------------------------------------------------
// VorbisParseSetup
// ---------------------------------------------------------------------------

function VorbisParseSetup(
  Data    : PByte;
  DataLen : Integer;
  var Setup: TVorbisSetup
): Boolean;
var
  Br         : TAudioBitReader;
  I          : Integer;
  PacketType : Byte;
  CBCount    : Integer;
  FloorCount : Integer;
  ResCount   : Integer;
  MapCount   : Integer;
  ModeCount  : Integer;
  TimeCount  : Integer;
begin
  Result := False;
  if DataLen < 7 then Exit;

  PacketType := Data^;
  if PacketType <> VORBIS_PACKET_SETUP then Exit;
  for I := 0 to 5 do
    if Data[1 + I] <> VORBIS_HEADER_MAGIC[I] then Exit;

  BrInitLSB(Br, Data + 7, DataLen - 7);

  // Codebooks
  CBCount := BrRead(Br, 8) + 1;
  Setup.CodebookCount := CBCount;
  if not ParseCodebooks(Br, Setup.Codebooks, CBCount) then Exit;

  // Time domains (Vorbis I: count+1, all must be type 0, ignored)
  TimeCount := BrRead(Br, 6) + 1;
  for I := 0 to TimeCount - 1 do
    if BrRead(Br, 16) <> 0 then Exit;

  // Floors
  FloorCount := BrRead(Br, 6) + 1;
  Setup.FloorCount := FloorCount;
  if not ParseFloors(Br, Setup.Floors, FloorCount,
    Setup.Ident.BlockSize0, Setup.Ident.BlockSize1) then Exit;

  // Residues
  ResCount := BrRead(Br, 6) + 1;
  Setup.ResidueCount := ResCount;
  if not ParseResidues(Br, Setup.Residues, ResCount) then Exit;

  // Mappings
  MapCount := BrRead(Br, 6) + 1;
  Setup.MappingCount := MapCount;
  if not ParseMappings(Br, Setup.Mappings, MapCount, Setup.Ident.Channels) then Exit;

  // Modes
  ModeCount := BrRead(Br, 6) + 1;
  Setup.ModeCount := ModeCount;
  if not ParseModes(Br, Setup.Modes, ModeCount) then Exit;

  // Framing bit
  if BrRead(Br, 1) = 0 then Exit;

  // Precompute windows
  BuildWindows(Setup);

  Setup.Initialized := True;
  Result := True;
end;

end.
