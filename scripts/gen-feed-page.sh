#!/usr/bin/env bash
# QuartzWrt 软件源页面生成（WP-9）——生成类似 ImmortalWrt 下载页的静态索引页
#
# 产出（纯静态、无外部依赖，可直接被静态托管）：
#   <发布根>/index.html                        总览：源地址/构建标识/签名指纹 + 架构与目标导航
#   <发布根>/packages/<arch>/<feed>/index.html 包清单：名称/版本/体积/下载链接 + 索引文件
#   <发布根>/targets/<board>/<subtarget>/index.html  镜像清单：名称/体积/sha256 + 目标包索引
#
# 用法:
#   scripts/gen-feed-page.sh <发布根目录> [--url https://sources.quartzwrt.org/quartz-feed]
#                            [--build-id ID] [--apk PATH] [--title 名称]
# 说明：包清单解析需要 host apk（构建树 staging_dir/host/bin/apk，或 --apk 指定）；
#       缺失时降级为"仅链接、不列包"（页面仍可用）。

set -euo pipefail

DEST="${1:?用法：gen-feed-page.sh <发布根目录> [--url ...]}"; shift || true
URL=""; BUILD_ID=""; APK=""; TITLE="QuartzWrt 软件源"
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --build-id) BUILD_ID="$2"; shift 2 ;;
    --apk) APK="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --allow-no-apk) shift ;;  # 已在上方预处理
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done
[ -d "$DEST" ] || { echo "错误：发布根目录不存在：$DEST" >&2; exit 1; }
BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOW_NO_APK=0
for a in "$@"; do [ "$a" = "--allow-no-apk" ] && ALLOW_NO_APK=1; done
[ -n "$APK" ] || APK="${QUARTZ_WORK_DIR:-$BUILDER_DIR/../build}/immortalwrt/staging_dir/host/bin/apk"
if [ ! -x "$APK" ]; then
  # 包清单需要 host apk 解析索引；缺失时**默认报错**（避免静默发布"0 个包"的页面）
  [ "$ALLOW_NO_APK" = 1 ] || {
    echo "错误：未找到 host apk（$APK）——包清单无法生成；先完成一次构建，或用 --apk/--allow-no-apk" >&2
    exit 1; }
  APK=""
fi
[ -n "$BUILD_ID" ] || BUILD_ID="$(sed -n 's/^build_id: *//p' "$DEST/PUBLISH.txt" 2>/dev/null | head -1)"
[ -n "$BUILD_ID" ] || BUILD_ID="unknown"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
GEN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------- 采集数据（TSV：name<TAB>version<TAB>size）----------
list_feed() { # $1=packages.adb  $2=输出 TSV
  : > "$2"
  [ -n "$APK" ] || return 0
  "$APK" adbdump "$1" 2>/dev/null | awk '
    /^  - name: /{n=$3}
    /^    version: /{v=$2}
    /^    file-size: /{if(n&&v){printf "%s\t%s\t%s\n", n, v, $2; n=""; v=""}}' >> "$2"
}
for arch_dir in "$DEST"/packages/*/; do
  [ -d "$arch_dir" ] || continue
  arch="$(basename "$arch_dir")"
  for feed_dir in "$arch_dir"*/; do
    [ -f "$feed_dir/packages.adb" ] || continue
    feed="$(basename "$feed_dir")"
    list_feed "$feed_dir/packages.adb" "$WORK/pkgs-$arch-$feed.tsv"
  done
done

# 目标目录：镜像 + 目标包
for tgt_dir in "$DEST"/targets/*/*/; do
  [ -d "$tgt_dir" ] || continue
  b="$(basename "$(dirname "$tgt_dir")")"; s="$(basename "$tgt_dir")"
  : > "$WORK/imgs-$b-$s.tsv"
  for img in "$tgt_dir"*.img.gz "$tgt_dir"*.bin; do
    [ -f "$img" ] || continue
    printf '%s\t%s\t%s\n' "$(basename "$img")" "$(stat -c%s "$img")" \
      "$(sha256sum "$img" | cut -c1-16)" >> "$WORK/imgs-$b-$s.tsv"
  done
  [ -f "$tgt_dir/packages/packages.adb" ] && list_feed "$tgt_dir/packages/packages.adb" "$WORK/pkgs-$b-$s-target.tsv"
done

# ---------- 渲染 ----------
DEST="$DEST" URL="$URL" BUILD_ID="$BUILD_ID" GEN_TS="$GEN_TS" TITLE="$TITLE" WORK="$WORK" \
python3 - <<'PYEOF'
import html, os, pathlib

dest = pathlib.Path(os.environ["DEST"])
url = os.environ["URL"].rstrip("/")
build_id = os.environ["BUILD_ID"]
ts = os.environ["GEN_TS"]
title = os.environ["TITLE"]
work = pathlib.Path(os.environ["WORK"])

def esc(x): return html.escape(str(x))
def human(n):
    try: n = int(n)
    except Exception: return "-"
    for u in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or u == "GiB": return f"{n:.0f} {u}" if u == "B" else f"{n/1:.1f} {u}".replace(".0 ", " ")
        n /= 1024
