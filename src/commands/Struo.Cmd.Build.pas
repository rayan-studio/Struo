{ Struo.Cmd.Build -- `struo build` and `struo check`.

  This is the backbone: `run`, `test` and `check` are all this command with a
  different target selection or a different final step, so the compile loop
  lives here and they call into it.

  Target order is not arbitrary. The library compiles first, because the
  binaries and tests `uses` it and the compiler needs its .ppu to exist. That
  is also why every target compiles its units into one directory per profile
  rather than per target: it is what makes the second compile cheap. }
unit Struo.Cmd.Build;

{$mode objfpc}{$H+}

interface

uses
  Struo.Util.Strings, Struo.Types, Struo.Manifest, Struo.Cli.Args;

type
  { Which targets a command wants built. OnlyName, when set, narrows the
    selection to the one target of the wanted kinds carrying that name. }
  TTargetSelection = record
    WantLib: Boolean;
    WantBins: Boolean;
    WantTests: Boolean;
    WantExamples: Boolean;
    OnlyName: string;
  end;

{ The library and the binaries: what `struo build` does with no options. }
function DefaultSelection: TTargetSelection;

{ Compiles the selected targets, in dependency order. Returns how many were
  compiled. Raises EStruoError, after printing the compiler's diagnostics,
  when any of them fails. }
function BuildTargets(AManifest: TManifest; AProfile: TBuildProfile;
  const ASelection: TTargetSelection; ACheckOnly: Boolean): Integer;

{ Re-resolves the dependency graph and rewrites Struo.lock if it changed.
  Shared by add, remove and update, which all leave the lockfile current.
  With ADryRun, reports what would change and writes nothing. }
procedure RefreshLockfile(AManifest: TManifest; ADryRun: Boolean = False);

{ The absolute path of the executable a target produces. }
function TargetOutputPath(AManifest: TManifest; AProfile: TBuildProfile;
  const ATarget: TTarget): string;

{ The options shared by build, check, run and test. }
procedure DeclareBuildOptions(ACommandLine: TCommandLine);
function ProfileFromOptions(ACommandLine: TCommandLine): TBuildProfile;
function SelectionFromOptions(ACommandLine: TCommandLine): TTargetSelection;

function RunBuild(const AArgv: TStrArray): Integer;
function RunCheck(const AArgv: TStrArray): Integer;

implementation

uses
  SysUtils, Struo.Util.Fs, Struo.Paths, Struo.SemVer, Struo.Targets,
  Struo.Compiler, Struo.Lockfile, Struo.Resolver, Struo.Workspace,
  Struo.Cli.Output, Struo.Cli.Command;

function DefaultSelection: TTargetSelection;
begin
  Result := Default(TTargetSelection);
  Result.WantLib := True;
  Result.WantBins := True;
end;

{ ---- target ordering ----------------------------------------------------- }

{ True when ATarget is one the selection asked for. }
function Wanted(const ASelection: TTargetSelection; const ATarget: TTarget): Boolean;
begin
  case ATarget.Kind of
    tgLib:     Result := ASelection.WantLib;
    tgBin:     Result := ASelection.WantBins;
    tgTest:    Result := ASelection.WantTests;
    tgExample: Result := ASelection.WantExamples;
  else
    Result := False;
  end;

  { OnlyName narrows binaries, tests and examples, but never excludes the
    library: a named binary still needs the library it uses. }
  if Result and (ASelection.OnlyName <> '') and (ATarget.Kind <> tgLib) then
    Result := SameText(ATarget.Name, ASelection.OnlyName);
end;

{ The selected targets, library first. }
function CollectSelected(AManifest: TManifest;
  const ASelection: TTargetSelection): TTargetArray;
const
  { The order the compiler needs: a library's units must exist before
    anything that uses them is compiled. }
  COrder: array[0 .. 3] of TTargetKind = (tgLib, tgBin, tgTest, tgExample);
var
  LKind, I: Integer;
