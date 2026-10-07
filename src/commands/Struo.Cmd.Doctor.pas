{ Struo.Cmd.Doctor -- `struo doctor`.

  Reports what Struo detected, which is the first thing to ask for when a
  build behaves unexpectedly. It is also the only command that must work when
  everything else is broken, so it never raises for a missing compiler or a
  missing manifest: it reports their absence and moves on.

  The output goes to stdout, because it is the command's product rather than
  progress about producing something else. }
unit Struo.Cmd.Doctor;

{$mode objfpc}{$H+}

interface

uses
  Struo.Util.Strings;

function RunDoctor(const AArgv: TStrArray): Integer;

implementation

uses
  SysUtils, Struo.Types, Struo.Util.Fs, Struo.Util.Proc, Struo.Paths,
  Struo.Manifest, Struo.Targets, Struo.Compiler, Struo.Workspace,
  Struo.Cli.Args, Struo.Cli.Output, Struo.Cli.Command;

const
  CLabelWidth = 12;

procedure Report(const ALabel, AValue: string);
begin
  Say(PadRightStr(ALabel, CLabelWidth) + AValue);
end;

{ Reports the compiler, and collects anything the user should act on. }
procedure ReportCompiler(const AInfo: TCompilerInfo; var AProblems: TStrArray);
begin
  if not AInfo.Found then
  begin
    Report('Compiler', 'not found');
    StrArrayAdd(AProblems,
      'No Free Pascal compiler was found. Install it from ' +
      'https://www.freepascal.org/ and put `fpc` on your PATH, or set ' +
      'STRUO_FPC to its full path.');
    Exit;
  end;

  Report('Compiler', Format('fpc %s (%s)',
    [AInfo.Version, ToolchainOriginName(AInfo.Origin)]));
  Report('', AInfo.Path);
  Report('Host', AInfo.Target);

  if AInfo.UnitsDir <> '' then
    Report('Units', AInfo.UnitsDir)
  else
  begin
    Report('Units', 'not found');
    StrArrayAdd(AProblems,
      'The compiler''s packaged units could not be located, so `uses ' +
      'Classes` and similar will fail. The install may be incomplete.');
  end;

  if AInfo.Origin = toSystem then
  begin
    { A system compiler is whatever this machine happens to have, so a build
      here is not necessarily the build a colleague gets. }
    StrArrayAdd(AProblems,
      'Struo is using a compiler from this machine rather than a bundled ' +
      'one, so builds here may differ from builds elsewhere. Run ' +
      '`struo toolchain` to see what else is available.');

    if not AInfo.HasConfig then
      { Struo works around this by passing the unit path itself, but every
        other tool on the machine will not, so it is worth saying. }
      StrArrayAdd(AProblems,
        'This install has no fpc.cfg, so plain `fpc` can only find its RTL. ' +
        'Struo passes the unit path itself, but to fix it everywhere run: ' +
        Format('fpcmkcfg -d basepath=%s -o %s', [AInfo.BaseDir,
          JoinPath(PathWithoutTrailingSep(ExtractFilePath(AInfo.Path)),
                   'fpc.cfg')]));
  end
  else if AInfo.Hermetic then
    { Not a problem: a bundled toolchain is deliberately told to read no
      config, so that another installation's fpc.cfg cannot reach into it. }
    Report('Config', 'none read (hermetic)');
end;

procedure ReportPackage;
var
  LPath: string;
  LManifest: TManifest;
  LTargets: TStrArray;
  I: Integer;
begin
  LPath := TryDiscoverManifestPath('');
  if LPath = '' then
  begin
    Report('Package', 'none found from ' + CurrentDir);
    Exit;
  end;

  try
    LManifest := TManifest.Load(LPath);
  except
    on E: EStruoError do
    begin
      { A broken manifest is exactly the sort of thing doctor exists to
        surface, so report it rather than letting it end the command. }
      Report('Package', 'found, but could not be read');
      Report('', E.Message);
      Exit;
    end;
  end;

  try
    Report('Package', LManifest.Describe);
    Report('Manifest', LManifest.ManifestPath);
    Report('Target dir', TargetDir(LManifest.Root));

    InferTargets(LManifest);
    LTargets := nil;
    for I := 0 to High(LManifest.Targets) do
      StrArrayAdd(LTargets, LManifest.Targets[I].Name +
        ' (' + TargetKindName(LManifest.Targets[I].Kind) + ')');
    if Length(LTargets) = 0 then
      Report('Targets', 'none')
    else
      Report('Targets', JoinStr(LTargets, ', '));

    if Length(LManifest.Dependencies) = 0 then
      Report('Deps', 'none')
    else
      Report('Deps', Format('%d declared', [Length(LManifest.Dependencies)]));
  finally
    LManifest.Free;
  end;
end;

procedure ReportTools;
var
  LGit: string;
begin
  LGit := FindExecutable('git');
  if LGit = '' then
    Report('git', 'not found (needed for git dependencies and `struo new`)')
  else
    Report('git', LGit);
end;

function RunDoctor(const AArgv: TStrArray): Integer;
var
  LCommandLine: TCommandLine;
  LProblems: TStrArray;
  I: Integer;
begin
  LCommandLine := TCommandLine.Create('doctor');
  try
    LCommandLine.AddGlobalOptions;
    LCommandLine.Parse(AArgv);

    if LCommandLine.Flag('help') then
    begin
      PrintCommandHelp('doctor', '[options]',
        'Report the compiler, paths and package Struo detected.' + LineEnding +
        'The first thing to check when a build behaves unexpectedly.',
        LCommandLine);
      Exit(CExitOk);
    end;
    ApplyGlobalOptions(LCommandLine);

    LProblems := nil;

    Report('Struo', CStruoVersion);
    ReportCompiler(HostCompiler, LProblems);
    Report('Struo home', StruoHome);
    ReportTools;
    SayBlank;
    ReportPackage;

    if Length(LProblems) > 0 then
    begin
      SayBlank;
      for I := 0 to High(LProblems) do
        Warn(LProblems[I]);
    end;

    { Always zero. A report that fails because it has something to report
      would be useless in the situation it exists for. }
    Result := CExitOk;
  finally
    LCommandLine.Free;
  end;
end;

end.
