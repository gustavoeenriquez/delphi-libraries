unit uPDF.Objects;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.Generics.Defaults,
  uPDF.Types, uPDF.Errors;

type
  TPDFObject = class;
  TPDFDictionary = class;
  TPDFStream = class;
  TPDFArray = class;

  // -------------------------------------------------------------------------
  // Object kinds (for fast type dispatch without repeated is-checks)
  // -------------------------------------------------------------------------
  TPDFObjectKind = (
    Null,
    Boolean,
    Integer,
    Real,
    String_,    // underscore avoids clash with Delphi keyword
    Name,
    Array_,
    Dictionary,
    Stream,
    Reference   // indirect object reference (not yet resolved)
  );

  // -------------------------------------------------------------------------
  // IObjectResolver — implemented by TPDFParser / TPDFDocument
  // Decouples objects from the parser so core model has no parser dependency
  // -------------------------------------------------------------------------
  IObjectResolver = interface
    ['{A3B7C1F2-4E8D-4A9B-B3C5-D2E1F7A08B4C}']
    function Resolve(const AID: TPDFObjectID): TPDFObject;
    function ResolveNumber(ANumber, AGeneration: Integer): TPDFObject;
  end;

  // -------------------------------------------------------------------------
  // Base PDF object
  // All objects are heap-allocated and owned by TPDFDocument's object pool.
  // -------------------------------------------------------------------------
  TPDFObject = class abstract
  private
    FID:       TPDFObjectID;   // non-null only for indirect objects in the file
    FResolver: IObjectResolver;
  public
    constructor Create; virtual;
    function  Kind: TPDFObjectKind; virtual; abstract;
    function  IsNull: Boolean; inline;
    function  IsBoolean: Boolean; inline;
    function  IsInteger: Boolean; inline;
    function  IsReal: Boolean; inline;
    function  IsNumber: Boolean; inline;   // Integer or Real
    function  IsString: Boolean; inline;
    function  IsName: Boolean; inline;
    function  IsArray: Boolean; inline;
    function  IsDictionary: Boolean; inline;
    function  IsStream: Boolean; inline;
    function  IsReference: Boolean; inline;

    // Convenience casts — raise EPDFTypeError if wrong kind
    function  AsBoolean: Boolean;
    function  AsInteger: Int64;
    function  AsReal: Double;
    function  AsNumber: Double;   // works for both Integer and Real
    function  AsString: RawByteString;
    function  AsUnicodeString: string;
    function  AsName: string;     // without leading '/'
    function  AsArray: TPDFArray;
    function  AsDictionary: TPDFDictionary;
    function  AsStream: TPDFStream;

    // Dereference if this is a TPDFReference; otherwise return self
    function  Dereference: TPDFObject;

    function  Clone: TPDFObject; virtual; abstract;
    function  ToDebugString: string; virtual; abstract;

    property  ID: TPDFObjectID read FID write FID;
    property  Resolver: IObjectResolver read FResolver write FResolver;
  end;

  // -------------------------------------------------------------------------
  // Null
  // -------------------------------------------------------------------------
  TPDFNull = class(TPDFObject)
  public
    function Kind: TPDFObjectKind; override;
    function Clone: TPDFObject; override;
    function ToDebugString: string; override;
    class function Instance: TPDFNull;
  private
    class var FSingleton: TPDFNull;
  end;

  // -------------------------------------------------------------------------
  // Boolean
  // -------------------------------------------------------------------------
  TPDFBoolean = class(TPDFObject)
  private
    FValue: Boolean;
  public
    constructor Create(AValue: Boolean); reintroduce;
    function Kind: TPDFObjectKind; override;
    function Value: Boolean; inline;
    function Clone: TPDFObject; override;
    function ToDebugString: string; override;
  end;

  // -------------------------------------------------------------------------
  // Integer
  // -------------------------------------------------------------------------
  TPDFInteger = class(TPDFObject)
  private
    FValue: Int64;
  public
    constructor Create(AValue: Int64); reintroduce;
    function Kind: TPDFObjectKind; override;
    function Value: Int64; inline;
    function Clone: TPDFObject; override;
    function ToDebugString: string; override;
  end;

  // -------------------------------------------------------------------------
  // Real
  // -------------------------------------------------------------------------
  TPDFReal = class(TPDFObject)
  private
    FValue: Double;
  public
    constructor Create(AValue: Double); reintroduce;
    function Kind: TPDFObjectKind; override;
    function Value: Double; inline;
    function Clone: TPDFObject; override;
    function ToDebugString: string; override;
  end;

  // -------------------------------------------------------------------------
  // String  (raw bytes — may be literal or hex encoded in source)
  // -------------------------------------------------------------------------
  TPDFString = class(TPDFObject)
  private
    FBytes:  RawByteString;
    FIsHex:  Boolean;       // was written as <hexhex> in source
  public
    constructor Create(const ABytes: RawByteString; AIsHex: Boolean = False); reintroduce;
    // Replace stored bytes after decryption (called by parser)
    procedure SetDecryptedBytes(const AData: TBytes);
    function Kind: TPDFObjectKind; override;
    function Bytes: RawByteString; inline;
    function IsHex: Boolean; inline;
    function ToUnicode: string;
    function Clone: TPDFObject; override;
    function ToDebugString: string; override;
  end;

  // -------------------------------------------------------------------------
  // Name  (stored without the leading '/')
  // -------------------------------------------------------------------------
  TPDFName = class(TPDFObject)
  private
    FValue: string;
  public
    constructor Create(const AValue: string); reintroduce;
    function Kind: TPDFObjectKind; override;
    function Value: string; inline;
    // With leading slash for serialization
    function ToRawName: string; inline;
    function Clone: TPDFObject; override;
    function ToDebugString: string; override;
  end;

  // -------------------------------------------------------------------------
  // Array
  // -------------------------------------------------------------------------
  TPDFArray = class(TPDFObject)
  private
    FItems: TObjectList<TPDFObject>;
  public
    constructor Create; override;
    destructor Destroy; override;
    function Kind: TPDFObjectKind; override;
    procedure Add(AItem: TPDFObject);
    procedure Insert(AIndex: Integer; AItem: TPDFObject);
    procedure Delete(AIndex: Integer);
    function  Count: Integer; inline;
    function  Items(AIndex: Integer): TPDFObject;
    // Dereferenced access
    function  Get(AIndex: Integer): TPDFObject;
    function  GetAsInteger(AIndex: Integer; ADefault: Int64 = 0): Int64;
    function  GetAsReal(AIndex: Integer; ADefault: Double = 0): Double;
    function  GetAsNumber(AIndex: Integer; ADefault: Double = 0): Double;
    function  GetAsName(AIndex: Integer; const ADefault: string = ''): string;
    function  Clone: TPDFObject; override;
    function  ToDebugString: string; override;
  end;

  // -------------------------------------------------------------------------
  // Dictionary
  // -------------------------------------------------------------------------
  TPDFDictionary = class(TPDFObject)
  private
    // Keys stored without '/'  — access always by bare name
    FEntries: TObjectDictionary<string, TPDFObject>;
    FKeyOrder: TList<string>;  // preserve insertion order for serialization
  public
    constructor Create; override;
    destructor Destroy; override;
    function Kind: TPDFObjectKind; override;
    procedure SetValue(const AKey: string; AValue: TPDFObject);
    procedure Remove(const AKey: string);
    function  Contains(const AKey: string): Boolean; inline;
    function  Count: Integer; inline;
    // Raw (possibly a TPDFReference)
    function  RawGet(const AKey: string): TPDFObject;
    // Dereferenced access
    function  Get(const AKey: string): TPDFObject;
    function  GetAsBoolean(const AKey: string; ADefault: Boolean = False): Boolean;
    function  GetAsInteger(const AKey: string; ADefault: Int64 = 0): Int64;
    function  GetAsReal(const AKey: string; ADefault: Double = 0): Double;
    function  GetAsNumber(const AKey: string; ADefault: Double = 0): Double;
    function  GetAsString(const AKey: string; const ADefault: RawByteString = ''): RawByteString;
    function  GetAsUnicodeString(const AKey: string; const ADefault: string = ''): string;
    function  GetAsName(const AKey: string; const ADefault: string = ''): string;
    function  GetAsArray(const AKey: string): TPDFArray;
    function  GetAsDictionary(const AKey: string): TPDFDictionary;
    function  GetRect(const AKey: string): TPDFRect;
    function  GetMatrix(const AKey: string): TPDFMatrix;
    // Iterate key/value pairs
    procedure ForEach(AProc: TProc<string, TPDFObject>);
    function  Keys: TArray<string>;
    function  Clone: TPDFObject; override;
    function  ToDebugString: string; override;
  end;

  // -------------------------------------------------------------------------
  // Stream  (dictionary + raw encoded bytes, plus decoded access)
  // -------------------------------------------------------------------------
  TPDFStream = class(TPDFObject)
  private
    FDict:               TPDFDictionary;
    FRawData:            TBytes;        // encoded (as in file)
    FDecodedData:        TBytes;        // cache of decoded bytes (lazy)
    FDecoded:            Boolean;
    FStreamOffset:       Int64;         // byte offset in source file (0 = in memory)
    FSourceStream:       TStream;       // reference to source (not owned)
    // Encryption support
    FDecryptionContext:  IDecryptionContext;
    FDecryptObjNum:      Integer;
    FDecryptGenNum:      Integer;
    procedure EnsureDecoded;
  public
    constructor Create; override;
    destructor Destroy; override;
    function Kind: TPDFObjectKind; override;
    // Attach raw encoded bytes
    procedure SetRawData(const AData: TBytes);
    // For file-backed lazy loading
    procedure SetFileSource(AStream: TStream; AOffset, ALength: Int64);
    // Attach decryption context (called by parser for encrypted documents)
    procedure SetDecryptionContext(ACtx: IDecryptionContext;
      AObjNum, AGenNum: Integer);
    // Access
    function  Dict: TPDFDictionary; inline;
    function  RawBytes: TBytes;
    function  DecodedBytes: TBytes;
    function  DecodedAsString: RawByteString;
    function  MakeDecodedStream: TBytesStream;
    function  Length: Int64;
    function  Clone: TPDFObject; override;
    function  ToDebugString: string; override;
    // Invalidate decode cache (call after modifying dict filters)
    procedure InvalidateCache;
  end;

  // -------------------------------------------------------------------------
  // Reference (indirect object — resolved lazily)
  // -------------------------------------------------------------------------
  TPDFReference = class(TPDFObject)
  private
    FRefID: TPDFObjectID;
  public
    constructor Create(const AID: TPDFObjectID); reintroduce;
    constructor CreateNum(ANumber, AGeneration: Integer); reintroduce;
    function Kind: TPDFObjectKind; override;
    function RefID: TPDFObjectID; inline;
    // Resolve using the attached Resolver; raises EPDFObjectError if no resolver
    function Resolve: TPDFObject;
    function Clone: TPDFObject; override;
    function ToDebugString: string; override;
  end;

  // -------------------------------------------------------------------------
  // Object pool — owns all TPDFObject instances for a document
  // -------------------------------------------------------------------------
  TPDFObjectPool = class
  private
    FObjects: TObjectList<TPDFObject>;
  public
    constructor Create;
    destructor Destroy; override;
    // Take ownership of AObject; returns AObject for chaining
    function  Add(AObject: TPDFObject): TPDFObject;
    function  Count: Integer;
    procedure Clear;
  end;

