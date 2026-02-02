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
#          8) Agent resilience (watchdog, cgroups, session persistence)
#          9) Long-run session hardening
#         10) Verification
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
# Phase 8: Agent Process Resilience & Recovery
#-------------------------------------------------------------------------------
phase_agent_resilience() {
    log_phase "Agent Process Resilience & Recovery"

    # Feature flags (can be overridden in bootstrap_local.sh)
    ENABLE_WATCHDOG="${ENABLE_WATCHDOG:-true}"
    ENABLE_CGROUPS_LIMITS="${ENABLE_CGROUPS_LIMITS:-true}"
    ENABLE_SESSION_PERSISTENCE="${ENABLE_SESSION_PERSISTENCE:-true}"

    # Memory limits (configurable)
    WATCHDOG_WARN_MB="${WATCHDOG_WARN_MB:-8000}"
    WATCHDOG_KILL_MB="${WATCHDOG_KILL_MB:-13000}"
    CGROUPS_MEMORY_LIMIT="${CGROUPS_MEMORY_LIMIT:-12G}"

    #---------------------------------------------------------------------------
    # 1. Claude Memory Watchdog Service
    #---------------------------------------------------------------------------
    if [[ "$ENABLE_WATCHDOG" == "true" ]]; then
        log_info "Installing Claude memory watchdog service..."

        # Watchdog script
        sudo tee /usr/local/bin/claude-memory-watchdog > /dev/null <<'WATCHDOGEOF'
#!/usr/bin/env bash
#===============================================================================
# claude-memory-watchdog - Monitor and manage Claude CLI memory usage
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
set -euo pipefail

readonly WARN_THRESHOLD_MB="${WATCHDOG_WARN_MB:-8000}"
readonly KILL_THRESHOLD_MB="${WATCHDOG_KILL_MB:-13000}"
readonly CHECK_INTERVAL=30
readonly LOG_TAG="claude-watchdog"

log() { logger -t "$LOG_TAG" "$*"; echo "[$(date '+%H:%M:%S')] $*"; }

get_claude_memory_mb() {
    ps aux 2>/dev/null | grep -E 'node.*claude|claude.*node|bun.*claude' | grep -v grep \
        | awk '{sum+=$6} END {if(sum>0) printf "%.0f", sum/1024; else print "0"}'
}

main() {
    log "Starting watchdog (warn: ${WARN_THRESHOLD_MB}MB, kill: ${KILL_THRESHOLD_MB}MB)"

    while true; do
        local mem_mb
        mem_mb=$(get_claude_memory_mb)

        if [[ "$mem_mb" -gt "$KILL_THRESHOLD_MB" ]]; then
            log "CRITICAL: Claude using ${mem_mb}MB (>${KILL_THRESHOLD_MB}MB), sending SIGTERM..."
            pkill -TERM -f 'node.*claude|claude.*node|bun.*claude' 2>/dev/null || true
            sleep 5

            # Force kill if still running
            mem_mb=$(get_claude_memory_mb)
            if [[ "$mem_mb" -gt "$KILL_THRESHOLD_MB" ]]; then
                log "CRITICAL: Force killing Claude (still at ${mem_mb}MB)..."
                pkill -KILL -f 'node.*claude|claude.*node|bun.*claude' 2>/dev/null || true
            fi
        elif [[ "$mem_mb" -gt "$WARN_THRESHOLD_MB" ]]; then
            log "WARNING: Claude using ${mem_mb}MB (>${WARN_THRESHOLD_MB}MB)"
        fi

        sleep "$CHECK_INTERVAL"
    done
}

main "$@"
WATCHDOGEOF
        sudo chmod +x /usr/local/bin/claude-memory-watchdog

        # Systemd service
        sudo tee /etc/systemd/system/claude-watchdog.service > /dev/null <<EOF
[Unit]
Description=Claude CLI Memory Watchdog
Documentation=https://github.com/williamzujkowski/moltdown
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/claude-memory-watchdog
Restart=on-failure
RestartSec=30s
Environment="WATCHDOG_WARN_MB=${WATCHDOG_WARN_MB}"
Environment="WATCHDOG_KILL_MB=${WATCHDOG_KILL_MB}"
StandardOutput=journal
StandardError=journal
SyslogIdentifier=claude-watchdog

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable claude-watchdog
        log_info "Claude watchdog service installed (warn: ${WATCHDOG_WARN_MB}MB, kill: ${WATCHDOG_KILL_MB}MB)"
    fi

    #---------------------------------------------------------------------------
    # 2. cgroups v2 Memory Limiting Wrapper
    #---------------------------------------------------------------------------
    if [[ "$ENABLE_CGROUPS_LIMITS" == "true" ]]; then
        log_info "Installing cgroups memory limit wrapper..."

        sudo tee /usr/local/bin/run-claude-limited > /dev/null <<'CGROUPSEOF'
#!/usr/bin/env bash
#===============================================================================
# run-claude-limited - Run Claude CLI with enforced memory limits
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
#
# Usage: run-claude-limited [MEMORY_LIMIT] [claude args...]
#        run-claude-limited 12G           # Run with 12GB limit
#        run-claude-limited 8G --help     # Run with 8GB limit
#===============================================================================
set -euo pipefail

MEMORY_LIMIT="${1:-12G}"
shift 2>/dev/null || true

# Validate limit format
if [[ ! "$MEMORY_LIMIT" =~ ^[0-9]+[GMK]$ ]]; then
    echo "Usage: run-claude-limited [MEMORY_LIMIT] [claude args...]"
    echo "  MEMORY_LIMIT: Memory limit with suffix (e.g., 12G, 8192M)"
    echo "  Default: 12G"
    exit 1
fi

# Calculate swap limit (memory + 4G for emergency)
MEM_VALUE="${MEMORY_LIMIT%[GMK]}"
MEM_SUFFIX="${MEMORY_LIMIT: -1}"
SWAP_VALUE=$((MEM_VALUE + 4))
SWAP_LIMIT="${SWAP_VALUE}${MEM_SUFFIX}"

echo "[run-claude-limited] Starting with MemoryMax=${MEMORY_LIMIT}, MemorySwapMax=${SWAP_LIMIT}"

exec systemd-run \
    --user \
    --scope \
    --unit="claude-limited-$$" \
    -p "MemoryMax=${MEMORY_LIMIT}" \
    -p "MemorySwapMax=${SWAP_LIMIT}" \
    -p "MemoryAccounting=yes" \
    -- claude "$@"
CGROUPSEOF
        sudo chmod +x /usr/local/bin/run-claude-limited
        log_info "cgroups wrapper installed (default limit: ${CGROUPS_MEMORY_LIMIT})"
    fi

    #---------------------------------------------------------------------------
    # 3. Session Persistence with tmux
    #---------------------------------------------------------------------------
    if [[ "$ENABLE_SESSION_PERSISTENCE" == "true" ]]; then
        log_info "Installing session persistence tools..."

        # Agent session wrapper
        mkdir -p "$HOME/.local/bin"
        mkdir -p "$HOME/.agent-session"

        cat > "$HOME/.local/bin/agent-session" <<'SESSIONEOF'
#!/usr/bin/env bash
#===============================================================================
# agent-session - tmux session management with persistence
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
#
# Usage: agent-session [session-name] [work-dir]
#===============================================================================
set -euo pipefail

SESSION_NAME="${1:-agent-work}"
WORK_DIR="${2:-$HOME/work}"
SESSION_DIR="$HOME/.agent-session"
RECOVERY_FILE="$SESSION_DIR/${SESSION_NAME}.state"

mkdir -p "$SESSION_DIR"

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Attaching to existing session: $SESSION_NAME"
    tmux attach-session -t "$SESSION_NAME"
else
    echo "Creating new session: $SESSION_NAME in $WORK_DIR"

    tmux new-session -d -s "$SESSION_NAME" -c "$WORK_DIR"

    # Log session state for recovery
    cat > "$RECOVERY_FILE" <<EOF
session=$SESSION_NAME
created=$(date -Is)
work_dir=$WORK_DIR
pid=$$
EOF

    tmux attach-session -t "$SESSION_NAME"
fi
SESSIONEOF
        chmod +x "$HOME/.local/bin/agent-session"

        # Crash monitor
        cat > "$HOME/.local/bin/agent-crash-monitor" <<'CRASHEOF'
#!/usr/bin/env bash
#===============================================================================
# agent-crash-monitor - Log crash events for post-mortem analysis
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
set -euo pipefail

SESSION_DIR="$HOME/.agent-session"
CRASH_LOG="$SESSION_DIR/crashes.log"
mkdir -p "$SESSION_DIR"

log_crash() {
    local timestamp
    timestamp=$(date -Is)
    local mem_info
    mem_info=$(free -h | grep -E '^Mem:|^Swap:' | tr '\n' ' ')

    cat >> "$CRASH_LOG" <<EOF
---
timestamp: $timestamp
trigger: $1
memory: $mem_info
claude_processes: $(pgrep -c -f 'claude|node.*claude' 2>/dev/null || echo 0)
sessions: $(tmux list-sessions 2>/dev/null | wc -l || echo 0)
EOF
}

# Monitor dmesg for OOM events
while true; do
    if dmesg -T 2>/dev/null | tail -20 | grep -qi 'out of memory\|oom-killer\|killed process.*claude'; then
        log_crash "oom-killer"
    fi
    sleep 60
done
CRASHEOF
        chmod +x "$HOME/.local/bin/agent-crash-monitor"

        # Add to PATH if not present
        if ! grep -q '.local/bin' "$HOME/.bashrc" 2>/dev/null; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
        fi

        log_info "Session persistence tools installed (agent-session, agent-crash-monitor)"
    fi

    log_info "Agent resilience phase complete"
}

