# deepin-v23-to-v25

通用 Deepin 23（beige）→ Deepin 25（crimson）原地升级工具。把一次真实的升级经验
整理成可重复执行的脚本：先备份、再升级、进桌面后修复，出问题能救援、能还原。

> 官方不支持 23 → 25 跨版本原地升级。本工具通过切换软件源、隔离第三方源、
> 全量升级桌面栈来完成迁移，属于**实验性方案**。升级前必须完成数据备份，
> 并准备好 Deepin 25 安装 U 盘作为兜底。

## 适用对象

- Deepin 23 / 23.1，x86_64、aarch64、loongarch64、riscv64。
- 有独立数据盘或 U 盘可存放备份（不能与根分区同一文件系统）。
- 能进入 TTY（Ctrl+Alt+F3）执行命令。
- 多用户、多块硬盘、LUKS/LVM、NVIDIA、Docker 等常见桌面环境。
- **不适用**：已经是 V25 的系统（只提供 post/fix/rescue）。V23 没有磐石；若根分区只读，先修复文件系统错误或 `ro` 挂载。

## 快速开始

```bash
# 仓库放在根文件系统的 ASCII 路径（不要放 NTFS/中文路径）
cd ~/git/deepin-v23-to-v25

# 1. 只读检查，不改系统
sudo ./bin/deepin-v25 preflight

# 2. 扫描数据，生成建议路径
sudo ./bin/deepin-v25 scan

# 3. 备份（备份盘不要放在根分区）
sudo ./bin/deepin-v25 backup --dest /media/$USER/backup

# 4. 把工具装到固定位置，之后在 TTY 里也能直接调用
sudo ./bin/deepin-v25 install

# 5. 切到 TTY（Ctrl+Alt+F3），登录后执行升级
sudo deepin-v25 upgrade

# 6. 首次进入 V25 桌面后
sudo deepin-v25 post

# 桌面异常（dock 不显示、窗口无边框等）
sudo deepin-v25 fix-desktop
```

升级脚本会要求输入 `UPGRADE` 确认；中途断电、断网或关闭终端后，重新执行
`sudo deepin-v25 upgrade` 即可从 apt 断点继续。若系统已被识别为 V25，命令会
提示改用 `sudo deepin-v25 post` 续做剩余的全量升级和桌面修复。建议先开
`screen -S up25`。

## 命令

| 命令 | 作用 |
| --- | --- |
| `preflight` | 只读检查版本、磁盘、启动方式、显卡、镜像、备份新鲜度 |
| `scan` | 扫描各用户的数据目录和 git 仓库，生成备份路径建议 |
| `backup` | 多用户归档 + 私密数据加密 + 分卷 + 校验和 + 自带恢复工具 |
| `upgrade` | 原地升级：隔离第三方源、切换镜像、模拟、下载、全量升级、验证 |
| `post` | 首次进入 V25 后修复 apt、桌面关键包、DDE 服务、Docker |
| `fix-desktop` | 修复 dock/窗口/主题/缓存；含 TTY 下 `apt update` 流程 |
| `rescue` | TTY 救援：修 dpkg/apt、重装桌面关键包、启动 lightdm |
| `restore` | 从备份恢复用户数据，可选 `--system` 恢复额外系统路径 |
| `sources` | 查看或逐个恢复被隔离的第三方软件源 |
| `diagnose` | 收集桌面故障报告，便于排查 |
| `install` | 复制工具到 `/opt/deepin-v23-to-v25` 并链接 `deepin-v25` |

全局参数：`--config FILE`、`--yes/-y`、`--dry-run`、`--force`。
`--dry-run` 不会安装包或改动软件源、用户数据，但仍会写日志和升级前状态快照。

## 备份范围

每个普通用户（UID ≥ 1000、有真实 shell、HOME 存在）自动包含：

- XDG 目录：文档、桌面、图片（同时识别中文目录名）。
- 常见代码目录：`git`、`wwwroot`、`node_www`、`projects`、`src`、`code`、
  `repos`、`workspace(s)`、`dev`、`develop`、`go/src`、`IdeaProjects`、
  `AndroidStudioProjects`、字体和本地 `.desktop` 文件。
- 加密归档：`.ssh`、`.gnupg`、`.password-store`、`.kube`、`.aws`、`.docker`、
  密钥环、shell 配置与历史、`.npmrc`、`.pypirc`、`.netrc`、`.git-credentials`、
  `.gitconfig`，以及普通数据中发现的 `.env`、私钥、kdbx、ovpn 等。
- `~/.config` 默认也进加密归档（很多应用把 token 放在这里）。

