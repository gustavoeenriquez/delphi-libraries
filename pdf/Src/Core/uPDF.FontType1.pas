unit uPDF.FontType1;

// Type 1 font programs (Adobe Type 1 Font Format): FontFile streams in PFA or
// PFB form, eexec and charstring decryption, Subrs and CharStrings, built-in
// encoding, and the Type 1 charstring interpreter (hsbw/sbw, flex and hint
// replacement through OtherSubrs, seac accented characters).

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Types, System.Math, System.Generics.Collections,
  uPDF.Types, uPDF.FontProgram;

type
  TType1Program = class(TPDFFontProgram)
  private
    FSubrs:       TArray<TBytes>;           // decrypted
    FCharStrings: TArray<TBytes>;           // decrypted, in program order
    FNames:       TArray<string>;
    FNameToGID:   TDictionary<string, Integer>;
    FEncoding:    array[0..255] of string;
    FHasEncoding: Boolean;
    FLastSbx:     Double;                   // side bearing of the last glyph run
    procedure ParseClearText(const AText: TBytes);
    procedure ParsePrivate(const AData: TBytes);
    procedure RunGlyph(AGID: Integer; var B: TGlyphOutlineBuilder;
      ADX, ADY: Double; ASeacDepth: Integer);
  public
    constructor Create(const AData: TBytes);
    destructor  Destroy; override;
    function  Kind: TFontProgramKind; override;
    function  GlyphCount: Integer; override;
    function  GlyphOutline(AGID: Integer): TGlyphOutline; override;
    function  GlyphByName(const AName: string): Integer; override;
    function  GlyphName(AGID: Integer): string; override;
    function  HasBuiltinEncoding: Boolean; override;
    function  BuiltinGlyphName(ACode: Integer): string; override;
  end;

implementation

uses
  uPDF.StdFonts;

const
  EEXEC_KEY      = 55665;
  CHARSTRING_KEY = 4330;
  MAX_SUBR_DEPTH = 10;
  MAX_STACK      = 48;

function Decrypt(const AData: TBytes; AStart, ALen: Integer; AKey: Word;
  ASkip: Integer): TBytes;
var
  R: Word;
  C: Byte;
begin
  R := AKey;
  SetLength(Result, Max(0, ALen - ASkip));
  for var I := 0 to ALen - 1 do
  begin
    C := AData[AStart + I];
    if I >= ASkip then
      Result[I - ASkip] := C xor (R shr 8);
    R := Word((C + R) * 52845 + 22719);
  end;
end;

function IsSpace(B: Byte): Boolean; inline;
begin
  Result := B in [0, 9, 10, 12, 13, 32];
end;

function IsDelim(B: Byte): Boolean; inline;
begin
  Result := B in [Ord('('), Ord(')'), Ord('<'), Ord('>'), Ord('['), Ord(']'),
                  Ord('{'), Ord('}'), Ord('/'), Ord('%')];
end;

function IsHex(B: Byte): Boolean; inline;
begin
  Result := B in [Ord('0')..Ord('9'), Ord('a')..Ord('f'), Ord('A')..Ord('F')];
end;

// PostScript-ish tokenizer over a byte buffer
type
  TPSTokens = record
    Data: TBytes;
    P:    Integer;
    function Next: string;
    function NextInt(out V: Integer): Boolean;
  end;

function TPSTokens.Next: string;
var
  S: Integer;
begin
  while P < Length(Data) do
  begin
    if IsSpace(Data[P]) then
      Inc(P)
    else if Data[P] = Ord('%') then
    begin
      while (P < Length(Data)) and not (Data[P] in [10, 13]) do Inc(P);
    end else
      Break;
  end;
  if P >= Length(Data) then Exit('');
  S := P;
  if Data[P] = Ord('/') then
    Inc(P)
  else if IsDelim(Data[P]) then
  begin
    Inc(P);
    Exit(Char(Data[S]));
  end;
  while (P < Length(Data)) and not IsSpace(Data[P]) and not IsDelim(Data[P]) do
    Inc(P);
  Result := TEncoding.ANSI.GetString(Data, S, P - S);
end;

function TPSTokens.NextInt(out V: Integer): Boolean;
begin
  Result := TryStrToInt(Next, V);
end;

