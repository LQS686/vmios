package dev.hackios.sweetvm;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.res.ColorStateList;
import android.database.Cursor;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.OpenableColumns;
import android.text.InputType;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.Space;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicBoolean;

public final class MainActivity extends Activity {
    private static final int REQ_ROOT = 100;
    private static final int REQ_PAYLOAD = 101;

    private static final int BG = 0xFF08080C;
    private static final int SURFACE = 0xFF14141B;
    private static final int SURFACE_2 = 0xFF1D1D26;
    private static final int TEXT = 0xFFF5F5F7;
    private static final int DIM = 0xFF9898A6;
    private static final int ACCENT = 0xFF0A84FF;
    private static final int GOOD = 0xFF30D158;
    private static final int BAD = 0xFFFF453A;
    private static final int WARN = 0xFFFF9F0A;
    private static final int STROKE = 0xFF262631;

    private BootConfig cfg;
    private VmEngine engine;
    private PowerManager.WakeLock wake;
    private final Handler ui = new Handler(Looper.getMainLooper());

    private FrameLayout rootView;
    private FrameLayout vmScreen;
    private FramebufferView fbView;
    private TouchSender touch;
    private TextView vmStatus;
    private TextView vmTimer;
    private TextView vmHint;
    private LinearLayout vmTop;
    private TextView vmPill;
    private boolean vmActive;
    private boolean vmStopping;
    private String lastCmdline = "";
    private long vmStartedAt;
    private long lastFrames;
    private long lastFrameTime;
    private boolean controlsVisible = true;

    private final Runnable hideControls = () -> {
        if (!vmActive || vmTop == null) {
            return;
        }
        controlsVisible = false;
        vmTop.animate().alpha(0f).setDuration(220).start();
        if (vmPill != null) {
            vmPill.animate().alpha(0f).setDuration(220).start();
        }
    };

    private final Runnable ticker = new Runnable() {
        @Override
        public void run() {
            if (!vmActive) {
                return;
            }
            long now = System.currentTimeMillis();
            long s = Math.max(0, (now - vmStartedAt) / 1000);
            long f = engine.frames();
            long df = f - lastFrames;
            long dt = Math.max(1, now - lastFrameTime);
            long fps = df * 1000 / dt;
            lastFrames = f;
            lastFrameTime = now;
            if (vmTimer != null) {
                vmTimer.setText(String.format(Locale.US, "%02d:%02d · %d fps", s / 60, s % 60, fps));
            }
            if (s % 5 == 0) {
                long copies = engine.frames();
                long avgUs = copies > 0 ? engine.copyNanos() / copies / 1000 : 0;
                android.util.Log.i("sweetvm", "fps=" + fps + " ticks=" + engine.ticks()
                        + " copies=" + copies + " copy_avg_us=" + avgUs
                        + " copy_max_us=" + engine.copyMaxNanos() / 1000 + " uptime=" + s);
            }
            if (vmStatus != null) {
                vmStatus.setText(engine.isRunning() ? "运行中 · 软件 CPU" : "正在停止…");
            }
            if (vmHint != null && fbView != null && fbView.hasFrame()) {
                vmHint.setVisibility(View.GONE);
            }
            ui.postDelayed(this, 1000);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setStatusBarColor(Color.TRANSPARENT);
        getWindow().setNavigationBarColor(BG);
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN);
        cfg = BootConfig.load(this);
        engine = new VmEngine(this);
        rootView = new FrameLayout(this);
        rootView.setBackgroundColor(BG);
        setContentView(rootView);
        adoptExistingFiles();
        showHome();
    }

    private void adoptExistingFiles() {
        File root = BootConfig.defaultRoot(this);
        File payload = BootConfig.defaultPayload(this);
        if (!cfg.rootPath.isEmpty()) {
            File f = new File(cfg.rootPath);
            if (!f.isFile()) {
                cfg.rootPath = "";
            }
        }
        if (!cfg.payloadPath.isEmpty()) {
            File f = new File(cfg.payloadPath);
            if (!f.isFile()) {
                cfg.payloadPath = "";
            }
        }
        if (cfg.rootPath.isEmpty() && root.isFile()) {
            cfg.rootPath = root.getAbsolutePath();
        }
        if (cfg.payloadPath.isEmpty() && payload.isFile()) {
            cfg.payloadPath = payload.getAbsolutePath();
        }
        cfg.save(this);
    }

    private int insetTop() {
        if (Build.VERSION.SDK_INT >= 23) {
            android.view.WindowInsets i = getWindow().getDecorView().getRootWindowInsets();
            if (i != null) {
                return i.getSystemWindowInsetTop();
            }
        }
        return 0;
    }

