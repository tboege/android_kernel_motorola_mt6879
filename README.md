# Motorola Edge 40 Neo (manaus) — DroidSpaces kernel

Fork of [LineageOS/android_kernel_motorola_mt6879](https://github.com/LineageOS/android_kernel_motorola_mt6879)
(`lineage-23.2`) with DroidSpaces GKI options, kABI-safe IPC patches, and
`CONFIG_LOCALVERSION="-for_droidspaces"` so `uname -r` is easy to spot.

This README is enough to **clone → build `Image` → pack `boot-droidspaces.img`**
on WSL2 / Ubuntu with ≈15 GiB RAM. Upstream Android Common Kernel patch notes:
[`README.ACK.md`](README.ACK.md).

## Quick start

```sh
# 1) Workspace (any path — examples use $HOME/android)
export ANDROID_ROOT="${ANDROID_ROOT:-$HOME/android}"
mkdir -p "$ANDROID_ROOT" && cd "$ANDROID_ROOT"

git clone -b droidspaces \
  https://github.com/tboege/android_kernel_motorola_mt6879.git \
  kernel_manaus
cd kernel_manaus

# 2) Toolchain: Android clang-r416183b (LLVM 12), not a newer host clang
#    Place it at: $ANDROID_ROOT/toolchains/clang/clang-r416183b/
#    Optional: $ANDROID_ROOT/out/host-tools/usr/bin/python → python3

export PATH="$ANDROID_ROOT/out/host-tools/usr/bin:$ANDROID_ROOT/toolchains/clang/clang-r416183b/bin:$PATH"
export ARCH=arm64 LLVM=1 LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu-

# 3) Config (merge matches build.config.manaus) + force ThinLTO
make mrproper
KCONFIG_CONFIG=arch/arm64/configs/manaus_defconfig \
  scripts/kconfig/merge_config.sh -m -r \
  arch/arm64/configs/gki_defconfig \
  arch/arm64/configs/vendor/mt6879.config \
  arch/arm64/configs/vendor/manaus.config
make LLVM=1 LLVM_IAS=1 LTO=thin manaus_defconfig
make LLVM=1 LLVM_IAS=1 olddefconfig
./scripts/config --disable LTO_CLANG_FULL --enable LTO_CLANG_THIN
make olddefconfig LLVM=1 LLVM_IAS=1 \
  CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- \
  CC="ccache clang" HOSTCC="ccache clang"
# Expect in .config: CONFIG_LTO_CLANG_THIN=y and CONFIG_USER_NS=y

# 4) Build Image (ThinLTO jobs capped for ≤15 GiB WSL)
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
export CCACHE_CPP2=yes CCACHE_COMPRESS=true CCACHE_BASEDIR="$PWD"
make -j"$(nproc)" \
  LLVM=1 LLVM_IAS=1 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  CC="ccache clang" HOSTCC="ccache clang" \
  KBUILD_LDFLAGS="--thinlto-jobs=2 --threads=2" \
  Image Image.gz

# 5) Pack boot.img (needs a reference Lineage boot.img + magiskboot)
REF_BOOT=/path/to/lineage-boot.img \
MAGISKBOOT=/path/to/magiskboot \
OUT_DIR="$ANDROID_ROOT/out/droidspaces-manaus" \
  ./pack-boot.sh
```

Flash **only** `boot` (keep `vendor_boot` / `dtbo` from the ROM):

```sh
fastboot flash boot "$ANDROID_ROOT/out/droidspaces-manaus/boot-droidspaces.img"
fastboot reboot
# Rollback: fastboot flash boot .../boot-ref.img
```

After boot, `adb shell uname -r` should contain `-for_droidspaces`.

---

## What this branch already contains

You do **not** need to re-apply these if you cloned `droidspaces`:

| Change | Purpose |
| --- | --- |
| `include/linux/sched.h`, `include/linux/sched/user.h` | DroidSpaces kABI padding for `SYSVIPC` / `POSIX_MQUEUE` |
| `arch/arm64/configs/gki_defconfig` | DroidSpaces GKI symbols + `LOCALVERSION=-for_droidspaces` |
| `pack-boot.sh` | magiskboot pack helper |
| This `README.md` | build + pack instructions |

Patch sources (already applied):
https://github.com/ravindu644/Droidspaces-OSS/tree/main/Documentation/resources/kernel-patches/GKI/below-kernel-6.12
(`001…_6_7_8` + `002…posix_mqueue` on this tree).

**Do not** enable `CONFIG_CFS_BANDWIDTH` or `CONFIG_CGROUP_PIDS` — they change
structure sizes and vendor modules refuse to load.

`manaus_defconfig` is a **generated** merge of `gki_defconfig` +
`vendor/mt6879.config` + `vendor/manaus.config`. `build.config.manaus` deletes
it after use. Do not commit it; recreate with the merge steps above.

---

## Toolchain and layout

```text
$ANDROID_ROOT/
  kernel_manaus/                      # this repo
  toolchains/clang/clang-r416183b/    # required
  out/host-tools/usr/bin/             # optional (python → python3)
  out/droidspaces-manaus/             # pack output (created by pack-boot.sh)
```

Device / Lineage expect **clang-r416183b**. Newer Android clangs (e.g. r547379
used on other devices) are the wrong tool for this tree.

On some Ubuntu hosts, kernel scripts call `python` but only `python3` exists.
A symlink in `out/host-tools/usr/bin/python` → `/usr/bin/python3` is enough.

---

## Why ThinLTO and `KBUILD_LDFLAGS`

`gki_defconfig` still lists `CONFIG_LTO_CLANG_FULL=y`. Full LTO OOMs on ≈15 GiB
WSL (`ld.lld` killed / exit 137 during `LTO vmlinux.o`). Always force ThinLTO
in `.config` after merge (see Quick start).

`scripts/link-vmlinux.sh` uses **`KBUILD_LDFLAGS`** for the relocatable LTO
link — not `LDFLAGS_vmlinux`. Cap jobs with:

```text
KBUILD_LDFLAGS="--thinlto-jobs=2 --threads=2"
```

Exporting `LTO=thin` on the make command line alone does **not** flip an
existing Full-LTO `.config`.

---

## Packing `boot.img` (`pack-boot.sh`)

Manaus Lineage boot images are **header v4**, page 4096, gzip kernel,
lz4_legacy ramdisk. The reference image used when developing this branch had
**no separate `dtb` slot** — the script leaves any ROM `dtb` untouched. Do not
flash a custom `dtbo` from this tree.

### magiskboot

Extract from a Magisk APK (e.g. v30.7):

```sh
# lib/x86_64/libmagiskboot.so → rename/copy to an executable named magiskboot
unzip -j Magisk-*.apk lib/x86_64/libmagiskboot.so -d /tmp
mv /tmp/libmagiskboot.so /path/to/magiskboot && chmod +x /path/to/magiskboot
```

### Reference boot

Use the **same LineageOS nightly** you run on the phone (same 5.10 sublevel as
vendor modules). Example name: the ROM’s `boot.img`.

```sh
REF_BOOT=/path/to/lineage-boot.img \
MAGISKBOOT=/path/to/magiskboot \
OUT_DIR="${ANDROID_ROOT:-$HOME/android}/out/droidspaces-manaus" \
  ./pack-boot.sh
```

Outputs:

| File | Use |
| --- | --- |
| `boot-droidspaces.img` | Flash to `boot` |
| `boot-ref.img` | Rollback copy of the reference |
| `SHA256SUMS` | Checksums |

Magisk: flash of `boot-droidspaces.img` removes root. After a clean boot, patch
**that** image in the Magisk app (Install → Select and Patch a File), then flash
the patched result. Do not Magisk-patch raw `Image.gz`.

---

## DTB note

`build.config.manaus` mentions `mediatek/mt6879.dtb`, but
`arch/arm64/boot/dts/mediatek/Makefile` only builds generic EVB dtbs. A plain
`make dtbs` will not produce a Manaus board DTB. For first flash, keep the
ROM’s DTB via magiskboot (as `pack-boot.sh` does). Do not block Image builds on
`mt6879.dtb`.

---

## Flash / recovery

```sh
adb reboot bootloader
fastboot flash boot /path/to/boot-droidspaces.img
fastboot reboot
```

If it does not boot:

```sh
fastboot flash boot /path/to/boot-ref.img
fastboot reboot
```

Do **not** flash `vendor_boot` with anything from this package (recovery lives
there on this device). Do **not** turn off `CONFIG_MODVERSIONS` to force
modules — if wifi/touch die, ABI broke; roll back to `boot-ref.img`.

---

## Checklist

1. Branch `droidspaces` cloned; clang-r416183b on `PATH`.
2. Merge config + ThinLTO verified in `.config`.
3. `Image` / `Image.gz` built with `--thinlto-jobs=2`.
4. `pack-boot.sh` with matching ROM `boot.img` + magiskboot.
5. `uname -r` contains `-for_droidspaces` after flash.
