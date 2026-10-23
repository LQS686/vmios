#!/usr/bin/env python3
"""Resolve kernel sampler backtraces (spotlight/SMP lines) to iOS dylibs.

The phone's kernel log only has raw addresses; `ipsw dyld a2s` needs macOS.
This walks the split dyld_shared_cache in research/dsc.tar, builds the image
address map from the main cache's imagesText table, and resolves every frame
of every `SMP <name>[pid] ... pc/lr/sp/bt` block to `dylib+offset`, optionally
naming the nearest symbol when the dylib was extracted to research/dsc-extract.

  python3 tools/dsc-frames.py LOG [LOG...] [--dylibs DIR] [--only NAME]
"""
import argparse
import bisect
import json
import os
import re
import struct
import sys
import tarfile

CACHE_MAIN = "dyld_shared_cache_arm64"


class Cache:
    def __init__(self, tar_path):
        self.tar_path = tar_path
        self.t = tarfile.open(tar_path, "r:")
        self.members = {m.name.split("/")[-1]: m for m in self.t.getmembers() if m.isfile()}
        self.index_path = os.path.join(os.path.dirname(tar_path), "dsc-index.json")
        self.images, self.maps = self._load_index()

    # ------------------------------------------------------------------ index
    def _read_member_head(self, name, n=0x200):
        f = self.t.extractfile(self.members[name])
        return f.read(n)

    def _load_index(self):
        if os.path.exists(self.index_path):
            with open(self.index_path) as f:
                d = json.load(f)
            return d["images"], d["maps"]

        main = self._read_member_head(CACHE_MAIN, 0x4000)
        images_text_off, images_text_count = struct.unpack_from("<QQ", main, 0x88)
        f = self.t.extractfile(self.members[CACHE_MAIN])
        images = []
        for i in range(images_text_count):
            f.seek(images_text_off + i * 32)
            _uuid, load_addr, text_size, path_off = struct.unpack("<16sQII", f.read(32))
            f.seek(path_off)
            name = f.read(256).split(b"\0")[0].decode("latin1")
            images.append([load_addr, text_size, name])
        images.sort()

        maps = {}
        for name, m in self.members.items():
            if not name.startswith(CACHE_MAIN):
                continue
            hdr = self._read_member_head(name)
            if not hdr.startswith(b"dyld_v1"):
                continue
            mapping_offset, mapping_count = struct.unpack_from("<II", hdr, 16)
            f = self.t.extractfile(m)
            f.seek(mapping_offset)
            raw = f.read(32 * mapping_count)
            segs = []
            for i in range(mapping_count):
                addr, size, foff = struct.unpack_from("<QQQ", raw, 32 * i)
                segs.append([addr, size, foff])
            maps[name] = segs
        with open(self.index_path, "w") as fh:
            json.dump({"images": images, "maps": maps}, fh)
        return images, maps

    # -------------------------------------------------------------- resolving
    def image_for(self, va):
        addrs = [im[0] for im in self.images]
        i = bisect.bisect_right(addrs, va) - 1
        if i < 0:
            return None
        load, size, name = self.images[i]
        # Accept anything within 16 MB of __TEXT for __DATA/__LINKEDIT frames.
        if va - load < max(size, 0) + 0x1000000:
            return name, va - load
        return None

    def subcache_for(self, va):
        for name, segs in self.maps.items():
            for addr, size, _foff in segs:
                if addr <= va < addr + size:
                    return name, va - addr
        return None, None


def nearest_symbol(path, offset):
    """Nearest preceding nlist symbol in a thin Mach-O (best effort)."""
    try:
        data = open(path, "rb").read()
    except OSError:
        return None
    if data[:4] != b"\xcf\xfa\xed\xfe":
        return None
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    symtab = None
    text_base = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x19:
            name = data[off + 8:off + 24].rstrip(b"\0")
            vmaddr = struct.unpack_from("<Q", data, off + 24)[0]
            if name == b"__TEXT" and text_base is None:
                text_base = vmaddr
        elif cmd == 0x2:
            symtab = struct.unpack_from("<IIII", data, off + 8)
        off += size
    if not symtab or text_base is None:
        return None
    symoff, nsyms, stroff, _strsize = symtab
    best = None
    target = text_base + offset
    for i in range(nsyms):
        n_strx, n_type, _sect, _desc, n_value = struct.unpack_from("<IBBHQ", data, symoff + i * 16)
        if not n_value or n_value > target or (n_type & 0x0E) != 0x0E:
            continue
        if best is None or n_value > best[0]:
            end = data.index(b"\0", stroff + n_strx)
            best = (n_value, data[stroff + n_strx:end].decode("latin1"))
    if best and target - best[0] < 0x4000:
        return "%s+0x%x" % (best[1], target - best[0])
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("logs", nargs="+")
    ap.add_argument("--tar", default="research/dsc.tar")
    ap.add_argument("--dylibs", default="research/dsc-extract")
    ap.add_argument("--only", default=None, help="substring filter on process name")
    ns = ap.parse_args()
    cache = Cache(ns.tar)

    head_re = re.compile(r"^SMP (\S+?)\[(\d+)\] slide (0x[0-9a-f]+) mh (0x[0-9a-f]+)")
    thread_re = re.compile(r"^SMP (\S+) t(\d+) pc (0x[0-9a-f]+) lr (0x[0-9a-f]+) sp (0x[0-9a-f]+) bt(.*)$")

    for path in ns.logs:
        print("==== %s" % path)
        current = None
        slide = 0
        for line in open(path, "r", errors="replace"):
            line = line.rstrip("\n")
            m = head_re.match(line)
            if m:
                current, pid, slide_s, mh = m.group(1), m.group(2), m.group(3), m.group(4)
                slide = int(slide_s, 16)
                if ns.only and ns.only not in current:
                    current = None
                    continue
                print("-- %s[%s] slide %s mh %s" % (current, pid, slide_s, mh))
                continue
            m = thread_re.match(line)
            if not (m and current):
                continue
            if ns.only and ns.only not in m.group(1):
                continue
            frames = [m.group(3), m.group(4)] + m.group(6).split()
            out = []
            for fr in frames:
                if not re.fullmatch(r"0x[0-9a-fA-F]+", fr):
                    continue
                va = int(fr, 16) - slide
                hit = cache.image_for(va)
                if hit:
                    name, off = hit
                    short = os.path.basename(name)
                    sym = nearest_symbol(os.path.join(ns.dylibs, short),
                                         off) if os.path.exists(os.path.join(ns.dylibs, short)) else None
                    out.append("%s+0x%x%s" % (short, off, ("(%s)" % sym) if sym else ""))
                else:
                    out.append(fr)
            print("  t%s  %s" % (m.group(2), " <- ".join(out[:10])))


if __name__ == "__main__":
    main()