begin
  Result := nil;
  for LKind := Low(COrder) to High(COrder) do
    for I := 0 to High(AManifest.Targets) do
      if (AManifest.Targets[I].Kind = COrder[LKind]) and
         Wanted(ASelection, AManifest.Targets[I]) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := AManifest.Targets[I];
      end;
end;

function TargetOutputPath(AManifest: TManifest; AProfile: TBuildProfile;
  const ATarget: TTarget): string;
begin
  case ATarget.Kind of
    tgLib:
      { A library produces units, not a file of its own. }
      Result := '';
    tgTest, tgExample:
      { Kept out of the profile root so `struo build` followed by `struo test`
        does not leave test binaries sitting next to the real ones. }
      Result := JoinPath(TestOutputDir(AManifest.Root, AProfile),
                         ExecutableName(ATarget.Name));
  else
    Result := JoinPath(ProfileDir(AManifest.Root, AProfile),
                       ExecutableName(ATarget.Name));
  end;
end;

{ ---- the compile loop ---------------------------------------------------- }

{ '[unoptimized + debuginfo]' or '[optimized]', as Cargo's Finished line
  reports what kind of build just happened. }
function ProfileDescriptor(const ASettings: TProfileSettings): string;
var
  LParts: TStrArray;
begin
  LParts := nil;
  if ASettings.Optimize = 0 then
    StrArrayAdd(LParts, 'unoptimized')
  else
    StrArrayAdd(LParts, 'optimized');
  if ASettings.Debug then
    StrArrayAdd(LParts, 'debuginfo');
  Result := '[' + JoinStr(LParts, ' + ') + ']';
end;

{ ---- dependencies -------------------------------------------------------- }

{ The unit output directories of APackage's transitive dependencies, so a
  package sees exactly what it declared and not whatever else happens to have
  been compiled. ADirs runs parallel to the graph. }
function TransitiveUnitPaths(AGraph: TDependencyGraph; const ADirs: TStrArray;
  const ANames: TStrArray): TStrArray;
var
  LPending: TStrArray;
  LPackage: TResolvedPackage;
  I, J: Integer;
