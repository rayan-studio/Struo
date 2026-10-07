{ Exercises manifest loading, validation and target inference.

  Most cases run the TOML through TManifest.FromToml with no package on disk,
  which is why loading is a pure function of the file's bytes. The inference
  cases build a throwaway package tree under the system temp directory and
  delete it again. }
program test_manifest;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Struo.Util.Strings,
  Struo.Util.Fs,
  Struo.Types,
  Struo.SemVer,
  Struo.Toml.Value,
  Struo.Toml.Parser,
  Struo.Manifest,
  Struo.Targets,
  Struo.Test;

const
  CMinimal =
    '[package]' + LineEnding +
    'name = "weather"' + LineEnding +
    'version = "0.3.1"';

{ Loads ASource as a manifest rooted at ARoot, or nil when it was refused. }
function LoadSource(const ASource, ARoot, AWhat: string): TManifest;
var
  LDocument: TTomlValue;
begin
  Result := nil;
  LDocument := nil;
  try
    LDocument := ParseToml(ASource);
    Result := TManifest.FromToml(LDocument, JoinPath(ARoot, CManifestName));
  except
    on E: EStruoError do
      Failed(AWhat, 'unexpectedly refused: ' + E.Message);
    on E: Exception do
      Failed(AWhat, 'unexpected ' + E.ClassName + ': ' + E.Message);
  end;
  LDocument.Free;
end;

{ Asserts that ASource is refused, and that the error carries a line number so
  the user is told where to look. }
procedure CheckRefuses(const ASource, AWhat: string);
var
  LDocument: TTomlValue;
  LManifest: TManifest;
