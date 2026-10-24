# piano-slot-switch — Android 一键切换 Linux 模块（KernelSU/Magisk）

## 原理
qbootctl（静态 musl 版）+ 运行时补建 /dev/bsg 节点 + by-partlabel 兼容链接。
内核已具备 BSG 支持（/sys/class/bsg/ufs-bsg0），只缺设备节点——脚本自动补齐。

## 模块文件结构（打包 zip 前）

```
piano-slot-switch/
├── module.prop          （本目录已提供）
├── piano-switch         （本目录已提供，切换脚本）
└── qbootctl             （从 qbootctl-static workflow 的 Release/Artifact 下载）
```

安装目录约定：KernelSU 模块实际路径为
`/data/adb/modules/piano-slot-switch/`，脚本通过 `$MODDIR` 找同目录的 qbootctl。

## 组装步骤

1. **编译静态 qbootctl**：把 `qbootctl-static.yml` 放进你 fork 的
   `.github/workflows/` → Actions → Run workflow → 下载 `qbootctl-static-*` 产物；
2. 本地组目录：
   ```
   piano-slot-switch/
   ├── module.prop
   ├── piano-switch
   └── qbootctl          (来自上一步)
   ```
3. 打 zip：
   ```powershell
   Compress-Archive -Path piano-slot-switch/* -DestinationPath piano-slot-switch.zip
   ```
   （Linux/WSL: cd piano-slot-switch && zip -r ../piano-slot-switch.zip .）
4. KernelSU（或 Magisk）→ 模块 → 从本地安装 → 选择 zip → 重启。

## 使用（root shell / Termux）

```sh
su -c piano-switch                 # 查看槽位状态（含 active/successful）
su -c piano-switch to-linux        # 切到 B 槽 Linux 并自动重启
su -c piano-switch to-android      # 切到 A 槽 Android 并自动重启
```

## 桌面一键按钮（可选，两种做法）

1. **Termux:Widget**：Termux 里建 `~/.shortcuts/to-linux.sh`：
   ```sh
   su -c /data/adb/modules/piano-slot-switch/piano-switch to-linux
   ```
   桌面添加 Termux:Widget 小部件 → 点按即切；
2. **任意支持 root 命令的启动器插件**（如 SKS / MacroDroid root shell）：
   命令填 `su -c /data/adb/modules/piano-slot-switch/piano-switch to-linux`。

## Linux → Android 方向

在 Linux 侧（Debian）安装 qbootctl 后：
```sh
sudo qbootctl -s a && sudo reboot
```
（也可以做一个 .desktop 启动器实现桌面一键。）

## 安全说明

1. 切换失败时脚本不重启（qbootctl 返回非零即中止），避免半切换状态；
2. ABL retry 机制兜底：B 槽连续启动失败会自动标记 unbootable 并回退 A；
3. **每次 Android 系统更新（OTA）后**，dtbo_b 会被覆盖——先用 fastboot 重刷
   dualboot 的 dtbo_b 再使用一键切换；
4. /dev/bsg 节点与 by-partlabel 链接在重启后消失（tmpfs），脚本每次运行自动重建。

## 故障排查

| 现象 | 处理 |
|------|------|
| `qbootctl binary missing` | qbootctl 没放进模块目录，重新组装 |
| `no-udc`/权限错误 | 确认在 root（su）下运行；KSU 给 shell 授权 |
| 切换后仍进原系统 | 运行 `su -c piano-switch` 看 Current/Active slot 是否已变；若 GPT 变了但启动未变，检查是否 OTA 刚覆盖过 boot_b/dtbo_b |
