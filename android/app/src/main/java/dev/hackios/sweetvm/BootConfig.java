package dev.hackios.sweetvm;

import android.content.Context;
import android.content.SharedPreferences;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;

/** Small persisted configuration and file helpers. */
public final class BootConfig {
    private static final String PREFS = "sweetvm";
    private static final String KEY_ROOT = "root";
    private static final String KEY_PAYLOAD = "payload";
    private static final String KEY_CMDLINE = "cmdline";
    private static final String KEY_FPS = "fps";

    public String rootPath = "";
    public String payloadPath = "";
    public String cmdline = "";
    public int fps = 4;

    public static BootConfig load(Context ctx) {
        SharedPreferences p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        BootConfig c = new BootConfig();
        c.rootPath = p.getString(KEY_ROOT, "");
        c.payloadPath = p.getString(KEY_PAYLOAD, "");
        c.cmdline = p.getString(KEY_CMDLINE, "");
        c.fps = p.getInt(KEY_FPS, 4);
        return c;
    }

    public void save(Context ctx) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString(KEY_ROOT, rootPath)
                .putString(KEY_PAYLOAD, payloadPath)
                .putString(KEY_CMDLINE, cmdline)
                .putInt(KEY_FPS, fps)
                .apply();
    }

    public File rootFile() {
        return rootPath.isEmpty() ? null : new File(rootPath);
    }

    public File payloadFile() {
        return payloadPath.isEmpty() ? null : new File(payloadPath);
    }

    public static File externalDir(Context ctx) {
        File d = ctx.getExternalFilesDir(null);
        if (d == null) {
            d = ctx.getFilesDir();
        }
        if (!d.exists()) {
            d.mkdirs();
        }
        return d;
    }

    public static File defaultRoot(Context ctx) {
        File ext = new File(externalDir(ctx), "ios16-root.img");
        return ext.isFile() ? ext : new File(ctx.getFilesDir(), "ios16-root.img");
    }

    public static File defaultPayload(Context ctx) {
        File ext = new File(externalDir(ctx), "payload.bin");
        return ext.isFile() ? ext : new File(ctx.getFilesDir(), "payload.bin");
    }

    /** Copy the bundled test payload (no Apple bits) and return it. */
    public static File demoPayload(Context ctx) throws IOException {
        File f = new File(ctx.getFilesDir(), "demo/payload.bin");
        if (f.isFile() && f.length() > 1024) {
            return f;
        }
        File dir = f.getParentFile();
        if (dir != null) {
            dir.mkdirs();
        }
        try (InputStream in = ctx.getAssets().open("demo/payload.bin");
             FileOutputStream out = new FileOutputStream(f)) {
            copy(in, out, null);
        }
        return f;
    }

    public static boolean looksLikePayload(File f) {
        if (f == null || !f.isFile() || f.length() < 0x2a8) {
            return false;
        }
        byte[] m = new byte[8];
        try (FileInputStream in = new FileInputStream(f)) {
            int n = in.read(m);
            return n == 8 && "SWEETXNU".equals(new String(m, java.nio.charset.StandardCharsets.US_ASCII));
        } catch (IOException e) {
            return false;
        }
    }

    public static boolean looksLikeHfs(File f) {
        if (f == null || !f.isFile() || f.length() < 2048) {
            return false;
        }
        byte[] b = new byte[2];
        try (FileInputStream in = new FileInputStream(f)) {
            long skip = in.skip(1024);
            if (skip != 1024) {
                return false;
            }
            int n = in.read(b);
            return n == 2 && b[0] == 0x48 && (b[1] == 0x2b || b[1] == 0x58);
        } catch (IOException e) {
            return false;
        }
    }

    public static String human(long bytes) {
        if (bytes < 1024) {
            return bytes + " B";
        }
        double v = bytes;
        String[] u = {"B", "KB", "MB", "GB", "TB"};
        int i = 0;
        while (v >= 1024 && i < u.length - 1) {
            v /= 1024;
            i++;
        }
        return String.format(java.util.Locale.US, v >= 100 ? "%.0f %s" : "%.1f %s", v, u[i]);
    }

    public static String shortPath(File f) {
        if (f == null) {
            return "未选择";
        }
        return f.getName() + " · " + human(f.length());
    }

    public interface Progress {
        void update(long copied, long total);
        boolean cancelled();
    }

    public static void copy(InputStream in, FileOutputStream out, Progress p) throws IOException {
        byte[] buf = new byte[1 << 20];
        long done = 0;
        int n;
        while ((n = in.read(buf)) > 0) {
            out.write(buf, 0, n);
            done += n;
            if (p != null) {
                p.update(done, -1);
                if (p.cancelled()) {
                    throw new IOException("已取消");
                }
            }
        }
    }
}
