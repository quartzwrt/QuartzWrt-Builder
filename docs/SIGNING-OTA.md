# QuartzWrt 签名与 OTA 通道设计（WP-9）

**状态**: v1.0（2026-10-14 落地并端到端验证）
**范围**: apk 签名密钥体系、CI 签名、公钥预置、软件源发布（D10 阶段 1/2）、
#41 翻转条件、OTA 通道原型、ASU 评估、第三方自动 Bump CI
**相关**: `docs/TDD.md` §4.2/§4.3/§7.3；`QuartzWrt-ThirdParty/docs/DESIGN.md` §4.5（D10）；
WORKPLAN §3 WP-9、坑位 #41/#50

---

## 1. 签名体系（apk 时代，锁定基座 ce35a9e4 实测）

### 1.1 机制事实（源码 + 实测）

| 事实 | 依据 |
| :--- | :--- |
| apk 签名密钥 = **EC prime256v1**（非 RSA；TDD 旧文"RSA 密钥对"为 opkg 时代措辞） | 基座 `package/Makefile`：`openssl ecparam -name prime256v1 -genkey -noout -out $(BUILD_KEY_APK_SEC)` |
| 密钥文件固定名：`$(TOPDIR)/private-key.pem`（签名）/ `public-key.pem`（验签） | 基座 `rules.mk`：`BUILD_KEY_APK_SEC/PUB` |
| **未注入时每个全新构建树自动生成一把临时密钥** | 同上（`$(BUILD_KEY_APK_SEC):` 规则）——所以"稳定密钥"必须外部注入 |
| 签的是**索引**（`packages.adb`），不是单个 `.apk`：`apk mkndx --sign <私钥>`；包完整性由索引内哈希链保证 | 基座 `package/Makefile`（merge-index / index 目标）；`apk extract` 对未签名单包报 UNTRUSTED 即"单包无签名" |
| 索引签名块：`# sig v00 h04 <key id:16B><ECDSA 签名>`；**key id = sha512(EC 原始点 65B)[:16]** | apk 源码 `crypto_openssl.c apk_pkey_init`（`i2d_PublicKey`→sha512→前 16 字节）；实测与 `adbdump` 输出逐字节一致 |
| 公钥随固件投放 `/etc/apk/keys/`；apk **按内容 id 匹配**、文件名任意 | 基座 `package/base-files/Makefile` `Package/base-files/install-key`（`CONFIG_BUILDBOT` 未设时生效）；apk 源码 `adb_trust_verify_signature` |
| `CONFIG_SIGNED_PACKAGES` 默认 `y` | `config/Config-build.in` |
| **镜像本体在 apk 时代没有可用的密码学签名路径**：`Build/append-metadata` 的 usign/ucert 签名需要 `key-build`+`key-build.ucert`，而验签端 `fwtool_check_signature` 依赖 `/usr/bin/ucert`——本基座镜像**未装 ucert**（实测 manifest 无此包）→ 该路径整体失效（TDD "usign 不再适用"成立） | 基座 `include/image-commands.mk`、`package/base-files/files/lib/upgrade/fwtool.sh`；镜像 manifest 实测 |
| sysupgrade 的实际校验 = 元数据设备匹配（`fwtool_check_image`）+ 平台检查（x86：魔数/分区表）+ 传输完整性；**镜像真实性由 OTA 通道的"清单签名 + sha256"承担**（见 §7） | 基座 `usr/libexec/validate_firmware_image`、`target/linux/x86/base-files/lib/upgrade/platform.sh` |

### 1.2 QuartzWrt 的两把长期密钥

