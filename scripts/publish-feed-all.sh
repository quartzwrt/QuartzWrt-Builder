#!/usr/bin/env bash
# QuartzWrt 多架构 feed 发布（WP-9）——一次发布全部可用架构与目标，并生成软件源页面
#
# 背景：软件源要同时带 x86_64 与 ARM（FNet3399 = aarch64_generic / rockchip armv8）。
# 构建树里两套产物**可共存**（bin/packages/<arch>/ 与 bin/targets/<board>/<subtarget>/
# 各自独立），分别由对应目标的构建产出（切换目标会 dirclean，故需两次构建）。
#
# 流程：逐对（架构:目标）调用 publish-feed.sh 到同一发布根 → gen-feed-page.sh 生成页面
#       → 可选一次性 rsync 到静态托管（NAS；`--delete` 只作用于该专用目录）
#
# 用法:
#   scripts/publish-feed-all.sh --base-dir <构建树> --dest <发布根> [选项]
#     --pairs "x86_64:x86:64 aarch64_generic:rockchip:armv8"   架构:board:subtarget 列表
#     --rsync DEST     全部发布后一次性同步（SSH_PASS=... 可驱动密码认证）
#     --url URL        软件源页面里展示的公开地址（默认取 seed 内 QUARTZ_FEED_BASE_URL）
#     --no-page        不生成软件源页面
#     --root-page      同步后把"站点根精简页"写到托管站点根 index.html（先备份为 index.html~；
#                      站点根 = rsync 目标去掉最后一段，如 .../quartzwrt/quartz-feed → .../quartzwrt）
#     --feeds LIST     传给 publish-feed.sh（默认 quartz,thirdparty）
#
# 退出码: 0 成功；1 失败（含"无任何可用架构对"）

set -euo pipefail

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR=""
DEST=""
PAIRS="x86_64:x86:64 aarch64_generic:rockchip:armv8"
RSYNC_DEST=""
URL=""
MAKE_PAGE=1
FEEDS="quartz,thirdparty"
ROOT_PAGE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base-dir) BASE_DIR="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    --pairs) PAIRS="$2"; shift 2 ;;
    --rsync) RSYNC_DEST="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --no-page) MAKE_PAGE=0; shift ;;
    --root-page) ROOT_PAGE=1; shift ;;
    --feeds) FEEDS="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（用法见 --help）" >&2; exit 1 ;;
  esac
done
[ -n "$BASE_DIR" ] && [ -d "$BASE_DIR" ] || { echo "错误：--base-dir 构建树不存在" >&2; exit 1; }
[ -n "$DEST" ] || { echo "错误：缺 --dest 发布根目录" >&2; exit 1; }
[ -n "$URL" ] || URL="$(sed -n 's/^CONFIG_QUARTZ_FEED_BASE_URL="\?\([^"]*\)"\?$/\1/p' "$BASE_DIR/.config" 2>/dev/null | head -1)"

step() { printf '\n==> %s\n' "$*"; }

# 发布（逐对；跳过产物不存在的对）
n=0; published=()
for pair in $PAIRS; do
  arch="${pair%%:*}"; rest="${pair#*:}"; board="${rest%%:*}"; sub="${rest#*:}"
  have_pkgs=0; have_tgt=0
  [ -d "$BASE_DIR/bin/packages/$arch/quartz" ] && have_pkgs=1
  [ -d "$BASE_DIR/bin/targets/$board/$sub" ] && have_tgt=1
  if [ "$have_pkgs" = 0 ] && [ "$have_tgt" = 0 ]; then
    echo "跳过 $arch / $board/$sub（构建树中无产物）"; continue
  fi
  step "发布 $arch + $board/$sub（包=$have_pkgs 目标=$have_tgt）"
  args=(--base-dir "$BASE_DIR" --dest "$DEST" --arch "$arch" --board "$board" --subtarget "$sub" --feeds "$FEEDS")
  [ "$have_tgt" = 1 ] || args+=(--no-target --no-images)
  bash "$BUILDER_DIR/scripts/publish-feed.sh" "${args[@]}"
  n=$((n+1)); published+=("$arch:$board:$sub")
done
[ "$n" -gt 0 ] || { echo "错误：无任何可用架构对（--pairs：$PAIRS）" >&2; exit 1; }

# 软件源页面
if [ "$MAKE_PAGE" = 1 ]; then
  step "生成软件源页面（$URL）"
  bash "$BUILDER_DIR/scripts/gen-feed-page.sh" "$DEST" --url "$URL"
fi

# 一次性同步（含页面）
if [ -n "$RSYNC_DEST" ]; then
  step "同步到静态托管：$RSYNC_DEST"
  command -v rsync >/dev/null || { echo "错误：缺少 rsync" >&2; exit 1; }
  RSYNC_ARGS=(-av --delete --chmod=D755,F644 "$DEST"/ "$RSYNC_DEST"/)
  if [ -n "${SSH_PASS:-}" ] && [ -x "$BUILDER_DIR/scripts/ssh-pass.py" ]; then
    echo "  （SSH_PASS 已设：经 scripts/ssh-pass.py 驱动密码认证）"
    python3 "$BUILDER_DIR/scripts/ssh-pass.py" -- rsync "${RSYNC_ARGS[@]}"
  else
    rsync "${RSYNC_ARGS[@]}"
  fi
  echo "  OK：已同步（远端与本次发布一致）"
fi

# 站点根精简页（可选）：把域名根指向软件源入口
if [ "$ROOT_PAGE" = 1 ]; then
  [ -n "$RSYNC_DEST" ] || { echo "错误：--root-page 需要与 --rsync 同用（站点根由 rsync 目标推导）" >&2; exit 1; }
  feed_path="$(basename "${URL%/}")"; [ -n "$feed_path" ] || feed_path="quartz-feed"
  step "站点根精简页 → $feed_path/ 入口"
  bash "$BUILDER_DIR/scripts/gen-feed-page.sh" "$DEST" --url "$URL" --feed-path "$feed_path" \
    --root-out "$DEST/root-index.html"
  remote="${RSYNC_DEST%%:*}"; rpath="${RSYNC_DEST#*:}"; rroot="$(dirname "${rpath%/}")"
  cmd="cp -b '$rpath/root-index.html' '$rroot/index.html' && rm -f '$rpath/root-index.html' && ls -l '$rroot/index.html' '$rroot/index.html~' 2>/dev/null | tail -2"
  if [ -n "${SSH_PASS:-}" ]; then
    python3 "$BUILDER_DIR/scripts/ssh-pass.py" -- ssh -o StrictHostKeyChecking=accept-new "$remote" "$cmd"
  else
    ssh "$remote" "$cmd"
  fi
  echo "  OK：站点根 index.html 已更新（原文件备份为 index.html~）"
fi

step "完成 ✔ 已发布 $n 组：${published[*]}"
echo "  发布根：$DEST"
[ "$MAKE_PAGE" = 1 ] && echo "  页面：$DEST/index.html（公开地址：${URL:-未配置}）"
echo "  发布后自检：scripts/check-feed-live.sh <公开地址>"
