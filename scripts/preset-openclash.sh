#!/usr/bin/env bash
#
# File: scripts/preset-openclash.sh
# Description: 把 clash 内核 + GeoIP/GeoSite 预置进固件（对应插件 luci-app-openclash）
#
# 为什么需要这一步：luci-app-openclash 这个包**本身不含内核**，也不含 GeoIP/GeoSite。
# 只装包不预置内核的话，刷完机 OpenClash 页面能打开但启动不了（会提示「未检测到内核」），
# 还得手动在页面上点下载。这里在编译期就下好塞进 files/，装完即用。
#
# 只做一件事，失败不阻塞编译：
#   核心下载不了 → ::warning:: + 跳过，固件照出（用户仍可在 LuCI 里点「下载内核」）
#
# 用法：OPENWRT_DIR=openwrt scripts/preset-openclash.sh
#   OPENCLASH_ARCH  内核架构，x86_64 = amd64（默认）；arm64 = arm64
#
set -uo pipefail

OPENWRT="${OPENWRT_DIR:-openwrt}"
ARCH="${OPENCLASH_ARCH:-amd64}"
REQ="${REQ_FILE:-/tmp/requested.list}"
CORE_DIR="$OPENWRT/files/etc/openclash/core"
GEO_DIR="$OPENWRT/files/etc/openclash"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { echo "[openclash] $*"; }
warn() { echo "::warning::$*"; log "$*"; }

# ---------- 只有在真的选了 openclash 时才做 ----------
want=no
if [ -s "$REQ" ] && grep -qx 'luci-app-openclash=y' "$REQ"; then want=yes; fi
case "${EXTRA_PACKAGES:-}" in *luci-app-openclash*) want=yes ;; esac
if [ "$want" = "no" ]; then
    echo "::notice::本次没有请求 luci-app-openclash，跳过内核预置"
    exit 0
fi

fetch() {  # fetch <URL> <输出文件> <最小字节数> <说明> → 成功返回 0
    local url="$1" out="$2" min="$3" desc="$4" i size ok
    for i in 1 2 3; do
        ok=no
        # curl 优先，wget 兜底（runner 上两个都有，个别环境 curl 的 TLS 后端会抽风）
        if curl -fsSL --retry 2 --connect-timeout 20 --max-time 600 -o "$out" "$url" 2>/dev/null; then
            ok=yes
        elif wget -q --tries=2 --timeout=60 -O "$out" "$url" 2>/dev/null; then
            ok=yes
        fi
        if [ "$ok" = "yes" ]; then
            size="$(stat -c %s "$out" 2>/dev/null || echo 0)"
            if [ "$size" -ge "$min" ]; then
                log "$desc：$(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B")"
                return 0
            fi
            log "$desc：文件只有 ${size}B，看起来是错误页，重试($i/3)"
        else
            log "$desc：第 $i 次下载失败"
        fi
        sleep $((i * 3))
    done
    return 1
}

mkdir -p "$CORE_DIR" "$GEO_DIR"

# ---------- 1. clash 内核（mihomo / Meta）----------
# v1 是基线 x86-64 指令集，兼容性最好；v2/v3 需要较新 CPU，不默认用
CORE_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${ARCH}-v1.tar.gz"
ok_core=no
if fetch "$CORE_URL" "$TMP/core.tar.gz" 3000000 "clash 内核"; then
    if tar -xzf "$TMP/core.tar.gz" -C "$TMP" 2>/dev/null; then
        member="$(find "$TMP" -maxdepth 1 -type f ! -name 'core.tar.gz' | head -n1)"
        if [ -n "$member" ]; then
            mv -f "$member" "$CORE_DIR/clash_meta"
            chmod 755 "$CORE_DIR/clash_meta"
            ok_core=yes
        fi
    fi
fi
[ "$ok_core" = "yes" ] || warn "clash 内核没下成，固件里将没有内核（可在 LuCI → OpenClash → 版本更新 里点下载）"

# ---------- 2. GeoIP / GeoSite（分流规则数据）----------
GEO_BASE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
ok_geo=0
fetch "$GEO_BASE/geoip.dat" "$GEO_DIR/GeoIP.dat" 1000000 "GeoIP.dat" && ok_geo=$((ok_geo + 1))
fetch "$GEO_BASE/geosite.dat" "$GEO_DIR/GeoSite.dat" 1000000 "GeoSite.dat" && ok_geo=$((ok_geo + 1))
[ "$ok_geo" -eq 2 ] || warn "GeoIP/GeoSite 只下成 $ok_geo 个，OpenClash 首次启动会自己去下"

{
    echo ""
    echo "### OpenClash 预置"
    echo ""
    echo "| 文件 | 大小 |"
    echo "|---|---|"
    for f in "$CORE_DIR/clash_meta" "$GEO_DIR/GeoIP.dat" "$GEO_DIR/GeoSite.dat"; do
        if [ -f "$f" ]; then
            echo "| \`${f#"$OPENWRT"/files}\` | $(du -h "$f" | cut -f1) |"
        else
            echo "| \`${f#"$OPENWRT"/files}\` | ⚠️ 缺失 |"
        fi
    done
    echo ""
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ "$ok_core" = "yes" ]; then
    echo "::notice::OpenClash 内核已预置（${ARCH}），刷完机可直接启动"
fi
exit 0
