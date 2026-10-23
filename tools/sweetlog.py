#!/usr/bin/env python3
"""Decode the SWEET persistent console log ring (kernel patch 0047).

Shared by tools/sweet-log.py (CLI) and tools/boot-timeline.py (--bin).

The area is the last (1 + ring/4096) device blocks of the userdata partition
as read by tools/sweet-log-pull.sh: block 0 is the header
("SWEETLOG", u32 version, u32 ring size, u64 total bytes, u64 flush seq),
the ring follows, and byte n of the console stream lives at ring offset
n % size.
"""
import struct


def decode_bytes(data):
    """(text, meta) for a raw log area; raises ValueError if it has no header."""
    magic, version, size, total, seq = struct.unpack_from("<8sIIQQ", data, 0)
    if magic != b"SWEETLOG":
        raise ValueError("no SWEETLOG header (log never flushed, or wrong area)")
    ring = data[4096:4096 + size]
    if total <= size:
        text = ring[:total]
    else:
        start = total % size
        text = ring[start:] + ring[:start]
    meta = dict(version=version, size=size, total=total, seq=seq,
                wrapped=total > size)
    return text.decode("utf-8", "replace").replace("\r", ""), meta


def decode_file(path):
    with open(path, "rb") as f:
        return decode_bytes(f.read())[0]
