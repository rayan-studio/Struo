{ Struo.Cmd.Test -- `struo test`.

  A test target is a program that exits zero when it passes. That is the whole
  contract, and it is deliberate: it means a Struo package can be tested
  without adopting a particular test framework, and a framework can be a
  plain dependency rather than something Struo has to know about.

  Every test runs even after one fails, because a developer wants the whole
  list, not the first item on it. }
unit Struo.Cmd.Test;

{$mode objfpc}{$H+}

interface

uses
  Struo.Util.Strings;

function RunTest(const AArgv: TStrArray): Integer;

implementation

uses
  SysUtils, Struo.Types, Struo.Util.Fs, Struo.Util.Proc,
  Struo.Manifest, Struo.Workspace, Struo.Cli.Args, Struo.Cli.Output,
  Struo.Cli.Command, Struo.Cmd.Build;

function RunTest(const AArgv: TStrArray): Integer;
var
  LCommandLine: TCommandLine;
  LManifest: TManifest;
  LSelection: TTargetSelection;
  LProfile: TBuildProfile;
  LTests: TTargetArray;
  LChosen: TTarget;
  LFailures, LNames: TStrArray;
  LExecutable, LOnly: string;
  LOutcome: TProcOutcome;
  LRan, I: Integer;
begin
  LCommandLine := TCommandLine.Create('test');
  try
    DeclareBuildOptions(LCommandLine);
    LCommandLine.AddValue('test', '', 'name', 'Run only this test target');
    LCommandLine.Parse(AArgv);

    if LCommandLine.Flag('help') then
    begin
      PrintCommandHelp('test', '[options] [-- <args>]',
        'Build the test targets and run each one.' + LineEnding +
        'A test target is any .pas file in ' + CTestsDirName +
        '/, plus every [[test]] in the manifest.' + LineEnding +
        'A test passes when it exits with status 0.', LCommandLine);
      Exit(CExitOk);
    end;
    ApplyGlobalOptions(LCommandLine);

    LManifest := OpenPackage(LCommandLine.Value('manifest-path', ''));
    try
      LProfile := ProfileFromOptions(LCommandLine);
      LOnly := LCommandLine.Value('test', '');

      LSelection := Default(TTargetSelection);
      LSelection.WantLib := True;
      LSelection.WantTests := True;
      LSelection.OnlyName := LOnly;

      LTests := LManifest.TargetsOfKind(tgTest);
      if Length(LTests) = 0 then
      begin
        { Not a failure. A package with no tests yet should be told how to add
          one, not handed an error. }
        Warn(Format('package `%s` has no tests', [LManifest.Name]));
        Note('Help', 'add a program under ' + CTestsDirName +
                     '/ that exits non-zero when it fails');
        Exit(CExitOk);
      end;

      { Checked before building, so a mistyped --test costs no compile time. }
      if (LOnly <> '') and not LManifest.FindTarget(tgTest, LOnly, LChosen) then
      begin
        LNames := nil;
        for I := 0 to High(LTests) do
          StrArrayAdd(LNames, LTests[I].Name);
        raise EStruoError.CreateHintFmt('no test named `%s`', [LOnly],
          'this package has: ' + JoinStr(LNames, ', '));
      end;

      BuildTargets(LManifest, LProfile, LSelection, False);

      LFailures := nil;
      LRan := 0;
      for I := 0 to High(LTests) do
      begin
        if (LOnly <> '') and not SameText(LTests[I].Name, LOnly) then
          Continue;
        Inc(LRan);

        LExecutable := TargetOutputPath(LManifest, LProfile, LTests[I]);
        if not PathIsFile(LExecutable) then
        begin
          StrArrayAdd(LFailures, LTests[I].Name + ' (was not built)');
          Continue;
        end;

        Status('Running', Format('%s (%s)',
          [LTests[I].Name, RelativePath(LExecutable, LManifest.Root)]));

        { Attached, so the test's own output reaches the terminal as it is
          produced rather than in a lump at the end. }
        LOutcome := RunAttached(LExecutable, LCommandLine.Passthrough,
                                LManifest.Root);
        if (not LOutcome.Spawned) or (LOutcome.ExitCode <> 0) then
          StrArrayAdd(LFailures, LTests[I].Name);
      end;

      if Length(LFailures) > 0 then
        raise EStruoError.CreateHintFmt('%d of %d test(s) failed: %s',
          [Length(LFailures), LRan, JoinStr(LFailures, ', ')],
          'the failing output is above');

      Status('Finished', Format('%d test(s) passed', [LRan]));
      Result := CExitOk;
    finally
      LManifest.Free;
    end;
  finally
    LCommandLine.Free;
  end;
end;

end.
