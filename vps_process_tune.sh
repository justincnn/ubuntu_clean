#!/usr/bin/env bash
set -euo pipefail

# vps_process_tune.sh
# Conservative, idempotent Ubuntu VPS tuning focused on process stability:
# - vm.swappiness=10 (persist)
# - journald disk usage caps (persist)
# - fstrim.timer enable (if present)
# - systemd + PAM limits (nofile, tasks) (persist)
# - Docker json-file log rotation (persist)
# - Disable commonly-unused services on VPS (if present)
#
# Optional env vars:
#   APPLY_SYSCTL=1           Apply sysctl tuning (default 1)
#   APPLY_JOURNALD=1         Apply journald caps (default 1)
#   APPLY_FSTRIM=1           Enable fstrim.timer if present (default 1)
#   APPLY_SYSTEMD_LIMITS=1   Write systemd defaults (default 1)
#   APPLY_PAM_LIMITS=1       Write /etc/security/limits.d rules (default 1)
#   APPLY_DISABLE=1          Disable unused services (default 1)
#   APPLY_DOCKER=1           Apply Docker logging config (default 1)
#
#   RESTART_DOCKER=0         Restart docker after writing daemon.json (default 0)
#   REEXEC_SYSTEMD=0         systemctl daemon-reexec after system.conf change (default 0)
#
#   JOURNAL_SYSTEM_MAX=200M  journald SystemMaxUse (default 200M)
#   JOURNAL_RUNTIME_MAX=100M journald RuntimeMaxUse (default 100M)
#   JOURNAL_RETENTION=7day   journald MaxRetentionSec (default 7day)
#
#   LIMIT_NOFILE=65535       DefaultLimitNOFILE and PAM nofile limit (default 65535)
#   TASKS_MAX=16384          systemd DefaultTasksMax (default 16384)

APPLY_SYSCTL="${APPLY_SYSCTL:-1}"
APPLY_JOURNALD="${APPLY_JOURNALD:-1}"
APPLY_FSTRIM="${APPLY_FSTRIM:-1}"
APPLY_SYSTEMD_LIMITS="${APPLY_SYSTEMD_LIMITS:-1}"
APPLY_PAM_LIMITS="${APPLY_PAM_LIMITS:-1}"
APPLY_DISABLE="${APPLY_DISABLE:-1}"
APPLY_DOCKER="${APPLY_DOCKER:-1}"

RESTART_DOCKER="${RESTART_DOCKER:-0}"
REEXEC_SYSTEMD="${REEXEC_SYSTEMD:-0}"

JOURNAL_SYSTEM_MAX="${JOURNAL_SYSTEM_MAX:-200M}"
JOURNAL_RUNTIME_MAX="${JOURNAL_RUNTIME_MAX:-100M}"
JOURNAL_RETENTION="${JOURNAL_RETENTION:-7day}"

LIMIT_NOFILE="${LIMIT_NOFILE:-65535}"
TASKS_MAX="${TASKS_MAX:-16384}"

