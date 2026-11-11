# backup-post.d

所有归档写入并生成 manifest 后执行。用于把额外导出复制到备份盘、记录外部
系统状态等。失败只警告。

可用环境变量与 `backup-pre.d` 相同：

- `DEEPIN_BACKUP_DIR`
- `DEEPIN_BACKUP_USERS`
- `DEEPIN_BACKUP_EXTRA_DIR`

注意：post hook 在 `checksums.sha256` 和 `archives.tsv` 生成之后运行，写入
`extra/` 的内容不会进入校验和，也不会被 `restore` 自动恢复。
