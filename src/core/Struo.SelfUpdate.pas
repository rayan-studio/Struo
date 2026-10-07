{ Struo.SelfUpdate -- replacing Struo with a newer Struo.

  A self-updater is one of the few things a tool can get wrong in a way the
  user cannot recover from, so the order of operations here is the design:

    1. Download the archive to a temp file, renamed into place only once
       complete, so a dropped connection cannot look like a finished download.
    2. Unpack it inside the installation directory, not over it.
    3. Run the unpacked binary with --version and require the answer the
       release promised. This is the gate: a truncated download, a wrong
       platform's archive or a corrupt build is caught here, before anything
       the user depends on has been touched.
    4. Only then swap, moving the old files aside rather than deleting them,
       and moving them back if the swap fails halfway.

  Replacing a running executable is allowed on both platforms, but only by
  renaming it out of the way first: Windows will not let the file be
  overwritten while it is mapped, and will happily let it be renamed. The old
  binary therefore survives until the next run, which is what
  CleanUpAfterUpdate is for. }
unit Struo.SelfUpdate;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings, Struo.Types, Struo.SemVer, Struo.Release;

{ True when this Struo is able to replace itself. AReason explains why not,
  phrased for the user. }
function CanSelfUpdate(out AReason: string): Boolean;

{ Downloads, unpacks and verifies ARelease without touching the installation,
  and returns the directory holding the verified new version. Everything this
  does is undone by deleting that directory, which DiscardStaged does.

  ARelease is trusted: the check that an asset's URL belongs to the right
  repository happens in Struo.Release, where the untrusted JSON is read. A
  caller that builds a TReleaseInfo itself is on its own. }
function StageRelease(const ARelease: TReleaseInfo): string;

{ Moves the staged version into place, putting the old files aside rather than
  deleting them, and putting them back if the swap fails partway. }
procedure CommitStaged(const APayloadDir: string; const ARelease: TReleaseInfo);

{ Throws away what StageRelease produced. }
procedure DiscardStaged;

{ StageRelease then CommitStaged. Raises EStruoError, having left the
  installation as it was, on any failure. }
procedure InstallRelease(const ARelease: TReleaseInfo);

{ Removes what a previous update left behind, including the binary that was
  running when it happened. Cheap, silent, and called at startup. }
procedure CleanUpAfterUpdate;

{ ---- the update notice --------------------------------------------------- }

{ The tag of a newer release, or '' when there is none, when it was checked
  recently, or when anything at all went wrong.

  Asks GitHub at most once a day and remembers the answer, so the cost of the
  notice is one request a day rather than one per command. Every failure is
  silent: a command must not start reporting errors because the network is
  down. }
function PendingUpdateTag: string;

{ True when the notice should be offered at all: a terminal is watching, the
  user has not opted out, and this Struo could act on the answer. }
function UpdateCheckAllowed: Boolean;

implementation

uses
  DateUtils, Struo.Util.Fs, Struo.Util.Proc, Struo.Paths, Struo.Compiler,
  Struo.Net, Struo.Toml.Value, Struo.Toml.Parser, Struo.Toml.Writer,
  Struo.Cli.Output;

const
  { Staging and quarantine directories, inside the installation so that the
    swap is a rename on one volume rather than a copy across two. }
  CStagingDirName = '.struo-new';
  CQuarantineDirName = '.struo-old';

  { One request a day is enough to tell somebody a release happened. }
  CCheckIntervalSeconds = 24 * 60 * 60;

  CCacheFileName = 'update-check.toml';

{ ---- eligibility --------------------------------------------------------- }

{ The directory holding this installation, which is where the swap happens. }
function InstallDir: string;
begin
  Result := StruoExecutableDir;
end;

{ True when APath's directory accepts a new file. Tested by writing one
  rather than by inspecting permissions, which on Windows is the only answer
  that means anything. }
function DirectoryIsWritable(const ADir: string): Boolean;
var
  LProbe: string;
begin
  LProbe := JoinPath(ADir, '.struo-write-test');
  Result := False;
  try
    WriteTextFile(LProbe, 'probe');
    Result := PathIsFile(LProbe);
    DeleteFile(LProbe);
  except
    on EFsError do
      Result := False;
  end;
end;

function CanSelfUpdate(out AReason: string): Boolean;
var
  LCompiler: TCompilerInfo;
