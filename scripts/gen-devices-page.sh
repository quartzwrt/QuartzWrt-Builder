#!/usr/bin/env bash
# QuartzWrt 支持设备页生成（WP-9）——基座全量目标/设备的可浏览清单（menuconfig 式层级）
#
# 用途：GitHub Actions 下拉是静态列表，装不下基座 2259 个设备；本页把"目标 → 设备"层级
# 完整列出（含架构与设备描述），供用户挑 profile 名后填进 workflow 的 profile 输入。
#
# 产出（写入 <发布根>/devices/，随 feed 一起托管；`--delete` 同步下也能自愈）：
#   devices/index.html            目标清单（架构/设备数 + 链接）
#   devices/<board>-<subtarget>.html  该目标的设备表（profile 名 + 描述 + 别名）
#   devices/devices.json          机读清单（target → arch → devices[{profile,title,aliases}]）
#
# 用法:
#   scripts/gen-devices-page.sh --base-dir <基座树> --out <发布根>/devices [--url URL]
# 依赖：基座树内 scripts/dump-target-info.pl（无需构建）。

set -euo pipefail

BASE_DIR=""; OUT=""; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base-dir) BASE_DIR="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（用法见 --help）" >&2; exit 1 ;;
  esac
done
[ -n "$BASE_DIR" ] && [ -f "$BASE_DIR/scripts/dump-target-info.pl" ] || {
  echo "错误：--base-dir 需指向基座树（含 scripts/dump-target-info.pl）" >&2; exit 1; }
[ -n "$OUT" ] || { echo "错误：缺 --out" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

# 注意：dump-target-info.pl **必须在基座树根目录**运行（它按相对路径读 tmp/.targetinfo
# 与 target/linux/**；用绝对路径从别处调用会静默返回空——实测踩中）
if [ ! -s "$BASE_DIR/tmp/.targetinfo" ]; then
  echo "提示：基座树缺 tmp/.targetinfo（目标元数据），尝试 make prepare-tmpinfo…"
  ( cd "$BASE_DIR" && make -s prepare-tmpinfo >/dev/null 2>&1 ) || true
fi
[ -s "$BASE_DIR/tmp/.targetinfo" ] || {
  echo "错误：$BASE_DIR/tmp/.targetinfo 缺失——先在基座树跑一次 make prepare-tmpinfo" >&2; exit 1; }

# 目标清单：target/subtarget + arch
( cd "$BASE_DIR" && perl scripts/dump-target-info.pl targets ) > "$WORK/targets.txt"
[ -s "$WORK/targets.txt" ] || { echo "错误：目标枚举为空（dump-target-info.pl 异常）" >&2; exit 1; }
# 逐目标设备
: > "$WORK/devices.tsv"
while read -r t arch; do
  ( cd "$BASE_DIR" && perl scripts/dump-target-info.pl devices "$t" ) 2>/dev/null | while IFS= read -r line; do
    prof="${line%% *}"; rest="${line#"$prof"}"; rest="${rest# }"
    printf '%s\t%s\t%s\n' "$t" "$prof" "$rest" >> "$WORK/devices.tsv"
  done
done < "$WORK/targets.txt"

GEN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BASE_COMMIT="$(git -C "$BASE_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
WORK="$WORK" OUT="$OUT" URL="$URL" GEN_TS="$GEN_TS" BASE_COMMIT="$BASE_COMMIT" python3 - <<'PYEOF'
import html, json, os, pathlib

work = pathlib.Path(os.environ["WORK"]); out = pathlib.Path(os.environ["OUT"])
url = os.environ["URL"].rstrip("/"); ts = os.environ["GEN_TS"]; commit = os.environ["BASE_COMMIT"]

def esc(x): return html.escape(str(x))

targets = []
for line in (work / "targets.txt").read_text().splitlines():
    parts = line.split()
    if len(parts) >= 2: targets.append((parts[0], parts[1]))

devs = {}
for line in (work / "devices.tsv").read_text().splitlines():
    p = line.split("\t")
    if len(p) >= 3: devs.setdefault(p[0], []).append((p[1], p[2]))

CSS = """
:root{color-scheme:dark light}
*{box-sizing:border-box}
body{margin:0;background:#1c1c1e;color:#f2f2f7;font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,"Noto Sans CJK SC",sans-serif}
.wrap{max-width:1000px;margin:0 auto;padding:40px 24px 80px}
h1{font-size:26px;margin:0 0 4px}
h2{font-size:18px;margin:32px 0 12px;padding-bottom:6px;border-bottom:1px solid rgba(255,255,255,.08)}
a{color:#6ab0ff;text-decoration:none}a:hover{text-decoration:underline}
.sub{color:#98989d;margin:0 0 24px}
table{width:100%;border-collapse:collapse;font-size:14px}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid rgba(255,255,255,.06);vertical-align:top}
th{color:#98989d;font-weight:500}
code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px}
td.num{text-align:right;font-variant-numeric:tabular-nums}
footer{margin-top:48px;color:#98989d;font-size:13px;border-top:1px solid rgba(255,255,255,.08);padding-top:14px}
"""

def page(body, title):
    return f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(title)}</title>
