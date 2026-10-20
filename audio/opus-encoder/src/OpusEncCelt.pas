unit OpusEncCelt;

{
  OpusEncCelt.pas - CELT encoder (Opus Phase 2)

  Implements the CELT (Constrained Energy Lapped Transform) encoder:
    - Forward MDCT (analysis transform, exact inverse of decoder IMDCT)
    - Per-band energy computation and log-domain quantization
    - Coarse energy coding via Laplace distribution
    - Bit allocation using libopus allocation vectors
    - PVQ (Pyramid Vector Quantization) per band
    - Fine energy refinement

  Reference: RFC 6716 §4.3, libopus celt/ (MIT license)
  Tables ported from libopus (xiph/opus), Copyright (c) 2007-2009 Xiph.Org
  Foundation. Used under MIT license.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

{$POINTERMATH ON}

interface

uses
  SysUtils, Math,
  OpusTypes,
  OpusEncTypes,
  OpusRangeEncoder;

const
  CELT_ENC_BANDS  = 21;
  CELT_ENC_EBANDS : array[0..21] of Integer = (
    0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 34, 40, 48, 60, 78, 100);
  CELT_ENC_OVERLAP = 120;

type
  TCeltEncState = record
    PrevLogE_dB : array[0..CELT_ENC_BANDS-1] of Single; // previous log energy in dB
    OverlapBuf  : TArray<Single>;   // previous FrameSize/2 samples
    FrameSize   : Integer;  // samples (120, 240, 480, 960)
    LM          : Integer;  // frame index: 0=2.5ms..3=20ms
    Channels    : Integer;
    FirstFrame  : Boolean;
  end;

procedure CeltEncStateInit(var S: TCeltEncState; Channels, LM: Integer);

// Encode one CELT frame. PCM = Channels×FrameSize interleaved int16 samples.
// Budget: available bits in the range encoder. Returns False on error.
function CeltEncodeFrame(
  var S      : TCeltEncState;
  PCM        : PSmallInt;
  var Re     : TOpusRangeEncoder;
  Budget     : Integer
): Boolean;

// Exposed for unit tests
function  CeltPVQU(N, K: Integer): UInt32;
function  CeltPVQV(N, K: Integer): UInt32;
function  CeltIcwrs(N: Integer; const Y: array of Integer): UInt32;
procedure CeltEncodePulses(const Y: array of Integer; N, K: Integer; var Re: TOpusRangeEncoder);
procedure CeltForwardMDCT(const PrevM, CurrM: PSingle; M, Overlap: Integer; Output: PSingle);
procedure CeltAllocBits(Budget, NBands, LM: Integer; out Pulses, EBits: TArray<Integer>);
procedure CeltPVQSearch(X: PSingle; N, K: Integer; out IY: TArray<Integer>);
procedure CeltComputeBandEnergy(const X: PSingle; M, LM, NBands: Integer; out BandE: TArray<Single>);

implementation

// ---------------------------------------------------------------------------
// PVQ combinatorics table (from libopus celt/cwrs.c, MIT license)
// U(N,K) — accessed via CELT_PVQ_U(N,K) = DATA[ROW[min(N,K)] + max(N,K)]
// ---------------------------------------------------------------------------

const
  CELT_PVQ_U_DATA: array[0..1271] of UInt32 = (
    // N=0, K=0..176
    1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    // N=1, K=1..176
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    // N=2, K=2..176
    3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47,49,51,53,
    55,57,59,61,63,65,67,69,71,73,75,77,79,81,83,85,87,89,91,93,95,97,99,101,
    103,105,107,109,111,113,115,117,119,121,123,125,127,129,131,133,135,137,
    139,141,143,145,147,149,151,153,155,157,159,161,163,165,167,169,171,173,
    175,177,179,181,183,185,187,189,191,193,195,197,199,201,203,205,207,209,
    211,213,215,217,219,221,223,225,227,229,231,233,235,237,239,241,243,245,
    247,249,251,253,255,257,259,261,263,265,267,269,271,273,275,277,279,281,
    283,285,287,289,291,293,295,297,299,301,303,305,307,309,311,313,315,317,
    319,321,323,325,327,329,331,333,335,337,339,341,343,345,347,349,351,
    // N=3, K=3..176
    13,25,41,61,85,113,145,181,221,265,313,365,421,481,545,613,685,761,841,
    925,1013,1105,1201,1301,1405,1513,1625,1741,1861,1985,2113,2245,2381,2521,
    2665,2813,2965,3121,3281,3445,3613,3785,3961,4141,4325,4513,4705,4901,
    5101,5305,5513,5725,5941,6161,6385,6613,6845,7081,7321,7565,7813,8065,
    8321,8581,8845,9113,9385,9661,9941,10225,10513,10805,11101,11401,11705,
    12013,12325,12641,12961,13285,13613,13945,14281,14621,14965,15313,15665,
    16021,16381,16745,17113,17485,17861,18241,18625,19013,19405,19801,20201,
    20605,21013,21425,21841,22261,22685,23113,23545,23981,24421,24865,25313,
    25765,26221,26681,27145,27613,28085,28561,29041,29525,30013,30505,31001,
    31501,32005,32513,33025,33541,34061,34585,35113,35645,36181,36721,37265,
    37813,38365,38921,39481,40045,40613,41185,41761,42341,42925,43513,44105,
    44701,45301,45905,46513,47125,47741,48361,48985,49613,50245,50881,51521,
    52165,52813,53465,54121,54781,55445,56113,56785,57461,58141,58825,59513,
    60205,60901,61601,
    // N=4, K=4..176
    63,129,231,377,575,833,1159,1561,2047,2625,3303,4089,4991,6017,7175,8473,
    9919,11521,13287,15225,17343,19649,22151,24857,27775,30913,34279,37881,
    41727,45825,50183,54809,59711,64897,70375,76153,82239,88641,95367,102425,
    109823,117569,125671,134137,142975,152193,161799,171801,182207,193025,
    204263,215929,228031,240577,253575,267033,280959,295361,310247,325625,
    341503,357889,374791,392217,410175,428673,447719,467321,487487,508225,
    529543,551449,573951,597057,620775,645113,670079,695681,721927,748825,
    776383,804609,833511,863097,893375,924353,956039,988441,1021567,1055425,
    1090023,1125369,1161471,1198337,1235975,1274393,1313599,1353601,1394407,
    1436025,1478463,1521729,1565831,1610777,1656575,1703233,1750759,1799161,
    1848447,1898625,1949703,2001689,2054591,2108417,2163175,2218873,2275519,
    2333121,2391687,2451225,2511743,2573249,2635751,2699257,2763775,2829313,
    2895879,2963481,3032127,3101825,3172583,3244409,3317311,3391297,3466375,
    3542553,3619839,3698241,3777767,3858425,3940223,4023169,4107271,4192537,
    4278975,4366593,4455399,4545401,4636607,4729025,4822663,4917529,5013631,
    5110977,5209575,5309433,5410559,5512961,5616647,5721625,5827903,5935489,
    6044391,6154617,6266175,6379073,6493319,6608921,6725887,6844225,6963943,
    7085049,7207551,
    // N=5, K=5..176
    321,681,1289,2241,3649,5641,8361,11969,16641,22569,29961,39041,50049,
    63241,78889,97281,118721,143529,172041,204609,241601,283401,330409,383041,
    441729,506921,579081,658689,746241,842249,947241,1061761,1186369,1321641,
    1468169,1626561,1797441,1981449,2179241,2391489,2618881,2862121,3121929,
    3399041,3694209,4008201,4341801,4695809,5071041,5468329,5888521,6332481,
    6801089,7295241,7815849,8363841,8940161,9545769,10181641,10848769,
    11548161,12280841,13047849,13850241,14689089,15565481,16480521,17435329,
    18431041,19468809,20549801,21675201,22846209,24064041,25329929,26645121,
    28010881,29428489,30899241,32424449,34005441,35643561,37340169,39096641,
    40914369,42794761,44739241,46749249,48826241,50971689,53187081,55473921,
    57833729,60268041,62778409,65366401,68033601,70781609,73612041,76526529,
    79526721,82614281,85790889,89058241,92418049,95872041,99421961,103069569,
    106816641,110664969,114616361,118672641,122835649,127107241,131489289,
    135983681,140592321,145317129,150160041,155123009,160208001,165417001,
    170752009,176215041,181808129,187533321,193392681,199388289,205522241,
    211796649,218213641,224775361,231483969,238341641,245350569,252512961,
    259831041,267307049,274943241,282741889,290705281,298835721,307135529,
    315607041,324252609,333074601,342075401,351257409,360623041,370174729,
    379914921,389846081,399970689,410291241,420810249,431530241,442453761,
    453583369,464921641,476471169,488234561,500214441,512413449,524834241,
    537479489,550351881,563454121,576788929,590359041,604167209,618216201,
    632508801,
    // N=6, K=6..96
    1683,3653,7183,13073,22363,36365,56695,85305,124515,177045,246047,335137,
    448427,590557,766727,982729,1244979,1560549,1937199,2383409,2908411,
    3522221,4235671,5060441,6009091,7095093,8332863,9737793,11326283,13115773,
    15124775,17372905,19880915,22670725,25765455,29189457,32968347,37129037,
    41699767,46710137,52191139,58175189,64696159,71789409,79491819,87841821,
    96879431,106646281,117185651,128542501,140763503,153897073,167993403,
    183104493,199284183,216588185,235074115,254801525,275831935,298228865,
    322057867,347386557,374284647,402823977,433078547,465124549,499040399,
    534906769,572806619,612825229,655050231,699571641,746481891,795875861,
    847850911,902506913,959946283,1020274013,1083597703,1150027593,1219676595,
    1292660325,1369097135,1449108145,1532817275,1620351277,1711839767,
    1807415257,1907213187,2011371957,2120032959,
    // N=7, K=7..54
    8989,19825,40081,75517,134245,227305,369305,579125,880685,1303777,1884961,
    2668525,3707509,5064793,6814249,9041957,11847485,15345233,19665841,
    24957661,31388293,39146185,48442297,59511829,72616013,88043969,106114625,
    127178701,151620757,179861305,212358985,249612805,292164445,340600625,
    395555537,457713341,527810725,606639529,695049433,793950709,904317037,
    1027188385,1163673953,1314955181,1482288821,1667010073,1870535785,
    2094367717,
    // N=8, K=8..37
    48639,108545,224143,433905,795455,1392065,2340495,3800305,5984767,9173505,
    13726991,20103025,28875327,40754369,56610575,77500017,104692735,139703809,
    184327311,240673265,311207743,398796225,506750351,638878193,799538175,
    993696769,1226990095,1505789553,1837271615,2229491905,
    // N=9, K=9..28
    265729,598417,1256465,2485825,4673345,8405905,14546705,24331777,39490049,
    62390545,96220561,145198913,214828609,312193553,446304145,628496897,
    872893441,1196924561,1621925137,2173806145,
    // N=10, K=10..24
    1462563,3317445,7059735,14218905,27298155,50250765,89129247,152951073,
    254831667,413442773,654862247,1014889769,1541911931,2300409629,3375210671,
    // N=11, K=11..19
    8097453,18474633,39753273,81270333,158819253,298199265,540279585,
    948062325,1616336765,
    // N=12, K=12..18
    45046719,103274625,224298231,464387817,921406335,1759885185,3248227095,
    // N=13, K=13..16
    251595969,579168825,1267854873,2653649025,
    // N=14, K=14
    1409933619
  );

  CELT_PVQ_U_ROW: array[0..14] of Integer = (
    0, 176, 351, 525, 698, 870, 1041, 1131, 1178, 1207, 1226, 1240, 1248, 1254, 1257);

// ---------------------------------------------------------------------------
// Energy quantization tables (from libopus celt/quant_bands.c, MIT license)
// ---------------------------------------------------------------------------

const
  // Mean log-energy per band (Q4 fixed, converted to float)
  CELT_EMEANS: array[0..24] of Single = (
    6.4375, 6.25, 5.75, 5.3125, 5.0625, 4.8125, 4.5, 4.375, 4.875, 4.6875,
    4.5625, 4.4375, 4.875, 4.625, 4.3125, 4.5, 4.375, 4.625, 4.75, 4.4375,
    3.75, 3.75, 3.75, 3.75, 3.75);

  // Inter-frame energy prediction coefficients (4 frame sizes)
  CELT_PRED_COEF: array[0..3] of Single = (
    29440/32768.0, 26112/32768.0, 21248/32768.0, 16384/32768.0);
  CELT_BETA_COEF: array[0..3] of Single = (
    30147/32768.0, 22282/32768.0, 12124/32768.0, 6554/32768.0);
  CELT_BETA_INTRA: Single = 4915/32768.0;

  // Laplace probability model for coarse energy [LM][intra/inter][band_pair]
  // e_prob_model[4][2][42] — from libopus celt/quant_bands.c
  CELT_E_PROB: array[0..3, 0..1, 0..41] of Byte = (
    (( 72,127, 65,129, 66,128, 65,128, 64,128, 62,128, 64,128, 64,128,
        92, 78, 92, 79, 92, 78, 90, 79,116, 41,115, 40,114, 40,132, 26,
       132, 26,145, 17,161, 12,176, 10,177, 11),
     ( 24,179, 48,138, 54,135, 54,132, 53,134, 56,133, 55,132, 55,132,
        61,114, 70, 96, 74, 88, 75, 88, 87, 74, 89, 66, 91, 67,100, 59,
       108, 50,120, 40,122, 37, 97, 43, 78, 50)),
    (( 83, 78, 84, 81, 88, 75, 86, 74, 87, 71, 90, 73, 93, 74, 93, 74,
       109, 40,114, 36,117, 34,117, 34,143, 17,145, 18,146, 19,162, 12,
       165, 10,178,  7,189,  6,190,  8,177,  9),
     ( 23,178, 54,115, 63,102, 66, 98, 69, 99, 74, 89, 71, 91, 73, 91,
        78, 89, 86, 80, 92, 66, 93, 64,102, 59,103, 60,104, 60,117, 52,
       123, 44,138, 35,133, 31, 97, 38, 77, 45)),
    (( 61, 90, 93, 60,105, 42,107, 41,110, 45,116, 38,113, 38,112, 38,
       124, 26,132, 27,136, 19,140, 20,155, 14,159, 16,158, 18,170, 13,
       177, 10,187,  8,192,  6,175,  9,159, 10),
     ( 21,178, 59,110, 71, 86, 75, 85, 84, 83, 91, 66, 88, 73, 87, 72,
        92, 75, 98, 72,105, 58,107, 54,115, 52,114, 55,112, 56,129, 51,
       132, 40,150, 33,140, 29, 98, 35, 77, 42)),
    (( 42,121, 96, 66,108, 43,111, 40,117, 44,123, 32,120, 36,119, 33,
       127, 33,134, 34,139, 21,147, 23,152, 20,158, 25,154, 26,166, 21,
       173, 16,184, 13,184, 10,150, 13,139, 15),
     ( 22,178, 63,114, 74, 82, 84, 83, 92, 82,103, 62, 96, 72, 96, 67,
       101, 73,107, 72,113, 55,118, 52,125, 52,118, 52,117, 55,135, 49,
       137, 39,157, 32,145, 29, 97, 33, 77, 40))
  );

  // Allocation vectors [nbAllocVectors=11][nbEBands=21]
  // From libopus celt/modes.c
  CELT_ALLOC_VECTORS: array[0..10, 0..20] of Byte = (
    ( 0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0),
    (90, 80, 75, 69, 63, 56, 49, 40, 34, 29, 20, 18, 10,  0,  0,  0,  0,  0,  0,  0,  0),
    (110,100, 90, 84, 78, 71, 65, 58, 51, 45, 39, 32, 26, 20, 12,  0,  0,  0,  0,  0,  0),
    (118,110,103, 93, 86, 80, 75, 70, 65, 59, 53, 47, 40, 31, 23, 15,  4,  0,  0,  0,  0),
    (126,119,112,104, 95, 89, 83, 78, 72, 66, 60, 54, 47, 39, 32, 25, 17, 12,  1,  0,  0),
    (134,127,120,114,103, 97, 91, 85, 78, 72, 66, 60, 54, 47, 41, 35, 29, 23, 16, 10,  1),
    (144,137,130,124,113,107,101, 95, 88, 82, 76, 70, 64, 57, 51, 45, 39, 33, 26, 15,  1),
    (152,145,138,132,123,117,111,105, 98, 92, 86, 80, 74, 67, 61, 55, 49, 43, 36, 20,  1),
    (162,155,148,142,133,127,121,115,108,102, 96, 90, 84, 77, 71, 65, 59, 53, 46, 30,  1),
    (172,165,158,152,143,137,131,125,118,112,106,100, 94, 87, 81, 75, 69, 63, 56, 45, 20),
    (200,200,200,200,200,200,200,200,198,193,188,183,178,173,168,163,158,153,148,129,104)
  );

  LAPLACE_LOG_MINP = 0;
  LAPLACE_MINP     = 1;
  LAPLACE_NMIN     = 16;

// ---------------------------------------------------------------------------
// PVQ combinatorics helpers
// ---------------------------------------------------------------------------

function CeltPVQU(N, K: Integer): UInt32;
var
  MinNK, MaxNK: Integer;
begin
  if (N < 0) or (K < 0) then Exit(0);
  MinNK := N; MaxNK := K;
  if K < N then begin MinNK := K; MaxNK := N; end;
  if MinNK > 14 then Exit(0);
  if MaxNK > 176 then Exit(0);
  Result := CELT_PVQ_U_DATA[CELT_PVQ_U_ROW[MinNK] + MaxNK];
end;

function CeltPVQV(N, K: Integer): UInt32;
begin
  Result := CeltPVQU(N, K) + CeltPVQU(N, K + 1);
end;

// Compute the rank of integer PVQ vector Y (length N, L1 norm K)
function CeltIcwrs(N: Integer; const Y: array of Integer): UInt32;
var
  I, J, K: Integer;
begin
  Assert(N >= 2);
  J := N - 1;
  Result := UInt32(Y[J] < 0);
  K := Abs(Y[J]);
  repeat
    Dec(J);
    Inc(Result, CeltPVQU(N - J, K));
    Inc(K, Abs(Y[J]));
    if Y[J] < 0 then
      Inc(Result, CeltPVQU(N - J, K + 1));
  until J = 0;
end;

procedure CeltEncodePulses(const Y: array of Integer; N, K: Integer; var Re: TOpusRangeEncoder);
var
  V: UInt32;
begin
  if K <= 0 then Exit;
  V := CeltPVQV(N, K);
  if V > 1 then
    ReEncodeUInt(Re, CeltIcwrs(N, Y), V);
end;

// ---------------------------------------------------------------------------
// Laplace encoder (from libopus celt/laplace.c, MIT license)
// ---------------------------------------------------------------------------

function CeltLaplaceGetFreq1(FS0, Decay: Cardinal): Cardinal;
var
  FT: Cardinal;
begin
  FT := 32768 - LAPLACE_MINP * (2 * LAPLACE_NMIN) - FS0;
  Result := Cardinal(Int64(FT) * (16384 - Decay) shr 15);
end;

procedure CeltLaplaceEncode(var Re: TOpusRangeEncoder; var Value: Integer; FS, Decay: Cardinal);
var
  FL   : Cardinal;
  Val  : Integer;
  S    : Integer;
  I    : Integer;
  CFS  : Cardinal;
begin
  FL := 0;
  Val := Value;
  if Val <> 0 then
  begin
    S := -Ord(Val < 0);
    Val := (Val + S) xor S;  // abs
    FL := FS;
    CFS := CeltLaplaceGetFreq1(FS, Decay);
    I := 1;
    while (CFS > 0) and (I < Val) do
    begin
      CFS := CFS * 2;
      FL  := FL + CFS + 2 * LAPLACE_MINP;
      CFS := Cardinal(Int64(CFS - 2 * LAPLACE_MINP) * Decay shr 15);
      Inc(I);
    end;
    if CFS = 0 then
    begin
      var NDIMax: Integer := (32768 - Integer(FL) + LAPLACE_MINP - 1) shr LAPLACE_LOG_MINP;
      NDIMax := (NDIMax - S) shr 1;
      var DI: Integer := Min(Val - I, NDIMax - 1);
      FL := FL + Cardinal(2 * DI + 1 + S) * LAPLACE_MINP;
      CFS := Min(LAPLACE_MINP, 32768 - FL);
      Value := (I + DI + S) xor S;
    end
    else
    begin
      CFS := CFS + LAPLACE_MINP;
      FL  := FL + CFS and not Cardinal(S);
    end;
  end;
  // Encode using the range encoder at 15-bit precision
  ReEncodeUInt(Re, FL shr 1, (FL + CFS + 1) shr 1);  // simplified uniform fallback
  // NOTE: A full implementation would use ec_encode_bin(enc, FL, FL+CFS, 15)
  // We approximate with a uniform encode over the [FL, FL+CFS) interval
end;

// ---------------------------------------------------------------------------
// Forward MDCT — exact inverse of CeltIMDCT in the decoder
// Derived by transposing the IMDCT algorithm.
//
// Input:  N = 2*M time-domain samples, windowed:
//           Combined = [windowed_prev_M | windowed_curr_M]
// Output: M = N/2 spectral coefficients
// ---------------------------------------------------------------------------

procedure CeltForwardMDCT(const PrevM, CurrM: PSingle; M, Overlap: Integer; Output: PSingle);
var
  N, N2, N4: Integer;
  K, J     : Integer;
  Br, Bi   : TArray<Double>;
  Cr, Ci   : TArray<Double>;
  Angle, cosA, sinA : Double;
  AK, BK, CK, DK   : Single; // input quadrant samples
  OverlapStart: Integer;
  W: Double;
begin
  N  := 2 * M;
  N2 := M;
  N4 := M div 2;
  if N4 = 0 then Exit;

  SetLength(Br, N4);
  SetLength(Bi, N4);
  SetLength(Cr, N4);
  SetLength(Ci, N4);

  // Step 1: Time-domain pre-rotate using all 4 quadrants of the N-sample window
  // Combined input: [PrevM(0..M-1) | CurrM(0..M-1)]
  // Quadrant layout (same as IMDCT output structure):
  //   Input[N4+K]       = PrevM[N4+K]        for K=0..N4-1  → quadrant 'a'
  //   Input[N4-1-K]     = PrevM[N4-1-K]      for K=0..N4-1  → quadrant 'b'
  //   Input[N4*3+K]     = CurrM[N4+K]        for K=0..N4-1  → quadrant 'c'
  //   Input[N-1-K-N4]   = CurrM[N4-1-K]      for K=0..N4-1  → quadrant 'd'
  // Analysis uses differences: (a-d) and (b-c)
  OverlapStart := M - Overlap;
  for K := 0 to N4 - 1 do
  begin
    Angle := Pi * (4.0 * K + 1) / (2.0 * N);
    cosA  := Cos(Angle);
    sinA  := Sin(Angle);

    // Read samples and apply analysis window to overlap regions
    var PrevIdx1 := N4 + K;       // in PrevM
    var PrevIdx2 := N4 - 1 - K;   // in PrevM
    var CurrIdx1 := N4 + K;       // in CurrM  (= PrevIdx1 - M = offset)
    var CurrIdx2 := N4 - 1 - K;   // in CurrM

    AK := PrevM[PrevIdx1];  DK := CurrM[CurrIdx2];
    BK := PrevM[PrevIdx2];  CK := CurrM[CurrIdx1];

    // Apply analysis window to overlap regions
    // Rising window on PrevM end (last Overlap samples):
    if PrevIdx1 >= OverlapStart then
    begin
      W := Sin(Pi * (PrevIdx1 - OverlapStart + 0.5) / Overlap);
      W := W * W;
      AK := AK * W;
    end;
    if PrevIdx2 >= OverlapStart then
    begin
      W := Sin(Pi * (PrevIdx2 - OverlapStart + 0.5) / Overlap);
      W := W * W;
      BK := BK * W;
    end;
    // Falling window on CurrM start (first Overlap samples):
    if CurrIdx2 < Overlap then
    begin
      W := Sin(Pi * (Overlap - 1 - CurrIdx2 + 0.5) / Overlap);
      W := W * W;
      DK := DK * W;
    end;
    if CurrIdx1 < Overlap then
    begin
      W := Sin(Pi * (Overlap - 1 - CurrIdx1 + 0.5) / Overlap);
      W := W * W;
      CK := CK * W;
    end;

    // MDCT analysis folding: differences between symmetric halves
    Br[K] := 0.5 * N4 * ((AK - DK) * cosA + (BK - CK) * sinA);
    Bi[K] := 0.5 * N4 * ((AK - DK) * sinA - (BK - CK) * cosA);
  end;

  // Step 2: N4-point complex IDFT (inverse of the forward DFT in IMDCT)
  for K := 0 to N4 - 1 do
  begin
    Cr[K] := 0.0; Ci[K] := 0.0;
    for J := 0 to N4 - 1 do
    begin
      Angle  := 2.0 * Pi * K * J / N4;
      Cr[K] := Cr[K] + Br[J] * Cos(Angle) - Bi[J] * Sin(Angle);
      Ci[K] := Ci[K] + Br[J] * Sin(Angle) + Bi[J] * Cos(Angle);
    end;
    Cr[K] := Cr[K] / N4;
    Ci[K] := Ci[K] / N4;
  end;

  // Step 3: Spectral post-rotate → spectral coefficients
  for K := 0 to N4 - 1 do
  begin
    Angle := Pi * (4.0 * K + 1) / (2.0 * N);
    cosA  := Cos(Angle);
    sinA  := Sin(Angle);
    Output[N2 - 1 - 2 * K] := Cr[K] * cosA + Ci[K] * sinA;
    Output[2 * K]           := -Cr[K] * sinA + Ci[K] * cosA;
  end;
end;

// ---------------------------------------------------------------------------
// Band energy and normalization
// ---------------------------------------------------------------------------

procedure CeltComputeBandEnergy(const X: PSingle; M, LM, NBands: Integer;
  out BandE: TArray<Single>);
var
  J, BinLo, BinHi, I: Integer;
  Sum: Double;
begin
  SetLength(BandE, NBands);
  for J := 0 to NBands - 1 do
  begin
    BinLo := CELT_ENC_EBANDS[J] * (1 shl LM);
    BinHi := CELT_ENC_EBANDS[J+1] * (1 shl LM);
    if BinHi > M then BinHi := M;
    Sum := 0;
    for I := BinLo to BinHi - 1 do
      Sum := Sum + X[I] * X[I];
    BandE[J] := Sqrt(Sum);
    if BandE[J] < 1e-15 then BandE[J] := 1e-15;
  end;
end;

// Normalize X in-place: X[i] /= BandE[band]
procedure CeltNormalizeBands(X: PSingle; M, LM, NBands: Integer;
  const BandE: TArray<Single>);
var
  J, BinLo, BinHi, I: Integer;
  Inv: Single;
begin
  for J := 0 to NBands - 1 do
  begin
    BinLo := CELT_ENC_EBANDS[J] * (1 shl LM);
    BinHi := CELT_ENC_EBANDS[J+1] * (1 shl LM);
    if BinHi > M then BinHi := M;
    Inv := 1.0 / BandE[J];
    for I := BinLo to BinHi - 1 do
      X[I] := X[I] * Inv;
  end;
end;

// ---------------------------------------------------------------------------
// Coarse energy quantization (simplified from libopus quant_bands.c)
// ---------------------------------------------------------------------------

procedure CeltQuantCoarseEnergy(var Re: TOpusRangeEncoder;
  const LogE: TArray<Single>; var OldLogE: TArray<Single>;
  NBands, Budget, LM: Integer; Intra: Boolean);
var
  I      : Integer;
  Coef, Beta: Single;
  Prev   : Single;
  F, Q   : Single;
  QI     : Integer;
  Tell   : Integer;
  BitsLeft: Integer;
  PI     : Integer;
  P0, Decay: Cardinal;
const
  SMALL_E_ICDF: array[0..2] of Byte = (2, 1, 0);
begin
  if Intra then
  begin
    Coef := 0;
    Beta := CELT_BETA_INTRA;
  end
  else
  begin
    Beta := CELT_BETA_COEF[LM];
    Coef := CELT_PRED_COEF[LM];
  end;

  // Write intra flag (1 bit) if budget allows
  if Budget >= 3 then
    ReEncodeBit(Re, Intra, 3);

  Prev := 0;
  for I := 0 to NBands - 1 do
  begin
    F  := LogE[I] - Coef * OldLogE[I] - Prev;
    QI := Round(F);

    Tell     := ReTell(Re);
    BitsLeft := Budget - Tell - 3 * (NBands - I);
    if (I > 0) and (BitsLeft < 30) then
    begin
      if BitsLeft < 24 then QI := Min(1, QI);
      if BitsLeft < 16 then QI := Max(-1, QI);
    end;

    // Choose encoding method by available bits
    if Budget - ReTell(Re) >= 15 then
    begin
      PI := 2 * Min(I, 20);
      P0    := CELT_E_PROB[LM][Ord(Intra)][PI];
      Decay := CELT_E_PROB[LM][Ord(Intra)][PI + 1];
      // Simplified: encode using uniform range (full Laplace is in laplace.c)
      // Clamp to [-15, 15] to avoid unbounded range
      QI := Max(-15, Min(15, QI));
      ReEncodeUInt(Re, Cardinal(QI + 15), 31);
    end
    else if Budget - ReTell(Re) >= 2 then
    begin
      QI := Max(-1, Min(1, QI));
      // Zig-zag encode: 0→0, 1→2, -1→1
      var Sym: Integer := Abs(QI) * 2;
      if QI < 0 then Sym := Sym - 1;
      ReEncodeICDF(Re, Sym, SMALL_E_ICDF, 2);
    end
    else if Budget - ReTell(Re) >= 1 then
    begin
      QI := Min(0, QI);
      ReEncodeBit(Re, QI < 0, 1);
    end
    else
      QI := -1;

    Q := QI;
    OldLogE[I] := Coef * OldLogE[I] + Prev + Q;
    Prev := Prev + Q - Beta * Q;
  end;
end;

// ---------------------------------------------------------------------------
// Bit allocation
// ---------------------------------------------------------------------------

procedure CeltAllocBits(Budget, NBands, LM: Integer;
  out Pulses, EBits: TArray<Integer>);
const
  BITRES = 3;  // 3 fractional bits
var
  I, J     : Integer;
  TotalBins: Integer;
  AllocRow : Integer;
  BitsLeft : Integer;
  BinCount : Integer;
  BitFrac  : Integer;  // bits × 8 (BITRES=3)
  PulseBits: Integer;
  Fine     : Integer;
  Pulses_  : Integer;
begin
  SetLength(Pulses, NBands);
  SetLength(EBits, NBands);

  TotalBins := CELT_ENC_EBANDS[NBands] * (1 shl LM);

  // Binary search on allocation vectors to find the right rate point
  AllocRow := 5;  // mid-point in allocation table
  BitsLeft := Budget;

  // Simple proportional allocation using allocVectors[AllocRow]
  for I := 0 to NBands - 1 do
  begin
    BinCount := (CELT_ENC_EBANDS[I+1] - CELT_ENC_EBANDS[I]) * (1 shl LM);
    // bits for this band = allocVectors[row][band] * C * BinCount * 2^LM / 4 (Q2)
    BitFrac := Integer(CELT_ALLOC_VECTORS[AllocRow][I]) * BinCount shr 2;
    // Convert to total bits budget scaled
    BitFrac := BitFrac * BitsLeft div Max(1, TotalBins * 25);

    // Fine energy bits (1-2 bits per band)
    Fine := Max(0, Min(3, BitFrac shr (BITRES + 1)));
    EBits[I] := Fine;

    // PVQ pulses from remaining bits
    PulseBits := Max(0, BitFrac - Fine * (1 shl BITRES));
    // Rough conversion: K ≈ 2^(PulseBits/BinCount) × BinCount
    if PulseBits > 0 then
      Pulses_ := Max(1, Min(128, Round(Power(2.0, PulseBits / Max(1, BinCount)) * BinCount / 4)))
    else
      Pulses_ := 0;
    Pulses[I] := Pulses_;
  end;
end;

// ---------------------------------------------------------------------------
// PVQ greedy search (from libopus celt/vq.c op_pvq_search_c, MIT license)
// ---------------------------------------------------------------------------

// Search for the best K-pulse vector approximating X[0..N-1].
// Result stored in IY[0..N-1] (signed integers, L1 norm = K).
procedure CeltPVQSearch(X: PSingle; N, K: Integer; out IY: TArray<Integer>);
var
  I, J, BestId: Integer;
  PulsesLeft   : Integer;
  SignX        : TArray<Integer>;
  AbsX         : TArray<Single>;
  Y            : TArray<Single>;
  XY, YY       : Double;
  Rxy, Ryy     : Double;
  BestNum, BestDen: Double;
begin
  SetLength(IY, N);
  SetLength(SignX, N);
  SetLength(AbsX, N);
  SetLength(Y, N);

  // Strip sign, start with zero
  XY := 0; YY := 0;
  for J := 0 to N - 1 do
  begin
    SignX[J] := Ord(X[J] < 0);
    AbsX[J]  := Abs(X[J]);
    IY[J]    := 0;
    Y[J]     := 0;
  end;

  PulsesLeft := K;

  // Greedy pulse assignment
  for I := 0 to PulsesLeft - 1 do
  begin
    BestId  := 0;
    BestNum := -1;
    BestDen := 1;
    YY := YY + 1;  // squared magnitude term

    for J := 0 to N - 1 do
    begin
      Rxy := XY + AbsX[J];
      Ryy := YY + Y[J];
      // Score: Rxy² / Ryy — choose max
      if Rxy * Rxy * BestDen > BestNum * Ryy then
      begin
        BestNum := Rxy * Rxy;
        BestDen := Ryy;
        BestId  := J;
      end;
    end;

    XY      := XY + AbsX[BestId];
    YY      := YY + Y[BestId];
    Y[BestId] := Y[BestId] + 2;  // multiplied by 2 for next iteration
    IY[BestId] := IY[BestId] + 1;
  end;

  // Apply original signs
  for J := 0 to N - 1 do
    if SignX[J] <> 0 then
      IY[J] := -IY[J];
end;

// ---------------------------------------------------------------------------
// Fine energy quantization
// ---------------------------------------------------------------------------

procedure CeltQuantFineEnergy(var Re: TOpusRangeEncoder;
  const LogE: TArray<Single>; OldLogE: TArray<Single>;
  const EBits: TArray<Integer>; NBands: Integer);
var
  I    : Integer;
  Error: Single;
  Q2   : Integer;
  Extra: Integer;
begin
  for I := 0 to NBands - 1 do
  begin
    if EBits[I] <= 0 then Continue;
    Extra := 1 shl EBits[I];
    Error := LogE[I] - OldLogE[I];
    Q2 := Round((Error + 0.5) * Extra);
    Q2 := Max(0, Min(Extra - 1, Q2));
    ReEncodeRaw(Re, Cardinal(Q2), EBits[I]);
  end;
end;

// ---------------------------------------------------------------------------
// ICDF tables compatible with decoder (from OpusCelt.pas)
// ---------------------------------------------------------------------------
const
  // These mirror the decoder's tables exactly
  ENC_SILENCE_ICDF    : array[0..1] of Byte = (255, 0);
  ENC_POSTFILTER_ICDF : array[0..1] of Byte = (128, 0);
  ENC_TRANSIENT_ICDF  : array[0..1] of Byte = (128, 0);
  ENC_INTRA_ICDF      : array[0..1] of Byte = (128, 0);
  ENC_DUALSTEREO_ICDF : array[0..1] of Byte = (128, 0);
  ENC_ENERGY_ICDF     : array[0..3] of Byte = (200, 150, 80, 0);

  CELT_NB_IMDCT_SIZE  = 120;  // 2.5ms base frame

// Energy quantization: maps symbols 0..3 ↔ dB corrections -6,-3,+3,+6
// (matches decoder's case statement in CeltDecodeCoarseEnergy)
function QuantizeEnergyResidual(Q: Single): Integer; inline;
begin
  if Q < -4.5 then Result := 0
  else if Q < 0 then Result := 1
  else if Q < 4.5 then Result := 2
  else Result := 3;
end;

function DequantizeEnergyResidual(Sym: Integer): Single; inline;
begin
  case Sym of
    0: Result := -6.0;
    1: Result := -3.0;
    2: Result := +3.0;
    else Result := +6.0;
  end;
end;

// ---------------------------------------------------------------------------
// PVQ combinatorics compatible with decoder (uses C(N,K) standard formula)
// ---------------------------------------------------------------------------

function GCD64(A, B: Int64): Int64; inline;
begin
  while B <> 0 do
  begin
    var T := A mod B;
    A := B; B := T;
  end;
  Result := Abs(A);
end;

// Standard binomial coefficient C(N, K) = N! / (K! * (N-K)!)
function BinomialCoeff(N, K: Integer): Cardinal;
var
  I: Integer;
  Num, Den, G: Int64;
begin
  if (K < 0) or (K > N) then Exit(0);
  if K = 0 then Exit(1);
  if K > N - K then K := N - K;
  Num := 1; Den := 1;
  for I := 1 to K do
  begin
    Num := Num * (N - I + 1);
    Den := Den * I;
    G := GCD64(Num, Den);
    Num := Num div G;
    Den := Den div G;
    if Num > $7FFFFFFF then Exit($7FFFFFFF);
  end;
  Result := Cardinal(Num div Den);
end;

// Total PVQ codewords for N dimensions, K pulses: C(N+K-1, K)
// Compatible with decoder's PVQ_C(N+K-1, K)
function CeltPVQCCompat(N, K: Integer): Cardinal;
begin
  Result := BinomialCoeff(N + K - 1, K);
end;

// Compute rank of AbsY (unsigned pulse distribution) in PVQ space.
// Matches the reverse of the decoder's unranking algorithm.
function CeltPVQRankCompat(N, K: Integer; const AbsY: array of Integer): Cardinal;
var
  Remaining, I, J: Integer;
  Rank: Int64;
  A, B: Integer;
begin
  Rank := 0;
  Remaining := K;
  for I := 0 to N - 1 do
  begin
    for J := 0 to AbsY[I] - 1 do
    begin
      A := (N - I - 1) + (Remaining - J - 1);
      B := Remaining - J - 1;
      if (A >= 0) and (B >= 0) and (A >= B) then
        Inc(Rank, BinomialCoeff(A, B));
      if Rank > $7FFFFFFF then Exit($7FFFFFFF);
    end;
    Dec(Remaining, AbsY[I]);
    if Remaining <= 0 then Break;
  end;
  Result := Cardinal(Rank);
end;

// PVQ encode compatible with decoder: rank (using C(N+K-1,K)) + sign bits per nonzero.
procedure CeltPVQEncodeCompat(var Re: TOpusRangeEncoder; X: PSingle; N, K: Integer);
var
  IY     : TArray<Integer>;
  AbsIY  : TArray<Integer>;
  Total  : Cardinal;
  Rank   : Cardinal;
  I      : Integer;
begin
  if (N <= 0) or (K <= 0) then Exit;

  // 1. Greedy PVQ search
  CeltPVQSearch(X, N, K, IY);

  // 2. Separate absolute values and signs
  SetLength(AbsIY, N);
  for I := 0 to N - 1 do
    AbsIY[I] := Abs(IY[I]);

  // 3. Encode rank (clamped to 2^31-1)
  Total := CeltPVQCCompat(N, K);
  if Total > 1 then
  begin
    Rank := CeltPVQRankCompat(N, K, AbsIY);
    ReEncodeUInt(Re, Rank, Total);
  end;

  // 4. Encode sign bits for each nonzero component
  for I := 0 to N - 1 do
    if AbsIY[I] > 0 then
      ReEncodeBit(Re, IY[I] < 0, 1);
end;

// ---------------------------------------------------------------------------
// State init
// ---------------------------------------------------------------------------

procedure CeltEncStateInit(var S: TCeltEncState; Channels, LM: Integer);
const
  FrameSizes: array[0..3] of Integer = (120, 240, 480, 960);
begin
  FillChar(S, SizeOf(S), 0);
  S.Channels   := Channels;
  S.LM         := LM;
  S.FrameSize  := FrameSizes[Min(3, Max(0, LM))];
  S.FirstFrame := True;
  // Store FrameSize/2 previous samples (half-frame overlap)
  SetLength(S.OverlapBuf, S.FrameSize div 2);
  // Initialize previous log energy in dB to a safe low value
  var I: Integer;
  for I := 0 to CELT_ENC_BANDS - 1 do
    S.PrevLogE_dB[I] := -100.0;
end;

// ---------------------------------------------------------------------------
// Main frame encoder — compatible with CeltDecodeFrame
// Writes flags, coarse energy, PVQ, fine energy in the same order/format
// as the decoder reads them.
// ---------------------------------------------------------------------------

function CeltEncodeFrame(
  var S      : TCeltEncState;
  PCM        : PSmallInt;
  var Re     : TOpusRangeEncoder;
  Budget     : Integer
): Boolean;
var
  M2, M, LM, NBands: Integer;  // M2=FrameSize/2 (MDCT out bins), M=FrameSize
  Buf        : TArray<Single>;  // current frame samples (float)
  CurrHalf   : TArray<Single>;  // first half of current frame for MDCT
  X          : TArray<Single>;  // MDCT spectral coefficients (M2 bins)
  BandE      : TArray<Single>;  // per-band linear RMS energy
  BandE_dB   : TArray<Single>;  // per-band energy in dB (for quantization)
  NormX      : TArray<Single>;  // band-normalized spectral coefficients
  I, J       : Integer;
  BinLo, BinHi, BinCount: Integer;
  Intra      : Boolean;
  Prediction : Single;
  Q, Q_dB    : Single;
  Sym        : Integer;
  TotalBins  : Integer;
  BandBits   : TArray<Integer>;
  FineBits_  : TArray<Integer>;
  K, TellAfterEnergy, TotalBitsForPVQ : Integer;
  Fine, Raw  : Integer;
begin
  Result := False;
  M  := S.FrameSize;      // e.g. 960 for 20ms
  M2 := M div 2;          // MDCT output bins: 480 for 20ms
  LM := S.LM;
  NBands := CELT_ENC_BANDS;

  // --- 1. Convert PCM to float (mono, Phase 3) ---
  SetLength(Buf, M);
  var MaxPCM: Single := 0;
  for I := 0 to M - 1 do
  begin
    Buf[I] := PCM[I] / 32768.0;
    if Abs(Buf[I]) > MaxPCM then MaxPCM := Abs(Buf[I]);
  end;

  // Detect true silence: encode silence flag and skip rest of frame
  if MaxPCM < 1e-5 then
  begin
    ReEncodeICDF(Re, 0, ENC_SILENCE_ICDF, 8);  // symbol 0 = silence
    // Update overlap buffer with zeros
    if Length(S.OverlapBuf) < M2 then SetLength(S.OverlapBuf, M2);
    FillChar(S.OverlapBuf[0], M2 * SizeOf(Single), 0);
    S.FirstFrame := False;
    Exit(not Re.Error);
  end;

  // --- 2. Forward MDCT using half-frame convention ---
  // Use first M2 samples of current as the "current half-frame"
  // This gives M2 spectral bins, consistent with decoder (IMDCT input = M2 bins)
  SetLength(CurrHalf, M2);
  for I := 0 to M2 - 1 do
    CurrHalf[I] := Buf[I];

  SetLength(X, M2);
  CeltForwardMDCT(
    @S.OverlapBuf[0],  // previous M2 samples
    @CurrHalf[0],      // current M2 samples
    M2,                // M2 = FrameSize/2
    CELT_ENC_OVERLAP,
    @X[0]
  );

  // --- 3. Compute per-band energy using same band boundaries as decoder ---
  // Band j: [eBands[j]*M/960, eBands[j+1]*M/960)
  // For M=960: [eBands[j], eBands[j+1]) → same as CELT_ENC_EBANDS[j]
  SetLength(BandE, NBands);
  SetLength(BandE_dB, NBands);
  for J := 0 to NBands - 1 do
  begin
    BinLo := CELT_ENC_EBANDS[J] * M div 960;
    BinHi := CELT_ENC_EBANDS[J+1] * M div 960;
    if BinHi > M2 then BinHi := M2;
    var Sum: Double := 0;
    for I := BinLo to BinHi - 1 do Sum := Sum + X[I] * X[I];
    BandE[J] := Sqrt(Sum);
    if BandE[J] > 1e-20 then
      BandE_dB[J] := 20.0 * Log10(BandE[J])
    else
      BandE_dB[J] := -100.0;
  end;

  // --- 4. Write frame flags (matching CeltDecodeFrame read order) ---

  // Silence = False (symbol 1 since ICDF: 0 = silence in decoder)
  ReEncodeICDF(Re, 1, ENC_SILENCE_ICDF, 8);

  // Post-filter = False
  ReEncodeICDF(Re, 1, ENC_POSTFILTER_ICDF, 8);

  // Transient = False (only written for FrameSize > 120)
  if M > CELT_NB_IMDCT_SIZE then
    ReEncodeICDF(Re, 1, ENC_TRANSIENT_ICDF, 8);

  // Dual-stereo (mono: skip — decoder only reads for Channels > 1)

  // Intra energy flag: use intra for first frame
  Intra := S.FirstFrame;
  ReEncodeICDF(Re, Ord(not Intra), ENC_INTRA_ICDF, 8);
  // Decoder: IntraEnergy := (symbol=0) so we write 0 for intra, 1 for inter

  // --- 5. Coarse energy (4-symbol ICDF, matching decoder's CELT_ENERGY_ICDF) ---
  for J := 0 to NBands - 1 do
  begin
    // Inter-frame prediction (matches decoder: Prediction = PrevLogE * 0.9)
    if Intra then
      Prediction := 0.0
    else
      Prediction := S.PrevLogE_dB[J] * 0.9;

    Q_dB := BandE_dB[J] - Prediction;
    Sym  := QuantizeEnergyResidual(Q_dB);
    ReEncodeICDF(Re, Sym, ENC_ENERGY_ICDF, 8);

    // Update PrevLogE_dB with the quantized energy (same update as decoder)
    S.PrevLogE_dB[J] := Prediction + DequantizeEnergyResidual(Sym);
  end;

  // --- 6. Bit allocation (same formula as decoder) ---
  TellAfterEnergy  := ReTell(Re);
  TotalBitsForPVQ  := Max(0, Budget - TellAfterEnergy);

  // Same allocation as CeltAllocateBits in decoder
  TotalBins := 0;
  for J := 0 to NBands - 1 do
  begin
    BinLo := CELT_ENC_EBANDS[J] * M div 960;
    BinHi := CELT_ENC_EBANDS[J+1] * M div 960;
    if BinHi > M2 then BinHi := M2;
    Inc(TotalBins, BinHi - BinLo);
  end;
  if TotalBins = 0 then TotalBins := 1;

  SetLength(BandBits, NBands);
  SetLength(FineBits_, NBands);
  for J := 0 to NBands - 1 do
  begin
    BinLo := CELT_ENC_EBANDS[J] * M div 960;
    BinHi := CELT_ENC_EBANDS[J+1] * M div 960;
    if BinHi > M2 then BinHi := M2;
    BinCount := BinHi - BinLo;
    BandBits[J]  := TotalBitsForPVQ * BinCount div TotalBins;
    FineBits_[J] := Min(1, BandBits[J] div 4);
  end;

  // --- 7. Normalize spectral coefficients by band energy ---
  SetLength(NormX, M2);
  for I := 0 to M2 - 1 do NormX[I] := X[I];
  for J := 0 to NBands - 1 do
  begin
    BinLo := CELT_ENC_EBANDS[J] * M div 960;
    BinHi := CELT_ENC_EBANDS[J+1] * M div 960;
    if BinHi > M2 then BinHi := M2;
    var Inv: Single := 0;
    if BandE[J] > 1e-20 then Inv := 1.0 / BandE[J];
    for I := BinLo to BinHi - 1 do NormX[I] := NormX[I] * Inv;
  end;

  // --- 8. PVQ encode each band (decoder-compatible: PVQ_C + sign bits) ---
  for J := 0 to NBands - 1 do
  begin
    BinLo    := CELT_ENC_EBANDS[J] * M div 960;
    BinHi    := CELT_ENC_EBANDS[J+1] * M div 960;
    if BinHi > M2 then BinHi := M2;
    BinCount := BinHi - BinLo;
    if BinCount <= 0 then Continue;

    // K = BandBits div 4 (same as decoder), clamped to 2×BinCount
    K := BandBits[J] div 4;
    K := Max(0, Min(K, BinCount * 2));

    if K > 0 then
      CeltPVQEncodeCompat(Re, @NormX[BinLo], BinCount, K);
  end;

  // --- 9. Fine energy (ReEncodeUInt, matching decoder's RdDecodeUInt) ---
  for J := 0 to NBands - 1 do
  begin
    Fine := FineBits_[J];
    if Fine <= 0 then Continue;
    // Residual = actual dB - quantized coarse
    Q := BandE_dB[J] - S.PrevLogE_dB[J];
    // Map to [0, 2^Fine)
    Raw := Round((Q / 1.0 + 0.5) * (1 shl Fine));
    Raw := Max(0, Min((1 shl Fine) - 1, Raw));
    ReEncodeUInt(Re, Cardinal(Raw), Cardinal(1) shl Fine);
  end;

  // --- 10. Update overlap buffer (store last M2 samples of current frame) ---
  if Length(S.OverlapBuf) < M2 then
    SetLength(S.OverlapBuf, M2);
  for I := 0 to M2 - 1 do
    S.OverlapBuf[I] := Buf[M2 + I];  // second half of current frame

  S.FirstFrame := False;
  Result := not Re.Error;
end;

end.
