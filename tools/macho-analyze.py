#!/usr/bin/env python3
"""Minimal Mach-O / dyld-cache-dylib inspector for the ios-sweet bring-up.

The project analyses iOS binaries on Windows/Linux, where Apple's nm/otool and
REA's macOS provider are unavailable. This reads a thin arm64 Mach-O (a dylib
extracted from the dyld shared cache, or the built kernel), exposes symbols,
exports and sections, and disassembles named functions with Capstone so that
retry loops / timeouts can be read straight out of the code.

Usage:
  python3 tools/macho-analyze.py info  BINARY
  python3 tools/macho-analyze.py sym   BINARY PATTERN [PATTERN...]
  python3 tools/macho-analyze.py dis   BINARY SYMBOL_OR_ADDR [--n BYTES] [--json]
  python3 tools/macho-analyze.py xref  BINARY SYMBOL_OR_ADDR     # bl/b targets to it
  python3 tools/macho-analyze.py callers BINARY SYMBOL_OR_ADDR   # functions containing bl to it
"""
import argparse
import bisect
import json
import struct
import sys

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xb
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_FUNCTION_STARTS = 0x26
LC_DYLD_EXPORTS_TRIE = 0x80000033


class MachO:
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            self.data = f.read()
        magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack_from(
            "<IiiIIIII", self.data, 0)
        if magic != 0xFEEDFACF:
            raise SystemExit("not a thin 64-bit little-endian Mach-O (magic 0x%x)" % magic)
        self.cputype = cputype
        self.filetype = filetype
        self.ncmds = ncmds
        self.segments = []          # (name, vmaddr, vmsize, fileoff, filesize, maxprot, initprot)
        self.sections = []          # (segname, sectname, addr, size, offset)
        self.symbols = []           # (name, n_value, n_type, n_sect)
        self.exports = {}           # name -> vmaddr
        self.function_starts = []   # vmaddrs
        self._parse_load_commands(sizeofcmds)

    # ---------------------------------------------------------------- parsing
    def _parse_load_commands(self, sizeofcmds):
        off = 32
        symtab = None
        for _ in range(self.ncmds):
            cmd, cmdsize = struct.unpack_from("<II", self.data, off)
            if cmd == LC_SEGMENT_64:
                segname = self.data[off + 8:off + 24].rstrip(b"\0").decode("latin1")
                vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, _flags = \
                    struct.unpack_from("<QQQQiiII", self.data, off + 24)
                self.segments.append((segname, vmaddr, vmsize, fileoff, filesize, maxprot, initprot))
                soff = off + 72
                for _s in range(nsects):
                    sectname = self.data[soff:soff + 16].rstrip(b"\0").decode("latin1")
                    segn = self.data[soff + 16:soff + 32].rstrip(b"\0").decode("latin1")
                    addr, size, offset = struct.unpack_from("<QQI", self.data, soff + 32)
                    self.sections.append((segn, sectname, addr, size, offset))
                    soff += 80
            elif cmd == LC_SYMTAB:
                symtab = struct.unpack_from("<IIII", self.data, off + 8)
            elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
                export_off, export_size = struct.unpack_from("<II", self.data, off + 40)
                if export_size:
                    self._parse_exports(export_off, export_size)
            elif cmd == LC_DYLD_EXPORTS_TRIE:
                dataoff, datasize = struct.unpack_from("<II", self.data, off + 8)
                self._parse_exports(dataoff, datasize)
            elif cmd == LC_FUNCTION_STARTS:
                dataoff, datasize = struct.unpack_from("<II", self.data, off + 8)
                self._parse_function_starts(dataoff, datasize)
            off += cmdsize

        if symtab:
            symoff, nsyms, stroff, strsize = symtab
            for i in range(nsyms):
                n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from(
                    "<IBBHQ", self.data, symoff + i * 16)
                end = self.data.index(b"\0", stroff + n_strx)
                name = self.data[stroff + n_strx:end].decode("latin1")
                self.symbols.append((name, n_value, n_type, n_sect))

    def _parse_exports(self, off, size):
        blob = self.data[off:off + size]

        def walk(node_off, prefix, depth=0):
            if depth > 32 or node_off >= len(blob):
                return
            terminal_size, = struct.unpack_from("B", blob, node_off)
            p = node_off + 1
            if terminal_size:
                flags, = struct.unpack_from("<Q", blob, p)
                if flags & 0x8:  # re-export
                    pass
                else:
                    addr, = struct.unpack_from("<Q", blob, p + 8)
                    self.exports[prefix] = addr
                p += terminal_size
            if p < len(blob):
                nchildren, = struct.unpack_from("B", blob, p)
                p += 1
                for _ in range(nchildren):
                    end = blob.index(b"\0", p)
                    edge = blob[p:end].decode("latin1")
                    child, = struct.unpack_from("<Q", blob, end + 1)
                    walk(child, prefix + edge, depth + 1)
                    p = end + 1 + 8

        walk(0, "")

    def _parse_function_starts(self, off, size):
        data = self.data[off:off + size]
        # ULEB128 deltas from the __TEXT base address
        base = self.segments[0][1] if self.segments else 0
        addr = base
        i = 0
        while i < len(data):
            delta = 0
            shift = 0
            while True:
                b = data[i]
                i += 1
                delta |= (b & 0x7F) << shift
                shift += 7
                if not b & 0x80:
                    break
            if delta == 0:
                break
            addr += delta
            self.function_starts.append(addr)

    # ------------------------------------------------------------- addresses
    def va_to_off(self, va):
        for name, vmaddr, vmsize, fileoff, filesize, _mp, _ip in self.segments:
            if filesize and vmaddr <= va < vmaddr + filesize:
                return fileoff + (va - vmaddr)
        return None

    def off_to_va(self, off):
        for name, vmaddr, vmsize, fileoff, filesize, _mp, _ip in self.segments:
            if filesize and fileoff <= off < fileoff + filesize:
                return vmaddr + (off - fileoff)
        return None

    def resolve(self, token):
        """Symbol name, hex address, or 0x-prefixed address -> VA."""
        if token.lower().startswith("0x"):
            return int(token, 16)
        hits = [s for s in self.symbols if s[0] == token]
        if hits and hits[0][1]:
            return hits[0][1]
        hits = [s for s in self.symbols if s[0].lstrip("_") == token.lstrip("_") and s[1]]
        if hits:
            return hits[0][1]
        base = self.segments[0][1] if self.segments else 0
        for k, v in self.exports.items():
            if k == token or k.lstrip("_") == token.lstrip("_"):
                return base + v
        fuzzy = [s for s in self.symbols if token in s[0] and s[1]]
        if fuzzy:
            return fuzzy[0][1]
        raise SystemExit("symbol not found: %s" % token)


