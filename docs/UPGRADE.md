# 升级流程

## 前置条件

1. 系统是 Deepin 23.x，且**没有启用磐石/只读保护**。
2. 已完成备份，并有可启动的 Deepin 25 U 盘作为兜底。
3. 能进入 TTY：`Ctrl+Alt+F3`，用普通账号登录后 `sudo`。
4. 接上电源，网络可用。笔记本电量不足时预检会拒绝继续。

先跑只读检查：

```bash
sudo ./bin/deepin-v25 preflight
```

预检会检查：版本与架构、根分区是否只读、`/` 与 `/boot` 空间、内核数量、
UEFI/BIOS、电源、LUKS/LVM/RAID、显卡与 DKMS、镜像连通性、NTP、apt 锁与
`dpkg --audit`、被 hold 的包、普通用户、最近备份是否在 14 天内。

任何一项 `[错误]` 都会阻止升级。`preflight` 只报告备份状态；真正的 `upgrade`
命令要求存在 14 天内的备份。备份过期或缺失时，先运行 `backup`；已有其他
备份可以加 `--skip-backup-check`。

## 执行

建议在 `screen` 里跑，避免 SSH/终端断开：

```bash
screen -S up25
sudo deepin-v25 upgrade
```

工具会要求输入 `UPGRADE` 确认，然后按顺序执行：

1. 把自身复制到 `/opt/deepin-v23-to-v25`，建立 `deepin-v25` 命令。
2. 启用持久化 journald（1 GiB 上限），保证首次启动失败时有日志。
3. 备份 GRUB 配置，设置 5 秒菜单和 `menu_show_once`，保留旧内核入口。
4. 停止 Docker 容器与 Docker、lightdm、unattended-upgrades、packagekit。
5. 把所有 `/etc/apt/sources.list.d/*.list|*.sources` 移到隔离目录，并备份原始
   `sources.list`。
6. 依次探测 `DEEPIN_MIRRORS`，写入
   `deb <mirror>/beige/ crimson main commercial community`，每次都用
   `apt update` 验证；全部失败则中止，原始源仍可恢复。
7. 可选测试 appstore（`appstore-V25`）和 driver（`driver-25`）源，失败自动停用。
8. `apt-get -s full-upgrade` 模拟：
   - 如果 `dde-shell`、`dde-session`、`dde-session-shell`、`lightdm` 会被删除，中止。
   - 如果会安装 `deepin-immutable-*`、`uos-recovery`、`deepin-recovery-plugin`，中止。
9. `--download-only` 预下载，减少正式升级时因断网重来的概率。
10. 最多 3 轮 `full-upgrade`，轮间执行 `dpkg --configure -a` 与
    `apt-get --fix-broken install`。
11. 检查桌面关键包，缺失则单独安装；更新 initramfs 与 GRUB。
12. 复制日志到备份目录的 `pre-upgrade-state/`，提示重启。

升级前状态记录在 `/var/lib/deepin-v23-to-v25/pre/`，包括 dpkg 选择、apt-mark、
软件源、挂载、分区、fstab、crypttab、启动文件、显卡、内核模块、启用服务、
Docker 容器等。日志在 `/var/log/deepin-v23-to-v25/`。

## 中断与续跑

apt/dpkg 支持断点续跑。断电、断网或终端关闭后：

```bash
sudo deepin-v25 upgrade
```

重新执行会重新预检、重新隔离源、重新模拟；已下载的包会复用。若 apt 状态损坏，
先跑：

```bash
sudo deepin-v25 rescue
```

再继续 `upgrade`。

## 首次进入 Deepin 25

```bash
sudo deepin-v25 post
```

`post` 会：

- 连续最多 3 次 `apt update`（首次启动 dock 不显示时，这是实测有效的步骤）。
- 修复 dpkg 状态，补跑 `full-upgrade`。
- 安装缺失的桌面关键包与推荐包。
- 重启 `dde-dconfig-daemon`，必要时启动 lightdm；已登录用户会重启
  `dde-shell@DDE.service`。
- 恢复升级前正在运行的 Docker 容器。
- 列出失败的 systemd 单元。

如果桌面出现窗口无边框、dock 不出现、主题异常，继续：

```bash
sudo deepin-v25 fix-desktop
```

## 第三方软件源

升级期间所有第三方源都被隔离，不会自动恢复，因为旧源的签名和依赖关系经常
与新系统冲突。查看和恢复：

```bash
sudo deepin-v25 sources status
sudo deepin-v25 sources restore warpdotdev.list
sudo deepin-v25 sources restore --all   # 逐个测试，失败自动重新隔离
```

恢复后如果 `apt update` 报 `NO_PUBKEY`，说明源仍用旧签名密钥，优先升级/重装
该软件，或保持禁用。

## 失败边界

- **没有原子回滚。** 系统升级后不能一键退回 V23；数据依靠备份恢复。
- 旧内核保留在 GRUB「Advanced options」中，可在新内核无法启动时选择。
- 进不了桌面但 TTY 可用：`rescue` → `fix-desktop`。
- TTY 也不可用：用 Deepin 25 U 盘启动，先尝试修复模式；必要时全新安装后运行
  备份目录里的 `restore-backup.sh`。
- 不要在没有备份的情况下手工执行 `apt full-upgrade` 或删除 `/var/cache/apt`。
