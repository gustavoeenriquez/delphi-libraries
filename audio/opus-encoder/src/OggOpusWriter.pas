unit OggOpusWriter;

{
  OggOpusWriter.pas - Ogg Opus stream writer (RFC 7845) on top of TOpusEncoder

  Writes OpusHead (pre-skip = encoder lookahead at 48 kHz), OpusTags and the
  audio packets, with granule positions in 48 kHz samples and end trimming
  (the last granule position marks the exact end of the input), like
  opusenc/libopusenc.

  Accepts any number of samples per Write call; they are buffered into
  frames of FrameSize samples.

  Derived from libopus; distributed under the libopus BSD 3-clause license
  (full text in README.md).
}

{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, Math,
  OggPageWriter,
  OpusEncTypes,
  OpusEncoder;

type
  TOggOpusWriter = class
  private
    FStream     : TStream;
    FOwnsStream : Boolean;
    FPages      : TOggPageWriter;
    FEncoder    : TOpusEncoder;
    FSampleRate : Integer;
    FChannels   : Integer;
    FFrameSize  : Integer;     // samples per channel at FSampleRate
    FPreSkip    : Integer;     // 48 kHz samples
    FPending    : TArray<Single>;
    FPendingLen : Integer;     // samples per channel in FPending
    FInputTotal : Int64;       // input samples per channel (API rate)
    FEncodedTotal: Int64;      // encoded samples per channel (API rate)
    FPageSegs   : Integer;     // segments in the current (unflushed) page
    FPagePackets: Integer;
    FLastGranule: Int64;
    FHeadersDone: Boolean;
    FFinished   : Boolean;
    FVendor     : string;
    FComments   : TStringList;
    procedure WriteHeaders;
    procedure EncodeFrame(Pcm: PSingle; IsLast: Boolean);
    function  Granule48(Samples: Int64): Int64;
  public
    // FrameSizeMs10: frame duration in tenths of ms (25, 50, 100, 200, 400, 600)
    constructor Create(AStream: TStream; SampleRate, Channels: Integer;
      Application: TOpusApplication; FrameSizeMs10: Integer = 200;
      OwnsStream: Boolean = False);
    destructor Destroy; override;
    // Optional "TAG=value" user comments (before the first Write)
    procedure AddComment(const TagValue: string);
    procedure WriteFloat(Pcm: PSingle; Samples: Integer);     // interleaved [-1, 1]
    procedure WriteInt16(Pcm: PSmallInt; Samples: Integer);   // interleaved
    procedure Finish;   // flushes the remaining samples and writes EOS
    // Configure bitrate, complexity, etc. before the first Write
    property Encoder: TOpusEncoder read FEncoder;
    property PreSkip: Integer read FPreSkip;
    property FrameSize: Integer read FFrameSize;
    property Vendor: string read FVendor write FVendor;
  end;

implementation

const
  MAX_PAGE_SEGMENTS = 255;
  PACKETS_PER_PAGE  = 50;   // about 1 s of 20 ms packets

constructor TOggOpusWriter.Create(AStream: TStream; SampleRate, Channels: Integer;
  Application: TOpusApplication; FrameSizeMs10: Integer; OwnsStream: Boolean);
begin
  inherited Create;
  FStream := AStream;
  FOwnsStream := OwnsStream;
  FSampleRate := SampleRate;
  FChannels := Channels;
  FEncoder := TOpusEncoder.Create(SampleRate, Channels, Application);
  FFrameSize := SampleRate * FrameSizeMs10 div 10000;
  if OpusFrameSizeSelect(FFrameSize, OPUS_FRAMESIZE_ARG, SampleRate) <> FFrameSize then
    raise EArgumentException.Create('TOggOpusWriter: invalid frame size');
  FPreSkip := FEncoder.Lookahead * 48000 div SampleRate;
  SetLength(FPending, FFrameSize * Channels);
  FPages := TOggPageWriter.Create(AStream, Cardinal(TThread.GetTickCount64) xor Cardinal(NativeUInt(Self)));
  FVendor := 'delphi-libraries opus-encoder (libopus 1.5.2 port)';
  FComments := TStringList.Create;
end;

destructor TOggOpusWriter.Destroy;
begin
  FPages.Free;
  FEncoder.Free;
  FComments.Free;
  if FOwnsStream then FStream.Free;
  inherited;
end;

procedure TOggOpusWriter.AddComment(const TagValue: string);
begin
  FComments.Add(TagValue);
end;

function TOggOpusWriter.Granule48(Samples: Int64): Int64;
begin
  Result := Samples * 48000 div FSampleRate;
end;

procedure TOggOpusWriter.WriteHeaders;
var
  Head, Tags, B: TBytes;
  P, I: Integer;

  procedure Put32(V: Cardinal);
  begin
    Tags[P] := V and $FF; Tags[P + 1] := (V shr 8) and $FF;
    Tags[P + 2] := (V shr 16) and $FF; Tags[P + 3] := (V shr 24) and $FF;
    Inc(P, 4);
  end;

  procedure PutStr(const S: string);
  begin
    B := TEncoding.UTF8.GetBytes(S);
    SetLength(Tags, Length(Tags) + 4 + Length(B));
    Put32(Length(B));
    if Length(B) > 0 then Move(B[0], Tags[P], Length(B));
    Inc(P, Length(B));
  end;

begin
  // RFC 7845 section 5.1: OpusHead
  SetLength(Head, 19);
  Move(AnsiString('OpusHead')[1], Head[0], 8);
  Head[8] := 1;
  Head[9] := FChannels;
  Head[10] := FPreSkip and $FF;
  Head[11] := (FPreSkip shr 8) and $FF;
  Head[12] := FSampleRate and $FF;
  Head[13] := (FSampleRate shr 8) and $FF;
  Head[14] := (FSampleRate shr 16) and $FF;
  Head[15] := (FSampleRate shr 24) and $FF;
  Head[16] := 0;   // output gain
  Head[17] := 0;
  Head[18] := 0;   // channel mapping family 0
  FPages.WritePacket(Head, True, False, 0);

  // RFC 7845 section 5.2: OpusTags (own page)
  SetLength(Tags, 8);
  Move(AnsiString('OpusTags')[1], Tags[0], 8);
  P := 8;
  PutStr(FVendor);
  SetLength(Tags, Length(Tags) + 4);
  Put32(FComments.Count);
  for I := 0 to FComments.Count - 1 do
    PutStr(FComments[I]);
  FPages.WritePacket(Tags, False, False, 0);
  FPages.FlushPage(0);
  FHeadersDone := True;
end;

procedure TOggOpusWriter.EncodeFrame(Pcm: PSingle; IsLast: Boolean);
var
  Pkt: array[0..1499] of Byte;
  Len, Segs: Integer;
  Granule: Int64;
begin
  if not FHeadersDone then
    WriteHeaders;
  Len := FEncoder.EncodeFloat(Pcm, FFrameSize, @Pkt[0], Length(Pkt));
  if Len < 0 then
    raise Exception.CreateFmt('TOggOpusWriter: encode error %d', [Len]);
  Inc(FEncodedTotal, FFrameSize);
  Segs := Len div 255 + 1;
  // Keep every packet that completes on a page inside that page
  if (FPageSegs + Segs > MAX_PAGE_SEGMENTS) or (FPagePackets >= PACKETS_PER_PAGE) then
  begin
    FPages.FlushPage(FLastGranule);
    FPageSegs := 0;
    FPagePackets := 0;
  end;
  // Granule position: 48 kHz samples decoded (pre-skip included) up to the
  // end of this packet. End trimming: the last one marks the real input end.
  if IsLast then
    Granule := FPreSkip + Granule48(FInputTotal)
  else
    Granule := Granule48(FEncodedTotal);
  FPages.WritePacket(@Pkt[0], Len, False, IsLast, Granule);
  FLastGranule := Granule;
  Inc(FPageSegs, Segs);
  Inc(FPagePackets);
end;

procedure TOggOpusWriter.WriteFloat(Pcm: PSingle; Samples: Integer);
var
  Take: Integer;
begin
  if FFinished then
    raise Exception.Create('TOggOpusWriter: stream already finished');
  Inc(FInputTotal, Samples);
  while Samples > 0 do
  begin
    Take := Min(Samples, FFrameSize - FPendingLen);
    Move(Pcm^, FPending[FPendingLen * FChannels], Take * FChannels * SizeOf(Single));
    Inc(FPendingLen, Take);
    Inc(Pcm, Take * FChannels);
    Dec(Samples, Take);
    if FPendingLen = FFrameSize then
    begin
      EncodeFrame(@FPending[0], False);
      FPendingLen := 0;
    end;
  end;
end;

procedure TOggOpusWriter.WriteInt16(Pcm: PSmallInt; Samples: Integer);
const
  INV32768: Single = 1.0 / 32768;
var
  Tmp: TArray<Single>;
  I: Integer;
begin
  SetLength(Tmp, Samples * FChannels);
  for I := 0 to Samples * FChannels - 1 do
    Tmp[I] := INV32768 * Pcm[I];
  if Samples > 0 then
    WriteFloat(@Tmp[0], Samples);
end;

procedure TOggOpusWriter.Finish;
var
  Needed: Int64;
begin
  if FFinished then Exit;
  if not FHeadersDone then
    WriteHeaders;
  // Encode until the decoder output (minus pre-skip) covers all the input
  Needed := FInputTotal + FPreSkip * FSampleRate div 48000;
  repeat
    FillChar(FPending[FPendingLen * FChannels], (FFrameSize - FPendingLen) * FChannels * SizeOf(Single), 0);
    FPendingLen := 0;
    EncodeFrame(@FPending[0], FEncodedTotal + FFrameSize >= Needed);
  until FEncodedTotal >= Needed;
  FPages.FlushPage(FLastGranule);
  FFinished := True;
end;

end.
