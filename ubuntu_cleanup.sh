#!/usr/bin/env bash

# ==============================================================================
# Ubuntu VPS 深度清理与性能优化脚本
# - 可重复执行 / 安全默认 / 支持 dry-run / 支持分步骤
# - 面向 Docker 多容器 VPS：默认不删除容器与命名镜像，不触碰卷
# ==============================================================================

set -Eeuo pipefail

# ------------------------------ 默认配置 ------------------------------
VERSION="2.0.0"

# 运行模式：safe | standard | aggressive
MODE="safe"

# 是否自动确认（默认 false：交互确认更安全）
AUTO_CONFIRM="${AUTO_CONFIRM:-false}"

# dry-run：仅打印将执行的命令，不实际执行
DRY_RUN=false

# 日志文件（若不可写则回退到当前目录）
LOG_FILE_DEFAULT="/var/log/ubuntu_cleanup.log"
LOG_FILE="$LOG_FILE_DEFAULT"

# journald 限制（safe/standard/aggressive 会各自设置默认值）
JOURNAL_VACUUM_SIZE=""
JOURNAL_VACUUM_TIME=""

# 临时目录清理保留天数（mtime > N 天才删除）
TMP_DELETE_AFTER_DAYS=1

# /var/log 大文件截断阈值
TRUNCATE_LOGS_OVER="50M"

# 轮转/压缩日志删除：删除 /var/log 下 *.gz/*.xz/*.bz2/*.log.N 等
# 注意：默认只删除“旧的”轮转日志，避免影响当日排障
ROTATED_LOG_DELETE_AFTER_DAYS=7
DO_ROTATED_LOG_CLEAN=true

# 是否执行：旧内核清理（默认 standard/aggressive 才会执行）
DO_KERNEL_CLEAN=false

# 是否执行：Snap 清理（检测到 snap 才会运行；safe 模式只做 retain 设置）
DO_SNAP_CLEAN=false

# 是否执行：Docker 清理（检测到 docker 才会运行；默认安全策略）
DO_DOCKER_CLEAN=true

# 是否截断 Docker 容器 json 日志（/var/lib/docker/containers/*/*-json.log）
# 这是 VPS 常见“空间杀手”，截断不影响容器运行，但会丢失历史日志。
DO_DOCKER_LOG_TRUNCATE=false
DOCKER_LOG_TRUNCATE_OVER="20M"

# 是否执行：常见开发/构建缓存清理
DO_DEV_CACHE_CLEAN=false

# 是否执行：sysctl 优化（safe/standard/aggressive 都会执行“保守项”）
DO_SYSCTL_TUNE=true

# 是否执行：fstrim（需要 SSD/支持 discard；可选）
DO_FSTRIM=false

# 是否清理系统崩溃转储/核心转储
DO_COREDUMP_CLEAN=true

# 是否清理 APT lists（/var/lib/apt/lists/*）
# 这能释放空间，但下次 apt update 会重新下载。
DO_APT_LISTS_CLEAN=false

# 是否将 sysctl 永久写入 /etc/sysctl.d（比直接写 /etc/sysctl.conf 更干净）
PERSIST_SYSCTL=true
SYSCTL_DROPIN="/etc/sysctl.d/99-ubuntu-cleanup.conf"

# ------------------------------ 输出/日志 ------------------------------
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
    die "请使用 root 权限运行：sudo bash $0 ... 或 sudo ./$0 ..."
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# 统一执行命令：支持 dry-run
run() {
  if $DRY_RUN; then
    log_info "[dry-run] $*"
    return 0
  fi
  log_info "执行: $*"
  "$@"
}

confirm() {
  local prompt="$1"
  if [[ "$AUTO_CONFIRM" == "true" ]]; then
    log_info "AUTO_CONFIRM=true，自动确认：$prompt"
    return 0
  fi
  read -r -p "$prompt [y/N] " ans || true
  case "${ans,,}" in
    y|yes) return 0 ;;
    *)     return 1 ;;
  esac
}

