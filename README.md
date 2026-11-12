# Actions-OpenWrt · 个人云编译仓库

用 GitHub Actions 编译 **coolsnowwolf/lede** 固件，默认目标是 **x86_64 generic**（PVE 虚拟机 / 软路由）。
日常只需要改 `config/packages.txt` 这一个文件。

首次构建约 1h50m；开启 ccache 后，第二次起通常 40–70 分钟。

---

## 1. 只改这几个地方

| 路径 | 作用 | 什么时候改 |
|---|---|---|
| `config/packages.txt` | 插件清单，一行一个包名，`!` 开头 = 显式关闭 | **加 / 删插件（90% 的改动）** |
| `config/feeds.txt` | 额外 feed（含 iStore 这种非标准布局） | 包找不到、要换源时 |
| `config/base.config` | 机型、分区大小、镜像格式、ccache | 换设备、改磁盘大小 |
| `config/extra.config` | 其它零散 `CONFIG_*`（默认全注释 = 不改） | 关 IPv6、换主题、砍体积 |
| `diy-part1.sh` | 读取 `config/feeds.txt`、摊平非标准 feed | 一般不用动（改 feeds.txt 就够） |
| `diy-part2.sh` | feeds install **之后**：默认 IP / 主机名 / 时区 | 改固件出厂默认值 |
| `scripts/gen-config.sh` | 把上面三份配置拼成 `openwrt/.config` | 一般不用动 |
| `scripts/check-packages.sh` | 编译前预检 + defconfig 后对账 | 一般不用动 |
| `.github/workflows/openwrt-builder.yml` | 流水线本体 | 一般不用动 |

`openwrt/.config` **不再入库**：它由 `scripts/gen-config.sh` 在 CI 里现场生成，
仓库里那三份配置才是唯一真相，不存在「改错了文件」这种事。

> 上一版仓库的体检报告在 [REVIEW.md](REVIEW.md)，这一版改了什么、和别的仓库比差在哪，见 [UPGRADE.md](UPGRADE.md)。

---

## 2. 怎么跑

**Actions → OpenWrt Builder → Run workflow。**

运行参数（不改文件也能改行为）：

