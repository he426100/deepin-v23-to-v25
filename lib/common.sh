#!/usr/bin/env bash
# Shared helpers. Sourced by bin/deepin-v25 and by the libraries.
# shellcheck shell=bash

if [ -z "${REPO_ROOT:-}" ]; then
  REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fi
TOOL_NAME="deepin-v23-to-v25"
if [ -r "$REPO_ROOT/VERSION" ]; then
  TOOL_VERSION="$(head -n 1 "$REPO_ROOT/VERSION" | tr -d '[:space:]')"
else
  TOOL_VERSION="0.0.0"
fi

: "${STATE_DIR:=/var/lib/deepin-v23-to-v25}"
: "${LOG_DIR:=/var/log/deepin-v23-to-v25}"
: "${LOCK_FILE:=/run/lock/deepin-v23-to-v25.lock}"
: "${ASSUME_YES:=0}"
: "${DRY_RUN:=0}"
: "${VERBOSE:=0}"
: "${FORCE:=0}"
: "${SKIP_BACKUP_CHECK:=0}"
: "${ALLOW_GRAPHICAL:=0}"
: "${CONFIG_FILE:=}"

if [ -t 2 ]; then
  C_RED=$'\033[31m'
  C_YEL=$'\033[33m'
  C_GRN=$'\033[32m'
  C_DIM=$'\033[2m'
  C_OFF=$'\033[0m'
else
  C_RED=""
  C_YEL=""
  C_GRN=""
  C_DIM=""
  C_OFF=""
fi

APT_OPTS=(
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
  -o Acquire::Retries=5
  -o Acquire::http::Timeout=30
  -o Acquire::https::Timeout=30
)
: "${APT_ETC_DIR:=/etc/apt}"

log()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s[错误]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

section() {
  printf '\n%s--- %s ---%s\n' "$C_DIM" "$*" "$C_OFF"
}

is_true() {
  case "${1:-}" in 1|yes|YES|true|TRUE|on|ON) return 0 ;; esac
  return 1
}

is_false() { ! is_true "${1:-}"; }

have() { command -v "$1" >/dev/null 2>&1; }

need_cmd() {
  local c
  for c in "$@"; do
    have "$c" || die "缺少命令：$c"
  done
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo $TOOL_NAME $*"
}

now_stamp() { date '+%Y%m%d-%H%M%S'; }

human_size() {
  local n="${1:-0}"
  if have numfmt; then
    printf '%sB' "$(numfmt --to=iec --format='%.1f' "$n" 2>/dev/null || printf '%s' "$n")"
  else
    printf '%sB' "$n"
  fi
}

disk_avail_bytes() {
  local path="${1:-/}"
  df --output=avail -B1 -- "$path" 2>/dev/null | tail -1 | tr -d ' '
}

fs_source() { findmnt -no SOURCE -T "$1" 2>/dev/null || true; }
fs_type()   { findmnt -no FSTYPE -T "$1" 2>/dev/null || true; }

