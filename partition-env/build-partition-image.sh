#!/usr/bin/env bash
# build-partition-image.sh — piano partition-rescue image builder
#
# Kernel config path (matches upstream build-rootfs-image.sh exactly):
#   piano_defconfig  ->  merge piano_rootfs.config fragment  ->  olddefconfig
#   (the rootfs config is a FRAGMENT; using it as a full .config produces a
#    broken kernel — that was the v1 bug: no USB, no display, black screen.)
#
# dtbo: build with the repo's scripts/build-dtbo.py over
#   boot/dtbo-piano-power.dts  (the source upstream rootfs builds use).
#
# boot.img: vendored mkbootimg, header v4 / pagesize 4096 / base 0 /
#   offsets from boot/stock-boot-params.env; initramfs embedded via
#   CONFIG_INITRAMFS_SOURCE; entry = /pianoinit (repo-rootfs forced cmdline).
#
# RAM-boot via `fastboot boot` needs no AVB footer (cold boot_b does).

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

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
DROPBEAR_TREE=""
FRAGMENT="piano_rootfs"
JOBS=$(nproc)
OUT=""
STAGING=""

usage() { sed -n '2,20p' "$0" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --kernel-src)    KERNEL_SRC=$2;    shift 2 ;;
        --busybox)       BUSYBOX=$2;       shift 2 ;;
        --smmu-tool)     SMMU_TOOL=$2;     shift 2 ;;
        --tools-dir)     TOOLS_DIR=$2;     shift 2 ;;
        --dtbo)          DTBO=$2;          shift 2 ;;
        --dropbear-tree) DROPBEAR_TREE=$2; shift 2 ;;
        --fragment)      FRAGMENT=$2;      shift 2 ;;
        --repo-root)     REPO_ROOT=$2;     shift 2 ;;
        --jobs)          JOBS=$2;          shift 2 ;;
        --out)           OUT=$2;           shift 2 ;;
        --staging)       STAGING=$2;       shift 2 ;;
        -h|--help)       usage ;;
        *) echo "unknown arg: $1" >&2; usage ;;
    esac
done

die() { echo "build-partition-image: $*" >&2; exit 1; }

[ -n "$REPO_ROOT" ] || die "cannot locate repo root (no mkbootimg/); pass --repo-root"
# kbuild requires an ABSOLUTE O= path: a relative one is resolved against the
# directory after make -C, silently breaking srctree detection (symptom:
# "No rule to make target 'piano_defconfig'"). Normalize everything.
KERNEL_SRC=$(realpath -m "${KERNEL_SRC:?}")
REPO_ROOT=$(realpath -m "$REPO_ROOT")
OUT=${OUT:-$REPO_ROOT/out/partition-image}
STAGING=${STAGING:-$REPO_ROOT/out/partition-staging}
OUT=$(realpath -m "$OUT")
STAGING=$(realpath -m "$STAGING")

[ -n "$KERNEL_SRC" ] || die "--kernel-src required"
[ -d "$KERNEL_SRC" ] || die "kernel src not found: $KERNEL_SRC"
[ -x "$(command -v python3)" ] || die "python3 required"
for t in make gcc flex bison cpio; do
    command -v "$t" >/dev/null || die "missing host tool: $t"
done
command -v clang >/dev/null || die "clang required (upstream builds are LLVM=1)"
[ -n "$BUSYBOX" ] && [ -f "$BUSYBOX" ]  || die "--busybox <static busybox> required"
[ -n "$SMMU_TOOL" ] && [ -f "$SMMU_TOOL" ] || die "--smmu-tool <piano-qup-smmu> required"
[ -n "$TOOLS_DIR" ] || die "--tools-dir required"
[ -f "$HERE/pianoinit" ] || die "pianoinit not next to this script"
FRAG_FILE="$KERNEL_SRC/arch/arm64/configs/${FRAGMENT}.config"
[ -f "$FRAG_FILE" ] || die "kernel config fragment not found: $FRAG_FILE"
[ -f "$KERNEL_SRC/arch/arm64/configs/piano_defconfig" ] || die "piano_defconfig missing"

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
    echo "        --dts boot/dtbo-piano-power.dts --kernel-dir <kernel> \\" >&2
    echo "        --output <out>/dtbo.img" >&2
fi

KBUILD_OUT="$KERNEL_SRC/out/partition-build"
KMAKE=(make -C "$KERNEL_SRC" O="$KBUILD_OUT" ARCH=arm64 LLVM=1)

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
    find "$TOOLS_DIR" -maxdepth 1 -type f -executable -print0 |
    while IFS= read -r -d '' f; do install -m 0755 "$f" "$STAGING/bin/"; done
