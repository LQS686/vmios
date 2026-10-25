package dev.vmios.sweetvm;

import android.util.Log;

import java.io.File;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;
import java.util.HashMap;

/**
 * Host rasterizer for the CoreAnimation draw batches the plugin forwards
 * (WIRE_CA_DRAW / WIRE_TEXMAP / WIRE_CA_FLUSH).
 *
 * Every guest surface arrives as a 16 KiB page table, so pixels are read and
 * written in guest RAM through the shared RAM file; nothing is copied into a
 * host-side shadow, which keeps the guest and the compositor looking at the
 * same bytes. The fragment math mirrors the plugin's local rasterizer exactly
 * (source-over, plus CA's luminance blend), so a draw takes the same path
 * whichever side executes it.
 */
final class GuestRam {
    static final long BASE = 0x40000000L;
    private static final int SHIFT = 29;
    private static final int SIZE = 1 << SHIFT;
    private static final int MASK = SIZE - 1;

    private final MappedByteBuffer[] windows;
    private final long length;

    GuestRam(File file) throws Exception {
        long length = file.length();
        this.length = length;
        int count = (int) ((length + SIZE - 1) >>> SHIFT);
        if (count <= 0) {
            throw new IllegalStateException("empty guest ram");
        }
        windows = new MappedByteBuffer[count];
        RandomAccessFile f = new RandomAccessFile(file, "rw");
        try {
            FileChannel channel = f.getChannel();
            for (int i = 0; i < count; i++) {
                long offset = (long) i << SHIFT;
                long size = Math.min(SIZE, length - offset);
                MappedByteBuffer window = channel.map(FileChannel.MapMode.READ_WRITE,
                        offset, size);
                window.order(ByteOrder.LITTLE_ENDIAN);
                windows[i] = window;
            }
        } finally {
            f.close();
        }
    }

    ByteBuffer at(long pa) {
        return windows[(int) ((pa - BASE) >>> SHIFT)];
    }

    int index(long pa) {
        return (int) ((pa - BASE) & MASK);
    }

    boolean contains(long pa) {
        return pa >= BASE && pa - BASE < length;
    }
}

final class CaCompositor {
    private static final String TAG = "sweetgpu-ca";
    static final int F_TEXTURED = 1;
    static final int F_UPLOAD_TEX = 2;
    static final int F_INTERNAL = 4;
    static final int F_TEX_CHUNK = 8;
    static final int HEADER_BYTES = 88;
    static final int VERTEX_BYTES = 32;
    static final int UPLOAD_CHUNK = 3800;

    private final GuestRam ram;
    private final HashMap<Integer, Surface> surfaces = new HashMap<>();
    private final HashMap<Integer, Upload> uploads = new HashMap<>();
    private final HashMap<Integer, Decoded> decoded = new HashMap<>();
    private long draws;
    private long pixels;
    private long decodeCount;
    private int uploadLogs;
    private int drawLogs;
    private int rejectLogs;
    private int mapLogs;
    private long frame;
    private long frameStart = System.nanoTime();
    private long frameDraws;
    private long framePixels;
    private int dropped;

    CaCompositor(GuestRam ram) {
        this.ram = ram;
    }

    private boolean disabled() {
        return ram == null;
    }

    static final class Surface {
        int id;
        long[] pages;
        int pageShift = 14;
        int pageSize = 1 << 14;
        int pageMask = (1 << 14) - 1;
        int total;
        int received;
        int bpr;
        int width;
        int height;
        long alloc;

        boolean ready() {
            return total > 0 && received >= total;
        }
    }

    static final class Upload {
        byte[] data;
        int expect;
        int got;
        int texFmt;
        int width;
        int height;
        int bpr;
        boolean ready;
    }

    static final class Decoded {
        int[] pixels;
        int width;
        int height;
    }

    /* ---- wire messages -------------------------------------------------- */

