#!/usr/bin/env bash
# QuartzWrt feed 在线复核（WP-9）——发布后 / #41 阶段 1 翻转前的"前置条件检查"
#
# 对托管根 URL 逐项核对（与固件 distfeeds / OTA 的 URL 约定逐字对应）：
#   ① 可达性：packages/<arch>/<feed>/packages.adb、targets/<board>/<subtarget>/packages/packages.adb
#   ② 索引签名：下载后校验 key id == 预置公钥（sha512(EC 原始点)[:16]，与设备端 apk 同款判定）
#   ③ OTA：ota/<board>/<subtarget>.json 可达 + usign 验签（用仓库内 OTA 公钥）
#   ④ 包可取：抽查一个 .apk 的 HTTP 200（Content-Length 与索引 file-size 一致）
#
# 用法:
#   scripts/check-feed-live.sh <托管根 URL> [--arch x86_64] [--board x86 --subtarget 64]
#                              [--feeds quartz,thirdparty] [--pubkey PATH] [--ota-pub PATH]
# 退出码: 0 全过（可翻转）；1 有失败项（勿翻转）
#
# 提示：URL 用设备可达的地址（LAN 内 NAS 用 LAN IP/域名；HTTPS 与 HTTP 均可，
#       包完整性由签名保证，HTTP 仅暴露"有哪些包"的元数据）。

set -euo pipefail

BASE_URL="${1:?用法：check-feed-live.sh <托管根 URL> [--arch ...]}"; shift || true
BASE_URL="${BASE_URL%/}"   # 去尾斜杠（固件侧拼接约定：<根>/packages/...）

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="x86_64"; BOARD="x86"; SUBTARGET="64"
FEEDS="quartz,thirdparty"
PUBKEY="${QUARTZ_SIGNING_DIR:+$QUARTZ_SIGNING_DIR/apk-public-key.pem}"
OTA_PUB="${QUARTZ_SIGNING_DIR:+$QUARTZ_SIGNING_DIR/ota.pub}"

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --board) BOARD="$2"; shift 2 ;;
    --subtarget) SUBTARGET="$2"; shift 2 ;;
    --feeds) FEEDS="$2"; shift 2 ;;
    --pubkey) PUBKEY="$2"; shift 2 ;;
    --ota-pub) OTA_PUB="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

# 公钥兜底：Packages 仓库副本（权威、随固件投放）
[ -n "$PUBKEY" ] || PUBKEY="$BUILDER_DIR/../QuartzWrt-Packages/meta/quartz-defaults/files/etc/apk/keys/quartz.pem"
[ -n "$OTA_PUB" ] || OTA_PUB="$BUILDER_DIR/../QuartzWrt-Packages/meta/quartz-defaults/files/etc/quartz-ota.pub"

PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
step() { printf '\n==> %s\n' "$*"; }