is_subpath() {
  local child parent
  child="$(realpath -m -- "$1" 2>/dev/null)" || return 1
  parent="$(realpath -m -- "$2" 2>/dev/null)" || return 1
  [ "$child" = "$parent" ] && return 0
  [ "$parent" = "/" ] && return 0
  case "$child" in
    "$parent"/*) return 0 ;;
  esac
  return 1
}

# Like is_subpath, but does not resolve symlinks. Used to decide which
# archive a path belongs to, so ~/Documents -> /mnt/docs stays a user path.
is_subpath_lexical() {
  local child parent
  child="$(realpath -m -s -- "$1" 2>/dev/null)" || return 1
  parent="$(realpath -m -s -- "$2" 2>/dev/null)" || return 1
  [ "$child" = "$parent" ] && return 0
  [ "$parent" = "/" ] && return 0
  case "$child" in
    "$parent"/*) return 0 ;;
  esac
  return 1
}

on_linux_console() {
  local t
  t="$(tty 2>/dev/null || true)"
  case "$t" in /dev/tty[0-9]*) return 0 ;; esac
  return 1
}

confirm() {
  local prompt="$1" ans
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  if [ ! -t 0 ]; then
    warn "非交互环境且未指定 --yes，默认不继续。"
    return 1
  fi
  read -r -p "$prompt [y/N] " ans || ans=""
  case "$ans" in y|Y|yes|YES) return 0 ;; esac
  return 1
}

type_confirm() {
  local prompt="$1" word="$2" ans
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  [ -t 0 ] || return 1
  read -r -p "$prompt " ans || ans=""
  [ "$ans" = "$word" ]
}

load_config() {
  local default="$REPO_ROOT/config/default.conf" cfg
  [ -r "$default" ] || die "缺少默认配置：$default"
  # shellcheck disable=SC1090
  . "$default"
  cfg="${CONFIG_FILE:-}"
  if [ -z "$cfg" ] && [ -r /etc/deepin-v23-to-v25.conf ]; then
    cfg=/etc/deepin-v23-to-v25.conf
  fi
  if [ -n "$cfg" ]; then
    [ -r "$cfg" ] || die "无法读取配置文件：$cfg"
    # shellcheck disable=SC1090
    . "$cfg"
  fi
}

ensure_state() {
  mkdir -p -- "$STATE_DIR"
  chmod 700 -- "$STATE_DIR"
}

setup_logging() {
  local name="$1" dir
  if [ "$(id -u)" -eq 0 ]; then
    dir="$LOG_DIR"
  else
    dir="${XDG_STATE_HOME:-$HOME/.local/state}/deepin-v23-to-v25/log"
  fi
  mkdir -p -- "$dir" || die "无法创建日志目录：$dir"
  chmod 700 -- "$dir" 2>/dev/null || true
  LOG_FILE="$dir/${name}-$(now_stamp).log"
  : >"$LOG_FILE" || die "无法写入日志：$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  ln -sfn -- "$LOG_FILE" "$dir/latest-${name}.log" 2>/dev/null || true
  trap 'rc=$?; printf "\n!! 脚本在第 %s 行中止（退出码 %s）\n" "$LINENO" "$rc" >&2' ERR
  printf '=== %s %s ===\n' "$TOOL_NAME" "$name"
  printf '时间: %s\n主机: %s\n用户: %s\n日志: %s\n\n' \
    "$(date '+%F %T')" "$(hostname 2>/dev/null || echo unknown)" "$(id -un)" "$LOG_FILE"
}

os_field() {
  local key="$1"
  [ -r /etc/os-release ] || return 1
  sed -n "s/^${key}=//p" /etc/os-release | head -1 | tr -d '"'
}

os_pretty() { os_field PRETTY_NAME || echo "未知系统"; }

is_deepin_v23() {
  [ "$(os_field ID)" = "deepin" ] || return 1
  case "$(os_field VERSION_ID)" in 23|23.*) return 0 ;; esac
  return 1
}

is_deepin_v25() {
  [ "$(os_field ID)" = "deepin" ] || return 1
  case "$(os_field VERSION_ID)" in 25|25.*) return 0 ;; esac
  return 1
}

uid_min() {
  local n
  n="$(awk '$1=="UID_MIN"{print $2; exit}' /etc/login.defs 2>/dev/null || true)"
  printf '%s' "${n:-1000}"
}

list_human_users() {
  local min name _uid _gid _gecos home shell
  min="$(uid_min)"
  while IFS=: read -r name _uid _gid _gecos home shell; do
    [ -n "$name" ] || continue
    case "$_uid" in ''|*[!0-9]*) continue ;; esac
    [ "$_uid" -ge "$min" ] 2>/dev/null || continue
    [ "$_uid" -lt 65534 ] || continue
    [ -d "$home" ] || continue
    case "$home" in /nonexistent|/dev/null) continue ;; esac
    case "$shell" in ""|*/nologin|*/false|*/sync) continue ;; esac
    printf '%s\n' "$name"
  done < /etc/passwd
}

