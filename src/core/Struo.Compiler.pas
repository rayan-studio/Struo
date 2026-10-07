{ Struo.Compiler -- finding Free Pascal and driving it.

  Two things this unit does that calling fpc by hand does not:

  * It passes the packaged unit directory explicitly. A Free Pascal install
    without an fpc.cfg can locate its RTL and nothing else, so `uses Process`
    fails with `Can't find unit` and no indication why. Struo works out where
    the packages live from the compiler's own answers to -iV, -iTP and -iTO,
    and puts them on the search path every time. `struo doctor` reports when
    the config is missing, since the user may want to fix it properly.

  * It creates output directories. fpc does not, and its error for a missing
    one is `Path "bin\" does not exist`, which sounds like the user's mistake
    rather than a directory the build system should have made.

  Arguments are built into an array and handed to the process one by one, so
  a path containing a space -- which on Windows is most of them -- survives. }
unit Struo.Compiler;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings, Struo.Types, Struo.Manifest;

type
  { Where the compiler Struo is using came from. The distinction matters for
    reproducibility: two people on the same Struo release share a bundled
    toolchain exactly, and share nothing in particular otherwise. }
  TToolchainOrigin = (
    toNone,
    { STRUO_FPC, STRUO_TOOLCHAIN, or a path passed in code. }
    toExplicit,
    { Shipped in the Struo release, beside the binary. }
    toBundled,
    { Found on PATH or in a conventional install root. }
    toSystem
  );

  TCompilerInfo = record
    Found: Boolean;
    Origin: TToolchainOrigin;

    { True when Struo supplies every search path itself and tells fpc to read
      no configuration file at all. Set for the bundled toolchain, so that a
      stray fpc.cfg elsewhere on the machine cannot reach into a Struo build
      and point it at another installation's units. }
    Hermetic: Boolean;

    { Absolute path to the fpc driver executable. }
    Path: string;
    { As reported by -iV, for instance '3.2.2'. }
    Version: string;
    { As reported by -iTP and -iTO. }
    Cpu: string;
    OS: string;
    { 'i386-win32'. The name of the packaged unit directory. }
    Target: string;
    { The installation root, the directory holding bin/ and units/. }
    BaseDir: string;
    { Where the packaged units live, or '' when they could not be located. }
    UnitsDir: string;
    { False when fpc found no fpc.cfg. Struo copes either way, but it is worth
      telling the user, because everything else on their machine will not. }
    HasConfig: Boolean;
  end;

  { One compilation: a source file in, a binary or a set of units out. }
  TCompileRequest = record
    { Absolute path to the program or unit to compile. }
    SourceFile: string;
    { Absolute path of the executable to produce, or '' to compile units
      only, as a library target does. }
    OutputFile: string;
    { Absolute directory for .ppu and .o output. Created if missing. }
    UnitOutputDir: string;

    UnitSearchPaths: TStrArray;
    IncludePaths: TStrArray;
    LibraryPaths: TStrArray;
    Defines: TStrArray;

    { objfpc, delphi, fpc or macpas. }
    Mode: string;
    { A target triple such as x86_64-win64, or '' for the host. }
    TargetTriple: string;

    Settings: TProfileSettings;
    ExtraFlags: TStrArray;

    { Skip the linker: for `struo check`, where only diagnostics matter. }
    CheckOnly: Boolean;

    { The directory to run the compiler in. Diagnostics are relative to it. }
    WorkDir: string;
  end;

  TCompileResult = record
    Success: Boolean;
    ExitCode: Integer;
    { The compiler's diagnostics, stdout and stderr interleaved. }
    Output: string;
    { The command as a shell would accept it, for --verbose and errors. }
    Command: string;
    Elapsed: Double;
  end;

  TCompilerInfoArray = array of TCompilerInfo;

{ Looks for a compiler and asks it about itself, in this order:

    1. AOverride, when it is not empty
    2. STRUO_FPC        -- an fpc executable
    3. STRUO_TOOLCHAIN  -- a Free Pascal installation root
    4. the toolchain shipped with this Struo, beside the binary
    5. PATH, then the conventional install roots

  An explicit choice beats the bundled toolchain, because someone setting
  STRUO_FPC is telling Struo something it should not second-guess. Everything
  else loses to the bundled one, so that a machine with an old Free Pascal
  installed does not quietly change what Struo compiles with.

  Returns a record with Found False rather than raising, so `struo doctor` can
  report the absence instead of dying of it. }
function DetectCompiler(const AOverride: string): TCompilerInfo;

{ The host compiler, detected once per process. }
function HostCompiler: TCompilerInfo;

{ Every toolchain Struo can see, most preferred first, for `struo toolchain`.
  Entries that could not answer -iV are left out. }
function DiscoverToolchains: TCompilerInfoArray;

{ The fpc driver inside ARoot, a Free Pascal installation root, or '' when
  there is none. Looks for bin/<target>/fpc and bin/fpc, which covers a
  Windows install and a Unix one. }
function FindCompilerInRoot(const ARoot: string): string;

{ 'bundled', 'system', 'explicit'. For diagnostics. }
function ToolchainOriginName(AOrigin: TToolchainOrigin): string;

{ Raises EStruoError with installation advice when no compiler was found, or
  when the one found is too old. }
procedure RequireCompiler(const AInfo: TCompilerInfo);

{ The exact argument list Struo would pass. Separated from Compile so that it
  can be tested without running anything. }
function BuildArguments(const AInfo: TCompilerInfo;
  const ARequest: TCompileRequest): TStrArray;

{ Creates the output directories, runs the compiler and collects the result.
  Does not print: the caller decides how to render the diagnostics. }
function Compile(const AInfo: TCompilerInfo;
  const ARequest: TCompileRequest): TCompileResult;

{ Fills a request with this manifest's [build] settings and the given
  profile, leaving the per-target fields for the caller. }
function RequestFromManifest(AManifest: TManifest;
  AProfile: TBuildProfile): TCompileRequest;

const
  { Below this, Free Pascal lacks the namespaced unit names Struo's own source
    relies on, so there is no point pretending it will work. }
  CMinimumFpcVersion = '3.2.0';

implementation

uses
  Struo.Util.Fs, Struo.Util.Proc, Struo.Paths, Struo.SemVer;

var
  GHostCompiler: TCompilerInfo;
  GHostDetected: Boolean = False;

{ ---- discovery ----------------------------------------------------------- }

{ Asks the compiler one question. fpc answers -iXX with a single line. }
function AskCompiler(const APath, AQuery: string): string;
var
  LOutcome: TProcOutcome;
  LLines: TStrArray;
begin
  Result := '';
  LOutcome := RunCaptured(APath, [AQuery], '');
  if not LOutcome.Spawned then
    Exit;
  LLines := SplitLines(LOutcome.Output);
  if Length(LLines) > 0 then
    Result := Trim(LLines[0]);
end;

{ Candidate locations for the packaged units, in the order worth trying. A
  Windows install keeps them under the compiler's own root; a Unix package
  puts them under /usr/lib/fpc/<version>. }
function LocateUnitsDir(const ABaseDir, ATarget, AVersion: string): string;
var
  LCandidates: TStrArray;
  I: Integer;
begin
  LCandidates := StrArrayOf([
    JoinPaths([ABaseDir, 'units', ATarget]),
    JoinPaths([ABaseDir, 'lib', 'fpc', AVersion, 'units', ATarget]),
    JoinPaths(['/usr/lib/fpc', AVersion, 'units', ATarget]),
    JoinPaths(['/usr/local/lib/fpc', AVersion, 'units', ATarget])
  ]);

  for I := 0 to High(LCandidates) do
    if PathIsDir(LCandidates[I]) then
      Exit(NormalizePath(LCandidates[I]));
  Result := '';
end;

{ True when fpc reports reading a configuration file. -vt lists every path it
  tried and every file it read; a line beginning `Using config file` means it
  found one. }
function CompilerHasConfig(const APath: string): Boolean;
var
  LOutcome: TProcOutcome;
begin
  { -h alone makes fpc print help and exit without needing a source file. }
  LOutcome := RunCaptured(APath, ['-vt', '-h'], '');
  Result := LOutcome.Spawned and
            (Pos('Using config file', LOutcome.Output) > 0);
end;

{ Walks the usual Windows install roots looking for an fpc executable, newest
  version directory first. }
function ProbeInstallRoots: string;
{$IFDEF WINDOWS}
var
  LRoots, LVersions, LTargets: TStrArray;
  LRoot, LCandidate: string;
  I, J, K: Integer;
begin
  Result := '';
  LRoots := StrArrayOf(['C:\FPC', 'C:\lazarus\fpc',
                        JoinPath(SysUtils.GetEnvironmentVariable('ProgramFiles'), 'FPC')]);

  for I := 0 to High(LRoots) do
  begin
    LRoot := LRoots[I];
    if not PathIsDir(LRoot) then
      Continue;

    { <root>/<version>/bin/<target>/fpc.exe }
    LVersions := ListDirsIn(LRoot);
    for J := High(LVersions) downto 0 do
    begin
      LTargets := ListDirsIn(JoinPaths([LRoot, LVersions[J], 'bin']));
      for K := 0 to High(LTargets) do
      begin
        LCandidate := JoinPaths([LRoot, LVersions[J], 'bin', LTargets[K], 'fpc.exe']);
        if PathIsFile(LCandidate) then
          Exit(NormalizePath(LCandidate));
      end;
    end;
  end;
end;
{$ELSE}
var
  LCandidates: TStrArray;
  I: Integer;
begin
  Result := '';
  LCandidates := StrArrayOf(['/usr/local/bin/fpc', '/usr/bin/fpc', '/opt/fpc/bin/fpc']);
  for I := 0 to High(LCandidates) do
    if PathIsFile(LCandidates[I]) then
      Exit(LCandidates[I]);
end;
{$ENDIF}

function ToolchainOriginName(AOrigin: TToolchainOrigin): string;
begin
  case AOrigin of
    toExplicit: Result := 'explicit';
    toBundled:  Result := 'bundled';
    toSystem:   Result := 'system';
  else
    Result := 'none';
  end;
end;

function FindCompilerInRoot(const ARoot: string): string;
var
  LTargets: TStrArray;
  LCandidate: string;
  I: Integer;
begin
  Result := '';
  if not PathIsDir(ARoot) then
    Exit;

  { A Windows install keeps the driver at bin/<target>/fpc.exe. }
  LTargets := ListDirsIn(JoinPath(ARoot, 'bin'));
  for I := 0 to High(LTargets) do
  begin
    LCandidate := JoinPaths([ARoot, 'bin', LTargets[I], ExecutableName('fpc')]);
    if PathIsFile(LCandidate) then
      Exit(NormalizePath(LCandidate));
  end;

  { A Unix install keeps it at bin/fpc. }
  LCandidate := JoinPaths([ARoot, 'bin', ExecutableName('fpc')]);
  if PathIsFile(LCandidate) then
    Exit(NormalizePath(LCandidate));
end;

{ Asks APath about itself and fills in a record. Found stays False when it
  does not answer, which is how a file called fpc that is not a Free Pascal
  driver gets rejected. }
function DescribeCompiler(const APath: string; AOrigin: TToolchainOrigin;
  AHermetic: Boolean): TCompilerInfo;
var
  LBinDir: string;
begin
  Result := Default(TCompilerInfo);
  if APath = '' then
    Exit;

  Result.Path := APath;
  Result.Origin := AOrigin;
  Result.Hermetic := AHermetic;

  Result.Version := AskCompiler(APath, '-iV');
  if Result.Version = '' then
    Exit;

  Result.Cpu := AskCompiler(APath, '-iTP');
  Result.OS := AskCompiler(APath, '-iTO');
  Result.Target := Result.Cpu + '-' + Result.OS;

  { fpc sits at <base>/bin/<target>/fpc, so the root is two levels above its
    directory. On a Unix install where fpc is in /usr/bin, that gives /, and
    LocateUnitsDir falls through to the /usr/lib candidates. }
  LBinDir := PathWithoutTrailingSep(ExtractFilePath(APath));
  Result.BaseDir := PathWithoutTrailingSep(
    ExtractFilePath(PathWithoutTrailingSep(ExtractFilePath(LBinDir))));

  Result.UnitsDir := LocateUnitsDir(Result.BaseDir, Result.Target, Result.Version);

  { A hermetic toolchain is told to read no config, so asking whether one
    exists would only produce a misleading answer. }
  if AHermetic then
    Result.HasConfig := False
  else
    Result.HasConfig := CompilerHasConfig(APath);

  Result.Found := True;
end;

{ The bundled toolchain, or a record with Found False. }
function DetectBundled: TCompilerInfo;
var
  LRoots: TStrArray;
  LPath: string;
  I: Integer;
begin
  LRoots := BundledToolchainRoots;
  for I := 0 to High(LRoots) do
  begin
    LPath := FindCompilerInRoot(LRoots[I]);
    if LPath = '' then
      Continue;
    Result := DescribeCompiler(LPath, toBundled, True);
    if Result.Found then
      Exit;
  end;
  Result := Default(TCompilerInfo);
end;

function DetectCompiler(const AOverride: string): TCompilerInfo;
var
  LPath: string;
begin
  { 1 and 2: an explicit choice, which must beat everything including the
    bundled toolchain. }
  LPath := '';
  if AOverride <> '' then
    LPath := FindExecutable(AOverride);
  if LPath = '' then
    LPath := FindExecutable(SysUtils.GetEnvironmentVariable('STRUO_FPC'));

  { 3: an explicit installation root rather than an executable. }
  if LPath = '' then
    LPath := FindCompilerInRoot(
      SysUtils.GetEnvironmentVariable('STRUO_TOOLCHAIN'));

  if LPath <> '' then
  begin
    Result := DescribeCompiler(LPath, toExplicit, False);
    if Result.Found then
      Exit;
  end;

  { 4: the toolchain this Struo shipped with. }
  Result := DetectBundled;
  if Result.Found then
    Exit;

  { 5: whatever the machine happens to have. }
  LPath := FindExecutable('fpc');
  if LPath = '' then
    LPath := ProbeInstallRoots;
  Result := DescribeCompiler(LPath, toSystem, False);
end;

function HostCompiler: TCompilerInfo;
begin
  if not GHostDetected then
  begin
    GHostCompiler := DetectCompiler('');
    GHostDetected := True;
  end;
  Result := GHostCompiler;
end;

function DiscoverToolchains: TCompilerInfoArray;
var
  LSeen: TStrArray;

  procedure Consider(const APath: string; AOrigin: TToolchainOrigin;
    AHermetic: Boolean);
  var
    LInfo: TCompilerInfo;
  begin
    if APath = '' then
      Exit;
    { One installation reached two ways is still one installation. }
    if StrArrayHas(LSeen, LowerCase(APath)) then
      Exit;
    LInfo := DescribeCompiler(APath, AOrigin, AHermetic);
    if not LInfo.Found then
      Exit;
    StrArrayAdd(LSeen, LowerCase(APath));
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := LInfo;
  end;

var
  LRoots: TStrArray;
  I: Integer;
begin
  Result := nil;
  LSeen := nil;

  Consider(FindExecutable(SysUtils.GetEnvironmentVariable('STRUO_FPC')),
    toExplicit, False);
  Consider(FindCompilerInRoot(SysUtils.GetEnvironmentVariable('STRUO_TOOLCHAIN')),
    toExplicit, False);

  LRoots := BundledToolchainRoots;
  for I := 0 to High(LRoots) do
    Consider(FindCompilerInRoot(LRoots[I]), toBundled, True);

  Consider(FindExecutable('fpc'), toSystem, False);
  Consider(ProbeInstallRoots, toSystem, False);
end;

procedure RequireCompiler(const AInfo: TCompilerInfo);
var
  LFound, LMinimum: TSemVer;
begin
  LFound := Default(TSemVer);
  LMinimum := Default(TSemVer);

  if not AInfo.Found then
    raise EStruoError.CreateHint('no Free Pascal compiler found',
      'install Free Pascal from https://www.freepascal.org/ and put `fpc` on ' +
      'your PATH, or set STRUO_FPC to its full path');

  { An unparseable version is a development snapshot. Those are usually newer
    than the minimum, so let them through rather than blocking on a string. }
  if TryParseSemVer(AInfo.Version, LFound) and
     TryParseSemVer(CMinimumFpcVersion, LMinimum) and
     (CompareSemVer(LFound, LMinimum) < 0) then
    raise EStruoError.CreateHintFmt(
      'Free Pascal %s is too old; Struo needs %s or newer',
      [AInfo.Version, CMinimumFpcVersion],
      'upgrade from https://www.freepascal.org/');
end;

{ ---- argument construction ----------------------------------------------- }

{ Maps a warning level onto fpc's verbosity switches. }
procedure AppendWarningFlags(const AWarnings: string; var AArgs: TStrArray);
begin
  if AWarnings = 'none' then
    { Silence warnings, notes and hints alike. }
    StrArrayAddAll(AArgs, ['-vw-', '-vn-', '-vh-'])
  else if AWarnings = 'all' then
    StrArrayAddAll(AArgs, ['-vwnh'])
  else if AWarnings = 'error' then
    { -Sew turns a warning into a failed build, which is what a CI run wants. }
    StrArrayAddAll(AArgs, ['-vwnh', '-Sew'])
  else
    { 'default': warnings on, notes and hints off, which is fpc's own
      sensible middle ground. }
    StrArrayAddAll(AArgs, ['-vw', '-vn-', '-vh-']);
end;

function BuildArguments(const AInfo: TCompilerInfo;
  const ARequest: TCompileRequest): TStrArray;
var
  I: Integer;
  LMode: string;
begin
  Result := nil;

  { -n tells fpc to read no configuration file. For the bundled toolchain
    that is the point: Struo passes every search path explicitly, so an
    fpc.cfg belonging to some other installation on the machine must not get
    a say in what this build compiles against. A system compiler keeps its
    config, since the user may have put something there Struo cannot know. }
  if AInfo.Hermetic then
    StrArrayAdd(Result, '-n');

  LMode := ARequest.Mode;
  if LMode = '' then
    LMode := 'objfpc';
  StrArrayAdd(Result, '-M' + LMode);

  { -Sh makes `string` mean AnsiString rather than the 255-byte ShortString.
    Every modern Pascal package assumes this, and a package that does not can
    still turn it off with an H-minus directive in its own source. }
  StrArrayAdd(Result, '-Sh');

  { Cross-compilation target. Both halves are needed, or fpc keeps the host
    CPU with the requested OS. }
  if ARequest.TargetTriple <> '' then
  begin
    I := Pos('-', ARequest.TargetTriple);
    if I > 1 then
    begin
      StrArrayAdd(Result, '-P' + Copy(ARequest.TargetTriple, 1, I - 1));
      StrArrayAdd(Result, '-T' + Copy(ARequest.TargetTriple, I + 1, MaxInt));
    end;
  end;

  { Level zero is spelled `-O-`, not `-O0`: fpc rejects the latter outright.
    The manifest uses 0..4 because that is what a person expects to write. }
  if ARequest.Settings.Optimize <= 0 then
    StrArrayAdd(Result, '-O-')
  else
    StrArrayAdd(Result, '-O' + IntToStr(ARequest.Settings.Optimize));

  if ARequest.Settings.Debug then
    { -g for debug info, -gl for the line numbers that make a backtrace
      readable. }
    StrArrayAddAll(Result, ['-g', '-gl']);

  if ARequest.Settings.Checks then
    { Range, overflow and IO checking. On in debug, off in release. }
    StrArrayAddAll(Result, ['-Cr', '-Co', '-Ci']);

  if ARequest.Settings.SmartLink then
    StrArrayAddAll(Result, ['-CX', '-XX']);

  if ARequest.Settings.Strip then
    StrArrayAdd(Result, '-Xs');

  AppendWarningFlags(ARequest.Settings.Warnings, Result);

  for I := 0 to High(ARequest.Defines) do
    StrArrayAdd(Result, '-d' + ARequest.Defines[I]);

  for I := 0 to High(ARequest.IncludePaths) do
    StrArrayAdd(Result, '-Fi' + ARequest.IncludePaths[I]);

  for I := 0 to High(ARequest.UnitSearchPaths) do
    StrArrayAdd(Result, '-Fu' + ARequest.UnitSearchPaths[I]);

  for I := 0 to High(ARequest.LibraryPaths) do
    StrArrayAdd(Result, '-Fl' + ARequest.LibraryPaths[I]);

  { The compiler's own packages, last so a package's own units win a name
    clash against the distribution's. The trailing wildcard is fpc's syntax
    for 'every subdirectory of this one'. }
  if AInfo.UnitsDir <> '' then
    StrArrayAdd(Result, '-Fu' + JoinPath(AInfo.UnitsDir, '*'));

  if ARequest.UnitOutputDir <> '' then
    StrArrayAdd(Result, '-FU' + ARequest.UnitOutputDir);

  if ARequest.CheckOnly then
    { Compile and assemble, but do not link. Everything that can be wrong
      with the source has already been reported by then. }
    StrArrayAdd(Result, '-Cn')
  else if ARequest.OutputFile <> '' then
    StrArrayAdd(Result, '-o' + ARequest.OutputFile);

  for I := 0 to High(ARequest.ExtraFlags) do
    if not IsBlankStr(ARequest.ExtraFlags[I]) then
      StrArrayAdd(Result, ARequest.ExtraFlags[I]);

  { The source file goes last, as fpc expects. }
  StrArrayAdd(Result, ARequest.SourceFile);
end;

{ ---- running ------------------------------------------------------------- }

function Compile(const AInfo: TCompilerInfo;
  const ARequest: TCompileRequest): TCompileResult;
var
  LArgs: TStrArray;
  LOutcome: TProcOutcome;
begin
  Result := Default(TCompileResult);
  LArgs := BuildArguments(AInfo, ARequest);
  Result.Command := FormatCommand(AInfo.Path, LArgs);

  { fpc will not create these, and its complaint about a missing one reads
    like the user's mistake rather than the build system's. }
  if ARequest.UnitOutputDir <> '' then
    EnsureDir(ARequest.UnitOutputDir);
  if ARequest.OutputFile <> '' then
    EnsureDir(PathWithoutTrailingSep(ExtractFilePath(ARequest.OutputFile)));

  LOutcome := RunCaptured(AInfo.Path, LArgs, ARequest.WorkDir);
  Result.ExitCode := LOutcome.ExitCode;
  Result.Output := LOutcome.Output;
  Result.Elapsed := LOutcome.Elapsed;

  if not LOutcome.Spawned then
    raise EStruoError.CreateHintFmt('could not run the compiler `%s`',
      [AInfo.Path], LOutcome.Output);

  Result.Success := LOutcome.ExitCode = 0;
end;

function RequestFromManifest(AManifest: TManifest;
  AProfile: TBuildProfile): TCompileRequest;
var
  I: Integer;
begin
  Result := Default(TCompileRequest);
  Result.Mode := AManifest.Build.Mode;
  Result.TargetTriple := AManifest.Build.Target;
  Result.Settings := AManifest.Profile(AProfile);
  Result.Defines := AManifest.Build.Defines;
  Result.ExtraFlags := AManifest.Build.Flags;
  Result.WorkDir := AManifest.Root;

  { Paths in [build] are relative to the package, so resolve them once here
    rather than at every use. }
  for I := 0 to High(AManifest.Build.IncludePaths) do
    StrArrayAdd(Result.IncludePaths,
      AbsolutePath(AManifest.Build.IncludePaths[I], AManifest.Root));
  for I := 0 to High(AManifest.Build.UnitPaths) do
    StrArrayAdd(Result.UnitSearchPaths,
      AbsolutePath(AManifest.Build.UnitPaths[I], AManifest.Root));
  for I := 0 to High(AManifest.Build.LibraryPaths) do
    StrArrayAdd(Result.LibraryPaths,
      AbsolutePath(AManifest.Build.LibraryPaths[I], AManifest.Root));

  { A package's own src/ is always searchable, so a unit can `uses` a sibling
    without the manifest saying so. }
  StrArrayAddUnique(Result.UnitSearchPaths,
    JoinPath(AManifest.Root, CSourceDirName));
end;

end.
