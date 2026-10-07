{ Struo.Cmd.Run -- `struo run`.

  Builds, then hands the terminal to the program. Two details make the
  difference between this being useful and being in the way:

  * The child inherits stdin, stdout and stderr, so it can prompt, be piped,
    and be interrupted exactly as if it had been started directly. Struo's own
    progress went to stderr for this reason.

  * Struo exits with the program's exit code. A script that runs
    `struo run && deploy` must see the program's verdict, not Struo's opinion
    of whether it managed to start it. }
unit Struo.Cmd.Run;

{$mode objfpc}{$H+}

interface

uses
  Struo.Util.Strings;

function RunRun(const AArgv: TStrArray): Integer;

implementation

uses
  SysUtils, Struo.Types, Struo.Util.Fs, Struo.Util.Proc,
  Struo.Manifest, Struo.Workspace, Struo.Cli.Args, Struo.Cli.Output,
  Struo.Cli.Command, Struo.Cmd.Build;

{ Works out which binary to run, and says something useful when it cannot. }
function ChooseBinary(AManifest: TManifest; const ARequested: string): TTarget;
var
  LBinaries: TTargetArray;
  LNames: TStrArray;
  LCount, I: Integer;
begin
  LBinaries := AManifest.TargetsOfKind(tgBin);

  if ARequested <> '' then
  begin
    if AManifest.FindTarget(tgBin, ARequested, Result) then
      Exit;
    LNames := nil;
    for I := 0 to High(LBinaries) do
      StrArrayAdd(LNames, LBinaries[I].Name);
    if Length(LNames) = 0 then
      raise EStruoError.CreateHintFmt('no binary named `%s`', [ARequested],
        Format('package `%s` has no binaries at all', [AManifest.Name]));
    raise EStruoError.CreateHintFmt('no binary named `%s`', [ARequested],
      'this package has: ' + JoinStr(LNames, ', '));
  end;

  if AManifest.DefaultBinary(Result, LCount) then
    Exit;

  if LCount = 0 then
    raise EStruoError.CreateHintFmt('package `%s` has no binary to run',
      [AManifest.Name],
      'add `' + CSourceDirName + '/main.pas`, or run `struo build` to build ' +
      'the library');

  { Several binaries and none named after the package: guessing here would
    run the wrong program, which is worse than asking. }
  LNames := nil;
  for I := 0 to High(LBinaries) do
    StrArrayAdd(LNames, LBinaries[I].Name);
  raise EStruoError.CreateHintFmt(
    'package `%s` has %d binaries, so there is no default', [AManifest.Name, LCount],
    'pass --bin with one of: ' + JoinStr(LNames, ', '));
end;

function RunRun(const AArgv: TStrArray): Integer;
var
  LCommandLine: TCommandLine;
  LManifest: TManifest;
  LSelection: TTargetSelection;
  LProfile: TBuildProfile;
  LTarget: TTarget;
  LExecutable: string;
  LArguments: TStrArray;
  LOutcome: TProcOutcome;
begin
  LCommandLine := TCommandLine.Create('run');
  try
    DeclareBuildOptions(LCommandLine);
    LCommandLine.Parse(AArgv);

    if LCommandLine.Flag('help') then
    begin
      PrintCommandHelp('run', '[options] [-- <args>]',
        'Build the package, then run its binary.' + LineEnding +
        'Everything after `--` is passed to the program rather than to Struo.',
        LCommandLine);
      Exit(CExitOk);
    end;
    ApplyGlobalOptions(LCommandLine);

    LManifest := OpenPackage(LCommandLine.Value('manifest-path', ''));
    try
      LProfile := ProfileFromOptions(LCommandLine);
      LTarget := ChooseBinary(LManifest, LCommandLine.Value('bin', ''));

      { Build only what is needed to run: the library and this one binary. }
      LSelection := Default(TTargetSelection);
      LSelection.WantLib := True;
      LSelection.WantBins := True;
      LSelection.OnlyName := LTarget.Name;
      BuildTargets(LManifest, LProfile, LSelection, False);

      LExecutable := TargetOutputPath(LManifest, LProfile, LTarget);
      if not PathIsFile(LExecutable) then
        raise EStruoError.CreateHintFmt(
          'the build reported success but `%s` is not there', [LExecutable],
          'run with --verbose to see the compiler command');

      LArguments := LCommandLine.Passthrough;

      { Shown relative to the package root: `target\debug\weather.exe` is
        what the user recognises, not the absolute path. }
      Status('Running', Format('`%s`',
        [Trim(RelativePath(LExecutable, LManifest.Root) + ' ' +
              JoinStr(LArguments, ' '))]));

      LOutcome := RunAttached(LExecutable, LArguments, LManifest.Root);
      if not LOutcome.Spawned then
        raise EStruoError.CreateHintFmt('could not start `%s`', [LExecutable],
          LOutcome.Output);

      { The program's verdict, not ours. }
      Result := LOutcome.ExitCode;
    finally
      LManifest.Free;
    end;
  finally
    LCommandLine.Free;
  end;
end;

end.
