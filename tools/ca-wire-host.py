#!/usr/bin/env python3
"""Minimal GPU-wire host for reproducing the CA surface write path in QEMU.

  tools/ca-wire-host.py --ram OUT/guest-ram.bin [--port 5141] [--write]

It parses the same messages as GpuWireServer/CaCompositor:
  op 3 fill, op 4 CA draw / texture chunk, op 5 surface page map, op 6 flush.
Without --write it only logs; with --write it paints every destination
surface with one colour through the page map, which is the operation that
caused the phone kernel panic. Keeping this out of Android makes the guest
RAM layout and the map directly inspectable.
"""
import argparse
import mmap
import os
import socket
import struct
import sys
import time

MAGIC = 0x5550474E
RAM_BASE = 0x40000000
HEADER = struct.Struct('<IHHII')          # magic, version, op, bytes, request
FILL = struct.Struct('<QIIIIII')          # pa, w, h, stride, color, x, y
MAP = struct.Struct('<IIIIIIIIII')        # surface..reserved
CA = struct.Struct('<IIIIIIIIIIIIIIIIIIIIII')  # 22 u32 = 88 bytes
PIXEL = 0xFF204060


class Host:
    def __init__(self, ram_path, write):
        self.write = write
        self.f = open(ram_path, 'r+b')
        size = os.fstat(self.f.fileno()).st_size
        self.mm = mmap.mmap(self.f.fileno(), 0, access=mmap.ACCESS_WRITE)
        self.ram_end = RAM_BASE + size
        self.maps = {}
        self.draws = 0
        self.maps_done = 0
        self.writes = 0
        self.dropped = 0

    def contains(self, pa):
        return RAM_BASE <= pa < self.ram_end

    def write_surface(self, sid, w, h, bpr):
        pages = self.maps.get(sid)
        if not pages:
            self.dropped += 1
            return
        total, shift, entries = pages
        if shift != 14 or bpr < w * 4:
            self.dropped += 1
            return
        size = shift and (1 << shift)
        row = struct.pack('<I', PIXEL) * w
        for y in range(h):
            off = y * bpr
            page = off >> shift
            within = off & (size - 1)
            if page >= total:
                break
            take = min(w * 4, size - within)
            pa = entries[page]
            if not pa:
                break
            self.mm[pa - RAM_BASE + within:pa - RAM_BASE + within + take] = row[:take]
            done = take // 4
            while done < w:
                page += 1
                if page >= total or not entries[page]:
                    break
                take = min((w - done) * 4, size)
                pa = entries[page]
                self.mm[pa - RAM_BASE:pa - RAM_BASE + take] = row[done * 4:done * 4 + take]
                done += take // 4
        self.writes += 1
        if self.writes <= 8:
            print('write sid=%d %dx%d bpr=%d pages=%d' % (sid, w, h, bpr, total), flush=True)

    def feed(self, payload):
        op = payload[0]
        body = payload[1]
        if op == 3:
            pa, w, h, stride, color, x, y = FILL.unpack_from(body, 0)
            if self.write and self.contains(pa) and w > 0 and h > 0 \
                    and stride >= w * 4 and pa - RAM_BASE + (h - 1) * stride + w * 4 <= len(self.mm):
                row = struct.pack('<I', color | 0xFF000000) * w
                for yy in range(h):
                    at = pa - RAM_BASE + (y + yy) * stride + x * 4
                    self.mm[at:at + w * 4] = row
            return
        if op == 5:
            sid, index, count, total, alo, ahi, flo, fhi, shift, _ = MAP.unpack_from(body, 0)
            entries = body[MAP.size:MAP.size + count * 8]
            pages = self.maps.get(sid)
            if pages is None or pages[0] != total or index == 0:
                pages = [total, shift, [0] * total]
                self.maps[sid] = pages
            for i in range(count):
                pa = struct.unpack_from('<Q', entries, i * 8)[0]
                if pa and (not self.contains(pa) or pa & 0x3FFF):
                    print('bad map sid=%d i=%d pa=0x%x' % (sid, index + i, pa), flush=True)
                    continue
                pages[2][index + i] = pa
            self.maps_done += 1
            if self.maps_done <= 6:
                print('map sid=%d total=%d shift=%d first=0x%x alloc=%d' % (
                    sid, total, shift, pages[2][0], alo), flush=True)
            return
        if op != 4 or len(body) < CA.size:
            return
        f = CA.unpack_from(body, 0)
        flags, dst, dw, dh, bpr, tex, tw, th, tbpr, tf = f[:10]
        tris = f[15]
        if flags & 8:
            return
        self.draws += 1
        if self.draws <= 12:
            print('draw flags=0x%x dst=%d %dx%d bpr=%d tris=%d len=%d' % (
                flags, dst, dw, dh, bpr, tris, len(body)), flush=True)
        if self.write and dst and dw and dh and bpr:
            self.write_surface(dst, dw, dh, bpr)


def serve(port, host):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', port))
    srv.listen(1)
    print('listening on %d' % port, flush=True)
    while True:
        conn, addr = srv.accept()
        print('client', addr, flush=True)
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        buf = b''
        try:
            while True:
                while len(buf) < HEADER.size:
                    chunk = conn.recv(1 << 16)
                    if not chunk:
                        raise EOFError
                    buf += chunk
                magic, version, op, nbytes, request = HEADER.unpack_from(buf, 0)
                if magic != MAGIC or nbytes > 4096:
                    print('bad header magic=0x%x op=%d bytes=%d' % (magic, op, nbytes), flush=True)
                    raise ValueError
                while len(buf) < HEADER.size + nbytes:
                    chunk = conn.recv(1 << 16)
                    if not chunk:
                        raise EOFError
                    buf += chunk
                body = buf[HEADER.size:HEADER.size + nbytes]
                buf = buf[HEADER.size + nbytes:]
                host.feed((op, body))
                if op == 6:
                    conn.sendall(struct.pack('<II', MAGIC, request))
        except (EOFError, ValueError, OSError) as e:
            print('client gone:', e, flush=True)
        finally:
            conn.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ram', required=True)
    ap.add_argument('--port', type=int, default=5141)
    ap.add_argument('--write', action='store_true')
    a = ap.parse_args()
    host = Host(a.ram, a.write)
    try:
        serve(a.port, host)
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
