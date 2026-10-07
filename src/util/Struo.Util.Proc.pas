{ Struo.Util.Proc -- running child processes.

  Struo shells out constantly: to fpc for every compile, to git for fetching
  dependencies, and to the program itself for `struo run`. Those three cases
  want different things from a child process, so there are three entry points
  rather than one with a pile of flags:

    RunCaptured  -- collect the output, for a compiler whose diagnostics we
                    want to re-render ourselves.
    RunAttached  -- let the child own the terminal, for `struo run` and for
                    anything interactive such as a git credential prompt.
    RunQuiet     -- discard the output, when only the exit code matters.

  Arguments are passed as an array and handed to TProcess one by one, never
  concatenated into a command line. That is what keeps a path with a space in
  it, which on Windows is most of them, from being split apart. }
unit Struo.Util.Proc;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings;

type
  { The outcome of a child process. Output holds stdout and stderr
    interleaved in the order the child wrote them. }
  TProcOutcome = record
    ExitCode: Integer;
    Output: string;
    Elapsed: Double;   // seconds
    Spawned: Boolean;  // False when the executable could not be started
  end;

  EProcError = class(Exception);

{ Runs AExe and collects its output. Never raises for a non-zero exit code;
  inspect ExitCode. Sets Spawned to False when AExe could not be launched at
  all, which is a different failure from a program that ran and complained. }
function RunCaptured(const AExe: string; const AArgs: array of string;
  const AWorkDir: string): TProcOutcome;

{ Runs AExe with Struo's own stdin, stdout and stderr. The child's output goes
  straight to the terminal, uncoloured and uncaptured, which is what you want
  for a program the user asked to run. Output is always empty. }
function RunAttached(const AExe: string; const AArgs: array of string;
  const AWorkDir: string): TProcOutcome;

{ Runs AExe and throws the output away. }
function RunQuiet(const AExe: string; const AArgs: array of string;
  const AWorkDir: string): TProcOutcome;

{ Resolves AName against PATH, appending the platform executable extension
  when AName has none. Returns '' when nothing matches. An AName that already
  contains a separator is checked as a path and not searched for. }
function FindExecutable(const AName: string): string;

{ Renders a command the way a shell would accept it, quoting the parts that
  need it. For `--verbose` output and error messages only -- nothing is ever
  executed through this string. }
function FormatCommand(const AExe: string; const AArgs: array of string): string;

implementation

uses
  Classes, Process, Struo.Util.Fs;

const
  { Read the child's pipe in chunks. 16 KiB is comfortably more than a single
    compiler diagnostic and small enough to keep memory flat on a long build. }
  CReadChunk = 16 * 1024;

{ The three Run* functions differ only in how the child's streams are wired,
  so they share this body. }
function RunInternal(const AExe: string; const AArgs: array of string;
  const AWorkDir: string; ACapture, AAttach: Boolean): TProcOutcome;
var
  LProcess: TProcess;
  LBuffer: array[0 .. CReadChunk - 1] of Byte;
  LRead: Integer;
  LOutput: TStringStream;
  LStart: TDateTime;
  I: Integer;
begin
  Result.ExitCode := -1;
  Result.Output := '';
  Result.Elapsed := 0;
  Result.Spawned := False;
  LStart := Now;

  LProcess := TProcess.Create(nil);
  try
    LProcess.Executable := AExe;
    for I := 0 to High(AArgs) do
      LProcess.Parameters.Add(AArgs[I]);
    if (AWorkDir <> '') and PathIsDir(AWorkDir) then
      LProcess.CurrentDirectory := AWorkDir;

    if AAttach then
      { Hand the child our own handles so it can print and prompt directly. }
      LProcess.Options := [poWaitOnExit]
    else if ACapture then
      { stderr merged into stdout keeps compiler diagnostics in the order the
        compiler emitted them. }
      LProcess.Options := [poUsePipes, poStderrToOutPut]
    else
      LProcess.Options := [poUsePipes, poStderrToOutPut, poWaitOnExit];

    try
      LProcess.Execute;
      Result.Spawned := True;
    except
      on E: Exception do
      begin
        { A missing executable is the common case here. Report it as a failure
          to spawn and let the caller produce a better message than the OS. }
        Result.Output := E.Message;
        Result.Elapsed := (Now - LStart) * SecsPerDay;
        Exit;
      end;
    end;

    if ACapture and not AAttach then
    begin
      LOutput := TStringStream.Create('');
      try
        { Drain the pipe while the child runs. Waiting for exit first would
          deadlock as soon as the child filled the pipe buffer. }
        while LProcess.Running or (LProcess.Output.NumBytesAvailable > 0) do
        begin
          if LProcess.Output.NumBytesAvailable > 0 then
          begin
            LRead := LProcess.Output.Read(LBuffer, CReadChunk);
            if LRead > 0 then
              LOutput.WriteBuffer(LBuffer, LRead);
          end
          else
            { Nothing ready: yield rather than spin on the CPU. }
            Sleep(5);
        end;
        Result.Output := LOutput.DataString;
      finally
        LOutput.Free;
      end;
    end;

    if LProcess.Running then
      LProcess.WaitOnExit;
    Result.ExitCode := LProcess.ExitStatus;
  finally
    LProcess.Free;
  end;

  Result.Elapsed := (Now - LStart) * SecsPerDay;
