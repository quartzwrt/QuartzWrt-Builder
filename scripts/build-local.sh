#!/usr/bin/env bash
# QuartzWrt 本地构建脚本（docs/TDD.md §7.4）
#
# 复刻 .github/workflows/build.yml 的关键步骤，用于开发迭代与调试：
#   基座检出（锁定 commit）→ feeds 追加注入 → update/install → 同名包检查
#   → 设备适配层（可选）→ ccache → 分层种子装配（compose-seed.sh）+ defconfig + Gate A → make
#   → manifest 校验 → 产物收集
#
# CI 是权威构建与发布通道；本脚本产物仅用于本地调试，禁止作为发布件分发。
# 与 CI 的步骤必须保持一致，任一侧变更需同步另一侧（docs/TDD.md §7.4）。
# 公共步骤（设备适配应用、manifest 校验）已抽为 scripts/{apply-device,check-manifest}.sh，
# 两侧共用，避免漂移。
#
# 用法:
#   scripts/build-local.sh                    # 默认目标 x86_64 generic；默认构建 std+docker 两个变体
#   scripts/build-local.sh --device erya_fnet-3399   # 设备构建（devices/ 适配层）
#   scripts/build-local.sh --variants std     # 只构建标准版（开发迭代快路径）
#   scripts/build-local.sh --variants docker  # 只构建 docker 变体（等价 --docker）
#
# 变体（2026-10-16 用户指令：「编译分别带/不带 docker 的固件」）：
#   std    —— 标准版（不含 docker 栈；check-manifest 的 docker 反向断言生效）
#   docker —— 预装 docker 栈（config/preinstall/docker.config + docker.files 配方；
#             断言翻为正向后端 nftables）
#   构建顺序固定 docker → std：构建树最终状态 = 标准版，publish-feed.sh 的 OTA 清单
#   与软件源 targets 目录据此取件（**OTA 只发标准版**），docker 版产物在 std 构建
#   覆盖镜像之前已收集到独立目录（<产物目录>-docker）。
#
# 环境变量:
#   QUARTZ_WORK_DIR       构建工作目录（默认 <Builder 仓库>../build）
#   QUARTZ_ARTIFACTS_DIR  产物输出目录（默认 <Builder 仓库>../artifacts-local[，设备构建加 /<设备名>]；
#                         docker 变体写到 <该目录>-docker）
#   QUARTZ_VARIANTS       等价于 --variants（命令行优先；默认 std,docker）
#   QUARTZ_DEVICE         等价于 --device（命令行优先）
#   QUARTZ_BUILD_ID       构建标识（随镜像 /etc/quartz-build-id；发布构建建议用发布 tag，
#                         如 QUARTZ_BUILD_ID=v0.1.0——OTA 版本比较依据，见 docs/SIGNING-OTA.md）
#   QUARTZ_SOURCE_DATE_EPOCH  可复现构建：固定 SOURCE_DATE_EPOCH（基座据此固定包/镜像
#                         内时间戳；本地与 CI 用同一值可让同机重复构建逐字节一致）
#   QUARTZ_SIGNING_DIR    签名密钥目录（见 scripts/inject-signing-key.sh；发布构建必给）
#   QUARTZ_SKIP_FEEDS_UPDATE=1  离线/网络故障：跳过 feeds update，仅 install 当前已锁定内容
#                         （用于基座树已有正确 feeds 的增量重建；不要用于首次/换锁构建）
#   QUARTZ_SKIP_BASE_FETCH=1    离线/网络故障：跳过基座 git fetch（仍 checkout 锁定 commit；
#                         基座树必须已存在且包含该 commit）
#   JOBS                  make 并行度（默认 16；本机 15GB 内存勿再调高）

set -euo pipefail

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${QUARTZ_WORK_DIR:-$BUILDER_DIR/../build}"
BASE_DIR="$WORK_DIR/immortalwrt"
JOBS="${JOBS:-16}"
CCACHE_DIR="${CCACHE_DIR:-$WORK_DIR/ccache}"

