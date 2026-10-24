package dev.vmios.sweetvm;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;

/**
 * Reads the kernel's persistent console ring (xnu patch 0047) out of the raw
 * HFS+ root image.
 *
 * The kernel keeps every console byte in a 4 MiB ring and, once a second,
 * copies new bytes to the last 4 MiB + 4 KiB of the partition. The first 4 KiB
 * block is a header: "SWEETLOG", u32 version, u32 ring size, u64 total bytes
 * written, u64 flush sequence; the ring follows it.
 *
 * The app never saw guest console output before this: QEMU is started without
 * a console chardev, so vm/serial.log stays empty and panic reports were
 * invisible on the phone. This reads the ring straight from the image the VM
 * already holds open.
 */
public final class SweetLog {
    public static final int RING = 4 << 20;
    public static final int HEADER_BLOCK = 4096;

    private SweetLog() {
    }

    /** Last {@code maxBytes} of guest console output, or "" if there is none. */
    public static String tail(File image, int maxBytes) {
        if (image == null || !image.isFile() || maxBytes <= 0) {
            return "";
        }
        try (RandomAccessFile f = new RandomAccessFile(image, "r")) {
            long base = f.length() - RING - HEADER_BLOCK;
            if (base < 0) {
                return "";
            }
            byte[] h = new byte[32];
            f.seek(base);
            f.readFully(h);
            if (!"SWEETLOG".equals(new String(h, 0, 8, StandardCharsets.US_ASCII))) {
                return "";
            }
            int ring = (int) le32(h, 12);
            long total = le64(h, 16);
            if (ring <= 0 || ring > RING) {
                ring = RING;
            }
            int n = (int) Math.min(maxBytes, Math.min(total, ring));
            if (n <= 0) {
                return "";
            }
            int pos = (int) ((total - n) % ring);
            byte[] out = new byte[n];
            int first = Math.min(n, ring - pos);
            f.seek(base + HEADER_BLOCK + pos);
            f.readFully(out, 0, first);
            if (n > first) {
                f.seek(base + HEADER_BLOCK);
                f.readFully(out, first, n - first);
            }
            return new String(out, StandardCharsets.UTF_8);
        } catch (IOException e) {
            return "";
        }
    }

    private static long le32(byte[] b, int o) {
        return (b[o] & 0xffL) | (b[o + 1] & 0xffL) << 8
                | (b[o + 2] & 0xffL) << 16 | (b[o + 3] & 0xffL) << 24;
    }

    private static long le64(byte[] b, int o) {
        return le32(b, o) | le32(b, o + 4) << 32;
    }
}
