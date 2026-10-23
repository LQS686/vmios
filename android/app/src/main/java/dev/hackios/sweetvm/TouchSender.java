package dev.hackios.sweetvm;

import android.net.LocalSocket;
import android.net.LocalSocketAddress;

import java.io.IOException;
import java.io.OutputStream;

/**
 * Feeds the QEMU sweet-touch chardev (vm/qemu/sweet_touch.c).
 * Five-byte packets: type (0 up, 1 down, 2 move), x LE16, y LE16.
 */
public final class TouchSender {
    private final String path;
    private volatile boolean closed;
    private volatile LocalSocket socket;
    private volatile OutputStream out;
    private Thread connector;

    public TouchSender(String path) {
        this.path = path;
    }

    public void start() {
        if (closed) {
            return;
        }
        Thread t = connector;
        if (t != null && t.isAlive()) {
            return;
        }
        connector = new Thread(this::connectLoop, "sweetvm-touch");
        connector.setDaemon(true);
        connector.start();
    }

    private void connectLoop() {
        while (!closed && out == null) {
            LocalSocket s = null;
            try {
                s = new LocalSocket();
                s.connect(new LocalSocketAddress(path,
                        LocalSocketAddress.Namespace.FILESYSTEM));
                socket = s;
                out = s.getOutputStream();
                return;
            } catch (IOException e) {
                if (s != null) {
                    try {
                        s.close();
                    } catch (IOException ignored) {
                    }
                }
                try {
                    Thread.sleep(300);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    return;
                }
            }
        }
    }

    public void send(int type, int x, int y) {
        OutputStream o = out;
        if (o == null || closed) {
            return;
        }
        byte[] b = {
                (byte) type,
                (byte) (x & 0xff), (byte) ((x >> 8) & 0xff),
                (byte) (y & 0xff), (byte) ((y >> 8) & 0xff)
        };
        try {
            o.write(b);
            o.flush();
        } catch (IOException e) {
            closeSocket();
            start();
        }
    }

    private void closeSocket() {
        out = null;
        LocalSocket s = socket;
        socket = null;
        if (s != null) {
            try {
                s.close();
            } catch (IOException ignored) {
            }
        }
    }

    public void close() {
        closed = true;
        closeSocket();
    }
}
