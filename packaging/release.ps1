<#
.SYNOPSIS
    Assembles a Struo release archive with Free Pascal bundled inside it.

.DESCRIPTION
    Struo ships its own compiler, so a user downloads one archive, unpacks it,
    and `struo build` works. Nothing to install, no PATH to arrange, and
    everyone on a given Struo release compiles with the same compiler.

    The archive looks like this, and the layout is what Struo's toolchain
    discovery expects (see Struo.Paths.BundledToolchainRoots):

        struo-0.1.0-i386-win32/
        |-- struo.exe
        |-- README.md
        |-- LICENSE            MIT, Struo itself
        |-- THIRD-PARTY.md     GPL/LGPL, the bundled Free Pascal
        `-- toolchain/
            |-- bin/<target>/  fpc, ppc<arch>, as, ld, ar, strip, windres
            |-- units/<target>/
            `-- msg/

    Two things are deliberately left out of toolchain/:

    * fpc.cfg. A configuration file written on the build machine carries that
      machine's absolute paths, so copying it would produce an archive that
      only works on the machine it was built on. Struo passes every search
      path itself and runs a bundled toolchain with -n, which tells fpc to
      read no configuration at all. That also makes the bundled compiler
      immune to an unrelated fpc.cfg sitting elsewhere on the user's machine.

    * gdb, the Free Vision IDE, fpdoc and fppkg. Struo does not invoke them,
      and together they are a third of bin/.

    By default the unit tree is the curated core listed in $CoreUnitPackages:
    27 MB compressed rather than 69 MB, because googleapi, winunits-jedi and
    odata alone are 42% of a full unit tree and almost no Pascal package needs
    them. Pass -Full to include everything.

.PARAMETER Version
    The version to stamp on the archive. Defaults to the version in src.

.PARAMETER FpcRoot
    The Free Pascal installation to copy from. Defaults to the compiler the
    bootstrap script would use.

.PARAMETER Full
    Bundle every unit package instead of the curated core.

.PARAMETER SkipArchive
    Stage the directory but do not zip it. Useful when testing this script.

.EXAMPLE
    ./packaging/release.ps1
    Produces dist/struo-0.1.0-i386-win32.zip with the core toolchain.

.EXAMPLE
    ./packaging/release.ps1 -Full -FpcRoot C:\FPC\3.2.2
    Produces an archive with every unit package Free Pascal ships.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Version,
    [string]$FpcRoot,
    [switch]$Full,
    [switch]$SkipArchive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Root = Split-Path -Parent $PSScriptRoot

# The unit packages a Struo package can expect to find in a release. Anything
# here is `uses`-able out of the box; anything not needs -Full, or the user
# pointing STRUO_TOOLCHAIN at a complete Free Pascal install. Keep
# docs/toolchain.md in step with this list.
$CoreUnitPackages = @(
    # The language itself.
    'rtl', 'rtl-objpas', 'rtl-extra', 'rtl-console', 'rtl-unicode',
    'rtl-generics',
    # The Free Component Library pieces a command-line package actually uses.
    'fcl-base', 'fcl-process', 'fcl-json', 'fcl-xml', 'fcl-net', 'fcl-res',
    'fcl-registry', 'fcl-extra', 'fcl-stl', 'fcl-fpcunit',
    # Build support, compression, crypto, and the Windows API headers.
    'fpmkunit', 'hash', 'regexpr', 'paszlib', 'zlib', 'openssl',
    'winunits-base'
)

# Tools in bin/ that Struo never invokes.
$ExcludedTools = @('gdb.exe', 'fp.exe', 'fpdoc.exe', 'fppkg.exe', 'ide.exe')

# ---- output ---------------------------------------------------------------

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

# Windows PowerShell 5.1 turns a native command's stderr into a terminating
# error while $ErrorActionPreference is 'Stop', even when the command exits
# zero. Struo writes its progress to stderr by design, so every struo call
# here has to opt out of that and judge the result by exit code instead.
function Invoke-Native {
    param(
        [string]$Exe,
        [string[]]$Arguments = @(),
        [switch]$Capture
    )
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Capture) {
            $text = (& $Exe @Arguments 2>&1 | Out-String)
        } else {
            & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
            $text = ''
        }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $text }
    } finally {
        $ErrorActionPreference = $saved
    }
}

