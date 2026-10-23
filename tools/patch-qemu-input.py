#!/usr/bin/env python3
"""Make the SWEET kernel's touch power vote succeed without a PMIC.

  patch-qemu-input.py KERNEL [OUT]

bsd/dev/sweet_touch.c votes the L11C rail through sweet_rpmh_vreg_enable()
and skips the probe if that returns an error. QEMU has no RPMh RSC/TCS
dictionary, so replace the function with `mov w0, #0; ret`. The synthetic
soft-touch hardware is powered by definition.

This is a bring-up patch for the QEMU/Android VM path, not for the phone.
Run it on a kernel (or use the result with mkpayload.py) together with
tools/patch-qemu-psci.py.
"""
import struct
import sys

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
RET_ZERO = bytes.fromhex("00008052c0035fd6")	# mov w0, #0 ; ret


def find_symbol(data, name):
    magic, cpu, sub, ftype, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<8I", data, 0)
    assert magic == 0xfeedfacf, "not a 64-bit Mach-O"
    off = 32
    segs = []
    symtab = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == LC_SEGMENT_64:
            vmaddr, vmsize, foff, fsize = struct.unpack_from("<4Q", data, off + 24)
            segs.append((vmaddr, vmsize, foff, fsize))
        elif cmd == LC_SYMTAB:
            symtab = struct.unpack_from("<4I", data, off + 8)
        off += size
    if symtab is None:
        raise SystemExit("no LC_SYMTAB")
    symoff, nsyms, stroff, strsize = symtab
    for i in range(nsyms):
        strx, ntype, nsect, ndesc, value = struct.unpack_from("<IBBHQ", data, symoff + 16 * i)
        end = data.find(b"\0", stroff + strx)
        if data[stroff + strx:end].decode("utf-8", "replace") == name:
            for vmaddr, vmsize, foff, fsize in segs:
                if vmaddr <= value < vmaddr + vmsize:
                    return foff + (value - vmaddr)
    return None


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__.strip())
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else src + ".input"
    data = bytearray(open(src, "rb").read())
    off = find_symbol(data, "_sweet_rpmh_vreg_enable")
    if off is None:
        raise SystemExit("no _sweet_rpmh_vreg_enable symbol")
    if data[off:off + len(RET_ZERO)] == RET_ZERO:
        print(f"{src}: already patched at 0x{off:x}")
    else:
        data[off:off + len(RET_ZERO)] = RET_ZERO
        open(dst, "wb").write(data)
        print(f"{src} -> {dst}: _sweet_rpmh_vreg_enable at 0x{off:x} -> return 0")


if __name__ == "__main__":
    main()
