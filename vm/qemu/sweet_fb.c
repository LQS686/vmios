#include "qemu/osdep.h"
#include "hw/sysbus.h"
#include "hw/qdev-properties.h"
#include "exec/address-spaces.h"
#include "qemu/error-report.h"
#include "qemu/module.h"

#define TYPE_SWEET_FB "sweet-fb"
OBJECT_DECLARE_SIMPLE_TYPE(SweetFBState, SWEET_FB)

#define SWEET_FB_MMIO_SIZE       0x1000u
#define SWEET_FB_COMMAND_SIZE    0x40000u
#define SWEET_FB_HEADER_SIZE     32u
#define SWEET_FB_DESCRIPTOR_SIZE 16u
#define SWEET_FB_MAGIC           0x31424653u
#define SWEET_FB_MAX_DESCRIPTORS ((SWEET_FB_COMMAND_SIZE - SWEET_FB_HEADER_SIZE) / SWEET_FB_DESCRIPTOR_SIZE)
#define SWEET_FB_MAX_COPY        16384u
#define SWEET_FB_FRAME_SIZE      (1080u * 2400u * 4u)

struct SweetFBState {
    SysBusDevice parent_obj;
    MemoryRegion mmio;
    uint64_t mmio_base;
    uint64_t frame_base;
    uint64_t command_base;
    uint32_t completed;
    uint32_t status;
};

static uint32_t sweet_fb_get32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t sweet_fb_get64(const uint8_t *p)
{
    return (uint64_t)sweet_fb_get32(p) | (uint64_t)sweet_fb_get32(p + 4) << 32;
}

static void sweet_fb_put32(uint8_t *p, uint32_t value)
{
    p[0] = value;
    p[1] = value >> 8;
    p[2] = value >> 16;
    p[3] = value >> 24;
}

static bool sweet_fb_dma_read(hwaddr address, void *buffer, size_t length)
{
    return address_space_read(&address_space_memory, address,
                              MEMTXATTRS_UNSPECIFIED, buffer, length) == MEMTX_OK;
}

static bool sweet_fb_dma_write(hwaddr address, const void *buffer, size_t length)
{
    return address_space_write(&address_space_memory, address,
                               MEMTXATTRS_UNSPECIFIED, buffer, length) == MEMTX_OK;
}

static void sweet_fb_present(SweetFBState *s, uint32_t sequence)
{
    uint8_t header[SWEET_FB_HEADER_SIZE];
    uint8_t result[8];
    uint32_t count = 0;
    bool ok = sweet_fb_dma_read(s->command_base, header, sizeof(header));

    if (ok) {
        count = sweet_fb_get32(header + 4);
        ok = sweet_fb_get32(header) == SWEET_FB_MAGIC &&
             sweet_fb_get32(header + 8) == sequence &&
             count <= SWEET_FB_MAX_DESCRIPTORS;
    }

    uint8_t *descriptors = NULL;
    uint8_t *pixels = NULL;
    if (ok) {
        descriptors = g_malloc((size_t)count * SWEET_FB_DESCRIPTOR_SIZE);
        pixels = g_malloc(SWEET_FB_MAX_COPY);
        ok = sweet_fb_dma_read(s->command_base + SWEET_FB_HEADER_SIZE,
                               descriptors, (size_t)count * SWEET_FB_DESCRIPTOR_SIZE);
    }

    for (uint32_t i = 0; ok && i < count; i++) {
        const uint8_t *d = descriptors + i * SWEET_FB_DESCRIPTOR_SIZE;
        uint64_t source = sweet_fb_get64(d);
        uint32_t destination = sweet_fb_get32(d + 8);
        uint32_t length = sweet_fb_get32(d + 12);

        if (!length || length > SWEET_FB_MAX_COPY ||
            destination > SWEET_FB_FRAME_SIZE ||
            length > SWEET_FB_FRAME_SIZE - destination) {
            ok = false;
            break;
        }
        ok = sweet_fb_dma_read(source, pixels, length) &&
             sweet_fb_dma_write(s->frame_base + destination, pixels, length);
    }

    g_free(pixels);
    g_free(descriptors);
    s->completed = ok ? sequence : 0;
    s->status = ok ? 0 : 1;
    sweet_fb_put32(result, s->completed);
    sweet_fb_put32(result + 4, s->status);
    if (!sweet_fb_dma_write(s->command_base + 12, result, sizeof(result))) {
        s->completed = 0;
        s->status = 1;
    }
}

static uint64_t sweet_fb_read(void *opaque, hwaddr offset, unsigned size)
{
    SweetFBState *s = opaque;

    switch (offset) {
    case 0:
        return s->completed;
    case 4:
        return s->status;
    default:
        return 0;
    }
}

static void sweet_fb_write(void *opaque, hwaddr offset, uint64_t value,
                           unsigned size)
{
    SweetFBState *s = opaque;

    if (offset == 0) {
        sweet_fb_present(s, (uint32_t)value);
    }
}

static const MemoryRegionOps sweet_fb_ops = {
    .read = sweet_fb_read,
    .write = sweet_fb_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = {
        .min_access_size = 4,
        .max_access_size = 4,
    },
};

static void sweet_fb_realize(DeviceState *dev, Error **errp)
{
    SweetFBState *s = SWEET_FB(dev);
    SysBusDevice *sbd = SYS_BUS_DEVICE(dev);

    memory_region_init_io(&s->mmio, OBJECT(s), &sweet_fb_ops, s,
                          "sweet-fb", SWEET_FB_MMIO_SIZE);
    sysbus_init_mmio(sbd, &s->mmio);
    sysbus_mmio_map(sbd, 0, s->mmio_base);
}

static Property sweet_fb_props[] = {
    DEFINE_PROP_UINT64("mmio-base", SweetFBState, mmio_base, 0x0f000000),
    DEFINE_PROP_UINT64("frame-base", SweetFBState, frame_base, 0x9c000000),
    DEFINE_PROP_UINT64("command-base", SweetFBState, command_base, 0x9d000000),
    DEFINE_PROP_END_OF_LIST(),
};

static void sweet_fb_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    dc->desc = "SWEET native framebuffer present engine";
    dc->realize = sweet_fb_realize;
    dc->user_creatable = true;
    device_class_set_props(dc, sweet_fb_props);
}

static const TypeInfo sweet_fb_info = {
    .name = TYPE_SWEET_FB,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(SweetFBState),
    .class_init = sweet_fb_class_init,
};

static void sweet_fb_register_types(void)
{
    type_register_static(&sweet_fb_info);
}

type_init(sweet_fb_register_types)
