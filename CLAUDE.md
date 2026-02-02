# CLAUDE.md

**Project:** moltdown - Golden image VM workflow for AI agents
**Repository:** github.com/williamzujkowski/moltdown
**Owner:** @williamzujkowski

---

## Quick Reference

```bash
# Setup & Installation (Cloud Image - Recommended)
./setup_cloud.sh              # One-command setup using cloud images (fast!)
./setup_cloud.sh --vm-name my-agent  # Custom VM name

# Setup & Installation (ISO - Alternative)
./setup.sh                    # One-command setup using ISO installer (slower)
make install-deps             # Install host dependencies only

# VM Creation (Manual)
./generate_cloud_seed.sh      # Create seed ISO for cloud images
./generate_nocloud_iso.sh     # Create seed ISO for ISO installer
./virt_install_agent_vm.sh    # Create VM with virt-install (ISO method)

# Bootstrap (run inside VM)
./bootstrap_agent_vm.sh       # Full bootstrap with all phases

# Snapshot Management
./snapshot_manager.sh list <vm>        # List snapshots
./snapshot_manager.sh pre-run <vm>     # Snapshot before agent run
./snapshot_manager.sh post-run <vm>    # Revert to dev-ready
./snapshot_manager.sh golden <vm>      # Interactive golden image creation

# Clone Management (Parallel Workflows)
./clone_manager.sh create <vm> --linked  # Create linked clone (instant)
./clone_manager.sh create <vm>           # Create full clone
./clone_manager.sh list                  # List all clones
./clone_manager.sh start <clone>         # Start a clone
./clone_manager.sh stop <clone>          # Stop a clone
./clone_manager.sh delete <clone>        # Delete a clone
./clone_manager.sh cleanup <vm>          # Delete all clones of VM

# Quality
make lint                     # Run shellcheck + yamllint
shellcheck -x *.sh guest/*.sh # Manual shellcheck

# GitHub CLI
gh issue create               # Create issue
gh issue list                 # List issues
gh pr create                  # Create PR
```

---

## Project Overview

**moltdown** is a toolkit for creating reproducible, snapshot-based Ubuntu 24.04 Desktop VMs optimized for AI agent workflows. The core concept is "golden image" management: create a pristine VM state, run agents with full autonomy, then "molt" back to clean state.

The name comes from molting — shedding old state to emerge fresh.

---

## Repository Structure

```
moltdown/
├── setup_cloud.sh               # One-command setup using cloud images (RECOMMENDED)
├── setup.sh                     # One-command setup using ISO installer (alternative)
├── generate_cloud_seed.sh       # Creates seed ISO for cloud images
├── generate_nocloud_iso.sh      # Creates seed ISO for ISO installer (autoinstall)
├── virt_install_agent_vm.sh     # Creates VM using virt-install + ISO
├── run_bootstrap_on_vm.sh       # Pushes bootstrap to VM via SSH
├── snapshot_manager.sh          # Manages libvirt snapshots (pre-run, post-run, golden)
├── guest/
│   └── bootstrap_agent_vm.sh    # Runs INSIDE the VM to configure it
├── cloud-init/
│   ├── user-data                # Cloud-init config template (for cloud images)
│   └── meta-data                # Cloud-init instance metadata
├── autoinstall/
│   ├── user-data                # Cloud-init autoinstall config (Ubuntu unattended install)
│   └── meta-data                # Cloud-init instance metadata
├── examples/
│   ├── bootstrap_local.sh       # Template for user customizations
│   └── user-data-custom.yaml    # Example customized autoinstall
├── Makefile                     # Common operations
└── .github/workflows/lint.yml   # CI with shellcheck + yamllint
```

---

## Core Operating Principles

### 1. Time Authority

**All operations use America/New_York (ET) timezone.**

Before any time-sensitive operation:

```bash
date '+%Y-%m-%d %H:%M:%S %Z'  # Verify current ET time
TZ='America/New_York' date    # Force ET if needed
```

Use verified ET time for:
- Timestamps in commits and issues
- Version date checks
- "Last updated" fields

### 2. Documentation Style: Polite Linus Torvalds

**All documentation and text must follow this style:**

Write like a technically precise, experienced engineer who respects the reader's intelligence. Be direct, honest, and clear. No marketing fluff, no exaggeration, no hand-waving.

**Do:**
- State what something does, precisely
- Admit limitations and incomplete features honestly
- Use technical terms correctly
- Be concise - say it once, say it right
- Provide working examples that actually work
- Tell the reader what they need to know, not what sounds impressive

