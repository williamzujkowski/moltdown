---
name: moltdown
description: |
  moltdown VM workflow toolkit for AI agents. Use when working with VM creation,
  snapshots, clones, bootstrapping, or agent sessions. Triggers on "VM", "snapshot",
  "clone", "bootstrap", "golden image", "agent VM", "moltdown", "libvirt".
argument-hint: [command]
allowed-tools: Read, Bash, Grep, Glob
---

# moltdown - Golden Image VM Workflow

<!-- CANONICAL SOURCES:
  - CLAUDE.md Quick Reference
  - README.md
  - RESOURCES.md
-->

## Quick Reference

```bash
# One-command agent VM (start here!)
./agent.sh                    # Create + connect to agent VM

# Setup (first time only)
./setup_cloud.sh              # Default: 16GB RAM, 4 vCPUs
./setup_cloud.sh --memory 8192 --vcpus 4  # Lightweight

# Snapshot workflow
./snapshot_manager.sh list <vm>        # List snapshots
./snapshot_manager.sh pre-run <vm>     # Before agent work
./snapshot_manager.sh post-run <vm>    # Revert to dev-ready
./snapshot_manager.sh golden <vm>      # Create golden image

# Clone workflow (parallel agents)
./clone_manager.sh create <vm> --linked               # Instant clone
./clone_manager.sh create <vm> --linked --memory 8192 # 8GB clone
./clone_manager.sh list                               # List all
./clone_manager.sh cleanup <vm>                       # Delete all

# Inside VM
vm-health-check              # Quick health status
vm-health-check --watch      # Continuous monitoring
run-claude-limited           # Run Claude with 12GB limit
agent-session                # Persistent tmux session
```

## Core Concepts

### Golden Image Workflow
1. **os-clean**: Fresh Ubuntu + updates
2. **dev-ready**: Bootstrap complete (tools installed, auth configured)
3. **pre-run**: Before each agent run (timestamped)
4. **post-run**: Revert to dev-ready after work

### Memory Planning
- Claude CLI can leak to 13GB+
- 64GB host: 2-4 clones @ 12-16GB each
- Always use `run-claude-limited` inside VMs

## Script Reference

| Script | Purpose |
|--------|---------|
| `agent.sh` | One-command agent VM creation |
| `setup_cloud.sh` | Full VM setup (cloud images) |
| `snapshot_manager.sh` | Manage libvirt snapshots |
| `clone_manager.sh` | Manage VM clones |
| `sync-ai-auth.sh` | Sync AI CLI auth to VMs |
| `update-golden.sh` | Update golden image |
| `guest/bootstrap_agent_vm.sh` | Run inside VM to configure it |

## Common Workflows

### Start Fresh Agent Session
```bash
./agent.sh
# Inside VM:
agent-session
```

### Run Multiple Agents in Parallel
```bash
./clone_manager.sh create ubuntu2404-agent --linked --memory 8192
./clone_manager.sh create ubuntu2404-agent --linked --memory 8192
./clone_manager.sh start moltdown-clone-*
```

### Update Golden Image
```bash
./update-golden.sh           # Full update
./update-golden.sh --quick   # CLIs only
./update-golden.sh --auth-only  # Re-sync auth
```

## Shell Standards

All scripts follow:
- `set -euo pipefail` strict mode
- `readonly` for constants
- `local` for function variables
- Logging: `log_info()`, `log_warn()`, `log_error()`, `log_phase()`
- All scripts must pass `shellcheck -x`

## Quality Gates

Before committing:
- [ ] `make lint` passes
- [ ] Scripts are executable (`chmod +x`)
- [ ] No hardcoded paths that should be configurable
- [ ] `--help` updated if CLI changed

## Related Files

- [README.md](../../../README.md) - Full documentation
- [RESOURCES.md](../../../RESOURCES.md) - Memory planning
- [CLAUDE.md](../../../CLAUDE.md) - Development guidelines
