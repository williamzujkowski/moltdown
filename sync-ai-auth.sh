#!/usr/bin/env bash
#===============================================================================
# sync-ai-auth.sh - Sync AI CLI auth and git config to moltdown VM
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
#
# Copies authenticated CLI configs from host to VM so you don't have to
# re-authenticate. Also copies git config and signing keys for commits.
#
# Usage:
#   ./sync-ai-auth.sh <vm-ip> [username]
#
# Example:
#   ./sync-ai-auth.sh 192.168.122.45 agent
#
# What gets copied:
#   - Claude Code: ~/.claude.json, ~/.claude/
#   - Codex: ~/.codex/
#   - Gemini: ~/.gemini/
#   - Git: ~/.gitconfig
#   - GitHub CLI: ~/.config/gh/
#   - SSH keys: ~/.ssh/ (for git auth)
#   - GPG keys: exported and imported (if using GPG signing)
#
# License: MIT
#===============================================================================

set -euo pipefail

readonly SCRIPT_VERSION="1.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

show_help() {
    cat << 'EOF'
sync-ai-auth.sh - Sync AI CLI auth and git config to moltdown VM

Usage:
  ./sync-ai-auth.sh <vm-ip> [username]

Arguments:
  vm-ip      IP address of the target VM
  username   SSH username (default: agent)

Options:
  -h, --help     Show this help message
  -v, --version  Show version
  --dry-run      Show what would be copied without copying

What gets copied:
  - Claude Code: ~/.claude.json, ~/.claude/settings.json, ~/.claude/agents/
  - Codex: ~/.codex/auth.json, ~/.codex/config.toml
  - Gemini: ~/.gemini/oauth_creds.json, ~/.gemini/settings.json
  - Git: ~/.gitconfig
  - GitHub CLI: ~/.config/gh/hosts.yml
  - SSH keys: ~/.ssh/id_* (for git auth)
  - GPG keys: exported and imported (if using GPG signing)

Examples:
  ./sync-ai-auth.sh 192.168.122.45
  ./sync-ai-auth.sh 192.168.122.45 myuser
  ./sync-ai-auth.sh 192.168.122.45 --dry-run
EOF
    exit 0
}

show_version() {
    echo "sync-ai-auth.sh version $SCRIPT_VERSION"
    exit 0
}

# Parse arguments
DRY_RUN=false
VM_IP=""
VM_USER="agent"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help ;;
        -v|--version) show_version ;;
        --dry-run) DRY_RUN=true; shift ;;
        -*) log_error "Unknown option: $1"; exit 1 ;;
        *)
            if [[ -z "$VM_IP" ]]; then
                VM_IP="$1"
            else
                VM_USER="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$VM_IP" ]]; then
    log_error "Usage: $0 <vm-ip> [username]"
    log_error "Run with --help for more information"
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║            🦀 moltdown - AI Auth Sync                             ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "DRY RUN MODE - no files will be copied"
    echo ""
fi

log_info "Target: ${VM_USER}@${VM_IP}"
echo ""

# Test SSH connection
log_step "Testing SSH connection..."
if ! ssh $SSH_OPTS "${VM_USER}@${VM_IP}" "echo 'SSH OK'" &>/dev/null; then
    log_error "Cannot connect to ${VM_USER}@${VM_IP}"
    log_error "Make sure the VM is running and SSH is accessible"
    exit 1
fi
log_info "SSH connection OK"
echo ""

# Helper function for scp
sync_file() {
    local src="$1"
    local dest="$2"
    local desc="${3:-$src}"

    if [[ ! -e "$src" ]]; then
        log_warn "  - $desc (not found on host)"
        return 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "  Would copy: $src -> $dest"
        return 0
    fi

    if scp $SSH_OPTS -q "$src" "${VM_USER}@${VM_IP}:$dest" 2>/dev/null; then
        log_info "  ✓ $desc"
        return 0
    else
        log_warn "  ✗ Failed to copy $desc"
        return 1
    fi
}

