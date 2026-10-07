{ Struo.Util.Fs -- filesystem and path helpers.

  Two things here are deliberate rather than incidental:

  * ReadTextFile understands byte order marks. Windows PowerShell 5.1 writes
    UTF-16 when you redirect with '>', so a hand-made Struo.toml can easily
    arrive as UTF-16. Silently parsing those bytes as Latin-1 would produce a
    baffling syntax error, so we decode instead.

  * WriteTextFile is atomic. Struo rewrites manifests and lockfiles in place;
    a half-written Struo.toml after a crash would be worse than no change at
    all, so we write a sibling temporary file and rename it over the target. }
unit Struo.Util.Fs;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings;

type
  { Raised for every failure in this unit, so callers have one thing to
    catch. The message always names the path. }
  EFsError = class(Exception);

{ ---- path arithmetic ----------------------------------------------------- }

{ Joins with the platform separator, tolerating a trailing separator on the
  left and a leading one on the right. An empty part is skipped. }
function JoinPath(const ALeft, ARight: string): string;
function JoinPaths(const AParts: array of string): string;

function IsAbsolutePath(const APath: string): Boolean;

{ Rewrites separators to the platform's, then resolves '.' and '..'
  textually. Does not touch the disk and does not follow symlinks. }
function NormalizePath(const APath: string): string;

{ Resolves APath against ABaseDir when it is relative, then normalizes. }
function AbsolutePath(const APath, ABaseDir: string): string;

{ Expresses ATarget relative to ABaseDir, falling back to ATarget when the
  two share no common root (different drives, say). For display only. }
function RelativePath(const ATarget, ABaseDir: string): string;

function PathWithoutTrailingSep(const APath: string): string;
function PathWithTrailingSep(const APath: string): string;

{ ---- queries ------------------------------------------------------------- }

function PathIsFile(const APath: string): Boolean;
function PathIsDir(const APath: string): Boolean;
function PathExists(const APath: string): Boolean;

{ Walks up from AStartDir looking for AFileName, returning the full path to
  the first hit or '' at the filesystem root. This is how Struo finds the
  manifest from a subdirectory of a package. }
function FindUpwards(const AStartDir, AFileName: string): string;

{ Returns the directory names, not full paths, sorted, '.' and '..' omitted. }
function ListDirsIn(const ADir: string): TStrArray;

{ Returns file names, not full paths, matching AMask ('*.pas'), sorted. }
function ListFilesIn(const ADir, AMask: string): TStrArray;

{ ---- mutation ------------------------------------------------------------ }

{ Creates ADir and every missing parent. Raises EFsError on failure; a
  directory that already exists is success. }
procedure EnsureDir(const ADir: string);

{ Deletes a file or a whole directory tree. Returns False when something
  could not be removed. A path that does not exist is success. }
function RemoveTree(const APath: string): Boolean;

{ ---- text files ---------------------------------------------------------- }

{ Reads the whole file as UTF-8. A UTF-8 BOM is stripped; UTF-16 content is
  decoded to UTF-8. Raises EFsError when the file cannot be read. }
function ReadTextFile(const APath: string): string;

{ Writes AContent as UTF-8 without a BOM, atomically. Creates the parent
  directory when it is missing. }
procedure WriteTextFile(const APath, AContent: string);

{ Appends a line, creating the file when absent. Used for log-shaped files. }
procedure AppendTextLine(const APath, ALine: string);

implementation

uses
  Classes;

{ ---- path arithmetic ----------------------------------------------------- }

function JoinPath(const ALeft, ARight: string): string;
var
  LRight: string;
