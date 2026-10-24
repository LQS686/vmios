#!/bin/sh
# Build the SweetMetal plugin bundle and the SGB1 blob the kernel installs.
#
#   tools/build-sweetmetal.sh
#
# Needs clang with an arm64 Mach-O target and ld64.lld (see .tools/lld18).
# Output: vm/metal/build/SweetMetal.bundle/{Info.plist,SweetMetal}
#         vm/metal/build/SweetMetal.sgb (packed for mkadt.py --gpu-bundle)
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUT="$ROOT/vm/metal/build"
LD=${LD:-"$ROOT/.tools/lld18/usr/bin/ld64.lld"}
CLANG=${CLANG:-clang}

mkdir -p "$OUT/SweetMetal.bundle"
"$CLANG" -target arm64-apple-ios16.0 -fobjc-runtime=ios-16.0 -fno-objc-arc \
	-O2 -Wall -c "$ROOT/vm/metal/SweetMetal.m" -o "$OUT/SweetMetal.o"
"$LD" -dylib -arch arm64 -platform_version ios 16.0 16.7.16 \
	-install_name /System/Library/Extensions/SweetMetal.bundle/SweetMetal \
	-undefined dynamic_lookup -adhoc_codesign -o "$OUT/SweetMetal.bundle/SweetMetal" \
	"$OUT/SweetMetal.o"
cp "$ROOT/vm/metal/Info.plist" "$OUT/SweetMetal.bundle/Info.plist"
python3 "$ROOT/tools/gpu-bundle.py" pack "$OUT/SweetMetal.bundle" "$OUT/SweetMetal.sgb"
