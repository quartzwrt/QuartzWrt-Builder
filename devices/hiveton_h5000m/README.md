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
  ath11k/ath12k、aic8800 等）在本设备层全部显式关闭，仅保留 MT7996E + MT7992-23
  驱动/固件与 `wpad-openssl` / `wifi-scripts` / `wireless-regdb`。

## 真机验收（2026-10-21，v0.2.0 docker 变体）

设备：Hiveton H5000M（MT7987A，2 GB RAM〔用户改配〕，8 GB eMMC），
固件 QuartzWrt v0.2.0（docker 变体），内核 6.12.112。

- **5G**：Quectel RG520N-EU，5G SA / n78 / 100 MHz（QENG 带宽码 12）/ PCI 900 /
  ARFCN 620640；RSRP -82 dBm、RSRQ -11、SINR 21–24；IPv4 + 公网 IPv6 已拨号。
  国内节点单流实测 **26.2 MB/s（USB2）/ 27.2 MB/s（USB3）**，约 210–218 Mbps。
  **USB 链路：首次冷启动枚举为 USB 2.0（480 Mbps），重启后恢复 USB 3.0
  （5000 Mbps / 3.20）**；USB3 下吞吐与 USB2 基本相同 → 瓶颈在移动网络/小区，
  不在 USB。首次冷启动 2.0 的复现条件待后续观察。
- **WiFi 7**：MT7996E/MT7992E；2.4 GHz EHT40（ch1）+ 5 GHz EHT160（ch36）。
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
