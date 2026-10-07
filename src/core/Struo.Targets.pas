{ Struo.Targets -- what a package builds, worked out from its layout.

  Most packages declare no targets at all. The conventional layout says
  everything, and inferring from it is what makes `struo new` followed by
  `struo build` work with a four-line manifest:

    src/<name>.pas     the library unit
    src/main.pas       a binary named after the package
    src/bin/<n>.pas    an extra binary named <n>
    tests/*.pas        one test target per file
    examples/*.pas     one example target per file

  Inference never overrides a declaration. A target declared in the manifest
  wins on both counts that matter: its name is taken, and its source file is
  claimed, so inference cannot produce a second target compiling the same
  file under a different name. }
unit Struo.Targets;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings, Struo.Types, Struo.Manifest;

{ Adds every target implied by AManifest.Root's layout that AManifest did not
  already declare. Reads the filesystem; does not compile anything. }
procedure InferTargets(AManifest: TManifest);

{ Checks that the target set is buildable: at least one target, every source
  file present, no two targets of a kind sharing a name. Raises EStruoError
  naming the first problem. }
procedure ValidateTargets(AManifest: TManifest);

{ 'a library', 'a binary', 'a test', 'an example'. For error messages. }
function TargetKindName(AKind: TTargetKind): string;

type
  { What a .pas file declares itself to be. }
  TPascalSourceKind = (pskProgram, pskUnit, pskUnknown);

{ Reads APath's leading declaration, skipping comments and directives.

  Inference needs this because a directory of .pas files is not a directory of
  programs. `tests/` typically holds test programs beside a shared helper
  unit, and treating that unit as a test target would produce a target that
  compiles perfectly and yields no executable -- a failure with no cause the
  user could act on. Asking the file what it is costs one read and removes
  the whole class of problem. }
function PascalSourceKind(const APath: string): TPascalSourceKind;

{ The absolute path of ATarget's source file. }
function TargetSourceFile(AManifest: TManifest; const ATarget: TTarget): string;

implementation

uses
  Struo.Util.Fs;

function TargetKindName(AKind: TTargetKind): string;
begin
  case AKind of
    tgLib:     Result := 'a library';
    tgBin:     Result := 'a binary';
    tgTest:    Result := 'a test';
    tgExample: Result := 'an example';
  else
    Result := 'a target';
  end;
end;

function TargetSourceFile(AManifest: TManifest; const ATarget: TTarget): string;
begin
  Result := AbsolutePath(ATarget.SourcePath, AManifest.Root);
end;

function PascalSourceKind(const APath: string): TPascalSourceKind;
const
  { The declaration is always at the top. Reading the whole of a large unit to
    find a word in its first line would be wasteful. }
  CProbeBytes = 4096;
var
  LText, LWord: string;
  I: Integer;
begin
  Result := pskUnknown;
  if not PathIsFile(APath) then
    Exit;

  try
    LText := Copy(ReadTextFile(APath), 1, CProbeBytes);
  except
    on EFsError do
      { Unreadable is not the same as malformed, and inference is not the
        place to report it; validation will fail on the file later. }
      Exit;
  end;

  I := 1;
  while I <= Length(LText) do
  begin
    { Brace comments, which is also where compiler directives live. }
    if LText[I] = '{' then
    begin
      while (I <= Length(LText)) and (LText[I] <> '}') do
        Inc(I);
      Inc(I);
      Continue;
    end;

    { Old-style (* *) comments. }
    if (LText[I] = '(') and (I < Length(LText)) and (LText[I + 1] = '*') then
    begin
      Inc(I, 2);
      while (I < Length(LText)) and
            not ((LText[I] = '*') and (LText[I + 1] = ')')) do
        Inc(I);
      Inc(I, 2);
      Continue;
    end;

    { Line comments. }
    if (LText[I] = '/') and (I < Length(LText)) and (LText[I + 1] = '/') then
    begin
      while (I <= Length(LText)) and not (LText[I] in [#10, #13]) do
        Inc(I);
      Continue;
    end;

    if LText[I] in [' ', #9, #10, #13] then
    begin
      Inc(I);
      Continue;
    end;

    { The first thing that is neither whitespace nor a comment. If it is not
      an identifier, this is not Pascal we can classify. }
    if not (LText[I] in ['A' .. 'Z', 'a' .. 'z', '_']) then
      Exit;

    LWord := '';
    while (I <= Length(LText)) and
          (LText[I] in ['A' .. 'Z', 'a' .. 'z', '0' .. '9', '_']) do
    begin
      LWord := LWord + LText[I];
      Inc(I);
    end;

    if SameText(LWord, 'program') then
      Exit(pskProgram);
    if SameText(LWord, 'unit') then
      Exit(pskUnit);
    { `library` builds a shared object and `package` a Delphi bpl; neither is
      something Struo infers, so they are left for an explicit declaration. }
    Exit(pskUnknown);
  end;
end;

{ True when AManifest already has a target of AKind named AName, or any target
  at all whose source is ASourcePath. Either is a reason not to infer. }
function AlreadyCovered(AManifest: TManifest; AKind: TTargetKind;
  const AName, ASourcePath: string): Boolean;
var
  I: Integer;
  LDeclared: string;
begin
  for I := 0 to High(AManifest.Targets) do
  begin
    if (AManifest.Targets[I].Kind = AKind) and
       SameText(AManifest.Targets[I].Name, AName) then
      Exit(True);

    { Compare normalised paths: 'src/main.pas' and 'src\main.pas' name the
      same file, and a declaration using either spelling must claim it. }
    LDeclared := NormalizePath(AManifest.Targets[I].SourcePath);
    if SameText(LDeclared, NormalizePath(ASourcePath)) then
      Exit(True);
  end;
  Result := False;
end;

{ Adds a target unless it is already covered, or unless the file declares
  itself to be something other than AExpected. ASourcePath is relative to the
  package root and is expected to exist. }
procedure InferOne(AManifest: TManifest; AKind: TTargetKind;
  const AName, ASourcePath: string; AExpected: TPascalSourceKind);
var
  LTarget: TTarget;
begin
  if AlreadyCovered(AManifest, AKind, AName, ASourcePath) then
    Exit;

  { A helper unit sitting in tests/ is not a test, and a program sitting in
    src/ under the library's name is not the library. }
  if PascalSourceKind(JoinPath(AManifest.Root, ASourcePath)) <> AExpected then
    Exit;
  LTarget := Default(TTarget);
  LTarget.Kind := AKind;
  LTarget.Name := AName;
  LTarget.SourcePath := ASourcePath;
  LTarget.Declared := False;
  AManifest.AddTarget(LTarget);
end;

{ Looks for the library unit. A package named `my-lib` may spell its unit
  either way round, since the dash is legal in a package name and illegal in a
  Pascal identifier. }
procedure InferLibrary(AManifest: TManifest);
var
  LCandidates: TStrArray;
  LUnitName, LRelative: string;
  I: Integer;
begin
  LUnitName := DefaultUnitName(AManifest.Name);

  LCandidates := StrArrayOf([LUnitName]);
  if LUnitName <> AManifest.Name then
    StrArrayAdd(LCandidates, AManifest.Name);
  { `src/lib.pas` is the obvious fallback name and costs nothing to support. }
  StrArrayAdd(LCandidates, 'lib');

  for I := 0 to High(LCandidates) do
  begin
    LRelative := JoinPath(CSourceDirName, LCandidates[I] + '.pas');
    if PathIsFile(JoinPath(AManifest.Root, LRelative)) then
    begin
      InferOne(AManifest, tgLib, LUnitName, LRelative, pskUnit);
      Exit;
    end;
  end;
end;

procedure InferBinaries(AManifest: TManifest);
var
  LBinDir, LRelative: string;
  LFiles: TStrArray;
  I: Integer;
begin
  { src/main.pas is the entry point of a binary package. }
  LRelative := JoinPath(CSourceDirName, 'main.pas');
  if PathIsFile(JoinPath(AManifest.Root, LRelative)) then
    InferOne(AManifest, tgBin, AManifest.Name, LRelative, pskProgram);

  { src/bin/<n>.pas gives additional binaries, named after the file. }
  LBinDir := JoinPaths([AManifest.Root, CSourceDirName, CBinSubDirName]);
  if not PathIsDir(LBinDir) then
    Exit;

  LFiles := ListFilesIn(LBinDir, '*.pas');
  for I := 0 to High(LFiles) do
  begin
    LRelative := JoinPaths([CSourceDirName, CBinSubDirName, LFiles[I]]);
    InferOne(AManifest, tgBin, ChangeFileExt(LFiles[I], ''), LRelative,
      pskProgram);
  end;
end;

{ tests/ and examples/ both map one file to one target, so they share a body. }
procedure InferFlatDir(AManifest: TManifest; const ADirName: string;
  AKind: TTargetKind);
var
  LDir: string;
  LFiles: TStrArray;
  I: Integer;
begin
  LDir := JoinPath(AManifest.Root, ADirName);
  if not PathIsDir(LDir) then
    Exit;

  LFiles := ListFilesIn(LDir, '*.pas');
  for I := 0 to High(LFiles) do
    InferOne(AManifest, AKind, ChangeFileExt(LFiles[I], ''),
      JoinPath(ADirName, LFiles[I]), pskProgram);
end;

procedure InferTargets(AManifest: TManifest);
begin
  if AManifest.Root = '' then
    Exit;
  InferLibrary(AManifest);
  InferBinaries(AManifest);
  InferFlatDir(AManifest, CTestsDirName, tgTest);
  InferFlatDir(AManifest, CExamplesDirName, tgExample);
end;

procedure ValidateTargets(AManifest: TManifest);
var
  I, J: Integer;
  LSource: string;
begin
  if Length(AManifest.Targets) = 0 then
    raise EStruoError.CreateHintFmt(
      'package `%s` has nothing to build', [AManifest.Name],
      'add `' + CSourceDirName + '/main.pas` for a binary, or `' +
      CSourceDirName + '/' + DefaultUnitName(AManifest.Name) +
      '.pas` for a library');

  for I := 0 to High(AManifest.Targets) do
  begin
    LSource := TargetSourceFile(AManifest, AManifest.Targets[I]);
    if not PathIsFile(LSource) then
    begin
      if AManifest.Targets[I].Declared then
        raise EStruoError.CreateHintFmt(
          '%s `%s` points at `%s`, which does not exist',
          [TargetKindName(AManifest.Targets[I].Kind), AManifest.Targets[I].Name,
           AManifest.Targets[I].SourcePath],
          'fix the `path` in ' + CManifestName + ' or create the file')
      else
        { Inference only ever names files it found, so this means the file was
          removed between inference and validation. }
        raise EStruoError.CreateHintFmt('`%s` has disappeared',
          [AManifest.Targets[I].SourcePath], '');
    end;

    for J := I + 1 to High(AManifest.Targets) do
      if (AManifest.Targets[I].Kind = AManifest.Targets[J].Kind) and
         SameText(AManifest.Targets[I].Name, AManifest.Targets[J].Name) then
        raise EStruoError.CreateHintFmt(
          'there are two targets named `%s`', [AManifest.Targets[I].Name],
          'give each ' + TargetKindName(AManifest.Targets[I].Kind) +
          ' a distinct `name` in ' + CManifestName);
  end;
end;

end.