implementation

uses
  System.Character, System.Math, System.StrUtils,
  uPDF.Filters;  // for TPDFFilterPipeline

// -------------------------------------------------------------------------
// Helper: PDF string to Unicode
// -------------------------------------------------------------------------

function PDFStringToUnicode(const ABytes: RawByteString): string;
var
  Len: Integer;
begin
  Len := System.Length(ABytes);
  if Len = 0 then
    Exit('');

  // UTF-16 BE BOM: 0xFE 0xFF
  if (Len >= 2) and (Ord(ABytes[1]) = $FE) and (Ord(ABytes[2]) = $FF) then
  begin
    var WStr: WideString;
    SetLength(WStr, (Len - 2) div 2);
    var I := 3;
    var J := 1;
    while I < Len do
    begin
      WStr[J] := WideChar((Ord(ABytes[I]) shl 8) or Ord(ABytes[I+1]));
      Inc(I, 2);
      Inc(J);
    end;
    Result := string(WStr);
    Exit;
  end;

  // UTF-16 LE BOM: 0xFF 0xFE
  if (Len >= 2) and (Ord(ABytes[1]) = $FF) and (Ord(ABytes[2]) = $FE) then
  begin
    var WStr: WideString;
    SetLength(WStr, (Len - 2) div 2);
    var I := 3;
    var J := 1;
    while I < Len do
    begin
      WStr[J] := WideChar(Ord(ABytes[I]) or (Ord(ABytes[I+1]) shl 8));
      Inc(I, 2);
      Inc(J);
    end;
    Result := string(WStr);
    Exit;
  end;

  // Assume PDFDocEncoding (close to Latin-1 / ISO-8859-1)
  SetLength(Result, Len);
  for var I := 1 to Len do
    Result[I] := Char(Ord(ABytes[I]));
