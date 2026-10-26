#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="2.8.0"
T="${T:-/home/alir/theos/toolchain/linux/iphone/bin}"
S="${S:-/home/alir/theos/sdks/iPhoneOS9.3.sdk}"
CC="${CC:-$T/clang}"
AR="${AR:-}"
RANLIB="${RANLIB:-$T/ranlib}"

VENDOR="$SCRIPT_DIR/vendor"
SRC="$VENDOR/libplist-$VERSION"
PREFIX="$SCRIPT_DIR/deps"
BUILD="$SRC/.build-ios-armv7"
OBJDIR="$BUILD/obj"

if [ ! -d "$SRC" ]; then
    mkdir -p "$VENDOR"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fL --retry 3 -o "$tmp/libplist.tar.gz" \
        "https://github.com/libimobiledevice/libplist/archive/refs/tags/$VERSION.tar.gz"
    tar -xzf "$tmp/libplist.tar.gz" -C "$VENDOR"
fi

[ -x "$CC" ] || { echo "compiler not found: $CC" >&2; exit 1; }
[ -d "$S" ] || { echo "SDK not found: $S" >&2; exit 1; }

rm -rf "$BUILD"
mkdir -p "$OBJDIR" "$PREFIX/lib" "$PREFIX/include"

if [ -z "$AR" ]; then
    mkdir -p "$BUILD/tools"
    cp "$T/ar" "$BUILD/tools/ar"
    ln -sfn "$T/ranlib" "$BUILD/tools/aarch64-apple-darwin14-ranlib"
    AR="$BUILD/tools/ar"
fi

cat > "$BUILD/config.h" <<'EOF'
#ifndef LIBPLIST_CONFIG_H
#define LIBPLIST_CONFIG_H

#define HAVE_CONFIG_H 1
#define LIBPLIST_STATIC 1
#define PACKAGE_VERSION "2.8.0"

#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1

#define HAVE_STRDUP 1
#define HAVE_STRNDUP 1
#define HAVE_STRERROR 1
#define HAVE_GMTIME_R 1
#define HAVE_LOCALTIME_R 1
#define HAVE_TIMEGM 1

#define HAVE_TM_TM_GMTOFF 1
#define HAVE_TM_TM_ZONE 1

#define __LITTLE_ENDIAN__ 1

#endif
EOF

CFLAGS=(
    -target armv7-apple-ios9.0
    -arch armv7
    -miphoneos-version-min=9.0
    -isysroot "$S"
    -O2
    -fPIC
    -DHAVE_CONFIG_H
    -I"$BUILD"
    -I"$SRC/include"
    -I"$SRC"
    -I"$SRC/src"
    -I"$SRC/libcnary/include"
    -Wall -Wextra -Wno-unused-parameter
)

mapfile -t SOURCES < <(find "$SRC/src" -maxdepth 1 -name '*.c'; find "$SRC/libcnary" -maxdepth 1 -name '*.c' ! -name 'cnary.c')

OBJECTS=()
pids=()
for f in "${SOURCES[@]}"; do
    rel="${f#$SRC/}"
    obj="$OBJDIR/${rel//\//_}.o"
    OBJECTS+=("$obj")
    "$CC" "${CFLAGS[@]}" -c "$f" -o "$obj" &
    pids+=("$!")
done

status=0
for p in "${pids[@]}"; do
    wait "$p" || status=1
done
[ "$status" -eq 0 ] || { echo "compilation failed" >&2; exit 1; }

ARCHIVE="$PREFIX/lib/libplist-2.0.a"
rm -f "$ARCHIVE"
"$AR" rcs "$ARCHIVE" "${OBJECTS[@]}"
"$RANLIB" "$ARCHIVE"

rm -rf "$PREFIX/include/plist"
cp -R "$SRC/include/plist" "$PREFIX/include/plist"

echo "installed: $PREFIX/lib/libplist-2.0.a"
echo "headers:   $PREFIX/include/plist"
