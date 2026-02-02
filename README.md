# 🦀 moltdown

*Shed your VM state. Emerge fresh.*

A reproducible, low-click workflow for creating and managing Ubuntu 24.04 Desktop VMs optimized for AI agent work. Run agents with full autonomy, then molt back to a pristine golden image.

[![Lint](https://github.com/williamzujkowski/moltdown/actions/workflows/lint.yml/badge.svg)](https://github.com/williamzujkowski/moltdown/actions/workflows/lint.yml)

## Overview

This toolkit provides:

- **Automated OS Installation**: Cloud-init/autoinstall for hands-free Ubuntu Desktop setup
- **Comprehensive Bootstrap**: Security-hardened development environment with agent tooling
- **Snapshot Management**: Pre/post agent-run snapshots for clean state management
- **Idempotent Operations**: Re-runnable scripts with phase markers
- **Local Customization**: Override defaults without modifying core scripts

## Quick Start

### One-Command Setup (Recommended)

```bash
git clone https://github.com/williamzujkowski/moltdown.git
cd moltdown
./setup_cloud.sh
```

This uses Ubuntu Cloud Images for fast VM creation (~8 minutes to desktop-ready).

### Alternative: ISO Installer

```bash
./setup.sh
```

This uses the traditional Ubuntu ISO installer (slower, ~20 minutes).

### Using Make

```bash
make install-deps    # Install host dependencies
make setup-cloud     # Create VM using cloud images (RECOMMENDED)
make setup           # Create VM using ISO installer
make golden          # Create golden snapshots after bootstrap
make gui             # Open VM desktop with virt-viewer
make ssh             # SSH into VM
```

### Manual Installation

If you prefer more control:

```bash
# 1. Generate cloud-init seed ISO
./generate_nocloud_iso.sh --customize

# 2. Create VM with automated installation
./virt_install_agent_vm.sh --seed-iso ./seed.iso

# 3. Wait for installation (~10-15 min), then SSH in
ssh agent@<vm-ip>

# 4. Run bootstrap inside VM
./bootstrap_agent_vm.sh
gh auth login

# 5. Create golden snapshots
sudo shutdown -h now
./snapshot_manager.sh golden ubuntu2404-agent
```

## Directory Structure

```
moltdown/
├── README.md                    # This file
├── CLAUDE.md                    # Development guidelines
├── Makefile                     # Common operations
├── setup_cloud.sh               # One-command setup (cloud images, RECOMMENDED)
├── setup.sh                     # One-command setup (ISO installer)
├── generate_cloud_seed.sh       # Create seed ISO for cloud images
├── generate_nocloud_iso.sh      # Create seed ISO for ISO installer
├── virt_install_agent_vm.sh     # Create VM with virt-install
├── run_bootstrap_on_vm.sh       # Push bootstrap via SSH
├── snapshot_manager.sh          # Manage VM snapshots
├── clone_manager.sh             # Manage VM clones for parallel workflows
├── cloud-init/
│   ├── user-data                # Cloud-init config (for cloud images)
│   └── meta-data                # Cloud-init metadata
├── autoinstall/
│   ├── user-data                # Autoinstall config (for ISO installer)
│   └── meta-data                # Cloud-init metadata
├── guest/
│   ├── bootstrap_agent_vm.sh    # Run inside VM
│   └── vm-health-check.sh       # Health monitoring script
├── docs/
│   └── CLOUD_IMAGES.md          # Cloud image workflow docs
├── examples/
│   ├── bootstrap_local.sh       # Local customization template
│   └── user-data-custom.yaml    # Customized autoinstall example
└── .github/
    └── workflows/
        └── lint.yml             # ShellCheck + yamllint CI
```

## GUI Access

VMs are created with SPICE graphics for full desktop access.

```bash
# Connect with virt-viewer (minimal)
virt-viewer ubuntu2404-agent

# Or use virt-manager for full GUI management
virt-manager
```

Install GUI tools: `sudo apt install virt-viewer` or `sudo apt install virt-manager`

## Agent Workflow

Once you have a `dev-ready` snapshot, use this workflow for each agent run:

```bash
# Before agent work
./snapshot_manager.sh pre-run ubuntu2404-agent

# ... do agent work ...

# Export any artifacts from VM
scp agent@<vm-ip>:~/work/artifacts/* ./local-artifacts/

# Reset to clean state
./snapshot_manager.sh post-run ubuntu2404-agent
```

## Parallel Agent Workflows

Run multiple agents simultaneously using VM clones:

```bash
# Create linked clones (instant, copy-on-write)
./clone_manager.sh create ubuntu2404-agent --linked
./clone_manager.sh create ubuntu2404-agent --linked
./clone_manager.sh create ubuntu2404-agent --linked

# Start clones
./clone_manager.sh start moltdown-clone-ubuntu2404-agent-20250201-143052

# List all clones
./clone_manager.sh list

# Connect to each clone
virt-viewer <clone-name>  # GUI
ssh agent@<clone-ip>      # SSH

# Cleanup when done
./clone_manager.sh cleanup ubuntu2404-agent
```

**Clone types:**
- **Linked clone** (`--linked`): Instant creation, uses copy-on-write. Best for parallel work.
- **Full clone**: Complete disk copy. Slower but fully independent.

Using Make:
```bash
make clone-linked    # Create linked clone
make clone           # Create full clone
make clone-list      # List all clones
make clone-cleanup   # Delete all clones
```

## Long-Running Sessions

VMs are hardened for multi-day or multi-week agent sessions:

- **Swap file**: 4GB for memory pressure
- **Journal limits**: 100MB max, prevents disk fill
- **No auto-reboot**: Security updates don't restart
- **Cloud-init disabled**: Prevents reconfiguration

Monitor health inside VM:
```bash
vm-health-check           # Quick status
vm-health-check --watch   # Live monitoring
```

## Scripts Reference

### bootstrap_agent_vm.sh

Transforms a fresh Ubuntu 24.04 Desktop into an agent-ready environment.

**Features:**
- Phased execution with idempotent markers
- Security hardening (SSH, firewall, fail2ban)
- Development tools (git, gh, Node.js, Docker, Python)
- Browser automation (Chrome, Playwright deps)
- Agent tooling (Claude CLI, workspace structure)
- VM performance optimization
- Package manifest generation

**Configuration flags** (edit in script):
```bash
INSTALL_NODEJS="true"
INSTALL_DOCKER="true"
INSTALL_PLAYWRIGHT_DEPS="true"
INSTALL_CLAUDE_CLI="true"
REMOVE_DESKTOP_FLUFF="true"
ENABLE_UNATTENDED_UPGRADES="true"
```

### snapshot_manager.sh

Manage libvirt snapshots for the golden image workflow.

```bash
# List all VMs
./snapshot_manager.sh vms

# List snapshots
./snapshot_manager.sh list ubuntu2404-agent

# Create snapshot (offline recommended)
./snapshot_manager.sh create ubuntu2404-agent my-snap --offline

# Revert to snapshot
./snapshot_manager.sh revert ubuntu2404-agent dev-ready

# Pre-agent-run workflow
./snapshot_manager.sh pre-run ubuntu2404-agent

# Post-agent-run (revert to dev-ready)
./snapshot_manager.sh post-run ubuntu2404-agent

# Interactive golden image creation
./snapshot_manager.sh golden ubuntu2404-agent
```

### generate_nocloud_iso.sh

Generate cloud-init seed ISO for automated installation.

```bash
# Interactive mode
./generate_nocloud_iso.sh --customize

# Command-line customization
./generate_nocloud_iso.sh \
    --username myuser \
    --password mysecretpass \
    --hostname my-agent-vm \
    --ssh-key ~/.ssh/id_ed25519.pub

# Custom output path
./generate_nocloud_iso.sh /tmp/my-seed.iso
```

### virt_install_agent_vm.sh

Create VMs with virt-install and automated installation.

```bash
# Default configuration
./virt_install_agent_vm.sh --seed-iso ./seed.iso

# Full customization
./virt_install_agent_vm.sh \
    --name my-agent-vm \
    --vcpus 8 \
    --memory 16384 \
    --disk-size 100 \
    --seed-iso ./seed.iso

# Dry run (show command without executing)
./virt_install_agent_vm.sh --seed-iso ./seed.iso --dry-run
```

### run_bootstrap_on_vm.sh

Push and execute bootstrap script via SSH.

```bash
# Basic usage
./run_bootstrap_on_vm.sh 192.168.122.100 username

# Copy SSH key first
./run_bootstrap_on_vm.sh 192.168.122.100 username --copy-ssh-key

# Dry run
./run_bootstrap_on_vm.sh 192.168.122.100 username --dry-run
```

## Security Considerations

The bootstrap script implements:

1. **SSH Hardening**
   - Root login disabled
   - Password authentication disabled
   - Public key authentication only
   - Limited auth attempts

2. **Firewall (UFW)**
   - Default deny incoming
   - Default allow outgoing
   - SSH allowed

3. **Fail2ban**
   - SSH brute-force protection
   - 1-hour ban after 3 failures

4. **Unattended Upgrades**
   - Automatic security patches
   - No automatic reboot

## Customization

### Local Overrides (Recommended)

Instead of modifying core scripts, use `bootstrap_local.sh`:

```bash
# Copy template to VM
scp examples/bootstrap_local.sh agent@vm:~/

# Edit to add your packages, dotfiles, etc.
ssh agent@vm vim ~/bootstrap_local.sh

# Run bootstrap - it will source your local config automatically
ssh agent@vm ./bootstrap_agent_vm.sh
```

Example `bootstrap_local.sh`:
```bash
# Additional packages
LOCAL_APT_PACKAGES=("zsh" "neovim" "tmuxinator")
LOCAL_NPM_PACKAGES=("@anthropic-ai/claude-code")
LOCAL_PIPX_PACKAGES=("pdm" "pre-commit")

phase_local_customizations() {
    # Clone dotfiles
    git clone https://github.com/myuser/dotfiles ~/.dotfiles
    ~/.dotfiles/install.sh
}
```

### Adding Software

Edit `bootstrap_agent_vm.sh` and add to the appropriate phase function. For example, to add VS Code:

```bash
phase_dev_tools() {
    # ... existing code ...
    
    # VS Code
    log_info "Installing VS Code..."
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
    sudo install -o root -g root -m 644 packages.microsoft.gpg /etc/apt/trusted.gpg.d/
    sudo sh -c 'echo "deb [arch=amd64] https://packages.microsoft.com/repos/vscode stable main" > /etc/apt/sources.list.d/vscode.list'
    sudo apt update
    sudo apt install -y code
}
```

### Changing Default User

Edit `autoinstall/user-data`:

```yaml
identity:
    hostname: your-hostname
    username: your-username
    password: "your-password-hash"
```

Generate password hash:
```bash
echo 'yourpassword' | openssl passwd -6 -stdin
```

### Adding SSH Keys

Option 1: Edit `autoinstall/user-data`:
```yaml
ssh:
    authorized-keys:
      - ssh-ed25519 AAAA... your-key
```

Option 2: Use generate script:
```bash
./generate_nocloud_iso.sh --ssh-key ~/.ssh/id_ed25519.pub
```

## Troubleshooting

### VM won't start after revert

```bash
# Check VM state
sudo virsh domstate ubuntu2404-agent

# Force off and try again
sudo virsh destroy ubuntu2404-agent
sudo virsh snapshot-revert ubuntu2404-agent dev-ready
sudo virsh start ubuntu2404-agent
```

### Can't SSH to VM

```bash
# Get VM IP
sudo virsh domifaddr ubuntu2404-agent

# Check if SSH is running in VM
sudo virsh console ubuntu2404-agent
# Then: systemctl status ssh

# Check firewall
sudo ufw status
```

### Bootstrap fails mid-way

The script uses idempotent markers. Just re-run:
```bash
./bootstrap_agent_vm.sh
```

To force re-run a phase:
```bash
rm ~/.bootstrap_markers/05-browser-automation.done
./bootstrap_agent_vm.sh
```

### Autoinstall not working

1. Verify seed ISO is attached:
```bash
sudo virsh dumpxml ubuntu2404-agent | grep -A5 cdrom
```

2. Check cloud-init logs in VM:
```bash
cat /var/log/cloud-init-output.log
```

## Requirements

**Host system:**
- libvirt + QEMU/KVM
- virt-install (`virtinst` package)
- virt-viewer (for GUI access)
- genisoimage, mkisofs, or xorriso
- SSH client

**Install on Ubuntu/Debian:**
```bash
sudo apt install \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    virtinst \
    virt-manager \
    virt-viewer \
    genisoimage \
    cloud-image-utils \
    openssh-client
```

Or use: `make install-deps`

## License

MIT License - feel free to adapt for your workflows.
