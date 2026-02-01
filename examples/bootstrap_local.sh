#!/usr/bin/env bash
#===============================================================================
# bootstrap_local.sh - Local customizations for bootstrap
#===============================================================================
# Copy this file to the guest VM alongside bootstrap_agent_vm.sh and it will
# be sourced automatically if present, allowing you to add custom packages
# and configurations without modifying the main script.
#
# Usage:
#   1. Copy to VM: scp examples/bootstrap_local.sh agent@vm:~/
#   2. Edit as needed
#   3. Run bootstrap normally: ./bootstrap_agent_vm.sh
#===============================================================================

# Override feature flags (uncomment to change defaults)
# INSTALL_NODEJS="false"
# INSTALL_DOCKER="false"
# INSTALL_PLAYWRIGHT_DEPS="false"
# INSTALL_CLAUDE_CLI="false"
# REMOVE_DESKTOP_FLUFF="false"
# ENABLE_UNATTENDED_UPGRADES="false"

# Additional packages to install via apt
LOCAL_APT_PACKAGES=(
    # "your-package-here"
    # "another-package"
)

# Additional npm global packages
LOCAL_NPM_PACKAGES=(
    # "package-name"
)

# Additional pipx packages
LOCAL_PIPX_PACKAGES=(
    # "package-name"
)

# Custom phase to run after all other phases
# This function is called automatically if defined
phase_local_customizations() {
    log_phase "Local Customizations"
    
    # Install additional apt packages
    if [[ ${#LOCAL_APT_PACKAGES[@]} -gt 0 ]]; then
        log_info "Installing additional apt packages..."
        sudo apt install -y "${LOCAL_APT_PACKAGES[@]}"
    fi
    
    # Install additional npm packages
    if [[ ${#LOCAL_NPM_PACKAGES[@]} -gt 0 ]] && command -v npm &>/dev/null; then
        log_info "Installing additional npm packages..."
        sudo npm install -g "${LOCAL_NPM_PACKAGES[@]}"
    fi
    
    # Install additional pipx packages
    if [[ ${#LOCAL_PIPX_PACKAGES[@]} -gt 0 ]] && command -v pipx &>/dev/null; then
        log_info "Installing additional pipx packages..."
        for pkg in "${LOCAL_PIPX_PACKAGES[@]}"; do
            pipx install "$pkg" || true
        done
    fi
    
    # Add your custom setup here
    # Example: Clone your dotfiles
    # if [[ ! -d "$HOME/.dotfiles" ]]; then
    #     git clone https://github.com/yourusername/dotfiles.git "$HOME/.dotfiles"
    #     cd "$HOME/.dotfiles" && ./install.sh
    # fi
    
    log_info "Local customizations complete"
}
