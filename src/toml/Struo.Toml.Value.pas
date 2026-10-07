{ Struo.Toml.Value -- the value tree a parsed TOML document becomes.

  Tables preserve insertion order. That is not a detail: `struo add` and the
  lockfile writer both re-emit tables, and a parser that reordered keys would
  turn every write into a noisy diff.

  Ownership is strict and simple. A value owns its children; freeing the root
  frees the document. Put and Append take ownership of what you hand them, so
  a caller never frees a value it has already stored.

  This unit knows nothing about manifests. It is a general TOML tree, and
  Struo.Manifest is what gives the keys meaning. }
unit Struo.Toml.Value;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings;

type
  TTomlKind = (tkString, tkInteger, tkFloat, tkBoolean, tkArray, tkTable);

  { Raised by the lexer, the parser and the typed accessors below. Line and
    Column are 1-based, or 0 when the error is not tied to a position. }
  ETomlError = class(Exception)
  private
    FLine: Integer;
    FColumn: Integer;
  public
    constructor CreateAt(ALine, AColumn: Integer; const AMessage: string);
    constructor CreateAtFmt(ALine, AColumn: Integer; const AFormat: string;
      const AArgs: array of const);
    property Line: Integer read FLine;
    property Column: Integer read FColumn;
  end;

  TTomlValue = class;
  TTomlValueArray = array of TTomlValue;

  TTomlValue = class
  private
    FKind: TTomlKind;
    FStr: string;
    FInt: Int64;
    FFloat: Double;
    FBool: Boolean;
    { For a table, FKeys runs parallel to FChildren. For an array, FKeys is
      empty and FChildren holds the items. }
    FKeys: TStrArray;
    FChildren: TTomlValueArray;
    FLine: Integer;
    FIsInline: Boolean;
    FIsArrayOfTables: Boolean;
    procedure Expect(AKind: TTomlKind);
  public
    class function NewString(const AValue: string): TTomlValue;
    class function NewInteger(AValue: Int64): TTomlValue;
    class function NewFloat(AValue: Double): TTomlValue;
    class function NewBoolean(AValue: Boolean): TTomlValue;
    class function NewArray: TTomlValue;
    class function NewTable: TTomlValue;

    { Builds a TOML array of strings in one call, for the writer's benefit. }
    class function NewStringArray(const AValues: array of string): TTomlValue;

    destructor Destroy; override;

    { ---- shape ---------------------------------------------------------- }

    { 'a string', 'an integer', 'a table'. Reads naturally inside an error
      message, which is the only place it is used. }
    function KindName: string;
    function IsTable: Boolean;
    function IsArray: Boolean;
    function IsScalar: Boolean;

    { Items in an array, or keys in a table. Zero for a scalar. }
    function Count: Integer;

    { ---- table access --------------------------------------------------- }

    function Has(const AKey: string): Boolean;

    { The value stored under AKey, or nil when absent. The caller does not own
      the result. }
    function Find(const AKey: string): TTomlValue;

    { As Find, but raises ETomlError naming AContext when the key is absent.
      AContext is the dotted path the caller is reading, for the message. }
    function Require(const AKey, AContext: string): TTomlValue;

    { Stores AValue under AKey, taking ownership. Replacing an existing key
      frees the value that was there. Appends when the key is new, so
      insertion order is preserved. }
    procedure Put(const AKey: string; AValue: TTomlValue);

    { Returns the table stored under AKey, creating an empty one when the key
      is absent. Raises when the key holds something that is not a table. }
    function EnsureTable(const AKey: string): TTomlValue;

    { Frees the value under AKey and closes the gap. True when it was there. }
    function Remove(const AKey: string): Boolean;

    function KeyAt(AIndex: Integer): string;

    { ---- array access --------------------------------------------------- }

    { Appends AValue, taking ownership. }
    procedure Append(AValue: TTomlValue);

    { The item or table value at AIndex. Raises when AIndex is out of range. }
    function ItemAt(AIndex: Integer): TTomlValue;

    { ---- navigation ----------------------------------------------------- }

    { Walks a dotted path such as 'profile.release.optimize', returning nil as
      soon as a step is missing or is not a table. This is how the manifest
      reader reaches nested settings without nil checks at every level. }
    function Path(const ADottedKey: string): TTomlValue;

    { ---- typed readers -------------------------------------------------- }

    { Raise ETomlError when the value is of another kind. AsFloat accepts an
      integer, since TOML writes 2 where 2.0 was meant. }
    function AsString: string;
    function AsInteger: Int64;
    function AsFloat: Double;
    function AsBoolean: Boolean;

    { Every element of an array of strings. Raises when the value is not an
      array, or holds anything but strings. A bare string yields one element,
      so `keywords = "cli"` and `keywords = ["cli"]` both work. }
    function AsStrings: TStrArray;

    { ---- typed table lookups with defaults ------------------------------ }

    { Each returns ADefault when AKey is absent, and raises when AKey is
      present but holds the wrong kind. A manifest typo should be reported,
      not silently replaced by a default. }
    function StringOr(const AKey, ADefault: string): string;
    function IntegerOr(const AKey: string; ADefault: Int64): Int64;
    function FloatOr(const AKey: string; ADefault: Double): Double;
    function BooleanOr(const AKey: string; ADefault: Boolean): Boolean;
    function StringsOr(const AKey: string; const ADefault: TStrArray): TStrArray;

    property Kind: TTomlKind read FKind;

    { The 1-based source line this value was parsed from, 0 when built in
      code. Carried so manifest validation can point at the offending line. }
    property Line: Integer read FLine write FLine;

    { True when a table was written inline, in braces, rather than under a
      [header]. The writer honours this so a round trip keeps the shape the
      author chose. }
    property IsInline: Boolean read FIsInline write FIsInline;

    { True when an array was built from [[header]] rather than from a value,
      which the writer must emit as repeated headers. }
    property IsArrayOfTables: Boolean read FIsArrayOfTables write FIsArrayOfTables;
  end;

{ 'a string' for tkString, and so on. Free-standing so error messages can name
  a kind they do not have a value for. }
function TomlKindName(AKind: TTomlKind): string;

implementation

{ ---- ETomlError ---------------------------------------------------------- }

constructor ETomlError.CreateAt(ALine, AColumn: Integer; const AMessage: string);
begin
  inherited Create(AMessage);
  FLine := ALine;
  FColumn := AColumn;
end;

constructor ETomlError.CreateAtFmt(ALine, AColumn: Integer;
  const AFormat: string; const AArgs: array of const);
begin
  CreateAt(ALine, AColumn, Format(AFormat, AArgs));
end;

{ ---- helpers ------------------------------------------------------------- }

function TomlKindName(AKind: TTomlKind): string;
begin
  case AKind of
    tkString:  Result := 'a string';
    tkInteger: Result := 'an integer';
    tkFloat:   Result := 'a float';
    tkBoolean: Result := 'a boolean';
    tkArray:   Result := 'an array';
    tkTable:   Result := 'a table';
  else
    Result := 'a value';
  end;
end;

{ ---- construction -------------------------------------------------------- }

class function TTomlValue.NewString(const AValue: string): TTomlValue;
begin
  Result := TTomlValue.Create;
  Result.FKind := tkString;
  Result.FStr := AValue;
end;

class function TTomlValue.NewInteger(AValue: Int64): TTomlValue;
begin
  Result := TTomlValue.Create;
  Result.FKind := tkInteger;
  Result.FInt := AValue;
end;

class function TTomlValue.NewFloat(AValue: Double): TTomlValue;
begin
  Result := TTomlValue.Create;
  Result.FKind := tkFloat;
  Result.FFloat := AValue;
end;

class function TTomlValue.NewBoolean(AValue: Boolean): TTomlValue;
begin
  Result := TTomlValue.Create;
  Result.FKind := tkBoolean;
  Result.FBool := AValue;
end;

class function TTomlValue.NewArray: TTomlValue;
begin
  Result := TTomlValue.Create;
  Result.FKind := tkArray;
end;

class function TTomlValue.NewTable: TTomlValue;
begin
  Result := TTomlValue.Create;
  Result.FKind := tkTable;
end;

class function TTomlValue.NewStringArray(const AValues: array of string): TTomlValue;
var
  I: Integer;
begin
  Result := NewArray;
  for I := 0 to High(AValues) do
    Result.Append(NewString(AValues[I]));
end;

destructor TTomlValue.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FChildren) do
    FChildren[I].Free;
  FChildren := nil;
  FKeys := nil;
  inherited Destroy;
