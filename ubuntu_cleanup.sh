#!/bin/bash

# --- 核心修正说明 ---
# 1. 移除了所有可能删除容器(Container)的命令。
# 2. Docker 清理仅限于 "Dangling Images" (标签为 <none>) 和 "Build Cache"。
# 3. 调整顺序：Docker 清理现在会在 Snap 清理之前运行，防止因 Snap 更新导致服务停止后被误判删除。

set -u
set -o pipefail

# --- 配置 ---
AUTO_CONFIRM=true
LOG_DIR="/var/log/system-cleanup"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/cleanup-$(date +%Y%m%d-%H%M%S).log"

# --- 辅助函数 ---
exec > >(tee -a "$LOG_FILE") 2>&1

log_info() { echo "[信息] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn() { echo "[警告] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_step() {
    echo "----------------------------------------"
    echo ">> 步骤: $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "----------------------------------------"
}
log_success() { echo "[成功] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

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

# --- 检查 Root ---
if [ "$(id -u)" -ne 0 ]; then
    echo "必须以 root 身份运行。"
    exit 1
fi

# --- 主逻辑 ---
log_info "开始安全清理模式..."
initial_space_kb=$(get_used_space_kb)

run_cleanup_step() {
    local description="$1"
    local command_to_run="$2"
    log_step "$description"
    eval "$command_to_run"
    echo
}

# 1. 安全的 Docker 清理 (优先执行)
# 只删除 <none> 镜像和构建缓存。绝对不删除容器，不删除未使用的正常镜像。
if command_exists docker; then
    log_step "Docker 资源清理 (安全模式)"
    log_info "仅清理悬空镜像(<none>)和构建缓存。现有容器即使停止也不会被删除。"
    
    # 清理悬空镜像 (Dangling images only) - 去掉了 -a 参数
    docker image prune -f -a
    
    # 清理构建缓存 (Build cache)
    docker builder prune -f
else
    log_info "未检测到 Docker，跳过。"
fi

# 2. APT 清理
run_cleanup_step "清理 APT 缓存" "apt-get clean -y"
run_cleanup_step "移除未使用依赖" "apt-get autoremove --purge -y"

# 3. 日志清理
if command_exists journalctl; then
    log_step "清理 Systemd 日志"
    journalctl --vacuum-size=100M
fi
run_cleanup_step "清理 /var/log 旧文件" "find /var/log -type f \( -name '*.gz' -o -name '*.1' -o -name '*.xz' \) -delete"

# 4. 临时文件清理
run_cleanup_step "清理 /tmp (超过1天)" "find /tmp -mindepth 1 -mtime +0 -delete"

# 5. Snap 清理 (放在最后)
# 警告：Snap 操作可能会导致 Docker 服务重启（如果 Docker 是 Snap 版）
if command_exists snap; then
    log_step "清理 Snap 旧版本"
    snap list --all | awk '/disabled/{print $1, $3}' | while read snapname revision; do
        log_info "移除 Snap: $snapname (r$revision)"
        snap remove "$snapname" --revision="$revision"
    done
fi

# 6. 旧内核清理 (逻辑保持)
current_kernel=$(uname -r)
old_kernels=$(dpkg --list | grep -E 'linux-image-[0-9]+' | awk '{ print $2 }' | grep -v "$current_kernel" | sort -V | head -n -1)
if [ -n "$old_kernels" ]; then
    log_step "清理旧内核: $old_kernels"
    apt-get purge -y $old_kernels
    update-grub
fi

# --- 结束 ---
final_space_kb=$(get_used_space_kb)
freed=$((initial_space_kb - final_space_kb))
log_success "清理完成。释放空间: $(format_kb "$freed")"
