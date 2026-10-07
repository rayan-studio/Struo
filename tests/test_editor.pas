{ Exercises the surgical manifest editor and the lockfile.

  The editor's whole reason to exist is that it must not damage a file a
  person wrote, so most of what is checked here is what did *not* change:
  comments, blank lines, key order, indentation and the file's line endings. }
program test_editor;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Struo.Util.Strings,
  Struo.Util.Fs,
  Struo.Types,
  Struo.SemVer,
  Struo.Manifest,
  Struo.Manifest.Editor,
  Struo.Lockfile,
  Struo.Test;

var
  GScratch: string;

{ A throwaway manifest path holding AContent. }
function WriteScratch(const AName, AContent: string): string;
begin
  Result := JoinPath(GScratch, AName + '-' + IntToStr(Random(1000000)) +
                     '-' + CManifestName);
  WriteTextFile(Result, AContent);
end;

{ ---- the editor ---------------------------------------------------------- }

const
  CCommented =
    '[package]' + LineEnding +
    'name = "app"' + LineEnding +
    'version = "0.1.0"' + LineEnding +
    LineEnding +
    '# Hand-picked, in this order, for reasons.' + LineEnding +
    '[dependencies]' + LineEnding +
    '# fjson parses the config.' + LineEnding +
    'fjson = "1.2.0"' + LineEnding +
    'zulu = "0.1.0"' + LineEnding +
    LineEnding +
    '[build]' + LineEnding +
    'mode = "objfpc"' + LineEnding;

procedure TestPreservesEverythingElse;
var
  LPath, LText: string;
  LEditor: TManifestEditor;
begin
  LPath := WriteScratch('comments', CCommented);
  try
    LEditor := TManifestEditor.Create(LPath);
    try
      Check(not LEditor.SetEntry(CDependenciesSection, 'fcolor', '"2.0.0"'),
        'adding a new key reports that it was new');
      LText := LEditor.Text;
    finally
      LEditor.Free;
    end;

    Check(Pos('# Hand-picked, in this order, for reasons.', LText) > 0,
      'a comment above the section survives');
    Check(Pos('# fjson parses the config.', LText) > 0,
      'a comment inside the section survives');
    Check(Pos('fcolor = "2.0.0"', LText) > 0, 'the new key is written');
    Check(Pos('[build]', LText) > 0, 'the following section survives');

    { Added at the end of its own section, not at the end of the file, and
      not before the section's existing keys. }
    Check(Pos('zulu = "0.1.0"', LText) < Pos('fcolor = "2.0.0"', LText),
      'the new key goes after the existing ones');
    Check(Pos('fcolor = "2.0.0"', LText) < Pos('[build]', LText),
      'the new key stays inside its section');

    { The blank line that separated [dependencies] from [build] must still be
      doing its job. }
    Check(Pos('fcolor = "2.0.0"' + LineEnding + LineEnding + '[build]', LText) > 0,
      'the blank line before the next section survives');
  finally
    DeleteFile(LPath);
  end;
end;

procedure TestReplacesInPlace;
var
  LPath, LText: string;
  LEditor: TManifestEditor;
begin
  LPath := WriteScratch('replace', CCommented);
  try
    LEditor := TManifestEditor.Create(LPath);
    try
      Check(LEditor.SetEntry(CDependenciesSection, 'fjson', '"1.9.0"'),
        'replacing an existing key reports that it existed');
      LText := LEditor.Text;
    finally
      LEditor.Free;
    end;

    CheckEqInt(Pos('fjson = "1.2.0"', LText), 0, 'the old value is gone');
    Check(Pos('fjson = "1.9.0"', LText) > 0, 'the new value is there');
    { Replaced where it was, so the key order the author chose is kept. }
    Check(Pos('fjson = "1.9.0"', LText) < Pos('zulu = "0.1.0"', LText),
      'the key stays in its original position');
    Check(Pos('# fjson parses the config.', LText) <
          Pos('fjson = "1.9.0"', LText),
      'its comment still sits above it');
  finally
    DeleteFile(LPath);
  end;
end;

procedure TestRemoves;
var
  LPath, LText: string;
  LEditor: TManifestEditor;
begin
  LPath := WriteScratch('remove', CCommented);
  try
    LEditor := TManifestEditor.Create(LPath);
    try
      Check(LEditor.RemoveEntry(CDependenciesSection, 'fjson'),
        'removing a present key succeeds');
      Check(not LEditor.RemoveEntry(CDependenciesSection, 'nope'),
        'removing an absent key reports so');
      Check(not LEditor.RemoveEntry('no-such-section', 'fjson'),
        'removing from an absent section reports so');
      LText := LEditor.Text;
    finally
      LEditor.Free;
    end;

    CheckEqInt(Pos('fjson = "1.2.0"', LText), 0, 'the assignment is gone');
    { The comment above it is the author's prose, not Struo's to delete. }
    Check(Pos('# fjson parses the config.', LText) > 0,
      'the comment above it is left alone');
    Check(Pos('zulu = "0.1.0"', LText) > 0, 'the other key survives');
  finally
    DeleteFile(LPath);
  end;
end;

procedure TestCreatesMissingSection;
var
  LPath, LText: string;
  LEditor: TManifestEditor;
begin
  LPath := WriteScratch('newsection',
    '[package]' + LineEnding +
    'name = "app"' + LineEnding +
    'version = "0.1.0"' + LineEnding);
  try
    LEditor := TManifestEditor.Create(LPath);
    try
      LEditor.SetEntry(CDevDependenciesSection, 'fptest', '"0.3.0"');
      LText := LEditor.Text;
    finally
      LEditor.Free;
    end;

    Check(Pos('[dev-dependencies]', LText) > 0,
      'a missing section is created');
    Check(Pos('[dev-dependencies]', LText) < Pos('fptest = "0.3.0"', LText),
      'the key goes under its new header');
    Check(Pos('version = "0.1.0"' + LineEnding + LineEnding +
              '[dev-dependencies]', LText) > 0,
      'the new section is separated by a blank line');
  finally
    DeleteFile(LPath);
  end;
end;

procedure TestMultiLineValue;
var
  LPath, LText: string;
  LEditor: TManifestEditor;
begin
  { A value spread over several lines must be replaced or removed whole.
    Treating only its first line as the entry would leave the tail behind as
    syntax errors. }
  LPath := WriteScratch('multiline',
    '[package]' + LineEnding +
    'name = "app"' + LineEnding +
    'version = "0.1.0"' + LineEnding +
    LineEnding +
    '[dependencies]' + LineEnding +
    'fhttp = { version = "0.4.0", features = [' + LineEnding +
    '  "tls",' + LineEnding +
    '  "http2",' + LineEnding +
    '] }' + LineEnding +
    'after = "1.0.0"' + LineEnding);
  try
    LEditor := TManifestEditor.Create(LPath);
    try
      Check(LEditor.SetEntry(CDependenciesSection, 'fhttp', '"0.5.0"'),
        'a multi-line entry is found');
      LText := LEditor.Text;
    finally
      LEditor.Free;
    end;

    Check(Pos('fhttp = "0.5.0"', LText) > 0, 'it is replaced');
    CheckEqInt(Pos('"tls"', LText), 0, 'its continuation lines go with it');
    CheckEqInt(Pos('] }', LText), 0, 'including the closing brace');
    Check(Pos('after = "1.0.0"', LText) > 0, 'the next key is untouched');
  finally
    DeleteFile(LPath);
  end;
end;

procedure TestKeepsLineEndings;
var
  LPath, LText: string;
  LEditor: TManifestEditor;
begin
  { A file with Unix line endings must not come back with Windows ones, or a
    one-line change would show up as a whole-file diff. }
  LPath := WriteScratch('eol',
    '[package]'#10'name = "app"'#10'version = "0.1.0"'#10 +
    #10'[dependencies]'#10'fjson = "1.0.0"'#10);
  try
    LEditor := TManifestEditor.Create(LPath);
    try
      LEditor.SetEntry(CDependenciesSection, 'fcolor', '"1.0.0"');
      LText := LEditor.Text;
    finally
      LEditor.Free;
    end;
    CheckEqInt(Pos(#13, LText), 0, 'a LF-only file stays LF-only');
    Check(EndsWithStr(LText, #10), 'the trailing newline is kept');
  finally
    DeleteFile(LPath);
  end;
end;

procedure TestEditedManifestStillLoads;
var
  LPath: string;
  LEditor: TManifestEditor;
  LManifest: TManifest;
  LDependency: TDependency;
begin
  { The real contract: whatever the editor writes, the parser must accept. }
  LPath := WriteScratch('reload', CCommented);
  try
    LEditor := TManifestEditor.Create(LPath);
    try
      LDependency := Default(TDependency);
      LDependency.Name := 'fcolor';
      LDependency.Kind := dkGit;
      LDependency.GitUrl := 'https://github.com/x/fcolor';
      LDependency.PinKind := gpTag;
      LDependency.PinValue := 'v1.0.0';
      LDependency.UseDefaultFeatures := True;
      LDependency.Features := StrArrayOf(['ansi']);

      LEditor.SetEntry(SectionFor(LDependency), LDependency.Name,
        RenderDependencyValue(LDependency));
      LEditor.Save;
    finally
      LEditor.Free;
    end;

    LManifest := TManifest.Load(LPath);
    try
      Check(LManifest.FindDependency('fcolor', LDependency),
        'the written git dependency parses back');
      Check(LDependency.Kind = dkGit, 'as a git dependency');
      CheckEqStr(LDependency.GitUrl, 'https://github.com/x/fcolor',
        'with its url intact');
      Check(LDependency.PinKind = gpTag, 'with its tag pin');
      CheckEqInt(Length(LDependency.Features), 1, 'and its features');
    finally
      LManifest.Free;
    end;
  finally
    DeleteFile(LPath);
  end;
end;

procedure TestRendering;
var
  LDependency: TDependency;
begin
  LDependency := Default(TDependency);
  LDependency.Name := 'fjson';
  LDependency.Kind := dkRegistry;
  LDependency.Req := ParseVersionReq('1.2.0');
  LDependency.UseDefaultFeatures := True;

  { A plain registry dependency is written as the bare string, because that
    is the form every manifest uses and what `struo add fjson` should make. }
  CheckEqStr(RenderDependencyValue(LDependency), '"1.2.0"',
    'a version-only dependency is a bare string');

  LDependency.Optional := True;
  CheckEqStr(RenderDependencyValue(LDependency),
    '{ version = "1.2.0", optional = true }',
    'anything extra forces an inline table');

  LDependency := Default(TDependency);
  LDependency.Name := 'mylib';
  LDependency.Kind := dkPath;
  LDependency.Path := '../mylib';
  LDependency.UseDefaultFeatures := True;
  CheckEqStr(RenderDependencyValue(LDependency), '{ path = "../mylib" }',
    'a path dependency is a table');

  LDependency.Kind := dkGit;
  LDependency.Path := '';
  LDependency.GitUrl := 'https://x/y';
  LDependency.PinKind := gpRev;
  LDependency.PinValue := 'abc123';
  CheckEqStr(RenderDependencyValue(LDependency),
    '{ git = "https://x/y", rev = "abc123" }',
    'a git dependency carries its pin');

  LDependency := Default(TDependency);
  LDependency.Kind := dkRegistry;
  LDependency.Req := ParseVersionReq('1.0.0');
  LDependency.IsDev := True;
  CheckEqStr(SectionFor(LDependency), CDevDependenciesSection,
    'a dev dependency goes to the dev section');
end;

{ ---- the lockfile -------------------------------------------------------- }

procedure TestLockfileRoundTrip;
var
  LPath: string;
  LLock, LBack: TLockfile;
  LPackage: TLockedPackage;
begin
  LPath := JoinPath(GScratch, 'rt-' + IntToStr(Random(1000000)) + '-' +
                              CLockfileName);
  LLock := TLockfile.Create;
  try
    LLock.Add(MakeLockedPackage('zulu', ParseSemVer('0.9.0'),
      'path+../zulu', nil));
    LLock.Add(MakeLockedPackage('app', ParseSemVer('0.1.0'), '',
      StrArrayOf(['zulu', 'fjson'])));
    LLock.Add(MakeLockedPackage('fjson', ParseSemVer('1.2.0'),
      'registry+fjson', nil));
    LLock.Save(LPath);
  finally
    LLock.Free;
  end;

  try
    Check(Pos('Do not edit it by hand', ReadTextFile(LPath)) > 0,
      'the lockfile says not to edit it');

    { Sorted by name, so two machines resolving the same graph produce the
      same bytes and a diff shows only real changes. }
    Check(Pos('name = "app"', ReadTextFile(LPath)) <
          Pos('name = "fjson"', ReadTextFile(LPath)),
      'entries are sorted by name');

    LBack := TLockfile.Load(LPath);
    try
      CheckEqInt(LBack.Count, 3, 'all entries survive a round trip');
      CheckEqInt(LBack.FormatVersion, CLockfileFormat,
        'the format version survives');
      Check(LBack.Find('fjson', LPackage), 'an entry is found by name');
      CheckEqStr(SemVerToStr(LPackage.Version), '1.2.0', 'with its version');
      CheckEqStr(LPackage.Source, 'registry+fjson', 'and its source');
      Check(LBack.Find('app', LPackage), 'the root entry is found');
      CheckEqInt(Length(LPackage.Dependencies), 2, 'with its dependency list');
      { Sorted, so the order a resolver happened to visit them in is not
        recorded as if it meant something. }
      CheckEqStr(JoinStr(LPackage.Dependencies, ','), 'fjson,zulu',
        'and that list is sorted');
    finally
      LBack.Free;
    end;
  finally
    DeleteFile(LPath);
  end;
end;

procedure TestLockfileComparison;
var
  LLeft, LRight: TLockfile;
begin
  LLeft := TLockfile.Create;
  LRight := TLockfile.Create;
  try
    LLeft.Add(MakeLockedPackage('a', ParseSemVer('1.0.0'), 'path+../a', nil));
    LRight.Add(MakeLockedPackage('a', ParseSemVer('1.0.0'), 'path+../a', nil));
    Check(LLeft.SameAs(LRight), 'identical lockfiles compare equal');

    LRight.Add(MakeLockedPackage('b', ParseSemVer('1.0.0'), '', nil));
    Check(not LLeft.SameAs(LRight), 'a different count is a difference');

    LRight.Free;
    LRight := TLockfile.Create;
    { Same version, different source: a dependency that moved from a path to
      git is a change worth rewriting the lockfile for. }
    LRight.Add(MakeLockedPackage('a', ParseSemVer('1.0.0'), 'git+https://x/a', nil));
    Check(not LLeft.SameAs(LRight), 'a different source is a difference');

    LRight.Free;
    LRight := TLockfile.Create;
    LRight.Add(MakeLockedPackage('a', ParseSemVer('1.0.1'), 'path+../a', nil));
    Check(not LLeft.SameAs(LRight), 'a different version is a difference');
  finally
    LLeft.Free;
    LRight.Free;
  end;
end;

procedure TestMissingLockfileIsEmpty;
var
  LLock: TLockfile;
begin
  { A package nobody has built has no lockfile, and that is not an error. }
  LLock := TLockfile.Load(JoinPath(GScratch, 'does-not-exist.lock'));
  try
    CheckEqInt(LLock.Count, 0, 'an absent lockfile loads as empty');
  finally
    LLock.Free;
  end;
end;

begin
  Randomize;
  GScratch := JoinPath(GetTempDir(False),
    'struo-editor-' + IntToStr(Random(1000000)));
  EnsureDir(GScratch);
  try
    Suite('editor');
    TestPreservesEverythingElse;
    TestReplacesInPlace;
    TestRemoves;
    TestCreatesMissingSection;
    TestMultiLineValue;
    TestKeepsLineEndings;
    TestEditedManifestStillLoads;
    TestRendering;
    TestLockfileRoundTrip;
    TestLockfileComparison;
    TestMissingLockfileIsEmpty;
  finally
    RemoveTree(GScratch);
  end;
  Halt(TestSummary);
end.
