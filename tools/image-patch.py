#!/usr/bin/env python3
"""Find and patch the split dyld shared cache inside a raw disk image.

tools/dsc-patch.py needs a directory (a mounted root, or an extracted cache).
Most of the time the cache only exists inside the 16 GB HFS+ root image, and
Windows cannot mount HFS+ at all. This tool does not care about the filesystem:
a split-cache member starts with "dyld_v1", and the bring-up patch sites are at
fixed offsets inside their members, so scanning for the magic and checking the
two byte patterns locates the exact physical offset in the image. Nothing else
in the image has that combination.

  # which members are in this image, and are they patched?
  python3 tools/image-patch.py find ios16-root.img

  # apply the bring-up set in place (writes 4 bytes, keeps a block-level undo)
  python3 tools/image-patch.py apply ios16-root.img --presets all -y

  # undo
  python3 tools/image-patch.py restore ios16-root.img --undo ios16-root.img.undo.json

  # an image on a phone (app-private path, read through run-as): the shell
  # commands to read/patch one 4 KiB block, since adb cannot push into app data
  python3 tools/image-patch.py phone ios16-root.img dev.hackios.sweetvm files/ios16-root.img

Hard links (mkiosroot.sh links the cryptex cache into
/System/Library/Caches/com.apple.dyld) share blocks, so one physical site
serves both paths; find reports every distinct site it sees.
"""
import argparse
import json
import mmap
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dsc_patch_sites as sites  # noqa: E402

MAGIC = b"dyld_v1"
BLOCK = 4096


def member_site_offset(mm, member_start, va):
    """File offset of `va` inside the subcache whose header is at member_start.

    A subcache's VAs are not file offsets: the header holds a mapping table of
    (vmaddr, size, fileoff) and the site is at fileoff + (va - vmaddr). Returns
    None if this member does not map the VA at all.
    """
    hdr = mm[member_start:member_start + 0x20]
    if len(hdr) < 0x20 or not hdr.startswith(MAGIC):
        return None
    mapping_offset, mapping_count = struct.unpack_from("<II", hdr, 16)
    if mapping_count == 0 or mapping_count > 64:
        return None
    raw = mm[member_start + mapping_offset:member_start + mapping_offset + 32 * mapping_count]
    if len(raw) < 32 * mapping_count:
        return None
    for i in range(mapping_count):
        addr, size, foff = struct.unpack_from("<QQQ", raw, 32 * i)
        if addr <= va < addr + size:
            return member_start + foff + (va - addr)
    return None


def scan(path, presets):
    """[(preset_name, member_offset, site_offset, current_hex)] for each hit."""
    size = os.path.getsize(path)
    by_va = {sites.PRESETS[n]["va"]: n for n in presets}
    found = []
    with open(path, "rb") as f:
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            pos, seen = 0, 0
            while True:
                pos = mm.find(MAGIC, pos)
                if pos < 0:
                    break
                seen += 1
                for va, name in by_va.items():
                    at = member_site_offset(mm, pos, va)
                    if at is None or at + 4 > size:
                        continue
                    cur = mm[at:at + 4].hex()
                    p = sites.PRESETS[name]
                    if cur in (p["expect"], p["write"]):
                        found.append((name, pos, at, cur))
                pos += 1
        finally:
            mm.close()
    return found, seen


