/*
 * SweetMetal: probe Metal plugin for the SWEET virtual GPU.
 *
 * Metal loads /System/Library/Extensions/<MetalPluginName>.bundle, takes
 * MetalPluginClassName (or the principal class), then creates the device with
 * -initWithAcceleratorPort: and registers it with MTLAddDevice (Metal's
 * _MTLRegisterDevices). This class implements just enough to log that path
 * and then records every selector CoreAnimation sends, so the real device
 * can be grown from observed calls instead of guessed ones.
 *
 * Built by tools/build-sweetmetal.sh; installed into the guest root by the
 * kernel (SweetGPUInstaller) from the ADT bundle blob.
 */
typedef struct objc_class *Class;
typedef struct objc_selector *SEL;
typedef signed char BOOL;
typedef unsigned int io_object_t;
typedef void *id;
typedef struct objc_method *Method;
typedef void (*IMP)(void);

Class objc_getClass(const char *name);
Class object_getClass(id obj);
typedef struct objc_ivar *Ivar;
Ivar *class_copyIvarList(Class cls, unsigned int *outCount);
const char *ivar_getName(Ivar ivar);
long ivar_getOffset(Ivar ivar);
typedef unsigned int mach_port_t;
typedef int kern_return_t;
extern mach_port_t mach_task_self_;
kern_return_t mach_vm_read_overwrite(mach_port_t target_task,
    unsigned long long address, unsigned long long size,
    unsigned long long buffer, unsigned long long *outsize);
static void sweet_hex64(const char *tag, unsigned int index, const void *pointer);
Class class_getSuperclass(Class cls);
const char *class_getName(Class cls);
const char *object_getClassName(id obj);
Method *class_copyMethodList(Class cls, unsigned int *outCount);
Method class_getInstanceMethod(Class cls, SEL name);
IMP method_getImplementation(Method method);
IMP method_setImplementation(Method method, IMP imp);
SEL method_getName(Method method);
const char *method_getTypeEncoding(Method method);
BOOL class_addMethod(Class cls, SEL name, IMP imp, const char *types);
BOOL sel_isEqual(SEL a, SEL b);
void _objc_msgForward(void);
int strcmp(const char *a, const char *b);
void free(void *ptr);
void *malloc(unsigned long size);
void *calloc(unsigned long count, unsigned long size);
void *memcpy(void *dst, const void *src, unsigned long n);
void bzero(void *dst, unsigned long n);
SEL sel_registerName(const char *name);
const char *sel_getName(SEL sel);
const char *protocol_getName(id protocol);
id objc_msgSend(id self, SEL op, ...);
int open(const char *path, int flags, ...);
int read(int fd, void *buf, unsigned long count);
int close(int fd);
int dprintf(int fd, const char *format, ...);
int snprintf(char *str, unsigned long size, const char *format, ...);
int strncmp(const char *a, const char *b, unsigned long n);
void *dlopen(const char *path, int mode);
void *dlsym(void *handle, const char *name);
char *dlerror(void);
int usleep(unsigned int usec);
int pthread_create(void *thread, const void *attr, void *(*start)(void *), void *arg);
void *dispatch_get_global_queue(long identifier, unsigned long flags);
unsigned long long dispatch_time(unsigned long long when, long long delta);
void dispatch_after_f(unsigned long long when, void *queue, void *context,
    void (*work)(void *));
unsigned int _dyld_image_count(void);
const void *_dyld_get_image_header(unsigned int index);
const char *_dyld_get_image_name(unsigned int index);
int getpid(void);
char *strstr(const char *haystack, const char *needle);
int IOConnectCallStructMethod(unsigned int connection, unsigned int selector,
    const void *input, unsigned long inputSize, void *output,
    unsigned long *outputSize);
int IOConnectCallScalarMethod(unsigned int connection, unsigned int selector,
    const unsigned long long *input, unsigned int inputCount,
    unsigned long long *output, unsigned int *outputCount);
unsigned long long mach_absolute_time(void);
typedef struct { unsigned int numer, denom; } sweet_mach_timebase;
int mach_timebase_info(sweet_mach_timebase *info);
void *IOServiceMatching(const char *name);
unsigned int IOServiceGetMatchingService(unsigned int mainPort, void *matching);
int IOServiceOpen(unsigned int service, unsigned int owningTask,
    unsigned int type, unsigned int *connection);
int IOObjectRelease(unsigned int object);
unsigned int mach_task_self(void);

/*
 * Metal's _MTLRegisterDevices accepts the plugin class only if it is a
 * subclass of its expected device class. _MTLDevice is the pure Metal base;
 * MTLIOAccelDevice adds the IOGPU plumbing. Both variants are built so the
 * check can be identified without a kernel rebuild.
 */
#ifdef SWEETMETAL_ACCEL_BASE
__attribute__((objc_root_class))
@interface MTLIOAccelDevice {
	Class isa;
}
#define SWEET_BASE MTLIOAccelDevice
#else
__attribute__((objc_root_class))
@interface _MTLDevice {
	Class isa;
}
#define SWEET_BASE _MTLDevice
#endif
- (id)init;
- (id)retain;
- (void)release;
- (id)autorelease;
- (BOOL)respondsToSelector:(SEL)sel;
- (id)methodSignatureForSelector:(SEL)sel;
- (void)forwardInvocation:(id)invocation;
@end

@interface SweetMetalDevice : SWEET_BASE
- (id)initWithAcceleratorPort:(io_object_t)port;
- (id)name;
@end

static int console_fd = -1;
static id sweet_device_self;
static char sweet_lib_path[256];
static unsigned int sweet_accel_port;
static unsigned sweet_fill_logs;

static unsigned int
sweet_iosurface_id(id surface)
{
	static unsigned int (*get_id)(id);
	if (get_id == 0) {
		void *ios = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", 2);
		if (ios != 0) {
			get_id = (unsigned int (*)(id))dlsym(ios, "IOSurfaceGetID");
		}
	}
	return get_id != 0 && surface != 0 ? get_id(surface) : 0;
}

/* Open our own IOAcceleratorES user client; the Metal port dies at registration. */
static unsigned int
sweet_open_gpu_service(void)
{
	void *matching = IOServiceMatching("IOAcceleratorES");
	if (matching == 0) {
		return 0;
	}
	unsigned int service = IOServiceGetMatchingService(0, matching);
	if (service == 0) {
		return 0;
	}
	unsigned int connection = 0;
	int result = IOServiceOpen(service, mach_task_self(), 0, &connection);
	IOObjectRelease(service);
	return result == 0 ? connection : 0;
}

static unsigned int
sweet_channel(double value)
{
	if (value <= 0.0) {
		return 0;
	}
	if (value >= 1.0) {
		return 255;
	}
	return (unsigned int)(value * 255.0 + 0.5);
}

static void
sweet_log(const char *what, const char *sel)
{
	if (console_fd < 0) {
		console_fd = open("/dev/console", 1 /* O_WRONLY */);
	}
	if (console_fd >= 0) {
		dprintf(console_fd, "SWEETMETAL: %s%s%s\n", what,
		    sel ? " " : "", sel ? sel : "");
	}
}

static const char *
sweet_cstr(id string)
{
	if (string == 0) {
		return "(nil)";
	}
	const char *s = ((const char *(*)(id, SEL))objc_msgSend)(string,
	    sel_registerName("UTF8String"));
	return s ? s : "(null)";
}

static id
sweet_msg_id(id obj, const char *sel)
{
	return ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName(sel));
}

static unsigned long
sweet_msg_ul(id obj, const char *sel)
{
	return ((unsigned long (*)(id, SEL))objc_msgSend)(obj, sel_registerName(sel));
}

static id
sweet_msg_id_idx(id obj, const char *sel, unsigned long index)
{
	return ((id (*)(id, SEL, unsigned long))objc_msgSend)(obj,
	    sel_registerName(sel), index);
}

/*
 * CoreAnimation sets its uber-shader function constants by name on the real
 * MTLFunctionConstantValues object before handing it to our fake library, so
 * descriptor introspection cannot see them. Swizzle the real setters and log
 * the name/type/value at the moment CA stores them.
 */
static IMP sweet_cv_index_imp;
static IMP sweet_cv_name_imp;
static unsigned sweet_cv_hooked;

static void
sweet_cv_report(const char *kind, const char *name, unsigned long index,
    unsigned long type, const void *value)
{
	unsigned int raw = 0;
	float f = 0.0f;
	int s = 0;
	if (value != 0) {
		memcpy(&raw, value, sizeof(raw));
		memcpy(&f, value, sizeof(f));
		memcpy(&s, value, sizeof(s));
	}
	if (console_fd < 0) {
		console_fd = open("/dev/console", 1);
	}
	dprintf(console_fd,
	    "SWEETMETAL: cvset %s name=%s idx=%lu type=%lu u=%u s=%d f=%g hex=%#x",
	    kind, name, index, type, raw, s, (double)f, raw);
	dprintf(console_fd, "%c", 10);
}

static void
sweet_cv_set_index(id self, SEL _cmd, const void *value, unsigned long type,
    unsigned long index)
{
	sweet_cv_report("byindex", "-", index, type, value);
	if (sweet_cv_index_imp != 0) {
		((void (*)(id, SEL, const void *, unsigned long, unsigned long))
		    sweet_cv_index_imp)(self, _cmd, value, type, index);
	}
}

/* Last value written for each constant name; a function is created right
 * after CA fills a fresh set, so this table is that function's constants. */
#define SWEET_FC_MAX 64
typedef struct {
	char name[32];
	double value;
} SweetFcEntry;
typedef struct {
	int count;
	SweetFcEntry e[SWEET_FC_MAX];
} SweetFcSet;

static SweetFcSet sweet_fc;

static float sweet_half_to_float(unsigned short h);

static void
sweet_fc_store(const char *name, unsigned long type, const void *value)
{
	double d = 0.0;
	if (name == 0 || strcmp(name, "-") == 0) {
		return;
	}
	if (value != 0) {
		switch (type) {
		case 3: {	/* MTLDataTypeFloat */
			float f;
			memcpy(&f, value, sizeof(f));
			d = (double)f;
			break;
		}
		case 16: {	/* MTLDataTypeHalf */
			unsigned short h;
			memcpy(&h, value, sizeof(h));
			d = (double)sweet_half_to_float(h);
			break;
		}
		case 53: {	/* MTLDataTypeBool */
			d = (*(const unsigned char *)value) ? 1.0 : 0.0;
			break;
		}
		default: {
			unsigned int u;
			memcpy(&u, value, sizeof(u));
			d = (double)u;
			break;
		}
		}
	}
	for (int i = 0; i < sweet_fc.count; i++) {
		if (strcmp(sweet_fc.e[i].name, name) == 0) {
			sweet_fc.e[i].value = d;
			return;
		}
	}
	if (sweet_fc.count < SWEET_FC_MAX) {
		SweetFcEntry *e = &sweet_fc.e[sweet_fc.count++];
		unsigned long i = 0;
		while (name[i] != 0 && i + 1 < sizeof(e->name)) {
			e->name[i] = name[i];
			i++;
		}
		e->name[i] = 0;
		e->value = d;
	}
}

static void
sweet_cv_set_name(id self, SEL _cmd, const void *value, unsigned long type,
    id name)
{
	sweet_cv_report("byname", sweet_cstr(name), 0, type, value);
	sweet_fc_store(sweet_cstr(name), type, value);
	if (sweet_cv_name_imp != 0) {
		((void (*)(id, SEL, const void *, unsigned long, id))
		    sweet_cv_name_imp)(self, _cmd, value, type, name);
	}
}

static void
sweet_install_cv_hooks(void)
{
	static const char *classes[2] = {
		"MTLFunctionConstantValuesInternal",
		"MTLFunctionConstantValues"
	};
	if (sweet_cv_hooked == 3) {
		return;
	}
	for (unsigned i = 0; i < 2; i++) {
		Class cls = objc_getClass(classes[i]);
		if (cls == 0) {
			continue;
		}
		if ((sweet_cv_hooked & 1) == 0) {
			Method m = class_getInstanceMethod(cls,
			    sel_registerName("setConstantValue:type:atIndex:"));
			if (m != 0 && method_getImplementation(m) != (IMP)sweet_cv_set_index) {
				sweet_cv_index_imp = method_setImplementation(m,
				    (IMP)sweet_cv_set_index);
				sweet_cv_hooked |= 1;
				sweet_log("cv hook atIndex on", classes[i]);
			}
		}
		if ((sweet_cv_hooked & 2) == 0) {
			Method m = class_getInstanceMethod(cls,
			    sel_registerName("setConstantValue:type:withName:"));
			if (m != 0 && method_getImplementation(m) != (IMP)sweet_cv_set_name) {
				sweet_cv_name_imp = method_setImplementation(m,
				    (IMP)sweet_cv_set_name);
				sweet_cv_hooked |= 2;
				sweet_log("cv hook withName on", classes[i]);
			}
		}
	}
}

/*
 * The runtime builds an NSInvocation from this signature before calling
 * -forwardInvocation:. A zero-argument "@:" makes CoreFoundation's
 * forwarding path throw when the caller passed any argument, so lend unknown
 * selectors a wide object-argument signature instead.
 */
static id
sweet_generic_signature(void)
{
	static id signature;
	if (signature == 0) {
		signature = ((id (*)(id, SEL, const char *))objc_msgSend)(
		    (id)objc_getClass("NSMethodSignature"),
		    sel_registerName("signatureWithObjCTypes:"),
		    "@@:@@@@@@@@@@@@@@@@");
	}
	return signature;
}

static void
sweet_zero_return(id invocation)
{
	id signature = ((id (*)(id, SEL))objc_msgSend)(invocation,
	    sel_registerName("methodSignature"));
	unsigned long length = ((unsigned long (*)(id, SEL))objc_msgSend)(
	    signature, sel_registerName("methodReturnLength"));
	static unsigned char zero[256];
	if (length > 0 && length <= sizeof(zero)) {
		((void (*)(id, SEL, void *))objc_msgSend)(invocation,
		    sel_registerName("setReturnValue:"), zero);
	}
}

static int
sweet_lib_path_is(const char *p)
{
	unsigned long i = 0;
	if (p == 0) {
		return 0;
	}
	while (p[i] != 0 && i + 1 < sizeof(sweet_lib_path)) {
		sweet_lib_path[i] = p[i];
		i++;
	}
	sweet_lib_path[i] = 0;
	return 1;
}


static void
sweet_probe_now(const char *how)
{
	dprintf(console_fd, "SWEETMETAL: probe[%s] self=%p\n", how, (void *)0);
	void *metal = dlopen("/System/Library/Frameworks/Metal.framework/Metal", 2);
	if (metal == 0) {
		dprintf(console_fd, "SWEETMETAL: probe[%s] dlopen failed: %s\n",
		    how, dlerror());
		return;
	}
	id (*create_default)(void) = (id (*)(void))dlsym(metal,
	    "MTLCreateSystemDefaultDevice");
	id (*copy_all)(void) = (id (*)(void))dlsym(metal, "MTLCopyAllDevices");
	dprintf(console_fd, "SWEETMETAL: probe[%s] syms default=%d all=%d\n",
	    how, create_default != 0, copy_all != 0);

	id device = create_default ? create_default() : 0;
	dprintf(console_fd, "SWEETMETAL: probe[%s] default=%p name=%s\n",
	    how, device, device ? sweet_cstr(sweet_msg_id(device, "name")) : "(none)");

	if (copy_all) {
		id list = copy_all();
		unsigned long n = list ? sweet_msg_ul(list, "count") : 0;
		dprintf(console_fd, "SWEETMETAL: probe[%s] devices=%lu\n", how, n);
		for (unsigned long i = 0; i < n && i < 8; i++) {
			id d = sweet_msg_id_idx(list, "objectAtIndex:", i);
			dprintf(console_fd, "SWEETMETAL: probe[%s] device[%lu]=%p name=%s\n",
			    how, i, d, d ? sweet_cstr(sweet_msg_id(d, "name")) : "(nil)");
		}
	}
}

/*
 * _MTLAddDevice runs after this bundle's constructor, so ask Metal itself,
 * from inside backboardd, whether the device ended up in its device list.
 */
static void *
sweet_probe_thread(void *unused)
{
	(void)unused;
	sweet_log("probe", "thread running");
	usleep(3000000);
	sweet_probe_now("thread");
	return 0;
}

static void
sweet_probe_work(void *context)
{
	(void)context;
	sweet_log("probe", "queue running");
	usleep(3000000);
	sweet_probe_now("queue");
}

/*
 * The panel is IOSurface id 1. Writing it proves the default-surface lookup
 * and mapping work from a CA process; a nil lookup explains a frozen panel.
 */
