#!/usr/bin/env bash
# Upgrade, post-upgrade repair, desktop recovery, source handling, diagnostics.
# shellcheck shell=bash

MIRROR_OVERRIDE=""
SIM_LOG=""
LIGHTDM_STOPPED=0
UPGRADE_PHASE="prepare"
SOURCES_TOUCHED=0
MAIN_SOURCE_WRITTEN=0
AUX_SOURCES_WRITTEN=()

dpkg_repair() {
  dpkg --force-confdef --force-confold --configure -a || true
  DEBIAN_FRONTEND=noninteractive apt-get -y --fix-broken install "${APT_OPTS[@]}" >/dev/null 2>&1 || true
}

check_tty() {
  if on_linux_console || [ -n "${TMUX:-}" ] || [ -n "${STY:-}" ]; then
    return 0
  fi
  if is_true "$ALLOW_GRAPHICAL" || is_true "$FORCE"; then
    warn "在图形终端中继续（桌面会在此脚本停止 lightdm 时退出）。"
    return 0
  fi
  warn "当前不是 Linux 虚拟终端（TTY）。升级会停止 lightdm，图形终端会话会立刻断开。"
  printf '请按 Ctrl+Alt+F3 进入 TTY，登录后执行：\n'
  printf '  sudo %s upgrade\n' "$TOOL_NAME"
  printf '如果确定要在图形终端中执行，加 --allow-graphical-terminal。\n'
  return 1
}

