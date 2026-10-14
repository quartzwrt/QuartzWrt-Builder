#!/usr/bin/env bash
# QuartzWrt 签名验证（WP-9；CI 与本地构建后置步骤）
#
# 验证构建产物与稳定签名密钥一致：
#   ① 各 feed 索引 packages.adb 带签名，且 sig 块 key id == 公钥 id
#      （apk key id = sha512(EC 原始点)[:16]，apk 源码 crypto_openssl.c apk_pkey_init；
#       adbdump 的 `# sig v00 h04 <id>...` 前 16 字节即该 id）；
#   ② 镜像内 base-files 包携带 /etc/apk/keys/public-key.pem == 稳定公钥；
#   ③ quartz-defaults 包携带 quartz.pem（== 稳定公钥）/ quartz-ota.pub /
#      quartz-ota-update，且 QUARTZ_FEED_BASE_URL 配置时携带 quartz-feed.list。
#
# 用法:
#   scripts/verify-signing.sh <基座构建树> [--arch x86_64] [--feeds quartz,thirdparty]
#                             [--pubkey PATH] [--ota-pub PATH]
# 退出码: 0 全过；1 任一断言失败
#
# 说明：本脚本做的是**结构性/一致性**校验（签名存在 + key id 匹配 + 载荷内容），
# 真正的密码学验签在设备侧由 apk（feed）与 usign（OTA 清单）完成（见 ota-drill.sh）。

set -euo pipefail

BASE_DIR="${1:?用法：verify-signing.sh <基座构建树> [--arch x86_64] ...}"
shift || true

ARCH="x86_64"
FEEDS="quartz,thirdparty"
TARGETS="x86/64"
PUBKEY=""
OTA_PUB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --feeds) FEEDS="$2"; shift 2 ;;
    --targets) TARGETS="$2"; shift 2 ;;
    --pubkey) PUBKEY="$2"; shift 2 ;;
    --ota-pub) OTA_PUB="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

[ -d "$BASE_DIR" ] || { echo "错误：构建树不存在：$BASE_DIR" >&2; exit 1; }
APK="$BASE_DIR/staging_dir/host/bin/apk"
[ -x "$APK" ] || { echo "错误：未找到 host apk（$APK；先跑一次构建）" >&2; exit 1; }
command -v openssl >/dev/null || { echo "错误：缺少 openssl" >&2; exit 1; }

[ -n "$PUBKEY" ] || PUBKEY="$BASE_DIR/public-key.pem"
[ -f "$PUBKEY" ] || { echo "错误：未找到公钥（$PUBKEY）" >&2; exit 1; }
if [ -z "$OTA_PUB" ] && [ -f "$BASE_DIR/feeds/quartz/meta/quartz-defaults/files/etc/quartz-ota.pub" ]; then
  OTA_PUB="$BASE_DIR/feeds/quartz/meta/quartz-defaults/files/etc/quartz-ota.pub"
fi

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

. "$(dirname "${BASH_SOURCE[0]}")/lib-keyid.sh"

echo "== 签名验证：$BASE_DIR"
echo "   apk 公钥：$PUBKEY"
ID="$(quartz_apk_key_id "$PUBKEY")"
echo "   apk key id：$ID"

echo "-- ① feed 索引签名"
IFS=',' read -r -a _feeds <<< "$FEEDS"
for f in "${_feeds[@]}"; do
  idx="$BASE_DIR/bin/packages/$ARCH/$f/packages.adb"
  [ -f "$idx" ] || { bad "$f: 索引不存在（$idx）"; continue; }
  sig="$("$APK" adbdump "$idx" 2>/dev/null | grep -o '# sig v00 h04 [0-9a-f]*' | head -1 || true)"
  if [ -z "$sig" ]; then bad "$f: 索引无签名块（packages.adb 未签名）"; continue; fi
  got="${sig##* }"; got="${got:0:32}"
  [ "$got" = "$ID" ] && ok "$f: 索引签名 key id 匹配（${got:0:16}…）" \
                     || bad "$f: 索引签名 key id 不匹配（期望 ${ID:0:16}…，实得 ${got:0:16}…）"