static void
sweet_probe_panel(void)
{
	void *ios = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", 2);
	if (ios == 0) {
		sweet_log("panel", "no IOSurface.framework");
		return;
	}
	id (*lookup)(unsigned int) = (id (*)(unsigned int))dlsym(ios, "IOSurfaceLookup");
	unsigned long (*get_width)(id) = (unsigned long (*)(id))dlsym(ios, "IOSurfaceGetWidth");
	unsigned long (*get_height)(id) = (unsigned long (*)(id))dlsym(ios, "IOSurfaceGetHeight");
	unsigned long (*get_bpr)(id) = (unsigned long (*)(id))dlsym(ios, "IOSurfaceGetBytesPerRow");
	void *(*get_base)(id) = (void *(*)(id))dlsym(ios, "IOSurfaceGetBaseAddress");
	int (*lock)(id, unsigned long, unsigned int *) =
	    (int (*)(id, unsigned long, unsigned int *))dlsym(ios, "IOSurfaceLock");
	int (*unlock)(id, unsigned long, unsigned int *) =
	    (int (*)(id, unsigned long, unsigned int *))dlsym(ios, "IOSurfaceUnlock");

	if (lookup == 0 || get_base == 0 || lock == 0 || unlock == 0) {
		sweet_log("panel", "missing IOSurface symbols");
		return;
	}
	id surface = lookup(1);
	dprintf(console_fd, "SWEETMETAL: panel pid=%d surface=%p %lux%lu bpr=%lu\n",
	    getpid(), surface, surface ? get_width(surface) : 0,
	    surface ? get_height(surface) : 0, surface ? get_bpr(surface) : 0);
	if (surface == 0) {
		return;
	}
	unsigned int seed = 0;
	if (lock(surface, 0, &seed) != 0) {
		sweet_log("panel", "lock failed");
		return;
	}
	unsigned char *base = (unsigned char *)get_base(surface);
	unsigned long bpr = get_bpr(surface);
	unsigned long width = get_width(surface);
	unsigned long height = get_height(surface);
	dprintf(console_fd, "SWEETMETAL: panel base=%p %lux%lu bpr=%lu\n",
	    base, width, height, bpr);
	unlock(surface, 0, &seed);

	/* End-to-end self-test: ask the host GPU to paint 200x200 on the panel. */
	if (sweet_accel_port != 0) {
		unsigned int request[6] = { 1, 0x00ff00ff, 0, 0, 200, 200 };
		unsigned long output_size = 0;
		int result = IOConnectCallStructMethod(sweet_accel_port, 0x100,
		    request, sizeof(request), 0, &output_size);
		dprintf(console_fd,
		    "SWEETMETAL: panel fill via gpu service -> 0x%x port=%u\n",
		    result, sweet_accel_port);
	}
}

/*
 * The compositor's render target is an IOSurface owned by this process. Map it
 * once per render pass so draw input can be turned into pixels; the kernel's
 * present path copies the surface onto the panel unchanged.
 */
typedef struct {
	id surface;
	unsigned char *base;
	unsigned long width, height, bytes_per_row;
} SweetSurfaceMapping;

static void *sweet_iosurface_library;

static void *
sweet_iosurface_symbol(const char *name)
{
	if (sweet_iosurface_library == 0) {
		sweet_iosurface_library = dlopen(
		    "/System/Library/Frameworks/IOSurface.framework/IOSurface", 2);
	}
	return sweet_iosurface_library != 0 ?
	    dlsym(sweet_iosurface_library, name) : 0;
}

static int
sweet_surface_map(unsigned int identifier, SweetSurfaceMapping *mapping)
{
	bzero(mapping, sizeof(*mapping));
	if (identifier == 0) {
		return -1;
	}
	id (*lookup)(unsigned int) = (id (*)(unsigned int))
	    sweet_iosurface_symbol("IOSurfaceLookup");
	int (*lock)(id, unsigned int, unsigned int *) = (int (*)(id, unsigned int,
	    unsigned int *))sweet_iosurface_symbol("IOSurfaceLock");
	void *(*base)(id) = (void *(*)(id))
	    sweet_iosurface_symbol("IOSurfaceGetBaseAddress");
	unsigned long (*width)(id) = (unsigned long (*)(id))
	    sweet_iosurface_symbol("IOSurfaceGetWidth");
	unsigned long (*height)(id) = (unsigned long (*)(id))
	    sweet_iosurface_symbol("IOSurfaceGetHeight");
	unsigned long (*bpr)(id) = (unsigned long (*)(id))
	    sweet_iosurface_symbol("IOSurfaceGetBytesPerRow");
	if (lookup == 0 || lock == 0 || base == 0 || width == 0 || height == 0 ||
	    bpr == 0) {
		return -1;
	}
	id surface = lookup(identifier);
	if (surface == 0) {
		return -1;
	}
	unsigned int seed = 0;
	if (lock(surface, 0, &seed) != 0) {
		return -1;
	}
	mapping->surface = surface;
	mapping->base = (unsigned char *)base(surface);
	mapping->width = width(surface);
	mapping->height = height(surface);
	mapping->bytes_per_row = bpr(surface);
	if (mapping->base == 0) {
		mapping->surface = 0;
		return -1;
	}
	return 0;
}

static void
sweet_surface_unmap(SweetSurfaceMapping *mapping)
{
	if (mapping->surface != 0) {
		int (*unlock)(id, unsigned int, unsigned int *) = (int (*)(id,
		    unsigned int, unsigned int *))
		    sweet_iosurface_symbol("IOSurfaceUnlock");
		if (unlock != 0) {
			unsigned int seed = 0;
			unlock(mapping->surface, 0, &seed);
		}
		void (*release_surface)(id) = (void (*)(id))
		    sweet_iosurface_symbol("IOSurfaceRelease");
		if (release_surface != 0) {
			release_surface(mapping->surface);
		}
		bzero(mapping, sizeof(*mapping));
	}
}

static void
sweet_surface_fill(SweetSurfaceMapping *mapping, unsigned int rgba)
{
	if (mapping->base == 0) {
		return;
	}
	for (unsigned long y = 0; y < mapping->height; y++) {
		unsigned int *row = (unsigned int *)(mapping->base +
		    y * mapping->bytes_per_row);
		for (unsigned long x = 0; x < mapping->width; x++) {
			row[x] = rgba;
		}
	}
}

/*
 * Host-side rasterization.
 *
 * This process runs under TCG, where CA's per-pixel fragment work costs
 * microseconds per pixel. The draws themselves are simple (position, texcoord,
 * colour, src-over), and the host owns the guest RAM file, so the plugin
 * forwards each batch as canonical 8-float vertices plus a page map for every
 * surface involved. The host rasterizes into the real pages and the kernel's
 * present path then copies them to the panel unchanged.
 *
 * Draws are queued; a flush barrier at the end of the encoder waits for the
 * host so the drawable is complete before the swap record is sent. Anything
 * the host cannot address (heap textures, physically unmapped surfaces, a
 * broken transport) stays on the local rasterizer.
 */
#define SWEET_CA_F_TEXTURED 1
#define SWEET_CA_F_UPLOAD_TEX 2
#define SWEET_CA_F_INTERNAL 4
#define SWEET_CA_F_TEX_CHUNK 8

struct sweet_ca_header {
	unsigned int flags;
	unsigned int dst_id, dst_w, dst_h, dst_bpr;
	unsigned int tex_id, tex_w, tex_h, tex_bpr, tex_fmt;
	int clip_x0, clip_y0, clip_x1, clip_y1;
	unsigned int blend_fn;
	unsigned int tri_count;
	unsigned int chunk_index, chunk_count;
	unsigned int tex_chunk_index, tex_chunk_count;
	unsigned int tex_bytes;
	unsigned int reserved;
};

struct sweet_ca_vertex {
	float x, y, u, v;
	float r, g, b, a;
};

#define SWEET_CA_TRIS_PER_CHUNK 40
#define SWEET_CA_UPLOAD_BYTES 3800
#define SWEET_CA_MAX_UPLOAD (2u << 20)
#define SWEET_CA_MAP_SLOTS 64

typedef struct {
	unsigned int id;
	unsigned int first_lo, first_hi;
	unsigned int alloc_lo, alloc_hi;
} SweetCAHostMap;

static SweetCAHostMap sweet_ca_maps[SWEET_CA_MAP_SLOTS];
static unsigned int sweet_ca_map_next;
static unsigned int sweet_ca_upload_ids = 0x80000000u;
static unsigned int sweet_ca_sequence;
static unsigned int sweet_ca_pending;
static unsigned int sweet_ca_submitted;
static unsigned int sweet_ca_local;
static unsigned int sweet_ca_flushes;
static unsigned int sweet_ca_failures;
static unsigned int sweet_ca_disabled;
static unsigned int sweet_ca_logs;
static volatile int sweet_ca_gate;

static void
sweet_ca_enter(void)
{
	while (__sync_lock_test_and_set(&sweet_ca_gate, 1)) {
	}
}

static void
sweet_ca_leave(void)
{
	__sync_lock_release(&sweet_ca_gate);
}

/*
 * Register a surface with the host: the kernel streams the surface's 16 KiB
 * page table over the wire and returns the identity the plugin caches. The
 * cache is dropped on every flush so a recycled surface id can never alias an
 * old physical mapping.
 */
static int
sweet_ca_map(unsigned int identifier)
{
	if (identifier == 0 || sweet_accel_port == 0) {
		return 0;
	}
	for (unsigned int i = 0; i < SWEET_CA_MAP_SLOTS; i++) {
		if (sweet_ca_maps[i].id == identifier) {
			return 1;
		}
	}
	unsigned int input = identifier;
	unsigned int output[6];
	unsigned long output_size = sizeof(output);
	int result = IOConnectCallStructMethod(sweet_accel_port, 0x104, &input,
	    sizeof(input), output, &output_size);
	if (result != 0 || output_size < sizeof(output) || output[0] == 0) {
		if (sweet_ca_logs < 8) {
			sweet_ca_logs++;
			dprintf(console_fd,
			    "SWEETMETAL: host map %u failed 0x%x%c", identifier,
			    result, 10);
		}
		return 0;
	}
	SweetCAHostMap *entry = &sweet_ca_maps[sweet_ca_map_next++ %
	    SWEET_CA_MAP_SLOTS];
	entry->id = identifier;
	entry->first_lo = output[4];
	entry->first_hi = output[5];
	entry->alloc_lo = output[2];
	entry->alloc_hi = output[3];
	if (sweet_ca_logs < 8) {
		sweet_ca_logs++;
		dprintf(console_fd,
		    "SWEETMETAL: host map %u pages=%u alloc=%u pa=0x%x%08x%c",
		    identifier, output[1], output[2], output[5], output[4], 10);
	}
	return 1;
}

/* One wire message: 4-byte sequence, 4 bytes of padding, payload. */
static int
sweet_ca_send(const void *payload, unsigned long bytes)
{
	static unsigned char buffer[8 + 4000];
	if (sweet_accel_port == 0 || bytes > 4000) {
		return -1;
	}
	sweet_ca_enter();
	if (sweet_ca_disabled) {
		sweet_ca_leave();
		return -1;
	}
	unsigned int sequence = ++sweet_ca_sequence;
	memcpy(buffer, &sequence, 4);
	bzero(buffer + 4, 4);
	memcpy(buffer + 8, payload, bytes);
	unsigned long output_size = 0;
	int result = IOConnectCallStructMethod(sweet_accel_port, 0x101, buffer,
	    8 + bytes, 0, &output_size);
	sweet_ca_leave();
	if (result != 0) {
		sweet_ca_failures++;
		if (sweet_ca_failures > 2) {
			sweet_ca_disabled = 1;
		}
		return -1;
	}
	sweet_ca_pending++;
	return 0;
}

static void
sweet_ca_flush(void)
{
	if (sweet_ca_pending == 0 || sweet_accel_port == 0 ||
	    sweet_ca_disabled) {
		bzero(sweet_ca_maps, sizeof(sweet_ca_maps));
		sweet_ca_pending = 0;
		return;
	}
	unsigned int sequence = sweet_ca_sequence;
	unsigned long output_size = 0;
	int result = IOConnectCallStructMethod(sweet_accel_port, 0x103,
	    &sequence, sizeof(sequence), 0, &output_size);
	sweet_ca_flushes++;
	if (result != 0) {
		sweet_ca_failures++;
		if (sweet_ca_failures > 2) {
			sweet_ca_disabled = 1;
		}
		if (sweet_ca_logs < 16) {
			sweet_ca_logs++;
			dprintf(console_fd,
			    "SWEETMETAL: host flush seq %u failed 0x%x%c",
			    sequence, result, 10);
		}
	}
	sweet_ca_pending = 0;
	bzero(sweet_ca_maps, sizeof(sweet_ca_maps));
}

static int
sweet_ca_upload(unsigned int identifier, unsigned int format,
    unsigned long width, unsigned long height, unsigned long bytes_per_row,
    const unsigned char *pixels, unsigned long size, unsigned int flags)
{
	if (pixels == 0 || size == 0 || size > SWEET_CA_MAX_UPLOAD) {
		return 0;
	}
	unsigned long chunks = (size + SWEET_CA_UPLOAD_BYTES - 1) /
	    SWEET_CA_UPLOAD_BYTES;
	unsigned char message[4000];
	for (unsigned long chunk = 0; chunk < chunks; chunk++) {
		unsigned long offset = chunk * SWEET_CA_UPLOAD_BYTES;
		unsigned long bytes = size - offset;
		if (bytes > SWEET_CA_UPLOAD_BYTES) {
			bytes = SWEET_CA_UPLOAD_BYTES;
		}
		struct sweet_ca_header header;
		bzero(&header, sizeof(header));
		header.flags = flags | SWEET_CA_F_TEX_CHUNK;
		header.tex_id = identifier;
		header.tex_w = (unsigned int)width;
		header.tex_h = (unsigned int)height;
		header.tex_bpr = (unsigned int)bytes_per_row;
		header.tex_fmt = format;
		header.tex_chunk_index = (unsigned int)chunk;
		header.tex_chunk_count = (unsigned int)chunks;
		header.tex_bytes = (unsigned int)size;
		memcpy(message, &header, sizeof(header));
		memcpy(message + sizeof(header), pixels + offset, bytes);
		if (sweet_ca_send(message, sizeof(header) + bytes) != 0) {
			return 0;
		}
	}
	return 1;
}

/*
 * CoreAnimation renders into a drawable IOSurface, but the guest window
 * server never flips it, so the panel keeps the last boot-time frame. Hand
 * the finished drawable to IOMobileFramebuffer's swap selectors (4 = begin,
 * 5 = end with the 0x46c record AppleCLCD::present consumes); the kernel's
 * vsync timer copies it natively (sweet-fb descriptors in QEMU).
 */
static unsigned int sweet_fb_conn;
static int sweet_fb_open_tried;
static unsigned int sweet_swap_id;
static unsigned int sweet_presents;
static unsigned int sweet_present_logs;
static unsigned int sweet_last_surface;
static unsigned long sweet_last_width, sweet_last_height;

static int
sweet_fb_open(void)
{
	if (sweet_fb_conn != 0) {
		return 0;
	}
	if (sweet_fb_open_tried) {
		return -1;
	}
	sweet_fb_open_tried = 1;
	void *mf = dlopen(
	    "/System/Library/Frameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", 2);
	int (*open_fb)(unsigned int, unsigned int, unsigned long, unsigned int *) =
	    (int (*)(unsigned int, unsigned int, unsigned long, unsigned int *))
	    (mf != 0 ? dlsym(mf, "IOMobileFramebufferOpen") : 0);
	unsigned int service = IOServiceGetMatchingService(0,
	    IOServiceMatching("IOMobileFramebuffer"));
	unsigned int conn = 0;
	int kr = -1;
	if (service != 0 && open_fb != 0) {
		kr = open_fb(service, mach_task_self(), 0, &conn);
	}
	if (service != 0) {
		IOObjectRelease(service);
	}
	dprintf(console_fd, "SWEETMETAL: present open=0x%x conn=%u%c", kr, conn, 10);
	if (kr == 0 && conn != 0) {
		sweet_fb_conn = conn;
		return 0;
	}
	return -1;
}

static void
sweet_present_surface(unsigned int surface, unsigned long width,
    unsigned long height)
{
	if (surface == 0 || width == 0 || height == 0 || sweet_fb_open() != 0) {
		return;
	}
	unsigned char rec[0x46c];
	bzero(rec, sizeof(rec));
	unsigned long long swap = 0;
	unsigned int swap_count = 1;
	unsigned int id = ++sweet_swap_id;
	if (IOConnectCallScalarMethod(sweet_fb_conn, 4, 0, 0, &swap,
	    &swap_count) == 0 && swap != 0) {
		id = (unsigned int)swap;
	}
	unsigned int rect[4] = { 0, 0, (unsigned int)width, (unsigned int)height };
	unsigned int mask = 1;
	memcpy(rec + 0x50, &id, 4);
	memcpy(rec + 0x54, &surface, 4);
	memcpy(rec + 0x64, rect, sizeof(rect));
	memcpy(rec + 0xc4, rect, sizeof(rect));
	memcpy(rec + 0x104, &mask, 4);
	int kr = IOConnectCallStructMethod(sweet_fb_conn, 5, rec, sizeof(rec), 0, 0);
	sweet_presents++;
	if (sweet_present_logs < 8) {
		sweet_present_logs++;
		dprintf(console_fd,
		    "SWEETMETAL: present surface=%u %lux%lu swap=%u -> 0x%x%c",
		    surface, width, height, id, kr, 10);
	}
}