bytes_used_rootfs() {
  # df 输出单位为 1K-blocks
  df -P / | awk 'NR==2 {print $3 * 1024}'
}

fmt_bytes() {
  # 兼容大多数 Ubuntu：numfmt 通常可用；否则回退
  local b="$1"
  if have_cmd numfmt; then
    numfmt --to=iec --suffix=B "$b"
  else
    echo "${b}B"
  fi
}

setup_logging() {
  # 若 /var/log 不可写（比如非 root / 或特殊系统），回退到当前目录
  if ! ( : >>"$LOG_FILE" ) 2>/dev/null; then
    LOG_FILE="./ubuntu_cleanup.log"
  fi
  exec > >(tee -a "$LOG_FILE") 2>&1
  log_info "日志文件: $LOG_FILE"
}

on_err() {
  local exit_code=$?
  log_error "脚本出错 (exit=$exit_code)。请查看日志：$LOG_FILE"
  exit "$exit_code"
}
trap on_err ERR

usage() {
  cat <<'EOF'
用法:
  sudo ./ubuntu_cleanup.sh [选项]

选项:
  --mode {safe|standard|aggressive}   预设强度（默认 safe）
  --dry-run                           仅打印命令，不执行
  --yes                               等同 AUTO_CONFIRM=true
  --no-docker                          跳过 Docker 清理
  --docker                             强制开启 Docker 清理
  --docker-log-truncate                 截断 Docker 容器 json 日志（空间杀手，丢失历史日志）
  --kernel-clean                        清理旧内核（谨慎，建议维护窗口）
  --snap-clean                          清理 Snap disabled 旧版本（检测到 snap 才生效）
  --dev-cache-clean                     清理常见开发/构建缓存（pip/npm/gradle 等，谨慎）
  --apt-lists-clean                     清理 /var/lib/apt/lists/*（下次 apt update 会重下）
  --no-coredump-clean                   跳过 coredump/crash 清理
  --fstrim                              执行 fstrim（支持 discard 时可提升 SSD 性能）
  --log-file /path/to/log               指定日志文件
  -h, --help                           显示帮助

说明:
  1) safe：默认不删容器/卷/命名镜像；只做安全释放空间与保守优化。
  2) standard：在 safe 基础上更积极（包含旧内核、更多日志/缓存）。
  3) aggressive：面向“我知道我在做什么”，可能清理更多缓存与残留。
EOF
}

parse_args() {
  # 这些 FORCE_* 用于确保用户显式开启的选项不被 mode 默认值覆盖
  FORCE_KERNEL_CLEAN=false
  FORCE_SNAP_CLEAN=false
  FORCE_DEV_CACHE_CLEAN=false
  FORCE_DOCKER_LOG_TRUNCATE=false
  FORCE_APT_LISTS_CLEAN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        MODE="${2:-}"; shift 2 ;;
      --dry-run)
        DRY_RUN=true; shift ;;
      --yes)
        AUTO_CONFIRM=true; shift ;;
      --no-docker)
        DO_DOCKER_CLEAN=false; shift ;;
      --docker)
        DO_DOCKER_CLEAN=true; shift ;;
      --docker-log-truncate)
        DO_DOCKER_LOG_TRUNCATE=true; FORCE_DOCKER_LOG_TRUNCATE=true; shift ;;
      --kernel-clean)
        DO_KERNEL_CLEAN=true; FORCE_KERNEL_CLEAN=true; shift ;;
      --snap-clean)
        DO_SNAP_CLEAN=true; FORCE_SNAP_CLEAN=true; shift ;;
      --dev-cache-clean)
        DO_DEV_CACHE_CLEAN=true; FORCE_DEV_CACHE_CLEAN=true; shift ;;
      --apt-lists-clean)
        DO_APT_LISTS_CLEAN=true; FORCE_APT_LISTS_CLEAN=true; shift ;;
      --no-coredump-clean)
        DO_COREDUMP_CLEAN=false; shift ;;
      --fstrim)
        DO_FSTRIM=true; shift ;;
      --log-file)
        LOG_FILE="${2:-}"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "未知参数: $1（用 -h 查看帮助）" ;;
    esac
  done

  case "$MODE" in
    safe|standard|aggressive) ;;
    *) die "--mode 只能是 safe|standard|aggressive" ;;
  esac
}

apply_mode_defaults() {
  case "$MODE" in
    safe)
      # 日常可重复：保守清理
      JOURNAL_VACUUM_SIZE="100M"
      JOURNAL_VACUUM_TIME="7d"
      ROTATED_LOG_DELETE_AFTER_DAYS=14
      DO_KERNEL_CLEAN=false
      DO_SNAP_CLEAN=false
      DO_DEV_CACHE_CLEAN=false
      DO_DOCKER_LOG_TRUNCATE=false
      DO_APT_LISTS_CLEAN=false
      ;;
    standard)
      # 空间更敏感：更积极但仍尽量安全
      JOURNAL_VACUUM_SIZE="50M"
      JOURNAL_VACUUM_TIME="14d"
      ROTATED_LOG_DELETE_AFTER_DAYS=7
      DO_KERNEL_CLEAN=true
      DO_SNAP_CLEAN=true
      DO_DEV_CACHE_CLEAN=true
      DO_DOCKER_LOG_TRUNCATE=true
      DO_APT_LISTS_CLEAN=false
      ;;
    aggressive)
      # 我知道我在做什么：尽可能释放空间
      JOURNAL_VACUUM_SIZE="20M"
      JOURNAL_VACUUM_TIME="30d"
      ROTATED_LOG_DELETE_AFTER_DAYS=1
      DO_KERNEL_CLEAN=true
      DO_SNAP_CLEAN=true
      DO_DEV_CACHE_CLEAN=true
      DO_DOCKER_LOG_TRUNCATE=true
      DO_APT_LISTS_CLEAN=true
      ;;
  esac

  # 参数显式开启拥有最高优先级（允许在 safe 模式下启用这些清理项）
  # 说明：parse_args() 先跑，apply_mode_defaults() 后跑；这里保证显式开关不被模式覆盖。
  if [[ "${FORCE_KERNEL_CLEAN:-false}" == "true" ]]; then
    DO_KERNEL_CLEAN=true
  fi
  if [[ "${FORCE_DEV_CACHE_CLEAN:-false}" == "true" ]]; then
    DO_DEV_CACHE_CLEAN=true
  fi
  if [[ "${FORCE_SNAP_CLEAN:-false}" == "true" ]]; then
    DO_SNAP_CLEAN=true
  fi
  if [[ "${FORCE_DOCKER_LOG_TRUNCATE:-false}" == "true" ]]; then
    DO_DOCKER_LOG_TRUNCATE=true
  fi
  if [[ "${FORCE_APT_LISTS_CLEAN:-false}" == "true" ]]; then
    DO_APT_LISTS_CLEAN=true
  fi
}

print_detect() {
  log_step "环境探测"
  log_info "MODE=$MODE DRY_RUN=$DRY_RUN AUTO_CONFIRM=$AUTO_CONFIRM"
  log_info "Docker: $(have_cmd docker && echo yes || echo no)"
  log_info "Snap:   $(have_cmd snap && echo yes || echo no)"
  if [[ -r /proc/meminfo ]]; then
    local mem_kb
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo || echo 0)
    log_info "内存:   $((mem_kb/1024)) MiB"
  fi
}

# ------------------------------ 清理：APT ------------------------------
clean_apt() {
  log_step "APT 清理"
  have_cmd apt-get || { log_warn "未发现 apt-get，跳过 APT 清理"; return 0; }

  if confirm "执行 APT 清理（autoremove/clean/autoclean）？"; then
    run dpkg --configure -a || true
    run apt-get -y update || true

    # clean: 清空 /var/cache/apt/archives
    run apt-get -y clean

    # autoclean: 清理过期 .deb
    run apt-get -y autoclean || true

    # autoremove: 卸载孤儿包
    run apt-get -y autoremove --purge

    # 可选：清理 lists（可释放几十到几百 MB；下次 apt update 会重新下载）
    if $DO_APT_LISTS_CLEAN; then
      if confirm "清理 /var/lib/apt/lists/* 以进一步释放空间？"; then
        run rm -rf /var/lib/apt/lists/*
      fi
    fi

    log_success "APT 清理完成"
  else
    log_info "跳过 APT 清理"
  fi
}

# ------------------------------ 清理：Docker（安全） ------------------------------
clean_docker_safe() {
  log_step "Docker 清理（安全模式）"
  if ! $DO_DOCKER_CLEAN; then
    log_info "已配置跳过 Docker 清理"
    return 0
  fi
  if ! have_cmd docker; then
    log_info "未检测到 docker，跳过"
    return 0
  fi

  log_warn "策略：不删除容器、不删除卷、不删除命名镜像；仅清理悬空镜像/构建缓存/未使用网络。"
  if confirm "执行 Docker 安全清理？"; then
    run docker image prune -f
    run docker builder prune -f
    run docker network prune -f
    log_success "Docker 清理完成（未触碰容器/卷）"
  else
    log_info "跳过 Docker 清理"
  fi

  # Docker json 日志：大概率占用大量空间，截断是“保护系统”的常见做法
  if $DO_DOCKER_LOG_TRUNCATE; then
    log_warn "可选：截断 Docker 容器 json 日志（会丢失历史日志，但不会影响容器运行）"
    if confirm "截断 /var/lib/docker/containers/*/*-json.log 中超过 $DOCKER_LOG_TRUNCATE_OVER 的日志文件？"; then
      run find /var/lib/docker/containers -type f -name "*-json.log" -size "+$DOCKER_LOG_TRUNCATE_OVER" -exec truncate -s 0 {} \; || true
      log_success "Docker json 日志截断完成"
    fi
  fi
}