log() { echo "[vps-proc-tune] $*"; }
warn() { echo "[vps-proc-tune][WARN] $*" >&2; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    warn "Run as root: sudo -H bash $0"
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
  # Usage: write_file_if_changed /path/to/file "content"
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

apply_sysctl() {
  [[ "$APPLY_SYSCTL" == "1" ]] || { log "Skip sysctl (APPLY_SYSCTL=0)"; return 0; }

  log "Apply sysctl tuning (persist) ..."
  mkdir -p /etc/sysctl.d

  # Keep conservative and process-oriented.
  write_file_if_changed "/etc/sysctl.d/99-vps-proc-tune.conf" "# Managed by vps_process_tune.sh\n\
vm.swappiness=10\n\
vm.vfs_cache_pressure=50\n\
vm.dirty_background_ratio=5\n\
vm.dirty_ratio=15\n\
fs.file-max=1048576\n\
fs.inotify.max_user_watches=524288\n\
fs.inotify.max_user_instances=1024\n"

  # Apply immediately (best-effort).
  sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
  sysctl --system >/dev/null 2>&1 || true

  log "vm.swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo '?')"
}

tune_journald() {
  [[ "$APPLY_JOURNALD" == "1" ]] || { log "Skip journald (APPLY_JOURNALD=0)"; return 0; }

  log "Cap systemd-journald disk usage (persist) ..."
  mkdir -p /etc/systemd/journald.conf.d
  write_file_if_changed "/etc/systemd/journald.conf.d/99-vps-proc-tune.conf" "[Journal]\n\
SystemMaxUse=${JOURNAL_SYSTEM_MAX}\n\
RuntimeMaxUse=${JOURNAL_RUNTIME_MAX}\n\
MaxRetentionSec=${JOURNAL_RETENTION}\n\
Compress=yes\n"

  systemctl restart systemd-journald >/dev/null 2>&1 || true
  log "journald drop-in: /etc/systemd/journald.conf.d/99-vps-proc-tune.conf"
}

enable_fstrim() {
  [[ "$APPLY_FSTRIM" == "1" ]] || { log "Skip fstrim (APPLY_FSTRIM=0)"; return 0; }

  if systemctl list-unit-files | awk '{print $1}' | grep -qx 'fstrim.timer'; then
    log "Enable fstrim.timer (if disk supports TRIM) ..."
    systemctl enable --now fstrim.timer >/dev/null 2>&1 || true
  else
    log "fstrim.timer not found; skip"
  fi
}

apply_systemd_limits() {
  [[ "$APPLY_SYSTEMD_LIMITS" == "1" ]] || { log "Skip systemd limits (APPLY_SYSTEMD_LIMITS=0)"; return 0; }

  log "Write systemd defaults (nofile/tasks) (persist) ..."
  mkdir -p /etc/systemd/system.conf.d
  write_file_if_changed "/etc/systemd/system.conf.d/99-vps-proc-tune.conf" "[Manager]\n\
DefaultLimitNOFILE=${LIMIT_NOFILE}\n\
DefaultTasksMax=${TASKS_MAX}\n"

  systemctl daemon-reload >/dev/null 2>&1 || true

  if [[ "$REEXEC_SYSTEMD" == "1" ]]; then
    log "REEXEC_SYSTEMD=1; systemctl daemon-reexec (may briefly disrupt services) ..."
    systemctl daemon-reexec >/dev/null 2>&1 || true
  else
    log "systemd defaults written; reboot or set REEXEC_SYSTEMD=1 to apply immediately"
  fi
}

apply_pam_limits() {
  [[ "$APPLY_PAM_LIMITS" == "1" ]] || { log "Skip PAM limits (APPLY_PAM_LIMITS=0)"; return 0; }

  log "Write /etc/security/limits.d nofile (persist) ..."
  mkdir -p /etc/security/limits.d
  write_file_if_changed "/etc/security/limits.d/99-vps-proc-tune.conf" "# Managed by vps_process_tune.sh\n\
* soft nofile ${LIMIT_NOFILE}\n\
* hard nofile ${LIMIT_NOFILE}\n"
}

disable_service_if_exists() {
  local unit="$1"
  if systemctl list-unit-files | awk '{print $1}' | grep -qx "$unit"; then
    log "Disable service: $unit"
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    systemctl stop "$unit" >/dev/null 2>&1 || true
  else
    log "Service not present: $unit"
  fi
}

disable_unused_services() {
  [[ "$APPLY_DISABLE" == "1" ]] || { log "Skip disabling services (APPLY_DISABLE=0)"; return 0; }

  log "Disable commonly-unused services on VPS (if present) ..."
  disable_service_if_exists "multipathd.service"
  disable_service_if_exists "open-iscsi.service"
  disable_service_if_exists "iscsid.service"
  disable_service_if_exists "snap.lxd.daemon.service"
  disable_service_if_exists "snap.lxd.activate.service"
  disable_service_if_exists "snap.cups.cupsd.service"
  disable_service_if_exists "cups.service"
  disable_service_if_exists "cups-browsed.service"
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

# Force rotation settings.
opts["max-size"] = "10m"
opts["max-file"] = "3"

p.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print("[vps-proc-tune] Wrote /etc/docker/daemon.json: json-file max-size=10m max-file=3")
PY
}

tune_docker() {
  [[ "$APPLY_DOCKER" == "1" ]] || { log "Skip Docker (APPLY_DOCKER=0)"; return 0; }

  if ! command -v docker >/dev/null 2>&1; then
    log "docker not installed; skip"
    return 0
  fi

  log "Configure Docker log rotation (persist) ..."
  merge_docker_daemon_json

  if [[ "$RESTART_DOCKER" == "1" ]]; then
    log "RESTART_DOCKER=1; restarting docker (may briefly interrupt containers) ..."
    systemctl restart docker >/dev/null 2>&1 || true
  else
    log "Docker config written; restart later to apply (RESTART_DOCKER=0)"
  fi
}

summary() {
  log "Summary:"
  echo " - sysctl: /etc/sysctl.d/99-vps-proc-tune.conf (if enabled)"
  echo " - journald: /etc/systemd/journald.conf.d/99-vps-proc-tune.conf (if enabled)"
  echo " - systemd: /etc/systemd/system.conf.d/99-vps-proc-tune.conf (if enabled)"
  echo " - limits: /etc/security/limits.d/99-vps-proc-tune.conf (if enabled)"
  echo " - docker: /etc/docker/daemon.json (if docker present)"
  echo " - swappiness: $(sysctl -n vm.swappiness 2>/dev/null || echo '?')"
  echo " - DefaultLimitNOFILE: $(systemctl show --property=DefaultLimitNOFILE --value 2>/dev/null || echo '?')"
  echo " - DefaultTasksMax: $(systemctl show --property=DefaultTasksMax --value 2>/dev/null || echo '?')"
}

main() {
  need_root
  apply_sysctl
  tune_journald
  enable_fstrim
  apply_systemd_limits
  apply_pam_limits
  disable_unused_services
  tune_docker
  summary
}

main "$@"

# NOTE: This repository now also includes vps_tune.sh, a unified (adaptive + conservative)
# tuning script with MODE=plan support and service audit.
