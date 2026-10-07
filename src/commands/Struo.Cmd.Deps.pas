{ Struo.Cmd.Deps -- `struo add`, `remove`, `update` and `tree`.

  `add` resolves the dependency before writing it. That ordering is the whole
  point: a path or git dependency is fetched and its manifest read first, so
  the version written into Struo.toml is the one that is actually there, and a
  typo in a url fails before it has edited the user's file. A manifest left
  naming something that does not exist is worse than a command that refused.

  The registry is not live yet, so `struo add fjson` with no source says so
  and names the two forms that do work. Writing an entry Struo cannot fetch
  would turn one clear error into a confusing one at the next build. }
unit Struo.Cmd.Deps;

{$mode objfpc}{$H+}

interface

uses
  Struo.Util.Strings;

function RunAdd(const AArgv: TStrArray): Integer;
function RunRemove(const AArgv: TStrArray): Integer;
function RunUpdate(const AArgv: TStrArray): Integer;
function RunTree(const AArgv: TStrArray): Integer;

implementation

uses
  SysUtils, Struo.Types, Struo.Util.Fs, Struo.SemVer, Struo.Manifest,
  Struo.Manifest.Editor, Struo.Lockfile, Struo.Resolver, Struo.Source,
  Struo.Targets, Struo.Workspace, Struo.Cli.Args, Struo.Cli.Output,
  Struo.Cli.Command, Struo.Cmd.Build;

{ ---- struo add ----------------------------------------------------------- }

{ Builds the dependency the options describe, without touching the disk. }
function DependencyFromOptions(const AName: string;
  ACommandLine: TCommandLine): TDependency;
var
  LPins: Integer;
begin
  Result := Default(TDependency);
  Result.Name := AName;
  Result.IsDev := ACommandLine.Flag('dev');
  Result.Optional := ACommandLine.Flag('optional');
  Result.UseDefaultFeatures := not ACommandLine.Flag('no-default-features');
  Result.Features := ACommandLine.ListValue('features');
  Result.Req := AnyVersionReq;

  if not IsValidPackageName(AName) then
    raise EStruoUsageError.CreateHintFmt('`%s` is not a valid package name',
      [AName], 'use only letters, digits, `-` and `_`, starting with a letter');

  if ACommandLine.HasValue('path') and ACommandLine.HasValue('git') then
    raise EStruoUsageError.CreateHint(
      '--path and --git are two different sources', 'pass one or the other');

  if ACommandLine.HasValue('path') then
  begin
    Result.Kind := dkPath;
    Result.Path := ACommandLine.Value('path', '');
    Exit;
  end;

  if ACommandLine.HasValue('git') then
  begin
    Result.Kind := dkGit;
    Result.GitUrl := ACommandLine.Value('git', '');

    LPins := 0;
    if ACommandLine.HasValue('branch') then
    begin
      Inc(LPins);
      Result.PinKind := gpBranch;
      Result.PinValue := ACommandLine.Value('branch', '');
    end;
    if ACommandLine.HasValue('tag') then
    begin
      Inc(LPins);
      Result.PinKind := gpTag;
      Result.PinValue := ACommandLine.Value('tag', '');
    end;
    if ACommandLine.HasValue('rev') then
    begin
      Inc(LPins);
      Result.PinKind := gpRev;
      Result.PinValue := ACommandLine.Value('rev', '');
    end;
    if LPins > 1 then
      raise EStruoUsageError.CreateHint(
        '--branch, --tag and --rev pin the same thing three ways',
        'pass one of them');
    Exit;
  end;

  { No source given: a registry dependency, which is not possible yet. }
  Result.Kind := dkRegistry;
  if ACommandLine.HasValue('version') then
    Result.Req := ParseVersionReq(ACommandLine.Value('version', ''));
end;

{ Reads the dependency's own manifest to confirm it exists, that it calls
  itself what the user said, and what version it is at. Returns the version
  for the status line. }
function VerifyDependency(var ADependency: TDependency;
  AParent: TManifest): string;