end;

{ ---- shape --------------------------------------------------------------- }

procedure TTomlValue.Expect(AKind: TTomlKind);
begin
  if FKind <> AKind then
    raise ETomlError.CreateAtFmt(FLine, 0, 'expected %s, found %s',
      [TomlKindName(AKind), KindName]);
end;

function TTomlValue.KindName: string;
begin
  Result := TomlKindName(FKind);
end;

function TTomlValue.IsTable: Boolean;
begin
  Result := FKind = tkTable;
end;

function TTomlValue.IsArray: Boolean;
begin
  Result := FKind = tkArray;
end;

function TTomlValue.IsScalar: Boolean;
begin
  Result := FKind in [tkString, tkInteger, tkFloat, tkBoolean];
end;

function TTomlValue.Count: Integer;
begin
  if FKind in [tkTable, tkArray] then
    Result := Length(FChildren)
  else
    Result := 0;
end;

{ ---- table access -------------------------------------------------------- }

function TTomlValue.Has(const AKey: string): Boolean;
begin
  Result := Find(AKey) <> nil;
end;

function TTomlValue.Find(const AKey: string): TTomlValue;
var
  I: Integer;
begin
  Result := nil;
  if FKind <> tkTable then
    Exit;
  { TOML keys are case-sensitive, so this is an exact comparison. }
  for I := 0 to High(FKeys) do
    if FKeys[I] = AKey then
      Exit(FChildren[I]);
