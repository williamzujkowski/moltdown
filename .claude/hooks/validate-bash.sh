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
