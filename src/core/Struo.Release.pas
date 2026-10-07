{ Struo.Release -- what versions of Struo exist, according to GitHub.

  Everything this unit returns came off the network, so it is data and never
  instruction. Two checks matter and are easy to lose sight of:

  * A tag only counts when it parses as a version. A release called
    `nightly-latest` cannot be compared against the running Struo, so it is
    ignored rather than guessed at.

  * An asset's download URL must live under the repository Struo updates
    from. GitHub would not serve anything else, but a self-updater that
    follows whatever URL a JSON body hands it is one compromised response
    away from installing somebody else's binary, and the check costs a line. }
unit Struo.Release;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings, Struo.Types, Struo.SemVer;

type
  TReleaseAsset = record
    Name: string;
    Url: string;
    Size: Int64;
  end;

  TReleaseAssetArray = array of TReleaseAsset;

  TReleaseInfo = record
    { False when there is no such release, which is the normal answer for a
      repository that has not published one yet. }
    Found: Boolean;
    { 'v0.2.0' as GitHub stores it. }
    Tag: string;
    { The same thing parsed, which is what gets compared. }
    Version: TSemVer;
    Title: string;
    { The release body, shown to the user before they update. }
    Notes: string;
    PageUrl: string;
    PublishedAt: string;
    Assets: TReleaseAssetArray;
  end;

{ The repository Struo updates itself from, as `owner/name`. Overridable with
  STRUO_UPDATE_REPO so a fork, or a test, can point elsewhere. }
function UpdateRepository: string;

{ The target triple naming this build's assets, such as 'x86_64-win64'.
  Resolved at compile time from the compiler's own target, so it cannot drift
  from what the packaging scripts name the archives. }
function HostTargetName: string;

{ The archive extension this platform's asset uses: '.zip' on Windows,
  '.tar.gz' elsewhere, each being what the local tar can already open. }
function HostArchiveExtension: string;

{ 'struo-0.2.0-x86_64-win64.zip': the asset name a release should carry for
  this host. }
function HostAssetName(const AVersion: TSemVer): string;

{ Reads a GitHub release reply. Exposed apart from fetching so that the
  parsing -- the URL check above all -- can be tested without a network, and
  so that a malformed reply is handled in one place. Returns Found False for
  anything it cannot use, and never raises: every byte here came off the
  network. }
function ParseReleaseJson(const ABody: string): TReleaseInfo;

{ The latest published release. AQuick uses the short timeout and returns
  Found False on any failure, for the update check; otherwise failures raise. }
function FetchLatestRelease(AQuick: Boolean): TReleaseInfo;

{ A specific tag, with or without the leading 'v'. }
function FetchRelease(const ATag: string): TReleaseInfo;

{ The asset this host should install. False when the release has none, which
  means that platform was not built for this version. }
function FindHostAsset(const ARelease: TReleaseInfo;
  out AAsset: TReleaseAsset): Boolean;

{ True when ARelease is a higher version than the running Struo. }
function IsUpgrade(const ARelease: TReleaseInfo): Boolean;

{ The running Struo's version, parsed. }
function RunningVersion: TSemVer;

implementation

uses
  fpjson, jsonparser, Struo.Net, Struo.Cli.Output;

const
  { Where releases live unless STRUO_UPDATE_REPO says otherwise. }
  CDefaultRepository = 'rayan-studio/Struo';

  { Compile-time target, the same strings fpc reports for -iTP and -iTO. }
  CHostCpu = {$I %FPCTARGETCPU%};
  CHostOS = {$I %FPCTARGETOS%};

function UpdateRepository: string;
begin
  Result := Trim(SysUtils.GetEnvironmentVariable('STRUO_UPDATE_REPO'));
  if Result = '' then
    Result := CDefaultRepository;
end;

function HostTargetName: string;
begin
  Result := LowerCase(CHostCpu) + '-' + LowerCase(CHostOS);
end;

function HostArchiveExtension: string;
begin
  {$IFDEF WINDOWS}
  Result := '.zip';
  {$ELSE}
  Result := '.tar.gz';
  {$ENDIF}
end;

function HostAssetName(const AVersion: TSemVer): string;
begin
  Result := Format('struo-%s-%s%s',
    [SemVerToStr(AVersion), HostTargetName, HostArchiveExtension]);
end;

function RunningVersion: TSemVer;
begin
  if not TryParseSemVer(CStruoVersion, Result) then
    Result := Default(TSemVer);
end;

function IsUpgrade(const ARelease: TReleaseInfo): Boolean;
begin
  Result := ARelease.Found and
            (CompareSemVer(ARelease.Version, RunningVersion) > 0);
end;

{ ---- parsing ------------------------------------------------------------- }

{ The prefix every asset of this repository's releases must start with. }
function ExpectedAssetPrefix: string;
begin
  Result := 'https://github.com/' + UpdateRepository + '/releases/download/';
end;

{ Reads a string field, tolerating its absence or a null. }
function ObjectString(AObject: TJSONObject; const AKey: string): string;
var
  LValue: TJSONData;
begin
  Result := '';
  if AObject = nil then
    Exit;
  LValue := AObject.Find(AKey);
  if (LValue = nil) or (LValue.JSONType in [jtNull, jtArray, jtObject]) then
    Exit;
  Result := LValue.AsString;
end;

function ObjectInteger(AObject: TJSONObject; const AKey: string): Int64;
var
  LValue: TJSONData;
begin
  Result := 0;
  if AObject = nil then
    Exit;
  LValue := AObject.Find(AKey);
  if (LValue = nil) or (LValue.JSONType <> jtNumber) then
    Exit;
  Result := LValue.AsInt64;
end;

{ Turns one release object into a TReleaseInfo. Returns Found False when the
  tag is not a version Struo can compare. }
function ParseRelease(AObject: TJSONObject): TReleaseInfo;
var
  LAssets: TJSONArray;
  LEntry: TJSONObject;
  LAsset: TReleaseAsset;
  LTag: string;
  I: Integer;
begin
  Result := Default(TReleaseInfo);
  if AObject = nil then
    Exit;

  Result.Tag := ObjectString(AObject, 'tag_name');
  LTag := Result.Tag;
  { Tags are conventionally v-prefixed; the version inside is what counts. }
  if StartsWithStr(LowerCase(LTag), 'v') then
    Delete(LTag, 1, 1);

  if not TryParseSemVer(LTag, Result.Version) then
  begin
    { A tag such as `nightly` cannot be compared with the running version, so
      there is nothing sensible to do but ignore the release. }
    TraceFmt('ignoring release `%s`: its tag is not a version', [Result.Tag]);
    Exit;
  end;

  Result.Title := ObjectString(AObject, 'name');
  Result.Notes := ObjectString(AObject, 'body');
  Result.PageUrl := ObjectString(AObject, 'html_url');
  Result.PublishedAt := ObjectString(AObject, 'published_at');

  if AObject.Find('assets') is TJSONArray then
  begin
    LAssets := TJSONArray(AObject.Find('assets'));
    for I := 0 to LAssets.Count - 1 do
    begin
      if not (LAssets.Items[I] is TJSONObject) then
        Continue;
      LEntry := TJSONObject(LAssets.Items[I]);

      LAsset.Name := ObjectString(LEntry, 'name');
      LAsset.Url := ObjectString(LEntry, 'browser_download_url');
      LAsset.Size := ObjectInteger(LEntry, 'size');
      if (LAsset.Name = '') or (LAsset.Url = '') then
        Continue;

      { The one check that matters: an asset Struo will download and execute
        has to come from the repository Struo updates from. }
      if not StartsWithStr(LAsset.Url, ExpectedAssetPrefix) then
      begin
        TraceFmt('ignoring asset `%s`: `%s` is outside `%s`',
          [LAsset.Name, LAsset.Url, ExpectedAssetPrefix]);
        Continue;
      end;

      SetLength(Result.Assets, Length(Result.Assets) + 1);
      Result.Assets[High(Result.Assets)] := LAsset;
    end;
  end;

  Result.Found := True;
end;

function ParseReleaseJson(const ABody: string): TReleaseInfo;
var
  LData: TJSONData;
begin
  Result := Default(TReleaseInfo);
  if Trim(ABody) = '' then
    Exit;

  try
    LData := GetJSON(ABody);
  except
    on E: Exception do
    begin
      TraceFmt('the reply was not JSON: %s', [E.Message]);
      Exit;
    end;
  end;

  try
    if not (LData is TJSONObject) then
      Exit;

    { GitHub answers a missing release with an object carrying a message
      rather than with a body that looks like a release. }
    if TJSONObject(LData).Find('tag_name') = nil then
    begin
      TraceFmt('no release: %s', [ObjectString(TJSONObject(LData), 'message')]);
      Exit;
    end;

    Result := ParseRelease(TJSONObject(LData));
  finally
    LData.Free;
  end;
end;

{ ---- fetching ------------------------------------------------------------ }

function FetchFromApi(const APath: string; AQuick: Boolean): TReleaseInfo;
var
  LUrl, LBody: string;
  LStatus: Integer;
begin
  Result := Default(TReleaseInfo);
  LUrl := 'https://api.github.com/repos/' + UpdateRepository + APath;

  if AQuick then
  begin
    { The update check runs while the user waits for a command to finish, so
      a network problem has to be a silent non-answer. }
    if not TryHttpGetText(LUrl, CQuickTimeout, LBody) then
      Exit;
  end
  else
  begin
    if not HttpGetStatus(LUrl, CDefaultTimeout, LStatus, LBody) then
      raise EStruoError.CreateHintFmt('could not reach `%s`', [LUrl],
        'check the network, or set STRUO_UPDATE_REPO to another repository');

    { A repository with no published release answers 404, which is an answer
      and not a failure. Reporting it as one would make `no releases yet` look
      like a broken Struo. }
    if LStatus = 404 then
    begin
      TraceFmt('%s -> HTTP 404, so there is no such release', [LUrl]);
      Exit;
    end;

    if (LStatus >= 400) or ((LStatus = 0) and (Trim(LBody) = '')) then
      raise EStruoError.CreateHintFmt(
        '`%s` answered HTTP %d', [LUrl, LStatus],
        'GitHub limits unauthenticated requests to 60 an hour; if that is ' +
        'the problem, waiting fixes it');
  end;

  Result := ParseReleaseJson(LBody);
end;

function FetchLatestRelease(AQuick: Boolean): TReleaseInfo;
begin
  { /releases/latest skips prereleases and drafts, which is what someone
    running `struo self-update` wants. }
  Result := FetchFromApi('/releases/latest', AQuick);
end;

function FetchRelease(const ATag: string): TReleaseInfo;
var
  LTag: string;
begin
  LTag := Trim(ATag);
  if LTag = '' then
    Exit(FetchLatestRelease(False));

  { Accept `0.2.0` as well as `v0.2.0`: the tag carries the v, but nobody
    types it. }
  if not StartsWithStr(LowerCase(LTag), 'v') then
    LTag := 'v' + LTag;

  Result := FetchFromApi('/releases/tags/' + LTag, False);
  if not Result.Found then
    raise EStruoError.CreateHintFmt('no release tagged `%s`', [LTag],
      Format('see https://github.com/%s/releases for the ones there are',
        [UpdateRepository]));
end;

function FindHostAsset(const ARelease: TReleaseInfo;
  out AAsset: TReleaseAsset): Boolean;
var
  LWanted: string;
  I: Integer;
begin
  AAsset := Default(TReleaseAsset);
  LWanted := HostAssetName(ARelease.Version);

  for I := 0 to High(ARelease.Assets) do
    if SameText(ARelease.Assets[I].Name, LWanted) then
    begin
      AAsset := ARelease.Assets[I];
      Exit(True);
    end;

  { Fall back to a looser match on the target, so a release that names its
    archives slightly differently still updates rather than refusing. }
  for I := 0 to High(ARelease.Assets) do
    if ContainsStr(LowerCase(ARelease.Assets[I].Name), HostTargetName) and
       EndsWithStr(LowerCase(ARelease.Assets[I].Name), HostArchiveExtension) then
    begin
      AAsset := ARelease.Assets[I];
      Exit(True);
    end;

  Result := False;
end;

end.
