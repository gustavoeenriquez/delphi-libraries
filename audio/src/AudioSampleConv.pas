unit AudioSampleConv;

{
  AudioSampleConv.pas - PCM sample format conversions

  Converts between raw PCM integer/float formats and the internal
  normalized Single [-1.0 .. 1.0] representation used by TAudioBuffer.

  Supported source formats:
    Int8    (signed 8-bit,  range -128..127)
    UInt8   (unsigned 8-bit, range 0..255, WAV "PCM 8-bit" is unsigned)
    Int16   (signed 16-bit little-endian)
    Int24   (signed 24-bit little-endian, packed 3 bytes)
    Int32   (signed 32-bit little-endian)
    Float32 (IEEE 754 single, assumed [-1.0..1.0] or beyond — clamped on output)
    Float64 (IEEE 754 double, same semantics)

  All "ToFloat" functions produce Single in [-1.0 .. 1.0].
  All "FromFloat" functions clamp input before conversion.

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/
}

interface

// ---------------------------------------------------------------------------
// Raw integer/float → Single [-1.0..1.0]
// ---------------------------------------------------------------------------

// Unsigned 8-bit (WAV PCM 8-bit: 0..255, midpoint = 128)
function SampleUInt8ToFloat(V: Byte): Single; inline;

// Signed 8-bit (-128..127)
function SampleInt8ToFloat(V: ShortInt): Single; inline;

// Signed 16-bit (-32768..32767)
function SampleInt16ToFloat(V: SmallInt): Single; inline;

// Signed 24-bit packed in 3 bytes at P^ (little-endian)
function SampleInt24ToFloat(P: PByte): Single; inline;

// Signed 32-bit (-2147483648..2147483647)
function SampleInt32ToFloat(V: Integer): Single; inline;

// IEEE float (passed through; clamped to [-1.0..1.0] for safety)
function SampleFloat32ToFloat(V: Single): Single; inline;

// IEEE double (downcast)
function SampleFloat64ToFloat(V: Double): Single; inline;

// ---------------------------------------------------------------------------
// Single [-1.0..1.0] → raw integer/float
// ---------------------------------------------------------------------------

// → Unsigned 8-bit (WAV PCM 8-bit)
function SampleFloatToUInt8(V: Single): Byte; inline;

// → Signed 16-bit
function SampleFloatToInt16(V: Single): SmallInt; inline;

// → Signed 24-bit, written to 3 bytes at P^ (little-endian)
procedure SampleFloatToInt24(V: Single; P: PByte); inline;

// → Signed 32-bit
function SampleFloatToInt32(V: Single): Integer; inline;

// → IEEE float (passed through, clamped)
function SampleFloatToFloat32(V: Single): Single; inline;

// ---------------------------------------------------------------------------
// Block conversion helpers (interleaved input → planar TAudioBuffer channel)
// ---------------------------------------------------------------------------

// Convert a block of N interleaved Int16 samples for one channel into Dst[].
// Src points to the first sample of that channel; Stride = total channel count.
procedure BlockInt16ToFloat(Src: PSmallInt; Stride, N: Integer; Dst: PSingle);

// Convert a block of N interleaved Int24 (3-byte) samples for one channel.
// Src points to the first byte of that channel's first sample;
// ByteStride = total bytes per interleaved frame (Channels * 3).
procedure BlockInt24ToFloat(Src: PByte; ByteStride, N: Integer; Dst: PSingle);

// Convert a block of N interleaved Int32 samples for one channel.
procedure BlockInt32ToFloat(Src: PInteger; Stride, N: Integer; Dst: PSingle);

// Convert a block of N interleaved Float32 samples for one channel.
procedure BlockFloat32ToFloat(Src: PSingle; Stride, N: Integer; Dst: PSingle);

// ---------------------------------------------------------------------------
// Clamp helper (exported for reuse)
// ---------------------------------------------------------------------------

function ClampSingle(V, Lo, Hi: Single): Single; inline;
function ClampInt(V, Lo, Hi: Integer): Integer; inline;

implementation

// ---------------------------------------------------------------------------
// Clamp
// ---------------------------------------------------------------------------

function ClampSingle(V, Lo, Hi: Single): Single;
begin
  if V < Lo then Result := Lo
  else if V > Hi then Result := Hi
  else Result := V;
end;

function ClampInt(V, Lo, Hi: Integer): Integer;
begin
  if V < Lo then Result := Lo
  else if V > Hi then Result := Hi
  else Result := V;
