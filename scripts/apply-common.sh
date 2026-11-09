#!/usr/bin/env bash
# QuartzWrt 通用补丁层（跨设备/跨目标，2026-11-09）
#
# 用法: scripts/apply-common.sh <immortalwrt 目录>
#
# 把 config/patches/ 下的文件按镜像路径投放到基座树，例如：
#   config/patches/target/linux/generic/pending-6.12/999-xxx.patch
#   → <基座>/target/linux/generic/pending-6.12/999-xxx.patch
#
# generic/pending-6.12 由 OpenWrt 对所有目标（mediatek/rockchip/x86_64/...）统一应用，
# 因此这里的补丁对 x86_64 与所有设备构建都生效；设备层（devices/）只放机型专属内容。
#
# 幂等：用 .quartz-common-patches 清单记录上次投放的文件，源文件删除后同步清理基座树。
# 本地 build-local.sh 与 CI build.yml 共用本脚本。

set -euo pipefail

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="${1:?用法: apply-common.sh <immortalwrt 目录>}"
SRC="$BUILDER_DIR/config/patches"
MANIFEST="$BASE_DIR/.quartz-common-patches"

[ -d "$BASE_DIR" ] || { echo "错误：基座树不存在：$BASE_DIR" >&2; exit 1; }
[ -d "$SRC" ] || { echo "==> 通用补丁层：config/patches 不存在，跳过"; exit 0; }

echo "==> 通用补丁层：$SRC"

# 清理上一轮投放、但源文件已删除的条目（不触碰基座自带文件）
if [ -f "$MANIFEST" ]; then
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ ! -f "$SRC/$rel" ]; then
      rm -f "$BASE_DIR/$rel"
      echo "    移除过期：$rel"
    fi
  done < "$MANIFEST"
fi

tmp_manifest="$(mktemp)"
trap 'rm -f "$tmp_manifest"' EXIT

while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  mkdir -p "$BASE_DIR/$(dirname "$rel")"
  cp -p "$f" "$BASE_DIR/$rel"
  printf '%s\n' "$rel" >> "$tmp_manifest"
  echo "    投放：$rel"
done < <(find "$SRC" -type f -print0 | sort -z)

mv "$tmp_manifest" "$MANIFEST"
echo "==> 通用补丁层应用完成"
