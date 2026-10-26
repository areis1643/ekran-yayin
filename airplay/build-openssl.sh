#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VERSION=1.1.1w
T=/home/alir/theos/toolchain/linux/iphone/bin
S=/home/alir/theos/sdks/iPhoneOS9.3.sdk
SRC="$ROOT/vendor/openssl-$VERSION"
BUILD="$ROOT/vendor/openssl-$VERSION-build-armv7"
PREFIX="$ROOT/deps"
mkdir -p "$ROOT/vendor" "$PREFIX" "$BUILD"
if [[ ! -f "$SRC/Configure" ]]; then
    ARCHIVE="$ROOT/vendor/openssl-$VERSION.tar.gz"
    curl --fail --location --retry 3 \
        "https://www.openssl.org/source/old/1.1.1/openssl-$VERSION.tar.gz" \
        -o "$ARCHIVE"
    tar -xzf "$ARCHIVE" -C "$ROOT/vendor"
fi

export PATH="$T:$PATH"
export CC="$T/clang -target armv7-apple-ios9.0 -isysroot $S"
# This cctools ar looks for a prefixed ranlib next to its executable.
# Keep the compatibility tools local; do not modify the toolchain.
mkdir -p "$BUILD/tools"
cp "$T/ar" "$BUILD/tools/ar"
ln -sfn "$T/ranlib" "$BUILD/tools/aarch64-apple-darwin14-ranlib"
export AR="$BUILD/tools/ar" RANLIB="$T/ranlib"
# ios-cross also injects its own SDK path and iOS 6 minimum flags.
mkdir -p "$BUILD/SDKs"
ln -sfn "$S" "$BUILD/SDKs/$(basename -- "$S")"
export CROSS_TOP="$BUILD"
export CROSS_SDK="$(basename -- "$S")"
unset CROSS_COMPILE
cd "$BUILD"
perl "$SRC/Configure" ios-cross no-shared no-tests no-asm \
    --prefix="$PREFIX" --openssldir="$PREFIX/ssl" --libdir=lib \
    -mios-version-min=9.0
make -j8 build_libs
make install_dev

# The supplied SDK stubs omit these standard libSystem exports. Repair only
# a local link-time stub; no replacement code is added to libcrypto or the test.
mkdir -p "$BUILD/sdkstub"
python3 - "$BUILD/sdkstub/libSystem.tbd" <<'PY'
import pathlib
import sys
source = pathlib.Path('/home/alir/projeler/ekran-yayin/iPad/sdkstub/libSystem.tbd')
stub = source.read_text()
symbols = '_memchr, _memcmp, _memcpy, _memmove, _memset, _strchr, _strcmp, _strncmp, '
stub = stub.replace('symbols:            [ ', 'symbols:            [ ' + symbols, 1)
pathlib.Path(sys.argv[1]).write_text(stub)
PY

cat > "$BUILD/test.c" <<'EOF'
#include <openssl/evp.h>
int main(void)
{
    unsigned char key[32] = {9};
    EVP_PKEY *p = EVP_PKEY_new_raw_public_key(
        EVP_PKEY_X25519, NULL, key, sizeof(key));
    if (p == NULL) return 1;
    EVP_PKEY_free(p);
    return 0;
}
EOF
"$T/clang" -target armv7-apple-ios9.0 -isysroot "$S" \
    -I"$PREFIX/include" -L"$BUILD/sdkstub" \
    -L/home/alir/projeler/ekran-yayin/iPad/sdkstub \
    "$BUILD/test.c" "$PREFIX/lib/libcrypto.a" -o "$BUILD/test-armv7"
"$T/lipo" -info "$PREFIX/lib/libcrypto.a"
"$T/lipo" -info "$PREFIX/lib/libssl.a"
file "$BUILD/test-armv7"
