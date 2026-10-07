{ Struo.SemVer -- versions and the requirements that select them.

  Struo follows Cargo's reading of SemVer, including the parts that are
  convention rather than specification:

  * A bare requirement is a caret requirement. `fjson = "1.2.0"` means
    >=1.2.0, <2.0.0, not an exact pin. This is what package authors almost
    always mean, and making them write the caret would only add noise.

  * Under 1.0.0 the minor version is treated as breaking, so `"0.4.1"` means
    >=0.4.1, <0.5.0. Pre-1.0 libraries do break on minor bumps, and pretending
    otherwise produces builds that fail for the person who clones your repo
    rather than for you.

  * A prerelease version satisfies a requirement only when the requirement
    itself names a prerelease of the same major.minor.patch. Otherwise
    `>=1.0.0` would quietly pull in 2.0.0-alpha.1. }
unit Struo.SemVer;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings, Struo.Types;

type
  TSemVer = record
    Major: Integer;
    Minor: Integer;
    Patch: Integer;
    { Everything after '-', empty when absent. Compared component by
      component, so 1.0.0-alpha.2 is below 1.0.0-alpha.10. }
    PreRelease: string;
    { Everything after '+'. Carried for display and ignored in comparison, as
      the specification requires. }
    Build: string;
  end;

  TSemVerArray = array of TSemVer;

  TReqOp = (roGE, roGT, roLE, roLT, roEQ, roNE);

  { One bound, such as >=1.2.0. A requirement is the AND of its bounds. }
  TComparator = record
    Op: TReqOp;
    Version: TSemVer;
  end;

  TVersionReq = record
    { The requirement as the author wrote it, for error messages and for
      writing back to the manifest unchanged. }
    Text: string;
    Bounds: array of TComparator;
  end;

{ ---- versions ------------------------------------------------------------ }

{ Parses a full MAJOR.MINOR.PATCH with optional -prerelease and +build.
  Raises EStruoError naming AText on anything else. }
function ParseSemVer(const AText: string): TSemVer;
function TryParseSemVer(const AText: string; out AVersion: TSemVer): Boolean;

{ Accepts a partial version, as a requirement may be written: '1', '1.2' or
  '1.2.3'. ASpecified reports how many components were given, which is what
  the caret and tilde rules need to know. }
function TryParsePartialSemVer(const AText: string; out AVersion: TSemVer;
  out ASpecified: Integer): Boolean;

function SemVerToStr(const AVersion: TSemVer): string;

{ -1, 0 or 1. Build metadata is ignored; a prerelease sorts below the release
  it precedes. }
function CompareSemVer(const ALeft, ARight: TSemVer): Integer;
function SameSemVer(const ALeft, ARight: TSemVer): Boolean;
function IsPreRelease(const AVersion: TSemVer): Boolean;

{ ---- requirements -------------------------------------------------------- }

{ Parses '*', '1.2.3', '^1.2', '~1.2.3', '1.2.*', '=1.0.0', '>=1.2, <1.5'.
  Raises EStruoError, naming AText, on anything else. }
function ParseVersionReq(const AText: string): TVersionReq;
function TryParseVersionReq(const AText: string; out AReq: TVersionReq): Boolean;

{ An unconstrained requirement, equivalent to '*'. }
function AnyVersionReq: TVersionReq;

{ An exact pin, as the lockfile records. }
function ExactVersionReq(const AVersion: TSemVer): TVersionReq;

function VersionReqMatches(const AReq: TVersionReq; const AVersion: TSemVer): Boolean;

{ The requirement as written, or '*' when it was empty. }
function VersionReqToStr(const AReq: TVersionReq): string;