end;

// =========================================================================
// TPDFObject
// =========================================================================

constructor TPDFObject.Create;
begin
  inherited;
  FID := TPDFObjectID.Null;
end;

function TPDFObject.IsNull: Boolean;       begin Result := Kind = TPDFObjectKind.Null;       end;
function TPDFObject.IsBoolean: Boolean;    begin Result := Kind = TPDFObjectKind.Boolean;    end;
function TPDFObject.IsInteger: Boolean;    begin Result := Kind = TPDFObjectKind.Integer;    end;
function TPDFObject.IsReal: Boolean;       begin Result := Kind = TPDFObjectKind.Real;       end;
function TPDFObject.IsNumber: Boolean;     begin Result := Kind in [TPDFObjectKind.Integer, TPDFObjectKind.Real]; end;
function TPDFObject.IsString: Boolean;     begin Result := Kind = TPDFObjectKind.String_;    end;
function TPDFObject.IsName: Boolean;       begin Result := Kind = TPDFObjectKind.Name;       end;
function TPDFObject.IsArray: Boolean;      begin Result := Kind = TPDFObjectKind.Array_;     end;
function TPDFObject.IsDictionary: Boolean; begin Result := Kind = TPDFObjectKind.Dictionary; end;
function TPDFObject.IsStream: Boolean;     begin Result := Kind = TPDFObjectKind.Stream;     end;
function TPDFObject.IsReference: Boolean;  begin Result := Kind = TPDFObjectKind.Reference;  end;

