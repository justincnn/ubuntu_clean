#!/usr/bin/env bash
set -euo pipefail

# vps_tune.sh
# Unified Ubuntu VPS tuning script (adaptive + conservative), designed for OCI (Oracle Cloud)
# and generic cloud VMs. Supports ARM and x86.
#
# Key goals: improve efficiency and stability without risky defaults.
# - Preflight: inspect system resources/capabilities first
# - Plan mode: show what would be changed
# - Apply mode: idempotently write config drop-ins and optionally disable/purge candidate services
#
# Modes:
#   MODE=apply (default)  Apply changes (requires root)
#   MODE=plan             Print preflight + decisions only (no changes; root not required)
#
# Toggle semantics: auto|0|1
#   auto: script decides using safe heuristics
#
# Core toggles:
#   APPLY_SYSCTL=auto|0|1
#   APPLY_JOURNALD=auto|0|1
#   APPLY_FSTRIM=auto|0|1
#   APPLY_SYSTEMD_LIMITS=auto|0|1
#   APPLY_PAM_LIMITS=auto|0|1
#   APPLY_DOCKER=auto|0|1
#   APPLY_DISABLE=auto|0|1              Disable conservative "commonly unused" services
#   APPLY_BBR=auto|0|1                  Enable BBR+fq if supported
#   APPLY_ZRAM=auto|0|1                 Enable zram-generator on small-memory nodes
#   APPLY_SERVICE_AUDIT=auto|0|1        Print running services and candidate statuses
#   APPLY_DISABLE_CANDIDATES=auto|0|1   Disable broader candidate services (explicitly recommended: 0)
#   APPLY_PURGE_CANDIDATE_PACKAGES=auto|0|1  Purge packages for candidates (explicitly recommended: 0)
#
# Risk toggles:
#   RESTART_DOCKER=0|1     Restart docker after daemon.json write (default 0)
#   REEXEC_SYSTEMD=0|1     systemctl daemon-reexec after system.conf change (default 0)
#   INSTALL_ZRAM=0|1       If zram-generator missing and zram enabled, try to install it (default 0)

MODE="${MODE:-apply}"

APPLY_SYSCTL="${APPLY_SYSCTL:-auto}"
APPLY_JOURNALD="${APPLY_JOURNALD:-auto}"
APPLY_FSTRIM="${APPLY_FSTRIM:-auto}"
APPLY_SYSTEMD_LIMITS="${APPLY_SYSTEMD_LIMITS:-auto}"
APPLY_PAM_LIMITS="${APPLY_PAM_LIMITS:-auto}"
APPLY_DOCKER="${APPLY_DOCKER:-auto}"
APPLY_DISABLE="${APPLY_DISABLE:-auto}"
APPLY_BBR="${APPLY_BBR:-auto}"
APPLY_ZRAM="${APPLY_ZRAM:-auto}"

APPLY_SERVICE_AUDIT="${APPLY_SERVICE_AUDIT:-auto}"
APPLY_DISABLE_CANDIDATES="${APPLY_DISABLE_CANDIDATES:-0}"
APPLY_PURGE_CANDIDATE_PACKAGES="${APPLY_PURGE_CANDIDATE_PACKAGES:-0}"

RESTART_DOCKER="${RESTART_DOCKER:-0}"
REEXEC_SYSTEMD="${REEXEC_SYSTEMD:-0}"
INSTALL_ZRAM="${INSTALL_ZRAM:-0}"

