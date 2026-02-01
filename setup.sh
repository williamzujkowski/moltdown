#!/usr/bin/env bash
#===============================================================================
# setup.sh - Quick setup for moltdown
#===============================================================================
# One-command setup that:
# 1. Checks/installs dependencies
# 2. Downloads Ubuntu ISO if needed
# 3. Generates seed ISO
# 4. Creates VM
#
# Usage: ./setup.sh [--skip-iso-download] [--vm-name NAME]
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04-desktop-amd64.iso"
readonly ISO_PATH="/var/lib/libvirt/images/ubuntu-24.04-desktop-amd64.iso"

log_info()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
log_warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

check_deps() {
    local missing=()
    
    for cmd in virsh virt-install genisoimage; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing dependencies: ${missing[*]}"
        echo ""
        echo -n "Install now? (y/n): "
        read -r response
        if [[ "$response" == "y" ]]; then
            sudo apt update
            sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst virt-manager genisoimage
        else
            exit 1
        fi
    fi
    
    log_info "All dependencies installed"
}

download_iso() {
    if [[ -f "$ISO_PATH" ]]; then
        log_info "Ubuntu ISO already exists: $ISO_PATH"
        return 0
    fi
    
    log_info "Downloading Ubuntu 24.04 Desktop ISO..."
    log_info "This may take a while (~5GB)..."
    sudo wget --progress=bar:force -O "$ISO_PATH" "$ISO_URL"
    log_info "Download complete"
}

main() {
    local skip_download="false"
    local vm_name="ubuntu2404-agent"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-iso-download) skip_download="true"; shift ;;
            --vm-name) vm_name="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: $0 [--skip-iso-download] [--vm-name NAME]"
                exit 0
                ;;
            *) shift ;;
        esac
    done
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║            🦀 moltdown - Quick Setup                              ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    cd "$SCRIPT_DIR"
    
    # Step 1: Check dependencies
    log_info "Step 1/4: Checking dependencies..."
    check_deps
    
    # Step 2: Download ISO
    if [[ "$skip_download" != "true" ]]; then
        log_info "Step 2/4: Checking Ubuntu ISO..."
        download_iso
    else
        log_info "Step 2/4: Skipping ISO download"
    fi
    
    # Step 3: Generate seed ISO
    log_info "Step 3/4: Generating cloud-init seed ISO..."
    if [[ ! -f "seed.iso" ]]; then
        ./generate_nocloud_iso.sh --customize
    else
        echo -n "seed.iso exists. Regenerate? (y/n): "
        read -r response
        if [[ "$response" == "y" ]]; then
            rm -f seed.iso
            ./generate_nocloud_iso.sh --customize
        fi
    fi
    
    # Step 4: Create VM
    log_info "Step 4/4: Creating VM..."
    ./virt_install_agent_vm.sh --seed-iso ./seed.iso --name "$vm_name"
    
    echo ""
    log_info "Setup complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Wait for installation to complete (~10-15 min)"
    echo "  2. SSH into VM: ssh agent@<vm-ip>"
    echo "  3. Run bootstrap: ./bootstrap_agent_vm.sh"
    echo "  4. Auth GitHub: gh auth login"
    echo "  5. Create snapshots: ./snapshot_manager.sh golden $vm_name"
    echo ""
}

main "$@"
