#!/usr/bin/env bash
# Sourced by deps.sh, build.sh and package.sh. Not executable on its own.
#
# Every script takes the core name as $1 and loads cores/<name>.env for the
# parts that differ between cores. Everything else here is common.

set -euo pipefail

CORE="${1:-}"
if [ -z "$CORE" ]; then
    echo "usage: $0 <core>" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Defaults a core's .env may override.
GIT_HOST="https://gitlab.com/jgemu"
CORE_REPO=""     # full clone URL; defaults to $GIT_HOST/$CORE
CORE_SUBDIR="."  # where the Makefile lives, relative to the clone
CORE_OUTDIR=""   # directory `make` writes the core into; defaults to $CORE
CORE_PIN=""      # the ref this core is built at; see cores/<name>.env
MAKE_ARGS=""     # extra arguments for the core's make
APT_DEPS=""      # extra Debian/Ubuntu packages this core needs
BREW_DEPS=""     # extra Homebrew formulae
PACMAN_DEPS=""   # extra MSYS2 UCRT64 packages
SUMMARY=""       # one line, used in the .deb description

# Toolchain overrides for cores that cannot be built with the platform
# default. These are passed to the core's make; the makefiles declare them
# with ?= so a command-line value wins. Note that setting CORE_CFLAGS
# replaces the default -O2 rather than adding to it.
CORE_CC=""
CORE_CXX=""
CORE_AR=""
CORE_CFLAGS=""
CORE_CXXFLAGS=""
CORE_LDFLAGS=""

# Extra -D arguments for QTea's configure, applied after the platform ones
# so they win. A core built with a non-default toolchain has to set the
# matching compiler here: the archive it produces is only linkable by the
# toolchain that made it. Values must not contain spaces.
QTEA_CMAKE_ARGS=""

JG_PIN=""
QTEA_PIN=""
if [ -f "$ROOT/pins.env" ]; then
    # shellcheck disable=SC1091
    . "$ROOT/pins.env"
fi

# Resolved before the core's .env is sourced, so a core can branch on it.
# Cores whose toolchain differs per platform, cen64 for one, need that:
# llvm-ar exists on Linux and MSYS2 but not in Apple's toolchain.
# RUNNER_OS is set by GitHub Actions in every shell, msys2 included. The
# uname fallback is for running these scripts by hand.
case "${RUNNER_OS:-$(uname -s)}" in
    Linux)                 PLATFORM=linux   ;;
    macOS|Darwin)          PLATFORM=macos   ;;
    Windows|MINGW*|MSYS*)  PLATFORM=windows ;;
    *) echo "unsupported platform: ${RUNNER_OS:-$(uname -s)}" >&2; exit 1 ;;
esac

ENVFILE="$ROOT/cores/$CORE.env"
if [ ! -f "$ENVFILE" ]; then
    echo "unknown core '$CORE'; expected $ENVFILE" >&2
    echo "known cores:" >&2
    ls "$ROOT/cores" | sed 's/\.env$//' | sed 's/^/  /' >&2
    exit 2
fi
# shellcheck disable=SC1090
. "$ENVFILE"

: "${CORE_REPO:=$GIT_HOST/$CORE}"
: "${CORE_OUTDIR:=$CORE}"

# What actually gets built. Precedence: an explicit environment variable
# (the workflow's manual-run inputs) beats the pin checked into the repo,
# which beats master.
JG_REF="${JG_REF:-${JG_PIN:-master}}"
QTEA_REF="${QTEA_REF:-${QTEA_PIN:-master}}"
CORE_REF="${CORE_REF:-${CORE_PIN:-master}}"

# RUNNER_OS is set by GitHub Actions in every shell, msys2 included. The
# uname fallback is for running these scripts by hand.

WORK="${WORK:-$ROOT/work}"
DIST="${DIST:-$ROOT/dist}"

