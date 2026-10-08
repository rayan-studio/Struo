{ Struo.Net -- fetching things over HTTPS, and unpacking them.

  Struo shells out rather than linking an HTTP client, for the same reason it
  shells out to git: Free Pascal can speak TLS through fphttpclient, but only
  with the right OpenSSL libraries present, which on Windows means shipping
  DLLs and then debugging which pair a given machine has. Meanwhile curl has
  been in C:\Windows\System32 since Windows 10 1803 and is on every Unix that
  matters, and it already handles proxies, corporate certificate stores and
  redirects the way the user's other tools do.

  Unpacking goes the same way. bsdtar, which is tar.exe on Windows, reads zip
  archives as happily as tarballs, so one `tar -xf` serves both platforms.
  That is why a Struo release ships .zip for Windows and .tar.gz for Unix:
  each is what the local tar can already open.

  Which tar, on Windows, is not a question PATH answers correctly -- see
  ArchiveToolPath. }
unit Struo.Net;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings, Struo.Types;

const
  { Long enough for a slow link, short enough that a hung proxy does not
    look like a hung Struo. }
  CDefaultTimeout = 30;

  { The update check runs while the user waits, so it gets a budget that
    cannot be felt rather than one that cannot fail. }
  CQuickTimeout = 3;

{ True when Struo found something that can fetch a URL. }
function HasHttpClient: Boolean;

{ 'curl (C:\Windows\System32\curl.exe)', for `struo doctor`. }
function HttpClientName: string;

{ GETs AUrl and returns the body. Raises EStruoError, with the client's own
  message, on any failure including a non-2xx status. }
function HttpGetText(const AUrl: string; ATimeoutSeconds: Integer = CDefaultTimeout): string;

{ As HttpGetText, but returns False instead of raising. For the update check,
  which must never turn a working command into a failed one because the
  network was down. }
function TryHttpGetText(const AUrl: string; ATimeoutSeconds: Integer;
  out AText: string): Boolean;

{ GETs AUrl and reports the HTTP status alongside the body, so a caller can
  tell `there is no such thing` from `there is no network`. GitHub answers
  `no releases yet` with a 404, which is an answer rather than a failure.

  Returns False when the request could not be made at all. AStatus is 0 when
  the client cannot report one, which happens only with wget or PowerShell;
  curl is asked for the code directly. }
function HttpGetStatus(const AUrl: string; ATimeoutSeconds: Integer;
  out AStatus: Integer; out ABody: string): Boolean;

{ True when the HTTP client in use can report a status code. }
function HttpReportsStatus: Boolean;

{ Downloads AUrl to APath, creating its directory. Raises on failure, and
  leaves no partial file behind. }
procedure HttpDownload(const AUrl, APath: string;
  ATimeoutSeconds: Integer = CDefaultTimeout);

{ The tar Struo unpacks with, as a full path, or '' when there is none. }
function ArchiveToolPath: string;

{ Unpacks a .zip or .tar.gz into ADestination, which is created if missing.
  Raises EStruoError naming the archive on failure. }
procedure ExtractArchive(const AArchive, ADestination: string);

implementation

uses
  Struo.Util.Fs, Struo.Util.Proc, Struo.Cli.Output;

{ ---- client discovery ---------------------------------------------------- }

type
  TClientKind = (ckNone, ckCurl, ckWget, ckPowerShell);

var
  GClientKind: TClientKind = ckNone;
  GClientPath: string = '';
  GClientResolved: Boolean = False;

procedure ResolveClient;
begin
  if GClientResolved then
    Exit;
  GClientResolved := True;

  { curl first: present on Windows 10 and later, and on practically every
    Unix, and it behaves the same on both. }
  GClientPath := FindExecutable('curl');
  if GClientPath <> '' then
  begin
    GClientKind := ckCurl;
    Exit;
  end;

  GClientPath := FindExecutable('wget');
  if GClientPath <> '' then
  begin
    GClientKind := ckWget;
    Exit;
  end;

  {$IFDEF WINDOWS}
  { Last resort on an older Windows: PowerShell is always there, just slower
    to start and clumsier to drive. }
  GClientPath := FindExecutable('powershell');
  if GClientPath <> '' then
  begin
    GClientKind := ckPowerShell;
    Exit;
  end;
  {$ENDIF}

  GClientKind := ckNone;
end;

function HasHttpClient: Boolean;
begin
  ResolveClient;
  Result := GClientKind <> ckNone;
end;

function HttpClientName: string;
begin
  ResolveClient;
  case GClientKind of
    ckCurl:       Result := 'curl (' + GClientPath + ')';
    ckWget:       Result := 'wget (' + GClientPath + ')';
    ckPowerShell: Result := 'powershell (' + GClientPath + ')';
  else
    Result := 'none found';
  end;
end;

procedure RequireClient;
begin
  if HasHttpClient then
    Exit;
  raise EStruoError.CreateHint('no HTTP client found',
    'Struo uses curl to reach the network; install curl, or wget, and put it ' +
    'on your PATH');
