{ Struo.Toml.Parser -- tokens into a value tree.

  Supports what a Struo manifest and lockfile need: comments, bare, quoted and
  dotted keys, [table] and [[array of table]] headers, strings, integers,
  floats, booleans, arrays, and inline tables. Dates and multi-line strings
  are rejected with a message saying so rather than mis-parsed.

  The parser is deliberately strict about the mistakes that cost time:
  a table header written twice, a key assigned twice, and two pairs crammed
  onto one line are all errors with a line and column, not surprises that
  surface three commands later. }
unit Struo.Toml.Parser;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings, Struo.Toml.Value, Struo.Toml.Lexer;

{ Parses ASource into a table. The caller owns the result and must free it.
  Raises ETomlError, carrying a line and column, on malformed input. }
function ParseToml(const ASource: string): TTomlValue;

{ Reads APath and parses it. ETomlError messages are prefixed with the file
  name, so they read as `Struo.toml:12:5: ...` once rendered. }
function ParseTomlFile(const APath: string): TTomlValue;

implementation

uses
  Struo.Util.Fs;

type
  TTomlParser = class
  private
    FLexer: TTomlLexer;
    FToken: TTomlToken;
    FRoot: TTomlValue;
    { Where bare key-value pairs currently land: the root, or the table named
      by the most recent header. }
    FCurrent: TTomlValue;
    { Dotted paths already opened by a [header], so a repeat can be caught.
      Array-of-table headers are exempt, since repeating them is the point. }
    FHeaders: TStrArray;

    procedure NextToken;
    function Accept(AKind: TTomlTokenKind): Boolean;
    procedure Consume(AKind: TTomlTokenKind);
    procedure SkipNewlines;
    procedure Fail(const AMessage: string);
    procedure FailFmt(const AFormat: string; const AArgs: array of const);

    function ParseKeyPath: TStrArray;
    function ParseValue: TTomlValue;
    function ParseArray: TTomlValue;
    function ParseInlineTable: TTomlValue;
    procedure ParseTableHeader;
    procedure ParseKeyValue(ATarget: TTomlValue);

    { Walks APath from the root, creating tables as needed, and returns the
      table that ACount steps in. Stops into the last element of an array of
      tables, which is how [bin.meta] after [[bin]] finds its home. }
    function Descend(const APath: TStrArray; ACount: Integer): TTomlValue;
  public
    constructor Create(const ASource: string);
    destructor Destroy; override;
    function Parse: TTomlValue;
  end;

{ ---- construction -------------------------------------------------------- }

constructor TTomlParser.Create(const ASource: string);
begin
  inherited Create;
  FLexer := TTomlLexer.Create(ASource);
  FRoot := TTomlValue.NewTable;
  FCurrent := FRoot;
  NextToken;
end;

destructor TTomlParser.Destroy;
begin
  FLexer.Free;
  { Non-nil only when Parse did not run to completion, so this is the
    exception path cleaning up a half-built document. }
  FRoot.Free;
  inherited Destroy;
end;

{ ---- token plumbing ------------------------------------------------------ }

procedure TTomlParser.NextToken;
begin
  FToken := FLexer.Next;
end;

function TTomlParser.Accept(AKind: TTomlTokenKind): Boolean;
begin
  Result := FToken.Kind = AKind;
  if Result then
    NextToken;
end;

procedure TTomlParser.Consume(AKind: TTomlTokenKind);
begin
  if FToken.Kind <> AKind then
    FailFmt('expected %s, found %s',
      [TomlTokenName(AKind), TomlTokenName(FToken.Kind)]);
  NextToken;
end;

procedure TTomlParser.SkipNewlines;
begin
  while FToken.Kind = ttNewline do
    NextToken;
end;

procedure TTomlParser.Fail(const AMessage: string);
begin
  raise ETomlError.CreateAt(FToken.Line, FToken.Column, AMessage);
end;

procedure TTomlParser.FailFmt(const AFormat: string; const AArgs: array of const);
begin
  Fail(Format(AFormat, AArgs));
end;

{ ---- keys ---------------------------------------------------------------- }

