#!/usr/bin/env bash
#===============================================================================
# setup-hooks.sh - Configure Claude Code hooks for moltdown project
#===============================================================================
# Part of moltdown - https://github.com/williamzujkowski/moltdown
#
# Purpose: Set up Claude Code hooks for shell script validation, lint checking,
#          and project context injection. Idempotent - safe to run multiple times.
#
# Usage:   ./setup-hooks.sh [--dry-run] [--force]
#
# Options:
#   --dry-run   Show what would be done without making changes
#   --force     Overwrite existing hook scripts
#   --remove    Remove all moltdown hooks
#
# License: MIT
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CLAUDE_DIR="$SCRIPT_DIR/.claude"
readonly HOOKS_DIR="$CLAUDE_DIR/hooks"
readonly SETTINGS_FILE="$CLAUDE_DIR/settings.json"

# Flags
DRY_RUN=false
FORCE=false
REMOVE=false

#-------------------------------------------------------------------------------
# Logging
#-------------------------------------------------------------------------------
log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_dry()   { echo "[DRY]   $*"; }

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
    cat << 'EOF'
Usage: ./setup-hooks.sh [OPTIONS]

Configure Claude Code hooks for moltdown project.

Options:
  --dry-run   Show what would be done without making changes
  --force     Overwrite existing hook scripts (default: skip existing)
  --remove    Remove all moltdown hooks
  -h, --help  Show this help message

Hooks installed:
  1. PostToolUse[Write|Edit] - Run shellcheck on modified .sh files
  2. SessionStart[startup]   - Inject project context reminder
  3. PreToolUse[Bash]        - Validate dangerous commands

Examples:
  ./setup-hooks.sh              # Install hooks
  ./setup-hooks.sh --dry-run    # Preview changes
  ./setup-hooks.sh --remove     # Remove hooks
  ./setup-hooks.sh --force      # Reinstall all hooks
EOF
}

#-------------------------------------------------------------------------------
# Parse Arguments
#-------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --remove)
            REMOVE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

#-------------------------------------------------------------------------------
# Remove hooks
#-------------------------------------------------------------------------------
remove_hooks() {
    log_info "Removing moltdown hooks..."

    if [[ -d "$HOOKS_DIR" ]]; then
        if $DRY_RUN; then
            log_dry "Would remove: $HOOKS_DIR"
        else
            rm -rf "$HOOKS_DIR"
            log_info "Removed: $HOOKS_DIR"
        fi
    fi

    if [[ -f "$SETTINGS_FILE" ]]; then
        if $DRY_RUN; then
            log_dry "Would remove hooks from: $SETTINGS_FILE"
        else
            # Remove hooks key from settings if it exists
            if command -v jq &>/dev/null; then
                local tmp_file
                tmp_file=$(mktemp)
                jq 'del(.hooks)' "$SETTINGS_FILE" > "$tmp_file"
                mv "$tmp_file" "$SETTINGS_FILE"
                log_info "Removed hooks from: $SETTINGS_FILE"
            else
                log_warn "jq not installed - manually edit $SETTINGS_FILE to remove hooks"
            fi
        fi
    fi

    log_info "Hooks removed successfully"
}

