{ Struo.Cli.Args -- argv into flags, options and positionals.

  Each command declares the options it accepts before parsing. That costs a
  few lines per command and buys two things worth more than those lines: an
  unknown option is an error rather than a silently ignored typo, and the
  help text is generated from the same declarations, so it cannot drift away
  from what the command actually accepts.

  `--` ends option parsing. Everything after it is handed through untouched,
  which is how `struo run -- --release` passes --release to the program
  instead of to Struo. }
unit Struo.Cli.Args;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings, Struo.Types;

type
  TOptionKind = (okFlag, okValue);

  TCommandLine = class
  private
    { Declared options. The five arrays run in parallel; one index is one
      option. }
    FLongNames: TStrArray;
    FShortNames: TStrArray;
    FKinds: array of TOptionKind;
    FValueNames: TStrArray;
    FHelps: TStrArray;

    { What the command line actually carried. }
    FSeenNames: TStrArray;
    FSeenValues: TStrArray;
    FPositionals: TStrArray;
    FPassthrough: TStrArray;
    FHasPassthrough: Boolean;

    { The command name, used only to make error messages concrete. }
    FCommand: string;

    function IndexOfLong(const AName: string): Integer;
    function IndexOfShort(AChar: Char): Integer;
    procedure Remember(const ALongName, AValue: string);
    procedure Fail(const AMessage, AHint: string);
    function SuggestionFor(const AName: string): string;
    function Render(AIndex: Integer): string;
  public
    constructor Create(const ACommand: string);

    { ---- declaration ---- }

    { A boolean option. AShort is a single character, or '' for none. }
    procedure AddFlag(const ALongName, AShortName, AHelp: string);

    { An option taking a value. AValueName appears in the help as
      `--bin <name>`. }
    procedure AddValue(const ALongName, AShortName, AValueName, AHelp: string);

    { The options every command accepts. Declared here rather than copied
      into each command. }
    procedure AddGlobalOptions;

    { ---- parsing ---- }

    { Raises EStruoUsageError, which exits 2, on an unknown option or a
      missing value. }
    procedure Parse(const AArgv: TStrArray);

    { ---- results ---- }

    function Flag(const ALongName: string): Boolean;
    function HasValue(const ALongName: string): Boolean;
    function Value(const ALongName, ADefault: string): string;

    { An option's value as an integer, raising a usage error when it is not
      one. }
    function IntValue(const ALongName: string; ADefault: Integer): Integer;

    { An option given more than once, or given a comma-separated value, as
      --features json,tls. }
    function ListValue(const ALongName: string): TStrArray;

    function Positionals: TStrArray;
    function PositionalCount: Integer;

    { The positional at AIndex, or '' when there are fewer than that. }
    function Positional(AIndex: Integer): string;

    { Raises a usage error naming AWhat when the positional is absent. }
    function RequirePositional(AIndex: Integer; const AWhat: string): string;

    { Arguments after `--`. }
    function Passthrough: TStrArray;
    function HasPassthrough: Boolean;

    { The declared options, one per line, aligned, for a help screen. }
    function OptionsHelp: string;
  end;

{ The process's own arguments, ParamStr(1) onwards. }
function ArgvFromParams: TStrArray;

implementation

const
  { Where the help text for an option starts. Wide enough for the longest
    option Struo declares, so nothing wraps awkwardly. }
  CHelpColumn = 28;

  { Beyond this edit distance a suggestion is noise rather than help. }
  CMaxSuggestionDistance = 3;

function ArgvFromParams: TStrArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, ParamCount);
  for I := 1 to ParamCount do
    Result[I - 1] := ParamStr(I);
end;

{ The edit distance between two strings, for `did you mean`. Two rolling rows
  rather than a full matrix: option names are short, but there is no reason to
  allocate a matrix for them. }
function EditDistance(const ALeft, ARight: string): Integer;
var
  LPrevious, LCurrent: array of Integer;
  I, J, LInsert, LDelete, LReplace: Integer;
begin
  if ALeft = '' then
    Exit(Length(ARight));
  if ARight = '' then
    Exit(Length(ALeft));

  SetLength(LPrevious, Length(ARight) + 1);
  SetLength(LCurrent, Length(ARight) + 1);
  for J := 0 to Length(ARight) do
    LPrevious[J] := J;

  for I := 1 to Length(ALeft) do
  begin
    LCurrent[0] := I;
    for J := 1 to Length(ARight) do
    begin
      LDelete := LPrevious[J] + 1;
      LInsert := LCurrent[J - 1] + 1;
      LReplace := LPrevious[J - 1];
      if ALeft[I] <> ARight[J] then
        Inc(LReplace);

      LCurrent[J] := LDelete;
      if LInsert < LCurrent[J] then
        LCurrent[J] := LInsert;
      if LReplace < LCurrent[J] then
        LCurrent[J] := LReplace;
    end;
    LPrevious := Copy(LCurrent, 0, Length(LCurrent));
  end;

  Result := LPrevious[Length(ARight)];
end;

