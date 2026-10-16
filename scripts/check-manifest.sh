#!/usr/bin/env bash
# QuartzWrt manifest 校验（build-local.sh 与 CI 共用，防两侧漂移）
#
# 用法: scripts/check-manifest.sh <manifest 文件> [设备名] [基座构建树]
#   - 公共断言（Gate B，WP-12 起**派生**，不再手抄）：
#       ① assemblies：装配后的种子层里每个 `CONFIG_PACKAGE_<x>=y` 都必须在 manifest 在列
#          （非包符号——如 `*_INCLUDE_*` 之类的包构建选项——自动豁免：见下"豁免"）；
#       ② quartz-defaults 的 DEPENDS 全清单（核心组件 + thirdparty 预装）从
#          feeds/quartz/meta/quartz-defaults/Makefile 现读现断言（增删依赖无需改本脚本）。
#   - docker 栈断言（变体相关，2026-10-16）：
#       标准版（默认）→ **反向**：docker 栈必须不在列（2026-10-12 用户拍板移出预装）；
#       docker 变体（--docker）→ **正向**：docker 栈必须在列（docker.config 层的效果）。
#   - 设备断言（可选）：devices/<设备名>/device.env 的 $DEVICE_MANIFEST_PACKAGES 在列。
#     该清单**刻意比"选择"宽**（可含依赖闭包项与 DEVICE_PACKAGES 项）：上游闭包变化时
#     设备构建即红，是设备级验收而非选择来源。
#
# 豁免机制（Gate B 非包符号）：
#   ① 基座构建树给了且 tmp/.packageinfo 存在 → 用包清单自动判定（最准）；
#   ② 否则回退：种子源文件里 `# assert-exempt: <符号名>` 标记的行跳过。
#
# 退出码非 0 即校验失败。

set -euo pipefail

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER=""
_args=()
for _a in "$@"; do
  case "$_a" in
    --docker) DOCKER=1 ;;
    *) _args+=("$_a") ;;
  esac
done
if [ "${#_args[@]}" -gt 0 ]; then set -- "${_args[@]}"; else set --; fi
MANIFEST="${1:?用法: check-manifest.sh <manifest 文件> [设备名] [基座构建树] [--docker]}"
DEVICE="${2:-}"
BUILD_TREE="${3:-}"

[ -f "$MANIFEST" ] || { echo "FAIL: manifest 不存在：$MANIFEST" >&2; exit 1; }
echo "manifest: $MANIFEST"

fail=0
check_pkg() {  # $1=包名 $2=来源说明
  # apk 体系下带 ABI_VERSION 的库在 manifest/镜像里是 `<名>-<ABI>`（安装期由
  # include/image.mk 的 GetABISuffix 派生；如 libnghttp2 → manifest 里 `libnghttp2-14`），
  # 因此匹配时允许可选数字后缀；符号名本身照旧（.config 里仍是 libnghttp2）。
  local re
  re="$(printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
  if grep -qE "^${re}(-[0-9]+)? " "$MANIFEST"; then
    echo "OK: ${1}  [$2]"
  else
    echo "FAIL: ${1} 不在固件清单中（$2；可能依赖未满足被静默取消选择）" >&2
    fail=1
  fi
}

# ── Gate B ①：装配后的种子层 =y 项 ───────────────────────────────────────────
COMPOSE_ARGS=()
[ -n "$DEVICE" ] && COMPOSE_ARGS=(--device "$DEVICE")
[ -n "$DOCKER" ] && COMPOSE_ARGS+=(--docker)
PACKAGEINFO="${BUILD_TREE:+$BUILD_TREE/tmp/.packageinfo}"
composed="$(bash "$BUILDER_DIR/scripts/compose-seed.sh" ${COMPOSE_ARGS[@]+"${COMPOSE_ARGS[@]}"} emit 2>/dev/null)"
echo "── Gate B：种子层 =y 项（装配派生）──"
while IFS= read -r line; do
  case "$line" in CONFIG_PACKAGE_*=y) ;; *) continue ;; esac
  sym="${line#CONFIG_PACKAGE_}"; pkg="${sym%=y}"
  if [ -n "$PACKAGEINFO" ] && [ -f "$PACKAGEINFO" ] && ! grep -q "^Package: ${pkg}$" "$PACKAGEINFO"; then
    echo "SKIP: ${pkg}（非包符号：包构建选项，自动豁免）"
    continue
  fi
  check_pkg "$pkg" "种子层 =y"
done <<< "$composed"

# ── Gate B ②：quartz-defaults 的 DEPENDS（现读现断言，替代旧手抄 8 包清单）────
QD_MK="${BUILD_TREE:+$BUILD_TREE/feeds/quartz/meta/quartz-defaults/Makefile}"
if [ -n "$QD_MK" ] && [ -f "$QD_MK" ]; then
  echo "── Gate B：quartz-defaults DEPENDS（源：feeds/quartz/meta/quartz-defaults/Makefile）──"
  deps="$(awk '/^  DEPENDS:=/{f=1} f{print} f&&/^endef/{exit}' "$QD_MK" \
          | grep -oE '\+[A-Za-z0-9][A-Za-z0-9._+-]*' | sed 's/^+//' | sort -u)"
  for p in $deps; do check_pkg "$p" "quartz-defaults DEPENDS"; done
else
  echo "SKIP: quartz-defaults DEPENDS 派生（未给基座构建树或 feeds/quartz 未安装）"
  # 保守兜底：至少确认元包本体与核心聚合入口在列
  check_pkg quartz-defaults "元包本体"
fi

# ── docker 栈断言（变体相关，2026-10-16）────────────────────────────────────
if [ -n "$DOCKER" ]; then
  echo "── docker 变体：docker 栈必须在列 ──"
  for p in dockerd docker containerd runc docker-compose luci-app-dockerman luci-lib-docker; do
    check_pkg "$p" "docker 变体"
  done
else
  for p in dockerd docker containerd runc luci-app-dockerman luci-lib-docker; do
    if grep -q "^${p} " "$MANIFEST"; then
      echo "FAIL: $p 出现在固件清单中（标准版不含 docker，2026-10-12 用户拍板；要 docker 请构建 --docker 变体）" >&2
      fail=1
    else
      echo "OK(不在列): $p"
    fi
  done
fi

# ── 设备验收断言（可含闭包项与 DEVICE_PACKAGES 项；比"选择"宽是刻意的）────────
if [ -n "$DEVICE" ]; then
  DEVICE_ENV="$BUILDER_DIR/devices/$DEVICE/device.env"
  [ -f "$DEVICE_ENV" ] || { echo "FAIL: 设备元数据不存在：$DEVICE_ENV" >&2; exit 1; }
  # shellcheck disable=SC1090
  . "$DEVICE_ENV"
  for p in ${DEVICE_MANIFEST_PACKAGES:-}; do
    check_pkg "$p" "设备验收"
  done
fi

exit $fail
