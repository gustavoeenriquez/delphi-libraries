unit uExtract.Result;

interface

type
  TConversionResult = record
    Markdown    : string;
    Title       : string;
    Success     : Boolean;
    ErrorMessage: string;
    class function Ok  (const AMarkdown: string; const ATitle: string = ''): TConversionResult; static; inline;
    class function Fail(const AError: string): TConversionResult; static; inline;
  end;

implementation

{ TConversionResult }

class function TConversionResult.Ok(const AMarkdown: string; const ATitle: string): TConversionResult;
begin
  Result.Markdown     := AMarkdown;
  Result.Title        := ATitle;
  Result.Success      := True;
  Result.ErrorMessage := '';
end;

class function TConversionResult.Fail(const AError: string): TConversionResult;
begin
  Result.Markdown     := '';
  Result.Title        := '';
  Result.Success      := False;
  Result.ErrorMessage := AError;
end;

end.