end;

{ ---- requests ------------------------------------------------------------ }

{ The argument list for a GET. ATarget is '' for a body-to-stdout request, or
  a path to save into. }
function GetArguments(const AUrl, ATarget: string;
  ATimeoutSeconds: Integer): TStrArray;
begin
  Result := nil;
  case GClientKind of
    ckCurl:
      begin
        { -sS: quiet, but still report errors. --fail: a 404 is a failure,
          not a body saying `Not Found`. -L: follow the redirect GitHub uses
          for release downloads. }
        StrArrayAddAll(Result, ['-sS', '--fail', '-L',
          '--max-time', IntToStr(ATimeoutSeconds)]);
        { GitHub rejects requests without a user agent. }
        StrArrayAddAll(Result, ['-A', 'struo/' + CStruoVersion]);
        if ATarget <> '' then
          StrArrayAddAll(Result, ['-o', ATarget]);
        StrArrayAdd(Result, AUrl);
      end;
    ckWget:
      begin
        StrArrayAddAll(Result, ['-q',
          '--timeout=' + IntToStr(ATimeoutSeconds),
          '--user-agent=struo/' + CStruoVersion]);
        if ATarget = '' then
          StrArrayAddAll(Result, ['-O', '-'])
        else
          StrArrayAddAll(Result, ['-O', ATarget]);
        StrArrayAdd(Result, AUrl);
      end;
    ckPowerShell:
      begin
        StrArrayAddAll(Result, ['-NoProfile', '-NonInteractive', '-Command']);
        if ATarget = '' then
          StrArrayAdd(Result, Format(
            '[Net.ServicePointManager]::SecurityProtocol = ''Tls12''; ' +
            '(Invoke-WebRequest -UseBasicParsing -TimeoutSec %d ' +
            '-UserAgent ''struo/%s'' -Uri ''%s'').Content',
            [ATimeoutSeconds, CStruoVersion, AUrl]))
        else
          StrArrayAdd(Result, Format(
            '[Net.ServicePointManager]::SecurityProtocol = ''Tls12''; ' +
            'Invoke-WebRequest -UseBasicParsing -TimeoutSec %d ' +
            '-UserAgent ''struo/%s'' -Uri ''%s'' -OutFile ''%s''',
            [ATimeoutSeconds, CStruoVersion, AUrl, ATarget]));
      end;
  end;
end;

function TryHttpGetText(const AUrl: string; ATimeoutSeconds: Integer;
  out AText: string): Boolean;
var
  LOutcome: TProcOutcome;
begin
  AText := '';
  ResolveClient;
  if GClientKind = ckNone then
    Exit(False);

  LOutcome := RunCaptured(GClientPath,
    GetArguments(AUrl, '', ATimeoutSeconds), '');
  Result := LOutcome.Spawned and (LOutcome.ExitCode = 0);
  if Result then
    AText := LOutcome.Output
  else
    TraceFmt('GET %s failed: %s', [AUrl, Trim(LOutcome.Output)]);
end;

function HttpReportsStatus: Boolean;
begin
  ResolveClient;
  Result := GClientKind = ckCurl;
end;

function HttpGetStatus(const AUrl: string; ATimeoutSeconds: Integer;
  out AStatus: Integer; out ABody: string): Boolean;
var
  LOutcome: TProcOutcome;
  LArgs: TStrArray;
  LBreak: Integer;
  LCode: string;
