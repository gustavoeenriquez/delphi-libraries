program TestMP3EncPhase6;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  MP3EncQuantize,
  MP3EncHuffman,
  MP3EncFrame,
  MP3EncRateCtrl;

var
  GPassed, GFailed: Integer;

procedure Check(const AName: string; ACondition: Boolean);
begin
  if ACondition then begin
    Inc(GPassed);
    WriteLn('  PASS  ', AName);
  end else begin
    Inc(GFailed);
    WriteLn('** FAIL  ', AName);
  end;
end;

function MakeIx(AIndex, AValue: Integer): T576Int;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result[AIndex] := AValue;
end;

// -- BV: RateCtrlBigValues ---------------------------------------------------

procedure TestBigValues;
var
  Ix: T576Int;
begin
  WriteLn('BV: RateCtrlBigValues');

  FillChar(Ix, SizeOf(Ix), 0);
  Check('BV01 all-zero  -> 0',    RateCtrlBigValues(Ix) = 0);

  Ix := MakeIx(0, 1);
  Check('BV02 Ix[0]=1  -> 1',     RateCtrlBigValues(Ix) = 1);  // 0 div 2 + 1

  Ix := MakeIx(1, 2);
  Check('BV03 Ix[1]=2  -> 1',     RateCtrlBigValues(Ix) = 1);  // 1 div 2 + 1

  Ix := MakeIx(4, 3);
  Check('BV04 Ix[4]=3  -> 3',     RateCtrlBigValues(Ix) = 3);  // 4 div 2 + 1

  Ix := MakeIx(575, 1);
  Check('BV05 Ix[575]=1 -> 288',  RateCtrlBigValues(Ix) = 288); // 575 div 2 + 1

  Ix := MakeIx(3, -5);
  Check('BV06 Ix[3]=-5 -> 2',     RateCtrlBigValues(Ix) = 2);  // 3 div 2 + 1

  // Two non-zero; last (highest index) is i=5
  FillChar(Ix, SizeOf(Ix), 0);
  Ix[3] := 7; Ix[5] := 1;
  Check('BV07 last at i=5 -> 3',  RateCtrlBigValues(Ix) = 3);  // 5 div 2 + 1
end;

// -- C1: RateCtrlCount1 ------------------------------------------------------

procedure TestCount1;
var
  Ix: T576Int;
begin
  WriteLn('C1: RateCtrlCount1');

  FillChar(Ix, SizeOf(Ix), 0);
  Check('C1_01 all-zero bigEnd=0 -> 0', RateCtrlCount1(Ix, 0) = 0);

  // Valid quad [1,-1,0,1] then all-zero -> 1
  FillChar(Ix, SizeOf(Ix), 0);
  Ix[0] := 1; Ix[1] := -1; Ix[2] := 0; Ix[3] := 1;
  Check('C1_02 one valid quad -> 1', RateCtrlCount1(Ix, 0) = 1);

  // Two valid quads then all-zero -> 2
  FillChar(Ix, SizeOf(Ix), 0);
  Ix[0] := 1; Ix[1] := 0; Ix[2] := -1; Ix[3] := 1;
  Ix[4] := 0; Ix[5] := 1; Ix[6] := -1; Ix[7] := 0;
  Check('C1_03 two valid quads -> 2', RateCtrlCount1(Ix, 0) = 2);

  // Stop at |v|>1 after first quad
  FillChar(Ix, SizeOf(Ix), 0);
  Ix[0] := 1; Ix[1] := 0; Ix[2] := -1; Ix[3] := 1;
  Ix[4] := 2; Ix[5] := 0; Ix[6] := 0;  Ix[7] := 0;
  Check('C1_04 stop at |v|>1 -> 1', RateCtrlCount1(Ix, 0) = 1);

  // bigEnd=4: count starts from index 4
  FillChar(Ix, SizeOf(Ix), 0);
  Ix[4] := 1; Ix[5] := -1; Ix[6] := 0; Ix[7] := 1;
  Check('C1_05 bigEnd=4 one valid quad -> 1', RateCtrlCount1(Ix, 4) = 1);
