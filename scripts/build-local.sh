#!/usr/bin/env bash
# QuartzWrt 本地构建脚本（docs/TDD.md §7.4）
#
# 复刻 .github/workflows/build.yml 的关键步骤，用于开发迭代与调试：
#   基座检出（锁定 commit）→ feeds 追加注入 → update/install → 同名包检查
#   → ccache → seed.config + defconfig → make → manifest 校验 → 产物收集
#
# CI 是权威构建与发布通道；本脚本产物仅用于本地调试，禁止作为发布件分发。
# 与 CI 的步骤必须保持一致，任一侧变更需同步另一侧（docs/TDD.md §7.4）。
#
# 用法: scripts/build-local.sh
# 环境变量:
#   QUARTZ_WORK_DIR       构建工作目录（默认 <Builder 仓库>../build）
#   QUARTZ_ARTIFACTS_DIR  产物输出目录（默认 <Builder 仓库>../artifacts-local）
#   JOBS                  make 并行度（默认 16；本机 15GB 内存勿再调高）

set -euo pipefail

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${QUARTZ_WORK_DIR:-$BUILDER_DIR/../build}"
BASE_DIR="$WORK_DIR/immortalwrt"
ARTIFACTS_DIR="${QUARTZ_ARTIFACTS_DIR:-$BUILDER_DIR/../artifacts-local}"
JOBS="${JOBS:-16}"
CCACHE_DIR="${CCACHE_DIR:-$WORK_DIR/ccache}"

step() { printf '\n==> [%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

# 构建目录必须在 Linux 文件系统上：WSL 下 /mnt/c 大小写不敏感会破坏构建（坑位 #3）
if grep -qi microsoft /proc/version && [[ "$WORK_DIR" == /mnt/* ]]; then
  echo "错误：WSL 下构建目录不能位于 /mnt/*（大小写不敏感），请通过 QUARTZ_WORK_DIR 指定 /home 下的路径。" >&2
  exit 1
fi

# 依赖预检：与 docs/TDD.md §7.4 前置条件一致（awk 不能是 mawk）
step "构建依赖预检"
for cmd in time libtoolize zstd node gawk git file flex bison unzip rsync wget python3; do
  command -v "$cmd" >/dev/null || { echo "错误：缺少 $cmd，请先补齐 OpenWrt 构建依赖（docs/TDD.md §7.4）。" >&2; exit 1; }
done
if [[ "$(readlink -f "$(command -v awk)")" == *mawk ]]; then
  echo "错误：/usr/bin/awk 指向 mawk，请切换为 gawk（update-alternatives --config awk）。" >&2
  exit 1
fi
echo "OK"

# 1. 基座锁定参数（docs/TDD.md §4.2）
step "加载基座版本（config/base.env）"
set -a; . "$BUILDER_DIR/config/base.env"; set +a
echo "$BASE_OWNER_REPO @ $BASE_BRANCH ($BASE_COMMIT)"

mkdir -p "$WORK_DIR"

# 2. 检出 / 更新基座到锁定 commit，不随上游滚动
step "检出 ImmortalWrt 基座到锁定 commit"
if [ -d "$BASE_DIR/.git" ]; then
  git -C "$BASE_DIR" fetch origin "$BASE_BRANCH"
else
  git clone "https://github.com/$BASE_OWNER_REPO.git" "$BASE_DIR"
fi
git -C "$BASE_DIR" checkout "$BASE_COMMIT"

# 3. feeds 注入：在基座默认 feeds.conf 末尾追加双 Feed，不覆写（坑位 #2）
step "注入 feeds.conf（追加双 Feed）"
cp "$BASE_DIR/feeds.conf.default" "$BASE_DIR/feeds.conf"
cat "$BUILDER_DIR/config/feeds.conf.extra" >> "$BASE_DIR/feeds.conf"
tail -n 4 "$BASE_DIR/feeds.conf"

# 4. feeds update / install
step "feeds update + install"
(cd "$BASE_DIR" && ./scripts/feeds update -a && ./scripts/feeds install -a)

# 5. 双 Feed 同名包检查（docs/TDD.md §4.5）
step "同名包检查"
bash "$BUILDER_DIR/scripts/check-duplicate-packages.sh" "$BASE_DIR/feeds"

# 6. ccache（与 CI 同样把构建目录 .ccache 链到持久目录）
step "准备 ccache（$CCACHE_DIR）"
mkdir -p "$CCACHE_DIR"
[ -e "$BASE_DIR/.ccache" ] || ln -s "$CCACHE_DIR" "$BASE_DIR/.ccache"
export CCACHE_DIR

# 7. 配置：种子 + defconfig 补齐默认项
step "加载 seed.config 并 defconfig"
cp "$BUILDER_DIR/config/seed.config" "$BASE_DIR/.config"
(cd "$BASE_DIR" && make defconfig)

# 8. 全量构建（本地用 V=w 减小日志；CI 首次跑通后也将降级）
step "全量构建 make -j$JOBS（首次约 45–90 分钟）"
(cd "$BASE_DIR" && make -j"$JOBS" V=w)

# 9. manifest 校验：与 CI 相同的四包清单（docs/TDD.md §3.2）
step "校验固件 manifest 关键包"
manifest="$(find "$BASE_DIR/bin" -name '*.manifest' | head -1)"
echo "manifest: $manifest"
for p in quartz-defaults luci-app-openclash luci-app-dockerman luci-lib-docker; do
  if grep -q "^${p} " "$manifest"; then
    echo "OK: $p"
  else
    echo "FAIL: $p 不在固件清单中（可能依赖未满足被静默取消选择）" >&2
    exit 1
  fi
done

# 10. 产物收集（与 CI Collect artifacts 一致）
step "收集产物 → $ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR"
find "$BASE_DIR/bin" -type f \( -name '*.img.gz' -o -name '*.manifest' -o -name '*.buildinfo' \) \
  -exec cp {} "$ARTIFACTS_DIR/" \;
cp "$BASE_DIR/.config" "$ARTIFACTS_DIR/dotconfig"

step "完成 ✔ 产物目录: $ARTIFACTS_DIR"
ls -la "$ARTIFACTS_DIR"
