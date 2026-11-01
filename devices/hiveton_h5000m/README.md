# Hiveton H5000M（MediaTek Filogic）

MT7987A / WiFi 7 / 8GB eMMC 的 5G CPE。基座 ImmortalWrt 25.12 已原生支持
`hiveton_h5000m`（DTS、LED、网络、sysupgrade、镜像定义），本目录**不加厂商补丁**。

## 构建

```sh
QUARTZ_SIGNING_DIR=/home/nrxboat/.quartz-signing \
QUARTZ_BUILD_ID=v0.2.0 \
scripts/build-local.sh --device hiveton_h5000m --variants std,docker
```

- 目标：`mediatek/filogic`；镜像：`*hiveton_h5000m*sysupgrade.bin`
- 根分区：`CONFIG_TARGET_ROOTFS_PARTSIZE=2048`（完整 Quartz + docker 变体）
- 变体：`std` 与 `docker`（用户侧有改内存版本，docker 必须提供）

## 预装口径

- **完整 `quartz-defaults`**（openclash/bandix/主题/Dashboard/daemon/app-api 等）：
  由 `config/preinstall/features.config` 预装，设备层不裁剪。
- **qmodem 5G 栈**：`luci-app-qmodem-next=y`，与 FNet3399 同款默认配置；
  驱动沿用 `config/common.config` 的 Vendor QMI + PCIe + MTK-T7XX + Qfirehose。
- **fancontrol**：预装并启用保守曲线（`start_temp=45` / `start_speed=64` /
  `full_speed_temp=80`），由 `files/.../99-fancontrol-h5000m` 写入。
- 基座设备包（WiFi 7 固件、USB3、f2fs/automount 等）由
  `Device/hiveton_h5000m` 的 `DEVICE_PACKAGES` 带出。
- **只保留板载 WiFi**：通用层的加装 USB/PCIe 网卡驱动（mt792x、rtw8x、iwlwifi、
  ath11k/ath12k、aic8800 等）在本设备层全部显式关闭，仅保留板载 MT7992（驱动包
  `kmod-mt7996e`）+ MT7992-23 固件与 `wpad-openssl` / `wifi-scripts` / `wireless-regdb`。

## Web 终端（ttyd / luci-app-ttyd，2026-11-01）

- `config/preinstall/features.config` 预装 `ttyd` + `luci-app-ttyd` +
  `luci-i18n-ttyd-zh-cn`；LuCI 出现「系统 → 终端」完整交互 shell，
  另有 ttyd 配置页。
- 设备层默认加固（`files/target/linux/mediatek/filogic/base-files/etc/uci-defaults/99-ttyd-quartz`）：
  `interface=@lan`、`check_origin=1`、`max_clients=2`、`terminal_type=xterm-256color`，
  `command` 改为 `/usr/bin/ttyd-login-check`。
- `ttyd-login-check` 在 root 密码未设置（空 / `!` / `*`）时拒绝进入，避免 LAN 的
  7681 端口变成免密 root shell；设置 root 密码后自动回到 `/bin/login`。
- 注意：LuCI 用 HTTPS 访问时，ttyd 默认 HTTP:7681 的 iframe 会被浏览器按混合内容
  拦截；需要给 ttyd 配 SSL、反向代理到同源，或直接新标签打开 7681。

## MH5000-82M 5G 模组适配（2026-10-31）

模组：成都鼎桥 TDTech MH5000-82M（展锐 IVY510 / ORCA 平台），USB VID `0x1782`。
release 固件按 USB 模式使用三个 PID：`0x4056`（RNDIS）/ `0x4057`（ECM）/
`0x4058`（NCM）；debug 固件为 `0x4038/0x4039/0x4040`，本设备层未启用。

release 固件 USB 接口布局（三种模式相同，见模组《linux-android USB 使用指南》§7）：

| interface | 功能 | 宿主节点 |
| :--- | :--- | :--- |
| 2 | AT | `/dev/ttyUSB0` |
| 3 | DIAG | 保留（不建 ttyUSB） |
| 4 | LOG | 保留（不建 ttyUSB） |
| 5 | MODEM | 保留（不建 ttyUSB） |
| 6 | Common AT | 保留（不建 ttyUSB） |

