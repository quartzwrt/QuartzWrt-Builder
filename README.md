# QuartzWrt-Builder

QuartzWrt 主构建仓库：ImmortalWrt 基座锁定、双 Feed 注入、固件构建与签名流水线。

整体设计规范见 [docs/TDD.md](docs/TDD.md)。

## 目录结构

| 路径 | 职责 |
| :--- | :--- |
| `config/base.env` | ImmortalWrt 基座锁定（分支 + 精确 commit） |
| `config/feeds.conf.extra` | 双 Feed 定义（CI 中**追加**到基座 `feeds.conf` 末尾，不替换） |
| `config/seed.config` | `.config` 构建种子（x86_64 起步，最小集） |
| `scripts/check-duplicate-packages.sh` | 双 Feed 同名包扫描（CI 强制项） |
| `.github/workflows/build.yml` | GitHub Actions 全量构建流水线 |
| `docs/TDD.md` | 技术设计文档（唯一权威版本） |

## CI 构建

- 触发方式：push 到 `main`、PR、每周日 02:00 (UTC+8) 定时、手动 `workflow_dispatch`。
- 首次全量构建约 2–6 小时；GitHub Actions 默认磁盘不足，流水线已用 `maximize-build-space` 扩容。
- 公开仓库免费额度无限；若仓库为私有，注意月度 CI 分钟数限制。

手动触发：

```bash
gh workflow run build.yml
```

## 首次跑通后必做（按 docs/TDD.md §4 要求）

1. 用基座树中 `./scripts/diffconfig.sh` 的输出回填 `config/seed.config`。
2. 把 `config/feeds.conf.extra` 中两个 Feed 的 `;main` 换成 commit SHA（格式 `url;<commit-sha>`）。
3. 把各第三方包 Makefile 中的 `PKG_MIRROR_HASH:=skip` 替换为真实校验和（可用 maintainer-tools 或本地 `make package/.../download` 获取）。
4. 将签名私钥加入 GitHub Secrets，按 §7.3 接入签名步骤。

> 注意：`scripts/feeds` 的解析器只把 `#` 后跟至少一个字符的行当注释，**单独的 `#` 行会报语法错误**（见 `config/feeds.conf.extra` 中的说明）。

## 基座升级 / 追随新版

修改 `config/base.env` 的 `BASE_BRANCH`/`BASE_COMMIT`：

```bash
git ls-remote https://github.com/immortalwrt/immortalwrt.git refs/heads/openwrt-25.12
```

改后触发一次全量 CI 验证。

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
make package/feeds/thirdparty/luci-app-openclash/compile
```