function TPDFObject.AsBoolean: Boolean;
begin
  var O := Dereference;
  if O.Kind <> TPDFObjectKind.Boolean then
    raise EPDFTypeError.CreateFmt('Expected Boolean, got %s', [O.ToDebugString]);
  Result := TPDFBoolean(O).Value;
end;

function TPDFObject.AsInteger: Int64;
begin
  var O := Dereference;
  if O.Kind <> TPDFObjectKind.Integer then
    raise EPDFTypeError.CreateFmt('Expected Integer, got %s', [O.ToDebugString]);
  Result := TPDFInteger(O).Value;
end;

function TPDFObject.AsReal: Double;
begin
  var O := Dereference;
  if O.Kind <> TPDFObjectKind.Real then
    raise EPDFTypeError.CreateFmt('Expected Real, got %s', [O.ToDebugString]);
  Result := TPDFReal(O).Value;
end;

function TPDFObject.AsNumber: Double;
begin
  var O := Dereference;
  case O.Kind of
    TPDFObjectKind.Integer: Result := TPDFInteger(O).Value;
    TPDFObjectKind.Real:    Result := TPDFReal(O).Value;
  else
    raise EPDFTypeError.CreateFmt('Expected number, got %s', [O.ToDebugString]);
  end;
end;

function TPDFObject.AsString: RawByteString;
begin
  var O := Dereference;
  if O.Kind <> TPDFObjectKind.String_ then
    raise EPDFTypeError.CreateFmt('Expected String, got %s', [O.ToDebugString]);
  Result := TPDFString(O).Bytes;
end;

function TPDFObject.AsUnicodeString: string;
begin
  var O := Dereference;
  if O.Kind <> TPDFObjectKind.String_ then
    raise EPDFTypeError.CreateFmt('Expected String, got %s', [O.ToDebugString]);
  Result := TPDFString(O).ToUnicode;
end;

function TPDFObject.AsName: string;
begin
  var O := Dereference;
  if O.Kind <> TPDFObjectKind.Name then
    raise EPDFTypeError.CreateFmt('Expected Name, got %s', [O.ToDebugString]);
  Result := TPDFName(O).Value;
end;

function TPDFObject.AsArray: TPDFArray;
begin
  var O := Dereference;
  if O.Kind <> TPDFObjectKind.Array_ then
    raise EPDFTypeError.CreateFmt('Expected Array, got %s', [O.ToDebugString]);
  Result := TPDFArray(O);
end;

function TPDFObject.AsDictionary: TPDFDictionary;
begin
  var O := Dereference;
  if O.Kind <> TPDFObjectKind.Dictionary then
    raise EPDFTypeError.CreateFmt('Expected Dictionary, got %s', [O.ToDebugString]);
  Result := TPDFDictionary(O);
end;

function TPDFObject.AsStream: TPDFStream;
begin
  var O := Dereference;
  if O.Kind <> TPDFObjectKind.Stream then
    raise EPDFTypeError.CreateFmt('Expected Stream, got %s', [O.ToDebugString]);
  Result := TPDFStream(O);
end;

function TPDFObject.Dereference: TPDFObject;
begin
  if Kind = TPDFObjectKind.Reference then
    Result := TPDFReference(Self).Resolve
  else
    Result := Self;
end;

// =========================================================================
// TPDFNull
// =========================================================================

function TPDFNull.Kind: TPDFObjectKind;  begin Result := TPDFObjectKind.Null; end;
function TPDFNull.Clone: TPDFObject;     begin Result := TPDFNull.Create;      end;
function TPDFNull.ToDebugString: string; begin Result := 'null';              end;

class function TPDFNull.Instance: TPDFNull;
begin
  if FSingleton = nil then
    FSingleton := TPDFNull.Create;
  Result := FSingleton;
end;

// =========================================================================
// TPDFBoolean
// =========================================================================

constructor TPDFBoolean.Create(AValue: Boolean);
begin
  inherited Create;
  FValue := AValue;
end;

function TPDFBoolean.Kind: TPDFObjectKind;  begin Result := TPDFObjectKind.Boolean;              end;
function TPDFBoolean.Value: Boolean;         begin Result := FValue;                              end;
function TPDFBoolean.Clone: TPDFObject;      begin Result := TPDFBoolean.Create(FValue);         end;
function TPDFBoolean.ToDebugString: string;  begin Result := IfThen(FValue, 'true', 'false');    end;

