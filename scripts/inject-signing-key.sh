#!/usr/bin/env bash
# QuartzWrt 构建树签名密钥注入（WP-9；本地构建与 CI 共用）
#
# 把长期稳定密钥注入基座构建树 TOPDIR——基座规则（rules.mk / package/Makefile）：
#   private-key.pem  签名各 feed 的 packages.adb 索引（apk mkndx --sign）
#   public-key.pem   随 base-files 投放 /etc/apk/keys/（固件信任本密钥签的 feed）
#
# 未注入时基座会**每个全新构建树生成一把临时密钥**（可用的开发态，但 feed 与固件
# 互不认账、跨版本升级验签失败）——因此发布构建必须注入稳定密钥。
#
# 用法:
#   scripts/inject-signing-key.sh <基座构建树> [--require]
#
# 密钥来源（按序）：
#   ① 环境变量 QUARTZ_SIGNING_DIR 下的 apk-private-key.pem / apk-public-key.pem
#   ② 环境变量 APK_SIGNING_PRIVATE_KEY / APK_SIGNING_PUBLIC_KEY（**PEM 内容**或文件路径；
#      CI 从 GitHub Secrets 注入）
#   ③ 无 → 警告并继续（开发构建，基座自生成临时密钥）；--require 时改为失败
#
# 一致性校验：私钥推导公钥 == 给定公钥；且与 feed 内 quartz-defaults 预置的
# quartz.pem（随固件投放的权威公钥）一致——不一致直接失败（防密钥错配发布）。

set -euo pipefail

BASE_DIR="${1:?用法：inject-signing-key.sh <基座构建树> [--require]}"
REQUIRE=0
[ "${2:-}" = "--require" ] && REQUIRE=1

[ -d "$BASE_DIR" ] || { echo "错误：构建树不存在：$BASE_DIR" >&2; exit 1; }

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

priv=""; pub=""

# ① 密钥目录
if [ -n "${QUARTZ_SIGNING_DIR:-}" ] && [ -f "$QUARTZ_SIGNING_DIR/apk-private-key.pem" ]; then
  priv="$QUARTZ_SIGNING_DIR/apk-private-key.pem"
  pub="$QUARTZ_SIGNING_DIR/apk-public-key.pem"
fi

# ② CI Secrets：内容或路径
if [ -z "$priv" ] && [ -n "${APK_SIGNING_PRIVATE_KEY:-}" ]; then
  if [ -f "$APK_SIGNING_PRIVATE_KEY" ]; then
    priv="$APK_SIGNING_PRIVATE_KEY"
  else
    printf '%s\n' "$APK_SIGNING_PRIVATE_KEY" > "$TMP/priv.pem"; priv="$TMP/priv.pem"
  fi
fi
if [ -z "$pub" ] && [ -n "${APK_SIGNING_PUBLIC_KEY:-}" ]; then
  if [ -f "$APK_SIGNING_PUBLIC_KEY" ]; then
    pub="$APK_SIGNING_PUBLIC_KEY"
  else
    printf '%s\n' "$APK_SIGNING_PUBLIC_KEY" > "$TMP/pub.pem"; pub="$TMP/pub.pem"
  fi
fi

if [ -z "$priv" ]; then
  if [ "$REQUIRE" = 1 ]; then
    echo "错误：--require 但未提供签名密钥（QUARTZ_SIGNING_DIR 或 APK_SIGNING_PRIVATE_KEY）" >&2
    exit 1
  fi
  echo "警告：未提供签名密钥——本次为开发构建，基座将生成临时密钥（feed 不可发布）。"
  exit 0
fi

# 私钥 → 公钥推导；若未单独给公钥则一并推导
command -v openssl >/dev/null || { echo "错误：缺少 openssl" >&2; exit 1; }
openssl ec -in "$priv" -pubout -out "$TMP/derived.pem" 2>/dev/null || {
  echo "错误：无法读取 apk 私钥（$priv）" >&2; exit 1; }
if [ -z "$pub" ]; then
  pub="$TMP/derived.pem"
else
  openssl ec -pubin -in "$pub" -pubout -out "$TMP/given.pem" 2>/dev/null || {
    echo "错误：无法读取 apk 公钥（$pub）" >&2; exit 1; }
  if ! cmp -s "$TMP/derived.pem" "$TMP/given.pem"; then
    echo "错误：私钥与公钥不匹配（$priv vs $pub）" >&2; exit 1
  fi
fi

# 与 feed 内 quartz-defaults 预置公钥比对（防密钥错配发布；feed 未安装时跳过）
shipped="$BASE_DIR/feeds/quartz/meta/quartz-defaults/files/etc/apk/keys/quartz.pem"
if [ -f "$shipped" ]; then
  if ! cmp -s "$TMP/derived.pem" "$shipped"; then
    echo "错误：注入密钥与 quartz-defaults 预置公钥（quartz.pem）不一致。" >&2
    echo "      固件将不信任本密钥签名的 feed——请先更新 Packages 仓库公钥或换用匹配的密钥。" >&2
    exit 1
  fi
  echo "OK：与 quartz-defaults 预置公钥（quartz.pem）一致"
fi

install -m 600 "$priv" "$BASE_DIR/private-key.pem"
install -m 644 "$TMP/derived.pem" "$BASE_DIR/public-key.pem"

# key id = sha512(EC 原始点)[:16]（apk 源码 apk_pkey_init 语义，见 lib-keyid.sh）
. "$BUILDER_DIR/scripts/lib-keyid.sh"
key_id="$(quartz_apk_key_id "$BASE_DIR/public-key.pem")"
echo "OK：签名密钥已注入 $BASE_DIR（apk key id = $key_id）"
