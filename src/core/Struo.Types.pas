{ Struo.Types -- the error types and the constants everything agrees on.

  The core layer raises; it does not print and it does not Halt. That rule is
  what lets `struo build` and a future library embedding of the same code
  report failures differently. EStruoError carries an optional hint because
  the difference between a good command-line tool and an irritating one is
  usually one sentence telling the user what to do next. }
unit Struo.Types;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

const
  { Struo's own version. Bump this in one place. }
  CStruoVersion = '0.1.0';

  { The manifest, the lockfile, and the directory build output goes into. }
  CManifestName = 'Struo.toml';
  CLockfileName = 'Struo.lock';
  CTargetDirName = 'target';

  { The only edition that exists so far. Recorded in every new manifest so
    that a later edition can change defaults without breaking old packages. }
  CCurrentEdition = '2026';

  { Conventional layout, as documented in docs/manifest.md. }
  CSourceDirName = 'src';
  CTestsDirName = 'tests';
  CExamplesDirName = 'examples';
  CBinSubDirName = 'bin';

  { Exit codes. A script needs to tell a build that failed from a command line
    that was wrong, so they differ. }
  CExitOk = 0;
  CExitFailure = 1;
  CExitUsage = 2;

type
  { Every deliberate failure in Struo. The message is lowercase and does not
    end in a full stop, so the CLI can render it as `error: <message>`. }
  EStruoError = class(Exception)
  private
    FHint: string;
  public
    { The message plus a sentence telling the user what to do about it. }
    constructor CreateHint(const AMessage, AHint: string);
    constructor CreateHintFmt(const AFormat: string;
      const AArgs: array of const; const AHint: string);

    { Rendered as `hint: <text>` under the error. Empty when there is nothing
      useful to add; a hint that only restates the error is worse than none. }
    property Hint: string read FHint write FHint;
  end;

  { A malformed command line, as opposed to a command that ran and failed.
    Exits CExitUsage. }
  EStruoUsageError = class(EStruoError);

  { How much a command is allowed to print. }
  TVerbosity = (vbQuiet, vbNormal, vbVerbose);

  { Which build profile a command is working in. The name is also the
    subdirectory under target/. }
  TBuildProfile = (bpDebug, bpRelease);

function ProfileName(AProfile: TBuildProfile): string;
function TryParseProfileName(const AText: string; out AProfile: TBuildProfile): Boolean;

implementation

constructor EStruoError.CreateHint(const AMessage, AHint: string);
begin
  inherited Create(AMessage);
  FHint := AHint;
end;

constructor EStruoError.CreateHintFmt(const AFormat: string;
  const AArgs: array of const; const AHint: string);
begin
  CreateHint(Format(AFormat, AArgs), AHint);
end;

function ProfileName(AProfile: TBuildProfile): string;
begin
  case AProfile of
    bpRelease: Result := 'release';
  else
    Result := 'debug';
  end;
end;

function TryParseProfileName(const AText: string; out AProfile: TBuildProfile): Boolean;
begin
  Result := True;
  if AText = 'debug' then
    AProfile := bpDebug
  else if AText = 'release' then
    AProfile := bpRelease
  else
  begin
    AProfile := bpDebug;
    Result := False;
  end;
end;

end.
