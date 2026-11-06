# TU102-1E07 — RTX 2080 Ti 22G Rev.A (10de:1e07) UEFI 解锁移植

从 `tu102-22g-uefi-unlock`（T1.5，10de:1e04）移植到本机 Rev.A 卡。
漏洞链（V67 canary → FECS PLM → SS0/SS1）与上游完全一致，只改身份/几何常量。

## 产物（2026-11-01 构建，OVMF 冒烟通过）

| 文件 | sha256 | 用途 |
|---|---|---|
| `TU102-1E07.EFI` | `02a1091319…dd9a7bb5` | 解锁版（经 GRUB chainloader 执行后返回 GRUB） |
| `TU102DUMP.EFI` | `b0c9969e0…46517ed4` | 只读诊断版（寄存器预检 + PROM 窗口转储，不写卡） |

含 NVIDIA 固件，**不入库不分发**。

## 本机目标

| 项 | 值 |
|---|---|
| GPU | RTX 2080 Ti 22G mod Rev.A, `10de:1e07`, subsystem `7377:1401` (Colorful) |
| VBIOS | `90.02.17.00.61`（TU102.rom，GPU-Z 导出） |
| 主板 | GA-B75M-D2V (F4)，UEFI only / CSM=Never / VT-d on / **无 Above 4G** |
| CPU/RAM | Xeon E3-1230 V2 / 16 GB |

## 与 1e04 移植的差异（全部）

1. `U40X_TARGET_DID` 0x1E04 → **0x1E07**
2. FW50 几何 → 本机 ROM 实测（见下表）
3. `returnToGrub` 默认 **TRUE**（GRUB chainloader 不传 LoadOptions；原逻辑
   会走内置 OS 链载梯子而非回 GRUB）。`--chainload-os` 可选恢复旧行为。
4. 默认 **rebar 尝试禁用**（B75 无 Above 4G；`rebar=try` 可选启用）
5. FWSEC 期望哈希 → `584b5fe0…`（39440 B）

### FWSEC 几何对比

| 常量 | 1e04 Leadtek (c6fa28fa) | **1e07 本机 (584b5fe0)** | CMP 50HX (d8981d40) |
|---|---|---|---|
| IMEM load | 0x9800 | **0x9600** | 0x9A00 |
| SEC base / size | 0x400 / 0x9400 | **0x300 / 0x9300** | 0x400 / 0x9600 |
| DMEM off / size | 0x9800 / 0x420 | **0x9600 / 0x410** | 0x9A00 / 0x3F0 |
| blob | 39968 B | **39440 B** | 40432 B |
| iface / mapper / cmd_in | 0xE0 / 0x390 / 0x3E0 | **0xDC / 0x380 / 0x3D0** | 0xE0 / 0x360 / 0x3B0 |

39440 B 与 KohakUnlock 记载的 ASUS 发布版 TU102 FWSEC 尺寸族吻合；
`rom_analyze.py` 结构校验通过（DMAP v3 签名、mapper/command 边界合法）。
capacity 守卫 0x100ce0==0x2c9 不变（编码 VRAM 布局而非 DID，两卡同值）。

## 输入 blobs

- 四个 TU102 CMP blob：本地 `../part/cmp50hx-unlock/efi-unlock/blobs/`
  （sha256 与 cmp50hx-unlock@df2fe11 一致，已核，无需联网）
- `blobs/fwsec_native.bin`：本机 FWSEC。注意 GPU-Z 的 TU102.rom 前部是
  NVGF 容器，PCI 链实际从 0x28600 开始：
  ```bash
  dd if=../TU102.rom of=/tmp/chain.bin bs=1 skip=$((0x28600)) count=$((0x20200))
  python3 extract_fwsec.py /tmp/chain.bin blobs/
  mv blobs/fwsec_50hx_prod.bin blobs/fwsec_native.bin   # 584b5fe0… 39440B
  ```

## 构建（Arch：pacman -S gnu-efi）

```bash
bash build.sh              # -> TU102-1E07.EFI
DUMP_ONLY=1 bash build.sh  # -> TU102DUMP.EFI
bash qemu-test.sh          # OVMF 冒烟（无需 GPU）
```

Arch binutils 无 `efi-app-x86_64`；build.sh 用 `pei-x86-64` 转换后补
PE 头字段（Subsystem=10、SizeOfImage/Headers、对齐），OVMF 实测加载通过。

## 使用（GRUB → 解锁 → 回 GRUB → 手动选系统）

EFI 放 ESP，如 `(hd0,gpt1)/EFI/tu102/TU102-1E07.EFI`。

GRUB 菜单 `c` 进命令行：
```
insmod part_gpt
insmod chain
chainloader (hd0,gpt1)/EFI/tu102/TU102-1E07.EFI
boot
```
执行完自动**返回 GRUB 命令行**（EFI_SUCCESS），随后：
- 回菜单：`normal`，或
- 直接引导：`chainloader (hd0,gpt1)/EFI/Microsoft/Boot/bootmgfw.efi` + `boot`
  （Linux：`linux /vmlinuz... root=...` 那套）