{ The highest version in AVersions that satisfies AReq. False when none does,
  which is the resolver's cue to report a conflict. }
function MaxSatisfying(const AReq: TVersionReq; const AVersions: TSemVerArray;
  out ABest: TSemVer): Boolean;

{ Sorts ascending. Used so `struo tree` and error messages list versions in a
  predictable order. }
procedure SortSemVers(var AVersions: TSemVerArray);

implementation

{ ---- parsing ------------------------------------------------------------- }

{ Reads a run of digits as a non-negative integer. Rejects an empty run and a
  leading zero on a multi-digit number, both of which SemVer forbids. }
function TryParseNumericId(const AText: string; out AValue: Integer): Boolean;
var
  I: Integer;
begin
  AValue := 0;
  Result := False;
  if AText = '' then
    Exit;
  if (Length(AText) > 1) and (AText[1] = '0') then
    Exit;
  for I := 1 to Length(AText) do
  begin
    if not (AText[I] in ['0' .. '9']) then
      Exit;
    { Refuse to wrap rather than accept a nonsense version. }
    if AValue > (High(Integer) - 9) div 10 then
      Exit;
    AValue := AValue * 10 + (Ord(AText[I]) - Ord('0'));
  end;
  Result := True;
end;

{ Prerelease and build identifiers allow letters, digits, dots and dashes. }
function IsValidTag(const AText: string): Boolean;
var
  I: Integer;
begin
  if AText = '' then
    Exit(False);
  for I := 1 to Length(AText) do
    if not (AText[I] in ['A' .. 'Z', 'a' .. 'z', '0' .. '9', '.', '-']) then
      Exit(False);
  Result := True;
end;

function TryParsePartialSemVer(const AText: string; out AVersion: TSemVer;
  out ASpecified: Integer): Boolean;
var
  LCore, LRest: string;
  LParts: TStrArray;
  LDash, LPlus: Integer;
begin
  AVersion := Default(TSemVer);
  ASpecified := 0;
  Result := False;

  LRest := Trim(AText);
  if LRest = '' then
    Exit;

  { Split off +build first: a build tag may contain a dash, so looking for '-'
    in the whole string would find the wrong one. }
  LPlus := Pos('+', LRest);
  if LPlus > 0 then
  begin
    AVersion.Build := Copy(LRest, LPlus + 1, MaxInt);
    LRest := Copy(LRest, 1, LPlus - 1);
    if not IsValidTag(AVersion.Build) then
      Exit;
  end;

  LDash := Pos('-', LRest);
  if LDash > 0 then
  begin
    AVersion.PreRelease := Copy(LRest, LDash + 1, MaxInt);
    LRest := Copy(LRest, 1, LDash - 1);
    if not IsValidTag(AVersion.PreRelease) then
      Exit;
  end;

  LCore := LRest;
  if LCore = '' then
    Exit;

  LParts := SplitStr(LCore, '.');
  if (Length(LParts) < 1) or (Length(LParts) > 3) then
    Exit;

  if not TryParseNumericId(LParts[0], AVersion.Major) then
    Exit;
  ASpecified := 1;

  if Length(LParts) >= 2 then
  begin
    if not TryParseNumericId(LParts[1], AVersion.Minor) then
      Exit;
    ASpecified := 2;
  end;

  if Length(LParts) >= 3 then
  begin
    if not TryParseNumericId(LParts[2], AVersion.Patch) then
      Exit;
    ASpecified := 3;
  end;

  Result := True;
end;

function TryParseSemVer(const AText: string; out AVersion: TSemVer): Boolean;
var
  LSpecified: Integer;
begin
  Result := TryParsePartialSemVer(AText, AVersion, LSpecified) and (LSpecified = 3);
end;

function ParseSemVer(const AText: string): TSemVer;
begin
  if not TryParseSemVer(AText, Result) then
    raise EStruoError.CreateHintFmt('`%s` is not a valid version', [AText],
      'versions look like 1.0.0, 0.2.1-beta.3 or 1.0.0+build.5');
end;

function SemVerToStr(const AVersion: TSemVer): string;
begin
  Result := Format('%d.%d.%d', [AVersion.Major, AVersion.Minor, AVersion.Patch]);
  if AVersion.PreRelease <> '' then
    Result := Result + '-' + AVersion.PreRelease;
  if AVersion.Build <> '' then
    Result := Result + '+' + AVersion.Build;
end;

{ ---- comparison ---------------------------------------------------------- }

{ Compares two prerelease identifiers. A numeric identifier sorts below an
  alphanumeric one, and numeric ones compare by value, so alpha.10 is above
  alpha.2 rather than below it alphabetically. }
function CompareIdentifier(const ALeft, ARight: string): Integer;
var
  LLeftNum, LRightNum: Integer;
  LLeftIsNum, LRightIsNum: Boolean;
begin
  LLeftIsNum := TryParseNumericId(ALeft, LLeftNum);
  LRightIsNum := TryParseNumericId(ARight, LRightNum);

  if LLeftIsNum and LRightIsNum then
  begin
    if LLeftNum < LRightNum then
      Exit(-1);
    if LLeftNum > LRightNum then
      Exit(1);
    Exit(0);
  end;

  if LLeftIsNum <> LRightIsNum then
  begin
    if LLeftIsNum then
      Exit(-1);
    Exit(1);
  end;

  Result := CompareStr(ALeft, ARight);
  if Result < 0 then
    Result := -1
  else if Result > 0 then
    Result := 1;
end;

function ComparePreRelease(const ALeft, ARight: string): Integer;
var
  LLeftParts, LRightParts: TStrArray;
  I, LCount: Integer;
begin
  { A version with no prerelease is the release, which outranks every
    prerelease of the same core version. }
  if (ALeft = '') and (ARight = '') then
    Exit(0);
  if ALeft = '' then
    Exit(1);
  if ARight = '' then
    Exit(-1);

  LLeftParts := SplitStr(ALeft, '.');
  LRightParts := SplitStr(ARight, '.');

  LCount := Length(LLeftParts);
  if Length(LRightParts) < LCount then
    LCount := Length(LRightParts);

  for I := 0 to LCount - 1 do
  begin
    Result := CompareIdentifier(LLeftParts[I], LRightParts[I]);
    if Result <> 0 then
      Exit;
  end;

  { Equal so far: the one with more identifiers is the greater. }
  if Length(LLeftParts) < Length(LRightParts) then
    Exit(-1);
  if Length(LLeftParts) > Length(LRightParts) then
    Exit(1);
  Result := 0;
end;

function CompareSemVer(const ALeft, ARight: TSemVer): Integer;
begin
  if ALeft.Major <> ARight.Major then
  begin
    if ALeft.Major < ARight.Major then
      Exit(-1);
    Exit(1);
  end;
  if ALeft.Minor <> ARight.Minor then
  begin
    if ALeft.Minor < ARight.Minor then
      Exit(-1);
    Exit(1);
  end;
  if ALeft.Patch <> ARight.Patch then
  begin
    if ALeft.Patch < ARight.Patch then
      Exit(-1);
    Exit(1);
  end;
  { Build metadata takes no part in precedence. }
  Result := ComparePreRelease(ALeft.PreRelease, ARight.PreRelease);
end;

function SameSemVer(const ALeft, ARight: TSemVer): Boolean;
begin
  Result := CompareSemVer(ALeft, ARight) = 0;
end;

function IsPreRelease(const AVersion: TSemVer): Boolean;
begin
  Result := AVersion.PreRelease <> '';
end;

{ ---- requirements -------------------------------------------------------- }

function MakeComparator(AOp: TReqOp; const AVersion: TSemVer): TComparator;
begin
  Result.Op := AOp;
  Result.Version := AVersion;
end;

procedure AddBound(var AReq: TVersionReq; AOp: TReqOp; const AVersion: TSemVer);
begin
  SetLength(AReq.Bounds, Length(AReq.Bounds) + 1);
  AReq.Bounds[High(AReq.Bounds)] := MakeComparator(AOp, AVersion);
end;

function AnyVersionReq: TVersionReq;
begin
  Result.Text := '*';
  Result.Bounds := nil;
end;

function ExactVersionReq(const AVersion: TSemVer): TVersionReq;
begin
  Result.Text := '=' + SemVerToStr(AVersion);
  Result.Bounds := nil;
  AddBound(Result, roEQ, AVersion);
end;

{ The upper bound of a caret requirement: increment the leftmost non-zero
  component and zero everything to its right. When every specified component
  is zero, increment the last one specified, so ^0.0 is <0.1.0 while ^0 is
  <1.0.0. }
function CaretUpperBound(const AVersion: TSemVer; ASpecified: Integer): TSemVer;
begin
  Result := Default(TSemVer);
  if AVersion.Major > 0 then
    Result.Major := AVersion.Major + 1
  else if AVersion.Minor > 0 then
    Result.Minor := AVersion.Minor + 1
  else if AVersion.Patch > 0 then
    Result.Patch := AVersion.Patch + 1
  else
    case ASpecified of
      1: Result.Major := 1;
      2: Result.Minor := 1;
    else
      Result.Patch := 1;
    end;
end;

{ The upper bound of a tilde requirement: '~1' allows all of 1.x, while '~1.2'
  and '~1.2.3' allow only 1.2.x. }
function TildeUpperBound(const AVersion: TSemVer; ASpecified: Integer): TSemVer;
begin
  Result := Default(TSemVer);
  if ASpecified <= 1 then
    Result.Major := AVersion.Major + 1
  else
  begin
    Result.Major := AVersion.Major;
    Result.Minor := AVersion.Minor + 1;
  end;
end;

{ Parses one comma-separated piece of a requirement into bounds. }
function ParseOneBound(const APiece: string; var AReq: TVersionReq): Boolean;
var
  LText, LCore: string;
  LVersion, LUpper: TSemVer;
  LSpecified: Integer;
  LOp: TReqOp;
  LHasOp: Boolean;
begin
  LText := Trim(APiece);
  if LText = '' then
    Exit(False);

  { '*', '1.*' and '1.2.x' are all wildcards; how many components precede the
    star is what decides the bound. }
  if (LText = '*') or (LText = 'x') or (LText = 'X') then
  begin
    { No bounds at all: everything matches. }
    Exit(True);
  end;

  if EndsWithStr(LText, '.*') or EndsWithStr(LText, '.x') or EndsWithStr(LText, '.X') then
  begin
    LCore := Copy(LText, 1, Length(LText) - 2);
    if not TryParsePartialSemVer(LCore, LVersion, LSpecified) then
      Exit(False);

    { The star stands in for the next component, so '1.*' allows all of 1.x
      while '1.2.*' allows only 1.2.x. }
    LUpper := Default(TSemVer);
    if LSpecified = 1 then
      LUpper.Major := LVersion.Major + 1
    else
    begin
      LUpper.Major := LVersion.Major;
      LUpper.Minor := LVersion.Minor + 1;
    end;

    AddBound(AReq, roGE, LVersion);
    AddBound(AReq, roLT, LUpper);
    Exit(True);
  end;

  { An explicit operator, longest first so '>=' is not read as '>'. }
  LHasOp := True;
  if StartsWithStr(LText, '>=') then
  begin
    LOp := roGE;
    Delete(LText, 1, 2);
  end
  else if StartsWithStr(LText, '<=') then
  begin
    LOp := roLE;
    Delete(LText, 1, 2);
  end
  else if StartsWithStr(LText, '!=') then
  begin
    LOp := roNE;
    Delete(LText, 1, 2);
  end
  else if StartsWithStr(LText, '>') then
  begin
    LOp := roGT;
    Delete(LText, 1, 1);
  end
  else if StartsWithStr(LText, '<') then
  begin
    LOp := roLT;
    Delete(LText, 1, 1);
  end
  else if StartsWithStr(LText, '=') then
  begin
    LOp := roEQ;
    Delete(LText, 1, 1);
  end
  else
  begin
    LHasOp := False;
    LOp := roGE;
  end;

  if LHasOp then
  begin
    if not TryParsePartialSemVer(LText, LVersion, LSpecified) then
      Exit(False);
    AddBound(AReq, LOp, LVersion);
    Exit(True);
  end;

  { No operator: a caret, written or implied. }
  if StartsWithStr(LText, '^') then
    Delete(LText, 1, 1)
  else if StartsWithStr(LText, '~') then
  begin
    Delete(LText, 1, 1);
    if not TryParsePartialSemVer(LText, LVersion, LSpecified) then
      Exit(False);
    AddBound(AReq, roGE, LVersion);
    AddBound(AReq, roLT, TildeUpperBound(LVersion, LSpecified));
    Exit(True);
  end;

  if not TryParsePartialSemVer(LText, LVersion, LSpecified) then
    Exit(False);
  AddBound(AReq, roGE, LVersion);
  AddBound(AReq, roLT, CaretUpperBound(LVersion, LSpecified));
  Result := True;
end;

function TryParseVersionReq(const AText: string; out AReq: TVersionReq): Boolean;
var
  LPieces: TStrArray;
  I: Integer;
begin
  AReq.Text := Trim(AText);
  AReq.Bounds := nil;

  { An empty requirement means 'any', the same as '*'. }
  if AReq.Text = '' then
  begin
    AReq.Text := '*';
    Exit(True);
  end;

  LPieces := SplitTrimStr(AReq.Text, ',');
  if Length(LPieces) = 0 then
    Exit(False);

  for I := 0 to High(LPieces) do
    if not ParseOneBound(LPieces[I], AReq) then
    begin
      AReq.Bounds := nil;
      Exit(False);
    end;

  Result := True;
end;

function ParseVersionReq(const AText: string): TVersionReq;
begin
  if not TryParseVersionReq(AText, Result) then
    raise EStruoError.CreateHintFmt('`%s` is not a valid version requirement',
      [AText],
      'try "1.2.3" for compatible releases, "=1.2.3" for an exact version, ' +
      'or ">=1.2, <1.5" for a range');
end;

function VersionReqToStr(const AReq: TVersionReq): string;
begin
  if AReq.Text = '' then
    Result := '*'
  else
    Result := AReq.Text;
end;

function BoundMatches(const ABound: TComparator; const AVersion: TSemVer): Boolean;
var
  LOrder: Integer;
begin
  LOrder := CompareSemVer(AVersion, ABound.Version);
  case ABound.Op of
    roGE: Result := LOrder >= 0;
    roGT: Result := LOrder > 0;
    roLE: Result := LOrder <= 0;
    roLT: Result := LOrder < 0;
    roEQ: Result := LOrder = 0;
    roNE: Result := LOrder <> 0;
  else
    Result := False;
  end;
end;

function VersionReqMatches(const AReq: TVersionReq; const AVersion: TSemVer): Boolean;
var
  I: Integer;
  LPreReleaseAllowed: Boolean;
begin
  for I := 0 to High(AReq.Bounds) do
    if not BoundMatches(AReq.Bounds[I], AVersion) then
      Exit(False);

  if not IsPreRelease(AVersion) then
    Exit(True);

  { The candidate is a prerelease. Accept it only if the author opted in by
    naming a prerelease of the same core version: `>=1.0.0` must not quietly
    resolve to 2.0.0-alpha.1. }
  LPreReleaseAllowed := False;
  for I := 0 to High(AReq.Bounds) do
    if IsPreRelease(AReq.Bounds[I].Version) and
       (AReq.Bounds[I].Version.Major = AVersion.Major) and
       (AReq.Bounds[I].Version.Minor = AVersion.Minor) and
       (AReq.Bounds[I].Version.Patch = AVersion.Patch) then
    begin
      LPreReleaseAllowed := True;
      Break;
    end;
  Result := LPreReleaseAllowed;
end;

function MaxSatisfying(const AReq: TVersionReq; const AVersions: TSemVerArray;
  out ABest: TSemVer): Boolean;
var
  I: Integer;
begin
  ABest := Default(TSemVer);
  Result := False;
  for I := 0 to High(AVersions) do
    if VersionReqMatches(AReq, AVersions[I]) then
      if (not Result) or (CompareSemVer(AVersions[I], ABest) > 0) then
      begin
        ABest := AVersions[I];
        Result := True;
      end;
end;

procedure SortSemVers(var AVersions: TSemVerArray);
var
  I, J: Integer;
  LTemp: TSemVer;
begin
  { Insertion sort: version lists are short, and this keeps the unit free of
    dependencies on a sorting container. }
  for I := 1 to High(AVersions) do
  begin
    LTemp := AVersions[I];
    J := I - 1;
    while (J >= 0) and (CompareSemVer(AVersions[J], LTemp) > 0) do
    begin
      AVersions[J + 1] := AVersions[J];
      Dec(J);
    end;
    AVersions[J + 1] := LTemp;
  end;
end;

end.
