# 故障恢复

先判断故障在哪一层，不要一上来就重装。

```
开机
├─ GRUB 出现，但新内核卡住/黑屏
│    → GRUB「Advanced options」选旧内核（6.6.x）
├─ 内核启动，但停在全黑/emergency shell
│    → TTY 可用：journalctl -b -p err；恢复 /etc/fstab、crypttab
├─ 内核正常，lightdm 不启动
│    → sudo deepin-v25 rescue
├─ lightdm 正常，登录后黑屏/闪回登录页
│    → 新建测试用户验证；reset 用户 DDE 配置
├─ 进了桌面，但 dock 不显示/窗口无边框/主题错误
│    → sudo deepin-v25 fix-desktop
└─ 以上都不行
     → U 盘安装 Deepin 25，再用备份 restore
```

## TTY 入口

`Ctrl+Alt+F3`，用普通账号登录，`sudo -i` 或每条命令加 `sudo`。TTY 不支持中文，
脚本和路径都要用 ASCII。升级/救援工具已安装到 `/opt/deepin-v23-to-v25`，
命令为 `deepin-v25`；如果命令不存在，用仓库里的 `bin/deepin-v25`。

## lightdm 不启动

```bash
sudo deepin-v25 rescue
```

依次执行：检查根分区是否只读/磐石（是则直接停止并提示）、`apt update`、
dpkg 修复、安装缺失的桌面关键包、重启 `dde-dconfig-daemon`、启动 lightdm。
仍失败时重装关键包：

```bash
sudo deepin-v25 rescue --reinstall
```

日志：

```bash
journalctl -u lightdm -b -n 80 --no-pager
journalctl -b -p err --no-pager
systemctl --failed
```

根分区只读或存在 `deepin-immutable-*` 时，apt 修复不会生效。先按系统提示关闭
只读保护并重启，再运行 rescue。

## 登录后黑屏 / 闪回登录页

先排除用户配置不兼容：

```bash
sudo useradd -m test25
sudo passwd test25
```

注销后用 `test25` 登录。如果测试用户正常，说明是旧 DDE 配置问题：

```bash
sudo deepin-v25 fix-desktop --reset-user-config
```

该命令只把 `~/.config/dde-dock`、`deepin-daemon`、`dde-launcher` 等目录改名为
`.bak-时间戳`，不删除；确认无影响后可自行清理。也可以手动重置。随后注销重登。

## dock 不显示 / 窗口异常

```bash
sudo deepin-v25 fix-desktop
```

它会执行 `apt update`、dpkg 修复、补齐桌面包、重启 `dde-dconfig-daemon`、
重建图标/字体/desktop 缓存，并重启每个登录用户的 `dde-shell@DDE.service`。

仍无效：

```bash
sudo deepin-v25 fix-desktop --restart-session
sudo deepin-v25 fix-desktop --reset-user-config --restart-session
sudo deepin-v25 diagnose
```

`--restart-session` 会关闭所有图形程序，先保存工作。`diagnose` 生成
`/var/log/deepin-v23-to-v25/diagnose-*.txt`，包含系统版本、单元状态、桌面包
版本、进程、用户单元、journal 错误和窗口管理器信息。

> 首次 V25 启动 dock 不显示的问题，在本项目来源机器上通过 TTY 执行
> `apt update` 后恢复；根因未证实。详见 [PITFALLS.md](PITFALLS.md)。

## apt / dpkg 损坏

```bash
sudo deepin-v25 rescue
# 或手工：
sudo dpkg --configure -a
sudo apt-get -y --fix-broken install
sudo apt-get check
```

第三方源报 `NO_PUBKEY` 时，不要反复 `apt update`。先查看并保持禁用：

```bash
sudo deepin-v25 sources status
sudo deepin-v25 sources restore --all   # 会逐个测试，失败自动再隔离
```

## 全新安装后恢复数据

1. 安装 Deepin 25，创建与旧系统相同或不同的用户名。
2. 挂载备份盘（不要格式化）。
3. 确认备份完整：

```bash
cd /media/$USER/deepin-backup-...
sha256sum -c checksums.sha256
```

4. 恢复用户数据：

```bash
sudo bash restore-backup.sh
```

5. 用户名不同时映射：

```bash
sudo bash restore-backup.sh --map oldname=newname
```

6. 额外系统路径（`/srv/www` 等）默认不恢复，确认后再加：

```bash
sudo bash restore-backup.sh --system
```

恢复会覆盖同名文件；如果新系统上已有重要内容，先备份或改名。恢复完成后：

- 检查 `~/.ssh` 权限：`chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_*`。
- 重新登录，让 shell 与桌面配置生效。
- 数据库按 `extra/` 里的导出文件手工导入。
- Docker 数据卷不包含在用户归档中，需要单独迁移。

## 完全没有 TTY

用 Deepin 25 U 盘启动：

1. 先尝试 Live 环境挂载原系统，取回 `/var/log/deepin-v23-to-v25/` 日志。
2. 能修则修；不能修则全新安装，再执行上面的 restore。
3. 安装时只格式化系统分区，保留数据盘和备份盘。

## 回退预期

没有系统级原子回滚。旧内核可以在 GRUB 里选择，用于排查内核相关问题；
用户空间已经升级到 V25，不能靠换内核退回 V23。真正的回退方式是重装 +
restore。
