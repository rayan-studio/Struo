{ Struo.Util.Strings -- string helpers the Free Pascal RTL does not provide.

  This unit knows nothing about Struo and depends on nothing of ours, so any
  layer may use it. Inputs are open arrays, which accept both dynamic arrays
  and inline literals, so JoinStr(LParts, ', ') and JoinStr(['a', 'b'], ', ')
  both compile. }
unit Struo.Util.Strings;

{$mode objfpc}{$H+}

interface

type
  { A list of strings. Used throughout Struo in preference to TStringList
    wherever ownership and lifetime would only get in the way. }
  TStrArray = array of string;

{ ---- predicates ---------------------------------------------------------- }

function StartsWithStr(const AText, APrefix: string): Boolean;
function EndsWithStr(const AText, ASuffix: string): Boolean;
function IsBlankStr(const AText: string): Boolean;
function ContainsStr(const AText, ANeedle: string): Boolean;

{ ---- splitting and joining ----------------------------------------------- }

{ Splits on every occurrence of ADelim. An empty text yields an empty array;
  'a,,b' yields three elements, the middle one empty. }
function SplitStr(const AText: string; ADelim: Char): TStrArray;

{ Splits on ADelim, then trims each element and drops the blank ones. Suits
  comma-separated command-line values such as --features json, tls. }
function SplitTrimStr(const AText: string; ADelim: Char): TStrArray;

{ Splits on CRLF, LF or CR. A trailing newline does not produce a final empty
  element. }
function SplitLines(const AText: string): TStrArray;

function JoinStr(const AParts: array of string; const ASep: string): string;

{ ---- shaping ------------------------------------------------------------- }

function PadLeftStr(const AText: string; AWidth: Integer): string;
function PadRightStr(const AText: string; AWidth: Integer): string;

{ Prefixes every line of AText with APrefix, the first line included. }
function IndentStr(const AText, APrefix: string): string;

{ Shortens AText to AWidth characters, ending in an ellipsis when it had to
  cut. Keeps diagnostics on a single terminal line. }
function EllipsizeStr(const AText: string; AWidth: Integer): string;

{ ---- arrays -------------------------------------------------------------- }

procedure StrArrayAdd(var AArray: TStrArray; const AValue: string);
procedure StrArrayAddAll(var AArray: TStrArray; const AValues: array of string);

{ Appends AValue only when it is not already present, preserving insertion
  order. Compiler search paths rely on both halves of that promise. }
procedure StrArrayAddUnique(var AArray: TStrArray; const AValue: string);

function StrArrayIndexOf(const AArray: array of string; const AValue: string): Integer;
function StrArrayHas(const AArray: array of string; const AValue: string): Boolean;
function StrArrayOf(const AValues: array of string): TStrArray;
procedure StrArrayRemoveAt(var AArray: TStrArray; AIndex: Integer);

implementation

uses
  SysUtils;

{ ---- predicates ---------------------------------------------------------- }

function StartsWithStr(const AText, APrefix: string): Boolean;
begin
  Result := (APrefix = '') or
            ((Length(AText) >= Length(APrefix)) and
             (CompareByte(AText[1], APrefix[1], Length(APrefix)) = 0));
end;

function EndsWithStr(const AText, ASuffix: string): Boolean;
begin
  Result := (ASuffix = '') or
            ((Length(AText) >= Length(ASuffix)) and
             (CompareByte(AText[Length(AText) - Length(ASuffix) + 1],
                          ASuffix[1], Length(ASuffix)) = 0));
end;

function IsBlankStr(const AText: string): Boolean;
begin
  Result := Trim(AText) = '';
end;

function ContainsStr(const AText, ANeedle: string): Boolean;
begin
  Result := Pos(ANeedle, AText) > 0;
end;

{ ---- splitting and joining ----------------------------------------------- }

function SplitStr(const AText: string; ADelim: Char): TStrArray;
var
  LStart, I, LCount: Integer;
begin
  Result := nil;
  if AText = '' then
    Exit;

  { Count the delimiters first so the array is sized exactly once. }
  LCount := 1;
  for I := 1 to Length(AText) do
    if AText[I] = ADelim then
      Inc(LCount);
  SetLength(Result, LCount);

  LCount := 0;
  LStart := 1;
  for I := 1 to Length(AText) do
    if AText[I] = ADelim then
    begin
      Result[LCount] := Copy(AText, LStart, I - LStart);
      Inc(LCount);
      LStart := I + 1;
    end;
  Result[LCount] := Copy(AText, LStart, Length(AText) - LStart + 1);
