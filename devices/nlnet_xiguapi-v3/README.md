# NLnet XiGuaPi V3（NL68K / 西瓜皮 V3）

QuartzWrt 设备层。目标：`rockchip/armv8`，设备 ID `nlnet_xiguapi-v3`，
产物 `immortalwrt-rockchip-armv8-nlnet_xiguapi-v3-squashfs-sysupgrade.img.gz`。

## 硬件概况

- SoC：Rockchip RK3568（4×Cortex-A55，Mali-G52，RK817-5 PMIC）
- 内存/存储：4GB LPDDR4X / 32GB eMMC（SanDisk SDINBDA4-32G）
- 有线：2× RTL8211F 千兆
  - 基座 `02_network` 初始化：`eth0` = LAN、`eth1` = WAN
- 扩展：
  - 2× mini-PCIe（PCIe WiFi；带 5V PA 供电）
  - 1× M.2 B Key（USB 5G，RM500Q 尺寸 52×30）
  - 1× M.2 E Key（PCIe WiFi + USB2 蓝牙，22×30）
- 其他：USB-A 3.0 OTG、HDMI 2.0、TF、SIM
- 屏幕：GC9307 SPI 320×240（FPC；**本版不启用**）
- 风扇：5V PWM（MX1.25 4pin；DTS 已带温控曲线，内核 thermal 自动调速）
- 按键/LED：ADC 复位键；`blue:status`（sys）、`blue:wan`（net）；第三 LED 未映射
- 调试串口：UART2，`1500000n8`

基座原生支持设备树、U-Boot `xiguapi-v3-rk3568`、网络/LED 初始化与 sysupgrade；
**本设备层不加厂商补丁**。

## 本设备层做什么

### 1. 目标与分区

`seed.config` 固定目标/设备符号与分区：

```text
rockchip/armv8 + nlnet_xiguapi-v3
KERNEL 32MiB / rootfs 8192MiB
CONFIG_KERNEL_RELAY=y
```

- `CONFIG_KERNEL_RELAY=y` 是 `kmod-mt7915e` 的前置内核符号（基座 rockchip
  默认关闭；不打开则驱动被 Kconfig 静默丢弃）。
- eMMC 32GB，rootfs 8192MiB 可容纳完整 Quartz 预装、WiFi 固件、Docker 与按需安装包
  （2026-11-23 用户拍板从 2G 扩到 8G）。

### 2. 预装（设备专用层）

- `luci-app-qmodem-next`：带出 qmodem / qmodem-smsd / sms-forwarder-next；
  驱动/支持项沿用 `config/common.config` 的 Vendor QMI + PCIe/MHI +
  MTK-T7XX + Qfirehose。USB M.2 B Key 与 mini-PCIe PCIe 适配器都覆盖。
- `kmod-mt7915e` + `kmod-mt7915-firmware` + `kmod-mt7916-firmware`：
  mini-PCIe MT7915/MT7916 WiFi 卡。
- 通用层已覆盖：mt7921e/u、mt7925e/u、rtw89/rtw88、iwlwifi、
  ath11k/ath12k、aic8800 等加装网卡驱动与固件；wpad-openssl /
  wifi-scripts / wireless-regdb；quartz-defaults、ttyd、btrfs 等。

**不预装**：fancontrol（内核 thermal 已自动调速）、蓝牙（kmod-btusb/固件）、
屏幕驱动、docker（软件源 `quartz-docker`）、usb-tether（软件源按需安装）。

### 3. ttyd 登录加固

`files/target/linux/rockchip/base-files/` 投放：

- `etc/uci-defaults/99-ttyd-quartz`：默认 `@lan`、`check_origin=1`、
  `max_clients=2`，`command` 改为 `/usr/bin/ttyd-login-check`。
- `usr/bin/ttyd-login-check`：root 密码未设置（空 / `!` / `*`）时拒绝进入，
  避免 LAN 上的免密 root shell。

### 4. WiFi 默认（CN + 5GHz）

`files/target/linux/rockchip/base-files/` 投放：

- `etc/uci-defaults/99-wireless-nl68k`（**不被 sysupgrade 配置备份保留**）：
  首启把 helper 调用**插到 `/etc/rc.local` 顶部**（在 base 的 `exit 0` 之前），
  并清掉旧 marker 行。r5 曾把调用追加在 `exit 0` 之后，导致永不执行。
