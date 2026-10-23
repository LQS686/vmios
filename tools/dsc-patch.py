#!/usr/bin/env python3
"""Patch one instruction (or any byte range) in a split dyld shared cache.

The bring-up image has no usable GPU, but iOS userland polls for one with long
hard-coded timeouts (see BOOT_ANALYSIS.md). Those waits are inside the shared
cache, which the iOS root keeps as `dyld_shared_cache_arm64*`; this tool maps an
unslid VA to the right subcache member and file offset, verifies the bytes it is
about to replace, and edits them in place.

  # what is at a VA, and which file/offset backs it
  python3 tools/dsc-patch.py --at 0x18853e6b4 research/dsc-test

  # apply one named fix (dry run first, then -y)
  python3 tools/dsc-patch.py research/dsc-test --preset metal-wait-300ms -y

  # what a fully built root (or a mounted HFS image) is missing
  python3 tools/dsc-patch.py --root /mnt/iosroot --check

  # apply the bring-up set during a root build (idempotent)
  python3 tools/dsc-patch.py --root /mnt/iosroot --presets all -y \
      --undo-out /tmp/dsc-undo.json

  # undo, using the sidecar written by -y
  python3 tools/dsc-patch.py CACHE_DIR --restore CACHE_DIR/.dsc-patch-undo.json

CACHE_DIR holds dyld_shared_cache_arm64 and its .NN / .dylddata /
.dyldlinkedit members; --root accepts an iOS root instead and finds them.
Members are never re-signed: the SWEET root is unsealed and AMFI is permissive,
so the image keeps working (same as the MobileGestalt getter patch already in
the image).
"""
import argparse
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dsc_patch_sites import BRINGUP, CACHE_DIRS, CACHE_PREFIX, PRESETS  # noqa: E402


def members(cache_dir):
    out = []
    for name in sorted(os.listdir(cache_dir)):
        if name.startswith(CACHE_PREFIX):
            path = os.path.join(cache_dir, name)
            if os.path.isfile(path):
                out.append((name, path))
    if not out:
        raise SystemExit("no %s* in %s" % (CACHE_PREFIX, cache_dir))
    return out


def cache_dir_for(root):
    """Resolve an iOS root (or a mounted HFS image) to its cache directory."""
    for rel in CACHE_DIRS:
        path = os.path.join(root, rel)
        if not os.path.isdir(path):
            continue
        try:
            names = os.listdir(path)
        except OSError:
            continue
        if any(n.startswith(CACHE_PREFIX) for n in names):
            return path
    raise SystemExit("no %s* under %s (looked in %s)"
                     % (CACHE_PREFIX, root, ", ".join(CACHE_DIRS)))


def scan(cache_dir):
    """[(name, path, [(vmaddr, size, fileoff), ...]), ...] from each header."""
    table = []
    for name, path in members(cache_dir):
        with open(path, "rb") as f:
            hdr = f.read(0x200)
            if not hdr.startswith(b"dyld_v1"):
                continue
            mapping_offset, mapping_count = struct.unpack_from("<II", hdr, 16)
            f.seek(mapping_offset)
            raw = f.read(32 * mapping_count)
            segs = []
            for i in range(mapping_count):
                addr, size, foff = struct.unpack_from("<QQQ", raw, 32 * i)
                segs.append((addr, size, foff))
            table.append((name, path, segs))
    return table


def locate(table, va):
    for name, path, segs in table:
        for addr, size, foff in segs:
            if addr <= va < addr + size:
                return name, path, foff + (va - addr)
    raise SystemExit("VA 0x%x is not in any cache member" % va)


def show(path, off, va=0, n=16):
    with open(path, "rb") as f:
        f.seek(off)
        raw = f.read(n)
    try:
        from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
        for ins in Cs(CS_ARCH_ARM64, CS_MODE_ARM).disasm(raw, va):
            print("    0x%x  %-8s %s" % (ins.address, ins.mnemonic, ins.op_str))
    except ImportError:
        print("    bytes %s" % raw.hex())


def read_at(path, off, n):
    with open(path, "rb") as f:
        f.seek(off)
        return f.read(n).hex()


def record_undo(cache_dir, undo_out, rec):
    """Merge one patch record into the sidecar (outside the image by default)."""
    path = undo_out or os.path.join(cache_dir, ".dsc-patch-undo.json")
    undo = {"patches": []}
    if os.path.exists(path):
        try:
            undo = json.load(open(path))
        except ValueError:
            pass
    undo.setdefault("patches", []).append(rec)
    with open(path, "w") as f:
        json.dump(undo, f, indent=1)
    return path