log() { echo "[vps-tune] $*"; }
warn() { echo "[vps-tune][WARN] $*" >&2; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

need_root_for_apply() {
  if [[ "$MODE" != "apply" ]]; then
    return 0
  fi
  if [[ "${EUID}" -ne 0 ]]; then
    warn "MODE=apply requires root: sudo -H MODE=apply bash $0"
    exit 1
  fi
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    cp -a "$f" "${f}.bak.${ts}"
    log "Backup: $f -> ${f}.bak.${ts}"
  fi
}

write_file_if_changed() {
  local f="$1"
  local content="$2"
  local tmp
  tmp="$(mktemp)"
  printf '%s' "$content" >"$tmp"
  if [[ -f "$f" ]] && cmp -s "$tmp" "$f"; then
    rm -f "$tmp"
    return 0
  fi
  backup_file "$f"
  install -m 0644 "$tmp" "$f"
  rm -f "$tmp"
}

to_bool() {
  # Usage: to_bool <auto|0|1> <default_0_or_1>
  local v="$1"; local d="$2"
  case "$v" in
    0|1) echo "$v" ;;
    auto) echo "$d" ;;
    *) warn "Invalid toggle '$v' (expected auto/0/1); using default=$d"; echo "$d" ;;
  esac
}

get_arch() { uname -m 2>/dev/null || echo unknown; }
get_cpu_count() { getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1; }
get_mem_mb() { awk '/MemTotal:/ {printf "%d\n", $2/1024}' /proc/meminfo 2>/dev/null || echo 0; }
get_swap_mb() { awk '/SwapTotal:/ {printf "%d\n", $2/1024}' /proc/meminfo 2>/dev/null || echo 0; }

get_root_fs_gb() {
  df -BG --output=size / 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$1); print $1}'
}

detect_oci() {
  local vendor="" product=""
  vendor="$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || true)"
  product="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || true)"
  if echo "$vendor $product" | grep -qiE 'oracle'; then
    echo 1
    return 0
  fi
  if have_cmd curl; then
    if curl -fsS -m 1 http://169.254.169.254/opc/v1/instance/ >/dev/null 2>&1; then
      echo 1
      return 0
    fi
  fi
  echo 0
}

