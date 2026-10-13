program TestMP3EncPhase4;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  MP3EncHuffman;

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

begin
  HuffInit;
  WriteLn('=== MP3EncHuffman Phase 4 ===');

  { -------- LB: HuffLinBits -------- }
  WriteLn;
  WriteLn('--- HuffLinBits ---');
  Check('LB01 table 0  linbits=0',  HuffLinBits(0)  = 0);
  Check('LB02 table 15 linbits=0',  HuffLinBits(15) = 0);
  Check('LB03 table 16 linbits=1',  HuffLinBits(16) = 1);
  Check('LB04 table 17 linbits=2',  HuffLinBits(17) = 2);
  Check('LB05 table 23 linbits=13', HuffLinBits(23) = 13);
  Check('LB06 table 24 linbits=4',  HuffLinBits(24) = 4);
  Check('LB07 table 31 linbits=13', HuffLinBits(31) = 13);
  Check('LB08 table 32 linbits=0',  HuffLinBits(32) = 0);

  { -------- CP: HuffCountPairBits — table 0 -------- }
  WriteLn;
  WriteLn('--- HuffCountPairBits table 0 ---');
  Check('CP01 t0 (0,0)=0',          HuffCountPairBits(0, 0, 0) = 0);
  Check('CP02 t0 (1,0)=INVALID',    HuffCountPairBits(0, 1, 0) = HUFF_INVALID);

  { -------- CP: table 1 (xlen=2, ylen=2) -------- }
  WriteLn;
  WriteLn('--- HuffCountPairBits table 1 ---');
  { (0,0): len=1, no signs → 1 bit }
  Check('CP03 t1 (0,0)=1',          HuffCountPairBits(1, 0, 0) = 1);
  { (1,0): len=3, +sign_x → 3+1=4 }
  Check('CP04 t1 (1,0)=4',          HuffCountPairBits(1, 1, 0) = 4);
  { (0,1): len=3, +sign_y → 4 }
  Check('CP05 t1 (0,1)=4',          HuffCountPairBits(1, 0, 1) = 4);
  { (1,1): len=3, +sign_x +sign_y → 5 }
  Check('CP06 t1 (1,1)=5',          HuffCountPairBits(1, 1, 1) = 5);
  { out of range for table 1 (xlen=2) }
  Check('CP07 t1 (2,0)=INVALID',    HuffCountPairBits(1, 2, 0) = HUFF_INVALID);

  { -------- CP: table 5 (xlen=4) -------- }
  WriteLn;
  WriteLn('--- HuffCountPairBits table 5 ---');
  { (0,0): CT5L[0]=1 → 1 }
  Check('CP08 t5 (0,0)=1',          HuffCountPairBits(5, 0, 0) = 1);
  { (3,3): CT5L[15]=8, +2 signs → 10 }
  Check('CP09 t5 (3,3)=10',         HuffCountPairBits(5, 3, 3) = 10);
  { out of range for table 5 (xlen=4) }
  Check('CP10 t5 (4,0)=INVALID',    HuffCountPairBits(5, 4, 0) = HUFF_INVALID);

  { -------- CP: ESC table 16 -------- }
  WriteLn;
  WriteLn('--- HuffCountPairBits table 16 ---');
  { (0,0): CT16L[0]=1, no signs → 1 }
  Check('CP11 t16 (0,0)=1',         HuffCountPairBits(16, 0, 0) = 1);
  { (1,0): CT16L[1*16+0]=CT16L[16]=3, +sign_x → 4 }
  Check('CP12 t16 (1,0)=4',         HuffCountPairBits(16, 1, 0) = 4);
  { (15,0): CT16L[15*16+0]=CT16L[240]=9, linbits(1)+sign → 9+1+1=11 }
  Check('CP13 t16 (15,0)=11',       HuffCountPairBits(16, 15, 0) = 11);
  { (16,0): clamp x→15, lbx=1; CT16L[240]=9, linbits(1)+sign+no_y_sign → 9+1+1=11 }
  Check('CP14 t16 (16,0)=11',       HuffCountPairBits(16, 16, 0) = 11);

  { -------- EP: HuffEncodePair -------- }
  WriteLn;
  WriteLn('--- HuffEncodePair ---');
  { Table 0 → Code=0, Len=0 }
  Check('EP01 t0 (0,0,0,0) Len=0',
        HuffEncodePair(0, 0, 0, 0, 0).Len = 0);

  { Table 1, (0,0): CT1C[0]=1, len=1; no signs → Code=1, Len=1 }
  Check('EP02 t1 (0,0,0,0) Code=1', HuffEncodePair(1, 0, 0, 0, 0).Code = 1);
  Check('EP03 t1 (0,0,0,0) Len=1',  HuffEncodePair(1, 0, 0, 0, 0).Len  = 1);

  { Table 1, (1,0): CT1C[1]=1, len=3; code << 1 | sign_x=0 → 2, Len=4 }
  Check('EP04 t1 (1,0,0,0) Code=2', HuffEncodePair(1, 1, 0, 0, 0).Code = 2);
  Check('EP05 t1 (1,0,0,0) Len=4',  HuffEncodePair(1, 1, 0, 0, 0).Len  = 4);

  { Table 1, (1,0) neg x: code<<1 | sign_x=1 → 3, Len=4 }
  Check('EP06 t1 (1,0,1,0) Code=3', HuffEncodePair(1, 1, 0, 1, 0).Code = 3);

  { Table 1, (1,1): CT1C[3]=0, len=3; code<<1|sx=0 → 0; <<1|sy=0 → 0, Len=5 }
  Check('EP07 t1 (1,1,0,0) Code=0', HuffEncodePair(1, 1, 1, 0, 0).Code = 0);
  Check('EP08 t1 (1,1,0,0) Len=5',  HuffEncodePair(1, 1, 1, 0, 0).Len  = 5);

  { Table 1, out of range → INVALID }
  Check('EP09 t1 (2,0) INVALID',    HuffEncodePair(1, 2, 0, 0, 0).Len = HUFF_INVALID);

  { -------- CQ: HuffCountQuadBits -------- }
  WriteLn;
  WriteLn('--- HuffCountQuadBits ---');
  { Table 32, (0,0,0,0): p=0, CT32L[0]=1 → 1 }
  Check('CQ01 t32 (0,0,0,0)=1',     HuffCountQuadBits(32, 0, 0, 0, 0) = 1);
  { Table 32, (1,0,0,0): p=1, CT32L[1]=4, +sign_v → 5 }
  Check('CQ02 t32 (1,0,0,0)=5',     HuffCountQuadBits(32, 1, 0, 0, 0) = 5);
  { Table 32, (0,1,0,0): p=2, CT32L[2]=4, +sign_w → 5 }
  Check('CQ03 t32 (0,1,0,0)=5',     HuffCountQuadBits(32, 0, 1, 0, 0) = 5);
  { Table 32, (1,1,1,1): p=15, CT32L[15]=6, +4 signs → 10 }
  Check('CQ04 t32 (1,1,1,1)=10',    HuffCountQuadBits(32, 1, 1, 1, 1) = 10);
  { Table 33, (0,0,0,0): CT33L[0]=4 → 4 }
  Check('CQ05 t33 (0,0,0,0)=4',     HuffCountQuadBits(33, 0, 0, 0, 0) = 4);
  { Table 33, (1,1,1,1): CT33L[15]=4, +4 signs → 8 }
  Check('CQ06 t33 (1,1,1,1)=8',     HuffCountQuadBits(33, 1, 1, 1, 1) = 8);
  { Invalid table }
  Check('CQ07 t31 quad=INVALID',     HuffCountQuadBits(31, 0, 0, 0, 0) = HUFF_INVALID);

  { -------- EQ: HuffEncodeQuad -------- }
  WriteLn;
  WriteLn('--- HuffEncodeQuad ---');
  { Table 32, (0,0,0,0): CT32C[0]=1, len=1; no signs → Code=1, Len=1 }
  Check('EQ01 t32 (0,0,0,0) Code=1', HuffEncodeQuad(32,0,0,0,0,0,0,0,0).Code=1);
  Check('EQ02 t32 (0,0,0,0) Len=1',  HuffEncodeQuad(32,0,0,0,0,0,0,0,0).Len =1);
  { Table 33, (1,1,1,1) signs (1,0,1,0):
    CT33C[15]=0, len=4; ext=(1<<1|0)<<1|1 << 1|0 = pack: v=1,w=0,x=1,y=0
    ext = 1<<1=2; w=1 so ext=(2<<1)|0=4; x=1 so ext=(4<<1)|1=9; y=1 so ext=(9<<1)|0=18
    code=0<<4|18=18, len=4+4=8 }
  Check('EQ03 t33 (1,1,1,1,1,0,1,0) Len=8',
        HuffEncodeQuad(33,1,1,1,1,1,0,1,0).Len = 8);

  { -------- RB: HuffCountRegionBits -------- }
  WriteLn;
  WriteLn('--- HuffCountRegionBits ---');
  { Table 1, pairs [1,1]: HuffCountPairBits(1,1,1)=5 → total 5 }
  Check('RB01 t1 [1,1] bits=5',
        HuffCountRegionBits(1, 0, 2, [1, 1]) = 5);
  { Table 1, pairs [0,0,1,0]: (0,0)=1 + (1,0)=4 → 5 }
  Check('RB02 t1 [0,0,1,0] bits=5',
        HuffCountRegionBits(1, 0, 4, [0, 0, 1, 0]) = 5);
  { Table 0, all-zero → 0 }
  Check('RB03 t0 [0,0] bits=0',
        HuffCountRegionBits(0, 0, 2, [0, 0]) = 0);
  { Table 1, value 2 is out of range → INVALID }
  Check('RB04 t1 [2,0]=INVALID',
        HuffCountRegionBits(1, 0, 2, [2, 0]) = HUFF_INVALID);

  { -------- BT: HuffBestTable -------- }
  WriteLn;
  WriteLn('--- HuffBestTable ---');
  { All-zero region → table 0 }
  Check('BT01 [0,0] → t0',
        HuffBestTable(0, 2, [0, 0]) = 0);
  { [1,1] — table 3: CT3L[4]=2 + 2 signs = 4 bits (beats table 1's 5) }
  Check('BT02 [1,1] → t3',
        HuffBestTable(0, 2, [1, 1]) = 3);
  { [16,0] — needs ESC table: HuffBestTable only checks 0..15;
    table 16+ not checked, so any non-zero value in 0..15 or 0 expected.
    Values 0..15 all return INVALID for x=16, so result=0 }
  Check('BT03 [16,0] with no valid t0..15 → 0',
        HuffBestTable(0, 2, [16, 0]) = 0);

  WriteLn;
  WriteLn(Format('=== %d / %d passed ===', [GPassed, GTotal]));
  if GPassed < GTotal then
    ExitCode := 1;
end.