static void
sweet_present_pending(void)
{
	if (sweet_last_surface != 0) {
		sweet_present_surface(sweet_last_surface, sweet_last_width,
		    sweet_last_height);
		sweet_last_surface = 0;
	}
}

static double
sweet_ticks_ms(unsigned long long ticks)
{
	static sweet_mach_timebase timebase;
	static int ready;
	if (!ready) {
		if (mach_timebase_info(&timebase) != 0) {
			timebase.numer = 1;
			timebase.denom = 1;
		}
		ready = 1;
	}
	return (double)ticks * (double)timebase.numer /
	    (double)timebase.denom / 1000000.0;
}

/* Does this process actually have UI windows/layers? (SpringBoard only) */
static void
sweet_probe_ui(void)
{
	Class app_class = objc_getClass("UIApplication");
	if (app_class == 0) {
		return;
	}
	id app = ((id (*)(id, SEL))objc_msgSend)((id)app_class,
	    sel_registerName("sharedApplication"));
	id windows = app != 0 ? sweet_msg_id(app, "windows") : 0;
	unsigned long count = windows != 0 ? sweet_msg_ul(windows, "count") : 0;
	dprintf(console_fd, "SWEETMETAL: ui pid=%d app=%p windows=%lu\n",
	    getpid(), app, count);
	for (unsigned long i = 0; i < count && i < 8; i++) {
		id window = sweet_msg_id_idx(windows, "objectAtIndex:", i);
		id layer = window != 0 ? sweet_msg_id(window, "layer") : 0;
		id sublayers = layer != 0 ? sweet_msg_id(layer, "sublayers") : 0;
		unsigned long sub = sublayers != 0 ?
		    sweet_msg_ul(sublayers, "count") : 0;
		unsigned long level = window != 0 ?
		    sweet_msg_ul(window, "windowLevel") : 0;
		dprintf(console_fd,
		    "SWEETMETAL: ui win[%lu] %s level=%lu sublayers=%lu\n",
		    i, window != 0 ? object_getClassName(window) : "(nil)",
		    level, sub);
	}

}


/* Does the WindowServer exist here, and which surface does IOMFB hand out? */
static void
sweet_probe_display(void)
{
	Class ws_class = objc_getClass("CAWindowServer");
	id server = 0;
	if (ws_class != 0 &&
	    ((BOOL (*)(id, SEL, SEL))objc_msgSend)((id)ws_class,
	    sel_registerName("respondsToSelector:"),
	    sel_registerName("serverIfExisting"))) {
		server = ((id (*)(id, SEL))objc_msgSend)((id)ws_class,
		    sel_registerName("serverIfExisting"));
	}
	dprintf(console_fd, "SWEETMETAL: display pid=%d server=%p\n",
	    getpid(), server);
	if (server != 0) {
		id displays = sweet_msg_id(server, "displays");
		unsigned long count = displays != 0 ?
		    sweet_msg_ul(displays, "count") : 0;
		dprintf(console_fd, "SWEETMETAL: display count=%lu\n", count);
		for (unsigned long i = 0; i < count && i < 4; i++) {
			id display = sweet_msg_id_idx(displays, "objectAtIndex:", i);
			id name = display != 0 ?
			    sweet_msg_id(display, "name") : 0;
			unsigned long flags = display != 0 ?
			    sweet_msg_ul(display, "rendererFlags") : 0;
			dprintf(console_fd,
			    "SWEETMETAL: display[%lu] %s name=%s flags=0x%lx\n",
			    i, display != 0 ?
			    object_getClassName(display) : "(nil)",
			    sweet_cstr(name), flags);
		}
	}

	void *mf = dlopen("/System/Library/Frameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", 2);
	void *ios = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", 2);
	if (mf == 0) {
		return;
	}
	int (*open_fb)(unsigned int, unsigned int, unsigned long,
	    unsigned int *) = (int (*)(unsigned int, unsigned int,
	    unsigned long, unsigned int *))dlsym(mf, "IOMobileFramebufferOpen");
	int (*get_surface)(unsigned int, int, id *) = (int (*)(unsigned int,
	    int, id *))dlsym(mf, "IOMobileFramebufferGetLayerDefaultSurface");
	unsigned int service = IOServiceGetMatchingService(0,
	    IOServiceMatching("IOMobileFramebuffer"));
	unsigned int conn = 0;
	int kr = -1;
	if (service != 0 && open_fb != 0) {
		kr = open_fb(service, mach_task_self(), 0, &conn);
	}
	id surface = 0;
	int gr = -1;
	if (kr == 0 && get_surface != 0) {
		gr = get_surface(conn, 0, &surface);
	}
	unsigned int surface_id = 0, width = 0, height = 0, bpr = 0;
	if (surface != 0 && ios != 0) {
		unsigned int (*get_id)(id) =
		    (unsigned int (*)(id))dlsym(ios, "IOSurfaceGetID");
		unsigned long (*get_w)(id) =
		    (unsigned long (*)(id))dlsym(ios, "IOSurfaceGetWidth");
		unsigned long (*get_h)(id) =
		    (unsigned long (*)(id))dlsym(ios, "IOSurfaceGetHeight");
		unsigned long (*get_b)(id) =
		    (unsigned long (*)(id))dlsym(ios, "IOSurfaceGetBytesPerRow");
		surface_id = get_id != 0 ? get_id(surface) : 0;
		width = get_w != 0 ? (unsigned int)get_w(surface) : 0;
		height = get_h != 0 ? (unsigned int)get_h(surface) : 0;
		bpr = get_b != 0 ? (unsigned int)get_b(surface) : 0;
	}
	dprintf(console_fd,
	    "SWEETMETAL: iomfb svc=%u open=0x%x conn=%u get=0x%x surface=%p id=%u %ux%u bpr=%u\n",
	    service, kr, conn, gr, surface, surface_id, width, height, bpr);
	if (service != 0) {
		IOObjectRelease(service);
	}
}

/* Which graphics stacks does this process actually have loaded? */
static void
sweet_probe_images(void *context)
{
	(void)context;
	unsigned int count = _dyld_image_count();
	dprintf(console_fd, "SWEETMETAL: images pid=%d count=%u\n", getpid(), count);
	for (unsigned int i = 0; i < count; i++) {
		const char *name = _dyld_get_image_name(i);
		if (name == 0) {
			continue;
		}
		if (strstr(name, "GL") || strstr(name, "AGX") ||
		    strstr(name, "Metal") || strstr(name, "EAGL") ||
		    strstr(name, "OpenGL") || strstr(name, "QuartzCore")) {
			dprintf(console_fd, "SWEETMETAL: image[%u] %s\n", i, name);
		}
		if (strstr(name, "QuartzCore.framework/QuartzCore")) {
			unsigned long base = (unsigned long)_dyld_get_image_header(i);
			dprintf(console_fd,
			    "SWEETMETAL: quartzcore base=0x%lx slide=0x%lx\n",
			    base, base - 0x188284000UL);
		}
	}
	sweet_probe_panel();
	sweet_probe_ui();
	sweet_probe_display();
}

__attribute__((constructor))
static void
sweet_loaded(void)
{
	static void *thread;
	sweet_log("bundle loaded", 0);
	sweet_install_cv_hooks();
	int probe_rc = pthread_create(&thread, 0, sweet_probe_thread, 0);
	dprintf(console_fd, "SWEETMETAL: probe thread rc=%d\n", probe_rc);
	void *queue = dispatch_get_global_queue(0, 0);
	dprintf(console_fd, "SWEETMETAL: probe queue=%p\n", queue);
	if (queue != 0) {
		dispatch_after_f(dispatch_time(0, 4000000000LL), queue, 0,
		    sweet_probe_work);
		dispatch_after_f(dispatch_time(0, 60000000000LL), queue, 0,
		    sweet_probe_images);
	}
}

typedef struct {
	unsigned long x, y, z;
} SweetSize;

/*
 * Metal hands the objects returned by the device to CoreAnimation, which
 * sends them the usual protocol (command queue, encoder, ...). Those are
 * trap objects: known selectors log and return the next trap or a sane
 * value, everything else reaches -forwardInvocation: and returns zero.
 */
__attribute__((objc_root_class))
@interface NSObject {
	Class isa;
}
+ (id)alloc;
- (id)init;
- (BOOL)respondsToSelector:(SEL)sel;
- (id)methodSignatureForSelector:(SEL)sel;
- (void)forwardInvocation:(id)invocation;
- (BOOL)conformsToProtocol:(id)proto;
@end

@interface SweetObject : NSObject
@end

@implementation SweetObject

- (id)device
{
	return sweet_device_self;
}

- (BOOL)conformsToProtocol:(id)proto
{
	const char *name = proto ? protocol_getName(proto) : "";
	sweet_log("conformsToProtocol", name);
	return strncmp(name, "MTL", 3) == 0;
}

- (BOOL)isKindOfClass:(Class)cls
{
	const char *name = cls ? class_getName(cls) : "";
	sweet_log("isKindOfClass", name);
	if (strncmp(name, "MTL", 3) == 0) {
		return 1;
	}
	return [super isKindOfClass:cls];
}

- (id)methodSignatureForSelector:(SEL)sel
{
	id signature = [super methodSignatureForSelector:sel];
	return signature ? signature : sweet_generic_signature();
}

- (void)forwardInvocation:(id)invocation
{
	SEL sel = ((SEL (*)(id, SEL))objc_msgSend)(invocation,
	    sel_registerName("selector"));
	sweet_log("call", sel_getName(sel));
	sweet_zero_return(invocation);
}

@end

@interface SweetCommandEncoder : SweetObject
@end

@implementation SweetCommandEncoder
@end

/*
 * A function created from a descriptor is used by MPSCore to build compute
 * pipelines; a render function type makes it report "not a compute function".
 */
@interface SweetFunction : SweetObject {
	id fn_name;
	SweetFcSet fn_fc;
	int fn_has_fc;
}
- (void)setSweetName:(id)name;
- (id)name;
- (void)snapshotConstants;
- (int)copyFcTo:(SweetFcSet *)out;
@end

@implementation SweetFunction

- (void)setSweetName:(id)name
{
	fn_name = ((id (*)(id, SEL))objc_msgSend)(name,
	    sel_registerName("retain"));
}

- (void)snapshotConstants
{
	fn_fc = sweet_fc;
	fn_has_fc = 1;
}

- (int)copyFcTo:(SweetFcSet *)out
{
	if (!fn_has_fc) {
		return 0;
	}
	*out = fn_fc;
	return 1;
}

- (id)name
{
	sweet_log("function", "name");
	return fn_name;
}

- (unsigned long)functionType
{
	sweet_log("function", "functionType");
	return 3;	/* MTLFunctionTypeKernel */
}

@end

/* Generic stand-in for resources and states; logs and survives any call. */
@interface SweetOpaque : SweetObject
- (void *)contents;
- (unsigned long)length;
- (unsigned long)width;
- (unsigned long)height;
- (unsigned long)pixelFormat;
- (unsigned long)sampleCount;
- (unsigned long)textureType;
- (unsigned long)storageMode;
- (unsigned long)usage;
- (unsigned long)maxTotalThreadsPerThreadgroup;
- (unsigned long)threadExecutionWidth;
- (unsigned long)staticThreadgroupMemoryLength;
- (unsigned long)functionType;
- (id)newFunctionWithName:(id)name;
- (id)newFunctionWithName:(id)name constantValues:(id)values error:(id *)error;
- (id)newFunctionWithDescriptor:(id)descriptor error:(id *)error;
- (id)newRenderPipelineStateWithFunction:(id)function error:(id *)error;
- (id)newComputePipelineStateWithFunction:(id)function error:(id *)error;
- (id)newRenderPipelineStateWithName:(id)name options:(unsigned long)options
    reflection:(id *)reflection error:(id *)error;
@end

static id sweet_pipeline_named(id name);

@implementation SweetOpaque

- (id)newFunctionWithName:(id)name
{
	dprintf(console_fd, "SWEETMETAL: library newFunctionWithName %s\n",
	    sweet_cstr(name));
	return [[SweetOpaque alloc] init];
}

- (id)newFunctionWithName:(id)name constantValues:(id)values error:(id *)error
{
	sweet_log("library", "newFunctionWithName:constantValues:error:");
	return [[SweetOpaque alloc] init];
}

- (id)newFunctionWithDescriptor:(id)descriptor error:(id *)error
{
	id name = descriptor ? sweet_msg_id(descriptor, "name") : 0;
	sweet_install_cv_hooks();
	dprintf(console_fd, "SWEETMETAL: library newFunctionWithDescriptor %s\n",
	    sweet_cstr(name));
	if (descriptor != 0) {
		id cv = sweet_msg_id(descriptor, "constantValues");
		if (cv != 0) {
			Class cvc = object_getClass(cv);
			dprintf(console_fd, "SWEETMETAL: cv class %s obj %p", class_getName(cvc), cv);
			dprintf(console_fd, "%c", 10);
			unsigned int ivn = 0;
			Ivar *ivs = class_copyIvarList(cvc, &ivn);
			for (unsigned int i = 0; ivs != 0 && i < ivn && i < 12; i++) {
				dprintf(console_fd, "SWEETMETAL: cv ivar %s +%ld",
				    ivar_getName(ivs[i]), ivar_getOffset(ivs[i]));
				dprintf(console_fd, "%c", 10);
			}
			if (ivs != 0) {
				free(ivs);
			}
			{
				id arr = sweet_msg_id(cv, "newIndexedConstantArray");
				unsigned long n = arr != 0 ? sweet_msg_ul(arr, "count") : 0;
				dprintf(console_fd, "SWEETMETAL: cv indexed %lu", n);
				dprintf(console_fd, "%c", 10);
				for (unsigned long i = 0; i < n && i < 16; i++) {
					id c = sweet_msg_id_idx(arr, "objectAtIndex:", i);
					if (c == 0) {
						continue;
					}
					dprintf(console_fd, "SWEETMETAL: cv[%lu] class %s",
					    i, object_getClassName(c));
					dprintf(console_fd, "%c", 10);
					unsigned int cin = 0;
					Ivar *civ = class_copyIvarList(object_getClass(c), &cin);
					for (unsigned int k = 0; civ != 0 && k < cin && k < 8; k++) {
						dprintf(console_fd, "SWEETMETAL:   civar %s +%ld",
						    ivar_getName(civ[k]), ivar_getOffset(civ[k]));
						dprintf(console_fd, "%c", 10);
					}
					if (civ != 0) {
						free(civ);
					}
					{
						unsigned long long cidx = *(unsigned long long *)((char *)c + 8);
						unsigned long long ctyp = *(unsigned long long *)((char *)c + 16);
						unsigned long long cdat = *(unsigned long long *)((char *)c + 24);
						dprintf(console_fd, "SWEETMETAL:   idx %llu type %llu data %#llx",
						    cidx, ctyp, cdat);
						dprintf(console_fd, "%c", 10);
						if (cdat > 0x100000000ULL && (cdat & 7) == 0) {
							unsigned long long val[2] = { 0, 0 };
							unsigned long long got = 0;
							if (mach_vm_read_overwrite(mach_task_self_, cdat, sizeof(val),
							    (unsigned long long)val, &got) == 0 && got == sizeof(val)) {
								dprintf(console_fd, "SWEETMETAL:   value %#llx %#llx",
								    val[0], val[1]);
								dprintf(console_fd, "%c", 10);
							}
						}
					}
					sweet_hex64("cvraw64_", i, (const void *)c);
				}
			}
		}
	}
	SweetFunction *function = [[SweetFunction alloc] init];
	((void (*)(id, SEL, id))objc_msgSend)(function,
	    sel_registerName("setSweetName:"), name);
	((void (*)(id, SEL))objc_msgSend)(function,
	    sel_registerName("snapshotConstants"));
	return function;
}

- (id)newRenderPipelineStateWithName:(id)name options:(unsigned long)options
    reflection:(id *)reflection error:(id *)error
{
	dprintf(console_fd, "SWEETMETAL: library newRenderPipelineStateWithName %s\n",
	    sweet_cstr(name));
	return sweet_pipeline_named(name);
}

- (id)newRenderPipelineStateWithFunction:(id)function error:(id *)error
{
	sweet_log("library", "newRenderPipelineStateWithFunction:error:");
	return sweet_pipeline_named(0);
}

- (id)newComputePipelineStateWithFunction:(id)function error:(id *)error
{
	sweet_log("library", "newComputePipelineStateWithFunction:error:");
	return [[SweetOpaque alloc] init];
}

- (void *)contents
{
	static unsigned char scratch[4 << 20];
	sweet_log("opaque", "contents");
	return scratch;
}

