#!/usr/bin/env bash
#===============================================================================
# update-golden.sh - Update the golden image (CLIs, packages, auth)
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
#
# Starts the golden VM, updates packages and CLIs, then creates new snapshot.
#
# Usage:
#   ./update-golden.sh              # Full update (packages + CLIs + auth)
#   ./update-golden.sh --quick      # CLIs only, skip apt upgrade
#   ./update-golden.sh --auth-only  # Just re-sync auth from host
#   ./update-golden.sh --packages   # Packages only, skip CLIs
#
# License: MIT
#===============================================================================

set -euo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GOLDEN_VM="${MOLTDOWN_GOLDEN:-moltdown-integration-test}"
VM_USER="${MOLTDOWN_USER:-agent}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}[====]${NC}  $*"; }

show_help() {
    cat << 'EOF'
update-golden.sh - Update the golden image

Usage:
  ./update-golden.sh              Full update (packages + CLIs + auth)
  ./update-golden.sh --quick      CLIs only, skip apt upgrade
  ./update-golden.sh --auth-only  Just re-sync auth from host
  ./update-golden.sh --packages   Packages only, skip CLIs
  ./update-golden.sh --no-snapshot  Don't create snapshot after update
  ./update-golden.sh -h, --help   Show this help

Environment Variables:
  MOLTDOWN_GOLDEN    Golden VM name (default: moltdown-integration-test)
  MOLTDOWN_USER      SSH username (default: agent)
EOF
    exit 0
}

# Parse arguments
QUICK=false
AUTH_ONLY=false
PACKAGES_ONLY=false
NO_SNAPSHOT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help ;;
        --quick) QUICK=true; shift ;;
        --auth-only) AUTH_ONLY=true; shift ;;
        --packages) PACKAGES_ONLY=true; shift ;;
        --no-snapshot) NO_SNAPSHOT=true; shift ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Detect virsh
VIRSH="virsh"
if ! virsh list &>/dev/null 2>&1; then
    VIRSH="sudo virsh"
fi

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}            🦀 moltdown - Updating Golden Image                     ${CYAN}║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Start golden VM
log_step "Starting golden VM: $GOLDEN_VM"
$VIRSH start "$GOLDEN_VM" 2>/dev/null || log_info "VM already running or starting..."

log_info "Waiting for VM to boot (60s)..."
sleep 60

IP=$($VIRSH domifaddr "$GOLDEN_VM" 2>/dev/null | grep -oE '192\.168\.[0-9]+\.[0-9]+' | head -1)
if [[ -z "$IP" ]]; then
    log_error "Could not get VM IP. Is the VM running?"
    exit 1
fi
log_info "Golden VM IP: $IP"

# Wait for SSH
log_info "Waiting for SSH..."
for i in {1..30}; do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
           "${VM_USER}@${IP}" "true" 2>/dev/null; then
        break
    fi
    sleep 5
done

# Verify SSH works
if ! ssh -o StrictHostKeyChecking=no -o BatchMode=yes "${VM_USER}@${IP}" "true" 2>/dev/null; then
    log_error "Cannot SSH to VM"
    exit 1
fi
log_info "SSH connected"
echo ""

# Auth only mode
if $AUTH_ONLY; then
    log_step "Syncing auth only..."
    "$SCRIPT_DIR/sync-ai-auth.sh" "$IP" "$VM_USER"
else
    # Update packages
    if ! $QUICK; then
        log_step "Updating system packages..."
        ssh -o StrictHostKeyChecking=no -o BatchMode=yes "${VM_USER}@${IP}" << 'EOF'
echo "Running apt update..."
sudo apt update -qq
echo "Running apt upgrade..."
sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y -qq
echo "Running apt autoremove..."
sudo apt autoremove -y -qq
echo "Package update complete."
EOF
        echo ""
    fi

    # Update CLIs
    if ! $PACKAGES_ONLY; then
        log_step "Updating AI CLIs..."
        ssh -o StrictHostKeyChecking=no -o BatchMode=yes "${VM_USER}@${IP}" << 'EOF'
echo "=== Updating Claude Code ==="
curl -fsSL https://claude.ai/install.sh 2>/dev/null | bash 2>/dev/null || echo "Claude update skipped"
claude --version 2>/dev/null || echo "Claude not available"

echo ""
echo "=== Updating Codex ==="
sudo npm update -g @openai/codex 2>/dev/null || sudo npm install -g @openai/codex 2>/dev/null
codex --version 2>/dev/null || echo "Codex not available"

echo ""
echo "=== Updating Gemini ==="
sudo npm update -g @google/gemini-cli 2>/dev/null || sudo npm install -g @google/gemini-cli 2>/dev/null
gemini --version 2>/dev/null || echo "Gemini not available"

echo ""
echo "=== Updating nexus-agents ==="
if [[ -d ~/nexus-agents ]]; then
    cd ~/nexus-agents
    git pull 2>/dev/null || echo "Git pull skipped"
    pnpm install 2>/dev/null || npm install 2>/dev/null || echo "npm install skipped"
    pnpm build 2>/dev/null || echo "Build skipped"
fi
echo "CLI updates complete."
EOF
        echo ""

        log_step "Syncing auth from host..."
        "$SCRIPT_DIR/sync-ai-auth.sh" "$IP" "$VM_USER"
    fi
fi

# Shutdown and snapshot
if ! $NO_SNAPSHOT; then
    log_step "Shutting down for snapshot..."
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes "${VM_USER}@${IP}" "sudo shutdown -h now" 2>/dev/null || true
    sleep 30

    # Wait for shutdown
    for i in {1..12}; do
        state=$($VIRSH domstate "$GOLDEN_VM" 2>/dev/null || echo "unknown")
        [[ "$state" == "shut off" ]] && break
        sleep 5
    done

    state=$($VIRSH domstate "$GOLDEN_VM" 2>/dev/null || echo "unknown")
    if [[ "$state" != "shut off" ]]; then
        log_warn "VM not shut off, forcing..."
        $VIRSH destroy "$GOLDEN_VM" 2>/dev/null || true
        sleep 5
    fi

    log_step "Creating new snapshot..."
    # Delete old dev-ready
    $VIRSH snapshot-delete "$GOLDEN_VM" dev-ready 2>/dev/null || true

    # Create new snapshot
    desc="Updated $(date +%Y-%m-%d)"
    $AUTH_ONLY && desc="Auth sync $(date +%Y-%m-%d)"
    $QUICK && desc="Quick update $(date +%Y-%m-%d)"

    $VIRSH snapshot-create-as "$GOLDEN_VM" dev-ready \
        --description "$desc" --atomic

    log_info "Snapshot created!"
    echo ""
    log_step "Snapshots for $GOLDEN_VM:"
    $VIRSH snapshot-list "$GOLDEN_VM"
else
    log_info "Skipping snapshot (--no-snapshot)"
fi

echo ""
log_step "Golden image update complete!"
