{ Exercises the parts of self-update that must be right without a network:
  how a GitHub release reply is read, and which download URLs are accepted.

  The URL check is the reason this suite exists. A self-updater downloads a
  binary and then runs it, so anything that decides *which* binary is security
  relevant, and a test is cheaper than the argument.

  Named for Struo.Release rather than for self-update, and not by accident:
  Windows inspects executable *names* and demands elevation for anything that
  looks like an installer, `update` and `setup` among the words it looks for.
  A test binary called test_selfupdate.exe refuses to run at all, with an
  error about elevation that says nothing about why. }
program test_release;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Struo.Util.Strings,
  Struo.Types,
  Struo.SemVer,
  Struo.Release,
  Struo.Test;

{ The repository the fixtures below pretend to come from. Set before anything
  runs, so the URL check has a known expectation. }
const
  CTestRepo = 'rayan-studio/Struo';

{ A release reply with one asset per platform, as GitHub shapes it. }
function FixtureRelease(const AVersion: string): string;
const
  CBase = 'https://github.com/' + CTestRepo + '/releases/download/';
begin
  Result :=
    '{' +
    '"tag_name": "v' + AVersion + '",' +
    '"name": "Struo ' + AVersion + '",' +
    '"body": "Fixed the thing.",' +
    '"html_url": "https://github.com/' + CTestRepo + '/releases/tag/v' + AVersion + '",' +
    '"published_at": "2026-10-07T09:12:00Z",' +
    '"assets": [' +
      '{"name": "struo-' + AVersion + '-i386-win32.zip",' +
       '"size": 28901234,' +
       '"browser_download_url": "' + CBase + 'v' + AVersion +
         '/struo-' + AVersion + '-i386-win32.zip"},' +
      '{"name": "struo-' + AVersion + '-x86_64-linux.tar.gz",' +
       '"size": 27123456,' +
       '"browser_download_url": "' + CBase + 'v' + AVersion +
         '/struo-' + AVersion + '-x86_64-linux.tar.gz"}' +
    ']}';
end;

{ Struo.Release only exposes fetching, which needs a network, so the parser is
  reached the way the rest of Struo reaches it: through the same entry point,
  with the reply substituted. ParseReleaseJson is the seam. }
procedure TestHostNaming;
var
  LVersion: TSemVer;
begin
  LVersion := ParseSemVer('1.2.3');

  { The asset name has to match what the packaging scripts produce, or an
    update would download nothing. Both derive from the compiler target. }
  Check(ContainsStr(HostAssetName(LVersion), '1.2.3'),
    'the asset name carries the version');
  Check(ContainsStr(HostAssetName(LVersion), HostTargetName),
    'the asset name carries the target');
  Check(EndsWithStr(HostAssetName(LVersion), HostArchiveExtension),
    'the asset name carries the archive extension');

  {$IFDEF WINDOWS}
  CheckEqStr(HostArchiveExtension, '.zip',
    'Windows takes the zip, which its own tar can open');
  {$ELSE}
  CheckEqStr(HostArchiveExtension, '.tar.gz',
    'Unix takes the tarball');
  {$ENDIF}

  { Lowercase on both halves, because the compiler reports the OS capitalised
    and the packaging scripts do not. }
  CheckEqStr(LowerCase(HostTargetName), HostTargetName,
    'the target name is lowercase');
  Check(Pos('-', HostTargetName) > 1, 'the target name is cpu-os');
end;

procedure TestRepositoryDefault;
begin
  { An override exists for forks; without one the default has to be the real
    repository, or self-update would look in the wrong place. The fixtures
    below are built around that default, so a set override would make the
    whole suite meaningless rather than merely fail this one check. }
  if SysUtils.GetEnvironmentVariable('STRUO_UPDATE_REPO') <> '' then
  begin
    WriteLn('  skip  STRUO_UPDATE_REPO is set; unset it to run this suite');
    Halt(0);
  end;

  CheckEqStr(UpdateRepository, CTestRepo,
    'the update repository defaults to the real one');
end;

procedure TestVersionComparison;
var
  LRelease: TReleaseInfo;
begin
  LRelease := Default(TReleaseInfo);
  LRelease.Found := True;

  LRelease.Version := ParseSemVer('99.0.0');
  Check(IsUpgrade(LRelease), 'a higher version is an upgrade');

  LRelease.Version := RunningVersion;
  Check(not IsUpgrade(LRelease), 'the running version is not an upgrade');

  LRelease.Version := ParseSemVer('0.0.1');
  Check(not IsUpgrade(LRelease), 'a lower version is not an upgrade');

  LRelease.Found := False;
  LRelease.Version := ParseSemVer('99.0.0');
  Check(not IsUpgrade(LRelease), 'a release that was not found is not an upgrade');

  CheckEqStr(SemVerToStr(RunningVersion), CStruoVersion,
    'the running version parses from the one constant that holds it');
end;

procedure TestParsesFixture;
var
  LRelease: TReleaseInfo;
  LAsset: TReleaseAsset;
begin
  LRelease := ParseReleaseJson(FixtureRelease('0.9.0'));
  if not LRelease.Found then
  begin
    Failed('a release reply parses', 'Found was False');
    Exit;
  end;

  CheckEqStr(LRelease.Tag, 'v0.9.0', 'the tag is read');
  CheckEqStr(SemVerToStr(LRelease.Version), '0.9.0',
    'the version is parsed out of the v-prefixed tag');
  CheckEqStr(LRelease.Title, 'Struo 0.9.0', 'the title is read');
  CheckEqStr(LRelease.Notes, 'Fixed the thing.', 'the notes are read');
  Check(ContainsStr(LRelease.PageUrl, '/releases/tag/'), 'the page url is read');
  CheckEqStr(Copy(LRelease.PublishedAt, 1, 10), '2026-10-07',
    'the publication date is read');
  CheckEqInt(Length(LRelease.Assets), 2, 'both assets are read');

  Check(FindHostAsset(LRelease, LAsset), 'this host finds its own asset');
  Check(ContainsStr(LAsset.Name, HostTargetName),
    'and it is the one for this target');
  Check(LAsset.Size > 0, 'its size is read, for the download message');
