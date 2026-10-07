{ Struo.Test -- the smallest test harness that is still pleasant to read.

  Struo does not depend on fpcunit, so that `struo test` can bootstrap on a
  bare Free Pascal install. Each test program calls Suite once, then a series
  of Check* calls, then ends with Halt(TestSummary). A non-zero exit code is
  the only thing a runner needs to understand. }
unit Struo.Test;

{$mode objfpc}{$H+}

interface

{ Prints a heading and resets the counters. }
procedure Suite(const AName: string);

procedure Check(ACondition: Boolean; const AWhat: string);
procedure CheckEqStr(const AActual, AExpected, AWhat: string);
procedure CheckEqInt(AActual, AExpected: Int64; const AWhat: string);
procedure CheckEqBool(AActual, AExpected: Boolean; const AWhat: string);

{ Records a failure outright, for the arm of a try..except that should not
  have been reached. }
procedure Failed(const AWhat, ADetail: string);

{ Prints the tally and returns the process exit code: 0 all passed, 1
  otherwise. }
function TestSummary: Integer;

implementation

uses
  SysUtils;

var
  GPassed: Integer = 0;
  GFailed: Integer = 0;
  GSuite: string = '';

procedure Suite(const AName: string);
begin
  GSuite := AName;
  GPassed := 0;
  GFailed := 0;
  WriteLn(AName);
end;

procedure Pass(const AWhat: string);
begin
  Inc(GPassed);
  WriteLn('  ok    ', AWhat);
end;

procedure Fail(const AWhat, ADetail: string);
begin
  Inc(GFailed);
  WriteLn('  FAIL  ', AWhat);
  if ADetail <> '' then
    WriteLn('        ', ADetail);
end;

procedure Check(ACondition: Boolean; const AWhat: string);
begin
  if ACondition then
    Pass(AWhat)
  else
    Fail(AWhat, '');
end;

{ Renders a string for a failure message: visible quotes, and newlines shown
  as escapes so a multi-line mismatch stays on one line. }
function Show(const AValue: string): string;
begin
  Result := StringReplace(AValue, #13#10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #9, '\t', [rfReplaceAll]);
  Result := '`' + Result + '`';
end;

procedure CheckEqStr(const AActual, AExpected, AWhat: string);
begin
  if AActual = AExpected then
    Pass(AWhat)
  else
    Fail(AWhat, 'expected ' + Show(AExpected) + ', got ' + Show(AActual));
end;

procedure CheckEqInt(AActual, AExpected: Int64; const AWhat: string);
begin
  if AActual = AExpected then
    Pass(AWhat)
  else
    Fail(AWhat, Format('expected %d, got %d', [AExpected, AActual]));
end;

procedure CheckEqBool(AActual, AExpected: Boolean; const AWhat: string);
begin
  if AActual = AExpected then
    Pass(AWhat)
  else
    Fail(AWhat, Format('expected %s, got %s',
      [BoolToStr(AExpected, True), BoolToStr(AActual, True)]));
end;

procedure Failed(const AWhat, ADetail: string);
begin
  Fail(AWhat, ADetail);
end;

function TestSummary: Integer;
begin
  WriteLn;
  if GFailed = 0 then
  begin
    WriteLn(Format('%s: %d passed', [GSuite, GPassed]));
    Result := 0;
  end
  else
  begin
    WriteLn(Format('%s: %d passed, %d FAILED', [GSuite, GPassed, GFailed]));
    Result := 1;
  end;
end;

end.
