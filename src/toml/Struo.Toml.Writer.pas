{ Struo.Toml.Writer -- a value tree back into TOML text.

  This is for files Struo generates and owns, Struo.lock above all. It is not
  for rewriting a manifest a person wrote: re-emitting Struo.toml through here
  would silently delete their comments and reflow their formatting. Manifest
  edits go through Struo.Manifest.Editor, which changes only the lines it
  must. }
unit Struo.Toml.Writer;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings, Struo.Toml.Value;

{ Serialises ARoot, which must be a table. Scalars come first in each table,
  then sub-tables as [headers], so the output reads top-down. }
function WriteToml(ARoot: TTomlValue): string;

{ A value in its inline form: 'text', 42, true, [1, 2], or braces for an
  inline table. }
function FormatTomlValue(AValue: TTomlValue): string;

{ Quotes and escapes AValue as a TOML basic string, brackets included. }
function QuoteTomlString(const AValue: string): string;

{ Renders AKey bare when it can be, quoted when it cannot. }
function FormatTomlKey(const AKey: string): string;

implementation

uses
  Struo.Toml.Lexer;

const
  { Beyond this, an array is laid out one element per line. Chosen so a
    lockfile's short dependency lists stay on one line while a long list of
    checksums stays readable. }
  CInlineArrayWidth = 60;

function QuoteTomlString(const AValue: string): string;
var
  I: Integer;
  LChar: Char;
begin
  Result := '"';
  for I := 1 to Length(AValue) do
  begin
    LChar := AValue[I];
    case LChar of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #8:   Result := Result + '\b';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #12:  Result := Result + '\f';
      #13:  Result := Result + '\r';
    else
      { Other control characters have no shorthand and must be escaped by
        code point. Everything else, UTF-8 bytes included, passes through. }
      if LChar < #32 then
        Result := Result + '\u' + LowerCase(IntToHex(Ord(LChar), 4))
      else
        Result := Result + LChar;
    end;
  end;
  Result := Result + '"';
end;

function FormatTomlKey(const AKey: string): string;
begin
  if IsBareKey(AKey) then
    Result := AKey
  else
    Result := QuoteTomlString(AKey);
end;

{ Renders a float so that reading it back yields a float again, never an
  integer. }
function FormatTomlFloat(AValue: Double): string;
begin
  { The fixed TOML format, not the locale's: emitting `1,5` would produce a
    lockfile this very parser rejects. }
  Result := FloatToStr(AValue, TomlFormatSettings);
  if (Pos('.', Result) = 0) and (Pos('e', LowerCase(Result)) = 0) then
    Result := Result + '.0';
end;

function FormatTomlValue(AValue: TTomlValue): string;
var
  I: Integer;
  LParts: TStrArray;
  LWidth: Integer;
begin
  case AValue.Kind of
    tkString:
      Result := QuoteTomlString(AValue.AsString);
    tkInteger:
      Result := IntToStr(AValue.AsInteger);
    tkFloat:
      Result := FormatTomlFloat(AValue.AsFloat);
    tkBoolean:
      if AValue.AsBoolean then
        Result := 'true'
      else
        Result := 'false';
    tkArray:
      begin
        LParts := nil;
        LWidth := 0;
        for I := 0 to AValue.Count - 1 do
        begin
          StrArrayAdd(LParts, FormatTomlValue(AValue.ItemAt(I)));
          Inc(LWidth, Length(LParts[High(LParts)]) + 2);
        end;
        if Length(LParts) = 0 then
          Result := '[]'
        else if LWidth <= CInlineArrayWidth then
          Result := '[' + JoinStr(LParts, ', ') + ']'
        else
          { One element per line, with a trailing comma so adding another
            touches exactly one line in a diff. }
          Result := '[' + LineEnding + '    ' +
                    JoinStr(LParts, ',' + LineEnding + '    ') + ',' +
                    LineEnding + ']';
      end;
    tkTable:
      begin
        LParts := nil;
        for I := 0 to AValue.Count - 1 do
          StrArrayAdd(LParts, FormatTomlKey(AValue.KeyAt(I)) + ' = ' +
                              FormatTomlValue(AValue.ItemAt(I)));
        if Length(LParts) = 0 then
          Result := '{}'
        else
          Result := '{ ' + JoinStr(LParts, ', ') + ' }';
      end;
  else
    Result := '""';
  end;
end;

{ True when AValue belongs under its own [header] rather than on a key line. }
function NeedsHeader(AValue: TTomlValue): Boolean;
begin
  Result := (AValue.IsTable and not AValue.IsInline) or AValue.IsArrayOfTables;
end;

procedure EmitTable(ATable: TTomlValue; const APrefix: string;
  var AOutput: string); forward;

{ Emits a [header] or [[header]] line followed by the table's body. }
procedure EmitSection(ATable: TTomlValue; const APath: string;
  AIsArrayElement: Boolean; var AOutput: string);
begin
  if AOutput <> '' then
    AOutput := AOutput + LineEnding;
  if AIsArrayElement then
    AOutput := AOutput + '[[' + APath + ']]' + LineEnding
  else
    AOutput := AOutput + '[' + APath + ']' + LineEnding;
  EmitTable(ATable, APath, AOutput);
end;

procedure EmitTable(ATable: TTomlValue; const APrefix: string;
  var AOutput: string);
var
  I, J: Integer;
  LKey, LPath: string;
  LValue: TTomlValue;
begin
  { Scalars and inline values first, so a reader sees what a section is before
    descending into its subsections. }
  for I := 0 to ATable.Count - 1 do
  begin
    LValue := ATable.ItemAt(I);
    if NeedsHeader(LValue) then
      Continue;
    AOutput := AOutput + FormatTomlKey(ATable.KeyAt(I)) + ' = ' +
               FormatTomlValue(LValue) + LineEnding;
  end;

  for I := 0 to ATable.Count - 1 do
  begin
    LValue := ATable.ItemAt(I);
    if not NeedsHeader(LValue) then
      Continue;

    LKey := FormatTomlKey(ATable.KeyAt(I));
    if APrefix = '' then
      LPath := LKey
    else
      LPath := APrefix + '.' + LKey;

    if LValue.IsArrayOfTables then
      for J := 0 to LValue.Count - 1 do
        EmitSection(LValue.ItemAt(J), LPath, True, AOutput)
    else
      EmitSection(LValue, LPath, False, AOutput);
  end;
end;

function WriteToml(ARoot: TTomlValue): string;
begin
  Result := '';
  if (ARoot = nil) or not ARoot.IsTable then
    Exit;
  EmitTable(ARoot, '', Result);
end;

end.
