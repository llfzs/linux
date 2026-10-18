#!/usr/bin/env bash
# build-partition-image.sh — piano partition-rescue image builder
#
# Composes on top of the llfzs/linux build skeleton:
#   - kernel: code002-2/linux @ piano-7.2.6, config piano_rootfs (unchanged;
#     its CONFIG_CMDLINE_FORCE already selects rdinit=/pianoinit)
#   - initramfs: embedded via CONFIG_INITRAMFS_SOURCE (repo-verified path),
#     entry = <staging>/pianoinit  (this directory's `pianoinit`)
#   - boot.img: header v4 / pagesize 4096 / base 0 / offsets per
#     boot/stock-boot-params.env (CONFIRMED values), no external ramdisk
#   - dtbo: passed through via --dtbo (build it with the repo's
#     scripts/build-dtbo.py over boot/dtbo-piano-rootfs.dts)
#
# RAM-boot via `fastboot boot` does NOT need an AVB footer. Only a cold
# boot from boot_b does — run the repo's scripts/sign-boot-avb.sh first then.
#
# Repo layout auto-detection: this script may live anywhere inside the
# llfzs/linux clone (e.g. partition-env/); the repo root is found by walking
# up until a directory containing mkbootimg/ appears. Override with --repo-root.
#
# Tools directory layout (--tools-dir):
#   bin/   executables (static busybox goes via --busybox instead)
#   lib/   shared-library closure with Debian arm64 layout, e.g.
#          lib/ld-linux-aarch64.so.1, lib/aarch64-linux-gnu/*.so.*
#   (A flat directory of executables also works — legacy mode, libs ignored.)
#
# Usage:
#   ./build-partition-image.sh \
#     --kernel-src ../linux-piano \
#     --busybox  /path/to/busybox.static \
#     --smmu-tool /path/to/piano-qup-smmu \
#     --tools-dir /path/to/tools \
#     [--dtbo /path/to/dtbo.img] [--config piano_rootfs] [--jobs N]
#     [--dropbear-tree DIR] [--repo-root DIR] [--gcc] [--out out/partition-image]

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

# --- locate the llfzs/linux repo root (dir containing mkbootimg/) ----------
REPO_ROOT=""
_d="$HERE"
for _i in 1 2 3 4 5; do
    if [ -d "$_d/mkbootimg" ]; then REPO_ROOT="$_d"; break; fi
    _d=$(dirname "$_d")
done

KERNEL_SRC=""
BUSYBOX=""
SMMU_TOOL=""
TOOLS_DIR=""
DTBO=""
CONFIG_NAME="piano_rootfs"
DROPBEAR_TREE=""
JOBS=$(nproc)
OUT=""
STAGING=""
USE_LLVM=1

usage() { sed -n '2,40p' "$0" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --kernel-src)    KERNEL_SRC=$2;    shift 2 ;;
        --busybox)       BUSYBOX=$2;       shift 2 ;;
        --smmu-tool)     SMMU_TOOL=$2;     shift 2 ;;
        --tools-dir)     TOOLS_DIR=$2;     shift 2 ;;
        --dtbo)          DTBO=$2;          shift 2 ;;
        --config)        CONFIG_NAME=$2;   shift 2 ;;
        --dropbear-tree) DROPBEAR_TREE=$2; shift 2 ;;
        --repo-root)     REPO_ROOT=$2;     shift 2 ;;
        --jobs)          JOBS=$2;          shift 2 ;;
        --out)           OUT=$2;           shift 2 ;;
        --staging)       STAGING=$2;       shift 2 ;;
        --gcc)           USE_LLVM=0;       shift ;;
        -h|--help)       usage ;;
        *) echo "unknown arg: $1" >&2; usage ;;
    esac
done

die() { echo "build-partition-image: $*" >&2; exit 1; }

[ -n "$REPO_ROOT" ] || die "cannot locate llfzs/linux repo root (no mkbootimg/ found upward from $HERE); pass --repo-root"
OUT=${OUT:-$REPO_ROOT/out/partition-image}
STAGING=${STAGING:-$REPO_ROOT/out/partition-staging}

