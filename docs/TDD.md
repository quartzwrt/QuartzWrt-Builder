# 💎 QuartzWrt 技术设计文档 (TDD)

**文档版本**: v2.0.1（双 Feed 架构与第三方包集成规范合并版；2026-10-20 增补蜂窝/5G 定位）
**项目代号**: Quartz (石英)
**基座系统**: ImmortalWrt (OpenWrt 衍生版)
**文档状态**: 已确认 (Approved)
**适用范围**: QuartzWrt 固件构建、App 开发、第三方插件引入
**最后更新**: 2026-10-20

> **版本说明**：本文由《QuartzWrt 技术设计文档 v1.1.0》与《QuartzWrt 第三方软件包集成与管理规范 v1.0.0》合并而成，统一了两份文档的术语、修正了与 OpenWrt 构建机制不符的示例，并补充了 Feed 自锁定、运行时资源锁定、签名与 OTA 等章节。

---

## 0. 术语表 (Glossary)

| 名称 | 类型 | 说明 |
| :--- | :--- | :--- |
| `QuartzWrt-Builder` | 仓库 | 主构建仓库：`.config` 种子、`feeds.conf`、构建脚本、CI 流水线、`docs/` |
| `QuartzWrt-Packages` | 仓库 | 自有核心与适配层。在 `feeds.conf` 中的 feed 标识为 **`quartz`** |
| `QuartzWrt-ThirdParty` | 仓库 | 第三方插件收集器。在 `feeds.conf` 中的 feed 标识为 **`thirdparty`** |
| `quartz-defaults` | 元包 | 位于 `QuartzWrt-Packages` 的 `meta/` 目录，统一声明跨 Feed 的包依赖 |
| Bridge（适配层） | 软件包 | 位于 `quartz` feed，将纯 LuCI 单体插件的底层操作封装为标准 ubus API |
| 受控 Fork | 机制 | 承载第三方适配改动的本组织 fork：`main` 保持上游镜像、适配走 `quartz` 分支、发布锁 `vX.Y.Z-quartzN` tag（§4.7） |

> 本文正文统一使用「仓库全名 + feed 标识」的写法（如 `QuartzWrt-Packages`（`quartz` feed）），不再混用 `quartz-packages`/`thirdparty-packages` 等历史写法。

---

## 1. 项目执行摘要 (Executive Summary)

**QuartzWrt** 是一个专注于现代化交互体验、移动端联动与蜂窝/5G 模组管理的 OpenWrt 衍生发行版。本项目通过剥离沉重的底层硬件适配包袱，将研发精力聚焦于**消费级 UI 体验**、**无缝的 App 生态联动**与**基于 qmodem 的蜂窝能力**。

项目采用严格的 **Overlay（覆盖）架构** 与 **双 Feed（双软件源）策略**，将 ImmortalWrt 视为只读基座，通过独立的第三方包收集库与自有核心功能库，结合自动化 CI/CD 流水线，确保系统的高可维护性、稳定性和上游同步能力。

### 核心交付物
1. **Quartz Theme & Dashboard**：具备“石英”质感（毛玻璃/暗色模式）的现代 Web 仪表盘。
2. **Quartz App**：跨平台移动端应用，支持局域网自动发现与安全的远程管理。
3. **双 Feed 软件源**：分离的 `QuartzWrt-Packages`（核心特色）与 `QuartzWrt-ThirdParty`（社区优秀插件）。
4. **Automated Builder**：基于 GitHub Actions 的全自动固件构建与签名流水线。
5. **Cellular / 5G 模组管理**：以 qmodem 为基座，覆盖模组信息、信号/小区、拨号、SIM/短信、AT 调试与流量统计，并对 FNet3399 + RG520N-EU 做设备级适配。

---

## 2. 核心设计理念 (Design Philosophy)