end;

// -- CT: RateCtrlCount1Table -------------------------------------------------

procedure TestCount1Table;
var
  Ix: T576Int;
  r: Byte;
begin
  WriteLn('CT: RateCtrlCount1Table');

  FillChar(Ix, SizeOf(Ix), 0);
  // count1=0: no bits compared, bitsA=bitsB=0 -> A wins (0)
  Check('CT01 count1=0 -> 0', RateCtrlCount1Table(Ix, 0, 0) = 0);

  // Any input with count1=1: result must be 0 or 1
  Ix[0] := 1; Ix[1] := 1; Ix[2] := 0; Ix[3] := 1;
  r := RateCtrlCount1Table(Ix, 0, 1);
  Check('CT02 count1=1 result in {0,1}', r <= 1);

  // All-ones quad: check result in range
  FillChar(Ix, SizeOf(Ix), 0);
  Ix[0] := 1; Ix[1] := 1; Ix[2] := 1; Ix[3] := 1;
  r := RateCtrlCount1Table(Ix, 0, 1);
  Check('CT03 all-ones quad result in {0,1}', r <= 1);
end;

// -- TB: RateCtrlBestTable ---------------------------------------------------

procedure TestBestTable;
var
  Ix: T576Int;
begin
  WriteLn('TB: RateCtrlBestTable');

  FillChar(Ix, SizeOf(Ix), 0);
  Check('TB01 empty range -> 0',      RateCtrlBestTable(Ix, 0, 0) = 0);
  Check('TB02 all-zero pairs -> 0',   RateCtrlBestTable(Ix, 0, 4) = 0);

  FillChar(Ix, SizeOf(Ix), 0);
  Ix[0] := 1; Ix[1] := 1;
  Check('TB03 [1,1] -> 3',            RateCtrlBestTable(Ix, 0, 2) = 3);

  FillChar(Ix, SizeOf(Ix), 0);
  Ix[0] := 5; Ix[1] := 3;
  Check('TB04 [5,3] result 0..31',    RateCtrlBestTable(Ix, 0, 2) <= 31);

  FillChar(Ix, SizeOf(Ix), 0);
  Ix[0] := 0; Ix[1] := 1;
  Check('TB05 [0,1] result 0..31',    RateCtrlBestTable(Ix, 0, 2) <= 31);
end;

// -- FP: RateCtrlFillParams --------------------------------------------------

procedure TestFillParams;
var
  Ix: T576Int;
  P: TRCtrlParams;
begin
  WriteLn('FP: RateCtrlFillParams');

  FillChar(Ix, SizeOf(Ix), 0);
  RateCtrlFillParams(Ix, 0, P);
  Check('FP01 all-zero BigValues=0',  P.BigValues = 0);
  Check('FP02 all-zero Count1=0',     P.Count1 = 0);
  Check('FP03 Region0Count=10',       P.Region0Count = RC_REGION0_COUNT);
  Check('FP04 Region1Count=3',        P.Region1Count = RC_REGION1_COUNT);
  Check('FP05 SrIdx=0 stored',        P.SrIdx = 0);

  // Non-zero Ix: Ix[4]=3, Ix[5]=2  -> BigValues = 5 div 2 + 1 = 3
  FillChar(Ix, SizeOf(Ix), 0);
  Ix[4] := 3; Ix[5] := 2;
  RateCtrlFillParams(Ix, 0, P);
  Check('FP06 BigValues matches helper', P.BigValues = RateCtrlBigValues(Ix));
  Check('FP07 TableSelect[0] 0..31',    P.TableSelect[0] <= 31);
  RateCtrlFillParams(Ix, 1, P);
  Check('FP08 SrIdx=1 stored',          P.SrIdx = 1);
end;

// -- HB: RateCtrlHuffBits ----------------------------------------------------

