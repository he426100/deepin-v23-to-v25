#!/usr/bin/env bash
# Restore a backup made by "deepin-v25 backup".
# shellcheck shell=bash

RESTORE_DIR=""
RESTORE_PASSFILE=""
RESTORE_TEMP_PASS=0
declare -A USER_MAP=()

manifest_get() {
  local key="$1"
  sed -n "s/^${key}=//p" "$RESTORE_DIR/manifest.env" 2>/dev/null | tail -1 | sed 's/^"//; s/"$//'
}

restore_cleanup() {
  if [ "$RESTORE_TEMP_PASS" -eq 1 ] && [ -n "$RESTORE_PASSFILE" ] && [ -f "$RESTORE_PASSFILE" ]; then
    rm -f -- "$RESTORE_PASSFILE"
  fi
}

validate_archive_name() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) die "非法归档名：$1" ;;
  esac
}

restore_stream() {
  local base="$1"
  local -a parts=()
  validate_archive_name "$base"
  mapfile -d '' -t parts < <(
    find "$RESTORE_DIR" -maxdepth 1 -type f -name "$(basename "$base").part-*" -print0 | sort -z
  )
  if [ "${#parts[@]}" -eq 0 ]; then
    parts=("$RESTORE_DIR/$base")
  fi
  cat -- "${parts[@]}"
}

restore_decode_cmd() {
  case "$1" in
    zstd) printf 'zstd -dc' ;;
    gzip|"") printf 'gzip -dc' ;;
    *) die "未知压缩格式：$1" ;;
  esac
}

prepare_restore_passphrase() {
  local p f mode
  if [ -n "$RESTORE_PASSFILE" ]; then
    [ -r "$RESTORE_PASSFILE" ] || die "无法读取口令文件：$RESTORE_PASSFILE"
    return 0
  fi
  [ -t 0 ] || die "备份已加密，需要 --passphrase-file FILE 或在终端输入口令。"
  read -r -s -p '备份加密口令: ' p || die "读取口令失败"
  printf '\n'
  [ -n "$p" ] || die "口令为空。"
  f="$(mktemp "${TMPDIR:-/tmp}/deepin-v25-restore-pass.XXXXXX")"
  umask 077
  printf '%s' "$p" >"$f"
  unset p
  chmod 600 "$f"
  RESTORE_PASSFILE="$f"
  RESTORE_TEMP_PASS=1
}

validate_members() {
  local base="$1" enc="$2" codec="$3"
  local -a st=()
  local i rc=0
  printf '  检查归档路径 %s ...\n' "$base"
  set +e
  if [ "$enc" -eq 1 ]; then
    restore_stream "$base" | \
      gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$RESTORE_PASSFILE" -d | \
      eval "$(restore_decode_cmd "$codec")" | \
      tar -tf - | \
      awk 'BEGIN{bad=0}
           /^\//{print "  拒绝绝对路径: "$0; bad=1}
           /(^|\/)\.\.(\/|$)/{print "  拒绝上级路径: "$0; bad=1}
           END{exit bad}'
  else
    restore_stream "$base" | \
      eval "$(restore_decode_cmd "$codec")" | \
      tar -tf - | \
      awk 'BEGIN{bad=0}
           /^\//{print "  拒绝绝对路径: "$0; bad=1}
           /(^|\/)\.\.(\/|$)/{print "  拒绝上级路径: "$0; bad=1}
           END{exit bad}'
  fi
  st=("${PIPESTATUS[@]}")
  set -e
  for i in "${!st[@]}"; do
    [ "${st[$i]}" -eq 0 ] || rc=1
  done
  [ "$rc" -eq 0 ] || die "归档路径检查失败：$base"
}

