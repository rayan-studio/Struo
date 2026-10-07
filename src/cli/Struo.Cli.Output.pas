{ Struo.Cli.Output -- everything Struo prints.

  Nothing else in Struo writes to stdout or stderr. One unit owning the output
  is what makes --quiet, --color and the twelve-column layout real rather than
  aspirational.

  Progress goes to stderr, not stdout. That is deliberate: it keeps stdout
  clean for the data a command produces, so `struo tree | grep fjson` works
  and, more importantly, so a program started by `struo run` owns stdout
  outright and can be piped as if Struo were not there.

  The shape copies Cargo's, because it reads well and because a Pascal
  developer arriving from Rust will already know how to scan it:

     Compiling hello v0.1.0 (C:\dev\hello)
      Finished `debug` profile [unoptimized + debuginfo] in 0.41s
       Running `target\debug\hello.exe` }
unit Struo.Cli.Output;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Types, Struo.Util.Strings;

type
  { What --color asked for. caAuto means colour only when stderr is a
    terminal, so a redirected build log stays free of escape codes. }
  TColorChoice = (ccAuto, ccAlways, ccNever);

{ ---- configuration ------------------------------------------------------- }

procedure SetVerbosity(AVerbosity: TVerbosity);
function Verbosity: TVerbosity;

procedure SetColorChoice(AChoice: TColorChoice);
function TryParseColorChoice(const AText: string; out AChoice: TColorChoice): Boolean;

{ True when colour is actually being emitted, after the auto decision. }
function ColorEnabled: Boolean;

{ ---- progress, on stderr ------------------------------------------------- }

{ A green verb right-aligned in twelve columns, then the detail:
    `Status('Compiling', 'hello v0.1.0')`. Silent under --quiet. }
procedure Status(const AVerb, ADetail: string);

{ As Status, but cyan, for a verb that reports rather than acts: Using,
  Adding, Updating. }
procedure Note(const AVerb, ADetail: string);

{ `warning: <message>`, in yellow. Never silenced: a warning the user asked
  not to see is a warning that should not have been written. }
procedure Warn(const AMessage: string);

{ `error: <message>` in red, then `hint: <hint>` in cyan when AHint is not
  empty. Only struo.pas calls this. }
procedure Error(const AMessage, AHint: string);

{ Shown only under --verbose, dimmed and prefixed, for the compiler command
  lines and the paths Struo decided on. }
procedure Trace(const AMessage: string);
procedure TraceFmt(const AFormat: string; const AArgs: array of const);

{ Re-emits a compiler's output, dropping its banner and the progress lines
  that duplicate Struo's own. Never silenced: a warning from the compiler is
  the user's code talking, and --quiet was about Struo's chatter.

  Diagnostics keep their original text rather than being reformatted. The
  file:line:column shape is what every editor and IDE knows how to jump to,
  and rewriting it would break that for no gain. }
procedure Diagnostics(const AText: string);

{ ---- data, on stdout ----------------------------------------------------- }

{ A line of a command's actual output: a dependency tree, a doctor report, a
  search result. Goes to stdout so it can be piped. Silent under --quiet. }
procedure Say(const ALine: string);
procedure SayFmt(const AFormat: string; const AArgs: array of const);

{ A blank line on stdout, for separating blocks of output. }
procedure SayBlank;

{ ---- formatting helpers -------------------------------------------------- }

{ '0.41s', '1m 02s'. Used by the Finished line. }
function FormatDuration(ASeconds: Double): string;

{ Wraps AText in the escape codes for ABold and AColor, or returns it
  untouched when colour is off. AColor is an ANSI base code: 31 red, 32
  green, 33 yellow, 36 cyan. }
function Colorize(const AText: string; AColor: Integer; ABold: Boolean): string;

const
  { The width Cargo uses, and the reason its output lines up. }
  CVerbColumn = 12;

  CColorRed = 31;
  CColorGreen = 32;
  CColorYellow = 33;
  CColorCyan = 36;

implementation

uses
  {$IFDEF WINDOWS}
  Windows;
  {$ELSE}
  termio;
  {$ENDIF}

