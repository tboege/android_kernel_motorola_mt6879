#!/usr/bin/env bash
# Pack arch/arm64/boot/Image into a flashable boot.img using magiskboot.
# Keeps the reference image's ramdisk / header; replaces only the kernel.
#
# Usage:
#   REF_BOOT=/path/to/lineage-boot.img \
#   MAGISKBOOT=/path/to/magiskboot \
#   OUT_DIR=/path/to/out \
#   ./pack-boot.sh
#
# Optional: KERNEL_IMAGE=/path/to/Image  (default: arch/arm64/boot/Image
# relative to this script's repo root)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REF_BOOT="${REF_BOOT:?Set REF_BOOT to a LineageOS (or stock) boot.img for this device}"
MAGISKBOOT="${MAGISKBOOT:?Set MAGISKBOOT to the magiskboot binary}"
OUT_DIR="${OUT_DIR:-$ROOT/out-boot}"
KERNEL_IMAGE="${KERNEL_IMAGE:-$ROOT/arch/arm64/boot/Image}"
WORKDIR="${WORKDIR:-$OUT_DIR/pack-work}"

if [[ ! -x "$MAGISKBOOT" ]]; then
  echo "MAGISKBOOT is not executable: $MAGISKBOOT" >&2
  exit 1
fi
if [[ ! -f "$REF_BOOT" ]]; then
  echo "REF_BOOT not found: $REF_BOOT" >&2
  exit 1
fi
if [[ ! -f "$KERNEL_IMAGE" ]]; then
  echo "KERNEL_IMAGE not found: $KERNEL_IMAGE (build Image first)" >&2
  exit 1
fi

mkdir -p "$OUT_DIR" "$WORKDIR"
rm -rf "$WORKDIR/unpack"
mkdir -p "$WORKDIR/unpack"
cd "$WORKDIR/unpack"

echo "=== unpack $REF_BOOT ==="
"$MAGISKBOOT" unpack -h "$REF_BOOT"
echo "=== replace kernel ==="
cp -a "$KERNEL_IMAGE" kernel
# Keep ROM DTB if present. This tree's Makefile does not build mt6879.dtb.
if [[ -f dtb ]]; then
  echo "dtb present — leaving ROM DTB unchanged"
fi

OUT_IMG="$OUT_DIR/boot-droidspaces.img"
echo "=== repack → $OUT_IMG ==="
"$MAGISKBOOT" repack "$REF_BOOT" "$OUT_IMG"
cp -a "$REF_BOOT" "$OUT_DIR/boot-ref.img"

echo "=== verify ==="
rm -rf "$WORKDIR/verify"
mkdir -p "$WORKDIR/verify"
cd "$WORKDIR/verify"
"$MAGISKBOOT" unpack "$OUT_IMG" >/dev/null
python3 - <<PY
from pathlib import Path
src = Path("$KERNEL_IMAGE").read_bytes()
got = Path("kernel").read_bytes()
assert src == got, "repacked kernel payload does not match Image"
assert b"-for_droidspaces" in got or b"Linux version" in got
print("kernel_match=True bytes=%d" % len(got))
PY

(
  cd "$OUT_DIR"
  sha256sum boot-droidspaces.img boot-ref.img > SHA256SUMS
)
ls -lh "$OUT_IMG" "$OUT_DIR/boot-ref.img"
echo "Done. Flash only boot:"
echo "  fastboot flash boot $OUT_IMG"
echo "Rollback:"
echo "  fastboot flash boot $OUT_DIR/boot-ref.img"