save_apt_sources() {
  local qdir="$STATE_DIR/quarantine/apt-sources"
  local f b sha
  SOURCES_TOUCHED=1
  section "备份并隔离第三方软件源"
  mkdir -p "$qdir/disabled"
  if [ -f "$APT_ETC_DIR/sources.list" ] && [ ! -f "$qdir/sources.list.orig" ]; then
    cp -a "$APT_ETC_DIR/sources.list" "$qdir/sources.list.orig" || true
  fi
  if [ -d "$APT_ETC_DIR/sources.list.d" ] && [ ! -d "$qdir/sources.list.d.orig" ]; then
    cp -a "$APT_ETC_DIR/sources.list.d" "$qdir/sources.list.d.orig" || true
  fi
  : >"$qdir/manifest.tsv"
  for f in "$APT_ETC_DIR"/sources.list.d/*.list "$APT_ETC_DIR"/sources.list.d/*.sources; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    b="$(basename "$f")"
    if [ -e "$qdir/disabled/$b" ] || [ -L "$qdir/disabled/$b" ]; then
      b="$b.$(now_stamp)"
    fi
    sha="$(sha256sum -- "$f" 2>/dev/null | awk '{print $1}')"
    printf '%s\t%s\n' "$b" "$sha" >>"$qdir/manifest.tsv"
    mv -- "$f" "$qdir/disabled/$b" || die "无法隔离软件源：$f"
    info "已停用：$b"
  done
  cat >"$qdir/README.txt" <<EOF
原软件源已隔离，升级完成后可用以下命令查看/恢复：
  sudo $TOOL_NAME sources status
  sudo $TOOL_NAME sources restore <文件名>
  sudo $TOOL_NAME sources restore --all
第三方源在升级期间可能导致 apt 失败，因此不会自动恢复。
EOF
  ok "第三方源已隔离到 $qdir/disabled"
}

restore_original_apt_sources() {
  local qdir="$STATE_DIR/quarantine/apt-sources"
  local stamp="$qdir/sources.list.d.failed-$(now_stamp)"
  local n
  [ -d "$qdir" ] || return 0
  [ -e "$stamp" ] && stamp="$stamp-$$"
  warn "恢复升级前的软件源 ..."
  if [ -f "$qdir/sources.list.orig" ]; then
    cp -a "$qdir/sources.list.orig" "$APT_ETC_DIR/sources.list" || \
      warn "恢复 $APT_ETC_DIR/sources.list 失败。"
  elif [ "$MAIN_SOURCE_WRITTEN" -eq 1 ]; then
    rm -f -- "$APT_ETC_DIR/sources.list"
  fi
  if [ -d "$qdir/sources.list.d.orig" ]; then
    if [ -d "$APT_ETC_DIR/sources.list.d" ]; then
      mv -- "$APT_ETC_DIR/sources.list.d" "$stamp" 2>/dev/null || true
    fi
    cp -a "$qdir/sources.list.d.orig" "$APT_ETC_DIR/sources.list.d" || \
      warn "恢复 $APT_ETC_DIR/sources.list.d 失败。"
    [ -d "$stamp" ] && info "失败时的源目录已保存：$stamp"
  else
    for n in "${AUX_SOURCES_WRITTEN[@]}"; do
      rm -f -- "$APT_ETC_DIR/sources.list.d/$n.list"
    done
  fi
  if apt_update >/dev/null 2>&1; then
    ok "软件源已恢复到升级前状态。"
  else
    warn "软件源已恢复，但 apt update 失败（检查网络后运行 apt update）。"
  fi
}

upgrade_exit_trap() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ]; then
    if [ "$UPGRADE_PHASE" = "prepare" ] && [ "$SOURCES_TOUCHED" -eq 1 ]; then
      restore_original_apt_sources || true
    fi
    if [ "$LIGHTDM_STOPPED" -eq 1 ] && [ "$UPGRADE_PHASE" != "installing" ]; then
      if lightdm_start; then
        printf '\n升级未进入安装阶段，桌面已恢复。\n'
      else
        printf '\n提示：lightdm 未启动。回桌面：sudo systemctl start lightdm\n'
      fi
    fi
  fi
  exit "$rc"
}

write_main_source() {
  local mirror="${1%/}/"
  printf 'deb %s %s %s\n' "$mirror" "$DEEPIN_SUITE" "$DEEPIN_COMPONENTS" >"$APT_ETC_DIR/sources.list"
  MAIN_SOURCE_WRITTEN=1
}

try_mirrors() {
  local -a candidates=()
  local -A seen=()
  local m
  section "切换 Deepin 25 软件源"
  if [ -n "$MIRROR_OVERRIDE" ]; then
    candidates+=("$MIRROR_OVERRIDE")
  elif [ -n "$SELECTED_MIRROR" ]; then
    candidates+=("$SELECTED_MIRROR")
  fi
  for m in "${DEEPIN_MIRRORS[@]}"; do
    candidates+=("$m")
  done

  for m in "${candidates[@]}"; do
    [ -n "$m" ] || continue
    m="${m%/}/"
    [ -n "${seen[$m]:-}" ] && continue
    seen[$m]=1
    if ! curl -fsSL --max-time 20 -r 0-0 \
        "${m}dists/${DEEPIN_SUITE}/InRelease" >/dev/null 2>&1; then
      warn "镜像不可达，跳过：$m"
      continue
    fi
    write_main_source "$m"
    info "尝试镜像：$m"
    if apt_update; then
      SELECTED_MIRROR="$m"
      ok "软件源已切换：$m"
      return 0
    fi
    warn "apt update 失败，换下一个镜像。"
  done
  die "所有镜像都不可用。保留的原始源在 $STATE_DIR/quarantine/apt-sources/。"
}

install_aux_source() {
  local name="$1" line="$2" qdir="$STATE_DIR/quarantine/apt-sources"
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" >"$APT_ETC_DIR/sources.list.d/$name.list"
  AUX_SOURCES_WRITTEN+=("$name")
  info "测试附加源：$name"
  if apt_update; then
    ok "附加源可用：$name"
  else
    warn "附加源 $name 刷新失败，停用它。"
    mv -- "$APT_ETC_DIR/sources.list.d/$name.list" "$qdir/disabled/$name.list.$(now_stamp)" 2>/dev/null || \
      rm -f "$APT_ETC_DIR/sources.list.d/$name.list"
    apt_update >/dev/null 2>&1 || true
  fi
}

install_aux_sources() {
  section "附加软件源"
  if is_true "$APPSTORE_ENABLED"; then
    install_aux_source appstore "$APPSTORE_SOURCE"
  fi
  if is_true "$DRIVER_REPO_ENABLED"; then
    install_aux_source driver "$DRIVER_SOURCE"
  fi
}

prepare_grub() {
  local timeout="${GRUB_TIMEOUT:-5}"
  case "$timeout" in ''|*[!0-9]*) timeout=5 ;; esac
  section "准备 GRUB"
  mkdir -p "$STATE_DIR/pre"
  [ -f /etc/default/grub ] && [ ! -f "$STATE_DIR/pre/default-grub.orig" ] && \
    cp -a /etc/default/grub "$STATE_DIR/pre/default-grub.orig" || true
  [ -f /boot/grub/grub.cfg ] && [ ! -f "$STATE_DIR/pre/grub.cfg.orig" ] && \
    cp -a /boot/grub/grub.cfg "$STATE_DIR/pre/grub.cfg.orig" || true

  if [ -f /etc/default/grub ]; then
    if grep -q '^GRUB_TIMEOUT=' /etc/default/grub; then
      sed -i "s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=$timeout/" /etc/default/grub
    else
      printf 'GRUB_TIMEOUT=%s\n' "$timeout" >>/etc/default/grub
    fi
    if grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub; then
      sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
    else
      printf 'GRUB_TIMEOUT_STYLE=menu\n' >>/etc/default/grub
    fi
  else
    warn "/etc/default/grub 不存在，跳过主配置修改。"
  fi

  mkdir -p /etc/default/grub.d
  cat >/etc/default/grub.d/99-deepin-v25-upgrade.cfg <<EOF
GRUB_TIMEOUT=$timeout
GRUB_TIMEOUT_STYLE=menu
EOF
  if have update-grub; then
    update-grub >/dev/null 2>&1 || warn "update-grub 失败，GRUB 菜单可能未更新。"
  fi
  ok "GRUB 菜单等待时间设为 ${timeout}s，旧内核仍可选择。"
}

stop_services_for_upgrade() {
  section "停止桌面、容器和后台更新"
  if have docker; then
    if systemctl is-active --quiet docker 2>/dev/null; then
      docker ps -q 2>/dev/null | xargs -r docker stop >/dev/null 2>&1 || true
      systemctl stop docker.socket docker 2>/dev/null || true
      info "Docker 容器已停止。"
    fi
  fi
  local s
  for s in "${STOP_SERVICES[@]}"; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then
      systemctl stop "$s" 2>/dev/null || true
      info "已停止：$s"
      [ "$s" = "lightdm" ] && LIGHTDM_STOPPED=1
    fi
  done
  systemctl stop packagekit 2>/dev/null || true
}

removed_packages_block() {
  awk '
    /^The following packages will be REMOVED:/ { f=1; next }
    f && /^[^[:space:]]/ { f=0 }
    f && NF { print }
  ' "$1"
}

removed_package_names() {
  tr -s '[:space:]' '\n' | sed '/^$/d; s/:.*//'
}