def resolve_jobs(ns):
    """Turn the CLI into [(name, va, expect, write, why), ...]."""
    jobs = []
    if ns.at:
        if not (ns.expect and ns.write):
            raise SystemExit("--at needs --expect and --write")
        jobs.append(("at-0x%x" % int(ns.at, 16), int(ns.at, 16), ns.expect, ns.write, ""))
    names = []
    if ns.preset:
        names += [ns.preset]
    if ns.presets:
        names += [n for n in ns.presets.split(",") if n]
    for name in names:
        if name == "all":
            jobs += [(p, PRESETS[p]["va"], PRESETS[p]["expect"], PRESETS[p]["write"],
                      PRESETS[p]["why"]) for p in BRINGUP]
            continue
        if name not in PRESETS:
            raise SystemExit("unknown preset %r (have: %s)"
                             % (name, ", ".join(sorted(PRESETS))))
        p = PRESETS[name]
        jobs.append((name, p["va"], p["expect"], p["write"], p["why"]))
    if not jobs:
        raise SystemExit("nothing to do: --at, --preset, --presets, --root --check or --restore")
    return jobs


def restore(ns):
    undo = json.load(open(ns.restore))
    for rec in undo["patches"]:
        path = os.path.join(ns.cache_dir, rec["member"])
        with open(path, "r+b") as f:
            f.seek(rec["offset"])
            f.write(bytes.fromhex(rec["before"]))
        print("restored %s @0x%x -> %s" % (rec["member"], rec["offset"], rec["before"]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cache_dir", nargs="?", help="directory holding dyld_shared_cache_arm64*")
    ap.add_argument("--root", help="iOS root (or mounted image); finds the cache in it")
    ap.add_argument("--at", help="unslid VA, hex")
    ap.add_argument("--expect", help="expected current bytes, hex")
    ap.add_argument("--write", help="replacement bytes, hex")
    ap.add_argument("--preset", choices=sorted(PRESETS))
    ap.add_argument("--presets", help="comma separated presets, or 'all' for the bring-up set")
    ap.add_argument("--check", action="store_true",
                    help="report the state of every requested site, never write")
    ap.add_argument("--undo-out", help="write the undo sidecar here, not into the cache")
    ap.add_argument("--restore", help="undo sidecar JSON")
    ap.add_argument("-y", "--yes", action="store_true", help="actually write")
    ns = ap.parse_args()

    if ns.root:
        ns.cache_dir = cache_dir_for(ns.root)
    if not ns.cache_dir:
        ap.error("need cache_dir or --root")
    if not os.path.isdir(ns.cache_dir):
        raise SystemExit("not a directory: %s" % ns.cache_dir)

    if ns.restore:
        restore(ns)
        return

    jobs = resolve_jobs(ns)
    table = scan(ns.cache_dir)
    print("cache: %s (%d members)" % (ns.cache_dir, len(table)))

    pending, done, failed = [], [], []
    for name, va, expect, write, why in jobs:
        member, path, off = locate(table, va)
        cur = read_at(path, off, len(expect) // 2)
        print("  %-20s VA 0x%x -> %s @0x%x" % (name, va, member, off))
        if why:
            print("  %-20s %s" % ("", why))
        print("  %-20s current %s -> %s" % ("", cur, write))
        if cur == expect:
            pending.append((name, member, path, off, cur, write))
        elif cur == write:
            done.append(name)
        else:
            failed.append((name, cur, expect))
        if ns.check or ns.at:
            show(path, off, va)

    if failed:
        for name, cur, expect in failed:
            print("  %s: unexpected bytes %s (want %s) - wrong cache?" % (name, cur, expect))
        raise SystemExit("refusing to patch: %d site(s) do not match" % len(failed))

    print()
    if done:
        print("already patched: %s" % ", ".join(done))
    if not pending:
        print("nothing to do")
        return
    print("to patch: %s" % ", ".join(p[0] for p in pending))
    if ns.check:
        print("check only; nothing written")
        return
    if not ns.yes:
        print("dry run; pass -y to write")
        return

    undo_path = ns.undo_out
    for name, member, path, off, before, after in pending:
        with open(path, "r+b") as f:
            f.seek(off)
            f.write(bytes.fromhex(after))
        if read_at(path, off, len(after) // 2) != after:
            raise SystemExit("%s: read-back mismatch in %s @0x%x" % (name, member, off))
        undo_path = record_undo(ns.cache_dir, ns.undo_out,
                                {"member": member, "offset": off, "before": before,
                                 "after": after, "preset": name})
        print("  %-20s written %s -> %s (%s)" % (name, before, after, member))
    print("undo record: %s" % undo_path)


if __name__ == "__main__":
    main()
