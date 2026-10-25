package dev.vmios.sweetvm;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * A SWEETXNU payload (tools/mkpayload.py): kernel segments + ADT + the
 * physical layout the QEMU loader expects.  This mirrors build_image() in
 * tools/qemu-sweet.py.  Java long arithmetic is modulo 2^64, which is what the
 * unsigned Python values do here.
 */
public final class Payload {
    public static final String MAGIC = "SWEETXNU";
    public static final long RAM_BASE = 0x40000000L;
    public static final long STUB_PA = 0x40200000L;
    public static final long FB_BASE = 0x9c000000L;
    public static int FB_W = 1080;
    public static int FB_H = 2400;
    public static int FB_STRIDE = FB_W * 4;
    public static final int PAGE = 0x4000;

    private static final int CMDLINE_LEN = 608;

    public static void configure(String cmdline) {
        FB_W = 1080;
        FB_H = 2400;
        java.util.regex.Matcher w = java.util.regex.Pattern
                .compile("(?:^| )sweetfb_w=(\\d+)").matcher(cmdline);
        java.util.regex.Matcher h = java.util.regex.Pattern
                .compile("(?:^| )sweetfb_h=(\\d+)").matcher(cmdline);
        if (w.find() && h.find()) {
            int width = Integer.parseInt(w.group(1));
            int height = Integer.parseInt(h.group(1));
            if (width > 0 && height > 0 && width <= 4096 && height <= 4096) {
                FB_W = width;
                FB_H = height;
            }
        }
        FB_STRIDE = FB_W * 4;
    }

    public static final class Segment {
        public final long vmaddr, vmsize, fileOff, fileSize;
        Segment(long vmaddr, long vmsize, long fileOff, long fileSize) {
            this.vmaddr = vmaddr;
            this.vmsize = vmsize;
            this.fileOff = fileOff;
            this.fileSize = fileSize;
        }
    }

    public final byte[] data;
    public final int nsegs;
    public final long virtBase, entryVa, adtOff, adtSize, kernelEnd, physBase, memSize;
    public final List<Segment> segments = new ArrayList<>();

