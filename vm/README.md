# QEMU support for the Android VM

The Android app needs a QEMU that can attach the raw HFS+ iOS root without
changing the kernel. The kernel's SWEET UFS driver talks to a Qualcomm UFSHCI
host through a single polled UTRL/UTRD slot. `qemu/sweet_ufs.c` implements
that surface over a flat image, and synthesizes a GPT with a `userdata`
partition at LBA 34. The kernel sees the same GPT it sees on the phone.

Two additional QEMU core changes are required:

- allow the `sweet-touch` and `sweet-ufs` sysbus devices on `virt`;
- give them no-op FDT bindings (the kernel uses the ADT, not QEMU's DTB).

`qemu/qemu-sweet.patch`, `qemu/sweet_ufs.c` and `qemu/sweet_touch.c` are the
source. `sweet_touch` models GCC, TLMM and GENI SE7 plus a synthetic Goodix
GT9896; its input is a 5-byte record (type, x LE16, y LE16), either over a
chardev or from a state file:

```sh
-chardev socket,id=sweet_touch,path=/tmp/touch.sock,server=on,wait=off
-device sweet-touch,chardev=sweet_touch
# or, without chardev flow control:
-device sweet-touch,touchfile=/tmp/touch.bin
```

`tools/qemu-sweet.py --touchfile FILE` writes the latter. A paused VM can be
saved and resumed with QEMU's file migration transport (no block device
needed): `migrate` to `file:/path/vmstate` over QMP, then start with
`-incoming file:/path/vmstate` (`tools/qemu-sweet.py --incoming FILE`). This
skips a 15-20 minute TCG boot and is what the Android app's quick start uses.

The kernel's `sweet_touch.c` requires the L11C RPMh vote to succeed; QEMU has
no RPMh block, so run `tools/patch-qemu-input.py` on the kernel (it replaces
`_sweet_rpmh_vreg_enable` with `return 0`). The touch probe then logs
`SWEET TOUCH: selected GT9896 Yellowstone`. The APK ships
no QEMU source; keep these files with the app if you redistribute the APK.

## Host build (for testing the kernel/root)

Ubuntu 24.04, QEMU 8.2.0:

```sh
sudo apt install build-essential ninja-build pkg-config python3-venv \
    libglib2.0-dev libpixman-1-dev device-tree-compiler
git clone --depth 1 -b v8.2.0 https://github.com/qemu/qemu.git
cp vm/qemu/sweet_ufs.c qemu/hw/block/
git -C qemu apply "$PWD/vm/qemu/qemu-sweet.patch"
mkdir qemu/build && cd qemu/build
../configure --target-list=aarch64-softmmu --disable-werror \
    --disable-docs --disable-guest-agent --disable-tools \
    --disable-gtk --disable-sdl --disable-vnc --disable-opengl \
    --disable-spice --disable-glusterfs --disable-libssh --disable-capstone \
    --disable-slirp --disable-kvm --disable-curl --disable-libiscsi \
    --disable-libnfs --disable-smartcard --disable-usb-redir --disable-u2f \
    --disable-seccomp --disable-xen --disable-brlapi --disable-curses \
    --disable-vte --disable-pipewire --disable-jack --disable-oss \
    --disable-alsa --enable-pie
ninja qemu-system-aarch64
```

Test the UFS device with the existing QEMU runner:

```sh
python3 tools/qemu-sweet.py payload-ios.bin out/ --secs 600 \
    --kernel xnu/out/kernel.development.sweet \
    --qemu qemu/build/qemu-system-aarch64 \
    --ufs ios16-root.img --shared-ram
```

`--shared-ram` creates `out/guest-ram.bin` as QEMU's guest RAM. The panel is
at guest physical `0x9c000000`, i.e. file offset `0x9c000000 - 0x40000000 =
0x5c000000`; the app reads `1080 * 2400 * 4` bytes from there. The app's
`VmEngine` uses the same layout.

## Android cross-build

The app ships two engines: `arm64-v8a` for phones and `x86_64` for emulators.
Both run the aarch64 guest. Use NDK r27 and a Termux aarch64/x86_64 sysroot.

Termux packages needed (the `glib` package contains the headers in the current
repo; the dev packages were merged into it):

```
glib libpixman pcre2 libffi libiconv libandroid-support zlib
```

Download the `binary-<arch>/Packages.gz` index from
`https://packages.termux.dev/apt/termux-main/dists/stable/`, fetch the
`Filename:` entries, and `dpkg-deb -x` them into a staging prefix. Create a
pkg-config wrapper with `PKG_CONFIG_SYSROOT_DIR` pointing at that prefix and
`PKG_CONFIG_LIBDIR` pointing at its `lib/pkgconfig`.

Then, for each ABI, create a cross wrapper directory whose `gcc`/`g++`
scripts exec the matching NDK `aarch64-linux-android24-clang` /
`x86_64-linux-android24-clang` with all arguments, and whose `ar`, `ld`, `nm`,
`strip`, `ranlib` and `objcopy` scripts exec the NDK LLVM tools. Configure:

```sh
PKG_CONFIG=$SYSROOT_PREFIX/pkg-config \
../configure --cross-prefix=$WRAPPERS/ --cpu=aarch64 \
    --target-list=aarch64-softmmu --host-cc=gcc \
    [the same --disable-* list as above] \
    --disable-vhost-user --disable-vhost-crypto --disable-vhost-vdpa \
    --disable-vhost-net --disable-vhost-kernel --disable-libvduse \
    --disable-virtfs --enable-pie
ninja qemu-system-aarch64
```

For the x86_64 engine, use `--cpu=x86_64` and x86_64 wrappers/sysroot; the
guest target stays `aarch64-softmmu`.

Stage the **original** QEMU binary and libraries, without `patchelf`:

```
android/app/src/main/assets/engine/<abi>/qemu-system-aarch64
android/app/src/main/assets/engine/<abi>/libglib-2.0.so.0
android/app/src/main/assets/engine/<abi>/libgio-2.0.so.0
android/app/src/main/assets/engine/<abi>/libgobject-2.0.so.0
android/app/src/main/assets/engine/<abi>/libgmodule-2.0.so.0
android/app/src/main/assets/engine/<abi>/libgthread-2.0.so.0
android/app/src/main/assets/engine/<abi>/libpixman-1.so
android/app/src/main/assets/engine/<abi>/libpcre2-8.so
android/app/src/main/assets/engine/<abi>/libffi.so
android/app/src/main/assets/engine/<abi>/libiconv.so
android/app/src/main/assets/engine/<abi>/libandroid-support.so
android/app/src/main/assets/engine/<abi>/libz.so.1
```

Running the **unmodified** binary and libraries is important. `patchelf`
renaming of SONAMEs/`NEEDED` entries was tried and made Android's linker
segfault inside `soinfo::prelink_image()`; the app's `EngineAssets` extracts
the original files and sets `LD_LIBRARY_PATH`, and the app targets API 28 so
`execve` from app data is allowed.

## Display and input

The app reads the shared RAM file; no QEMU display backend is involved.
`-display none -serial file:...` is intentional.

Touch/keys are not implemented. The kernel's `sweet_touch.c` expects GENI
I²C + Goodix GT9896 and an RPMh LDO vote; `sweet_keys.c` expects SPMI. The
next step would be a QEMU model of those blocks (or a kernel input channel),
not a change to the iOS root.

## License

QEMU is GPLv2. `sweet_ufs.c` and `qemu-sweet.patch` are provided under the
same terms. The kernel is Apple's open-source XNU under the APSL; the iOS
userland is not distributed here.
