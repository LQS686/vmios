package dev.hackios.sweetvm;

import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.opengl.GLES20;
import android.util.Log;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.File;
import java.io.RandomAccessFile;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Host GPU backend for the SWEET offline wire (GPU_WIRE_CLEAR). */
public final class GpuWireServer {
    private static final String TAG = "sweetgpu-host";
    private static final int MAGIC = 0x5550474e;
    private static final int VERSION = 1;
    private static final int OP_CLEAR = 1;
    private static final int OP_DRAW = 2;
    private static final int OP_FILL = 3;
    private static final int RESPONSE = 0x8000;
    private static final int WIDTH = 64;
    private static final int HEIGHT = 64;
    private static final int FORMAT_R32F = 55;
    private static final int PIXEL_BYTES = WIDTH * HEIGHT * 4;

    /* Guest panel: ADT framebuffer at guest PA 0x9c000000, QEMU RAM at 0x40000000. */
    private static final long RAM_PA = 0x40000000L;
    private static final long PANEL_PA = 0x9c000000L;
    private static final long PANEL_OFF = PANEL_PA - RAM_PA;
    private static final int PANEL_BPR = 1080 * 4;
    private static final int PANEL_WIDTH = 1080;

    private static GpuWireServer instance;
    private static File guestRam;
    private static boolean panelStarted;

    private final ServerSocket server;
    private final Thread thread;

    public static synchronized void start(int port) {
        start(port, null);
    }

    public static synchronized void start(int port, File ramFile) {
        guestRam = ramFile;
        if (instance != null) {
            return;
        }
        try {
            GpuWireServer s = new GpuWireServer(port);
            instance = s;
            s.thread.start();
        } catch (Exception e) {
            Log.e(TAG, "start failed", e);
        }
    }

    private GpuWireServer(int port) throws Exception {
        server = new ServerSocket(port, 1, InetAddress.getByName("127.0.0.1"));
        thread = new Thread(this::serve, "sweetgpu-host");
        thread.setDaemon(true);
        Log.i(TAG, "listening on 127.0.0.1:" + port);
    }