fi
[ -x "$STAGING/bin/sgdisk" ] ||
    echo "WARNING: no sgdisk staged — image will be inspect-only" >&2

if [ -n "$DROPBEAR_TREE" ]; then
    # Some aarch64 tool trees provide /lib as a symlink into /usr/lib
    # (upstream build-initramfs.sh handles it the same way): copy the usr
    # tree verbatim, then dereference lib into a REAL directory so kernel
    # modules and the loader stay discoverable in the initramfs.
    [ -d "$DROPBEAR_TREE/usr" ] || die "dropbear tree has no usr/ dir: $DROPBEAR_TREE"
    cp -a "$DROPBEAR_TREE/usr" "$STAGING/"
    mkdir -p "$STAGING/lib"
    cp -aL "$DROPBEAR_TREE/lib/." "$STAGING/lib/" ||
        die "failed to copy dropbear lib closure"
fi

# ------------------------------------------------------------- kernel config --
echo ">> config: piano_defconfig + $FRAGMENT fragment (upstream path)"
(
    cd "$KERNEL_SRC"
    "${KMAKE[@]}" piano_defconfig >/dev/null
    if [ -x ./scripts/kconfig/merge_config.sh ]; then
        ./scripts/kconfig/merge_config.sh -m -O "$KBUILD_OUT" \
            "$KBUILD_OUT/.config" \
            "arch/arm64/configs/${FRAGMENT}.config" >/dev/null
    else
        cat "arch/arm64/configs/${FRAGMENT}.config" >> "$KBUILD_OUT/.config"
    fi
    "${KMAKE[@]}" olddefconfig >/dev/null
    # embed the partition initramfs
    if [ -x ./scripts/config ]; then
        ./scripts/config --file "$KBUILD_OUT/.config" \
            --set-str CONFIG_INITRAMFS_SOURCE "$STAGING"
    else
        sed -i "/CONFIG_INITRAMFS_SOURCE/d" "$KBUILD_OUT/.config"
        echo "CONFIG_INITRAMFS_SOURCE=\"$STAGING\"" >> "$KBUILD_OUT/.config"
    fi
    "${KMAKE[@]}" olddefconfig >/dev/null
    # hard gates from the upstream build
    for opt in CONFIG_CMDLINE_FORCE=y CONFIG_EXT4_FS=y CONFIG_DRM_SIMPLEDRM=y \
               CONFIG_SCSI_UFSHCD=m CONFIG_SCSI_UFS_QCOM=m \
               CONFIG_PHY_QCOM_QMP_UFS=m CONFIG_USB_CONFIGFS_NCM=y; do
        grep -qxF "$opt" "$KBUILD_OUT/.config" ||
            { echo "Required: $opt" >&2; exit 1; }
    done
)

# ----------------------------------------------------------- two-pass build --
echo ">> building Image + modules (pass 1)"
"${KMAKE[@]}" -j"$JOBS" Image modules >/dev/null
echo ">> installing modules into staging"
"${KMAKE[@]}" INSTALL_MOD_PATH="$STAGING" modules_install >/dev/null
KVER=$(cat "$KBUILD_OUT/include/config/kernel.release")
rm -f "$STAGING/lib/modules/$KVER/build" "$STAGING/lib/modules/$KVER/source"

echo ">> rebuilding Image (pass 2, $KVER, initramfs with modules)"
find "$KBUILD_OUT/usr" -maxdepth 1 -name 'initramfs_data*' -delete 2>/dev/null || true
"${KMAKE[@]}" -j"$JOBS" Image >/dev/null
IMAGE="$KBUILD_OUT/arch/arm64/boot/Image"
[ -f "$IMAGE" ] || die "Image missing after build"

# ------------------------------------------------------------- boot.img ----
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
    echo "config:   piano_defconfig + ${FRAGMENT}.config (merged) + INITRAMFS_SOURCE=$STAGING"
    echo "compiler: LLVM=1 (clang/lld)"
    echo "dtbo:     $( [ -n "$DTBO" ] && echo "$(basename "$DTBO")" || echo '(not bundled)') — build source must be boot/dtbo-piano-power.dts"
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
    echo "  # host: 10.42.0.1/24; ssh root@10.42.0.2 (empty password) or nc … 23"
    (cd "$OUT" && sha256sum ./* 2>/dev/null)
} > "$OUT/MANIFEST.txt"

echo ">> done: $OUT"
ls -l "$OUT"