run_simulation() {
  local simdir="$STATE_DIR/upgrade"
  local removed removed_names critical_removed="" p
  mkdir -p "$simdir"
  SIM_LOG="$simdir/apt-simulate.log"
  section "升级模拟（不改动系统）"
  if ! LC_ALL=C apt-get -s full-upgrade "${APT_OPTS[@]}" >"$SIM_LOG" 2>&1; then
    warn "升级模拟失败，日志尾部："
    tail -40 "$SIM_LOG" >&2 || true
    die "先修复 apt 后重试；系统尚未改动。"
  fi
  grep -E '^[0-9]+ upgraded' "$SIM_LOG" | tail -1 || true
  grep -E '^Need to get|^After this operation' "$SIM_LOG" | sed 's/^/  /' || true

  removed="$(removed_packages_block "$SIM_LOG")"
  if [ -n "$removed" ]; then
    printf '将删除的包（前 40 个）：\n'
    printf '%s\n' "$removed" | head -40 | sed 's/^/  /'
    removed_names="$(printf '%s\n' "$removed" | removed_package_names)"
    for p in "${DESKTOP_PACKAGES[@]}" dde-session-shell; do
      if printf '%s\n' "$removed_names" | grep -qx "$p"; then
        critical_removed="$critical_removed $p"
      fi
    done
    if [ -n "$critical_removed" ]; then
      die "模拟显示会删除桌面关键包：$critical_removed。已停止，系统未改动。"
    fi
    printf '说明：startdde/deepin-kwin-* 等旧桌面框架被 dde-shell 取代属于预期。\n'
  fi

  if grep -Eq '^Inst .*(deepin-immutable|uos-recovery|deepin-recovery)' "$SIM_LOG"; then
    die "模拟显示会安装 immutable/磐石相关包。本工具不支持磐石系统，已停止。"
  fi
  ok "升级模拟通过。"
}

download_packages() {
  section "预下载升级包"
  if ! run_protected apt-get -y full-upgrade --download-only "${APT_OPTS[@]}"; then
    die "预下载失败，系统尚未改动。检查网络/磁盘后重跑以续传。"
  fi
  local avail
  avail="$(disk_avail_bytes /)"
  if [ -n "$avail" ] && [ "$avail" -lt $((4 * 1024 * 1024 * 1024)) ]; then
    die "下载后根分区剩余不足 4 GiB（$(human_size "$avail")）。清理空间后重跑，已下载的包会复用。"
  fi
  ok "预下载完成，根分区剩余 $(human_size "$avail")。"
}

do_full_upgrade() {
  local attempt ok=0
  section "执行 apt full-upgrade"
  for attempt in 1 2 3; do
    info "第 $attempt 次 full-upgrade ..."
    if run_protected apt-get -y full-upgrade "${APT_OPTS[@]}"; then
      ok=1
      break
    fi
    warn "第 $attempt 次未完成，先修复 dpkg 再重试。"
    dpkg_repair
    sleep 2
  done
  [ "$ok" -eq 1 ] || die "full-upgrade 多次失败。系统处于可续做状态，修复后重跑本命令。"
  dpkg_repair
  run_protected apt-get -y full-upgrade "${APT_OPTS[@]}" >/dev/null 2>&1 || true
  ok "full-upgrade 完成。"
}

ensure_desktop_packages() {
  local -a missing=() extras_missing=()
  local p
  apt_update >/dev/null 2>&1 || warn "apt update 失败，尝试使用现有缓存。"
  for p in "${DESKTOP_PACKAGES[@]}"; do
    package_installed "$p" || missing+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    warn "缺少桌面关键包：${missing[*]}，尝试安装。"
    apt_install "${missing[@]}" || warn "桌面关键包安装失败，运行 $TOOL_NAME rescue。"
  fi
  for p in "${DESKTOP_EXTRA_PACKAGES[@]}"; do
    package_installed "$p" || extras_missing+=("$p")
  done
  for p in "${extras_missing[@]}"; do
    info "安装推荐组件：$p"
    apt_install "$p" || warn "推荐组件安装失败：$p（不影响继续）"
  done
  systemctl daemon-reload 2>/dev/null || true
  if package_installed lightdm; then
    systemctl enable lightdm >/dev/null 2>&1 || warn "无法启用 lightdm。"
  fi
}

update_boot() {
  section "重建 initramfs 和 GRUB"
  if have update-initramfs; then
    update-initramfs -u -k all || warn "update-initramfs 失败，检查 /boot 空间。"
  fi
  if have update-grub; then
    update-grub >/dev/null 2>&1 || warn "update-grub 失败。"
  fi
  local k ver
  for k in /boot/vmlinuz-*; do
    [ -e "$k" ] || continue
    ver="${k#/boot/vmlinuz-}"
    [ -f "/boot/initrd.img-$ver" ] || warn "缺少 /boot/initrd.img-$ver"
  done
  local count
  count="$(grep -c '^menuentry' /boot/grub/grub.cfg 2>/dev/null || true)"
  info "GRUB 菜单项：${count:-unknown}"
}

