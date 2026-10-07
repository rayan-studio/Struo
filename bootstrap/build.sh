#!/bin/sh
# Builds Struo from source using a bare Free Pascal install.
#
# The POSIX counterpart of build.ps1. See that file for why the unit path is
# passed explicitly rather than left to fpc.cfg: an install without a config
# can locate its RTL and nothing else, so units from packages such as
# fcl-process would be invisible.
#
# Usage:
#   ./bootstrap/build.sh              build bin/struo with debug information
#   ./bootstrap/build.sh --release    build optimised and stripped
#   ./bootstrap/build.sh --tests      build and run every test program
#   ./bootstrap/build.sh --clean      delete target/ and bin/
#
# Set STRUO_FPC to choose a compiler, or pass --fpc <path>.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

PROFILE=debug
MODE=binary
FPC_OVERRIDE=${STRUO_FPC:-}

while [ $# -gt 0 ]; do
    case "$1" in
        --release) PROFILE=release ;;
        --tests)   MODE=tests ;;
        --clean)   MODE=clean ;;
        --fpc)     shift; FPC_OVERRIDE=${1:-} ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'error: unknown option `%s`\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

# ---- output ---------------------------------------------------------------
# Struo's own output style: a right-aligned verb then the detail.

if [ -t 1 ]; then
    C_VERB=$(printf '\033[1;32m'); C_INFO=$(printf '\033[1;36m')
    C_ERR=$(printf '\033[1;31m');  C_OFF=$(printf '\033[0m')
else
    C_VERB=''; C_INFO=''; C_ERR=''; C_OFF=''
fi

step()    { printf '%s%12s%s %s\n' "$C_VERB" "$1" "$C_OFF" "$2"; }
info()    { printf '%s%12s%s %s\n' "$C_INFO" "$1" "$C_OFF" "$2"; }
problem() {
    printf '%serror:%s %s\n' "$C_ERR" "$C_OFF" "$1" >&2
    [ -n "${2:-}" ] && printf '%shint:%s %s\n' "$C_INFO" "$C_OFF" "$2" >&2
    return 0
}

if [ "$MODE" = clean ]; then
    for dir in "$ROOT/target" "$ROOT/bin"; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
            step Removed "$(basename "$dir")"
        fi
    done
    exit 0
fi

# ---- compiler discovery ---------------------------------------------------

find_fpc() {
    if [ -n "$FPC_OVERRIDE" ] && [ -x "$FPC_OVERRIDE" ]; then
        printf '%s\n' "$FPC_OVERRIDE"
        return 0
    fi
    if command -v fpc >/dev/null 2>&1; then
        command -v fpc
        return 0
    fi
    # Probe the usual install roots, newest version first.
    for probe in /usr/local/bin/fpc /opt/fpc/bin/fpc "$HOME/.fpc/bin/fpc"; do
        [ -x "$probe" ] && { printf '%s\n' "$probe"; return 0; }
    done
    return 1
}

FPC=$(find_fpc) || {
    problem 'no Free Pascal compiler found' \
        'install Free Pascal from https://www.freepascal.org/, then put fpc on your PATH or pass --fpc <path>'
    exit 1
}

FPC_VERSION=$("$FPC" -iV 2>/dev/null | head -1 | tr -d ' \r')
FPC_CPU=$("$FPC" -iTP 2>/dev/null | head -1 | tr -d ' \r')
FPC_OS=$("$FPC" -iTO 2>/dev/null | head -1 | tr -d ' \r')

if [ -z "$FPC_VERSION" ]; then
    problem "\`$FPC\` did not answer -iV; it may not be a Free Pascal compiler" ''
    exit 1
fi

FPC_TARGET="$FPC_CPU-$FPC_OS"
# fpc lives at <base>/bin/<target>/fpc, and its packaged units at
# <base>/units/<target>/. Walk up two levels to find <base>.
FPC_BIN_DIR=$(dirname -- "$(command -v -- "$FPC" || printf '%s' "$FPC")")
FPC_BASE=$(dirname -- "$(dirname -- "$FPC_BIN_DIR")")
FPC_UNITS="$FPC_BASE/units/$FPC_TARGET"

info Using "fpc $FPC_VERSION $FPC_TARGET ($FPC)"

# ---- compiling ------------------------------------------------------------

UNIT_OUT="$ROOT/target/$PROFILE/bootstrap"
BIN_DIR="$ROOT/bin"

# Under MSYS or Git Bash, fpc is a Windows binary that cannot read a POSIX
# path. Translating here lets the same script serve both worlds.
if command -v cygpath >/dev/null 2>&1; then
    winpath() { cygpath -w -- "$1"; }
else
    winpath() { printf '%s' "$1"; }
fi

SEARCH_PATHS=''
for sub in src src/util src/toml src/core src/cli src/commands tests; do
    [ -d "$ROOT/$sub" ] && SEARCH_PATHS="$SEARCH_PATHS -Fu$(winpath "$ROOT/$sub")"
done
[ -d "$FPC_UNITS" ] && SEARCH_PATHS="$SEARCH_PATHS -Fu$(winpath "$FPC_UNITS")/*"

if [ "$PROFILE" = release ]; then
    PROFILE_FLAGS='-O3 -Xs -XX -CX'
else
    PROFILE_FLAGS='-O1 -g -gl'
fi

# Compiles $1 into $2, returning the compiler's exit status. Free Pascal does
# not create its output directories, so they are made here.
compile() {
    _source=$1
    _exe=$2
    _units=$3
    mkdir -p "$_units" "$(dirname -- "$_exe")"
    # shellcheck disable=SC2086
    "$FPC" -Mobjfpc -Sh -viwn $SEARCH_PATHS $PROFILE_FLAGS \
        "-FU$(winpath "$_units")" "-o$(winpath "$_exe")" "$(winpath "$_source")" 2>&1 |
        grep -Ev '^(Free Pascal Compiler|Copyright \(c\)|Target OS:|Compiling |Assembling |Linking |[0-9]+ lines compiled)' || true
    # The pipeline hides fpc's status, so judge by whether the binary appeared.
    [ -f "$_exe" ]
}

if [ "$MODE" = tests ]; then
    FAILURES=''
    for program in "$ROOT"/tests/test_*.pas; do
        [ -f "$program" ] || { problem "no test programs found in \`$ROOT/tests\`" ''; exit 1; }
        name=$(basename -- "$program" .pas)
        exe="$BIN_DIR/$name"
        step Compiling "$name"
        rm -f "$exe"
        if ! compile "$program" "$exe" "$ROOT/target/$PROFILE/tests"; then
            FAILURES="$FAILURES $name(compile)"
            continue
        fi
        step Running "$name"
        "$exe" || FAILURES="$FAILURES $name"
    done

    printf '\n'
    if [ -n "$FAILURES" ]; then
        problem "test suites failed:$FAILURES" ''
        exit 1
    fi
    step Finished 'all test suites passed'
    exit 0
fi

MAIN="$ROOT/src/struo.pas"
if [ ! -f "$MAIN" ]; then
    problem "\`$MAIN\` does not exist yet" \
        'run ./bootstrap/build.sh --tests to build and run the test suites instead'
    exit 1
fi

step Compiling "struo ($PROFILE)"
rm -f "$BIN_DIR/struo"
if ! compile "$MAIN" "$BIN_DIR/struo" "$UNIT_OUT"; then
    problem 'struo did not compile' ''
    exit 1
fi

step Finished "$PROFILE profile -> bin/struo"
info Next "add \`$BIN_DIR\` to your PATH, then run: struo --version"