def read_tsv(p):
    out = []
    if p.exists():
        for line in p.read_text().splitlines():
            parts = line.split("\t")
            if len(parts) >= 3: out.append(parts[:3])
    return out

CSS = """
:root{color-scheme:dark light}
*{box-sizing:border-box}
body{margin:0;background:#1c1c1e;color:#f2f2f7;font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,"Noto Sans CJK SC",sans-serif}
.wrap{max-width:960px;margin:0 auto;padding:40px 24px 80px}
h1{font-size:26px;margin:0 0 4px;display:flex;align-items:center;gap:10px}
h2{font-size:18px;margin:32px 0 12px;padding-bottom:6px;border-bottom:1px solid rgba(255,255,255,.08)}
a{color:#6ab0ff;text-decoration:none}a:hover{text-decoration:underline}
.sub{color:#98989d;margin:0 0 24px}
.card{background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.08);border-radius:12px;padding:16px 18px;margin:14px 0}
table{width:100%;border-collapse:collapse;font-size:14px}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid rgba(255,255,255,.06);white-space:nowrap}
th{color:#98989d;font-weight:500}
td.num{text-align:right;font-variant-numeric:tabular-nums}
code,pre{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
pre{background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.08);border-radius:8px;padding:12px 14px;overflow-x:auto;font-size:13px}
.kv{display:grid;grid-template-columns:max-content 1fr;gap:4px 16px;font-size:14px}
.kv div:nth-child(odd){color:#98989d}
footer{margin-top:48px;color:#98989d;font-size:13px;border-top:1px solid rgba(255,255,255,.08);padding-top:14px}
.gem{width:22px;height:22px;flex:none}
"""

def page(body, depth=0, page_title=None):
    t = esc(page_title or title)
    return f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{t}</title><style>{CSS}</style></head>
<body><div class="wrap">
<h1><svg class="gem" viewBox="0 0 24 24" fill="none" stroke="#6ab0ff" stroke-width="1.6"><path d="M7 3h10l4 6-9 12L3 9z"/><path d="M3 9h18M12 21 8 9l2-6M12 21l4-12-2-6"/></svg>{esc(title)}</h1>
{body}
<footer>由 <code>QuartzWrt-Builder/scripts/gen-feed-page.sh</code> 生成于 {esc(ts)}　·　构建标识 <code>{esc(build_id)}</code>　·　索引均以稳定密钥签名（设备端 apk 自动验签）</footer>
</div></body></html>"""

# ---- 总览页 ----
archs, targets = [], []
for ad in sorted(dest.glob("packages/*")):
    if ad.is_dir(): archs.append(ad.name)
for td in sorted(dest.glob("targets/*/*")):
    if td.is_dir(): targets.append((td.parent.name, td.name))

rows_feed = []
for arch in archs:
    for fd in sorted((dest / "packages" / arch).glob("*")):
        if not (fd / "packages.adb").exists(): continue
        n = len(read_tsv(work / f"pkgs-{arch}-{fd.name}.tsv"))
        rel = f"packages/{arch}/{fd.name}"
        rows_feed.append(
            f'<tr><td><code>{esc(arch)}</code></td><td><code>{esc(fd.name)}</code></td>'
            f'<td class="num">{n}</td>'
            f'<td><a href="{rel}/index.html">包清单</a> · '
            f'<a href="{rel}/packages.adb">packages.adb</a></td></tr>')

rows_tgt = []
for b, s in targets:
    rel = f"targets/{b}/{s}"
    imgs = read_tsv(work / f"imgs-{b}-{s}.tsv")
    ota = (dest / "ota" / b / f"{s}.json").exists()
    n = len(read_tsv(work / f"pkgs-{b}-{s}-target.tsv"))
    rows_tgt.append(
        f'<tr><td><code>{esc(b)}/{esc(s)}</code></td><td class="num">{len(imgs)}</td>'
        f'<td class="num">{n}</td>'
        f'<td><a href="{rel}/index.html">镜像与目标包</a>'
        + (f' · <a href="ota/{esc(b)}/{esc(s)}.json">OTA 清单</a>' if ota else '')
        + '</td></tr>')

idx_json = "".join(
    f'<li><a href="packages/{esc(a)}/{esc(f)}/packages.adb"><code>packages/{esc(a)}/{esc(f)}/packages.adb</code></a></li>'
    for a in archs for f in sorted(p.name for p in (dest / "packages" / a).glob("*") if (p / "packages.adb").exists()))

body = f"""<p class="sub">QuartzWrt 固件与软件包的公开镜像（apk 源）。{esc(url or '(未配置公开地址)')}</p>
<div class="card"><div class="kv">
<div>源地址</div><div><code>{esc(url or '-')}</code></div>
<div>构建标识</div><div><code>{esc(build_id)}</code></div>
<div>架构</div><div>{esc('、'.join(archs) or '-')}</div>
<div>目标</div><div>{esc('、'.join(f'{b}/{s}' for b, s in targets) or '-')}</div>
</div></div>

