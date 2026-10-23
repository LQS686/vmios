package dev.hackios.sweetvm;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;

/**
 * Publishes the latest touch state to the file polled by sweet-touch
 * (vm/qemu/sweet_touch.c). Five-byte records: type (0 up, 1 down, 2 move),
 * x LE16, y LE16.
 */
public final class TouchSender {
    private final File file;
    private RandomAccessFile out;
    private boolean closed;

    public TouchSender(File file) {
        this.file = file;
    }

    public void start() {
        // QEMU creates the file at realize time; open lazily on the first packet.
    }

    public synchronized void send(int type, int x, int y) {
        if (closed) {
            return;
        }
        byte[] b = {
                (byte) type,
                (byte) (x & 0xff), (byte) ((x >> 8) & 0xff),
                (byte) (y & 0xff), (byte) ((y >> 8) & 0xff)
        };
        try {
            if (out == null) {
                File dir = file.getParentFile();
                if (dir != null && !dir.isDirectory() && !dir.mkdirs()) {
                    return;
                }
                out = new RandomAccessFile(file, "rw");
            }
            out.seek(0);
            out.write(b);
        } catch (IOException e) {
            closeFile();
        }
    }

    private void closeFile() {
        RandomAccessFile f = out;
        out = null;
        if (f != null) {
            try {
                f.close();
            } catch (IOException ignored) {
            }
        }
    }

    public synchronized void close() {
        closed = true;
        closeFile();
    }
}
