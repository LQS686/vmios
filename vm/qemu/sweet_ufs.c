/*
 * sweet-ufs: a Qualcomm UFSHCI-shaped host for the SWEET XNU UFS driver.
 *
 * The driver in xnu/patches/0028-sweet-ufs-root-device.patch polls a single
 * UTRL slot and speaks SCSI READ(10)/WRITE(10) through a UCD containing a
 * COMMAND UPIU and a PRDT.  This device implements exactly that surface over
 * a flat HFS+ image.  The image is presented as GPT partition "userdata"
 * starting at LBA 34, so the unmodified iOS root image stays untouched.
 *
 *   -device sweet-ufs,file=/path/ios16-root.img,mmio-base=0xe000000
 *
 * Only the registers the driver touches are modelled.  All commands are
 * synchronous, which matches the driver's polled use.
 */
#include "qemu/osdep.h"
#include "qapi/error.h"
#include "hw/hw.h"
#include "hw/sysbus.h"
#include "hw/qdev-properties.h"
#include "exec/address-spaces.h"
#include "qemu/log.h"
#include "qemu/module.h"
#include <zlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

#define TYPE_SWEET_UFS "sweet-ufs"
OBJECT_DECLARE_SIMPLE_TYPE(SweetUFSState, SWEET_UFS)

#define SWEET_UFS_LBA           4096u
#define SWEET_UFS_GPT_LBAS      34u
#define SWEET_UFS_MMIO_SIZE     0x3000u
#define SWEET_UFS_BOUNCE_MAX    (1u << 20)

#define REG_CAP      0x00
#define REG_IS       0x20
#define REG_IE       0x24
#define REG_HCS      0x30
#define REG_HCE      0x34
#define REG_UTRLBA   0x50
#define REG_UTRLBAU  0x54
#define REG_UTRLDBR  0x58
#define REG_UTRLCLR  0x5c
#define REG_UTRLRSR  0x60

#define CAP_64AS     (1u << 24)
#define HCS_DP       (1u << 0)
#define HCS_UTRLRDY  (1u << 1)

struct SweetUFSState {
    SysBusDevice parent_obj;

    MemoryRegion mmio;
    char *file;
    uint64_t mmio_base;
    int fd;
    uint64_t file_size;
    uint64_t part_blocks;

    uint32_t reg_is;
    uint32_t reg_ie;
    uint32_t reg_hce;
    uint32_t reg_hcs;
    uint32_t reg_utrldbr;
    uint32_t reg_utrlrsr;
    uint64_t utrlba;

    uint8_t *gpt;
};

struct sweet_utrd {
    uint32_t dw0, dw1, dw2, dw3;
    uint32_t ucdba, ucdbau;
    uint32_t resp;
    uint32_t prdt;
} QEMU_PACKED;

static uint32_t get_le32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t get_le64(const uint8_t *p)
{
    return (uint64_t)get_le32(p) | (uint64_t)get_le32(p + 4) << 32;
}

static void put_le32(uint8_t *p, uint32_t v)
{
    p[0] = v;
    p[1] = v >> 8;
    p[2] = v >> 16;
    p[3] = v >> 24;
}

static void put_le64(uint8_t *p, uint64_t v)
{
    put_le32(p, (uint32_t)v);
    put_le32(p + 4, (uint32_t)(v >> 32));
}

static uint32_t get_be32(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 |
           (uint32_t)p[2] << 8 | (uint32_t)p[3];
}

static bool sweet_dma_read(hwaddr addr, void *buf, size_t len)
{
    return address_space_read(&address_space_memory, addr,
                              MEMTXATTRS_UNSPECIFIED, buf, len) == MEMTX_OK;
}

static bool sweet_dma_write(hwaddr addr, const void *buf, size_t len)
{
    return address_space_write(&address_space_memory, addr,
                               MEMTXATTRS_UNSPECIFIED, buf, len) == MEMTX_OK;
}