| 密钥 | 算法/工具 | 用途 | 私钥存放 | 公钥随固件投放 |
| :--- | :--- | :--- | :--- | :--- |
| **apk 签名密钥** | EC P-256（openssl） | 签名各 feed 的 `packages.adb` 索引（apk 安装/升级时验签） | GitHub Secrets `APK_SIGNING_PRIVATE_KEY`（+ 维护者本机 `~/.quartz-signing/`，0600） | `/etc/apk/keys/quartz.pem`（`quartz-defaults` 预置）+ `/etc/apk/keys/public-key.pem`（base-files 自动，CI 构建即稳定密钥） |
| **OTA 清单密钥** | Ed25519（usign） | 签名 OTA 版本清单（设备端 usign 验签） | GitHub Secrets `OTA_SIGNING_KEY` | `/etc/quartz-ota.pub`（`quartz-defaults` 预置） |

> 为什么 OTA 用 usign：设备镜像**自带 usign**（基座包，实测在列），**不带 openssl CLI**——
> 用 usign 可零新增依赖完成"清单签名→镜像哈希"信任链；apk 密钥是 EC/PEM 格式，
> 设备端没有对应验签工具。两把密钥分工明确、互不替代。

**当前密钥指纹（2026-10-14 生成，登记备查）**：

- apk key id：`6947a869aad621cb2a8c0765c39ea104`
- OTA fingerprint：`00b0cef78d463a09`

### 1.3 密钥生命周期

- **生成（一次性）**：`scripts/gen-signing-key.sh`（默认输出 `~/.quartz-signing/`，拒绝覆盖）。
- **入仓**：公钥入 `QuartzWrt-Packages`（`meta/quartz-defaults/files/etc/apk/keys/quartz.pem`、
  `files/etc/quartz-ota.pub`）；私钥**永不入 git**。
- **入 Secrets**：`gh secret set APK_SIGNING_PRIVATE_KEY|APK_SIGNING_PUBLIC_KEY|OTA_SIGNING_KEY -R quartzwrt/QuartzWrt-Builder`
  （gen 脚本末尾直接打印命令）。
- **轮换（= 换代，非日常操作）**：已出厂固件只信任其镜像内预置的旧公钥——
  轮换须"先让新公钥随一次固件升级落到设备，再切换签名密钥"，且旧 feed 需双密钥并存过渡；
  纪律：**密钥丢失 = 无法发布可升级的 feed/OTA**（只能走整镜像重刷），私钥务必备份。

---

## 2. 构建注入与验证（本地与 CI 共用）

```text
scripts/inject-signing-key.sh <构建树> [--require]     # 注入 private/public-key.pem（+一致性校验）
scripts/verify-signing.sh <构建树> [--arch --feeds --targets]   # 构建后强校验（8 项断言）
```

- 注入源：`QUARTZ_SIGNING_DIR`（本地）或 `APK_SIGNING_PRIVATE_KEY`（CI Secrets，内容或路径）；
  同时校验"私钥推导公钥 == 给定公钥 == feed 内 quartz-defaults 预置的 `quartz.pem`"——
  **密钥错配直接构建失败**（防"签出来的 feed 没人认"）。
- `build-local.sh` 步骤 5c/5d：注入密钥 + 写构建标识 `files/etc/quartz-build-id`（随镜像投放，
  OTA 版本比较的依据）；步骤 10c：签名一致性校验。
- CI `build.yml`：job 级 env 承接 Secrets（`secrets` 不能用于 step `if`——WP-6 教训），
  "Inject signing key"步骤注入；`publish=yes` 时**强制要求密钥**（`--require`），普通构建允许
  缺省（开发态临时密钥，verify 步骤跳过并提示）。
- **开发态语义（重要）**：不注入密钥时基座生成临时密钥，固件只信任自己——适合本地调试，
  但**该构建的 feed 不可发布**（旧设备不认）。

---

## 3. 软件源发布（D10 阶段 1）

### 3.1 仓库布局（与固件 distfeeds URL 逐字对应）

固件 URL 由基座 `FeedSourcesAppendAPK` + `VERSION_SED_SCRIPT` 生成：
`%U/packages/%A/<feed>/packages.adb`、`%U/targets/%S/packages/packages.adb`
（`%U=CONFIG_VERSION_REPO`、`%A=ARCH_PACKAGES` 如 `x86_64`、`%S=BOARD/SUBTARGET` 如 `x86/64`）。
因此发布目录就是 URL 根：