    private void setVmSystemBars(boolean vm) {
        int flags = View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN;
        if (vm) {
            flags |= View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    | View.SYSTEM_UI_FLAG_FULLSCREEN
                    | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION;
        }
        getWindow().getDecorView().setSystemUiVisibility(flags);
        if (Build.VERSION.SDK_INT >= 30) {
            android.view.WindowInsetsController c = getWindow().getInsetsController();
            if (c != null) {
                if (vm) {
                    c.hide(android.view.WindowInsets.Type.statusBars()
                            | android.view.WindowInsets.Type.navigationBars());
                    c.setSystemBarsBehavior(android.view.WindowInsetsController
                            .BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
                } else {
                    c.show(android.view.WindowInsets.Type.statusBars()
                            | android.view.WindowInsets.Type.navigationBars());
                }
            }
        }
    }

    private int statusBarHeight() {
        int id = getResources().getIdentifier("status_bar_height", "dimen", "android");
        int h = id > 0 ? getResources().getDimensionPixelSize(id) : dp(24);
        return Math.max(h, insetTop());
    }

    private int navBarHeight() {
        int id = getResources().getIdentifier("navigation_bar_height", "dimen", "android");
        int h = id > 0 ? getResources().getDimensionPixelSize(id) : dp(16);
        return Math.max(h, insetBottom());
    }

    private int insetBottom() {
        if (Build.VERSION.SDK_INT >= 23) {
            android.view.WindowInsets i = getWindow().getDecorView().getRootWindowInsets();
            if (i != null) {
                return i.getSystemWindowInsetBottom();
            }
        }
        return 0;
    }

    private int dp(float v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }

    private int sp(float v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, v,
                getResources().getDisplayMetrics());
    }

