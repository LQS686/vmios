#!/usr/bin/env python3
"""Poll a running vmios's kernel log ring through adb, for A/B boot timing.

The kernel's persistent log lives in the last 1025 blocks of the userdata
image (kernel patch 0047): block 0 is "SWEETLOG" + total bytes written + flush
sequence, the 4 MiB ring follows. Inside the VM the image is an app-private
file, so it is read with `run-as` + dd + base64 (adb on Windows mangles binary
stdout, base64 does not; dd is also block-addressed here, toybox's bs=1 skip is
useless at a 16 GiB offset).

  python3 tools/vm-probe.py out.csv [SECONDS] [INTERVAL]
"""
import base64
import os
import shutil
import subprocess
import sys
import time

ADB = os.environ.get("ADB") or next(
    (p for p in ("./.tools/platform-tools/adb.exe", "./.tools/platform-tools/adb",
                 "adb", "adb.exe") if shutil.which(p) or os.path.exists(p)), "adb")
PKG = "dev.vmios.sweetvm"
GUEST = "files/ios16-root.img"
BLOCK = 4096
IMAGE = 17179869184
AREA = IMAGE - 1025 * BLOCK          # SWEET_LOG_BLOCKS = 1 + 4 MiB / 4096


def read(blk, count):
    # No shell on the host: adb passes the string to the device's sh, which is
    # where the pipe belongs. Windows' cmd.exe would eat the quotes.
    arg = "run-as %s dd if=%s bs=%d skip=%d count=%d 2>/dev/null | base64" % (
        PKG, GUEST, BLOCK, blk, count)
    out = subprocess.run([ADB, "shell", arg], capture_output=True).stdout
    txt = out.replace(b"\r", b"").replace(b"\n", b"")
    try:
        return base64.b64decode(txt)
    except Exception:
        return b""


def header():
    d = read(AREA // BLOCK, 1)
    if len(d) < 32 or d[:8] != b"SWEETLOG":
        return None, 0, 0
    return "ok", int.from_bytes(d[16:24], "little"), int.from_bytes(d[24:32], "little")


def tail(total, n=600):
    """Last n bytes of this boot's log (ring offset n % size)."""
    size = 4 << 20
    start = max(0, total - n)
    off = AREA + BLOCK + (start % size)
    blk = off // BLOCK
    raw = read(blk, 2)
    return raw[off - blk * BLOCK:off - blk * BLOCK + n].decode("utf-8", "replace")


def main():
    out = sys.argv[1]
    secs = int(sys.argv[2]) if len(sys.argv) > 2 else 300
    every = int(sys.argv[3]) if len(sys.argv) > 3 else 5
    t0 = time.time()
    with open(out, "w", encoding="utf-8") as f:
        f.write("wall_s,total,seq,tail\n")
        while time.time() - t0 < secs:
            ok, total, seq = header()
            txt = ""
            if ok and total:
                txt = tail(total).replace("\n", " | ").replace("\r", "").replace(",", ";")[-150:]
            f.write("%.1f,%d,%d,%s\n" % (time.time() - t0, total, seq, txt))
            f.flush()
            time.sleep(every)
    print("probe done", out)


if __name__ == "__main__":
    main()
