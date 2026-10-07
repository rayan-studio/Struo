{ Struo.Paths -- where Struo keeps things.

  Two separate trees, and the distinction matters:

  * STRUO_HOME, by default ~/.struo, is shared by every package on the
    machine. Fetched sources and the registry index live there, so cloning a
    dependency once serves every project that needs it.

  * <package>/target/ belongs to one package and is disposable. Everything in
    it can be rebuilt from the manifest and the lockfile, which is why
    `struo new` puts it in .gitignore. }
unit Struo.Paths;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Types, Struo.Util.Strings, Struo.Util.Fs;

{ ---- the shared home ----------------------------------------------------- }

{ STRUO_HOME when set, otherwise ~/.struo. Not created as a side effect of
  being asked for; the commands that write there call EnsureStruoHome. }
function StruoHome: string;

{ Creates STRUO_HOME and the subdirectories below it. }
procedure EnsureStruoHome;

{ Unpacked registry packages, one directory per name-version. }
function RegistryCacheDir: string;

{ Downloaded .tar.gz archives, kept so a re-fetch is free. }
function RegistryArchiveDir: string;

{ Clones of git dependencies, one directory per URL and revision. }
function GitCacheDir: string;

{ The registry index checkout. }
function RegistryIndexDir: string;

{ STRUO_HOME/config.toml: the machine-wide settings. }
function ConfigPath: string;

{ STRUO_HOME/credentials.toml: registry tokens. Kept apart from config.toml
  so the config can be shared or committed to a dotfiles repository without
  dragging a token along. }
function CredentialsPath: string;

