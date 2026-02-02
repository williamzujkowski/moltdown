#!/usr/bin/env bash
#===============================================================================
# bootstrap_agent_vm.sh - Ubuntu 24.04 Desktop Agent VM Bootstrap
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
#
# Purpose: Transform a fresh Ubuntu 24.04 Desktop install into an agent-ready
#          development environment with security hardening and reproducibility.
#
# Usage:   chmod +x bootstrap_agent_vm.sh && ./bootstrap_agent_vm.sh
#
# Phases:  1) System updates
#          2) Core utilities
#          3) Security hardening
#          4) Development tools
#          5) Browser & automation
#          6) Agent tooling
#          7) Desktop optimization
#          8) Long-run session hardening
#          9) Verification
#
# License: MIT
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_DIR="$HOME/logs"
LOG_FILE="$LOG_DIR/bootstrap_$(date +%Y%m%d_%H%M%S).log"
readonly LOG_FILE
readonly MARKER_DIR="$HOME/.bootstrap_markers"
readonly ARTIFACTS_DIR="$HOME/work/artifacts"
readonly REPOS_DIR="$HOME/work/repos"
readonly SCRATCH_DIR="$HOME/work/scratch"

# Feature flags - set to "false" to skip (can be overridden in bootstrap_local.sh)
INSTALL_NODEJS="true"
INSTALL_DOCKER="true"
INSTALL_PLAYWRIGHT_DEPS="true"
INSTALL_CLAUDE_CLI="true"
REMOVE_DESKTOP_FLUFF="true"
ENABLE_UNATTENDED_UPGRADES="true"

# Resource settings (can be overridden in bootstrap_local.sh)
# 8GB swap recommended for Claude CLI memory leak protection
SWAP_SIZE="${SWAP_SIZE:-8G}"