#-------------------------------------------------------------------------------
# Phase 9: Long-Run Session Hardening
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

    # Install enhanced health check script with trend analysis
    log_info "Installing enhanced health check script..."
    sudo tee /usr/local/bin/vm-health-check > /dev/null <<'HEALTHEOF'
#!/bin/bash
#===============================================================================
# vm-health-check - VM health status with memory trend prediction
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
set -uo pipefail

readonly METRICS_DIR="$HOME/.vm-metrics"
readonly METRICS_FILE="$METRICS_DIR/memory-trend.csv"
readonly WARN_THRESHOLD=8000
readonly ALERT_THRESHOLD=12000

mkdir -p "$METRICS_DIR" 2>/dev/null || true

show_help() {
    echo "Usage: vm-health-check [options]"
    echo ""
    echo "Options:"
    echo "  --watch, -w    Continuous monitoring (updates every 30s)"
    echo "  --trend, -t    Show memory trend analysis"
    echo "  --help, -h     Show this help"
    exit 0
}

get_claude_memory_mb() {
    ps aux 2>/dev/null | grep -E 'node.*claude|claude.*node|bun.*claude' | grep -v grep \
        | awk '{sum+=$6} END {if(sum>0) printf "%.0f", sum/1024; else print "0"}'
}

record_metric() {
    local timestamp mem_mb
    timestamp=$(date +%s)
    mem_mb=$(get_claude_memory_mb)

    echo "$timestamp,$mem_mb" >> "$METRICS_FILE" 2>/dev/null || true

    # Keep only last 24 hours (2880 samples at 30s intervals)
    if [[ -f "$METRICS_FILE" ]]; then
        tail -n 2880 "$METRICS_FILE" > "$METRICS_FILE.tmp" 2>/dev/null && \
            mv "$METRICS_FILE.tmp" "$METRICS_FILE" 2>/dev/null || true
    fi

    echo "$mem_mb"
}

