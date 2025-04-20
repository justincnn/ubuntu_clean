# Ubuntu System Cleanup Script
一个用于清理 Ubuntu 及基于 Debian 的系统的 Bash 脚本，旨在释放磁盘空间、移除不再需要的文件和配置，并可能提高系统运行效率。特别适用于 VPS 或需要定期维护的服务器/桌面环境。
## ✨ 功能特性
该脚本执行以下清理操作：
*   **更新软件包列表**: 在清理前运行 `apt update`。
*   **清理 APT 缓存**: 删除已下载的 `.deb` 包文件 (`apt clean`)。
*   **移除未使用依赖**: 卸载自动安装且不再被任何包需要的依赖项 (`apt autoremove --purge`)。
*   **清理旧内核**: 自动识别并移除除当前正在运行的内核之外的旧 `linux-image`, `linux-headers`, `linux-modules` 包，并在成功后更新 GRUB。
*   **清理 Systemd Journal 日志**: 根据配置的大小 (`JOURNALD_VACUUM_SIZE`) 或时间 (`JOURNALD_VACUUM_TIME`) 限制来清理 systemd 日志。
*   **清理旧的轮转日志**: 删除 `/var/log` 目录下常见的旧日志文件（如 `.gz`, `.xz`, `.bz2` 压缩包和 `.log.1`, `.log.2` 等编号文件）。
*   **清理临时文件**: (可选，带警告) 清空 `/tmp` 和 `/var/tmp` 目录。
*   **清理 Docker 资源**: (可选) 如果安装了 Docker，提供清理未使用容器、网络、镜像（**包括所有未使用的，不仅是悬空镜像**）和构建缓存的选项 (`docker system prune -af`)。
*   **用户交互**: 对可能移除重要数据或进行系统更改的操作提供确认提示。
*   **自动确认模式**: 支持通过环境变量 `AUTO_CONFIRM=true` 跳过确认，方便自动化执行。
*   **清晰的输出**: 提供结构化的状态、警告和错误信息。
*   **安全检查**: 运行前检查 root 权限和必要的命令（`apt`, `dpkg`, `uname` 等）。
## ⚠️ 重要警告
*   **请谨慎使用此脚本！** 它会永久删除文件和软件包。
*   **强烈建议在运行前备份您的重要数据！**
*   此脚本需要 **root 权限** (使用 `sudo`) 来执行大部分操作。
*   清理 `/tmp` 和 `/var/tmp` 目录可能会影响正在运行的应用程序，请确认没有进程依赖这些目录中的临时文件。
*   Docker 清理 (`docker system prune -af`) 会移除**所有**未被容器使用的镜像，而不仅仅是悬空镜像。请确保您不需要这些未使用的镜像。
*   虽然脚本设计为在 Ubuntu/Debian 系统上安全运行，但作者不对因使用此脚本造成的任何数据丢失或系统问题负责。
## ⚙️ 系统要求
*   基于 Ubuntu 或 Debian 的 Linux 发行版。
*   `sudo` 权限。
*   已安装标准的 Linux 核心工具 (`bash`, `grep`, `awk`, `sed`, `dpkg`, `uname`, `find` 等)。
*   `apt` 包管理器。
*   可选：`docker` (如果需要清理 Docker 资源)。
*   可选：`journalctl` (如果需要清理 systemd 日志)。
## 🚀 如何使用
1.  **下载脚本**:
    *   通过 Git 克隆仓库:
        ```bash
        git clone https://github.com/justincnn/ubuntu_clean.git
        cd ubuntu_clean
        ```
    *   或者直接下载 `ubuntu_cleanup.sh` 文件。
2.  **给予执行权限**:
    ```bash
    chmod +x ubuntu_cleanup.sh
    ```
3.  **运行脚本**:
    *   **交互模式 (推荐)**:
        ```bash
        sudo ./ubuntu_cleanup.sh
        ```
        脚本会提示您确认每个主要的清理步骤。输入 `y` 或 `yes` 继续，或按 Enter (或输入 `n`) 跳过。
    *   **自动确认模式 (用于自动化，请谨慎)**:
        ```bash
        export AUTO_CONFIRM=true
        sudo ./ubuntu_cleanup.sh
        # 或者
        sudo AUTO_CONFIRM=true ./ubuntu_cleanup.sh
        ```
        在此模式下，脚本将不会请求确认，直接执行所有配置的清理操作。
## 🔧 配置
您可以在脚本顶部修改以下变量来自定义行为：
*   `AUTO_CONFIRM`: 设置为 `true` 以启用自动确认模式（默认为 `false`）。也可以通过环境变量覆盖。
*   `JOURNALD_VACUUM_SIZE`: 设置 systemd journal 日志的大小限制（例如 `"100M"`, `"500M"`, `"1G"`）。如果设置了此项，则优先于时间限制。
*   `JOURNALD_VACUUM_TIME`: 如果 `JOURNALD_VACUUM_SIZE` 未设置或为空，则使用此时间限制（例如 `"2weeks"`, `"1month"`, `"3days"`）。
## 🤝 贡献
欢迎提出问题 (Issues) 和拉取请求 (Pull Requests)。如果您发现任何错误或有改进建议，请随时贡献！
##📄 许可证
本项目采用 [MIT 许可证](LICENSE)。
---
**提示**: 如果您进行了内核清理，建议在清理完成后重新启动系统以确保系统使用最新的内核并移除旧内核的运行时影响。
