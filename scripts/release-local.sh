#!/usr/bin/env bash
# QuartzWrt 本地构建 → GitHub Release 发布（WP-9）
#
# 定位：CI（build.yml）与本地构建是**等价的构建通道**——两者注入同一把稳定签名密钥
# （CI 用 Secrets，本地用 QUARTZ_SIGNING_DIR），产物签名/信任根完全一致（见
# docs/SIGNING-OTA.md §11）；本脚本负责"本地构建 → 校验 → 打包 → 发 Release"这条发布路径。
#
# 流程：可选构建（--build，构建标识绑定发布 tag）→ 签名校验（**硬门禁**，不过不发）
#       → 收集产物（镜像/manifest/sha256sums/profiles.json/OTA 清单，多架构）→ 可选发布 feed
#       （--publish-feed [--rsync DEST]）→ `gh release create`（已存在则 upload --clobber）
#
# 用法:
#   scripts/release-local.sh --tag v0.1.0 [--build] [--device erya_fnet-3399]
#                            [--variants std,docker]  # 默认两个变体都发（2026-10-16 用户指令）
#                            [--also-device <名>]   # 额外带上另一设备的镜像/manifest（同构建树内已有产物）
#                            [--publish-feed [--rsync user@nas:/path/quartz-feed]]
#                            [--draft] [--notes FILE] [--no-feed-tarball] [--dry-run]
#
# 约定:
#   - 发布构建建议 `--build`：以 tag 作为 /etc/quartz-build-id（OTA 版本比较依据，
#     本地与 CI 同 tag → 同标识）；不带 --build 时读取构建树内已有标识并与 tag 比对提示。
#   - 镜像格式：**只发 squashfs**（2026-10-16 用户指令，ext4 已停止构建）。
#   - 变体：std（标准版）与 docker（预装 docker 栈）**都发**；docker 资产名带 `-docker`
#     标记（插在 squashfs/manifest/buildinfo 标记之前，如
#     `…-erya_fnet-3399-docker-squashfs-sysupgrade.img.gz`），取自 `artifacts-local*`
#     构建产物目录（build-local.sh 按变体收集）；树内只留标准版。
#   - Release 资产：镜像 *.img.gz、*.manifest、*.buildinfo、sha256sums、profiles.json、
#     OTA 清单（ota/<board>/<subtarget>.json(.sig)，**只含标准版**——OTA 通道口径见
#     docs/SIGNING-OTA.md §14），以及 feed 快照 quartz-feed-<tag>.tar.gz
#     （不含镜像，解压后根即 URL 根，供自建镜像站/离线用）。
#   - 需要可复现构建时设 QUARTZ_SOURCE_DATE_EPOCH（本地与 CI 同值），见 build-local.sh。

set -euo pipefail

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${QUARTZ_WORK_DIR:-$BUILDER_DIR/../build}"
BASE_DIR="$WORK_DIR/immortalwrt"
TAG=""
DO_BUILD=0
DEVICE="${QUARTZ_DEVICE:-}"
DO_PUBLISH_FEED=0
RSYNC_DEST=""
DRAFT=""
NOTES_FILE=""
FEED_TARBALL=1
DRY_RUN=0
ALSO_DEVICE=""
EXTRA_BINS=()
VARIANT_LIST="${QUARTZ_VARIANTS:-std,docker}"

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --build) DO_BUILD=1; shift ;;
    --device) DEVICE="$2"; shift 2 ;;
    --variants) VARIANT_LIST="$2"; shift 2 ;;
    --variants=*) VARIANT_LIST="${1#--variants=}"; shift ;;
    --publish-feed) DO_PUBLISH_FEED=1; shift ;;
    --rsync) RSYNC_DEST="$2"; shift 2 ;;
    --draft) DRAFT="--draft"; shift ;;
    --notes) NOTES_FILE="$2"; shift 2 ;;
    --no-feed-tarball) FEED_TARBALL=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --also-device) ALSO_DEVICE="$2"; shift 2 ;;
    --base-dir) BASE_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（用法见 --help）" >&2; exit 1 ;;
  esac
done

[ -n "$TAG" ] || { echo "错误：缺 --tag（如 --tag v0.1.0）" >&2; exit 1; }
case "$TAG" in v*) : ;; *) echo "警告：tag 不以 v 开头（建议 vX.Y.Z）";; esac
command -v gh >/dev/null || { echo "错误：缺少 gh CLI" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "错误：gh 未登录（gh auth login）" >&2; exit 1; }