    private void serve() {
        ClearRenderer gpu = null;
        try {
            gpu = new ClearRenderer();
            while (true) {
                try (Socket socket = server.accept()) {
                    socket.setTcpNoDelay(true);
                    Log.i(TAG, "client " + socket.getRemoteSocketAddress());
                    handle(socket, gpu);
                } catch (EOFException ignored) {
                } catch (Exception e) {
                    Log.w(TAG, "client failed", e);
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "serve failed", e);
        } finally {
            if (gpu != null) {
                gpu.close();
            }
        }
    }

    private void handle(Socket socket, ClearRenderer gpu) throws Exception {
        DataInputStream in = new DataInputStream(socket.getInputStream());
        DataOutputStream out = new DataOutputStream(socket.getOutputStream());
        while (true) {
            int magic = Integer.reverseBytes(in.readInt());
            int version = Short.reverseBytes(in.readShort()) & 0xffff;
            int operation = Short.reverseBytes(in.readShort()) & 0xffff;
            int bytes = Integer.reverseBytes(in.readInt());
            int request = Integer.reverseBytes(in.readInt());
            if (magic != MAGIC || version != VERSION || bytes < 0 || bytes > 4096) {
                return;
            }
            byte[] payload = new byte[bytes];
            if (bytes > 0) {
                in.readFully(payload);
            }
            if (operation == OP_FILL) {
                fillSurface(payload, request);
                continue;
            }
            if (operation != OP_CLEAR && operation != OP_DRAW) {
                return;
            }
            long start = System.nanoTime();
            int clears = gpu.clear(operation == OP_CLEAR);
            long end = System.nanoTime();
            Log.i(TAG, "op=" + operation + " request=" + request + " clears=" + clears
                    + " gpu_ns=" + (end - start));
            if (guestRam != null) {
                startPanelBlit(gpu);
            }

            ByteBuffer reply = ByteBuffer.allocate(16 + 32 + PIXEL_BYTES)
                    .order(ByteOrder.LITTLE_ENDIAN);
            reply.putInt(MAGIC);
            reply.putShort((short) VERSION);
            reply.putShort((short) (operation | RESPONSE));
            reply.putInt(32 + PIXEL_BYTES);
            reply.putInt(request);
            reply.putInt(WIDTH);
            reply.putInt(HEIGHT);
            reply.putInt(FORMAT_R32F);
            reply.putInt(4);
            reply.putLong(start);
            reply.putLong(end);
            for (int i = 0; i < WIDTH * HEIGHT; i++) {
                reply.putInt(operation == OP_CLEAR ? 0x3f800000 : 0);
            }
            out.write(reply.array());
            out.flush();
        }
    }

    private static RandomAccessFile panelFile;

    private static synchronized RandomAccessFile panelFile() throws Exception {
        if (panelFile == null) {
            panelFile = new RandomAccessFile(guestRam, "rw");
        }
        return panelFile;
    }

    /*
     * OP_FILL: paint a rectangle of a guest IOSurface (the render pass clear
     * the plugin asked for) directly in the guest's RAM.
     */
    private static void fillSurface(byte[] payload, int request) {
        if (payload.length < 32 || guestRam == null) {
            return;
        }
        ByteBuffer b = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);
        long pa = (b.getInt(0) & 0xffffffffL) | ((long) b.getInt(4) << 32);
        int width = b.getInt(8);
        int height = b.getInt(12);
        int stride = b.getInt(16);
        int color = b.getInt(20);
        int x = b.getInt(24);
        int y = b.getInt(28);
        long off = pa - RAM_PA;
        if (off < 0 || width <= 0 || height <= 0 || stride < width * 4) {
            Log.w(TAG, "fill rejected pa=0x" + Long.toHexString(pa) + " " + width
                    + "x" + height + " stride=" + stride);
            return;
        }
        byte[] row = new byte[width * 4];
        for (int i = 0; i < width; i++) {
            row[i * 4] = (byte) (color >> 16);
            row[i * 4 + 1] = (byte) (color >> 8);
            row[i * 4 + 2] = (byte) color;
            row[i * 4 + 3] = (byte) 0xff;
        }
        try {
            RandomAccessFile f = panelFile();
            long base = off + (long) y * stride + (long) x * 4;
            for (int yy = 0; yy < height; yy++) {
                f.seek(base + (long) yy * stride);
                f.write(row);
            }
            Log.i(TAG, "fill request=" + request + " pa=0x" + Long.toHexString(pa)
                    + " " + width + "x" + height + " color=#" + Integer.toHexString(color));
        } catch (Exception e) {
            Log.w(TAG, "fill failed", e);
        }
    }

    /*
     * End-to-end check of the host GPU path: take the colour the GL clear
     * produced, then paint a moving square straight into the guest panel
     * surface through the shared RAM file. The guest is expected to show it
     * on screen once the kernel console stops drawing.
     */
    private static void startPanelBlit(ClearRenderer gpu) {
        synchronized (GpuWireServer.class) {
            if (panelStarted || guestRam == null) {
                return;
            }
            panelStarted = true;
        }
        final int color = gpu.pixel(1f, 0f, 0f);
        final int white = gpu.pixel(1f, 1f, 1f);
        Thread t = new Thread(() -> {
            Log.i(TAG, "panel blit color=#" + Integer.toHexString(color)
                    + " off=0x" + Long.toHexString(PANEL_OFF));
            final int y0 = 300, rows = 480, bar = 48;
            byte[] row = new byte[PANEL_WIDTH * 4];
            try (RandomAccessFile f = new RandomAccessFile(guestRam, "rw")) {
                for (int i = 0; i < 600; i++) {
                    int barX = (i * 9) % (PANEL_WIDTH - bar);
                    for (int px = 0; px < PANEL_WIDTH; px++) {
                        int c = (px >= barX && px < barX + bar) ? white : color;
                        row[px * 4] = (byte) (c >> 16);	/* R */
                        row[px * 4 + 1] = (byte) (c >> 8);	/* G */
                        row[px * 4 + 2] = (byte) c;	/* B */
                        row[px * 4 + 3] = (byte) 0xff;
                    }
                    for (int yy = 0; yy < rows; yy++) {
                        f.seek(PANEL_OFF + (long) (y0 + yy) * PANEL_BPR);
                        f.write(row);
                    }
                    Thread.sleep(250);
                }
            } catch (Exception e) {
                Log.w(TAG, "panel blit failed", e);
            }
        }, "sweetgpu-panel");
        t.setDaemon(true);
        t.start();
    }

