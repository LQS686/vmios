# Third-party notices for the Android VM app

The app and the APK produced from this directory contain:

- **QEMU 8.2.0** (`qemu-system-aarch64`), GPLv2. The source used for the
  engine is upstream QEMU 8.2.0 plus `vm/qemu/sweet_ufs.c` and
  `vm/qemu/qemu-sweet.patch`. If you redistribute an APK with this binary,
  make the corresponding source available under GPLv2.
- **GLib**, **GIO**, **GObject**, **GModule**, **GThread**, **pixman**,
  **PCRE2**, **libffi**, **GNU libiconv**, **libandroid-support** and
  **zlib** builds from Termux. These are unmodified Termux packages; their
  licenses are in the packages (LGPL-2.1-or-later for GLib, MIT for pixman,
  BSD for PCRE2, MIT for libffi, LGPL for libiconv, zlib license for zlib).
- The **SWEET XNU kernel** binary in the demo payload, built from Apple's
  open-source xnu-8796 with the patches in `xnu/patches/`, under the Apple
  Public Source License 2.0 and the project's MIT additions. The demo payload
  intentionally has **no** Apple device-tree `/product` data.

The app does **not** include iOS, its shared cache, SpringBoard, the iPhone X
IPSW, or any other Apple userland. The user must supply the iOS root image.

This is an unofficial hobby project, not affiliated with or endorsed by
Apple, Qualcomm, Xiaomi or the Termux project.