*   **做减法 (Less is More)**：不做全品类硬件适配，但蜂窝/5G 模组是当前核心场景之一——以 qmodem 为统一基座，围绕 FNet3399 等目标设备做深度适配，而非铺开所有 5G/CPE 硬件。
*   **解耦 (Decoupling)**：UI 皮肤与数据聚合分离；前端渲染与后端逻辑分离；**自有核心代码与第三方收集代码分离**。
*   **不造轮子 (Don't Reinvent the Wheel)**：远程穿透依赖 Tailscale/ZeroTier，推送依赖第三方通道，基座依赖 ImmortalWrt。

---

## 3. 系统架构设计 (System Architecture)

### 3.1 Overlay 架构与双 Feed 设计

**核心原则：绝对不修改上游 ImmortalWrt 源码。** 所有定制内容通过独立的 Feed 叠加，并严格区分“自有核心”与“第三方收集”。

#### 仓库拓扑 (Multi-Repo)
*   `QuartzWrt-Builder` (主构建仓库)：包含 `.config` 种子、`feeds.conf`、构建脚本、补丁。
*   `QuartzWrt-Packages`（**`quartz` Feed**）：仅包含 QuartzWrt 专属研发的核心代码。
*   `QuartzWrt-ThirdParty`（**`thirdparty` Feed**）：作为社区优秀第三方软件包的“收集器”和“适配层”。

#### 第三方包集成三大原则
1.  **物理隔离 (Physical Isolation)**：严格区分“自有核心代码”与“第三方收集代码”，通过双 Feed 架构实现物理仓库隔离。
2.  **能力下沉与多端复用 (Backend Decoupling)**：App 和 Dashboard 绝不直接解析第三方 LuCI 的 HTML 页面或耦合其 UI 逻辑。所有第三方功能必须抽象为标准 API（ubus/HTTP）供多端调用。
3.  **不可变上游 (Immutable Upstream)**：严禁直接修改上游仓库（不向其提交、不强推、不改写历史）。适配、补丁或 API 桥接通过两条路径承载：**受控 Fork**（§4.7：fork 至本组织、镜像/适配分支分离、锁 tag）或 `quartz` Feed 的独立包（Bridge 适配层 / 再开发）。

#### Feed 目录结构与职责规范

**1. `quartz` Feed (`QuartzWrt-Packages`)** - *保持极简，高度可控*
```text
QuartzWrt-Packages/
├── luci/
│   ├── theme/luci-theme-quartz/         # Quartz 全局主题 (CSS/HTML)
│   └── applications/luci-app-dashboard/ # 概览仪表盘 (Vue/React SPA)
├── utils/
│   ├── quartz-daemon/                   # 数据聚合守护进程 (Go/Rust)
│   └── quartz-app-api/                  # App 专属 RPC 接口与 JWT 认证
├── bridge/
│   └── quartz-xxx-bridge/               # 第三方插件 API 适配层 (模式 B)
└── meta/
    └── quartz-defaults/                 # 元数据包 (依赖聚合与默认配置)
```

**2. `thirdparty` Feed (`QuartzWrt-ThirdParty`)** - *海纳百川，严格锁定版本*
```text
QuartzWrt-ThirdParty/
├── net/
│   ├── openclash/                       # 代理工具 (薄 Makefile + 版本锁定)
│   ├── passwall/                        # 代理工具
│   └── tailscale/                       # 内网穿透
├── utils/
│   ├── dockerman/                       # Docker 管理
│   └── luci-app-ttyd/                   # Web 终端
└── libs/
    └── ...                              # 第三方包所需的特定依赖库
```

> **引入方式约定**：`thirdparty` Feed 中的每个包只放**薄 Makefile**（声明 `PKG_SOURCE_URL` + 锁定版本 + 校验和），源码由 OpenWrt 构建系统下载。**禁止**使用 Git Submodule 引入上游仓库（feeds 本身就是 git 仓库，嵌套 submodule 不会随 `scripts/feeds update` 更新）。**Fork 上游承载适配改动必须遵循 §4.7 受控 Fork 规范**（2026-10-14 用户拍板）：fork 至 `quartzwrt` 组织，`main` 保持上游镜像（只 merge、不放自有提交），适配改动走 `quartz` 分支并打 `vX.Y.Z-quartzN` tag，feed 锁定 tag/commit；发布前同步上游并复验。

> **同名包与基座遮蔽（2026-10-12 实践）**：feeds 同名包**先列者胜**，基座默认 feeds 在 `feeds.conf` 中位于双 Feed 之前——基座已提供的包（如 ImmortalWrt luci feed 自带的 `luci-app-openclash`、`luci-app-dockerman`）会**遮蔽** thirdparty 的同名包。因此：基座/quartz feed 已提供且满足需求的包**一律不收录**，由 `quartz-defaults` 直接 `DEPENDS`；仅收录基座没有的包（如 `luci-lib-docker`）。不能靠 feeds 顺序覆盖基座。

### 3.2 元数据包 (Meta-Package) 机制

`quartz-defaults` 作为总入口，统一声明对两个 Feed 中软件包的依赖：

```makefile
define Package/quartz-defaults
  TITLE:=QuartzWrt Default Configuration and Packages
  DEPENDS:= \
    +luci-theme-quartz \
    +luci-app-dashboard \
    +quartz-daemon \
    +quartz-app-api \
    +openwrt-bandix \
    +luci-app-bandix \
    +quartz-ddns-bridge \
    +luci-app-ddns \
    +luci-app-openclash
endef
```

上例中：`luci-theme-quartz`、`luci-app-dashboard`、`quartz-daemon`、`quartz-app-api`、`quartz-ddns-bridge` 来自 `quartz` Feed；`openwrt-bandix`、`luci-app-bandix`（模式 A 后端+前端）、`luci-app-ddns`（模式 B 本体）、`luci-app-openclash` 来自 `thirdparty` Feed。

> 注意：不要在 `DEPENDS` 续行中写注释（`\` 续行与 `#` 注释的组合容易吞掉下一行）。依赖来源在代码评审时人工核对。

### 3.3 Quartz UI 与 Dashboard 架构

#### 架构拆分
*   **`luci-theme-quartz`**：仅负责全局 CSS 变量、基础骨架、侧边栏。必须解决 Tailwind CSS 全局 reset 对原生 LuCI `cbi` 样式的污染问题（采用 PostCSS 命名空间或 `qz-` 前缀）。
*   **`luci-app-dashboard`**：纯 JS 客户端渲染的单页应用 (SPA)，作为登录后的默认首页。

#### 数据聚合层 (`quartz-daemon`)
为解决 LuCI 传统 Lua 模板并发请求导致的卡顿，引入独立的轻量级守护进程：
*   **技术栈**：**Go**（单一自包含二进制，交叉编译；动态链接系统 musl libc，与 feed 惯例一致——"静态编译"指无额外运行库依赖，非字面静态链接）。实现见 `QuartzWrt-Packages/utils/quartz-daemon/`（DESIGN v1.0，契约 AGGREGATE-API v1 生产者）。
*   **职责**：后台定时采集系统负载、网络吞吐、Docker 状态、在线设备 MAC/IP。
*   **输出**：提供单一的高性能 HTTP/JSON 接口，前端一次请求即可渲染整个 Dashboard。

### 3.4 Quartz App 与通信架构

*   **技术栈**：**定为 Flutter**（与第三方包 API 桥接示例中的 Dart 客户端保持一致；Tauri 作为桌面端备选，不作主栈）。
*   **网络与发现**：局域网通过 mDNS 自动发现；广域网深度集成 Tailscale/ZeroTier 实现安全穿透。
*   **认证与 API 隔离**：开发 `quartz-app-api` (基于 `rpcd`)，摒弃短效 session cookie，采用 JWT Token 或长效 API Key 实现持久化认证。**JWT 建议短时有效 + 刷新机制；长效 API Key 必须支持服务端吊销与轮换。** mDNS 发现后的 TLS 连接建议做证书 pinning；ubus/rpcd 按 namespace 配置 ACL，App 权限统一收敛到 `quartz-app-api`。

---

## 4. 第三方包版本锁定与升级规范

### 4.1 上游版本锁定机制 (Version Pinning)

在 `thirdparty` Feed 中，**严禁**将源码指向第三方仓库的 `master`/`main` 分支头。

#### 为什么必须锁定？
*   **构建可重现性**：确保任何时间、任何人编译出的固件，包含的第三方代码字节级一致，便于 Bug 复现。
*   **CI 稳定性**：防止上游的破坏性更新（如新增依赖、重构目录）导致 QuartzWrt 的 CI 流水线随机变红。
*   **安全与防篡改**：通过 SHA256 校验和防止上游仓库被投毒或 CDN 传输损坏。

#### Makefile 规范示例

❌ **错误做法（移动指针，无校验）**：
```makefile
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/vernesong/OpenClash.git
PKG_SOURCE_VERSION:=master  # 危险：指向分支头，每次构建可能拿到不同代码
```

✅ **正确做法（锁定 Tag + 强哈希校验）**：
```makefile
PKG_NAME:=luci-app-openclash
PKG_VERSION:=0.46.050
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/vernesong/OpenClash.git
PKG_SOURCE_VERSION:=v$(PKG_VERSION)  # 锁定到具体 Release/Tag
PKG_MIRROR_HASH:=a1b2c3d4e5f6...     # 生成源码 tarball 的 SHA256 校验和
```

*   若上游无 Tag、只能锁 commit，则写 `PKG_SOURCE_VERSION:=<完整 commit SHA>` 并补充 `PKG_SOURCE_DATE:=<YYYY-MM-DD>`。
*   **校验和字段说明**：普通文件下载源（tarball 直链）使用 `PKG_HASH`；git 等 VCS 源由构建系统生成 tarball 供镜像分发，其校验和使用 `PKG_MIRROR_HASH`。二者作用相同——锁定源码内容，按下载方式选用。
*   OpenWrt 没有 `PKG_SOURCE_BRANCH` 这个变量，请勿在 Makefile 中使用。

### 4.2 Feed 与基座自身的锁定

版本锁定不止于第三方包——**自有代码同样要锁**，否则可重现性只做了一半：

*   **Feed 锁定**：`feeds.conf` 支持写 commit SHA 代替分支名；CI 在基座默认 feeds **末尾追加**（不替换）两个 Feed 的精确 commit：
    ```conf
    src-git quartz https://github.com/YourOrg/QuartzWrt-Packages.git^<commit-sha>
    src-git thirdparty https://github.com/YourOrg/QuartzWrt-ThirdParty.git^<commit-sha>
    ```
    > **语法注意（2026-10-12 实测）**：`;` 后跟的是**分支名**，`^` 后跟的才是 **commit SHA**（`scripts/feeds` 源码用 `split(/;/)` 与 `split(/\^/)` 区分）。写成 `;`+SHA 会被当作分支执行 `git clone --branch <sha>`，在 GitHub 上报 `Remote branch ... not found` 直接失败。
*   **基座锁定**：`QuartzWrt-Builder` 必须记录所用 ImmortalWrt 的**分支 + 精确 commit**，不随上游滚动。
*   **基座自带 feeds 不锁（2026-10-16 拍板）**：基座 `feeds.conf.default` 的 packages/luci/routing/telephony/video 保持**分支追踪**（不写 `^SHA`）——发行版价值在自有功能与 App 联动、对基座改动少，上游修复自动跟进即可。漂移以每次构建/发布产出的 `feeds.buildinfo`（七条 feed 的解析 SHA，随 Release 资产）留痕；构建期由 Gate A（装配行必须存活）兜底（WORKPLAN 坑位 #56）。需要复现或二分时，用 `feeds.buildinfo` 里的 SHA 临时钉住对应 feed。
*   **Bump 机制**：定时 CI job（每周）检查两个 Feed 与基座的上游更新，自动提交 bump PR，CI 通过后合并——参考 Dependabot 的运作方式。**已落地（2026-10-14）**：`.github/workflows/bump.yml`（每周一 + 手动；轻量检查 + 开 PR，**不触发构建**——合并前按 PR 检查单做本地全量 / 手动 CI 权威验收；另附受控 Fork 上游发版观察与**基座 feed 漂移周报**——对照最近 Release 的 `feeds.buildinfo` 报告漂移量，只报告不动作）。

### 4.3 第三方包版本升级工作流

1. 日常保持锁定，CI 稳定运行。
2. 定时 CI job 对比上游最新 Release/Tag 与当前锁定版本，发现更新自动开 PR。
3. 使用官方 `maintainer-tools/update_git_source_package.sh` 半自动更新 `PKG_SOURCE_VERSION`/`PKG_SOURCE_DATE`/`PKG_MIRROR_HASH`，避免手工计算哈希出错。
4. 触发 CI 编译与自动化测试，通过后合并至主分支。

### 4.4 运行时资源锁定（构建期锁定的边界）

构建期 `PKG_*_HASH` **管不到运行时下载的资源**。OpenClash/PassWall 的代理核心二进制、GeoIP 数据库等是在设备运行时下载的，这部分同样需要治理：

*   建立**运行时资源清单**：每个插件声明其运行时下载项（URL、版本、SHA256、镜像源）。
*   `quartz-daemon` 或 Bridge 通过 API 暴露各插件核心/规则库的**版本与更新状态**，供 App/Dashboard 展示与触发更新。（WP-4 v1 已接入版本读取：`services.<id>.<field>` 开放映射，如 `openclash.core`；**更新状态比较需联网**，随本清单治理落地，触发动作归 WP-5/Bridge。）
*   运行时下载一律走 QuartzWrt 可控的镜像源，并校验 SHA256。

### 4.5 同名包冲突处理规则

两个 Feed 存在同名包（如都提供 `luci-app-docker`）时：

1.  **默认规则**：在 `thirdparty` Feed 中**重命名冲突包**（如 `luci-app-docker-thirdparty`），从源头消除歧义。
2.  **兜底手段**：`feeds.conf` 中先列出的 Feed 优先级更高（`quartz` 在前即可覆盖 `thirdparty`）。但历史上 OpenWrt 在重复包的依赖解析上出过 bug，顺序只作为最后手段，不可依赖。
3.  **CI 强制检查**：流水线中增加同名包扫描步骤（`scripts/check-duplicate-packages.sh`，本地 `build-local.sh` 与 CI 共用），发现冲突直接让构建失败。扫描三类冲突：① `quartz` ↔ `thirdparty` 同名（PKG_NAME）；② **我方包目录名与基座 feed 重复**——`include/scan.awk` 按 Makefile 路径最后一段（目录名）去重，重复时整包被静默丢弃（WORKPLAN 坑位 #46）；③ **我方 PKG_NAME 与基座 feed 包重复**——feeds 安装「先列者胜」（基座 feed 在 `feeds.conf` 中先列），基座版本胜出、我方成死代码（WORKPLAN 坑位 #11）。扫描深度/过滤与构建系统一致（`include/scan.mk` 的 `SCAN_DEPTH=5` + `BuildPackage|KernelPackage|Build/DefaultTargets`）。**预装包 manifest 断言**：`quartz-defaults` DEPENDS 增删须同步 `scripts/check-manifest.sh` 的公共断言列表（本地/CI 共用）。

### 4.6 设备适配层（devices/，2026-10-14 立）

**原则：不改基座仓库、不动既定 x86_64 默认目标**——设备（硬件目标）差异一律收敛在 Builder 的
`devices/<设备名>/` 目录，对锁定基座做非侵入叠加：

```text
devices/<设备名>/
├── device.env        # 元数据：目标/子目标/架构/U-Boot 变体/manifest 设备断言/镜像匹配式
├── seed.config       # 设备 .config 种子（首次构建后以 diffconfig 回填，同 §4.2 锁定纪律）
├── patches/*.patch   # 对锁定基座的非侵入补丁（如 uboot-rockchip 目标注册、armv8 设备定义）
└── files/            # 原样投放（镜像式覆盖到构建树：内核 DTS、U-Boot src overlay 等）
```

*   **应用方式**：`scripts/apply-device.sh <基座树> <设备名>`（本地与 CI 共用）——补丁目标文件先复位
    （幂等、可重复运行），按序 `git apply`，`files/` 原样覆盖。设备补丁基于锁定 commit 逐字节可复现；
    **基座 bump 后必须重验设备补丁**（apply 失败即构建失败，属预期护栏）。
*   **构建入口**：`scripts/build-local.sh --device <名>` 与 CI `workflow_dispatch` 的 `device` 输入
    （§7.1）；留空 = x86_64 默认目标。目标切换由 `$WORK_DIR/.quartz-target` 戳记护栏自动
    `make dirclean`（防 staging_dir/build_dir 跨架构混用）。
*   **设备构建验收**（三合一，经 `scripts/check-manifest.sh` 与 CI 步骤共用）：公共 manifest 断言
    （quartz 五关键包在列 + docker 反向断言）+ 设备断言（`device.env` 的 `DEVICE_MANIFEST_PACKAGES`）
    + 成品镜像存在性（`DEVICE_IMAGE_GLOB`，如 `*erya_fnet-3399*squashfs-sysupgrade.img.gz`）。
*   **硬件验收边界**：本层只保证"构建侧适配"（设备被识别、U-Boot/内核 DTB/镜像正确产出）；
    真机刷写与首启验收由设备侧流程完成（x86 的 QEMU 预览台不适用于 ARM 设备镜像）。
*   **当前设备**：
    *   `erya_fnet-3399`（Erya FNet3399，RK3399，rockchip/armv8；适配素材来自 vendor 适配包
        `Fnet资料`）。蜂窝能力以 qmodem 为基座并已预装（受控 Fork `quartz2` 承载 `lang` 等
        适配；daemon `cellular`、app-api `qmodem.*`、App 蜂窝 tab 已接入）；设备细节见
        `devices/erya_fnet-3399/README.md`。
    *   `hiveton_h5000m`（Hiveton H5000M，MT7987A，mediatek/filogic，WiFi 7 + M.2 USB 5G）。
        基座原生支持、无需厂商补丁；完整 `quartz-defaults` + qmodem 5G 栈 + fancontrol
        保守曲线，`std`/`docker` 双变体；产物为 `sysupgrade.bin`。设备细节见
        `devices/hiveton_h5000m/README.md`。

### 4.7 受控 Fork 规范（2026-10-14 立，用户拍板）

**适用**：上游结构不适配薄 Makefile（打包仓库型 / 预编译二进制型 / 多包 feed 型），或需要 QuartzWrt 适配改动（主题对齐、i18n、App 联动、探针投放）时——用 fork 承载改动；**禁止把上游文件复制进本仓库**（会漂移、不可 diff、不可同步）。

**纪律**：

1. **fork 至 `quartzwrt` 组织**，仓库名与上游一致（保留 fork 网络关系，便于对照与同步）；
2. **分支分离**：`main` 保持上游镜像（只做 fast-forward/merge，不放自有提交）；适配改动走 `quartz` 分支；发布打 `vX.Y.Z-quartzN` tag；**feed 锁定 tag/commit，不锁分支**；
3. **同步纪律**：上游发版或 QuartzWrt 发布前 → merge 上游 → rebase 适配分支 → 单包编译 + 验收复验；有价值的改动尽量 PR 回上游，减少长期分叉；
4. **登记**：fork 清单与同步状态登记在 `QuartzWrt-ThirdParty/docs/FORKS.md`（上游→fork 对应、锁定 tag、改动摘要、上次同步日期）；
5. **归口**：活跃上游的适配版登记在 `thirdparty`（源指 fork）；分叉深到"再开发"程度（上游停更/大改）时迁 `quartz` Feed 独立包（WP-10 模式）；
6. **feed 形态（三选，本项目采用 ③）**：① thirdparty 薄 Makefile 指向 fork（需复刻上游安装规则，易漂移）；② fork 仓库作为独立 feed 行追加进 `feeds.conf.extra`（零复制，但 feed 数量与 CI 覆盖面增加）；③ **镜像进 `QuartzWrt-ThirdParty`（采用）**——受控 fork 或上游直取的整仓/子集内容镜像进本仓库子目录（同步脚本 `scripts/sync-mirrors.sh` + `docs/FORKS.md` 台账；可按条目排除不需要的包目录，如基座已提供的同名包），**feed 仍只有 `quartz`/`thirdparty` 两条、锁定沿用 thirdparty commit**；fork 保留为上游跟踪 + 适配分支的改动脉络（无适配需求的上游直取、不建 fork）。

---

## 5. 第三方包集成与 App 联动模式

为了让 Quartz App 和 Dashboard 能够使用第三方插件的功能，必须将其核心能力 API 化。根据第三方包的架构成熟度，分为两种集成模式：

### 模式 A：原生 API 驱动 (Native API-Driven) —— 【理想模式】

**适用对象**：自带独立后端守护进程，且原生暴露标准 ubus/HTTP API 的插件。
**典型案例**：`openwrt-bandix` (Rust+eBPF 后端) + `luci-app-bandix` (纯前端)。

**集成方案**：
1.  **`thirdparty` Feed**：同时收录后端包 (`openwrt-bandix`) 和前端包 (`luci-app-bandix`)，并严格保持两者版本一致。
2.  **App/Dashboard 对接**：**零适配成本**。App 和 `quartz-daemon` 直接通过标准 `ubus` 协议调用后端暴露的接口。
    ```dart
    // App 端直接调用 bandix 原生 ubus API
    final devices = await ubus.call('bandix', 'get_devices', {});
    await ubus.call('bandix', 'set_limit', {'mac': '...', 'up': 1024});
    ```
3.  **优势**：无需编写任何中间层，上游更新只要 API 不变，App 端完全无感。

**实践判据（2026-10-18 增补，用户授权）**：模式 A/B 的分界**不看「是否自带后端守护进程」，而看「该接口是否为程序化集成而设计」**——返回是否结构化稳定、写面是否有语义保证与结构化错误、是否自带缓存与能力声明。两个判例：

- `luci-app-bandix`：自带 Rust/eBPF 后端与 rpcd，但其 rpcd 面向 UI（核心不可达时**伪造成空设备表**、写面无语义保证）→ 判为**模式 B**，建 `quartz-bandix-bridge`（WP-8）；
- `luci-app-qmodem`：自带**结构化 rpcd**（44 方法方法表 + 每方法参数声明 + 10s `try_cache` + 自带 acl.d），LuCI 前端为纯 JS → 判为**模式 A**，**直接消费、不建 bridge**（读 = daemon 采集器唯一收口；写 = app-api `ubusfwd` 转发条目表；见 `QuartzWrt-App/docs/W6.12-CELLULAR-DESIGN.md` §3.0）。

**不建 bridge 时的三个替代落点**（避免职责真空）：① 读契约稳定 → 消费侧采集器（上游字段变化只改一处）；② 写契约/校验/审计 → app-api 转发条目表；③ 集成默认值（默认开启、NVM 持久化、定时任务等）→ **设备/配置层**（`devices/<机型>/` uci-defaults 或 preinstall 层）。**回头建 bridge 的条件**：需跨机型写面语义归一、需一次调用组合多步业务、或需向非 root 的 LuCI 会话开放这些能力（ACL 场景）。

### 模式 B：Bridge 适配层模式 (Bridge Adapter) —— 【兜底模式】

**适用对象**：纯 LuCI 单体应用，所有逻辑（如 `os.execute` 执行 shell 命令）都写在 Lua 控制器中，无独立后端。
**典型案例**：部分老旧的 DDNS 插件、简单的 Wake-on-LAN 插件。

**集成方案**：
1.  **`thirdparty` Feed**：保持第三方插件原始代码不变，仅做版本锁定。
2.  **`quartz` Feed (Bridge 开发)**：在 `QuartzWrt-Packages` 的 `bridge/` 目录开发一个轻量级的 `rpcd` 脚本或独立微服务（如 `quartz-xxx-bridge`），将第三方插件的底层操作封装为标准 ubus API。
    ```lua
    -- /usr/libexec/rpcd/quartz_xxx_bridge (位于 quartz feed)
    -- 封装对第三方插件底层脚本的调用，输出标准 JSON
    -- 安全要求：所有入参必须白名单校验，严禁直接拼接进 shell 命令
    ```
3.  **App/Dashboard 对接**：App 只与 `quartz-xxx-bridge` 交互，绝不直接调用第三方插件的内部逻辑。
4.  **优势**：将第三方插件视为“黑盒”，通过薄薄的适配层隔离上游代码重构对 App 带来的影响。

---

## 6. 第三方包准入评估清单 (Checklist)

在将新的第三方软件包引入 `thirdparty` Feed 之前，开发者必须完成以下评估：

- [ ] **架构评估**：该插件是“前后端分离（模式 A）”还是“单体 LuCI（模式 B）”？如果是后者，是否已评估开发 Bridge 适配层的工作量？
- [ ] **上游活跃度**：上游仓库是否仍在维护？最近一次提交/Release 是什么时候？
- [ ] **版本锁定**：是否已在 Makefile 中配置固定的 `PKG_SOURCE_VERSION`（Tag/commit，必要时含 `PKG_SOURCE_DATE`）和准确的校验和（`PKG_HASH`/`PKG_MIRROR_HASH`）？
- [ ] **依赖冲突**：该插件的依赖树是否与 QuartzWrt 现有组件（或 ImmortalWrt 基座）存在冲突（如不同版本的 OpenSSL、iptables/nftables 混用）？
- [ ] **内核/硬件前提**：eBPF 类插件（如 bandix）需确认目标设备的**内核版本与 BTF 支持**，不满足的机型要有降级方案。
- [ ] **App 联动可行性**：该插件提供的功能，是否具备通过 API 暴露给移动端 App 的实际使用场景和价值？
- [ ] **许可证兼容性**：上游许可证（GPL/闭源）是否与 QuartzWrt 的再分发策略一致？
- [ ] **供应链审计**：插件是否内嵌预编译二进制？二进制来源与校验方式是什么？运行时下载资源（核心、规则库）是否已纳入运行时资源清单（§4.4）？
- [ ] **Fork 判定**：是否需要适配改动（主题/i18n/App 联动），或上游结构不适配薄 Makefile（打包仓库型/预编译二进制型/多包 feed 型）？需要则按 §4.7 建受控 Fork（登记 `FORKS.md`）；不需要则保持薄 Makefile 直指上游。

---

## 7. 软件工程与 CI/CD 规范

### 7.1 自动化构建流水线 (GitHub Actions)

**发布通道（2026-10-15 修订，用户拍板「本地构建结果也可正常发 Release」）**：**CI 与本地构建是等价的两条构建通道**——同一基座/双 Feed 锁定、同一把稳定签名密钥（CI 走 Secrets、本地走 `QUARTZ_SIGNING_DIR`）、同一套门禁（同名包检查 / manifest 断言 / `scripts/verify-signing.sh` 签名校验，见 §7.4 与 Builder `docs/SIGNING-OTA.md` §11）；**发布件可来自任一通道**，但**必须**通过上述门禁（`scripts/release-local.sh` 内置硬门禁：签名校验不过即拒绝发布）。一致性边界：包版本为确定性（由 feed 提交派生，两通道逐字相同）、签名同一把（设备互认）；镜像**跨机逐字节一致不承诺**（宿主工具链不同），需要时可设 `SOURCE_DATE_EPOCH` 做同机可复现构建，发布件以随附 `sha256sums` 为准。CI 仍保留为**干净环境权威验收**（跨环境核对 / 基础设施与设备适配重大变更后复验）。
**触发策略（2026-10-12 起）**：CI 仅手动触发（`workflow_dispatch`），不随 push/PR 自动运行；定时构建取消（基座与双 Feed 已锁定 SHA，计划构建只会重复同一状态）；日常构建验证走本地 `scripts/build-local.sh`。

**CI 核心 Pipeline:**
1.  **Checkout**: 拉取 `QuartzWrt-Builder` 与 ImmortalWrt 基座（锁定分支 + 精确 commit，见 §4.2）。
2.  **Feeds Inject**: 在基座默认 `feeds.conf` **末尾追加** `quartz` 与 `thirdparty` 两行（保留基座 packages/luci 等 feed，不得整体覆写，否则 luci-base 等基础包缺失；锁定 commit，见 §4.2）。
3.  **Update & Install**: 执行 `./scripts/feeds update -a && ./scripts/feeds install -a`。
4.  **Duplicate Check**: 同名包 / 基座遮蔽扫描（含基座 feed，见 §4.5），发现冲突即失败。
5.  **Device Apply**: 设备适配层应用（`scripts/apply-device.sh`，`device` 输入非空时；见 §4.6）。
6.  **Config & Build**: 加载 `.config`（设备构建用 `devices/<名>/seed.config`）-> `make defconfig` -> `make -j$(nproc)`。
7.  **Manifest Verify**: 公共断言（= `quartz-defaults` DEPENDS 全清单在列 + docker 反向断言）+ 设备断言（`scripts/check-manifest.sh`）+ 设备成品镜像存在性（§4.6）。
8.  **Sign & Release**: 构建前注入稳定签名密钥（§7.3：Secrets → 构建树），构建后 `scripts/verify-signing.sh` 强校验（索引签名 key id / 公钥载荷 / feed 列表）；`publish=yes` 时经 `scripts/publish-feed.sh` 整理 feed + OTA 清单并同步到托管（S3 兼容，如 Cloudflare R2）。打包上传至 GitHub Releases。

### 7.2 编译优化与缓存

*   **ccache**：构建配置中启用 `CONFIG_CCACHE`，CI 中持久化 ccache 目录。
*   **外置缓存**：GitHub Actions 缓存有 10GB 上限，`build_dir` 与 `toolchain` 等大体积缓存放外部 S3/R2，并明确失效策略（按基座 commit 版本化缓存键）。
*   **预下载**：缓存 `dl/` 目录，避免每次构建重复下载第三方源码 tarball。

### 7.3 包签名、包管理器与 OTA

*   **包管理器**：**已定案 apk**（基座锁定 ImmortalWrt 25.12，apk 体系）。
*   **签名密钥**：apk 体系的签名密钥为 **EC prime256v1（P-256）密钥对**（构建树内固定名 `private-key.pem`/`public-key.pem`；**未注入时基座为每个全新构建树自生成临时密钥**，故发布构建必须注入稳定密钥）。**签的是各 feed 的 `packages.adb` 索引**（`apk mkndx --sign`），单包不签名、完整性由索引哈希链保证；索引签名块 key id = sha512(EC 原始点)[:16]。私钥存放于 GitHub Secrets（`APK_SIGNING_PRIVATE_KEY`，CI 构建前注入构建树），公钥随 `quartz-defaults` 预置（`/etc/apk/keys/quartz.pem`，与 base-files 自动投放的 `public-key.pem` 并存）。工具：Builder `scripts/gen-signing-key.sh`（生成）/`inject-signing-key.sh`（注入+一致性校验）/`verify-signing.sh`（构建后强校验）；完整设计见 Builder `docs/SIGNING-OTA.md`。usign（opkg 时代方案）不用于包签名。
*   **固件签名**：apk 时代 sysupgrade 的 usign/ucert 镜像签名路径在基座镜像中失效（镜像未装 `ucert`，验签函数直接放行）——**镜像真实性由 OTA 通道承担**：OTA 版本清单用 usign（Ed25519，公钥 `/etc/quartz-ota.pub`）签名 + 清单内镜像 sha256 校验 + `sysupgrade` 平台/元数据预检（`-T`）。清单与镜像由 `scripts/publish-feed.sh` 随 feed 一并发布（`ota/<board>/<subtarget>.json(.sig)`）。
*   **OTA 通道（已定案，2026-10-14）**：v1 = **自定义 OTA 通道**（自有 feed 托管 + 签名清单 + `quartz-ota-update`，端到端演练通过）；**ASU 暂不采用**（上游 ASU 只从官方 feed 构建，无法携带 Quartz 定制与设备适配；自建 ASU 服务为 v2 候选，形态见 `docs/SIGNING-OTA.md` §7）。App 触发入口经 WP-5 动作白名单封装（v2）。

### 7.4 本地构建工作流（开发迭代）

CI 与本地构建分工：**CI 覆盖干净环境可重现性与权威验收**，**本地覆盖快速迭代与发布**（`scripts/release-local.sh`：构建 → 签名硬门禁 → 打包 → `gh release create`）；两者步骤与门禁保持一致（同步义务见下），产物互认（同锁定、同密钥——§7.1）。

*   **脚本**：`scripts/build-local.sh` —— 复刻 §7.1 流水线的全部关键步骤：基座检出（锁定 commit）→ feeds 追加注入 → `feeds update/install` → 同名包检查 →（设备构建）设备适配层应用 → `seed.config` + `make defconfig` → `make` → 产物收集与 manifest 校验（公共断言与设备断言经 `scripts/check-manifest.sh` 共用），产物落本地目录。**设备构建**：`--device <名>`（§4.6），产物落 `artifacts-local/<设备名>/`。
*   **镜像格式与变体（2026-10-16 用户指令）**：**只出 squashfs 镜像**（`config/common.config` 关闭 `CONFIG_TARGET_ROOTFS_EXT4FS`，ext4 系列不再生成）；固件分**两个变体**——`std`（标准版）与 `docker`（预装 docker 栈，变体层 `config/preinstall/docker.config` + `docker.files` 配方）。`--variants std,docker`（默认两个，构建顺序固定 **docker 先、std 后**，构建树停在标准版）；docker 产物落 `<产物目录>-docker`、文件名带 `-docker` 标记（插在 `squashfs-`/`.manifest`/`.buildinfo` 标记之前，保持既有 glob 口径）。CI `build.yml` 的 `docker` 输入同款（默认 both）；GitHub Release 两变体都发，**软件源/OTA 通道只发标准版**（`publish-feed.sh` 有 docker 变体护栏）。详见 Builder `docs/SIGNING-OTA.md` §14。
*   **性能**：32 核开发机建议 `-j16`（15GB 内存边界，避免并行编译 OOM）；首次全量约 45–90 分钟，保留 `build_dir`/`staging_dir`/ccache 后增量重编为分钟级。单包迭代用 `make package/feeds/<feed>/<pkg>/{clean,compile}`。
*   **前置条件**：OpenWrt 构建依赖齐全（build-essential、gawk、gettext、libncurses-dev 等；注意 `/usr/bin/awk` 不能指向 mawk；另需 `zstd`）；构建目录必须位于 Linux 文件系统（如 `/home`），WSL 下禁用 `/mnt/c`（大小写不敏感会破坏构建）。**WSL 额外注意**：须剔除 PATH 中的 Windows 条目（`/mnt/c/...`，含空格路径）——GNU find 的 `-execdir` 安全检查会因相对/含空格路径直接报错（实测触发于 rust host 包安装阶段）；`scripts/build-local.sh` 已内置 PATH 净化。
*   **同步义务**：CI workflow 与本地脚本的步骤必须保持一致，任一侧变更需同步另一侧。

---

## 8. 关键技术决策与待决事项 (Open Questions)

### 已决策项

| 模块 | 决策 | 依据 |
| :--- | :--- | :--- |
| App 技术栈 | Flutter | 与第三方 API 桥接示例（Dart）一致；Tauri 仅作桌面端备选 |
| 第三方包引入方式 | 薄 Makefile + 版本锁定 | 禁止 Submodule/Fork，见 §3.1 |
| 同名包冲突 | 优先重命名 + CI 强制检查 | 见 §4.5 |
| 包管理器 | apk | 基座定为 ImmortalWrt 25.12（apk 体系），见 §7.3 |
| 签名体系 | apk EC P-256 稳定密钥（索引签名 `packages.adb`；私钥 → Secrets，公钥 → `quartz-defaults` 预置） | 见 §7.3；WP-9 落地（Builder `docs/SIGNING-OTA.md`） |
| OTA 通道 | 自定义 OTA 通道（usign 签名清单 + 镜像 sha256 + sysupgrade）；ASU 暂缓（v2 候选，须自建服务） | WP-9 评估 + 端到端演练（2026-10-14）；见 Builder `docs/SIGNING-OTA.md` §6/§7 |
| 本地构建 | 方案一：脚本复刻 CI 步骤（`scripts/build-local.sh`），定位于开发迭代 | 正式产物仍以 CI 为准，见 §7.1、§7.4 |
| CI 触发 | 仅手动 `workflow_dispatch`（不随 push/PR 自动运行） | 日常验证走本地构建；CI 用于发布前/重大变更后的权威验收，见 §7.1 |
| UI 隔离 | Tailwind utilities 采用 `qz:` 前缀（v4 变体语法）+ `source(none)` 精确扫描；主题 cascade.css 入层（层序 theme < base < qz-theme < components < utilities），preflight 归 base 并辅以显式中和规则 | 2026-10-12 实测通过（WP-2 spike，`dev/spike/tailwind/RESULTS.md`）：生产配置零污染且 utilities 正常生效 |
| Daemon 技术栈 | **Go**（单一自包含二进制、零第三方依赖）| 契约 AGGREGATE-API v1 生产者；WP-4 `DESIGN.md` v1.0（2026-10-12 定案并实现） |

### 待决事项

| 模块 | 待决事项 (Open Questions) | 建议方案 / 思考方向 |
| :--- | :--- | :--- |
| **App 推送** | 路由器在内网，如何向 App 推送断网/告警消息？ | 固件端预留 Webhook 接口，集成 Bark / PushDeer / Telegram Bot 等第三方推送服务。 |

---

## 9. 里程碑与交付计划 (Milestones)

### Phase 1: 基础设施与双 Feed 骨架 (Week 1-2)
- [ ] 确立 QuartzWrt 品牌视觉 (Logo、UI 设计稿、CSS 变量规范)。
- [ ] 搭建 `Builder`、`QuartzWrt-Packages` 与 `QuartzWrt-ThirdParty` 三个仓库骨架。
- [ ] **确定包管理器（apk）并初始化 apk 签名密钥对（EC P-256，§7.3）。**
- [ ] 跑通 GitHub Actions CI/CD 流水线，实现双 Feed 注入（含 commit 锁定与同名包检查）与 ImmortalWrt 原版固件的自动编译。
- [ ] 交付本地构建脚本 `scripts/build-local.sh`（与 CI 步骤一致，§7.4）。
- [ ] 搭建前端脚手架 (Vite + Tailwind)，验证 CSS 隔离方案。

### Phase 2: Quartz UI 与数据聚合 (Week 3-5)
- [ ] 完成 `luci-theme-quartz` 基础换皮（侧边栏、顶部导航、表单样式）。
- [ ] 开发 `quartz-daemon` (Go)，实现系统状态、网络吞吐的数据聚合 API。
- [ ] 开发 `luci-app-dashboard`，对接后端数据，实现高颜值概览页面渲染。

### Phase 3: App 开发与生态联动 (Week 6-9)
- [ ] 开发路由器端 `quartz-app-api` (JWT 认证与接口隔离、吊销机制)。
- [ ] 启动 Flutter App 开发，实现局域网 mDNS 发现与基础控制。
- [ ] 集成 Tailscale/ZeroTier，打通 App 远程管理链路。

### Phase 4: 打磨、测试与首发 (Week 10-12)
- [ ] 多硬件目标测试 (x86_64, 主流 ARM 软路由如 R4S/R5S)。
- [ ] 完善 `thirdparty` Feed 的版本锁定、自动 Bump 与 CI 缓存策略调优。
- [ ] **运行时资源锁定清单上线，核心/规则库版本状态接入 API。**
- [ ] 建立软件源 apk 索引签名与固件 OTA 签名清单机制，落地 OTA 升级通道原型（ASU 评估结论见 §7.3）。
- [ ] **发布 QuartzWrt v1.0.0 MVP 版本。**

---

> **架构师备注**：双 Feed 架构确立后，近期的首要任务是**初始化 `QuartzWrt-ThirdParty` 仓库**，并以“薄 Makefile + 版本锁定”的方式引入 2-3 个最常用的第三方插件（如 OpenClash、DockerMan），跑通一次包含第三方插件的 CI 编译。这能提前踩平第三方包依赖冲突与运行时资源治理的坑。

> **文档维护说明**：本规范随 QuartzWrt 架构演进而更新，文档存放在 `QuartzWrt-Builder` 仓库的 `docs/` 目录，经 PR Review 修改。任何对本规范的偏离（如特殊情况需修改第三方源码），必须在 PR 中提供详细的技术说明并获得架构师 Review。
