{ Struo.Cli.Command -- the command registry, dispatch and help.

  One list of commands serves three purposes: dispatch, the top-level help
  screen, and the `did you mean` suggestion for a mistyped command. Keeping
  them from drifting apart is the whole reason the registry exists rather
  than a case statement in struo.pas. }
unit Struo.Cli.Command;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings, Struo.Types, Struo.Cli.Args;

type
  { A command receives the arguments after its own name and returns a process
    exit code. Raising EStruoError is the normal way to fail; struo.pas turns
    it into `error:` and exit 1. }
  TCommandHandler = function(const AArgv: TStrArray): Integer;

{ Adds a command. ASection groups it on the help screen. AAliases are extra
  names that dispatch to the same handler but do not appear in help. }
procedure RegisterCommand(const AName, ASection, ASummary: string;
  AHandler: TCommandHandler; const AAliases: array of string);

function FindCommand(const AName: string; out AHandler: TCommandHandler): Boolean;

{ The closest registered name to AName, or '' when nothing is close. }
function SuggestCommand(const AName: string): string;

{ Runs AArgv[0] as a command with the rest as its arguments. Handles an empty
  command line, --version and --help itself. }
function Dispatch(const AArgv: TStrArray): Integer;

{ ---- shared help rendering ----------------------------------------------- }

{ `struo 0.1.0`. }
procedure PrintVersion;

{ The top-level screen: usage, the commands by section, and where to read
  more. }
procedure PrintGlobalHelp;

{ A command's own screen, built from the options it declared so that help and
  behaviour cannot disagree. ADescription may run to several lines. }
procedure PrintCommandHelp(const AName, AUsage, ADescription: string;
  ACommandLine: TCommandLine);

{ Reads --verbose, --quiet and --color out of a parsed command line and
  applies them. Every command calls this immediately after parsing. }
procedure ApplyGlobalOptions(ACommandLine: TCommandLine);

implementation

uses
  Struo.Cli.Output;

type
  TCommandEntry = record
    Name: string;
    Section: string;
    Summary: string;
    Handler: TCommandHandler;
    Aliases: TStrArray;
  end;

var
  GCommands: array of TCommandEntry;

