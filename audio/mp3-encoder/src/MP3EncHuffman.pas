unit MP3EncHuffman;

{
  MP3EncHuffman.pas — ISO 11172-3 Layer III Huffman coder

  Covers:
    - Big-values region: tables 0–31 (non-ESC tables 0–15, ESC tables 16–31)
    - Count1 region: tables 32 (quad_A) and 33 (quad_B)
    - HuffCountRegionBits / HuffBestTable helpers for outer rate-control loop

  Table data translated verbatim from toots/shine src/lib/huffman.c
  Encoding logic from src/lib/l3bitstream.c shine_HuffmanCode /
    shine_huffman_coder_count1.

  Reference: ISO 11172-3 Annex B Table B.7 / page 98 pseudocode
  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

const
  HUFF_TABLES   = 32;   { big-values table indices 0..31 }
  HUFF_QUAD_A   = 32;   { count1 table A }
  HUFF_QUAD_B   = 33;   { count1 table B }
  HUFF_INVALID  = $7FFF;{ returned when table cannot encode the pair }

type
  THuffCode = record
    Code : UInt64;    { MSB-first packed bits (huffman + linbits + signs), up to 47 bits }
    Len  : Integer;   { total bit count; 0 = no bits (all-zero pair) }
  end;

{ Must be called once before any Huff* function. No-op currently (tables are
  const) but present for future precomputed-distance tables. }
procedure HuffInit;

{ LinBits count for ESC tables 16–31 (0 for tables 0–15 and quad tables). }
function HuffLinBits(ATable: Integer): Integer;

{ Encode one big-values pair (x,y are absolute values; sign flags are 0/1).
  Returns Len=0 for table 0 or (0,0) pair — caller writes nothing.
  Returns Len=HUFF_INVALID if the pair is out of range for the table. }
function HuffEncodePair(ATable, AX, AY, ASignX, ASignY: Integer): THuffCode;

{ Bit count only — faster than HuffEncodePair when signs are irrelevant.
  Returns HUFF_INVALID if out of range. }
function HuffCountPairBits(ATable, AX, AY: Integer): Integer;

{ Encode one count1 quad (v,w,x,y are absolute values; sign flags 0/1).
  Only tables 32 and 33 are valid here. }
function HuffEncodeQuad(ATable, AV, AW, AX, AY,
  ASignV, ASignW, ASignX, ASignY: Integer): THuffCode;

{ Bit count for a count1 quad (signs irrelevant). }
function HuffCountQuadBits(ATable, AV, AW, AX, AY: Integer): Integer;

{ Sum of HuffCountPairBits for pairs (AIx[AStart], AIx[AStart+1]) ...
  (AIx[AEnd-2], AIx[AEnd-1]).  AEnd must be even. }
function HuffCountRegionBits(ATable, AStart, AEnd: Integer;
  const AIx: array of Integer): Integer;

{ Return the table index (0..15) that gives the fewest bits for a region.
  Returns 0 for an all-zero region.  AIx values must be <= 15. }
function HuffBestTable(AStart, AEnd: Integer;
  const AIx: array of Integer): Integer;

implementation

{$POINTERMATH ON}

// ---------------------------------------------------------------------------
// Huffman table data — translated verbatim from toots/shine huffman.c
// ---------------------------------------------------------------------------

const

  { Table 1 — xlen=2, ylen=2 }
  CT1C: array[0..3] of Word =
    (1, 1, 1, 0);
  CT1L: array[0..3] of Byte =
    (1, 3, 3, 3);

  { Table 2 — xlen=3, ylen=3 }
  CT2C: array[0..8] of Word =
    (1, 2, 1, 3, 1, 1, 3, 2, 0);
  CT2L: array[0..8] of Byte =
    (1, 3, 6, 3, 3, 5, 5, 5, 6);

  { Table 3 — xlen=3, ylen=3 }
  CT3C: array[0..8] of Word =
    (3, 2, 1, 1, 1, 1, 3, 2, 0);
  CT3L: array[0..8] of Byte =
    (2, 2, 6, 3, 2, 5, 5, 5, 6);

  { Table 5 — xlen=4, ylen=4 }
  CT5C: array[0..15] of Word =
    (1, 2, 6, 5, 3, 1, 4, 4, 7, 5, 7, 1, 6, 1, 1, 0);
  CT5L: array[0..15] of Byte =
    (1, 3, 6, 7, 3, 3, 6, 7, 6, 6, 7, 8, 7, 6, 7, 8);

  { Table 6 — xlen=4, ylen=4 }
  CT6C: array[0..15] of Word =
    (7, 3, 5, 1, 6, 2, 3, 2, 5, 4, 4, 1, 3, 3, 2, 0);
  CT6L: array[0..15] of Byte =
    (3, 3, 5, 7, 3, 2, 4, 5, 4, 4, 5, 6, 6, 5, 6, 7);

  { Table 7 — xlen=6, ylen=6 }
  CT7C: array[0..35] of Word =
    (1,  2, 10, 19, 16, 10, 3,  3,  7,  10, 5,  3,
     11, 4, 13, 17, 8,  4, 12, 11, 18, 15, 11, 2,
     7,  6, 9,  14, 3,  1,  6,  4,  5,  3,  2,  0);
  CT7L: array[0..35] of Byte =
    (1, 3, 6, 8, 8, 9,  3, 4, 6, 7,  7,  8,
     6, 5, 7, 8, 8, 9,  7, 7, 8, 9,  9,  9,
     7, 7, 8, 9, 9, 10, 8, 8, 9, 10, 10, 10);

  { Table 8 — xlen=6, ylen=6 }
  CT8C: array[0..35] of Word =
    (3,  4, 6, 18, 12, 5, 5,  1,  2,  16, 9,  3,
     7,  3, 5, 14, 7,  3, 19, 17, 15, 13, 10, 4,
     13, 5, 8, 11, 5,  1, 12, 4,  4,  1,  1,  0);
  CT8L: array[0..35] of Byte =
    (2, 3, 6, 8, 8,  9,  3, 2, 4, 8, 8,  8,
     6, 4, 6, 8, 8,  9,  8, 8, 8, 9, 9,  10,
     8, 7, 8, 9, 10, 10, 9, 8, 9, 9, 11, 11);

  { Table 9 — xlen=6, ylen=6 }
  CT9C: array[0..35] of Word =
    (7,  5, 9, 14, 15, 7, 6,  4, 5, 5,  6, 7,
     7,  6, 8, 8,  8,  5, 15, 6, 9, 10, 5, 1,
     11, 7, 9, 6,  4,  1, 14, 4, 6, 2,  6, 0);
  CT9L: array[0..35] of Byte =
    (3, 3, 5, 6, 8, 9, 3, 3, 4, 5, 6, 8,
     4, 4, 5, 6, 7, 8, 6, 5, 6, 7, 7, 8,
     7, 6, 7, 7, 8, 9, 8, 7, 8, 8, 9, 9);

  { Table 10 — xlen=8, ylen=8 }
  CT10C: array[0..63] of Word = (
    1,  2,  10, 23, 35, 30, 12, 17, 3,  3,  8,  12, 18, 21, 12, 7,
    11, 9,  15, 21, 32, 40, 19, 6,  14, 13, 22, 34, 46, 23, 18, 7,
    20, 19, 33, 47, 27, 22, 9,  3,  31, 22, 41, 26, 21, 20, 5,  3,
    14, 13, 10, 11, 16, 6,  5,  1,  9,  8,  7,  8,  4,  4,  2,  0);
  CT10L: array[0..63] of Byte = (
    1, 3, 6, 8,  9,  9,  9,  10, 3, 4, 6,  7,  8,  9,  8,  8,
    6, 6, 7, 8,  9,  10, 9,  9,  7, 7, 8,  9,  10, 10, 9,  10,
    8, 8, 9, 10, 10, 10, 10, 10, 9, 9, 10, 10, 11, 11, 10, 11,
    8, 8, 9, 10, 10, 10, 11, 11, 9, 8, 9,  10, 10, 11, 11, 11);

  { Table 11 — xlen=8, ylen=8 }
  CT11C: array[0..63] of Word = (
    3,  4,  10, 24, 34, 33, 21, 15, 5,  3,  4,  10, 32, 17, 11, 10,
    11, 7,  13, 18, 30, 31, 20, 5,  25, 11, 19, 59, 27, 18, 12, 5,
    35, 33, 31, 58, 30, 16, 7,  5,  28, 26, 32, 19, 17, 15, 8,  14,
    14, 12, 9,  13, 14, 9,  4,  1,  11, 4,  6,  6,  6,  3,  2,  0);
  CT11L: array[0..63] of Byte = (
    2, 3, 5, 7, 8, 9,  8,  9,  3, 3, 4, 6,  8,  8,  7,  8,
    5, 5, 6, 7, 8, 9,  8,  8,  7, 6, 7, 9,  8,  10, 8,  9,
    8, 8, 8, 9, 9, 10, 9,  10, 8, 8, 9, 10, 10, 11, 10, 11,
    8, 7, 7, 8, 9, 10, 10, 10, 8, 7, 8, 9,  10, 10, 10, 10);

  { Table 12 — xlen=8, ylen=8 }
  CT12C: array[0..63] of Word = (
    9,  6,  16, 33, 41, 39, 38, 26, 7,  5,  6,  9,  23, 16, 26, 11,
    17, 7,  11, 14, 21, 30, 10, 7,  17, 10, 15, 12, 18, 28, 14, 5,
    32, 13, 22, 19, 18, 16, 9,  5,  40, 17, 31, 29, 17, 13, 4,  2,
    27, 12, 11, 15, 10, 7,  4,  1,  27, 12, 8,  12, 6,  3,  1,  0);
  CT12L: array[0..63] of Byte = (
    4, 3, 5, 7, 8, 9, 9, 9, 3, 3, 4, 5,  7, 7, 8, 8, 5, 4, 5, 6, 7, 8,
    7, 8, 6, 5, 6, 6, 7, 8, 8, 8, 7, 6,  7, 7, 8, 8, 8, 9, 8, 7, 8, 8,
    8, 9, 8, 9, 8, 7, 7, 8, 8, 9, 9, 10, 9, 8, 8, 9, 9, 9, 9, 10);

  { Table 13 — xlen=16, ylen=16 }
  CT13C: array[0..255] of Word = (
    1,  5,  14, 21, 34, 51, 46, 71, 42, 52, 68,  52, 67, 44, 43, 19,
    3,  4,  12, 19, 31, 26, 44, 33, 31, 24, 32,  24, 31, 35, 22, 14,
    15, 13, 23, 36, 59, 49, 77, 65, 29, 40, 30,  40, 27, 33, 42, 16,
    22, 20, 37, 61, 56, 79, 73, 64, 43, 76, 56,  37, 26, 31, 25, 14,
    35, 16, 60, 57, 97, 75,114, 91, 54, 73, 55,  41, 48, 53, 23, 24,
    58, 27, 50, 96, 76, 70, 93, 84, 77, 58, 79,  29, 74, 49, 41, 17,
    47, 45, 78, 74,115, 94, 90, 79, 69, 83, 71,  50, 59, 38, 36, 15,
    72, 34, 56, 95, 92, 85, 91, 90, 86, 73, 77,  65, 51, 44, 43, 42,
    43, 20, 30, 44, 55, 78, 72, 87, 78, 61, 46,  54, 37, 30, 20, 16,
    53, 25, 41, 37, 44, 59, 54, 81, 66, 76, 57,  54, 37, 18, 39, 11,
    35, 33, 31, 57, 42, 82, 72, 80, 47, 58, 55,  21, 22, 26, 38, 22,
    53, 25, 23, 38, 70, 60, 51, 36, 55, 26, 34,  23, 27, 14,  9,  7,
    34, 32, 28, 39, 49, 75, 30, 52, 48, 40, 52,  28, 18, 17,  9,  5,
    45, 21, 34, 64, 56, 50, 49, 45, 31, 19, 12,  15, 10,  7,  6,  3,
    48, 23, 20, 39, 36, 35, 53, 21, 16, 23, 13,  10,  6,  1,  4,  2,
    16, 15, 17, 27, 25, 20, 29, 11, 17, 12, 16,   8,  1,  1,  0,  1);
  CT13L: array[0..255] of Byte = (
    1,  4,  6,  7,  8,  9,  9, 10,  9, 10, 11, 11, 12, 12, 13, 13,
    3,  4,  6,  7,  8,  8,  9,  9,  9,  9, 10, 10, 11, 12, 12, 12,
    6,  6,  7,  8,  9,  9, 10, 10,  9, 10, 10, 11, 11, 12, 13, 13,
    7,  7,  8,  9,  9, 10, 10, 10, 10, 11, 11, 11, 11, 12, 13, 13,
    8,  7,  9,  9, 10, 10, 11, 11, 10, 11, 11, 12, 12, 13, 13, 14,
    9,  8,  9, 10, 10, 10, 11, 11, 11, 11, 12, 11, 13, 13, 14, 14,
    9,  9, 10, 10, 11, 11, 11, 11, 11, 12, 12, 12, 13, 13, 14, 14,
   10,  9, 10, 11, 11, 11, 12, 12, 12, 12, 13, 13, 13, 14, 16, 16,
    9,  8,  9, 10, 10, 11, 11, 12, 12, 12, 12, 13, 13, 14, 15, 15,
   10,  9, 10, 10, 11, 11, 11, 13, 12, 13, 13, 14, 14, 14, 16, 15,
   10, 10, 10, 11, 11, 12, 12, 13, 12, 13, 14, 13, 14, 15, 16, 17,
   11, 10, 10, 11, 12, 12, 12, 12, 13, 13, 13, 14, 15, 15, 15, 16,
   11, 11, 11, 12, 12, 13, 12, 13, 14, 14, 15, 15, 15, 16, 16, 16,
   12, 11, 12, 13, 13, 13, 14, 14, 14, 14, 14, 15, 16, 15, 16, 16,
   13, 12, 12, 13, 13, 13, 15, 14, 14, 17, 15, 15, 15, 17, 16, 16,
   12, 12, 13, 14, 14, 14, 15, 14, 15, 15, 16, 16, 19, 18, 19, 16);

  { Table 15 — xlen=16, ylen=16 }
  CT15C: array[0..255] of Word = (
    7,   12, 18, 53, 47, 76,124,108, 89,123,108,119,107, 81,122, 63,
   13,   5, 16, 27, 46, 36, 61, 51, 42, 70, 52, 83, 65, 41, 59, 36,
   19,  17, 15, 24, 41, 34, 59, 48, 40, 64, 50, 78, 62, 80, 56, 33,
   29,  28, 25, 43, 39, 63, 55, 93, 76, 59, 93, 72, 54, 75, 50, 29,
   52,  22, 42, 40, 67, 57, 95, 79, 72, 57, 89, 69, 49, 66, 46, 27,
   77,  37, 35, 66, 58, 52, 91, 74, 62, 48, 79, 63, 90, 62, 40, 38,
  125,  32, 60, 56, 50, 92, 78, 65, 55, 87, 71, 51, 73, 51, 70, 30,
  109,  53, 49, 94, 88, 75, 66,122, 91, 73, 56, 42, 64, 44, 21, 25,
   90,  43, 41, 77, 73, 63, 56, 92, 77, 66, 47, 67, 48, 53, 36, 20,
   71,  34, 67, 60, 58, 49, 88, 76, 67,106, 71, 54, 38, 39, 23, 15,
  109,  53, 51, 47, 90, 82, 58, 57, 48, 72, 57, 41, 23, 27, 62,  9,
   86,  42, 40, 37, 70, 64, 52, 43, 70, 55, 42, 25, 29, 18, 11, 11,
  118,  68, 30, 55, 50, 46, 74, 65, 49, 39, 24, 16, 22, 13, 14,  7,
   91,  44, 39, 38, 34, 63, 52, 45, 31, 52, 28, 19, 14,  8,  9,  3,
  123,  60, 58, 53, 47, 43, 32, 22, 37, 24, 17, 12, 15, 10,  2,  1,
   71,  37, 34, 30, 28, 20, 17, 26, 21, 16, 10,  6,  8,  6,  2,  0);
  CT15L: array[0..255] of Byte = (
    3,  4,  5,  7,  7,  8,  9,  9,  9, 10, 10, 11, 11, 11, 12, 13,
    4,  3,  5,  6,  7,  7,  8,  8,  8,  9,  9, 10, 10, 10, 11, 11,
    5,  5,  5,  6,  7,  7,  8,  8,  8,  9,  9, 10, 10, 11, 11, 11,
    6,  6,  6,  7,  7,  8,  8,  9,  9,  9, 10, 10, 10, 11, 11, 11,
    7,  6,  7,  7,  8,  8,  9,  9,  9,  9, 10, 10, 10, 11, 11, 11,
    8,  7,  7,  8,  8,  8,  9,  9,  9,  9, 10, 10, 11, 11, 11, 12,
    9,  7,  8,  8,  8,  9,  9,  9,  9, 10, 10, 10, 11, 11, 12, 12,
    9,  8,  8,  9,  9,  9,  9, 10, 10, 10, 10, 10, 11, 11, 11, 12,
    9,  8,  8,  9,  9,  9,  9, 10, 10, 10, 10, 11, 11, 12, 12, 12,
    9,  8,  9,  9,  9,  9, 10, 10, 10, 11, 11, 11, 11, 12, 12, 12,
   10,  9,  9,  9, 10, 10, 10, 10, 10, 11, 11, 11, 11, 12, 13, 12,
   10,  9,  9,  9, 10, 10, 10, 10, 11, 11, 11, 11, 12, 12, 12, 13,
   11, 10,  9, 10, 10, 10, 11, 11, 11, 11, 11, 11, 12, 12, 13, 13,
   11, 10, 10, 10, 10, 11, 11, 11, 11, 12, 12, 12, 12, 12, 13, 13,
   12, 11, 11, 11, 11, 11, 11, 11, 12, 12, 12, 12, 13, 13, 12, 13,
   12, 11, 11, 11, 11, 11, 11, 12, 12, 12, 12, 12, 13, 13, 13, 13);

  { Tables 16–23 share these arrays (t16HB/t16l in Shine).
    xlen=16, ylen=16; ESC table. linbits per table: 1,2,3,4,6,8,10,13 }
  CT16C: array[0..255] of Word = (
    1,   5,  14,  44,  74,  63, 110,  93, 172, 149, 138, 242, 225, 195, 376,  17,
    3,   4,  12,  20,  35,  62,  53,  47,  83,  75,  68, 119, 201, 107, 207,   9,
   15,  13,  23,  38,  67,  58, 103,  90, 161,  72, 127, 117, 110, 209, 206,  16,
   45,  21,  39,  69,  64, 114,  99,  87, 158, 140, 252, 212, 199, 387, 365,  26,
   75,  36,  68,  65, 115, 101, 179, 164, 155, 264, 246, 226, 395, 382, 362,   9,
   66,  30,  59,  56, 102, 185, 173, 265, 142, 253, 232, 400, 388, 378, 445,  16,
  111,  54,  52, 100, 184, 178, 160, 133, 257, 244, 228, 217, 385, 366, 715,  10,
   98,  48,  91,  88, 165, 157, 148, 261, 248, 407, 397, 372, 380, 889, 884,   8,
   85,  84,  81, 159, 156, 143, 260, 249, 427, 401, 392, 383, 727, 713, 708,   7,
  154,  76,  73, 141, 131, 256, 245, 426, 406, 394, 384, 735, 359, 710, 352,  11,
  139, 129,  67, 125, 247, 233, 229, 219, 393, 743, 737, 720, 885, 882, 439,   4,
  243, 120, 118, 115, 227, 223, 396, 746, 742, 736, 721, 712, 706, 223, 436,   6,
  202, 224, 222, 218, 216, 389, 386, 381, 364, 888, 443, 707, 440, 437,1728,   4,
  747, 211, 210, 208, 370, 379, 734, 723, 714,1735, 883, 877, 876,3459, 865,   2,
  377, 369, 102, 187, 726, 722, 358, 711, 709, 866,1734, 871,3458, 870, 434,   0,
   12,  10,   7,  11,  10,  17,  11,   9,  13,  12,  10,   7,   5,   3,   1,   3);
  CT16L: array[0..255] of Byte = (
    1,  4,  6,  8,  9,  9, 10, 10, 11, 11, 11, 12, 12, 12, 13,  9,
    3,  4,  6,  7,  8,  9,  9,  9, 10, 10, 10, 11, 12, 11, 12,  8,
    6,  6,  7,  8,  9,  9, 10, 10, 11, 10, 11, 11, 11, 12, 12,  9,
    8,  7,  8,  9,  9, 10, 10, 10, 11, 11, 12, 12, 12, 13, 13, 10,
    9,  8,  9,  9, 10, 10, 11, 11, 11, 12, 12, 12, 13, 13, 13,  9,
    9,  8,  9,  9, 10, 11, 11, 12, 11, 12, 12, 13, 13, 13, 14, 10,
   10,  9,  9, 10, 11, 11, 11, 11, 12, 12, 12, 12, 13, 13, 14, 10,
   10,  9, 10, 10, 11, 11, 11, 12, 12, 13, 13, 13, 13, 15, 15, 10,
   10, 10, 10, 11, 11, 11, 12, 12, 13, 13, 13, 13, 14, 14, 14, 10,
   11, 10, 10, 11, 11, 12, 12, 13, 13, 13, 13, 14, 13, 14, 13, 11,
   11, 11, 10, 11, 12, 12, 12, 12, 13, 14, 14, 14, 15, 15, 14, 10,
   12, 11, 11, 11, 12, 12, 13, 14, 14, 14, 14, 14, 14, 13, 14, 11,
   12, 12, 12, 12, 12, 13, 13, 13, 13, 15, 14, 14, 14, 14, 16, 11,
   14, 12, 12, 12, 13, 13, 14, 14, 14, 16, 15, 15, 15, 17, 15, 11,
   13, 13, 11, 12, 14, 14, 13, 14, 14, 15, 16, 15, 17, 15, 14, 11,
    9,  8,  8,  9,  9, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11,  8);

  { Tables 24–31 share these arrays (t24HB/t24l in Shine).
    xlen=16, ylen=16; ESC table. linbits per table: 4,5,6,7,8,9,11,13 }
  CT24C: array[0..255] of Word = (
   15,  13,  46,  80, 146, 262, 248, 434, 426, 669, 653, 649, 621, 517,1032,  88,
   14,  12,  21,  38,  71, 130, 122, 216, 209, 198, 327, 345, 319, 297, 279,  42,
   47,  22,  41,  74,  68, 128, 120, 221, 207, 194, 182, 340, 315, 295, 541,  18,
   81,  39,  75,  70, 134, 125, 116, 220, 204, 190, 178, 325, 311, 293, 271,  16,
  147,  72,  69, 135, 127, 118, 112, 210, 200, 188, 352, 323, 306, 285, 540,  14,
  263,  66, 129, 126, 119, 114, 214, 202, 192, 180, 341, 317, 301, 281, 262,  12,
  249, 123, 121, 117, 113, 215, 206, 195, 185, 347, 330, 308, 291, 272, 520,  10,
  435, 115, 111, 109, 211, 203, 196, 187, 353, 332, 313, 298, 283, 531, 381,  17,
  427, 212, 208, 205, 201, 193, 186, 177, 169, 320, 303, 286, 268, 514, 377,  16,
  335, 199, 197, 191, 189, 181, 174, 333, 321, 305, 289, 275, 521, 379, 371,  11,
  668, 184, 183, 179, 175, 344, 331, 314, 304, 290, 277, 530, 383, 373, 366,  10,
  652, 346, 171, 168, 164, 318, 309, 299, 287, 276, 263, 513, 375, 368, 362,   6,
  648, 322, 316, 312, 307, 302, 292, 284, 269, 261, 512, 376, 370, 364, 359,   4,
  620, 300, 296, 294, 288, 282, 273, 266, 515, 380, 374, 369, 365, 361, 357,   2,
 1033, 280, 278, 274, 267, 264, 259, 382, 378, 372, 367, 363, 360, 358, 356,   0,
   43,  20,  19,  17,  15,  13,  11,   9,   7,   6,   4,   7,   5,   3,   1,   3);
  CT24L: array[0..255] of Byte = (
    4,  4,  6,  7,  8,  9,  9, 10, 10, 11, 11, 11, 11, 11, 12,  9,
    4,  4,  5,  6,  7,  8,  8,  9,  9,  9, 10, 10, 10, 10, 10,  8,
    6,  5,  6,  7,  7,  8,  8,  9,  9,  9,  9, 10, 10, 10, 11,  7,
    7,  6,  7,  7,  8,  8,  8,  9,  9,  9,  9, 10, 10, 10, 10,  7,
    8,  7,  7,  8,  8,  8,  8,  9,  9,  9, 10, 10, 10, 10, 11,  7,
    9,  7,  8,  8,  8,  8,  9,  9,  9,  9, 10, 10, 10, 10, 10,  7,
    9,  8,  8,  8,  8,  9,  9,  9,  9, 10, 10, 10, 10, 10, 11,  7,
   10,  8,  8,  8,  9,  9,  9,  9, 10, 10, 10, 10, 10, 11, 11,  8,
   10,  9,  9,  9,  9,  9,  9,  9,  9, 10, 10, 10, 10, 11, 11,  8,
   10,  9,  9,  9,  9,  9,  9, 10, 10, 10, 10, 10, 11, 11, 11,  8,
   11,  9,  9,  9,  9, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11,  8,
   11, 10,  9,  9,  9, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11,  8,
   11, 10, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11,  8,
   11, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11,  8,
   12, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11,  8,
    8,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  8,  8,  8,  8,  4);

  { Count1 table A (table 32) — quads, xlen=1 so 16 entries (ylen=16) }
  CT32C: array[0..15] of Word =
    (1, 5, 4, 5, 6, 5, 4, 4, 7, 3, 6, 0, 7, 2, 3, 1);
  CT32L: array[0..15] of Byte =
    (1, 4, 4, 5, 4, 6, 5, 6, 4, 5, 5, 6, 5, 6, 6, 6);

  { Count1 table B (table 33) — quads, uniform 4-bit codes }
  CT33C: array[0..15] of Word =
    (15,14,13,12,11,10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0);
  CT33L: array[0..15] of Byte =
    (4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4);

  { LinBits for ESC tables 16..31 (index = table - 16) }
  HUFF_LINBITS: array[0..15] of Byte =
    (1, 2, 3, 4, 6, 8, 10, 13, 4, 5, 6, 7, 8, 9, 11, 13);

// ---------------------------------------------------------------------------
// Table descriptor
// ---------------------------------------------------------------------------

type
  TTabHdr = record
    XLen   : Byte;
    YLen   : Byte;
    LinBits: Byte;
    CodP   : PWord;
    LenP   : PByte;
  end;

var
  GTab: array[0..33] of TTabHdr;
  GInitDone: Boolean = False;

// ---------------------------------------------------------------------------

procedure HuffInit;
var
  h: ^TTabHdr;
begin
  if GInitDone then Exit;

  FillChar(GTab, SizeOf(GTab), 0);

  { Table 0: no data — all-zero pairs, 0 bits }
  GTab[0].XLen := 0; GTab[0].YLen := 0;

  { Non-ESC tables }
  h := @GTab[1];  h^.XLen:=2;  h^.YLen:=2;  h^.CodP:=@CT1C[0];  h^.LenP:=@CT1L[0];
  h := @GTab[2];  h^.XLen:=3;  h^.YLen:=3;  h^.CodP:=@CT2C[0];  h^.LenP:=@CT2L[0];
  h := @GTab[3];  h^.XLen:=3;  h^.YLen:=3;  h^.CodP:=@CT3C[0];  h^.LenP:=@CT3L[0];
  { Table 4: unused (NULL in Shine) — leave all zeros }
  h := @GTab[5];  h^.XLen:=4;  h^.YLen:=4;  h^.CodP:=@CT5C[0];  h^.LenP:=@CT5L[0];
  h := @GTab[6];  h^.XLen:=4;  h^.YLen:=4;  h^.CodP:=@CT6C[0];  h^.LenP:=@CT6L[0];
  h := @GTab[7];  h^.XLen:=6;  h^.YLen:=6;  h^.CodP:=@CT7C[0];  h^.LenP:=@CT7L[0];
  h := @GTab[8];  h^.XLen:=6;  h^.YLen:=6;  h^.CodP:=@CT8C[0];  h^.LenP:=@CT8L[0];
  h := @GTab[9];  h^.XLen:=6;  h^.YLen:=6;  h^.CodP:=@CT9C[0];  h^.LenP:=@CT9L[0];
  h := @GTab[10]; h^.XLen:=8;  h^.YLen:=8;  h^.CodP:=@CT10C[0]; h^.LenP:=@CT10L[0];
  h := @GTab[11]; h^.XLen:=8;  h^.YLen:=8;  h^.CodP:=@CT11C[0]; h^.LenP:=@CT11L[0];
  h := @GTab[12]; h^.XLen:=8;  h^.YLen:=8;  h^.CodP:=@CT12C[0]; h^.LenP:=@CT12L[0];
  h := @GTab[13]; h^.XLen:=16; h^.YLen:=16; h^.CodP:=@CT13C[0]; h^.LenP:=@CT13L[0];
  { Table 14: unused — leave all zeros }
  h := @GTab[15]; h^.XLen:=16; h^.YLen:=16; h^.CodP:=@CT15C[0]; h^.LenP:=@CT15L[0];

  { ESC tables 16–23 — share t16 arrays }
  GTab[16].XLen:=16; GTab[16].YLen:=16; GTab[16].LinBits:=1;  GTab[16].CodP:=@CT16C[0]; GTab[16].LenP:=@CT16L[0];
  GTab[17].XLen:=16; GTab[17].YLen:=16; GTab[17].LinBits:=2;  GTab[17].CodP:=@CT16C[0]; GTab[17].LenP:=@CT16L[0];
  GTab[18].XLen:=16; GTab[18].YLen:=16; GTab[18].LinBits:=3;  GTab[18].CodP:=@CT16C[0]; GTab[18].LenP:=@CT16L[0];
  GTab[19].XLen:=16; GTab[19].YLen:=16; GTab[19].LinBits:=4;  GTab[19].CodP:=@CT16C[0]; GTab[19].LenP:=@CT16L[0];
  GTab[20].XLen:=16; GTab[20].YLen:=16; GTab[20].LinBits:=6;  GTab[20].CodP:=@CT16C[0]; GTab[20].LenP:=@CT16L[0];
  GTab[21].XLen:=16; GTab[21].YLen:=16; GTab[21].LinBits:=8;  GTab[21].CodP:=@CT16C[0]; GTab[21].LenP:=@CT16L[0];
  GTab[22].XLen:=16; GTab[22].YLen:=16; GTab[22].LinBits:=10; GTab[22].CodP:=@CT16C[0]; GTab[22].LenP:=@CT16L[0];
  GTab[23].XLen:=16; GTab[23].YLen:=16; GTab[23].LinBits:=13; GTab[23].CodP:=@CT16C[0]; GTab[23].LenP:=@CT16L[0];

  { ESC tables 24–31 — share t24 arrays }
  GTab[24].XLen:=16; GTab[24].YLen:=16; GTab[24].LinBits:=4;  GTab[24].CodP:=@CT24C[0]; GTab[24].LenP:=@CT24L[0];
  GTab[25].XLen:=16; GTab[25].YLen:=16; GTab[25].LinBits:=5;  GTab[25].CodP:=@CT24C[0]; GTab[25].LenP:=@CT24L[0];
  GTab[26].XLen:=16; GTab[26].YLen:=16; GTab[26].LinBits:=6;  GTab[26].CodP:=@CT24C[0]; GTab[26].LenP:=@CT24L[0];
  GTab[27].XLen:=16; GTab[27].YLen:=16; GTab[27].LinBits:=7;  GTab[27].CodP:=@CT24C[0]; GTab[27].LenP:=@CT24L[0];
  GTab[28].XLen:=16; GTab[28].YLen:=16; GTab[28].LinBits:=8;  GTab[28].CodP:=@CT24C[0]; GTab[28].LenP:=@CT24L[0];
  GTab[29].XLen:=16; GTab[29].YLen:=16; GTab[29].LinBits:=9;  GTab[29].CodP:=@CT24C[0]; GTab[29].LenP:=@CT24L[0];
  GTab[30].XLen:=16; GTab[30].YLen:=16; GTab[30].LinBits:=11; GTab[30].CodP:=@CT24C[0]; GTab[30].LenP:=@CT24L[0];
  GTab[31].XLen:=16; GTab[31].YLen:=16; GTab[31].LinBits:=13; GTab[31].CodP:=@CT24C[0]; GTab[31].LenP:=@CT24L[0];

  { Count1 tables 32–33 }
  GTab[32].XLen:=1;  GTab[32].YLen:=16; GTab[32].CodP:=@CT32C[0]; GTab[32].LenP:=@CT32L[0];
  GTab[33].XLen:=1;  GTab[33].YLen:=16; GTab[33].CodP:=@CT33C[0]; GTab[33].LenP:=@CT33L[0];

  GInitDone := True;
end;

// ---------------------------------------------------------------------------

function HuffLinBits(ATable: Integer): Integer;
begin
  if (ATable >= 16) and (ATable <= 31) then
    Result := HUFF_LINBITS[ATable - 16]
  else
    Result := 0;
end;

// ---------------------------------------------------------------------------

function HuffEncodePair(ATable, AX, AY, ASignX, ASignY: Integer): THuffCode;
var
  H      : TTabHdr;
  cbits  : Integer;
  xbits  : Integer;
  code   : UInt64;
  ext    : UInt64;
  linbits: Integer;
  lbx, lby: Integer;
  idx    : Integer;
  cx, cy : Integer;
begin
  Result.Code := 0;
  Result.Len  := 0;

  if ATable = 0 then Exit;  { table 0 = 0 bits for (0,0) }
  if (ATable < 0) or (ATable > 31) then begin
    Result.Len := HUFF_INVALID; Exit;
  end;

  H := GTab[ATable];
  if H.CodP = nil then begin Result.Len := HUFF_INVALID; Exit; end;

  if ATable > 15 then begin
    { ESC table }
    linbits := H.LinBits;
    if (AX - 15 >= (1 shl linbits)) or (AY - 15 >= (1 shl linbits)) then begin
      Result.Len := HUFF_INVALID; Exit;
    end;
    lbx := 0; lby := 0;
    cx := AX; cy := AY;
    if cx > 14 then begin lbx := cx - 15; cx := 15; end;
    if cy > 14 then begin lby := cy - 15; cy := 15; end;
    idx   := cx * H.YLen + cy;
    code  := H.CodP[idx];
    cbits := H.LenP[idx];
    ext   := 0;
    xbits := 0;
    if AX > 14 then begin ext := UInt64(lbx);  xbits := linbits; end;
    if AX <> 0 then begin ext := (ext shl 1) or UInt64(ASignX); Inc(xbits); end;
    if AY > 14 then begin ext := (ext shl linbits) or UInt64(lby); Inc(xbits, linbits); end;
    if AY <> 0 then begin ext := (ext shl 1) or UInt64(ASignY); Inc(xbits); end;
    Result.Code := (code shl xbits) or ext;
    Result.Len  := cbits + xbits;
  end else begin
    { Non-ESC table }
    if (AX >= H.XLen) or (AY >= H.YLen) then begin Result.Len := HUFF_INVALID; Exit; end;
    idx   := AX * H.YLen + AY;
    code  := H.CodP[idx];
    cbits := H.LenP[idx];
    if AX <> 0 then begin code := (code shl 1) or UInt64(ASignX); Inc(cbits); end;
    if AY <> 0 then begin code := (code shl 1) or UInt64(ASignY); Inc(cbits); end;
    Result.Code := code;
    Result.Len  := cbits;
  end;
end;

// ---------------------------------------------------------------------------

function HuffCountPairBits(ATable, AX, AY: Integer): Integer;
var
  H      : TTabHdr;
  linbits: Integer;
  cx, cy : Integer;
  idx    : Integer;
  bits   : Integer;
begin
  if ATable = 0 then begin
    if (AX = 0) and (AY = 0) then Result := 0 else Result := HUFF_INVALID;
    Exit;
  end;
  if (ATable < 0) or (ATable > 31) then begin Result := HUFF_INVALID; Exit; end;

  H := GTab[ATable];
  if H.CodP = nil then begin Result := HUFF_INVALID; Exit; end;

  if ATable > 15 then begin
    linbits := H.LinBits;
    { ESC values must fit in linbits: 15 + (2^linbits - 1) is the maximum }
    if (AX - 15 >= (1 shl linbits)) or (AY - 15 >= (1 shl linbits)) then begin
      Result := HUFF_INVALID; Exit;
    end;
    cx := AX; cy := AY;
    if cx > 14 then cx := 15;
    if cy > 14 then cy := 15;
    idx  := cx * H.YLen + cy;
    bits := H.LenP[idx];
    if AX > 14 then Inc(bits, linbits);
    if AX <> 0 then Inc(bits);
    if AY > 14 then Inc(bits, linbits);
    if AY <> 0 then Inc(bits);
    Result := bits;
  end else begin
    if (AX >= H.XLen) or (AY >= H.YLen) then begin Result := HUFF_INVALID; Exit; end;
    idx  := AX * H.YLen + AY;
    bits := H.LenP[idx];
    if AX <> 0 then Inc(bits);
    if AY <> 0 then Inc(bits);
    Result := bits;
  end;
end;

// ---------------------------------------------------------------------------

function HuffEncodeQuad(ATable, AV, AW, AX, AY,
  ASignV, ASignW, ASignX, ASignY: Integer): THuffCode;
var
  H    : TTabHdr;
  p    : Integer;
  code : Cardinal;
  cbits: Integer;
  ext  : Cardinal;
  xbits: Integer;
begin
  Result.Code := 0;
  Result.Len  := 0;

  if (ATable <> HUFF_QUAD_A) and (ATable <> HUFF_QUAD_B) then begin
    Result.Len := HUFF_INVALID; Exit;
  end;

  H := GTab[ATable];
  p := (AV shl 3) + (AW shl 2) + (AX shl 1) + AY;   { ISO hcod index: v w x y, v most significant }
  code  := H.CodP[p];
  cbits := H.LenP[p];

  ext   := 0;
  xbits := 0;
  if AV <> 0 then begin ext := Cardinal(ASignV); xbits := 1; end;
  if AW <> 0 then begin ext := (ext shl 1) or Cardinal(ASignW); Inc(xbits); end;
  if AX <> 0 then begin ext := (ext shl 1) or Cardinal(ASignX); Inc(xbits); end;
  if AY <> 0 then begin ext := (ext shl 1) or Cardinal(ASignY); Inc(xbits); end;

  Result.Code := (code shl xbits) or ext;
  Result.Len  := cbits + xbits;
end;

// ---------------------------------------------------------------------------

function HuffCountQuadBits(ATable, AV, AW, AX, AY: Integer): Integer;
var
  H   : TTabHdr;
  p   : Integer;
  bits: Integer;
begin
  if (ATable <> HUFF_QUAD_A) and (ATable <> HUFF_QUAD_B) then begin
    Result := HUFF_INVALID; Exit;
  end;

  H    := GTab[ATable];
  p    := (AV shl 3) + (AW shl 2) + (AX shl 1) + AY;
  bits := H.LenP[p];
  if AV <> 0 then Inc(bits);
  if AW <> 0 then Inc(bits);
  if AX <> 0 then Inc(bits);
  if AY <> 0 then Inc(bits);
  Result := bits;
end;

// ---------------------------------------------------------------------------

function HuffCountRegionBits(ATable, AStart, AEnd: Integer;
  const AIx: array of Integer): Integer;
var
  i, b: Integer;
begin
  Result := 0;
  i := AStart;
  while i < AEnd do begin
    b := HuffCountPairBits(ATable, AIx[i], AIx[i + 1]);
    if b = HUFF_INVALID then begin Result := HUFF_INVALID; Exit; end;
    Inc(Result, b);
    Inc(i, 2);
  end;
end;

// ---------------------------------------------------------------------------

function HuffBestTable(AStart, AEnd: Integer;
  const AIx: array of Integer): Integer;
var
  t, bits, best, bestBits: Integer;
begin
  best     := 0;
  bestBits := MaxInt;

  { Check table 0 first — valid only when all coefficients are zero }
  bits := HuffCountRegionBits(0, AStart, AEnd, AIx);
  if bits = 0 then begin Result := 0; Exit; end;

  { Try non-ESC tables 1–15 }
  for t := 1 to 15 do begin
    if GTab[t].CodP = nil then Continue;
    bits := HuffCountRegionBits(t, AStart, AEnd, AIx);
    if (bits <> HUFF_INVALID) and (bits < bestBits) then begin
      bestBits := bits; best := t;
    end;
  end;
  Result := best;
end;

initialization
  HuffInit;

end.
