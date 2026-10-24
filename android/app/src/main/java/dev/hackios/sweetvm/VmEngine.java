package dev.hackios.sweetvm;

import android.app.ActivityManager;
import android.content.Context;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Runs the aarch64 QEMU with the SWEET loader stub, the UFS image device and
 * a file-backed guest RAM that the UI reads the panel from.
 */
public final class VmEngine {
    public interface Listener {
        void onExit(int code, String logTail);
        void onError(String message);
    }

    public static final long RAM_GIB = 3;
    public static final long RAM_BYTES = RAM_GIB << 30;
    public static final long FB_OFFSET = Payload.FB_BASE - Payload.RAM_BASE;
    private static final long OFFLOAD_OFFSET = FB_OFFSET + 0x1000000L;
    private static final int OFFLOAD_COMPLETED = 12;

    private final Context ctx;
    private Process process;
    private Thread monitor;
    private Thread reader;
    private volatile boolean running;
    private volatile boolean stopping;
    private volatile long frames;
    private volatile long ticks;
    private volatile long copyNanos;
    private volatile long copyMaxNanos;
    private File guestRam;
    private File rootFile;
    private File logFile;
    private File qmpSocket;
    private String engineId = "";
    private FramebufferView view;
    private int fps = 4;

    public VmEngine(Context ctx) {
        this.ctx = ctx.getApplicationContext();
    }

    public boolean isRunning() {
        return running;
    }

    public long frames() {
        return frames;
    }

    public long ticks() {
        return ticks;
    }

    public long copyNanos() {
        return copyNanos;
    }

    public long copyMaxNanos() {
        return copyMaxNanos;
    }

    public File logFile() {
        return logFile;
    }

    public File qmpSocket() {
        return qmpSocket;
    }

    public String engineId() {
        return engineId;
    }

    public void setView(FramebufferView v) {
        view = v;
    }

