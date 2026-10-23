#!/usr/bin/env python3
"""Make SWEET XNU's host_set_multiuser_config_flags() report success.

The macOS-config kernel is built without CONFIG_MULTIUSER, so the Mach host
call is a stub (`mov w0, #46; ret`, KERN_NOT_SUPPORTED). iOS usermanagerd
treats that as fatal: it logs "FAILED to Set Foreground ID + multiuser in
commpage", never publishes the foreground user identity, and then
containermanagerd's MCMUserIdentityCache loops in _lock_resync while
LaunchServices waits for its user container. Boot then stalls before Setup
or SpringBoard can create a scene.

  patch-kernel-multiuser.py KERNEL [--out OUT] [--revert] [--check]

This rewrites only the function's return value for QEMU bring-up. It does
NOT program the commpage fields, so it is a workaround, not a correct
CONFIG_MULTIUSER implementation. The real fix belongs in the XNU source:
call commpage_update_multiuser_config(flags) and return KERN_SUCCESS.
"""
import argparse
import struct
import sys

LC_SEGMENT_64, LC_SYMTAB = 0x19, 0x2
STUB = bytes.fromhex('c0058052c0035fd6')        # mov w0, #46; ret
PATCH = bytes.fromhex('00008052c0035fd6')       # mov w0, #0; ret
SYMBOL = '_host_set_multiuser_config_flags'


def parse_macho(buf):
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from('<8I', buf, 0)
    if magic != 0xfeedfacf:
        sys.exit('not a 64-bit Mach-O kernel')
    segs, symtab = [], None
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', buf, off)
        if cmd == LC_SEGMENT_64:
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<4Q', buf, off + 24)
            segs.append((vmaddr, vmsize, fileoff, filesize))
        elif cmd == LC_SYMTAB:
            symtab = struct.unpack_from('<IIII', buf, off + 8)
        off += size
    return segs, symtab


def find_symbol(buf, segs, symtab, name):
    symoff, nsyms, stroff, _ = symtab
    for i in range(nsyms):
        n_strx, n_type, _, _, n_value = struct.unpack_from('<IBBHQ', buf, symoff + 16 * i)
        end = buf.index(b'\0', stroff + n_strx)
        if buf[stroff + n_strx:end].decode('ascii', 'replace') == name and n_type & 0x0e:
            for vmaddr, vmsize, fileoff, filesize in segs:
                if vmaddr <= n_value < vmaddr + filesize:
                    return n_value, fileoff + n_value - vmaddr
            return n_value, None
    sys.exit(f'{name} not found in symbol table')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('kernel')
    ap.add_argument('--out', help='write patched kernel here (default: in place)')
    ap.add_argument('--revert', action='store_true', help='restore the KERN_NOT_SUPPORTED stub')
    ap.add_argument('--check', action='store_true', help='only report the current bytes')
    a = ap.parse_args()

    buf = bytearray(open(a.kernel, 'rb').read())
    segs, symtab = parse_macho(buf)
    if not symtab:
        sys.exit('kernel has no LC_SYMTAB; use the unstripped development kernel')
    va, off = find_symbol(buf, segs, symtab, SYMBOL)
    if off is None:
        sys.exit(f'{SYMBOL} at {va:#x} is not backed by a segment')
    cur = bytes(buf[off:off + 8])
    want, new = (STUB, PATCH) if not a.revert else (PATCH, STUB)
    action = 'already patched' if cur == new else ('stub' if cur == STUB else f'unexpected {cur.hex()}')
    print(f'{SYMBOL} VA {va:#x} file {off:#x}: {cur.hex()} ({action})')
    if a.check:
        return 0 if cur in (STUB, PATCH) else 1
    if cur == new:
        return 0
    if cur != want:
        sys.exit('refusing to patch: bytes do not match the expected stub')
    buf[off:off + 8] = new
    open(a.out or a.kernel, 'wb').write(buf)
    print(f'patched -> {(a.out or a.kernel)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
