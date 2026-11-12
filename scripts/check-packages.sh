#!/usr/bin/env bash
#
# File: scripts/check-packages.sh
# Description: 包存在性检查（两段式）
#
#   pre  —— `feeds install` 之后、`make defconfig` 之前：在源码树里逐个找包目录。
#           包名写错、feed 没加、分支里被移除，5 秒就能知道，
#           不用等 1 小时 45 分的编译跑完才发现固件里少了插件。
#   post —— `make defconfig` 之后：确认请求的符号真的留在了最终 .config 里。
#           依赖不满足 / 被其它包顶掉 / 行写法非法，都在这一步暴露。
#
# 用法：scripts/check-packages.sh pre|post
#   OPENWRT_DIR=openwrt          源码目录
#   REQ_FILE=/tmp/requested.list gen-config.sh 生成的请求清单（name=y|n）
#   STRICT=true|false            有包找不到时是否让构建直接失败（默认只警告）
#
set -uo pipefail

STAGE="${1:-pre}"
OPENWRT="${OPENWRT_DIR:-openwrt}"
REQ="${REQ_FILE:-/tmp/requested.list}"
STRICT="${STRICT:-false}"
SUMMARY="${GITHUB_STEP_SUMMARY:-}"

REPORT="$(mktemp)"
say() { printf '%s\n' "$*" | tee -a "$REPORT"; }

if [ ! -s "$REQ" ]; then
    echo "::warning::$REQ 不存在或为空，跳过 $STAGE 检查（是不是没跑 gen-config.sh？）"
    exit 0
fi

pkg_dirs() {  # 源码树里所有包目录名
    # -L 不能省：feeds install 装进 package/feeds/<feed>/<包> 的是**符号链接**，
    # 少了 -L 时 `-type d` 会把它们全部跳过 —— 表现就是「明明有的包被报成找不到」
    # （luci-app-openclash / luci-app-adguardhome / adguardhome 就这么被误报过一次）
    find -L "$OPENWRT/package" -maxdepth 5 -type d -printf '%f\n' 2>/dev/null | tr -d '\r' | sort -u
}
kmod_names() {  # 内核模块定义名（kmod-xxx 去掉 kmod- 前缀）
    # 源码里的写法是 `define KernelPackage/virtio-net`（斜杠，不是空格）
    # 扫整棵 package/ 而不是只扫 package/kernel：kmod-nft-fullcone 这类定义在别处
    grep -RhsE '^define[[:space:]]+KernelPackage/' "$OPENWRT/package" 2>/dev/null |
        sed -e 's/#.*//' -e 's/^define[[:space:]]*KernelPackage\///' -e 's/[[:space:]]*$//' |
        tr -d '\r' | sort -u
}
cfg_has_symbol() {  # $1=包名 → 最终 .config 里是否选中
    grep -qE "^CONFIG_PACKAGE_${1//./\\.}=[ym]$" "$OPENWRT/.config" 2>/dev/null
}
cfg_has_disable() {  # $1=包名 → 最终 .config 里是否是显式关闭
    grep -qF "# CONFIG_PACKAGE_$1 is not set" "$OPENWRT/.config" 2>/dev/null
}

