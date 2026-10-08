#!/bin/sh
# Assembles a Struo release archive with Free Pascal bundled inside it.
#
# The POSIX counterpart of release.ps1. The archive layout is the same, and is
# what Struo.Paths.BundledToolchainRoots expects:
#
#   struo-0.1.0-x86_64-linux/
#   |-- struo
#   |-- README.md
#   |-- LICENSE            MIT, Struo itself
#   |-- THIRD-PARTY.md     GPL/LGPL, the bundled Free Pascal
#   |-- install.sh
#   `-- toolchain/
#       |-- bin/<target>/  fpc driver + the ppc<arch> compiler
#       |-- units/<target>/
#       `-- msg/
#
# One difference from Windows matters. A Windows Free Pascal install keeps
# everything under one root, so release.ps1 copies it. A Unix package spreads
# it out -- the driver in /usr/bin, the compiler and units under
# /usr/lib/fpc/<version> -- so this script builds the bundled layout instead of
# copying one. `fpc -PB` is what it asks for the compiler binary's real path.
#
# A Unix toolchain also still needs the system assembler and linker: unlike the
# Windows distribution, Free Pascal on Unix uses the binutils `as` and `ld`
# that are already there. The archive therefore depends on binutils, which
# README and docs/toolchain.md both say. Bundling them would mean shipping an
# ABI-sensitive linker, which is a worse trade than one apt line.
#
# Usage:
#   ./packaging/release.sh                 core toolchain, .tar.gz in dist/
#   ./packaging/release.sh --full          every unit package
#   ./packaging/release.sh --skip-archive  stage only, for testing this script
#   ./packaging/release.sh --fpc <path>    use a specific compiler

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

FULL=no
SKIP_ARCHIVE=no
FPC_OVERRIDE=${STRUO_FPC:-}
VERSION=''

while [ $# -gt 0 ]; do
    case "$1" in
        --full)          FULL=yes ;;
        --skip-archive)  SKIP_ARCHIVE=yes ;;
        --fpc)           shift; FPC_OVERRIDE=${1:-} ;;
        --version)       shift; VERSION=${1:-} ;;
        -h|--help)       sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'error: unknown option `%s`\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

# The unit packages a Struo release carries. Keep this in step with
# $CoreUnitPackages in release.ps1 and with the table in docs/toolchain.md:
# all three describe the same promise to package authors.
CORE_PACKAGES='rtl rtl-objpas rtl-extra rtl-console rtl-unicode rtl-generics
fcl-base fcl-process fcl-json fcl-xml fcl-net fcl-res fcl-registry fcl-extra
fcl-stl fcl-fpcunit fpmkunit hash regexpr paszlib zlib openssl'

# ---- output ---------------------------------------------------------------

if [ -t 1 ]; then
    C_VERB=$(printf '\033[1;32m'); C_INFO=$(printf '\033[1;36m')
    C_ERR=$(printf '\033[1;31m');  C_WARN=$(printf '\033[1;33m')
    C_OFF=$(printf '\033[0m')
else
    C_VERB=''; C_INFO=''; C_ERR=''; C_WARN=''; C_OFF=''
fi

step()    { printf '%s%12s%s %s\n' "$C_VERB" "$1" "$C_OFF" "$2"; }
info()    { printf '%s%12s%s %s\n' "$C_INFO" "$1" "$C_OFF" "$2"; }
warn()    { printf '%swarning:%s %s\n' "$C_WARN" "$C_OFF" "$1" >&2; }
problem() {
    printf '%serror:%s %s\n' "$C_ERR" "$C_OFF" "$1" >&2
    [ -n "${2:-}" ] && printf '%shint:%s %s\n' "$C_INFO" "$C_OFF" "$2" >&2
    return 0
}

size_mb() {
    # du reports in KiB with -k everywhere, which POSIX guarantees.
    printf '%s MB' "$(( $(du -sk "$1" | cut -f1) / 1024 ))"
}

# ---- inputs ---------------------------------------------------------------

# The version lives in one place in the source. Reading it keeps an archive
# from claiming a version the binary inside does not report.
if [ -z "$VERSION" ]; then
    VERSION=$(sed -n "s/.*CStruoVersion *= *'\([^']*\)'.*/\1/p" \
        "$ROOT/src/core/Struo.Types.pas" | head -1)
fi
if [ -z "$VERSION" ]; then
    problem 'could not read CStruoVersion from src/core/Struo.Types.pas' ''
    exit 1
fi

if [ -n "$FPC_OVERRIDE" ] && [ -x "$FPC_OVERRIDE" ]; then
    FPC=$FPC_OVERRIDE
