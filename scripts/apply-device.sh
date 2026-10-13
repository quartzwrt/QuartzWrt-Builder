#!/usr/bin/env bash
# QuartzWrt 设备适配层应用脚本（docs/TDD.md §4.6）
#
# 用法: scripts/apply-device.sh <immortalwrt 目录> <设备名>
#
# 把 devices/<设备名>/ 下的适配内容应用到基座构建树：
#   1. 补丁目标文件复位（git checkout --，幂等、可重复运行）；
#   2. 按序应用 patches/*.patch（git apply，锁定基座 commit 上逐字节可复现）；
#   3. files/ 原样覆盖到构建树（内核 DTS / U-Boot src overlay 等）。
#
# 基座树为锁定 commit 的工作副本，允许本地修改；本脚本只触碰自己声明的文件。

set -euo pipefail

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="${1:?用法: apply-device.sh <immortalwrt 目录> <设备名>}"
DEVICE="${2:?用法: apply-device.sh <immortalwrt 目录> <设备名>}"
DEVICE_DIR="$BUILDER_DIR/devices/$DEVICE"

[ -d "$BASE_DIR/.git" ] || { echo "错误：$BASE_DIR 不是 git 工作树（需为锁定基座检出）" >&2; exit 1; }
[ -d "$DEVICE_DIR" ] || { echo "错误：设备目录不存在：$DEVICE_DIR" >&2; exit 1; }

echo "==> 设备适配层：$DEVICE（$DEVICE_DIR）"

# 1. 补丁目标文件复位：从补丁头解析（+++ b/<path>），逐个还原为基座原样
if compgen -G "$DEVICE_DIR/patches/*.patch" > /dev/null; then
  mapfile -t patched_files < <(grep -h '^+++ b/' "$DEVICE_DIR"/patches/*.patch | sed 's|^+++ b/||' | sort -u)
  for f in "${patched_files[@]}"; do
    git -C "$BASE_DIR" checkout -- "$f" 2>/dev/null || true
  done
  echo "    复位补丁目标：${patched_files[*]}"
fi

# 2. 按序应用补丁（先 --check 再 apply，失败立即退出）
for p in "$DEVICE_DIR"/patches/*.patch; do
  [ -e "$p" ] || continue
  git -C "$BASE_DIR" apply --check "$p"
  git -C "$BASE_DIR" apply "$p"
  echo "    补丁已应用：$(basename "$p")"
done

# 3. files/ overlay：镜像式覆盖到构建树（新增文件原样落位；幂等）
if [ -d "$DEVICE_DIR/files" ]; then
  (cd "$DEVICE_DIR/files" && find . -type f -print0 | while IFS= read -r -d '' f; do
    mkdir -p "$BASE_DIR/$(dirname "$f")"
    cp -p "$f" "$BASE_DIR/$f"
  done)
  echo "    files overlay 已投放：$(cd "$DEVICE_DIR/files" && find . -type f | wc -l) 个文件"
fi

echo "==> 设备适配层应用完成"