check_immutable_after() {
  local pkgs opts
  pkgs="$(immutable_packages)"
  opts="$(findmnt -no OPTIONS / 2>/dev/null || true)"
  if [ -n "$pkgs" ] || { root_is_readonly; }; then
    warn "检测到只读根分区或 immutable/磐石相关包："
    [ -n "$pkgs" ] && printf '%s\n' "$pkgs" | sed 's/^/  /'
    printf '  本工具不会自动关闭磐石。可用：\n'
    printf '  控制中心 -> 系统 -> 开发者选项 -> 关闭只读保护，重启\n'
    printf '  或：sudo deepin-immutable-writable enable && sudo reboot\n'
  fi
}

verify_after_upgrade() {
  section "升级后验证"
  . /etc/os-release 2>/dev/null || true
  if is_deepin_v25; then
    ok "系统版本：$(os_pretty)"
  else
    warn "版本不是 Deepin 25.x（$(os_pretty)），可能需要重跑或运行 post 修复。"
  fi
  local audit
  audit="$(dpkg --audit 2>&1 || true)"
  [ -n "$audit" ] && { warn "dpkg audit："; printf '%s\n' "$audit" | head -20; } || ok "dpkg 状态正常。"
  apt-get check >/dev/null 2>&1 && ok "apt 依赖关系正常。" || warn "apt 依赖关系不完整。"

  ensure_desktop_packages

  local p
  for p in "${DESKTOP_PACKAGES[@]}"; do
    if package_installed "$p"; then ok "已安装：$p"; else warn "仍缺少：$p"; fi
  done
  if [ -d /usr/share/xsessions ] && [ -n "$(ls -A /usr/share/xsessions 2>/dev/null || true)" ]; then
    ls -1 /usr/share/xsessions | sed 's/^/  xsessions: /'
  else
    warn "/usr/share/xsessions 为空，登录界面可能没有会话。"
  fi
  if package_installed lightdm; then
    systemctl is-enabled lightdm >/dev/null 2>&1 && ok "lightdm 已启用。" || warn "lightdm 未启用。"
  fi

  update_boot
  check_immutable_after
  if have dkms; then
    if dkms status 2>/dev/null | grep -i nvidia | grep -qv 'installed'; then
      warn "NVIDIA DKMS 模块未成功构建，重启前检查：dkms status"
    fi
  fi
}

copy_logs_to_backup() {
  local dir
  dir="$(last_backup_manifest "${BACKUP_DEST:-}")"
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ] && \
    { cp -a "$LOG_FILE" "$dir/" 2>/dev/null || cp "$LOG_FILE" "$dir/" 2>/dev/null || true; }
  [ -n "${SIM_LOG:-}" ] && [ -f "$SIM_LOG" ] && \
    { cp -a "$SIM_LOG" "$dir/" 2>/dev/null || cp "$SIM_LOG" "$dir/" 2>/dev/null || true; }
  if [ -d "$STATE_DIR/pre" ]; then
    mkdir -p "$dir/pre-upgrade-state" 2>/dev/null || true
    cp -a "$STATE_DIR/pre"/. "$dir/pre-upgrade-state"/ 2>/dev/null || true
  fi
}

cmd_preflight() {
  require_root
  setup_logging preflight
  show_system_facts
  run_preflight 0
}

cmd_install() {
  if is_true "$DRY_RUN"; then
    warn "dry-run：install 会复制文件到 $(tool_install_dir)，未执行。"
    return 0
  fi
  require_root
  setup_logging install
  local dest
  dest="$(install_tool_copy)"
  ok "已安装到 $dest"
  printf '命令：sudo %s preflight|backup|upgrade|post|fix-desktop|rescue|restore|sources|diagnose\n' "$TOOL_NAME"
}

