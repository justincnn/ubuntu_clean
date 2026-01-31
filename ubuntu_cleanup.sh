#!/bin/bash

# ==============================================================================
# 🚀 Ubuntu VPS 深度清理与性能优化脚本 (Pro版)
# ==============================================================================
# 功能：
# 1. 磁盘清理：APT, Docker(安全模式), Snap, Systemd Logs, User Caches
# 2. 性能优化：优化内存交换(Swap)策略，提升系统响应速度
# 3. 安全机制：严格保护 Docker 容器，防止因 restart:no 导致的误删
# ==============================================================================

set -u
set -o pipefail

# --- 配置区域 ---
AUTO_CONFIRM=true
LOG_FILE="/var/log/vps_cleanup_pro.log"

# Systemd 日志保留限制 (激进模式)
JOURNAL_SIZE="50M"

# --- 辅助函数 ---
# 重定向输出到屏幕和日志文件
exec > >(tee -a "$LOG_FILE") 2>&1

log_info() { echo -e "\033[36m[INFO]\033[0m $(date '+%H:%M:%S') $1"; }
log_success() { echo -e "\033[32m[OK]\033[0m   $(date '+%H:%M:%S') $1"; }
log_warn() { echo -e "\033[33m[WARN]\033[0m $(date '+%H:%M:%S') $1"; }
log_step() { echo -e "\n\033[1;35m>> $1 \033[0m"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ 错误：请使用 root 权限运行 (sudo bash ...)"
        exit 1
    fi
}

get_disk_usage() {
    df / | awk 'NR==2 {print $3}'
}

format_size() {
    numfmt --to=iec --suffix=B --padding=7 $1
}

# --- 脚本开始 ---
check_root
log_info "开始执行深度清理与优化..."
START_USAGE=$(get_disk_usage)

# ==============================================================================
# 1. 系统包管理器深度清理 (APT)
# ==============================================================================
log_step "APT 深度清理"

# 修复潜在的依赖关系
dpkg --configure -a

# 清理过期的安装包缓存
apt-get clean -y

# 移除不再需要的依赖包 (孤儿包)
log_info "正在移除未使用的依赖包..."
apt-get autoremove --purge -y

# (可选) 如果安装了 deborphan，清理孤儿库
if command -v deborphan &> /dev/null; then
    log_info "使用 deborphan 清理孤儿库..."
    deborphan | xargs -r apt-get -y remove --purge
fi

# ==============================================================================
# 2. Docker 资源清理 (严格安全模式)
# ==============================================================================
log_step "Docker 资源清理 (安全模式)"

if command -v docker &> /dev/null; then
    log_info "检测到 Docker。正在执行安全清理..."
    log_warn "策略：保留所有容器(Container)和有标签的镜像。仅清理构建缓存和无名镜像。"

    # 1. 清理悬空镜像 (Dangling images): 标签为 <none> 的废弃镜像
    # 这不会删除被停止容器使用的镜像
    docker image prune -f

    # 2. 清理构建缓存 (Build Cache): 这是占用空间的隐形杀手
    # 如果你频繁构建镜像，这能释放 GB 级空间
    docker builder prune -f

    # 3. 清理未使用的网络 (Network)
    docker network prune -f
    
    log_success "Docker 清理完成 (未触碰容器)"
else
    log_info "未检测到 Docker，跳过。"
fi

# ==============================================================================
# 3. Snap 激进优化 (如果存在)
# ==============================================================================
if command -v snap &> /dev/null; then
    log_step "Snap 优化与清理"
    
    # 设置 Snap 只保留 2 个版本 (默认是 3 个)
    log_info "设置 Snap 保留限制为 2 个版本..."
    snap set system refresh.retain=2

    # 移除已禁用的旧版本 Snap
    # 注意：这可能会短暂重启依赖 Snap 的服务
    snap list --all | awk '/disabled/{print $1, $3}' | while read snapname revision; do
        log_info "移除旧版本 Snap: $snapname (r$revision)"
        snap remove "$snapname" --revision="$revision"
    done
fi

