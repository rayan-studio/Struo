{ Struo.Toml.Lexer -- turns TOML text into tokens.

  One design note worth stating, because it explains an otherwise odd token
  kind. TOML is ambiguous without context: `true` is a boolean in a value
  position and a perfectly legal bare key in a key position, and `1979` is
  either an integer or a table name. Rather than feed context back into the
  lexer, we emit a single ttAtom token for any unquoted run and let the parser
  decide what it meant. TryParseNumber and TryParseBoolean, below, are what
  the parser uses to do that.

  Newlines are tokens, not whitespace: TOML is line-oriented, and the parser
  needs to know where a key-value pair ends. }
unit Struo.Toml.Lexer;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Toml.Value;

type
  TTomlTokenKind = (
    ttEOF,
    ttNewline,
    ttAtom,       // unquoted run: a bare key, a number, true, false
    ttString,     // quoted, already decoded
    ttEquals,
    ttDot,
    ttComma,
    ttLBracket,
    ttRBracket,
    ttLBrace,
    ttRBrace
  );

  TTomlToken = record
    Kind: TTomlTokenKind;
    { The atom's characters, or the decoded contents of a string. }
    Text: string;
    Line: Integer;
    Column: Integer;
  end;

  TTomlLexer = class
  private
    FSource: string;
    FPos: Integer;
    FLine: Integer;
    FLineStart: Integer;
    function CurrentChar: Char;
    function PeekChar(AOffset: Integer): Char;
    function AtEnd: Boolean;
    function Column: Integer;
    procedure Advance;
    procedure SkipSpacesAndComments;
    function MakeToken(AKind: TTomlTokenKind; const AText: string;
      ALine, AColumn: Integer): TTomlToken;
    function ReadBasicString: TTomlToken;
    function ReadLiteralString: TTomlToken;
    function ReadAtom: TTomlToken;
  public
    constructor Create(const ASource: string);

    { Returns the next token, ttEOF forever once the input is exhausted. }
    function Next: TTomlToken;
  end;

{ Names a token kind for an error message: 'a newline', '`=`', 'end of
  input'. }
function TomlTokenName(AKind: TTomlTokenKind): string;

{ Interprets an atom as a TOML number. Understands an optional sign, decimal
  integers and floats with an exponent, 0x/0o/0b prefixes, and underscore
  separators. Returns False when AText is not a number at all, which is how
  the parser tells an integer from a bare key. }
function TryParseNumber(const AText: string; out AIsFloat: Boolean;
  out AInteger: Int64; out AFloat: Double): Boolean;

{ Interprets an atom as `true` or `false`. TOML booleans are lowercase only,
  so `True` is a bare key and not a mis-cased boolean. }
function TryParseBoolean(const AText: string; out AValue: Boolean): Boolean;

{ True when AText is usable as an unquoted key: letters, digits, underscore
  and dash, and not empty. }
function IsBareKey(const AText: string): Boolean;

{ Number formatting fixed to the TOML spec rather than to the machine's
  locale: a full stop for the decimal point, no thousands separator. Without
  this, `ratio = 1.5` fails to parse anywhere the system decimal separator is
  a comma, which is most of Europe. The writer uses it for the same reason. }
function TomlFormatSettings: TFormatSettings;

implementation

uses
  Struo.Util.Strings;

const
  CBareKeyChars = ['A'..'Z', 'a'..'z', '0'..'9', '_', '-'];

var
  GTomlFormat: TFormatSettings;

function TomlFormatSettings: TFormatSettings;
begin
  Result := GTomlFormat;
end;

{ ---- naming -------------------------------------------------------------- }

function TomlTokenName(AKind: TTomlTokenKind): string;
begin
  case AKind of
    ttEOF:      Result := 'end of input';
    ttNewline:  Result := 'a newline';
    ttAtom:     Result := 'a bare word';
    ttString:   Result := 'a string';
    ttEquals:   Result := '`=`';
    ttDot:      Result := '`.`';
    ttComma:    Result := '`,`';
    ttLBracket: Result := '`[`';
    ttRBracket: Result := '`]`';
    ttLBrace:   Result := '`{`';
    ttRBrace:   Result := '`}`';
  else
    Result := 'a token';
  end;
end;

{ ---- atom interpretation ------------------------------------------------- }

function IsBareKey(const AText: string): Boolean;
var
  I: Integer;
begin
  if AText = '' then
    Exit(False);
  for I := 1 to Length(AText) do
    if not (AText[I] in CBareKeyChars) then
      Exit(False);
  Result := True;
end;

function TryParseBoolean(const AText: string; out AValue: Boolean): Boolean;
begin
  AValue := AText = 'true';
  Result := AValue or (AText = 'false');
end;

{ Parses digits in ABase after a 0x/0o/0b prefix. }
function TryParseRadix(const ADigits: string; ABase: Integer;
  out AInteger: Int64): Boolean;
var
  I, LDigit: Integer;
begin
  AInteger := 0;
  Result := False;
  if ADigits = '' then
    Exit;
  for I := 1 to Length(ADigits) do
  begin
    case ADigits[I] of
      '0' .. '9': LDigit := Ord(ADigits[I]) - Ord('0');
      'a' .. 'f': LDigit := Ord(ADigits[I]) - Ord('a') + 10;
      'A' .. 'F': LDigit := Ord(ADigits[I]) - Ord('A') + 10;
    else
      Exit(False);
    end;
    if LDigit >= ABase then
      Exit(False);
    AInteger := AInteger * ABase + LDigit;
  end;
  Result := True;
end;

function TryParseNumber(const AText: string; out AIsFloat: Boolean;
  out AInteger: Int64; out AFloat: Double): Boolean;
var
  LText, LDigits: string;
  LNegative: Boolean;
  I: Integer;
  LHasDigit: Boolean;
begin
  AIsFloat := False;
  AInteger := 0;
  AFloat := 0;
  Result := False;

  { Underscores are decoration; TOML allows them between digits. }
  LText := StringReplace(AText, '_', '', [rfReplaceAll]);
  if LText = '' then
    Exit;

  LNegative := False;
  if LText[1] in ['+', '-'] then
  begin
    LNegative := LText[1] = '-';
    Delete(LText, 1, 1);
    if LText = '' then
      Exit;
  end;

  { Radix prefixes. TOML does not allow a sign on these, but accepting one
    costs nothing and rejecting it would only puzzle the author. }
  if (Length(LText) > 2) and (LText[1] = '0') and
     (LText[2] in ['x', 'X', 'o', 'O', 'b', 'B']) then
  begin
    LDigits := Copy(LText, 3, MaxInt);
    case LText[2] of
      'x', 'X': Result := TryParseRadix(LDigits, 16, AInteger);
      'o', 'O': Result := TryParseRadix(LDigits, 8, AInteger);
      'b', 'B': Result := TryParseRadix(LDigits, 2, AInteger);
    end;
    if Result and LNegative then
      AInteger := -AInteger;
    Exit;
  end;

  { Decide between integer and float by looking for a radix point or an
    exponent, and reject anything that is not made of number characters. }
  LHasDigit := False;
  for I := 1 to Length(LText) do
    case LText[I] of
      '0' .. '9':
        LHasDigit := True;
      '.':
        AIsFloat := True;
      'e', 'E':
        begin
          { An exponent needs digits before it, so `e5` stays a bare key. }
          if not LHasDigit then
            Exit;
          AIsFloat := True;
        end;
      '+', '-':
        { Only valid immediately after the exponent marker. }
        if (I = 1) or not (LText[I - 1] in ['e', 'E']) then
          Exit;
    else
      Exit;
    end;

  if not LHasDigit then
    Exit;

  if AIsFloat then
  begin
    { Parse with the fixed TOML format so a comma-decimal locale cannot change
      how a manifest reads. }
    Result := TryStrToFloat(LText, AFloat, GTomlFormat);
    if not Result then
      Exit;
    if LNegative then
      AFloat := -AFloat;
  end
  else
  begin
    Result := TryStrToInt64(LText, AInteger);
    if not Result then
      Exit;
    if LNegative then
      AInteger := -AInteger;
  end;
end;

{ ---- UTF-8 encoding of an escape ----------------------------------------- }

{ Appends ACodePoint to ATarget as UTF-8. Used for \u and \U escapes, which
  name a code point rather than bytes. }
procedure AppendCodePointUtf8(var ATarget: string; ACodePoint: LongWord);
begin
  if ACodePoint <= $7F then
    ATarget := ATarget + Chr(ACodePoint)
  else if ACodePoint <= $7FF then
    ATarget := ATarget + Chr($C0 or (ACodePoint shr 6)) +
                         Chr($80 or (ACodePoint and $3F))
  else if ACodePoint <= $FFFF then
    ATarget := ATarget + Chr($E0 or (ACodePoint shr 12)) +
                         Chr($80 or ((ACodePoint shr 6) and $3F)) +
                         Chr($80 or (ACodePoint and $3F))
  else
    ATarget := ATarget + Chr($F0 or (ACodePoint shr 18)) +
                         Chr($80 or ((ACodePoint shr 12) and $3F)) +
                         Chr($80 or ((ACodePoint shr 6) and $3F)) +
                         Chr($80 or (ACodePoint and $3F));
end;

{ ---- TTomlLexer ---------------------------------------------------------- }

constructor TTomlLexer.Create(const ASource: string);
begin
  inherited Create;
  FSource := ASource;
  FPos := 1;
  FLine := 1;
  FLineStart := 1;
end;

function TTomlLexer.AtEnd: Boolean;
begin
  Result := FPos > Length(FSource);
end;

function TTomlLexer.CurrentChar: Char;
begin
  if AtEnd then
    Result := #0
  else
    Result := FSource[FPos];
end;

function TTomlLexer.PeekChar(AOffset: Integer): Char;
begin
  if FPos + AOffset > Length(FSource) then
    Result := #0
  else
    Result := FSource[FPos + AOffset];
end;

function TTomlLexer.Column: Integer;
begin
  Result := FPos - FLineStart + 1;
end;

procedure TTomlLexer.Advance;
begin
  if not AtEnd then
    Inc(FPos);
end;

procedure TTomlLexer.SkipSpacesAndComments;
begin
  while not AtEnd do
  begin
    if CurrentChar in [' ', #9] then
      Advance
    else if CurrentChar = '#' then
      { A comment runs to the end of the line; the newline itself is still a
        token, because it terminates the pair the comment trailed. }
      while (not AtEnd) and not (CurrentChar in [#10, #13]) do
        Advance
    else
      Break;
  end;
end;

function TTomlLexer.MakeToken(AKind: TTomlTokenKind; const AText: string;
  ALine, AColumn: Integer): TTomlToken;
begin
  Result.Kind := AKind;
  Result.Text := AText;
  Result.Line := ALine;
  Result.Column := AColumn;
end;

function TTomlLexer.ReadBasicString: TTomlToken;
var
  LText: string;
  LLine, LCol, I: Integer;
  LCode: LongWord;
  LHex: string;
  LEscape: Char;
begin
  LLine := FLine;
  LCol := Column;

  if (PeekChar(1) = '"') and (PeekChar(2) = '"') then
    raise ETomlError.CreateAt(LLine, LCol,
      'multi-line strings are not supported in a Struo manifest');

  Advance; // opening quote
  LText := '';
  while True do
  begin
    if AtEnd or (CurrentChar in [#10, #13]) then
      raise ETomlError.CreateAt(LLine, LCol, 'unterminated string');

    if CurrentChar = '"' then
    begin
      Advance;
      Break;
    end;

    if CurrentChar <> '\' then
    begin
      LText := LText + CurrentChar;
      Advance;
      Continue;
    end;

    { An escape sequence. }
    Advance;
    case CurrentChar of
      '"':  begin LText := LText + '"';  Advance; end;
      '\':  begin LText := LText + '\';  Advance; end;
      'b':  begin LText := LText + #8;   Advance; end;
      't':  begin LText := LText + #9;   Advance; end;
      'n':  begin LText := LText + #10;  Advance; end;
      'f':  begin LText := LText + #12;  Advance; end;
      'r':  begin LText := LText + #13;  Advance; end;
      'u', 'U':
        begin
          LEscape := CurrentChar;
          if LEscape = 'U' then
            I := 8
          else
            I := 4;
          Advance;
          LHex := '';
          while (Length(LHex) < I) and (not AtEnd) and
                (CurrentChar in ['0'..'9', 'a'..'f', 'A'..'F']) do
          begin
            LHex := LHex + CurrentChar;
            Advance;
          end;
          if Length(LHex) <> I then
            raise ETomlError.CreateAtFmt(FLine, Column,
              'expected %d hexadecimal digits after \%s', [I, LEscape]);
          LCode := StrToQWord('$' + LHex);
          AppendCodePointUtf8(LText, LCode);
        end;
    else
      raise ETomlError.CreateAtFmt(FLine, Column,
        'unknown escape sequence `\%s`', [CurrentChar]);
    end;
  end;

  Result := MakeToken(ttString, LText, LLine, LCol);
end;

function TTomlLexer.ReadLiteralString: TTomlToken;
var
  LText: string;
  LLine, LCol: Integer;
begin
  LLine := FLine;
  LCol := Column;

  if (PeekChar(1) = '''') and (PeekChar(2) = '''') then
    raise ETomlError.CreateAt(LLine, LCol,
      'multi-line strings are not supported in a Struo manifest');

  Advance; // opening quote
  LText := '';
  { Literal strings have no escapes at all, which is what makes them the
    right way to write a Windows path. }
  while True do
  begin
    if AtEnd or (CurrentChar in [#10, #13]) then
      raise ETomlError.CreateAt(LLine, LCol, 'unterminated literal string');
    if CurrentChar = '''' then
    begin
      Advance;
      Break;
    end;
    LText := LText + CurrentChar;
    Advance;
  end;

  Result := MakeToken(ttString, LText, LLine, LCol);
end;

function TTomlLexer.ReadAtom: TTomlToken;
var
  LText: string;
  LLine, LCol: Integer;
  LNumeric: Boolean;
begin
  LLine := FLine;
  LCol := Column;
  { Only a run that starts like a number may absorb a radix point, so that
    `a.b` stays two keys while `1.5` stays one float. }
  LNumeric := CurrentChar in ['0'..'9', '+', '-'];

  LText := '';
  while not AtEnd do
  begin
    if CurrentChar in CBareKeyChars then
      LText := LText + CurrentChar
    else if LNumeric and (CurrentChar = '.') then
      LText := LText + CurrentChar
    else
      Break;
    Advance;
  end;

  Result := MakeToken(ttAtom, LText, LLine, LCol);
end;

function TTomlLexer.Next: TTomlToken;
var
  LLine, LCol: Integer;
begin
  SkipSpacesAndComments;

  if AtEnd then
    Exit(MakeToken(ttEOF, '', FLine, Column));

  LLine := FLine;
  LCol := Column;

  { Newline, counting CRLF once. }
  if CurrentChar in [#10, #13] then
  begin
    if (CurrentChar = #13) and (PeekChar(1) = #10) then
      Advance;
    Advance;
    Inc(FLine);
    FLineStart := FPos;
    Exit(MakeToken(ttNewline, '', LLine, LCol));
  end;

  case CurrentChar of
    '"': Exit(ReadBasicString);
    '''': Exit(ReadLiteralString);
    '=': begin Advance; Exit(MakeToken(ttEquals, '=', LLine, LCol)); end;
    '.': begin Advance; Exit(MakeToken(ttDot, '.', LLine, LCol)); end;
    ',': begin Advance; Exit(MakeToken(ttComma, ',', LLine, LCol)); end;
    '[': begin Advance; Exit(MakeToken(ttLBracket, '[', LLine, LCol)); end;
    ']': begin Advance; Exit(MakeToken(ttRBracket, ']', LLine, LCol)); end;
    '{': begin Advance; Exit(MakeToken(ttLBrace, '{', LLine, LCol)); end;
    '}': begin Advance; Exit(MakeToken(ttRBrace, '}', LLine, LCol)); end;
  end;

  if (CurrentChar in CBareKeyChars) or (CurrentChar in ['+', '-']) then
    Exit(ReadAtom);

  raise ETomlError.CreateAtFmt(LLine, LCol,
    'unexpected character `%s`', [CurrentChar]);
end;

initialization
  GTomlFormat := DefaultFormatSettings;
  GTomlFormat.DecimalSeparator := '.';
  GTomlFormat.ThousandSeparator := #0;

end.