def apply(path, hits, undo_path):
    undo = {"image": os.path.abspath(path), "blocks": []}
    if os.path.exists(undo_path):
        try:
            undo = json.load(open(undo_path))
        except ValueError:
            pass
    todo = [h for h in hits if h[3] == sites.PRESETS[h[0]]["expect"]]
    if not todo:
        print("nothing to patch")
        return 0
    with open(path, "r+b") as f:
        done_blocks = set()
        for name, member, at, cur in todo:
            block_start = at - (at % BLOCK)
            if block_start not in done_blocks:
                f.seek(block_start)
                before = f.read(BLOCK)
                undo["blocks"].append({"offset": block_start, "before": before.hex()})
                done_blocks.add(block_start)
            write = sites.PRESETS[name]["write"]
            f.seek(at)
            f.write(bytes.fromhex(write))
        f.flush()
        os.fsync(f.fileno())
        # read back
        bad = []
        for name, member, at, cur in todo:
            f.seek(at)
            if f.read(4).hex() != sites.PRESETS[name]["write"]:
                bad.append(name)
    with open(undo_path, "w") as u:
        json.dump(undo, u)
    for name, member, at, cur in todo:
        print("  %-20s member@0x%-10x site@0x%-10x %s -> %s"
              % (name, member, at, cur, sites.PRESETS[name]["write"]))
    print("undo (%d blocks, %d bytes) written to %s"
          % (len(undo["blocks"]), len(undo["blocks"]) * BLOCK, undo_path))
    if bad:
        print("READ-BACK FAILED for: %s" % ", ".join(bad))
        return 1
    print("read-back verified")
    return 0


def restore(path, undo_path):
    undo = json.load(open(undo_path))
    with open(path, "r+b") as f:
        for rec in undo["blocks"]:
            data = bytes.fromhex(rec["before"])
            f.seek(rec["offset"])
            f.write(data)
            f.seek(rec["offset"])
            if f.read(len(data)) != data:
                raise SystemExit("restore read-back mismatch at 0x%x" % rec["offset"])
        f.flush()
        os.fsync(f.fileno())
    print("restored %d blocks from %s" % (len(undo["blocks"]), undo_path))


def phone(hits, pkg, guest):
    """Shell snippets to read and write the patched blocks through run-as."""
    for name, member, at, cur in hits:
        blk, off = divmod(at, BLOCK)
        print("# %s: site 0x%x (image offset), block %d, +0x%x" % (name, at, blk, off))
        print("adb exec-out run-as %s dd if=%s bs=%d skip=%d count=1 > blk_%d.bin"
              % (pkg, guest, BLOCK, blk, blk))
        print("adb push blk_%d.bin /sdcard/blk_%d.bin" % (blk, blk))
        print("adb shell \"cat /sdcard/blk_%d.bin | run-as %s sh -c "
              "'dd of=%s bs=%d seek=%d count=1 conv=notrunc'\""
              % (blk, pkg, guest, BLOCK, blk))
        print()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=("find", "apply", "restore", "phone"))
    ap.add_argument("image")
    ap.add_argument("--presets", default="all", help="'all' or comma separated names")
    ap.add_argument("--undo", help="undo sidecar (default IMAGE.undo.json)")
    ap.add_argument("--pkg", default="dev.hackios.sweetvm")
    ap.add_argument("--guest", default="files/ios16-root.img")
    ap.add_argument("-y", "--yes", action="store_true")
    a = ap.parse_args()

    undo_path = a.undo or (a.image + ".undo.json")
    if a.cmd == "restore":
        if not a.undo:
            raise SystemExit("--undo FILE is required for restore")
        restore(a.image, a.undo)
        return 0

    names = list(sites.BRINGUP) if a.presets == "all" else [n for n in a.presets.split(",") if n]
    for n in names:
        if n not in sites.PRESETS:
            raise SystemExit("unknown preset %r" % n)

    print("scanning %s (%.1f GiB) for %d site(s)..." % (a.image, os.path.getsize(a.image) / 2**30, len(names)))
    hits, seen = scan(a.image, names)
    print("%d dyld_v1 magic(s) found" % seen)
    if not hits:
        raise SystemExit("no member carries the expected bytes; wrong image or already patched differently")
    for name, member, at, cur in hits:
        state = "needs patch" if cur == sites.PRESETS[name]["expect"] else "already patched"
        print("  %-20s member@0x%-10x site@0x%-10x %s (%s)"
              % (name, member, at, cur, state))

    if a.cmd == "find":
        return 0
    if a.cmd == "phone":
        phone(hits, a.pkg, a.guest)
        return 0
    if not a.yes:
        print("\ndry run; pass -y to write")
        return 0
    return apply(a.image, hits, undo_path)


if __name__ == "__main__":
    sys.exit(main())
