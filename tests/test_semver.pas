{ Exercises version parsing, precedence and requirement matching.

  The caret and prerelease cases are the ones worth reading: they encode
  decisions about what `fjson = "0.4.1"` is allowed to resolve to, and getting
  them wrong produces builds that break for whoever clones the repository
  rather than for the author. }
program test_semver;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Struo.Util.Strings,
  Struo.Types,
  Struo.SemVer,
  Struo.Test;

{ Asserts that AText parses and re-renders to itself, which catches both a
  parsing and a formatting mistake in one check. }
procedure CheckRoundTrip(const AText: string);
var
  LVersion: TSemVer;
begin
  if TryParseSemVer(AText, LVersion) then
    CheckEqStr(SemVerToStr(LVersion), AText, 'parses `' + AText + '`')
  else
    Failed('parses `' + AText + '`', 'did not parse at all');
end;

procedure CheckInvalid(const AText: string);
var
  LVersion: TSemVer;
begin
  Check(not TryParseSemVer(AText, LVersion), 'rejects `' + AText + '`');
end;

{ Asserts the ordering of two versions: -1, 0 or 1. }
procedure CheckOrder(const ALeft, ARight: string; AExpected: Integer);
var
  LLeft, LRight: TSemVer;
  LActual: Integer;
  LWhat: string;
begin
  LWhat := ALeft + ' vs ' + ARight;
  if not (TryParseSemVer(ALeft, LLeft) and TryParseSemVer(ARight, LRight)) then
  begin
    Failed(LWhat, 'one side did not parse');
    Exit;
  end;
  LActual := CompareSemVer(LLeft, LRight);
  CheckEqInt(LActual, AExpected, LWhat);
end;

{ Asserts whether AVersion satisfies AReq. }
procedure CheckMatch(const AReq, AVersion: string; AExpected: Boolean);
var
  LReq: TVersionReq;
  LVersion: TSemVer;
  LWhat: string;
begin
  if AExpected then
    LWhat := Format('"%s" accepts %s', [AReq, AVersion])
  else
    LWhat := Format('"%s" rejects %s', [AReq, AVersion]);

  if not TryParseVersionReq(AReq, LReq) then
  begin
    Failed(LWhat, 'the requirement did not parse');
    Exit;
  end;
  if not TryParseSemVer(AVersion, LVersion) then
  begin
    Failed(LWhat, 'the version did not parse');
    Exit;
  end;
  CheckEqBool(VersionReqMatches(LReq, LVersion), AExpected, LWhat);
end;

procedure TestParsing;
var
  LVersion: TSemVer;
begin
  CheckRoundTrip('0.1.0');
  CheckRoundTrip('1.2.3');
  CheckRoundTrip('10.20.30');
  CheckRoundTrip('1.0.0-alpha');
  CheckRoundTrip('1.0.0-alpha.1');
  CheckRoundTrip('1.0.0-0.3.7');
  CheckRoundTrip('1.0.0+build.5');
  CheckRoundTrip('1.0.0-beta.2+exp.sha.5114f85');

  if TryParseSemVer('1.2.3-rc.1+b9', LVersion) then
  begin
    CheckEqInt(LVersion.Major, 1, 'major is read');
    CheckEqInt(LVersion.Minor, 2, 'minor is read');
    CheckEqInt(LVersion.Patch, 3, 'patch is read');
    CheckEqStr(LVersion.PreRelease, 'rc.1', 'the prerelease is split off');
    CheckEqStr(LVersion.Build, 'b9', 'the build tag is split off');
  end
  else
    Failed('splits a full version', 'did not parse');

  CheckInvalid('');
  CheckInvalid('1');
  CheckInvalid('1.2');
  CheckInvalid('1.2.3.4');
  CheckInvalid('01.2.3');
  CheckInvalid('1.2.x');
  CheckInvalid('v1.2.3');
  CheckInvalid('-1.2.3');
  CheckInvalid('1.2.3-');
end;

procedure TestPartialParsing;
var
  LVersion: TSemVer;
  LSpecified: Integer;
begin
  Check(TryParsePartialSemVer('1', LVersion, LSpecified) and (LSpecified = 1) and
        (LVersion.Major = 1) and (LVersion.Minor = 0),
        'a bare major fills the rest with zeros');
  Check(TryParsePartialSemVer('1.2', LVersion, LSpecified) and (LSpecified = 2) and
        (LVersion.Minor = 2) and (LVersion.Patch = 0),
        'a major.minor fills the patch with zero');
  Check(TryParsePartialSemVer('1.2.3', LVersion, LSpecified) and (LSpecified = 3),
        'a full version reports three components');
end;

