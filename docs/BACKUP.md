# 数据备份

备份的目标不是“拷走整个 home”，而是把**不可再生的东西**完整带走，同时让
可重装的环境保持轻量。默认策略按这个原则设计。

## 优先级

| 数据 | 是否默认备份 | 说明 |
| --- | --- | --- |
| 代码、git 仓库 | 是 | 常见代码目录自动包含；隐藏位置的仓库用 `scan` 发现 |
| 文档、桌面、图片 | 是 | 读取 XDG 配置，兼容中英文目录名 |
| 数据库 | 需 hook | 见下文 mysqldump 示例 |
| shell 配置与历史 | 是（加密） | `.bashrc`、`.zshrc`、`.profile`、历史、`.config` |
| SSH/GPG/云凭据 | 是（加密） | `.ssh`、`.gnupg`、`.kube`、`.aws`、`.docker` 等 |
| 下载、音乐、视频、ISO/虚拟机 | 否 | 用开关或 `--include` 加入 |
| 微信聊天记录 | 否 | 明确排除；需要时设 `WECHAT_BACKUP=1` |
| 开发工具缓存 | 否 | `node_modules`、`.cache`、构建产物等自动排除 |

## 自动路径

每个登录用户（UID ≥ 1000、真实 shell、HOME 存在）：

- `DOCUMENTS`、`DESKTOP`、`PICTURES`（通过 `~/.config/user-dirs.dirs`，
  回退到 `Documents/文档`、`Desktop/桌面`、`Pictures/图片`）。
- 代码目录：`git`、`wwwroot`、`node_www`、`projects`、`src`、`code`、`repos`、
  `workspace`、`workspaces`、`dev`、`develop`、`go/src`、`IdeaProjects`、
  `AndroidStudioProjects`。
- 字体与本地应用入口：`.local/share/fonts`、`.local/share/applications`。

可选：

```bash
BACKUP_INCLUDE_DOWNLOADS=1
BACKUP_INCLUDE_MEDIA=1
BACKUP_INCLUDE_DISK_IMAGES=1
```

`scan` 还会报告其他顶层大目录、常见目录之外的 git 仓库、超过 500 MiB 的
文件、微信路径和运行中的 Docker 容器，并把建议写成
`/var/lib/deepin-v23-to-v25/backup-paths.suggested.conf`。取消注释后合并到
`/etc/deepin-v23-to-v25.conf`。

## 用户指定路径

```bash
sudo deepin-v25 backup --dest /media/disk/backup \
  --include /home/alice/数据集 \
  --include /srv/www \
  --exclude '*.qcow2'
```

`BACKUP_EXTRA_PATHS` 里的路径：

- 位于某个用户 HOME 内 → 归入该用户的归档，恢复时自动回到原位置。
- 位于 HOME 外 → 进入 `system` 归档，默认不恢复，必须 `--system`。

同一路径的父子目录会自动去重。备份目标本身不能位于根文件系统，也不能是
`/proc`、`/sys`、`/dev`、`/boot`。

## 加密

敏感路径默认进入 gpg 对称加密归档；**明文归档在打包时就排除这些路径**，
不是先打包再删除。

敏感范围包括：`.ssh`、`.gnupg`、`.password-store`、`.kube`、`.aws`、`.docker`、
密钥环、shell 配置与历史、`.npmrc`、`.pypirc`、`.netrc`、`.git-credentials`、
`.gitconfig`、`~/.config`（可关闭），以及普通数据中的 `.env`、`*.key`、
`*.pem`、kdbx、ovpn 等。

口令来源优先级：

1. `--passphrase-file /root/backup.pass`（权限 0600）。
2. `SECRETS_PASSPHRASE_FILE`。
3. 交互输入两次，只保留在内存和临时文件描述符中，退出即清理。

`ALLOW_UNENCRYPTED_SECRETS=0` 时，缺少 gpg 或口令会直接失败，不会悄悄生成
明文敏感归档。

> 注意：加密保护内容，不隐藏文件名和目录结构；分卷文件名仍是可见的。

## 数据库 hooks

`hooks/backup-pre.d/*.sh` 在归档前执行，可执行文件才会运行。可用的环境变量：

- `DEEPIN_BACKUP_DIR`：本次备份目录（已创建）。
- `DEEPIN_BACKUP_USERS`：用户列表文件（`用户名<TAB>HOME<TAB>UID`）。
- `DEEPIN_BACKUP_EXTRA_DIR`：`$DEEPIN_BACKUP_DIR/extra`，放导出文件。

hook 失败只警告，不中止备份。数据库口令不要写进 hook，使用 `~/.my.cnf`
（0600）或环境变量。示例：

```bash
#!/usr/bin/env bash
set -euo pipefail
out="$DEEPIN_BACKUP_EXTRA_DIR/mysql"
install -d -m 700 "$out"
docker exec mysql-8.0 sh -c \
  'exec mysqldump --single-transaction --all-databases' \
  | gzip >"$out/all-databases.sql.gz"
```

导出文件位于备份目录的 `extra/` 下，**不进入 `archives.tsv` 和校验和，也不会
自动加密或自动恢复**；如含敏感数据，请在 hook 内直接加密（例如
`gpg --symmetric`），重装后按需手工导入。

## 分卷与校验

- 默认 gzip，任何 Deepin 都自带；可选 zstd。
- 默认按 3500 MiB 分卷，适配 FAT32 U 盘；恢复工具会自动按顺序拼接。
- 每个分卷写入 `checksums.sha256`。
- `BACKUP_VERIFY=1` 时会实际解压并读取 tar 索引，确认归档可恢复。

空间不足时工具会在写入前失败。备份目录内部结构见仓库根 README。

## 恢复

```bash
sudo bash /media/disk/deepin-backup-.../restore-backup.sh
```

只恢复用户数据。额外系统路径：

```bash
sudo bash /media/disk/deepin-backup-.../restore-backup.sh --system
```

全新安装后用户名变了：

```bash
sudo bash .../restore-backup.sh --map oldname=newname
```

恢复前会校验 `checksums.sha256`；数据以 root 解包并设置正确的 owner/group。
同名文件会被覆盖，执行前确认目标用户和路径正确；`--system` 恢复前会有一次
确认。详见 [RECOVERY.md](RECOVERY.md)。