# ------------------------------ 清理：Snap ------------------------------
clean_snap() {
  log_step "Snap 清理"
  if ! have_cmd snap; then
    log_info "未检测到 snap，跳过"
    return 0
  fi

  # 无论是否 aggressive，都可以安全设置 retain
  if confirm "设置 Snap 保留版本为 2（refresh.retain=2）？"; then
    run snap set system refresh.retain=2
  fi

  if ! $DO_SNAP_CLEAN; then
    log_info "模式/配置未启用 Snap 旧版本清理，跳过"
    return 0
  fi

  if confirm "移除 disabled 的旧版本 Snap（可能短暂影响 snap 服务）？"; then
    # shellcheck disable=SC2016
    snap list --all | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
      [[ -n "${snapname:-}" && -n "${revision:-}" ]] || continue
      run snap remove "$snapname" --revision="$revision"
    done
    log_success "Snap disabled 旧版本清理完成"
  else
    log_info "跳过 Snap disabled 旧版本清理"
  fi
}

# ------------------------------ 清理：日志/临时/缓存 ------------------------------
clean_logs_and_tmp() {
  log_step "日志与临时目录清理"

  # journald
  if have_cmd journalctl; then
    if confirm "清理 Systemd Journal（size=$JOURNAL_VACUUM_SIZE, time=$JOURNAL_VACUUM_TIME）？"; then
      # rotate 让 vacuum 更彻底
      run journalctl --rotate || true
      run journalctl --vacuum-size="$JOURNAL_VACUUM_SIZE" --vacuum-time="$JOURNAL_VACUUM_TIME" || true
    fi
  fi

  # 轮转/压缩日志：删除旧的 *.gz/*.xz/*.bz2/*.log.N 等
  if $DO_ROTATED_LOG_CLEAN; then
    if confirm "删除 /var/log 下轮转/压缩日志（mtime>$ROTATED_LOG_DELETE_AFTER_DAYS 天）？"; then
      run find /var/log -type f \
        \( -name "*.gz" -o -name "*.xz" -o -name "*.bz2" -o -regex ".*\\.log\\.[0-9]+$" -o -regex ".*\\.[0-9]+$" \) \
        -mtime "+$ROTATED_LOG_DELETE_AFTER_DAYS" -delete || true
    fi
  fi

  # /var/log 大文件截断（保留文件避免服务因 missing log 崩）
  if confirm "截断 /var/log 下超过 $TRUNCATE_LOGS_OVER 的 .log 文件（保留文件名）？"; then
    run find /var/log -type f -name "*.log" -size "+$TRUNCATE_LOGS_OVER" -exec truncate -s 0 {} \;
  fi

  # systemd-tmpfiles
  if have_cmd systemd-tmpfiles; then
    if confirm "执行 systemd-tmpfiles --clean（清理系统临时文件策略命中的条目）？"; then
      run systemd-tmpfiles --clean || true
    fi
  fi

  # /tmp /var/tmp
  if confirm "清理临时目录 /tmp 与 /var/tmp（删除 mtime>$TMP_DELETE_AFTER_DAYS 天的文件）？"; then
    run find /tmp -mindepth 1 -mtime "+$TMP_DELETE_AFTER_DAYS" -delete
    run find /var/tmp -mindepth 1 -mtime "+$TMP_DELETE_AFTER_DAYS" -delete
  fi

  # 用户缓存：safe 模式只清理 root 的 apt/pip 等常见缓存目录的“安全子集”
  if confirm "清理用户缓存（/root/.cache 与 /home/*/.cache 内容）？"; then
    run rm -rf /root/.cache/* || true
    for user_dir in /home/*; do
      [[ -d "$user_dir/.cache" ]] || continue
      run rm -rf "$user_dir/.cache"/* || true
      log_info "已清理: $user_dir/.cache"
    done
  fi
}

clean_dev_caches_aggressive() {
  log_step "开发/构建缓存清理（谨慎）"
  if ! $DO_DEV_CACHE_CLEAN; then
    log_info "未启用 dev-cache-clean，跳过"
    return 0
  fi

  log_warn "这会删除一些可再生缓存（可能导致下次构建/安装变慢）。不会删除项目源码。"
  if ! confirm "确认清理常见开发/构建缓存（pip/npm/yarn/pnpm/gradle/maven/go/rust 等）？"; then
    log_info "跳过开发缓存清理"
    return 0
  fi

  # root
  run rm -rf \
    /root/.cache/pip \
    /root/.cache/pypoetry \
    /root/.cache/uv \
    /root/.npm \
    /root/.yarn \
    /root/.pnpm-store \
    /root/.gradle \
    /root/.m2 \
    /root/.cargo/registry \
    /root/.cargo/git \
    /root/.cache/go-build \
    /root/go/pkg/mod/cache \
    /root/.composer/cache \
    /root/.cache/composer \
    /root/.cache/ms-playwright \
    /root/.cache/puppeteer \
    /root/.cache/selenium \
    || true

  # /home users
  for user_dir in /home/*; do
    [[ -d "$user_dir" ]] || continue
    run rm -rf \
      "$user_dir/.cache/pip" \
      "$user_dir/.cache/pypoetry" \
      "$user_dir/.cache/uv" \
      "$user_dir/.npm" \
      "$user_dir/.yarn" \
      "$user_dir/.pnpm-store" \
      "$user_dir/.gradle" \
      "$user_dir/.m2" \
      "$user_dir/.cargo/registry" \
      "$user_dir/.cargo/git" \
      "$user_dir/.cache/go-build" \
      "$user_dir/go/pkg/mod/cache" \
      "$user_dir/.composer/cache" \
      "$user_dir/.cache/composer" \
      "$user_dir/.cache/ms-playwright" \
      "$user_dir/.cache/puppeteer" \
      "$user_dir/.cache/selenium" \
      || true
  done

  log_success "开发/构建缓存清理完成"
}

# ------------------------------ 清理：旧内核 ------------------------------
clean_old_kernels() {
  log_step "旧内核清理"
  if ! $DO_KERNEL_CLEAN; then
    log_info "模式/配置未启用旧内核清理，跳过"
    return 0
  fi
  have_cmd apt-get || { log_warn "未发现 apt-get，跳过"; return 0; }
  have_cmd dpkg-query || have_cmd dpkg || { log_warn "未发现 dpkg-query/dpkg，跳过"; return 0; }

  local current_kernel current_pkg
  current_kernel=$(uname -r)
  current_pkg="linux-image-${current_kernel}"

  # 收集已安装 linux-image-*，并按版本排序
  # 显式初始化为空数组，避免在 set -u 场景下出现 "unbound variable"
  local -a images=()
  if have_cmd dpkg-query; then
    mapfile -t images < <(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | sort -V)
  else
    mapfile -t images < <(dpkg --list | awk '/^ii  linux-image-[0-9]/{print $2}' | sort -V)
  fi

  if (( ${#images[@]} == 0 )); then
    log_info "未发现 linux-image-* 包"
    return 0
  fi

  # 保留：当前运行内核 + 最新一个内核（作为回滚）
  local latest_pkg
  latest_pkg="${images[-1]}"

  local -a keep=()
  keep=("$current_pkg")
  if [[ "$latest_pkg" != "$current_pkg" ]]; then
    keep+=("$latest_pkg")
  fi

  # 构造待删除列表：除 keep 之外的所有 linux-image-*（同时尽量带上 headers/modules）
  # 显式初始化为空数组，避免在 set -u 场景下出现 "unbound variable"
  local -a purge=()
  local pkg
  for pkg in "${images[@]}"; do
    if [[ " $current_pkg $latest_pkg " == *" $pkg "* ]]; then
      continue
    fi

    purge+=("$pkg")

    # 提取版本后缀，用于匹配 headers/modules
    local ver
    ver="${pkg#linux-image-}"

    # headers/modules/extra 可能存在也可能不存在；不存在不会影响 apt-get purge
    purge+=("linux-headers-$ver" "linux-modules-$ver" "linux-modules-extra-$ver")
  done

  if (( ${#purge[@]} == 0 )); then
    log_info "仅存在需要保留的内核（当前/最新），无需清理"
    return 0
  fi

  log_warn "将移除旧内核相关包（保留: ${keep[*]}）："
  printf '%s\n' "${purge[@]}" | awk 'NF' | sort -u | sed 's/^/  - /'

  if confirm "确认移除旧内核包并 update-grub（建议维护窗口执行）？"; then
    # 去重后 purge
    # shellcheck disable=SC2046
    run apt-get -y purge $(printf '%s\n' "${purge[@]}" | awk 'NF' | sort -u)

    # 再做一次 autoremove，清掉残留依赖
    run apt-get -y autoremove --purge

    if have_cmd update-grub; then
      run update-grub
    fi
    log_success "旧内核清理完成（建议稍后重启）"
  else
    log_info "跳过旧内核清理"
  fi
}

# ------------------------------ 优化：sysctl ------------------------------
apply_sysctl() {
  local key="$1" val="$2"
  run sysctl -w "$key=$val"
  if $PERSIST_SYSCTL; then
    # 幂等写入：已存在则替换
    if [[ ! -f "$SYSCTL_DROPIN" ]]; then
      run bash -c "umask 022; : > '$SYSCTL_DROPIN'"
    fi
    if grep -qE "^${key}=" "$SYSCTL_DROPIN" 2>/dev/null; then
      run sed -i "s/^${key}=.*/${key}=${val}/" "$SYSCTL_DROPIN"
    else
      run bash -c "echo '${key}=${val}' >> '$SYSCTL_DROPIN'"
    fi
  fi
}