var
  GVerbosity: TVerbosity = vbNormal;
  GColorChoice: TColorChoice = ccAuto;
  GColorResolved: Boolean = False;
  GColorActive: Boolean = False;

  { A locale-independent format for the durations below. Struo must not print
    `0,41s` on one machine and `0.41s` on another, and the CLI layer cannot
    reach into the TOML layer for its settings. }
  GNeutralFormat: TFormatSettings;

{ ---- colour decision ----------------------------------------------------- }

{ True when stderr looks like a terminal rather than a file or a pipe. }
function StdErrIsTerminal: Boolean;
{$IFDEF WINDOWS}
var
  LHandle: THandle;
  LMode: DWORD;
begin
  LHandle := GetStdHandle(STD_ERROR_HANDLE);
  if (LHandle = 0) or (LHandle = INVALID_HANDLE_VALUE) then
    Exit(False);
  { A console handle answers GetConsoleMode; a redirected one does not. }
  Result := GetConsoleMode(LHandle, LMode);
end;
{$ELSE}
begin
  Result := IsATTY(StdErr) = 1;
end;
{$ENDIF}

{$IFDEF WINDOWS}
{ Windows 10 and later understand ANSI escapes, but only once the console is
  told to. Without this, colour would come out as literal `[32m` noise. }
procedure EnableVirtualTerminal;
const
  CEnableVirtualTerminalProcessing = $0004;
var
  LHandle: THandle;
  LMode: DWORD;
begin
  LHandle := GetStdHandle(STD_ERROR_HANDLE);
  if (LHandle = 0) or (LHandle = INVALID_HANDLE_VALUE) then
    Exit;
  if GetConsoleMode(LHandle, LMode) then
    SetConsoleMode(LHandle, LMode or CEnableVirtualTerminalProcessing);
end;
{$ENDIF}

function ColorEnabled: Boolean;
begin
  if GColorResolved then
    Exit(GColorActive);

  case GColorChoice of
    ccAlways: GColorActive := True;
    ccNever:  GColorActive := False;
  else
    { NO_COLOR is honoured whatever its value, as the convention requires.
      Qualified because the Windows unit exports an API function of the same
      name with a different signature. }
    GColorActive := StdErrIsTerminal and
                    (SysUtils.GetEnvironmentVariable('NO_COLOR') = '') and
                    (SysUtils.GetEnvironmentVariable('TERM') <> 'dumb');
  end;

  {$IFDEF WINDOWS}
  if GColorActive then
    EnableVirtualTerminal;
  {$ENDIF}

  GColorResolved := True;
  Result := GColorActive;
end;

procedure SetVerbosity(AVerbosity: TVerbosity);
begin
  GVerbosity := AVerbosity;
end;

function Verbosity: TVerbosity;
begin
  Result := GVerbosity;
end;

procedure SetColorChoice(AChoice: TColorChoice);
begin
  GColorChoice := AChoice;
  { Decide again on the next request, now that the choice has changed. }
  GColorResolved := False;
end;

function TryParseColorChoice(const AText: string; out AChoice: TColorChoice): Boolean;
begin
  Result := True;
  if AText = 'auto' then
    AChoice := ccAuto
  else if AText = 'always' then
    AChoice := ccAlways
  else if AText = 'never' then
    AChoice := ccNever
  else
  begin
    AChoice := ccAuto;
    Result := False;
  end;
end;

