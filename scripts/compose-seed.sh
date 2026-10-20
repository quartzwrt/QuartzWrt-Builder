#!/usr/bin/env bash
# QuartzWrt 种子装配与 Gate A（WP-12 预装分层）
#
# 用法:
#   scripts/compose-seed.sh [--device <设备名>] [--docker] emit     > <基座树>/.config
#   scripts/compose-seed.sh [--device <设备名>] [--docker] verify  <装配后的 .config>
#
# 装配顺序（同符号后者覆盖前者；覆盖明细打到 stderr）：
#   config/common.config                       跨目标构建面/分发面
#   config/seed.config  （或设备种子，见下）    目标层
#   config/preinstall/drivers.config           通用驱动层
#   config/preinstall/features.config          通用功能层
#   config/preinstall/docker.config            docker 变体层（仅 --docker；2026-10-16）
#   devices/<设备>/seed.config                 目标/设备层（仅 --device）
#   devices/<设备>/preinstall.config           设备专用预装层（仅 --device）
#
# 语义性注释行（2026-10-16 增）：片段里形如 `# CONFIG_X is not set` 的行**不是普通
#   注释**，而是 Kconfig 的"显式关掉"写法——本脚本把它当语义行参与装配、覆盖与
#   Gate A 校验（否则"关掉某个默认开的符号"在分层片段里无从表达；曾因此静默丢失
#   用户的关闭意图）。仅当整行严格匹配 `# CONFIG_<符号> is not set` 时才算语义行，
#   其余 `#` 行仍是注释。
#
# Gate A（verify）：装配结果的每一行必须原样保留在 `make defconfig` 之后的 .config。
# 抓的是"符号不存在 / 依赖未满足 → 被 Kconfig 静默丢弃"这一类失败（项目实例：
# kmod-rfkill 在 RFKILL 内建的 rockchip 上被静默丢弃，见 WORKPLAN 坑位与 device.env 注记）。
# 静默丢弃是构建零报错但镜像少东西的最隐蔽路径，因此把它变成硬失败。
#
# 说明：本脚本只做"装配 + 行级校验"，不做语义校验；语义（装了没有）由
# scripts/check-manifest.sh 的 Gate B 在构建后用 manifest 断言兜底。
#
# 退出码：emit 恒 0（覆盖明细不算错）；verify 有缺行时非 0。

set -euo pipefail

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEVICE=""
DOCKER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="${2:?--device 需要参数：设备名（devices/<设备名>/）}"; shift 2 ;;
    --device=*) DEVICE="${1#--device=}"; shift ;;
    --docker) DOCKER=1; shift ;;
    emit|verify) MODE="$1"; shift ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) break ;;
  esac
done
MODE="${MODE:-}"
FINAL_CONFIG="${1:-}"

[ -n "$MODE" ] || { echo "错误：缺少模式（emit | verify），用法见 --help" >&2; exit 1; }

# 源文件清单（顺序即装配顺序）
FILES=("$BUILDER_DIR/config/common.config")
if [ -n "$DEVICE" ]; then
  DEVICE_DIR="$BUILDER_DIR/devices/$DEVICE"
  [ -d "$DEVICE_DIR" ] || { echo "错误：设备不存在：$DEVICE_DIR" >&2; exit 1; }
  FILES+=("$DEVICE_DIR/seed.config")
else
  FILES+=("$BUILDER_DIR/config/seed.config")
fi
FILES+=("$BUILDER_DIR/config/preinstall/drivers.config" "$BUILDER_DIR/config/preinstall/features.config")
if [ -n "$DOCKER" ]; then
  FILES+=("$BUILDER_DIR/config/preinstall/docker.config")
fi
if [ -n "$DEVICE" ]; then
  FILES+=("$DEVICE_DIR/preinstall.config")
fi

for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "错误：源文件不存在：$f" >&2; exit 1; }
done

# 装配：跳过注释/空行（**例外**：`# CONFIG_X is not set` 是语义行，见头部说明）；
#       同符号保留**最后出现**的值（并把覆盖关系记到 stderr）
declare -A seen      # KEY -> 首次出现它的文件（用于覆盖报告）
composed=""
overrides=""
for f in "${FILES[@]}"; do
  rel="${f#"$BUILDER_DIR"/}"
  while IFS= read -r line || [ -n "$line" ]; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    [ -z "$stripped" ] && continue
    key=""
    case "$stripped" in
      '# CONFIG_'*' is not set')
        # 语义性注释行：严格整行匹配 `# CONFIG_<符号> is not set` 才算
        # （带尾注的同形行、以及其它 # 行仍是注释，直接跳过）。
        key="$(printf '%s' "$stripped" | sed -n 's/^# \(CONFIG_[A-Za-z0-9_.-]*\) is not set$/\1/p')"
        [ -n "$key" ] || continue
        ;;
      '#'*) continue ;;
    esac
    if [ -z "$key" ]; then
      # 规范化：剥掉行内注释（` # ...`）与行尾空白——片段允许 `KEY=VAL  # 说明` 写法，
      # 但 emit 进入 .config 的必须是 Kconfig 规范形式（defconfig 也会剥，这里提前统一，
      # 保证 emit 产物与 Gate A 比对口径一致）。
      stripped="$(printf '%s' "$stripped" | sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//')"
      [ -z "$stripped" ] && continue
      key="${stripped%%=*}"
    fi
    prev="${seen[$key]:-}"
    if [ -n "$prev" ]; then
      overrides+="  $key: $prev → $rel（后者胜）"$'\n'
      # 删除早先声明的同符号行——两种形态都删（`KEY=...` 与 `# KEY is not set`），
      # 避免同符号两行并存的歧义。注意：命令替换会吞掉结尾换行——必须显式补回，
      # 否则下一次追加会与前一行粘连（Gate A 实测踩中：`...=y` + `CONFIG_...=y`
      # 拼成一行 → 两个符号都被 Kconfig 丢弃）。
      removed="$(printf '%s\n' "$composed" | awk -v k="$key" 'index($0, k "=") != 1 && $0 != "# " k " is not set"')"
      if [ -n "$removed" ]; then composed="$removed"$'\n'; else composed=""; fi
    fi
    seen[$key]="$rel"
    composed+="$stripped"$'\n'
  done < "$f"
done

if [ -n "$overrides" ]; then
  echo "── 装配覆盖明细（后者胜，正常语义）──" >&2
  printf '%s' "$overrides" >&2
fi

if [ "$MODE" = "emit" ]; then
  printf '%s' "$composed"
  exit 0
fi

# ── Gate A：装配行必须保留在最终 .config ──────────────────────────────────────
[ -n "$FINAL_CONFIG" ] || { echo "错误：verify 需要给定装配后的 .config 路径" >&2; exit 1; }
[ -f "$FINAL_CONFIG" ] || { echo "错误：.config 不存在：$FINAL_CONFIG" >&2; exit 1; }

missing=0; checked=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  checked=$((checked + 1))
  if ! grep -qxF "$line" "$FINAL_CONFIG"; then
    echo "FAIL(Gate A): 装配行未出现在最终 .config（被 Kconfig 静默丢弃？）：$line" >&2
    missing=$((missing + 1))
  fi
done <<< "$composed"

if [ "$missing" -gt 0 ]; then
  echo "Gate A 失败：$missing/$checked 行被丢弃（检查符号名/依赖是否满足；设备层内核符号是否置齐）" >&2
  exit 1
fi
echo "Gate A 通过：装配 $checked 行全部保留在最终 .config"
exit 0
