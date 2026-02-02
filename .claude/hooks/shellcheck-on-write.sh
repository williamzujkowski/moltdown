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
