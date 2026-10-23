#!/usr/bin/env python3
"""Keep one connection to a QEMU sweet-touch chardev and fan out 5-byte packets.

The QEMU socket chardev used by sweet-touch accepts one client; after that
client disconnects, later connections are not delivered to the device. The
Android app keeps its socket open, so it is unaffected. For host-driven UI
tests, this proxy holds the chardev connection and listens on a local Unix
socket that any number of short-lived gesture scripts can connect to.

  sweet-touch-proxy.py QEMU_SOCKET CONTROL_SOCKET
"""
import os
import socket
import sys
import time


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    qemu_path, ctl_path = sys.argv[1], sys.argv[2]
    qemu = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    while True:
        try:
            qemu.connect(qemu_path)
            break
        except (FileNotFoundError, ConnectionRefusedError):
            time.sleep(0.5)
    if os.path.exists(ctl_path):
        os.unlink(ctl_path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(ctl_path)
    srv.listen(4)
    print(f"proxy: {qemu_path} -> {ctl_path}", flush=True)
    while True:
        conn, _ = srv.accept()
        with conn:
            while True:
                data = conn.recv(4096)
                if not data:
                    break
                qemu.sendall(data)


if __name__ == "__main__":
    main()
