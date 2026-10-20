unit OpusRepacketizer;

{
  OpusRepacketizer.pas - Opus packet framing helpers used by the encoder

  Port of libopus 1.5.2 src/repacketizer.c (opus_repacketizer_cat,
  opus_repacketizer_out_range_impl, opus_packet_pad) and src/opus.c
  (opus_packet_parse_impl, encode_size). Packet extensions (padding
  extensions of libopus 1.5) are not generated: padding is always zeros,
  which is what libopus produces when no extension is present.

  Copyright (c) 2011 Xiph.Org Foundation. Written by Jean-Marc Valin.
  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  OpusEncTypes;

type
  PPByte = ^PByte;

  TOpusRepacketizer = record
    Toc      : Byte;
    NbFrames : Integer;
    Frames   : array[0..47] of PByte;
    Len      : array[0..47] of SmallInt;
    Framesize: Integer;
    procedure Init;
    function  Cat(Data: PByte; Len_: Integer): Integer;
    function  OutRange(BeginF, EndF: Integer; Data: PByte; MaxLen: Integer; Pad: Boolean): Integer;
  end;

function OpusPacketGetSamplesPerFrame(Data: PByte; Fs: Integer): Integer;
function OpusPacketGetNbFrames(Data: PByte; Len: Integer): Integer;
function OpusPacketParseImpl(Data: PByte; Len: Integer; out OutToc: Byte;
  Frames: PPByte; Size: PSmallInt; out PayloadOffset: Integer): Integer;
// Pads Data (Len bytes) in place to NewLen bytes. Returns OPUS_OK or an error.
function OpusPacketPad(Data: PByte; Len, NewLen: Integer): Integer;

implementation

function OpusPacketGetSamplesPerFrame(Data: PByte; Fs: Integer): Integer;
var
  Audiosize: Integer;
begin
  if (Data[0] and $80) <> 0 then
  begin
    Audiosize := (Data[0] shr 3) and 3;
    Result := (Fs shl Audiosize) div 400;
  end
  else if (Data[0] and $60) = $60 then
  begin
    if (Data[0] and $08) <> 0 then Result := Fs div 50
    else Result := Fs div 100;
  end
  else
  begin
    Audiosize := (Data[0] shr 3) and 3;
    if Audiosize = 3 then Result := Fs * 60 div 1000
    else Result := (Fs shl Audiosize) div 100;
  end;
end;

function OpusPacketGetNbFrames(Data: PByte; Len: Integer): Integer;
var
  Count: Integer;
begin
  if Len < 1 then Exit(OPUS_BAD_ARG);
  Count := Data[0] and 3;
  if Count = 0 then Result := 1
  else if Count <> 3 then Result := 2
  else if Len < 2 then Result := OPUS_INVALID_PACKET
  else Result := Data[1] and $3F;
end;

function EncodeSize(Size: Integer; Data: PByte): Integer;
begin
  if Size < 252 then
  begin
    Data[0] := Size;
    Result := 1;
  end
  else
  begin
    Data[0] := 252 + (Size and 3);
    Data[1] := (Size - Data[0]) shr 2;
    Result := 2;
  end;
end;

function ParseSize(Data: PByte; Len: Integer; out Size: SmallInt): Integer;
begin
  if Len < 1 then
  begin
    Size := -1;
    Result := -1;
  end
  else if Data[0] < 252 then
  begin
    Size := Data[0];
    Result := 1;
  end
  else if Len < 2 then
  begin
    Size := -1;
    Result := -1;
  end
  else
  begin
    Size := 4 * Data[1] + Data[0];
    Result := 2;
  end;
end;

function OpusPacketParseImpl(Data: PByte; Len: Integer; out OutToc: Byte;
  Frames: PPByte; Size: PSmallInt; out PayloadOffset: Integer): Integer;
var
  I, Bytes, Count, Framesize, LastSize, P, Tmp: Integer;
  Ch, Toc: Byte;
  Data0: PByte;
begin
  OutToc := 0;
  PayloadOffset := 0;
  if Len < 0 then Exit(OPUS_BAD_ARG);
  if Len = 0 then Exit(OPUS_INVALID_PACKET);
  Data0 := Data;
  Framesize := OpusPacketGetSamplesPerFrame(Data, 48000);
  Toc := Data^;
  Inc(Data);
  Dec(Len);
  LastSize := Len;
  case Toc and 3 of
    0: Count := 1;
    1:
      begin
        Count := 2;
        if (Len and 1) <> 0 then Exit(OPUS_INVALID_PACKET);
        LastSize := Len div 2;
        Size[0] := SmallInt(LastSize);
      end;
    2:
      begin
        Count := 2;
        Bytes := ParseSize(Data, Len, Size[0]);
        Len := Len - Bytes;
        if (Size[0] < 0) or (Size[0] > Len) then Exit(OPUS_INVALID_PACKET);
        Inc(Data, Bytes);
        LastSize := Len - Size[0];
      end;
  else
    begin
      if Len < 1 then Exit(OPUS_INVALID_PACKET);
      Ch := Data^;
      Inc(Data);
      Count := Ch and $3F;
      if (Count <= 0) or (Framesize * Count > 5760) then Exit(OPUS_INVALID_PACKET);
      Dec(Len);
      if (Ch and $40) <> 0 then
      begin
        repeat
          if Len <= 0 then Exit(OPUS_INVALID_PACKET);
          P := Data^;
          Inc(Data);
          Dec(Len);
          if P = 255 then Tmp := 254 else Tmp := P;
          Len := Len - Tmp;
        until P <> 255;
      end;
      if Len < 0 then Exit(OPUS_INVALID_PACKET);
      if (Ch and $80) <> 0 then
      begin
        LastSize := Len;
        for I := 0 to Count - 2 do
        begin
          Bytes := ParseSize(Data, Len, Size[I]);
          Len := Len - Bytes;
          if (Size[I] < 0) or (Size[I] > Len) then Exit(OPUS_INVALID_PACKET);
          Inc(Data, Bytes);
          LastSize := LastSize - (Bytes + Size[I]);
        end;
        if LastSize < 0 then Exit(OPUS_INVALID_PACKET);
      end
      else
      begin
        LastSize := Len div Count;
        if LastSize * Count <> Len then Exit(OPUS_INVALID_PACKET);
        for I := 0 to Count - 2 do
          Size[I] := SmallInt(LastSize);
      end;
    end;
  end;
  if LastSize > 1275 then Exit(OPUS_INVALID_PACKET);
  Size[Count - 1] := SmallInt(LastSize);
  PayloadOffset := Data - Data0;
  for I := 0 to Count - 1 do
  begin
    if Frames <> nil then
      Frames[I] := Data;
    Inc(Data, Size[I]);
  end;
  OutToc := Toc;
  Result := Count;
end;

procedure TOpusRepacketizer.Init;
begin
  NbFrames := 0;
end;

function TOpusRepacketizer.Cat(Data: PByte; Len_: Integer): Integer;
var
  CurrNbFrames, Ret, Dummy: Integer;
  TmpToc: Byte;
begin
  if Len_ < 1 then Exit(OPUS_INVALID_PACKET);
  if NbFrames = 0 then
  begin
    Toc := Data[0];
    Framesize := OpusPacketGetSamplesPerFrame(Data, 8000);
  end
  else if (Toc and $FC) <> (Data[0] and $FC) then
    Exit(OPUS_INVALID_PACKET);
  CurrNbFrames := OpusPacketGetNbFrames(Data, Len_);
  if CurrNbFrames < 1 then Exit(OPUS_INVALID_PACKET);
  if (CurrNbFrames + NbFrames) * Framesize > 960 then
    Exit(OPUS_INVALID_PACKET);
  Ret := OpusPacketParseImpl(Data, Len_, TmpToc, @Frames[NbFrames], @Len[NbFrames], Dummy);
  if Ret < 1 then Exit(Ret);
  NbFrames := NbFrames + CurrNbFrames;
  Result := OPUS_OK;
end;

function TOpusRepacketizer.OutRange(BeginF, EndF: Integer; Data: PByte; MaxLen: Integer;
  Pad: Boolean): Integer;
var
  I, Count, TotSize, OnesBegin, OnesEnd, PadAmount, Nb255s: Integer;
  L: PSmallInt;
  F: PPByte;
  Ptr: PByte;
  Vbr: Boolean;
begin
  OnesBegin := 0;
  OnesEnd := 0;
  if (BeginF < 0) or (BeginF >= EndF) or (EndF > NbFrames) then
    Exit(OPUS_BAD_ARG);
  Count := EndF - BeginF;
  L := @Len[BeginF];
  F := @Frames[BeginF];
  TotSize := 0;
  Ptr := Data;
  if Count = 1 then
  begin
    TotSize := TotSize + L[0] + 1;
    if TotSize > MaxLen then Exit(OPUS_BUFFER_TOO_SMALL);
    Ptr^ := Toc and $FC; Inc(Ptr);
  end
  else if Count = 2 then
  begin
    if L[1] = L[0] then
    begin
      TotSize := TotSize + 2 * L[0] + 1;
      if TotSize > MaxLen then Exit(OPUS_BUFFER_TOO_SMALL);
      Ptr^ := (Toc and $FC) or 1; Inc(Ptr);
    end
    else
    begin
      TotSize := TotSize + L[0] + L[1] + 2 + Ord(L[0] >= 252);
      if TotSize > MaxLen then Exit(OPUS_BUFFER_TOO_SMALL);
      Ptr^ := (Toc and $FC) or 2; Inc(Ptr);
      Inc(Ptr, EncodeSize(L[0], Ptr));
    end;
  end;
  if (Count > 2) or (Pad and (TotSize < MaxLen)) then
  begin
    Ptr := Data;
    TotSize := 0;
    Vbr := False;
    for I := 1 to Count - 1 do
      if L[I] <> L[0] then
      begin
        Vbr := True;
        Break;
      end;
    if Vbr then
    begin
      TotSize := TotSize + 2;
      for I := 0 to Count - 2 do
        TotSize := TotSize + 1 + Ord(L[I] >= 252) + L[I];
      TotSize := TotSize + L[Count - 1];
      if TotSize > MaxLen then Exit(OPUS_BUFFER_TOO_SMALL);
      Ptr^ := (Toc and $FC) or 3; Inc(Ptr);
      Ptr^ := Count or $80; Inc(Ptr);
    end
    else
    begin
      TotSize := TotSize + Count * L[0] + 2;
      if TotSize > MaxLen then Exit(OPUS_BUFFER_TOO_SMALL);
      Ptr^ := (Toc and $FC) or 3; Inc(Ptr);
      Ptr^ := Count; Inc(Ptr);
    end;
    if Pad then PadAmount := MaxLen - TotSize else PadAmount := 0;
    if PadAmount <> 0 then
    begin
      Data[1] := Data[1] or $40;
      Nb255s := (PadAmount - 1) div 255;
      if TotSize + Nb255s + 1 > MaxLen then Exit(OPUS_BUFFER_TOO_SMALL);
      OnesBegin := TotSize + Nb255s + 1;
      OnesEnd := TotSize + PadAmount;
      for I := 0 to Nb255s - 1 do
      begin
        Ptr^ := 255; Inc(Ptr);
      end;
      Ptr^ := PadAmount - 255 * Nb255s - 1; Inc(Ptr);
      TotSize := TotSize + PadAmount;
    end;
    if Vbr then
      for I := 0 to Count - 2 do
        Inc(Ptr, EncodeSize(L[I], Ptr));
  end;
  for I := 0 to Count - 1 do
  begin
    // Move() handles overlap (in-place padding)
    Move(F[I]^, Ptr^, L[I]);
    Inc(Ptr, L[I]);
  end;
  for I := OnesBegin to OnesEnd - 1 do
    Data[I] := $01;
  if Pad then
    while Ptr < Data + MaxLen do
    begin
      Ptr^ := 0;
      Inc(Ptr);
    end;
  Result := TotSize;
end;

function OpusPacketPad(Data: PByte; Len, NewLen: Integer): Integer;
var
  Rp: TOpusRepacketizer;
  Copy: array of Byte;
  Ret: Integer;
begin
  if Len < 1 then Exit(OPUS_BAD_ARG);
  if Len = NewLen then Exit(OPUS_OK)
  else if Len > NewLen then Exit(OPUS_BAD_ARG);
  SetLength(Copy, Len);
  Move(Data^, Copy[0], Len);
  Rp.Init;
  Ret := Rp.Cat(@Copy[0], Len);
  if Ret <> OPUS_OK then Exit(Ret);
  Ret := Rp.OutRange(0, Rp.NbFrames, Data, NewLen, True);
  if Ret > 0 then Result := OPUS_OK else Result := Ret;
end;

end.
