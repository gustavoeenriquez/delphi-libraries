unit uPDF.FontCMap;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  uPDF.Types, uPDF.Errors;

type
  // -------------------------------------------------------------------------
  // ToUnicode CMap parser
  //
  // A ToUnicode CMap stream looks like:
  //   /CIDInit /ProcSet findresource begin
  //   12 beginbfchar
  //   <01> <0041>          ← charcode → Unicode codepoint (hex)
  //   <02> <0042>
  //   ...
  //   endbfchar
  //   10 beginbfrange
  //   <20> <7E> <0020>     ← range: charcodes 0x20..0x7E → 0x0020..0x007E
  //   <80> <81> [<2022> <2026>]  ← range with individual target array
  //   ...
  //   endbfrange
  //   endcmap
  // -------------------------------------------------------------------------
  TPDFCMapParser = class
  public
    // Parse a ToUnicode CMap string and populate AMap: charcode → Unicode string
    class procedure ParseToUnicode(const ACMapText: string;
      AMap: TDictionary<Integer, string>); static;
  private
    class function HexToBytes(const AHex: string): TBytes; static;
    class function BytesToUnicode(const ABytes: TBytes): string; static;
    class function ParseHexToken(const AText: string; var APos: Integer): string; static;
    class function ParseToken(const AText: string; var APos: Integer): string; static;
    class procedure SkipWhitespace(const AText: string; var APos: Integer); static;
  end;

  // -------------------------------------------------------------------------
  // Predefined CMap tables (for CJK fonts)
  // Maps CID → Unicode for common CMaps.
  // Full tables are large; we provide the Identity mapping here,
  // and load external tables lazily for others.
  // -------------------------------------------------------------------------
  TPDFPredefinedCMap = class
  public
    // Returns true if CMapName is the Identity mapping (CID = Unicode)
    class function IsIdentity(const ACMapName: string): Boolean; static;
    // For known predefined CMaps, map a CID to Unicode
    class function CIDToUnicode(const ACMapName: string; ACID: Integer): string; static;
  end;

implementation

// =========================================================================
// TPDFCMapParser
// =========================================================================

class function TPDFCMapParser.HexToBytes(const AHex: string): TBytes;
var
  H, I: Integer;
begin
  SetLength(Result, Length(AHex) div 2);
  I := 0;
  H := 0;
  while H < Length(AHex) - 1 do
  begin
    var Nibble1: Integer;
    var Nibble2: Integer;
    var C1 := AHex[H + 1];
    var C2 := AHex[H + 2];
    if C1 >= 'a' then Nibble1 := Ord(C1) - Ord('a') + 10
    else if C1 >= 'A' then Nibble1 := Ord(C1) - Ord('A') + 10
    else Nibble1 := Ord(C1) - Ord('0');
    if C2 >= 'a' then Nibble2 := Ord(C2) - Ord('a') + 10
    else if C2 >= 'A' then Nibble2 := Ord(C2) - Ord('A') + 10
    else Nibble2 := Ord(C2) - Ord('0');
    Result[I] := (Nibble1 shl 4) or Nibble2;
    Inc(I);
    Inc(H, 2);
  end;
  SetLength(Result, I);
end;

class function TPDFCMapParser.BytesToUnicode(const ABytes: TBytes): string;
begin
  if Length(ABytes) = 0 then Exit('');
  if Length(ABytes) = 1 then
    Exit(Char(ABytes[0]));
  if Length(ABytes) = 2 then
  begin
    var CodePoint := (Integer(ABytes[0]) shl 8) or ABytes[1];
    // Check for surrogate pair range (supplementary planes)
    if (CodePoint >= $D800) and (CodePoint <= $DFFF) then
      Exit('') // invalid
    else
      Exit(Char(CodePoint));
  end;
  if Length(ABytes) = 4 then
  begin
    // Possible UTF-32 BE or surrogate pair
    var Hi := (Integer(ABytes[0]) shl 8) or ABytes[1];
    var Lo := (Integer(ABytes[2]) shl 8) or ABytes[3];
    if (Hi >= $D800) and (Hi <= $DBFF) and (Lo >= $DC00) and (Lo <= $DFFF) then
    begin
      // Surrogate pair → supplementary character
      var CodePoint := $10000 + ((Hi - $D800) shl 10) + (Lo - $DC00);
      Result := Char($D800 + ((CodePoint - $10000) shr 10)) +
                Char($DC00 + ((CodePoint - $10000) and $3FF));
      Exit;
    end;
    Exit(Char(Hi) + Char(Lo));
  end;
  // Fallback: convert each byte pair as UTF-16 BE
  Result := '';
  var I := 0;
  while I < Length(ABytes) - 1 do
  begin
    var CP := (Integer(ABytes[I]) shl 8) or ABytes[I + 1];
    Result := Result + Char(CP);
    Inc(I, 2);
  end;
end;

