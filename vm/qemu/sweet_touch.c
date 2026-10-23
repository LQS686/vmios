/*
 * sweet-touch: a minimal Qualcomm GENI SE7 + Goodix GT9896 model for the
 * SWEET touch driver (bsd/dev/sweet_touch.c).
 *
 * The driver is polled: it maps GCC (0x00100000), TLMM (0x03900000) and
 * SE7 (0x00a84000), initializes the FIFO I2C engine itself and then talks
 * I2C to the IC at 0x5d.  This device implements enough of those three
 * register files to let that unchanged driver probe a synthetic GT9896 and
 * read touch reports.  The host side is a 5-byte packet stream over a
 * chardev socket:
 *
 *      type (0=up, 1=down, 2=move), x LE16, y LE16
 *
 * The same 5-byte record can be supplied through a host file with the
 * touchfile property; it is pread before each touch report, avoiding chardev
 * flow control. The Android app uses that path.
 *
 * The driver's RPMh LDO vote is expected to be stubbed by
 * tools/patch-qemu-input.py; no RPMh block is modelled.
 */
#include "qemu/osdep.h"
#include "qapi/error.h"
#include "hw/sysbus.h"
#include "hw/qdev-properties.h"
#include "hw/qdev-properties-system.h"
#include "chardev/char-fe.h"
#include "qemu/log.h"
#include "qemu/module.h"
#include "qemu/thread.h"
#include <fcntl.h>
#include <unistd.h>

#define TYPE_SWEET_TOUCH "sweet-touch"
OBJECT_DECLARE_SIMPLE_TYPE(SweetTouchState, SWEET_TOUCH)

#define GCC_BASE  0x00100000u
#define GCC_SIZE  0x00060000u
#define TLMM_BASE 0x03900000u
#define TLMM_SIZE 0x0005b000u
#define SE_BASE   0x00a84000u
#define SE_SIZE   0x00004000u

#define SE_STATUS     0x040
#define SE_FW         0x068
#define SE_DMA        0x258
#define SE_TX_LEN     0x26c
#define SE_RX_LEN     0x270
#define SE_CMD        0x600
#define SE_CTRL       0x604
#define SE_IRQ        0x610
#define SE_IRQ_EN     0x614
#define SE_IRQ_CLR    0x618
#define SE_TX         0x700
#define SE_RX         0x780
#define SE_TX_COUNT   0x800
#define SE_RX_COUNT   0x804
#define SE_TX_WM      0x80c
#define SE_HW_TX      0xe24
#define SE_HW_RX      0xe28

#define IRQ_DONE      (1u << 0)
#define IRQ_ABORT     (1u << 5)
#define IRQ_RX_WM     (1u << 26)
#define IRQ_RX_LAST   (1u << 27)
#define IRQ_TX_WM     (1u << 30)

#define RX_MAX        128
#define TX_MAX        16

struct SweetTouchState {
    SysBusDevice parent_obj;

    MemoryRegion gcc;
    MemoryRegion tlmm;
    MemoryRegion se;
    CharBackend chr;

    uint32_t *gcc_regs;
    uint32_t *tlmm_regs;
    uint32_t *se_regs;
    QemuMutex lock;

    uint32_t irq;
    uint32_t pointer;
    uint32_t tx_expected;
    uint32_t rx_expected;
    uint8_t tx[TX_MAX];
    unsigned tx_len;
    uint8_t rx[RX_MAX];
    unsigned rx_len;
    unsigned rx_pos;
    uint32_t rx_words;

    bool touch_down;
    uint16_t touch_x;
    uint16_t touch_y;
    int touch_fd;
    uint8_t touch_raw[5];
    char *touchfile;

    uint8_t in[5];
    unsigned in_len;
};

static uint32_t se_read(SweetTouchState *s, uint32_t off)
{
    switch (off) {
    case SE_STATUS:
        return 0;
    case SE_FW:
        return 0x00000300;             /* firmware 3, 32-bit FIFOs */
    case SE_IRQ:
        return qatomic_read(&s->irq);
    case SE_TX_COUNT:
        return 0;
    case SE_RX_COUNT:
        return qatomic_read(&s->rx_words);
    case SE_TX:
        return 0;
    case SE_RX: {
        uint32_t w = 0;
        if (s->rx_words) {
            for (unsigned i = 0; i < 4 && s->rx_pos < s->rx_len; i++) {
                w |= (uint32_t)s->rx[s->rx_pos++] << (8 * i);
            }
            s->rx_words--;
        }
        return w;
    }
    case SE_HW_TX:
        return 0x20200000;             /* depth[29:24]=32, granularity[21:16]=32 */
    case SE_HW_RX:
        return 0x20200000;
    default:
        return s->se_regs[off >> 2];
    }
}

static void sweet_touch_sync_file(SweetTouchState *s)
{
    uint8_t b[5];
    if (s->touch_fd < 0 || pread(s->touch_fd, b, sizeof(b), 0) != sizeof(b)) {
        return;
    }
    qemu_mutex_lock(&s->lock);
    if (memcmp(b, s->touch_raw, sizeof(b)) != 0) {
        uint16_t x = b[1] | (b[2] << 8);
        uint16_t y = b[3] | (b[4] << 8);
        memcpy(s->touch_raw, b, sizeof(b));
        s->touch_down = b[0] != 0;
        s->touch_x = x >= 1080 ? 1079 : x;
        s->touch_y = y >= 2400 ? 2399 : y;
    }
    qemu_mutex_unlock(&s->lock);
}

