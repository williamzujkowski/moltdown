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