    private Payload(byte[] data) {
        this.data = data;
        ByteBuffer b = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN);
        byte[] magic = new byte[8];
        b.get(magic);
        if (!MAGIC.equals(new String(magic, StandardCharsets.US_ASCII))) {
            throw new IllegalArgumentException("不是 SWEETXNU payload");
        }
        if (b.getInt(8) != 1) {
            throw new IllegalArgumentException("不支持的 payload 版本");
        }
        nsegs = b.getInt(12);
        if (nsegs <= 0 || nsegs > 64) {
            throw new IllegalArgumentException("payload 段数异常: " + nsegs);
        }
        virtBase = b.getLong(0x10);
        entryVa = b.getLong(0x18);
        adtOff = b.getLong(0x20);
        adtSize = b.getLong(0x28);
        kernelEnd = b.getLong(0x30);
        physBase = b.getLong(0x38);
        memSize = b.getLong(0x40);
        if (adtOff < 0 || adtSize <= 0 || adtOff + adtSize > data.length) {
            throw new IllegalArgumentException("ADT 范围无效");
        }
        for (int i = 0; i < nsegs; i++) {
            int o = 0x2a8 + 32 * i;
            if (o + 32 > data.length) {
                throw new IllegalArgumentException("payload 段表被截断");
            }
            segments.add(new Segment(b.getLong(o), b.getLong(o + 8),
                    b.getLong(o + 16), b.getLong(o + 24)));
            Segment s = segments.get(i);
            if (s.fileOff < 0 || s.fileSize < 0 ||
                s.fileOff + s.fileSize > data.length || s.fileSize > s.vmsize) {
                throw new IllegalArgumentException("payload 段 " + i + " 越界");
            }
        }
    }

    public static Payload load(File file) throws IOException {
        if (file == null || !file.isFile()) {
            throw new IOException("payload 不存在");
        }
        if (file.length() > 64L * 1024 * 1024) {
            throw new IOException("payload 太大");
        }
        try (FileInputStream in = new FileInputStream(file)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream((int) file.length());
            byte[] buf = new byte[1 << 16];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
            }
            return new Payload(out.toByteArray());
        }
    }

    public String cmdline() {
        int start = 0x48;
        int end = start + CMDLINE_LEN;
        if (end > data.length) {
            return "";
        }
        int n = 0;
        while (n < CMDLINE_LEN && data[start + n] != 0) {
            n++;
        }
        return new String(data, start, n, StandardCharsets.US_ASCII);
    }

    public long delta() {
        return physBase - virtBase;
    }

    public long adtPa() {
        return kernelEnd + delta();
    }

    public long bootArgsPa() {
        long adtPa = adtPa();
        return (adtPa + adtSize + PAGE - 1) & ~((long) PAGE - 1);
    }

    public long imageSize() {
        return bootArgsPa() + PAGE - physBase;
    }

    public long entryPa() {
        return entryVa + delta();
    }

    /** Build ram.bin (payload bytes placed at their physical addresses) and stub.bin. */
    public void writeImages(File ramFile, File stubFile, String overrideCmdline) throws IOException {
        long imgSize = imageSize();
        if (imgSize <= 0 || imgSize > 256L * 1024 * 1024) {
            throw new IOException("payload 物理映像大小异常: " + imgSize);
        }
        byte[] img = new byte[(int) imgSize];
        for (Segment s : segments) {
            long off = s.vmaddr - virtBase;
            if (off < 0 || off + s.fileSize > imgSize) {
                throw new IOException("段落在物理映像之外");
            }
            System.arraycopy(data, (int) s.fileOff, img, (int) off, (int) s.fileSize);
        }
        long adtPa = adtPa();
        System.arraycopy(data, (int) adtOff, img, (int) (adtPa - physBase), (int) adtSize);

        ByteBuffer ba = ByteBuffer.allocate(736).order(ByteOrder.LITTLE_ENDIAN);
        ba.putShort((short) 2);             // Revision
        ba.putShort((short) 2);             // Version
        ba.putInt(0);                       // flags/padding
        ba.putLong(virtBase);
        ba.putLong(physBase);
        ba.putLong(memSize);
        ba.putLong(bootArgsPa() + PAGE);    // topOfKernelData
        ba.putLong(FB_BASE);
        ba.putLong(1);
        ba.putLong(FB_STRIDE);
        ba.putLong(FB_W);
        ba.putLong(FB_H);
        ba.putLong(32);
        ba.putInt(0);
        ba.putInt(0);
        ba.putLong(adtPa - delta());        // deviceTreeP (virtual)
        ba.putInt((int) adtSize);
        String cmdline = (overrideCmdline == null || overrideCmdline.isEmpty())
                ? cmdline() : overrideCmdline;
        byte[] c = cmdline.getBytes(StandardCharsets.US_ASCII);
        int cn = Math.min(c.length, CMDLINE_LEN - 1);
        ba.put(c, 0, cn);
        ba.position(ba.position() + (CMDLINE_LEN - cn));
        ba.putInt(0);
        ba.putLong(0);
        ba.putLong(memSize);
        if (ba.position() != 736) {
            throw new IOException("boot_args 大小错误: " + ba.position());
        }
        long baPa = bootArgsPa();
        System.arraycopy(ba.array(), 0, img, (int) (baPa - physBase), ba.capacity());

        try (FileOutputStream out = new FileOutputStream(ramFile)) {
            out.write(img);
        }

        /*
         * Multi-CPU QEMU boots run with virtualization=on, so QEMU enters
         * this stub at EL2 (its PSCI SMC conduit). XNU must run at EL1:
         * drop EL2 -> EL1 with HCR_EL2.RW=1 (AArch64 EL1), then load
         * boot_args/entry and branch. At EL1 the first compare falls through.
         */
        int[] code = {
                0xd5384242, // mrs x2, CurrentEL
                0xf100205f, // cmp x2, #8 (EL2)
                0x54000101, // b.ne 2f
                0xd28078a2, // mov x2, #0x3c5 (EL1h, DAIF masked)
                0xd51c4002, // msr spsr_el2, x2
                0x100000a2, // adr x2, 2f
                0xd51c4022, // msr elr_el2, x2
                0xd2b00002, // mov x2, #0x80000000 (HCR_EL2.RW=1)
                0xd51c1102, // msr hcr_el2, x2
                0xd69f03e0, // eret
                0x10000083, // adr x3, 3f
                0xf9400060, // ldr x0, [x3]
                0xf9400461, // ldr x1, [x3, #8]
                0xd61f0020, // br x1
        };
        ByteBuffer stub = ByteBuffer.allocate(72).order(ByteOrder.LITTLE_ENDIAN);
        for (int word : code) {
            stub.putInt(word);
        }
        stub.putLong(baPa);
        stub.putLong(entryPa());
        try (FileOutputStream out = new FileOutputStream(stubFile)) {
            out.write(stub.array());
        }
    }
}
