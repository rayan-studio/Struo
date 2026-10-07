{ Struo.Cmd.New -- `struo new` and `struo init`.

  The two commands are the same work with a different destination, so they
  share everything below CreatePackage.

  What gets written matters more than it looks: this is the first Struo a new
  user reads, and it is the shape every package in the ecosystem will copy.
  So the manifest is four lines rather than a commented template nobody
  prunes, the source file compiles and runs, and target/ is in .gitignore
  from the first commit rather than after someone notices. }
unit Struo.Cmd.New;

{$mode objfpc}{$H+}

interface

uses
  Struo.Util.Strings;

function RunNew(const AArgv: TStrArray): Integer;
function RunInit(const AArgv: TStrArray): Integer;

implementation

uses
  SysUtils, Struo.Types, Struo.Util.Fs, Struo.Util.Proc,
  Struo.Manifest, Struo.Paths, Struo.Cli.Args, Struo.Cli.Output,
  Struo.Cli.Command;

type
  TPackageShape = (psBinary, psLibrary);

{ ---- templates ----------------------------------------------------------- }

function ManifestTemplate(const AName: string): string;
begin
  { Deliberately minimal. Everything omitted has a documented default, and a
    manifest a reader can take in at a glance teaches the format better than
    one full of commented-out keys. }
  Result :=
    '[package]' + LineEnding +
    'name = "' + AName + '"' + LineEnding +
    'version = "0.1.0"' + LineEnding +
    'edition = "' + CCurrentEdition + '"' + LineEnding +
    LineEnding +
    '[dependencies]' + LineEnding;
end;

function BinaryTemplate(const AName: string): string;
begin
  Result :=
    'program ' + DefaultUnitName(AName) + ';' + LineEnding +
    LineEnding +
    '{$mode objfpc}{$H+}' + LineEnding +
    LineEnding +
    'begin' + LineEnding +
    '  WriteLn(''Hello, world!'');' + LineEnding +
    'end.' + LineEnding;
end;

function LibraryTemplate(const AName: string): string;
var
  LUnit: string;
begin
  LUnit := DefaultUnitName(AName);
  Result :=
    'unit ' + LUnit + ';' + LineEnding +
    LineEnding +
    '{$mode objfpc}{$H+}' + LineEnding +
    LineEnding +
    'interface' + LineEnding +
    LineEnding +
    'function Greet(const AName: string): string;' + LineEnding +
    LineEnding +
    'implementation' + LineEnding +
    LineEnding +
    'function Greet(const AName: string): string;' + LineEnding +
    'begin' + LineEnding +
    '  Result := ''Hello, '' + AName + ''!'';' + LineEnding +
    'end;' + LineEnding +
    LineEnding +
    'end.' + LineEnding;
end;

function LibraryTestTemplate(const AName: string): string;
var
  LUnit: string;
begin
  LUnit := DefaultUnitName(AName);
  { A library package gets a test that already passes, so `struo test` has
    something to say on the first run and the convention is visible. }
  Result :=
    'program test_' + LUnit + ';' + LineEnding +
    LineEnding +
    '{$mode objfpc}{$H+}' + LineEnding +
    LineEnding +
    'uses' + LineEnding +
    '  ' + LUnit + ';' + LineEnding +
    LineEnding +
    'begin' + LineEnding +
    '  if Greet(''world'') <> ''Hello, world!'' then' + LineEnding +
    '  begin' + LineEnding +
    '    WriteLn(''Greet returned the wrong text'');' + LineEnding +
    '    Halt(1);' + LineEnding +
    '  end;' + LineEnding +
    '  WriteLn(''ok'');' + LineEnding +
    'end.' + LineEnding;
end;

function GitignoreTemplate: string;
begin
  Result :=
    '# Struo build output' + LineEnding +
    '/' + CTargetDirName + '/' + LineEnding +
    LineEnding +
    '# Free Pascal artifacts' + LineEnding +
    '*.o' + LineEnding +
    '*.ppu' + LineEnding +
    '*.compiled' + LineEnding +
    '*.exe' + LineEnding;
end;

{ ---- git ----------------------------------------------------------------- }

{ Initialises a repository in ARoot. A missing git is a warning, not a
  failure: the package is already written and perfectly usable without it. }
procedure InitialiseGit(const ARoot: string);
var
  LGit: string;
  LOutcome: TProcOutcome;
begin
  LGit := FindExecutable('git');
  if LGit = '' then
  begin
    Warn('git was not found, so no repository was created');
    Exit;
  end;

  if PathIsDir(JoinPath(ARoot, '.git')) then
  begin
    TraceFmt('`%s` is already a git repository', [ARoot]);
    Exit;
  end;

  LOutcome := RunQuiet(LGit, ['init', '--quiet'], ARoot);
  if LOutcome.ExitCode <> 0 then
    Warn('`git init` failed, so no repository was created')
  else
    TraceFmt('initialised a git repository in `%s`', [ARoot]);
end;

{ ---- the shared body ----------------------------------------------------- }

{ Writes AContent to APath unless something is already there, which `struo
  init` in a populated directory must not overwrite. }
procedure WriteNewFile(const APath, AContent: string; var ACreated: Boolean);
begin
  if PathIsFile(APath) then
  begin
    ACreated := False;
    TraceFmt('kept the existing `%s`', [APath]);
    Exit;
  end;
  WriteTextFile(APath, AContent);
  ACreated := True;
end;

procedure CreatePackage(const ARoot, AName: string; AShape: TPackageShape;
  AUseGit: Boolean);
