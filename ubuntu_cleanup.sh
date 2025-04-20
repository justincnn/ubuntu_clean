#!/bin/bash

# -----------------------------------------------------------------------------
# Ubuntu System Cleanup Script
# Version: 1.1
# Author: Your Name/AI Assistant
#
# Purpose: Cleans up various system caches, logs, and unnecessary files
#          on Ubuntu/Debian-based systems to free up disk space and
#          potentially improve performance.
#
# WARNING: Run this script with caution. While designed to be safe,
#          improper modification or interruption could potentially
#          affect your system. It's recommended to back up important
#          data before running extensive cleanup operations.
#          This script requires root privileges for most operations.
# -----------------------------------------------------------------------------

# --- Configuration ---
# Set to true to enable automatic confirmation for potentially risky actions
# Set to false to require manual 'y' confirmation for each major step
AUTO_CONFIRM=${AUTO_CONFIRM:-false}

# Journald log size limit (e.g., 100M, 500M, 1G)
JOURNALD_VACUUM_SIZE="200M"
# Journald log time limit (e.g., 2weeks, 1month, 3days) - uncomment to use instead of size
# JOURNALD_VACUUM_TIME="2weeks"

# --- Helper Functions ---

# Function to print header messages
print_header() {
    echo ""
    echo "=================================================="
    echo "$1"
    echo "=================================================="
}

# Function to print status messages
print_status() {
    echo "[INFO] $1"
}

# Function to print warning messages
print_warning() {
    echo "[WARN] $1"
}

# Function to print error messages and exit
print_error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# Function to ask for confirmation
confirm_action() {
    local message=$1
    if [[ "$AUTO_CONFIRM" == "true" ]]; then
        print_status "Auto-confirming: $message"
        return 0 # Simulate 'yes'
    fi

    local response
    read -p "$message (y/N)? " -r response
    echo # Move to a new line
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        return 0 # Yes
    else
        return 1 # No
    fi
}

# --- Pre-run Checks ---

# Check if running as root
if [[ "$(id -u)" -ne 0 ]]; then
   print_error "This script must be run as root. Please use sudo."
fi

# Check if apt is available
if ! command -v apt &> /dev/null; then
    print_error "'apt' command not found. This script is intended for Debian/Ubuntu-based systems."
fi

# Check if dpkg is available
if ! command -v dpkg &> /dev/null; then
    print_error "'dpkg' command not found. Cannot manage kernel packages."
fi

# Check if uname is available
if ! command -v uname &> /dev/null; then
    print_error "'uname' command not found. Cannot determine current kernel."
fi


# --- Main Cleanup Actions ---

# Ensure system package lists are up-to-date before cleaning
print_header "Updating Package Lists"
if sudo apt update; then
    print_status "Package lists updated successfully."
else
    print_warning "Failed to update package lists. Some cleanup steps might be affected."
fi


# 1. Clean APT Cache
print_header "Cleaning APT Cache"
if confirm_action "Remove downloaded package files (.deb) from the cache (/var/cache/apt/archives)?"; then
    print_status "Running 'sudo apt clean'..."
    if sudo apt clean; then
        print_status "APT cache cleaned successfully."
    else
        print_warning "Failed to clean APT cache."
    fi
else
    print_status "Skipping APT cache cleaning."
fi
echo "---"


# 2. Remove Unnecessary Packages (Auto Removable)
print_header "Removing Unused Dependencies"
if confirm_action "Remove automatically installed packages that are no longer required?"; then
    print_status "Running 'sudo apt autoremove --purge -y'..."
    # The -y is added here because autoremove is generally safe and often desired
    if sudo apt autoremove --purge -y; then
        print_status "Unused dependencies removed and purged successfully."
    else
        print_warning "Failed to remove unused dependencies."
    fi
else
    print_status "Skipping removal of unused dependencies."
fi
echo "---"


# 3. Clean Old Kernels
print_header "Cleaning Old Kernels"
current_kernel=$(uname -r)
print_status "Current running kernel: $current_kernel"

# Identify old kernel images, headers, and modules
old_kernels=$(dpkg --list | grep -E 'linux-(image|headers|modules)-[0-9]+' | awk '{print $2}' | grep -v "$current_kernel" | grep -v "$(echo $current_kernel | sed 's/-generic//')") # Also exclude base version number if needed

if [ -z "$old_kernels" ]; then
    print_status "No old kernels found to remove."
else
    print_status "Found old kernel packages to remove:"
    echo "$old_kernels" # Show the user what will be removed
    echo # Add a newline for clarity

    if confirm_action "Proceed with removing the listed old kernel packages?"; then
        print_status "Running 'sudo apt purge ...' for old kernels..."
        # Convert multi-line string to space-separated list for apt
        # Use xargs for safety with potentially large numbers of packages
        echo "$old_kernels" | xargs sudo apt purge -y
        if [ $? -eq 0 ]; then
            print_status "Old kernels purged successfully."
            # Update GRUB only if kernels were actually removed
            print_status "Updating GRUB configuration..."
            if sudo update-grub; then
                print_status "GRUB updated successfully."
            else
                print_warning "Failed to update GRUB. You might need to run 'sudo update-grub' manually."
            fi
        else
            print_warning "Failed to purge old kernels. Check the output above for errors."
        fi
    else
        print_status "Skipping old kernel removal."
    fi
