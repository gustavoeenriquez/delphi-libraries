program TestMP3EncPhase5;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  MP3EncBitWriter,
  MP3EncQuantize,
  MP3EncHuffman,
  MP3EncFrame;

var
  GTotal  : Integer = 0;
  GPassed : Integer = 0;

procedure Check(const AName: string; ACond: Boolean);
begin
  Inc(GTotal);
  if ACond then begin
    Inc(GPassed);
    WriteLn('  PASS  ', AName);
  end else
    WriteLn('  FAIL  ', AName);
end;

{ Build a minimal valid TFrameConfig for mono MPEG1 Layer III }
function MakeCfgMono: TFrameConfig;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.VersionBits     := FRAME_VER_MPEG1;
  Result.LayerBits       := FRAME_LAY_III;
  Result.ProtectionBit   := FRAME_NO_CRC;
  Result.BitrateIndex    := 9;       { 128 kbps }
  Result.SamplerateIndex := 0;       { 44100 Hz }
  Result.Padding         := 0;
  Result.PrivateBit      := 0;
  Result.ChannelMode     := FRAME_CH_MONO;
  Result.ModeExt         := 0;
  Result.Copyright       := 0;
  Result.Original        := 1;
  Result.Emphasis        := 0;
  Result.Channels        := 1;
  Result.Granules        := 2;
end;

{ Build a minimal valid TFrameConfig for stereo MPEG1 Layer III }
function MakeCfgStereo: TFrameConfig;
begin
  Result := MakeCfgMono;
  Result.ChannelMode := FRAME_CH_STEREO;
  Result.Channels    := 2;
end;

{ Build an all-zero TGrInfo with a given global_gain }
function MakeGr(AGain: Integer): TGrInfo;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.GlobalGain := AGain;
  Result.SrIdx      := 0;
end;

{ Return byte at position AByteIdx from a just-written bitwriter }
function BW_Byte(ABW: TMP3BitWriter; AByteIdx: Integer): Byte;
var
  B: TBytes;
begin
  B := ABW.GetBytes;
  if AByteIdx < Length(B) then Result := B[AByteIdx] else Result := $FF;
end;

var
  BW  : TMP3BitWriter;
  Cfg : TFrameConfig;
  SI  : TFrameSideInfo;
  Gr  : TGrInfo;
  S1, S2: Integer;
  Scfsi: array[0..3] of Byte;
  Bits: Integer;

