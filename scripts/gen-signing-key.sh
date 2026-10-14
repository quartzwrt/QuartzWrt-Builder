#!/usr/bin/env bash
# QuartzWrt 发行版签名密钥生成（WP-9）
#
# 生成两把**长期稳定**密钥（一生只生成一次；轮换 = 换代，见 docs/SIGNING-OTA.md）：
#   ① apk 签名密钥（EC prime256v1）——签名各 feed 的 packages.adb 索引；
#      构建树里必须叫 private-key.pem / public-key.pem（基座 rules.mk 约定），
#      公钥随固件投放 /etc/apk/keys/（base-files 自动 + quartz-defaults 预置）。
#   ② OTA 清单签名密钥（usign / Ed25519）——签名 OTA 版本清单（设备端用 usign 验签；
#      设备上没有 openssl CLI，usign 随基座镜像自带）。
#
# 私钥绝不入 git：本脚本输出到仓库外目录（默认 ~/.quartz-signing），
# 由维护者写入 GitHub Secrets（脚本末尾打印命令）。
#
# 用法:
#   scripts/gen-signing-key.sh [--dir DIR] [--force] [--usign PATH]
#
# 环境变量: QUARTZ_SIGNING_DIR（等价 --dir）
# 退出码: 0 成功；1 参数/依赖错误；2 密钥已存在（未加 --force）

set -euo pipefail

DIR="${QUARTZ_SIGNING_DIR:-$HOME/.quartz-signing}"
FORCE=0
USIGN="${USIGN:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:?--dir 需要参数}"; shift 2 ;;
    --dir=*) DIR="${1#--dir=}"; shift ;;
    --force) FORCE=1; shift ;;
    --usign) USIGN="${2:?--usign 需要参数}"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（用法见 --help）" >&2; exit 1 ;;
  esac
done

command -v openssl >/dev/null || { echo "错误：缺少 openssl（生成 apk EC 密钥用）" >&2; exit 1; }

# usign：优先用锁定基座构建树里的 host 工具（版本与固件一致），否则 PATH 里的
if [ -z "$USIGN" ]; then
  BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  for cand in "${QUARTZ_WORK_DIR:-$BUILDER_DIR/../build}/immortalwrt/staging_dir/host/bin/usign" "$(command -v usign 2>/dev/null || true)"; do
    [ -n "$cand" ] && [ -x "$cand" ] && USIGN="$cand" && break
  done
fi
[ -n "$USIGN" ] && [ -x "$USIGN" ] || {
  echo "错误：未找到 usign（先跑一次本地构建，或用 --usign 指定；基座构建树 staging_dir/host/bin/usign）" >&2
  exit 1
}

APK_PRIV="$DIR/apk-private-key.pem"
APK_PUB="$DIR/apk-public-key.pem"
OTA_SEC="$DIR/ota.key"
OTA_PUB="$DIR/ota.pub"

if [ -e "$APK_PRIV" ] || [ -e "$OTA_SEC" ]; then
  if [ "$FORCE" != 1 ]; then
    echo "错误：$DIR 下已存在密钥（拒绝覆盖——密钥轮换 = 换代，需人工确认）。" >&2
    echo "      （确要重生成请加 --force，并注意：旧固件将不再信任新 feed。）" >&2
    exit 2
  fi
  echo "警告：--force 覆盖已有密钥"
fi

mkdir -p "$DIR"
chmod 700 "$DIR"

# ① apk EC prime256v1（与基座 package/Makefile 的生成命令逐字一致）
openssl ecparam -name prime256v1 -genkey -noout -out "$APK_PRIV"
openssl ec -in "$APK_PRIV" -pubout -out "$APK_PUB" 2>/dev/null
chmod 600 "$APK_PRIV"; chmod 644 "$APK_PUB"

# ② usign Ed25519（-c 注释进公钥文件）
"$USIGN" -G -s "$OTA_SEC" -p "$OTA_PUB" -c "QuartzWrt OTA signing key"
chmod 600 "$OTA_SEC"; chmod 644 "$OTA_PUB"

# apk 密钥指纹 = sha512(EC 原始点)[:16]（apk 源码 apk_pkey_init；见 lib-keyid.sh）
. "$(dirname "${BASH_SOURCE[0]}")/lib-keyid.sh"
apk_id="$(quartz_apk_key_id "$APK_PUB")"
ota_id="$("$USIGN" -F -p "$OTA_PUB")"

cat <<EOF

==> 签名密钥已生成：$DIR
    apk 私钥      $APK_PRIV   (0600)
    apk 公钥      $APK_PUB    key id = $apk_id
    OTA 私钥      $OTA_SEC     (0600)
    OTA 公钥      $OTA_PUB     fingerprint = $ota_id

下一步（维护者一次性操作）：
  1) 公钥入仓（随固件投放，不是秘密）：
       cp $APK_PUB <QuartzWrt-Packages>/meta/quartz-defaults/files/etc/apk/keys/quartz.pem
       cp $OTA_PUB <QuartzWrt-Packages>/meta/quartz-defaults/files/etc/quartz-ota.pub
     提交 Packages 仓库（docs/SIGNING-OTA.md §3）。
  2) 私钥写入 GitHub Secrets（CI 签名用；本机保留 0600 备份）：
       gh secret set APK_SIGNING_PRIVATE_KEY -R quartzwrt/QuartzWrt-Builder < $APK_PRIV
       gh secret set APK_SIGNING_PUBLIC_KEY  -R quartzwrt/QuartzWrt-Builder < $APK_PUB
       gh secret set OTA_SIGNING_KEY         -R quartzwrt/QuartzWrt-Builder < $OTA_SEC
  3) 本地构建注入（开发机）：QUARTZ_SIGNING_DIR=$DIR scripts/build-local.sh
EOF
