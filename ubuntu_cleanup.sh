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
    # Ensure kb is numeric, default to 0 if not
    if ! [[ "$kb" =~ ^[0-9]+$ ]]; then
        log_warn "Invalid value passed to format_kb: '$kb'. Using 0."
        kb=0
    fi
    # Check if bc exists before trying to use it
    if ! command_exists bc; then
        # Fallback to simple KB display if bc is missing (shouldn't happen after checks)
         printf "%d KB (bc not found)\n" "$kb"
         return
    fi

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

# --- Dependency Check and Installation ---
# Define essential commands that MUST exist and cannot be auto-installed by this script
essential_cmds=("apt" "dpkg" "uname" "grep" "awk" "sed" "sudo" "df" "tail")
# Define commands that are needed and can be auto-installed (map command to package name)
declare -A installable_cmds=( [bc]="bc" )
# Define optional commands checked later in the script (don't exit if missing)
optional_cmds=("journalctl" "docker")

# Combine all commands to check initially
all_cmds_to_check=("${essential_cmds[@]}" "${!installable_cmds[@]}") # Use keys of installable_cmds

needs_apt_update=false
packages_to_install=()

log_info "Checking required commands..."
for cmd in "${all_cmds_to_check[@]}"; do
    if ! command_exists "$cmd"; then
        # Is it an essential command?
        is_essential=false
        for essential in "${essential_cmds[@]}"; do
            if [[ "$cmd" == "$essential" ]]; then
                is_essential=true
                break
            fi
        done

        if $is_essential; then
            log_error "Essential command '$cmd' is not installed or not in PATH. Cannot continue."
            exit 1
        elif [[ -v installable_cmds[$cmd] ]]; then
            # It's an installable command
            package_name=${installable_cmds[$cmd]}
            log_warn "Required command '$cmd' not found. Will attempt to install package '$package_name'."
            packages_to_install+=("$package_name")
            needs_apt_update=true # Mark that apt update is needed
        # else: It's an optional command checked later, do nothing here
        fi
    else
        log_info "Command '$cmd' found."
    fi
done

