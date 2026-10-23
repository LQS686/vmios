#!/usr/bin/env python3
"""Switch the SWEET kernel's one PSCI call from SMC to HVC for QEMU.

  patch-qemu-psci.py KERNEL_OR_PAYLOAD [OUT]

The phone's PSCI conduit is SMC. QEMU's virt machine implements PSCI through
HVC by default (it only offers SMC when the guest starts at EL2); the SWEET
kernel boots at EL1. The kernel has exactly one `smc #0` instruction, inside
SweetCPU::startCPU(), immediately after the PSCI CPU_ON function id
(0xC4000003) is loaded. Replace that instruction with `hvc #0`.

The patch is a four-byte change; it works on a Mach-O kernel or on a
SWEETXNU payload (the kernel segment is copied verbatim into the payload).
It refuses if the SMC is missing or its PSCI context is not found.
"""
import sys

SMC = b'\x03\x00\x00\xd4'		# smc #0
HVC = b'\x02\x00\x00\xd4'		# hvc #0
MOV_W0_3 = b'\x60\x00\x80\x52'		# mov w0, #3
MOVK_W0_C400 = b'\x00\x80\xb8\x72'	# movk w0, #0xc400, lsl #16


def find_psci_smc(data):
    hits = []
    pos = data.find(SMC)
    while pos >= 0:
        window = data[max(0, pos - 32):pos]
        if MOV_W0_3 in window and MOVK_W0_C400 in window:
            hits.append(pos)
        pos = data.find(SMC, pos + 4)
    return hits


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__.strip())
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else src + '.qemu'
    data = bytearray(open(src, 'rb').read())
    hits = find_psci_smc(data)
    if len(hits) != 1:
        raise SystemExit(f'expected one PSCI smc #0, found {len(hits)} in {src}')
    off = hits[0]
    data[off:off + 4] = HVC
    open(dst, 'wb').write(data)
    print(f'{src} -> {dst}: PSCI smc #0 at 0x{off:x} replaced with hvc #0')


if __name__ == '__main__':
    main()
