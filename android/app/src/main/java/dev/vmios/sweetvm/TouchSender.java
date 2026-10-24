package dev.vmios.sweetvm;

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
    private final byte[] rec = new byte[5];
    private RandomAccessFile out;
    private boolean closed;
    private long lastMove;

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
        // Android delivers moves at up to 120 Hz and every send is two
        // syscalls on the UI thread. The guest polls at its own rate, so drop
        // intermediate moves; downs and ups always go through.
        if (type == 2) {
            long now = System.nanoTime();
            if (now - lastMove < 8000000L) {
                return;
            }
            lastMove = now;
        }
        rec[0] = (byte) type;
        rec[1] = (byte) (x & 0xff);
        rec[2] = (byte) ((x >> 8) & 0xff);
        rec[3] = (byte) (y & 0xff);
        rec[4] = (byte) ((y >> 8) & 0xff);
        try {
            if (out == null) {
                File dir = file.getParentFile();
                if (dir != null && !dir.isDirectory() && !dir.mkdirs()) {
                    return;
                }
                out = new RandomAccessFile(file, "rw");
            }
            out.seek(0);
            out.write(rec);
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
