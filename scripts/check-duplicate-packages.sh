#!/usr/bin/env bash
# 同名包 / 基座遮蔽扫描（docs/TDD.md §4.5；WORKPLAN 坑位 #11/#46）
#
# 三类冲突都会让「已收录的包静默失效」，发现即失败：
#   A. quartz ↔ thirdparty 同名（PKG_NAME）——同名包依赖解析歧义（历史 bug 源）
#   B. 我方包目录名 == 基座 feed 包目录名——include/scan.awk 按 Makefile 路径的
#      最后一段（目录名）去重，重复时整包被静默丢弃（坑位 #46：仅改 PKG_NAME
#      不改目录名即中招，feeds install 无报错、defconfig 无该符号）
#   C. 我方 PKG_NAME == 基座 feed 包——feeds 安装「先列者胜」（基座 feed 在
#      feeds.conf 中先列），基座版本胜出、我方 Makefile 成死代码（坑位 #11）
#
# 扫描范围与深度对齐构建系统：include/scan.mk 的 SCAN_DEPTH=5 + 仅统计含
# `call (Build/DefaultTargets|BuildPackage|KernelPackage)` 的 Makefile。
# 基座侧 = feeds/ 下除 quartz/thirdparty 外的全部 feed；feeds/base 是基座树
# package/ 的符号链接，其下 feeds/ 子树是 feed 安装产物（符号链接），跳过。
#
# 用法: check-duplicate-packages.sh [feeds 目录]   （默认 feeds，在基座树根目录运行）

set -euo pipefail
export LC_ALL=C   # sort/join 须按字节序一致（join 要求 strcmp 有序，非当前 locale）

FEEDS_DIR="${1:-feeds}"
OUR_FEEDS=("$FEEDS_DIR/quartz" "$FEEDS_DIR/thirdparty")

for d in "${OUR_FEEDS[@]}"; do
  [ -d "$d" ] || { echo "错误：未找到 $d（先运行 ./scripts/feeds update -a）"; exit 2; }
done

SCAN_GREP='call (Build/DefaultTargets|BuildPackage|KernelPackage)'