#-------------------------------------------------------------------------------
# Create hook scripts
#-------------------------------------------------------------------------------
create_hook_scripts() {
    log_info "Creating hook scripts..."

    if $DRY_RUN; then
        log_dry "Would create: $HOOKS_DIR"
    else
        mkdir -p "$HOOKS_DIR"
    fi

    # Hook 1: Shellcheck validator for modified shell scripts
    local shellcheck_hook="$HOOKS_DIR/shellcheck-on-write.sh"
    if [[ -f "$shellcheck_hook" ]] && ! $FORCE; then
        log_info "Skipping existing: $shellcheck_hook"
    else
        if $DRY_RUN; then
            log_dry "Would create: $shellcheck_hook"
        else
            cat > "$shellcheck_hook" << 'HOOK_EOF'
#!/usr/bin/env bash
# PostToolUse hook: Run shellcheck on modified .sh files
# Exit 0 = proceed, Exit 2 = block (not used here, just advisory)

set -euo pipefail

# Read input from stdin
INPUT=$(cat)

# Extract file path from tool input
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only check .sh files
if [[ -z "$FILE_PATH" ]] || [[ ! "$FILE_PATH" =~ \.sh$ ]]; then
    exit 0
fi

# Check if file exists
if [[ ! -f "$FILE_PATH" ]]; then
    exit 0
fi

# Run shellcheck if available
if command -v shellcheck &>/dev/null; then
    if ! shellcheck -x "$FILE_PATH" 2>&1; then
        # Output goes to Claude as feedback (not blocking)
        echo "shellcheck found issues in $FILE_PATH" >&2
    fi
fi

exit 0
HOOK_EOF
            chmod +x "$shellcheck_hook"
            log_info "Created: $shellcheck_hook"
        fi
    fi

    # Hook 2: Session context injection
    local session_hook="$HOOKS_DIR/session-context.sh"
    if [[ -f "$session_hook" ]] && ! $FORCE; then
        log_info "Skipping existing: $session_hook"
    else
        if $DRY_RUN; then
            log_dry "Would create: $session_hook"
        else
            cat > "$session_hook" << 'HOOK_EOF'
#!/usr/bin/env bash
# SessionStart hook: Inject project context reminder
# Outputs text that Claude will see at session start

set -euo pipefail

INPUT=$(cat)
SESSION_TYPE=$(echo "$INPUT" | jq -r '.matcher_value // "unknown"')

# Only inject on fresh startup, not resume/compact
if [[ "$SESSION_TYPE" == "startup" ]]; then
    cat << 'CONTEXT'
moltdown project context:
- VM workflow toolkit for AI agents
- Use 'make lint' before commits
- Shell scripts must pass shellcheck -x
- Key commands: ./agent.sh, ./snapshot_manager.sh, ./clone_manager.sh
CONTEXT
fi

exit 0
HOOK_EOF
            chmod +x "$session_hook"
            log_info "Created: $session_hook"
        fi
    fi

    # Hook 3: Dangerous command validator
    local bash_hook="$HOOKS_DIR/validate-bash.sh"
    if [[ -f "$bash_hook" ]] && ! $FORCE; then
        log_info "Skipping existing: $bash_hook"
    else
        if $DRY_RUN; then
            log_dry "Would create: $bash_hook"
        else
            cat > "$bash_hook" << 'HOOK_EOF'
#!/usr/bin/env bash
# PreToolUse hook: Block dangerous bash commands
# Exit 0 = allow, Exit 2 = block with reason

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Patterns to block (destructive VM/disk operations)
DANGEROUS_PATTERNS=(
    'virsh.*destroy.*ubuntu2404-agent'  # Don't destroy the main golden VM
    'virsh.*undefine.*ubuntu2404-agent'
    'rm.*\.qcow2'                         # Don't delete disk images
    'rm -rf /var/lib/libvirt'
)

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -qE "$pattern"; then
        echo "Blocked: This command could destroy the golden image or disk images." >&2
        echo "Use clone_manager.sh for disposable VMs instead." >&2
        exit 2
    fi
done

exit 0
HOOK_EOF
            chmod +x "$bash_hook"
            log_info "Created: $bash_hook"
        fi
    fi
}

#-------------------------------------------------------------------------------
# Create/update settings.json with hooks configuration
#-------------------------------------------------------------------------------
update_settings() {
    log_info "Updating settings.json with hook configuration..."

    # Define the hooks configuration
    local hooks_json
    hooks_json=$(cat << 'JSON_EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/shellcheck-on-write.sh",
            "timeout": 30
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/session-context.sh"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/validate-bash.sh"
          }
        ]
      }
    ]
  }
}
JSON_EOF
)

    if $DRY_RUN; then
        log_dry "Would update: $SETTINGS_FILE"
        log_dry "Hooks configuration:"
        echo "$hooks_json" | head -20
        return 0
    fi

    # Check for jq
    if ! command -v jq &>/dev/null; then
        log_error "jq is required but not installed. Install with: sudo apt install jq"
        log_info "Manual configuration:"
        echo "$hooks_json"
        exit 1
    fi

    # Create or merge with existing settings
    if [[ -f "$SETTINGS_FILE" ]]; then
        # Backup existing
        cp "$SETTINGS_FILE" "$SETTINGS_FILE.bak"
        log_info "Backed up existing settings to: $SETTINGS_FILE.bak"

        # Merge hooks into existing settings
        local merged
        merged=$(jq -s '.[0] * .[1]' "$SETTINGS_FILE" <(echo "$hooks_json"))
        echo "$merged" > "$SETTINGS_FILE"
        log_info "Merged hooks into existing settings"
    else
        # Create new settings file
        mkdir -p "$(dirname "$SETTINGS_FILE")"
        echo "$hooks_json" > "$SETTINGS_FILE"
        log_info "Created new settings file: $SETTINGS_FILE"
    fi
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║            moltdown - Claude Code Hooks Setup                     ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""

    if $REMOVE; then
        remove_hooks
        exit 0
    fi

    # Prerequisites check
    if ! command -v jq &>/dev/null; then
        log_warn "jq not installed - some features may not work"
        log_info "Install with: sudo apt install jq"
    fi

    if ! command -v shellcheck &>/dev/null; then
        log_warn "shellcheck not installed - lint hooks won't work"
        log_info "Install with: sudo apt install shellcheck"
    fi

    create_hook_scripts
    update_settings

    echo ""
    log_info "Setup complete!"
    echo ""
    echo "Hooks installed:"
    echo "  1. PostToolUse[Write|Edit] - shellcheck on .sh files"
    echo "  2. SessionStart[startup]   - project context injection"
    echo "  3. PreToolUse[Bash]        - dangerous command blocking"
    echo ""
    echo "To activate hooks, restart Claude Code or run /hooks to reload."
    echo ""
    if $DRY_RUN; then
        echo "NOTE: This was a dry run. No changes were made."
    fi
}

main "$@"
