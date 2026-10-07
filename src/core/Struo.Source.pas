{ Struo.Source -- getting a dependency's source onto disk.

  Struo shells out to git rather than speaking HTTPS itself. That is a
  deliberate trade. Free Pascal can do TLS through fphttpclient, but only with
  the right OpenSSL libraries present, which on Windows means shipping DLLs
  and debugging why someone's machine has the wrong pair. git is already
  installed on every machine that will publish a Pascal package, it already
  handles proxies, credential helpers, SSH keys and corporate certificate
  stores, and it is already what the user's `git clone` of the same repository
  would use. Reusing it means a git dependency behaves exactly as the user
  expects on their own network.

  A clone is cached under STRUO_HOME and keyed by url and revision, so ten
  projects depending on the same library clone it once. }
unit Struo.Source;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings, Struo.Types, Struo.Manifest;

{ A stable one-line description of where a package came from, as the lockfile
  records it:

    path+../mylib
    git+https://github.com/x/fcolor#a1b2c3d4
    registry+https://index.struo.dev

  Two resolutions match only when these strings match, which is what lets the
  lockfile notice that a dependency moved. }
function DescribeSource(const ADependency: TDependency; const ARevision: string): string;

{ The directory holding APath dependency's source, resolved against the
  manifest that declared it. Raises EStruoError when it is not a package. }
function ResolvePathSource(const ADependency: TDependency;
  const AParentRoot: string): string;

{ Clones or updates a git dependency and checks out its pin. Returns the
  checkout directory. ARevision receives the resolved commit hash, which is
  what the lockfile pins so that `branch = "main"` stays reproducible. }
function FetchGitSource(const ADependency: TDependency;
  out ARevision: string): string;

{ Raised rather than guessing when a registry dependency is asked for before
  the registry exists. Kept separate so `struo add` can still write the
  manifest entry and say what is missing. }
procedure FailRegistryNotAvailable(const AName: string);

implementation

uses
  Struo.Util.Fs, Struo.Util.Proc, Struo.Paths, Struo.Cli.Output;

{ ---- describing ---------------------------------------------------------- }

function DescribeSource(const ADependency: TDependency; const ARevision: string): string;
begin
  case ADependency.Kind of
    dkPath:
      { Left as written, so a lockfile committed from one machine still
        describes the same relative layout on another. }
      Result := 'path+' + ADependency.Path;
    dkGit:
      begin
        Result := 'git+' + ADependency.GitUrl;
        if ARevision <> '' then
          Result := Result + '#' + ARevision;
      end;
  else
    Result := 'registry+' + ADependency.Name;
  end;
end;

{ ---- path dependencies --------------------------------------------------- }

function ResolvePathSource(const ADependency: TDependency;
  const AParentRoot: string): string;
begin
  Result := AbsolutePath(ADependency.Path, AParentRoot);

  if not PathIsDir(Result) then
    raise EStruoError.CreateHintFmt(
      'path dependency `%s` points at `%s`, which does not exist',
      [ADependency.Name, ADependency.Path],
      'the path is relative to the manifest that declares it');

  if not PathIsFile(JoinPath(Result, CManifestName)) then
    raise EStruoError.CreateHintFmt(
      'path dependency `%s` has no %s in `%s`',
      [ADependency.Name, CManifestName, Result],
      'a path dependency must be a Struo package');
end;

{ ---- git dependencies ---------------------------------------------------- }

{ A filesystem-safe directory name for a clone: the repository's own name
  followed by a short digest of the full url, so two repositories with the
  same name on different hosts cannot collide. }
function CacheSlug(const AUrl: string): string;
var
  LLeaf: string;
  LHash: LongWord;
  I: Integer;
