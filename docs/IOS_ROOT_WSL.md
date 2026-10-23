# Building the iOS root on WSL without hfsplus in the kernel

`tools/mkiosroot.sh` is the supported path: it needs a Linux host whose
kernel can mount HFS+ (`modprobe hfsplus`). WSL2 kernels usually lack that
module. This recipe produces the same 16 GB raw HFS+ image using
`apfs-fuse` for the IPSW volumes and `libguestfs` for the HFS+ writes.

It is a bring-up recipe, not a redistribution tool: the IPSW and the resulting
root contain Apple's userland and belong on your own machine, never in git.

## 0. Inputs

- iPhone X (iPhone10,3) iOS 16.7.16 (20H392) IPSW. The URL is available from
  `https://api.ipsw.me/v4/device/iPhone10,3?type=ipsw`; the project's
  `tools/remotezip.py` can fetch single members without downloading all 6 GB.
- Ubuntu 24.04 (WSL2 is fine) with root.
- `apfs-fuse` built from source (`sgan81/apfs-fuse`): Ubuntu does not package
  it. `libfuse3-dev`, `libbz2-dev`, `zlib1g-dev`, `cmake`, `g++` are enough.
- `hfsprogs`, `libguestfs-tools`, `rsync`, `python3`, `clang`/`llvm`.

The three DMGs are named by build ID; `BuildManifest.plist` maps them:

| Manifest key | Example file |
| --- | --- |
| `OS` | `087-86698-044.dmg` (≈4.7 GB) |
| `Cryptex1,SystemOS` | `087-86593-047.dmg` (≈2.7 GB) |
| `Cryptex1,AppOS` | `087-86715-047.dmg` |

`unzip IPSW.ipsw <the three names> -d images/`.

## 1. Mount the APFS volumes

```sh
mkdir -p /mnt/apfs-os /mnt/apfs-sys /mnt/apfs-app
/opt/apfs-fuse/build/apfs-fuse -o allow_other images/<OS>.dmg /mnt/apfs-os
/opt/apfs-fuse/build/apfs-fuse -o allow_other images/<SystemOS>.dmg /mnt/apfs-sys
/opt/apfs-fuse/build/apfs-fuse -o allow_other images/<AppOS>.dmg /mnt/apfs-app
```

Each mount exposes the volume as `root/`. Run `stat` on
`/mnt/apfs-os/root/sbin/launchd`: it should be root-owned, mode 755.

## 2. Copy the three volumes into one staging tree

```sh
S=/opt/ios-sweet/staging
rm -rf "$S"; mkdir -p "$S"
rsync -aH --numeric-ids /mnt/apfs-os/root/  "$S/"
mkdir -p "$S/private/preboot/Cryptexes/OS" "$S/private/preboot/Cryptexes/App"
rsync -aH --numeric-ids /mnt/apfs-sys/root/ "$S/private/preboot/Cryptexes/OS/"
rsync -aH --numeric-ids /mnt/apfs-app/root/ "$S/private/preboot/Cryptexes/App/"
```

Then apply the same links as `mkiosroot.sh`:

- hard-link the SystemOS dyld shared cache into
  `$S/System/Library/Caches/com.apple.dyld`;
- hard-link every cryptex file that has no counterpart in the OS root (copy
  symlinks instead of linking them);
- create `$S/private/var/db/{diagnostics,uuidtext}` owned by `_logd` (272)
  with `.migrated` markers;
- install `$S/private/var/keybags/systembag.kb` (mode 0600, root).

The compact version used during bring-up:

```python
import os
root = "/opt/ios-sweet/staging"
base = os.path.join(root, "private/preboot/Cryptexes")
for c in ("OS", "App"):
    src_root = os.path.join(base, c)
    for dirpath, dirnames, filenames in os.walk(src_root):
        rel = os.path.relpath(dirpath, src_root)
        if rel.startswith("System/Library/Caches/com.apple.dyld"):
            continue
        for name in filenames + [d for d in dirnames
                                 if os.path.islink(os.path.join(dirpath, d))]:
            src = os.path.join(dirpath, name)
            dst = os.path.join(root, os.path.relpath(src, src_root))
            if os.path.lexists(dst):
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if os.path.islink(src):
                os.symlink(os.readlink(src), dst)
            else:
                os.link(src, dst)
        dirnames[:] = [d for d in dirnames
                       if not os.path.islink(os.path.join(dirpath, d))]
```

