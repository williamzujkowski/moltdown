#!/usr/bin/env bash
#===============================================================================
# virt_install_agent_vm.sh - Automated Ubuntu 24.04 Desktop VM Creation
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
#
# Purpose: Create a new Ubuntu 24.04 Desktop VM with automated installation
#          using cloud-init/autoinstall. Minimal to zero interaction required.
#
# Usage:   ./virt_install_agent_vm.sh [options]
#
# License: MIT
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"

# VM defaults
DEFAULT_VM_NAME="ubuntu2404-agent"
DEFAULT_VCPUS="4"
DEFAULT_MEMORY="16384"  # MB - 16GB needed for Claude CLI memory leaks
DEFAULT_DISK_SIZE="50" # GB
DEFAULT_DISK_PATH="/var/lib/libvirt/images"

# Ubuntu 24.04 ISO - update this path
DEFAULT_ISO_PATH="/var/lib/libvirt/images/ubuntu-24.04-desktop-amd64.iso"

# Network
DEFAULT_NETWORK="default"

#-------------------------------------------------------------------------------
# Functions
#-------------------------------------------------------------------------------
usage() {
    cat <<EOF
virt-install Agent VM Creator v${SCRIPT_VERSION}

Automated Ubuntu 24.04 Desktop VM creation with cloud-init autoinstall.

Usage: $(basename "$0") [options]

Options:
    --name NAME         VM name (default: ${DEFAULT_VM_NAME})
    --vcpus N           Number of vCPUs (default: ${DEFAULT_VCPUS})
    --memory MB         Memory in MB (default: ${DEFAULT_MEMORY})
    --disk-size GB      Disk size in GB (default: ${DEFAULT_DISK_SIZE})
    --disk-path PATH    Directory for disk image (default: ${DEFAULT_DISK_PATH})
    --iso PATH          Ubuntu ISO path (default: ${DEFAULT_ISO_PATH})
    --seed-iso PATH     Cloud-init seed ISO path
    --network NAME      Libvirt network (default: ${DEFAULT_NETWORK})
    --graphics TYPE     Graphics type: spice, vnc, none (default: spice)
    --dry-run           Show virt-install command without executing
    -h, --help          Show this help message

Examples:
    # Basic usage (generate seed ISO first)
    ./generate_nocloud_iso.sh --customize
    $(basename "$0") --seed-iso ./seed.iso

    # Full customization
    $(basename "$0") \\
        --name my-agent-vm \\
        --vcpus 8 \\
        --memory 16384 \\
        --disk-size 100 \\
        --seed-iso ./seed.iso

    # Dry run to see command
    $(basename "$0") --seed-iso ./seed.iso --dry-run

Workflow:
    1. Download Ubuntu 24.04 Desktop ISO
    2. ./generate_nocloud_iso.sh --customize
    3. $(basename "$0") --seed-iso ./seed.iso
    4. Wait for installation (~10-15 min)
    5. VM will reboot into desktop
    6. Run bootstrap_agent_vm.sh
    7. ./snapshot_manager.sh golden <vm-name>

EOF
    exit "${1:-0}"
}

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*"; }
log_error() { echo "[ERROR] $*" >&2; }

check_prerequisites() {
    local missing=()
    
    if ! command -v virt-install &>/dev/null; then
        missing+=("virt-install (virtinst package)")
    fi
    
    if ! command -v virsh &>/dev/null; then
        missing+=("virsh (libvirt-clients package)")
    fi
    
    if ! systemctl is-active --quiet libvirtd 2>/dev/null; then
        log_warn "libvirtd service may not be running"
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing prerequisites:"
        for pkg in "${missing[@]}"; do
            log_error "  - $pkg"
        done
        log_error ""
        log_error "Install with: sudo apt install virtinst libvirt-clients libvirt-daemon-system"
        exit 1
    fi
}

check_vm_exists() {
    local name="$1"
    if sudo virsh dominfo "$name" &>/dev/null; then
        return 0
    fi
    return 1
}

check_file_exists() {
    local path="$1"
    local desc="$2"
    if [[ ! -f "$path" ]]; then
        log_error "$desc not found: $path"
        return 1
    fi
    return 0
}

