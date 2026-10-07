<#
.SYNOPSIS
    Builds Struo from source using a bare Free Pascal install.

.DESCRIPTION
    Struo builds itself, so this script exists only to produce the first
    binary. It finds a Free Pascal compiler, works out where its packaged
    units live, and compiles src/struo.pas into bin/.

    The unit path matters more than it looks. A Free Pascal install without an
    fpc.cfg knows where its RTL is and nothing else, so units from packages
    such as fcl-process are invisible to the compiler. Rather than require the
    user to run fpcmkcfg, this script passes the package unit directory
    explicitly. Struo's own compiler driver does the same thing for the same
    reason.

.PARAMETER Release
    Build optimised and stripped instead of debuggable.

.PARAMETER Tests
    Build and run the test programs in tests/ instead of the binary.

.PARAMETER Clean
    Delete target/ and bin/ and stop.

.PARAMETER Fpc
    Path to a specific fpc executable, overriding discovery.

.EXAMPLE
    ./bootstrap/build.ps1
    Builds bin/struo.exe with debug information.

.EXAMPLE
    ./bootstrap/build.ps1 -Tests
    Builds and runs every test, exiting non-zero if any fails.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Release,
    [switch]$Tests,
    [switch]$Clean,
    [string]$Fpc
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Root = Split-Path -Parent $PSScriptRoot

# ---- output ---------------------------------------------------------------
# Struo's own output style: a right-aligned verb then the detail, so the
# bootstrap looks like the tool it is building.

function Write-Step {
    param([string]$Verb, [string]$Detail, [string]$Color = 'Green')
    Write-Host ("{0,12} " -f $Verb) -ForegroundColor $Color -NoNewline
    Write-Host $Detail
}

function Write-Problem {
    param([string]$Message, [string]$Hint)
    Write-Host 'error: ' -ForegroundColor Red -NoNewline
    Write-Host $Message
    if ($Hint) {
        Write-Host 'hint: ' -ForegroundColor Cyan -NoNewline
        Write-Host $Hint
    }
}

# ---- compiler discovery ---------------------------------------------------

function Resolve-FpcPath {
    param([string]$Explicit)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Explicit) { $candidates.Add($Explicit) }
    if ($env:STRUO_FPC) { $candidates.Add($env:STRUO_FPC) }

    $onPath = Get-Command fpc -ErrorAction SilentlyContinue
    if ($onPath) { $candidates.Add($onPath.Source) }

    # Probe the usual install roots, newest version first. Depth is capped so
    # this cannot turn into a full disk scan.
    foreach ($probe in @('C:\FPC', 'C:\lazarus\fpc', 'C:\lazarus', "$env:ProgramFiles\FPC")) {
        if (-not (Test-Path $probe)) { continue }
        $found = Get-ChildItem -Path $probe -Filter 'fpc.exe' -Recurse -Depth 3 `
                     -File -ErrorAction SilentlyContinue |
                 Sort-Object FullName -Descending
        foreach ($f in $found) { $candidates.Add($f.FullName) }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return (Resolve-Path $candidate).Path
        }
    }
    return $null
}

function Get-FpcInfo {
    param([string]$FpcPath)

    # -iV, -iTP and -iTO each print one line: the version, the CPU and the OS.
    $version = (& $FpcPath -iV 2>$null | Select-Object -First 1).Trim()
    $cpu     = (& $FpcPath -iTP 2>$null | Select-Object -First 1).Trim()
    $os      = (& $FpcPath -iTO 2>$null | Select-Object -First 1).Trim()

    if (-not $version) {
        throw "`"$FpcPath`" did not answer -iV; it may not be a Free Pascal compiler."
    }

    # fpc.exe sits at <base>\bin\<target>\fpc.exe, and its packaged units at
    # <base>\units\<target>\. Walk up two levels to find <base>.
    $binDir  = Split-Path -Parent $FpcPath
    $baseDir = Split-Path -Parent (Split-Path -Parent $binDir)

    [pscustomobject]@{
        Path     = $FpcPath
        Version  = $version
        Target   = "$cpu-$os"
        BaseDir  = $baseDir
        UnitsDir = Join-Path $baseDir "units\$cpu-$os"
    }
}

# ---- compiling ------------------------------------------------------------