resolve_backup_users() {
  local u
  local -A seen=()
  case "${BACKUP_USERS:-auto}" in
    auto|"")
      while IFS= read -r u; do
        [ -n "$u" ] || continue
        [ -n "${seen[$u]:-}" ] && continue
        seen[$u]=1
        printf '%s\n' "$u"
      done < <(list_human_users)
      ;;
    *)
      local -a requested=()
      read -r -a requested <<<"${BACKUP_USERS}"
      for u in "${requested[@]}"; do
        [ -n "$u" ] || continue
        getent passwd "$u" >/dev/null 2>&1 || die "未知用户：$u"
        [ -n "${seen[$u]:-}" ] && continue
        seen[$u]=1
        printf '%s\n' "$u"
      done
      ;;
  esac
}

user_home() { getent passwd "$1" | cut -d: -f6; }
user_uid()  { id -u "$1" 2>/dev/null || true; }
user_shell(){ getent passwd "$1" | cut -d: -f7; }

run_as_user() {
  local user="$1"; shift
  local uid home
  uid="$(user_uid "$user")"
  home="$(user_home "$user")"
  [ -n "$uid" ] || die "无法确定用户 $user 的 UID"
  if have runuser; then
    runuser -u "$user" -- env \
      HOME="$home" USER="$user" LOGNAME="$user" \
      XDG_RUNTIME_DIR="/run/user/$uid" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
      "$@"
  elif have sudo; then
    sudo -u "$user" env \
      HOME="$home" USER="$user" LOGNAME="$user" \
      XDG_RUNTIME_DIR="/run/user/$uid" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
      "$@"
  else
    die "缺少 runuser/sudo，无法以 $user 身份运行命令"
  fi
}

user_session_available() {
  local uid="$1"
  [ -S "/run/user/$uid/bus" ]
}

apt_update() {
  DEBIAN_FRONTEND=noninteractive apt-get update "${APT_OPTS[@]}" "$@"
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get -y install "${APT_OPTS[@]}" "$@"
}

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

package_version() {
  dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

apt_locked() {
  have fuser || return 1
  fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1
}

run_protected() {
  if have systemd-inhibit; then
    systemd-inhibit --what=sleep:idle:handle-lid-switch \
      --who="$TOOL_NAME" --why="Deepin 23 -> 25 upgrade" --mode=block "$@"
  else
    "$@"
  fi
}

tool_install_dir() { printf '%s' "${TOOL_INSTALL_DIR:-/opt/deepin-v23-to-v25}"; }

install_tool_copy() {
  local dest src
  dest="$(tool_install_dir)"
  src="$REPO_ROOT"
  case "$dest" in
    *[![:print:]]*) die "安装路径必须是可打印 ASCII：$dest" ;;
  esac
  mkdir -p -- "$dest" || die "无法创建 $dest"
  case "$dest" in
    *[!A-Za-z0-9._/-]*) die "安装路径只能使用 ASCII 字母、数字和 ._/-：$dest" ;;
  esac
  if have rsync; then
    rsync -a --exclude '.git/' --exclude 'tests/' "$src"/ "$dest"/ || die "复制工具到 $dest 失败"
  else
    cp -a "$src"/. "$dest"/ || die "复制工具到 $dest 失败"
    rm -rf -- "$dest/.git" "$dest/tests"
  fi
  mkdir -p /usr/local/bin
  ln -sfn -- "$dest/bin/deepin-v25" /usr/local/bin/deepin-v25
  ln -sfn -- "$dest/bin/deepin-v25" "/usr/local/bin/$TOOL_NAME"
  printf '%s\n' "$dest"
}

pre_state_dir() {
  ensure_state
  printf '%s/pre' "$STATE_DIR"
}

quarantine_dir() {
  ensure_state
  printf '%s/quarantine' "$STATE_DIR"
}