// =========================================================================
// TPDFInteger
// =========================================================================

constructor TPDFInteger.Create(AValue: Int64);
begin
  inherited Create;
  FValue := AValue;
end;

function TPDFInteger.Kind: TPDFObjectKind;  begin Result := TPDFObjectKind.Integer;              end;
function TPDFInteger.Value: Int64;           begin Result := FValue;                              end;
function TPDFInteger.Clone: TPDFObject;      begin Result := TPDFInteger.Create(FValue);         end;
function TPDFInteger.ToDebugString: string;  begin Result := IntToStr(FValue);                   end;

// =========================================================================
// TPDFReal
// =========================================================================

constructor TPDFReal.Create(AValue: Double);
begin
  inherited Create;
  FValue := AValue;
end;

function TPDFReal.Kind: TPDFObjectKind;  begin Result := TPDFObjectKind.Real;                      end;
function TPDFReal.Value: Double;          begin Result := FValue;                                    end;
function TPDFReal.Clone: TPDFObject;      begin Result := TPDFReal.Create(FValue);                  end;
function TPDFReal.ToDebugString: string;  begin Result := Format('%.6g', [FValue]);                 end;

// =========================================================================
// TPDFString
// =========================================================================

constructor TPDFString.Create(const ABytes: RawByteString; AIsHex: Boolean);
begin
  inherited Create;
  FBytes := ABytes;
  FIsHex := AIsHex;
end;

function TPDFString.Kind: TPDFObjectKind; begin Result := TPDFObjectKind.String_; end;
function TPDFString.Bytes: RawByteString; begin Result := FBytes;                 end;
function TPDFString.IsHex: Boolean;       begin Result := FIsHex;                 end;

procedure TPDFString.SetDecryptedBytes(const AData: TBytes);
begin
  SetLength(FBytes, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], FBytes[1], Length(AData));
  FIsHex := False; // decrypted bytes are always stored as literal
end;

function TPDFString.ToUnicode: string;
begin
  Result := PDFStringToUnicode(FBytes);
end;

function TPDFString.Clone: TPDFObject;
begin
  Result := TPDFString.Create(FBytes, FIsHex);
end;

function TPDFString.ToDebugString: string;
begin
  if FIsHex then
    Result := '<' + string(FBytes) + '>'
  else
    Result := '(' + string(FBytes) + ')';
end;

// =========================================================================
// TPDFName
// =========================================================================

constructor TPDFName.Create(const AValue: string);
begin
  inherited Create;
  // Strip leading '/' if present
  if (AValue <> '') and (AValue[1] = '/') then
    FValue := AValue.Substring(1)
  else
    FValue := AValue;
end;

function TPDFName.Kind: TPDFObjectKind;  begin Result := TPDFObjectKind.Name;     end;
function TPDFName.Value: string;          begin Result := FValue;                  end;
function TPDFName.ToRawName: string;      begin Result := '/' + FValue;            end;
function TPDFName.Clone: TPDFObject;      begin Result := TPDFName.Create(FValue); end;
function TPDFName.ToDebugString: string;  begin Result := '/' + FValue;            end;

// =========================================================================
// TPDFArray
// =========================================================================

constructor TPDFArray.Create;
begin
  inherited;
  FItems := TObjectList<TPDFObject>.Create(True {owns objects});
end;

destructor TPDFArray.Destroy;
begin
  FItems.Free;
  inherited;
end;

function TPDFArray.Kind: TPDFObjectKind; begin Result := TPDFObjectKind.Array_; end;
function TPDFArray.Count: Integer;        begin Result := FItems.Count;          end;

procedure TPDFArray.Add(AItem: TPDFObject);
begin
  FItems.Add(AItem);
end;

procedure TPDFArray.Insert(AIndex: Integer; AItem: TPDFObject);
begin
  FItems.Insert(AIndex, AItem);
end;

procedure TPDFArray.Delete(AIndex: Integer);
begin
  FItems.Delete(AIndex);
end;

function TPDFArray.Items(AIndex: Integer): TPDFObject;
begin
  if (AIndex < 0) or (AIndex >= FItems.Count) then
    raise EPDFRangeError.CreateFmt('Array index %d out of bounds (count=%d)', [AIndex, FItems.Count]);
  Result := FItems[AIndex];
end;

function TPDFArray.Get(AIndex: Integer): TPDFObject;
begin
  Result := Items(AIndex).Dereference;
end;

function TPDFArray.GetAsInteger(AIndex: Integer; ADefault: Int64): Int64;
begin
  try
    var O := Get(AIndex);
    if O.IsNumber then Result := Round(O.AsNumber)
    else Result := ADefault;
  except
    Result := ADefault;
  end;
end;