/*
 * Build a minimal valid GPT whose entries point at the raw image.  LBA 0-33
 * are synthesized; every read/write at or above LBA 34 maps to file offset 0.
 */
static void sweet_ufs_build_gpt(SweetUFSState *s)
{
    const uint64_t last = SWEET_UFS_GPT_LBAS + s->part_blocks - 1;
    uint8_t *mbr = s->gpt;
    uint8_t *hdr = s->gpt + SWEET_UFS_LBA;
    uint8_t *ents = s->gpt + 2 * SWEET_UFS_LBA;
    const uint8_t apple_hfs[16] = {
        0x00, 0x53, 0x46, 0x48, 0x00, 0x00, 0xaa, 0x11,
        0xaa, 0x11, 0x00, 0x30, 0x65, 0x43, 0xec, 0xac,
    };
    const uint8_t disk_guid[16] = {
        0x53, 0x57, 0x45, 0x45, 0x54, 0x55, 0x46, 0x53,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    };
    const uint8_t part_guid[16] = {
        0x53, 0x57, 0x45, 0x45, 0x54, 0x49, 0x4f, 0x53,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    };
    static const char name[] = "userdata";

    /* Protective MBR. */
    mbr[446 + 4] = 0xee;
    put_le32(mbr + 446 + 8, 1);
    put_le32(mbr + 446 + 12, s->part_blocks + SWEET_UFS_GPT_LBAS - 1 > UINT32_MAX
                             ? UINT32_MAX : (uint32_t)(s->part_blocks + SWEET_UFS_GPT_LBAS - 1));
    mbr[510] = 0x55;
    mbr[511] = 0xaa;

    /* GPT header. */
    memcpy(hdr, "EFI PART", 8);
    put_le32(hdr + 8, 0x00010000);
    put_le32(hdr + 12, 92);
    put_le32(hdr + 16, 0);              /* header CRC, patched below */
    put_le32(hdr + 20, 0);
    put_le64(hdr + 24, 1);
    put_le64(hdr + 32, last);
    put_le64(hdr + 40, SWEET_UFS_GPT_LBAS);
    put_le64(hdr + 48, last);
    memcpy(hdr + 56, disk_guid, 16);
    put_le64(hdr + 72, 2);
    put_le32(hdr + 80, 128);
    put_le32(hdr + 84, 128);
    put_le32(hdr + 88, 0);              /* entry array CRC, patched below */
    put_le32(hdr + 92, 0);
    put_le32(hdr + 16, 0);
    put_le32(hdr + 16, (uint32_t)crc32(0, hdr, 92));

    /* First entry: the whole image as Apple HFS+ (partition type GUID). */
    memcpy(ents, apple_hfs, 16);
    memcpy(ents + 16, part_guid, 16);
    put_le64(ents + 32, SWEET_UFS_GPT_LBAS);
    put_le64(ents + 40, last);
    put_le64(ents + 48, 0);
    for (unsigned i = 0; i < sizeof(name) - 1; i++) {
        ents[56 + 2 * i] = name[i];
    }
    put_le32(hdr + 88, (uint32_t)crc32(0, ents, 128 * 128));
    put_le32(hdr + 16, 0);
    put_le32(hdr + 16, (uint32_t)crc32(0, hdr, 92));
}

static bool sweet_ufs_read_lba(SweetUFSState *s, uint64_t lba, void *buf,
                               uint32_t count)
{
    uint8_t *out = buf;
    size_t len = (size_t)count * SWEET_UFS_LBA;

    if (lba + count <= SWEET_UFS_GPT_LBAS) {
        memcpy(out, s->gpt + lba * SWEET_UFS_LBA, len);
        return true;
    }
    if (lba < SWEET_UFS_GPT_LBAS || lba >= SWEET_UFS_GPT_LBAS + s->part_blocks) {
        return false;
    }
    uint64_t off = (lba - SWEET_UFS_GPT_LBAS) * SWEET_UFS_LBA;
    memset(out, 0, len);
    if (off < s->file_size) {
        size_t want = MIN(len, s->file_size - off);
        ssize_t got = pread(s->fd, out, want, off);
        if (got < 0 || (size_t)got != want) {
            return false;
        }
    }
    return true;
}

