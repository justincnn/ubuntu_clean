# Ubuntu System Cleanup Script

一个用于 **Ubuntu / Debian VPS** 的 Bash 清理脚本：

- 释放磁盘空间：APT、日志、临时目录、用户缓存、Snap（可选）、Docker（安全模式）、开发缓存（可选）等
- 默认安全：不删 Docker 卷、不清空全部日志、危险操作需显式开关
- 支持 `--dry-run` 预演、`--yes` 自动确认、清理前后磁盘对比报告

## ✨ 功能特性

- **默认安全策略**：
  - Docker 清理**不删除卷、不删除命名镜像**（仅清理悬空镜像、构建缓存、未使用网络）
  - journald 日志**保留最近 7 天**（`--vacuum-time=7d`），不全部清空
  - 轮转日志（`*.gz` / `*.log.N` 等）**截断而非删除**（保留文件名，避免影响占用进程）
  - 旧内核清理、开发缓存清理默认**关闭**，需显式 `--kernel-clean` / `--dev-cache` 开启
- **开发缓存清理**（可选，`--dev-cache`）：pip / npm / Go 构建缓存 / uv 缓存
- **大缓存报告**：Playwright / Camoufox 等浏览器引擎缓存**仅报告占用**，不自动清理（删除后需重新下载）
- **可重复执行**：所有操作幂等，可定期运行
- **清理报告**：展示总容量、初始/最终已用与可用、本次实际释放量

## ⚠️ 重要警告

- 请谨慎使用：它会永久删除文件或卸载软件包
- 强烈建议运行前备份重要数据
- 需要 root 权限：用 `sudo` 执行
- `--dev-cache` 会删除开发/构建缓存（pip/npm/go/uv），导致下次构建/安装变慢
- `--kernel-clean` 会移除旧内核包；通常安全，但建议维护窗口执行，完成后可重启
- `--prune-volumes` 会删除 Docker 未使用卷，**可能造成数据丢失**，仅在明确知晓时使用

## ⚙️ 系统要求

- Ubuntu 或 Debian 系统
- `bash`、`find`、`awk`、`sed`、`df` 等基础工具
- 可选：`docker`（Docker 清理）、`snap`（Snap 清理）
- 可选：`journalctl`（journald 清理）

## 🚀 使用方法

### 1) 下载并赋予执行权限

```bash
git clone https://github.com/justincnn/ubuntu_clean.git
cd ubuntu_clean
chmod +x ubuntu_cleanup.sh
```

### 2) 推荐：先 dry-run 预演（不改动系统）

```bash
sudo ./ubuntu_cleanup.sh --dry-run
```

### 3) 日常清理（默认安全配置）

```bash
sudo ./ubuntu_cleanup.sh --yes
```

> `--yes` 跳过确认；不加则会在执行前做一次全局确认。

### 4) 更完整的清理（含开发缓存）

```bash
sudo ./ubuntu_cleanup.sh --dev-cache --yes
```

## 🔧 参数说明

| 参数 | 说明 |
|---|---|
| `--dry-run` | 预演模式：只打印将执行的命令，不实际改动系统 |
| `--yes` | 跳过所有确认（等同 `AUTO_CONFIRM=true`）|
| `--no-docker` | 跳过 Docker 清理 |
| `--dev-cache` | 清理开发缓存（pip/npm/go/uv，默认关闭）|
| `--prune-volumes` | Docker 清理时同时删除未使用卷（**默认保留，有数据丢失风险**）|
| `--kernel-clean` | 清理旧内核（默认关闭，建议维护窗口执行）|
| `--keep-log-days N` | journald 日志保留天数（默认 7）|
| `--log-file PATH` | 指定日志文件（默认 `/var/log/ubuntu_cleanup.log`）|
| `--help` | 显示帮助 |

## 📋 清理内容明细

| 模块 | 清理内容 | 默认 |
|---|---|---|
| 1. APT | `dpkg --configure -a`、`apt-get autoremove/autoclean/clean`、清空 apt lists | ✅ 开启 |
| 2. Docker | 悬空镜像、构建缓存、未使用网络；容器 json 日志截断（**不删卷**）| ✅ 开启 |
| 3. Snap | 清理 disabled 旧版本（`refresh.retain=2`）| ✅ 检测到才执行 |
| 4. 日志/tmp | journald 保留 7 天、轮转日志截断、`/tmp` `/var/tmp` 文件+空目录清理 | ✅ 开启 |
| 5. 旧内核 | 移除旧内核包（保留当前 + 最新）| ❌ 需 `--kernel-clean` |
| 6. 开发缓存 | pip / npm / Go / uv 缓存 | ❌ 需 `--dev-cache` |
| 7. 大缓存报告 | Playwright / Camoufox 等浏览器缓存（仅报告）| ✅ 只报告不清理 |

## ⏱️ 定时运行（可选）

### 方案 A：cron（每周日凌晨 3 点，自动确认）

```bash
sudo crontab -e
```

加入：

```cron
0 3 * * 0 /path/to/ubuntu_clean/ubuntu_cleanup.sh --yes --log-file /var/log/ubuntu_cleanup.log
```

### 方案 B：systemd timer（推荐，日志更友好）

创建一个 `oneshot` service + timer，定期执行 `ubuntu_cleanup.sh --yes` 即可。

## 许可证

MIT