    void onMap(ByteBuffer b) {
        if (disabled()) {
            return;
        }
        int id = b.getInt(0);
        int pageIndex = b.getInt(4);
        int pageCount = b.getInt(8);
        int total = b.getInt(12);
        int shift = b.getInt(32);
        long alloc = (b.getInt(16) & 0xffffffffL) | ((long) b.getInt(20) << 32);
        if (shift < 12 || shift > 20 || pageCount <= 0 || total <= 0
                || pageIndex < 0 || pageIndex + pageCount > total) {
            return;
        }
        Surface s = surfaces.get(id);
        if (s == null || s.total != total || pageIndex == 0) {
            s = new Surface();
            s.id = id;
            s.total = total;
            s.pages = new long[total];
            s.pageShift = shift;
            s.pageSize = 1 << shift;
            s.pageMask = s.pageSize - 1;
            s.received = 0;
            s.alloc = alloc;
            surfaces.put(id, s);
            decoded.remove(id);
        }
        for (int i = 0; i < pageCount; i++) {
            long pa = (b.getLong(40 + i * 8));
            if (pa != 0 && (!ram.contains(pa) || (pa & 0x3fff) != 0)) {
                if (rejectLogs < 8) {
                    rejectLogs++;
                    Log.w(TAG, "map reject id=" + id + " page " + (pageIndex + i)
                            + " pa=0x" + Long.toHexString(pa));
                }
                return;
            }
            if (s.pages[pageIndex + i] == 0) {
                s.received++;
            }
            s.pages[pageIndex + i] = pa;
        }
        if (mapLogs < 8) {
            mapLogs++;
            Log.i(TAG, "map id=" + id + " pages=" + total + " alloc=" + alloc
                    + " batch=" + pageIndex + "+" + pageCount + " first=0x"
                    + Long.toHexString(b.getLong(40)) + " p1=0x"
                    + Long.toHexString(b.getLong(48)) + " p2=0x"
                    + Long.toHexString(b.getLong(56)));
        }
    }

    void onTexture(ByteBuffer b) {
        int id = b.getInt(20);
        int width = b.getInt(24);
        int height = b.getInt(28);
        int bpr = b.getInt(32);
        int fmt = b.getInt(36);
        int chunk = b.getInt(72);
        int chunks = b.getInt(76);
        int total = b.getInt(80);
        int offset = HEADER_BYTES;
        int bytes = b.limit() - offset;
        if (bytes <= 0) {
            return;
        }
        if (total <= 0 || total > (2 << 20) || chunks <= 0 || chunk < 0
                || chunk >= chunks || width <= 0 || height <= 0 || width > 8192
                || height > 8192 || bpr <= 0 || bpr > (1 << 20)) {
            if (rejectLogs < 8) {
                rejectLogs++;
                Log.w(TAG, "texture reject id=" + id + " " + width + "x" + height
                        + " bpr=" + bpr + " fmt=" + fmt + " total=" + total
                        + " chunk=" + chunk + "/" + chunks + " bytes=" + bytes);
            }
            return;
        }
        Upload u = uploads.get(id);
        if (u == null || u.expect != total || chunk == 0) {
            u = new Upload();
            u.data = new byte[total];
            u.expect = total;
            u.got = 0;
            u.width = width;
            u.height = height;
            u.bpr = bpr;
            u.texFmt = fmt;
            u.ready = false;
            uploads.put(id, u);
            decoded.remove(id);
        }
        int at = chunk * UPLOAD_CHUNK;
        int copy = Math.min(bytes, total - at);
        if (copy <= 0) {
            return;
        }
        System.arraycopy(b.array(), b.arrayOffset() + offset, u.data, at, copy);
        u.got += copy;
        if (u.got >= u.expect) {
            u.ready = true;
            if (uploadLogs < 8) {
                uploadLogs++;
                Log.i(TAG, "upload " + id + " " + width + "x" + height
                        + " bpr=" + bpr + " fmt=" + fmt + " bytes=" + total);
            }
        }
    }

    void onFlush() {
        if (disabled()) {
            return;
        }
        long now = System.nanoTime();
        if (frameDraws > 0 && (frame <= 8 || (frame & 63) == 0)) {
            Log.i(TAG, "frame " + frame + " draws=" + frameDraws + " px=" + framePixels
                    + " ms=" + ((now - frameStart) / 1000000L) + " decodes=" + decodeCount
                    + " maps=" + surfaces.size() + " uploads=" + uploads.size()
                    + " dropped=" + dropped);
        }
        frame++;
        frameDraws = 0;
        framePixels = 0;
        frameStart = now;
        decoded.clear();
    }

    /* ---- draws ----------------------------------------------------------- */