end;

// ---------------------------------------------------------------------------
// → Single
// ---------------------------------------------------------------------------

function SampleUInt8ToFloat(V: Byte): Single;
// 0..255  →  mid=128 → 0.0;  0 → ≈-1.0;  255 → ≈+1.0
// Formula: (V - 128) / 128.0   (slightly asymmetric, matches WAV spec)
begin
  Result := (Integer(V) - 128) * (1.0 / 128.0);
end;

function SampleInt8ToFloat(V: ShortInt): Single;
begin
  Result := V * (1.0 / 128.0);
end;

function SampleInt16ToFloat(V: SmallInt): Single;
begin
  Result := V * (1.0 / 32768.0);
end;

function SampleInt24ToFloat(P: PByte): Single;
var
  Raw: Integer;
begin
  // Little-endian 24-bit signed
  Raw := Integer(P^) or (Integer((P+1)^) shl 8) or (Integer((P+2)^) shl 16);
  // Sign-extend from 24 to 32 bits
  if (Raw and $800000) <> 0 then
    Raw := Raw or Integer($FF000000);
  Result := Raw * (1.0 / 8388608.0);  // 2^23
end;

function SampleInt32ToFloat(V: Integer): Single;
begin
  Result := V * (1.0 / 2147483648.0);  // 2^31
end;

function SampleFloat32ToFloat(V: Single): Single;
begin
  Result := ClampSingle(V, -1.0, 1.0);
end;

function SampleFloat64ToFloat(V: Double): Single;
begin
  Result := ClampSingle(Single(V), -1.0, 1.0);
end;

// ---------------------------------------------------------------------------
// Single → raw
// ---------------------------------------------------------------------------

function SampleFloatToUInt8(V: Single): Byte;
var
  I: Integer;
begin
  I := Round(ClampSingle(V, -1.0, 1.0) * 128.0) + 128;
  Result := Byte(ClampInt(I, 0, 255));
end;

function SampleFloatToInt16(V: Single): SmallInt;
begin
  Result := SmallInt(ClampInt(Round(ClampSingle(V, -1.0, 1.0) * 32768.0),
    -32768, 32767));
end;

procedure SampleFloatToInt24(V: Single; P: PByte);
var
  Raw: Integer;
begin
  Raw := ClampInt(Round(ClampSingle(V, -1.0, 1.0) * 8388607.0),
    -8388608, 8388607);
  P^        := Byte(Raw and $FF);
  (P+1)^    := Byte((Raw shr 8) and $FF);
  (P+2)^    := Byte((Raw shr 16) and $FF);
end;

function SampleFloatToInt32(V: Single): Integer;
var
  D: Double;
begin
  D := ClampSingle(V, -1.0, 1.0) * 2147483647.0;
  if D > 2147483647.0 then Result := 2147483647
  else if D < -2147483648.0 then Result := -2147483648
  else Result := Round(D);
end;

function SampleFloatToFloat32(V: Single): Single;
begin
  Result := ClampSingle(V, -1.0, 1.0);
end;

// ---------------------------------------------------------------------------
// Block helpers
// ---------------------------------------------------------------------------

procedure BlockInt16ToFloat(Src: PSmallInt; Stride, N: Integer; Dst: PSingle);
var
  I: Integer;
begin
  for I := 0 to N - 1 do
  begin
    Dst^ := Src^ * (1.0 / 32768.0);
    Inc(Src, Stride);
    Inc(Dst);
  end;
end;

procedure BlockInt24ToFloat(Src: PByte; ByteStride, N: Integer; Dst: PSingle);
var
  I: Integer;
begin
  for I := 0 to N - 1 do
  begin
    Dst^ := SampleInt24ToFloat(Src);
    Inc(Src, ByteStride);
    Inc(Dst);
  end;
end;

procedure BlockInt32ToFloat(Src: PInteger; Stride, N: Integer; Dst: PSingle);
var
  I: Integer;
begin
  for I := 0 to N - 1 do
  begin
    Dst^ := Src^ * (1.0 / 2147483648.0);
    Inc(Src, Stride);
    Inc(Dst);
  end;
end;

procedure BlockFloat32ToFloat(Src: PSingle; Stride, N: Integer; Dst: PSingle);
var
  I: Integer;
begin
  for I := 0 to N - 1 do
  begin
    Dst^ := ClampSingle(Src^, -1.0, 1.0);
    Inc(Src, Stride);
    Inc(Dst);
  end;
end;

end.
