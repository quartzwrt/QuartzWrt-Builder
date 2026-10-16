#!/usr/bin/env bash
# QuartzWrt feed 发布（WP-9 / D10）——把构建产物整理成可直接托管的 apk 仓库树
#
# 产出目录布局与固件 distfeeds 的 URL 约定逐字对应（基座 include/feeds.mk
# FeedSourcesAppendAPK：%U/packages/%A/<feed>/packages.adb 与
# %U/targets/%S/packages/packages.adb）：
#
#   <dest>/packages/<arch>/<feed>/{*.apk,packages.adb,index.json}      ← %U/packages/%A/<feed>/
#   <dest>/targets/<board>/<subtarget>/packages/{*.apk,packages.adb}   ← %U/targets/%S/packages/
#   <dest>/targets/<board>/<subtarget>/{镜像,sha256sums,profiles.json} ← OTA 下载对象
#   <dest>/ota/<board>/<subtarget>.json(+.sig)                         ← OTA 版本清单（usign 签名）
#   <dest>/PUBLISH.txt                                                 ← 发布记录（版本/key id/体积）
#
# 阶段 1（D10）：--feeds quartz,thirdparty（默认，含目标包）→ 配合固件内
# quartz-defaults 的 quartz-feed.list 生效；阶段 2（全量自包含）：--feeds all +
# CONFIG_VERSION_REPO 指向本仓库根（见 docs/SIGNING-OTA.md §6）。
#
# 用法:
#   scripts/publish-feed.sh --base-dir <构建树> --dest <目录> [选项]
#     --arch x86_64            包架构目录（默认 x86_64；设备构建如 aarch64_generic）
#     --board x86 --subtarget 64   目标目录（默认 x86/64；设备如 rockchip/armv8）
#     --feeds quartz,thirdparty|all  发布哪些 feed（默认 quartz,thirdparty）
#     --no-target              不发布目标包（kernel/kmods/base-files）
#     --no-images              不发布镜像与 OTA 清单
#     --ota-key PATH           usign 私钥（默认 $OTA_SIGNING_KEY 或 $QUARTZ_SIGNING_DIR/ota.key）
#     --build-id ID            覆盖 build id（默认读 <base-dir>/files/etc/quartz-build-id）
#     --skip-verify            跳过签名 key id 校验（不推荐）
#     --rsync DEST             发布后 rsync 同步到静态托管（如 NAS：user@nas:/volume1/web/quartzwrt）
#                              —— `-av --delete`；DEST 必须是**专用目录**（--delete 会清理其内容）
#
# 退出码: 0 成功；1 失败（含签名缺失/校验失败——宁可不发布）

set -euo pipefail

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR=""
DEST=""
ARCH="x86_64"
BOARD="x86"
SUBTARGET="64"
FEEDS="quartz,thirdparty"
WITH_TARGET=1
WITH_IMAGES=1
OTA_KEY="${OTA_SIGNING_KEY:-${QUARTZ_SIGNING_DIR:+$QUARTZ_SIGNING_DIR/ota.key}}"
# 缺省兜底：gen-signing-key.sh 的默认目录（~/.quartz-signing/ota.key）——存在即用
if [ -z "$OTA_KEY" ] && [ -f "$HOME/.quartz-signing/ota.key" ]; then
  OTA_KEY="$HOME/.quartz-signing/ota.key"
fi
BUILD_ID=""
SKIP_VERIFY=0
RSYNC_DEST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --base-dir) BASE_DIR="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --board) BOARD="$2"; shift 2 ;;
    --subtarget) SUBTARGET="$2"; shift 2 ;;
    --feeds) FEEDS="$2"; shift 2 ;;
    --no-target) WITH_TARGET=0; shift ;;
    --no-images) WITH_IMAGES=0; shift ;;
    --ota-key) OTA_KEY="$2"; shift 2 ;;
    --build-id) BUILD_ID="$2"; shift 2 ;;
    --skip-verify) SKIP_VERIFY=1; shift ;;
    --rsync) RSYNC_DEST="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（用法见 --help）" >&2; exit 1 ;;
  esac
done

[ -n "$BASE_DIR" ] && [ -d "$BASE_DIR" ] || { echo "错误：--base-dir 构建树不存在" >&2; exit 1; }
[ -n "$DEST" ] || { echo "错误：缺 --dest 输出目录" >&2; exit 1; }

