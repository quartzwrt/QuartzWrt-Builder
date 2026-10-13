#!/usr/bin/env bash
# QuartzWrt 本地镜像 VM 真启动测试（QEMU/KVM）—— test-in-docker.sh 的"真实情况"版
#
# 与 Docker 版的分工：
#   test-in-docker.sh  秒级：只测用户态（LuCI/主题/页面），适合快速迭代
#   test-in-vm.sh      真启动：引导链（BIOS→grub→内核）、内核与模块、procd 完整
#                      init、首次启动 uci-defaults、网络栈（br-lan/防火墙/DHCP）、
#                      磁盘持久化 —— 与真机开机路径一致
#
# 前置: sudo apt install qemu-system-x86 qemu-utils
#       （/dev/kvm 存在则 KVM 加速；否则自动退回 TCG 软件模拟，很慢）
#
# 用法:
#   scripts/test-in-vm.sh                交互模式：串口控制台直连（Ctrl-A X 退出）
#   scripts/test-in-vm.sh --detach       后台模式：就绪后打印访问地址（保持运行）
#   scripts/test-in-vm.sh --stop         停掉后台实例
#   scripts/test-in-vm.sh --keep         复用上次的磁盘覆盖层（默认每次全新首次启动；
#                                        镜像重建后拒绝复用——陈旧覆盖层会致启动崩溃，
#                                        QUARTZ_ALLOW_STALE_OVERLAY=1 可强制）
# 环境变量: PORT=8080（LuCI 宿主端口）、SSH_PORT=2222、APP_PORT=8443（App API
#           443 宿主端口，WP-5）、MEM=1024、SMP=4、VM_PASS=quartz（ensure_wan 首试密码）
#
# 网络：两张网卡——eth0=LAN 段（slirp 192.168.1.0/24，hostfwd 供宿主访问 LuCI/SSH/API）；
#       eth1=WAN 段（slirp 默认网 10.0.2.0/24，DHCP 10.0.2.15 / 网关 10.0.2.2 / DNS
#       10.0.2.3），供 VM 自身出网（OpenClash 等网络功能测试）。基座 x86 板级不会自动
#       生成 WAN，detach 模式就绪后由 ensure_wan 补配一次（幂等）。
#
# 进系统后：串口控制台直接是 root shell（全新镜像无密码）；先 passwd 设一个，
# 再用浏览器访问 http://localhost:$PORT 登录 LuCI。
#
# 自检提示：用 wget 抓 CGI 页（/cgi-bin/luci/）会得到 0 字节正文——wget 与 uhttpd
# 的 chunked 403 响应兼容问题（docker 期同样复现，浏览器不受影响）；验证页面
# 请用浏览器，或 python3 urllib（正确处理 chunked，实测 403 + 3177 字节正文）。
set -euo pipefail

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="${QUARTZ_WORK_DIR:-$BUILDER_DIR/../build}/immortalwrt"
VM_DIR="$BUILDER_DIR/../vm"
PORT="${PORT:-8080}"
SSH_PORT="${SSH_PORT:-2222}"
APP_PORT="${APP_PORT:-8443}"
MEM="${MEM:-1024}"
SMP="${SMP:-4}"
OVERLAY="$VM_DIR/overlay.qcow2"
SERIAL_LOG="$VM_DIR/serial.log"
PIDFILE="$VM_DIR/qemu.pid"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
MODE="interactive"; KEEP=0
for a in "$@"; do
	case "$a" in
		--detach) MODE="detach";;
		--stop)   MODE="stop";;
		--keep)   KEEP=1;;
		-h|--help) usage;;
		*) echo "未知参数: $a（-h 看用法）" >&2; exit 1;;
	esac
done

if [ "$MODE" = stop ]; then
	[ -f "$PIDFILE" ] || { echo "没有正在运行的实例（$PIDFILE 不存在）"; exit 0; }
	kill "$(cat "$PIDFILE")" 2>/dev/null || true
	rm -f "$PIDFILE"
	echo "已停止 VM"; exit 0
fi

# ---- 前置检查 ----
command -v qemu-system-x86_64 >/dev/null || {
	echo "错误：未安装 QEMU。请先执行: sudo apt install qemu-system-x86 qemu-utils" >&2; exit 1; }
command -v qemu-img >/dev/null || {
	echo "错误：缺少 qemu-img（sudo apt install qemu-utils）" >&2; exit 1; }

if [ -w /dev/kvm ]; then
	ACCEL=(-enable-kvm -cpu host)
	echo "==> 加速: KVM"
