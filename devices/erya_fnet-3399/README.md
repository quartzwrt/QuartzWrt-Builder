# Erya FNet3399 设备适配（RK3399）

QuartzWrt 首个 ARM 设备适配。目标：`rockchip/armv8`，设备 ID `erya_fnet-3399`，
产物 `immortalwrt-rockchip-armv8-erya_fnet-3399-squashfs-sysupgrade.img.gz`。

## 硬件概况

- 组成：**SW799 核心板**（RK3399 + LPDDR4 + eMMC + 板载 AP6236 无线/蓝牙）**+ 专用底板**
  （同一核心板的另一种底板机型为 Fine3399，非本项目目标）
- SoC：Rockchip RK3399（双核 A72 + 四核 A53），LPDDR4
- 无线：核心板板载 Ampak **AP6236**（芯片识别 BCM43430B0，2.4GHz 802.11n + BT combo），
  接口 SDIO0 + UART0（详见「无线与蓝牙」一节；厂商原版 DTS 未启用，本设备层补齐）
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
| 无线/蓝牙增补（非厂商素材，2026-10-15 追加） | `files/…/rk3399-fnet-3399-ap6236.dtsi` + `files/package/firmware/brcmfmac-firmware-fnet3399/` |

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

## 无线与蓝牙（AP6236 / BCM43430B0）

无线/蓝牙在 **SW799 核心板**上（Ampak AP6236，芯片识别为 BCM43430B0；2.4GHz 802.11n 1x1 +
BT combo）。厂商随附的内核 DTS 只覆盖有线/存储/5G 部分、未启用无线，本设备层按公开布线
资料补齐（2026-10-15，属设备适配层自有内容，非厂商素材）：

| 组成 | 落地位置 |
| :--- | :--- |
| 设备树增补（SDIO0 无线 + UART0 蓝牙 + 电源时序/引脚） | `files/target/linux/rockchip/files/arch/arm64/boot/dts/rockchip/rk3399-fnet-3399-ap6236.dtsi`（由厂商 DTS 末尾 `#include` 引入，厂商 DTS 其余内容不变） |
| 固件包 `brcmfmac-firmware-fnet3399`（bin/NVRAM/HCD/CLM + 许可 + NOTICE） | `files/package/firmware/brcmfmac-firmware-fnet3399/`（apply-device 投放进基座 `package/firmware/`，仅本设备构建可见） |
| 内核模块与用户态选包 | `seed.config` 末段「WP-11 追加」块 |

**布线依据**（四份独立来源逐字段一致，其中最后一份为 FNet3399 专用移植、可作对照基线）：

- `cm9vdA/build-linux`：`boot/dts/rockchip/{mainline,bsp}/rk3399-fine3399.dts`
- `unifreq/linux-6.6.y`：`arch/arm64/boot/dts/rockchip/rk3399-bozz-sw799.dts`
- `armbian/build`：`patch/kernel/archive/rockchip64-6.18/dt/rk3399-fine3399.dts`
- `Lemon1151/iStoreOS-RK3399`：`fnet3399/kernel-rockchip/patches/993-…-kernel.patch`
  （model/compatible 与厂商 DTS 完全一致：`erya,fnet-3399`）

要点：

- **WiFi**：SDIO0（`non-removable`；WL_REG_ON = gpio0 PB2，host-wake = gpio0 PA3，
  32.768kHz 取 RK808 CLKOUT），驱动 `kmod-brcmfmac`（SDIO）+ 固件
  `brcmfmac43430b0-sdio.{bin,txt}`（内核 `sdio.c` 固件名表：43430 rev≥2 → 43430B0）。
  内核以根 compatible 首串为 board_type，优先找板级 NVRAM，故包内同时投放
  `brcmfmac43430b0-sdio.erya,fnet-3399.txt`。
