#!/usr/bin/env bash
#===============================================================================
# clone_manager.sh - Manage VM clones for parallel agent workflows
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
#
# Purpose: Create and manage VM clones for running multiple agents in parallel.
#          Supports both full clones and linked clones (copy-on-write).
#
# Usage:   ./clone_manager.sh <command> [options]
#
# Commands:
#   create <source-vm> [clone-name]   Create a clone from source VM
#   list [source-vm]                  List clones (optionally filter by source)
#   delete <clone-name>               Delete a specific clone
#   cleanup <source-vm>               Delete all clones of a source VM
#   start <clone-name>                Start a clone
#   stop <clone-name>                 Stop a clone gracefully
#   status [clone-name]               Show clone status and IPs
#
# Options:
#   --linked                          Use linked clone (faster, less disk space)
#   --vcpus N                         Override vCPUs for clone
#   --memory N                        Override memory (MB) for clone
#   --dry-run                         Show what would be done
#
# License: MIT
#===============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly CLONE_PREFIX="moltdown-clone"
readonly LIBVIRT_IMAGES="/var/lib/libvirt/images"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

#-------------------------------------------------------------------------------
# Logging Functions
#-------------------------------------------------------------------------------
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------
check_virsh() {
    if ! command -v virsh &>/dev/null; then
        log_error "virsh not found. Install with: sudo apt install libvirt-clients"
        exit 1
    fi
}

check_virt_clone() {
    if ! command -v virt-clone &>/dev/null; then
        log_error "virt-clone not found. Install with: sudo apt install virtinst"
        exit 1
    fi
}

vm_exists() {
    local vm_name="$1"
    sudo virsh dominfo "$vm_name" &>/dev/null
}

vm_is_running() {
    local vm_name="$1"
    local state
    state=$(sudo virsh domstate "$vm_name" 2>/dev/null || echo "unknown")
    [[ "$state" == "running" ]]
}

get_vm_disk() {
    local vm_name="$1"
    sudo virsh domblklist "$vm_name" --details 2>/dev/null | \
        awk '/disk/{print $4}' | head -1
}

generate_clone_name() {
    local source_vm="$1"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    echo "${CLONE_PREFIX}-${source_vm}-${timestamp}"
}

is_clone() {
    local vm_name="$1"
    [[ "$vm_name" == ${CLONE_PREFIX}* ]]
}

get_source_vm_from_clone() {
    local clone_name="$1"
    # Extract source VM name from clone name: moltdown-clone-<source>-<timestamp>
    echo "$clone_name" | sed "s/^${CLONE_PREFIX}-//" | sed 's/-[0-9]\{8\}-[0-9]\{6\}$//'
}