<style>{CSS}</style></head><body><div class="wrap">
<h1>{esc(title)}</h1>
{body}
<footer>基座 ImmortalWrt 25.12 @ <code>{esc(commit)}</code>　·　由 <code>QuartzWrt-Builder/scripts/gen-devices-page.sh</code> 生成于 {esc(ts)}　·　
<a href="../index.html">← 软件源总览</a></footer>
</div></body></html>"""

# ---- 目标清单页 ----
rows = "".join(
    f'<tr><td><a href="{esc(t.replace("/", "-"))}.html"><code>{esc(t)}</code></a></td>'
    f'<td><code>{esc(a)}</code></td><td class="num">{len(devs.get(t, []))}</td></tr>'
    for t, a in targets)
(body := f"""<p class="sub">基座支持的**全部目标与设备**（{len(targets)} 个目标 / {sum(len(v) for v in devs.values())} 个设备）。
在 CI 里按「目标 + 设备」两级选择：workflow 的 <code>target</code> 下拉选目标，
<code>profile</code> 填下表设备名（**留空 = 构建该目标全部设备**）。</p>
<table><tr><th>目标 / 子目标</th><th>架构</th><th class="num">设备数</th></tr>{rows}</table>""")
(out / "index.html").write_text(page(body, "QuartzWrt 支持设备"), encoding="utf-8")

# ---- 逐目标设备页 ----
for t, a in targets:
    dl = devs.get(t, [])
    rows = "".join(
        f'<tr><td><code>{esc(p)}</code></td><td>{esc(title)}</td></tr>' for p, title in dl)
    b = f"""<p class="sub">目标 <code>{esc(t)}</code>　·　架构 <code>{esc(a)}</code>　·　设备 {len(dl)} 个　·　
<a href="index.html">← 全部目标</a></p>
<p style="color:#98989d;font-size:13px">CI 用法：<code>target={esc(t)}</code>；<code>profile</code> 留空 = 构建本目标全部设备，或填下表 profile 名只构该设备。</p>
<table><tr><th>profile（填进 CI）</th><th>设备</th></tr>{rows or '<tr><td colspan="2">（无）</td></tr>'}</table>"""
    (out / f"{t.replace('/', '-')}.html").write_text(page(b, f"支持设备 · {t}"), encoding="utf-8")

# ---- 机读清单 ----
data = [{"target": t, "arch": a,
         "devices": [{"profile": p, "title": title} for p, title in devs.get(t, [])]}
        for t, a in targets]
(out / "devices.json").write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
print(f"设备页：{len(targets)} 个目标页 + index + devices.json（设备 {sum(len(v) for v in devs.values())}）")
PYEOF
echo "OK：$OUT（$(find "$OUT" -name '*.html' | wc -l) 个页面）"
