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
    a = ap.parse_args(argv)

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
            m = re.search(r'fps=(\d+) frames=(\d+) uptime=(\d+)', line)
            if m:
                fps.append(int(m.group(1)))
                if len(fps) % 6 == 0:
                    print('[*] t+%ss fps=%s' % (m.group(3), m.group(1)))
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
        if max(fps) <= 12:
            print('[!] still capped near 12 fps - check the 高级选项 slider '
                  'and that the APK is the rebuilt one', file=sys.stderr)
    print('[*] logs and screenshots in', a.out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
