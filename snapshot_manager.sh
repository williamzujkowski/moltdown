#!/usr/bin/env bash
#===============================================================================
# snapshot_manager.sh - VM Snapshot Management for Agent Workflows
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
#
# Purpose: Manage libvirt/virsh snapshots for agent VM golden image workflow.
#          Provides create, revert, list, delete, and pre-agent-run operations.
#
# Usage:   ./snapshot_manager.sh <command> <vm_name> [snapshot_name] [options]
#
# License: MIT
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"

# Default snapshot names
readonly SNAP_OS_CLEAN="os-clean"
readonly SNAP_DEV_READY="dev-ready"

#-------------------------------------------------------------------------------
# Functions
#-------------------------------------------------------------------------------
usage() {
    cat <<EOF
Snapshot Manager v${SCRIPT_VERSION} - VM Snapshot Management for Agent Workflows

Usage: $(basename "$0") <command> <vm_name> [snapshot_name] [options]

Commands:
    create <vm> <name> [desc]   Create a new snapshot
    revert <vm> <name>          Revert to a snapshot (starts VM)
    delete <vm> <name>          Delete a snapshot
    list <vm>                   List all snapshots for a VM
    info <vm> <name>            Show snapshot details
    
    pre-run <vm>                Create timestamped snapshot before agent run
    post-run <vm>               Revert to dev-ready after agent run
    golden <vm>                 Create both os-clean and dev-ready snapshots
    
    vms                         List all VMs

Options:
    --offline                   Create snapshot with VM shut down (recommended)
    --no-start                  Don't start VM after revert
    -h, --help                  Show this help message

Examples:
    $(basename "$0") list ubuntu2404-agent
    $(basename "$0") create ubuntu2404-agent os-clean "Fresh install"
    $(basename "$0") revert ubuntu2404-agent dev-ready
    $(basename "$0") pre-run ubuntu2404-agent
    $(basename "$0") post-run ubuntu2404-agent

Golden Image Workflow:
    1. Install Ubuntu 24.04 Desktop in VM
    2. $(basename "$0") create <vm> os-clean --offline
    3. Run bootstrap_agent_vm.sh in VM
    4. Complete gh auth login
    5. $(basename "$0") create <vm> dev-ready --offline
    
Agent Run Workflow:
    1. $(basename "$0") pre-run <vm>          # Creates timestamped snapshot
    2. Do agent work...
    3. Export artifacts from VM
    4. $(basename "$0") post-run <vm>         # Reverts to dev-ready

EOF
    exit "${1:-0}"
}

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_cmd()   { echo "[CMD]   sudo virsh $*"; }

#-------------------------------------------------------------------------------
# Validation
#-------------------------------------------------------------------------------
check_prerequisites() {
    if ! command -v virsh &>/dev/null; then
        log_error "virsh command not found. Install libvirt-clients."
        exit 1
    fi
    
    if ! sudo virsh list --all &>/dev/null; then
        log_error "Cannot connect to libvirt. Check permissions and libvirtd service."
        exit 1
    fi
}

validate_vm_exists() {
    local vm="$1"
    if ! sudo virsh dominfo "$vm" &>/dev/null; then
        log_error "VM '$vm' not found"
        log_info "Available VMs:"
        sudo virsh list --all --name | grep -v '^$' | sed 's/^/  /'
        exit 1
    fi
}

validate_snapshot_exists() {
    local vm="$1"
    local snap="$2"
    if ! sudo virsh snapshot-info "$vm" "$snap" &>/dev/null; then
        log_error "Snapshot '$snap' not found for VM '$vm'"
        log_info "Available snapshots:"
        sudo virsh snapshot-list "$vm" --name | grep -v '^$' | sed 's/^/  /'
        exit 1
    fi
}

get_vm_state() {
    local vm="$1"
    sudo virsh domstate "$vm" 2>/dev/null | tr -d '[:space:]'
}

#-------------------------------------------------------------------------------
# Commands
#-------------------------------------------------------------------------------
cmd_list_vms() {
    log_info "Available VMs:"
    echo ""
    sudo virsh list --all
}

cmd_list_snapshots() {
    local vm="$1"
    validate_vm_exists "$vm"
    
    log_info "Snapshots for VM '$vm':"
    echo ""
    sudo virsh snapshot-list "$vm" --tree
    echo ""
    
    # Show current snapshot
    local current
    current=$(sudo virsh snapshot-current "$vm" --name 2>/dev/null || echo "none")
    log_info "Current snapshot: $current"
}

cmd_snapshot_info() {
    local vm="$1"
    local snap="$2"
    
    validate_vm_exists "$vm"
    validate_snapshot_exists "$vm" "$snap"
    
    sudo virsh snapshot-info "$vm" "$snap"
}

