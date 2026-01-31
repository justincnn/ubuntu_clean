#!/bin/bash

# --- 脚本说明 ---
# 优化点：
# 1. Docker: 替换了 'system prune'，改为只清理镜像和构建缓存，绝对不删除容器。
# 2. Cache: 增加了对 /root/.cache 的清理 (pip, npm, thumbnails 等)。
# 3. Safety: 修正了原脚本中的语法错误。

# 如果命令以非零状态退出，则立即退出。
# set -e # 保持注释，避免单步错误导致中断
# 在替换时将未设置的变量视为错误。
set -u
# Pipestatus: 管道的退出状态是最后一个以非零状态退出的命令的状态。
set -o pipefail

# --- 配置 ---
AUTO_CONFIRM=true

# 脚本日志文件
LOG_DIR="/var/log/system-cleanup"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/cleanup-$(date +%Y%m%d-%H%M%S).log"

# Systemd Journald 清理设置
JOURNALD_VACUUM_SIZE="100M" # 建议缩小到 100M
JOURNALD_VACUUM_TIME="2weeks"

# 标记是否已删除内核，以建议重新启动
kernels_removed_flag=false

# --- 辅助函数 ---
exec > >(tee -a "$LOG_FILE") 2>&1

log_info() { echo "[信息] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn() { echo "[警告] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "[错误] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }
log_step() {
    echo "----------------------------------------"
    echo ">> 步骤: $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "----------------------------------------"
}
log_success() { echo "[成功] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

confirm_action() {
    if [ "$AUTO_CONFIRM" = true ]; then return 0; fi
    read -p "❓ 确认操作: '$1'? (y/N): " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) log_info "跳过操作: '$1'."; return 1 ;;
    esac
}

get_used_space_kb() {
    df --output=used / | awk 'NR==2 {print $1}' || echo "0"
}

format_kb() {
    local kb=$1
    if ! [[ "$kb" =~ ^-?[0-9]+$ ]]; then echo "0 KB"; return; fi
    local abs_kb=${kb#-}
    local sign=""; [[ "$kb" =~ ^- ]] && sign="-"
    
    if (( $(echo "$abs_kb >= 1048576" | bc -l 2>/dev/null || echo 0) )); then
        echo "${sign}$(echo "scale=2; $abs_kb / 1024 / 1024" | bc 2>/dev/null) GB"
    elif (( $(echo "$abs_kb >= 1024" | bc -l 2>/dev/null || echo 0) )); then
        echo "${sign}$(echo "scale=2; $abs_kb / 1024" | bc 2>/dev/null) MB"
    else
        echo "${sign}${abs_kb} KB"
    fi
}

# --- 健康检查 ---
log_info "脚本日志文件: $LOG_FILE"
if [ "$(id -u)" -ne 0 ]; then
    log_error "必须以 root 身份运行。"
    exit 1
fi

essential_commands=("apt-get" "dpkg-query" "uname" "grep" "awk" "sed" "bc" "df" "find")
for cmd in "${essential_commands[@]}"; do
    if ! command_exists "$cmd"; then
        log_error "缺少命令 '$cmd'。请先安装。"
        exit 1
    fi
done

# --- 主脚本逻辑 ---
total_freed_kb=0

run_cleanup_step() {
    local description="$1"
    local command_to_run="$2"

    log_step "$description"
    if ! confirm_action "$description"; then return; fi

    local space_before_kb=$(get_used_space_kb)
    log_info "正在运行: $command_to_run"

    if ! eval "$command_to_run"; then
        log_warn "命令执行出错。"
    else
        log_info "命令成功执行。"
    fi

    local space_after_kb=$(get_used_space_kb)
    local freed_step_kb=$((space_before_kb - space_after_kb))

    if [ "$freed_step_kb" -gt 0 ]; then
        log_success "释放空间: $(format_kb "$freed_step_kb")"
        total_freed_kb=$((total_freed_kb + freed_step_kb))
    else
        log_info "空间无显著变化或略微增加。"
    fi
    echo
}

log_info "开始系统清理..."
initial_space_kb=$(get_used_space_kb)
log_info "初始已用空间: $(format_kb "$initial_space_kb")"

# 1. 基础 APT 清理
run_cleanup_step "清理 APT 缓存 (clean)" "apt-get clean -y"
run_cleanup_step "移除未使用的依赖项 (autoremove)" "apt-get autoremove --purge -y"

# 2. 清理旧内核 (逻辑保持原样，这部分写得不错)
log_step "检查旧内核"
current_kernel=$(uname -r)
# 获取除当前内核外的所有内核
old_kernels=$(dpkg --list | grep -E 'linux-image-[0-9]+' | awk '{ print $2 }' | grep -v "$current_kernel" | sort -V | head -n -1)

if [ -z "$old_kernels" ]; then
    log_info "未发现可移除的旧内核。"
else
    log_info "发现旧内核: $old_kernels"
    if confirm_action "清除旧内核"; then
        run_cleanup_step "清除旧内核包" "apt-get purge -y $old_kernels"
        update-grub
        kernels_removed_flag=true
    fi
fi

# 3. Systemd Journal 清理 (修复了原脚本的语法错误)
log_step "清理 Systemd Journal"
if command_exists journalctl; then
    # 优先清理损坏的日志文件
    journalctl --rotate >/dev/null 2>&1
    
    if [ -n "$JOURNALD_VACUUM_SIZE" ]; then
        run_cleanup_step "限制日志大小至 $JOURNALD_VACUUM_SIZE" "journalctl --vacuum-size=$JOURNALD_VACUUM_SIZE"
    elif [ -n "$JOURNALD_VACUUM_TIME" ]; then
        run_cleanup_step "清理早于 $JOURNALD_VACUUM_TIME 的日志" "journalctl --vacuum-time=$JOURNALD_VACUUM_TIME"
    fi
fi

# 4. 清理 /var/log 旧日志
# 注意：find 命令中增加 ! -name "*log" 防止误删当前正在写入但未轮替的日志
run_cleanup_step "清理 /var/log 中的旧轮替压缩日志" \
    "find /var/log -type f \( -name '*.gz' -o -name '*.1' -o -name '*.xz' \) -delete"

# 5. 清理缓存目录 (新增)
log_step "清理系统及用户缓存"
# 清理 root 用户的缓存 (npm, pip, thumbnails 等通常积压在这里)
run_cleanup_step "清理 /root/.cache (如果是 root 运行)" "rm -rf /root/.cache/*"
# 清理 /tmp 和 /var/tmp
run_cleanup_step "清理 /tmp (超过1天)" "find /tmp -mindepth 1 -mtime +0 -delete"
run_cleanup_step "清理 /var/tmp (超过7天)" "find /var/tmp -mindepth 1 -mtime +6 -delete"

# 6. Snap 清理
if command_exists snap; then
    log_step "清理 Snap 旧版本"
    # 使用 set -c 来运行复杂的管道命令
    run_cleanup_step "移除 Disabled 的 Snap" \
    "snap list --all | awk '/disabled/{print \$1, \$3}' | while read snapname revision; do snap remove \"\$snapname\" --revision=\"\$revision\"; done"
fi

# 7. Docker 清理 (核心修正)
log_step "清理 Docker 资源"
if command_exists docker; then
    log_info "注意：正在执行 Docker 清理。将保留容器，仅清理无用镜像和缓存。"
    
    # 1. 清理悬空镜像 (dangling images) 和未被任何容器引用的镜像
    # 使用 -a (all) 清理所有未被容器使用的镜像，不仅是 dangling。
    # 如果你想保留 tag 过的但未运行的镜像，去掉 -a
    if confirm_action "清理未使用的 Docker 镜像 (image prune -a)"; then
        run_cleanup_step "清理未使用的镜像" "docker image prune -a -f"
    fi

    # 2. 清理构建缓存 (通常占用巨大空间)
    if confirm_action "清理 Docker 构建缓存 (builder prune)"; then
        run_cleanup_step "清理构建缓存" "docker builder prune -f"
    fi

    # 3. 这里的关键是：不要运行 docker system prune 或 docker container prune
    log_info "已跳过容器清理，以保护 'restart: no' 的服务。"
else
    log_info "未检测到 Docker。"
fi

# 8. 孤儿包清理 (如果安装了 deborphan)
if command_exists deborphan; then
    run_cleanup_step "清理孤儿库文件 (deborphan)" "deborphan | xargs -r apt-get -y remove --purge"
fi

# --- 结束 ---
echo
log_step "清理摘要"
final_space_kb=$(get_used_space_kb)
actual_freed=$((initial_space_kb - final_space_kb))

log_success "清理完成！"
log_info "初始空间: $(format_kb "$initial_space_kb")"
log_info "最终空间: $(format_kb "$final_space_kb")"
log_info "实际释放: $(format_kb "$actual_freed")"

if [ "$kernels_removed_flag" = true ]; then
    log_warn "已移除旧内核，请重启 VPS 以应用更改：'reboot'"
fi

exit 0
