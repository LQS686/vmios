#!/usr/bin/env python3
"""The SWEET boot-args, in one place.

The kernel command line is the only knob that changes behaviour without a
rebuild, and it is written down in four places (this repo's README, the WSL
image notes, the Android app's UI hint, and every build command someone types
from memory). This file is the source of truth: `mkpayload.py --profile NAME`
packs it, and `python3 tools/bootargs.py NAME` prints it.

  python3 tools/bootargs.py                 # the device profile
  python3 tools/bootargs.py --list          # profiles and their length
  python3 tools/bootargs.py sample --add sweetiolog=1

Profiles:

  device   Production boot on the phone: all eight cores, cached UFS writes,
           sleeping UFS waits, no GPU (there is none), 30 Hz software panel.
  timing   device + console timestamps and UFS counters. Answers "where do the
           31 s between the last early-boot line and launchd go", and "is the
           one-command-at-a-time controller the bottleneck".
  sample    timing + the stack sampler, for a boot that stalls in userland.
  vm       vmios (the Android app): cpus=N becomes QEMU's -smp, no rd= (the
           app appends rd=ufsroot0 itself). 2 vCPUs is what NOTES.md calls
           stable, but see BOOT_FIXES.md 8.4: -accel tcg,thread=single means the
           extra vCPU only time-shares one host core.
  vm-sample  vm + the sampler.
  qemu     Kernel-only boot under QEMU with a ramdisk root (rd=md0), one CPU:
           TCG does not do eight vCPUs usefully.
  probe    Minimal: no root, no log, no drivers. For a kernel that does not
           reach the UFS device at all.

A profile must stay under BOOT_LINE_LENGTH - 1 = 607 bytes: that is the
size of the boot-args field in the shim payload header, and the Android app
truncates at the same limit.
"""
import sys

BOOT_LINE_LENGTH = 608

# Everything the device needs, in the order it was debugged in.
DEVICE = " ".join([
    "debug=0xc",
    "serial=3",
    "cpus=8",                       # 6x A55 + 2x A76 (0078)
    "keepsyms=1",
    "-enable_kprintf_spam",
    "-noprogress",
    "rd=ufsroot0",
    "unentitled_ios_sim_launch=1",
    "ignition_level=1",
    "wdt_test=no_user_checkin",
    "ufsrw=1",
    "rootrw=1",
    "launchd_unsecure_cache=1",
    "wdt=-1",
    "sweetfb_noconsole=1",
    "sweetfb_hz=30",
    "ufscache=1",                   # clean cache lines, no full sync (0069)
    "ufswait=1",                    # sleep instead of spinning (0069)
])

TIMING = DEVICE + " sweetts=1 ufsstats=1 ufsstatsecs=5"

# vmios (the Android app): QEMU's -smp comes from cpus=N here, and one vCPU
# is the reason LaunchServices looks like it hangs; 2 is the stable bring-up
# choice (6/8 hit the pset0 ticket lock, see NOTES.md). No rd=: the app appends
# rd=ufsroot0 itself when the command line has none, so keep it out.
VM = " ".join([
    "debug=0xc",
    "serial=3",
    "cpus=2",
    "keepsyms=1",
    "-noprogress",
    "unentitled_ios_sim_launch=1",
    "ignition_level=1",
    "wdt_test=no_user_checkin",
    "ufsrw=1",
    "rootrw=1",
    "launchd_unsecure_cache=1",
    "wdt=-1",
    "sweetfb_noconsole=1",
    "sweetfb_hz=30",
    "ufscache=1",
    "ufswait=1",
    # A TCG vCPU can hold a lock through a >125 ms host I/O stall; XNU's
    # default ticket/spin timeouts (tlto_us/slto_us) then fire a misleading
    # "Ticket spinlock timeout" panic. 2 s is enough to ride out the stall.
    "tlto_us=2000000",
    "slto_us=2000000",
])

PROFILES = {
    "device": DEVICE,
    "timing": TIMING,
    "vm": VM,
    "vm-sample": VM + " sweetsample=SpringBoard,backboardd,lsd,containermanagerd",
    # Same as `vm` with two vCPUs that actually run in parallel: VmEngine turns
    # `tcgmulti=1` into -accel tcg,thread=multi (XNU ignores the token).
    "vm-mttcg": VM + " tcgmulti=1",
    "vm-offload": VM + " sweetfb_offload=1",
    # 375x812 points at 2x: the same UIKit layout with 44.5% of the pixels.
    # Use mkadt.py --fb-width 750 --fb-height 1624 --display-scale 2.
    "vm-2x": VM + " sweetfb_native=1 sweetfb_w=750 sweetfb_h=1624",
    # Touch is dead under vmios until kernel patch 0085 (the RPMh rail vote
    # fails with ENODEV and used to abort the GT9896 probe). Until that kernel
    # is built, sweethidtest drives a Home press every N seconds through
    # IOHIDEventService, which needs no PMIC and is what the Setup "Hello"
    # screen accepts.
    "vm-hidtest": VM + " sweetkeys=1 sweethidtest=10",
    # lsd is the daemon the 4-minute stall sits behind; backboardd and
    # containermanagerd are the next suspects.
    "sample": TIMING + " sweetsample=SpringBoard,lsd,backboardd,containermanagerd",
    "qemu": "debug=0x8 serial=3 cpus=1 keepsyms=1 -noprogress rd=md0",
    "probe": "debug=0x8 serial=3 cpus=1 keepsyms=1",
}


def check(name):
    cmd = PROFILES[name]
    if len(cmd) >= BOOT_LINE_LENGTH:
        raise SystemExit("profile %s is %d bytes, limit is %d"
                         % (name, len(cmd), BOOT_LINE_LENGTH - 1))
    return cmd


def main(argv):
    if not argv:
        print(check("device"))
        return 0
    if argv[0] in ("-l", "--list"):
        for name in PROFILES:
            print("%-8s %3d bytes  %s" % (name, len(PROFILES[name]), check(name)[:60] + "..."))
        return 0
    name, rest = argv[0], argv[1:]
    if name not in PROFILES:
        raise SystemExit("unknown profile %r (have: %s)" % (name, ", ".join(PROFILES)))
    cmd = check(name)
    if rest[:1] == ["--add"]:
        for extra in rest[1:]:
            if extra.split("=")[0] + "=" not in cmd:
                cmd += " " + extra
        if len(cmd) >= BOOT_LINE_LENGTH:
            raise SystemExit("too long: %d bytes" % len(cmd))
    print(cmd)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
