# 💎 QuartzWrt 技术设计文档 (TDD)

**文档版本**: v2.0.0（双 Feed 架构与第三方包集成规范合并版）
**项目代号**: Quartz (石英)
**基座系统**: ImmortalWrt (OpenWrt 衍生版)
**文档状态**: 已确认 (Approved)
**适用范围**: QuartzWrt 固件构建、App 开发、第三方插件引入
**最后更新**: 2026-10-12

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

> 本文正文统一使用「仓库全名 + feed 标识」的写法（如 `QuartzWrt-Packages`（`quartz` feed）），不再混用 `quartz-packages`/`thirdparty-packages` 等历史写法。

---

## 1. 项目执行摘要 (Executive Summary)

**QuartzWrt** 是一个专注于现代化交互体验与移动端联动的 OpenWrt 衍生发行版。本项目通过剥离沉重的底层硬件适配包袱，将研发精力聚焦于**消费级 UI 体验**与**无缝的 App 生态联动**。

项目采用严格的 **Overlay（覆盖）架构** 与 **双 Feed（双软件源）策略**，将 ImmortalWrt 视为只读基座，通过独立的第三方包收集库与自有核心功能库，结合自动化 CI/CD 流水线，确保系统的高可维护性、稳定性和上游同步能力。

### 核心交付物
1. **Quartz Theme & Dashboard**：具备“石英”质感（毛玻璃/暗色模式）的现代 Web 仪表盘。
2. **Quartz App**：跨平台移动端应用，支持局域网自动发现与安全的远程管理。
3. **双 Feed 软件源**：分离的 `QuartzWrt-Packages`（核心特色）与 `QuartzWrt-ThirdParty`（社区优秀插件）。
4. **Automated Builder**：基于 GitHub Actions 的全自动固件构建与签名流水线。

---

## 2. 核心设计理念 (Design Philosophy)

*   **做减法 (Less is More)**：暂不涉足 5G/CPE 等重度硬件适配，专注于 x86 与主流 ARM 软路由的通用体验。
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
3.  **不可变上游 (Immutable Upstream)**：严禁直接修改第三方插件的上游源码。所有适配、补丁或 API 桥接必须通过独立的 `quartz` Feed 包来实现。

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

> **引入方式约定**：`thirdparty` Feed 中的每个包只放**薄 Makefile**（声明 `PKG_SOURCE_URL` + 锁定版本 + 校验和），源码由 OpenWrt 构建系统下载。**禁止**使用 Git Submodule 引入上游仓库（feeds 本身就是 git 仓库，嵌套 submodule 不会随 `scripts/feeds update` 更新）；**禁止** Fork 上游仓库改源码（违反“不可变上游”原则）。确无 Tag 可锁且必须 Fork 的特殊情况，须在 PR 中详细说明理由并经架构师 Review。

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
*   **Bump 机制**：定时 CI job（建议每周）检查两个 Feed 与基座的上游更新，自动提交 bump PR，CI 通过后合并——参考 Dependabot 的运作方式。

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
3.  **CI 强制检查**：流水线中增加同名包扫描步骤——比对两个 Feed 的包目录名，或解析 `scripts/feeds install` 输出的 duplicate 警告，发现冲突直接让构建失败。

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
*   **当前设备**：`erya_fnet-3399`（Erya FNet3399，RK3399，rockchip/armv8；适配素材来自 vendor
    适配包 `Fnet资料`，落地细节与 5G 模组建议（qmodem，未预装、候选归 WP-7）见
    `devices/erya_fnet-3399/README.md`）。

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

---

## 7. 软件工程与 CI/CD 规范

### 7.1 自动化构建流水线 (GitHub Actions)

CI 是**权威构建与发布通道**：正式产物以 CI 编译结果为准，禁止将本地构建产物作为发布件分发。本地构建用于开发迭代与调试（见 §7.4），不替代 CI。**触发策略（2026-10-12 起）：CI 仅手动触发（`workflow_dispatch`），不随 push/PR 自动运行；定时构建取消（基座与双 Feed 已锁定 SHA，计划构建只会重复同一状态）；日常构建验证走本地 `scripts/build-local.sh`，CI 保留给发布前 / 基础设施重大变更后的权威验收。**

**CI 核心 Pipeline:**
1.  **Checkout**: 拉取 `QuartzWrt-Builder` 与 ImmortalWrt 基座（锁定分支 + 精确 commit，见 §4.2）。
2.  **Feeds Inject**: 在基座默认 `feeds.conf` **末尾追加** `quartz` 与 `thirdparty` 两行（保留基座 packages/luci 等 feed，不得整体覆写，否则 luci-base 等基础包缺失；锁定 commit，见 §4.2）。
3.  **Update & Install**: 执行 `./scripts/feeds update -a && ./scripts/feeds install -a`。
4.  **Duplicate Check**: 同名包扫描（见 §4.5），发现冲突即失败。
5.  **Device Apply**: 设备适配层应用（`scripts/apply-device.sh`，`device` 输入非空时；见 §4.6）。
6.  **Config & Build**: 加载 `.config`（设备构建用 `devices/<名>/seed.config`）-> `make defconfig` -> `make -j$(nproc)`。
7.  **Manifest Verify**: 公共断言 + 设备断言（`scripts/check-manifest.sh`）+ 设备成品镜像存在性（§4.6）。
8.  **Sign & Release**: 按 §7.3 的 apk 签名体系对 `.apk` 与固件镜像签名，打包上传至 GitHub Releases。