if [ "$STAGE" = "pre" ]; then
    [ -d "$OPENWRT/package" ] || {
        echo "::error::$OPENWRT/package 不存在，源码是不是没 clone 成功？"
        exit 1
    }
    DIRS="$(mktemp)"
    KMODS="$(mktemp)"
    pkg_dirs >"$DIRS"
    kmod_names >"$KMODS"

    # 每个 feed 提供哪些包（feeds update 之后会生成 feeds/<名字>.index）
    # 用来回答「这个包到底是从哪个源来的、有没有被别的源也提供了」
    IDXDIR="$(mktemp -d)"
    for idx in "$OPENWRT"/feeds/*.index; do
        [ -e "$idx" ] || continue
        f="$(basename "$idx" .index)"
        grep -hs '^Package: ' "$idx" 2>/dev/null | sed 's/^Package: //' | tr -d '\r' |
            sed -e 's/[[:space:]]*$//' | sort -u >"$IDXDIR/$f"
    done
    sources_of() {  # $1=包名 → 空格分隔的来源列表，按 feeds.conf 顺序，core 第一
        local p="$1" out="" f
        [ -d "$OPENWRT/package/$p" ] && out="core"
        for f in "$IDXDIR"/*; do
            [ -e "$f" ] || continue
            if grep -qxF "$p" "$f"; then out="$out $(basename "$f")"; fi
        done
        printf '%s' "${out# }"
    }
    in_index() {  # $1=包名 → 是否出现在任一 feed 的索引里（兜底：feeds install 偶尔没装进 package/）
        grep -qxF "$1" "$IDXDIR"/* 2>/dev/null
    }
    MULTI=""

    MISSING=""
    DROPPED_DISABLE=""
    KMOD_MAYBE=""
    OK=0
    SOURCE_LINES=""

    while IFS='=' read -r name val; do
        [ -z "${name:-}" ] && continue
        val="${val//$'\r'/}"
        if grep -qxF "$name" "$DIRS" || in_index "$name"; then
            OK=$((OK + 1))
            srcs="$(sources_of "$name")"
            [ "$(printf '%s' "$srcs" | wc -w)" -ge 2 ] && MULTI="$MULTI $name"
            SOURCE_LINES="$SOURCE_LINES| \`$name\` | ${srcs:-?} |
"
            continue
        fi
        case "$name" in
            kmod-*)
                if grep -qxF "${name#kmod-}" "$KMODS"; then
                    OK=$((OK + 1))
                    SOURCE_LINES="$SOURCE_LINES| \`$name\` | kmod（内核模块定义） |
"
                else
                    # 源码树里没有独立的 kmod-xxx 定义：可能已内建进内核
                    KMOD_MAYBE="$KMOD_MAYBE $name"
                fi
                ;;
            *)
                if [ "$val" = "n" ]; then
                    DROPPED_DISABLE="$DROPPED_DISABLE $name"
                else
                    MISSING="$MISSING $name"
                fi
                ;;
        esac
    done <"$REQ"

    say "### 包存在性预检（feeds 装完之后、编译之前）"
    say ""
    say "- 源码：\`${REPO_URL:-?}\` @ \`${REPO_BRANCH:-?}\`"
    say "- 在源码树里找到：**$OK** 个"
    say "- 找不到：**$(printf '%s' "$MISSING" | wc -w)** 个"
    say ""
    if [ -n "$MISSING" ]; then
        say "**找不到的包 —— 名字写错 / feed 没加 / 该分支已移除：**"
        say ""
        for p in $MISSING; do
            base="${p#luci-app-}"
            base="${base#luci-}"
            base="${base#kmod-}"
            say "- \`$p\`"
            if [ "${#base}" -ge 4 ]; then
                sug=""
                while IFS= read -r d; do
                    cb="${d#luci-app-}"
                    cb="${cb#luci-}"
                    cb="${cb#kmod-}"
                    [ "${#cb}" -ge 4 ] || continue
                    [ "${cb:0:4}" = "${base:0:4}" ] || continue
                    diff=$(( ${#cb} - ${#base} ))
                    [ "$diff" -lt 0 ] && diff=$((0 - diff))
                    [ "$diff" -le 3 ] || continue
                    sug="$sug \`$d\`"
                done <"$DIRS"
                [ -n "$sug" ] && say "  - 近似名（多半是拼错）：$sug"
            fi
        done
        say ""
        say "> 这些包不会让编译失败，只会「绿勾但固件里没有」。三种处理方式："
        say "> 1. 包在别的仓库里 → 在 \`config/feeds.txt\` 加一行 feed（脚本会自动读取）"
        say "> 2. 只是拼错 → 照上面的「近似名」改 \`config/packages.txt\`"
        say "> 3. 这个分支确实没有了（如 \`luci-app-turboacc\` 在 25.12 被移除）→ 从清单里删掉"
        echo "::warning::以下包在源码树里找不到：$MISSING"
    else
        say "请求的包全部在源码树里 ✅"
    fi

    # ----- 每个包来自哪个源 -----
    # feeds install -a 是「先到先得」：feeds.conf 里排在前面的 feed 优先，
    # 核心包 package/ 优先级最高。我们把额外 feed 追加在最后，所以默认源天然优先。
    # 这里把结果摊开，免得「以为加了源就换了包，其实没换」。
    if [ -n "$SOURCE_LINES" ]; then
        say ""
        say "<details><summary>包的来源（feeds.conf 顺序优先，默认源在前）</summary>"
        say ""
        say "| 包 | 来源 |"
        say "|---|---|"
        printf '%s' "$SOURCE_LINES" | tee -a "$REPORT"
        say ""
        say "</details>"
    fi
    if [ -n "$MULTI" ]; then
        say ""
        say "**同一个包被多个源提供：**"
        for p in $MULTI; do say "- \`$p\` ← $(sources_of "$p")"; done
        say ""
        say "> 按 feeds.conf 的顺序取第一个（默认源在前 → 默认源生效）。"
        say "> 想让外部源的版本生效，见 README「强制用外部源的版本」。"
        echo "::notice::以下包在多个源里都有，按顺序取第一个：$MULTI"
    fi
    rm -f "$DIRS" "$KMODS"
    rm -rf "$IDXDIR"
    if [ -n "$KMOD_MAYBE" ]; then
        say ""
        say "**待确认的内核模块（可能已内建进内核，属正常）：**"
        for p in $KMOD_MAYBE; do say "- \`$p\`"; done
    fi
    if [ -n "$DROPPED_DISABLE" ]; then
        say ""
        say "<details><summary>已请求关闭、但 feed 里本来就没有的包（可忽略）</summary>"
        say ""
        for p in $DROPPED_DISABLE; do say "- \`$p\`"; done
        say ""
        say "</details>"
    fi
    if [ "$STRICT" = "true" ] && [ -n "$MISSING" ]; then
        echo "::error::预检发现找不到的包，按 STRICT=true 中止（修好 packages.txt 再跑）"
        exit 1
    fi
else
    [ -f "$OPENWRT/.config" ] || {
        echo "::error::$OPENWRT/.config 不存在，make defconfig 是不是没跑？"
        exit 1
    }
    DIRS="$(mktemp)"
    pkg_dirs >"$DIRS"

    MISSING=""
    NOT_DISABLED=""
    BUILTIN=""
    OK=0

    while IFS='=' read -r name val; do
        [ -z "${name:-}" ] && continue
        val="${val//$'\r'/}"
        if [ "$val" = "n" ]; then
            if cfg_has_disable "$name"; then
                OK=$((OK + 1))
            elif cfg_has_symbol "$name"; then
                NOT_DISABLED="$NOT_DISABLED $name"
            fi
            continue
        fi
        if cfg_has_symbol "$name"; then
            OK=$((OK + 1))
        elif grep -qxF "$name" "$DIRS"; then
            MISSING="$MISSING $name" # 源码里有，但没人选中 → 真丢了
        else
            BUILTIN="$BUILTIN $name" # 源码里也没有 → 内建或不存在
        fi
    done <"$REQ"
    rm -f "$DIRS"

    say "### 配置解析对账（make defconfig 之后）"
    say ""
    say "- 请求项生效：**$OK** 个"
    say "- 被 defconfig 丢弃：**$(printf '%s' "$MISSING" | wc -w)** 个"
    say ""
    if [ -n "$MISSING" ]; then
        say "**被丢弃的选项 —— 存在但没被选中（依赖不满足最常见）：**"
        say ""
        for p in $MISSING; do say "- \`$p\`"; done
        say ""
        echo "::warning::以下选项被 make defconfig 丢弃：$MISSING"
    else
        say "请求的包全部生效 ✅"
    fi
    if [ -n "$NOT_DISABLED" ]; then
        say ""
        say "**你要求关闭、但最终仍然是开着的（被别的包依赖强制拉回）：**"
        for p in $NOT_DISABLED; do say "- \`$p\`"; done
    fi
    if [ -n "$BUILTIN" ]; then
        say ""
        say "<details><summary>源码里没有对应包、但符号仍被要求（多半是内核已内建，可忽略）</summary>"
        say ""
        for p in $BUILTIN; do say "- \`$p\`"; done
        say ""
        say "</details>"
    fi
    if [ "$STRICT" = "true" ] && [ -n "$MISSING" ]; then
        echo "::error::有选项被丢弃，按 STRICT=true 中止编译"
        exit 1
    fi
fi

if [ -n "$SUMMARY" ]; then
    cat "$REPORT" >>"$SUMMARY"
    printf '\n' >>"$SUMMARY"
fi
rm -f "$REPORT"
exit 0
