#!/usr/bin/env bash
#
# File: scripts/gen-config.sh
# Description: 把 config/ 下的分层配置拼成 openwrt/.config
#
#   config/base.config   机型 / 分区 / 镜像格式等「机器属性」
#   config/packages.txt  插件清单（每行一个，! 前缀 = 显式关闭）
#   config/extra.config  其它零散 CONFIG_* 开关（最后追加，优先级最高）
#
# 另外把「本次请求了什么」写进 /tmp/requested.list（每行 name=y|n），
# 供 scripts/check-packages.sh 在编译前后逐个核对。
#
# 用法：scripts/gen-config.sh [源码目录，默认 openwrt]
#
set -euo pipefail

OPENWRT_DIR="${1:-openwrt}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF_DIR="$ROOT_DIR/config"
OUT="$OPENWRT_DIR/.config"
REQ="${REQ_FILE:-/tmp/requested.list}"

log() { echo "[gen-config] $*"; }
die() { echo "::error::$*" >&2; exit 1; }

[ -d "$OPENWRT_DIR" ] || die "找不到源码目录：$OPENWRT_DIR（先 clone 源码再生成配置）"
mkdir -p "$(dirname "$REQ")"
: > "$REQ"

TMP="$(mktemp)"
LIST="$(mktemp)"
KEEP_Y=0
KEEP_N=0

# add_pkg <包名> <y|n>：向 .config 写一行，并登记到请求清单
add_pkg() {
    local name="$1" val="$2"
    if [ "$val" = "n" ]; then
        printf '# CONFIG_PACKAGE_%s is not set\n' "$name"
        KEEP_N=$((KEEP_N + 1))
    else
        printf 'CONFIG_PACKAGE_%s=y\n' "$name"
        KEEP_Y=$((KEEP_Y + 1))
    fi
    printf '%s=%s\n' "$name" "$val" >>"$REQ"
}

{
    echo "# ---------------------------------------------------------------------------"
    echo "# 本文件由 scripts/gen-config.sh 自动生成，请勿直接修改。"
    echo "#   改机型/分区  → config/base.config"
    echo "#   加/删插件    → config/packages.txt"
    echo "#   其它开关     → config/extra.config"
    echo "# 生成时间：$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# ---------------------------------------------------------------------------"
    echo
} >"$TMP"

# ---------- 1. 机器属性 ----------
if [ -f "$CONF_DIR/base.config" ]; then
    sed -e 's/\r$//' "$CONF_DIR/base.config" >>"$TMP"
else
    echo "::warning::config/base.config 缺失，目标平台会退回源码默认值（大概率不是你要的机型）"
fi

# ---------- 1.5 本次运行对机器属性的覆盖（workflow_dispatch 输入）----------
# 分区大小是最常临时改的一项：跑一次 4G 分区试试，不想因此改文件
if [ -n "${ROOTFS_MB:-}" ]; then
    case "$ROOTFS_MB" in
        *[!0-9]*)
            echo "::warning::ROOTFS_MB=$ROOTFS_MB 不是数字，忽略（继续用 config/base.config 里的值）"
            ;;
        *)
            if grep -q '^CONFIG_TARGET_ROOTFS_PARTSIZE=' "$TMP"; then
                sed -i "s/^CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=${ROOTFS_MB}/" "$TMP"
            else
                printf 'CONFIG_TARGET_ROOTFS_PARTSIZE=%s\n' "$ROOTFS_MB" >>"$TMP"
            fi
            log "分区大小按本次输入改成 ${ROOTFS_MB} MB（覆盖 config/base.config）"
            ;;
    esac
fi

