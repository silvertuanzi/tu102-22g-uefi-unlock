# 1e07 Rev.A port — 变更记录

本目录是本仓库 `efi-unlock-tu102/`（10de:1e04 移植）向 **RTX 2080 Ti 22G
Rev.A 改装卡（`10de:1e07`，Colorful `7377:1401`，VBIOS 90.02.17.00.61）**
的二次移植。漏洞链（V67 canary → FWSEC → SEC2 booter → SS0/SS1）不变，
全部差异如下。

## A. 身份与固件几何（来源：本机 GPU-Z ROM + EFI 运行时 PROM 窗口，双解析器交叉验证）

| 常量 | 1e04 (c6fa28fa) | 1e07 (584b5fe0) |
|---|---|---|
| `U40X_TARGET_DID` | 0x1E04 | **0x1E07** |
| FWSEC IMEM/secBase/secSize | 0x9800/0x400/0x9400 | **0x9600/0x300/0x9300** |
| FWSEC DMEM off/size, blob | 0x9800/0x420, 39968B | **0x9600/0x410, 39440B** |
| iface/mapper/cmd_in | 0xE0/0x390/0x3E0 | **0xDC/0x380/0x3D0** |

本机 FWSEC 提取时注意：GPU-Z 导出的 TU102.rom 前部是 NVGF 容器头，
PCI 链实际从 0x28600 开始（`dd skip=0x28600 count=0x20200` 后再跑
extract_fwsec.py）。39440B 与 KohakUnlock 记载的 ASUS 发布版 TU102
FWSEC 尺寸族吻合。capacity 守卫 0x100ce0==0x2c9 两卡同值（编码 VRAM
布局而非 DID），不变。

## B. booter 启动顺序修复（实机踩坑，行为级）

上游 `booter_load_tu102_direct` 先试 no-reset（TU106 CMP40HS driver-flow
结论）再兜底 reset。在本 1e07 卡上（Windows 会话热重启路径 1/1 复现）：
no-reset 启动 → booter 验签通过但退出 **m0=0x91** → SEC2 寄存器块
尸体化（后续 port 写全部读回 dead5ec1/e c2，engine reset 不可恢复），
即上游 v2.69 注释记载的 corpse 效应。

修复：**reset-first 单次尝试**（原 attempt B 的 reset 体），删除重试与
GA102 DMA 兜底（0x91 后再跑只加重污染）。该顺序与 KohakUnlock 硬件
验证成功的 TU102 22G 序列（kernel/tu102_core_port.h `tx_run`：booter
前 `tx_reset(SEC2)`）一致。修复后实测 4/4（含 Windows GPU-Z 满载初始
化后热重启路径），0x91 未复现。

## C. 运行形态（宿主为 GRUB，非 Windows Boot Manager 直载）

1. `returnToGrub` 默认 **TRUE**：GRUB `chainloader` 不传 LoadOptions，
   原逻辑会走内置 OS 链载梯子而非返回 GRUB。`--chainload-os` 恢复旧行为
2. 默认 rebar 尝试**禁用**（宿主 B75M-D2V 无 Above 4G Decoding；
   `rebar=try` 可选启用）。主漏洞链不依赖 Above 4G：>4GB 缓冲走
   `AllocatePages`（RAM 页分配，与 PCIe MMIO 窗口无关）
3. `VBIOS_DUMP` 关闭：运行时 `\50hx_vbios.bin` 快照是只写诊断，
   漏洞链不回读；本卡 PROM 已捕获并验证

## D. 构建适配（Arch Linux）

- gnu-efi 头在 `/usr/include/efi`（非 Debian 路径）
- Arch binutils 无 `efi-app-x86-64` BFD target → `pei-x86-64` 转换后
  补 PE 头字段（Subsystem=10、SizeOfHeaders/Image、SectionAlignment）
- 四个 TU102 blob 哈希与 1e04 相同（cmp50hx-unlock@df2fe11）；
  `fwsec_native.bin` 期望 584b5fe0…（39440B）
- `qemu-test.sh` 用 MBR 分区 FAT 镜像 + OVMF.4m.fd（superfloppy 盘
  OVMF 不枚举）

## E. 实测（2026-11-01~06，bench/bench_gemm.py，TFLOPS）

| 场景 | FP16 2048³ | 3072³ | 4096³ | FP32 对照 |
|---|---:|---:|---:|---:|
| 解锁 Linux（n=4） | 58.9–63.7 | 66.6–67.8 | 77.5–79.3 | 10.7–13.9 |
| 解锁 Windows（n=2） | 70.3–73.0 | 70.2 | 78.8–79.7 | 10.7 |
| 锁定基线（Linux，热重启不跑 EFI） | 36.3 | 37.5 | 42.7 | 13.9 |

解锁/锁定 1.75–1.88×。热重启矩阵（连续 warm reboot 无断电）：
Linux↔Windows 双向、Windows 满载初始化后、5 天 5 轮全部成功。
