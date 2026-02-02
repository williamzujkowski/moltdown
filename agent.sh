#!/usr/bin/env bash
#===============================================================================
# agent.sh - One command to spin up a ready-to-use agent VM
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
#
# Creates a linked clone, starts it, waits for SSH, and connects.
#
# Usage:
#   ./agent.sh                    # Create new clone and connect
#   ./agent.sh --list             # List running agent clones
#   ./agent.sh --stop <name>      # Stop a clone
#   ./agent.sh --kill <name>      # Delete a clone
#   ./agent.sh --attach <name>    # Attach to existing clone
#   ./agent.sh --gui <name>       # Open GUI for clone
#
# Environment:
#   MOLTDOWN_GOLDEN      Golden VM name (default: moltdown-integration-test)
#   MOLTDOWN_USER        SSH username (default: agent)
#   MOLTDOWN_SSH_TIMEOUT SSH timeout in seconds (default: 180)
#
# License: MIT
#===============================================================================

set -euo pipefail

readonly SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

GOLDEN_VM="${MOLTDOWN_GOLDEN:-moltdown-integration-test}"
VM_USER="${MOLTDOWN_USER:-agent}"
SSH_TIMEOUT="${MOLTDOWN_SSH_TIMEOUT:-180}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}[====]${NC}  $*"; }

show_help() {
    cat << 'EOF'
agent.sh - One command to spin up a ready-to-use agent VM

Usage:
  ./agent.sh                    Create new clone and connect
  ./agent.sh --list             List all agent clones
  ./agent.sh --attach <name>    Attach to existing clone
  ./agent.sh --stop <name>      Stop a clone gracefully
  ./agent.sh --kill <name>      Delete a clone completely
  ./agent.sh --gui [name]       Open GUI viewer for clone
  ./agent.sh --health [name]    Run health check on clone
  ./agent.sh -h, --help         Show this help

Arguments:
  <name>    Clone name or partial match (e.g., "moltdown-clone-xxx" or just "xxx")

Environment Variables:
  MOLTDOWN_GOLDEN       Golden VM name (default: moltdown-integration-test)
  MOLTDOWN_USER         SSH username (default: agent)
  MOLTDOWN_SSH_TIMEOUT  SSH wait timeout in seconds (default: 180)

Examples:
  ./agent.sh                     # New agent VM, auto-connect
  ./agent.sh --list              # See what's running
  ./agent.sh --attach xxx        # Reconnect to existing
  ./agent.sh --kill xxx          # Clean up when done
EOF
    exit 0
}

# Detect if we need sudo for virsh
VIRSH="virsh"
detect_virsh() {
    if virsh list &>/dev/null; then
        VIRSH="virsh"
    elif sudo -n virsh list &>/dev/null 2>&1; then
        VIRSH="sudo virsh"
    else
        VIRSH="virsh"
    fi
}

get_clone_ip() {
    local clone="$1"
    $VIRSH domifaddr "$clone" 2>/dev/null | grep -oE '192\.168\.[0-9]+\.[0-9]+' | head -1
}

find_clone() {
    local partial="$1"

    # If it's already a full name and exists, return it
    if $VIRSH dominfo "$partial" &>/dev/null 2>&1; then
        echo "$partial"
        return 0
    fi

    # Try to find a match
    local match
    match=$($VIRSH list --all --name 2>/dev/null | grep -E "(^|-)${partial}" | head -1)
    if [[ -n "$match" ]]; then
        echo "$match"
        return 0
    fi

    return 1
}

wait_for_ssh() {
    local ip="$1"
    local timeout="$2"
    local start
    start=$(date +%s)

    while true; do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
               "${VM_USER}@${ip}" "true" 2>/dev/null; then
            return 0
        fi

        local elapsed=$(($(date +%s) - start))
        if [[ $elapsed -ge $timeout ]]; then
            return 1
        fi

        printf "\r  Waiting for SSH... %ds / %ds" "$elapsed" "$timeout"
        sleep 5
    done
}

cmd_list() {
    detect_virsh

    echo ""
    log_step "Running moltdown clones:"
    echo ""

    local found=0
    while IFS= read -r vm; do
        [[ -z "$vm" ]] && continue
        local ip state
        ip=$(get_clone_ip "$vm")
        state=$($VIRSH domstate "$vm" 2>/dev/null)
        if [[ "$state" == "running" ]]; then
            printf "  ${GREEN}%-45s${NC}  %-8s  %s\n" "$vm" "$state" "${ip:-waiting...}"
            found=1
        fi
    done < <($VIRSH list --all --name 2>/dev/null | grep "^moltdown-clone")

    [[ $found -eq 0 ]] && echo "  (no running clones)"

    echo ""
    log_step "Stopped clones:"
    echo ""

    found=0
    while IFS= read -r vm; do
        [[ -z "$vm" ]] && continue
        local state
        state=$($VIRSH domstate "$vm" 2>/dev/null)
        if [[ "$state" != "running" ]]; then
            printf "  ${YELLOW}%-45s${NC}  %s\n" "$vm" "$state"
            found=1
        fi
    done < <($VIRSH list --all --name 2>/dev/null | grep "^moltdown-clone")

    [[ $found -eq 0 ]] && echo "  (no stopped clones)"
    echo ""
}