function TTomlParser.ParseKeyPath: TStrArray;
begin
  Result := nil;
  repeat
    case FToken.Kind of
      ttAtom:
        begin
          if not IsBareKey(FToken.Text) then
            FailFmt('`%s` is not a valid bare key; quote it', [FToken.Text]);
          StrArrayAdd(Result, FToken.Text);
        end;
      ttString:
        begin
          if FToken.Text = '' then
            Fail('a key cannot be empty');
          StrArrayAdd(Result, FToken.Text);
        end;
    else
      FailFmt('expected a key, found %s', [TomlTokenName(FToken.Kind)]);
    end;
    NextToken;
  until not Accept(ttDot);
end;

{ ---- values -------------------------------------------------------------- }

function TTomlParser.ParseValue: TTomlValue;
var
  LIsFloat, LBool: Boolean;
  LInteger: Int64;
  LFloat: Double;
  LLine: Integer;
begin
  LLine := FToken.Line;

  case FToken.Kind of
    ttString:
      begin
        Result := TTomlValue.NewString(FToken.Text);
        NextToken;
      end;
    ttLBracket:
      Result := ParseArray;
    ttLBrace:
      Result := ParseInlineTable;
    ttAtom:
      begin
        if TryParseBoolean(FToken.Text, LBool) then
          Result := TTomlValue.NewBoolean(LBool)
        else if TryParseNumber(FToken.Text, LIsFloat, LInteger, LFloat) then
        begin
          if LIsFloat then
            Result := TTomlValue.NewFloat(LFloat)
          else
            Result := TTomlValue.NewInteger(LInteger);
        end
        else
        begin
          { The two ways to get here are a date, which we do not support, and
            an unquoted string, which is the commonest manifest typo of all.
            Both deserve to be named. }
          if (Length(FToken.Text) >= 8) and (Pos('-', FToken.Text) > 1) then
            FailFmt('dates are not supported; `%s` must be quoted to be a string',
              [FToken.Text])
          else
            FailFmt('expected a value, found `%s`; quote it to make it a string',
              [FToken.Text]);
          Result := nil; // unreachable: Fail always raises
        end;
        NextToken;
      end;
  else
    FailFmt('expected a value, found %s', [TomlTokenName(FToken.Kind)]);
    Result := nil; // unreachable
  end;

  Result.Line := LLine;
end;

function TTomlParser.ParseArray: TTomlValue;
begin
  Result := TTomlValue.NewArray;
  Result.Line := FToken.Line;
  try
    Consume(ttLBracket);
    { Newlines carry no meaning inside brackets, so a long dependency list can
      be laid out over several lines. }
    SkipNewlines;
    while FToken.Kind <> ttRBracket do
    begin
      Result.Append(ParseValue);
      SkipNewlines;
      if not Accept(ttComma) then
        Break;
      SkipNewlines;
    end;
    SkipNewlines;
    Consume(ttRBracket);
  except
    Result.Free;
    raise;
  end;
end;

function TTomlParser.ParseInlineTable: TTomlValue;
begin
  Result := TTomlValue.NewTable;
  Result.Line := FToken.Line;
  Result.IsInline := True;
  try
    Consume(ttLBrace);
    SkipNewlines;
    while FToken.Kind <> ttRBrace do
    begin
      ParseKeyValue(Result);
      SkipNewlines;
      if not Accept(ttComma) then
        Break;
      SkipNewlines;
    end;
    SkipNewlines;
    Consume(ttRBrace);
  except
    Result.Free;
    raise;
  end;
end;

{ ---- structure ----------------------------------------------------------- }

function TTomlParser.Descend(const APath: TStrArray; ACount: Integer): TTomlValue;
var
  I: Integer;
  LNext: TTomlValue;
begin
  Result := FRoot;
  for I := 0 to ACount - 1 do
  begin
    LNext := Result.Find(APath[I]);
    if LNext = nil then
    begin
      LNext := TTomlValue.NewTable;
      LNext.Line := FToken.Line;
      Result.Put(APath[I], LNext);
    end
    else if LNext.IsArrayOfTables and (LNext.Count > 0) then
      LNext := LNext.ItemAt(LNext.Count - 1)
    else if not LNext.IsTable then
      FailFmt('cannot use `%s` as a table: it is already %s',
        [JoinStr(Copy(APath, 0, I + 1), '.'), LNext.KindName]);
    Result := LNext;
  end;
end;