begin
  if ALeft = '' then
    Exit(ARight);
  if ARight = '' then
    Exit(ALeft);
  { An absolute right-hand side wins outright, as it does in every other
    language's path join. Callers that want the opposite use AbsolutePath. }
  if IsAbsolutePath(ARight) then
    Exit(ARight);

  LRight := ARight;
  while (LRight <> '') and (LRight[1] in ['/', '\']) do
    Delete(LRight, 1, 1);
  Result := PathWithTrailingSep(ALeft) + LRight;
end;

function JoinPaths(const AParts: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AParts) do
    Result := JoinPath(Result, AParts[I]);
end;

function IsAbsolutePath(const APath: string): Boolean;
begin
  if APath = '' then
    Exit(False);
  { UNC share, or a POSIX root. }
  if APath[1] in ['/', '\'] then
    Exit(True);
  { Drive letter, as in C:\dev. }
  Result := (Length(APath) >= 3) and
            (UpCase(APath[1]) in ['A'..'Z']) and
            (APath[2] = ':') and
            (APath[3] in ['/', '\']);
end;

function NormalizePath(const APath: string): string;
var
  LRoot, LRest: string;
  LParts, LStack: TStrArray;
  I: Integer;
begin
  if APath = '' then
    Exit('');

  { Split the path into an untouchable root and the part we may rewrite, so
    that '..' can never escape above the root. }
  LRoot := '';
  LRest := APath;
  if (Length(APath) >= 2) and (APath[1] in ['/', '\']) and (APath[2] in ['/', '\']) then
  begin
    LRoot := PathDelim + PathDelim;
    LRest := Copy(APath, 3, MaxInt);
  end
  else if (Length(APath) >= 3) and (UpCase(APath[1]) in ['A'..'Z']) and
          (APath[2] = ':') and (APath[3] in ['/', '\']) then
  begin
    LRoot := UpCase(APath[1]) + ':' + PathDelim;
    LRest := Copy(APath, 4, MaxInt);
  end
  else if APath[1] in ['/', '\'] then
  begin
    LRoot := PathDelim;
    LRest := Copy(APath, 2, MaxInt);
  end;

  { Normalize separators before splitting so both kinds are accepted. }
  for I := 1 to Length(LRest) do
    if LRest[I] in ['/', '\'] then
      LRest[I] := PathDelim;

  LParts := SplitStr(LRest, PathDelim);
  LStack := nil;
  for I := 0 to High(LParts) do
  begin
    if (LParts[I] = '') or (LParts[I] = '.') then
      Continue;
    if LParts[I] = '..' then
    begin
      { Only pop a component we actually walked into. A leading '..' in a
        relative path has to survive, or '../mylib' would become 'mylib'. }
      if (Length(LStack) > 0) and (LStack[High(LStack)] <> '..') then
        SetLength(LStack, Length(LStack) - 1)
      else if LRoot = '' then
        StrArrayAdd(LStack, '..');
      Continue;
    end;
    StrArrayAdd(LStack, LParts[I]);
  end;

  Result := LRoot + JoinStr(LStack, PathDelim);
  if Result = '' then
    Result := '.';
end;

function AbsolutePath(const APath, ABaseDir: string): string;
begin
  if APath = '' then
    Exit(NormalizePath(ABaseDir));
  if IsAbsolutePath(APath) then
    Result := NormalizePath(APath)
  else
    Result := NormalizePath(JoinPath(ABaseDir, APath));
end;

function RelativePath(const ATarget, ABaseDir: string): string;
var
  LTargetParts, LBaseParts, LOut: TStrArray;
  I, LCommon: Integer;
begin
  LTargetParts := SplitStr(NormalizePath(ATarget), PathDelim);
  LBaseParts := SplitStr(PathWithoutTrailingSep(NormalizePath(ABaseDir)), PathDelim);

  { Different roots, for instance C: and D:, have no relative expression. }
  if (Length(LTargetParts) = 0) or (Length(LBaseParts) = 0) or
     (not SameText(LTargetParts[0], LBaseParts[0])) then
    Exit(ATarget);

  LCommon := 0;
  while (LCommon < Length(LTargetParts)) and (LCommon < Length(LBaseParts)) and
        SameText(LTargetParts[LCommon], LBaseParts[LCommon]) do
    Inc(LCommon);

  LOut := nil;
  for I := LCommon to High(LBaseParts) do
    StrArrayAdd(LOut, '..');
  for I := LCommon to High(LTargetParts) do
    StrArrayAdd(LOut, LTargetParts[I]);

  if Length(LOut) = 0 then
    Result := '.'
  else
    Result := JoinStr(LOut, PathDelim);
end;

function PathWithoutTrailingSep(const APath: string): string;
begin
  Result := APath;
  while (Length(Result) > 1) and (Result[Length(Result)] in ['/', '\']) do
  begin
    { Keep 'C:\' intact: stripping it would turn a root into a drive-relative
      path, which means something different. }
    if (Length(Result) = 3) and (Result[2] = ':') then
      Break;
    SetLength(Result, Length(Result) - 1);
  end;
end;

function PathWithTrailingSep(const APath: string): string;
begin
  if APath = '' then
    Exit('');
  if APath[Length(APath)] in ['/', '\'] then
    Result := APath
  else
    Result := APath + PathDelim;
end;

{ ---- queries ------------------------------------------------------------- }

function PathIsFile(const APath: string): Boolean;
begin
  Result := (APath <> '') and FileExists(APath) and not DirectoryExists(APath);
end;

function PathIsDir(const APath: string): Boolean;
begin
  Result := (APath <> '') and DirectoryExists(APath);
end;

function PathExists(const APath: string): Boolean;
begin
  Result := PathIsFile(APath) or PathIsDir(APath);
end;

function FindUpwards(const AStartDir, AFileName: string): string;
var
  LDir, LPrev, LCandidate: string;
begin
  LDir := NormalizePath(ExpandFileName(AStartDir));
  LPrev := '';
  while (LDir <> '') and (LDir <> LPrev) do
  begin
    LCandidate := JoinPath(LDir, AFileName);
    if PathIsFile(LCandidate) then
      Exit(LCandidate);
    LPrev := LDir;
    LDir := PathWithoutTrailingSep(ExtractFilePath(PathWithoutTrailingSep(LDir)));
  end;
  Result := '';
end;

{ Shared body of ListDirsIn and ListFilesIn: FindFirst/FindNext differ only in
  which entries they keep. }
function ListEntries(const ADir, AMask: string; AWantDirs: Boolean): TStrArray;
var
  LSearch: TSearchRec;
  LIsDir: Boolean;
  LList: TStringList;
  I: Integer;
begin
  Result := nil;
  if not PathIsDir(ADir) then
    Exit;

  LList := TStringList.Create;
  try
    if FindFirst(JoinPath(ADir, AMask), faAnyFile, LSearch) = 0 then
    begin
      repeat
        if (LSearch.Name = '.') or (LSearch.Name = '..') then
          Continue;
        LIsDir := (LSearch.Attr and faDirectory) <> 0;
        if LIsDir = AWantDirs then
          LList.Add(LSearch.Name);
      until FindNext(LSearch) <> 0;
    end;
    FindClose(LSearch);

    { Sort so that target inference and `struo tree` are deterministic rather
      than dependent on directory order. }
    LList.Sort;
    SetLength(Result, LList.Count);
    for I := 0 to LList.Count - 1 do
      Result[I] := LList[I];
  finally
    LList.Free;
  end;
end;

function ListDirsIn(const ADir: string): TStrArray;
begin
  Result := ListEntries(ADir, '*', True);
end;

function ListFilesIn(const ADir, AMask: string): TStrArray;
begin
  Result := ListEntries(ADir, AMask, False);
end;

{ ---- mutation ------------------------------------------------------------ }

procedure EnsureDir(const ADir: string);
begin
  if ADir = '' then
    Exit;
  if PathIsDir(ADir) then
    Exit;
  if PathIsFile(ADir) then
    raise EFsError.CreateFmt('cannot create directory `%s`: a file is in the way', [ADir]);
  if not ForceDirectories(PathWithoutTrailingSep(ADir)) then
    raise EFsError.CreateFmt('failed to create directory `%s`', [ADir]);
end;

function RemoveTree(const APath: string): Boolean;
var
  LNames: TStrArray;
  I: Integer;
begin
  if not PathExists(APath) then
    Exit(True);

  if PathIsFile(APath) then
  begin
    { Read-only files are common in fetched package caches, so clear the flag
      rather than failing on them. }
    FileSetAttr(APath, FileGetAttr(APath) and not faReadOnly);
    Exit(DeleteFile(APath));
  end;

  Result := True;
  LNames := ListFilesIn(APath, '*');
  for I := 0 to High(LNames) do
    Result := RemoveTree(JoinPath(APath, LNames[I])) and Result;
  LNames := ListDirsIn(APath);
  for I := 0 to High(LNames) do
    Result := RemoveTree(JoinPath(APath, LNames[I])) and Result;

  Result := RemoveDir(PathWithoutTrailingSep(APath)) and Result;
end;

{ ---- text files ---------------------------------------------------------- }

{ Decodes AData, which has already been read from disk, honouring a byte order
  mark when one is present. }
function DecodeTextBytes(const AData: string; const APath: string): string;
var
  LWide: UnicodeString;
  LPayload: string;
  LCount, I: Integer;
  LSwap: Char;
begin
  { UTF-8 BOM: keep the bytes, drop the mark. }
  if (Length(AData) >= 3) and (AData[1] = #$EF) and (AData[2] = #$BB) and
     (AData[3] = #$BF) then
    Exit(Copy(AData, 4, MaxInt));

  { UTF-16, little or big endian. Decode to UTF-8 so the rest of Struo only
    ever handles one encoding. }
  if (Length(AData) >= 2) and
     (((AData[1] = #$FF) and (AData[2] = #$FE)) or
      ((AData[1] = #$FE) and (AData[2] = #$FF))) then
  begin
    LCount := (Length(AData) - 2) div 2;
    if LCount = 0 then
      Exit('');
    LPayload := Copy(AData, 3, LCount * 2);

    { Big endian: swap each code unit into host order before decoding. }
    if (AData[1] = #$FE) and (AData[2] = #$FF) then
      for I := 1 to LCount do
      begin
        LSwap := LPayload[I * 2 - 1];
        LPayload[I * 2 - 1] := LPayload[I * 2];
        LPayload[I * 2] := LSwap;
      end;

    SetLength(LWide, LCount);
    Move(LPayload[1], LWide[1], LCount * 2);
    Exit(UTF8Encode(LWide));
  end;

  { A stray NUL in the first bytes means UTF-16 without a BOM. We could guess,
    but a wrong guess corrupts a manifest, so say what we found instead. }
  if (Length(AData) >= 2) and ((AData[1] = #0) or (AData[2] = #0)) then
    raise EFsError.CreateFmt(
      '`%s` looks like UTF-16 but has no byte order mark; save it as UTF-8',
      [APath]);

  Result := AData;
end;

function ReadTextFile(const APath: string): string;
var
  LStream: TFileStream;
  LRaw: string;
begin
  if not PathIsFile(APath) then
    raise EFsError.CreateFmt('no such file: `%s`', [APath]);
  try
    LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  except
    on E: Exception do
      raise EFsError.CreateFmt('failed to open `%s`: %s', [APath, E.Message]);
  end;
  try
    SetLength(LRaw, LStream.Size);
    if LStream.Size > 0 then
      LStream.ReadBuffer(LRaw[1], LStream.Size);
  finally
    LStream.Free;
  end;
  Result := DecodeTextBytes(LRaw, APath);
end;

procedure WriteTextFile(const APath, AContent: string);
var
  LStream: TFileStream;
  LTemp: string;
begin
  EnsureDir(PathWithoutTrailingSep(ExtractFilePath(ExpandFileName(APath))));

  { Write beside the target, on the same volume, so the rename is a cheap
    metadata operation and cannot fail halfway. }
  LTemp := APath + '.struo-tmp';
  try
    LStream := TFileStream.Create(LTemp, fmCreate);
  except
    on E: Exception do
      raise EFsError.CreateFmt('failed to write `%s`: %s', [APath, E.Message]);
  end;
  try
    if AContent <> '' then
      LStream.WriteBuffer(AContent[1], Length(AContent));
  finally
    LStream.Free;
  end;

  { Windows will not rename onto an existing name, so clear the way first. }
  if PathIsFile(APath) then
  begin
    FileSetAttr(APath, FileGetAttr(APath) and not faReadOnly);
    DeleteFile(APath);
  end;
  if not RenameFile(LTemp, APath) then
  begin
    DeleteFile(LTemp);
    raise EFsError.CreateFmt('failed to replace `%s`', [APath]);
  end;
end;

procedure AppendTextLine(const APath, ALine: string);
var
  LExisting: string;
begin
  if PathIsFile(APath) then
    LExisting := ReadTextFile(APath)
  else
    LExisting := '';
  if (LExisting <> '') and not EndsWithStr(LExisting, LineEnding) then
    LExisting := LExisting + LineEnding;
  WriteTextFile(APath, LExisting + ALine + LineEnding);
end;

end.
