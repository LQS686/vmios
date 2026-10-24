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
Class class_getSuperclass(Class cls);
const char *class_getName(Class cls);
const char *object_getClassName(id obj);
Method *class_copyMethodList(Class cls, unsigned int *outCount);
SEL method_getName(Method method);
const char *method_getTypeEncoding(Method method);
BOOL class_addMethod(Class cls, SEL name, IMP imp, const char *types);
BOOL sel_isEqual(SEL a, SEL b);
void _objc_msgForward(void);
int strcmp(const char *a, const char *b);
void free(void *ptr);
void *malloc(unsigned long size);
void *memcpy(void *dst, const void *src, unsigned long n);
void bzero(void *dst, unsigned long n);
SEL sel_registerName(const char *name);
const char *sel_getName(SEL sel);
const char *protocol_getName(id protocol);
id objc_msgSend(id self, SEL op, ...);
int open(const char *path, int flags, ...);
int dprintf(int fd, const char *format, ...);
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
}
- (void)setSweetName:(id)name;
- (id)name;
@end

@implementation SweetFunction

- (void)setSweetName:(id)name
{
	fn_name = ((id (*)(id, SEL))objc_msgSend)(name,
	    sel_registerName("retain"));
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
	dprintf(console_fd, "SWEETMETAL: library newFunctionWithDescriptor %s\n",
	    sweet_cstr(name));
	SweetFunction *function = [[SweetFunction alloc] init];
	((void (*)(id, SEL, id))objc_msgSend)(function,
	    sel_registerName("setSweetName:"), name);
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
}
- (void)setNameC:(const char *)name;
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

/* Texture backed by an IOSurface; keeps the id for the clear forwarder. */
@interface SweetTexture : SweetOpaque {
	unsigned int tex_surface;
	unsigned long tex_width;
	unsigned long tex_height;
	unsigned long tex_format;
}
- (void)setSurfaceID:(unsigned int)identifier;
- (unsigned int)surfaceID;
- (void)setSize:(unsigned long)width height:(unsigned long)height;
- (void)setFormat:(unsigned long)format;
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

@end

#define SWEET_OBJECT() [[SweetOpaque alloc] init]

static unsigned int sweet_encoder_logs;
static unsigned int sweet_draw_logs;

/* Render encoder: records the destination surface and the draw inputs so the
 * kernel/host can later replay CA's compositor draws with real content. */
@interface SweetRenderEncoder : SweetObject {
	unsigned int enc_surface;
	id enc_pipeline;
	id enc_vb[8];
	unsigned long enc_vboff[8];
	id enc_vtex[8];
	id enc_tex[8];
	id enc_ib;
	unsigned long enc_iboff;
}
- (id)initWithSurface:(unsigned int)surface;
- (void)setRenderPipelineState:(id)pipeline;
- (void)setVertexBuffer:(id)buffer offset:(unsigned long)offset
    atIndex:(unsigned long)index;
- (void)setFragmentTexture:(id)texture atIndex:(unsigned long)index;
- (void)setVertexTexture:(id)texture atIndex:(unsigned long)index;
- (void)drawIndexedPrimitives:(unsigned long)type indexCount:(unsigned long)count
    indexType:(unsigned long)index_type indexBuffer:(id)index_buffer
    indexBufferOffset:(unsigned long)index_offset
    instanceCount:(unsigned long)instances;
- (void)drawPrimitives:(unsigned long)type vertexStart:(unsigned long)start
    vertexCount:(unsigned long)count;
- (void)endEncoding;
@end

@implementation SweetRenderEncoder

- (id)initWithSurface:(unsigned int)surface
{
	enc_surface = surface;
	return self;
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

- (void)setFragmentTexture:(id)texture atIndex:(unsigned long)index
{
	if (index < 8) {
		enc_tex[index] = texture;
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
	if (sweet_draw_logs < 12 || (sweet_draw_logs % 60) == 0) {
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
				sweet_hex32("vbytes", i,
				    (const char *)contents + (enc_vboff[i] < length ? enc_vboff[i] : 0));
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
		if (index_buffer != 0) {
			void *contents = (void *)((void *(*)(id, SEL))objc_msgSend)(
			    index_buffer, sel_registerName("contents"));
			unsigned long length = ((unsigned long (*)(id, SEL))objc_msgSend)(
			    index_buffer, sel_registerName("length"));
			dprintf(console_fd, "SWEETMETAL:   ib=%p+%lu len=%lu\n",
			    contents, index_offset, length);
			sweet_hex32("ibytes", 0,
			    (const char *)contents + (index_offset < length ? index_offset : 0));
		}
		sweet_draw_logs++;
	}
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
}

- (void)endEncoding
{
	sweet_log("encoder", "endEncoding");
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
	[self flushFills];
}

- (void)commitAndWaitUntilSubmitted
{
	sweet_log("buffer", "commitAndWaitUntilSubmitted");
	[self flushFills];
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
	if (descriptor != 0) {
		id attachments = sweet_msg_id(descriptor, "colorAttachments");
		id attachment = attachments != 0 ?
		    sweet_msg_id_idx(attachments, "objectAtIndexedSubscript:", 0) : 0;
		if (attachment == 0 && attachments != 0) {
			attachment = sweet_msg_id_idx(attachments, "objectAtIndex:", 0);
		}
		id texture = attachment != 0 ? sweet_msg_id(attachment, "texture") : 0;
		unsigned long action = attachment != 0 ?
		    sweet_msg_ul(attachment, "loadAction") : 0;
		if (texture != 0 &&
		    ((BOOL (*)(id, SEL, Class))objc_msgSend)(texture,
		    sel_registerName("isKindOfClass:"), objc_getClass("SweetTexture"))) {
			surface = ((unsigned int (*)(id, SEL))objc_msgSend)(texture,
			    sel_registerName("surfaceID"));
			double red = 0, green = 0, blue = 0, alpha = 0;
			if (action == 2) {
				typedef struct { double red, green, blue, alpha; } ClearColor;
				ClearColor color = ((ClearColor (*)(id, SEL))objc_msgSend)(
				    attachment, sel_registerName("clearColor"));
				red = color.red; green = color.green;
				blue = color.blue; alpha = color.alpha;
				if (pending_count < 8) {
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
	return [[SweetRenderEncoder alloc] initWithSurface:surface];
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

@interface SweetCommandQueue : SweetObject
- (id)device;
- (id)commandBuffer;
- (id)commandBufferWithUnretainedReferences;
- (id)commandBufferWithDescriptor:(id)descriptor;
@end

@implementation SweetCommandQueue

- (id)device
{
	sweet_log("queue", "device");
	return sweet_device_self;
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

- (unsigned long)maxTextureDimension2D
{
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
	return [[SweetCommandQueue alloc] init];
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
