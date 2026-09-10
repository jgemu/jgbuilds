#!/usr/bin/env bash
# Turns a finished build into something a user can download: a .deb on
# Linux, a .dmg on macOS, a .zip on Windows. Writes into dist/.
#
#   ./scripts/package.sh nestopia

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

VERSION="$(core_version)"
mkdir -p "$DIST"

# --------------------------------------------------------------------------
case "$PLATFORM" in
# --------------------------------------------------------------------------
linux)
    PKGNAME="$BIN_NAME"
    ARCH="$(dpkg --print-architecture)"
    MAINTAINER="${DEB_MAINTAINER:-Jolly Good Emulation Team <noreply@jgemu.gitlab.io>}"

    log "staging the install tree"
    rm -rf "$STAGE"
    DESTDIR="$STAGE" cmake --install "$BUILD" --strip

    # dpkg-shlibdeps reads the ELF headers and turns them into versioned
    # Depends, which beats guessing package names by hand. It insists on a
    # debian/control in the working directory, so give it a stub, and it
    # wants DEBIAN/ to already exist at the root of the staged tree so it
    # can resolve $ORIGIN in the RUNPATH.
    log "resolving shared library dependencies"
    mkdir -p "$STAGE/DEBIAN"
    SHLIBDIR="$WORK/shlibdeps"
    rm -rf "$SHLIBDIR"
    mkdir -p "$SHLIBDIR/debian"
    printf 'Source: %s\n\nPackage: %s\nArchitecture: any\n' \
        "$PKGNAME" "$PKGNAME" > "$SHLIBDIR/debian/control"

    DEPENDS="$(
        cd "$SHLIBDIR" &&
        dpkg-shlibdeps -O --ignore-missing-info "$STAGE/usr/bin/$BIN_NAME" |
        sed 's/^shlibs:Depends=//'
    )"
    echo "Depends: $DEPENDS"

    INSTALLED_SIZE="$(du -sk "$STAGE" | cut -f1)"

    cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKGNAME
Version: $VERSION
Section: games
Priority: optional
Architecture: $ARCH
Depends: $DEPENDS
Installed-Size: $INSTALLED_SIZE
Maintainer: $MAINTAINER
Description: ${SUMMARY:-$BIN_NAME emulator with the QTea frontend}
 The $BIN_NAME emulator core statically linked into QTea, a Qt6 frontend
 for the Jolly Good API.
EOF

    DEB="$DIST/${PKGNAME}_${VERSION}_${ARCH}.deb"
    log "building $DEB"
    # --root-owner-group avoids needing fakeroot for the ownership metadata.
    dpkg-deb --build --root-owner-group "$STAGE" "$DEB"
    dpkg-deb --info "$DEB"
    ;;

# --------------------------------------------------------------------------
macos)
# --------------------------------------------------------------------------
    APP="$BUILD/$BIN_NAME.app"
    [ -d "$APP" ] || { echo "no bundle at $APP" >&2; exit 1; }

    DMG="$DIST/$BIN_NAME-$VERSION-macos-$(uname -m).dmg"
    log "building $DMG"
    hdiutil create \
        -volname "$BIN_NAME $VERSION" \
        -srcfolder "$APP" \
        -ov -format UDZO \
        "$DMG"
    ;;