    private static final class ClearRenderer {
        private EGLDisplay display;
        private EGLContext context;
        private EGLSurface surface;

        ClearRenderer() {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
            int[] version = new int[2];
            if (display == EGL14.EGL_NO_DISPLAY || !EGL14.eglInitialize(display, version, 0,
                    version, 1)) {
                throw new IllegalStateException("eglInitialize failed");
            }
            int[] configAttrs = {
                    EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                    EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                    EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
                    EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                    EGL14.EGL_NONE
            };
            EGLConfig[] configs = new EGLConfig[1];
            int[] count = new int[1];
            if (!EGL14.eglChooseConfig(display, configAttrs, 0, configs, 0, 1, count, 0)
                    || count[0] == 0) {
                throw new IllegalStateException("eglChooseConfig failed");
            }
            int[] contextAttrs = {EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE};
            context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
                    contextAttrs, 0);
            int[] surfaceAttrs = {
                    EGL14.EGL_WIDTH, WIDTH, EGL14.EGL_HEIGHT, HEIGHT, EGL14.EGL_NONE
            };
            surface = EGL14.eglCreatePbufferSurface(display, configs[0], surfaceAttrs, 0);
            if (context == EGL14.EGL_NO_CONTEXT || surface == EGL14.EGL_NO_SURFACE
                    || !EGL14.eglMakeCurrent(display, surface, surface, context)) {
                throw new IllegalStateException("EGL setup failed");
            }
            Log.i(TAG, "EGL " + version[0] + "." + version[1] + " "
                    + GLES20.glGetString(GLES20.GL_RENDERER));
        }

        int pixel(float red, float green, float blue) {
            GLES20.glViewport(0, 0, WIDTH, HEIGHT);
            GLES20.glClearColor(red, green, blue, 1f);
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
            GLES20.glFinish();
            ByteBuffer px = ByteBuffer.allocateDirect(4).order(ByteOrder.LITTLE_ENDIAN);
            GLES20.glReadPixels(0, 0, 1, 1, GLES20.GL_RGBA,
                    GLES20.GL_UNSIGNED_BYTE, px);
            int r = px.get(0) & 0xff;
            int g = px.get(1) & 0xff;
            int b = px.get(2) & 0xff;
            return (0xff << 24) | (r << 16) | (g << 8) | b;
        }

        int clear(boolean on) {
            GLES20.glViewport(0, 0, WIDTH, HEIGHT);
            GLES20.glClearColor(on ? 1f : 0f, 0f, 0f, 1f);
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
            GLES20.glFinish();
            ByteBuffer pixels = ByteBuffer.allocateDirect(PIXEL_BYTES)
                    .order(ByteOrder.LITTLE_ENDIAN);
            GLES20.glReadPixels(0, 0, WIDTH, HEIGHT, GLES20.GL_RGBA,
                    GLES20.GL_UNSIGNED_BYTE, pixels);
            int clears = 0;
            for (int i = 0; i < WIDTH * HEIGHT; i++) {
                if ((pixels.get(i * 4) & 0xff) != 0) {
                    clears++;
                }
            }
            return clears;
        }

        void close() {
            if (display == EGL14.EGL_NO_DISPLAY) {
                return;
            }
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_CONTEXT);
            if (surface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglDestroySurface(display, surface);
            }
            if (context != EGL14.EGL_NO_CONTEXT) {
                EGL14.eglDestroyContext(display, context);
            }
            EGL14.eglTerminate(display);
        }
    }
}