DEVICE="${QUARTZ_DEVICE:-}"
VARIANT_LIST="${QUARTZ_VARIANTS:-std,docker}"
while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="${2:?--device 需要参数：设备名（devices/<设备名>/）}"; shift 2 ;;
    --device=*) DEVICE="${1#--device=}"; shift ;;
    --variants) VARIANT_LIST="${2:?--variants 需要参数：std / docker / std,docker}"; shift 2 ;;
    --variants=*) VARIANT_LIST="${1#--variants=}"; shift ;;
    --docker) VARIANT_LIST="docker"; shift ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（用法见 --help）" >&2; exit 1 ;;
  esac
done

# 变体列表校验 + 构建顺序（固定 docker 先、std 后，见头部说明）
VARIANTS=()
for v in ${VARIANT_LIST//,/ }; do
  case "$v" in
    std|docker) ;;
    *) echo "错误：未知变体 '$v'（可选：std / docker）" >&2; exit 1 ;;
  esac
  VARIANTS+=("$v")
done
[ "${#VARIANTS[@]}" -gt 0 ] || { echo "错误：--variants 为空（可选：std / docker）" >&2; exit 1; }
BUILD_ORDER=()
for v in docker std; do
  for w in "${VARIANTS[@]}"; do [ "$v" = "$w" ] && BUILD_ORDER+=("$v"); done
done

# 设备参数校验 + 元数据装载（docs/TDD.md §4.6）
if [ -n "$DEVICE" ]; then
  DEVICE_ENV="$BUILDER_DIR/devices/$DEVICE/device.env"
  [ -f "$DEVICE_ENV" ] || {
    echo "错误：设备不存在：$DEVICE（应为 devices/<设备名>/，现有：$(ls "$BUILDER_DIR/devices" 2>/dev/null | tr '\n' ' '))" >&2
    exit 1
  }
  # shellcheck disable=SC1090
  set -a; . "$DEVICE_ENV"; set +a
  TARGET_ID="$DEVICE_TARGET_ID"
  ARTIFACTS_BASE="${QUARTZ_ARTIFACTS_DIR:-$BUILDER_DIR/../artifacts-local/$DEVICE}"
  TARGET_BIN_DIR="$BASE_DIR/bin/targets/${DEVICE_TARGET}/${DEVICE_SUBTARGET}"
else
  TARGET_ID="x86-64-generic"
  ARTIFACTS_BASE="${QUARTZ_ARTIFACTS_DIR:-$BUILDER_DIR/../artifacts-local}"
  TARGET_BIN_DIR="$BASE_DIR/bin/targets/x86/64"
fi
TARGET_STAMP="$WORK_DIR/.quartz-target"

