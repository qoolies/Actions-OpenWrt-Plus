# 与上游 / 同类仓库对比后改了什么

上一版仓库的运行流程是对的（#5 全绿），问题全在**可维护性**和**可观测性**上：
配置散落、改错没提示、出问题只能翻 1.7 小时日志、部分 action 已停更。

本文记录这次的对照与取舍。使用手册见 [README.md](README.md)，上一版体检见 [REVIEW.md](REVIEW.md)。

---

## 1. 对比了哪些仓库

| 仓库 | 它做对的事 | 我们采纳的部分 |
|---|---|---|
| [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)（本仓库源头） | 流程编排最干净的模板：clone → feeds → .config → download → make → artifact | 保留整体骨架与 `UPLOAD_*` 语义；但它的 action **至今仍是 `@main` 不锁版本**（`actions/checkout@main`、`upload-artifact@main`），且 `UPLOAD_RELEASE` 默认 `true` |
| [ophub/amlogic-s9xxx-openwrt](https://github.com/ophub/amlogic-s9xxx-openwrt) | ① `workflow_dispatch` 输入驱动（板子/内核/IP/ccache 都在界面上选）② 按源码分支分目录放配置 `config/<branch>/{config,feeds.conf.default,diy-part*.sh}` ③ ccache 缓存 key 绑**上游 commit** ④ 虚拟磁盘扩容 ⑤ 用 `github.event.repository.owner.id == sender.id` 限制谁都能触发 | 全部采纳（虚拟磁盘除外，x86 镜像用不到那么大盘） |
| [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede) | 上游源码、`scripts/config/confdata.c`（判断 `.config` 写法是否合法） | 结论写进了 `config/base.config` 的注释里 |
| GitHub 官方 action 仓库 | `ubuntu-22.04` 弃用时间表 | 见下方「风险」 |

关键事实（本次核对时间 2026-11-11）：

- `ubuntu-22.04` 自 **2026-09-17** 起进入弃用期、**2027-04-17** 下线，中间还有 brownout 会直接让任务失败 —— [actions/runner-images#14254](https://github.com/actions/runner-images/issues/14254)
- 各 action 当前主流版本：[upload-artifact v7.0.2](https://github.com/actions/upload-artifact/releases/tag/v7.0.2)、[checkout v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1)、[cache v6.1.0](https://github.com/actions/cache/releases/tag/v6.1.0)、[action-gh-release v3.0.4](https://github.com/softprops/action-gh-release/releases/tag/v3.0.4)、[repository-dispatch v4.0.1](https://github.com/peter-evans/repository-dispatch/releases/tag/v4.0.1)

---

## 2. 具体改了什么

### 2.1 配置分层：`.config` 拆成三份，日常只改 `packages.txt`

旧版是一个 56 行、带大量注释的 `.config`，加个插件要记住 `CONFIG_PACKAGE_` 前缀和命名规则，
还得自己保证数字行不带行尾注释。

现在：

```text
config/base.config   机型 / 分区 / 镜像格式 / ccache     ← 很少动
config/packages.txt  插件清单，一行一个包，! 前缀=关闭    ← 日常只动这里
config/extra.config  其它任意 CONFIG_*（默认全注释）      ← 逃生口
        ↓ scripts/gen-config.sh
openwrt/.config      现场生成，不入库（没有第二份真相）
```

`packages.txt` 支持两种写法，比 Kconfig 语法直观：

```text
luci-app-openclash          # 启用
!luci-app-ssr-plus          # 显式关闭
```

好处：改包不再需要懂 Kconfig；`.config` 里的注释、行尾注释陷阱全部由脚本负责；
`config/` 整个目录可以原样 copy 到另一个 fork 复用。

### 2.2 编译前 5 秒的「包存在性预检」（旧版没有的能力）

旧版的核对发生在 `make defconfig` **之后**，只能发现「源码里有但没被选中」。
真正的主要坑是**源码里根本没有这个包名**（feed 没加、分支移除、名字拼错），这种包
连警告都不打，直接跳过 —— 上一版体检报告里 3 个插件里有 1 个就是这么消失的。

`scripts/check-packages.sh pre` 在 feeds install 完、编译开始前扫源码树：

- 包目录存在？→ OK
- `kmod-*` 在 `package/kernel` 的 `define KernelPackage/` 里？→ OK；都没有 → 标「可能已内建」
- 其余 → 进「找不到」列表 + `::warning::`

`scripts/check-packages.sh post` 仍然做 `defconfig` 对账，并且会区分
「源码里有、但没被选中（真丢包）」和「源码里没有（内建/不存在）」，不再混为一谈。

把 `STRICT` 改成 `"true"`，任何一项不合预期都直接失败，而不是黄字警告。

### 2.3 ccache：第二次构建起明显变快（第一版接了但没生效，已修）

> 实测教训：第一版的缓存路径写成 `/workdir/.ccache`，结果 `actions/caches` 里
> `total_count: 0` —— 一个字节都没存。原因见下，已在 v2 修正。

- lede 的 `rules.mk` 里是**无条件赋值**：`export CCACHE_DIR:=$(TOPDIR)/.ccache`，
  所以环境变量里的 `CCACHE_DIR` 会被覆盖，缓存必须放在 `openwrt/.ccache`
- `CCACHE_NOCOMPRESS:=true` 由 rules.mk 强制，缓存不压缩，全量约 3–5 GB
- key = `ccache-<分支>-<上游commit>-<run_id>`，`restore-keys` 先回退到同 commit、再回退到同分支
- 上限 3G（`CCACHE_MAXSIZE`）
- Summary 里新增 ccache 命中率/体积，命中率为 0 或体积为 0 就说明没接上

### 2.3.1 额外 feed 改成声明式（`config/feeds.txt`）

原来要在 `diy-part1.sh` 里改 shell；现在加源只是往 `config/feeds.txt` 写一行，
支持 `flatten=子目录`（iStore 那类非标准布局）和第三列当分支。

这样「只改了两三个包」的重编不会从零开始；源码没变时命中率最高。

### 2.4 运行参数上界面：不改文件也能改行为

`workflow_dispatch` 新增 6 个输入：`source_repo`、`source_branch`、`extra_packages`、
`release`、`use_ccache`、`debug_ssh`。

`extra_packages` 尤其顺手：临时想试 `luci-app-ttyd`，不用改文件、不用开 PR，
填 `luci-app-ttyd` 直接跑；想临时关掉某个包就填 `!luci-app-wol`。

### 2.5 版本与依赖维护

| 项 | 旧版 | 现在 |
|---|---|---|
| `actions/checkout` | `@v4` | `@v7` |
| `actions/upload-artifact` | `@v4` | `@v7` |
| `actions/cache` | `@v4`（update-checker 里是 v3，已停服） | `@v6` |
| `softprops/action-gh-release` | `@v2` | `@v3` |
| `peter-evans/repository-dispatch` | `@v3` | `@v4` |
| 删除旧运行 / 旧 release | `Mattraks/delete-workflow-runs@main`、`dev-drprasad/delete-older-releases@master`（两个都已停更、且不锁版本） | 改用 runner 自带的 `gh api`，零第三方依赖 |
| apt 包列表 | 硬编码，换 runner 版本就有一堆装不上 | 先 `apt-cache show` 探测再装，`24.04/26.04` 直接可用；`libncurses5-dev` 自动换 `libncurses-dev` |
| clone | 全量 | `--depth 1`（20s → 5s） |

### 2.6 失败后能自己说清原因

旧版：编译失败 → 上传 `.config` 和 `logs/`，然后自己去几千行日志里找。

现在：

- 编译日志 `tee` 到 `/tmp/build.log`
- 失败时 Summary 自动摘录**最后的报错行** + **最后涉及的 `package/...` 目录**
- 并给出可直接执行的处理建议（把该包 `!` 掉再跑）
- 需要人工进容器时勾 `debug_ssh`，tmate 直接给 SSH 地址

### 2.8 网络加速（老 TurboACC）：上游没了页面，功能还在

上游 2026-10-29 把 `luci-app-turboacc` 从 `luci@openwrt-25.12` 移除，全锥形 NAT、
TCP 拥塞控制、流量卸载都并进了 **LuCI → 网络 → 防火墙 → 常规设置**。
页面上那几项只有在固件带对应内核模块时才显示（LuCI 的 `getFeatures` 靠
`/sys/module/<名字>` 探测）：

| 页面选项 | 需要的包 | 上游在 25.12 里有吗 |
|---|---|---|
| 启用 FullCone NAT（FULLCONENAT / Broadcom Fullcone NAT1） | `kmod-nft-fullcone` | ✅ `package/network/services/fullconenat-nft` |
| 流量卸载 → 软件流量卸载 | `kmod-nft-offload` | ✅ `package/kernel/linux` |
| TCP CCA → bbr | `kmod-tcp-bbr` | ✅ `package/kernel/linux` |

所以「TurboACC 编不进去」这件事的正确解法**不是**去第三方仓库打内核补丁，
只要把这三个 `kmod-*` 写进 `config/packages.txt`，再用
`files/etc/uci-defaults/99-turboacc` 把默认值设好（全锥 + 软件卸载 + bbr）。
真想要那个独立页面，才需要 [mufeng05/turboacc](https://github.com/mufeng05/turboacc)
那种带内核补丁的仓库，风险见 README。

### 2.9 预检的假阳性：feed 包被误报「找不到」

`feeds install` 装进 `package/feeds/<feed>/<包>` 的是**符号链接**，
`find -type d` 默认不跟随符号链接 → `luci-app-openclash`、`luci-app-adguardhome`、
`adguardhome` 全被误报成「源码树里找不到」。已改成 `find -L`，并加了 feed 索引兜底；
`kmod_names()` 也从只扫 `package/kernel` 改成扫整棵 `package/`（`kmod-nft-fullcone`
这种定义在 `package/network/services/fullconenat-nft` 里）。

### 2.10 ccache 改成「可观测」

缓存到底有没有生效，从 Actions 日志里看不出来（日志要登录）。现在：

- `actions/cache` 拆成 `restore` + `save` 两步，保存时机确定
- 编译后自动自检，结果直接进 annotation：
  `::warning::.config 里没有 CONFIG_CCACHE=y` / `::warning::.ccache 是空的` /
  `::notice::ccache 生效：目录 1.8G`
- Summary 里同时有一张 ccache 自检表

### 2.11 OpenClash 补内核，运行参数补三个输入

对照 [ImmortalWrt-ImageBuilder](https://github.com/qoolies/ImmortalWrt-ImageBuilder)
（同一个人的 ImageBuilder 版仓库）补的几处：

1. **OpenClash 内核预置**（`scripts/preset-openclash.sh`）：这个包不含内核也不含
   GeoIP/GeoSite，光编进去等于装了个壳。现在编译期下好
   `clash_meta`（`v1` 基线指令集，老 CPU 不会 Illegal instruction）+ GeoIP/GeoSite，
   塞进 `/etc/openclash/`，刷完即用。下载失败只 `::warning::`，不阻塞编译。
2. **运行参数变多**：`lan_ip`、`hostname`、`rootfs_mb`（1024–4096）、`preset_openclash`。
   管理地址/主机名留空就用 `diy-part2.sh` 里的默认值；根分区覆盖走
   `scripts/gen-config.sh`，不动 `config/base.config`。
3. **首启脚本 `files/etc/uci-defaults/99-custom`**：主机名/时区兜底（源码层改失败也生效）、
   SSH 与网页终端放开到所有网口、装了 docker 就补 firewall zone、固件描述打标记。
   `diy-part2.sh` 会把这次的默认值写成 `/etc/config/edge-settings` 交给它读。

### 2.12 其它小修

- `diy-part1.sh`：`add_feed` / `add_flat_feed` 两个幂等函数，重复执行不会把 feed 写两遍；
  iStore 摊平从「一次性命令」变成「取消注释一行」
- `diy-part2.sh`：每个替换都带存在性保护，上游改路径时打印 `::warning::` 而不是静默失败；
  默认主机名按 lede 的 `LEDE`（旧版按 `OpenWrt` 写，实际匹配不到）
- 默认时区从 `GMT0/UTC` 改成 `CST-8/Asia/Shanghai`
- `concurrency` + `timeout-minutes: 350`：不会出现两个构建排队烧 4 小时
- artifact 保留 14 天、失败日志保留 5 天
- 运行/Release 清理保留数量可配（`KEEP_RUNS` / `KEEP_RELEASES`）

### 2.13 第一轮真机构建（run 43147063312）暴露的问题

2026-11-12 用这套配置真的编了一轮，**成功**，1h46m（下载 13m + 编译 87m）。
annotations 只报了两条，一条是好的、一条是 bug：

| annotation | 判定 | 处理 |
|---|---|---|
| `::warning::.config 里没有 CONFIG_CCACHE=y` | **真 bug**：87 分钟编译全程没吃到缓存 | 见下 |
| `::notice::OpenClash 内核已预置（amd64）` | 正常，内核 + GeoIP/GeoSite 都已进固件 | 不用管 |

**ccache 为什么写了 `CONFIG_CCACHE=y` 还是没生效**：lede 的 `config/Config-devel.in` 里是

```text
config CCACHE
	bool "Use ccache" if DEVEL
```

`if DEVEL` 的意思是「DEVEL 打开时这个选项才可见」。Kconfig 对**不可见符号**的处理是
直接忽略并回落到默认值，于是 `make defconfig` 把 `CONFIG_CCACHE=y` 整行抹掉了 ——
`rules.mk` 里 `ifneq ($(CONFIG_CCACHE),)` 那段（`TARGET_CC := ccache $(TARGET_CC)`）自然没进，
编译全量、`.ccache` 空、`Save ccache` 被条件跳过。修法是 `config/base.config` 里
`CONFIG_DEVEL=y` + `CONFIG_CCACHE=y` 成对写（DEVEL 只影响菜单可见性，不改别的默认值）。

顺带按这一轮的实际数据做的几处调整：

1. **ccache 自检升级**：不再只看"目录非空"，改用 `ccache --print-stats` 报**命中率**
   （`::notice::ccache 生效：缓存 3G，本次命中 1234 次 / 未命中 56 次（命中率 96%）`）。
   命中率是唯一能证明缓存真的接上的数字。
2. **新增 `source_commit` 输入**：把「已经刷过、确认能用」的那个上游 commit 钉住。
   以前只能钉 tag，而 tag 不一定有；现在填 SHA 即可重现同一份固件。
   填错会在 clone 阶段 10 秒内报错，不浪费一次 90 分钟。
3. **`release` 输入保留但默认仍是 false**：勾上才发 Release（artifact 14 天过期、下载要登录、
   还是 zip 套娃；Release 里是直接的 `.img.gz`）。默认不发，避免每轮都自动建 Release。
4. **并行度**：`make download -j8 → -j16`（这一步纯 IO，实测 13 分钟）；
   `make -j$(nproc) → -j$(nproc+1)`（编译里总有等 IO/flock 的空档）。
5. **Summary 增列** `CONFIG_DEVEL` / `CONFIG_CCACHE` 两个生效值，一眼能看出缓存有没有接上。

> 注意：这一轮没吃到缓存，所以**下一轮仍然是全量编译**（第一次会把缓存建起来），
> 再下一轮才会明显变快。这是 ccache 的正常节奏，不是配置问题。

**止损规则（已定，不再反复试）**：下一轮跑完只看一条判据 —— annotation 里有没有
`::notice::ccache 生效：… 命中率 X%` 且 `X` 不为 0。

- 有 → 收工，以后不用管这件事。
- 没有（还是 `::warning::.config 里没有 CONFIG_CCACHE=y` 或命中率 0）→ **把 ccache 整套删掉**，
  别再来回折腾。要删的东西：workflow 里 `Restore ccache` / `Report ccache stats` /
  `Check ccache is really used` / `Save ccache` 四个 step、`use_ccache` 输入、
  `Resolve parameters` 里的 `USE_CCACHE`，以及 `config/base.config` 里的
  `CONFIG_DEVEL=y` + `CONFIG_CCACHE=y` 和 `env.CCACHE_DIR` / `CCACHE_MAXSIZE`。
  删完就是「每轮全量编译 1h46m」，功能不受任何影响。

---

## 3. 迁移步骤

工作目录里已经是改好的版本，覆盖到 fork 后：

```bash
git rm .config                      # 旧的 .config 不再入库（内容已拆进 config/）
git add -A
git commit -m "refactor: 配置分层 + 编译前预检 + ccache + action 升级"
git push origin main
```

然后 Actions → OpenWrt Builder → Run workflow，第一次跑会新建 ccache（仍然全量编译），
第二次起才会快。

**回滚**：`git revert` 那一个 commit 即可，旧的 `.config` + 旧 workflow 是自洽的，
不依赖任何新增文件。

---

## 4. 仍存在的风险（不是这次能彻底解决的)

1. **`ubuntu-22.04` 会下线**（2027-04-17）。目前它还是最能编译 lede 的环境，所以默认不变；
   想提前迁到 `ubuntu-24.04`，把 `runs-on` 改一行即可，apt 列表会自动适配。若遇到某些包在新
   glibc/gcc 下编不过，就是上游包的问题，先 `!` 掉再等上游修。
2. **lede master 天天变**。要稳定就钉 tag 或 commit（见 README「锁定上游版本」）。
3. **ccache 占缓存配额**：GitHub 每仓库默认 10GB，这里设 3G 上限；如果同时还有别的仓库在用缓存，
   可能会被 LRU 顶掉，表现为「这次又变慢了」，不影响正确性。
4. **包名本身是外部事实**：feed 里有没有某个包、哪天被移除，脚本只能**报告**，不能替你解决。
   预检的价值就在于让这件事在 5 秒内可见，而不是 1.7 小时后才知道。