begin
  Result := nil;
  LPending := Copy(ANames, 0, Length(ANames));

  I := 0;
  while I < Length(LPending) do
  begin
    if AGraph.Find(LPending[I], LPackage) then
    begin
      { Find the package's slot to read its output directory. }
      for J := 0 to AGraph.Count - 1 do
        if SameText(AGraph.PackageAt(J).Name, LPackage.Name) then
        begin
          StrArrayAddUnique(Result, ADirs[J]);
          Break;
        end;
      for J := 0 to High(LPackage.DependencyNames) do
        StrArrayAddUnique(LPending, LPackage.DependencyNames[J]);
    end;
    Inc(I);
  end;
end;

{ Compiles every dependency's library, in the order the resolver produced, and
  returns their unit output directories parallel to the graph. }
function BuildDependencies(const ACompiler: TCompilerInfo;
  AManifest: TManifest; AProfile: TBuildProfile;
  AGraph: TDependencyGraph): TStrArray;
var
  LPackage: TResolvedPackage;
  LLibrary: TTarget;
  LRequest: TCompileRequest;
  LOutcome: TCompileResult;
  I: Integer;
begin
  Result := nil;
  SetLength(Result, AGraph.Count);

  for I := 0 to AGraph.Count - 1 do
  begin
    LPackage := AGraph.PackageAt(I);

    { Each dependency gets its own directory, keyed by name and version, so
      two builds of the same package never overwrite each other's units. }
    Result[I] := DependencyUnitDir(AManifest.Root, AProfile, LPackage.Name,
      SemVerToStr(LPackage.Version));

    if LPackage.IsRoot then
      Continue;

    if not LPackage.Manifest.HasLibrary(LLibrary) then
    begin
      { A dependency with no library has nothing a dependent could use. Worth
        saying, because the author probably meant it to have one. }
      Warn(Format('dependency `%s` has no library unit, so nothing was ' +
                  'compiled from it', [LPackage.Name]));
      Continue;
    end;

    LRequest := RequestFromManifest(LPackage.Manifest, AProfile);
    LRequest.SourceFile := TargetSourceFile(LPackage.Manifest, LLibrary);
    LRequest.UnitOutputDir := Result[I];
    LRequest.OutputFile := '';
    StrArrayAddUnique(LRequest.UnitSearchPaths, Result[I]);
    StrArrayAddAll(LRequest.UnitSearchPaths,
      TransitiveUnitPaths(AGraph, Result, LPackage.DependencyNames));

    Status('Compiling', Format('%s v%s', [LPackage.Name,
      SemVerToStr(LPackage.Version)]));

    LOutcome := Compile(ACompiler, LRequest);
    TraceFmt('%s', [LOutcome.Command]);
    Diagnostics(LOutcome.Output);

    if not LOutcome.Success then
      raise EStruoError.CreateHintFmt('could not compile dependency `%s v%s`',
        [LPackage.Name, SemVerToStr(LPackage.Version)],
        Format('its source is at `%s`', [LPackage.Root]));
  end;
end;

{ Writes Struo.lock when the resolved graph differs from what is on disk.

  A package with no dependencies gets no lockfile unless it already has one:
  a file recording that `hello` depends on nothing is noise in a repository,
  and the first dependency will create it. }
{ AAnnounce is True when the user asked about the lockfile -- update, add,
  remove -- and False during a build, where `already up to date` is noise on
  every single run. }
procedure SyncLockfile(AManifest: TManifest; AGraph: TDependencyGraph;
  ADryRun, AAnnounce: Boolean);
var
  LPath: string;
  LResolved, LOnDisk: TLockfile;
begin
  LPath := JoinPath(AManifest.Root, CLockfileName);
  LResolved := AGraph.ToLockfile;
  try
    if (AGraph.Dependencies = 0) and not PathIsFile(LPath) then
      Exit;

    LOnDisk := TLockfile.Load(LPath);
    try
      if LResolved.SameAs(LOnDisk) then
      begin
        if AAnnounce then
          Status('Unchanged', Format('%s already matches %s',
            [CLockfileName, CManifestName]))
        else
          TraceFmt('%s is up to date', [CLockfileName]);
        Exit;
      end;

      if ADryRun then
      begin
        Note('Dry run', Format('%s would record %d package(s)',
          [CLockfileName, LResolved.Count]));
        Exit;
      end;

      LResolved.Save(LPath);
      Status('Locking', Format('%d package(s) in %s',
        [LResolved.Count, CLockfileName]));
    finally
      LOnDisk.Free;
    end;
  finally
    LResolved.Free;
  end;
end;

procedure RefreshLockfile(AManifest: TManifest; ADryRun: Boolean);
var
  LGraph: TDependencyGraph;
begin
  { Dev dependencies are included, because the lockfile has to describe
    everything a clone might build, tests among them. }
  LGraph := ResolveGraph(AManifest, True);
  try
    SyncLockfile(AManifest, LGraph, ADryRun, True);
  finally
    LGraph.Free;
  end;
end;

{ ---- the compile loop ---------------------------------------------------- }

function BuildTargets(AManifest: TManifest; AProfile: TBuildProfile;
  const ASelection: TTargetSelection; ACheckOnly: Boolean): Integer;
var
  LCompiler: TCompilerInfo;
  LBase, LRequest: TCompileRequest;
  LTargets: TTargetArray;
  LOutcome: TCompileResult;
  LGraph: TDependencyGraph;
  LDependencyDirs, LRootNames: TStrArray;
  LUnitDir, LWhat: string;
  LStart: TDateTime;
  I: Integer;
begin
  LCompiler := HostCompiler;
  RequireCompiler(LCompiler);

  LTargets := CollectSelected(AManifest, ASelection);
  if Length(LTargets) = 0 then
  begin
    if ASelection.OnlyName <> '' then
      raise EStruoError.CreateHintFmt('no target named `%s`',
        [ASelection.OnlyName],
        'run `struo build --all-targets --verbose` to see what this package has');
    raise EStruoError.CreateHintFmt('package `%s` has nothing to build',
      [AManifest.Name], '');
  end;

  LStart := Now;

  TraceFmt('compiler %s %s (%s)',
    [LCompiler.Version, LCompiler.Target, LCompiler.Path]);
  if not LCompiler.HasConfig then
    TraceFmt('no fpc.cfg was found; using the packaged units at %s',
      [LCompiler.UnitsDir]);

  { Dev dependencies are only needed when something that uses them is being
    built. }
  LGraph := ResolveGraph(AManifest,
    ASelection.WantTests or ASelection.WantExamples);
  try
    SyncLockfile(AManifest, LGraph, False, False);
    LDependencyDirs := BuildDependencies(LCompiler, AManifest, AProfile, LGraph);

    LBase := RequestFromManifest(AManifest, AProfile);
    LUnitDir := UnitOutputDir(AManifest.Root, AProfile);

    { Everything this package compiles lands in one unit directory, and that
      directory is on the search path, so a binary finds the library that was
      compiled a moment earlier. }
    StrArrayAddUnique(LBase.UnitSearchPaths, LUnitDir);

    LRootNames := nil;
    for I := 0 to High(AManifest.Dependencies) do
      StrArrayAdd(LRootNames, AManifest.Dependencies[I].Name);
    StrArrayAddAll(LBase.UnitSearchPaths,
      TransitiveUnitPaths(LGraph, LDependencyDirs, LRootNames));

    Status('Compiling', Format('%s (%s)', [AManifest.Describe, AManifest.Root]));

    for I := 0 to High(LTargets) do
    begin
      LRequest := LBase;
      LRequest.SourceFile := TargetSourceFile(AManifest, LTargets[I]);
      LRequest.UnitOutputDir := LUnitDir;
      LRequest.CheckOnly := ACheckOnly;
      LRequest.OutputFile := TargetOutputPath(AManifest, AProfile, LTargets[I]);

      { A test or an example is a program of its own; its units must not mix
        with the library's, or a stale test unit could satisfy a real build. }
      if LTargets[I].Kind in [tgTest, tgExample] then
      begin
        LRequest.UnitOutputDir := TestOutputDir(AManifest.Root, AProfile);
        { It still needs the library's units, which are in the main directory. }
        StrArrayAddUnique(LRequest.UnitSearchPaths, LUnitDir);
      end;

      LWhat := Format('%s `%s`',
        [TargetKindName(LTargets[I].Kind), LTargets[I].Name]);
      TraceFmt('building %s from %s', [LWhat, LTargets[I].SourcePath]);

      LOutcome := Compile(LCompiler, LRequest);
      TraceFmt('%s', [LOutcome.Command]);
      Diagnostics(LOutcome.Output);

      if not LOutcome.Success then
        raise EStruoError.CreateHintFmt('could not compile %s of `%s`',
          [LWhat, AManifest.Name],
          'the compiler''s diagnostics are above; run with --verbose to see ' +
          'the exact command');
    end;

    if ACheckOnly then
      Status('Finished', Format('checked %d target(s) in %s',
        [Length(LTargets), FormatDuration((Now - LStart) * SecsPerDay)]))
    else
      Status('Finished', Format('`%s` profile %s in %s',
        [ProfileName(AProfile),
         ProfileDescriptor(AManifest.Profile(AProfile)),
         FormatDuration((Now - LStart) * SecsPerDay)]));

    Result := Length(LTargets);
  finally
    LGraph.Free;
  end;
end;

{ ---- options ------------------------------------------------------------- }

procedure DeclareBuildOptions(ACommandLine: TCommandLine);
begin
  ACommandLine.AddFlag('release', '', 'Build with the release profile');
  ACommandLine.AddValue('profile', '', 'name', 'Build with a named profile');
  ACommandLine.AddValue('bin', '', 'name', 'Build only this binary');
  ACommandLine.AddFlag('lib', '', 'Build only the library');
  ACommandLine.AddFlag('all-targets',  '',
    'Build the binaries, the tests and the examples');
  ACommandLine.AddGlobalOptions;
end;

function ProfileFromOptions(ACommandLine: TCommandLine): TBuildProfile;
var
  LName: string;
begin
  if ACommandLine.HasValue('profile') then
  begin
    LName := LowerCase(ACommandLine.Value('profile', 'debug'));
    if ACommandLine.Flag('release') and (LName <> 'release') then
      raise EStruoUsageError.CreateHint(
        '--release and --profile disagree about which profile to use',
        'pass one or the other');
    if not TryParseProfileName(LName, Result) then
      raise EStruoUsageError.CreateHintFmt('unknown profile `%s`', [LName],
        'the profiles are debug and release');
    Exit;
  end;

  if ACommandLine.Flag('release') then
    Result := bpRelease
  else
    Result := bpDebug;
end;

function SelectionFromOptions(ACommandLine: TCommandLine): TTargetSelection;
begin
  Result := Default(TTargetSelection);

  if ACommandLine.Flag('lib') and ACommandLine.HasValue('bin') then
    raise EStruoUsageError.CreateHint('--lib and --bin select different things',
      'pass one or the other');

  if ACommandLine.Flag('all-targets') then
  begin
    Result.WantLib := True;
    Result.WantBins := True;
    Result.WantTests := True;
    Result.WantExamples := True;
    Exit;
  end;

  if ACommandLine.Flag('lib') then
  begin
    Result.WantLib := True;
    Exit;
  end;

  if ACommandLine.HasValue('bin') then
  begin
    { The library comes along because the binary almost certainly uses it. }
    Result.WantLib := True;
    Result.WantBins := True;
    Result.OnlyName := ACommandLine.Value('bin', '');
    Exit;
  end;

  Result := DefaultSelection;
end;

{ ---- entry points -------------------------------------------------------- }

{ build and check differ by one boolean, so they share this. }
function RunBuildOrCheck(const AArgv: TStrArray; ACheckOnly: Boolean): Integer;
var
  LCommandLine: TCommandLine;
  LManifest: TManifest;
  LName: string;
begin
  if ACheckOnly then
    LName := 'check'
  else
    LName := 'build';

  LCommandLine := TCommandLine.Create(LName);
  try
    DeclareBuildOptions(LCommandLine);
    LCommandLine.Parse(AArgv);

    if LCommandLine.Flag('help') then
    begin
      if ACheckOnly then
        PrintCommandHelp('check', '[options]',
          'Compile the package for diagnostics only, without linking.' +
          LineEnding + 'Faster than `struo build` when you just want to know ' +
          'whether the code is valid.', LCommandLine)
      else
        PrintCommandHelp('build', '[options]',
          'Compile the package and everything it depends on.', LCommandLine);
      Exit(CExitOk);
    end;
    ApplyGlobalOptions(LCommandLine);

    LManifest := OpenPackage(LCommandLine.Value('manifest-path', ''));
    try
      BuildTargets(LManifest, ProfileFromOptions(LCommandLine),
        SelectionFromOptions(LCommandLine), ACheckOnly);
    finally
      LManifest.Free;
    end;
    Result := CExitOk;
  finally
    LCommandLine.Free;
  end;
end;

function RunBuild(const AArgv: TStrArray): Integer;
begin
  Result := RunBuildOrCheck(AArgv, False);
end;

function RunCheck(const AArgv: TStrArray): Integer;
begin
  Result := RunBuildOrCheck(AArgv, True);
end;

end.
