/*
 * Native triangle rasterizer for CaCompositor.
 *
 * The host-side compositor runs on ART. Debuggable APKs are not AOT-compiled
 * (command-line dexopt ends at status=verify), so the per-pixel Java loop
 * costs ~300 ns/px and a full-screen layer takes ~1 s. This is a direct port
 * of CaCompositor.triangle(): same edge functions, top-left rule, bilinear
 * sampling, source-over/blend-46 math and page-table addressing into the
 * shared guest RAM file.
 *
 * Large triangles are split into row bands and rasterized by 2-4 threads.
 * Bands own disjoint scanlines so they never race; the guest's TCG threads
 * are pinned to the big cluster and these threads run on the idle cores.
 */
#include <jni.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>

#define RAM_BASE 0x40000000ull

static uint8_t *g_ram;
static size_t g_ram_len;

JNIEXPORT jint JNICALL
Java_dev_vmios_sweetvm_CaCompositor_nativeInit(JNIEnv *env, jclass cls,
    jstring path, jlong length)
{
    (void)cls;
    if (g_ram != NULL) {
        return 1;
    }
    const char *p = (*env)->GetStringUTFChars(env, path, NULL);
    if (p == NULL) {
        return 0;
    }
    int fd = open(p, O_RDWR);
    (*env)->ReleaseStringUTFChars(env, path, p);
    if (fd < 0) {
        return 0;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        close(fd);
        return 0;
    }
    size_t len = (size_t)st.st_size;
    if (length > 0 && (size_t)length < len) {
        len = (size_t)length;
    }
    void *m = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (m == MAP_FAILED) {
        return 0;
    }
    g_ram = (uint8_t *)m;
    g_ram_len = len;
    return 1;
}

static inline float
edge(float ax, float ay, float bx, float by, float px, float py)
{
    return (px - ax) * (by - ay) - (py - ay) * (bx - ax);
}

static inline int
top_left(float dx, float dy)
{
    return dy > 0.0f || (dy == 0.0f && dx < 0.0f);
}

static inline float
half_to_float(uint16_t bits)
{
    int sign = (bits >> 15) & 1;
    int expo = (bits >> 10) & 0x1f;
    int mant = bits & 0x3ff;
    float v;
    if (expo == 0) {
        v = (float)mant * 5.9604644775390625e-8f;
    } else if (expo == 31) {
        v = 65504.0f;
    } else {
        uint32_t scale_bits = (uint32_t)(expo - 15 + 127) << 23;
        float scale;
        memcpy(&scale, &scale_bits, sizeof(scale));
        v = (1.0f + (float)mant / 1024.0f) * scale;
    }
    return sign ? -v : v;
}

static inline void
sample(const int32_t *pixels, int w, int h, float u, float v, float *out)
{
    out[0] = out[1] = out[2] = out[3] = 1.0f;
    if (pixels == NULL || w <= 0 || h <= 0) {
        return;
    }
    if ((u > 1.5f || v > 1.5f) && u >= 0.0f && v >= 0.0f &&
        u <= (float)w + 0.5f && v <= (float)h + 0.5f) {
        u /= (float)w;
        v /= (float)h;
    }
    if (u < 0.0f) u = 0.0f;
    if (v < 0.0f) v = 0.0f;
    if (u > 0.999999f) u = 0.999999f;
    if (v > 0.999999f) v = 0.999999f;
    float fx = u * (float)w - 0.5f;
    float fy = v * (float)h - 0.5f;
    int ix = (int)floorf(fx);
    int iy = (int)floorf(fy);
    float ax = fx - (float)ix;
    float ay = fy - (float)iy;
    int x0 = ix < 0 ? 0 : (ix >= w ? w - 1 : ix);
    int x1 = (ix + 1 < 0) ? 0 : (ix + 1 >= w ? w - 1 : ix + 1);
    int y0 = iy < 0 ? 0 : (iy >= h ? h - 1 : iy);
    int y1 = (iy + 1 < 0) ? 0 : (iy + 1 >= h ? h - 1 : iy + 1);
    int32_t p00 = pixels[y0 * w + x0];
    int32_t p10 = pixels[y0 * w + x1];
    int32_t p01 = pixels[y1 * w + x0];
    int32_t p11 = pixels[y1 * w + x1];
    float w00 = (1.0f - ax) * (1.0f - ay);
    float w10 = ax * (1.0f - ay);
    float w01 = (1.0f - ax) * ay;
    float w11 = ax * ay;
    out[0] = (((p00 >> 16) & 0xff) * w00 + ((p10 >> 16) & 0xff) * w10 +
              ((p01 >> 16) & 0xff) * w01 + ((p11 >> 16) & 0xff) * w11) / 255.0f;
    out[1] = (((p00 >> 8) & 0xff) * w00 + ((p10 >> 8) & 0xff) * w10 +
              ((p01 >> 8) & 0xff) * w01 + ((p11 >> 8) & 0xff) * w11) / 255.0f;
    out[2] = (((p00) & 0xff) * w00 + ((p10) & 0xff) * w10 +
              ((p01) & 0xff) * w01 + ((p11) & 0xff) * w11) / 255.0f;
    out[3] = (((p00 >> 24) & 0xff) * w00 + ((p10 >> 24) & 0xff) * w10 +
              ((p01 >> 24) & 0xff) * w01 + ((p11 >> 24) & 0xff) * w11) / 255.0f;
}

