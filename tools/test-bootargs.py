#!/usr/bin/env python3
"""Test the app's boot_args path on the JVM, with no Android device.

`Payload.writeImages()` is plain Java (java.io/java.nio), so the class the app
ships can be compiled and run against a real payload. This checks the thing
that broke once already: the lock timeouts must be in the command line that is
packed into boot_args, and MainActivity's 573-byte limit must leave exactly
enough room for them.

  python3 tools/test-bootargs.py [payload.bin]

Exit codes: 0 pass, 1 no JDK, 2 compile/run failure, 3 assertion failure.
"""
import json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = 'dev/hackios/sweetvm'
LOCKS = ' tlto_us=2000000 slto_us=2000000'
LIMIT = 607 - len(LOCKS)          # MainActivity.MTTCG_LOCK_ARGS

TEST_JAVA = '''package dev.hackios.sweetvm;
import java.io.File;
import java.io.RandomAccessFile;

public class BootArgsTest {
    static String pack(Payload p, String cmdline) throws Exception {
        File ram = File.createTempFile("ram", ".bin");
        File stub = File.createTempFile("stub", ".bin");
        try {
            p.writeImages(ram, stub, cmdline);
            RandomAccessFile f = new RandomAccessFile(ram, "r");
            f.seek(p.bootArgsPa() - p.physBase + 0x6c);
            byte[] buf = new byte[608];
            f.readFully(buf);
            f.close();
            int n = 0;
            while (n < buf.length && buf[n] != 0) n++;
            return new String(buf, 0, n, "US-ASCII");
        } finally {
            ram.delete();
            stub.delete();
        }
    }

    static void check(boolean ok, String what) {
        if (!ok) throw new AssertionError(what);
    }

    public static void main(String[] a) throws Exception {
        Payload p = Payload.load(new File(a[0]));
        String base = p.cmdline();

        String got = pack(p, (base + LOCKS).trim());
        System.out.println("base: " + got);
        check(got.contains("tlto_us=2000000"), "lock timeout missing from boot_args: " + got);
        check(got.contains("slto_us=2000000"), "spin timeout missing from boot_args");
        check(got.contains("cpus=2"), "cpus missing from boot_args");

        StringBuilder pad = new StringBuilder(base);
        while (pad.length() < LIMIT) pad.append(' ');
        String atLimit = (pad + LOCKS).trim();
        check(atLimit.length() <= 607, "test cmdline exceeds boot_args: " + atLimit.length());
        String got2 = pack(p, atLimit);
        check(got2.contains("tlto_us=2000000") && got2.contains("slto_us=2000000"),
              "timeouts truncated at the MainActivity limit: " + got2);
        System.out.println("at-limit length: " + atLimit.length() + " ok");

        String over = (pad + " xxxxxxxx" + LOCKS).trim();
        String got3 = pack(p, over);
        check(!got3.endsWith("slto_us=2000000"),
              "expected truncation to drop the tail when over the limit");
        System.out.println("over-limit (" + over.length() + ") truncates: " + got3.substring(got3.length() - 20));
        System.out.println("boot_args test OK");
    }
}
'''


def find_jdk():
    for home in (os.environ.get('JAVA_HOME'), os.path.join(HERE, '.tools', 'jdk')):
        if not home:
            continue
        javac = os.path.join(home, 'bin', 'javac.exe' if os.name == 'nt' else 'javac')
        java = os.path.join(home, 'bin', 'java.exe' if os.name == 'nt' else 'java')
        if os.path.isfile(javac) and os.path.isfile(java):
            return javac, java
    return None, None


def main():
    payload = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        HERE, '.tools', 'frozen', 'payload-vm-mttcg.bin')
    if not os.path.isfile(payload):
        print('[!] payload not found:', payload, file=sys.stderr)
        return 2
    javac, java = find_jdk()
    if not javac:
        print('[!] no JDK (set JAVA_HOME or provide .tools/jdk)', file=sys.stderr)
        return 1
    src = os.path.join(HERE, 'android', 'app', 'src', 'main', 'java', PKG)
    with tempfile.TemporaryDirectory() as tmp:
        pkgdir = os.path.join(tmp, 'src', PKG)
        os.makedirs(pkgdir)
        shutil.copy(os.path.join(src, 'Payload.java'), pkgdir)
        test_src = os.path.join(pkgdir, 'BootArgsTest.java')
        with open(test_src, 'w', encoding='utf-8') as f:
            f.write(TEST_JAVA)
        # inject the constants the Java source expects
        s = open(test_src, encoding='utf-8').read().replace(
            'public class BootArgsTest {',
            'public class BootArgsTest {\n    static final String LOCKS = %s;\n'
            '    static final int LIMIT = %d;' % (json.dumps(LOCKS), LIMIT))
        open(test_src, 'w', encoding='utf-8').write(s)
        out = os.path.join(tmp, 'out')
        r = subprocess.run([javac, '-encoding', 'UTF-8', '-d', out,
                            os.path.join(pkgdir, 'Payload.java'), test_src],
                           capture_output=True)
        if r.returncode:
            print((r.stdout + r.stderr).decode('utf-8', 'replace'), file=sys.stderr)
            return 2
        r = subprocess.run([java, '-Dfile.encoding=UTF-8', '-cp', out,
                            'dev.hackios.sweetvm.BootArgsTest', os.path.abspath(payload)],
                           capture_output=True)
        print(r.stdout.decode('utf-8', 'replace'), end='')
        if r.returncode:
            print(r.stderr.decode('utf-8', 'replace'), file=sys.stderr)
            print('[!] FAILED', file=sys.stderr)
            return 3
        print('[*] PASS')
        return 0


if __name__ == '__main__':
    sys.exit(main())