predict_trend() {
    if [[ ! -f "$METRICS_FILE" ]]; then
        echo "insufficient_data"
        return
    fi

    local line_count
    line_count=$(wc -l < "$METRICS_FILE" 2>/dev/null || echo "0")

    if [[ "$line_count" -lt 10 ]]; then
        echo "insufficient_data"
        return
    fi

    # Get last 30 minutes of data (60 samples)
    local start_mem end_mem
    start_mem=$(tail -n 60 "$METRICS_FILE" | head -1 | cut -d, -f2 2>/dev/null || echo "0")
    end_mem=$(tail -n 1 "$METRICS_FILE" | cut -d, -f2 2>/dev/null || echo "0")

    local delta=$((end_mem - start_mem))

    # If growing by >2GB in 30 min, predict OOM
    if [[ "$delta" -gt 2000 ]]; then
        local rate_per_min=$((delta / 30))
        local remaining=$((ALERT_THRESHOLD - end_mem))
        local mins_to_alert=$((remaining / rate_per_min))

        if [[ "$mins_to_alert" -gt 0 && "$mins_to_alert" -lt 120 ]]; then
            echo "oom_predicted:${mins_to_alert}"
            return
        fi
    fi

    if [[ "$delta" -gt 500 ]]; then
        echo "growing"
    elif [[ "$delta" -lt -500 ]]; then
        echo "shrinking"
    else
        echo "stable"
    fi
}