extract_home_archive() {
  local base="$1" enc="$2" codec="$3" user="$4" home="$5"
  local group
  group="$(id -gn "$user" 2>/dev/null || echo "$user")"
  local -a st=()
  local i rc=0
  printf '  恢复用户数据 %s -> %s ...\n' "$base" "$home"
  set +e
  if [ "$enc" -eq 1 ]; then
    restore_stream "$base" | \
      gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$RESTORE_PASSFILE" -d | \
      eval "$(restore_decode_cmd "$codec")" | \
      tar -x -C "$home" -p --owner="$user" --group="$group"
  else
    restore_stream "$base" | \
      eval "$(restore_decode_cmd "$codec")" | \
      tar -x -C "$home" -p --owner="$user" --group="$group"
  fi
  st=("${PIPESTATUS[@]}")
  set -e
  for i in "${!st[@]}"; do
    if [ "$i" -eq $(( ${#st[@]} - 1 )) ]; then
      [ "${st[$i]}" -le 1 ] || rc=1
    else
      [ "${st[$i]}" -eq 0 ] || rc=1
    fi
  done
  [ "$rc" -eq 0 ] || die "恢复失败：$base"
}

extract_system_archive() {
  local base="$1" enc="$2" codec="$3"
  local -a st=()
  local i rc=0
  printf '  恢复系统路径 %s -> / ...\n' "$base"
  set +e
  if [ "$enc" -eq 1 ]; then
    restore_stream "$base" | \
      gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$RESTORE_PASSFILE" -d | \
      eval "$(restore_decode_cmd "$codec")" | \
      tar -x -C / -p --same-owner
  else
    restore_stream "$base" | \
      eval "$(restore_decode_cmd "$codec")" | \
      tar -x -C / -p --same-owner
  fi
  st=("${PIPESTATUS[@]}")
  set -e
  for i in "${!st[@]}"; do
    if [ "$i" -eq $(( ${#st[@]} - 1 )) ]; then
      [ "${st[$i]}" -le 1 ] || rc=1
    else
      [ "${st[$i]}" -eq 0 ] || rc=1
    fi
  done
  [ "$rc" -eq 0 ] || die "恢复失败：$base"
}

cmd_restore() {
  local use_system=0 list_only=0 verify=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) [ $# -ge 2 ] || die "--from 需要参数"; RESTORE_DIR="$2"; shift 2 ;;
      --from=*) RESTORE_DIR="${1#*=}"; shift ;;
      --system) use_system=1; shift ;;
      --list) list_only=1; shift ;;
      --no-verify) verify=0; shift ;;
      --passphrase-file) [ $# -ge 2 ] || die "--passphrase-file 需要参数"; RESTORE_PASSFILE="$2"; shift 2 ;;
      --map)
        [ $# -ge 2 ] || die "--map 需要参数，例如 --map oldname=newname"
        local spec="$2" old new
        old="${spec%%=*}"; new="${spec#*=}"
        [ -n "$old" ] && [ -n "$new" ] && [ "$old" != "$new" ] || die "无效映射：$spec"
        USER_MAP["$old"]="$new"
        shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done

  require_root
  setup_logging restore
  [ -n "$RESTORE_DIR" ] || die "用法：deepin-v25 restore --from /media/disk/deepin-backup-..."
  [ -d "$RESTORE_DIR" ] || die "备份目录不存在：$RESTORE_DIR"
  RESTORE_DIR="$(realpath -m -- "$RESTORE_DIR")"
  [ -f "$RESTORE_DIR/manifest.env" ] || die "不是有效备份目录（缺少 manifest.env）：$RESTORE_DIR"
  [ -f "$RESTORE_DIR/archives.tsv" ] || die "备份不完整（缺少 archives.tsv）。"
  trap 'restore_cleanup' EXIT

  need_cmd tar gzip sha256sum awk find
  local codec
  codec="$(manifest_get BACKUP_CODEC)"
  case "$codec" in
    auto|"") codec="gzip" ;;
    zstd) need_cmd zstd ;;
    gzip) ;;
    *) die "未知压缩格式：$codec" ;;
  esac

  section "备份信息"
  printf '目录    : %s\n' "$RESTORE_DIR"
  printf '时间    : %s\n' "$(manifest_get BACKUP_CREATED)"
  printf '系统    : %s\n' "$(manifest_get BACKUP_OS)"
  printf '压缩    : %s\n' "$codec"
  printf '加密    : %s\n' "$(manifest_get BACKUP_ENCRYPTED)"

  if [ "$verify" -eq 1 ]; then
    [ -f "$RESTORE_DIR/checksums.sha256" ] || die "缺少 checksums.sha256；确认备份完整，或用 --no-verify。"
    section "校验文件"
    ( cd "$RESTORE_DIR" && sha256sum -c checksums.sha256 ) || die "校验失败，不要继续恢复。"
  fi

  local -a rows=()
  local kind user base acodec enc parts total
  local need_pass=0 skipped_system=0
  while IFS=$'\t' read -r kind user base acodec enc parts total; do
    [ -n "$kind" ] || continue
    case "$kind" in
      system|secrets-system)
        if [ "$use_system" -eq 0 ]; then
          skipped_system=$((skipped_system + 1))
          continue
        fi
        ;;
    esac
    rows+=("$kind"$'\t'"$user"$'\t'"$base"$'\t'"$acodec"$'\t'"$enc")
    [ "$enc" -eq 1 ] && need_pass=1
  done <"$RESTORE_DIR/archives.tsv"

  if [ "$skipped_system" -gt 0 ]; then
    warn "--system 未指定，跳过 $skipped_system 个系统归档；系统额外路径未恢复。"
  fi

  if is_true "$DRY_RUN"; then
    section "Dry run"
    printf '将恢复 %s 个归档（未写入任何文件）。\n' "${#rows[@]}"
    return 0
  fi

  if [ "$list_only" -eq 1 ]; then
    section "归档列表"
    printf '%s\n' "${rows[@]}" | awk -F'\t' '{printf "%-14s %-12s %s\n", $1, $2, $3}'
    printf '\n恢复：sudo deepin-v25 restore --from %s [--system] [--map old=new]\n' "$RESTORE_DIR"
    return 0
  fi

  local -A seen_users=()
  local target
  local row
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r kind user base acodec enc <<<"$row"
    case "$kind" in
      home|secrets)
        target="${USER_MAP[$user]:-$user}"
        if ! getent passwd "$target" >/dev/null 2>&1; then
          die "目标用户不存在：$user -> $target。用 --map $user=新用户名 指定。"
        fi
        [ -d "$(user_home "$target")" ] || die "目标用户 $target 的家目录不存在。"
        seen_users["$user"]="$target"
        ;;
    esac
  done

  if [ "$need_pass" -eq 1 ]; then
    need_cmd gpg
    prepare_restore_passphrase
  fi

  if [ "$use_system" -eq 1 ]; then
    warn "将恢复系统额外路径到 /，可能覆盖 /etc 等文件。"
    if ! confirm "继续恢复系统路径？"; then
      die "已取消。"
    fi
  fi

  section "安全检查"
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r kind user base acodec enc <<<"$row"
    validate_members "$base" "$enc" "$acodec"
  done

  if ! confirm "开始恢复？同名文件会被覆盖"; then
    die "已取消。"
  fi

  section "恢复"
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r kind user base acodec enc <<<"$row"
    case "$kind" in
      home|secrets)
        target="${seen_users[$user]}"
        extract_home_archive "$base" "$enc" "$acodec" "$target" "$(user_home "$target")"
        ;;
      system|secrets-system)
        extract_system_archive "$base" "$enc" "$acodec"
        ;;
    esac
  done

  if [ -d "$RESTORE_DIR/extra" ] && [ -n "$(ls -A "$RESTORE_DIR/extra" 2>/dev/null || true)" ]; then
    warn "钩子输出未自动覆盖系统：$RESTORE_DIR/extra"
    printf '  数据库等导出文件请按需手动恢复。\n'
  fi

  section "恢复完成"
  printf '用户数据已恢复到各自家目录。\n'
  if [ "$use_system" -eq 1 ]; then
    printf '系统额外路径已恢复；检查 /etc 下被覆盖的配置。\n'
  elif [ "$skipped_system" -gt 0 ]; then
    printf '系统额外路径未恢复；需要时加 --system。\n'
  fi
  printf '\n建议：\n'
  printf '  1. 检查 shell 配置和 SSH 权限：ls -l ~/.ssh; chmod 700 ~/.ssh; chmod 600 ~/.ssh/id_*\n'
  printf '  2. 重新登录，使 shell/桌面配置生效。\n'
  printf '  3. 数据库、Docker 数据卷需按 hooks 的导出文件另行恢复。\n'
}