function FindBytes(const AData: TBytes; const AText: AnsiString; AFrom: Integer): Integer;
begin
  for var I := AFrom to Length(AData) - Length(AText) do
  begin
    var Ok := True;
    for var K := 1 to Length(AText) do
      if AData[I + K - 1] <> Ord(AText[K]) then
      begin
        Ok := False;
        Break;
      end;
    if Ok then Exit(I);
  end;
  Result := -1;
end;

// =========================================================================
// TType1Program
// =========================================================================

constructor TType1Program.Create(const AData: TBytes);
var
  Data, Bin: TBytes;
  E, P: Integer;
begin
  inherited Create;
  FNameToGID := TDictionary<string, Integer>.Create;
  Data := AData;
  // PFB: segments 80 01 (ASCII) and 80 02 (binary), each with a 32-bit LE length
  if (Length(Data) > 6) and (Data[0] = $80) and (Data[1] in [1, 2]) then
  begin
    var Joined: TBytes := nil;
    P := 0;
    while (P + 6 <= Length(Data)) and (Data[P] = $80) and (Data[P + 1] in [1, 2]) do
    begin
      var L := Data[P + 2] or (Data[P + 3] shl 8) or (Data[P + 4] shl 16) or (Data[P + 5] shl 24);
      L := Min(L, Length(Data) - P - 6);
      Joined := Joined + Copy(Data, P + 6, L);
      Inc(P, 6 + L);
    end;
    Data := Joined;
  end;

  E := FindBytes(Data, 'eexec', 0);
  if E < 0 then
    raise EFontProgramError.Create('Type1: no eexec section');
  ParseClearText(Copy(Data, 0, E));
  P := E + 5;
  while (P < Length(Data)) and IsSpace(Data[P]) do Inc(P);

  // The encrypted part may be hexadecimal (PFA)
  if (P + 4 <= Length(Data)) and IsHex(Data[P]) and IsHex(Data[P + 1]) and
     IsHex(Data[P + 2]) and IsHex(Data[P + 3]) then
  begin
    SetLength(Bin, (Length(Data) - P) div 2 + 1);
    var N := 0;
    var Hi := -1;
    while P < Length(Data) do
    begin
      var C := Data[P];
      Inc(P);
      var V: Integer;
      case C of
        Ord('0')..Ord('9'): V := C - Ord('0');
        Ord('a')..Ord('f'): V := C - Ord('a') + 10;
        Ord('A')..Ord('F'): V := C - Ord('A') + 10;
      else
        if IsSpace(C) then Continue else Break;
      end;
      if Hi < 0 then Hi := V else
      begin
        Bin[N] := Hi * 16 + V;
        Inc(N);
        Hi := -1;
      end;
    end;
    SetLength(Bin, N);
  end else
    Bin := Copy(Data, P, Length(Data) - P);

  ParsePrivate(Decrypt(Bin, 0, Length(Bin), EEXEC_KEY, 4));
  if Length(FCharStrings) = 0 then
    raise EFontProgramError.Create('Type1: no CharStrings');
end;

destructor TType1Program.Destroy;
begin
  FNameToGID.Free;
  inherited;
end;

procedure TType1Program.ParseClearText(const AText: TBytes);
var
  T: TPSTokens;
  Tok: string;
begin
  T.Data := AText;
  T.P := 0;
  repeat
    Tok := T.Next;
    if Tok = '/FontMatrix' then
    begin
      var M: array[0..5] of Double;
      var Open := T.Next;
      if (Open = '[') or (Open = '{') then
      begin
        var Ok := True;
        for var I := 0 to 5 do
          Ok := Ok and TryStrToFloat(T.Next, M[I], TFormatSettings.Invariant);
        if Ok then
          FFontMatrix := TPDFMatrix.Make(M[0], M[1], M[2], M[3], M[4], M[5]);
      end;
    end
    else if Tok = '/Encoding' then
    begin
      Tok := T.Next;
      if Tok = 'StandardEncoding' then
      begin
        FHasEncoding := True;
        for var C := 0 to 255 do
          FEncoding[C] := StdEncodingGlyph(TPDFStdEncoding.Standard, C);
      end else
      begin
        // 256 array 0 1 255 {1 index exch /.notdef put} for
        // dup 32 /space put ... readonly def
        FHasEncoding := True;
        repeat
          Tok := T.Next;
          if Tok = 'dup' then
          begin
            var Code: Integer;
            if T.NextInt(Code) then
            begin
              var Name := T.Next;
              if (Code in [0..255]) and Name.StartsWith('/') then
                FEncoding[Code] := Name.Substring(1);
            end;
          end;
        until (Tok = '') or (Tok = 'def') or (Tok = 'readonly');
      end;
    end;
  until Tok = '';