static void build_report(SweetTouchState *s, uint32_t nr)
{
    uint8_t b[RX_MAX];
    memset(b, 0, sizeof(b));
    if (nr > sizeof(b)) {
        nr = sizeof(b);
    }
    sweet_touch_sync_file(s);
    if (s->pointer == 0x4022) {
        b[0] = '9';
        b[1] = '8';
        b[2] = '9';
        b[3] = '6';
        b[8] = 0x01;
        b[9] = 0x02;
        b[10] = 0x03;
        b[11] = 0x04;
    } else if (s->pointer == 0x4180) {
        bool down;
        qemu_mutex_lock(&s->lock);
        down = s->touch_down;
        qemu_mutex_unlock(&s->lock);
        if (down) {
            b[0] = 0x80;
            b[2] = 1;
        }
        unsigned sum = 0;
        for (unsigned i = 0; i < 6; i++) {
            sum += b[i];
        }
        b[6] = (sum >> 8) & 0xff;
        b[7] = sum & 0xff;
    } else if (s->pointer == 0x4188) {
        uint16_t x, y;
        bool down;
        qemu_mutex_lock(&s->lock);
        down = s->touch_down;
        x = s->touch_x;
        y = s->touch_y;
        qemu_mutex_unlock(&s->lock);
        if (down) {
            b[2] = x >> 8;
            b[3] = x & 0xff;
            b[4] = y >> 8;
            b[5] = y & 0xff;
        }
        unsigned sum = 0;
        for (unsigned i = 0; i < 8; i++) {
            sum += b[i];
        }
        b[8] = (sum >> 8) & 0xff;
        b[9] = sum & 0xff;
    } else if (s->pointer == 0x38) {
        /* Keep the Focaltech probe from claiming the IC. */
    } else {
        /* 0x8240 and unknown registers read as zeros. */
    }
    s->rx_len = nr;
    s->rx_pos = 0;
    memcpy(s->rx, b, nr);
    s->rx_words = (nr + 3) / 4;
    qatomic_or(&s->irq, IRQ_DONE | IRQ_RX_WM | IRQ_RX_LAST);
}

static void tx_done(SweetTouchState *s)
{
    if (s->tx_expected == 3 && s->tx[0] == 0x41) {
        qatomic_or(&s->irq, IRQ_DONE);           /* Goodix ACK */
    } else if (s->tx_expected != 0) {
        s->pointer = (s->tx_expected >= 2)
                   ? ((uint32_t)s->tx[0] << 8) | s->tx[1]
                   : s->tx[0];
        qatomic_or(&s->irq, IRQ_DONE);
    }
    s->tx_len = 0;
    s->tx_expected = 0;
}

static uint64_t se_mmio_read(void *opaque, hwaddr off, unsigned size)
{
    SweetTouchState *s = opaque;
    if (off + 4 > SE_SIZE) {
        return 0;
    }
    return se_read(s, off);
}

static void se_mmio_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    SweetTouchState *s = opaque;
    uint32_t v = (uint32_t)val;

    if (off + 4 > SE_SIZE) {
        return;
    }
    switch (off) {
    case SE_IRQ_CLR:
        qatomic_and(&s->irq, ~v);
        break;
    case SE_CTRL:
        if (v == 2) {
            s->tx_len = 0;
            s->rx_len = 0;
            s->rx_pos = 0;
            s->rx_words = 0;
            qatomic_set(&s->irq, IRQ_ABORT);
        }
        break;
    case SE_TX_WM:
        if (v & 1) {
            qatomic_or(&s->irq, IRQ_TX_WM);
        } else {
            qatomic_and(&s->irq, ~IRQ_TX_WM);
        }
        break;
    case SE_TX_LEN:
        s->tx_expected = v;
        s->tx_len = 0;
        break;
    case SE_RX_LEN:
        s->rx_expected = v;
        break;
    case SE_CMD: {
        unsigned dir = (v >> 27) & 3;
        if (dir == 2) {
            build_report(s, s->rx_expected);
        } else {
            qatomic_or(&s->irq, IRQ_TX_WM);
        }
        break;
    }
    case SE_TX:
        for (unsigned i = 0; i < 4 && s->tx_len < s->tx_expected
                                && s->tx_len < TX_MAX; i++) {
            s->tx[s->tx_len++] = (v >> (8 * i)) & 0xff;
        }
        if (s->tx_len >= s->tx_expected) {
            tx_done(s);
        }
        break;
    default:
        s->se_regs[off >> 2] = v;
        break;
    }
}

static uint64_t gcc_mmio_read(void *opaque, hwaddr off, unsigned size)
{
    SweetTouchState *s = opaque;
    if (off + 4 > GCC_SIZE) {
        return 0;
    }
    uint32_t v = s->gcc_regs[off >> 2];
    if (off == 0x18148) {
        v &= ~1u; /* RCGR update bit self-clears when the clock is running */
    }
    return v;
}