begin
  AReason := '';
  Result := False;

  LCompiler := HostCompiler;

  { A build from bootstrap/ has no toolchain beside it, so there is no release
    archive this installation corresponds to. Updating it would mean replacing
    a developer's own build with a published one, which is not what they
    want. }
  if not PathIsDir(JoinPath(InstallDir, 'toolchain')) then
  begin
    if LCompiler.Origin = toBundled then
      AReason := 'this Struo''s toolchain is installed separately from its ' +
                 'binary, so updating it is the package manager''s job'
    else
      AReason := 'this Struo was built from source rather than installed ' +
                 'from a release; update it with `git pull` and ' +
                 '`./bootstrap/build.ps1`';
    Exit;
  end;

  if not DirectoryIsWritable(InstallDir) then
  begin
    AReason := Format('`%s` is not writable', [InstallDir]);
    Exit;
  end;

  if not HasHttpClient then
  begin
    AReason := 'no HTTP client was found, so Struo cannot reach GitHub';
    Exit;
  end;

  Result := True;
end;

{ ---- installing ---------------------------------------------------------- }

{ The single directory an unpacked release archive contains. Returns '' when
  the archive did not look like a release. }
function PayloadDir(const AStagingDir: string): string;
var
  LEntries: TStrArray;
begin
  Result := '';
  LEntries := ListDirsIn(AStagingDir);

  { A release archive holds exactly one top-level directory,
    struo-<version>-<target>. Anything else is not one. }
  if Length(LEntries) = 1 then
    Result := JoinPath(AStagingDir, LEntries[0])
  { Tolerate an archive packed without the wrapping directory. }
  else if PathIsFile(JoinPath(AStagingDir, ExecutableName('struo'))) then
    Result := AStagingDir;
end;

{ Runs the staged binary and checks it reports AExpected. This is the gate
  that makes the swap below safe to attempt. }
procedure VerifyStagedBinary(const APayloadDir: string;
  const AExpected: TSemVer);
var
  LBinary: string;
  LOutcome: TProcOutcome;
  LReported: TSemVer;
  LText: string;
begin
  LBinary := JoinPath(APayloadDir, ExecutableName('struo'));
  if not PathIsFile(LBinary) then
    raise EStruoError.CreateHint('the downloaded archive has no struo binary',
      'the release may be packaged wrongly; nothing was changed');

  LOutcome := RunCaptured(LBinary, ['--version'], APayloadDir);
  if (not LOutcome.Spawned) or (LOutcome.ExitCode <> 0) then
    raise EStruoError.CreateHint('the downloaded struo will not run',
      Trim(LOutcome.Output) + ' -- nothing was changed');

  { Output is `struo 0.2.0`; the version is what has to match. }
  LText := Trim(LOutcome.Output);
  if StartsWithStr(LowerCase(LText), 'struo ') then
    LText := Trim(Copy(LText, 7, MaxInt));

  if not TryParseSemVer(LText, LReported) then
    raise EStruoError.CreateHintFmt(
      'the downloaded struo reported `%s` rather than a version', [LText],
      'nothing was changed');

  if not SameSemVer(LReported, AExpected) then
    raise EStruoError.CreateHintFmt(
      'the release says %s but the binary in it reports %s',
      [SemVerToStr(AExpected), SemVerToStr(LReported)],
      'nothing was changed');

  TraceFmt('staged binary verified: %s', [LText]);
end;

{ Moves ASource to ADestination, raising with both paths on failure. }
procedure MoveOrFail(const ASource, ADestination, AWhat: string);
begin
  if not RenameFile(ASource, ADestination) then
    raise EStruoError.CreateHintFmt('could not move %s into place', [AWhat],
      Format('`%s` -> `%s`', [ASource, ADestination]));
end;

{ Replaces the installation with what is in APayloadDir. Either finishes or
  puts back what it moved. }
procedure SwapIn(const APayloadDir: string);
var
  LInstall, LQuarantine, LName: string;
  LFiles: TStrArray;
  LToolchainMoved: Boolean;
  I: Integer;
