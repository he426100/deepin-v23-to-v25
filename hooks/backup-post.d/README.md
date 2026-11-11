# backup-post.d

所有归档写入后、归档校验和 manifest 生成之前执行。用于把额外导出复制到
备份盘、记录外部系统状态等。失败只警告。

可用环境变量与 `backup-pre.d` 相同：

- `DEEPIN_BACKUP_DIR`
- `DEEPIN_BACKUP_USERS`
- `DEEPIN_BACKUP_EXTRA_DIR`

注意：post hook 运行时 `checksums.sha256` 和 `archives.tsv` 已包含归档条目，
但 manifest.env 尚未生成；写入 `extra/` 的内容不会进入校验和，也不会被
`restore` 自动恢复。
