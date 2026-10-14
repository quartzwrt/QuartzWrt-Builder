# QuartzWrt-Builder

QuartzWrt 主构建仓库：ImmortalWrt 基座锁定、双 Feed 注入、固件构建与签名流水线。

整体设计规范见 [docs/TDD.md](docs/TDD.md)。

## 目录结构

| 路径 | 职责 |
| :--- | :--- |
| `config/base.env` | ImmortalWrt 基座锁定（分支 + 精确 commit） |
| `config/feeds.conf.extra` | 双 Feed 定义（CI 中**追加**到基座 `feeds.conf` 末尾，不替换） |
| `config/seed.config` | `.config` 构建种子（x86_64 默认目标，最小集） |
| `devices/<设备名>/` | 设备适配层：基座补丁（`patches/`）+ 原样投放文件（`files/`）+ 设备种子（`seed.config`）+ 元数据（`device.env`）；当前含 `erya_fnet-3399`（RK3399） |
| `scripts/build-local.sh` | 本地全量构建脚本（复刻 CI 步骤，产物落本地目录，见 docs/TDD.md §7.4）；`--device <名>` 切换设备目标 |
| `scripts/apply-device.sh` | 设备适配层应用（build-local 与 CI 共用：复位→打补丁→投放 files） |
| `scripts/check-manifest.sh` | manifest 校验（build-local 与 CI 共用：公共断言 + 设备断言） |
| `scripts/test-in-docker.sh` | 本地镜像 Docker 快速预览：导入 rootfs 起最小服务链，浏览器看真实 LuCI（主题/Dashboard 视觉验证用；不含内核/网络/防火墙——那些走 QEMU） |
| `scripts/test-in-vm.sh` | QEMU/KVM 真启动测试：完整引导链（BIOS→GRUB→内核）、procd 首次启动、网络栈；交互串口 / `--detach` / `--stop`（2026-10-12 实测通过；x86 目标） |
| `scripts/check-duplicate-packages.sh` | 双 Feed 同名包扫描（CI 强制项） |
| `scripts/gen-signing-key.sh` / `inject-signing-key.sh` / `verify-signing.sh` | WP-9 签名密钥：生成（一次性）/ 构建树注入（+密钥一致性校验）/ 构建后签名强校验（docs/SIGNING-OTA.md） |
| `scripts/publish-feed.sh` | WP-9 发布：整理 feed 树 + 目标包 + 镜像 + 签名 OTA 清单（含同名旧版本清理与索引重签）；`--rsync` 直推 NAS 等静态托管 |
| `scripts/check-feed-live.sh` | WP-9 发布后自检：托管根可达性 / 索引签名 key id / OTA 清单验签 / 抽查包可取（#41 阶段 1 翻转前置） |
| `scripts/ota-drill.sh` | WP-9 端到端演练：独立 QEMU 实例上跑「包升级链路 + 固件 OTA 链路」（含异钥反例） |
| `scripts/release-local.sh` | WP-9 发布：本地构建 → 签名校验（硬门禁）→ 打包 → `gh release create`（含多架构 feed 快照与 OTA 清单） |
| `scripts/publish-feed-all.sh` | WP-9 多架构发布：按"架构:目标"对表发布全部 feed/目标包/镜像 + 生成软件源页面 + 一次 rsync |
| `scripts/gen-feed-page.sh` | WP-9 软件源页面（仿 ImmortalWrt 下载页）：总览 / 包清单 / 镜像清单，纯静态自包含 |
| `scripts/release-feed-repos.sh` | WP-9 双 Feed 仓库 Release：quartz/thirdparty 各发多架构 feed 压缩包（供自建软件源）+ 公钥 |
| `scripts/ssh-pass.py` | pty 驱动 ssh/rsync 密码认证（NAS 等无 key 远端发布用；密码仅走环境变量） |
| `.github/workflows/build.yml` | GitHub Actions 全量构建流水线（仅手动触发；`device` 切换设备目标；`publish` 发布 feed/OTA） |
| `.github/workflows/bump.yml` | 锁定自动检查（每周 + 手动）：基座/双 Feed 上游更新 → 开 bump PR；另附受控 Fork 上游发版观察 |
| `docs/TDD.md` | 技术设计文档（唯一权威版本） |
| `docs/SIGNING-OTA.md` | WP-9 设计与运行手册：签名体系、公钥预置、软件源发布（D10 阶段 1/2 与 #41 翻转条件）、OTA 原型、ASU 评估、Bump CI |
| `dev/ota-drill/` | WP-9 演练证据（日志 / summary.json / PUBLISH.txt） |

## CI 构建（仅手动触发）

- **触发方式：仅手动 `workflow_dispatch`**，不随 push / PR 自动运行；日常构建验证走本地 `scripts/build-local.sh`（docs/TDD.md §7.4）。
- 用途：发布前 / 基础设施重大变更后的干净环境权威验收。
- 单次全量构建约 2–6 小时；GitHub Actions 默认磁盘不足，流水线已用 `maximize-build-space` 扩容。
- 公开仓库免费额度无限；若仓库为私有，注意月度 CI 分钟数限制。

手动触发：

```bash
gh workflow run build.yml
```

## 构建锁定状态（docs/TDD.md §4）

