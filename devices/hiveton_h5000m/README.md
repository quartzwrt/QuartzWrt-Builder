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

## 待真机复核

- 5G 模组实际型号与 qmodem 驱动匹配（MTK T7XX / Vendor QMI）。
- fancontrol 起转/稳态温度/启停频率；曲线可能需要按真机调整。
- eMMC 根分区与 docker 数据目录容量。
- WiFi 7 双频、2.5G 网口、LED 映射。

## 发布链

H5000M 产出 `sysupgrade.bin`；`build-local.sh` / `release-local.sh` / CI 的产物收集
需补 `.bin` 支持（随本设备层一起提交）。OTA/feed 发布仍只走标准版。
