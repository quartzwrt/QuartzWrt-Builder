#!/usr/bin/env bash
# QuartzWrt 本地镜像 Docker 快速预览（docs/TDD.md §7.4 配套工具）
#
# 用途：把本地构建产物 rootfs 导入 Docker，起最小服务链（ubusd/procd/rpcd/uhttpd），
#       用浏览器访问真实 LuCI（主题 / 页面 / 后续 Dashboard）快速预览。
#
# 能力边界：这是"用户态"预览台——不含内核 / 引导链 / 防火墙 / 网络 / DHCP；
#           这些需要在 QEMU 里真启动镜像验证。
#
# 已解决的坑（全部为容器实测结论，改动前先读这里）：
#   1. 必须起 procd：theme header 模板通过 ubus 取 system.board，而 system 对象
#      由 procd 提供；缺它则任意页面渲染抛 "left-hand side expression is null"。
#   2. uhttpd 没有 -c 配置文件选项（init 脚本是把 uci 逐项翻译成命令行参数），
#      这里按 /etc/config/uhttpd 默认值给出等效命令行。
#   3. "首次启动"须模拟两步：/bin/config_generate（板级配置）+ 执行 uci-defaults
#      （默认主题等注册；正规固件由 /etc/init.d/boot 触发）。
#   4. 必须显式给 uhttpd 传 ubus 参数（-u /ubus -U /var/run/ubus/ubus.sock，对应
#      /etc/init.d/uhttpd 对 ubus_prefix/ubus_socket 的翻译）；缺失时 /ubus 端点不注册
#      （404），LuCI 前端 RPC 探针失败走回退路径，相当一部分视图（overview/system/
#      network/dhcp…）会永远停在"正在载入视图"——2026-10-12 逐页排查结论。
#   5. 容器内启动脚本用固定路径而非 mktemp+trap 删除：容器以 bind mount 引用该文件，
#      删除后 docker restart 与 docker cp 都会失败（"mkdir qz-start.sh: not a directory"）。
#
# 用法: scripts/test-in-docker.sh [rootfs.tar.gz 路径]
#   环境变量: PORT=8080（宿主端口，只发布到 127.0.0.1）、PASSWORD=quartz（测试用 root 密码）
set -euo pipefail

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="${QUARTZ_WORK_DIR:-$BUILDER_DIR/../build}/immortalwrt"
if [ -n "${1:-}" ]; then
	TARBALL="$1"
else
	# 优先标准 rootfs 变体（排除 -targz- 镜像变体），取最新
	TARBALL="$(ls -t "$BASE_DIR"/bin/targets/*/*/*-rootfs.tar.gz 2>/dev/null | grep -v -- '-targz-' | head -1 || true)"
	TARBALL="${TARBALL:-$(ls -t "$BASE_DIR"/bin/targets/*/*/*-rootfs.tar.gz 2>/dev/null | head -1 || true)}"
fi
PORT="${PORT:-8080}"
PASSWORD="${PASSWORD:-quartz}"
IMAGE="quartzwrt:test"
CONTAINER="quartzwrt-test"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage

[ -n "$TARBALL" ] && [ -f "$TARBALL" ] || { echo "错误：未找到 rootfs tarball（先运行 scripts/build-local.sh，或用参数指定路径）。" >&2; exit 1; }

# docker 访问：优先直接用；当前会话未刷新 docker 组时借用 sg 执行
if docker ps >/dev/null 2>&1; then
	dk() { docker "$@"; }
elif sg docker -c "docker ps" >/dev/null 2>&1; then
	dk() { local a=() x; for x in "$@"; do a+=("'${x//\'/\'\\\'\'}'"); done; sg docker -c "${a[*]}"; }
else
	echo "错误：docker 不可用（daemon 未启动或未加入 docker 组）。" >&2
	exit 1
fi

