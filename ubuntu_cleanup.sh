#!/usr/bin/env bash
# ==============================================================================
# Ubuntu VPS 极速彻底清理脚本 
# - 修正了在 Oracle VPS/Docker 环境下由于 overlay 挂载导致的统计不准问题
# - 自动清理 APT、Docker、Snap、日志、缓存及旧内核
# ==============================================================================

set -Eeuo pipefail

# ------------------------------ 输出/日志 ------------------------------
LOG_FILE="/var/log/ubuntu_cleanup_fixed.log"

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

# 核心修正：排除 overlay, tmpfs 等虚拟挂载点，避免重复计算 Docker 占用
bytes_used_total() {
    # 只统计物理磁盘分区，忽略 Docker 的叠加文件系统
    df -P -l -x overlay -x tmpfs -x devtmpfs -x devfs -x squashfs 2>/dev/null | awk 'NR>1 {sum += $3} END {print sum * 1024}'
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

    local start end freed
    # 记录初始空间
    start=$(bytes_used_total)

    log_warn "=== 开始极速清理 ==="
    
    clean_apt
    clean_docker_aggressive
    clean_snap
    clean_logs_and_tmp
    clean_old_kernels

    # 关键步骤：同步磁盘，确保 df 获取的是释放后的真实数据
    log_info "正在同步文件系统状态..."
    sync && sleep 1

    # 记录最终空间
    end=$(bytes_used_total)
    
    # 计算释放量
    if (( end > start )); then 
        freed=0
    else 
        freed=$(( start - end ))
    fi

    log_step "清理摘要"
    echo "------------------------------------------------"
    echo "初始已用: $(fmt_bytes "$start")"
    echo "最终已用: $(fmt_bytes "$end")"
    echo -e "\033[32m本次实际释放: $(fmt_bytes "$freed")\033[0m"
    echo "------------------------------------------------"
    log_success "清理完成！"
}

main "$@"