- (unsigned long)length
{
	sweet_log("opaque", "length");
	return 1UL << 20;
}

- (unsigned long)width
{
	sweet_log("opaque", "width");
	return 1080;
}

- (unsigned long)height
{
	sweet_log("opaque", "height");
	return 2400;
}

- (unsigned long)pixelFormat
{
	sweet_log("opaque", "pixelFormat");
	return 80;	/* MTLPixelFormatBGRA8Unorm */
}

- (unsigned long)sampleCount
{
	sweet_log("opaque", "sampleCount");
	return 1;
}

- (unsigned long)textureType
{
	sweet_log("opaque", "textureType");
	return 2;	/* MTLTextureType2D */
}

- (unsigned long)storageMode
{
	sweet_log("opaque", "storageMode");
	return 0;
}

- (unsigned long)usage
{
	sweet_log("opaque", "usage");
	return 0;
}

- (unsigned long)maxTotalThreadsPerThreadgroup
{
	sweet_log("opaque", "maxTotalThreadsPerThreadgroup");
	return 1024;
}

- (unsigned long)threadExecutionWidth
{
	sweet_log("opaque", "threadExecutionWidth");
	return 32;
}

- (unsigned long)staticThreadgroupMemoryLength
{
	sweet_log("opaque", "staticThreadgroupMemoryLength");
	return 0;
}

- (unsigned long)functionType
{
	sweet_log("opaque", "functionType");
	return 1;	/* MTLFunctionTypeVertex; 0 is invalid and aborts callers */
}

@end

/* Real storage for CA's vertex/index buffers: the kernel will copyin these
 * user addresses when a draw reaches the GPU service. */
@interface SweetBuffer : SweetOpaque {
	void *buf_ptr;
	unsigned long buf_len;
}
- (id)initWithLength:(unsigned long)length;
- (id)initWithBytes:(const void *)bytes length:(unsigned long)length;
@end

@implementation SweetBuffer

- (id)initWithLength:(unsigned long)length
{
	buf_len = length ? length : 1;
	buf_ptr = malloc(buf_len);
	if (buf_ptr != 0) {
		bzero(buf_ptr, buf_len);
	}
	return self;
}

- (id)initWithBytes:(const void *)bytes length:(unsigned long)length
{
	buf_len = length ? length : 1;
	buf_ptr = malloc(buf_len);
	if (buf_ptr != 0) {
		if (bytes != 0) {
			memcpy(buf_ptr, bytes, length);
		} else {
			bzero(buf_ptr, buf_len);
		}
	}
	return self;
}

- (void *)contents
{
	return buf_ptr;
}

- (unsigned long)length
{
	return buf_len;
}

@end

/* Pipeline state with the function/library name, so a draw can be decoded. */
@interface SweetPipeline : SweetOpaque {
	char pipe_name[96];
	unsigned long pipe_attr_format[8];
	unsigned long pipe_attr_offset[8];
	unsigned long pipe_attr_buffer[8];
	unsigned long pipe_stride[8];
	SweetFcSet pipe_fc;
	int pipe_has_fc;
}
- (void)setNameC:(const char *)name;
- (void)setAttribute:(unsigned long)index format:(unsigned long)format
    offset:(unsigned long)offset buffer:(unsigned long)buffer;
- (void)setStride:(unsigned long)stride forBuffer:(unsigned long)buffer;
- (unsigned long)attributeFormat:(unsigned long)index;
- (unsigned long)attributeOffset:(unsigned long)index;
- (unsigned long)attributeBuffer:(unsigned long)index;
- (unsigned long)strideForBuffer:(unsigned long)buffer;
- (int)copyConstantsFromFunction:(id)function;
- (double)fcValue:(const char *)name;
@end

@implementation SweetPipeline

- (void)setNameC:(const char *)name
{
	unsigned long i = 0;
	if (name != 0) {
		while (name[i] != 0 && i + 1 < sizeof(pipe_name)) {
			pipe_name[i] = name[i];
			i++;
		}
	}
	pipe_name[i] = 0;
}

- (const char *)nameC
{
	return pipe_name;
}

- (void)setAttribute:(unsigned long)index format:(unsigned long)format
    offset:(unsigned long)offset buffer:(unsigned long)buffer
{
	if (index < 8) {
		pipe_attr_format[index] = format;
		pipe_attr_offset[index] = offset;
		pipe_attr_buffer[index] = buffer;
	}
}

- (void)setStride:(unsigned long)stride forBuffer:(unsigned long)buffer
{
	if (buffer < 8) {
		pipe_stride[buffer] = stride;
	}
}

- (unsigned long)attributeFormat:(unsigned long)index
{
	return index < 8 ? pipe_attr_format[index] : 0;
}

- (unsigned long)attributeOffset:(unsigned long)index
{
	return index < 8 ? pipe_attr_offset[index] : 0;
}

- (unsigned long)attributeBuffer:(unsigned long)index
{
	return index < 8 ? pipe_attr_buffer[index] : 0;
}

- (unsigned long)strideForBuffer:(unsigned long)buffer
{
	return buffer < 8 ? pipe_stride[buffer] : 0;
}

- (int)copyConstantsFromFunction:(id)function
{
	if (function == 0 || !((BOOL (*)(id, SEL, Class))objc_msgSend)(function,
	    sel_registerName("isKindOfClass:"), objc_getClass("SweetFunction"))) {
		return 0;
	}
	pipe_has_fc = ((int (*)(id, SEL, SweetFcSet *))objc_msgSend)(function,
	    sel_registerName("copyFcTo:"), &pipe_fc);
	return pipe_has_fc;
}

- (double)fcValue:(const char *)name
{
	if (!pipe_has_fc || name == 0) {
		return -1.0;
	}
	for (int i = 0; i < pipe_fc.count; i++) {
		if (strcmp(pipe_fc.e[i].name, name) == 0) {
			return pipe_fc.e[i].value;
		}
	}
	return -1.0;
}

@end

static id
sweet_pipeline_from_descriptor(id descriptor)
{
	SweetPipeline *state = [[SweetPipeline alloc] init];
	const char *name = "-";
	if (descriptor != 0) {
		id vertex = sweet_msg_id(descriptor, "vertexFunction");
		if (vertex != 0) {
			id fnname = sweet_msg_id(vertex, "name");
			if (fnname != 0) {
				name = sweet_cstr(fnname);
			}
		}
		id frag = sweet_msg_id(descriptor, "fragmentFunction");
		if (frag != 0) {
			dprintf(console_fd, "SWEETMETAL: pso frag %s", sweet_cstr(sweet_msg_id(frag, "name")));
			dprintf(console_fd, "%c", 10);
			((void (*)(id, SEL, id))objc_msgSend)(state,
			    sel_registerName("copyConstantsFromFunction:"), frag);
			if (strstr(name, "fixed_") != 0) {
				double fblend = ((double (*)(id, SEL, const char *))
				    objc_msgSend)(state, sel_registerName("fcValue:"),
				    "fc_blend_function");
				double ftex = ((double (*)(id, SEL, const char *))
				    objc_msgSend)(state, sel_registerName("fcValue:"),
				    "fc_texture_function");
				double fdst = ((double (*)(id, SEL, const char *))
				    objc_msgSend)(state, sel_registerName("fcValue:"),
				    "fc_destination_function");
				double fimg = ((double (*)(id, SEL, const char *))
				    objc_msgSend)(state, sel_registerName("fcValue:"),
				    "fc_image_count");
				dprintf(console_fd,
				    "SWEETMETAL: pso fc blend=%g tex=%g dst=%g img=%g",
				    fblend, ftex, fdst, fimg);
				dprintf(console_fd, "%c", 10);
			}
		}
		if (strstr(name, "fixed_") != 0) {
			@try {
				id vd = sweet_msg_id(descriptor, "vertexDescriptor");
				id attrs = vd != 0 ? sweet_msg_id(vd, "attributes") : 0;
				id lays = vd != 0 ? sweet_msg_id(vd, "layouts") : 0;
				for (unsigned long i = 0; i < 8; i++) {
					id a = attrs != 0 ? sweet_msg_id_idx(attrs,
					    "objectAtIndexedSubscript:", i) : 0;
					if (a != 0) {
						unsigned long afmt = sweet_msg_ul(a, "format");
						unsigned long aoff = sweet_msg_ul(a, "offset");
						unsigned long abuf = sweet_msg_ul(a, "bufferIndex");
						dprintf(console_fd,
						    "SWEETMETAL: pso attr%lu fmt=%lu off=%lu buf=%lu", i,
						    afmt, aoff, abuf);
						dprintf(console_fd, "%c", 10);
						((void (*)(id, SEL, unsigned long, unsigned long,
						    unsigned long, unsigned long))objc_msgSend)(state,
						    sel_registerName("setAttribute:format:offset:buffer:"),
						    i, afmt, aoff, abuf);
					}
					id l = lays != 0 ? sweet_msg_id_idx(lays,
					    "objectAtIndexedSubscript:", i) : 0;
					if (l != 0) {
						unsigned long lstride = sweet_msg_ul(l, "stride");
						dprintf(console_fd,
						    "SWEETMETAL: pso lay%lu stride=%lu step=%lu", i,
						    lstride, sweet_msg_ul(l, "stepFunction"));
						dprintf(console_fd, "%c", 10);
						((void (*)(id, SEL, unsigned long, unsigned long))
						    objc_msgSend)(state,
						    sel_registerName("setStride:forBuffer:"), lstride, i);
					}
				}
				id cas = sweet_msg_id(descriptor, "colorAttachments");
				id a0 = cas != 0 ? sweet_msg_id_idx(cas,
				    "objectAtIndexedSubscript:", 0) : 0;
				if (a0 != 0) {
					dprintf(console_fd,
					    "SWEETMETAL: pso color0 fmt=%lu blend=%lu src=%lu dst=%lu op=%lu",
					    sweet_msg_ul(a0, "pixelFormat"),
					    sweet_msg_ul(a0, "blendingEnabled"),
					    sweet_msg_ul(a0, "sourceRGBBlendFactor"),
					    sweet_msg_ul(a0, "destinationRGBBlendFactor"),
					    sweet_msg_ul(a0, "rgbBlendOperation"));
					dprintf(console_fd, "%c", 10);
				}
			} @catch (id exception) {
				sweet_log("pso query failed", 0);
			}
		}
	}
	((void (*)(id, SEL, const char *))objc_msgSend)(state,
	    sel_registerName("setNameC:"), name);
	return state;
}

static id
sweet_pipeline_named(id name)
{
	SweetPipeline *state = [[SweetPipeline alloc] init];
	((void (*)(id, SEL, const char *))objc_msgSend)(state,
	    sel_registerName("setNameC:"), sweet_cstr(name));
	return state;
}

static void
sweet_hex32(const char *tag, unsigned int index, const void *pointer)
{
	const unsigned char *p = (const unsigned char *)pointer;
	if (p == 0) {
		return;
	}
	dprintf(console_fd, "SWEETMETAL:   %s[%u] %02x%02x%02x%02x %02x%02x%02x%02x"
	    " %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x"
	    " %02x%02x%02x%02x %02x%02x%02x%02x\n", tag, index,
	    p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7],
	    p[8], p[9], p[10], p[11], p[12], p[13], p[14], p[15],
	    p[16], p[17], p[18], p[19], p[20], p[21], p[22], p[23],
	    p[24], p[25], p[26], p[27], p[28], p[29], p[30], p[31]);
}

static void
sweet_hex64(const char *tag, unsigned int index, const void *pointer)
{
	const unsigned char *p = (const unsigned char *)pointer;
	if (p == 0) {
		return;
	}
	dprintf(console_fd, "SWEETMETAL:   %s%u", tag, index);
	for (unsigned long i = 0; i < 64; i++) {
		dprintf(console_fd, "%02x", p[i]);
		if ((i & 15) == 15) {
			dprintf(console_fd, "%c", 10);
			if (i != 63) {
				dprintf(console_fd, "SWEETMETAL:     ");
			}
		}
	}
}
/* Texture backed by an IOSurface; keeps the id for the clear forwarder. */
typedef struct {
	unsigned long x, y, z, width, height, depth;
} SweetRegion;

static unsigned long sweet_texel_bpp(unsigned long fmt);

@interface SweetTexture : SweetOpaque {
	unsigned int tex_surface;
	unsigned long tex_width;
	unsigned long tex_height;
	unsigned long tex_format;
	unsigned long tex_bpr;
	void *tex_pixels;
	unsigned long tex_dirty;
	unsigned long tex_rendered;
@public
	unsigned long tex_version;
	unsigned long tex_host_version;
	unsigned int tex_host_id;
}
- (void)setSurfaceID:(unsigned int)identifier;
- (unsigned int)surfaceID;
- (void)setSize:(unsigned long)width height:(unsigned long)height;
- (void)setFormat:(unsigned long)format;
- (void)replaceRegion:(SweetRegion)region mipmapLevel:(unsigned long)level
    slice:(unsigned long)slice withBytes:(const void *)bytes
    bytesPerRow:(unsigned long)bytes_per_row bytesPerImage:(unsigned long)bytes_per_image;
- (void)replaceRegion:(SweetRegion)region mipmapLevel:(unsigned long)level
    withBytes:(const void *)bytes bytesPerRow:(unsigned long)bytes_per_row;
- (unsigned long)dirty;
- (void)clearDirty;
- (void *)pixelBytes;
- (unsigned long)bytesPerRow;
- (int)ensureRenderPixels;
- (void)markRendered;
- (unsigned long)rendered;
@end

@implementation SweetTexture

- (void)setSurfaceID:(unsigned int)identifier
{
	tex_surface = identifier;
}

- (unsigned int)surfaceID
{
	return tex_surface;
}

- (void)setSize:(unsigned long)width height:(unsigned long)height
{
	tex_width = width;
	tex_height = height;
}

- (void)setFormat:(unsigned long)format
{
	tex_format = format;
}

- (unsigned long)width
{
	return tex_width;
}

- (unsigned long)height
{
	return tex_height;
}

- (unsigned long)pixelFormat
{
	return tex_format;
}

- (void)storeUpload:(const void *)bytes bytesPerRow:(unsigned long)bytes_per_row
    height:(unsigned long)height
{
	unsigned long need = bytes_per_row * height;
	if (bytes == 0 || need == 0) {
		return;
	}
	if (tex_pixels != 0) {
		free(tex_pixels);
		tex_pixels = 0;
	}
	tex_pixels = malloc(need);
	if (tex_pixels == 0) {
		return;
	}
	memcpy(tex_pixels, bytes, need);
	tex_bpr = bytes_per_row;
	tex_dirty = 1;
	tex_version++;
}

- (void)replaceRegion:(SweetRegion)region mipmapLevel:(unsigned long)level
    slice:(unsigned long)slice withBytes:(const void *)bytes
    bytesPerRow:(unsigned long)bytes_per_row bytesPerImage:(unsigned long)bytes_per_image
{
	if (level != 0 || slice != 0) {
		return;
	}
	[self storeUpload:bytes bytesPerRow:bytes_per_row height:region.height];
	if (tex_pixels != 0) {
		const unsigned char *p = (const unsigned char *)tex_pixels;
		unsigned long sum = 0, n = tex_bpr * region.height;
		unsigned long limit = n < (256UL << 10) ? n : (256UL << 10);
		for (unsigned long i = 0; i < limit; i += 4) {
			sum += p[i] + p[i + 1] + p[i + 2] + p[i + 3];
		}
		dprintf(console_fd,
		    "SWEETMETAL: upload %lux%lu fmt=%lu bpr=%lu bytes=%p first=%02x%02x%02x%02x",
		    tex_width, tex_height, tex_format, tex_bpr,
		    tex_pixels, p[0], p[1], p[2], p[3]);
		dprintf(console_fd, " sum256k=%lu%c", sum, 10);
	}
}

- (void)replaceRegion:(SweetRegion)region mipmapLevel:(unsigned long)level
    withBytes:(const void *)bytes bytesPerRow:(unsigned long)bytes_per_row
{
	[self replaceRegion:region mipmapLevel:level slice:0 withBytes:bytes
	    bytesPerRow:bytes_per_row bytesPerImage:0];
}

- (unsigned long)dirty
{
	return tex_dirty;
}

- (void)clearDirty
{
	tex_dirty = 0;
}

- (void *)pixelBytes
{
	return tex_pixels;
}

- (unsigned long)bytesPerRow
{
	return tex_bpr;
}

- (unsigned long)bytesPerPixel
{
	return sweet_texel_bpp(tex_format);
}

- (void)markRendered
{
	tex_rendered = 1;
}

- (unsigned long)rendered
{
	return tex_rendered;
}