detect_trim_support() {
  # Returns 1 if root block device advertises discard support.
  have_cmd findmnt || { echo 0; return 0; }
  have_cmd lsblk || { echo 0; return 0; }

  local src pk dev gran max
  src="$(findmnt -no SOURCE / 2>/dev/null || true)"
  [[ "$src" == /dev/* ]] || { echo 0; return 0; }

  pk="$(lsblk -no PKNAME "$src" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [[ -n "$pk" ]]; then
    dev="/dev/${pk}"
  else
    dev="$src"
  fi

  gran="$(lsblk -ndo DISC-GRAN "$dev" 2>/dev/null | awk 'NR==1 {print $1}')"
  max="$(lsblk -ndo DISC-MAX "$dev" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [[ -n "$gran" && -n "$max" && "$gran" != "0B" && "$max" != "0B" ]]; then
    echo 1
  else
    echo 0
  fi
}

detect_bbr_support() {
  if sysctl net.ipv4.tcp_available_congestion_control >/dev/null 2>&1; then
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | tr ' ' '\n' | grep -qx bbr; then
      echo 1
      return 0
    fi
  fi
  echo 0
}

detect_docker() { if have_cmd docker; then echo 1; else echo 0; fi; }

detect_zram_generator() {
  if [[ -x /usr/lib/systemd/system-generators/zram-generator ]] || [[ -x /usr/lib/systemd/system-generators/systemd-zram-generator ]]; then
    echo 1
  else
    echo 0
  fi
}

unit_exists() {
  local unit="$1"
  have_cmd systemctl || return 1
  systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "$unit"
}

unit_running() {
  local unit="$1"
  have_cmd systemctl || return 1
  systemctl is-active --quiet "$unit" 2>/dev/null
}

list_running_services() {
  have_cmd systemctl || return 0
  systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | awk '{print $1}' | sort -u
}

candidate_units() {
  # Conservative list that is typically useless on headless VPS.
  # Never include ssh/cloud-init/networking basics here.
  cat <<'EOF'
multipathd.service
open-iscsi.service
iscsid.service
cups.service
cups-browsed.service
avahi-daemon.service
bluetooth.service
ModemManager.service
rpcbind.service
nfs-server.service
EOF
}

decide_defaults() {
  ARCH="$(get_arch)"
  CPU_COUNT="$(get_cpu_count)"
  MEM_MB="$(get_mem_mb)"
  SWAP_MB="$(get_swap_mb)"
  ROOT_GB="$(get_root_fs_gb)"
  IS_OCI="$(detect_oci)"
  TRIM_OK="$(detect_trim_support)"
  BBR_OK="$(detect_bbr_support)"
  HAS_DOCKER="$(detect_docker)"
  HAS_ZRAM_GEN="$(detect_zram_generator)"

  # Journald caps: scale down for tiny root disks.
  if [[ -n "$ROOT_GB" ]] && (( ROOT_GB > 0 )) && (( ROOT_GB <= 20 )); then
    JOURNAL_SYSTEM_MAX_DEFAULT="100M"
    JOURNAL_RUNTIME_MAX_DEFAULT="50M"
    JOURNAL_RETENTION_DEFAULT="3day"
  else
    JOURNAL_SYSTEM_MAX_DEFAULT="200M"
    JOURNAL_RUNTIME_MAX_DEFAULT="100M"
    JOURNAL_RETENTION_DEFAULT="7day"
  fi

  LIMIT_NOFILE_DEFAULT="65535"
  if (( CPU_COUNT <= 2 )) && (( MEM_MB <= 2048 )); then
    TASKS_MAX_DEFAULT="8192"
  else
    TASKS_MAX_DEFAULT="16384"
  fi

  DO_SYSCTL="$(to_bool "$APPLY_SYSCTL" 1)"
  DO_JOURNALD="$(to_bool "$APPLY_JOURNALD" 1)"
  DO_FSTRIM="$(to_bool "$APPLY_FSTRIM" "$TRIM_OK")"
  DO_SYSTEMD_LIMITS="$(to_bool "$APPLY_SYSTEMD_LIMITS" 1)"
  DO_PAM_LIMITS="$(to_bool "$APPLY_PAM_LIMITS" 1)"
  DO_DOCKER="$(to_bool "$APPLY_DOCKER" "$HAS_DOCKER")"
  DO_DISABLE="$(to_bool "$APPLY_DISABLE" 1)"
  DO_BBR="$(to_bool "$APPLY_BBR" "$BBR_OK")"

  if (( MEM_MB > 0 )) && (( MEM_MB <= 4096 )); then
    DO_ZRAM="$(to_bool "$APPLY_ZRAM" 1)"
  else
    DO_ZRAM="$(to_bool "$APPLY_ZRAM" 0)"
  fi

  DO_SERVICE_AUDIT="$(to_bool "$APPLY_SERVICE_AUDIT" 1)"
  DO_DISABLE_CANDIDATES="$(to_bool "$APPLY_DISABLE_CANDIDATES" 0)"
  DO_PURGE_CANDIDATE_PACKAGES="$(to_bool "$APPLY_PURGE_CANDIDATE_PACKAGES" 0)"
}

print_report_and_plan() {
  log "Preflight:"
  echo " - arch: ${ARCH}"
  echo " - cpu: ${CPU_COUNT}"
  echo " - mem_mb: ${MEM_MB}"
  echo " - swap_mb: ${SWAP_MB}"
  echo " - root_gb: ${ROOT_GB}"
  echo " - oci_detected: ${IS_OCI}"
  echo " - trim_support: ${TRIM_OK}"
  echo " - bbr_support: ${BBR_OK}"
  echo " - docker_present: ${HAS_DOCKER}"
  echo " - zram_generator_present: ${HAS_ZRAM_GEN}"

  log "Plan (effective toggles):"
  echo " - sysctl: ${DO_SYSCTL}"
  echo " - journald: ${DO_JOURNALD} (SystemMaxUse=${JOURNAL_SYSTEM_MAX_DEFAULT}, RuntimeMaxUse=${JOURNAL_RUNTIME_MAX_DEFAULT}, Retention=${JOURNAL_RETENTION_DEFAULT})"
  echo " - fstrim.timer: ${DO_FSTRIM}"
  echo " - systemd limits: ${DO_SYSTEMD_LIMITS} (DefaultLimitNOFILE=${LIMIT_NOFILE_DEFAULT}, DefaultTasksMax=${TASKS_MAX_DEFAULT}, reexec=${REEXEC_SYSTEMD})"
  echo " - pam limits: ${DO_PAM_LIMITS} (* nofile ${LIMIT_NOFILE_DEFAULT})"
  echo " - disable conservative services: ${DO_DISABLE}"
  echo " - bbr+fq: ${DO_BBR}"
  echo " - zram: ${DO_ZRAM} (install_if_missing=${INSTALL_ZRAM})"
  echo " - docker logging: ${DO_DOCKER} (restart=${RESTART_DOCKER})"
  echo " - service audit: ${DO_SERVICE_AUDIT}"
  echo " - disable candidate services: ${DO_DISABLE_CANDIDATES}"
  echo " - purge candidate packages: ${DO_PURGE_CANDIDATE_PACKAGES}"
}

print_service_audit() {
  [[ "$DO_SERVICE_AUDIT" == "1" ]] || return 0

  log "Service audit:"
  if ! have_cmd systemctl; then
    echo " - systemctl: not available; skip"
    return 0
  fi

  local running
  running="$(list_running_services || true)"
  if [[ -z "$running" ]]; then
    echo " - running: (none detected)"
  else
    echo " - running services (unit names):"
    echo "$running" | awk '{print "   - " $0}'
  fi

  echo " - candidates (present/running):"
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    if unit_exists "$u"; then
      if unit_running "$u"; then
        echo "   - $u : present + RUNNING"
      else
        echo "   - $u : present"
      fi
    fi
  done < <(candidate_units)

  if unit_exists "snap.lxd.daemon.service" || unit_exists "snap.lxd.activate.service"; then
    echo "   - snap.lxd.* : present (snap-managed; removal via 'snap remove lxd' if desired)"
  fi
  if unit_exists "snap.cups.cupsd.service"; then
    echo "   - snap.cups.* : present (snap-managed; removal via 'snap remove cups' if desired)"
  fi
}

apply_sysctl() {
  [[ "$DO_SYSCTL" == "1" ]] || return 0
  mkdir -p /etc/sysctl.d
  write_file_if_changed "/etc/sysctl.d/99-vps-tune.conf" "# Managed by vps_tune.sh\n\
vm.swappiness=10\n\
vm.vfs_cache_pressure=50\n\
vm.dirty_background_ratio=5\n\
vm.dirty_ratio=15\n\
fs.file-max=1048576\n\
fs.inotify.max_user_watches=524288\n\
fs.inotify.max_user_instances=1024\n"
  sysctl --system >/dev/null 2>&1 || true
}

apply_bbr() {
  [[ "$DO_BBR" == "1" ]] || return 0
  mkdir -p /etc/sysctl.d
  write_file_if_changed "/etc/sysctl.d/99-vps-tune-net.conf" "# Managed by vps_tune.sh\n\
net.core.default_qdisc=fq\n\
net.ipv4.tcp_congestion_control=bbr\n\
net.core.somaxconn=4096\n\
net.ipv4.tcp_max_syn_backlog=4096\n\
net.core.netdev_max_backlog=16384\n"
  sysctl --system >/dev/null 2>&1 || true
}

apply_journald() {
  [[ "$DO_JOURNALD" == "1" ]] || return 0
  mkdir -p /etc/systemd/journald.conf.d
  write_file_if_changed "/etc/systemd/journald.conf.d/99-vps-tune.conf" "[Journal]\n\
SystemMaxUse=${JOURNAL_SYSTEM_MAX_DEFAULT}\n\
RuntimeMaxUse=${JOURNAL_RUNTIME_MAX_DEFAULT}\n\
MaxRetentionSec=${JOURNAL_RETENTION_DEFAULT}\n\
Compress=yes\n"
  if have_cmd systemctl; then
    systemctl restart systemd-journald >/dev/null 2>&1 || true
  fi
}

apply_fstrim() {
  [[ "$DO_FSTRIM" == "1" ]] || return 0
  if have_cmd systemctl && systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx 'fstrim.timer'; then
    systemctl enable --now fstrim.timer >/dev/null 2>&1 || true
  fi
}

apply_systemd_limits() {
  [[ "$DO_SYSTEMD_LIMITS" == "1" ]] || return 0
  mkdir -p /etc/systemd/system.conf.d
  write_file_if_changed "/etc/systemd/system.conf.d/99-vps-tune.conf" "[Manager]\n\
DefaultLimitNOFILE=${LIMIT_NOFILE_DEFAULT}\n\
DefaultTasksMax=${TASKS_MAX_DEFAULT}\n"

  if have_cmd systemctl; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ "$REEXEC_SYSTEMD" == "1" ]]; then
      systemctl daemon-reexec >/dev/null 2>&1 || true
    fi
  fi
}

apply_pam_limits() {
  [[ "$DO_PAM_LIMITS" == "1" ]] || return 0
  mkdir -p /etc/security/limits.d
  write_file_if_changed "/etc/security/limits.d/99-vps-tune.conf" "# Managed by vps_tune.sh\n\
* soft nofile ${LIMIT_NOFILE_DEFAULT}\n\
* hard nofile ${LIMIT_NOFILE_DEFAULT}\n"
}

disable_service_if_exists() {
  local unit="$1"
  unit_exists "$unit" || return 0
  systemctl disable --now "$unit" >/dev/null 2>&1 || true
  systemctl stop "$unit" >/dev/null 2>&1 || true
}

apply_disable_conservative_services() {
  [[ "$DO_DISABLE" == "1" ]] || return 0
  have_cmd systemctl || return 0

  # Conservative list from earlier script.
  disable_service_if_exists "multipathd.service"
  disable_service_if_exists "open-iscsi.service"
  disable_service_if_exists "iscsid.service"
  disable_service_if_exists "snap.lxd.daemon.service"
  disable_service_if_exists "snap.lxd.activate.service"
  disable_service_if_exists "snap.cups.cupsd.service"
  disable_service_if_exists "cups.service"
  disable_service_if_exists "cups-browsed.service"
}

disable_candidate_services() {
  [[ "$DO_DISABLE_CANDIDATES" == "1" ]] || return 0
  have_cmd systemctl || return 0

  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    disable_service_if_exists "$u"
  done < <(candidate_units)

  disable_service_if_exists "snap.lxd.daemon.service"
  disable_service_if_exists "snap.lxd.activate.service"
  disable_service_if_exists "snap.cups.cupsd.service"
}

install_zram_generator_if_needed() {
  [[ "$INSTALL_ZRAM" == "1" ]] || return 0
  have_cmd apt-get || return 0
  apt-get -y update >/dev/null 2>&1 || true
  apt-get -y install systemd-zram-generator >/dev/null 2>&1 || apt-get -y install zram-generator >/dev/null 2>&1 || true
}

apply_zram() {
  [[ "$DO_ZRAM" == "1" ]] || return 0

  if [[ "$HAS_ZRAM_GEN" != "1" ]]; then
    install_zram_generator_if_needed
    HAS_ZRAM_GEN="$(detect_zram_generator)"
  fi
  if [[ "$HAS_ZRAM_GEN" != "1" ]]; then
    warn "ZRAM enabled but zram-generator not found; skipping (set INSTALL_ZRAM=1 to attempt install)"
    return 0
  fi

  mkdir -p /etc/systemd
  write_file_if_changed "/etc/systemd/zram-generator.conf" "# Managed by vps_tune.sh\n\
[zram0]\n\
zram-size = ram / 4\n\
compression-algorithm = zstd\n\
swap-priority = 100\n"

  if have_cmd systemctl; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx 'systemd-zram-setup@.service'; then
      systemctl restart 'systemd-zram-setup@zram0.service' >/dev/null 2>&1 || true
    fi
  fi
}

merge_docker_daemon_json() {
  local daemon_json="/etc/docker/daemon.json"
  mkdir -p /etc/docker
  if [[ ! -f "$daemon_json" ]]; then
    printf '%s\n' '{}' >"$daemon_json"
  fi
  backup_file "$daemon_json"

  python3 - <<'PY'
import json
from pathlib import Path

p = Path("/etc/docker/daemon.json")
try:
    data = json.loads(p.read_text(encoding="utf-8") or "{}")
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}

data.setdefault("log-driver", "json-file")
opts = data.setdefault("log-opts", {})
if not isinstance(opts, dict):
    opts = {}
    data["log-opts"] = opts

opts["max-size"] = "10m"
opts["max-file"] = "3"

# Improves availability when docker daemon restarts.
data.setdefault("live-restore", True)

p.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print("[vps-tune] Wrote /etc/docker/daemon.json (log rotation + live-restore)")
PY
}

apply_docker() {
  [[ "$DO_DOCKER" == "1" ]] || return 0
  have_cmd docker || return 0

  merge_docker_daemon_json
  if [[ "$RESTART_DOCKER" == "1" ]] && have_cmd systemctl; then
    systemctl restart docker >/dev/null 2>&1 || true
  fi
}

purge_candidate_packages() {
  [[ "$DO_PURGE_CANDIDATE_PACKAGES" == "1" ]] || return 0
  have_cmd apt-get || { warn "apt-get not found; cannot purge packages"; return 0; }
  have_cmd systemctl || { warn "systemctl not found; cannot map units to packages"; return 0; }

  local pkgs=()
  unit_exists "multipathd.service" && pkgs+=(multipath-tools)
  (unit_exists "open-iscsi.service" || unit_exists "iscsid.service") && pkgs+=(open-iscsi)
  (unit_exists "cups.service" || unit_exists "cups-browsed.service") && pkgs+=(cups cups-browsed)
  unit_exists "avahi-daemon.service" && pkgs+=(avahi-daemon)
  unit_exists "bluetooth.service" && pkgs+=(bluez)
  unit_exists "ModemManager.service" && pkgs+=(modemmanager)
  unit_exists "rpcbind.service" && pkgs+=(rpcbind)
  unit_exists "nfs-server.service" && pkgs+=(nfs-kernel-server)

  if (( ${#pkgs[@]} == 0 )); then
    log "No candidate packages detected for purge"
    return 0
  fi

  # Deduplicate.
  local uniq=() p
  for p in "${pkgs[@]}"; do
    if ! printf '%s\n' "${uniq[@]}" | grep -qx "$p"; then
      uniq+=("$p")
    fi
  done

  log "Purging packages: ${uniq[*]}"
  apt-get -y update >/dev/null 2>&1 || true
  apt-get -y purge "${uniq[@]}" >/dev/null 2>&1 || true
  apt-get -y autoremove --purge >/dev/null 2>&1 || true
}

summary() {
  log "Summary:"
  echo " - sysctl: /etc/sysctl.d/99-vps-tune.conf"
  echo " - net sysctl (bbr): /etc/sysctl.d/99-vps-tune-net.conf"
  echo " - journald: /etc/systemd/journald.conf.d/99-vps-tune.conf"
  echo " - systemd defaults: /etc/systemd/system.conf.d/99-vps-tune.conf"
  echo " - pam limits: /etc/security/limits.d/99-vps-tune.conf"
  echo " - zram: /etc/systemd/zram-generator.conf"
  echo " - docker: /etc/docker/daemon.json"
  echo " - swappiness: $(sysctl -n vm.swappiness 2>/dev/null || echo '?')"
}

main() {
  decide_defaults
  print_report_and_plan
  print_service_audit

  if [[ "$MODE" == "plan" ]]; then
    log "MODE=plan; no changes applied."
    return 0
  fi
  if [[ "$MODE" != "apply" ]]; then
    warn "Unknown MODE='$MODE' (expected apply|plan)"
    exit 2
  fi

  need_root_for_apply

  apply_sysctl
  apply_bbr
  apply_journald
  apply_fstrim
  apply_systemd_limits
  apply_pam_limits
  apply_disable_conservative_services
  disable_candidate_services
  purge_candidate_packages
  apply_zram
  apply_docker
  summary
}

main "$@"