    void onDraw(byte[] payload) {
        if (disabled()) {
            return;
        }
        ByteBuffer b = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);
        int flags = b.getInt(0);
        if ((flags & F_TEX_CHUNK) != 0) {
            onTexture(b);
            return;
        }
        int dstId = b.getInt(4);
        int dstW = b.getInt(8);
        int dstH = b.getInt(12);
        int dstBpr = b.getInt(16);
        int texId = b.getInt(20);
        int texW = b.getInt(24);
        int texH = b.getInt(28);
        int texBpr = b.getInt(32);
        int texFmt = b.getInt(36);
        int clipX0 = b.getInt(40);
        int clipY0 = b.getInt(44);
        int clipX1 = b.getInt(48);
        int clipY1 = b.getInt(52);
        int blend = b.getInt(56);
        int triCount = b.getInt(60);
        if (drawLogs < 12 && payload.length >= HEADER_BYTES) {
            drawLogs++;
            Log.i(TAG, "draw flags=0x" + Integer.toHexString(flags) + " len="
                    + payload.length + " dst=" + dstId + " " + dstW + "x" + dstH
                    + " bpr=" + dstBpr + " tex=" + texId + " " + texW + "x" + texH
                    + " tris=" + triCount + " b80=" + b.getInt(80));
        }