- **蓝牙**：UART0（本板控制台为 uart2，不冲突；BT_REG_ON = gpio0 PB1、host-wake =
  gpio0 PA4、device-wake = gpio2 PD2），内核侧栈 `kmod-bluetooth` + `kmod-hci-uart`
  + `kmod-btbcm` + HCD 固件 `BCM43430B0.hcd`（btbcm subver 0x410c → `BCM43430B0`）。
  **用户态 bluez 不在基座与双 Feed**：需要实际配对/使用时可从上游 packages feed 自取
  （`bluez-daemon`/`bluez-utils`），本设备层不预装。
- **用户态 WiFi**：`wpad-openssl`（与基座 rockchip 既有无线设备配方同款）+ `wifi-scripts`
  + `wireless-regdb`；LuCI 无线页由既有 luci 栈提供。
- 复核勿误判：CLM blob 沿用厂商旧名 `brcmfmac43430-sdio.clm_blob`，当前内核查找名是
  `…43430b0-sdio.clm_blob` → 该文件不会加载（CLM 为可选件，缺失非致命）；**不要改名**，
  CLM 下载失败在 brcmfmac 中是致命错误（`common.c` → preinit 失败即无线起不来）。
  完整 md5 清单、板级 NVRAM 固定 MAC 事项见该包 `NOTICE.md`。
- 真机状态以 `dmesg | grep -iE "brcmfmac|Bluetooth|hci"` 为准；若首启无线未自动拉起，
  参考移植（iStoreOS fnet3399）在板级脚本里做了「延迟 60s 再 `wifi up`」，真机验收时
  优先复现该现象（`wifi up` 手动可起即属该时序问题，非驱动缺失）。

## 5G 模组支持（vendor 建议）

vendor 说明「建议使用 qmodem」。qmodem **不在** ImmortalWrt 官方 feed 中，由 vendor 自备
feed 装入其成品镜像。**现状（2026-10-16 起）**：已按 TDD §6 准入清单评估并收录进 thirdparty
feed，且在设备预装层预装（`luci-app-qmodem-next` + Vendor QMI 驱动切换，见
`preinstall.config` 与 `config/common.config` 的 `qmodem_INCLUDE_*`）；真机 5G 模组识别
待复核。本节保留 vendor 建议的原始记录。

## PWM 风扇控制（2026-10-16）

- **硬件与驱动链**：风扇接 `&pwm1`（周期 10000ns，vendor DTS 原样）；DTS 节点 `fan: pwm-fan`
  含 `#cooling-cells`、**无** `cooling-levels`、**无**风扇冷却映射 → 内核 `pwm-fan`
  （`kmod-hwmon-pwmfan`，hwmon 设备名 `pwmfan`）+ RK3399 TSADC 热区（`cpu_thermal`/
  `gpu_thermal`，`CONFIG_ROCKCHIP_THERMAL=y` 内建）；热区冷却映射只绑 CPU/GPU，**内核对
  风扇零干预**。
- **控制方案（用户态单写者）**：`fancontrol` 守护进程（thirdparty feed，上游
  JiaY-shi 2.x，锁 tag `v2.1.0`）按温度曲线连续调 `pwm1`；LuCI 页「服务 → Fan Control」
  （`luci-app-fancontrol`，含实时状态/趋势图，zh-cn 随镜像）。
- **设备默认曲线**（`files/target/linux/rockchip/base-files/etc/uci-defaults/99-fancontrol-fnet3399`）：
  `enabled=1`、`start_temp=45`、`full_speed_temp=75`——75°C 与 cpu_thermal 首级被动降频
  （70/75°C）对齐，上游默认 85°C 偏高（届时时 SoC 已降频）；其余走上游默认（start_speed 64 /
  hysteresis 3 / kick 255@500ms 启动助推 / fail_safe 255 全速保护 / interval 5）。
  `thermal_zone`/`fan_file` 保持 `auto` 自动发现——**不硬编码 hwmon 序号**（随加载模块变化；
  vendor 旧版即硬编码 `hwmon2`）。
- **已知行为**：`pwm-fan` 驱动 probe 时**无条件把 PWM 置最大**（vendor DTS 的
  `rockchip,initial-pwm=0` 是其内核补丁属性，本内核不识别、被忽略）→ **开机至 fancontrol
  启动前风扇全速**属预期；服务被停用也保持全速（散热安全侧——用户态是唯一调速者）。