var
  LWritten: Boolean;
  LUnit: string;
begin
  ValidatePackageName(AName);

  EnsureDir(ARoot);
  EnsureDir(JoinPath(ARoot, CSourceDirName));

  WriteNewFile(JoinPath(ARoot, CManifestName), ManifestTemplate(AName), LWritten);
  if not LWritten then
    raise EStruoError.CreateHintFmt('`%s` already has a %s',
      [ARoot, CManifestName],
      'edit it directly, or use `struo new` in an empty directory');

  LUnit := DefaultUnitName(AName);
  if AShape = psBinary then
    WriteNewFile(JoinPaths([ARoot, CSourceDirName, 'main.pas']),
      BinaryTemplate(AName), LWritten)
  else
  begin
    WriteNewFile(JoinPaths([ARoot, CSourceDirName, LUnit + '.pas']),
      LibraryTemplate(AName), LWritten);
    EnsureDir(JoinPath(ARoot, CTestsDirName));
    WriteNewFile(JoinPaths([ARoot, CTestsDirName, 'test_' + LUnit + '.pas']),
      LibraryTestTemplate(AName), LWritten);
  end;

  WriteNewFile(JoinPath(ARoot, '.gitignore'), GitignoreTemplate, LWritten);

  if AUseGit then
    InitialiseGit(ARoot);

  if AShape = psBinary then
    Status('Created', Format('binary (application) package `%s`', [AName]))
  else
    Status('Created', Format('library package `%s`', [AName]));
end;

{ Reads the shape from --bin and --lib, refusing both at once. }
function ShapeFromOptions(ACommandLine: TCommandLine): TPackageShape;
begin
  if ACommandLine.Flag('bin') and ACommandLine.Flag('lib') then
    raise EStruoUsageError.CreateHint(
      'a package is either a binary or a library, not both',
      'pass --bin or --lib, or neither for a binary');
  if ACommandLine.Flag('lib') then
    Result := psLibrary
  else
    { A binary is what someone typing `struo new` almost always wants. }
    Result := psBinary;
end;

{ Reads --vcs, which takes git or none. }
function UseGitFromOptions(ACommandLine: TCommandLine): Boolean;
var
  LChoice: string;
begin
  LChoice := LowerCase(ACommandLine.Value('vcs', 'git'));
  if LChoice = 'git' then
    Exit(True);
  if LChoice = 'none' then
    Exit(False);
  raise EStruoUsageError.CreateHintFmt('unknown --vcs value `%s`', [LChoice],
    'use git or none');
end;

procedure DeclareSharedOptions(ACommandLine: TCommandLine);
begin
  ACommandLine.AddFlag('bin', '', 'Create a binary package (the default)');
  ACommandLine.AddFlag('lib', '', 'Create a library package');
  ACommandLine.AddValue('name', '', 'name',
    'Package name, when it differs from the directory name');
  ACommandLine.AddValue('vcs', '', 'kind',
    'Version control to set up: git (the default) or none');
  ACommandLine.AddGlobalOptions;
end;

{ ---- struo new ----------------------------------------------------------- }

function RunNew(const AArgv: TStrArray): Integer;
var
  LCommandLine: TCommandLine;
  LPath, LRoot, LName: string;
begin
  LCommandLine := TCommandLine.Create('new');
  try
    DeclareSharedOptions(LCommandLine);
    LCommandLine.Parse(AArgv);

    if LCommandLine.Flag('help') then
    begin
      PrintCommandHelp('new', '<path> [options]',
        'Create a new Struo package in a new directory.', LCommandLine);
      Exit(CExitOk);
    end;
    ApplyGlobalOptions(LCommandLine);

    LPath := LCommandLine.RequirePositional(0, 'a path for the new package');
    LRoot := AbsolutePath(LPath, CurrentDir);

    { The directory name is the package name unless --name says otherwise,
      which is what makes `struo new ./weather` do the obvious thing. }
    LName := LCommandLine.Value('name', ExtractFileName(PathWithoutTrailingSep(LRoot)));

    if PathIsDir(LRoot) and (Length(ListFilesIn(LRoot, '*')) > 0) then
      raise EStruoError.CreateHintFmt('`%s` already exists and is not empty',
        [LRoot], 'use `struo init` inside it instead');

    CreatePackage(LRoot, LName, ShapeFromOptions(LCommandLine),
      UseGitFromOptions(LCommandLine));
    Result := CExitOk;
  finally
    LCommandLine.Free;
  end;
end;

{ ---- struo init ---------------------------------------------------------- }

function RunInit(const AArgv: TStrArray): Integer;
var
  LCommandLine: TCommandLine;
  LRoot, LName: string;
begin
  LCommandLine := TCommandLine.Create('init');
  try
    DeclareSharedOptions(LCommandLine);
    LCommandLine.Parse(AArgv);

    if LCommandLine.Flag('help') then
    begin
      PrintCommandHelp('init', '[path] [options]',
        'Turn an existing directory into a Struo package.', LCommandLine);
      Exit(CExitOk);
    end;
    ApplyGlobalOptions(LCommandLine);

    { With no path, the current directory. }
    LRoot := AbsolutePath(LCommandLine.Positional(0), CurrentDir);
    LName := LCommandLine.Value('name', ExtractFileName(PathWithoutTrailingSep(LRoot)));

    CreatePackage(LRoot, LName, ShapeFromOptions(LCommandLine),
      UseGitFromOptions(LCommandLine));
    Result := CExitOk;
  finally
    LCommandLine.Free;
  end;
end;

end.