- `usr/sbin/wireless-nl68k`（**不被配置备份保留**）：真正的修复逻辑。
  `/etc/init.d/done`（`START=95`）在启动最后执行 `sh /etc/rc.local`，此时
  `/etc/config/wireless` 已由 `/sbin/wifi config` 生成、network 已起来。
  - **仅当 `wireless.radio0.country` 为 `00` 或缺失时**：设 `country='CN'`；
    phy 支持 Band 2 时设 `band='5g'`、`channel='36'`、`htmode='HE80'`
    （非 HE 卡用 `VHT80`），然后 `wifi down; sleep 2; wifi up`。
    - 首启用 `wifi reload` 不够：hostapd 仍持旧 channel 状态，会报
      `IEEE 802.11 Hardware does not support configured channel` 并 AP-DISABLED；
      full down/up 才能重置 phy（r6 测试镜像踩过这个坑）。
  - 用户已选的国家（如 US/6GHz）不会被覆盖；6GHz 需允许 6GHz 的国家与客户端。
  - 首次修好后 `country=CN`，后续启动跳过。
- **不要直接把修复写进 `/etc/rc.local`**：`sysupgrade` 保留配置时会恢复旧的
  `/etc/rc.local`，覆盖新镜像里的版本（r4 测试镜像踩过这个坑）。

### 5. 无线页面显示网卡型号

QCNFA765/QCA2066 的 iwinfo 型号映射在 **Builder 通用层**，不在本设备层：

```text
config/patches/package/base-files/files/etc/uci-defaults/99-wifi-devices-name
```

首启检测到 PCI `17cb:1103` 时，向 `/usr/share/wifi_devices.json` 插入
`17cb:1103 / 17cb:3374` → `Qualcomm QCNFA765` 映射，iwinfo/LuCI 不再显示
`Generic MAC80211`。这是卡级映射，所有目标/设备只要有这张卡都会生效。

## 接口共存关系（n 选 m / 互斥）

**结论：没有 n 选 m；2× mini-PCIe + M.2 B Key + M.2 E Key 四个槽可以同时插满**
（逻辑通道层面）。真正共享的只有 PCIe 3.0 那组 2-lane PHY 的 1+1 拆分，
以及电源/散热预算。

| 控制器 | PHY | 板级用途（推断） | 复位 GPIO |
|---|---|---|---|
| `pcie2x1`（PCIe 2.0 x1） | `combphy2` | mini-PCIe 之一 | `gpio3_PC1` |
| `pcie3x1`（PCIe 3.0 x1） | `pcie30phy` lane1 | mini-PCIe 之一 | `gpio3_PA1` |
| `pcie3x2`（PCIe 3.0，x2 能力） | `pcie30phy` lane0 | M.2 E Key | `gpio2_PD6` |

- 三个控制器各自独立，DTS 全部 `status = "okay"`，可同时工作。
- `pcie3x1` 与 `pcie3x2` 共用 2-lane `pcie30phy`，板级为 **1+1 拆分**
  （各 `num-lanes=<1>`），同时使用时各跑 x1；若某卡强求 x2，必须空出另一个槽
  并改 DTS（WiFi 卡都是 x1）。
- 运行时用 `lspci -D` 的 PCI domain 区分：`0000`=`pcie2x1`、
  `0001`=`pcie3x1`、`0002`=`pcie3x2`。
- M.2 B Key 走 **USB，不占 PCIe lane**（DTS `rfkill-modem` 标注
  `M.2 USB Modem`，`usb2phy0_host` 由 `vcc_4v0_5g` 供电）；USB3 控制器
  `usb_host1_xhci`（`combphy1`）与 USB-A 的 `usb_host0_xhci`（`combphy0`）独立。
- M.2 E Key 走 PCIe + USB2（蓝牙），与 B Key、mini-PCIe 均独立。
- 想把 5G 模块切 PCIe 模式，需 mini-PCIe 转 5G 转接板，占用一个 mini-PCIe 槽；
  此时 B Key 仍可插 USB 5G 模块，qmodem 支持多模组。
- SoC 级唯一复用：`combphy0/1/2` 可供 SATA0/1/2；本板未引出/未启用 SATA。
  若启用，会分别挤掉 USB-A USB3 / B Key USB3 / `pcie2x1`。