def disassemble(m, va, nbytes, base_va=None):
    from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
    off = m.va_to_off(va)
    if off is None:
        raise SystemExit("address 0x%x is not file-backed" % va)
    code = m.data[off:off + nbytes]
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    md.detail = True
    out = []
    for ins in md.disasm(code, va):
        out.append((ins.address, ins.mnemonic, ins.op_str, ins.bytes.hex()))
    return out


def function_end(m, va):
    starts = sorted(m.function_starts)
    i = bisect.bisect_left(starts, va)
    if i < len(starts) and starts[i] == va and i + 1 < len(starts):
        return starts[i + 1]
    return va + 0x400


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["info", "sym", "dis", "xref", "callers"])
    ap.add_argument("binary")
    ap.add_argument("args", nargs="*")
    ap.add_argument("--n", type=int, default=0, help="bytes to disassemble")
    ap.add_argument("--json", action="store_true")
    ns = ap.parse_args()
    m = MachO(ns.binary)

    if ns.cmd == "info":
        print("file            %s" % ns.binary)
        print("cputype         0x%x  filetype %d" % (m.cputype, m.filetype))
        print("segments:")
        for s in m.segments:
            print("  %-16s vm 0x%012x size 0x%09x fileoff 0x%08x filesize 0x%09x prot %d/%d"
                  % (s[0], s[1], s[2], s[3], s[4], s[5], s[6]))
        print("symbols         %d (%d with addresses)" % (len(m.symbols), sum(1 for s in m.symbols if s[1])))
        print("exports         %d" % len(m.exports))
        print("function starts %d" % len(m.function_starts))
        return

    if ns.cmd == "sym":
        pats = ns.args
        for name, value, ntype, nsect in m.symbols:
            if value and any(p.lower() in name.lower() for p in pats):
                print("0x%012x  %s" % (value, name))
        for name, value in m.exports.items():
            base = m.segments[0][1]
            if any(p.lower() in name.lower() for p in pats):
                print("0x%012x  (export) %s" % (base + value, name))
        return

    if ns.cmd == "dis":
        va = m.resolve(ns.args[0])
        n = ns.n or max(0x40, function_end(m, va) - va)
        ins = disassemble(m, va, n)
        if ns.json:
            print(json.dumps(ins))
        else:
            for a, mn, ops, _b in ins:
                mark = "  ; <-- target" if ops and ns.args[1:] and any(
                    x.lower() in ops.lower() for x in ns.args[1:]) else ""
                print("0x%012x  %-9s %s%s" % (a, mn, ops, mark))
        return

    if ns.cmd in ("xref", "callers"):
        target = m.resolve(ns.args[0])
        hits = []
        for seg, sect, addr, size, offset in m.sections:
            if not sect.startswith("__text"):
                continue
            code = m.data[offset:offset + size]
            # AArch64: bl imm26 = 0x94000000 | imm, b imm26 = 0x14000000 | imm
            for i in range(0, len(code) - 4, 4):
                ins, = struct.unpack_from("<I", code, i)
                if (ins & 0xFC000000) not in (0x94000000, 0x14000000):
                    continue
                imm = ins & 0x03FFFFFF
                if imm & 0x02000000:
                    imm -= 0x04000000
                site = addr + i
                if site + imm * 4 == target:
                    hits.append(site)
        starts = sorted(m.function_starts)

        def owner(site):
            j = bisect.bisect_right(starts, site) - 1
            return starts[j] if j >= 0 else 0

        for site in hits:
            print("0x%012x  in 0x%012x" % (site, owner(site)) if ns.cmd == "callers"
                  else "0x%012x" % site)
        return


if __name__ == "__main__":
    main()