cmd_upgrade() {
  local arg
  while [ $# -gt 0 ]; do
    case "$1" in
      --mirror) [ $# -ge 2 ] || die "--mirror 需要参数"; MIRROR_OVERRIDE="$2"; shift 2 ;;
      --mirror=*) MIRROR_OVERRIDE="${1#*=}"; shift ;;
      --skip-backup-check) SKIP_BACKUP_CHECK=1; shift ;;
      --allow-graphical-terminal) ALLOW_GRAPHICAL=1; shift ;;
      *) die "未知参数：$1" ;;
    esac
  done

  require_root
  setup_logging upgrade
  trap upgrade_exit_trap EXIT

  if is_deepin_v25; then
    ok "系统已经是 Deepin 25（$(os_pretty)）。"
    printf '如桌面/组件异常，运行：sudo %s post\n' "$TOOL_NAME"
    return 0
  fi
  is_deepin_v23 || die "只支持从 Deepin 23.x 升级，当前是 $(os_pretty)。"

  show_system_facts
  run_preflight || die "预检未通过，未改动系统。"

  collect_pre_state

  if is_true "$DRY_RUN"; then
    section "Dry run"
    printf '将执行：备份第三方源 -> 切换到以下镜像 -> 模拟/预下载/full-upgrade\n'
    printf '镜像：%s\n' "${SELECTED_MIRROR:-$(find_deepin_mirror || true)}"
    printf '组件：%s %s %s\n' "$DEEPIN_SUITE" "$DEEPIN_COMPONENTS"
    printf '桌面包：%s\n' "${DESKTOP_PACKAGES[*]}"
    printf '系统未改动。\n'
    return 0
  fi

  check_tty || die "请在 TTY 中运行。"
  printf '\n即将切换到 Deepin 25 源并执行 full-upgrade。\n'
  printf '会先停止 lightdm/Docker，第三方源会隔离到 %s/quarantine。\n' "$STATE_DIR"
  type_confirm "输入 UPGRADE 开始：" UPGRADE || die "已取消，系统未改动。"

  install_tool_copy >/dev/null
  ok "救援工具副本已安装：$(tool_install_dir)（命令 deepin-v25）"
  enable_persistent_journal
  prepare_grub
  stop_services_for_upgrade
  save_apt_sources
  try_mirrors
  install_aux_sources
  run_simulation
  download_packages
  UPGRADE_PHASE="installing"
  do_full_upgrade
  verify_after_upgrade
  copy_logs_to_backup

  section "升级流程完成"
  printf '日志：%s\n' "$LOG_FILE"
  printf '下一步（重启后）：sudo %s post\n' "$TOOL_NAME"
  printf '若进不了桌面：TTY 中执行 sudo %s rescue\n' "$TOOL_NAME"
  printf '第三方源查看：sudo %s sources status\n' "$TOOL_NAME"
  if is_true "$AUTO_REBOOT" || confirm "现在重启？"; then
    sync
    reboot
  else
    printf '请尽快重启，让新内核和桌面组件生效。\n'
  fi
}

lightdm_start() {
  if ! have lightdm && ! systemctl list-unit-files --no-legend lightdm.service >/dev/null 2>&1; then
    warn "未找到 lightdm。"
    return 1
  fi
  systemctl enable lightdm >/dev/null 2>&1 || true
  if systemctl is-active --quiet lightdm; then
    ok "lightdm：active"
    return 0
  fi
  systemctl reset-failed lightdm 2>/dev/null || true
  systemctl start lightdm || true
  sleep 2
  if systemctl is-active --quiet lightdm; then
    ok "lightdm：active"
    return 0
  fi
  warn "lightdm 未能启动。查看：journalctl -u lightdm -n 80 --no-pager"
  return 1
}

restart_dde_config() {
  if systemctl list-unit-files --no-legend dde-dconfig-daemon.service 2>/dev/null | grep -q dde-dconfig-daemon; then
    systemctl restart dde-dconfig-daemon 2>/dev/null && info "已重启 dde-dconfig-daemon。" || \
      warn "重启 dde-dconfig-daemon 失败。"
  fi
}

restart_docker_after() {
  is_true "$DOCKER_RESTORE" || return 0
  have docker || { info "未安装 Docker，跳过。"; return 0; }
  local enabled=0 active=0 c
  if [ -f "$STATE_DIR/pre/docker-enabled" ] && grep -q '^enabled' "$STATE_DIR/pre/docker-enabled" 2>/dev/null; then
    enabled=1
  fi
  if [ -f "$STATE_DIR/pre/docker-active" ] && grep -qx 'active' "$STATE_DIR/pre/docker-active" 2>/dev/null; then
    active=1
  fi
  if [ "$active" -eq 0 ]; then
    info "升级前 Docker 未运行，跳过启动（enabled=$enabled）。"
    return 0
  fi
  systemctl start docker 2>/dev/null || true
  local i
  for i in $(seq 1 30); do
    [ -S /var/run/docker.sock ] && break
    sleep 1
  done
  if [ ! -S /var/run/docker.sock ]; then
    warn "Docker 未启动（enabled=$enabled）。需要时：sudo systemctl start docker"
    return 0
  fi
  if [ -f "$STATE_DIR/pre/docker-running" ]; then
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      docker inspect "$c" >/dev/null 2>&1 && docker start "$c" >/dev/null 2>&1 || \
        warn "容器启动失败：$c"
    done <"$STATE_DIR/pre/docker-running"
  else
    info "没有升级前的容器记录，不自动启动容器。"
  fi
  docker ps -a --format '  {{.Names}}  {{.Status}}' 2>/dev/null || true
}

