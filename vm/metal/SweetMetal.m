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

Class objc_getClass(const char *name);
SEL sel_registerName(const char *name);
const char *sel_getName(SEL sel);
id objc_msgSend(id self, SEL op, ...);
int open(const char *path, int flags, ...);
int dprintf(int fd, const char *format, ...);

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

__attribute__((constructor))
static void
sweet_loaded(void)
{
	sweet_log("bundle loaded", 0);
}

@implementation SweetMetalDevice

- (id)initWithAcceleratorPort:(io_object_t)port
{
	sweet_log("initWithAcceleratorPort port=", 0);
	if (console_fd >= 0) {
		dprintf(console_fd, "SWEETMETAL: port=%u self=%p\n", port, self);
	}
	return self;
}

- (id)name
{
	return ((id (*)(id, SEL, const char *))objc_msgSend)(
		(id)objc_getClass("NSString"),
		sel_registerName("stringWithUTF8String:"), "SweetMetal");
}

- (BOOL)respondsToSelector:(SEL)sel
{
	sweet_log("respondsToSelector", sel_getName(sel));
	return [super respondsToSelector:sel];
}

- (id)methodSignatureForSelector:(SEL)sel
{
	sweet_log("methodSignatureForSelector", sel_getName(sel));
	id signature = [super methodSignatureForSelector:sel];
	if (signature == 0) {
		/* Unknown selectors must still reach forwardInvocation: for the log. */
		signature = ((id (*)(id, SEL, const char *))objc_msgSend)(
			(id)objc_getClass("NSMethodSignature"),
			sel_registerName("signatureWithObjCTypes:"), "@:");
	}
	return signature;
}

- (void)forwardInvocation:(id)invocation
{
	SEL sel = ((SEL (*)(id, SEL))objc_msgSend)(invocation,
	    sel_registerName("selector"));
	sweet_log("call", sel_getName(sel));
}

@end
