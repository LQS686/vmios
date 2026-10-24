#!/bin/sh
# Build the SweetMetal plugin bundle and the SGB1 blob the kernel installs.
#
#   tools/build-sweetmetal.sh
#
# Needs clang with an arm64 Mach-O target and ld64.lld (see .tools/lld18).
# Output: vm/metal/build/SweetMetal.bundle/{Info.plist,SweetMetal}
#         vm/metal/build/SweetMetal.sgb      (_MTLDevice base)
#         vm/metal/build/SweetMetalAccel.sgb (same class/name, MTLIOAccelDevice
#                                             base; selected by embedding this
#                                             blob instead of SweetMetal.sgb)
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUT="$ROOT/vm/metal/build"
LD=${LD:-"$ROOT/.tools/lld18/usr/bin/ld64.lld"}
CLANG=${CLANG:-clang}

build() {
	extra=$1
	staging=$2
	obj=$3
	blob=$4
	rm -rf "$staging"
	mkdir -p "$staging/SweetMetal.bundle"
	# shellcheck disable=SC2086
	"$CLANG" -target arm64-apple-ios16.0 -fobjc-runtime=ios-16.0 -fno-objc-arc \
		-O2 -Wall $extra -c "$ROOT/vm/metal/SweetMetal.m" -o "$OUT/$obj"
	"$LD" -dylib -arch arm64 -platform_version ios 16.0 16.7.16 \
		-install_name /System/Library/Extensions/SweetMetal.bundle/SweetMetal \
		-undefined dynamic_lookup -adhoc_codesign \
		-o "$staging/SweetMetal.bundle/SweetMetal" "$OUT/$obj"
	cp "$ROOT/vm/metal/Info.plist" "$staging/SweetMetal.bundle/Info.plist"
	python3 "$ROOT/tools/gpu-bundle.py" pack "$staging/SweetMetal.bundle" "$OUT/$blob"
}

build "" "$OUT/plain" SweetMetal.o SweetMetal.sgb
build "-DSWEETMETAL_ACCEL_BASE" "$OUT/accel" SweetMetalAccel.o SweetMetalAccel.sgb
