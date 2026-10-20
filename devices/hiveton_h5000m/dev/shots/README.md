# H5000M 真机验收证据（2026-10-21）

设备：Hiveton H5000M（MT7987A / 2 GB RAM / 8 GB eMMC）
固件：QuartzWrt v0.2.0 docker 变体（内核 6.12.112）+ 本轮热修包
（quartz-app-api r15、Dashboard Docker 卡修复版）

## website/（官网上架候选）

| 文件 | 说明 |
| :--- | :--- |
| `dashboard-zh-clean-light.png` | **中文首图候选**：1920×1080，中性背景，Dashboard 全量真数据 |
| `dashboard-zh-clean-dark.png` | 中文暗色首图候选 |
| `dashboard-zh-clean-mobile-light.png` | 中文移动端（390×844 @2x） |
| `dashboard-zh-clean-mobile-dark.png` | 中文移动端暗色 |
| `dashboard-zh-clean-lower-light.png` | 中文下半区（服务/Bandix 流量/客户端，已脱敏） |
| `dashboard-en-clean-light.png` | 英文首图候选 |
| `dashboard-en-clean-dark.png` | 英文暗色 |
| `dashboard-zh-wallpaper-light.png` | 中文 + 设备当前自定义壁纸（展示壁纸能力） |
| `dashboard-en-wallpaper-light.png` | 英文 + 自定义壁纸 |
| `qmodem-zh-clean-light.png` | 中文 QModem 概览（5G 信号/小区/SIM，IMEI/IMSI/ICCID 已打码） |
| `qmodem-zh-clean-dark.png` | 中文 QModem 暗色 |
| `qmodem-en-clean-light.png` | 英文 QModem |
| `qmodem-zh-wallpaper-light.png` | 中文 QModem + 自定义壁纸 |

说明：

- 数据为真机实时数据（RG520N-EU，5G SA n78，IPv4/IPv6 已拨号）。
- `*-clean-*` 为展示用中性渐变背景（截图时移除用户壁纸层）；`*-wallpaper-*` 保留设备壁纸。
- 已脱敏：QModem 的 IMEI/IMSI/ICCID；Dashboard 的客户端 MAC/IP/主机名。
- Hero 与侧栏的 `QuartzWrt H5000M` / `QuartzWrt` 为展示用文案替换；设备实际 hostname
  仍为 `ImmortalWrt`。如需与截图完全一致，可在设备上把 hostname 设为
  `QuartzWrt-H5000M`。
- 建议官网首图：中文 `dashboard-zh-clean-light.png`，暗色 `dashboard-zh-clean-dark.png`，
  移动端 `dashboard-zh-clean-mobile-light.png`。

## acceptance/（验收证据）

| 文件 | 说明 |
| :--- | :--- |
| `accept-config-20261021.log` | 配置面 17/17 PASS |
| `accept-router-20261021.log` | 路由器后端 15/15 PASS |
| `e2e-20261021.log` | App e2e 32/32 ALL PASS |
| `e2e-post-reboot-20261021.log` | 重启后 App e2e 32/32 ALL PASS |
| `post-reboot-20261021.txt` | 重启后 USB3/单模组/版本复验记录 |
| `status.json` | quartz-daemon 实时快照（含 cellular/docker/bandix） |
| `fancontrol.png` | 风扇控制页面（运行中，温度/PWM 实时值） |
| `wireless.png` | 无线页面（2.4G EHT40 / 5G EHT160） |
| `interfaces.png` | 接口页面（wwan0_1 / LAN，IP 已打码） |

详细结论与待办见 `devices/hiveton_h5000m/README.md` 的「真机验收」与
「待真机复核 / 后续」两节。
