#!/usr/bin/env python3
"""Find ARM64 ADRP/ADD/LDR references to selected strings in a Mach-O dylib.

  find-strrefs.py BINARY NEEDLE [NEEDLE ...]

Fast linear scan (capstone); no full analysis. Reports both direct
adrp+add materialization and adrp+ldr through a pointer table.
"""
import struct
import sys

import capstone

LC_SEGMENT_64 = 0x19


def segments(buf):
    magic, = struct.unpack_from('<I', buf, 0)
    assert magic == 0xfeedfacf, 'not a 64-bit Mach-O'
    ncmds, = struct.unpack_from('<I', buf, 16)
    off = 32
    out = []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', buf, off)
        if cmd == LC_SEGMENT_64:
            name = buf[off + 8:off + 24].split(b'\0')[0].decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<4Q', buf, off + 24)
            initprot, = struct.unpack_from('<i', buf, off + 24 + 32 + 8)
            out.append(dict(name=name, vmaddr=vmaddr, vmsize=vmsize,
                            fileoff=fileoff, filesize=filesize, prot=initprot))
        off += size
    return out


def strings_in(buf, segs, needles):
    found = {}
    for s in segs:
        if s['name'] != '__TEXT':
            continue
        data = buf[s['fileoff']:s['fileoff'] + s['filesize']]
        i = 0
        while i < len(data):
            j = data.find(b'\0', i)
            if j < 0:
                break
            chunk = data[i:j]
            if len(chunk) >= 4:
                try:
                    text = chunk.decode('utf-8')
                except UnicodeDecodeError:
                    text = ''
                if text and any(nd in text for nd in needles):
                    found[s['vmaddr'] + i] = text
            i = j + 1
    return found


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    buf = open(argv[0], 'rb').read()
    needles = argv[1:]
    segs = segments(buf)
    by_va = strings_in(buf, segs, needles)
    if not by_va:
        sys.exit('no matching strings')
    for va, text in sorted(by_va.items()):
        print('STRING 0x%x %s' % (va, text))

    def read_ptr(va):
        for s in segs:
            if s['vmaddr'] <= va < s['vmaddr'] + s['vmsize']:
                off = s['fileoff'] + (va - s['vmaddr'])
                if off + 8 <= len(buf):
                    return struct.unpack_from('<Q', buf, off)[0]
        return None

    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
    md.skipdata = True
    refs = 0
    for s in segs:
        if not (s['prot'] & 4) or s['name'] != '__TEXT':
            continue
        code = buf[s['fileoff']:s['fileoff'] + s['filesize']]
        pages = {}
        regs = {}
        for insn in md.disasm(code, s['vmaddr']):
            m = insn.mnemonic
            ops = [p.strip() for p in insn.op_str.split(',')]
            if m == 'adrp':
                try:
                    pages[ops[0]] = int(insn.op_str.split('#')[-1], 0)
                    regs.pop(ops[0], None)
                except (ValueError, IndexError):
                    pass
            elif m == 'add' and len(ops) == 3 and ops[2].startswith('#'):
                base = regs.get(ops[1], pages.get(ops[1]))
                if base is None:
                    continue
                try:
                    target = base + int(ops[2][1:], 0)
                except ValueError:
                    continue
                regs[ops[0]] = target
                if target in by_va:
                    refs += 1
                    print('REF 0x%x -> 0x%x %s  (add %s)' % (
                        insn.address, target, by_va[target], insn.op_str))
            elif m in ('ldr', 'ldrb', 'ldrh', 'ldrsw') and \
                    len(ops) >= 2 and ops[1].startswith('['):
                base_reg = ops[1][1:]
                base = regs.get(base_reg, pages.get(base_reg))
                if base is None:
                    continue
                off = 0
                if len(ops) >= 3 and ops[2].startswith('#'):
                    try:
                        off = int(ops[2].rstrip(']')[1:], 0)
                    except ValueError:
                        off = 0
                ptr = read_ptr(base + off)
                if ptr is not None and ptr in by_va:
                    refs += 1
                    print('REF 0x%x -> ptr@0x%x -> 0x%x %s  (%s %s)' % (
                        insn.address, base + off, ptr, by_va[ptr], m, insn.op_str))
    print('refs=%d strings=%d' % (refs, len(by_va)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