# ==============================================================================
# 4. 日志与缓存深度清理
# ==============================================================================
log_step "日志与应用缓存清理"

# Systemd Journal 清理
if command -v journalctl &> /dev/null; then
    log_info "压缩 Systemd 日志至 $JOURNAL_SIZE..."
    journalctl --vacuum-size=$JOURNAL_SIZE --vacuum-time=7d
fi

# 截断巨型日志文件 (保留文件但清空内容，比 rm 更安全)
log_info "截断 /var/log 下超过 50MB 的旧日志文件..."
find /var/log -type f -name "*.log" -size +50M -exec truncate -s 0 {} \;

# 清理 /tmp 和 /var/tmp
log_info "清理临时目录..."
find /tmp -mindepth 1 -mtime +1 -delete
find /var/tmp -mindepth 1 -mtime +1 -delete

# 清理用户级缓存 (.cache) - 包含 root 和 /home/*
# 这通常包含 pip, npm, yarn, thumbnails 等缓存
log_info "清理用户缓存目录 (/root/.cache & /home/*/.cache)..."
rm -rf /root/.cache/*
for user_dir in /home/*; do
    if [ -d "$user_dir/.cache" ]; then
        # 仅删除缓存内容，保留目录结构
        rm -rf "$user_dir/.cache"/*
        log_info "已清理: $user_dir/.cache"
    fi
done

# ==============================================================================
# 5. 旧内核清理 (保留当前内核)
# ==============================================================================
log_step "旧内核清理"
current_kernel=$(uname -r)
# 提取所有内核包名，排除当前内核
kernel_packages=$(dpkg --list | grep -E 'linux-image-[0-9]+' | awk '{ print $2 }' | grep -v "$current_kernel" | sort -V | head -n -1)

if [ -n "$kernel_packages" ]; then
    log_info "发现旧内核，正在移除: $kernel_packages"
    apt-get purge -y $kernel_packages
    update-grub
    log_success "旧内核已移除"
else
    log_info "未发现可清理的旧内核。"
fi

# ==============================================================================
# 6. VPS 性能参数调优 (Sysctl)
# ==============================================================================
log_step "性能参数优化 (Sysctl)"

# 1. 优化 Swappiness (降低对 Swap 的依赖)
# 默认通常是 60，对于 VPS 来说太高了，会导致频繁读写硬盘。
# 降低到 10，让系统尽可能用物理内存，提升速度。
CURRENT_SWAP=$(cat /proc/sys/vm/swappiness)
if [ "$CURRENT_SWAP" -gt 10 ]; then
    log_info "优化 vm.swappiness (当前: $CURRENT_SWAP -> 目标: 10)"
    sysctl -w vm.swappiness=10
    echo "vm.swappiness=10" >> /etc/sysctl.conf
else
    log_info "vm.swappiness 已优化 ($CURRENT_SWAP)"
fi

# 2. 优化 VFS Cache Pressure
# 增加到 50 (默认100)，让系统倾向于保留 inode/dentry 缓存，让文件访问更快
# 注意：如果内存极小(<1GB)，保持 100 即可。
MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [ "$MEM_TOTAL" -gt 2000000 ]; then # 如果内存 > 2GB
    log_info "内存充足，优化文件系统缓存保留..."
    sysctl -w vm.vfs_cache_pressure=50
fi

# ==============================================================================
# 总结
# ==============================================================================
echo ""
log_step "清理摘要"
END_USAGE=$(get_disk_usage)
FREED_SPACE=$((START_USAGE - END_USAGE))

# 处理可能出现的负数 (如果清理过程中产生新日志)
if [ $FREED_SPACE -lt 0 ]; then FREED_SPACE=0; fi

echo "------------------------------------------------"
echo "初始已用: $(format_size $((START_USAGE * 1024)))"
echo "最终已用: $(format_size $((END_USAGE * 1024)))"
echo "本次释放: $(format_size $((FREED_SPACE * 1024)))"
echo "------------------------------------------------"
log_success "系统清理与优化完成！"
echo ""

exit 0
