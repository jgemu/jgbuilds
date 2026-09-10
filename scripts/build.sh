#!/usr/bin/env bash
# Clones and builds the JG API, one emulator core as a static archive, and
# QTea linked against it.
#
#   ./scripts/build.sh nestopia
#
# Override the refs through the environment:
#   JG_REF=1.0.0 CORE_REF=v1.99.0 QTEA_REF=master ./scripts/build.sh nestopia

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

mkdir -p "$WORK"

# --------------------------------------------------------------------------
# 1. The JG API
# --------------------------------------------------------------------------
# Headers and a pkg-config file, nothing compiled. Installing it into a
# prefix inside the workspace keeps the build out of system directories and
# needs no sudo. PKG_CONFIG_PATH (set in common.sh) is what makes the core
# and QTea find it.

log "fetching the Jolly Good API"
fetch_repo "$GIT_HOST/jg" "$JG_REF" "$JG_SRC"

log "installing the Jolly Good API into $PREFIX"
make -C "$JG_SRC" install PREFIX="$PREFIX"

pkg-config --exists jg || {
    echo "jg.pc did not land in $PREFIX/lib/pkgconfig" >&2
    exit 1
}
echo "jg $(pkg-config --modversion jg): $(pkg-config --cflags jg)"

# --------------------------------------------------------------------------
# 2. The core
# --------------------------------------------------------------------------
# ENABLE_STATIC_JG=1 builds lib<core>-jg.a and writes jg-static.mk beside it,
# declaring the core's name, assets, icons and link flags. DISABLE_MODULE=1
# skips the shared module, which nothing here loads.

log "fetching core: $CORE"
fetch_repo "$CORE_REPO" "$CORE_REF" "$CORE_SRC"

log "building core: $CORE"

MAKE_VARS=( ENABLE_STATIC_JG=1 DISABLE_MODULE=1 )
if [ -n "$CORE_CC" ];       then MAKE_VARS+=( "CC=$CORE_CC" );             fi
if [ -n "$CORE_CXX" ];      then MAKE_VARS+=( "CXX=$CORE_CXX" );           fi
if [ -n "$CORE_AR" ];       then MAKE_VARS+=( "AR=$CORE_AR" );             fi
if [ -n "$CORE_CFLAGS" ];   then MAKE_VARS+=( "CFLAGS=$CORE_CFLAGS" );     fi
if [ -n "$CORE_CXXFLAGS" ]; then MAKE_VARS+=( "CXXFLAGS=$CORE_CXXFLAGS" ); fi
if [ -n "$CORE_LDFLAGS" ];  then MAKE_VARS+=( "LDFLAGS=$CORE_LDFLAGS" );   fi

# shellcheck disable=SC2086
make -C "$CORE_SRC/$CORE_SUBDIR" "${MAKE_VARS[@]}" $MAKE_ARGS -j"$(ncpu)"

if [ ! -f "$CORE_OUT/jg-static.mk" ]; then
    echo "expected $CORE_OUT/jg-static.mk after the core build" >&2
    echo "set CORE_SUBDIR or CORE_OUTDIR in cores/$CORE.env" >&2
    ls -la "$CORE_SRC/$CORE_SUBDIR" >&2
    exit 1
fi

echo "--- jg-static.mk ---"
cat "$CORE_OUT/jg-static.mk"
echo "--------------------"

# --------------------------------------------------------------------------
# 3. QTea
# --------------------------------------------------------------------------

log "fetching QTea"
fetch_repo "$GIT_HOST/qtea" "$QTEA_REF" "$QTEA_SRC"

CMAKE_ARGS=(
    -S "$QTEA_SRC"
    -B "$BUILD"
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DQTEA_CORE_DIR="$CORE_OUT"
)

case "$PLATFORM" in
linux)
    # Baked into the .desktop Exec= line and QTEA_DATAROOTDIR at configure
    # time, so it has to be the path the .deb will install to, not the
    # staging directory.
    CMAKE_ARGS+=( -DCMAKE_INSTALL_PREFIX=/usr )
    ;;
macos)
    CMAKE_ARGS+=( -DCMAKE_PREFIX_PATH="$(brew --prefix qt)" )
    ;;
windows)
    CMAKE_ARGS+=( -DCMAKE_INSTALL_PREFIX="$STAGE" )
    ;;
esac

# Last, so a core can override a platform default. A core built with a
# non-default toolchain must select the same one for QTea here: an archive
# of LLVM bitcode, for instance, is only linkable by clang with -flto.
if [ -n "$QTEA_CMAKE_ARGS" ]; then
    # shellcheck disable=SC2206
    CMAKE_ARGS+=( $QTEA_CMAKE_ARGS )
fi

log "configuring QTea"
cmake "${CMAKE_ARGS[@]}"

log "building QTea"
cmake --build "$BUILD" --parallel "$(ncpu)"

# On macOS macdeployqt copies Qt and the Homebrew dylibs into the .app and
# rewrites their install names. Without it the bundle only runs on a machine
# that already has Homebrew Qt.
if [ "$PLATFORM" = macos ]; then
    log "deploying Qt into the bundle"
    cmake --build "$BUILD" --target bundle
fi

log "built $BIN_NAME $(core_version)"
