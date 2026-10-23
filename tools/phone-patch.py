#!/usr/bin/env python3
"""Patch the two shared-cache sites inside the image on a phone, through adb.

The VM's root image is an app-private file, so it cannot be pushed to; it is
patched as one 4 KiB block at a time: read the block, check the site bytes are
exactly what tools/dsc_patch_sites.py expects, change 4 bytes, write the block
back with dd conv=notrunc, read it back and compare the whole block.

  python3 tools/phone-patch.py patch      # apply the bring-up set
  python3 tools/phone-patch.py revert     # put the saved blocks back
  python3 tools/phone-patch.py status

Offsets come from `python3 tools/image-patch.py find IMAGE` on a local copy of
the same image; they are the same physical bytes.
"""
import base64
import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dsc_patch_sites import BRINGUP, PRESETS  # noqa: E402

ADB = os.environ.get("ADB") or next(
    (p for p in ("./.tools/platform-tools/adb.exe", "./.tools/platform-tools/adb",
                 "adb", "adb.exe") if shutil.which(p) or os.path.exists(p)), "adb")
PKG = "dev.hackios.sweetvm"
GUEST = "files/ios16-root.img"
BLOCK = 4096
# image offset -> preset, from tools/image-patch.py find
SITES = {0x13F9C26B4: "metal-wait-300ms", 0x19D2EFC98: "iosurface-wait-3s"}
STATE = r"./.tools/phone-patch.json"


def sh(arg):
    return subprocess.run([ADB, "shell", arg], capture_output=True).stdout


def read_block(blk):
    out = sh("run-as %s dd if=%s bs=%d skip=%d count=1 2>/dev/null | base64" % (PKG, GUEST, BLOCK, blk))
    txt = out.replace(b"\r", b"").replace(b"\n", b"")
    return base64.b64decode(txt)


def write_block(blk, data):
    assert len(data) == BLOCK
    b64 = os.path.abspath(r"./.tools/write.b64")
    with open(b64, "w") as f:
        f.write(base64.b64encode(data).decode())
    subprocess.run([ADB, "push", b64, "/data/local/tmp/write.b64"], capture_output=True)
    out = sh("base64 -d < /data/local/tmp/write.b64 | run-as %s sh -c "
             "'dd of=%s bs=%d seek=%d count=1 conv=notrunc'" % (PKG, GUEST, BLOCK, blk))
    return out.decode("utf-8", "replace")


def plan():
    rows = []
    for at, name in sorted(SITES.items()):
        blk, off = divmod(at, BLOCK)
        rows.append((name, at, blk, off))
    return rows


def cmd_status():
    for name, at, blk, off in plan():
        blk_data = read_block(blk)
        cur = blk_data[off:off + 4].hex() if len(blk_data) == BLOCK else "short-read"
        p = PRESETS[name]
        state = {p["expect"]: "original", p["write"]: "patched"}.get(cur, "unknown")
        print("  %-20s block %d +0x%x  %s (%s)" % (name, blk, off, cur, state))


def cmd_patch():
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    state = {"blocks": []}
    if os.path.exists(STATE):
        state = json.load(open(STATE))
    saved = {b["blk"] for b in state["blocks"]}
    for name, at, blk, off in plan():
        data = read_block(blk)
        if len(data) != BLOCK:
            raise SystemExit("%s: short read (%d bytes)" % (name, len(data)))
        cur = data[off:off + 4].hex()
        p = PRESETS[name]
        if cur == p["write"]:
            print("  %-20s already patched" % name)
            continue
        if cur != p["expect"]:
            raise SystemExit("%s: block %d has %s, expected %s - wrong image?"
                             % (name, blk, cur, p["expect"]))
        if blk not in saved:
            state["blocks"].append({"blk": blk, "name": name, "before": data.hex()})
            with open(STATE, "w") as f:
                json.dump(state, f)
            print("  %-20s saved original block %d" % (name, blk))
        new = bytearray(data)
        new[off:off + 4] = bytes.fromhex(p["write"])
        msg = write_block(blk, bytes(new))
        back = read_block(blk)
        if back != bytes(new):
            raise SystemExit("%s: read-back mismatch after write (%s)" % (name, msg.strip()[:80]))
        if back[off:off + 4].hex() != p["write"]:
            raise SystemExit("%s: site not patched" % name)
        print("  %-20s %s -> %s  (block %d, verified)"
              % (name, cur, p["write"], blk))


def cmd_revert():
    state = json.load(open(STATE))
    for rec in state["blocks"]:
        data = bytes.fromhex(rec["before"])
        write_block(rec["blk"], data)
        if read_block(rec["blk"]) != data:
            raise SystemExit("revert read-back mismatch for block %d" % rec["blk"])
        print("  restored block %d (%s)" % (rec["blk"], rec["name"]))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    {"status": cmd_status, "patch": cmd_patch, "revert": cmd_revert}[cmd]()