- (int)ensureRenderPixels
{
	if (tex_width == 0 || tex_height == 0 || tex_width > 8192 ||
	    tex_height > 8192) {
		return -1;
	}
	unsigned long bpr = tex_width * [self bytesPerPixel];
	if (tex_pixels != 0 && tex_bpr == bpr) {
		return 0;
	}
	free(tex_pixels);
	tex_pixels = calloc(bpr * tex_height, 1);
	if (tex_pixels == 0) {
		tex_bpr = 0;
		return -1;
	}
	tex_bpr = bpr;
	tex_dirty = 1;
	dprintf(console_fd,
	    "SWEETMETAL: offscreen storage %lux%lu fmt=%lu bpr=%lu %p%c",
	    tex_width, tex_height, tex_format, tex_bpr, tex_pixels, 10);
	return 0;
}

- (void)dealloc
{
	free(tex_pixels);
	tex_pixels = 0;
	[super dealloc];
}

@end

#define SWEET_OBJECT() [[SweetOpaque alloc] init]

static unsigned int sweet_encoder_logs;
static unsigned int sweet_draw_logs;
static unsigned int sweet_draw_logs5;

/* Render encoder: records the destination surface and the draw inputs so the
 * kernel/host can later replay CA's compositor draws with real content. */
float floorf(float);
float ceilf(float);
float fminf(float, float);
float fmaxf(float, float);

/*
 * CPU compositor for CoreAnimation's 2D draws.
 *
 * The runtime layout (read from the render-pipeline vertex descriptor) is
 * 48 bytes per vertex: float4 position @0, float2 texcoord0 @16,
 * float2 texcoord1 @24, half4 color @32. Positions are pixels in the
 * destination surface; texcoords are normalized. The fragment shaders blend
 * source-over into the destination (framebuffer fetch), which is exactly what
 * the kernel's present path then copies to the panel.
 */
static float
sweet_half_to_float(unsigned short h)
{
	int sign = (h >> 15) & 1;
	int expo = (h >> 10) & 0x1f;
	int mant = h & 0x3ff;
	float v;
	if (expo == 0) {
		v = (float)mant * 5.9604644775390625e-8f;
	} else if (expo == 31) {
		v = 65504.0f;
	} else {
		unsigned int bits = (unsigned int)(expo - 15 + 127) << 23;
		float scale = *(float *)&bits;
		v = (1.0f + (float)mant / 1024.0f) * scale;
	}
	return sign ? -v : v;
}

typedef struct {
	const unsigned char *vb;
	unsigned long vb_len;
	unsigned long stride;
	unsigned long pos_fmt, pos_off;
	unsigned long tex_fmt, tex_off;
	unsigned long col_fmt, col_off;
	const unsigned char *tex;
	unsigned long tex_w, tex_h, tex_fmt_px, tex_bpr;
	unsigned int tex_surface;
	unsigned long tex_internal;
	int tex_mapped;
	id tex_owner;
	unsigned long blend_fn, tex_fn, dst_fn, img_count;
	unsigned char *dst;
	unsigned long dst_w, dst_h, dst_bpr;
	int clip_x0, clip_y0, clip_x1, clip_y1;
	int dbg_n;
	float dbg_x0, dbg_y0, dbg_x1, dbg_y1;
	float dbg_u0, dbg_v0, dbg_u1, dbg_v1;
	float dbg_col[4];
} SweetRaster;

/*
 * MTLPixelFormat storage sizes. CoreAnimation binds RG8Unorm (30) for its
 * two-channel gradients, R16Float (25) for LUTs and the private wide-gamut
 * BGR10_XR (550/551, 32bpp) / BGRA10_XR (552/553, 64bpp) formats; assuming
 * four bytes per texel shifts every row and skews sampled gradients.
 */
static unsigned long
sweet_texel_bpp(unsigned long fmt)
{
	switch (fmt) {
	case 1:
	case 10: case 11: case 12: case 13: case 14:
		return 1;
	case 20: case 21: case 22: case 23: case 24: case 25:
	case 30: case 31: case 32: case 33: case 34:
		return 2;
	case 53: case 54: case 55:
	case 60: case 61: case 62: case 63: case 64: case 65:
	case 70: case 71: case 72: case 73: case 74:
	case 80: case 81:
	case 90: case 91: case 92: case 93:
	case 550: case 551: case 554: case 555:
		return 4;
	case 103: case 104: case 105:
	case 110: case 111: case 112: case 113: case 114: case 115:
	case 552: case 553:
		return 8;
	case 123: case 124: case 125:
		return 16;
	default:
		return 4;
	}
}

/* Extended-range formats store raw/1023 in [-0.752941, 1.25098]. */
static float
sweet_xr10(unsigned long raw)
{
	return (float)raw * (2.003921568627451f / 1023.0f) - 0.7529411764705882f;
}

static float
sweet_xr16(unsigned long raw)
{
	return (float)raw * (2.003921568627451f / 65535.0f) - 0.7529411764705882f;
}

static void
sweet_decode_texel(unsigned long fmt, const unsigned char *p, float t[4])
{
	t[0] = t[1] = t[2] = t[3] = 1.0f;
	switch (fmt) {
	case 1: case 10:
		t[3] = (float)p[0] / 255.0f;
		break;
	case 20: {
		unsigned int v = *(const unsigned short *)p;
		t[0] = t[1] = t[2] = (float)v / 65535.0f;
		break;
	}
	case 25: {
		float v = sweet_half_to_float(*(const unsigned short *)p);
		t[0] = t[1] = t[2] = v;
		break;
	}
	case 30: case 31: {
		t[0] = (float)p[0] / 255.0f;
		t[1] = (float)p[1] / 255.0f;
		t[2] = 0.0f;
		break;
	}
	case 55: {
		float v = *(const float *)p;
		t[0] = t[1] = t[2] = v;
		break;
	}
	case 70: case 71:
		t[0] = (float)p[0] / 255.0f;
		t[1] = (float)p[1] / 255.0f;
		t[2] = (float)p[2] / 255.0f;
		t[3] = (float)p[3] / 255.0f;
		break;
	case 80: case 81:
		t[0] = (float)p[2] / 255.0f;
		t[1] = (float)p[1] / 255.0f;
		t[2] = (float)p[0] / 255.0f;
		t[3] = (float)p[3] / 255.0f;
		break;
	case 110: case 111: {
		const unsigned short *h = (const unsigned short *)p;
		t[0] = (float)h[0] / 65535.0f;
		t[1] = (float)h[1] / 65535.0f;
		t[2] = (float)h[2] / 65535.0f;
		t[3] = (float)h[3] / 65535.0f;
		break;
	}
	case 115: {
		const unsigned short *h = (const unsigned short *)p;
		t[0] = sweet_half_to_float(h[0]);
		t[1] = sweet_half_to_float(h[1]);
		t[2] = sweet_half_to_float(h[2]);
		t[3] = sweet_half_to_float(h[3]);
		break;
	}
	case 550: case 551: {
		unsigned int raw = *(const unsigned int *)p;
		unsigned int b = raw & 0x3ff;
		unsigned int g = (raw >> 10) & 0x3ff;
		unsigned int r = (raw >> 20) & 0x3ff;
		t[0] = sweet_xr10(r);
		t[1] = sweet_xr10(g);
		t[2] = sweet_xr10(b);
		break;
	}
	case 552: case 553: {
		const unsigned short *h = (const unsigned short *)p;
		t[0] = sweet_xr16(h[0]);
		t[1] = sweet_xr16(h[1]);
		t[2] = sweet_xr16(h[2]);
		t[3] = (float)h[3] / 65535.0f;
		break;
	}
	case 105: {
		const float *f = (const float *)p;
		t[0] = f[0];
		t[1] = f[1];
		t[2] = 0.0f;
		break;
	}
	default:
		t[0] = (float)p[2] / 255.0f;
		t[1] = (float)p[1] / 255.0f;
		t[2] = (float)p[0] / 255.0f;
		t[3] = (float)p[3] / 255.0f;
		break;
	}
}

/* Anything this process rendered is stored as RGBA8 whatever the declared
 * format says; only the IOSurface consumer sees the native layout. */
static void
sweet_decode_internal(const unsigned char *p, float t[4])
{
	t[0] = (float)p[0] / 255.0f;
	t[1] = (float)p[1] / 255.0f;
	t[2] = (float)p[2] / 255.0f;
	t[3] = (float)p[3] / 255.0f;
}

static void
sweet_texel(const SweetRaster *r, float u, float v, float out[4])
{
	out[0] = out[1] = out[2] = out[3] = 1.0f;
	if (r->tex == 0 || r->tex_w == 0 || r->tex_h == 0) {
		return;
	}
	if ((u > 1.5f || v > 1.5f) && u >= 0.0f && v >= 0.0f &&
	    u <= (float)r->tex_w + 0.5f && v <= (float)r->tex_h + 0.5f) {
		u /= (float)r->tex_w;
		v /= (float)r->tex_h;
	}
	if (u < 0.0f) u = 0.0f;
	if (v < 0.0f) v = 0.0f;
	if (u > 0.999999f) u = 0.999999f;
	if (v > 0.999999f) v = 0.999999f;
	float fx = u * (float)r->tex_w - 0.5f;
	float fy = v * (float)r->tex_h - 0.5f;
	int x0 = (int)floorf(fx), y0 = (int)floorf(fy);
	float ax = fx - (float)x0, ay = fy - (float)y0;
	int xs[2] = { x0, x0 + 1 };
	int ys[2] = { y0, y0 + 1 };
	float acc[4] = { 0, 0, 0, 0 };
	for (int j = 0; j < 2; j++) {
		int y = ys[j];
		if (y < 0) y = 0;
		if (y >= (int)r->tex_h) y = (int)r->tex_h - 1;
		for (int i = 0; i < 2; i++) {
			int x = xs[i];
			if (x < 0) x = 0;
			if (x >= (int)r->tex_w) x = (int)r->tex_w - 1;
			const unsigned char *p = r->tex + (unsigned long)y * r->tex_bpr +
			    (unsigned long)x * (r->tex_internal ? 4 :
			    sweet_texel_bpp(r->tex_fmt_px));
			float t[4];
			if (r->tex_internal) {
				sweet_decode_internal(p, t);
			} else {
				sweet_decode_texel(r->tex_fmt_px, p, t);
			}
			float w = (i ? ax : 1.0f - ax) * (j ? ay : 1.0f - ay);
			for (int k = 0; k < 4; k++) {
				acc[k] += t[k] * w;
			}
		}
	}
	for (int k = 0; k < 4; k++) {
		out[k] = acc[k];
	}
}

static int
sweet_vertex(const SweetRaster *r, unsigned long index, float *x, float *y,
    float *u, float *v, float col[4])
{
	unsigned long off = index * r->stride;
	if (off + r->stride > r->vb_len) {
		return 0;
	}
	const unsigned char *p = r->vb + off;
	if (r->pos_fmt == 29) {
		*x = *(const float *)(p + r->pos_off);
		*y = *(const float *)(p + r->pos_off + 4);
	} else {
		*x = *(const float *)(p + r->pos_off);
		*y = *(const float *)(p + r->pos_off + 4);
	}
	if (r->tex_fmt == 29) {
		*u = *(const float *)(p + r->tex_off);
		*v = *(const float *)(p + r->tex_off + 4);
	} else {
		*u = 0.0f;
		*v = 0.0f;
	}
	col[0] = col[1] = col[2] = col[3] = 1.0f;
	if (r->col_fmt == 27) {
		const unsigned short *h = (const unsigned short *)(p + r->col_off);
		col[0] = sweet_half_to_float(h[0]);
		col[1] = sweet_half_to_float(h[1]);
		col[2] = sweet_half_to_float(h[2]);
		col[3] = sweet_half_to_float(h[3]);
	}
	return 1;
}

static float
sweet_edge(float ax, float ay, float bx, float by, float px, float py)
{
	return (px - ax) * (by - ay) - (py - ay) * (bx - ax);
}

static void
sweet_blend_pixel(SweetRaster *r, int x, int y, const float col[4])
{
	if (x < 0 || y < 0 || x >= (int)r->dst_w || y >= (int)r->dst_h) {
		return;
	}
	if (x < r->clip_x0 || y < r->clip_y0 || x >= r->clip_x1 || y >= r->clip_y1) {
		return;
	}
	unsigned char *p = r->dst + (unsigned long)y * r->dst_bpr + (unsigned long)x * 4;
	float a = col[3];
	if (a <= 0.0f) {
		return;
	}
	if (a > 1.0f) a = 1.0f;
	float sr = col[0] * a, sg = col[1] * a, sb = col[2] * a;
	float dr = (float)p[0] / 255.0f;
	float dg = (float)p[1] / 255.0f;
	float db = (float)p[2] / 255.0f;
	float da = (float)p[3] / 255.0f;
	float inv = 1.0f - a;
	float orr = sr + dr * inv;
	float og = sg + dg * inv;
	float ob = sb + db * inv;
	float oa = a + da * inv;
	if (r->blend_fn == 46) {
		/* fixed_frag_lph_cpf blend 46: src scaled by dst luminance^4. */
		float l = 0.299f * dr + 0.587f * dg + 0.114f * db;
		if (l < 0.0f) l = 0.0f;
		if (l > 1.0f) l = 1.0f;
		float l4 = l * l;
		l4 *= l4;
		orr = sr * l4 + dr * (1.0f - a * l4);
		og = sg * l4 + dg * (1.0f - a * l4);
		ob = sb * l4 + db * (1.0f - a * l4);
		oa = a * l4 + da * (1.0f - a * l4);
	}
	p[0] = (unsigned char)(orr > 1.0f ? 255.0f : orr * 255.0f);
	p[1] = (unsigned char)(og > 1.0f ? 255.0f : og * 255.0f);
	p[2] = (unsigned char)(ob > 1.0f ? 255.0f : ob * 255.0f);
	p[3] = (unsigned char)(oa > 1.0f ? 255.0f : oa * 255.0f);
}

static void
sweet_raster_triangle(SweetRaster *r, unsigned long i0, unsigned long i1,
    unsigned long i2)
{
	float x0, y0, u0, v0, c0[4];
	float x1, y1, u1, v1, c1[4];
	float x2, y2, u2, v2, c2[4];
	if (!sweet_vertex(r, i0, &x0, &y0, &u0, &v0, c0) ||
	    !sweet_vertex(r, i1, &x1, &y1, &u1, &v1, c1) ||
	    !sweet_vertex(r, i2, &x2, &y2, &u2, &v2, c2)) {
		return;
	}
	/* Vertex functions without a color attribute leave +color zero; such a
	 * triangle is fully transparent, so the attribute is absent, not black. */
	int zero_color = 1;
	for (int k = 0; k < 4; k++) {
		if (c0[k] != 0.0f || c1[k] != 0.0f || c2[k] != 0.0f) {
			zero_color = 0;
			break;
		}
	}
	if (zero_color) {
		for (int k = 0; k < 4; k++) {
			c0[k] = c1[k] = c2[k] = 1.0f;
		}
	}
	float area = sweet_edge(x0, y0, x1, y1, x2, y2);
	if (area == 0.0f) {
		return;
	}
	int minx = (int)floorf(fminf(fminf(x0, x1), x2));
	int maxx = (int)ceilf(fmaxf(fmaxf(x0, x1), x2));
	int miny = (int)floorf(fminf(fminf(y0, y1), y2));
	int maxy = (int)ceilf(fmaxf(fmaxf(y0, y1), y2));
	if (minx < r->clip_x0) minx = r->clip_x0;
	if (miny < r->clip_y0) miny = r->clip_y0;
	if (maxx > r->clip_x1) maxx = r->clip_x1;
	if (maxy > r->clip_y1) maxy = r->clip_y1;
	float inv_area = 1.0f / area;
	for (int y = miny; y < maxy; y++) {
		for (int x = minx; x < maxx; x++) {
			float px = (float)x + 0.5f, py = (float)y + 0.5f;
			float w0 = sweet_edge(x1, y1, x2, y2, px, py) * inv_area;
			float w1 = sweet_edge(x2, y2, x0, y0, px, py) * inv_area;
			float w2 = sweet_edge(x0, y0, x1, y1, px, py) * inv_area;
			if (w0 < 0.0f || w1 < 0.0f || w2 < 0.0f) {
				continue;
			}
			float u = u0 * w0 + u1 * w1 + u2 * w2;
			float v = v0 * w0 + v1 * w1 + v2 * w2;
			float col[4];
			for (int k = 0; k < 4; k++) {
				col[k] = c0[k] * w0 + c1[k] * w1 + c2[k] * w2;
			}
			if (r->tex != 0 && r->tex_surface != 0) {
				float t[4];
				sweet_texel(r, u, v, t);
				for (int k = 0; k < 4; k++) {
					col[k] *= t[k];
				}
			} else if (r->tex != 0) {
				float t[4];
				sweet_texel(r, u, v, t);
				for (int k = 0; k < 4; k++) {
					col[k] *= t[k];
				}
			}
			sweet_blend_pixel(r, x, y, col);
		}
	}
}

/*
 * Turn a triangle range into host messages. Vertices are decoded to the
 * canonical layout so the host never has to know CA's pipeline descriptors;
 * colours are resolved here exactly as the local rasterizer resolves them.
 */
