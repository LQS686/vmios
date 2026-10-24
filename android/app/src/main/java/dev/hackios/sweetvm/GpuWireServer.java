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
    private static final int RESPONSE = 0x8000;
    private static final int WIDTH = 64;
    private static final int HEIGHT = 64;
    private static final int FORMAT_R32F = 55;
    private static final int PIXEL_BYTES = WIDTH * HEIGHT * 4;

    private static GpuWireServer instance;

    private final ServerSocket server;
    private final Thread thread;

    public static synchronized void start(int port) {
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
            if (bytes > 0) {
                in.readFully(new byte[bytes]);
            }
            if (operation != OP_CLEAR && operation != OP_DRAW) {
                return;
            }
            long start = System.nanoTime();
            int clears = gpu.clear(operation == OP_CLEAR);
            long end = System.nanoTime();
            Log.i(TAG, "op=" + operation + " request=" + request + " clears=" + clears
                    + " gpu_ns=" + (end - start));

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
