#!/usr/bin/env python3
"""Decode the SWEET persistent console log (kernel patch 0047).

  sweet-log.py AREA.bin [OUT.txt]

AREA.bin is the last (1 + ring/4096) device blocks of the userdata
partition as read by tools/sweet-log-pull.sh: block 0 is the header
("SWEETLOG", u32 version, u32 ring size, u64 total bytes, u64 flush seq),
the ring follows. Byte n of the console stream is at ring offset n % size.
The decoding itself lives in tools/sweetlog.py, shared with boot-timeline.py.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sweetlog  # noqa: E402


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    try:
        text, meta = sweetlog.decode_bytes(open(sys.argv[1], "rb").read())
    except ValueError as e:
        sys.exit(str(e))
    print("# version %d, ring %d, total %d bytes, flush #%d%s"
          % (meta["version"], meta["size"], meta["total"], meta["seq"],
             " (wrapped: oldest bytes lost)" if meta["wrapped"] else ""),
          file=sys.stderr)
    if len(sys.argv) > 2:
        open(sys.argv[2], "w").write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
