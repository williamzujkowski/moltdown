#!/usr/bin/env bash
#===============================================================================
# generate_nocloud_iso.sh - Create cloud-init NoCloud seed ISO
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
#
# Purpose: Generate an ISO image containing cloud-init configuration for
#          automated Ubuntu 24.04 Desktop installation.
#
# Usage:   ./generate_nocloud_iso.sh [output_path] [--customize]
#
# License: MIT
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly AUTOINSTALL_DIR="${SCRIPT_DIR}/autoinstall"
readonly DEFAULT_OUTPUT="${SCRIPT_DIR}/seed.iso"

#-------------------------------------------------------------------------------
# Functions
#-------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [output_path] [options]

Generate a cloud-init NoCloud seed ISO for automated Ubuntu installation.

Arguments:
    output_path     Path for the generated ISO (default: ${DEFAULT_OUTPUT})

Options:
    --customize     Interactive customization of user-data
    --ssh-key FILE  Add SSH public key from file
    --username NAME Set the username (default: agent)
    --password PASS Set the password (will be hashed)
    --hostname NAME Set the hostname (default: agent-vm)
    -h, --help      Show this help message

Examples:
    $(basename "$0")
    $(basename "$0") /tmp/my-seed.iso
    $(basename "$0") --ssh-key ~/.ssh/id_ed25519.pub --password mysecretpass
    $(basename "$0") --customize

Requirements:
    - genisoimage or mkisofs or xorriso

After generating the ISO, use it with virt-install:
    ./virt_install_agent_vm.sh --seed-iso ./seed.iso

EOF
    exit "${1:-0}"
}

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*"; }
log_error() { echo "[ERROR] $*" >&2; }

check_prerequisites() {
    local iso_tool=""
    
    if command -v genisoimage &>/dev/null; then
        iso_tool="genisoimage"
    elif command -v mkisofs &>/dev/null; then
        iso_tool="mkisofs"
    elif command -v xorriso &>/dev/null; then
        iso_tool="xorriso"
    else
        log_error "No ISO generation tool found"
        log_error "Install one of: genisoimage, mkisofs, or xorriso"
        log_error "  sudo apt install genisoimage"
        exit 1
    fi
    
    echo "$iso_tool"
}

hash_password() {
    local password="$1"
    echo "$password" | openssl passwd -6 -stdin
}

generate_ssh_key_yaml() {
    local keyfile="$1"
    if [[ -f "$keyfile" ]]; then
        local key
        key=$(cat "$keyfile")
        echo "    - $key"
    fi
}

