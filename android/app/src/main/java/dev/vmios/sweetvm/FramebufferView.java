package dev.vmios.sweetvm;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.util.AttributeSet;
import android.view.MotionEvent;
import android.view.View;

import java.nio.ByteBuffer;

/** Draws the 1080x2400 guest panel, letterboxed, from a double buffer. */
public final class FramebufferView extends View {
    private final Object lock = new Object();
    private Bitmap front;
    private Bitmap back;
    private boolean hasFrame;
    private final Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
    private final RectF dst = new RectF();

    public interface TouchListener {
        /** type: 0 up, 1 down, 2 move; x/y in the 1080x2400 guest panel. */
        void onGuestTouch(int type, int x, int y);
    }

    private TouchListener touchListener;

    public void setTouchListener(TouchListener l) {
        touchListener = l;
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        int w = getWidth();
        int h = getHeight();
        if (w == 0 || h == 0) {
            return true;
        }
        float scale = Math.min((float) w / Payload.FB_W, (float) h / Payload.FB_H);
        float left = (w - Payload.FB_W * scale) / 2f;
        float top = (h - Payload.FB_H * scale) / 2f;
        float gx = (e.getX() - left) / scale;
        float gy = (e.getY() - top) / scale;
        if (gx < 0 || gy < 0 || gx >= Payload.FB_W || gy >= Payload.FB_H) {
            return true;
        }
        int type;
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                type = 1;
                break;
            case MotionEvent.ACTION_MOVE:
                type = 2;
                break;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL:
                type = 0;
                break;
            default:
                return true;
        }
        TouchListener l = touchListener;
        if (l != null) {
            l.onGuestTouch(type, (int) gx, (int) gy);
        }
        return true;
    }

    public FramebufferView(Context c) {
        this(c, null);
    }

    public FramebufferView(Context c, AttributeSet a) {
        super(c, a);
        setBackgroundColor(Color.BLACK);
        front = Bitmap.createBitmap(Payload.FB_W, Payload.FB_H, Bitmap.Config.ARGB_8888);
        back = Bitmap.createBitmap(Payload.FB_W, Payload.FB_H, Bitmap.Config.ARGB_8888);
        front.setHasAlpha(false);
        back.setHasAlpha(false);
    }

    /** Called on the VM reader thread. */
    public void copyFromBuffer(ByteBuffer buffer) {
        buffer.position(0);
        buffer.limit(Payload.FB_STRIDE * Payload.FB_H);
        back.copyPixelsFromBuffer(buffer);
        back.setHasAlpha(false);
        synchronized (lock) {
            Bitmap t = front;
            front = back;
            back = t;
            hasFrame = true;
        }
        postInvalidate();
    }

    public boolean hasFrame() {
        synchronized (lock) {
            return hasFrame;
        }
    }

    @Override
    protected void onDraw(Canvas canvas) {
        int w = getWidth();
        int h = getHeight();
        canvas.drawColor(Color.BLACK);
        synchronized (lock) {
            if (front == null) {
                return;
            }
            float scale = Math.min((float) w / Payload.FB_W, (float) h / Payload.FB_H);
            float dw = Payload.FB_W * scale;
            float dh = Payload.FB_H * scale;
            float left = (w - dw) / 2f;
            float top = (h - dh) / 2f;
            dst.set(left, top, left + dw, top + dh);
            canvas.drawBitmap(front, null, dst, paint);
        }
    }
}