download_iso_prompt() {
    local iso_path="$1"
    
    log_warn "Ubuntu ISO not found at: $iso_path"
    echo ""
    echo "Download Ubuntu 24.04 Desktop:"
    echo "  https://releases.ubuntu.com/24.04/ubuntu-24.04-desktop-amd64.iso"
    echo ""
    echo "Or use wget:"
    echo "  sudo wget -P /var/lib/libvirt/images/ \\"
    echo "    https://releases.ubuntu.com/24.04/ubuntu-24.04-desktop-amd64.iso"
    echo ""
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    local vm_name="$DEFAULT_VM_NAME"
    local vcpus="$DEFAULT_VCPUS"
    local memory="$DEFAULT_MEMORY"
    local disk_size="$DEFAULT_DISK_SIZE"
    local disk_path="$DEFAULT_DISK_PATH"
    local iso_path="$DEFAULT_ISO_PATH"
    local seed_iso=""
    local network="$DEFAULT_NETWORK"
    local graphics="spice"
    local dry_run="false"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage 0
                ;;
            --name)
                vm_name="$2"
                shift 2
                ;;
            --vcpus)
                vcpus="$2"
                shift 2
                ;;
            --memory)
                memory="$2"
                shift 2
                ;;
            --disk-size)
                disk_size="$2"
                shift 2
                ;;
            --disk-path)
                disk_path="$2"
                shift 2
                ;;
            --iso)
                iso_path="$2"
                shift 2
                ;;
            --seed-iso)
                seed_iso="$2"
                shift 2
                ;;
            --network)
                network="$2"
                shift 2
                ;;
            --graphics)
                graphics="$2"
                shift 2
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage 1
                ;;
        esac
    done
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║        🦀 moltdown - Automated VM Creator                         ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Check prerequisites
    check_prerequisites
    
    # Validate inputs
    if [[ -z "$seed_iso" ]]; then
        log_warn "No seed ISO specified"
        echo ""
        echo "For automated installation, generate a seed ISO first:"
        echo "  ./generate_nocloud_iso.sh --customize"
        echo ""
        echo "Then run:"
        echo "  $(basename "$0") --seed-iso ./seed.iso"
        echo ""
        echo -n "Continue without autoinstall (manual installation)? (y/n): "
        read -r response
        if [[ "$response" != "y" ]]; then
            exit 0
        fi
    fi
    
    # Check ISO exists
    if ! check_file_exists "$iso_path" "Ubuntu ISO"; then
        download_iso_prompt "$iso_path"
        exit 1
    fi
    
    # Check seed ISO if specified
    if [[ -n "$seed_iso" ]] && ! check_file_exists "$seed_iso" "Seed ISO"; then
        exit 1
    fi
    
    # Check VM doesn't already exist
    if check_vm_exists "$vm_name"; then
        log_error "VM '$vm_name' already exists"
        log_info "Delete it first with: sudo virsh undefine $vm_name --remove-all-storage"
        log_info "Or use a different name: --name different-name"
        exit 1
    fi
    
    # Disk image path
    local disk_image="${disk_path}/${vm_name}.qcow2"
    
    # Display configuration
    log_info "Configuration:"
    log_info "  VM Name:     $vm_name"
    log_info "  vCPUs:       $vcpus"
    log_info "  Memory:      ${memory} MB"
    log_info "  Disk:        ${disk_size} GB (${disk_image})"
    log_info "  Network:     $network"
    log_info "  Graphics:    $graphics"
    log_info "  Ubuntu ISO:  $iso_path"
    [[ -n "$seed_iso" ]] && log_info "  Seed ISO:    $seed_iso"
    echo ""
    
    # Build virt-install command
    local cmd=(
        sudo virt-install
        --name "$vm_name"
        --vcpus "$vcpus"
        --memory "$memory"
        --disk "path=${disk_image},size=${disk_size},format=qcow2,bus=virtio"
        --cdrom "$iso_path"
        --os-variant ubuntu24.04
        --network "network=${network},model=virtio"
        --graphics "${graphics},listen=0.0.0.0"
        --video virtio
        --channel spicevmc
        --boot uefi
        --cpu host-passthrough
        --features smm.state=on
        --tpm "backend.type=emulator,backend.version=2.0,model=tpm-crb"
    )
    
    # Add seed ISO if specified
    if [[ -n "$seed_iso" ]]; then
        cmd+=(--disk "path=${seed_iso},device=cdrom,readonly=on")
        
        # Add kernel parameters for autoinstall
        cmd+=(--extra-args "autoinstall ds=nocloud")
    fi
    
    # Add console for headless installs
    cmd+=(--console "pty,target_type=serial")
    
    # Don't wait for install to complete
    cmd+=(--noautoconsole)
    
    # Display command
    echo "virt-install command:"
    echo "─────────────────────────────────────────────────────────────────────"
    printf '%s \\\n' "${cmd[@]}" | sed 's/^/  /'
    echo "─────────────────────────────────────────────────────────────────────"
    echo ""
    
    if [[ "$dry_run" == "true" ]]; then
        log_info "Dry run - command not executed"
        exit 0
    fi
    
    # Confirm
    echo -n "Create VM? (y/n): "
    read -r response
    if [[ "$response" != "y" ]]; then
        log_info "Aborted"
        exit 0
    fi
    
    # Execute
    log_info "Creating VM..."
    "${cmd[@]}"
    
    echo ""
    log_info "VM '$vm_name' created and installation started"
    echo ""
    log_info "Monitor installation:"
    log_info "  Console:    sudo virsh console $vm_name"
    log_info "  GUI:        virt-manager (connect to $vm_name)"
    log_info "  Status:     sudo virsh domstate $vm_name"
    echo ""
    
    if [[ -n "$seed_iso" ]]; then
        log_info "Automated installation in progress..."
        log_info "The VM will reboot automatically when complete."
        log_info ""
        log_info "After installation:"
        log_info "  1. SSH into VM: ssh agent@<vm-ip>"
        log_info "  2. Get IP: sudo virsh domifaddr $vm_name"
        log_info "  3. Run bootstrap: ./bootstrap_agent_vm.sh"
        log_info "  4. Create snapshot: ./snapshot_manager.sh golden $vm_name"
    else
        log_info "Manual installation required."
        log_info "Open virt-manager to complete the installation."
    fi
    echo ""
    
    # Wait a moment and show IP if available
    sleep 5
    local ip
    ip=$(sudo virsh domifaddr "$vm_name" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1) || true
    if [[ -n "$ip" ]]; then
        log_info "VM IP detected: $ip"
    fi
}

main "$@"
