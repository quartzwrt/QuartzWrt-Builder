#!/usr/bin/env bash
# QuartzWrt 双 Feed 仓库的 Release（自建软件源压缩包）——WP-9
#
# 目的（用户拍板）：`QuartzWrt-Packages`（quartz feed）与 `QuartzWrt-ThirdParty`（thirdparty
# feed）两个仓库各发一个 Release，资产就是**该 feed 的多架构压缩包**——供他人自建软件源
# （解压后按 `packages/<arch>/<feed>/` 目录原样挂到任意静态托管即可，索引已签名）。
#
# 资产（每个 feed 一个包）：
#   <feed>-feed-<tag>.tar.gz   含 packages/<arch>/<feed>/{*.apk,packages.adb}（全部架构）
#   quartz.pem                 签名公钥（设备端信任根，随包分发便于自建源使用者核对）
#   说明见 Release notes（构建标识/锁定/签名指纹/自建源步骤）
#
# 用法:
#   scripts/release-feed-repos.sh --tag v0.1.0 [--feed-dir DIR] [--dry-run] [--draft] [--only quartz|thirdparty]
# 说明：--feed-dir 默认 `<Builder>/../feed-out`（publish-feed-all.sh 的产物根）；
#       缺失时请先发布一次（scripts/publish-feed-all.sh 或 release-local.sh --publish-feed）。

set -euo pipefail

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG=""; FEED_DIR="$BUILDER_DIR/../feed-out"; DRY_RUN=0; DRAFT=""; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --feed-dir) FEED_DIR="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --draft) DRAFT="--draft"; shift ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（用法见 --help）" >&2; exit 1 ;;
  esac
done
[ -n "$TAG" ] || { echo "错误：缺 --tag（与固件发布同 tag，便于溯源）" >&2; exit 1; }
[ -d "$FEED_DIR" ] || { echo "错误：发布根不存在：$FEED_DIR（先跑 publish-feed-all.sh）" >&2; exit 1; }
command -v gh >/dev/null || { echo "错误：缺少 gh CLI" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "错误：gh 未登录" >&2; exit 1; }

. "$BUILDER_DIR/scripts/lib-keyid.sh"
PUBKEY="$BUILDER_DIR/../QuartzWrt-Packages/meta/quartz-defaults/files/etc/apk/keys/quartz.pem"
[ -f "$PUBKEY" ] || PUBKEY="$FEED_DIR/quartz.pem"
KEY_ID="$(quartz_apk_key_id "$PUBKEY" 2>/dev/null || echo unknown)"
BUILD_ID="$(sed -n 's/^build_id: *//p' "$FEED_DIR/PUBLISH.txt" 2>/dev/null | head -1)"
FEED_URL="$(sed -n 's/^CONFIG_QUARTZ_FEED_BASE_URL="\?\([^"]*\)"\?$/\1/p' "$BUILDER_DIR/config/seed.config" | head -1)"

step() { printf '\n==> %s\n' "$*"; }
OUT="$BUILDER_DIR/../release-out/feed-repos-$TAG"; mkdir -p "$OUT"

for pair in quartz:QuartzWrt-Packages thirdparty:QuartzWrt-ThirdParty; do
  feed="${pair%%:*}"; repo="${pair#*:}"
  [ -z "$ONLY" ] || [ "$ONLY" = "$feed" ] || continue
  arches=()
  for ad in "$FEED_DIR"/packages/*/"$feed"; do
    [ -d "$ad" ] && [ -f "$ad/packages.adb" ] && arches+=("$(basename "$(dirname "$ad")")")
  done
  [ "${#arches[@]}" -gt 0 ] || { echo "跳过 $feed：发布根内无该 feed（$FEED_DIR/packages/*/$feed）"; continue; }

  step "打包 $feed（架构：${arches[*]}）→ $repo Release $TAG"
  stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
  mkdir -p "$stage/$feed"
  for arch in "${arches[@]}"; do
    mkdir -p "$stage/$feed/packages/$arch"
    cp -a "$FEED_DIR/packages/$arch/$feed" "$stage/$feed/packages/$arch/"
    rm -f "$stage/$feed/packages/$arch/$feed/index.html"   # 站点页面不入包（自建源不需要）
  done
  cp -f "$PUBKEY" "$stage/$feed/quartz.pem"
  cat > "$stage/$feed/README.md" <<EOF
# QuartzWrt $feed feed 快照（$TAG）

- 构建标识：\`${BUILD_ID:-unknown}\`
- 签名公钥：\`quartz.pem\`（apk key id \`$KEY_ID\`；**索引以此密钥签名，设备端 apk 自动验签**）
- 架构：$(printf '%s ' "${arches[@]}")

## 自建软件源
把 \`packages/\` 目录原样挂到任意静态 Web 服务器（保持目录结构与大小写，无需目录列表）：

\`\`\`
<你的根>/packages/<arch>/$feed/packages.adb      ← apk 索引（已签名）
<你的根>/packages/<arch>/$feed/*.apk
\`\`\`

设备侧（固件已预置 \`quartz.pem\`）：
\`\`\`
# /etc/apk/repositories.d/quartz-feed.list
<你的根>/packages/<arch>/$feed/packages.adb
\`\`\`
（\`<arch>\` 取 \`x86_64\` 或 \`aarch64_generic\`；官方源：${FEED_URL:-https://sources.quartzwrt.org/quartz-feed}）
EOF
  tarball="$OUT/$feed-feed-$TAG.tar.gz"
  ( cd "$stage" && tar -czf "$tarball" "$feed" )
  echo "  $(basename "$tarball")：$(ls -lh "$tarball" | awk '{print $5}')"

  notes="$OUT/$feed-NOTES.md"
  cat > "$notes" <<EOF
# $feed feed 快照 $TAG

对应固件发布 **$TAG**（构建标识 \`${BUILD_ID:-unknown}\`）的 \`$feed\` feed 快照，
供**自建软件源**使用。

- 资产：\`$feed-feed-$TAG.tar.gz\`（含全部架构：$(printf '%s ' "${arches[@]}")）、\`quartz.pem\`（签名公钥）
- 签名：apk EC 稳定密钥，key id \`$KEY_ID\`——与本项目固件/CI 产物**同一把密钥**，索引已签名，设备端 apk 自动验签
- 官方源：${FEED_URL:-https://sources.quartzwrt.org/quartz-feed}
- 用法：解压 → \`packages/\` 原样挂到静态托管 → 设备 \`/etc/apk/repositories.d/\` 加一行索引 URL
  （详见包内 \`README.md\`）
EOF

  if [ "$DRY_RUN" = 1 ]; then
    echo "  --dry-run：跳过发布（资产：$tarball；说明：$notes）"
    continue
  fi
  if gh release view "$TAG" -R "quartzwrt/$repo" >/dev/null 2>&1; then
    echo "  Release 已存在 → 覆盖上传"
    gh release upload "$TAG" -R "quartzwrt/$repo" "$tarball" "$PUBKEY" --clobber
  else
    gh release create "$TAG" -R "quartzwrt/$repo" --title "$feed feed 快照 $TAG" \
      --notes-file "$notes" $DRAFT "$tarball" "$PUBKEY"
  fi
  echo "  OK：https://github.com/quartzwrt/$repo/releases/tag/$TAG"
done

step "完成 ✔（资产目录：$OUT）"
