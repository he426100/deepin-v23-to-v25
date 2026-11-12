#!/usr/bin/env bash
# Read-only system inspection, preflight checks and pre-upgrade snapshots.
# shellcheck shell=bash

PREFLIGHT_ERRORS=0
PREFLIGHT_WARNINGS=0
SELECTED_MIRROR=""

preflight_error() {
  PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
  printf '%s[错误]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2
}

preflight_warn() {
  PREFLIGHT_WARNINGS=$((PREFLIGHT_WARNINGS + 1))
  printf '%s[警告]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2
}

preflight_ok() { printf '%s[通过]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }

find_deepin_mirror() {
  local m
  need_cmd curl
  for m in "${DEEPIN_MIRRORS[@]}"; do
    m="${m%/}/"
    if curl -fsSL --max-time 20 -r 0-0 \
        "${m}dists/${DEEPIN_SUITE}/InRelease" >/dev/null 2>&1; then
      SELECTED_MIRROR="$m"
      printf '%s' "$m"
      return 0
    fi
  done
  return 1
}

root_is_readonly() {
  local opts
  opts="$(findmnt -no OPTIONS / 2>/dev/null || true)"
  case ",$opts," in *,ro,*) return 0 ;; esac
  return 1
}

immutable_packages() {
  dpkg-query -W -f='${Package}\n' 2>/dev/null | \
    grep -E '^(deepin-immutable|deepin-recovery|uos-recovery)' || true
}

check_version() {
  local id ver
  id="$(os_field ID)"
  ver="$(os_field VERSION_ID)"
  if [ "$id" != "deepin" ]; then
    preflight_error "这不是 Deepin（ID=${id:-unknown}）。"
    return
  fi
  if is_deepin_v23; then
    preflight_ok "系统版本：$(os_pretty)（VERSION_ID=$ver）"
  elif is_deepin_v25; then
    preflight_error "系统已经是 Deepin 25（VERSION_ID=$ver），无需再升级。"
  else
    preflight_error "只支持 Deepin 23.x，当前 VERSION_ID=${ver:-unknown}。"
  fi
}

check_arch() {
  local a
  a="$(uname -m)"
  case "$a" in
    x86_64|aarch64|loongarch64|riscv64) preflight_ok "架构：$a" ;;
    *) preflight_warn "非常见架构：$a，请先确认镜像提供对应软件包。" ;;
  esac
}

check_root_fs() {
  local target src fstype opts pkgs
  target="$(findmnt -no TARGET / 2>/dev/null || echo /)"
  src="$(fs_source /)"
  fstype="$(fs_type /)"
  opts="$(findmnt -no OPTIONS / 2>/dev/null || true)"
  pkgs="$(immutable_packages)"
  preflight_ok "根分区：${src:-unknown}（${fstype:-unknown}）挂载于 $target"
  if root_is_readonly; then
    preflight_error "根文件系统是只读的。"
    if is_deepin_v25 || [ -n "$pkgs" ]; then
      printf '  先关闭只读保护并重启：控制中心 -> 系统 -> 开发者选项 -> 关闭只读保护\n'
      printf '  或：sudo deepin-immutable-writable enable && sudo reboot\n'
    else
      printf '  V23 没有磐石；检查文件系统错误或 /etc/fstab 中的 ro 挂载，修复后重试。\n'
    fi
  fi
  if [ -n "$pkgs" ]; then
    preflight_error "检测到 immutable/磐石相关包：$(printf '%s' "$pkgs" | tr '\n' ' ')"
    printf '  本工具不支持磐石系统，请先关闭只读保护。\n'
  fi
  case "$opts" in
    *noexec*) preflight_warn "根分区带 noexec 选项，脚本可能无法执行。" ;;
  esac
}

check_space() {
  local avail boot_avail
  avail="$(disk_avail_bytes /)"
  if [ -z "$avail" ]; then
    preflight_warn "无法读取根分区可用空间。"
  elif [ "$avail" -lt $((20 * 1024 * 1024 * 1024)) ]; then
    preflight_error "根分区可用空间不足 20 GiB（当前 $(human_size "$avail")）。"
  else
    preflight_ok "根分区可用空间：$(human_size "$avail")"
  fi

  if findmnt -no TARGET /boot >/dev/null 2>&1; then
    boot_avail="$(disk_avail_bytes /boot)"
    if [ -n "$boot_avail" ] && [ "$boot_avail" -lt $((400 * 1024 * 1024)) ]; then
      preflight_warn "/boot 可用空间不足 400 MiB（当前 $(human_size "$boot_avail")）。"
    else
      preflight_ok "/boot 可用空间：$(human_size "${boot_avail:-0}")"
    fi
  else
    preflight_warn "/boot 没有独立挂载，内核将写入根分区。"
  fi

  local inodes_used
  inodes_used="$(df --output=ipcent -x tmpfs -x devtmpfs / 2>/dev/null | tail -1 | tr -d ' %')"
  if [ -n "$inodes_used" ] && [ "$inodes_used" -ge 95 ] 2>/dev/null; then
    preflight_warn "根分区 inode 使用率 ${inodes_used}%，apt 解包可能失败。"
  fi
}