    public void start(File payloadFile, File rootFile, String cmdline, int fps,
                      boolean resume, Listener listener) throws Exception {
        stop();
        this.rootFile = rootFile;
        this.fps = Math.max(10, Math.min(60, fps));
        File vmDir = new File(ctx.getFilesDir(), "vm");
        if (!vmDir.isDirectory() && !vmDir.mkdirs()) {
            throw new IOException("无法创建 VM 目录");
        }
        logFile = new File(vmDir, "qemu.log");

        Payload payload = Payload.load(payloadFile);
        if (payload.physBase != 0xb0000000L) {
            throw new IOException("payload 不是 QEMU 低内存布局（phys_base="
                    + Long.toHexString(payload.physBase) + "）");
        }
        int cpus = 1;
        if (cmdline != null) {
            java.util.regex.Matcher m = java.util.regex.Pattern
                    .compile("(?:^| )cpus=(\\d+)").matcher(cmdline);
            if (m.find()) {
                cpus = Math.max(1, Math.min(8, Integer.parseInt(m.group(1))));
            }
        }
        // writeImages packs the command line into boot_args, so anything the
        // guest kernel must see has to be added before that call. Keep XNU's
        // ticket/spin lock timeouts generous: the defaults are ~125/250 ms
        // (tlto_us/slto_us, parsed by ml_init_lock_timeout), but a TCG vCPU
        // can exceed that while a lock owner blocks on host I/O, and the
        // resulting panic ("Ticket spinlock timeout", 3,000,001 ticks, owner
        // on CPU 1) looks like a deadlock. With 2 s the same MTTCG boot ran
        // 900 s without a panic. A truly stuck lock still panics, just later.
        if (cmdline == null) {
            cmdline = "";
        }
        if (!cmdline.contains("tlto_us=")) {
            cmdline = (cmdline + " tlto_us=2000000 slto_us=2000000").trim();
        }
        if (cmdline.length() >= 600) {
            android.util.Log.w("sweetvm", "boot args are " + cmdline.length()
                    + " bytes; the 607-byte boot_args field may truncate the lock timeouts");
        }
        // 3 GB of resident guest RAM is cheap on a 12-16 GB phone and makes
        // first-touch faults happen at startup instead of inside the vCPU
        // thread, but it can get the app killed on a small device. Only
        // prealloc when there is headroom.
        ActivityManager am = (ActivityManager) ctx.getSystemService(Context.ACTIVITY_SERVICE);
        ActivityManager.MemoryInfo mi = new ActivityManager.MemoryInfo();
        if (am != null) {
            am.getMemoryInfo(mi);
        }
        boolean prealloc = !resume && (am == null || mi.totalMem >= (6L << 30));

        File ram = new File(vmDir, "ram.bin");
        File stub = new File(vmDir, "stub.bin");
        payload.writeImages(ram, stub, cmdline);

        // Keep the 3 GB RAM file on internal storage: the old external path is
        // FUSE-backed and makes every guest RAM access pay a FUSE round trip.
        File oldRam = new File(BootConfig.externalDir(ctx), "guest-ram.bin");
        if (oldRam.isFile()) {
            oldRam.delete();
        }
        guestRam = new File(vmDir, "guest-ram.bin");
        try (RandomAccessFile rf = new RandomAccessFile(guestRam, "rw")) {
            if (rf.length() != RAM_BYTES) {
                rf.setLength(RAM_BYTES);
            }
        }

        File qemuShare = new File(vmDir, "qemu-share");
        if (!qemuShare.isDirectory()) {
            qemuShare.mkdirs();
        }
        File serial = new File(vmDir, "serial.log");
        serial.delete();

        EngineAssets.Engine eng = EngineAssets.ensure(ctx);
        engineId = eng.version;
        String qemu = eng.qemu.getAbsolutePath();

        List<String> cmd = new ArrayList<>();
        cmd.add(qemu);
        cmd.add("-M"); cmd.add("virt,gic-version=3");
        cmd.add("-cpu"); cmd.add("cortex-a76");
        cmd.add("-smp"); cmd.add(Integer.toString(cpus));
        cmd.add("-m"); cmd.add(RAM_GIB + "G");
        // Single-threaded TCG stays the default; tcgmulti=1 turns on MTTCG
        // (two real vCPUs). One MTTCG boot reached the iOS Setup GUI at 300 s;
        // another stalled in userland, so the speed win is not proven yet.
        boolean mttcg = cpus >= 2 && cmdline.contains("tcgmulti=1");
        boolean offload = cmdline.contains("sweetfb_offload=1");
        boolean gpuWire = cmdline.contains("gpu_wire=1");
        android.util.Log.i("sweetvm", "engine cpus=" + cpus + " accel="
                + (mttcg ? "tcg,thread=multi" : "tcg,thread=single")
                + " prealloc=" + prealloc
                + " present=" + (offload ? "native" : "guest")
                + " gpu_wire=" + gpuWire
                + " capture=" + this.fps + "fps");
        // A large TB cache matters for the multi-hundred-MB dyld shared cache.
        cmd.add("-accel");
        cmd.add(mttcg ? "tcg,thread=multi,tb-size=512" : "tcg,thread=single,tb-size=512");
        cmd.add("-display"); cmd.add("none");
        cmd.add("-serial"); cmd.add("file:" + serial.getAbsolutePath());
        cmd.add("-monitor"); cmd.add("none");
        qmpSocket = new File(vmDir, "qmp.sock");
        qmpSocket.delete();
        cmd.add("-qmp");
        cmd.add("unix:" + qmpSocket.getAbsolutePath() + ",server=on,wait=off");
        cmd.add("-no-reboot");
        cmd.add("-nic"); cmd.add("none");
        cmd.add("-L"); cmd.add(qemuShare.getAbsolutePath());
        if (offload) {
            cmd.add("-device");
            cmd.add("sweet-fb");
        }
        if (gpuWire) {
            // Guest -> Android host GPU pipe: the ADT's virtio0 node maps the
            // first virtio-mmio slot at 0x0a000000; the socket chardev connects
            // to GpuWireServer in this process. QEMU connects at startup, so
            // the server must be listening before the process is spawned.
            GpuWireServer.start(5141);
            cmd.add("-global"); cmd.add("virtio-mmio.force-legacy=false");
            cmd.add("-chardev"); cmd.add("socket,id=gpu_wire,host=127.0.0.1,port=5141");
            cmd.add("-device"); cmd.add("virtio-serial-device,bus=virtio-mmio-bus.0");
            cmd.add("-device"); cmd.add("virtconsole,chardev=gpu_wire,name=offline-transport");
        }
        cmd.add("-object");
        // prealloc: without it every first touch of a guest page is a host
        // page fault inside the vCPU thread. iOS allocates continuously, so
        // those faults freeze the whole guest for milliseconds - the "stall
        // that is not rendering". Touch all of it once at startup instead.
        // A resume loads the whole RAM image anyway, so it needs no prealloc.
        cmd.add("memory-backend-file,id=ram,size=" + RAM_GIB
                + "G,mem-path=" + guestRam.getAbsolutePath() + ",share=on"
                + (prealloc ? ",prealloc=on,prealloc-threads=4" : ""));
        cmd.add("-numa"); cmd.add("node,memdev=ram");
        cmd.add("-device");
        cmd.add(String.format(Locale.US, "loader,file=%s,addr=0x%x,force-raw=on",
                ram.getAbsolutePath(), payload.physBase));
        cmd.add("-device");
        cmd.add(String.format(Locale.US, "loader,file=%s,addr=0x%x,force-raw=on",
                stub.getAbsolutePath(), Payload.STUB_PA));
        cmd.add("-device");
        cmd.add(String.format(Locale.US, "loader,addr=0x%x,cpu-num=0", Payload.STUB_PA));
        if (rootFile != null) {
            if (!rootFile.isFile()) {
                throw new IOException("iOS 根镜像不存在");
            }
            cmd.add("-device");
            cmd.add("sweet-ufs,file=" + rootFile.getAbsolutePath() + ",mmio-base=0xe000000");
            if (resume) {
                cmd.add("-incoming");
                cmd.add("file:" + Snapshot.stateFile(ctx).getAbsolutePath());
            }
        }
        File touchFile = new File(vmDir, "touch.bin");
        touchFile.delete();
        cmd.add("-device");
        cmd.add("sweet-touch,touchfile=" + touchFile.getAbsolutePath());

        ProcessBuilder pb = new ProcessBuilder(cmd);
        pb.environment().put("LD_LIBRARY_PATH", eng.dir.getAbsolutePath());
        pb.environment().put("HOME", ctx.getFilesDir().getAbsolutePath());
        pb.environment().put("TMPDIR", ctx.getCacheDir().getAbsolutePath());
        pb.environment().put("QEMU_AUDIO_DRV", "none");
        pb.redirectErrorStream(true);
        pb.redirectOutput(ProcessBuilder.Redirect.to(logFile));
        final Process p = pb.start();
        process = p;
        running = true;
        stopping = false;
        frames = 0;
        ticks = 0;
        copyNanos = 0;
        copyMaxNanos = 0;

        monitor = new Thread(() -> {
            int code = -1;
            try {
                code = p.waitFor();
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
            running = false;
            stopReader();
            if (listener != null && !stopping) {
                listener.onExit(code, tail());
            }
        }, "sweetvm-monitor");
        monitor.setDaemon(true);
        monitor.start();

        startReader(guestRam, payload, listener, offload);
    }

    /** Probe every this many 32-bit words: 16 words = 64 bytes. */
    private static final int PROBE_STEP = 16;

    /**
     * A full 1080x2400 frame is 10.4 MB. Copying it on every tick regardless of
     * what the guest did costs a memcpy plus a texture upload for a picture that
     * has not changed (iOS only presents on change, so most ticks have nothing
     * new). Sample every 16th word (64 bytes) of the panel and skip the copy
     * when nothing moved. The old 256-word probe sampled one word every 40 KB,
     * so a localized change (a caret, a toggle, a tap highlight) could go
     * unseen for many ticks - a frozen frame that looked like guest lag.
     */
    private static boolean changed(MappedByteBuffer map, int[] probe, int[] last, boolean haveLast) {
        int words = Math.min(probe.length, Payload.FB_STRIDE * Payload.FB_H / 4 / PROBE_STEP);
        boolean diff = !haveLast;
        for (int i = 0; i < words; i++) {
            int v = map.getInt(i * PROBE_STEP * 4);
            probe[i] = v;
            if (haveLast && v != last[i]) {
                diff = true;
            }
        }
        return diff;
    }

    private void startReader(File guestRam, Payload payload, Listener listener, boolean offload) {
        reader = new Thread(() -> {
            FileChannel ch = null;
            MappedByteBuffer map = null;
            ByteBuffer completion = null;
            boolean sequenceMode = offload;
            try {
                ch = FileChannel.open(guestRam.toPath(),
                        java.nio.file.StandardOpenOption.READ);
                map = ch.map(FileChannel.MapMode.READ_ONLY, FB_OFFSET,
                        (long) Payload.FB_STRIDE * Payload.FB_H);
                if (sequenceMode) {
                    completion = ch.map(FileChannel.MapMode.READ_ONLY, OFFLOAD_OFFSET, 32)
                            .order(ByteOrder.LITTLE_ENDIAN);
                }
            } catch (Exception e) {
                sequenceMode = false;
                if (listener != null) {
                    listener.onError("无法映射共享显存: " + e.getMessage());
                }
            }
            // Deadline pacing, not Thread.sleep: a fixed sleep adds the copy
            // time to every interval, so a 16 fps guest sampled at 30 fps
            // drifts and beats (judder). Keep a monotonic deadline and park
            // only the remainder; if a copy overruns the period, restart it.
            final long period = 1_000_000_000L / Math.max(1, fps);
            long next = System.nanoTime() + period;
            int[] probe = sequenceMode ? null
                    : new int[Payload.FB_STRIDE * Payload.FB_H / 4 / PROBE_STEP];
            int[] lastProbe = sequenceMode ? null : new int[probe.length];
            boolean haveLast = false;
            int lastSequence = -1;
            try {
                while (running) {
                    ticks++;
                    FramebufferView v = view;
                    boolean newFrame;
                    if (sequenceMode) {
                        int sequence = completion.getInt(OFFLOAD_COMPLETED);
                        newFrame = sequence != lastSequence;
                        lastSequence = sequence;
                    } else {
                        newFrame = changed(map, probe, lastProbe, haveLast);
                    }
                    if (map != null && v != null && newFrame) {
                        if (!sequenceMode) {
                            System.arraycopy(probe, 0, lastProbe, 0, probe.length);
                            haveLast = true;
                        }
                        long t0 = System.nanoTime();
                        v.copyFromBuffer(map);
                        long dt = System.nanoTime() - t0;
                        copyNanos += dt;
                        if (dt > copyMaxNanos) {
                            copyMaxNanos = dt;
                        }
                        frames++;
                    }
                    long now = System.nanoTime();
                    if (next > now) {
                        java.util.concurrent.locks.LockSupport.parkNanos(next - now);
                    } else {
                        next = now;
                    }
                    next += period;
                    if (next < now) {
                        next = now + period;
                    }
                }
            } finally {
                if (ch != null) {
                    try {
                        ch.close();
                    } catch (IOException ignored) {
                    }
                }
            }
        }, "sweetvm-fb");
        reader.setDaemon(true);
        reader.start();
    }

    private void stopReader() {
        Thread r = reader;
        reader = null;
        if (r != null) {
            r.interrupt();
        }
    }

    public void stop() {
        stopping = true;
        running = false;
        stopReader();
        Process p = process;
        process = null;
        if (p != null) {
            p.destroy();
            try {
                if (!p.waitFor(2, java.util.concurrent.TimeUnit.SECONDS)) {
                    p.destroyForcibly();
                }
            } catch (InterruptedException e) {
                p.destroyForcibly();
                Thread.currentThread().interrupt();
            }
        }
        Thread m = monitor;
        monitor = null;
        if (m != null) {
            m.interrupt();
        }
    }

    public String tail() {
        StringBuilder sb = new StringBuilder();
        appendTail(sb, logFile, 8192);
        File serial = new File(ctx.getFilesDir(), "vm/serial.log");
        appendTail(sb, serial, 4096);
        String guest = SweetLog.tail(rootFile, 32768);
        if (!guest.isEmpty()) {
            sb.append("\n--- SWEETLOG ---\n").append(guest);
        }
        String s = sb.toString().trim();
        return s.isEmpty() ? "(QEMU 没有输出)" : s;
    }

    private static void appendTail(StringBuilder sb, File f, int max) {
        if (f == null || !f.isFile()) {
            return;
        }
        long len = f.length();
        long start = Math.max(0, len - max);
        try (FileInputStream in = new FileInputStream(f)) {
            long skipped = in.skip(start);
            byte[] buf = new byte[(int) (len - skipped)];
            int off = 0;
            int n;
            while (off < buf.length && (n = in.read(buf, off, buf.length - off)) > 0) {
                off += n;
            }
            sb.append(new String(buf, 0, off, StandardCharsets.UTF_8)).append('\n');
        } catch (IOException ignored) {
        }
    }
}
