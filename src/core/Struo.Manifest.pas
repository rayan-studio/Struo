{ Struo.Manifest -- the Struo.toml model, loaded and validated.

  This unit interprets the TOML tree; it does not parse TOML and it does not
  touch the source tree. Target inference from the directory layout is
  Struo.Targets' job, so that loading a manifest stays a pure function of the
  file's bytes and can be tested without a package on disk.

  Validation is strict and reports a line. A manifest is read at the start of
  every command, so a mistake in it should be named once, precisely, rather
  than surfacing later as a baffling compiler error. }
unit Struo.Manifest;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings, Struo.Types, Struo.SemVer, Struo.Toml.Value;

type
  { Where a dependency's source comes from. }
  TDependencyKind = (dkRegistry, dkPath, dkGit);

  { Which of branch, tag or rev pins a git dependency. gpDefault means the
    repository's default branch, which is reproducible only via the lockfile. }
  TGitPin = (gpDefault, gpBranch, gpTag, gpRev);

  TDependency = record
    Name: string;
    Kind: TDependencyKind;

    { Registry dependencies only. }
    Req: TVersionReq;

    { Path dependencies: as written in the manifest, relative to the package
      root. Resolved against the root when it is needed, not at load time, so
      a manifest can be read without its directory being present. }
    Path: string;

    { Git dependencies. }
    GitUrl: string;
    PinKind: TGitPin;
    PinValue: string;

    Optional: Boolean;
    UseDefaultFeatures: Boolean;
    Features: TStrArray;

    { True for an entry under [dev-dependencies]: built for tests and
      examples, never for the library or the binaries. }
    IsDev: Boolean;

    { The manifest line it came from, for error messages. }
    Line: Integer;
  end;

  TDependencyArray = array of TDependency;

  TTargetKind = (tgLib, tgBin, tgTest, tgExample);

  TTarget = record
    Kind: TTargetKind;
    { The unit or executable name. }
    Name: string;
    { The source file, relative to the package root. }
    SourcePath: string;
    { False when the target was inferred from the layout rather than declared
      in the manifest. Only used to make `--verbose` output clearer. }
    Declared: Boolean;
  end;

  TTargetArray = array of TTarget;

  TProfileSettings = record
    { Mapped to -O0 .. -O4. }
    Optimize: Integer;
    { -g -gl: line numbers in a backtrace. }
    Debug: Boolean;
    { -Cr -Co -Ci: range, overflow and IO checking. }
    Checks: Boolean;
    { -Xs }
    Strip: Boolean;
    { -XX -CX: drop unused code from the binary. }
    SmartLink: Boolean;
    { none | default | all | error }
    Warnings: string;
  end;

  TBuildSettings = record
    { objfpc | delphi | fpc | macpas }
    Mode: string;
    { A target triple such as x86_64-win64, or empty for the host. }
    Target: string;
    IncludePaths: TStrArray;
    UnitPaths: TStrArray;
    LibraryPaths: TStrArray;
    Defines: TStrArray;
    { Passed to the compiler verbatim. An escape hatch, not a first resort. }
    Flags: TStrArray;
  end;

  TManifest = class
  private
    procedure FailAt(ALine: Integer; const AMessage, AHint: string);
    procedure FailAtFmt(ALine: Integer; const AFormat: string;
      const AArgs: array of const; const AHint: string);

    procedure LoadPackage(ADocument: TTomlValue);
    procedure LoadDependencyTable(ADocument: TTomlValue; const AKey: string;
      AIsDev: Boolean);
    procedure LoadTargets(ADocument: TTomlValue);
    procedure LoadTargetList(ADocument: TTomlValue; const AKey: string;
      AKind: TTargetKind);
    procedure LoadBuild(ADocument: TTomlValue);
    procedure LoadProfiles(ADocument: TTomlValue);
    procedure ReadProfile(ADocument: TTomlValue; const AName: string;
      var ASettings: TProfileSettings);
    function ReadDependency(const AName: string; AValue: TTomlValue;
      AIsDev: Boolean): TDependency;
  public
    { ---- [package] ---- }
    Name: string;
    Version: TSemVer;
    Edition: string;
    Description: string;
    License: string;
    Repository: string;
    Homepage: string;
    Readme: string;
    Authors: TStrArray;
    Keywords: TStrArray;

    { ---- the rest ---- }
    Dependencies: TDependencyArray;
    Targets: TTargetArray;
    Build: TBuildSettings;
    DebugProfile: TProfileSettings;
    ReleaseProfile: TProfileSettings;

    { Where this manifest came from. Root is the directory holding it, and is
      what every relative path in the manifest resolves against. }
    ManifestPath: string;
    Root: string;

    constructor Create;

    { Reads, parses and validates APath. Raises EStruoError, whose message
      names the file and line, on anything wrong. }
    class function Load(const APath: string): TManifest;

    { Interprets an already-parsed document. ADocument stays the caller's to
      free. APath is used for error messages and to set Root. }
    class function FromToml(ADocument: TTomlValue; const APath: string): TManifest;

    { 'weather v0.3.1', as the build output names a package. }
    function Describe: string;

    function FindDependency(const AName: string; out ADependency: TDependency): Boolean;
    function HasDependency(const AName: string): Boolean;

    { In memory only. Writing a dependency back to the file is
      Struo.Manifest.Editor's job, so that comments and formatting survive. }
    procedure AddDependency(const ADependency: TDependency);

    procedure AddTarget(const ATarget: TTarget);
    function TargetsOfKind(AKind: TTargetKind): TTargetArray;
    function FindTarget(AKind: TTargetKind; const AName: string;
      out ATarget: TTarget): Boolean;

    { The library target, if this package has one. }
    function HasLibrary(out ATarget: TTarget): Boolean;

    { The binary to run when `struo run` is given no --bin. True only when
      the choice is unambiguous. ACount reports how many binaries exist, so
      the caller can say whether the problem is none or too many. }
    function DefaultBinary(out ATarget: TTarget; out ACount: Integer): Boolean;

    function Profile(AProfile: TBuildProfile): TProfileSettings;
  end;

{ Package names are registry identifiers as well as defaults for unit names:
  a letter, then letters, digits, '-' or '_'. }
function IsValidPackageName(const AName: string): Boolean;

{ Raises EStruoError explaining precisely which rule AName broke. }
procedure ValidatePackageName(const AName: string);

{ The Pascal unit name a package name implies. Package names may contain a
  dash, as registry names conventionally do, but a Pascal identifier may not,
  so `my-lib` becomes unit `my_lib`. Struo looks for both spellings when
  inferring the library source file. }
function DefaultUnitName(const APackageName: string): string;

{ Default settings, used when the manifest says nothing. }
function DefaultDebugProfile: TProfileSettings;
function DefaultReleaseProfile: TProfileSettings;

implementation

uses
  Struo.Util.Fs, Struo.Toml.Parser;

const
  CValidModes: array[0 .. 3] of string = ('objfpc', 'delphi', 'fpc', 'macpas');
  CValidWarnings: array[0 .. 3] of string = ('none', 'default', 'all', 'error');
  CMaxKeywords = 5;

{ ---- names --------------------------------------------------------------- }

function IsValidPackageName(const AName: string): Boolean;
var
  I: Integer;
begin
  if AName = '' then
    Exit(False);
  if not (AName[1] in ['A' .. 'Z', 'a' .. 'z']) then
    Exit(False);
  for I := 2 to Length(AName) do
    if not (AName[I] in ['A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_']) then
      Exit(False);
  Result := True;
end;

procedure ValidatePackageName(const AName: string);
begin
  if AName = '' then
    raise EStruoError.CreateHint('the package name is empty',
      'set `name` under [package] in ' + CManifestName);
  if not (AName[1] in ['A' .. 'Z', 'a' .. 'z']) then
    raise EStruoError.CreateHintFmt('`%s` is not a valid package name', [AName],
      'a package name must start with a letter');
  if not IsValidPackageName(AName) then
    raise EStruoError.CreateHintFmt('`%s` is not a valid package name', [AName],
      'use only letters, digits, `-` and `_`');
end;

function DefaultUnitName(const APackageName: string): string;
begin
  Result := StringReplace(APackageName, '-', '_', [rfReplaceAll]);
end;

{ ---- profile defaults ---------------------------------------------------- }

function DefaultDebugProfile: TProfileSettings;
begin
  { A debug build should fail loudly and be navigable in a debugger, so the
    checks are on and optimisation is off: optimised code moves lines around
    and makes a backtrace misleading. }
  Result.Optimize := 0;
  Result.Debug := True;
  Result.Checks := True;
  Result.Strip := False;
  Result.SmartLink := False;
  Result.Warnings := 'default';
end;

function DefaultReleaseProfile: TProfileSettings;
begin
  Result.Optimize := 3;
  Result.Debug := False;
  Result.Checks := False;
  Result.Strip := True;
  Result.SmartLink := True;
  Result.Warnings := 'default';
end;

{ ---- construction -------------------------------------------------------- }

constructor TManifest.Create;
begin
  inherited Create;
  Edition := CCurrentEdition;
  Build.Mode := 'objfpc';
  DebugProfile := DefaultDebugProfile;
  ReleaseProfile := DefaultReleaseProfile;
end;

class function TManifest.Load(const APath: string): TManifest;
var
  LDocument: TTomlValue;
begin
  if not PathIsFile(APath) then
    raise EStruoError.CreateHintFmt('no manifest at `%s`', [APath],
      'run `struo init` to create one');

  try
    LDocument := ParseTomlFile(APath);
  except
    on E: ETomlError do
      { Re-shaped into a Struo error so the CLI has one error type to render,
        keeping the line and column the parser worked out. }
      raise EStruoError.CreateHint(
        Format('%s:%d:%d: %s', [ExtractFileName(APath), E.Line, E.Column, E.Message]),
        'see docs/manifest.md for the manifest format');
    on E: EFsError do
      raise EStruoError.CreateHint(E.Message, '');
  end;

  try
    Result := FromToml(LDocument, APath);
  finally
    LDocument.Free;
  end;
end;

class function TManifest.FromToml(ADocument: TTomlValue; const APath: string): TManifest;
begin
  Result := TManifest.Create;
  try
    Result.ManifestPath := NormalizePath(ExpandFileName(APath));
    Result.Root := PathWithoutTrailingSep(ExtractFilePath(Result.ManifestPath));

    if (ADocument = nil) or not ADocument.IsTable then
      Result.FailAt(0, 'the manifest is empty', 'see docs/manifest.md');

    Result.LoadPackage(ADocument);
    Result.LoadDependencyTable(ADocument, 'dependencies', False);
    Result.LoadDependencyTable(ADocument, 'dev-dependencies', True);
    Result.LoadTargets(ADocument);
    Result.LoadBuild(ADocument);
    Result.LoadProfiles(ADocument);
  except
    Result.Free;
    raise;
  end;
end;

{ ---- error helpers ------------------------------------------------------- }

procedure TManifest.FailAt(ALine: Integer; const AMessage, AHint: string);
var
  LWhere: string;
begin
  if ManifestPath = '' then
    LWhere := CManifestName
  else
    LWhere := ExtractFileName(ManifestPath);
  if ALine > 0 then
    LWhere := Format('%s:%d', [LWhere, ALine]);
  raise EStruoError.CreateHint(LWhere + ': ' + AMessage, AHint);
end;

procedure TManifest.FailAtFmt(ALine: Integer; const AFormat: string;
  const AArgs: array of const; const AHint: string);
begin
  FailAt(ALine, Format(AFormat, AArgs), AHint);
end;

{ ---- [package] ----------------------------------------------------------- }

procedure TManifest.LoadPackage(ADocument: TTomlValue);
var
  LPackage: TTomlValue;
  LVersionText: string;
begin
  LPackage := ADocument.Find('package');
  if LPackage = nil then
    FailAt(0, 'the manifest has no [package] section',
      'every package needs [package] with a `name` and a `version`');
  if not LPackage.IsTable then
    FailAtFmt(LPackage.Line, '[package] must be a table, found %s',
      [LPackage.KindName], '');

  if not LPackage.Has('name') then
    FailAt(LPackage.Line, '[package] has no `name`',
      'add `name = "my-package"` under [package]');
  Name := LPackage.Find('name').AsString;
  try
    ValidatePackageName(Name);
  except
    on E: EStruoError do
      FailAt(LPackage.Find('name').Line, E.Message, E.Hint);
  end;

  if not LPackage.Has('version') then
    FailAt(LPackage.Line, '[package] has no `version`',
      'add `version = "0.1.0"` under [package]');
  LVersionText := LPackage.Find('version').AsString;
  if not TryParseSemVer(LVersionText, Version) then
    FailAtFmt(LPackage.Find('version').Line,
      '`%s` is not a valid version', [LVersionText],
      'versions look like 0.1.0 or 1.2.3-beta.1');

  Edition := LPackage.StringOr('edition', CCurrentEdition);
  if Edition <> CCurrentEdition then
    FailAtFmt(LPackage.Find('edition').Line,
      'unknown edition `%s`', [Edition],
      'this version of Struo understands edition "' + CCurrentEdition + '"');

  Description := LPackage.StringOr('description', '');
  License := LPackage.StringOr('license', '');
  Repository := LPackage.StringOr('repository', '');
  Homepage := LPackage.StringOr('homepage', '');
  Readme := LPackage.StringOr('readme', '');
  Authors := LPackage.StringsOr('authors', nil);
  Keywords := LPackage.StringsOr('keywords', nil);

  if Length(Keywords) > CMaxKeywords then
    FailAtFmt(LPackage.Find('keywords').Line,
      '[package] has %d keywords, the limit is %d',
      [Length(Keywords), CMaxKeywords], '');
end;

{ ---- dependencies -------------------------------------------------------- }

function TManifest.ReadDependency(const AName: string; AValue: TTomlValue;
  AIsDev: Boolean): TDependency;
var
  LPins: Integer;
  LSources: Integer;
begin
  Result := Default(TDependency);
  Result.Name := AName;
  Result.IsDev := AIsDev;
  Result.UseDefaultFeatures := True;
  Result.Line := AValue.Line;
  Result.Req := AnyVersionReq;

  if not IsValidPackageName(AName) then
    FailAtFmt(AValue.Line, '`%s` is not a valid dependency name', [AName],
      'use only letters, digits, `-` and `_`, starting with a letter');

  { The shorthand: a bare string is a version requirement. }
  if AValue.Kind = tkString then
  begin
    Result.Kind := dkRegistry;
    if not TryParseVersionReq(AValue.AsString, Result.Req) then
      FailAtFmt(AValue.Line, '`%s` is not a valid version requirement for `%s`',
        [AValue.AsString, AName],
        'try "1.2.3" for compatible releases or ">=1.2, <1.5" for a range');
    Exit;
  end;

  if not AValue.IsTable then
    FailAtFmt(AValue.Line,
      'dependency `%s` must be a version string or a table, found %s',
      [AName, AValue.KindName],
      'write `' + AName + ' = "1.0.0"` or `' + AName + ' = { path = "../' + AName + '" }`');

  { Exactly one source. Two would leave Struo guessing which the author
    meant, and guessing wrong fetches the wrong code. }
  LSources := 0;
  if AValue.Has('version') then
    Inc(LSources);
  if AValue.Has('path') then
    Inc(LSources);
  if AValue.Has('git') then
    Inc(LSources);

  if LSources = 0 then
    FailAtFmt(AValue.Line, 'dependency `%s` has no source', [AName],
      'give it a `version`, a `path` or a `git` url');
  if LSources > 1 then
    FailAtFmt(AValue.Line,
      'dependency `%s` has more than one of `version`, `path` and `git`', [AName],
      'pick the one source Struo should fetch it from');

  if AValue.Has('path') then
  begin
    Result.Kind := dkPath;
    Result.Path := AValue.Find('path').AsString;
    if IsBlankStr(Result.Path) then
      FailAtFmt(AValue.Line, 'dependency `%s` has an empty `path`', [AName], '');
  end
  else if AValue.Has('git') then
  begin
    Result.Kind := dkGit;
    Result.GitUrl := AValue.Find('git').AsString;
    if IsBlankStr(Result.GitUrl) then
      FailAtFmt(AValue.Line, 'dependency `%s` has an empty `git` url', [AName], '');

    LPins := 0;
    if AValue.Has('branch') then
    begin
      Inc(LPins);
      Result.PinKind := gpBranch;
      Result.PinValue := AValue.Find('branch').AsString;
    end;
    if AValue.Has('tag') then
    begin
      Inc(LPins);
      Result.PinKind := gpTag;
      Result.PinValue := AValue.Find('tag').AsString;
    end;
    if AValue.Has('rev') then
    begin
      Inc(LPins);
      Result.PinKind := gpRev;
      Result.PinValue := AValue.Find('rev').AsString;
    end;
    if LPins > 1 then
      FailAtFmt(AValue.Line,
        'dependency `%s` has more than one of `branch`, `tag` and `rev`', [AName],
        'a git dependency can be pinned one way only');
  end
  else
  begin
    Result.Kind := dkRegistry;
    if not TryParseVersionReq(AValue.Find('version').AsString, Result.Req) then
      FailAtFmt(AValue.Find('version').Line,
        '`%s` is not a valid version requirement for `%s`',
        [AValue.Find('version').AsString, AName], '');
  end;

  Result.Optional := AValue.BooleanOr('optional', False);
  Result.UseDefaultFeatures := AValue.BooleanOr('default-features', True);
  Result.Features := AValue.StringsOr('features', nil);
end;

procedure TManifest.LoadDependencyTable(ADocument: TTomlValue;
  const AKey: string; AIsDev: Boolean);
var
  LTable: TTomlValue;
  LDependency: TDependency;
  I: Integer;
begin
  LTable := ADocument.Find(AKey);
  if LTable = nil then
    Exit;
  if not LTable.IsTable then
    FailAtFmt(LTable.Line, '[%s] must be a table, found %s',
      [AKey, LTable.KindName], '');

  for I := 0 to LTable.Count - 1 do
  begin
    LDependency := ReadDependency(LTable.KeyAt(I), LTable.ItemAt(I), AIsDev);

    { The same name in both [dependencies] and [dev-dependencies] would make
      the build order depend on which table was read first. }
    if HasDependency(LDependency.Name) then
      FailAtFmt(LDependency.Line, 'dependency `%s` is declared twice',
        [LDependency.Name], '');

    AddDependency(LDependency);
  end;
end;

{ ---- targets ------------------------------------------------------------- }

{ Reads one target table into ATarget, leaving the name empty when the table
  does not give one. }
procedure ReadTargetTable(ATable: TTomlValue; AKind: TTargetKind;
  out ATarget: TTarget);
begin
  ATarget := Default(TTarget);
  ATarget.Kind := AKind;
  ATarget.Declared := True;
  ATarget.Name := ATable.StringOr('name', '');
  ATarget.SourcePath := ATable.StringOr('path', '');
end;

procedure TManifest.LoadTargetList(ADocument: TTomlValue; const AKey: string;
  AKind: TTargetKind);
var
  LValue, LEntry: TTomlValue;
  LTarget: TTarget;
  I: Integer;
begin
  LValue := ADocument.Find(AKey);
  if LValue = nil then
    Exit;

  { [[bin]] is the documented form, but accept a single [bin] table too: it
    is an easy thing to write by mistake and the intent is unmistakable. }
  if LValue.IsTable then
  begin
    ReadTargetTable(LValue, AKind, LTarget);
    if LTarget.Name = '' then
      LTarget.Name := Name;
    if LTarget.SourcePath = '' then
      FailAtFmt(LValue.Line, '[%s] has no `path`', [AKey],
        'add `path = "src/main.pas"`');
    AddTarget(LTarget);
    Exit;
  end;

  if not LValue.IsArray then
    FailAtFmt(LValue.Line, '[[%s]] must be a table or an array of tables, found %s',
      [AKey, LValue.KindName], '');

  for I := 0 to LValue.Count - 1 do
  begin
    LEntry := LValue.ItemAt(I);
    if not LEntry.IsTable then
      FailAtFmt(LEntry.Line, 'every [[%s]] entry must be a table, found %s',
        [AKey, LEntry.KindName], '');

    ReadTargetTable(LEntry, AKind, LTarget);
    if LTarget.Name = '' then
    begin
      { One binary may take the package's name by default; several cannot,
        or two targets would collide on one output file. }
      if (AKind = tgBin) and (LValue.Count = 1) then
        LTarget.Name := Name
      else
        FailAtFmt(LEntry.Line, 'a [[%s]] entry has no `name`', [AKey],
          'name each target when there is more than one');
    end;
    if LTarget.SourcePath = '' then
      FailAtFmt(LEntry.Line, '[[%s]] `%s` has no `path`', [AKey, LTarget.Name],
        'add `path = "src/bin/' + LTarget.Name + '.pas"`');
    AddTarget(LTarget);
  end;
end;

procedure TManifest.LoadTargets(ADocument: TTomlValue);
var
  LLib: TTomlValue;
  LTarget: TTarget;
begin
  LLib := ADocument.Find('lib');
  if LLib <> nil then
  begin
    if not LLib.IsTable then
      FailAtFmt(LLib.Line, '[lib] must be a table, found %s', [LLib.KindName],
        'a package can have at most one library');
    ReadTargetTable(LLib, tgLib, LTarget);
    if LTarget.Name = '' then
      LTarget.Name := Name;
    if LTarget.SourcePath = '' then
      FailAtFmt(LLib.Line, '[lib] has no `path`', [],
        'add `path = "src/' + Name + '.pas"`');
    AddTarget(LTarget);
  end;

  LoadTargetList(ADocument, 'bin', tgBin);
  LoadTargetList(ADocument, 'test', tgTest);
  LoadTargetList(ADocument, 'example', tgExample);
end;

{ ---- [build] ------------------------------------------------------------- }

procedure TManifest.LoadBuild(ADocument: TTomlValue);
var
  LBuild: TTomlValue;
  I: Integer;
  LFound: Boolean;
begin
  LBuild := ADocument.Find('build');
  if LBuild = nil then
    Exit;
  if not LBuild.IsTable then
    FailAtFmt(LBuild.Line, '[build] must be a table, found %s',
      [LBuild.KindName], '');

  Build.Mode := LowerCase(LBuild.StringOr('mode', 'objfpc'));
  LFound := False;
  for I := Low(CValidModes) to High(CValidModes) do
    if Build.Mode = CValidModes[I] then
    begin
      LFound := True;
      Break;
    end;
  if not LFound then
    FailAtFmt(LBuild.Find('mode').Line, 'unknown compiler mode `%s`',
      [Build.Mode],
      'use one of: ' + JoinStr(CValidModes, ', '));

  Build.Target := LBuild.StringOr('target', '');
  Build.IncludePaths := LBuild.StringsOr('include', nil);
  Build.UnitPaths := LBuild.StringsOr('units', nil);
  Build.LibraryPaths := LBuild.StringsOr('libraries', nil);
  Build.Defines := LBuild.StringsOr('defines', nil);
  Build.Flags := LBuild.StringsOr('flags', nil);
end;

{ ---- [profile.*] --------------------------------------------------------- }

procedure TManifest.ReadProfile(ADocument: TTomlValue; const AName: string;
  var ASettings: TProfileSettings);
var
  LProfile: TTomlValue;
  I: Integer;
  LFound: Boolean;
begin
  LProfile := ADocument.Path('profile.' + AName);
  if LProfile = nil then
    Exit;
  if not LProfile.IsTable then
    FailAtFmt(LProfile.Line, '[profile.%s] must be a table, found %s',
      [AName, LProfile.KindName], '');

  ASettings.Optimize := LProfile.IntegerOr('optimize', ASettings.Optimize);
  if (ASettings.Optimize < 0) or (ASettings.Optimize > 4) then
    FailAtFmt(LProfile.Find('optimize').Line,
      '[profile.%s] optimize must be between 0 and 4, found %d',
      [AName, ASettings.Optimize], '');

  ASettings.Debug := LProfile.BooleanOr('debug', ASettings.Debug);
  ASettings.Checks := LProfile.BooleanOr('checks', ASettings.Checks);
  ASettings.Strip := LProfile.BooleanOr('strip', ASettings.Strip);
  ASettings.SmartLink := LProfile.BooleanOr('smart-link', ASettings.SmartLink);
  ASettings.Warnings := LowerCase(LProfile.StringOr('warnings', ASettings.Warnings));

  LFound := False;
  for I := Low(CValidWarnings) to High(CValidWarnings) do
    if ASettings.Warnings = CValidWarnings[I] then
    begin
      LFound := True;
      Break;
    end;
  if not LFound then
    FailAtFmt(LProfile.Find('warnings').Line,
      '[profile.%s] has an unknown `warnings` value `%s`',
      [AName, ASettings.Warnings],
      'use one of: ' + JoinStr(CValidWarnings, ', '));
end;

procedure TManifest.LoadProfiles(ADocument: TTomlValue);
begin
  ReadProfile(ADocument, 'debug', DebugProfile);
  ReadProfile(ADocument, 'release', ReleaseProfile);
end;

{ ---- queries ------------------------------------------------------------- }

function TManifest.Describe: string;
begin
  Result := Name + ' v' + SemVerToStr(Version);
end;

function TManifest.FindDependency(const AName: string;
  out ADependency: TDependency): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Dependencies) do
    { Dependency names are compared case-insensitively: a registry that let
      `fjson` and `FJson` coexist would be a phishing surface. }
    if SameText(Dependencies[I].Name, AName) then
    begin
      ADependency := Dependencies[I];
      Exit(True);
    end;
  ADependency := Default(TDependency);
  Result := False;
end;

function TManifest.HasDependency(const AName: string): Boolean;
var
  LDependency: TDependency;
begin
  Result := FindDependency(AName, LDependency);
end;

procedure TManifest.AddDependency(const ADependency: TDependency);
begin
  SetLength(Dependencies, Length(Dependencies) + 1);
  Dependencies[High(Dependencies)] := ADependency;
end;

procedure TManifest.AddTarget(const ATarget: TTarget);
begin
  SetLength(Targets, Length(Targets) + 1);
  Targets[High(Targets)] := ATarget;
end;

function TManifest.TargetsOfKind(AKind: TTargetKind): TTargetArray;
var
  I, LCount: Integer;
begin
  Result := nil;
  LCount := 0;
  for I := 0 to High(Targets) do
    if Targets[I].Kind = AKind then
      Inc(LCount);
  SetLength(Result, LCount);
  LCount := 0;
  for I := 0 to High(Targets) do
    if Targets[I].Kind = AKind then
    begin
      Result[LCount] := Targets[I];
      Inc(LCount);
    end;
end;

function TManifest.FindTarget(AKind: TTargetKind; const AName: string;
  out ATarget: TTarget): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Targets) do
    if (Targets[I].Kind = AKind) and SameText(Targets[I].Name, AName) then
    begin
      ATarget := Targets[I];
      Exit(True);
    end;
  ATarget := Default(TTarget);
  Result := False;
end;

function TManifest.HasLibrary(out ATarget: TTarget): Boolean;
var
  LLibraries: TTargetArray;
begin
  LLibraries := TargetsOfKind(tgLib);
  Result := Length(LLibraries) > 0;
  if Result then
    ATarget := LLibraries[0]
  else
    ATarget := Default(TTarget);
end;

function TManifest.DefaultBinary(out ATarget: TTarget; out ACount: Integer): Boolean;
var
  LBinaries: TTargetArray;
  I: Integer;
begin
  LBinaries := TargetsOfKind(tgBin);
  ACount := Length(LBinaries);
  ATarget := Default(TTarget);

  if ACount = 0 then
    Exit(False);
  if ACount = 1 then
  begin
    ATarget := LBinaries[0];
    Exit(True);
  end;

  { Several binaries: one named after the package is the obvious default,
    exactly as Cargo treats it. Otherwise the caller must choose. }
  for I := 0 to High(LBinaries) do
    if SameText(LBinaries[I].Name, Name) then
    begin
      ATarget := LBinaries[I];
      Exit(True);
    end;
  Result := False;
end;

function TManifest.Profile(AProfile: TBuildProfile): TProfileSettings;
begin
  case AProfile of
    bpRelease: Result := ReleaseProfile;
  else
    Result := DebugProfile;
  end;
end;

end.
