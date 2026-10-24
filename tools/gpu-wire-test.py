#!/usr/bin/env python3
"""Round-trip one GPU_WIRE_CLEAR through the Android host GPU server.

Usage: gpu-wire-test.py [PORT]     (default 55141 = adb forward to device 5141)

This tests GpuWireServer's EGL/GLES path only, not the guest transport; on the
phone run `adb forward tcp:55141 tcp:5141` first.
"""
import socket
import struct
import sys

MAGIC = 0x5550474E
VERSION = 1
OP_CLEAR = 1
RESPONSE = 0x8000
WIDTH = HEIGHT = 64
PIXEL_BYTES = WIDTH * HEIGHT * 4
REPLY_BYTES = 16 + 32 + PIXEL_BYTES


def main(argv):
    port = int(argv[1]) if len(argv) > 1 else 55141
    request = 0x5EED0001
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    sock.sendall(struct.pack("<IHHII", MAGIC, VERSION, OP_CLEAR, 0, request))
    reply = bytearray()
    while len(reply) < REPLY_BYTES:
        chunk = sock.recv(REPLY_BYTES - len(reply))
        if not chunk:
            break
        reply += chunk
    if len(reply) != REPLY_BYTES:
        print(f"FAIL short reply {len(reply)}/{REPLY_BYTES}")
        return 1
    magic, version, operation, size, echoed = struct.unpack_from("<IHHII", reply, 0)
    width, height, fmt, status, gpu_start, gpu_end = struct.unpack_from("<IIIIQQ", reply, 16)
    pixel0 = struct.unpack_from("<I", reply, 48)[0]
    print(f"magic=0x{magic:08x} version={version} op=0x{operation:04x} size={size} "
          f"request=0x{echoed:08x}")
    print(f"{width}x{height} format={fmt} status={status} "
          f"gpu_ns={gpu_end - gpu_start} pixel0=0x{pixel0:08x}")
    ok = (magic == MAGIC and version == VERSION
          and operation == (OP_CLEAR | RESPONSE)
          and echoed == request and width == WIDTH and height == HEIGHT
          and pixel0 == 0x3F800000)
    print("OK" if ok else "FAIL unexpected reply")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
