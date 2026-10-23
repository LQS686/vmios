# SweetVM — the Android VM front-end (experimental)

This directory is a separate, experimental way to run the same SWEET XNU
kernel: inside an Android app, under QEMU TCG, without touching the phone's
partitions. It is **not** the bare-metal port described in the top-level
README and it does not replace it.

## What is verified

- `x86_64` AVD, Android 15: the app starts the bundled **demo payload** and
  shows the guest framebuffer; the kernel reaches
  `*** SWEET userspace: init running as PID 1 ***` and keeps printing
  heartbeats. The VM screen, immersive mode, auto-hiding controls and the
  stop path were exercised.
- The app's iOS branch was tested with a 64 MB HFS+ test root and a UFS
  payload: the guest logs `SWEET UFS: "userdata" on LUN 0: first block 0x22,
  64 MiB`, mounts the volume and runs `/sbin/launchd` as PID 1.
- Touch works end to end in the app: a payload built with the QEMU input
  patches reaches `SWEET TOUCH: selected GT9896 Yellowstone`; the app's
  touches go through a Unix socket into `vm/qemu/sweet_touch.c`. Hardware
  keys are not modelled yet.
- Host QEMU (2 vCPU, MTTCG) with the bring-up image patches now reaches the
  real iOS lock screen and, after skipping Setup, the SpringBoard home
  screen; unlock swipes and Setup taps go through the GENI+GT9896 model.
  This needs the multiuser kernel stub, a synthetic MobileGestalt cache plus
  the MG IOKit-getter patch, and removal of the QEMU-only SpringBoard lock
  prefs (see `../NOTES.md`). System-app placeholders can show "Waiting..."
  until MobileInstallation/SystemAppMigrator finishes. This is verified on
  host QEMU, not yet on an Android device.
- The Android app's iOS branch still has to be rerun with that patched
  image/payload. Earlier app runs confirmed UFS mount, touch and backboardd
  surfaces, but not a usable home screen; hardware keys are not modelled.

## How it works

```
MainActivity (Java)
  ├─ Payload.java       parses SWEETXNU, writes ram.bin/stub.bin, boot_args
  ├─ EngineAssets.java  extracts the QEMU build + original Termux libs
  ├─ VmEngine.java      launches QEMU once, shares guest RAM, reads the panel
  └─ FramebufferView    double-buffered 1080x2400 bitmap, letterboxed

QEMU (aarch64-softmmu, TCG, virt)
  ├─ loader devices at 0xb0000000 / 0x40200000
  ├─ sweet-ufs          vm/qemu/sweet_ufs.c: UTRL/UTRD + GPT + HFS+ file
  └─ memory-backend-file/share=on  →  guest-ram.bin  →  app reads it
```

The app never reads the root filesystem itself. QEMU opens the raw HFS+
image read/write; the custom UFS device presents it as GPT partition
`userdata`; the unmodified SWEET UFS driver in the kernel does the rest.

## Build

Requirements: JDK 17, Android SDK 35, Android NDK 27, Gradle 8.9 (the wrapper
is included), and a Linux host with the QEMU build dependencies.

1. **Engine assets** — put the QEMU binary and the original Termux libraries
   under `app/src/main/assets/engine/arm64-v8a/` and `.../x86_64/`. The exact
   build and packaging commands are in [`../vm/README.md`](../vm/README.md).
   Keep the original file names (`qemu-system-aarch64`, `libglib-2.0.so.0`,
   `libz.so.1`, …). Do **not** run `patchelf` on these libraries: renaming
   their SONAMEs makes Android's linker crash in `prelink_image()`.
2. **Demo payload** — an open-source test payload with no Apple device-tree
   data:
   ```sh
   python3 tools/mkadt.py /tmp/q-demo.adt --qemu --no-product
   python3 tools/mkpayload.py xnu/out/kernel.development.sweet /tmp/q-demo.adt \
       app/src/main/assets/demo/payload.bin --ramdisk /tmp/sweet-init \
       --cmdline 'debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=md0 sweetkeys=0 sweettouch=0 sweetusb=0'
   ```
3. **APK**:
   ```sh
   ./gradlew assembleDebug
   adb install -r app/build/outputs/apk/debug/app-debug.apk
   ```

The app targets **API 28** on purpose. Android 10+ blocks executing binaries
from writable app data for `targetSdk >= 29`; the native-library directory
also only accepts `*.so` names, while Termux's libraries have versioned
SONAMEs. API 28 keeps the classic extract-and-exec path working without
rewriting ELF files. This is an experimental sideload app, not a Play Store
submission.

## Running iOS, not just the demo

You need two user-supplied files:

- a 16 GB raw HFS+ root built from your own IPSW (`tools/mkiosroot.sh`, or
  the WSL/guestfish recipe in [`../docs/IOS_ROOT_WSL.md`](../docs/IOS_ROOT_WSL.md));
- a SWEETXNU payload built with `tools/mkadt.py --qemu` and
  `tools/mkpayload.py`. The ADT must be the QEMU variant, and the payload's
  `phys_base` must be `0xb0000000` (do not use `--highmem`). Include
  `rd=ufsroot0 ufsrw=1 rootrw=1` in the command line. For touch, run
  `tools/patch-qemu-psci.py` (only needed for SMP) and
  `tools/patch-qemu-input.py` on the kernel before `mkpayload.py`, and add
  `sweettouch=1 sweettouchdelay=3`; add `sweetfb_noconsole=1` for the GUI.

Import both in the app, or copy them to
`/sdcard/Android/data/dev.hackios.sweetvm/files/` and press refresh. The app
copies imports from the system picker into that directory; the root image is
large, so make sure the device has free space.

## Limitations

- **Touch works; hardware keys do not.** Touch requires a payload built with
  `tools/patch-qemu-input.py` (the RPMh LDO vote is stubbed) and the QEMU
  `sweet-touch` device. The PMIC/SPMI power and volume keys are not modelled.
- **Display wake/power is unfinished.** iOS renders to surfaces, but the
  guest then requests display off and the QEMU panel copy fades it out. The
  next work is the IOMFB power/wake path (auto-lock, power key) before the
  home screen is usable.
- Single vCPU, 3 GB guest RAM, TCG. No GPU, no network, no audio, no camera,
  no sensors. iOS itself has no GPU driver in this project.
- iOS 16 on TCG can take a very long time to boot and may not render past the
  SpringBoard boot logo on every host. The app's demo payload is the quick
  way to verify the engine.
- `sweetfb_noconsole=1` is recommended for iOS; without it the kernel console
  covers the GUI.
- The app does not ship Apple's iOS files, the D22AP `/product` device-tree
  node, or a ready-made root image.

## Third-party code

QEMU is GPLv2; the engine assets contain a QEMU build. The source is upstream
QEMU 8.2.0 plus the patch and driver in [`../vm/qemu/`](../vm/qemu/). Termux's
GLib/pixman and dependency builds are used unchanged. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
