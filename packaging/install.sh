#!/bin/sh
# Installs Struo from an unpacked release archive.
#
# Run it from inside the directory the archive produced:
#
#   tar -xf struo-0.1.0-x86_64-linux.tar.gz
#   cd struo-0.1.0-x86_64-linux
#   ./install.sh
#
# The whole bundle goes to one directory and a symlink goes on your PATH:
#
#   $PREFIX/share/struo/        struo, toolchain/, the documents
#   $PREFIX/bin/struo           -> ../share/struo/struo
#
# Keeping the bundle together is what lets `struo self-update` replace itself:
# it needs the binary and its toolchain in one place it can swap atomically.
# Struo resolves the symlink to find them, so the link is only a convenience.
#
# PREFIX defaults to ~/.local, which needs no sudo, or to /usr/local when run
# as root. Set PREFIX or pass --prefix to choose.
#
# Usage:
#   ./install.sh                       install under ~/.local
#   ./install.sh --prefix /usr/local   install system-wide (needs write access)
#   ./install.sh --uninstall           remove what this script installed
#   ./install.sh --no-verify           skip the post-install compile check

set -eu

SOURCE_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ "$(id -u)" = 0 ]; then
    PREFIX=${PREFIX:-/usr/local}
else
    PREFIX=${PREFIX:-$HOME/.local}
fi

ACTION=install
VERIFY=yes

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)     shift; PREFIX=${1:?--prefix needs a directory} ;;
        --uninstall)  ACTION=uninstall ;;
        --no-verify)  VERIFY=no ;;
        -h|--help)    sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'error: unknown option `%s`\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

BUNDLE="$PREFIX/share/struo"
LINK="$PREFIX/bin/struo"

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

# ---- uninstall ------------------------------------------------------------

if [ "$ACTION" = uninstall ]; then
    REMOVED=no
    if [ -L "$LINK" ] || [ -f "$LINK" ]; then
        rm -f "$LINK"
        step Removed "$LINK"
        REMOVED=yes
    fi
    if [ -d "$BUNDLE" ]; then
        rm -rf "$BUNDLE"
        step Removed "$BUNDLE"
        REMOVED=yes
    fi
    if [ "$REMOVED" = no ]; then
        problem "nothing of Struo found under \`$PREFIX\`" \
            'pass --prefix with the directory it was installed to'
        exit 1
    fi
    info Note "packages you built are untouched; so is ~/.struo"
    step Finished 'uninstalled'
    exit 0
fi

# ---- checks ---------------------------------------------------------------

if [ ! -f "$SOURCE_DIR/struo" ]; then
    problem "no struo binary beside this script" \
        'run install.sh from inside the directory the release archive produced'
    exit 1
fi

if [ ! -d "$SOURCE_DIR/toolchain" ]; then
    problem 'no toolchain/ beside this script' \
        'this does not look like a Struo release archive'
    exit 1
fi

# Free Pascal on Unix uses the system assembler and linker rather than
# shipping its own, so the bundled toolchain needs binutils. Said now, because
# the failure otherwise arrives later as a link error in the user's package.
MISSING_TOOLS=''
for tool in as ld; do
    command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS $tool"
done
if [ -n "$MISSING_TOOLS" ]; then
    warn "not found:$MISSING_TOOLS -- the bundled compiler needs binutils to link"
    info Hint 'install it with: apt install binutils, or dnf install binutils'
fi

# ---- install --------------------------------------------------------------

if ! mkdir -p "$BUNDLE" "$PREFIX/bin" 2>/dev/null; then
    problem "cannot create \`$BUNDLE\`" \
        "choose a writable prefix with --prefix, or re-run with sudo"
    exit 1
fi

# Replace rather than merge: a leftover unit from an older toolchain could
# otherwise satisfy a build and produce a mystery.
step Installing "$BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"
cp -R "$SOURCE_DIR"/. "$BUNDLE"/
chmod +x "$BUNDLE/struo"
rm -f "$BUNDLE/install.sh"

# A relative target keeps the link working if the prefix is later moved whole.
ln -sf "../share/struo/struo" "$LINK"
step Linked "$LINK"

if [ "$VERIFY" = yes ]; then
    step Checking 'the installed toolchain'
    if ! STRUO_FPC='' STRUO_TOOLCHAIN='' "$BUNDLE/struo" toolchain --verify; then
        problem 'the installed toolchain cannot compile' \
            'see the diagnostics above; ./install.sh --uninstall undoes this'
        exit 1
    fi
fi

# ---- report ---------------------------------------------------------------

VERSION=$("$BUNDLE/struo" --version 2>/dev/null || echo 'struo')
step Finished "$VERSION in $BUNDLE"

# Only worth mentioning when it is actually a problem.
case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *)
        warn "\`$PREFIX/bin\` is not on your PATH"
        info Hint "add this to your shell profile:"
        printf '\n    export PATH="%s/bin:$PATH"\n\n' "$PREFIX"
        ;;
esac

info Next 'struo new hello && cd hello && struo run'
