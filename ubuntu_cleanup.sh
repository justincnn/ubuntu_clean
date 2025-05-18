#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
# set -e # Be cautious with set -e in a script that performs many independent steps.
# Treat unset variables as an error when substituting.
set -u
# Pipestatus: exit status of a pipeline is the status of the last command to exit with non-zero
set -o pipefail

# --- Configuration ---
# For this modified version, it's ALWAYS true to make all steps default.
AUTO_CONFIRM=true

# Script Log File
LOG_DIR="/var/log/system-cleanup"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/cleanup-$(date +%Y%m%d-%H%M%S).log"

# Systemd Journald cleanup settings
JOURNALD_VACUUM_SIZE="200M" # Max size (e.g., "100M", "500M", "1G"). Takes precedence over time.
JOURNALD_VACUUM_TIME="1month" # Max age (e.g., "2weeks", "1month", "3days"). Used if size is empty.

# Flag to track if kernels were removed, to suggest reboot
kernels_removed_flag=false

# --- Helper Functions ---
# (Redirect all stdout/stderr of helper functions and main script to log file and console)
exec > >(tee -a "$LOG_FILE") 2>&1

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_step() {
    echo "----------------------------------------"
    echo ">> STEP: $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "----------------------------------------"
}

log_success() {
    echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

confirm_action() {
    if [ "$AUTO_CONFIRM" = true ]; then
        # log_warn "AUTO_CONFIRM=true, automatically proceeding with action: '$1'." # Already logged by run_cleanup_step's description
        return 0 # Yes
    fi
    read -p "❓ Confirm action: '$1'? (y/N): " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) log_info "Skipping action: '$1'."; return 1 ;;
    esac
}

get_used_space_kb() {
    df --output=used / | awk 'NR==2 {print $1}' || echo "0"
}

