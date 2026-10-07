{ Struo.Cmd.Toolchain -- `struo toolchain`.

  Struo ships with a Free Pascal installation, so the obvious question when a
  build misbehaves is which compiler actually ran. This command answers it,
  lists the alternatives Struo can see, and with --verify proves the active
  one works by compiling and running a real program.

  That last part matters more for a bundled toolchain than it would for a
  system one. A shipped compiler can arrive truncated by a bad download, or
  stripped of its assembler by an over-eager antivirus, and the failure then
  surfaces as a baffling link error inside the user's own package. Compiling
  three lines of Pascal that nobody wrote turns that into a plain answer. }
unit Struo.Cmd.Toolchain;

{$mode objfpc}{$H+}

interface

uses
  Struo.Util.Strings;

function RunToolchain(const AArgv: TStrArray): Integer;

implementation

uses
  SysUtils, Struo.Types, Struo.Util.Fs, Struo.Util.Proc, Struo.Manifest,
  Struo.Paths, Struo.Compiler, Struo.Cli.Args, Struo.Cli.Output,
  Struo.Cli.Command;

const
  { The program --verify compiles. It uses a packaged unit on purpose: the
    RTL alone would pass even on an installation whose units are missing,
    which is the commonest way a bundled toolchain goes wrong. }
  CProbeSource =
    'program struo_toolchain_probe;' + LineEnding +
    '{$mode objfpc}{$H+}' + LineEnding +
    'uses SysUtils, Classes;' + LineEnding +
    'begin' + LineEnding +
    '  WriteLn(''struo-probe-ok '', TStringList.ClassName);' + LineEnding +
    'end.' + LineEnding;

  CProbeExpected = 'struo-probe-ok TStringList';

{ One line per toolchain, aligned. }
procedure ReportToolchain(const AInfo: TCompilerInfo; AIsActive: Boolean);
var
  LMarker: string;
begin
  if AIsActive then
    LMarker := 'active'
  else
    LMarker := '';
  Say(Format('%s %s %s %s %s',
    [PadRightStr(LMarker, 7),
     PadRightStr('fpc ' + AInfo.Version, 11),
     PadRightStr(AInfo.Target, 14),
     PadRightStr(ToolchainOriginName(AInfo.Origin), 9),
     AInfo.Path]));
end;

{ Compiles and runs CProbeSource with AInfo. Raises EStruoError describing
  what broke. }
procedure VerifyToolchain(const AInfo: TCompilerInfo);
var
  LDir, LSource, LExecutable: string;
  LRequest: TCompileRequest;
  LOutcome: TCompileResult;
  LRun: TProcOutcome;
begin
  RequireCompiler(AInfo);

  LDir := JoinPath(GetTempDir(False),
    'struo-verify-' + IntToStr(Random(1000000)));
  EnsureDir(LDir);
  try
    LSource := JoinPath(LDir, 'struo_toolchain_probe.pas');
    LExecutable := JoinPath(LDir, ExecutableName('struo_toolchain_probe'));
    WriteTextFile(LSource, CProbeSource);

    LRequest := Default(TCompileRequest);
    LRequest.SourceFile := LSource;
    LRequest.OutputFile := LExecutable;
    LRequest.UnitOutputDir := JoinPath(LDir, 'units');
    LRequest.Mode := 'objfpc';
    LRequest.WorkDir := LDir;
    LRequest.Settings := DefaultDebugProfile;
    { Nothing to warn about in three lines, and a warning here would read as
      though the user's code were at fault. }
    LRequest.Settings.Warnings := 'none';

    Status('Verifying', Format('fpc %s (%s)',
      [AInfo.Version, ToolchainOriginName(AInfo.Origin)]));

    LOutcome := Compile(AInfo, LRequest);
    TraceFmt('%s', [LOutcome.Command]);

    if not LOutcome.Success then
    begin
      Diagnostics(LOutcome.Output);
      raise EStruoError.CreateHintFmt(
        'the toolchain at `%s` could not compile a trivial program',
        [AInfo.Path],
        'the installation looks incomplete; its diagnostics are above');
    end;

    { Compiling is not enough: this proves the assembler and the linker ran
      and that the result is a working executable. }
    LRun := RunCaptured(LExecutable, [], LDir);
    if not LRun.Spawned then
      raise EStruoError.CreateHintFmt(
        'the toolchain compiled a program that will not start', [],
        Trim(LRun.Output));
    if Pos(CProbeExpected, LRun.Output) = 0 then
      raise EStruoError.CreateHintFmt(
        'the compiled program printed `%s` instead of `%s`',
        [Trim(LRun.Output), CProbeExpected], '');

    Status('Finished', 'the toolchain compiles, links and runs');
  finally
    RemoveTree(LDir);
  end;
end;

function RunToolchain(const AArgv: TStrArray): Integer;
var
  LCommandLine: TCommandLine;
  LActive: TCompilerInfo;
  LAll: TCompilerInfoArray;
  I: Integer;
begin
  LCommandLine := TCommandLine.Create('toolchain');
  try
    LCommandLine.AddFlag('verify', '',
      'Compile and run a test program with the active toolchain');
    LCommandLine.AddFlag('path', '',
      'Print only the active compiler''s path');
    LCommandLine.AddGlobalOptions;
    LCommandLine.Parse(AArgv);

    if LCommandLine.Flag('help') then
    begin
      PrintCommandHelp('toolchain', '[options]',
        'Report the Free Pascal toolchain Struo is using.' + LineEnding +
        'Struo ships with one; STRUO_FPC or STRUO_TOOLCHAIN override it.',
        LCommandLine);
      Exit(CExitOk);
    end;
    ApplyGlobalOptions(LCommandLine);

    LActive := HostCompiler;

    if LCommandLine.Flag('path') then
    begin
      { Scriptable: one path on stdout, nothing else. }
      RequireCompiler(LActive);
      Say(LActive.Path);
      Exit(CExitOk);
    end;

    if LCommandLine.Flag('verify') then
    begin
      VerifyToolchain(LActive);
      Exit(CExitOk);
    end;

    if not LActive.Found then
      raise EStruoError.CreateHint('no Free Pascal toolchain was found',
        'this Struo was built without a bundled toolchain; install Free ' +
        'Pascal and put `fpc` on your PATH, or set STRUO_TOOLCHAIN to an ' +
        'installation root');

    LAll := DiscoverToolchains;
    for I := 0 to High(LAll) do
      ReportToolchain(LAll[I], SameText(LAll[I].Path, LActive.Path));

    if LActive.Origin = toSystem then
    begin
      SayBlank;
      { Worth saying: a system compiler is whatever this machine happens to
        have, so a build here is not the build a colleague gets. }
      Warn('Struo is using a compiler from this machine, not a bundled one, ' +
           'so builds here may differ from builds elsewhere.');
    end;

    Result := CExitOk;
  finally
    LCommandLine.Free;
  end;
end;

end.