cmd_create_snapshot() {
    local vm="$1"
    local snap="$2"
    local desc="${3:-Snapshot created $(date -Is)}"
    local offline="${4:-false}"
    
    validate_vm_exists "$vm"
    
    local state
    state=$(get_vm_state "$vm")
    
    if [[ "$offline" == "true" && "$state" == "running" ]]; then
        log_warn "VM is running. Shutting down for clean snapshot..."
        sudo virsh shutdown "$vm"
        
        # Wait for shutdown
        local timeout=60
        while [[ $timeout -gt 0 ]]; do
            state=$(get_vm_state "$vm")
            [[ "$state" != "running" ]] && break
            sleep 2
            ((timeout -= 2))
        done
        
        if [[ "$state" == "running" ]]; then
            log_error "VM did not shut down in time. Force shutdown? (y/n)"
            read -r response
            if [[ "$response" == "y" ]]; then
                sudo virsh destroy "$vm"
                sleep 2
            else
                exit 1
            fi
        fi
    fi
    
    state=$(get_vm_state "$vm")
    if [[ "$state" == "running" ]]; then
        log_warn "Creating live snapshot (VM is running)"
        log_warn "For consistency, consider using --offline flag"
    else
        log_info "Creating offline snapshot (recommended)"
    fi
    
    log_cmd "snapshot-create-as $vm $snap --description \"$desc\" --atomic"
    sudo virsh snapshot-create-as "$vm" "$snap" \
        --description "$desc" \
        --atomic
    
    log_info "Snapshot '$snap' created successfully"
    
    # Show snapshot list
    echo ""
    cmd_list_snapshots "$vm"
}

cmd_revert_snapshot() {
    local vm="$1"
    local snap="$2"
    local start="${3:-true}"
    
    validate_vm_exists "$vm"
    validate_snapshot_exists "$vm" "$snap"
    
    local state
    state=$(get_vm_state "$vm")
    
    if [[ "$state" == "running" ]]; then
        log_info "Stopping VM before revert..."
        sudo virsh destroy "$vm" 2>/dev/null || true
        sleep 2
    fi
    
    log_cmd "snapshot-revert $vm $snap"
    sudo virsh snapshot-revert "$vm" "$snap"
    
    log_info "Reverted to snapshot '$snap'"
    
    if [[ "$start" == "true" ]]; then
        log_info "Starting VM..."
        sudo virsh start "$vm"
        log_info "VM started. Waiting for boot..."
        sleep 5
        
        # Try to get IP
        local ip
        ip=$(sudo virsh domifaddr "$vm" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1)
        if [[ -n "$ip" ]]; then
            log_info "VM IP: $ip"
            log_info "SSH: ssh $(whoami)@$ip"
        fi
    fi
}

cmd_delete_snapshot() {
    local vm="$1"
    local snap="$2"
    
    validate_vm_exists "$vm"
    validate_snapshot_exists "$vm" "$snap"
    
    # Safety check for golden snapshots
    if [[ "$snap" == "$SNAP_OS_CLEAN" || "$snap" == "$SNAP_DEV_READY" ]]; then
        log_warn "You are about to delete a golden snapshot: $snap"
        echo -n "Are you sure? (yes/no): "
        read -r response
        if [[ "$response" != "yes" ]]; then
            log_info "Aborted"
            exit 0
        fi
    fi
    
    log_cmd "snapshot-delete $vm $snap"
    sudo virsh snapshot-delete "$vm" "$snap"
    
    log_info "Snapshot '$snap' deleted"
}

cmd_pre_run() {
    local vm="$1"
    local snap="pre-run-$(date +%Y%m%d_%H%M%S)"
    
    validate_vm_exists "$vm"
    
    log_info "Creating pre-agent-run snapshot..."
    cmd_create_snapshot "$vm" "$snap" "Pre-agent-run snapshot" "false"
    
    echo ""
    log_info "Ready for agent run!"
    log_info "After completion, revert with:"
    log_info "  $(basename "$0") post-run $vm"
    log_info ""
    log_info "Or to revert to this specific snapshot:"
    log_info "  $(basename "$0") revert $vm $snap"
}

cmd_post_run() {
    local vm="$1"
    
    validate_vm_exists "$vm"
    
    # Check if dev-ready exists
    if ! sudo virsh snapshot-info "$vm" "$SNAP_DEV_READY" &>/dev/null; then
        log_error "Golden snapshot '$SNAP_DEV_READY' not found"
        log_error "Create it first with: $(basename "$0") create $vm $SNAP_DEV_READY --offline"
        exit 1
    fi
    
    log_warn "This will revert to '$SNAP_DEV_READY' and discard current state!"
    echo -n "Continue? (y/n): "
    read -r response
    if [[ "$response" != "y" ]]; then
        log_info "Aborted"
        exit 0
    fi
    
    cmd_revert_snapshot "$vm" "$SNAP_DEV_READY" "true"
}