#-------------------------------------------------------------------------------
# Command: create
#-------------------------------------------------------------------------------
cmd_create() {
    local source_vm=""
    local clone_name=""
    local linked=false
    local vcpus=""
    local memory=""
    local dry_run=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --linked)
                linked=true
                shift
                ;;
            --vcpus)
                vcpus="$2"
                shift 2
                ;;
            --memory)
                memory="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                exit 1
                ;;
            *)
                if [[ -z "$source_vm" ]]; then
                    source_vm="$1"
                elif [[ -z "$clone_name" ]]; then
                    clone_name="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$source_vm" ]]; then
        log_error "Usage: $SCRIPT_NAME create <source-vm> [clone-name] [--linked] [--vcpus N] [--memory N]"
        exit 1
    fi

    # Generate clone name if not provided
    if [[ -z "$clone_name" ]]; then
        clone_name=$(generate_clone_name "$source_vm")
    fi

    # Verify source VM exists
    if ! vm_exists "$source_vm"; then
        log_error "Source VM '$source_vm' not found"
        exit 1
    fi

    # Check if clone already exists
    if vm_exists "$clone_name"; then
        log_error "Clone '$clone_name' already exists"
        exit 1
    fi

    # Get source disk
    local source_disk
    source_disk=$(get_vm_disk "$source_vm")
    if [[ -z "$source_disk" ]]; then
        log_error "Could not find disk for VM '$source_vm'"
        exit 1
    fi

    local clone_disk="${LIBVIRT_IMAGES}/${clone_name}.qcow2"

    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║            🦀 moltdown - Clone Creation                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    log_info "Source VM:    $source_vm"
    log_info "Clone name:   $clone_name"
    log_info "Source disk:  $source_disk"
    log_info "Clone disk:   $clone_disk"
    log_info "Clone type:   $(if $linked; then echo 'Linked (copy-on-write)'; else echo 'Full copy'; fi)"
    echo ""

    if $dry_run; then
        log_warn "Dry run mode - no changes will be made"
        echo ""
    fi

    # Check if source VM is running (must be stopped for clean clone)
    if vm_is_running "$source_vm"; then
        log_warn "Source VM is running. For best results, stop it first:"
        log_warn "  sudo virsh shutdown $source_vm"
        echo ""
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted"
            exit 0
        fi
    fi

    if $dry_run; then
        log_step "Would create clone with virt-clone..."
        if $linked; then
            log_step "Would create linked disk with qemu-img create -b ..."
        fi
        return 0
    fi

    # Create the clone
    if $linked; then
        log_step "Creating linked clone disk..."

        # For linked clone, create a new disk backed by the source
        sudo qemu-img create -f qcow2 -b "$source_disk" -F qcow2 "$clone_disk"

        log_step "Creating VM definition from source..."
        # Use virt-clone with the pre-created disk
        sudo virt-clone \
            --original "$source_vm" \
            --name "$clone_name" \
            --preserve-data \
            --file "$clone_disk"
    else
        log_step "Creating full clone (this may take a while)..."
        sudo virt-clone \
            --original "$source_vm" \
            --name "$clone_name" \
            --file "$clone_disk"
    fi

    # Apply resource overrides if specified
    if [[ -n "$vcpus" ]]; then
        log_step "Setting vCPUs to $vcpus..."
        sudo virsh setvcpus "$clone_name" "$vcpus" --config --maximum
        sudo virsh setvcpus "$clone_name" "$vcpus" --config
    fi

    if [[ -n "$memory" ]]; then
        log_step "Setting memory to ${memory}MB..."
        sudo virsh setmaxmem "$clone_name" "${memory}M" --config
        sudo virsh setmem "$clone_name" "${memory}M" --config
    fi

    echo ""
    log_info "Clone '$clone_name' created successfully!"
    echo ""
    echo "Next steps:"
    echo "  Start:   sudo virsh start $clone_name"
    echo "  GUI:     virt-viewer $clone_name"
    echo "  SSH:     ssh agent@\$(sudo virsh domifaddr $clone_name | awk '/ipv4/{print \$4}' | cut -d/ -f1)"
    echo "  Delete:  $SCRIPT_NAME delete $clone_name"
}