        Surface dst = surfaces.get(dstId);
        if (dst == null || !dst.ready()) {
            dropped++;
            return;
        }
        dst.width = dstW;
        dst.height = dstH;
        dst.bpr = dstBpr;
        if (dstBpr < dstW * 4 || (dst.alloc > 0 && (long) dstBpr * dstH > dst.alloc)) {
            dropped++;
            return;
        }
        int x0 = Math.max(0, clipX0);
        int y0 = Math.max(0, clipY0);
        int x1 = Math.min(dstW, clipX1);
        int y1 = Math.min(dstH, clipY1);
        if (x1 <= x0 || y1 <= y0) {
            return;
        }
        boolean textured = (flags & F_TEXTURED) != 0;
        Decoded tex = null;
        if (textured) {
            tex = texture(flags, texId, texW, texH, texBpr, texFmt);
            if (tex == null) {
                dropped++;
                return;
            }
        }
        long start = System.nanoTime();
        int offset = HEADER_BYTES;
        for (int t = 0; t < triCount; t++) {
            float ax = b.getFloat(offset);
            float ay = b.getFloat(offset + 4);
            float au = b.getFloat(offset + 8);
            float av = b.getFloat(offset + 12);
            float ar = b.getFloat(offset + 16);
            float ag = b.getFloat(offset + 20);
            float ab = b.getFloat(offset + 24);
            float aa = b.getFloat(offset + 28);
            float bx = b.getFloat(offset + 32);
            float by = b.getFloat(offset + 36);
            float bu = b.getFloat(offset + 40);
            float bv = b.getFloat(offset + 44);
            float br = b.getFloat(offset + 48);
            float bg = b.getFloat(offset + 52);
            float bb = b.getFloat(offset + 56);
            float ba = b.getFloat(offset + 60);
            float cx = b.getFloat(offset + 64);
            float cy = b.getFloat(offset + 68);
            float cu = b.getFloat(offset + 72);
            float cv = b.getFloat(offset + 76);
            float cr = b.getFloat(offset + 80);
            float cg = b.getFloat(offset + 84);
            float cb = b.getFloat(offset + 88);
            float ca = b.getFloat(offset + 92);
            offset += 3 * VERTEX_BYTES;
            long covered = triangle(dst, x0, y0, x1, y1, blend, tex, textured,
                    ax, ay, au, av, ar, ag, ab, aa,
                    bx, by, bu, bv, br, bg, bb, ba,
                    cx, cy, cu, cv, cr, cg, cb, ca);
            pixels += covered;
            framePixels += covered;
        }
        draws++;
        frameDraws++;
        long elapsed = System.nanoTime() - start;
        if (elapsed > 4000000L) {
            Log.i(TAG, "slow draw dst=" + dstId + " tris=" + triCount
                    + " ms=" + (elapsed / 1000000L));
        }
    }

    /* ---- texture decoding ------------------------------------------------ */

    private Decoded texture(int flags, int id, int width, int height, int bpr, int fmt) {
        Decoded cached = decoded.get(id);
        if (cached != null && cached.width == width && cached.height == height) {
            return cached;
        }
        if (width <= 0 || height <= 0 || bpr <= 0 || width > 8192 || height > 8192
                || (long) width * height > 4_000_000L) {
            return null;
        }
        int[] out = new int[width * height];
        boolean internal = (flags & F_INTERNAL) != 0;
        if ((flags & F_UPLOAD_TEX) != 0) {
            Upload u = uploads.get(id);
            if (u == null || !u.ready) {
                return null;
            }
            ByteBuffer src = ByteBuffer.wrap(u.data).order(ByteOrder.LITTLE_ENDIAN);
            for (int y = 0; y < height; y++) {
                decodeRow(src, (long) y * bpr, width, internal ? 4 : bpp(fmt), fmt,
                        internal, out, y * width);
            }
        } else {
            Surface s = surfaces.get(id);
            if (s == null || !s.ready()) {
                return null;
            }
            int bytesPerTexel = internal ? 4 : bpp(fmt);
            for (int y = 0; y < height; y++) {
                decodeSurfaceRow(s, (long) y * bpr, width, bytesPerTexel, fmt,
                        internal, out, y * width);
            }
        }
        Decoded d = new Decoded();
        d.pixels = out;
        d.width = width;
        d.height = height;
        decoded.put(id, d);
        decodeCount++;
        return d;
    }

    private void decodeSurfaceRow(Surface s, long rowOffset, int count, int bytesPerTexel,
            int fmt, boolean internal, int[] out, int outOffset) {
        int done = 0;
        while (done < count) {
            long offset = rowOffset + (long) done * bytesPerTexel;
            int page = (int) (offset >>> s.pageShift);
            if (page >= s.total) {
                return;
            }
            int within = (int) (offset & s.pageMask);
            int texels = Math.min(count - done, (s.pageSize - within) / bytesPerTexel);
            if (texels <= 0) {
                return;
            }
            long pa = s.pages[page] - GuestRam.BASE + within;
            ByteBuffer buf = ram.at(pa);
            int index = ram.index(pa);
            for (int i = 0; i < texels; i++, index += bytesPerTexel) {
                out[outOffset + done + i] = decode(buf, index, fmt, internal);
            }
            done += texels;
        }
    }

    private static void decodeRow(ByteBuffer src, long offset, int count, int bytesPerTexel,
            int fmt, boolean internal, int[] out, int outOffset) {
        int index = (int) offset;
        for (int i = 0; i < count; i++) {
            out[outOffset + i] = decode(src, index, fmt, internal);
            index += bytesPerTexel;
        }
    }

    private static int bpp(int fmt) {
        switch (fmt) {
            case 1: case 10: case 11: case 12: case 13: case 14:
                return 1;
            case 20: case 21: case 22: case 23: case 24: case 25:
            case 30: case 31: case 32: case 33: case 34:
                return 2;
            case 53: case 54: case 55:
            case 60: case 61: case 62: case 63: case 64: case 65:
            case 70: case 71: case 72: case 73: case 74:
            case 80: case 81:
            case 90: case 91: case 92: case 93:
            case 550: case 551: case 554: case 555:
                return 4;
            case 103: case 104: case 105:
            case 110: case 111: case 112: case 113: case 114: case 115:
            case 552: case 553:
                return 8;
            case 123: case 124: case 125:
                return 16;
            default:
                return 4;
        }
    }

    private static int pack(float r, float g, float b, float a) {
        int ri = r <= 0f ? 0 : r >= 1f ? 255 : (int) (r * 255f);
        int gi = g <= 0f ? 0 : g >= 1f ? 255 : (int) (g * 255f);
        int bi = b <= 0f ? 0 : b >= 1f ? 255 : (int) (b * 255f);
        int ai = a <= 0f ? 0 : a >= 1f ? 255 : (int) (a * 255f);
        return (ai << 24) | (ri << 16) | (gi << 8) | bi;
    }

    private static float half(int bits) {
        int sign = (bits >> 15) & 1;
        int expo = (bits >> 10) & 0x1f;
        int mant = bits & 0x3ff;
        float v;
        if (expo == 0) {
            v = mant * 5.9604644775390625e-8f;
        } else if (expo == 31) {
            v = 65504.0f;
        } else {
            int scaleBits = (expo - 15 + 127) << 23;
            v = (1.0f + mant / 1024.0f) * Float.intBitsToFloat(scaleBits);
        }
        return sign != 0 ? -v : v;
    }

    private static float xr10(int raw) {
        return raw * (2.003921568627451f / 1023.0f) - 0.7529411764705882f;
    }

    private static float xr16(int raw) {
        return raw * (2.003921568627451f / 65535.0f) - 0.7529411764705882f;
    }

    private static int decode(ByteBuffer b, int i, int fmt, boolean internal) {
        if (internal) {
            int p = b.getInt(i);
            int r = p & 0xff;
            int g = (p >> 8) & 0xff;
            int bl = (p >> 16) & 0xff;
            int a = (p >> 24) & 0xff;
            return (a << 24) | (r << 16) | (g << 8) | bl;
        }
        switch (fmt) {
            case 1:
            case 10:
                return ((b.get(i) & 0xff) << 24) | 0xffffff;
            case 20: {
                int v = b.getShort(i) & 0xffff;
                int g = v / 257;
                return 0xff000000 | (g << 16) | (g << 8) | g;
            }
            case 25: {
                float v = half(b.getShort(i) & 0xffff);
                return pack(v, v, v, 1f);
            }
            case 30:
            case 31: {
                int r = b.get(i) & 0xff;
                int g = b.get(i + 1) & 0xff;
                return 0xff000000 | (r << 16) | (g << 8);
            }
            case 55: {
                float v = b.getFloat(i);
                return pack(v, v, v, 1f);
            }
            case 70:
            case 71: {
                int r = b.get(i) & 0xff;
                int g = b.get(i + 1) & 0xff;
                int bl = b.get(i + 2) & 0xff;
                int a = b.get(i + 3) & 0xff;
                return (a << 24) | (r << 16) | (g << 8) | bl;
            }
            case 80:
            case 81: {
                int bl = b.get(i) & 0xff;
                int g = b.get(i + 1) & 0xff;
                int r = b.get(i + 2) & 0xff;
                int a = b.get(i + 3) & 0xff;
                return (a << 24) | (r << 16) | (g << 8) | bl;
            }
            case 110:
            case 111: {
                int r = (b.getShort(i) & 0xffff) / 257;
                int g = (b.getShort(i + 2) & 0xffff) / 257;
                int bl = (b.getShort(i + 4) & 0xffff) / 257;
                int a = (b.getShort(i + 6) & 0xffff) / 257;
                return (a << 24) | (r << 16) | (g << 8) | bl;
            }
            case 115: {
                float r = half(b.getShort(i) & 0xffff);
                float g = half(b.getShort(i + 2) & 0xffff);
                float bl = half(b.getShort(i + 4) & 0xffff);
                float a = half(b.getShort(i + 6) & 0xffff);
                return pack(r, g, bl, a);
            }
            case 550:
            case 551: {
                int raw = b.getInt(i);
                float r = xr10(raw & 0x3ff);
                float g = xr10((raw >> 10) & 0x3ff);
                float bl = xr10((raw >> 20) & 0x3ff);
                return pack(r, g, bl, 1f);
            }
            case 552:
            case 553: {
                float r = xr16(b.getShort(i) & 0xffff);
                float g = xr16(b.getShort(i + 2) & 0xffff);
                float bl = xr16(b.getShort(i + 4) & 0xffff);
                int a = (b.getShort(i + 6) & 0xffff) / 257;
                return (a << 24) | ((int) Math.min(255, Math.max(0, r * 255f)) << 16)
                        | ((int) Math.min(255, Math.max(0, g * 255f)) << 8)
                        | (int) Math.min(255, Math.max(0, bl * 255f));
            }
            case 105: {
                float r = b.getFloat(i);
                float g = b.getFloat(i + 4);
                return pack(r, g, 0f, 1f);
            }
            default: {
                int bl = b.get(i) & 0xff;
                int g = b.get(i + 1) & 0xff;
                int r = b.get(i + 2) & 0xff;
                int a = b.get(i + 3) & 0xff;
                return (a << 24) | (r << 16) | (g << 8) | bl;
            }
        }
    }

    /* ---- rasterizer ------------------------------------------------------ */

    private static float edge(float ax, float ay, float bx, float by, float px, float py) {
        return (px - ax) * (by - ay) - (py - ay) * (bx - ax);
    }

    private static boolean topLeft(float dx, float dy) {
        return dy > 0f || (dy == 0f && dx < 0f);
    }

    private long triangle(Surface dst, int clipX0, int clipY0, int clipX1, int clipY1,
            int blend, Decoded tex, boolean textured,
            float ax, float ay, float au, float av, float ar, float ag, float ab, float aa,
            float bx, float by, float bu, float bv, float br, float bg, float bb, float ba,
            float cx, float cy, float cu, float cv, float cr, float cg, float cb, float ca) {
        float area = edge(ax, ay, bx, by, cx, cy);
        if (area == 0f) {
            return 0;
        }
        float minxf = Math.min(ax, Math.min(bx, cx));
        float maxxf = Math.max(ax, Math.max(bx, cx));
        float minyf = Math.min(ay, Math.min(by, cy));
        float maxyf = Math.max(ay, Math.max(by, cy));
        int minx = Math.max(clipX0, (int) Math.floor(minxf));
        int maxx = Math.min(clipX1, (int) Math.ceil(maxxf));
        int miny = Math.max(clipY0, (int) Math.floor(minyf));
        int maxy = Math.min(clipY1, (int) Math.ceil(maxyf));
        if (minx >= maxx || miny >= maxy) {
            return 0;
        }
        float inv = 1f / area;
        boolean positive = area > 0f;
        /* Edge e(a,b,p) is linear in p: stepping x by one adds (by-ay). */
        float d0x = cy - by;
        float d1x = ay - cy;
        float d2x = by - ay;
        boolean tl0 = topLeft(cx - bx, cy - by);
        boolean tl1 = topLeft(ax - cx, ay - cy);
        boolean tl2 = topLeft(bx - ax, by - ay);
        boolean solid = !textured && ar == br && ar == cr && ag == bg && ag == cg
                && ab == bb && ab == cb && aa == ba && aa == ca;
        float sr = 0f, sg = 0f, sb = 0f, sa = 0f;
        if (solid) {
            sa = Math.min(1f, Math.max(0f, aa));
            sr = ar * sa;
            sg = ag * sa;
            sb = ab * sa;
            if (sa <= 0f) {
                return 0;
            }
        }
        long covered = 0;
        int tw = tex != null ? tex.width : 0;
        int th = tex != null ? tex.height : 0;
        int[] tp = tex != null ? tex.pixels : null;
        boolean texturePixels = textured && !(au == bu && au == cu && av == bv && av == cv);
        for (int y = miny; y < maxy; y++) {
            float py = y + 0.5f;
            float e0 = edge(bx, by, cx, cy, minx + 0.5f, py);
            float e1 = edge(cx, cy, ax, ay, minx + 0.5f, py);
            float e2 = edge(ax, ay, bx, by, minx + 0.5f, py);
            long rowOffset = (long) y * dst.bpr;
            int x = minx;
            while (x < maxx) {
                long pixelOffset = rowOffset + (long) x * 4;
                if (dst.alloc > 0 && pixelOffset + 4 > dst.alloc) {
                    break;
                }
                int page = (int) (pixelOffset >>> dst.pageShift);
                if (page >= dst.total) {
                    break;
                }
                int within = (int) (pixelOffset & dst.pageMask);
                int span = Math.min(maxx - x, (dst.pageSize - within) / 4);
                if (span <= 0) {
                    break;
                }
                long pa = dst.pages[page] - GuestRam.BASE + within;
                ByteBuffer buf = ram.at(pa);
                int index = ram.index(pa);
                for (int i = 0; i < span; i++, x++, index += 4) {
                    boolean in;
                    if (positive) {
                        in = (e0 > 0f || (e0 == 0f && tl0))
                                && (e1 > 0f || (e1 == 0f && tl1))
                                && (e2 > 0f || (e2 == 0f && tl2));
                    } else {
                        in = (e0 < 0f || (e0 == 0f && !tl0))
                                && (e1 < 0f || (e1 == 0f && !tl1))
                                && (e2 < 0f || (e2 == 0f && !tl2));
                    }
                    if (in) {
                        float w0 = e0 * inv;
                        float w1 = e1 * inv;
                        float w2 = e2 * inv;
                        float colR, colG, colB, colA;
                        if (solid) {
                            colR = sr;
                            colG = sg;
                            colB = sb;
                            colA = sa;
                        } else {
                            colR = ar * w0 + br * w1 + cr * w2;
                            colG = ag * w0 + bg * w1 + cg * w2;
                            colB = ab * w0 + bb * w1 + cb * w2;
                            colA = aa * w0 + ba * w1 + ca * w2;
                            if (textured) {
                                float u, v;
                                if (texturePixels) {
                                    u = au * w0 + bu * w1 + cu * w2;
                                    v = av * w0 + bv * w1 + cv * w2;
                                } else {
                                    u = au;
                                    v = av;
                                }
                                sample(tp, tw, th, u, v, SAMPLE);
                                colR *= SAMPLE[0];
                                colG *= SAMPLE[1];
                                colB *= SAMPLE[2];
                                colA *= SAMPLE[3];
                            }
                            colA = colA > 1f ? 1f : colA < 0f ? 0f : colA;
                            colR *= colA;
                            colG *= colA;
                            colB *= colA;
                        }
                        int dstPixel = buf.getInt(index);
                        float dr = (dstPixel & 0xff) / 255f;
                        float dg = ((dstPixel >> 8) & 0xff) / 255f;
                        float db = ((dstPixel >> 16) & 0xff) / 255f;
                        float da = ((dstPixel >> 24) & 0xff) / 255f;
                        float invA = 1f - colA;
                        float orr = colR + dr * invA;
                        float og = colG + dg * invA;
                        float ob = colB + db * invA;
                        float oa = colA + da * invA;
                        if (blend == 46) {
                            float l = 0.299f * dr + 0.587f * dg + 0.114f * db;
                            l = l < 0f ? 0f : l > 1f ? 1f : l;
                            float l4 = l * l;
                            l4 *= l4;
                            float k = 1f - colA * l4;
                            orr = colR * l4 + dr * k;
                            og = colG * l4 + dg * k;
                            ob = colB * l4 + db * k;
                            oa = colA * l4 + da * k;
                        }
                        int out = ((int) (oa >= 1f ? 255 : oa * 255f) << 24)
                                | ((int) (orr >= 1f ? 255 : orr * 255f) << 16)
                                | ((int) (og >= 1f ? 255 : og * 255f) << 8)
                                | (int) (ob >= 1f ? 255 : ob * 255f);
                        buf.putInt(index, out);
                        covered++;                    }
                    e0 += d0x;
                    e1 += d1x;
                    e2 += d2x;
                }
                if (x >= maxx) {
                    break;
                }
            }
        }
        return covered;
    }

    private static final float[] SAMPLE = new float[4];

    private static void sample(int[] pixels, int w, int h, float u, float v, float[] out) {
        out[0] = out[1] = out[2] = out[3] = 1f;
        if (pixels == null || w <= 0 || h <= 0) {
            return;
        }
        if ((u > 1.5f || v > 1.5f) && u >= 0f && v >= 0f && u <= w + 0.5f && v <= h + 0.5f) {
            u /= w;
            v /= h;
        }
        if (u < 0f) u = 0f;
        if (v < 0f) v = 0f;
        if (u > 0.999999f) u = 0.999999f;
        if (v > 0.999999f) v = 0.999999f;
        float fx = u * w - 0.5f;
        float fy = v * h - 0.5f;
        int ix = (int) Math.floor(fx);
        int iy = (int) Math.floor(fy);
        float ax = fx - ix;
        float ay = fy - iy;
        int x0 = ix < 0 ? 0 : ix >= w ? w - 1 : ix;
        int x1 = ix + 1 < 0 ? 0 : ix + 1 >= w ? w - 1 : ix + 1;
        int y0 = iy < 0 ? 0 : iy >= h ? h - 1 : iy;
        int y1 = iy + 1 < 0 ? 0 : iy + 1 >= h ? h - 1 : iy + 1;
        int p00 = pixels[y0 * w + x0];
        int p10 = pixels[y0 * w + x1];
        int p01 = pixels[y1 * w + x0];
        int p11 = pixels[y1 * w + x1];
        float w00 = (1f - ax) * (1f - ay);
        float w10 = ax * (1f - ay);
        float w01 = (1f - ax) * ay;
        float w11 = ax * ay;
        out[0] = (((p00 >> 16) & 0xff) * w00 + ((p10 >> 16) & 0xff) * w10
                + ((p01 >> 16) & 0xff) * w01 + ((p11 >> 16) & 0xff) * w11) / 255f;
        out[1] = (((p00 >> 8) & 0xff) * w00 + ((p10 >> 8) & 0xff) * w10
                + ((p01 >> 8) & 0xff) * w01 + ((p11 >> 8) & 0xff) * w11) / 255f;
        out[2] = ((p00 & 0xff) * w00 + (p10 & 0xff) * w10
                + (p01 & 0xff) * w01 + (p11 & 0xff) * w11) / 255f;
        out[3] = (((p00 >>> 24)) * w00 + ((p10 >>> 24)) * w10
                + ((p01 >>> 24)) * w01 + ((p11 >>> 24)) * w11) / 255f;
    }
}