var
  LRoot, LRevision: string;
  LManifest: TManifest;
begin
  LRevision := '';
  case ADependency.Kind of
    dkPath:
      LRoot := ResolvePathSource(ADependency, AParent.Root);
    dkGit:
      LRoot := FetchGitSource(ADependency, LRevision);
  else
    FailRegistryNotAvailable(ADependency.Name);
    LRoot := '';
  end;

  LManifest := TManifest.Load(JoinPath(LRoot, CManifestName));
  try
    if not SameText(LManifest.Name, ADependency.Name) then
      raise EStruoError.CreateHintFmt(
        'that source is a package called `%s`, not `%s`',
        [LManifest.Name, ADependency.Name],
        Format('run `struo add %s` with the same source instead',
          [LManifest.Name]));
    Result := SemVerToStr(LManifest.Version);
  finally
    LManifest.Free;
  end;
end;

function RunAdd(const AArgv: TStrArray): Integer;
var
  LCommandLine: TCommandLine;
  LManifest: TManifest;
  LEditor: TManifestEditor;
  LDependency: TDependency;
  LNames: TStrArray;
  LVersion, LSection: string;
  LReplaced: Boolean;
  I: Integer;
begin
  LCommandLine := TCommandLine.Create('add');
  try
    LCommandLine.AddValue('version', '', 'req',
      'The version requirement, as "1.2" or ">=1.2, <1.5"');
    LCommandLine.AddValue('path', '', 'dir', 'Depend on a package on disk');
    LCommandLine.AddValue('git', '', 'url', 'Depend on a git repository');
    LCommandLine.AddValue('branch', '', 'name', 'Pin the git dependency to a branch');
    LCommandLine.AddValue('tag', '', 'name', 'Pin the git dependency to a tag');
    LCommandLine.AddValue('rev', '', 'sha', 'Pin the git dependency to a commit');
    LCommandLine.AddFlag('dev', '', 'Add under [dev-dependencies]');
    LCommandLine.AddFlag('optional', '', 'Mark the dependency optional');
    LCommandLine.AddFlag('no-default-features', '',
      'Do not enable the dependency''s default features');
    LCommandLine.AddValue('features', '', 'list',
      'Comma-separated features to enable');
    LCommandLine.AddFlag('dry-run', '', 'Report what would change, write nothing');
    LCommandLine.AddGlobalOptions;
    LCommandLine.Parse(AArgv);

    if LCommandLine.Flag('help') then
    begin
      PrintCommandHelp('add', '<name>... [options]',
        'Add dependencies to ' + CManifestName + '.' + LineEnding +
        'The manifest is edited in place: comments and formatting survive.',
        LCommandLine);
      Exit(CExitOk);
    end;
    ApplyGlobalOptions(LCommandLine);

    LNames := LCommandLine.Positionals;
    if Length(LNames) = 0 then
      raise EStruoUsageError.CreateHint('`struo add` needs a package name',
        'for example: `struo add fcolor --git https://github.com/x/fcolor`');

    { Several names can only share one source, since a --path names one
      directory. }
    if (Length(LNames) > 1) and
       (LCommandLine.HasValue('path') or LCommandLine.HasValue('git')) then
      raise EStruoUsageError.CreateHint(
        '--path and --git describe one source, so they take one package',
        'run `struo add` once per package');

    LManifest := OpenManifestOnly(LCommandLine.Value('manifest-path', ''));
    try
      LEditor := TManifestEditor.Create(LManifest.ManifestPath);
      try
        for I := 0 to High(LNames) do
        begin
          LDependency := DependencyFromOptions(LNames[I], LCommandLine);

          { Fetched and checked before the manifest is touched, so a typo in a
            url leaves the file alone. }
          LVersion := VerifyDependency(LDependency, LManifest);

          LSection := SectionFor(LDependency);
          LReplaced := LEditor.SetEntry(LSection, LDependency.Name,
            RenderDependencyValue(LDependency));

          if LReplaced then
            Note('Updating', Format('%s v%s in %s',
              [LDependency.Name, LVersion, LSection]))
          else
            Note('Adding', Format('%s v%s to %s',
              [LDependency.Name, LVersion, LSection]));
        end;

        if LCommandLine.Flag('dry-run') then
        begin
          Note('Dry run', 'nothing was written; ' + CManifestName +
                          ' would become:');
          SayBlank;
          Say(LEditor.Text);
          Exit(CExitOk);
        end;

        LEditor.Save;
      finally
        LEditor.Free;
      end;
    finally
      LManifest.Free;
    end;

    { Re-resolve so Struo.lock reflects the new manifest straight away, the
      way `cargo add` leaves the lockfile current. }
    LManifest := OpenManifestOnly(LCommandLine.Value('manifest-path', ''));
    try
      RefreshLockfile(LManifest);
    finally
      LManifest.Free;
    end;

    Result := CExitOk;
  finally
    LCommandLine.Free;
  end;