end;

procedure TType1Program.ParsePrivate(const AData: TBytes);
var
  T: TPSTokens;
  Tok: string;
  LenIV: Integer;

  // "len RD <binary>": the binary starts one byte after the RD token
  function ReadBinary(ALen: Integer): TBytes;
  begin
    T.Next;                                   // RD or -|
    Inc(T.P);
    if (ALen < 0) or (T.P + ALen > Length(T.Data)) then
      raise EFontProgramError.Create('Type1: charstring past the end');
    if LenIV < 0 then
      Result := Copy(T.Data, T.P, ALen)
    else
      Result := Decrypt(T.Data, T.P, ALen, CHARSTRING_KEY, LenIV);
    Inc(T.P, ALen);
  end;

begin
  T.Data := AData;
  T.P := 0;
  LenIV := 4;
  repeat
    Tok := T.Next;
    if Tok = '/lenIV' then
    begin
      if not T.NextInt(LenIV) then LenIV := 4;
    end
    else if Tok = '/Subrs' then
    begin
      var N: Integer;
      if not T.NextInt(N) or (N < 0) or (N > 65535) then Continue;
      SetLength(FSubrs, N);
      T.Next;                                 // array
      for var K := 0 to N - 1 do
      begin
        // dup <index> <len> RD <binary> NP
        repeat
          Tok := T.Next;
        until (Tok = 'dup') or (Tok = '') or (Tok = 'ND') or (Tok = 'def') or (Tok = '|-');
        if Tok <> 'dup' then Break;
        var Idx, L: Integer;
        if not T.NextInt(Idx) or not T.NextInt(L) then Break;
        var Bin := ReadBinary(L);
        if (Idx >= 0) and (Idx < N) then FSubrs[Idx] := Bin;
      end;
    end
    else if Tok = '/CharStrings' then
    begin
      var N: Integer;
      if not T.NextInt(N) then Continue;
      repeat
        Tok := T.Next;
      until (Tok = 'begin') or (Tok = '');
      var List := TList<TBytes>.Create;
      try
        repeat
          Tok := T.Next;
          if Tok.StartsWith('/') then
          begin
            var L: Integer;
            if not T.NextInt(L) then Break;
            var Bin := ReadBinary(L);
            var Name := Tok.Substring(1);
            FNameToGID.TryAdd(Name, List.Count);
            FNames := FNames + [Name];
            List.Add(Bin);
          end;
        until (Tok = 'end') or (Tok = '');
        FCharStrings := List.ToArray;
      finally
        List.Free;
      end;
      Break;
    end;
  until Tok = '';
end;

// Type 1 charstring interpreter. The outline of AGID is appended to B,
// translated by (ADX, ADY).
procedure TType1Program.RunGlyph(AGID: Integer; var B: TGlyphOutlineBuilder;
  ADX, ADY: Double; ASeacDepth: Integer);
