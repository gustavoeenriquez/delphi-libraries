unit uPDF.Errors;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils;

type
  // -------------------------------------------------------------------------
  // Base PDF exception
  // -------------------------------------------------------------------------
  EPDFError = class(Exception)
  private
    FOffset: Int64;
  public
    constructor Create(const AMsg: string); overload;
    constructor CreateFmt(const AMsg: string; const AArgs: array of const); overload;
    constructor CreateAtOffset(const AMsg: string; AOffset: Int64); overload;
    property Offset: Int64 read FOffset write FOffset;
  end;

  // -------------------------------------------------------------------------
  // Parse errors (malformed PDF structure)
  // -------------------------------------------------------------------------
  EPDFParseError = class(EPDFError)
  private
    FLine: Integer;
  public
    constructor Create(const AMsg: string; ALine: Integer = -1); overload;
    constructor CreateFmt(const AMsg: string; const AArgs: array of const;
      ALine: Integer = -1); overload;
    property Line: Integer read FLine;
  end;

  EPDFLexError  = class(EPDFParseError);   // tokenizer-level error
  EPDFXRefError = class(EPDFParseError);   // cross-reference table error

  // -------------------------------------------------------------------------
  // Encryption / decryption errors
  // -------------------------------------------------------------------------
  EPDFEncryptionError = class(EPDFError);
  EPDFPasswordError   = class(EPDFEncryptionError);
  EPDFUnsupportedEncryptionError = class(EPDFEncryptionError);

  // -------------------------------------------------------------------------
  // Filter / stream errors
  // -------------------------------------------------------------------------
  EPDFFilterError = class(EPDFError);
  EPDFStreamError = class(EPDFError);

  // -------------------------------------------------------------------------
  // Font errors
  // -------------------------------------------------------------------------
  EPDFFontError  = class(EPDFError);

  // -------------------------------------------------------------------------
  // Rendering errors
  // -------------------------------------------------------------------------
  EPDFRenderError = class(EPDFError);

  // -------------------------------------------------------------------------
  // Object / type errors
  // -------------------------------------------------------------------------
  EPDFObjectError   = class(EPDFError);
  EPDFTypeError     = class(EPDFObjectError);   // wrong object type accessed
  EPDFRangeError    = class(EPDFObjectError);   // index out of bounds

  // -------------------------------------------------------------------------
  // Document-level errors
  // -------------------------------------------------------------------------
  EPDFDocumentError      = class(EPDFError);
  EPDFNotOpenError       = class(EPDFDocumentError);
  EPDFPageNotFoundError  = class(EPDFDocumentError);

  // -------------------------------------------------------------------------
  // Feature not yet implemented
  // -------------------------------------------------------------------------
  EPDFNotSupportedError = class(EPDFError);

implementation

// -------------------------------------------------------------------------
// EPDFError
// -------------------------------------------------------------------------

constructor EPDFError.Create(const AMsg: string);
begin
  inherited Create(AMsg);
  FOffset := -1;
end;

constructor EPDFError.CreateFmt(const AMsg: string; const AArgs: array of const);
begin
  inherited CreateFmt(AMsg, AArgs);
  FOffset := -1;
end;

constructor EPDFError.CreateAtOffset(const AMsg: string; AOffset: Int64);
begin
  inherited CreateFmt('%s (offset %d)', [AMsg, AOffset]);
  FOffset := AOffset;
end;

// -------------------------------------------------------------------------
// EPDFParseError
// -------------------------------------------------------------------------

constructor EPDFParseError.Create(const AMsg: string; ALine: Integer);
begin
  if ALine >= 0 then
    inherited CreateFmt('%s (line %d)', [AMsg, ALine])
  else
    inherited Create(AMsg);
  FLine := ALine;
end;

constructor EPDFParseError.CreateFmt(const AMsg: string;
  const AArgs: array of const; ALine: Integer);
begin
  Create(Format(AMsg, AArgs), ALine);
end;

end.
