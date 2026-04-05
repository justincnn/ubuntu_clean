#!/usr/bin/env bash
# ==============================================================================
# Ubuntu VPS 极速彻底清理脚本 
# - 修正了在 Oracle VPS/Docker 环境下由于 overlay 挂载导致的统计不准问题
# - 在摘要中新增：总硬盘容量、可用容量、清理前后对比
# ==============================================================================

set -Eeuo pipefail

# ------------------------------ 输出/日志 ------------------------------
LOG_FILE="/var/log/ubuntu_cleanup_enhanced.log"

_color() { local c="$1"; shift; printf "\033[%sm%s\033[0m" "$c" "$*"; }
log_info() { echo -e "$(_color 36 [INFO]) $(date '+%F %T') $*"; }
log_warn() { echo -e "$(_color 33 [WARN]) $(date '+%F %T') $*"; }
log_error() { echo -e "$(_color 31 [ERR ]) $(date '+%F %T') $*"; }
log_success() { echo -e "$(_color 32 [OK ]) $(date '+%F %T') $*"; }
log_step() { echo -e "\n$(_color 35 '>>') $(_color 35 "$*")"; }

die() { log_error "$*"; exit 1; }

# ------------------------------ 工具函数 ------------------------------
need_root() { if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then die "请使用 root 权限运行：sudo bash $0"; fi; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# 获取磁盘统计数据 (返回字节: 总容量 已用 可用)
# 使用 / 目录作为统计基准，这是 VPS 最核心的物理磁盘分区
get_disk_stats() {
    # 使用 1024 字节块 (-P 兼容性好)
    df -P / 2>/dev/null | awk 'NR==2 {print $2*1024, $3*1024, $4*1024}'
}

fmt_bytes() {
    local b="$1"
    if have_cmd numfmt; then
        numfmt --to=iec --suffix=B "$b"
    else
        echo "${b}B"
    fi
}

run() { log_info "执行: $*"; "$@"; }

setup_logging() {
    if ! ( : >>"$LOG_FILE" ) 2>/dev/null; then LOG_FILE="./ubuntu_cleanup.log"; fi
    exec > >(tee -a "$LOG_FILE") 2>&1
    log_info "日志文件: $LOG_FILE"
}

on_err() { local exit_code=$?; log_error "脚本出错 (exit=$exit_code)。"; exit "$exit_code"; }
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
}

clean_docker_aggressive() {
    log_step "2. Docker 彻底清理"
    have_cmd docker || { log_info "未检测到 Docker，跳过"; return 0; }
    run docker system prune -a --volumes -f || true
    log_info "清空容器日志..."
    run find /var/lib/docker/containers -type f -name "*-json.log" -exec truncate -s 0 {} \; || true
}

clean_snap() {
    log_step "3. Snap 彻底清理"
    have_cmd snap || return 0
    run snap set system refresh.retain=2 || true
    snap list --all | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
        [[ -n "${snapname:-}" && -n "${revision:-}" ]] || continue
        run snap remove "$snapname" --revision="$revision" || true
    done
}

clean_logs_and_tmp() {
    log_step "4. 日志与临时目录清理"
    if have_cmd journalctl; then
        run journalctl --rotate || true
        run journalctl --vacuum-time=1s || true
    fi
    run find /var/log -type f \( -name "*.gz" -o -name "*.xz" -o -name "*.bz2" -o -regex ".*\\.[0-9]+$" -o -name "*.old" \) -delete || true
    run find /var/log -type f \( -name "*.log" -o -name "syslog*" -o -name "messages*" \) -exec truncate -s 0 {} \; || true
    for tmpdir in /tmp /var/tmp; do
        run find "$tmpdir" -xdev -mindepth 1 \( -type f -o -type l \) -delete || true
    done
}

clean_old_kernels() {
    log_step "5. 自动清理旧内核"
    local current_kernel=$(uname -r)
    local current_pkg="linux-image-${current_kernel}"
    local -a images=()
    mapfile -t images < <(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | sort -V)
    (( ${#images[@]} <= 1 )) && { log_info "无旧内核需清理"; return 0; }
    
    local latest_pkg="${images[-1]}"
    for pkg in "${images[@]}"; do
        if [[ "$pkg" != "$current_pkg" && "$pkg" != "$latest_pkg" ]]; then
            run apt-get -y purge "$pkg" || true
        fi
    done
    run apt-get -y autoremove --purge || true
}

# ------------------------------ 主流程 ------------------------------

main() {
    need_root
    setup_logging

    # 记录初始状态 (读取为数组)
    read -r start_total start_used start_free < <(get_disk_stats)

    log_warn "=== 开始极速清理 ==="
    
    clean_apt
    clean_docker_aggressive
    clean_snap
    clean_logs_and_tmp
    clean_old_kernels

    # 强制刷盘，确保系统更新磁盘统计信息
    log_info "正在同步文件系统状态..."
    sync && sleep 1

    # 记录最终状态
    read -r end_total end_used end_free < <(get_disk_stats)
    
    # 计算实际释放字节
    local freed=0
    if (( start_used > end_used )); then
        freed=$(( start_used - end_used ))
    fi

    log_step "清理摘要"
    echo "------------------------------------------------"
    echo "总硬盘容量:   $(fmt_bytes "$end_total")"
    echo "------------------------------------------------"
    echo "初始已用:     $(fmt_bytes "$start_used")"
    echo "最终已用:     $(fmt_bytes "$end_used")"
    echo "------------------------------------------------"
    echo "初始可用:     $(fmt_bytes "$start_free")"
    echo "最终可用:     $(fmt_bytes "$end_free")"
    echo "------------------------------------------------"
    echo -e "\033[32m本次实际释放: $(fmt_bytes "$freed")\033[0m"
    echo "------------------------------------------------"
    log_success "清理完成！"
}

main "$@"