{ ---- a package's own tree ------------------------------------------------ }

{ <root>/target }
function TargetDir(const APackageRoot: string): string;

{ <root>/target/<profile>: where finished binaries land. }
function ProfileDir(const APackageRoot: string; AProfile: TBuildProfile): string;

{ <root>/target/<profile>/units: compiled units for this package's own code. }
function UnitOutputDir(const APackageRoot: string; AProfile: TBuildProfile): string;

{ <root>/target/<profile>/deps/<name>-<version>: one directory per dependency,
  so two versions of the same package cannot overwrite each other's units. }
function DependencyUnitDir(const APackageRoot: string; AProfile: TBuildProfile;
  const AName, AVersion: string): string;

{ <root>/target/<profile>/tests }
function TestOutputDir(const APackageRoot: string; AProfile: TBuildProfile): string;

{ The executable name for ABaseName on this platform. }
function ExecutableName(const ABaseName: string): string;

{ ---- the bundled toolchain ----------------------------------------------- }

{ Struo's own executable, and the directory holding it. Used to find the
  toolchain shipped beside it. }
function StruoExecutablePath: string;
function StruoExecutableDir: string;

{ The directories that may hold the Free Pascal installation shipped with
  Struo, in the order worth trying. A release archive puts it at
  <struo>/toolchain, but a distribution may move the binary into bin/ or
  libexec/, so the parent is checked too.

  Each candidate is a Free Pascal *installation root*: the directory holding
  bin/ and units/, exactly as an unpacked FPC install looks. }
function BundledToolchainRoots: TStrArray;

{ ---- misc ---------------------------------------------------------------- }

function CurrentDir: string;

{ The user's home directory, across platforms. }
function UserHomeDir: string;

implementation

const
  { Subdirectory names under STRUO_HOME. Kept here so a future `struo cache`
    command has one place to look. }
  CRegistryDirName = 'registry';
  CArchiveDirName = 'archives';
  CGitDirName = 'git';
  CIndexDirName = 'index';

  { The Free Pascal installation Struo ships with, relative to the binary. }
  CToolchainDirName = 'toolchain';

function UserHomeDir: string;
begin
  {$IFDEF WINDOWS}
  Result := GetEnvironmentVariable('USERPROFILE');
  if Result = '' then
    { A domain profile can leave USERPROFILE unset while the two halves are
      present. }
    Result := JoinPath(GetEnvironmentVariable('HOMEDRIVE'),
                       GetEnvironmentVariable('HOMEPATH'));
  {$ELSE}
  Result := GetEnvironmentVariable('HOME');
  {$ENDIF}
  if Result = '' then
    { Nothing left to guess with. The working directory at least exists. }
    Result := GetCurrentDir;
  Result := PathWithoutTrailingSep(NormalizePath(Result));
end;

function StruoHome: string;
begin
  Result := GetEnvironmentVariable('STRUO_HOME');
  if Result <> '' then
    Exit(PathWithoutTrailingSep(NormalizePath(ExpandFileName(Result))));
  Result := JoinPath(UserHomeDir, '.struo');
end;

procedure EnsureStruoHome;
begin
  EnsureDir(StruoHome);
  EnsureDir(RegistryCacheDir);
  EnsureDir(RegistryArchiveDir);
  EnsureDir(GitCacheDir);
end;

function RegistryCacheDir: string;
begin
  Result := JoinPath(StruoHome, CRegistryDirName);
end;

function RegistryArchiveDir: string;
begin
  Result := JoinPath(StruoHome, CArchiveDirName);
end;

function GitCacheDir: string;
begin
  Result := JoinPath(StruoHome, CGitDirName);
end;

function RegistryIndexDir: string;
begin
  Result := JoinPath(StruoHome, CIndexDirName);
end;

function ConfigPath: string;
begin
  Result := JoinPath(StruoHome, 'config.toml');
end;

function CredentialsPath: string;
begin
  Result := JoinPath(StruoHome, 'credentials.toml');
end;

function TargetDir(const APackageRoot: string): string;
begin
  Result := JoinPath(APackageRoot, CTargetDirName);
end;

function ProfileDir(const APackageRoot: string; AProfile: TBuildProfile): string;
begin
  Result := JoinPath(TargetDir(APackageRoot), ProfileName(AProfile));
end;

function UnitOutputDir(const APackageRoot: string; AProfile: TBuildProfile): string;
begin
  Result := JoinPath(ProfileDir(APackageRoot, AProfile), 'units');
end;

function DependencyUnitDir(const APackageRoot: string; AProfile: TBuildProfile;
  const AName, AVersion: string): string;
var
  LLeaf: string;
begin
  { Two versions of one package must not share a unit directory, or the
    second compile would silently overwrite the first and the linker would
    pick whichever landed last. }
  if AVersion = '' then
    LLeaf := AName
  else
    LLeaf := AName + '-' + AVersion;
  Result := JoinPaths([ProfileDir(APackageRoot, AProfile), 'deps', LLeaf]);
end;

function TestOutputDir(const APackageRoot: string; AProfile: TBuildProfile): string;
begin
  Result := JoinPath(ProfileDir(APackageRoot, AProfile), CTestsDirName);
end;

function ExecutableName(const ABaseName: string): string;
begin
  {$IFDEF WINDOWS}
  if LowerCase(ExtractFileExt(ABaseName)) = '.exe' then
    Result := ABaseName
  else
    Result := ABaseName + '.exe';
  {$ELSE}
  Result := ABaseName;
  {$ENDIF}
end;

function CurrentDir: string;
begin
  Result := PathWithoutTrailingSep(NormalizePath(GetCurrentDir));
end;

{ ---- the bundled toolchain ----------------------------------------------- }

function StruoExecutablePath: string;
begin
  { ParamStr(0) is the full path on Windows and usually is on Unix; expanding
    it covers the case where the shell handed over a relative argv[0]. }
  Result := NormalizePath(ExpandFileName(ParamStr(0)));
end;

function StruoExecutableDir: string;
begin
  Result := PathWithoutTrailingSep(ExtractFilePath(StruoExecutablePath));
end;

function BundledToolchainRoots: TStrArray;
var
  LHere, LParent: string;
begin
  LHere := StruoExecutableDir;
  LParent := PathWithoutTrailingSep(ExtractFilePath(LHere));

  Result := StrArrayOf([
    { The release archive's own layout. }
    JoinPath(LHere, CToolchainDirName),
    { struo moved into bin/ beside the toolchain. }
    JoinPath(LParent, CToolchainDirName),
    { A Unix-style install: /usr/bin/struo with /usr/lib/struo/toolchain. }
    JoinPaths([LParent, 'lib', 'struo', CToolchainDirName]),
    JoinPaths([LParent, 'libexec', 'struo', CToolchainDirName])
  ]);
end;

end.
