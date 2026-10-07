{ Exercises the TOML subset Struo relies on, including the malformed input it
  must reject with a position rather than accept quietly. }
program test_toml;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Struo.Util.Strings,
  Struo.Toml.Value,
  Struo.Toml.Parser,
  Struo.Toml.Writer,
  Struo.Test;

{ Parses ASource and reports the failure as a test failure rather than letting
  the exception escape, so one bad case does not hide the rest of the suite. }
function TryParse(const ASource, AWhat: string): TTomlValue;
begin
  Result := nil;
  try
    Result := ParseToml(ASource);
  except
    on E: ETomlError do
      Failed(AWhat, Format('unexpected parse error at %d:%d: %s',
        [E.Line, E.Column, E.Message]));
    on E: Exception do
      Failed(AWhat, 'unexpected ' + E.ClassName + ': ' + E.Message);
  end;
end;

{ Asserts that ASource does not parse. The message is not checked, only that
  the parser refused and said where. }
procedure CheckRejects(const ASource, AWhat: string);
var
  LDoc: TTomlValue;
begin
  LDoc := nil;
  try
    LDoc := ParseToml(ASource);
    Failed(AWhat, 'expected a parse error, but it parsed');
    LDoc.Free;
  except
    on E: ETomlError do
      Check(E.Line > 0, AWhat + ' (reported at line ' + IntToStr(E.Line) + ')');
    on E: Exception do
      Failed(AWhat, 'wrong exception class ' + E.ClassName + ': ' + E.Message);
  end;
end;

procedure TestScalars;
var
  LDoc: TTomlValue;
begin
  LDoc := TryParse(
    'name = "myapp"' + LineEnding +
    'count = 42' + LineEnding +
    'ratio = 1.5' + LineEnding +
    'neg = -7' + LineEnding +
    'big = 1_000_000' + LineEnding +
    'hex = 0xFF' + LineEnding +
    'yes = true' + LineEnding +
    'no = false' + LineEnding +
    'raw = ''C:\dev\no-escapes''', 'scalars');
  if LDoc = nil then
    Exit;
  try
    CheckEqStr(LDoc.Find('name').AsString, 'myapp', 'a basic string');
    CheckEqInt(LDoc.Find('count').AsInteger, 42, 'an integer');
    Check(Abs(LDoc.Find('ratio').AsFloat - 1.5) < 1E-9, 'a float');
    CheckEqInt(LDoc.Find('neg').AsInteger, -7, 'a negative integer');
    CheckEqInt(LDoc.Find('big').AsInteger, 1000000, 'underscores in a number');
    CheckEqInt(LDoc.Find('hex').AsInteger, 255, 'a hexadecimal integer');
    CheckEqBool(LDoc.Find('yes').AsBoolean, True, 'true');
    CheckEqBool(LDoc.Find('no').AsBoolean, False, 'false');
    CheckEqStr(LDoc.Find('raw').AsString, 'C:\dev\no-escapes',
      'a literal string keeps its backslashes');
  finally
    LDoc.Free;
  end;
end;

procedure TestEscapesAndComments;
var
  LDoc: TTomlValue;
