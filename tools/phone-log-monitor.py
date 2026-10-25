#!/usr/bin/env python3
"""Stream the SWEET console log ring out of a running vmios VM on Android.

  tools/phone-log-monitor.py [--pkg PKG] [--interval SECS] [--follow/-f]

The ring lives in the last 1025 blocks of the guest root image. Its header
carries the monotonic byte count, so each poll fetches the ring area, decodes
it and prints only the bytes written since the previous poll. Read-only.
"""
import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sweetlog  # noqa: E402

BS = 4096
TOTAL_BLOCKS = 4194304 // BS
SKIP = 4194304 - (TOTAL_BLOCKS + 1)   # image blocks: header + 4 MiB ring at the end


def default_adb():
    cand = os.path.join(HERE, "..", ".tools", "platform-tools", "adb.exe")
    return os.path.abspath(cand)


def read_area(adb, pkg, image):
    cmd = [adb, "exec-out", "run-as", pkg, "dd", "if=" + image,
           "bs=%d" % BS, "skip=%d" % SKIP, "count=%d" % (TOTAL_BLOCKS + 1)]
    out = subprocess.run(cmd, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, check=True).stdout
    if len(out) < (TOTAL_BLOCKS + 1) * BS:
        raise RuntimeError("short read: %d bytes" % len(out))
    return out


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--pkg", default=os.environ.get("VMIOOS_PKG", "dev.hackios.sweetvm"))
    ap.add_argument("--image", default="files/ios16-root.img")
    ap.add_argument("--adb", default=default_adb())
    ap.add_argument("--interval", type=float, default=3.0)
    ap.add_argument("-f", "--follow", action="store_true",
                    help="keep polling; default prints one snapshot")
    ap.add_argument("--tail", type=int, default=60,
                    help="lines of history to print on start")
    args = ap.parse_args(argv)

    last_total = None
    while True:
        try:
            area = read_area(args.adb, args.pkg, args.image)
        except (subprocess.CalledProcessError, RuntimeError) as e:
            print("monitor: read failed: %s" % e, file=sys.stderr)
            if not args.follow:
                return 1
            time.sleep(args.interval)
            continue
        text, meta = sweetlog.decode_bytes(area)
        total = meta["total"]
        if last_total is None:
            print("# ring %d bytes, guest wrote %d, flush #%d%s" % (
                meta["size"], total, meta["seq"],
                " (wrapped)" if meta["wrapped"] else ""), file=sys.stderr)
            lines = text.splitlines(True)
            sys.stdout.write("".join(lines[-args.tail:]) if args.tail else "")
        elif total > last_total:
            fresh = total - last_total
            if fresh > len(text):
                fresh = len(text)
            sys.stdout.write(text[-fresh:])
        elif total < last_total:
            print("monitor: guest log reset (%d -> %d)" % (last_total, total),
                  file=sys.stderr)
            sys.stdout.write(text)
        sys.stdout.flush()
        last_total = total
        if not args.follow:
            return 0
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