step() { printf '\n==> [%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# 目标域（x86 默认 / 设备）
if [ -n "$DEVICE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$BUILDER_DIR/devices/$DEVICE/device.env"; set +a
  TARGET_BIN="$BASE_DIR/bin/targets/$DEVICE_TARGET/$DEVICE_SUBTARGET"
  ARCH_PKGS="$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\?\([^"]*\)"\?$/\1/p' "$BASE_DIR/.config" | head -1)"
  BOARD="$DEVICE_TARGET"; SUB="$DEVICE_SUBTARGET"
else
  TARGET_BIN="$BASE_DIR/bin/targets/x86/64"
  ARCH_PKGS="x86_64"; BOARD="x86"; SUB="64"
fi

# 已发布根（feed-out）：存在则作为发布树/feed 快照的基底（保留其它架构与页面；
# 见步骤 3 的 publish_feed_tree）。缺失（首次发布）时退回"仅从构建树收集"。
FEED_SEED=""
if [ -d "$BUILDER_DIR/../feed-out" ]; then FEED_SEED="$BUILDER_DIR/../feed-out"; fi

# 1. 构建（可选；默认两个变体，见 build-local.sh --variants）
if [ "$DO_BUILD" = 1 ]; then
  step "本地构建（构建标识 = $TAG；变体 = $VARIANT_LIST）"
  QUARTZ_BUILD_ID="$TAG" bash "$BUILDER_DIR/scripts/build-local.sh" ${DEVICE:+--device "$DEVICE"} --variants "$VARIANT_LIST"
fi

[ -d "$TARGET_BIN" ] || { echo "错误：未找到目标产物目录：$TARGET_BIN（先构建）" >&2; exit 1; }

# 2. 签名校验（硬门禁）
step "签名校验（未通过不发布）"
bash "$BUILDER_DIR/scripts/verify-signing.sh" "$BASE_DIR" --arch "${ARCH_PKGS:-x86_64}" --targets "$BOARD/$SUB"