- **镜像内容**：`fancontrol` + `luci-app-fancontrol` + `luci-i18n-fancontrol-zh-cn`
  随设备镜像预装（`preinstall.config`），包本体来自 thirdparty feed 镜像
  （`QuartzWrt-ThirdParty/utils/fancontrol/`，台账 FORKS.md）。
- **真机验证（2026-10-16，真机 192.168.1.1 = 10-16 验证构建）**：
  - 现场核对：`hwmon0=cpu_thermal / hwmon1=gpu_thermal / hwmon2=pwmfan`、
    `thermal_zone0=cpu-thermal`、`pwm1_enable` 存在；**未装服务时 `pwm1=255`（风扇全速）**
    ——实证驱动 probe 无条件置最大（vendor 的 `rockchip,initial-pwm` 在本内核不生效）。
  - 三个 apk 热装（`--allow-untrusted`）→ `auto` 发现命中（日志：`using temperature input
    /sys/class/thermal/thermal_zone0/temp and PWM output /sys/class/hwmon/hwmon2/pwm1`）。
  - 曲线实测（同源 `src/fancontrol.c` 宿主 gcc 编译 + 伪 sysfs 逐点）：45°C→64、
    50°C→95、60°C→159、70°C→223、75°C→255、≥75°C 钳位 255、<40°C→0，线性插值逐点吻合。
  - **温度闭环**：风扇全速时 cpu 38.1°C；置 0 后空载 4 分钟 38.1→41.1°C 仍在上升
    （均衡 ~42-46°C）→ 服务启用本曲线后**稳定 42.8-43.3°C @ PWM 57-60（22-23%）**，
    关扇爬升趋势被压平、且远低于 70°C 被动降频阈值。
  - LuCI 页面（服务 → Fan Control）：状态卡实时值（温度/PWM/解析路径/Fault: None）、
    设置页三页签与 40/75/3 回显、双模渲染均正常；`fs.read_direct` 走 cgi-io
    （词法规范化、**不解析符号链接**）+ 基座 `luci-mod-system` 的 `cgi-io:download`
    授权 → 状态文件读取 200（无坑位 #25/#30 类 realpath 陷阱）；`session access
    uci fancontrol → true`、`service list fancontrol → running:true`。
  - 证据：`dev/shots/fancontrol/`（双模截图 ×4 + 页面文本 + `device-run-20261016.log`
    含 uci/status/procd 与 3 分钟采样）。
  - **说明**：真机上是热装 + 手工写入 uci（与 uci-defaults 同值）；首启由
    uci-defaults 自动落同一组值的路径由镜像级核验覆盖（见上方"构建验证"轮次）。

## 构建验证（2026-10-14 本地全量构建）

- **构建**：`scripts/build-local.sh --device erya_fnet-3399` 全绿（EXIT=0：公共 manifest 断言 + 设备断言 + 成品镜像存在性全过）。
- **镜像结构核验**（与 vendor 成品 `immortalwrt-rockchip-armv8-erya_fnet-3399-squashfs-sysupgrade.img.gz` 逐项对照）：
  - 镜像总大小逐字节一致（1149239296 B）；分区表完全一致（boot 32 MiB @ 扇区 65536 + rootfs 1000 MiB @ 扇区 196608，含 bootable 标志）；
  - 引导链：idbloader（扇区 64）与 `trust.bin`（扇区 24576，`BL3X` 头）按扇区与 vendor 逐字节一致；
    `uboot.img`（扇区 0x4000，`LOADER` 头）**与 vendor 不同**——vendor 镜像用的是其自带旧基座
    U-Boot（`2025.04-ImmortalWrt-r34695`），本项目用锁定基座的 `2025.10-ImmortalWrt-r0+38247-ce35a9e4ef`
    （2026-10-15 复核更正：本轮同时确认**本设备前后两次自建镜像的 `uboot.img` 逐字节一致**，
    即 U-Boot 链只随基座锁定版本变化、不受设备层改动影响）；
  - FIT 内核（boot 分区 `kernel.img`）内嵌 `rk3399-fnet-3399` DTB（compatible `erya,fnet-3399`，load 0x03200000）；
  - fwtool 尾标元数据 `supported_devices: ["erya,fnet-3399"]`（设备上 sysupgrade 接受本镜像的依据）；
  - rootfs（squashfs）含 quartz 全家桶（`quartz-defaults`/theme/dashboard/quartz-config/daemon/app-api/openclash）+ 设备包（`kmod-usb-net-rtl8152`、`pwm-fan.ko`）+ `/etc/quartz-release`。
- **核验手法**（可复跑）：`sfdisk -d`（分区表）；`dd` 取扇区 64/0x4000/24576 十六进制对照；`dd` 取 boot 分区 + `debugfs -R "dump /kernel.img"` + `dumpimage -l`（FIT 内容）；`unsquashfs -o 100663296`（rootfs）。
- **注**：`kmod-rfkill`（vendor 配方 `DEVICE_PACKAGES` 成员）在 rockchip 因 `CONFIG_RFKILL`/`RFKILL_GPIO` 内核内建而**不可选**、被静默丢弃——功能无缺失（rfkill-gpio 驱动内建，`rfkill-modem` 节点可绑），vendor 成品镜像同样无此包；故 manifest 断言不列它（见 `device.env` 注释）。

## 构建验证（2026-10-15 无线/蓝牙轮，本地全量构建）

- **构建**：`scripts/build-local.sh --device erya_fnet-3399` 全绿（manifest 公共断言 + 11 项设备断言
  + 镜像存在性 + 签名一致性 9/9）。
- **内核配置核对**：`CONFIG_BT=m` / `CONFIG_BT_BCM=m` / `CONFIG_BT_HCIUART=m` +
  `CONFIG_BT_HCIUART_BCM=y`（uart0 蓝牙协议绑定）；MMC 仍为内建 `CONFIG_MMC=y`
  （`kmod-mmc` 走"内建即空包"路径，eMMC 不受影响）。
- **镜像级核验**：
  - rootfs 含全部固件（`brcmfmac43430b0-sdio.bin`/`.txt`、板级 NVRAM、`BCM43430B0.hcd`、
    CLM blob、Broadcom 许可）与模块（`brcmfmac.ko`/`brcmutil.ko`/`cfg80211.ko`/`mac80211.ko`/
    `bluetooth.ko`/`btbcm.ko`/`hci_uart.ko`）；**五个固件文件与许可经 md5 与仓库源逐字节一致**；
  - FIT 内核内嵌 DTB 含 `wifi@1`（`brcm,bcm4329-fmac`）、`sdio-pwrseq`、UART0 `bluetooth`
    节点（`brcm,bcm43438-bt`）与 `mmc1 = &sdio0` 别名；
  - 引导链：idbloader/`trust.bin` 与 vendor 逐字节一致；`uboot.img` 与 self 上一轮一致、
    与 vendor 因基座 U-Boot 版本不同而不同（见上节「构建验证（2026-10-14）」更正项）。
- **真机验收（2026-10-15，用户实测）**：**WiFi 可用 ✅**——刷入含 AP6236 的 v0.1.1 镜像后
  无线工作正常（SDIO 枚举 + 固件加载 + 射频可用）。蓝牙（UART0 + `BCM43430B0.hcd`）与
  其余链路仍待复核；复核判据见上「无线与蓝牙」节（`dmesg | grep -iE "brcmfmac|Bluetooth"`，
  首启未起时参考移植 60s 后再 `wifi up`）。

## 已知边界

- SPI 小屏（st7735r）与 PWM 背光在 dts 中默认 `disabled`，未纳入 v1 验收；
- 无线：**核心板板载 AP6236 已启用并经真机验证（WiFi ✅ 2026-10-15；蓝牙待复核）**；
  底板自身无其他无线（USB/PCIe 网卡可另装）；
- 设备实机验收（刷写 + 首启 + LuCI/App 链路）待用户在真机执行——本地只做构建级验证。