begin
  HuffInit;
  BW := TMP3BitWriter.Create;
  try
    WriteLn('=== MP3EncFrame Phase 5 ===');

    { -------- SL: FrameSlen -------- }
    WriteLn;
    WriteLn('--- FrameSlen ---');
    FrameSlen(0, S1, S2);
    Check('SL01 compress=0  → (0,0)',  (S1=0) and (S2=0));
    FrameSlen(1, S1, S2);
    Check('SL02 compress=1  → (0,1)',  (S1=0) and (S2=1));
    FrameSlen(5, S1, S2);
    Check('SL03 compress=5  → (1,1)',  (S1=1) and (S2=1));
    FrameSlen(9, S1, S2);
    Check('SL04 compress=9  → (2,2)',  (S1=2) and (S2=2));
    FrameSlen(14, S1, S2);
    Check('SL05 compress=14 → (4,2)',  (S1=4) and (S2=2));
    FrameSlen(15, S1, S2);
    Check('SL06 compress=15 → (4,3)',  (S1=4) and (S2=3));

    { -------- FH: FrameWriteHeader -------- }
    WriteLn;
    WriteLn('--- FrameWriteHeader ---');
    Cfg := MakeCfgMono;
    BW.Reset;
    FrameWriteHeader(BW, Cfg);
    { Sync word occupies bytes 0–1 high bits: byte0 must be 0xFF }
    Check('FH01 header=32 bits',     BW.GetBitCount = 32);
    Check('FH02 byte0=0xFF (sync)',  BW_Byte(BW, 0) = $FF);
    { byte1: sync[3],version=11,layer=01,protection=1 → 11111011 = 0xFB }
    Check('FH03 byte1=0xFB',         BW_Byte(BW, 1) = $FB);
    { byte2: bitrate=9=1001, sr=0=00, padding=0, private=0 → 10010000 = 0x90 }
    Check('FH04 byte2=0x90',         BW_Byte(BW, 2) = $90);
    { byte3: mode=11, ext=00, copyright=0, original=1, emph=00 → 11000100 = 0xC4 }
    Check('FH05 byte3=0xC4 (mono)',  BW_Byte(BW, 3) = $C4);
    { Stereo: mode=00 → byte3 = 00000100 = 0x04 }
    Cfg := MakeCfgStereo;
    BW.Reset;
    FrameWriteHeader(BW, Cfg);
    Check('FH06 byte3=0x04 (stereo)', BW_Byte(BW, 3) = $04);

    { -------- SI: FrameWriteSideInfo -------- }
    WriteLn;
    WriteLn('--- FrameWriteSideInfo ---');
    FillChar(SI, SizeOf(SI), 0);
    SI.Gr[0][0] := MakeGr(210);
    SI.Gr[1][0] := MakeGr(210);

    Cfg := MakeCfgMono;
    BW.Reset;
    FrameWriteSideInfo(BW, Cfg, SI);
    Check('SI01 mono side info = 136 bits', BW.GetBitCount = FRAME_SIDEINFO_MONO);

    Cfg := MakeCfgStereo;
    SI.Gr[0][1] := MakeGr(210);
    SI.Gr[1][1] := MakeGr(210);
    BW.Reset;
    FrameWriteSideInfo(BW, Cfg, SI);
    Check('SI02 stereo side info = 256 bits', BW.GetBitCount = FRAME_SIDEINFO_STEREO);

    { With main_data_begin=5: check bits 0..8 encode 5 = 000000101b }
    Cfg := MakeCfgMono;
    FillChar(SI, SizeOf(SI), 0);
    SI.MainDataBegin := 5;
    SI.Gr[0][0] := MakeGr(128);
    SI.Gr[1][0] := MakeGr(128);
    BW.Reset;
    FrameWriteSideInfo(BW, Cfg, SI);
    { byte1 (bits 8-15): LSB of main_data_begin (5=000000101, bit8=1),
      then private_bits=00000, then scfsi[0..1]=00
      = 1,0,0,0,0,0,0,0 = 0x80 }
    Check('SI03 main_data_begin byte1=0x80', BW_Byte(BW, 1) = $80);
    { byte0 = bits 0-7 of main_data_begin 9-bit field: 000000_10 = 0x02 }
    Check('SI04 main_data_begin byte0=0x02',  BW_Byte(BW, 0) = $02);

    { global_gain=128=0x80: in mono the gain for gr0 starts at bit 39.
      128 = 10000000b.
      bits 32-39: big_values[7..1]=0000000, gain[7]=1 → byte4=0x01
      bits 40-47: gain[6..0]=0000000, scalefac_compress[3]=0 → byte5=0x00 }
    FillChar(SI, SizeOf(SI), 0);
    SI.Gr[0][0] := MakeGr(128);
    SI.Gr[1][0] := MakeGr(128);
    BW.Reset;
    FrameWriteSideInfo(BW, Cfg, SI);
    Check('SI05 global_gain byte4=0x01', BW_Byte(BW, 4) = $01);
    Check('SI06 global_gain byte5=0x00', BW_Byte(BW, 5) = $00);

    { -------- SB: FrameScalefacBits -------- }
    WriteLn;
    WriteLn('--- FrameScalefacBits ---');
    { compress=0 → slen1=0, slen2=0 → 0 bits regardless of scfsi }
    Gr := MakeGr(210);
    Gr.ScalefacCompress := 0;
    FillChar(Scfsi, SizeOf(Scfsi), 0);
    Check('SB01 compress=0 gr0 → 0 bits',
          FrameScalefacBits(Gr, 0, Scfsi) = 0);
    { compress=5 → slen1=1, slen2=1; gr0: 6+5+5+5 = 21 bits }
    Gr.ScalefacCompress := 5;
    Check('SB02 compress=5 gr0 → 21 bits',
          FrameScalefacBits(Gr, 0, Scfsi) = 21);
    { compress=9 → slen1=2, slen2=2; gr0: 12+10+10+10 = 42 bits }
    Gr.ScalefacCompress := 9;
    Check('SB03 compress=9 gr0 → 42 bits',
          FrameScalefacBits(Gr, 0, Scfsi) = 42);
    { compress=5, gr1, scfsi all 0 → same 21 bits }
    Gr.ScalefacCompress := 5;
    Check('SB04 compress=5 gr1 scfsi=0 → 21 bits',
          FrameScalefacBits(Gr, 1, Scfsi) = 21);
    { compress=5, gr1, scfsi[0]=1 → skip band0 (6 bits) → 15 bits }
    Scfsi[0] := 1;
    Check('SB05 compress=5 gr1 scfsi[0]=1 → 15 bits',
          FrameScalefacBits(Gr, 1, Scfsi) = 15);
    { compress=5, gr1, all scfsi=1 → 0 bits }
    Scfsi[0] := 1; Scfsi[1] := 1; Scfsi[2] := 1; Scfsi[3] := 1;
    Check('SB06 compress=5 gr1 all scfsi=1 → 0 bits',
          FrameScalefacBits(Gr, 1, Scfsi) = 0);

    { -------- FS: FrameWriteScalefacs bit count matches -------- }
    WriteLn;
    WriteLn('--- FrameWriteScalefacs ---');
    FillChar(Scfsi, SizeOf(Scfsi), 0);
    Gr := MakeGr(210);
    { compress=5, all scfsi=0, gr0: expect 21 bits written }
    Gr.ScalefacCompress := 5;
    BW.Reset;
    FrameWriteScalefacs(BW, Gr, 0, Scfsi);
    Check('FS01 compress=5 gr0 writes 21 bits', BW.GetBitCount = 21);
    { compress=9, gr0: 42 bits }
    Gr.ScalefacCompress := 9;
    BW.Reset;
    FrameWriteScalefacs(BW, Gr, 0, Scfsi);
    Check('FS02 compress=9 gr0 writes 42 bits', BW.GetBitCount = 42);
    { gr1, scfsi[0]=1: skips band0 → 15 bits }
    Gr.ScalefacCompress := 5;
    Scfsi[0] := 1;
    BW.Reset;
    FrameWriteScalefacs(BW, Gr, 1, Scfsi);
    Check('FS03 compress=5 gr1 scfsi[0]=1 → 15 bits', BW.GetBitCount = 15);
    { scalefac value: set scalefacL[0]=3, slen1=2 → first 2 bits = 11b = bits in byte0 }
    Gr.ScalefacCompress := 9;   { slen1=2 }
    Gr.ScalefacL[0]     := 3;   { 11b }
    FillChar(Scfsi, SizeOf(Scfsi), 0);
    BW.Reset;
    FrameWriteScalefacs(BW, Gr, 0, Scfsi);
    { First 2 bits = 11b → byte0 top bits = 11xxxxxx = 0xC0 or higher }
    Check('FS04 scalefacL[0]=3 → byte0 high bit pair = 11b',
          (BW_Byte(BW, 0) and $C0) = $C0);

    { -------- HB: FrameHuffmanBits -------- }
    WriteLn;
    WriteLn('--- FrameHuffmanBits ---');
    { All-zero Ix, BigValues=0, Count1=0 → 0 bits }
    Gr := MakeGr(210);
    Check('HB01 all-zero gr → 0 huff bits', FrameHuffmanBits(Gr) = 0);
    { BigValues=1 (pair [1,1]), table_select[0]=1 → 5 bits }
    Gr.BigValues        := 1;
    Gr.TableSelect[0]   := 1;
    Gr.Ix[0] := 1; Gr.Ix[1] := 1;
    Check('HB02 pair(1,1) t1 → 5 bits', FrameHuffmanBits(Gr) = 5);
    { BigValues=1, pair [0,0], table=1 → 1 bit }
    Gr.Ix[0] := 0; Gr.Ix[1] := 0;
    Check('HB03 pair(0,0) t1 → 1 bit', FrameHuffmanBits(Gr) = 1);
    { Count1=1 quad (1,0,1,0), table 32: p=1+0+4+0=5, CT32L[5]=6, +2 signs → 8 }
    Gr := MakeGr(210);
    Gr.Count1            := 1;
    Gr.Count1TableSelect := 0;  { table 32 }
    Gr.Ix[0] := 1; Gr.Ix[1] := 0; Gr.Ix[2] := 1; Gr.Ix[3] := 0;
    Check('HB04 quad(1,0,1,0) t32 → 8 bits', FrameHuffmanBits(Gr) = 8);
    { negative sign doesn't change count — sign is 1 extra bit already included }
    Gr.Ix[0] := -1;
    Check('HB05 quad(-1,0,1,0) same 8 bits', FrameHuffmanBits(Gr) = 8);
    { Two big-values pairs, both (1,1) with t1: 5+5=10 bits }
    Gr := MakeGr(210);
    Gr.BigValues := 2;
    Gr.TableSelect[0] := 1;
    Gr.Ix[0] := 1; Gr.Ix[1] := 1;
    Gr.Ix[2] := 1; Gr.Ix[3] := 1;
    Check('HB06 two pairs(1,1) t1 → 10 bits', FrameHuffmanBits(Gr) = 10);

    { -------- HW: FrameWriteHuffman actual bits -------- }
    WriteLn;
    WriteLn('--- FrameWriteHuffman ---');
    Gr := MakeGr(210);
    Gr.BigValues := 1;
    Gr.TableSelect[0] := 1;
    Gr.Ix[0] := 1; Gr.Ix[1] := 1;
    BW.Reset;
    FrameWriteHuffman(BW, Gr);
    Check('HW01 pair(1,1) t1 writes 5 bits', BW.GetBitCount = 5);
    { Verify actual code: HuffEncodePair(1,1,1,0,0) = Code=0, Len=5
      5 bits with Code=0: byte0 = 00000xxx → top 5 bits = 00000 }
    Check('HW02 pair(1,1,0,0) code=0 → byte0=0x00', BW_Byte(BW, 0) = $00);
    { pair(1,0) neg x: sign_x=1; HuffEncodePair(1,1,0,1,0)=Code=3,Len=4
      bits: 0011xxxx → byte0=0x30 }
    Gr.Ix[0] := -1; Gr.Ix[1] := 0;
    BW.Reset;
    FrameWriteHuffman(BW, Gr);
    Check('HW03 pair(-1,0) t1 writes 4 bits', BW.GetBitCount = 4);
    Check('HW04 pair(-1,0) code=3 → byte0=0x30', BW_Byte(BW, 0) = $30);
    { Count1 quad (0,0,0,0) table32: CT32C[0]=1, len=1; no signs → code=1, byte0=10000000=0x80 }
    Gr := MakeGr(210);
    Gr.Count1 := 1;
    BW.Reset;
    FrameWriteHuffman(BW, Gr);
    Check('HW05 quad(0,0,0,0) t32 writes 1 bit', BW.GetBitCount = 1);
    Check('HW06 quad(0,0,0,0) code=1 → byte0=0x80', BW_Byte(BW, 0) = $80);

    { -------- MD: FrameWriteMainData bit budget -------- }
    WriteLn;
    WriteLn('--- FrameWriteMainData ---');
    { Mono, 2 granules, all-zero Ix, compress=0 → 0 scalefac + 0 huff = 0 bits }
    FillChar(SI, SizeOf(SI), 0);
    Cfg := MakeCfgMono;
    BW.Reset;
    FrameWriteMainData(BW, Cfg, SI);
    Check('MD01 all-zero mono → 0 main data bits', BW.GetBitCount = 0);
    { compress=5 (slen1=1,slen2=1), gr0 + gr1 scfsi=0 → 21+21=42 bits scalefac }
    FillChar(SI, SizeOf(SI), 0);
    SI.Gr[0][0].ScalefacCompress := 5;
    SI.Gr[1][0].ScalefacCompress := 5;
    BW.Reset;
    FrameWriteMainData(BW, Cfg, SI);
    Check('MD02 compress=5 mono 2gr → 42 scalefac bits', BW.GetBitCount = 42);
    { BigValues=1 pair(1,1) t1 for both granules: 5+5=10 huff + 42 scalefac = 52 }
    SI.Gr[0][0].BigValues := 1; SI.Gr[0][0].TableSelect[0] := 1;
    SI.Gr[0][0].Ix[0] := 1; SI.Gr[0][0].Ix[1] := 1;
    SI.Gr[1][0].BigValues := 1; SI.Gr[1][0].TableSelect[0] := 1;
    SI.Gr[1][0].Ix[0] := 1; SI.Gr[1][0].Ix[1] := 1;
    BW.Reset;
    FrameWriteMainData(BW, Cfg, SI);
    Check('MD03 compress=5+pair(1,1) 2gr → 52 bits', BW.GetBitCount = 52);
    { Stereo: same scalefac per channel per granule: 4 × 21 = 84 scalefac bits }
    Cfg := MakeCfgStereo;
    FillChar(SI, SizeOf(SI), 0);
    SI.Gr[0][0].ScalefacCompress := 5;
    SI.Gr[0][1].ScalefacCompress := 5;
    SI.Gr[1][0].ScalefacCompress := 5;
    SI.Gr[1][1].ScalefacCompress := 5;
    BW.Reset;
    FrameWriteMainData(BW, Cfg, SI);
    Check('MD04 compress=5 stereo 2gr → 84 scalefac bits', BW.GetBitCount = 84);
    { scfsi band0=1 for both channels → gr1 skips 6 bits per channel →
      gr0 ch0=21, gr0 ch1=21, gr1 ch0=15, gr1 ch1=15 = 72 bits }
    SI.Scfsi[0][0] := 1;
    SI.Scfsi[1][0] := 1;
    BW.Reset;
    FrameWriteMainData(BW, Cfg, SI);
    Check('MD05 scfsi[ch][0]=1 stereo → 72 bits', BW.GetBitCount = 72);
    { FrameScalefacBits + FrameHuffmanBits match actual written bits, gr0 mono }
    Cfg := MakeCfgMono;
    FillChar(SI, SizeOf(SI), 0);
    FillChar(Scfsi, SizeOf(Scfsi), 0);
    SI.Gr[0][0].ScalefacCompress := 9;
    SI.Gr[0][0].BigValues := 1;
    SI.Gr[0][0].TableSelect[0] := 1;
    SI.Gr[0][0].Ix[0] := 1; SI.Gr[0][0].Ix[1] := 1;
    Bits := FrameScalefacBits(SI.Gr[0][0], 0, Scfsi)
          + FrameHuffmanBits(SI.Gr[0][0]);
    BW.Reset;
    FrameWriteScalefacs(BW, SI.Gr[0][0], 0, Scfsi);
    FrameWriteHuffman(BW, SI.Gr[0][0]);
    Check('MD06 scalefacBits+huffBits = actual bits written',
          BW.GetBitCount = Bits);

    WriteLn;
    WriteLn(Format('=== %d / %d passed ===', [GPassed, GTotal]));
    if GPassed < GTotal then
      ExitCode := 1;

  finally
    BW.Free;
  end;
end.