# Source local customizations if present
readonly LOCAL_CONFIG="$HOME/bootstrap_local.sh"
if [[ -f "$LOCAL_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$LOCAL_CONFIG"
fi

#-------------------------------------------------------------------------------
# Logging & Output
#-------------------------------------------------------------------------------
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log_info()  { echo "[INFO]  $(date +%H:%M:%S) $*"; }
log_warn()  { echo "[WARN]  $(date +%H:%M:%S) $*"; }
log_error() { echo "[ERROR] $(date +%H:%M:%S) $*"; }
log_phase() { echo ""; echo "═══════════════════════════════════════════════════════════════"; echo "[PHASE] $*"; echo "═══════════════════════════════════════════════════════════════"; }

#-------------------------------------------------------------------------------
# Idempotent Phase Runner
#-------------------------------------------------------------------------------
mkdir -p "$MARKER_DIR"

run_once() {
    local phase_name="$1"
    shift
    
    if [[ -f "$MARKER_DIR/${phase_name}.done" ]]; then
        log_info "Skipping '$phase_name' (already completed)"
        return 0
    fi
    
    log_info "Starting phase: $phase_name"
    if "$@"; then
        touch "$MARKER_DIR/${phase_name}.done"
        log_info "Completed phase: $phase_name"
        return 0
    else
        log_error "Failed phase: $phase_name"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Phase 1: System Updates
#-------------------------------------------------------------------------------
phase_system_updates() {
    log_phase "System Updates"
    
    sudo apt update
    sudo apt full-upgrade -y
    sudo apt autoremove -y
    
    log_info "System updated successfully"
}

#-------------------------------------------------------------------------------
# Phase 2: Core Utilities
#-------------------------------------------------------------------------------
phase_core_utilities() {
    log_phase "Core Utilities"
    
    sudo apt install -y \
        build-essential \
        git git-lfs \
        curl wget unzip \
        ca-certificates gnupg lsb-release \
        jq yq \
        ripgrep fd-find fzf bat \
        tmux htop tree ncdu \
        python3 python3-venv python3-pip pipx \
        openssh-client openssh-server \
        ufw \
        rsync \
        vim neovim \
        qemu-guest-agent spice-vdagent
    
    # Ensure pipx on PATH
    python3 -m pipx ensurepath || true
    
    # Enable QEMU guest agent for better VM integration
    sudo systemctl enable --now qemu-guest-agent || true
    
    log_info "Core utilities installed"
}

#-------------------------------------------------------------------------------
# Phase 3: Security Hardening
#-------------------------------------------------------------------------------
phase_security_hardening() {
    log_phase "Security Hardening"
    
    # SSH hardening
    log_info "Hardening SSH configuration..."
    sudo cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%Y%m%d)"
    
    sudo tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<'EOF'
# Security hardening for agent VM
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
AllowAgentForwarding yes
EOF
    
    sudo systemctl restart ssh
    
    # UFW firewall
    log_info "Configuring firewall..."
    sudo ufw --force reset
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow ssh
    sudo ufw --force enable
    
    # Fail2ban
    log_info "Installing and configuring fail2ban..."
    sudo apt install -y fail2ban
    
    sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
EOF
    
    sudo systemctl enable --now fail2ban
    
    # Unattended upgrades for security patches
    if [[ "$ENABLE_UNATTENDED_UPGRADES" == "true" ]]; then
        log_info "Enabling unattended security upgrades..."
        sudo apt install -y unattended-upgrades
        
        sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
        
        sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    fi
    
    # Reduce journal disk usage
    log_info "Configuring journald limits..."
    sudo sed -i 's/#SystemMaxUse=.*/SystemMaxUse=100M/' /etc/systemd/journald.conf
    sudo sed -i 's/#MaxRetentionSec=.*/MaxRetentionSec=1week/' /etc/systemd/journald.conf
    sudo systemctl restart systemd-journald
    
    log_info "Security hardening complete"
}

#-------------------------------------------------------------------------------
# Phase 4: Development Tools
#-------------------------------------------------------------------------------
phase_dev_tools() {
    log_phase "Development Tools"
    
    # GitHub CLI
    log_info "Installing GitHub CLI..."
    sudo apt install -y gh
    
    # Node.js LTS
    if [[ "$INSTALL_NODEJS" == "true" ]]; then
        log_info "Installing Node.js LTS..."
        if ! command -v node &>/dev/null; then
            curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
            sudo apt install -y nodejs
        else
            log_info "Node.js already installed: $(node --version)"
        fi
    fi
    
    # Docker
    if [[ "$INSTALL_DOCKER" == "true" ]]; then
        log_info "Installing Docker..."
        if ! command -v docker &>/dev/null; then
            curl -fsSL https://get.docker.com | sudo sh
            sudo usermod -aG docker "$USER"
            sudo systemctl enable docker
        else
            log_info "Docker already installed: $(docker --version)"
        fi
    fi
    
    # Python tools via pipx
    log_info "Installing Python tools..."
    pipx install poetry || true
    pipx install ruff || true
    pipx install httpie || true
    
    log_info "Development tools installed"
}

#-------------------------------------------------------------------------------
# Phase 5: Browser & Automation
#-------------------------------------------------------------------------------
phase_browser_automation() {
    log_phase "Browser & Automation"
    
    # Google Chrome
    log_info "Installing Google Chrome..."
    if ! command -v google-chrome &>/dev/null; then
        wget -qO - https://dl.google.com/linux/linux_signing_key.pub \
            | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
        
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
            | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null
        
        sudo apt update
        sudo apt install -y google-chrome-stable
    else
        log_info "Chrome already installed"
    fi
    
    # Playwright dependencies
    if [[ "$INSTALL_PLAYWRIGHT_DEPS" == "true" ]]; then
        log_info "Installing Playwright/Puppeteer dependencies..."
        sudo apt install -y \
            libnss3 \
            libatk1.0-0 \
            libatk-bridge2.0-0 \
            libcups2 \
            libdrm2 \
            libxkbcommon0 \
            libxcomposite1 \
            libxdamage1 \
            libxfixes3 \
            libxrandr2 \
            libgbm1 \
            libasound2t64 \
            libpango-1.0-0 \
            libcairo2
        
        # If node is available, install playwright browsers
        if command -v npx &>/dev/null; then
            sudo npx playwright install-deps chromium || true
        fi
    fi
    
    log_info "Browser and automation tools installed"
}

#-------------------------------------------------------------------------------
# Phase 6: Agent Tooling
#-------------------------------------------------------------------------------
phase_agent_tooling() {
    log_phase "Agent Tooling"
    
    # Claude CLI
    if [[ "$INSTALL_CLAUDE_CLI" == "true" ]] && command -v npm &>/dev/null; then
        log_info "Installing Claude CLI..."
        sudo npm install -g @anthropic-ai/claude-code || true
    fi
    
    # Create workspace structure
    log_info "Creating workspace directories..."
    mkdir -p "$REPOS_DIR"
    mkdir -p "$SCRATCH_DIR"
    mkdir -p "$ARTIFACTS_DIR"
    mkdir -p "$HOME/.config"
    
    # Git configuration template
    if [[ ! -f "$HOME/.gitconfig" ]]; then
        log_info "Creating git config template..."
        cat > "$HOME/.gitconfig" <<'EOF'
[init]
    defaultBranch = main
[pull]
    rebase = true
[push]
    autoSetupRemote = true
[core]
    editor = vim
    autocrlf = input
[alias]
    st = status
    co = checkout
    br = branch
    ci = commit
    lg = log --oneline --graph --decorate
EOF
    fi
    
    log_info "Agent tooling configured"
}

#-------------------------------------------------------------------------------
# Phase 7: Desktop Optimization
#-------------------------------------------------------------------------------
phase_desktop_optimization() {
    log_phase "Desktop Optimization"
    
    # Remove desktop bloat
    if [[ "$REMOVE_DESKTOP_FLUFF" == "true" ]]; then
        log_info "Removing unnecessary desktop applications..."
        sudo apt purge -y \
            thunderbird \
            libreoffice* \
            rhythmbox \
            totem \
            cheese \
            simple-scan \
            shotwell \
            aisleriot \
            gnome-mahjongg \
            gnome-mines \
            gnome-sudoku \
            gnome-calendar \
            gnome-contacts \
            gnome-weather \
            gnome-maps \
            gnome-clocks || true
        
        sudo apt autoremove -y
    fi
    
    # GNOME performance tweaks for VM
    log_info "Applying GNOME VM performance tweaks..."
    gsettings set org.gnome.desktop.interface enable-animations false || true
    gsettings set org.gnome.desktop.session idle-delay 0 || true
    gsettings set org.gnome.desktop.interface gtk-enable-primary-paste false || true
    gsettings set org.gnome.desktop.screensaver lock-enabled false || true
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' || true
    
    # Set dark theme (easier on eyes for long sessions)
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true
    
    log_info "Desktop optimization complete"
}

#-------------------------------------------------------------------------------
# Phase 8: Long-Run Session Hardening
#-------------------------------------------------------------------------------
phase_longrun_hardening() {
    log_phase "Long-Run Session Hardening"

    # Disable cloud-init after bootstrap to prevent reconfiguration on reboot
    log_info "Disabling cloud-init for future boots..."
    sudo touch /etc/cloud/cloud-init.disabled

    # Create swap file if not present (important for memory pressure during long runs)
    # Claude CLI memory leaks can consume 13GB+, so larger swap is recommended
    if [[ ! -f /swapfile ]]; then
        log_info "Creating ${SWAP_SIZE} swap file (Claude CLI memory leak protection)..."
        sudo fallocate -l "$SWAP_SIZE" /swapfile
        sudo chmod 600 /swapfile
        sudo mkswap /swapfile
        sudo swapon /swapfile
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
        log_info "Swap file created and enabled (${SWAP_SIZE})"
    else
        log_info "Swap file already exists"
    fi

    # Install health check script for monitoring long sessions
    log_info "Installing health check script..."
    sudo tee /usr/local/bin/vm-health-check > /dev/null <<'HEALTHEOF'
#!/bin/bash
# vm-health-check - Quick VM health status for long-running sessions
# Part of moltdown 🦀

show_help() {
    echo "Usage: vm-health-check [--watch]"
    echo "  --watch  Continuous monitoring (updates every 30s)"
    exit 0
}

check_health() {
    echo "=== VM Health Check $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo "Uptime:  $(uptime -p)"
    echo ""
    echo "--- Memory ---"
    echo "RAM:     $(free -h | awk '/Mem:/{print $3 "/" $2 " (" int($3/$2*100) "% used)"}')"
    echo "Swap:    $(free -h | awk '/Swap:/{if($2!="0B") print $3 "/" $2 " (" int($3/$2*100) "%)"; else print "not configured"}')"

    # Claude CLI memory tracking (critical for leak detection)
    local claude_mem
    claude_mem=$(ps aux 2>/dev/null | grep -E 'claude|node.*claude-code' | grep -v grep | awk '{sum+=$6} END {if(sum>0) printf "%.1fMB", sum/1024; else print "not running"}')
    echo "Claude:  $claude_mem"

    # Warn if Claude is consuming excessive memory
    local claude_mb
    claude_mb=$(ps aux 2>/dev/null | grep -E 'claude|node.*claude-code' | grep -v grep | awk '{sum+=$6} END {print sum/1024}')
    if [[ -n "$claude_mb" ]] && (( $(echo "$claude_mb > 4000" | bc -l 2>/dev/null || echo 0) )); then
        echo "  ⚠️  WARNING: Claude CLI using >4GB - consider restarting or snapshotting"
    fi

    echo ""
    echo "--- System ---"
    echo "Disk:    $(df -h / | awk 'NR==2{print $3 "/" $2 " (" $5 " used)"}')"
    echo "Load:    $(cat /proc/loadavg | cut -d' ' -f1-3)"
    echo "Procs:   $(ps aux --no-headers | wc -l)"
    echo "Journal: $(journalctl --disk-usage 2>/dev/null | grep -oP '\d+\.\d+[MG]' || echo 'unknown')"
}

case "${1:-}" in
    --help|-h) show_help ;;
    --watch|-w)
        while true; do
            clear
            check_health
            echo ""
            echo "[Ctrl+C to exit, refreshing in 30s...]"
            sleep 30
        done
        ;;
    *) check_health ;;
