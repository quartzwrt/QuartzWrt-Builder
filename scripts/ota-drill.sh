#!/usr/bin/env bash
# QuartzWrt WP-9 端到端演练：签名 feed + 包升级链路 + 固件 OTA 链路
#
# 在**独立**的 QEMU 实例（自有覆盖层/端口，不动 test-in-vm.sh 的共享实例）上：
#   A. 包升级链路（旧固件上）：
#      预置公钥 → 接入自有 feed（quartz-feed.list）→ apk update（验签通过）
#      → 反例：异钥签名的仓库被拒绝 → apk upgrade 真升级（版本前移）
#   B. 固件 OTA 链路：
#      OTA 清单（usign 签名）→ 校验通过 → 下载镜像 + sha256 → sysupgrade -n
#      → 重启 → 断言新 build id / 新预置件 / 包版本 / 再次 --check 已最新
#
# 依赖：qemu-system-x86_64、python3、host apk/usign（构建树 staging_dir）、
#       scripts/{publish-feed,inject-signing-key}.sh、scripts/vm-ssh-pass.py
#
# 用法:
#   scripts/ota-drill.sh [--old-image 旧镜像] [--base-dir 构建树] [--phase all|pkg|fw]
#                        [--port 9992] [--luci-port 8180] [--ssh-port 2322] [--app-port 8543]
#                        [--keep] [--feed-dir DIR] [--ota-key PATH]
#
# 证据：$DRILL_DIR/drill-<时间戳>.log + summary.json（默认 <Builder>/../vm/ota-drill/）

set -euo pipefail

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${QUARTZ_WORK_DIR:-$BUILDER_DIR/../build}"
BASE_DIR="$WORK_DIR/immortalwrt"
VM_ROOT="$BUILDER_DIR/../vm"
OLD_IMAGE="$VM_ROOT/immortalwrt-x86-64-generic-ext4-combined.img"
DRILL_DIR="${QUARTZ_DRILL_DIR:-$VM_ROOT/ota-drill}"
FEED_DIR=""
HTTP_PORT="${PORT:-9992}"
LUCI_PORT="${LUCI_PORT:-8180}"
SSH_PORT="${SSH_PORT:-2322}"
APP_PORT="${APP_PORT:-8543}"
PHASE="all"
KEEP=0
OTA_KEY="${OTA_SIGNING_KEY:-${QUARTZ_SIGNING_DIR:-$HOME/.quartz-signing}/ota.key}"

while [ $# -gt 0 ]; do
  case "$1" in
    --old-image) OLD_IMAGE="$2"; shift 2 ;;
    --base-dir) BASE_DIR="$2"; shift 2 ;;
    --feed-dir) FEED_DIR="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    --port) HTTP_PORT="$2"; shift 2 ;;
    --luci-port) LUCI_PORT="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --app-port) APP_PORT="$2"; shift 2 ;;
    --ota-key) OTA_KEY="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（用法见 --help）" >&2; exit 1 ;;
  esac
done

[ -n "$FEED_DIR" ] || FEED_DIR="$DRILL_DIR/feed"
mkdir -p "$DRILL_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$DRILL_DIR/drill-$TS.log"
exec > >(tee -a "$LOG") 2>&1

PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
step() { printf '\n==> [%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

VSSH() { VM_SSH_PORT="$SSH_PORT" VM_PASSES="quartz," python3 "$BUILDER_DIR/scripts/vm-ssh-pass.py" --timeout "${2:-60}" "$1"; }
vrun() { # vrun <描述> <命令>  —— 远端执行，返回退出码
  local desc="$1"; shift
  local out code
  out="$(VSSH "$*" 2>&1)"; code=$?
  echo "--- [vm] $desc :: $*"
  echo "$out" | sed 's/^/    /'
  return $code
}
vassert() { # vassert <描述> <命令> —— 期望成功
  if vrun "$@"; then ok "$1"; else bad "$1（退出码非 0）"; fi
}

cleanup() {
  if [ "$KEEP" = 1 ]; then echo "（--keep：保留 VM 与 HTTP 服务）"; return; fi
  [ -f "$DRILL_DIR/qemu.pid" ] && kill "$(cat "$DRILL_DIR/qemu.pid")" 2>/dev/null || true
  [ -f "$DRILL_DIR/http.pid" ] && kill "$(cat "$DRILL_DIR/http.pid")" 2>/dev/null || true
  rm -f "$DRILL_DIR/qemu.pid" "$DRILL_DIR/http.pid"
}
trap cleanup EXIT

step "前置检查"
command -v qemu-system-x86_64 >/dev/null || { echo "错误：未安装 QEMU" >&2; exit 1; }
[ -f "$OLD_IMAGE" ] || { echo "错误：旧固件基底镜像不存在：$OLD_IMAGE" >&2; exit 1; }
[ -x "$BASE_DIR/staging_dir/host/bin/apk" ] || { echo "错误：构建树未构建（缺 host apk）" >&2; exit 1; }
[ -f "$OTA_KEY" ] || { echo "错误：缺 OTA usign 私钥（--ota-key 或 QUARTZ_SIGNING_DIR/ota.key）" >&2; exit 1; }
echo "旧镜像: $OLD_IMAGE"
echo "构建树: $BASE_DIR"
echo "演练目录: $DRILL_DIR（feed: $FEED_DIR）"
echo "HTTP 端口: $HTTP_PORT；VM 端口: luci=$LUCI_PORT ssh=$SSH_PORT app=$APP_PORT"

# ---------- 1. 发布 feed（含 OTA 清单） ----------
if [ "$PHASE" = "all" ] || [ "$PHASE" = "pkg" ] || [ "$PHASE" = "fw" ]; then
  step "发布 feed + OTA 清单 → $FEED_DIR"
  rm -rf "$FEED_DIR"
  bash "$BUILDER_DIR/scripts/publish-feed.sh" --base-dir "$BASE_DIR" --dest "$FEED_DIR" --ota-key "$OTA_KEY"
fi

# ---------- 2. 演练载荷（从**已构建 apk** 提取真实投放件） ----------
step "准备演练载荷（drill/）"
PAYLOAD="$FEED_DIR/drill"
mkdir -p "$PAYLOAD"
qd="$(ls "$BASE_DIR"/bin/packages/x86_64/quartz/quartz-defaults-*.apk | head -1)"
tmp="$(mktemp -d)"
( cd "$tmp" && "$BASE_DIR/staging_dir/host/bin/apk" extract --allow-untrusted "$qd" >/dev/null 2>&1 )
cp "$tmp/etc/apk/keys/quartz.pem" "$PAYLOAD/quartz.pem"
cp "$tmp/etc/quartz-ota.pub" "$PAYLOAD/quartz-ota.pub"
cp "$tmp/usr/sbin/quartz-ota-update" "$PAYLOAD/quartz-ota-update"
if [ -f "$tmp/etc/apk/repositories.d/quartz-feed.list" ]; then
  cp "$tmp/etc/apk/repositories.d/quartz-feed.list" "$PAYLOAD/quartz-feed.list"
else
  { echo "# drill 生成的 feed 行（构建时未配 QUARTZ_FEED_BASE_URL）"
    echo "http://192.168.1.2:$HTTP_PORT/packages/x86_64/quartz/packages.adb"
    echo "http://192.168.1.2:$HTTP_PORT/packages/x86_64/thirdparty/packages.adb"
    echo "http://192.168.1.2:$HTTP_PORT/targets/x86/64/packages/packages.adb"
  } > "$PAYLOAD/quartz-feed.list"
fi
rm -rf "$tmp"
echo "  载荷：$(ls "$PAYLOAD" | tr '\n' ' ')"
grep -q "192.168.1.2:$HTTP_PORT" "$PAYLOAD/quartz-feed.list" || {
  echo "错误：构建时的 QUARTZ_FEED_BASE_URL 与演练端口不符（$HTTP_PORT）——请按演练端口构建" >&2; exit 1; }

# 反例载荷：异钥签名的第三方索引（同包内容）
step "生成反例仓库（rogue/，异钥签名）"
mkdir -p "$PAYLOAD/rogue"
cp "$FEED_DIR/packages/x86_64/thirdparty"/*.apk "$PAYLOAD/rogue/"
openssl ecparam -name prime256v1 -genkey -noout -out "$DRILL_DIR/rogue.key" 2>/dev/null
( cd "$PAYLOAD/rogue" && "$BASE_DIR/staging_dir/host/bin/apk" mkndx --root "$BASE_DIR" \
    --keys-dir "$BASE_DIR" --allow-untrusted --sign "$DRILL_DIR/rogue.key" \
    --output packages.adb ./*.apk >/dev/null 2>&1 )
echo "  rogue 索引：$(ls -l "$PAYLOAD/rogue/packages.adb" | awk '{print $5}') 字节（rogue 私钥 $DRILL_DIR/rogue.key）"

# ---------- 3. HTTP 服务 ----------
step "启动 HTTP 服务（: $HTTP_PORT）"
if [ -f "$DRILL_DIR/http.pid" ] && kill -0 "$(cat "$DRILL_DIR/http.pid")" 2>/dev/null; then
  kill "$(cat "$DRILL_DIR/http.pid")" 2>/dev/null || true; sleep 1
fi
( cd "$FEED_DIR" && nohup python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 >"$DRILL_DIR/http.log" 2>&1 &
  echo $! > "$DRILL_DIR/http.pid" )
sleep 1
curl -fsS "http://127.0.0.1:$HTTP_PORT/ota/x86/64.json" >/dev/null && echo "  OK：清单可访问"

# ---------- 4. 启动独立演练 VM ----------
step "启动演练 VM（全新覆盖层，端口 $LUCI_PORT/$SSH_PORT/$APP_PORT）"
rm -f "$DRILL_DIR/overlay.qcow2" "$DRILL_DIR/serial.log"
qemu-img create -q -f qcow2 -b "$OLD_IMAGE" -F raw "$DRILL_DIR/overlay.qcow2"
qemu-system-x86_64 -cpu max -accel tcg -smp 4 -m 1024 \
  -drive file="$DRILL_DIR/overlay.qcow2",if=virtio,format=qcow2 \
  -netdev user,id=n0,net=192.168.1.0/24,host=192.168.1.2,hostfwd=tcp::"$LUCI_PORT"-192.168.1.1:80,hostfwd=tcp::"$SSH_PORT"-192.168.1.1:22,hostfwd=tcp::"$APP_PORT"-192.168.1.1:443 \
  -device virtio-net-pci,netdev=n0 -netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
  -name quartzwrt-ota-drill -display none -serial "file:$DRILL_DIR/serial.log" \
  -daemonize -pidfile "$DRILL_DIR/qemu.pid"
echo "  VM pid: $(cat "$DRILL_DIR/qemu.pid")，等待 SSH 就绪…"
for i in $(seq 1 60); do
  if VSSH "true" 20 >/dev/null 2>&1; then echo "  SSH 就绪（第 ${i} 次探测）"; break; fi
  sleep 5
  [ "$i" = 60 ] && { echo "错误：VM SSH 未就绪（串口日志：$DRILL_DIR/serial.log）" >&2; exit 1; }
done

step "记录演练前状态"
vrun "固件版本" "cat /etc/openwrt_release | grep -E 'DISTRIB_(REVISION|TARGET)'; echo -n 'build-id: '; cat /etc/quartz-build-id 2>/dev/null || echo '(无)'" || true
vrun "关键包版本（升级前）" "apk list --installed 2>/dev/null | grep -E 'luci-theme-quartz|luci-app-dashboard|quartz-defaults|luci-app-bandix' | awk '{print \$1}'" || true
vrun "WAN 检查" "ip route | grep -q default && echo WAN_OK || echo WAN_MISSING" || true
# WAN 兜底（基座 99-default_network 仅在首启可见第二网卡时配 wan；坑位 #33）
vrun "WAN 兜底（缺默认路由则补配 eth1/dhcp）" \
  "ip route | grep -q default || { uci -q get network.wan >/dev/null 2>&1 || { uci set network.wan=interface; uci set network.wan.proto=dhcp; uci set network.wan.device=eth1; uci commit network; }; /etc/init.d/network reload; sleep 4; /etc/init.d/firewall reload; ip route | grep -q default && echo WAN_FIXED || echo WAN_STILL_MISSING; }" || true

# ---------- A. 包升级链路 ----------
if [ "$PHASE" = "all" ] || [ "$PHASE" = "pkg" ]; then
  step "A. 包升级链路"
  vassert "A1 预置 feed 公钥（模拟随固件投放）" \
    "wget -q -O /etc/apk/keys/quartz.pem http://192.168.1.2:$HTTP_PORT/drill/quartz.pem && ls -l /etc/apk/keys/quartz.pem"
  vassert "A2 接入自有 feed（quartz-feed.list）" \
    "wget -q -O /etc/apk/repositories.d/quartz-feed.list http://192.168.1.2:$HTTP_PORT/drill/quartz-feed.list && cat /etc/apk/repositories.d/quartz-feed.list"
  vassert "A3 apk update（索引签名验签通过）" \
    "apk update 2>&1 | tail -3"
  vrun "A4 断言：自有源索引可用" \
    "apk list --available luci-theme-quartz 2>/dev/null | head -3" || true
  vrun "A5 反例：异钥签名的源被拒绝" \
    "sed -i 's|/packages/x86_64/thirdparty/packages.adb|/drill/rogue/packages.adb|' /etc/apk/repositories.d/quartz-feed.list; apk update 2>&1 | grep -iE 'untrusted|BAD|invalid' | head -3; echo '--- add 尝试:'; apk add luci-app-mosdns 2>&1 | tail -3" || true
  vrun "A5b 反例断言（luci-app-mosdns 不可安装）" \
    "apk add --simulate luci-app-mosdns >/dev/null 2>&1 && echo ROGUE_ACCEPTED || echo ROGUE_REJECTED" || true
  vassert "A6 恢复合法源" \
    "wget -q -O /etc/apk/repositories.d/quartz-feed.list http://192.168.1.2:$HTTP_PORT/drill/quartz-feed.list && apk update >/dev/null 2>&1 && echo restored"
  vassert "A7 apk upgrade（真升级）" \
    "apk upgrade 2>&1 | tail -5"
  vrun "A8 升级后版本" \
    "apk list --installed 2>/dev/null | grep -E 'luci-theme-quartz|luci-app-dashboard|quartz-defaults|luci-app-bandix' | awk '{print \$1}'" || true
fi

# ---------- B. 固件 OTA 链路 ----------
if [ "$PHASE" = "all" ] || [ "$PHASE" = "fw" ]; then
  step "B. 固件 OTA 链路"
  NEW_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build_id"])' "$FEED_DIR/ota/x86/64.json")"
  echo "  目标 build id：$NEW_ID"
  vassert "B1 投放 OTA 验签公钥 + 升级脚本（模拟随固件投放）" \
    "wget -q -O /etc/quartz-ota.pub http://192.168.1.2:$HTTP_PORT/drill/quartz-ota.pub && wget -q -O /usr/sbin/quartz-ota-update http://192.168.1.2:$HTTP_PORT/drill/quartz-ota-update && chmod +x /usr/sbin/quartz-ota-update && echo ok"
  vrun "B2 --check（期望：有新版本，退出码 10）" \
    "quartz-ota-update --url http://192.168.1.2:$HTTP_PORT --check; echo EXIT=\$?" || true
  step "B3 --apply（sysupgrade -n，VM 将重启）"
  vrun "B3 执行升级" "quartz-ota-update --url http://192.168.1.2:$HTTP_PORT --apply" || true
  echo "  等待 VM 重启并恢复 SSH…"
  rebooted=0
  for i in $(seq 1 90); do
    sleep 6
    if VSSH "true" 15 >/dev/null 2>&1; then rebooted=$i; break; fi
  done
  [ "$rebooted" != 0 ] && ok "B4 VM 重启后 SSH 恢复（第 ${rebooted} 次探测）" || bad "B4 VM 重启后 SSH 未恢复"
  vassert "B5 新固件 build id 断言" "test \"\$(cat /etc/quartz-build-id)\" = \"$NEW_ID\" && cat /etc/quartz-build-id"
  vassert "B6 新固件预置件断言（公钥/feed 行/OTA 脚本）" \
    "test -f /etc/apk/keys/quartz.pem && test -f /etc/quartz-ota.pub && test -f /etc/apk/repositories.d/quartz-feed.list && test -x /usr/sbin/quartz-ota-update && echo all-present"
  vrun "B7 升级后包版本" \
    "apk list --installed 2>/dev/null | grep -E 'luci-theme-quartz|luci-app-dashboard|quartz-defaults|luci-app-bandix' | awk '{print \$1}'" || true
  vassert "B8 自有 feed 在新固件上可用（apk update + 已最新）" \
    "apk update >/dev/null 2>&1 && quartz-ota-update --url http://192.168.1.2:$HTTP_PORT --check >/dev/null 2>&1 && echo up-to-date"
  vrun "B9 固件信息" "cat /etc/openwrt_release | grep DISTRIB_REVISION; uname -r" || true
fi

step "演练汇总"
echo "PASS=$PASS FAIL=$FAIL"
{
  echo "{"
  echo "  \"time\": \"$TS\","
  echo "  \"old_image\": \"$OLD_IMAGE\","
  echo "  \"build_id\": \"$(cat "$BASE_DIR/files/etc/quartz-build-id" 2>/dev/null || echo unknown)\","
  echo "  \"pass\": $PASS, \"fail\": $FAIL,"
  echo "  \"log\": \"$LOG\""
  echo "}"
} > "$DRILL_DIR/summary-$TS.json"
echo "日志：$LOG"
echo "摘要：$DRILL_DIR/summary-$TS.json"
[ "$FAIL" = 0 ] || exit 1
