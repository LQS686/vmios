#!/usr/bin/env python3
"""Decode the SweetMetal dest=5 draw blocks from a phone-log-monitor transcript.

Prints, for each captured draw, the pipeline, index buffer, textures and the
first vertices decoded with CA's observed 48-byte layout:
  float4 position @0, float2 texcoord0 @16, float2 texcoord1 @24,
  half4 color @32.
"""
import re
import struct
import sys

TAG = re.compile(r'SWEETMETAL:\s+vb64_(\d)([0-9a-f]+)$')
DRAW = re.compile(r'SWEETMETAL: draw pid=(\d+) dest=(\d+) pipe=(\S+) '
                  r'prim=(\d+) count=(\d+) itype=(\d+) inst=(\d+) ib=(\S+)')
VB = re.compile(r'SWEETMETAL:\s+vb\[(\d)\]=(\S+) len=(\d+)')
TEX = re.compile(r'SWEETMETAL:\s+tex\[(\d)\]=surface (\d+)')
IMAX = re.compile(r'SWEETMETAL:\s+imax=(\d+)')
CHUNK = re.compile(r'SWEETMETAL:\s+chunk (\d+)')


def half(h):
    s = (h >> 15) & 1
    e = (h >> 10) & 0x1f
    m = h & 0x3ff
    if e == 0:
        v = m * 2.0 ** -24
    elif e == 31:
        v = 65504.0 if m else float('inf')
    else:
        v = (1.0 + m / 1024.0) * 2.0 ** (e - 15)
    return -v if s else v


def decode(vb_bytes, base_off, index):
    off = base_off + index * 48
    if off + 48 > len(vb_bytes):
        return None
    px, py, pz, pw = struct.unpack_from('<4f', vb_bytes, off)
    u0, v0 = struct.unpack_from('<2f', vb_bytes, off + 16)
    u1, v1 = struct.unpack_from('<2f', vb_bytes, off + 24)
    c = struct.unpack_from('<4H', vb_bytes, off + 32)
    return (px, py, pz, pw, u0, v0, u1, v1,
            tuple(half(x) for x in c))


def main(path):
    lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
    i = 0
    shown = 0
    while i < len(lines):
        m = DRAW.search(lines[i])
        if not m:
            i += 1
            continue
        dest = int(m.group(2))
        if dest != 5:
            i += 1
            continue
        block = lines[i:i + 220]
        vb_buf = {}
        vbs = {}
        texs = {}
        imax = 0
        hexbuf = {}
        cur_idx = None
        cont = re.compile(r'SWEETMETAL:\s+([0-9a-f]{32})$')
        for ln in block:
            mm = VB.search(ln)
            if mm:
                vbs[int(mm.group(1))] = (mm.group(2), int(mm.group(3)))
                cur_idx = None
                continue
            mm = TEX.search(ln)
            if mm:
                texs[int(mm.group(1))] = int(mm.group(2))
                cur_idx = None
                continue
            mm = IMAX.search(ln)
            if mm:
                imax = int(mm.group(1))
                cur_idx = None
                continue
            mm = TAG.search(ln)
            if mm:
                cur_idx = int(mm.group(1))
                hexbuf.setdefault(cur_idx, bytearray()).extend(
                    bytes.fromhex(mm.group(2).ljust(32, '0')[:32]))
                continue
            mm = cont.search(ln)
            if mm and cur_idx is not None:
                hexbuf[cur_idx].extend(bytes.fromhex(mm.group(1)))
                continue
            if not ln.startswith('SWEETMETAL:     '):
                cur_idx = None
        vb0 = hexbuf.get(1, b'')
        print('DRAW ib=%s count=%s imax=%d tex=%s vb1=%s' % (
            m.group(8), m.group(5), imax, texs, vbs.get(1, ('?', 0))[0]))
        if vb0:
            for k in range(min(imax + 1, 6)):
                d = decode(vb0, 0, k)
                if d:
                    print('  v%d pos=(%.1f,%.1f,%.1f,%.1f) uv0=(%.3f,%.3f) '
                          'uv1=(%.3f,%.3f) col=(%.3f,%.3f,%.3f,%.3f)' % (
                              (k, d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7])
                              + tuple(d[8])))
        shown += 1
        if shown >= 6:
            break
        # skip past this block
        j = i + 1
        while j < len(lines) and not DRAW.search(lines[j]) and \
                'SWEETMETAL: pass ' not in lines[j]:
            j += 1
        i = j


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else '.tools/gputest/phone-live.txt')