function TPDFArray.GetAsReal(AIndex: Integer; ADefault: Double): Double;
begin
  try
    var O := Get(AIndex);
    if O.IsNumber then Result := O.AsNumber
    else Result := ADefault;
  except
    Result := ADefault;
  end;
end;

function TPDFArray.GetAsNumber(AIndex: Integer; ADefault: Double): Double;
begin
  Result := GetAsReal(AIndex, ADefault);
end;

function TPDFArray.GetAsName(AIndex: Integer; const ADefault: string): string;
begin
  try
    var O := Get(AIndex);
    if O.IsName then Result := O.AsName
    else Result := ADefault;
  except
    Result := ADefault;
  end;
end;

function TPDFArray.Clone: TPDFObject;
begin
  var R := TPDFArray.Create;
  for var I := 0 to FItems.Count - 1 do
    R.Add(FItems[I].Clone);
  Result := R;
end;

function TPDFArray.ToDebugString: string;
begin
  var SB := TStringBuilder.Create;
  try
    SB.Append('[');
    for var I := 0 to FItems.Count - 1 do
    begin
      if I > 0 then SB.Append(' ');
      SB.Append(FItems[I].ToDebugString);
    end;
    SB.Append(']');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

// =========================================================================
// TPDFDictionary
// =========================================================================

constructor TPDFDictionary.Create;
begin
  inherited;
  FEntries  := TObjectDictionary<string, TPDFObject>.Create([doOwnsValues]);
  FKeyOrder := TList<string>.Create;
end;

destructor TPDFDictionary.Destroy;
begin
  FKeyOrder.Free;
  FEntries.Free;
  inherited;
end;

function TPDFDictionary.Kind: TPDFObjectKind; begin Result := TPDFObjectKind.Dictionary; end;
function TPDFDictionary.Count: Integer;        begin Result := FEntries.Count;             end;
function TPDFDictionary.Contains(const AKey: string): Boolean; begin Result := FEntries.ContainsKey(AKey); end;

procedure TPDFDictionary.SetValue(const AKey: string; AValue: TPDFObject);
begin
  var Key := AKey.TrimLeft(['/']);
  if not FEntries.ContainsKey(Key) then
    FKeyOrder.Add(Key);
  FEntries.AddOrSetValue(Key, AValue);
end;

procedure TPDFDictionary.Remove(const AKey: string);
begin
  var Key := AKey.TrimLeft(['/']);
  FEntries.Remove(Key);
  FKeyOrder.Remove(Key);
end;

function TPDFDictionary.RawGet(const AKey: string): TPDFObject;
begin
  var Key := AKey.TrimLeft(['/']);
  if not FEntries.TryGetValue(Key, Result) then
    Result := nil;
end;

function TPDFDictionary.Get(const AKey: string): TPDFObject;
begin
  Result := RawGet(AKey);
  if Result <> nil then
    Result := Result.Dereference;
end;

function TPDFDictionary.GetAsBoolean(const AKey: string; ADefault: Boolean): Boolean;
begin
  var O := Get(AKey);
  if (O <> nil) and O.IsBoolean then Result := O.AsBoolean
  else Result := ADefault;
end;

function TPDFDictionary.GetAsInteger(const AKey: string; ADefault: Int64): Int64;
begin
  var O := Get(AKey);
  if (O <> nil) and O.IsNumber then Result := Round(O.AsNumber)
  else Result := ADefault;
end;

function TPDFDictionary.GetAsReal(const AKey: string; ADefault: Double): Double;
begin
  var O := Get(AKey);
  if (O <> nil) and O.IsNumber then Result := O.AsNumber
  else Result := ADefault;
end;

function TPDFDictionary.GetAsNumber(const AKey: string; ADefault: Double): Double;
begin
  Result := GetAsReal(AKey, ADefault);
end;

function TPDFDictionary.GetAsString(const AKey: string; const ADefault: RawByteString): RawByteString;
begin
  var O := Get(AKey);
  if (O <> nil) and O.IsString then Result := O.AsString
  else Result := ADefault;
end;

function TPDFDictionary.GetAsUnicodeString(const AKey: string; const ADefault: string): string;
begin
  var O := Get(AKey);
  if (O <> nil) and O.IsString then Result := O.AsUnicodeString
  else Result := ADefault;
end;

function TPDFDictionary.GetAsName(const AKey: string; const ADefault: string): string;
begin
  var O := Get(AKey);
  if (O <> nil) and O.IsName then Result := O.AsName
  else Result := ADefault;
end;

function TPDFDictionary.GetAsArray(const AKey: string): TPDFArray;
begin
  var O := Get(AKey);
  if (O <> nil) and O.IsArray then Result := TPDFArray(O)
  else Result := nil;
end;

