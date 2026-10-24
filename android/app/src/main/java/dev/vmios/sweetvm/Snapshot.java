package dev.hackios.sweetvm;

import android.content.Context;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/**
 * A paused VM image written by QEMU's file: migration transport.  Saving takes
 * the 3 GB guest RAM plus device state (~1 GB after zero-page skipping), and
 * restoring with -incoming skips the ten-to-twenty-minute TCG boot.
 */
public final class Snapshot {
    private static final String STATE = "snapshot.vmstate";
    private static final String META = "snapshot.json";

    private Snapshot() {
    }

    public static File stateFile(Context ctx) {
        return new File(new File(ctx.getFilesDir(), "vm"), STATE);
    }

    private static File metaFile(Context ctx) {
        return new File(new File(ctx.getFilesDir(), "vm"), META);
    }

    /** The state is only valid for the exact payload/root/cmdline/engine it was saved with. */
    public static boolean isUsable(Context ctx, File payload, File root,
                                   String cmdline, String engineVersion) {
        File state = stateFile(ctx);
        File meta = metaFile(ctx);
        if (!state.isFile() || state.length() < (64L << 20)
                || payload == null || !payload.isFile()
                || root == null || !root.isFile()) {
            return false;
        }
        try {
            JSONObject m = new JSONObject(read(meta));
            return m.getLong("payload_len") == payload.length()
                    && m.getLong("payload_mtime") == payload.lastModified()
                    && m.getLong("root_len") == root.length()
                    && m.getLong("root_mtime") == root.lastModified()
                    && engineVersion.equals(m.optString("engine"))
                    && cmdline.equals(m.optString("cmdline"));
        } catch (Exception e) {
            return false;
        }
    }

    public static void writeMeta(Context ctx, File payload, File root,
                                 String cmdline, String engineVersion) throws IOException {
        JSONObject m = new JSONObject();
        try {
            m.put("payload_len", payload.length());
            m.put("payload_mtime", payload.lastModified());
            m.put("root_len", root.length());
            m.put("root_mtime", root.lastModified());
            m.put("engine", engineVersion);
            m.put("cmdline", cmdline);
            m.put("saved_at", System.currentTimeMillis());
        } catch (Exception e) {
            throw new IOException(e.getMessage() == null ? "无法写入快照信息" : e.getMessage());
        }
        write(metaFile(ctx), m.toString());
    }

    public static void invalidate(Context ctx) {
        stateFile(ctx).delete();
        metaFile(ctx).delete();
    }

    /**
     * Stops the guest and migrates its state to {@code state}.  Must run off the
     * UI thread; QEMU quits itself once the migration completes.
     */
    public static void save(File qmpSock, File state) throws Exception {
        state.delete();
        LocalSocket s = new LocalSocket();
        try {
            s.connect(new LocalSocketAddress(qmpSock.getAbsolutePath(),
                    LocalSocketAddress.Namespace.FILESYSTEM));
            BufferedReader in = new BufferedReader(new InputStreamReader(
                    s.getInputStream(), StandardCharsets.UTF_8));
            OutputStream out = s.getOutputStream();
            in.readLine();
            qmp(out, in, "{\"execute\":\"qmp_capabilities\"}");
            qmp(out, in, "{\"execute\":\"stop\"}");
            qmp(out, in, "{\"execute\":\"migrate\",\"arguments\":{\"uri\":"
                    + JSONObject.quote("file:" + state.getAbsolutePath())
                    + ",\"blk\":false,\"inc\":false}}");
            long deadline = System.currentTimeMillis() + 300_000;
            String last = "";
            while (System.currentTimeMillis() < deadline) {
                String r = qmp(out, in, "{\"execute\":\"query-migrate\"}");
                JSONObject o = new JSONObject(r);
                if (o.has("error")) {
                    throw new IOException(o.getJSONObject("error")
                            .optString("desc", "QMP 错误"));
                }
                JSONObject ret = o.optJSONObject("return");
                String st = ret == null ? "" : ret.optString("status");
                last = st;
                if ("completed".equals(st)) {
                    try {
                        qmp(out, in, "{\"execute\":\"quit\"}");
                    } catch (IOException ignored) {
                    }
                    return;
                }
                if ("failed".equals(st) || "cancelled".equals(st)) {
                    throw new IOException("迁移状态为 " + st);
                }
                Thread.sleep(400);
            }
            throw new IOException("超时（" + last + "）");
        } finally {
            try {
                s.close();
            } catch (IOException ignored) {
            }
        }
    }

    private static String qmp(OutputStream out, BufferedReader in, String cmd)
            throws IOException {
        out.write((cmd + "\n").getBytes(StandardCharsets.UTF_8));
        out.flush();
        long deadline = System.currentTimeMillis() + 15_000;
        while (System.currentTimeMillis() < deadline) {
            String line = in.readLine();
            if (line == null) {
                throw new IOException("QMP 连接已关闭");
            }
            line = line.trim();
            if (!line.startsWith("{")) {
                continue;
            }
            JSONObject o;
            try {
                o = new JSONObject(line);
            } catch (Exception e) {
                continue;
            }
            if (o.has("return") || o.has("error")) {
                return line;
            }
        }
        throw new IOException("QMP 响应超时");
    }

    private static String read(File f) throws IOException {
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] b = new byte[(int) f.length()];
            int n = in.read(b);
            return new String(b, 0, Math.max(n, 0), StandardCharsets.UTF_8);
        }
    }

    private static void write(File f, String s) throws IOException {
        try (FileOutputStream out = new FileOutputStream(f)) {
            out.write(s.getBytes(StandardCharsets.UTF_8));
        }
    }
}
