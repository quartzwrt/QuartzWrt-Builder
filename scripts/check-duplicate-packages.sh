#!/usr/bin/env bash
# 双 Feed 同名包扫描（docs/TDD.md §4.5）
#
# 同名包会让 feeds 的优先级逻辑变得不可靠（OpenWrt 历史上在重复包的
# 依赖解析上出过 bug）。默认做法是在 thirdparty feed 中重命名冲突包；
# 本脚本在 CI 中强制执行：发现冲突即失败。
#
# 用法: check-duplicate-packages.sh [feeds 目录]   （默认 feeds，在基座树根目录运行）

set -euo pipefail

FEEDS_DIR="${1:-feeds}"
QUARTZ_FEED="${FEEDS_DIR}/quartz"
THIRDPARTY_FEED="${FEEDS_DIR}/thirdparty"

for d in "$QUARTZ_FEED" "$THIRDPARTY_FEED"; do
  [ -d "$d" ] || { echo "错误：未找到 $d（先运行 ./scripts/feeds update -a）"; exit 2; }
done

pkg_names() {
  find "$1" -name Makefile -print0 2>/dev/null |
    xargs -0 -r sed -n 's/^[[:space:]]*PKG_NAME[[:space:]]*[:?]\?=[[:space:]]*\([^[:space:]]*\).*/\1/p' |
    sort -u
}

dups=$(comm -12 <(pkg_names "$QUARTZ_FEED") <(pkg_names "$THIRDPARTY_FEED"))

if [ -n "$dups" ]; then
  echo "❌ 双 Feed 同名包冲突（请在 thirdparty feed 中重命名，见 docs/TDD.md §4.5）:"
  echo "$dups"
  exit 1
fi

echo "✅ 同名包检查通过"
