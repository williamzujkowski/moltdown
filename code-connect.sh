#!/usr/bin/env bash
#===============================================================================
# code-connect.sh - Open VS Code connected to agent VM
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
#
# Opens VS Code with Remote SSH extension connected to an agent VM.
#
# Usage:
#   ./code-connect.sh                    # Connect to most recent clone
#   ./code-connect.sh moltdown-clone-xxx # Connect to specific clone
#   ./code-connect.sh 192.168.122.x      # Connect by IP
#   ./code-connect.sh --path /home/agent/project  # Open specific path
#
# Requirements:
#   - VS Code with Remote - SSH extension installed
#   - SSH key authentication configured
#
# License: MIT
#===============================================================================

set -euo pipefail

VM_USER="${MOLTDOWN_USER:-agent}"
REMOTE_PATH="/home/${VM_USER}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

show_help() {
    cat << 'EOF'
code-connect.sh - Open VS Code connected to agent VM

Usage:
  ./code-connect.sh                         Connect to most recent clone
  ./code-connect.sh <clone-name>            Connect to specific clone
  ./code-connect.sh <ip-address>            Connect by IP address
  ./code-connect.sh --path <remote-path>    Open specific directory
  ./code-connect.sh -h, --help              Show this help

Options:
  --path <path>    Remote directory to open (default: /home/agent)

Examples:
  ./code-connect.sh
  ./code-connect.sh moltdown-clone-xxx
  ./code-connect.sh 192.168.122.45
  ./code-connect.sh --path /home/agent/nexus-agents
  ./code-connect.sh moltdown-clone-xxx --path ~/myproject

Requirements:
  - VS Code installed and in PATH
  - Remote - SSH extension (ms-vscode-remote.remote-ssh)
EOF
    exit 0
}

# Detect virsh
VIRSH="virsh"
if ! virsh list &>/dev/null 2>&1; then
    VIRSH="sudo virsh"
fi

get_clone_ip() {
    local clone="$1"
    $VIRSH domifaddr "$clone" 2>/dev/null | grep -oE '192\.168\.[0-9]+\.[0-9]+' | head -1
}

find_clone() {
    local partial="$1"

    if $VIRSH dominfo "$partial" &>/dev/null 2>&1; then
        echo "$partial"
        return 0
    fi

    local match
    match=$($VIRSH list --all --name 2>/dev/null | grep -E "(^|-)${partial}" | head -1)
    if [[ -n "$match" ]]; then
        echo "$match"
        return 0
    fi

    return 1
}

# Parse arguments
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help ;;
        --path)
            REMOTE_PATH="$2"
            shift 2
            ;;
        *)
            TARGET="$1"
            shift
            ;;
    esac
done

# Check VS Code is available
if ! command -v code &>/dev/null; then
    log_error "VS Code not found in PATH"
    log_info "Install VS Code or add it to PATH"
    exit 1
fi

# Find target
IP=""

if [[ -z "$TARGET" ]]; then
    # Find most recent running clone
    TARGET=$($VIRSH list --name 2>/dev/null | grep "^moltdown-clone" | head -1)
    if [[ -z "$TARGET" ]]; then
        log_error "No running clones found"
        log_info "Run './agent.sh' first to create an agent VM"
        exit 1
    fi
    log_info "Using most recent clone: $TARGET"
fi

# Check if target is an IP address
if [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IP="$TARGET"
else
    # It's a clone name
    clone=$(find_clone "$TARGET") || {
        log_error "Clone not found: $TARGET"
        exit 1
    }

    IP=$(get_clone_ip "$clone")
    if [[ -z "$IP" ]]; then
        log_error "Could not get IP for $clone"
        log_info "Is the VM running? Try: ./agent.sh --attach $clone"
        exit 1
    fi
fi

# Expand ~ in remote path
if [[ "$REMOTE_PATH" == "~"* ]]; then
    REMOTE_PATH="/home/${VM_USER}${REMOTE_PATH:1}"
fi

log_info "Opening VS Code to ${VM_USER}@${IP}:${REMOTE_PATH}"

# Open VS Code with Remote SSH
# Format: code --remote ssh-remote+user@host /path
code --remote "ssh-remote+${VM_USER}@${IP}" "$REMOTE_PATH"

log_info "VS Code launched!"