[ -n "$KERNEL_SRC" ] || die "--kernel-src required (code002-2/linux @ piano-7.2.6)"
[ -d "$KERNEL_SRC" ] || die "kernel src not found: $KERNEL_SRC"
[ -x "$(command -v python3)" ] || die "python3 required"
for t in make gcc flex bison cpio; do
    command -v "$t" >/dev/null || die "missing host tool: $t"
done
[ -n "$BUSYBOX" ] && [ -f "$BUSYBOX" ]  || die "--busybox <static busybox> required"
[ -n "$SMMU_TOOL" ] && [ -f "$SMMU_TOOL" ] || die "--smmu-tool <piano-qup-smmu> required"
[ -n "$TOOLS_DIR" ] || die "--tools-dir <dir> required"
[ -d "$TOOLS_DIR" ] || die "tools dir not found: $TOOLS_DIR"
[ -f "$HERE/pianoinit" ] || die "pianoinit not next to this script"
CONFIG_FILE="$KERNEL_SRC/arch/arm64/configs/${CONFIG_NAME}.config"
[ -f "$CONFIG_FILE" ] || die "kernel config not found: $CONFIG_FILE"

# mkbootimg from the repo (vendored AOSP tool)
MKBOOTIMG=""
for c in "$REPO_ROOT/mkbootimg/mkbootimg.py" "$REPO_ROOT/mkbootimg/mkbootimg"; do
    [ -f "$c" ] && MKBOOTIMG="$c" && break
done
[ -n "$MKBOOTIMG" ] || die "vendored mkbootimg not found under $REPO_ROOT/mkbootimg/"

if [ -n "$DTBO" ]; then
    [ -f "$DTBO" ] || die "dtbo not found: $DTBO"
else
    echo "NOTE: --dtbo not given; producing boot.img only." >&2
    echo "      Build one with: python3 scripts/build-dtbo.py \\" >&2
    echo "        --dts boot/dtbo-piano-rootfs.dts --kernel-dir <kernel> \\" >&2
    echo "        --output <out>/dtbo.img" >&2
fi

if [ "$USE_LLVM" = 1 ]; then
    command -v clang >/dev/null || die "clang required (or pass --gcc)"
    KMAKE="make LLVM=1"
else
    KMAKE="make"
fi

mkdir -p "$OUT"
rm -rf "$STAGING"
mkdir -p "$STAGING/bin" "$STAGING/sbin" "$STAGING/etc" "$STAGING/run" \
         "$STAGING/proc" "$STAGING/sys" "$STAGING/dev" "$STAGING/tmp" \
         "$STAGING/mnt" "$STAGING/root" "$STAGING/lib" "$STAGING/usr/bin" \
         "$STAGING/usr/sbin"

# ------------------------------------------------------- initramfs staging --
echo ">> staging initramfs"
install -m 0755 "$HERE/pianoinit" "$STAGING/pianoinit"
install -m 0755 "$BUSYBOX"        "$STAGING/bin/busybox"
install -m 0755 "$SMMU_TOOL"      "$STAGING/bin/piano-qup-smmu"

if [ -d "$TOOLS_DIR/bin" ]; then
    find "$TOOLS_DIR/bin" -maxdepth 1 -type f -print0 |
    while IFS= read -r -d '' f; do install -m 0755 "$f" "$STAGING/bin/"; done
    if [ -d "$TOOLS_DIR/lib" ]; then
        cp -a "$TOOLS_DIR/lib/." "$STAGING/lib/"
    fi
else
    # legacy flat layout: executables only
    find "$TOOLS_DIR" -maxdepth 1 -type f -executable -print0 |
    while IFS= read -r -d '' f; do install -m 0755 "$f" "$STAGING/bin/"; done
fi
[ -x "$STAGING/bin/sgdisk" ] ||
    echo "WARNING: no sgdisk staged — image will be inspect-only" >&2

if [ -n "$DROPBEAR_TREE" ]; then
    cp -a "$DROPBEAR_TREE/." "$STAGING/" ||
        die "failed to copy dropbear tree"
fi