# 固定路径启动脚本（非 mktemp）：容器 bind mount 引用，必须持续存在（坑位 5）
START_SCRIPT="/tmp/quartzwrt-docker-start.sh"
cat > "$START_SCRIPT" <<'EOS'
#!/bin/sh
# 容器内启动脚本：模拟首次启动 + 最小服务链（替代完整 procd 启动）

# 1. 板级配置生成（等价于真实 boot 的 config_generate）
/bin/config_generate >/dev/null 2>&1

# 2. uci-defaults：注册默认主题等（正规固件由 /etc/init.d/boot 触发）
for f in /etc/uci-defaults/*; do
	[ -f "$f" ] && sh "$f" >/dev/null 2>&1
done
rm -f /etc/uci-defaults/*

# 3. 设置测试用 root 密码
printf '%s\n%s\n' "$QZ_PASSWORD" "$QZ_PASSWORD" | passwd root >/dev/null 2>&1

# 4. 服务链：ubusd -> procd -> rpcd -> uhttpd
#    procd 必不可少：system ubus 对象（board 信息）由它提供（坑位 1）
mkdir -p /var/run/ubus
ubusd &
sleep 1
procd &
sleep 1
rpcd &
sleep 1
# uhttpd 无 -c 选项，按固件默认配置翻译（坑位 2）：监听 80、docroot /www、CGI /cgi-bin
# ubus 参数必须显式给出（坑位 4）：-u /ubus 注册 ubus RPC 前缀，-U 指定 ubusd socket；
# 缺失时 LuCI 前端部分视图永久卡在"正在载入视图"（实测）
exec uhttpd -f -p 0.0.0.0:80 -h /www -x /cgi-bin -u /ubus -U /var/run/ubus/ubus.sock
EOS

echo "==> 导入镜像: $(basename "$TARBALL")（更新于 $(date -r "$TARBALL" '+%H:%M:%S')）"
dk docker import "$TARBALL" "$IMAGE" >/dev/null

echo "==> 启动容器: $CONTAINER（宿主端口 $PORT，root 密码 $PASSWORD）"
dk docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
dk docker run -d --name "$CONTAINER" -p "127.0.0.1:$PORT:80" -e QZ_PASSWORD="$PASSWORD" \
	-v "$START_SCRIPT:/qz-start.sh:ro" "$IMAGE" sh /qz-start.sh >/dev/null

echo "==> 等待服务就绪"
ready=0
for _ in $(seq 1 30); do
	if dk docker exec "$CONTAINER" wget -qO- http://127.0.0.1/ 2>/dev/null | grep -q "cgi-bin/luci"; then
		ready=1; break
	fi
	sleep 1
done
[ "$ready" = 1 ] || { echo "❌ 服务未就绪（docker logs $CONTAINER 查看）"; exit 1; }

echo "==> 校验登录页渲染"
out="$(dk docker exec "$CONTAINER" /www/cgi-bin/luci 2>&1 || true)"
if ! printf '%s' "$out" | grep -q "Status: 403"; then
	echo "❌ 登录页未正常渲染（预期 403 + 登录页）"; exit 1
fi
if printf '%s' "$out" | grep -qE "left-hand side expression|error500"; then
	echo "❌ 登录页渲染报错（模板或服务链有问题）"; exit 1
fi
printf '%s' "$out" | grep -q "luci-static/quartz" \
	&& echo "✅ 登录页渲染正常（Quartz 主题资源已引用）" \
	|| echo "⚠️ 登录页渲染正常，但未检测到 quartz 资源（主题可能未注册为默认）"

theme="$(dk docker exec "$CONTAINER" uci -q get luci.main.mediaurlbase 2>/dev/null || echo '?')"
echo "✅ 默认主题: $theme"

echo
echo "┌──────────────────────────────────────────────┐"
echo "│  浏览器打开:  http://localhost:$PORT"
echo "│  登录: root / $PASSWORD"
echo "│  停止: docker rm -f $CONTAINER"
echo "└──────────────────────────────────────────────┘"