done

echo "-- ② 镜像 base-files 公钥载荷（目标：$TARGETS）"
found_bf=0
IFS=',' read -r -a _targets <<< "$TARGETS"
for t in "${_targets[@]}"; do
  for bf in "$BASE_DIR"/bin/targets/"$t"/packages/base-files-*.apk; do
    [ -f "$bf" ] || continue
    found_bf=1
    tmp="$(mktemp -d)"; ( cd "$tmp" && "$APK" extract --allow-untrusted "$bf" >/dev/null 2>&1 )
    if [ ! -f "$tmp/etc/apk/keys/public-key.pem" ]; then
      bad "$(basename "$bf"): 缺 etc/apk/keys/public-key.pem"
    elif cmp -s "$tmp/etc/apk/keys/public-key.pem" "$PUBKEY"; then
      ok "$(basename "$bf"): public-key.pem == 稳定公钥"
    else
      bad "$(basename "$bf"): public-key.pem 与稳定公钥不一致（临时密钥？未注入签名密钥？）"
    fi
    rm -rf "$tmp"
  done
done
[ "$found_bf" = 1 ] || bad "未找到 base-files 包（bin/targets/$TARGETS/packages/）"

echo "-- ③ quartz-defaults 载荷"
qd="$(ls "$BASE_DIR"/bin/packages/$ARCH/quartz/quartz-defaults-*.apk 2>/dev/null | head -1 || true)"
if [ -z "$qd" ]; then
  bad "未找到 quartz-defaults 包"
else
  tmp="$(mktemp -d)"; ( cd "$tmp" && "$APK" extract --allow-untrusted "$qd" >/dev/null 2>&1 )
  if [ -f "$tmp/etc/apk/keys/quartz.pem" ] && cmp -s "$tmp/etc/apk/keys/quartz.pem" "$PUBKEY"; then
    ok "quartz.pem == 稳定公钥（随固件预置）"
  else
    bad "quartz.pem 缺失或与稳定公钥不一致"
  fi
  [ -f "$tmp/etc/quartz-ota.pub" ] && ok "quartz-ota.pub 在列" || bad "quartz-ota.pub 缺失"
  [ -f "$tmp/usr/sbin/quartz-ota-update" ] && ok "quartz-ota-update 在列" || bad "quartz-ota-update 缺失"
  if [ -n "$OTA_PUB" ] && [ -f "$tmp/etc/quartz-ota.pub" ]; then
    cmp -s "$tmp/etc/quartz-ota.pub" "$OTA_PUB" && ok "quartz-ota.pub == 仓库 OTA 公钥" \
      || bad "quartz-ota.pub 与仓库 OTA 公钥不一致"
  fi
  # QUARTZ_FEED_BASE_URL 配置 → 必须带 quartz-feed.list（D10 阶段 1 接入）
  url="$(sed -n 's/^CONFIG_QUARTZ_FEED_BASE_URL="\?\([^"]*\)"\?$/\1/p' "$BASE_DIR/.config" 2>/dev/null | head -1)"
  if [ -n "$url" ]; then
    if [ -f "$tmp/etc/apk/repositories.d/quartz-feed.list" ] && grep -qF "$url" "$tmp/etc/apk/repositories.d/quartz-feed.list"; then
      ok "quartz-feed.list 在列且指向 $url"
    else
      bad "已设 QUARTZ_FEED_BASE_URL=$url 但 quartz-feed.list 缺失/不符"
    fi
  else
    [ -f "$tmp/etc/apk/repositories.d/quartz-feed.list" ] \
      && bad "未设 QUARTZ_FEED_BASE_URL 却携带 quartz-feed.list（死链风险）" \
      || ok "未设 QUARTZ_FEED_BASE_URL：无 feed 行（安全默认）"
  fi
  rm -rf "$tmp"
fi

echo "== 结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || exit 1