procedure TestPrecedence;
begin
  CheckOrder('1.0.0', '1.0.0', 0);
  CheckOrder('1.0.0', '2.0.0', -1);
  CheckOrder('2.0.0', '1.0.0', 1);
  CheckOrder('1.0.0', '1.1.0', -1);
  CheckOrder('1.0.0', '1.0.1', -1);
  CheckOrder('0.9.9', '1.0.0', -1);

  { A prerelease sorts below the release it precedes. }
  CheckOrder('1.0.0-alpha', '1.0.0', -1);
  CheckOrder('1.0.0', '1.0.0-alpha', 1);

  { Numeric identifiers compare by value, so alpha.10 is above alpha.2. The
    alphabetical answer would be the wrong one. }
  CheckOrder('1.0.0-alpha.2', '1.0.0-alpha.10', -1);
  CheckOrder('1.0.0-alpha', '1.0.0-alpha.1', -1);
  CheckOrder('1.0.0-alpha.1', '1.0.0-beta', -1);
  CheckOrder('1.0.0-beta.2', '1.0.0-beta.11', -1);
  CheckOrder('1.0.0-rc.1', '1.0.0', -1);

  { A numeric identifier sorts below an alphanumeric one. }
  CheckOrder('1.0.0-1', '1.0.0-alpha', -1);

  { Build metadata takes no part in precedence. }
  CheckOrder('1.0.0+build.1', '1.0.0+build.2', 0);
  CheckOrder('1.0.0+anything', '1.0.0', 0);
end;

procedure TestCaret;
begin
  { A bare requirement is a caret requirement, as in Cargo. }
  CheckMatch('1.2.3', '1.2.3', True);
  CheckMatch('1.2.3', '1.2.4', True);
  CheckMatch('1.2.3', '1.9.0', True);
  CheckMatch('1.2.3', '2.0.0', False);
  CheckMatch('1.2.3', '1.2.2', False);
  CheckMatch('^1.2.3', '1.5.0', True);
  CheckMatch('^1.2.3', '2.0.0', False);

  { Under 1.0.0 the minor version is breaking. }
  CheckMatch('0.4.1', '0.4.1', True);
  CheckMatch('0.4.1', '0.4.9', True);
  CheckMatch('0.4.1', '0.5.0', False);
  CheckMatch('0.4.1', '0.4.0', False);

  { And under 0.1.0 the patch is breaking. }
  CheckMatch('0.0.3', '0.0.3', True);
  CheckMatch('0.0.3', '0.0.4', False);

  { Partial carets, which Cargo spells out explicitly. }
  CheckMatch('^1.2', '1.9.9', True);
  CheckMatch('^1.2', '2.0.0', False);
  CheckMatch('^1', '1.9.9', True);
  CheckMatch('^1', '2.0.0', False);
  CheckMatch('^0', '0.9.9', True);
  CheckMatch('^0', '1.0.0', False);
  CheckMatch('^0.0', '0.0.9', True);
  CheckMatch('^0.0', '0.1.0', False);
end;

procedure TestTilde;
begin
  CheckMatch('~1.2.3', '1.2.3', True);
  CheckMatch('~1.2.3', '1.2.9', True);
  CheckMatch('~1.2.3', '1.3.0', False);
  CheckMatch('~1.2.3', '1.2.2', False);
  CheckMatch('~1.2', '1.2.9', True);
  CheckMatch('~1.2', '1.3.0', False);
  { '~1' is looser than '~1.2': it allows the whole major series. }
  CheckMatch('~1', '1.9.9', True);
  CheckMatch('~1', '2.0.0', False);
end;

procedure TestWildcardAndRanges;
begin
  CheckMatch('*', '0.0.1', True);
  CheckMatch('*', '99.0.0', True);
  CheckMatch('1.*', '1.9.9', True);
  CheckMatch('1.*', '2.0.0', False);
  CheckMatch('1.2.*', '1.2.9', True);
  CheckMatch('1.2.*', '1.3.0', False);

  CheckMatch('=1.2.3', '1.2.3', True);
  CheckMatch('=1.2.3', '1.2.4', False);

  CheckMatch('>=1.2, <1.5', '1.2.0', True);
  CheckMatch('>=1.2, <1.5', '1.4.9', True);
  CheckMatch('>=1.2, <1.5', '1.5.0', False);
  CheckMatch('>=1.2, <1.5', '1.1.9', False);
  CheckMatch('>1.0.0', '1.0.1', True);
  CheckMatch('>1.0.0', '1.0.0', False);
  CheckMatch('<=2.0.0', '2.0.0', True);
  CheckMatch('!=1.2.3', '1.2.4', True);
  CheckMatch('!=1.2.3', '1.2.3', False);
end;