tune_sysctl() {
  log_step "性能参数优化（sysctl）"
  if ! $DO_SYSCTL_TUNE; then
    log_info "已配置跳过 sysctl 优化"
    return 0
  fi
  have_cmd sysctl || { log_warn "未发现 sysctl，跳过"; return 0; }

  # 根据内存大小选择更保守参数
  local mem_kb
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)

  if confirm "应用推荐 sysctl（swappiness/vfs_cache_pressure 等）并可持久化到 $SYSCTL_DROPIN？"; then
    # swappiness：Docker 主机通常希望减少 swap 抖动
    apply_sysctl vm.swappiness 10

    # vfs_cache_pressure：内存足够时降低，让 inode/dentry 缓存保留更久
    if [[ "$mem_kb" -ge 2000000 ]]; then
      apply_sysctl vm.vfs_cache_pressure 50
    else
      log_info "内存较小（$((mem_kb/1024))MiB），保持默认 vfs_cache_pressure（不强行修改）"
    fi

    log_success "sysctl 优化完成"
  else
    log_info "跳过 sysctl 优化"
  fi
}

# ------------------------------ 清理：coredump/crash ------------------------------
clean_coredumps() {
  log_step "coredump/crash 清理"
  if ! $DO_COREDUMP_CLEAN; then
    log_info "已配置跳过 coredump/crash 清理"
    return 0
  fi

  local did=false

  if [[ -d /var/lib/systemd/coredump ]]; then
    log_warn "/var/lib/systemd/coredump 可能占用大量空间（核心转储）"
    if confirm "删除 /var/lib/systemd/coredump 下所有文件？"; then
      run rm -rf /var/lib/systemd/coredump/* || true
      did=true
    fi
  fi

  if [[ -d /var/crash ]]; then
    if confirm "删除 /var/crash 下的崩溃报告文件？"; then
      run rm -rf /var/crash/* || true
      did=true
    fi
  fi

  if $did; then
    log_success "coredump/crash 清理完成"
  else
    log_info "未执行 coredump/crash 清理"
  fi
}

# ------------------------------ 优化：fstrim ------------------------------
fstrim_disks() {
  log_step "fstrim（可选）"
  if ! $DO_FSTRIM; then
    log_info "未启用 fstrim，跳过"
    return 0
  fi
  have_cmd fstrim || { log_warn "未发现 fstrim，跳过"; return 0; }

  log_warn "fstrim 适用于支持 discard 的 SSD/云盘，可回收已删除块，可能提升长期性能。"
  if confirm "执行 fstrim -av？"; then
    run fstrim -av || true
    log_success "fstrim 执行完成"
  else
    log_info "跳过 fstrim"
  fi
}

# ------------------------------ 主流程 ------------------------------
main() {
  parse_args "$@"
  apply_mode_defaults
  need_root
  setup_logging

  local start end freed
  start=$(bytes_used_rootfs)

  print_detect

  clean_apt
  clean_docker_safe
  clean_snap
  clean_logs_and_tmp
  clean_coredumps
  clean_dev_caches_aggressive
  clean_old_kernels
  tune_sysctl
  fstrim_disks

  log_step "清理摘要"
  end=$(bytes_used_rootfs)
  if (( end > start )); then
    freed=0
  else
    freed=$(( start - end ))
  fi
  echo "------------------------------------------------"
  echo "初始已用: $(fmt_bytes "$start")"
  echo "最终已用: $(fmt_bytes "$end")"
  echo "本次释放: $(fmt_bytes "$freed")"
  echo "日志文件: $LOG_FILE"
  echo "------------------------------------------------"
  log_success "完成"
}

main "$@"
