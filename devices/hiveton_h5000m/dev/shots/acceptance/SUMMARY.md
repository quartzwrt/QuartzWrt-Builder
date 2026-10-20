# H5000M 真机验收摘要（2026-10-21）

## 基线

- 设备：Hiveton H5000M，MT7987A，2 GB RAM（用户改配），8 GB eMMC。
- 固件：`QuartzWrt v0.2.0 (ImmortalWrt 25.12)`，内核 6.12.112，docker 变体。
- 热更：`quartz-app-api 0.1.0-r15`、`quartz-daemon 0.1.0-r9`、Dashboard Docker 卡
  修复版（同版本重装）。
- 访问：`https://192.168.1.1`（App API）/ `http://192.168.1.1`（LuCI）。

## 结果

| 项 | 结果 |
| :--- | :--- |
| 5G 模组 | RG520N-EU，5G SA n78，100 MHz，PCI 900，ARFCN 620640 |
| 信号 | RSRP -82 dBm / RSRQ -11 / SINR 21–24（多次采样） |
| 拨号 | 运行中；IPv4 `10.5.42.81`，公网 IPv6 已获取 |
| 吞吐 | 国内节点单流 26.2 MB/s（USB2）/ 27.2 MB/s（USB3），约 210–218 Mbps |
| USB | 首次冷启动 480 Mbps（USB 2.0）；**重启后 5000 Mbps / 3.20（USB 3.0）** |
| WiFi 7 | 2.4G EHT40 + 5G EHT160；客户端 2SS/160MHz RX 1441–1729 / TX 1441 Mbps |
| 2.5G | eth0 RTL8221B / eth1 MT7987 2.5G PHY；本次对端千兆 → 1000 Mbps；用户确认无需实测 |
| eMMC | `/overlay` 7.15 GB，已用约 201 MB |
| 风扇 | 45/64/80 曲线；空闲 47–51°C/PWM 71–90；满载 55.5°C/PWM 120；降温 46.6°C/PWM 82 |
| LED | 3 个：2.4G/5G/WAN；WLAN 常亮，WAN 跟随 eth1，WWAN 未映射 |
| 配置面 | `vm-accept-config.sh` 17/17 PASS |
| 路由器后端 | `vm-accept-router.sh` 15/15 PASS |
| App e2e | 32/32 ALL PASS（真机） |
| 稳定性 | 连续运行 3.5 h，daemon/dockerd/fancontrol PID 未变，无崩溃；温度 47.4°C |

## 本轮发现与修复

1. **Dashboard / App Docker 卡误判**：`d.running` 是运行中容器数，0 容器被显示为
   “stopped”；改为 `available` 判定。Dashboard 已重编前端（app.js）并热装，App
   概览卡同步修复（analyze 0 + 99 测试）；Docker 卡显示“运行中”。
2. **app-api 443 目录列表**：uhttpd `app` 实例未设 `home`，根路径暴露文件系统
   目录列表；r15 固定 `home=/www`，既有设备由 uci-defaults 修复。
3. **Docker overlay-on-overlay**：H5000M 上 `docker run` 复现
   `overlay ... invalid argument`；已在 Builder README、设备 README、App CHANGELOG
   写明「重新选择 Docker 数据目录 / vfs」的处理方式。
4. **重启后 qmodem 旧模组段**：旧 `1_1`（state=disabled）与新 `2_1` 并存，daemon
   原先把两段都采集 → 快照出现两个模组。daemon **r9** 过滤 disabled 段，并给包补
   postinst（运行时升级自动 restart）；热升级后快照只剩 `2_1`，e2e 32/32。

## 重启后复验（2026-10-21）

- USB 恢复 **5000 Mbps / 3.20**；国内单流 27.2 MB/s，与 USB2 时基本相同 → 瓶颈在
  移动网络/小区，不在 USB。
- qmodem 的 `1_1/2_1` 并存问题已由 daemon r9 过滤；`apk` 升级 r9 时 postinst 自动
  重启进程（PID 变化），不需要手动 restart。
- 2.5G 按用户确认不再实测。

## 证据

- 官网候选图：`dev/shots/website/`
- 验收日志与截图：`dev/shots/acceptance/`
- 详细说明：`devices/hiveton_h5000m/README.md`