function TPDFDictionary.GetAsDictionary(const AKey: string): TPDFDictionary;
begin
  var O := Get(AKey);
  if (O <> nil) and O.IsDictionary then Result := TPDFDictionary(O)
  else Result := nil;
end;

function TPDFDictionary.GetRect(const AKey: string): TPDFRect;
begin
  var A := GetAsArray(AKey);
  if (A = nil) or (A.Count < 4) then
    Exit(TPDFRect.MakeEmpty);
  Result := TPDFRect.Make(
    A.GetAsReal(0), A.GetAsReal(1),
    A.GetAsReal(2), A.GetAsReal(3)
  );
end;

function TPDFDictionary.GetMatrix(const AKey: string): TPDFMatrix;
begin
  var A := GetAsArray(AKey);
  if (A = nil) or (A.Count < 6) then
    Exit(TPDFMatrix.Identity);
  Result := TPDFMatrix.Make(
    A.GetAsReal(0), A.GetAsReal(1),
    A.GetAsReal(2), A.GetAsReal(3),
    A.GetAsReal(4), A.GetAsReal(5)
  );
end;

procedure TPDFDictionary.ForEach(AProc: TProc<string, TPDFObject>);
begin
  for var Key in FKeyOrder do
  begin
    var V: TPDFObject;
    if FEntries.TryGetValue(Key, V) then
      AProc(Key, V);
  end;
end;

function TPDFDictionary.Keys: TArray<string>;
begin
  Result := FKeyOrder.ToArray;
end;

function TPDFDictionary.Clone: TPDFObject;
begin
  var R := TPDFDictionary.Create;
  for var Key in FKeyOrder do
  begin
    var V: TPDFObject;
    if FEntries.TryGetValue(Key, V) then
      R.SetValue(Key, V.Clone);
  end;
  Result := R;
end;

function TPDFDictionary.ToDebugString: string;
begin
  var SB := TStringBuilder.Create;
  try
    SB.Append('<< ');
    for var Key in FKeyOrder do
    begin
      var V: TPDFObject;
      if FEntries.TryGetValue(Key, V) then
      begin
        SB.Append('/');
        SB.Append(Key);
        SB.Append(' ');
        SB.Append(V.ToDebugString);
        SB.Append(' ');
      end;
    end;
    SB.Append('>>');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

// =========================================================================
// TPDFStream
// =========================================================================

constructor TPDFStream.Create;
begin
  inherited;
  FDict         := TPDFDictionary.Create;
  FDecoded      := False;
  FStreamOffset := 0;
  FSourceStream := nil;
end;

destructor TPDFStream.Destroy;
begin
  FDict.Free;
  inherited;
end;

function TPDFStream.Kind: TPDFObjectKind; begin Result := TPDFObjectKind.Stream; end;
function TPDFStream.Dict: TPDFDictionary; begin Result := FDict;                 end;

procedure TPDFStream.SetRawData(const AData: TBytes);
begin
  FRawData      := AData;
  FSourceStream := nil;
  FStreamOffset := 0;
  FDecoded      := False;
  FDecodedData  := nil;
end;

procedure TPDFStream.SetFileSource(AStream: TStream; AOffset, ALength: Int64);
begin
  FSourceStream := AStream;
  FStreamOffset := AOffset;
  SetLength(FRawData, 0);
  FDict.SetValue('Length', TPDFInteger.Create(ALength));
  FDecoded     := False;
  FDecodedData := nil;
end;

function TPDFStream.RawBytes: TBytes;
begin
  // Lazy load from file source
  if (System.Length(FRawData) = 0) and (FSourceStream <> nil) then
  begin
    var Len := FDict.GetAsInteger('Length');
    if Len <= 0 then
      SetLength(FRawData, 0)
    else
    begin
      SetLength(FRawData, Len);
      FSourceStream.Position := FStreamOffset;
      FSourceStream.ReadBuffer(FRawData[0], Len);
    end;
  end;
  Result := FRawData;
end;

procedure TPDFStream.SetDecryptionContext(ACtx: IDecryptionContext;
  AObjNum, AGenNum: Integer);
begin
  FDecryptionContext := ACtx;
  FDecryptObjNum     := AObjNum;
  FDecryptGenNum     := AGenNum;
  InvalidateCache;  // force re-decode with decryption
end;

procedure TPDFStream.EnsureDecoded;
var
  ObjParms: TArray<TObject>;