begin
  LInstall := InstallDir;
  LQuarantine := JoinPath(LInstall, CQuarantineDirName);

  { A quarantine left by an earlier update would collide with this one. }
  RemoveTree(LQuarantine);
  EnsureDir(LQuarantine);

  LToolchainMoved := False;
  try
    { The toolchain first: it is the big part, and it is the part nothing is
      holding open while Struo is merely updating itself. }
    if PathIsDir(JoinPath(LInstall, 'toolchain')) then
    begin
      MoveOrFail(JoinPath(LInstall, 'toolchain'),
                 JoinPath(LQuarantine, 'toolchain'), 'the old toolchain');
      LToolchainMoved := True;
    end;
    if PathIsDir(JoinPath(APayloadDir, 'toolchain')) then
      MoveOrFail(JoinPath(APayloadDir, 'toolchain'),
                 JoinPath(LInstall, 'toolchain'), 'the new toolchain');

    { Then the binary. Renaming a running executable is permitted; overwriting
      one is not, which is why this is a move and not a copy. }
    LName := ExecutableName('struo');
    MoveOrFail(JoinPath(LInstall, LName), JoinPath(LQuarantine, LName),
               'the running binary');
    try
      MoveOrFail(JoinPath(APayloadDir, LName), JoinPath(LInstall, LName),
                 'the new binary');
    except
      { Without a binary there is no Struo, so this one failure is worth
        undoing by hand before re-raising. }
      RenameFile(JoinPath(LQuarantine, LName), JoinPath(LInstall, LName));
      raise;
    end;
  except
    if LToolchainMoved and not PathIsDir(JoinPath(LInstall, 'toolchain')) then
      RenameFile(JoinPath(LQuarantine, 'toolchain'),
                 JoinPath(LInstall, 'toolchain'));
    raise;
  end;

  { Everything else in the archive -- README, LICENSE, THIRD-PARTY -- is
    documentation, so a failure to replace it is not worth undoing a working
    update for. }
  LFiles := ListFilesIn(APayloadDir, '*');
  for I := 0 to High(LFiles) do
  begin
    if SameText(LFiles[I], ExecutableName('struo')) then
      Continue;
    if PathIsFile(JoinPath(LInstall, LFiles[I])) then
      DeleteFile(JoinPath(LInstall, LFiles[I]));
    RenameFile(JoinPath(APayloadDir, LFiles[I]),
               JoinPath(LInstall, LFiles[I]));
  end;
end;

procedure DiscardStaged;
begin
  RemoveTree(JoinPath(InstallDir, CStagingDirName));
end;

function StageRelease(const ARelease: TReleaseInfo): string;
var
  LAsset: TReleaseAsset;
  LStaging, LArchive: string;
  LReason: string;
begin
  if not CanSelfUpdate(LReason) then
    raise EStruoError.CreateHint('Struo cannot update itself here', LReason);

  if not FindHostAsset(ARelease, LAsset) then
    raise EStruoError.CreateHintFmt(
      'release %s has no archive for %s', [ARelease.Tag, HostTargetName],
      Format('see %s for what it does have', [ARelease.PageUrl]));

  LStaging := JoinPath(InstallDir, CStagingDirName);
  RemoveTree(LStaging);
  EnsureDir(LStaging);
  try
    LArchive := JoinPath(LStaging, LAsset.Name);

    if LAsset.Size > 0 then
      Status('Downloading', Format('%s (%d MB)',
        [LAsset.Name, (LAsset.Size + 524288) div 1048576]))
    else
      Status('Downloading', LAsset.Name);
    HttpDownload(LAsset.Url, LArchive);

    Status('Unpacking', LAsset.Name);
    ExtractArchive(LArchive, LStaging);
    DeleteFile(LArchive);

    Result := PayloadDir(LStaging);
    if Result = '' then
      raise EStruoError.CreateHintFmt(
        '`%s` does not look like a Struo release archive', [LAsset.Name],
        'nothing was changed');

    { The gate. Everything up to here is undone by deleting one directory;
      everything after it touches the installation. }
    Status('Verifying', 'the downloaded binary');
    VerifyStagedBinary(Result, ARelease.Version);
  except
    DiscardStaged;
    raise;
  end;
end;

procedure CommitStaged(const APayloadDir: string; const ARelease: TReleaseInfo);
begin
  Status('Installing', Format('struo %s over %s',
    [SemVerToStr(ARelease.Version), CStruoVersion]));
  try
    SwapIn(APayloadDir);
  finally
    DiscardStaged;
  end;

  Status('Finished', Format('struo %s is installed in `%s`',
    [SemVerToStr(ARelease.Version), InstallDir]));
