# QuartzWrt-Builder

QuartzWrt 主构建仓库：ImmortalWrt 基座锁定、双 Feed 注入、固件构建与签名流水线。

整体设计规范见 [docs/TDD.md](docs/TDD.md)。

## 目录结构

| 路径 | 职责 |
| :--- | :--- |
| `config/base.env` | ImmortalWrt 基座锁定（分支 + 精确 commit） |
| `config/feeds.conf.extra` | 双 Feed 定义（CI 中**追加**到基座 `feeds.conf` 末尾，不替换） |
| `config/seed.config` | `.config` 构建种子（x86_64 起步，最小集） |
| `scripts/build-local.sh` | 本地全量构建脚本（复刻 CI 步骤，产物落本地目录，见 docs/TDD.md §7.4） |
| `scripts/check-duplicate-packages.sh` | 双 Feed 同名包扫描（CI 强制项） |
| `.github/workflows/build.yml` | GitHub Actions 全量构建流水线（仅手动触发） |
| `docs/TDD.md` | 技术设计文档（唯一权威版本） |

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
- ⏳ 待办：首次构建成功后，用基座树中 `./scripts/diffconfig.sh` 的输出回填 `config/seed.config`。
- ⏳ 待办：将 apk 签名私钥加入 GitHub Secrets，按 §7.3 接入 CI 签名步骤。

> 注意：`scripts/feeds` 的解析器只把 `#` 后跟至少一个字符的行当注释，**单独的 `#` 行会报语法错误**（见 `config/feeds.conf.extra` 中的说明）。

## 基座升级 / 追随新版

修改 `config/base.env` 的 `BASE_BRANCH`/`BASE_COMMIT`：

```bash
git ls-remote https://github.com/immortalwrt/immortalwrt.git refs/heads/openwrt-25.12
```

改后手动触发一次全量 CI 验证（`gh workflow run build.yml`）。

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