format_kb() {
    local kb=$1
    if ! [[ "$kb" =~ ^-?[0-9]+$ ]]; then # Allow negative numbers for diffs
        echo "${kb} (invalid input)"
        return
    fi

    local abs_kb=${kb#-} # Absolute value for bc division
    local sign=""
    if [[ "$kb" =~ ^- ]]; then
        sign="-"
    fi

    local freed_mb=$(echo "scale=2; $abs_kb / 1024" | bc 2>/dev/null)
    local freed_gb=$(echo "scale=2; $abs_kb / 1024 / 1024" | bc 2>/dev/null)

    if ! [[ "$freed_mb" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! [[ "$freed_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "${sign}${abs_kb} KB (bc calc error or non-numeric output)"
        return
    fi

    if (( $(echo "$abs_kb >= 1048576" | bc -l) )); then # 1024 * 1024
        printf "%s%.2f GB\n" "$sign" "$freed_gb"
    elif (( $(echo "$abs_kb >= 1024" | bc -l) )); then
        printf "%s%.2f MB\n" "$sign" "$freed_mb"
    else
        printf "%s%d KB\n" "$sign" "$kb" # Original KB for small values
    fi
}

# --- Sanity Checks ---
log_info "Script log file: $LOG_FILE"
log_info "Running preliminary checks..."

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root (or using sudo)."
    exit 1
fi

essential_commands=("apt-get" "dpkg-query" "uname" "grep" "awk" "sed" "sudo" "bc" "df" "find" "tee" "date" "fmt")
for cmd in "${essential_commands[@]}"; do
    if ! command_exists "$cmd"; then
        log_error "Required command '$cmd' is not installed. Please install it."
        exit 1
    fi
done

# --- Main Script ---
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
    log_info "Running: $command_to_run"

    local exit_status=0
    if ! sudo bash -c "$command_to_run"; then
        exit_status=$?
        log_warn "Command finished with errors (exit code $exit_status). Space calculation might be inaccurate."
    else
        log_info "Command executed successfully."
    fi

    local space_after_kb
    space_after_kb=$(get_used_space_kb)
    local freed_step_kb=$((space_before_kb - space_after_kb))

    if [ "$freed_step_kb" -gt 0 ]; then
        local freed_human
        freed_human=$(format_kb "$freed_step_kb")
        log_success "Freed approximately: $freed_human"
        total_freed_kb=$((total_freed_kb + freed_step_kb))
    elif [ "$freed_step_kb" -eq 0 ] && [ "$exit_status" -eq 0 ]; then
        log_info "No significant space freed by this step."
    elif [ "$exit_status" -eq 0 ]; then # CORRECTED: Added 'then'
        # This case means command was successful, but freed_step_kb is negative (space used increased)
        local changed_human
        changed_human=$(format_kb "$freed_step_kb") # Will show as negative
        log_warn "Disk usage changed by approximately $changed_human. This can happen (e.g., logs generated during cleanup, or space freed then reallocated quickly)."
    fi
    echo
}

log_info "Starting Ubuntu System Cleanup & Optimization..."
initial_space_kb=$(get_used_space_kb)
log_info "Initial used space: $(format_kb "$initial_space_kb")"
echo

# 1. Update package list (good practice before upgrades/other apt actions)
log_step "Update package list"
if confirm_action "Update package list (apt-get update)"; then
    log_info "Running apt-get update -y..."
    if sudo apt-get update -y; then
        log_success "Package list updated."
    else
        log_warn "apt-get update finished with errors (exit code $?)."
    fi
    echo
fi

# 2. Upgrade installed packages (Improves efficiency and security)
log_step "Upgrade all installed packages"
if confirm_action "Upgrade all installed packages (apt-get full-upgrade)"; then
    log_info "Running apt-get full-upgrade -y..."
    if sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"; then
        log_success "System packages upgraded."
    else
        log_warn "apt-get full-upgrade finished with errors (exit code $?)."
    fi
    echo
fi

# 3. Clean APT Cache
run_cleanup_step "Clean APT cache (apt-get clean)" "apt-get clean -y"

# 4. Remove Unused Dependencies
run_cleanup_step "Remove unused dependencies (apt-get autoremove)" "apt-get autoremove --purge -y"

# 5. Clean Old Kernels
log_step "Clean old Kernels"
current_kernel=$(uname -r)
log_info "Current kernel: $current_kernel"

old_kernels=$(dpkg-query -W -f='${Package}\t${Status}\n' 'linux-image-[0-9]*' 'linux-headers-[0-9]*' 'linux-modules-[0-9]*' 'linux-modules-extra-[0-9]*' 2>/dev/null | \
    grep '\sinstall ok installed$' | \
    awk '{print $1}' | \
    grep -Pv "^linux-(image|headers|modules|modules-extra)-(${current_kernel%-[a-z0-9]*-generic}|${current_kernel%-[a-z0-9]*-lowlatency}|${current_kernel%-[a-z0-9]*-azure}|${current_kernel%-[a-z0-9]*-aws}|${current_kernel%-[a-z0-9]*-gcp}|${current_kernel%-[a-z0-9]*-oracle}|generic|lowlatency|azure|aws|gcp|oracle})$" | \
    grep -Pv "^linux-(image|headers|modules|modules-extra)-$(uname -r)$" | \
    tr '\n' ' ')

if [ -z "$old_kernels" ]; then
    log_info "No old kernels found to remove."
else
    log_info "Found old kernel packages to remove:"
    echo "$old_kernels" | fmt -w 80
    if confirm_action "Purge old kernel packages"; then
        space_before_kb=$(get_used_space_kb)
        log_info "Running kernel purge for: $old_kernels"
        purge_exit_status=0
        if ! sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y $old_kernels; then
            purge_exit_status=$?
            log_warn "Kernel purge command finished with errors (exit code $purge_exit_status)."
        else
            log_success "Old kernels purged successfully."
            kernels_removed_flag=true
            log_info "Updating GRUB configuration..."
            if sudo update-grub; then
                log_success "GRUB updated."
            else
                log_warn "update-grub failed (exit code $?). Manual check might be needed."
            fi
        fi

        log_info "Running autoremove again after kernel removal..."
        if sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y; then
            log_info "Post-kernel removal autoremove completed."
        else
            log_warn "Post-kernel removal autoremove failed (exit code $?)."
        fi

        space_after_kb=$(get_used_space_kb)
        freed_step_kb=$((space_before_kb - space_after_kb))

        if [ "$freed_step_kb" -gt 0 ]; then
            log_success "Freed approximately (kernels & subsequent autoremove): $(format_kb $freed_step_kb)"
            total_freed_kb=$((total_freed_kb + freed_step_kb))
        elif [ "$purge_exit_status" -eq 0 ]; then # Only log "no space freed" if purge itself was okay
             log_info "No significant space freed by kernel removal, or space was reclaimed and re-used quickly."
        fi
    fi
fi
echo

# 6. Clean Systemd Journal Logs
log_step "Clean Systemd Journal Logs"
if command_exists journalctl; then
    journal_cmd_desc=""
    journal_cmd_run=""
    if [ -n "$JOURNALD_VACUUM_SIZE" ]; then # CORRECTED: 'S' to 'then'
        journal_cmd_desc="Clean systemd journal logs to size: $JOURNALD_VACUUM_SIZE"
        journal_cmd_run="journalctl --vacuum-size=$JOURNALD_VACUUM_SIZE"
    elif [ -n "$JOURNALD_VACUUM_TIME" ]; then
        journal_cmd_desc="Clean systemd journal logs older than: $JOURNALD_VACUUM_TIME"
        journal_cmd_run="journalctl --vacuum-time=$JOURNALD_VACUUM_TIME"
    else
        log_info "No size or time limit set for journald cleanup. Skipping this specific journal cleanup method."
    fi

    if [ -n "$journal_cmd_run" ]; then
       run_cleanup_step "$journal_cmd_desc" "$journal_cmd_run"
    fi
else
    log_warn "journalctl command not found. Skipping Systemd Journal cleanup."
fi
echo

# 7. Clean Old Rotated Logs in /var/log
run_cleanup_step "Clean old rotated logs in /var/log (files ending with .[0-9] or .gz, .xz, .bz2)" \
                 "find /var/log -type f -regextype posix-extended -regex '.*/.*\.(log\.[0-9]+(\.gz)?|[0-9]+|gz|xz|bz2)$' -delete"


# 8. Clean Temporary Files (Safer Approach)
log_step "Clean Temporary Files (/tmp, /var/tmp)"
log_warn "Cleaning /tmp and /var/tmp. This is generally safe but ensure no critical temp data exists for long-running processes."

run_cleanup_step "Clean /tmp (items older than 1 day)" \
                 "find /tmp -mindepth 1 -mtime +0 -delete"
run_cleanup_step "Clean /var/tmp (items older than 7 days)" \
                 "find /var/tmp -mindepth 1 -mtime +6 -delete"
echo

# 9. Clean Snap Package Revisions (if snapd is installed)
log_step "Clean old Snap package revisions"
if command_exists snap; then
    if confirm_action "Remove old/disabled snap revisions"; then
        log_info "Looking for old snap revisions to remove..."
        space_before_kb=$(get_used_space_kb)
        
        snap_list_output=$(LANG=C snap list --all) # Capture list once
        echo "$snap_list_output" | awk '/disabled|broken/{print $1, $3}' |
        while read -r snapname revision; do
            log_info "Attempting to remove snap: $snapname revision $revision"
            if sudo snap remove "$snapname" --revision="$revision"; then
                log_info "Removed snap: $snapname revision $revision"
            else
                log_warn "Failed to remove snap: $snapname revision $revision (exit code $?). It might have been already gone or is required by another snap."
            fi
        done

        space_after_kb=$(get_used_space_kb)
        freed_step_kb=$((space_before_kb - space_after_kb))
        if [ "$freed_step_kb" -gt 0 ]; then
            log_success "Freed approximately from old snap revisions: $(format_kb $freed_step_kb)"
            total_freed_kb=$((total_freed_kb + freed_step_kb))
        else
            log_info "No significant space freed from snap revisions, or no old revisions found/removed."
        fi
    fi
else
    log_info "Snap command not found. Skipping Snap cleanup."
fi
echo

# 10. Clean Docker Resources (Optional)
log_step "Clean Docker Resources (Optional)"
if command_exists docker; then
    log_warn "Docker prune will remove ALL unused containers, networks, images (dangling AND unused), and build cache."
    if confirm_action "Run 'docker system prune -af'"; then
        run_cleanup_step "Prune Docker system (containers, networks, images, cache)" "docker system prune -af"
    fi
else
    log_info "Docker command not found. Skipping Docker cleanup."
fi
echo

# --- Final Summary ---
log_step "Cleanup Summary"
final_space_kb=$(get_used_space_kb)
total_freed_check_kb=$((initial_space_kb - final_space_kb))

log_success "System cleanup and optimization process finished!"
log_info "Initial used space: $(format_kb "$initial_space_kb")"
log_info "Final used space:   $(format_kb "$final_space_kb")"

if [ "$total_freed_kb" -lt 0 ]; then 
    total_freed_kb=0
fi

if [ "$total_freed_check_kb" -lt 0 ]; then 
    log_warn "Overall disk usage appears to have increased by $(format_kb $(( -total_freed_check_kb )))."
    log_warn "Total space freed by script (sum of positive steps): $(format_kb $total_freed_kb)"
else
    log_success "Total space freed by this script (sum of steps): $(format_kb $total_freed_kb)"
    log_info "(Verification based on initial/final state: $(format_kb $total_freed_check_kb))"
    if [ "$total_freed_kb" -ne "$total_freed_check_kb" ] && [ "$total_freed_check_kb" -ge 0 ]; then
        log_warn "Note: Sum of steps and initial/final state difference can occur due to concurrent disk activity or calculation nuances."
    fi
fi


if [ "$kernels_removed_flag" = true ]; then
   log_warn "Old kernels were removed. A system reboot is highly recommended to activate the latest kernel and complete cleanup."
fi

log_info "Cleanup log saved to: $LOG_FILE"
echo "----------------------------------------"

exit 0
