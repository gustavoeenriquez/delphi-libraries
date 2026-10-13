unit MP3EncFrame;

{
  MP3EncFrame.pas — MPEG1 Layer III frame writer

  Assembles a complete MP3 frame into a TMP3BitWriter:
    1. Frame header    (32 bits)
    2. Side information (136 bits mono / 256 bits stereo)
    3. Main data        (scale factors + Huffman-coded spectral data)

  Only long-block (non-switching) granules are handled, matching
  the scope of MP3EncQuantize and MP3EncHuffman.

  Reference: ISO 11172-3 §2.4.1–2.4.3 / toots/shine l3bitstream.c
  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  MP3EncBitWriter, MP3EncQuantize, MP3EncHuffman;

{ --- Constants ------------------------------------------------------------ }

const
  { MPEG version bits (2-bit field in header) }
  FRAME_VER_MPEG1   = 3;  { 11b = MPEG1 }
  FRAME_VER_MPEG2   = 2;  { 10b = MPEG2 }

  { Layer bits (2-bit field: 01=Layer III, 10=Layer II, 11=Layer I) }
  FRAME_LAY_III     = 1;

  { protection_bit = 1 means NO CRC follows the header }
  FRAME_NO_CRC      = 1;

  { Channel mode }
  FRAME_CH_STEREO   = 0;
  FRAME_CH_JOINT    = 1;
  FRAME_CH_DUAL     = 2;
  FRAME_CH_MONO     = 3;

  { Side-info size in bits }
  FRAME_SIDEINFO_MONO   = 136;
  FRAME_SIDEINFO_STEREO = 256;

{ --- Data types ----------------------------------------------------------- }

type
  { Per-granule per-channel information }
  TGrInfo = record
    Part2_3_Length    : Integer;  { total bits: scale factors + Huffman (12 bits) }
    BigValues         : Integer;  { number of big-values pairs (9 bits, max 288) }
    GlobalGain        : Integer;  { quantizer step gain, 0..255 (8 bits) }
    ScalefacCompress  : Integer;  { slen1/slen2 index, 0..15 (4 bits) }
    TableSelect       : array[0..2] of Byte;  { Huffman table per region (5 bits) }
    Region0Count      : Byte;  { sfb boundary count for region 0 (4 bits) }
    Region1Count      : Byte;  { sfb boundary count for region 1 (3 bits) }
    Preflag           : Byte;  { pre-emphasis flag (1 bit) }
    ScalefacScale     : Byte;  { scale factor step-size selector (1 bit) }
    Count1TableSelect : Byte;  { count1 table: 0=table32, 1=table33 (1 bit) }
    Count1            : Integer;  { number of count1 quads }
    SrIdx             : Byte;  { sample rate index: 0=44100, 1=48000, 2=32000 }
    Ix                : T576Int;   { quantized spectral lines (signed) }
    ScalefacL         : TScalefacL;  { long-block scale factors sfb 0..21 }
  end;

  { Frame-level side information }
  TFrameSideInfo = record
    MainDataBegin : Integer;  { 9 bits; negative offset into bit reservoir }
    PrivateBits   : Byte;     { 5 bits mono / 3 bits stereo }
    Scfsi         : array[0..1, 0..3] of Byte;  { [channel][band] }
    Gr            : array[0..1, 0..1] of TGrInfo;  { [granule][channel] }
  end;

  { Frame configuration — all fields written verbatim into the 32-bit header }
  TFrameConfig = record
    VersionBits     : Byte;  { 2 bits: use FRAME_VER_* constants }
    LayerBits       : Byte;  { 2 bits: use FRAME_LAY_* constants }
    ProtectionBit   : Byte;  { 1 bit: 1 = no CRC }
    BitrateIndex    : Byte;  { 4 bits: ISO Table B.2 index }
    SamplerateIndex : Byte;  { 2 bits: 0=44100, 1=48000, 2=32000 }
    Padding         : Byte;  { 1 bit }
    PrivateBit      : Byte;  { 1 bit }
    ChannelMode     : Byte;  { 2 bits: use FRAME_CH_* constants }
    ModeExt         : Byte;  { 2 bits }
    Copyright       : Byte;  { 1 bit }
    Original        : Byte;  { 1 bit }
    Emphasis        : Byte;  { 2 bits }
    Channels        : Integer;  { derived: 1 (mono) or 2 (stereo) }
    Granules        : Integer;  { 2 for MPEG1, 1 for MPEG2/2.5 }
  end;

{ --- Functions ------------------------------------------------------------ }

{ Decode slen1 / slen2 from scalefac_compress (ISO 11172-3 Table B.8). }
procedure FrameSlen(AScalefacCompress: Integer;
  out ASlen1, ASlen2: Integer);

{ Write the 32-bit MPEG1 Layer III frame header to ABW. }
procedure FrameWriteHeader(ABW: TMP3BitWriter;
  const ACfg: TFrameConfig);

{ Write side information (FRAME_SIDEINFO_MONO or FRAME_SIDEINFO_STEREO bits). }
procedure FrameWriteSideInfo(ABW: TMP3BitWriter;
  const ACfg: TFrameConfig; const ASI: TFrameSideInfo);

{ Return the number of bits needed for scale factors of one granule/channel.
  AGrIdx 0 always writes; AGrIdx 1 respects AScfsi[0..3]. }
function FrameScalefacBits(const AGr: TGrInfo;
  AGrIdx: Integer; const AScfsi: array of Byte): Integer;

{ Write scale factors for one granule/channel. }
procedure FrameWriteScalefacs(ABW: TMP3BitWriter;
  const AGr: TGrInfo; AGrIdx: Integer; const AScfsi: array of Byte);

{ Return the number of bits needed for Huffman-coded spectral data
  of one granule/channel (big-values + count1, no padding). }
function FrameHuffmanBits(const AGr: TGrInfo): Integer;

{ Write Huffman-coded spectral data for one granule/channel. }
procedure FrameWriteHuffman(ABW: TMP3BitWriter; const AGr: TGrInfo);

{ Write all main data for a complete frame:
  for each (gr, ch): scale factors then Huffman data.
  No bit-stuffing is added; the caller is responsible for ensuring
  the Part2_3_Length fields are set to the actual bit counts. }
procedure FrameWriteMainData(ABW: TMP3BitWriter;
  const ACfg: TFrameConfig; const ASI: TFrameSideInfo);

implementation

// ---------------------------------------------------------------------------
// slen tables — ISO 11172-3 Table B.8 (same as Shine's shine_slen1/2_tab)
// ---------------------------------------------------------------------------

const
  SLEN1_TAB: array[0..15] of Byte =
    (0, 0, 0, 0, 3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4);
  SLEN2_TAB: array[0..15] of Byte =
    (0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 3, 1, 2, 3, 2, 3);

// ---------------------------------------------------------------------------

procedure FrameSlen(AScalefacCompress: Integer;
  out ASlen1, ASlen2: Integer);
begin
  if (AScalefacCompress >= 0) and (AScalefacCompress <= 15) then begin
    ASlen1 := SLEN1_TAB[AScalefacCompress];
    ASlen2 := SLEN2_TAB[AScalefacCompress];
  end else begin
    ASlen1 := 0; ASlen2 := 0;
  end;
end;

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

procedure FrameWriteHeader(ABW: TMP3BitWriter; const ACfg: TFrameConfig);
begin
  ABW.WriteBits($7FF,               11);  { sync word }
  ABW.WriteBits(ACfg.VersionBits,    2);
  ABW.WriteBits(ACfg.LayerBits,      2);
  ABW.WriteBits(ACfg.ProtectionBit,  1);
  ABW.WriteBits(ACfg.BitrateIndex,   4);
  ABW.WriteBits(ACfg.SamplerateIndex,2);
  ABW.WriteBits(ACfg.Padding,        1);
  ABW.WriteBits(ACfg.PrivateBit,     1);
  ABW.WriteBits(ACfg.ChannelMode,    2);
  ABW.WriteBits(ACfg.ModeExt,        2);
  ABW.WriteBits(ACfg.Copyright,      1);
  ABW.WriteBits(ACfg.Original,       1);
  ABW.WriteBits(ACfg.Emphasis,       2);
end;

// ---------------------------------------------------------------------------
// Side information
// ---------------------------------------------------------------------------

procedure WriteGrSideInfo(ABW: TMP3BitWriter; const AGr: TGrInfo);
begin
  ABW.WriteBits(AGr.Part2_3_Length,    12);
  ABW.WriteBits(AGr.BigValues,          9);
  ABW.WriteBits(AGr.GlobalGain,         8);
  ABW.WriteBits(AGr.ScalefacCompress,   4);
  ABW.WriteBits(0,                      1);  { window_switching_flag = 0 }
  ABW.WriteBits(AGr.TableSelect[0],     5);
  ABW.WriteBits(AGr.TableSelect[1],     5);
  ABW.WriteBits(AGr.TableSelect[2],     5);
  ABW.WriteBits(AGr.Region0Count,       4);
  ABW.WriteBits(AGr.Region1Count,       3);
  ABW.WriteBits(AGr.Preflag,            1);
  ABW.WriteBits(AGr.ScalefacScale,      1);
  ABW.WriteBits(AGr.Count1TableSelect,  1);
end;

procedure FrameWriteSideInfo(ABW: TMP3BitWriter;
  const ACfg: TFrameConfig; const ASI: TFrameSideInfo);
var
  ch, gr: Integer;
begin
  ABW.WriteBits(ASI.MainDataBegin, 9);

  if ACfg.Channels = 1 then
    ABW.WriteBits(ASI.PrivateBits, 5)
  else
    ABW.WriteBits(ASI.PrivateBits, 3);

  { scfsi: only present for MPEG1 }
  for ch := 0 to ACfg.Channels - 1 do
    for gr := 0 to 3 do
      ABW.WriteBits(ASI.Scfsi[ch][gr], 1);

  for gr := 0 to ACfg.Granules - 1 do
    for ch := 0 to ACfg.Channels - 1 do
      WriteGrSideInfo(ABW, ASI.Gr[gr][ch]);
end;

// ---------------------------------------------------------------------------
// Scale factors
// ---------------------------------------------------------------------------

function FrameScalefacBits(const AGr: TGrInfo;
  AGrIdx: Integer; const AScfsi: array of Byte): Integer;
var
  slen1, slen2: Integer;
begin
  FrameSlen(AGr.ScalefacCompress, slen1, slen2);
  Result := 0;
  if (AGrIdx = 0) or (AScfsi[0] = 0) then Inc(Result, 6 * slen1);   { sfb 0..5 }
  if (AGrIdx = 0) or (AScfsi[1] = 0) then Inc(Result, 5 * slen1);   { sfb 6..10 }
  if (AGrIdx = 0) or (AScfsi[2] = 0) then Inc(Result, 5 * slen2);   { sfb 11..15 }
  if (AGrIdx = 0) or (AScfsi[3] = 0) then Inc(Result, 5 * slen2);   { sfb 16..20 }
end;

procedure FrameWriteScalefacs(ABW: TMP3BitWriter;
  const AGr: TGrInfo; AGrIdx: Integer; const AScfsi: array of Byte);
var
  slen1, slen2, sfb: Integer;
begin
  FrameSlen(AGr.ScalefacCompress, slen1, slen2);

  if (AGrIdx = 0) or (AScfsi[0] = 0) then
    for sfb := 0 to 5 do
      ABW.WriteBits(AGr.ScalefacL[sfb], slen1);

  if (AGrIdx = 0) or (AScfsi[1] = 0) then
    for sfb := 6 to 10 do
      ABW.WriteBits(AGr.ScalefacL[sfb], slen1);

  if (AGrIdx = 0) or (AScfsi[2] = 0) then
    for sfb := 11 to 15 do
      ABW.WriteBits(AGr.ScalefacL[sfb], slen2);

  if (AGrIdx = 0) or (AScfsi[3] = 0) then
    for sfb := 16 to 20 do
      ABW.WriteBits(AGr.ScalefacL[sfb], slen2);
end;

// ---------------------------------------------------------------------------
// Huffman
// ---------------------------------------------------------------------------

function FrameHuffmanBits(const AGr: TGrInfo): Integer;
var
  bigEnd, r1Start, r2Start: Integer;
  i, t, bits, absX, absY: Integer;
begin
  Result := 0;
  bigEnd  := AGr.BigValues * 2;

  { Region boundaries from scalefactor band table }
  r1Start := QuantSfbBand(AGr.SrIdx, AGr.Region0Count + 1);
  r2Start := QuantSfbBand(AGr.SrIdx, AGr.Region0Count + AGr.Region1Count + 2);
  if r1Start > bigEnd then r1Start := bigEnd;
  if r2Start > bigEnd then r2Start := bigEnd;

  { Big-values: 3 regions }
  i := 0;
  while i < bigEnd do begin
    if i < r1Start      then t := AGr.TableSelect[0]
    else if i < r2Start then t := AGr.TableSelect[1]
    else                     t := AGr.TableSelect[2];

    absX := Abs(AGr.Ix[i]);
    absY := Abs(AGr.Ix[i + 1]);
    bits := HuffCountPairBits(t, absX, absY);
    if bits <> HUFF_INVALID then Inc(Result, bits);
    Inc(i, 2);
  end;

  { Count1 quads }
  t := HUFF_QUAD_A + AGr.Count1TableSelect;
  i := bigEnd;
  while i < bigEnd + AGr.Count1 * 4 do begin
    bits := HuffCountQuadBits(t,
      Abs(AGr.Ix[i]),     Abs(AGr.Ix[i + 1]),
      Abs(AGr.Ix[i + 2]), Abs(AGr.Ix[i + 3]));
    if bits <> HUFF_INVALID then Inc(Result, bits);
    Inc(i, 4);
  end;
end;

{ Write a packed Huffman code of up to 64 bits (codes with linbits exceed 32). }
procedure WriteCode(ABW: TMP3BitWriter; const AHc: THuffCode);
begin
  if AHc.Len > 32 then begin
    ABW.WriteBits(Cardinal(AHc.Code shr 32), AHc.Len - 32);
    ABW.WriteBits(Cardinal(AHc.Code and $FFFFFFFF), 32);
  end else
    ABW.WriteBits(Cardinal(AHc.Code), AHc.Len);
end;

procedure FrameWriteHuffman(ABW: TMP3BitWriter; const AGr: TGrInfo);
var
  bigEnd, r1Start, r2Start: Integer;
  i, t: Integer;
  hc: THuffCode;
  absX, absY, signX, signY: Integer;
  absV, absW, absXq, absYq, signV, signW, signXq, signYq: Integer;
begin
  bigEnd  := AGr.BigValues * 2;

  r1Start := QuantSfbBand(AGr.SrIdx, AGr.Region0Count + 1);
  r2Start := QuantSfbBand(AGr.SrIdx, AGr.Region0Count + AGr.Region1Count + 2);
  if r1Start > bigEnd then r1Start := bigEnd;
  if r2Start > bigEnd then r2Start := bigEnd;

  { Big-values }
  i := 0;
  while i < bigEnd do begin
    if i < r1Start      then t := AGr.TableSelect[0]
    else if i < r2Start then t := AGr.TableSelect[1]
    else                     t := AGr.TableSelect[2];

    if t > 0 then begin
      absX  := Abs(AGr.Ix[i]);
      signX := Ord(AGr.Ix[i] < 0);
      absY  := Abs(AGr.Ix[i + 1]);
      signY := Ord(AGr.Ix[i + 1] < 0);
      hc    := HuffEncodePair(t, absX, absY, signX, signY);
      if (hc.Len > 0) and (hc.Len <> HUFF_INVALID) then
        WriteCode(ABW, hc);
    end;
    Inc(i, 2);
  end;

  { Count1 quads }
  t := HUFF_QUAD_A + AGr.Count1TableSelect;
  i := bigEnd;
  while i < bigEnd + AGr.Count1 * 4 do begin
    absV  := Abs(AGr.Ix[i]);     signV  := Ord(AGr.Ix[i]     < 0);
    absW  := Abs(AGr.Ix[i + 1]); signW  := Ord(AGr.Ix[i + 1] < 0);
    absXq := Abs(AGr.Ix[i + 2]); signXq := Ord(AGr.Ix[i + 2] < 0);
    absYq := Abs(AGr.Ix[i + 3]); signYq := Ord(AGr.Ix[i + 3] < 0);
    hc := HuffEncodeQuad(t, absV, absW, absXq, absYq,
                            signV, signW, signXq, signYq);
    if (hc.Len > 0) and (hc.Len <> HUFF_INVALID) then
      WriteCode(ABW, hc);
    Inc(i, 4);
  end;
end;

// ---------------------------------------------------------------------------
// Main data
// ---------------------------------------------------------------------------

procedure FrameWriteMainData(ABW: TMP3BitWriter;
  const ACfg: TFrameConfig; const ASI: TFrameSideInfo);
var
  gr, ch: Integer;
  scfsi: array[0..3] of Byte;
  k: Integer;
begin
  for gr := 0 to ACfg.Granules - 1 do
    for ch := 0 to ACfg.Channels - 1 do begin
      for k := 0 to 3 do
        scfsi[k] := ASI.Scfsi[ch][k];
      FrameWriteScalefacs(ABW, ASI.Gr[gr][ch], gr, scfsi);
      FrameWriteHuffman(ABW, ASI.Gr[gr][ch]);
    end;
end;

end.
