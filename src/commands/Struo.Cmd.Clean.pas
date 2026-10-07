{ Struo.Cmd.Clean -- `struo clean`.

  Deletes target/, or one profile's subdirectory. Everything in there is
  reproducible from the manifest and the lockfile, which is what makes
  deleting it safe to do without confirmation. }
unit Struo.Cmd.Clean;

{$mode objfpc}{$H+}

interface

uses
  Struo.Util.Strings;

function RunClean(const AArgv: TStrArray): Integer;

implementation

uses
  SysUtils, Struo.Types, Struo.Util.Fs, Struo.Manifest, Struo.Paths,
  Struo.Workspace, Struo.Cli.Args, Struo.Cli.Output, Struo.Cli.Command,
  Struo.Cmd.Build;

function RunClean(const AArgv: TStrArray): Integer;
var
  LCommandLine: TCommandLine;
  LManifest: TManifest;
  LVictim: string;
  LWholeTree: Boolean;
begin
  LCommandLine := TCommandLine.Create('clean');
  try
    LCommandLine.AddFlag('release', '', 'Clean only the release profile');
    LCommandLine.AddValue('profile', '', 'name', 'Clean only this profile');
    LCommandLine.AddGlobalOptions;
    LCommandLine.Parse(AArgv);

    if LCommandLine.Flag('help') then
    begin
      PrintCommandHelp('clean', '[options]',
        'Delete the build output in ' + CTargetDirName + '/.' + LineEnding +
        'With --release or --profile, delete only that profile''s directory.',
        LCommandLine);
      Exit(CExitOk);
    end;
    ApplyGlobalOptions(LCommandLine);

    { Only the manifest is needed: a package whose sources are mid-edit must
      still be cleanable. }
    LManifest := OpenManifestOnly(LCommandLine.Value('manifest-path', ''));
    try
      LWholeTree := not (LCommandLine.Flag('release') or
                         LCommandLine.HasValue('profile'));

      if LWholeTree then
        LVictim := TargetDir(LManifest.Root)
      else
        LVictim := ProfileDir(LManifest.Root, ProfileFromOptions(LCommandLine));

      if not PathIsDir(LVictim) then
      begin
        { Nothing to do is a success, so `struo clean` is safe in a script. }
        Status('Finished', Format('nothing to clean in `%s`',
          [RelativePath(LVictim, LManifest.Root)]));
        Exit(CExitOk);
      end;

      TraceFmt('removing %s', [LVictim]);
      if not RemoveTree(LVictim) then
        raise EStruoError.CreateHintFmt('could not fully remove `%s`', [LVictim],
          'something may still be running from it, or a file may be read-only');

      Status('Removed', RelativePath(LVictim, LManifest.Root));
      Result := CExitOk;
    finally
      LManifest.Free;
    end;
  finally
    LCommandLine.Free;
  end;
end;

end.
