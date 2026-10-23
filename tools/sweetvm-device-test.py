#!/usr/bin/env python3
"""Install and exercise SweetVM on a connected phone, then report the numbers
that matter for the stutter fix.

  python3 tools/sweetvm-device-test.py            # install, boot, measure
  python3 tools/sweetvm-device-test.py --no-install --read-secs 600

What it checks, in order:

  1. `adb devices` has exactly one device.
  2. The APK installs (a signature change needs uninstall first; --reinstall
     does that, which also clears the app's 16 GB image + payload).
  3. `files/ios16-root.img` and `files/payload.bin` are readable through
     run-as. They are NOT pushed by this script (16 GB over USB is a decision,
     not a default); see android/README.md for the push recipe.
  4. The activity starts and logcat shows `engine cpus=N accel=... prealloc=...
     capture=Nfps` - the line that proves MTTCG and the 30 fps default.
  5. While booting it samples `fps=` lines from the app and takes a screenshot
     every --shot-secs; after --read-secs it optionally runs a tap and a swipe.

Exit codes: 0 all checks passed, 1 no device, 2 install failed,
3 payload/image missing, 4 the engine never logged its config.
"""
import argparse, os, re, shutil, subprocess, sys, time


def find_adb(explicit):
    if explicit:
        return explicit
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    local = os.path.join(here, 'android-sdk', 'platform-tools',
                         'adb.exe' if os.name == 'nt' else 'adb')
    if os.path.isfile(local):
        return local
    return shutil.which('adb')


def run(cmd, timeout=120):
    return subprocess.run(cmd, text=True, capture_output=True, timeout=timeout)


RING = 4 << 20
HEADER_BLOCK = 4096


def decode_ring(blob, max_bytes=262144):
    """Decode a 4 KiB SWEETLOG header + ring blob into its last max_bytes.

    Returns None when the magic is missing. Handles a ring that has wrapped
    and a requested tail shorter than the ring (which can still wrap).
    """
    if len(blob) < HEADER_BLOCK + 24 or blob[:8] != b'SWEETLOG':
        return None
    ring = int.from_bytes(blob[12:16], 'little') or RING
    total = int.from_bytes(blob[16:24], 'little')
    ring = min(ring, RING)
    if len(blob) < HEADER_BLOCK + ring:
        ring = len(blob) - HEADER_BLOCK
    n = min(total, ring, max_bytes)
    if n <= 0:
        return b''
    pos = int((total - n) % ring)
    data = blob[HEADER_BLOCK:HEADER_BLOCK + ring]
    if pos + n <= ring:
        return data[pos:pos + n]
    return data[pos:] + data[:n - (ring - pos)]


def fetch_ring(adb, pkg):
    """Return the 4 KiB SWEETLOG header + ring from the device, or None."""
    r = run([adb, 'shell', 'run-as', pkg, 'stat', '-c', '%s', 'files/ios16-root.img'])
    size = r.stdout.strip()
    if not size.isdigit():
        r = run([adb, 'shell', 'run-as', pkg, 'ls', '-l', 'files/ios16-root.img'])
        parts = r.stdout.split()
        size = parts[4] if len(parts) > 4 else ''
    if not size.isdigit():
        return None
    base = int(size) - RING - HEADER_BLOCK
    if base < 0:
        return None
    skip = (base + HEADER_BLOCK - 1) // HEADER_BLOCK
    r = subprocess.run([adb, 'exec-out', 'run-as', pkg, 'dd',
                        'if=files/ios16-root.img', 'bs=4096', 'skip=%d' % skip,
                        'count=1025'], capture_output=True, timeout=180)
    return r.stdout


def pull_guest_log(adb, pkg, outdir):
    """Pull the last 4 MiB + 4 KiB of the image and decode the SWEETLOG ring.

    QEMU runs without a console chardev, so the guest console (including a
    panic) only exists in that ring; reading it off the phone is the only way
    to see why a boot died. Uses toybox dd inside run-as, 4 KiB at a time.
    """
    blob = fetch_ring(adb, pkg)
    out = decode_ring(blob) if blob else None
    if out is None:
        print('[!] no SWEETLOG header in the pulled tail', file=sys.stderr)
        return
    path = os.path.join(outdir, 'guestlog.txt')
    with open(path, 'wb') as f:
        f.write(out)
    print('[*] guest console ->', path, '(%d bytes of %d)' % (len(out), total))