static int
sweet_ca_batch(const SweetRaster *r, unsigned int dst_id,
    const unsigned char *indices, unsigned long count, unsigned long index_type,
    unsigned int tex_id, unsigned int tex_flags)
{
	if (count < 3 || dst_id == 0 || r->vb == 0) {
		return 0;
	}
	unsigned long triangles = count / 3;
	unsigned long chunks = (triangles + SWEET_CA_TRIS_PER_CHUNK - 1) /
	    SWEET_CA_TRIS_PER_CHUNK;
	/* Reject the batch before anything reaches the wire if any index is
	 * outside the vertex buffer. */
	for (unsigned long k = 0; k < triangles * 3; k++) {
		unsigned long index = index_type == 0 ?
		    ((const unsigned short *)indices)[k] :
		    ((const unsigned int *)indices)[k];
		if ((index + 1) * r->stride > r->vb_len) {
			return 0;
		}
	}
	unsigned char message[4000];
	for (unsigned long chunk = 0; chunk < chunks; chunk++) {
		unsigned long first = chunk * SWEET_CA_TRIS_PER_CHUNK;
		unsigned long last = first + SWEET_CA_TRIS_PER_CHUNK;
		if (last > triangles) {
			last = triangles;
		}
		struct sweet_ca_header header;
		bzero(&header, sizeof(header));
		header.flags = tex_flags;
		header.dst_id = dst_id;
		header.dst_w = (unsigned int)r->dst_w;
		header.dst_h = (unsigned int)r->dst_h;
		header.dst_bpr = (unsigned int)r->dst_bpr;
		header.tex_id = tex_id;
		header.tex_w = (unsigned int)r->tex_w;
		header.tex_h = (unsigned int)r->tex_h;
		header.tex_bpr = (unsigned int)r->tex_bpr;
		header.tex_fmt = (unsigned int)r->tex_fmt_px;
		header.clip_x0 = r->clip_x0;
		header.clip_y0 = r->clip_y0;
		header.clip_x1 = r->clip_x1;
		header.clip_y1 = r->clip_y1;
		header.blend_fn = (unsigned int)r->blend_fn;
		header.tri_count = (unsigned int)(last - first);
		header.chunk_index = (unsigned int)chunk;
		header.chunk_count = (unsigned int)chunks;
		unsigned char *out = message + sizeof(header);
		for (unsigned long t = first; t < last; t++) {
			struct sweet_ca_vertex v[3];
			int zero = 1;
			for (int k = 0; k < 3; k++) {
				unsigned long index = index_type == 0 ?
				    ((const unsigned short *)indices)[t * 3 + k] :
				    ((const unsigned int *)indices)[t * 3 + k];
				float c[4];
				if (!sweet_vertex(r, index, &v[k].x, &v[k].y,
				    &v[k].u, &v[k].v, c)) {
					return 0;
				}
				v[k].r = c[0];
				v[k].g = c[1];
				v[k].b = c[2];
				v[k].a = c[3];
				for (int q = 0; q < 4; q++) {
					if (c[q] != 0.0f) {
						zero = 0;
					}
				}
			}
			if (zero) {
				for (int k = 0; k < 3; k++) {
					v[k].r = v[k].g = v[k].b = v[k].a = 1.0f;
				}
			}
			memcpy(out, v, sizeof(v));
			out += sizeof(v);
		}
		if (sweet_ca_send(message, (unsigned long)(out - message)) != 0) {
			return 0;
		}
	}
	return 1;
}

typedef struct {
	double origin_x, origin_y, width, height, znear, zfar;
} SweetViewport;

typedef struct {
	unsigned long x, y, width, height;
} SweetScissor;

@interface SweetRenderEncoder : SweetObject {
	unsigned int enc_surface;
	id enc_pipeline;
	id enc_vb[8];
	unsigned long enc_vboff[8];
	id enc_fb[8];
	unsigned long enc_fboff[8];
	id enc_vtex[8];
	id enc_tex[8];
	id enc_ib;
	unsigned long enc_iboff;
	unsigned char enc_vbytes[8][256];
	unsigned long enc_vblen[8];
	unsigned char enc_fbytes[8][256];
	unsigned long enc_fblen[8];
	SweetViewport enc_viewport;
	SweetScissor enc_scissor;
	SweetSurfaceMapping enc_map;
	id enc_target_tex;
}
- (id)initWithSurface:(unsigned int)surface;
- (void)setTargetTexture:(id)texture;
- (void)setRenderPipelineState:(id)pipeline;
- (void)setVertexBuffer:(id)buffer offset:(unsigned long)offset
    atIndex:(unsigned long)index;
- (void)setVertexBufferOffset:(unsigned long)offset atIndex:(unsigned long)index;
- (void)setVertexBytes:(const void *)bytes length:(unsigned long)length
    atIndex:(unsigned long)index;
- (void)setViewport:(SweetViewport)viewport;
- (void)setScissorRect:(SweetScissor)rect;
- (void)clearRed:(double)red green:(double)green blue:(double)blue
    alpha:(double)alpha;
- (void)setFragmentBytes:(const void *)bytes length:(unsigned long)length
    atIndex:(unsigned long)index;
- (void)setFragmentTexture:(id)texture atIndex:(unsigned long)index;
- (void)setFragmentSamplerState:(id)state atIndex:(unsigned long)index;
- (void)setFragmentBuffer:(id)buffer offset:(unsigned long)offset
    atIndex:(unsigned long)index;
- (void)setFragmentBufferOffset:(unsigned long)offset atIndex:(unsigned long)index;
- (void)drawIndexedPrimitives:(unsigned long)type indexCount:(unsigned long)count
    indexType:(unsigned long)index_type indexBuffer:(id)index_buffer
    indexBufferOffset:(unsigned long)index_offset;
- (void)setVertexTexture:(id)texture atIndex:(unsigned long)index;
- (void)drawIndexedPrimitives:(unsigned long)type indexCount:(unsigned long)count
    indexType:(unsigned long)index_type indexBuffer:(id)index_buffer
    indexBufferOffset:(unsigned long)index_offset
    instanceCount:(unsigned long)instances;
- (void)drawIndexedPrimitives:(unsigned long)type indexCount:(unsigned long)count
    indexType:(unsigned long)index_type indexBuffer:(id)index_buffer
    indexBufferOffset:(unsigned long)index_offset;

- (void)drawPrimitives:(unsigned long)type vertexStart:(unsigned long)start
    vertexCount:(unsigned long)count;
- (void)endEncoding;
@end

@implementation SweetRenderEncoder

- (id)initWithSurface:(unsigned int)surface
{
	enc_surface = surface;
	if (surface != 0 && sweet_surface_map(surface, &enc_map) == 0) {
		dprintf(console_fd,
		    "SWEETMETAL: mapped dest=%u %lux%lu bpr=%lu base=%p", surface,
		    enc_map.width, enc_map.height, enc_map.bytes_per_row,
		    enc_map.base);
		dprintf(console_fd, "%c", 10);
	}
	return self;
}

/* Render targets created with newTextureWithDescriptor have no IOSurface;
 * keep their pixels here so later draws can sample what was rendered. */
- (void)setTargetTexture:(id)texture
{
	enc_target_tex = texture;
	if (texture == 0 || enc_map.base != 0) {
		return;
	}
	if (((unsigned int (*)(id, SEL))objc_msgSend)(texture,
	    sel_registerName("surfaceID")) != 0) {
		return;
	}
	if (((int (*)(id, SEL))objc_msgSend)(texture,
	    sel_registerName("ensureRenderPixels")) != 0) {
		return;
	}
	enc_map.base = (unsigned char *)((void *(*)(id, SEL))objc_msgSend)(
	    texture, sel_registerName("pixelBytes"));
	enc_map.width = ((unsigned long (*)(id, SEL))objc_msgSend)(texture,
	    sel_registerName("width"));
	enc_map.height = ((unsigned long (*)(id, SEL))objc_msgSend)(texture,
	    sel_registerName("height"));
	enc_map.bytes_per_row = ((unsigned long (*)(id, SEL))objc_msgSend)(
	    texture, sel_registerName("bytesPerRow"));
	if (enc_map.bytes_per_row != enc_map.width * 4) {
		dprintf(console_fd,
		    "SWEETMETAL: skip offscreen %lux%lu bpr=%lu (not 8-bit)%c",
		    enc_map.width, enc_map.height, enc_map.bytes_per_row, 10);
		enc_map.base = 0;
		enc_map.width = 0;
		enc_map.height = 0;
		enc_map.bytes_per_row = 0;
		return;
	}
	((void (*)(id, SEL))objc_msgSend)(texture, sel_registerName("markRendered"));
	dprintf(console_fd,
	    "SWEETMETAL: render target offscreen %lux%lu bpr=%lu base=%p%c",
	    enc_map.width, enc_map.height, enc_map.bytes_per_row,
	    enc_map.base, 10);
}

- (void)clearRed:(double)red green:(double)green blue:(double)blue
    alpha:(double)alpha
{
	unsigned int rgba = (unsigned int)sweet_channel(red) |
	    ((unsigned int)sweet_channel(green) << 8) |
	    ((unsigned int)sweet_channel(blue) << 16) |
	    ((unsigned int)sweet_channel(alpha) << 24);
	sweet_surface_fill(&enc_map, rgba);
	dprintf(console_fd, "SWEETMETAL: clear dest=%u to %#x", enc_surface, rgba);
	dprintf(console_fd, "%c", 10);
}

- (void)setRenderPipelineState:(id)pipeline
{
	enc_pipeline = pipeline;
}

- (void)setVertexBuffer:(id)buffer offset:(unsigned long)offset
    atIndex:(unsigned long)index
{
	if (index < 8) {
		enc_vb[index] = buffer;
		enc_vboff[index] = offset;
	}
}

- (void)setVertexBufferOffset:(unsigned long)offset atIndex:(unsigned long)index
{
	if (index < 8) {
		enc_vboff[index] = offset;
	}
}

- (void)setViewport:(SweetViewport)viewport
{
	enc_viewport = viewport;
	dprintf(console_fd,
	    "SWEETMETAL: viewport %g,%g %gx%g z=%g..%g", viewport.origin_x,
	    viewport.origin_y, viewport.width, viewport.height, viewport.znear,
	    viewport.zfar);
	dprintf(console_fd, "%c", 10);
}

- (void)setScissorRect:(SweetScissor)rect
{
	enc_scissor = rect;
	dprintf(console_fd, "SWEETMETAL: scissor %lu,%lu %lux%lu", rect.x, rect.y,
	    rect.width, rect.height);
	dprintf(console_fd, "%c", 10);
}

- (void)setVertexBytes:(const void *)bytes length:(unsigned long)length
    atIndex:(unsigned long)index
{
	if (index < 8 && bytes != 0) {
		unsigned long n = length < 256 ? length : 256;
		memcpy(enc_vbytes[index], bytes, n);
		enc_vblen[index] = n;
		dprintf(console_fd, "SWEETMETAL: vbytes[%lu] len=%lu", index, length);
		dprintf(console_fd, "%c", 10);
		sweet_hex64("vbB64_", (unsigned int)index, enc_vbytes[index]);
	}
}

- (void)setFragmentBytes:(const void *)bytes length:(unsigned long)length
    atIndex:(unsigned long)index
{
	if (index < 8 && bytes != 0) {
		unsigned long n = length < 256 ? length : 256;
		memcpy(enc_fbytes[index], bytes, n);
		enc_fblen[index] = n;
		dprintf(console_fd, "SWEETMETAL: fbytes[%lu] len=%lu", index, length);
		dprintf(console_fd, "%c", 10);
		sweet_hex64("fbB64_", (unsigned int)index, enc_fbytes[index]);
	}
}

- (void)setFragmentTexture:(id)texture atIndex:(unsigned long)index
{
	if (index < 8) {
		enc_tex[index] = texture;
	}
}

- (void)setFragmentSamplerState:(id)state atIndex:(unsigned long)index
{
	sweet_log("encoder", "setFragmentSamplerState:atIndex:");
}

- (void)setFragmentBuffer:(id)buffer offset:(unsigned long)offset
    atIndex:(unsigned long)index
{
	if (index < 8) {
		enc_fb[index] = buffer;
		enc_fboff[index] = offset;
	}
}

- (void)setFragmentBufferOffset:(unsigned long)offset atIndex:(unsigned long)index
{
	if (index < 8) {
		enc_fboff[index] = offset;
	}
}

- (void)setVertexTexture:(id)texture atIndex:(unsigned long)index
{
	if (index < 8) {
		enc_vtex[index] = texture;
	}
}

static unsigned int
sweet_texture_surface(id texture)
{
	if (texture == 0) {
		return 0;
	}
	if (!((BOOL (*)(id, SEL, Class))objc_msgSend)(texture,
	    sel_registerName("isKindOfClass:"), objc_getClass("SweetTexture"))) {
		return 0;
	}
	return ((unsigned int (*)(id, SEL))objc_msgSend)(texture,
	    sel_registerName("surfaceID"));
}

