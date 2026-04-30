unit uExtract.StreamInfo;

interface

uses
  System.SysUtils, System.IOUtils;

type
  TStreamInfo = record
    Extension: string;  // lowercase, with dot — e.g. '.pdf', '.csv'
    MimeType : string;
    Charset  : string;
    FileName : string;

    class function FromFile(const AFilePath: string): TStreamInfo; static;
    class function From(const AExtension, AMimeType: string;
                        const AFileName: string = ''): TStreamInfo; static;
    function HasExtension(const AExt: string): Boolean;
    function HasAnyExtension(const AExts: array of string): Boolean;
  end;

implementation

{ TStreamInfo }

class function TStreamInfo.FromFile(const AFilePath: string): TStreamInfo;
begin
  Result.Extension := LowerCase(TPath.GetExtension(AFilePath));
  Result.FileName  := TPath.GetFileName(AFilePath);
  Result.MimeType  := '';
  Result.Charset   := '';
end;

class function TStreamInfo.From(const AExtension, AMimeType: string;
                                const AFileName: string): TStreamInfo;
begin
  Result.Extension := LowerCase(AExtension);
  if (Result.Extension <> '') and (Result.Extension[1] <> '.') then
    Result.Extension := '.' + Result.Extension;
  Result.MimeType := AMimeType;
  Result.FileName := AFileName;
  Result.Charset  := '';
end;

function TStreamInfo.HasExtension(const AExt: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(AExt);
  if (Ext <> '') and (Ext[1] <> '.') then
    Ext := '.' + Ext;
  Result := Extension = Ext;
end;

function TStreamInfo.HasAnyExtension(const AExts: array of string): Boolean;
var
  E: string;
begin
  for E in AExts do
    if HasExtension(E) then Exit(True);
  Result := False;
end;

end.
