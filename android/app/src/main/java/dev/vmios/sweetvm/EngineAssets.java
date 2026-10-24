package dev.vmios.sweetvm;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.res.AssetManager;
import android.os.Build;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/**
 * The QEMU build and its original Termux libraries are shipped as assets and
 * extracted next to each other.  They keep their original SONAMEs: rewriting
 * them with patchelf corrupts the dynamic string table enough that Android's
 * linker segfaults in prelink_image().  targetSdk 28 keeps the classic
 * exec-from-app-data path usable, so nothing has to live in jniLibs.
 */
public final class EngineAssets {
    public static final class Engine {
        public final File dir;
        public final File qemu;
        public final String version;
        Engine(File dir, File qemu, String version) {
            this.dir = dir;
            this.qemu = qemu;
            this.version = version;
        }
    }

    private EngineAssets() {
    }

    public static Engine ensure(Context ctx) throws IOException {
        String abi = supportedAbi();
        File dir = new File(ctx.getFilesDir(), "engine-" + abi);
        String version = currentVersion(ctx);
        File marker = new File(dir, ".version");
        if (!marker.isFile() || !version.equals(readSmall(marker))) {
            deleteTree(dir);
            if (!dir.mkdirs()) {
                throw new IOException("无法创建引擎目录");
            }
            copyAssets(ctx.getAssets(), "engine/" + abi, dir);
            try (FileOutputStream out = new FileOutputStream(marker)) {
                out.write(version.getBytes(StandardCharsets.US_ASCII));
            }
        }
        File qemu = new File(dir, "qemu-system-aarch64");
        if (!qemu.isFile()) {
            throw new IOException("引擎缺少 qemu-system-aarch64");
        }
        if (!qemu.setExecutable(true)) {
            throw new IOException("无法给 QEMU 设置执行权限");
        }
        return new Engine(dir, qemu, version);
    }

    /** Identifies the extracted engine; snapshots are only valid for the same one. */
    public static String currentVersion(Context ctx) throws IOException {
        return engineVersion(ctx) + "-" + supportedAbi();
    }

    public static String supportedAbi() throws IOException {
        String[] abis = Build.SUPPORTED_ABIS;
        for (String a : abis) {
            if ("arm64-v8a".equals(a) || "x86_64".equals(a)) {
                return a;
            }
        }
        throw new IOException("需要 64 位 ARM 或 x86 设备，当前 ABI: "
                + String.join(",", abis));
    }

    private static String engineVersion(Context ctx) {
        try {
            PackageInfo pi = ctx.getPackageManager()
                    .getPackageInfo(ctx.getPackageName(), 0);
            return pi.versionCode + "-" + pi.lastUpdateTime;
        } catch (PackageManager.NameNotFoundException e) {
            return "?";
        }
    }

    private static void copyAssets(AssetManager am, String path, File dir) throws IOException {
        String[] names = am.list(path);
        if (names == null || names.length == 0) {
            throw new IOException("APK 中没有 " + path);
        }
        byte[] buf = new byte[1 << 20];
        for (String name : names) {
            File out = new File(dir, name);
            try (InputStream in = am.open(path + "/" + name);
                 FileOutputStream os = new FileOutputStream(out)) {
                int n;
                while ((n = in.read(buf)) > 0) {
                    os.write(buf, 0, n);
                }
            }
        }
    }

    private static String readSmall(File f) {
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] b = new byte[64];
            int n = in.read(b);
            return n <= 0 ? "" : new String(b, 0, n, StandardCharsets.US_ASCII).trim();
        } catch (IOException e) {
            return "";
        }
    }

    private static void deleteTree(File f) {
        if (!f.exists()) {
            return;
        }
        if (f.isDirectory()) {
            File[] kids = f.listFiles();
            if (kids != null) {
                for (File k : kids) {
                    deleteTree(k);
                }
            }
        }
        // File.delete() is enough here: these are our own extracted files.
        f.delete();
    }
}