```text
<发布根>/
├── packages/<arch>/{quartz,thirdparty}/     # 自有 feed（*.apk + packages.adb + index.json）
├── targets/<board>/<subtarget>/packages/    # 目标包（kernel/kmods/base-files……）
├── targets/<board>/<subtarget>/             # 镜像 + sha256sums + profiles.json（OTA 下载对象）
├── ota/<board>/<subtarget>.json(+.sig)      # OTA 版本清单（usign 签名）
└── PUBLISH.txt                              # 发布记录（build id / key id / 体积）
```

生成：`scripts/publish-feed.sh --base-dir <构建树> --dest <目录> [--feeds quartz,thirdparty|all]
[--no-target] [--no-images] [--ota-key PATH]`——内置签名一致性校验（失败不发布）。

### 3.2 托管与同步

**托管形态（2026-10-14 用户决定：自建 NAS 为主）**：发布目录是**纯静态目录树**（根即 URL 根），
任何静态 Web 服务器都能承载——NAS（群晖/威联通/自建 nginx/caddy）是首选；Cloudflare R2
（S3 兼容）保留为"需要公网/跨地域"时的备选（阶段 2 全量镜像也用它更合适）。

**NAS 托管要点（实测/约定）**：

- **URL 必须是设备可达的地址**：LAN 内用 NAS 的 LAN IP 或内网域名（如
  `http://192.168.1.10/quartzwrt`），不要用只在维护机可解析的名字；带路径前缀没问题
  （固件拼接约定 = `<根>/packages/...`），**根 URL 不要带尾斜杠**。
- **HTTP 或 HTTPS 都可**：包完整性由**索引签名**保证（HTTP 只暴露"有哪些包"的元数据）；
  公网暴露建议 HTTPS（NAS 自签证书在设备端无 CA 信任，需用有效证书或用 HTTP + 仅限内网）。
- **同步**：`publish-feed.sh --rsync <目标>`（`-av --delete --chmod=D755,F644`，把旧版本清理
  同步到远端）。目标可以是 SSH 形态（`user@nas:/volume1/web/quartzwrt/quartz-feed`）或已挂载的
  本地路径（SMB/NFS 挂载点）。**目标必须是专用目录**——`--delete` 会清理该目录内不属于本次
  发布的内容（别指向网站根，避免误删站点文件）。
  - **远端要密码时**（NAS 未放 SSH key、甚至没有 home 目录）：`SSH_PASS='<密码>' scripts/publish-feed.sh ... --rsync user@host:/path`
    ——经 `scripts/ssh-pass.py`（pty 助手，自动应答主机密钥确认与密码提示；密码只走环境变量、不落盘）。
  - **手动上传**（不想给自动化凭据时）：`publish-feed.sh` 只生成目录，把该目录（或打成的 zip）
    经宝塔面板/共享目录拷到站点目录即可；注意保持目录结构原样、解压后顶层目录名 = URL 路径段。
- **Web 服务器要求**：原样提供文件（勿改写/勿转码）、保持文件名大小写、允许 `.adb` 后缀、
  不需要目录列表；gzip 等透明压缩无碍（apk 走 HTTP 正常解码）。
- **CI 限制（重要）**：GitHub Actions runner 在公网，**够不到家里的 NAS**——NAS 托管时
  `publish` 流程走"本地/局域网机器"：`publish-feed.sh`（+`--rsync`），或在 CI 里
  `publish=yes` 生成 feed artifact 后，在局域网机器上 `gh run download` 再 `--rsync`。
  若 NAS 经 Tailscale/隧道可达，也可继续用 `PUBLISH_S3_*`（NAS 上跑 MinIO）或 rclone。
- **发布后自检**：`scripts/check-feed-live.sh <URL>`（可达性 / 索引签名 key id /
  OTA 清单验签 / 抽查包可取）——**这就是 #41 阶段 1 的翻转前置检查**。

