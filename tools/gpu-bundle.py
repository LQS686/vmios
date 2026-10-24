#!/usr/bin/env python3
"""Pack a directory into the SGB1 blob the SWEET kernel installer writes.

  gpu-bundle.py pack DIR OUT.bin
  gpu-bundle.py list IN.bin

SGB1 layout (little endian):
  magic "SGB1" | u32 file_count
  per file: u16 name_len | name | u32 size | data
Names are relative paths with '/' separators and must not escape DIR.
"""
import os
import struct
import sys

MAGIC = b"SGB1"


def pack(root, out):
    files = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            data = open(path, "rb").read()
            if len(rel.encode()) > 4096 or len(data) > (1 << 20):
                raise SystemExit(f"{rel}: too large for SGB1")
            files.append((rel.encode(), data))
    blob = bytearray(MAGIC)
    blob += struct.pack("<I", len(files))
    for name, data in files:
        blob += struct.pack("<H", len(name)) + name + struct.pack("<I", len(data)) + data
    open(out, "wb").write(blob)
    print(f"{out}: {len(blob)} bytes, {len(files)} files", file=sys.stderr)
    for name, data in files:
        print(f"  {name.decode()} {len(data)}", file=sys.stderr)


def list_blob(path):
    blob = open(path, "rb").read()
    if blob[:4] != MAGIC:
        raise SystemExit("not an SGB1 blob")
    count, = struct.unpack_from("<I", blob, 4)
    off = 8
    for i in range(count):
        n, = struct.unpack_from("<H", blob, off)
        off += 2
        name = blob[off:off + n].decode()
        off += n
        size, = struct.unpack_from("<I", blob, off)
        off += 4
        print(f"{i}: {name} {size}")
        off += size
    if off != len(blob):
        raise SystemExit(f"trailing bytes: {len(blob) - off}")


if __name__ == "__main__":
    if len(sys.argv) != 4 and len(sys.argv) != 3:
        sys.exit(__doc__)
    if sys.argv[1] == "pack":
        pack(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "list":
        list_blob(sys.argv[2])
    else:
        sys.exit(__doc__)