#-------------------------------------------------------------------------------
# Command: list
#-------------------------------------------------------------------------------
cmd_list() {
    local filter_source=""

    if [[ $# -gt 0 ]]; then
        filter_source="$1"
    fi

    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║            🦀 moltdown - Clone List                               ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""

    local found=false
    local vm_list
    vm_list=$(sudo virsh list --all --name 2>/dev/null | grep "^${CLONE_PREFIX}" || true)

    if [[ -z "$vm_list" ]]; then
        log_info "No clones found"
        return 0
    fi

    printf "%-40s %-15s %-15s %s\n" "CLONE NAME" "STATE" "SOURCE VM" "DISK SIZE"
    printf "%-40s %-15s %-15s %s\n" "----------" "-----" "---------" "---------"

    while IFS= read -r clone_name; do
        [[ -z "$clone_name" ]] && continue

        local source_vm
        source_vm=$(get_source_vm_from_clone "$clone_name")

        # Filter by source if specified
        if [[ -n "$filter_source" && "$source_vm" != "$filter_source" ]]; then
            continue
        fi

        local state
        state=$(sudo virsh domstate "$clone_name" 2>/dev/null || echo "unknown")

        local disk_size="unknown"
        local disk_path
        disk_path=$(get_vm_disk "$clone_name")
        if [[ -n "$disk_path" && -f "$disk_path" ]]; then
            disk_size=$(du -h "$disk_path" 2>/dev/null | cut -f1)
        fi

        printf "%-40s %-15s %-15s %s\n" "$clone_name" "$state" "$source_vm" "$disk_size"
        found=true
    done <<< "$vm_list"

    if ! $found; then
        if [[ -n "$filter_source" ]]; then
            log_info "No clones found for source VM '$filter_source'"
        else
            log_info "No clones found"
        fi
    fi
}

#-------------------------------------------------------------------------------
# Command: delete
#-------------------------------------------------------------------------------
cmd_delete() {
    local clone_name="$1"
    local force=false

    if [[ -z "$clone_name" ]]; then
        log_error "Usage: $SCRIPT_NAME delete <clone-name>"
        exit 1
    fi

    if ! vm_exists "$clone_name"; then
        log_error "Clone '$clone_name' not found"
        exit 1
    fi

    # Safety check: only delete clones, not source VMs
    if ! is_clone "$clone_name"; then
        log_error "VM '$clone_name' is not a moltdown clone (doesn't start with '$CLONE_PREFIX')"
        log_error "Use 'sudo virsh undefine' directly if you really want to delete it"
        exit 1
    fi

    log_info "Deleting clone: $clone_name"

    # Stop if running
    if vm_is_running "$clone_name"; then
        log_step "Stopping clone..."
        sudo virsh destroy "$clone_name" 2>/dev/null || true
    fi

    # Get disk path before undefining
    local disk_path
    disk_path=$(get_vm_disk "$clone_name")

    # Undefine VM
    log_step "Removing VM definition..."
    sudo virsh undefine "$clone_name" --remove-all-storage 2>/dev/null || \
        sudo virsh undefine "$clone_name" 2>/dev/null

    # Remove disk if it still exists (belt and suspenders)
    if [[ -n "$disk_path" && -f "$disk_path" ]]; then
        log_step "Removing disk image..."
        sudo rm -f "$disk_path"
    fi

    log_info "Clone '$clone_name' deleted"
}

#-------------------------------------------------------------------------------
# Command: cleanup
#-------------------------------------------------------------------------------
cmd_cleanup() {
    local source_vm="$1"
    local dry_run=false

    if [[ "$source_vm" == "--dry-run" ]]; then
        dry_run=true
        source_vm="$2"
    fi

    if [[ -z "$source_vm" ]]; then
        log_error "Usage: $SCRIPT_NAME cleanup <source-vm> [--dry-run]"
        exit 1
    fi

    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║            🦀 moltdown - Clone Cleanup                            ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""

    local clones=()
    local vm_list
    vm_list=$(sudo virsh list --all --name 2>/dev/null | grep "^${CLONE_PREFIX}-${source_vm}-" || true)

    if [[ -z "$vm_list" ]]; then
        log_info "No clones found for source VM '$source_vm'"
        return 0
    fi

    while IFS= read -r clone_name; do
        [[ -z "$clone_name" ]] && continue
        clones+=("$clone_name")
    done <<< "$vm_list"

    log_info "Found ${#clones[@]} clone(s) to delete:"
    for clone in "${clones[@]}"; do
        echo "  - $clone"
    done
    echo ""

    if $dry_run; then
        log_warn "Dry run mode - no changes will be made"
        return 0
    fi

    read -p "Delete all ${#clones[@]} clones? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborted"
        return 0
    fi

    for clone in "${clones[@]}"; do
        cmd_delete "$clone"
    done

    log_info "Cleanup complete"
}

#-------------------------------------------------------------------------------
# Command: start
#-------------------------------------------------------------------------------
cmd_start() {
    local clone_name="$1"

    if [[ -z "$clone_name" ]]; then
        log_error "Usage: $SCRIPT_NAME start <clone-name>"
        exit 1
    fi

    if ! vm_exists "$clone_name"; then
        log_error "Clone '$clone_name' not found"
        exit 1
    fi

    if vm_is_running "$clone_name"; then
        log_warn "Clone '$clone_name' is already running"
        return 0
    fi

    log_info "Starting clone '$clone_name'..."
    sudo virsh start "$clone_name"

    log_info "Clone started. Waiting for IP..."
    sleep 5

    local ip
    ip=$(sudo virsh domifaddr "$clone_name" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1)
    if [[ -n "$ip" ]]; then
        log_info "Clone IP: $ip"
        echo ""
        echo "Connect with:"
        echo "  GUI: virt-viewer $clone_name"
        echo "  SSH: ssh agent@$ip"
    else
        log_warn "IP not yet available. Check with: sudo virsh domifaddr $clone_name"
    fi
}

#-------------------------------------------------------------------------------
# Command: stop
#-------------------------------------------------------------------------------
cmd_stop() {
    local clone_name="$1"
    local force=false

    if [[ "$clone_name" == "--force" || "$clone_name" == "-f" ]]; then
        force=true
        clone_name="$2"
    fi

    if [[ -z "$clone_name" ]]; then
        log_error "Usage: $SCRIPT_NAME stop <clone-name> [--force]"
        exit 1
    fi

    if ! vm_exists "$clone_name"; then
        log_error "Clone '$clone_name' not found"
        exit 1
    fi

    if ! vm_is_running "$clone_name"; then
        log_info "Clone '$clone_name' is not running"
        return 0
    fi

    if $force; then
        log_info "Force stopping clone '$clone_name'..."
        sudo virsh destroy "$clone_name"
    else
        log_info "Gracefully stopping clone '$clone_name'..."
        sudo virsh shutdown "$clone_name"
        log_info "Shutdown signal sent. Clone will stop shortly."
    fi
}

#-------------------------------------------------------------------------------
# Command: status
#-------------------------------------------------------------------------------
cmd_status() {
    local clone_name="${1:-}"

    if [[ -n "$clone_name" ]]; then
        # Status for specific clone
        if ! vm_exists "$clone_name"; then
            log_error "Clone '$clone_name' not found"
            exit 1
        fi

        echo "╔═══════════════════════════════════════════════════════════════════╗"
        echo "║            🦀 moltdown - Clone Status                             ║"
        echo "╚═══════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "Clone: $clone_name"
        echo ""

        local state
        state=$(sudo virsh domstate "$clone_name" 2>/dev/null || echo "unknown")
        echo "State:  $state"

        if [[ "$state" == "running" ]]; then
            local ip
            ip=$(sudo virsh domifaddr "$clone_name" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1)
            echo "IP:     ${ip:-pending...}"
        fi

        local disk_path
        disk_path=$(get_vm_disk "$clone_name")
        if [[ -n "$disk_path" ]]; then
            echo "Disk:   $disk_path"
            if [[ -f "$disk_path" ]]; then
                local disk_size
                disk_size=$(du -h "$disk_path" 2>/dev/null | cut -f1)
                echo "Size:   $disk_size"

                # Check if it's a linked clone
                local backing
                backing=$(qemu-img info "$disk_path" 2>/dev/null | grep "backing file:" | cut -d: -f2- | xargs)
                if [[ -n "$backing" ]]; then
                    echo "Type:   Linked clone"
                    echo "Backing: $backing"
                else
                    echo "Type:   Full clone"
                fi
            fi
        fi
    else
        # Status for all clones
        cmd_list
    fi
}

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
    cat << EOF
Usage: $SCRIPT_NAME <command> [options]

🦀 moltdown Clone Manager - Manage VM clones for parallel agent workflows

Commands:
  create <source-vm> [name]   Create a clone from source VM
  list [source-vm]            List clones (optionally filter by source)
  delete <clone-name>         Delete a specific clone
  cleanup <source-vm>         Delete all clones of a source VM
  start <clone-name>          Start a clone
  stop <clone-name>           Stop a clone gracefully
  status [clone-name]         Show clone status

Create Options:
  --linked                    Use linked clone (faster, less disk space)
  --vcpus N                   Override vCPUs for clone
  --memory N                  Override memory (MB) for clone
  --dry-run                   Show what would be done

Examples:
  # Create a full clone
  $SCRIPT_NAME create ubuntu2404-agent

  # Create a linked clone (instant, copy-on-write)
  $SCRIPT_NAME create ubuntu2404-agent --linked

  # Create clone with custom resources
  $SCRIPT_NAME create ubuntu2404-agent worker-1 --linked --vcpus 2 --memory 4096

  # List all clones
  $SCRIPT_NAME list

  # List clones of specific VM
  $SCRIPT_NAME list ubuntu2404-agent

  # Start a clone
  $SCRIPT_NAME start moltdown-clone-ubuntu2404-agent-20250201-143052

  # Delete a clone
  $SCRIPT_NAME delete moltdown-clone-ubuntu2404-agent-20250201-143052

  # Delete all clones of a VM
  $SCRIPT_NAME cleanup ubuntu2404-agent

Parallel Workflow:
  1. Create golden image:     ./snapshot_manager.sh golden ubuntu2404-agent
  2. Create clones:           $SCRIPT_NAME create ubuntu2404-agent --linked
                              $SCRIPT_NAME create ubuntu2404-agent --linked
  3. Start clones:            $SCRIPT_NAME start <clone1>
                              $SCRIPT_NAME start <clone2>
  4. Run agents in parallel
  5. Cleanup when done:       $SCRIPT_NAME cleanup ubuntu2404-agent

EOF
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 0
    fi

    local command="$1"
    shift

    check_virsh

    case "$command" in
        create)
            check_virt_clone
            cmd_create "$@"
            ;;
        list)
            cmd_list "$@"
            ;;
        delete)
            cmd_delete "$@"
            ;;
        cleanup)
            cmd_cleanup "$@"
            ;;
        start)
            cmd_start "$@"
            ;;
        stop)
            cmd_stop "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            log_error "Unknown command: $command"
            echo ""
            usage
            exit 1
            ;;
    esac
}

main "$@"