procedure TestPreReleasePolicy;
begin
  { A prerelease is not an acceptable answer to a requirement that did not ask
    for one, or `>=1.0.0` would quietly pull in 2.0.0-alpha.1. }
  CheckMatch('>=1.0.0', '2.0.0-alpha.1', False);
  CheckMatch('1.2.3', '1.5.0-beta', False);
  CheckMatch('*', '1.0.0-alpha', False);

  { Naming a prerelease of the same core version opts in. }
  CheckMatch('>=1.5.0-alpha', '1.5.0-alpha', True);
  CheckMatch('>=1.5.0-alpha', '1.5.0-beta', True);
  CheckMatch('1.5.0-alpha', '1.5.0', True);

  { Opting in for one core version does not opt in for another. }
  CheckMatch('>=1.5.0-alpha', '1.6.0-alpha', False);
end;

procedure TestInvalidRequirements;
var
  LReq: TVersionReq;
begin
  Check(not TryParseVersionReq('not-a-version', LReq),
    'rejects a nonsense requirement');
  Check(not TryParseVersionReq('>=', LReq), 'rejects a bare operator');
  Check(not TryParseVersionReq('1.2.3.4', LReq), 'rejects four components');
  Check(TryParseVersionReq('', LReq) and (VersionReqToStr(LReq) = '*'),
    'an empty requirement means any version');
end;

procedure TestMaxSatisfying;
var
  LReq: TVersionReq;
  LVersions: TSemVerArray;
  LBest: TSemVer;

  procedure Add(const AText: string);
  begin
    SetLength(LVersions, Length(LVersions) + 1);
    LVersions[High(LVersions)] := ParseSemVer(AText);
  end;

begin
  LVersions := nil;
  Add('1.0.0');
  Add('1.2.0');
  Add('1.4.2');
  Add('2.0.0');
  Add('1.3.0-beta');

  LReq := ParseVersionReq('1.0.0');
  if MaxSatisfying(LReq, LVersions, LBest) then
    CheckEqStr(SemVerToStr(LBest), '1.4.2',
      'MaxSatisfying picks the highest compatible release')
  else
    Failed('MaxSatisfying picks the highest compatible release', 'found none');

  LReq := ParseVersionReq('=1.2.0');
  if MaxSatisfying(LReq, LVersions, LBest) then
    CheckEqStr(SemVerToStr(LBest), '1.2.0', 'MaxSatisfying honours an exact pin')
  else
    Failed('MaxSatisfying honours an exact pin', 'found none');

  LReq := ParseVersionReq('^3');
  Check(not MaxSatisfying(LReq, LVersions, LBest),
    'MaxSatisfying reports no match rather than guessing');

  { The prerelease in the list must not win, even though it sorts high. }
  LReq := ParseVersionReq('>=1.0.0, <2.0.0');
  if MaxSatisfying(LReq, LVersions, LBest) then
    CheckEqStr(SemVerToStr(LBest), '1.4.2',
      'MaxSatisfying skips a prerelease nobody asked for')
  else
    Failed('MaxSatisfying skips a prerelease nobody asked for', 'found none');
end;

procedure TestSorting;
var
  LVersions: TSemVerArray;
  LRendered: TStrArray;
  I: Integer;
begin
  SetLength(LVersions, 5);
  LVersions[0] := ParseSemVer('1.0.0');
  LVersions[1] := ParseSemVer('0.9.0');
  LVersions[2] := ParseSemVer('1.0.0-alpha');
  LVersions[3] := ParseSemVer('2.0.0');
  LVersions[4] := ParseSemVer('1.0.1');

  SortSemVers(LVersions);

  LRendered := nil;
  for I := 0 to High(LVersions) do
    StrArrayAdd(LRendered, SemVerToStr(LVersions[I]));

  CheckEqStr(JoinStr(LRendered, ' '),
    '0.9.0 1.0.0-alpha 1.0.0 1.0.1 2.0.0',
    'sorting puts a prerelease before its release');
end;

procedure TestErrorMessages;
begin
  try
    ParseSemVer('nope');
    Failed('ParseSemVer raises on bad input', 'no exception');
  except
    on E: EStruoError do
      Check(E.Hint <> '', 'the version error carries a hint');
  end;

  try
    ParseVersionReq('>>1');
    Failed('ParseVersionReq raises on bad input', 'no exception');
  except
    on E: EStruoError do
      Check(E.Hint <> '', 'the requirement error carries a hint');
  end;
end;

begin
  Suite('semver');
  TestParsing;
  TestPartialParsing;
  TestPrecedence;
  TestCaret;
  TestTilde;
  TestWildcardAndRanges;
  TestPreReleasePolicy;
  TestInvalidRequirements;
  TestMaxSatisfying;
  TestSorting;
  TestErrorMessages;
  Halt(TestSummary);
end.