# ---------- 2. 插件清单 ----------
if [ -f "$CONF_DIR/packages.txt" ]; then
    # 去注释 → 去首尾空白 → 去空行
    sed -e 's/\r$//' -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        "$CONF_DIR/packages.txt" | grep -v '^$' >"$LIST" || true

    DUP="$(sort "$LIST" | uniq -d | tr '\n' ' ')"
    [ -n "$DUP" ] && echo "::warning::config/packages.txt 里有重复行：$DUP"

    echo >>"$TMP"
    echo "# ----- 来自 config/packages.txt -----" >>"$TMP"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        val=y
        case "$line" in
            '!'*) val=n; line="${line#!}" ;;
        esac
        case "$line" in
            *[!A-Za-z0-9._+-]*)
                die "config/packages.txt 里有非法包名：$line（只允许字母数字和 . _ + -）"
                ;;
        esac
        add_pkg "$line" "$val" >>"$TMP"
    done <"$LIST"
fi

# ---------- 3. 本次运行的额外包（workflow_dispatch 的 extra_packages）----------
if [ -n "${EXTRA_PACKAGES:-}" ]; then
    echo >>"$TMP"
    echo "# ----- 来自本次运行输入的 extra_packages -----" >>"$TMP"
    for p in $EXTRA_PACKAGES; do
        val=y
        case "$p" in
            '!'*) val=n; p="${p#!}" ;;
        esac
        add_pkg "$p" "$val" >>"$TMP"
    done
fi

# ---------- 4. 零散开关 ----------
if [ -f "$CONF_DIR/extra.config" ]; then
    echo >>"$TMP"
    echo "# ----- 来自 config/extra.config -----" >>"$TMP"
    sed -e 's/\r$//' "$CONF_DIR/extra.config" >>"$TMP"

    # extra.config 里手写的 PACKAGE 行也要纳入核对
    sed -e 's/\r$//' "$CONF_DIR/extra.config" |
        awk '/^CONFIG_PACKAGE_[A-Za-z0-9._+-]+=[ym]$/ { s = $0; sub(/^CONFIG_PACKAGE_/, "", s); sub(/=[ym]$/, "", s); print s "=y" }' >>"$REQ"
    sed -e 's/\r$//' "$CONF_DIR/extra.config" |
        awk '/^# CONFIG_PACKAGE_[A-Za-z0-9._+-]+ is not set$/ { s = $0; sub(/^# CONFIG_PACKAGE_/, "", s); sub(/ is not set$/, "", s); print s "=n" }' >>"$REQ"
fi

# ---------- 5. 请求清单去重（后写的覆盖先写的）----------
if [ -s "$REQ" ]; then
    awk -F'=' 'NF >= 2 { if (!($1 in seen)) { order[++n] = $1; seen[$1] = 1 } v[$1] = $2 }
         END { for (i = 1; i <= n; i++) printf "%s=%s\n", order[i], v[order[i]] }' "$REQ" >"$REQ.tmp"
    mv "$REQ.tmp" "$REQ"
fi

mv "$TMP" "$OUT"
rm -f "$LIST"

log "已生成 $OUT（$(wc -l <"$OUT") 行）：启用 $KEEP_Y 个包，显式关闭 $KEEP_N 个"
log "请求清单写入 $REQ（$(wc -l <"$REQ") 条），编译前后都会逐个核对"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### 配置生成"
        echo ""
        echo "| 来源 | 内容 |"
        echo "|---|---|"
        if [ -f "$CONF_DIR/base.config" ]; then
            echo "| \`config/base.config\` | 已合入 |"
        else
            echo "| \`config/base.config\` | ⚠️ 缺失 |"
        fi
        echo "| \`config/packages.txt\` | 启用 **$KEEP_Y** 个 / 显式关闭 **$KEEP_N** 个 |"
        if [ -n "${ROOTFS_MB:-}" ]; then
            echo "| 本次输入 \`rootfs_mb\` | **${ROOTFS_MB} MB**（覆盖 base.config） |"
        fi
        echo "| 本次输入 \`extra_packages\` | \`${EXTRA_PACKAGES:-(空)}\` |"
        echo ""
    } >>"$GITHUB_STEP_SUMMARY"
fi
