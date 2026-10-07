{ Struo.Cmd.SelfUpdate -- `struo self-update`, and the notice that mentions it.

  The command is named self-update rather than update because `struo update`
  already means something: re-resolving a package's dependencies. Conflating
  the two would make `struo update` in a project directory ambiguous between
  two very different actions, one of which replaces the user's tooling.

  The notice is the other half. It is one line, it appears at most once a day,
  and it never appears for a script, a CI job or a build command -- a compile
  that waited on github.com would be a bad trade for news nobody asked for. }
unit Struo.Cmd.SelfUpdate;

{$mode objfpc}{$H+}

interface

uses
  Struo.Util.Strings;

function RunSelfUpdate(const AArgv: TStrArray): Integer;

{ Prints one line when a newer release exists. ACommand is the command that
  just finished; the notice only follows those where a brief network call
  cannot be felt. Silent on every failure. }
procedure OfferUpdateNotice(const ACommand: string);

implementation

uses
  SysUtils, Struo.Types, Struo.SemVer, Struo.Net, Struo.Release,
  Struo.SelfUpdate, Struo.Cli.Args, Struo.Cli.Output, Struo.Cli.Command;

const
  { Commands a one-line notice may follow. The build loop is deliberately
    absent: `struo build` must never wait on the network, and someone running
    it in a loop does not want the news eleven times. }
  CNoticeAfter: array[0 .. 8] of string = (
    'new', 'init', 'add', 'remove', 'update', 'tree', 'clean', 'doctor',
    'toolchain'
  );

  { How much of a release body to show before pointing at the page. Long
    enough for a summary line, short enough not to fill the terminal. }
  CNotesExcerpt = 400;

{ ---- the notice ---------------------------------------------------------- }

procedure OfferUpdateNotice(const ACommand: string);
var
  LTag: string;
begin
  if not StrArrayHas(CNoticeAfter, LowerCase(ACommand)) then
    Exit;

  { Everything that could go wrong -- no network, no release, checked an hour
    ago, opted out -- comes back as an empty string. }
  LTag := PendingUpdateTag;
  if LTag = '' then
    Exit;

  Note('Update', Format('struo %s is available (you have %s). Run `struo ' +
                        'self-update` to install it.', [LTag, CStruoVersion]));
end;

{ ---- the command --------------------------------------------------------- }

{ Prints what a release is, before installing it. }
procedure DescribeRelease(const ARelease: TReleaseInfo);
var
  LNotes: string;
begin
  Note('Release', Format('%s, published %s',
    [ARelease.Tag, Copy(ARelease.PublishedAt, 1, 10)]));
  if ARelease.PageUrl <> '' then
    Note('Notes', ARelease.PageUrl);

  LNotes := Trim(ARelease.Notes);
  if LNotes = '' then
    Exit;

  SayBlank;
  { Release notes are text somebody wrote for people, so they are shown as
    they are rather than reformatted, and truncated rather than wrapped. }
  Say(IndentStr(EllipsizeStr(LNotes, CNotesExcerpt), '    '));
  SayBlank;
end;

function RunSelfUpdate(const AArgv: TStrArray): Integer;
var
  LCommandLine: TCommandLine;
  LRelease: TReleaseInfo;
  LAsset: TReleaseAsset;
  LReason, LWanted: string;
begin
  LCommandLine := TCommandLine.Create('self-update');
  try
    LCommandLine.AddFlag('check', '',
      'Report whether an update exists, install nothing');
    LCommandLine.AddValue('version', '', 'tag',
      'Install this release instead of the latest');
    LCommandLine.AddFlag('force', '',
      'Reinstall even when the version is already current');
    LCommandLine.AddFlag('dry-run', '',
      'Download and verify the update, then install nothing');
    LCommandLine.AddGlobalOptions;
    LCommandLine.Parse(AArgv);

    if LCommandLine.Flag('help') then
    begin
      PrintCommandHelp('self-update', '[options]',
        'Replace Struo with the latest release from GitHub.' + LineEnding +
        'Named self-update because `struo update` re-resolves a package''s ' +
        'dependencies.' + LineEnding +
        '--dry-run downloads and verifies the update without installing it.' +
        LineEnding +
        'Set STRUO_NO_UPDATE_CHECK=1 to silence the daily notice.',
        LCommandLine);
      Exit(CExitOk);
    end;
    ApplyGlobalOptions(LCommandLine);

    { --check answers the question without needing to be able to act, which
      is the one useful thing to do on a build from source. }
    if not LCommandLine.Flag('check') then
      if not CanSelfUpdate(LReason) then
        raise EStruoError.CreateHint('Struo cannot update itself here', LReason);

    if not HasHttpClient then
      raise EStruoError.CreateHint('no HTTP client found',
        'Struo uses curl to reach GitHub; install curl, or wget, and put it ' +
        'on your PATH');

    LWanted := LCommandLine.Value('version', '');
    Note('Checking', Format('github.com/%s', [UpdateRepository]));

    if LWanted <> '' then
      LRelease := FetchRelease(LWanted)
    else
      LRelease := FetchLatestRelease(False);

    if not LRelease.Found then
    begin
      { For --check, `there are no releases` is a complete answer to the
        question asked, so it succeeds: a script running it wants to know
        whether to update, and the answer is no. }
      if LCommandLine.Flag('check') then
      begin
        Status('Up to date', Format('`%s` has published no releases yet',
          [UpdateRepository]));
        Exit(CExitOk);
      end;
      raise EStruoError.CreateHintFmt(
        '`%s` has published no releases yet', [UpdateRepository],
        'this Struo is as new as there is');
    end;

    { Report before acting, so --check and a real run agree about the facts. }
    if (not LCommandLine.Flag('force')) and (LWanted = '') and
       not IsUpgrade(LRelease) then
    begin
      Status('Up to date', Format('struo %s is the latest release',
        [CStruoVersion]));
      Exit(CExitOk);
    end;

    if LCommandLine.Flag('check') then
    begin
      Status('Available', Format('struo %s (you have %s)',
        [SemVerToStr(LRelease.Version), CStruoVersion]));
      if not FindHostAsset(LRelease, LAsset) then
        Warn(Format('that release has no archive for %s, so it cannot be ' +
                    'installed here', [HostTargetName]));
      { Still a success: the question was answered. A script wanting an exit
        code for `is there an update` can compare `struo --version` instead. }
      Exit(CExitOk);
    end;

    DescribeRelease(LRelease);

    if LCommandLine.Flag('dry-run') then
    begin
      { Everything a real update does except the swap: the archive is
        downloaded, unpacked and the binary inside it is run and checked. It
        answers `would this work on my machine` without betting the
        installation on the answer. }
      StageRelease(LRelease);
      DiscardStaged;
      Status('Dry run', Format(
        'struo %s downloaded and verified; nothing was installed',
        [SemVerToStr(LRelease.Version)]));
      Exit(CExitOk);
    end;

    InstallRelease(LRelease);
    Result := CExitOk;
  finally
    LCommandLine.Free;
  end;
end;

end.
