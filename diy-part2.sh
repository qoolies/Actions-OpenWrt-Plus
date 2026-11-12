#!/usr/bin/env bash
#
# File: diy-part2.sh
# Description: feeds install 之后、make defconfig 之前执行；工作目录 = openwrt/
#
# 这里做「改源码」类的小动作：默认 IP、主机名、时区…
# 每个动作都带存在性保护 —— 上游改了路径或换了默认值，就打印 WARN 跳过，而不是静默失效。
#
set -euo pipefail

# ---------- 想改的值都放这里 ----------
LAN_IP="${LAN_IP:-192.168.0.2}"
ROUTER_HOSTNAME="${ROUTER_HOSTNAME:-MyRouter}"
# lede 默认 timezone='GMT0' / zonename='UTC'，北京时间对应下面这一对
ROUTER_TIMEZONE="${ROUTER_TIMEZONE:-CST-8}"
ROUTER_ZONENAME="${ROUTER_ZONENAME:-Asia/Shanghai}"

# replace_any <文件> <新值串> <说明> <候选旧值1> [候选旧值2 ...]
# 命中第一个就替换并停止；一个都没命中才警告一次（避免刷一屏黄条）
replace_any() {
    local f="$1" new="$2" desc="$3"
    shift 3
    if [ ! -f "$f" ]; then
        echo "::warning::$f 不存在，跳过：$desc（上游可能改了路径）"
        return 0
    fi
    local o
    for o in "$@"; do
        if grep -qF -- "$o" "$f"; then
            sed -i "s|${o}|${new}|g" "$f"
            echo "  ✔ $desc（原值 ${o}）"
            return 0
        fi
    done
    echo "::warning::$f 里找不到「$*」，跳过：$desc"
}

GEN=package/base-files/files/bin/config_generate

# ---------- 默认 LAN IP ----------
replace_any "$GEN" "$LAN_IP" "默认 LAN IP" '192.168.1.1'

# ---------- 默认主机名 ----------
# 不同源码默认值不同：lede=LEDE、官方 openwrt=OpenWrt、ImmortalWrt=ImmortalWrt
replace_any "$GEN" "hostname='${ROUTER_HOSTNAME}'" "默认主机名" \
    "hostname='LEDE'" "hostname='OpenWrt'" "hostname='ImmortalWrt'"

# ---------- 默认时区 ----------
replace_any "$GEN" "timezone='${ROUTER_TIMEZONE}'" "默认时区" "timezone='GMT0'"
replace_any "$GEN" "zonename='${ROUTER_ZONENAME}'" "默认时区名" "zonename='UTC'"

# ---------- 其它常用动作（按需取消注释）----------
#
# 默认主题换成 argon（前提：config/packages.txt 里有 luci-theme-argon）
# replace_any feeds/luci/collections/luci/Makefile 'luci-theme-argon' "默认主题 → argon" 'luci-theme-bootstrap'
#
# 强制用外部源的版本（详见 README「强制用外部源的版本」）
# ./scripts/feeds uninstall luci-app-passwall
# ./scripts/feeds install -p small luci-app-passwall
#
# 精简固件体积：直接删掉不要的包目录（比在 .config 里关更快更干净）
# rm -rf feeds/luci/applications/luci-app-nlbwmon
# rm -rf feeds/luci/applications/luci-app-vlmcsd
#
# 打补丁：把 .patch 放进 patch/ 目录，然后在这里 apply
# patch -p1 < "$GITHUB_WORKSPACE/patches/01-foo.patch"

# ---------- 把这次的默认值交给开机脚本 ----------
# 上面改的是「源码里的默认值」，开机脚本改的是「已经生成好的 uci 配置」。
# 两者配合：万一下次上游改了写法、上面某步 WARN 跳过，开机脚本仍然兜得住。
SETTINGS_DIR="files/etc/config"
mkdir -p "$SETTINGS_DIR"
cat >"$SETTINGS_DIR/edge-settings" <<EOF
LAN_IP='$LAN_IP'
ROUTER_HOSTNAME='$ROUTER_HOSTNAME'
ROUTER_TIMEZONE='$ROUTER_TIMEZONE'
ROUTER_ZONENAME='$ROUTER_ZONENAME'
EOF
echo "  ✔ 已写入 $SETTINGS_DIR/edge-settings（供 /etc/uci-defaults/99-custom 使用）"

echo "=== diy-part2.sh 完成 ==="