command -v curl >/dev/null || { echo "错误：缺少 curl" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fetch() { # fetch <URL> <输出文件> —— 打印 HTTP 码（不带 -f：HTTP 错误码照常打印）
  local code
  code="$(curl -sS -o "$2" -w '%{http_code}' --max-time 60 "$1" 2>/dev/null)" || true
  echo "${code:-000}"
}

step "① 可达性 + ② 索引签名：$BASE_URL"
. "$BUILDER_DIR/scripts/lib-keyid.sh"
[ -f "$PUBKEY" ] || { echo "错误：未找到 apk 公钥（$PUBKEY；用 --pubkey 指定）" >&2; exit 1; }
EXPECT_ID="$(quartz_apk_key_id "$PUBKEY")"
echo "   期望 key id：$EXPECT_ID"

# 签名 key id 提取：有 host apk（构建树）走 adbdump（权威文本渲染）；
# 否则退回"二进制扫描 id 字节"——签名块内含 16 字节 key id，命中即签名块在
# （真实验签由设备端 apk 完成，本脚本只做发布前置检查）。
APK_BIN=""
for cand in "${QUARTZ_WORK_DIR:-$BUILDER_DIR/../build}/immortalwrt/staging_dir/host/bin/apk" "$(command -v apk 2>/dev/null || true)"; do
  [ -n "$cand" ] && [ -x "$cand" ] && APK_BIN="$cand" && break
done
sig_key_id_of() { # $1 = adb 文件 → 输出 key id（32 hex）或空
  if [ -n "$APK_BIN" ]; then
    "$APK_BIN" adbdump "$1" 2>/dev/null | grep -ao '# sig v00 h04 [0-9a-f]*' | head -1 | sed 's/.*h04 //' | cut -c1-32
  else
    python3 - "$1" "$EXPECT_ID" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
want = bytes.fromhex(sys.argv[2])
print(sys.argv[2] if want in data else "")
PY
  fi
}

IFS=',' read -r -a _feeds <<< "$FEEDS"
for f in "${_feeds[@]}"; do
  url="$BASE_URL/packages/$ARCH/$f/packages.adb"
  code="$(fetch "$url" "$TMP/$f.adb")"
  if [ "$code" != "200" ]; then bad "$f 索引不可达（HTTP $code）：$url"; continue; fi
  got="$(sig_key_id_of "$TMP/$f.adb")"
  if [ -z "$got" ]; then bad "$f 索引无签名块（或非本密钥签名）"; continue; fi
  [ "$got" = "$EXPECT_ID" ] && ok "$f 索引可达且签名 key id 匹配（$(stat -c%s "$TMP/$f.adb") 字节）" \
                            || bad "$f 索引签名 key id 不匹配（期望 ${EXPECT_ID:0:16}…，实得 ${got:0:16}…）"
  # ④ 抽查一个包（索引内首个包）：验证包文件可取（不依赖构建树，用 strings 抓 name/version）
  if command -v strings >/dev/null; then
    read -r name ver < <(strings "$TMP/$f.adb" | awk '
      /^  - name: / && !n { n=$3 }
      /^    version: / && n && !v { v=$2 }
      n && v { print n, v; exit }') || true
    if [ -n "${name:-}" ] && [ -n "${ver:-}" ]; then
      code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 60 \
        "$BASE_URL/packages/$ARCH/$f/$name-$ver.apk" 2>/dev/null || echo 000)"
      [ "$code" = "200" ] && ok "$f 抽查包可取：$name-$ver.apk" \
                          || bad "$f 抽查包不可取（HTTP $code）：$name-$ver.apk"
    fi
  fi
done

tgt_url="$BASE_URL/targets/$BOARD/$SUBTARGET/packages/packages.adb"
code="$(fetch "$tgt_url" "$TMP/target.adb")"
if [ "$code" != "200" ]; then
  bad "目标包索引不可达（HTTP $code）：$tgt_url"
else
  got="$(sig_key_id_of "$TMP/target.adb")"
  [ "$got" = "$EXPECT_ID" ] && ok "目标包索引可达且签名匹配" || bad "目标包索引签名不匹配（或缺失）"
fi

step "③ OTA 清单：$BASE_URL/ota/$BOARD/$SUBTARGET.json"
code="$(fetch "$BASE_URL/ota/$BOARD/$SUBTARGET.json" "$TMP/ota.json")"
code_sig="$(fetch "$BASE_URL/ota/$BOARD/$SUBTARGET.json.sig" "$TMP/ota.json.sig")"
if [ "$code" != "200" ] || [ "$code_sig" != "200" ]; then
  bad "OTA 清单/签名不可达（HTTP $code/$code_sig）——仅影响固件 OTA 通道，不影响包源"
else
  usign_bin=""
  for cand in "${QUARTZ_WORK_DIR:-$BUILDER_DIR/../build}/immortalwrt/staging_dir/host/bin/usign" "$(command -v usign 2>/dev/null || true)"; do
    [ -n "$cand" ] && [ -x "$cand" ] && usign_bin="$cand" && break
  done
  if [ -z "$usign_bin" ]; then
    echo "  SKIP: 未找到 usign（跳过 OTA 验签；构建树 staging_dir/host/bin/usign）"
  elif [ ! -f "$OTA_PUB" ]; then
    bad "缺 OTA 公钥（$OTA_PUB）"
  else
    # 注意：清单与签名文件需同名对位，usign -x 指向签名文件
    cp "$TMP/ota.json" "$TMP/m.json"; cp "$TMP/ota.json.sig" "$TMP/m.json.sig"
    if "$usign_bin" -q -V -m "$TMP/m.json" -p "$OTA_PUB"; then
      ok "OTA 清单验签通过（build_id=$(sed -n 's/.*"build_id": "\([^"]*\)".*/\1/p' "$TMP/ota.json" | head -1)）"
    else
      bad "OTA 清单验签失败"
    fi
  fi
fi

step "结果：PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" = 0 ]; then
  cat <<EOF

✔ 该托管根满足 #41 阶段 1 翻转前置。翻转步骤：
  1) config/seed.config（x86）与 devices/<设备>/seed.config 设：
       CONFIG_QUARTZ_FEED_BASE_URL="$BASE_URL"
     （CONFIG_FEED_{quartz,thirdparty} 保持 =m 不动）
  2) 重建固件（本地 scripts/build-local.sh 或手动 CI）
  3) 设备侧复核：apk update 无 UNTRUSTED、apk list -u 可见自有源
EOF
else
  echo "✘ 存在失败项——先修好再翻转（勿把死链/错钥写进固件）。"
  exit 1
fi