{ ---- construction -------------------------------------------------------- }

constructor TCommandLine.Create(const ACommand: string);
begin
  inherited Create;
  FCommand := ACommand;
end;

procedure TCommandLine.AddFlag(const ALongName, AShortName, AHelp: string);
begin
  StrArrayAdd(FLongNames, ALongName);
  StrArrayAdd(FShortNames, AShortName);
  SetLength(FKinds, Length(FKinds) + 1);
  FKinds[High(FKinds)] := okFlag;
  StrArrayAdd(FValueNames, '');
  StrArrayAdd(FHelps, AHelp);
end;

procedure TCommandLine.AddValue(const ALongName, AShortName, AValueName,
  AHelp: string);
begin
  StrArrayAdd(FLongNames, ALongName);
  StrArrayAdd(FShortNames, AShortName);
  SetLength(FKinds, Length(FKinds) + 1);
  FKinds[High(FKinds)] := okValue;
  StrArrayAdd(FValueNames, AValueName);
  StrArrayAdd(FHelps, AHelp);
end;

procedure TCommandLine.AddGlobalOptions;
begin
  AddFlag('help', 'h', 'Print this help and exit');
  AddFlag('verbose', 'v', 'Show the commands Struo runs');
  AddFlag('quiet', 'q', 'Print nothing but errors');
  AddValue('color', '', 'when', 'Colour the output: auto, always or never');
  AddValue('manifest-path', '', 'path',
    'Use this ' + CManifestName + ' instead of searching upward');
end;

{ ---- lookup -------------------------------------------------------------- }

function TCommandLine.IndexOfLong(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FLongNames) do
    if FLongNames[I] = AName then
      Exit(I);
  Result := -1;
end;

function TCommandLine.IndexOfShort(AChar: Char): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FShortNames) do
    if (FShortNames[I] <> '') and (FShortNames[I][1] = AChar) then
      Exit(I);
  Result := -1;
end;

procedure TCommandLine.Fail(const AMessage, AHint: string);
var
  LHint: string;
begin
  LHint := AHint;
  if LHint = '' then
    LHint := Format('run `struo %s --help` to see the options', [FCommand]);
  raise EStruoUsageError.CreateHint(AMessage, LHint);
end;

function TCommandLine.SuggestionFor(const AName: string): string;
var
  I, LDistance, LBest: Integer;
begin
  Result := '';
  LBest := CMaxSuggestionDistance + 1;
  for I := 0 to High(FLongNames) do
  begin
    LDistance := EditDistance(LowerCase(AName), FLongNames[I]);
    if LDistance < LBest then
    begin
      LBest := LDistance;
      Result := FLongNames[I];
    end;
  end;
  if LBest > CMaxSuggestionDistance then
    Result := '';
end;

procedure TCommandLine.Remember(const ALongName, AValue: string);
var
  I: Integer;
begin
  { A repeated option overwrites, except that ListValue can still see every
    occurrence, which is what makes `--features a --features b` work. }
  for I := 0 to High(FSeenNames) do
    if (FSeenNames[I] = ALongName) and (FSeenValues[I] = AValue) then
      Exit;
  StrArrayAdd(FSeenNames, ALongName);
  StrArrayAdd(FSeenValues, AValue);
end;

{ ---- parsing ------------------------------------------------------------- }

procedure TCommandLine.Parse(const AArgv: TStrArray);
var
  I, J, LIndex: Integer;
  LArgument, LName, LValue, LUnknown: string;
  LHasInlineValue: Boolean;
begin
  I := 0;
  while I <= High(AArgv) do
  begin
    LArgument := AArgv[I];

    { `--` hands everything after it to the program being run. }
    if LArgument = '--' then
    begin
      FHasPassthrough := True;
      for J := I + 1 to High(AArgv) do
        StrArrayAdd(FPassthrough, AArgv[J]);
      Exit;
    end;

    if StartsWithStr(LArgument, '--') then
    begin
      LName := Copy(LArgument, 3, MaxInt);
      LValue := '';
      LHasInlineValue := False;

      J := Pos('=', LName);
      if J > 0 then
      begin
        LValue := Copy(LName, J + 1, MaxInt);
        LName := Copy(LName, 1, J - 1);
        LHasInlineValue := True;
      end;

      LIndex := IndexOfLong(LName);
      if LIndex < 0 then
      begin
        LUnknown := SuggestionFor(LName);
        if LUnknown <> '' then
          Fail(Format('unknown option `--%s`', [LName]),
               Format('did you mean `--%s`?', [LUnknown]))
        else
          Fail(Format('unknown option `--%s`', [LName]), '');
      end;

      if FKinds[LIndex] = okFlag then
      begin
        if LHasInlineValue then
          Fail(Format('`--%s` takes no value', [LName]), '');
        Remember(LName, '');
      end
      else
      begin
        if not LHasInlineValue then
        begin
          Inc(I);
          if I > High(AArgv) then
            Fail(Format('`--%s` needs a value', [LName]),
                 Format('write `--%s <%s>`', [LName, FValueNames[LIndex]]));
          LValue := AArgv[I];
        end;
        Remember(LName, LValue);
      end;

      Inc(I);
      Continue;
    end;

    { A short option, or a cluster of them such as -vq. }
    if (Length(LArgument) > 1) and (LArgument[1] = '-') then
    begin
      J := 2;
      while J <= Length(LArgument) do
      begin
        LIndex := IndexOfShort(LArgument[J]);
        if LIndex < 0 then
          Fail(Format('unknown option `-%s`', [LArgument[J]]), '');

        if FKinds[LIndex] = okValue then
        begin
          { The value is the rest of the cluster, as in -j4, or the next
            argument. Either way the cluster ends here. }
          if J < Length(LArgument) then
            Remember(FLongNames[LIndex], Copy(LArgument, J + 1, MaxInt))
          else
          begin
            Inc(I);
            if I > High(AArgv) then
              Fail(Format('`-%s` needs a value', [LArgument[J]]),
                   Format('write `--%s <%s>`',
                          [FLongNames[LIndex], FValueNames[LIndex]]));
            Remember(FLongNames[LIndex], AArgv[I]);
          end;
          Break;
        end;

        Remember(FLongNames[LIndex], '');
        Inc(J);
      end;
      Inc(I);
      Continue;
    end;

    StrArrayAdd(FPositionals, LArgument);
    Inc(I);
  end;