customize_interactive() {
    local workdir="$1"
    local userdata="${workdir}/user-data"
    
    log_info "Interactive customization mode"
    echo ""
    
    # Username
    local username="agent"
    echo -n "Username [agent]: "
    read -r input
    [[ -n "$input" ]] && username="$input"
    
    # Password
    local password=""
    echo -n "Password: "
    read -rs password
    echo ""
    if [[ -z "$password" ]]; then
        password="agent"
        log_warn "Using default password 'agent' - CHANGE THIS!"
    fi
    local password_hash
    password_hash=$(hash_password "$password")
    
    # Hostname
    local hostname="agent-vm"
    echo -n "Hostname [agent-vm]: "
    read -r input
    [[ -n "$input" ]] && hostname="$input"
    
    # SSH key
    local ssh_key=""
    echo -n "SSH public key file (Enter to skip): "
    read -r keyfile
    if [[ -n "$keyfile" && -f "$keyfile" ]]; then
        ssh_key=$(cat "$keyfile")
    fi
    
    # Update user-data
    sed -i "s/username: .*/username: $username/" "$userdata"
    sed -i "s|password: .*|password: \"$password_hash\"|" "$userdata"
    sed -i "s/hostname: .*/hostname: $hostname/" "$userdata"
    
    # Update meta-data
    sed -i "s/local-hostname: .*/local-hostname: $hostname/" "${workdir}/meta-data"
    
    # Add SSH key if provided
    if [[ -n "$ssh_key" ]]; then
        # Find the authorized-keys line and add key
        sed -i "/authorized-keys:/a\\    - $ssh_key" "$userdata"
    fi
    
    echo ""
    log_info "Customization complete"
    log_info "  Username: $username"
    log_info "  Hostname: $hostname"
    [[ -n "$ssh_key" ]] && log_info "  SSH key: added"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    local output="$DEFAULT_OUTPUT"
    local customize="false"
    local ssh_key_file=""
    local username=""
    local password=""
    local hostname=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage 0
                ;;
            --customize)
                customize="true"
                shift
                ;;
            --ssh-key)
                ssh_key_file="$2"
                shift 2
                ;;
            --username)
                username="$2"
                shift 2
                ;;
            --password)
                password="$2"
                shift 2
                ;;
            --hostname)
                hostname="$2"
                shift 2
                ;;
            -*)
                log_error "Unknown option: $1"
                usage 1
                ;;
            *)
                output="$1"
                shift
                ;;
        esac
    done
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║           🦀 moltdown - Seed ISO Generator                        ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Check prerequisites
    local iso_tool
    iso_tool=$(check_prerequisites)
    log_info "Using ISO tool: $iso_tool"
    
    # Check source files
    if [[ ! -f "${AUTOINSTALL_DIR}/user-data" ]]; then
        log_error "user-data not found at ${AUTOINSTALL_DIR}/user-data"
        exit 1
    fi
    if [[ ! -f "${AUTOINSTALL_DIR}/meta-data" ]]; then
        log_error "meta-data not found at ${AUTOINSTALL_DIR}/meta-data"
        exit 1
    fi
    
    # Create temp working directory
    local workdir
    workdir=$(mktemp -d)
    trap "rm -rf '$workdir'" EXIT
    
    # Copy source files
    cp "${AUTOINSTALL_DIR}/user-data" "$workdir/"
    cp "${AUTOINSTALL_DIR}/meta-data" "$workdir/"
    
    # Interactive customization
    if [[ "$customize" == "true" ]]; then
        customize_interactive "$workdir"
    else
        # Apply command-line customizations
        if [[ -n "$username" ]]; then
            sed -i "s/username: .*/username: $username/" "${workdir}/user-data"
            log_info "Username set to: $username"
        fi
        
        if [[ -n "$password" ]]; then
            local password_hash
            password_hash=$(hash_password "$password")
            sed -i "s|password: .*|password: \"$password_hash\"|" "${workdir}/user-data"
            log_info "Password set (hashed)"
        fi
        
        if [[ -n "$hostname" ]]; then
            sed -i "s/hostname: .*/hostname: $hostname/" "${workdir}/user-data"
            sed -i "s/local-hostname: .*/local-hostname: $hostname/" "${workdir}/meta-data"
            log_info "Hostname set to: $hostname"
        fi
        
        if [[ -n "$ssh_key_file" ]]; then
            if [[ -f "$ssh_key_file" ]]; then
                local ssh_key
                ssh_key=$(cat "$ssh_key_file")
                sed -i "/authorized-keys:/a\\    - $ssh_key" "${workdir}/user-data"
                log_info "SSH key added from: $ssh_key_file"
            else
                log_error "SSH key file not found: $ssh_key_file"
                exit 1
            fi
        fi
    fi
    
    # Generate ISO
    log_info "Generating ISO: $output"
    
    case "$iso_tool" in
        genisoimage|mkisofs)
            "$iso_tool" \
                -output "$output" \
                -volid cidata \
                -joliet \
                -rock \
                "$workdir"
            ;;
        xorriso)
            xorriso \
                -as mkisofs \
                -o "$output" \
                -V cidata \
                -J \
                -r \
                "$workdir"
            ;;
    esac
    
    # Verify
    if [[ -f "$output" ]]; then
        local size
        size=$(du -h "$output" | cut -f1)
        log_info "ISO generated successfully: $output ($size)"
        echo ""
        log_info "Contents:"
        if command -v isoinfo &>/dev/null; then
            isoinfo -l -i "$output" 2>/dev/null | grep -E "user-data|meta-data" | sed 's/^/  /'
        else
            echo "  user-data"
            echo "  meta-data"
        fi
        echo ""
        log_info "Next step: Use this ISO with virt-install"
        log_info "  ./virt_install_agent_vm.sh --seed-iso $output"
    else
        log_error "Failed to generate ISO"
        exit 1
    fi
}

main "$@"
