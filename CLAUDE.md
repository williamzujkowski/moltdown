# CLAUDE.md

This file provides context for Claude (or other AI assistants) when working with the moltdown repository.

## Project Overview

**moltdown** is a toolkit for creating reproducible, snapshot-based Ubuntu 24.04 Desktop VMs optimized for AI agent workflows. The core concept is "golden image" management: create a pristine VM state, run agents with full autonomy, then "molt" back to clean state.

The name comes from molting — shedding old state to emerge fresh.

## Repository Structure

```
moltdown/
├── setup.sh                     # One-command setup (entry point for new users)
├── generate_nocloud_iso.sh      # Creates cloud-init seed ISO for autoinstall
├── virt_install_agent_vm.sh     # Creates VM using virt-install + seed ISO
├── run_bootstrap_on_vm.sh       # Pushes bootstrap to VM via SSH
├── snapshot_manager.sh          # Manages libvirt snapshots (pre-run, post-run, golden)
├── guest/
│   └── bootstrap_agent_vm.sh    # Runs INSIDE the VM to configure it
├── autoinstall/
│   ├── user-data                # Cloud-init autoinstall config (Ubuntu unattended install)
│   └── meta-data                # Cloud-init instance metadata
├── examples/
│   ├── bootstrap_local.sh       # Template for user customizations
│   └── user-data-custom.yaml    # Example customized autoinstall
├── Makefile                     # Common operations
└── .github/workflows/lint.yml   # CI with shellcheck + yamllint
```

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
8. Local customizations (if bootstrap_local.sh exists)
9. Verification

Phases are tracked in `~/.bootstrap_markers/` — re-running skips completed phases.

### Cloud-init Autoinstall
The `autoinstall/user-data` file defines unattended Ubuntu installation:
- Username/password configuration
- SSH key injection
- Package pre-installation
- Post-install commands

## Development Guidelines

### Shell Script Conventions
- Use `set -euo pipefail` at the start of all scripts
- Use `readonly` for constants
- Use `local` for function variables
- Log functions: `log_info()`, `log_warn()`, `log_error()`, `log_phase()`
- Check prerequisites before operations
- Provide `--help` / `-h` for all user-facing scripts
- Use heredocs for multi-line output

### Banner Style
All scripts use this banner format:
```bash
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║            🦀 moltdown - <Script Purpose>                         ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
```

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

## Testing

### Linting
```bash
make lint
# or manually:
shellcheck -x *.sh guest/*.sh
yamllint autoinstall/
```

### Manual Testing Workflow
1. Create a test VM: `./setup.sh --vm-name test-vm`
2. SSH in and run bootstrap: `./bootstrap_agent_vm.sh`
3. Verify with: check `~/.bootstrap_markers/` for completed phases
4. Test snapshot operations: `./snapshot_manager.sh list test-vm`

### CI
GitHub Actions runs shellcheck and yamllint on push/PR to main.

## Common Tasks

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

### Modifying Autoinstall
Edit `autoinstall/user-data`. Key sections:
- `identity:` — username, password hash, hostname
- `ssh:` — authorized keys
- `packages:` — packages installed during OS install
- `late-commands:` — shell commands run post-install

### Adding a Snapshot Manager Command
1. Create `cmd_new_command()` function
2. Add case to the `main()` case statement
3. Update `usage()` with documentation

## Things to Watch Out For

### Security Sensitive
- `autoinstall/user-data` contains a default password hash — users should customize
- SSH hardening disables password auth — ensure keys are configured first
- The bootstrap enables UFW — don't lock yourself out

### VM-Specific Paths
- `/mnt/user-data/uploads` — not relevant here (that's Claude's container)
- VM working directory: `/home/agent/` (or whatever username is configured)
- Bootstrap markers: `~/.bootstrap_markers/`
- Artifacts: `~/work/artifacts/`

### Idempotency
- Bootstrap phases use marker files — deleting a marker re-runs that phase
- Snapshot operations check VM state before acting
- Package installs use `|| true` where appropriate to not fail on already-installed

### Dependencies Between Scripts
- `setup.sh` calls → `generate_nocloud_iso.sh` → `virt_install_agent_vm.sh`
- `run_bootstrap_on_vm.sh` copies and runs → `guest/bootstrap_agent_vm.sh`
- `bootstrap_agent_vm.sh` optionally sources → `bootstrap_local.sh`

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
```

## Future Improvements / TODOs
- [ ] Support for other distros (Fedora, Debian)
- [ ] Packer integration for cloud image builds
- [ ] Terraform module for cloud VM provisioning
- [ ] Pre-built OVA/QCOW2 downloads
- [ ] Integration tests with actual VM creation