const
  { Where a command's summary starts on the help screen. }
  CCommandColumn = 16;

procedure RegisterCommand(const AName, ASection, ASummary: string;
  AHandler: TCommandHandler; const AAliases: array of string);
begin
  SetLength(GCommands, Length(GCommands) + 1);
  with GCommands[High(GCommands)] do
  begin
    Name := AName;
    Section := ASection;
    Summary := ASummary;
    Handler := AHandler;
    Aliases := StrArrayOf(AAliases);
  end;
end;

function FindCommand(const AName: string; out AHandler: TCommandHandler): Boolean;
var
  I: Integer;
begin
  AHandler := nil;
  for I := 0 to High(GCommands) do
    if (GCommands[I].Name = AName) or StrArrayHas(GCommands[I].Aliases, AName) then
    begin
      AHandler := GCommands[I].Handler;
      Exit(True);
    end;
  Result := False;
end;

{ The edit distance between two strings, for the suggestion below. Kept local
  rather than shared with Struo.Cli.Args: duplicating fifteen lines is a
  smaller cost than a utility unit neither layer owns. }
function Distance(const ALeft, ARight: string): Integer;
var
  LPrevious, LCurrent: array of Integer;
  I, J, LBest: Integer;
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
      LBest := LPrevious[J] + 1;
      if LCurrent[J - 1] + 1 < LBest then
        LBest := LCurrent[J - 1] + 1;
      if LPrevious[J - 1] + Ord(ALeft[I] <> ARight[J]) < LBest then
        LBest := LPrevious[J - 1] + Ord(ALeft[I] <> ARight[J]);
      LCurrent[J] := LBest;
    end;
    LPrevious := Copy(LCurrent, 0, Length(LCurrent));
  end;

  Result := LPrevious[Length(ARight)];
end;

function SuggestCommand(const AName: string): string;
var
  I, LDistance, LBest: Integer;
begin
  Result := '';
  LBest := 3;
  for I := 0 to High(GCommands) do
  begin
    LDistance := Distance(LowerCase(AName), GCommands[I].Name);
    if LDistance < LBest then
    begin
      LBest := LDistance;
      Result := GCommands[I].Name;
    end;
  end;
end;

{ ---- help ---------------------------------------------------------------- }

procedure PrintVersion;
begin
  Say('struo ' + CStruoVersion);
end;

procedure PrintGlobalHelp;
var
  I: Integer;
  LSections: TStrArray;
  LSection: Integer;
begin
  Say('Struo is the package manager and build tool for Pascal.');
  SayBlank;
  Say('Usage: struo <command> [options] [arguments]');
  SayBlank;

  { Collect the sections in the order they were registered, so the help
    screen's grouping follows the order the commands were declared in. }
  LSections := nil;
  for I := 0 to High(GCommands) do
    StrArrayAddUnique(LSections, GCommands[I].Section);

  for LSection := 0 to High(LSections) do
  begin
    Say(LSections[LSection] + ':');
    for I := 0 to High(GCommands) do
      if GCommands[I].Section = LSections[LSection] then
        Say('  ' + PadRightStr(GCommands[I].Name, CCommandColumn) +
            GCommands[I].Summary);
    SayBlank;
  end;

  Say('Options:');
  Say('  -h, --help      Print help for a command');
  Say('  -V, --version   Print Struo''s version');
  Say('  -v, --verbose   Show the commands Struo runs');
  Say('  -q, --quiet     Print nothing but errors');
  SayBlank;
  Say('Run `struo <command> --help` for the options of one command.');
end;

procedure PrintCommandHelp(const AName, AUsage, ADescription: string;
  ACommandLine: TCommandLine);
begin
  if ADescription <> '' then
  begin
    Say(ADescription);
    SayBlank;
  end;
  Say('Usage: struo ' + AName + ' ' + AUsage);
  SayBlank;
  Say('Options:');
  Say(ACommandLine.OptionsHelp);
end;

procedure ApplyGlobalOptions(ACommandLine: TCommandLine);
var
  LChoice: TColorChoice;
  LText: string;
begin
  { --color is read before anything is printed, so that even the first error
    respects it. }
  LText := ACommandLine.Value('color', 'auto');
  if not TryParseColorChoice(LText, LChoice) then
    raise EStruoUsageError.CreateHintFmt('unknown --color value `%s`', [LText],
      'use auto, always or never');
  SetColorChoice(LChoice);

  if ACommandLine.Flag('quiet') and ACommandLine.Flag('verbose') then
    raise EStruoUsageError.CreateHint(
      '--quiet and --verbose contradict each other',
      'pass one or the other');

  if ACommandLine.Flag('quiet') then
    SetVerbosity(vbQuiet)
  else if ACommandLine.Flag('verbose') then
    SetVerbosity(vbVerbose);
end;

{ ---- dispatch ------------------------------------------------------------ }

function Dispatch(const AArgv: TStrArray): Integer;
var
  LName, LSuggestion: string;
  LHandler: TCommandHandler;
  LRest: TStrArray;
  I: Integer;
begin
  if Length(AArgv) = 0 then
  begin
    PrintGlobalHelp;
    { No command is not an error: it is someone finding their way around. }
    Exit(CExitOk);
  end;

  LName := AArgv[0];

  { The two options that stand alone, before any command. }
  if (LName = '--version') or (LName = '-V') then
  begin
    PrintVersion;
    Exit(CExitOk);
  end;
  if (LName = '--help') or (LName = '-h') or (LName = 'help') then
  begin
    { `struo help build` is the same as `struo build --help`. }
    if Length(AArgv) > 1 then
    begin
      if FindCommand(AArgv[1], LHandler) then
        Exit(LHandler(StrArrayOf(['--help'])));
      LName := AArgv[1];
    end
    else
    begin
      PrintGlobalHelp;
      Exit(CExitOk);
    end;
  end;

  if not FindCommand(LName, LHandler) then
  begin
    LSuggestion := SuggestCommand(LName);
    if LSuggestion <> '' then
      raise EStruoUsageError.CreateHintFmt('unknown command `%s`', [LName],
        Format('did you mean `struo %s`?', [LSuggestion]));
    raise EStruoUsageError.CreateHintFmt('unknown command `%s`', [LName],
      'run `struo --help` to see the commands');
  end;

  LRest := nil;
  SetLength(LRest, Length(AArgv) - 1);
  for I := 1 to High(AArgv) do
    LRest[I - 1] := AArgv[I];

  Result := LHandler(LRest);
end;

end.