function Colorize(const AText: string; AColor: Integer; ABold: Boolean): string;
begin
  if (AText = '') or not ColorEnabled then
    Exit(AText);
  if ABold then
    Result := Format(#27'[1;%dm%s'#27'[0m', [AColor, AText])
  else
    Result := Format(#27'[%dm%s'#27'[0m', [AColor, AText]);
end;

{ ---- progress ------------------------------------------------------------ }

{ The one place a line reaches stderr. }
procedure EmitErr(const ALine: string);
begin
  WriteLn(StdErr, ALine);
  Flush(StdErr);
end;

{ The twelve-column verb, padded before it is coloured so the escape codes do
  not count towards the width. }
procedure EmitVerb(const AVerb, ADetail: string; AColor: Integer);
begin
  EmitErr(Colorize(PadLeftStr(AVerb, CVerbColumn), AColor, True) + ' ' + ADetail);
end;

procedure Status(const AVerb, ADetail: string);
begin
  if GVerbosity = vbQuiet then
    Exit;
  EmitVerb(AVerb, ADetail, CColorGreen);
end;

procedure Note(const AVerb, ADetail: string);
begin
  if GVerbosity = vbQuiet then
    Exit;
  EmitVerb(AVerb, ADetail, CColorCyan);
end;

procedure Warn(const AMessage: string);
begin
  EmitErr(Colorize('warning:', CColorYellow, True) + ' ' + AMessage);
end;

procedure Error(const AMessage, AHint: string);
begin
  EmitErr(Colorize('error:', CColorRed, True) + ' ' + AMessage);
  if AHint <> '' then
    EmitErr(Colorize('hint:', CColorCyan, True) + ' ' + AHint);
end;

procedure Trace(const AMessage: string);
begin
  if GVerbosity <> vbVerbose then
    Exit;
  { Dimmed rather than coloured: a trace line is scaffolding and should not
    compete with the status lines around it. }
  EmitErr(Colorize('       trace', CColorCyan, False) + ' ' + AMessage);
end;

procedure TraceFmt(const AFormat: string; const AArgs: array of const);
begin
  { Formatting is skipped entirely when tracing is off, so a Trace call on a
    hot path costs nothing. }
  if GVerbosity <> vbVerbose then
    Exit;
  Trace(Format(AFormat, AArgs));
end;

{ True for a compiler line that only repeats what Struo already said. }
function IsCompilerNoise(const ALine: string): Boolean;
const
  CNoisePrefixes: array[0 .. 6] of string = (
    'Free Pascal Compiler version',
    'Copyright (c)',
    'Target OS:',
    'Compiling ',
    'Assembling ',
    'Linking ',
    'Compiling resource '
  );
var
  I: Integer;
begin
  for I := Low(CNoisePrefixes) to High(CNoisePrefixes) do
    if StartsWithStr(ALine, CNoisePrefixes[I]) then
      Exit(True);

  { `12345 lines compiled, 0.4 sec` -- Struo reports its own timing. }
  if (Pos(' lines compiled', ALine) > 0) and (Pos(' sec', ALine) > 0) then
    Exit(True);

  { The fpc driver's own epitaph after ppc386 fails. The real diagnostics are
    already above it, and Struo says what could not be built, so this line
    only adds a path the user did not ask about. }
  Result := EndsWithStr(ALine, 'returned an error exitcode');
end;

procedure Diagnostics(const AText: string);
var
  LLines: TStrArray;
  I: Integer;
begin
  if AText = '' then
    Exit;
  LLines := SplitLines(AText);
  for I := 0 to High(LLines) do
  begin
    if IsBlankStr(LLines[I]) or IsCompilerNoise(Trim(LLines[I])) then
      Continue;
    EmitErr(TrimRight(LLines[I]));
  end;
end;

{ ---- data --------------------------------------------------------------- }

procedure Say(const ALine: string);
begin
  if GVerbosity = vbQuiet then
    Exit;
  WriteLn(ALine);
end;

procedure SayFmt(const AFormat: string; const AArgs: array of const);
begin
  if GVerbosity = vbQuiet then
    Exit;
  Say(Format(AFormat, AArgs));
end;

procedure SayBlank;
begin
  if GVerbosity = vbQuiet then
    Exit;
  WriteLn;
end;

{ ---- formatting --------------------------------------------------------- }

function FormatDuration(ASeconds: Double): string;
var
  LMinutes: Integer;
begin
  if ASeconds < 0 then
    ASeconds := 0;
  if ASeconds < 60 then
    { Two decimals below a minute: a build that takes 0.41s and one that takes
      0.89s are usefully different numbers. }
    Exit(Format('%.2fs', [ASeconds], GNeutralFormat));

  LMinutes := Trunc(ASeconds) div 60;
  Result := Format('%dm %02ds', [LMinutes, Trunc(ASeconds) mod 60]);
end;

initialization
  GNeutralFormat := DefaultFormatSettings;
  GNeutralFormat.DecimalSeparator := '.';
  GNeutralFormat.ThousandSeparator := #0;

end.