cmd_golden() {
    local vm="$1"
    
    validate_vm_exists "$vm"
    
    echo ""
    log_info "Golden Image Snapshot Creator"
    log_info "=============================="
    echo ""
    log_info "This will guide you through creating golden snapshots."
    echo ""
    
    # Check current state
    local state
    state=$(get_vm_state "$vm")
    log_info "VM state: $state"
    
    # os-clean snapshot
    if sudo virsh snapshot-info "$vm" "$SNAP_OS_CLEAN" &>/dev/null; then
        log_warn "Snapshot '$SNAP_OS_CLEAN' already exists"
        echo -n "Skip os-clean? (y/n): "
        read -r response
        if [[ "$response" != "y" ]]; then
            cmd_delete_snapshot "$vm" "$SNAP_OS_CLEAN"
            cmd_create_snapshot "$vm" "$SNAP_OS_CLEAN" "Ubuntu 24.04 Desktop - fresh install + updates" "true"
        fi
    else
        echo -n "Create '$SNAP_OS_CLEAN' snapshot now? (y/n): "
        read -r response
        if [[ "$response" == "y" ]]; then
            cmd_create_snapshot "$vm" "$SNAP_OS_CLEAN" "Ubuntu 24.04 Desktop - fresh install + updates" "true"
        fi
    fi
    
    echo ""
    log_info "Now run the bootstrap script in the VM:"
    log_info "  1. Start the VM"
    log_info "  2. Run: ./bootstrap_agent_vm.sh"
    log_info "  3. Run: gh auth login"
    log_info "  4. Shut down the VM"
    echo ""
    echo -n "Press Enter when ready to create '$SNAP_DEV_READY' snapshot..."
    read -r
    
    # dev-ready snapshot
    state=$(get_vm_state "$vm")
    if [[ "$state" == "running" ]]; then
        log_warn "VM should be shut down for dev-ready snapshot"
        echo -n "Shut down now? (y/n): "
        read -r response
        if [[ "$response" == "y" ]]; then
            sudo virsh shutdown "$vm"
            sleep 10
        fi
    fi
    
    if sudo virsh snapshot-info "$vm" "$SNAP_DEV_READY" &>/dev/null; then
        log_warn "Snapshot '$SNAP_DEV_READY' already exists"
        echo -n "Replace it? (y/n): "
        read -r response
        if [[ "$response" == "y" ]]; then
            cmd_delete_snapshot "$vm" "$SNAP_DEV_READY"
        else
            log_info "Keeping existing snapshot"
            return
        fi
    fi
    
    cmd_create_snapshot "$vm" "$SNAP_DEV_READY" "Chrome + gh + dev tools + baseline tuning" "true"
    
    echo ""
    log_info "Golden image creation complete!"
    log_info ""
    log_info "Your agent workflow:"
    log_info "  1. $(basename "$0") pre-run $vm    # Before each agent run"
    log_info "  2. Do agent work..."
    log_info "  3. Export artifacts"
    log_info "  4. $(basename "$0") post-run $vm   # Reset to clean state"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    local cmd="${1:-}"
    local vm="${2:-}"
    local snap="${3:-}"
    local desc="${4:-}"
    local offline="false"
    local no_start="false"
    
    # Parse global options
    for arg in "$@"; do
        case "$arg" in
            --offline) offline="true" ;;
            --no-start) no_start="true" ;;
            -h|--help) usage 0 ;;
        esac
    done
    
    check_prerequisites
    
    case "$cmd" in
        vms)
            cmd_list_vms
            ;;
        list)
            [[ -z "$vm" ]] && { log_error "VM name required"; usage 1; }
            cmd_list_snapshots "$vm"
            ;;
        info)
            [[ -z "$vm" ]] && { log_error "VM name required"; usage 1; }
            [[ -z "$snap" ]] && { log_error "Snapshot name required"; usage 1; }
            cmd_snapshot_info "$vm" "$snap"
            ;;
        create)
            [[ -z "$vm" ]] && { log_error "VM name required"; usage 1; }
            [[ -z "$snap" ]] && { log_error "Snapshot name required"; usage 1; }
            cmd_create_snapshot "$vm" "$snap" "$desc" "$offline"
            ;;
        revert)
            [[ -z "$vm" ]] && { log_error "VM name required"; usage 1; }
            [[ -z "$snap" ]] && { log_error "Snapshot name required"; usage 1; }
            local start="true"
            [[ "$no_start" == "true" ]] && start="false"
            cmd_revert_snapshot "$vm" "$snap" "$start"
            ;;
        delete)
            [[ -z "$vm" ]] && { log_error "VM name required"; usage 1; }
            [[ -z "$snap" ]] && { log_error "Snapshot name required"; usage 1; }
            cmd_delete_snapshot "$vm" "$snap"
            ;;
        pre-run)
            [[ -z "$vm" ]] && { log_error "VM name required"; usage 1; }
            cmd_pre_run "$vm"
            ;;
        post-run)
            [[ -z "$vm" ]] && { log_error "VM name required"; usage 1; }
            cmd_post_run "$vm"
            ;;
        golden)
            [[ -z "$vm" ]] && { log_error "VM name required"; usage 1; }
            cmd_golden "$vm"
            ;;
        "")
            usage 0
            ;;
        *)
            log_error "Unknown command: $cmd"
            usage 1
            ;;
    esac
}

main "$@"
