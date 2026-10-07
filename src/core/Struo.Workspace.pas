{ Struo.Workspace -- finding the package a command should act on.

  Every command starts here. Struo searches upward from the working directory
  for Struo.toml, which is what lets `struo build` work from `src/` or from a
  test directory three levels down, exactly as git works from anywhere inside
  a repository. }
unit Struo.Workspace;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Types, Struo.Manifest;

{ The manifest to use. AExplicitPath comes from --manifest-path and wins when
  it is not empty; it may name either the file or the directory holding it.
  Otherwise the search walks up from the working directory.

  Raises EStruoError when there is nothing to find, with the hint a user in
  the wrong directory needs. }
function DiscoverManifestPath(const AExplicitPath: string): string;

{ As DiscoverManifestPath, but returns '' instead of raising. For `struo
  doctor` and for `struo init`, which must know whether a manifest is already
  there without treating its absence as a failure. }
function TryDiscoverManifestPath(const AExplicitPath: string): string;

{ The whole opening sequence: discover, load, validate, infer targets,
  validate the targets. The caller owns the result and must free it. }
function OpenPackage(const AExplicitPath: string): TManifest;

{ As OpenPackage but without target inference or validation, for commands
  that only read or rewrite the manifest -- `struo add` has no business
  failing because the source tree is empty. }
function OpenManifestOnly(const AExplicitPath: string): TManifest;

implementation

uses
  Struo.Util.Fs, Struo.Paths, Struo.Targets, Struo.Cli.Output;

function TryDiscoverManifestPath(const AExplicitPath: string): string;
var
  LCandidate: string;
begin
  if AExplicitPath <> '' then
  begin
    LCandidate := AbsolutePath(AExplicitPath, CurrentDir);
    { Accept a directory as well as a file: `--manifest-path ../other` is a
      natural thing to type and unambiguous. }
    if PathIsDir(LCandidate) then
      LCandidate := JoinPath(LCandidate, CManifestName);
    if PathIsFile(LCandidate) then
      Exit(NormalizePath(LCandidate));
    Exit('');
  end;

  Result := FindUpwards(CurrentDir, CManifestName);
end;

function DiscoverManifestPath(const AExplicitPath: string): string;
begin
  Result := TryDiscoverManifestPath(AExplicitPath);
  if Result <> '' then
    Exit;

  if AExplicitPath <> '' then
    raise EStruoError.CreateHintFmt('no %s at `%s`',
      [CManifestName, AExplicitPath],
      '--manifest-path takes the manifest file or the directory holding it');

  raise EStruoError.CreateHintFmt(
    'could not find %s in `%s` or any parent directory',
    [CManifestName, CurrentDir],
    'run `struo new <name>` to start a package, or `struo init` to turn this ' +
    'directory into one');
end;

function OpenManifestOnly(const AExplicitPath: string): TManifest;
var
  LPath: string;
begin
  LPath := DiscoverManifestPath(AExplicitPath);
  Result := TManifest.Load(LPath);
  TraceFmt('manifest %s', [LPath]);
end;

function OpenPackage(const AExplicitPath: string): TManifest;
begin
  Result := OpenManifestOnly(AExplicitPath);
  try
    InferTargets(Result);
    ValidateTargets(Result);
  except
    Result.Free;
    raise;
  end;
end;

end.