# Install missing packages if any were found
if [ ${#packages_to_install[@]} -gt 0 ]; then
    log_info "Attempting to install missing packages: ${packages_to_install[*]}"
    if $needs_apt_update; then
        log_info "Running 'apt update' first..."
        if ! apt update -y; then
            log_error "apt update failed. Cannot install dependencies. Please run 'apt update' manually and fix any issues."
            exit 1
        fi
         log_info "'apt update' completed."
    fi

    for pkg in "${packages_to_install[@]}"; do
        log_info "Installing '$pkg'..."
        if ! apt install -y "$pkg"; then
            log_error "Failed to install package '$pkg'. Please install it manually."
            # Decide if you want to exit or continue with potentially limited functionality
            # For bc, it's critical for the reporting, so we exit.
            if [[ "$pkg" == "bc" ]]; then
                 log_error "Exiting because 'bc' is required for space reporting."
                 exit 1
            fi
            # If other non-critical tools were added, you might choose to continue here.
        else
            log_success "Package '$pkg' installed successfully."
            # Re-check if the command now exists (optional, but good verification)
            cmd_for_pkg=""
            for cmd_key in "${!installable_cmds[@]}"; do
                 if [[ "${installable_cmds[$cmd_key]}" == "$pkg" ]]; then
                      cmd_for_pkg=$cmd_key
                      break
                 fi
            done
            if [[ -n "$cmd_for_pkg" ]] && ! command_exists "$cmd_for_pkg"; then
                 log_warn "Package '$pkg' installed, but command '$cmd_for_pkg' still not found. This might indicate an issue."
            fi
        fi
    done
fi
# --- End Dependency Check ---


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
        # Don't calculate space if command failed badly, maybe? Or proceed? Let's proceed for now.
    fi

    local space_after_kb=$(get_used_space_kb)
    # Ensure space values are numeric before subtraction
    if ! [[ "$space_before_kb" =~ ^[0-9]+$ ]] || ! [[ "$space_after_kb" =~ ^[0-9]+$ ]]; then
        log_warn "Could not accurately determine disk space before/after. Skipping space calculation for this step."
        return
    fi

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
        # Optional: Subtract from total? Usually not desired for cleanup scripts.
        # total_freed_kb=$((total_freed_kb + freed_step_kb)) # This would subtract
    fi

    echo # Add a blank line for readability
}

log_info "Starting Ubuntu System Cleanup..."
initial_space_kb=$(get_used_space_kb)
log_info "Initial used space: $(format_kb $initial_space_kb)"
echo # Blank line

# 1. Update package list (doesn't free space, but good practice)
log_step "Update package list (optional)"
if confirm_action "Run 'apt update' (updates package lists)?"; then
    log_info "Running apt update..."
    # Don't use run_cleanup_step as it doesn't free space and output is useful
    apt update
    echo
fi

# 2. Clean APT Cache
run_cleanup_step "Clean APT cache (apt clean)" "apt clean -y"

# 3. Remove Unused Dependencies
run_cleanup_step "Remove unused dependencies (apt autoremove)" "apt autoremove --purge -y"

# 4. Clean Old Kernels
log_step "Clean old Kernels"
current_kernel=$(uname -r)
log_info "Current kernel: $current_kernel"

# Find old kernel images, headers, and modules
# Using grep 'linux-(image|headers|modules)-[0-9]' ensures we target kernel packages specifically
# Exclude the meta-packages (like linux-image-generic) and the currently running kernel series
# Note: Using %-*-generic correctly handles kernels like 5.15.0-100-generic
# Ensure the pattern matches the actual kernel version numbering on the system
old_kernels=$(dpkg --list | grep -E 'linux-(image|headers|modules)-[0-9]+\.' | awk '{print $2}' | grep -vE "linux-(image|headers|modules)-${current_kernel%-[a-z]*-generic}" | grep -vE 'linux-(image|headers|modules)-(generic|generic-hwe-[^ ]+|signed-image-[^ ]+)' | tr '\n' ' ')


if [ -z "$old_kernels" ]; then
    log_info "No old kernels found to remove."
else
    log_info "Found old kernel packages potentially removable:"
    echo "$old_kernels" | fmt -w 80 # Format list for readability
    if confirm_action "Purge old kernel packages listed above"; then
        space_before_kb=$(get_used_space_kb)
        log_info "Running kernel purge..."
        # Use apt purge directly here
        if apt purge $old_kernels -y; then
             local purge_status=0
             log_info "Kernel purge command successful (apt reported success)."
             # Update GRUB only if purge was successful
             log_info "Updating GRUB configuration..."
             update-grub
             log_success "Kernel cleanup appears successful. Running autoremove again..."
             # Run autoremove again, as removing kernels might leave new orphans
             apt autoremove --purge -y
        else
            local purge_status=$?
            log_warn "Kernel purge command finished with errors (exit code $purge_status). GRUB not updated automatically. Manual check recommended. Running autoremove anyway..."
            # Still run autoremove, it might clean up other things
             apt autoremove --purge -y
        fi

        space_after_kb=$(get_used_space_kb)
         if ! [[ "$space_before_kb" =~ ^[0-9]+$ ]] || ! [[ "$space_after_kb" =~ ^[0-9]+$ ]]; then
             log_warn "Could not accurately determine disk space before/after kernel cleanup. Skipping space calculation for this step."
         else
            freed_step_kb=$((space_before_kb - space_after_kb))
            if [ "$freed_step_kb" -gt 0 ]; then
                freed_human=$(format_kb "$freed_step_kb")
                log_success "Freed approximately (kernels & subsequent autoremove): $freed_human"
                total_freed_kb=$((total_freed_kb + freed_step_kb))
            elif [ $purge_status -eq 0 ]; then # Only log 'no space' if purge seemed ok
                 log_info "No significant space freed by kernel removal step."
            fi
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
    # Check current disk usage
    current_journal_usage=$(journalctl --disk-usage 2>/dev/null || echo "Could not determine usage")
    log_info "Current journal disk usage: $current_journal_usage"

    if [ -n "$JOURNALD_VACUUM_SIZE" ]; then
        log_info "Configured to vacuum journal logs to size: $JOURNALD_VACUUM_SIZE"
        journal_cmd="journalctl --vacuum-size=$JOURNALD_VACUUM_SIZE"
    elif [ -n "$JOURNALD_VACUUM_TIME" ]; then
        log_info "Configured to vacuum journal logs older than: $JOURNALD_VACUUM_TIME"
        journal_cmd="journalctl --vacuum-time=$JOURNALD_VACUUM_TIME"
    else
        log_info "No size or time limit set for journald cleanup via script config. Skipping vacuum."
    fi

    if [ -n "$journal_cmd" ]; then
       # Use run_cleanup_step, passing the journalctl command
       run_cleanup_step "Clean systemd journal logs (using $journal_cmd)" "$journal_cmd"
    fi
else
    log_warn "journalctl command not found. Skipping Systemd Journal cleanup."
fi
echo # Blank line

# 6. Clean Old Rotated Logs in /var/log
# Warning: This is aggressive. Make sure you don't need old rotated logs.
# Using run_cleanup_step for consistency
run_cleanup_step "Clean old rotated logs in /var/log (*.[0-9], *.gz, *.xz, *.bz2)" "find /var/log -type f -regextype posix-extended -regex '.*\.([0-9]+|gz|xz|bz2)$' -print -delete"

# 7. Clean Temporary Files (Optional, with warning)
log_step "Clean Temporary Files (/tmp, /var/tmp)"
log_warn "Cleaning /tmp and /var/tmp can affect running applications!"
if confirm_action "Clean /tmp and /var/tmp directories (use with caution)"; then
    space_before_kb=$(get_used_space_kb)
    log_info "Cleaning /tmp/* and /tmp/.* (excluding '.' and '..')..."
    find /tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} + > /dev/null 2>&1
    log_info "Cleaning /var/tmp/* and /var/tmp/.* (excluding '.' and '..')..."
    find /var/tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} + > /dev/null 2>&1

    space_after_kb=$(get_used_space_kb)
    if ! [[ "$space_before_kb" =~ ^[0-9]+$ ]] || ! [[ "$space_after_kb" =~ ^[0-9]+$ ]]; then
        log_warn "Could not accurately determine disk space before/after temp cleanup. Skipping space calculation for this step."
    else
        freed_step_kb=$((space_before_kb - space_after_kb))
        if [ "$freed_step_kb" -gt 0 ]; then
            freed_human=$(format_kb "$freed_step_kb")
            log_success "Freed approximately from temp dirs: $freed_human"
            total_freed_kb=$((total_freed_kb + freed_step_kb))
        else
             log_info "No significant space freed from temp directories."
        fi
    fi