# ------------------------------------------------------------- kernel build --
echo ">> preparing kernel config (INITRAMFS_SOURCE=$STAGING)"
(
    cd "$KERNEL_SRC"
    cp "arch/arm64/configs/${CONFIG_NAME}.config" .config
    if [ -x ./scripts/config ]; then
        ./scripts/config --file .config \
            --set-str CONFIG_INITRAMFS_SOURCE "$STAGING"
    else
        sed -i "/CONFIG_INITRAMFS_SOURCE/d" .config
        echo "CONFIG_INITRAMFS_SOURCE=\"$STAGING\"" >> .config
    fi
    $KMAKE ARCH=arm64 olddefconfig >/dev/null
)

# modules first: modules_install populates $STAGING/lib/modules,
# then the Image build embeds the finished staging tree.
echo ">> building modules"
$KMAKE -C "$KERNEL_SRC" ARCH=arm64 -j"$JOBS" modules >/dev/null
echo ">> installing modules into staging"
$KMAKE -C "$KERNEL_SRC" ARCH=arm64 INSTALL_MOD_PATH="$STAGING" \
    modules_install >/dev/null
# strip build/source symlinks (absolute paths, useless inside initramfs)
KVER=$(make -s -C "$KERNEL_SRC" ARCH=arm64 kernelrelease)
rm -f "$STAGING/lib/modules/$KVER/build" "$STAGING/lib/modules/$KVER/source"

echo ">> building Image (kernel $KVER, initramfs embedded, LLVM=$USE_LLVM)"
$KMAKE -C "$KERNEL_SRC" ARCH=arm64 -j"$JOBS" Image >/dev/null
IMAGE="$KERNEL_SRC/arch/arm64/boot/Image"
[ -f "$IMAGE" ] || die "Image missing after build"

# ------------------------------------------------------------- boot.img ----
# Parameters from boot/stock-boot-params.env (CONFIRMED section):
#   header v4, pagesize 4096, base 0, kernel 0x8000, ramdisk 0x1000000,
#   tags 0x100. No external ramdisk (initramfs is embedded in the Image);
#   cmdline is forced by CONFIG_CMDLINE_FORCE (rdinit=/pianoinit).
echo ">> packing boot.img"
python3 "$MKBOOTIMG" \
    --kernel "$IMAGE" \
    --header_version 4 \
    --pagesize 4096 \
    --base 0 \
    --kernel_offset 0x8000 \
    --ramdisk_offset 0x1000000 \
    --tags_offset 0x100 \
    --cmdline "" \
    -o "$OUT/partition-boot.img"

if [ -n "$DTBO" ]; then
    cp "$DTBO" "$OUT/dtbo.img"
fi

# ------------------------------------------------------------- manifest ----
{
    echo "piano partition-rescue image"
    echo "date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "kernel:   $KVER ($(git -C "$KERNEL_SRC" rev-parse --short HEAD 2>/dev/null || echo unknown))"
    echo "repo:     $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "config:   ${CONFIG_NAME}.config + INITRAMFS_SOURCE=$STAGING (unmodified cmdline)"
    echo "compiler: $([ "$USE_LLVM" = 1 ] && echo 'LLVM=1 (clang/lld)' || echo gcc)"
    echo "entry:    /pianoinit (rdinit from CONFIG_CMDLINE_FORCE)"
    echo "policy:   init performs no persistent writes; GPT surgery is interactive"
    if [ -x "$STAGING/bin/sgdisk" ]; then
        echo "tools:    $(ls "$STAGING/bin" | tr '\n' ' ')"
    else
        echo "tools:    inspect-only (no sgdisk staged)"
    fi
    echo ""
    echo "RAM boot (no AVB footer needed):"
    echo "  fastboot set_active b"
    echo "  fastboot flash dtbo_b dtbo.img"
    echo "  fastboot boot partition-boot.img"
    echo "  # host: nmcli … 10.42.0.1/24; ssh root@10.42.0.2"
    echo ""
    echo "Cold boot from boot_b instead? Sign first with the repo's"
    echo "scripts/sign-boot-avb.sh (boot_b requires an AVB hash footer)."
    (cd "$OUT" && sha256sum ./* 2>/dev/null)
} > "$OUT/MANIFEST.txt"

echo ">> done: $OUT"
ls -l "$OUT"