step() { printf '\n==> [%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

# 构建目录必须在 Linux 文件系统上：WSL 下 /mnt/c 大小写不敏感会破坏构建（坑位 #3）
if grep -qi microsoft /proc/version && [[ "$WORK_DIR" == /mnt/* ]]; then
  echo "错误：WSL 下构建目录不能位于 /mnt/*（大小写不敏感），请通过 QUARTZ_WORK_DIR 指定 /home 下的路径。" >&2
  exit 1
fi

# PATH 净化：WSL 会把 Windows PATH 追加进来（/mnt/c/...，含空格条目），
# GNU find 的 -execdir 安全检查会直接报错（rust host 包安装阶段实测），
# 构建期一律剔除：只保留绝对 Linux 路径，且排除 /mnt/*。
_clean_path=""
IFS=':' read -r -a _path_entries <<< "$PATH"
for _p in "${_path_entries[@]}"; do
  [[ -z "$_p" || "$_p" != /* || "$_p" == /mnt/* ]] && continue
  _clean_path="${_clean_path:+$_clean_path:}$_p"
done
export PATH="$_clean_path"

# 依赖预检：与 docs/TDD.md §7.4 前置条件一致（awk 不能是 mawk）
step "构建依赖预检"
for cmd in time libtoolize zstd node gawk git file flex bison unzip rsync wget python3; do
  command -v "$cmd" >/dev/null || { echo "错误：缺少 $cmd，请先补齐 OpenWrt 构建依赖（docs/TDD.md §7.4）。" >&2; exit 1; }
done
if [[ "$(readlink -f "$(command -v awk)")" == *mawk ]]; then
  echo "错误：/usr/bin/awk 指向 mawk，请切换为 gawk（update-alternatives --config awk）。" >&2
  exit 1
fi
echo "OK"

# 0. 构建目标（默认 x86_64；--device 时为设备目标）
step "构建目标：$TARGET_ID${DEVICE:+（设备适配：$DEVICE）}　·　变体：${BUILD_ORDER[*]}"

# 1. 基座锁定参数（docs/TDD.md §4.2）
step "加载基座版本（config/base.env）"
set -a; . "$BUILDER_DIR/config/base.env"; set +a
echo "$BASE_OWNER_REPO @ $BASE_BRANCH ($BASE_COMMIT)"

mkdir -p "$WORK_DIR"

# 2. 检出 / 更新基座到锁定 commit，不随上游滚动
step "检出 ImmortalWrt 基座到锁定 commit"
if [ "${QUARTZ_SKIP_BASE_FETCH:-0}" = 1 ]; then
  [ -d "$BASE_DIR/.git" ] || { echo "错误：QUARTZ_SKIP_BASE_FETCH=1 但基座树不存在" >&2; exit 1; }
  git -C "$BASE_DIR" cat-file -e "$BASE_COMMIT^{commit}" 2>/dev/null || {
    echo "错误：QUARTZ_SKIP_BASE_FETCH=1 但基座树缺少 commit $BASE_COMMIT" >&2; exit 1; }
  echo "跳过基座 fetch（QUARTZ_SKIP_BASE_FETCH=1）"
else
  if [ -d "$BASE_DIR/.git" ]; then
    git -C "$BASE_DIR" fetch origin "$BASE_BRANCH"
  else
    git clone "https://github.com/$BASE_OWNER_REPO.git" "$BASE_DIR"
  fi
fi
git -C "$BASE_DIR" checkout "$BASE_COMMIT"

# 3. feeds 注入：在基座默认 feeds.conf 末尾追加双 Feed，不覆写（坑位 #2）
step "注入 feeds.conf（追加双 Feed）"
cp "$BASE_DIR/feeds.conf.default" "$BASE_DIR/feeds.conf"
cat "$BUILDER_DIR/config/feeds.conf.extra" >> "$BASE_DIR/feeds.conf"
tail -n 4 "$BASE_DIR/feeds.conf"

# 4. feeds update / install
# 两个自有 feed 锁定为 commit（双 Feed 定义中的 ^SHA）：scripts/feeds 对已存在的
# checkout 会直接跳过（源码注释 "in case git hash has been provided don't update
# the feed"），配置改 SHA 后不会重新检出。因此每轮强制删除旧目录，保证按锁定
# SHA 重新克隆、修复包增删后的残留（CI 每次全新检出，无此问题）。
if [ "${QUARTZ_SKIP_FEEDS_UPDATE:-0}" = 1 ]; then
  step "feeds install（QUARTZ_SKIP_FEEDS_UPDATE=1：跳过网络更新，使用已锁定/已安装 feeds）"
  (cd "$BASE_DIR" && ./scripts/feeds install -a)
else
  step "feeds update + install"
  rm -rf "$BASE_DIR/feeds/quartz" "$BASE_DIR/feeds/thirdparty" \
         "$BASE_DIR/package/feeds/quartz" "$BASE_DIR/package/feeds/thirdparty"
  (cd "$BASE_DIR" && ./scripts/feeds update -a && ./scripts/feeds install -a)
fi
for f in quartz thirdparty; do
  echo "feed $f @ $(git -C "$BASE_DIR/feeds/$f" rev-parse HEAD)"
done

# 5. 双 Feed 同名包检查（docs/TDD.md §4.5）
step "同名包检查"
bash "$BUILDER_DIR/scripts/check-duplicate-packages.sh" "$BASE_DIR/feeds"

# 5b. 设备适配层（可选）：基座补丁 + files overlay（docs/TDD.md §4.6）
if [ -n "$DEVICE" ]; then
  step "应用设备适配层：$DEVICE"
  bash "$BUILDER_DIR/scripts/apply-device.sh" "$BASE_DIR" "$DEVICE"
fi

# 5c. 签名密钥注入（WP-9）：稳定密钥 → 构建树 TOPDIR（feed 索引签名 + 固件信任根）。
#     未提供密钥时为开发构建（基座自生成临时密钥，feed 不可发布）——发布构建
#     必须提供 QUARTZ_SIGNING_DIR（本地）或 APK_SIGNING_PRIVATE_KEY（CI Secrets）。
step "注入签名密钥（WP-9，docs/SIGNING-OTA.md）"
bash "$BUILDER_DIR/scripts/inject-signing-key.sh" "$BASE_DIR"

# 5d. 构建标识：随镜像投放 /etc/quartz-build-id（TOPDIR/files 原样覆盖进 rootfs），
#     publish-feed.sh 的 OTA 清单与设备端 quartz-ota-update 以它判定版本新旧。
#     同机制再写 /etc/quartz-release（QUARTZ_DESCRIPTION，dashboard/App 显示的版本串）——
#     覆盖 quartz-defaults 的兜底值：发布构建显示 tag，开发构建显示构建标识。
#     发布构建建议 QUARTZ_BUILD_ID=<发布 tag>（本地与 CI 同 tag → 同标识，OTA 不误判）。
step "写入构建标识（/etc/quartz-build-id + /etc/quartz-release）"
BUILD_ID="${QUARTZ_BUILD_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$(git -C "$BUILDER_DIR" rev-parse --short HEAD 2>/dev/null || echo nogit)}"
mkdir -p "$BASE_DIR/files/etc"
printf '%s\n' "$BUILD_ID" > "$BASE_DIR/files/etc/quartz-build-id"
printf "# 由构建生成（覆盖 quartz-defaults 兜底值）：QuartzWrt 发行版标识\nQUARTZ_DESCRIPTION='QuartzWrt %s (ImmortalWrt %s)'\n" \
  "$BUILD_ID" "${BASE_BRANCH#openwrt-}" > "$BASE_DIR/files/etc/quartz-release"
echo "build id: $BUILD_ID"

# 5e. 可复现构建（可选）：固定 SOURCE_DATE_EPOCH——基座 rules.mk/image.mk/rootfs.mk 据此
#     固定包与镜像内时间戳（分区 GUID 也由它派生）。本地与 CI 用同一 epoch 时，
#     同机重复构建可逐字节一致、跨机差异收敛（跨机逐字节一致不承诺：宿主工具链不同）。
if [ -n "${QUARTZ_SOURCE_DATE_EPOCH:-}" ]; then
  export SOURCE_DATE_EPOCH="$QUARTZ_SOURCE_DATE_EPOCH"
  echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH（可复现构建模式）"
fi

# 7. ccache（与 CI 同样把构建目录 .ccache 链到持久目录；变体循环前一次即可）
step "准备 ccache（$CCACHE_DIR）"
mkdir -p "$CCACHE_DIR"
[ -e "$BASE_DIR/.ccache" ] || ln -s "$CCACHE_DIR" "$BASE_DIR/.ccache"
export CCACHE_DIR

# ─────────────────────────────────────────────────────────────────────────────
# 6~11. 变体循环（std / docker；公共步骤 1~5e、7 已在循环外完成一次）
#   每轮：种子装配（含变体层）→ defconfig → Gate A → [docker 文件叠加] → make
#        → manifest 校验（含变体断言）→ 镜像自检 → 签名校验 → 产物收集（改名）
#   docker 产物先收集到 <产物目录>-docker，随后 std 构建覆盖树内同名镜像——
#   循环末尾构建树回到标准版状态（publish/OTA 取件口径，见头部说明）。
# ─────────────────────────────────────────────────────────────────────────────

variant_artifacts_dir() {  # $1=变体：std → <基>；docker → <基>-docker
  if [ "$1" = "docker" ]; then printf '%s-docker' "$ARTIFACTS_BASE"; else printf '%s' "$ARTIFACTS_BASE"; fi
}

# 变体文件名改写：把 -docker 插在 fs 类型/后缀标记**之前**，保持既有 glob 口径不变
# （`*-squashfs-sysupgrade.img.gz`、`*.manifest`、`*.buildinfo` 仍能命中 docker 版）。
variant_name() {  # $1=文件名 $2=变体
  if [ "$2" = "std" ]; then printf '%s' "$1"; return; fi
  printf '%s' "$1" | sed -E 's/-(squashfs-)/-docker-\1/; s/\.(manifest|buildinfo)$/-docker.\1/'
}

# docker 变体文件叠加（config/preinstall/docker.files → 构建树 TOPDIR/files，
# 与 quartz-build-id/quartz-release 同机制，镜像期原样覆盖进 rootfs）。
# 变体之间必须**显式清理**：同一棵树先建 docker 再建 std 时，残留文件会被打进 std 镜像。
DOCKER_FILES_SRC="$BUILDER_DIR/config/preinstall/docker.files"
docker_files_apply() {  # $1=on|off
  local rel
  while IFS= read -r -d '' f; do
    rel="${f#"$DOCKER_FILES_SRC"/}"
    if [ "$1" = "on" ]; then
      mkdir -p "$BASE_DIR/files/$(dirname "$rel")"
      cp -p "$f" "$BASE_DIR/files/$rel"
    else
      rm -f "$BASE_DIR/files/$rel"
    fi
  done < <(find "$DOCKER_FILES_SRC" -type f -print0)
  [ "$1" = "off" ] && rmdir "$BASE_DIR/files/etc/docker" 2>/dev/null || true
}

build_variant() {
  local variant="$1" vlabel
  local compose_variant=()
  [ "$variant" = "docker" ] && compose_variant=(--docker)
  case "$variant" in
    std) vlabel="std（标准版）" ;;
    docker) vlabel="docker（预装 docker 栈）" ;;
  esac
  local art_dir; art_dir="$(variant_artifacts_dir "$variant")"

  COMPOSE_ARGS=()
  [ -n "$DEVICE" ] && COMPOSE_ARGS=(--device "$DEVICE")

  # 6. 配置：分层种子装配（脚本见 compose-seed.sh）+ defconfig 补齐默认项 + Gate A
  #    Gate A：装配行必须原样保留在 defconfig 之后的 .config——把"符号不存在/依赖未满足
  #    被 Kconfig 静默丢弃"（构建零报错但镜像少东西）变成硬失败。
  step "变体 $vlabel：装配种子层并 defconfig（compose-seed.sh${DEVICE:+；设备 $DEVICE}${compose_variant:+ + docker 层}）"
  bash "$BUILDER_DIR/scripts/compose-seed.sh" ${COMPOSE_ARGS[@]+"${COMPOSE_ARGS[@]}"} ${compose_variant[@]+"${compose_variant[@]}"} emit > "$BASE_DIR/.config"
  (cd "$BASE_DIR" && make defconfig)
  bash "$BUILDER_DIR/scripts/compose-seed.sh" ${COMPOSE_ARGS[@]+"${COMPOSE_ARGS[@]}"} ${compose_variant[@]+"${compose_variant[@]}"} verify "$BASE_DIR/.config"

  # 6b. 目标切换护栏：上次目标与本次不同 → dirclean
  # 注意执行顺序：dirclean 按 **当前 .config 的目标域** 清理（rm -rf build_dir/target-<arch>、
  # bin/targets/<board>/<subtarget>、共享 host 工具与 tmp/），因此必须先落好新 .config 再清理，
  # 清理的才是新目标域的陈旧产物（多目标 build_dir 共存是基座设计，不整树删除）。
  # 变体切换不改目标，因此只在首个变体可能触发。
  local prev_target
  prev_target="$(cat "$TARGET_STAMP" 2>/dev/null || true)"
  if [ -z "$prev_target" ] && [ -d "$BASE_DIR/staging_dir" ]; then
    prev_target="unknown"   # 老树首次带戳运行：保守清理
  fi
  if [ "$prev_target" != "$TARGET_ID" ]; then
    if [ -n "$prev_target" ]; then
      step "目标切换（$prev_target → $TARGET_ID）：make dirclean"
      (cd "$BASE_DIR" && make dirclean)
    fi
    echo "$TARGET_ID" > "$TARGET_STAMP"
  fi

  # 6c. docker 变体文件叠加/清理（make 之前落位；std 轮清掉，防复用树串味）
  if [ "$variant" = "docker" ]; then docker_files_apply on; else docker_files_apply off; fi

  # 6d. 陈旧 ext4 镜像清理：本版（2026-10-16 起）已关闭 EXT4FS，但复用构建树里可能
  #     残留上一轮（改动前）产出的 ext4 镜像——不清理会让下面的"只出 squashfs"自检
  #     误报（自检本身要留住：它是 EXT4FS 关行失效的兜底）。
  find "$TARGET_BIN_DIR" -maxdepth 1 -name '*-ext4-*' -delete 2>/dev/null || true

  # 8. 全量构建（本地用 V=w 减小日志；CI 首次跑通后也将降级）
  step "变体 $vlabel：全量构建 make -j$JOBS（首次约 45–90 分钟，换架构工具链重建更长）"
  (cd "$BASE_DIR" && make -j"$JOBS" V=w)

  # 10. manifest 校验（公共断言 + 设备断言 + 变体断言，与 CI 共用 check-manifest.sh）
  # 目标域限定：多目标构建产物在 bin/targets/<board>/<subtarget>/ 共存，
  # 一律按本次目标取 manifest/镜像，避免误取其他目标的存量产物。
  step "变体 $vlabel：校验固件 manifest"
  local manifest
  manifest="$(find "$TARGET_BIN_DIR" -name '*.manifest' | head -1)"
  [ -n "$manifest" ] || { echo "FAIL: 未在 $TARGET_BIN_DIR 找到 manifest" >&2; exit 1; }
  bash "$BUILDER_DIR/scripts/check-manifest.sh" "$manifest" "${DEVICE:-}" "$BASE_DIR" ${compose_variant[@]+"${compose_variant[@]}"}

  # 10b. 镜像格式自检（只出 squashfs，2026-10-16 用户指令）+ 设备镜像存在性
  if compgen -G "$TARGET_BIN_DIR/*ext4*" >/dev/null; then
    echo "FAIL: 目标域出现 ext4 镜像（应只出 squashfs）：$(ls "$TARGET_BIN_DIR"/*ext4* 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
  fi
  if [ -n "$DEVICE" ]; then
    local img
    img="$(find "$TARGET_BIN_DIR" -name "$DEVICE_IMAGE_GLOB" | head -1)"
    if [ -n "$img" ]; then
      echo "OK(设备镜像): ${img#"$BASE_DIR/"}"
    else
      echo "FAIL(设备镜像): 未找到 $DEVICE_IMAGE_GLOB（bin/targets/${DEVICE_TARGET}/${DEVICE_SUBTARGET}/）" >&2
      exit 1
    fi
  else
    local n_img
    n_img="$(find "$TARGET_BIN_DIR" -maxdepth 1 -name '*.img.gz' | wc -l)"
    [ "$n_img" -gt 0 ] && echo "OK(镜像): $n_img 个（squashfs 系列）" || { echo "FAIL: 未找到成品镜像" >&2; exit 1; }
  fi

  # 10c. 签名一致性校验（WP-9，docs/SIGNING-OTA.md）：feed 索引签名 key id /
  #      镜像内公钥载荷 / quartz-defaults 的 feed 列表与 OTA 件——发布构建的护栏。
  step "变体 $vlabel：签名一致性校验（WP-9）"
  local arch_pkgs
  arch_pkgs="$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\?\([^"]*\)"\?$/\1/p' "$BASE_DIR/.config" | head -1)"
  bash "$BUILDER_DIR/scripts/verify-signing.sh" "$BASE_DIR" --arch "${arch_pkgs:-x86_64}"

  # 11. 产物收集（与 CI Collect artifacts 一致；同样限定本次目标域；docker 变体改名）
  step "变体 $vlabel：收集产物 → $art_dir"
  mkdir -p "$art_dir"
  rm -f "$art_dir"/*ext4*   # 产物目录里的陈旧 ext4（历史构建遗留；本版只出 squashfs）
  find "$TARGET_BIN_DIR" -type f \( -name '*.img.gz' -o -name '*sysupgrade*.bin' -o -name '*.manifest' -o -name '*.buildinfo' \) \
    -print0 | while IFS= read -r -d '' f; do
      cp "$f" "$art_dir/$(variant_name "$(basename "$f")" "$variant")"
    done
  cp "$BASE_DIR/.config" "$art_dir/dotconfig"
  ls -la "$art_dir"
}

step "开始构建 ${#BUILD_ORDER[@]} 个变体：${BUILD_ORDER[*]}"
for v in "${BUILD_ORDER[@]}"; do
  build_variant "$v"
done

step "完成 ✔"
for v in "${BUILD_ORDER[@]}"; do
  echo "  变体 ${v} 产物目录: $(variant_artifacts_dir "$v")"
done