```bash
# 一次性：本地构建（注入稳定密钥）→ 发布到 NAS（rsync 直推）
QUARTZ_SIGNING_DIR=~/.quartz-signing scripts/build-local.sh
scripts/publish-feed.sh --base-dir ../build/immortalwrt --dest ../feed-out \
  --rsync user@nas:/volume1/web/quartzwrt
scripts/check-feed-live.sh http://192.168.1.10/quartzwrt     # 前置检查（全绿再翻转）
```

**Cloudflare R2 / S3 兼容通道**：CI `publish=yes` → `aws s3 sync`（Secrets：`PUBLISH_S3_ENDPOINT`/
`PUBLISH_S3_BUCKET`/`PUBLISH_S3_ACCESS_KEY_ID`/`PUBLISH_S3_SECRET_ACCESS_KEY`；未配置时只留 artifact）。

---

## 4. 公钥预置与设备侧接入（`quartz-defaults`）

- **公钥**：`/etc/apk/keys/quartz.pem`（apk 信任根）、`/etc/quartz-ota.pub`（OTA 验签）；
  另有 base-files 自动投放的 `public-key.pem`（CI 构建下与 `quartz.pem` 同内容，重复无害）。
- **feed 行（阶段 1 开关）**：kconfig `QUARTZ_FEED_BASE_URL`（string，默认空）——
  - 空：**不写任何 feed 行**（安全默认；未发布前不引入死链，坑位 #41 不复现）；
  - 非空：安装 `/etc/apk/repositories.d/quartz-feed.list`，三行 =
    `quartz` / `thirdparty` / 目标包（后者让 kmod 等按本镜像内核版本可装——
    官方快照旧于锁定基座，kmod 无法从官方装，见 D10 实测）；
    同时写 `/etc/quartz-ota.url`（**OTA 源与 feed 同根，`quartz-ota-update` 零配置可用**；
    `uci quartz.ota.url` 可覆盖）。
- **OTA 件**：`/usr/sbin/quartz-ota-update`（原型，见 §7）。

---

## 5. #41 翻转条件（distfeeds 死链的闭环口径）

坑位 #41 现状：`CONFIG_FEED_{quartz,thirdparty,video}=m` → distfeeds 里三行被注释，
`apk upgrade` 不再因"stale/unavailable repositories"整体拒绝；但 quartz/thirdparty
**尚未接入可用源**（App 软件包管理面只能看到官方源）。

| 阶段 | 动作 | 效果 | 前置条件（翻转条件） |
| :--- | :--- | :--- | :--- |
| **阶段 1（✅ 已执行 2026-10-15）** | `seed.config` 设 `CONFIG_QUARTZ_FEED_BASE_URL="http://10.0.0.110:880/quartz-feed"`（自建 NAS）→ 重建 | 固件经 `quartz-feed.list` 接入自有 feed（quartz/thirdparty/目标包），索引签名由预置公钥校验；`CONFIG_FEED_*=m` **保持不变**（官方 distfeeds 里那三行仍是注释，不复活死链） | ① feed 已发布且 `apk update` 在干净设备上验签通过（**实测：VM `apk update` 10529 包无 UNTRUSTED + `apk add geo2txt` 从 NAS 装成功**）；② 发布件由稳定密钥签名（`verify-signing.sh` 9/9）；③ URL 可匿名访问（LAN HTTP，签名保护完整性） |
| **阶段 2（后续，含全量镜像）** | 全量发布（`--feeds all` + 官方 base/luci/packages/... 镜像）→ `CONFIG_VERSION_REPO="https://<托管根>"` + `CONFIG_FEED_{quartz,thirdparty}=y`（video 视上游情况） | 固件完全自包含：distfeeds 全指向自有镜像，可复现升级；ASU/OTA 前提 | ① 阶段 1 稳定运行；② 全量镜像同步管道（约 3.45GB/x86_64 量级）与缓存策略就绪；③ 官方 feed 的镜像时效性监控（避免比锁定基座旧/新错配） |