cmd_post_upgrade() {
  if is_true "$DRY_RUN"; then
    warn "dry-run：post 会修改系统，未执行。"
    return 0
  fi
  require_root
  setup_logging post
  . /etc/os-release 2>/dev/null || true
  if ! is_deepin_v25; then
    warn "当前不是 Deepin 25（$(os_pretty)），仍尝试修复。"
  fi

  section "刷新软件源（修复首次启动桌面异常的关键步骤）"
  local i
  for i in 1 2 3; do
    if apt_update; then ok "apt update 成功。"; break; fi
    warn "apt update 第 $i 次失败。"
    sleep 2
  done

  dpkg_repair
  section "补齐剩余升级"
  run_protected apt-get -y full-upgrade "${APT_OPTS[@]}" || warn "full-upgrade 未完全成功。"
  apt-get check >/dev/null 2>&1 && ok "apt 依赖关系正常。" || warn "apt 依赖关系不完整。"
  ensure_desktop_packages
  restart_dde_config
  lightdm_start || true
  local u uid
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    uid="$(user_uid "$u")"
    user_session_available "$uid" || continue
    restart_user_shell "$u" || true
  done < <(resolve_backup_users)
  restart_docker_after

  section "失败服务"
  systemctl --failed --no-pager || true
  section "本次启动错误日志（最后 50 条）"
  journalctl -b -p err --no-pager 2>/dev/null | tail -50 || true
  copy_logs_to_backup

  section "Post 完成"
  if is_true "$RESTART_SESSION_ON_POST"; then
    info "重启 lightdm 以重新加载桌面会话 ..."
    systemctl restart lightdm 2>/dev/null || true
  fi
  printf '桌面异常（窗口无边框、底部 dock 不出现）：\n'
  printf '  TTY 中执行 sudo %s fix-desktop\n' "$TOOL_NAME"
  printf '查看诊断：sudo %s diagnose\n' "$TOOL_NAME"
  printf '第三方源：sudo %s sources status\n' "$TOOL_NAME"
}

reset_user_dde_config() {
  local user="$1" home="$2" d stamp
  stamp="$(now_stamp)"
  for d in .config/dde-shell .config/dde-dock .config/deepin-daemon .config/dde-launcher .config/dde-file-manager; do
    [ -e "$home/$d" ] || continue
    mv -- "$home/$d" "$home/$d.bak-$stamp" || warn "无法移动 $home/$d"
    info "已重置 $home/$d -> $d.bak-$stamp"
  done
}

restart_user_shell() {
  local user="$1" uid
  uid="$(user_uid "$user")"
  user_session_available "$uid" || return 1
  run_as_user "$user" systemctl --user reset-failed 'dde-shell@DDE.service' 2>/dev/null || true
  if run_as_user "$user" systemctl --user restart 'dde-shell@DDE.service' 2>/dev/null; then
    ok "已重启 $user 的 dde-shell@DDE（dock/桌面）。"
    return 0
  fi
  warn "无法重启 $user 的 dde-shell@DDE（可能未登录图形会话）。"
  return 1
}