默认**不**包含：下载、音乐、视频、虚拟机/ISO 镜像、微信数据。用配置开关或
`--include` 按需加入。数据库建议通过 `hooks/backup-pre.d/` 先导出再备份。

备份目录结构：

```
manifest.env          机器可读元数据
MANIFEST.md           人类可读说明
archives.tsv          归档清单（类型、用户、分卷、加密标记）
checksums.sha256      分卷校验和
*.tar.gz[.gpg].part-N 数据分卷
tool/                 自带的本工具副本
restore-backup.sh     一条命令恢复
pre-upgrade-state/    升级前系统状态快照
```

恢复：

```bash
sudo bash /media/disk/deepin-backup-.../restore-backup.sh
sudo bash /media/disk/deepin-backup-.../restore-backup.sh --system
```

换用户名重装后可用 `--map oldname=newname` 把归档映射到新用户。

## 关于升级后 dock 不显示

本工具来自一次真实的 V23→V25 升级：首次进入桌面时窗口严重异常、底部 dock
不出现，在 TTY 中执行一次 `apt update` 后 dock 恢复。

**根因未证实**：升级只保留了一个启动周期的 journal，无法回看第一现场。最可能的
解释是升级后 apt 缓存/依赖索引不完整，DDE 组件在首次启动时初始化失败；但这是
推断，不是结论。工具因此采取“预防 + 修复”而非宣称已定位根因：

- 升级前启用持久化 journald，保证下次能看到完整启动日志。
- `post` 和 `fix-desktop` 固定执行 `apt update` + dpkg 修复 + 补齐桌面关键包，
  再重启 `dde-dconfig-daemon`、用户的 `dde-shell@DDE.service`（`post` 仅在用户
  已登录图形会话时重启）。
- `diagnose` 收集单元状态、包版本、日志和窗口管理器信息。

如果 dock 仍然不出现，依次尝试：

```bash
sudo deepin-v25 fix-desktop
sudo deepin-v25 fix-desktop --restart-session
sudo deepin-v25 fix-desktop --reset-user-config   # 会先把旧配置改名备份
sudo deepin-v25 diagnose
```

## 安全设计

- 备份目标与根分区同文件系统时默认拒绝；拒绝 `/proc`、`/sys`、`/dev`、`/boot`。
- 明文归档在打包时排除敏感路径；敏感归档未加密时默认拒绝执行。
- 模拟升级阶段若发现桌面关键包将被移除，或会安装 immutable/磐石相关包，立即中止。
- 第三方源全部移到隔离目录，升级后由 `sources` 按需恢复；恢复失败会自动重新隔离。
- 默认优先使用 Deepin 官方软件源，镜像仅作回退，避免镜像未同步导致旧包。
- 保留旧内核与 GRUB 菜单（默认 5 秒），升级前备份 GRUB 配置。
- 升级前记录 dpkg 选择、apt-mark、挂载、分区、fstab、crypttab、显卡、Docker
  容器等状态。
- 所有系统改动有日志：`/var/log/deepin-v23-to-v25/`。

## 配置

默认值见 [`config/default.conf`](config/default.conf)。不要直接修改仓库内默认值；
复制为 `/etc/deepin-v23-to-v25.conf` 或用 `--config` 指定：

```bash
sudo cp config/default.conf /etc/deepin-v23-to-v25.conf
sudoedit /etc/deepin-v23-to-v25.conf
```

常用项：`BACKUP_DEST`、`BACKUP_USERS`、`BACKUP_EXTRA_PATHS`、
`BACKUP_INCLUDE_DOWNLOADS`、`BACKUP_INCLUDE_MEDIA`、`ENCRYPT_SECRETS`、
`SECRETS_PASSPHRASE_FILE`、`DEEPIN_MIRRORS`、`APPSTORE_ENABLED`、
`DRIVER_REPO_ENABLED`、`DOCKER_RESTORE`。**不要把口令写进配置文件。**

## 文档

- [readme.txt](readme.txt) — 纯 ASCII 速查，供 TTY/控制台查看
- [docs/UPGRADE.md](docs/UPGRADE.md) — 升级流程、判断点、失败续跑
- [docs/BACKUP.md](docs/BACKUP.md) — 备份策略、路径定制、加密与 hooks
- [docs/RECOVERY.md](docs/RECOVERY.md) — 进不去桌面、还原、重装后的恢复
- [docs/PITFALLS.md](docs/PITFALLS.md) — 已知坑与实测说明

## 开发

```bash
bash -n bin/deepin-v25 lib/*.sh
./tests/smoke.sh
```

测试只使用临时目录和假数据，不执行 apt，不修改系统。