Run the project's bring-up changes as root:

```sh
sudo python3 tools/sweet-root-tweaks.py "$S"
```

## 3. Create the HFS+ image

`guestfish` mounts HFS+ read-write only after the image is clean; repair it
first if it was touched by a VM.

```sh
truncate -s 16G ios16-root.img
mkfs.hfsplus -s -J -v iOSRoot ios16-root.img
tar --numeric-owner --sparse -C "$S" -cf root.tar .
printf 'run\nmount-options force /dev/sda /\ntar-in /opt/ios-sweet/root.tar /\nstatvfs /\n' \
    | guestfish -a ios16-root.img
fsck.hfsplus -f -y ios16-root.img
fsck.hfsplus -f -n ios16-root.img
```

`tar-in` preserves numeric owners, modes, symlinks and hard links. The staging
tree is ~12 GB; a 16 GB volume leaves several hundred MB free after the
cryptexes and the log/keybag additions.

## 4. First boot and activation

Boot the root with the QEMU payload. On the first boot `mobileactivationd`
creates its MCM container; the data ark may be created **without**
`-ActivationState`, which can leave SpringBoard at the boot logo. Stop the VM,
run `fsck`, then find the container whose metadata identifier is
`com.apple.mobileactivationd` and add the activated state:

```python
import plistlib, glob, os
for meta in glob.glob("/mnt/root/private/var/containers/Data/System/*/"
                      ".com.apple.mobile_container_manager.metadata.plist"):
    md = plistlib.load(open(meta, "rb"))
    if md.get("MCMMetadataIdentifier") != "com.apple.mobileactivationd":
        continue
    ark = os.path.join(os.path.dirname(meta),
                       "Library/internal/data_ark.plist")
    d = plistlib.load(open(ark, "rb"))
    d.update({"-ActivationState": "Activated", "-BrickState": False,
              "-DataMigrationCompleted": True,
              "-PreSydroDataMigrationCompleted": True,
              "-BuildVersion": "20H392", "-ProductVersion": "16.7.16"})
    plistlib.dump(d, open(ark, "wb"), fmt=plistlib.FMT_BINARY)
    print(ark)
```

Upload it with `guestfish upload` and keep the container's original owner
(`501:501`) and mode (`0600`). Do this only on a copy of your own root.

## 5. Payload and boot

The payload's ADT must be the QEMU variant:

```sh
python3 tools/mkadt.py /tmp/q-ios.adt --qemu
python3 tools/mkpayload.py xnu/out/kernel.development.sweet /tmp/q-ios.adt \
    payload-ios.bin --cmdline \
    'debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress \
rd=ufsroot0 ufsrw=1 rootrw=1 unentitled_ios_sim_launch=1 ignition_level=1 \
wdt_test=no_user_checkin launchd_unsecure_cache=1 wdt=-1 sweetfb_hz=30 \
sweetfb_noconsole=1 sweetkeys=0 sweettouch=0 sweetusb=0'
```

`mkadt.py --qemu` includes the `/product` node only if
`research/ipsw-x/d22ap.adt` exists; extract it from the IPSW as described in
the top-level README. Without it MobileGestalt reports an iPod and iOS 16 may
not present the expected iPhone X UI.

Boot with `tools/qemu-sweet.py ... --ufs ios16-root.img --shared-ram`. The
guest RAM file's `0x5c000000` offset is the 1080×2400 panel. Expect a long
single-core TCG boot. The demo payload is the fast way to prove the engine;
the iOS root reaches SpringBoard/backboardd processes but the GUI is not
guaranteed to render past the boot logo on every host.