> 注意：**不要**只把 `CONFIG_FEED_*=y` 翻回来——那会让 distfeeds 重新指向官方
> `%U/packages/%A/quartz/packages.adb`（404）。翻转必须与 URL 来源（阶段 1 的
> `QUARTZ_FEED_BASE_URL` 或阶段 2 的 `CONFIG_VERSION_REPO`）成对发生。

---

## 6. OTA 通道（原型，已端到端演练）

### 6.1 清单与信任链

```json
{ "schema": "quartzwrt-ota/1", "dist": "QuartzWrt", "base": "ImmortalWrt 25.12",
  "build_id": "<UTC 时间戳>-<Builder 短提交>", "revision": "r0+38247-ce35a9e4ef",
  "target": "x86/64", "generated": "...",
  "images": [ { "name": "...", "path": "targets/x86/64/...", "sha256": "...", "size": N } ] }
```

- 生成：`publish-feed.sh`（构建标识取自镜像内同源的 `files/etc/quartz-build-id`）；
- 签名：`usign -S`（OTA 私钥）→ `<...>.json.sig`；
- 设备侧 `quartz-ota-update`：清单验签（`/etc/quartz-ota.pub`）→ 版本比对（build id）
  → 下载镜像 → **sha256 校验** → `sysupgrade -T` 预检 → `sysupgrade [-n]`；
- 退出码：`0` 已最新 / `10` 有新版本 / `1` 错误（脚本接口，供 App/WP-5 动作封装）。

### 6.2 生产化待办（原型边界）

① 版本比较升级为语义化/日期序（当前为 build id 相等性 + `--force` 重装）；
② 断点续传/带宽控制；③ App 集成（WP-5 动作白名单加 `system.ota_check/apply`，危险动作确认层）；
④ 分设备通道（x86/aarch64 各自的 target 清单已按 `ota/<board>/<subtarget>.json` 分目录）；
⑤ 回滚策略（保留上一版本镜像 URL）。

---

## 7. ASU（Attended Sysupgrade）评估结论

**结论：v1 不采用上游 ASU，走"自有 feed + 签名清单 OTA"通道；ASU 作为 v2 候选，且必须是自建服务。**

依据（实测/机制）：

1. **上游 ASU 服务只从官方 feed 构建**（`asu` 服务端用官方 imagebuilder + 官方 packages），
   不含 quartz/thirdparty feed、不含本项目的设备补丁与分区参数（FNet3399 等）——
   对我们等于"另一个发行版"，产出无法带 Quartz 定制；自建 ASU 服务 = 一套常驻服务 +
   imagebuilder 农场（每个 target/架构都要镜像），运维成本与收益不匹配当前阶段。
2. **我们的构建本来就在 GitHub Actions**：自定义 OTA（本文件 §6）复用既有产物与托管，
   零新增常驻设施；"保留用户已装包列表"（ASU 的核心价值）可以在 v2 用
   "记录 world → 服务端重放安装" 的轻量实现（清单里带 `world` 快照即可）。
3. **签名/信任模型不同**：ASU 依赖官方签名体系；我们已建立自有稳定密钥 + 预置公钥，
   OTA 通道的信任链（清单签名 + 镜像 sha256）已闭环并演练通过。
4. 若将来要接 ASU：建议形态 = **Cloudflare Worker 暴露 ASU API → repository_dispatch 触发
   本仓库 build.yml（带包列表参数）→ 产物回传 R2 → Worker 返回下载 URL**；
   与 D10 阶段 2 的自有全量镜像共用基建。**该形态成立的前提是阶段 2 完成。**

---

## 8. 第三方自动 Bump CI（`.github/workflows/bump.yml`）

- **触发**：每周一 03:00 UTC + 手动；**只做轻量检查，不触发构建**（遵守"CI 仅手动"策略）。
- **动作**：对比三处锁定与上游（`config/base.env` 的基座 commit；`feeds.conf.extra` 的
  quartz/thirdparty `^SHA`）→ 有变化则改锁定、推 `bump/locks-<日期>` 分支、开 PR
  （正文含 TDD §4.3 验证检查单：单包编译 / 本地全量 / 设备重验 / 手动 CI 权威验收 /
  FORKS.md 发布前检查单）。
