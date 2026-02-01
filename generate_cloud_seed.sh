#!/usr/bin/env bash
#===============================================================================
# generate_cloud_seed.sh - Generate seed ISO for Ubuntu Cloud Images
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
#
# Creates a NoCloud seed ISO for use with Ubuntu Cloud Images.
# Different from generate_nocloud_iso.sh which uses autoinstall format.
#
# Usage: ./generate_cloud_seed.sh [output_path] [options]
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_OUTPUT="${SCRIPT_DIR}/cloud-seed.iso"

log_info()  { echo "[INFO]  $*"; }
log_error() { echo "[ERROR] $*" >&2; }

usage() {
    cat << 'USAGE'
Generate seed ISO for Ubuntu Cloud Images

Usage: generate_cloud_seed.sh [output_path] [options]

Arguments:
    output_path       Path for generated ISO (default: ./cloud-seed.iso)

Options:
    --username NAME   Set username (default: agent)
    --password PASS   Set password (will be hashed)
    --hostname NAME   Set hostname (default: agent-vm)
    --ssh-key FILE    Add SSH public key from file
    --no-desktop      Skip ubuntu-desktop-minimal installation
    -h, --help        Show this help

Examples:
    ./generate_cloud_seed.sh
    ./generate_cloud_seed.sh /tmp/my-seed.iso --password mypass
    ./generate_cloud_seed.sh --ssh-key ~/.ssh/id_ed25519.pub --no-desktop

After generating, create VM with:
    cp /var/lib/libvirt/images/ubuntu-noble-cloudimg.img my-vm.qcow2
    qemu-img resize my-vm.qcow2 50G
    virt-install --name my-vm --import --disk my-vm.qcow2 --disk cloud-seed.iso,device=cdrom ...
USAGE
    exit "${1:-0}"
}

main() {
    local output="$DEFAULT_OUTPUT"
    local username="agent"
    local password=""
    local hostname="agent-vm"
    local ssh_key=""
    local install_desktop=true
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage 0 ;;
            --username) username="$2"; shift 2 ;;
            --password) password="$2"; shift 2 ;;
            --hostname) hostname="$2"; shift 2 ;;
            --ssh-key) ssh_key="$2"; shift 2 ;;
            --no-desktop) install_desktop=false; shift ;;
            -*) log_error "Unknown option: $1"; usage 1 ;;
            *) output="$1"; shift ;;
        esac
    done
    
    # Check for ISO tool
    local iso_tool=""
    if command -v xorriso &>/dev/null; then
        iso_tool="xorriso"
    elif command -v genisoimage &>/dev/null; then
        iso_tool="genisoimage"
    elif command -v mkisofs &>/dev/null; then
        iso_tool="mkisofs"
    else
        log_error "No ISO tool found. Install: sudo apt install xorriso"
        exit 1
    fi
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║           🦀 moltdown - Cloud Seed ISO Generator                  ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Create temp directory
    local workdir
    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' EXIT
    
    # Generate password hash if provided
    local passwd_hash
    if [[ -n "$password" ]]; then
        passwd_hash=$(echo "$password" | openssl passwd -6 -stdin)
    else
        # Default hash for "agent"
        passwd_hash='$6$rounds=4096$randomsalt$9oBEQq4ndZ/NWu70e2niTNPNHXwAK7jDmUvPpcvG9/k/Dh4J.omw8IHK5CI94TkQ50Sz8u747yR00Cg4KKC4q/'
    fi
    
    # Read SSH key if provided
    local ssh_key_line=""
    if [[ -n "$ssh_key" && -f "$ssh_key" ]]; then
        ssh_key_line=$(cat "$ssh_key")
    fi
    
    # Build packages list
    local packages="openssh-server qemu-guest-agent spice-vdagent curl wget git vim"
    if [[ "$install_desktop" == "true" ]]; then
        packages="ubuntu-desktop-minimal $packages"
    fi
    
    # Generate user-data
    cat > "$workdir/user-data" << USERDATA
#cloud-config
users:
  - name: ${username}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: "${passwd_hash}"
    groups: [sudo, adm, cdrom, dip, plugdev, lpadmin]
USERDATA

    # Add SSH key if provided
    if [[ -n "$ssh_key_line" ]]; then
        cat >> "$workdir/user-data" << SSHKEY
    ssh_authorized_keys:
      - ${ssh_key_line}
SSHKEY
    fi
    
    # Continue user-data
    cat >> "$workdir/user-data" << USERDATA

hostname: ${hostname}
ssh_pwauth: true
package_update: true
package_upgrade: true

packages:
USERDATA

    # Add packages
    for pkg in $packages; do
        echo "  - $pkg" >> "$workdir/user-data"
    done
    
    # Add runcmd
    cat >> "$workdir/user-data" << 'USERDATA'

runcmd:
  - systemctl enable ssh
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
USERDATA

    if [[ "$install_desktop" == "true" ]]; then
        echo "  - systemctl set-default graphical.target" >> "$workdir/user-data"
    fi
    
    # Generate meta-data
    cat > "$workdir/meta-data" << METADATA
instance-id: moltdown-$(date +%s)
local-hostname: ${hostname}
METADATA

    # Create ISO
    log_info "Generating ISO: $output"
    case "$iso_tool" in
        xorriso)
            xorriso -as mkisofs -o "$output" -V "CIDATA" -J -r "$workdir" 2>/dev/null
            ;;
        genisoimage|mkisofs)
            "$iso_tool" -output "$output" -volid "CIDATA" -joliet -rock "$workdir" 2>/dev/null
            ;;
    esac
    
    log_info "ISO generated: $output ($(du -h "$output" | cut -f1))"
    log_info ""
    log_info "Configuration:"
    log_info "  Username: $username"
    log_info "  Hostname: $hostname"
    log_info "  Desktop:  $install_desktop"
    [[ -n "$ssh_key_line" ]] && log_info "  SSH key:  configured"
    echo ""
}

main "$@"