end;

{ ---- results ------------------------------------------------------------- }

function TCommandLine.Flag(const ALongName: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FSeenNames) do
    if FSeenNames[I] = ALongName then
      Exit(True);
  Result := False;
end;

function TCommandLine.HasValue(const ALongName: string): Boolean;
begin
  Result := Flag(ALongName);
end;

function TCommandLine.Value(const ALongName, ADefault: string): string;
var
  I: Integer;
begin
  { The last occurrence wins, which is what a user repeating an option on one
    line expects. }
  Result := ADefault;
  for I := 0 to High(FSeenNames) do
    if FSeenNames[I] = ALongName then
      Result := FSeenValues[I];
end;

function TCommandLine.IntValue(const ALongName: string; ADefault: Integer): Integer;
var
  LText: string;
begin
  Result := ADefault;
  LText := Value(ALongName, '');
  if LText = '' then
    Exit;
  if not TryStrToInt(LText, Result) then
    Fail(Format('`--%s` needs a number, not `%s`', [ALongName, LText]), '');
end;

function TCommandLine.ListValue(const ALongName: string): TStrArray;
var
  I, J: Integer;
  LParts: TStrArray;
begin
  Result := nil;
  for I := 0 to High(FSeenNames) do
    if FSeenNames[I] = ALongName then
    begin
      { Both `--features a,b` and `--features a --features b` are accepted,
        because both are things people type. }
      LParts := SplitTrimStr(FSeenValues[I], ',');
      for J := 0 to High(LParts) do
        StrArrayAddUnique(Result, LParts[J]);
    end;
end;

function TCommandLine.Positionals: TStrArray;
begin
  Result := FPositionals;
end;

function TCommandLine.PositionalCount: Integer;
begin
  Result := Length(FPositionals);
end;

function TCommandLine.Positional(AIndex: Integer): string;
begin
  if (AIndex < 0) or (AIndex > High(FPositionals)) then
    Result := ''
  else
    Result := FPositionals[AIndex];
end;

function TCommandLine.RequirePositional(AIndex: Integer; const AWhat: string): string;
begin
  Result := Positional(AIndex);
  if Result = '' then
    Fail(Format('`struo %s` needs %s', [FCommand, AWhat]),
         Format('run `struo %s --help` for the usage', [FCommand]));
end;

function TCommandLine.Passthrough: TStrArray;
begin
  Result := FPassthrough;
end;

function TCommandLine.HasPassthrough: Boolean;
begin
  Result := FHasPassthrough;
end;

{ '  -h, --help' or '      --release', with the value name appended. }
function TCommandLine.Render(AIndex: Integer): string;
begin
  if FShortNames[AIndex] <> '' then
    Result := '  -' + FShortNames[AIndex] + ', --' + FLongNames[AIndex]
  else
    { Four spaces stand in for the missing short form so the long names stay
      in one column. }
    Result := '      --' + FLongNames[AIndex];
  if FKinds[AIndex] = okValue then
    Result := Result + ' <' + FValueNames[AIndex] + '>';
end;

function TCommandLine.OptionsHelp: string;
var
  I: Integer;
  LLeft: string;
begin
  Result := '';
  for I := 0 to High(FLongNames) do
  begin
    if I > 0 then
      Result := Result + LineEnding;
    LLeft := Render(I);
    if Length(LLeft) >= CHelpColumn then
      { Too long to share a line: put the description underneath rather than
        pushing the column out for every other option. }
      Result := Result + LLeft + LineEnding + StringOfChar(' ', CHelpColumn) +
                FHelps[I]
    else
      Result := Result + PadRightStr(LLeft, CHelpColumn) + FHelps[I];
  end;
end;

end.
