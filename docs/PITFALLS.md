# 已知坑与实测记录

这里记录设计依据、真实遇到的故障，以及**没有被证实**的推断。不要把推断当结论。

## 1. 官方不支持 23 → 25 原地升级

V23 与 V25 的桌面栈、软件源和包依赖都变了，跨版本 `full-upgrade` 不在官方支持
范围内。本工具的可行路径来自实测：切换源、隔离第三方源、完整跑完
`full-upgrade`，再修复桌面组件。它不能保证所有硬件、所有第三方软件都成功。

## 2. 软件源路径很反直觉

V25 的包放在 `beige/` 目录下的 `crimson` 分发中：

```
deb https://cdn-community-packages.deepin.com/deepin/beige/ crimson main commercial community
```

不是 `/deepin/crimson/`（实测 404），也不是 `/deepin/beige/dists/beige`。
工具探测的是 `<mirror>/dists/crimson/InRelease`，返回可读才认为镜像可用。
当前默认镜像，顺序即尝试顺序：

- `https://cdn-community-packages.deepin.com/deepin/beige/`
- `https://mirrors.tuna.tsinghua.edu.cn/deepin/beige/`
- `https://mirrors.aliyun.com/deepin/beige/`

官方 CDN 优先，镜像只作回退。镜像可能滞后：曾出现镜像仍提供旧版
`dde-control-center`（6.1.103，官方源已是 6.1.113），升级后控制中心异常。

应用商店源使用 `appstore-V25`；驱动源使用 `driver-25` 的 `snipe non-free`。
两者都可能因网络或签名问题导致 `apt update` 失败，工具会测试后按需停用。

## 3. 磐石/只读系统会直接失败

V23 没有磐石；这一节针对在 V25 上执行 `post`/`fix-desktop`/`rescue`，以及 V23 上因
文件系统错误或手动 `ro` 挂载导致的只读根。

V25 的磐石（immutable）把根文件系统置于只读保护下，`apt` 无法写入。升级脚本在
预检阶段检查挂载选项和 `deepin-immutable-*` 包，发现后拒绝继续；升级模拟阶段
如果发现将安装 immutable/uos-recovery 相关包也会中止。这不是可以“绕过”的
问题，需要先在控制中心关闭只读保护并重启。

## 4. 升级后 dock 不显示（本项目来源机器的真实故障）

现象：

- 首次进入 V25 桌面，窗口严重异常，底部 dock 不出现。
- 在 TTY 中执行一次 `apt update`，再回桌面，dock 出现。

**根因未证实。** 当时 journald 只保留了一个启动周期，第一现场日志已被覆盖，无法
确认是 apt 索引不完整、DDE 组件首次初始化失败、还是 dconfig 缓存问题。最可能
与升级后 apt 缓存/依赖索引状态有关，但这是推断。

工具的处理方式是“预防 + 修复”，不宣称根治：

- 升级前启用持久化 journald（`/etc/systemd/journald.conf.d/99-deepin-v25-persistent.conf`）。
- `post` 先执行 `apt update`，再进行 dpkg 修复、补齐桌面包、重启
  `dde-dconfig-daemon` 和用户级 `dde-shell@DDE.service`。
- `fix-desktop` 重复同样的流程，并重建缓存。
- `diagnose` 收集可供复查的信息。

如果问题再次出现，保留 `/var/log/journal` 和 `diagnose` 报告，才能进一步定位。

## 5. 第三方源是 apt 失败的头号原因

常见情况：

- 旧软件源的签名密钥已过期或被替换，`apt update` 报 `NO_PUBKEY`，退出码 100。
- 源里的包仍依赖 V23 的库，升级时试图降级/删除桌面关键包。
- 源地址随应用版本变化，旧地址 404。

因此升级时**所有**第三方源都会被移到
`/var/lib/deepin-v23-to-v25/quarantine/apt-sources/disabled/`。升级后按需恢复，
恢复时逐个测试，失败自动重新隔离。恢复后仍报签名错误，应升级/重装该应用，
而不是强行信任旧密钥。

## 6. 桌面关键包不能被移除

升级模拟会解析 `The following packages will be REMOVED:`。如果
`dde-shell`、`dde-session`、`dde-session-shell`、`lightdm` 在删除列表中，立即
中止。V23 的 `startdde`、`deepin-kwin-*` 被 V25 的新组件替代属于预期变化；
真正危险的是新桌面栈本身被删掉。

## 7. 脚本不要放在 Windows/NTFS 分区

如果进不了桌面，只能进 TTY，Windows 分区不一定自动挂载；即使挂载，路径常含
中文，TTY 下无法输入。升级/救援工具必须放在根文件系统的 ASCII 路径
（仓库默认安装到 `/opt/deepin-v23-to-v25`）。备份盘只用于存放数据和恢复工具
副本，不作为运行入口。

## 8. 微信与不可再生数据

微信聊天记录目录体积大、结构特殊，默认不备份。真正不可再生的是代码、文档、
数据库、shell 环境与历史、SSH/GPG 凭据；这些默认包含，敏感部分加密。开发工具
缓存、`node_modules`、构建产物默认排除，重装即可恢复。

## 9. Docker、数据库与端口

升级会停止 Docker 和所有运行中的容器。升级前记录运行中的容器名，`post` 阶段
启动 Docker 并尝试恢复这些容器。数据库数据卷不在用户 home 备份中，必须在
`hooks/backup-pre.d/` 里导出逻辑备份，否则重装后只剩空库。

## 10. 显卡、内核与 DKMS

- NVIDIA 专有驱动通过 DKMS 编译；新内核可能编译失败。预检会报告 DKMS 状态和
  显卡，升级后仍保留旧内核入口。
- 新内核无法启动时，在 GRUB「Advanced options」选择旧内核。
- 升级会更新 initramfs 和 GRUB；GRUB 菜单超时设为 5 秒，避免默认直接进入新内核。
- LUKS/LVM/RAID 不需要特殊处理，但升级前会记录 `fstab`、`crypttab` 和分区表；
  不要在这期间修改磁盘布局。

## 11. 空间与断电

- 预检要求根分区至少 20 GiB、`/boot` 至少 400 MiB 可用。
- 升级前会 `--download-only`，需要额外容纳整个升级包集合。
- 笔记本必须接电源；断电会中断 dpkg，需要重新执行 `upgrade` 或先 `rescue`。
- 建议在 `screen`/`tmux` 中运行，避免终端断开。

## 12. 备份目标与文件系统

- 默认拒绝把备份写到根分区同一文件系统，因为系统损坏时无法从同一盘恢复。
- 拒绝 `/proc`、`/sys`、`/dev`、`/boot`。
- FAT32 单文件上限 4 GiB，默认 3500 MiB 分卷；NTFS/ext4 可调大。
- 备份完成后务必保留 `checksums.sha256`、`archives.tsv`、`manifest.env`、
  `restore-backup.sh` 和 `tool/`，缺一不可。

## 13. 不要滥用 `--force` / `--yes`

`--force` 会跳过电源和图形终端限制，`--yes` 会跳过确认。它们只用于明确知道
后果的场景；正常升级不需要。