else
    log_info "Skipping temporary file cleanup."
fi
echo # Blank line


# 8. Clean Docker Resources (Optional)
log_step "Clean Docker Resources (Optional)"
if command_exists docker; then
    log_warn "Docker prune will remove ALL unused containers, networks, images (both dangling AND unused), and build cache."
    if confirm_action "Run 'docker system prune -af' (removes ALL unused Docker data)"; then
        # Use run_cleanup_step
        run_cleanup_step "Prune Docker system (containers, networks, images, cache)" "docker system prune -af"
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
total_freed_check_kb=0
if [[ "$initial_space_kb" =~ ^[0-9]+$ ]] && [[ "$final_space_kb" =~ ^[0-9]+$ ]]; then
    total_freed_check_kb=$((initial_space_kb - final_space_kb))
fi


log_success "System cleanup process finished!"
log_info "Initial used space: $(format_kb $initial_space_kb)"
log_info "Final used space:   $(format_kb $final_space_kb)"
log_success "Total space freed by this script (sum of steps): $(format_kb $total_freed_kb)"
# log_info "(Verification based on initial/final state: $(format_kb $total_freed_check_kb))" # Optional verification

# Suggest reboot if kernels were removed (might need a flag set in the kernel section)
# Example: Check if the kernel purge command was attempted and successful
# if [[ -v purge_status ]] && [[ $purge_status -eq 0 ]]; then
#    log_warn "Old kernels were removed. A system reboot is recommended to activate the latest kernel and complete cleanup."
# fi

echo "----------------------------------------"

exit 0