static inline int
pack(float r, float g, float b, float a)
{
    int ri = r <= 0.0f ? 0 : (r >= 1.0f ? 255 : (int)(r * 255.0f));
    int gi = g <= 0.0f ? 0 : (g >= 1.0f ? 255 : (int)(g * 255.0f));
    int bi = b <= 0.0f ? 0 : (b >= 1.0f ? 255 : (int)(b * 255.0f));
    int ai = a <= 0.0f ? 0 : (a >= 1.0f ? 255 : (int)(a * 255.0f));
    return (ai << 24) | (ri << 16) | (gi << 8) | bi;
}

typedef struct {
    const jlong *pages;
    const int32_t *tp;
    uint32_t total;
    uint32_t page_shift;
    uint32_t page_mask;
    long alloc;
    int dst_bpr;
    int minx, maxx;
    int blend;
    int tex_w, tex_h;
    int positive;
    int solid;
    int textured;
    int texture_pixels;
    float inv;
    float d0x, d1x, d2x;
    int tl0, tl1, tl2;
    float ax, ay, bx, by, cx, cy;
    float au, av, bu, bv, cu, cv;
    float ar, ag, ab, aa;
    float br, bg, bb, ba;
    float cr, cg, cb, ca;
    float sr, sg, sb, sa;
    int opaque_solid;
    uint32_t opaque_px;
} RasterCtx;