cmd_attach() {
    local input="$1"
    detect_virsh

    if [[ -z "$input" ]]; then
        # Find most recent running clone
        input=$($VIRSH list --name 2>/dev/null | grep "^moltdown-clone" | head -1)
        if [[ -z "$input" ]]; then
            log_error "No running clones. Run ./agent.sh to create one."
            exit 1
        fi
        log_info "Attaching to most recent: $input"
    fi

    local clone
    clone=$(find_clone "$input") || {
        log_error "Clone not found: $input"
        log_info "Run './agent.sh --list' to see available clones"
        exit 1
    }

    # Start if not running
    local state
    state=$($VIRSH domstate "$clone" 2>/dev/null)
    if [[ "$state" != "running" ]]; then
        log_info "Starting $clone..."
        $VIRSH start "$clone" >/dev/null
        sleep 10
    fi

    # Get IP
    log_info "Getting IP for $clone..."
    local ip=""
    for _ in {1..30}; do
        ip=$(get_clone_ip "$clone")
        [[ -n "$ip" ]] && break
        sleep 2
    done

    if [[ -z "$ip" ]]; then
        log_error "Could not get IP for $clone"
        exit 1
    fi

    log_info "Waiting for SSH on $ip..."
    if ! wait_for_ssh "$ip" "$SSH_TIMEOUT"; then
        echo ""
        log_error "SSH timeout. VM may still be booting."
        log_info "Try: ssh ${VM_USER}@${ip}"
        exit 1
    fi
    echo ""

    log_info "Connecting to $clone ($ip)..."
    exec ssh -o StrictHostKeyChecking=no "${VM_USER}@${ip}"
}

cmd_stop() {
    local input="$1"
    detect_virsh

    [[ -z "$input" ]] && { log_error "Usage: ./agent.sh --stop <clone-name>"; exit 1; }

    local clone
    clone=$(find_clone "$input") || {
        log_error "Clone not found: $input"
        exit 1
    }

    log_info "Stopping $clone..."
    $VIRSH shutdown "$clone" 2>/dev/null || $VIRSH destroy "$clone" 2>/dev/null || true
    log_info "Stopped."
}

cmd_kill() {
    local input="$1"
    detect_virsh

    [[ -z "$input" ]] && { log_error "Usage: ./agent.sh --kill <clone-name>"; exit 1; }

    local clone
    clone=$(find_clone "$input") || {
        log_error "Clone not found: $input"
        exit 1
    }

    log_info "Deleting $clone..."
    $VIRSH destroy "$clone" 2>/dev/null || true
    "$SCRIPT_DIR/clone_manager.sh" delete "$clone" 2>/dev/null || {
        # Manual cleanup if clone_manager fails
        $VIRSH undefine "$clone" --remove-all-storage 2>/dev/null || true
    }
    log_info "Deleted."
}

cmd_gui() {
    local input="${1:-}"
    detect_virsh

    if [[ -z "$input" ]]; then
        input=$($VIRSH list --name 2>/dev/null | grep "^moltdown-clone" | head -1)
        [[ -z "$input" ]] && { log_error "No running clones."; exit 1; }
    fi

    local clone
    clone=$(find_clone "$input") || {
        log_error "Clone not found: $input"
        exit 1
    }

    log_info "Opening GUI for $clone..."
    virt-viewer "$clone" &
}

