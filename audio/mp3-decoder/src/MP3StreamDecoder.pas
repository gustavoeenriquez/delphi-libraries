unit MP3StreamDecoder;

{
  TMP3StreamDecoder — stream-level MP3 decoder (MPEG-1/2/2.5 Layer III).

  Wraps TMP3Layer3Decoder (frame-level) with:
    - ID3v2 tag skip at open
    - Frame-by-frame parsing via TMP3FrameParser
    - ISO 11172-3 bit reservoir management (main_data_begin)
    - Output as TAudioBuffer — planar float, normalized [-1.0 .. 1.0]

  Interface mirrors TFLACStreamDecoder / TOpusDecoder so AudioCodec.pas
  can wire it into IAudioDecoder via a thin adapter.
}

interface

uses
  SysUtils, Classes,
  AudioTypes,
  MP3Types, MP3BitStream, MP3Frame, MP3Layer3;

type
  TMP3StreamDecoder = class
  private
    const RESV_CAP = 4096;
  private
    FStream     : TStream;
    FOwns       : Boolean;
    FDecoder    : TMP3Layer3Decoder;
    FReady      : Boolean;
    FSampleRate : Cardinal;
    FChannels   : Byte;
    FResv       : TBytes;
    FResvLen    : Integer;

    class function SkipID3v2Tag(AStream: TStream): Boolean; static;
  public
    constructor Create(AStream: TStream; OwnsStream: Boolean);
    destructor  Destroy; override;

    function Decode(out Buffer: TAudioBuffer): TAudioDecodeResult;

    property Ready      : Boolean  read FReady;
    property SampleRate : Cardinal read FSampleRate;
    property Channels   : Byte     read FChannels;
  end;

implementation

class function TMP3StreamDecoder.SkipID3v2Tag(AStream: TStream): Boolean;
var
  Hdr  : array[0..9] of Byte;
  Size : Integer;
begin
  Result := False;
  if AStream.Read(Hdr[0], 10) < 10 then Exit;
  if (Hdr[0] <> Ord('I')) or (Hdr[1] <> Ord('D')) or (Hdr[2] <> Ord('3')) then
  begin
    AStream.Seek(-10, soCurrent);
    Exit;
  end;
  // Syncsafe integer size at bytes 6-9 (each byte uses only 7 bits)
  Size := (Hdr[6] shl 21) or (Hdr[7] shl 14) or (Hdr[8] shl 7) or Hdr[9];
  AStream.Seek(Size, soCurrent);
  Result := True;
end;

constructor TMP3StreamDecoder.Create(AStream: TStream; OwnsStream: Boolean);
var
  SavePos : Int64;
  Hdr     : TMP3FrameHeader;
begin
  inherited Create;
  FStream  := AStream;
  FOwns    := OwnsStream;
  FDecoder := TMP3Layer3Decoder.Create;
  SetLength(FResv, RESV_CAP);
  FResvLen := 0;

  SkipID3v2Tag(AStream);

  // Peek at first frame to populate SampleRate / Channels
  SavePos := AStream.Position;
  if TMP3FrameParser.ParseHeader(AStream, Hdr) then
  begin
    FSampleRate := Cardinal(Hdr.SampleRate);
    FChannels   := Byte(Hdr.Channels);
    FReady      := True;
  end;
  AStream.Position := SavePos;
end;

destructor TMP3StreamDecoder.Destroy;
begin
  FDecoder.Free;
  if FOwns then FStream.Free;
  inherited;
end;

function TMP3StreamDecoder.Decode(out Buffer: TAudioBuffer): TAudioDecodeResult;
var
  Hdr    : TMP3FrameHeader;
  SI     : TMP3SideInfo;
  SIBuf  : TBytes;
  SIBS   : TMP3BitStream;
  FMain  : TBytes;
  MBuf   : TBytes;
  MOfs   : Integer;
  BAfter : Integer;
  SISz   : Integer;
  Excess : Integer;
  PcmL   : TArray<Single>;
  PcmR   : TArray<Single>;

  procedure UpdateReservoir;
  begin
    if FResvLen + BAfter > RESV_CAP then
    begin
      Excess := FResvLen + BAfter - RESV_CAP;
      if Excess < FResvLen then
        Move(FResv[Excess], FResv[0], FResvLen - Excess);
      Dec(FResvLen, Excess);
      if FResvLen < 0 then FResvLen := 0;
    end;
    if BAfter > 0 then
    begin
      Move(FMain[0], FResv[FResvLen], BAfter);
      Inc(FResvLen, BAfter);
    end;
  end;

begin
  Buffer := nil;
  if not FReady then Exit(adrError);

  while True do
  begin
    if not TMP3FrameParser.ParseHeader(FStream, Hdr) then
      Exit(adrEndOfStream);

    SISz   := TMP3FrameParser.SideInfoSize(Hdr);
    BAfter := Hdr.FrameSize - 4 - SISz;
    if BAfter < 0 then Continue;

    if FStream.Position + SISz > FStream.Size then
      Exit(adrEndOfStream);

    // Parse side info
    SetLength(SIBuf, SISz);
    if SISz > 0 then FStream.ReadBuffer(SIBuf[0], SISz);
    SIBS := TMP3BitStream.Create(SIBuf);
    try
      if not TMP3FrameParser.ParseSideInfo(SIBS, Hdr, SI) then
      begin
        if BAfter > 0 then FStream.Seek(BAfter, soCurrent);
        Continue;
      end;
    finally
      SIBS.Free;
    end;

    // Read this frame's main-data contribution
    if BAfter > FStream.Size - FStream.Position then
      BAfter := Integer(FStream.Size - FStream.Position);
    SetLength(FMain, BAfter);
    if BAfter > 0 then FStream.ReadBuffer(FMain[0], BAfter);

    // Assemble main-data: [tail of reservoir] + [this frame's bytes]
    MOfs := SI.MainDataBegin;
    if MOfs > FResvLen then MOfs := FResvLen;
    SetLength(MBuf, MOfs + BAfter);
    if MOfs > 0 then
      Move(FResv[FResvLen - MOfs], MBuf[0], MOfs);
    if BAfter > 0 then
      Move(FMain[0], MBuf[MOfs], BAfter);

    // Decode frame
    PcmL := nil; PcmR := nil;
    try
      FDecoder.DecodeFrame(Hdr, SI, MBuf, 0, PcmL, PcmR);
    except
      UpdateReservoir;
      Continue;
    end;

    UpdateReservoir;

    if Length(PcmL) = 0 then Continue;

    // Build planar TAudioBuffer (already normalised to [-1..1] by DecodeFrame)
    if Hdr.Channels >= 2 then
    begin
      SetLength(Buffer, 2);
      Buffer[0] := PcmL;
      Buffer[1] := PcmR;
    end
    else
    begin
      SetLength(Buffer, 1);
      Buffer[0] := PcmL;
    end;

    Exit(adrOK);
  end;
end;

end.
