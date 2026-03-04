# Ubuntu System Cleanup Script

一个用于 **Ubuntu / Debian VPS** 的 Bash 脚本：

- 释放磁盘空间：APT、日志、临时目录、用户缓存、Snap（可选）、Docker（安全模式）等
- 优化系统参数：提供保守的 `sysctl` 调优（可选持久化）与 `fstrim`（可选）
- 支持定期重复执行：提供 `safe|standard|aggressive` 三档强度 + `--dry-run` 预演

## ✨ 功能特性

- **三档强度**：
  - `safe`（默认）：安全清理与保守优化，适合日常/定期运行
  - `standard`：更积极（默认包含旧内核清理、Snap disabled 旧版本清理等）
  - `aggressive`：会清理更多可再生缓存（如构建/包管理缓存），更适合“我知道我在做什么”的场景
- **可重复执行**：大多数操作幂等；`sysctl` 采用 drop-in 文件持久化（默认写入 `/etc/sysctl.d/99-ubuntu-cleanup.conf`）
- **Docker 安全策略**：默认**不删除容器**、**不删除卷**、**不删除命名镜像**；仅清理悬空镜像、构建缓存、未使用网络
- **日志与临时文件**：支持 `journalctl --vacuum-*`、截断超大 `.log` 文件（保留文件名更安全）、清理 `/tmp` 与 `/var/tmp`
- **交互确认 + 自动确认**：默认逐步确认；支持 `--yes` / `AUTO_CONFIRM=true`

## ⚠️ 重要警告

- 请谨慎使用：它会永久删除文件或卸载软件包。
- 强烈建议运行前备份重要数据。
- 需要 root 权限：用 `sudo` 执行。
- `--mode aggressive` 与 `--dev-cache-clean` 可能会删除开发/构建缓存，导致下次构建/安装变慢。
- `--kernel-clean` 会移除旧内核包；通常安全，但建议维护窗口执行，完成后可重启。

## ⚙️ 系统要求

- Ubuntu 或 Debian 系统
- `bash`、`find`、`awk`、`sed`、`df` 等基础工具
- `apt-get`/`dpkg`（用于 APT/内核相关清理）
- 可选：`docker`（Docker 清理）
- 可选：`snap`（Snap 清理）
- 可选：`journalctl`（journald 清理）
- 可选：`fstrim`（SSD/云盘 trim）

## 🚀 使用方法

### 1) 下载并赋予执行权限

```bash
git clone https://github.com/justincnn/ubuntu_clean.git
cd ubuntu_clean
chmod +x ubuntu_cleanup.sh
```

### 2) 推荐：先 dry-run 预演

```bash
sudo ./ubuntu_cleanup.sh --mode safe --dry-run
```

### 3) 日常定期清理（安全默认）

```bash
sudo ./ubuntu_cleanup.sh --mode safe
```

### 4) 标准清理（更积极）

```bash
sudo ./ubuntu_cleanup.sh --mode standard
```

### 5) 激进清理（谨慎）

```bash
sudo ./ubuntu_cleanup.sh --mode aggressive
```

## 🔧 常用参数

- `--yes`：跳过交互确认（等同 `AUTO_CONFIRM=true`）
- `--no-docker`：跳过 Docker 清理
- `--kernel-clean`：清理旧内核
- `--snap-clean`：清理 Snap disabled 旧版本（检测到 snap 才生效）
- `--dev-cache-clean`：清理常见开发缓存（pip/npm/gradle/maven 等）
- `--fstrim`：执行 `fstrim -av`
- `--log-file /path/to/log`：指定日志文件

查看完整帮助：

```bash
sudo ./ubuntu_cleanup.sh --help
```

## ⏱️ 定时运行（可选）

### 方案 A：cron（每周日凌晨 3 点，safe + 自动确认）

```bash
sudo crontab -e
```

加入：

```cron
0 3 * * 0 AUTO_CONFIRM=true /path/to/ubuntu_clean/ubuntu_cleanup.sh --mode safe --log-file /var/log/ubuntu_cleanup.log
```

### 方案 B：systemd timer（推荐，日志更友好）

可自行创建一个 `oneshot` service + timer，定期执行：

- `AUTO_CONFIRM=true`
- `--mode safe`
- `--log-file /var/log/ubuntu_cleanup.log`

## 许可证

MIT
