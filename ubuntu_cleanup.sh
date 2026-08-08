#!/usr/bin/env bash
# ==============================================================================
# Ubuntu VPS 清理脚本
# - APT / 日志 / 临时目录 / Docker(安全模式) / 旧内核 / 开发缓存清理
# - 支持 --dry-run 预演、--yes 自动确认、--no-docker 跳过 Docker
# - 默认安全：不删 Docker 卷、不清空全部日志、开发缓存需显式开启
# ==============================================================================

set -Eeuo pipefail

# ------------------------------ 输出/日志 ------------------------------
LOG_FILE="/var/log/ubuntu_cleanup.log"

_color() { local c="$1"; shift; printf "\033[%sm%s\033[0m" "$c" "$*"; }
log_info() { echo -e "$(_color 36 "[INFO]") $(date '+%F %T') $*"; }
log_warn() { echo -e "$(_color 33 "[WARN]") $(date '+%F %T') $*"; }
log_error() { echo -e "$(_color 31 "[ERR ]") $(date '+%F %T') $*"; }
log_success() { echo -e "$(_color 32 "[OK  ]") $(date '+%F %T') $*"; }
log_step() { echo -e "\n$(_color 35 '>>') $(_color 35 "$*")"; }

die() { log_error "$*"; exit 1; }

# ------------------------------ 全局配置 ------------------------------
DRY_RUN=0            # 1=dry-run(只打印不执行)
AUTO_CONFIRM=0       # 1=跳过所有确认
DO_DOCKER=1          # 1=执行 Docker 清理
DO_DEV_CACHE=0       # 1=清理开发缓存(默认关闭)
PRUNE_VOLUMES=0      # 1=Docker 清理时也删卷(默认不删)
DO_KERNEL_CLEAN=0    # 1=清理旧内核(默认关闭)
KEEP_LOG_DAYS=7      # journalctl 保留天数