- (void)drawIndexedPrimitives:(unsigned long)type indexCount:(unsigned long)count
    indexType:(unsigned long)index_type indexBuffer:(id)index_buffer
    indexBufferOffset:(unsigned long)index_offset
    instanceCount:(unsigned long)instances
{
	enc_ib = index_buffer;
	enc_iboff = index_offset;
	BOOL interest = (enc_surface == 5) ? (sweet_draw_logs5 < 40) :
	    (sweet_draw_logs < 12);
	if (interest) {
		const char *pipeline = "(none)";
		if (enc_pipeline != 0 && ((BOOL (*)(id, SEL, Class))objc_msgSend)(
		    enc_pipeline, sel_registerName("isKindOfClass:"),
		    objc_getClass("SweetPipeline"))) {
			pipeline = ((const char *(*)(id, SEL))objc_msgSend)(
			    enc_pipeline, sel_registerName("nameC"));
		}
		dprintf(console_fd,
		    "SWEETMETAL: draw pid=%d dest=%u pipe=%s prim=%lu count=%lu"
		    " itype=%lu inst=%lu ib=%p+%lu\n", getpid(), enc_surface,
		    pipeline, type, count, index_type, instances, index_buffer,
		    index_offset);
		for (unsigned int i = 0; i < 8; i++) {
			if (enc_vb[i] != 0) {
				void *contents = (void *)((void *(*)(id, SEL))objc_msgSend)(
				    enc_vb[i], sel_registerName("contents"));
				unsigned long length = ((unsigned long (*)(id, SEL))objc_msgSend)(
				    enc_vb[i], sel_registerName("length"));
				dprintf(console_fd,
				    "SWEETMETAL:   vb[%u]=%p+%lu len=%lu\n", i,
				    contents, enc_vboff[i], length);
				{
					const char *vbase = (const char *)contents +
					    (enc_vboff[i] < length ? enc_vboff[i] : 0);
					unsigned long n = (enc_surface == 5) ? 256 : 64;
					for (unsigned long off = 0; off < n; off += 64) {
						dprintf(console_fd,
						    "SWEETMETAL:   chunk %lu", off);
						dprintf(console_fd, "%c", 10);
						sweet_hex64("vb64_", i, vbase + off);
					}
				}
			}
			if (enc_tex[i] != 0) {
				dprintf(console_fd, "SWEETMETAL:   tex[%u]=surface %u\n",
				    i, sweet_texture_surface(enc_tex[i]));
			}
			if (enc_vtex[i] != 0) {
				dprintf(console_fd, "SWEETMETAL:   vtex[%u]=surface %u\n",
				    i, sweet_texture_surface(enc_vtex[i]));
			}
		}
		for (unsigned int i = 0; i < 8; i++) {
			if (enc_fb[i] != 0) {
				void *contents = (void *)((void *(*)(id, SEL))objc_msgSend)(
				    enc_fb[i], sel_registerName("contents"));
				unsigned long length = ((unsigned long (*)(id, SEL))objc_msgSend)(
				    enc_fb[i], sel_registerName("length"));
				const char *base = (const char *)contents +
				    (enc_fboff[i] < length ? enc_fboff[i] : 0);
				dprintf(console_fd,
				    "SWEETMETAL:   fb[%u]=%p+%lu len=%lu %08x %08x %08x %08x",
				    i, contents, enc_fboff[i], length,
				    *(const unsigned int *)base,
				    *(const unsigned int *)(base + 4),
				    *(const unsigned int *)(base + 8),
				    *(const unsigned int *)(base + 12));
				sweet_hex64("fb64_", i, base);
			}
		}
		if (index_buffer != 0) {
			void *contents = (void *)((void *(*)(id, SEL))objc_msgSend)(
			    index_buffer, sel_registerName("contents"));
			unsigned long length = ((unsigned long (*)(id, SEL))objc_msgSend)(
			    index_buffer, sel_registerName("length"));
			dprintf(console_fd, "SWEETMETAL:   ib=%p+%lu len=%lu\n",
			    contents, index_offset, length);
			{
				const unsigned short *ip = (const unsigned short *)
				    ((const char *)contents + (index_offset < length ? index_offset : 0));
				unsigned long imax = 0;
				unsigned long n = count < 512 ? count : 512;
				for (unsigned long k = 0; k < n && (index_offset + 2 * k) < length; k++) {
					if (ip[k] > imax) {
						imax = ip[k];
					}
				}
				dprintf(console_fd, "SWEETMETAL:   imax=%lu", imax);
				dprintf(console_fd, "%c", 10);
				sweet_hex32("ibytes", 0,
				    (const char *)contents + (index_offset < length ? index_offset : 0));
			}
		}
		if (enc_surface == 5) {
			sweet_draw_logs5++;
		} else {
			sweet_draw_logs++;
		}
	}

	if (enc_map.base != 0 && enc_pipeline != 0) {
		SweetRaster r;
		SweetSurfaceMapping src_map;
		int src_mapped = 0;
		bzero(&src_map, sizeof(src_map));
		bzero(&r, sizeof(r));
		unsigned long vbuf = ((unsigned long (*)(id, SEL, unsigned long))
		    objc_msgSend)(enc_pipeline,
		    sel_registerName("attributeBuffer:"), 0);
		if (vbuf >= 8 || enc_vb[vbuf] == 0) {
			vbuf = 1;
		}
		unsigned long stride = ((unsigned long (*)(id, SEL, unsigned long))
		    objc_msgSend)(enc_pipeline,
		    sel_registerName("strideForBuffer:"), vbuf);
		r.pos_fmt = ((unsigned long (*)(id, SEL, unsigned long))objc_msgSend)(
		    enc_pipeline, sel_registerName("attributeFormat:"), 0);
		r.pos_off = ((unsigned long (*)(id, SEL, unsigned long))objc_msgSend)(
		    enc_pipeline, sel_registerName("attributeOffset:"), 0);
		r.tex_fmt = ((unsigned long (*)(id, SEL, unsigned long))objc_msgSend)(
		    enc_pipeline, sel_registerName("attributeFormat:"), 1);
		r.tex_off = ((unsigned long (*)(id, SEL, unsigned long))objc_msgSend)(
		    enc_pipeline, sel_registerName("attributeOffset:"), 1);
		r.col_fmt = ((unsigned long (*)(id, SEL, unsigned long))objc_msgSend)(
		    enc_pipeline, sel_registerName("attributeFormat:"), 3);
		r.col_off = ((unsigned long (*)(id, SEL, unsigned long))objc_msgSend)(
		    enc_pipeline, sel_registerName("attributeOffset:"), 3);
		if (r.pos_fmt == 0 || r.pos_fmt == 29) {
			r.pos_fmt = 31;
		}
		if (r.tex_fmt == 0) {
			r.tex_fmt = 29;
			r.tex_off = 16;
		}
		if (r.col_fmt == 0) {
			r.col_fmt = 27;
			r.col_off = 32;
		}
		r.blend_fn = 54;
		if (((BOOL (*)(id, SEL, Class))objc_msgSend)(enc_pipeline,
		    sel_registerName("isKindOfClass:"), objc_getClass("SweetPipeline"))) {
			double blend = ((double (*)(id, SEL, const char *))objc_msgSend)(
			    enc_pipeline, sel_registerName("fcValue:"), "fc_blend_function");
			if (blend >= 0.0) {
				r.blend_fn = (unsigned long)blend;
			}
			double tfn = ((double (*)(id, SEL, const char *))objc_msgSend)(
			    enc_pipeline, sel_registerName("fcValue:"), "fc_texture_function");
			if (tfn >= 0.0) {
				r.tex_fn = (unsigned long)tfn;
			}
			double dfn = ((double (*)(id, SEL, const char *))objc_msgSend)(
			    enc_pipeline, sel_registerName("fcValue:"),
			    "fc_destination_function");
			if (dfn >= 0.0) {
				r.dst_fn = (unsigned long)dfn;
			}
			double img = ((double (*)(id, SEL, const char *))objc_msgSend)(
			    enc_pipeline, sel_registerName("fcValue:"), "fc_image_count");
			if (img >= 0.0) {
				r.img_count = (unsigned long)img;
			}
		}
		r.stride = stride != 0 ? stride : 48;
		if (enc_vb[vbuf] != 0) {
			void *vc = (void *)((void *(*)(id, SEL))objc_msgSend)(enc_vb[vbuf],
			    sel_registerName("contents"));
			unsigned long vl = ((unsigned long (*)(id, SEL))objc_msgSend)(
			    enc_vb[vbuf], sel_registerName("length"));
			unsigned long vo = enc_vboff[vbuf];
			if (vc != 0 && vo < vl) {
				r.vb = (const unsigned char *)vc + vo;
				r.vb_len = vl - vo;
			}
		}
		for (unsigned int i = 0; i < 8 && r.tex == 0; i++) {
			if (enc_tex[i] == 0 || enc_tex[i] == enc_target_tex) {
				continue;
			}
			void *px = (void *)((void *(*)(id, SEL))objc_msgSend)(enc_tex[i],
			    sel_registerName("pixelBytes"));
			unsigned int sid = ((unsigned int (*)(id, SEL))objc_msgSend)(enc_tex[i],
			    sel_registerName("surfaceID"));
			if (px == 0 && sid != 0 && sid != enc_surface) {
				/* Cross-process layer content lives in an IOSurface. */
				if (sweet_surface_map(sid, &src_map) == 0) {
					px = src_map.base;
					src_mapped = 1;
					dprintf(console_fd,
					    "SWEETMETAL: sample surface=%u %lux%lu bpr=%lu\n",
					    sid, src_map.width, src_map.height,
					    src_map.bytes_per_row);
				}
			}
			if (px == 0) {
				continue;
			}
			r.tex = (const unsigned char *)px;
			r.tex_owner = enc_tex[i];
			r.tex_mapped = src_mapped;
			r.tex_w = ((unsigned long (*)(id, SEL))objc_msgSend)(enc_tex[i],
			    sel_registerName("width"));
			r.tex_h = ((unsigned long (*)(id, SEL))objc_msgSend)(enc_tex[i],
			    sel_registerName("height"));
			r.tex_fmt_px = ((unsigned long (*)(id, SEL))objc_msgSend)(enc_tex[i],
			    sel_registerName("pixelFormat"));
			r.tex_bpr = ((unsigned long (*)(id, SEL))objc_msgSend)(enc_tex[i],
			    sel_registerName("bytesPerRow"));
			r.tex_surface = sid;
			/* Uploaded pixels keep their declared format; IOSurface memory
			 * this process renders into, and offscreen targets it has
			 * rendered, are RGBA8 whatever the format says. */
			r.tex_internal = src_mapped ? 1 : 0;
			if (!r.tex_internal && ((BOOL (*)(id, SEL, Class))objc_msgSend)(
			    enc_tex[i], sel_registerName("isKindOfClass:"),
			    objc_getClass("SweetTexture"))) {
				r.tex_internal = ((unsigned long (*)(id, SEL))objc_msgSend)(
				    enc_tex[i], sel_registerName("rendered")) != 0;
			}
			if (src_mapped) {
				if (r.tex_w == 0) r.tex_w = src_map.width;
				if (r.tex_h == 0) r.tex_h = src_map.height;
				if (r.tex_bpr == 0) r.tex_bpr = src_map.bytes_per_row;
			}
		}
		r.dst = enc_map.base;
		r.dst_w = enc_map.width;
		r.dst_h = enc_map.height;
		r.dst_bpr = enc_map.bytes_per_row;
		r.clip_x0 = enc_scissor.width != 0 ? (int)enc_scissor.x : 0;
		r.clip_y0 = enc_scissor.height != 0 ? (int)enc_scissor.y : 0;
		r.clip_x1 = enc_scissor.width != 0 ? (int)(enc_scissor.x + enc_scissor.width) :
		    (int)r.dst_w;
		r.clip_y1 = enc_scissor.height != 0 ? (int)(enc_scissor.y + enc_scissor.height) :
		    (int)r.dst_h;
		/*
		 * Hand the batch to the host when it can address both surfaces.
		 * Uploaded pixel buffers travel once per version; a texture this
		 * process rendered offscreen stays local because its contents
		 * change every frame and live in heap memory.
		 */
		int host_ok = !sweet_ca_disabled && sweet_accel_port != 0 &&
		    enc_surface != 0 && r.dst != 0 && r.dst_bpr != 0;
		unsigned int tex_id = 0;
		unsigned int tex_flags = 0;
		if (host_ok && r.tex != 0) {
			if (r.tex_mapped) {
				if (!sweet_ca_map(r.tex_surface)) {
					host_ok = 0;
				} else {
					tex_id = r.tex_surface;
					tex_flags = SWEET_CA_F_TEXTURED;
				}
			} else if (r.tex_owner != 0 && !r.tex_internal) {
				SweetTexture *texture = (SweetTexture *)r.tex_owner;
				if (texture->tex_host_id == 0) {
					texture->tex_host_id = sweet_ca_upload_ids++;
				}
				tex_id = texture->tex_host_id;
				tex_flags = SWEET_CA_F_TEXTURED | SWEET_CA_F_UPLOAD_TEX;
				if (texture->tex_host_version != texture->tex_version) {
					if (!sweet_ca_upload(tex_id, (unsigned int)r.tex_fmt_px,
					    r.tex_w, r.tex_h, r.tex_bpr, r.tex,
					    r.tex_bpr * r.tex_h, tex_flags)) {
						host_ok = 0;
					} else {
						texture->tex_host_version = texture->tex_version;
					}
				}
			} else {
				host_ok = 0;
			}
			if (host_ok && r.tex_internal) {
				tex_flags |= SWEET_CA_F_INTERNAL;
			}
		}
		if (host_ok && (r.tex_w > 65535 || r.tex_h > 65535 ||
		    r.dst_w > 65535 || r.dst_h > 65535)) {
			host_ok = 0;
		}
		if (host_ok && !sweet_ca_map(enc_surface)) {
			host_ok = 0;
		}
		if (r.vb != 0 && index_buffer != 0 && r.stride >= 16 && count >= 3 &&
		    count <= 4096) {
			unsigned long long raster_t0 = mach_absolute_time();
			void *ic = (void *)((void *(*)(id, SEL))objc_msgSend)(index_buffer,
			    sel_registerName("contents"));
			unsigned long il = ((unsigned long (*)(id, SEL))objc_msgSend)(
			    index_buffer, sel_registerName("length"));
			unsigned long isz = index_type == 0 ? 2 : 4;
			if (ic != 0 && index_offset < il) {
				unsigned long n = (il - index_offset) / isz;
				if (n > count) {
					n = count;
				}
				const unsigned char *ip = (const unsigned char *)ic + index_offset;
				int submitted = 0;
				if (host_ok) {
					submitted = sweet_ca_batch(&r, enc_surface, ip, n,
					    index_type, tex_id, tex_flags);
					if (submitted) {
						sweet_ca_submitted++;
					}
				}
				if (!submitted) {
					sweet_ca_local++;
					for (unsigned long k = 0; k + 2 < n; k += 3) {
						unsigned long a, b, c;
						if (index_type == 0) {
							a = ((const unsigned short *)ip)[k];
							b = ((const unsigned short *)ip)[k + 1];
							c = ((const unsigned short *)ip)[k + 2];
						} else {
							a = ((const unsigned int *)ip)[k];
							b = ((const unsigned int *)ip)[k + 1];
							c = ((const unsigned int *)ip)[k + 2];
						}
						sweet_raster_triangle(&r, a, b, c);
					}
					dprintf(console_fd,
					    "SWEETMETAL: raster dest=%u tris=%lu stride=%lu tex=%p"
					    " fmt=%lu %lux%lu bpr=%lu blend=%lu tfn=%lu dfn=%lu"
					    " img=%lu ms=%.2f", enc_surface,
					    count / 3, r.stride, r.tex, r.tex_fmt_px, r.tex_w,
					    r.tex_h, r.tex_bpr, r.blend_fn, r.tex_fn, r.dst_fn,
					    r.img_count,
					    sweet_ticks_ms(mach_absolute_time() - raster_t0));
					dprintf(console_fd, "%c", 10);
				}
			}
		}
		if (src_mapped) {
			sweet_surface_unmap(&src_map);
		}
	}
}

- (void)drawIndexedPrimitives:(unsigned long)type indexCount:(unsigned long)count
    indexType:(unsigned long)index_type indexBuffer:(id)index_buffer
    indexBufferOffset:(unsigned long)index_offset
{
	[self drawIndexedPrimitives:type indexCount:count indexType:index_type
	    indexBuffer:index_buffer indexBufferOffset:index_offset instanceCount:1];
}


- (void)drawPrimitives:(unsigned long)type vertexStart:(unsigned long)start
    vertexCount:(unsigned long)count
{
	if (sweet_draw_logs < 12) {
		dprintf(console_fd,
		    "SWEETMETAL: draw pid=%d dest=%u prim=%lu vstart=%lu count=%lu\n",
		    getpid(), enc_surface, type, start, count);
		sweet_draw_logs++;
	}
	if ((type == 3 || type == 4) && count >= 3 && count <= 4096) {
		static unsigned int indices[4096];
		unsigned long n = 0;
		if (type == 3) {
			for (unsigned long i = 0; i < count; i++) {
				indices[n++] = (unsigned int)(start + i);
			}
		} else {
			for (unsigned long i = 2; i < count; i++) {
				indices[n++] = (unsigned int)(start +
				    ((i & 1) ? i - 1 : i - 2));
				indices[n++] = (unsigned int)(start +
				    ((i & 1) ? i - 2 : i - 1));
				indices[n++] = (unsigned int)(start + i);
			}
		}
		SweetBuffer *tmp = [[SweetBuffer alloc] initWithBytes:indices
		    length:n * sizeof(unsigned int)];
		[self drawIndexedPrimitives:3 indexCount:n indexType:1
		    indexBuffer:tmp indexBufferOffset:0 instanceCount:1];
	}
}

- (void)endEncoding
{
	sweet_log("encoder", "endEncoding");
	/* The drawable must be complete before the swap record is sent. */
	sweet_ca_flush();
	if (enc_surface != 0 && enc_map.base != 0 && enc_map.width >= 1000 &&
	    enc_map.height >= 2000) {
		sweet_last_surface = enc_surface;
		sweet_last_width = enc_map.width;
		sweet_last_height = enc_map.height;
	}
	sweet_surface_unmap(&enc_map);
}

@end

@interface SweetCommandBuffer : SweetObject {
	unsigned int pending_surface[8];
	unsigned int pending_color[8];
	int pending_count;
}
- (void)commit;
- (void)commitAndWaitUntilSubmitted;
- (void)enqueue;
- (void)presentDrawable:(id)drawable;
- (void)waitUntilCompleted;
- (id)renderCommandEncoderWithDescriptor:(id)descriptor;
- (id)blitCommandEncoder;
- (id)computeCommandEncoder;
- (void)flushFills;
@end

@implementation SweetCommandBuffer

- (void)flushFills
{
	for (int i = 0; i < pending_count; i++) {
		unsigned int request[6] = {
			pending_surface[i], pending_color[i], 0, 0, 0, 0
		};
		unsigned long output_size = 0;
		int result = IOConnectCallStructMethod(sweet_accel_port, 0x100,
		    request, sizeof(request), 0, &output_size);
		if (sweet_fill_logs < 12) {
			sweet_fill_logs++;
			dprintf(console_fd,
			    "SWEETMETAL: fill surface %u color=#%06x -> 0x%x\n",
			    pending_surface[i], pending_color[i], result);
		}
	}
	pending_count = 0;
}

- (void)commit
{
	sweet_log("buffer", "commit");
	sweet_ca_flush();
	[self flushFills];
	sweet_present_pending();
}

- (void)commitAndWaitUntilSubmitted
{
	sweet_log("buffer", "commitAndWaitUntilSubmitted");
	sweet_ca_flush();
	[self flushFills];
	sweet_present_pending();
}

- (void)enqueue
{
	sweet_log("buffer", "enqueue");
}

- (void)presentDrawable:(id)drawable
{
	sweet_log("buffer", "presentDrawable");
}

- (void)waitUntilCompleted
{
	sweet_log("buffer", "waitUntilCompleted");
}