JG_SRC="$WORK/jg"
CORE_SRC="$WORK/core"
QTEA_SRC="$WORK/qtea"
PREFIX="$WORK/prefix"          # the JG API is installed here
BUILD="$WORK/build"            # QTea's CMake build tree
STAGE="$WORK/stage"            # `cmake --install` destination

# Where jg-static.mk and lib<core>-jg.a end up, i.e. what QTEA_CORE_DIR wants.
CORE_OUT="$CORE_SRC/$CORE_SUBDIR/$CORE_OUTDIR"

# The name QTea gives the executable: the core name minus any -jg suffix.
BIN_NAME="${CORE%-jg}"

# Both directories: the JG API installs jg.pc to share/pkgconfig, which is
# the conventional spot for a headers-only package with nothing
# architecture-dependent to describe. pkg-config searches share/pkgconfig
# under the system prefixes by default but knows nothing about ours, so it
# has to be named explicitly.
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"

log() { printf '\n==> %s\n' "$*"; }

ncpu() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    else
        sysctl -n hw.ncpu 2>/dev/null || echo 2
    fi
}

# Clone one ref shallowly. Works for a branch, a tag or a full commit SHA,
# which --branch does not.
fetch_repo() {
    local url="$1" ref="$2" dest="$3"
    rm -rf "$dest"
    mkdir -p "$dest"
    git -C "$dest" init -q
    git -C "$dest" remote add origin "$url"
    git -C "$dest" fetch -q --depth 1 origin "$ref"
    git -C "$dest" checkout -q FETCH_HEAD
    printf '%s %s (%s)\n' "$url" "$ref" \
        "$(git -C "$dest" rev-parse --short HEAD)"
}

# The JG makefiles list a core's documentation in DOCS. Asking make for it
# beats globbing for likely names: this is exactly the set `make install`
# would ship as documentation.
core_docs() {
    local dir="$CORE_SRC/$CORE_SUBDIR"
    local mk="$WORK/print-docs.mk"
    local err="$WORK/print-docs.err"
    local declared="" docs="" f

    printf 'jg-ci-print-docs:\n\t@echo $(DOCS)\n' > "$mk"
    if ! declared="$(make -C "$dir" --no-print-directory \
                     -f Makefile -f "$mk" jg-ci-print-docs 2>"$err")"; then
        echo "core_docs: could not read DOCS from $CORE's makefile:" >&2
        sed 's/^/  /' "$err" >&2
        declared=""
    fi

    # DOCS is what `make install` would ship, but a core need not declare it
    # and an incomplete one silently costs the package a ChangeLog. Union it
    # with the conventional names actually present in the tree.
    for f in $declared ChangeLog CHANGELOG NEWS README README.md \
             COPYING LICENSE AUTHORS THANKS; do
        case " $docs " in *" $f "*) continue ;; esac
        if [ -f "$dir/$f" ]; then
            docs="$docs $f"
        fi
    done

    printf '%s' "$docs"
}

# Every Jolly Good project keeps its version in a version.h that is valid C,
# Makefile and shell at once. QTea reads the core's from the directory above
# CORE_OUT, so read it from the same place the built binary reports.
core_version() {
    local vh
    for vh in "$CORE_OUT/../version.h" "$CORE_OUT/version.h"; do
        if [ -f "$vh" ]; then
            awk -F= '
                /^VERSION_MAJOR=/ { a = $2 }
                /^VERSION_MINOR=/ { b = $2 }
                /^VERSION_PATCH=/ { c = $2 }
                END { if (a != "") print a "." b "." c }
            ' "$vh"
            return
        fi
    done
    echo "0.0.0"
}

# Run rather than sourced, this prints the settings it resolved. The
# workflow uses it to find a core's pinned ref without reimplementing the
# precedence rules above:
#
#   eval "$(bash scripts/common.sh geolith)"
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf 'CORE=%s\nCORE_REF=%s\nJG_REF=%s\nQTEA_REF=%s\nBIN_NAME=%s\n' \
        "$CORE" "$CORE_REF" "$JG_REF" "$QTEA_REF" "$BIN_NAME"
fi