<h2>软件源（apk）</h2>
<table><tr><th>架构</th><th>Feed</th><th class="num">包数</th><th>入口</th></tr>
{''.join(rows_feed) or '<tr><td colspan="4">（无）</td></tr>'}
</table>

<h2>固件与目标包</h2>
<table><tr><th>目标</th><th class="num">镜像</th><th class="num">目标包</th><th>入口</th></tr>
{''.join(rows_tgt) or '<tr><td colspan="4">（无）</td></tr>'}
</table>

<h2>设备侧接入</h2>
<p>固件出厂已预置本源与签名公钥（<code>/etc/apk/keys/quartz.pem</code>）；手工接入：</p>
<pre># /etc/apk/repositories.d/quartz-feed.list
{esc(url or 'https://sources.quartzwrt.org/quartz-feed')}/packages/&lt;arch&gt;/quartz/packages.adb
{esc(url or 'https://sources.quartzwrt.org/quartz-feed')}/packages/&lt;arch&gt;/thirdparty/packages.adb
{esc(url or 'https://sources.quartzwrt.org/quartz-feed')}/targets/&lt;board&gt;/&lt;subtarget&gt;/packages/packages.adb</pre>
<p>固件升级走 OTA 清单（usign 签名 + 镜像 sha256）：设备上 <code>quartz-ota-update --check</code>。</p>

<h2>索引文件</h2>
<ul>{idx_json or '<li>（无）</li>'}</ul>
"""
(dest / "index.html").write_text(page(body), encoding="utf-8")

# ---- 每个 feed 的包清单页 ----
for arch in archs:
    for fd in sorted((dest / "packages" / arch).glob("*")):
        if not (fd / "packages.adb").exists(): continue
        pkgs = read_tsv(work / f"pkgs-{arch}-{fd.name}.tsv")
        trs = "".join(
            f'<tr><td><code>{esc(n)}</code></td><td>{esc(v)}</td><td class="num">{human(sz)}</td>'
            f'<td><a href="{esc(n)}-{esc(v)}.apk">下载</a></td></tr>'
            for n, v, sz in sorted(pkgs))
        b = f"""<p class="sub"><a href="../../index.html">← 总览</a>　·　<code>packages/{esc(arch)}/{esc(fd.name)}</code></p>
<table><tr><th>包名</th><th>版本</th><th class="num">体积</th><th></th></tr>{trs or '<tr><td colspan="4">（无）</td></tr>'}</table>
<p style="color:#98989d;font-size:13px">索引：<a href="packages.adb">packages.adb</a>（已签名；设备端 apk 验签后使用）</p>"""
        (fd / "index.html").write_text(page(b, page_title=f"{title} · {arch}/{fd.name}"), encoding="utf-8")

# ---- 每个目标的镜像页 ----
for b_, s_ in targets:
    td = dest / "targets" / b_ / s_
    imgs = read_tsv(work / f"imgs-{b_}-{s_}.tsv")
    trs = "".join(
        f'<tr><td><code>{esc(n)}</code></td><td class="num">{human(sz)}</td><td><code>{esc(h[:16])}…</code></td>'
        f'<td><a href="{esc(n)}">下载</a></td></tr>' for n, sz, h in sorted(imgs))
    tp = read_tsv(work / f"pkgs-{b_}-{s_}-target.tsv")
    tprs = "".join(
        f'<tr><td><code>{esc(n)}</code></td><td>{esc(v)}</td><td class="num">{human(sz)}</td>'
        f'<td><a href="packages/{esc(n)}-{esc(v)}.apk">下载</a></td></tr>' for n, v, sz in sorted(tp))
    ota = dest / "ota" / b_ / f"{s_}.json"
    body2 = f"""<p class="sub"><a href="../../index.html">← 总览</a>　·　<code>targets/{esc(b_)}/{esc(s_)}</code></p>
<h2>固件镜像</h2>
<table><tr><th>文件</th><th class="num">体积</th><th>sha256</th><th></th></tr>{trs or '<tr><td colspan="4">（无）</td></tr>'}</table>
{'<p style="color:#98989d;font-size:13px">OTA 清单：<a href="../../ota/' + esc(b_) + '/' + esc(s_) + '.json">ota/' + esc(b_) + '/' + esc(s_) + '.json</a>（usign 签名，配套 <code>.sig</code>）</p>' if ota.exists() else ''}
<h2>目标包（kernel/kmods 等）</h2>
<table><tr><th>包名</th><th>版本</th><th class="num">体积</th><th></th></tr>{tprs or '<tr><td colspan="4">（无）</td></tr>'}</table>
<p style="color:#98989d;font-size:13px">索引：<a href="packages/packages.adb">packages/packages.adb</a></p>"""
    (td / "index.html").write_text(page(body2, page_title=f"{title} · {b_}/{s_}"), encoding="utf-8")

print(f"页面已生成：index.html + {len(archs)} 架构 feed 清单 + {len(targets)} 目标清单")
PYEOF
echo "OK：$(find "$DEST" -name index.html | wc -l) 个页面 → $DEST"
