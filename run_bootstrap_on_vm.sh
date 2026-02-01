#!/usr/bin/env bash
#===============================================================================
# run_bootstrap_on_vm.sh - Push and execute bootstrap script on VM via SSH
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
#
# Purpose: Automate the process of copying the bootstrap script to a VM and
#          running it remotely. Reduces manual steps and clicking.
#
# Usage:   ./run_bootstrap_on_vm.sh <vm_ip> [vm_user] [--copy-ssh-key]
#
# License: MIT
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/guest/bootstrap_agent_vm.sh"
readonly SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

#-------------------------------------------------------------------------------
# Functions
#-------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") <vm_ip> [vm_user] [options]

Arguments:
    vm_ip       IP address of the VM
    vm_user     Username on the VM (default: \$USER)

Options:
    --copy-ssh-key    Copy local SSH public key to VM before bootstrap
    --dry-run         Show what would be done without executing
    -h, --help        Show this help message

Examples:
    $(basename "$0") 192.168.122.100
    $(basename "$0") 192.168.122.100 ubuntu --copy-ssh-key
    $(basename "$0") 192.168.122.100 ubuntu --dry-run

EOF
    exit "${1:-0}"
}

log_info()  { echo "[INFO]  $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_cmd()   { echo "[CMD]   $*"; }

check_prerequisites() {
    if [[ ! -f "$BOOTSTRAP_SCRIPT" ]]; then
        log_error "Bootstrap script not found: $BOOTSTRAP_SCRIPT"
        log_error "Expected directory structure:"
        log_error "  $(dirname "$SCRIPT_DIR")/"
        log_error "  ├── run_bootstrap_on_vm.sh"
        log_error "  └── guest/"
        log_error "      └── bootstrap_agent_vm.sh"
        exit 1
    fi
    
    if ! command -v ssh &>/dev/null; then
        log_error "ssh command not found"
        exit 1
    fi
    
    if ! command -v scp &>/dev/null; then
        log_error "scp command not found"
        exit 1
    fi
}

wait_for_ssh() {
    local host="$1"
    local user="$2"
    local max_attempts=30
    local attempt=1
    
    log_info "Waiting for SSH to become available on $host..."
    
    while [[ $attempt -le $max_attempts ]]; do
        if ssh $SSH_OPTS -o BatchMode=yes "$user@$host" "exit 0" 2>/dev/null; then
            log_info "SSH is available"
            return 0
        fi
        echo -n "."
        sleep 2
        ((attempt++))
    done
    
    echo ""
    log_error "SSH not available after $max_attempts attempts"
    return 1
}

copy_ssh_key() {
    local host="$1"
    local user="$2"
    
    local pubkey=""
    for key in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
        if [[ -f "$key" ]]; then
            pubkey="$key"
            break
        fi
    done
    
    if [[ -z "$pubkey" ]]; then
        log_error "No SSH public key found in ~/.ssh/"
        log_error "Generate one with: ssh-keygen -t ed25519"
        exit 1
    fi
    
    log_info "Copying SSH public key to VM..."
    log_cmd "ssh-copy-id -i $pubkey $user@$host"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        return 0
    fi
    
    ssh-copy-id -i "$pubkey" "$user@$host"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    local vm_ip=""
    local vm_user="$USER"
    local copy_key="false"
    DRY_RUN="false"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage 0
                ;;
            --copy-ssh-key)
                copy_key="true"
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                usage 1
                ;;
            *)
                if [[ -z "$vm_ip" ]]; then
                    vm_ip="$1"
                elif [[ "$vm_user" == "$USER" ]]; then
                    vm_user="$1"
                else
                    log_error "Too many arguments"
                    usage 1
                fi
                shift
                ;;
        esac
    done
    
    if [[ -z "$vm_ip" ]]; then
        log_error "VM IP address is required"
        usage 1
    fi
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║              🦀 moltdown - Remote Bootstrap                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    log_info "VM IP: $vm_ip"
    log_info "VM User: $vm_user"
    log_info "Dry Run: $DRY_RUN"
    echo ""
    
    check_prerequisites
    
    # Copy SSH key if requested
    if [[ "$copy_key" == "true" ]]; then
        copy_ssh_key "$vm_ip" "$vm_user"
    fi
    
    # Wait for SSH
    if [[ "$DRY_RUN" != "true" ]]; then
        wait_for_ssh "$vm_ip" "$vm_user"
    fi
    
    # Copy bootstrap script
    log_info "Copying bootstrap script to VM..."
    log_cmd "scp $BOOTSTRAP_SCRIPT $vm_user@$vm_ip:~/bootstrap_agent_vm.sh"
    
    if [[ "$DRY_RUN" != "true" ]]; then
        scp $SSH_OPTS "$BOOTSTRAP_SCRIPT" "$vm_user@$vm_ip:~/bootstrap_agent_vm.sh"
    fi
    
    # Execute bootstrap
    log_info "Executing bootstrap script on VM..."
    log_cmd "ssh $vm_user@$vm_ip 'chmod +x ~/bootstrap_agent_vm.sh && ~/bootstrap_agent_vm.sh'"
    
    if [[ "$DRY_RUN" != "true" ]]; then
        ssh $SSH_OPTS -t "$vm_user@$vm_ip" "chmod +x ~/bootstrap_agent_vm.sh && ~/bootstrap_agent_vm.sh"
    fi
    
    echo ""
    log_info "Bootstrap execution complete!"
    log_info ""
    log_info "Next steps on the VM:"
    log_info "  1) gh auth login"
    log_info "  2) sudo shutdown -h now"
    log_info ""
    log_info "Then on this host:"
    log_info "  ./snapshot_manager.sh create <vm-name> dev-ready"
    echo ""
}

main "$@"