var
  Stack: array[0..MAX_STACK - 1] of Double;
  PS: TArray<Double>;                       // PostScript operand stack (OtherSubrs)
  SP: Integer;
  X, Y: Double;
  Flex: Boolean;
  FlexPts: TArray<TPointF>;
  Ended: Boolean;

  procedure Push(V: Double);
  begin
    if SP < MAX_STACK then
    begin
      Stack[SP] := V;
      Inc(SP);
    end;
  end;

  procedure MoveTo(DX, DY: Double);
  begin
    X := X + DX;
    Y := Y + DY;
    if Flex then
      FlexPts := FlexPts + [TPointF.Create(X, Y)]
    else
      B.MoveTo(X + ADX, Y + ADY);
  end;

  procedure LineTo(DX, DY: Double);
  begin
    X := X + DX;
    Y := Y + DY;
    B.LineTo(X + ADX, Y + ADY);
  end;

  procedure CurveTo(DXA, DYA, DXB, DYB, DXC, DYC: Double);
  var
    XA, YA, XB, YB: Double;
  begin
    XA := X + DXA;  YA := Y + DYA;
    XB := XA + DXB; YB := YA + DYB;
    X  := XB + DXC; Y  := YB + DYC;
    B.CurveTo(XA + ADX, YA + ADY, XB + ADX, YB + ADY, X + ADX, Y + ADY);
  end;

  procedure Run(const ACode: TBytes; ADepth: Integer);
  var
    P, B0: Integer;
  begin
    if ADepth > MAX_SUBR_DEPTH then
      raise EFontProgramError.Create('Type1: subroutines nested too deep');
    P := 0;
    while (P < Length(ACode)) and not Ended do
    begin
      B0 := ACode[P];
      Inc(P);
      case B0 of
        1, 3: SP := 0;                                   // hstem vstem
        4:                                               // vmoveto
        begin
          if SP >= 1 then MoveTo(0, Stack[SP - 1]);
          SP := 0;
        end;
        5:                                               // rlineto
        begin
          if SP >= 2 then LineTo(Stack[0], Stack[1]);
          SP := 0;
        end;
        6:                                               // hlineto
        begin
          if SP >= 1 then LineTo(Stack[0], 0);
          SP := 0;
        end;
        7:                                               // vlineto
        begin
          if SP >= 1 then LineTo(0, Stack[0]);
          SP := 0;
        end;
        8:                                               // rrcurveto
        begin
          if SP >= 6 then
            CurveTo(Stack[0], Stack[1], Stack[2], Stack[3], Stack[4], Stack[5]);
          SP := 0;
        end;
        9:                                               // closepath
        begin
          B.Close;
          SP := 0;
        end;
        10:                                              // callsubr
        begin
          if SP = 0 then Exit;
          Dec(SP);
          var Idx := Round(Stack[SP]);
          if (Idx < 0) or (Idx >= Length(FSubrs)) then
            raise EFontProgramError.Create('Type1: bad subroutine');
          Run(FSubrs[Idx], ADepth + 1);
        end;
        11: Exit;                                        // return
        13:                                              // hsbw
        begin
          if SP >= 2 then
          begin
            X := Stack[0];
            Y := 0;
            FLastSbx := X;
          end;
          SP := 0;
        end;
        14:                                              // endchar
        begin
          B.Close;
          Ended := True;
        end;
        21:                                              // rmoveto
        begin
          if SP >= 2 then MoveTo(Stack[0], Stack[1]);
          SP := 0;
        end;
        22:                                              // hmoveto
        begin
          if SP >= 1 then MoveTo(Stack[0], 0);
          SP := 0;
        end;
        30:                                              // vhcurveto
        begin
          if SP >= 4 then CurveTo(0, Stack[0], Stack[1], Stack[2], Stack[3], 0);
          SP := 0;
        end;
        31:                                              // hvcurveto
        begin
          if SP >= 4 then CurveTo(Stack[0], 0, Stack[1], Stack[2], 0, Stack[3]);
          SP := 0;
        end;
        12:
        begin
          if P >= Length(ACode) then Exit;
          var B1 := ACode[P];
          Inc(P);
          case B1 of
            0, 1, 2: SP := 0;                            // dotsection vstem3 hstem3
            6:                                           // seac
            begin
              if (SP >= 5) and (ASeacDepth = 0) then
              begin
                var ASB := Stack[0];
                var AccX := Stack[1];
                var AccY := Stack[2];
                var BG := GlyphByName(StdEncodingGlyph(TPDFStdEncoding.Standard, Round(Stack[3])));
                var AG := GlyphByName(StdEncodingGlyph(TPDFStdEncoding.Standard, Round(Stack[4])));
                B.Close;
                // The accent origin is relative to the base origin moved by
                // the base side bearing (as FreeType places it)
                FLastSbx := 0;
                if BG >= 0 then RunGlyph(BG, B, ADX, ADY, ASeacDepth + 1);
                var BaseSbx := FLastSbx;
                if AG >= 0 then
                  RunGlyph(AG, B, ADX + AccX - ASB + BaseSbx, ADY + AccY, ASeacDepth + 1);
              end;
              SP := 0;
              Ended := True;
            end;
            7:                                           // sbw
            begin
              if SP >= 4 then
              begin
                X := Stack[0];
                Y := Stack[1];
                FLastSbx := X;
              end;
              SP := 0;
            end;
            12:                                          // div
              if SP >= 2 then
              begin
                Dec(SP);
                if Stack[SP] <> 0 then Stack[SP - 1] := Stack[SP - 1] / Stack[SP];
              end;
            16:                                          // callothersubr
            begin
              if SP < 2 then
              begin
                SP := 0;
                Continue;
              end;
              var Other := Round(Stack[SP - 1]);
              var N := Round(Stack[SP - 2]);
              Dec(SP, 2);
              N := EnsureRange(N, 0, SP);
              // the arguments go to the PostScript stack (last one on top)
              PS := nil;
              for var K := SP - N to SP - 1 do
                PS := PS + [Stack[K]];
              Dec(SP, N);
              case Other of
                0:                                       // end of flex
                begin
                  Flex := False;
                  if Length(FlexPts) >= 7 then
                  begin
                    B.CurveTo(FlexPts[1].X + ADX, FlexPts[1].Y + ADY, FlexPts[2].X + ADX,
                      FlexPts[2].Y + ADY, FlexPts[3].X + ADX, FlexPts[3].Y + ADY);
                    B.CurveTo(FlexPts[4].X + ADX, FlexPts[4].Y + ADY, FlexPts[5].X + ADX,
                      FlexPts[5].Y + ADY, FlexPts[6].X + ADX, FlexPts[6].Y + ADY);
                    X := FlexPts[6].X;
                    Y := FlexPts[6].Y;
                  end;
                  // results: "pop pop setcurrentpoint" takes x, then y
                  PS := [Y, X];
                end;
                1:                                       // start of flex
                begin
                  Flex := True;
                  FlexPts := nil;
                  PS := nil;
                end;
                2: PS := nil;                            // flex point (taken by rmoveto)
              end;
            end;
            17:                                          // pop
              if Length(PS) > 0 then
              begin
                Push(PS[High(PS)]);
                SetLength(PS, Length(PS) - 1);
              end else
                Push(0);
            33:                                          // setcurrentpoint
            begin
              if SP >= 2 then
              begin
                X := Stack[0];
                Y := Stack[1];
              end;
              SP := 0;
            end;
          else
            SP := 0;
          end;
        end;
        32..246: Push(B0 - 139);
        247..250:
        begin
          if P < Length(ACode) then Push((B0 - 247) * 256 + ACode[P] + 108);
          Inc(P);
        end;
        251..254:
        begin
          if P < Length(ACode) then Push(-(B0 - 251) * 256 - ACode[P] - 108);
          Inc(P);
        end;
        255:
        begin
          if P + 4 <= Length(ACode) then
            Push(Integer((Cardinal(ACode[P]) shl 24) or (Cardinal(ACode[P + 1]) shl 16) or
              (Cardinal(ACode[P + 2]) shl 8) or ACode[P + 3]));
          Inc(P, 4);
        end;
      end;
    end;
  end;