**Do Not:**
- Exaggerate capabilities ("revolutionary", "cutting-edge", "seamless")
- Claim features exist when they don't
- Use vague marketing language ("leverage", "empower", "unlock")
- Hide limitations in fine print
- Promise what the code can't deliver
- Pad documentation with filler

**The test:** If a developer reads your documentation and tries to use the feature, will it work exactly as described? If not, fix the documentation or fix the code.

### 3. Prime Directive

**Priority order for all implementation decisions:**

```
correctness > simplicity > performance > cleverness
```

- **Correctness**: Does it work? Handles edge cases? Tested?
- **Simplicity**: Can someone understand it in 5 minutes?
- **Performance**: Does it meet requirements? (not theoretical optimality)
- **Cleverness**: Never. Clever code is maintenance debt.

**The goal:** Produce boring, readable, maintainable software that survives production.

### 4. Research-First Approach

Before implementing any feature or making changes:

1. **Research Phase**
   - Check existing scripts for similar patterns
   - Verify command compatibility (Ubuntu 24.04)
   - Look for security implications

2. **Document Findings**
   - Create GitHub issue if non-trivial
   - Note any `Verify:` items

---

## Shell Script Standards

### File Headers

```bash
#!/usr/bin/env bash
#===============================================================================
# script_name.sh - Brief Description
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
#
# Purpose: Detailed explanation
#
# Usage:   ./script_name.sh [options]
#
# License: MIT
#===============================================================================
```

### Required Patterns

```bash
# Always start with strict mode
set -euo pipefail

# Use readonly for constants
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="1.0.0"

# Use local for function variables
my_function() {
    local input="$1"
    local result
    # ...
}

# Log functions for consistent output
log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_phase() { echo ""; echo "[PHASE] $*"; }
```

### Banner Style

All user-facing scripts use this banner format:
```bash
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║            🦀 moltdown - <Script Purpose>                         ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
```

### CLI Conventions

- Provide `--help` / `-h` for all user-facing scripts
- Use positional args for required inputs
- Use flags for optional behavior
- Check prerequisites before operations
- Validate inputs early, fail fast

### Security Sensitive Areas

- `autoinstall/user-data` contains a default password hash — users should customize
- SSH hardening disables password auth — ensure keys are configured first
- The bootstrap enables UFW — don't lock yourself out

---

## Key Concepts

### Golden Image Workflow

1. **os-clean**: Snapshot after fresh Ubuntu install + updates
2. **dev-ready**: Snapshot after bootstrap completes (tools installed, auth configured)
3. **pre-run**: Timestamped snapshot before each agent run
4. **post-run**: Revert to dev-ready after agent work completes

### Bootstrap Phases

The `guest/bootstrap_agent_vm.sh` script runs in phases with idempotent markers:

1. System updates
2. Core utilities
3. Security hardening (SSH, UFW, fail2ban)
4. Development tools (Node.js, Docker, Python)
5. Browser & automation (Chrome, Playwright deps)
6. Agent tooling (Claude CLI, workspace structure)
7. Desktop optimization (GNOME tweaks for VM)
8. Long-run hardening (swap, cloud-init disable, health check)
9. Local customizations (if bootstrap_local.sh exists)
10. Verification

Phases are tracked in `~/.bootstrap_markers/` — re-running skips completed phases.

### Cloud-init Autoinstall

The `autoinstall/user-data` file defines unattended Ubuntu installation:
- Username/password configuration
- SSH key injection
- Package pre-installation
- Post-install commands

---

## Workflow Templates

### Feature Implementation

1. Create GitHub issue with requirements
2. Research and document approach
3. Implement with testing
4. Run `make lint`
5. Create PR with issue reference
6. Address review feedback
7. Merge and close issue

### Bug Fix

1. Create GitHub issue with reproduction steps
2. Identify root cause
3. Implement fix
4. Verify fix works
5. Check for similar bugs elsewhere
6. Create PR
7. Merge and close issue

### Adding a New Package to Bootstrap

Edit `guest/bootstrap_agent_vm.sh`, find the appropriate phase function:
- System packages → `phase_core_utilities()` or `phase_dev_tools()`
- Python tools → `phase_dev_tools()` (use pipx)
- Node packages → `phase_dev_tools()` (use npm -g)
- Browser-related → `phase_browser_automation()`

Add to the existing `apt install` block or create a new section with logging.

### Adding a New Bootstrap Phase

1. Create the phase function: `phase_new_thing() { ... }`
2. Add to main(): `run_once "NN-new-thing" phase_new_thing`
3. Number it appropriately (phases run in order)

### Adding a Snapshot Manager Command

