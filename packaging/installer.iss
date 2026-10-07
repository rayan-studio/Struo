; Inno Setup script for the Struo Windows installer.
;
; Compiled by packaging/release.ps1 and by the release workflow, from a staged
; directory that release.ps1 has already assembled and verified:
;
;   ISCC.exe /DStruoVersion=0.1.0 /DStruoTarget=x86_64-win64 ^
;            /DStageDir=..\dist\struo-0.1.0-x86_64-win64 installer.iss
;
; Two decisions here are deliberate and worth not undoing by accident.
;
; A per-user install by default, into %LOCALAPPDATA%, rather than Program
; Files. `struo self-update` replaces the binary and the toolchain in place,
; and it can only do that if the install directory is writable by the person
; running it. A Program Files install would make every update need elevation,
; which is a worse trade than not appearing in a machine-wide location. Anyone
; who wants that can still choose it: PrivilegesRequiredOverridesAllowed puts
; the question to them.
;
; And the whole bundle in one directory, binary and toolchain together, for
; the same reason: self-update swaps them as a pair.

#ifndef StruoVersion
  #define StruoVersion "0.0.0"
#endif
#ifndef StruoTarget
  #define StruoTarget "unknown"
#endif
#ifndef StageDir
  #define StageDir "..\dist"
#endif

#define StruoName "Struo"
#define StruoPublisher "Struo contributors"
#define StruoUrl "https://github.com/rayan-studio/Struo"

[Setup]
AppId={{B4F2A6D1-7C3E-4A58-9E21-5D8F0C6B1A74}
AppName={#StruoName}
AppVersion={#StruoVersion}
AppVerName={#StruoName} {#StruoVersion}
AppPublisher={#StruoPublisher}
AppPublisherURL={#StruoUrl}
AppSupportURL={#StruoUrl}/issues
AppUpdatesURL={#StruoUrl}/releases
VersionInfoVersion={#StruoVersion}

; Per-user by default; the dialog lets someone choose machine-wide instead.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
DefaultDirName={autopf}\{#StruoName}
DefaultGroupName={#StruoName}
DisableProgramGroupPage=yes
AllowNoIcons=yes

; The toolchain is the bulk of this, and it is already compressed as little as
; .ppu and .o files allow; lzma2/max is what gets it back down.
Compression=lzma2/max
SolidCompression=yes
LZMANumBlockThreads=2

OutputDir=..\dist
OutputBaseFilename=struo-{#StruoVersion}-{#StruoTarget}-setup
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#StruoName} {#StruoVersion}
LicenseFile={#StageDir}\LICENSE

; Struo is a command-line tool, so there is nothing to launch and no reason to
; make someone click through pages about it.
DisableWelcomePage=no
DisableReadyPage=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "addtopath"; Description: "Add Struo to my PATH (recommended)"; \
  GroupDescription: "Set up the command line:"

[Files]
; The staged directory has already been verified by release.ps1: its toolchain
; compiled, linked and ran a test program before this installer was built.
Source: "{#StageDir}\struo.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion isreadme
Source: "{#StageDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\THIRD-PARTY.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\toolchain\*"; DestDir: "{app}\toolchain"; \
  Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#StruoName} on GitHub"; Filename: "{#StruoUrl}"
Name: "{group}\Uninstall {#StruoName}"; Filename: "{uninstallexe}"

[Registry]
; Appended by the Pascal code below rather than declared here, because Inno's
; declarative PATH handling would duplicate the entry on reinstall.

[Run]
; Prove the install works before telling anyone it finished. Same check the
; release script ran against the staged directory, now against what actually
; landed on this machine.
Filename: "{app}\struo.exe"; Parameters: "toolchain --verify"; \
  Description: "Verify the bundled Free Pascal toolchain"; \
  StatusMsg: "Verifying the bundled toolchain..."; \
  Flags: runhidden

[Code]
const
  { Appending to this rather than to the machine-wide one, to match a
    per-user install. }
  CUserEnvironmentKey = 'Environment';

{ The registry root this install is writing to: per-user or machine-wide,
  depending on what the person chose. }
function EnvironmentRoot: Integer;
begin
  if IsAdminInstallMode then
    Result := HKEY_LOCAL_MACHINE
  else
    Result := HKEY_CURRENT_USER;
end;

function EnvironmentKey: string;
begin
  if IsAdminInstallMode then
    Result := 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  else
    Result := CUserEnvironmentKey;
end;

{ True when ADirectory is already one of the entries in APath. Compared
  whole-entry and case-insensitively, so `C:\Struo` does not match
  `C:\Struo-old` and a reinstall does not add a second copy. }
function PathContains(const APath, ADirectory: string): Boolean;
var
  LHaystack, LNeedle: string;
begin
  LHaystack := ';' + Uppercase(APath) + ';';
  LHaystack := StringChange(LHaystack, '\;', ';');
  LNeedle := ';' + Uppercase(ADirectory) + ';';
  Result := Pos(LNeedle, LHaystack) > 0;
end;

procedure AddToPath(const ADirectory: string);
var
  LPath: string;
begin
  if not RegQueryStringValue(EnvironmentRoot, EnvironmentKey, 'Path', LPath) then
    LPath := '';

  if PathContains(LPath, ADirectory) then
    Exit;

  if (LPath <> '') and (Copy(LPath, Length(LPath), 1) <> ';') then
    LPath := LPath + ';';

  RegWriteExpandStringValue(EnvironmentRoot, EnvironmentKey, 'Path',
    LPath + ADirectory);
end;

procedure RemoveFromPath(const ADirectory: string);
var
  LPath, LRebuilt, LEntry: string;
  LPos: Integer;
begin
  if not RegQueryStringValue(EnvironmentRoot, EnvironmentKey, 'Path', LPath) then
    Exit;

  { Rebuilt entry by entry rather than by string surgery, so a trailing
    separator or an empty entry cannot corrupt the rest of someone's PATH. }
  LRebuilt := '';
  LPath := LPath + ';';
  repeat
    LPos := Pos(';', LPath);
    LEntry := Trim(Copy(LPath, 1, LPos - 1));
    LPath := Copy(LPath, LPos + 1, Length(LPath));
    if (LEntry <> '') and
       (CompareText(RemoveBackslashUnlessRoot(LEntry),
                    RemoveBackslashUnlessRoot(ADirectory)) <> 0) then
    begin
      if LRebuilt <> '' then
        LRebuilt := LRebuilt + ';';
      LRebuilt := LRebuilt + LEntry;
    end;
  until LPath = '';

  RegWriteExpandStringValue(EnvironmentRoot, EnvironmentKey, 'Path', LRebuilt);
end;

procedure CurStepChanged(ACurStep: TSetupStep);
begin
  if (ACurStep = ssPostInstall) and WizardIsTaskSelected('addtopath') then
    AddToPath(ExpandConstant('{app}'));
end;

procedure CurUninstallStepChanged(ACurStep: TUninstallStep);
begin
  { Only the PATH entry. ~/.struo holds the dependency cache and the user's
    registry token; removing it on uninstall would throw away work that has
    nothing to do with this binary. }
  if ACurStep = usPostUninstall then
    RemoveFromPath(ExpandConstant('{app}'));
end;