end;

function RunCaptured(const AExe: string; const AArgs: array of string;
  const AWorkDir: string): TProcOutcome;
begin
  Result := RunInternal(AExe, AArgs, AWorkDir, True, False);
end;

function RunAttached(const AExe: string; const AArgs: array of string;
  const AWorkDir: string): TProcOutcome;
begin
  Result := RunInternal(AExe, AArgs, AWorkDir, False, True);
end;

function RunQuiet(const AExe: string; const AArgs: array of string;
  const AWorkDir: string): TProcOutcome;
begin
  Result := RunInternal(AExe, AArgs, AWorkDir, False, False);
end;

function FindExecutable(const AName: string): string;
var
  LExts, LDirs: TStrArray;
  LPathVar, LCandidate: string;
  I, J: Integer;
begin
  Result := '';
  if AName = '' then
    Exit;

  {$IFDEF WINDOWS}
  LExts := StrArrayOf(['.exe', '.cmd', '.bat', '.com', '']);
  {$ELSE}
  LExts := StrArrayOf(['']);
  {$ENDIF}
  { An explicit extension is honoured as given, with no substitutes tried. }
  if ExtractFileExt(AName) <> '' then
    LExts := StrArrayOf(['']);

  { A name with a separator in it is a path, not something to look up. }
  if (Pos('/', AName) > 0) or (Pos('\', AName) > 0) then
  begin
    for I := 0 to High(LExts) do
      if PathIsFile(AName + LExts[I]) then
        Exit(NormalizePath(ExpandFileName(AName + LExts[I])));
    Exit;
  end;

  LPathVar := GetEnvironmentVariable('PATH');
  {$IFDEF WINDOWS}
  LDirs := SplitStr(LPathVar, ';');
  { Windows resolves the current directory before PATH. }
  StrArrayAdd(LDirs, '.');
  {$ELSE}
  LDirs := SplitStr(LPathVar, ':');
  {$ENDIF}

  for I := 0 to High(LDirs) do
  begin
    if IsBlankStr(LDirs[I]) then
      Continue;
    for J := 0 to High(LExts) do
    begin
      { PATH entries are often quoted on Windows; strip the quotes. }
      LCandidate := JoinPath(StringReplace(Trim(LDirs[I]), '"', '', [rfReplaceAll]),
                             AName + LExts[J]);
      if PathIsFile(LCandidate) then
        Exit(NormalizePath(ExpandFileName(LCandidate)));
    end;
  end;
end;

{ True when APart can go on a command line unquoted. }
function IsBarePart(const APart: string): Boolean;
var
  I: Integer;
begin
  if APart = '' then
    Exit(False);
  for I := 1 to Length(APart) do
    if not (APart[I] in ['A'..'Z', 'a'..'z', '0'..'9',
                         '-', '_', '.', '/', '\', ':', '=', '+', ',', '@']) then
      Exit(False);
  Result := True;
end;

function FormatCommand(const AExe: string; const AArgs: array of string): string;

  function Render(const APart: string): string;
  begin
    if IsBarePart(APart) then
      Result := APart
    else
      Result := '"' + StringReplace(APart, '"', '\"', [rfReplaceAll]) + '"';
  end;

var
  I: Integer;
begin
  Result := Render(AExe);
  for I := 0 to High(AArgs) do
    Result := Result + ' ' + Render(AArgs[I]);
end;

end.