else
	ACCEL=(-cpu max -accel tcg)
	echo "==> 警告: /dev/kvm 不可用，退回 TCG 软件模拟（启动会明显变慢）"
fi

if ! command -v ss >/dev/null || ss -tln 2>/dev/null | grep -q ":$PORT "; then
	echo "==> 警告: 宿主端口 $PORT 似乎被占用——若是旧 docker 测试容器，先执行: docker rm -f quartzwrt-test"
fi

# ---- 镜像准备 ----
# 用 BIOS 变体（ext4-combined，SeaBIOS 直接可引导；EFI 变体需 OVMF，暂不引入）
IMG_GZ="$(ls -t "$BASE_DIR"/bin/targets/x86/64/*ext4-combined.img.gz 2>/dev/null | grep -v -- '-efi' | head -1 || true)"
[ -n "$IMG_GZ" ] && [ -f "$IMG_GZ" ] || { echo "错误：未找到 ext4-combined 镜像（先运行 scripts/build-local.sh）" >&2; exit 1; }
IMG="$VM_DIR/$(basename "${IMG_GZ%.gz}")"
mkdir -p "$VM_DIR"
if [ ! -f "$IMG" ] || [ "$IMG_GZ" -nt "$IMG" ]; then
	echo "==> 解压基底镜像: $(basename "$IMG_GZ")（$(date -r "$IMG_GZ" '+%H:%M:%S') 构建）"
	gunzip -c "$IMG_GZ" > "$IMG.tmp" && mv "$IMG.tmp" "$IMG"
fi

if [ "$KEEP" = 1 ] && [ -f "$OVERLAY" ]; then
	# 陈旧覆盖层护栏（2026-10-12 实测坑）：覆盖层只与"生成它时的那个基底镜像"
	# 配套——镜像重建后内容变化，同路径对新基底复用会得到文件系统混合损坏
	# （症状：内核 panic "No working init found" 循环重启）。修复方式：不加
	# --keep 用全新覆盖层；确有需要（如跨镜像保留手工配置）设
	# QUARTZ_ALLOW_STALE_OVERLAY=1 强制。
	if [ "$IMG" -nt "$OVERLAY" ] && [ "${QUARTZ_ALLOW_STALE_OVERLAY:-0}" != 1 ]; then
		echo "错误：基底镜像（$(date -r "$IMG" '+%m-%d %H:%M:%S')）比覆盖层（$(date -r "$OVERLAY" '+%m-%d %H:%M:%S')）新——镜像重建后不得复用旧覆盖层（会 No working init 崩溃）。" >&2
		echo "      去掉 --keep 用全新覆盖层；或 QUARTZ_ALLOW_STALE_OVERLAY=1 强制。" >&2
		exit 1
	fi
	echo "==> 复用磁盘覆盖层（保留上次系统内改动）"
else
	echo "==> 新建磁盘覆盖层（全新首次启动，uci-defaults 会完整执行）"
	rm -f "$OVERLAY"
	qemu-img create -q -f qcow2 -F raw -b "$IMG" "$OVERLAY" >/dev/null
fi

# ---- 网络：slirp 用户网络对齐固件 LAN 网段（默认 lan=192.168.1.1），
#      显式指定 hostfwd 目标地址，确保转发不依赖 DHCP 租约表 ----
NETDEV="user,id=n0,net=192.168.1.0/24,host=192.168.1.2,hostfwd=tcp::${PORT}-192.168.1.1:80,hostfwd=tcp::${SSH_PORT}-192.168.1.1:22,hostfwd=tcp::${APP_PORT}-192.168.1.1:443"
# WAN 段：第二张网卡走 slirp 默认网络（10.0.2.0/24）——DHCP 发 10.0.2.15、网关
# 10.0.2.2、DNS 10.0.2.3；VM 侧以 wan(eth1, dhcp) 接入（见 ensure_wan），出网即通
WANNETDEV="user,id=n1"

QEMU_ARGS=(
	qemu-system-x86_64
	"${ACCEL[@]}"
	-smp "$SMP" -m "$MEM"
	-drive "file=$OVERLAY,if=virtio,format=qcow2"
	-netdev "$NETDEV" -device virtio-net-pci,netdev=n0
	-netdev "$WANNETDEV" -device virtio-net-pci,netdev=n1
	-name "quartzwrt-vm"
)

