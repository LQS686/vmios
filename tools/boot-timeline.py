#!/usr/bin/env python3
"""Turn the SWEET console log into a boot timeline.

Kernel patch 0083 (boot-arg sweetts=1) prefixes every console line with
"[seconds.milliseconds] " taken from the ARM generic timer, which counts from
reset. This tool reads those prefixes and reports where the time actually went,
so the 31 s gap between the last early-boot line and launchd stops being a
mystery:

  tools/sweet-log-pull.sh logs/boot.txt
  python3 tools/boot-timeline.py logs/boot.txt

  # top gaps only, and a window around the 200 s mark
  python3 tools/boot-timeline.py logs/boot.txt --gaps 12
  python3 tools/boot-timeline.py logs/boot.txt --around 200

  # straight from the raw 4 MiB partition area (no sweet-log.py step)
  python3 tools/boot-timeline.py --bin logs/area.bin

Gaps are attributed "before -> after": the text printed last before the silence
is the thing that led into it, the text after it is what finally woke up.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

TS = re.compile(r"^\[\s*(\d{6})\.(\d{3})\]\s?(.*)$")


def parse(lines):
    """[(t, text, raw), ...] for the lines that carry a timestamp."""
    out = []
    for n, raw in enumerate(lines, 1):
        raw = raw.rstrip("\n")
        m = TS.match(raw)
        if not m:
            continue
        t = int(m.group(1)) + int(m.group(2)) / 1000.0
        out.append((t, m.group(3), n))
    return out


def tags(text):
    """Which subsystem the line came from, as far as the prefix says."""
    for key in ("SWEET UFS", "SWEET LOG", "SWEET FB", "SWEET TOUCH", "SWEET HID",
                "SWEET SAMPLE", "CRASH"):
        if text.startswith(key):
            return key
    if text.startswith("launchd") or "launchd" in text[:40]:
        return "launchd"
    return "userland" if text[:1].isalpha() else "kernel"


def gaps(timed, min_gap):
    out = []
    for (t0, s0, n0), (t1, s1, n1) in zip(timed, timed[1:]):
        d = t1 - t0
        if d >= min_gap:
            out.append((d, t0, s0, n0, t1, s1, n1))
    out.sort(reverse=True)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", nargs="?", help="console log as text")
    ap.add_argument("--bin", dest="area", help="raw SWEETLOG area (.bin) instead of text")
    ap.add_argument("--gaps", type=int, default=8, help="how many gaps to show (default 8)")
    ap.add_argument("--min-gap", type=float, default=0.2, help="ignore gaps under this (s)")
    ap.add_argument("--around", type=float, help="dump a window around this time (s)")
    ap.add_argument("--window", type=float, default=10.0)
    ap.add_argument("--all", action="store_true", help="also print the full timed log")
    a = ap.parse_args()

    if a.area:
        import sweetlog
        text = sweetlog.decode_file(a.area)
    elif a.log:
        text = open(a.log, "r", encoding="utf-8", errors="replace").read()
    else:
        ap.error("need a log file or --bin")

    lines = text.splitlines()
    timed = parse(lines)
    if not timed:
        print("no [seconds.milliseconds] prefixes in %d lines.\n"
              "Boot with the timing profile (`tools/mkpayload.py --profile timing`, "
              "or add sweetts=1) and pull the log again." % len(lines), file=sys.stderr)
        return 2

    span = timed[-1][0] - timed[0][0]
    print("boot timeline: %d timed lines of %d, %.1f s from %.3f s to %.3f s"
          % (len(timed), len(lines), span, timed[0][0], timed[-1][0]))

    gs = gaps(timed, a.min_gap)
    total = sum(g[0] for g in gs)
    print("silences >= %.1f s: %d, %.1f s in total (%.0f%% of the span)"
          % (a.min_gap, len(gs), total, 100.0 * total / span if span else 0))

    if gs:
        print("\nwhere the time went (largest first):")
        for d, t0, s0, n0, t1, s1, n1 in gs[:a.gaps]:
            print("  %7.3f s  %.3f -> %.3f  [%s]" % (d, t0, t1, tags(s0)))
            print("            before L%-5d %s" % (n0, s0.strip()[:120]))
            if t1 - t0 > 0.001:
                print("            after  L%-5d %s" % (n1, s1.strip()[:120]))

    if a.around is not None:
        lo, hi = a.around - a.window, a.around + a.window
        print("\nwindow %.1f..%.1f s:" % (lo, hi))
        prev = None
        for t, s, n in timed:
            if lo <= t <= hi:
                if prev is not None and t - prev >= a.min_gap:
                    print("           ... %.3f s of silence ..." % (t - prev))
                print("  %10.3f  L%-5d %s" % (t, n, s.strip()[:120]))
                prev = t

    if a.all:
        print()
        prev = None
        for t, s, n in timed:
            if prev is not None and t - prev >= a.min_gap:
                print("           ... %.3f s of silence ..." % (t - prev))
            print("  %10.3f  L%-5d %s" % (t, n, s.strip()[:120]))
            prev = t
    return 0


if __name__ == "__main__":
    sys.exit(main())
