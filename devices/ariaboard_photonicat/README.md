# Ariaboard Photonicat（光影猫一代 / RK3568）

QuartzWrt 设备层。目标：`rockchip/armv8`，设备 ID `ariaboard_photonicat`，
产物 `immortalwrt-rockchip-armv8-ariaboard_photonicat-squashfs-sysupgrade.img.gz`。

> 二代是 `ariaboard_photonicat2`（RK3576，`kmod-photonicat-pm` 内核驱动），
> 与本目录不是同一套电源/电池方案，注意不要混用。

## 硬件概况

- SoC：Rockchip RK3568（4 核 ARM64）
- 内存/存储：2GB 或 4GB LPDDR4；16GB 或 64GB eMMC；MicroSD
- 有线：2× 1000Base-T（YT8521SC）
  - `eth0` = WAN（RGMII，gmac1）
  - `eth1` = LAN（SGMII，gmac0）
- 无线：QCA9377 SDIO Wi-Fi 5（2.4/5GHz）+ 蓝牙（UART1）
- 扩展：M.2 B-Key（USB，4G/5G 模组）、M.2 E-Key（PCIe/USB）
- 接口：HDMI、USB 3.0 Type-A、Type-C 供电、MicroSD
- 电池：7000mAh + 板载 PMU MCU（UART4）
- 调试串口：UART2，`1500000n8`

基座原生支持设备树、U-Boot `photonicat-rk3568`、网络/LED 初始化与 sysupgrade；
**本设备层不加厂商补丁**。

## 本设备层做什么

### 1. 目标与分区

`seed.config` 只固定目标/设备符号与分区尺寸：

```text
rockchip/armv8 + ariaboard_photonicat
KERNEL 32MiB / rootfs 2048MiB
```

### 2. 板载 WiFi：完全走官方默认

板载 QCA9377 使用基座 25.12 官方 `Device/ariaboard_photonicat` 的默认包：

- `kmod-ath10k-sdio`
- `ath10k-firmware-qca9377-sdio`（通用固件，含 `ath10k-board-qca9377-sdio`）
- `wpad-openssl` / `wifi-scripts` / `wireless-regdb`（公共功能层）

**不引入** Photonicat 专用 ath10k 固件，也不修改设备 profile。
`preinstall.config` 里显式锁定驱动/固件，只是为了让 Gate A 在基座 bump 后
profile 静默变化时直接报错。

### 3. 外接 USB/PCIe WiFi 网卡：保留公共驱动层

与 FNet3399 同口径，完整保留 `config/preinstall/drivers.config` 的加装网卡驱动：

- MediaTek mt76：mt7921e/u、mt7925e/u、mt7663u、mt7601u、mt76x0u、mt76x2u
- Realtek：rtw89（8852be/8852ce/8922ae）、rtw88、rtl8xxxu
- Intel：iwlwifi + AX200/AX201/AX210/BE200 固件
- Qualcomm：ath11k-pci / ath12k + WCN6855 / QCA2066 / WCN7850 固件
  （QCNFA765/NFA765 有 WCN6855 与 QCA2066 hw2.1 两种上报，固件都预装）
- AIC8800：USB / PCIe

本设备**不做** H5000M 那样的显式关闭；完整清单以公共层为准，设备层不重复抄包。
`device.env` 的 manifest 断言只取各驱动家族代表项做镜像级抽检。

### 4. 电池：pcat-mgr + FUSE + LuCI

- `pcat-mgr` 由基座 `DEVICE_PACKAGES` 带入，运行在 `/dev/ttyS4` 115200：
  - 启动时向 PMU MCU 发 `Watchdog(0)` 关闭板载看门狗
  - `TimeSync` 对时
  - 通过 go-fuse 把 `pcat-battery` / `pcat-charger` 挂到
    `/sys/class/power_supply/`（`luci-mod-battstatus` 的 rpcd 原生识别
    `board=ariaboard,photonicat`）
  - daemon 同步采集 `battery` 节（契约 §3.10），Dashboard 与 App 均显示电池卡；
    LuCI 另有状态栏电池指示
  - 充电器插拔、低电压自动关机、电源键关机事件
- 设备层显式选择 `kmod-fuse`（pcat-mgr → fuse-utils → libfuse → kmod-fuse）
  与 `luci-mod-battstatus` + `luci-i18n-battstatus-zh-cn`。
- `files/.../etc/uci-defaults/99-pcat-mgr`：
  - 启用 `/etc/init.d/pcat-mgr`
  - 首次启动写入 `/etc/pcat-mgr.json`，OCV 表取自基座 DTS
    （4100/4040/3980/3920/3870/3820/3790/3770/3740/3680/3450 mV）
  - `AutoShutdownVoltage` 不写，沿用 pcat-mgr 默认 3200mV；需要更保守可按
    DTS `voltage-min-design`（3400mV）调高
- `files/.../lib/upgrade/keep.d/pcat-mgr`：sysupgrade 时保留
  `/etc/pcat-mgr.json`，避免用户调整被冲掉。

> `pcat-mgr` 必须能启动；若 FUSE 不可用或服务未运行，板载 MCU 看门狗可能
> 在约 60 秒后复位整机。排查顺序：`/etc/init.d/pcat-mgr status` →
> `logread | grep pcat` → `ls /sys/class/power_supply/` → `lsmod | grep fuse`。

### 5. 5G：qmodem

按 FNet3399/H5000M 同款口径预装 `luci-app-qmodem-next`，由它带出
`qmodem` / `qmodem-smsd` / `sms-forwarder-next`；驱动/支持项沿用公共层
`config/common.config` 的 `qmodem_INCLUDE_*`（Vendor QMI + PCIe + MTK-T7XX +
Qfirehose）。M.2 B-Key 为 USB 通道，qmodem 的 `qmodem_init` / `modem_scan`
会自动建 section；B-Key 的 `rfkill-modem` 节点由基座 DTS 提供。

基座 profile 自带的 `kmod-usb-net-cdc-mbim` / `kmod-usb-net-qmi-wwan` /
`kmod-usb-serial-option` / `uqmi` 保留，不影响 qmodem。

## 未包含

- **QCA9377 蓝牙**：基座未开 `CONFIG_BT_HCIUART_QCA`，也没有打包 QCA UART
  蓝牙驱动/固件；默认镜像不要期待蓝牙可用。

## 构建

```bash
scripts/build-local.sh --device ariaboard_photonicat
# 只出标准版：
scripts/build-local.sh --device ariaboard_photonicat --variants std
```

产物：

```text
artifacts-local/ariaboard_photonicat/
  immortalwrt-rockchip-armv8-ariaboard_photonicat-squashfs-sysupgrade.img.gz
```

## 刷机与首启检查

镜像为整盘镜像（含 U-Boot/分区表），解压后 dd 到 MicroSD 或 eMMC：

```bash
gzip -dc ...img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress   # SD
gzip -dc ...img.gz | dd of=/dev/mmcblk0 bs=4M conv=fsync                    # eMMC
```

首启建议检查：

```bash
ip -br link
logread | grep -i pcat
/etc/init.d/pcat-mgr status
ls /sys/class/power_supply/
cat /sys/class/power_supply/pcat-battery/capacity
cat /sys/class/power_supply/pcat-charger/online
dmesg | grep -i ath10k
wifi status
```

`reload-sdio-wifi` 会在启动后延迟约 5 秒再 `modprobe ath10k_sdio` 并拉起 WiFi。