static void
raster_band(const RasterCtx *c, int y0, int y1, long *out_covered)
{
    long covered = 0;
    const jlong *pages = c->pages;
    const int32_t *tp = c->tp;
    const uint32_t page_size = 1u << c->page_shift;
    const uint32_t page_mask = c->page_mask;
    float ax = c->ax, ay = c->ay, bx = c->bx, by = c->by;
    float cx = c->cx, cy = c->cy;
    for (int y = y0; y < y1; y++) {
        float py = (float)y + 0.5f;
        float e0 = edge(bx, by, cx, cy, (float)c->minx + 0.5f, py);
        float e1 = edge(cx, cy, ax, ay, (float)c->minx + 0.5f, py);
        float e2 = edge(ax, ay, bx, by, (float)c->minx + 0.5f, py);
        uint64_t row_offset = (uint64_t)y * (uint32_t)c->dst_bpr;
        int x = c->minx;
        while (x < c->maxx) {
            uint64_t pixel_offset = row_offset + (uint64_t)x * 4;
            if (c->alloc > 0 && pixel_offset + 4 > (uint64_t)c->alloc) {
                break;
            }
            uint32_t page = (uint32_t)(pixel_offset >> c->page_shift);
            if (page >= c->total) {
                break;
            }
            uint32_t within = (uint32_t)(pixel_offset & page_mask);
            int span = (c->maxx - x);
            int capacity = (int)((page_size - within) / 4);
            if (span > capacity) {
                span = capacity;
            }
            if (span <= 0) {
                break;
            }
            uint64_t pa = (uint64_t)pages[page];
            if (pa < RAM_BASE ||
                pa - RAM_BASE + within + 4 > g_ram_len) {
                break;
            }
            uint8_t *base = g_ram + (pa - RAM_BASE) + within;
            if (c->opaque_solid) {
                for (int i = 0; i < span; i++, x++) {
                    int in;
                    if (c->positive) {
                        in = (e0 > 0.0f || (e0 == 0.0f && c->tl0)) &&
                            (e1 > 0.0f || (e1 == 0.0f && c->tl1)) &&
                            (e2 > 0.0f || (e2 == 0.0f && c->tl2));
                    } else {
                        in = (e0 < 0.0f || (e0 == 0.0f && !c->tl0)) &&
                            (e1 < 0.0f || (e1 == 0.0f && !c->tl1)) &&
                            (e2 < 0.0f || (e2 == 0.0f && !c->tl2));
                    }
                    if (in) {
                        memcpy(base + (size_t)i * 4, &c->opaque_px,
                            sizeof(c->opaque_px));
                        covered++;
                    }
                    e0 += c->d0x;
                    e1 += c->d1x;
                    e2 += c->d2x;
                }
                continue;
            }
            for (int i = 0; i < span; i++, x++) {
                int in;
                if (c->positive) {
                    in = (e0 > 0.0f || (e0 == 0.0f && c->tl0)) &&
                        (e1 > 0.0f || (e1 == 0.0f && c->tl1)) &&
                        (e2 > 0.0f || (e2 == 0.0f && c->tl2));
                } else {
                    in = (e0 < 0.0f || (e0 == 0.0f && !c->tl0)) &&
                        (e1 < 0.0f || (e1 == 0.0f && !c->tl1)) &&
                        (e2 < 0.0f || (e2 == 0.0f && !c->tl2));
                }
                if (in) {
                    float w0 = e0 * c->inv;
                    float w1 = e1 * c->inv;
                    float w2 = e2 * c->inv;
                    float col_r, col_g, col_b, col_a;
                    if (c->solid) {
                        col_r = c->sr;
                        col_g = c->sg;
                        col_b = c->sb;
                        col_a = c->sa;
                    } else {
                        col_r = c->ar * w0 + c->br * w1 + c->cr * w2;
                        col_g = c->ag * w0 + c->bg * w1 + c->cg * w2;
                        col_b = c->ab * w0 + c->bb * w1 + c->cb * w2;
                        col_a = c->aa * w0 + c->ba * w1 + c->ca * w2;
                        if (c->textured) {
                            float u, vv;
                            if (c->texture_pixels) {
                                u = c->au * w0 + c->bu * w1 + c->cu * w2;
                                vv = c->av * w0 + c->bv * w1 + c->cv * w2;
                            } else {
                                u = c->au;
                                vv = c->av;
                            }
                            float s[4];
                            sample(tp, c->tex_w, c->tex_h, u, vv, s);
                            col_r *= s[0];
                            col_g *= s[1];
                            col_b *= s[2];
                            col_a *= s[3];
                        }
                        col_a = col_a > 1.0f ? 1.0f :
                            (col_a < 0.0f ? 0.0f : col_a);
                        col_r *= col_a;
                        col_g *= col_a;
                        col_b *= col_a;
                    }
                    uint32_t dp;
                    memcpy(&dp, base + (size_t)i * 4, sizeof(dp));
                    float dr = (dp & 0xff) / 255.0f;
                    float dg = ((dp >> 8) & 0xff) / 255.0f;
                    float db = ((dp >> 16) & 0xff) / 255.0f;
                    float da = ((dp >> 24) & 0xff) / 255.0f;
                    float inv_a = 1.0f - col_a;
                    float orr = col_r + dr * inv_a;
                    float og = col_g + dg * inv_a;
                    float ob = col_b + db * inv_a;
                    float oa = col_a + da * inv_a;
                    if (c->blend == 46) {
                        float l = 0.299f * dr + 0.587f * dg + 0.114f * db;
                        l = l < 0.0f ? 0.0f : (l > 1.0f ? 1.0f : l);
                        float l4 = l * l;
                        l4 *= l4;
                        float k = 1.0f - col_a * l4;
                        orr = col_r * l4 + dr * k;
                        og = col_g * l4 + dg * k;
                        ob = col_b * l4 + db * k;
                        oa = col_a * l4 + da * k;
                    }
                    uint32_t out = ((uint32_t)(oa >= 1.0f ? 255 :
                        oa * 255.0f) << 24) |
                        ((uint32_t)(orr >= 1.0f ? 255 :
                        orr * 255.0f) << 16) |
                        ((uint32_t)(og >= 1.0f ? 255 :
                        og * 255.0f) << 8) |
                        (uint32_t)(ob >= 1.0f ? 255 : ob * 255.0f);
                    memcpy(base + (size_t)i * 4, &out, sizeof(out));
                    covered++;
                }
                e0 += c->d0x;
                e1 += c->d1x;
                e2 += c->d2x;
            }
            if (x >= c->maxx) {
                break;
            }
        }
    }
    *out_covered = covered;
}