**内核补丁（设备层）**：
`files/target/linux/mediatek/patches-6.12/999-usb-serial-option-add-tdtech-mh5000-82m.patch`
给 `drivers/usb/serial/option.c` 增加三个 release PID，并用
`RSVD(3) | RSVD(4) | RSVD(5) | RSVD(6)` 把 DIAG/LOG/MODEM/Common AT 排除在
option 驱动之外，只让 interface 2 生成 `/dev/ttyUSB0`（AT 口）。
**三个 PID 必须同时支持**：模组当前 USB 模式不同，VID/PID 会变；只加 `4058`
时 NCM 模式可识别，切到 RNDIS/ECM 又会失效。

补丁还在 `option_probe()` 里对这三个 PID 做了接口号兜底：qmodem 的端口规则带
`option_driver: 1`，运行时会往 `option1/new_id` 写一条只有 VID/PID 的动态 ID；
动态 ID 的 `driver_info` 为 0，会绕过 `RSVD()`。兜底检查保证即便动态 ID 生效，
也只有 interface 2 能绑定 option，DIAG/LOG/MODEM/Common AT 不会变成 ttyUSB。

**qmodem 侧（无需改包）**：thirdparty feed 的 qmodem 已包含

- `modem_support.json` 的 `mh5000-82m` profile（manufacturer `huawei`、
  platform `unisoc`、modes `ecm/ncm/rndis`）；
- `modem_port_rule.json` 的 `1782:4056/4057/4058`，`include: ["1.2"]`
  （只取 interface 2 的 AT 口）；
- Huawei/Unisoc 方言：`AT^SETMODE`、`AT^SETAUTODIAL`、`AT^MONSC`、
  `AT^CHIPTEMP`、`AT^SIMSWITCH`。

开机/热插拔由 `qmodem_init` + `modem_scan.sh` 自动建 section，无需手工指定
设备或 tty 端口。`kmod-usb-serial-option` 已加入 `DEVICE_MANIFEST_PACKAGES`
断言，防止镜像漏包。

**构建注意**：本补丁是 target 补丁，新增/修改后首次构建会让
`make target/linux/prepare` 重新应用；若复用旧构建树且补丁没有生效，清掉内核
prepare 戳（或 `make target/linux/clean`）后再构建。构建后可确认：

```sh
grep -n TDTECH_PRODUCT_MH5000_82M \
  build/immortalwrt/build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic/linux-*/drivers/usb/serial/option.c
```

（本次已在 6.12.112 上通过真实 prepare 流程应用补丁，`make target/linux/compile`
内核编译 `EXIT=0`；产出 `option.ko` 的 `usb_device_id` 表中三个 PID 的
`driver_info` 均为 `0x78`，即 `RSVD(3..6)`。）

**真机验证（插模块后）**：

```sh
lsusb | grep -i 1782
ls /dev/ttyUSB*
dmesg | grep -i option
uci show qmodem | grep -E 'at_port|manufacturer|platform'
# AT 口（ttyUSB0）：
# AT+CGMM -> MH5000-82M
# AT+CGMI -> TDTech Technology Co., LTD
# AT^SETMODE? -> ^SETMODE: 0/1/2
# AT^SETAUTODIAL? -> ^SETAUTODIAL:1,4
```

预期：只出现 `/dev/ttyUSB0`（AT）；qmodem 自动识别 `mh5000-82m`，蜂窝页/
短信/AT 调试可用；数据面出现 `usbX` 网口并自动拨号。若出现多个 ttyUSB，说明
补丁未生效（DIAG/LOG 被 option 误绑）或模块为 debug 固件。

**真机验证记录（2026-11-01，镜像 `20261101-ttyd-mh5000-82m`）**：

- **内核补丁通过**：模块在 RNDIS（`1782:4056`）和 NCM（`1782:4058`）下都只把
  interface 2 绑成 `/dev/ttyUSB0`，没有 DIAG/LOG/MODEM 的额外 ttyUSB；
  `dmesg` 为 `option 2-1:1.2: GSM modem (1-port) converter detected`。
- `ATI` 可读：`TDTech Technology Co., LTD / MH5000-82M / V100R001C00`。
- **当前阻塞（非驱动/qmodem）**：模块每 ~30 s 自重启一轮——
  SuperSpeed 枚举约 5–12 s → `USB disconnect` → `usb 1-1` 全速设备出现约 3.5 s
  → 再枚举；每次 RNDIS/NCM MAC 都变，说明是模块重启而非普通 USB 复位。
  RNDIS 与 NCM、qmodem/hotplug 全停、`power/control=on` 均复现；无 over-current
  日志；AT 后续命令多为 `+CME ERROR: 4`（模块处于启动/复位窗口）。
