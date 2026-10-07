{ struo -- the package manager and build tool for Pascal.

  This file does three things and nothing else: register the commands,
  dispatch, and turn an exception into an exit code. Every decision about what
  a command does lives in its own unit, so this file stays short enough to
  read in one go and to see the whole command surface at a glance.

  The only try..except in Struo that reaches the user is below. The core layer
  raises EStruoError and never prints; this is where that becomes `error:` on
  stderr and a status a script can act on:

    0  the command succeeded, or the program `struo run` started did
    1  the command ran and failed
    2  the command line was wrong }
program struo;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Struo.Util.Strings,
  Struo.Types,
  Struo.Cli.Output,
  Struo.Cli.Args,
  Struo.Cli.Command,
  Struo.Cmd.New,
  Struo.Cmd.Build,
  Struo.Cmd.Run,
  Struo.Cmd.Test,
  Struo.Cmd.Clean,
  Struo.Cmd.Doctor;

const
  { The sections of the help screen, in the order they appear. }
  CSectionPackages = 'Creating packages';
  CSectionBuilding = 'Building';
  CSectionDiagnostics = 'Diagnostics';

procedure RegisterCommands;
begin
  RegisterCommand('new', CSectionPackages,
    'Create a new package in a new directory', @RunNew, []);
  RegisterCommand('init', CSectionPackages,
    'Turn the current directory into a package', @RunInit, []);

  RegisterCommand('build', CSectionBuilding,
    'Compile the package and its dependencies', @RunBuild, ['b']);
  RegisterCommand('run', CSectionBuilding,
    'Build, then run the binary', @RunRun, ['r']);
  RegisterCommand('test', CSectionBuilding,
    'Build and run the test targets', @RunTest, ['t']);
  RegisterCommand('check', CSectionBuilding,
    'Compile for diagnostics without linking', @RunCheck, []);
  RegisterCommand('clean', CSectionBuilding,
    'Delete the build output', @RunClean, []);

  RegisterCommand('doctor', CSectionDiagnostics,
    'Report the detected compiler and paths', @RunDoctor, []);
end;

function Main: Integer;
begin
  RegisterCommands;
  try
    Result := Dispatch(ArgvFromParams);
  except
    { Order matters: the usage error is a subclass and must be caught first,
      or every usage mistake would exit 1 and scripts could not tell a wrong
      command line from a failed build. }
    on E: EStruoUsageError do
    begin
      Error(E.Message, E.Hint);
      Result := CExitUsage;
    end;
    on E: EStruoError do
    begin
      Error(E.Message, E.Hint);
      Result := CExitFailure;
    end;
    on E: Exception do
    begin
      { Anything reaching here is a bug in Struo rather than a problem with
        the user's package, so it says so and names the class: a report
        including `EAccessViolation` is worth ten saying `it crashed`. }
      Error(Format('internal error: %s: %s', [E.ClassName, E.Message]),
        'this is a bug in Struo; please report it at ' +
        'https://github.com/rayan-studio/Struo/issues');
      Result := CExitFailure;
    end;
  end;
end;

begin
  Halt(Main);
end.