# ------------------------------ 工具函数 ------------------------------
need_root() { if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then die "请使用 root 权限运行：sudo bash $0"; fi; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# 获取磁盘统计数据 (字节: 总容量 已用 可用)
get_disk_stats() {
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

# 执行命令: dry-run 时只打印; 否则真实执行
run() {
    log_info "执行: $*"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "    [dry-run] 跳过执行"
        return 0
    fi
    "$@"
}

# 全局一次确认(仅当非 AUTO_CONFIRM 且非 dry-run 时询问)
confirm_once() {
    [[ "$AUTO_CONFIRM" -eq 1 || "$DRY_RUN" -eq 1 ]] && return 0
    echo -n "继续执行以上清理？[y/N] "
    local ans
    read -r ans
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || die "已取消"
}

setup_logging() {
    if ! ( : >>"$LOG_FILE" ) 2>/dev/null; then LOG_FILE="./ubuntu_cleanup.log"; fi
    exec > >(tee -a "$LOG_FILE") 2>&1
    log_info "日志文件: $LOG_FILE"
}

on_err() { local exit_code=$?; log_error "脚本出错 (exit=$exit_code)。"; exit "$exit_code"; }
trap on_err ERR

usage() {
    cat <<'EOF'
用法: sudo ubuntu_cleanup.sh [选项]

选项:
  --dry-run          预演模式: 只打印将执行的命令, 不实际执行
  --yes              跳过所有确认(等同 AUTO_CONFIRM=true)
  --no-docker        跳过 Docker 清理
  --dev-cache        清理开发缓存(pip/npm/go/uv 等, 默认关闭)
  --prune-volumes    Docker 清理时同时删除未使用卷(默认保留)
  --kernel-clean     清理旧内核(默认关闭, 建议维护窗口执行)
  --keep-log-days N  journalctl 保留天数(默认 7)
  --log-file PATH    指定日志文件
  --help             显示帮助

示例:
  sudo ./ubuntu_cleanup.sh --dry-run           # 预演
  sudo ./ubuntu_cleanup.sh --yes               # 自动确认执行
  sudo ./ubuntu_cleanup.sh --dev-cache --yes   # 含开发缓存
EOF
}

# ------------------------------ 清理模块 ------------------------------

clean_apt() {
    log_step "1. APT 清理"
    have_cmd apt-get || { log_info "未检测到 apt-get，跳过"; return 0; }
    run dpkg --configure -a || true
    run apt-get -y update || true
    run apt-get -y autoremove --purge
    run apt-get -y autoclean || true
    run apt-get -y clean
    run find /var/lib/apt/lists/ -mindepth 1 -delete || true
}

clean_docker() {
    [[ "$DO_DOCKER" -eq 0 ]] && { log_info "Docker 清理已跳过(--no-docker)"; return 0; }
    log_step "2. Docker 清理(安全模式)"
    have_cmd docker || { log_info "未检测到 Docker，跳过"; return 0; }

    # 报告容器日志占用
    local log_size
    log_size=$(find /var/lib/docker/containers -type f -name "*-json.log" -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')
    if [[ "$log_size" -gt 0 ]]; then
        log_info "容器 json 日志占用: $(fmt_bytes "$log_size")"
    fi

    # 悬空镜像 + 构建缓存 + 未使用网络(不删卷/不删命名镜像)
    local prune_args="-f"
    if [[ "$PRUNE_VOLUMES" -eq 1 ]]; then
        log_warn "已开启 --prune-volumes, 将同时删除未使用卷!"
        prune_args="$prune_args --volumes"
    fi
    run docker system prune -a $prune_args || true

    # 截断容器日志(保留文件, 清空内容)
    run find /var/lib/docker/containers -type f -name "*-json.log" -exec truncate -s 0 {} \; || true
}

clean_snap() {
    log_step "3. Snap 清理"
    have_cmd snap || { log_info "未检测到 snap，跳过"; return 0; }
    run snap set system refresh.retain=2 || true
    snap list --all | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
        [[ -n "${snapname:-}" && -n "${revision:-}" ]] || continue
        run snap remove "$snapname" --revision="$revision" || true
    done
}

clean_logs_and_tmp() {
    log_step "4. 日志与临时目录清理"
    if have_cmd journalctl; then
        local usage
        usage=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[MG]' | head -1)
        log_info "journald 当前占用: ${usage:-未知}"
        run journalctl --rotate || true
        run journalctl --vacuum-time="${KEEP_LOG_DAYS}d" || true
    fi
    # 轮转日志: 截断而非删除(保留文件名, 避免占用进程异常)
    run find /var/log -type f \( -name "*.gz" -o -name "*.xz" -o -name "*.bz2" -o -regex ".*\.[0-9]+$" -o -name "*.old" \) -exec truncate -s 0 {} \; || true
    run find /var/log -type f \( -name "*.log" -o -name "syslog*" -o -name "messages*" \) -exec truncate -s 0 {} \; || true
    # 清理临时目录(文件+符号链接+空目录)
    for tmpdir in /tmp /var/tmp; do
        run find "$tmpdir" -xdev -mindepth 1 \( -type f -o -type l \) -delete || true
        run find "$tmpdir" -xdev -mindepth 1 -type d -empty -delete || true
    done
}

clean_old_kernels() {
    [[ "$DO_KERNEL_CLEAN" -eq 0 ]] && { log_info "旧内核清理已跳过(需 --kernel-clean)"; return 0; }
    log_step "5. 自动清理旧内核"
    local current_kernel
    current_kernel=$(uname -r)
    # 精确匹配当前内核对应的包名(兼容 HWE/generic/aws 等 flavor)
    local current_pkg
    current_pkg=$(dpkg-query -W -f='${Package}\n' "linux-image-*" 2>/dev/null | grep -E "^linux-image-${current_kernel//.+\//}$" | head -1 || true)
    [[ -z "$current_pkg" ]] && current_pkg="linux-image-${current_kernel}"

    local -a images=()
    mapfile -t images < <(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | sort -V)
    (( ${#images[@]} <= 1 )) && { log_info "无旧内核需清理"; return 0; }

    local latest_pkg="${images[-1]}"
    local removed=0
    for pkg in "${images[@]}"; do
        if [[ "$pkg" != "$current_pkg" && "$pkg" != "$latest_pkg" ]]; then
            log_warn "将移除旧内核: $pkg"
            run apt-get -y purge "$pkg" || true
            removed=1
        fi
    done
    (( removed )) && run apt-get -y autoremove --purge || true
}

clean_dev_cache() {
    [[ "$DO_DEV_CACHE" -eq 0 ]] && { log_info "开发缓存清理已跳过(需 --dev-cache)"; return 0; }
    log_step "6. 开发缓存清理"

    # 安全的目录大小统计: 只统计存在的路径, 取第一个数字
    _dir_size() {
        local paths=() p
        shopt -s nullglob
        for p in "$@"; do
            [[ -e "$p" ]] && paths+=("$p")
        done
        shopt -u nullglob
        [[ ${#paths[@]} -eq 0 ]] && { echo 0; return; }
        du -sb "${paths[@]}" 2>/dev/null | awk '{s+=$1} END {print s+0}' || echo 0
    }

    # pip
    if have_cmd pip; then
        local psize
        psize=$(_dir_size /root/.cache/pip /home/*/.cache/pip)
        [[ "$psize" -gt 0 ]] && { log_info "pip 缓存: $(fmt_bytes "$psize")"; run pip cache purge; } || true
    fi

    # npm
    if have_cmd npm; then
        local nsize
        nsize=$(_dir_size /root/.npm /home/*/.npm)
        [[ "$nsize" -gt 0 ]] && { log_info "npm 缓存: $(fmt_bytes "$nsize")"; run npm cache clean --force; } || true
    fi

    # Go 构建缓存
    if have_cmd go; then
        local gsize
        gsize=$(_dir_size /root/.cache/go-build /home/*/.cache/go-build)
        [[ "$gsize" -gt 0 ]] && { log_info "Go 构建缓存: $(fmt_bytes "$gsize")"; run go clean -cache; } || true
    fi

    # uv 缓存
    if have_cmd uv; then
        local usize
        usize=$(_dir_size /root/.cache/uv /home/*/.cache/uv)
        [[ "$usize" -gt 0 ]] && { log_info "uv 缓存: $(fmt_bytes "$usize")"; run uv cache clean; } || true
    fi
}

# 大缓存单独提醒(不自动清理, 只报告)
report_big_caches() {
    log_step "7. 大缓存报告(不自动清理, 需手动处理)"
    local total=0 t size
    local targets=(
        "/root/.cache/ms-playwright"
        "/home/*/.cache/ms-playwright"
        "/root/.cache/camoufox"
        "/home/*/.cache/camoufox"
    )
    for t in "${targets[@]}"; do
        # t 可能含通配符, 展开后统计存在的
        local matched=0
        shopt -s nullglob
        for m in $t; do
            [[ -e "$m" ]] && matched=1
        done
        shopt -u nullglob
        [[ "$matched" -eq 0 ]] && continue
        size=$(du -sb $t 2>/dev/null | awk '{s+=$1} END {print s+0}' || echo 0)
        if [[ "$size" -gt 0 ]]; then
            log_info "$t: $(fmt_bytes "$size") (浏览器引擎缓存, 删除后需重新下载)"
            total=$(( total + size ))
        fi
    done
    if [[ "$total" -gt 0 ]]; then
        log_warn "以上浏览器缓存共 $(fmt_bytes "$total"), 如需释放请手动删除(不会自动清理)"
    fi
}

# ------------------------------ 主流程 ------------------------------

main() {
    need_root
    setup_logging

    # 记录初始状态
    local start_total start_used start_free
    read -r start_total start_used start_free < <(get_disk_stats)
    # start_total 已在摘要中通过 end_total 展示, 这里忽略该变量本身(容量不变)
    : "${start_total}"

    log_warn "=== 开始清理 (dry-run=${DRY_RUN} 确认=${AUTO_CONFIRM} Docker=${DO_DOCKER}) ==="

    # 先展示计划(非 dry-run 时也先列出将做什么, 给一次全局确认)
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_warn "预演模式: 以下为将执行的命令, 不会实际改动系统"
    else
        echo ""
        echo "以下操作将被执行:"
        echo "  1. APT 清理 (update/autoremove/autoclean/clean)"
        [[ "$DO_DOCKER" -eq 1 ]] && echo "  2. Docker 清理 (悬空镜像+构建缓存+日志截断, 不删卷)"
        echo "  3. Snap 旧版本清理 (如检测到 snap)"
        echo "  4. 日志截断 + 临时目录清理 (journal 保留 ${KEEP_LOG_DAYS} 天)"
        [[ "$DO_KERNEL_CLEAN" -eq 1 ]] && echo "  5. 旧内核清理"
        [[ "$DO_DEV_CACHE" -eq 1 ]] && echo "  6. 开发缓存清理 (pip/npm/go/uv)"
        echo "  7. 大缓存报告 (仅报告, 不自动清理)"
        echo ""
        confirm_once
    fi

    clean_apt
    clean_docker
    clean_snap
    clean_logs_and_tmp
    clean_old_kernels
    clean_dev_cache
    report_big_caches

    # 强制刷盘
    log_info "正在同步文件系统状态..."
    run sync
    sleep 1

    # 记录最终状态
    local end_total end_used end_free
    read -r end_total end_used end_free < <(get_disk_stats)

    local freed=0
    if (( start_used > end_used )); then
        freed=$(( start_used - end_used ))
    fi

    log_step "清理摘要"
    echo "------------------------------------------------"
    echo "总硬盘容量:   $(fmt_bytes "$end_total")"
    echo "初始已用:     $(fmt_bytes "$start_used")"
    echo "最终已用:     $(fmt_bytes "$end_used")"
    echo "初始可用:     $(fmt_bytes "$start_free")"
    echo "最终可用:     $(fmt_bytes "$end_free")"
    echo "------------------------------------------------"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo -e "\033[33m本次为预演模式, 未实际改动系统\033[0m"
    else
        echo -e "\033[32m本次实际释放: $(fmt_bytes "$freed")\033[0m"
    fi
    echo "------------------------------------------------"
    log_success "清理完成！"
}

# ------------------------------ 参数解析 ------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --yes) AUTO_CONFIRM=1; shift ;;
        --no-docker) DO_DOCKER=0; shift ;;
        --dev-cache) DO_DEV_CACHE=1; shift ;;
        --prune-volumes) PRUNE_VOLUMES=1; shift ;;
        --kernel-clean) DO_KERNEL_CLEAN=1; shift ;;
        --keep-log-days) KEEP_LOG_DAYS="$2"; shift 2 ;;
        --log-file) LOG_FILE="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "未知参数: $1"; usage; exit 1 ;;
    esac
done

main "$@"
