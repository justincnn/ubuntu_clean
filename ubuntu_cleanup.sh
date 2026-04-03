#!/usr/bin/env bash

# ==============================================================================
# Ubuntu VPS 极速彻底清理脚本 (Aggressive & Unattended Version)
# - 无需确认，直接执行
# - Docker 彻底清理 (删除所有停止容器、未使用镜像、未使用数据卷)
# - 日志“绝户式”清理 (不保留任何历史日志，所有活跃日志截断为 0)
# ==============================================================================

set -Eeuo pipefail

# ------------------------------ 输出/日志 ------------------------------
LOG_FILE="/var/log/ubuntu_cleanup_aggressive.log"

_color() { local c="$1"; shift; printf "\033[%sm%s\033[0m" "$c" "$*"; }
log_info()    { echo -e "$(_color 36 [INFO]) $(date '+%F %T') $*"; }
log_warn()    { echo -e "$(_color 33 [WARN]) $(date '+%F %T') $*"; }
log_error()   { echo -e "$(_color 31 [ERR ]) $(date '+%F %T') $*"; }
log_success() { echo -e "$(_color 32 [OK  ]) $(date '+%F %T') $*"; }
log_step()    { echo -e "\n$(_color 35 '>>') $(_color 35 "$*")"; }

die() { log_error "$*"; exit 1; }

# ------------------------------ 工具函数 ------------------------------
need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请使用 root 权限运行：sudo bash $0"
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

run() {
  log_info "执行: $*"
  "$@"
}

bytes_used_total() {
  df -P -l -x tmpfs -x devtmpfs -x devfs -x squashfs 2>/dev/null | awk 'NR>1 {sum += $3} END {print sum * 1024}'
}

fmt_bytes() {
  local b="$1"
  if have_cmd numfmt; then
    numfmt --to=iec --suffix=B "$b"
  else
    echo "${b}B"
  fi
}

setup_logging() {
  if ! ( : >>"$LOG_FILE" ) 2>/dev/null; then
    LOG_FILE="./ubuntu_cleanup_aggressive.log"
  fi
  exec > >(tee -a "$LOG_FILE") 2>&1
  log_info "日志文件: $LOG_FILE"
}

on_err() {
  local exit_code=$?
  log_error "脚本出错 (exit=$exit_code)。"
  exit "$exit_code"
}
trap on_err ERR

# ------------------------------ 清理模块 ------------------------------

clean_apt() {
  log_step "1. APT 彻底清理"
  have_cmd apt-get || return 0
  
  run dpkg --configure -a || true
  run apt-get -y update || true
  run apt-get -y autoremove --purge
  run apt-get -y autoclean || true
  run apt-get -y clean

  log_info "清理 APT Lists 缓存..."
  run find /var/lib/apt/lists/ -mindepth 1 -delete || true
  log_success "APT 清理完成"
}

clean_docker_aggressive() {
  log_step "2. Docker 彻底清理 (警告: 将删除所有未使用镜像和卷)"
  have_cmd docker || { log_info "未检测到 Docker，跳过"; return 0; }

  # 彻底清理 Docker 系统 (包括所有未使用的数据卷、未使用的镜像、停止的容器)
  run docker system prune -a --volumes -f || true

  # 强制截断所有幸存容器的 JSON 日志到 0 字节 (无视大小)
  log_info "清空所有 Docker 容器日志文件..."
  run find /var/lib/docker/containers -type f -name "*-json.log" -exec truncate -s 0 {} \; || true
  
  log_success "Docker 彻底清理完成"
}

clean_snap() {
  log_step "3. Snap 彻底清理"
  have_cmd snap || return 0

  run snap set system refresh.retain=2 || true
  log_info "移除已禁用的 Snap 旧版本..."
  snap list --all | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
    [[ -n "${snapname:-}" && -n "${revision:-}" ]] || continue
    run snap remove "$snapname" --revision="$revision" || true
  done
  log_success "Snap 清理完成"
}