check_health() {
    echo "=== VM Health Check $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo "Uptime:  $(uptime -p)"
    echo ""
    echo "--- Memory ---"
    echo "RAM:     $(free -h | awk '/Mem:/{print $3 "/" $2 " (" int($3/$2*100) "% used)"}')"
    echo "Swap:    $(free -h | awk '/Swap:/{if($2!="0B") print $3 "/" $2 " (" int($3/$2*100) "%)"; else print "not configured"}')"

    # Claude CLI memory tracking with trend
    local claude_mb
    claude_mb=$(record_metric)
    echo "Claude:  ${claude_mb}MB"

    # Trend prediction
    local trend
    trend=$(predict_trend)
    case "$trend" in
        oom_predicted:*)
            local mins="${trend#*:}"
            echo "  🔴 ALERT: Predicted memory exhaustion in ~${mins} minutes!"
            ;;
        growing)
            echo "  🟡 CAUTION: Memory usage increasing"
            ;;
        stable|shrinking)
            # No warning needed
            ;;
    esac

    # Threshold warnings
    if [[ "$claude_mb" -gt "$ALERT_THRESHOLD" ]]; then
        echo "  🔴 CRITICAL: Claude using >${ALERT_THRESHOLD}MB - watchdog may terminate"
    elif [[ "$claude_mb" -gt "$WARN_THRESHOLD" ]]; then
        echo "  🟡 WARNING: Claude using >${WARN_THRESHOLD}MB - consider restarting"
    fi

    # Watchdog status
    if systemctl is-active --quiet claude-watchdog 2>/dev/null; then
        echo "Watchdog: running"
    else
        echo "Watchdog: not running"
    fi

    echo ""
    echo "--- System ---"
    echo "Disk:    $(df -h / | awk 'NR==2{print $3 "/" $2 " (" $5 " used)"}')"
    echo "Load:    $(cat /proc/loadavg | cut -d' ' -f1-3)"
    echo "Procs:   $(ps aux --no-headers | wc -l)"
    echo "Journal: $(journalctl --disk-usage 2>/dev/null | grep -oP '\d+\.\d+[MG]' || echo 'unknown')"
}

show_trend() {
    echo "=== Memory Trend Analysis ==="
    if [[ ! -f "$METRICS_FILE" ]]; then
        echo "No trend data available. Run vm-health-check --watch to collect data."
        return
    fi

    local count
    count=$(wc -l < "$METRICS_FILE")
    echo "Data points: $count"

    if [[ "$count" -lt 2 ]]; then
        echo "Not enough data for trend analysis."
        return
    fi

    # Last 5 readings
    echo ""
    echo "Recent readings (last 5):"
    tail -n 5 "$METRICS_FILE" | while IFS=, read -r ts mem; do
        echo "  $(date -d "@$ts" '+%H:%M:%S'): ${mem}MB"
    done

    # Min/max in dataset
    echo ""
    local min max
    min=$(cut -d, -f2 "$METRICS_FILE" | sort -n | head -1)
    max=$(cut -d, -f2 "$METRICS_FILE" | sort -n | tail -1)
    echo "Range: ${min}MB - ${max}MB"

    # Current trend
    echo ""
    echo "Trend: $(predict_trend)"
}

case "${1:-}" in
    --help|-h) show_help ;;
    --trend|-t) show_trend ;;
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
    run_once "08-agent-resilience"     phase_agent_resilience
    run_once "09-longrun-hardening"    phase_longrun_hardening

    # Run local customizations if defined (from bootstrap_local.sh)
    if declare -f phase_local_customizations &>/dev/null; then
        run_once "10-local-customizations" phase_local_customizations
    fi

    run_once "11-verification"         phase_verification
    
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