end;

function SplitTrimStr(const AText: string; ADelim: Char): TStrArray;
var
  LParts: TStrArray;
  I: Integer;
begin
  Result := nil;
  LParts := SplitStr(AText, ADelim);
  for I := 0 to High(LParts) do
    if not IsBlankStr(LParts[I]) then
      StrArrayAdd(Result, Trim(LParts[I]));
end;

function SplitLines(const AText: string): TStrArray;
var
  I, LStart: Integer;
begin
  Result := nil;
  I := 1;
  LStart := 1;
  while I <= Length(AText) do
  begin
    if (AText[I] = #10) or (AText[I] = #13) then
    begin
      StrArrayAdd(Result, Copy(AText, LStart, I - LStart));
      { Treat CRLF as one break rather than two. }
      if (AText[I] = #13) and (I < Length(AText)) and (AText[I + 1] = #10) then
        Inc(I);
      LStart := I + 1;
    end;
    Inc(I);
  end;
  if LStart <= Length(AText) then
    StrArrayAdd(Result, Copy(AText, LStart, Length(AText) - LStart + 1));
end;

function JoinStr(const AParts: array of string; const ASep: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AParts) do
  begin
    if I > 0 then
      Result := Result + ASep;
    Result := Result + AParts[I];
  end;
end;

{ ---- shaping ------------------------------------------------------------- }

function PadLeftStr(const AText: string; AWidth: Integer): string;
begin
  if Length(AText) >= AWidth then
    Result := AText
  else
    Result := StringOfChar(' ', AWidth - Length(AText)) + AText;
end;

function PadRightStr(const AText: string; AWidth: Integer): string;
begin
  if Length(AText) >= AWidth then
    Result := AText
  else
    Result := AText + StringOfChar(' ', AWidth - Length(AText));
end;

function IndentStr(const AText, APrefix: string): string;
var
  LLines: TStrArray;
  I: Integer;
begin
  Result := '';
  LLines := SplitLines(AText);
  for I := 0 to High(LLines) do
  begin
    if I > 0 then
      Result := Result + LineEnding;
    Result := Result + APrefix + LLines[I];
  end;
end;

function EllipsizeStr(const AText: string; AWidth: Integer): string;
const
  CEllipsis = '...';
begin
  if (AWidth <= 0) or (Length(AText) <= AWidth) then
    Result := AText
  else if AWidth <= Length(CEllipsis) then
    Result := Copy(AText, 1, AWidth)
  else
    Result := Copy(AText, 1, AWidth - Length(CEllipsis)) + CEllipsis;
end;

{ ---- arrays -------------------------------------------------------------- }

procedure StrArrayAdd(var AArray: TStrArray; const AValue: string);
begin
  SetLength(AArray, Length(AArray) + 1);
  AArray[High(AArray)] := AValue;
end;

procedure StrArrayAddAll(var AArray: TStrArray; const AValues: array of string);
var
  I, LBase: Integer;
begin
  if Length(AValues) = 0 then
    Exit;
  LBase := Length(AArray);
  SetLength(AArray, LBase + Length(AValues));
  for I := 0 to High(AValues) do
    AArray[LBase + I] := AValues[I];
end;

procedure StrArrayAddUnique(var AArray: TStrArray; const AValue: string);
begin
  if not StrArrayHas(AArray, AValue) then
    StrArrayAdd(AArray, AValue);
end;

function StrArrayIndexOf(const AArray: array of string; const AValue: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(AArray) do
    if AArray[I] = AValue then
      Exit(I);
  Result := -1;
end;

function StrArrayHas(const AArray: array of string; const AValue: string): Boolean;
begin
  Result := StrArrayIndexOf(AArray, AValue) >= 0;
end;

function StrArrayOf(const AValues: array of string): TStrArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I] := AValues[I];
end;

procedure StrArrayRemoveAt(var AArray: TStrArray; AIndex: Integer);
var
  I: Integer;
begin
  if (AIndex < 0) or (AIndex > High(AArray)) then
    Exit;
  for I := AIndex to High(AArray) - 1 do
    AArray[I] := AArray[I + 1];
  SetLength(AArray, Length(AArray) - 1);
end;

end.
