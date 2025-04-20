#!/bin/bash

# --- Configuration ---
# Set to true to skip confirmation prompts (USE WITH CAUTION!)
# Can be overridden by environment variable: sudo AUTO_CONFIRM=true ./script.sh
AUTO_CONFIRM=${AUTO_CONFIRM:-false}

# Systemd Journald cleanup settings
# Max size (e.g., "100M", "500M", "1G"). Takes precedence over time.
JOURNALD_VACUUM_SIZE="200M"
# Max age (e.g., "2weeks", "1month", "3days"). Used if size is empty.
JOURNALD_VACUUM_TIME="1month"

# --- Helper Functions ---

# Function to print messages
log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARN] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_step() {
    echo "----------------------------------------"
    echo ">> STEP: $1"
    echo "----------------------------------------"
}

log_success() {
    echo "[SUCCESS] $1"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to ask for confirmation
confirm_action() {
    if [ "$AUTO_CONFIRM" = true ]; then
        log_warn "AUTO_CONFIRM=true, skipping confirmation for '$1'."
        return 0 # Yes
    fi

    read -p "❓ Confirm action: '$1'? (y/N): " response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0 # Yes
            ;;
        *)
            log_info "Skipping action: '$1'."
            return 1 # No
            ;;
    esac
}

# Function to get used disk space in Kilobytes for the root filesystem
get_used_space_kb() {
    # df --output=used / : Gets used space in 1K blocks for root mount point
    # tail -n 1 : Removes the header line
    # awk '{print $1}' : Extracts the first field (the number)
    df --output=used / | tail -n 1 | awk '{print $1}' || echo "0"
}