end;

{ ---- struo remove -------------------------------------------------------- }

function RunRemove(const AArgv: TStrArray): Integer;
var
  LCommandLine: TCommandLine;
  LManifest: TManifest;
  LEditor: TManifestEditor;
  LNames: TStrArray;
  LRemoved: Boolean;
  I: Integer;
begin
  LCommandLine := TCommandLine.Create('remove');
  try
    LCommandLine.AddFlag('dev', '', 'Remove from [dev-dependencies]');
    LCommandLine.AddFlag('dry-run', '', 'Report what would change, write nothing');
    LCommandLine.AddGlobalOptions;
    LCommandLine.Parse(AArgv);

    if LCommandLine.Flag('help') then
    begin
      PrintCommandHelp('remove', '<name>... [options]',
        'Drop dependencies from ' + CManifestName + '.', LCommandLine);
      Exit(CExitOk);
    end;
    ApplyGlobalOptions(LCommandLine);

    LNames := LCommandLine.Positionals;
    if Length(LNames) = 0 then
      raise EStruoUsageError.CreateHint('`struo remove` needs a package name', '');

    LManifest := OpenManifestOnly(LCommandLine.Value('manifest-path', ''));
    try
      LEditor := TManifestEditor.Create(LManifest.ManifestPath);
      try
        for I := 0 to High(LNames) do
        begin
          if LCommandLine.Flag('dev') then
            LRemoved := LEditor.RemoveEntry(CDevDependenciesSection, LNames[I])
          else
          begin
            LRemoved := LEditor.RemoveEntry(CDependenciesSection, LNames[I]);
            { Fall back to the dev section, so `struo remove x` works without
              the user recalling which section declared x. }
            if not LRemoved then
              LRemoved := LEditor.RemoveEntry(CDevDependenciesSection, LNames[I]);
          end;

          if not LRemoved then
            raise EStruoError.CreateHintFmt('`%s` is not a dependency of `%s`',
              [LNames[I], LManifest.Name],
              'run `struo tree` to see what is');
          Note('Removing', LNames[I]);
        end;

        if LCommandLine.Flag('dry-run') then
        begin
          Note('Dry run', 'nothing was written');
          Exit(CExitOk);
        end;
        LEditor.Save;
      finally
        LEditor.Free;
      end;
    finally
      LManifest.Free;
    end;

    LManifest := OpenManifestOnly(LCommandLine.Value('manifest-path', ''));
    try
      RefreshLockfile(LManifest);
    finally
      LManifest.Free;
    end;

    Result := CExitOk;
  finally
    LCommandLine.Free;
  end;
end;

{ ---- struo update -------------------------------------------------------- }

function RunUpdate(const AArgv: TStrArray): Integer;
var
  LCommandLine: TCommandLine;
  LManifest: TManifest;
