#!/usr/bin/env bash
# Data scanner and backup writer.
# shellcheck shell=bash

# --------------------------------------------------------------- helpers ----

WORK=""
PASSFILE=""
TEMP_PASSFILE=0
DEST=""
ARCHIVES_TSV=""

list_add_path() {
  local file="$1" path="$2"
  local -a old=()
  local p prune=0
  [ -e "$path" ] || [ -L "$path" ] || return 0
  [ -f "$file" ] || : >"$file"
  while IFS= read -r -d '' p; do
    old+=("$p")
    [ "$p" = "$path" ] && return 0
    if is_subpath_lexical "$path" "$p"; then
      return 0
    fi
    if is_subpath_lexical "$p" "$path"; then
      prune=1
    fi
  done <"$file"
  if [ "$prune" -eq 1 ]; then
    : >"$file.tmp"
    for p in "${old[@]}"; do
      is_subpath_lexical "$p" "$path" && continue
      printf '%s\0' "$p" >>"$file.tmp"
    done
    mv -- "$file.tmp" "$file"
  fi
  printf '%s\0' "$path" >>"$file"
}

list_remove_exact() {
  local file="$1" path="$2" p tmp
  [ -f "$file" ] || return 0
  tmp="$file.tmp"
  : >"$tmp"
  while IFS= read -r -d '' p; do
    [ "$p" = "$path" ] && continue
    printf '%s\0' "$p" >>"$tmp"
  done <"$file"
  mv -- "$tmp" "$file"
}

list_empty() { [ ! -s "$1" ]; }

list_print() {
  local p
  while IFS= read -r -d '' p; do printf '  %s\n' "$p"; done <"$1"
}

list_count() {
  local n=0 p
  [ -f "$1" ] || { printf '0'; return; }
  while IFS= read -r -d '' p; do n=$((n + 1)); done <"$1"
  printf '%s' "$n"
}

list_total_bytes() {
  local file="$1" p total=0 size
  [ -f "$file" ] || { printf '0'; return; }
  while IFS= read -r -d '' p; do
    size="$(du -sx --block-size=1 -- "$p" 2>/dev/null | cut -f1)"
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    total=$((total + size))
  done <"$file"
  printf '%s' "$total"
}

all_lists_total_bytes() {
  local f total=0
  for f in "$WORK"/lists/*; do
    [ -f "$f" ] || continue
    total=$((total + $(list_total_bytes "$f")))
  done
  printf '%s' "$total"
}

xdg_dir() {
  local home="$1" key="$2" v
  v="$(sed -n "s/^XDG_${key}_DIR=\"\\(.*\\)\"/\\1/p" "$home/.config/user-dirs.dirs" 2>/dev/null | tail -1)"
  v="${v//\$HOME/$home}"
  if [ -n "$v" ] && [ -d "$v" ]; then
    printf '%s' "$v"
    return 0
  fi
  local c
  case "$key" in
    DESKTOP)   for c in Desktop 桌面; do [ -d "$home/$c" ] && { printf '%s' "$home/$c"; return 0; }; done ;;
    DOWNLOAD)  for c in Downloads 下载; do [ -d "$home/$c" ] && { printf '%s' "$home/$c"; return 0; }; done ;;
    DOCUMENTS) for c in Documents 文档; do [ -d "$home/$c" ] && { printf '%s' "$home/$c"; return 0; }; done ;;
    MUSIC)     for c in Music 音乐; do [ -d "$home/$c" ] && { printf '%s' "$home/$c"; return 0; }; done ;;
    PICTURES)  for c in Pictures 图片; do [ -d "$home/$c" ] && { printf '%s' "$home/$c"; return 0; }; done ;;
    VIDEOS)    for c in Videos 视频; do [ -d "$home/$c" ] && { printf '%s' "$home/$c"; return 0; }; done ;;
  esac
  return 0
}

user_standard_paths() {
  local home="$1" p rel
  for key in DOCUMENTS DESKTOP PICTURES; do
    p="$(xdg_dir "$home" "$key")"
    [ -n "$p" ] && printf '%s\n' "$p"
  done
  if is_true "$BACKUP_INCLUDE_DOWNLOADS"; then
    p="$(xdg_dir "$home" DOWNLOAD)"
    [ -n "$p" ] && printf '%s\n' "$p"
  fi
  if is_true "$BACKUP_INCLUDE_MEDIA"; then
    for key in MUSIC VIDEOS; do
      p="$(xdg_dir "$home" "$key")"
      [ -n "$p" ] && printf '%s\n' "$p"
    done
  fi
  for rel in \
    git wwwroot node_www projects src code repos workspace workspaces dev develop \
    go/src IdeaProjects AndroidStudioProjects \
    .local/share/fonts .local/share/applications; do
    [ -d "$home/$rel" ] && printf '%s\n' "$home/$rel"
  done
}

user_known_secret_paths() {
  local home="$1" rel
  for rel in \
    .ssh .gnupg .password-store .kube .aws .docker \
    .local/share/keyrings .local/share/fish/fish_history \
    .npmrc .pypirc .netrc .git-credentials .gitconfig \
    .bashrc .bash_profile .bash_logout .bash_aliases .bash_history .inputrc \
    .profile .zshrc .zshenv .zprofile .zlogin .zlogout .zsh_history; do
    [ -e "$home/$rel" ] && printf '%s\n' "$home/$rel"
  done
  if is_true "$SECRETS_INCLUDE_CONFIG" && [ -d "$home/.config" ]; then
    printf '%s\n' "$home/.config"
  fi
}

system_protected_paths() {
  local p
  for p in /etc/ssh /etc/shadow /etc/gshadow /etc/ssl/private /etc/pki/private \
           /etc/NetworkManager/system-connections /etc/wireguard /etc/openvpn \
           /etc/ppp /root/.ssh /root/.gnupg; do
    [ -e "$p" ] && printf '%s\n' "$p"
  done
}

is_secret_path() {
  local path="$1" home="$2" rel p
  [ -n "$home" ] || return 1
  if [ "$path" = "$home" ]; then
    return 1
  fi
  is_subpath_lexical "$path" "$home" || return 1
  rel="${path#"$home"/}"
  case "$rel" in
    .ssh|.ssh/*|.gnupg|.gnupg/*|.password-store|.password-store/*|\
    .kube|.kube/*|.aws|.aws/*|.docker|.docker/*|\
    .local/share/keyrings|.local/share/keyrings/*|\
    .local/share/fish/fish_history|\
    .npmrc|.pypirc|.netrc|.git-credentials|.gitconfig|\
    .bashrc|.bash_profile|.bash_logout|.bash_aliases|.bash_history|.inputrc|\
    .profile|.zshrc|.zshenv|.zprofile|.zlogin|.zlogout|.zsh_history)
      return 0 ;;
  esac
  if is_true "$SECRETS_INCLUDE_CONFIG"; then
    case "$rel" in .config|.config/*) return 0 ;; esac
  fi
  case "$rel" in
    *.env) return 0 ;;
    .env.*|*/.env|*/.env.*) return 0 ;;
    *.pem|*.key|*.p12|*.pfx|*.kdbx|*.ovpn) return 0 ;;
    id_rsa|id_rsa.*|id_ed25519|id_ed25519.*|id_ecdsa|id_ecdsa.*|id_dsa|id_dsa.*) return 0 ;;
  esac
  return 1
}