typedef struct {
    const RasterCtx *ctx;
    int y0, y1;
    long covered;
} RasterBand;

static void *
raster_thread(void *arg)
{
    RasterBand *band = (RasterBand *)arg;
    raster_band(band->ctx, band->y0, band->y1, &band->covered);
    return NULL;
}

JNIEXPORT jlong JNICALL
Java_dev_vmios_sweetvm_CaCompositor_nativeTriangle(JNIEnv *env, jclass cls,
    jlongArray jpages, jint total, jint page_shift, jlong alloc, jint dst_bpr,
    jint clip_x0, jint clip_y0, jint clip_x1, jint clip_y1, jint blend,
    jintArray jtex, jint tex_w, jint tex_h, jint textured, jfloatArray jverts)
{
    (void)cls;
    if (g_ram == NULL || jpages == NULL || jverts == NULL) {
        return 0;
    }
    jint page_len = (*env)->GetArrayLength(env, jpages);
    if (page_len < total) {
        return 0;
    }
    jlong *pages = (*env)->GetLongArrayElements(env, jpages, NULL);
    jfloat *v = (*env)->GetFloatArrayElements(env, jverts, NULL);
    jint *tex = NULL;
    if (jtex != NULL && textured) {
        tex = (*env)->GetIntArrayElements(env, jtex, NULL);
    }
    if (pages == NULL || v == NULL) {
        if (pages) (*env)->ReleaseLongArrayElements(env, jpages, pages, JNI_ABORT);
        if (v) (*env)->ReleaseFloatArrayElements(env, jverts, v, JNI_ABORT);
        return 0;
    }

    long covered = 0;
    do {
        float ax = v[0], ay = v[1], au = v[2], av = v[3];
        float ar = v[4], ag = v[5], ab = v[6], aa = v[7];
        float bx = v[8], by = v[9], bu = v[10], bv = v[11];
        float br = v[12], bg = v[13], bb = v[14], ba = v[15];
        float cx = v[16], cy = v[17], cu = v[18], cv = v[19];
        float cr = v[20], cg = v[21], cb = v[22], ca = v[23];
        float area = edge(ax, ay, bx, by, cx, cy);
        if (area == 0.0f) {
            break;
        }
        float minxf = fminf(ax, fminf(bx, cx));
        float maxxf = fmaxf(ax, fmaxf(bx, cx));
        float minyf = fminf(ay, fminf(by, cy));
        float maxyf = fmaxf(ay, fmaxf(by, cy));
        int minx = clip_x0 > (int)floorf(minxf) ? clip_x0 : (int)floorf(minxf);
        int maxx = clip_x1 < (int)ceilf(maxxf) ? clip_x1 : (int)ceilf(maxxf);
        int miny = clip_y0 > (int)floorf(minyf) ? clip_y0 : (int)floorf(minyf);
        int maxy = clip_y1 < (int)ceilf(maxyf) ? clip_y1 : (int)ceilf(maxyf);
        if (minx >= maxx || miny >= maxy) {
            break;
        }
        int solid = !textured && ar == br && ar == cr && ag == bg &&
            ag == cg && ab == bb && ab == cb && aa == ba && aa == ca;
        float sr = 0.0f, sg = 0.0f, sb = 0.0f, sa = 0.0f;
        if (solid) {
            sa = aa < 0.0f ? 0.0f : (aa > 1.0f ? 1.0f : aa);
            sr = ar * sa;
            sg = ag * sa;
            sb = ab * sa;
            if (sa <= 0.0f) {
                break;
            }
        }
        RasterCtx c;
        memset(&c, 0, sizeof(c));
        c.pages = pages;
        c.tp = tex;
        c.total = (uint32_t)total;
        c.page_shift = (uint32_t)page_shift;
        c.page_mask = (1u << page_shift) - 1;
        c.alloc = (long)alloc;
        c.dst_bpr = dst_bpr;
        c.minx = minx;
        c.maxx = maxx;
        c.blend = blend;
        c.tex_w = tex_w;
        c.tex_h = tex_h;
        c.positive = area > 0.0f;
        c.solid = solid;
        c.textured = textured;
        c.texture_pixels = textured &&
            !(au == bu && au == cu && av == bv && av == cv);
        c.inv = 1.0f / area;
        c.d0x = cy - by;
        c.d1x = ay - cy;
        c.d2x = by - ay;
        c.tl0 = top_left(cx - bx, cy - by);
        c.tl1 = top_left(ax - cx, ay - cy);
        c.tl2 = top_left(bx - ax, by - ay);
        c.ax = ax; c.ay = ay; c.bx = bx; c.by = by; c.cx = cx; c.cy = cy;
        c.au = au; c.av = av; c.bu = bu; c.bv = bv; c.cu = cu; c.cv = cv;
        c.ar = ar; c.ag = ag; c.ab = ab; c.aa = aa;
        c.br = br; c.bg = bg; c.bb = bb; c.ba = ba;
        c.cr = cr; c.cg = cg; c.cb = cb; c.ca = ca;
        c.sr = sr; c.sg = sg; c.sb = sb; c.sa = sa;
        c.opaque_solid = solid && sa >= 0.999f;
        if (c.opaque_solid) {
            int ri = (int)(sr * 255.0f + 0.5f);
            int gi = (int)(sg * 255.0f + 0.5f);
            int bi = (int)(sb * 255.0f + 0.5f);
            c.opaque_px = 0xff000000u | ((uint32_t)ri << 16) |
                ((uint32_t)gi << 8) | (uint32_t)bi;
        }
        int rows = maxy - miny;
        long area_px = (long)rows * (long)(maxx - minx);
        (void)area_px;
        int threads = 1; /* A/B: threading off */
        if (threads <= 1) {
            raster_band(&c, miny, maxy, &covered);
            break;
        }
        RasterBand bands[4];
        pthread_t th[4];
        int made = 0;
        int i;
        for (i = 0; i < threads; i++) {
            bands[i].ctx = &c;
            bands[i].y0 = miny + rows * i / threads;
            bands[i].y1 = miny + rows * (i + 1) / threads;
            bands[i].covered = 0;
        }
        for (i = 1; i < threads; i++) {
            if (pthread_create(&th[made], NULL, raster_thread,
                &bands[i]) == 0) {
                made++;
            } else {
                raster_band(&c, bands[i].y0, bands[i].y1,
                    &bands[i].covered);
            }
        }
        raster_band(&c, bands[0].y0, bands[0].y1, &bands[0].covered);
        for (i = 0; i < made; i++) {
            pthread_join(th[i], NULL);
        }
        for (i = 0; i < threads; i++) {
            covered += bands[i].covered;
        }
    } while (0);

    (*env)->ReleaseLongArrayElements(env, jpages, pages, JNI_ABORT);
    (*env)->ReleaseFloatArrayElements(env, jverts, v, JNI_ABORT);
    if (tex != NULL) {
        (*env)->ReleaseIntArrayElements(env, jtex, tex, JNI_ABORT);
    }
    return (jlong)covered;
}