begin
  if FDecoded then Exit;

  var Raw := RawBytes;

  // Step 1: decrypt before decompression (PDF encryption wraps compression)
  if (FDecryptionContext <> nil) and (FDecryptObjNum > 0) then
    Raw := FDecryptionContext.DecryptBytes(Raw, FDecryptObjNum, FDecryptGenNum, True);

  // Step 2: check for filter(s)
  var FilterObj := FDict.RawGet('Filter');
  if (FilterObj = nil) or FilterObj.IsNull then
  begin
    FDecodedData := Raw;
    FDecoded     := True;
    Exit;
  end;

  // Build list of filter names
  var Filters: TArray<string>;
  if FilterObj.IsName then
    Filters := [FilterObj.AsName]
  else if FilterObj.IsArray then
  begin
    var A := TPDFArray(FilterObj.Dereference);
    SetLength(Filters, A.Count);
    for var I := 0 to A.Count - 1 do
      Filters[I] := A.GetAsName(I);
  end;

  // Build list of decode parms (as TObject for the filter pipeline)
  var Parms: TArray<TPDFDictionary>;
  SetLength(Parms, System.Length(Filters));
  var ParmObj := FDict.RawGet('DecodeParms');
  if ParmObj <> nil then
  begin
    if ParmObj.IsDictionary then
      Parms[0] := TPDFDictionary(ParmObj.Dereference)
    else if ParmObj.IsArray then
    begin
      var PA := TPDFArray(ParmObj.Dereference);
      for var I := 0 to Min(PA.Count, System.Length(Parms)) - 1 do
        if PA.Items(I).IsDictionary then
          Parms[I] := TPDFDictionary(PA.Get(I));
    end;
  end;

  // Convert to TObject array for the filter pipeline
  SetLength(ObjParms, System.Length(Parms));
  for var I := 0 to High(Parms) do
    ObjParms[I] := Parms[I];

  // Step 3: apply filter chain
  try
    FDecodedData := TPDFFilterPipeline.Decode(Raw, Filters, ObjParms);
  except
    FDecodedData := Raw;  // fall back to raw on filter error
  end;
  FDecoded := True;
end;

function TPDFStream.DecodedBytes: TBytes;
begin
  EnsureDecoded;
  Result := FDecodedData;
end;

function TPDFStream.DecodedAsString: RawByteString;
begin
  var Data := DecodedBytes;
  SetLength(Result, System.Length(Data));
  if System.Length(Data) > 0 then
    Move(Data[0], Result[1], System.Length(Data));
end;

function TPDFStream.MakeDecodedStream: TBytesStream;
begin
  Result := TBytesStream.Create(DecodedBytes);
end;

function TPDFStream.Length: Int64;
begin
  Result := FDict.GetAsInteger('Length');
end;

procedure TPDFStream.InvalidateCache;
begin
  FDecoded     := False;
  FDecodedData := nil;
end;

function TPDFStream.Clone: TPDFObject;
begin
  var R    := TPDFStream.Create;
  R.FDict.Free;
  R.FDict  := TPDFDictionary(FDict.Clone);
  R.FRawData := Copy(FRawData);
  Result   := R;
end;

function TPDFStream.ToDebugString: string;
begin
  Result := Format('stream(%s, length=%d)', [FDict.ToDebugString, Length]);
end;

// =========================================================================
// TPDFReference
// =========================================================================

constructor TPDFReference.Create(const AID: TPDFObjectID);
begin
  inherited Create;
  FRefID := AID;
end;

constructor TPDFReference.CreateNum(ANumber, AGeneration: Integer);
begin
  Create(TPDFObjectID.Make(ANumber, AGeneration));
end;

function TPDFReference.Kind: TPDFObjectKind; begin Result := TPDFObjectKind.Reference; end;
function TPDFReference.RefID: TPDFObjectID;   begin Result := FRefID;                   end;

function TPDFReference.Resolve: TPDFObject;
begin
  if FResolver = nil then
    raise EPDFObjectError.CreateFmt(
      'Cannot resolve reference %s: no resolver attached', [FRefID.ToString]);
  Result := FResolver.Resolve(FRefID);
  if Result = nil then
    Result := TPDFNull.Instance;
end;

function TPDFReference.Clone: TPDFObject;
begin
  var R     := TPDFReference.Create(FRefID);
  R.Resolver := FResolver;
  Result    := R;
end;

function TPDFReference.ToDebugString: string;
begin
  Result := FRefID.ToString;
end;

// =========================================================================
// TPDFObjectPool
// =========================================================================

constructor TPDFObjectPool.Create;
begin
  inherited;
  FObjects := TObjectList<TPDFObject>.Create(True);
end;

destructor TPDFObjectPool.Destroy;
begin
  FObjects.Free;
  inherited;
end;

function TPDFObjectPool.Add(AObject: TPDFObject): TPDFObject;
begin
  FObjects.Add(AObject);
  Result := AObject;
end;

function TPDFObjectPool.Count: Integer;
begin
  Result := FObjects.Count;
end;

procedure TPDFObjectPool.Clear;
begin
  FObjects.Clear;
end;

initialization
  // Pre-create the null singleton
  TPDFNull.FSingleton := TPDFNull.Create;

finalization
  TPDFNull.FSingleton.Free;

end.
