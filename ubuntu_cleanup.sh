#!/bin/bash

# 如果命令以非零状态退出，则立即退出。
# set -e # 在执行许多独立步骤的脚本中，请谨慎使用 set -e。
# 在替换时将未设置的变量视为错误。
set -u
# Pipestatus: 管道的退出状态是最后一个以非零状态退出的命令的状态。
set -o pipefail

# --- 配置 ---
# 对于此修改版本，始终为 true 以使所有步骤默认为执行。
AUTO_CONFIRM=true

# 脚本日志文件
LOG_DIR="/var/log/system-cleanup"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/cleanup-$(date +%Y%m%d-%H%M%S).log"

# Systemd Journald 清理设置
JOURNALD_VACUUM_SIZE="200M" # 最大大小 (例如 "100M", "500M", "1G")。优先于时间。
JOURNALD_VACUUM_TIME="1month" # 最长保留时间 (例如 "2weeks", "1month", "3days")。如果大小为空则使用此设置。

# 标记是否已删除内核，以建议重新启动
kernels_removed_flag=false

# --- 辅助函数 ---
# (将所有辅助函数和主脚本的 stdout/stderr 重定向到日志文件和控制台)
exec > >(tee -a "$LOG_FILE") 2>&1

log_info() {
    echo "[信息] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo "[警告] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[错误] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_step() {
    echo "----------------------------------------"
    echo ">> 步骤: $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "----------------------------------------"
}

log_success() {
    echo "[成功] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

confirm_action() {
    if [ "$AUTO_CONFIRM" = true ]; then
        # log_warn "AUTO_CONFIRM=true, 自动继续操作: '$1'." # 已由 run_cleanup_step 的描述记录
        return 0 # 是
    fi
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
    if ! [[ "$kb" =~ ^-?[0-9]+$ ]]; then # 允许负数用于差异计算
        echo "${kb} (无效输入)"
        return
    fi

    local abs_kb=${kb#-} # 用于 bc 除法的绝对值
    local sign=""
    if [[ "$kb" =~ ^- ]]; then
        sign="-"
    fi

    local freed_mb=$(echo "scale=2; $abs_kb / 1024" | bc 2>/dev/null)
    local freed_gb=$(echo "scale=2; $abs_kb / 1024 / 1024" | bc 2>/dev/null)

    if ! [[ "$freed_mb" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! [[ "$freed_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "${sign}${abs_kb} KB (bc 计算错误或非数字输出)"
        return
    fi

    if (( $(echo "$abs_kb >= 1048576" | bc -l) )); then # 1024 * 1024
        printf "%s%.2f GB
" "$sign" "$freed_gb"
    elif (( $(echo "$abs_kb >= 1024" | bc -l) )); then
        printf "%s%.2f MB
" "$sign" "$freed_mb"
    else
        printf "%s%d KB
" "$sign" "$kb" # 对于小值，显示原始 KB
    fi
}

# --- 健康检查 ---
log_info "脚本日志文件: $LOG_FILE"
log_info "正在运行初步检查..."

if [ "$(id -u)" -ne 0 ]; then
    log_error "此脚本必须以 root 用户身份运行 (或使用 sudo)。"
    exit 1
fi

essential_commands=("apt-get" "dpkg-query" "uname" "grep" "awk" "sed" "sudo" "bc" "df" "find" "tee" "date" "fmt")
for cmd in "${essential_commands[@]}"; do
    if ! command_exists "$cmd"; then
        log_error "所需命令 '$cmd' 未安装。请安装它。"
        exit 1
    fi
done

# --- 主脚本 ---
total_freed_kb=0

run_cleanup_step() {
    local description="$1"
    local command_to_run="$2"

    log_step "$description"

    if ! confirm_action "$description"; then
        return
    fi

    local space_before_kb
    space_before_kb=$(get_used_space_kb)
    log_info "正在运行: $command_to_run"

    local exit_status=0
    if ! sudo bash -c "$command_to_run"; then
        exit_status=$?
        log_warn "命令执行出错 (退出码 $exit_status)。空间计算可能不准确。"
    else
        log_info "命令成功执行。"
    fi

    local space_after_kb
    space_after_kb=$(get_used_space_kb)
    local freed_step_kb=$((space_before_kb - space_after_kb))

    if [ "$freed_step_kb" -gt 0 ]; then
        local freed_human
        freed_human=$(format_kb "$freed_step_kb")
        log_success "大约释放了: $freed_human"
        total_freed_kb=$((total_freed_kb + freed_step_kb))
    elif [ "$freed_step_kb" -eq 0 ] && [ "$exit_status" -eq 0 ]; then
        log_info "此步骤未释放明显空间。"
    elif [ "$exit_status" -eq 0 ]; then # 已修正: 添加 'then'
        # 这种情况意味着命令成功，但 freed_step_kb 是负数 (空间使用增加了)
        local changed_human
        changed_human=$(format_kb "$freed_step_kb") # 将显示为负数
        log_warn "磁盘使用量变化了大约 $changed_human。这可能发生 (例如，在清理过程中生成了日志，或者空间被释放后又迅速被重新分配)。"
    fi
    echo
}

log_info "开始 Ubuntu 系统清理和优化..."
initial_space_kb=$(get_used_space_kb)
log_info "初始已用空间: $(format_kb "$initial_space_kb")"
echo

# 1. 更新软件包列表 (在升级/其他 apt 操作前的好习惯)
log_step "更新软件包列表"
if confirm_action "更新软件包列表 (apt-get update)"; then
    log_info "正在运行 apt-get update -y..."
    if sudo apt-get update -y; then
        log_success "软件包列表已更新。"
    else
        log_warn "apt-get update 执行出错 (退出码 $?)。"
    fi
    echo
fi

# 2. 升级已安装的软件包 (提高效率和安全性)
log_step "升级所有已安装的软件包"
if confirm_action "升级所有已安装的软件包 (apt-get full-upgrade)"; then
    log_info "正在运行 apt-get full-upgrade -y..."
    if sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"; then
        log_success "系统软件包已升级。"
    else
        log_warn "apt-get full-upgrade 执行出错 (退出码 $?)。"
    fi
    echo
fi

# 3. 清理 APT 缓存
run_cleanup_step "清理 APT 缓存 (apt-get clean)" "apt-get clean -y"

# 4. 移除未使用的依赖项
run_cleanup_step "移除未使用的依赖项 (apt-get autoremove)" "apt-get autoremove --purge -y"

# 5. 清理旧内核
log_step "清理旧内核"
current_kernel=$(uname -r)
log_info "当前内核: $current_kernel"

old_kernels=$(dpkg-query -W -f='${Package}	${Status}
' 'linux-image-[0-9]*' 'linux-headers-[0-9]*' 'linux-modules-[0-9]*' 'linux-modules-extra-[0-9]*' 2>/dev/null | \
    grep '\sinstall ok installed$' | \
    awk '{print $1}' | \
    grep -Pv "^linux-(image|headers|modules|modules-extra)-(${current_kernel%-[a-z0-9]*-generic}|${current_kernel%-[a-z0-9]*-lowlatency}|${current_kernel%-[a-z0-9]*-azure}|${current_kernel%-[a-z0-9]*-aws}|${current_kernel%-[a-z0-9]*-gcp}|${current_kernel%-[a-z0-9]*-oracle}|generic|lowlatency|azure|aws|gcp|oracle})$" | \
    grep -Pv "^linux-(image|headers|modules|modules-extra)-$(uname -r)$" | \
    tr '
' ' ')

if [ -z "$old_kernels" ]; then
    log_info "未找到要移除的旧内核。"
else
    log_info "发现要移除的旧内核包:"
    echo "$old_kernels" | fmt -w 80
    if confirm_action "清除旧内核包"; then
        space_before_kb=$(get_used_space_kb)
        log_info "正在为以下内核运行清除: $old_kernels"
        purge_exit_status=0
        if ! sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y $old_kernels; then
            purge_exit_status=$?
            log_warn "内核清除命令执行出错 (退出码 $purge_exit_status)。"
        else
            log_success "旧内核已成功清除。"
            kernels_removed_flag=true
            log_info "正在更新 GRUB 配置..."
            if sudo update-grub; then
                log_success "GRUB 已更新。"
            else
                log_warn "update-grub 失败 (退出码 $?)。可能需要手动检查。"
            fi
        fi

        log_info "内核移除后再次运行 autoremove..."
        if sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y; then
            log_info "内核移除后的 autoremove 已完成。"
        else
            log_warn "内核移除后的 autoremove 失败 (退出码 $?)。"
        fi

        space_after_kb=$(get_used_space_kb)
        freed_step_kb=$((space_before_kb - space_after_kb))

        if [ "$freed_step_kb" -gt 0 ]; then
            log_success "大约释放了 (内核和后续的 autoremove): $(format_kb $freed_step_kb)"
            total_freed_kb=$((total_freed_kb + freed_step_kb))
        elif [ "$purge_exit_status" -eq 0 ]; then # 仅当清除本身没问题时才记录“未释放空间”
             log_info "内核移除未释放明显空间，或者空间被回收并迅速重用。"
        fi
    fi
fi
echo

# 6. 清理 Systemd Journal 日志
log_step "清理 Systemd Journal 日志"
if command_exists journalctl; then
    journal_cmd_desc=""
    journal_cmd_run=""
    if [ -n "$JOURNALD_VACUUM_SIZE" ]; then # 已修正: 'S' to 'then'
        journal_cmd_desc="清理 systemd journal 日志到指定大小: $JOURNALD_VACUUM_SIZE"
        journal_cmd_run="journalctl --vacuum-size=$JOURNALD_VACUUM_SIZE"
    elif [ -n "$JOURNALD_VACUUM_TIME" ]; then
        journal_cmd_desc="清理早于以下时间的 systemd journal 日志: $JOURNALD_VACUUM_TIME"
        journal_cmd_run="journalctl --vacuum-time=$JOURNALD_VACUUM_TIME"
    else
        log_info "未设置 journald 清理的大小或时间限制。跳过此特定的 journal 清理方法。"
    fi

    if [ -n "$journal_cmd_run" ]; then
       run_cleanup_step "$journal_cmd_desc" "$journal_cmd_run"
    fi
else
    log_warn "未找到 journalctl 命令。跳过 Systemd Journal 清理。"
fi
echo

# 7. 清理 /var/log 中旧的轮替日志
run_cleanup_step "清理 /var/log 中的旧轮替日志 (以 .[0-9] 或 .gz, .xz, .bz2 结尾的文件)" \
                 "find /var/log -type f -regextype posix-extended -regex '.*/.*\.(log\.[0-9]+(\.gz)?|[0-9]+|gz|xz|bz2)$' -delete"


# 8. 清理临时文件 (更安全的方法)
log_step "清理临时文件 (/tmp, /var/tmp)"
log_warn "正在清理 /tmp 和 /var/tmp。这通常是安全的，但请确保没有正在运行的进程依赖于这些临时文件。"

run_cleanup_step "清理 /tmp (超过1天的文件)" \
                 "find /tmp -mindepth 1 -mtime +0 -delete"
run_cleanup_step "清理 /var/tmp (超过7天的文件)" \
                 "find /var/tmp -mindepth 1 -mtime +6 -delete"
echo

# 9. 清理 Snap 包的旧版本 (如果安装了 snapd)
log_step "清理旧的 Snap 包版本"
if command_exists snap; then
    if confirm_action "移除旧的/禁用的 snap 版本"; then
        log_info "正在查找要移除的旧 snap 版本..."
        space_before_kb=$(get_used_space_kb)
        
        snap_list_output=$(LANG=C snap list --all) # 捕获一次列表
        echo "$snap_list_output" | awk '/disabled|broken/{print $1, $3}' |
        while read -r snapname revision; do
            log_info "尝试移除 snap: $snapname 版本 $revision"
            if sudo snap remove "$snapname" --revision="$revision"; then
                log_info "已移除 snap: $snapname 版本 $revision"
            else
                log_warn "移除 snap 失败: $snapname 版本 $revision (退出码 $?)。它可能已经被移除或被其他 snap 需要。"
            fi
        done

        space_after_kb=$(get_used_space_kb)
        freed_step_kb=$((space_before_kb - space_after_kb))
        if [ "$freed_step_kb" -gt 0 ]; then
            log_success "从旧 snap 版本中大约释放了: $(format_kb $freed_step_kb)"
            total_freed_kb=$((total_freed_kb + freed_step_kb))
        else
            log_info "从 snap 版本中未释放明显空间，或未找到/移除旧版本。"
        fi
    fi
else
    log_info "未找到 Snap 命令。跳过 Snap 清理。"
fi
echo

# 10. 清理 Docker 资源 (可选)
log_step "清理 Docker 资源 (可选)"
if command_exists docker; then
    log_warn "Docker prune 将移除所有未使用的容器、网络、镜像 (悬空和未使用的) 和构建缓存。"
    if confirm_action "运行 'docker system prune -af'"; then
        run_cleanup_step "清理 Docker 系统 (容器、网络、镜像、缓存)" "docker system prune -af"
    fi
else
    log_info "未找到 Docker 命令。跳过 Docker 清理。"
fi
echo

# --- 最终摘要 ---
log_step "清理摘要"
final_space_kb=$(get_used_space_kb)
total_freed_check_kb=$((initial_space_kb - final_space_kb))

log_success "系统清理和优化过程已完成！"
log_info "初始已用空间: $(format_kb "$initial_space_kb")"
log_info "最终已用空间:   $(format_kb "$final_space_kb")"

if [ "$total_freed_kb" -lt 0 ]; then 
    total_freed_kb=0
fi

if [ "$total_freed_check_kb" -lt 0 ]; then 
    log_warn "磁盘总使用量似乎增加了 $(format_kb $(( -total_freed_check_kb )))。"
    log_warn "脚本释放的总空间 (各积极步骤总和): $(format_kb $total_freed_kb)"
else
    log_success "此脚本释放的总空间 (各步骤总和): $(format_kb $total_freed_kb)"
    log_info "(基于初始/最终状态的验证: $(format_kb $total_freed_check_kb))"
    if [ "$total_freed_kb" -ne "$total_freed_check_kb" ] && [ "$total_freed_check_kb" -ge 0 ]; then
        log_warn "注意：由于并发的磁盘活动或计算上的细微差别，各步骤总和与初始/最终状态差异可能不同。"
    fi
fi


if [ "$kernels_removed_flag" = true ]; then
   log_warn "旧内核已被移除。强烈建议重新启动系统以激活最新的内核并完成清理。"
fi

log_info "清理日志已保存至: $LOG_FILE"
echo "----------------------------------------"

exit 0
