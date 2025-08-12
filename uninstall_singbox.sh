#!/bin/sh

# sing-box uninstall script for FreeBSD
# Usage: ./uninstall_singbox.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

echo_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

echo_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

# Check if running as root
if [ "$(id -u)" = "0" ]; then
    echo_warn "Running as root, will clean system-wide installations"
    IS_ROOT=1
else
    echo_info "Running as regular user, will clean user installations"
    IS_ROOT=0
fi

# Function to stop sing-box processes
stop_singbox() {
    echo_info "Stopping sing-box processes..."
    
    # Find and kill sing-box processes
    PIDS=$(pgrep -f "sing-box" 2>/dev/null || true)
    if [ -n "$PIDS" ]; then
        echo_info "Found running sing-box processes: $PIDS"
        for pid in $PIDS; do
            echo_info "Killing process $pid"
            kill -TERM "$pid" 2>/dev/null || true
        done
        
        # Wait a bit for graceful shutdown
        sleep 2
        
        # Force kill if still running
        PIDS=$(pgrep -f "sing-box" 2>/dev/null || true)
        if [ -n "$PIDS" ]; then
            echo_warn "Force killing remaining processes"
            for pid in $PIDS; do
                kill -KILL "$pid" 2>/dev/null || true
            done
        fi
    else
        echo_info "No running sing-box processes found"
    fi
}

# Function to remove files and directories
remove_path() {
    local path="$1"
    if [ -e "$path" ]; then
        echo_info "Removing: $path"
        rm -rf "$path"
    else
        echo_info "Not found: $path"
    fi
}

# Main uninstall function
uninstall_singbox() {
    echo_info "Starting sing-box uninstall..."
    
    # Stop processes first
    stop_singbox
    
    # Remove the specified installation directory
    remove_path "/home/qqq/sing-box"
    
    # Remove common binary locations
    if [ "$IS_ROOT" = "1" ]; then
        remove_path "/usr/local/bin/sing-box"
        remove_path "/usr/bin/sing-box"
        remove_path "/opt/sing-box"
        remove_path "/etc/sing-box"
        remove_path "/var/log/sing-box"
        remove_path "/var/lib/sing-box"
    fi
    
    # Remove user-specific locations
    remove_path "$HOME/bin/sing-box"
    remove_path "$HOME/.local/bin/sing-box"
    remove_path "$HOME/sing-box"
    remove_path "$HOME/.sing-box"
    remove_path "$HOME/.config/sing-box"
    
    # Remove from common build/source directories
    remove_path "$HOME/singbox_build"
    remove_path "$HOME/go/src/github.com/SagerNet/sing-box"
    
    # Check for any remaining sing-box files
    echo_info "Checking for remaining sing-box files..."
    
    # Search in common directories
    SEARCH_DIRS="$HOME /usr/local /opt"
    if [ "$IS_ROOT" = "1" ]; then
        SEARCH_DIRS="$SEARCH_DIRS /usr /var"
    fi
    
    for dir in $SEARCH_DIRS; do
        if [ -d "$dir" ]; then
            FOUND=$(find "$dir" -name "*sing-box*" -type f 2>/dev/null || true)
            if [ -n "$FOUND" ]; then
                echo_warn "Found remaining files in $dir:"
                echo "$FOUND"
            fi
        fi
    done
    
    # Check if sing-box is still in PATH
    if command -v sing-box >/dev/null 2>&1; then
        LOCATION=$(which sing-box 2>/dev/null || true)
        echo_warn "sing-box still found in PATH: $LOCATION"
        if [ -n "$LOCATION" ]; then
            echo_info "Removing: $LOCATION"
            rm -f "$LOCATION" 2>/dev/null || echo_error "Failed to remove $LOCATION (permission denied?)"
        fi
    else
        echo_info "sing-box not found in PATH - good!"
    fi
    
    echo_info "Uninstall completed!"
    echo_info "You may need to reload your shell or logout/login to update PATH"
}

# Confirmation
echo_warn "This will remove sing-box from your system"
echo_warn "Target directory: /home/qqq/sing-box"
printf "Continue? (y/N): "
read -r CONFIRM

case "$CONFIRM" in
    [yY]|[yY][eE][sS])
        uninstall_singbox
        ;;
    *)
        echo_info "Uninstall cancelled"
        exit 0
        ;;
esac