# ---- WAN 自动配置（幂等）：给 VM 补配 wan(eth1, dhcp) 接口 ----
# 基座 x86 板级（board.d 02_network / config_generate）不会自动生成 WAN，旧覆盖层
# 也没有——首次以本脚本（双网卡）启动的实例需补配一次。用 python3(pty) 驱动 ssh
# 自动应答密码：依次尝试 $VM_PASS（默认 quartz）与空密码（全新镜像 root 空口令）。
# 无 python3 / 密码均不可用时跳过并提示手动命令（不视为失败）。
ensure_wan() {
	command -v python3 >/dev/null 2>&1 || {
		echo "==> 未安装 python3，跳过 WAN 自动配置（手动命令见脚本注释）"; return 0; }
	VM_SSH_PORT="$SSH_PORT" VM_PASS="${VM_PASS:-quartz}" python3 - <<'PYEOF'
import os, pty, select, sys, time

port = os.environ.get("VM_SSH_PORT", "2222")
passwords = [os.environ.get("VM_PASS", "quartz"), ""]
remote = """
if [ ! -e /sys/class/net/eth1 ]; then echo "WAN:NOETH1"; exit 0; fi
if uci -q get network.wan >/dev/null 2>&1; then echo "WAN:EXISTS"; exit 0; fi
uci set network.wan=interface
uci set network.wan.device=eth1
uci set network.wan.proto=dhcp
uci commit network
/etc/init.d/network reload
/etc/init.d/firewall reload
echo "WAN:CONFIGURED"
"""
cmd = ["ssh", "-p", port,
       "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
       "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
       "-o", "LogLevel=ERROR", "root@127.0.0.1", remote]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
buf = b""
sent = 0
deadline = time.time() + 45
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 1)
    if not r:
        continue
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    buf += data
    if b"password:" in buf.lower() and sent < len(passwords):
        os.write(fd, (passwords[sent] + "\n").encode())
        sent += 1
text = buf.decode(errors="replace")
if "WAN:CONFIGURED" in text:
    print("==> WAN 段已配置（wan=eth1, dhcp），DHCP 数秒后出网")
elif "WAN:EXISTS" in text:
    print("==> WAN 段已存在，跳过")
elif "WAN:NOETH1" in text:
    print("==> 未发现 eth1（单网卡实例？），跳过 WAN 配置")
else:
    print("==> WAN 自动配置未完成（SSH 密码均不可用？）。手动执行：")
    print("    ssh -p %s root@localhost" % port)
    print("    uci set network.wan=interface; uci set network.wan.device=eth1; \\")
    print("      uci set network.wan.proto=dhcp; uci commit network; /etc/init.d/network reload")
PYEOF
}

if [ "$MODE" = detach ]; then
	echo "==> 后台启动（串口日志: $SERIAL_LOG）"
	rm -f "$SERIAL_LOG"
	"${QEMU_ARGS[@]}" -display none -serial "file:$SERIAL_LOG" -daemonize -pidfile "$PIDFILE"

	echo "==> 等待系统就绪（引导 + procd 初始化，KVM 下约 20–40 秒）"
	ready=0
	for _ in $(seq 1 60); do
		if wget -qO- --timeout=3 "http://127.0.0.1:$PORT/" 2>/dev/null | grep -q "cgi-bin/luci"; then
			ready=1; break
		fi
		sleep 2
	done
	if [ "$ready" = 1 ]; then
		echo "✅ 系统已启动，LuCI 就绪"
		ensure_wan
	else
		echo "❌ 等待超时——串口日志尾部："; tail -30 "$SERIAL_LOG" || true; exit 1
	fi
	echo
	echo "┌──────────────────────────────────────────────┐"
	echo "│  LuCI:  http://localhost:$PORT"
	echo "│  SSH:   ssh -p $SSH_PORT root@localhost（需先设密码）"
	echo "│  串口:  tail -f $SERIAL_LOG"
	echo "│  停止:  scripts/test-in-vm.sh --stop"
	echo "└──────────────────────────────────────────────┘"
else
	echo "==> 交互模式：串口控制台直连。全新镜像 root 无密码，直接回车进 shell；"
	echo "    建议先执行 passwd 设置密码，然后浏览器访问 http://localhost:$PORT"
	echo "    WAN 出网（eth1, dhcp）手动配置："
	echo "    uci set network.wan=interface; uci set network.wan.device=eth1; uci set network.wan.proto=dhcp; uci commit network; /etc/init.d/network reload"
	echo "    退出 QEMU: Ctrl-A 然后 X"
	sleep 2
	exec "${QEMU_ARGS[@]}" -nographic
fi
