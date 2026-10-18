# piano 分区环境构建套件（partition-rescue）

基于 llfzs/linux 构建骨架的可落地实现：`fastboot boot` 进入最小分区环境，
SSH/telnet 接管后手工执行 GPT 操作。

## 文件
| 文件 | 作用 |
|------|------|
| `pianoinit` | initramfs 入口（安装为 `/pianoinit`）：NCM + SMMU/UFS 时序（逐行取自 rootfs-init）+ 块设备清单 + 常驻 shell。**init 本身零写入**，分区操作全部交互执行 |
| `build-partition-image.sh` | 编排：staging 组装 → modules_install 进 staging → `CONFIG_INITRAMFS_SOURCE` 内嵌 → 编 Image（默认 LLVM=1）→ 仓库 vendored mkbootimg 组 v4 boot.img → MANIFEST。仓库根自动探测，也可 `--repo-root` 指定 |
| `partition-env.yml` | 独立 GitHub Actions workflow：arm64 runner 上自动取工具（busybox-static/sgdisk/e2fsprogs + ldd 闭包）、编 rootfs dtbo、调本脚本构建、上传 14 天 artifact |

## GitHub Actions 构建（推荐）
把本目录放进你 fork 的 llfzs/linux 仓库根，workflow 放 `.github/workflows/`：
```
your-fork/
├── partition-env/{pianoinit, build-partition-image.sh, README.md}
└── .github/workflows/partition-env.yml
```
然后 Actions → partition-env → Run workflow（可选 kernel_ref，默认 piano-7.2.6）。
产物：`partition-env-<sha>` artifact（partition-boot.img + dtbo.img + MANIFEST，保留 14 天）。

CI 自动完成：内核 checkout、fetch-arm64-tools（定位 piano-qup-smmu）、
busybox-static/sgdisk/e2fsprogs 工具闭包、`build-dtbo.py` 编 rootfs dtbo、
LLVM=1 内核构建与组包。

## 本地构建
```bash
./build-partition-image.sh \
  --kernel-src ../linux-piano \
  --busybox    ../tools/busybox \
  --smmu-tool  ../tools/piano-qup-smmu \
  --tools-dir  ../tools \
  --dtbo       out/ci-image/dtbo.img \
  --jobs "$(nproc)"
# 产出 out/partition-image/{partition-boot.img, dtbo.img, MANIFEST.txt}
# 默认 LLVM=1（与仓库 CI 一致）；本地只有 gcc 时加 --gcc
```
`--dtbo` 三种来源：本地 rootfs 构建产物（`out/ci-image/dtbo.img`）、
CI 下载的 flash bundle、或自编：
```bash
python3 scripts/build-dtbo.py \
  --dts boot/dtbo-piano-rootfs.dts --kernel-dir ../linux-piano \
  --output out/dtbo.img
```
（`build-dtbo.py` 自动识别 `../linux-piano` 与 `kernel/` 两种布局。）

### tools 目录布局（本地）
```
tools/
├── bin/   可执行文件（sgdisk、mkfs.ext4、e2fsck、resize2fs…）
└── lib/   动态库闭包（Debian arm64 布局）
    ├── ld-linux-aarch64.so.1
    └── aarch64-linux-gnu/*.so.*
```
静态 busybox 单独经 `--busybox` 传入。arm64 容器导出示例：
```bash
docker run --rm --platform linux/arm64 -v "$PWD/../tools":/out alpine sh -c '
  apk add --no-cache busybox-static sgdisk e2fsprogs &&
  cp /bin/busybox.static /out/busybox'
# 或在 arm64 主机/runner 上按 partition-env.yml 的 "Stage the partition
# toolset" 步骤做 ldd 闭包。
```

## 上机
```bash
fastboot getvar current-slot          # 记录
fastboot set_active b                 # RAM boot 组合槽 b 镜像（硬约束）
fastboot flash dtbo_b dtbo.img        # 唯一预写（防 stock dtbo 的 eUSB2 挂死）
fastboot boot partition-boot.img      # 全内存，重启即回

# 主机接管
nmcli con add type ethernet ifname <usb网卡> con-name piano-ncm \
      ipv4.method manual ipv4.addresses 10.42.0.1/24 ipv6.method disabled
nmcli con up piano-ncm
ssh root@10.42.0.2        # 或 nc 10.42.0.2 23

# 进环境后第一步（脚本 banner 也有提示）：GPT 备份落到主机
ssh root@10.42.0.2 'dd if=/dev/sda bs=512 count=34' | dd of=gpt-head.bin
ssh root@10.42.0.2 'dd if=/dev/sda bs=512 skip=$(( $(blockdev --getsz /dev/sda) - 33 ))' \
    | dd of=gpt-tail.bin   # 尾部 33 扇区（备份 GPT）

# 真实分区（人手执行，环境自身不自动写）
sgdisk -p /dev/sda
sgdisk --delete=N /dev/sda
sgdisk --new=N:<原start>:<新end> --change-name=N:userdata \
       --typecode=N:<原typecode> --partition-guid=N:<原GUID> /dev/sda
sgdisk --new=M:0:0 --change-name=M:linuxroot --typecode=M:8300 /dev/sda
sync
```

## 注意
- 入口名不能改成 `/init`（ABL 会追加 Android first-stage init 覆盖同名文件）；
- `pianoinit` 中 CLKREF 的 devmem 访问逐行取自 rootfs-init，**不要扩大寄存器范围**；
- 改动 `pianoinit` 后先 `sh -n pianoinit`（runbook 教训：一行语法错即可 panic）；
- 环境驻留期间保持 USB 供电（充电未验证）；
- 分区红线：GPT 备份、Android 数据备份、救援 ROM 常备；不碰 XBL/ABL/super；
- 本 profile 显式偏离仓库"init 永不写分区"审计线（init 不自动写、交互写），已在脚本头声明。

## 与仓库的关系
脚本是 llfzs 构建体系之上的薄封装：mkbootimg、stock 参数溯源、build-dtbo.py、
fetch-arm64-tools、签名脚本、时序脚本全部来自仓库；`pianoinit` 为 rootfs-init
的裁剪版。上游更新时优先对照 `initramfs/rootfs-init` 的 SMMU/UFS 段同步。