procedure TestHuffBits;
var
  Ix: T576Int;
  P: TRCtrlParams;
begin
  WriteLn('HB: RateCtrlHuffBits');

  FillChar(Ix, SizeOf(Ix), 0);
  RateCtrlFillParams(Ix, 0, P);
  Check('HB01 all-zero -> 0 bits', RateCtrlHuffBits(Ix, P) = 0);

  FillChar(Ix, SizeOf(Ix), 0);
  Ix[0] := 1; Ix[1] := 1;
  RateCtrlFillParams(Ix, 0, P);
  Check('HB02 [1,1] bits > 0', RateCtrlHuffBits(Ix, P) > 0);

  FillChar(Ix, SizeOf(Ix), 0);
  Ix[0] := 3; Ix[1] := 2; Ix[2] := 1; Ix[3] := 0;
  RateCtrlFillParams(Ix, 0, P);
  Check('HB03 non-trivial bits >= 0', RateCtrlHuffBits(Ix, P) >= 0);
end;

// -- FG: RateCtrlFindGain ----------------------------------------------------

procedure TestFindGain;
var
  QState : TQuantState;
  Xr     : T576;
  Ix     : T576Int;
  P      : TRCtrlParams;
  SfL    : TScalefacL;
  gain, bits: Integer;
begin
  WriteLn('FG: RateCtrlFindGain');

  QuantInit(QState);
  FillChar(SfL, SizeOf(SfL), 0);

  // All-zero Xr: any gain gives 0 bits -> finds minimum gain = 0
  FillChar(Xr, SizeOf(Xr), 0);
  gain := RateCtrlFindGain(QState, Xr, 1000, SfL, 0, 0, 0, Ix, P);
  Check('FG01 all-zero gain in 0..255', (gain >= 0) and (gain <= 255));
  bits := RateCtrlHuffBits(Ix, P);
  Check('FG02 all-zero bits <= 1000', bits <= 1000);

  // Zero budget + all-zero Xr: bits=0 for any gain -> finds gain=0
  gain := RateCtrlFindGain(QState, Xr, 0, SfL, 0, 0, 0, Ix, P);
  Check('FG03 zero budget all-zero -> gain=0', gain = 0);

  // Non-zero Xr: result bits <= targetBits
  FillChar(Xr, SizeOf(Xr), 0);
  Xr[0] := 100.0; Xr[1] := 50.0; Xr[2] := 25.0;
  gain := RateCtrlFindGain(QState, Xr, 500, SfL, 0, 0, 0, Ix, P);
  bits := RateCtrlHuffBits(Ix, P);
  Check('FG04 non-zero bits <= 500', bits <= 500);

  // Large budget -> gain in valid range
  FillChar(Xr, SizeOf(Xr), 0);
  Xr[0] := 1.0; Xr[1] := 0.5;
  gain := RateCtrlFindGain(QState, Xr, 10000, SfL, 0, 0, 0, Ix, P);
  Check('FG05 large budget gain in range', (gain >= 0) and (gain <= 255));

  // Params out are consistent: BigValues >= 0
  Check('FG06 params BigValues >= 0', P.BigValues >= 0);
end;

var
  T0: TDateTime;
begin
  HuffInit;
  T0 := Now;
  WriteLn('=== TestMP3EncPhase6 ===');
  WriteLn;
  TestBigValues;
  WriteLn;
  TestCount1;
  WriteLn;
  TestCount1Table;
  WriteLn;
  TestBestTable;
  WriteLn;
  TestFillParams;
  WriteLn;
  TestHuffBits;
  WriteLn;
  TestFindGain;
  WriteLn;
  WriteLn(Format('Total: %d/%d passed  (%.0f ms)',
    [GPassed, GPassed + GFailed, (Now - T0) * 86400000]));
  if GFailed = 0 then WriteLn('ALL PASSED')
  else             WriteLn(Format('%d FAILED', [GFailed]));
  ExitCode := GFailed;
end.