end;

function TTomlValue.Require(const AKey, AContext: string): TTomlValue;
begin
  Expect(tkTable);
  Result := Find(AKey);
  if Result = nil then
  begin
    if AContext = '' then
      raise ETomlError.CreateAtFmt(FLine, 0, 'missing required key `%s`', [AKey])
    else
      raise ETomlError.CreateAtFmt(FLine, 0, 'missing required key `%s.%s`',
        [AContext, AKey]);
  end;
end;

procedure TTomlValue.Put(const AKey: string; AValue: TTomlValue);
var
  I: Integer;
begin
  Expect(tkTable);
  for I := 0 to High(FKeys) do
    if FKeys[I] = AKey then
    begin
      { Replacing in place keeps the key where the author put it. }
      if FChildren[I] <> AValue then
      begin
        FChildren[I].Free;
        FChildren[I] := AValue;
      end;
      Exit;
    end;

  SetLength(FKeys, Length(FKeys) + 1);
  SetLength(FChildren, Length(FChildren) + 1);
  FKeys[High(FKeys)] := AKey;
  FChildren[High(FChildren)] := AValue;
end;

function TTomlValue.EnsureTable(const AKey: string): TTomlValue;
begin
  Expect(tkTable);
  Result := Find(AKey);
  if Result = nil then
  begin
    Result := NewTable;
    Put(AKey, Result);
  end
  else if not Result.IsTable then
    raise ETomlError.CreateAtFmt(Result.Line, 0,
      'expected `%s` to be a table, found %s', [AKey, Result.KindName]);
end;

function TTomlValue.Remove(const AKey: string): Boolean;
var
  I, J: Integer;
begin
  Result := False;
  if FKind <> tkTable then
    Exit;
  for I := 0 to High(FKeys) do
    if FKeys[I] = AKey then
    begin
      FChildren[I].Free;
      for J := I to High(FKeys) - 1 do
      begin
        FKeys[J] := FKeys[J + 1];
        FChildren[J] := FChildren[J + 1];
      end;
      SetLength(FKeys, Length(FKeys) - 1);
      SetLength(FChildren, Length(FChildren) - 1);
      Exit(True);
    end;
end;

function TTomlValue.KeyAt(AIndex: Integer): string;
begin
  Expect(tkTable);
  if (AIndex < 0) or (AIndex > High(FKeys)) then
    raise ETomlError.CreateAtFmt(FLine, 0,
      'table key index %d out of range (%d keys)', [AIndex, Length(FKeys)]);
  Result := FKeys[AIndex];