### 7.2 编译优化与缓存

*   **ccache**：构建配置中启用 `CONFIG_CCACHE`，CI 中持久化 ccache 目录。
*   **外置缓存**：GitHub Actions 缓存有 10GB 上限，`build_dir` 与 `toolchain` 等大体积缓存放外部 S3/R2，并明确失效策略（按基座 commit 版本化缓存键）。
*   **预下载**：缓存 `dl/` 目录，避免每次构建重复下载第三方源码 tarball。

### 7.3 包签名、包管理器与 OTA

*   **包管理器**：**已定案 apk**（基座锁定 ImmortalWrt 25.12，apk 体系）。
*   **签名密钥**：采用 apk 体系要求的 RSA 密钥对（由构建系统 key-build 生成），私钥存放于 GitHub Secrets，CI 自动签名；公钥随 `quartz-defaults` 预置。usign（opkg 时代方案）不再适用。
*   **固件签名**：固件镜像与 `.apk` 包统一走上述签名体系，App/Web 升级前校验。
*   **OTA 通道**：规划 Attended Sysupgrade (ASU) 或自定义 OTA 通道，作为 App 触发固件升级的统一入口；升级流程强制签名校验。

### 7.4 本地构建工作流（开发迭代）

CI 与本地构建分工明确：**CI 覆盖"干净环境可重现性"与发布**，**本地覆盖快速迭代**，两者步骤保持一致。

*   **脚本**：`scripts/build-local.sh` —— 复刻 §7.1 流水线的全部关键步骤：基座检出（锁定 commit）→ feeds 追加注入 → `feeds update/install` → 同名包检查 →（设备构建）设备适配层应用 → `seed.config` + `make defconfig` → `make` → 产物收集与 manifest 校验（公共断言与设备断言经 `scripts/check-manifest.sh` 共用），产物落本地目录。**设备构建**：`--device <名>`（§4.6），产物落 `artifacts-local/<设备名>/`。
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
| 签名体系 | apk RSA (key-build) | 见 §7.3 |
| 本地构建 | 方案一：脚本复刻 CI 步骤（`scripts/build-local.sh`），定位于开发迭代 | 正式产物仍以 CI 为准，见 §7.1、§7.4 |
| CI 触发 | 仅手动 `workflow_dispatch`（不随 push/PR 自动运行） | 日常验证走本地构建；CI 用于发布前/重大变更后的权威验收，见 §7.1 |
| UI 隔离 | Tailwind utilities 采用 `qz:` 前缀（v4 变体语法）+ `source(none)` 精确扫描；主题 cascade.css 入层（层序 theme < base < qz-theme < components < utilities），preflight 归 base 并辅以显式中和规则 | 2026-10-12 实测通过（WP-2 spike，`dev/spike/tailwind/RESULTS.md`）：生产配置零污染且 utilities 正常生效 |
| Daemon 技术栈 | **Go**（单一自包含二进制、零第三方依赖）| 契约 AGGREGATE-API v1 生产者；WP-4 `DESIGN.md` v1.0（2026-10-12 定案并实现） |

### 待决事项

| 模块 | 待决事项 (Open Questions) | 建议方案 / 思考方向 |
| :--- | :--- | :--- |
| **App 推送** | 路由器在内网，如何向 App 推送断网/告警消息？ | 固件端预留 Webhook 接口，集成 Bark / PushDeer / Telegram Bot 等第三方推送服务。 |
| **OTA 通道** | ASU 还是自定义升级服务？ | 优先评估 ASU（社区成熟方案）；自定义方案须完整实现签名校验。 |

---

## 9. 里程碑与交付计划 (Milestones)

### Phase 1: 基础设施与双 Feed 骨架 (Week 1-2)
- [ ] 确立 QuartzWrt 品牌视觉 (Logo、UI 设计稿、CSS 变量规范)。
- [ ] 搭建 `Builder`、`QuartzWrt-Packages` 与 `QuartzWrt-ThirdParty` 三个仓库骨架。
- [ ] **确定包管理器（opkg/apk）并初始化 usign 签名密钥对。**
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
- [ ] 建立固件与软件仓库的 usign 签名机制，落地 ASU/OTA 升级通道原型。
- [ ] **发布 QuartzWrt v1.0.0 MVP 版本。**

---

> **架构师备注**：双 Feed 架构确立后，近期的首要任务是**初始化 `QuartzWrt-ThirdParty` 仓库**，并以“薄 Makefile + 版本锁定”的方式引入 2-3 个最常用的第三方插件（如 OpenClash、DockerMan），跑通一次包含第三方插件的 CI 编译。这能提前踩平第三方包依赖冲突与运行时资源治理的坑。

> **文档维护说明**：本规范随 QuartzWrt 架构演进而更新，文档存放在 `QuartzWrt-Builder` 仓库的 `docs/` 目录，经 PR Review 修改。任何对本规范的偏离（如特殊情况需修改第三方源码），必须在 PR 中提供详细的技术说明并获得架构师 Review。