check_boot() {
  local k count=0
  if [ -d /boot ]; then
    for k in /boot/vmlinuz-*; do
      [ -e "$k" ] || continue
      count=$((count + 1))
    done
  fi
  if [ "$count" -lt 2 ]; then
    preflight_warn "/boot 只有 $count 个内核，新内核启动失败时没有旧内核可选。"
  else
    preflight_ok "/boot 内核数量：$count"
  fi

  if [ -d /sys/firmware/efi ]; then
    preflight_ok "启动方式：UEFI"
    if findmnt -no TARGET /boot/efi >/dev/null 2>&1 || findmnt -no TARGET /efi >/dev/null 2>&1; then
      preflight_ok "EFI 分区已挂载。"
    else
      preflight_warn "UEFI 启动但未发现已挂载的 EFI 分区；GRUB 更新可能失败。"
    fi
    if have mokutil; then
      local sb
      sb="$(mokutil --sb-state 2>/dev/null || true)"
      case "$sb" in
        *enabled*) preflight_warn "Secure Boot 已启用：第三方 DKMS 驱动（如 NVIDIA）可能无法加载。" ;;
      esac
    fi
  else
    preflight_ok "启动方式：Legacy BIOS"
  fi
  if ! have update-grub; then
    preflight_warn "缺少 update-grub，升级后无法自动刷新 GRUB。"
  fi
  if ! have update-initramfs; then
    preflight_warn "缺少 update-initramfs，升级后无法自动重建 initrd。"
  fi
}