sync_dir() {
    local src="$1"
    local dest="$2"
    local desc="${3:-$src}"

    if [[ ! -d "$src" ]]; then
        log_warn "  - $desc (not found on host)"
        return 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "  Would copy: $src/ -> $dest/"
        return 0
    fi

    if scp $SSH_OPTS -q -r "$src" "${VM_USER}@${VM_IP}:$dest" 2>/dev/null; then
        log_info "  ✓ $desc"
        return 0
    else
        log_warn "  ✗ Failed to copy $desc"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Claude Code
#-------------------------------------------------------------------------------
log_step "Syncing Claude Code config..."
if [[ "$DRY_RUN" != "true" ]]; then
    ssh $SSH_OPTS "${VM_USER}@${VM_IP}" "mkdir -p ~/.claude" 2>/dev/null
fi
sync_file ~/.claude.json "~/.claude.json" "~/.claude.json (settings)"
sync_file ~/.claude/settings.json "~/.claude/settings.json" "~/.claude/settings.json"
sync_dir ~/.claude/agents "~/.claude/" "~/.claude/agents/"
echo ""

#-------------------------------------------------------------------------------
# Codex
#-------------------------------------------------------------------------------
log_step "Syncing Codex config..."
if [[ "$DRY_RUN" != "true" ]]; then
    ssh $SSH_OPTS "${VM_USER}@${VM_IP}" "mkdir -p ~/.codex" 2>/dev/null
fi
sync_file ~/.codex/auth.json "~/.codex/auth.json" "~/.codex/auth.json (OAuth tokens)"
sync_file ~/.codex/config.toml "~/.codex/config.toml" "~/.codex/config.toml"
sync_file ~/.codex/instructions.md "~/.codex/instructions.md" "~/.codex/instructions.md"
echo ""

#-------------------------------------------------------------------------------
# Gemini
#-------------------------------------------------------------------------------
log_step "Syncing Gemini config..."
if [[ "$DRY_RUN" != "true" ]]; then
    ssh $SSH_OPTS "${VM_USER}@${VM_IP}" "mkdir -p ~/.gemini" 2>/dev/null
fi
sync_file ~/.gemini/oauth_creds.json "~/.gemini/oauth_creds.json" "~/.gemini/oauth_creds.json (OAuth)"
sync_file ~/.gemini/settings.json "~/.gemini/settings.json" "~/.gemini/settings.json"
sync_file ~/.gemini/google_accounts.json "~/.gemini/google_accounts.json" "~/.gemini/google_accounts.json"
echo ""

#-------------------------------------------------------------------------------
# Git Config
#-------------------------------------------------------------------------------
log_step "Syncing Git config..."
sync_file ~/.gitconfig "~/.gitconfig" "~/.gitconfig (identity + signing)"
sync_file ~/.gitignore_global "~/.gitignore_global" "~/.gitignore_global"
echo ""

#-------------------------------------------------------------------------------
# GitHub CLI
#-------------------------------------------------------------------------------
log_step "Syncing GitHub CLI auth..."
if [[ "$DRY_RUN" != "true" ]]; then
    ssh $SSH_OPTS "${VM_USER}@${VM_IP}" "mkdir -p ~/.config/gh" 2>/dev/null
fi
sync_file ~/.config/gh/hosts.yml "~/.config/gh/hosts.yml" "~/.config/gh/hosts.yml (auth tokens)"
echo ""

#-------------------------------------------------------------------------------
# SSH Keys (for git auth)
#-------------------------------------------------------------------------------
log_step "Syncing SSH keys..."
if [[ "$DRY_RUN" != "true" ]]; then
    ssh $SSH_OPTS "${VM_USER}@${VM_IP}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh" 2>/dev/null
fi

# Copy common key pairs
for keytype in id_ed25519 id_rsa id_ecdsa; do
    if [[ -f ~/.ssh/$keytype ]]; then
        sync_file ~/.ssh/$keytype "~/.ssh/$keytype" "~/.ssh/$keytype (private)"
        sync_file ~/.ssh/${keytype}.pub "~/.ssh/${keytype}.pub" "~/.ssh/${keytype}.pub"
    fi
done

# Copy SSH config
sync_file ~/.ssh/config "~/.ssh/config" "~/.ssh/config"

# Fix permissions
if [[ "$DRY_RUN" != "true" ]]; then
    ssh $SSH_OPTS "${VM_USER}@${VM_IP}" "chmod 600 ~/.ssh/id_* 2>/dev/null; chmod 644 ~/.ssh/*.pub 2>/dev/null; chmod 600 ~/.ssh/config 2>/dev/null" 2>/dev/null || true
fi
echo ""

#-------------------------------------------------------------------------------
# GPG Keys (if using GPG signing)
#-------------------------------------------------------------------------------
SIGNING_FORMAT=$(git config --global gpg.format 2>/dev/null || echo "gpg")
SIGNING_KEY=$(git config --global user.signingkey 2>/dev/null || true)

if [[ "$SIGNING_FORMAT" != "ssh" && -n "$SIGNING_KEY" ]]; then
    log_step "Syncing GPG keys (GPG signing detected)..."

    if command -v gpg &>/dev/null; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "  Would export and import GPG key: $SIGNING_KEY"
        else
            # Export secret key
            GPG_EXPORT=$(mktemp)
            if gpg --export-secret-keys --armor "$SIGNING_KEY" > "$GPG_EXPORT" 2>/dev/null && [[ -s "$GPG_EXPORT" ]]; then
                scp $SSH_OPTS -q "$GPG_EXPORT" "${VM_USER}@${VM_IP}:/tmp/gpg-key.asc" 2>/dev/null
                if ssh $SSH_OPTS "${VM_USER}@${VM_IP}" "gpg --batch --import /tmp/gpg-key.asc 2>/dev/null && rm /tmp/gpg-key.asc" 2>/dev/null; then
                    log_info "  ✓ GPG key $SIGNING_KEY imported"
                    # Trust the key
                    ssh $SSH_OPTS "${VM_USER}@${VM_IP}" "echo '${SIGNING_KEY}:6:' | gpg --import-ownertrust 2>/dev/null" 2>/dev/null || true
                else
                    log_warn "  ✗ Failed to import GPG key"
                fi
            else
                log_warn "  ✗ GPG key export failed (may require passphrase)"
                log_warn "    Consider using SSH signing instead: git config --global gpg.format ssh"
            fi
            rm -f "$GPG_EXPORT"
        fi
    else
        log_warn "  GPG not installed on host"
    fi
else
    log_info "SSH signing configured or no signing key (skipping GPG)"
fi
echo ""

#-------------------------------------------------------------------------------
# Verify
#-------------------------------------------------------------------------------
if [[ "$DRY_RUN" != "true" ]]; then
    log_step "Verifying on VM..."
    echo ""
    ssh $SSH_OPTS "${VM_USER}@${VM_IP}" << 'VERIFY'
echo "=== Verification ==="
echo ""

echo "Claude Code:"
[[ -f ~/.claude.json ]] && echo "  ✓ ~/.claude.json" || echo "  ✗ ~/.claude.json"
[[ -f ~/.claude/settings.json ]] && echo "  ✓ ~/.claude/settings.json" || echo "  - ~/.claude/settings.json (optional)"

echo ""
echo "Codex:"
[[ -f ~/.codex/auth.json ]] && echo "  ✓ ~/.codex/auth.json" || echo "  ✗ ~/.codex/auth.json"
[[ -f ~/.codex/config.toml ]] && echo "  ✓ ~/.codex/config.toml" || echo "  - ~/.codex/config.toml (optional)"

echo ""
echo "Gemini:"
[[ -f ~/.gemini/oauth_creds.json ]] && echo "  ✓ ~/.gemini/oauth_creds.json" || echo "  ✗ ~/.gemini/oauth_creds.json"

echo ""
echo "Git:"
[[ -f ~/.gitconfig ]] && echo "  ✓ ~/.gitconfig" || echo "  ✗ ~/.gitconfig"
if git config user.name &>/dev/null && git config user.email &>/dev/null; then
    echo "  ✓ Identity: $(git config user.name) <$(git config user.email)>"
fi
if git config user.signingkey &>/dev/null; then
    echo "  ✓ Signing key: $(git config user.signingkey)"
fi

echo ""
echo "GitHub CLI:"
if gh auth status &>/dev/null; then
    echo "  ✓ Authenticated"
else
    echo "  ✗ Not authenticated"
fi

echo ""
echo "SSH Keys:"
for f in ~/.ssh/id_*.pub; do
    [[ -f "$f" ]] && echo "  ✓ $f"
done 2>/dev/null || echo "  - No SSH keys"

echo ""
echo "GPG Keys:"
if gpg --list-secret-keys --keyid-format=short 2>/dev/null | grep -q sec; then
    gpg --list-secret-keys --keyid-format=short 2>/dev/null | grep -E "^sec|^uid" | head -4
else
    echo "  - No GPG keys"
fi
VERIFY
fi

echo ""
log_info "Done! AI CLIs and git config synced to ${VM_USER}@${VM_IP}"
echo ""
log_info "Test with:"
log_info "  ssh ${VM_USER}@${VM_IP}"
log_info "  claude --version"
log_info "  codex --version"
log_info "  gemini --version"
log_info "  git commit --allow-empty -S -m 'test signed commit'"