static void gcc_mmio_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    SweetTouchState *s = opaque;
    if (off + 4 <= GCC_SIZE) {
        s->gcc_regs[off >> 2] = (uint32_t)val;
    }
}

static uint64_t tlmm_mmio_read(void *opaque, hwaddr off, unsigned size)
{
    SweetTouchState *s = opaque;
    if (off + 4 > TLMM_SIZE) {
        return 0;
    }
    return s->tlmm_regs[off >> 2];
}

static void tlmm_mmio_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    SweetTouchState *s = opaque;
    if (off + 4 <= TLMM_SIZE) {
        s->tlmm_regs[off >> 2] = (uint32_t)val;
    }
}

static const MemoryRegionOps gcc_ops = {
    .read = gcc_mmio_read, .write = gcc_mmio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};
static const MemoryRegionOps tlmm_ops = {
    .read = tlmm_mmio_read, .write = tlmm_mmio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};
static const MemoryRegionOps se_ops = {
    .read = se_mmio_read, .write = se_mmio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};

static void sweet_touch_receive(void *opaque, const uint8_t *buf, int size)
{
    SweetTouchState *s = opaque;
    for (int i = 0; i < size; i++) {
        s->in[s->in_len++] = buf[i];
        if (s->in_len == sizeof(s->in)) {
            uint8_t type = s->in[0];
            uint16_t x = s->in[1] | (s->in[2] << 8);
            uint16_t y = s->in[3] | (s->in[4] << 8);
            s->in_len = 0;
            if (x >= 1080) {
                x = 1079;
            }
            if (y >= 2400) {
                y = 2399;
            }
            qemu_mutex_lock(&s->lock);
            s->touch_down = type != 0;
            s->touch_x = x;
            s->touch_y = y;
            qemu_mutex_unlock(&s->lock);
        }
    }
    qemu_chr_fe_accept_input(&s->chr);
}

static void sweet_touch_realize(DeviceState *dev, Error **errp)
{
    SweetTouchState *s = SWEET_TOUCH(dev);
    SysBusDevice *sbd = SYS_BUS_DEVICE(dev);

    s->gcc_regs = g_new0(uint32_t, GCC_SIZE / 4);
    s->tlmm_regs = g_new0(uint32_t, TLMM_SIZE / 4);
    s->se_regs = g_new0(uint32_t, SE_SIZE / 4);
    qemu_mutex_init(&s->lock);
    s->touch_fd = -1;
    if (s->touchfile) {
        s->touch_fd = open(s->touchfile, O_RDWR | O_CREAT, 0600);
        if (s->touch_fd < 0) {
            fprintf(stderr, "sweet-touch: cannot open touchfile %s\n", s->touchfile);
        }
    }

    memory_region_init_io(&s->gcc, OBJECT(s), &gcc_ops, s,
                          "sweet-touch-gcc", GCC_SIZE);
    memory_region_init_io(&s->tlmm, OBJECT(s), &tlmm_ops, s,
                          "sweet-touch-tlmm", TLMM_SIZE);
    memory_region_init_io(&s->se, OBJECT(s), &se_ops, s,
                          "sweet-touch-se7", SE_SIZE);
    sysbus_init_mmio(sbd, &s->gcc);
    sysbus_init_mmio(sbd, &s->tlmm);
    sysbus_init_mmio(sbd, &s->se);
    sysbus_mmio_map(sbd, 0, GCC_BASE);
    sysbus_mmio_map(sbd, 1, TLMM_BASE);
    sysbus_mmio_map(sbd, 2, SE_BASE);

    qemu_chr_fe_set_handlers(&s->chr, NULL,
                             sweet_touch_receive, NULL, NULL, s, NULL, true);
    qemu_chr_fe_accept_input(&s->chr);
}

static void sweet_touch_unrealize(DeviceState *dev)
{
    SweetTouchState *s = SWEET_TOUCH(dev);
    if (s->touch_fd >= 0) {
        close(s->touch_fd);
    }
    qemu_mutex_destroy(&s->lock);
    g_free(s->gcc_regs);
    g_free(s->tlmm_regs);
    g_free(s->se_regs);
}

static Property sweet_touch_props[] = {
    DEFINE_PROP_CHR("chardev", SweetTouchState, chr),
    DEFINE_PROP_STRING("touchfile", SweetTouchState, touchfile),
    DEFINE_PROP_END_OF_LIST(),
};

static void sweet_touch_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    dc->desc = "SWEET GENI SE7 + Goodix GT9896 touch model";
    dc->realize = sweet_touch_realize;
    dc->unrealize = sweet_touch_unrealize;
    dc->user_creatable = true;
    device_class_set_props(dc, sweet_touch_props);
}

static const TypeInfo sweet_touch_info = {
    .name = TYPE_SWEET_TOUCH,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(SweetTouchState),
    .class_init = sweet_touch_class_init,
};

static void sweet_touch_register_types(void)
{
    type_register_static(&sweet_touch_info);
}

type_init(sweet_touch_register_types)