1. Create `cmd_new_command()` function
2. Add case to the `main()` case statement
3. Update `usage()` with documentation

---

## Discovered Issue Protocol

When finding issues during work, create a GitHub issue **IMMEDIATELY** to prevent lost work items.

### Issue Creation Format

**Title Pattern:** `{type}: {brief description}`

| Type         | Label         | Use When                            |
| ------------ | ------------- | ----------------------------------- |
| `bug:`       | bug           | Defect in existing functionality    |
| `enhance:`   | enhancement   | New feature or improvement          |
| `docs:`      | documentation | Documentation update needed         |
| `security:`  | security      | Security consideration              |

**Quick Commands:**

```bash
# Bug discovered
gh issue create --title "bug: [description]" --label "bug"

# Enhancement idea
gh issue create --title "enhance: [description]" --label "enhancement"

# Documentation issue
gh issue create --title "docs: [description]" --label "documentation"
```

---

## Error Handling

### Q Protocol

Before uncertain actions:

```
DOING: [action]
EXPECT: [outcome]
IF YES: [next step]
IF NO: [fallback]
```

After execution:

```
RESULT: [what happened]
MATCHES: yes/no
THEREFORE: [conclusion]
```

### Failure Response

When anything fails:

1. State what failed with raw error
2. State theory of cause
3. Propose ONE next action
4. State expected outcome
5. Wait for confirmation (or proceed if clearly safe)

**Never:**
- Silent retries
- Best-effort guessing
- Continuing without addressing failure

---

## Self-Check Quality Gate

Before completing ANY task:

- [ ] Scripts pass `shellcheck -x`
- [ ] YAML passes `yamllint` (for autoinstall/)
- [ ] Scripts are executable (`chmod +x`)
- [ ] Changes tested or test plan documented
- [ ] No hardcoded paths that should be configurable
- [ ] Error messages are helpful
- [ ] `--help` updated if CLI changed

---

## Ask vs Assume Rule

**Always clarify (never assume) for:**

| Topic           | Example Question                              |
| --------------- | --------------------------------------------- |
| VM environment  | "Which libvirt network? NAT or bridged?"      |
| User setup      | "Do you have SSH keys configured?"            |
| Breaking changes| "Can we change the default VM name?"          |
| Security        | "Should this be in .gitignore?"               |

**Safe to assume:** Ubuntu 24.04, bash 5.x, libvirt/KVM, standard GNU coreutils.

---

## Useful Commands

```bash
# Check VM status
sudo virsh list --all

# Get VM IP
sudo virsh domifaddr ubuntu2404-agent

# SSH into VM
ssh agent@<ip>

# View snapshots
./snapshot_manager.sh list ubuntu2404-agent

# Quick moltdown (revert to clean)
./snapshot_manager.sh post-run ubuntu2404-agent

# Re-run a bootstrap phase
rm ~/.bootstrap_markers/05-browser-automation.done
./bootstrap_agent_vm.sh

# Lint everything
make lint
```

### GUI Access

```bash
# Connect to VM desktop with virt-viewer
virt-viewer ubuntu2404-agent

# Auto-retry if VM is starting
virt-viewer --auto-retry ubuntu2404-agent

# Full management GUI
virt-manager
```

### Long-Running Sessions

```bash
# Inside VM: Quick health check
vm-health-check

# Inside VM: Watch mode (updates every 30s)
vm-health-check --watch

# From host: Remote health check
ssh agent@<ip> 'vm-health-check'

# Manual journal cleanup if needed
ssh agent@<ip> 'sudo journalctl --vacuum-size=50M'
```

---

## Security Considerations

**Local-only data (NOT in git):**
- VM disk images (`/var/lib/libvirt/images/` or `/var/tmp/`)
- Generated seed ISOs (`seed.iso`)
- SSH keys inside VMs
- User credentials

**In git repo:**
- Shell scripts only
- Documentation
- Templates (with example/placeholder credentials)

The `.gitignore` excludes all disk images and ISOs. Never commit files from `/var/lib/libvirt/images/`.

When working with this codebase, ensure:
- Never add `*.qcow2`, `*.img`, or `*.iso` files to git
- Never commit real SSH private keys
- Template files contain only example credentials (the actual credentials are provided at runtime)

---

## Future Improvements / TODOs

- [ ] Support for other distros (Fedora, Debian)
- [ ] Packer integration for cloud image builds
- [ ] Terraform module for cloud VM provisioning
- [ ] Pre-built OVA/QCOW2 downloads
- [ ] Integration tests with actual VM creation

---

_Last updated: 2026-02-01 (ET)_