find_secret_files() {
  local root="$1" out="$2" prune=()
  local p d
  [ -e "$root" ] || return 0
  prune=(
    -name .cache -o -name .git -o -name node_modules -o -name .venv -o -name venv
    -o -name __pycache__ -o -name .pytest_cache -o -name .mypy_cache -o -name .tox
    -o -name .gradle -o -name target -o -name .npm -o -name .yarn -o -name .pnpm-store
    -o -name .local -o -name .mozilla
  )
  local -a file_prune=("${prune[@]}")
  local -a secret_dirs=( .ssh .gnupg .password-store .kube .aws .docker )
  if is_true "$SECRETS_INCLUDE_CONFIG"; then
    file_prune+=(-o -name .config)
    secret_dirs+=( .config )
  fi
  while IFS= read -r -d '' p; do
    list_add_path "$out" "$p"
  done < <(
    find "$root" \( "${file_prune[@]}" \) -prune -o \
      \( -type f -o -type l \) \( \
        -name '.env' -o -name '.env.*' -o -name '*.env' \
        -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' \
        -o -name '*.kdbx' -o -name '*.ovpn' \
        -o -name 'id_rsa' -o -name 'id_rsa.*' \
        -o -name 'id_ed25519' -o -name 'id_ed25519.*' \
        -o -name 'id_ecdsa' -o -name 'id_ecdsa.*' \
        -o -name 'id_dsa' -o -name 'id_dsa.*' \
        -o -name '.netrc' -o -name '.git-credentials' \
        -o -name '.npmrc' -o -name '.pypirc' -o -name '.gitconfig' \
        -o -name '.bashrc' -o -name '.bash_profile' -o -name '.bash_logout' \
        -o -name '.bash_aliases' -o -name '.bash_history' -o -name '.inputrc' \
        -o -name '.profile' -o -name '.zshrc' -o -name '.zshenv' \
        -o -name '.zprofile' -o -name '.zlogin' -o -name '.zlogout' \
        -o -name '.zsh_history' \
        -o -name 'ssh_host_*_key' \
      \) -print0 2>/dev/null
  )
  local -a dir_expr=()
  for d in "${secret_dirs[@]}"; do
    [ "${#dir_expr[@]}" -gt 0 ] && dir_expr+=(-o)
    dir_expr+=(-name "$d")
  done
  while IFS= read -r -d '' p; do
    list_add_path "$out" "$p"
  done < <(
    find "$root" \( "${prune[@]}" \) -prune -o \
      -type d \( "${dir_expr[@]}" \) -prune -print0 2>/dev/null
  )
}

# -------------------------------------------------------------- excludes ----

TAR_EXCLUDES=()
TAR_EXCLUDES_SECRET=()
TAR_EXCLUDES_SYSTEM=()
build_tar_excludes() {
  local -a common=(
    '.cache' 'Cache' 'CachedData' 'Code Cache' 'GPUCache' 'Service Worker'
    'Crashpad' 'ShaderCache' 'DawnCache' '.thumbnails' 'thumbnails'
    'Trash' '.local/share/Trash' 'lost+found'
    'node_modules' 'bower_components' 'vendor' '.venv' 'venv'
    '__pycache__' '.pytest_cache' '.mypy_cache' '.ruff_cache' '.tox' '.nox'
    '.gradle' '.m2/repository' '.cargo/registry' '.npm/_cacache' '.npm/_logs'
    '.yarn/cache' '.pnpm-store' 'CMakeFiles' 'CMakeTmp' 'target'
  )
  TAR_EXCLUDES=("${common[@]}")
  # The encrypted archive must not inherit the plaintext secret exclusions.
  TAR_EXCLUDES_SECRET=("${common[@]}")
  TAR_EXCLUDES+=(
    '.ssh' '.gnupg' '.password-store' '.kube' '.aws' '.docker'
    '.local/share/keyrings' '.npmrc' '.pypirc' '.netrc' '.git-credentials'
    '.gitconfig' '.bashrc' '.bash_profile' '.bash_logout' '.bash_aliases'
    '.bash_history' '.inputrc' '.profile' '.zshrc' '.zshenv' '.zprofile'
    '.zlogin' '.zlogout' '.zsh_history'
    '.env' '.env.*' '*.env' '*.pem' '*.key' '*.p12' '*.pfx' '*.kdbx' '*.ovpn'
    'id_rsa' 'id_rsa.*' 'id_ed25519' 'id_ed25519.*' 'id_ecdsa' 'id_ecdsa.*'
    'id_dsa' 'id_dsa.*' 'ssh_host_*_key'
  )
  # Plain system archives run with cwd=/, so these must match full members.
  TAR_EXCLUDES_SYSTEM=(
    'etc/shadow' 'etc/gshadow' 'etc/ssh' 'etc/ssl/private' 'etc/pki/private'
    'etc/NetworkManager/system-connections' 'etc/wireguard' 'etc/openvpn'
    'etc/ppp' 'root/.ssh' 'root/.gnupg'
  )
  if is_true "$SECRETS_INCLUDE_CONFIG"; then
    TAR_EXCLUDES+=('.config')
  fi
  if ! is_true "$WECHAT_BACKUP"; then
    TAR_EXCLUDES+=('xwechat_files' 'WeChat Files' 'wechat_files' 'WeChatFiles')
  fi
  if ! is_true "$BACKUP_INCLUDE_DISK_IMAGES"; then
    TAR_EXCLUDES+=('*.iso' '*.img' '*.vmdk' '*.qcow2' '*.vdi' '*.vhd' '*.vhdx')
  fi
  local e
  for e in "${BACKUP_EXTRA_EXCLUDES[@]}"; do
    [ -n "$e" ] && TAR_EXCLUDES+=("$e")
  done
}

# ------------------------------------------------------------- destination ----

validate_dest() {
  [ -n "$BACKUP_DEST" ] || die "未指定备份目标。用法：deepin-v25 backup --dest /mnt/backup"
  [ -d "$BACKUP_DEST" ] || die "备份目录不存在：$BACKUP_DEST（外接磁盘是否已挂载？）"
  DEST="$(realpath -m -- "$BACKUP_DEST")"
  [ -w "$DEST" ] || die "备份目录不可写：$DEST"
  case "$DEST" in
    /|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*|/boot|/boot/*)
      die "不能把备份写到 $DEST" ;;
  esac
  local root_src dest_src
  root_src="$(fs_source /)"
  dest_src="$(fs_source "$DEST")"
  if [ -n "$root_src" ] && [ "$root_src" = "$dest_src" ] && ! is_true "$ALLOW_SAME_FS_BACKUP"; then
    die "备份目标与根分区在同一个文件系统（$root_src），无法用于灾难恢复。请挂载外接磁盘，或设置 ALLOW_SAME_FS_BACKUP=1 仅用于测试。"
  fi
  local fstype
  fstype="$(fs_type "$DEST")"
  if [ "$fstype" = "vfat" ]; then
    if [ "$BACKUP_SPLIT_MB" -gt 3500 ] 2>/dev/null; then
      warn "FAT32 单文件上限 4 GiB，分卷大小改为 3500 MiB。"
      BACKUP_SPLIT_MB=3500
    fi
  fi
  ok "备份目标：$DEST（$(fs_source "$DEST" 2>/dev/null || echo unknown), ${fstype:-unknown}）"
}

make_backup_dir() {
  local base="$DEST/deepin-backup-$(date +%F-%H%M%S)" i=2
  while [ -e "$base" ]; do
    base="$DEST/deepin-backup-$(date +%F-%H%M%S)-$i"
    i=$((i + 1))
  done
  mkdir -p -- "$base" || die "无法创建备份目录：$base"
  chmod 700 -- "$base" 2>/dev/null || true
  printf '%s' "$base"
}

# ------------------------------------------------------------ passphrase ----

prepare_passphrase() {
  local p1 p2 f
  if [ -n "$SECRETS_PASSPHRASE_FILE" ]; then
    [ -r "$SECRETS_PASSPHRASE_FILE" ] || die "无法读取口令文件：$SECRETS_PASSPHRASE_FILE"
    PASSFILE="$SECRETS_PASSPHRASE_FILE"
    local mode
    mode="$(stat -c '%a' "$PASSFILE" 2>/dev/null || echo '')"
    case "$mode" in
      *[1-7]?|*?[1-7]) warn "口令文件权限是 $mode，建议 chmod 600。" ;;
    esac
    return 0
  fi
  [ -t 0 ] || die "需要加密口令：设置 SECRETS_PASSPHRASE_FILE 或在终端运行。"
  printf '私密数据将用 AES256 加密。口令只保存在内存和临时文件中。\n'
  read -r -s -p '加密口令: ' p1 || die "读取口令失败"
  printf '\n'
  read -r -s -p '再次输入: ' p2 || die "读取口令失败"
  printf '\n'
  [ -n "$p1" ] || die "口令不能为空。"
  [ "$p1" = "$p2" ] || die "两次口令不一致。"
  if [ "${#p1}" -lt 8 ]; then
    warn "口令短于 8 个字符，建议使用更长的口令。"
  fi
  f="$(mktemp "${TMPDIR:-/tmp}/deepin-v25-pass.XXXXXX")"
  umask 077
  printf '%s' "$p1" >"$f"
  unset p1 p2
  chmod 600 "$f"
  PASSFILE="$f"
  TEMP_PASSFILE=1
}

cleanup_passphrase() {
  if [ "$TEMP_PASSFILE" -eq 1 ] && [ -n "$PASSFILE" ] && [ -f "$PASSFILE" ]; then
    rm -f -- "$PASSFILE"
  fi
}

# ---------------------------------------------------------------- archive ----

codec_cmd() {
  case "$1" in
    zstd) printf 'zstd' ;;
    gzip|"") printf 'gzip' ;;
    *) die "未知压缩格式：$1" ;;
  esac
}

make_relative_list() {
  local root="$1" abs="$2" rel="$3" p
  : >"$rel"
  while IFS= read -r -d '' p; do
    if [ "$p" = "$root" ]; then
      printf '.\0' >>"$rel"
    elif [ "$root" = "/" ]; then
      printf '%s\0' "${p#/}" >>"$rel"
    else
      case "$p" in
        "$root"/*) printf '%s\0' "${p#"$root"/}" >>"$rel" ;;
        *)
          printf 'make_relative_list: %s 不在 %s 下\n' "$p" "$root" >&2
          return 1
          ;;
      esac
    fi
  done <"$abs"
}

write_archive() {
  local kind="$1" user="$2" base="$3" cwd="$4" abslist="$5" encrypt="$6"
  local rel="$WORK/rel-${base}.list"
  local final="$DEST/$base"
  local prefix="$DEST/$base.part-"
  local codec
  codec="$(codec_cmd "$BACKUP_COMPRESS")"

  if list_empty "$abslist"; then
    return 0
  fi
  if [ "$encrypt" -eq 1 ] && [ -z "$PASSFILE" ]; then
    die "加密归档缺少口令：$base"
  fi
  make_relative_list "$cwd" "$abslist" "$rel"
  [ -s "$rel" ] || return 0

  local -a tar_cmd=(
    tar --create --file - --sparse --acls --xattrs
    --warning=no-file-changed --null --verbatim-files-from
  )
  local pat
  local -a tar_excludes=("${TAR_EXCLUDES[@]}")
  if [ "$encrypt" -eq 1 ]; then
    tar_excludes=("${TAR_EXCLUDES_SECRET[@]}")
  elif [ "${kind%%-*}" = "system" ]; then
    tar_excludes+=("${TAR_EXCLUDES_SYSTEM[@]}")
  fi
  for pat in "${tar_excludes[@]}"; do
    tar_cmd+=("--exclude=$pat")
  done
  if is_subpath_lexical "$DEST" "$cwd"; then
    local dest_rel="${DEST#"$cwd"/}"
    [ -n "$dest_rel" ] && tar_cmd+=("--exclude=$dest_rel")
  fi
  tar_cmd+=(-C "$cwd" --files-from "$rel")

  local -a st=()
  local rc=0
  printf '  写入 %s ...\n' "$base"
  set +e
  if [ "$encrypt" -eq 1 ]; then
    if [ "$codec" = "zstd" ]; then
      "${tar_cmd[@]}" | zstd -T0 -c | \
        gpg --batch --yes --quiet --symmetric --cipher-algo AES256 \
          --pinentry-mode loopback --passphrase-file "$PASSFILE" --output - | \
        split -b "$((BACKUP_SPLIT_MB * 1024 * 1024))" -d -a 3 - "$prefix"
    else
      "${tar_cmd[@]}" | gzip -c | \
        gpg --batch --yes --quiet --symmetric --cipher-algo AES256 \
          --pinentry-mode loopback --passphrase-file "$PASSFILE" --output - | \
        split -b "$((BACKUP_SPLIT_MB * 1024 * 1024))" -d -a 3 - "$prefix"
    fi
  else
    if [ "$codec" = "zstd" ]; then
      "${tar_cmd[@]}" | zstd -T0 -c | \
        split -b "$((BACKUP_SPLIT_MB * 1024 * 1024))" -d -a 3 - "$prefix"
    else
      "${tar_cmd[@]}" | gzip -c | \
        split -b "$((BACKUP_SPLIT_MB * 1024 * 1024))" -d -a 3 - "$prefix"
    fi
  fi
  st=("${PIPESTATUS[@]}")
  set -e

  local i
  for i in "${!st[@]}"; do
    if [ "$i" -eq 0 ]; then
      if [ "${st[$i]}" -gt 1 ]; then
        warn "tar 退出码 ${st[$i]}（$base）"
        rc=1
      fi
    elif [ "${st[$i]}" -ne 0 ]; then
      warn "管道第 $((i + 1)) 段退出码 ${st[$i]}（$base）"
      rc=1
    fi
  done
  if [ "$rc" -ne 0 ]; then
    rm -f -- "$prefix"* "$final"
    die "创建归档失败：$base"
  fi

  local -a parts=()
  mapfile -d '' -t parts < <(find "$DEST" -maxdepth 1 -type f -name "$(basename "$base").part-*" -print0 | sort -z)
  if [ "${#parts[@]}" -eq 0 ]; then
    die "归档没有生成：$base"
  elif [ "${#parts[@]}" -eq 1 ]; then
    mv -- "${parts[0]}" "$final"
    parts=("$final")
  fi

  local total=0 f size
  for f in "${parts[@]}"; do
    size="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
    total=$((total + size))
    printf '%s  %s\n' "$(sha256sum -- "$f" | awk '{print $1}')" "$(basename "$f")" >>"$DEST/checksums.sha256"
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$kind" "$user" "$base" "$codec" "$encrypt" "${#parts[@]}" "$total" >>"$ARCHIVES_TSV"
  ok "$base（$(human_size "$total")，${#parts[@]} 个文件）"
}

# ------------------------------------------------------------- preflight ----

check_dest_space() {
  local avail estimate
  avail="$(disk_avail_bytes "$DEST")"
  if [ -n "$avail" ] && [ "$avail" -lt $((2 * 1024 * 1024 * 1024)) ]; then
    die "备份目标可用空间不足 2 GiB（$(human_size "$avail")）。"
  fi
  estimate="$1"
  if [ -n "$avail" ] && [ "$estimate" -gt 0 ]; then
    if [ "$estimate" -gt $((avail * 8 / 10)) ]; then
      warn "待备份数据约 $(human_size "$estimate")，目标可用 $(human_size "$avail")；压缩后可能放不下。"
    fi
  fi
}

# ------------------------------------------------------------- hooks --------

run_hooks() {
  local phase="$1" dir h
  is_true "$BACKUP_HOOKS" || return 0
  dir="$REPO_ROOT/hooks/${phase}.d"
  [ -d "$dir" ] || return 0
  for h in "$dir"/*.sh; do
    [ -f "$h" ] || continue
    [ -x "$h" ] || { warn "跳过不可执行的 hook：$h"; continue; }
    printf '运行 hook：%s\n' "$(basename "$h")"
    if DEEPIN_BACKUP_DIR="$DEST" DEEPIN_BACKUP_USERS="$WORK/users.txt" \
       DEEPIN_BACKUP_EXTRA_DIR="$DEST/extra" "$h"; then
      ok "hook 完成：$(basename "$h")"
    else
      warn "hook 失败：$(basename "$h")（继续备份其余数据）"
    fi
  done
}

# --------------------------------------------------------------- backup -----

add_classified_path() {
  local path="$1" home="$2" plain="$3" secret="$4"
  if is_secret_path "$path" "$home"; then
    list_add_path "$secret" "$path"
  else
    list_add_path "$plain" "$path"
  fi
}

add_user_scanned_path() {
  local path="$1" user="$2" home="$3" plain="$4" secret="$5"
  local target
  if [ -L "$path" ]; then
    if target="$(realpath -e -- "$path" 2>/dev/null)"; then
      if [ "$target" != "$home" ] && { [ -d "$target" ] || [ -f "$target" ]; }; then
        if is_subpath_lexical "$target" "$home"; then
          warn "$user: $path 是符号链接，同时备份链接和目标：$target"
          add_classified_path "$target" "$home" "$plain" "$secret"
        else
          warn "$user: $path 的链接目标在 HOME 之外，归入系统归档（恢复需 --system）：$target"
          list_add_path "$WORK/lists/system-plain" "$target"
        fi
      else
        warn "$user: $path 链接到不支持的目标，只备份链接本身。"
      fi
    else
      warn "$user: $path 是断链，只备份链接本身。"
    fi
    list_add_path "$plain" "$path"
  elif is_subpath_lexical "$path" "$home"; then
    add_classified_path "$path" "$home" "$plain" "$secret"
  else
    warn "$user: 标准目录在 HOME 之外，归入系统归档（恢复需 --system）：$path"
    list_add_path "$WORK/lists/system-plain" "$path"
  fi
}

prepare_lists() {
  local users_file="$WORK/users.txt"
  local user home uid plain secret path p
  local -a paths=()
  : >"$users_file"
  : >"$WORK/lists/system-plain"
  : >"$WORK/lists/system-secret"

  resolve_backup_users >"$WORK/user-names.txt"
  chmod 600 "$WORK/user-names.txt"
  if [ ! -s "$WORK/user-names.txt" ]; then
    die "没有找到要备份的用户（BACKUP_USERS=$BACKUP_USERS）。"
  fi

  while IFS= read -r user; do
    [ -n "$user" ] || continue
    home="$(user_home "$user")"
    uid="$(user_uid "$user")"
    printf '%s\t%s\t%s\n' "$user" "$home" "$uid" >>"$users_file"
    plain="$WORK/lists/plain-$user"
    secret="$WORK/lists/secret-$user"
    : >"$plain"
    : >"$secret"

    while IFS= read -r p; do
      [ -n "$p" ] && add_user_scanned_path "$p" "$user" "$home" "$plain" "$secret"
    done < <(user_standard_paths "$home")

    while IFS= read -r p; do
      [ -n "$p" ] && list_add_path "$secret" "$p"
    done < <(user_known_secret_paths "$home")

    if [ -d "$home/.config" ] && ! is_true "$SECRETS_INCLUDE_CONFIG"; then
      warn "$user: 未加密 ~/.config（SECRETS_INCLUDE_CONFIG=0），其中的应用令牌可能以明文备份。"
    fi
  done <"$WORK/user-names.txt"

  for p in "${BACKUP_EXTRA_PATHS[@]}"; do
    [ -n "$p" ] || continue
    local was_link=0
    [ -L "$p" ] && was_link=1
    path="$(realpath -m -- "$p")"
    [ -e "$path" ] || [ -L "$path" ] || { warn "指定路径不存在，跳过：$p"; continue; }
    [ "$path" = "/" ] && die "拒绝把整个根目录作为额外路径。"
    [ "$was_link" -eq 1 ] && warn "额外路径是符号链接，按目标备份：$p -> $path"

    local matched=0
    while IFS=$'\t' read -r user home uid; do
      if is_subpath_lexical "$path" "$home"; then
        matched=1
        if is_secret_path "$path" "$home"; then
          list_add_path "$WORK/lists/secret-$user" "$path"
        else
          list_add_path "$WORK/lists/plain-$user" "$path"
        fi
        break
      fi
    done <"$users_file"
    if [ "$matched" -eq 0 ]; then
      list_add_path "$WORK/lists/system-plain" "$path"
    fi
  done

  while IFS=$'\t' read -r user home uid; do
    plain="$WORK/lists/plain-$user"
    secret="$WORK/lists/secret-$user"
    if [ -s "$plain" ]; then
      while IFS= read -r p; do
        find_secret_files "$p" "$secret"
      done < <(
        while IFS= read -r -d '' p; do printf '%s\n' "$p"; done <"$plain"
      )
    fi
    find_secret_files "$home/.local/share/keyrings" "$secret"
    info "$user: 明文 $(list_count "$plain") 项，加密 $(list_count "$secret") 项"
  done <"$users_file"

  if [ -s "$WORK/lists/system-plain" ]; then
    while IFS= read -r p; do
      find_secret_files "$p" "$WORK/lists/system-secret"
    done < <(
      while IFS= read -r -d '' p; do printf '%s\n' "$p"; done <"$WORK/lists/system-plain"
    )
    while IFS= read -r p; do
      local covered=0 q
      while IFS= read -r -d '' q; do
        is_subpath_lexical "$p" "$q" && { covered=1; break; }
      done <"$WORK/lists/system-plain"
      if [ "$covered" -eq 1 ]; then
        list_add_path "$WORK/lists/system-secret" "$p"
        list_remove_exact "$WORK/lists/system-plain" "$p"
      fi
    done < <(system_protected_paths)
  fi

  if ! is_true "$ENCRYPT_SECRETS"; then
    local total=0
    while IFS=$'\t' read -r user home uid; do
      total=$((total + $(list_count "$WORK/lists/secret-$user")))
    done <"$users_file"
    total=$((total + $(list_count "$WORK/lists/system-secret")))
    if [ "$total" -gt 0 ] && ! is_true "$ALLOW_UNENCRYPTED_SECRETS"; then
      die "存在私密数据但 ENCRYPT_SECRETS=0。设置 ENCRYPT_SECRETS=1，或显式加 --allow-unencrypted-secrets。"
    fi
  fi
}

print_backup_plan() {
  local user home uid
  printf '\n备份计划\n'
  while IFS=$'\t' read -r user home uid; do
    printf '\n用户 %s（%s）\n' "$user" "$home"
    printf '明文归档：\n'; list_print "$WORK/lists/plain-$user"
    printf '加密归档：\n'; list_print "$WORK/lists/secret-$user"
  done <"$WORK/users.txt"
  if [ -s "$WORK/lists/system-plain" ]; then
    printf '\n系统路径（明文，恢复需 --system）：\n'; list_print "$WORK/lists/system-plain"
  fi
  if [ -s "$WORK/lists/system-secret" ]; then
    printf '\n系统路径（加密，恢复需 --system）：\n'; list_print "$WORK/lists/system-secret"
  fi
}

copy_pre_state_if_any() {
  local pre="$STATE_DIR/pre"
  if [ -d "$pre" ]; then
    mkdir -p "$DEST/pre-upgrade-state" 2>/dev/null || return 0
    cp -a "$pre"/. "$DEST/pre-upgrade-state"/ 2>/dev/null || \
      cp -r "$pre"/. "$DEST/pre-upgrade-state"/ 2>/dev/null || true
  fi
}

write_manifest() {
  local finished epoch
  finished="$(date '+%F %T %z')"
  epoch="$(date +%s)"
  cat >"$DEST/manifest.env" <<EOF
BACKUP_FORMAT=1
BACKUP_TOOL_VERSION=$TOOL_VERSION
BACKUP_CREATED="$finished"
BACKUP_FINISHED_EPOCH=$epoch
BACKUP_HOST="$(hostname 2>/dev/null || echo unknown)"
BACKUP_OS="$(os_pretty)"
BACKUP_KERNEL="$(uname -r)"
BACKUP_CODEC=$BACKUP_COMPRESS
BACKUP_ENCRYPTED=$ENCRYPT_SECRETS
BACKUP_SPLIT_MB=$BACKUP_SPLIT_MB
BACKUP_DIR="$DEST"
EOF
  {
    printf '# Deepin 23 -> 25 backup\n\n'
    printf -- '- 时间：%s\n' "$finished"
    printf -- '- 主机：%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf -- '- 系统：%s\n' "$(os_pretty)"
    printf -- '- 工具版本：%s\n' "$TOOL_VERSION"
    printf -- '- 压缩：%s\n' "$BACKUP_COMPRESS"
    printf -- '- 私密数据加密：%s\n' "$(is_true "$ENCRYPT_SECRETS" && echo yes || echo no)"
    printf -- '- 分卷：%s MiB\n\n' "$BACKUP_SPLIT_MB"
    printf '## 用户\n\n'
    while IFS=$'\t' read -r user home uid; do
      printf -- '- %s（UID %s，HOME %s）\n' "$user" "$uid" "$home"
    done <"$WORK/users.txt"
    printf '\n## 归档\n\n'
    if [ -s "$ARCHIVES_TSV" ]; then
      while IFS=$'\t' read -r kind user base codec enc parts total; do
        printf -- '- %s %s: `%s`（%s 字节，%s 个分卷）\n' "$kind" "$user" "$base" "$total" "$parts"
      done <"$ARCHIVES_TSV"
    fi
    printf '\n恢复：sudo bash %s/restore-backup.sh\n' "$DEST"
    printf '加 --system 才会恢复系统额外路径。\n'
  } >"$DEST/MANIFEST.md"
}

install_restore_tool() {
  mkdir -p "$DEST/tool"
  if have rsync; then
    rsync -a --exclude '.git/' --exclude 'tests/' "$REPO_ROOT"/ "$DEST/tool"/ || die "复制恢复工具失败"
  else
    cp -a "$REPO_ROOT"/. "$DEST/tool"/ || die "复制恢复工具失败"
    rm -rf -- "$DEST/tool/.git" "$DEST/tool/tests"
  fi
  cat >"$DEST/restore-backup.sh" <<'EOF'
#!/usr/bin/env bash
# Restore this backup after a fresh Deepin 25 installation.
#   sudo bash restore-backup.sh            # user data only
#   sudo bash restore-backup.sh --system   # also restore extra system paths
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$HERE/tool/bin/deepin-v25" restore --from "$HERE" "$@"
  fi
  echo "请用 root 运行：sudo bash $0" >&2
  exit 1
fi
exec bash "$HERE/tool/bin/deepin-v25" restore --from "$HERE" "$@"
EOF
  chmod +x "$DEST/restore-backup.sh" 2>/dev/null || true
}

verify_archives() {
  is_true "$BACKUP_VERIFY" || { warn "已跳过归档校验（BACKUP_VERIFY=0）。"; return 0; }
  section "校验备份"
  ( cd "$DEST" && sha256sum -c checksums.sha256 ) || die "校验和失败，备份不完整。"
  local kind user base codec enc parts total f
  while IFS=$'\t' read -r kind user base codec enc parts total; do
    local -a parts_files=()
    mapfile -d '' -t parts_files < <(find "$DEST" -maxdepth 1 -type f -name "$(basename "$base").part-*" -print0 | sort -z)
    if [ "${#parts_files[@]}" -eq 0 ]; then
      parts_files=("$DEST/$base")
    fi
    printf '  读取测试 %s ...\n' "$base"
    set +e
    if [ "$enc" -eq 1 ]; then
      cat -- "${parts_files[@]}" | \
        gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$PASSFILE" -d | \
        { if [ "$codec" = "zstd" ]; then zstd -dc; else gzip -dc; fi; } | \
        tar -tf - >/dev/null
    else
      cat -- "${parts_files[@]}" | \
        { if [ "$codec" = "zstd" ]; then zstd -dc; else gzip -dc; fi; } | \
        tar -tf - >/dev/null
    fi
    local vrc=$?
    set -e
    [ "$vrc" -eq 0 ] || die "归档无法读取：$base"
  done <"$ARCHIVES_TSV"
  ok "所有归档均可读取。"
}

cmd_backup() {
  local arg
  while [ $# -gt 0 ]; do
    case "$1" in
      --dest) [ $# -ge 2 ] || die "--dest 需要参数"; BACKUP_DEST="$2"; shift 2 ;;
      --dest=*) BACKUP_DEST="${1#*=}"; shift ;;
      --users) [ $# -ge 2 ] || die "--users 需要参数"; BACKUP_USERS="$2"; shift 2 ;;
      --include) [ $# -ge 2 ] || die "--include 需要参数"; BACKUP_EXTRA_PATHS+=("$2"); shift 2 ;;
      --exclude) [ $# -ge 2 ] || die "--exclude 需要参数"; BACKUP_EXTRA_EXCLUDES+=("$2"); shift 2 ;;
      --passphrase-file) [ $# -ge 2 ] || die "--passphrase-file 需要参数"; SECRETS_PASSPHRASE_FILE="$2"; shift 2 ;;
      --no-verify) BACKUP_VERIFY=0; shift ;;
      --allow-same-fs) ALLOW_SAME_FS_BACKUP=1; shift ;;
      --allow-unencrypted-secrets) ALLOW_UNENCRYPTED_SECRETS=1; shift ;;
      *) die "未知参数：$1" ;;
    esac
  done

  require_root
  setup_logging backup
  need_cmd tar gzip sha256sum split find
  if is_true "$ENCRYPT_SECRETS"; then need_cmd gpg; fi
  if [ "$BACKUP_COMPRESS" = "zstd" ]; then need_cmd zstd; fi
  is_true "$ENCRYPT_SECRETS" || warn "私密数据将不加密（ENCRYPT_SECRETS=0）。"

  case "$BACKUP_COMPRESS" in
    auto|"")
      if have zstd; then BACKUP_COMPRESS="zstd"; else BACKUP_COMPRESS="gzip"; fi ;;
    gzip|zstd) ;;
    *) die "BACKUP_COMPRESS 只能是 gzip、zstd 或 auto。" ;;
  esac

  validate_dest
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/deepin-v25-backup.XXXXXX")"
  trap 'cleanup_passphrase; rm -rf -- "$WORK"' EXIT
  mkdir -p "$WORK/lists"
  build_tar_excludes

  prepare_lists
  check_dest_space "$(all_lists_total_bytes)"
  print_backup_plan

  if is_true "$DRY_RUN"; then
    warn "dry-run：未写入任何备份文件。"
    return 0
  fi
  if ! confirm "开始备份到 $DEST？"; then
    die "已取消。"
  fi

  local destdir
  destdir="$(make_backup_dir)"
  printf '备份目录：%s\n' "$destdir"

  local -a secret_users=()
  local user home uid
  while IFS=$'\t' read -r user home uid; do
    [ -s "$WORK/lists/secret-$user" ] && secret_users+=("$user")
  done <"$WORK/users.txt"
  if [ "${#secret_users[@]}" -gt 0 ] || [ -s "$WORK/lists/system-secret" ]; then
    if is_true "$ENCRYPT_SECRETS"; then
      prepare_passphrase
    else
      warn "跳过私密数据加密。"
    fi
  fi

  DEST="$destdir"
  ARCHIVES_TSV="$DEST/archives.tsv"
  : >"$ARCHIVES_TSV"
  : >"$DEST/checksums.sha256"
  mkdir -p "$DEST/extra"
  run_hooks backup-pre

  local codec_ext
  case "$BACKUP_COMPRESS" in zstd) codec_ext="zst" ;; *) codec_ext="gz" ;; esac

  while IFS=$'\t' read -r user home uid; do
    [ -n "$user" ] || continue
    local safe
    safe="$(printf '%s' "$user" | tr -c 'A-Za-z0-9._-' '_')-$uid"
    if [ -s "$WORK/lists/plain-$user" ]; then
      write_archive "home" "$user" "home-$safe.tar.$codec_ext" "$home" "$WORK/lists/plain-$user" 0
    fi
    if [ -s "$WORK/lists/secret-$user" ]; then
      local enc=0 name="secrets-$safe.tar.$codec_ext"
      if is_true "$ENCRYPT_SECRETS"; then enc=1; name="$name.gpg"; fi
      write_archive "secrets" "$user" "$name" "$home" "$WORK/lists/secret-$user" "$enc"
    fi
  done <"$WORK/users.txt"

  if [ -s "$WORK/lists/system-plain" ]; then
    write_archive "system" "-" "system.tar.$codec_ext" "/" "$WORK/lists/system-plain" 0
  fi
  if [ -s "$WORK/lists/system-secret" ]; then
    local enc=0 name="secrets-system.tar.$codec_ext"
    if is_true "$ENCRYPT_SECRETS"; then enc=1; name="$name.gpg"; fi
    write_archive "secrets-system" "-" "$name" "/" "$WORK/lists/system-secret" "$enc"
  fi

  copy_pre_state_if_any
  install_restore_tool
  run_hooks backup-post
  verify_archives
  write_manifest
  ensure_state
  printf '%s\n' "$DEST" >"$STATE_DIR/last-backup"
  chmod 600 "$STATE_DIR/last-backup" 2>/dev/null || true

  section "备份完成"
  printf '目录：%s\n' "$DEST"
  printf '大小：%s\n' "$(du -sh -- "$DEST" 2>/dev/null | cut -f1)"
  printf '恢复：sudo bash %s/restore-backup.sh\n' "$DEST"
  printf '提示：把恢复口令/口令文件与备份盘分开保存。\n'
}

# ---------------------------------------------------------------- scan ------

size_of() {
  local p="$1" n
  if have timeout; then
    n="$(timeout 20 du -sx --block-size=1 -- "$p" 2>/dev/null | cut -f1)"
  else
    n="$(du -sx --block-size=1 -- "$p" 2>/dev/null | cut -f1)"
  fi
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

cmd_scan() {
  require_root
  setup_logging scan
  ensure_state
  local plan="$STATE_DIR/backup-paths.suggested.conf"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/deepin-v25-scan.XXXXXX")"
  trap 'rm -f -- "$tmp"' EXIT

  section "扫描用户数据"
  printf '只读扫描：不会移动或修改任何文件。\n\n'

  local user home uid p rel size line
  while IFS= read -r user; do
    home="$(user_home "$user")"
    printf '用户 %s（%s）\n' "$user" "$home"
    {
      for key in DOCUMENTS DESKTOP PICTURES; do
        p="$(xdg_dir "$home" "$key")"
        [ -n "$p" ] && printf '%s\t%s\t默认包含\n' "$(size_of "$p")" "$p"
      done
      p="$(xdg_dir "$home" DOWNLOAD)"
      [ -n "$p" ] && printf '%s\t%s\t未包含（BACKUP_INCLUDE_DOWNLOADS=1 可加入）\n' "$(size_of "$p")" "$p"
      for key in MUSIC VIDEOS; do
        p="$(xdg_dir "$home" "$key")"
        [ -n "$p" ] && printf '%s\t%s\t未包含（BACKUP_INCLUDE_MEDIA=1 可加入）\n' "$(size_of "$p")" "$p"
      done
      for rel in git wwwroot node_www projects src code repos workspace workspaces dev develop go/src IdeaProjects AndroidStudioProjects .local/share/fonts .local/share/applications; do
        p="$home/$rel"
        [ -e "$p" ] && printf '%s\t%s\t默认包含\n' "$(size_of "$p")" "$p"
      done
      [ -d "$home/.config" ] && printf '%s\t%s\t加密包含\n' "$(size_of "$home/.config")" "$home/.config"
      for p in "$home/.ssh" "$home/.gnupg" "$home/.password-store"; do
        [ -e "$p" ] && printf '%s\t%s\t加密包含\n' "$(size_of "$p")" "$p"
      done
    } | sort -t $'\t' -k1,1nr | while IFS=$'\t' read -r bytes p note; do
      printf '  %-10s %s  [%s]\n' "$(human_size "$bytes")" "$p" "$note"
    done

    printf '  其他顶层目录（仅报告，不自动包含）：\n'
    {
      while IFS= read -r p; do
        [ -d "$p" ] || continue
        rel="${p#"$home"/}"
        case "$rel" in
          .*|Documents|文档|Desktop|桌面|Pictures|图片|Downloads|下载|Music|音乐|Videos|视频|git|wwwroot|node_www|projects|src|code|repos|workspace|workspaces|dev|develop) continue ;;
        esac
        size="$(size_of "$p")"
        [ "$size" -ge $((20 * 1024 * 1024)) ] && printf '%s\t%s\n' "$size" "$p"
      done < <(find "$home" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)
    } | sort -t $'\t' -k1,1nr | head -15 | while IFS=$'\t' read -r size p; do
      printf '  %-10s %s  [建议：BACKUP_EXTRA_PATHS]\n' "$(human_size "$size")" "$p"
      printf '%s\t%s\n' "$size" "$p" >>"$tmp"
    done

    printf '  其他 git 仓库：\n'
    {
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in
          "$home/git"|"$home/git/"*|"$home/wwwroot"|"$home/wwwroot/"*|"$home/node_www"|"$home/node_www/"*|\
          "$home/projects"|"$home/projects/"*|"$home/src"|"$home/src/"*|"$home/code"|"$home/code/"*|\
          "$home/repos"|"$home/repos/"*|"$home/workspace"|"$home/workspace/"*|"$home/workspaces"|"$home/workspaces/"*|\
          "$home/dev"|"$home/dev/"*|"$home/develop"|"$home/develop/"*|"$home/go/src"|"$home/go/src/"*|\
          "$home/IdeaProjects"|"$home/IdeaProjects/"*|"$home/AndroidStudioProjects"|"$home/AndroidStudioProjects/"*) continue ;;
        esac
        printf '%s\t%s\n' "$(size_of "$p")" "$p"
      done < <(find "$home" -maxdepth 4 -type d -name .git -prune -printf '%h\n' 2>/dev/null | sort -u)
    } | sort -t $'\t' -k1,1nr | head -20 | while IFS=$'\t' read -r bytes p; do
      printf '  %-10s %s  [建议：BACKUP_EXTRA_PATHS]\n' "$(human_size "$bytes")" "$p"
      printf '%s\t%s\n' "$bytes" "$p" >>"$tmp"
    done

    printf '  大文件（>500 MiB）：\n'
    find "$home" -xdev -type f -size +500M -printf '%s\t%p\n' 2>/dev/null | \
      sort -rn | head -10 | while IFS=$'\t' read -r size p; do
        printf '  %-10s %s\n' "$(human_size "$size")" "$p"
      done

    local wx
    for wx in "$home/Documents/xwechat_files" "$home/xwechat_files" "$home/Documents/WeChat Files" "$home/WeChat Files"; do
      if [ -d "$wx" ]; then
        warn "检测到微信数据（默认不备份）：$wx"
      fi
    done
    printf '\n'
  done < <(resolve_backup_users)

  section "检测到的服务"
  if have docker && systemctl is-active --quiet docker 2>/dev/null; then
    docker ps --format '  {{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null || true
    printf '  数据库容器建议在 hooks/backup-pre.d/ 中导出后备份。\n'
  else
    printf '  Docker 未运行或未安装。\n'
  fi

  {
    printf '# Generated by %s scan on %s\n' "$TOOL_NAME" "$(date '+%F %T')"
    printf '# Review before use. Only paths listed here are extra; the common\n'
    printf '# paths shown as 默认包含 are already backed up automatically.\n'
    printf '# Copy the entries you want to /etc/deepin-v23-to-v25.conf.\n\n'
    printf 'BACKUP_EXTRA_PATHS+=(\n'
    awk -F'\t' '!seen[$2]++' "$tmp" | sort -t $'\t' -k1,1nr | while IFS=$'\t' read -r bytes p; do
      printf '  # %s  %s\n  # "%s"\n' "$(human_size "$bytes")" "$p" "$p"
    done
    printf ')\n\n# 可选开关：\n# BACKUP_INCLUDE_DOWNLOADS=1\n# BACKUP_INCLUDE_MEDIA=1\n'
  } >"$plan"
  chmod 600 "$plan" 2>/dev/null || true

  section "扫描结果"
  printf '建议配置：%s\n' "$plan"
  printf '查看并取消注释需要的路径，然后复制到 /etc/deepin-v23-to-v25.conf。\n'
  printf '备份命令示例：sudo deepin-v25 backup --dest /media/你的磁盘/backup\n'
}