cmd_health() {
    local input="${1:-}"
    detect_virsh

    if [[ -z "$input" ]]; then
        input=$($VIRSH list --name 2>/dev/null | grep "^moltdown-clone" | head -1)
        [[ -z "$input" ]] && { log_error "No running clones."; exit 1; }
    fi

    local clone
    clone=$(find_clone "$input") || {
        log_error "Clone not found: $input"
        exit 1
    }

    local ip
    ip=$(get_clone_ip "$clone")
    [[ -z "$ip" ]] && { log_error "Could not get IP for $clone"; exit 1; }

    log_step "Health check for $clone ($ip)"
    echo ""

    ssh -o StrictHostKeyChecking=no -o BatchMode=yes "${VM_USER}@${ip}" << 'EOF'
echo "Claude:  $(claude --version 2>/dev/null | head -1 || echo '✗ not found')"
echo "Codex:   $(codex --version 2>/dev/null || echo '✗ not found')"
echo "Gemini:  $(gemini --version 2>/dev/null || echo '✗ not found')"
echo "GitHub:  $(gh auth status &>/dev/null && echo '✓ authenticated' || echo '✗ not authenticated')"
echo "Git:     $(git config user.name 2>/dev/null || echo '✗ not configured') <$(git config user.email 2>/dev/null || echo 'no email')>"
echo "Signing: $(git config gpg.format 2>/dev/null || echo 'gpg') key=$(git config user.signingkey 2>/dev/null | head -c 20 || echo 'none')..."
EOF
}

cmd_new() {
    detect_virsh

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}            🦀 moltdown - Spinning up Agent VM                     ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    log_step "Creating new agent VM from $GOLDEN_VM"

    # Create clone
    log_info "Creating linked clone..."
    local output
    output=$("$SCRIPT_DIR/clone_manager.sh" create "$GOLDEN_VM" --linked 2>&1) || {
        log_error "Failed to create clone"
        echo "$output"
        exit 1
    }

    local clone
    clone=$(echo "$output" | grep -oE 'moltdown-clone-[^ ]+' | head -1)

    if [[ -z "$clone" ]]; then
        log_error "Failed to parse clone name"
        echo "$output"
        exit 1
    fi

    log_info "Clone: $clone"

    # Start clone
    log_info "Starting..."
    "$SCRIPT_DIR/clone_manager.sh" start "$clone" >/dev/null 2>&1 || $VIRSH start "$clone" >/dev/null 2>&1

    # Wait for IP
    log_info "Waiting for network..."
    local ip=""
    for _ in {1..60}; do
        ip=$(get_clone_ip "$clone")
        [[ -n "$ip" ]] && break
        sleep 2
    done

    if [[ -z "$ip" ]]; then
        log_error "Timeout waiting for IP"
        log_info "Clone created but may still be booting: $clone"
        exit 1
    fi

    log_info "IP: $ip"

    # Wait for SSH
    log_info "Waiting for SSH..."
    if ! wait_for_ssh "$ip" "$SSH_TIMEOUT"; then
        echo ""
        log_error "SSH timeout"
        log_info "VM may still be booting. Try: ssh ${VM_USER}@${ip}"
        exit 1
    fi
    echo ""

    # Quick health check
    log_info "Running health check..."
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes "${VM_USER}@${ip}" << 'EOF' 2>/dev/null || true
echo -n "  Claude: " && (claude --version 2>/dev/null | head -1 || echo "✗")
echo -n "  GitHub: " && (gh auth status &>/dev/null && echo "✓" || echo "✗")
EOF

    # Show quick reference
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  🦀 Agent VM Ready!                                               ${GREEN}║${NC}"
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════════╣${NC}"
    printf "${GREEN}║${NC}  %-65s ${GREEN}║${NC}\n" "SSH:  ssh ${VM_USER}@${ip}"
    printf "${GREEN}║${NC}  %-65s ${GREEN}║${NC}\n" "GUI:  virt-viewer $clone"
    printf "${GREEN}║${NC}  %-65s ${GREEN}║${NC}\n" "Stop: ./agent.sh --stop $clone"
    printf "${GREEN}║${NC}  %-65s ${GREEN}║${NC}\n" "Kill: ./agent.sh --kill $clone"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Connect
    log_info "Connecting..."
    exec ssh -o StrictHostKeyChecking=no "${VM_USER}@${ip}"
}

# Parse arguments
case "${1:-}" in
    -h|--help)
        show_help
        ;;
    -l|--list)
        cmd_list
        ;;
    -a|--attach)
        cmd_attach "${2:-}"
        ;;
    -s|--stop)
        cmd_stop "${2:-}"
        ;;
    -k|--kill)
        cmd_kill "${2:-}"
        ;;
    -g|--gui)
        cmd_gui "${2:-}"
        ;;
    --health)
        cmd_health "${2:-}"
        ;;
    "")
        cmd_new
        ;;
    *)
        # If arg looks like a clone name, attach to it
        if [[ "$1" == moltdown-* ]]; then
            cmd_attach "$1"
        else
            # Try to find it as a partial match
            detect_virsh
            if $VIRSH list --all --name 2>/dev/null | grep -q "$1"; then
                cmd_attach "$1"
            else
                log_error "Unknown option: $1"
                log_info "Run './agent.sh --help' for usage"
                exit 1
            fi
        fi
        ;;
esac