check_power() {
  local p online found=0 type
  for p in /sys/class/power_supply/BAT*; do
    [ -e "$p" ] || continue
    found=1
  done
  [ "$found" -eq 1 ] || { preflight_ok "供电：台式机/无电池"; return; }
  online=0
  for p in /sys/class/power_supply/*; do
    [ -e "$p/online" ] || continue
    type="$(cat "$p/type" 2>/dev/null || true)"
    [ "$type" = "Mains" ] || continue
    [ "$(cat "$p/online" 2>/dev/null || echo 0)" = "1" ] && online=1
  done
  if [ "$online" -eq 1 ]; then
    preflight_ok "供电：已连接电源"
  elif is_true "$FORCE"; then
    preflight_warn "未连接电源，继续升级（--force）。升级中断可能损坏系统。"
  else
    preflight_error "笔记本未连接电源。请插上电源，或使用 --force 承担风险。"
  fi
}

check_storage_layout() {
  local types
  types="$(lsblk -rno TYPE 2>/dev/null | sort -u | tr '\n' ' ')"
  case " $types " in
    *" crypt "*) preflight_warn "检测到 LUKS/加密卷：升级中不要忘记磁盘口令。" ;;
  esac
  case " $types " in
    *" lvm "*) preflight_ok "检测到 LVM（受支持）。" ;;
  esac
  case " $types " in
    *" raid"*) preflight_warn "检测到 RAID，升级前确认阵列状态正常（cat /proc/mdstat）。" ;;
  esac
}

check_gpu() {
  local gpu
  gpu="$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' || true)"
  [ -n "$gpu" ] && preflight_ok "显卡：$(printf '%s' "$gpu" | head -1 | cut -d' ' -f2- | cut -c1-100)"
  if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    preflight_ok "NVIDIA 驱动：$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
    if have dkms; then
      if dkms status 2>/dev/null | grep -qi nvidia; then
        preflight_ok "NVIDIA DKMS 模块已注册，升级后会自动重建。"
      else
        preflight_warn "NVIDIA 驱动未通过 DKMS 管理；新内核可能无法加载，请准备重装驱动。"
      fi
    fi
  fi
}

check_network() {
  if ! have curl; then
    preflight_error "缺少 curl，无法检查镜像连通性。"
    return
  fi
  if find_deepin_mirror >/dev/null; then
    preflight_ok "Deepin 25 镜像可用：$SELECTED_MIRROR"
  else
    preflight_error "所有配置的 Deepin 25 镜像都不可达。检查网络/DNS 后重试。"
  fi
  local ntp
  ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  if [ "$ntp" = "no" ]; then
    preflight_warn "系统时间未同步（NTP），TLS 下载可能失败。"
  fi
}

check_apt_state() {
  if apt_locked; then
    preflight_error "apt/dpkg 正被其他进程占用，等它结束后重试。"
  fi
  local audit
  audit="$(dpkg --audit 2>&1 || true)"
  if [ -n "$audit" ]; then
    preflight_warn "dpkg 存在未完成配置，升级脚本会先修复。"
    printf '%s\n' "$audit" | head -10
  else
    preflight_ok "dpkg 状态正常。"
  fi
  local holds
  holds="$(apt-mark showhold 2>/dev/null || true)"
  if [ -n "$holds" ]; then
    preflight_warn "存在被 hold 的包：$(printf '%s' "$holds" | tr '\n' ' ')"
  fi
}

last_backup_manifest() {
  local dir="${1:-}" best=""
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    best="$(find "$dir" -maxdepth 2 -name manifest.env -printf '%h\n' 2>/dev/null | sort | tail -1)"
  fi
  if [ -z "$best" ] && [ -f "$STATE_DIR/last-backup" ]; then
    local p
    p="$(head -1 "$STATE_DIR/last-backup" 2>/dev/null || true)"
    [ -n "$p" ] && [ -f "$p/manifest.env" ] && best="$p"
  fi
  printf '%s' "$best"
}

check_backup() {
  local required="${1:-1}"
  if is_true "$SKIP_BACKUP_CHECK"; then
    preflight_warn "已跳过备份检查（--skip-backup-check）。"
    return
  fi
  local dest="${BACKUP_DEST:-}" dir manifest epoch age_days max_age
  dir="$(last_backup_manifest "$dest")"
  if [ -z "$dir" ]; then
    if [ "$required" -eq 1 ]; then
      preflight_error "没有找到可用的数据备份。"
    else
      preflight_warn "尚未找到本工具的备份（升级前必须完成）。"
    fi
    printf '  先运行：sudo deepin-v25 backup --dest /path/to/disk\n'
    printf '  已有其他备份可加：--skip-backup-check\n'
    return
  fi
  manifest="$dir/manifest.env"
  epoch="$(sed -n 's/^BACKUP_FINISHED_EPOCH=//p' "$manifest" 2>/dev/null | tail -1)"
  max_age="${MAX_BACKUP_AGE_DAYS:-14}"
  if [ -n "$epoch" ] && [ "$epoch" -gt 0 ] 2>/dev/null; then
    age_days=$(( ( $(date +%s) - epoch ) / 86400 ))
    if [ "$age_days" -gt "$max_age" ]; then
      if [ "$required" -eq 1 ]; then
        preflight_error "最近的备份已 $age_days 天（$dir），超过 ${max_age} 天。请重新备份。"
      else
        preflight_warn "最近的备份已 $age_days 天（$dir），升级前请重新备份。"
      fi
      return
    fi
    preflight_ok "可用备份：$dir（$age_days 天前）"
  else
    preflight_warn "找到备份目录但无法读取时间：$dir"
  fi
}

check_users() {
  local users
  users="$(resolve_backup_users 2>/dev/null || true)"
  if [ -z "$users" ]; then
    preflight_warn "没有检测到可备份的普通用户。"
  else
    preflight_ok "登录用户：$(printf '%s' "$users" | tr '\n' ' ')"
  fi
}

run_preflight() {
  local require_backup="${1:-1}"
  PREFLIGHT_ERRORS=0
  PREFLIGHT_WARNINGS=0
  SELECTED_MIRROR=""
  section "升级前检查"
  check_version
  check_arch
  check_root_fs
  check_space
  check_boot
  check_power
  check_storage_layout
  check_gpu
  check_network
  check_apt_state
  check_users
  check_backup "$require_backup"
  printf '\n'
  if [ "$PREFLIGHT_ERRORS" -gt 0 ]; then
    printf '%s预检失败：%s 个错误，%s 个警告。%s\n' \
      "$C_RED" "$PREFLIGHT_ERRORS" "$PREFLIGHT_WARNINGS" "$C_OFF" >&2
    return 1
  fi
  printf '%s预检通过（%s 个警告）。%s\n' "$C_GRN" "$PREFLIGHT_WARNINGS" "$C_OFF"
  return 0
}

capture() {
  local name="$1"; shift
  local out="$PRE_STATE/$name"
  if "$@" >"$out" 2>/dev/null; then
    return 0
  fi
  printf '# command failed: %s\n' "$*" >"$out"
  return 0
}

collect_pre_state() {
  PRE_STATE="$(pre_state_dir)"
  mkdir -p -- "$PRE_STATE"
  chmod 700 -- "$PRE_STATE"
  section "记录升级前状态"
  printf '保存到 %s\n' "$PRE_STATE"

  capture os-release cat /etc/os-release
  capture uname uname -a
  capture proc-cmdline cat /proc/cmdline
  capture dpkg-selections dpkg --get-selections
  capture apt-manual apt-mark showmanual
  capture apt-holds apt-mark showhold
  capture apt-policy apt-cache policy
  capture installed-packages dpkg-query -W -f='${Package}\t${Version}\t${Status}\n'
  capture sources.list cat /etc/apt/sources.list
  capture findmnt findmnt -R /
  capture lsblk lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
  capture fstab cat /etc/fstab
  capture crypttab cat /etc/crypttab
  capture boot-files sh -c 'find /boot -maxdepth 1 -type f -printf "%f\n" | sort'
  capture lspci lspci -nn
  capture lsmod lsmod
  capture debian-version cat /etc/debian_version
  capture timedatectl timedatectl
  capture locale locale
  capture passwd cat /etc/passwd
  capture group cat /etc/group
  capture docker-running sh -c 'command -v docker >/dev/null 2>&1 && docker ps --format "{{.Names}}" || true'
  capture docker-enabled systemctl is-enabled docker
  capture docker-active systemctl is-active docker
  capture enabled-units sh -c 'systemctl list-unit-files --state=enabled --no-legend | awk "{print \$1}"'
  capture running-services sh -c 'systemctl list-units --type=service --state=running --no-legend | awk "{print \$1}"'
  capture failed-units systemctl --failed --no-legend
  if have efibootmgr; then
    capture efibootmgr efibootmgr -v
  fi
  if have dkms; then
    capture dkms-status dkms status
  fi
  if have nvidia-smi; then
    capture nvidia-smi nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
  fi
  if have crontab; then
    capture root-crontab crontab -l -u root
    local u
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      capture "crontab-$u" crontab -l -u "$u"
    done < <(resolve_backup_users 2>/dev/null || true)
  fi
  cp -a /etc/apt/sources.list.d "$PRE_STATE/sources.list.d" 2>/dev/null || true
  mkdir -p "$PRE_STATE"
  cat >"$PRE_STATE/README.txt" <<'EOF'
升级前状态快照。用于回退/排查，不要删除。
- dpkg-selections: 升级前所有包
- apt-manual: 手动安装的包
- sources.list / sources.list.d: 升级前软件源
- findmnt / lsblk / fstab / crypttab: 存储布局
- docker-running: 升级前运行的容器
- enabled-units / running-services: 服务状态
EOF
  ok "升级前状态已记录。"
}

enable_persistent_journal() {
  is_true "$ENABLE_PERSISTENT_JOURNAL" || return 0
  section "持久化系统日志"
  if [ -d /var/log/journal ]; then
    ok "journald 已经是持久化模式。"
    return 0
  fi
  mkdir -p /etc/systemd/journald.conf.d
  local f=/etc/systemd/journald.conf.d/99-deepin-v25-persistent.conf
  if [ -e "$f" ]; then
    warn "$f 已存在，未修改。"
  else
    cat >"$f" <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=1G
EOF
    systemctl restart systemd-journald 2>/dev/null || warn "重启 systemd-journald 失败。"
  fi
  mkdir -p /var/log/journal || true
  ok "已启用持久化日志，首次启动桌面异常时可查 journalctl -b。"
}

copy_tool_now() {
  section "安装救援工具副本"
  local dest
  dest="$(install_tool_copy)"
  ok "工具已复制到 $dest，命令：sudo deepin-v25 ..."
}

show_system_facts() {
  printf '系统    : %s\n' "$(os_pretty)"
  printf '内核    : %s\n' "$(uname -r)"
  printf '架构    : %s\n' "$(uname -m)"
  printf '根分区  : %s (%s)\n' "$(fs_source /)" "$(fs_type /)"
  printf '可用空间: %s\n' "$(human_size "$(disk_avail_bytes /)")"
}
