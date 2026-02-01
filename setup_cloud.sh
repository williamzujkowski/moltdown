#!/usr/bin/env bash
#===============================================================================
# setup_cloud.sh - Quick setup using Ubuntu Cloud Images
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
#
# Creates an Ubuntu 24.04 Desktop VM using cloud images (faster than ISO install)
#
# Usage: ./setup_cloud.sh [--vm-name NAME] [--skip-download]
#===============================================================================

set -euo pipefail

# Configuration
readonly CLOUD_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
readonly CLOUD_IMG_PATH="/var/lib/libvirt/images/ubuntu-noble-cloudimg.img"
readonly DEFAULT_VM_NAME="ubuntu2404-agent"
readonly DEFAULT_DISK_SIZE="50G"
readonly DEFAULT_MEMORY="8192"
readonly DEFAULT_VCPUS="4"

log_info()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
log_warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

check_deps() {
    local missing=()
    for cmd in virsh virt-install qemu-img xorriso wget; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing: ${missing[*]}"
        log_error "Install: sudo apt install qemu-kvm libvirt-daemon-system virtinst qemu-utils xorriso wget"
        exit 1
    fi
}

download_cloud_image() {
    if [[ -f "$CLOUD_IMG_PATH" ]]; then
        log_info "Cloud image exists: $CLOUD_IMG_PATH"
        return 0
    fi
    
    log_info "Downloading Ubuntu 24.04 cloud image (~600MB)..."
    sudo wget --progress=bar:force -O "$CLOUD_IMG_PATH" "$CLOUD_IMG_URL"
    log_info "Download complete"
}

generate_seed_iso() {
    local output="$1"
    local workdir
    workdir=$(mktemp -d)
    
    # Cloud-init user-data (NOT autoinstall format)
    cat > "$workdir/user-data" << 'USERDATA'
#cloud-config
users:
  - name: agent
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: "$6$rounds=4096$randomsalt$9oBEQq4ndZ/NWu70e2niTNPNHXwAK7jDmUvPpcvG9/k/Dh4J.omw8IHK5CI94TkQ50Sz8u747yR00Cg4KKC4q/"
    groups: [sudo, adm, cdrom, dip, plugdev, lpadmin]

hostname: agent-vm
ssh_pwauth: true
package_update: true
package_upgrade: true

packages:
  - ubuntu-desktop-minimal
  - openssh-server
  - qemu-guest-agent
  - spice-vdagent
  - curl
  - wget
  - git
  - vim

runcmd:
  - systemctl enable ssh
  - systemctl enable qemu-guest-agent
  - systemctl set-default graphical.target

final_message: |
  === moltdown VM ready ===
  Login: agent / agent (CHANGE PASSWORD!)
  SSH: ssh agent@$(hostname -I | awk '{print $1}')
USERDATA

    cat > "$workdir/meta-data" << EOF
instance-id: moltdown-$(date +%s)
local-hostname: agent-vm
EOF

    xorriso -as mkisofs -o "$output" -V "CIDATA" -J -r "$workdir" 2>/dev/null
    rm -rf "$workdir"
    log_info "Seed ISO created: $output"
}

create_vm() {
    local vm_name="$1"
    local disk_path="/var/lib/libvirt/images/${vm_name}.qcow2"
    local seed_path="/var/lib/libvirt/images/${vm_name}-seed.iso"
    
    # Check if VM exists
    if virsh dominfo "$vm_name" &>/dev/null; then
        log_error "VM '$vm_name' already exists"
        log_error "Delete with: sudo virsh undefine $vm_name --remove-all-storage"
        exit 1
    fi
    
    # Create disk from cloud image
    log_info "Creating VM disk from cloud image..."
    sudo cp "$CLOUD_IMG_PATH" "$disk_path"
    sudo qemu-img resize "$disk_path" "$DEFAULT_DISK_SIZE"
    
    # Generate seed ISO
    generate_seed_iso "$seed_path"
    sudo mv "$seed_path" "/var/lib/libvirt/images/" 2>/dev/null || true
    seed_path="/var/lib/libvirt/images/${vm_name}-seed.iso"
    
    # Create VM
    log_info "Creating VM: $vm_name"
    sudo virt-install \
        --name "$vm_name" \
        --vcpus "$DEFAULT_VCPUS" \
        --memory "$DEFAULT_MEMORY" \
        --disk "path=$disk_path" \
        --disk "path=$seed_path,device=cdrom" \
        --os-variant ubuntu24.04 \
        --network network=default \
        --graphics spice \
        --video virtio \
        --channel spicevmc \
        --import \
        --noautoconsole
    
    log_info "VM '$vm_name' created and starting"
}

wait_for_ready() {
    local vm_name="$1"
    local max_wait=300
    local waited=0
    
    log_info "Waiting for VM to be ready (cloud-init + desktop install)..."
    
    while [[ $waited -lt $max_wait ]]; do
        local ip
        ip=$(sudo virsh domifaddr "$vm_name" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1)
        
        if [[ -n "$ip" ]]; then
            if sshpass -p "agent" ssh -o StrictHostKeyChecking=accept-new \
                -o PreferredAuthentications=password \
                -o PubkeyAuthentication=no \
                -o ConnectTimeout=3 \
                "agent@$ip" 'cloud-init status' 2>/dev/null | grep -q "done"; then
                echo ""
                log_info "VM ready! IP: $ip"
                return 0
            fi
        fi
        
        echo -n "."
        sleep 10
        waited=$((waited + 10))
    done
    
    echo ""
    log_warn "Timeout waiting for cloud-init. Check: ssh agent@<ip>"
    return 1
}

main() {
    local vm_name="$DEFAULT_VM_NAME"
    local skip_download=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vm-name) vm_name="$2"; shift 2 ;;
            --skip-download) skip_download=true; shift ;;
            -h|--help)
                echo "Usage: $0 [--vm-name NAME] [--skip-download]"
                exit 0
                ;;
            *) shift ;;
        esac
    done
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║            🦀 moltdown - Cloud Image Setup                        ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    check_deps
    
    if [[ "$skip_download" != "true" ]]; then
        download_cloud_image
    fi
    
    create_vm "$vm_name"
    wait_for_ready "$vm_name"
    
    echo ""
    log_info "Setup complete!"
    echo ""
    echo "Next steps:"
    echo "  1. SSH: ssh agent@<ip> (password: agent)"
    echo "  2. Change password: passwd"
    echo "  3. Run bootstrap: ./bootstrap_agent_vm.sh"
    echo "  4. Create snapshot: ./snapshot_manager.sh golden $vm_name"
    echo ""
}

main "$@"