begin
  AStatus := 0;
  ABody := '';
  ResolveClient;
  if GClientKind = ckNone then
    Exit(False);

  if GClientKind <> ckCurl then
  begin
    { No way to ask the others for a code without parsing their chatter, so
      the caller is told the status is unknown. }
    Result := TryHttpGetText(AUrl, ATimeoutSeconds, ABody);
    Exit;
  end;

  { Without --fail, curl returns the body for an error status too, and -w
    appends the code on a line of its own so it can be split off. }
  LArgs := nil;
  StrArrayAddAll(LArgs, ['-sS', '-L', '--max-time', IntToStr(ATimeoutSeconds),
    '-A', 'struo/' + CStruoVersion, '-w', #10 + '%{http_code}', AUrl]);

  TraceFmt('GET %s', [AUrl]);
  LOutcome := RunCaptured(GClientPath, LArgs, '');
  if not LOutcome.Spawned then
    Exit(False);

  ABody := LOutcome.Output;
  LBreak := Length(ABody);
  while (LBreak > 0) and (ABody[LBreak] <> #10) do
    Dec(LBreak);
  if LBreak = 0 then
    { No code came back, so curl failed before the response. }
    Exit(LOutcome.ExitCode = 0);

  LCode := Trim(Copy(ABody, LBreak + 1, MaxInt));
  ABody := Copy(ABody, 1, LBreak - 1);
  if not TryStrToInt(LCode, AStatus) then
    AStatus := 0;

  TraceFmt('  -> HTTP %d, %d bytes', [AStatus, Length(ABody)]);
  Result := True;
end;

function HttpGetText(const AUrl: string; ATimeoutSeconds: Integer): string;
var
  LOutcome: TProcOutcome;
begin
  RequireClient;
  TraceFmt('GET %s', [AUrl]);

  LOutcome := RunCaptured(GClientPath,
    GetArguments(AUrl, '', ATimeoutSeconds), '');

  if not LOutcome.Spawned then
    raise EStruoError.CreateHintFmt('could not run `%s`', [GClientPath],
      Trim(LOutcome.Output));

  if LOutcome.ExitCode <> 0 then
    raise EStruoError.CreateHintFmt('could not fetch `%s`', [AUrl],
      Trim(LOutcome.Output));

  Result := LOutcome.Output;
end;

procedure HttpDownload(const AUrl, APath: string; ATimeoutSeconds: Integer);
var
  LOutcome: TProcOutcome;
  LTemp: string;
begin
  RequireClient;
  EnsureDir(PathWithoutTrailingSep(ExtractFilePath(ExpandFileName(APath))));

  { Download beside the target and rename, so an interrupted transfer cannot
    leave something that looks like a finished archive. }
  LTemp := APath + '.part';
  if PathIsFile(LTemp) then
    DeleteFile(LTemp);

  TraceFmt('GET %s -> %s', [AUrl, APath]);
  LOutcome := RunCaptured(GClientPath,
    GetArguments(AUrl, LTemp, ATimeoutSeconds), '');

  if not LOutcome.Spawned then
  begin
    DeleteFile(LTemp);
    raise EStruoError.CreateHintFmt('could not run `%s`', [GClientPath],
      Trim(LOutcome.Output));
  end;

  if (LOutcome.ExitCode <> 0) or not PathIsFile(LTemp) then
  begin
    DeleteFile(LTemp);
    raise EStruoError.CreateHintFmt('could not download `%s`', [AUrl],
      Trim(LOutcome.Output));
  end;

  if PathIsFile(APath) then
    DeleteFile(APath);
  if not RenameFile(LTemp, APath) then
  begin
    DeleteFile(LTemp);
    raise EStruoError.CreateHintFmt('could not save the download to `%s`',
      [APath], '');
  end;
end;

{ ---- unpacking ----------------------------------------------------------- }

{ ---- unpacking ----------------------------------------------------------- }

var
  GTarPath: string = '';
  GTarResolved: Boolean = False;

function ArchiveToolPath: string;
{$IFDEF WINDOWS}
var
  LRoot: string;
{$ENDIF}
begin
  if not GTarResolved then
  begin
    GTarResolved := True;

    {$IFDEF WINDOWS}
    { Deliberately not whatever PATH offers first. Git for Windows ships GNU
      tar in its own bin directory, and GNU tar cannot read a zip: handed the
      archive a Windows release actually ships, it answers `This does not look
      like a tar archive` and stops. Anyone running Struo from Git Bash has
      that tar ahead of the one that works, and self-update is exactly where
      they would find out.

      The tar.exe in System32 is bsdtar and reads zip and tar.gz alike, so ask
      for it by name. A 32-bit Struo is redirected to SysWOW64, which carries
      an equally capable bsdtar, and the PATH lookup remains the fallback for
      a Windows too old to ship either. }
    LRoot := GetEnvironmentVariable('SystemRoot');
    if LRoot = '' then
      LRoot := 'C:\Windows';

    GTarPath := JoinPaths([LRoot, 'System32', 'tar.exe']);
    if PathIsFile(GTarPath) then
      GTarPath := NormalizePath(GTarPath)
    else
      GTarPath := FindExecutable('tar');
    {$ELSE}
    { Every Unix tar reads the .tar.gz a Unix release ships. }
    GTarPath := FindExecutable('tar');
    {$ENDIF}
  end;
  Result := GTarPath;
end;

procedure ExtractArchive(const AArchive, ADestination: string);
var
  LTar: string;
  LOutcome: TProcOutcome;
begin
  if not PathIsFile(AArchive) then
    raise EStruoError.CreateHintFmt('no archive at `%s`', [AArchive], '');

  LTar := ArchiveToolPath;
  if LTar = '' then
    raise EStruoError.CreateHint('tar was not found',
      'Struo uses tar to unpack archives; it ships with Windows 10 and later ' +
      'and with every Unix, so a missing one usually means a trimmed PATH');

  EnsureDir(ADestination);

  { bsdtar, which is what tar.exe on Windows is, reads zip as well as
    tar.gz, so one invocation covers both kinds of release asset. }
  TraceFmt('tar -xf %s -C %s', [AArchive, ADestination]);
  LOutcome := RunCaptured(LTar, ['-xf', AArchive, '-C', ADestination], '');

  if (not LOutcome.Spawned) or (LOutcome.ExitCode <> 0) then
    raise EStruoError.CreateHintFmt('could not unpack `%s`', [AArchive],
      Trim(LOutcome.Output));
end;

end.
