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
Method *class_copyMethodList(Class cls, unsigned int *outCount);
SEL method_getName(Method method);
const char *method_getTypeEncoding(Method method);
BOOL class_addMethod(Class cls, SEL name, IMP imp, const char *types);
BOOL sel_isEqual(SEL a, SEL b);
void _objc_msgForward(void);
int strcmp(const char *a, const char *b);
void free(void *ptr);
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
	return [[SweetOpaque alloc] init];
}

- (id)newRenderPipelineStateWithFunction:(id)function error:(id *)error
{
	sweet_log("library", "newRenderPipelineStateWithFunction:error:");
	return [[SweetOpaque alloc] init];
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

#define SWEET_OBJECT() [[SweetOpaque alloc] init]

@interface SweetCommandBuffer : SweetObject
- (void)commit;
- (void)enqueue;
- (void)presentDrawable:(id)drawable;
- (void)waitUntilCompleted;
- (id)renderCommandEncoderWithDescriptor:(id)descriptor;
- (id)blitCommandEncoder;
- (id)computeCommandEncoder;
@end

@implementation SweetCommandBuffer

- (void)commit
{
	sweet_log("buffer", "commit");
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
	return [[SweetCommandEncoder alloc] init];
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
	return [[SweetOpaque alloc] init];
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
	return [[SweetOpaque alloc] init];
}

- (id)newTextureWithDescriptor:(id)descriptor iosurface:(id)surface plane:(unsigned long)plane
{
	sweet_log("msg", "newTextureWithDescriptor:iosurface:plane:");
	return [[SweetOpaque alloc] init];
}

- (id)newBufferWithLength:(unsigned long)length options:(unsigned long)options
{
	sweet_log("msg", "newBufferWithLength:options:");
	dprintf(console_fd, "SWEETMETAL:   length=%lu options=%lu\n", length, options);
	return [[SweetOpaque alloc] init];
}

- (id)newBufferWithBytes:(const void *)bytes length:(unsigned long)length
    options:(unsigned long)options
{
	sweet_log("msg", "newBufferWithBytes:length:options:");
	dprintf(console_fd, "SWEETMETAL:   bytes=%p length=%lu options=%lu\n",
	    bytes, length, options);
	return [[SweetOpaque alloc] init];
}

- (id)newTextureWithDescriptor:(id)descriptor
{
	sweet_log("msg", "newTextureWithDescriptor");
	return [[SweetOpaque alloc] init];
}

- (id)newSamplerStateWithDescriptor:(id)descriptor
{
	sweet_log("msg", "newSamplerStateWithDescriptor");
	return [[SweetOpaque alloc] init];
}

- (id)newRenderPipelineStateWithDescriptor:(id)descriptor error:(id *)error
{
	sweet_log("msg", "newRenderPipelineStateWithDescriptor:error:");
	return [[SweetOpaque alloc] init];
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