esac
HEALTHEOF
    sudo chmod +x /usr/local/bin/vm-health-check

    # Ensure journal vacuum runs periodically
    log_info "Configuring journal maintenance..."
    sudo journalctl --vacuum-size=100M 2>/dev/null || true

    log_info "Long-run hardening complete"
}

#-------------------------------------------------------------------------------
# Phase 9: Verification & Manifest Generation
#-------------------------------------------------------------------------------
phase_verification() {
    log_phase "Verification & Manifest Generation"
    
    mkdir -p "$ARTIFACTS_DIR"
    local manifest_date
    manifest_date=$(date +%Y%m%d_%H%M%S)
    
    # Generate package manifests
    log_info "Generating package manifests..."
    dpkg-query -W -f='${Package}=${Version}\n' | sort > "$ARTIFACTS_DIR/apt_packages_${manifest_date}.manifest"
    
    if command -v pip &>/dev/null; then
        pip list --format=freeze 2>/dev/null | sort > "$ARTIFACTS_DIR/pip_packages_${manifest_date}.manifest" || true
    fi
    
    if command -v npm &>/dev/null; then
        npm list -g --depth=0 2>/dev/null > "$ARTIFACTS_DIR/npm_packages_${manifest_date}.manifest" || true
    fi
    
    if command -v pipx &>/dev/null; then
        pipx list --short 2>/dev/null > "$ARTIFACTS_DIR/pipx_packages_${manifest_date}.manifest" || true
    fi
    
    # System info
    log_info "Recording system information..."
    cat > "$ARTIFACTS_DIR/system_info_${manifest_date}.txt" <<EOF
Bootstrap Version: $SCRIPT_VERSION
Bootstrap Date: $(date -Is)
Hostname: $(hostname)
Kernel: $(uname -r)
Ubuntu Version: $(lsb_release -ds)
CPU: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)
Memory: $(free -h | awk '/^Mem:/ {print $2}')
Disk: $(df -h / | awk 'NR==2 {print $2 " total, " $4 " available"}')
EOF
    
    # Verification checks
    log_info "Running verification checks..."
    local failed=0
    local required_commands=(
        "git"
        "gh"
        "python3"
        "pip"
        "curl"
        "wget"
        "jq"
        "tmux"
        "ufw"
        "google-chrome"
    )
    
    # Optional commands based on feature flags
    [[ "$INSTALL_NODEJS" == "true" ]] && required_commands+=("node" "npm")
    [[ "$INSTALL_DOCKER" == "true" ]] && required_commands+=("docker")
    
    for cmd in "${required_commands[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            log_info "  ✓ $cmd"
        else
            log_error "  ✗ $cmd NOT FOUND"
            failed=1
        fi
    done
    
    # Service checks
    log_info "Checking services..."
    for svc in ssh ufw fail2ban; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log_info "  ✓ $svc service running"
        else
            log_warn "  ⚠ $svc service not running"
        fi
    done
    
    if [[ $failed -eq 0 ]]; then
        log_info "All verification checks passed!"
    else
        log_error "Some verification checks failed!"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║       🦀 moltdown - Agent VM Bootstrap v${SCRIPT_VERSION}                     ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    log_info "Bootstrap started at $(date -Is)"
    log_info "Log file: $LOG_FILE"
    log_info "Marker directory: $MARKER_DIR"
    echo ""
    
    # Run all phases with idempotency
    run_once "01-system-updates"       phase_system_updates
    run_once "02-core-utilities"       phase_core_utilities
    run_once "03-security-hardening"   phase_security_hardening
    run_once "04-dev-tools"            phase_dev_tools
    run_once "05-browser-automation"   phase_browser_automation
    run_once "06-agent-tooling"        phase_agent_tooling
    run_once "07-desktop-optimization" phase_desktop_optimization
    run_once "08-longrun-hardening"    phase_longrun_hardening

    # Run local customizations if defined (from bootstrap_local.sh)
    if declare -f phase_local_customizations &>/dev/null; then
        run_once "09-local-customizations" phase_local_customizations
    fi

    run_once "10-verification"         phase_verification
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                     Bootstrap Complete!                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    log_info "Bootstrap finished at $(date -Is)"
    log_info "Log saved to: $LOG_FILE"
    log_info "Manifests saved to: $ARTIFACTS_DIR"
    echo ""
    echo "NEXT STEPS:"
    echo "  1) Authenticate GitHub:"
    echo "     gh auth login"
    echo ""
    echo "  2) Generate SSH key for GitHub (optional):"
    echo "     ssh-keygen -t ed25519 -C 'agent-vm'"
    echo "     cat ~/.ssh/id_ed25519.pub"
    echo "     gh ssh-key add ~/.ssh/id_ed25519.pub --title 'agent-vm'"
    echo ""
    echo "  3) If Docker was installed, log out and back in (or run: newgrp docker)"
    echo ""
    echo "  4) Shut down VM and create 'dev-ready' snapshot:"
    echo "     sudo shutdown -h now"
    echo "     # On host: sudo virsh snapshot-create-as <vm-name> dev-ready --atomic"
    echo ""
}

main "$@"
