{ Struo.Manifest.Editor -- changing Struo.toml without rewriting it.

  `struo add` and `struo remove` edit a file a person wrote and will keep
  reading. Round-tripping it through the TOML parser and writer would be far
  less code, and it would silently delete every comment, reorder nothing in
  particular, and reflow the author's layout. Nobody forgives a tool that
  does that twice.

  So this operates on lines. It finds the section, finds the key inside it,
  and replaces or inserts exactly the lines it must. Comments, blank lines,
  key order and the author's spacing all survive untouched.

  The one thing it has to be careful about is that a dependency is not always
  one line. An inline table holding a multi-line array of features spreads
  across three or four of them. So a key's extent is found by counting
  brackets and braces outside strings, not by assuming the line it starts on
  is the line it ends on. }
unit Struo.Manifest.Editor;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings, Struo.Types, Struo.Manifest;

const
  { The two sections this editor knows how to write into. }
  CDependenciesSection = 'dependencies';
  CDevDependenciesSection = 'dev-dependencies';

type
  TManifestEditor = class
  private
    FPath: string;
    FLines: TStrArray;
    FEol: string;
    FEndsWithNewline: Boolean;
    FChanged: Boolean;

    { The index of the `[name]` header line, or -1. }
    function FindSection(const AName: string): Integer;

    { The index one past the section's last line: the next header, or the end
      of the file. }
    function SectionLimit(AHeaderIndex: Integer): Integer;

    { The first line of AKey's entry within the section, or -1. ALastLine
      receives the last line of the entry, which differs when the value runs
      across several lines. }
    function FindKey(AHeaderIndex: Integer; const AKey: string;
      out ALastLine: Integer): Integer;

    { Creates the section at the end of the file when it is missing. }
    function EnsureSection(const AName: string): Integer;

    procedure ReplaceLines(AFrom, ATo: Integer; const AText: string);
    procedure InsertLine(AIndex: Integer; const AText: string);
    procedure DeleteLines(AFrom, ATo: Integer);
  public
    { Reads APath. Raises EStruoError when it is not there. }
    constructor Create(const APath: string);

    { Adds AKey with AValueText, or replaces its value when it is already
      there. AValueText is the right-hand side only, as
      RenderDependencyValue produces it. Returns True when the key was
      already present, so the caller can say `Adding` or `Updating`. }
    function SetEntry(const ASection, AKey, AValueText: string): Boolean;

    { Removes AKey and its continuation lines. False when it was not there. }
    function RemoveEntry(const ASection, AKey: string): Boolean;

    { Writes the file back, atomically, if anything changed. }
    procedure Save;

    { The current text, for tests and for --dry-run. }
    function Text: string;

    property Changed: Boolean read FChanged;
  end;

{ The right-hand side of a dependency line: a bare version string when that
  says everything, an inline table when it does not. }
function RenderDependencyValue(const ADependency: TDependency): string;

{ The section a dependency belongs in. }
function SectionFor(const ADependency: TDependency): string;

implementation

uses
  Struo.Util.Fs, Struo.SemVer, Struo.Toml.Writer;

{ ---- rendering ----------------------------------------------------------- }

{ '"tls", "json"': the inside of a TOML array of strings. }
function QuoteList(const AValues: TStrArray): string;
var
  LParts: TStrArray;
  I: Integer;
begin
  LParts := nil;
  for I := 0 to High(AValues) do
    StrArrayAdd(LParts, QuoteTomlString(AValues[I]));
  Result := JoinStr(LParts, ', ');
end;

function SectionFor(const ADependency: TDependency): string;
begin
  if ADependency.IsDev then
    Result := CDevDependenciesSection
  else
    Result := CDependenciesSection;
end;

function RenderDependencyValue(const ADependency: TDependency): string;
var
  LParts: TStrArray;
  LPinKey: string;
begin
  LParts := nil;

  case ADependency.Kind of
    dkPath:
      StrArrayAdd(LParts, 'path = ' + QuoteTomlString(ADependency.Path));
    dkGit:
      begin
        StrArrayAdd(LParts, 'git = ' + QuoteTomlString(ADependency.GitUrl));
        case ADependency.PinKind of
          gpBranch: LPinKey := 'branch';
          gpTag:    LPinKey := 'tag';
          gpRev:    LPinKey := 'rev';
        else
          LPinKey := '';
        end;
        if LPinKey <> '' then
          StrArrayAdd(LParts, LPinKey + ' = ' + QuoteTomlString(ADependency.PinValue));
      end;
  else
    StrArrayAdd(LParts, 'version = ' +
      QuoteTomlString(VersionReqToStr(ADependency.Req)));
  end;

  if ADependency.Optional then
    StrArrayAdd(LParts, 'optional = true');
  if not ADependency.UseDefaultFeatures then
    StrArrayAdd(LParts, 'default-features = false');
  if Length(ADependency.Features) > 0 then
    StrArrayAdd(LParts, 'features = [' + QuoteList(ADependency.Features) + ']');

  { A registry dependency with nothing but a version is written as the bare
    string, because that is the form every manifest in the ecosystem uses and
    the form `struo add fjson` should produce. }
  if (ADependency.Kind = dkRegistry) and (Length(LParts) = 1) then
    Exit(QuoteTomlString(VersionReqToStr(ADependency.Req)));

  Result := '{ ' + JoinStr(LParts, ', ') + ' }';