- ✅ 基座锁定：`config/base.env`（ImmortalWrt 25.12 @ ce35a9e4）。
- ✅ 双 Feed 锁定：`config/feeds.conf.extra` 已从 `;main` 改为 commit SHA；升级时更新 SHA 并触发全量 CI 验证。
- ✅ 第三方包校验和：`PKG_MIRROR_HASH` 已回填（thirdparty feed）。
- ✅ apk 签名与 OTA（WP-9，2026-10-14）：稳定 EC 签名密钥（Secrets → 构建注入）+ 公钥随
  `quartz-defaults` 预置 + 签名校验 + feed/OTA 发布管线 + 端到端演练（见 `docs/SIGNING-OTA.md`）。
- ⏳ 待办：托管凭据（R2/S3 Secrets）与 `seed.config` 的 `CONFIG_QUARTZ_FEED_BASE_URL` 填写
  （D10 阶段 1 翻转，条件见 `docs/SIGNING-OTA.md` §5）。

> 注意：`scripts/feeds` 的解析器只把 `#` 后跟至少一个字符的行当注释，**单独的 `#` 行会报语法错误**（见 `config/feeds.conf.extra` 中的说明）。

## 签名与发布（WP-9，docs/SIGNING-OTA.md）

```bash
# ① 生成长期签名密钥（一次性；输出 ~/.quartz-signing，私钥不入 git）
scripts/gen-signing-key.sh
# ② 公钥入 Packages 仓库（quartz-defaults 预置）；私钥写入 GitHub Secrets（脚本会打印命令）

# ③ 本地构建：注入密钥（QUARTZ_SIGNING_DIR）+ 构建标识 + 构建后签名校验（步骤 5c/10c 自动）
QUARTZ_SIGNING_DIR=~/.quartz-signing scripts/build-local.sh

# ④ 发布 feed + OTA 清单到目录（多架构 + 自动生成软件源页面；再整体同步到托管：NAS/R2/静态主机）
scripts/publish-feed-all.sh --base-dir ../build/immortalwrt --dest ../feed-out
#    直接推到 NAS（静态托管，-av --delete；目标须为专用目录）：
#    scripts/publish-feed.sh --base-dir ../build/immortalwrt --dest ../feed-out \
#      --rsync user@nas:/volume1/web/quartzwrt
# ⑤ 发布后自检（#41 阶段 1 翻转前置：可达性/索引签名/OTA 验签/抽查包）
scripts/check-feed-live.sh http://<nas-ip>/quartzwrt
# ⑥ 端到端演练（独立 QEMU：包升级链路 + 固件 OTA 链路，含异钥反例）
scripts/ota-drill.sh            # 证据落 ../vm/ota-drill/
```

# ⑥ 本地构建 → GitHub Release（发布路径；本地与 CI 同一把签名密钥，产物互认）
QUARTZ_SIGNING_DIR=~/.quartz-signing scripts/release-local.sh --tag v0.1.0 --build
#    资产：镜像/manifest/sha256sums/profiles.json/OTA 清单 + feed 快照 tar.gz；--dry-run 可先演练
#    同时发布 feed 到 NAS：... --publish-feed --rsync user@nas:/path/quartz-feed

CI：`gh workflow run build.yml -f publish=yes`（需签名 Secrets；托管凭据 `PUBLISH_S3_*` 可选，
未配置时 feed 树随 artifact 留档）。锁定自动检查/开 PR：`.github/workflows/bump.yml`（每周一 + 手动）。
本地与 CI 的一致性（签名/版本/可复现构建）见 `docs/SIGNING-OTA.md` §11。

## 基座升级 / 追随新版

修改 `config/base.env` 的 `BASE_BRANCH`/`BASE_COMMIT`：

```bash
git ls-remote https://github.com/immortalwrt/immortalwrt.git refs/heads/openwrt-25.12
```

改后手动触发一次全量 CI 验证（`gh workflow run build.yml`）。

## 设备适配（devices/，docs/TDD.md §4.6）

Builder 支持多目标构建：默认 x86_64，`devices/<设备名>/` 目录承载设备适配
（对锁定基座的补丁 + 原样投放文件 + 设备 `.config` 种子 + 元数据）。

```bash
# 设备本地构建（产物落 artifacts-local/<设备名>/）
scripts/build-local.sh --device erya_fnet-3399

# 设备 CI 构建（手动触发时填 device 输入）
gh workflow run build.yml -f device=erya_fnet-3399
```

原则：**不改基座仓库**——设备差异一律落 `devices/`（补丁基于锁定 commit，
逐字节可复现；基座升级后需重验补丁）。x86_64 ↔ 设备目标切换由 `build-local.sh`
自动 `make dirclean`（`.quartz-target` 戳记护栏）。新增设备照
`devices/erya_fnet-3399/` 的目录结构（`device.env`/`seed.config`/`patches/`/`files/`）复制改造。

## 本地构建（开发迭代）

- **全量本地构建**：`scripts/build-local.sh`（复刻 CI 步骤，见 docs/TDD.md §7.4），产物落在本地目录，用于快速迭代验证；正式产物仍以 CI 为准。
- **单包快速验证**（几分钟级）：

```bash
git clone https://github.com/immortalwrt/immortalwrt.git --branch openwrt-25.12
cd immortalwrt
git checkout ce35a9e4ef1b87fbbc2146036ce6693e4242861a
cp feeds.conf.default feeds.conf
cat /path/to/QuartzWrt-Builder/config/feeds.conf.extra >> feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a
# 验证某个包
make package/feeds/thirdparty/luci-lib-docker/compile
```