clean_logs_and_tmp() {
  log_step "4. 日志与临时目录绝户式清理"

  # Systemd Journal 彻底清空 (仅保留最近 1 秒)
  if have_cmd journalctl; then
    run journalctl --rotate || true
    run journalctl --vacuum-time=1s || true
  fi

  # 删除所有压缩和轮转的历史日志
  log_info "删除历史轮转日志..."
  run find /var/log -type f \( -name "*.gz" -o -name "*.xz" -o -name "*.bz2" -o -regex ".*\\.[0-9]+$" -o -name "*.old" \) -delete || true

  # 截断所有当前正在写入的常规日志
  log_info "截断 /var/log 下的所有运行日志为 0 字节..."
  run find /var/log -type f \( -name "*.log" -o -name "syslog*" -o -name "messages*" -o -name "auth*" -o -name "daemon*" -o -name "kern*" \) -exec truncate -s 0 {} \; || true
  
  # 清空登录相关二进制日志
  > /var/log/wtmp || true
  > /var/log/btmp || true
  > /var/log/lastlog || true

  # systemd 临时文件清理
  have_cmd systemd-tmpfiles && run systemd-tmpfiles --clean || true

  # 无视时间，直接清空 /tmp 和 /var/tmp
  log_info "清空临时目录 /tmp 与 /var/tmp..."
  for tmpdir in /tmp /var/tmp; do
    run find "$tmpdir" -xdev -mindepth 1 \( -type f -o -type l \) -delete || true
    run find "$tmpdir" -xdev -mindepth 1 -type d -empty -delete || true
  done

  # 清空缓存目录
  log_info "清空用户 .cache 目录..."
  [[ -d /root/.cache ]] && run find /root/.cache -mindepth 1 -delete || true
  for user_dir in /home/*; do
    [[ -d "$user_dir/.cache" ]] && run find "$user_dir/.cache" -mindepth 1 -delete || true
  done

  log_success "日志与临时文件绝户式清理完成"
}

clean_dev_caches_aggressive() {
  log_step "5. 开发/构建缓存无差别清理"
  
  local cache_paths=(
    ".cache/pip" ".cache/pypoetry" ".cache/uv" ".npm" ".yarn" ".pnpm-store"
    ".gradle" ".m2" ".cargo/registry" ".cargo/git" ".cache/go-build" "go/pkg/mod/cache"
    ".composer/cache" ".cache/composer" ".cache/ms-playwright" ".cache/puppeteer" ".cache/selenium"
  )

  local target_users=( "/root" )
  for d in /home/*; do [[ -d "$d" ]] && target_users+=("$d"); done

  for user_home in "${target_users[@]}"; do
    for cpath in "${cache_paths[@]}"; do
      [[ -d "$user_home/$cpath" ]] && run find "$user_home/$cpath" -mindepth 1 -delete || true
    done
  done
  log_success "开发构建缓存清理完成"
}

clean_old_kernels() {
  log_step "6. 自动清理旧内核"
  have_cmd apt-get || return 0

  local current_kernel current_pkg
  current_kernel=$(uname -r)
  current_pkg="linux-image-${current_kernel}"

  local -a images=()
  if have_cmd dpkg-query; then
    mapfile -t images < <(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | sort -V)
  else
    mapfile -t images < <(dpkg --list | awk '/^ii  linux-image-[0-9]/{print $2}' | sort -V)
  fi

  (( ${#images[@]} == 0 )) && return 0

  local latest_pkg="${images[-1]}"
  local -a keep=("$current_pkg")
  [[ "$latest_pkg" != "$current_pkg" ]] && keep+=("$latest_pkg")

  local -a purge=()
  for pkg in "${images[@]}"; do
    if [[ " ${keep[*]} " == *" $pkg "* ]]; then continue; fi
    purge+=("$pkg")
    local ver="${pkg#linux-image-}"
    purge+=("linux-headers-$ver" "linux-modules-$ver" "linux-modules-extra-$ver")
  done

  if (( ${#purge[@]} > 0 )); then
    # shellcheck disable=SC2046
    run apt-get -y purge $(printf '%s\n' "${purge[@]}" | awk 'NF' | sort -u) || true
    run apt-get -y autoremove --purge || true
    have_cmd update-grub && run update-grub
    log_success "旧内核已清理"
  else
    log_info "无需清理旧内核"
  fi
}

clean_coredumps() {
  log_step "7. Coredump / Crash 崩溃报告清理"
  [[ -d /var/lib/systemd/coredump ]] && run find /var/lib/systemd/coredump -mindepth 1 -delete || true
  [[ -d /var/crash ]] && run find /var/crash -mindepth 1 -delete || true
  log_success "崩溃日志已清空"
}

# ------------------------------ 主流程 ------------------------------
main() {
  need_root
  setup_logging

  local start end freed
  start=$(bytes_used_total)

  log_warn "=== 即将开始无脑极速清理，全程无确认，强制执行 ==="
  
  clean_apt
  clean_docker_aggressive
  clean_snap
  clean_logs_and_tmp
  clean_dev_caches_aggressive
  clean_old_kernels
  clean_coredumps

  log_step "清理摘要"
  end=$(bytes_used_total)
  if (( end > start )); then freed=0; else freed=$(( start - end )); fi
  
  echo "------------------------------------------------"
  echo "初始已用: $(fmt_bytes "$start")"
  echo "最终已用: $(fmt_bytes "$end")"
  echo -e "\033[32m本次释放: $(fmt_bytes "$freed")\033[0m"
  echo "------------------------------------------------"
  log_success "清理彻底完成！"
}

main "$@"
