#!/usr/bin/env python3
"""build-dtbo.py — compile the piano bring-up DTBO image.

Usage:
    scripts/build-dtbo.py [--dts PATH] [--output PATH] [--dtc dtc]
                          [--kernel-dir PATH]

Compiles debian-piano/boot/dtbo-piano-bringup.dts with `dtc -@` (kernel
dt-bindings include path taken from --kernel-dir, PIANO_KERNEL_DIR /
PIANO_KERNEL_INCLUDE, or the kernel checkout found next to this repository)
and wraps the result in a single-entry big-endian Android DTBO table
header:

    struct dt_table_header (all fields big-endian):
        magic          0xd7b7ab1e
        total_size     header + entry header + dtb
        header_size    32
        dt_entry_size  32
        dt_entry_count 1
        dt_entries_off 32
        page_size      4096
        version        0
    struct dt_table_entry (big-endian):
        dt_size, dt_offset(=64), id, rev, custom[4]

The bring-up overlay is the stock piano dtbo entry 0 (all downstream
fragments intact) plus:

  * fragment@200 — simple-framebuffer node at the cont_splash memory
    (0xfc800000, 0x2b00000): dual-DSI full width 3200 x 2136,
    stride 12800, a8b8g8r8.  Quad-split console output is the symptom of
    declaring 1600/6400 against the real 3200-wide scanout.
  * /reserved-memory/splash_region gains `no-map` so simpledrm's
    devm_ioremap_wc does not collide with the linear mapping.
  * fragments@201..214 — mainline DT provider overrides + the dwc3 USB
    stack (gcc/tcsr/icc/rpmh-clk/smmu providers, rpmhpd, bi_tcxo_div2,
    M31 eUSB2 + QMP combo phys, the usb@a600000 wrapper in mainline
    binding, downstream nested dwc3 child disabled).  Phandle references
    inside these fragments resolve against the stock tree labels via
    the overlay __symbols__ mechanism.

ABL phandle-rewrites the merged tree, so added fragments must only use
stock-tree labels (via `target = <&label>`) or target-path — never
hard-coded phandle numbers.

Flashed to dtbo_b only (`fastboot flash dtbo_b`).  Never write
bootloader-chain partitions.
"""

import argparse
import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

MAGIC = 0xD7B7AB1E


def kernel_include_candidates(repo: Path, kernel_dir) -> "list[Path]":
    """Every plausible <kernel>/include tree, in priority order.

    An explicit --kernel-dir wins: it may be a kernel source checkout or an
    O= build tree (kbuild links the source tree as ./source inside it).
    """
    cands = []

    def add(path: Path) -> None:
        if path not in cands:
            cands.append(path)

    if kernel_dir:
        kd = Path(kernel_dir).resolve()
        add(kd / "source" / "include")
        add(kd / "include")
    env_dir = os.environ.get("PIANO_KERNEL_DIR")
    if env_dir:
        ed = Path(env_dir).resolve()
        add(ed / "source" / "include")
        add(ed / "include")
    env_inc = os.environ.get("PIANO_KERNEL_INCLUDE")
    if env_inc:
        add(Path(env_inc).resolve())
    # Umbrella layouts: in CI this repository is checked out into src/ and the
    # kernel into src/kernel, so the tree is <repo>/kernel; a local workspace
    # keeps the kernel next to debian-piano (kernel/ or linux-piano/).
    for base in (repo, repo.parent):
        add(base / "kernel" / "include")
        add(base / "linux-piano" / "include")
    return cands


def resolve_kernel_include(repo: Path, kernel_dir) -> "Path | None":
    cands = kernel_include_candidates(repo, kernel_dir)
    for cand in cands:
        if (cand / "dt-bindings").is_dir():
            return cand
    print("build-dtbo: no kernel dt-bindings include tree found; tried:", file=sys.stderr)
    for cand in cands:
        print(f"  {cand}", file=sys.stderr)
    print("build-dtbo: pass --kernel-dir (kernel source or O= build tree)", file=sys.stderr)
    return None


def build(kinc: Path, dts: Path, output: Path, dtc: str) -> None:
    with tempfile.TemporaryDirectory() as td:
        dtb = Path(td) / "overlay.dtb"
        pp = Path(td) / "overlay.pp.dts"
        subprocess.run(
            ["cpp", "-nostdinc", "-undef", "-x", "assembler-with-cpp",
             "-I", str(kinc), "-o", str(pp), str(dts)],
            check=True,
        )
        subprocess.run(
            [dtc, "-@", "-I", "dts", "-O", "dtb", "-o", str(dtb), str(pp)],
            check=True,
        )
        blob = dtb.read_bytes()
    entry = struct.pack(">8I", len(blob), 64, 0, 0, 0, 0, 0, 0)
    total = 32 + 32 + len(blob)
    header = struct.pack(">8I", MAGIC, total, 32, 32, 1, 32, 4096, 0)
    output.write_bytes(header + entry + blob)
    print(f"build-dtbo: wrote {output} ({total} bytes, dtb {len(blob)})")


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--dts", type=Path,
                    default=repo / "boot" / "dtbo-piano-bringup.dts")
    ap.add_argument("--output", type=Path,
                    default=repo / "out" / "test-image" / "dtbo-piano-bringup.img")
    ap.add_argument("--dtc", default="dtc")
    ap.add_argument("--kernel-dir", default=None,
                    help="kernel source checkout or O= build tree holding "
                         "include/dt-bindings (e.g. the --kernel-dir of "
                         "scripts/build-test-bootimg.sh)")
    args = ap.parse_args()
    if not args.dts.is_file():
        print(f"build-dtbo: missing overlay source {args.dts}", file=sys.stderr)
        return 1
    kinc = resolve_kernel_include(repo, args.kernel_dir)
    if kinc is None:
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    build(kinc, args.dts, args.output, args.dtc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
