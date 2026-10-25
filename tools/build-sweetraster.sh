#!/bin/sh
# Build the native triangle rasterizer loaded by CaCompositor.
#
# The app is debuggable, so `cmd package compile -m speed` still leaves ART at
# status=verify and the per-pixel Java loop costs ~1.1 s per full-screen layer.
# This .so is packaged as lib/arm64-v8a/libsweetraster.so.
#
#   NDK_CLANG=/path/to/aarch64-linux-android-clang tools/build-sweetraster.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
NDK_CLANG=${NDK_CLANG:-/opt/ndk-bin/aarch64-linux-android-clang}
OUT="$ROOT/android/app/src/main/jniLibs/arm64-v8a"

mkdir -p "$OUT"
"$NDK_CLANG" -shared -fPIC -O2 \
	-o "$OUT/libsweetraster.so" "$ROOT/android/app/src/main/cpp/sweetraster.c"
echo "$OUT/libsweetraster.so"
