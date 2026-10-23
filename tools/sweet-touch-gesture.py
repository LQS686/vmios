#!/usr/bin/env python3
"""Send a held tap or swipe to a sweet-touch control socket.

  sweet-touch-gesture.py SOCKET tap X Y
  sweet-touch-gesture.py SOCKET swipe X1 Y1 X2 Y2 [STEPS]

The guest's GT9896 driver polls every 10 ms; a tap shorter than that can be
lost between down and up. Taps are therefore held for 350 ms. Use this with
tools/sweet-touch-proxy.py (the proxy holds the one QEMU chardev connection).
"""
import socket
import struct
import sys
import time


def main():
    if len(sys.argv) < 5 or sys.argv[2] not in ('tap', 'swipe'):
        sys.exit(__doc__)
    path, action = sys.argv[1], sys.argv[2]
    nums = [int(v) for v in sys.argv[3:]]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(path)

    def send(kind, x, y):
        s.sendall(struct.pack('<BHH', kind, x, y))

    if action == 'tap':
        x, y = nums[0], nums[1]
        send(1, x, y)
        time.sleep(0.35)
        send(0, x, y)
        time.sleep(0.1)
    else:
        x1, y1, x2, y2 = nums[:4]
        steps = nums[4] if len(nums) > 4 else 12
        send(1, x1, y1)
        time.sleep(0.25)
        for i in range(1, steps + 1):
            x = x1 + (x2 - x1) * i // steps
            y = y1 + (y2 - y1) * i // steps
            send(2, x, y)
            time.sleep(0.05)
        send(0, x2, y2)
        time.sleep(0.1)
    s.close()
    print(f'{action} done')


if __name__ == '__main__':
    main()