- **上游发版观察**（informational）：从 `QuartzWrt-ThirdParty/docs/FORKS.md` 提取受控 Fork
  与上游仓库，逐个报"最新 tag / 默认分支头"到 job summary（Builder 单独检出时用内置兜底清单），
  供维护者对照 FORKS.md 的锁定日期判断是否需要同步。
- **合并纪律**：bump PR 合并不等于验收——按 PR 检查单跑完本地全量（含 `verify-signing.sh`）
  或手动 CI 后才合并；设备/基座 bump 必须重验设备补丁（TDD §4.6）。

---

## 9. 验收记录（2026-10-14）

### 9.1 构建与签名

- 稳定密钥注入 + 新 `quartz-defaults`（r2）→ 全量构建 **exit 0**；`verify-signing.sh`
  **8/8 PASS**（quartz/thirdparty 索引签名 key id 匹配 `6947a869aad621cb…`、base-files 公钥载荷、
  quartz.pem / quartz-ota.pub / quartz-ota-update / quartz-feed.list）。
- 镜像级核验（debugfs 直读 rootfs）：`/etc/quartz-build-id`、`/etc/apk/repositories.d/quartz-feed.list`、
  `/etc/apk/keys/quartz.pem` 均在位。

### 9.2 端到端演练（`scripts/ota-drill.sh`，独立 QEMU 实例；**PASS=10 FAIL=0**）

**A. 包升级链路**（旧固件上，模拟"公钥/feed 行随固件投放"）：

| 步骤 | 结果 |
| :--- | :--- |
| A1–A2 投放 `quartz.pem` + `quartz-feed.list` | ✅ |
| A3 `apk update`（**设备端 apk 真实验签**） | ✅ `OK: 10521 distinct packages available`（含自有 feed） |
| A4 自有源索引可用、升级可见 | ✅ `luci-theme-quartz … [upgradable from: …~f9f7488]` |
| A5 **反例：异钥签名的仓库** | ✅ `UNTRUSTED signature` + `apk add luci-app-mosdns` → `no such package`（`ROGUE_REJECTED`） |
| A6–A7 `apk upgrade`（真升级） | ✅ 6 个包升级，含 `quartz-defaults 0.1.0-r1 → 0.1.0-r2` |
| A8 升级后版本 | ✅ dashboard `~4276a56` / theme `~19dfe25`（版本戳前移） |

**B. 固件 OTA 链路**：

| 步骤 | 结果 |
| :--- | :--- |
| B1 投放 `quartz-ota.pub` + `quartz-ota-update` | ✅ |
| B2 `--check` | ✅ 清单验签有效、`本机 unknown → 远端 20261014T2145Z-wp9drill`、退出码 **10** |
| B3 `--apply` | ✅ 下载 → **sha256 校验通过** → `sysupgrade -T` 预检 → 开始升级 → 重启 |
| B4 重启恢复 | ✅ 第 11 次探测（约 1 分钟）SSH 恢复 |
| B5 新 build id | ✅ `20261014T2145Z-wp9drill`（与清单一致） |
| B6 新固件预置件 | ✅ 公钥 / feed 行 / OTA 脚本 all-present |
| B7 升级后包版本 | ✅ 新镜像内版本（dashboard `~4276a56`、theme `~19dfe25`、quartz-defaults r2） |
| B8 自有 feed + OTA 复检 | ✅ `apk update` 通过、`--check` 退出码 0（已最新） |

证据：`dev/ota-drill/`（演练日志 + summary.json + PUBLISH.txt；VM 侧为独立实例，不动共享预览台）。