- **重插 + 重启复验（2026-11-01 15:17）**：现象不变。NCM `4058` 下
  `/dev/ttyUSB0` 会短暂出现，但仍 ~30 s 掉线；按 USB 手册 FAQ Q4 的
  `stty -F /dev/ttyUSB0 -echo raw` 后单发 `AT+CGMM` 仍返回 `+CME ERROR: 4`
  （`ATI` 正常）。H5000M DTS 只有 `reg_3p3v`/`reg_usb_5v` 两个 fixed regulator，
  没有 `USB_DETECT` GPIO 或电流限制描述，硬件侧需核对适配器是否引出该脚及供电。
- **复位尝试（2026-11-01 15:23–15:26）**：`AT+RESET=1`、`AT+CFUN=1,1` 均返回
  `+CME ERROR: 4`；USB 层 `unbind`/`bind` 强制重新枚举后仍按 ~30 s 循环。
  模块当前只响应 `ATI`，其余标准 AT 全部 CME 4，说明复位命令到不了模组控制核，
  不是 qmodem/驱动能解决的；下一步是硬件侧（USB_DETECT/供电/适配器）或联系
  TDTech 做固件恢复。
- **Windows 交叉验证（2026-11-01）**：同一模块经 USB 转接板（父设备为
  Genesys Logic `05e3:0610` Hub）在 Windows 上稳定枚举，PID `1782:4058`，
  无断联。设备树为 1 个 `MI_00` UsbNcm（驱动正常，生成“以太网 6”，未拨号）
  + `MI_02..06` 五个 TDTECH 设备（Problem 28 = 无驱动，对应
  AT/DIAG/LOG/MODEM/Common AT）。这证明**模块本身正常**，H5000M 侧的循环
  问题在 M.2 座/转接板/供电/`USB_DETECT`，不是模组固件或我们的内核补丁。
- **下一步硬件排查**：换有源 USB Hub/独立供电、USB2-only 线/口、换 M.2 适配器
  或 USB 线、检查 SIM/天线、把模块插到 PC/FNet3399 交叉验证；若仍复现，联系
  TDTech 确认 `V100R001C00` 固件是否有供电/看门狗问题。
  **重点核对 USB 手册 §4.1 的 `USB_DETECT`**：模组用上升沿/下降沿做 USB3 插拔
  检测，适配器或主板未引出/未驱动该脚时会反复走“插入/拔出”流程，与本次
  SuperSpeed→USB2 反复枚举的现象吻合；可先用 USB2-only 连接验证。USB 手册
  FAQ Q4 还提示 AT 口需先 `stty -F /dev/ttyUSB0 -echo raw`，否则可能返回
  `ERROR4`（对应 AT 手册 §22.2 的 CME 4）；FAQ Q3/Q5 的官方路径是采集
  `lsusb -t`、`lsusb -v`、`dmesg` 交 TDTech 支持分析。

**边界**：debug 固件 PID（`4038/4039/4040`）与文档未列出的 `4041/4059` 未纳入；
需要时按同样方式补 ID（debug 的 Common AT 在 interface 7、ADB 在 6，RSVD 要
相应扩到 7）。

## 真机验收（2026-10-21，v0.2.0 docker 变体）

设备：Hiveton H5000M（MT7987A，2 GB RAM〔用户改配〕，8 GB eMMC），
固件 QuartzWrt v0.2.0（docker 变体），内核 6.12.112。

- **5G**：Quectel RG520N-EU，5G SA / n78 / 100 MHz（QENG 带宽码 12）/ PCI 900 /
  ARFCN 620640；RSRP -82 dBm、RSRQ -11、SINR 21–24；IPv4 + 公网 IPv6 已拨号。
  国内节点单流实测 **26.2 MB/s（USB2）/ 27.2 MB/s（USB3）**，约 210–218 Mbps。
  **USB 链路：首次冷启动枚举为 USB 2.0（480 Mbps），重启后恢复 USB 3.0
  （5000 Mbps / 3.20）**；USB3 下吞吐与 USB2 基本相同 → 瓶颈在移动网络/小区，
  不在 USB。首次冷启动 2.0 的复现条件待后续观察。