rebuild_caches() {
  local d
  if have gtk-update-icon-cache; then
    for d in /usr/share/icons/*; do
      [ -f "$d/index.theme" ] || continue
      gtk-update-icon-cache -f -t "$d" >/dev/null 2>&1 || true
    done
  fi
  have update-desktop-database && update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
  have fc-cache && fc-cache -f >/dev/null 2>&1 || true
}

cmd_fix_desktop() {
  if is_true "$DRY_RUN"; then
    warn "dry-run：fix-desktop 会修改系统，未执行。"
    return 0
  fi
  local restart_session=0 reset_config=0 only_user=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --restart-session) restart_session=1; shift ;;
      --reset-user-config) reset_config=1; shift ;;
      --user) [ $# -ge 2 ] || die "--user 需要参数"; only_user="$2"; shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  require_root
  setup_logging fix-desktop
  section "刷新 apt（实测可修复首次升级后 dock 不显示）"
  apt_update || warn "apt update 失败，继续用现有缓存修复。"
  dpkg_repair
  ensure_desktop_packages
  systemctl daemon-reload 2>/dev/null || true
  restart_dde_config
  rebuild_caches

  local -a users=()
  local u
  if [ -n "$only_user" ]; then
    getent passwd "$only_user" >/dev/null 2>&1 || die "未知用户：$only_user"
    users=("$only_user")
  else
    while IFS= read -r u; do users+=("$u"); done < <(resolve_backup_users)
  fi

  if [ "$reset_config" -eq 1 ]; then
    warn "将备份并重置 DDE 用户配置（不删除，改名为 .bak-时间）。"
    if ! confirm "继续重置桌面配置？"; then
      die "已取消。"
    fi
    for u in "${users[@]}"; do
      reset_user_dde_config "$u" "$(user_home "$u")"
    done
  fi

  local restarted=0
  for u in "${users[@]}"; do
    if restart_user_shell "$u"; then restarted=1; fi
  done
  if [ "$restarted" -eq 0 ]; then
    warn "没有可重启的图形会话；如刚登录，请注销后重新登录。"
  fi

  if [ "$restart_session" -eq 1 ]; then
    warn "重启 lightdm 会关闭当前所有图形程序。"
    if confirm "重启图形会话？"; then
      systemctl restart lightdm 2>/dev/null || warn "lightdm 重启失败。"
    fi
  fi

  section "桌面组件状态"
  systemctl status lightdm --no-pager -l 2>&1 | head -15 || true
  systemctl --failed --no-pager || true
  journalctl -b -p err --no-pager 2>/dev/null | tail -30 || true

  section "完成"
  printf '如果 dock 仍不出现：\n'
  printf '  sudo %s fix-desktop --restart-session\n' "$TOOL_NAME"
  printf '  sudo %s fix-desktop --reset-user-config --restart-session\n' "$TOOL_NAME"
  printf '  sudo %s diagnose\n' "$TOOL_NAME"
}

cmd_rescue() {
  if is_true "$DRY_RUN"; then
    warn "dry-run：rescue 会修改系统，未执行。"
    return 0
  fi
  local reinstall=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reinstall) reinstall=1; shift ;;
      *) die "未知参数：$1" ;;
    esac
  done
  require_root
  setup_logging rescue
  . /etc/os-release 2>/dev/null || true
  printf '版本：%s\n内核：%s\n' "$(os_pretty)" "$(uname -r)"
  printf '根分区：%s\n' "$(findmnt -no OPTIONS / 2>/dev/null || echo unknown)"

  local imm
  imm="$(immutable_packages)"
  if root_is_readonly || [ -n "$imm" ]; then
    if is_deepin_v25 || [ -n "$imm" ]; then
      warn "根分区只读或启用了磐石，apt 修复不会生效。先关闭只读保护并重启。"
    else
      warn "根分区只读，apt 修复不会生效。V23 没有磐石；检查文件系统错误或 /etc/fstab 中的 ro 挂载。"
    fi
    return 1
  fi

  apt_update || warn "apt update 失败，尝试用缓存修复。"
  dpkg_repair
  apt-get check >/dev/null 2>&1 && ok "apt 依赖关系正常。" || warn "apt 依赖关系仍不完整。"

  local p
  local -a missing=()
  for p in "${DESKTOP_PACKAGES[@]}"; do
    package_installed "$p" || missing+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    warn "缺失桌面包：${missing[*]}"
    apt_install "${missing[@]}" || warn "安装失败。"
  fi
  if [ "$reinstall" -eq 1 ]; then
    info "重装桌面关键包 ..."
    DEBIAN_FRONTEND=noninteractive apt-get -y --reinstall install "${APT_OPTS[@]}" \
      "${DESKTOP_PACKAGES[@]}" || warn "重装失败。"
  fi

  restart_dde_config
  lightdm_start || true
  section "失败服务"
  systemctl --failed --no-pager || true
  section "lightdm 日志"
  journalctl -u lightdm -b -n 40 --no-pager 2>/dev/null || true

  if systemctl is-active --quiet lightdm; then
    printf '\nlightdm 已运行。按 Ctrl+Alt+F7 回图形界面；仍黑屏就重启一次。\n'
  else
    printf '\nlightdm 仍未启动。检查上面的日志；仍不行就重启，或从 Windows 制作 U 盘安装 25 后恢复备份。\n'
  fi
  printf '如果只是 dock/窗口异常：sudo %s fix-desktop\n' "$TOOL_NAME"
}

cmd_sources() {
  local action="${1:-status}"
  [ $# -gt 0 ] && shift
  case "$action" in
    status|list) ;;
    *)
      if is_true "$DRY_RUN"; then
        warn "dry-run：sources $action 会修改软件源，未执行。"
        return 0
      fi ;;
  esac
  require_root
  setup_logging sources
  local qdir="$STATE_DIR/quarantine/apt-sources"
  case "$action" in
    status|list)
      section "当前软件源"
      [ -f "$APT_ETC_DIR/sources.list" ] && sed 's/^/  /' "$APT_ETC_DIR/sources.list" || true
      local f
      for f in "$APT_ETC_DIR"/sources.list.d/*.list "$APT_ETC_DIR"/sources.list.d/*.sources; do
        [ -e "$f" ] || continue
        printf '  %s\n' "$f"
        sed 's/^/    /' "$f"
      done
      section "已隔离的软件源"
      if [ -d "$qdir/disabled" ]; then
        find "$qdir/disabled" -maxdepth 1 -type f -printf '  %f\n' 2>/dev/null | sort || true
      else
        printf '  无\n'
      fi
      ;;
    restore)
      local target="${1:-}"
      [ -n "$target" ] || die "用法：deepin-v25 sources restore <文件名> | --all"
      [ -d "$qdir/disabled" ] || die "没有隔离的软件源。"
      apt_update >/dev/null 2>&1 || warn "当前软件源已无法完整刷新，恢复测试可能不准。"
      local -a files=()
      if [ "$target" = "--all" ]; then
        while IFS= read -r f; do files+=("$(basename -- "$f")"); done < <(find "$qdir/disabled" -maxdepth 1 -type f | sort)
      else
        files=("$(basename -- "$target")")
      fi
      for f in "${files[@]}"; do
        if [ ! -f "$qdir/disabled/$f" ] && [ ! -L "$qdir/disabled/$f" ]; then
          warn "不存在：$f"; continue
        fi
        if [ -e "$APT_ETC_DIR/sources.list.d/$f" ] || [ -L "$APT_ETC_DIR/sources.list.d/$f" ]; then
          warn "目标已存在，跳过：$f"; continue
        fi
        mv -- "$qdir/disabled/$f" "$APT_ETC_DIR/sources.list.d/$f" || { warn "移动失败：$f"; continue; }
        if apt_update >/dev/null 2>&1; then
          ok "已恢复：$f"
        else
          warn "恢复后 apt update 失败，重新隔离：$f"
          mv -- "$APT_ETC_DIR/sources.list.d/$f" "$qdir/disabled/$f" 2>/dev/null || true
        fi
      done
      apt-get check >/dev/null 2>&1 && ok "apt 依赖关系正常。" || warn "apt 依赖关系不完整。"
      ;;
    *) die "未知子命令：$action（status|restore）" ;;
  esac
}

cmd_diagnose() {
  require_root
  setup_logging diagnose
  local report="$LOG_DIR/diagnose-$(now_stamp).txt"
  section "收集诊断信息"
  {
    echo "=== Deepin 25 diagnose ==="
    date
    echo
    echo "--- os-release ---"; cat /etc/os-release 2>/dev/null || true
    echo "--- kernel ---"; uname -a
    echo "--- uptime ---"; uptime
    echo "--- mounts ---"; findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS / /boot 2>/dev/null || true
    echo "--- disk ---"; df -h / /boot 2>/dev/null || true; df -i / 2>/dev/null || true
    echo "--- failed units ---"; systemctl --failed --no-pager 2>&1 || true
    echo "--- dpkg audit ---"; dpkg --audit 2>&1 || true
    echo "--- apt check ---"; apt-get check 2>&1 || true
    echo "--- xsessions ---"; ls -l /usr/share/xsessions 2>&1 || true
    echo "--- desktop packages ---"
    dpkg-query -W -f='${Package} ${Version} ${Status}\n' \
      dde-shell dde-session dde-session-shell dde-kwin dde-appearance lightdm \
      xdg-desktop-portal-dde 2>/dev/null || true
    echo "--- processes ---"
    ps -eo pid,user,comm,args 2>/dev/null | grep -E 'dde-shell|dde-session|kwin|lightdm|dde-dconfig' | grep -v grep || true
    echo "--- lightdm ---"; systemctl status lightdm --no-pager -l 2>&1 | head -30 || true
    echo "--- dde-dconfig ---"; systemctl status dde-dconfig-daemon --no-pager -l 2>&1 | head -20 || true
    echo "--- boot errors ---"; journalctl -b -p err --no-pager 2>/dev/null | tail -100 || true
    echo "--- lightdm journal ---"; journalctl -u lightdm -b -n 80 --no-pager 2>/dev/null || true
    local u uid
    while IFS= read -r u; do
      uid="$(user_uid "$u")"
      echo
      echo "--- user $u (uid $uid) ---"
      if user_session_available "$uid"; then
        run_as_user "$u" systemctl --user --failed --no-pager 2>&1 || true
        run_as_user "$u" systemctl --user status 'dde-shell@DDE.service' --no-pager -l 2>&1 | head -40 || true
        run_as_user "$u" journalctl --user -b -n 80 --no-pager 2>&1 | tail -80 || true
        run_as_user "$u" bash -c 'DISPLAY=:0 XAUTHORITY="$HOME/.Xauthority" xprop -root _NET_SUPPORTING_WM_CHECK 2>&1' || true
        run_as_user "$u" bash -c 'DISPLAY=:0 XAUTHORITY="$HOME/.Xauthority" xprop -root _NET_CLIENT_LIST 2>&1' || true
      else
        echo "无活动用户会话（/run/user/$uid/bus 不存在）"
      fi
    done < <(resolve_backup_users)
  } >"$report" 2>&1
  ln -sfn "$report" "$LOG_DIR/latest-diagnose.txt" 2>/dev/null || true
  section "完成"
  printf '报告：%s\n' "$report"
  printf '失败的 systemd 单元：\n'
  systemctl --failed --no-pager 2>/dev/null || true
  printf '\n重点排查：\n'
  printf '  grep -iE "dde-shell|dock|kwin|dde-dconfig" %s\n' "$report"
  printf '  journalctl -b -p err --no-pager\n'
}

cmd_help() {
  cat <<EOF
$TOOL_NAME $TOOL_VERSION - 通用 Deepin 23 -> 25 原地升级工具

用法：sudo $TOOL_NAME <命令> [参数]

命令：
  preflight     只读检查（系统版本、磁盘、启动、显卡、镜像、备份）
  scan          扫描用户数据，生成备份路径建议
  backup        备份用户数据；--dest DIR 必填
  upgrade       执行原地升级（会停止 lightdm/Docker，需 TTY）
  post          首次进入 25 后运行；apt update + 修复桌面服务
  fix-desktop   修复 dock/窗口/桌面（含 TTY apt update 流程）
  rescue        TTY 中修复 apt/lightdm/桌面关键包
  restore       从备份恢复；--from DIR
  sources       查看/恢复第三方软件源（status|restore）
  diagnose      收集桌面故障诊断报告
  install       把工具复制到 /opt/deepin-v23-to-v25

全局参数：
  --config FILE   使用指定配置文件（默认 /etc/deepin-v23-to-v25.conf）
  --yes, -y       跳过交互确认
  --dry-run       只打印计划，不改动系统
  --force         跳过电源检查/图形终端限制（危险）
  --help, -h      显示帮助

示例：
  sudo $TOOL_NAME scan
  sudo $TOOL_NAME backup --dest /media/backup --passphrase-file /root/backup.pass
  sudo $TOOL_NAME upgrade
  sudo $TOOL_NAME post
  sudo $TOOL_NAME fix-desktop --restart-session
  sudo $TOOL_NAME restore --from /media/backup/deepin-backup-2026-11-11-120000 --map oldname=newname

详细文档：$REPO_ROOT/docs/
EOF
}