static bool sweet_ufs_write_lba(SweetUFSState *s, uint64_t lba,
                                const void *buf, uint32_t count)
{
    const uint8_t *in = buf;
    size_t len = (size_t)count * SWEET_UFS_LBA;

    if (lba < SWEET_UFS_GPT_LBAS || lba >= SWEET_UFS_GPT_LBAS + s->part_blocks) {
        return false;
    }
    uint64_t off = (lba - SWEET_UFS_GPT_LBAS) * SWEET_UFS_LBA;
    if (off + len > s->file_size) {
        return false;
    }
    while (len) {
        ssize_t got = pwrite(s->fd, in, len, off);
        if (got <= 0) {
            return false;
        }
        in += got;
        off += got;
        len -= got;
    }
    return true;
}

static void sweet_ufs_complete(SweetUFSState *s, hwaddr utrd_pa, hwaddr ucd_pa,
                               uint32_t resp_off, bool ok)
{
    uint8_t resp[512];

    memset(resp, 0, sizeof(resp));
    resp[0] = 0x21;                     /* RESPONSE UPIU */
    if (!ok) {
        resp[6] = 1;                    /* CHECK CONDITION */
        resp[7] = 0x04;                 /* hardware error */
    }
    sweet_dma_write(ucd_pa + resp_off, resp, sizeof(resp));

    uint32_t ocs = ok ? 0 : 1;
    sweet_dma_write(utrd_pa + 8, &ocs, sizeof(ocs));
    s->reg_utrldbr &= ~1u;
    s->reg_is |= 1u;
}

