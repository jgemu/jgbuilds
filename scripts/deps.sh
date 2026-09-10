#!/usr/bin/env bash
# Installs everything needed to build the JG API, one core, and QTea.
#
#   ./scripts/deps.sh nestopia

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

case "$PLATFORM" in
linux)
    log "apt-get: build dependencies"
    sudo apt-get update -qq
    # shellcheck disable=SC2086
    sudo apt-get install -y --no-install-recommends \
        build-essential git pkg-config cmake ninja-build \
        qt6-base-dev qt6-base-dev-tools libgl-dev \
        libsdl3-dev libepoxy-dev libspeexdsp-dev libarchive-dev \
        dpkg-dev fakeroot file \
        $APT_DEPS
    ;;

macos)
    # Installed one at a time and skipped when already present: `brew
    # install` on something the image already ships can exit non-zero.
    log "brew: build dependencies"
    for formula in qt sdl3 libepoxy speexdsp libarchive ninja $BREW_DEPS; do
        if brew list --formula "$formula" >/dev/null 2>&1; then
            echo "  = $formula"
        else
            echo "  + $formula"
            brew install --quiet "$formula"
        fi
    done
    command -v pkg-config >/dev/null 2>&1 || brew install --quiet pkgconf
    ;;

windows)
    # The base set is installed by msys2/setup-msys2 in the workflow, which
    # caches it. Only per-core extras are left to do here.
    if [ -n "$PACMAN_DEPS" ]; then
        log "pacman: extra packages for $CORE"
        # shellcheck disable=SC2086
        pacman -S --needed --noconfirm $PACMAN_DEPS
    fi
    ;;
esac

log "done"