- **WiFi 7**：MT7992（2.4/5 GHz 双频，DTS `mt7992@0,0`）；2.4 GHz EHT40（ch1）+ 5 GHz EHT160（ch36）。
  实测客户端 2SS / 160 MHz，RX 1441–1729 Mbps / TX 1441 Mbps（EHT）。
- **2.5G 网口**：eth0 = RTL8221B（2.5G PHY，LAN）、eth1 = MT7987 2.5G PHY（WAN，
  当前无载波）。本次对端为千兆网卡，协商 1000 Mbps；**用户确认 2.5G 无需实测**
  （硬件/对端条件具备）。
- **存储/内存**：eMMC 8 GB，`/overlay` 7.15 GB（已用约 200 MB）；内存 1.94 GB 可见。
- **风扇**：fancontrol 运行（45/64/80 曲线）。空闲 47–51°C / PWM 71–90；
  4 核满载 60 s 后 55.5°C / PWM 120；降温 30 s 后 46.6°C / PWM 82，无卡死/停转。
- **LED**：仅 3 个（`amber:wlan-2ghz`、`blue:wlan-5ghz`、`mdio-bus:0f:red:wan`）。
  WLAN LED 当前 `trigger=none` 常亮；WAN LED 跟随 eth1（以太 WAN），WWAN 未映射。
  如需 5G 状态灯，后续在设备层调整。
- **通用验收**：`vm-accept-config.sh` **17/17**、`vm-accept-router.sh` **15/15**、
  App e2e **32/32 ALL PASS**（真实 5G 模组；qmodem `at_cfg` lang=en 40 条命令）。
- **本轮修复**：
  - Dashboard `DockerCard.vue` / App 概览 `dockerCard` 把「运行中容器数」误当引擎
    状态（0 容器显示 stopped），改为 `available` 判定；设备热装修复版，Docker 卡
    显示“运行中”。
  - `quartz-app-api` uhttpd `app` 实例未设 `home`，443 根路径暴露文件系统目录列表；
    r15 固定 `home=/www`（既有无此项的设备由 uci-defaults 修复）。
  - **重启后 qmodem 保留旧 `1_1`（state=disabled）与新 `2_1` 两段**，daemon 原先把
    两段都采集 → 快照出现两个模组。daemon **r9** 过滤 `state=disabled` 段，并给包
    补 postinst（运行时升级后自动 restart）；热升级 r9 后快照只剩 `2_1`，e2e 32/32。
- **证据**：`dev/shots/`（Dashboard 中英文/明暗、QModem、风扇、无线、接口）与
  `dev/shots/accept-*.log`。

## Docker 存储驱动（重要，H5000M / FNet3399）

H5000M 根分区是 squashfs + overlayfs，docker 变体默认数据目录 `/opt/docker` 同样位于
overlay 上。`docker run` 会报：

```text
failed to mount ... fstype overlay ... invalid argument   # overlay-on-overlay
```

两种处理（任选其一）：

1. **重新选择 Docker 数据目录**：LuCI → 服务 → Docker，把 Docker 数据目录改到
   非 overlay 的文件系统（例如挂载的磁盘/分区），保存后重启 Docker；
2. 若只能留在 overlay：在 `/etc/docker/daemon.json` 增加 `"storage-driver": "vfs"`，
   重启 dockerd（兼容性最好，性能较低）。

Docker 卡在引擎正常时显示“运行中”；本轮之前显示的“stopped”是卡片误判，已修复。

## 待真机复核 / 后续

- 首次冷启动枚举 USB 2.0、重启后恢复 USB 3.0 的复现条件（疑似 USB3 上电/枚举时序）。
- LED 映射：WWAN/5G 状态灯、WLAN LED 活动触发。
- Docker 数据目录选择在 LuCI/Docker 页的易用性（当前需手动改 daemon.json 或目录）。
- qmodem 旧 section 的自动清理（当前由 daemon 侧过滤 `state=disabled`，UCI 里仍保留 `1_1`）。
- 长期稳定性（本轮 3.5 h 观察无异常；建议 24 h 复测）。

## 发布链

H5000M 产出 `sysupgrade.bin`；`build-local.sh` / `release-local.sh` / CI 的产物收集
需补 `.bin` 支持（随本设备层一起提交）。OTA/feed 发布仍只走标准版。