elif command -v fpc >/dev/null 2>&1; then
    FPC=$(command -v fpc)
else
    problem 'no Free Pascal compiler found' 'pass --fpc <path>'
    exit 1
fi

FPC_VERSION=$("$FPC" -iV 2>/dev/null | head -1 | tr -d ' \r')
FPC_CPU=$("$FPC" -iTP 2>/dev/null | head -1 | tr -d ' \r')
FPC_OS=$("$FPC" -iTO 2>/dev/null | head -1 | tr -d ' \r')
TARGET="$FPC_CPU-$FPC_OS"

if [ -z "$FPC_VERSION" ]; then
    problem "\`$FPC\` did not answer -iV; it may not be a Free Pascal compiler" ''
    exit 1
fi

# -PB prints the real path of the code generator, which on a Unix package is
# nowhere near the driver. Asking is more reliable than guessing.
PPC=$("$FPC" -PB 2>/dev/null | head -1 | tr -d '\r')
if [ ! -x "$PPC" ]; then
    problem "could not locate the compiler binary (fpc -PB said \"$PPC\")" \
        'the Free Pascal install looks incomplete'
    exit 1
fi

# Where the packaged units are. There is no single answer: an upstream install
# keeps them under the compiler root, while Debian and Ubuntu put the whole
# thing under a multiarch directory -- /usr/lib/x86_64-linux-gnu/fpc/<version>
# -- and leave only a versioned alias on PATH. So try the landmarks, then ask
# the filesystem, and if even that fails say what was tried: a packaging script
# that guesses in silence costs a round trip through CI to learn anything.
FPC_BIN_DIR=$(dirname -- "$FPC")
FPC_BASE=$(dirname -- "$FPC_BIN_DIR")

# The alias on PATH is a symlink into the real install, so follow it before
# using the code generator as a landmark.
PPC_REAL=$(readlink -f -- "$PPC" 2>/dev/null || true)
[ -n "$PPC_REAL" ] || PPC_REAL=$PPC
PPC_BASE=$(dirname -- "$PPC_REAL")

UNITS_SOURCE=''
TRIED=''
for candidate in \
    "$PPC_BASE/units/$TARGET" \
    "$FPC_BASE/units/$TARGET" \
    "$FPC_BASE/lib/fpc/$FPC_VERSION/units/$TARGET" \
    "/usr/lib/fpc/$FPC_VERSION/units/$TARGET" \
    "/usr/local/lib/fpc/$FPC_VERSION/units/$TARGET"; do
    if [ -d "$candidate" ]; then UNITS_SOURCE=$candidate; break; fi
    TRIED="$TRIED
  $candidate"
done

# None of the known layouts. A distribution is free to invent another one, and
# one find is cheaper than another red build.
if [ -z "$UNITS_SOURCE" ]; then
    UNITS_SOURCE=$(find /usr/lib /usr/lib64 /usr/local/lib -maxdepth 7 \
        -type d -path "*/fpc/*/units/$TARGET" 2>/dev/null | head -1 || true)
fi

if [ -z "$UNITS_SOURCE" ]; then
    problem "could not find the packaged units for $TARGET" \
        'the Free Pascal install looks incomplete'
    printf 'fpc:     %s\n' "$FPC" >&2
    printf 'fpc -PB: %s -> %s\n' "$PPC" "$PPC_REAL" >&2
    printf 'tried:%s\n' "$TRIED" >&2
    exit 1
fi

# Everything else Free Pascal ships sits beside the unit tree, so derive it
# from what was actually found rather than guessing a second time.
UNITS_BASE=$(dirname -- "$(dirname -- "$UNITS_SOURCE")")

info Packaging "struo $VERSION for $TARGET"
info Toolchain "fpc $FPC_VERSION ($PPC)"

# The assembler and linker come from binutils on Unix, so an archive built
# without them present would pass its own verification and then fail for a
# user who has them. Check now and say so.
for tool in as ld; do
    command -v "$tool" >/dev/null 2>&1 || warn \
        "\`$tool\` is not on PATH; the bundled toolchain needs binutils to link"
done

# ---- build ----------------------------------------------------------------

step Building 'struo (release)'
"$ROOT/bootstrap/build.sh" --release

STAGE_NAME="struo-$VERSION-$TARGET"
DIST="$ROOT/dist"
STAGE="$DIST/$STAGE_NAME"

rm -rf "$STAGE"
mkdir -p "$STAGE"