- **实际限制是电源与散热**：所有 PCIe 槽共用 `vcc_3v3_wifi`，B Key 另有 4.0V 轨；
  DC 输入规格 5–18V 1–3A。多卡满载建议 12V/3A 以上电源，并注意风道。

## 构建

```bash
cd /home/nrxboat/quartzwrt/QuartzWrt-Builder
scripts/build-local.sh --device nlnet_xiguapi-v3
```

只出标准版 squashfs（无 docker 变体）。产物：

```text
artifacts-local/nlnet_xiguapi-v3/
  immortalwrt-rockchip-armv8-nlnet_xiguapi-v3-squashfs-sysupgrade.img.gz
```

复用已有热构建树时注意：

- `build-local.sh` 的目标戳 `$WORK_DIR/.quartz-target` 必须等于
  `rockchip-armv8-nlnet_xiguapi-v3`，否则会 `make dirclean` 清掉热缓存。
- `apply-device.sh` 只复位**当前设备**补丁涉及的文件；切换设备前应清理上一台
  设备投放在 `target/linux/rockchip/{,armv8/}base-files/` 下的 uci-defaults
  等 overlay（Photonicat 的 `99-pcat-mgr`、FNet 的 `99-fancontrol-fnet3399`
  等），否则会带进本机型镜像。

## 刷机

镜像为整盘镜像（U-Boot + kernel + rootfs），可 dd 到 SD/eMMC：

```bash
gzip -dc ...img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress   # SD
gzip -dc ...img.gz | dd of=/dev/mmcblk0 bs=4M conv=fsync                    # eMMC
```

也可用 Rockchip 工具（maskrom 模式）写入 eMMC。

**双介质 U-Boot 注意**：若 eMMC 与 SD 都写入主线 U-Boot 2024.10，SD 启动可能
出现「SD 的 kernel + eMMC 的 rootfs」。建议只保留一个介质带主线 U-Boot，
或 eMMC 使用 Rockchip U-Boot。需要清空 eMMC 但保留其 U-Boot 时，可参考原适配
文章的 64MB 空镜像 + `bootloader.bin` 做法。

## 首启验收

```bash
ip -br link                          # eth0=LAN / eth1=WAN，双千兆协商
df -h                                # rootfs 约 8192MiB
dmesg | grep -i pcie                 # 三控制器枚举
lspci -D                             # domain 0000/0001/0002 对应三个 PCIe 槽
lsusb                                # 5G 模块 / USB
ls /dev/ttyUSB* /dev/mhi_* 2>/dev/null
logread | grep -i qmodem             # qmodem 扫描/拨号
wifi status                          # MT7915 / MT7922 等
dmesg | grep -i "mt7915\|mt7921"     # 驱动/固件加载
uci get ttyd.@ttyd[0].command        # /usr/bin/ttyd-login-check
```

- 风扇：本机未装，跳过；DTS 温控曲线已启用（若装风扇，内核 thermal 自动调速）。
- 屏幕：本版不启用，不亮是预期。
- LED：`blue:status`（sys）、`blue:wan`（net）；第三 LED 未映射。
- 5G PCIe：`dmesg | grep mhi`、`/dev/mhi_QMI0`；QModem 页应识别模组。

## 已知限制

- GC9307 SPI 屏未启用：基座无对应 kmod；后续可加 `kmod-fb-tft-st7789v` +
  DTS `compatible` 补丁 + GC9307 初始化补丁。
- 未预装蓝牙（按用户选择）；MT7922/MT7921 的 BT 需要 `kmod-btusb` +
  `mt7921bt-firmware`/`mt7922bt-firmware`。
- 未预装 fancontrol；若后续要用户态曲线，需处理与内核 thermal cooling-maps
  的抢占关系。
- 6GHz 未作为默认：默认 `CN + 5GHz`；6GHz 需允许 6GHz 的国家（如 US）与
  6GHz 客户端，手动改 `country`/`band`。
- 第三颗 LED 是 `blue:backlight`（屏幕背光 PWM），不作为状态灯；
  `blue:wan` 由 qmodem 管理，当前测试中未点亮。
- 5G PCIe 模式需要 mini-PCIe 转 5G 转接板；M.2 B Key 本体为 USB。