    private TextView text(String s, float size, int color, boolean bold) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, size);
        t.setTextColor(color);
        t.setTypeface(Typeface.create(bold ? "sans-serif-medium" : "sans-serif",
                bold ? Typeface.BOLD : Typeface.NORMAL));
        t.setLineSpacing(0, 1.18f);
        return t;
    }

    private GradientDrawable round(int color, float radiusDp) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(color);
        d.setCornerRadius(dp(radiusDp));
        return d;
    }

    private GradientDrawable outline(int color, int strokeColor, float radiusDp, int strokeDp) {
        GradientDrawable d = round(color, radiusDp);
        d.setStroke(dp(strokeDp), strokeColor);
        return d;
    }

    private LinearLayout card() {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setPadding(dp(18), dp(16), dp(18), dp(16));
        c.setBackground(outline(SURFACE, STROKE, 20, 1));
        return c;
    }

    private TextView action(String label, boolean primary, View.OnClickListener l) {
        TextView b = text(label, 15, primary ? Color.WHITE : TEXT, true);
        b.setGravity(Gravity.CENTER);
        b.setPadding(dp(16), dp(15), dp(16), dp(15));
        b.setBackground(primary ? round(ACCENT, 15) : outline(SURFACE_2, STROKE, 15, 1));
        b.setClickable(true);
        b.setFocusable(true);
        b.setOnClickListener(l);
        return b;
    }

    private Space gap(int dp) {
        Space s = new Space(this);
        s.setLayoutParams(new LinearLayout.LayoutParams(1, dp(dp)));
        return s;
    }

    private void clearRoot() {
        rootView.removeAllViews();
        vmScreen = null;
        fbView = null;
        vmStatus = null;
        vmTimer = null;
        vmHint = null;
        vmTop = null;
        vmPill = null;
    }

    private void showHome() {
        vmActive = false;
        ui.removeCallbacks(ticker);
        ui.removeCallbacks(hideControls);
        if (touch != null) {
            touch.close();
            touch = null;
        }
        releaseWake();
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        setVmSystemBars(false);
        clearRoot();

        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setClipToPadding(false);
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setPadding(dp(20), statusBarHeight() + dp(14), dp(20), navBarHeight() + dp(24));
        scroll.addView(c, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        rootView.addView(scroll, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        LinearLayout head = new LinearLayout(this);
        head.setOrientation(LinearLayout.HORIZONTAL);
        head.setGravity(Gravity.CENTER_VERTICAL);
        TextView logo = text("S", 26, Color.WHITE, true);
        logo.setGravity(Gravity.CENTER);
        logo.setBackground(round(ACCENT, 17));
        LinearLayout.LayoutParams logoLp = new LinearLayout.LayoutParams(dp(54), dp(54));
        logoLp.rightMargin = dp(14);
        head.addView(logo, logoLp);
        LinearLayout titles = new LinearLayout(this);
        titles.setOrientation(LinearLayout.VERTICAL);
        titles.addView(text("SweetVM", 29, TEXT, true));
        TextView sub = text("iOS 16 · XNU 虚拟机", 13, DIM, false);
        sub.setPadding(0, dp(2), 0, 0);
        titles.addView(sub);
        head.addView(titles);
        c.addView(head);
        c.addView(gap(22));

        File root = cfg.rootFile();
        File payload = cfg.payloadFile();
        boolean ready = root != null && root.isFile() && payload != null && payload.isFile();
        LinearLayout status = card();
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        TextView dot = text("●", 13, ready ? GOOD : WARN, false);
        row.addView(dot);
        TextView state = text(ready ? "配置就绪" : "还差一步", 15, TEXT, true);
        state.setPadding(dp(8), 0, 0, 0);
        row.addView(state);
        View spacer = new View(this);
        row.addView(spacer, new LinearLayout.LayoutParams(0, 1, 1));
        row.addView(text("QEMU · TCG", 11, DIM, false));
        status.addView(row);
        status.addView(gap(14));
        status.addView(infoRow("iOS 根镜像", root == null ? "未选择" :
                BootConfig.shortPath(root), root != null && BootConfig.looksLikeHfs(root)));
        status.addView(gap(10));
        status.addView(infoRow("内核 payload", payload == null ? "未选择" :
                BootConfig.shortPath(payload), payload != null && BootConfig.looksLikePayload(payload)));
        status.addView(gap(14));
        TextView note = text("根镜像与 3GB 客户机内存放在应用内部存储，QEMU 直接读写。"
                + "启动后可在“停止”里保存快照，下次秒开。", 11, DIM, false);
        status.addView(note);
        c.addView(status);
        c.addView(gap(14));

        c.addView(action(canResume() ? "快速启动 iOS（快照）" : "启动 iOS 虚拟机",
                true, v -> startIos()), wide());
        if (canResume()) {
            c.addView(gap(10));
            c.addView(action("冷启动 iOS（不使用快照）", false, v -> startIos(false)), wide());
        }
        c.addView(gap(10));
        c.addView(action("运行引擎自检（无需 iOS）", false, v -> startDemo()), wide());
        c.addView(gap(20));
        c.addView(sectionLabel("镜像与 payload"));
        c.addView(gap(8));
        c.addView(action("选择 iOS 根镜像（HFS+ raw）", false, v -> pick(REQ_ROOT)), wide());
        c.addView(gap(8));
        c.addView(action("选择内核 payload（SWEETXNU）", false, v -> pick(REQ_PAYLOAD)), wide());
        c.addView(gap(20));
        c.addView(sectionLabel("调试"));
        c.addView(gap(8));
        LinearLayout debug = new LinearLayout(this);
        debug.setOrientation(LinearLayout.HORIZONTAL);
        TextView adv = action("高级启动参数", false, v -> showAdvanced());
        TextView logs = action("运行日志", false, v -> showLogs());
        LinearLayout.LayoutParams lp1 = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1);
        lp1.rightMargin = dp(5);
        LinearLayout.LayoutParams lp2 = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1);
        lp2.leftMargin = dp(5);
        debug.addView(adv, lp1);
        debug.addView(logs, lp2);
        c.addView(debug, wide());
        c.addView(gap(20));
        c.addView(sectionLabel("说明"));
        c.addView(gap(8));
        TextView legal = text(
                "这是一个实验性虚拟机：QEMU TCG 软件模拟 ARM64，没有 GPU 加速，启动和动画会很慢。\n\n"
                        + "App 不附带 Apple 的 iOS 系统文件。你需要自备 iPhone X iOS 16.7.16 IPSW，"
                        + "在 Linux/macOS 上用 tools/mkiosroot.sh 生成 HFS+ 根镜像；payload 用 "
                        + "tools/mkadt.py --qemu 和 tools/mkpayload.py 构建。\n\n"
                        + "首次启动建议先跑“引擎自检”，确认显示链路正常。\n\n"
                        + "触摸已通过 sweet-touch（GENI SE7 + GT9896）接入；电源/音量键尚未接入。",
                12, DIM, false);
        legal.setLineSpacing(dp(3), 1.2f);
        c.addView(legal);
        c.addView(gap(10));
        TextView help = text("如何构建镜像和 payload？", 12, ACCENT, true);
        help.setPadding(0, dp(6), 0, dp(6));
        help.setOnClickListener(v -> showHelp());
        c.addView(help);
    }

    private LinearLayout.LayoutParams wide() {
        return new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
    }

    private View sectionLabel(String s) {
        TextView t = text(s, 12, DIM, true);
        t.setLetterSpacing(0.08f);
        return t;
    }

    private View infoRow(String label, String value, boolean ok) {
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        TextView a = text(label, 11, DIM, false);
        l.addView(a);
        TextView b = text(value, 14, TEXT, false);
        b.setPadding(0, dp(3), 0, 0);
        b.setTextIsSelectable(true);
        l.addView(b);
        if (!ok && !"未选择".equals(value)) {
            TextView w = text("格式未验证或文件缺失", 10, WARN, false);
            w.setPadding(0, dp(3), 0, 0);
            l.addView(w);
        }
        return l;
    }

    private void pick(int req) {
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType("*/*");
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try {
            startActivityForResult(i, req);
        } catch (Exception e) {
            toast("无法打开文件选择器: " + e.getMessage());
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (resultCode != RESULT_OK || data == null || data.getData() == null) {
            return;
        }
        if (requestCode == REQ_ROOT) {
            importFile(data.getData(), true);
        } else if (requestCode == REQ_PAYLOAD) {
            importFile(data.getData(), false);
        }
    }

    private void importFile(Uri uri, boolean root) {
        File target = root ? BootConfig.defaultRoot(this) : BootConfig.defaultPayload(this);
        long size = querySize(uri);
        if (size > 0 && target.getParentFile() != null
                && target.getParentFile().getUsableSpace() < size + (256L << 20)) {
            dialog("空间不足", "目标目录可用空间不足。\n需要 " + BootConfig.human(size)
                    + "，可用 " + BootConfig.human(target.getParentFile().getUsableSpace()) + "。");
            return;
        }
        if (target.exists()) {
            new AlertDialog.Builder(this)
                    .setTitle("覆盖现有文件？")
                    .setMessage(target.getName() + " 已存在，导入会替换它。")
                    .setNegativeButton("取消", null)
                    .setPositiveButton("覆盖", (d, w) -> doImport(uri, target, size, root))
                    .show();
        } else {
            doImport(uri, target, size, root);
        }
    }

    private void doImport(Uri uri, File target, long size, boolean isRoot) {
        ProgressBar bar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        bar.setMax(1000);
        bar.setProgressTintList(ColorStateList.valueOf(ACCENT));
        TextView msg = text(size > 0 ? "0 / " + BootConfig.human(size) : "准备中…", 12, DIM, false);
        msg.setPadding(0, dp(10), 0, 0);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(22), dp(18), dp(22), dp(6));
        box.addView(bar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(6)));
        box.addView(msg);
        AtomicBoolean cancel = new AtomicBoolean(false);
        AlertDialog dlg = new AlertDialog.Builder(this)
                .setTitle("导入 " + target.getName())
                .setView(box)
                .setNegativeButton("取消", (d, w) -> cancel.set(true))
                .setCancelable(false)
                .create();
        dlg.show();
        new Thread(() -> {
            File tmp = new File(target.getAbsolutePath() + ".part");
            try (InputStream in = getContentResolver().openInputStream(uri);
                 FileOutputStream out = new FileOutputStream(tmp)) {
                if (in == null) {
                    throw new IOException("无法读取文件");
                }
                byte[] buf = new byte[1 << 20];
                long done = 0;
                int last = -1;
                int n;
                while ((n = in.read(buf)) > 0) {
                    if (cancel.get()) {
                        throw new IOException("已取消");
                    }
                    out.write(buf, 0, n);
                    done += n;
                    if (size > 0) {
                        int p = (int) Math.min(1000, done * 1000 / size);
                        if (p != last) {
                            last = p;
                            long fd = done;
                            ui.post(() -> {
                                bar.setProgress(p);
                                msg.setText(BootConfig.human(fd) + " / " + BootConfig.human(size));
                            });
                        }
                    }
                }
                out.getFD().sync();
                if (target.exists() && !target.delete()) {
                    throw new IOException("无法替换旧文件");
                }
                if (!tmp.renameTo(target)) {
                    throw new IOException("无法保存文件");
                }
                if (cancel.get()) {
                    throw new IOException("已取消");
                }
                ui.post(() -> {
                    dlg.dismiss();
                    if (isRoot) {
                        cfg.rootPath = target.getAbsolutePath();
                        if (!BootConfig.looksLikeHfs(target)) {
                            toast("已导入，但没有识别到 HFS+ 卷头，请确认这是 raw 根镜像");
                        }
                    } else {
                        cfg.payloadPath = target.getAbsolutePath();
                        if (!BootConfig.looksLikePayload(target)) {
                            toast("已导入，但不是 SWEETXNU payload");
                        }
                    }
                    cfg.save(this);
                    showHome();
                });
            } catch (Exception e) {
                try {
                    tmp.delete();
                } catch (Exception ignored) {
                }
                ui.post(() -> {
                    dlg.dismiss();
                    dialog("导入失败", e.getMessage() == null ? "未知错误" : e.getMessage());
                });
            }
        }, "sweetvm-import").start();
    }

    private long querySize(Uri uri) {
        ContentResolver cr = getContentResolver();
        try (Cursor c = cr.query(uri, new String[]{OpenableColumns.SIZE}, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                int i = c.getColumnIndex(OpenableColumns.SIZE);
                if (i >= 0 && !c.isNull(i)) {
                    return c.getLong(i);
                }
            }
        } catch (Exception ignored) {
        }
        return -1;
    }

    private boolean canResume() {
        File root = cfg.rootFile();
        File payload = cfg.payloadFile();
        if (root == null || !root.isFile() || payload == null || !payload.isFile()) {
            return false;
        }
        String engineVersion;
        try {
            engineVersion = EngineAssets.currentVersion(this);
        } catch (IOException e) {
            return false;
        }
        return Snapshot.isUsable(this, payload, root, iosCmdline(payload), engineVersion);
    }

    private void startIos() {
        startIos(canResume());
    }

    private void startIos(boolean resume) {
        File root = cfg.rootFile();
        File payload = cfg.payloadFile();
        if (root == null || !root.isFile()) {
            dialog("需要 iOS 根镜像",
                    "请先导入由 tools/mkiosroot.sh 生成的 HFS+ raw 根镜像。\n\n"
                            + "App 不附带 iOS 系统文件；这是你自备的 IPSW 生成的镜像。");
            return;
        }
        if (payload == null || !payload.isFile()) {
            dialog("需要内核 payload", "请先导入用 tools/mkpayload.py 生成的 SWEETXNU payload。");
            return;
        }
        if (!BootConfig.looksLikeHfs(root)) {
            dialog("根镜像格式未确认",
                    "在 offset 1024 没有找到 HFS+ 卷头（H+ / HX）。继续启动可能失败。",
                    "仍然启动", () -> launch(payload, root, iosCmdline(payload), resume));
            return;
        }
        if (!BootConfig.looksLikePayload(payload)) {
            dialog("payload 格式错误", "文件不是 SWEETXNU payload，请重新生成。");
            return;
        }
        launch(payload, root, iosCmdline(payload), resume);
    }

    private String iosCmdline(File payload) {
        String cmd = cfg.cmdline.trim();
        if (cmd.isEmpty()) {
            try {
                cmd = Payload.load(payload).cmdline().trim();
            } catch (Exception e) {
                cmd = "";
            }
        }
        if (!cmd.contains("rd=")) {
            cmd = (cmd + " rd=ufsroot0 ufsrw=1 rootrw=1").trim();
        }
        cmd = ensureQemuArgs(cmd);
        cmd = enableTouch(cmd);
        if (cfg.mttcg && !cmd.contains("tcgmulti=1")) {
            // VmEngine turns this into -accel tcg,thread=multi and adds
            // the 2 s ticket/spin lock timeouts that keep XNU from panicking.
            cmd = (cmd + " tcgmulti=1").trim();
        }
        return truncateCmdline(cmd);
    }

    private String enableTouch(String cmd) {
        cmd = cmd.replace("sweettouch=0", "sweettouch=1");
        if (!cmd.contains("sweettouch=")) {
            cmd = (cmd + " sweettouch=1").trim();
        }
        if (!cmd.contains("sweettouchdelay=")) {
            cmd = (cmd + " sweettouchdelay=3").trim();
        }
        if (!cmd.contains("sweetfb_noconsole=")) {
            cmd = (cmd + " sweetfb_noconsole=1").trim();
        }
        return cmd;
    }

    private String demoCmdline(File payload) {
        String cmd = cfg.cmdline.trim();
        if (cmd.isEmpty() || cmd.contains("rd=ufsroot0")) {
            try {
                cmd = Payload.load(payload).cmdline().trim();
            } catch (Exception e) {
                cmd = "";
            }
        }
        if (!cmd.contains("rd=")) {
            cmd = (cmd + " rd=md0").trim();
        }
        return truncateCmdline(ensureQemuArgs(cmd));
    }

    private String ensureQemuArgs(String cmd) {
        StringBuilder b = new StringBuilder(cmd);
        String[] need = {"sweetkeys=0", "sweetusb=0",
                "wdt=-1", "wdt_test=no_user_checkin",
                "sweetiolog=0", "sweetsample=0", "sweetnull=0"};
        for (String s : need) {
            String key = s.split("=")[0];
            if (!b.toString().contains(key + "=")) {
                b.append(' ').append(s);
            }
        }
        return b.toString().trim();
    }

    /** VmEngine appends " tlto_us=2000000 slto_us=2000000" for MTTCG. */
    private static final int MTTCG_LOCK_ARGS = 34;

    private String truncateCmdline(String cmd) {
        int limit = cfg.mttcg ? 607 - MTTCG_LOCK_ARGS : 607;
        if (cmd.length() <= limit) {
            return cmd;
        }
        int cut = cmd.lastIndexOf(' ', limit);
        if (cut < 0) {
            cut = limit;
        }
        return cmd.substring(0, cut);
    }

    private void startDemo() {
        File payload;
        try {
            payload = BootConfig.demoPayload(this);
        } catch (IOException e) {
            dialog("演示 payload 缺失", "APK 中没有 assets/demo/payload.bin。\n" + e.getMessage());
            return;
        }
        if (!BootConfig.looksLikePayload(payload)) {
            dialog("演示 payload 损坏", "assets/demo/payload.bin 不是 SWEETXNU payload。");
            return;
        }
        launch(payload, null, demoCmdline(payload), false);
    }

    private void launch(File payload, File root, String cmd, boolean resume) {
        try {
            Payload p = Payload.load(payload);
            if (p.physBase != 0xb0000000L) {
                dialog("payload 不适用于 App",
                        "App 的 QEMU 使用 0xb0000000 低内存布局；请在构建时使用 "
                                + "mkadt.py --qemu（不要 --highmem）。");
                return;
            }
        } catch (Exception e) {
            dialog("无法读取 payload", e.getMessage() == null ? "未知错误" : e.getMessage());
            return;
        }
        showVmScreen();
        lastCmdline = cmd;
        touch = new TouchSender(new File(getFilesDir(), "vm/touch.bin"));
        touch.start();
        acquireWake();
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        vmActive = true;
        vmStopping = false;
        vmStartedAt = System.currentTimeMillis();
        lastFrames = 0;
        lastFrameTime = vmStartedAt;
        ui.removeCallbacks(ticker);
        ui.post(ticker);
        new Thread(() -> {
            try {
                engine.start(payload, root, cmd, cfg.fps, resume, new VmEngine.Listener() {
                    @Override
                    public void onExit(int code, String logTail) {
                        ui.post(() -> {
                            if (!vmActive || vmStopping) {
                                return;
                            }
                            vmActive = false;
                            ui.removeCallbacks(ticker);
                            releaseWake();
                            getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                            showExit(code, logTail);
                        });
                    }

                    @Override
                    public void onError(String message) {
                        ui.post(() -> toast(message));
                    }
                });
            } catch (Exception e) {
                ui.post(() -> {
                    vmActive = false;
                    ui.removeCallbacks(ticker);
                    releaseWake();
                    getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                    showExit(-1, e.getMessage() == null ? "无法启动 QEMU" : e.getMessage());
                });
            }
        }, "sweetvm-start").start();
    }

    private void showVmScreen() {
        setVmSystemBars(true);
        clearRoot();
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        fbView = new FramebufferView(this);
        fbView.setTouchListener((type, x, y) -> {
            TouchSender t = touch;
            if (t != null) {
                t.send(type, x, y);
            }
        });
        root.addView(fbView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        vmHint = new TextView(this);
        vmHint.setText("正在启动 XNU…\n首次启动可能需要几十分钟");
        vmHint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        vmHint.setTextColor(TEXT);
        vmHint.setGravity(Gravity.CENTER);
        vmHint.setPadding(dp(22), dp(18), dp(22), dp(18));
        vmHint.setBackground(round(0xCC14141B, 18));
        FrameLayout.LayoutParams hp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        hp.gravity = Gravity.CENTER;
        root.addView(vmHint, hp);

        vmTop = new LinearLayout(this);
        vmTop.setOrientation(LinearLayout.HORIZONTAL);
        vmTop.setGravity(Gravity.CENTER_VERTICAL);
        vmTop.setPadding(dp(14), statusBarHeight() + dp(8), dp(14), dp(10));
        vmTop.setBackgroundColor(0xFF08080C);
        TextView close = text("×", 24, TEXT, false);
        close.setGravity(Gravity.CENTER);
        close.setPadding(dp(8), 0, dp(8), 0);
        close.setOnClickListener(v -> confirmStop());
        vmTop.addView(close, new LinearLayout.LayoutParams(dp(40), dp(44)));
        LinearLayout stack = new LinearLayout(this);
        stack.setOrientation(LinearLayout.VERTICAL);
        stack.setPadding(dp(6), 0, 0, 0);
        TextView title = text("SweetVM", 14, TEXT, true);
        vmStatus = text("启动中 · 软件 CPU", 10, DIM, false);
        stack.addView(title);
        stack.addView(vmStatus);
        vmTop.addView(stack);
        View spacer = new View(this);
        vmTop.addView(spacer, new LinearLayout.LayoutParams(0, 1, 1));
        TextView stop = text("停止", 12, BAD, true);
        stop.setPadding(dp(12), dp(8), dp(12), dp(8));
        stop.setOnClickListener(v -> confirmStop());
        vmTop.addView(stop);
        FrameLayout.LayoutParams tp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tp.gravity = Gravity.TOP;
        root.addView(vmTop, tp);

        vmPill = new TextView(this);
        vmPill.setText("00:00 · 等待画面");
        vmPill.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        vmPill.setTextColor(TEXT);
        vmPill.setGravity(Gravity.CENTER);
        vmPill.setPadding(dp(14), dp(8), dp(14), dp(8));
        vmPill.setBackground(round(0xF21D1D26, 99));
        FrameLayout.LayoutParams pp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        pp.gravity = Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL;
        pp.bottomMargin = navBarHeight() + dp(20);
        root.addView(vmPill, pp);
        vmTimer = vmPill;

        TextView controls = text("≡", 20, TEXT, true);
        controls.setGravity(Gravity.CENTER);
        controls.setBackground(round(0xCC1D1D26, 99));
        controls.setOnClickListener(v -> toggleControls());
        FrameLayout.LayoutParams cp = new FrameLayout.LayoutParams(dp(44), dp(44));
        cp.gravity = Gravity.BOTTOM | Gravity.RIGHT;
        cp.rightMargin = dp(14);
        cp.bottomMargin = navBarHeight() + dp(66);
        root.addView(controls, cp);

        vmScreen = root;
        rootView.addView(root, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        engine.setView(fbView);
        controlsVisible = true;
        ui.removeCallbacks(hideControls);
        ui.postDelayed(hideControls, 4500);
    }

    private void toggleControls() {
        controlsVisible = !controlsVisible;
        if (vmTop != null) {
            vmTop.animate().alpha(controlsVisible ? 1f : 0f).setDuration(180).start();
        }
        if (vmPill != null) {
            vmPill.animate().alpha(controlsVisible ? 1f : 0f).setDuration(180).start();
        }
        ui.removeCallbacks(hideControls);
        if (controlsVisible) {
            ui.postDelayed(hideControls, 4500);
        }
    }

    private void confirmStop() {
        if (!vmActive) {
            showHome();
            return;
        }
        new AlertDialog.Builder(this)
                .setTitle("停止虚拟机？")
                .setMessage("保存快照会把当前 RAM 和设备状态写入磁盘，下次启动只需几秒；"
                        + "直接停止会丢失未保存的 iOS 状态（HFS+ 已写入的部分保留）。")
                .setNegativeButton("继续运行", null)
                .setNeutralButton("直接停止", (d, w) -> stopVm(true))
                .setPositiveButton("保存快照并退出", (d, w) -> saveAndStop())
                .show();
    }

    private void saveAndStop() {
        if (!vmActive) {
            showHome();
            return;
        }
        final File payload = cfg.payloadFile();
        final File root = cfg.rootFile();
        final String cmd = lastCmdline;
        final String engineVersion;
        try {
            engineVersion = EngineAssets.currentVersion(this);
        } catch (IOException e) {
            toast("保存快照失败: " + e.getMessage());
            return;
        }
        final AlertDialog progress = new AlertDialog.Builder(this)
                .setTitle("正在保存快照")
                .setMessage("写入客户机内存与设备状态，请稍候…")
                .setCancelable(false)
                .show();
        vmStopping = true;
        vmActive = false;
        ui.removeCallbacks(ticker);
        new Thread(() -> {
            String err = null;
            try {
                Snapshot.save(engine.qmpSocket(), Snapshot.stateFile(this));
                Snapshot.writeMeta(this, payload, root, cmd, engineVersion);
            } catch (Exception e) {
                err = e.getMessage() == null ? e.toString() : e.getMessage();
            }
            engine.stop();
            final String fe = err;
            ui.post(() -> {
                progress.dismiss();
                releaseWake();
                getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                showHome();
                toast(fe == null ? "快照已保存，下次可秒开" : "保存快照失败: " + fe);
            });
        }, "sweetvm-snapshot").start();
    }

    private void stopVm(boolean home) {
        vmStopping = true;
        vmActive = false;
        ui.removeCallbacks(ticker);
        engine.stop();
        releaseWake();
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if (home) {
            showHome();
        }
    }

    private void showExit(int code, String log) {
        if (isFinishing() || isDestroyed()) {
            return;
        }
        String tail = log == null ? "" : log;
        if (tail.length() > 2400) {
            tail = tail.substring(tail.length() - 2400);
        }
        String msg = "退出码：" + code + "\n\n" + tail;
        if (cfg.mttcg && (tail.contains("panic(") || tail.contains("Ticket spinlock"))) {
            msg = "检测到内核 panic：多线程 TCG 可能不稳定。\n"
                    + "请在高级选项关闭「多线程 TCG」后重试，并复制日志。\n\n" + msg;
        }
        AlertDialog d = new AlertDialog.Builder(this)
                .setTitle(code == 0 ? "虚拟机已退出" : "虚拟机异常退出")
                .setMessage(msg)
                .setNegativeButton("复制日志", (dd, w) -> {
                    ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                    cm.setPrimaryClip(ClipData.newPlainText("SweetVM log", log == null ? "" : log));
                    toast("日志已复制");
                })
                .setPositiveButton("返回", (dd, w) -> showHome())
                .setCancelable(false)
                .create();
        d.show();
    }

    private void showAdvanced() {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(22), dp(14), dp(22), dp(4));
        box.addView(text("启动参数（留空 = 使用 payload 自带）", 11, DIM, false));
        EditText et = new EditText(this);
        et.setText(cfg.cmdline);
        et.setHint("rd=ufsroot0 ufsrw=1 rootrw=1 …");
        et.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        et.setTypeface(Typeface.MONOSPACE);
        et.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE
                | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        et.setMinLines(4);
        et.setGravity(Gravity.TOP | Gravity.START);
        et.setPadding(dp(10), dp(10), dp(10), dp(10));
        et.setBackground(outline(SURFACE_2, STROKE, 10, 1));
        box.addView(et, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(150)));
        box.addView(gap(14));
        android.widget.CheckBox mttcgBox = new android.widget.CheckBox(this);
        mttcgBox.setText("多线程 TCG（试验：2 个 vCPU 真并行，更快但可能 panic）");
        mttcgBox.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        mttcgBox.setTextColor(TEXT);
        mttcgBox.setChecked(cfg.mttcg);
        box.addView(mttcgBox);
        TextView fpsLabel = text("画面采样：" + cfg.fps + " fps", 12, DIM, false);
        SeekBar seek = new SeekBar(this);
        // 15..60 fps in steps of 5. The old 1..11 range capped the whole VM
        // at 11 fps regardless of how fast the guest rendered.
        seek.setMax(9);
        seek.setProgress(Math.max(0, Math.min(9, (cfg.fps - 15) / 5)));
        seek.setProgressTintList(ColorStateList.valueOf(ACCENT));
        seek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override
            public void onProgressChanged(SeekBar s, int p, boolean fromUser) {
                fpsLabel.setText("画面采样：" + (15 + p * 5) + " fps");
            }
            @Override public void onStartTrackingTouch(SeekBar s) { }
            @Override public void onStopTrackingTouch(SeekBar s) { }
        });
        box.addView(fpsLabel);
        box.addView(seek);
        box.addView(text("QEMU 固定 3 GB 客户机内存；vCPU 数取自 cpus=N，默认单线程 TCG。"
                + "tcgmulti=1 可试验多线程 TCG（当前会触发内核 panic）。参数长度上限 607 字节。",
                10, DIM, false));
        AlertDialog d = new AlertDialog.Builder(this)
                .setTitle("高级选项")
                .setView(box)
                .setNegativeButton("取消", null)
                .setNeutralButton("清除", (dd, w) -> {
                    cfg.cmdline = "";
                    cfg.save(this);
                    showHome();
                })
                .setPositiveButton("保存", (dd, w) -> {
                    cfg.cmdline = et.getText().toString().trim();
                    cfg.mttcg = mttcgBox.isChecked();
                    cfg.fps = 15 + seek.getProgress() * 5;
                    cfg.save(this);
                    showHome();
                })
                .create();
        d.show();
    }

    private void showLogs() {
        StringBuilder sb = new StringBuilder();
        appendFile(sb, new File(getFilesDir(), "vm/qemu.log"));
        appendFile(sb, new File(getFilesDir(), "vm/serial.log"));
        String guest = SweetLog.tail(cfg.rootFile(), 64 * 1024);
        if (!guest.isEmpty()) {
            sb.append("--- SWEETLOG ---\n").append(guest).append('\n');
        }
        String content = sb.toString();
        if (content.trim().isEmpty()) {
            content = "还没有运行日志。";
        }
        final String shown = content;
        TextView tv = text(content, 11, TEXT, false);
        tv.setTypeface(Typeface.MONOSPACE);
        tv.setTextIsSelectable(true);
        tv.setPadding(dp(14), dp(12), dp(14), dp(12));
        ScrollView sv = new ScrollView(this);
        sv.addView(tv);
        new AlertDialog.Builder(this)
                .setTitle("运行日志")
                .setView(sv)
                .setNegativeButton("关闭", null)
                .setPositiveButton("复制", (d, w) -> {
                    ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                    cm.setPrimaryClip(ClipData.newPlainText("SweetVM log", shown));
                    toast("已复制");
                })
                .show();
    }

    private void appendFile(StringBuilder sb, File f) {
        if (!f.isFile()) {
            return;
        }
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] b = new byte[(int) Math.min(f.length(), 256 * 1024)];
            int n = in.read(b);
            if (n > 0) {
                sb.append(new String(b, 0, n, java.nio.charset.StandardCharsets.UTF_8)).append('\n');
            }
        } catch (IOException ignored) {
        }
    }

    private void showHelp() {
        dialog("构建镜像与 payload",
                "1. 在 Linux/macOS 上用 tools/mkiosroot.sh 把 iPhone X 16.7.16 IPSW 的 "
                        + "OS/SystemOS/AppOS 合成 16 GB HFS+ 根镜像。\n\n"
                        + "2. 生成 QEMU 设备树：python3 tools/mkadt.py q.adt --qemu\n\n"
                        + "3. 打包 payload：python3 tools/mkpayload.py kernel.development.sweet "
                        + "q.adt payload.bin --cmdline \"debug=0xc serial=3 cpus=1 keepsyms=1 "
                        + "-enable_kprintf_spam -noprogress rd=ufsroot0 ufsrw=1 rootrw=1 "
                        + "unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin "
                        + "launchd_unsecure_cache=1 wdt=-1 sweetfb_hz=30\"\n\n"
                        + "4. 在 App 里导入 payload 和根镜像。根镜像也可放到 "
                        + "Android/data/dev.hackios.sweetvm/files/ios16-root.img。\n\n"
                        + "注意：kernel 必须用 QEMU ADT（--qemu），phys_base 必须是 0xb0000000，"
                        + "不能使用 --highmem。");
    }

    private void dialog(String title, String msg) {
        new AlertDialog.Builder(this).setTitle(title).setMessage(msg)
                .setPositiveButton("知道了", null).show();
    }

    private void dialog(String title, String msg, String positive, Runnable action) {
        new AlertDialog.Builder(this).setTitle(title).setMessage(msg)
                .setNegativeButton("取消", null)
                .setPositiveButton(positive, (d, w) -> action.run())
                .show();
    }

    private void toast(String s) {
        Toast.makeText(this, s, Toast.LENGTH_LONG).show();
    }

    private void acquireWake() {
        if (wake == null) {
            PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
            wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SweetVM:vm");
            wake.setReferenceCounted(false);
        }
        wake.acquire(12L * 60 * 60 * 1000);
    }

    private void releaseWake() {
        if (wake != null && wake.isHeld()) {
            wake.release();
        }
    }

    @Override
    public void onBackPressed() {
        if (vmActive) {
            confirmStop();
        } else {
            super.onBackPressed();
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        vmActive = false;
        vmStopping = true;
        ui.removeCallbacks(ticker);
        engine.stop();
        if (touch != null) {
            touch.close();
            touch = null;
        }
        releaseWake();
    }
}