static void sweet_ufs_handle(SweetUFSState *s)
{
    struct sweet_utrd utrd;
    uint8_t upiu[32];
    uint8_t cdb[16];
    uint8_t *data = NULL;
    hwaddr utrd_pa = s->utrlba;
    hwaddr ucd_pa;
    uint32_t resp, prdt, xfer;
    bool ok = true;

    if (!(s->reg_utrlrsr & 1) || !sweet_dma_read(utrd_pa, &utrd, sizeof(utrd))) {
        s->reg_utrldbr &= ~1u;
        s->reg_is |= 1u;
        return;
    }
    ucd_pa = (hwaddr)utrd.ucdba | (hwaddr)utrd.ucdbau << 32;
    resp = utrd.resp >> 16;
    prdt = utrd.prdt;

    if (!sweet_dma_read(ucd_pa, upiu, sizeof(upiu)) ||
        !sweet_dma_read(ucd_pa + 16, cdb, sizeof(cdb))) {
        sweet_ufs_complete(s, utrd_pa, ucd_pa, resp * 4, false);
        return;
    }

    xfer = get_be32(upiu + 12);
    uint32_t direction = upiu[1] & 0x60;
    uint8_t op = cdb[0];
    uint64_t lba = 0;
    uint32_t count = 0;
    bool is_write = direction == 0x20;

    if (op == 0x28 || op == 0x2a) {
        lba = get_be32(cdb + 2);
        count = (uint32_t)cdb[7] << 8 | cdb[8];
        if (count == 0 || (uint64_t)count * SWEET_UFS_LBA > SWEET_UFS_BOUNCE_MAX ||
            xfer != count * SWEET_UFS_LBA) {
            ok = false;
        }
    }

    if (ok && (op == 0x28 || op == 0x2a) && xfer) {
        data = g_malloc0(xfer);
        uint32_t prdt_off = (prdt >> 16) * 4;
        uint32_t n = prdt & 0xffff;
        uint32_t done = 0;

        for (uint32_t i = 0; i < n && ok; i++) {
            uint8_t e[16];
            if (!sweet_dma_read(ucd_pa + prdt_off + 16 * i, e, sizeof(e))) {
                ok = false;
                break;
            }
            hwaddr addr = get_le64(e);
            uint32_t len = (get_le32(e + 12) & 0x3ffff) + 1;
            if (done + len > xfer) {
                ok = false;
                break;
            }
            if (is_write) {
                if (!sweet_dma_read(addr, data + done, len)) {
                    ok = false;
                }
            }
            done += len;
        }
        if (ok && done < xfer) {
            ok = false;
        }
        if (ok) {
            if (op == 0x28) {
                ok = sweet_ufs_read_lba(s, lba, data, count);
            } else if (op == 0x2a) {
                ok = sweet_ufs_write_lba(s, lba, data, count);
            }
        }
        if (ok && !is_write) {
            done = 0;
            for (uint32_t i = 0; i < n && ok; i++) {
                uint8_t e[16];
                if (!sweet_dma_read(ucd_pa + prdt_off + 16 * i, e, sizeof(e))) {
                    ok = false;
                    break;
                }
                hwaddr addr = get_le64(e);
                uint32_t len = (get_le32(e + 12) & 0x3ffff) + 1;
                if (!sweet_dma_write(addr, data + done, len)) {
                    ok = false;
                }
                done += len;
            }
        }
    } else if (ok && op == 0x25) {
        /* READ CAPACITY(10): last LBA and block size. */
        uint8_t cap[8];
        put_le32(cap, (uint32_t)(SWEET_UFS_GPT_LBAS + s->part_blocks - 1));
        put_le32(cap + 4, SWEET_UFS_LBA);
        uint32_t prdt_off = (prdt >> 16) * 4;
        uint8_t e[16];
        if (prdt && sweet_dma_read(ucd_pa + prdt_off, e, sizeof(e))) {
            ok = sweet_dma_write(get_le64(e), cap, sizeof(cap));
        }
    } else if (ok && op == 0x12) {
        /* INQUIRY: enough of a standard response for a block device. */
        uint8_t inq[36] = { 0 };
        inq[0] = 0x00;
        inq[2] = 0x05;
        inq[3] = 0x02;
        inq[4] = 31;
        memcpy(inq + 8, "SWEET   ", 8);
        memcpy(inq + 16, "iOS root        ", 16);
        memcpy(inq + 32, "0001", 4);
        uint32_t prdt_off = (prdt >> 16) * 4;
        uint8_t e[16];
        if (prdt && sweet_dma_read(ucd_pa + prdt_off, e, sizeof(e))) {
            uint32_t len = MIN(xfer, (uint32_t)sizeof(inq));
            ok = sweet_dma_write(get_le64(e), inq, len);
        }
    } else if (ok && op == 0x35) {
        fsync(s->fd);
    } else if (ok && op != 0x00) {
        /* Unsupported commands with no data are completed successfully. */
    }

    g_free(data);
    sweet_ufs_complete(s, utrd_pa, ucd_pa, resp * 4, ok);
}

static uint64_t sweet_ufs_read(void *opaque, hwaddr offset, unsigned size)
{
    SweetUFSState *s = opaque;

    switch (offset) {
    case REG_CAP:
        return CAP_64AS;
    case REG_IS:
        return s->reg_is;
    case REG_IE:
        return s->reg_ie;
    case REG_HCS:
        return HCS_DP | HCS_UTRLRDY;
    case REG_HCE:
        return s->reg_hce;
    case REG_UTRLBA:
        return (uint32_t)s->utrlba;
    case REG_UTRLBAU:
        return (uint32_t)(s->utrlba >> 32);
    case REG_UTRLDBR:
        return s->reg_utrldbr;
    case REG_UTRLCLR:
        return 0;
    case REG_UTRLRSR:
        return s->reg_utrlrsr;
    default:
        return 0;
    }
}