function Get-SizeMb {
    param([string]$Path)
    if (Test-Path -PathType Container $Path) {
        $bytes = (Get-ChildItem -Recurse -File $Path |
                  Measure-Object -Property Length -Sum).Sum
    } else {
        $bytes = (Get-Item $Path).Length
    }
    if (-not $bytes) { return 0 }
    return [math]::Round($bytes / 1MB, 1)
}

# ---- inputs ---------------------------------------------------------------

# The version lives in one place in the source; read it rather than letting an
# archive claim a version the binary does not report.
function Get-StruoVersion {
    $typesFile = Join-Path $Root 'src\core\Struo.Types.pas'
    $line = Select-String -Path $typesFile -Pattern "CStruoVersion\s*=\s*'([^']+)'" |
            Select-Object -First 1
    if (-not $line) {
        throw "could not read CStruoVersion from `"$typesFile`""
    }
    return $line.Matches[0].Groups[1].Value
}

function Resolve-FpcRoot {
    param([string]$Explicit)

    if ($Explicit) {
        if (-not (Test-Path $Explicit)) {
            throw "`"$Explicit`" does not exist"
        }
        return (Resolve-Path $Explicit).Path
    }

    # Walk up from whichever fpc the bootstrap would use: it sits at
    # <root>/bin/<target>/fpc.exe.
    $onPath = Get-Command fpc -ErrorAction SilentlyContinue
    if ($onPath) {
        $binDir = Split-Path -Parent $onPath.Source
        return Split-Path -Parent (Split-Path -Parent $binDir)
    }

    foreach ($probe in @('C:\FPC', 'C:\lazarus\fpc')) {
        if (-not (Test-Path $probe)) { continue }
        $found = Get-ChildItem -Path $probe -Filter 'fpc.exe' -Recurse -Depth 3 `
                     -File -ErrorAction SilentlyContinue |
                 Sort-Object FullName -Descending | Select-Object -First 1
        if ($found) {
            $binDir = Split-Path -Parent $found.FullName
            return Split-Path -Parent (Split-Path -Parent $binDir)
        }
    }
    throw 'no Free Pascal installation found; pass -FpcRoot <path>'
}

# ---- staging --------------------------------------------------------------

function Copy-Toolchain {
    param(
        [string]$FpcRoot,
        [string]$Destination,
        [string]$Target
    )

    $binSource = Join-Path $FpcRoot "bin\$Target"
    if (-not (Test-Path $binSource)) {
        # An install may name the directory with different capitalisation than
        # fpc reports its target in.
        $binSource = Get-ChildItem -Path (Join-Path $FpcRoot 'bin') -Directory |
                     Where-Object { $_.Name -ieq $Target } |
                     Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $binSource -or -not (Test-Path $binSource)) {
        throw "no bin directory for target `"$Target`" under `"$FpcRoot`""
    }

    $binDest = Join-Path $Destination "bin\$Target"
    New-Item -ItemType Directory -Path $binDest -Force | Out-Null

    Get-ChildItem -Path $binSource -File | Where-Object {
        # A configuration file from this machine would pin its absolute paths
        # into the archive, so it never travels.
        ($_.Extension -ne '.cfg') -and ($ExcludedTools -notcontains $_.Name)
    } | ForEach-Object {
        Copy-Item $_.FullName -Destination $binDest
    }
    Write-Step 'Copied' "toolchain\bin\$Target ($(Get-SizeMb $binDest) MB)"

    $unitsSource = Join-Path $FpcRoot "units\$Target"
    if (-not (Test-Path $unitsSource)) {
        throw "no units directory for target `"$Target`" under `"$FpcRoot`""
    }
    $unitsDest = Join-Path $Destination "units\$Target"
    New-Item -ItemType Directory -Path $unitsDest -Force | Out-Null

    if ($Full) {
        Copy-Item -Path (Join-Path $unitsSource '*') -Destination $unitsDest -Recurse
        Write-Step 'Copied' "toolchain\units\$Target, every package ($(Get-SizeMb $unitsDest) MB)"
    } else {
        $missing = @()
        foreach ($package in $CoreUnitPackages) {
            $from = Join-Path $unitsSource $package
            if (-not (Test-Path $from)) { $missing += $package; continue }
            Copy-Item -Path $from -Destination $unitsDest -Recurse
        }
        Write-Step 'Copied' ("toolchain\units\$Target, $($CoreUnitPackages.Count - $missing.Count) " +
                             "core packages ($(Get-SizeMb $unitsDest) MB)")
        if ($missing.Count -gt 0) {
            # Not fatal, but the archive will be missing something the core
            # list promised, so say which.
            Write-Host 'warning: ' -ForegroundColor Yellow -NoNewline
            Write-Host "not in this Free Pascal install: $($missing -join ', ')"
        }
    }

    # Message files are small and their absence produces diagnostics with
    # placeholder text instead of sentences.
    $msgSource = Join-Path $FpcRoot 'msg'
    if (Test-Path $msgSource) {
        Copy-Item -Path $msgSource -Destination (Join-Path $Destination 'msg') -Recurse
    }
}

