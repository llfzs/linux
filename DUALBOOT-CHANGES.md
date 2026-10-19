# 双系统分支（dualboot）修改清单

目标：让构建产物支持「Android 槽 A（不动）+ Linux 槽 B（boot_b/dtbo_b）+
独立 `PARTLABEL=linux` 分区作 Debian 根」。userdata 保持 Android 专属（f2fs+FBE）。

设备前提（你已完成）：平板上已创建名为 `linux` 的 GPT 分区（ext4 或未格式化均可，
刷镜像时会覆盖）。

---

## 一、建分支并提交修改

```bash
cd 你的fork目录
git checkout -b dualboot origin/main
```

### 修改 1：`initramfs/rootfs-init`（核心）
用本目录 `rootfs-init` **整文件替换**（相对上游 main 的差异只有 3 处）：
1. 删除 `root=` cmdline 解析与 `PARTLABEL=userdata` 强校验，改为固定
   `root_label=linux`（上游 cmdline 里残留的 root= 被有意忽略，内核 config 不用动）；
2. 分区探测 `grep -qx 'PARTNAME=userdata'` → `grep -qx "PARTNAME=$root_label"`；
3. rescue 文案改为指向 linux 分区（含"先建分区/先刷镜像"的提示）。
其余（NCM/SSH、SMMU、UFS 时序、diagnostic、switch_root）逐行保持上游原样。

### 修改 2：`rootfs/overlay/etc/fstab`
用本目录 `fstab` 替换（1 行）：
```
PARTLABEL=linux / ext4 defaults,noatime,x-systemd.growfs 0 1
```
`x-systemd.growfs` 保留：12G 镜像刷进更大的 linux 分区后，首次启动自动扩容。

### 修改 3：`.github/workflows/build.yml`
两处（可选其一或都做）：
a) 让 push 到 dualboot 分支自动构建：
```yaml
  push:
    branches: [main, dualboot]     # 原 [main]
```
b) 在 "Build the matched GNOME image set" 步骤末尾的 MANIFEST append 块里加一行，
   让产物自带双系统刷写说明：
```yaml
            echo 'Dual-boot: flash rootfs with: fastboot flash linux userdata.img (NOT userdata!)'
```
（不改也能构建：workflow_dispatch 手动触发时选 dualboot 分支即可。）

### 提交
```bash
git add initramfs/rootfs-init rootfs/overlay/etc/fstab .github/workflows/build.yml
git commit -m "dualboot: root on dedicated PARTLABEL=linux partition"
git push origin dualboot
```

---

## 二、构建
- **手动**：Actions → build → Run workflow → 分支选 `dualboot`（kernel_ref 默认
  piano-7.2.6，image_size 按你的 linux 分区大小设，如 32G——镜像不必等于分区，
  growfs 首启会自动扩满）；
- **自动**：push 到 dualboot 分支（需完成修改 3a）；
- **发 Release**：`git tag piano-dualboot-v1 && git push origin piano-dualboot-v1`
  （tag 匹配 `piano-v*` 才触发 Release；`piano-dualboot-v1` 不匹配——用
  `piano-v1-dualboot` 这类以 piano-v 开头的名字）。

产物与 main 完全一致：boot.img（AVB 已签名）、dtbo.img、userdata.img.zst
（内容=linux 分区的 rootfs）、rootfs tarball。

---

## 三、刷写流程（双系统）

```bash
fastboot getvar current-slot          # 记录；Android 在槽 A 保持不动
fastboot set_active b
fastboot flash boot_b boot.img
fastboot flash dtbo_b dtbo.img
zstd -d userdata.img.zst -o linux.img
fastboot flash linux linux.img        # ← 关键差异：刷 linux 分区，不是 userdata！
fastboot reboot                       # 冷启动进 Debian（首次自动 growfs 扩容）
```

切回 Android：
```bash
# 音量减+电源进 fastboot
fastboot set_active a && fastboot reboot
```
或 Linux 里装 qbootctl：`qbootctl -s a && reboot`（见本系列 stage5 产物）。

---

## 四、风险与不变量
- userdata 不再被 Linux 触碰：Android 数据保留（这是本分支的意义）；
- 内核 config、AVB 签名、dtbo 与上游完全一致——只动了「根在哪」；
- 若 linux 分区未建/未刷镜像：/pianoinit 会进 rescue 并明确提示原因（安全）；
- 老规矩：不碰 XBL/ABL、OTA 写槽 B 前先关更新、救援 ROM 常备。

## 五、回滚
```bash
fastboot set_active a                 # 回 Android
# Linux 引导清除：重刷 stock boot_b/dtbo_b（救援 ROM 内有）
```