begin
  LCommandLine := TCommandLine.Create('update');
  try
    LCommandLine.AddFlag('dry-run', '',
      'Report what would change, write nothing');
    LCommandLine.AddGlobalOptions;
    LCommandLine.Parse(AArgv);

    if LCommandLine.Flag('help') then
    begin
      PrintCommandHelp('update', '[options]',
        'Re-resolve dependencies and rewrite ' + CLockfileName + '.' +
        LineEnding +
        'Git dependencies pinned to a branch or a tag are refetched, so this ' +
        'is how you move to' + LineEnding +
        'a newer commit without changing ' + CManifestName + '.', LCommandLine);
      Exit(CExitOk);
    end;
    ApplyGlobalOptions(LCommandLine);

    LManifest := OpenManifestOnly(LCommandLine.Value('manifest-path', ''));
    try
      RefreshLockfile(LManifest, LCommandLine.Flag('dry-run'));
    finally
      LManifest.Free;
    end;
    Result := CExitOk;
  finally
    LCommandLine.Free;
  end;
end;

{ ---- struo tree ---------------------------------------------------------- }

{ Draws one level of the tree. ASeen carries the names already printed, so a
  package shared by two dependents is expanded once and marked (*) after. }
procedure DrawNode(AGraph: TDependencyGraph; const AName, APrefix: string;
  AIsLast: Boolean; var ASeen: TStrArray);
var
  LPackage: TResolvedPackage;
  LConnector, LChildPrefix, LLabel: string;
  LRepeat: Boolean;
  I: Integer;
begin
  if not AGraph.Find(AName, LPackage) then
    Exit;

  if AIsLast then
  begin
    LConnector := '`-- ';
    LChildPrefix := APrefix + '    ';
  end
  else
  begin
    LConnector := '|-- ';
    LChildPrefix := APrefix + '|   ';
  end;

  LRepeat := StrArrayHas(ASeen, LowerCase(LPackage.Name));
  LLabel := Format('%s v%s', [LPackage.Name, SemVerToStr(LPackage.Version)]);
  if LRepeat then
    { Already expanded above. Repeating the subtree would make a diamond look
      like duplication. }
    LLabel := LLabel + ' (*)';

  Say(APrefix + LConnector + LLabel);
  if LRepeat then
    Exit;

  StrArrayAdd(ASeen, LowerCase(LPackage.Name));
  for I := 0 to High(LPackage.DependencyNames) do
    DrawNode(AGraph, LPackage.DependencyNames[I], LChildPrefix,
      I = High(LPackage.DependencyNames), ASeen);
end;

function RunTree(const AArgv: TStrArray): Integer;
var
  LCommandLine: TCommandLine;
  LManifest: TManifest;
  LGraph: TDependencyGraph;
  LRoot: TResolvedPackage;
  LSeen: TStrArray;
  I: Integer;
begin
  LCommandLine := TCommandLine.Create('tree');
  try
    LCommandLine.AddFlag('dev', '', 'Include dev dependencies');
    LCommandLine.AddGlobalOptions;
    LCommandLine.Parse(AArgv);

    if LCommandLine.Flag('help') then
    begin
      PrintCommandHelp('tree', '[options]',
        'Print the resolved dependency graph.', LCommandLine);
      Exit(CExitOk);
    end;
    ApplyGlobalOptions(LCommandLine);

    LManifest := OpenManifestOnly(LCommandLine.Value('manifest-path', ''));
    try
      LGraph := ResolveGraph(LManifest, LCommandLine.Flag('dev'));
      try
        if not LGraph.Find(LManifest.Name, LRoot) then
          raise EStruoError.CreateHint('the root package is not in the graph',
            'this is a bug in Struo');

        Say(Format('%s v%s (%s)',
          [LRoot.Name, SemVerToStr(LRoot.Version), LRoot.Root]));

        LSeen := nil;
        StrArrayAdd(LSeen, LowerCase(LRoot.Name));
        for I := 0 to High(LRoot.DependencyNames) do
          DrawNode(LGraph, LRoot.DependencyNames[I], '',
            I = High(LRoot.DependencyNames), LSeen);

        if Length(LRoot.DependencyNames) = 0 then
          Say('(no dependencies)');
      finally
        LGraph.Free;
      end;
    finally
      LManifest.Free;
    end;
    Result := CExitOk;
  finally
    LCommandLine.Free;
  end;
end;

end.