日志写在 EFI 所在分区根 `\50hx_log.txt`。

**Windows 前置（一次性）**：设备键
`HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-...}\<NN>` 加
`EnableGpuFirmware=1` (DWORD)，让驱动走 GSP-RM 接受 pre-OS 解锁态。
Linux：NVIDIA open 驱动（本机 615.78.08）直接接受。

### 成功判据（\50hx_log.txt 末尾）

```
[TU102] capacity=0x2c9 OK (22GiB identity confirmed)
fwsec50: *** WPR2 UP lo=0x057fe000 hi=0x057fee00 ***
tu102:   m0=0x0 m1=0x1                        ← booter OK（0x91 = 失败）
tu102: RESULT: PLM=0xffffff8f SS0=0x88888888 SS1=0x00000008
[50HX] *** UNLOCKED (SS0=0x88888888 SS1=0x8) ***
[rebar] skipped (no rebar=try; host lacks Above-4G)
[50HX] returning to GRUB; it may now start the OS loader
```
注意：booter 成功后 WPR2 回落 `0x1ffffe00` 是预期终态（与 KohakUnlock
tx_run 的 TX_VERIFY 期望一致），不代表 FWSEC 白做。

## 实测（2026-11-01，本机，bench_gemm.py）

| 场景 | FP16 2048³ | FP16 3072³ | FP16 4096³ | FP32 对照 |
|---|---:|---:|---:|---:|
| 解锁（Linux，n=2） | 59.9 / 63.0 | 66.6 / 67.6 | 78.6 / 79.3 | 10.7 / 12.0 |
| 解锁（Windows，n=1） | 73.0 | 70.2 | 79.7 | 10.7 |
| **锁定基线**（Linux，n=1，热重启不跑 EFI） | **36.3** | **37.5** | **42.7** | 13.9 |

- 解锁/锁定比 1.75–1.88×，与 1e04 卡 +51~75%、KohakUnlock +53~85% 形态一致
- FP32 对照持平
- 热重启矩阵（同日连续 warm reboot，无断电）：Linux→Linux 基线、
  Win(GPU-Z 1min 满载)→解锁→Win、解锁→Linux、Win→解锁→Linux；
  reset-first 构建 4/4 成功；修复前 no-reset 构建在 Windows 热重启
  路径 1/1 失败（0x91）
- Windows 侧 `EnableGpuFirmware=1` 已确认开启并保持（Windows 解锁实测
  达标即在该配置下取得；未做关闭该值的 A/B，保留现状）

## Warm reboot（必要需求，为何满足）

每次引导完整重跑漏洞链，不依赖上次残留态：
1. 找卡（DID=1e07）→ BAR0 → 守卫（capacity==0x2c9）
2. `detect_fb_size` 读**本次** VBIOS POST latch 的 WPR2 → 定 fbSize/FRTS
   （warm reboot 后 VBIOS 重新 POST，WPR2 重新 latch，均被读到）
3. GFW kill 后 WPR2 若掉 → `[8b]` 用**本机 FWSEC+几何**重拉 WPR2
4. SEC2 booter → V67 canary → SS0/SS1 写满速 → sanitize
5. 返回 GRUB（无二次 POST、不回 BDS）

热重启验证流程：
1. 解锁 → 进系统 → bench 确认提速
2. 系统内 `reboot`（warm）→ GRUB → 再跑一次 chainloader → 进系统
3. 第二次 bench 仍提速 = warm-reboot 解锁有效
（对照：完全断电后直接进系统 = 上次解锁态已清，bench 应回基线）

## 风险与已验证边界

- **已实机验证**（本机，reset-first 构建后）：Linux/Windows 双向热重启
  解锁 4/4（含一次 Windows GPU-Z 满载初始化后热重启），bench 1.6–1.9×，
  无 error 43 / no device
- 修复前 no-reset 构建曾在 Windows→热重启→解锁 路径 1/1 触发 booter
  0x91 + SEC2 寄存器块尸体化（黑屏，断电恢复）；根因与修复见上文
  reset-first 注释。0x91 若复现：断电冷启动一次即恢复，勿连续重试
- 若 `[8b]` FWSEC 拉不起 WPR2（日志 `WPR2 NOT up`）即几何不匹配，停手
- 长稳（连续数小时烤机级）未做；功耗墙不变，注意散热；仅限自有硬件

## 溯源

- 漏洞链/加载器: xrip/cmp50hx-unlock @ df2fe11 ← PZH1gdmu/CMP40HX-Unlock (MIT)
- 1e04 移植与 22G 几何参照: tu102-22g-uefi-unlock (MIT, 本工作区)
- 22G 布局/实测参照: KohakuBlueleaf/KohakUnlock (GPL-2.0, 文档参考)
