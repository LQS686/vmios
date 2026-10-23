#!/usr/bin/env python3
"""Patch one instruction in a built SWEET kernel, in the kernel or in a payload.

Kernel behaviour changes normally go through xnu/patches/ and a CI build. When a
fix has to land without one - the host has no Xcode - the same change can be
applied to an already built kernel: each site names an unslid VA, the bytes it
expects there, and the bytes to write. A wrong VA, a stale build, or a second
apply all fail the byte check instead of corrupting the image.

  # what is at a site, in a kernel or in a packed payload
  python3 tools/kernel-patch.py show  xnu/out/kernel.development.sweet --preset touch-skip-rail-vote
  python3 tools/kernel-patch.py show  payload.bin --preset touch-skip-rail-vote

  # apply (keeps an undo file) and verify by reading the bytes back
  python3 tools/kernel-patch.py apply payload.bin --preset touch-skip-rail-vote -y

  python3 tools/kernel-patch.py restore payload.bin --undo payload.bin.undo.json

A SWEETXNU payload (tools/mkpayload.py) carries the kernel segments and the ADT
as separate pieces, so patching the payload keeps the ADT and the command line
exactly as they were - only the four bytes change.
"""
import argparse
import json
import os
import struct
import sys

PAYLOAD_MAGIC = b"SWEETXNU"
CMDLINE, SEG_TABLE = 0x48, 0x2A8

PRESETS = {
    # bsd/dev/sweet_touch.c, sweet_touch_init(): the L11C rail vote aborts the
    # whole GT9896 bring-up when it fails. Under SweetVM the RPMh block is not
    # emulated and every register reads back 0xffffffff, so the vote returns
    # ENODEV and touch never appears - not even a tap. Turn the conditional
    # branch into an unconditional jump to the probe path (kernel 0085 does the
    # same thing in source: warn and keep going).
    "touch-skip-rail-vote": {
        "va": 0xFFFFFE00074E9AAC,
        "expect": "a0000034",       # cbz w0, 0xfffffe00074e9ac0
        "write": "05000014",        # b    0xfffffe00074e9ac0
        "why": "sweet_touch_init: ignore the L11C vote result, always probe",
    },
    # bsd/dev/sweet_touch.c, touch_goodix(): a frame whose bit 7 is clear is
    # treated as "no new touch frame: retain current contacts" and returns 0.
    # The QEMU GT9896 model emits exactly that shape for a release (it only sets
    # bit 7 while the state file says down), so the finger is never lifted and
    # no gesture can finish. Redirect that return to the touch_report(0, x, y)
    # call site at the end of the function: w0 is still 0 there (touch_read
    # returned success), so the call releases every active contact.
    "touch-release-on-empty-frame": {
        "va": 0xFFFFFE00074EA06C,
        "expect": "13000014",       # b 0xfffffe00074ea0b8  (epilogue, return 0)
        "write": "4e000014",        # b 0xfffffe00074ea1a4  (touch_report(0, x, y))
        "why": "touch_goodix: an empty frame releases the contacts instead of holding them",
    },
}


class Image:
    """A kernel Mach-O or a SWEETXNU payload; both map an unslid VA to a file offset."""

    def __init__(self, path):
        self.path = path
        self.data = bytearray(open(path, "rb").read())
        self.segments = []
        if self.data[:8] == PAYLOAD_MAGIC:
            self.kind = "payload"
            nsegs = struct.unpack_from("<I", self.data, 12)[0]
            for i in range(nsegs):
                vmaddr, vmsize, foff, fsize = struct.unpack_from("<4Q", self.data, SEG_TABLE + 32 * i)
                self.segments.append((vmaddr, vmsize, foff, fsize))
        else:
            self.kind = "kernel"
            magic, _, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<IiiIIIII", self.data, 0)
            if magic != 0xFEEDFACF:
                raise SystemExit("%s: neither a SWEETXNU payload nor a thin 64-bit Mach-O" % path)
            off = 32
            for _ in range(ncmds):
                cmd, cmdsize = struct.unpack_from("<II", self.data, off)
                if cmd == 0x19:
                    vmaddr, vmsize, foff, fsize = struct.unpack_from("<QQQQ", self.data, off + 24)
                    self.segments.append((vmaddr, vmsize, foff, fsize))
                off += cmdsize

    def offset(self, va):
        for vmaddr, vmsize, foff, fsize in self.segments:
            if vmaddr <= va < vmaddr + vmsize:
                inner = va - vmaddr
                if inner >= fsize:
                    raise SystemExit("VA 0x%x is in %s's zero-fill area" % (va, self.kind))
                return foff + inner
        raise SystemExit("VA 0x%x is not mapped by this %s" % (va, self.kind))

    def read(self, va, n):
        off = self.offset(va)
        return bytes(self.data[off:off + n])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=("show", "apply", "restore"))
    ap.add_argument("image")
    ap.add_argument("--preset", choices=sorted(PRESETS))
    ap.add_argument("--undo", help="undo sidecar (default IMAGE.undo.json)")
    ap.add_argument("-y", "--yes", action="store_true")
    a = ap.parse_args()

    undo_path = a.undo or (a.image + ".undo.json")
    if a.cmd == "restore":
        if not a.undo:
            raise SystemExit("--undo FILE is required")
        undo = json.load(open(a.undo))
        img = Image(a.image)
        for rec in undo["patches"]:
            off = img.offset(rec["va"])
            img.data[off:off + 4] = bytes.fromhex(rec["before"])
        open(a.image, "wb").write(img.data)
        print("restored %d site(s) in %s" % (len(undo["patches"]), a.image))
        return 0

    if not a.preset:
        raise SystemExit("--preset is required (have: %s)" % ", ".join(sorted(PRESETS)))
    p = PRESETS[a.preset]
    img = Image(a.image)
    cur = img.read(p["va"], 4).hex()
    print("%s (%s): VA 0x%x -> file 0x%x" % (a.preset, img.kind, p["va"], img.offset(p["va"])))
    print("  %s" % p["why"])
    print("  current %s" % cur)
    if cur == p["write"]:
        print("  already patched")
        return 0
    if cur != p["expect"]:
        raise SystemExit("  expected %s - wrong build or wrong site" % p["expect"])
    print("  new     %s" % p["write"])
    if a.cmd == "show" or not a.yes:
        print("dry run; pass -y to write")
        return 0

    off = img.offset(p["va"])
    img.data[off:off + 4] = bytes.fromhex(p["write"])
    open(a.image, "wb").write(img.data)
    if Image(a.image).read(p["va"], 4).hex() != p["write"]:
        raise SystemExit("read-back mismatch")
    undo = {"patches": []}
    if os.path.exists(undo_path):
        try:
            undo = json.load(open(undo_path))
        except ValueError:
            pass
    undo.setdefault("patches", []).append({"va": p["va"], "preset": a.preset, "before": cur,
                                           "after": p["write"]})
    json.dump(undo, open(undo_path, "w"), indent=1)
    print("written and verified; undo record in %s" % undo_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