end;

procedure InstallRelease(const ARelease: TReleaseInfo);
begin
  CommitStaged(StageRelease(ARelease), ARelease);
end;

procedure CleanUpAfterUpdate;
var
  LQuarantine: string;
begin
  LQuarantine := JoinPath(InstallDir, CQuarantineDirName);
  if not PathIsDir(LQuarantine) then
    Exit;

  { It holds the binary that was running when the update happened, so this is
    the first moment it can go. A failure means another Struo is running; the
    next run will get it. }
  if RemoveTree(LQuarantine) then
    TraceFmt('removed `%s`, left by an earlier update', [LQuarantine])
  else
    TraceFmt('`%s` is still in use; it will go next time', [LQuarantine]);
end;

{ ---- the update notice --------------------------------------------------- }

function CachePath: string;
begin
  Result := JoinPath(StruoHome, CCacheFileName);
end;

{ Reads the cache. Returns False when it is absent, unreadable or stale. }
function ReadCache(out ALatest: string): Boolean;
var
  LDocument: TTomlValue;
  LCheckedAt: Int64;
begin
  ALatest := '';
  Result := False;
  if not PathIsFile(CachePath) then
    Exit;

  try
    LDocument := ParseTomlFile(CachePath);
  except
    { A corrupt cache is not worth reporting; it will be overwritten. }
    on Exception do
      Exit;
  end;

  try
    LCheckedAt := LDocument.IntegerOr('checked-at', 0);
    ALatest := LDocument.StringOr('latest', '');
    Result := (DateTimeToUnix(Now, False) - LCheckedAt) < CCheckIntervalSeconds;
  finally
    LDocument.Free;
  end;
end;

procedure WriteCache(const ALatest: string);
var
  LDocument: TTomlValue;
begin
  LDocument := TTomlValue.NewTable;
  try
    LDocument.Put('checked-at',
      TTomlValue.NewInteger(DateTimeToUnix(Now, False)));
    LDocument.Put('latest', TTomlValue.NewString(ALatest));
    try
      WriteTextFile(CachePath,
        '# Written by Struo. Records when it last looked for an update.' +
        LineEnding +
        '# Delete this file, or set STRUO_NO_UPDATE_CHECK=1, to stop the check.' +
        LineEnding + WriteToml(LDocument));
    except
      { An unwritable home means the check runs every time instead of once a
        day. That is a shame, not a failure worth reporting. }
      on EFsError do
        TraceFmt('could not write `%s`', [CachePath]);
    end;
  finally
    LDocument.Free;
  end;
end;

function UpdateCheckAllowed: Boolean;
var
  LReason: string;
begin
  { An opt-out that works whatever its value, as such variables should. }
  if SysUtils.GetEnvironmentVariable('STRUO_NO_UPDATE_CHECK') <> '' then
    Exit(False);

  { Nobody is reading: a script or a CI job must never be told about a new
    release, and must never pay for the request. }
  if (Verbosity = vbQuiet) or not ColorEnabled then
    Exit(False);

  { Nothing to offer someone who cannot act on it. }
  Result := CanSelfUpdate(LReason);
end;

function PendingUpdateTag: string;
var
  LCached, LBare: string;
  LRelease: TReleaseInfo;
  LVersion: TSemVer;
begin
  Result := '';
  LVersion := Default(TSemVer);
  if not UpdateCheckAllowed then
    Exit;

  if ReadCache(LCached) then
  begin
    { Checked recently: answer from what was found then. }
    LBare := LCached;
    { Only a leading v, so a tag that merely contains one survives. }
    if StartsWithStr(LowerCase(LBare), 'v') then
      Delete(LBare, 1, 1);

    if (LBare <> '') and TryParseSemVer(LBare, LVersion) and
       (CompareSemVer(LVersion, RunningVersion) > 0) then
      Result := LCached;
    Exit;
  end;

  LRelease := FetchLatestRelease(True);
  if not LRelease.Found then
  begin
    { Record the attempt even when it failed, so an offline machine is not
      asked to retry on every command. }
    WriteCache('');
    Exit;
  end;

  WriteCache(LRelease.Tag);
  if IsUpgrade(LRelease) then
    Result := LRelease.Tag;
end;

end.