begin
  LDoc := TryParse(
    '# a leading comment' + LineEnding +
    'tab = "a\tb"' + LineEnding +
    'quote = "say \"hi\""' + LineEnding +
    'uni = "\u00e9t\u00e9"   # accented' + LineEnding +
    'empty = ""', 'escapes and comments');
  if LDoc = nil then
    Exit;
  try
    CheckEqStr(LDoc.Find('tab').AsString, 'a' + #9 + 'b', 'a tab escape');
    CheckEqStr(LDoc.Find('quote').AsString, 'say "hi"', 'an escaped quote');
    { \u00e9 is e-acute, which is two bytes in UTF-8. }
    CheckEqInt(Length(LDoc.Find('uni').AsString), 5,
      'a \u escape becomes UTF-8 bytes');
    CheckEqStr(LDoc.Find('empty').AsString, '', 'an empty string');
    Check(not LDoc.Has('#'), 'comments produce no keys');
  finally
    LDoc.Free;
  end;
end;

procedure TestTables;
var
  LDoc, LPackage: TTomlValue;
begin
  LDoc := TryParse(
    '[package]' + LineEnding +
    'name = "weather"' + LineEnding +
    'version = "0.3.1"' + LineEnding +
    LineEnding +
    '[dependencies]' + LineEnding +
    'fjson = "1.2.0"' + LineEnding +
    LineEnding +
    '[profile.release]' + LineEnding +
    'optimize = 3', 'tables');
  if LDoc = nil then
    Exit;
  try
    LPackage := LDoc.Find('package');
    Check((LPackage <> nil) and LPackage.IsTable, 'a table header');
    CheckEqStr(LPackage.Find('name').AsString, 'weather', 'a key inside a table');
    CheckEqStr(LDoc.Find('dependencies').Find('fjson').AsString, '1.2.0',
      'a second table');
    CheckEqInt(LDoc.Path('profile.release.optimize').AsInteger, 3,
      'a dotted table header');
    Check(LDoc.Path('profile.missing') = nil, 'Path returns nil for a gap');
    Check(LDoc.Path('package.name.deeper') = nil,
      'Path returns nil through a scalar');
  finally
    LDoc.Free;
  end;
end;

procedure TestDottedKeys;
var
  LDoc: TTomlValue;
begin
  LDoc := TryParse(
    'profile.debug.optimize = 0' + LineEnding +
    'profile.debug.debug = true', 'dotted keys');
  if LDoc = nil then
    Exit;
  try
    CheckEqInt(LDoc.Path('profile.debug.optimize').AsInteger, 0,
      'a dotted key builds tables');
    CheckEqBool(LDoc.Path('profile.debug.debug').AsBoolean, True,
      'a second dotted key reuses them');
  finally
    LDoc.Free;
  end;
end;

procedure TestArrays;
var
  LDoc, LKeywords: TTomlValue;
  LStrings: TStrArray;
begin
  LDoc := TryParse(
    'keywords = ["cli", "json"]' + LineEnding +
    'empty = []' + LineEnding +
    'nums = [1, 2, 3]' + LineEnding +
    'multi = [' + LineEnding +
    '  "a",' + LineEnding +
    '  "b",' + LineEnding +
    ']' + LineEnding +
    'single = "solo"', 'arrays');
  if LDoc = nil then
    Exit;
  try
    LKeywords := LDoc.Find('keywords');
    CheckEqInt(LKeywords.Count, 2, 'an inline array');
    CheckEqStr(LKeywords.ItemAt(1).AsString, 'json', 'an element by index');
    CheckEqInt(LDoc.Find('empty').Count, 0, 'an empty array');
    CheckEqInt(LDoc.Find('nums').ItemAt(2).AsInteger, 3, 'an array of integers');
    CheckEqInt(LDoc.Find('multi').Count, 2,
      'a multi-line array with a trailing comma');
    LStrings := LDoc.Find('single').AsStrings;
    CheckEqInt(Length(LStrings), 1, 'a bare string reads as a one-element array');
  finally
    LDoc.Free;
  end;
end;

procedure TestInlineTables;
var
  LDoc, LDep: TTomlValue;
begin
  LDoc := TryParse(
    '[dependencies]' + LineEnding +
    'fhttp = { version = "^0.4", optional = true }' + LineEnding +
    'mylib = { path = "../mylib" }' + LineEnding +
    'bare = {}', 'inline tables');
  if LDoc = nil then
    Exit;
  try
    LDep := LDoc.Path('dependencies.fhttp');
    Check((LDep <> nil) and LDep.IsTable, 'an inline table');
    Check(LDep.IsInline, 'it remembers it was inline');
    CheckEqStr(LDep.StringOr('version', ''), '^0.4', 'a key inside it');
    CheckEqBool(LDep.BooleanOr('optional', False), True, 'a boolean inside it');
    CheckEqStr(LDoc.Path('dependencies.mylib').StringOr('path', ''), '../mylib',
      'a path dependency');
    CheckEqInt(LDoc.Path('dependencies.bare').Count, 0, 'an empty inline table');
  finally
    LDoc.Free;
  end;
end;

procedure TestArrayOfTables;
var
  LDoc, LBins: TTomlValue;
begin
  LDoc := TryParse(
    '[[bin]]' + LineEnding +
    'name = "myapp"' + LineEnding +
    'path = "src/main.pas"' + LineEnding +
    LineEnding +
    '[[bin]]' + LineEnding +
    'name = "myapp-admin"' + LineEnding +
    LineEnding +
    '[bin.meta]' + LineEnding +
    'hidden = true', 'arrays of tables');
  if LDoc = nil then
    Exit;
  try
    LBins := LDoc.Find('bin');
    Check((LBins <> nil) and LBins.IsArray, '[[bin]] builds an array');
    Check(LBins.IsArrayOfTables, 'it is flagged as an array of tables');
    CheckEqInt(LBins.Count, 2, 'two [[bin]] headers give two elements');
    CheckEqStr(LBins.ItemAt(0).StringOr('name', ''), 'myapp', 'the first element');
    CheckEqStr(LBins.ItemAt(1).StringOr('name', ''), 'myapp-admin',
      'the second element');
    CheckEqBool(LBins.ItemAt(1).Path('meta.hidden').AsBoolean, True,
      '[bin.meta] lands in the last [[bin]]');
  finally
    LDoc.Free;
  end;
end;

procedure TestDefaults;
var
  LDoc: TTomlValue;
begin
  LDoc := TryParse('present = "yes"', 'typed lookups');
  if LDoc = nil then
    Exit;
  try
    CheckEqStr(LDoc.StringOr('present', 'fallback'), 'yes',
      'StringOr finds a present key');
    CheckEqStr(LDoc.StringOr('absent', 'fallback'), 'fallback',
      'StringOr falls back');
    CheckEqInt(LDoc.IntegerOr('absent', 7), 7, 'IntegerOr falls back');
    CheckEqBool(LDoc.BooleanOr('absent', True), True, 'BooleanOr falls back');

    { A key of the wrong type is an authoring mistake and must be reported,
      not quietly replaced by the default. }
    try
      LDoc.IntegerOr('present', 0);
      Failed('a wrong type raises', 'expected ETomlError, got no exception');
    except
      on E: ETomlError do
        Check(True, 'a wrong type raises instead of defaulting');
    end;
  finally
    LDoc.Free;
  end;
end;

procedure TestRejections;
begin
  CheckRejects('name = ', 'rejects a missing value');
  CheckRejects('name "myapp"', 'rejects a missing equals sign');
  CheckRejects('name = "unterminated', 'rejects an unterminated string');
  CheckRejects('a = 1 b = 2', 'rejects two pairs on one line');
  CheckRejects('name = "a"' + LineEnding + 'name = "b"',
    'rejects a duplicate key');
  CheckRejects('[pkg]' + LineEnding + '[pkg]', 'rejects a duplicate table');
  CheckRejects('when = 1979-05-27', 'rejects a date');
  CheckRejects('text = """multi"""', 'rejects a multi-line string');
  CheckRejects('[unclosed', 'rejects an unclosed table header');
  CheckRejects('arr = [1, 2', 'rejects an unclosed array');
  CheckRejects('name = myapp', 'rejects an unquoted string');
end;

procedure TestRoundTrip;
var
  LDoc, LBack: TTomlValue;
  LText: string;
begin
  LDoc := TryParse(
    '[package]' + LineEnding +
    'name = "weather"' + LineEnding +
    'keywords = ["cli", "json"]' + LineEnding +
    LineEnding +
    '[dependencies]' + LineEnding +
    'fhttp = { version = "^0.4" }' + LineEnding +
    LineEnding +
    '[[bin]]' + LineEnding +
    'name = "weather"', 'round trip');
  if LDoc = nil then
    Exit;
  try
    LText := WriteToml(LDoc);
    Check(Pos('[package]', LText) > 0, 'the writer emits a table header');
    Check(Pos('[[bin]]', LText) > 0, 'the writer emits an array-of-tables header');
    Check(Pos('keywords = ["cli", "json"]', LText) > 0,
      'the writer emits a short array inline');

    { The real test: what comes back out must parse to the same values. }
    LBack := TryParse(LText, 'round trip reparse');
    if LBack = nil then
      Exit;
    try
      CheckEqStr(LBack.Path('package.name').AsString, 'weather',
        'a scalar survives a round trip');
      CheckEqStr(LBack.Path('dependencies.fhttp.version').AsString, '^0.4',
        'an inline table survives a round trip');
      CheckEqInt(LBack.Find('bin').Count, 1,
        'an array of tables survives a round trip');
      CheckEqInt(LBack.Path('package.keywords').Count, 2,
        'an array survives a round trip');
    finally
      LBack.Free;
    end;
  finally
    LDoc.Free;
  end;
end;

procedure TestWriterQuoting;
var
  LTable: TTomlValue;
begin
  CheckEqStr(QuoteTomlString('plain'), '"plain"', 'quoting a plain string');
  CheckEqStr(QuoteTomlString('say "hi"'), '"say \"hi\""', 'quoting a quote');
  CheckEqStr(QuoteTomlString('C:\dev'), '"C:\\dev"', 'quoting a backslash');
  CheckEqStr(FormatTomlKey('plain-key'), 'plain-key', 'a bare key stays bare');
  CheckEqStr(FormatTomlKey('needs quotes'), '"needs quotes"',
    'a key with a space is quoted');

  LTable := TTomlValue.NewTable;
  try
    LTable.Put('ratio', TTomlValue.NewFloat(2));
    CheckEqStr(FormatTomlValue(LTable.Find('ratio')), '2.0',
      'a whole float keeps its point');

    { A locale with a comma decimal separator must not leak into the output,
      or Struo would write lockfiles it cannot read back. }
    LTable.Put('frac', TTomlValue.NewFloat(1.5));
    CheckEqStr(FormatTomlValue(LTable.Find('frac')), '1.5',
      'a float is written with a full stop regardless of locale');
  finally
    LTable.Free;
  end;
end;

begin
  Suite('toml');
  TestScalars;
  TestEscapesAndComments;
  TestTables;
  TestDottedKeys;
  TestArrays;
  TestInlineTables;
  TestArrayOfTables;
  TestDefaults;
  TestRejections;
  TestRoundTrip;
  TestWriterQuoting;
  Halt(TestSummary);
end.
