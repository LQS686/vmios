#!/usr/bin/env python3
"""Compare two vmios boot runs by guest time, not wall time.

The kernel's log thread flushes the ring every ufslogsecs (10 s), and the flush
sequence number in the SWEETLOG header counts those intervals, so (seq, total)
is a guest-time curve that does not care when the host started polling. The
Metal and IOSurface waits are usleep/sleep loops in guest time, so this is the
right axis for an A/B.

  python3 .tools/compare-runs.py base.csv base.log patched.csv patched.log
"""
import csv
import sys

MARKERS = [
    "Darwin Kernel",
    "load_init_program",
    "exec SpringBoard",
    "exec backboardd",
    "SWEET FB: 1000 swaps",
    "SWEET FB: 2000 swaps",
    "SMP --- sample",
]


def load(csv_path, log_path):
    rows = []
    for r in list(csv.reader(open(csv_path, encoding="utf-8")))[1:]:
        if len(r) >= 3:
            rows.append((float(r[0]), int(r[1]), int(r[2])))
    # Drop the samples taken before this boot started: the SWEETLOG header still
    # holds the previous boot's total and sequence until the first flush.
    for i in range(1, len(rows)):
        if rows[i][1] < rows[i - 1][1] or rows[i][2] < rows[i - 1][2]:
            rows = rows[i:]
            break
    text = open(log_path, encoding="utf-8", errors="replace").read()
    return rows, text


def curve(rows):
    """seq -> total, keeping the last sample seen for each sequence number."""
    out = {}
    for _, total, seq in rows:
        if seq:
            out[seq] = max(total, out.get(seq, 0))
    return out


def marker_offset(text, marker):
    """Byte offset of a marker in the decoded log (= its position in the ring)."""
    return text.find(marker)


def seq_for_offset(cur, off):
    for seq in sorted(cur):
        if cur[seq] >= off:
            return seq
    return None


def main():
    a_csv, a_log, b_csv, b_log = sys.argv[1:5]
    a_rows, a_text = load(a_csv, a_log)
    b_rows, b_text = load(b_csv, b_log)
    a_cur, b_cur = curve(a_rows), curve(b_rows)

    print("guest-time curve (bytes logged by the end of each 10 s flush):")
    print("  seq  guest_s %8s %8s" % ("base", "patched"))
    for seq in sorted(set(a_cur) | set(b_cur)):
        av = a_cur.get(seq, 0)
        bv = b_cur.get(seq, 0)
        mark = ""
        if av and bv and abs(bv - av) > max(2000, 0.15 * av):
            mark = "  <-- %.2fx" % (bv / av) if av else ""
        print("  %3d  %6d  %8d %8d%s" % (seq, seq * 10, av, bv, mark))

    print("\nmilestones (guest second derived from the curve):")
    print("  %-22s %-18s %-18s" % ("marker", "base", "patched"))
    for m in MARKERS:
        cells = []
        for text, cur in ((a_text, a_cur), (b_text, b_cur)):
            off = marker_offset(text, m)
            if off is None or off < 0:
                cells.append("absent")
            else:
                seq = seq_for_offset(cur, off)
                cells.append("seq %d (~%ds)" % (seq, seq * 10) if seq else "beyond log")
        print("  %-22s %-18s %-18s" % (m, cells[0], cells[1]))

    print("\nlast flush of each run: base seq %d / %d bytes, patched seq %d / %d bytes"
          % (max(a_cur), max(a_cur.values()), max(b_cur), max(b_cur.values())))


if __name__ == "__main__":
    main()