| 输入 | 说明 |
|---|---|
| `source_repo` | 换源码仓库，留空 = lede |
| `source_branch` | 分支或 tag，留空 = master。填 tag 可锁定上游版本 |
| `extra_packages` | 本次临时加包，空格分隔，如 `luci-app-ttyd !luci-app-wol` |
| `lan_ip` | 路由器管理地址，留空 = `192.168.0.2`（参考 [ImmortalWrt-ImageBuilder](https://github.com/qoolies/ImmortalWrt-ImageBuilder) 的做法：运行参数直接问卷式传入） |
| `hostname` | 主机名，留空 = `MyRouter` |
| `rootfs_mb` | 根分区大小，1024/2048/3072/4096，覆盖 `config/base.config` 里的 2048 |
| `preset_openclash` | 预置 OpenClash 内核 + GeoIP/GeoSite（默认是；选了 openclash 才有意义） |
| `release` | 构建成功后发 Release（默认否） |
| `use_ccache` | 使用 ccache（默认是） |
| `debug_ssh` | 失败时开 tmate SSH 进运行环境（默认否，会挂起 30 分钟） |

想让它每 3 天自动跟着上游编译：打开 `.github/workflows/update-checker.yml` 里的 `schedule` 注释。

---

## 3. 每次跑完，看 Summary 而不是只看红绿

运行页面的 **Summary** 从上到下依次是：

1. **本次构建参数** —— 源码/分支/临时加包/ccache 是否开启
2. **配置生成** —— 启用几个包、关掉几个包
3. **包存在性预检** —— ⚠️ 这是新增的关键一步：**编译前 5 秒**告诉你哪些包在 feed 里根本不存在（包名写错、feed 没加、分支已移除）。这种包不会让编译失败，只会「绿勾但固件里没有」
4. **make defconfig 警告 + 配置解析对账** —— 源码里有、但 `defconfig` 没选中的包（通常是依赖不满足）
5. **镜像产物 + 对账** —— 逐个检查你请求的包是否真的出现在 `bin/targets` 的包清单里（`bin/packages` 只是编译产物，不代表被装进镜像）

失败时会额外出现 **失败定位** 块：摘录最后的报错行和涉及的包目录，并直接给出处理建议。

---

## 4. 常用配方

### 加一个插件

```text
# config/packages.txt
luci-app-diskman
```

前提是该包在某个已启用的 feed 里（lede 默认有 packages / luci / routing / telephony / helloworld / video）。
包名不知道？看 `feeds/luci/applications/` 下的目录名，或直接跑一次，预检会告诉你有没有。

### 删掉一个默认插件

lede 的 `DEFAULT_PACKAGES.router` 默认会编进十几个 luci 应用（ddns、upnp、autoreboot、nlbwmon、turboacc…）。
想关掉就在 `packages.txt` 里加一行 `!包名`：

```text
!luci-app-ssr-plus
!luci-app-nlbwmon
```

### 换机型

改 `config/base.config` 顶部三行（目标平台那一段），例如 ARM 软路由：

```text
CONFIG_TARGET_rockchip=y
CONFIG_TARGET_rockchip_armv8=y
CONFIG_TARGET_rockchip_armv8_DEVICE_r2s=y
```

机型符号不熟时，在本地 `make menuconfig` 选好后 `grep '^CONFIG_TARGET' .config` 抄过来即可。

### 改 LAN IP / 主机名 / 时区

`diy-part2.sh` 顶部三个变量：

```sh
LAN_IP="${LAN_IP:-192.168.0.2}"
ROUTER_HOSTNAME="${ROUTER_HOSTNAME:-MyRouter}"
ROUTER_TIMEZONE="${ROUTER_TIMEZONE:-CST-8}"
```

这些是「出厂默认值」，刷机后仍然可以在 LuCI 里改。
上游换路径或换写法时脚本会打印 `::warning::` 跳过，不会静默失效。

### 加第三方 feed

`config/feeds.txt` 里取消注释一行即可：

```text
passwall  https://github.com/xiaorouji/openwrt-passwall
```

加完把包名写进 `config/packages.txt`。重复执行安全（同名 feed 只更新 URL）。

"包找不到"时的判断顺序：
1. 名字拼错了？预检会给近似名
2. 包在别的仓库？→ 上面这样加 feed
3. 该分支确实移除了（`luci-app-turboacc` 就是这样消失的，等价功能见「网络加速」一节）→ 删掉这一行

### OpenClash 要内核，包本身不带

`luci-app-openclash` 是个纯 LuCI 包：**没有内核、没有 GeoIP/GeoSite**。只把包编进去，
刷完机能打开页面但启动不了（提示未检测到内核），得手动点一次「下载内核」。

所以 `preset_openclash: true`（默认）时，编译期会跑 `scripts/preset-openclash.sh`：

| 预置文件 | 来源 | 大小 |
|---|---|---|
| `/etc/openclash/core/clash_meta` | [vernesong/OpenClash](https://github.com/vernesong/OpenClash) `core` 分支的 `meta/clash-linux-amd64-v1.tar.gz` | ~16 MB |
| `/etc/openclash/GeoIP.dat`、`GeoSite.dat` | [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) 最新 release | ~27 MB |

要点：用 `v1`（基线 x86-64 指令集）而不是 `v2/v3`，老 CPU 上不会 `Illegal instruction`；
下载失败**不会**让编译失败，只在 annotation 里 `::warning::`，固件照出、内核留给你手点。
换 ARM 机型时把脚本里的 `OPENCLASH_ARCH` 改成 `arm64`。

### 和 ImmortalWrt-ImageBuilder 仓库怎么分工

| | 本仓库（从源码编译） | [ImmortalWrt-ImageBuilder](https://github.com/qoolies/ImmortalWrt-ImageBuilder) |
|---|---|---|
| 做法 | clone 源码 → feeds → `make` 全量编译 | 官方 `imagebuilder` 镜像 + `make image` 装现成 ipk/apk |
| 耗时 | 1.5 小时左右 | 10–20 分钟 |
| 能改 | 源码、内核、任何包 | 只能挑包、塞文件 |
| 适合 | 要改源码/内核、要精确控制 `.config` | 只是想换插件组合、快速出固件 |

两边可以共用一套「运行参数」的思路：管理地址、主机名、根分区、预装软件都做成
`workflow_dispatch` 输入，而不是每次改文件。区别是 ImageBuilder 那边把值写成
`files/etc/config/*.txt` 交给首启脚本读，本仓库一部分在源码层改（`diy-part2.sh`），
一部分在首启脚本兜底（`files/etc/uci-defaults/99-custom`）。

### 装 iStore 应用商店

iStore 的仓库不是标准 feed 布局（包埋在 `luci/` 子目录），用 `flatten=` 让它摊平：

```text
istore  https://github.com/istoreos/istore.git flatten=luci
```

然后 `config/packages.txt` 里启用 `luci-app-store`。

### 强制用外部源的版本（覆盖默认源）

`feeds install -a` 是**先到先得**：`feeds.conf` 里靠前的 feed 优先，核心包（`package/`）又高于所有 feed。
额外 feed 是追加在最后的，所以**默认源永远赢** —— 这是特性，不是 bug。

想要外部源的版本生效（比如你 fork 了某个包修了个 bug），在 `diy-part2.sh` 里写两行：

```sh
./scripts/feeds uninstall luci-app-passwall       # 删掉默认源那份
./scripts/feeds install -p small luci-app-passwall  # 从 small 源装
```

注意 `uninstall` 会触发一次 `make prepare-tmpinfo`，整体多花 10–25 秒。
预检的「包的来源」表会告诉你到底生效的是哪一个 —— 加源没生效时这里一眼看得出来。

### 换源码仓库（官方 OpenWrt / ImmortalWrt）

先不改文件试跑：Run workflow 时填 `source_repo` + `source_branch`，例如

| 目标 | source_repo | source_branch |
|---|---|---|
| lede（当前） | `https://github.com/coolsnowwolf/lede` | `master` |
| 官方 OpenWrt | `https://github.com/openwrt/openwrt` | `openwrt-25.12` |
| ImmortalWrt | `https://github.com/immortalwrt/immortalwrt` | `openwrt-25.12` |

预检报告第一行会写「源码：xxx @ xxx」，确认没跑偏；确认 OK 后再把 workflow 里的
`DEFAULT_REPO` / `DEFAULT_BRANCH` 改掉固化。

换源码要重新核对的东西（以 ImmortalWrt 25.12 为例，2026-11 实测链接）：

| 项 | 结论 |
|---|---|
| `luci-app-openclash`、`luci-app-adguardhome` | ✅ [immortalwrt/luci](https://github.com/immortalwrt/luci/tree/master/applications) 里都有 |
| `adguardhome` 本体 | ✅ [immortalwrt/packages](https://github.com/immortalwrt/packages/tree/master/net/adguardhome) 里有 |
| `luci-app-ssr-plus` | ❌ 没有（lede 的 helloworld feed 特有）→ 把 `packages.txt` 里 `!luci-app-ssr-plus` 删掉即可 |
| feeds | 各家自带 `feeds.conf.default`（ImmortalWrt 的 packages/luci 是自家 fork），我们仓库没有覆盖文件，会自动用它的 |
| 机型符号 | x86_64 generic 基本一致，第一次跑完在「最终生效的关键项」里确认 |
| 默认主机名 | lede 是 `LEDE`、ImmortalWrt 是 `ImmortalWrt`，`diy-part2.sh` 已三个都试 |

### 不要把另一个发行版当 feed 加进来

`feeds install -a` 是先到先得：重叠的包全被 lede 抢先，**加了等于没加**；
只有 lede 没有的包会被装进来，而它们依赖的 `luci-lib-*` / `ucode-mod-*`
往往在 lede 这边不存在，结果要么编译失败、要么被 defconfig 静默丢弃。
**要换发行版就换源码仓库，别混 feed。**

### 砍体积

- 小的：`config/extra.config` 里关掉用不上的默认包（vsftpd / vlmcsd / nlbwmon / wol …）
- 大的：`diy-part2.sh` 里直接 `rm -rf` 掉整个包目录（比在 .config 里关更快、不会有残留依赖）
- 更彻底：`config/base.config` 里把 `CONFIG_TARGET_ROOTFS_PARTSIZE` 从 2048 降到 1024

### 网络加速（老 TurboACC 的那几项）

上游 2026-10-29 把 `luci-app-turboacc` 从 `luci@openwrt-25.12` 删了，全锥形 NAT、
TCP 拥塞控制、流量卸载全部搬进 **LuCI → 网络 → 防火墙 → 常规设置**。
页面上那些开关只有在固件带对应内核模块时才显示（LuCI 靠 `/sys/module/<名字>` 探测），
所以要在 `config/packages.txt` 里确保这三行：

| 页面选项 | 包 |
|---|---|
| 启用 FullCone NAT（FULLCONENAT / Broadcom Fullcone NAT1） | `kmod-nft-fullcone` |
| 流量卸载 → 软件流量卸载 | `kmod-nft-offload` |
| TCP CCA → bbr | `kmod-tcp-bbr` |

默认值由 `files/etc/uci-defaults/99-turboacc` 在首次启动时写入
（`fullcone=1`、`flow_offloading=1`、`tcpcca=bbr`、`fullcone6=0`、硬件卸载关 —— x86 没有卸载单元）。
刷机后想改回 cubic、或者关掉全锥，直接在防火墙页面上改即可，不会被覆盖。

**不要**为了那个独立页面去加第三方 turboacc 仓库：它们要往 `target/linux/generic/hack-*`
里塞内核补丁、还要改 `nftables` / `libnftnl` / `firewall4` 的源码包，
内核一改 ccache 也就废了，收益只是「界面上多一个页面」。

### 锁定上游版本（防「今天能过明天过不了」）

lede master 每天在变。要稳定就钉版本：

- 懒人版：`source_branch` 输入框填一个 tag
- 彻底版：把 `.github/workflows/openwrt-builder.yml` 里 `DEFAULT_BRANCH` 改成某个 commit 或 tag

### 发布 Release

运行时把 `release` 勾上。产物会进一条 release，正文自动写好上游 commit、插件清单、镜像大小；
旧 release 自动保留最近 3 个（`KEEP_RELEASES`）。

### 编译失败怎么办

1. 看 Summary 的 **失败定位**：里面已经摘出了报错行和包目录
2. 九成情况是**上游某个包自己编不过**，和你的配置无关。把它的名字写进 `packages.txt` 并加 `!` 前缀，重跑即可出固件
3. 下载 artifact `build-logs*`，里面有完整 `build.log`、`defconfig.log` 和最终 `.config`
4. 想进容器手动查：勾 `debug_ssh` 重跑，失败后会输出 SSH 地址（默认挂 30 分钟）

---

## 5. 冷知识（踩过的坑）

- **`.config` 的 `=y` 行可以带行尾注释**（Kconfig 只看第一个字符），但**数字/字符串行不行**（整串校验，会被判非法丢弃）。所以本仓库把说明都单独写成一行。
- **`make defconfig` 遇到不认识的 `CONFIG_` 符号不报错，直接跳过**，这就是「绿勾但没插件」的根源 —— 预检步骤专治这个。
- **`feeds.conf.default` 写错会在 `Update feeds` 一秒内失败**。格式是 `src-git <名字> <URL>[;<分支>]`。
- **`bin/packages` 不等于装了包**：那只是编译出来的 ipk/apk；判断有没有进固件只看 `bin/targets` 下的清单。
- **lede 默认主机名是 `LEDE`，不是 `OpenWrt`**，默认时区是 `GMT0`/`UTC`。
- **ccache 目录不能随便放**：lede 的 `rules.mk` 里是无条件 `export CCACHE_DIR=$(TOPDIR)/.ccache`，
  环境变量会被它覆盖。所以缓存必须放在 `openwrt/.ccache`，放别处就是"配了但每次都全量编译"。
- **同名包不会互相打架**：`feeds install -a` 是先到先得，`feeds.conf` 里靠前的 feed 优先，
  核心包（`package/`）又高于所有 feed。额外 feed 追加在最后，所以默认源天然优先；
  预检的「包的来源」表会列出每个包最终来自哪个源。
- 当前 lede 的 luci feed 锁在 **openwrt-25.12** 分支：`luci-app-turboacc`、`luci-app-accesscontrol` 在该分支已被移除；
  加速类功能已并入防火墙页面（见「网络加速」一节），不要再去找 `luci-app-turboacc`。
- **lede 的 `DEFAULT_PACKAGES.router` 里还写着 `luci-app-turboacc`、`luci-app-ssr-plus`**，
  但这两个包在 luci@25.12 分支已经不存在了，所以是被**静默丢弃**的（不是你漏关）。
  想知道某个默认包到底有没有进镜像，看 Summary 最后的对账报告，别猜。
- **iStore 不是 lede 的默认包**（`DEFAULT_PACKAGES.router` 里没有 `luci-app-store`）。
  本仓库在 `packages.txt` 里显式写了 `!luci-app-store` 做保险；真要用就临时勾
  `extra_packages` 填 `luci-app-store`，或者按「装 iStore」那节加 feed。
- **feed 里的包目录是符号链接**：`find package -type d` 看不到它们，脚本里必须用 `find -L`，
  否则「明明装好的包」会被报成找不到。