end;

procedure TestRejectsForeignAssetUrl;
var
  LRelease: TReleaseInfo;
  LAsset: TReleaseAsset;
begin
  { The check that matters. An asset whose download URL points somewhere else
    is dropped, so a tampered reply cannot make Struo fetch and execute a
    binary from another host. }
  LRelease := ParseReleaseJson(
    '{"tag_name": "v9.9.9", "assets": [' +
    '{"name": "struo-9.9.9-' + HostTargetName + HostArchiveExtension + '",' +
    ' "size": 1,' +
    ' "browser_download_url": "https://example.invalid/evil' +
       HostArchiveExtension + '"}' +
    ']}');

  Check(LRelease.Found, 'the release itself still parses');
  CheckEqInt(Length(LRelease.Assets), 0,
    'an asset hosted outside the repository is dropped');
  Check(not FindHostAsset(LRelease, LAsset),
    'so there is nothing for this host to install');
end;

procedure TestRejectsLookalikeRepository;
var
  LRelease: TReleaseInfo;
begin
  { A prefix check has to compare the whole repository path. `Struo-evil`
    starts with the same characters as `Struo`, and must not pass. }
  LRelease := ParseReleaseJson(
    '{"tag_name": "v9.9.9", "assets": [' +
    '{"name": "struo-9.9.9-' + HostTargetName + HostArchiveExtension + '",' +
    ' "size": 1,' +
    ' "browser_download_url":' +
      ' "https://github.com/rayan-studio/Struo-evil/releases/download/v9.9.9/x' +
      HostArchiveExtension + '"}' +
    ']}');
  CheckEqInt(Length(LRelease.Assets), 0,
    'a repository whose name merely starts the same is rejected');
end;

procedure TestIgnoresUnversionedTag;
var
  LRelease: TReleaseInfo;
begin
  { A tag Struo cannot compare with its own version is no use: there would be
    no way to know whether installing it is an upgrade. }
  LRelease := ParseReleaseJson('{"tag_name": "nightly", "assets": []}');
  Check(not LRelease.Found, 'a release tagged `nightly` is ignored');

  LRelease := ParseReleaseJson('{"tag_name": "v1.2", "assets": []}');
  Check(not LRelease.Found, 'a partial version in a tag is ignored');

  LRelease := ParseReleaseJson('{"tag_name": "1.2.3", "assets": []}');
  Check(LRelease.Found, 'a tag without the v prefix still works');
end;

procedure TestSurvivesMalformedReplies;
var
  LRelease: TReleaseInfo;
begin
  { Everything here came off the network, so none of it may crash Struo. }
  LRelease := ParseReleaseJson('');
  Check(not LRelease.Found, 'an empty reply is not a release');

  LRelease := ParseReleaseJson('not json at all');
  Check(not LRelease.Found, 'a reply that is not JSON is not a release');

  LRelease := ParseReleaseJson('[]');
  Check(not LRelease.Found, 'an array where an object was expected');

  LRelease := ParseReleaseJson('{"message": "Not Found"}');
  Check(not LRelease.Found, 'GitHub''s not-found object is not a release');

  LRelease := ParseReleaseJson('{"tag_name": "v1.0.0"}');
  Check(LRelease.Found and (Length(LRelease.Assets) = 0),
    'a release with no assets parses, with no assets');

  LRelease := ParseReleaseJson('{"tag_name": "v1.0.0", "assets": "nope"}');
  Check(LRelease.Found and (Length(LRelease.Assets) = 0),
    'assets of the wrong type are ignored rather than fatal');

  LRelease := ParseReleaseJson(
    '{"tag_name": "v1.0.0", "assets": [{"name": null, "size": null}]}');
  Check(LRelease.Found and (Length(LRelease.Assets) = 0),
    'nulls where strings were expected are ignored');

  LRelease := ParseReleaseJson(
    '{"tag_name": "v1.0.0", "body": null, "assets": [1, 2, 3]}');
  Check(LRelease.Found and (Length(LRelease.Assets) = 0),
    'numbers where asset objects were expected are ignored');
end;

procedure TestLooseAssetMatch;
var
  LRelease: TReleaseInfo;
  LAsset: TReleaseAsset;
begin
  { An exact name is preferred, but a release that named its archive slightly
    differently should still update rather than refuse. }
  LRelease := ParseReleaseJson(
    '{"tag_name": "v9.9.9", "assets": [' +
    '{"name": "struo-nightly-' + HostTargetName + HostArchiveExtension + '",' +
    ' "size": 1,' +
    ' "browser_download_url": "https://github.com/' + CTestRepo +
      '/releases/download/v9.9.9/struo-nightly-' + HostTargetName +
      HostArchiveExtension + '"}' +
    ']}');

  Check(FindHostAsset(LRelease, LAsset),
    'an asset named loosely still matches on target and extension');
  Check(ContainsStr(LAsset.Name, HostTargetName), 'and it is the right one');
end;

begin
  Suite('release');
  TestRepositoryDefault;
  TestHostNaming;
  TestVersionComparison;
  TestParsesFixture;
  TestRejectsForeignAssetUrl;
  TestRejectsLookalikeRepository;
  TestIgnoresUnversionedTag;
  TestSurvivesMalformedReplies;
  TestLooseAssetMatch;
  Halt(TestSummary);
end.