# ---- main -----------------------------------------------------------------

if (-not $Version) { $Version = Get-StruoVersion }
$fpcRootResolved = Resolve-FpcRoot -Explicit $FpcRoot

$fpcExe = Get-ChildItem -Path (Join-Path $fpcRootResolved 'bin') -Filter 'fpc.exe' `
              -Recurse -Depth 2 -File -ErrorAction SilentlyContinue |
          Select-Object -First 1
if (-not $fpcExe) {
    Write-Problem "no fpc.exe under `"$fpcRootResolved\bin`"" 'pass -FpcRoot <path>'
    exit 1
}

$fpcVersion = (& $fpcExe.FullName -iV).Trim()
$target = "$((& $fpcExe.FullName -iTP).Trim())-$((& $fpcExe.FullName -iTO).Trim())"

Write-Step 'Packaging' "struo $Version for $target" 'Cyan'
Write-Step 'Toolchain' "fpc $fpcVersion from $fpcRootResolved" 'Cyan'

# Build the binary that goes in the archive. Release profile: this is the one
# people download.
Write-Step 'Building' 'struo (release)'
& (Join-Path $Root 'bootstrap\build.ps1') -Release
if ($LASTEXITCODE -ne 0) {
    Write-Problem 'struo did not build' ''
    exit 1
}

$stageName = "struo-$Version-$target"
$distDir = Join-Path $Root 'dist'
$stageDir = Join-Path $distDir $stageName

if (Test-Path $stageDir) { Remove-Item -Recurse -Force $stageDir }
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

Copy-Item (Join-Path $Root 'bin\struo.exe') -Destination $stageDir
foreach ($doc in @('README.md', 'LICENSE', 'THIRD-PARTY.md')) {
    $from = Join-Path $Root $doc
    if (Test-Path $from) { Copy-Item $from -Destination $stageDir }
}

Copy-Toolchain -FpcRoot $fpcRootResolved `
               -Destination (Join-Path $stageDir 'toolchain') `
               -Target $target

# ---- prove it works -------------------------------------------------------
# An archive that unpacks and then cannot compile is worse than no archive, so
# the staged binary is made to use the staged toolchain before anything is
# zipped. The environment is cleared of overrides first: STRUO_FPC pointing at
# the build machine's compiler would make this pass for the wrong reason.

Write-Step 'Checking' 'the staged toolchain'
$savedFpc = $env:STRUO_FPC
$savedToolchain = $env:STRUO_TOOLCHAIN
$env:STRUO_FPC = ''
$env:STRUO_TOOLCHAIN = ''
try {
    $stagedStruo = Join-Path $stageDir 'struo.exe'

    $report = Invoke-Native -Exe $stagedStruo -Arguments @('toolchain') -Capture
    if ($report.Output -notmatch 'bundled') {
        Write-Problem 'the staged struo did not pick up the bundled toolchain' `
            "it reported:`n$($report.Output)"
        exit 1
    }

    $verify = Invoke-Native -Exe $stagedStruo -Arguments @('toolchain', '--verify')
    if ($verify.ExitCode -ne 0) {
        Write-Problem 'the bundled toolchain cannot compile' `
            'the archive would not work; see the diagnostics above'
        exit 1
    }
} finally {
    $env:STRUO_FPC = $savedFpc
    $env:STRUO_TOOLCHAIN = $savedToolchain
}

Write-Step 'Staged' "$stageDir ($(Get-SizeMb $stageDir) MB)"

if ($SkipArchive) {
    Write-Step 'Finished' 'staged only, as asked'
    exit 0
}

$zipPath = Join-Path $distDir "$stageName.zip"
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Compress-Archive -Path $stageDir -DestinationPath $zipPath -CompressionLevel Optimal

Write-Step 'Finished' "dist\$stageName.zip ($(Get-SizeMb $zipPath) MB)"