# 变体护栏（2026-10-16 双变体构建）：软件源 / OTA 通道**只发标准版**。
# OTA 清单是镜像数组、设备端 quartz-ota-update 取「首个匹配项」，而按字典序
# docker 版（…-docker-squashfs-…）会排在标准版之前 → 若不拦，OTA 会把所有设备
# 升级成 docker 版。约定：构建树停在标准版（build-local 固定 docker→std 顺序），
# 若树里 dockerd 被选（= docker 变体构建树），直接拒绝发布并提示。
if [ -f "$BASE_DIR/.config" ] && grep -q '^CONFIG_PACKAGE_dockerd=y$' "$BASE_DIR/.config"; then
  echo "错误：当前构建树是 docker 变体（CONFIG_PACKAGE_dockerd=y）——软件源/OTA 只发标准版。" >&2
  echo "      请先以标准版重建（build-local.sh 会以 std 收尾；或 --variants std），再运行本脚本。" >&2
  exit 1
fi

APK="$BASE_DIR/staging_dir/host/bin/apk"
[ -x "$APK" ] || { echo "错误：未找到 host apk（$APK）" >&2; exit 1; }

# OTA 私钥：路径或**内容**（CI Secrets 注入的是内容）——内容落到临时文件
if [ -n "$OTA_KEY" ] && [ ! -f "$OTA_KEY" ]; then
  _tmpkey="$(mktemp)"; chmod 600 "$_tmpkey"
  printf '%s\n' "$OTA_KEY" > "$_tmpkey"
  OTA_KEY="$_tmpkey"
  trap 'rm -f "$_tmpkey"' EXIT
fi

TARGET_REL="$BOARD/$SUBTARGET"
PKG_SRC="$BASE_DIR/bin/packages/$ARCH"
TGT_SRC="$BASE_DIR/bin/targets/$TARGET_REL"