procedure TTomlParser.ParseTableHeader;
var
  LIsArray: Boolean;
  LPath: TStrArray;
  LDotted: string;
  LParent, LExisting, LTable: TTomlValue;
begin
  Consume(ttLBracket);
  LIsArray := Accept(ttLBracket);

  LPath := ParseKeyPath;
  LDotted := JoinStr(LPath, '.');

  Consume(ttRBracket);
  if LIsArray then
    Consume(ttRBracket);

  LParent := Descend(LPath, Length(LPath) - 1);
  LExisting := LParent.Find(LPath[High(LPath)]);

  if LIsArray then
  begin
    { [[bin]] appends; the first occurrence creates the array. }
    if LExisting = nil then
    begin
      LExisting := TTomlValue.NewArray;
      LExisting.IsArrayOfTables := True;
      LExisting.Line := FToken.Line;
      LParent.Put(LPath[High(LPath)], LExisting);
    end
    else if not (LExisting.IsArray and LExisting.IsArrayOfTables) then
      FailFmt('cannot use `[[%s]]`: `%s` is already %s',
        [LDotted, LDotted, LExisting.KindName]);

    LTable := TTomlValue.NewTable;
    LTable.Line := FToken.Line;
    LExisting.Append(LTable);
    FCurrent := LTable;
    Exit;
  end;

  if StrArrayHas(FHeaders, LDotted) then
    FailFmt('table `%s` is defined more than once', [LDotted]);
  StrArrayAdd(FHeaders, LDotted);

  if LExisting = nil then
  begin
    LTable := TTomlValue.NewTable;
    LTable.Line := FToken.Line;
    LParent.Put(LPath[High(LPath)], LTable);
    FCurrent := LTable;
  end
  else if LExisting.IsTable then
    { Created implicitly by a deeper header, as [a.b] creates `a`. Opening it
      now is legal and just fills it in. }
    FCurrent := LExisting
  else
    FailFmt('cannot use `[%s]`: it is already %s', [LDotted, LExisting.KindName]);
end;

procedure TTomlParser.ParseKeyValue(ATarget: TTomlValue);
var
  LPath: TStrArray;
  LTable, LNext, LValue: TTomlValue;
  I: Integer;
begin
  LPath := ParseKeyPath;
  Consume(ttEquals);

  { Dotted keys create intermediate tables inside the target, so
    `profile.release.optimize = 3` works without a header. }
  LTable := ATarget;
  for I := 0 to High(LPath) - 1 do
  begin
    LNext := LTable.Find(LPath[I]);
    if LNext = nil then
    begin
      LNext := TTomlValue.NewTable;
      LNext.Line := FToken.Line;
      LTable.Put(LPath[I], LNext);
    end
    else if not LNext.IsTable then
      FailFmt('cannot use `%s` as a table: it is already %s',
        [JoinStr(Copy(LPath, 0, I + 1), '.'), LNext.KindName]);
    LTable := LNext;
  end;

  if LTable.Has(LPath[High(LPath)]) then
    FailFmt('key `%s` is assigned more than once', [JoinStr(LPath, '.')]);

  LValue := ParseValue;
  LTable.Put(LPath[High(LPath)], LValue);
end;

function TTomlParser.Parse: TTomlValue;
begin
  SkipNewlines;
  while FToken.Kind <> ttEOF do
  begin
    if FToken.Kind = ttLBracket then
      ParseTableHeader
    else
    begin
      ParseKeyValue(FCurrent);
      { A pair owns its line. Without this check `a = 1 b = 2` would quietly
        parse as two pairs. }
      if not (FToken.Kind in [ttNewline, ttEOF]) then
        FailFmt('expected a newline after the value, found %s',
          [TomlTokenName(FToken.Kind)]);
    end;
    SkipNewlines;
  end;

  { Hand ownership to the caller; the destructor must not free it now. }
  Result := FRoot;
  FRoot := nil;
end;

{ ---- entry points -------------------------------------------------------- }

function ParseToml(const ASource: string): TTomlValue;
var
  LParser: TTomlParser;
begin
  LParser := TTomlParser.Create(ASource);
  try
    Result := LParser.Parse;
  finally
    LParser.Free;
  end;
end;

function ParseTomlFile(const APath: string): TTomlValue;
begin
  Result := ParseToml(ReadTextFile(APath));
end;

end.
