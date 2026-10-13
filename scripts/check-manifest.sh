#!/usr/bin/env bash
# QuartzWrt manifest 校验（build-local.sh 与 CI 共用，防两侧漂移）
#
# 用法: scripts/check-manifest.sh <manifest 文件> [设备名]
#   - 公共断言：quartz 五关键包在列；docker 栈反向断言不在列（用户拍板移出预装，2026-10-12）
#   - 设备断言（可选）：devices/<设备名>/device.env 的 $DEVICE_MANIFEST_PACKAGES 在列
#
# 退出码非 0 即校验失败。

set -euo pipefail

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${1:?用法: check-manifest.sh <manifest 文件> [设备名]}"
DEVICE="${2:-}"

[ -f "$MANIFEST" ] || { echo "FAIL: manifest 不存在：$MANIFEST" >&2; exit 1; }
echo "manifest: $MANIFEST"

fail=0

# 公共：关键包必须在列
for p in quartz-defaults luci-theme-quartz luci-app-dashboard luci-app-quartz-config luci-app-openclash; do
  if grep -q "^${p} " "$MANIFEST"; then
    echo "OK: $p"
  else
    echo "FAIL: $p 不在固件清单中（可能依赖未满足被静默取消选择）" >&2
    fail=1
  fi
done

# 公共：docker 栈必须不在列
for p in dockerd docker containerd runc luci-app-dockerman luci-lib-docker; do
  if grep -q "^${p} " "$MANIFEST"; then
    echo "FAIL: $p 出现在固件清单中（docker 已移出预装，2026-10-12 用户拍板）" >&2
    fail=1
  else
    echo "OK(不在列): $p"
  fi
done

# 设备专属断言
if [ -n "$DEVICE" ]; then
  DEVICE_ENV="$BUILDER_DIR/devices/$DEVICE/device.env"
  [ -f "$DEVICE_ENV" ] || { echo "FAIL: 设备元数据不存在：$DEVICE_ENV" >&2; exit 1; }
  # shellcheck disable=SC1090
  . "$DEVICE_ENV"
  for p in ${DEVICE_MANIFEST_PACKAGES:-}; do
    if grep -q "^${p} " "$MANIFEST"; then
      echo "OK(设备): $p"
    else
      echo "FAIL(设备): $p 不在固件清单中（DEVICE_PACKAGES 项）" >&2
      fail=1
    fi
  done
fi

exit $fail