end;

{ ---- array access -------------------------------------------------------- }

procedure TTomlValue.Append(AValue: TTomlValue);
begin
  Expect(tkArray);
  SetLength(FChildren, Length(FChildren) + 1);
  FChildren[High(FChildren)] := AValue;
end;

function TTomlValue.ItemAt(AIndex: Integer): TTomlValue;
begin
  if not (FKind in [tkArray, tkTable]) then
    raise ETomlError.CreateAtFmt(FLine, 0,
      'expected an array or a table, found %s', [KindName]);
  if (AIndex < 0) or (AIndex > High(FChildren)) then
    raise ETomlError.CreateAtFmt(FLine, 0,
      'index %d out of range (%d items)', [AIndex, Length(FChildren)]);
  Result := FChildren[AIndex];
end;

{ ---- navigation ---------------------------------------------------------- }

function TTomlValue.Path(const ADottedKey: string): TTomlValue;
var
  LSteps: TStrArray;
  I: Integer;
begin
  Result := Self;
  LSteps := SplitStr(ADottedKey, '.');
  for I := 0 to High(LSteps) do
  begin
    if (Result = nil) or not Result.IsTable then
      Exit(nil);
    Result := Result.Find(LSteps[I]);
  end;
end;

{ ---- typed readers ------------------------------------------------------- }

function TTomlValue.AsString: string;
begin
  Expect(tkString);
  Result := FStr;
end;

function TTomlValue.AsInteger: Int64;
begin
  Expect(tkInteger);
  Result := FInt;
end;

function TTomlValue.AsFloat: Double;
begin
  { `optimize = 2` is the natural way to write a float-valued setting, so
    widening an integer here is a kindness rather than a laxity. }
  if FKind = tkInteger then
    Exit(FInt);
  Expect(tkFloat);
  Result := FFloat;
end;

function TTomlValue.AsBoolean: Boolean;
begin
  Expect(tkBoolean);
  Result := FBool;
end;

function TTomlValue.AsStrings: TStrArray;
var
  I: Integer;
begin
  Result := nil;
  { A single string stands in for a one-element array. }
  if FKind = tkString then
    Exit(StrArrayOf([FStr]));

  Expect(tkArray);
  SetLength(Result, Length(FChildren));
  for I := 0 to High(FChildren) do
  begin
    if FChildren[I].Kind <> tkString then
      raise ETomlError.CreateAtFmt(FChildren[I].Line, 0,
        'expected every element to be a string, found %s at index %d',
        [FChildren[I].KindName, I]);
    Result[I] := FChildren[I].FStr;
  end;
end;

{ ---- typed table lookups with defaults ----------------------------------- }

function TTomlValue.StringOr(const AKey, ADefault: string): string;
var
  LValue: TTomlValue;
begin
  LValue := Find(AKey);
  if LValue = nil then
    Exit(ADefault);
  Result := LValue.AsString;
end;

function TTomlValue.IntegerOr(const AKey: string; ADefault: Int64): Int64;
var
  LValue: TTomlValue;
begin
  LValue := Find(AKey);
  if LValue = nil then
    Exit(ADefault);
  Result := LValue.AsInteger;
end;

function TTomlValue.FloatOr(const AKey: string; ADefault: Double): Double;
var
  LValue: TTomlValue;
begin
  LValue := Find(AKey);
  if LValue = nil then
    Exit(ADefault);
  Result := LValue.AsFloat;
end;

function TTomlValue.BooleanOr(const AKey: string; ADefault: Boolean): Boolean;
var
  LValue: TTomlValue;
begin
  LValue := Find(AKey);
  if LValue = nil then
    Exit(ADefault);
  Result := LValue.AsBoolean;
end;

function TTomlValue.StringsOr(const AKey: string;
  const ADefault: TStrArray): TStrArray;
var
  LValue: TTomlValue;
begin
  LValue := Find(AKey);
  if LValue = nil then
    Exit(ADefault);
  Result := LValue.AsStrings;
end;

end.