cp "$ROOT/bin/struo" "$STAGE/struo"
chmod +x "$STAGE/struo"
for doc in README.md LICENSE THIRD-PARTY.md; do
    [ -f "$ROOT/$doc" ] && cp "$ROOT/$doc" "$STAGE/"
done
[ -f "$ROOT/packaging/install.sh" ] && {
    cp "$ROOT/packaging/install.sh" "$STAGE/install.sh"
    chmod +x "$STAGE/install.sh"
}

# ---- the toolchain --------------------------------------------------------

TC="$STAGE/toolchain"
mkdir -p "$TC/bin/$TARGET" "$TC/units/$TARGET"

# The driver and the code generator, side by side: the driver looks for the
# generator in its own directory first, which is what makes this layout work
# wherever the archive is unpacked.
cp "$FPC" "$TC/bin/$TARGET/fpc"
cp "$PPC" "$TC/bin/$TARGET/$(basename -- "$PPC")"
chmod +x "$TC/bin/$TARGET/fpc" "$TC/bin/$TARGET/$(basename -- "$PPC")"

# Anything else Free Pascal keeps beside the generator, minus a configuration
# file, which would pin this build machine's absolute paths into the archive.
PPC_DIR=$(dirname -- "$PPC")
if [ "$PPC_DIR" != "$TC/bin/$TARGET" ]; then
    for f in "$PPC_DIR"/*; do
        [ -f "$f" ] || continue
        case "$(basename -- "$f")" in
            *.cfg) continue ;;
            fpc|"$(basename -- "$PPC")") continue ;;
        esac
        cp "$f" "$TC/bin/$TARGET/" 2>/dev/null || true
    done
fi
step Copied "toolchain/bin/$TARGET ($(size_mb "$TC/bin"))"

if [ "$FULL" = yes ]; then
    cp -R "$UNITS_SOURCE"/* "$TC/units/$TARGET/"
    step Copied "toolchain/units/$TARGET, every package ($(size_mb "$TC/units"))"
else
    COPIED=0
    MISSING=''
    for package in $CORE_PACKAGES; do
        if [ -d "$UNITS_SOURCE/$package" ]; then
            cp -R "$UNITS_SOURCE/$package" "$TC/units/$TARGET/"
            COPIED=$((COPIED + 1))
        else
            MISSING="$MISSING $package"
        fi
    done
    step Copied "toolchain/units/$TARGET, $COPIED core packages ($(size_mb "$TC/units"))"
    [ -n "$MISSING" ] && warn "not in this Free Pascal install:$MISSING"
fi

# Message files are small, and without them diagnostics come out as
# placeholders rather than sentences.
for msgdir in "$UNITS_BASE/msg" "$PPC_BASE/msg" "$FPC_BASE/msg" \
              "/usr/lib/fpc/$FPC_VERSION/msg" \
              "/usr/share/fpcsrc/$FPC_VERSION/msg"; do
    if [ -d "$msgdir" ]; then cp -R "$msgdir" "$TC/msg"; break; fi
done

# ---- prove it works -------------------------------------------------------
# An archive that unpacks and then cannot compile is worse than no archive, so
# the staged binary is made to use the staged toolchain before anything is
# compressed. Overrides are cleared first: STRUO_FPC pointing at the build
# machine's compiler would make this pass for the wrong reason.

step Checking 'the staged toolchain'
STRUO_FPC='' STRUO_TOOLCHAIN='' "$STAGE/struo" toolchain > "$DIST/.toolchain-report" 2>&1 || true
if ! grep -q 'bundled' "$DIST/.toolchain-report"; then
    problem 'the staged struo did not pick up the bundled toolchain' \
        "it reported: $(cat "$DIST/.toolchain-report")"
    exit 1
fi
rm -f "$DIST/.toolchain-report"

if ! STRUO_FPC='' STRUO_TOOLCHAIN='' "$STAGE/struo" toolchain --verify; then
    problem 'the bundled toolchain cannot compile' \
        'the archive would not work; see the diagnostics above'
    exit 1
fi

step Staged "$STAGE ($(size_mb "$STAGE"))"

if [ "$SKIP_ARCHIVE" = yes ]; then
    step Finished 'staged only, as asked'
    exit 0
fi

# ---- archive --------------------------------------------------------------

ARCHIVE="$DIST/$STAGE_NAME.tar.gz"
rm -f "$ARCHIVE"
# From inside dist/, so the tarball holds one directory rather than a path.
(cd "$DIST" && tar -czf "$STAGE_NAME.tar.gz" "$STAGE_NAME")

step Finished "dist/$STAGE_NAME.tar.gz ($(size_mb "$ARCHIVE"))"
