# Erya FNet3399 设备适配（RK3399）

QuartzWrt 首个 ARM 设备适配。目标：`rockchip/armv8`，设备 ID `erya_fnet-3399`，
产物 `immortalwrt-rockchip-armv8-erya_fnet-3399-squashfs-sysupgrade.img.gz`。

## 硬件概况

- SoC：Rockchip RK3399（双核 A72 + 四核 A53），LPDDR4
- 有线：GMAC 千兆（RGMII，外置 125MHz 时钟）；USB 3.0 口可接 RTL8152/8153 USB 网卡
- 存储：eMMC（sdhci，8-bit HS400）+ SD
- 其他：PWM 风扇（pwm-fan）、蓝色心跳 LED、电源键/Recovery 键（ADC）、
  PWM 背光 + SPI 小屏（dts 中默认 disabled）、PCIe x2、两个 USB3（均 host 模式）、
  `rfkill-modem` 节点（5G/4G 模组供电与复位控制）
- 串口：UART2 @ 1500000n8

## 素材来源与投放位置

素材为 vendor 适配包（`Fnet资料`，2026-10-14 由 `E:\Downloads\123pan\Fnet资料` 拷入本机
`~/fnet/Fnet资料`），按 `immortalwrt适配过程/` 说明落地为：

| 素材 | 落地位置（本目录内） |
| :--- | :--- |
| `rk3399-fnet-3399.dts`（内核 DTS） | `files/target/linux/rockchip/files/arch/arm64/boot/dts/rockchip/` |
| `rk3399-fnet-3399.dts`（U-Boot DTS） | `files/package/boot/uboot-rockchip/src/arch/arm/dts/` |
| `rk3399-fnet-3399-u-boot.dtsi` | 同上 |
| `fnet3399-rk3399_defconfig` | `files/package/boot/uboot-rockchip/src/configs/` |
| 「修改文件1」U-Boot 目标注册 | `patches/0001-uboot-rockchip-add-fnet3399-target.patch` |
| 「修改文件2」设备定义 | `patches/0002-rockchip-armv8-add-erya-fnet3399-device.patch` |

机制说明（经锁定基座源码核实，见 WORKPLAN 坑位 #42）：

- 内核 dtb 由 `include/image.mk` 的 `Device/Build/dtb` 直接编译
  `$(LINUX_DIR)/arch/arm64/boot/dts/rockchip/rk3399-fnet-3399.dts`（`DEVICE_DTS` 指定），
  **无需**给内核 dts Makefile 打补丁；
- U-Boot 的 `src/` 目录由 `include/package-defaults.mk` 整树拷入构建目录
  （`[ ! -d ./src/ ] || $(CP) ./src/. $(PKG_BUILD_DIR)`），dts/defconfig 原样投放即可；
- U-Boot 变体名 `fnet3399-rk3399` 必须与设备定义 `UBOOT_DEVICE_NAME` 一致
  （`pine64-bin` 镜像流程按此名从 `STAGING_DIR_IMAGE` 取 `-uboot.img`）；
- `CONFIG_TPL=y` + `UBOOT_USE_BINMAN` 与 guangmiao/r4se 等既有 rk3399 板同款流程。

## 构建

```bash
# 本地（产物落 artifacts-local/erya_fnet-3399/）
scripts/build-local.sh --device erya_fnet-3399

# CI：workflow_dispatch 填 device = erya_fnet-3399
```

目标切换自动处理：脚本以 `$WORK_DIR/.quartz-target` 记录上次目标，
x86_64 ↔ 本设备 之间切换时自动 `make dirclean`（防止 staging_dir 混用）。

## 分区尺寸

按 vendor 成品镜像（ImmortalWrt SNAPSHOT r34836）实测分区表对齐：
boot 32 MiB（`CONFIG_TARGET_KERNEL_PARTSIZE=32`）+ rootfs 1000 MiB
（`CONFIG_TARGET_ROOTFS_PARTSIZE=1000`）；基座 rockchip 默认（16/160）不适用本设备。
vendor 镜像同一参数组合已用基座 `ptgen` 复现（偏移/尺寸逐字节一致），见坑位 #42。

## 5G 模组支持（vendor 建议）

vendor 说明「建议使用 qmodem」。qmodem（`luci-app-qmodem` 及 sms/ttl 子包）**不在**
ImmortalWrt 官方 feed 与本项目双 Feed 中，vendor 成品镜像是从其自备 feed 装入的。
当前适配**不预装** qmodem；如需 5G 模组管理能力，纳入 WP-7（ThirdParty 扩包）评估
后再随镜像投放（qmodem 上游为第三方仓库，需按 TDD §6 准入清单评估并锁版本）。

## 构建验证（2026-10-14 本地全量构建）

- **构建**：`scripts/build-local.sh --device erya_fnet-3399` 全绿（EXIT=0：公共 manifest 断言 + 设备断言 + 成品镜像存在性全过）。
- **镜像结构核验**（与 vendor 成品 `immortalwrt-rockchip-armv8-erya_fnet-3399-squashfs-sysupgrade.img.gz` 逐项对照）：
  - 镜像总大小逐字节一致（1149239296 B）；分区表完全一致（boot 32 MiB @ 扇区 65536 + rootfs 1000 MiB @ 扇区 196608，含 bootable 标志）；
  - 引导链三件套按扇区逐字节一致：idbloader（扇区 64）、`uboot.img`（扇区 0x4000，`LOADER` 头）、`trust.bin`（扇区 24576，`BL3X` 头）；
  - FIT 内核（boot 分区 `kernel.img`）内嵌 `rk3399-fnet-3399` DTB（compatible `erya,fnet-3399`，load 0x03200000）；
  - fwtool 尾标元数据 `supported_devices: ["erya,fnet-3399"]`（设备上 sysupgrade 接受本镜像的依据）；
  - rootfs（squashfs）含 quartz 全家桶（`quartz-defaults`/theme/dashboard/quartz-config/daemon/app-api/openclash）+ 设备包（`kmod-usb-net-rtl8152`、`pwm-fan.ko`）+ `/etc/quartz-release`。
- **核验手法**（可复跑）：`sfdisk -d`（分区表）；`dd` 取扇区 64/0x4000/24576 十六进制对照；`dd` 取 boot 分区 + `debugfs -R "dump /kernel.img"` + `dumpimage -l`（FIT 内容）；`unsquashfs -o 100663296`（rootfs）。
- **注**：`kmod-rfkill`（vendor 配方 `DEVICE_PACKAGES` 成员）在 rockchip 因 `CONFIG_RFKILL`/`RFKILL_GPIO` 内核内建而**不可选**、被静默丢弃——功能无缺失（rfkill-gpio 驱动内建，`rfkill-modem` 节点可绑），vendor 成品镜像同样无此包；故 manifest 断言不列它（见 `device.env` 注释）。

## 已知边界

- SPI 小屏（st7735r）与 PWM 背光在 dts 中默认 `disabled`，未纳入 v1 验收；
- 无线：本机 dts 无 SDIO/PCIe 无线节点（FNet3399 本体不带无线；如需 USB/PCIe 网卡另装）；
- 设备实机验收（刷写 + 首启 + LuCI/App 链路）待用户在真机执行——本地只做构建级验证。