# Function to format Kilobytes into human-readable format (MB or GB)
format_kb() {
    local kb=$1
    local freed_mb=$(echo "scale=2; $kb / 1024" | bc)
    local freed_gb=$(echo "scale=2; $kb / 1024 / 1024" | bc)

    # Check if bc calculation was successful (output is numeric)
    if ! [[ "$freed_mb" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "${kb} KB (calc error)"
        return
    fi

    if (( $(echo "$kb >= 1048576" | bc -l) )); then # 1024 * 1024
        printf "%.2f GB\n" "$freed_gb"
    elif (( $(echo "$kb >= 1024" | bc -l) )); then
        printf "%.2f MB\n" "$freed_mb"
    else
        printf "%d KB\n" "$kb"
    fi
}

# --- Sanity Checks ---
log_info "Running preliminary checks..."

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root (or using sudo)."
    exit 1
fi

# Check for essential commands
for cmd in apt dpkg uname grep awk sed sudo bc df tail; do
    if ! command_exists "$cmd"; then
        log_error "Required command '$cmd' is not installed. Please install it."
        exit 1
    fi
done

# --- Main Script ---

total_freed_kb=0 # Initialize total freed space counter

# Function to execute a cleanup command and report freed space
run_cleanup_step() {
    local description="$1"
    local command_to_run="$2"
    local run_anyway=${3:-false} # Optional 3rd arg to force run without confirmation (use carefully)

    log_step "$description"

    if ! $run_anyway && ! confirm_action "$description"; then
        return # Skip if not confirmed
    fi

    local space_before_kb=$(get_used_space_kb)
    log_info "Running: $command_to_run"

    # Execute the command, capturing output and exit status
    eval "$command_to_run" # Use eval to handle complex commands with pipes/redirects if necessary
    local exit_status=$?

    if [ $exit_status -ne 0 ]; then
        log_warn "Command finished with errors (exit code $exit_status). Space calculation might be inaccurate."
    fi

    local space_after_kb=$(get_used_space_kb)
    local freed_step_kb=$((space_before_kb - space_after_kb))

    # Only count positive freed space
    if [ "$freed_step_kb" -gt 0 ]; then
        local freed_human=$(format_kb "$freed_step_kb")
        log_success "Freed approximately: $freed_human"
        total_freed_kb=$((total_freed_kb + freed_step_kb))
    elif [ "$freed_step_kb" -eq 0 ]; then
        log_info "No significant space freed by this step."
    else
        # This case (space increased) is unlikely for cleanup, but possible
        local increased_human=$(format_kb $((-freed_step_kb)))
        log_warn "Disk usage increased by approximately $increased_human. This can happen (e.g., logs generated during cleanup)."
    fi

    echo # Add a blank line for readability
}

log_info "Starting Ubuntu System Cleanup..."
initial_space_kb=$(get_used_space_kb)
log_info "Initial used space: $(format_kb $initial_space_kb)"
echo # Blank line

# 1. Update package list (doesn't free space, but good practice)
log_step "Update package list"
if confirm_action "Update package list (apt update)"; then
    log_info "Running apt update..."
    sudo apt update
    echo
fi

# 2. Clean APT Cache
run_cleanup_step "Clean APT cache (apt clean)" "sudo apt clean -y"

# 3. Remove Unused Dependencies
run_cleanup_step "Remove unused dependencies (apt autoremove)" "sudo apt autoremove --purge -y"

# 4. Clean Old Kernels
log_step "Clean old Kernels"
current_kernel=$(uname -r)
log_info "Current kernel: $current_kernel"

# Find old kernel images, headers, and modules
# Using grep 'linux-(image|headers|modules)-[0-9]' ensures we target kernel packages specifically
old_kernels=$(dpkg --list | grep -E 'linux-(image|headers|modules)-[0-9]' | awk '{print $2}' | grep -vE "linux-(image|headers|modules)-${current_kernel%-[a-z]*-generic}" | grep -vE "linux-(image|headers|modules)-generic" | tr '\n' ' ')

if [ -z "$old_kernels" ]; then
    log_info "No old kernels found to remove."
else
    log_info "Found old kernel packages to remove:"
    echo "$old_kernels" | fmt -w 80 # Format list for readability
    if confirm_action "Purge old kernel packages"; then
        space_before_kb=$(get_used_space_kb)
        log_info "Running kernel purge..."
        sudo apt purge $old_kernels -y
        local purge_status=$?

        if [ $purge_status -eq 0 ]; then
             # Update GRUB only if purge was successful
            log_info "Updating GRUB configuration..."
            sudo update-grub
            log_success "Kernel cleanup likely successful."
        else
            log_warn "Kernel purge command finished with errors (exit code $purge_status). GRUB not updated automatically. Space calculation might be inaccurate."
        fi

        # Run autoremove again, as removing kernels might leave new orphans
        log_info "Running autoremove again after kernel removal..."
        sudo apt autoremove --purge -y

        space_after_kb=$(get_used_space_kb)
        freed_step_kb=$((space_before_kb - space_after_kb))

        if [ "$freed_step_kb" -gt 0 ]; then
            freed_human=$(format_kb "$freed_step_kb")
            log_success "Freed approximately (kernels & subsequent autoremove): $freed_human"
            total_freed_kb=$((total_freed_kb + freed_step_kb))
        elif [ $purge_status -eq 0 ]; then
             log_info "No significant space freed by kernel removal."
        fi
    else
        log_info "Skipping kernel removal."
    fi
fi
echo # Blank line

# 5. Clean Systemd Journal Logs
log_step "Clean Systemd Journal Logs"
if command_exists journalctl; then
    journal_cmd=""
    if [ -n "$JOURNALD_VACUUM_SIZE" ]; then
        log_info "Configured to vacuum journal logs to size: $JOURNALD_VACUUM_SIZE"
        journal_cmd="sudo journalctl --vacuum-size=$JOURNALD_VACUUM_SIZE"
    elif [ -n "$JOURNALD_VACUUM_TIME" ]; then
        log_info "Configured to vacuum journal logs older than: $JOURNALD_VACUUM_TIME"
        journal_cmd="sudo journalctl --vacuum-time=$JOURNALD_VACUUM_TIME"
    else
        log_info "No size or time limit set for journald cleanup. Skipping."
    fi

    if [ -n "$journal_cmd" ]; then
       run_cleanup_step "Clean systemd journal logs" "$journal_cmd"
    fi
else
    log_warn "journalctl command not found. Skipping Systemd Journal cleanup."
fi
echo # Blank line

# 6. Clean Old Rotated Logs in /var/log
run_cleanup_step "Clean old rotated logs in /var/log" "sudo find /var/log -type f -regextype posix-extended -regex '.*\.([0-9]+|gz|xz|bz2)$' -delete"

# 7. Clean Temporary Files (Optional, with warning)
log_step "Clean Temporary Files (/tmp, /var/tmp)"
log_warn "Cleaning /tmp and /var/tmp can affect running applications!"
if confirm_action "Clean /tmp and /var/tmp directories"; then
    space_before_kb=$(get_used_space_kb)
    log_info "Cleaning /tmp/* ..."
    sudo rm -rf /tmp/* /tmp/.* > /dev/null 2>&1 # Be careful with .*
    log_info "Cleaning /var/tmp/* ..."
    sudo rm -rf /var/tmp/* /var/tmp/.* > /dev/null 2>&1 # Be careful with .*

    space_after_kb=$(get_used_space_kb)
    freed_step_kb=$((space_before_kb - space_after_kb))

    if [ "$freed_step_kb" -gt 0 ]; then
        freed_human=$(format_kb "$freed_step_kb")
        log_success "Freed approximately from temp dirs: $freed_human"
        total_freed_kb=$((total_freed_kb + freed_step_kb))
    else
         log_info "No significant space freed from temp directories."
    fi
else
    log_info "Skipping temporary file cleanup."
fi
echo # Blank line


# 8. Clean Docker Resources (Optional)
log_step "Clean Docker Resources (Optional)"
if command_exists docker; then
    log_warn "Docker prune will remove ALL unused containers, networks, images (including dangling AND unused), and build cache."
    if confirm_action "Run 'docker system prune -af'"; then
        run_cleanup_step "Prune Docker system (containers, networks, images, cache)" "sudo docker system prune -af"
    else
        log_info "Skipping Docker cleanup."
    fi
else
    log_info "Docker command not found. Skipping Docker cleanup."
fi
echo # Blank line

# --- Final Summary ---
log_step "Cleanup Summary"
final_space_kb=$(get_used_space_kb)
# Recalculate total freed based on initial and final, as a cross-check (though step-by-step sum is usually preferred)
total_freed_check_kb=$((initial_space_kb - final_space_kb))

log_success "System cleanup process finished!"
log_info "Initial used space: $(format_kb $initial_space_kb)"
log_info "Final used space:   $(format_kb $final_space_kb)"
log_success "Total space freed by this script (sum of steps): $(format_kb $total_freed_kb)"
# log_info "(Verification based on initial/final state: $(format_kb $total_freed_check_kb))" # Optional verification

# Suggest reboot if kernels were removed
# You could set a flag during kernel removal step
# if [ "$kernels_removed_flag" = true ]; then
#    log_warn "Old kernels were removed. A system reboot is recommended to activate the latest kernel and complete cleanup."
# fi

echo "----------------------------------------"

exit 0