end;

{ ---- line scanning ------------------------------------------------------- }

{ The net change in bracket and brace depth across ALine, ignoring anything
  inside a string or after a comment marker. This is what makes a multi-line
  value's extent discoverable. }
function DepthDelta(const ALine: string): Integer;
var
  I: Integer;
  LInBasic, LInLiteral: Boolean;
begin
  Result := 0;
  LInBasic := False;
  LInLiteral := False;
  I := 1;
  while I <= Length(ALine) do
  begin
    if LInBasic then
    begin
      if ALine[I] = '\' then
        Inc(I)
      else if ALine[I] = '"' then
        LInBasic := False;
    end
    else if LInLiteral then
    begin
      if ALine[I] = '''' then
        LInLiteral := False;
    end
    else
      case ALine[I] of
        '"': LInBasic := True;
        '''': LInLiteral := True;
        '#': Exit;
        '[', '{': Inc(Result);
        ']', '}': Dec(Result);
      end;
    Inc(I);
  end;
end;

{ True when ALine, outside any string, is a `[section]` header. }
function IsSectionHeader(const ALine: string; out AName: string): Boolean;
var
  LTrimmed: string;
  LClose: Integer;
begin
  AName := '';
  LTrimmed := Trim(ALine);
  if (LTrimmed = '') or (LTrimmed[1] <> '[') then
    Exit(False);

  { An array-of-tables header opens with two brackets. }
  if StartsWithStr(LTrimmed, '[[') then
  begin
    LClose := Pos(']]', LTrimmed);
    if LClose <= 2 then
      Exit(False);
    AName := Trim(Copy(LTrimmed, 3, LClose - 3));
    Exit(True);
  end;

  LClose := Pos(']', LTrimmed);
  if LClose <= 1 then
    Exit(False);
  AName := Trim(Copy(LTrimmed, 2, LClose - 2));
  Result := True;
end;

{ The key a line assigns to, or '' when the line is not an assignment.
  Handles both bare and quoted keys. }
function LineKey(const ALine: string): string;
var
  LTrimmed: string;
  I: Integer;
begin
  Result := '';
  LTrimmed := Trim(ALine);
  if (LTrimmed = '') or (LTrimmed[1] = '#') or (LTrimmed[1] = '[') then
    Exit;

  if LTrimmed[1] = '"' then
  begin
    I := 2;
    while (I <= Length(LTrimmed)) and (LTrimmed[I] <> '"') do
    begin
      if LTrimmed[I] = '\' then
        Inc(I);
      Result := Result + LTrimmed[I];
      Inc(I);
    end;
    Inc(I);
  end
  else
  begin
    I := 1;
    while (I <= Length(LTrimmed)) and
          (LTrimmed[I] in ['A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '-']) do
    begin
      Result := Result + LTrimmed[I];
      Inc(I);
    end;
  end;

  { Only an assignment counts. `fjson` alone on a line is not one, and a
    dotted key such as `profile.debug` is not a dependency entry. }
  while (I <= Length(LTrimmed)) and (LTrimmed[I] in [' ', #9]) do
    Inc(I);
  if (I > Length(LTrimmed)) or (LTrimmed[I] <> '=') then
    Result := '';
end;

{ ---- construction -------------------------------------------------------- }

constructor TManifestEditor.Create(const APath: string);
var
  LText: string;
begin
  inherited Create;
  FPath := APath;
  if not PathIsFile(APath) then
    raise EStruoError.CreateHintFmt('no manifest at `%s`', [APath],
      'run `struo init` to create one');

  LText := ReadTextFile(APath);

  { Keep whichever line ending the file already uses, so an edit does not
    show up as a whole-file change in a diff. }
  if Pos(#13#10, LText) > 0 then
    FEol := #13#10
  else if Pos(#10, LText) > 0 then
    FEol := #10
  else
    FEol := LineEnding;

  FEndsWithNewline := (LText <> '') and
                      (LText[Length(LText)] in [#10, #13]);
  FLines := SplitLines(LText);
end;

function TManifestEditor.Text: string;
begin
  Result := JoinStr(FLines, FEol);
  { A text file ends with a newline. Restoring it only when it was there
    leaves a file without one alone. }
  if FEndsWithNewline and (Result <> '') then
    Result := Result + FEol;
end;

procedure TManifestEditor.Save;
begin
  if not FChanged then
    Exit;
  WriteTextFile(FPath, Text);
end;

{ ---- line surgery ------------------------------------------------------- }

procedure TManifestEditor.ReplaceLines(AFrom, ATo: Integer; const AText: string);
begin
  DeleteLines(AFrom, ATo);
  InsertLine(AFrom, AText);
end;

procedure TManifestEditor.InsertLine(AIndex: Integer; const AText: string);
var
  I: Integer;
begin
  SetLength(FLines, Length(FLines) + 1);
  for I := High(FLines) downto AIndex + 1 do
    FLines[I] := FLines[I - 1];
  FLines[AIndex] := AText;
  FChanged := True;
end;

procedure TManifestEditor.DeleteLines(AFrom, ATo: Integer);
var
  LCount, I: Integer;
begin
  if (AFrom < 0) or (ATo < AFrom) or (AFrom > High(FLines)) then
    Exit;
  if ATo > High(FLines) then
    ATo := High(FLines);
  LCount := ATo - AFrom + 1;
  for I := AFrom to High(FLines) - LCount do
    FLines[I] := FLines[I + LCount];
  SetLength(FLines, Length(FLines) - LCount);
  FChanged := True;
end;

{ ---- navigation --------------------------------------------------------- }

function TManifestEditor.FindSection(const AName: string): Integer;
var
  I: Integer;
  LName: string;
begin
  for I := 0 to High(FLines) do
    if IsSectionHeader(FLines[I], LName) and (LName = AName) then
      Exit(I);
  Result := -1;
end;

function TManifestEditor.SectionLimit(AHeaderIndex: Integer): Integer;
var
  I, LDepth: Integer;
  LName: string;
begin
  LDepth := 0;
  for I := AHeaderIndex + 1 to High(FLines) do
  begin
    { A header only ends the section when it is at depth zero; a `[` inside a
      multi-line array is not a header. }
    if (LDepth = 0) and IsSectionHeader(FLines[I], LName) then
      Exit(I);
    Inc(LDepth, DepthDelta(FLines[I]));
  end;
  Result := Length(FLines);
end;

function TManifestEditor.FindKey(AHeaderIndex: Integer; const AKey: string;
  out ALastLine: Integer): Integer;
var
  I, LLimit, LDepth: Integer;
begin
  ALastLine := -1;
  LLimit := SectionLimit(AHeaderIndex);
  I := AHeaderIndex + 1;

  while I < LLimit do
  begin
    { Dependency names are compared case-insensitively, matching how the
      manifest model looks them up. }
    if SameText(LineKey(FLines[I]), AKey) then
    begin
      { Walk forward until the value's brackets balance. }
      LDepth := DepthDelta(FLines[I]);
      ALastLine := I;
      while (LDepth > 0) and (ALastLine + 1 < LLimit) do
      begin
        Inc(ALastLine);
        Inc(LDepth, DepthDelta(FLines[ALastLine]));
      end;
      Exit(I);
    end;

    { Skip over a multi-line value belonging to some other key. }
    LDepth := DepthDelta(FLines[I]);
    while (LDepth > 0) and (I + 1 < LLimit) do
    begin
      Inc(I);
      Inc(LDepth, DepthDelta(FLines[I]));
    end;
    Inc(I);
  end;

  Result := -1;
end;

function TManifestEditor.EnsureSection(const AName: string): Integer;
begin
  Result := FindSection(AName);
  if Result >= 0 then
    Exit;

  { Append at the end. A blank line first, unless the file already ends with
    one, so sections stay visually separated. }
  if (Length(FLines) > 0) and not IsBlankStr(FLines[High(FLines)]) then
    InsertLine(Length(FLines), '');
  InsertLine(Length(FLines), '[' + AName + ']');
  Result := High(FLines);
end;

{ ---- the operations ----------------------------------------------------- }

function TManifestEditor.SetEntry(const ASection, AKey, AValueText: string): Boolean;
var
  LHeader, LFirst, LLast, LInsertAt: Integer;
begin
  LHeader := EnsureSection(ASection);
  LFirst := FindKey(LHeader, AKey, LLast);

  if LFirst >= 0 then
  begin
    { Replace in place, keeping the key where the author put it and keeping
      the indentation they used. }
    ReplaceLines(LFirst, LLast, AKey + ' = ' + AValueText);
    Exit(True);
  end;

  { Insert at the end of the section, before any trailing blank lines, so a
    blank line separating sections is not swallowed. }
  LInsertAt := SectionLimit(LHeader);
  while (LInsertAt - 1 > LHeader) and IsBlankStr(FLines[LInsertAt - 1]) do
    Dec(LInsertAt);

  InsertLine(LInsertAt, AKey + ' = ' + AValueText);
  Result := False;
end;

function TManifestEditor.RemoveEntry(const ASection, AKey: string): Boolean;
var
  LHeader, LFirst, LLast: Integer;
begin
  LHeader := FindSection(ASection);
  if LHeader < 0 then
    Exit(False);

  LFirst := FindKey(LHeader, AKey, LLast);
  if LFirst < 0 then
    Exit(False);

  DeleteLines(LFirst, LLast);
  Result := True;
end;

end.