fi
echo "---"


# 4. Clean Systemd Journal Logs
print_header "Cleaning Systemd Journal Logs"
if command -v journalctl &> /dev/null; then
    if [ -n "$JOURNALD_VACUUM_SIZE" ]; then
        action_msg="Vacuum journald logs to free up space, keeping approximately ${JOURNALD_VACUUM_SIZE}?"
        vacuum_cmd="sudo journalctl --vacuum-size=${JOURNALD_VACUUM_SIZE}"
    elif [ -n "$JOURNALD_VACUUM_TIME" ]; then
        action_msg="Vacuum journald logs older than ${JOURNALD_VACUUM_TIME}?"
        vacuum_cmd="sudo journalctl --vacuum-time=${JOURNALD_VACUUM_TIME}"
    else
        action_msg="" # No action configured
    fi

    if [ -n "$action_msg" ] && confirm_action "$action_msg"; then
        print_status "Running '$vacuum_cmd'..."
        if $vacuum_cmd; then
            print_status "Systemd journal logs vacuumed successfully."
        else
            print_warning "Failed to vacuum systemd journal logs."
        fi
    else
        print_status "Skipping systemd journal log cleaning or no action configured."
    fi
else
    print_status "journalctl command not found. Skipping journald log cleaning."
fi
echo "---"


# 5. Clean Rotated Log Files
print_header "Cleaning Old Rotated Log Files"
if confirm_action "Remove old, rotated system log files (e.g., *.log.1, *.log.gz) from /var/log?"; then
    print_status "Searching for and removing old log files..."
    # Remove compressed logs (.gz, .xz, .bz2)
    find_gz_output=$(sudo find /var/log -type f -name "*.gz" -print -delete 2>/dev/null)
    find_xz_output=$(sudo find /var/log -type f -name "*.xz" -print -delete 2>/dev/null)
    find_bz2_output=$(sudo find /var/log -type f -name "*.bz2" -print -delete 2>/dev/null)
    # Remove numbered logs (e.g., messages.1, syslog.2)
    find_num_output=$(sudo find /var/log -type f -regex '.*\.log\.[0-9]+$' -print -delete 2>/dev/null)
    # You might add more patterns here if needed

    if [ -n "$find_gz_output" ] || [ -n "$find_xz_output" ] || [ -n "$find_bz2_output" ] || [ -n "$find_num_output" ]; then
         print_status "Removed the following old log files:"
         [ -n "$find_gz_output" ] && echo "$find_gz_output"
         [ -n "$find_xz_output" ] && echo "$find_xz_output"
         [ -n "$find_bz2_output" ] && echo "$find_bz2_output"
         [ -n "$find_num_output" ] && echo "$find_num_output"
         print_status "Old rotated log files cleaned."
    else
         print_status "No old rotated log files matching patterns found or removed."
    fi
    # Consider forcing log rotation as a safer alternative sometimes:
    # print_status "Forcing log rotation (may take a moment)..."
    # sudo logrotate -f /etc/logrotate.conf
else
    print_status "Skipping old rotated log file cleaning."
fi
echo "---"


# 6. Clean Temporary Files (Use with Caution)
print_header "Cleaning Temporary Files"
if confirm_action "Remove contents of /tmp and /var/tmp? (WARNING: Active processes might use these directories)"; then
    print_status "Cleaning /tmp/* ..."
    sudo rm -rf /tmp/*
    sudo rm -rf /tmp/.* 2>/dev/null # Clean hidden files too, ignore errors for . and ..
    print_status "Cleaning /var/tmp/* ..."
    sudo rm -rf /var/tmp/*
    sudo rm -rf /var/tmp/.* 2>/dev/null # Clean hidden files too, ignore errors for . and ..
    print_status "Temporary directories cleaned."
else
    print_status "Skipping temporary file cleaning."
fi
echo "---"


# 7. Clean Docker Resources (Optional)
print_header "Cleaning Docker Resources (Optional)"
if command -v docker &> /dev/null; then
    print_status "Docker installation found."
    if confirm_action "Prune unused Docker resources (containers, networks, images, build cache)? (WARNING: Removes ALL unused images, not just dangling ones)"; then
        print_status "Running 'sudo docker system prune -af'..."
        if sudo docker system prune -af; then
             print_status "Docker resources pruned successfully."
        else
             print_warning "Failed to prune Docker resources. Check Docker daemon status and permissions."
        fi
    else
        print_status "Skipping Docker resource pruning."
    fi
else
    print_status "Docker not found. Skipping Docker cleanup."
fi
echo "---"


# --- Final Summary ---
print_header "Cleanup Complete"
print_status "System cleanup process finished."
print_status "Consider rebooting if major changes (like kernel removal) were performed."

# Attempt to show disk space savings (basic estimate)
# Note: This is a rough estimate before/after the script itself runs.
# A more accurate measure would require storing df output before *each* step.
# echo ""
# print_status "Disk usage after cleanup:"
# df -h /

echo ""
exit 0