def native_app_check(adb, pkg, outdir, wait=120):
    """Watch the guest console while the user opens Settings/Photos.

    Native apps can only launch after MobileInstallation registers them; the
    kernel logs `exec <binary>` for whatever actually starts, so the ring is
    the ground truth (the screen alone cannot tell "tap ignored" from "app
    started and rendered the same home screen").
    """
    def shot(name):
        r = subprocess.run([adb, 'exec-out', 'screencap', '-p'],
                           capture_output=True, timeout=60)
        with open(os.path.join(outdir, name), 'wb') as f:
            f.write(r.stdout)

    print('[*] opening the home screen; then tap Settings (or Photos) on the phone')
    print('[*] watching the guest console for %d s ...' % wait)
    t0 = time.time()
    seen = None
    while time.time() - t0 < wait:
        blob = fetch_ring(adb, pkg)
        text = (decode_ring(blob) or b'').decode('utf-8', 'replace')
        for prog in ('Preferences', 'MobileSlideShow', 'MobileSafari', 'AppStore'):
            if ('exec ' + prog) in text:
                seen = prog
                break
        if seen:
            break
        time.sleep(10)
    shot('native-app-after.png')
    if seen:
        print('[*] app launched:', seen, '(exec seen in the guest console)')
        return 0
    print('[!] no app exec within %d s; registration is still missing ' % wait
          + '(see docs/PERF_FIXES.md 8)', file=sys.stderr)
    return 5