**演练中发现的边界（如实登记）**：① x86 generic 镜像 `fwtool` **元数据缺失**
（`upgrade: Image metadata not present`）——sysupgrade 的"设备匹配"检查因此跳过（非必需），
镜像选择的正确性由"清单按 target 分目录 + 签名"承担；② 旧固件（本次演练的基线）无
`/etc/quartz-build-id`，脚本显示 `unknown`——正式出厂固件都带该文件；
③ 演练的 `apk upgrade` 顺带验证了"自有 feed 里目标包版本与镜像一致"（内核/kmod 无跨版本漂移）。

---

### 9.3 NAS 托管上线 + 阶段 1 翻转（2026-10-15）

- **环境**：fnOS + 宝塔面板（Docker/openresty）；站点 `http://10.0.0.110:880` ↔ 站点根
  `/vol2/1000/quartzwrt`（实测映射）；**443 为 fnOS 系统 UI**（302→`:5667`），与本站无关。
- **发布**：feed 落在站点根下 `quartz-feed/`（专用子目录，`--rsync` 的 `--delete` 不会波及站点文件）；
  267 文件 / 192M 全量到位。
- **自检**：`scripts/check-feed-live.sh http://10.0.0.110:880/quartz-feed` → **4/4 PASS**。
- **翻转**：`CONFIG_QUARTZ_FEED_BASE_URL` 写入 x86 + FNet3399 双种子（Builder `5733815`）。
- **构建**（build id `20261015T0230Z-nas-flip`）：`verify-signing.sh` **9/9**；镜像级核验（debugfs）
  feed 三行 / `/etc/quartz-ota.url` / build id 均在位。
- **设备侧实测**（新镜像全新 QEMU 实例）：`apk update` 接受 NAS 签名源（10529 包，无 UNTRUSTED）；
  **`apk add geo2txt` 从 NAS 安装成功**；`quartz-ota-update --check` **零配置**（读
  `/etc/quartz-ota.url`）清单验签有效、按 build id 正确判定。
- **运维纪律（实测教训）**：包版本戳含"当日秒数"（`luci.mk findrev`）——**每次重建都会产生新版本**，
  因此 **feed 必须与固件同批发布**（先 build 后 publish），否则设备侧"可用包/OTA 清单"会落后于镜像。

---

## 11. 本地 ↔ CI 构建一致性，与「本地构建 → GitHub Release」发布路径

### 11.1 签名一致性：**已统一（同一把稳定密钥）**

本地构建与 CI 构建注入的是**同一把长期密钥**（CI 走 GitHub Secrets，本地走
`QUARTZ_SIGNING_DIR`；`inject-signing-key.sh` 还会与 `quartz-defaults` 预置公钥比对，
错配即构建失败）——因此：

| 产物 | 签名者 | 本地与 CI 是否一致 |
| :--- | :--- | :--- |
| 各 feed 的 `packages.adb` 索引 | apk EC 稳定密钥（key id `6947a869aad621cb2a8c0765c39ea104`） | ✅ 同一把 → 设备对两边产物**互认** |
| OTA 版本清单 `ota/<board>/<subtarget>.json` | usign/Ed25519 稳定密钥（fingerprint `00b0cef78d463a09`） | ✅ 同一把 |
| 固件镜像本体 | apk 时代**无可用签名路径**（§1.1）——真实性由"清单签名 + 镜像 sha256"承担 | ✅ 同一信任链 |

结论：**"两边签名一致"不需要额外工作**，这是 WP-9 稳定密钥设计的直接结果；设备不需要区分
产物来自本地还是 CI。

### 11.2 包版本一致性：**同锁定下逐字相同（确定性，非构建时刻）**

luci 包的版本戳由 `luci.mk findrev` 生成：`%y.%j`（提交日）+ 当日秒数 + 短 hash，
取自 **feed 提交时间戳**（`git log -1 --format=%ct`；feed 为 `^SHA` 浅克隆，取 tip）。
**与构建时刻无关**——因此本地与 CI 在同锁定下产出的包版本号完全一致。实测（feed
`3dbeb3b`）：手工按同公式算出 `26.287.58460~3dbeb3b`，与本地构建产出的
`luci-theme-quartz-26.287.58460~3dbeb3b.apk` / `luci-app-dashboard-26.287.58460~3dbeb3b.apk`
逐字相符。

