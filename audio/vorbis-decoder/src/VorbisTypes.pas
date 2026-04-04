unit VorbisTypes;

{
  VorbisTypes.pas - Vorbis I codec types and constants

  Implements the Ogg Vorbis I data structures as defined in:
    https://xiph.org/vorbis/doc/Vorbis_I_spec.html

  Key structural facts:
    - Vorbis uses LSB-first bit packing (opposite of FLAC)
    - Three header packets: identification, comment, setup
    - Audio packets use MDCT with overlapping windows (short/long blocks)
    - Codebooks encode both Huffman scalar values and vector quantization
    - Floors shape the spectral envelope; residues encode the residual signal
    - Channel coupling uses M/S (magnitude/angle) pairs

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

uses
  SysUtils, Math;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const
  // Vorbis header packet types
  VORBIS_PACKET_IDENTIFICATION = 1;
  VORBIS_PACKET_COMMENT        = 3;
  VORBIS_PACKET_SETUP          = 5;

  // Magic bytes for header packets: "\001vorbis", "\003vorbis", "\005vorbis"
  VORBIS_HEADER_MAGIC : array[0..5] of Byte = ($76,$6F,$72,$62,$69,$73); // 'vorbis'

  // Maximum values (per spec)
  VORBIS_MAX_CHANNELS      = 255;
  VORBIS_MAX_CODEBOOKS     = 256;
  VORBIS_MAX_FLOORS        = 64;
  VORBIS_MAX_RESIDUES      = 64;
  VORBIS_MAX_MAPPINGS      = 64;
  VORBIS_MAX_MODES         = 64;

  // Codebook entry flags
  VORBIS_CB_UNUSED         = $FFFFFFFF;  // sentinel for unused entries

  // Floor type identifiers
  VORBIS_FLOOR_TYPE_0      = 0;
  VORBIS_FLOOR_TYPE_1      = 1;

  // Residue type identifiers
  VORBIS_RESIDUE_TYPE_0    = 0;
  VORBIS_RESIDUE_TYPE_1    = 1;
  VORBIS_RESIDUE_TYPE_2    = 2;

  // Window shapes (all Vorbis I windows are sine-shaped)
  VORBIS_WINDOW_SLOPE      = 0;  // only window type in Vorbis I

  // Codebook lookup types
  VORBIS_LOOKUP_NONE       = 0;
  VORBIS_LOOKUP_TYPE1      = 1;  // implicit VQ, dimensions computed from sqrt
  VORBIS_LOOKUP_TYPE2      = 2;  // explicit VQ, entry_count * dimensions values

// ---------------------------------------------------------------------------
// Codebook types
// ---------------------------------------------------------------------------

type
  // One decoded Huffman/VQ codebook
  TVorbisCodebook = record
    Dimensions      : Integer;       // vector dimension
    Entries         : Integer;       // total codeword entries
    Lengths         : TArray<Byte>;  // Huffman length per entry (0 = unused)
    // Huffman decode table (canonical huffman)
    HuffSymbols     : TArray<Integer>;  // symbol at each decode position
    HuffMinLen      : Integer;
    HuffMaxLen      : Integer;
    // Lookup table (VQ or scalar multipliers)
    LookupType      : Integer;
    MinValue        : Single;
    DeltaValue      : Single;
    ValueBits       : Integer;       // bits per multiplicand
    SequenceP       : Boolean;       // additive sequence flag
    Multiplicands   : TArray<Single>; // decoded float VQ values
    // Flat decode table for fast lookup
    // Table[code_len - HuffMinLen][code_bits] -> symbol or -1
    DecodeTable     : TArray<TArray<Integer>>;
  end;

// ---------------------------------------------------------------------------
// Floor types
// ---------------------------------------------------------------------------

type
  // Floor type 0: LSP-based (rarely used in practice, kept for completeness)
  TVorbisFloor0 = record
    Order           : Integer;
    Rate            : Integer;
    BarkMapSize     : Integer;
    AmplitudeBits   : Integer;
    AmplitudeOffset : Integer;
    NumberOfBooks   : Integer;
    BookList        : array[0..15] of Integer;
  end;

  // Floor type 1: piecewise linear interpolation (standard in Vorbis I)
  TVorbisFloor1Partition = record
    PartitionClass  : Integer;
  end;

  TVorbisFloor1Class = record
    Dimensions      : Integer;    // 1..8
    SubClasses      : Integer;    // 0..3 (actual subclasses = 1 shl SubClasses)
    MasterBook      : Integer;    // codebook index for subclass selection (-1 if SubClasses=0)
    SubClassBooks   : array[0..7] of Integer;  // codebook per subclass (-1 = unused)
  end;

  TVorbisFloor1 = record
    Partitions      : Integer;
    PartitionClassList : TArray<Integer>;   // class index per partition
    ClassCount      : Integer;
    Classes         : TArray<TVorbisFloor1Class>;
    Multiplier      : Integer;  // 1..4, step size = multiplier
    RangeBits       : Integer;  // bits per X value in list
    XList           : TArray<Integer>;  // sorted X positions (0..n-1)
    XListCount      : Integer;
    // Sorted index list (argsort of XList)
    XSorted         : TArray<Integer>;
  end;

  TVorbisFloor = record
    FloorType       : Integer;
    Floor0          : TVorbisFloor0;
    Floor1          : TVorbisFloor1;
  end;

// ---------------------------------------------------------------------------
// Residue types
// ---------------------------------------------------------------------------

type
  TVorbisResidue = record
    ResType         : Integer;       // 0, 1, or 2
    Begin_          : Cardinal;      // residue start
    End_            : Cardinal;      // residue end
    PartitionSize   : Integer;
    Classifications : Integer;       // number of classes
    ClassBook       : Integer;       // codebook for class prediction
    Books           : array[0..63, 0..7] of Integer;  // books[class][pass] (-1=unused)
    // Derived
    StageCount      : Integer;       // number of passes (max set bits in Books)
  end;

// ---------------------------------------------------------------------------
// Mapping types
// ---------------------------------------------------------------------------

type
  TVorbisMappingCoupling = record
    Magnitude       : Integer;  // channel index
    Angle           : Integer;  // channel index
  end;

  TVorbisMapping = record
    SubMaps         : Integer;
    Couplings       : Integer;
    CouplingList    : TArray<TVorbisMappingCoupling>;
    Mux             : TArray<Integer>;  // submap index per channel
    // per-submap floor and residue
    SubMapFloor     : array[0..15] of Integer;
    SubMapResidue   : array[0..15] of Integer;
  end;

// ---------------------------------------------------------------------------
// Mode types
// ---------------------------------------------------------------------------

type
  TVorbisMode = record
    BlockFlag       : Boolean;   // False = short window, True = long window
    WindowType      : Integer;   // always 0 in Vorbis I
    TransformType   : Integer;   // always 0 in Vorbis I (MDCT)
    Mapping         : Integer;   // mapping index
  end;

// ---------------------------------------------------------------------------
// Stream identification header
// ---------------------------------------------------------------------------

type
  TVorbisIdent = record
    Version         : Cardinal;
    Channels        : Byte;
    SampleRate      : Cardinal;
    BitrateMax      : Integer;
    BitrateNominal  : Integer;
    BitrateMin      : Integer;
    BlockSize0      : Integer;   // short block = 2^BlockSize0Exp
    BlockSize1      : Integer;   // long block = 2^BlockSize1Exp
    BlockSize0Exp   : Integer;   // raw exponent from header
    BlockSize1Exp   : Integer;
    FramingBit      : Boolean;
  end;

// ---------------------------------------------------------------------------
// Complete decoder setup state
// ---------------------------------------------------------------------------

type
  TVorbisSetup = record
    Ident           : TVorbisIdent;
    // Codebooks
    CodebookCount   : Integer;
    Codebooks       : TArray<TVorbisCodebook>;
    // Floors
    FloorCount      : Integer;
    Floors          : TArray<TVorbisFloor>;
    // Residues
    ResidueCount    : Integer;
    Residues        : TArray<TVorbisResidue>;
    // Mappings
    MappingCount    : Integer;
    Mappings        : TArray<TVorbisMapping>;
    // Modes
    ModeCount       : Integer;
    Modes           : TArray<TVorbisMode>;
    // Precomputed windows
    Window0         : TArray<Single>;   // short window, length = BlockSize0
    Window1         : TArray<Single>;   // long window, length = BlockSize1
    // Ready flag
    Initialized     : Boolean;
  end;

// ---------------------------------------------------------------------------
// Decode result for one audio packet
// ---------------------------------------------------------------------------

type
  TVorbisDecodeResult = (
    vdrOK,            // audio samples ready
    vdrHeader,        // header packet consumed, no audio output
    vdrEndOfStream,   // EOS reached
    vdrCorrupted,     // bit error in packet
    vdrError          // unrecoverable setup error
  );

// ---------------------------------------------------------------------------
// Float32 math helpers (ilog, float32_unpack)
// ---------------------------------------------------------------------------

// ilog(x): position of highest set bit, 0 for x=0
function VorbisILog(X: Cardinal): Integer; inline;

// Decode a Vorbis float32: sign(1) + exp(8) + mantissa(21)
function VorbisFloat32Unpack(V: Cardinal): Single; inline;

// Lookup1_values: how many values for a type-1 VQ lookup
// = floor(entries^(1/dimensions))
function VorbisLookup1Values(Entries, Dimensions: Integer): Integer;

implementation

function VorbisILog(X: Cardinal): Integer;
begin
  Result := 0;
  while X > 0 do
  begin
    Inc(Result);
    X := X shr 1;
  end;
end;

function VorbisFloat32Unpack(V: Cardinal): Single;
var
  Mantissa : Int64;
  Exponent : Integer;
begin
  // Vorbis float32: bit31=sign, bits[30..21]=exponent, bits[20..0]=mantissa
  // value = mantissa * 2^(exponent - 788 - 21)
  Mantissa := Int64(V and $1FFFFF);
  Exponent := Integer((V and $7FE00000) shr 21);
  if (V and $80000000) <> 0 then Mantissa := -Mantissa;
  Result := Mantissa * Power(2.0, Exponent - 788 - 21);
end;

function VorbisLookup1Values(Entries, Dimensions: Integer): Integer;
var
  R, I  : Integer;
  P     : Int64;
begin
  // Largest R such that R^Dimensions <= Entries
  if Dimensions <= 0 then Exit(0);
  R := Trunc(Power(Entries, 1.0 / Dimensions));
  // Clamp and search upward to correct for floating-point imprecision
  if R < 1 then R := 1;
  while True do
  begin
    P := 1;
    for I := 0 to Dimensions - 1 do
    begin
      P := P * (R + 1);
      if P > Entries then Break;
    end;
    if P <= Entries then
      Inc(R)
    else
      Break;
  end;
  Result := R;
end;

end.