begin
  if (AGID < 0) or (AGID >= Length(FCharStrings)) then Exit;
  SP := 0;
  X := 0;
  Y := 0;
  Flex := False;
  Ended := False;
  Run(FCharStrings[AGID], 0);
  B.Close;
end;

function TType1Program.Kind: TFontProgramKind;
begin
  Result := TFontProgramKind.Type1;
end;

function TType1Program.GlyphCount: Integer;
begin
  Result := Length(FCharStrings);
end;

function TType1Program.GlyphOutline(AGID: Integer): TGlyphOutline;
var
  B: TGlyphOutlineBuilder;
begin
  B.Init;
  try
    RunGlyph(AGID, B, 0, 0, 0);
  except
    on EFontProgramError do ;
  end;
  Result := B.Build;
end;

function TType1Program.GlyphByName(const AName: string): Integer;
begin
  if not FNameToGID.TryGetValue(AName, Result) then
    Result := -1;
end;

function TType1Program.GlyphName(AGID: Integer): string;
begin
  if (AGID >= 0) and (AGID < Length(FNames)) then
    Result := FNames[AGID]
  else
    Result := '';
end;

function TType1Program.HasBuiltinEncoding: Boolean;
begin
  Result := FHasEncoding;
end;

function TType1Program.BuiltinGlyphName(ACode: Integer): string;
begin
  if FHasEncoding and (ACode >= 0) and (ACode <= 255) then
    Result := FEncoding[ACode]
  else
    Result := '';
end;

end.