# 与 scan.mk 同语义的包 Makefile 列表（深度 5 + GREP_STRING 过滤）
makefiles_of() {
  local root="$1" f rel
  while IFS= read -r f; do
    rel="${f#"$root"/}"
    case "$rel" in
      feeds/*) continue ;;  # 基座树 package/feeds/* = feed 安装产物，跳过
    esac
    if grep -aqE "$SCAN_GREP" "$f"; then printf '%s\n' "$f"; fi
  done < <(find -L "$root" -mindepth 1 -maxdepth 5 -name Makefile 2>/dev/null | sort)
  return 0
}

dir_names_of() {  # stdin: Makefile 列表 → 目录名 <TAB> 目录路径（同名取首个）
  local f
  while IFS= read -r f; do
    printf '%s\t%s\n' "$(basename "$(dirname "$f")")" "$(dirname "$f")"
  done | awk -F'\t' '!seen[$1]++'
}

pkg_names_of() {  # stdin: Makefile 列表 → PKG_NAME <TAB> Makefile（同名取首个；未展开的 $(…) 值跳过）
  local f v
  while IFS= read -r f; do
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      case "$v" in *'$'*) continue ;; esac
      printf '%s\t%s\n' "$v" "$f"
    done < <(sed -n 's/^[[:space:]]*PKG_NAME[[:space:]]*[:?]\?=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$f")
  done | awk -F'\t' '!seen[$1]++'
}

# ---- 基座 feed 清单（realpath 去重；feeds/base → ../package 与兜底路径合并） ----
BASE_ROOTS=()
declare -A SEEN_REAL=()
add_base_root() {
  local d="$1" real
  [ -d "$d" ] || return 0
  real=$(realpath "$d")
  [ -n "${SEEN_REAL[$real]:-}" ] && return 0   # 已收录（含 feeds/base == package/ 的情况）
  SEEN_REAL["$real"]=1
  BASE_ROOTS+=("$d")
}

SEEN_REAL["$(realpath "$FEEDS_DIR/quartz")"]=1
SEEN_REAL["$(realpath "$FEEDS_DIR/thirdparty")"]=1

while IFS= read -r d; do
  add_base_root "$d"
done < <(find -L "$FEEDS_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '*.tmp' | sort)
add_base_root "$(dirname "$FEEDS_DIR")/package"   # feeds/base 缺失时兜底（基座树本体）

[ "${#BASE_ROOTS[@]}" -gt 0 ] || { echo "错误：未在 $FEEDS_DIR 找到任何基座 feed"; exit 2; }

# ---- 生成两套索引 ----
TMPLIST=()
new_tmp() { local t; t=$(mktemp); TMPLIST+=("$t"); printf '%s\n' "$t"; }
trap 'rm -f "${TMPLIST[@]}"' EXIT

ours_dirs=$(new_tmp); base_dirs=$(new_tmp)
ours_pkgs=$(new_tmp); base_pkgs=$(new_tmp)

index_root() {  # <root> <dirs 输出> <pkgs 输出>（包列表只扫描一次）
  local mf
  mf=$(new_tmp)
  makefiles_of "$1" > "$mf"
  dir_names_of < "$mf" >> "$2"
  pkg_names_of < "$mf" >> "$3"
}

for d in "${OUR_FEEDS[@]}"; do
  index_root "$d" "$ours_dirs" "$ours_pkgs"
done
for d in "${BASE_ROOTS[@]}"; do
  index_root "$d" "$base_dirs" "$base_pkgs"
done

fail=0

report_conflicts() {  # <标题> <我方索引> <对方索引> <提示>
  local title="$1" lhs="$2" rhs="$3" hint="$4"
  local name ours theirs
  local hits
  hits=$(join -t $'\t' -j 1 <(sort -u "$lhs") <(sort -u "$rhs") || true)
  [ -n "$hits" ] || return 0
  echo "❌ $title"
  while IFS=$'\t' read -r name ours theirs; do
    printf '   冲突键: %s\n' "$name"
    printf '     我方: %s\n' "$ours"
    printf '     对方: %s\n' "$theirs"
  done <<< "$hits"
  echo "   → $hint"
  fail=1
}

# A. quartz ↔ thirdparty 同名（PKG_NAME）
q_pkgs=$(new_tmp); t_pkgs=$(new_tmp)
makefiles_of "$FEEDS_DIR/quartz"     | pkg_names_of > "$q_pkgs"
makefiles_of "$FEEDS_DIR/thirdparty" | pkg_names_of > "$t_pkgs"
report_conflicts "双 Feed 同名包冲突（quartz ↔ thirdparty）" "$q_pkgs" "$t_pkgs" \
  "请在 thirdparty feed 中重命名冲突包（docs/TDD.md §4.5）"

# B. 我方包目录名 == 基座 feed 包目录名（scan.awk 按目录名去重 → 静默丢弃）
report_conflicts "包目录名与基座 feed 重复（整包会被静默丢弃）" "$ours_dirs" "$base_dirs" \
  "基座已提供的包不收录；确需收录则目录名一并改名（PKG_NAME 与引用点同步，WORKPLAN 坑位 #46）"

# C. 我方 PKG_NAME == 基座 feed 包（先列者胜 → 我方成死代码）
report_conflicts "PKG_NAME 与基座 feed 重复（基座版本胜出，我方成死代码）" "$ours_pkgs" "$base_pkgs" \
  "基座已提供的包一律不收录、直接 DEPENDS（docs/TDD.md §3.1、WORKPLAN 坑位 #11）"

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "✅ 同名包 / 基座遮蔽检查通过（A quartz↔thirdparty / B 目录名 / C PKG_NAME×基座）"
