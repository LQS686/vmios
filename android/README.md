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
- Touch works end to end on a real phone (Redmi K70 Pro, 2026-10-23): the
  guest reaches `SWEET TOUCH: selected GT9896 Yellowstone, 1080x2400, poll=10ms`
  and `SWEET HID: touch 0 down/up` arrive in pairs - a swipe in the VM walked
  iOS Setup from the Hello screen to the country picker. Two kernel-side
  defects had to be fixed first (the L11C rail vote aborted the probe, and a
  lift report was treated as "no new frame"); see `../docs/BOOT_FIXES.md` §11.
  Hardware keys are not modelled: `sweetkeys=1` panics under QEMU because the
  SPMI driver reads an unemulated PMIC.
- **MTTCG is reachable from the payload.** `VmEngine` reads `tcgmulti=1` from
  the command line and switches `-accel` from `tcg,thread=single` to
  `tcg,thread=multi`, so multi-vCPU runs need a payload change, not an APK
  rebuild. Verified to boot (`/proc/<pid>/cmdline` shows `thread=multi`, five
  threads) and to reach the present loop without the pset0 ticket-lock
  deadlock. It did not make the UI fast enough to use: rendering is still a
  1125x2436 software rasterizer on emulated CPU, see `../docs/BOOT_FIXES.md`
  §10 and §12.
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

## Building the APK on a Windows host (no Android Studio)

The build only needs a JDK and the SDK command line tools; both can live inside
the repository's ignored `.tools/` so nothing is installed system-wide.

```sh
# JDK 17 (AGP 8.7.3 needs 17+). Any mirror works; this one is fast in CN.
curl -L -o .tools/dl/jdk17.zip \
  https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/windows/OpenJDK17U-jdk_x64_windows_hotspot_17.0.20.1_1.zip
unzip -q .tools/dl/jdk17.zip -d .tools/dl/jdk && mv ".tools/dl/jdk/jdk-17.0.20.1+1" .tools/jdk

# SDK: platform 35 + build-tools 35.0.0
curl -L -o .tools/dl/cmdtools.zip \
  https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip
unzip -q .tools/dl/cmdtools.zip -d .tools/dl/cmdtools
mkdir -p .tools/android-sdk/cmdline-tools
cp -r .tools/dl/cmdtools/cmdline-tools .tools/android-sdk/cmdline-tools/latest
yes | .tools/android-sdk/cmdline-tools/latest/bin/sdkmanager.bat \
  --sdk_root="$PWD/.tools/android-sdk" --licenses
.tools/android-sdk/cmdline-tools/latest/bin/sdkmanager.bat \
  --sdk_root="$PWD/.tools/android-sdk" "platform-tools" "platforms;android-35" "build-tools;35.0.0"

# Gradle 8.9 (services.gradle.org is slow here; the mirrors are not)
curl -L -o .tools/dl/gradle.zip https://mirrors.huaweicloud.com/gradle/gradle-8.9-bin.zip
unzip -q .tools/dl/gradle.zip -d .tools/gradle

printf 'sdk.dir=%s\n' "$(cygpath -w "$PWD/.tools/android-sdk" | sed 's/\\/\\\\/g; s/:/\\:/')" \
  > android/local.properties

JAVA_HOME="$PWD/.tools/jdk" ANDROID_HOME="$PWD/.tools/android-sdk" \
  .tools/gradle/gradle-8.9/bin/gradle.bat -p android assembleDebug --no-daemon
# -> android/app/build/outputs/apk/debug/app-debug.apk
```

Two host-specific traps:

- **Non-ASCII build path.** AGP refuses a project under a CJK path (this repo
  lives under `桌面/`); `android.overridePathCheck=true` in
  `android/gradle.properties` lifts that check, and the build then works.
- **Signature mismatch on install.** `adb install -r` fails against an APK that
  was signed with a different debug key
  (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`). Uninstalling deletes the app's data,
  i.e. the 16 GiB root image, so plan for it: keep a patched copy of the image
  on the host (`tools/image-patch.py apply` works on the raw file) and push it
  back afterwards.