# 附带设备产物（同一构建树内已构建的其它目标）
if [ -n "$ALSO_DEVICE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$BUILDER_DIR/devices/$ALSO_DEVICE/device.env"; set +a
  EXTRA_BINS+=("$BASE_DIR/bin/targets/$DEVICE_TARGET/$DEVICE_SUBTARGET")
  echo "附带设备产物：$ALSO_DEVICE → $DEVICE_TARGET/$DEVICE_SUBTARGET"
  set +a
fi

# 3. 发布目录：产物（两变体）+ feed + OTA 清单
OUT="$BUILDER_DIR/../release-out/$TAG"
step "整理发布产物 → $OUT"
rm -rf "$OUT"; mkdir -p "$OUT"

# 变体产物目录（与 build-local.sh 同规则）：std → <基>；docker → <基>-docker
ARTIFACTS_BASE="${QUARTZ_ARTIFACTS_DIR:-$BUILDER_DIR/../artifacts-local${DEVICE:+/$DEVICE}}"
variant_artifacts_dir() {
  if [ "$1" = "docker" ]; then printf '%s-docker' "$ARTIFACTS_BASE"; else printf '%s' "$ARTIFACTS_BASE"; fi
}

# ① 树内取与包集合无关的元数据（sha256sums/profiles.json，变体间一致）+ 变异前的
#    *.buildinfo（std 名）；树此时为**标准版终态**（build-local 固定 docker→std 顺序）。
for bin in "$TARGET_BIN" ${EXTRA_BINS[@]+"${EXTRA_BINS[@]}"}; do
  [ -d "$bin" ] || continue
  find "$bin" -maxdepth 1 -type f \( -name '*.buildinfo' -o -name 'sha256sums' -o -name 'profiles.json' \) \
    -exec cp {} "$OUT/" \;
done

# ② 变体镜像/manifest 取自 build-local 的产物目录（已按变体改名；树内只有标准版）
for v in ${VARIANT_LIST//,/ }; do
  vdir="$(variant_artifacts_dir "$v")"
  if [ ! -d "$vdir" ]; then
    if [ "$v" = "std" ]; then
      echo "  注：未找到标准版产物目录 $vdir —— 回退从构建树收集（未按变体改名）"
      find "$TARGET_BIN" -maxdepth 1 -type f \( -name '*.img.gz' -o -name '*sysupgrade*.bin' -o -name '*.manifest' \) -exec cp {} "$OUT/" \;
      continue
    fi
    echo "  WARN: 未找到变体 $v 的产物目录 $vdir —— 该变体不进本次发布（先跑 build-local.sh --variants $VARIANT_LIST）" >&2
    continue
  fi
  n=0
  while IFS= read -r -d '' f; do
    case "$(basename "$f")" in *ext4*) continue ;; esac   # 只发 squashfs（2026-10-16）
    cp -f "$f" "$OUT/"; n=$((n+1))
  done \
    < <(find "$vdir" -maxdepth 1 -type f \( -name '*.img.gz' -o -name '*sysupgrade*.bin' -o -name '*.manifest' -o -name '*.buildinfo' \) -print0)
  echo "  变体 $v：$n 个文件 ← $vdir"
done
if [ "$DO_PUBLISH_FEED" = 1 ] || [ "$FEED_TARBALL" = 1 ]; then
  # 发布对 = **本次构建目标**（设备模式=设备目标，否则 x86/64）。默认双架构对会把
  # **未重建目标**的 OTA 清单盖上本次 build id（清单报新版本而镜像内仍是旧 id →
  # 该目标设备 OTA 循环），故此处显式限定；其它架构内容由"已发布根"继承（见下）。
  FEED_PAIRS="$ARCH_PKGS:$BOARD:$SUB"
  publish_feed_tree() {
    local dest="$1"; shift
    # 以已发布根（feed-out）为底：保留其它架构/页面/历史，使 feed 快照为全量快照
    if [ -n "$FEED_SEED" ] && [ ! -d "$dest" ]; then
      echo "    以已发布根为底：$FEED_SEED → $dest"
      cp -a "$FEED_SEED" "$dest"
    fi
    bash "$BUILDER_DIR/scripts/publish-feed-all.sh" --base-dir "$BASE_DIR" --dest "$dest" \
         --pairs "$FEED_PAIRS" "$@"
  }
  publish_feed_tree "$OUT/feed"
  for j in "$OUT/feed"/ota/*/*.json; do
    [ -f "$j" ] || continue
    b="$(basename "$(dirname "$j")")"; sname="$(basename "$j" .json)"
    cp -f "$j" "$OUT/ota-$b-$sname.json"
    cp -f "$j.sig" "$OUT/ota-$b-$sname.json.sig" 2>/dev/null || true
  done
  if [ "$FEED_TARBALL" = 1 ]; then
    step "打包 feed 快照（不含镜像；含软件源页面）"
    ( cd "$OUT/feed" && tar --exclude='*.img.gz' --exclude='*.bin' -czf "$OUT/quartz-feed-$TAG.tar.gz" . )
    echo "  $(ls -lh "$OUT/quartz-feed-$TAG.tar.gz" | awk '{print $5}')"
  fi
fi

# 4. 可选：发布 feed 到静态托管（NAS）
if [ "$DO_PUBLISH_FEED" = 1 ] && [ -n "$RSYNC_DEST" ]; then
  step "发布 feed 到托管：$RSYNC_DEST（当前构建目标对 + 页面，一次同步）"
  publish_feed_tree "$OUT/feed" --rsync "$RSYNC_DEST"
fi

# 5. 发布说明
BUILD_ID="$(cat "$BASE_DIR/files/etc/quartz-build-id" 2>/dev/null || echo unknown)"
if [ "$DO_BUILD" = 0 ] && [ "$BUILD_ID" != "$TAG" ]; then
  echo "警告：构建树内标识（$BUILD_ID）≠ 发布 tag（$TAG）——若这是发布构建，建议用"
  echo "      --build（构建标识绑定 tag），否则 OTA 版本比较会以旧标识为准。"
fi
. "$BUILDER_DIR/scripts/lib-keyid.sh"
KEY_ID="$(quartz_apk_key_id "$BASE_DIR/public-key.pem" 2>/dev/null || echo unknown)"
BASE_COMMIT="$(sed -n 's/^BASE_COMMIT=//p' "$BUILDER_DIR/config/base.env" | head -1)"
Q_LOCK="$(sed -n 's|^src-git quartz .*\^\([0-9a-f]*\)$|\1|p' "$BUILDER_DIR/config/feeds.conf.extra" | head -1)"
T_LOCK="$(sed -n 's|^src-git thirdparty .*\^\([0-9a-f]*\)$|\1|p' "$BUILDER_DIR/config/feeds.conf.extra" | head -1)"
FEED_URL="$(sed -n 's/^CONFIG_QUARTZ_FEED_BASE_URL="\?\([^"]*\)"\?$/\1/p' "$BASE_DIR/.config" | head -1)"

if [ -z "$NOTES_FILE" ]; then
  NOTES_FILE="$OUT/RELEASE-NOTES.md"
  cat > "$NOTES_FILE" <<EOF
# QuartzWrt $TAG

**构建标识（build id）**：\`$BUILD_ID\`　（设备侧 \`/etc/quartz-build-id\`；OTA 版本比较依据）
**基座**：ImmortalWrt 25.12 @ \`${BASE_COMMIT:0:12}\`
**Feed 锁定**：quartz @ \`${Q_LOCK:0:12}\`；thirdparty @ \`${T_LOCK:0:12}\`
**签名**：apk key id \`$KEY_ID\`（本地与 CI 同一把稳定密钥，产物互认）
**软件源**：\`${FEED_URL:-（未配置）}\`

## 产物（两个变体：标准版与 \`-docker\` 版；**只发 squashfs**，ext4 已停止构建）

| 文件 | 用途 |
| :--- | :--- |
| \`*-squashfs-combined*.img.gz\` | x86_64 完整磁盘镜像（\`-efi\` 为 UEFI 引导） |
| \`*-docker-squashfs-*.img.gz\` | 同上 + **预装 docker 栈**（dockerd/containerd/compose + dockerman 页） |
| \`*-sysupgrade.bin\` | 设备 sysupgrade 镜像（H5000M 等 filogic 目标；\`-docker\` 版同名带标记） |
| \`*.manifest\` / \`*-docker.manifest\` | 包清单（两变体各一份；\`-docker\` 版含 docker 栈） |
| \`sha256sums\` / \`profiles.json\` | 校验和（\`sha256sum -c sha256sums\`）/ 设备档案 |
| \`ota/$BOARD/$SUB.json(.sig)\` | OTA 版本清单（usign 签名；**只含标准版**，见下"固件 OTA"注） |
| \`quartz-feed-$TAG.tar.gz\` | 本版 feed 快照（不含镜像；解压后根即 URL 根，供自建源/离线） |

## 安装与升级
- 刷写：把 \`*.img.gz\` 解压后写盘（x86 软路由/虚拟机；EFI 机器用 \`-efi\` 版）；
  filogic 设备的 \`*-sysupgrade.bin\` 直接用于系统升级/刷写。
  需要 docker 的机器请选文件名带 \`-docker\` 的镜像（两版除 docker 栈外内容一致）；
  docker 变体已预置 nftables 后端配方（\`/etc/docker/daemon.json\` + dockerd uci），
  与 fw4 无「检测到旧版规则」告警（机理见 Builder \`docs/SIGNING-OTA.md\` 与坑位 #24）。
- 包升级（设备）：\`apk update && apk upgrade\`（源 = 上述"软件源"；索引签名由固件预置公钥校验）。
- 固件 OTA（设备）：\`quartz-ota-update --check\` → \`quartz-ota-update --apply\`
  （信任链：OTA 清单 usign 验签 → 镜像 sha256 → \`sysupgrade\` 预检）。
  **注意**：OTA 通道只发标准版——docker 版设备执行 OTA 会升级为标准版；需要 docker 版
  请手动下载对应镜像刷写（\`sysupgrade\`）。
- 签名/密钥与本地构建说明：见 Builder \`docs/SIGNING-OTA.md\`。
EOF
fi

# 6. 发布（显式资产列表：不含 feed/ 目录本身，feed 以 tarball 形式发布）
ASSETS=()
for f in "$OUT"/*.img.gz "$OUT"/*sysupgrade*.bin "$OUT"/*.manifest "$OUT"/*.buildinfo "$OUT"/sha256sums "$OUT"/profiles.json \
         "$OUT"/ota-*.json "$OUT"/ota-*.json.sig "$OUT"/quartz-feed-*.tar.gz; do
  [ -f "$f" ] && ASSETS+=("$f")
done
[ "${#ASSETS[@]}" -gt 0 ] || { echo "错误：无资产可发布" >&2; exit 1; }

step "GitHub Release：$TAG（${#ASSETS[@]} 个资产）"
printf '  %s\n' "${ASSETS[@]##*/}"
if [ "$DRY_RUN" = 1 ]; then
  echo "  --dry-run：跳过实际发布（说明文件：$NOTES_FILE）"
elif gh release view "$TAG" >/dev/null 2>&1; then
  echo "  Release 已存在 → 覆盖上传资产"
  gh release upload "$TAG" "${ASSETS[@]}" --clobber
else
  gh release create "$TAG" --title "QuartzWrt $TAG" --notes-file "$NOTES_FILE" $DRAFT "${ASSETS[@]}"
fi

step "完成 ✔"
echo "  Release：$(gh release view "$TAG" --json url -q .url 2>/dev/null || echo "（见 GitHub Releases）")"
echo "  构建标识：$BUILD_ID；apk key id：$KEY_ID"
echo "  本地发布目录（可复用/手动上传）：$OUT"
echo "  设备侧复核建议：apk update（无 UNTRUSTED）→ quartz-ota-update --check"