- (id)renderCommandEncoderWithDescriptor:(id)descriptor
{
	sweet_log("buffer", "renderCommandEncoderWithDescriptor");
	unsigned int surface = 0;
	id texture = 0;
	BOOL texture_target = 0;
	unsigned long action = 0;
	double red = 0, green = 0, blue = 0, alpha = 0;
	if (descriptor != 0) {
		id attachments = sweet_msg_id(descriptor, "colorAttachments");
		id attachment = attachments != 0 ?
		    sweet_msg_id_idx(attachments, "objectAtIndexedSubscript:", 0) : 0;
		if (attachment == 0 && attachments != 0) {
			attachment = sweet_msg_id_idx(attachments, "objectAtIndex:", 0);
		}
		texture = attachment != 0 ? sweet_msg_id(attachment, "texture") : 0;
		action = attachment != 0 ?
		    sweet_msg_ul(attachment, "loadAction") : 0;
		if (texture != 0 &&
		    ((BOOL (*)(id, SEL, Class))objc_msgSend)(texture,
		    sel_registerName("isKindOfClass:"), objc_getClass("SweetTexture"))) {
			texture_target = 1;
			surface = ((unsigned int (*)(id, SEL))objc_msgSend)(texture,
			    sel_registerName("surfaceID"));
			if (action == 2) {
				typedef struct { double red, green, blue, alpha; } ClearColor;
				ClearColor color = ((ClearColor (*)(id, SEL))objc_msgSend)(
				    attachment, sel_registerName("clearColor"));
				red = color.red; green = color.green;
				blue = color.blue; alpha = color.alpha;
				if (pending_count < 8 && surface != 0) {
					pending_surface[pending_count] = surface;
					pending_color[pending_count] =
					    (sweet_channel(red) << 16) |
					    (sweet_channel(green) << 8) |
					    sweet_channel(blue);
					pending_count++;
				}
			}
			if (sweet_encoder_logs < 24) {
				sweet_encoder_logs++;
				dprintf(console_fd,
				    "SWEETMETAL: pass pid=%d dest=%u action=%lu"
				    " clear=%.3f,%.3f,%.3f,%.3f\n", getpid(),
				    surface, action, red, green, blue, alpha);
			}
		}
	}
	SweetRenderEncoder *encoder = [[SweetRenderEncoder alloc]
	    initWithSurface:surface];
	if (texture != 0 && texture_target) {
		[encoder setTargetTexture:texture];
	}
	if (action == 2) {
		[encoder clearRed:red green:green blue:blue alpha:alpha];
	}
	return encoder;
}

- (id)blitCommandEncoder
{
	sweet_log("buffer", "blitCommandEncoder");
	return [[SweetCommandEncoder alloc] init];
}

- (id)computeCommandEncoder
{
	sweet_log("buffer", "computeCommandEncoder");
	return [[SweetCommandEncoder alloc] init];
}

@end

@interface SweetCommandQueue : SweetObject {
	id queue_device;
}
- (void)setSweetDevice:(id)device;
- (id)device;
- (id)commandBuffer;
- (id)commandBufferWithUnretainedReferences;
- (id)commandBufferWithDescriptor:(id)descriptor;
@end

@implementation SweetCommandQueue

- (void)setSweetDevice:(id)device
{
	queue_device = device;
}

- (id)device
{
	sweet_log("queue", "device");
	return queue_device != 0 ? queue_device : sweet_device_self;
}

- (id)commandBuffer
{
	sweet_log("queue", "commandBuffer");
	return [[SweetCommandBuffer alloc] init];
}

- (id)commandBufferWithUnretainedReferences
{
	sweet_log("queue", "commandBufferWithUnretainedReferences");
	return [[SweetCommandBuffer alloc] init];
}

- (id)commandBufferWithDescriptor:(id)descriptor
{
	sweet_log("queue", "commandBufferWithDescriptor");
	return [[SweetCommandBuffer alloc] init];
}

@end

@implementation SweetMetalDevice

- (id)initWithAcceleratorPort:(io_object_t)port
{
	sweet_log("initWithAcceleratorPort port=", 0);
	if (console_fd >= 0) {
		dprintf(console_fd, "SWEETMETAL: port=%u self=%p\n", port, self);
	}
	sweet_device_self = self;
	sweet_accel_port = sweet_open_gpu_service();
	if (console_fd >= 0) {
		dprintf(console_fd, "SWEETMETAL: accel port %u -> own %u\n",
		    port, sweet_accel_port);
	}
	return self;
}

- (id)name
{
	sweet_log("msg", "name");
	return ((id (*)(id, SEL, const char *))objc_msgSend)(
		(id)objc_getClass("NSString"),
		sel_registerName("stringWithUTF8String:"), "SweetMetal");
}

/*
 * The inherited MTLIOAccelDevice implementations read ivars that this object
 * never initialized; report the same answers a real GPU would so callers
 * (CoreAnimation, Metal validation) get past device selection.
 */
- (unsigned long long)registryID
{
	sweet_log("msg", "registryID");
	return 1;
}

- (BOOL)isHeadless
{
	sweet_log("msg", "isHeadless");
	return 0;
}

- (BOOL)isLowPower
{
	sweet_log("msg", "isLowPower");
	return 0;
}

- (BOOL)isRemovable
{
	sweet_log("msg", "isRemovable");
	return 0;
}

- (BOOL)hasUnifiedMemory
{
	sweet_log("msg", "hasUnifiedMemory");
	return 1;
}

- (BOOL)supportsFamily:(long)family
{
	sweet_log("msg", "supportsFamily");
	dprintf(console_fd, "SWEETMETAL:   family=%ld\n", family);
	return 1;
}

- (BOOL)supportsFeatureSet:(unsigned long)featureSet
{
	sweet_log("msg", "supportsFeatureSet");
	dprintf(console_fd, "SWEETMETAL:   set=%lu\n", featureSet);
	return 1;
}

- (BOOL)supportsTextureSampleCount:(unsigned long)count
{
	sweet_log("msg", "supportsTextureSampleCount");
	dprintf(console_fd, "SWEETMETAL:   count=%lu\n", count);
	return count <= 4;
}

- (SweetSize)maxThreadsPerThreadgroup
{
	SweetSize size = { 1024, 1024, 64 };
	sweet_log("msg", "maxThreadsPerThreadgroup");
	return size;
}

- (unsigned long)maxBufferLength
{
	sweet_log("msg", "maxBufferLength");
	return 1UL << 30;
}

/* CA's MetalContext uses these legacySPI limits (objc_msgSend$maxTextureWidth2D
 * etc.), not maxTextureDimension2D; a zero rejects every display surface. */
- (unsigned long)maxTextureWidth2D
{
	return 16384;
}

- (unsigned long)maxTextureHeight2D
{
	return 16384;
}

- (unsigned long)maxFragmentTextures
{
	return 32;
}

- (unsigned long)maxVertexTextures
{
	return 32;
}

- (unsigned long)maxFragmentSamplers
{
	return 16;
}

- (unsigned long)maxVertexSamplers
{
	return 16;
}

- (unsigned long)maxColorAttachments
{
	return 8;
}

- (unsigned long)maxTextureDimension2D
{
	static unsigned int logged;
	if (logged < 8) {
		logged++;
		sweet_log("msg", "maxTextureDimension2D -> 16384");
	}
	return 16384;
}

- (unsigned long)maxTextureDimension3D
{
	return 2048;
}

- (unsigned long)maxTextureDimensionCube
{
	return 16384;
}

- (unsigned long)maxTextureArrayLayers
{
	return 2048;
}

- (unsigned long)maxFramebufferWidth
{
	return 16384;
}

- (unsigned long)maxFramebufferHeight
{
	return 16384;
}

- (unsigned long)maxThreadgroupMemoryLength
{
	sweet_log("msg", "maxThreadgroupMemoryLength");
	return 32768;
}

- (unsigned long)recommendedMaxWorkingSetSize
{
	sweet_log("msg", "recommendedMaxWorkingSetSize");
	return 1UL << 30;
}

- (unsigned long long)currentAllocatedSize
{
	sweet_log("msg", "currentAllocatedSize");
	return 0;
}

- (unsigned long)location
{
	sweet_log("msg", "location");
	return 0;
}

- (unsigned long)locationNumber
{
	sweet_log("msg", "locationNumber");
	return 0;
}

- (id)originalObject
{
	sweet_log("msg", "originalObject");
	return self;
}

- (unsigned long)gpuCoreCount
{
	sweet_log("msg", "gpuCoreCount");
	return 1;
}

/*
 * Creation entry points: log only. Returning nil keeps the caller alive long
 * enough to reveal the next selector it asks for.
 */
- (id)newCommandQueue
{
	sweet_log("msg", "newCommandQueue");
	SweetCommandQueue *queue = [[SweetCommandQueue alloc] init];
	((void (*)(id, SEL, id))objc_msgSend)(queue,
	    sel_registerName("setSweetDevice:"), self);
	return queue;
}

- (id)newCommandQueueWithMaxCommandBufferCount:(unsigned long)count
{
	sweet_log("msg", "newCommandQueueWithMaxCommandBufferCount");
	dprintf(console_fd, "SWEETMETAL:   count=%lu\n", count);
	return [[SweetCommandQueue alloc] init];
}

- (id)newDefaultLibrary
{
	sweet_log("msg", "newDefaultLibrary");
	return [[SweetOpaque alloc] init];
}

- (id)newLibraryWithSource:(id)source options:(id)options error:(id *)error
{
	sweet_log("msg", "newLibraryWithSource:options:error:");
	return [[SweetOpaque alloc] init];
}

- (id)newLibraryWithURL:(id)url error:(id *)error
{
	sweet_log("msg", "newLibraryWithURL:error:");
	sweet_lib_path_is(sweet_cstr(sweet_msg_id(url, "path")));
	if (url != 0) {
		id path = sweet_msg_id(url, "path");
		dprintf(console_fd, "SWEETMETAL: library url %s", sweet_cstr(path));
		dprintf(console_fd, "%c", 10);
	}
	return [[SweetOpaque alloc] init];
}

- (id)newLibraryWithFile:(id)path error:(id *)error
{
	sweet_log("msg", "newLibraryWithFile:error:");
	return [[SweetOpaque alloc] init];
}

- (id)newLibraryWithData:(id)data error:(id *)error
{
	sweet_log("msg", "newLibraryWithData:error:");
	return [[SweetOpaque alloc] init];
}

- (id)newPipelineLibraryWithFilePath:(id)path error:(id *)error
{
	sweet_log("msg", "newPipelineLibraryWithFilePath:error:");
	return [[SweetOpaque alloc] init];
}

- (id)newDefaultLibraryWithBundle:(id)bundle error:(id *)error
{
	sweet_log("msg", "newDefaultLibraryWithBundle:error:");
	return [[SweetOpaque alloc] init];
}

- (id)newRenderPipelineStateWithDescriptor:(id)descriptor
    options:(unsigned long)options error:(id *)error
{
	sweet_log("msg", "newRenderPipelineStateWithDescriptor:options:error:");
	return sweet_pipeline_from_descriptor(descriptor);
}

- (id)newComputePipelineStateWithFunction:(id)function error:(id *)error
{
	sweet_log("msg", "newComputePipelineStateWithFunction:error:");
	return [[SweetOpaque alloc] init];
}

- (id)newComputePipelineStateWithDescriptor:(id)descriptor
    options:(unsigned long)options reflection:(id *)reflection error:(id *)error
{
	sweet_log("msg", "newComputePipelineStateWithDescriptor:options:reflection:error:");
	return [[SweetOpaque alloc] init];
}

- (id)newComputePipelineStateWithDescriptor:(id)descriptor error:(id *)error
{
	sweet_log("msg", "newComputePipelineStateWithDescriptor:error:");
	return [[SweetOpaque alloc] init];
}

- (id)newComputePipelineStateWithFunction:(id)function options:(unsigned long)options
    reflection:(id *)reflection error:(id *)error
{
	sweet_log("msg", "newComputePipelineStateWithFunction:options:reflection:error:");
	return [[SweetOpaque alloc] init];
}

- (id)newRenderPipelineStateWithDescriptor:(id)descriptor
    options:(unsigned long)options reflection:(id *)reflection error:(id *)error
{
	sweet_log("msg", "newRenderPipelineStateWithDescriptor:options:reflection:error:");
	return sweet_pipeline_from_descriptor(descriptor);
}

- (id)newTextureWithDescriptor:(id)descriptor iosurface:(id)surface plane:(unsigned long)plane
{
	SweetTexture *texture = [[SweetTexture alloc] init];
	unsigned int identifier = sweet_iosurface_id(surface);
	((void (*)(id, SEL, unsigned int))objc_msgSend)(texture,
	    sel_registerName("setSurfaceID:"), identifier);
	if (descriptor != 0) {
		((void (*)(id, SEL, unsigned long, unsigned long))objc_msgSend)(texture,
		    sel_registerName("setSize:height:"),
		    sweet_msg_ul(descriptor, "width"), sweet_msg_ul(descriptor, "height"));
		((void (*)(id, SEL, unsigned long))objc_msgSend)(texture,
		    sel_registerName("setFormat:"), sweet_msg_ul(descriptor, "pixelFormat"));
	}
	if (sweet_fill_logs < 12) {
		dprintf(console_fd,
		    "SWEETMETAL: texture from iosurface id=%u plane=%lu\n",
		    identifier, plane);
	}
	return texture;
}

- (id)newBufferWithLength:(unsigned long)length options:(unsigned long)options
{
	sweet_log("msg", "newBufferWithLength:options:");
	dprintf(console_fd, "SWEETMETAL:   length=%lu options=%lu\n", length, options);
	return [[SweetBuffer alloc] initWithLength:length];
}

- (id)newBufferWithBytes:(const void *)bytes length:(unsigned long)length
    options:(unsigned long)options
{
	sweet_log("msg", "newBufferWithBytes:length:options:");
	dprintf(console_fd, "SWEETMETAL:   bytes=%p length=%lu options=%lu\n",
	    bytes, length, options);
	return [[SweetBuffer alloc] initWithBytes:bytes length:length];
}

- (id)newTextureWithDescriptor:(id)descriptor
{
	sweet_log("msg", "newTextureWithDescriptor");
	SweetTexture *texture = [[SweetTexture alloc] init];
	if (descriptor != 0) {
		((void (*)(id, SEL, unsigned long, unsigned long))objc_msgSend)(texture,
		    sel_registerName("setSize:height:"),
		    sweet_msg_ul(descriptor, "width"), sweet_msg_ul(descriptor, "height"));
		((void (*)(id, SEL, unsigned long))objc_msgSend)(texture,
		    sel_registerName("setFormat:"), sweet_msg_ul(descriptor, "pixelFormat"));
	}
	return texture;
}

- (id)newSamplerStateWithDescriptor:(id)descriptor
{
	sweet_log("msg", "newSamplerStateWithDescriptor");
	return [[SweetOpaque alloc] init];
}

- (id)newRenderPipelineStateWithDescriptor:(id)descriptor error:(id *)error
{
	sweet_log("msg", "newRenderPipelineStateWithDescriptor:error:");
	return sweet_pipeline_from_descriptor(descriptor);
}

- (id)newDepthStencilStateWithDescriptor:(id)descriptor
{
	sweet_log("msg", "newDepthStencilStateWithDescriptor");
	return [[SweetOpaque alloc] init];
}

- (id)newFence
{
	sweet_log("msg", "newFence");
	return [[SweetOpaque alloc] init];
}

- (id)newEvent
{
	sweet_log("msg", "newEvent");
	return [[SweetOpaque alloc] init];
}

- (id)newSharedEvent
{
	sweet_log("msg", "newSharedEvent");
	return [[SweetOpaque alloc] init];
}

- (id)newSharedEventWithHandle:(id)handle
{
	sweet_log("msg", "newSharedEventWithHandle");
	return [[SweetOpaque alloc] init];
}

- (void)setShouldMaximizeConcurrentCompilation:(BOOL)maximize
{
	sweet_log("msg", "setShouldMaximizeConcurrentCompilation");
}

- (BOOL)respondsToSelector:(SEL)sel
{
	sweet_log("respondsToSelector", sel_getName(sel));
	return [super respondsToSelector:sel];
}

/*
 * _MTLAddDevice asserts [newDevice conformsToProtocol:@protocol(MTLDevice)]
 * (then MTLDeviceSPI) before it registers the device. The probe declares no
 * headers, so answer by name instead of linking the protocol metadata.
 */
- (BOOL)conformsToProtocol:(id)proto
{
	const char *name = proto ? protocol_getName(proto) : "";
	sweet_log("conformsToProtocol", name);
	return strncmp(name, "MTL", 3) == 0;
}

/*
 * _MTLAddDevice calls these between the conformance checks and registration.
 * The inherited Metal versions read real device ivars and build an
 * NSInvocation from a method signature; on this probe object both blow up.
 */
- (void)initLimits
{
	sweet_log("initLimits", 0);
}

- (void)initFeatureQueries
{
	sweet_log("initFeatureQueries", 0);
}


- (id)featureProfile
{
	sweet_log("featureProfile", 0);
	return 0;
}

- (id)methodSignatureForSelector:(SEL)sel
{
	sweet_log("methodSignatureForSelector", sel_getName(sel));
	id signature = [super methodSignatureForSelector:sel];
	return signature ? signature : sweet_generic_signature();
}

- (void)forwardInvocation:(id)invocation
{
	SEL sel = ((SEL (*)(id, SEL))objc_msgSend)(invocation,
	    sel_registerName("selector"));
	sweet_log("call", sel_getName(sel));
	sweet_zero_return(invocation);
}

@end
