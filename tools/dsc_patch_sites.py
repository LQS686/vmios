#!/usr/bin/env python3
"""The known patch sites in the split dyld shared cache.

Shared by tools/dsc-patch.py (works on a directory or a mounted root) and
tools/image-patch.py (works on a raw disk image, no filesystem needed), so the
two can never disagree about a VA or an expected byte.

All VAs are unslid, from the iOS 16.7.16 (20H392) iPhone X D22AP cache.
"""

PRESETS = {
    # QuartzCore: ___CAMetalContextCreate_block_invoke polls IOServiceMatching(
    # "IOAcceleratorES") 300 times with usleep(100 ms) before giving up and
    # letting CoreAnimation use its software renderer. 300 * 100 ms = 30 s of
    # the main thread, once per process, on every boot without a GPU.
    # cmp w21, #0x12b  ->  cmp w21, #0x2   (3 tries, 300 ms)
    "metal-wait-300ms": {
        "va": 0x18853E6B4,
        "expect": "bfae0471",
        "write": "bf0e0071",
        "why": "QuartzCore CAMetalContextCreate: 300x100ms -> 3x100ms",
    },
    # IOSurface: __iosConnectInitalize waits for IOCoreSurfaceRoot with
    # sleep(1) and a counter that starts at -241, i.e. 240 s = 4 min before it
    # gives up. The kernel publishes the service before launchd, so this should
    # never fire; kept as a safety net for a boot-order regression.
    # mov w21, #-0xf1  ->  mov w21, #-0x3  (3 tries, 3 s)
    "iosurface-wait-3s": {
        "va": 0x1A3983C98,
        "expect": "151e8012",
        "write": "75008012",
        "why": "IOSurface __iosConnectInitalize: 240x1s -> 3x1s",
    },
}

# What a bring-up image gets; new presets stay opt-in until they are proven.
BRINGUP = ("metal-wait-300ms", "iosurface-wait-3s")

CACHE_PREFIX = "dyld_shared_cache_arm64"

# Where dyld looks at ignition level 1, and the cryptex copy it is linked from.
CACHE_DIRS = (
    "System/Library/Caches/com.apple.dyld",
    "private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
)
