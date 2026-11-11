# backup-pre.d

备份开始前执行的可执行脚本（`*.sh`，必须 `chmod +x`）。用于导出数据库、
生成清单等。失败只警告，不中止备份。

环境变量：

- `DEEPIN_BACKUP_DIR`：本次备份目录。
- `DEEPIN_BACKUP_USERS`：用户列表文件，每行 `用户名<TAB>HOME<TAB>UID`。
- `DEEPIN_BACKUP_EXTRA_DIR`：`$DEEPIN_BACKUP_DIR/extra`，放导出文件。

示例：

```bash
#!/usr/bin/env bash
set -euo pipefail
out="$DEEPIN_BACKUP_EXTRA_DIR/mysql"
install -d -m 700 "$out"
docker exec mysql-8.0 sh -c \
  'exec mysqldump --single-transaction --all-databases' \
  | gzip >"$out/all-databases.sql.gz"
```

注意：

- 不要把口令写进脚本；使用 `~/.my.cnf`（0600）或环境变量。
- `extra/` 不会自动加密、校验或恢复，敏感导出请在脚本内加密。
- 脚本以 root 执行，路径请写绝对路径。
