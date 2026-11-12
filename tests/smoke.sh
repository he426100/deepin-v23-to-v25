#!/usr/bin/env bash
# Offline smoke tests: no apt, no system changes, temp dirs only.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/deepin-v25-test.XXXXXX")"
trap 'rm -rf -- "$TMPROOT"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '[pass] %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$*" >&2; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

STATE_DIR="$TMPROOT/state"
LOG_DIR="$TMPROOT/log"
export STATE_DIR LOG_DIR

# shellcheck source=../lib/common.sh
. "$REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/backup.sh
. "$REPO_ROOT/lib/backup.sh"
# shellcheck source=../lib/restore.sh
. "$REPO_ROOT/lib/restore.sh"
# shellcheck source=../lib/upgrade.sh
. "$REPO_ROOT/lib/upgrade.sh"
# shellcheck source=../lib/detect.sh
. "$REPO_ROOT/lib/detect.sh"

echo "== 语法 =="
for f in "$REPO_ROOT/bin/deepin-v25" "$REPO_ROOT"/lib/*.sh \
         "$REPO_ROOT"/config/*.conf "$REPO_ROOT"/tests/smoke.sh; do
  if bash -n "$f"; then pass "bash -n ${f#"$REPO_ROOT"/}"; else fail "bash -n $f"; fi
done

echo "== CLI =="
help_out="$("$REPO_ROOT/bin/deepin-v25" --help)"
case "$help_out" in *"用法"*) pass "--help" ;; *) fail "--help 输出不包含用法" ;; esac
version_out="$("$REPO_ROOT/bin/deepin-v25" --version)"
check "--version 与 VERSION 一致" \
  '[ "$version_out" = "deepin-v23-to-v25 $(head -1 "$REPO_ROOT/VERSION")" ]'
dry_out="$("$REPO_ROOT/bin/deepin-v25" --dry-run post 2>&1)"
case "$dry_out" in *"dry-run"*) pass "--dry-run post 不执行修改" ;; *) fail "--dry-run post 未生效" ;; esac

echo "== 配置 =="
cfg="$TMPROOT/test.conf"
cat >"$cfg" <<'EOF'
BACKUP_DEST="/tmp/example-backup"
BACKUP_EXTRA_PATHS+=("/srv/example")
EOF
got="$(bash -c '
  set -u
  REPO_ROOT="$1"; CONFIG_FILE="$2"
  . "$REPO_ROOT/lib/common.sh"
  load_config
  printf "%s|%s" "$BACKUP_DEST" "${BACKUP_EXTRA_PATHS[0]:-}"
' bash "$REPO_ROOT" "$cfg")"
check "load_config 覆盖默认值" '[ "$got" = "/tmp/example-backup|/srv/example" ]'

echo "== 路径判断 =="
check "子路径为真" 'is_subpath_lexical /a/b /a'
check "父路径为假" '! is_subpath_lexical /a /a/b'
check "前缀相似不算子路径" '! is_subpath_lexical /ab /a'

echo "== 列表去重 =="
mkdir -p "$TMPROOT/l/a/sub" "$TMPROOT/l/b"
list="$TMPROOT/list.bin"
: >"$list"
list_add_path "$list" "$TMPROOT/l/a"
list_add_path "$list" "$TMPROOT/l/a/sub"
list_add_path "$list" "$TMPROOT/l/b"
check "父目录吸收子目录（2 项）" '[ "$(list_count "$list")" -eq 2 ]'

list2="$TMPROOT/list2.bin"
: >"$list2"
list_add_path "$list2" "$TMPROOT/l/a/sub"
list_add_path "$list2" "$TMPROOT/l/a"
check "后加入的父目录替换子目录（1 项）" '[ "$(list_count "$list2")" -eq 1 ]'
first="$(tr -d '\0' <"$list2")"
check "保留下来的路径是父目录" '[ "$first" = "$TMPROOT/l/a" ]'

echo "== XDG 目录 =="
home1="$TMPROOT/home1"
mkdir -p "$home1/.config" "$home1/我的文档"
printf 'XDG_DOCUMENTS_DIR="$HOME/我的文档"\n' >"$home1/.config/user-dirs.dirs"
check "读取 user-dirs.dirs" '[ "$(xdg_dir "$home1" DOCUMENTS)" = "$home1/我的文档" ]'
home2="$TMPROOT/home2"
mkdir -p "$home2/文档"
check "中文目录回退" '[ "$(xdg_dir "$home2" DOCUMENTS)" = "$home2/文档" ]'

echo "== 归档与分卷 =="
src="$TMPROOT/src"
mkdir -p "$src/.ssh"
printf 'hello deepin\n' >"$src/hello.txt"
head -c 2500000 /dev/urandom >"$src/blob.bin"
printf 'Host example\n' >"$src/.ssh/config"
printf 'export A=1\n' >"$src/.bashrc"
abslist="$TMPROOT/abs.bin"
printf '%s\0' "$src/hello.txt" "$src/blob.bin" "$src/.ssh/config" "$src/.bashrc" >"$abslist"
secretlist="$TMPROOT/secret.bin"
printf '%s\0' "$src/.ssh/config" "$src/.bashrc" >"$secretlist"
DEST="$TMPROOT/dest"
WORK="$TMPROOT/work"
mkdir -p "$DEST" "$WORK"
ARCHIVES_TSV="$DEST/archives.tsv"
: >"$ARCHIVES_TSV"
: >"$DEST/checksums.sha256"
BACKUP_COMPRESS="gzip"
BACKUP_SPLIT_MB=1
BACKUP_EXTRA_EXCLUDES=()
WECHAT_BACKUP=0
SECRETS_INCLUDE_CONFIG=1
BACKUP_INCLUDE_DISK_IMAGES=0
PASSFILE=""
build_tar_excludes

write_archive home tester data.tar.gz "$src" "$abslist" 0
mapfile -d '' -t parts < <(find "$DEST" -maxdepth 1 -type f -name 'data.tar.gz.part-*' -print0 | sort -z)
check "生成多个分卷" '[ "${#parts[@]}" -gt 1 ]'
check "checksums 覆盖每个分卷" '[ "$(wc -l <"$DEST/checksums.sha256")" -eq "${#parts[@]}" ]'
check "archives.tsv 记录类型与用户" 'grep -q "^home	tester	data.tar.gz	gzip	0	${#parts[@]}	" "$ARCHIVES_TSV"'

RESTORE_DIR="$DEST"
listing="$(restore_stream data.tar.gz | gzip -dc | tar -tf -)"
case "$listing" in
  *hello.txt*) pass "分卷拼接后可读" ;;
  *) fail "分卷拼接后无法读取" ;;
esac
case "$listing" in
  *.ssh/config*|*.bashrc*) fail "明文归档泄露了敏感文件" ;;
  *) pass "明文归档排除敏感文件" ;;
esac

check "正常归档通过路径检查" 'validate_members data.tar.gz 0 gzip'

echo "== 私密目录与 *.env =="
proj="$TMPROOT/proj"
mkdir -p "$proj/.config" "$proj/.ssh"
printf 'hello\n' >"$proj/normal.txt"
printf 'secret\n' >"$proj/.config/app.conf"
printf 'KEY=1\n' >"$proj/prod.env"
printf 'Host example\n' >"$proj/.ssh/config"
printf 'alias ll=ls\n' >"$proj/.bashrc"
printf '[user]\n\tname = x\n' >"$proj/.gitconfig"
printf 'history\n' >"$proj/.zsh_history"
proj_secret="$TMPROOT/proj-secret.bin"
: >"$proj_secret"
find_secret_files "$proj" "$proj_secret"
secret_flat="$(tr -d '\0' <"$proj_secret")"
case "$secret_flat" in
  *"$proj/.config"*) pass "项目 .config 进入加密清单" ;;
  *) fail "项目 .config 未进入加密清单" ;;
esac
case "$secret_flat" in
  *"$proj/.ssh"*) pass "项目 .ssh 目录进入加密清单" ;;
  *) fail "项目 .ssh 目录未进入加密清单" ;;
esac
case "$secret_flat" in
  *"$proj/prod.env"*) pass "*.env 进入加密清单" ;;
  *) fail "*.env 未进入加密清单" ;;
esac
for dot in .bashrc .gitconfig .zsh_history; do
  case "$secret_flat" in
    *"$proj/$dot"*) pass "仓库内 $dot 进入加密清单" ;;
    *) fail "仓库内 $dot 未进入加密清单" ;;
  esac
done

proj_plain="$TMPROOT/proj-plain.bin"
printf '%s\0' "$proj" >"$proj_plain"
write_archive home tester project.tar.gz "$TMPROOT" "$proj_plain" 0
plisting="$(restore_stream project.tar.gz | gzip -dc | tar -tf -)"
case "$plisting" in
  *normal.txt*) pass "项目普通文件进入明文归档" ;;
  *) fail "项目普通文件丢失" ;;
esac
case "$plisting" in
  *prod.env*|*.config/app.conf*|*.ssh/config*|*.bashrc*|*.gitconfig*|*.zsh_history*)
    fail "明文归档泄露项目私密文件" ;;
  *) pass "明文归档排除项目私密文件" ;;
esac

echo "== 用户列表 =="
check "显式重复用户去重" \
  '[ "$(BACKUP_USERS="$(id -un) $(id -un)" resolve_backup_users)" = "$(id -un)" ]'
if ( BACKUP_USERS="definitely-no-such-user-xyz" resolve_backup_users ) >/dev/null 2>&1; then
  fail "未知用户未被拒绝"
else
  pass "未知用户被拒绝"
fi


echo "== 路径穿越拒绝 =="
if ( validate_archive_name '../evil.tar.gz' ) >/dev/null 2>&1; then
  fail "非法归档名未被拒绝"
else
  pass "非法归档名被拒绝"
fi
check "合法归档名通过" 'validate_archive_name data.tar.gz'
mkdir -p "$TMPROOT/evil"
echo x >"$TMPROOT/evil/victim.txt"
tar -czPf "$TMPROOT/evil/evil.tar.gz" -C "$TMPROOT/evil" \
  --transform='s|^|../|' victim.txt 2>/dev/null
RESTORE_DIR="$TMPROOT/evil"
if ( validate_members evil.tar.gz 0 gzip ) >/dev/null 2>&1; then
  fail "包含 ../ 的归档未被拒绝"
else
  pass "包含 ../ 的归档被拒绝"
fi

echo "== 加密归档 =="
if have gpg; then
  PASSFILE="$TMPROOT/pass"
  printf 'test-passphrase\n' >"$PASSFILE"
  chmod 600 "$PASSFILE"
  write_archive secrets tester secrets.tar.gz.gpg "$src" "$secretlist" 1
  mapfile -d '' -t eparts < <(find "$DEST" -maxdepth 1 -type f -name 'secrets.tar.gz.gpg.part-*' -print0 | sort -z)
  check "生成加密归档（单卷或分卷）" '[ -f "$DEST/secrets.tar.gz.gpg" ] || [ "${#eparts[@]}" -ge 1 ]'
  RESTORE_DIR="$DEST"
  elisting="$(restore_stream secrets.tar.gz.gpg | \
    gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$PASSFILE" -d | \
    gzip -dc | tar -tf -)"
  case "$elisting" in
    *.ssh/config*) pass "加密归档包含 .ssh" ;;
    *) fail "加密归档丢失 .ssh" ;;
  esac
  case "$elisting" in
    *.bashrc*) pass "加密归档包含 shell 配置" ;;
    *) fail "加密归档丢失 shell 配置" ;;
  esac
  write_archive secrets tester project-secrets.tar.gz.gpg "$TMPROOT" "$proj_secret" 1
  plisting_enc="$(restore_stream project-secrets.tar.gz.gpg | \
    gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$PASSFILE" -d | \
    gzip -dc | tar -tf -)"
  case "$plisting_enc" in
    *prod.env*|*.config/app.conf*|*.ssh/config*)
      pass "加密归档包含项目私密文件" ;;
    *)
      fail "加密归档丢失项目私密文件" ;;
  esac
  PASSFILE=""
else
  printf '[skip] gpg 未安装，跳过加密测试\n'
fi

echo "== 系统敏感路径 =="
missing_excludes=""
for e in etc/shadow etc/gshadow etc/ssh etc/ssl/private etc/pki/private \
         etc/NetworkManager/system-connections etc/wireguard etc/openvpn \
         etc/ppp root/.ssh root/.gnupg; do
  printf '%s\n' "${TAR_EXCLUDES_SYSTEM[@]}" | grep -qx "$e" || missing_excludes="$missing_excludes $e"
done
if [ -z "$missing_excludes" ]; then
  pass "系统明文归档排除全部受保护路径"
else
  fail "系统明文归档缺少排除：$missing_excludes"
fi

fakeroot="$TMPROOT/fakeroot"
mkdir -p "$fakeroot/etc/ssl/private" "$fakeroot/home/u"
printf 'shadow\n' >"$fakeroot/etc/shadow"
printf 'key\n' >"$fakeroot/etc/ssl/private/server.key"
printf 'keep\n' >"$fakeroot/home/u/keep.txt"
sysabs="$TMPROOT/sysabs.bin"
printf '%s\0' "$fakeroot/etc/shadow" "$fakeroot/etc/ssl/private/server.key" \
  "$fakeroot/home/u/keep.txt" >"$sysabs"
WORK="$TMPROOT/work"
write_archive system "" system-test.tar.gz "$fakeroot" "$sysabs" 0
syslisting="$(restore_stream system-test.tar.gz | gzip -dc | tar -tf -)"
case "$syslisting" in
  *keep.txt*) pass "系统明文归档保留普通文件" ;;
  *) fail "系统明文归档丢失普通文件" ;;
esac
case "$syslisting" in
  *etc/shadow*|*server.key*) fail "系统明文归档泄露受保护路径" ;;
  *) pass "系统明文归档排除 shadow 和私钥" ;;
esac

echo "== 系统列表去重 =="
sysplain_list="$TMPROOT/sysplain.bin"
printf '%s\0' /etc /etc/shadow >"$sysplain_list"
list_remove_exact "$sysplain_list" /etc/shadow
sysplain_count="$(list_count "$sysplain_list")"
sysplain_flat="$(tr -d '\0' <"$sysplain_list")"
check "受保护路径精确移出明文列表" \
  '[ "$sysplain_count" -eq 1 ] && [ "$sysplain_flat" = "/etc" ]'

echo "== 符号链接标准目录 =="
home3="$TMPROOT/home3"
mkdir -p "$home3/data/real-docs" "$TMPROOT/work3/lists"
printf 'doc\n' >"$home3/data/real-docs/a.txt"
ln -s "$home3/data/real-docs" "$home3/Documents-link"
WORK="$TMPROOT/work3"
: >"$WORK/lists/system-plain"
: >"$WORK/lists/system-secret"
plain3="$TMPROOT/plain3.bin"
secret3="$TMPROOT/secret3.bin"
: >"$plain3"
: >"$secret3"
add_user_scanned_path "$home3/Documents-link" tester "$home3" "$plain3" "$secret3" 2>/dev/null
flat3="$(tr -d '\0' <"$plain3")"
case "$flat3" in
  *"$home3/Documents-link"*) pass "符号链接本身进入用户清单" ;;
  *) fail "符号链接本身未进入用户清单" ;;
esac
case "$flat3" in
  *"$home3/data/real-docs"*) pass "符号链接目标进入用户清单" ;;
  *) fail "符号链接目标未进入用户清单（数据会丢失）" ;;
esac

outside="$TMPROOT/outside-docs"
mkdir -p "$outside"
ln -s "$outside" "$home3/Outside-link"
: >"$plain3"
add_user_scanned_path "$home3/Outside-link" tester "$home3" "$plain3" "$secret3" 2>/dev/null
sys3="$(tr -d '\0' <"$WORK/lists/system-plain")"
case "$sys3" in
  *"$outside"*) pass "HOME 外链接目标归入系统归档" ;;
  *) fail "HOME 外链接目标未归入系统归档" ;;
esac
case "$(tr -d '\0' <"$plain3")" in
  *"$outside"*) fail "HOME 外链接目标误入用户归档" ;;
  *) pass "HOME 外链接目标不进入用户归档" ;;
esac

: >"$plain3"
: >"$WORK/lists/system-plain"
add_user_scanned_path "$outside" tester "$home3" "$plain3" "$secret3" 2>/dev/null
sys3="$(tr -d '\0' <"$WORK/lists/system-plain")"
case "$sys3" in
  *"$outside"*) pass "HOME 外标准目录归入系统归档" ;;
  *) fail "HOME 外标准目录未归入系统归档" ;;
esac
case "$(tr -d '\0' <"$plain3")" in
  *"$outside"*) fail "HOME 外标准目录误入用户归档" ;;
  *) pass "HOME 外标准目录不进入用户归档" ;;
esac

echo "== 恢复解包 =="
restore_home="$TMPROOT/restore-home"
mkdir -p "$restore_home"
extract_home_archive data.tar.gz 0 gzip "$(id -un)" "$restore_home" >/dev/null
check "恢复后普通文件存在" '[ -f "$restore_home/hello.txt" ]'
check "恢复后私密文件未被明文解出" '[ ! -f "$restore_home/.bashrc" ]'

symabs="$TMPROOT/symabs.bin"
printf '%s\0' "$home3/Documents-link" "$home3/data/real-docs" >"$symabs"
write_archive home tester symlink-test.tar.gz "$home3" "$symabs" 0
symhome="$TMPROOT/restore-symlink"
mkdir -p "$symhome"
extract_home_archive symlink-test.tar.gz 0 gzip "$(id -un)" "$symhome" >/dev/null
check "恢复后符号链接存在" '[ -L "$symhome/Documents-link" ]'
check "恢复后链接目标数据存在" '[ -f "$symhome/data/real-docs/a.txt" ]'

printf '%s\0' "$outside" >"$TMPROOT/absout.bin"
if make_relative_list "$home3" "$TMPROOT/absout.bin" "$TMPROOT/relout.bin" 2>/dev/null; then
  fail "HOME 外路径未被 make_relative_list 拒绝"
else
  pass "HOME 外路径被 make_relative_list 拒绝"
fi
printf '%s\0' /etc/shadow >"$TMPROOT/absroot.bin"
make_relative_list / "$TMPROOT/absroot.bin" "$TMPROOT/relroot.bin"
relroot="$(tr -d '\0' <"$TMPROOT/relroot.bin")"
check "系统归档成员去掉根前缀" '[ "$relroot" = "etc/shadow" ]'

echo "== REMOVED 折行解析 =="
simfixture="$TMPROOT/sim-removed.log"
cat >"$simfixture" <<'EOF'
The following packages will be REMOVED:
  libfoo:amd64 dde-session-shell
  dde-shell
The following NEW packages will be installed:
  unrelated-pkg
EOF
removed_names_test="$(removed_package_names < <(removed_packages_block "$simfixture"))"
for pkg in libfoo dde-session-shell dde-shell; do
  if printf '%s\n' "$removed_names_test" | grep -qx "$pkg"; then
    pass "折行 REMOVED 识别：$pkg"
  else
    fail "折行 REMOVED 漏掉：$pkg"
  fi
done
if printf '%s\n' "$removed_names_test" | grep -qx unrelated-pkg; then
  fail "REMOVED 段之后的包被误收"
else
  pass "REMOVED 段之后的包未被误收"
fi

echo "== 安装路径校验 =="
mkdir -p "$TMPROOT/fake-repo/bin"
if ( validate_tool_install_dir "$TMPROOT" "$TMPROOT/fake-repo" ) >/dev/null 2>&1; then
  fail "未拒绝仓库的上级目录"
else
  pass "拒绝仓库的上级目录"
fi
if ( validate_tool_install_dir "$TMPROOT/fake-repo/sub" "$TMPROOT/fake-repo" ) >/dev/null 2>&1; then
  fail "未拒绝仓库内部目录"
else
  pass "拒绝仓库内部目录"
fi
badpath="$TMPROOT/bad dir"
if ( validate_tool_install_dir "$badpath" "$TMPROOT/fake-repo" ) >/dev/null 2>&1; then
  fail "未拒绝含空格的安装路径"
else
  pass "拒绝含空格的安装路径"
fi
check "非法路径校验发生在创建目录之前" '[ ! -e "$badpath" ]'
check "独立安装路径通过校验" \
  'validate_tool_install_dir "$TMPROOT/install-dest" "$TMPROOT/fake-repo"'

echo "== 默认源与备份阈值 =="
first_mirror="$(bash -c '. "$1"; printf "%s" "${DEEPIN_MIRRORS[0]}"' bash \
  "$REPO_ROOT/config/default.conf")"
check "官方 CDN 优先" \
  '[ "$first_mirror" = "https://cdn-community-packages.deepin.com/deepin/beige/" ]'
check "MAX_BACKUP_AGE_DAYS 写入默认配置" \
  'grep -q "^MAX_BACKUP_AGE_DAYS=14$" "$REPO_ROOT/config/default.conf"'

echo "== 磐石包识别 =="
imm_out="$(
  dpkg-query() {
    printf '%s\n' node-immutable ceph-immutable-object-cache \
      golang-github-hashicorp-go-immutable-radix-dev \
      deepin-immutable-ctl deepin-recovery-plugin uos-recovery
  }
  immutable_packages
)"
for p in deepin-immutable-ctl deepin-recovery-plugin uos-recovery; do
  case "$imm_out" in
    *"$p"*) pass "识别磐石包：$p" ;;
    *) fail "漏掉磐石包：$p" ;;
  esac
done
case "$imm_out" in
  *node-immutable*|*ceph-immutable*|*immutable-radix*)
    fail "普通 immutable 包被误判为磐石" ;;
  *) pass "普通 immutable 包不误判" ;;
esac

echo "== apt 源回滚 =="
apt_update() { return 0; }
APT_ETC_DIR="$TMPROOT/etc-apt"
STATE_DIR="$TMPROOT/state-rollback"
DEEPIN_SUITE=crimson
DEEPIN_COMPONENTS="main commercial community"
mkdir -p "$APT_ETC_DIR/sources.list.d"
printf 'deb https://old.example/deepin beige main\n' >"$APT_ETC_DIR/sources.list"
printf 'deb https://third.example/app stable main\n' >"$APT_ETC_DIR/sources.list.d/third.list"
SOURCES_TOUCHED=0
MAIN_SOURCE_WRITTEN=0
AUX_SOURCES_WRITTEN=()
save_apt_sources >/dev/null
check "原始主源已备份" '[ -f "$STATE_DIR/quarantine/apt-sources/sources.list.orig" ]'
check "第三方源已隔离" '[ ! -f "$APT_ETC_DIR/sources.list.d/third.list" ]'
write_main_source "https://new.example/deepin/"
install_aux_source appstore "deb https://aux.example/appstore crimson appstore" >/dev/null
check "新主源已写入" 'grep -q "new.example" "$APT_ETC_DIR/sources.list"'
check "附加源已写入" '[ -f "$APT_ETC_DIR/sources.list.d/appstore.list" ]'
restore_original_apt_sources >/dev/null
check "主源恢复到升级前" 'grep -q "old.example" "$APT_ETC_DIR/sources.list"'
check "第三方源恢复到升级前" '[ -f "$APT_ETC_DIR/sources.list.d/third.list" ]'
check "生成的附加源已移除" '[ ! -f "$APT_ETC_DIR/sources.list.d/appstore.list" ]'

# 模拟在复制原始源之前就失败：不得删除尚未改动的 sources.list。
rm -f "$STATE_DIR/quarantine/apt-sources/sources.list.orig"
rm -rf "$STATE_DIR/quarantine/apt-sources/sources.list.d.orig"
printf 'deb https://untouched.example/deepin beige main\n' >"$APT_ETC_DIR/sources.list"
MAIN_SOURCE_WRITTEN=0
AUX_SOURCES_WRITTEN=()
restore_original_apt_sources >/dev/null
check "早失败不删除原始主源" 'grep -q "untouched.example" "$APT_ETC_DIR/sources.list"'

echo
printf '通过：%d，失败：%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