function Invoke-Fpc {
    param(
        [pscustomobject]$Info,
        [string]$Source,
        [string]$OutputExe,
        [string]$UnitOutDir,
        [string[]]$SourcePaths
    )

    # Free Pascal does not create its own output directories.
    foreach ($dir in @($UnitOutDir, (Split-Path -Parent $OutputExe))) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    $fpcArgs = @('-Mobjfpc', '-Sh', '-viwn')
    foreach ($p in $SourcePaths) { $fpcArgs += "-Fu$p" }
    if (Test-Path $Info.UnitsDir) { $fpcArgs += "-Fu$($Info.UnitsDir)\*" }
    $fpcArgs += "-FU$UnitOutDir"
    $fpcArgs += "-o$OutputExe"

    if ($Release) {
        # -O3 optimise, -Xs strip, -XX/-CX smart-link so unused units are
        # dropped from the binary.
        $fpcArgs += @('-O3', '-Xs', '-XX', '-CX')
    } else {
        # -gl gives line numbers in a backtrace, which is the whole point of a
        # debug build.
        $fpcArgs += @('-O1', '-g', '-gl')
    }
    $fpcArgs += $Source

    Write-Verbose ("$($Info.Path) " + ($fpcArgs -join ' '))

    # FPC writes diagnostics to stdout. Keep the lines that matter and drop
    # the banner, so a clean build prints nothing.
    $output = & $Info.Path @fpcArgs 2>&1 | Where-Object {
        $_ -notmatch '^(Free Pascal Compiler|Copyright \(c\)|Target OS:|Compiling |Assembling |Linking |\d+ lines compiled)'
    }
    $ok = ($LASTEXITCODE -eq 0)
    if ($output) { $output | ForEach-Object { Write-Host $_ } }
    return $ok
}

# ---- main -----------------------------------------------------------------

if ($Clean) {
    foreach ($dir in @((Join-Path $Root 'target'), (Join-Path $Root 'bin'))) {
        if (Test-Path $dir) {
            Remove-Item -Recurse -Force $dir
            Write-Step 'Removed' (Split-Path -Leaf $dir)
        }
    }
    exit 0
}

$fpcPath = Resolve-FpcPath -Explicit $Fpc
if (-not $fpcPath) {
    Write-Problem 'no Free Pascal compiler found' `
        'install Free Pascal from https://www.freepascal.org/, then put fpc on your PATH or pass -Fpc <path>'
    exit 1
}

try {
    $info = Get-FpcInfo -FpcPath $fpcPath
} catch {
    Write-Problem $_.Exception.Message ''
    exit 1
}

$profileName = if ($Release) { 'release' } else { 'debug' }
Write-Step 'Using' "fpc $($info.Version) $($info.Target) ($($info.Path))" 'Cyan'

if (-not (Test-Path $info.UnitsDir)) {
    Write-Problem "packaged units not found at `"$($info.UnitsDir)`"" `
        'this Free Pascal install looks incomplete; reinstall it with the packages included'
    exit 1
}

$sourcePaths = @(
    (Join-Path $Root 'src'),
    (Join-Path $Root 'src\util'),
    (Join-Path $Root 'src\toml'),
    (Join-Path $Root 'src\core'),
    (Join-Path $Root 'src\cli'),
    (Join-Path $Root 'src\commands')
) | Where-Object { Test-Path $_ }

$binDir = Join-Path $Root 'bin'

if ($Tests) {
    $testDir = Join-Path $Root 'tests'
    $programs = Get-ChildItem -Path $testDir -Filter 'test_*.pas' -File -ErrorAction SilentlyContinue |
                Sort-Object Name
    if (-not $programs) {
        Write-Problem "no test programs found in `"$testDir`"" ''
        exit 1
    }

    $failures = @()
    foreach ($program in $programs) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($program.Name)
        $exe = Join-Path $binDir "$name.exe"
        Write-Step 'Compiling' $name
        $built = Invoke-Fpc -Info $info -Source $program.FullName -OutputExe $exe `
                     -UnitOutDir (Join-Path $Root "target\$profileName\tests") `
                     -SourcePaths ($sourcePaths + @($testDir))
        if (-not $built) {
            $failures += "$name (did not compile)"
            continue
        }

        Write-Step 'Running' $name
        & $exe
        if ($LASTEXITCODE -ne 0) { $failures += $name }
    }

    Write-Host ''
    if ($failures.Count -gt 0) {
        Write-Problem ("test suites failed: " + ($failures -join ', ')) ''
        exit 1
    }
    Write-Step 'Finished' 'all test suites passed'
    exit 0
}

$mainSource = Join-Path $Root 'src\struo.pas'
if (-not (Test-Path $mainSource)) {
    Write-Problem "`"$mainSource`" does not exist yet" `
        'run ./bootstrap/build.ps1 -Tests to build and run the test suites instead'
    exit 1
}

Write-Step 'Compiling' "struo ($profileName)"
$exePath = Join-Path $binDir 'struo.exe'
$built = Invoke-Fpc -Info $info -Source $mainSource -OutputExe $exePath `
             -UnitOutDir (Join-Path $Root "target\$profileName\bootstrap") `
             -SourcePaths $sourcePaths
if (-not $built) {
    Write-Problem 'struo did not compile' ''
    exit 1
}

$sizeKb = [math]::Round((Get-Item $exePath).Length / 1KB)
Write-Step 'Finished' "$profileName profile -> bin\struo.exe (${sizeKb} KB)"
Write-Step 'Next' "add `"$binDir`" to your PATH, then run: struo --version" 'Cyan'