# feed 列表
if [ "$FEEDS" = "all" ]; then
  FEEDS=""
  for d in "$PKG_SRC"/*/; do
    [ -d "$d" ] || continue
    f="$(basename "$d")"
    [ "$f" = "base" ] || [ -n "$(ls "$d"/*.apk 2>/dev/null)" ] || continue
    FEEDS="${FEEDS:+$FEEDS,}$f"
  done
fi

# build id：构建期由 build-local.sh / CI 写入 <树>/files/etc/quartz-build-id（随镜像）；
# 缺失时按 时间戳-短提交 生成（发布记录与 OTA 清单同源）
if [ -z "$BUILD_ID" ]; then
  if [ -f "$BASE_DIR/files/etc/quartz-build-id" ]; then
    BUILD_ID="$(cat "$BASE_DIR/files/etc/quartz-build-id")"
  else
    BUILD_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(git -C "$BUILDER_DIR" rev-parse --short HEAD 2>/dev/null || echo nogit)"
  fi
fi

step() { printf '\n==> %s\n' "$*"; }

# 增量构建残留清理：同名多版本 → 只保留最高版本（与 apk 解析同规则），并**重签索引**
# （发布目录必须与索引自洽；CI 干净构建通常无残留，本地增量构建会有）
# $1 = 目录（含 *.apk 与 packages.adb）
prune_and_resign() {
  local dst="$1" pruned=0
  local -A keep
  local name ver file cur cur_ver cur_file apkf d n v
  while read -r name ver file; do
    cur="${keep[$name]:-}"
    if [ -z "$cur" ]; then keep[$name]="$ver|$file"; continue; fi
    cur_ver="${cur%%|*}"; cur_file="${cur#*|}"
    if [ "$("$APK" version -t "$ver" "$cur_ver")" = ">" ]; then
      rm -f "$cur_file"; pruned=$((pruned+1)); keep[$name]="$ver|$file"
    else
      rm -f "$file"; pruned=$((pruned+1))
    fi
  done < <(
    for apkf in "$dst"/*.apk; do
      [ -f "$apkf" ] || continue
      d="$("$APK" adbdump "$apkf" 2>/dev/null)"
      # 注意：**单包** adbdump 的元信息是 `  name:`/`  version:`（info 块，2 空格无破折号），
      # 而**索引**才是 `  - name:`；单包里带破折号的 `  - name:` 是文件列表条目（lib/etc）——
      # 用错模式会静默匹配到文件名、清理失效（实测踩中：x86 feed 残留 26 个多版本包）
      n="$(printf '%s\n' "$d" | sed -n 's/^  name: //p' | head -1)"
      v="$(printf '%s\n' "$d" | sed -n 's/^  version: //p' | head -1)"
      [ -n "$n" ] && [ -n "$v" ] && printf '%s %s %s\n' "$n" "$v" "$apkf"
    done
  )
  if [ "$pruned" -gt 0 ]; then
    echo "  清理同名旧版本 $pruned 个 → 重签索引"
    [ -s "$BASE_DIR/private-key.pem" ] || { echo "错误：重签索引需要稳定私钥（$BASE_DIR/private-key.pem）——先注入签名密钥" >&2; exit 1; }
    ( cd "$dst" && "$APK" mkndx --root "$BASE_DIR" --keys-dir "$BASE_DIR" --allow-untrusted \
        --sign "$BASE_DIR/private-key.pem" --output packages.adb ./*.apk >/dev/null )
    rm -f "$dst/index.json"   # 旧 index.json 与新集合不一致，宁缺勿错（apk 不消费它）
  fi
}

step "整理 feed：$FEEDS（arch=$ARCH）→ $DEST/packages/$ARCH/"
IFS=',' read -r -a _feeds <<< "$FEEDS"
for f in "${_feeds[@]}"; do
  src="$PKG_SRC/$f"
  [ -d "$src" ] || { echo "错误：feed 目录不存在：$src" >&2; exit 1; }
  [ -f "$src/packages.adb" ] || { echo "错误：$f 缺 packages.adb（先跑构建/package-index）" >&2; exit 1; }
  [ "$(ls "$src"/*.apk 2>/dev/null | wc -l)" -gt 0 ] || { echo "错误：$f 无 .apk 产物" >&2; exit 1; }
  mkdir -p "$DEST/packages/$ARCH/$f"
  cp -f "$src"/*.apk "$src/packages.adb" "$DEST/packages/$ARCH/$f/"
  [ -f "$src/index.json" ] && cp -f "$src/index.json" "$DEST/packages/$ARCH/$f/"
  prune_and_resign "$DEST/packages/$ARCH/$f"
  echo "  $f: $(ls "$DEST/packages/$ARCH/$f"/*.apk | wc -l) 包，$(du -sh "$DEST/packages/$ARCH/$f" | cut -f1)"
done

if [ "$WITH_TARGET" = 1 ]; then
  step "整理目标包 → $DEST/targets/$TARGET_REL/packages/"
  [ -f "$TGT_SRC/packages/packages.adb" ] || { echo "错误：缺目标索引 $TGT_SRC/packages/packages.adb" >&2; exit 1; }
  mkdir -p "$DEST/targets/$TARGET_REL/packages"
  cp -f "$TGT_SRC/packages"/*.apk "$TGT_SRC/packages/packages.adb" "$DEST/targets/$TARGET_REL/packages/"
  [ -f "$TGT_SRC/packages/index.json" ] && cp -f "$TGT_SRC/packages/index.json" "$DEST/targets/$TARGET_REL/packages/"
  prune_and_resign "$DEST/targets/$TARGET_REL/packages"
  echo "  目标包: $(ls "$DEST/targets/$TARGET_REL/packages"/*.apk | wc -l) 个"
fi

# 镜像与 OTA 清单
if [ "$WITH_IMAGES" = 1 ]; then
  step "整理镜像 → $DEST/targets/$TARGET_REL/"
  mkdir -p "$DEST/targets/$TARGET_REL"
  n=0
  for img in "$TGT_SRC"/*-combined*.img.gz "$TGT_SRC"/*-sysupgrade.img.gz "$TGT_SRC"/*-sysupgrade.bin; do
    [ -f "$img" ] || continue
    cp -f "$img" "$DEST/targets/$TARGET_REL/"; n=$((n+1))
  done
  for meta in sha256sums profiles.json version.buildinfo config.buildinfo; do
    [ -f "$TGT_SRC/$meta" ] && cp -f "$TGT_SRC/$meta" "$DEST/targets/$TARGET_REL/"
  done
  echo "  镜像: $n 个"
  [ "$n" -gt 0 ] || { echo "错误：未找到可发布镜像" >&2; exit 1; }

  step "生成 OTA 清单（usign 签名）"
  [ -n "$OTA_KEY" ] && [ -f "$OTA_KEY" ] || {
    echo "错误：缺 OTA usign 私钥（--ota-key 或 OTA_SIGNING_KEY/QUARTZ_SIGNING_DIR/ota.key）" >&2; exit 1; }
  USIGN=""
  for cand in "$BASE_DIR/staging_dir/host/bin/usign" "$(command -v usign 2>/dev/null || true)"; do
    [ -n "$cand" ] && [ -x "$cand" ] && USIGN="$cand" && break
  done
  [ -n "$USIGN" ] || { echo "错误：未找到 usign" >&2; exit 1; }

  revision="$(cat "$TGT_SRC/version.buildinfo" 2>/dev/null || echo unknown)"
  mkdir -p "$DEST/ota/$BOARD"
  manifest="$DEST/ota/$BOARD/$SUBTARGET.json"
  {
    echo "{"
    echo "  \"schema\": \"quartzwrt-ota/1\","
    echo "  \"dist\": \"QuartzWrt\","
    echo "  \"base\": \"ImmortalWrt 25.12\","
    echo "  \"build_id\": \"$BUILD_ID\","
    echo "  \"revision\": \"$revision\","
    echo "  \"target\": \"$TARGET_REL\","
    echo "  \"generated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"images\": ["
    first=1
    for img in "$DEST/targets/$TARGET_REL"/*-combined*.img.gz "$DEST/targets/$TARGET_REL"/*-sysupgrade.img.gz "$DEST/targets/$TARGET_REL"/*-sysupgrade.bin; do
      [ -f "$img" ] || continue
      name="$(basename "$img")"
      sha="$(sha256sum "$img" | cut -d' ' -f1)"
      size="$(stat -c%s "$img")"
      [ "$first" = 1 ] || echo "    ,"
      first=0
      printf '    {"name": "%s", "path": "targets/%s/%s", "sha256": "%s", "size": %s}' \
        "$name" "$TARGET_REL" "$name" "$sha" "$size"
    done
    echo ""
    echo "  ]"
    echo "}"
  } > "$manifest"
  "$USIGN" -S -m "$manifest" -s "$OTA_KEY" -x "$manifest.sig"
  echo "  $manifest (+ .sig)"
fi

# 签名一致性校验（默认开）
if [ "$SKIP_VERIFY" = 0 ]; then
  step "签名一致性校验"
  bash "$BUILDER_DIR/scripts/verify-signing.sh" "$BASE_DIR" --arch "$ARCH" --feeds "$FEEDS" --targets "$BOARD/$SUBTARGET"
fi

# 发布记录
step "发布记录"
{
  echo "QuartzWrt feed publish"
  echo "date:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "build_id:  $BUILD_ID"
  echo "arch:      $ARCH"
  echo "target:    $TARGET_REL"
  echo "feeds:     $FEEDS"
  echo "dest:      $DEST"
  if [ -f "$BASE_DIR/public-key.pem" ]; then
    . "$BUILDER_DIR/scripts/lib-keyid.sh"
    echo "apk key id: $(quartz_apk_key_id "$BASE_DIR/public-key.pem")"
  fi
  if [ -n "$OTA_KEY" ] && [ -f "$OTA_KEY" ] && [ -x "$BASE_DIR/staging_dir/host/bin/usign" ]; then
    echo "ota key:   $("$BASE_DIR/staging_dir/host/bin/usign" -F -s "$OTA_KEY" 2>/dev/null || echo unknown)"
  fi
  echo "size:      $(du -sh "$DEST" | cut -f1)"
} > "$DEST/PUBLISH.txt"
sed -n '1,20p' "$DEST/PUBLISH.txt"

if [ -n "$RSYNC_DEST" ]; then
  step "同步到静态托管：$RSYNC_DEST（rsync -av --delete --chmod=D755,F644）"
  command -v rsync >/dev/null || { echo "错误：缺少 rsync" >&2; exit 1; }
  case "$RSYNC_DEST" in
    *:*) : ;;  # 远程（ssh）形态
    *) [ -d "$RSYNC_DEST" ] || { echo "错误：本地目标目录不存在：$RSYNC_DEST" >&2; exit 1; } ;;
  esac
  RSYNC_ARGS=(-av --delete --chmod=D755,F644 "$DEST"/ "$RSYNC_DEST"/)
  if [ -n "${SSH_PASS:-}" ] && [ -x "$BUILDER_DIR/scripts/ssh-pass.py" ]; then
    # 远端需密码（如 NAS 未放 SSH key）：经 pty 助手驱动 rsync 的密码提示
    echo "  （SSH_PASS 已设：经 scripts/ssh-pass.py 驱动密码认证）"
    python3 "$BUILDER_DIR/scripts/ssh-pass.py" -- rsync "${RSYNC_ARGS[@]}"
  else
    rsync "${RSYNC_ARGS[@]}"
  fi
  echo "  OK：已同步（远端内容与本次发布一致，含同名旧版本清理）"
fi

step "完成 ✔ 发布目录：$DEST（根即 URL 根）"
echo "  固件侧接入（#41 阶段 1 翻转）：config/seed.config 设"
echo "    CONFIG_QUARTZ_FEED_BASE_URL=\"<你的托管根 URL>\""
echo "  发布后可用 scripts/check-feed-live.sh <托管根 URL> 复核（可达性/签名/翻转前置）"