含义：本地/CI 两边的包可以**互相升级、互为替代**，不会出现"版本互踩"（旧隐患见坑位 #49——
那是**未提交改动 + 残留旧包**造成的，与构建时刻无关）。

### 11.3 镜像字节级一致（可复现构建）：**可做到同机一致，跨机不承诺**

基座支持 `SOURCE_DATE_EPOCH`（`rules.mk`/`image.mk`/`rootfs.mk` 据此固定包与镜像内
时间戳、分区 GUID 派生值；`PKG_SOURCE_DATE_EPOCH` 亦由它统一）。用法：

```bash
QUARTZ_SOURCE_DATE_EPOCH=1760000000 scripts/build-local.sh     # 本地
# CI：build.yml 同法传入（或发布流程里用同一 epoch，如发布 tag 的提交时间）
```

- **同机重复构建**：可逐字节一致（校验 `sha256sums`）。
- **跨机（WSL ↔ GitHub runner）**：宿主工具链/路径不同，**不承诺**逐字节一致——
  真正需要"跨机可复现"时需固定宿主环境（容器化构建机）。
- 因此发布件的"一致性"承诺落在 §11.1（签名）与 §11.2（版本）两层；镜像 sha256 以
  每次发布的 `sha256sums` 为准（随 Release 提供）。

### 11.4 本地构建 → GitHub Release（`scripts/release-local.sh`）

```bash
# 发布构建（构建标识 = tag，OTA 版本比较一致）+ 校验 + 发 Release
QUARTZ_SIGNING_DIR=~/.quartz-signing scripts/release-local.sh --tag v0.1.0 --build
# 已有构建树（不重编）：只打包 + 发 Release；--dry-run 先演练
scripts/release-local.sh --tag v0.1.0 --dry-run
# 同时把 feed 发布到 NAS（复用 --rsync/SSH_PASS 机制）
scripts/release-local.sh --tag v0.1.0 --build --publish-feed --rsync user@nas:/path/quartz-feed
# 设备构建发布
scripts/release-local.sh --tag v0.1.0 --build --device erya_fnet-3399
```

要点：
- **硬门禁**：发布前必跑 `verify-signing.sh`（索引签名 key id / 公钥载荷 / feed 行与 OTA 源），
  不过不发；
- **资产**：镜像 `*.img.gz`、`*.manifest`、`*.buildinfo`、`sha256sums`、`profiles.json`、
  `ota-<board>-<subtarget>.json(.sig)`，外加 **feed 快照 `quartz-feed-<tag>.tar.gz`**（不含镜像；
  解压后根即 URL 根，供自建源/离线）；
- **Release 说明**自动生成（构建标识/基座与 feed 锁定/签名 key id/软件源 URL/安装与升级方法）；
- 已存在同名 Release 时用 `gh release upload --clobber` 覆盖资产（可重复发布）；
- **发布纪律**：feed 与固件**同批发布**（包版本戳与 OTA 清单都绑定这一次构建；NAS/Release
  的 feed 落后于镜像时，`quartz-ota-update --check` 会把旧镜像当"新版本"提示）。

CI 侧等价：`build.yml` 同样注入密钥并校验；`publish=yes` 时把同一套 feed/OTA 树同步到
S3/R2 兼容托管（`PUBLISH_S3_*`）。**两条通道产物互认**，用哪条发布取决于便利性。

## 10. 开放事项

- 阶段 1 已执行（NAS，2026-10-15，见 §9.3）；R2/S3 Secrets 仅在选择公网托管/阶段 2 时才需要。
- 发布后需在干净设备上复验一次"`apk update` 验签通过 + `apk upgrade` 升级"（演练已用
  本地 HTTP 源证明机制，公网 HTTPS 源属同类）。
- 阶段 2 全量镜像的同步管道（增量/缓存/时效监控）尚未实现。
- `quartz-ota-update` 的 App 集成（WP-5 动作）与"保留已装包"（world 重放）为 v2 事项。