static void sweet_ufs_write(void *opaque, hwaddr offset, uint64_t value,
                            unsigned size)
{
    SweetUFSState *s = opaque;

    switch (offset) {
    case REG_IS:
        s->reg_is &= ~(uint32_t)value;
        break;
    case REG_IE:
        s->reg_ie = value;
        break;
    case REG_UTRLBA:
        s->utrlba = (s->utrlba & 0xffffffff00000000ULL) | (uint32_t)value;
        break;
    case REG_UTRLBAU:
        s->utrlba = (s->utrlba & 0xffffffffULL) | (uint64_t)(uint32_t)value << 32;
        break;
    case REG_UTRLDBR:
        s->reg_utrldbr |= (uint32_t)value;
        if (s->reg_utrldbr & 1) {
            sweet_ufs_handle(s);
        }
        break;
    case REG_UTRLCLR:
        s->reg_utrldbr &= ~(uint32_t)value;
        break;
    case REG_UTRLRSR:
        s->reg_utrlrsr = (uint32_t)value & 1;
        break;
    default:
        break;
    }
}

static const MemoryRegionOps sweet_ufs_ops = {
    .read = sweet_ufs_read,
    .write = sweet_ufs_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = {
        .min_access_size = 4,
        .max_access_size = 4,
    },
};

static void sweet_ufs_realize(DeviceState *dev, Error **errp)
{
    SweetUFSState *s = SWEET_UFS(dev);
    SysBusDevice *sbd = SYS_BUS_DEVICE(dev);
    struct stat st;

    if (!s->file) {
        error_setg(errp, "sweet-ufs: file= is required");
        return;
    }
    s->fd = qemu_open(s->file, O_RDWR, errp);
    if (s->fd < 0) {
        error_setg_errno(errp, errno, "sweet-ufs: cannot open %s", s->file);
        return;
    }
    if (fstat(s->fd, &st) < 0) {
        error_setg_errno(errp, errno, "sweet-ufs: fstat %s", s->file);
        close(s->fd);
        s->fd = -1;
        return;
    }
    s->file_size = st.st_size;
    s->part_blocks = s->file_size / SWEET_UFS_LBA;
    if (!s->part_blocks) {
        error_setg(errp, "sweet-ufs: %s is too small", s->file);
        close(s->fd);
        s->fd = -1;
        return;
    }
    s->gpt = g_malloc0(SWEET_UFS_GPT_LBAS * SWEET_UFS_LBA);
    sweet_ufs_build_gpt(s);

    s->reg_hce = 1;
    s->reg_hcs = HCS_DP | HCS_UTRLRDY;
    memory_region_init_io(&s->mmio, OBJECT(s), &sweet_ufs_ops, s,
                          "sweet-ufs", SWEET_UFS_MMIO_SIZE);
    sysbus_init_mmio(sbd, &s->mmio);
    sysbus_mmio_map(sbd, 0, s->mmio_base);
}

static void sweet_ufs_unrealize(DeviceState *dev)
{
    SweetUFSState *s = SWEET_UFS(dev);

    if (s->fd >= 0) {
        close(s->fd);
        s->fd = -1;
    }
    g_free(s->gpt);
    s->gpt = NULL;
}

static Property sweet_ufs_props[] = {
    DEFINE_PROP_STRING("file", SweetUFSState, file),
    DEFINE_PROP_UINT64("mmio-base", SweetUFSState, mmio_base, 0x0e000000),
    DEFINE_PROP_END_OF_LIST(),
};

static void sweet_ufs_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    dc->desc = "SWEET UFS host backed by an HFS+ image";
    dc->realize = sweet_ufs_realize;
    dc->unrealize = sweet_ufs_unrealize;
    dc->user_creatable = true;
    device_class_set_props(dc, sweet_ufs_props);
}

static const TypeInfo sweet_ufs_info = {
    .name = TYPE_SWEET_UFS,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(SweetUFSState),
    .class_init = sweet_ufs_class_init,
};

static void sweet_ufs_register_types(void)
{
    type_register_static(&sweet_ufs_info);
}

type_init(sweet_ufs_register_types)