def self_test():
    """Synthetic rings: no wrap, full wrap, capped tail that wraps, bad magic."""
    ring = RING
    data = bytes((i * 7) & 0xff for i in range(ring))

    def blob(total):
        h = (b'SWEETLOG' + (1).to_bytes(4, 'little') + ring.to_bytes(4, 'little')
             + total.to_bytes(8, 'little') + (0).to_bytes(8, 'little'))
        return h + b'\x00' * (HEADER_BLOCK - len(h)) + data

    ok = True
    ok &= decode_ring(blob(1000)) == data[:1000]
    ok &= decode_ring(blob(ring + 500), 10 ** 9) == data[500:] + data[:500]
    ok &= decode_ring(blob(2 * ring + 500), 1000) == data[ring - 500:] + data[:500]
    ok &= decode_ring(b'nope' + data[:5000]) is None
    print('[*] SWEETLOG decoder self-test:', 'OK' if ok else 'FAILED')
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--adb', help='adb binary')
    ap.add_argument('--apk', default=os.path.join('android', 'app', 'build',
                                                  'outputs', 'apk', 'debug', 'app-debug.apk'))
    ap.add_argument('--no-install', action='store_true')
    ap.add_argument('--reinstall', action='store_true',
                    help='uninstall first (clears the app data: image + payload)')
    ap.add_argument('--read-secs', type=int, default=420,
                    help='how long to watch the VM after launch')
    ap.add_argument('--shot-secs', type=int, default=60)
    ap.add_argument('--out', default='artifacts/device-test')
    ap.add_argument('--native-app-check', action='store_true',
                    help='after the run, watch the guest console while you open Settings')
    ap.add_argument('--self-test', action='store_true',
                    help='check the SWEETLOG decoder on synthetic rings and exit')
    a = ap.parse_args(argv)

    if a.self_test:
        return self_test()

    adb = find_adb(a.adb)
    if not adb:
        print('[!] adb not found', file=sys.stderr)
        return 1
    dev = run([adb, 'devices']).stdout.splitlines()[1:]
    dev = [d.split()[0] for d in dev if d.strip() and 'device' in d]
    if len(dev) != 1:
        print('[!] expected one device, have %r' % dev, file=sys.stderr)
        return 1
    print('[*] device', dev[0])

    if not a.no_install:
        if a.reinstall:
            run([adb, 'uninstall', 'dev.hackios.sweetvm'])
        r = run([adb, 'install', '-r', '-g', a.apk], timeout=600)
        if r.returncode != 0:
            print(r.stdout + r.stderr, file=sys.stderr)
            print('[!] install failed; if this is INSTALL_FAILED_UPDATE_INCOMPATIBLE '
                  'rerun with --reinstall', file=sys.stderr)
            return 2
        print('[*] installed', a.apk)

    for name in ('files/payload.bin', 'files/ios16-root.img'):
        r = run([adb, 'shell', 'run-as', 'dev.hackios.sweetvm', 'ls', '-l', name])
        if r.returncode != 0 or 'No such file' in r.stdout:
            print('[!] missing %s in app storage (push it first)' % name, file=sys.stderr)
            return 3
        print('[*]', r.stdout.strip())

    os.makedirs(a.out, exist_ok=True)
    logf = open(os.path.join(a.out, 'logcat.txt'), 'w', encoding='utf-8', errors='replace')
    run([adb, 'logcat', '-c'])
    run([adb, 'shell', 'am', 'start', '-n',
         'dev.hackios.sweetvm/.MainActivity'])

    t0 = time.time()
    config_seen = False
    fps = []
    copies = []
    last_shot = 0
    proc = subprocess.Popen([adb, 'logcat', '-s', 'sweetvm:I', 'SWEET:I', '*:S'],
                            text=True, stdout=subprocess.PIPE, errors='replace')
    try:
        while time.time() - t0 < a.read_secs:
            line = proc.stdout.readline()
            if not line:
                break
            logf.write(line)
            logf.flush()
            if 'engine cpus=' in line:
                config_seen = True
                print('[*]', line.strip())
            m = re.search(r'fps=(\d+) ticks=(\d+) copies=(\d+) '
                          r'copy_avg_us=(\d+) copy_max_us=(\d+) uptime=(\d+)', line)
            if m:
                fps.append(int(m.group(1)))
                copies.append(int(m.group(4)))
                if len(fps) % 6 == 0:
                    print('[*] t+%ss fps=%s copy_avg_us=%s' % (m.group(6), m.group(1), m.group(4)))
            if time.time() - last_shot >= a.shot_secs:
                last_shot = time.time()
                shot = os.path.join(a.out, 'shot-%03d.png' % int(time.time() - t0))
                r = subprocess.run([adb, 'exec-out', 'screencap', '-p'],
                                   capture_output=True, timeout=60)
                with open(shot, 'wb') as f:
                    f.write(r.stdout)
                print('[*] screenshot', shot)
    finally:
        proc.terminate()
        logf.close()

    if not config_seen:
        print('[!] the engine never logged its configuration', file=sys.stderr)
        return 4

    # A swipe exercises the whole input path (Android -> touch.bin -> GT9896 ->
    # IOHIDEventService) and gives the guest something to animate.
    print('[*] swipe up on the panel')
    run([adb, 'shell', 'input', 'swipe', '540', '2000', '540', '700', '300'])
    time.sleep(15)
    shot = os.path.join(a.out, 'after-swipe.png')
    r = subprocess.run([adb, 'exec-out', 'screencap', '-p'],
                       capture_output=True, timeout=60)
    with open(shot, 'wb') as f:
        f.write(r.stdout)
    print('[*] screenshot', shot)

    if fps:
        nz = [f for f in fps if f > 0]
        print('[*] fps samples=%d median=%s max=%s' %
              (len(fps), sorted(nz)[len(nz) // 2] if nz else 0, max(fps)))
        if copies:
            print('[*] app-side copy median=%d us max=%d us' %
                  (sorted(copies)[len(copies) // 2], max(copies)))
        if max(fps) <= 12:
            print('[!] still capped near 12 fps - check the 高级选项 slider '
                  'and that the APK is the rebuilt one', file=sys.stderr)
    pull_guest_log(adb, 'dev.hackios.sweetvm', a.out)
    print('[*] logs and screenshots in', a.out)
    if a.native_app_check:
        return native_app_check(adb, 'dev.hackios.sweetvm', a.out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