begin
  LLeaf := AUrl;
  while EndsWithStr(LLeaf, '/') or EndsWithStr(LLeaf, '\') do
    SetLength(LLeaf, Length(LLeaf) - 1);
  I := Length(LLeaf);
  while (I > 0) and not (LLeaf[I] in ['/', '\', ':']) do
    Dec(I);
  LLeaf := Copy(LLeaf, I + 1, MaxInt);
  if EndsWithStr(LowerCase(LLeaf), '.git') then
    SetLength(LLeaf, Length(LLeaf) - 4);

  { Keep only characters that are safe in a directory name. }
  for I := Length(LLeaf) downto 1 do
    if not (LLeaf[I] in ['A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_', '.']) then
      Delete(LLeaf, I, 1);
  if LLeaf = '' then
    LLeaf := 'repo';

  { An FNV-1a digest of the url. Not cryptographic: it only has to separate
    two repositories a human gave the same name. }
  LHash := 2166136261;
  for I := 1 to Length(AUrl) do
  begin
    LHash := LHash xor Byte(AUrl[I]);
    LHash := LHash * 16777619;
  end;

  Result := LLeaf + '-' + LowerCase(IntToHex(LHash, 8));
end;

function LocateGit: string;
begin
  Result := FindExecutable('git');
  if Result = '' then
    raise EStruoError.CreateHint('git was not found',
      'Struo uses git to fetch git dependencies; install it and put it on ' +
      'your PATH');
end;

{ Runs git in ADirectory, raising with git's own message on failure. }
function Git(const AGit, ADirectory: string; const AArgs: array of string;
  const AWhat: string): string;
var
  LOutcome: TProcOutcome;
begin
  TraceFmt('%s', [FormatCommand(AGit, AArgs)]);
  LOutcome := RunCaptured(AGit, AArgs, ADirectory);
  if (not LOutcome.Spawned) or (LOutcome.ExitCode <> 0) then
    raise EStruoError.CreateHintFmt('%s failed', [AWhat],
      Trim(LOutcome.Output));
  Result := Trim(LOutcome.Output);
end;

{ As Git, but a non-zero status is an answer rather than a failure. Used to
  ask whether the clone already holds a ref. }
function GitSucceeds(const AGit, ADirectory: string;
  const AArgs: array of string): Boolean;
var
  LOutcome: TProcOutcome;
begin
  LOutcome := RunCaptured(AGit, AArgs, ADirectory);
  Result := LOutcome.Spawned and (LOutcome.ExitCode = 0);
end;

{ True when the clone already has everything the pin needs, so there is
  nothing to fetch.

  This is what keeps a routine build off the network. A commit hash never
  moves, and a tag that is already here is immutable by every convention
  worth honouring, so neither needs refetching. A branch does: following one
  is asking for its tip, and `struo update` is how you get it. }
function PinIsSatisfiedLocally(const AGit, ADirectory: string;
  const ADependency: TDependency): Boolean;
begin
  case ADependency.PinKind of
    gpRev:
      Result := GitSucceeds(AGit, ADirectory,
        ['cat-file', '-e', ADependency.PinValue + '^{commit}']);
    gpTag:
      Result := GitSucceeds(AGit, ADirectory,
        ['rev-parse', '--verify', '--quiet',
         'refs/tags/' + ADependency.PinValue + '^{commit}']);
  else
    { A branch, or no pin at all: the tip is the point. }
    Result := False;
  end;
end;

{ The pin to check out, or '' when the dependency named none. }
function PinRef(const ADependency: TDependency): string;
begin
  case ADependency.PinKind of
    gpBranch, gpTag, gpRev: Result := ADependency.PinValue;
  else
    Result := '';
  end;
end;

function FetchGitSource(const ADependency: TDependency;
  out ARevision: string): string;
var
  LGit, LRef: string;
begin
  ARevision := '';
  LGit := LocateGit;
  EnsureStruoHome;

  Result := JoinPath(GitCacheDir, CacheSlug(ADependency.GitUrl));
  LRef := PinRef(ADependency);

  if not PathIsDir(JoinPath(Result, '.git')) then
  begin
    { A fresh clone. Not shallow: a `rev` pin may name a commit that is not
      the tip, and --depth 1 would not have it. }
    if PathIsDir(Result) then
      RemoveTree(Result);
    EnsureDir(GitCacheDir);
    Status('Cloning', ADependency.GitUrl);
    Git(LGit, GitCacheDir, ['clone', '--quiet', ADependency.GitUrl, Result],
      Format('cloning `%s`', [ADependency.GitUrl]));
  end
  else if not PinIsSatisfiedLocally(LGit, Result, ADependency) then
  begin
    Status('Updating', ADependency.GitUrl);
    Git(LGit, Result, ['fetch', '--quiet', '--tags', 'origin'],
      Format('fetching `%s`', [ADependency.GitUrl]));
  end
  else
    TraceFmt('`%s` is already at %s, so no fetch was needed',
      [ADependency.Name, PinRef(ADependency)]);

  if LRef <> '' then
  begin
    { For a branch, take the remote's version rather than a stale local one. }
    if ADependency.PinKind = gpBranch then
      Git(LGit, Result, ['checkout', '--quiet', '--detach', 'origin/' + LRef],
        Format('checking out branch `%s` of `%s`', [LRef, ADependency.GitUrl]))
    else
      Git(LGit, Result, ['checkout', '--quiet', '--detach', LRef],
        Format('checking out `%s` of `%s`', [LRef, ADependency.GitUrl]));
  end;

  { The resolved commit is what the lockfile pins, so that `branch = "main"`
    builds the same code tomorrow as it does today. }
  ARevision := Git(LGit, Result, ['rev-parse', 'HEAD'],
    Format('reading the revision of `%s`', [ADependency.GitUrl]));

  if not PathIsFile(JoinPath(Result, CManifestName)) then
    raise EStruoError.CreateHintFmt(
      'git dependency `%s` has no %s at its root',
      [ADependency.Name, CManifestName],
      Format('`%s` does not look like a Struo package', [ADependency.GitUrl]));
end;

{ ---- registry ------------------------------------------------------------ }

procedure FailRegistryNotAvailable(const AName: string);
begin
  raise EStruoError.CreateHintFmt(
    'cannot fetch `%s`: the Struo registry is not available yet', [AName],
    'until it is, depend on the package by path or git: ' +
    Format('`struo add %s --git <url>` or `struo add %s --path <dir>`',
      [AName, AName]));
end;

end.