class procedure TPDFCMapParser.SkipWhitespace(const AText: string; var APos: Integer);
begin
  while (APos <= Length(AText)) and (AText[APos] in [' ', #9, #10, #13]) do
    Inc(APos);
end;

class function TPDFCMapParser.ParseHexToken(const AText: string; var APos: Integer): string;
// Reads <hexhex> token, returns the hex content (without angle brackets)
begin
  Result := '';
  if (APos > Length(AText)) or (AText[APos] <> '<') then Exit;
  Inc(APos);
  var Start := APos;
  while (APos <= Length(AText)) and (AText[APos] <> '>') do
    Inc(APos);
  Result := AText.Substring(Start - 1, APos - Start);
  if APos <= Length(AText) then Inc(APos); // skip '>'
end;

class function TPDFCMapParser.ParseToken(const AText: string; var APos: Integer): string;
// Reads until whitespace or '<' or '['  or ']'
begin
  SkipWhitespace(AText, APos);
  Result := '';
  while (APos <= Length(AText)) and not (AText[APos] in [' ', #9, #10, #13, '<', '[', ']']) do
  begin
    Result := Result + AText[APos];
    Inc(APos);
  end;
end;

class procedure TPDFCMapParser.ParseToUnicode(const ACMapText: string;
  AMap: TDictionary<Integer, string>);
var
  Pos:    Integer;
  Token:  string;
begin
  Pos := 1;
  while Pos <= Length(ACMapText) do
  begin
    SkipWhitespace(ACMapText, Pos);
    if Pos > Length(ACMapText) then Break;

    if ACMapText[Pos] = '<' then
    begin
      // Skip hex tokens outside of bf sections (e.g. in codespacerange)
      ParseHexToken(ACMapText, Pos);
      Continue;
    end;

    if ACMapText[Pos] = '%' then
    begin
      // Comment: skip to EOL
      while (Pos <= Length(ACMapText)) and not (ACMapText[Pos] in [#10, #13]) do
        Inc(Pos);
      Continue;
    end;

    Token := ParseToken(ACMapText, Pos);
    if Token = '' then
    begin
      Inc(Pos);
      Continue;
    end;

    if Token = 'beginbfchar' then
    begin
      // Read pairs: <srcHex> <dstHex>
      while Pos <= Length(ACMapText) do
      begin
        SkipWhitespace(ACMapText, Pos);
        if Pos > Length(ACMapText) then Break;
        if ACMapText[Pos] <> '<' then
        begin
          var CheckToken := ParseToken(ACMapText, Pos);
          if CheckToken = 'endbfchar' then Break;
          Continue;
        end;
        var SrcHex := ParseHexToken(ACMapText, Pos);
        SkipWhitespace(ACMapText, Pos);
        if (Pos > Length(ACMapText)) or (ACMapText[Pos] <> '<') then Continue;
        var DstHex := ParseHexToken(ACMapText, Pos);
        if (SrcHex = '') or (DstHex = '') then Continue;
        var SrcBytes := HexToBytes(SrcHex);
        var DstBytes := HexToBytes(DstHex);
        var CharCode := 0;
        for var B in SrcBytes do
          CharCode := (CharCode shl 8) or B;
        var Unicode := BytesToUnicode(DstBytes);
        AMap.AddOrSetValue(CharCode, Unicode);
      end;
    end
    else if Token = 'beginbfrange' then
    begin
      // Read triples: <srcStart> <srcEnd> <dstStart>  or  <srcStart> <srcEnd> [<u1> <u2> ...]
      while Pos <= Length(ACMapText) do
      begin
        SkipWhitespace(ACMapText, Pos);
        if Pos > Length(ACMapText) then Break;
        if ACMapText[Pos] <> '<' then
        begin
          var CheckToken := ParseToken(ACMapText, Pos);
          if CheckToken = 'endbfrange' then Break;
          Continue;
        end;
        var StartHex := ParseHexToken(ACMapText, Pos);
        SkipWhitespace(ACMapText, Pos);
        if (Pos > Length(ACMapText)) or (ACMapText[Pos] <> '<') then Continue;
        var EndHex := ParseHexToken(ACMapText, Pos);
        SkipWhitespace(ACMapText, Pos);
        if Pos > Length(ACMapText) then Break;

        var StartBytes := HexToBytes(StartHex);
        var EndBytes   := HexToBytes(EndHex);
        var StartCode  := 0; var EndCode := 0;
        for var B in StartBytes do StartCode := (StartCode shl 8) or B;
        for var B in EndBytes   do EndCode   := (EndCode   shl 8) or B;

        if ACMapText[Pos] = '[' then
        begin
          // Array of individual mappings
          Inc(Pos); // skip '['
          var Code := StartCode;
          while Pos <= Length(ACMapText) do
          begin
            SkipWhitespace(ACMapText, Pos);
            if (Pos > Length(ACMapText)) or (ACMapText[Pos] = ']') then
            begin
              if Pos <= Length(ACMapText) then Inc(Pos);
              Break;
            end;
            if ACMapText[Pos] = '<' then
            begin
              var DstHex := ParseHexToken(ACMapText, Pos);
              var Unicode := BytesToUnicode(HexToBytes(DstHex));
              if Code <= EndCode then
              begin
                AMap.AddOrSetValue(Code, Unicode);
                Inc(Code);
              end;
            end else
              Inc(Pos);
          end;
        end
        else if ACMapText[Pos] = '<' then
        begin
          // Single start Unicode, increment for range
          var DstHex   := ParseHexToken(ACMapText, Pos);
          var DstBytes := HexToBytes(DstHex);
          var DstCode  := 0;
          for var B in DstBytes do
            DstCode := (DstCode shl 8) or B;
          for var Code := StartCode to EndCode do
          begin
            AMap.AddOrSetValue(Code, Char(DstCode + (Code - StartCode)));
          end;
        end else
        begin
          // Unexpected — skip token
          ParseToken(ACMapText, Pos);
        end;
      end;
    end;
  end;
end;

// =========================================================================
// TPDFPredefinedCMap
// =========================================================================

class function TPDFPredefinedCMap.IsIdentity(const ACMapName: string): Boolean;
begin
  Result := (ACMapName = 'Identity-H') or (ACMapName = 'Identity-V');
end;

class function TPDFPredefinedCMap.CIDToUnicode(const ACMapName: string;
  ACID: Integer): string;
begin
  if IsIdentity(ACMapName) then
    Result := Char(ACID)
  else
    Result := Char(ACID); // default: treat CID as Unicode codepoint
end;

end.
