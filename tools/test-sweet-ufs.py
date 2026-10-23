#!/usr/bin/env python3
"""Compile and exercise the non-kernel-dependent parts of the SWEET UFS work.

The kernel tree cannot be built on a Windows host, so the code added by
0083 (console timestamps) and 0084 (UFS statistics) is cut out of
bsd/dev/sweet_ufs.c, compiled against small stubs of the kernel facilities it
uses, and driven through the cases that matter. This is not a kernel test: it
covers the arithmetic and the ring-buffer bookkeeping, which is where a bug
would be silent (a prefix that is one byte short corrupts every line after it).

  python3 tools/test-sweet-ufs.py                 # --src research/xnu/work
  python3 tools/test-sweet-ufs.py --src /usr/src/xnu-8796

Needs a host C compiler (`cc`, `gcc` or `clang`); exits 2 if there is none.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

TIMESTAMP_HARNESS = r'''
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#define relaxed 0
static uint64_t fake_now;
uint64_t mach_absolute_time(void) { return fake_now; }
void absolutetime_to_nanoseconds(uint64_t at, uint64_t *out) { *out = at; }
enum { NSEC_PER_SEC = 1000000000ull, NSEC_PER_MSEC = 1000000ull };

#define SWEET_LOG_SIZE (1u << 16)
static char sweet_log_ring[SWEET_LOG_SIZE];
static uint64_t sweet_log_total;

static uint64_t os_atomic_add_orig(uint64_t *p, uint64_t v, int m)
{
	(void)m;
	uint64_t old = *p;
	*p = old + v;
	return old;
}
#define SWEET_TS_LEN 13u
static bool sweet_ts = true;
static bool sweet_ts_bol = true;

%s

static int fails;

static void expect(const char *label, const char *want)
{
	char got[512];
	uint64_t n = sweet_log_total < sizeof(got) - 1 ? sweet_log_total : sizeof(got) - 1;
	for (uint64_t i = 0; i < n; i++) {
		got[i] = sweet_log_ring[i %% SWEET_LOG_SIZE];
	}
	got[n] = 0;
	for (uint64_t i = 0; i < n; i++) {
		if (got[i] == '\n') {
			got[i] = '|';
		}
	}
	if (strcmp(got, want) != 0) {
		printf("FAIL %%s\n  got  %%s\n  want %%s\n", label, got, want);
		fails++;
	} else {
		printf("ok   %%s\n", label);
	}
}

int main(void)
{
	fake_now = 123456789ull;                 /* 0.123 s: digits and field width */
	sweet_log_append("hello\n", 6);
	expect("one line", "[000000.123] hello|");

	sweet_log_total = 0;                     /* two lines in one chunk */
	fake_now = 5000000000ull;
	sweet_log_append("a\nb\n", 4);
	expect("two lines", "[000005.000] a|[000005.000] b|");

	sweet_log_total = 0;                     /* a chunk split mid-line */
	sweet_ts_bol = true;
	fake_now = 7000000000ull;
	sweet_log_append("SWEET UFS: ", 11);
	sweet_log_append("stats\n", 6);
	expect("split chunk", "[000007.000] SWEET UFS: stats|");

	sweet_log_total = 0;                     /* truncation, not rounding */
	sweet_ts_bol = true;
	fake_now = 61999999999ull;
	sweet_log_append("x\n", 2);
	expect("rollover", "[000061.999] x|");

	sweet_log_total = 0;                     /* 6-digit field saturates */
	sweet_ts_bol = true;
	fake_now = 1000000ull * 1000000000ull;
	sweet_log_append("x\n", 2);
	expect("saturate", "[999999.000] x|");

	if (sweet_log_total != 13 + 2) {         /* every prefix is SWEET_TS_LEN */
		printf("FAIL prefix length %%llu\n", (unsigned long long)sweet_log_total);
		fails++;
	} else {
		printf("ok   prefix length 13\n");
	}

	sweet_ts = false;                        /* sweetts=0: bytes unchanged */
	sweet_log_total = 0;
	sweet_ts_bol = true;
	sweet_log_append("raw\n", 4);
	expect("disabled", "raw|");

	printf(fails ? "\nFAILED %%d\n" : "\nALL OK\n", fails);
	return fails != 0;
}
'''

STATS_HARNESS = r'''
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define __unused __attribute__((unused))
typedef int wait_result_t;
typedef void *thread_t;
#define PZERO 22
int hz = 100;

static uint64_t fake_now;
uint64_t mach_absolute_time(void) { return fake_now; }
void absolutetime_to_nanoseconds(uint64_t at, uint64_t *o) { *o = at; }
typedef struct { int x; } lck_mtx_t;
static lck_mtx_t sweet_ufs_lock;
void lck_mtx_lock(lck_mtx_t *l) { (void)l; }
void lck_mtx_unlock(lck_mtx_t *l) { (void)l; }

static bool ufs_stats_on = true;
static uint32_t ufs_stats_secs = 2;
static int ufs_stats_chan;
static uint64_t ufs_st_cmds, ufs_st_reads, ufs_st_writes, ufs_st_bytes;
static uint64_t ufs_st_ns, ufs_st_max_ns, ufs_st_slept, ufs_st_errors;

static void ufs_stat(uint64_t t0, uint32_t len, bool write, bool slept, bool ok);

static int tsleep_calls;
int tsleep(void *chan, int pri, const char *what, int timo)
{
	(void)chan; (void)pri; (void)what; (void)timo;
	tsleep_calls++;
	if (tsleep_calls == 2) {                 /* interval 2: one more 1 ms read */
		fake_now += 1000000;
		ufs_stat(fake_now - 1000000, 4096, false, true, true);
	}
	if (tsleep_calls >= 3) {
		exit(0);                         /* the real loop never ends */
	}
	return 0;
}

%s

int main(void)
{
	/* 3 cmds: 2 reads + 1 write, 1 error, 2 slept, max 12 ms, 6 KiB */
	fake_now = 12000000;   ufs_stat(0,        2048, false, true,  true);
	fake_now = 14000000;   ufs_stat(13000000, 2048, false, false, false);
	fake_now = 15000000;   ufs_stat(14000000, 2048, true,  true,  true);
	ufs_stats_thread(NULL, 0);
	return 0;
}
'''

EXPECT_TIMESTAMP = [
    "ok   one line", "ok   two lines", "ok   split chunk", "ok   rollover",
    "ok   saturate", "ok   prefix length 13", "ok   disabled", "ALL OK",
]
EXPECT_STATS = [
    "SWEET UFS: statistics every 2 s (ufsstats=1)",
    "SWEET UFS: 3 cmds (2 rd/1 wr, +3), 6 KiB (+6), avg 4666 us, max 12000 us, slept 2, errors 1",
    "SWEET UFS: 4 cmds (3 rd/1 wr, +1), 10 KiB (+4), avg 1000 us, max 12000 us, slept 3, errors 1",
]


def cut(src, start, end):
    i = src.index(start)
    j = src.index(end, i)
    return src[i:j]


def build(cc, workdir, name, harness, body):
    path = os.path.join(workdir, name + ".c")
    with open(path, "w") as f:
        f.write(harness % body)
    exe = os.path.join(workdir, name + (".exe" if os.name == "nt" else ""))
    cmd = [cc, "-std=gnu11", "-Wall", "-Wextra", "-Wno-unused-parameter",
           "-Wformat=2", "-Werror=format", "-o", exe, path]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(res.stdout + res.stderr)
        raise SystemExit("%s: does not compile" % name)
    return subprocess.run([exe], capture_output=True, text=True).stdout


def check(label, out, needles):
    missing = [n for n in needles if n not in out]
    if missing:
        print(out)
        for n in missing:
            print("  missing: %s" % n)
        return False
    print("  [ok] %s" % label)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="research/xnu/work",
                    help="xnu tree with the patch series applied")
    a = ap.parse_args()

    src_path = os.path.join(a.src, "bsd/dev/sweet_ufs.c")
    if not os.path.isfile(src_path):
        raise SystemExit("no %s; unpack xnu and apply xnu/patches/*.patch first" % src_path)
    src = open(src_path).read()

    cc = next((c for c in ("cc", "gcc", "clang") if shutil.which(c)), None)
    if not cc:
        print("no C compiler on this host", file=sys.stderr)
        return 2

    ts_body = cut(src, "static uint32_t\nsweet_ts_prefix(char *out)",
                  "/* Called for all console output")
    ts_body += cut(src, "void\nsweet_log_append(const char *c, int size)\n{",
                   "/*\n * Copy console bytes")
    stats_body = cut(src, "/* Called at the end of every command",
                     "static inline uint32_t\nufs_rd")
    stats_body += cut(src, "static void\nufs_stats_thread", "static void\nufs_stats_start")

    work = tempfile.mkdtemp(prefix="sweet-ufs-test-")
    try:
        ok = check("sweetts prefix", build(cc, work, "ts", TIMESTAMP_HARNESS, ts_body),
                   EXPECT_TIMESTAMP)
        ok &= check("ufsstats counters", build(cc, work, "stats", STATS_HARNESS, stats_body),
                    EXPECT_STATS)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if not ok:
        raise SystemExit("FAILED")
    print("all harness checks passed (%s, %s)" % (cc, src_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