# --------------------------------------------------------------------------
windows)
# --------------------------------------------------------------------------
    log "staging the install tree"
    rm -rf "$STAGE"
    cmake --install "$BUILD" --prefix "$STAGE"

    # Qt's own deployment tool: Qt DLLs, the plugins that are loaded at
    # runtime and so are invisible to a dependency scan, and the MinGW
    # runtime. Per Qt's documentation it does not consider third-party
    # libraries, so SDL3 and friends are handled below.
    WINDEPLOYQT=""
    for cand in windeployqt6 windeployqt; do
        if command -v "$cand" >/dev/null 2>&1; then WINDEPLOYQT="$cand"; break; fi
    done
    [ -n "$WINDEPLOYQT" ] || { echo "windeployqt not found" >&2; exit 1; }

    log "running $WINDEPLOYQT"
    "$WINDEPLOYQT" --release --compiler-runtime --no-translations \
        "$STAGE/$BIN_NAME.exe"

    # windeployqt usually places these, but it decides for itself and a miss
    # is silent: without platforms/ the application will not start at all,
    # and without styles/ widgets fall back to Fusion and look nothing like a
    # native Windows program. Check, and fill in from the Qt install if
    # needed. This runs before the DLL sweep so the plugins' own
    # dependencies get collected with everything else.
    log "checking Qt plugins"
    QT_PLUGINS=""
    for q in qmake6 qmake; do
        if command -v "$q" >/dev/null 2>&1; then
            QT_PLUGINS="$(cygpath -u "$("$q" -query QT_INSTALL_PLUGINS)")"
            break
        fi
    done
    [ -n "$QT_PLUGINS" ] || { echo "cannot locate the Qt plugin dir" >&2; exit 1; }

    for group in platforms styles; do
        if [ -n "$(ls -A "$STAGE/$group" 2>/dev/null || true)" ]; then
            echo "  = $group: $(ls "$STAGE/$group" | tr '\n' ' ')"
            continue
        fi
        if [ ! -d "$QT_PLUGINS/$group" ]; then
            echo "no $group plugins in $QT_PLUGINS" >&2
            exit 1
        fi
        mkdir -p "$STAGE/$group"
        cp "$QT_PLUGINS/$group"/*.dll "$STAGE/$group/"
        echo "  + $group: $(ls "$STAGE/$group" | tr '\n' ' ') (windeployqt skipped it)"
    done

    # SDL3, epoxy, speexdsp, libarchive and everything those pull in.
    # ntldd -R walks the entire import tree of a PE file in one pass, so
    # this only has to visit what is already staged: the executable and the
    # plugins windeployqt placed. Anything reachable from them is resolved
    # for us, no repeat passes needed.
    log "collecting non-Qt DLLs"
    MINGW_BIN="${MSYSTEM_PREFIX:-/ucrt64}/bin"

    find "$STAGE" \( -name '*.exe' -o -name '*.dll' \) -print |
    while IFS= read -r binary; do
        ntldd -R "$binary" 2>/dev/null |
            awk -F' => ' 'NF > 1 {
                sub(/ \(0x[0-9a-fA-F]*\)$/, "", $2); print $2
            }'
    done |
    sort -u |
    while IFS= read -r winpath; do
        # ntldd reports Windows paths; everything outside the MinGW prefix
        # is a system DLL or an unresolved name, and is not ours to ship.
        dll="$(cygpath -u "$winpath" 2>/dev/null)" || continue
        case "$dll" in "$MINGW_BIN"/*) ;; *) continue ;; esac

        base="$(basename "$dll")"
        if [ ! -e "$STAGE/$base" ]; then
            cp "$dll" "$STAGE/"
            echo "  + $base"
        fi
    done

    # QTea's CMake install puts its LICENSE, the core's LICENSES and the
    # dependency license texts at the root already. What it never ships is
    # the prose documentation from either tree, so collect that here. CMake
    # owns the root of the package; everything added below lives in docs/.
    log "collecting documentation"

    mkdir -p "$STAGE/docs/qtea"
    for doc in README README.md ChangeLog COPYING AUTHORS NEWS THANKS; do
        if [ -f "$QTEA_SRC/$doc" ]; then
            cp "$QTEA_SRC/$doc" "$STAGE/docs/qtea/"
            echo "  + docs/qtea/$doc"
        fi
    done

    mkdir -p "$STAGE/docs/$BIN_NAME"
    DOCS="$(core_docs)"
    if [ -z "$DOCS" ]; then
        echo "warning: $CORE declares no DOCS in its Makefile" >&2
    fi
    for doc in $DOCS; do
        if [ -f "$CORE_SRC/$CORE_SUBDIR/$doc" ]; then
            cp "$CORE_SRC/$CORE_SUBDIR/$doc" "$STAGE/docs/$BIN_NAME/"
            echo "  + docs/$BIN_NAME/$doc"
        else
            echo "warning: $CORE lists $doc in DOCS but it is missing" >&2
        fi
    done

    # A missing platform plugin is not a subtle failure: the application
    # aborts on startup with a dialog about failing to load the Qt platform
    # plugin. Better to break the build than to ship that.
    if [ ! -e "$STAGE/platforms/qwindows.dll" ]; then
        echo "platforms/qwindows.dll is not in the package" >&2
        exit 1
    fi

    ZIP="$DIST/$BIN_NAME-$VERSION-windows-x86_64.zip"
    log "building $ZIP"
    rm -f "$ZIP"
    ( cd "$STAGE" && zip -qr "$ZIP" . )
    ;;
esac

log "artifacts"
ls -la "$DIST"