begin
  LDocument := nil;
  LManifest := nil;
  try
    try
      LDocument := ParseToml(ASource);
      LManifest := TManifest.FromToml(LDocument, 'C:\pkg\' + CManifestName);
      Failed(AWhat, 'expected a refusal, but it loaded');
    except
      on E: EStruoError do
        Check(Pos(CManifestName, E.Message) > 0,
          AWhat + ' (' + E.Message + ')');
      on E: ETomlError do
        Check(True, AWhat + ' (rejected by the parser)');
    end;
  finally
    LManifest.Free;
    LDocument.Free;
  end;
end;

procedure TestMinimal;
var
  LManifest: TManifest;
begin
  LManifest := LoadSource(CMinimal, 'C:\dev\weather', 'a minimal manifest');
  if LManifest = nil then
    Exit;
  try
    CheckEqStr(LManifest.Name, 'weather', 'the package name is read');
    CheckEqStr(SemVerToStr(LManifest.Version), '0.3.1', 'the version is read');
    CheckEqStr(LManifest.Edition, CCurrentEdition, 'the edition defaults');
    CheckEqStr(LManifest.Describe, 'weather v0.3.1', 'Describe names the package');
    CheckEqStr(LManifest.Build.Mode, 'objfpc', 'the compiler mode defaults');
    CheckEqInt(Length(LManifest.Dependencies), 0, 'there are no dependencies');
    CheckEqInt(Length(LManifest.Targets), 0, 'nothing is declared');

    { Defaults, not silence: a debug build must be debuggable and a release
      build must be fast, without the author writing a profile. }
    CheckEqInt(LManifest.Profile(bpDebug).Optimize, 0, 'debug does not optimise');
    CheckEqBool(LManifest.Profile(bpDebug).Debug, True, 'debug has debug info');
    CheckEqBool(LManifest.Profile(bpDebug).Checks, True, 'debug checks ranges');
    CheckEqInt(LManifest.Profile(bpRelease).Optimize, 3, 'release optimises');
    CheckEqBool(LManifest.Profile(bpRelease).Strip, True, 'release strips');
  finally
    LManifest.Free;
  end;
end;

procedure TestFullPackageSection;
var
  LManifest: TManifest;
begin
  LManifest := LoadSource(
    '[package]' + LineEnding +
    'name = "weather"' + LineEnding +
    'version = "1.0.0-beta.2"' + LineEnding +
    'edition = "2026"' + LineEnding +
    'authors = ["Ada <ada@example.com>", "Bob"]' + LineEnding +
    'description = "Forecasts in the terminal."' + LineEnding +
    'license = "MIT"' + LineEnding +
    'repository = "https://github.com/me/weather"' + LineEnding +
    'keywords = ["cli", "weather"]',
    'C:\dev\weather', 'a full [package]');
  if LManifest = nil then
    Exit;
  try
    CheckEqStr(SemVerToStr(LManifest.Version), '1.0.0-beta.2',
      'a prerelease version is read');
    CheckEqInt(Length(LManifest.Authors), 2, 'the authors are read');
    CheckEqStr(LManifest.License, 'MIT', 'the license is read');
    CheckEqInt(Length(LManifest.Keywords), 2, 'the keywords are read');
  finally
    LManifest.Free;
  end;
end;

procedure TestDependencies;
var
  LManifest: TManifest;
  LDependency: TDependency;
begin
  LManifest := LoadSource(
    CMinimal + LineEnding +
    '[dependencies]' + LineEnding +
    'fjson = "1.2.0"' + LineEnding +
    'fhttp = { version = "^0.4", optional = true, features = ["tls"] }' + LineEnding +
    'mylib = { path = "../mylib" }' + LineEnding +
    'fcolor = { git = "https://github.com/x/fcolor", tag = "v1.0.0" }' + LineEnding +
    LineEnding +
    '[dev-dependencies]' + LineEnding +
    'fptest = "0.3"',
    'C:\dev\weather', 'the dependency kinds');
  if LManifest = nil then
    Exit;
  try
    CheckEqInt(Length(LManifest.Dependencies), 5, 'all five are read');

    Check(LManifest.FindDependency('fjson', LDependency), 'fjson is found');
    Check(LDependency.Kind = dkRegistry, 'a bare string is a registry dependency');
    CheckEqStr(VersionReqToStr(LDependency.Req), '1.2.0',
      'the requirement is kept as written');
    CheckEqBool(LDependency.IsDev, False, 'it is not a dev dependency');
    CheckEqBool(LDependency.UseDefaultFeatures, True, 'default features are on');

    Check(LManifest.FindDependency('fhttp', LDependency), 'fhttp is found');
    CheckEqBool(LDependency.Optional, True, 'optional is read');
    CheckEqInt(Length(LDependency.Features), 1, 'the features are read');

    Check(LManifest.FindDependency('mylib', LDependency), 'mylib is found');
    Check(LDependency.Kind = dkPath, 'a path dependency is recognised');
    CheckEqStr(LDependency.Path, '../mylib', 'the path is kept as written');

    Check(LManifest.FindDependency('fcolor', LDependency), 'fcolor is found');
    Check(LDependency.Kind = dkGit, 'a git dependency is recognised');
    Check(LDependency.PinKind = gpTag, 'the tag pin is recognised');
    CheckEqStr(LDependency.PinValue, 'v1.0.0', 'the tag is read');

    Check(LManifest.FindDependency('fptest', LDependency), 'fptest is found');
    CheckEqBool(LDependency.IsDev, True, 'a dev dependency is marked');

    { Names are matched case-insensitively, so a registry cannot host both
      `fjson` and `FJson` as a way to trick someone. }
    Check(LManifest.HasDependency('FJSON'), 'lookup ignores case');
    Check(not LManifest.HasDependency('nope'), 'an absent name is not found');
  finally
    LManifest.Free;
  end;
end;

procedure TestBuildAndProfiles;
var
  LManifest: TManifest;
begin
  LManifest := LoadSource(
    CMinimal + LineEnding +
    '[build]' + LineEnding +
    'mode = "delphi"' + LineEnding +
    'defines = ["USE_SSL", "DEBUG"]' + LineEnding +
    'flags = ["-vh"]' + LineEnding +
    LineEnding +
    '[profile.release]' + LineEnding +
    'optimize = 2' + LineEnding +
    'strip = false' + LineEnding +
    'warnings = "all"',
    'C:\dev\weather', '[build] and [profile]');
  if LManifest = nil then
    Exit;
  try
    CheckEqStr(LManifest.Build.Mode, 'delphi', 'the compiler mode is read');
    CheckEqInt(Length(LManifest.Build.Defines), 2, 'the defines are read');
    CheckEqInt(Length(LManifest.Build.Flags), 1, 'the raw flags are read');
    CheckEqInt(LManifest.Profile(bpRelease).Optimize, 2,
      'a profile overrides its default');
    CheckEqBool(LManifest.Profile(bpRelease).Strip, False,
      'a profile can turn a default off');
    CheckEqStr(LManifest.Profile(bpRelease).Warnings, 'all',
      'the warning level is read');
    { Overriding release must leave debug alone. }
    CheckEqInt(LManifest.Profile(bpDebug).Optimize, 0,
      'the other profile keeps its defaults');
  finally
    LManifest.Free;
  end;
end;

procedure TestDeclaredTargets;
var
  LManifest: TManifest;
  LTarget: TTarget;
  LCount: Integer;
begin
  LManifest := LoadSource(
    CMinimal + LineEnding +
    '[lib]' + LineEnding +
    'name = "weather"' + LineEnding +
    'path = "src/weather.pas"' + LineEnding +
    LineEnding +
    '[[bin]]' + LineEnding +
    'name = "weather"' + LineEnding +
    'path = "src/main.pas"' + LineEnding +
    LineEnding +
    '[[bin]]' + LineEnding +
    'name = "weather-admin"' + LineEnding +
    'path = "src/bin/admin.pas"',
    'C:\dev\weather', 'declared targets');
  if LManifest = nil then
    Exit;
  try
    CheckEqInt(Length(LManifest.Targets), 3, 'all three targets are read');
    Check(LManifest.HasLibrary(LTarget), 'the library is found');
    CheckEqStr(LTarget.SourcePath, 'src/weather.pas', 'its path is read');
    CheckEqInt(Length(LManifest.TargetsOfKind(tgBin)), 2, 'both binaries are read');

    { Two binaries, one of which carries the package name: that one is the
      default for `struo run`. }
    Check(LManifest.DefaultBinary(LTarget, LCount), 'a default binary is chosen');
    CheckEqInt(LCount, 2, 'the count of binaries is reported');
    CheckEqStr(LTarget.Name, 'weather',
      'the binary named after the package wins');
  finally
    LManifest.Free;
  end;
end;

procedure TestAmbiguousBinary;
var
  LManifest: TManifest;
  LTarget: TTarget;
  LCount: Integer;
begin
  LManifest := LoadSource(
    CMinimal + LineEnding +
    '[[bin]]' + LineEnding +
    'name = "alpha"' + LineEnding +
    'path = "src/bin/alpha.pas"' + LineEnding +
    LineEnding +
    '[[bin]]' + LineEnding +
    'name = "beta"' + LineEnding +
    'path = "src/bin/beta.pas"',
    'C:\dev\weather', 'two unrelated binaries');
  if LManifest = nil then
    Exit;
  try
    { Neither is named after the package, so Struo must ask rather than pick. }
    Check(not LManifest.DefaultBinary(LTarget, LCount),
      'an ambiguous choice is refused rather than guessed');
    CheckEqInt(LCount, 2, 'the caller is told how many there were');
  finally
    LManifest.Free;
  end;
end;

procedure TestRefusals;
begin
  CheckRefuses('', 'refuses an empty manifest');
  CheckRefuses('[dependencies]' + LineEnding + 'fjson = "1"',
    'refuses a manifest with no [package]');
  CheckRefuses('[package]' + LineEnding + 'version = "1.0.0"',
    'refuses a package with no name');
  CheckRefuses('[package]' + LineEnding + 'name = "weather"',
    'refuses a package with no version');
  CheckRefuses('[package]' + LineEnding + 'name = "weather"' + LineEnding +
    'version = "1.0"', 'refuses a partial version');
  CheckRefuses('[package]' + LineEnding + 'name = "2fast"' + LineEnding +
    'version = "1.0.0"', 'refuses a name starting with a digit');
  CheckRefuses('[package]' + LineEnding + 'name = "my package"' + LineEnding +
    'version = "1.0.0"', 'refuses a name with a space');
  CheckRefuses(CMinimal + LineEnding + 'edition = "1999"',
    'refuses an unknown edition');
  CheckRefuses(CMinimal + LineEnding + '[dependencies]' + LineEnding +
    'fjson = { }', 'refuses a dependency with no source');
  CheckRefuses(CMinimal + LineEnding + '[dependencies]' + LineEnding +
    'fjson = { version = "1.0", path = "../fjson" }',
    'refuses a dependency with two sources');
  CheckRefuses(CMinimal + LineEnding + '[dependencies]' + LineEnding +
    'f = { git = "https://x/y", tag = "v1", branch = "main" }',
    'refuses two git pins');
  CheckRefuses(CMinimal + LineEnding + '[dependencies]' + LineEnding +
    'fjson = "not-a-version"', 'refuses a bad version requirement');
  CheckRefuses(CMinimal + LineEnding + '[build]' + LineEnding +
    'mode = "cobol"', 'refuses an unknown compiler mode');
  CheckRefuses(CMinimal + LineEnding + '[profile.debug]' + LineEnding +
    'optimize = 9', 'refuses an out-of-range optimisation level');
  CheckRefuses(CMinimal + LineEnding + '[profile.debug]' + LineEnding +
    'warnings = "loud"', 'refuses an unknown warning level');
  CheckRefuses(CMinimal + LineEnding +
    'keywords = ["a", "b", "c", "d", "e", "f"]', 'refuses too many keywords');
  CheckRefuses(CMinimal + LineEnding + '[lib]' + LineEnding + 'name = "x"',
    'refuses a [lib] with no path');
  CheckRefuses(CMinimal + LineEnding + '[[bin]]' + LineEnding +
    'name = "a"' + LineEnding + 'path = "a.pas"' + LineEnding +
    '[[bin]]' + LineEnding + 'path = "b.pas"',
    'refuses an unnamed binary when there are several');
end;

procedure TestUnitNaming;
begin
  CheckEqStr(DefaultUnitName('weather'), 'weather',
    'a plain name is its own unit name');
  { A dash is legal in a package name and illegal in a Pascal identifier. }
  CheckEqStr(DefaultUnitName('my-lib'), 'my_lib',
    'a dash becomes an underscore for the unit name');
  Check(IsValidPackageName('my-lib'), 'a dash is valid in a package name');
  Check(IsValidPackageName('f_json2'), 'digits and underscores are valid');
  Check(not IsValidPackageName('2fast'), 'a leading digit is invalid');
  Check(not IsValidPackageName('my.lib'), 'a dot is invalid');
  Check(not IsValidPackageName(''), 'an empty name is invalid');
end;

{ ---- inference, which needs a tree on disk ------------------------------- }

{ Builds a throwaway package under the temp directory and returns its root. }
function MakePackageTree(const AName: string): string;
begin
  Result := JoinPath(GetTempDir(False), 'struo-test-' + AName + '-' +
                     IntToStr(Random(1000000)));
  EnsureDir(JoinPaths([Result, CSourceDirName, CBinSubDirName]));
  EnsureDir(JoinPath(Result, CTestsDirName));
  EnsureDir(JoinPath(Result, CExamplesDirName));
end;

procedure TestInference;
var
  LRoot: string;
  LManifest: TManifest;
  LTarget: TTarget;
begin
  LRoot := MakePackageTree('infer');
  try
    WriteTextFile(JoinPaths([LRoot, 'src', 'weather.pas']), 'unit weather;');
    WriteTextFile(JoinPaths([LRoot, 'src', 'main.pas']), 'program main;');
    WriteTextFile(JoinPaths([LRoot, 'src', 'bin', 'admin.pas']), 'program admin;');
    WriteTextFile(JoinPaths([LRoot, 'tests', 'test_one.pas']), 'program t;');
    WriteTextFile(JoinPaths([LRoot, 'examples', 'demo.pas']), 'program d;');

    LManifest := LoadSource(CMinimal, LRoot, 'inference');
    if LManifest = nil then
      Exit;
    try
      InferTargets(LManifest);

      Check(LManifest.HasLibrary(LTarget), 'src/<name>.pas becomes the library');
      CheckEqStr(LTarget.Name, 'weather', 'the library takes the package name');
      Check(not LTarget.Declared, 'it is marked as inferred');

      CheckEqInt(Length(LManifest.TargetsOfKind(tgBin)), 2,
        'src/main.pas and src/bin/*.pas become binaries');
      Check(LManifest.FindTarget(tgBin, 'weather', LTarget),
        'src/main.pas takes the package name');
      Check(LManifest.FindTarget(tgBin, 'admin', LTarget),
        'src/bin/admin.pas becomes `admin`');
      Check(LManifest.FindTarget(tgTest, 'test_one', LTarget),
        'tests/*.pas become test targets');
      Check(LManifest.FindTarget(tgExample, 'demo', LTarget),
        'examples/*.pas become example targets');

      { Everything inferred points at a file that exists, so validation must
        be satisfied. }
      try
        ValidateTargets(LManifest);
        Check(True, 'the inferred target set validates');
      except
        on E: EStruoError do
          Failed('the inferred target set validates', E.Message);
      end;
    finally
      LManifest.Free;
    end;
  finally
    RemoveTree(LRoot);
  end;
end;

procedure TestInferenceDoesNotOverrideDeclarations;
var
  LRoot: string;
  LManifest: TManifest;
begin
  LRoot := MakePackageTree('declared');
  try
    WriteTextFile(JoinPaths([LRoot, 'src', 'main.pas']), 'program main;');

    { src/main.pas is already claimed under another name. Inference must not
      add a second binary compiling the same file. }
    LManifest := LoadSource(
      CMinimal + LineEnding +
      '[[bin]]' + LineEnding +
      'name = "cli"' + LineEnding +
      'path = "src/main.pas"',
      LRoot, 'a declared binary');
    if LManifest = nil then
      Exit;
    try
      InferTargets(LManifest);
      CheckEqInt(Length(LManifest.TargetsOfKind(tgBin)), 1,
        'a claimed source file is not inferred a second time');
    finally
      LManifest.Free;
    end;
  finally
    RemoveTree(LRoot);
  end;
end;

procedure TestDashedPackageLibrary;
var
  LRoot: string;
  LManifest: TManifest;
  LTarget: TTarget;
begin
  LRoot := MakePackageTree('dashed');
  try
    { A package named `my-lib` cannot have a unit called `my-lib`, so the
      underscored spelling is what gets written and what must be found. }
    WriteTextFile(JoinPaths([LRoot, 'src', 'my_lib.pas']), 'unit my_lib;');

    LManifest := LoadSource(
      '[package]' + LineEnding +
      'name = "my-lib"' + LineEnding +
      'version = "0.1.0"',
      LRoot, 'a dashed package name');
    if LManifest = nil then
      Exit;
    try
      InferTargets(LManifest);
      Check(LManifest.HasLibrary(LTarget),
        'src/my_lib.pas is found for package my-lib');
      CheckEqStr(LTarget.Name, 'my_lib', 'the unit name uses the underscore');
    finally
      LManifest.Free;
    end;
  finally
    RemoveTree(LRoot);
  end;
end;

procedure TestNothingToBuild;
var
  LRoot: string;
  LManifest: TManifest;
begin
  LRoot := MakePackageTree('empty');
  try
    LManifest := LoadSource(CMinimal, LRoot, 'an empty package');
    if LManifest = nil then
      Exit;
    try
      InferTargets(LManifest);
      try
        ValidateTargets(LManifest);
        Failed('an empty package is refused', 'validation passed');
      except
        on E: EStruoError do
          Check(E.Hint <> '', 'an empty package is refused with a hint');
      end;
    finally
      LManifest.Free;
    end;
  finally
    RemoveTree(LRoot);
  end;
end;

procedure TestLoadFromDisk;
var
  LRoot: string;
  LManifest: TManifest;
begin
  LRoot := MakePackageTree('ondisk');
  try
    WriteTextFile(JoinPath(LRoot, CManifestName), CMinimal);
    LManifest := TManifest.Load(JoinPath(LRoot, CManifestName));
    try
      CheckEqStr(LManifest.Name, 'weather', 'a manifest loads from disk');
      CheckEqStr(LManifest.Root, PathWithoutTrailingSep(NormalizePath(LRoot)),
        'the package root is the manifest directory');
    finally
      LManifest.Free;
    end;

    { The error for a missing manifest is what a user sees most often after a
      mistyped `cd`, so it carries the next step. }
    try
      TManifest.Load(JoinPath(LRoot, 'Nope.toml'));
      Failed('a missing manifest is refused', 'no exception');
    except
      on E: EStruoError do
        Check(E.Hint <> '', 'a missing manifest is refused with a hint');
    end;
  finally
    RemoveTree(LRoot);
  end;
end;

begin
  Randomize;
  Suite('manifest');
  TestMinimal;
  TestFullPackageSection;
  TestDependencies;
  TestBuildAndProfiles;
  TestDeclaredTargets;
  TestAmbiguousBinary;
  TestRefusals;
  TestUnitNaming;
  TestInference;
  TestInferenceDoesNotOverrideDeclarations;
  TestDashedPackageLibrary;
  TestNothingToBuild;
  TestLoadFromDisk;
  Halt(TestSummary);
end.
